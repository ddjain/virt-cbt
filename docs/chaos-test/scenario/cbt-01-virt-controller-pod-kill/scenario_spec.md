# CBT-V3-01 — virt-controller pod kill mid-backup

> **Plan:** [`../chaos_scenario_v3.md`](../chaos_scenario_v3.md)  
> **Shared snippets:** [`../_common.md`](../_common.md)  
> **Evidence rule:** Full vs Incremental pass/fail = qcow2 `backing-filename` via `make cbt-evidence` — not `VirtualMachineBackup.status.type` alone.


## 1. Metadata

| Field | Value |
|---|---|
| **Scenario ID** | `CBT-V3-01` |
| **Priority** | P2 |
| **Krkn scenario** | `pod-scenarios` |
| **Target component** | `virt-controller` Deployment pod(s) in `$CNV_NS` |
| **Inject window** | `T-PROG` — while chaos VMB has Progressing=True; run once for Full and once for Incremental |
| **Blast radius** | Medium |
| **Folder** | `docs/chaos-test/scenario/cbt-01-virt-controller-pod-kill/` |

## 2. Objective

Prove that losing the backup control-plane reconciler mid-Push does not corrupt the VMB/VMBT chain, leave stuck finalizers, or produce a silent false Incremental.

## 3. Traceability

- Catalog: `docs/chaos-test/chaos_scenario_v3.md` → `CBT-V3-01`
- Architecture: `docs/cbt/CBT-ARCHITECTURE.md`
- Components / inject window: `docs/cbt/CBT-COMPONENT-DEPENDENCIES.md`
- Evidence / safety: `docs/cbt/CBT-EXPLAINED.md`, `AGENTS.md`
- Krkn docs (local): `../../krkn-chaos/website/content/en/docs/scenarios/pod-scenarios/`
- Campaign dependency: baseline healthy Full + Incremental + `cbt-evidence` before chaos; run **CBT-V3-11** after any interrupt

## 4. Target and inject window

| Item | Detail |
|---|---|
| **Component under test** | `virt-controller` Deployment pod(s) in `$CNV_NS` |
| **Why this component** | virt-controller owns VirtualMachineBackup / Tracker reconcile. Mid-flight death can stall Progressing or drop checkpoint updates. |
| **When to inject** | `T-PROG` — while chaos VMB has Progressing=True; run once for Full and once for Incremental |
| **When NOT to inject** | During Attach-only (Initializing, Progressing=False) or after Done=True. |
| **Backup modes to repeat** | Full @ T-PROG; Incremental @ T-PROG (separate runs) |

## 5. Risk / blast radius

Single controller replica kill. Deployment recreates it. Do **not** delete all replicas. Control-plane reconcile impact only; no intentional data-plane wipe.

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
| Resolved target | One `virt-controller-*` pod name + restart count before/after |
| KUBECONFIG | disposable cluster kubeconfig |

Load shared env from [`_common.md`](../_common.md).

## 8. Procedure

Follow phases **A → B → C → D → E** in order. **C is mandatory:** if chaos did not hit the intended component inside the intended window, stop and mark the run invalid — do not interpret CBT results.

### 8.1 Phase A — Arm backup window (timing gate)

See [`_common.md` Phase A](../_common.md). For this scenario:

Create `$VMB_CHAOS` Push backup. Wait for **Progressing=True**. Do not inject earlier.

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
# Resolve one controller pod (example label — confirm on cluster):
CTRL_POD=$(oc get pod -n "$CNV_NS" -l kubevirt.io=virt-controller -o jsonpath='{.items[0].metadata.name}')
echo "TARGET=$CTRL_POD"

krknctl run pod-scenarios \
  --namespace "$CNV_NS" \
  --name-pattern "^${CTRL_POD}$" \
  --disruption-count 1 \
  --kill-timeout 180 \
  --expected-recovery-time 120 \
  --execution serial
```

Prefer `--name-pattern` for a single named pod over broad `openshift-.*`. Confirm label `kubevirt.io=virt-controller` exists on your build.

Record Krkn start/end wall time and the exact command line.

### 8.3 Phase C — Validate chaos injected on the correct component at the correct time

**Gate:** all checks below must pass before grading CBT.

1. Before inject: `oc get pod "$CTRL_POD" -n "$CNV_NS" -o jsonpath='{.status.containerStatuses[0].restartCount}'` and UID.
2. During/after Krkn: pod deleted or restarted; new UID or restartCount++.
3. Confirm **only** that controller pod was targeted (sibling replicas untouched if possible).
4. Confirm VMB still Progressing (or left Progressing within seconds of inject) — dump conditions with timestamps.
5. Krkn telemetry: recovery within `--expected-recovery-time` or documented failure.

Shared timing checks: [`_common.md` Phase C](../_common.md).

| Check | Pass if |
|---|---|
| Timing | Inject started after `INJECT_WINDOW_OPEN` and before VMB terminal (for `T-PROG`) — or matches documented `T-GAP` / `T-PRE` / `T-POST` |
| Target | Observed disrupted object matches the resolved target identity |
| Scope | No unintended pods/nodes/PVCs disrupted |

If any row fails → **INVALID RUN** (do not pass/fail CBT).

### 8.4 Phase D — Validate CBT backup data (corrupt vs correct)

After the chaos VMB reaches a **terminal** condition (or known failure), and after any required follow-up backup:

1. Wait for chaos VMB terminal (Done=True **or** explicit Failed condition).
2. If completed: run `cbt-evidence` on that artifact; confirm type matches header.
3. If failed: confirm tracker did **not** advance to an unverified checkpoint.
4. Run a **follow-up** backup on the same tracker; evidence must show Incremental (if checkpoint committed) or explained Full.
5. Confirm no stuck `backup.kubevirt.io/vmbackup-protection` finalizer on a dead-end object.

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

Ensure virt-controller Deployment has desired Ready replicas. Delete failed chaos VMB if needed after diagnostics. Proceed to V3-11 if interrupted.

Then run **CBT-V3-11** if the VMB was interrupted or stuck.

## 9. Expected results

Replacement controller Ready. Chaos VMB completes or fails explicitly (never indefinite Progressing). Tracker advances only on valid completion. Follow-up backup: Incremental with correct `backing-filename`, or explained Full. No unrelated CBT VM regression.

## 10. Pass criteria

- [ ] Phase C passed (correct component + correct time)
- [ ] VMB reached terminal state (success **or** explicit failure — not eternal Progressing)
- [ ] Tracker advanced only on valid completion
- [ ] Follow-up / chaos artifact qcow2 evidence matches expected mode (Incremental header **or** explained Full)
- [ ] No silent Incremental without `backing-filename`
- [ ] VM/VMI Running, CBT `Enabled` after recovery (post any required restart)
- [ ] Backup-output PVC reusable / detached correctly
- [ ] Blast radius within declared scope


## 11. Fail criteria

- Chaos missed target or wrong inject window (invalid), or operator still graded it
- Silent data loss / truncated “success”
- False Incremental (status or tracker without qcow2 proof)
- Stale finalizer / stuck Progressing / orphaned RWO attach
- Unrecovered VMI or unexplained Full fallback
- Inability to reverse the injected fault


## 12. Safety notes

- Kill **one** replica only.\n- Do not combine with node or Ceph chaos in the same run.

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
