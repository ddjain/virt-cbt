# Make silently ignores conflicting VM selection modes

## Description

The documented selection contract requires exactly one of `VMS`, `N`, `SELECTOR`, or `ALL`. Make recipes choose the first non-empty variable through nested `$(if ...)` expressions, so multiple supplied modes are silently collapsed before `parse_selection` can reject them. The selected set can therefore differ from the operator's apparent request while the command exits successfully.

## Environment

- Darwin arm64 workstation; GNU Bash 5.3.20; GNU Make at `/usr/bin/make`
- OpenShift identity: `system:admin`
- Configured namespace: `cbt-gcp-20260923`
- Current managed VM pool: 10 Ready/Running VMs

## Reproduction

```bash
make discover-vms VMS=fedora-cbt-1 N=2
```

## Expected

Reject conflicting modes with a non-zero exit and an exactly-one-selection error, per `README.md` selection contract and `scripts/odf-vm-validator.sh:79-85`.

## Actual

```text
fedora-cbt-1
```

Exit code: `0`. The `N=2` request was silently ignored. No cluster resources were modified.

## Errors / logs

No error or run report was emitted; the command returned the one explicitly named VM.

## Source references

- `Makefile:62-63` (`discover-vms` chooses `VMS` before `N`; the same nested precedence pattern appears in backup, CBT, reset, cycle, verify, status, evidence, and diagnostics recipes)
- `scripts/odf-vm-validator.sh:79-85` (rejects multiple modes only if they reach the script)
- `README.md:122-124` (documents exactly one selector)

## Root cause

The Make wrapper resolves selector variables by precedence rather than validating how many were set. As a result, the validator receives a single option and its own mutual-exclusion check is bypassed.

## Suggested fix

Validate selector-variable cardinality at the Make boundary for every selection-bearing target; fail before constructing the validator command if more than one of `VMS`, `N`/`n`, `SELECTOR`, and `ALL` is set.

## Post-fix retest

On 2026-09-25, `make discover-vms CONFIG=/tmp/virt-cbt-retest-pool-20260925.env VMS=fedora-cbt-1 N=2` failed during Make parsing with `specify exactly one of VMS, N/n, SELECTOR, or ALL=1` (exit `2`). No selection or cluster operation occurred.

Current-session retest: `VMS=qa-cbt-exhaustive-1 N=2`, `N=1 n=2`, and `SELECTOR=vm-os=fedora ALL=1` were each rejected at Make parse with the appropriate exactly-one/only-one error (exit 2); no cluster mutation occurred.
