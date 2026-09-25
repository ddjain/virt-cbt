# CBT-V3-08 — Network degradation on control or storage path

> **Plan:** [`../chaos_scenario_v3.md`](../chaos_scenario_v3.md)  
> **Shared snippets:** [`../_common.md`](../_common.md)  
> **Evidence rule:** Full vs Incremental pass/fail = qcow2 `backing-filename` via `make cbt-evidence` — not `VirtualMachineBackup.status.type` alone.


## 1. Metadata

| Field | Value |
|---|---|
| **Scenario ID** | `CBT-V3-08` |
| **Priority** | P3 |
| **Krkn scenario** | `network-chaos / pod-network-scenario / network-chaos-ng` |
| **Target component** | Control path (controller↔handler/launcher) **or** node/CSI↔Ceph egress — pick one path per run |
| **Inject window** | `T-PROG` — short fault first, then longer near backup timeout |
| **Blast radius** | Medium–High |
| **Folder** | `docs/chaos-test/scenario/cbt-08-network-control-storage/` |

## 2. Objective

Show bounded retries or deterministic failure under latency/loss, then successful evidence-backed follow-up backup after restore.

## 3. Traceability

- Catalog: `docs/chaos-test/chaos_scenario_v3.md` → `CBT-V3-08`
- Architecture: `docs/cbt/CBT-ARCHITECTURE.md`
- Components / inject window: `docs/cbt/CBT-COMPONENT-DEPENDENCIES.md`
- Evidence / safety: `docs/cbt/CBT-EXPLAINED.md`, `AGENTS.md`
- Krkn docs (local): `../../krkn-chaos/website/content/en/docs/scenarios/network-chaos/`
- Campaign dependency: baseline healthy Full + Incremental + `cbt-evidence` before chaos; run **CBT-V3-11** after any interrupt

## 4. Target and inject window

| Item | Detail |
|---|---|
| **Component under test** | Control path (controller↔handler/launcher) **or** node/CSI↔Ceph egress — pick one path per run |
| **Why this component** | CBT bitmap math is local; control and CSI/Ceph networks can still stall reconcile or Push I/O. |
| **When to inject** | `T-PROG` — short fault first, then longer near backup timeout |
| **When NOT to inject** | Using guest-only `vmi-network` (that is V3-08b); partitioning API/etcd. |
| **Backup modes to repeat** | Full and Incremental @ T-PROG |

## 5. Risk / blast radius

Network impairment on selected node/pods. Keep API reachable for observation. Do not brick etcd.

## 6. Preconditions

1. Disposable OpenShift cluster with OpenShift Virtualization + ODF Ceph-RBD.
2. Validator namespace with CBT-enabled Fedora VM, tracker, data/state/backup-output PVCs (`runStrategy: Always`).
3. `incrementalBackup` feature gate + CBT label selector matching the VM.
4. Baseline: CBT `Enabled`; VM/VMI Running; PVCs Bound; ODF Ready; no other VMB Progressing.
5. Baseline Full and Incremental already proven with `make cbt-evidence` (record checkpoint names).
6. Guest write workload active under `/data/vm-validator`.
7. `krknctl run network-chaos --help` reviewed for this Krkn release.
8. No scenario-specific extra preconditions.

## 7. Test environment

| Item | Example / resolve at run time |
|---|---|
| Namespace | `$NS` |
| VM / VMI | `$VM` |
| Tracker | `$TRACKER` (`$VM-tracker`) |
| Backup PVC | `$BACKUP_PVC` (`$VM-backup-output`) |
| Chaos VMB | `$VMB_CHAOS` (unique per run) |
| Resolved target | VMI node name and/or specific launcher/CSI pod |
| KUBECONFIG | disposable cluster kubeconfig |

Load shared env from [`_common.md`](../_common.md).

## 8. Procedure

Follow phases **A → B → C → D → E** in order. **C is mandatory:** if chaos did not hit the intended component inside the intended window, stop and mark the run invalid — do not interpret CBT results.

### 8.1 Phase A — Arm backup window (timing gate)

See [`_common.md` Phase A](../_common.md). For this scenario:

Progressing=True; choose **one** fault shape (latency **or** loss first — not combined on first run).

Record `INJECT_WINDOW_OPEN` timestamp and VMB conditions JSON.

### 8.2 Phase B — Inject chaos (krknctl preferred; event-driven)

### Event-driven injection (preferred)

Prefer **Krkn event-driven triggers** over sleep / fixed `wait_duration` timing whenever it makes sense — especially for `T-PROG` (wait until `VirtualMachineBackup` has `Progressing=True`, then inject; use `on_timeout: fail` so a missed window fails the run instead of injecting late).

**Engine policy:** prefer **`krknctl`**. Use native **`oc` / `kubectl`** only when krknctl is awkward or cannot express the fault cleanly (document which path you used in the run log).

**Reproducible script (future):** each scenario folder will get its own `chaos-trigger.sh` beside this `scenario_spec.md` (same directory). Do not put a shared trigger under `scripts/` for these V3 scenarios — keep inject logic local to the scenario so it stays easy to find and reproduce.


Always confirm flags with `--help` first:

```bash
krknctl run network-chaos --help
```

**Example stub** (adjust selectors/names to the resolved target; pin versions in the run log):

```bash
VMI_NODE=$(oc get vmi "$VM" -n "$NS" -o jsonpath='{.status.nodeName}')

# Example: egress impairment on VMI node (confirm --egress / --wait-duration rules via --help)
# Website: --wait-duration must be >= 2× --duration for network-chaos.
krknctl run network-chaos \
  --traffic-type egress \
  --node-name "$VMI_NODE" \
  --duration 60 \
  --wait-duration 150 \
  --egress '{latency: 100ms}'

# Alternative: pod-level
# krknctl run pod-network-scenario --namespace "$NS" --pod-name "$LAUNCHER_POD" ...
# Prefer network-chaos-ng variants when BFD-safe targeting is required.
```



Record Krkn start/end wall time and the exact command line.

### 8.3 Phase C — Validate chaos injected on the correct component at the correct time

**Gate:** all checks below must pass before grading CBT.

1. Confirm tc/netem or NetworkPolicy applied to intended node/pod (Krkn logs).
2. API still reachable from operator workstation.
3. Progressing at inject; backup slows or errors correlate with fault window.
4. After wait-duration: rules removed; connectivity restored.

Shared timing checks: [`_common.md` Phase C](../_common.md).

| Check | Pass if |
|---|---|
| Timing | Inject started after `INJECT_WINDOW_OPEN` and before VMB terminal (for `T-PROG`) — or matches documented `T-GAP` / `T-PRE` / `T-POST` |
| Target | Observed disrupted object matches the resolved target identity |
| Scope | No unintended pods/nodes/PVCs disrupted |

If any row fails → **INVALID RUN** (do not pass/fail CBT).

### 8.4 Phase D — Validate CBT backup data (corrupt vs correct)

After the chaos VMB reaches a **terminal** condition (or known failure), and after any required follow-up backup:

1. VMB terminal (success or explicit fail) — no checkpoint without payload completion.
2. After network restore: follow-up backup + `cbt-evidence`.
3. Distinguish control-path stall (reconcile) vs storage-path stall (Push I/O) in notes.

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

Verify no leftover network policies / tc rules; V3-11 if needed. Abort with out-of-band recovery if Krkn cannot restore network.

Then run **CBT-V3-11** if the VMB was interrupted or stuck.

## 9. Expected results

Bounded retries or deterministic fail + cleanup; post-restore Ready components; evidence-correct follow-up.

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

- Keep Kubernetes API usable.\n- One path, one fault type per run.\n- Never start etcd-split-brain as part of this scenario.

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
