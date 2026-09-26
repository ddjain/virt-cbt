#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CONFIG=${CONFIG:-$ROOT/config.env}
COMMAND=help
ARGS=()
while (($#)); do case "$1" in --config) CONFIG=${2:?missing config}; shift 2;; -h|--help) COMMAND=help; shift;; *) COMMAND=$1; shift; ARGS+=("$@"); break;; esac; done
CONFIG_LOADED=0
load_config() {
  local line key value
  [[ -r $CONFIG ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    case "$line" in ''|\#*) continue;; esac
    [[ $line == *=* ]] || { echo "ERROR: invalid config line in $CONFIG: $line" >&2; return 2; }
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      KUBECONFIG|NAMESPACE|VM_COUNT|VM_PREFIX|VM_LABEL_SELECTOR|CONTAINER_IMAGE|VM_CPU|VM_MEMORY|DATA_SIZE|BACKUP_SIZE|DATA_STORAGE_CLASS|BACKUP_STORAGE_CLASS|TARGET_NODE|SSH_KEY|SSH_PUBLIC_KEY|SSH_USER|TIMEOUT|STABILIZE_TIMEOUT|CBT_CHANGE_WAIT|REPORTS_DIR|RESTORE_PROOF_BASE_MIB|RESTORE_PROOF_APPEND_MIB|CBT_DIAGNOSTICS|CBT_DIAGNOSTICS_DEPTH) ;;
      *) echo "ERROR: unsupported config key in $CONFIG: $key" >&2; return 2;;
    esac
    printf -v "$key" '%s' "$value"
  done <"$CONFIG"
  CONFIG_LOADED=1
}
load_config || exit $?
: "${NAMESPACE:=cbt-demo}"; : "${VM_COUNT:=1}"; : "${VM_PREFIX:=fedora-cbt}"; : "${VM_LABEL_SELECTOR:=app.kubernetes.io/name=odf-cbt-validator}"
: "${CONTAINER_IMAGE:=quay.io/containerdisks/fedora:41}"; : "${VM_CPU:=1}"; : "${VM_MEMORY:=1Gi}"; : "${DATA_SIZE:=10Gi}"; : "${BACKUP_SIZE:=20Gi}"
: "${DATA_STORAGE_CLASS:=ocs-storagecluster-ceph-rbd}"; : "${BACKUP_STORAGE_CLASS:=$DATA_STORAGE_CLASS}"; : "${TARGET_NODE:=}"
: "${SSH_KEY:=}"; : "${SSH_PUBLIC_KEY:=}"; : "${SSH_USER:=fedora}"; : "${TIMEOUT:=600}"; : "${STABILIZE_TIMEOUT:=300}"; : "${CBT_CHANGE_WAIT:=5}"; : "${REPORTS_DIR:=reports}"
: "${RESTORE_PROOF_BASE_MIB:=512}"; : "${RESTORE_PROOF_APPEND_MIB:=128}"
: "${CBT_DIAGNOSTICS:=1}"; : "${CBT_DIAGNOSTICS_DEPTH:=core}"
export KUBECONFIG=${KUBECONFIG:-}
if [[ -z $SSH_PUBLIC_KEY && -n $SSH_KEY && -r $SSH_KEY.pub ]]; then SSH_PUBLIC_KEY=$(<"$SSH_KEY.pub"); fi

usage() { cat <<'EOF'
Usage: odf-vm-validator.sh [--config FILE] COMMAND [options]
Commands: generate-keys check-prereqs density-setup density-status density-teardown[--all] discover-vms backup cbt-backup backup-reset cbt-cycle cbt-payload-proof cbt-restore-proof cbt-evidence cbt-diagnostics verify status ssh report list-reports e2e
Selection options: --vms CSV | --count N | --selector key=value | --all
EOF
}
need() { command -v "$1" >/dev/null || { echo "ERROR: $1 is required" >&2; return 127; }; }
log() {
  local level=$1 phase=$2; shift 2
  printf '[%s] [%s] [%s] %s\n' "$(date -u +%H:%M:%S)" "$level" "$phase" "$*"
}
require_runtime_config() {
  [[ ${BASH_VERSINFO[0]} -ge 4 ]] || { echo 'ERROR: bash 4+ is required' >&2; return 2; }
  [[ $CONFIG_LOADED == 1 ]] || { echo "ERROR: configuration file is required for cluster operations: $CONFIG" >&2; return 2; }
  [[ -n $KUBECONFIG && -r $KUBECONFIG ]] || { echo "ERROR: KUBECONFIG must name a readable file in $CONFIG" >&2; return 2; }
  [[ $TIMEOUT =~ ^[1-9][0-9]*$ && $STABILIZE_TIMEOUT =~ ^[1-9][0-9]*$ && $CBT_CHANGE_WAIT =~ ^[0-9]+$ ]] || {
    echo 'ERROR: TIMEOUT and STABILIZE_TIMEOUT must be positive integers; CBT_CHANGE_WAIT must be non-negative' >&2
    return 2
  }
}
run_id=''; test_id=''; run_dir=''; report_command=''; selected=(); passed=0; failed=0; inconclusive=0
start_report() {
  local cmd=$1
  report_command=$cmd
  test_id="cbt-$(date -u +%Y%m%dT%H%M%SZ)-$$-$RANDOM"
  run_id="run-${test_id}-$cmd"
  run_dir="$REPORTS_DIR/$run_id"
  mkdir -p "$run_dir/per-vm" "$run_dir/diagnostics" || return
  : >"$run_dir/run.log" || return
  exec > >(tee -a "$run_dir/run.log") 2>&1
  started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  passed=0; failed=0; inconclusive=0
  log INFO REPORT "Started $run_id (test-id=$test_id)"
}
write_summary_txt() {
  local status=$1
  cat >"$run_dir/summary.txt" <<EOF
Test Summary
------------
Run:          $run_id
Command:      $report_command
Namespace:    $NAMESPACE
Status:       $status
Passed:       $passed
Failed:       $failed
Inconclusive: $inconclusive
Selected:     ${#selected[@]}
Started:      $started
Completed:    $completed
Results:      $run_dir/
EOF
}
finish_report() {
  local status=$1
  completed=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq -n \
    --arg id "$run_id" --arg c "$report_command" --arg ns "$NAMESPACE" \
    --arg s "$started" --arg e "$completed" \
    --argjson sel "$(printf '%s\n' "${selected[@]}" | jq -Rsc 'split("\n")|map(select(length>0))')" \
    --argjson p "$passed" --argjson f "$failed" --argjson i "$inconclusive" \
    --argjson r "$(jq -s '.' "$run_dir/per-vm"/*.json 2>/dev/null || echo '[]')" \
    '{runId:$id,command:$c,namespace:$ns,startedAt:$s,completedAt:$e,selected:$sel,passed:$p,failed:$f,inconclusive:$i,results:$r}' \
    >"$run_dir/summary.json"
  write_summary_txt "$([[ $status -eq 0 ]] && echo OK || echo FAILED)"
  log INFO REPORT "Report: $run_dir/summary.json"
  cat "$run_dir/summary.txt"
  return "$status"
}
parse_selection() {
  local mode='' value='' x sel_out='' sel_rc=0
  while (($#)); do
    case "$1" in
      --vms|--count|--selector)
        [[ -z $mode ]] || { echo 'ERROR: specify exactly one of VMS, N, SELECTOR, or ALL=1' >&2; return 2; }
        mode=${1#--}; value=${2-}; shift 2;;
      --all)
        [[ -z $mode ]] || { echo 'ERROR: specify exactly one of VMS, N, SELECTOR, or ALL=1' >&2; return 2; }
        mode=all; shift;;
      *) echo "ERROR: unknown option $1" >&2; return 2;;
    esac
  done
  [[ -n $mode ]] || { echo 'ERROR: specify exactly one of VMS, N, SELECTOR, or ALL=1' >&2; return 2; }
  selected=()
  # Capture helper output + exit status. Process substitution would swallow a
  # non-zero exit after partial stdout and let callers act on a bad subset.
  if [[ $mode == all ]]; then
    sel_out=$("$ROOT/scripts/select-vms.sh" --kubeconfig "$KUBECONFIG" --namespace "$NAMESPACE" --base-selector "$VM_LABEL_SELECTOR" --all) || sel_rc=$?
  else
    sel_out=$("$ROOT/scripts/select-vms.sh" --kubeconfig "$KUBECONFIG" --namespace "$NAMESPACE" --base-selector "$VM_LABEL_SELECTOR" "--$mode" "$value") || sel_rc=$?
  fi
  (( sel_rc == 0 )) || return "$sel_rc"
  while IFS= read -r x; do [[ -n $x ]] && selected+=("$x"); done <<<"$sel_out"
  ((${#selected[@]})) || { echo 'ERROR: selection matched no managed VMs' >&2; return 1; }
  for x in "${selected[@]}"; do assert_owned_vm "$x" || return; done
}
record() {
  local vm=$1 status=$2 message=$3
  jq -n --arg vm "$vm" --arg st "$status" --arg msg "$message" \
    '{vm:$vm,status:$st,message:$msg}' >"$run_dir/per-vm/$vm.json"
  case "$status" in
    PASS) ((passed+=1));;
    INCONCLUSIVE) ((inconclusive+=1));;
    *) ((failed+=1));;
  esac
  log INFO RESULT "$vm $status — $message"
}
assert_owned_namespace() {
  local owned
  owned=$(oc get namespace "$NAMESPACE" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || true)
  [[ $owned == odf-cbt-validator ]] || {
    echo "ERROR: refusing unowned namespace $NAMESPACE (managed-by='$owned')" >&2
    return 1
  }
}
assert_owned_vm() {
  local vm=$1
  oc get vm "$vm" -n "$NAMESPACE" -o json |
    jq -e '
      .metadata.labels["app.kubernetes.io/name"] == "odf-cbt-validator" and
      .metadata.labels["app.kubernetes.io/managed-by"] == "kube-burner"
    ' >/dev/null || {
      echo "ERROR: refusing VM/$vm because it is not kube-burner-managed by this validator" >&2
      return 1
    }
}
acquire_vm_lock() {
  local vm=$1 lock="${vm}-cbt-lock"
  oc create configmap "$lock" -n "$NAMESPACE" \
    --from-literal=test-id="$test_id" \
    --from-literal=owner="$$" \
    --labels=app.kubernetes.io/name=odf-cbt-validator,app.kubernetes.io/managed-by=odf-cbt-validator \
    >/dev/null || {
      echo "ERROR: VM/$vm is already locked by another validator run ($lock)" >&2
      return 1
    }
}
release_vm_lock() {
  local vm=$1 lock="${vm}-cbt-lock"
  oc delete configmap "$lock" -n "$NAMESPACE" --ignore-not-found --wait=true --timeout="${TIMEOUT}s" >/dev/null
}
virt_launcher_image() {
  # Prefer the named VM's virt-launcher compute image; fall back to any
  # virt-launcher in the same namespace (never cluster-wide -A).
  # jq's `[...][0]` yields JSON null (text "null") on empty match; use // empty.
  local vm=${1:-} image=''
  if [[ -n $vm ]]; then
    image=$(oc get pods -n "$NAMESPACE" -o json 2>/dev/null | jq -r --arg prefix "virt-launcher-$vm-" \
      '([.items[] | select(.metadata.name | startswith($prefix)) | .spec.containers[] | select(.name=="compute") | .image][0] // empty)' 2>/dev/null) || true
  fi
  if [[ -z ${image:-} || $image == null ]]; then
    image=$(oc get pods -n "$NAMESPACE" -o json 2>/dev/null | jq -r \
      '([.items[] | select(.metadata.name | startswith("virt-launcher-")) | .spec.containers[] | select(.name=="compute") | .image][0] // empty)' 2>/dev/null) || true
  fi
  [[ -n ${image:-} && $image != null ]] || {
    echo "ERROR: no virt-launcher pod in namespace $NAMESPACE to source a qemu-img-capable image" >&2
    return 1
  }
  printf '%s' "$image"
}
# Scalar checkpoint name from either API shape (string or {name,...} object).
tracker_checkpoint_name() {
  local tracker=$1
  oc get virtualmachinebackuptracker "$tracker" -n "$NAMESPACE" -o json 2>/dev/null |
    jq -r '(.status.latestCheckpoint
      | if type=="object" then .name
        elif type=="string" then .
        else empty end) // .status.checkpointName // empty' 2>/dev/null || true
}
# Ephemeral guest SSH: never persist host keys into the operator's known_hosts.
# virtctl defaults to ~/.ssh/kubevirt_known_hosts; local OpenSSH with
# StrictHostKeyChecking=no would also write ~/.ssh/known_hosts unless redirected.
guest_ssh() {
  local vm=$1; shift
  local command=${1-} kh rc=0
  [[ -n $SSH_KEY ]] || { echo 'ERROR: SSH_KEY is required' >&2; return 2; }
  kh=$(mktemp "${TMPDIR:-/tmp}/cbt-known-hosts.XXXXXX") || return 1
  virtctl ssh -n "$NAMESPACE" -i "$SSH_KEY" --known-hosts="$kh" \
    --local-ssh-opts="-o StrictHostKeyChecking=no" \
    --local-ssh-opts="-o UserKnownHostsFile=$kh" \
    --local-ssh-opts="-o GlobalKnownHostsFile=/dev/null" \
    --local-ssh-opts="-o UpdateHostKeys=no" \
    --local-ssh-opts="-o ConnectTimeout=15" \
    --local-ssh-opts="-o ServerAliveInterval=10" \
    --local-ssh-opts="-o ServerAliveCountMax=3" \
    "$SSH_USER@vm/$vm" --command "${command:-hostname}" || rc=$?
  rm -f "$kh"
  return "$rc"
}
check_prereqs() {
  for t in oc virtctl kube-burner jq; do need "$t" || return; done
  [[ -r ${KUBECONFIG:-/dev/null} || -z ${KUBECONFIG:-} ]] || { echo "ERROR: kubeconfig is unreadable: $KUBECONFIG"; return 1; }
  oc get crd virtualmachines.kubevirt.io virtualmachinebackups.backup.kubevirt.io virtualmachinebackuptrackers.backup.kubevirt.io >/dev/null
  oc get storageclass "$DATA_STORAGE_CLASS" "$BACKUP_STORAGE_CLASS" >/dev/null
  oc get storagecluster,cephcluster -n openshift-storage >/dev/null
  oc get volumesnapshotclass -o json | jq -e '.items|length>0' >/dev/null
  oc get hyperconverged -A -o json | jq -e '
    any(.. | objects;
      has("changedBlockTrackingLabelSelectors") or
      has("changedBlockTracking")
    )
  ' >/dev/null || {
    echo 'ERROR: HyperConverged CBT is not configured (need changedBlockTrackingLabelSelectors or changedBlockTracking)' >&2
    return 1
  }
  [[ -n $SSH_KEY && -r $SSH_KEY && -r "$SSH_KEY.pub" ]] || echo 'WARNING: SSH_KEY pair not configured; guest checks will fail'
  echo 'Prerequisites OK'
}
generate_keys() { [[ -n $SSH_KEY ]] || SSH_KEY="$ROOT/keys/cbt-validator"; mkdir -p "$(dirname "$SSH_KEY")"; if [[ ! -r $SSH_KEY ]]; then ssh-keygen -q -t ed25519 -N '' -f "$SSH_KEY"; fi; SSH_PUBLIC_KEY=$(<"$SSH_KEY.pub"); echo "SSH key: $SSH_KEY"; }
render_job() { local out=$1; sed -e "s|REPLACE_NAMESPACE|$NAMESPACE|g" -e "s|REPLACE_REPLICAS|$VM_COUNT|g" -e "s|REPLACE_VM_PREFIX|$VM_PREFIX|g" -e "s|REPLACE_CONTAINER_IMAGE|$CONTAINER_IMAGE|g" -e "s|REPLACE_SSH_USER|$SSH_USER|g" -e "s|REPLACE_SSH_PUBLIC_KEY|$SSH_PUBLIC_KEY|g" -e "s|REPLACE_VM_CPU|$VM_CPU|g" -e "s|REPLACE_VM_MEMORY|$VM_MEMORY|g" -e "s|REPLACE_DATA_SIZE|$DATA_SIZE|g" -e "s|REPLACE_BACKUP_SIZE|$BACKUP_SIZE|g" -e "s|REPLACE_DATA_STORAGE_CLASS|$DATA_STORAGE_CLASS|g" -e "s|REPLACE_BACKUP_STORAGE_CLASS|$BACKUP_STORAGE_CLASS|g" -e "s|REPLACE_TARGET_NODE|$TARGET_NODE|g" -e "s|REPLACE_MARKER_BASE_MIB|$RESTORE_PROOF_BASE_MIB|g" "$ROOT/kube-burner/odf-cbt-density.yml" >"$out"; }
density_setup() {
  [[ $VM_COUNT =~ ^[1-9][0-9]*$ ]] || { echo 'ERROR: VM_COUNT must be positive'; return 2; }
  local existing
  existing=$(oc get namespace "$NAMESPACE" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || true)
  if oc get namespace "$NAMESPACE" >/dev/null 2>&1; then
    [[ $existing == odf-cbt-validator ]] || { echo "ERROR: namespace $NAMESPACE is not utility-owned"; return 1; }
  else
    oc create namespace "$NAMESPACE"
    oc label namespace "$NAMESPACE" app.kubernetes.io/managed-by=odf-cbt-validator --overwrite
  fi
  if oc get vm -n "$NAMESPACE" -l "$VM_LABEL_SELECTOR" -o name | grep -q .; then
    echo 'ERROR: managed VM pool already exists; teardown first' >&2
    return 1
  fi
  local job
  mkdir -p "$ROOT/kube-burner/rendered"
  # Darwin mktemp requires ≥6 trailing X chars and does not treat a .yml suffix
  # as separate from the template — density.XXXX.yml becomes the literal name.
  job=$(mktemp "$ROOT/kube-burner/rendered/density.XXXXXX")
  if ! render_job "$job" || ! (cd "$ROOT/kube-burner" && kube-burner init --config "rendered/$(basename "$job")" --kubeconfig "$KUBECONFIG" --log-level error); then
    rm -f "$job"
    return 1
  fi
  rm -f "$job"
  wait_pool
}
wait_pool() {
  local deadline=$((SECONDS+STABILIZE_TIMEOUT)) count=0 ready=0 x
  log INFO SETUP "Waiting for $VM_COUNT VMs ready+CBT (stabilize=${STABILIZE_TIMEOUT}s)"
  while ((SECONDS<deadline)); do
    count=$(oc get vm -n "$NAMESPACE" -l "$VM_LABEL_SELECTOR" -o json | jq '.items|length')
    ready=$(oc get vm -n "$NAMESPACE" -l "$VM_LABEL_SELECTOR" -o json |
      jq '[.items[]|select(.status.ready==true and .status.changedBlockTracking.state=="Enabled")]|length')
    if [[ $count == "$VM_COUNT" && $ready == "$VM_COUNT" ]]; then
      log INFO SETUP "Pool ready: count=$count cbtEnabled=$ready"
      break
    fi
    log INFO SETUP "Waiting for pool… count=$count ready+cbt=$ready want=$VM_COUNT elapsed=$((SECONDS-(deadline-STABILIZE_TIMEOUT)))s"
    sleep 5
  done
  if [[ $count != "$VM_COUNT" || $ready != "$VM_COUNT" ]]; then
    echo "ERROR: VM pool did not become ready within ${STABILIZE_TIMEOUT}s (count=$count ready+cbt=$ready want=$VM_COUNT)" >&2
    return 1
  fi
  selected=()
  while IFS= read -r x; do selected+=("$x"); done < <("$ROOT/scripts/select-vms.sh" --kubeconfig "$KUBECONFIG" --namespace "$NAMESPACE" --base-selector "$VM_LABEL_SELECTOR" --count "$VM_COUNT")
  ((${#selected[@]} == VM_COUNT)) || { echo 'ERROR: VM pool selection mismatch after ready' >&2; return 1; }
  for vm in "${selected[@]}"; do
    oc wait --for=jsonpath='{.status.ready}'=true vm/"$vm" -n "$NAMESPACE" --timeout="${TIMEOUT}s"
    oc wait --for=jsonpath='{.status.phase}'=Running vmi/"$vm" -n "$NAMESPACE" --timeout="${TIMEOUT}s"
  done
}
density_status() {
  if [[ ${COUNT_ONLY:-} == 1 ]]; then
    oc get vm -n "$NAMESPACE" -l "$VM_LABEL_SELECTOR" -o json | jq '.items|length'
  elif [[ ${SUMMARY:-} == 1 ]]; then
    oc get vm -n "$NAMESPACE" -l "$VM_LABEL_SELECTOR" -o json |
      jq '{count:(.items|length),ready:([.items[]|select(.status.ready==true)]|length),cbtEnabled:([.items[]|select(.status.changedBlockTracking.state=="Enabled")]|length)}'
  else
    oc get vm,vmi,pvc,virtualmachinebackuptracker -n "$NAMESPACE" -l "$VM_LABEL_SELECTOR" -o wide
  fi
}
density_teardown() {
  local mode='' ns owned pending=() failed=0
  while (($#)); do case "$1" in
    --all) [[ -z $mode ]] || { echo 'ERROR: density-teardown accepts at most --all' >&2; return 2; }; mode=all; shift;;
    *) echo "ERROR: unknown density-teardown option: $1" >&2; return 2;;
  esac; done
  if [[ $mode == all ]]; then
    if [[ ${CONFIRM:-} != 1 ]]; then
      echo 'ERROR: density-teardown --all requires CONFIRM=1 (deletes every utility-owned namespace)' >&2
      return 2
    fi
    while IFS= read -r ns; do pending+=("$ns"); done < <(
      oc get namespace -l app.kubernetes.io/managed-by=odf-cbt-validator -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null
    )
    if ((${#pending[@]} == 0)); then
      echo 'No utility-owned namespaces to tear down'
      return 0
    fi
    printf 'Tearing down %s utility-owned namespace(s): %s\n' "${#pending[@]}" "${pending[*]}"
    for ns in "${pending[@]}"; do
      owned=$(oc get namespace "$ns" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || true)
      if [[ $owned != odf-cbt-validator ]]; then
        echo "ERROR: refusing unowned namespace $ns" >&2
        failed=1
        continue
      fi
      oc delete namespace "$ns" --wait=true --timeout="${TIMEOUT}s" || failed=1
    done
    return "$failed"
  fi
  assert_owned_namespace || return 1
  oc delete namespace "$NAMESPACE" --wait=true --timeout="${TIMEOUT}s"
}
discover() { if (($#==0)); then set -- --all; fi; parse_selection "$@"; if [[ ${COUNT_ONLY:-} == 1 ]]; then printf '%s\n' "${#selected[@]}"; else printf '%s\n' "${selected[@]}"; fi; }
wait_backup() {
  # Synchronization barrier only: waits for Done/Complete/Failed. Does NOT
  # assert .status.type — use cbt_backup_evidence for Full-vs-Incremental.
  local vm=$1 name=$2
  local deadline=$((SECONDS + TIMEOUT)) vmb_json=''
  log INFO BACKUP "Waiting for VirtualMachineBackup/$name terminal (timeout=${TIMEOUT}s)"
  while ((SECONDS < deadline)); do
    if vmb_json=$(oc get virtualmachinebackup "$name" -n "$NAMESPACE" -o json 2>/dev/null); then
      if jq -e '(.status.conditions // []) | any(.[]; (.type == "Failed") and .status == "True")' >/dev/null <<<"$vmb_json"; then
        echo "ERROR: VirtualMachineBackup/$name Failed" >&2
        jq '{name:.metadata.name,type:.status.type,conditions:.status.conditions,checkpointName:.status.checkpointName}' <<<"$vmb_json" >&2 || true
        oc get events -n "$NAMESPACE" --field-selector "involvedObject.name=$name" --sort-by='.lastTimestamp' 2>/dev/null | tail -n 20 >&2 || true
        return 1
      fi
      if jq -e '(.status.conditions // []) | any(.[]; (.type == "Done" or .type == "Complete") and .status == "True")' >/dev/null <<<"$vmb_json"; then
        log INFO BACKUP "VirtualMachineBackup/$name reached Done/Complete"
        return 0
      fi
    fi
    sleep 5
  done
  echo "ERROR: VirtualMachineBackup/$name did not reach a terminal condition within ${TIMEOUT}s" >&2
  oc get virtualmachinebackup "$name" -n "$NAMESPACE" -o json 2>/dev/null |
    jq '{name:.metadata.name,type:.status.type,conditions:.status.conditions}' >&2 || true
  return 1
}
# Best-effort forensic dump around one VMB. Never affects pass/fail.
collect_backup_diagnostics() {
  local vm=$1 name=$2 since_time=$3 baseline_json=${4:-}
  local out_dir args=()
  [[ ${CBT_DIAGNOSTICS:-1} != 0 ]] || return 0
  [[ -n ${run_dir:-} ]] || return 0
  out_dir="$run_dir/diagnostics/$vm/$name"
  mkdir -p "$out_dir"
  args=(
    --namespace "$NAMESPACE"
    --vm "$vm"
    --backup "$name"
    --out-dir "$out_dir"
    --depth "${CBT_DIAGNOSTICS_DEPTH:-core}"
    --tracker "$vm-tracker"
  )
  [[ -n $since_time ]] && args+=(--since-time "$since_time")
  [[ -n $baseline_json && -r $baseline_json ]] && args+=(--baseline-json "$baseline_json")
  log INFO DIAG "Collecting CBT diagnostics → $out_dir"
  "$ROOT/scripts/cbt-diagnostics-collect.sh" "${args[@]}" || \
    log WARN DIAG "Diagnostics collection returned non-zero (ignored)"
}
write_backup_baseline() {
  # Lightweight pre-apply snapshot for the diagnostics manifest.
  # Best-effort: never fails the backup path. Avoids --argjson + shell-captured
  # JSON (pretty-printed/multiline captures were producing "invalid JSON text").
  local vm=$1 tracker=$2 out=$3
  local checkpoint
  checkpoint=$(tracker_checkpoint_name "$tracker")
  if ! oc get vmi "$vm" -n "$NAMESPACE" -o json 2>/dev/null |
      jq -c --arg vm "$vm" --arg tracker "$tracker" --arg checkpoint "$checkpoint" \
        --arg captured "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{vm:$vm,tracker:$tracker,latestCheckpoint:$checkpoint,capturedAt:$captured,
          vmi:{phase:.status.phase,node:.status.nodeName,cbt:.status.changedBlockTracking}}' \
        >"$out" 2>/dev/null; then
    jq -nc --arg vm "$vm" --arg tracker "$tracker" --arg checkpoint "$checkpoint" \
      --arg captured "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{vm:$vm,tracker:$tracker,latestCheckpoint:$checkpoint,capturedAt:$captured,vmi:{}}' \
      >"$out" 2>/dev/null || printf '%s\n' '{}' >"$out"
  fi
  return 0
}
assert_backup_inputs() {
  local vm=$1 tracker="$vm-tracker" pvc="$vm-backup-output"
  assert_owned_namespace || return
  assert_owned_vm "$vm" || return
  oc get virtualmachinebackuptracker "$tracker" -n "$NAMESPACE" -o json |
    jq -e --arg vm "$vm" '
      .metadata.labels["app.kubernetes.io/name"] == "odf-cbt-validator" and
      .metadata.labels["app.kubernetes.io/managed-by"] == "kube-burner" and
      .spec.source.apiGroup == "kubevirt.io" and
      .spec.source.kind == "VirtualMachine" and
      .spec.source.name == $vm
    ' >/dev/null || { echo "ERROR: tracker/$tracker is not the expected managed source for $vm" >&2; return 1; }
  oc get pvc "$pvc" -n "$NAMESPACE" -o json |
    jq -e '
      .metadata.labels["app.kubernetes.io/name"] == "odf-cbt-validator" and
      .metadata.labels["app.kubernetes.io/managed-by"] == "kube-burner" and
      .status.phase == "Bound"
    ' >/dev/null || { echo "ERROR: PVC/$pvc is not the expected managed Bound backup target" >&2; return 1; }
}
create_backup_request() {
  local vm=$1 name=$2 force_full=${3:-false}
  local tracker="$vm-tracker" pvc="$vm-backup-output" uid force_full_yaml=''
  [[ -n $test_id ]] || { echo 'ERROR: backup requests require an active test report' >&2; return 1; }
  assert_backup_inputs "$vm" || return
  oc delete virtualmachinebackup "$name" -n "$NAMESPACE" --ignore-not-found --wait=true --timeout="${TIMEOUT}s" || return
  [[ $force_full == true ]] && force_full_yaml='  forceFullBackup: true'
  cat <<EOF | oc apply -f - >/dev/null || return
apiVersion: backup.kubevirt.io/v1alpha1
kind: VirtualMachineBackup
metadata:
  name: $name
  namespace: $NAMESPACE
  labels:
    app.kubernetes.io/name: odf-cbt-validator
    app.kubernetes.io/managed-by: kube-burner
    odf-cbt-validator/test-id: $test_id
  annotations:
    odf-cbt-validator/source-vm-uid: $(oc get vm "$vm" -n "$NAMESPACE" -o jsonpath='{.metadata.uid}')
spec:
  source: {apiGroup: backup.kubevirt.io, kind: VirtualMachineBackupTracker, name: $tracker}
  mode: Push
  pvcName: $pvc
$force_full_yaml
  skipQuiesce: true
EOF
  uid=$(oc get virtualmachinebackup "$name" -n "$NAMESPACE" -o json |
    jq -er --arg vm "$vm" --arg tracker "$tracker" --arg pvc "$pvc" --arg test_id "$test_id" '
      select(.metadata.labels["odf-cbt-validator/test-id"] == $test_id) |
      select(.spec.source.apiGroup == "backup.kubevirt.io" and .spec.source.kind == "VirtualMachineBackupTracker" and .spec.source.name == $tracker) |
      select(.spec.mode == "Push" and .spec.pvcName == $pvc) |
      select(.metadata.annotations["odf-cbt-validator/source-vm-uid"] != null) |
      .metadata.uid
    ') || { echo "ERROR: VirtualMachineBackup/$name does not match the requested source, PVC, or test identity" >&2; return 1; }
  [[ -n $uid ]] || { echo "ERROR: VirtualMachineBackup/$name has no UID" >&2; return 1; }
  printf '%s\n' "$uid"
}
backup_one() {
  local vm=$1 name=$2 tracker="$vm-tracker" checkpoint t0 baseline uid wait_rc=0
  checkpoint=$(tracker_checkpoint_name "$tracker")
  [[ -z $checkpoint ]] || { echo "ERROR: full backup already exists for $vm; use cbt-backup or recreate density" >&2; return 1; }
  t0=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  baseline=$(mktemp) || return
  write_backup_baseline "$vm" "$tracker" "$baseline" || { rm -f "$baseline"; return 1; }
  uid=$(create_backup_request "$vm" "$name") || { rm -f "$baseline"; return 1; }
  wait_backup "$vm" "$name" || wait_rc=$?
  collect_backup_diagnostics "$vm" "$name" "$t0" "$baseline"
  rm -f "$baseline"
  ((wait_rc == 0)) || return "$wait_rc"
  cbt_backup_evidence "$vm" "$name" Full "$uid"
}
cbt_one() {
  local vm=$1 name=$2 tracker="$vm-tracker" before after t0 baseline uid wait_rc=0
  assert_backup_inputs "$vm" || return
  oc get virtualmachinebackup "$vm-full" -n "$NAMESPACE" >/dev/null || return
  before=$(tracker_checkpoint_name "$tracker")
  [[ -n $before ]] || { echo "ERROR: no full checkpoint for $vm" >&2; return 1; }
  t0=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  baseline=$(mktemp) || return
  write_backup_baseline "$vm" "$tracker" "$baseline" || { rm -f "$baseline"; return 1; }
  uid=$(create_backup_request "$vm" "$name") || { rm -f "$baseline"; return 1; }
  wait_backup "$vm" "$name" || wait_rc=$?
  collect_backup_diagnostics "$vm" "$name" "$t0" "$baseline"
  rm -f "$baseline"
  ((wait_rc == 0)) || return "$wait_rc"
  after=$(tracker_checkpoint_name "$tracker")
  [[ -n $after && $after != "$before" ]] || {
    echo "ERROR: tracker/$tracker did not advance after Incremental backup (before=$before after=${after:-empty})" >&2
    return 1
  }
  cbt_backup_evidence "$vm" "$name" Incremental "$uid"
}
backup_reset_one() {
  # Clear Push-mode backup artifacts for one VM so a fresh Full can run again.
  # Keeps the VM, data PVC, guest files, and live CBT overlay untouched.
  local vm=$1
  local tracker="$vm-tracker" pvc="$vm-backup-output"
  assert_owned_namespace || return
  assert_owned_vm "$vm" || return
  log INFO RESET "Clearing backups/tracker/backup-output for $vm"
  oc delete virtualmachinebackup "$vm-full" "$vm-incremental" -n "$NAMESPACE" \
    --ignore-not-found --wait=true --timeout="${TIMEOUT}s" || return
  oc delete virtualmachinebackuptracker "$tracker" -n "$NAMESPACE" \
    --ignore-not-found --wait=true --timeout="${TIMEOUT}s" || return
  oc delete pvc "$pvc" -n "$NAMESPACE" --ignore-not-found --wait=true --timeout="${TIMEOUT}s" || return
  cat <<EOF | oc apply -f - >/dev/null || return
apiVersion: backup.kubevirt.io/v1alpha1
kind: VirtualMachineBackupTracker
metadata:
  name: $tracker
  namespace: $NAMESPACE
  labels:
    app.kubernetes.io/name: odf-cbt-validator
    app.kubernetes.io/managed-by: kube-burner
spec:
  source:
    apiGroup: kubevirt.io
    kind: VirtualMachine
    name: $vm
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $pvc
  namespace: $NAMESPACE
  labels:
    app.kubernetes.io/name: odf-cbt-validator
    app.kubernetes.io/managed-by: kube-burner
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests: {storage: $BACKUP_SIZE}
  storageClassName: $BACKUP_STORAGE_CLASS
EOF
  oc wait --for=jsonpath='{.status.phase}'=Bound pvc/"$pvc" -n "$NAMESPACE" --timeout="${TIMEOUT}s" || return
  assert_backup_inputs "$vm" || return
  log INFO RESET "Reset complete for $vm (tracker+backup-output recreated)"
}
backup_reset_selected() {
  local vm i=0 total
  parse_selection "$@"
  start_report backup-reset
  total=${#selected[@]}
  for vm in "${selected[@]}"; do
    ((i+=1))
    log INFO TEST "[$i/$total] backup-reset $vm"
    if backup_reset_one "$vm"; then
      record "$vm" PASS 'Backup CRs, tracker, and backup-output PVC cleared and recreated'
    else
      record "$vm" FAIL 'backup-reset failed'
    fi
  done
  ((failed==0 && inconclusive==0)) && finish_report 0 || finish_report 1
}
cbt_diagnostics_selected() {
  local vm i=0 total name collected
  parse_selection "$@" || return
  start_report cbt-diagnostics || return
  total=${#selected[@]}
  for vm in "${selected[@]}"; do
    ((i+=1))
    collected=0
    log INFO TEST "[$i/$total] cbt-diagnostics $vm"
    for name in "$vm-full" "$vm-incremental"; do
      if oc get virtualmachinebackup "$name" -n "$NAMESPACE" >/dev/null 2>&1; then
        collect_backup_diagnostics "$vm" "$name" ""
        ((collected+=1))
      else
        log INFO DIAG "Skip $name (not found)"
      fi
    done
    if ((collected == 0)); then
      record "$vm" INCONCLUSIVE 'No Full or Incremental backup found to diagnose'
    else
      record "$vm" PASS 'Diagnostics collected for existing backups'
    fi
  done
  ((failed==0 && inconclusive==0)) && finish_report 0 || finish_report 1
}
run_selected() {
  local action=$1; shift
  local vm i=0 total rc locked
  parse_selection "$@" || return
  start_report "$action" || return
  total=${#selected[@]}
  for vm in "${selected[@]}"; do
    ((i+=1))
    log INFO TEST "[$i/$total] $action $vm"
    rc=0
    locked=0
    acquire_vm_lock "$vm" && locked=1 || rc=$?
    if ((rc == 0)); then wait_for_live_workload "$vm" || rc=$?; fi
    if ((rc == 0)) && [[ $action == backup ]]; then
      backup_one "$vm" "$vm-full" || rc=$?
    elif ((rc == 0)) && [[ $action == cbt-backup ]]; then
      cbt_one "$vm" "$vm-incremental" || rc=$?
    elif ((rc == 0)); then
      verify_one "$vm" || rc=$?
    fi
    if ((locked == 1)); then release_vm_lock "$vm" || rc=$?; fi
    if ((rc == 0)); then
      record "$vm" INCONCLUSIVE 'Control-plane and artifact evidence passed; run cbt-cycle for restore-hash proof'
    elif ((rc == 2)); then
      record "$vm" INCONCLUSIVE 'Verification incomplete: physical evidence could not be inspected'
    else
      record "$vm" FAIL "$action failed"
    fi
  done
  ((failed==0 && inconclusive==0)) && finish_report 0 || finish_report 1
}
guest_check() {
  # Prints max(seq) on success to stdout; returns nonzero on failure.
  local vm=$1 output max_seq
  [[ -n $SSH_KEY ]] || return 1
  output=$(guest_ssh "$vm" \
    "test -f /data/vm-validator/workload.db -a -f /data/vm-validator/workload.log && mountpoint -q /data && python3 -c \"
import sqlite3, hashlib
c = sqlite3.connect('/data/vm-validator/workload.db', timeout=30.0)
c.execute('PRAGMA busy_timeout=30000')
row = c.execute('PRAGMA integrity_check').fetchone()
assert row and row[0] == 'ok', row
r = c.execute('select seq, payload, digest from records order by seq').fetchall()
assert r and [x[0] for x in r] == list(range(1, len(r) + 1))
assert all(hashlib.sha256(x[1].encode()).hexdigest() == x[2] for x in r)
print('GUEST_SEQ=' + str(r[-1][0]))
\")") || return 1
  max_seq=$(grep -Eo 'GUEST_SEQ=[0-9]+' <<<"$output" | tail -1 | cut -d= -f2)
  [[ $max_seq =~ ^[1-9][0-9]*$ ]] || return 1
  printf '%s\n' "$max_seq"
}
wait_for_live_workload() {
  local vm=$1 deadline=$((SECONDS + TIMEOUT))
  oc wait --for=jsonpath='{.status.ready}'=true vm/"$vm" -n "$NAMESPACE" --timeout="${TIMEOUT}s" || return
  oc wait --for=jsonpath='{.status.phase}'=Running vmi/"$vm" -n "$NAMESPACE" --timeout="${TIMEOUT}s" || return
  oc get vm "$vm" -n "$NAMESPACE" -o json | jq -e '.status.changedBlockTracking.state=="Enabled"' >/dev/null || return
  assert_backup_inputs "$vm" || return
  wait_for_proof_guest_ssh "$vm" || return
  wait_for_proof_guest_data "$vm" || return
  while ((SECONDS < deadline)); do
    if proof_guest_command "$vm" 'sudo -n systemctl is-active --quiet vm-validator.service vm-write-stress.service' &&
       guest_check "$vm" >/dev/null; then
      return 0
    fi
    sleep 5
  done
  echo "ERROR: guest workload did not become healthy on $vm within ${TIMEOUT}s" >&2
  return 1
}
verify_one() {
  local vm=$1 seq1 seq2
  wait_for_live_workload "$vm" || return
  wait_backup "$vm" "$vm-full" || return
  cbt_backup_evidence "$vm" "$vm-full" Full || return $?
  wait_backup "$vm" "$vm-incremental" || return
  cbt_backup_evidence "$vm" "$vm-incremental" Incremental || return $?
  seq1=$(guest_check "$vm") || return
  sleep 2
  seq2=$(guest_check "$vm") || return
  ((seq2 > seq1)) || {
    echo "ERROR: guest sequence did not increase across checks (seq1=$seq1 seq2=$seq2)" >&2
    return 1
  }
  log INFO VALIDATE "Guest workload advanced: seq $seq1 → $seq2"
}
status_selected() {
  if (($#==0)); then set -- --all; fi
  parse_selection "$@"
  printf '%-32s %-8s %-10s %-12s %-12s %-12s %s\n' VM READY PHASE CBT FULL INCREMENTAL CHECKPOINT
  local vm full inc cp
  for vm in "${selected[@]}"; do
    full=$(oc get virtualmachinebackup "$vm-full" -n "$NAMESPACE" -o json 2>/dev/null | jq -r '.status.type // .status.conditions[0].reason // "-"' 2>/dev/null) || full="-"
    inc=$(oc get virtualmachinebackup "$vm-incremental" -n "$NAMESPACE" -o json 2>/dev/null | jq -r '.status.type // .status.conditions[0].reason // "-"' 2>/dev/null) || inc="-"
    cp=$(tracker_checkpoint_name "$vm-tracker")
    [[ -n $cp ]] || cp="-"
    printf '%-32s %-8s %-10s %-12s %-12s %-12s %s\n' \
      "$vm" \
      "$(oc get vm "$vm" -n "$NAMESPACE" -o jsonpath='{.status.ready}' 2>/dev/null || echo -)" \
      "$(oc get vmi "$vm" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo -)" \
      "$(oc get vm "$vm" -n "$NAMESPACE" -o jsonpath='{.status.changedBlockTracking.state}' 2>/dev/null || echo -)" \
      "$full" "$inc" "$cp"
  done
}
ssh_guest() {
  local vm='' cmd=''
  while (($#)); do case "$1" in
    --vm) vm=${2-}; shift 2;;
    --cmd) cmd=${2-}; shift 2;;
    *) return 2;;
  esac; done
  # Prefer explicit --cmd; fall back to CMD env (Make preserves spaces/quotes that way).
  [[ -z $cmd && -n ${CMD:-} ]] && cmd=$CMD
  [[ -n $vm && $vm == "$VM_PREFIX"-* ]] || { echo 'ERROR: VM is required and must use configured prefix' >&2; return 2; }
  guest_ssh "$vm" "${cmd:-hostname}"
}
report() { local f; f=$(find "$REPORTS_DIR" -name summary.json -print | sort | sed -n '$p'); [[ -n $f ]] && cat "$f" || { echo 'No reports'; return 1; }; }
list_reports() { find "$REPORTS_DIR" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | sort -r; }
e2e() {
  local count=${1:-$VM_COUNT}
  density_setup
  cbt_cycle_selected --count "$count"
}
proof_cleanup() {
  local rc=$? cleanup_rc=0
  trap - EXIT
  if [[ -n ${proof_namespace:-} ]] && oc get namespace "$proof_namespace" >/dev/null 2>&1; then
    NAMESPACE=$proof_namespace
    density_teardown || { cleanup_rc=$?; echo "ERROR: proof namespace cleanup failed: $NAMESPACE" >&2; }
  fi
  if [[ ${proof_report_started:-0} == 1 && ${proof_report_done:-0} == 0 ]]; then
    record "${selected[0]:-proof}" FAIL 'Proof did not complete; see run.log'
    finish_report 1 || true
  fi
  ((rc == 0 && cleanup_rc != 0)) && rc=$cleanup_rc
  exit "$rc"
}
proof_guest_command() {
  local vm=$1 command=$2
  guest_ssh "$vm" "$command"
}
wait_for_proof_guest_ssh() {
  local vm=$1 deadline=$((SECONDS+TIMEOUT)) output=''
  echo "Waiting for guest SSH on $vm" >&2
  while ((SECONDS < deadline)); do
    if output=$(proof_guest_command "$vm" 'echo CBT_PROOF_SSH_READY' 2>&1) &&
       [[ $output == *CBT_PROOF_SSH_READY* ]]; then
      echo "Guest SSH ready: $vm" >&2
      return 0
    fi
    sleep 5
  done
  echo "ERROR: guest SSH did not become ready in ${TIMEOUT}s: $output" >&2
  return 1
}
wait_for_proof_guest_data() {
  local vm=$1 deadline=$((SECONDS+TIMEOUT)) output=''
  echo "Waiting for /data mount on $vm" >&2
  while ((SECONDS < deadline)); do
    if output=$(proof_guest_command "$vm" \
      'sudo -n sh -c "mountpoint -q /data && test \"$(findmnt -n -o SOURCE /data)\" = /dev/vdc && mkdir -p /data/vm-validator && echo CBT_PROOF_DATA_READY"' 2>&1) &&
       [[ $output == *CBT_PROOF_DATA_READY* ]]; then
      echo "Guest /data ready: $vm" >&2
      return 0
    fi
    sleep 5
  done
  echo "ERROR: guest /data was not mounted from /dev/vdc within ${TIMEOUT}s: $output" >&2
  return 1
}
backup_force_full_one() {
  local vm=$1 name=$2 uid
  uid=$(create_backup_request "$vm" "$name" true) || return
  wait_backup "$vm" "$name" || return
  cbt_backup_evidence "$vm" "$name" Full "$uid"
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
  # Exit codes from cbt-evidence-check.sh:
  #   0 = match, 1 = type mismatch, 2 = uninspectable (INCONCLUSIVE)
  local vm=$1 name=$2 expected_type=$3 expected_uid=${4:-}
  local evidence_dir=${run_dir:+$run_dir/evidence} evidence_json rc=0 args=()
  if [[ -n $evidence_dir ]]; then mkdir -p "$evidence_dir" || return; fi
  args=(
    --namespace "$NAMESPACE" --vm "$vm" --backup "$name"
    --expected "$expected_type" --backup-pvc "$vm-backup-output"
    --timeout "$TIMEOUT"
  )
  [[ -n $expected_uid ]] && args+=(--vmb-uid "$expected_uid" --test-id "$test_id")
  evidence_json=$("$ROOT/scripts/cbt-evidence-check.sh" "${args[@]}") || rc=$?

  [[ -n $evidence_dir && -n $evidence_json ]] && printf '%s\n' "$evidence_json" >"$evidence_dir/$name-evidence.json"

  if ((rc == 0)); then
    jq -r '"CBT evidence: \(.backup) is physically \(.physicalType) (backing=\(.backingFile // "none")), allocated=\(.allocatedDataBytes)B — matches expected \(.expectedType)"' <<<"$evidence_json"
    return 0
  fi
  if ((rc == 2)); then
    jq -r '"INCONCLUSIVE: \(.backup // "'"$name"'") evidence uninspectable (physicalType=\(.physicalType // "unknown"))"' <<<"$evidence_json" >&2 2>/dev/null || \
      echo "INCONCLUSIVE: physical evidence could not be inspected for $name (expected $expected_type)" >&2
    return 2
  fi
  jq -r '"ERROR: \(.backup) claims/expects \(.expectedType) but the qcow2 artifact is physically \(.physicalType) (backing=\(.backingFile // "none"))"' <<<"$evidence_json" >&2 2>/dev/null || \
    echo "ERROR: physical evidence check failed for $name (expected $expected_type)" >&2
  return 1
}
cbt_evidence_selected() {
  parse_selection "$@"
  start_report cbt-evidence
  local vm rc ok msg i=0 total=${#selected[@]}
  for vm in "${selected[@]}"; do
    ((i+=1))
    log INFO TEST "[$i/$total] cbt-evidence $vm"
    ok=INCONCLUSIVE
    msg='Artifacts match physical CBT evidence but have not passed restore-hash validation'
    rc=0
    cbt_backup_evidence "$vm" "$vm-full" Full || rc=$?
    if ((rc == 0)); then
      cbt_backup_evidence "$vm" "$vm-incremental" Incremental || rc=$?
    fi
    if ((rc == 2)); then
      ok=INCONCLUSIVE
      msg='Physical qcow2 evidence could not be inspected'
    elif ((rc != 0)); then
      ok=FAIL
      msg='Physical qcow2 evidence did not match expected backup type'
    fi
    record "$vm" "$ok" "$msg"
  done
  ((failed==0 && inconclusive==0)) && finish_report 0 || finish_report 1
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

  # Stop guest writers via systemctl only. Do not pkill -f patterns that also
  # appear in this command's argv (e.g. vm-write-stress.service) — that can
  # kill the remote shell before umount runs.
  disk_bytes=$(proof_guest_command "$vm" \
    "sudo -n sh -c 'if command -v cloud-init >/dev/null 2>&1; then timeout ${TIMEOUT}s cloud-init status --wait >/dev/null 2>&1 || true; fi; if command -v systemctl >/dev/null 2>&1; then systemctl disable --now vm-validator.service >/dev/null 2>&1 || true; systemctl disable --now vm-write-stress.service >/dev/null 2>&1 || true; fi; sync; sleep 2; if mountpoint -q /data; then umount /data || exit 1; fi; blockdev --getsize64 /dev/vdc'")
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

  # Capture launcher image/state claim while the VMI still exists, then stop
  # the VM before mounting state/data PVCs into a second pod (AGENTS.md:
  # concurrent RBD attach of live CBT/data PVCs pauses the running guest).
  launcher=$(oc get pods -n "$NAMESPACE" -o json | jq -er --arg prefix "virt-launcher-$vm-" \
    '[.items[] | select(.metadata.name | startswith($prefix)) | .metadata.name][0]')
  launcher_json=$(oc get pod "$launcher" -n "$NAMESPACE" -o json)
  launcher_node=$(jq -er '.spec.nodeName' <<<"$launcher_json")
  state_claim=$(jq -er '.spec.volumes[] | select(.name=="vm-state") | .persistentVolumeClaim.claimName' <<<"$launcher_json")
  image=$(jq -er '.spec.containers[] | select(.name=="compute") | .image' <<<"$launcher_json")

  log INFO PROOF "Stopping $vm before mounting state/data PVCs for payload inspect"
  virtctl stop "$vm" -n "$NAMESPACE" || oc patch vm "$vm" -n "$NAMESPACE" --type=merge -p '{"spec":{"runStrategy":"Halted"}}'
  local stop_deadline=$((SECONDS + TIMEOUT))
  while oc get vmi "$vm" -n "$NAMESPACE" >/dev/null 2>&1; do
    if ((SECONDS >= stop_deadline)); then
      echo "ERROR: VMI $vm still present after stop within ${TIMEOUT}s" >&2
      return 1
    fi
    sleep 5
  done
  log INFO PROOF "VMI gone; safe to mount state/data PVCs read-only"

  pod=cbt-payload-inspector
  oc delete pod "$pod" -n "$NAMESPACE" --ignore-not-found --wait=true --timeout="${TIMEOUT}s" >/dev/null
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

# Shared marker / Full+Incremental restore helpers (density cbt-cycle and
# disposable cbt-restore-proof). Never mounts the source VM's data or
# CBT-overlay PVC — only backup-output RO + a new restore PVC.
# VirtualMachineRestore is not used (that API restores snapshots).

CBT_MARKER_PATH=/data/vm-validator/cbt-marker.bin

guest_marker_sha256() {
  local vm=$1 path=$2 base
  base=$(basename "$path")
  proof_guest_command "$vm" \
    "sudo -n sh -c 'mountpoint -q /data || mount /dev/vdc /data; test -f $path; sha256sum $path'" \
    | awk -v b="$base" 'index($0, b) {print $1; exit}'
}

guest_marker_write_base() {
  local vm=$1 path=$2 base_mib=$3
  local base hash
  base=$(basename "$path")
  hash=$(proof_guest_command "$vm" \
    "sudo -n sh -c 'mountpoint -q /data || exit 1; mkdir -p $(dirname "$path"); dd if=/dev/urandom of=$path bs=1M count=$base_mib conv=fsync status=none; sha256sum $path'" \
    | awk -v b="$base" 'index($0, b) {print $1; exit}')
  [[ $hash =~ ^[0-9a-f]{64}$ ]] || {
    echo "ERROR: failed to capture baseline hash for $path (got '${hash:-empty}')" >&2
    return 1
  }
  printf '%s\n' "$hash"
}

guest_marker_append() {
  local vm=$1 path=$2 append_mib=$3
  local base hash
  base=$(basename "$path")
  hash=$(proof_guest_command "$vm" \
    "sudo -n sh -c 'mountpoint -q /data || exit 1; test -f $path; dd if=/dev/urandom of=$path bs=1M count=$append_mib oflag=append conv=notrunc,fsync status=none; sha256sum $path'" \
    | awk -v b="$base" 'index($0, b) {print $1; exit}')
  [[ $hash =~ ^[0-9a-f]{64}$ ]] || {
    echo "ERROR: failed to capture append hash for $path (got '${hash:-empty}')" >&2
    return 1
  }
  printf '%s\n' "$hash"
}
cleanup_restore_resources() {
  local vm=$1
  local restore_vm="$vm-restored" restore_pvc="$vm-restore-data" converter="$vm-restore-converter" rc=0
  oc delete vm "$restore_vm" -n "$NAMESPACE" --ignore-not-found --wait=true --timeout="${TIMEOUT}s" >/dev/null || rc=1
  oc delete secret "$restore_vm-userdata" -n "$NAMESPACE" --ignore-not-found --wait=true --timeout="${TIMEOUT}s" >/dev/null || rc=1
  oc delete pod "$converter" -n "$NAMESPACE" --ignore-not-found --wait=true --timeout="${TIMEOUT}s" >/dev/null || rc=1
  oc delete pvc "$restore_pvc" -n "$NAMESPACE" --ignore-not-found --wait=true --timeout="${TIMEOUT}s" >/dev/null || rc=1
  ((rc == 0)) || echo "ERROR: restore cleanup failed for $vm; resources remain for diagnostics" >&2
  return "$rc"
}

# Convert Full+Incremental qcow2 chain onto $vm-restore-data (rebase Inc onto Full).
convert_backup_chain_to_pvc() {
  local vm=$1 full_name=$2 inc_name=$3
  local restore_pvc="$vm-restore-data" converter="$vm-restore-converter"
  local avoid_node image affinity full_checkpoint inc_checkpoint full_path inc_path convert_out

  avoid_node=$(oc get vmi "$vm" -n "$NAMESPACE" -o jsonpath='{.status.nodeName}' 2>/dev/null || true)
  affinity=''
  if [[ -n $avoid_node ]]; then
    affinity="  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - {key: kubernetes.io/hostname, operator: NotIn, values: [$avoid_node]}"
  fi
  image=$(virt_launcher_image "$vm") || return 1

  echo "Creating restore PVC $restore_pvc" >&2
  cat <<EOF | oc apply -f - >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $restore_pvc
  namespace: $NAMESPACE
  labels:
    app.kubernetes.io/name: odf-cbt-restore-target
    app.kubernetes.io/managed-by: odf-cbt-validator
spec:
  accessModes: [ReadWriteOnce]
  volumeMode: Filesystem
  resources: {requests: {storage: $DATA_SIZE}}
  storageClassName: $DATA_STORAGE_CLASS
EOF
  oc wait --for=jsonpath='{.status.phase}'=Bound pvc/"$restore_pvc" -n "$NAMESPACE" --timeout="${TIMEOUT}s" >/dev/null

  full_checkpoint=$(oc get virtualmachinebackup "$full_name" -n "$NAMESPACE" -o json | jq -er '.status.checkpointName')
  inc_checkpoint=$(oc get virtualmachinebackup "$inc_name" -n "$NAMESPACE" -o json | jq -er '.status.checkpointName')
  full_path="/proof/$vm/$full_checkpoint/$full_name-datadisk.qcow2"
  inc_path="/proof/$vm/$inc_checkpoint/$inc_name-datadisk.qcow2"

  echo "Converting Full+Incremental chain onto $restore_pvc (rebase Incremental onto Full, then qemu-img convert)" >&2
  oc delete pod "$converter" -n "$NAMESPACE" --ignore-not-found --wait=true --timeout="${TIMEOUT}s" >/dev/null
  cat <<EOF | oc apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: $converter
  namespace: $NAMESPACE
  labels:
    app.kubernetes.io/name: odf-cbt-restore-target
    app.kubernetes.io/managed-by: odf-cbt-validator
spec:
  restartPolicy: Never
$affinity
  securityContext:
    runAsNonRoot: true
    runAsUser: 107
    runAsGroup: 107
    fsGroup: 107
    seccompProfile: {type: RuntimeDefault}
  containers:
  - name: convert
    image: "$image"
    command: ["/bin/sh", "-ec"]
    args:
    - |
      test -f "$full_path"
      test -f "$inc_path"
      cp "$inc_path" /work/inc.qcow2
      # Incremental backing points at the live CBT overlay path; rebase onto the
      # Full backup artifact so convert never needs the source VM's CBT PVC.
      qemu-img rebase -u -b "$full_path" -F qcow2 /work/inc.qcow2
      rm -f /restore/disk.img
      qemu-img convert -p -f qcow2 -O raw /work/inc.qcow2 /restore/disk.img
      sync
      test -s /restore/disk.img
      echo CONVERT_OK
    securityContext:
      allowPrivilegeEscalation: false
      capabilities: {drop: ["ALL"]}
    volumeMounts:
    - {name: backup, mountPath: /proof, readOnly: true}
    - {name: restore, mountPath: /restore}
    - {name: work, mountPath: /work}
  volumes:
  - name: backup
    persistentVolumeClaim: {claimName: $vm-backup-output}
  - name: restore
    persistentVolumeClaim: {claimName: $restore_pvc}
  - name: work
    emptyDir: {sizeLimit: 2Gi}
EOF
  oc wait --for=jsonpath='{.status.phase}'=Succeeded pod/"$converter" -n "$NAMESPACE" --timeout="${TIMEOUT}s" >/dev/null || {
    echo 'ERROR: restore converter pod did not Succeed' >&2
    oc logs -n "$NAMESPACE" "$converter" -c convert >&2 || true
    return 1
  }
  convert_out=$(oc logs -n "$NAMESPACE" "$converter" -c convert)
  grep -q CONVERT_OK <<<"$convert_out" || {
    echo "ERROR: converter did not report CONVERT_OK: $convert_out" >&2
    return 1
  }
  oc delete pod "$converter" -n "$NAMESPACE" --wait=true --timeout="${TIMEOUT}s" >/dev/null
}

boot_restore_vm() {
  local vm=$1
  local restore_vm="$vm-restored" restore_pvc="$vm-restore-data"

  echo "Booting restore VM $restore_vm from converted PVC" >&2
  cat <<EOF | oc apply -f - >/dev/null
apiVersion: v1
kind: Secret
metadata:
  name: $restore_vm-userdata
  namespace: $NAMESPACE
  labels:
    app.kubernetes.io/name: odf-cbt-restore-target
    app.kubernetes.io/managed-by: odf-cbt-validator
stringData:
  userdata: |
    #cloud-config
    user: $SSH_USER
    ssh_authorized_keys:
      - $SSH_PUBLIC_KEY
    mounts:
      - [/dev/vdc, /data, xfs, "defaults,nofail", "0", "2"]
    runcmd:
      - mkdir -p /data
      - bash -c 'mountpoint -q /data || mount /dev/vdc /data'
---
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: $restore_vm
  namespace: $NAMESPACE
  labels:
    app.kubernetes.io/name: odf-cbt-restore-target
    app.kubernetes.io/managed-by: odf-cbt-validator
spec:
  runStrategy: Always
  template:
    metadata:
      labels:
        app.kubernetes.io/name: odf-cbt-restore-target
        app.kubernetes.io/managed-by: odf-cbt-validator
    spec:
      domain:
        cpu: {cores: $VM_CPU}
        resources: {requests: {memory: $VM_MEMORY}}
        devices:
          disks:
            - {name: containerdisk, disk: {bus: virtio}}
            - {name: cloudinitdisk, disk: {bus: virtio}}
            - {name: datadisk, disk: {bus: virtio}}
          interfaces: [{name: default, masquerade: {}}]
      networks: [{name: default, pod: {}}]
      volumes:
        - {name: containerdisk, containerDisk: {image: $CONTAINER_IMAGE}}
        - {name: cloudinitdisk, cloudInitNoCloud: {secretRef: {name: $restore_vm-userdata}}}
        - {name: datadisk, persistentVolumeClaim: {claimName: $restore_pvc}}
EOF
  oc wait --for=jsonpath='{.status.ready}'=true vm/"$restore_vm" -n "$NAMESPACE" --timeout="${TIMEOUT}s" >/dev/null
  oc wait --for=jsonpath='{.status.phase}'=Running vmi/"$restore_vm" -n "$NAMESPACE" --timeout="${TIMEOUT}s" >/dev/null
  wait_for_proof_guest_ssh "$restore_vm"
}

# Restore Full+Incremental onto a new VM and require restored marker hash == expected_hash.
# Cleans restore-only resources afterward (source VM kept). Prints restored hash on stdout.
restore_chain_and_verify_hash() {
  local vm=$1 marker_path=$2 expected_hash=$3
  local restore_vm="$vm-restored" restored_hash
  cleanup_restore_resources "$vm" || return
  convert_backup_chain_to_pvc "$vm" "$vm-full" "$vm-incremental" || return 1
  boot_restore_vm "$vm" || {
    cleanup_restore_resources "$vm"
    return 1
  }
  restored_hash=$(guest_marker_sha256 "$restore_vm" "$marker_path") || {
    cleanup_restore_resources "$vm"
    return 1
  }
  [[ $restored_hash =~ ^[0-9a-f]{64}$ ]] || {
    echo "ERROR: failed to hash restored marker (got '${restored_hash:-empty}')" >&2
    cleanup_restore_resources "$vm"
    return 1
  }
  echo "restored_hash=$restored_hash" >&2
  if [[ $restored_hash != "$expected_hash" ]]; then
    echo "ERROR: restored hash $restored_hash != expected $expected_hash" >&2
    cleanup_restore_resources "$vm"
    return 1
  fi
  cleanup_restore_resources "$vm" || return
  printf '%s\n' "$restored_hash"
}

cbt_cycle_one() {
  # Density-pool CBT cycle: rewrite marker → Full → append → Incremental →
  # verify (guest+qcow2) → restore-hash. Does not auto-reset prior backups.
  local vm=$1
  local marker=$CBT_MARKER_PATH
  local base_mib=$RESTORE_PROOF_BASE_MIB append_mib=$RESTORE_PROOF_APPEND_MIB
  local hash0 hash1 restored_hash checkpoint full_name="$vm-full" inc_name="$vm-incremental"
  local full_checkpoint inc_checkpoint

  assert_owned_namespace || return 1
  [[ -n $SSH_KEY && -r $SSH_KEY ]] || { echo 'ERROR: SSH_KEY is required for cbt-cycle' >&2; return 2; }
  [[ -n $SSH_PUBLIC_KEY ]] || { echo 'ERROR: SSH_PUBLIC_KEY is required for restore VM' >&2; return 2; }
  [[ $base_mib =~ ^[1-9][0-9]*$ && $append_mib =~ ^[1-9][0-9]*$ ]] || {
    echo 'ERROR: RESTORE_PROOF_BASE_MIB and RESTORE_PROOF_APPEND_MIB must be positive integers' >&2
    return 2
  }

  if oc get virtualmachinebackup "$full_name" -n "$NAMESPACE" >/dev/null 2>&1; then
    echo "ERROR: $full_name already exists; run 'make backup-reset' first" >&2
    return 1
  fi
  checkpoint=$(tracker_checkpoint_name "$vm-tracker")
  if [[ -n $checkpoint ]]; then
    echo "ERROR: tracker $vm-tracker already has checkpoint '$checkpoint'; run 'make backup-reset' first" >&2
    return 1
  fi

  wait_for_proof_guest_ssh "$vm"
  wait_for_proof_guest_data "$vm"

  echo "Rewriting marker baseline (${base_mib} MiB) on $vm → $marker"
  hash0=$(guest_marker_write_base "$vm" "$marker" "$base_mib") || return 1
  echo "hash0=$hash0"
  backup_one "$vm" "$full_name" || return $?

  echo "Appending ${append_mib} MiB to marker on $vm"
  hash1=$(guest_marker_append "$vm" "$marker" "$append_mib") || return 1
  [[ $hash1 != "$hash0" ]] || {
    echo "ERROR: append hash matched baseline (hash0=$hash0)" >&2
    return 1
  }
  echo "hash1=$hash1"
  sleep "$CBT_CHANGE_WAIT"
  cbt_one "$vm" "$inc_name" || return $?

  verify_one "$vm" || return $?

  restored_hash=$(restore_chain_and_verify_hash "$vm" "$marker" "$hash1") || return 1
  [[ $restored_hash =~ ^[0-9a-f]{64}$ && $restored_hash == "$hash1" ]] || {
    echo "ERROR: restore-hash capture invalid (got '${restored_hash:-empty}')" >&2
    return 1
  }

  full_checkpoint=$(oc get virtualmachinebackup "$full_name" -n "$NAMESPACE" -o json | jq -r '.status.checkpointName // empty')
  inc_checkpoint=$(oc get virtualmachinebackup "$inc_name" -n "$NAMESPACE" -o json | jq -r '.status.checkpointName // empty')
  mkdir -p "$run_dir/evidence"
  jq -n --arg vm "$vm" --arg markerPath "$marker" \
    --arg hash0 "$hash0" --arg hash1 "$hash1" --arg restoredHash "$restored_hash" \
    --arg fullCheckpoint "$full_checkpoint" --arg incrementalCheckpoint "$inc_checkpoint" \
    --argjson baseMib "$base_mib" --argjson appendMib "$append_mib" \
    --argjson match "$([[ $restored_hash == "$hash1" ]] && echo true || echo false)" \
    '{vm:$vm,status:"PASS",markerPath:$markerPath,baseMib:$baseMib,appendMib:$appendMib,hash0:$hash0,hash1:$hash1,restoredHash:$restoredHash,fullCheckpoint:$fullCheckpoint,incrementalCheckpoint:$incrementalCheckpoint,match:$match,message:"Full+Incremental cycle: qcow2 evidence, guest workload, and restored marker hash all passed"}' \
    >"$run_dir/evidence/$vm-cbt-cycle.json"
  echo "CBT cycle PASS for $vm: restored hash matches hash1 ($hash1)"
  return 0
}

cbt_cycle_selected() {
  local vm i=0 total rc locked
  parse_selection "$@" || return
  start_report cbt-cycle || return
  total=${#selected[@]}
  for vm in "${selected[@]}"; do
    ((i+=1))
    log INFO TEST "[$i/$total] cbt-cycle $vm"
    rc=0
    locked=0
    acquire_vm_lock "$vm" && locked=1 || rc=$?
    if ((rc == 0)); then cbt_cycle_one "$vm" || rc=$?; fi
    if ((locked == 1)); then release_vm_lock "$vm" || rc=$?; fi
    if ((rc == 0)); then
      record "$vm" PASS 'Marker Full→append→Incremental→verify→restore-hash passed'
    elif ((rc == 2)); then
      record "$vm" INCONCLUSIVE 'CBT cycle incomplete: evidence could not be inspected'
    else
      record "$vm" FAIL 'CBT cycle failed'
    fi
  done
  ((failed==0 && inconclusive==0)) && finish_report 0 || finish_report 1
}

# Disposable-namespace restore proof (keeps prior make cbt-restore-proof surface).
cbt_restore_proof() {
  local stamp vm full_name inc_name proof_path base_mib append_mib
  local hash1 hash2 restored_hash full_checkpoint inc_checkpoint

  for t in oc virtctl kube-burner jq; do need "$t" || return; done
  check_prereqs
  [[ -n $SSH_KEY && -r $SSH_KEY ]] || { echo 'ERROR: SSH_KEY is required and must be readable for CBT restore proof' >&2; return 2; }
  [[ -n $SSH_PUBLIC_KEY ]] || { echo 'ERROR: SSH_PUBLIC_KEY is required for the disposable proof / restore VMs' >&2; return 2; }
  [[ $RESTORE_PROOF_BASE_MIB =~ ^[1-9][0-9]*$ && $RESTORE_PROOF_APPEND_MIB =~ ^[1-9][0-9]*$ ]] || {
    echo 'ERROR: RESTORE_PROOF_BASE_MIB and RESTORE_PROOF_APPEND_MIB must be positive integers' >&2
    return 2
  }
  base_mib=$RESTORE_PROOF_BASE_MIB
  append_mib=$RESTORE_PROOF_APPEND_MIB
  proof_path=/data/vm-validator/cbt-restore-proof.bin

  stamp=$(date -u +%y%m%d%H%M%S)
  proof_namespace="cbt-restore-$stamp"
  NAMESPACE=$proof_namespace
  VM_PREFIX=cbt-restore-vm
  VM_COUNT=1
  if oc get namespace "$NAMESPACE" >/dev/null 2>&1; then
    echo "ERROR: proof namespace already exists: $NAMESPACE" >&2
    return 1
  fi

  start_report cbt-restore-proof
  proof_report_started=1
  proof_report_done=0
  trap proof_cleanup EXIT
  density_setup
  vm=${selected[0]}
  full_name="$vm-full"
  inc_name="$vm-incremental"
  wait_for_proof_guest_ssh "$vm"
  wait_for_proof_guest_data "$vm"

  echo "Writing baseline proof file (${base_mib} MiB) on $vm"
  hash1=$(guest_marker_write_base "$vm" "$proof_path" "$base_mib") || return 1
  echo "hash1=$hash1"
  backup_one "$vm" "$full_name"

  echo "Appending ${append_mib} MiB to proof file on $vm"
  hash2=$(guest_marker_append "$vm" "$proof_path" "$append_mib") || return 1
  [[ $hash2 != "$hash1" ]] || {
    echo "ERROR: failed to capture distinct hash2 (hash1=$hash1 hash2=$hash2)" >&2
    return 1
  }
  echo "hash2=$hash2"
  sleep "$CBT_CHANGE_WAIT"
  cbt_one "$vm" "$inc_name"

  restored_hash=$(restore_chain_and_verify_hash "$vm" "$proof_path" "$hash2") || {
    ((failed+=1))
    finish_report 1
    proof_report_done=1
    return 1
  }
  [[ $restored_hash =~ ^[0-9a-f]{64}$ && $restored_hash == "$hash2" ]] || {
    echo "ERROR: restore-hash capture invalid (got '${restored_hash:-empty}')" >&2
    ((failed+=1))
    finish_report 1
    proof_report_done=1
    return 1
  }

  full_checkpoint=$(oc get virtualmachinebackup "$full_name" -n "$NAMESPACE" -o json | jq -r '.status.checkpointName // empty')
  inc_checkpoint=$(oc get virtualmachinebackup "$inc_name" -n "$NAMESPACE" -o json | jq -r '.status.checkpointName // empty')
  mkdir -p "$run_dir/evidence"
  jq -n --arg vm "$vm" --arg restoreVm "$vm-restored" --arg proofPath "$proof_path" \
    --arg hash1 "$hash1" --arg hash2 "$hash2" --arg restoredHash "$restored_hash" \
    --arg fullCheckpoint "$full_checkpoint" --arg incrementalCheckpoint "$inc_checkpoint" \
    --argjson baseMib "$base_mib" --argjson appendMib "$append_mib" \
    --argjson match "$([[ $restored_hash == "$hash2" ]] && echo true || echo false)" \
    '{vm:$vm,restoreVm:$restoreVm,status:"PASS",proofPath:$proofPath,baseMib:$baseMib,appendMib:$appendMib,hash1:$hash1,hash2:$hash2,restoredHash:$restoredHash,fullCheckpoint:$fullCheckpoint,incrementalCheckpoint:$incrementalCheckpoint,match:$match,message:"Restored Full+Incremental chain reproduces post-Incremental guest file hash"}' \
    | tee "$run_dir/evidence/$vm-restore-proof.json" >"$run_dir/per-vm/$vm.json"

  ((passed+=1))
  echo "CBT restore proof PASS: restored hash matches hash2 ($hash2); hash1=$hash1"
  finish_report 0
  proof_report_done=1
}
case "$COMMAND" in
  help) usage ;;
  report) report ;;
  list-reports) list_reports ;;
  *)
    require_runtime_config || exit $?
    case "$COMMAND" in
      generate-keys) generate_keys ;;
      check-prereqs) check_prereqs ;;
      density-setup) [[ ${ARGS[0]:-} == --count ]] && VM_COUNT=${ARGS[1]}; density_setup ;;
      density-status) density_status ;;
      density-teardown) density_teardown "${ARGS[@]}" ;;
      discover-vms) discover "${ARGS[@]}" ;;
      backup|cbt-backup|verify) run_selected "$COMMAND" "${ARGS[@]}" ;;
      backup-reset) backup_reset_selected "${ARGS[@]}" ;;
      cbt-cycle) cbt_cycle_selected "${ARGS[@]}" ;;
      cbt-payload-proof) cbt_payload_proof ;;
      cbt-restore-proof) cbt_restore_proof ;;
      cbt-evidence) cbt_evidence_selected "${ARGS[@]}" ;;
      cbt-diagnostics) cbt_diagnostics_selected "${ARGS[@]}" ;;
      status) status_selected "${ARGS[@]}" ;;
      ssh) ssh_guest "${ARGS[@]}" ;;
      e2e) [[ ${ARGS[0]:-} == --count ]] && VM_COUNT=${ARGS[1]}; e2e "$VM_COUNT" ;;
      *) usage >&2; exit 2 ;;
    esac
    ;;
esac
