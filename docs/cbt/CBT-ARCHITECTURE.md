# KubeVirt Changed Block Tracking Architecture

## What is tested

This repository tests KubeVirt-native incremental VM backup with ODF Ceph-RBD as the VM storage backend.
Per-component dependency roles for chaos/test planning are in `CBT-COMPONENT-DEPENDENCIES.md`.
Operational checks, Prometheus metrics, and failure runbooks are in `CBT-OPERATIONS.md`.

The storage backend and CBT implementation are separate layers:

```text
VM guest writes
      |
      v
QEMU/libvirt disk
      |
      | QCOW2 overlay + dirty bitmap
      v
KubeVirt VirtualMachineBackup controller
      |
      | checkpoint + tracker
      v
Backup output PVC / backup consumer
      |
      v
ODF Ceph-RBD CSI storage
```

ODF provides the persistent VM disk, CBT backend-state PVC, and backup-output PVC. QEMU/libvirt provides the dirty-bit tracking. The ODF CSI driver does not need to implement CSI Snapshot Metadata Service for this KubeVirt-native path.

## Components

### HyperConverged feature gate

The `incrementalBackup` feature gate must be enabled in the OpenShift Virtualization configuration.

### CBT label selector

Cluster configuration selects VMs for CBT:

```yaml
changedBlockTrackingLabelSelectors:
  virtualMachineLabelSelector:
    matchLabels:
      changedBlockTracking: "true"
```

Only VMs matching the selector are enabled. A disk-level `changedBlockTracking: true` field alone is not sufficient.

### VM disk field

The VM data disk opts into CBT:

```yaml
- name: datadisk
  changedBlockTracking: true
  disk:
    bus: virtio
```

### Backend-state PVC

KubeVirt creates a PVC similar to:

```text
persistent-state-for-<vm-name>-<suffix>
```

It stores VM state required for CBT overlays, checkpoints, and related metadata. KubeVirt needs a default StorageClass to create it.

### QCOW2 overlay

KubeVirt normally presents raw VM disks. CBT uses a thin QCOW2 overlay containing the dirty bitmap and points the overlay at the raw data disk as its data store.

### Backup tracker

`VirtualMachineBackupTracker` stores the latest checkpoint for a VM and backup consumer. The first backup with an empty tracker is full. A later backup referencing the same tracker can use the previous checkpoint and be incremental.

### VirtualMachineBackup

`VirtualMachineBackup` starts a backup operation. Push mode writes to a filesystem PVC. Its `pvcName` field is required. The status reports:

- `type`: `Full` or `Incremental`
- `checkpointName`
- `includedVolumes`
- completion conditions

## CBT state machine

Typical VM status progression:

```text
Undefined
   |
   v
PendingRestart
   |
   v
Initializing
   |
   v
Enabled
```

A restart is required when a running VM newly matches the selector or when CBT is newly enabled. If CBT is disabled or the VM stops matching the selector, the state can transition through disabled/pending-restart states.

## Backup sequence

```text
1. VM matches CBT selector
2. Data disk has changedBlockTracking: true
3. VM restarts
4. CBT state becomes Enabled
5. Create tracker with no checkpoint
6. Create backup A
7. Backup A creates checkpoint A and reports Full
8. Tracker records checkpoint A
9. Create backup B using same tracker
10. Backup B uses checkpoint A and reports Incremental
11. Tracker records checkpoint B
```

## Important limitations

- CBT and the `VirtualMachineBackup` APIs are release-dependent alpha/technology-preview functionality.
- `Incremental` status proves checkpoint-based mode selection; it does not expose a simple changed-byte count.
- A real backup consumer must read the push payload or pull-mode endpoints to measure transferred blocks.
- Online snapshots, disk detach/reattach, crashes, or bitmap loss can cause a later disk to fall back to full backup.
- The backup API is a low-level primitive. Production retention, transport, encryption, restore, and application consistency require a complete backup solution.
- CSI Snapshot Metadata Service CBT is a separate feature and should not be confused with this KubeVirt-native CBT mechanism.
