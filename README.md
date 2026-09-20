# ODF CBT

Reusable lab manifests and documentation for:

1. Setting up OpenShift Data Foundation with local devices.
2. Creating an OpenShift Virtualization Fedora VM on ODF Ceph-RBD.
3. Enabling and verifying KubeVirt Changed Block Tracking.
4. Taking full and incremental `VirtualMachineBackup` resources.

## Repository layout

```text
docs/ODF-SETUP.md             ODF deployment and troubleshooting
docs/CBT-ARCHITECTURE.md      KubeVirt CBT design and state model
docs/CBT-TEST-GUIDE.md        End-to-end commands and verification
manifests/fedora-cbt-vm.yaml  Generic ODF-backed Fedora VM
manifests/backup-pvc.yaml     Backup output PVC
manifests/backup-tracker.yaml CBT checkpoint tracker
manifests/full-backup.yaml    First/full backup
manifests/incremental-backup.yaml Follow-up/incremental backup
```

## Quick start

```bash
export KUBECONFIG=/path/to/kubeconfig
oc create namespace cbt-demo --dry-run=client -o yaml | oc apply -f -
oc apply -f manifests/fedora-cbt-vm.yaml
oc apply -f manifests/backup-pvc.yaml
oc wait --for=condition=Ready vm/fedora-cbt-vm -n cbt-demo --timeout=300s
oc apply -f manifests/backup-tracker.yaml
oc apply -f manifests/full-backup.yaml
# Wait for the full backup to reach Done=True before creating the next backup.
oc get virtualmachinebackup fedora-cbt-vm-full -n cbt-demo -o yaml
oc apply -f manifests/incremental-backup.yaml
oc get virtualmachinebackup fedora-cbt-vm-incremental -n cbt-demo -o yaml
```

Read the detailed procedures first:

- `docs/ODF-SETUP.md`
- `docs/CBT-ARCHITECTURE.md`
- `docs/CBT-TEST-GUIDE.md`

The manifests use generic names and the `ocs-storagecluster-ceph-rbd` StorageClass. Change the StorageClass and namespace for the target cluster as needed.
