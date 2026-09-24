#!/usr/bin/env bash
set -euo pipefail

# Forensic diagnostics for one VirtualMachineBackup. Collects CR YAML, events,
# and related controller/handler/launcher logs into --out-dir. This is never
# used as Full-vs-Incremental pass/fail — that remains cbt-evidence-check.sh.
#
# Best-effort: always exits 0. Per-artifact success/failure is recorded in
# manifest.json. Never mounts data/state PVCs; never writes Secret values.
#
# Usage:
#   cbt-diagnostics-collect.sh --namespace NS --vm VM --backup NAME --out-dir DIR \
#     [--since-time RFC3339] [--depth core|storage] [--tracker NAME] \
#     [--cnv-ns NS] [--storage-ns NS] [--baseline-json FILE]

NAMESPACE='' VM='' BACKUP='' OUT_DIR='' SINCE_TIME='' DEPTH=core
TRACKER='' CNV_NS=openshift-cnv STORAGE_NS=openshift-storage
BASELINE_JSON='' LOG_TAIL=20000

usage() {
  printf '%s\n' "Usage: $0 --namespace NS --vm VM --backup NAME --out-dir DIR [--since-time RFC3339] [--depth core|storage] [--tracker NAME] [--cnv-ns NS] [--storage-ns NS] [--baseline-json FILE]"
}

while (($#)); do
  case "$1" in
    --namespace) NAMESPACE=${2:?}; shift 2 ;;
    --vm) VM=${2:?}; shift 2 ;;
    --backup) BACKUP=${2:?}; shift 2 ;;
    --out-dir) OUT_DIR=${2:?}; shift 2 ;;
    --since-time) SINCE_TIME=${2:?}; shift 2 ;;
    --depth) DEPTH=${2:?}; shift 2 ;;
    --tracker) TRACKER=${2:?}; shift 2 ;;
    --cnv-ns) CNV_NS=${2:?}; shift 2 ;;
    --storage-ns) STORAGE_NS=${2:?}; shift 2 ;;
    --baseline-json) BASELINE_JSON=${2:?}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

[[ -n $NAMESPACE && -n $VM && -n $BACKUP && -n $OUT_DIR ]] || { usage >&2; exit 2; }
[[ $DEPTH == core || $DEPTH == storage ]] || { echo 'ERROR: --depth must be core or storage' >&2; exit 2; }
TRACKER=${TRACKER:-$VM-tracker}

command -v oc >/dev/null || { echo 'ERROR: oc is required' >&2; exit 127; }
command -v jq >/dev/null || { echo 'ERROR: jq is required' >&2; exit 127; }

# Do not let individual collection failures abort the script.
set +e

mkdir -p "$OUT_DIR/crs" "$OUT_DIR/cluster" "$OUT_DIR/logs"
[[ $DEPTH == storage ]] && mkdir -p "$OUT_DIR/storage"

collected_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
manifest_tmp=$(mktemp)
trap 'rm -f "$manifest_tmp"' EXIT
printf '%s\n' '[]' >"$manifest_tmp"

record_artifact() {
  local name=$1 status=$2 detail=${3:-}
  local tmp
  tmp=$(mktemp)
  jq --arg n "$name" --arg s "$status" --arg d "$detail" \
    '. + [{name:$n,status:$s,detail:$d}]' "$manifest_tmp" >"$tmp"
  mv "$tmp" "$manifest_tmp"
}

try_write() {
  # try_write NAME PATH -- command...
  local name=$1 path=$2; shift 2
  local err status=ok
  err=$(mktemp)
  if "$@" >"$path" 2>"$err"; then
    if [[ ! -s $path ]]; then
      status=empty
      record_artifact "$name" empty "wrote empty file"
    else
      record_artifact "$name" ok
    fi
  else
    status=error
    record_artifact "$name" error "$(tr '\n' ' ' <"$err" | head -c 400)"
    rm -f "$path"
  fi
  rm -f "$err"
  [[ $status == ok ]]
}

redact_secrets_yaml() {
  # Mirror run-cbt-krkn-scenario.sh: keep Secret metadata, drop values.
  sed -E 's/(^[[:space:]]*(data|stringData):)/\1 <redacted>/; /^[[:space:]]+[A-Za-z0-9_./-]+:[[:space:]]+[A-Za-z0-9+/=]+$/d'
}

log_since_args=()
if [[ -n $SINCE_TIME ]]; then
  log_since_args=(--since-time="$SINCE_TIME")
fi

# --- Resolve VMI node / launcher early (needed for handler + CSI) ---
vmi_json=''
vmi_node=''
launcher_pod=''
if vmi_json=$(oc get vmi "$VM" -n "$NAMESPACE" -o json 2>/dev/null); then
  printf '%s\n' "$vmi_json" >"$OUT_DIR/cluster/vmi-full.json"
  jq '{phase:.status.phase,node:.status.nodeName,activePods:.status.activePods,cbt:.status.changedBlockTracking,conditions:.status.conditions}' \
    <<<"$vmi_json" >"$OUT_DIR/cluster/vmi-cbt.json" 2>/dev/null
  vmi_node=$(jq -r '.status.nodeName // empty' <<<"$vmi_json")
  launcher_pod=$(jq -r --arg prefix "virt-launcher-$VM-" \
    '[.status.activePods // {} | to_entries[] | select(.key|startswith($prefix)) | .key][0] // empty' <<<"$vmi_json")
  if [[ -z $launcher_pod ]]; then
    launcher_pod=$(oc get pods -n "$NAMESPACE" -o json 2>/dev/null |
      jq -r --arg prefix "virt-launcher-$VM-" \
        '[.items[] | select(.metadata.name|startswith($prefix)) | .metadata.name][0] // empty')
  fi
  record_artifact vmi-cbt.json ok
else
  record_artifact vmi-cbt.json error 'VMI not found'
fi

# --- CRs (OPERATIONS preserve-before-cleanup recipe, split for triage) ---
try_write crs/vm.yaml "$OUT_DIR/crs/vm.yaml" \
  oc get vm "$VM" -n "$NAMESPACE" -o yaml
try_write crs/vmi.yaml "$OUT_DIR/crs/vmi.yaml" \
  oc get vmi "$VM" -n "$NAMESPACE" -o yaml
try_write crs/pvc.yaml "$OUT_DIR/crs/pvc.yaml" \
  oc get pvc -n "$NAMESPACE" -o yaml
try_write crs/virtualmachinebackup.yaml "$OUT_DIR/crs/virtualmachinebackup.yaml" \
  oc get virtualmachinebackup -n "$NAMESPACE" -o yaml
try_write crs/virtualmachinebackuptracker.yaml "$OUT_DIR/crs/virtualmachinebackuptracker.yaml" \
  oc get virtualmachinebackuptracker -n "$NAMESPACE" -o yaml
try_write crs/pods.yaml "$OUT_DIR/crs/pods.yaml" \
  oc get pods -n "$NAMESPACE" -o yaml
try_write crs/events.yaml "$OUT_DIR/crs/events.yaml" \
  oc get events -n "$NAMESPACE" --sort-by=.lastTimestamp -o yaml

# Combined dump (same shape as docs/manual cbt-diagnostics.yaml) + redacted secrets.
{
  oc get vm,vmi,pvc,virtualmachinebackup,virtualmachinebackuptracker,events \
    -n "$NAMESPACE" -o yaml 2>/dev/null
  echo '---'
  oc get pods -n "$NAMESPACE" -o yaml 2>/dev/null
  echo '---'
  oc get secret -n "$NAMESPACE" -o yaml 2>/dev/null | redact_secrets_yaml
} >"$OUT_DIR/crs/cbt-diagnostics.yaml" 2>/dev/null
if [[ -s $OUT_DIR/crs/cbt-diagnostics.yaml ]]; then
  record_artifact crs/cbt-diagnostics.yaml ok
else
  record_artifact crs/cbt-diagnostics.yaml empty 'combined dump empty'
fi

# --- Focused cluster JSON ---
try_write cluster/vmb.json "$OUT_DIR/cluster/vmb.json" \
  oc get virtualmachinebackup "$BACKUP" -n "$NAMESPACE" -o json
try_write cluster/tracker.json "$OUT_DIR/cluster/tracker.json" \
  oc get virtualmachinebackuptracker "$TRACKER" -n "$NAMESPACE" -o json

# HCO snippet only (feature gates + CBT selectors) — no full HCO dump.
if oc get hco -n "$CNV_NS" -o json >/dev/null 2>&1; then
  oc get hco -n "$CNV_NS" -o json 2>/dev/null | jq '{
    items: [.items[] | {
      name: .metadata.name,
      featureGates: (.spec.featureGates // null),
      changedBlockTrackingLabelSelectors: (
        .spec.virtualization.changedBlockTrackingLabelSelectors
        // .spec.changedBlockTrackingLabelSelectors
        // null
      )
    }]
  }' >"$OUT_DIR/cluster/hco-cbt-snippet.json" 2>/dev/null
  if [[ -s $OUT_DIR/cluster/hco-cbt-snippet.json ]]; then
    record_artifact cluster/hco-cbt-snippet.json ok
  else
    record_artifact cluster/hco-cbt-snippet.json empty
  fi
else
  record_artifact cluster/hco-cbt-snippet.json error 'HCO not found'
fi

# --- Filtered namespace events ---
oc get events -n "$NAMESPACE" --sort-by=.lastTimestamp 2>/dev/null |
  grep -Ei 'backup|checkpoint|quiesc|freeze|attach|mount|detach|migration|volume|cbt' \
  >"$OUT_DIR/logs/ns-events-filtered.txt"
if [[ -s $OUT_DIR/logs/ns-events-filtered.txt ]]; then
  record_artifact logs/ns-events-filtered.txt ok
else
  : >"$OUT_DIR/logs/ns-events-filtered.txt"
  record_artifact logs/ns-events-filtered.txt empty 'no matching events'
fi

# Events for this specific VMB
oc get events -n "$NAMESPACE" --field-selector "involvedObject.name=$BACKUP" \
  --sort-by=.lastTimestamp 2>/dev/null >"$OUT_DIR/logs/vmb-events.txt"
if [[ -s $OUT_DIR/logs/vmb-events.txt ]]; then
  record_artifact logs/vmb-events.txt ok
else
  record_artifact logs/vmb-events.txt empty
fi

# --- virt-controller logs (filtered) ---
{
  oc logs -n "$CNV_NS" deploy/virt-controller --all-containers=true --tail="$LOG_TAIL" \
    "${log_since_args[@]}" 2>/dev/null ||
  oc logs -n "$CNV_NS" deploy/virt-controller --tail="$LOG_TAIL" \
    "${log_since_args[@]}" 2>/dev/null
} | grep -Ei 'backup|checkpoint|changed.block|cbt|quiesc|export|vmbackup' \
  >"$OUT_DIR/logs/virt-controller.log"
if [[ -s $OUT_DIR/logs/virt-controller.log ]]; then
  record_artifact logs/virt-controller.log ok
else
  : >"$OUT_DIR/logs/virt-controller.log"
  record_artifact logs/virt-controller.log empty 'no matching controller log lines'
fi

# --- virt-handler on VMI node only ---
handler_pod=''
handler_log="virt-handler-unknown.log"
if [[ -n $vmi_node ]]; then
  handler_pod=$(oc get pods -n "$CNV_NS" -l kubevirt.io=virt-handler -o json 2>/dev/null |
    jq -r --arg node "$vmi_node" \
      '[.items[] | select(.spec.nodeName==$node) | .metadata.name][0] // empty')
  # Sanitize node name for filename
  safe_node=${vmi_node//\//_}
  handler_log="virt-handler-${safe_node}.log"
fi
if [[ -n $handler_pod ]]; then
  {
    oc logs -n "$CNV_NS" "$handler_pod" --all-containers=true --tail="$LOG_TAIL" \
      "${log_since_args[@]}" 2>/dev/null ||
    oc logs -n "$CNV_NS" "$handler_pod" --tail="$LOG_TAIL" \
      "${log_since_args[@]}" 2>/dev/null
  } | grep -Ei 'backup|checkpoint|changed.block|cbt|bitmap|libvirt|quiesc' \
    >"$OUT_DIR/logs/$handler_log"
  if [[ -s $OUT_DIR/logs/$handler_log ]]; then
    record_artifact "logs/$handler_log" ok "pod=$handler_pod node=$vmi_node"
  else
    : >"$OUT_DIR/logs/$handler_log"
    record_artifact "logs/$handler_log" empty "pod=$handler_pod no matching lines"
  fi
else
  : >"$OUT_DIR/logs/$handler_log"
  record_artifact "logs/$handler_log" error "no virt-handler on node=${vmi_node:-unknown}"
fi

# --- virt-launcher describe + compute logs ---
if [[ -n $launcher_pod ]]; then
  oc describe pod -n "$NAMESPACE" "$launcher_pod" >"$OUT_DIR/logs/virt-launcher-describe.txt" 2>/dev/null
  if [[ -s $OUT_DIR/logs/virt-launcher-describe.txt ]]; then
    record_artifact logs/virt-launcher-describe.txt ok "pod=$launcher_pod"
  else
    record_artifact logs/virt-launcher-describe.txt empty
  fi
  oc logs -n "$NAMESPACE" "$launcher_pod" -c compute --tail="$LOG_TAIL" \
    "${log_since_args[@]}" >"$OUT_DIR/logs/virt-launcher-compute.log" 2>/dev/null
  if [[ -s $OUT_DIR/logs/virt-launcher-compute.log ]]; then
    record_artifact logs/virt-launcher-compute.log ok "pod=$launcher_pod"
  else
    : >"$OUT_DIR/logs/virt-launcher-compute.log"
    record_artifact logs/virt-launcher-compute.log empty "pod=$launcher_pod"
  fi
else
  # Fallback: describe by label (may include other launchers in NS)
  oc describe pod -n "$NAMESPACE" -l kubevirt.io=virt-launcher \
    >"$OUT_DIR/logs/virt-launcher-describe.txt" 2>/dev/null
  record_artifact logs/virt-launcher-describe.txt error "launcher pod for $VM not found"
  : >"$OUT_DIR/logs/virt-launcher-compute.log"
  record_artifact logs/virt-launcher-compute.log error "launcher pod for $VM not found"
fi

# --- hp-volume-* hotplug helpers (if still present) ---
hp_json=$(oc get pods -n "$NAMESPACE" -o json 2>/dev/null |
  jq --arg vm "$VM" '[.items[] | select(.metadata.name|test("^hp-volume-")) | {name:.metadata.name,node:.spec.nodeName,phase:.status.phase,labels:.metadata.labels}]')
printf '%s\n' "${hp_json:-[]}" >"$OUT_DIR/cluster/hp-volume-pods.json"
if [[ $(jq 'length' <<<"${hp_json:-[]}") -gt 0 ]]; then
  record_artifact cluster/hp-volume-pods.json ok
else
  record_artifact cluster/hp-volume-pods.json empty 'no hp-volume pods present (normal after detach)'
fi

# --- Optional storage depth ---
if [[ $DEPTH == storage ]]; then
  if [[ -n $vmi_node ]]; then
    csi_pod=$(oc get pods -n "$STORAGE_NS" -l app=csi-rbdplugin -o json 2>/dev/null |
      jq -r --arg node "$vmi_node" \
        '[.items[] | select(.spec.nodeName==$node and (.metadata.name|test("provisioner")|not)) | .metadata.name][0] // empty')
    # Prefer nodeplugin DaemonSet pods (not controller)
    if [[ -z $csi_pod ]]; then
      csi_pod=$(oc get pods -n "$STORAGE_NS" -o json 2>/dev/null |
        jq -r --arg node "$vmi_node" \
          '[.items[] | select(.spec.nodeName==$node and (.metadata.name|test("csi-rbdplugin")) and (.metadata.name|test("provisioner")|not)) | .metadata.name][0] // empty')
    fi
    safe_node=${vmi_node//\//_}
    csi_log="csi-rbd-node-${safe_node}.log"
    if [[ -n $csi_pod ]]; then
      oc logs -n "$STORAGE_NS" "$csi_pod" --all-containers=true --tail="$LOG_TAIL" \
        "${log_since_args[@]}" >"$OUT_DIR/storage/$csi_log" 2>/dev/null
      if [[ -s $OUT_DIR/storage/$csi_log ]]; then
        record_artifact "storage/$csi_log" ok "pod=$csi_pod"
      else
        : >"$OUT_DIR/storage/$csi_log"
        record_artifact "storage/$csi_log" empty "pod=$csi_pod"
      fi
    else
      : >"$OUT_DIR/storage/$csi_log"
      record_artifact "storage/$csi_log" error "no csi-rbdplugin on node=$vmi_node"
    fi
  else
    record_artifact storage/csi-rbd-node.log error 'VMI node unknown'
  fi

  oc get storagecluster -n "$STORAGE_NS" -o json 2>/dev/null |
    jq '{items: [.items[]? | {name:.metadata.name,phase:.status.phase,conditions:.status.conditions}]}' \
    >"$OUT_DIR/storage/storagecluster-status.json" 2>/dev/null
  if [[ -s $OUT_DIR/storage/storagecluster-status.json ]]; then
    record_artifact storage/storagecluster-status.json ok
  else
    record_artifact storage/storagecluster-status.json error
  fi

  oc get cephcluster -n "$STORAGE_NS" -o json 2>/dev/null |
    jq '{items: [.items[]? | {name:.metadata.name,phase:.status.phase,ceph:.status.ceph,state:.status.state}]}' \
    >"$OUT_DIR/storage/cephcluster-status.json" 2>/dev/null
  if [[ -s $OUT_DIR/storage/cephcluster-status.json ]]; then
    record_artifact storage/cephcluster-status.json ok
  else
    record_artifact storage/cephcluster-status.json error
  fi
fi

# --- Baseline (optional, written by caller before backup apply) ---
if [[ -n $BASELINE_JSON && -r $BASELINE_JSON ]]; then
  cp "$BASELINE_JSON" "$OUT_DIR/baseline.json"
  record_artifact baseline.json ok
fi

# --- Manifest ---
# Use --slurpfile so we never pass JSON through a shell variable (--argjson).
[[ -s $manifest_tmp ]] || printf '%s\n' '[]' >"$manifest_tmp"
jq -n \
  --arg ns "$NAMESPACE" \
  --arg vm "$VM" \
  --arg backup "$BACKUP" \
  --arg tracker "$TRACKER" \
  --arg depth "$DEPTH" \
  --arg since "${SINCE_TIME:-}" \
  --arg collected "$collected_at" \
  --arg node "${vmi_node:-}" \
  --arg launcher "${launcher_pod:-}" \
  --arg handler "${handler_pod:-}" \
  --slurpfile artifacts "$manifest_tmp" \
  '{
    namespace:$ns,
    vm:$vm,
    backup:$backup,
    tracker:$tracker,
    depth:$depth,
    sinceTime:$since,
    collectedAt:$collected,
    vmiNode:$node,
    launcherPod:$launcher,
    virtHandlerPod:$handler,
    artifacts:($artifacts[0] // [])
  }' >"$OUT_DIR/manifest.json"

echo "CBT diagnostics: $OUT_DIR (depth=$DEPTH, artifacts=$(jq 'length' "$manifest_tmp" 2>/dev/null || echo 0))"
exit 0
