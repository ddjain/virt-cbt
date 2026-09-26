# Latest Branch Retest: Findings and Evidence

## Branch and scope

Pulled the branch to `936e29f` (`Initialize missing legacy proof markers`), following `91d03e5` (config migration and `backup-reset` dispatch). This update adds atomic initialization of the missing legacy proof file on the mounted data disk.

Retested those changes plus the branch's persistent Full → Incremental → `verify-cbt` flow and the related cycle, quick-verify, evidence, diagnostics, status, and VM-selection paths. The Blue cluster prerequisites passed. The earlier isolated namespace was deleted; the original namespace now has a verified persistent Full/Incremental pair and its VM remains running.

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

### Resolved finding: existing pool predates the `hello.txt` proof-file setup

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

The earlier retest left the original guest unchanged. This retest after `936e29f` verified the initialization on that legacy guest, then completed Full, Incremental, and restore-hash verification.

**Resolution:** `make backup` initializes the dedicated proof file on mounted `/data` if a legacy pool lacks the cloud-init seed, logs the action, and never falls back to the container disk. Verified end-to-end below.

### Retest after commit `936e29f`

The original `fedora-cbt-1` first reported `HELLO_MISSING`. After `make backup-reset`, `make backup` initialized the proof file on `/data`:

```text
[11:18:17] [INFO] [PROOF] Initialized missing recovery proof file at /data/vm-validator/hello.txt on fedora-cbt-1
[11:18:42] [INFO] [BACKUP] Waiting for VirtualMachineBackup/fedora-cbt-1-full terminal (timeout=1200s)
[11:30:29] [INFO] [BACKUP] VirtualMachineBackup/fedora-cbt-1-full reached Done/Complete
CBT evidence: fedora-cbt-1-full is physically Full (backing=), allocated=3191603200B — matches expected Full
```

The guest file read through `sudo -n` returned `format=odf-cbt-proof-v1`, `guest_created_at=2026-09-26T11:18:14Z`, and the new baseline proof record. An unprivileged `cat` returned `Permission denied`; the validator uses `sudo`, and this did not block the workflow.

`cbt-backup` then completed with physical Incremental evidence (`backingFile=/var/run/kubevirt-private/libvirt/qemu/cbt/datadisk.qcow2`). `verify-cbt` passed; `expectedRestoreSha256` and `restoredSha256` both equaled `13607ec0e1e12f820e06f2334e9b5eeb3e6cae2533a6ac9ff7ab11a2608577b9`.

Independent `oc` checks after verification showed the VM Ready with CBT Enabled, the VMI Running and not Paused, both PVCs Bound, VMB UIDs/source VM UID matching the manifest, and the Incremental tracker checkpoint. The temporary restore VM, PVC, and restore-target pods were absent. The LLM judge returned **PASS**.

`backup` and `cbt-backup` remained **INCONCLUSIVE** with `failed=0`, as designed before restore verification; `verify-cbt` supplied the recovery PASS.

The proof file is created with restrictive permissions; unprivileged guest reads require `sudo`. No source data or CBT-state PVC was mounted into a second pod.

**Retest reports:** `reports/run-cbt-20260926T111716Z-57582-17574-backup-reset/`, `reports/run-cbt-20260926T111744Z-57876-13072-backup/`, `reports/run-cbt-20260926T113322Z-67604-24570-cbt-backup/`, and `reports/run-cbt-20260926T114649Z-75281-26075-verify-cbt/`.


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

### Commit `936e29f` legacy-proof retest timings

Measured with `/usr/bin/time -p` (`real`):

| Command | Time | Result |
|---|---:|---|
| `make check-prereqs CONFIG=config.env` | 9.41 s | PASS; obsolete key warned and ignored |
| `make density-status CONFIG=config.env` | 2.33 s | PASS; original VM healthy |
| `make ssh` — confirm missing proof file | 3.20 s | `HELLO_MISSING` |
| `make backup-reset N=1 CONFIG=config.env` | 20.30 s | PASS; previous Full/Incremental resources reset |
| `make backup VMS=fedora-cbt-1 CONFIG=config.env` | 14:17.28 | INCONCLUSIVE; legacy proof initialized and physical Full verified |
| `make ssh` — unprivileged proof-file read | 3.96 s | Permission denied without sudo; `sudo -n` read succeeded |
| `make ssh` — `sudo -n cat` proof-file read | 3.14 s | PASS; format and baseline record present |
| `make cbt-backup VMS=fedora-cbt-1 CONFIG=config.env` | 12:54.71 | INCONCLUSIVE; physical Incremental verified |
| `make verify-cbt VMS=fedora-cbt-1 CONFIG=config.env` | 8:56.39 | PASS; restored hash matched |
