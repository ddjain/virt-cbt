# CBT Backup Operations, Dependencies, and Monitoring

This document is the operational companion to `CBT-ARCHITECTURE.md` and `CBT-TEST-GUIDE.md`. It describes every Kubernetes, KubeVirt, QEMU/libvirt, storage, node, network, and monitoring component involved in a KubeVirt-native Changed Block Tracking (CBT) backup.

For a concise role-per-component inventory aimed at chaos/test planning (PVCs, overlays, pods, storage, network, injection order), see `CBT-COMPONENT-DEPENDENCIES.md`.

The commands are written for OpenShift (`oc`). Replace namespaces and names with the values used by the target cluster.

## Scope and version warning

This is **KubeVirt-native CBT**, not CSI Snapshot Metadata Service CBT. KubeVirt uses QEMU/libvirt dirty bitmaps and checkpoints; the storage provider supplies persistent volumes but does not calculate the changed-block map.

The backup API is alpha/technology-preview and is release-dependent. OpenShift Virtualization releases have used different terminal condition names and status shapes. The cluster tested with this repository reports `Done=True`; current upstream API definitions document `Complete=True`. Some releases report only a backup-level `type`, while newer APIs can report per-volume `includedVolumes[].type`. Always inspect the complete condition and included-volume lists instead of assuming one condition name or shape:

```bash
oc get virtualmachinebackup "$BACKUP_NAME" -n "$NAMESPACE" -o json \
  | jq '.status | {type, checkpointName, includedVolumes, conditions}'
```
## Cloud29 validation snapshot

The documentation was checked against the configured `cloud29` cluster. The observed environment had OpenShift `4.22.13`, OpenShift Virtualization/KubeVirt operator `4.22.9`, and ODF `4.21.12`. The HCO feature gate and CBT selector were present, the ODF `StorageCluster` and CephCluster were `Ready`, the RBD StorageClass was default, and the CBT CRDs were installed.

The cluster had ready `virt-controller` replicas, a `virt-handler` DaemonSet covering the worker nodes, ready `virt-api`/`virt-operator`/`virt-exportproxy` deployments, RBD CSI controller and node pods, and healthy Rook-Ceph monitors, managers, and OSDs. Existing CBT VMIs reported `Enabled`, used one vCPU and 1 GiB memory in the lab workload, and had data and backend-state PVCs bound on the RBD StorageClass.

Prometheus scraped `kubevirt-prometheus-metrics`. The queried catalog contained the CBT controller workqueue labels `virt-controller-vmbackup` and `virt-controller-vmbackup-tracker`, VMI CPU and dirty-rate metrics, pod/container resource metrics, PVC metrics, and CSI operation metrics. It did not contain a dedicated CBT/backup/checkpoint metric family, and Ceph metric names were not present in the queried catalog; Ceph health therefore requires CR status and exporter target checks in addition to Prometheus.


## End-to-end component map

| Layer | Component | Role | Evidence to collect |
| --- | --- | --- | --- |
| API/configuration | `HyperConverged`/KubeVirt configuration | Enables `incrementalBackup` and selects VMs/namespaces with CBT label selectors | Feature gate and selector from the HCO resource |
| Operator | HCO, `virt-operator` | Reconciles the KubeVirt installation and deploys operands | CSV, HCO conditions, operator pod |
| API | `virt-api` and Kubernetes API server | Serves VM, VMI, VMB, VMBT, PVC, and status updates | API pods, CRDs, API events |
| Backup control plane | `virt-controller` | Watches `VirtualMachineBackup` and `VirtualMachineBackupTracker`, drives backup lifecycle, updates checkpoints, and manages backup finalizers | Deployment/pods, logs, backup events, backup workqueues |
| Guest execution | `virt-handler` | Runs on every node, talks to libvirt/QEMU, enables CBT in the VMI, creates/redefines checkpoints, and handles QEMU backup commands | DaemonSet/pods, VMI node, handler logs, handler metrics |
| VM process | `virt-launcher` | Pod containing the VMI's QEMU/libvirt process; owns the actual dirty bitmaps, QCOW2 overlays, checkpoint state, and backup job | Pod, node, mounted PVCs, VMI status, pod events |
| VM source | `VirtualMachine`/`VirtualMachineInstance` | VM selector label, disk-level `changedBlockTracking`, CPU/memory, run state | VM/VMI spec and status |
| CBT state | QEMU/libvirt QCOW2 overlay | Thin overlay references the raw disk as a data store and stores bitmap/checkpoint metadata | CBT status; domain XML/QEMU inspection only when debugging |
| Chain state | `VirtualMachineBackupTracker` | Stores one latest checkpoint per VM and backup consumer; each independent consumer needs its own tracker | Tracker spec/status and checkpoint volumes |
| Backup request | `VirtualMachineBackup` | Starts one push or pull backup and reports per-volume type, checkpoint, conditions, and quiesce result | VMB spec/status/events |
| Backup output | Push PVC or pull export | Push writes backup data to a filesystem PVC; pull exposes data/map endpoints through the export path | PVC attachment, VMB links, export resources/proxy |
| VM storage | Data PVC/DataVolume and StorageClass | Stores the guest disk used as the raw QCOW2 data store | PVC, PV, DataVolume, StorageClass, volume mode |
| CBT state storage | Backend-state PVC | Stores VM state needed for overlays, checkpoints, and related metadata | `persistent-state-for-<vm>-<suffix>` PVC and its PV/StorageClass |
| Backup storage | Backup-output PVC | Holds push-mode backup payload; normally RWO and attached as a utility volume to `virt-launcher` during the backup | PVC phase, events, pod volume attachment |
| CSI control plane | Storage CSI controller/provisioner | Creates and attaches data, state, and backup PVC volumes | CSI controller pods, PVC events, CSI operation metrics |
| CSI node plane | Storage CSI node plugin | Mounts/attaches volumes on the node hosting `virt-launcher` | CSI node pod on the VMI node, pod events, node mount state |
| Storage backend | ODF/Ceph RBD, or another supported provider | Persists raw disk, backend state, and backup output; CBT itself remains storage-agnostic | StorageCluster/CephCluster, pool health, PV/PVC, backend metrics |
| Scheduling | Kubernetes scheduler and node | Places `virt-launcher`, `virt-handler`, and CSI node workloads; supplies KVM and CPU/memory capacity | Node Ready/KVM, VMI node, allocatable/requests, taints and conditions |
| Networking | Kubernetes service network and API | Carries control/API traffic between controllers, handlers, launcher, CSI, and storage services | Services, EndpointSlices, NetworkPolicies, events |
| Pull transport | `VirtualMachineExport`/`virt-exportproxy` and HTTPS route | Exposes pull-mode backup data and bitmap/map endpoints to an external consumer | VMExport/VMB links, proxy pods/service/route, TLS/token state |
| Monitoring | Prometheus, ServiceMonitors, kube-state-metrics, ODF exporters | Scrapes control-plane, VMI, node, pod, PVC, CSI, and storage health signals | Target health, metric queries, alert rules |

### Operators and pods that matter

The backup controller is not a separate `virt-backup` deployment. In upstream KubeVirt it is part of `virt-controller`. `virt-handler` is the node-local component that interacts with the running VMI and libvirt. `virt-launcher` is the workload pod that actually runs QEMU.

CDI is involved only when a DataVolume is used to create/import/clone the VM disk. It is not in the steady-state CBT backup data path. Likewise, `virt-exportproxy` is relevant to pull mode, not ordinary push mode.

Inspect the complete dependency set:

```bash
oc get csv -n openshift-cnv
oc get hco -n openshift-cnv -o yaml
oc get deploy,ds,pods -n openshift-cnv -o wide
oc get pods -A -l kubevirt.io=virt-launcher -o wide
oc get pods -n openshift-storage -o wide
oc get pods -n openshift-storage -l app=csi-rbdplugin -o wide
```

For a particular VMI, identify the launcher and node:

```bash
oc get vmi "$VM_NAME" -n "$NAMESPACE" -o json \
  | jq '{phase:.status.phase,node:.status.nodeName,activePods:.status.activePods,cbt:.status.changedBlockTracking}'
oc get pod -n "$NAMESPACE" -l kubevirt.io=virt-launcher -o wide
oc describe pod -n "$NAMESPACE" -l kubevirt.io=virt-launcher
```

## CBT control flow and state

1. HCO/KubeVirt configuration enables the `incrementalBackup` feature gate.
2. A VM or namespace matches `changedBlockTrackingLabelSelectors`.
3. The VM data disk has `changedBlockTracking: true` and is an eligible PVC/DataVolume/HostDisk volume.
4. If the VMI is already running, the VM enters `PendingRestart`; restart is required.
5. KubeVirt creates or uses the backend-state PVC.
6. `virt-handler` configures a QCOW2 overlay with the raw disk as its data store and a dirty bitmap.
7. VMI and VM status reach `Initializing`, then `Enabled`.
8. A tracker with no checkpoint causes a full backup.
9. A completed backup creates a checkpoint and advances the tracker.
10. The next backup using that same tracker uses its latest checkpoint as the base.
11. Backup type is per volume. A disk with a missing or inconsistent bitmap may be full while another disk is incremental.

Check all relevant status fields:

```bash
oc get vm,vmi "$VM_NAME" -n "$NAMESPACE" -o json \
  | jq '.items[] | {kind, name, phase:.status.phase, cbt:.status.changedBlockTracking, conditions:.status.conditions}'
oc get pvc -n "$NAMESPACE" -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,SC:.spec.storageClassName,PV:.spec.volumeName,CAPACITY:.status.capacity.storage
oc get virtualmachinebackuptracker "$TRACKER_NAME" -n "$NAMESPACE" -o yaml
```

## Backup modes and data paths

### Push mode

Push mode is the repository's tested mode. The backup controller causes the backup PVC to be attached to the `virt-launcher` pod as a utility volume. QEMU/libvirt writes backup data to that mounted filesystem, and the controller detaches it after completion.

There is no backup-payload HTTP service in this path. The data plane is the mounted PVC and the storage backend's node-to-storage traffic. Control-plane traffic still uses the Kubernetes API between `virt-controller`, `virt-handler`, and the VMI.

Verify attachment and lifecycle:

```bash
oc get pvc "$BACKUP_PVC" -n "$NAMESPACE" -o yaml
oc get pod -n "$NAMESPACE" -l kubevirt.io=virt-launcher -o yaml \
  | jq '.items[] | {name:.metadata.name,node:.spec.nodeName,volumes:.spec.volumes}'
oc get events -n "$NAMESPACE" --sort-by=.lastTimestamp \
  | grep -Ei 'attach|mount|backup|volume|unmount|detach'
```

The backup PVC is commonly RWO. Do not start a second backup while the previous backup still owns the PVC.

### Pull mode

Pull mode uses a PVC for scratch space and exposes per-volume data and map endpoints to an external backup consumer. The consumer must authenticate with the configured token and validate the endpoint certificate. `ttlDuration` bounds an unfinished pull backup; deleting the VMB requests cleanup.

Inspect pull-mode resources and links:

```bash
oc get virtualmachinebackup "$BACKUP_NAME" -n "$NAMESPACE" -o json \
  | jq '{spec:.spec,status:.status,links:.status.links}'
oc get virtualmachineexport -n "$NAMESPACE" -o wide
oc get svc,route,pods -n openshift-cnv | grep -E 'virt-exportproxy|export'
```

## Filesystem consistency and migration interactions

`skipQuiesce: true` skips the filesystem freeze. The result is crash-consistent, not application-consistent. With quiescing enabled, inspect the `Quiesced` condition and reason. A failed freeze can complete with a warning rather than aborting the backup.

Only one backup per VM is supported at a time. Backup and migration are coordinated:

- A backup requested during migration waits for migration completion.
- A migration started during backup is blocked by the backup and utility-volume attachment.
- A system-critical migration can cancel the backup.
- A canceled backup may temporarily retain the utility volume and block migration until cleanup or timeout.
- Live migration transfers bitmap state and requires checkpoint redefinition on the destination.
- Non-shared storage, disk unplug/replug, crashes, bitmap inconsistency, and online snapshot restore can cause a per-volume full fallback.

Inspect these conditions before interpreting a full fallback:

```bash
oc get vmi "$VM_NAME" -n "$NAMESPACE" -o json \
  | jq '{phase:.status.phase,node:.status.nodeName,migration:.status.migrationState,conditions:.status.conditions}'
oc get vmrestore,vmsnapshot,virtualmachineinstance.migration.kubevirt.io -n "$NAMESPACE" 2>/dev/null || true
oc get virtualmachinebackup "$BACKUP_NAME" -n "$NAMESPACE" -o json \
  | jq '.metadata.finalizers, .status.conditions, .status.includedVolumes'
```

## CPU, memory, and node capacity

The VM's requested CPU and memory are part of the backup execution envelope. The backup itself also consumes CPU, memory, and I/O in `virt-launcher`, `virt-handler`, `virt-controller`, CSI pods, and the storage backend.

CBT adds memory overhead for QEMU dirty bitmaps. Upstream KubeVirt currently documents a 64 KiB bitmap granularity and a conservative buffer overhead; the backend-state PVC has a separate implementation-sized capacity overhead. These values are implementation and release dependent. Do not treat the exact number as a cluster-independent contract.

Collect capacity and actual usage:

```bash
oc get nodes -o custom-columns=NAME:.metadata.name,READY:.status.conditions[-1].status,CPU:.status.capacity.cpu,MEMORY:.status.capacity.memory,ALLOC_CPU:.status.allocatable.cpu,ALLOC_MEMORY:.status.allocatable.memory
oc describe node "$NODE_NAME" | sed -n '/Allocated resources:/,/Events:/p'
oc get vmi "$VM_NAME" -n "$NAMESPACE" -o json \
  | jq '{node:.status.nodeName,cpu:.spec.domain.cpu,memory:.spec.domain.resources,cbt:.status.changedBlockTracking}'
oc get pod -n "$NAMESPACE" -l kubevirt.io=virt-launcher \
  -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName,CPU_REQ:.spec.containers[0].resources.requests.cpu,MEM_REQ:.spec.containers[0].resources.requests.memory
oc adm top node
oc adm top pod -A | grep -E 'virt-(launcher|handler|controller)|csi|rook-ceph'
```

Watch for CPU throttling, memory pressure, OOM kills, node pressure, and insufficient KVM capability:

```bash
oc get nodes -o json | jq '.items[] | {name:.metadata.name,conditions:.status.conditions,allocatable:.status.allocatable,capacity:.status.capacity}'
oc get events -A --field-selector=reason=OOMKilling --sort-by=.lastTimestamp
oc get pods -A | grep -E 'virt-launcher|virt-handler|virt-controller|csi|rook-ceph' | grep -v Running
```

## Storage checks

The data PVC, backend-state PVC, and backup-output PVC can use different StorageClasses. Verify all three independently:

```bash
oc get pvc -n "$NAMESPACE" -o custom-columns=NAME:.metadata.name,SC:.spec.storageClassName,STATUS:.status.phase,PV:.spec.volumeName,MODE:.spec.volumeMode,ACCESS:.spec.accessModes[*]
oc get pv -o custom-columns=NAME:.metadata.name,SC:.spec.storageClassName,STATUS:.status.phase,CAPACITY:.spec.capacity.storage,CLAIM:.spec.claimRef.namespace/.spec.claimRef.name
oc get sc -o custom-columns=NAME:.metadata.name,PROVISIONER:.provisioner,DEFAULT:.metadata.annotations.storageclass\.kubernetes\.io/is-default-class,VOLUME_BINDING:.volumeBindingMode
```

For ODF/Ceph RBD:

```bash
oc get storagecluster,cephcluster,cephblockpool -n openshift-storage -o wide
oc get pods -n openshift-storage -o wide
oc get volumesnapshotclass -o wide
```

Required storage evidence is: healthy provider, provisioner exists, PVCs are `Bound`, the backend-state PVC uses an available default StorageClass, and the backup PVC can attach and detach. A VolumeSnapshotClass may be required by a release's capability checks, but CSI snapshots are not the CBT bitmap mechanism.

## Network and security checks

Push mode does not require an external backup route. It requires:

- Kubernetes API connectivity for controllers and status updates.
- Pod-to-node/libvirt control paths used by KubeVirt.
- CSI controller-to-API and CSI node-to-storage connectivity.
- `virt-launcher` node-to-Ceph/RBD connectivity through the storage network.
- NetworkPolicy rules allowing the required control and metrics traffic.

Pull mode additionally requires `virt-exportproxy`, its Service/Route or equivalent endpoint, TLS certificate validation, and the consumer token.

Inspect the actual cluster rather than assuming names:

```bash
oc get svc,endpointslice,route -A -o wide | grep -E 'kubevirt|export|csi|prometheus|ceph'
oc get networkpolicy -A
oc get servicemonitor,podmonitor -A | grep -E 'kubevirt|csi|ceph|rook|prometheus'
oc get events -A --sort-by=.lastTimestamp | grep -Ei 'network|dns|timeout|tls|forbidden|denied|attach|mount'
```

### API, RBAC, and TLS

The backup controller uses Kubernetes API permissions to watch and update VMs, VMIs, VMBs, VMBTs, PVCs, VMExports, and related status/events. Pull-mode export uses a token and TLS material; the controller maintains backup/export certificate material and the export proxy serves the external endpoint. A successful push backup does not validate pull-mode authentication or transport.

For diagnostics, verify authorization and certificate-related failures without exposing secret contents:

```bash
oc auth can-i get virtualmachinebackups.backup.kubevirt.io -n "$NAMESPACE"
oc auth can-i patch virtualmachinebackups.backup.kubevirt.io -n "$NAMESPACE"
oc auth can-i update virtualmachinebackuptrackers.backup.kubevirt.io/status -n "$NAMESPACE"
oc get events -A --sort-by=.lastTimestamp | grep -Ei 'forbidden|unauthorized|certificate|tls|token'
```

Do not print backup tokens, private keys, or raw certificate Secrets into diagnostic artifacts.

## Prometheus monitoring

On the tested OpenShift cluster, KubeVirt metrics are scraped by the `kubevirt-prometheus-metrics` headless Service and its ServiceMonitor:

```bash
oc get svc kubevirt-prometheus-metrics -n openshift-cnv -o yaml
oc get servicemonitor prometheus-kubevirt-rules -n openshift-cnv -o yaml
oc get pods -n openshift-monitoring -l prometheus=k8s
```

The exact metric set is release-dependent. The following families are useful for CBT backup operations.

### Direct CBT/backup control metrics

KubeVirt does not currently expose a dedicated `kubevirt_cbt_*` or `kubevirt_backup_*` Prometheus metric family in the tested cluster. Backup state is primarily in the VMB/VMBT CR status, conditions, events, and logs.

The generic KubeVirt workqueue metrics do expose the CBT controller queues:

- `kubevirt_workqueue_depth{name="virt-controller-vmbackup"}`
- `kubevirt_workqueue_depth{name="virt-controller-vmbackup-tracker"}`
- `kubevirt_workqueue_retries_total{...}`
- `kubevirt_workqueue_queue_duration_seconds_*`
- `kubevirt_workqueue_work_duration_seconds_*`
- `kubevirt_workqueue_unfinished_work_seconds{...}`
- `kubevirt_workqueue_longest_running_processor_seconds{...}`
- `kubevirt_workqueue_adds_total{...}`

Example queries:

```promql
kubevirt_workqueue_depth{name=~"virt-controller-vmbackup(-tracker)?"}
sum by (name) (rate(kubevirt_workqueue_retries_total{name=~"virt-controller-vmbackup(-tracker)?"}[10m]))
kubevirt_workqueue_unfinished_work_seconds{name=~"virt-controller-vmbackup(-tracker)?"}
```

### KubeVirt control-plane and VMI metrics

Useful families include:

- `kubevirt_virt_controller_ready_status`, `kubevirt_virt_controller_up`, and `cluster:kubevirt_virt_controller_*`
- `kubevirt_virt_handler_ready_status`, `kubevirt_virt_handler_up`, and `cluster:kubevirt_virt_handler_*`
- `kubevirt_vmi_cpu_usage_seconds_total`
- `kubevirt_vmi_dirty_rate_bytes_per_second`
- `kubevirt_vm_disk_allocated_size_bytes`
- `kubevirt_memory_delta_from_requested_bytes`
- `container_cpu_*`, `container_memory_*`, and Kubernetes pod restart metrics

The dirty-rate metric is workload/VMI telemetry, not a backup byte counter. It is useful for predicting backup pressure and correlating guest write activity with incremental runs.

### Kubernetes, CSI, and storage metrics

Use kube-state-metrics and CSI metrics to correlate backup failures with resources:

- `kube_persistentvolumeclaim_status_phase`
- `kube_persistentvolumeclaim_info`
- `kube_persistentvolume_capacity_bytes`
- `kube_pod_container_status_restarts_total`
- `kube_pod_status_ready`
- `csi_operations_seconds_bucket`, `_count`, and `_sum`
- ODF/Ceph metric families when the ODF ServiceMonitors and exporters are successfully scraped

The tested Prometheus instance exposed CSI operation metrics and Kubernetes PVC/pod metrics. It did not expose Ceph metric names in the queried metric catalog, so Ceph health must also be checked from `StorageCluster`, `CephCluster`, and Ceph tooling/exporter target health.

### Querying a cluster-local Prometheus

The following is convenient for an authorized diagnostic shell in OpenShift monitoring. Prometheus pod names and container tooling can vary:

```bash
PROM_POD=$(oc get pod -n openshift-monitoring -l prometheus=k8s -o jsonpath='{.items[0].metadata.name}')
oc exec -n openshift-monitoring "$PROM_POD" -c prometheus -- \
  sh -c 'wget -qO- http://127.0.0.1:9090/api/v1/label/__name__/values' \
  | jq -r '.data[]' | grep -Ei 'backup|checkpoint|bitmap|cbt|workqueue|csi|ceph|kubevirt'
```

Check scrape health for KubeVirt and storage jobs through the Prometheus UI/API, or use the Prometheus `up` metric filtered by the discovered job labels. A metric name existing in the catalog is not proof that its target is healthy.

## Events and logs

Use Kubernetes events first because backup controller events expose lifecycle and quiesce failures:

```bash
oc get events -n "$NAMESPACE" --sort-by=.lastTimestamp \
  | grep -Ei 'backup|checkpoint|quiesc|freeze|attach|mount|detach|migration|volume'
oc logs -n openshift-cnv deploy/virt-controller --since=1h \
  | grep -Ei 'backup|checkpoint|changed.block|cbt|quiesc|export'
oc logs -n openshift-cnv daemonset/virt-handler --since=1h \
  | grep -Ei 'backup|checkpoint|changed.block|cbt|bitmap|libvirt'
oc describe pod -n "$NAMESPACE" -l kubevirt.io=virt-launcher
```

For a failed backup, preserve before cleanup. Prefer the automated bundle
written by `make backup` / `make cbt-backup` (or ad-hoc
`make cbt-diagnostics`) under
`reports/run-*/diagnostics/<vm>/<backup-name>/` — it already includes the CR
YAML dump below plus filtered virt-controller / virt-handler / virt-launcher
logs for the backup window (Secret values redacted). Manual equivalent:

```bash
oc get vm,vmi,pvc,virtualmachinebackup,virtualmachinebackuptracker,events -n "$NAMESPACE" -o yaml > cbt-diagnostics.yaml
oc get pods -n "$NAMESPACE" -o yaml >> cbt-diagnostics.yaml
```

Do not decide Full-vs-Incremental correctness from these logs or from
`VirtualMachineBackup.status` — use `make cbt-evidence` (qcow2
`backing-filename`) instead.

## Minimum acceptance evidence

A successful API-level CBT test must show all of the following:

- Feature gate enabled and selector matches the VM or namespace.
- Data disk explicitly opts into CBT.
- VM and VMI report `changedBlockTracking.state: Enabled`.
- Data PVC, backend-state PVC, and backup PVC are `Bound`.
- VM/VMI/launcher node is `Ready`, has KVM, and has adequate CPU/memory.
- Full VMB reaches its release-appropriate terminal success condition and reports a checkpoint.
- Tracker records that checkpoint.
- A later VMB using the same tracker reaches terminal success and reports incremental type for the expected volume.
- Tracker advances to the later checkpoint.
- Controller/handler pods are ready and backup workqueues are not stuck or continuously retrying.
- Storage provider and CSI controller/node paths are healthy.
- For pull mode, export endpoint, TLS, token, and consumer read/map operations are separately verified.

`Incremental` proves checkpoint-based mode selection. It does not prove the exact number of bytes transferred, payload integrity, restore correctness, or application consistency.

## Known gaps and recommended future improvements

1. Add a dedicated CBT/backup exporter or recording rules for VMB/VMBT status, backup duration, per-volume type, checkpoint age, and failure reason.
2. Add alerts for a backup stuck in `Progressing`, repeated `virt-controller-vmbackup` retries, stale tracker checkpoints, unexpected full fallback, missing CBT `Enabled` state, and backup PVC attachment timeouts.
3. Add a repeatable guest write workload and verify that the second backup contains the expected changed ranges, not only `Incremental` status.
4. Add push-payload integrity checks and a restore test; CBT's low-level API does not provide restore or retention semantics.
5. Test crash, VM restart, live migration, disk hotplug, disk detach/reattach, online snapshot restore, and interrupted backup behavior.
6. Add per-volume assertions because one disk may fall back to full while another remains incremental.
7. Monitor memory overhead as disk size and tracker count grow; bitmap memory is proportional to eligible disk capacity and the number of trackers.
8. Record the exact OpenShift Virtualization/KubeVirt and ODF versions with every test result because API condition names, metrics, and CBT behavior are release-dependent.
9. Add a cleanup test that verifies backup finalizers and namespace deletion for interrupted backups; upstream has documented a failure mode where a VMB referencing a deleted tracker can hold a namespace in `Terminating`.

## Upstream references

- [KubeVirt VEP 25: Storage-agnostic incremental backup using QEMU](https://github.com/kubevirt/enhancements/blob/main/veps/sig-storage/25-incremental-backup/vep.md)
- [KubeVirt CBT implementation](https://github.com/kubevirt/kubevirt/tree/main/pkg/storage/cbt)
- [KubeVirt backup controller](https://github.com/kubevirt/kubevirt/blob/main/pkg/storage/cbt/backup.go)
- [KubeVirt CBT memory calculator](https://github.com/kubevirt/kubevirt/blob/main/pkg/storage/cbt/memory.go)
- [KubeVirt backup API types](https://github.com/kubevirt/api/blob/main/backup/v1alpha1/types.go)
- [KubeVirt workqueue metrics](https://github.com/kubevirt/kubevirt/blob/main/pkg/monitoring/metrics/common/workqueue/metrics.go)
- [Upstream tracker/finalizer issue](https://github.com/kubevirt/kubevirt/issues/18724)
- [Upstream latest-checkpoint limitation](https://github.com/kubevirt/kubevirt/issues/17875)
