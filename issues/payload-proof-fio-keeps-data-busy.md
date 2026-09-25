# CBT payload proof cannot unmount its guest data disk

## Description

`make cbt-payload-proof` creates the density VM with both `vm-validator.service` and `vm-write-stress.service` active. Before writing known raw ranges, the proof stops `vm-validator.service` and kills its Python process, but does not stop the fio stress service that continuously accesses `/data/fio-stress`. The proof's `umount /data` therefore fails with `target is busy` and the workflow aborts before taking any backups.

## Environment

- Darwin arm64; GNU Bash 5.3.20
- OpenShift 4.22.14; ODF StorageCluster Ready, Ceph `HEALTH_OK`
- Payload proof disposable namespace: `cbt-proof-260924202200`

## Reproduction

```bash
make cbt-payload-proof
```

## Expected

After disabling all guest writers and syncing, the proof VM unmounts `/data`, writes its seeded ranges, and continues through Full, Incremental, forced-Full control, qemu-img map analysis, and cleanup.

## Actual

The run exited non-zero (`make` exit code `2`; proof result `FAIL`) before the first backup. The log reported:

```text
umount: /data: target is busy.
You are using a client virtctl version that is different from the KubeVirt version running in the cluster
Client Version: v1.7.0
Server Version: v1.8.4
exit status 1
namespace "cbt-proof-260924202200" deleted
```

The namespace was removed by the proof EXIT cleanup trap; a subsequent `oc get namespace cbt-proof-260924202200` returned `NotFound`. The existing 10-VM pool was untouched.

## Errors / logs

- Run log: `reports/run-20260924T202201Z-cbt-payload-proof/run.log:8-18`.
- Summary: `reports/run-20260924T202201Z-cbt-payload-proof/summary.json:10-18`.
- The immediate cause in the command output is `umount: /data: target is busy`; the virtctl version warning is also present but is not needed to explain the abort.

## Source references

- `kube-burner/templates/fedora-cbt-secret.yml:54-92`: `vm-write-stress.service` runs an infinite fio loop against `/data/fio-stress`.
- `kube-burner/templates/fedora-cbt-secret.yml:99-101`: cloud-init enables both guest workload services.
- `scripts/odf-vm-validator.sh:704-705`: payload proof disables `vm-validator.service`, kills `vm-validator.py`, then attempts to unmount `/data`; it does not stop `vm-write-stress.service`.
- `scripts/odf-vm-validator.sh:710-717`: raw seed writes and backups happen only after the failed unmount.

## Root cause

The payload proof stops only one of the two guest services using `/data`. The fio stress service remains active, keeping the mount busy when the proof attempts to unmount it.

## Suggested fix

Disable and stop `vm-write-stress.service` in the disposable guest, confirm its fio child process has exited, then sync and unmount `/data`. Add a precondition that verifies the mount is gone before any raw-sector writes.

## Post-fix retest

The current source now disables `vm-write-stress.service` and attempts to stop its fio process, but two complete `make cbt-payload-proof` attempts still failed before unmount or backups with `exit status 255`. A read-only `pgrep -f` probe showed that `[v]m-write-stress` also matches the enclosing `sh -c` command when its argv contains `vm-write-stress.service`. See `issues/payload-proof-pkill-matches-its-shell.md`. The prior busy-unmount outcome was not reached, so the end-to-end payload proof remains FAIL; the service-stop change is not yet verified.
