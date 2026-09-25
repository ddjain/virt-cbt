# CBT-V3-11 — Interrupted-backup cleanup gate

> **Plan:** [`../chaos_scenario_v3.md`](../chaos_scenario_v3.md)  
> **Shared snippets:** [`../_common.md`](../_common.md)  
> **Evidence rule:** Full vs Incremental pass/fail = qcow2 `backing-filename` via `make cbt-evidence` — not `VirtualMachineBackup.status.type` alone.


## 1. Metadata

| Field | Value |
|---|---|
| **Scenario ID** | `CBT-V3-11` |
| **Priority** | Gate (after every interrupt) |
| **Krkn scenario** | `none (procedure)` |
| **Target component** | VMB finalizers, hotplug detach, tracker consistency, namespace deletability |
| **Inject window** | `T-POST` — after an interrupted/stuck VMB from V3-01…10 (or 12/13) |
| **Blast radius** | Low (cleanup) |
| **Folder** | `docs/chaos-test/scenario/cbt-11-interrupted-backup-cleanup/` |

## 2. Objective

Ensure interrupted backups do not leave eternal Progressing, stuck RWO attaches, or Incremental claims from invalid bases.

## 3. Traceability

- Catalog: `docs/chaos-test/chaos_scenario_v3.md` → `CBT-V3-11`
- Architecture: `docs/cbt/CBT-ARCHITECTURE.md`
- Components / inject window: `docs/cbt/CBT-COMPONENT-DEPENDENCIES.md`
- Evidence / safety: `docs/cbt/CBT-EXPLAINED.md`, `AGENTS.md`
- Krkn docs (local): `../../krkn-chaos/website/content/en/docs/scenarios/pod-scenarios/`
- Campaign dependency: baseline healthy Full + Incremental + `cbt-evidence` before chaos; run **CBT-V3-11** after any interrupt

## 4. Target and inject window

| Item | Detail |
|---|---|
| **Component under test** | VMB finalizers, hotplug detach, tracker consistency, namespace deletability |
| **Why this component** | Campaign gate: without cleanup honesty, later scenarios poison the chain. |
| **When to inject** | `T-POST` — after an interrupted/stuck VMB from V3-01…10 (or 12/13) |
| **When NOT to inject** | As a substitute for Phase C/D of the injecting scenario — run **after** those. |
| **Backup modes to repeat** | After any interrupted Full or Incremental chaos VMB |

## 5. Risk / blast radius

Read-only diagnostics then careful delete of test VMB only. No cluster-wide disruption.

## 6. Preconditions

1. Disposable OpenShift cluster with OpenShift Virtualization + ODF Ceph-RBD.
2. Validator namespace with CBT-enabled Fedora VM, tracker, data/state/backup-output PVCs (`runStrategy: Always`).
3. `incrementalBackup` feature gate + CBT label selector matching the VM.
4. Baseline: CBT `Enabled`; VM/VMI Running; PVCs Bound; ODF Ready; no other VMB Progressing.
5. Baseline Full and Incremental already proven with `make cbt-evidence` (record checkpoint names).
6. Guest write workload active under `/data/vm-validator`.
7. `krknctl run pod-scenarios --help` reviewed for this Krkn release.
8. Prior chaos scenario run ID and diagnostics path available.

## 7. Test environment

| Item | Example / resolve at run time |
|---|---|
| Namespace | `$NS` |
| VM / VMI | `$VM` |
| Tracker | `$TRACKER` (`$VM-tracker`) |
| Backup PVC | `$BACKUP_PVC` (`$VM-backup-output`) |
| Chaos VMB | `$VMB_CHAOS` (unique per run) |
| Resolved target | Chaos VMB `$VMB_CHAOS`, launcher volumes, `$BACKUP_PVC` |
| KUBECONFIG | disposable cluster kubeconfig |

Load shared env from [`_common.md`](../_common.md).

## 8. Procedure

Follow phases **A → B → C → D → E** in order. **C is mandatory:** if chaos did not hit the intended component inside the intended window, stop and mark the run invalid — do not interpret CBT results.

### 8.1 Phase A — Arm backup window (timing gate)

See [`_common.md` Phase A](../_common.md). For this scenario:

N/A — prior scenario already injected. Ensure diagnostics captured first.

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
# No Krkn injection. Example diagnostic / cleanup commands:

oc get virtualmachinebackup "$VMB_CHAOS" -n "$NS" -o json \
  | jq '{finalizers:.metadata.finalizers,status:.status,conditions:.status.conditions}'

oc get pod -n "$NS" -l kubevirt.io=virt-launcher -o json \
  | jq '.items[] | {name:.metadata.name,node:.spec.nodeName,volumes:[.spec.volumes[].name]}'

oc get pvc "$BACKUP_PVC" -n "$NS" -o yaml | head -80

# After evidence preserved:
oc delete virtualmachinebackup "$VMB_CHAOS" -n "$NS" --wait=false
# Watch finalizers clear; confirm PVC not stuck Terminating forever.
```

This gate has no chaos inject. Phase B is diagnostics + controlled delete.

Record Krkn start/end wall time and the exact command line.

### 8.3 Phase C — Validate chaos injected on the correct component at the correct time

**Gate:** all checks below must pass before grading CBT.

1. Confirm this run follows a documented interrupt (link prior scenario run ID).
2. “Injection” here means: operator started cleanup while prior VMB was terminal or known-stuck — record that state.
3. Confirm you are deleting **only** the chaos VMB, not the tracker or VM, unless the runbook says so.

Shared timing checks: [`_common.md` Phase C](../_common.md).

| Check | Pass if |
|---|---|
| Timing | Inject started after `INJECT_WINDOW_OPEN` and before VMB terminal (for `T-PROG`) — or matches documented `T-GAP` / `T-PRE` / `T-POST` |
| Target | Observed disrupted object matches the resolved target identity |
| Scope | No unintended pods/nodes/PVCs disrupted |

If any row fails → **INVALID RUN** (do not pass/fail CBT).

### 8.4 Phase D — Validate CBT backup data (corrupt vs correct)

After the chaos VMB reaches a **terminal** condition (or known failure), and after any required follow-up backup:

1. After cleanup: no VMB stuck Progressing.
2. Finalizers cleared; backup PVC Bound and not exclusively attached to a dead pod.
3. Create a **new** VMB on the same tracker only when prior op is inactive.
4. New backup evidence: Incremental only if base valid; else Full — never false Incremental.
5. `cbt-evidence` on the new backup.

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

Namespace remains operable; proceed to next campaign scenario only when gate passes.

Then run **CBT-V3-11** if the VMB was interrupted or stuck.

## 9. Expected results

Finalizers clear; PVC detached; no eternal Progressing; next backup honest (Incremental or safe Full per evidence).

## 10. Pass criteria

- [ ] Phase C passed (correct component + correct time)
- [ ] VMB reached terminal state (success **or** explicit failure — not eternal Progressing)
- [ ] Tracker advanced only on valid completion
- [ ] Follow-up / chaos artifact qcow2 evidence matches expected mode (Incremental header **or** explained Full)
- [ ] No silent Incremental without `backing-filename`
- [ ] VM/VMI Running, CBT `Enabled` after recovery (post any required restart)
- [ ] Backup-output PVC reusable / detached correctly
- [ ] Blast radius within declared scope
- [ ] Namespace deletion not blocked by leftover VMB finalizers (spot-check)

## 11. Fail criteria

- Chaos missed target or wrong inject window (invalid), or operator still graded it
- Silent data loss / truncated “success”
- False Incremental (status or tracker without qcow2 proof)
- Stale finalizer / stuck Progressing / orphaned RWO attach
- Unrecovered VMI or unexplained Full fallback
- Inability to reverse the injected fault


## 12. Safety notes

- Preserve diagnostics before delete.\n- Do not delete tracker while a VMB still references it without understanding finalizers.

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
