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
make density-teardown          # config NAMESPACE only
# make density-teardown ALL=1  # every utility-owned namespace
```

`N=2` and `n=2` select the first two utility-owned VM names in lexical order. The same selector must be used for Full, Incremental, and verify operations so they use the same trackers. Use `VMS=fedora-cbt-0,fedora-cbt-1` for an exact selection, `SELECTOR=some-label=value` for a label subset, or `ALL=1` for every managed VM. Selection is mandatory for backup and verification. Duplicate, missing, unowned, zero, or over-sized selections fail.

`e2e N=2` performs setup, Full, Incremental, and verification while leaving evidence in place. Each VM uses `${vm}-backup-output` and `${vm}-tracker`; backup work is bounded by `BACKUP_CONCURRENCY`. Reports are written below `REPORTS_DIR` with one summary, log, and per-VM result.

## Control-plane checklist

Use these two signals for triage; neither alone proves that the output contains only changed blocks.

- [ ] **Controller log:** for each Incremental backup, `virt-controller` logs `Setting incremental backup from checkpoint: <Full checkpoint>`.
- [ ] **Backup field:** the Incremental `VirtualMachineBackup` has `.status.type == "Incremental"` and `Done=True`.

For example, set the test namespace and VM, then inspect the logs and object:

```bash
NS=cbt-demo
VM=fedora-cbt-0
oc logs -n openshift-cnv deployment/virt-controller --all-pods=true --prefix=false --since=30m |
  jq -r 'select((.msg // "") | startswith("Setting incremental backup from checkpoint:")) |
    [.VirtualMachineBackup // "-", .msg] | @tsv'
oc get virtualmachinebackup "${VM}-incremental" -n "$NS" -o json |
  jq -e '.status.type == "Incremental" and any(.status.conditions[]; .type == "Done" and .status == "True")'
```

For payload-level evidence, run `make cbt-payload-proof` below.

## CBT payload proof

```bash
make cbt-payload-proof
```

This tests the data path independently of backup `status.type`. It creates one Fedora VM in a unique utility-owned namespace, stops the guest workload, writes two known ranges directly to the disposable VM's data disk, and takes a Full backup. It then changes a separate 4 MiB range, takes an Incremental backup, and takes a forced-Full control backup.

The verifier starts a short-lived read-only inspector pod on the VM's launcher node. It mounts the backup-output PVC plus the launcher's persistent-state and data PVCs read-only, at the backing-file paths expected by the QCOW2 images. `qemu-img map --force-share` resolves the backing chain. The analyzer counts only depth-0 allocated extents and requires a nonzero extent in the known canary range, while omitting both ranges present at the Full checkpoint. It also requires the Incremental artifact's allocated data to be less than one eighth of Full and checks a forced-Full control artifact contains the canary extent. This is payload-level evidence of selective changed-block output, not merely `status.type` or checkpoint progression.

The command overwrites raw sectors only on its disposable test VM. It requires SSH configuration and a data disk of at least 2 GiB. The namespace is removed through the ownership-checked teardown path; reports and QCOW2 extent maps remain under `REPORTS_DIR`. This does not prove restoreability of arbitrary backups.

## Guest invariant

The service refuses to run unless `/data` is mounted. It writes `/data/vm-validator/workload.db` and `workload.log` every second. Verification checks the mount, SQLite integrity, contiguous sequence, digest correctness, and increasing sequence across two checks at least two seconds apart. This detects a stale guest or accidental writes to the container disk.

## Restore limitation and release differences

The Push-mode backup API is release-dependent. The utility accepts either `Done=True` or `Complete=True`, but insists on `Full` for the baseline and `Incremental` for the next backup and requires tracker advancement. These checks do not restore a backup. A restore-to-new-VM test and guest checkpoint comparison are required to prove recoverability.

Conceptually, restore means applying the Full (+ Incremental) qcow2 chain from the backup-output PVC onto a new volume — **not** using the live CBT overlay. See [CBT-EXPLAINED.md §5.5](CBT-EXPLAINED.md#55-how-restore-works-conceptually).

The older `manifests/` files remain fixtures for chaos-specific runbooks. They are not rendered by the density Make targets. Existing ODF installation and CBT architecture guidance remains in `docs/odf/` and `docs/cbt/CBT-OPERATIONS.md`.
