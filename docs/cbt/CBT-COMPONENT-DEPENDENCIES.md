# CBT component dependencies (roles for test planning)

This document inventories every component the KubeVirt-native CBT
(Changed Block Tracking) path depends on, with its **role** on the
Full → Incremental backup pipeline. Use it when designing chaos or
resilience tests: wait for `Progressing=True` (see
[Detecting when backup is in progress](#detecting-when-backup-is-in-progress-chaos-inject-window)),
inject against these layers, then prove correctness
with qcow2-header evidence (`make cbt-evidence` /
`scripts/cbt-evidence-check.sh`) — never with
`VirtualMachineBackup.status` alone.

Companion docs:

- [`CBT-ARCHITECTURE.md`](CBT-ARCHITECTURE.md) — how CBT fits together
- [`CBT-OPERATIONS.md`](CBT-OPERATIONS.md) — ops checks, metrics, runbooks
- [`CBT-EXPLAINED.md`](CBT-EXPLAINED.md) — concepts, verification, safety incident
- [`CBT-TEST-GUIDE.md`](CBT-TEST-GUIDE.md) — Make/kube-burner workflow

This is **KubeVirt-native CBT** (QEMU dirty bitmaps + checkpoint chain),
not CSI Snapshot Metadata Service CBT. ODF Ceph RBD persists the volumes;
it does not compute the changed-block map.

---

## Naming convention (this repo's density validator)

For a VM named `<prefix>-<n>` (e.g. `fedora-cbt-1`):

| Resource | Kind | Example |
|---|---|---|
| `<vm>` | `VirtualMachine` / `VirtualMachineInstance` | `fedora-cbt-1` |
| `<vm>-data` | PVC (data disk) | `fedora-cbt-1-data` |
| `persistent-state-for-<vm>-<suffix>` | PVC (CBT overlay / VM state) | `persistent-state-for-fedora-cbt-1-9j5nt` |
| `<vm>-backup-output` | PVC (push backup target) | `fedora-cbt-1-backup-output` |
| `<vm>-tracker` | `VirtualMachineBackupTracker` | `fedora-cbt-1-tracker` |
| `<vm>-full` | `VirtualMachineBackup` | `fedora-cbt-1-full` |
| `<vm>-incremental` | `VirtualMachineBackup` | `fedora-cbt-1-incremental` |
| `virt-launcher-<vm>-*` | Pod | `virt-launcher-fedora-cbt-1-d2g9x` |

Backup artifacts land on the backup-output PVC at:

```text
<vm>/<checkpoint-name>/<backup-name>-datadisk.qcow2
```

---

## 1. Per-VM storage (highest impact)

| Component | Role |
|---|---|
| **Data PVC** (`<vm>-data`) | Guest data disk (this repo: `/data` workload). CBT tracks which blocks of this disk change between checkpoints. Backed by ODF RBD (`ocs-storagecluster-ceph-rbd` by default). |
| **CBT state / overlay PVC** (`persistent-state-for-<vm>-*`) | Holds the QEMU dirty-bitmap overlay and related VM state. The overlay file path inside the launcher is `/var/run/kubevirt-private/libvirt/qemu/cbt/<disk>.qcow2` (e.g. `datadisk.qcow2`). **This is CBT's memory of what changed.** Losing or corrupting it forces a fall-back to Full. |
| **Backup-output PVC** (`<vm>-backup-output`) | Destination for Push-mode backup qcow2 files. Hot-plugged into the launcher **only during** a backup; not part of the steady-state VM pod spec. Safe for a short-lived, read-only inspector pod (schedule off the VM node). |
| **DataVolume** (`<vm>-data`) | CDI blank (or import) volume that provisions the data PVC. Involved at create time; not on the steady-state backup data path. |

### Overlay vs data disk

```text
virt-launcher pod
├── /var/run/kubevirt-private/vmi-disks/datadisk     ← real guest bytes (data PVC)
└── /var/run/kubevirt-private/libvirt/qemu/cbt/
      └── datadisk.qcow2                             ← bitmap / checkpoint metadata
                                                      (state PVC; tiny vs disk size)
```

**Safety rule for tests and tooling:** never mount the data PVC or the
`persistent-state-for-*` PVC into a second pod while the VM is running.
Dual-attaching RBD on the same node has caused real `PausedIOError` on
the live VM. Evidence checks must use **only** the backup-output PVC.
See `CBT-EXPLAINED.md` §9 and `AGENTS.md`.

---

## 2. Compute / QEMU path

| Component | Role |
|---|---|
| **`virt-launcher` pod** | Runs QEMU/libvirt for the VMI. Owns dirty bitmaps (mostly in memory while running) and the CBT overlay file. Backup Push I/O and hotplug of the backup-output PVC happen here. |
| **`VirtualMachine` / `VirtualMachineInstance`** | Declares the guest. Requires disk-level `changedBlockTracking: true` on the data disk **and** a matching HyperConverged CBT label selector (this repo labels VMs `changedBlockTracking: "true"`). Steady-state success signal: `status.changedBlockTracking.state == Enabled`. |
| **`virt-handler` (DaemonSet, node-local)** | Node agent that talks to libvirt/QEMU: enables CBT, creates/redefines checkpoints, drives backup commands, handles hotplug. Co-located with the launcher on the VMI's node. |
| **`virt-controller` (Deployment)** | Cluster control plane that reconciles `VirtualMachineBackup` / `VirtualMachineBackupTracker`, updates checkpoints, and manages backup lifecycle. (There is no separate `virt-backup` deployment.) |
| **HyperConverged / KubeVirt config** | Cluster gate: `incrementalBackup` feature gate plus `changedBlockTrackingLabelSelectors`. Without these, CBT never enables. |

---

## 3. Backup control plane (KubeVirt API)

| Component | Role |
|---|---|
| **`VirtualMachineBackupTracker`** | Per-VM (per consumer) checkpoint bookkeeping. Empty tracker → next backup is Full. After Full, `latestCheckpoint` records the baseline; the next backup on the same tracker can be Incremental. |
| **`VirtualMachineBackup` (Full)** | One Push job that copies the whole disk into `<vm>-backup-output` and creates the first checkpoint. |
| **`VirtualMachineBackup` (Incremental)** | One Push job that exports only blocks dirty since the tracker's prior checkpoint. A healthy Incremental qcow2 has `backing-filename` pointing at the CBT overlay path above. |

**For chaos assertions:** use tracker/backup `.status` and conditions only as
*synchronization barriers* (e.g. "has the CR reached a terminal condition?").
Pass/fail that CBT actually produced an Incremental must come from the
backup qcow2's own header (`backing-filename`), via `cbt-evidence-check.sh`.

---

## 4. ODF / Ceph storage stack

| Component | Role |
|---|---|
| **StorageClass** (`ocs-storagecluster-ceph-rbd`) | Provisions data, state, and backup-output PVCs used by this workflow. |
| **VolumeSnapshotClass** (`ocs-storagecluster-rbdplugin-snapclass`) | Snapshot capability required by cluster prereqs; not the CBT bitmap mechanism itself. |
| **CSI RBD controller plugin** | Provisions and coordinates attach of RBD volumes cluster-wide. |
| **CSI RBD node plugin** | Attaches/mounts RBD volumes on the node hosting `virt-launcher`. Critical during backup hotplug and under I/O load. |
| **Ceph OSDs** | Persist the bytes of data, state, and backup-output volumes. |
| **Ceph MONs / MGRs** | Cluster quorum and management; needed for healthy RBD operation. |
| **Rook / OCS operators** | Keep the StorageCluster / CephCluster reconciled (`Ready`, `HEALTH_OK`). |

CBT itself is storage-agnostic at the bitmap layer; this repo's path is
validated on ODF RBD, so chaos against CSI/Ceph is in scope for *this*
deployment's end-to-end resilience.

---

## 5. Network

| Component | Role |
|---|---|
| **Pod network (OVN-Kubernetes)** | Carries guest pod IP (masquerade interface on the VMI). Used by `virtctl ssh` / guest verify, not by the bitmap itself. |
| **API / service network** | Control traffic: `virt-controller` ↔ API ↔ `virt-handler` ↔ launcher; CSI ↔ Ceph. Partitioning here can stall backup reconcile or volume attach. |
| **Node CNI helpers** (`bridge-marker`, `kube-cni-linux-bridge-plugin`) | Node-level networking support for OpenShift Virtualization. |
| **`virt-api` / Kubernetes API server** | Serves VM, VMI, backup, tracker, and PVC APIs that the backup path updates. |

This density workflow does not create a Service or NetworkPolicy in the
test namespace for CBT itself. Network chaos matters most for
**controller ↔ launcher** and **CSI ↔ Ceph**, not for "bitmap math."

---

## 6. Supporting components (setup / verify, not CBT core)

| Component | Role |
|---|---|
| **cloud-init Secret** (`<vm>-userdata`) | Injects SSH keys and guest bootstrap; required for `verify` guest checks. |
| **container disk** | Fedora guest root image; workload data must stay on `/data` (data PVC), never silently on the container disk. |
| **CDI** | Provisions DataVolumes at setup; not in the steady-state CBT backup path. |
| **Evidence inspector pod** | Short-lived, read-only mount of **backup-output only**; runs `qemu-img info` to read `backing-filename`. Scheduled away from the VM node. |
| **Guest workload** (`/data/vm-validator`) | SQLite + log integrity signal for `verify`; proves the guest is alive and writing, not that CBT bitmaps are correct. |

---

## End-to-end layer map (compact)

```text
Guest writes
    → QEMU dirty bitmap (in virt-launcher; persisted via CBT overlay on state PVC)
    → VirtualMachineBackup + Tracker (virt-controller / virt-handler)
    → Push copy into backup-output PVC (hotplugged during backup)
    → Persistent volumes on ODF Ceph RBD (CSI node/controller + OSDs)
```

| Layer | What to name in a test plan |
|---|---|
| Config | HyperConverged `incrementalBackup` + CBT label selector |
| Control plane | `virt-controller`, `virt-api`, backup/tracker CRs |
| Node agent | `virt-handler` on the VMI node |
| Guest process | `virt-launcher` / QEMU |
| CBT state | overlay file + `persistent-state-for-*` PVC |
| Guest data | `<vm>-data` PVC |
| Backup sink | `<vm>-backup-output` PVC |
| Storage | RBD CSI node/ctrl, Ceph OSD/MON, StorageClass |
| Network | OVN pod net, API path, CSI↔Ceph |
| Proof | qcow2 `backing-filename` via evidence inspector |

---

## Detecting when backup is in progress (chaos inject window)

Use CR **conditions** as the synchronization barrier for "inject now". Do
**not** use `.status.type`, tracker checkpoints, or controller logs to decide
whether the resulting backup was a genuine Full/Incremental — that stays with
`scripts/cbt-evidence-check.sh` (qcow2 `backing-filename`).

### Primary trigger (recommended)

This is what `scripts/run-cbt-krkn-scenario.sh` and `scripts/run-krkn-ai-cbt.sh`
already wait on before starting chaos:

```bash
oc get virtualmachinebackup "$VMB" -n "$NS" -o json \
  | jq -e '.status.conditions // [] | any(.[]; .type=="Progressing" and .status=="True")'
```

Observed lifecycle on a push Incremental (release-dependent names; this cluster
uses `Done`, not upstream `Complete`):

| Phase | Conditions / signals | Chaos? |
| --- | --- | --- |
| Attach | `Initializing=True`, `Progressing=False`, reason ≈ *backup target PVC … is being attached*; `hp-volume-*` pod appears | Too early (PVC not mounted yet) |
| **In progress** | **`Progressing=True`**, reason=`Backup is in progress`; `Done=False`; `status.type` already `Full`/`Incremental`; `checkpointName` set; finalizer `backup.kubevirt.io/vmbackup-protection` | **Inject here** |
| Terminal | `Progressing=False`, `Done=True`, reason=`Successfully completed VirtualMachineBackup` | Window closed |

Inspect the full status shape:

```bash
oc get virtualmachinebackup "$VMB" -n "$NS" -o json \
  | jq '.status | {type, checkpointName, includedVolumes, conditions}'
```

### Secondary signals (correlate, do not gate on alone)

- **Events:** `SuccessfulCreate` for hotplug / `VolumeMountedToPod` for
  `*-backup-target-pvc`; later `VirtualMachineBackupCompletedSuccessfully`.
- **Pods:** short-lived `hp-volume-*` on the VMI node while the backup PVC is
  hotplugged into `virt-launcher`.
- **QEMU block job** (best-effort, inside the launcher compute container):

  ```bash
  DOM="<namespace>_<vm>"   # e.g. cbt-gcp-20260923_fedora-cbt-1
  oc exec -n "$NS" "$LAUNCHER_POD" -c compute -- \
    virsh qemu-monitor-command "$DOM" '{"execute":"query-block-jobs"}'
  ```

  A running job shows `"type":"backup"` and `"status":"running"` (`offset` /
  `len` advance). Dirty bitmaps after a long guest write window can make
  Incremental transfer nearly a full-disk size — expect a long
  `Progressing=True` window.
- **Logs:** virt-controller `Starting backup…` / `Started backup… successfully`;
  virt-handler / libvirt during the job. Useful for forensics, not for the
  inject gate.

### After injection

Validate with physical evidence, not VMB status:

```bash
make cbt-evidence VMS=<vm-name>
# or: make verify VMS=<vm-name>
```

---

## Suggested chaos injection order

Ranked by how directly each hit sits on the Incremental path:

1. **`virt-launcher`** mid-Incremental — classic bitmap invalidate / silent Full fallback
2. **`virt-handler`** on the VM node during hotplug or checkpoint redefine
3. **CSI RBD nodeplugin** or **OSD** under the state or data PVC
4. **`virt-controller`** during backup reconcile
5. **Network partition** launcher ↔ storage, or controller ↔ launcher
6. **Do not** dual-mount `persistent-state-for-*` or the data PVC from a second pod while the VM runs (tooling hazard, not a useful scenario)

After injection, validate with:

```bash
make cbt-evidence VMS=<vm-name>
# or: make verify VMS=<vm-name>
```

Expect Incremental artifacts to show:

```text
backing-filename = /var/run/kubevirt-private/libvirt/qemu/cbt/datadisk.qcow2
```

and Full artifacts to show **no** `backing-filename`. A completed backup CR
is not proof of restoreability or of genuine CBT.
