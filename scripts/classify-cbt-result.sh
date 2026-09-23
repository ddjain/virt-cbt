#!/usr/bin/env bash
set -euo pipefail

NAMESPACE=${NAMESPACE:-cbt-demo}
VM_NAME=${VM_NAME:-fedora-cbt-vm}
VMB_NAME=${VMB_NAME:-fedora-cbt-vm-incremental}
TRACKER_NAME=${TRACKER_NAME:-fedora-cbt-tracker}
BACKUP_PVC=${BACKUP_PVC:-cbt-backup-output}
EXPECTED_TYPE=${EXPECTED_TYPE:-Incremental}
OUTPUT=${OUTPUT:-./cbt-result.json}

command -v oc >/dev/null || { echo 'oc is required' >&2; exit 127; }
command -v jq >/dev/null || { echo 'jq is required' >&2; exit 127; }

# Status/condition fields below are recorded for context only. They are
# controller-reported and are exactly what a chaos scenario (a crashed or
# racing virt-launcher/virt-handler/backup controller) can leave stale or
# wrong, so none of them decide pass/fail on their own.
vmb=$(oc get virtualmachinebackup "$VMB_NAME" -n "$NAMESPACE" -o json)
vm=$(oc get vm "$VM_NAME" -n "$NAMESPACE" -o json)
vmi=$(oc get vmi "$VM_NAME" -n "$NAMESPACE" -o json 2>/dev/null || printf '{}')
tracker=$(oc get virtualmachinebackuptracker "$TRACKER_NAME" -n "$NAMESPACE" -o json)

# The authoritative signal: read the resulting qcow2 artifact's own
# backing-file metadata directly off the backup PVC. A genuine CBT
# incremental is chained to the disk's dirty-bitmap overlay
# (.../libvirt/qemu/cbt/<disk>.qcow2); a Full backup is self-contained. This
# fact is fixed at file-creation time, so it survives whatever chaos does to
# pods/controllers afterwards.
evidence_rc=0
evidence=$("$(dirname "$0")/cbt-evidence-check.sh" \
  --namespace "$NAMESPACE" --vm "$VM_NAME" --backup "$VMB_NAME" \
  --expected "$EXPECTED_TYPE" --backup-pvc "$BACKUP_PVC") || evidence_rc=$?
[[ -n $evidence ]] || evidence='{}'

jq -n \
  --argjson vmb "$vmb" \
  --argjson vm "$vm" \
  --argjson vmi "$vmi" \
  --argjson tracker "$tracker" \
  --argjson evidence "$evidence" \
  --argjson evidenceOk "$([[ $evidence_rc -eq 0 ]] && echo true || echo false)" \
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
  def reported_type: ($vmb.status.type // "Unknown");
  def physical_type: ($evidence.physicalType // "Unknown");
  # classification is decided from evidenceOk (physical qcow2 evidence) plus
  # cluster health, never from reported_type/done/failed alone.
  def classification:
    if evidenceOk and vmi_running then "pass"
    elif (physical_type == "Full") and vmi_running and not failed then "safe_full_fallback"
    elif failed then "bounded_failure"
    else "fail"
    end;
  {
    namespace: $namespace,
    vm: $vm_name,
    vmb: $vmb_name,
    tracker: $tracker_name,
    reportedType: reported_type,
    physicalType: physical_type,
    evidence: $evidence,
    evidenceOk: evidenceOk,
    done: done,
    failed: failed,
    vmiRunning: vmi_running,
    checkpoint: checkpoint,
    classification: classification,
    pass: (classification == "pass"),
    accepted: (classification == "pass" or classification == "safe_full_fallback"),
    score: (if classification == "pass" then 1 elif classification == "safe_full_fallback" then 0 elif classification == "bounded_failure" then 0 else -1 end)
  }
' | tee "$OUTPUT"

jq -e '.classification == "pass" or .classification == "safe_full_fallback" or .classification == "bounded_failure"' "$OUTPUT" >/dev/null
