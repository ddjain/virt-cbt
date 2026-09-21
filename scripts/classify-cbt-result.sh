#!/usr/bin/env bash
set -euo pipefail

NAMESPACE=${NAMESPACE:-cbt-demo}
VM_NAME=${VM_NAME:-fedora-cbt-vm}
VMB_NAME=${VMB_NAME:-fedora-cbt-vm-incremental}
TRACKER_NAME=${TRACKER_NAME:-fedora-cbt-tracker}
OUTPUT=${OUTPUT:-./cbt-result.json}

command -v oc >/dev/null || { echo 'oc is required' >&2; exit 127; }
command -v jq >/dev/null || { echo 'jq is required' >&2; exit 127; }

vmb=$(oc get virtualmachinebackup "$VMB_NAME" -n "$NAMESPACE" -o json)
vm=$(oc get vm "$VM_NAME" -n "$NAMESPACE" -o json)
vmi=$(oc get vmi "$VM_NAME" -n "$NAMESPACE" -o json 2>/dev/null || printf '{}')
tracker=$(oc get virtualmachinebackuptracker "$TRACKER_NAME" -n "$NAMESPACE" -o json)

jq -n \
  --argjson vmb "$vmb" \
  --argjson vm "$vm" \
  --argjson vmi "$vmi" \
  --argjson tracker "$tracker" \
  --arg namespace "$NAMESPACE" \
  --arg vm_name "$VM_NAME" \
  --arg vmb_name "$VMB_NAME" \
  --arg tracker_name "$TRACKER_NAME" '
  def condition($type): (($vmb.status.conditions // []) | any(.[]; .type == $type and .status == "True"));
  def done: (condition("Done") or condition("Complete"));
  def failed: condition("Failed");
  def cbt_enabled: ($vm.status.changedBlockTracking.state == "Enabled");
  def vmi_running: ($vmi.status.phase == "Running");
  def checkpoint: ($tracker.status.latestCheckpoint // "");
  def no_stale_finalizers:
    (($vmb.metadata.deletionTimestamp // null) == null
      or (($vmb.metadata.finalizers // []) | length == 0));
  def type: ($vmb.status.type // "Unknown");
  def classification:
    if done and cbt_enabled and vmi_running and no_stale_finalizers and type == "Incremental" then "pass"
    elif done and cbt_enabled and vmi_running and no_stale_finalizers and type == "Full" then "safe_full_fallback"
    elif failed then "bounded_failure"
    else "fail"
    end;
  {
    namespace: $namespace,
    vm: $vm_name,
    vmb: $vmb_name,
    tracker: $tracker_name,
    backup_type: type,
    done: done,
    failed: failed,
    no_stale_finalizers: no_stale_finalizers,
    vmi_running: vmi_running,
    checkpoint: checkpoint,
    classification: classification,
    pass: (classification == "pass"),
    accepted: (classification == "pass" or classification == "safe_full_fallback"),
    score: (if classification == "pass" then 1 elif classification == "safe_full_fallback" then 0 elif classification == "bounded_failure" then 0 else -1 end)
  }
' | tee "$OUTPUT"

jq -e '.classification == "pass" or .classification == "safe_full_fallback" or .classification == "bounded_failure"' "$OUTPUT" >/dev/null
