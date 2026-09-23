# Krkn-AI CBT Resilience Runbook

This runbook connects the repository's CBT backup chain to the `kubevirt-outage`
scenario implemented by Krkn-AI. It is intentionally narrower than the full
`scenarios_v2.md` campaign: Krkn-AI currently supplies VMI disruption and
scenario search, while the backup lifecycle remains controlled by this
repository.

## What Krkn-AI can and cannot drive

Krkn-AI's KubeVirt scenario runs `krknctl run kubevirt-outage` and deletes one
selected VMI, then waits for VM recovery. It does not create a
`VirtualMachineBackup`, inspect the CBT tracker, or pass Krkn trigger flags
through its scenario command builder. Therefore:

- create and verify the CBT baseline with `docs/cbt/CBT-TEST-GUIDE.md`;
- start the test VMB with the repository manifest;
- wait for that VMB to report `Progressing=True`;
- start Krkn-AI with only `kubevirt-scenarios` enabled;
- judge the run from VMB/VMBT/CBT state, not from VMI recovery alone.

`CBT-CH-03` is the first recommended experiment. It tests VMI/virt-launcher
outage during backup without requiring node or storage failure credentials.

## Safety gates

Run only on a disposable cluster. Run the commands from a workstation with
`oc`, `jq`, `krknctl`, and Krkn-AI installed. Copy the authorized cloud29
kubeconfig to a temporary path; `/root/blue/kubeconfig` exists on cloud29,
not on the workstation:

```bash
scp cloud29:/root/blue/kubeconfig /tmp/cloud29-cbt-kubeconfig
export KUBECONFIG=/tmp/cloud29-cbt-kubeconfig
export KRKN_AI_REPO=/Users/darjain/projects/krkn-chaos/krkn-ai
```

Before each run require:

```bash
export NAMESPACE=cbt-demo
export VM_NAME=fedora-cbt-vm
export TRACKER_NAME=fedora-cbt-tracker
export VMB_NAME=fedora-cbt-vm-incremental

oc get vm,vmi,pvc -n "$NAMESPACE" -o wide
oc get vm "$VM_NAME" -n "$NAMESPACE" -o json | jq '.status.changedBlockTracking'
oc get virtualmachinebackup,virtualmachinebackuptracker -n "$NAMESPACE" -o wide
oc get nodes
oc get storagecluster,cephcluster -n openshift-storage -o wide
```


Do not proceed unless the VM/VMI is Running, CBT is `Enabled`, all scenario
PVCs are Bound, ODF is Ready, nodes are Ready, and no backup is already in
progress. Preserve diagnostics before every injection.

## Discover a target-specific Krkn-AI config

Run discovery from the Krkn-AI checkout; the kubeconfig remains outside this
repository:

```bash
cd /Users/darjain/projects/krkn-chaos/krkn-ai
uv run krkn_ai discover \
  -k /tmp/cloud29-cbt-kubeconfig \
  -n '^cbt-demo$' \
  -pl '.*' \
  -nl 'kubernetes.io/hostname' \
  -o /tmp/krkn-ai-cbt.yaml \
  -S overwrite
```

Edit `/tmp/krkn-ai-cbt.yaml` after discovery. Keep the discovered
`cluster_components` section, but set the experiment to one deterministic
KubeVirt candidate:

```yaml
generations: 1
population_size: 2
composition_rate: 0
population_injection_rate: 0
wait_duration: 30
seed: 42

scenario:
  pod-scenarios: {enable: false}
  application-outages: {enable: false}
  container-scenarios: {enable: false}
  node-cpu-hog: {enable: false}
  node-memory-hog: {enable: false}
  node-io-hog: {enable: false}
  time-scenarios: {enable: false}
  network-scenarios: {enable: false}
  dns-outage: {enable: false}
  syn-flood: {enable: false}
  pvc-scenarios: {enable: false}
  kubevirt-scenarios: {enable: true}
  storage-throttle: {enable: false}
  service-disruption: {enable: false}

fitness_function:
  items:
    - query: 'sum(kube_pod_container_status_restarts_total{namespace="cbt-demo"})'
      type: point
      weight: 1
  include_krkn_failure: true
```

Discovery must produce a VMI under `cluster_components.namespaces[].vmis`.
If it does not, stop: Krkn-AI will reject `kubevirt-scenarios` rather than
selecting the CBT VM. Confirm the generated VMI name is `fedora-cbt-vm` before
running.

## Run CBT-CH-03

First establish the ordinary chain and generate guest writes as described in
the CBT test guide. Then use two shells. Shell 1 waits for the exact backup
phase and only then starts Krkn-AI:

```bash
cd /Users/darjain/projects/redhat-chaos/virt-cbt
export KUBECONFIG=/tmp/cloud29-cbt-kubeconfig
export KRKN_AI_REPO=/Users/darjain/projects/krkn-chaos/krkn-ai
./scripts/run-krkn-ai-cbt.sh \
  --config /tmp/krkn-ai-cbt.yaml \
  --output /tmp/krkn-ai-cbt-results \
  --vmb "$VMB_NAME" \
  --namespace "$NAMESPACE" \
  --seed 42
```

Shell 2 starts the backup after Shell 1 is waiting:

```bash
export KUBECONFIG=/tmp/cloud29-cbt-kubeconfig
oc apply -f manifests/incremental-backup.yaml
```

The wrapper fails if `Progressing=True` is not observed within 600 seconds; it
never substitutes an arbitrary sleep. After Krkn-AI returns, it waits for this
same VMB to reach `Done=True`, `Complete=True`, or `Failed=True` (default
completion timeout 600 seconds) before capturing VMB/VMBT state and classifying
the outcome. Krkn-AI invokes the discovered `kubevirt-outage` candidate against
the VMI; the generated Krkn command can be inspected in the result log.

For a full-backup injection, create an equivalent uniquely named VMB whose
tracker is empty, change `VMB_NAME`, and run the same procedure. Do not reuse a
completed object name without deleting it after preserving its evidence.

## Acceptance and evidence

Immediately after Krkn-AI exits, capture:

```bash
mkdir -p /tmp/krkn-ai-cbt-evidence
oc get vm,vmi,pvc,virtualmachinebackup,virtualmachinebackuptracker,events \
  -n "$NAMESPACE" -o yaml > /tmp/krkn-ai-cbt-evidence/cluster.yaml
oc get virtualmachinebackup "$VMB_NAME" -n "$NAMESPACE" -o json \
  > /tmp/krkn-ai-cbt-evidence/vmb.json
oc get virtualmachinebackuptracker "$TRACKER_NAME" -n "$NAMESPACE" -o json \
  > /tmp/krkn-ai-cbt-evidence/tracker.json
oc logs -n openshift-cnv deploy/virt-controller --since=1h \
  > /tmp/krkn-ai-cbt-evidence/virt-controller.log
oc logs -n openshift-cnv daemonset/virt-handler --since=1h \
  > /tmp/krkn-ai-cbt-evidence/virt-handler.log
```

Pass only when the VMI returns Running, CBT returns to Enabled, the interrupted
VMB reaches a terminal state (or is explicitly failed and cleaned up), and the
tracker advances only for a verified completed backup. Run a follow-up backup
with the same tracker. `Incremental` is expected when checkpoint/bitmap state
survived; a `Full` fallback is acceptable only when the evidence explains state
loss. Never treat VMI recovery or a Krkn success code as proof of backup
correctness.

Krkn-AI output is under `/tmp/krkn-ai-cbt-results`, including scenario logs and
`reports/all.csv`. Retain the exact config, generated command, Krkn/Krknctl
versions, VMB/VMBT JSON, recovery timestamps, and cleanup actions.

## Cleanup

After evidence capture, follow `CBT-CH-10` in `scenarios_v2.md`: inspect
finalizers and backup-PVC attachment, delete only the disposable VMB, and verify
that a new backup can use the tracker safely. Delete `/tmp/cloud29-cbt-kubeconfig`
and temporary results when the run record has been archived.

## Multi-scenario campaign without modifying Krkn-AI

`configs/krkn-ai-cbt-matrix.yaml` is the exploratory Krkn-AI matrix. Discover
into it and review `cluster_components` before running:

```bash
cd /Users/darjain/projects/krkn-chaos/krkn-ai
uv run krkn_ai discover \
  -k /tmp/cloud29-cbt-kubeconfig \
  -n '^(cbt-demo|openshift-cnv)$' \
  -pl '.*' \
  -nl 'kubernetes.io/hostname' \
  -o /Users/darjain/projects/redhat-chaos/virt-cbt/configs/krkn-ai-cbt-matrix.yaml \
  -S merge
```

The matrix enables VMI, pod, network, PVC, storage-throttle, and node resource
scenario families. It is useful for discovering which disruption is impactful,
but Krkn-AI's unmodified runner cannot create a fresh CBT backup before every
candidate and does not forward Krkn trigger flags.

For valid CBT lifecycle results, execute one candidate at a time with the
external trigger-aware runner:

```bash
export KUBECONFIG=/tmp/cloud29-cbt-kubeconfig
export NAMESPACE=cbt-demo

./scripts/run-cbt-krkn-scenario.sh \
  --scenario kubevirt-outage \
  --output /tmp/cbt-results \
  --namespace "$NAMESPACE" \
  --vm fedora-cbt-vm \
  --vmb fedora-cbt-vm-incremental \
  --tracker fedora-cbt-tracker \
  --timeout 60 \
  --kill-count 1
```

The runner applies a fresh VMB, passes:

```text
--trigger-command
--trigger-expected-rc 0
--triggers-on-timeout fail
--triggers-timeout 600
--triggers-interval 5
```

and captures `cbt-result.json`. Repeat with controlled targets for
`pod-scenarios`, `network-chaos`, `storage-throttle`, `pvc-scenarios`,
`node-cpu-hog`, `node-memory-hog`, and `node-io-hog`.

Examples of scenario-specific flags:

```bash
# virt-handler or virt-controller pod; choose the exact target label/pattern.
./scripts/run-cbt-krkn-scenario.sh \
  --scenario pod-scenarios --output /tmp/cbt-results \
  -- --namespace openshift-cnv \
     --pod-label kubevirt.io=virt-handler \
     --name-pattern '.*' --disruption-count 1

# KubeVirt VMI outage.
./scripts/run-cbt-krkn-scenario.sh \
  --scenario kubevirt-outage --output /tmp/cbt-results \
  -- --namespace cbt-demo --vm-name fedora-cbt-vm \
     --kill-count 1 --timeout 60

# Network and resource scenarios must target the VMI host node after discovery.
./scripts/run-cbt-krkn-scenario.sh \
  --scenario network-chaos --output /tmp/cbt-results \
  -- --node-name "$VMI_NODE" --duration 30

./scripts/run-cbt-krkn-scenario.sh \
  --scenario node-cpu-hog --output /tmp/cbt-results \
  -- --node-selector "kubernetes.io/hostname=$VMI_NODE"
```

This split is intentional: Krkn-AI discovers and ranks the candidate matrix;
the trigger-aware direct Krkn runner provides one-backup-per-injection CBT
validity. A Krkn-AI source change is required before combining both behaviors
inside one Krkn-AI population.
