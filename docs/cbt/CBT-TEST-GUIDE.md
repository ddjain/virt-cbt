# Fedora ODF CBT density test guide

The primary workflow is the Make/kube-burner utility at repository root. It creates only Fedora VMs, each with an ODF data PVC, backup-output PVC, CBT tracker, and deterministic guest workload.

## Configuration

```bash
make init-config
$EDITOR config.env
# Set KUBECONFIG, DATA_STORAGE_CLASS, BACKUP_STORAGE_CLASS, SSH_KEY and SSH_PUBLIC_KEY.
```

The default namespace is `cbt-demo`; for shared clusters use a unique namespace. `check-prereqs` requires `oc`, `virtctl`, `kube-burner`, and `jq`, then checks the VM/backup/tracker CRDs, ODF resources, storage classes, snapshot class, and that HyperConverged CBT is configured.

## Density and backups

```bash
make check-prereqs
make density-setup N=2
make density-status
make cbt-cycle N=2
make status ALL=1
make report
# Re-run without tearing down VMs:
# make backup-reset N=2 && make cbt-cycle N=2
make density-teardown          # config NAMESPACE only
# make density-teardown ALL=1 CONFIRM=1  # every utility-owned namespace
```

`N=2` and `n=2` select the first two utility-owned VM names in lexical order (1-indexed: `fedora-cbt-1`, `fedora-cbt-2`). The same selector must be used for Full, Incremental, and verify operations so they use the same trackers. Use `VMS=fedora-cbt-1,fedora-cbt-2` for an exact selection, `SELECTOR=some-label=value` for a label subset, or `ALL=1` for every managed VM. Selection is mandatory for backup and verification. Duplicate, missing, unowned, zero, or over-sized selections fail.

`e2e N=2` performs `density-setup` then `cbt-cycle` for the first N VMs (marker rewrite → Full → append → Incremental → guest+qcow2 verify → restore-hash) while leaving the pool in place. Each VM uses `${vm}-backup-output` and `${vm}-tracker`. Backups and restore conversion run serially (the backup-output PVC is RWO). Reports are written below `REPORTS_DIR` with `summary.json`, `summary.txt`, `run.log`, and per-VM results (`PASS` / `FAIL` / `INCONCLUSIVE`).

`make backup-reset` clears Full/Incremental CRs and recreates the tracker plus backup-output PVC so another Full/`cbt-cycle` can run without `density-teardown`. It does not touch the VM or guest data.

## Control-plane checklist (triage only)

These signals are useful for human triage. They are **not** the framework's pass/fail criteria — use `make cbt-evidence` (qcow2 `backing-filename`) instead.

- [ ] **Controller log:** for each Incremental backup, `virt-controller` logs `Setting incremental backup from checkpoint: <Full checkpoint>`.
- [ ] **Backup terminal:** the Incremental `VirtualMachineBackup` has `Done=True` or `Complete=True` (or `Failed=True` if chaos bounded the failure).

```bash
NS=cbt-demo
VM=fedora-cbt-1
oc logs -n openshift-cnv deployment/virt-controller --all-pods=true --prefix=false --since=30m |
  jq -r 'select((.msg // "") | startswith("Setting incremental backup from checkpoint:")) |
    [.VirtualMachineBackup // "-", .msg] | @tsv'
make cbt-evidence VMS=$VM
```

For payload-level evidence, run `make cbt-payload-proof` below. Prefer `make cbt-restore-proof` when you need online-safe restoreability proof without mounting live CBT/data PVCs.

## CBT payload proof

```bash
make cbt-payload-proof
```

This tests the data path independently of backup `status.type`. It creates one Fedora VM in a unique utility-owned namespace, stops the guest workload, writes two known ranges directly to the disposable VM's data disk, and takes a Full backup. It then changes a separate 4 MiB range, takes an Incremental backup, and takes a forced-Full control backup.

**Safety:** before the inspector mounts the launcher's persistent-state and data PVCs, the framework **stops the VM and waits until the VMI is gone**. Concurrent second mounts of those PVCs while the VM is running caused live I/O pauses on this class of cluster (see `AGENTS.md` and CBT-EXPLAINED §10). Prefer `cbt-restore-proof` + `cbt-evidence` for online-safe checks.

The verifier then starts a short-lived read-only inspector pod on the (former) launcher node, mounts backup-output plus state/data read-only at the backing-file paths expected by the QCOW2 images, and runs `qemu-img map --force-share`. The analyzer counts only depth-0 allocated extents and requires a nonzero extent in the known canary range, while omitting both ranges present at the Full checkpoint. It also requires the Incremental artifact's allocated data to be less than one eighth of Full and checks a forced-Full control artifact contains the canary extent.

The command overwrites raw sectors only on its disposable test VM. It requires SSH configuration and a data disk of at least 2 GiB. The namespace is removed through the ownership-checked teardown path; reports and QCOW2 extent maps remain under `REPORTS_DIR`. This does not prove restoreability of arbitrary backups.

## CBT restore proof (guest hash after Full+Incremental)

```bash
make cbt-restore-proof
```

Creates a disposable namespace (`cbt-restore-<timestamp>`), writes
`/data/vm-validator/cbt-restore-proof.bin` and records `hash1`, takes a Full
backup, appends more bytes and records `hash2`, takes an Incremental backup,
rebases the Incremental qcow2 onto the Full artifact, converts the chain onto
a new PVC, boots a restore VM from that PVC, and requires
`restored_hash == hash2`. Tear-down of the disposable namespace is always
attempted (success or failure). Defaults are large enough for mid-backup
chaos injection (`RESTORE_PROOF_BASE_MIB=512`, `RESTORE_PROOF_APPEND_MIB=128`
in `config.example.env`); override in `config.env` if needed.

For the same restore-hash proof against an existing density pool (without a
disposable namespace), use `make cbt-cycle` (marker path
`/data/vm-validator/cbt-marker.bin`). Re-run with `make backup-reset` then
`make cbt-cycle`.

This is the recoverability check. It does not use `VirtualMachineRestore`
(that API is for snapshots). It never mounts the source VM's data or
CBT-overlay PVC.

## Guest invariant

The service refuses to run unless `/data` is mounted. It writes `/data/vm-validator/workload.db` and `workload.log` every second. Verification checks the mount, SQLite integrity, contiguous sequence, digest correctness, and that `max(seq)` **strictly increases** across two checks at least two seconds apart. Equal sequences fail (stale guest / stopped workload).

## Restore limitation and release differences

The Push-mode backup API is release-dependent. The utility treats `Done`, `Complete`, or `Failed` as terminal conditions for waiting; Full-vs-Incremental correctness still comes only from qcow2 evidence. Standard `verify` / `cbt-evidence` do not restore a backup. Use `make cbt-cycle` (density pool) or `make cbt-restore-proof` (disposable) for restore-to-new-VM + guest hash comparison.

When evidence cannot be inspected (missing checkpoint path, inspector pod not Ready, qemu-img failure), results are recorded as `INCONCLUSIVE` rather than FAIL.

Conceptually, restore means applying the Full (+ Incremental) qcow2 chain from the backup-output PVC onto a new volume — **not** using the live CBT overlay. See [CBT-EXPLAINED.md §5.5](CBT-EXPLAINED.md#55-how-restore-works-conceptually).

The older `manifests/` files remain fixtures for chaos-specific runbooks. They are not rendered by the density Make targets. Existing ODF installation and CBT architecture guidance remains in `docs/odf/` and `docs/cbt/CBT-OPERATIONS.md`.
