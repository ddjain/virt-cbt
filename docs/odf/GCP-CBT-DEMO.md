# GCP ODF CBT demonstration record

Target: `blue-cluster-qjm5h` in GCP project `cclm-chaos-testing`, region `us-central1`; deployment started 2026-09-23. These commands were run from the repository root. **No commit was made.** The copied `kubeconfig`, `config.env`, SSH keys, and deployment manifests in `reports/gcp-odf-demo-20260923/` are ignored by Git; never commit them. ODF operators were already installed before this work.

## Provisioned resources and commands

```bash
install -m 600 /Users/darjain/projects/krkn-chaos/krkn/example/pre-chaos-check-test/kubeconfig kubeconfig
git check-ignore -v kubeconfig
# machinesets.json was generated from the three existing worker-{a,b,c} MachineSets:
# distinct names/selector labels blue-cluster-qjm5h-odf-demo-{a,b,c},
# one replica per zone, machineType n2-standard-8, unchanged GCP network,
# worker credentials and 128 GB boot disk; owned label odf-cbt-demo.
oc --kubeconfig=kubeconfig apply --dry-run=server -f reports/gcp-odf-demo-20260923/machinesets.json
oc --kubeconfig=kubeconfig apply -f reports/gcp-odf-demo-20260923/machinesets.json
oc --kubeconfig=kubeconfig wait machineset -n openshift-machine-api -l app.kubernetes.io/managed-by=odf-cbt-demo --for=jsonpath='{.status.readyReplicas}'=1 --timeout=600s
oc --kubeconfig=kubeconfig label nodes blue-cluster-qjm5h-odf-demo-a-5ccwp blue-cluster-qjm5h-odf-demo-b-gkbr4 blue-cluster-qjm5h-odf-demo-c-jxgb9 app.kubernetes.io/managed-by=odf-cbt-demo cluster.ocs.openshift.io/openshift-storage= --overwrite
oc --kubeconfig=kubeconfig apply --dry-run=server -f reports/gcp-odf-demo-20260923/storagecluster.yaml
oc --kubeconfig=kubeconfig apply -f reports/gcp-odf-demo-20260923/storagecluster.yaml
oc --kubeconfig=kubeconfig wait storagecluster/ocs-storagecluster -n openshift-storage --for=condition=Available=True --timeout=1800s
make generate-keys
```

The final `StorageCluster` manifest uses `resourceProfile: lean`, host-path monitor data, three replicas of one 512 Gi Block OSD PVC each, the existing `standard-csi` GCP PD class (HDD), explicit `deviceClass: hdd`, and the three labeled workers. It skips MCG and the GCP object store; CephFS must remain enabled because the ODF lean-profile reconciliation expects its two MDS pods. NooBaa and monitor PVCs did not create additional GCP disks. The operator created three **512 Gi** HDD Persistent Disks, one each in `us-central1-a`, `us-central1-b`, and `us-central1-c`. Their CSI handles are recorded in the ignored `reports/gcp-odf-demo-20260923/created-disks.json`. The ODF RBD class is `ocs-storagecluster-ceph-rbd`.

The pre-existing default StorageClass was `standard-csi`. KubeVirt can allocate CBT backend-state PVCs using the default, so it was changed to ODF RBD to avoid creating unapproved per-VM GCP disks:

```bash
oc --kubeconfig=kubeconfig annotate storageclass standard-csi storageclass.kubernetes.io/is-default-class-
oc --kubeconfig=kubeconfig annotate storageclass ocs-storagecluster-ceph-rbd storageclass.kubernetes.io/is-default-class=true
oc --kubeconfig=kubeconfig annotate storageclass standard-csi storageclass.kubernetes.io/is-default-class-
```

The cluster's default-class controller briefly restored `standard-csi` after the first removal; the final removal above was repeated after ODF RBD already had the default annotation. Confirm exactly one default before creating VMs.

A pre-existing `blue-cluster-qjm5h-worker-c-8vdhs` stopped reporting to the API and blocked cluster operators. Its replacement was requested through its original MachineSet with:

```bash
oc --kubeconfig=kubeconfig delete machine blue-cluster-qjm5h-worker-c-8vdhs -n openshift-machine-api --wait=false
```

The OpenShift update channel was changed from `stable-4.21` to `stable-4.22` with:

```bash
oc --kubeconfig=kubeconfig adm upgrade channel stable-4.22
```

The cluster first accepted the recommended 4.21 patch update; the command below starts a rolling upgrade, not an immediate completion:

```bash
oc --kubeconfig=kubeconfig adm upgrade --to=4.21.33
```

After the patch and both MachineConfigPools converged, the recommended OpenShift 4.22 update was started:

```bash
oc --kubeconfig=kubeconfig adm upgrade --to=4.22.14
```
The patch and 4.22.14 updates completed; the cluster now reports 4.22.14. OpenShift Virtualization upgraded to `kubevirt-hyperconverged-operator.v4.22.9` (`Succeeded`) and serves the backup/tracker APIs.

Changing the channel alone does not upgrade the cluster. OpenShift upgrades, once performed, cannot be reversed by deleting demo resources.

The patch rollout initially could not drain `worker-a` because the pre-existing `cbt-test/fedora-cbt-test` VMI uses an RWO PVC and is not live-migratable. It was paused without deleting its VM or 10 Gi PVC:

```bash
oc --kubeconfig=kubeconfig patch vm fedora-cbt-test -n cbt-test --type=merge -p '{"spec":{"running":false}}'
```

Keep it stopped through the cluster and Virtualization upgrades. After both are complete and `worker`/`master` MachineConfigPools are updated, restore its prior running state with `oc --kubeconfig=kubeconfig patch vm fedora-cbt-test -n cbt-test --type=merge -p '{"spec":{"running":true}}`; verify the VMI is Running and the PVC remains Bound.
The pre-existing VM is running again after the upgrade; its original 10 Gi standard-csi PVC remained Bound.

The CBT gate and VM selector were enabled through the HCO CR using the patch file created for this setup:

```bash
oc --kubeconfig=kubeconfig patch hco kubevirt-hyperconverged -n openshift-cnv --type=merge --patch-file=reports/gcp-odf-demo-20260923/hco-cbt-settings.json
```

`incrementalBackup` is a Technology Preview feature gate in this Virtualization release.
The HCO reconciled `IncrementalBackup` and `UtilityVolumes` into KubeVirt and set the VM selector. Both backup APIs are served.

## Verification commands

```bash
oc --kubeconfig=kubeconfig get storagecluster,cephcluster,cephfilesystem -n openshift-storage -o wide
oc --kubeconfig=kubeconfig get pvc -n openshift-storage -o wide
oc --kubeconfig=kubeconfig get pv -o json | jq '[.items[]|select(.spec.claimRef.namespace=="openshift-storage")|{claim:.spec.claimRef.name,capacity:.spec.capacity.storage,handle:.spec.csi.volumeHandle}]'
make check-prereqs
make density-setup N=2
make backup N=2
make cbt-backup N=2
make verify N=2
make status ALL=1
```

The demo uses ignored `config.env`: namespace `cbt-gcp-20260923`, two Fedora VMs, 4 Gi data PVCs and 8 Gi backup-output PVCs per VM on ODF RBD. Never use a namespace already owned by another workload.

Both VMs reached `Running` with CBT `Enabled`; their 4 Gi data PVCs, 8 Gi backup-output PVCs, and 554 Mi CBT state PVCs are Bound to ODF RBD. Full backups passed for both VMs in `reports/run-20260923T094914Z-backup/summary.json`; Incremental backups passed in `reports/run-20260923T095203Z-cbt-backup/summary.json`; `make verify N=2` passed both guest/data-integrity checks in `reports/run-20260923T095301Z-verify/summary.json`.

On this macOS host, `/bin/bash` is 3.2 and the initial `make density-setup N=2` exited after creating the VM pool because `mapfile` is unavailable in Bash 3.2. The validator’s selector/readiness array loads were changed to Bash-3-compatible `while read` loops; `make discover-vms N=2`, `make density-status SUMMARY=1`, and the readiness wait then worked. The `make status` jq fallback was also corrected.

ODF reached `StorageCluster=Ready`, `CephCluster=Ready/HEALTH_OK`, and three 512 Gi OSD PVCs bound to GCP CSI disks in separate zones. A disposable `odf-cbt-smoke-20260923-1790146125` namespace provisioned a 1 Gi RBD PVC, mounted it in a UBI pod, wrote `/data/proof`, and read back `odf-rbd-ok`. Both smoke namespaces were deleted; cleanup briefly waited for the pre-existing CDI upload API to recover after replacing its unhealthy worker.

## Decommission the demonstration

Deleting ODF data is destructive. Preserve the ODF operator installation, which predates this demo. Do not delete the three worker MachineSets while OSDs or RBD claims still depend on them.

1. Verify `cbt-gcp-20260923` is labeled `app.kubernetes.io/managed-by=odf-cbt-validator`; then run `make density-teardown` with this repository's `config.env`. It deletes only the utility-owned namespace and its demo claims. If namespace deletion hangs, fix API discovery first; do not strip finalizers blindly.
  Before removing ODF, remove this demo's CBT preview gate and selector from HCO after the demo VM namespace is torn down:

  ```bash
  oc --kubeconfig=kubeconfig patch hco kubevirt-hyperconverged -n openshift-cnv --type=merge -p '{"spec":{"featureGates":null,"virtualization":{"changedBlockTrackingLabelSelectors":null}}}'
  ```
2. Before removing ODF, restore the original default class in this order: `oc --kubeconfig=kubeconfig annotate storageclass standard-csi storageclass.kubernetes.io/is-default-class=true`, then `oc --kubeconfig=kubeconfig annotate storageclass ocs-storagecluster-ceph-rbd storageclass.kubernetes.io/is-default-class-`. The StorageCluster currently has `uninstall.ocs.openshift.io/mode=graceful` and `uninstall.ocs.openshift.io/cleanup-policy=delete`. After reviewing Red Hat's [internal-mode uninstall procedure](https://access.redhat.com/articles/6525111), request removal with `oc --kubeconfig=kubeconfig delete storagecluster ocs-storagecluster -n openshift-storage --wait=true`; do not strip its finalizer if cleanup hangs. Confirm all three 512 Gi OSD PVCs, their PVs, and the CSI disks listed in `created-disks.json` are gone in GCP. Preserve the pre-existing ODF operator subscriptions.
  After confirming the StorageCluster is removed, no ODF PVC/PV references remain, and the disks are detached, check/delete any orphaned disks from a GCP-authenticated shell (not run during this setup):

  ```bash
  gcloud compute disks delete pvc-3d5a5776-969a-4f30-beea-54bb57a8d31f --project=cclm-chaos-testing --zone=us-central1-a
  gcloud compute disks delete pvc-00926db5-f211-4585-914e-e05ec4034cac --project=cclm-chaos-testing --zone=us-central1-b
  gcloud compute disks delete pvc-b3a8fab9-b43c-4741-8930-40e89d394a78 --project=cclm-chaos-testing --zone=us-central1-c
  ```
3. Only after the disks are gone, run `oc --kubeconfig=kubeconfig delete -f reports/gcp-odf-demo-20260923/machinesets.json`. These three MachineSets own only the `odf-demo-{a,b,c}` nodes and their auto-deleted 128 GB boot disks. Verify `oc --kubeconfig=kubeconfig get machines -n openshift-machine-api -l app.kubernetes.io/managed-by=odf-cbt-demo` is empty and confirm the instances/disks are absent in the GCP project.
4. The original worker MachineSet and any OpenShift/Virtualization upgrade remain; do not downgrade OpenShift as part of demo cleanup. Restore the update channel only if a separate cluster administration plan requires it. Remove local ignored credentials/reports only when no longer needed.
