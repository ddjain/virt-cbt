# Selector helper failures are swallowed after partial output

## Description

`parse_selection` reads `select-vms.sh` through process substitution and never checks the helper's exit status. The helper prints accepted names as it iterates, then exits non-zero on a later invalid CSV member. If at least one name was already printed, the caller treats the partial list as a valid selection and exits successfully. Selection-bearing operations can therefore act on a subset of an invalid request; discovery itself also falsely succeeds.

## Environment

- Darwin arm64 workstation; GNU Bash 5.3.20; GNU Make
- OpenShift identity: `system:admin`
- Namespace: `cbt-gcp-20260923`; managed VM `fedora-cbt-1` exists

## Reproduction

Read-only discovery, empty CSV member after a valid name:

```bash
make discover-vms VMS=fedora-cbt-1,,fedora-cbt-2
```

Read-only discovery, duplicate after a valid name:

```bash
make discover-vms VMS=fedora-cbt-1,fedora-cbt-1
```

## Expected

Both inputs are invalid and must exit non-zero with no selected VMs. A selection-bearing command must not proceed with any partial selection.

## Actual

```text
ERROR: empty VM name
fedora-cbt-1
validator-exit=0
```

and:

```text
ERROR: duplicate VM fedora-cbt-1
fedora-cbt-1
validator-exit=0
```

Both `make discover-vms` calls returned exit code `0` and printed the valid prefix of the malformed selection. No cluster resources were modified because only discovery was run.

## Errors / logs

The selector helper emits an error to stderr after printing the first VM to stdout. The parent emits no Make error and returns success. The same parser is shared by backup, reset, verify, evidence, diagnostics, status, and cycle commands.

## Source references

- `scripts/odf-vm-validator.sh:91-95`: process-substitution loop adds output to `selected`, then only tests whether the array is empty; it does not receive `select-vms.sh`'s exit status.
- `scripts/select-vms.sh:26-29`: explicit-name processing prints each name before validating all remaining CSV entries; duplicate/empty entries exit non-zero after partial output.
- `Makefile:65-105`: selection-bearing targets all route through the shared parser.

## Root cause

Process-substitution exit status is not the status of the surrounding `while read` loop. The consumer accepts partial stdout from a producer that later exits non-zero.

## Suggested fix

Capture and validate the selector helper's complete output and exit status before populating `selected` (or validate the full CSV before printing any names). Add a regression check that malformed trailing members never yield a successful/partial selection and never reach an operation loop.
## Post-fix retest

On 2026-09-25, `make discover-vms CONFIG=/tmp/virt-cbt-retest-pool-20260925.env VMS='fedora-cbt-1,,fedora-cbt-2'` and the duplicate-name case both exited non-zero (Make exit `2`). Each emitted only the selector error; neither printed `fedora-cbt-1` as a partial selection. A missing trailing VM also failed with `VM fedora-cbt-99 is not in owned pool`. No cluster resources were modified.

Current-session retest used the live two-VM pool `qa-cbt-exhaustive-20260925-0305`: empty, duplicate, and missing trailing CSV entries all exited non-zero and emitted no accepted prefix. The errors were respectively `empty VM name`, `duplicate VM qa-cbt-exhaustive-1`, and `VM qa-cbt-exhaustive-99 is not in owned pool`.
