# CBT Resilience Chaos Test Plan (Scenario V2)

## 1. Purpose and scope

This plan exercises the KubeVirt-native Changed Block Tracking (CBT) path used by this repository:

`guest writes -> QEMU/libvirt dirty bitmap and QCOW2 overlay -> virt-handler -> virt-controller -> VirtualMachineBackupTracker -> VirtualMachineBackup -> backup PVC -> ODF/Ceph-RBD CSI`.

The objective is resilience improvement, not merely pod recovery. Every experiment must establish a successful full backup and a successful incremental backup first, inject one controlled fault at a defined backup lifecycle point, then prove recovery with API state, tracker state, events, logs, storage state, and cluster health. `Incremental` proves checkpoint-based mode selection; it does not prove payload byte correctness or restore correctness. Payload integrity and restore are separate acceptance activities.

This document intentionally defines a new scenario catalog. It does not depend on any previous scenario catalog.

## 2. Test environment and safety gates

### 2.1 Required environment

- A disposable OpenShift cluster with OpenShift Virtualization and ODF/Ceph-RBD.
- The repository manifests applied in `cbt-demo`, or equivalent resources:
  - VM `fedora-cbt-vm`, with `runStrategy: Always` and `changedBlockTracking: true` on `datadisk`.
  - Data PVC/DataVolume, CBT backend-state PVC, and filesystem backup PVC `cbt-backup-output`.
  - Tracker `fedora-cbt-tracker`.
- `incrementalBackup` enabled and the cluster selector matching label `changedBlockTracking: "true"`.
- A default StorageClass for the CBT backend-state PVC.
- Krkn/Krknctl version recorded with each run. Use `krknctl run <scenario> --help` before execution because scenario parameter tables and defaults are release-dependent.
- A workload that writes repeatedly to `/data` during tests. The stock manifest creates and mounts `/data`, but does not itself guarantee a repeatable write workload; install one before the campaign.

### 2.2 Baseline commands

```bash
export NAMESPACE=cbt-demo
export VM_NAME=fedora-cbt-vm
export TRACKER_NAME=fedora-cbt-tracker
export BACKUP_PVC=cbt-backup-output
export KUBECONFIG=/root/blue/kubeconfig

oc get hco -A -o json | jq '.items[] | {name:.metadata.name,featureGates:.spec.featureGates,cbt:.spec.virtualization.changedBlockTrackingLabelSelectors}'
oc get vm,vmi,pvc -n "$NAMESPACE" -o wide
oc get vm "$VM_NAME" -n "$NAMESPACE" -o json | jq '.status.changedBlockTracking'
oc get virtualmachinebackup,virtualmachinebackuptracker -n "$NAMESPACE" -o wide
oc get storagecluster,cephcluster -n openshift-storage -o wide
oc get nodes
```

Before every experiment, require: CBT `Enabled`; VM/VMI Running; data, backend-state, and backup PVCs `Bound`; all relevant nodes Ready; ODF `Ready`; `virt-controller`, `virt-handler`, CSI, and Ceph pods healthy; no existing backup in progress; and the backup PVC not mounted by another workload.

### 2.3 Baseline backup and evidence

Use the repository manifests and wait for the release-appropriate terminal condition (`Done=True` on the documented cloud29 release; some releases use `Complete=True`). Capture the entire status rather than assuming a field shape.

```bash
oc apply -f manifests/backup-tracker.yaml
oc apply -f manifests/full-backup.yaml
oc wait --for=jsonpath='{.status.type}'=Full \
  virtualmachinebackup/fedora-cbt-vm-full -n "$NAMESPACE" --timeout=600s
oc wait --for=jsonpath='{.status.conditions[?(@.type=="Done")].status}'=True \
  virtualmachinebackup/fedora-cbt-vm-full -n "$NAMESPACE" --timeout=600s
oc get virtualmachinebackup "$VM_NAME-full" -n "$NAMESPACE" -o json \
  | jq '{type:.status.type,checkpoint:.status.checkpointName,conditions:.status.conditions,volumes:.status.includedVolumes}'

oc apply -f manifests/incremental-backup.yaml
oc wait --for=jsonpath='{.status.type}'=Incremental \
  virtualmachinebackup/fedora-cbt-vm-incremental -n "$NAMESPACE" --timeout=600s
oc wait --for=jsonpath='{.status.conditions[?(@.type=="Done")].status}'=True \
  virtualmachinebackup/fedora-cbt-vm-incremental -n "$NAMESPACE" --timeout=600s
oc get virtualmachinebackup "$VM_NAME-incremental" -n "$NAMESPACE" -o json \
  | jq '{type:.status.type,checkpoint:.status.checkpointName,conditions:.status.conditions,volumes:.status.includedVolumes}'
oc get virtualmachinebackuptracker "$TRACKER_NAME" -n "$NAMESPACE" -o json \
  | jq '.status.latestCheckpoint'
```

Save before/after evidence for every run:

```bash
oc get vm,vmi,pvc,virtualmachinebackup,virtualmachinebackuptracker,events -n "$NAMESPACE" -o yaml > cbt-diagnostics.yaml
oc get pods -n "$NAMESPACE" -o yaml >> cbt-diagnostics.yaml
oc get events -n "$NAMESPACE" --sort-by=.lastTimestamp
oc logs -n openshift-cnv deploy/virt-controller --since=1h | grep -Ei 'backup|checkpoint|changed.block|cbt|quiesc|export'
oc logs -n openshift-cnv daemonset/virt-handler --since=1h | grep -Ei 'backup|checkpoint|changed.block|cbt|bitmap|libvirt'
```

## 3. Krkn execution model and event timing

Krknctl command forms below are the documented entry points. Scenario-specific flags must be confirmed with the matching `--help`; the website publishes the scenario command and parameter dependencies, while generated parameter tables vary by Krkn release. Add common Krkn settings for telemetry, Cerberus, Prometheus metrics/alerts, `--iterations 1`, and a bounded recovery timeout according to the installed Krknctl version.

For precise backup-phase injection, use Krkn's event-driven trigger block in the scenario configuration rather than a guessed sleep. The trigger must observe the target VMB status and use `on_timeout: fail`, so a test cannot silently run outside its intended window:

```yaml
triggers:
  mode: all_of
  timeout: 600
  interval: 5
  on_timeout: fail
  conditions:
    - type: k8s
      apiVersion: backup.kubevirt.io/v1alpha1
      kind: VirtualMachineBackup
      name: fedora-cbt-vm-chaos
      namespace: cbt-demo
      condition: "status.conditions[0].type == Progressing"
```

If the installed Krkn condition evaluator cannot address the release's condition array, use a command trigger that exits zero only while the backup is progressing, for example:

```yaml
- type: command
  cmd: "oc get virtualmachinebackup fedora-cbt-vm-chaos -n cbt-demo -o json | jq -e '.status.conditions | any(.[]; .type == \"Progressing\" and .status == \"True\")'"
```

The test operator creates a uniquely named VMB immediately before the run, or runs a wrapper that applies it and starts Krkn. Do not use a fixed `wait_duration` as the only synchronization mechanism.

## 4. Scenarios

### CBT-CH-01 — virt-controller restart during backup orchestration

**Description:** Validate that loss of the backup control-plane pod does not corrupt the VMB/VMBT chain or strand finalizers.

**How to test:** Run the pod scenario against the `virt-controller` pod selected by its actual labels. Use the Krknctl entry point:

```bash
krknctl run pod-scenarios --help
krknctl run pod-scenarios <global-and-scenario-flags>
```

Resolve the exact selector and recovery flags from `--help`; do not target every control-plane pod. Start the VMB, use the Progressing trigger above, kill one controller pod, and let the Deployment recreate it. Collect controller restart count, VMB events/status, tracker status, and workqueue metrics.

**When:** After the backup has created/entered its running phase but before completion, while the tracker is being updated. Repeat once during the full backup and once during the incremental backup.

**Expected result:** The controller replacement becomes Ready; the active VMB either completes or fails with a recoverable, explicit condition; no stale finalizer or permanently stuck `Progressing` object remains. A retry after controller recovery completes with the expected chain semantics: full after an uncommitted full, or incremental when the prior checkpoint was committed. No unrelated CBT VM or cluster health regression.

**Additional notes:** Do not delete all controller replicas. A failure is a stuck backup, silent success with no checkpoint, stale tracker, or namespace deletion blockage.

### CBT-CH-02 — virt-handler restart on the VMI node

**Description:** Exercise the node-local libvirt/QEMU control path that owns dirty bitmaps, overlays, checkpoints, and backup commands.

**How to test:** Run the pod scenario against one `virt-handler` pod on the node hosting `virt-launcher`:

```bash
oc get vmi "$VM_NAME" -n "$NAMESPACE" -o json | jq -r '.status.nodeName'
krknctl run pod-scenarios --help
krknctl run pod-scenarios <global-and-scenario-flags-for-that-handler-pod>
```

Use a VMB Progressing trigger. Confirm the handler DaemonSet recreates the pod and inspect libvirt/bitmap and VMI events after recovery.

**When:** During the active QEMU backup job, after checkpoint creation has started but before VMB completion. Run separately for full and incremental backups.

**Expected result:** The VMI returns to Running/CBT Enabled; the backup terminates deterministically (complete or explicit failure, never indefinite progress); the next backup using the tracker has a correct, explainable type. If bitmap continuity cannot be guaranteed, a safe full fallback is acceptable and must be reported per volume. Tracker state must not advance to an unverified checkpoint.

**Additional notes:** A full fallback is not automatically a failure after handler/QEMU state loss. Silent incremental classification with corrupted or missing checkpoint evidence is a failure.

### CBT-CH-03 — VMI/virt-launcher outage during backup

**Description:** Validate crash recovery when the QEMU process and launcher pod disappear while CBT state is active.

**How to test:** Use the current Krkn VMI outage scenario, which deletes a VMI and relies on `runStrategy: Always` recovery:

```bash
krknctl run vmi-outage --help
krknctl run vmi-outage <flags-selecting-the-cbt-vmi-and-timeout>
```

Enable the Krkn virt checks for the target VMI where supported. Start the VMB, wait for Progressing, inject the VMI deletion, and record `vmi_rescheduling_time`, `vmi_readiness_time`, and `total_recovery_time` from Krkn telemetry.

**When:** During an active backup, and in a separate run immediately after the full backup has completed but before the incremental backup.

**Expected result:** The VM controller recreates the VMI because `runStrategy: Always`; the VMI becomes Running and CBT returns to Enabled after the required initialization/restart behavior. The interrupted VMB is not reported successful without a valid checkpoint. A follow-up backup completes with either Incremental from a valid preserved chain or an explicit safe Full fallback. No permanent backup PVC attachment or finalizer remains.

**Additional notes:** This scenario supports one VMI at a time. Do not interpret a recovered VMI alone as backup success; verify VMB and tracker state.

### CBT-CH-04 — node failure on the VMI host

**Description:** Test scheduler, virt-handler, CSI, and RBD recovery when the worker hosting `virt-launcher` is disrupted.

**How to test:** First identify the VMI node and confirm the cloud/provider supports a reversible node scenario. Use:

```bash
krknctl run node-scenarios --help
krknctl run node-scenarios <cloud-type-and-node-name-or-selector-flags>
```

Use only one worker, preserve control-plane quorum, and configure the scenario's recovery timeout. Start a VMB and inject after Progressing is observed. On bare metal or an unsupported provider, do not improvise cloud credentials; use CBT-CH-03 and a controlled node drain as a separately approved substitute.

**When:** During a backup with the backup PVC attached, then in a second run between full and incremental backups.

**Expected result:** The node recovers or the VMI is rescheduled within the defined SLO; RBD volumes reattach cleanly; backup PVC is not left exclusively attached to the failed node. VMB reaches a terminal state, tracker advances only on valid completion, and a subsequent backup succeeds. A full fallback is acceptable when bitmap continuity was lost; data-plane corruption, orphaned attachments, or an unrecoverable tracker is not.

**Additional notes:** This is a high-blast-radius test. Run only on an isolated cluster with out-of-band node recovery and preapproved cloud credentials.

### CBT-CH-05 — backup PVC storage throttling

**Description:** Determine whether slow backup-output I/O causes bounded backpressure, retries, or timeouts without corrupting checkpoint state.

**How to test:** Use the Krkn storage-throttle scenario against the backup PVC or its mounted launcher pod:

```bash
krknctl run storage-throttle --help
krknctl run storage-throttle <flags-for-pvc-name=cbt-backup-output-or-pod-name=virt-launcher>
```

The website documents that at least one of `--pvc-name` or `--pod-name` is required and that the PVC takes precedence. Capture VMB duration, CSI operation latency, PVC events, launcher resources, and workqueue retries.

**When:** During the data-copy portion of full backup, then during incremental backup with a deliberately smaller changed workload.

**Expected result:** Backup either completes within the agreed timeout or fails explicitly and cleans up the attachment. Controller retries remain bounded; no false successful checkpoint is recorded. After throttle removal, a new full/incremental backup succeeds and the backup PVC is reusable.

**Additional notes:** Keep throttling below a level that causes cluster-wide storage outage. Compare duration and bytes/throughput with an unthrottled baseline.

### CBT-CH-06 — backup PVC near-full condition

**Description:** Verify behavior when the push destination cannot accept the complete backup payload.

**How to test:** Use the Krkn PVC scenario, targeting the backup PVC mounted by the launcher:

```bash
krknctl run pvc-scenarios --help
krknctl run pvc-scenarios <flags-for-pvc-name=cbt-backup-output-and-fill-percentage>
```

The target PVC must be Bound and mounted. Inject fill before starting the VMB, or use a trigger/wrapper to begin fill immediately after VMB Progressing. Do not fill the data PVC in the same run; that is a separate experiment.

**When:** Before or during the backup output write phase; run once before full and once before incremental.

**Expected result:** The backup fails with a clear capacity/write error, does not advance the tracker as successful, releases the RWO PVC, and leaves the VM/VMI healthy. After Krkn cleanup removes the temporary fill file and capacity is restored, a fresh backup succeeds. No silent truncation or falsely successful checkpoint is accepted.

**Additional notes:** Verify the fill file cleanup described by the scenario documentation and check actual filesystem free space, not just PVC phase.

### CBT-CH-07 — network latency or packet loss on the VMI/CSI path

**Description:** Test control and storage-network tolerance while backup API calls, CSI operations, and launcher-to-Ceph traffic are delayed or degraded.

**How to test:** Use the network chaos scenario:

```bash
krknctl run network-chaos --help
krknctl run network-chaos <flags-for-traffic-type-duration-wait-duration-and-interface>
```

For node ingress, provide the documented network parameters and target interface; for egress, target the VMI node. The website requires `--wait-duration` to be at least twice `--duration` and documents that empty interfaces can be auto-detected. Prefer latency first, then packet loss; do not combine faults on the first run.

**When:** Inject after VMB Progressing and before completion. Repeat once with a short fault and once with a longer fault near the backup timeout.

**Expected result:** Temporary degradation produces bounded retries and recovery, or a deterministic failure with cleanup. Once the network is restored, controller/handler/CSI pods become Ready, the VMI stays healthy, and a follow-up backup succeeds. No stale attachment, checkpoint advancement without payload completion, or cluster-wide API outage.

**Additional notes:** Keep the Kubernetes API path available for observation. A test that prevents Krkn from restoring the network is invalid and must be aborted using the out-of-band recovery procedure.

### CBT-CH-08 — container/process disruption of backup control components

**Description:** Compare process-level failure with whole-pod deletion for `virt-controller` or `virt-handler` and validate signal handling.

**How to test:** Use the Krkn container scenario with a target container selected by the installed scenario flags:

```bash
krknctl run container-scenarios --help
krknctl run container-scenarios <flags-selecting-virt-controller-or-virt-handler-container>
```

Run one signal per iteration (prefer `SIGTERM`, then `SIGKILL` only in a disposable environment). Use Krkn's expected recovery setting and capture pod restart, readiness, and backup status.

**When:** During VMB Progressing, with separate runs for controller and handler.

**Expected result:** Graceful termination exits cleanly and the replacement process resumes reconciliation. SIGKILL may cause an explicit backup failure or safe full fallback, but never silent tracker corruption. Recovery time remains below the component SLO and the next backup is successful.

**Additional notes:** Do not target the Ceph monitor, API server, or all replicas in this CBT campaign; those are separate platform-disruption campaigns.

### CBT-CH-09 — CPU, memory, and I/O pressure on the VMI node

**Description:** Establish whether QEMU bitmap memory, backup I/O, and Krkn-induced node pressure cause OOM, throttling, or checkpoint loss.

**How to test:** Use the Krkn hog scenario and select the least destructive single resource first:

```bash
krknctl run hog-scenarios --help
krknctl run hog-scenarios <flags-for-cpu-or-memory-or-io-and-target-node>
```

Target the VMI node only, cap the hog below the node's eviction threshold, and run one of CPU, memory, or I/O per experiment. Record node allocatable/usage, launcher limits, OOM events, dirty-rate metric, backup duration, and workqueue retries.

**When:** During the full backup data-copy phase and during an incremental backup under guest write load.

**Expected result:** The node remains stable; backup completes within the performance SLO or fails cleanly with cleanup. No OOM-killed launcher, lost bitmap, permanent VMI outage, or false checkpoint. After pressure removal, a follow-up backup succeeds and resource usage returns to baseline.

**Additional notes:** CBT bitmap memory is implementation/release dependent and scales with eligible disk capacity. Record versions and disk size with results.

### CBT-CH-10 — interrupted backup cleanup and tracker safety

**Description:** Validate finalizers, utility-volume detachment, tracker consistency, and namespace cleanup after an intentionally interrupted VMB.

**How to test:** Start a VMB and inject one controlled interruption using CBT-CH-01, CBT-CH-03, or CBT-CH-05. After the VMB reaches a terminal or known stuck state, preserve diagnostics, then delete only the test VMB and inspect finalizers. Create a new VMB with the same tracker only after confirming the previous operation is no longer active.

```bash
oc get virtualmachinebackup "$VM_NAME-chaos" -n "$NAMESPACE" -o json \
  | jq '{finalizers:.metadata.finalizers,status:.status,links:.status.links}'
oc get pod -n "$NAMESPACE" -l kubevirt.io=virt-launcher -o yaml \
  | jq '.items[] | {name:.metadata.name,volumes:.spec.volumes}'
oc delete virtualmachinebackup "$VM_NAME-chaos" -n "$NAMESPACE"
oc get pvc "$BACKUP_PVC" -n "$NAMESPACE" -o yaml
```

**When:** Immediately after each interruption scenario, before rerunning the backup chain.

**Expected result:** Finalizers clear, the RWO backup PVC detaches, no VMB remains indefinitely `Progressing`, and namespace deletion is not blocked by a VMB referencing a deleted tracker. A new backup either resumes from a verified checkpoint or safely starts Full; it must not claim Incremental from an invalid base.

**Additional notes:** This is a cleanup gate for the entire campaign, not an optional postscript. Preserve diagnostics before deleting failed objects.

### CBT-CH-11 — live migration during backup

**Description:** Validate checkpoint/bitmap transfer and backup/migration coordination during a node transition.

**How to test:** This is a KubeVirt control experiment because the listed Krkn scenarios do not provide the migration operation itself. Start a VMB, request a live migration using the cluster's approved `VirtualMachineInstanceMigration` method, and observe the documented coordination. Use Krkn VMI/virt checks or pod/node scenarios only as background observation, not as the migration driver.

**When:** Run once with migration requested before backup (backup should wait), once during active backup (migration should wait or be coordinated), and once after backup completion.

**Expected result:** Backup and migration serialize according to the release contract; bitmap state is preserved or the next backup safely falls back to Full. No simultaneous RWO attachment, lost checkpoint, VMI outage beyond the migration SLO, or tracker advancement before backup completion.

**Additional notes:** Record source/destination nodes, migration phase, VMB phase, checkpoint names, and any full fallback reason. Do not use storage migration or disk detach in the same run.

### CBT-CH-12 — time skew and checkpoint timestamp handling

**Description:** Probe timestamp sensitivity without changing the host clock of the whole cluster.

**How to test:** Use Krkn time scenarios only against an isolated, disposable worker or a dedicated test pod if the scenario supports a pod target:

```bash
krknctl run time-scenarios --help
krknctl run time-scenarios <flags-for-isolated-target-and-short-duration>
```

Never skew API-server, etcd, Ceph monitor, or all worker clocks in this CBT campaign. Start the VMB and apply a small forward/backward skew only if the target is isolated and the scenario guarantees restoration.

**When:** Between full and incremental backups, and separately while a backup is Progressing.

**Expected result:** Backup status and tracker remain internally consistent; clock changes do not create a false incremental chain. A safe Full fallback or explicit failure is acceptable if the release detects timestamp/bitmap inconsistency. Clock restoration must be confirmed before cleanup.

**Additional notes:** This is lower priority than controller, handler, VMI, storage, and network tests. Abort if cluster time synchronization or API behavior is affected.

## 5. Campaign order and pass/fail rules

Run in this order: baseline; CBT-CH-01; CBT-CH-02; CBT-CH-03; CBT-CH-05; CBT-CH-06; CBT-CH-07; CBT-CH-08; CBT-CH-09; CBT-CH-04; CBT-CH-10 after every interrupted run; CBT-CH-11; CBT-CH-12. Stop the campaign when a safety gate fails, ODF is unhealthy, API access is lost without out-of-band recovery, or any experiment risks unrelated namespaces.

A scenario passes only when all applicable conditions hold:

1. The injected fault is recorded with start/end time and target identity.
2. Recovery meets the scenario SLO or produces a bounded, documented failure.
3. VMB status, conditions, events, and finalizers are consistent with the observed interruption.
4. Tracker advancement occurs only after a valid completed backup.
5. The next backup has the expected `Incremental` type, or a safe, explained `Full` fallback after state loss.
6. Data, backend-state, and backup PVCs are usable and detached correctly.
7. VM/VMI returns to Running with CBT `Enabled`; controller, handler, CSI, node, and ODF health recover.
8. Krkn/Cerberus reports no unrelated cluster-health failure and Prometheus shows no sustained retry or readiness regression.

A scenario fails for silent data loss, false successful checkpoint, stale finalizer, stuck attachment, unrecovered VMI, unexplained full fallback, permanent workqueue retry, cluster-health regression outside the intended blast radius, or inability to restore the injected fault.

## 6. Evidence and reporting template

For each run record:

- Test ID/title, date, operator, cluster, OpenShift Virtualization/KubeVirt/ODF versions.
- Krkn/Krknctl version, exact command, resolved target labels/names, and trigger configuration.
- Baseline and post-chaos VMB/VMBT JSON, checkpoint names, per-volume types, conditions, finalizers.
- VM/VMI state, CBT state, launcher node, PVC/PV/StorageClass state, and backup PVC attachment events.
- Krkn telemetry recovery timings, Cerberus result, Prometheus queries/results, controller/handler/CSI/Ceph evidence.
- Fault start/end timestamps, recovery timestamp, backup duration, and whether the next run was Incremental or safe Full.
- Failure reason, cleanup actions, residual objects, and resilience improvement recommendation.

## 7. Krkn scenarios deliberately not used as primary CBT injections

The Krkn website also documents zone outages, power outages, namespace/service deletion, service hijacking, SYN flood, and broad control-plane disruptions. They are intentionally excluded from the primary CBT campaign because they have a blast radius larger than one backup chain or do not represent a component in the push-mode CBT data path. They may be separate platform-resilience campaigns after this plan passes, with independent rollback and cluster-quorum approval.

## 8. References

- Repository architecture: `docs/cbt/CBT-ARCHITECTURE.md`
- Repository operations and evidence: `docs/cbt/CBT-OPERATIONS.md`
- Repository baseline procedure: `docs/cbt/CBT-TEST-GUIDE.md`
- Krkn scenario catalog: https://github.com/krkn-chaos/website/tree/main/content/en/docs/scenarios
- Krkn chaos methodology and pass/fail guidance: https://raw.githubusercontent.com/krkn-chaos/website/main/content/en/docs/chaos-testing-guide/_index.md
- Krkn event-driven triggers: https://raw.githubusercontent.com/krkn-chaos/website/main/content/en/docs/krkn/triggers.md
- Krknctl common variables: https://raw.githubusercontent.com/krkn-chaos/website/main/content/en/docs/scenarios/all-scenario-env-krknctl.md
- VMI outage scenario: https://raw.githubusercontent.com/krkn-chaos/website/main/content/en/docs/scenarios/vmi-outage/_index.md
- Network chaos scenario: https://raw.githubusercontent.com/krkn-chaos/website/main/content/en/docs/scenarios/network-chaos/_tab-krknctl.md
- Storage throttle scenario: https://raw.githubusercontent.com/krkn-chaos/website/main/content/en/docs/scenarios/storage-throttle/_tab-krknctl.md
- PVC scenario: https://raw.githubusercontent.com/krkn-chaos/website/main/content/en/docs/scenarios/pvc-scenario/_tab-krknctl.md
