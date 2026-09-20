# ODF and CBT Scenarios

This catalog turns the repository into repeatable lab scenarios. Each scenario has a purpose, prerequisites, procedure, expected evidence, and cleanup guidance.

## Scenario 1: Validate an Existing ODF Installation

### Purpose

Confirm that ODF is healthy before involving OpenShift Virtualization.

### Commands

```bash
oc get storagecluster,cephcluster -n openshift-storage -o wide
oc get cephblockpool,cephfilesystem,cephobjectstore -n openshift-storage -o wide
oc get pods -n openshift-storage
oc get sc
```

### Expected evidence

- `StorageCluster`: `Ready`
- `CephCluster`: `Ready`
- Ceph health: `HEALTH_OK`
- Block pool, filesystem, and object store: `Ready`
- ODF RBD StorageClass exists

### Failure path

Use `docs/ODF-SETUP.md` for OSD preparation, stale CSI credentials, StorageClient, and NooBaa troubleshooting.

## Scenario 2: Provision and Mount an ODF RBD PVC

### Purpose

Verify that the RBD CSI path can provision and mount storage independently of VM backup.

### Procedure

```bash
oc create namespace odf-smoke
oc apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: rbd-smoke
  namespace: odf-smoke
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
  storageClassName: ocs-storagecluster-ceph-rbd
---
apiVersion: v1
kind: Pod
metadata:
  name: rbd-smoke
  namespace: odf-smoke
spec:
  containers:
  - name: test
    image: registry.access.redhat.com/ubi9/ubi-minimal
    command: ["/bin/sh", "-c", "echo odf-ok >/data/result; test \"$(cat /data/result)\" = odf-ok; sleep 10"]
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: rbd-smoke
EOF
oc wait --for=jsonpath='{.status.phase}'=Bound pvc/rbd-smoke -n odf-smoke --timeout=120s
oc wait --for=condition=Ready pod/rbd-smoke -n odf-smoke --timeout=120s
oc logs -n odf-smoke rbd-smoke
```

### Expected evidence

The log contains `odf-ok`. Delete the namespace after the test:

```bash
oc delete namespace odf-smoke --wait=false
```

## Scenario 3: Create a Fedora VM on ODF

### Purpose

Create a generic OpenShift Virtualization VM whose data disk is provisioned by ODF Ceph-RBD.

### Procedure

```bash
oc create namespace cbt-demo --dry-run=client -o yaml | oc apply -f -
oc apply -f manifests/fedora-cbt-vm.yaml
oc apply -f manifests/backup-pvc.yaml
oc wait --for=condition=Ready vm/fedora-cbt-vm -n cbt-demo --timeout=300s
```

### Expected evidence

```bash
oc get vm,vmi,pvc -n cbt-demo
```

Expected:

- VM is `Running` and `Ready`.
- DataVolume/PVC is `Bound`.
- Data PVC StorageClass is `ocs-storagecluster-ceph-rbd`.
- KubeVirt creates a CBT backend-state PVC using the default StorageClass.

## Scenario 4: Enable and Verify CBT

### Purpose

Confirm that the VM is selected by the cluster CBT selector and that its data disk is actively tracked.

### Preconditions

```bash
oc get hyperconverged -A -o json \
  | jq '.items[] | {featureGates:.spec.featureGates,cbt:.spec.configuration.changedBlockTrackingLabelSelectors}'
```

The VM must have:

```yaml
metadata:
  labels:
    changedBlockTracking: "true"
```

The data disk must have:

```yaml
changedBlockTracking: true
```

### Verification

```bash
oc get vm fedora-cbt-vm -n cbt-demo -o json \
  | jq '.status.changedBlockTracking, .status.volumeSnapshotStatuses'
```

Expected:

```json
{"state":"Enabled"}
```

If the state is `PendingRestart`, stop and start the VM, then check again.

## Scenario 5: Take a Full Backup

### Purpose

Create the first checkpoint for a VM backup chain.

### Procedure

```bash
oc apply -f manifests/backup-tracker.yaml
oc apply -f manifests/full-backup.yaml
oc get virtualmachinebackup fedora-cbt-vm-full -n cbt-demo -o yaml
```

### Expected evidence

```text
status.type: Full
Done=True
status.checkpointName: <checkpoint-a>
```

The tracker should record checkpoint A:

```bash
oc get virtualmachinebackuptracker fedora-cbt-tracker -n cbt-demo -o yaml
```

## Scenario 6: Take an Incremental Backup

### Purpose

Prove that the tracker causes a later backup to use the prior checkpoint.

### Procedure

Wait for the VM workload to perform a write, then run:

```bash
oc apply -f manifests/incremental-backup.yaml
oc get virtualmachinebackup fedora-cbt-vm-incremental -n cbt-demo -o yaml
oc get virtualmachinebackuptracker fedora-cbt-tracker -n cbt-demo -o yaml
```

### Expected evidence

```text
status.type: Incremental
Done=True
status.checkpointName: <checkpoint-b>
tracker.latestCheckpoint: <checkpoint-b>
```

The first and second backup must use the same tracker. A new tracker starts a new chain and normally produces a full backup.

## Scenario 7: Timestamp-Writer Workload

### Purpose

Use a small guest workload that writes a timestamp repeatedly to an ODF-backed data disk.

### Workload

```bash
#!/bin/bash
date --iso-8601=seconds >> /data/log.txt
```

A complete example can be added as a separate VM manifest. The guest must:

1. Format `/dev/vdc` only when it has no filesystem.
2. Mount `/dev/vdc` at `/data`.
3. Write timestamps to `/data/log.txt`.
4. Run the script from a systemd timer or equivalent.

### Verification

Verify the file from inside the guest or by stopping the VM and mounting the PVC in a maintenance pod:

```bash
wc -l /mnt/log.txt
tail -5 /mnt/log.txt
```

Do not treat successful cloud-init submission as proof that the guest timer ran. The file must be read and its timestamps confirmed.

## Scenario 8: CBT Failure Diagnosis

### Symptom: CBT remains `PendingRestart`

Check the VM label, HCO selector, feature gate, and restart the VM.

### Symptom: `no default storage class found`

Set an approved default StorageClass and restart the VM. The default is used for the CBT backend-state PVC.

### Symptom: Backup says CBT is unavailable

Check VM and VMI status:

```bash
oc get vm,vmi fedora-cbt-vm -n cbt-demo -o json \
  | jq '.items[] | {kind:.kind,name:.metadata.name,cbt:.status.changedBlockTracking}'
```

### Symptom: Second backup is full

Check that:

- The first backup completed.
- The same tracker is used.
- The VM did not crash.
- The disk was not detached and reattached.
- An online snapshot restore did not reset bitmap state.

Per-volume bitmap loss can cause a disk to fall back to full.

## Scenario 9: Cleanup

### Delete only the scenario namespace

```bash
oc delete namespace cbt-demo
```

### Preserve ODF

Do not delete the StorageCluster, default StorageClass, CBT feature gate, or cluster-wide selector when cleaning up a VM scenario. Those are shared cluster resources.
