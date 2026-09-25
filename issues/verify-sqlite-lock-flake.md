# Verify can fail on a healthy guest database lock

## Description

A post-fix `make verify` run reached both completed VMBs and passed both qcow2 header checks, then failed while reading the guest SQLite workload because the continuously running writer held a lock. An independent read with a 30-second SQLite busy timeout immediately returned `integrity_check=ok`, showing the failure can be transient and produces a false negative for a healthy database.

## Environment

- Darwin arm64 workstation; GNU Bash 5.3.20
- OpenShift 4.22.14; ODF 4.21.12, `HEALTH_OK`
- Disposable namespace `qa-cbt-mktemp-a-20260925`, VM `qa-cbt-a-1`

## Reproduction

```bash
make verify CONFIG=/tmp/virt-cbt-retest-mktemp-a-20260925.env VMS=qa-cbt-a-1
```

## Expected

With Full and Incremental VMBs terminal and physically correct, guest SQLite integrity/digest reads should complete or report a bounded actionable guest-data failure, not fail only because a normal writer transaction briefly holds a lock.

## Actual

Make exited `2` (validator exit `1`); the report recorded `passed=0, failed=1`. Full and Incremental evidence checks had passed first. Guest output included:

```text
Error: in prepare, database is locked (5)
sqlite3.OperationalError: database is locked
```

A separate read-only guest command with `PRAGMA busy_timeout=30000; PRAGMA integrity_check;` returned:

```text
30000
ok
```

The VMI remained Running/Ready, CBT Enabled; both backup CRs were `Done=True`, and the tracker pointed at the Incremental checkpoint.

## Errors / logs

- Failure log: `reports/run-20260925T011513Z-verify/run.log:11-23`.
- Failure summary: `reports/run-20260925T011513Z-verify/summary.json:10-18`.
- Independent successful SQLite check was a read-only `virtctl ssh` command; no guest data was changed.
- Retest `reports/run-20260925T032614Z-verify/run.log:13` reproduced the lock as a false-success path: `verify` later reported PASS. An independent read-only guest `sqlite3` with `PRAGMA busy_timeout=30000; PRAGMA integrity_check;` returned `30000` and `ok`, confirming the database recovered without mutation.

## Source references

- `scripts/odf-vm-validator.sh:496-510`: `guest_check` runs `sqlite3 ... 'pragma integrity_check'` and Python SQLite reads without a configured busy timeout or retry.
- `kube-burner/templates/fedora-cbt-vm.yml:24-52`: the workload service continuously writes records to the same database.

## Root cause

The verifier races the normal SQLite writer and uses the default short SQLite lock wait. A transient write lock is treated as a permanent verification failure; `verify_one` returns immediately instead of retrying or using a bounded busy timeout.

## Suggested fix

Set a bounded SQLite busy timeout for both the integrity and Python reads, or retry only the lock/busy condition within the existing verification budget. Keep real integrity, digest, sequence, and guest-health errors as failures.
