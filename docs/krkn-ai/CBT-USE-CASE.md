# Krkn-AI for KubeVirt CBT Testing

## Purpose

This document records the Krkn-AI work performed for the KubeVirt Changed Block Tracking (CBT) test in this repository. It explains:

- what Krkn-AI contributes to the CBT test;
- where Krkn-AI was installed and executed;
- which CBT resources were used;
- the exact campaign configuration;
- the execution attempts, failures, fixes, and final results;
- the evidence produced outside Krkn-AI to validate CBT behavior;
- the current limitations and the next required improvements.

This is an execution record, not a generic Krkn-AI tutorial. The commands and paths below are specific to the `cloud29` environment and the `cbt-demo` test resources.

## Executive result

The final campaign completed successfully with eight generated scenarios:

| Field | Value |
| --- | --- |
| Krkn-AI run UUID | `905debba-9b29-43d2-a894-d002fec9a98f` |
| Execution host | `cloud29` |
| Krkn-AI version | `0.1.3.dev2+g47dec542d` |
| Krkn scenario runner | `krknctl` |
| Random seed | `42` |
| Algorithm | Genetic |
| Generations | `1` |
| Population size | `8` |
| Runtime | `873.27` seconds (`14.55` minutes) |
| Scenarios executed | `8` |
| Best fitness | `65.7753%` |
| Average fitness | `52.9676%` |
| Result status | `completed` |

Final result directory:

```text
/root/krkn-ai-cbt-results-cbt-aware/905debba-9b29-43d2-a894-d002fec9a98f
```

All eight final Krkn scenarios returned successfully. The campaign exercised VMI, pod, PVC, storage, and node-resource disruption. The network scenario family was enabled in configuration but was not instantiated because Krkn-AI could not find a compatible node interface on the cluster.

The final campaign did not prove restore correctness. The repository CBT documentation states that the low-level push-mode `VirtualMachineBackup` API does not provide restore semantics. The run validated backup status, checkpoint progression, payload creation, VM recovery, and CBT state after chaos.

## What Krkn-AI adds to this CBT use case

CBT itself is controlled by KubeVirt resources and status:

- `VirtualMachine` and `VirtualMachineInstance`;
- `VirtualMachineBackupTracker`;
- `VirtualMachineBackup`;
- the VM data PVC;
- the CBT backend-state PVC;
- the push-mode backup-output PVC;
- KubeVirt controller, handler, launcher, CSI, and storage components.

Krkn-AI does not replace this lifecycle. It adds the chaos and search layer around it.

### Krkn-AI contribution

Krkn-AI provides:

1. **Scenario discovery and candidate generation**
   - It discovers usable cluster resources and scenario parameters.
   - It creates candidate combinations for node, pod, VMI, PVC, storage, and resource disruptions.

2. **Repeatable execution**
   - The campaign uses seed `42`.
   - The generated scenario YAML records the exact parameters selected for each candidate.
   - The same configuration and seed can be rerun for comparison.

3. **Multi-scenario coverage**
   - One run exercised multiple disruption families instead of manually running only one VMI outage.
   - The result included scenario-level return codes, logs, durations, and fitness values.

4. **Fitness and ranking**
   - Krkn-AI combines Krkn execution success with configured Prometheus fitness inputs.
   - It ranks candidates and records the best candidate.
   - The score is a resilience-experiment score, not a CBT backup pass/fail result.

5. **Operational compatibility discovery**
   - The initial runs exposed API DNS problems inside scenario containers.
   - The campaign showed that PVC scenarios require a running pod mounted to the backup PVC.
   - The campaign showed that network scenarios require a discoverable compatible node interface.
   - These are useful environment findings that would be missed by testing only the CBT API.

### What Krkn-AI does not provide by itself

Krkn-AI does not currently:

- create a CBT baseline full backup before each candidate;
- wait for a specific `VirtualMachineBackup` phase before starting chaos;
- inspect the CBT tracker checkpoint as a pass/fail condition;
- verify that a backup payload contains expected guest changes;
- restore a push-mode CBT backup payload;
- classify `Full` versus `Incremental` as a CBT-specific verdict;
- forward arbitrary Krkn trigger flags through the current Krkn-AI scenario command builder;
- provide a dedicated `kubevirt_cbt_*` or `kubevirt_backup_*` Prometheus metric family.

Therefore the correct architecture is:

```text
CBT lifecycle wrapper / evaluator
        |
        +-- create and validate full backup
        +-- prepare guest writes and backup PVC consumer
        +-- invoke Krkn-AI chaos campaign
        +-- create and validate incremental backup
        +-- inspect tracker/checkpoint and VM recovery
        +-- emit CBT-specific pass/fail result
                         |
                         v
                    Krkn-AI
              chaos candidate generation
              scenario execution and ranking
```

## Execution location and environment

### Bastion and cluster access

All cluster operations were executed through the SSH host alias:

```text
cloud29
```

The administrative kubeconfig was:

```text
/root/blue/kubeconfig
```

The kubeconfig used by Krkn scenario containers was:

```text
/root/blue/kubeconfig-krkn
```

`kubeconfig-krkn` was a temporary remote copy. The original `/root/blue/kubeconfig` was used for cluster administration and was not modified.

The reason for the copy was container DNS behavior. The host could resolve:

```text
api.blue.rdu2.scalelab.redhat.com -> 198.18.0.3
```

The Krkn scenario containers could not resolve the API hostname. The temporary Krkn kubeconfig used the reachable IP address and disabled certificate verification for this disposable test environment:

```yaml
server: https://198.18.0.3:6443
insecure-skip-tls-verify: true
```

This workaround is environment-specific and should not be copied into a production test setup.

### Krkn-AI installation

Krkn-AI was installed on `cloud29` in:

```text
/root/krkn-ai
```

The Python virtual environment was:

```text
/root/krkn-ai-venv
```

The executable used was:

```text
/root/krkn-ai-venv/bin/krkn_ai
```

The installed package reported:

```text
Name: krkn_ai
Version: 0.1.3.dev2+g47dec542d
Editable project location: /root/krkn-ai
```

The Krkn runner was:

```text
krknctl
```

The installed `krknctl` displayed the standard Krkn CLI help and reported that version `v0.14.2-beta` was available. The installed binary did not expose a `krknctl version` command.

No Krkn-AI source code was modified for this work. The changes were remote campaign configuration, remote test resources, and this repository documentation.

## CBT resources under test

The final run used namespace:

```text
cbt-demo
```

The VM was:

```text
fedora-cbt-vm
```

The VMI was:

```text
fedora-cbt-vm
```

The CBT tracker was:

```text
fedora-cbt-tracker
```

The backup-output PVC was:

```text
cbt-backup-output
```

The VM data PVC was:

```text
fedora-cbt-vm-data
```

The CBT backend-state PVC was generated by KubeVirt and had the form:

```text
persistent-state-for-fedora-cbt-vm-<suffix>
```

The VM used the CBT-enabled disk configuration:

```yaml
metadata:
  labels:
    changedBlockTracking: "true"

spec:
  template:
    spec:
      domain:
        devices:
          disks:
          - name: datadisk
            changedBlockTracking: true
            disk:
              bus: virtio
```

The final cluster state after the campaign was:

```text
VM: Running, Ready=True
VMI: Running
VM CBT state: Enabled
Backup PVC: Bound
virt-launcher: Running and ready
cbt-backup-writer: Running and ready
```

## Backup-PVC workload added for scenario coverage

The Krkn PVC and storage scenarios require a pod using the target PVC. The push-mode CBT backup normally attaches the PVC temporarily to `virt-launcher` and detaches it after backup completion. Therefore, the PVC did not have a running consumer after the original backup completed.

A disposable writer pod was deployed:

```text
Pod: cbt-backup-writer
Namespace: cbt-demo
PVC: cbt-backup-output
Mount: /backup
Image: registry.access.redhat.com/ubi9/ubi-minimal:latest
```

The writer created:

```text
/backup/payload/cbt-workload-heartbeat.log
/backup/payload/cbt-workload-block
```

It wrote a timestamp every 15 seconds and rewrote a 4 MiB file with `fsync`. This gave Krkn-AI a real mounted workload for:

- `pvc-scenarios`;
- `storage-throttle`;
- backup-output PVC usage discovery;
- guest/backup workload activity correlation.

The backup PVC is `ReadWriteOnce`. The writer must be deleted before starting another push-mode backup and recreated after the backup completes:

```bash
KUBECONFIG=/root/blue/kubeconfig \
  oc delete pod cbt-backup-writer -n cbt-demo --wait=true

# Start the backup and wait for completion.

KUBECONFIG=/root/blue/kubeconfig \
  oc apply -f /tmp/virt-cbt-manifests/incremental-backup-post-chaos.yaml

# Recreate the consumer after backup completion.
KUBECONFIG=/root/blue/kubeconfig \
  oc apply -f /tmp/cbt-backup-writer.yaml
```

The writer manifest was created remotely at:

```text
/tmp/cbt-backup-writer.yaml
```

It included restricted security settings:

```yaml
securityContext:
  runAsNonRoot: true
  seccompProfile:
    type: RuntimeDefault
```

and:

```yaml
securityContext:
  allowPrivilegeEscalation: false
  capabilities:
    drop: [ALL]
```

## Krkn-AI configuration

The final configuration was stored on `cloud29` at:

```text
/root/krkn-ai-cbt-matrix.yaml
```

The final result copied the effective configuration to:

```text
/root/krkn-ai-cbt-results-cbt-aware/905debba-9b29-43d2-a894-d002fec9a98f/krkn-ai.yaml
```

### Execution and algorithm settings

```yaml
kubeconfig_file_path: /root/blue/kubeconfig-krkn
kubeconfig: /root/blue/kubeconfig-krkn
seed: 42
wait_duration: 30

genetic:
  generations: 1
  population_size: 8
  composition_rate: 0
  population_injection_rate: 0

baseline:
  enable: false
  duration: 60
```

The CLI also explicitly supplied the kubeconfig and output path:

```bash
/root/krkn-ai-venv/bin/krkn_ai run \
  -k /root/blue/kubeconfig-krkn \
  -c /root/krkn-ai-cbt-matrix.yaml \
  -o /root/krkn-ai-cbt-results-cbt-aware \
  -r krknctl \
  -s 42 \
  -v
```

The final run used one genetic generation with eight candidates. The algorithm generated duplicate scenario families with different parameters; it did not guarantee one candidate for every enabled scenario family.

The effective genetic configuration recorded in `results.json` was:

```json
{
  "algorithm_type": "genetic",
  "generations": 1,
  "population_size": 8,
  "mutation_rate": 0.7,
  "scenario_mutation_rate": 0.6,
  "crossover_rate": 0.6,
  "composition_rate": 0.0
}
```

### Fitness function

The final campaign used point fitness queries. Each query was configured to return zero instead of no data when the metric was absent, so Krkn-AI pre-flight validation could distinguish a healthy zero from an unavailable metric.

```yaml
fitness_function:
  items:
  - query: sum(increase(kube_pod_container_status_restarts_total{namespace="cbt-demo"}[10m])) or vector(0)
    type: point
    weight: 3

  - query: sum(kube_pod_status_phase{namespace="cbt-demo",phase=~"Pending|Failed|Unknown"}) or vector(0)
    type: point
    weight: 3

  - query: sum(kube_pod_container_status_waiting_reason{namespace="openshift-cnv",reason="CrashLoopBackOff"}) or vector(0)
    type: point
    weight: 2

  - query: sum(rate(kubevirt_workqueue_retries_total{name=~"virt-controller-vmbackup(-tracker)?"}[10m])) or vector(0)
    type: point
    weight: 3

  - query: sum(kubevirt_workqueue_unfinished_work_seconds{name=~"virt-controller-vmbackup(-tracker)?"}) or vector(0)
    type: point
    weight: 2

  - query: clamp_min(1 - sum(kube_persistentvolumeclaim_status_phase{namespace="cbt-demo",persistentvolumeclaim="cbt-backup-output",phase="Bound"}), 0) or vector(0)
    type: point
    weight: 3

  - query: clamp_min(1 - sum(kube_pod_status_ready{namespace="cbt-demo",condition="true",pod=~"virt-launcher-fedora-cbt-vm.*|cbt-backup-writer"}), 0) or vector(0)
    type: point
    weight: 3

  include_krkn_failure: true
  include_health_check_failure: false
  include_health_check_response_time: false
```

These queries represent operational degradation rather than CBT correctness directly. In particular:

- backup CR status is not exposed as a dedicated Prometheus metric in this cluster;
- `kubevirt_vmi_dirty_rate_bytes_per_second` is useful workload telemetry, but a non-zero dirty rate is not a failure;
- VMB type, checkpoint, completion condition, and tracker advancement were validated with the Kubernetes API after the run.

### Enabled scenario families

The effective scenario selection was:

```yaml
scenario:
  pod-scenarios:
    enable: true
  network-scenarios:
    enable: true
  kubevirt-scenarios:
    enable: true
  pvc-scenarios:
    enable: true
  storage-throttle:
    enable: true
  node-cpu-hog:
    enable: true
  node-memory-hog:
    enable: true
  node-io-hog:
    enable: true
  application-outages:
    enable: false
  container-scenarios:
    enable: false
  time-scenarios:
    enable: false
  dns-outage:
    enable: false
  syn-flood:
    enable: false
  service-disruption:
    enable: false
```

The discovered `cluster_components` section was retained in the configuration. It contained the discovered namespaces, pods, PVCs, services, nodes, and resource information used by Krkn-AI scenario factories. It is environment-specific and becomes stale when pod names, labels, node placement, or controller revision hashes change. The file at `/root/krkn-ai-cbt-matrix.yaml` is the authoritative copy for this run.

## Execution history

### Attempt 1: fitness pre-flight failure

The initial configuration used this query:

```promql
sum(kube_pod_container_status_waiting_reason{namespace="openshift-cnv",reason="CrashLoopBackOff"})
```

The cluster had no matching CrashLoopBackOff series. Krkn-AI correctly failed pre-flight validation rather than running with an unavailable fitness metric.

Run UUID:

```text
d47096e4-2ba2-406e-9d4f-885d113122ec
```

Failure:

```text
Pre-flight check failed: query returned no data
```

Fix:

```promql
sum(kube_pod_container_status_waiting_reason{namespace="openshift-cnv",reason="CrashLoopBackOff"}) or vector(0)
```

### Attempt 2: container API DNS failure

After the fitness query fix, pre-flight validation passed. Krkn-AI created eight candidates, but every Krkn scenario returned code `1`.

Run UUID:

```text
52871a52-e584-4871-812d-e7c4c1353a91
```

Representative failure:

```text
socket.gaierror: [Errno -2] Name or service not known
HTTPSConnection(host='api.blue.rdu2.scalelab.redhat.com', port=6443)
```

The host could resolve the API hostname, but the Krkn scenario container could not. This caused all scenarios to be marked as misconfiguration failures with fitness `-1.0`.

Fix:

- Resolve the API address on the host.
- Create `/root/blue/kubeconfig-krkn` with `https://198.18.0.3:6443`.
- Use that kubeconfig for Krkn-AI and the scenario containers.

### Attempt 3: corrected networking, missing PVC consumer

Run UUID:

```text
7d3f2aa0-1b65-4165-8db6-c396be42863f
```

The API connection problem was fixed. Results:

- six scenarios returned code `0`;
- `pvc-scenarios` returned code `1`;
- `storage-throttle` returned code `1`.

The scenario logs reported:

```text
No pod associated with PVC 'cbt-backup-output' in namespace 'cbt-demo'
```

This led to deployment of `cbt-backup-writer` on the backup PVC.

### Attempt 4: final CBT-aware campaign

Run UUID:

```text
905debba-9b29-43d2-a894-d002fec9a98f
```

The final run discovered backup PVC usage:

```text
Found PVC cbt-backup-output usage: 0.10%
```

All eight generated scenarios returned code `0`.

## Final generated candidates

The final `results.json` ranked these candidates:

| Rank | Scenario | Important parameters | Fitness |
| ---: | --- | --- | ---: |
| 1 | `node-memory-hog` | `51%`, `10` workers, node `d39-h04-000-r660`, `60s` | `65.7753%` |
| 2 | `kubevirt-outage` | VM `fedora-cbt-vm`, namespace `cbt-demo`, kill count `1`, timeout `60s` | `57.8947%` |
| 3 | `node-memory-hog` | `52%`, `9` workers, node `d39-h04-000-r660`, `60s` | `50.0142%` |
| 4 | `node-io-hog` | `676k`, `9` workers, `7%`, `/root`, `60s` | `50.0142%` |
| 5 | `pvc-scenarios` | PVC `cbt-backup-output`, fill `36%`, `60s` | `50.0142%` |
| 6 | `pod-scenarios` | CNV controller revision `7bd8c8fdbc`, one pod, recovery `60s` | `50.0142%` |
| 7 | `storage-throttle` | PVC `cbt-backup-output`, both directions, read `392` IOPS, write `383` IOPS, `60s` | `50.0142%` |
| 8 | `node-io-hog` | `3m`, `6` workers, `9%`, `/root`, `60s` | `50.0%` |

The genetic algorithm did not produce a network candidate because the network scenario factory reported that no valid node interfaces were available.

## Final Krkn-AI output artifacts

The final result directory contained:

```text
krkn-ai.yaml
learned_weights.json
results.json
run.log
reports/all.csv
reports/best_scenarios.yaml
reports/health_check_report.csv
logs/scenario_0.log
logs/scenario_1.log
logs/scenario_2.log
logs/scenario_3.log
logs/scenario_4.log
logs/scenario_5.log
logs/scenario_6.log
logs/scenario_7.log
yaml/generation_0/scenario_0.yaml
yaml/generation_0/scenario_1.yaml
yaml/generation_0/scenario_2.yaml
yaml/generation_0/scenario_3.yaml
yaml/generation_0/scenario_4.yaml
yaml/generation_0/scenario_5.yaml
yaml/generation_0/scenario_6.yaml
yaml/generation_0/scenario_7.yaml
```

Useful inspection commands:

```bash
ssh cloud29

/root/krkn-ai-venv/bin/krkn_ai monitor -o \
  /root/krkn-ai-cbt-results-cbt-aware/905debba-9b29-43d2-a894-d002fec9a98f
```

```bash
cat /root/krkn-ai-cbt-results-cbt-aware/905debba-9b29-43d2-a894-d002fec9a98f/reports/all.csv
```

```bash
jq . /root/krkn-ai-cbt-results-cbt-aware/905debba-9b29-43d2-a894-d002fec9a98f/results.json
```

The generated scenario YAML records the exact command and parameter set passed to `krknctl`. The scenario log records the Krkn container output, return code, resiliency output, and errors.

## CBT validation performed around Krkn-AI

Krkn-AI execution was combined with direct CBT API validation.

### Backup before chaos

The original full and incremental chain already existed. The incremental backup used:

```text
VirtualMachineBackup: fedora-cbt-vm-incremental
Tracker: fedora-cbt-tracker
PVC: cbt-backup-output
Mode: Push
```

The backup reported:

```text
type: Incremental
done: True
checkpoint: fedora-cbt-vm-incremental-2026-09-20_18-49-08
```

### Post-chaos backup

Before the post-chaos backup, `cbt-backup-writer` was deleted to release the RWO backup PVC. A uniquely named backup was created:

```text
VirtualMachineBackup: fedora-cbt-vm-incremental-post-chaos
```

The result was:

```text
type: Incremental
done: True
checkpoint: fedora-cbt-vm-incremental-post-chaos-2026-09-20_19-25-08
```

The tracker advanced to the new checkpoint. The payload was present:

```text
/backup/fedora-cbt-vm/fedora-cbt-vm-incremental-post-chaos-2026-09-20_19-25-08/fedora-cbt-vm-incremental-post-chaos-datadisk.qcow2
```

Observed payload size:

```text
786448 bytes
```

### VM and CBT recovery

After the Krkn campaign and post-chaos backup:

```text
VM status: Running
VM ready: true
VMI phase: Running
VM CBT state: Enabled
virt-launcher: Running and ready
cbt-backup-writer: Running and ready
```

This validates the recovery and checkpoint path, but not restore correctness.

## Prometheus evidence

The tested cluster did not expose a dedicated CBT backup metric family. The campaign therefore used generic KubeVirt, Kubernetes, and workqueue metrics.

The repository CBT operations documentation identifies these relevant families:

- `kubevirt_workqueue_depth`;
- `kubevirt_workqueue_retries_total`;
- `kubevirt_workqueue_unfinished_work_seconds`;
- `kubevirt_vmi_dirty_rate_bytes_per_second`;
- `kube_persistentvolumeclaim_status_phase`;
- `kube_pod_status_ready`;
- `kube_pod_container_status_restarts_total`;
- CSI operation metrics;
- ODF/Ceph metrics when exporters are available.

Post-campaign values collected from the cluster were:

```text
VMI dirty rate: 0
Backup workqueue retry rate: 0.007017543859649122
Backup unfinished work: 0
Backup PVC Bound: 1
Ready CBT pods: 2
```

The dirty-rate value is workload telemetry, not a transferred-byte counter. A non-zero dirty rate is expected while the guest is writing and is not itself a failure.

The backup CR status and tracker status remain authoritative for backup completion and checkpoint advancement.

## Fitness interpretation

The final best fitness was `65.7753%`, and the VMI outage scored `57.8947%`.

These values must not be interpreted as:

```text
65.8% CBT correctness
57.9% backup recovery
```

They are Krkn-AI experiment scores. The score includes Krkn execution success and the configured fitness signals. The final run's generic SLO component changed for some candidates while the Krkn scenario result remained successful.

The CBT verdict must be calculated separately from:

- `VirtualMachineBackup.status.type`;
- `VirtualMachineBackup.status.conditions`;
- `VirtualMachineBackup.status.checkpointName`;
- `VirtualMachineBackupTracker.status.latestCheckpoint`;
- backup payload presence and integrity checks;
- VM/VMI recovery;
- CBT state `Enabled` after chaos;
- guest/application data validation.

## Restore limitation

A restore test was not executed because the current CBT API path does not expose a compatible restore operation.

The repository documentation states:

- push mode writes backup payloads to a filesystem PVC;
- `VirtualMachineBackup` is a low-level backup primitive;
- `VirtualMachineRestore` restores `VirtualMachineSnapshot` objects;
- `VirtualMachineRestore` is not a restore consumer for the push-mode CBT payload;
- restore, retention, transport, encryption, and application consistency require a complete backup solution.

The current result should therefore be reported as:

```text
Full/incremental backup: PASS
Chaos execution: PASS
Checkpoint advancement: PASS
VM recovery: PASS
CBT remains enabled: PASS
Payload exists: PASS
Restore validation: NOT AVAILABLE
Overall: PASS_WITHOUT_RESTORE
```

Do not claim that `Incremental` status proves restore correctness. The repository CBT documentation explicitly says that it proves checkpoint-based mode selection, not exact changed-byte count, payload integrity, restore correctness, or application consistency.

## Reproducing the final campaign

The following assumes that the disposable CBT resources already exist on `cloud29`.

### 1. Verify the cluster

```bash
ssh cloud29

KUBECONFIG=/root/blue/kubeconfig oc get vm,vmi,pvc,pod -n cbt-demo -o wide
KUBECONFIG=/root/blue/kubeconfig oc get virtualmachinebackup,virtualmachinebackuptracker -n cbt-demo -o wide
KUBECONFIG=/root/blue/kubeconfig oc get vm fedora-cbt-vm -n cbt-demo -o json \
  | jq '.status.changedBlockTracking'
```

Require:

```text
VM/VMI Running
CBT state Enabled
backup-output PVC Bound
no backup already in progress
```

### 2. Ensure the PVC consumer exists

```bash
KUBECONFIG=/root/blue/kubeconfig \
  oc apply -f /tmp/cbt-backup-writer.yaml

KUBECONFIG=/root/blue/kubeconfig \
  oc wait --for=jsonpath='{.status.phase}'=Running \
  pod/cbt-backup-writer -n cbt-demo --timeout=180s
```

### 3. Run Krkn-AI

```bash
/root/krkn-ai-venv/bin/krkn_ai run \
  -k /root/blue/kubeconfig-krkn \
  -c /root/krkn-ai-cbt-matrix.yaml \
  -o /root/krkn-ai-cbt-results-cbt-aware \
  -r krknctl \
  -s 42 \
  -v
```

### 4. Inspect results

```bash
/root/krkn-ai-venv/bin/krkn_ai monitor -o \
  /root/krkn-ai-cbt-results-cbt-aware/<run-uuid>
```

### 5. Validate CBT after Krkn-AI

```bash
KUBECONFIG=/root/blue/kubeconfig \
  oc get vm,vmi -n cbt-demo -o json \
  | jq '.items[] | {
      kind,
      name: .metadata.name,
      phase: .status.phase,
      ready: .status.ready,
      cbt: .status.changedBlockTracking
    }'
```

### 6. Run the follow-up incremental backup

The backup writer must be deleted first because the backup PVC is RWO:

```bash
KUBECONFIG=/root/blue/kubeconfig \
  oc delete pod cbt-backup-writer -n cbt-demo --wait=true
```

Create a uniquely named backup using the existing tracker, wait for:

```text
status.type=Incremental
status.conditions[type=Done].status=True
```

Then inspect:

```bash
KUBECONFIG=/root/blue/kubeconfig \
  oc get virtualmachinebackup <backup-name> -n cbt-demo -o json \
  | jq '{type:.status.type,
         checkpoint:.status.checkpointName,
         conditions:.status.conditions,
         includedVolumes:.status.includedVolumes}'

KUBECONFIG=/root/blue/kubeconfig \
  oc get virtualmachinebackuptracker fedora-cbt-tracker -n cbt-demo -o json \
  | jq '.status.latestCheckpoint'
```

Recreate the writer only after backup completion.

## Known gaps and recommended next work

### 1. Add a CBT lifecycle wrapper

The next useful implementation should be a wrapper in this CBT repository, not a Krkn-AI source modification. It should:

1. verify VM/VMI and CBT state;
2. delete the RWO backup-PVC consumer;
3. create and validate a full baseline backup;
4. recreate the writer and generate workload writes;
5. run a deterministic Krkn candidate;
6. delete the writer;
7. create and validate an incremental backup;
8. verify tracker/checkpoint advancement;
9. verify VM recovery and CBT state;
10. emit a CBT-specific JSON verdict.

### 2. Use explicit candidate matrices

The genetic population generated duplicate node candidates. A CBT qualification run should explicitly cover:

```text
VMI:
  kubevirt-outage

Pod:
  virt-launcher disruption
  virt-handler disruption
  virt-controller disruption

Storage:
  pvc-scenarios
  storage-throttle

Resource:
  node-cpu-hog
  node-memory-hog
  node-io-hog

Network:
  network-scenarios after a compatible node interface is available
```

### 3. Add trigger-aware lifecycle handling

The current Krkn-AI run did not pass trigger flags such as:

```text
--trigger-command
--triggers-on-timeout fail
```

A direct Krkn wrapper can provide one-backup-per-injection lifecycle control today. Combining those triggers inside each Krkn-AI population candidate requires Krkn-AI runner support or an external wrapper.

### 4. Add payload and restore validation

The current run verified payload existence and size only. A complete CBT test needs:

- a payload format/integrity checker;
- expected guest-write markers;
- changed-range validation;
- a restore consumer for push-mode payloads;
- restore into a disposable VM;
- guest data verification after restore.

Until that exists, use `PASS_WITHOUT_RESTORE` rather than claiming full backup correctness.

## References in this repository

- [`docs/cbt/CBT-ARCHITECTURE.md`](../cbt/CBT-ARCHITECTURE.md)
- [`docs/cbt/CBT-OPERATIONS.md`](../cbt/CBT-OPERATIONS.md)
- [`docs/cbt/CBT-TEST-GUIDE.md`](../cbt/CBT-TEST-GUIDE.md)
- [`docs/chaos-test/KRKN-AI-CBT.md`](../chaos-test/KRKN-AI-CBT.md)
- [`docs/chaos-test/scenarios_v2.md`](../chaos-test/scenarios_v2.md)
- [`manifests/fedora-cbt-vm.yaml`](../../manifests/fedora-cbt-vm.yaml)
- [`manifests/backup-pvc.yaml`](../../manifests/backup-pvc.yaml)
- [`manifests/backup-tracker.yaml`](../../manifests/backup-tracker.yaml)
- [`manifests/full-backup.yaml`](../../manifests/full-backup.yaml)
- [`manifests/incremental-backup.yaml`](../../manifests/incremental-backup.yaml)
