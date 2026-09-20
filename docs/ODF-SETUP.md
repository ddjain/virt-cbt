# OpenShift Data Foundation Setup

This guide installs ODF on an OpenShift cluster using Local Storage Operator devices. It is written for a lab cluster; adapt node selection, capacity, release channels, and cleanup policy for production.

## Prerequisites

- OpenShift cluster-admin access.
- ODF operators installed and in `Succeeded` phase.
- Local Storage Operator installed.
- At least three storage nodes in separate failure domains.
- At least one unused block device per storage node; three or more devices per node is preferred.
- Devices are unclaimed and may be erased.

Set the kubeconfig for the target cluster before running commands:

```bash
export KUBECONFIG=/path/to/kubeconfig
oc whoami
oc get clusterversion
```

## Inspect operators and nodes

```bash
oc get nodes -o wide
oc get csv -A
oc get subscriptions -A
oc get storagecluster -A
oc get nodes -l cluster.ocs.openshift.io/openshift-storage -o wide
```

Confirm that the ODF operators are `Succeeded` and the selected nodes are `Ready`.

## Inspect local devices and PVs

```bash
oc get localvolumeset -n openshift-local-storage -o yaml
oc get pv -o custom-columns=NAME:.metadata.name,SC:.spec.storageClassName,CAPACITY:.spec.capacity.storage,STATUS:.status.phase
```

Use only `Available` PVs backed by devices that are confirmed safe to initialize. Record the backing StorageClass; this guide uses `localblock-sc`.

## Create the StorageCluster

Save and apply:

```yaml
apiVersion: ocs.openshift.io/v1
kind: StorageCluster
metadata:
  name: ocs-storagecluster
  namespace: openshift-storage
spec:
  flexibleScaling: false
  monDataDirHostPath: /var/lib/rook
  enableCephTools: true
  storageDeviceSets:
  - name: ocs-deviceset
    count: 3
    replica: 3
    portable: false
    dataPVCTemplate:
      spec:
        accessModes:
        - ReadWriteOnce
        resources:
          requests:
            storage: 1.4Ti
        storageClassName: localblock-sc
        volumeMode: Block
```

```bash
oc apply -f storagecluster.yaml
oc get storagecluster -n openshift-storage -o wide
```

`count: 3` creates three devices per device-set replica. `replica: 3` spreads the device sets across three failure domains. Adjust the requested device size to match the available local PVs.

## Stale Ceph metadata

If OSD preparation fails with a message such as:

```text
failed to get device already provisioned by ceph-volume
```

inspect the OSD prepare logs and verify that the affected PVs are unclaimed. If the old disk contents are disposable, enable cleanup of devices from other Ceph clusters:

```bash
oc patch storagecluster ocs-storagecluster -n openshift-storage --type=merge \
  -p '{"spec":{"managedResources":{"cephCluster":{"cleanupPolicy":{"wipeDevicesFromOtherClusters":true}}}}}'
```

Delete only the failed OSD preparation Jobs after the policy is propagated so the operator recreates them:

```bash
oc get pods -n openshift-storage | grep rook-ceph-osd-prepare
oc delete job -n openshift-storage <failed-prepare-job>
```

**Destructive operation:** this can erase stale Ceph signatures and data on selected devices. Never enable it without confirming ownership.

## Stale StorageClient or CSI credentials

If RBD provisioning times out or returns `Permission denied`, inspect the client and monitor configuration:

```bash
oc get storageclient -o yaml
oc get cephconnection -n openshift-storage -o yaml
oc get cm ceph-csi-config -n openshift-storage -o yaml
oc get secret -n openshift-storage | grep csi
```

A stale StorageClient may be stuck in `Offboarding` and may reference old monitor addresses or old Ceph credentials. On a new/reinitialized lab cluster, remove the stale object and allow the OCS client operator to recreate it:

```bash
oc delete storageclient ocs-storagecluster
oc patch storageclient ocs-storagecluster --type=merge \
  -p '{"metadata":{"finalizers":[]}}'
```

Confirm:

```bash
oc get storageclient -o json | jq '.items[] | {name:.metadata.name,status:.status}'
```

Expected state:

```text
phase: Connected
```

If CSI controllers still use old state, restart them after the regenerated connection and secrets exist:

```bash
oc rollout restart deployment/openshift-storage.rbd.csi.ceph.com-ctrlplugin -n openshift-storage
oc rollout restart deployment/openshift-storage.cephfs.csi.ceph.com-ctrlplugin -n openshift-storage
```

## NooBaa/CloudNativePG recovery

If NooBaa reports that its PostgreSQL cluster is unrecoverable because instance PVCs are missing, recreate the stale CNPG cluster in a lab environment:

```bash
oc get clusters -n openshift-storage
oc delete clusters noobaa-db-pg-cluster -n openshift-storage
oc get noobaa -n openshift-storage
```

Wait for NooBaa to return to `Ready`.

## Validate ODF

```bash
oc get storagecluster,cephcluster -n openshift-storage -o wide
oc get cephblockpool,cephfilesystem,cephobjectstore -n openshift-storage -o wide
oc get pods -n openshift-storage
oc get sc
```

Expected:

```text
StorageCluster: Ready
CephCluster: Ready / HEALTH_OK
CephBlockPool: Ready
CephFilesystem: Ready
CephObjectStore: Ready
```

Common ODF StorageClasses:

- `ocs-storagecluster-ceph-rbd`
- `ocs-storagecluster-ceph-rbd-virtualization`
- `ocs-storagecluster-cephfs`
- `ocs-storagecluster-ceph-rgw`

## Provisioning smoke test

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
oc delete namespace odf-smoke --wait=false
```

## Cleanup

Deleting the StorageCluster can destroy ODF data. Follow the ODF release-specific uninstall procedure and confirm that all PVC data is disposable before removing it. Do not reuse the device-wipe cleanup policy on a shared cluster without explicit approval.
