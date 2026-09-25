# Payload proof cleanup can kill its own remote shell

## Description

The guest cleanup command used by `cbt-payload-proof` invokes `pkill -f "[v]m-write-stress"` from the same `sh -c` command whose argv contains `systemctl disable --now vm-write-stress.service`. That command line matches the `pkill` regular expression, so `pkill` can terminate the shell executing the cleanup before it unmounts `/data` or reports the disk size. The workflow exits with `virtctl` status 255 before backups or extent analysis.

## Environment

- Darwin arm64; GNU Bash 5.3.20
- OpenShift 4.22.14; ODF 4.21.12
- Disposable payload-proof runs `cbt-proof-260925021923` and `cbt-proof-260925022619`; both namespaces were removed by the proof cleanup trap
- `virtctl` client v1.7.0; KubeVirt server v1.8.4

## Reproduction

```bash
make cbt-payload-proof CONFIG=/tmp/virt-cbt-retest-mktemp-a-20260925.env
```

The command failed identically twice:

- `reports/run-20260925T021924Z-cbt-payload-proof/run.log`
- `reports/run-20260925T022620Z-cbt-payload-proof/run.log`

A harmless process-match probe on the disposable source VM used an `sh -c` command line containing `vm-write-stress.service`, then ran `pgrep -a -f "[v]m-write-stress"`. It listed the matching `sh -c` and `sudo -n sh -c` processes, in addition to the actual stress service process.

## Expected

Stop `vm-write-stress.service` and its fio child, sync, unmount `/data`, and continue through Full, Incremental, forced-Full control, qemu-img map checks, and cleanup without terminating the control shell.

## Actual

Both payload runs reached `Guest SSH ready`, then emitted only the virtctl version warning and `exit status 255`. No `disk_bytes`, seed write, backup, or extent-map evidence was produced. Each run reported `FAIL` and removed its disposable namespace. The second summary was `passed=0`, `failed=1`, `inconclusive=0`.

## Errors / logs

```text
You are using a client virtctl version that is different from the KubeVirt version running in the cluster
Client Version: v1.7.0
Server Version: v1.8.4
exit status 255
```

The guest-side command was terminated before it could return output. This was reproduced twice; the process-match probe confirms the self-match mechanism.

- Current-session read-only probe on `qa-cbt-exhaustive-1` again showed the enclosing processes in `pgrep -a -f "[v]m-write-stress"` output: the `sudo -n sh -c echo vm-write-stress.service; pgrep ...` and `sh -c ...` command lines both matched the target pattern.

## Source references

- `scripts/odf-vm-validator.sh:747-749`: one `virtctl ssh` command disables `vm-write-stress.service`, then runs `pkill -f "[v]m-write-stress"` inside the same `sh -c` argv.
- `reports/run-20260925T021924Z-cbt-payload-proof/run.log:8-16`
- `reports/run-20260925T022620Z-cbt-payload-proof/run.log:8-16`

## Root cause

`[v]m-write-stress` avoids matching the pattern text itself, but the same process command line separately contains the literal `vm-write-stress.service` unit name. The regular expression matches that substring, so `pkill -f` can match and kill its own enclosing shell/SSH command.

## Suggested fix

Rely on `systemctl disable --now vm-write-stress.service` and verify service/process termination in a separate guest command. If a process kill remains necessary, identify the fio child by a stable PID or run the matcher in a separate process whose argv does not also contain the target text. Then rerun the complete payload proof and confirm `umount /data` succeeds before any raw-sector writes.
