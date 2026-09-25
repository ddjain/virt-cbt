# CBT V3 chaos scenario specs

Per-scenario folders derived from [`../chaos_scenario_v3.md`](../chaos_scenario_v3.md).
Each folder contains a `scenario_spec.md` with the same section layout:

1. Metadata  
2. Objective  
3. Traceability  
4. Target and inject window  
5. Risk / blast radius  
6. Preconditions  
7. Test environment  
8. Procedure — **A** arm window → **B** inject (`krknctl`) → **C** validate correct target/time → **D** CBT evidence → **E** cleanup  
9–14. Expected / pass / fail / safety / evidence / execution log  

Shared timing and evidence helpers: [`_common.md`](_common.md)  
Section template: [`_TEMPLATE.md`](_TEMPLATE.md)

| ID | Folder | Krkn | Window | Priority |
|---|---|---|---|---|
| `CBT-V3-01` | [`cbt-01-virt-controller-pod-kill/scenario_spec.md`](cbt-01-virt-controller-pod-kill/scenario_spec.md) | `pod-scenarios` | `T-PROG` | P2 |
| `CBT-V3-02` | [`cbt-02-virt-handler-pod-kill/scenario_spec.md`](cbt-02-virt-handler-pod-kill/scenario_spec.md) | `pod-scenarios` | `T-PROG` | P1 |
| `CBT-V3-03` | [`cbt-03-kubevirt-vmi-outage/scenario_spec.md`](cbt-03-kubevirt-vmi-outage/scenario_spec.md) | `kubevirt-outage` | `T-PROG (+ optional T-GAP)` | P0 |
| `CBT-V3-04` | [`cbt-04-container-signal/scenario_spec.md`](cbt-04-container-signal/scenario_spec.md) | `container-scenarios` | `T-PROG` | P2 |
| `CBT-V3-05` | [`cbt-05-backup-pvc-fill/scenario_spec.md`](cbt-05-backup-pvc-fill/scenario_spec.md) | `pvc-scenarios` | `T-PRE (+ optional early T-PROG)` | P1 |
| `CBT-V3-06` | [`cbt-06-storage-throttle/scenario_spec.md`](cbt-06-storage-throttle/scenario_spec.md) | `storage-throttle` | `T-PROG` | P1 |
| `CBT-V3-07` | [`cbt-07-csi-rbd-nodeplugin/scenario_spec.md`](cbt-07-csi-rbd-nodeplugin/scenario_spec.md) | `pod-scenarios` | `T-PROG` | P2 |
| `CBT-V3-08` | [`cbt-08-network-control-storage/scenario_spec.md`](cbt-08-network-control-storage/scenario_spec.md) | `network-chaos / pod-network-scenario / network-chaos-ng` | `T-PROG` | P3 |
| `CBT-V3-08b` | [`cbt-08b-vmi-guest-network/scenario_spec.md`](cbt-08b-vmi-guest-network/scenario_spec.md) | `vmi-network` | `T-PROG or T-GAP / guest verify window` | P3 (optional) |
| `CBT-V3-09` | [`cbt-09-node-resource-hog/scenario_spec.md`](cbt-09-node-resource-hog/scenario_spec.md) | `node-cpu-hog | node-memory-hog | node-io-hog` | `T-PROG` | P3 |
| `CBT-V3-10` | [`cbt-10-vmi-node-failure/scenario_spec.md`](cbt-10-vmi-node-failure/scenario_spec.md) | `node-scenarios` | `T-PROG (+ optional T-GAP)` | P3 (high blast — late in campaign) |
| `CBT-V3-11` | [`cbt-11-interrupted-backup-cleanup/scenario_spec.md`](cbt-11-interrupted-backup-cleanup/scenario_spec.md) | `none (procedure)` | `T-POST` | Gate (after every interrupt) |
| `CBT-V3-12` | [`cbt-12-live-migration-vs-backup/scenario_spec.md`](cbt-12-live-migration-vs-backup/scenario_spec.md) | `none primary (VirtualMachineInstanceMigration); Krkn optional for observation` | `before backup | T-PROG | after terminal` | P2 |
| `CBT-V3-13` | [`cbt-13-time-skew/scenario_spec.md`](cbt-13-time-skew/scenario_spec.md) | `time-scenarios` | `T-GAP and separately T-PROG` | P4 |

## Execution order (from catalog)

1. Baseline Full + Incremental + `cbt-evidence` (no chaos)
2. V3-03 → V3-02 → V3-05/06 → V3-01/04 → V3-07 → V3-08 (+ optional 08b) → V3-09 → V3-12 → V3-10 → V3-13
3. **V3-11** after every interrupted run

## Rule of thumb

**Phase C fail ⇒ stop.** Do not grade CBT if chaos missed the component or the inject window.
**Phase D** uses `make cbt-evidence` (qcow2 `backing-filename`), not VMB status alone.

## Event-driven inject + `chaos-trigger.sh`

Prefer **Krkn event-driven triggers** (e.g. wait for VMB `Progressing=True`,
`on_timeout: fail`) over sleep-based timing wherever it makes sense. Prefer
**`krknctl`**; fall back to **`oc`/`kubectl`** only when krknctl is a poor fit.

Each scenario folder gets its own **`chaos-trigger.sh`** beside
`scenario_spec.md` (same directory). No shared `scripts/chaos-trigger.sh` for
these scenarios — keep inject logic with the scenario that owns it.

To generate and run a trigger against a live cluster, use the
**`cbt-chaos-test`** skill (`.claude/skills/cbt-chaos-test/`):

```text
cbt-chaos-test cbt-01
```

It reads the matching `scenario_spec.md`, resolves cluster targets, builds
the `krknctl` command via the `krkn-scenario` subskill, asks for a short
approval, writes `chaos-trigger.sh`, then executes against a CBT backup and
grades with `make cbt-evidence`.
