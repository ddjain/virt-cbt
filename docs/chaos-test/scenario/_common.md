# Shared procedure snippets (CBT V3 scenario specs)

Every `scenario_spec.md` under this tree follows the same phase model and
reuses these snippets. Parameter placeholders assume density-style names;
adjust for your namespace/VM.

## Environment placeholders

```bash
export KUBECONFIG=/path/to/kubeconfig
export NS=<validator-namespace>          # e.g. cbt-demo or density NS
export VM=<vm-name>                      # e.g. fedora-cbt-1
export TRACKER=${VM}-tracker
export BACKUP_PVC=${VM}-backup-output
export VMB_CHAOS=${VM}-chaos-$(date +%s) # unique VMB name per run
export CNV_NS=openshift-cnv              # Virtualization operator NS
export STORAGE_NS=openshift-storage
```

Confirm labels/selectors on your cluster before killing pods:

```bash
oc get deploy -n "$CNV_NS" -l kubevirt.io=virt-controller -o wide
oc get ds -n "$CNV_NS" -l kubevirt.io=virt-handler -o wide
oc get vmi "$VM" -n "$NS" -o jsonpath='{.status.nodeName}{"\n"}'
```

## Phase A — Arm the inject window (`T-PROG`)

1. Ensure no other VMB is Progressing; CBT is `Enabled`; guest writes to `/data`.
2. Create a chaos VMB (Push mode, same tracker as baseline). Wait until
   **`Progressing=True`** before inject:

```bash
# Apply your VirtualMachineBackup CR named $VMB_CHAOS (pvcName=$BACKUP_PVC).
# Then:
until oc get virtualmachinebackup "$VMB_CHAOS" -n "$NS" -o json \
  | jq -e '.status.conditions // [] | any(.[]; .type=="Progressing" and .status=="True")' \
  >/dev/null 2>&1; do
  sleep 2
done
echo "INJECT_WINDOW_OPEN $(date -u +%Y-%m-%dT%H:%M:%SZ)"
# Record: VMB name, checkpointName if set, launcher node, hp-volume pods
```

**Do not inject** while only `Initializing=True` / attach-in-progress unless
the scenario explicitly documents Attach-phase testing.

For `T-GAP`: Full must already be terminal; do **not** create Incremental yet.
For `T-PRE`: run fill/precondition **before** creating the chaos VMB.
For `T-POST`: run after an interrupted VMB reaches terminal or known-stuck.

## Phase C — Generic “did we hit the right thing at the right time?”

Always record:

| Check | How |
|---|---|
| Inject clock | Wall time when Krkn started vs `INJECT_WINDOW_OPEN` |
| VMB still Progressing (or just left it) at inject | `oc get virtualmachinebackup … -o json \| jq '.status.conditions'` |
| Target identity | Exact pod/VMI/node/PVC name from Krkn logs + `oc get` |
| Wrong target? | Fail the run even if CBT later looks fine |

If inject happened outside the intended window → **run invalid**; do not grade CBT.

## Phase D — CBT backup integrity (authoritative)

Do **not** pass/fail Full vs Incremental from `.status.type` alone.

```bash
# After VMB is terminal (Done=True or explicit failure), and/or after follow-up backup:
make cbt-evidence VMS="$VM"
# or: scripts/cbt-evidence-check.sh …
```

| Outcome | qcow2 `backing-filename` |
|---|---|
| Genuine Incremental | `/var/run/kubevirt-private/libvirt/qemu/cbt/datadisk.qcow2` |
| Genuine Full / safe Full fallback | **absent** |
| Corrupt / silent wrong mode | Status says Incremental but header missing or wrong path |

Also check:

```bash
oc get virtualmachinebackup "$VMB_CHAOS" -n "$NS" -o json \
  | jq '{type:.status.type, checkpoint:.status.checkpointName, conditions:.status.conditions, finalizers:.metadata.finalizers}'
oc get virtualmachinebackuptracker "$TRACKER" -n "$NS" -o json \
  | jq '.status.latestCheckpoint'
# Optional guest integrity (alive signal, not CBT proof):
make verify VMS="$VM"
```

**Never** mount `$VM-data` or `persistent-state-for-$VM-*` into a second pod
while the VM is running. Evidence uses **backup-output only**.

## Phase E — Cleanup gate

After any interrupted run, follow
[`cbt-11-interrupted-backup-cleanup/scenario_spec.md`](cbt-11-interrupted-backup-cleanup/scenario_spec.md).

## Krknctl note / event-driven injection

Flags vary by Krkn/Krknctl release. Always:

```bash
krknctl run <scenario> --help
```

Examples in each `scenario_spec.md` are **starting stubs**, not release-pinned
contracts.

**Prefer Krkn event-driven triggers** wherever it makes sense (especially
`T-PROG`): wait for `VirtualMachineBackup` `Progressing=True`, then inject, with
`on_timeout: fail` so a missed window fails the run instead of injecting late.
Avoid sleep-only timing as the sole sync mechanism.

**Engine policy:** prefer **`krknctl`**. Use native **`oc` / `kubectl`** only when
krknctl is awkward or cannot express the fault cleanly.

**Helper:** each scenario directory contains (or gets) its own
`chaos-trigger.sh` next to `scenario_spec.md` (not a shared script under
`scripts/`). Generate/run via the `cbt-chaos-test` skill
(`.claude/skills/cbt-chaos-test/`) — e.g. `cbt-chaos-test cbt-01`.
