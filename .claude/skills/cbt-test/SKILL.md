---
name: cbt-test
description: >
  End-to-end test runner for the ODF CBT Fedora VM validator: create a VM
  pool, run cbt-cycle (marker rewrite → Full → append → Incremental →
  guest+qcow2 verify → restore-hash), then analyze results using physical
  qcow2-header evidence (never VirtualMachineBackup.status) to confirm CBT
  genuinely worked. Produces a clear pass/fail summary with the supporting
  evidence. Use when the user wants to test, exercise, or demonstrate this
  repo's CBT workflow end-to-end — e.g. "test this workflow", "run the CBT
  pipeline", "create a VM and verify CBT backups", "demo CBT backup",
  "run e2e test", "cbt-test". Also use after making changes to
  scripts/odf-vm-validator.sh, scripts/cbt-evidence-check.sh, or the
  kube-burner templates, to confirm the change didn't break the pipeline.
compatibility: >
  Requires oc, virtctl, kube-burner, jq, bash 4+, and KUBECONFIG access to
  an OpenShift + ODF cluster. On macOS, put /opt/homebrew/bin ahead of /bin
  in PATH (system bash is 3.2).
---

# CBT End-to-End Test Runner

You run the full VM-creation → CBT cycle (marker → Full → append →
Incremental → verify → restore-hash) → result-analysis pipeline for this
repo's ODF CBT validator, against a real OpenShift + ODF cluster, and
report back a clear pass/fail with evidence — not just "the command exited
0".

You are **interactive** for anything that touches cluster state destructively
(picking a namespace, tearing down an existing pool, `backup-reset`) —
confirm with the user before doing anything that could disrupt VMs or data
they didn't ask you to touch. You are **not** interactive for the
read-only/setup steps (checking prerequisites, reading config) — just do
those.

## Before you start: read the ground truth

Read these once at the start of a session, don't re-derive them:

- `README.md` — what each `make` target creates and where.
- `docs/cbt/CBT-EXPLAINED.md` §5 (layers / files / restore overview),
  §7–§8 (header-based verification + chaos fit), and §10 (never mount the
  live CBT-overlay/state PVC into a second pod while the VM is running).
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
  you to touch: **stop and ask** whether to reuse it (run `backup-reset`
  then `cbt-cycle` against existing VMs), or tear it down and recreate. Do
  not silently delete someone else's test data.
- If the namespace doesn't exist or is empty, proceed.

## Step 2 — Prefer the all-in-one cycle

For a fresh pool, prefer:

```bash
make e2e N=1        # density-setup + cbt-cycle; ask if user wants N>1
```

Or, if the pool already exists and backups need clearing:

```bash
make backup-reset N=1   # confirm with user first
make cbt-cycle N=1
```

`cbt-cycle` per VM: rewrite `/data/vm-validator/cbt-marker.bin` (hash0) →
Full (qcow2 evidence) → append (hash1) → Incremental (qcow2 evidence) →
`verify` (SQLite + both evidence checks) → restore Full+Inc onto a
temporary restore VM and require `restored_hash == hash1` → clean restore
resources. Sizes come from `RESTORE_PROOF_BASE_MIB` /
`RESTORE_PROOF_APPEND_MIB`.

If you need to walk the steps manually instead of `e2e`/`cbt-cycle`:

```bash
make density-setup N=1
make density-status
make backup VMS=<vm-name>
# mutate guest, then:
make cbt-backup VMS=<vm-name>
make verify VMS=<vm-name>
```

Report back: namespace, VM name(s) (`<VM_PREFIX>-1` .. `-N`, 1-indexed),
`ready=true` / `changedBlockTracking.state=Enabled`, and cycle result.

If a Full backup already exists and `cbt-cycle` fails asking for
`backup-reset`, ask the user before clearing backups — never auto-reset.

## Step 3 — Result analysis

Do not just say "e2e/cbt-cycle passed". Pull the actual evidence and summarize:

```bash
make report                                          # newest summary.json
r=$(ls -t reports | head -1); echo "$r"
cat "reports/$r/summary.json"
cat "reports/$r/evidence/"*.json 2>/dev/null
```

For each backup, report: `physicalType` vs `expectedType` (must match),
`backingFile` (empty for Full, CBT-overlay path for Incremental),
`allocatedDataBytes` if present. From the cycle evidence JSON, report
`hash0`, `hash1`, `restoredHash`, and `match`. Explicitly state that Full
vs Incremental evidence was read from the qcow2 file itself, not from
`VirtualMachineBackup.status` — that's the point of this whole pipeline.

If SSH fails with `REMOTE HOST IDENTIFICATION HAS CHANGED`, this is expected
after a VM was recreated with the same name — clear just that host's entry:

```bash
ssh-keygen -R "vm.<vm-name>.<namespace>" -f ~/.ssh/known_hosts
```

If anything failed, don't just report the failure — look at `run.log` in
the same report directory for the actual error, and check VM health before
proposing a fix:

```bash
tail -80 "reports/$r/run.log"
oc get vmi <vm-name> -n <namespace> -o jsonpath='{.status.conditions[?(@.type=="Paused")]}'
```

If the VMI is `Paused` with `reason: PausedIOError`, treat this as a
potential real incident (see `docs/cbt/CBT-EXPLAINED.md` §10) — do not just
retry. Check what pods currently have a PVC mounted
(`oc get pod <launcher> -o jsonpath='{.spec.volumes}'`) before creating any
new pod that might mount the same or an adjacent PVC on the same node.

## Step 4 — Optional: re-check evidence standalone (the "post-chaos" pattern)

To demonstrate the check can be re-run without redoing backups (the shape a
real chaos test needs):

```bash
make cbt-evidence VMS=<vm-name>
```

## Step 5 — Cleanup

Ask the user whether to tear down. Only if they confirm (or the VM pool was
created fresh in this session for a one-off smoke test and they said so
upfront):

```bash
make density-teardown
```

Never run `density-teardown` against a namespace/pool you didn't create or
weren't explicitly told to remove. Prefer `backup-reset` + `cbt-cycle` when
the user only wants another CBT cycle on the same VMs.

## Reporting back to the user

End with a compact summary:

- What was created or reused (namespace, VM name(s))
- Full backup: PASS/FAIL + physical evidence
- Incremental backup: PASS/FAIL + physical evidence
- Verify: PASS/FAIL (VM health, backup evidence, guest workload integrity)
- Restore-hash: PASS/FAIL (`restoredHash` vs `hash1`)
- Any anomalies found and what you checked before ruling them in/out
- Whether the pool was torn down, left running, or reset for another cycle
