# Diagnostics manifest omits the full VMI snapshot

## Description

`cbt-diagnostics-collect.sh` writes `cluster/vmi-full.json` containing the complete VirtualMachineInstance object, but does not add that file to `manifest.json`. The collector reports the manifest-entry count as `artifacts`; therefore the count under-reports files present in each forensic bundle and the manifest is not a complete artifact inventory.

## Environment

- Darwin arm64; GNU Bash 5.3.20
- OpenShift 4.22.14; ODF 4.21.12
- Validator namespace `qa-cbt-exhaustive-20260925-0305`; VM `qa-cbt-exhaustive-2`
- Full and Incremental backups physically verified and terminal

## Reproduction

```bash
make cbt-diagnostics CONFIG=/tmp/virt-cbt-full-20260925-0305.env \
  VMS=qa-cbt-exhaustive-2
```

Current run: `reports/run-20260925T033104Z-cbt-diagnostics/`.

## Expected

Every diagnostic file written by the collector is represented in `manifest.json`, and the displayed `artifacts` count matches the file inventory.

## Actual

For each Full and Incremental bundle, the command reported `artifacts=19` and the manifest contained 19 entries. The bundle directory contains `cluster/vmi-full.json` in addition to the listed files, but neither manifest has an entry for it. The file is a complete VMI JSON snapshot, not the smaller `vmi-cbt.json` summary.

## Errors / logs

- Run log: `reports/run-20260925T033104Z-cbt-diagnostics/run.log` (19 reported artifacts per bundle).
- Full manifest: `reports/run-20260925T033104Z-cbt-diagnostics/diagnostics/qa-cbt-exhaustive-2/qa-cbt-exhaustive-2-full/manifest.json`.
- Incremental manifest: `reports/run-20260925T033104Z-cbt-diagnostics/diagnostics/qa-cbt-exhaustive-2/qa-cbt-exhaustive-2-incremental/manifest.json`.
- `cluster/vmi-full.json` exists in both bundle directories; each manifest's `artifacts[]` has 19 entries and no `cluster/vmi-full.json` item.

## Source references

- `scripts/cbt-diagnostics-collect.sh:103-106`: writes `cluster/vmi-full.json` and `cluster/vmi-cbt.json`.
- `scripts/cbt-diagnostics-collect.sh:115`: records only `vmi-cbt.json`.
- `scripts/cbt-diagnostics-collect.sh:364`: reports the manifest-array length as the artifact count.

## Root cause

The full VMI snapshot is written directly with `printf` but never passed to `record_artifact`; the manifest inventory and artifact count are therefore incomplete.

## Suggested fix

Record `cluster/vmi-full.json` in the manifest after writing it, and assert during collection that every emitted artifact path appears exactly once in the manifest. Re-run both core and storage-depth collection and compare the declared count with the generated files.

## Current-session retest

The same discrepancy occurred in both modes: the `core` Make run reported 19 artifacts but wrote an unlisted `cluster/vmi-full.json`; direct `--depth storage` reported 22 and wrote that same unlisted file (23 physical files excluding `manifest.json`). The VMI dump had the correct namespace, VM name, Running phase, CBT Enabled state, and current launcher node. No cluster resource was modified by collection.
