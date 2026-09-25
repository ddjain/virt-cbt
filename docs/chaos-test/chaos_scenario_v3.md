# CBT Chaos Plan — Scenario Catalog V3 (Phase 1)

**Phase:** 1 — Design (catalog) + per-scenario specs  
**Status:** Draft for review  
**Per-scenario specs:** [`scenario/README.md`](scenario/README.md) — each `CBT-V3-*` folder has a `scenario_spec.md` (inject window, Phase C target/timing validation, Phase D CBT evidence, basic `krknctl` stubs).  
**Still deferred:** release-pinned Krkn triggers/wrappers and formal SLOs.

This document answers four questions for each proposed experiment:

| Question | Answered in |
|---|---|
| **What** fault do we inject? | Scenario ID + Krkn scenario type |
| **When** in the CBT/backup lifecycle? | Inject window |
| **Which** CBT component is the target? | Component / layer |
| **What** must happen afterward? | Expected outcome + proof |

It builds on `docs/cbt/` (architecture, component roles, inject window, evidence rules) and uses the local Krkn docs checkout at `../../krkn-chaos/website/content/en/docs/scenarios/` as the **source of truth for available chaos types**. It supersedes the planning intent of `scenarios_v2.md` for Phase 1; v2 remains useful for historical campaign order and evidence templates.

Companion CBT docs:

- [`../cbt/CBT-ARCHITECTURE.md`](../cbt/CBT-ARCHITECTURE.md)
- [`../cbt/CBT-COMPONENT-DEPENDENCIES.md`](../cbt/CBT-COMPONENT-DEPENDENCIES.md)
- [`../cbt/CBT-EXPLAINED.md`](../cbt/CBT-EXPLAINED.md)
- [`../cbt/CBT-OPERATIONS.md`](../cbt/CBT-OPERATIONS.md)

---

## 1. What we are protecting

KubeVirt-native CBT path (this repo):

```text
Guest writes
  → QEMU dirty bitmap (virt-launcher; overlay on persistent-state-for-* PVC)
  → virt-handler (node) + virt-controller (cluster)
  → VirtualMachineBackupTracker + VirtualMachineBackup
  → Push copy into <vm>-backup-output PVC (hotplugged only during backup)
  → ODF Ceph-RBD (CSI node/controller + OSDs)
```

Goal of chaos: prove the chain **fails safe or recovers correctly** under one fault at a time — not that pods simply come back Ready.

**Authoritative pass/fail for Full vs Incremental:** qcow2 `backing-filename` via `make cbt-evidence` / `scripts/cbt-evidence-check.sh`.  
**Not authoritative:** `VirtualMachineBackup.status.type`, tracker status, or controller logs alone (those may be stale under chaos). Use CR conditions only as **synchronization barriers**.

| Artifact | Header signal |
|---|---|
| Genuine Incremental | `backing-filename` = `/var/run/kubevirt-private/libvirt/qemu/cbt/datadisk.qcow2` |
| Genuine Full | **no** `backing-filename` |

Safe Full fallback after bitmap/overlay loss is acceptable **when explained**. Silent Incremental classification without that header is a failure.

---

## 2. Backup lifecycle and inject windows

Observed Push-mode VMB phases (names release-dependent; this environment uses `Done`, not always upstream `Complete`):

| Phase | Signals | Chaos allowed? |
|---|---|---|
| **Attach** | `Initializing=True`, `Progressing=False`; reason ≈ backup target PVC attaching; `hp-volume-*` may appear | **No** — PVC not mounted yet; inject here is ambiguous |
| **In progress** | **`Progressing=True`**, reason ≈ Backup is in progress; `Done=False`; finalizer present | **Yes — primary inject window** |
| **Terminal** | `Progressing=False`, `Done=True` (or explicit failure) | Window closed |
| **Between Full and Incremental** | Prior Full terminal; tracker has checkpoint; guest still writing | **Yes — secondary window** (chain / restart / migration tests) |
| **Steady state (no VMB)** | CBT `Enabled`, no backup CR active | Only for preconditions (e.g. fill backup PVC *before* starting VMB) |

**Primary gate (recommended):** wait until `Progressing=True` on the chaos VMB, then inject.

**Do not inject during Attach** unless the scenario is specifically about hotplug attach failure (call that out explicitly).

Secondary correlation only (do not gate inject on these alone): hotplug events, `hp-volume-*` pods, QEMU `query-block-jobs` showing `"type":"backup"`.

---

## 3. CBT components → chaos relevance

From `CBT-COMPONENT-DEPENDENCIES.md`, ranked by impact on the Incremental path:

| Priority | Component | Why it matters for CBT |
|---|---|---|
| P0 | `virt-launcher` / QEMU | Owns dirty bitmaps and overlay I/O; crash often forces Full fallback |
| P0 | CBT overlay / `persistent-state-for-*` (via launcher/handler/storage path) | CBT’s memory of what changed |
| P1 | `virt-handler` on VMI node | Checkpoint redefine, backup commands, hotplug |
| P1 | Backup-output PVC + CSI hotplug path | Push sink; RWO attach during Progressing |
| P2 | CSI RBD nodeplugin / Ceph OSD under data or state volume | I/O for bitmap persistence and disk copy |
| P2 | `virt-controller` | Reconciles VMB/VMBT; kill mid-run can stall or leave finalizers |
| P3 | Network: controller ↔ handler/launcher, CSI ↔ Ceph | Stalls reconcile or attach; not “bitmap math” |
| P3 | Node hosting VMI | Combined launcher + handler + CSI node impact |
| — | Data PVC / state PVC dual-mount from second pod | **Hazard, not a useful scenario** — caused live `PausedIOError` |

---

## 4. Krkn scenario inventory (source of truth)

Catalog derived from `../../krkn-chaos/website/content/en/docs/scenarios/_index.md` and per-scenario pages.  
**Phase 1 does not prepare commands** — only maps fitness for CBT.

### 4.1 In scope for CBT campaign (primary)

| Krkn scenario (website) | Hub / plugin id | CBT use |
|---|---|---|
| [Pod Failures](https://github.com/krkn-chaos/website/tree/main/content/en/docs/scenarios/pod-scenarios) | `pod_disruption_scenarios` / `pod-scenarios` | Kill `virt-controller`, `virt-handler` (VMI node), CSI RBD node/ctrl plugin pods (one replica at a time) |
| [Container Failures](https://github.com/krkn-chaos/website/tree/main/content/en/docs/scenarios/container-scenarios) | `container_scenarios` | SIGTERM/SIGKILL inside virt-controller or virt-handler container (finer than pod delete) |
| [KubeVirt VM Outage](https://github.com/krkn-chaos/website/tree/main/content/en/docs/scenarios/kubevirt-outage) | `kubevirt_vm_outage` / `kubevirt-outage` | Delete VMI mid-backup; `runStrategy: Always` recovery |
| [Node Failures](https://github.com/krkn-chaos/website/tree/main/content/en/docs/scenarios/node-scenarios) | `node_scenarios` | Disrupt VMI host (cloud/BM variants); high blast radius |
| [Node CPU / Memory / IO Hog](https://github.com/krkn-chaos/website/tree/main/content/en/docs/scenarios/hog-scenarios) | `hog_scenarios` | Pressure on VMI node during Push copy |
| [Network Chaos](https://github.com/krkn-chaos/website/tree/main/content/en/docs/scenarios/network-chaos) | `network_chaos_scenarios` | Latency / loss / bandwidth on VMI node path |
| [Pod Network Chaos](https://github.com/krkn-chaos/website/tree/main/content/en/docs/scenarios/pod-network-scenario) | `pod_network_scenarios` | Target virt-launcher or CSI node plugin pod traffic |
| [Network Chaos NG — VMI Network](https://github.com/krkn-chaos/website/tree/main/content/en/docs/scenarios/network-chaos-ng-scenarios/vmi-network) | `vmi-network` | Shape tap inside virt-launcher NS — guest-facing only; **prefer for guest verify path, not bitmap Push** (Push is local hotplug/RBD) |
| [Network Chaos NG — Pod / Node filter & chaos](https://github.com/krkn-chaos/website/tree/main/content/en/docs/scenarios/network-chaos-ng-scenarios) | `network_chaos_ng_scenarios` | Prefer over legacy network-chaos when needing filter/BFD-safe targeting |
| [PVC Disk Fill](https://github.com/krkn-chaos/website/tree/main/content/en/docs/scenarios/pvc-scenario) | `pvc_scenarios` | Fill **backup-output** PVC only (never data or state PVC while VM runs) |
| [Storage I/O Throttle](https://github.com/krkn-chaos/website/tree/main/content/en/docs/scenarios/storage-throttle) | `storage_throttle` | Throttle backup-output (or launcher mount) during Progressing |
| [Time Skew](https://github.com/krkn-chaos/website/tree/main/content/en/docs/scenarios/time-scenarios) | `time_scenarios` | Isolated worker/pod only; low priority |
| [Application Outages](https://github.com/krkn-chaos/website/tree/main/content/en/docs/scenarios/application-outages) | `application_outages_scenarios` | Optional: NetworkPolicy isolate virt-controller NS traffic (control-plane reachability) |

### 4.2 Available but excluded from primary CBT campaign

| Krkn scenario | Why excluded (for now) |
|---|---|
| Zone outages | AZ blast radius ≫ one backup chain |
| Power outages / cluster shut down | Cluster-wide; separate platform campaign |
| Service disruption (delete namespace objects) | Destroys test namespace / shared objects |
| Service hijacking / SYN flood / HTTP load | Not on CBT Push data path |
| DNS outage | Indirect; guest SSH/verify only unless targeting operator DNS |
| ETCD split brain | Can brick API; disposable-only, not CBT-specific |
| Aurora / EFS disruption | AWS-specific; not ODF RBD path |
| Managed-cluster scenario | Wrong product surface |

### 4.3 Important Krkn notes (carry into later phases)

- Website scenario name for VMI deletion is **`kubevirt-outage`** (plugin `kubevirt_vm_outage`), not the older informal `vmi-outage` name used in some earlier notes.
- **`vmi-network`** affects the guest tap, not OVN BFD and not the RBD Push path inside the launcher — good for guest connectivity chaos; weak for proving backup I/O resilience. Prefer **storage-throttle**, **pod-network** on CSI, or **node network** for storage/control paths.
- PVC fill requires the PVC to be Bound and mounted by a pod — for backup-output, that means either during Progressing (hotplugged into launcher) or a deliberate pre-mount helper; Phase 2 must pick one and document safety.
- Hog and node scenarios: one resource / one worker at a time; preserve control-plane quorum.
- Prefer Krkn **event-driven triggers** on `Progressing=True` over sleep-based timing (detail in Phase 2).

---

## 5. Scenario matrix (Phase 1 deliverable)

Each row is one experiment family. Repeat Full and Incremental separately where noted.  
**Detailed specs + basic `krknctl` stubs:** [`scenario/<id>-…/scenario_spec.md`](scenario/README.md).

### Legend — inject timing codes

| Code | Meaning |
|---|---|
| `T-PROG` | While chaos VMB has `Progressing=True` |
| `T-GAP` | After Full terminal, before Incremental VMB created |
| `T-PRE` | Before VMB create (e.g. capacity precondition) |
| `T-POST` | After interrupted VMB reaches terminal/stuck; cleanup gate |

---

### CBT-V3-01 — virt-controller pod kill mid-backup

**Spec:** [`scenario/cbt-01-virt-controller-pod-kill/scenario_spec.md`](scenario/cbt-01-virt-controller-pod-kill/scenario_spec.md)

| Field | Value |
|---|---|
| **Component** | `virt-controller` (OpenShift Virtualization control plane) |
| **Krkn type** | `pod-scenarios` (single replica; never all replicas) |
| **When** | `T-PROG` — once during Full, once during Incremental |
| **Expected** | Replacement Ready; VMB completes **or** fails with explicit condition (no indefinite Progressing); no stuck finalizer; tracker advances only on valid completion; follow-up backup: Incremental if checkpoint committed, else safe Full |
| **Proof** | Terminal VMB + `cbt-evidence` on follow-up; Deployment restart healthy |
| **Priority** | P2 |

---

### CBT-V3-02 — virt-handler kill on VMI node mid-backup

**Spec:** [`scenario/cbt-02-virt-handler-pod-kill/scenario_spec.md`](scenario/cbt-02-virt-handler-pod-kill/scenario_spec.md)

| Field | Value |
|---|---|
| **Component** | `virt-handler` DaemonSet pod on VMI’s node |
| **Krkn type** | `pod-scenarios` (node-scoped selector) |
| **When** | `T-PROG` — Full and Incremental separately |
| **Expected** | Handler recreates; VMI returns Running / CBT Enabled; VMB terminal (complete or explicit fail); next backup Incremental **or** explained Full fallback if bitmap continuity lost |
| **Proof** | `cbt-evidence`; no silent Incremental without backing-filename |
| **Priority** | P1 |
| **Note** | Highest-signal control-plane-adjacent fault for checkpoint/hotplug |

---

### CBT-V3-03 — virt-launcher / VMI outage mid-backup

**Spec:** [`scenario/cbt-03-kubevirt-vmi-outage/scenario_spec.md`](scenario/cbt-03-kubevirt-vmi-outage/scenario_spec.md)

| Field | Value |
|---|---|
| **Component** | VMI / `virt-launcher` / QEMU (dirty bitmap owner) |
| **Krkn type** | `kubevirt-outage` |
| **When** | `T-PROG`; also optional `T-GAP` (crash between Full and Incremental) |
| **Expected** | VM recreates VMI (`runStrategy: Always`); CBT returns Enabled after init/restart; interrupted VMB **not** success without valid checkpoint; follow-up Incremental or safe Full |
| **Proof** | `cbt-evidence`; VMI recovery alone is **not** pass |
| **Priority** | P0 |
| **Note** | Classic bitmap invalidate / silent-Full-fallback case from CBT docs |

---

### CBT-V3-04 — Container signal on virt-handler or virt-controller

**Spec:** [`scenario/cbt-04-container-signal/scenario_spec.md`](scenario/cbt-04-container-signal/scenario_spec.md)

| Field | Value |
|---|---|
| **Component** | Same as V3-01/02 but process-level |
| **Krkn type** | `container-scenarios` (prefer SIGTERM; SIGKILL only on disposable cluster) |
| **When** | `T-PROG` |
| **Expected** | Same safety as pod kill; compare recovery time vs V3-01/02 |
| **Priority** | P2 |

---

### CBT-V3-05 — Backup-output PVC near-full

**Spec:** [`scenario/cbt-05-backup-pvc-fill/scenario_spec.md`](scenario/cbt-05-backup-pvc-fill/scenario_spec.md)

| Field | Value |
|---|---|
| **Component** | `<vm>-backup-output` PVC (Push sink) |
| **Krkn type** | `pvc-scenario` |
| **When** | `T-PRE` (fill before VMB) and/or early `T-PROG` if PVC already mounted |
| **Expected** | Backup fails with clear capacity/write error; tracker does **not** advance as success; RWO released; after fill cleanup, fresh backup succeeds |
| **Proof** | No truncated “success”; evidence check on retry |
| **Priority** | P1 |
| **Safety** | Target **only** backup-output. Do **not** fill data or `persistent-state-for-*` while VM runs |

---

### CBT-V3-06 — Throttle I/O on backup path

**Spec:** [`scenario/cbt-06-storage-throttle/scenario_spec.md`](scenario/cbt-06-storage-throttle/scenario_spec.md)

| Field | Value |
|---|---|
| **Component** | Backup-output volume / launcher cgroup I/O |
| **Krkn type** | `storage-throttle` |
| **When** | `T-PROG` (data-copy portion); Full then Incremental with smaller dirty set |
| **Expected** | Completes within timeout **or** explicit fail + cleanup; no false checkpoint; after throttle removed, chain reusable |
| **Priority** | P1 |

---

### CBT-V3-07 — CSI RBD node plugin disruption on VMI node

**Spec:** [`scenario/cbt-07-csi-rbd-nodeplugin/scenario_spec.md`](scenario/cbt-07-csi-rbd-nodeplugin/scenario_spec.md)

| Field | Value |
|---|---|
| **Component** | CSI RBD nodeplugin (attach/mount during hotplug + RBD I/O) |
| **Krkn type** | `pod-scenarios` (openshift-storage / CSI labels; one pod on VMI node) |
| **When** | `T-PROG` |
| **Expected** | Bounded attach/I/O errors or retry; VMB terminal; volumes reattach; no orphaned exclusive attach; follow-up backup succeeds (Incremental or safe Full) |
| **Priority** | P2 |
| **Note** | Directly exercises ODF path this repo validates on |

---

### CBT-V3-08 — Network degradation on control or storage path

**Spec:** [`scenario/cbt-08-network-control-storage/scenario_spec.md`](scenario/cbt-08-network-control-storage/scenario_spec.md)

| Field | Value |
|---|---|
| **Component** | API/control path (controller↔handler/launcher) **or** CSI↔Ceph / node egress |
| **Krkn type** | Prefer `network-chaos-ng` node/pod variants; legacy `network-chaos` / `pod-network-scenario` acceptable |
| **When** | `T-PROG` (short fault first, then longer near timeout) |
| **Expected** | Bounded retries or deterministic fail + cleanup; after restore, Ready components and successful follow-up backup; no checkpoint without payload completion |
| **Priority** | P3 |
| **Note** | Keep API reachable for observation. Guest-only `vmi-network` is a **different** experiment (V3-08b) |

---

### CBT-V3-08b — Guest tap network chaos (optional)

**Spec:** [`scenario/cbt-08b-vmi-guest-network/scenario_spec.md`](scenario/cbt-08b-vmi-guest-network/scenario_spec.md)

| Field | Value |
|---|---|
| **Component** | VMI guest network (tap in virt-launcher netns) |
| **Krkn type** | `vmi-network` / `vmi-network-filter` |
| **When** | During guest write + verify (may overlap `T-PROG` or `T-GAP`) |
| **Expected** | Bitmap/Push still progress if storage path healthy; guest SSH/verify may fail until restored — **do not** confuse verify failure with CBT failure |
| **Priority** | P3 (separates guest net from CBT core) |

---

### CBT-V3-09 — CPU / memory / I/O hog on VMI node

**Spec:** [`scenario/cbt-09-node-resource-hog/scenario_spec.md`](scenario/cbt-09-node-resource-hog/scenario_spec.md)

| Field | Value |
|---|---|
| **Component** | Node hosting virt-launcher (QEMU + backup I/O) |
| **Krkn type** | `node-cpu-hog` / `node-memory-hog` / `node-io-hog` — **one** per run |
| **When** | `T-PROG` under guest write load |
| **Expected** | Node stable; backup completes or fails cleanly; no OOM-killed launcher without accounted failure; after hog ends, follow-up backup OK |
| **Priority** | P3 |
| **Note** | Cap below eviction threshold |

---

### CBT-V3-10 — VMI host node failure

**Spec:** [`scenario/cbt-10-vmi-node-failure/scenario_spec.md`](scenario/cbt-10-vmi-node-failure/scenario_spec.md)

| Field | Value |
|---|---|
| **Component** | Worker node (launcher + local handler + CSI node) |
| **Krkn type** | `node-scenarios` (provider-appropriate) |
| **When** | `T-PROG`; optional `T-GAP` |
| **Expected** | Node recovery or VMI reschedule within SLO; RBD reattach; backup PVC not stuck on dead node; VMB terminal; tracker advances only on valid complete; safe Full OK if bitmap lost |
| **Priority** | P3 (high blast radius — last among primary storage/compute tests) |
| **Safety** | Isolated disposable cluster; approved cloud/BM credentials; never all masters |

---

### CBT-V3-11 — Interrupted-backup cleanup gate (mandatory after interrupts)

**Spec:** [`scenario/cbt-11-interrupted-backup-cleanup/scenario_spec.md`](scenario/cbt-11-interrupted-backup-cleanup/scenario_spec.md)

| Field | Value |
|---|---|
| **Component** | VMB finalizers, hotplug detach, tracker consistency |
| **Krkn type** | None (procedure after V3-01…10 interruptions) |
| **When** | `T-POST` |
| **Expected** | Finalizers clear; backup PVC detached; no eternal Progressing; new backup does not claim Incremental from invalid base |
| **Priority** | Gate — run after every interrupted experiment |

---

### CBT-V3-12 — Live migration vs backup coordination

**Spec:** [`scenario/cbt-12-live-migration-vs-backup/scenario_spec.md`](scenario/cbt-12-live-migration-vs-backup/scenario_spec.md)

| Field | Value |
|---|---|
| **Component** | VMI migration + backup/checkpoint handoff |
| **Krkn type** | **Not** a primary Krkn scenario — drive with `VirtualMachineInstanceMigration`; use Krkn only for observation if needed |
| **When** | Migration before backup; during `T-PROG`; after terminal |
| **Expected** | Backup and migration serialize per release contract; bitmap preserved or safe Full; no dual RWO attach |
| **Priority** | P2 (KubeVirt control experiment) |

---

### CBT-V3-13 — Time skew (low priority)

**Spec:** [`scenario/cbt-13-time-skew/scenario_spec.md`](scenario/cbt-13-time-skew/scenario_spec.md)

| Field | Value |
|---|---|
| **Component** | Isolated disposable worker or dedicated test pod clock |
| **Krkn type** | `time-scenarios` |
| **When** | `T-GAP` and separately `T-PROG` |
| **Expected** | No false Incremental chain from clock weirdness; safe Full or explicit fail OK; clock restored before cleanup |
| **Priority** | P4 |
| **Safety** | Never skew API, etcd, Ceph MON, or all workers |

---

## 6. Recommended Phase 1 priority order (for later execution)

Order by CBT signal vs blast radius (commands still out of scope):

1. Baseline healthy Full + Incremental + `cbt-evidence` (no chaos)
2. **V3-03** kubevirt-outage @ `T-PROG` (Incremental first — highest CBT signal)
3. **V3-02** virt-handler kill @ `T-PROG`
4. **V3-05** / **V3-06** backup PVC fill / throttle
5. **V3-01** / **V3-04** virt-controller pod/container
6. **V3-07** CSI node plugin
7. **V3-08** network (control/storage); optionally **V3-08b** guest tap
8. **V3-09** hogs
9. **V3-12** migration coordination
10. **V3-10** node failure
11. **V3-13** time skew
12. **V3-11** cleanup gate after every interrupt

Stop the campaign if ODF is unhealthy, API is lost without out-of-band recovery, or a run risks unrelated namespaces.

---

## 7. Universal expected outcomes (every scenario)

Regardless of Krkn type:

1. Fault target and inject window (`T-*`) are recorded.
2. VMB reaches a **terminal** condition (success or explicit failure) — never stuck `Progressing` forever.
3. Tracker `latestCheckpoint` advances **only** after a backup that is actually valid.
4. Follow-up backup: Incremental with correct `backing-filename`, **or** explained Full with empty backing field.
5. Data PVC and `persistent-state-for-*` are never dual-mounted from a second live pod as part of the test.
6. VM/VMI returns to Running with CBT `Enabled` (after any required restart).
7. Backup-output PVC is reusable and not permanently attached.
8. Blast radius stays within the declared component (no unexplained cluster-wide regression).

**Fail immediately on:** silent data loss; “Incremental” without qcow2 evidence; stale finalizer; orphaned RWO attach; unrecovered VMI; unexplained Full fallback; inability to reverse the injected fault.

---

## 8. Safety hard rules (from CBT ops / AGENTS)

- Disposable cluster / managed namespace only (`app.kubernetes.io/managed-by=odf-cbt-validator` ownership rules apply to this repo’s tooling).
- **Never** mount data PVC or `persistent-state-for-*` into a second pod while the VM is running.
- Evidence inspector: backup-output only, read-only, preferably off the VMI node.
- One fault class per run; restore before the next scenario.
- Do not delete all virt-controller replicas or Ceph quorum in this campaign.

---

## 9. What’s next (Phase 2+)

Per-scenario `scenario_spec.md` files already include **basic** `krknctl` stubs and Phase C/D validation. Still deferred:

- Release-pinned Krkn event triggers (`Progressing=True`, `on_timeout: fail`) and Krkn-AI configs
- Namespace/VM naming convention for density pool vs single-demo manifests
- SLO numbers (recovery seconds, backup duration budgets)
- Formal QA import / Jira tickets from `test-spec-template.md` / `jira-issue-template.md`

---

## 10. References

**This repo**

- `docs/cbt/CBT-ARCHITECTURE.md`
- `docs/cbt/CBT-COMPONENT-DEPENDENCIES.md` (inject window + suggested order)
- `docs/cbt/CBT-EXPLAINED.md` (evidence + dual-mount incident)
- `docs/chaos-test/scenarios_v2.md` (prior campaign detail)
- `docs/chaos-test/KRKN-AI-CBT.md` (narrow kubevirt-outage runbook)

**Krkn website (local checkout)**

- `../../krkn-chaos/website/content/en/docs/scenarios/_index.md`
- Scenario pages under that tree (`kubevirt-outage`, `pod-scenarios`, `storage-throttle`, `pvc-scenario`, `network-chaos-ng-scenarios/vmi-network`, hogs, node-scenarios, …)
