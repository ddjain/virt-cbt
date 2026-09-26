# Latest Branch Retest: Findings and Evidence

## Branch and scope

Pulled the fast-forward update on `hardening/backup-validation-guards` to commit `91d03e5` (`Fix backup reset dispatch and config migration`). It adds the obsolete-`BACKUP_CONCURRENCY` warning/ignore behavior and dispatches `backup-reset` to `backup_reset_selected`.

Retested those changes plus the branch's persistent Full → Incremental → `verify-cbt` flow and the related cycle, quick-verify, evidence, diagnostics, status, and VM-selection paths. The Blue cluster prerequisites passed. The test namespace was isolated and removed; the original namespace remains active with its VM running and a verified cycle Full/Incremental pair.

## Retest result

### Passed on the latest commit

- `make check-prereqs CONFIG=config.env`: printed the obsolete-key warning and `Prerequisites OK`; independent `oc` checks confirmed all three required KubeVirt/backup CRDs, configured RBD StorageClass, ODF resources, VolumeSnapshotClasses, and CBT configuration in HyperConverged. LLM judge agreed.
- `make backup-reset N=1 CONFIG=config.env`: PASS. Independent `oc` showed the old VMBs and tracker deleted, a new Bound backup-output PVC, the data PVC UID unchanged, and the VM still `ready=true`/CBT `Enabled`. LLM judge agreed.
- `make cbt-cycle N=1 CONFIG=config.env`: PASS on the original VM. Full qcow2 had no backing file; Incremental qcow2 pointed to `/var/run/kubevirt-private/libvirt/qemu/cbt/datadisk.qcow2`. `hash1` and `restoredHash` both equaled `c048ddddc98ca63dce911aedc97869e528f61a9cab8b5ed157d81b081cb88489`. The LLM judge returned PASS; direct `oc` showed the source VMI remained Running and the restore VM/PVC were cleaned up.
- Fresh isolated pool: `density-setup`, `backup`, `cbt-backup`, `verify`, `cbt-evidence`, `cbt-diagnostics`, `verify-cbt`, `discover-vms`, and `status` were exercised individually. Full and Incremental physical evidence matched; diagnostics collected both bundles; `verify-cbt` passed with expected and restored hash `05457e4582eb63af9a57d2afe16e31f5d46ef9025a8faa2c0d1d50c99dd6e933`. Independent `oc` confirmed the same VM/PVC/VMB identities, Ready+CBT state, tracker checkpoint, and cleanup of restore resources. LLM judge returned PASS after clarifying that the remaining `persistent-state-for-fedora-cbt-1-*` PVC belongs to the live source VM, not the temporary restore.
- `make density-teardown` deleted only the isolated namespace. Direct `oc` confirmed the original namespace, VM, VMI, and cycle backups remained.

Full/Incremental, `verify`, and standalone `cbt-evidence` reports are **INCONCLUSIVE** until restore-hash verification; each had `failed=0` and `inconclusive=1`. Their nonzero Make exit status does not mean the physical evidence check failed. `verify-cbt` supplied the recovery PASS.

### Non-blocking virtctl warning

The fresh-pool Full backup logged a virtctl client/server mismatch (client v1.7.0, server v1.8.4) and one guest SSH probe returned `exit status 3`. The command retried, then the Full VMB reached `Done` and the qcow2 header check matched Full. No subsequent backup or restore verification failed.

### Finding: existing pool predates the `hello.txt` proof-file setup

The persistent `make backup` path failed on the pre-existing VM in `cbt-gcp-20260923` after `backup-reset` completed. The VM/VMI were healthy, CBT was Enabled, and the backup PVC was Bound. The guest directory `/data/vm-validator` contained `cbt-marker.bin`, `workload.db`, `workload.db-journal`, and `workload.log`, but no `hello.txt`. Independent `oc` showed no lock, VMB, or tracker checkpoint at the time of the failed attempt. The LLM judge classified this as a missing guest proof-file precondition, not a cluster/VM failure.

```text
[09:32:56] [INFO] [TEST] [1/1] backup fedora-cbt-1
virtualmachine.kubevirt.io/fedora-cbt-1 condition met
virtualmachineinstance.kubevirt.io/fedora-cbt-1 condition met
Waiting for guest SSH on fedora-cbt-1
Guest SSH ready: fedora-cbt-1
Waiting for /data mount on fedora-cbt-1
Guest /data ready: fedora-cbt-1
You are using a client virtctl version that is different from the KubeVirt version running in the cluster
Client Version: v1.7.0
Server Version: v1.8.4
exit status 1
[09:33:32] [INFO] [RESULT] fedora-cbt-1 FAIL — backup failed
real 38.21
```

Read-only guest inspection confirmed the missing file:

```text
$ make ssh VM=fedora-cbt-1 CMD='df -h /data && df -i /data && ls -l /data/vm-validator/hello.txt' CONFIG=config.env
Filesystem      Size  Used Avail Use% Mounted on
/dev/vdc        3.6G  2.8G  837M  78% /data
Filesystem      Inodes IUsed   IFree IUse% Mounted on
/dev/vdc       1713728    13 1713715    1% /data
ls: cannot access '/data/vm-validator/hello.txt': No such file or directory
exit status 2
real 4.24

$ make ssh VM=fedora-cbt-1 CMD='ls -la /data/vm-validator' CONFIG=config.env
total 672852
-rw-r--r--. 1 root root 671088640 cbt-marker.bin
-rw-r--r--. 1 root root   8699904 workload.db
-rw-r--r--. 1 root root      8720 workload.db-journal
-rw-r--r--. 1 root root   6138426 workload.log
real 3.23
```

A fresh VM created by the latest template completed the persistent backup/restore workflow. The old VM was not modified to synthesize `hello.txt`. After the failure, `cbt-cycle` successfully recreated and verified a Full/Incremental pair in the original namespace, so it was not left without backups.

**Disposition:** Existing pools created before the proof-file cloud-init setup need that guest file before using the persistent `backup`/`cbt-backup` flow. This retest did not change guest data or validator code to hide that precondition.

### LLM judge clarification

One initial `verify-cbt` judge call classified the run as FAIL because the resource list included the source VM's `persistent-state-for-fedora-cbt-1-*` PVC. A direct `oc` query confirmed `fedora-cbt-1-restored`, `fedora-cbt-1-restore-data`, and restore-target pods were absent; the remaining state PVC was the live source VM's CBT state. The clarified LLM judgment returned PASS. No live source data or CBT-state PVC was mounted into a second pod.

## Evidence locations

Run logs, summaries, diagnostics, qcow2 evidence JSON, and restore-hash JSON are retained under `reports/`, including:

- `reports/run-cbt-20260926T093214Z-9786-30406-backup-reset/`
- `reports/run-cbt-20260926T093533Z-11682-435-cbt-cycle/`
- `reports/retest-1790415407/` (isolated persistent workflow and feature checks)

## Make command timings

### Prior retest timings

Measured with `/usr/bin/time -p` (`real`):

| Command | Time | Result |
|---|---:|---|
| `make check-prereqs CONFIG=config.env` | 1.27 s | Rejected local config key `BACKUP_CONCURRENCY` |
| `make check-prereqs CONFIG=<temporary config>` | 7.62 s | PASS |
| `make density-status CONFIG=<temporary config>` | 2.36 s | PASS; existing pool healthy |
| `make backup-reset N=1 CONFIG=<temporary config>` | 0.42 s | Failed with CLI usage; no reset occurred |
| `make density-setup N=1 CONFIG=<isolated config>` | 85.74 s | PASS |
| `make backup VMS=fedora-cbt-1` — first attempt | 2.95 s | Failed: `oc create configmap` rejected `--labels` |
| `make backup VMS=fedora-cbt-1` — second attempt | 20:15.23 | Failed: guest workload check hit a shell syntax error and timed out |
| `make backup VMS=fedora-cbt-1` — after fixes | 9:42.47 | INCONCLUSIVE as designed; physical Full verified |
| `make cbt-backup VMS=fedora-cbt-1` | 9:20.33 | INCONCLUSIVE as designed; physical Incremental verified |
| `make verify-cbt VMS=fedora-cbt-1` | 9:22.46 | PASS |
| `make density-teardown CONFIG=<isolated config>` | 56.41 s | PASS; isolated namespace deleted |

### Latest retest timings

Measured with `/usr/bin/time -p` (`real`):

| Command | Time | Result |
|---|---:|---|
| `make check-prereqs CONFIG=config.env` | 9.74 s | PASS; obsolete concurrency key warned and ignored |
| `make density-status CONFIG=config.env` | 24.18 s | PASS; original pool healthy |
| `make backup-reset N=1 CONFIG=config.env` | 19.75 s | PASS; backup state reset and recreated |
| `make backup VMS=fedora-cbt-1 CONFIG=config.env` — original pool | 38.21 s | FAIL; legacy guest lacks `hello.txt` |
| `make ssh ... df/ls hello.txt` — original pool | 4.24 s | Confirmed `hello.txt` absent |
| `make ssh ... ls /data/vm-validator` — original pool | 3.23 s | PASS; listed existing guest files |
| `make cbt-cycle N=1 CONFIG=config.env` | 35:03.52 | PASS; physical Full/Incremental and restore hash matched |
| `make density-setup N=1 CONFIG=<isolated retest config>` | 63.58 s | PASS |
| `make backup VMS=fedora-cbt-1 CONFIG=<isolated retest config>` | 6:12.85 | INCONCLUSIVE; physical Full verified |
| `make cbt-backup VMS=fedora-cbt-1 CONFIG=<isolated retest config>` | 8:41.60 | INCONCLUSIVE; physical Incremental verified |
| `make verify N=1 CONFIG=<isolated retest config>` | 2:45.30 | INCONCLUSIVE by design; workload and both artifact types verified |
| `make cbt-evidence N=1 CONFIG=<isolated retest config>` | 1:46.21 | INCONCLUSIVE; both qcow2 headers matched |
| `make cbt-diagnostics N=1 CONFIG=<isolated retest config>` | 1:21.47 | PASS; both backup diagnostic bundles collected |
| `make verify-cbt N=1 CONFIG=<isolated retest config>` | 8:32.84 | PASS; restored hash matched |
| `make discover-vms N=1 CONFIG=<isolated retest config>` | 2.64 s | PASS; selected `fedora-cbt-1` |
| `make status N=1 CONFIG=<isolated retest config>` | 9.85 s | PASS; VM/VMI/CBT/backups/tracker matched `oc` |
| `make density-teardown CONFIG=<isolated retest config>` | 26.17 s | PASS; isolated namespace deleted |
| `make backup-reset N=1 CONFIG=<removed temporary config>` | 0.07 s | Failed before cluster access because the temporary config had been removed |
| `make backup-reset N=1 CONFIG=<temporary config after teardown>` | 1.50 s | Failed selection because the isolated namespace had already been deleted |

These two post-cleanup invocations made no cluster changes; they are retained here as timing records, not product failures.
