# ODF CBT Fedora VM density validator

This repository provides a Fedora-only OpenShift Virtualization workload for validating ODF-backed KubeVirt CBT metadata. It follows the external-config, Make-driven pattern of [vmshift-validator](https://github.com/ddjain/vmshift-validator), using kube-burner to create deterministic VM density.

The guest writes one UTC row per second to `/data/vm-validator/workload.db` and `/data/vm-validator/workload.log`. Rows contain sequence, random payload, and SHA-256 digest. Verification checks the ODF mount, SQLite integrity, contiguous rows, digests, service liveness, VM/VMI/CBT state, PVCs, and Full/Incremental backup metadata. This is not a restore test.

## Quick start

```bash
make init-config
$EDITOR config.env
make generate-keys                 # sets SSH_KEY only in the shell output; copy it into config.env
make check-prereqs
make density-setup N=2
make backup N=2
make cbt-backup N=2
make verify N=2
make report
make density-teardown
```

`config.example.env` contains all defaults. Set `KUBECONFIG`, storage classes, and `SSH_KEY`/`SSH_PUBLIC_KEY` for the target cluster. The namespace must be absent or labeled `app.kubernetes.io/managed-by=odf-cbt-validator`; teardown refuses an unowned namespace.

## Targets and selection

- `density-setup N=2` creates `VM_PREFIX-0` through `VM_PREFIX-1` with kube-burner. `n=2` is accepted; conflicting `N` and `n` is rejected.
- `density-status` and `discover-vms` show the utility-owned pool.
- `backup`, `cbt-backup`, `verify`, and `status` require exactly one selection: `VMS=a,b`, `N=2`, `SELECTOR=k=v`, or `ALL=1`. Count selection sorts names lexically and takes the first N. Explicit names retain caller order and reject duplicates, missing names, and VMs outside the base label.
- `density-teardown` removes only the owned namespace.
- `ssh VM=fedora-cbt-0 CMD='systemctl status vm-validator'` runs a guest command.
- `report` prints the newest report; `list-reports` lists report directories newest first.
- `e2e N=2` runs setup, Full backup, waits for new writes, Incremental backup, and verification without teardown.

Each VM has its own `${vm}-data`, `${vm}-backup-output`, `${vm}-tracker`, `${vm}-full`, and `${vm}-incremental`. `BACKUP_CONCURRENCY` is reserved for bounded backup scheduling; results are isolated per VM under `REPORTS_DIR`.

## Reports and caveats

Mutating and validation commands create `summary.json`, `run.log`, and `per-vm/*.json`. Reports contain resource verdicts but never kubeconfig or SSH material. Backup APIs and CBT status fields are release-dependent; the utility accepts `Done=True` or `Complete=True` while requiring Full then Incremental types. A successful backup CR proves control-plane completion and checkpoint progression, not restoreability. Add a restore-to-new-VM comparison for that claim.

## Layout

```text
kube-burner/odf-cbt-density.yml       density job
kube-burner/templates/fedora-cbt-vm.yml Fedora VM, ODF disks and workload
scripts/select-vms.sh                  shared deterministic selector
scripts/odf-vm-validator.sh            lifecycle, backup, verification and reports
manifests/                             fixtures for existing chaos runbooks
docs/cbt/                              release-dependent CBT/ODF runbooks
```
