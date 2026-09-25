# CBT result classifier has an invalid jq expression

## Description

`classify-cbt-result.sh` fails to compile its jq classification filter. The `safe_full_fallback` branch uses `and not failed`, which is invalid jq syntax. As a result, classification fails even when the VMB/VM/tracker and physical qcow2 evidence are available.

## Environment

- Darwin arm64; GNU Bash 5.3.20; jq available
- OpenShift 4.22.14; namespace `qa-cbt-mktemp-a-20260925`
- `VirtualMachineBackup/qa-cbt-a-1-incremental` was `Done=True`, type `Incremental`; VM/VMI Running and CBT Enabled; tracker advanced; evidence JSON reported physical `Incremental`, `match:true`.

## Reproduction

```bash
KUBECONFIG=/Users/darjain/projects/redhat-chaos/virt-cbt/kubeconfig \
NAMESPACE=qa-cbt-mktemp-a-20260925 \
VM_NAME=qa-cbt-a-1 \
VMB_NAME=qa-cbt-a-1-incremental \
TRACKER_NAME=qa-cbt-a-1-tracker \
BACKUP_PVC=qa-cbt-a-1-backup-output \
EXPECTED_TYPE=Incremental \
OUTPUT=/tmp/qa-cbt-classify-incremental.json \
scripts/classify-cbt-result.sh
```

## Expected

Write a classification JSON based on the live VMB/VM/tracker and qcow2 header, then return exit `0` for `pass` on this completed, physically Incremental backup.

## Actual

`jq` failed to compile the filter and the script exited `3`:

```text
jq: error: syntax error, unexpected IDENT (Unix shell quoting issues?) at <top-level>, line 16:
    elif (physical_type == "Full") and vmi_running and not failed then "safe_full_fallback"
jq: error: Possibly unterminated 'if' statement
```

No classification JSON was written. The independent evidence check remained `physicalType=Incremental`, `match=true`; the VMB and tracker were terminal/current.

## Errors / logs

The direct classifier command returned exit code `3`. `OUTPUT=/tmp/qa-cbt-classify-incremental.json` was empty. No cluster resource was modified by classification.

- Current-session retest against `qa-cbt-exhaustive-2-incremental` repeated the same jq parser error and exit `3`; `/tmp/qa-cbt-classify-current.json` is 0 bytes. `make cbt-evidence` had independently confirmed the same VMB artifact physically Incremental (`match=true`), and `oc`/`kubectl` showed terminal VMB and matching tracker checkpoint.

## Source references

- `scripts/classify-cbt-result.sh:70-76`: classification jq filter.
- `scripts/classify-cbt-result.sh:98-103`: expected classification exit mapping.
- `scripts/run-cbt-krkn-scenario.sh:116-138`: wrapper consumes classifier status; not dynamically executed because Krkn execution was explicitly excluded.

## Root cause

The jq predicate `and not failed` is not accepted by jq's grammar as an operand expression. This prevents compilation of the entire filter, regardless of which classification branch would be selected.

## Suggested fix

Parenthesize the negation as a jq expression (for example, `and (failed | not)`) and add direct tests for `pass`, `safe_full_fallback`, `bounded_failure`, `inconclusive`, and `fail`. In the Krkn wrapper, treat unexpected classifier exit codes as failures instead of falling through to the chaos runner's return code.
