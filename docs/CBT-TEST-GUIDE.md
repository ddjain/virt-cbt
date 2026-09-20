# Test CBT With an ODF-Backed Fedora VM

## Variables

Set these variables for a target cluster:

```bash
export NAMESPACE=cbt-demo
export VM_NAME=fedora-cbt-vm
export DATA_VOLUME_NAME=fedora-cbt-vm-data
export DATA_SC=ocs-storagecluster-ceph-rbd
export BACKUP_PVC=cbt-backup-output
export TRACKER_NAME=fedora-cbt-tracker
export KUBECONFIG=/path/to/kubeconfig
```

The VM name is intentionally generic. Change it only through these variables and matching manifest fields.

## Prerequisites

```bash
oc get hyperconverged -A -o json \
  | jq '.items[] | {name:.metadata.name,featureGates:.spec.featureGates,cbt:.spec.configuration.changedBlockTrackingLabelSelectors}'
oc get crd virtualmachinebackups.backup.kubevirt.io
oc get crd virtualmachinebackuptrackers.backup.kubevirt.io
oc get storagecluster,cephcluster -n openshift-storage -o wide
oc get volumesnapshotclass
```

Required:

- `incrementalBackup` feature gate enabled.
- CBT label selector matches `changedBlockTracking: "true"`.
- ODF is healthy.
- `DATA_SC` exists and provisions PVCs.
- A default StorageClass exists for the CBT backend-state PVC.
- An RBD VolumeSnapshotClass exists if the release requires snapshot capability checks.

Set the ODF RBD class as default only after checking shared-cluster impact:

```bash
oc patch storageclass "$DATA_SC" --type=merge \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

## Create the VM and backup PVC

```bash
oc create namespace "$NAMESPACE" --dry-run=client -o yaml | oc apply -f -
oc apply -f manifests/fedora-cbt-vm.yaml
oc apply -f manifests/backup-pvc.yaml
```

Wait for storage and VM readiness:

```bash
oc wait --for=jsonpath='{.status.phase}'=Bound \
  pvc/"$DATA_VOLUME_NAME" -n "$NAMESPACE" --timeout=300s
oc wait --for=jsonpath='{.status.phase}'=Bound \
  pvc/"$BACKUP_PVC" -n "$NAMESPACE" --timeout=300s
oc wait --for=condition=Ready vm/"$VM_NAME" -n "$NAMESPACE" --timeout=300s
oc get vm,vmi,pvc -n "$NAMESPACE"
```

The VM may require a DataVolume to complete before the VMI starts.

## Verify CBT state

```bash
oc get vm "$VM_NAME" -n "$NAMESPACE" -o json \
  | jq '.status.changedBlockTracking, .status.volumeSnapshotStatuses'
```

Expected:

```json
{"state":"Enabled"}
```

If the state is `PendingRestart`, restart the VM and check again:

```bash
oc patch vm "$VM_NAME" -n "$NAMESPACE" --type=merge -p '{"spec":{"runStrategy":"Halted"}}'
# wait for the VMI to disappear
oc patch vm "$VM_NAME" -n "$NAMESPACE" --type=merge -p '{"spec":{"runStrategy":"Always"}}'
```

## Create the tracker

```bash
oc apply -f manifests/backup-tracker.yaml
oc get virtualmachinebackuptracker "$TRACKER_NAME" -n "$NAMESPACE" -o yaml
```

## Take the first full backup

```bash
oc apply -f manifests/full-backup.yaml
oc wait --for=jsonpath='{.status.type}'=Full \
  virtualmachinebackup/"$VM_NAME-full" -n "$NAMESPACE" --timeout=600s
oc get virtualmachinebackup "$VM_NAME-full" -n "$NAMESPACE" -o json \
  | jq '{type:.status.type,checkpoint:.status.checkpointName,conditions:.status.conditions,volumes:.status.includedVolumes}'
```

The first backup should report `Done=True` and `type: Full`.

## Take the incremental backup

Wait long enough for the workload to make another write, then apply the second manifest:

```bash
oc apply -f manifests/incremental-backup.yaml
oc wait --for=jsonpath='{.status.type}'=Incremental \
  virtualmachinebackup/"$VM_NAME-incremental" -n "$NAMESPACE" --timeout=600s
oc get virtualmachinebackup "$VM_NAME-incremental" -n "$NAMESPACE" -o json \
  | jq '{type:.status.type,checkpoint:.status.checkpointName,conditions:.status.conditions,volumes:.status.includedVolumes}'
```

Expected:

```text
type: Incremental
Done=True
```

Verify tracker advancement:

```bash
oc get virtualmachinebackuptracker "$TRACKER_NAME" -n "$NAMESPACE" -o json \
  | jq '.status.latestCheckpoint'
```

## Optional timestamp workload

The optional timestamp variant is in `manifests/fedora-cbt-timestamp-vm.yaml`. It installs a script like:

```bash
#!/bin/bash
date --iso-8601=seconds >> /data/log.txt
```

and a systemd timer. Use it only if the guest image processes the supplied cloud-init data and mounts `/dev/vdc` at `/data`. Verify the log from inside the guest or with a maintenance pod after stopping the VM; do not assume the log exists solely because the cloud-init manifest was accepted.

## Verification summary

```bash
oc get vm "$VM_NAME" -n "$NAMESPACE" -o wide
oc get pvc -n "$NAMESPACE"
oc get virtualmachinebackup -n "$NAMESPACE" \
  -o custom-columns=NAME:.metadata.name,TYPE:.status.type,DONE:.status.conditions[-1].status,CHECKPOINT:.status.checkpointName
oc get virtualmachinebackuptracker "$TRACKER_NAME" -n "$NAMESPACE" -o yaml
```

The meaningful CBT result is:

```text
first backup: Done / Full
second backup: Done / Incremental
tracker: latest checkpoint updated
VM: CBT Enabled
```

## Troubleshooting

### No default StorageClass

The VM may report `FailedBackendStorageCreate` or `no default storage class found`. Set an approved default StorageClass and restart the VM.

### CBT remains Initializing

Check the VM label, HCO selector, feature gate, VMI state, and virt-handler logs. A restart is normally required.

### Backup says the VM has no CBT

Confirm both VM and VMI status:

```bash
oc get vm,vmi "$VM_NAME" -n "$NAMESPACE" -o json \
  | jq '.items[] | {kind:.kind,name:.metadata.name,cbt:.status.changedBlockTracking}'
```

### Backup target is stuck attaching

The backup PVC is RWO. Ensure it is not mounted by another workload or backup and wait for the previous backup to complete.

### Second backup is Full

Confirm that the same tracker was used and that the first backup completed. A crash, online snapshot restore, disk reattach, or bitmap loss can cause per-disk fallback to full.

## Cleanup

```bash
oc delete namespace "$NAMESPACE"
```

Only run cleanup after confirming that the VM, backups, tracker, PVCs, and backup contents are disposable.
