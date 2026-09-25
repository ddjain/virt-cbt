# CBT-V3-05 — Backup-output PVC near-full

> **Plan:** [`../chaos_scenario_v3.md`](../chaos_scenario_v3.md)  
> **Shared snippets:** [`../_common.md`](../_common.md)  
> **Evidence rule:** Full vs Incremental pass/fail = qcow2 `backing-filename` via `make cbt-evidence` — not `VirtualMachineBackup.status.type` alone.


## 1. Metadata

| Field | Value |
|---|---|
| **Scenario ID** | `CBT-V3-05` |
| **Priority** | P1 |
| **Krkn scenario** | `pvc-scenarios` |
| **Target component** | `$BACKUP_PVC` (`$VM-backup-output`) Push sink only |
| **Inject window** | `T-PRE (+ optional early T-PROG)` — fill before VMB create; or early Progressing if PVC already mounted via hotplug |
| **Blast radius** | Low–Medium |
| **Folder** | `docs/chaos-test/scenario/cbt-05-backup-pvc-fill/` |

## 2. Objective

Verify Push backup fails cleanly when the destination cannot accept the payload; no false checkpoint; PVC reusable after Krkn cleanup.

## 3. Traceability

- Catalog: `docs/chaos-test/chaos_scenario_v3.md` → `CBT-V3-05`
- Architecture: `docs/cbt/CBT-ARCHITECTURE.md`
- Components / inject window: `docs/cbt/CBT-COMPONENT-DEPENDENCIES.md`
- Evidence / safety: `docs/cbt/CBT-EXPLAINED.md`, `AGENTS.md`
- Krkn docs (local): `../../krkn-chaos/website/content/en/docs/scenarios/pvc-scenario/`
- Campaign dependency: baseline healthy Full + Incremental + `cbt-evidence` before chaos; run **CBT-V3-11** after any interrupt

## 4. Target and inject window

| Item | Detail |
|---|---|
| **Component under test** | `$BACKUP_PVC` (`$VM-backup-output`) Push sink only |
| **Why this component** | Capacity errors on the sink are a common real failure; CBT must not claim success. |
| **When to inject** | `T-PRE (+ optional early T-PROG)` — fill before VMB create; or early Progressing if PVC already mounted via hotplug |
| **When NOT to inject** | Against `$VM-data` or `persistent-state-for-*` while VM is running. |
| **Backup modes to repeat** | Before Full; before Incremental (separate runs) |

## 5. Risk / blast radius

Fills only the backup-output volume. Must not target data or CBT state PVCs while VM runs.

## 6. Preconditions

1. Disposable OpenShift cluster with OpenShift Virtualization + ODF Ceph-RBD.
2. Validator namespace with CBT-enabled Fedora VM, tracker, data/state/backup-output PVCs (`runStrategy: Always`).
3. `incrementalBackup` feature gate + CBT label selector matching the VM.
4. Baseline: CBT `Enabled`; VM/VMI Running; PVCs Bound; ODF Ready; no other VMB Progressing.
5. Baseline Full and Incremental already proven with `make cbt-evidence` (record checkpoint names).
6. Guest write workload active under `/data/vm-validator`.
7. `krknctl run pvc-scenarios --help` reviewed for this Krkn release.
8. No scenario-specific extra preconditions.

## 7. Test environment

| Item | Example / resolve at run time |
|---|---|
| Namespace | `$NS` |
| VM / VMI | `$VM` |
| Tracker | `$TRACKER` (`$VM-tracker`) |
| Backup PVC | `$BACKUP_PVC` (`$VM-backup-output`) |
| Chaos VMB | `$VMB_CHAOS` (unique per run) |
| Resolved target | PVC `$BACKUP_PVC` mounted by launcher (T-PROG) or helper (if using T-PRE strategy) |
| KUBECONFIG | disposable cluster kubeconfig |

Load shared env from [`_common.md`](../_common.md).

## 8. Procedure

Follow phases **A → B → C → D → E** in order. **C is mandatory:** if chaos did not hit the intended component inside the intended window, stop and mark the run invalid — do not interpret CBT results.

### 8.1 Phase A — Arm backup window (timing gate)

See [`_common.md` Phase A](../_common.md). For this scenario:

**T-PRE:** Ensure backup PVC Bound. PVC scenario requires the PVC mounted by a pod — use Progressing hotplug **or** a documented short-lived mounter that is **not** dual-attaching data/state. Prefer starting VMB, wait until volume attached, then fill (early T-PROG) if T-PRE mount is unsafe.
**Never** fill data/state PVCs.

Record `INJECT_WINDOW_OPEN` timestamp and VMB conditions JSON.

### 8.2 Phase B — Inject chaos (krknctl preferred; event-driven)

### Event-driven injection (preferred)

Prefer **Krkn event-driven triggers** over sleep / fixed `wait_duration` timing whenever it makes sense — especially for `T-PROG` (wait until `VirtualMachineBackup` has `Progressing=True`, then inject; use `on_timeout: fail` so a missed window fails the run instead of injecting late).

**Engine policy:** prefer **`krknctl`**. Use native **`oc` / `kubectl`** only when krknctl is awkward or cannot express the fault cleanly (document which path you used in the run log).

**Reproducible script (future):** each scenario folder will get its own `chaos-trigger.sh` beside this `scenario_spec.md` (same directory). Do not put a shared trigger under `scripts/` for these V3 scenarios — keep inject logic local to the scenario so it stays easy to find and reproduce.


Always confirm flags with `--help` first:

```bash
krknctl run pvc-scenarios --help
```

**Example stub** (adjust selectors/names to the resolved target; pin versions in the run log):

```bash
# PVC must be Bound and mounted. Prefer targeting backup-output during/after hotplug.
krknctl run pvc-scenarios \
  --namespace "$NS" \
  --pvc-name "$BACKUP_PVC" \
  --fill-percentage 95 \
  --duration 120

# If both pvc-name and pod-name set, pvc-name wins (website).
```

Krkn deletes the temp fill file after `--duration`. Verify free space on the filesystem, not only PVC phase.

Record Krkn start/end wall time and the exact command line.

### 8.3 Phase C — Validate chaos injected on the correct component at the correct time

**Gate:** all checks below must pass before grading CBT.

1. Confirm fill file landed on **backup-output** mount (not data/state).
2. `df` / events show capacity pressure on that volume.
3. Timing matches T-PRE or early T-PROG as planned.
4. No second mount of data/state PVCs introduced by the test harness.

Shared timing checks: [`_common.md` Phase C](../_common.md).

| Check | Pass if |
|---|---|
| Timing | Inject started after `INJECT_WINDOW_OPEN` and before VMB terminal (for `T-PROG`) — or matches documented `T-GAP` / `T-PRE` / `T-POST` |
| Target | Observed disrupted object matches the resolved target identity |
| Scope | No unintended pods/nodes/PVCs disrupted |

If any row fails → **INVALID RUN** (do not pass/fail CBT).

### 8.4 Phase D — Validate CBT backup data (corrupt vs correct)

After the chaos VMB reaches a **terminal** condition (or known failure), and after any required follow-up backup:

1. Chaos VMB should **fail** with clear capacity/write error (or equivalent condition).
2. Tracker must **not** advance as successful.
3. After Krkn cleanup restores space: fresh backup + `cbt-evidence` succeeds.
4. No truncated payload accepted as success.

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

Confirm fill file gone; backup PVC Bound and reusable; V3-11 if VMB stuck.

Then run **CBT-V3-11** if the VMB was interrupted or stuck.

## 9. Expected results

Explicit capacity failure; no false checkpoint; after cleanup, backup chain works; evidence clean on retry.

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
- Fill targeted wrong PVC

## 12. Safety notes

- **Only** `$BACKUP_PVC`.\n- Do not fill data or persistent-state-for-* while VM runs.

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
