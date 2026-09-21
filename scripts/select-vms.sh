#!/usr/bin/env bash
set -euo pipefail

KUBECONFIG_ARG=''; NAMESPACE=''; BASE_SELECTOR=''; MODE=''; VALUE=''
usage() { echo 'Usage: select-vms.sh --kubeconfig PATH --namespace NS --base-selector SEL (--vms CSV|--count N|--selector SEL|--all)' >&2; }
while (($#)); do
  case "$1" in
    --kubeconfig) KUBECONFIG_ARG=${2-}; shift 2;;
    --namespace) NAMESPACE=${2-}; shift 2;;
    --base-selector) BASE_SELECTOR=${2-}; shift 2;;
    --vms) [[ -z $MODE ]] || { usage; exit 2; }; MODE=vms; VALUE=${2-}; shift 2;;
    --count) [[ -z $MODE ]] || { usage; exit 2; }; MODE=count; VALUE=${2-}; shift 2;;
    --selector) [[ -z $MODE ]] || { usage; exit 2; }; MODE=selector; VALUE=${2-}; shift 2;;
    --all) [[ -z $MODE ]] || { usage; exit 2; }; MODE=all; shift;;
    -h|--help) usage; exit 0;; *) usage; exit 2;;
  esac
done
[[ -n $NAMESPACE && -n $BASE_SELECTOR && -n $MODE ]] || { usage; exit 2; }
case "$MODE" in count) [[ $VALUE =~ ^[1-9][0-9]*$ ]] || { echo 'ERROR: count must be positive' >&2; exit 2; };; vms) [[ -n $VALUE ]] || { echo 'ERROR: VMS cannot be empty' >&2; exit 2; };; selector) [[ $VALUE == *=* ]] || { echo 'ERROR: selector must be key=value' >&2; exit 2; };; esac
export KUBECONFIG="$KUBECONFIG_ARG"
json=$(oc get vm -n "$NAMESPACE" -l "$BASE_SELECTOR" -o json)
case "$MODE" in
  all) jq -r '.items[].metadata.name' <<<"$json" | sort;;
  count) total=$(jq '.items|length' <<<"$json"); (( VALUE <= total )) || { echo "ERROR: count $VALUE exceeds VM pool $total" >&2; exit 1; }; jq -r '.items[].metadata.name' <<<"$json" | sort | jq -Rrsc --argjson n "$VALUE" 'split("\n")|map(select(length>0))|.[0:$n][]';;
  selector) jq -r --arg s "$VALUE" '.items[] | select((.metadata.labels // {})[$s|split("=")[0]] == ($s|split("=")[1])) | .metadata.name' <<<"$json" | sort;;
  vms)
    pool=$(jq -r '.items[].metadata.name' <<<"$json")
    declare -A seen=(); IFS=',' read -r -a names <<<"$VALUE"
    for raw in "${names[@]}"; do name=${raw//[[:space:]]/}; [[ -n $name ]] || { echo 'ERROR: empty VM name' >&2; exit 1; }; [[ -z ${seen[$name]+x} ]] || { echo "ERROR: duplicate VM $name" >&2; exit 1; }; seen[$name]=1; grep -Fxq "$name" <<<"$pool" || { echo "ERROR: VM $name is not in owned pool" >&2; exit 1; }; printf '%s\n' "$name"; done;;
esac
