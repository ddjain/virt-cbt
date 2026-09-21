# Fedora ODF CBT density test guide

The primary workflow is the Make/kube-burner utility at repository root. It creates only Fedora VMs, each with an ODF data PVC, backup-output PVC, CBT tracker, and deterministic guest workload.

## Configuration

```bash
make init-config
$EDITOR config.env
# Set KUBECONFIG, DATA_STORAGE_CLASS, BACKUP_STORAGE_CLASS, SSH_KEY and SSH_PUBLIC_KEY.
```

The default namespace is `cbt-demo`; for shared clusters use a unique namespace. `check-prereqs` requires `oc`, `virtctl`, `kube-burner`, and `jq`, then checks the VM/backup/tracker CRDs, ODF resources, storage classes, snapshot class, and CBT configuration.

## Density and backups

```bash
make check-prereqs
make density-setup N=2
make density-status
make backup N=2
sleep 5
make cbt-backup N=2
make verify N=2
make status ALL=1
make report
make density-teardown
```

`N=2` and `n=2` select the first two utility-owned VM names in lexical order. The same selector must be used for Full, Incremental, and verify operations so they use the same trackers. Use `VMS=fedora-cbt-0,fedora-cbt-1` for an exact selection, `SELECTOR=some-label=value` for a label subset, or `ALL=1` for every managed VM. Selection is mandatory for backup and verification. Duplicate, missing, unowned, zero, or over-sized selections fail.

`e2e N=2` performs setup, Full, Incremental, and verification while leaving evidence in place. Each VM uses `${vm}-backup-output` and `${vm}-tracker`; backup work is bounded by `BACKUP_CONCURRENCY`. Reports are written below `REPORTS_DIR` with one summary, log, and per-VM result.

## Guest invariant

The service refuses to run unless `/data` is mounted. It writes `/data/vm-validator/workload.db` and `workload.log` every second. Verification checks the mount, SQLite integrity, contiguous sequence, digest correctness, and increasing sequence across two checks at least two seconds apart. This detects a stale guest or accidental writes to the container disk.

## Restore limitation and release differences

The Push-mode backup API is release-dependent. The utility accepts either `Done=True` or `Complete=True`, but insists on `Full` for the baseline and `Incremental` for the next backup and requires tracker advancement. These checks do not restore a backup. A restore-to-new-VM test and guest checkpoint comparison are required to prove recoverability.

The older `manifests/` files remain fixtures for chaos-specific runbooks. They are not rendered by the density Make targets. Existing ODF installation and CBT architecture guidance remains in `docs/odf/` and `docs/cbt/CBT-OPERATIONS.md`.
