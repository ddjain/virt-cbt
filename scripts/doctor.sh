#!/usr/bin/env bash
# Read-only first-run diagnostics for the ODF CBT validator.
set -uo pipefail

CONFIG='config.env'
failures=0
warnings=0
have_oc=0
have_jq=0
config_loaded=0
cluster_ready=0
config_kubeconfig=''
config_namespace=''
config_data_storage_class=''
config_backup_storage_class=''
config_ssh_key=''

usage() {
  echo 'Usage: doctor.sh [--config FILE]' >&2
}

ok() {
  printf 'OK    %s\n' "$*"
}

warn() {
  warnings=$((warnings + 1))
  printf 'WARN  %s\n' "$*"
}

fail() {
  failures=$((failures + 1))
  printf 'FAIL  %s\n' "$*"
}

skip() {
  printf 'SKIP  %s\n' "$*"
}

have() {
  command -v "$1" >/dev/null 2>&1
}

while (($#)); do
  case "$1" in
    --config) CONFIG=${2-}; shift 2;;
    -h|--help) usage; exit 0;;
    *) usage; exit 2;;
  esac
done

if ((BASH_VERSINFO[0] >= 4)); then
  ok "bash ${BASH_VERSINFO[0]} supports validator scripts"
else
  fail "bash 4+ is required; found ${BASH_VERSINFO[0]}"
fi

for tool in oc virtctl kube-burner jq; do
  if have "$tool"; then
    ok "$tool available at $(command -v "$tool")"
  else
    fail "$tool is missing from PATH"
  fi
done
if have oc; then have_oc=1; fi
if have jq; then have_jq=1; fi

if ! have curl && ! have wget; then
  warn 'curl or wget is required only when make bootstrap must download a tool'
fi
if ! have tar; then
  warn 'tar is required only when make bootstrap must install kube-burner'
fi
if ! have sha256sum && ! have shasum && ! have openssl; then
  warn 'a SHA-256 utility is required only when make bootstrap must download a tool'
fi

if [[ ! -r $CONFIG ]]; then
  fail "configuration file is missing or unreadable: $CONFIG (run make init-config)"
else
  config_loaded=1
  while IFS= read -r line || [[ -n $line ]]; do
    case "$line" in
      ''|\#*) continue;;
    esac
    if [[ $line != *=* ]]; then
      fail "invalid configuration line in $CONFIG: $line"
      continue
    fi
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      KUBECONFIG) config_kubeconfig=$value;;
      NAMESPACE) config_namespace=$value;;
      DATA_STORAGE_CLASS) config_data_storage_class=$value;;
      BACKUP_STORAGE_CLASS) config_backup_storage_class=$value;;
      SSH_KEY) config_ssh_key=$value;;
    esac
  done <"$CONFIG"
fi

if ((config_loaded)); then
  if [[ -n $config_kubeconfig && -r $config_kubeconfig ]]; then
    ok "KUBECONFIG is an explicit readable file: $config_kubeconfig"
  else
    fail "KUBECONFIG must be a non-empty readable file in $CONFIG; implicit oc configuration is not used"
  fi

  if [[ -z $config_namespace ]]; then
    fail "NAMESPACE is required in $CONFIG"
  elif [[ $config_namespace == cbt-demo ]]; then
    warn 'NAMESPACE is cbt-demo; choose a unique namespace on a shared cluster'
  else
    ok "NAMESPACE is configured: $config_namespace"
  fi

  if [[ -n $config_data_storage_class ]]; then
    ok "DATA_STORAGE_CLASS is configured: $config_data_storage_class"
  else
    fail "DATA_STORAGE_CLASS is required in $CONFIG"
  fi
  if [[ -n $config_backup_storage_class ]]; then
    ok "BACKUP_STORAGE_CLASS is configured: $config_backup_storage_class"
  else
    fail "BACKUP_STORAGE_CLASS is required in $CONFIG"
  fi

  if [[ -z $config_ssh_key ]]; then
    fail "SSH_KEY is required in $CONFIG; run make generate-keys"
  elif [[ -r $config_ssh_key && -r "$config_ssh_key.pub" ]]; then
    ok "SSH key pair is readable: $config_ssh_key"
  else
    fail "SSH_KEY pair is unreadable: $config_ssh_key (run make generate-keys)"
  fi
fi

check_command() {
  local label=$1
  shift
  if "$@" >/dev/null 2>&1; then
    ok "$label"
  else
    fail "$label"
  fi
}

check_nonempty_resource() {
  local label=$1 result
  shift
  result=$("$@" 2>/dev/null || true)
  if [[ -n $result ]]; then
    ok "$label"
  else
    fail "$label"
  fi
}

check_cluster_permission() {
  local label=$1 verb=$2 resource=$3 answer
  answer=$(oc --kubeconfig "$config_kubeconfig" auth can-i "$verb" "$resource" 2>/dev/null || true)
  if [[ $answer == yes ]]; then
    ok "$label"
  else
    fail "$label"
  fi
}

check_namespace_permission() {
  local label=$1 verb=$2 resource=$3 answer
  answer=$(oc --kubeconfig "$config_kubeconfig" auth can-i "$verb" "$resource" --namespace "$config_namespace" 2>/dev/null || true)
  if [[ $answer == yes ]]; then
    ok "$label"
  else
    fail "$label"
  fi
}

if ((have_oc)) && [[ -n $config_kubeconfig && -r $config_kubeconfig ]]; then
  if oc --kubeconfig "$config_kubeconfig" whoami >/dev/null 2>&1; then
    ok 'oc can authenticate with configured KUBECONFIG'
    cluster_ready=1
  else
    fail 'oc cannot authenticate with configured KUBECONFIG'
  fi
else
  skip 'cluster checks require oc and a readable explicit KUBECONFIG'
fi

if ((cluster_ready)); then
  check_command 'VirtualMachine CRD is installed' oc --kubeconfig "$config_kubeconfig" get crd virtualmachines.kubevirt.io
  check_command 'VirtualMachineBackup CRD is installed' oc --kubeconfig "$config_kubeconfig" get crd virtualmachinebackups.backup.kubevirt.io
  check_command 'VirtualMachineBackupTracker CRD is installed' oc --kubeconfig "$config_kubeconfig" get crd virtualmachinebackuptrackers.backup.kubevirt.io

  if [[ -n $config_data_storage_class ]]; then
    check_command "data storage class exists: $config_data_storage_class" oc --kubeconfig "$config_kubeconfig" get storageclass "$config_data_storage_class"
  fi
  if [[ -n $config_backup_storage_class ]]; then
    check_command "backup storage class exists: $config_backup_storage_class" oc --kubeconfig "$config_kubeconfig" get storageclass "$config_backup_storage_class"
  fi
  check_nonempty_resource 'ODF StorageCluster exists' oc --kubeconfig "$config_kubeconfig" get storagecluster -n openshift-storage -o name
  check_nonempty_resource 'ODF CephCluster exists' oc --kubeconfig "$config_kubeconfig" get cephcluster -n openshift-storage -o name

  snapshot_class=$(oc --kubeconfig "$config_kubeconfig" get volumesnapshotclass -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -n $snapshot_class ]]; then
    ok "VolumeSnapshotClass exists: $snapshot_class"
  else
    fail 'at least one VolumeSnapshotClass is required'
  fi

  if ((have_jq)); then
    hco_json=$(oc --kubeconfig "$config_kubeconfig" get hyperconverged -A -o json 2>/dev/null || true)
    if [[ -n $hco_json ]] && jq -e 'any(.. | objects; has("changedBlockTrackingLabelSelectors") or has("changedBlockTracking"))' >/dev/null <<<"$hco_json"; then
      ok 'HyperConverged exposes CBT configuration'
    else
      fail 'HyperConverged CBT configuration is missing'
    fi
  else
    skip 'HyperConverged CBT check requires jq'
  fi

  check_cluster_permission 'RBAC allows namespace creation' create namespaces
  check_cluster_permission 'RBAC allows namespace labeling' patch namespaces
  check_namespace_permission 'RBAC allows cloud-init Secret creation' create secrets
  check_namespace_permission 'RBAC allows backup-output PVC creation' create persistentvolumeclaims
  check_namespace_permission 'RBAC allows VirtualMachine creation' create virtualmachines.kubevirt.io
  check_namespace_permission 'RBAC allows backup tracker creation' create virtualmachinebackuptrackers.backup.kubevirt.io
  check_namespace_permission 'RBAC allows VM listing' list virtualmachines.kubevirt.io
  check_namespace_permission 'RBAC allows VMI listing' list virtualmachineinstances.kubevirt.io
  check_namespace_permission 'RBAC allows backup creation' create virtualmachinebackups.backup.kubevirt.io
  check_namespace_permission 'RBAC allows lock ConfigMap creation' create configmaps
  check_namespace_permission 'RBAC allows inspector Pod creation' create pods
fi

if ((failures)); then
  printf 'Doctor: FAIL (%d issue(s), %d warning(s))\n' "$failures" "$warnings" >&2
  exit 1
fi
printf 'Doctor: PASS (%d warning(s))\n' "$warnings"
