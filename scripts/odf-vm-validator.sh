#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CONFIG=${CONFIG:-$ROOT/config.env}
COMMAND=help
ARGS=()
while (($#)); do case "$1" in --config) CONFIG=${2:?missing config}; shift 2;; -h|--help) COMMAND=help; shift;; *) COMMAND=$1; shift; ARGS+=("$@"); break;; esac; done
[[ -r "$CONFIG" ]] && source "$CONFIG"
: "${NAMESPACE:=cbt-demo}"; : "${VM_COUNT:=1}"; : "${VM_PREFIX:=fedora-cbt}"; : "${VM_LABEL_SELECTOR:=app.kubernetes.io/name=odf-cbt-validator}"
: "${CONTAINER_IMAGE:=quay.io/containerdisks/fedora:41}"; : "${VM_CPU:=1}"; : "${VM_MEMORY:=1Gi}"; : "${DATA_SIZE:=10Gi}"; : "${BACKUP_SIZE:=20Gi}"
: "${DATA_STORAGE_CLASS:=ocs-storagecluster-ceph-rbd}"; : "${BACKUP_STORAGE_CLASS:=$DATA_STORAGE_CLASS}"; : "${TARGET_NODE:=}"
: "${SSH_KEY:=}"; : "${SSH_PUBLIC_KEY:=}"; : "${SSH_USER:=fedora}"; : "${TIMEOUT:=600}"; : "${STABILIZE_TIMEOUT:=300}"; : "${BACKUP_CONCURRENCY:=2}"; : "${CBT_CHANGE_WAIT:=5}"; : "${REPORTS_DIR:=reports}"
export KUBECONFIG=${KUBECONFIG:-}
if [[ -z $SSH_PUBLIC_KEY && -n $SSH_KEY && -r $SSH_KEY.pub ]]; then SSH_PUBLIC_KEY=$(<"$SSH_KEY.pub"); fi

usage() { cat <<'EOF'
Usage: odf-vm-validator.sh [--config FILE] COMMAND [options]
Commands: generate-keys check-prereqs density-setup density-status density-teardown discover-vms backup cbt-backup cbt-payload-proof cbt-evidence verify status ssh report list-reports e2e
Selection options: --vms CSV | --count N | --selector key=value | --all
EOF
}
need() { command -v "$1" >/dev/null || { echo "ERROR: $1 is required" >&2; return 127; }; }
run_id=''; run_dir=''; selected=(); passed=0; failed=0
start_report() { local cmd=$1; run_id="run-$(date -u +%Y%m%dT%H%M%SZ)-$cmd"; run_dir="$REPORTS_DIR/$run_id"; mkdir -p "$run_dir/per-vm"; : >"$run_dir/run.log"; exec > >(tee -a "$run_dir/run.log") 2>&1; started=$(date -u +%Y-%m-%dT%H:%M:%SZ); }
finish_report() { local status=$1; completed=$(date -u +%Y-%m-%dT%H:%M:%SZ); jq -n --arg id "$run_id" --arg c "$COMMAND" --arg ns "$NAMESPACE" --arg s "$started" --arg e "$completed" --argjson sel "$(printf '%s\n' "${selected[@]}" | jq -Rsc 'split("\n")|map(select(length>0))')" --argjson p "$passed" --argjson f "$failed" --argjson r "$(jq -s '.' "$run_dir/per-vm"/*.json 2>/dev/null || echo '[]')" '{runId:$id,command:$c,namespace:$ns,startedAt:$s,completedAt:$e,selected:$sel,passed:$p,failed:$f,results:$r}' >"$run_dir/summary.json"; echo "Report: $run_dir/summary.json"; return "$status"; }
parse_selection() { local mode='' value='' x; while (($#)); do case "$1" in --vms|--count|--selector) [[ -z $mode ]] || { echo 'ERROR: specify exactly one of VMS, N, SELECTOR, or ALL=1' >&2; return 2; }; mode=${1#--}; value=${2-}; shift 2;; --all) [[ -z $mode ]] || { echo 'ERROR: specify exactly one of VMS, N, SELECTOR, or ALL=1' >&2; return 2; }; mode=all; shift;; *) echo "ERROR: unknown option $1" >&2; return 2;; esac; done; [[ -n $mode ]] || { echo 'ERROR: specify exactly one of VMS, N, SELECTOR, or ALL=1' >&2; return 2; }; selected=(); if [[ $mode == all ]]; then while IFS= read -r x; do selected+=("$x"); done < <("$ROOT/scripts/select-vms.sh" --kubeconfig "$KUBECONFIG" --namespace "$NAMESPACE" --base-selector "$VM_LABEL_SELECTOR" --all); else while IFS= read -r x; do selected+=("$x"); done < <("$ROOT/scripts/select-vms.sh" --kubeconfig "$KUBECONFIG" --namespace "$NAMESPACE" --base-selector "$VM_LABEL_SELECTOR" "--$mode" "$value"); fi; ((${#selected[@]})) || { echo 'ERROR: selection matched no managed VMs' >&2; return 1; }; }
record() { local vm=$1 status=$2 message=$3; jq -n --arg vm "$vm" --arg st "$status" --arg msg "$message" '{vm:$vm,status:$st,message:$msg}' >"$run_dir/per-vm/$vm.json"; if [[ $status == PASS ]]; then ((passed+=1)); else ((failed+=1)); fi; }
check_prereqs() { for t in oc virtctl kube-burner jq; do need "$t" || return; done; [[ -r ${KUBECONFIG:-/dev/null} || -z ${KUBECONFIG:-} ]] || { echo "ERROR: kubeconfig is unreadable: $KUBECONFIG"; return 1; }; oc get crd virtualmachines.kubevirt.io virtualmachinebackups.backup.kubevirt.io virtualmachinebackuptrackers.backup.kubevirt.io >/dev/null; oc get storageclass "$DATA_STORAGE_CLASS" "$BACKUP_STORAGE_CLASS" >/dev/null; oc get storagecluster,cephcluster -n openshift-storage >/dev/null; oc get volumesnapshotclass -o json | jq -e '.items|length>0' >/dev/null; oc get hyperconverged -A -o json | jq -e '..|objects|select(has("changedBlockTracking"))' >/dev/null; [[ -n $SSH_KEY && -r $SSH_KEY && -r "$SSH_KEY.pub" ]] || echo 'WARNING: SSH_KEY pair not configured; guest checks will fail'; echo 'Prerequisites OK'; }
generate_keys() { [[ -n $SSH_KEY ]] || SSH_KEY="$ROOT/keys/cbt-validator"; mkdir -p "$(dirname "$SSH_KEY")"; if [[ ! -r $SSH_KEY ]]; then ssh-keygen -q -t ed25519 -N '' -f "$SSH_KEY"; fi; SSH_PUBLIC_KEY=$(<"$SSH_KEY.pub"); echo "SSH key: $SSH_KEY"; }
render_job() { local out=$1; sed -e "s|REPLACE_NAMESPACE|$NAMESPACE|g" -e "s|REPLACE_REPLICAS|$VM_COUNT|g" -e "s|REPLACE_VM_PREFIX|$VM_PREFIX|g" -e "s|REPLACE_CONTAINER_IMAGE|$CONTAINER_IMAGE|g" -e "s|REPLACE_SSH_USER|$SSH_USER|g" -e "s|REPLACE_SSH_PUBLIC_KEY|$SSH_PUBLIC_KEY|g" -e "s|REPLACE_VM_CPU|$VM_CPU|g" -e "s|REPLACE_VM_MEMORY|$VM_MEMORY|g" -e "s|REPLACE_DATA_SIZE|$DATA_SIZE|g" -e "s|REPLACE_BACKUP_SIZE|$BACKUP_SIZE|g" -e "s|REPLACE_DATA_STORAGE_CLASS|$DATA_STORAGE_CLASS|g" -e "s|REPLACE_BACKUP_STORAGE_CLASS|$BACKUP_STORAGE_CLASS|g" -e "s|REPLACE_TARGET_NODE|$TARGET_NODE|g" "$ROOT/kube-burner/odf-cbt-density.yml" >"$out"; }
density_setup() { [[ $VM_COUNT =~ ^[1-9][0-9]*$ ]] || { echo 'ERROR: VM_COUNT must be positive'; return 2; }; local existing; existing=$(oc get namespace "$NAMESPACE" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || true); if oc get namespace "$NAMESPACE" >/dev/null 2>&1; then [[ $existing == odf-cbt-validator ]] || { echo "ERROR: namespace $NAMESPACE is not utility-owned"; return 1; }; else oc create namespace "$NAMESPACE"; oc label namespace "$NAMESPACE" app.kubernetes.io/managed-by=odf-cbt-validator --overwrite; fi; if oc get vm -n "$NAMESPACE" -l "$VM_LABEL_SELECTOR" -o name | grep -q .; then echo 'ERROR: managed VM pool already exists; teardown first' >&2; return 1; fi; local job; mkdir -p "$ROOT/kube-burner/rendered"; job=$(mktemp "$ROOT/kube-burner/rendered/density.XXXX.yml"); render_job "$job"; (cd "$ROOT/kube-burner" && kube-burner init --config "rendered/$(basename "$job")" --kubeconfig "$KUBECONFIG" --log-level error); rm -f "$job"; wait_pool; }
wait_pool() { local deadline=$((SECONDS+STABILIZE_TIMEOUT)) x; while ((SECONDS<deadline)); do local count ready; count=$(oc get vm -n "$NAMESPACE" -l "$VM_LABEL_SELECTOR" --no-headers 2>/dev/null | wc -l | tr -d ' '); ready=$(oc get vm -n "$NAMESPACE" -l "$VM_LABEL_SELECTOR" -o json | jq '[.items[]|select(.status.ready==true and .status.changedBlockTracking.state=="Enabled")]|length'); if [[ $count == "$VM_COUNT" && $ready == "$VM_COUNT" ]]; then break; fi; sleep 5; done; selected=(); while IFS= read -r x; do selected+=("$x"); done < <("$ROOT/scripts/select-vms.sh" --kubeconfig "$KUBECONFIG" --namespace "$NAMESPACE" --base-selector "$VM_LABEL_SELECTOR" --count "$VM_COUNT"); ((${#selected[@]} == VM_COUNT)) || { echo 'ERROR: VM pool did not become ready'; return 1; }; for vm in "${selected[@]}"; do oc wait --for=jsonpath='{.status.ready}'=true vm/"$vm" -n "$NAMESPACE" --timeout="${TIMEOUT}s"; oc wait --for=jsonpath='{.status.phase}'=Running vmi/"$vm" -n "$NAMESPACE" --timeout="${TIMEOUT}s"; done; }
density_status() { if [[ ${COUNT_ONLY:-} == 1 ]]; then oc get vm -n "$NAMESPACE" -l "$VM_LABEL_SELECTOR" --no-headers | wc -l; elif [[ ${SUMMARY:-} == 1 ]]; then oc get vm -n "$NAMESPACE" -l "$VM_LABEL_SELECTOR" -o json | jq '{count:(.items|length),ready:([.items[]|select(.status.ready==true)]|length),cbtEnabled:([.items[]|select(.status.changedBlockTracking.state=="Enabled")]|length)}'; else oc get vm,vmi,pvc,virtualmachinebackuptracker -n "$NAMESPACE" -l "$VM_LABEL_SELECTOR" -o wide; fi; }
density_teardown() { local owned; owned=$(oc get namespace "$NAMESPACE" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || true); [[ $owned == odf-cbt-validator ]] || { echo "ERROR: refusing unowned namespace $NAMESPACE" >&2; return 1; }; oc delete namespace "$NAMESPACE" --wait=true; }
discover() { if (($#==0)); then set -- --all; fi; parse_selection "$@"; if [[ ${COUNT_ONLY:-} == 1 ]]; then printf '%s\n' "${#selected[@]}"; else printf '%s\n' "${selected[@]}"; fi; }
wait_backup() {
  # Only a synchronization barrier: waits for the VirtualMachineBackup job to
  # reach a terminal condition. It intentionally does NOT assert .status.type
  # — that field is controller-reported and cannot be trusted under chaos.
  # Use cbt_backup_evidence for the actual Full-vs-Incremental verdict, which
  # is read from the physical qcow2 backing-file metadata instead.
  local vm=$1 name=$2
  oc wait --for=jsonpath='{.status.conditions[?(@.type=="Done")].status}'=True virtualmachinebackup/"$name" -n "$NAMESPACE" --timeout="${TIMEOUT}s" 2>/dev/null || \
    oc wait --for=jsonpath='{.status.conditions[?(@.type=="Complete")].status}'=True virtualmachinebackup/"$name" -n "$NAMESPACE" --timeout="${TIMEOUT}s"
}
backup_one() { local vm=$1 name=$2 tracker="$vm-tracker" pvc="$vm-backup-output"; local checkpoint; checkpoint=$(oc get virtualmachinebackuptracker "$tracker" -n "$NAMESPACE" -o json | jq -r '.status.latestCheckpoint // .status.checkpointName // empty'); [[ -z $checkpoint ]] || { echo "full backup already exists for $vm; use cbt-backup or recreate density"; return 1; }; oc delete virtualmachinebackup "$name" -n "$NAMESPACE" --ignore-not-found; cat <<EOF | oc apply -f -
apiVersion: backup.kubevirt.io/v1alpha1
kind: VirtualMachineBackup
metadata: {name: $name, namespace: $NAMESPACE}
spec:
  source: {apiGroup: backup.kubevirt.io, kind: VirtualMachineBackupTracker, name: $tracker}
  mode: Push
  pvcName: $pvc
  skipQuiesce: true
EOF
wait_backup "$vm" "$name"; cbt_backup_evidence "$vm" "$name" Full; }
cbt_one() { local vm=$1 name=$2 tracker="$vm-tracker" pvc="$vm-backup-output"; oc get virtualmachinebackup "$vm-full" -n "$NAMESPACE" >/dev/null; local before; before=$(oc get virtualmachinebackuptracker "$tracker" -n "$NAMESPACE" -o json | jq -r '.status.latestCheckpoint // .status.checkpointName // empty'); [[ -n $before ]] || { echo "no full checkpoint for $vm"; return 1; }; oc delete virtualmachinebackup "$name" -n "$NAMESPACE" --ignore-not-found; cat <<EOF | oc apply -f -
apiVersion: backup.kubevirt.io/v1alpha1
kind: VirtualMachineBackup
metadata: {name: $name, namespace: $NAMESPACE}
spec:
  source: {apiGroup: backup.kubevirt.io, kind: VirtualMachineBackupTracker, name: $tracker}
  mode: Push
  pvcName: $pvc
  skipQuiesce: true
EOF
wait_backup "$vm" "$name"; cbt_backup_evidence "$vm" "$name" Incremental; }
run_selected() { local action=$1; shift; parse_selection "$@"; start_report "$action"; local vm; for vm in "${selected[@]}"; do if [[ $action == backup ]]; then backup_one "$vm" "$vm-full" && record "$vm" PASS 'Full backup completed' || record "$vm" FAIL 'Full backup failed'; elif [[ $action == cbt-backup ]]; then sleep "$CBT_CHANGE_WAIT"; cbt_one "$vm" "$vm-incremental" && record "$vm" PASS 'Incremental backup completed' || record "$vm" FAIL 'Incremental backup failed'; else verify_one "$vm" && record "$vm" PASS 'VM, backup and guest checks passed' || record "$vm" FAIL 'Verification failed'; fi; done; ((failed==0)) && finish_report 0 || finish_report 1; }
guest_check() { local vm=$1 output; [[ -n $SSH_KEY ]] || return 1; output=$(virtctl ssh -n "$NAMESPACE" -i "$SSH_KEY" --known-hosts=/dev/null --local-ssh-opts='-o' --local-ssh-opts='StrictHostKeyChecking=no' "$SSH_USER@vm/$vm" --command "test -f /data/vm-validator/workload.db -a -f /data/vm-validator/workload.log; mountpoint -q /data; sqlite3 /data/vm-validator/workload.db 'pragma integrity_check' | grep -qx ok; python3 -c \"import sqlite3,hashlib; c=sqlite3.connect('/data/vm-validator/workload.db'); r=c.execute('select seq,payload,digest from records order by seq').fetchall(); assert r and [x[0] for x in r]==list(range(1,len(r)+1)); assert all(hashlib.sha256(x[1].encode()).hexdigest()==x[2] for x in r)\"; echo GUEST_CHECK_OK"); grep -qx GUEST_CHECK_OK <<<"$output"; }
verify_one() { local vm=$1; oc wait --for=jsonpath='{.status.ready}'=true vm/"$vm" -n "$NAMESPACE" --timeout="${TIMEOUT}s"; oc wait --for=jsonpath='{.status.phase}'=Running vmi/"$vm" -n "$NAMESPACE" --timeout="${TIMEOUT}s"; oc get vm "$vm" -n "$NAMESPACE" -o json | jq -e '.status.changedBlockTracking.state=="Enabled"' >/dev/null; oc get pvc "$vm-data" "$vm-backup-output" -n "$NAMESPACE" -o json | jq -e '[.items[].status.phase]|all(.=="Bound")' >/dev/null; wait_backup "$vm" "$vm-full"; cbt_backup_evidence "$vm" "$vm-full" Full; wait_backup "$vm" "$vm-incremental"; cbt_backup_evidence "$vm" "$vm-incremental" Incremental; guest_check "$vm"; sleep 2; guest_check "$vm"; }
status_selected() { if (($#==0)); then set -- --all; fi; parse_selection "$@"; printf '%-32s %-8s %-10s %-12s %-12s %-12s %s\n' VM READY PHASE CBT FULL INCREMENTAL CHECKPOINT; local vm full inc cp; for vm in "${selected[@]}"; do full=$(oc get virtualmachinebackup "$vm-full" -n "$NAMESPACE" -o json 2>/dev/null | jq -r '.status.type // .status.conditions[0].reason // "-"' 2>/dev/null) || full="-"; inc=$(oc get virtualmachinebackup "$vm-incremental" -n "$NAMESPACE" -o json 2>/dev/null | jq -r '.status.type // .status.conditions[0].reason // "-"' 2>/dev/null) || inc="-"; cp=$(oc get virtualmachinebackuptracker "$vm-tracker" -n "$NAMESPACE" -o json 2>/dev/null | jq -r '.status.latestCheckpoint // .status.checkpointName // "-"' 2>/dev/null) || cp="-"; printf '%-32s %-8s %-10s %-12s %-12s %-12s %s\n' "$vm" "$(oc get vm "$vm" -n "$NAMESPACE" -o jsonpath='{.status.ready}' 2>/dev/null || echo -)" "$(oc get vmi "$vm" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo -)" "$(oc get vm "$vm" -n "$NAMESPACE" -o jsonpath='{.status.changedBlockTracking.state}' 2>/dev/null || echo -)" "$full" "$inc" "$cp"; done; }
ssh_guest() { local vm='' cmd=''; while (($#)); do case "$1" in --vm) vm=${2-}; shift 2;; --cmd) cmd=${2-}; shift 2;; *) return 2;; esac; done; [[ -n $vm && $vm == "$VM_PREFIX"-* ]] || { echo 'ERROR: VM is required and must use configured prefix' >&2; return 2; }; [[ -n $SSH_KEY ]] || { echo 'ERROR: SSH_KEY is required' >&2; return 2; }; virtctl ssh -n "$NAMESPACE" -i "$SSH_KEY" --known-hosts=/dev/null --local-ssh-opts='-o StrictHostKeyChecking=no' "$SSH_USER@vm/$vm" --command "${cmd:-hostname}"; }
report() { local f; f=$(find "$REPORTS_DIR" -name summary.json -print | sort | sed -n '$p'); [[ -n $f ]] && cat "$f" || { echo 'No reports'; return 1; }; }
list_reports() { find "$REPORTS_DIR" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | sort -r; }
e2e() { local count=${1:-$VM_COUNT}; density_setup; local sel=(--count "$count"); run_selected backup "${sel[@]}"; run_selected cbt-backup "${sel[@]}"; run_selected verify "${sel[@]}"; report; }
proof_cleanup() {
  local rc=$? cleanup_rc=0
  trap - EXIT
  if [[ -n ${proof_namespace:-} ]] && oc get namespace "$proof_namespace" >/dev/null 2>&1; then
    NAMESPACE=$proof_namespace
    density_teardown || { cleanup_rc=$?; echo "ERROR: proof namespace cleanup failed: $NAMESPACE" >&2; }
  fi
  if [[ ${proof_report_started:-0} == 1 && ${proof_report_done:-0} == 0 ]]; then
    record "${selected[0]:-cbt-payload-proof}" FAIL 'Payload proof did not complete; see run.log'
    finish_report 1 || true
  fi
  ((rc == 0 && cleanup_rc != 0)) && rc=$cleanup_rc
  exit "$rc"
}
proof_guest_command() {
  local vm=$1 command=$2
  virtctl ssh -n "$NAMESPACE" -i "$SSH_KEY" --known-hosts=/dev/null \
    --local-ssh-opts='-o' --local-ssh-opts='StrictHostKeyChecking=no' \
    "$SSH_USER@vm/$vm" --command "$command"
}
wait_for_proof_guest_ssh() {
  local vm=$1 deadline=$((SECONDS+TIMEOUT)) output=''
  echo "Waiting for guest SSH on $vm"
  while ((SECONDS < deadline)); do
    if output=$(proof_guest_command "$vm" 'echo CBT_PROOF_SSH_READY' 2>&1) &&
       [[ $output == *CBT_PROOF_SSH_READY* ]]; then
      echo "Guest SSH ready: $vm"
      return 0
    fi
    sleep 5
  done
  echo "ERROR: guest SSH did not become ready in ${TIMEOUT}s: $output" >&2
  return 1
}
backup_force_full_one() {
  local vm=$1 name=$2 tracker="$1-tracker" pvc="$1-backup-output"
  oc delete virtualmachinebackup "$name" -n "$NAMESPACE" --ignore-not-found
  cat <<EOF | oc apply -f -
apiVersion: backup.kubevirt.io/v1alpha1
kind: VirtualMachineBackup
metadata: {name: $name, namespace: $NAMESPACE}
spec:
  source: {apiGroup: backup.kubevirt.io, kind: VirtualMachineBackupTracker, name: $tracker}
  mode: Push
  pvcName: $pvc
  forceFullBackup: true
  skipQuiesce: true
EOF
  wait_backup "$vm" "$name" Full
}
payload_data_bytes() {
  jq '[.[] | select(.data == true and .depth == 0) | .length] | add // 0'
}
payload_range_data_bytes() {
  local map=$1 start=$2 end=$3
  jq --argjson start "$start" --argjson end "$end" \
    '[.[] | select(.data == true and .depth == 0) | (([.start + .length, $end] | min) - ([.start, $start] | max)) | select(. > 0)] | add // 0' \
    <<<"$map"
}
payload_has_data_in_range() {
  local map=$1 start=$2 end=$3
  jq -e --argjson start "$start" --argjson end "$end" \
    '[.[] | select(.data == true and .depth == 0) | select(.start < $end and (.start + .length) > $start)] | length > 0' \
    <<<"$map" >/dev/null
}
payload_has_nonzero_data_in_range() {
  local map=$1 start=$2 end=$3
  jq -e --argjson start "$start" --argjson end "$end" \
    '[.[] | select(.data == true and .zero == false and .depth == 0) | select(.start < $end and (.start + .length) > $start)] | length > 0' \
    <<<"$map" >/dev/null
}
cbt_backup_evidence() {
  # Determines whether a VirtualMachineBackup's resulting qcow2 is physically
  # a Full (self-contained) or an Incremental (CBT-chained) artifact, by
  # reading the artifact's own qemu-img metadata instead of trusting
  # VirtualMachineBackup/.status, which is controller-reported and can be
  # stale, racy, or wrong under chaos.
  #
  # Ground truth: a genuine CBT incremental is written by KubeVirt as a qcow2
  # whose backing file is the disk's CBT overlay
  # (.../libvirt/qemu/cbt/<disk>.qcow2), because its data only makes sense
  # relative to the tracked dirty bitmap. A Full backup is self-contained and
  # carries no backing file at all. This distinction is baked into the file
  # at creation time and survives virt-launcher pods, nodes, or controllers
  # being killed after the backup completes.
  local vm=$1 name=$2 expected_type=$3
  local evidence_dir=${run_dir:+$run_dir/evidence} evidence_json rc=0
  [[ -n $evidence_dir ]] && mkdir -p "$evidence_dir"

  evidence_json=$("$ROOT/scripts/cbt-evidence-check.sh" \
    --namespace "$NAMESPACE" --vm "$vm" --backup "$name" \
    --expected "$expected_type" --backup-pvc "$vm-backup-output" \
    --timeout "$TIMEOUT") || rc=$?

  [[ -n $evidence_dir ]] && printf '%s\n' "$evidence_json" >"$evidence_dir/$name-evidence.json"

  if ((rc == 0)); then
    jq -r '"CBT evidence: \(.backup) is physically \(.physicalType) (backing=\(.backingFile // "none")), allocated=\(.allocatedDataBytes)B — matches expected \(.expectedType)"' <<<"$evidence_json"
    return 0
  fi
  jq -r '"ERROR: \(.backup) claims/expects \(.expectedType) but the qcow2 artifact is physically \(.physicalType) (backing=\(.backingFile // "none"))"' <<<"$evidence_json" >&2 2>/dev/null || \
    echo "ERROR: physical evidence check failed for $name (expected $expected_type)" >&2
  return 1
}
cbt_evidence_selected() {
  parse_selection "$@"
  start_report cbt-evidence
  local vm
  for vm in "${selected[@]}"; do
    local ok=PASS msg='Full and Incremental artifacts match their physical CBT evidence'
    cbt_backup_evidence "$vm" "$vm-full" Full && cbt_backup_evidence "$vm" "$vm-incremental" Incremental || { ok=FAIL; msg='Physical qcow2 evidence did not match expected backup type'; }
    record "$vm" "$ok" "$msg"
  done
  ((failed==0)) && finish_report 0 || finish_report 1
}
cbt_payload_proof() {
  local stamp vm disk_bytes seed_bytes full_name inc_name control_name
  local full_checkpoint inc_checkpoint control_checkpoint launcher launcher_json launcher_node state_claim image pod
  local full_path inc_path control_path full_map inc_map control_map
  local full_bytes inc_bytes control_bytes full_seed_a full_seed_b seed_a_start=0 seed_a_end=$((128*1024*1024))
  local seed_b_start=$((512*1024*1024)) seed_b_end=$((640*1024*1024))
  local changed_start=$((1024*1024*1024)) changed_end=$((1028*1024*1024))

  for t in oc virtctl kube-burner jq; do need "$t" || return; done
  check_prereqs
  oc get crd virtualmachinebackups.backup.kubevirt.io -o json |
    jq -e 'any(.spec.versions[]; .served and .schema.openAPIV3Schema.properties.spec.properties.forceFullBackup.type == "boolean")' >/dev/null || {
      echo 'ERROR: VirtualMachineBackup CRD lacks spec.forceFullBackup required for the Full control' >&2
      return 2
    }
  [[ -n $SSH_KEY && -r $SSH_KEY ]] || { echo 'ERROR: SSH_KEY is required and must be readable for CBT payload proof' >&2; return 2; }
  [[ -n $SSH_PUBLIC_KEY ]] || { echo 'ERROR: SSH_PUBLIC_KEY is required for the disposable proof VM' >&2; return 2; }

  stamp=$(date -u +%y%m%d%H%M%S)
  proof_namespace="cbt-proof-$stamp"
  NAMESPACE=$proof_namespace
  VM_PREFIX=cbt-proof-vm
  VM_COUNT=1
  if oc get namespace "$NAMESPACE" >/dev/null 2>&1; then
    echo "ERROR: proof namespace already exists: $NAMESPACE" >&2
    return 1
  fi

  start_report cbt-payload-proof
  proof_report_started=1
  proof_report_done=0
  trap proof_cleanup EXIT
  density_setup
  vm=${selected[0]}
  full_name="$vm-full"
  inc_name="$vm-incremental"
  control_name="$vm-control-full"
  seed_bytes=$((256*1024*1024))
  wait_for_proof_guest_ssh "$vm"

  disk_bytes=$(proof_guest_command "$vm" \
    "sudo -n sh -c 'if command -v cloud-init >/dev/null 2>&1; then timeout ${TIMEOUT}s cloud-init status --wait >/dev/null 2>&1 || true; fi; if command -v systemctl >/dev/null 2>&1; then systemctl disable --now vm-validator.service >/dev/null 2>&1 || true; fi; if command -v pkill >/dev/null 2>&1; then pkill -f \"[v]m-validator.py\" >/dev/null 2>&1 || true; fi; sync; if mountpoint -q /data; then umount /data || exit 1; fi; blockdev --getsize64 /dev/vdc'")
  [[ $disk_bytes =~ ^[0-9]+$ && $disk_bytes -ge $((2*1024*1024*1024)) ]] || {
    echo "ERROR: proof needs a data disk of at least 2GiB; got ${disk_bytes:-no size}" >&2
    return 1
  }
  proof_guest_command "$vm" \
    "sudo -n dd if=/dev/urandom of=/dev/vdc bs=1M count=128 seek=0 conv=notrunc,fdatasync 2>/dev/null && sudo -n dd if=/dev/urandom of=/dev/vdc bs=1M count=128 seek=512 conv=notrunc,fdatasync 2>/dev/null && echo CBT_PROOF_SEEDED"
  backup_one "$vm" "$full_name"

  proof_guest_command "$vm" \
    "sudo -n python3 -c 'import os; fd=os.open(\"/dev/vdc\", os.O_WRONLY); n=os.pwrite(fd, bytes([165])*4194304, 1073741824); os.fsync(fd); os.close(fd); assert n == 4194304' && echo CBT_PROOF_CHANGED"
  cbt_one "$vm" "$inc_name"
  backup_force_full_one "$vm" "$control_name"

  launcher=$(oc get pods -n "$NAMESPACE" -o json | jq -er --arg prefix "virt-launcher-$vm-" \
    '[.items[] | select(.metadata.name | startswith($prefix)) | .metadata.name][0]')
  launcher_json=$(oc get pod "$launcher" -n "$NAMESPACE" -o json)
  launcher_node=$(jq -er '.spec.nodeName' <<<"$launcher_json")
  state_claim=$(jq -er '.spec.volumes[] | select(.name=="vm-state") | .persistentVolumeClaim.claimName' <<<"$launcher_json")
  image=$(jq -er '.spec.containers[] | select(.name=="compute") | .image' <<<"$launcher_json")
  pod=cbt-payload-inspector
  cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: $pod
  namespace: $NAMESPACE
spec:
  nodeName: $launcher_node
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 107
    runAsGroup: 107
    seccompProfile: {type: RuntimeDefault}
  containers:
  - name: inspect
    image: "$image"
    command: ["/bin/sh", "-c", "sleep 3600"]
    securityContext:
      allowPrivilegeEscalation: false
      capabilities: {drop: ["ALL"]}
    volumeMounts:
    - {name: backup, mountPath: /proof, readOnly: true}
    - {name: launcher-state, mountPath: /var/run/kubevirt-private/libvirt/qemu/cbt, subPath: cbt, readOnly: true}
    - {name: data, mountPath: /var/run/kubevirt-private/vmi-disks/datadisk, readOnly: true}
  volumes:
  - name: backup
    persistentVolumeClaim: {claimName: $vm-backup-output}
  - name: launcher-state
    persistentVolumeClaim: {claimName: $state_claim}
  - name: data
    persistentVolumeClaim: {claimName: $vm-data}
EOF
  oc wait --for=condition=Ready "pod/$pod" -n "$NAMESPACE" --timeout="${TIMEOUT}s"

  inspect_root=/proof
  full_checkpoint=$(oc get virtualmachinebackup "$full_name" -n "$NAMESPACE" -o json | jq -er '.status.checkpointName')
  inc_checkpoint=$(oc get virtualmachinebackup "$inc_name" -n "$NAMESPACE" -o json | jq -er '.status.checkpointName')
  control_checkpoint=$(oc get virtualmachinebackup "$control_name" -n "$NAMESPACE" -o json | jq -er '.status.checkpointName')
  full_path="$inspect_root/$vm/$full_checkpoint/$full_name-datadisk.qcow2"
  inc_path="$inspect_root/$vm/$inc_checkpoint/$inc_name-datadisk.qcow2"
  control_path="$inspect_root/$vm/$control_checkpoint/$control_name-datadisk.qcow2"
  full_map=$(oc exec -n "$NAMESPACE" "$pod" -c inspect -- qemu-img map --force-share --output=json "$full_path")
  inc_map=$(oc exec -n "$NAMESPACE" "$pod" -c inspect -- qemu-img map --force-share --output=json "$inc_path")
  control_map=$(oc exec -n "$NAMESPACE" "$pod" -c inspect -- qemu-img map --force-share --output=json "$control_path")
  mkdir -p "$run_dir/evidence"
  printf '%s\n' "$full_map" >"$run_dir/evidence/$vm-full-map.json"
  printf '%s\n' "$inc_map" >"$run_dir/evidence/$vm-incremental-map.json"
  printf '%s\n' "$control_map" >"$run_dir/evidence/$vm-control-full-map.json"
  full_bytes=$(payload_data_bytes <<<"$full_map")
  inc_bytes=$(payload_data_bytes <<<"$inc_map")
  control_bytes=$(payload_data_bytes <<<"$control_map")
  full_seed_a=$(payload_range_data_bytes "$full_map" "$seed_a_start" "$seed_a_end")
  full_seed_b=$(payload_range_data_bytes "$full_map" "$seed_b_start" "$seed_b_end")

  ((full_seed_a * 10 >= (seed_a_end-seed_a_start) * 9 &&
    full_seed_b * 10 >= (seed_b_end-seed_b_start) * 9)) || {
    echo "ERROR: Full artifact did not materialize both seeded ranges: first=$full_seed_a second=$full_seed_b" >&2
    return 1
  }
  payload_has_nonzero_data_in_range "$inc_map" "$changed_start" "$changed_end" || {
    echo 'ERROR: Incremental artifact has no nonzero depth-0 extent in the canary range' >&2; return 1;
  }
  payload_has_nonzero_data_in_range "$control_map" "$changed_start" "$changed_end" || {
    echo 'ERROR: forced-Full control does not contain the nonzero canary extent' >&2; return 1;
  }
  if payload_has_data_in_range "$inc_map" "$seed_a_start" "$seed_a_end" ||
     payload_has_data_in_range "$inc_map" "$seed_b_start" "$seed_b_end"; then
    echo 'ERROR: Incremental artifact includes previously checkpointed seed ranges' >&2
    return 1
  fi
  ((inc_bytes > 0 && inc_bytes * 8 < full_bytes && control_bytes >= full_bytes)) || {
    echo "ERROR: payload sizes do not distinguish CBT from Full: full=$full_bytes incremental=$inc_bytes controlFull=$control_bytes" >&2
    return 1
  }

  jq -n --arg vm "$vm" --arg fullCheckpoint "$full_checkpoint" \
    --arg incrementalCheckpoint "$inc_checkpoint" --arg controlFullCheckpoint "$control_checkpoint" \
    --argjson seedBytes "$seed_bytes" --argjson changedOffset "$changed_start" \
    --argjson changedBytes "$((changed_end-changed_start))" --argjson fullDataBytes "$full_bytes" \
    --argjson incrementalDataBytes "$inc_bytes" --argjson controlFullDataBytes "$control_bytes" \
    --argjson seedADataBytes "$full_seed_a" --argjson seedBDataBytes "$full_seed_b" \
    '{vm:$vm,status:"PASS",message:"Incremental QCOW2 has a nonzero depth-0 canary extent, omits both seeded baseline ranges, and is materially smaller than a Full control",fullCheckpoint:$fullCheckpoint,incrementalCheckpoint:$incrementalCheckpoint,controlFullCheckpoint:$controlFullCheckpoint,seedBytes:$seedBytes,seedAAllocatedDataBytes:$seedADataBytes,seedBAllocatedDataBytes:$seedBDataBytes,changedOffsetBytes:$changedOffset,changedBytes:$changedBytes,fullAllocatedDataBytes:$fullDataBytes,incrementalAllocatedDataBytes:$incrementalDataBytes,controlFullAllocatedDataBytes:$controlFullDataBytes,incrementalIncludesSeedRanges:false,incrementalContainsNonzeroCanaryExtent:true,controlFullContainsNonzeroCanaryExtent:true}' \
    >"$run_dir/per-vm/$vm.json"
  ((passed+=1))
  echo "CBT payload proof PASS: Full=$full_bytes bytes, Incremental=$inc_bytes bytes, control Full=$control_bytes bytes"
  finish_report 0
  proof_report_done=1
}
case "$COMMAND" in
 help) usage;; generate-keys) generate_keys;; check-prereqs) check_prereqs;; density-setup) [[ ${ARGS[0]:-} == --count ]] && VM_COUNT=${ARGS[1]}; density_setup;; density-status) density_status;; density-teardown) density_teardown;; discover-vms) discover "${ARGS[@]}";; backup|cbt-backup|verify) run_selected "$COMMAND" "${ARGS[@]}";; cbt-payload-proof) cbt_payload_proof;; cbt-evidence) cbt_evidence_selected "${ARGS[@]}";; status) status_selected "${ARGS[@]}";; ssh) ssh_guest "${ARGS[@]}";; report) report;; list-reports) list_reports;; e2e) [[ ${ARGS[0]:-} == --count ]] && VM_COUNT=${ARGS[1]}; e2e "$VM_COUNT";; *) usage >&2; exit 2;; esac
