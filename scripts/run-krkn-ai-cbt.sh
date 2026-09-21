#!/usr/bin/env bash
set -euo pipefail

CONFIG=''
OUTPUT='./krkn-ai-cbt-results'
VMB_NAME=''
NAMESPACE='cbt-demo'
SEED='42'
TIMEOUT='600'

usage() {
  printf '%s\n' "Usage: $0 --config FILE --vmb NAME [--output DIR] [--namespace NS] [--seed N] [--timeout SEC]"
}

while (($#)); do
  case "$1" in
    --config) CONFIG=${2:?missing value for --config}; shift 2 ;;
    --output) OUTPUT=${2:?missing value for --output}; shift 2 ;;
    --vmb) VMB_NAME=${2:?missing value for --vmb}; shift 2 ;;
    --namespace) NAMESPACE=${2:?missing value for --namespace}; shift 2 ;;
    --seed) SEED=${2:?missing value for --seed}; shift 2 ;;
    --timeout) TIMEOUT=${2:?missing value for --timeout}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

: "${KUBECONFIG:?set KUBECONFIG before running this script}"
KRKN_AI_KUBECONFIG=${KRKN_AI_KUBECONFIG:-$KUBECONFIG}
[[ -n "$CONFIG" && -n "$VMB_NAME" ]] || { usage >&2; exit 2; }
command -v oc >/dev/null || { echo 'oc is required' >&2; exit 127; }
if command -v krkn_ai >/dev/null; then
  KRKN_AI=(krkn_ai)
elif [[ -n "${KRKN_AI_REPO:-}" ]] && command -v uv >/dev/null; then
  KRKN_AI=(uv run --project "$KRKN_AI_REPO" krkn_ai)
else
  echo 'krkn_ai is required; install it or set KRKN_AI_REPO to its checkout' >&2
  exit 127
fi

printf 'Waiting for VirtualMachineBackup/%s to enter Progressing=True in %s...\n' "$VMB_NAME" "$NAMESPACE"
end=$((SECONDS + TIMEOUT))
while ((SECONDS < end)); do
  if oc get virtualmachinebackup "$VMB_NAME" -n "$NAMESPACE" -o json 2>/dev/null \
      | jq -e '.status.conditions // [] | any(.[]; .type == "Progressing" and .status == "True")' >/dev/null; then
    break
  fi
  sleep 1
done

if ((SECONDS >= end)); then
  echo "Timed out waiting for Progressing=True; refusing to run chaos outside the backup window" >&2
  exit 1
fi

exec "${KRKN_AI[@]}" run \
  --kubeconfig "$KRKN_AI_KUBECONFIG" \
  --config "$CONFIG" \
  --output "$OUTPUT" \
  --runner-type krknctl \
  --seed "$SEED"
