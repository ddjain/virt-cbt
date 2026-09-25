# Persisted run summaries misidentify the executed command

## Description

Four retained operation reports have a `summary.json.command` value of `e2e` even though each report directory, `runId`, and `run.log` identify a different command. This makes the command field and `make report` output unreliable for these records. The physical evidence JSON files themselves report matching Full/Incremental header evidence; the internal command label is the inconsistency.

## Environment

- Repository reports in `reports/` for namespace `cbt-gcp-20260923`
- Current workstation: Darwin arm64, GNU Bash 5.3.20
- Current cluster state was independently queried later: 10 Ready/Running CBT-enabled VMs, no `VirtualMachineBackup` objects, and empty tracker checkpoints. The current namespace was created at `2026-09-24T18:49:52Z`, after these runs; its new generation explains why historical VMBs are absent now. Historical backup artifacts are not independently inspectable from current cluster resources.

## Reproduction / evidence

Inspect these persisted records:

- `reports/run-20260924T181334Z-backup/summary.json`: `runId` ends in `-backup`, `command` is `e2e`; its `run.log` says `[TEST] ... backup fedora-cbt-1` and ends with `Command: e2e`.
- `reports/run-20260924T182226Z-backup/summary.json`: `runId` ends in `-backup`, `command` is `e2e`; its `run.log` says `[TEST] ... backup fedora-cbt-1` and ends with `Command: e2e`.
- `reports/run-20260924T182520Z-cbt-backup/summary.json`: `runId` ends in `-cbt-backup`, `command` is `e2e`; its result message is `Incremental backup completed`.
- `reports/run-20260924T183045Z-verify/summary.json`: `runId` ends in `-verify`, `command` is `e2e`; its `run.log` says `[TEST] ... verify fedora-cbt-1` and its summary text says `Command: e2e`.

`make report` selected the newest of these before newer QA reports were generated and printed the mismatched `verify` summary with `command: e2e`.

## Expected

Each summary's `command` should equal the operation in its `runId` and transcript (`backup`, `cbt-backup`, or `verify`). A pipeline-level `e2e` label is only appropriate for a report whose actual run id and contents represent the e2e operation.

## Actual

All four report JSON records say `command: e2e`. Exit code for the read-only `make report` was `0`; no diagnostic warned about the inconsistent metadata.

## Errors / logs

No runtime error. The contradiction is in retained output. For example, `reports/run-20260924T183045Z-verify/run.log:1-2,41-54` records a `verify` run and then a summary command of `e2e`; `summary.json:2-4` records `runId=...-verify` and `command=e2e`.

## Source references

- `scripts/odf-vm-validator.sh:30-39`: `start_report` builds the run id from its explicit command argument.
- `scripts/odf-vm-validator.sh:59-69`: `finish_report` independently serializes the mutable global `$COMMAND`.
- `scripts/odf-vm-validator.sh:5-8`: the global command is selected and then the config file is sourced.

## Root cause

Confirmed report-field divergence; exact historical trigger is not recoverable from retained evidence. The implementation derives the run id from `start_report`'s argument but derives the summary command from a separate mutable global. That split permits metadata drift and is consistent with the observed records. A newly generated `cbt-diagnostics` report and the current negative `cbt-backup` report both used correct command labels, so the historical trigger was not reproduced in this engagement.

## Suggested fix

Persist the operation name per report at `start_report` and serialize that immutable value in `finish_report`; add a consistency check between operation name and run id before emitting the summary. Preserve the historical artifacts rather than rewriting them without provenance.

## Post-fix retest

New summaries generated on 2026-09-25 correctly identify `cbt-diagnostics`, `cbt-cycle`, and `cbt-restore-proof` in both `runId` and `command`. The four retained 2026-09-24 artifacts remain mislabeled as documented; they were not rewritten because they are historical evidence.

- Current-session summaries also match their operations: `run-20260925T030938Z-backup` → `backup`, `run-20260925T031738Z-cbt-backup` → `cbt-backup`, `run-20260925T032635Z-cbt-evidence` → `cbt-evidence`, and `run-20260925T033104Z-cbt-diagnostics` → `cbt-diagnostics`.
