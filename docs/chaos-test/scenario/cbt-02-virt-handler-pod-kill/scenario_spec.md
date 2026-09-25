# CBT-V3-02 — virt-handler kill on VMI node mid-backup

> **Plan:** [`../chaos_scenario_v3.md`](../chaos_scenario_v3.md)  
> **Shared snippets:** [`../_common.md`](../_common.md)  
> **Evidence rule:** Full vs Incremental pass/fail = qcow2 `backing-filename` via `make cbt-evidence` — not `VirtualMachineBackup.status.type` alone.


## 1. Metadata

| Field | Value |
|---|---|
| **Scenario ID** | `CBT-V3-02` |
| **Priority** | P1 |
| **Krkn scenario** | `pod-scenarios` |
| **Target component** | `virt-handler` DaemonSet pod on the VMI’s node |
| **Inject window** | `T-PROG` — during active QEMU backup / checkpoint path; Full and Incremental separately |
| **Blast radius** | Medium |
| **Folder** | `docs/chaos-test/scenario/cbt-02-virt-handler-pod-kill/` |

## 2. Objective

Exercise the node agent that drives libvirt/QEMU backup commands and hotplug while a Push backup is Progressing; ensure deterministic terminal state and honest Full/Incremental evidence afterward.

## 3. Traceability

- Catalog: `docs/chaos-test/chaos_scenario_v3.md` → `CBT-V3-02`
- Architecture: `docs/cbt/CBT-ARCHITECTURE.md`
- Components / inject window: `docs/cbt/CBT-COMPONENT-DEPENDENCIES.md`
- Evidence / safety: `docs/cbt/CBT-EXPLAINED.md`, `AGENTS.md`
- Krkn docs (local): `../../krkn-chaos/website/content/en/docs/scenarios/pod-scenarios/`
- Campaign dependency: baseline healthy Full + Incremental + `cbt-evidence` before chaos; run **CBT-V3-11** after any interrupt

## 4. Target and inject window

| Item | Detail |
|---|---|
| **Component under test** | `virt-handler` DaemonSet pod on the VMI’s node |
| **Why this component** | virt-handler talks to QEMU for checkpoints, bitmaps, and backup; highest-signal control-plane-adjacent fault for CBT. |
| **When to inject** | `T-PROG` — during active QEMU backup / checkpoint path; Full and Incremental separately |
| **When NOT to inject** | On a non-VMI node; during Attach-only; against all handlers cluster-wide. |
| **Backup modes to repeat** | Full @ T-PROG; Incremental @ T-PROG |

## 5. Risk / blast radius

Node-local virt-handler only. Other nodes’ handlers untouched. May disrupt CBT checkpoint/hotplug on that node.

## 6. Preconditions

1. Disposable OpenShift cluster with OpenShift Virtualization + ODF Ceph-RBD.
2. Validator namespace with CBT-enabled Fedora VM, tracker, data/state/backup-output PVCs (`runStrategy: Always`).
3. `incrementalBackup` feature gate + CBT label selector matching the VM.
4. Baseline: CBT `Enabled`; VM/VMI Running; PVCs Bound; ODF Ready; no other VMB Progressing.
5. Baseline Full and Incremental already proven with `make cbt-evidence` (record checkpoint names).
6. Guest write workload active under `/data/vm-validator`.
7. `krknctl run pod-scenarios --help` reviewed for this Krkn release.
8. No scenario-specific extra preconditions.

## 7. Test environment

| Item | Example / resolve at run time |
|---|---|
| Namespace | `$NS` |
| VM / VMI | `$VM` |
| Tracker | `$TRACKER` (`$VM-tracker`) |
| Backup PVC | `$BACKUP_PVC` (`$VM-backup-output`) |
| Chaos VMB | `$VMB_CHAOS` (unique per run) |
| Resolved target | `virt-handler-*` pod scheduled on `$VMI_NODE` |
| KUBECONFIG | disposable cluster kubeconfig |

Load shared env from [`_common.md`](../_common.md).

## 8. Procedure

Follow phases **A → B → C → D → E** in order. **C is mandatory:** if chaos did not hit the intended component inside the intended window, stop and mark the run invalid — do not interpret CBT results.

### 8.1 Phase A — Arm backup window (timing gate)

See [`_common.md` Phase A](../_common.md). For this scenario:

Resolve VMI node, then open Progressing window on `$VMB_CHAOS`.

Record `INJECT_WINDOW_OPEN` timestamp and VMB conditions JSON.

### 8.2 Phase B — Inject chaos (krknctl preferred; event-driven)

### Event-driven injection (preferred)

Prefer **Krkn event-driven triggers** over sleep / fixed `wait_duration` timing whenever it makes sense — especially for `T-PROG` (wait until `VirtualMachineBackup` has `Progressing=True`, then inject; use `on_timeout: fail` so a missed window fails the run instead of injecting late).

**Engine policy:** prefer **`krknctl`**. Use native **`oc` / `kubectl`** only when krknctl is awkward or cannot express the fault cleanly (document which path you used in the run log).

**Reproducible script (future):** each scenario folder will get its own `chaos-trigger.sh` beside this `scenario_spec.md` (same directory). Do not put a shared trigger under `scripts/` for these V3 scenarios — keep inject logic local to the scenario so it stays easy to find and reproduce.


Always confirm flags with `--help` first:

```bash
krknctl run pod-scenarios --help
```

**Example stub** (adjust selectors/names to the resolved target; pin versions in the run log):

```bash
VMI_NODE=$(oc get vmi "$VM" -n "$NS" -o jsonpath='{.status.nodeName}')
HANDLER_POD=$(oc get pod -n "$CNV_NS" -l kubevirt.io=virt-handler \
  --field-selector spec.nodeName="$VMI_NODE" -o jsonpath='{.items[0].metadata.name}')
echo "VMI_NODE=$VMI_NODE HANDLER=$HANDLER_POD"

krknctl run pod-scenarios \
  --namespace "$CNV_NS" \
  --name-pattern "^${HANDLER_POD}$" \
  --node-names "$VMI_NODE" \
  --disruption-count 1 \
  --kill-timeout 180 \
  --expected-recovery-time 180
```



Record Krkn start/end wall time and the exact command line.

### 8.3 Phase C — Validate chaos injected on the correct component at the correct time

**Gate:** all checks below must pass before grading CBT.

1. Confirm target pod’s `spec.nodeName` == VMI node before inject.
2. After inject: that handler pod restarting/recreated on **same** node; other nodes’ handlers unchanged.
3. VMB was Progressing at inject time (conditions dump).
4. Watch VMI/launcher events for libvirt/backup errors correlated to handler restart.

Shared timing checks: [`_common.md` Phase C](../_common.md).

| Check | Pass if |
|---|---|
| Timing | Inject started after `INJECT_WINDOW_OPEN` and before VMB terminal (for `T-PROG`) — or matches documented `T-GAP` / `T-PRE` / `T-POST` |
| Target | Observed disrupted object matches the resolved target identity |
| Scope | No unintended pods/nodes/PVCs disrupted |

If any row fails → **INVALID RUN** (do not pass/fail CBT).

### 8.4 Phase D — Validate CBT backup data (corrupt vs correct)

After the chaos VMB reaches a **terminal** condition (or known failure), and after any required follow-up backup:

1. VMB terminal: complete or explicit fail.
2. CBT returns Enabled on VM/VMI after recovery.
3. `cbt-evidence` on completed artifact and/or follow-up backup.
4. Safe Full fallback after bitmap loss is OK **if explained**; Incremental without backing-filename is FAIL.

Use authoritative evidence ([`_common.md` Phase D](../_common.md)):

```bash
make cbt-evidence VMS="$VM"
```

| Signal | Interpretation |
|---|---|
| Incremental qcow2 has correct `backing-filename` | CBT chain intact |
| Full qcow2 has **no** `backing-filename` | Full / safe fallback |
| Status says Incremental but header missing/wrong | **FAIL — corrupt or false mode** |
| Tracker advanced without valid completed backup | **FAIL** |
| Guest `make verify` fails while evidence OK | Guest/net issue — note separately; not automatic CBT fail |

Also capture VMB conditions, finalizers, tracker `latestCheckpoint`, backup PVC attach state.

### 8.5 Phase E — Cleanup / recovery

Wait for virt-handler Ready on VMI node. Run V3-11 if backup interrupted.

Then run **CBT-V3-11** if the VMB was interrupted or stuck.

## 9. Expected results

Handler recreates; VMI Running / CBT Enabled; VMB terminal; next backup Incremental or explained Full; no silent Incremental.

## 10. Pass criteria

- [ ] Phase C passed (correct component + correct time)
- [ ] VMB reached terminal state (success **or** explicit failure — not eternal Progressing)
- [ ] Tracker advanced only on valid completion
- [ ] Follow-up / chaos artifact qcow2 evidence matches expected mode (Incremental header **or** explained Full)
- [ ] No silent Incremental without `backing-filename`
- [ ] VM/VMI Running, CBT `Enabled` after recovery (post any required restart)
- [ ] Backup-output PVC reusable / detached correctly
- [ ] Blast radius within declared scope
- [ ] Handler pod recovered on the same VMI node

## 11. Fail criteria

- Chaos missed target or wrong inject window (invalid), or operator still graded it
- Silent data loss / truncated “success”
- False Incremental (status or tracker without qcow2 proof)
- Stale finalizer / stuck Progressing / orphaned RWO attach
- Unrecovered VMI or unexplained Full fallback
- Inability to reverse the injected fault


## 12. Safety notes

- Only the handler on the VMI node.\n- Do not dual-mount state PVC to "inspect bitmaps" after this fault.

- Never dual-mount data PVC or `persistent-state-for-*` while the VM runs.
- Evidence inspector: backup-output only, prefer off-VMI node.

## 13. Evidence to capture

- Scenario ID, date, operator, cluster, OCP-Virt / KubeVirt / ODF / Krknctl versions
- Exact `krknctl` command + resolved target names
- `INJECT_WINDOW_OPEN`, fault start/end, recovery time
- Phase C screenshots/CLI proofs (pod restarts, VMI delete events, etc.)
- Pre/post VMB + VMBT JSON; `cbt-evidence` output; optional `make verify`
- Cerberus / cluster health if enabled
- Residual objects and cleanup actions

## 14. Execution log

| Run # | Date | Operator | Window | Mode (Full/Inc) | Phase C | CBT evidence | Result | Notes |
|---|---|---|---|---|---|---|---|---|
| | | | | | | | | |
