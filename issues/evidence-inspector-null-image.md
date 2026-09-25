# Evidence checker treats a missing launcher image as valid

## Description

When a namespace has no matching `virt-launcher` pod, the image lookup can yield the literal string `null`. The script checks only whether the result is empty, then attempts to create an evidence pod. A missing namespace therefore returns an API create error (exit 1) instead of the documented `INCONCLUSIVE`/exit 2; an existing namespace without a launcher can leave a pending inspector pod until its wait timeout.

## Environment

- Darwin arm64 workstation; GNU Bash 5.3.20
- OpenShift cluster, `system:admin`; server OpenShift 4.22.14
- No CBT backup artifacts in the configured density namespace at test time

## Reproduction

Missing namespace:

```bash
KUBECONFIG=<configured kubeconfig> scripts/cbt-evidence-check.sh \
  --namespace qa-nonexistent-namespace --vm vm --backup missing --expected Full
```

Observed exit code: `1`.

Existing namespace with no launcher (`openshift-config`):

```bash
KUBECONFIG=<configured kubeconfig> scripts/cbt-evidence-check.sh \
  --namespace openshift-config --vm qa-vm --backup qa-backup --expected Full
```

The tool call exceeded its 60-second command timeout. Independently, the resulting `qa-backup-evidence` pod was observed `0/1 Pending` in `openshift-config` and was deleted immediately as test cleanup.

## Expected

The checker should emit one JSON `inspectable:false` result and exit `2` before creating an inspector pod whenever no usable launcher image is available.

## Actual

- Missing namespace: `Error from server (NotFound): error when creating "STDIN": namespaces "qa-nonexistent-namespace" not found`; exit `1`.
- Existing namespace without a launcher: an inspector pod was created and remained Pending. The pod was removed with `oc delete pod qa-backup-evidence -n openshift-config --wait=true --timeout=60s`.
- The image-selection expression was independently evaluated against `openshift-config`; it printed `null` and returned jq exit `1` for the empty match.

## Errors / logs

The API-create error above is the missing-namespace output. The temporary pod was observed by `oc get pod qa-backup-evidence -n openshift-config -o wide` as `0/1 Pending`, then deletion returned `pod "qa-backup-evidence" deleted from openshift-config namespace`. No test pod remains (verified after deletion).

## Source references

- `scripts/cbt-evidence-check.sh:78-84`: `jq -er` lookup followed by `[[ -z $image ]]`; failed jq selection can leave the string `null`, which is non-empty.
- `scripts/cbt-evidence-check.sh:101-119`: the unchecked value is interpolated into a new pod and the script waits for it.

## Root cause

The lookup captures jq's textual `null` output even though `jq -e` returns non-zero. The `|| true` suppresses that status; the following emptiness check recognizes only `''`, not the JSON null sentinel. The script proceeds as if it had found a valid container image.

## Suggested fix

Use an empty-on-no-match jq expression (for example, `first // empty`) and validate that the resulting image is non-empty and not `null` before `oc apply`. Keep the documented exit-2 JSON response for this condition.

## Post-fix retest

On 2026-09-25, a newly created, validator-owned empty namespace with no launcher pod was passed to `cbt-evidence-check.sh` with `--timeout 5`. The checker emitted one JSON object with `inspectable:false` and reason `no virt-launcher pod ...`, exited `2`, and created no pod. `oc get pods` returned no resources; the namespace was removed by `make density-teardown` and independently verified `NotFound`. The null-image/pending-inspector defect is fixed.

Current-session retest repeated the empty-namespace case in `qa-cbt-no-launcher-20260925-0305`: one `inspectable:false` JSON result, exit 2, no evidence pod, and ownership-checked namespace deletion followed by `NotFound`.
