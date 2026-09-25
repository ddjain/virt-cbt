# CBT diagnostics reports PASS when no backups exist

## Description

`cbt-diagnostics` reports a successful collection even when neither Full nor Incremental backup exists and no diagnostic artifact was collected. Its PASS result is a false success for the documented operation, which is specifically a forensic dump for existing backups.

## Environment

- Darwin arm64 workstation; GNU Bash 5.3.20
- OpenShift identity: `system:admin`
- Namespace: `cbt-gcp-20260923`
- Live pool: 10 Ready/Running CBT-enabled VMs

## Reproduction

```bash
make cbt-diagnostics VMS=fedora-cbt-1
```

## Expected

With no backup resources, report `N/A`/`INCONCLUSIVE` or a failure indicating no backups were available; do not claim diagnostics were collected.

## Actual

The run log reported:

```text
Skip fedora-cbt-1-full (not found)
Skip fedora-cbt-1-incremental (not found)
fedora-cbt-1 PASS — Diagnostics collected for existing backups
```

The generated summary reported `Status: OK`, `Passed: 1`, `Failed: 0`, `Inconclusive: 0`. Exit code: `0`.

Independent cluster check: `oc get virtualmachinebackup,virtualmachinebackuptracker -n cbt-gcp-20260923 -o wide` returned only 10 empty trackers and no `VirtualMachineBackup` resources. `make status ALL=1` showed Full, Incremental, and checkpoint as `-` for all VMs.

## Errors / logs

No command error. Run directory: `reports/run-20260924T190608Z-cbt-diagnostics/`; the log explicitly records both backups as not found, while the summary is green.

## Source references

- `scripts/odf-vm-validator.sh:406-424`, especially lines 415-422: missing backups are skipped, then unconditionally recorded as PASS.
- `README.md:242-246`: diagnostics is described as a dump for existing Full/Incremental backups.

## Root cause

The loop treats a successful no-op (both resources absent) as equivalent to collecting one or more diagnostic bundles. The result record does not track whether any backup was found or any artifact was written.

## Suggested fix

Count existing backups and collected bundles. If none exist, emit a distinct `N/A`/`INCONCLUSIVE` result (or non-zero exit) with a clear message rather than `PASS — Diagnostics collected`.

## Post-fix retest

On 2026-09-25, `make cbt-diagnostics CONFIG=/tmp/virt-cbt-retest-pool-20260925.env VMS=fedora-cbt-1` logged both backups as not found, recorded `INCONCLUSIVE` with `No Full or Incremental backup found to diagnose`, and exited non-zero (Make exit `2`). `summary.json` contained `passed=0`, `failed=0`, `inconclusive=1`; independent `oc` listed ten empty trackers and no VMBs. The false PASS is fixed.

Current-session retest: `reports/run-20260925T030733Z-cbt-diagnostics/summary.json` records `INCONCLUSIVE` (`passed=0`, `failed=0`, `inconclusive=1`) for `qa-cbt-exhaustive-2` with no backups; Make exited 2. No backup was created by diagnostics.

