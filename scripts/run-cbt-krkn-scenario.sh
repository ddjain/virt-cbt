#!/usr/bin/env bash
set -euo pipefail

SCENARIO=''
MANIFEST='manifests/incremental-backup.yaml'
NAMESPACE=${NAMESPACE:-cbt-demo}
VMB_NAME=${VMB_NAME:-fedora-cbt-vm-incremental}
VM_NAME=${VM_NAME:-fedora-cbt-vm}
TRACKER_NAME=${TRACKER_NAME:-fedora-cbt-tracker}
OUTPUT_DIR=${OUTPUT_DIR:-./cbt-results}
TRIGGER_TIMEOUT=${TRIGGER_TIMEOUT:-600}

usage() {
  printf '%s\n' "Usage: $0 --scenario NAME [runner options] [-- scenario flags...]"
}

scenario_args=()
while (($#)); do
  case "$1" in
    --) shift; scenario_args+=("$@"); break ;;
    --scenario) SCENARIO=${2:?missing value for --scenario}; shift 2 ;;
    --manifest) MANIFEST=${2:?missing value for --manifest}; shift 2 ;;
    --output) OUTPUT_DIR=${2:?missing value for --output}; shift 2 ;;
    --namespace) NAMESPACE=${2:?missing value for --namespace}; shift 2 ;;
    --vmb) VMB_NAME=${2:?missing value for --vmb}; shift 2 ;;
    --vm) VM_NAME=${2:?missing value for --vm}; shift 2 ;;
    --tracker) TRACKER_NAME=${2:?missing value for --tracker}; shift 2 ;;
    --trigger-timeout) TRIGGER_TIMEOUT=${2:?missing value for --trigger-timeout}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) scenario_args+=("$1"); shift ;;
  esac
done

: "${KUBECONFIG:?set KUBECONFIG before running this script}"
KRKNCTL_KUBECONFIG=${KRKNCTL_KUBECONFIG:-$KUBECONFIG}
[[ -n "$SCENARIO" ]] || { usage >&2; exit 2; }
command -v oc >/dev/null || { echo 'oc is required' >&2; exit 127; }
command -v krknctl >/dev/null || { echo 'krknctl is required' >&2; exit 127; }
command -v jq >/dev/null || { echo 'jq is required' >&2; exit 127; }

run_dir="$OUTPUT_DIR/$SCENARIO"
mkdir -p "$run_dir"

oc delete virtualmachinebackup "$VMB_NAME" -n "$NAMESPACE" --ignore-not-found --wait=true
oc apply -f "$MANIFEST"

trigger_command='oc get virtualmachinebackup '"$VMB_NAME"' -n '"$NAMESPACE"' -o json | jq -e '\''.status.conditions // [] | any(.[]; .type == "Progressing" and .status == "True")'\'''

set +e
krknctl run "$SCENARIO" \
  --kubeconfig "$KRKNCTL_KUBECONFIG" \
  --wait-duration 30 \
  --iterations 1 \
  --triggers-on-timeout fail \
  --triggers-timeout "$TRIGGER_TIMEOUT" \
  --triggers-interval 5 \
  --trigger-command "$trigger_command" \
  --trigger-expected-rc 0 \
  "${scenario_args[@]}" \
  2>&1 | tee "$run_dir/krkn.log"
krkn_rc=${PIPESTATUS[0]}
set -e

oc get vm,vmi,pvc,virtualmachinebackup,virtualmachinebackuptracker,events \
  -n "$NAMESPACE" -o yaml > "$run_dir/cluster.yaml"
oc get virtualmachinebackup "$VMB_NAME" -n "$NAMESPACE" -o json > "$run_dir/vmb.json"
oc get virtualmachinebackuptracker "$TRACKER_NAME" -n "$NAMESPACE" -o json > "$run_dir/tracker.json"

NAMESPACE="$NAMESPACE" VM_NAME="$VM_NAME" VMB_NAME="$VMB_NAME" \
TRACKER_NAME="$TRACKER_NAME" OUTPUT="$run_dir/cbt-result.json" \
"$(dirname "$0")/classify-cbt-result.sh" || true

printf 'scenario=%s krkn_returncode=%s result=%s\n' \
  "$SCENARIO" "$krkn_rc" "$run_dir/cbt-result.json"
exit "$krkn_rc"
