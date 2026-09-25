# Verify can report PASS after SQLite integrity_check failed

## Description

A post-fix `make verify` run printed `database is locked` from the guest's SQLite `PRAGMA integrity_check` twice, then reported PASS because the later Python sequence/digest query succeeded. The verifier's shell command does not stop when the integrity check/`grep -qx ok` fails, so a required guest-integrity assertion is discarded and the report can falsely claim success.

## Environment

- Darwin arm64 workstation; GNU Bash 5.3.20
- OpenShift 4.22.14; ODF 4.21.12
- Disposable namespace `qa-cbt-mktemp-a-20260925`, VM `qa-cbt-a-1`

## Reproduction

```bash
make verify CONFIG=/tmp/virt-cbt-retest-mktemp-a-20260925.env VMS=qa-cbt-a-1
```

The first attempt failed when the Python SQLite query also hit a lock. On the retry, the Python query succeeded but the preceding integrity-check still failed.

## Expected

A failed `pragma integrity_check` must make `guest_check` fail (or be retried with a bounded SQLite busy timeout before deciding). `verify` must not record PASS unless integrity, sequence, and digest assertions all succeeded.

## Actual

The retry exited successfully and wrote `passed=1`, `failed=0`, `status=PASS`. Its log contained two lines:

```text
Error: in prepare, database is locked (5)
```

followed by `Guest workload advanced: seq 164 → 166` and `qa-cbt-a-1 PASS — VM, backup and guest checks passed`. Full and Incremental qemu evidence and backup terminal conditions were valid; the false PASS concerns the guest SQLite integrity subcheck.

## Errors / logs

- First failure: `reports/run-20260925T011513Z-verify/run.log:11-23`; summary recorded `FAIL`.
- False-pass retry: `reports/run-20260925T012410Z-verify/run.log` and `summary.json`.
- A separate read-only SQLite command with `PRAGMA busy_timeout=30000; PRAGMA integrity_check;` returned `30000` and `ok`, showing the database recovered when given time.
- Reproduced in `reports/run-20260925T013730Z-cbt-cycle/run.log` at 01:49:32Z: `Error: in prepare, database is locked (5)` was followed by `Guest workload advanced: seq 505 → 507`; `cbt-cycle` then wrote PASS at 01:54:43Z with matching restore hash. The chain/hash proof passed, but the required SQLite integrity subcheck was still swallowed.
- Reproduced again in the `make e2e` run `reports/run-20260925T023550Z-cbt-cycle/`: `run.log:34,36` contains two `database is locked (5)` errors, followed by guest sequence advancement and a restored hash matching `hash1`; `summary.json` still reports `PASS` (1 passed, 0 failed). Independent `oc`/`kubectl` checks confirm the Full and Incremental VMBs and tracker checkpoint were valid, so the false success is specifically the swallowed SQLite integrity subcheck.
- Current rerun `reports/run-20260925T032614Z-verify/` again logged `Error: in prepare, database is locked (5)` at line 13, then advanced seq 414→419 and reported PASS. A separate read-only guest command with `PRAGMA busy_timeout=30000; PRAGMA integrity_check;` returned `30000` and `ok`; the Make summary still has `passed=1, failed=0`.

## Source references

- `scripts/odf-vm-validator.sh:496-510`, especially line 507: the remote command chains `sqlite3 ... | grep -qx ok; python3 ...` with semicolons and does not enable `set -e` or otherwise propagate the integrity-check exit status.
- `scripts/odf-vm-validator.sh:512-529`: `verify_one` treats a non-empty `GUEST_SEQ` as a successful guest check.

## Root cause

The integrity-check pipeline failure is not propagated. A later successful Python command becomes the remote shell's final exit status, so `guest_check` accepts output containing `GUEST_SEQ` even after SQLite reported a lock error.

## Suggested fix

Make each guest assertion fail-fast or explicitly capture/check its exit code; apply a bounded SQLite busy timeout/retry for transient locks without suppressing integrity failures. Add a regression test where SQLite `integrity_check` fails but the later Python sequence query succeeds, and require `verify` to fail.
