# Make SSH does not preserve embedded single quotes in CMD

## Description

The Make `ssh` recipe wraps `CMD` in single quotes without escaping embedded single quotes. A remote command that uses ordinary SQL or shell quoting is therefore rewritten by the local shell before it reaches `virtctl`; spaces-only commands work, but nested quoted commands fail or run with different arguments.

## Environment

- Darwin arm64 workstation; GNU Make; GNU Bash 5.3.20
- OpenShift `system:admin`
- Test VM `qa-cbt-a-1` in disposable namespace `qa-cbt-mktemp-a-20260925`

## Reproduction

```bash
make ssh CONFIG=/tmp/virt-cbt-retest-mktemp-a-20260925.env \
  VM=qa-cbt-a-1 \
  CMD="sqlite3 /data/vm-validator/workload.db 'pragma integrity_check;'"
```

## Expected

The guest receives the exact command and SQLite prints `ok` for `pragma integrity_check`.

## Actual

The command failed with Make exit code `2` (underlying command exit `127`), including:

```text
bash: line 1: integrity_check: command not found
bash: line 1: : command not found
```

A control `CMD='echo hello world'` passed and printed `hello world`, confirming that spaces-only values work but nested quoting does not.

## Errors / logs

The failure occurred in the guest command invocation; no files were written and no cluster resources were changed. The guest SQLite query was read-only.

Post-fix retest reproduced the same Make quoting defect with a harmless command:

```text
bash: -c: line 1: syntax error near unexpected token `('
bash: -c: line 1: `CMD='python3 -c 'print("ssh-quote-check")'' scripts/odf-vm-validator.sh --config ... ssh --vm 'qa-cbt-a-1''
make: *** [ssh] Error 2
```

The control `make ssh ... CMD=hostname` exited `0` and returned `qa-cbt-a-1`; the quoted command remained broken.

Current-session retest on `qa-cbt-exhaustive-1`: Make still failed locally with the same `syntax error near unexpected token '('` for `CMD="python3 -c 'print(\"quoted\")'"` (exit 2). Passing the identical quoted command directly via `CMD=... scripts/odf-vm-validator.sh ... ssh --vm ...` succeeded and printed `direct-script-quote`, isolating the fault to the Make assignment.

## Source references

- `Makefile:98-99`: `CMD='$(CMD)'` embeds unescaped Make text inside a shell single-quoted assignment.
- `scripts/odf-vm-validator.sh:532-549`: `ssh_guest` reads `CMD` from the environment and forwards it to `virtctl ssh --command`.

## Root cause

An embedded single quote terminates the Make recipe's shell quoting. The remaining text is reinterpreted as shell syntax before the validator receives `CMD`.

## Suggested fix

Use a Make-safe environment transfer that preserves arbitrary command bytes (for example, encode/decode the value or use a properly escaped shell assignment). Add a regression case with nested quotes and spaces, not just `echo hello world`.
