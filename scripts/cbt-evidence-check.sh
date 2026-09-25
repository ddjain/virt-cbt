#!/usr/bin/env bash
set -euo pipefail

# Determines whether a VirtualMachineBackup's resulting qcow2 artifact is
# physically a Full (self-contained) or an Incremental (CBT-chained) backup,
# by reading the artifact's own qemu-img metadata — never
# VirtualMachineBackup/.status or controller logs, which are
# controller-reported and can be stale, racy, or simply wrong when chaos is
# injected against virt-handler, virt-launcher, the CSI plugin, or the node
# itself.
#
# Ground truth used here: KubeVirt writes a genuine CBT incremental as a
# qcow2 whose backing file is the disk's CBT bitmap overlay
# (.../libvirt/qemu/cbt/<disk>.qcow2) — its contents only make sense relative
# to that tracked dirty bitmap. A Full backup is self-contained: no backing
# file at all. This is decided at file-creation time and is unaffected by
# anything that happens to pods/controllers afterwards, so it survives the
# virt-launcher pod (or even the node) being killed by chaos right after the
# backup completes. Reading it only needs `qemu-img info` (no --backing-chain)
# on the backup PVC — that call reads the qcow2 header and does NOT need to
# open the backing file, so it never touches the live CBT overlay PVC.
#
# Safety note (learned the hard way): this script deliberately never mounts
# the VM's CBT-overlay/state PVC ("persistent-state-for-<vm>-...") or the
# VM's data PVC into a second pod. On this class of cluster, attaching an
# RBD-backed PVC to a second pod on the SAME node as a running VM was
# observed to disrupt that node's other RBD-backed mounts badly enough to
# pause the live VM with a low-level I/O error — even when the second mount
# was read-only and a logically unrelated PVC. The evidence pod here only
# ever mounts the backup-output PVC (never attached to the live VM's own
# pod spec — it's hotplugged transiently by the backup controller and
# detached again once the backup completes), and is explicitly kept off the
# VM's current node as defense in depth.
#
# Usage:
#   cbt-evidence-check.sh --namespace NS --vm VM --backup NAME \
#     --expected Full|Incremental [--backup-pvc PVC] [--timeout SECONDS]
#
# Prints one JSON object to stdout and exits:
#   0 — physical evidence matches --expected
#   1 — inspectable, but physical type does not match --expected
#   2 — uninspectable (pod/artifact/qemu-img); treat as INCONCLUSIVE

NAMESPACE='' VM='' BACKUP='' EXPECTED='' BACKUP_PVC='' TIMEOUT=${TIMEOUT:-300}

usage() { printf '%s\n' "Usage: $0 --namespace NS --vm VM --backup NAME --expected Full|Incremental [--backup-pvc PVC] [--timeout SECONDS]"; }

emit_inconclusive() {
  local reason=$1
  echo "ERROR: $reason" >&2
  jq -n --arg vm "$VM" --arg name "$BACKUP" --arg expected "$EXPECTED" --arg reason "$reason" \
    '{vm:$vm,backup:$name,expectedType:$expected,physicalType:"Unknown",backingFile:"",artifactPath:"",allocatedDataBytes:null,match:false,inspectable:false,reason:$reason}'
  exit 2
}

while (($#)); do
  case "$1" in
    --namespace) NAMESPACE=${2:?}; shift 2 ;;
    --vm) VM=${2:?}; shift 2 ;;
    --backup) BACKUP=${2:?}; shift 2 ;;
    --expected) EXPECTED=${2:?}; shift 2 ;;
    --backup-pvc) BACKUP_PVC=${2:?}; shift 2 ;;
    --timeout) TIMEOUT=${2:?}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ -n $NAMESPACE && -n $VM && -n $BACKUP && -n $EXPECTED ]] || { usage >&2; exit 2; }
[[ $EXPECTED == Full || $EXPECTED == Incremental ]] || { echo 'ERROR: --expected must be Full or Incremental' >&2; exit 2; }
BACKUP_PVC=${BACKUP_PVC:-$VM-backup-output}
command -v oc >/dev/null || { echo 'ERROR: oc is required' >&2; exit 127; }
command -v jq >/dev/null || { echo 'ERROR: jq is required' >&2; exit 127; }

pod="${BACKUP}-evidence"
cleanup() { oc delete pod "$pod" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true; }
trap cleanup EXIT

image=$(oc get pods -n "$NAMESPACE" -o json 2>/dev/null | jq -r --arg prefix "virt-launcher-$VM-" \
  '([.items[] | select(.metadata.name | startswith($prefix)) | .spec.containers[] | select(.name=="compute") | .image][0] // empty)' 2>/dev/null) || true
if [[ -z ${image:-} || $image == null ]]; then
  image=$(oc get pods -n "$NAMESPACE" -o json 2>/dev/null | jq -r \
    '([.items[] | select(.metadata.name | startswith("virt-launcher-")) | .spec.containers[] | select(.name=="compute") | .image][0] // empty)' 2>/dev/null) || true
fi
[[ -n ${image:-} && $image != null ]] || emit_inconclusive "no virt-launcher pod in namespace $NAMESPACE to source a qemu-img-capable image"

# Keep the inspector off the VM's current node: attaching the backup PVC on
# the same node the VM's disks are already mapped on is what triggered a
# live I/O error during testing (see safety note above). Best-effort only —
# if the VM/launcher can't be found, proceed without the exclusion.
avoid_node=$(oc get vmi "$VM" -n "$NAMESPACE" -o jsonpath='{.status.nodeName}' 2>/dev/null || true)
affinity=''
if [[ -n $avoid_node ]]; then
  affinity="  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - {key: kubernetes.io/hostname, operator: NotIn, values: [$avoid_node]}"
fi

oc delete pod "$pod" -n "$NAMESPACE" --ignore-not-found >/dev/null
cat <<EOF | oc apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: $pod, namespace: $NAMESPACE}
spec:
  restartPolicy: Never
$affinity
  securityContext: {runAsNonRoot: true, runAsUser: 107, runAsGroup: 107, seccompProfile: {type: RuntimeDefault}}
  containers:
  - name: inspect
    image: "$image"
    command: ["/bin/sh", "-c", "sleep 600"]
    securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: ["ALL"]}}
    volumeMounts: [{name: backup, mountPath: /proof, readOnly: true}]
  volumes: [{name: backup, persistentVolumeClaim: {claimName: $BACKUP_PVC}}]
EOF
oc wait --for=condition=Ready "pod/$pod" -n "$NAMESPACE" --timeout="${TIMEOUT}s" >/dev/null || \
  emit_inconclusive "evidence inspector pod for $BACKUP did not become Ready"

# Require the artifact directory that matches this VMB's checkpointName.
# Reusing the same VirtualMachineBackup name (delete + recreate) leaves older
# checkpoint dirs on the backup PVC; picking "newest by sort" can attribute a
# later Incremental to an earlier Full (or vice versa) — so we never fall back.
checkpoint=$(oc get virtualmachinebackup "$BACKUP" -n "$NAMESPACE" -o jsonpath='{.status.checkpointName}' 2>/dev/null || true)
[[ -n $checkpoint ]] || emit_inconclusive "VirtualMachineBackup/$BACKUP has no status.checkpointName; cannot locate artifact safely"
path=$(oc exec -n "$NAMESPACE" "$pod" -c inspect -- sh -c \
  "test -f /proof/$VM/$checkpoint/${BACKUP}-datadisk.qcow2 && echo /proof/$VM/$checkpoint/${BACKUP}-datadisk.qcow2" 2>/dev/null) || true
[[ -n ${path:-} ]] || emit_inconclusive "no backup artifact at /proof/$VM/$checkpoint/${BACKUP}-datadisk.qcow2 in PVC $BACKUP_PVC"

# A pod that just transitioned to Ready can briefly see an incompletely
# settled RWO mount right after a prior inspector pod released the same
# backup PVC (rapid unmount/mount churn between consecutive evidence
# checks) — qemu-img then spuriously fails to resolve the backing file.
# Retry a few times before treating it as a real anomaly.
qemu_err=$(mktemp)
trap 'rm -f "$qemu_err"; cleanup' EXIT
qemu_img_retry() {
  local out='' rc=1 attempt=0
  : >"$qemu_err"
  until ((rc == 0)) || ((attempt >= 5)); do
    ((attempt+=1))
    if out=$(oc exec -n "$NAMESPACE" "$pod" -c inspect -- qemu-img "$@" 2>"$qemu_err"); then
      rc=0
    else
      rc=$?
      sleep 3
    fi
  done
  if ((rc != 0)); then
    echo "ERROR: 'qemu-img $*' failed on $path after $attempt attempts" >&2
    cat "$qemu_err" >&2 2>/dev/null || true
    return 1
  fi
  printf '%s' "$out"
}

# Only ever `qemu-img info` (no --backing-chain): it reads the qcow2 header
# — including the backing-filename string — without needing to open the
# backing file, so it never requires touching the live CBT-overlay PVC.
info=$(qemu_img_retry info --output=json --force-share "$path") || \
  emit_inconclusive "qemu-img info failed for $path after retries"
backing=$(jq -r '.["backing-filename"] // empty' <<<"$info")
if [[ -n $backing && $backing =~ /libvirt/qemu/cbt/.*\.qcow2$ ]]; then
  physical_type=Incremental
elif [[ -z $backing ]]; then
  physical_type=Full
else
  physical_type=Anomalous
fi

# Allocated-bytes sizing is informational only and is intentionally omitted
# for Incremental artifacts: computing it accurately requires opening the
# backing chain (the live CBT-overlay PVC), which this script refuses to
# mount for the safety reasons documented above. For Full artifacts there is
# no backing file to open, so `qemu-img map` is safe to run.
bytes=null
if [[ $physical_type == Full ]]; then
  map_out=$(qemu_img_retry map --output=json --force-share "$path") && \
    bytes=$(jq '[.[] | select(.data == true and .depth == 0) | .length] | add // 0' <<<"$map_out")
fi

match=false
[[ $physical_type == "$EXPECTED" ]] && match=true

jq -n --arg vm "$VM" --arg name "$BACKUP" --arg expected "$EXPECTED" \
  --arg physical "$physical_type" --arg backing "$backing" --arg path "$path" \
  --argjson bytes "$bytes" --argjson match "$match" \
  '{vm:$vm,backup:$name,expectedType:$expected,physicalType:$physical,backingFile:$backing,artifactPath:$path,allocatedDataBytes:$bytes,match:$match,inspectable:true}'

[[ $match == true ]]
