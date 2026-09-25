# CBT-V3-03 — virt-launcher / VMI outage mid-backup

> **Plan:** [`../chaos_scenario_v3.md`](../chaos_scenario_v3.md)  
> **Shared snippets:** [`../_common.md`](../_common.md)  
> **Evidence rule:** Full vs Incremental pass/fail = qcow2 `backing-filename` via `make cbt-evidence` — not `VirtualMachineBackup.status.type` alone.


## 1. Metadata

| Field | Value |
|---|---|
| **Scenario ID** | `CBT-V3-03` |
| **Priority** | P0 |
| **Krkn scenario** | `kubevirt-outage` |
| **Target component** | VMI / `virt-launcher` / QEMU (dirty bitmap owner) |
| **Inject window** | `T-PROG (+ optional T-GAP)` — primary: Progressing=True; optional: crash between Full terminal and Incremental create |
| **Blast radius** | Medium |
| **Folder** | `docs/chaos-test/scenario/cbt-03-kubevirt-vmi-outage/` |

## 2. Objective

Validate crash recovery when QEMU disappears mid-backup: no success without a valid checkpoint; follow-up chain is Incremental or safe Full with qcow2 proof.

## 3. Traceability

- Catalog: `docs/chaos-test/chaos_scenario_v3.md` → `CBT-V3-03`
- Architecture: `docs/cbt/CBT-ARCHITECTURE.md`
- Components / inject window: `docs/cbt/CBT-COMPONENT-DEPENDENCIES.md`
- Evidence / safety: `docs/cbt/CBT-EXPLAINED.md`, `AGENTS.md`
- Krkn docs (local): `../../krkn-chaos/website/content/en/docs/scenarios/kubevirt-outage/`
- Campaign dependency: baseline healthy Full + Incremental + `cbt-evidence` before chaos; run **CBT-V3-11** after any interrupt

## 4. Target and inject window

| Item | Detail |
|---|---|
| **Component under test** | VMI / `virt-launcher` / QEMU (dirty bitmap owner) |
| **Why this component** | Dirty bitmaps live with QEMU/virt-launcher; VMI delete is the strongest CBT signal. |
| **When to inject** | `T-PROG (+ optional T-GAP)` — primary: Progressing=True; optional: crash between Full terminal and Incremental create |
| **When NOT to inject** | Against a VM with runStrategy Manual without a recovery plan; against multiple VMIs in one run for the first pass. |
| **Backup modes to repeat** | Incremental @ T-PROG (first); Full @ T-PROG; optional T-GAP crash |

## 5. Risk / blast radius

Deletes one VMI. `runStrategy: Always` should recreate it. Classic CBT bitmap invalidate case.

## 6. Preconditions

1. Disposable OpenShift cluster with OpenShift Virtualization + ODF Ceph-RBD.
2. Validator namespace with CBT-enabled Fedora VM, tracker, data/state/backup-output PVCs (`runStrategy: Always`).
3. `incrementalBackup` feature gate + CBT label selector matching the VM.
4. Baseline: CBT `Enabled`; VM/VMI Running; PVCs Bound; ODF Ready; no other VMB Progressing.
5. Baseline Full and Incremental already proven with `make cbt-evidence` (record checkpoint names).
6. Guest write workload active under `/data/vm-validator`.
7. `krknctl run kubevirt-outage --help` reviewed for this Krkn release.
8. No scenario-specific extra preconditions.

## 7. Test environment

| Item | Example / resolve at run time |
|---|---|
| Namespace | `$NS` |
| VM / VMI | `$VM` |
| Tracker | `$TRACKER` (`$VM-tracker`) |
| Backup PVC | `$BACKUP_PVC` (`$VM-backup-output`) |
| Chaos VMB | `$VMB_CHAOS` (unique per run) |
| Resolved target | VMI `$VM` in `$NS` |
| KUBECONFIG | disposable cluster kubeconfig |

Load shared env from [`_common.md`](../_common.md).

## 8. Procedure

Follow phases **A → B → C → D → E** in order. **C is mandatory:** if chaos did not hit the intended component inside the intended window, stop and mark the run invalid — do not interpret CBT results.

### 8.1 Phase A — Arm backup window (timing gate)

See [`_common.md` Phase A](../_common.md). For this scenario:

For T-PROG: wait Progressing=True. For T-GAP: ensure Full Done; do not start Incremental yet.

Record `INJECT_WINDOW_OPEN` timestamp and VMB conditions JSON.

### 8.2 Phase B — Inject chaos (krknctl preferred; event-driven)

### Event-driven injection (preferred)

Prefer **Krkn event-driven triggers** over sleep / fixed `wait_duration` timing whenever it makes sense — especially for `T-PROG` (wait until `VirtualMachineBackup` has `Progressing=True`, then inject; use `on_timeout: fail` so a missed window fails the run instead of injecting late).

**Engine policy:** prefer **`krknctl`**. Use native **`oc` / `kubectl`** only when krknctl is awkward or cannot express the fault cleanly (document which path you used in the run log).

**Reproducible script (future):** each scenario folder will get its own `chaos-trigger.sh` beside this `scenario_spec.md` (same directory). Do not put a shared trigger under `scripts/` for these V3 scenarios — keep inject logic local to the scenario so it stays easy to find and reproduce.


Always confirm flags with `--help` first:

```bash
krknctl run kubevirt-outage --help
```

**Example stub** (adjust selectors/names to the resolved target; pin versions in the run log):

```bash
# Website / hub: kubevirt-outage (plugin kubevirt_vm_outage). Confirm --help.
krknctl run kubevirt-outage \
  --namespace "$NS" \
  --vm-name "$VM" \
  --timeout 300 \
  --kill-count 1
```

Older notes may say `vmi-outage`; current website entry point is **`kubevirt-outage`**. VMI recovery alone is **not** CBT pass.

Record Krkn start/end wall time and the exact command line.

### 8.3 Phase C — Validate chaos injected on the correct component at the correct time

**Gate:** all checks below must pass before grading CBT.

1. Before: VMI Running; record UID and launcher pod name.
2. After Krkn: VMI deleted then recreated (new UID) within `--timeout`.
3. Confirm inject time vs Progressing (T-PROG) or vs Full-done / no Incremental yet (T-GAP).
4. Krkn must report VMI recovered (or document timeout failure as infra issue).

Shared timing checks: [`_common.md` Phase C](../_common.md).

| Check | Pass if |
|---|---|
| Timing | Inject started after `INJECT_WINDOW_OPEN` and before VMB terminal (for `T-PROG`) — or matches documented `T-GAP` / `T-PRE` / `T-POST` |
| Target | Observed disrupted object matches the resolved target identity |
| Scope | No unintended pods/nodes/PVCs disrupted |

If any row fails → **INVALID RUN** (do not pass/fail CBT).

### 8.4 Phase D — Validate CBT backup data (corrupt vs correct)

After the chaos VMB reaches a **terminal** condition (or known failure), and after any required follow-up backup:

1. Interrupted VMB must **not** be treated as success without valid checkpoint/evidence.
2. After VMI back and CBT Enabled: follow-up backup + `cbt-evidence`.
3. Expect Incremental **or** explained Full (bitmap loss). Status-only Incremental without header = FAIL.
4. Optional: `make verify` once SSH works again — separate from CBT proof.

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

Confirm single Running VMI; cleanup stuck VMB via V3-11; ensure backup PVC not stuck attached to old launcher.

Then run **CBT-V3-11** if the VMB was interrupted or stuck.

## 9. Expected results

VM recreates VMI; CBT Enabled after init/restart; interrupted VMB not silent-success; follow-up Incremental or safe Full with matching qcow2 header.

## 10. Pass criteria

- [ ] Phase C passed (correct component + correct time)
- [ ] VMB reached terminal state (success **or** explicit failure — not eternal Progressing)
- [ ] Tracker advanced only on valid completion
- [ ] Follow-up / chaos artifact qcow2 evidence matches expected mode (Incremental header **or** explained Full)
- [ ] No silent Incremental without `backing-filename`
- [ ] VM/VMI Running, CBT `Enabled` after recovery (post any required restart)
- [ ] Backup-output PVC reusable / detached correctly
- [ ] Blast radius within declared scope
- [ ] VMI recovery time recorded (not used as CBT pass by itself)

## 11. Fail criteria

- Chaos missed target or wrong inject window (invalid), or operator still graded it
- Silent data loss / truncated “success”
- False Incremental (status or tracker without qcow2 proof)
- Stale finalizer / stuck Progressing / orphaned RWO attach
- Unrecovered VMI or unexplained Full fallback
- Inability to reverse the injected fault


## 12. Safety notes

- One VMI at a time.\n- Do not mount state/data PVC during recovery.

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
