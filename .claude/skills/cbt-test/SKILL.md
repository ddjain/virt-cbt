---
name: cbt-test
description: >
  End-to-end test runner for the ODF CBT Fedora VM validator: create a VM
  pool, take a baseline Full backup, take a second Incremental (CBT) backup,
  run guest+backup verification, then analyze the results using the
  physical qcow2-header evidence (never VirtualMachineBackup.status) to
  confirm CBT genuinely worked. Produces a clear pass/fail summary with the
  supporting evidence. Use when the user wants to test, exercise, or
  demonstrate this repo's CBT workflow end-to-end — e.g. "test this
  workflow", "run the CBT pipeline", "create a VM and verify CBT backups",
  "demo CBT backup", "run e2e test", "cbt-test". Also use after making
  changes to scripts/odf-vm-validator.sh, scripts/cbt-evidence-check.sh,
  or the kube-burner templates, to confirm the change didn't break the
  pipeline.
compatibility: >
  Requires oc, virtctl, kube-burner, jq, bash 4+, and KUBECONFIG access to
  an OpenShift + ODF cluster. On macOS, put /opt/homebrew/bin ahead of /bin
  in PATH (system bash is 3.2).
---

# CBT End-to-End Test Runner

You run the full VM-creation → Full-backup → Incremental-backup →
verification → result-analysis pipeline for this repo's ODF CBT validator,
against a real OpenShift + ODF cluster, and report back a clear pass/fail
with evidence — not just "the command exited 0".

You are **interactive** for anything that touches cluster state destructively
(picking a namespace, tearing down an existing pool) — confirm with the user
before doing anything that could disrupt VMs or data they didn't ask you to
touch. You are **not** interactive for the read-only/setup steps (checking
prerequisites, reading config) — just do those.

## Before you start: read the ground truth

Read these once at the start of a session, don't re-derive them:

- `README.md` — what each `make` target creates and where.
- `docs/odf/CBT-EXPLAINED.md` §6–8 — how correctness is actually verified
  (qcow2 `backing-filename` header, never `.status`), and the real incident
  that shaped the current safety design (never mount the CBT-overlay/state
  PVC into a second pod while the VM is running).
- `AGENTS.md` — project rules, in particular the safety rule above.

## Step 0 — Preflight

```bash
which oc virtctl kube-burner jq
bash --version   # must be 4+; on macOS, put /opt/homebrew/bin ahead of
                 # /bin in PATH for this session if it reports 3.2.x
```

If `bash --version` on macOS reports 3.2.x, every `scripts/*.sh` invocation
will fail with `declare: -A: invalid option`. Fix the `PATH` before doing
anything else — don't try to work around it per-command.

Confirm `config.env` exists and points at the right cluster:

```bash
test -f config.env || make init-config
grep -E '^(KUBECONFIG|NAMESPACE|VM_COUNT)=' config.env
```

If `KUBECONFIG` is unset/wrong, ask the user which cluster to target before
proceeding — never guess a cluster to run this against.

```bash
export KUBECONFIG=<the value from config.env>
oc whoami
oc get storagecluster,cephcluster -n openshift-storage
make check-prereqs
```

`check-prereqs` must print `Prerequisites OK`. If it fails, report the exact
error — do not attempt to install operators or change cluster config to
force it to pass.

## Step 1 — Decide on a namespace, and check for an existing pool

```bash
grep -E '^NAMESPACE=' config.env
make density-status 2>&1
```

- If `density-status` shows an existing, healthy VM pool the user didn't ask
  you to touch: **stop and ask** whether to reuse it (skip straight to Step
  2 against an existing VM), or tear it down and recreate. Do not silently
  delete someone else's test data.
- If the namespace doesn't exist or is empty, proceed.

## Step 2 — VM creation

```bash
make density-setup N=1        # use N=1 for a quick smoke test; ask the
                               # user if they want more VMs for a density run
make density-status
```

Report back: namespace, VM name(s) created (`<VM_PREFIX>-1` .. `-N` —
1-indexed, not 0-indexed), and confirm `ready=true` /
`changedBlockTracking.state=Enabled` for each.

## Step 3 — First backup (Full)

```bash
make backup VMS=<vm-name>
```

Internally this creates `VirtualMachineBackup/<vm>-full`, waits for it to
reach a terminal condition, then runs `scripts/cbt-evidence-check.sh`
against the resulting qcow2 in `<vm>-backup-output` PVC — read the
`CBT evidence: ... matches expected Full` line in the output. If it instead
says `physically Incremental` or `Anomalous` for what should be a Full
backup, that's a real bug, not a flaky check — investigate before continuing
(don't paper over it by re-running).

## Step 4 — Second backup (Incremental / CBT)

```bash
make cbt-backup VMS=<vm-name>
```

Same flow, but expects `physically Incremental` with a `backingFile`
pointing at `.../libvirt/qemu/cbt/<disk>.qcow2`. If you want a stronger
signal that CBT tracked *your* changes specifically (not just "some"
incremental), write a known file to the guest between steps 3 and 4 first:

```bash
make ssh VM=<vm-name> CMD='sudo -n dd if=/dev/urandom of=/data/cbt-test-marker bs=1M count=8 conv=fsync'
```

## Step 5 — Verification

```bash
make verify VMS=<vm-name>
```

This re-checks both backups' physical evidence *and* SSHes into the guest to
validate the workload database (mount, SQLite integrity, contiguous rows,
digests). If SSH fails with `REMOTE HOST IDENTIFICATION HAS CHANGED`, this
is expected after a VM was recreated with the same name — clear just that
host's entry, don't touch the whole file:

```bash
ssh-keygen -R "vm.<vm-name>.<namespace>" -f ~/.ssh/known_hosts
```

## Step 6 — Result analysis

Do not just say "verify passed". Pull the actual evidence and summarize it:

```bash
make report                                          # newest summary.json
r=$(ls -t reports | head -1); echo "$r"
cat "reports/$r/summary.json"
cat "reports/$r/evidence/"*.json 2>/dev/null
```

For each backup, report: `physicalType` vs `expectedType` (must match),
`backingFile` (empty for Full, CBT-overlay path for Incremental),
`allocatedDataBytes` if present. Explicitly state that this evidence was
read from the qcow2 file itself, not from `VirtualMachineBackup.status` —
that's the point of this whole pipeline.

If anything failed, don't just report the failure — look at `run.log` in
the same report directory for the actual error, and check VM health before
proposing a fix:

```bash
tail -80 "reports/$r/run.log"
oc get vmi <vm-name> -n <namespace> -o jsonpath='{.status.conditions[?(@.type=="Paused")]}'
```

If the VMI is `Paused` with `reason: PausedIOError`, treat this as a
potential real incident (see `docs/odf/CBT-EXPLAINED.md` §8) — do not just
retry. Check what pods currently have a PVC mounted
(`oc get pod <launcher> -o jsonpath='{.spec.volumes}'`) before creating any
new pod that might mount the same or an adjacent PVC on the same node.

## Step 7 — Optional: re-check evidence standalone (the "post-chaos" pattern)

To demonstrate the check can be re-run without redoing backups (the shape a
real chaos test needs):

```bash
make cbt-evidence VMS=<vm-name>
```

## Step 8 — Cleanup

Ask the user whether to tear down. Only if they confirm (or the VM pool was
created fresh in this session for a one-off smoke test and they said so
upfront):

```bash
make density-teardown
```

Never run `density-teardown` against a namespace/pool you didn't create or
weren't explicitly told to remove.

## Reporting back to the user

End with a compact summary:

- What was created (namespace, VM name(s))
- Full backup: PASS/FAIL + physical evidence
- Incremental backup: PASS/FAIL + physical evidence
- Verify: PASS/FAIL (VM health, backup evidence, guest workload integrity)
- Any anomalies found and what you checked before ruling them in/out
- Whether the pool was torn down or left running, and why
