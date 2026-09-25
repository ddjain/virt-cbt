---
name: cbt-chaos-test
description: >
  Run one CBT V3 chaos scenario end-to-end against a live OpenShift + ODF
  cluster: resolve a scenario id (e.g. cbt-01), read its scenario_spec.md,
  discover cluster env, set up Fedora CBT VMs via make if needed, build a
  cluster-correct event-driven krknctl command via the krkn-scenario
  subskill, get a short user approval, write chaos-trigger.sh beside the
  spec, then execute it against a CBT backup and grade with qcow2 evidence.
  Use when the user says "cbt-chaos-test", "cbt-chaos-test cbt-01", "run
  chaos scenario cbt-03", "execute CBT-V3-02", "build chaos-trigger for
  cbt-05", or wants to inject Krkn chaos during a CBT Full/Incremental
  backup. Also use after editing docs/chaos-test/scenario/*/scenario_spec.md
  when they want the matching trigger script generated and tested.
compatibility: >
  Requires oc, virtctl, krknctl, jq, bash 4+, kube-burner (for density-setup),
  and KUBECONFIG to an OpenShift + ODF + OpenShift Virtualization cluster.
  On macOS put /opt/homebrew/bin ahead of /bin in PATH. Depends on the
  sibling krkn-scenario skill for flag-accurate krknctl generation.
arguments:
  - name: scenario
    description: >
      Scenario id or folder slug, e.g. cbt-01, CBT-V3-01, cbt-08b,
      or cbt-01-virt-controller-pod-kill
    required: true
---

# CBT Chaos Scenario Runner

You turn a catalog scenario id into a **cluster-correct, user-approved,
reproducible** chaos run against this repo's CBT validator path.

Invocation shapes:

- `cbt-chaos-test cbt-01`
- `cbt-chaos-test CBT-V3-03`
- `run chaos for cbt-08b`

Hard gates (do not skip):

1. **Read the spec before inventing flags.**
2. **Use the `krkn-scenario` skill** to build/validate the `krknctl` command
   (never guess flag names).
3. **Prefer event-driven triggers** over sleep-only timing whenever the
   inject window is `T-PROG` (or otherwise waitable via `oc`/`jq`).
4. **Stop for a 1–2 line user approval** before writing or running the
   trigger.
5. **Evidence = qcow2 header** via `make cbt-evidence` — never
   `VirtualMachineBackup.status.type` alone for Full vs Incremental.
6. **Never** dual-mount a VM data PVC or `persistent-state-for-*` while the
   VM is running (`AGENTS.md`).

## Step 0 — Resolve the scenario folder

Normalize `{{ scenario }}` (or the id in the user message):

| Input forms | Resolve to folder under `docs/chaos-test/scenario/` |
|---|---|
| `cbt-01`, `CBT-01`, `01` | `cbt-01-*` (unique prefix match) |
| `CBT-V3-01`, `cbt-v3-01` | same as `cbt-01` |
| `cbt-08b` | `cbt-08b-vmi-guest-network` |
| full slug `cbt-01-virt-controller-pod-kill` | exact folder |

```bash
ls docs/chaos-test/scenario | grep -E "^cbt-"
```

If zero or multiple matches, stop and ask. Then **read**:

1. `docs/chaos-test/scenario/<folder>/scenario_spec.md` (whole file)
2. `docs/chaos-test/scenario/_common.md` (shared Phase A/C/D + event-driven policy)
3. Catalog row in `docs/chaos-test/chaos_scenario_v3.md` only if the spec is ambiguous

Extract and keep as working facts:

- Scenario ID, priority, Krkn scenario tag, target component
- Inject window (`T-PROG` / `T-GAP` / `T-PRE` / `T-POST`)
- Backup modes to repeat (Full / Incremental)
- Blast radius + safety notes
- Example `krknctl` stub in Phase B (starting point only — not pinned)

Read `references/chaos-trigger-template.md` in this skill when you are about
to write `chaos-trigger.sh`.

## Step 1 — Preflight tools + cluster

Same baseline as `cbt-test`:

```bash
export PATH="/opt/homebrew/bin:$PATH"   # macOS bash 4+
which oc virtctl krknctl jq kube-burner
bash --version
test -f config.env || make init-config
grep -E '^(KUBECONFIG|NAMESPACE|VM_COUNT|VM_PREFIX)=' config.env
export KUBECONFIG=<from config.env>
oc whoami
oc get storagecluster,cephcluster -n openshift-storage
make check-prereqs
command -v krknctl && krknctl list available | head
```

If `KUBECONFIG` / cluster is wrong or prereqs fail, stop and report — do not
install operators or rewrite cluster CBT config to force progress.

Also resolve operator namespaces used by the spec:

```bash
export CNV_NS=${CNV_NS:-openshift-cnv}
export STORAGE_NS=${STORAGE_NS:-openshift-storage}
oc get ns "$CNV_NS" "$STORAGE_NS"
```

## Step 2 — Discover / prepare CBT VM environment

```bash
NS=$(grep -E '^NAMESPACE=' config.env | cut -d= -f2-)
make density-status 2>&1
```

Decide with the user (interactive for anything that creates/deletes pool
state):

| Cluster state | Action |
|---|---|
| Healthy pool, CBT Enabled, user OK to reuse | Use existing `$VM` (`<VM_PREFIX>-1` …); prefer `make backup-reset` only if user confirms and prior backups would confuse the run |
| Empty / missing namespace | `make density-setup N=1` (ask if they want N>1) |
| Pool exists but user wants disposable fresh VMs | Confirm, then teardown + setup — never silent teardown |

Export resolved names (match `_common.md`):

```bash
export NS=<validator-namespace>
export VM=<vm-name>                 # e.g. fedora-cbt-1
export TRACKER=${VM}-tracker
export BACKUP_PVC=${VM}-backup-output
export VMB_CHAOS=${VM}-chaos-$(date +%s)
export KUBECONFIG=...
```

Confirm CBT readiness:

```bash
oc get vm "$VM" -n "$NS" -o jsonpath='{.status.printableStatus}{" cbt="}{.status.changedBlockTracking.state}{"\n"}'
oc get vmi "$VM" -n "$NS" -o jsonpath='{.status.nodeName}{"\n"}'
oc get pvc "$BACKUP_PVC" -n "$NS"
```

If the scenario requires a **baseline Full + Incremental + evidence** first
(most do — see Preconditions), and it is missing:

```bash
make cbt-cycle N=1          # or VMS=$VM after reset
make cbt-evidence VMS="$VM"
```

Do not start chaos on a pool that has never proven a clean Incremental
header unless the user explicitly wants a smoke-only dry run.

## Step 3 — Resolve live inject targets from the cluster

From the spec's target component + Phase B stub, query the **actual**
objects on this cluster (names, labels, nodes). Examples:

```bash
# virt-controller (cbt-01)
oc get pod -n "$CNV_NS" -l kubevirt.io=virt-controller -o wide

# virt-handler on the VMI node (cbt-02)
NODE=$(oc get vmi "$VM" -n "$NS" -o jsonpath='{.status.nodeName}')
oc get pod -n "$CNV_NS" -l kubevirt.io=virt-handler -o wide --field-selector spec.nodeName="$NODE"

# VMI / launcher (cbt-03 / container signal)
oc get vmi "$VM" -n "$NS" -o name
oc get pod -n "$NS" -l kubevirt.io=virt-launcher,vm.kubevirt.io/name="$VM" -o name
```

Record the **exact** target identity you will put in the krknctl command
(pod name, name-pattern, label selector, node name, PVC name, etc.).
If the label from the stub does not exist on this build, stop and fix the
selector from live `oc` output — do not keep a dead stub selector.

## Step 4 — Build krknctl via the `krkn-scenario` subskill

**Mandatory:** read and follow `.claude/skills/krkn-scenario/SKILL.md`
(or `.agents/skills/krkn-scenario/SKILL.md`). Feed it a concrete request that
includes:

- Krkn scenario tag from the CBT spec (e.g. `pod-scenarios`)
- Resolved namespace / name-pattern / labels / node from Step 3
- Blast-radius limits from the spec (e.g. disruption-count 1)
- **Event-driven trigger requirement** when inject window is `T-PROG`
  (and for other windows when a waitable condition exists)

Prefer this trigger pattern (already used by `scripts/run-cbt-krkn-scenario.sh`):

```bash
--triggers-on-timeout fail \
--triggers-timeout 600 \
--triggers-interval 5 \
--trigger-command 'oc get virtualmachinebackup '"$VMB_CHAOS"' -n '"$NS"' -o json | jq -e '\''.status.conditions // [] | any(.[]; .type == "Progressing" and .status == "True")'\''' \
--trigger-expected-rc 0
```

Confirm exact trigger flag names with:

```bash
krknctl run <scenario-tag> --help
```

(Look under `TRIGGERS`. If this krknctl build lacks triggers, say so and
propose the safest fallback — e.g. Phase A wait loop then inject — and still
require user approval.)

For `T-PRE` / `T-GAP` / `T-POST`, do **not** fake a Progressing trigger.
Either:

- arm the correct precondition first, then run krknctl without a Progressing
  trigger, or
- use a different `--trigger-command` that matches the documented window.

Always pass `--kubeconfig "$KUBECONFIG"` explicitly.

Output of this step is a **candidate** `krknctl run …` line with real
cluster values filled in — not placeholders.

## Step 5 — User approval gate (required)

Before writing files or injecting chaos, show **exactly** this short
approval block (1–2 lines of explanation, then the command):

```text
Approval needed for <Scenario ID> (<folder>):
1. What: <one sentence — fault + exact target>
2. When: <one sentence — inject window + event-driven wait condition, or why not>

Proposed command:
```bash
<full krknctl command>
```

Backup mode this run: Full | Incremental
VM / NS: <vm> / <ns>
Reply approve to write chaos-trigger.sh and run, or say what to change.
```

Do **not** proceed past this gate until the user clearly approves
(`approve`, `yes`, `lgtm`, etc.). If they request changes, re-run Step 4
and re-ask.

## Step 6 — Write `chaos-trigger.sh` beside the spec

On approval, create:

`docs/chaos-test/scenario/<folder>/chaos-trigger.sh`

Requirements:

- Lives **next to** `scenario_spec.md` (never a shared `scripts/chaos-trigger.sh`
  for these scenarios — see `_common.md`)
- `#!/usr/bin/env bash`, `set -euo pipefail`
- Uses env vars (`NS`, `VM`, `VMB_CHAOS`, `KUBECONFIG`, `CNV_NS`, …) with
  documented defaults from `config.env` where sensible
- Creates / applies the chaos `VirtualMachineBackup` (or documents the
  make/oc path used), waits via **event-driven** krknctl when applicable
- Runs the approved `krknctl` command
- Logs timestamps, exact command, and resolved target to stdout
- `chmod +x`
- Follow `references/chaos-trigger-template.md`

Do not commit secrets into the script; read `KUBECONFIG` from the
environment / `config.env`.

## Step 7 — Execute against CBT backup + grade

Recommended order (align with spec Phases A→E):

1. **Arm:** ensure unique `$VMB_CHAOS`; create Push backup toward
   `$BACKUP_PVC` / tracker (script should do this, or call into make/oc
   helpers the script wraps).
2. **Inject:** run `./chaos-trigger.sh` from the scenario folder (or with
   env exported). Prefer the script owning both arm + krknctl so the trigger
   condition can see the VMB.
3. **Phase C:** verify correct target + correct time (restartCount/UID,
   node, etc.). If Phase C fails → **INVALID RUN** — stop; do not pass/fail
   CBT.
4. **Wait terminal:** Done/Complete/Failed on `$VMB_CHAOS`.
5. **Phase D:**

```bash
make cbt-evidence VMS="$VM"
```

   Optionally `make verify VMS="$VM"` as guest liveness only.
6. **Cleanup / V3-11:** if interrupted or stuck, follow
   `cbt-11-interrupted-backup-cleanup` before leaving the cluster dirty.
7. If the spec says repeat for Full **and** Incremental, ask before the
   second mode (or run both only when the user asked for a full matrix).

Reuse patterns from `scripts/run-cbt-krkn-scenario.sh` for trigger +
terminal wait, but keep the scenario-local script as the user-facing
artifact.

## Step 8 — Report

Compact summary:

- Scenario ID + folder + Krkn tag
- Cluster / NS / VM / resolved target
- Approved command (or path to `chaos-trigger.sh`)
- Phase C: PASS / FAIL / INVALID
- Chaos VMB terminal state
- `cbt-evidence`: physicalType vs expected, backing-filename
- Follow-up backup result if required by spec
- Whether Full and/or Incremental modes were covered
- Leftover objects / cleanup done or still needed

## Safety reminders

- Confirm before `density-teardown`, `backup-reset`, or killing anything
  outside the declared blast radius.
- Kill **one** virt-controller replica for cbt-01 — never all.
- High-blast scenarios (node failure, storage fill) need an extra explicit
  confirm even after the Step 5 approve if the user might not have noticed
  priority/blast notes.
- Evidence inspector may mount **backup-output only**, preferably off the
  VMI node.
