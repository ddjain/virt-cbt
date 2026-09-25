# chaos-trigger.sh template

Write this file as `docs/chaos-test/scenario/<folder>/chaos-trigger.sh`.
Adapt the krknctl body to the **user-approved** command from the
`krkn-scenario` step. Keep event-driven triggers for `T-PROG`.

```bash
#!/usr/bin/env bash
# CBT chaos trigger — generated for <SCENARIO_ID> / <folder>
# Spec: ./scenario_spec.md
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/config.env" ]] && set -a && source "$ROOT/config.env" && set +a

: "${KUBECONFIG:?set KUBECONFIG}"
NS="${NS:-${NAMESPACE:?set NS or NAMESPACE}}"
VM="${VM:?set VM (e.g. fedora-cbt-1)}"
TRACKER="${TRACKER:-${VM}-tracker}"
BACKUP_PVC="${BACKUP_PVC:-${VM}-backup-output}"
VMB_CHAOS="${VMB_CHAOS:-${VM}-chaos-$(date +%s)}"
CNV_NS="${CNV_NS:-openshift-cnv}"
TRIGGER_TIMEOUT="${TRIGGER_TIMEOUT:-600}"
COMPLETION_TIMEOUT="${COMPLETION_TIMEOUT:-600}"
MODE="${MODE:-Incremental}"   # Full|Incremental — informational / manifest choice

command -v oc >/dev/null
command -v krknctl >/dev/null
command -v jq >/dev/null

echo "scenario=<SCENARIO_ID> ns=$NS vm=$VM vmb=$VMB_CHAOS mode=$MODE"
echo "kubeconfig=$KUBECONFIG"

# --- resolve target (example: virt-controller) ---
# Replace with the live resolution from the skill run.
TARGET_POD="$(oc get pod -n "$CNV_NS" -l kubevirt.io=virt-controller \
  -o jsonpath='{.items[0].metadata.name}')"
echo "target=$TARGET_POD"

# --- Phase A: create chaos VMB (Push) ---
# Prefer applying a minimal VirtualMachineBackup CR. Adjust apiVersion/fields
# to match what `make backup` / `make cbt-backup` emit on this cluster.
oc delete virtualmachinebackup "$VMB_CHAOS" -n "$NS" --ignore-not-found --wait=true
# TODO: oc apply -f - <<EOF ... VirtualMachineBackup named $VMB_CHAOS ...
# Until CR apply is filled from live examples, callers may pre-create VMB_CHAOS
# and export it before invoking this script.

trigger_command=$(cat <<EOF
oc get virtualmachinebackup ${VMB_CHAOS} -n ${NS} -o json | jq -e '.status.conditions // [] | any(.[]; .type == "Progressing" and .status == "True")'
EOF
)

echo "INJECT_ARMED $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "trigger: wait until VirtualMachineBackup/$VMB_CHAOS Progressing=True (fail on timeout)"

# --- Phase B: event-driven krknctl (replace flags with approved command) ---
set +e
krknctl run pod-scenarios \
  --kubeconfig "$KUBECONFIG" \
  --namespace "$CNV_NS" \
  --name-pattern "^${TARGET_POD}$" \
  --disruption-count 1 \
  --wait-duration 30 \
  --iterations 1 \
  --triggers-on-timeout fail \
  --triggers-timeout "$TRIGGER_TIMEOUT" \
  --triggers-interval 5 \
  --trigger-command "$trigger_command" \
  --trigger-expected-rc 0
krkn_rc=$?
set -e
echo "KRKN_DONE rc=$krkn_rc $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# --- wait for VMB terminal ---
deadline=$((SECONDS + COMPLETION_TIMEOUT))
while ((SECONDS < deadline)); do
  if oc get virtualmachinebackup "$VMB_CHAOS" -n "$NS" -o json 2>/dev/null |
      jq -e '(.status.conditions // []) | any(.[]; (.type == "Done" or .type == "Complete" or .type == "Failed") and .status == "True")' >/dev/null; then
    echo "VMB_TERMINAL $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    exit "$krkn_rc"
  fi
  sleep 5
done
echo "ERROR: VirtualMachineBackup/$VMB_CHAOS not terminal within ${COMPLETION_TIMEOUT}s" >&2
exit 1
```

## Notes for the agent

- Swap `pod-scenarios` / selectors for the scenario under test.
- For non-`T-PROG` windows, remove the `--trigger-*` block and document the
  manual arming order in script comments.
- Prefer copying the **exact** approved argv from the approval gate into the
  script rather than re-deriving flags.
- After the first successful live run, consider tightening the VMB apply
  section using a real CR dumped from `make backup` / `oc get vmb -o yaml`.
