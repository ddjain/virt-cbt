# ODF CBT Fedora VM density validator

This repository stands up Fedora VMs on OpenShift Virtualization backed by
ODF (Ceph RBD) storage, takes Full and Incremental (CBT — Changed Block
Tracking) backups of them, and **proves the Incremental backup is genuinely
CBT-based** by reading the raw qcow2 backup artifact on disk — never by
trusting `VirtualMachineBackup.status` or controller logs. That distinction
matters because this tooling is meant to sit inside a chaos-testing loop
(kill virt-launcher/virt-handler/ceph OSDs mid-backup, then ask "was the
resulting backup actually correct?") where the status/logs come from the
exact components chaos is trying to break.

New to CBT? Read **[docs/cbt/CBT-EXPLAINED.md](docs/cbt/CBT-EXPLAINED.md)**
first — it explains what CBT is, where KubeVirt actually stores it, and
exactly how this repo verifies it, with diagrams and real numbers from a
live run (including a real incident hit while building the verification
tooling itself, and how it was fixed).

## What gets created, and where

Everything below lives in **one Kubernetes namespace** (`NAMESPACE` in
`config.env`, default `cbt-demo`), which this tooling creates and labels
`app.kubernetes.io/managed-by=odf-cbt-validator` so it refuses to touch a
namespace it doesn't own.

For each VM named `<prefix>-<n>` (e.g. `fedora-cbt-1`):

| Resource | Kind | Purpose |
|---|---|---|
| `<vm>` | `VirtualMachine` / `VirtualMachineInstance` | the Fedora guest, CBT enabled on its data disk |
| `<vm>-data` | `PersistentVolumeClaim` (ODF RBD) | the guest's actual data disk |
| `<vm>-backup-output` | `PersistentVolumeClaim` (ODF RBD) | where backup qcow2 files land |
| `<vm>-tracker` | `VirtualMachineBackupTracker` | KubeVirt's checkpoint bookkeeping for this VM |
| `<vm>-full` | `VirtualMachineBackup` | the baseline Full backup |
| `<vm>-incremental` | `VirtualMachineBackup` | the CBT Incremental backup, relative to `<vm>-full`'s checkpoint |

Backup files themselves land inside the `<vm>-backup-output` PVC at
`<vm>/<checkpoint-name>/<backup-name>-datadisk.qcow2`.

Every command below also writes a timestamped report to
`reports/run-<UTC timestamp>-<command>/` (see [Reports](#reports)).

## Prerequisites

- `oc`, `virtctl`, `kube-burner`, `jq` on your `PATH`
- A **bash 4+** (macOS ships bash 3.2 — `brew install bash` and make sure
  `/opt/homebrew/bin` comes before `/bin` in `PATH`, or the scripts will
  fail with `declare: -A: invalid option`)
- An OpenShift cluster with OpenShift Virtualization and ODF installed, and
  a `KUBECONFIG` pointing at it
- SSH access to guests is required for `backup`, `cbt-backup`, `verify`, and
  `verify-cbt` (`make generate-keys` creates a keypair for you)

## Full end-to-end pipeline

Run these in order. Each step tells you what it's doing, what it creates,
and roughly how long it takes.

### 1. Configure

```bash
make init-config          # copies config.example.env → config.env if absent
$EDITOR config.env        # set KUBECONFIG, NAMESPACE, storage classes, etc.
make generate-keys        # creates keys/cbt-validator (+.pub) if missing;
                           # copy the printed SSH_KEY path into config.env
                           # if you didn't already set one
make check-prereqs        # verifies oc/virtctl/kube-burner/jq exist, the
                           # VirtualMachine/VirtualMachineBackup/
                           # VirtualMachineBackupTracker CRDs are installed,
                           # the configured storage classes exist, ODF's
                           # StorageCluster/CephCluster are present, a
                           # VolumeSnapshotClass exists, and CBT is enabled
                           # in HyperConverged. Prints "Prerequisites OK" or
                           # a specific error — nothing is created.
```

### 2. Create the VM pool

```bash
make density-setup N=2
```

**What it does internally:** creates the namespace (if absent) and labels
it `app.kubernetes.io/managed-by=odf-cbt-validator`; refuses to proceed if a
VM pool already exists in it (run `make density-teardown` first). Renders
`kube-burner/odf-cbt-density.yml` with your config values and runs
`kube-burner init`, which creates `N` `VirtualMachine`s named
`<VM_PREFIX>-1` .. `<VM_PREFIX>-N` (default prefix `fedora-cbt`), each with
its own `<vm>-data` PVC, `<vm>-backup-output` PVC, and CBT enabled on the
data disk. Cloud-init mounts `/data`, starts the SQLite workload and fio
stress services, and seeds `/data/vm-validator/cbt-marker.bin`
(`RESTORE_PROOF_BASE_MIB`) plus `/data/vm-validator/hello.txt`. The latter
records its guest creation time and is the small, dedicated recovery-proof
file used by the normal Full → Incremental → restore flow.
Setup then polls
until all VMs report `status.ready=true` and
`status.changedBlockTracking.state=Enabled` (up to `STABILIZE_TIMEOUT`
seconds).

```bash
make density-status              # table of VM/VMI/PVC/tracker state
make density-status SUMMARY=1    # {count, ready, cbtEnabled} JSON summary
```

### 3. Take a baseline Full backup

```bash
make backup VMS=fedora-cbt-1
```

`backup` first confirms the live guest workload is healthy, then ensures the
dedicated proof file exists on the mounted data disk. For a legacy pool that
predates the cloud-init seed, it atomically initializes the missing file and
logs that action; it never falls back to the container disk. It then appends a
unique baseline record, flushes it, and hashes the complete file. It writes a
durable host-side proof manifest at:

```text
reports/proofs/fedora-cbt-1.json
```

The manifest records the VM UID and creation time, backup-output PVC UID,
the proof file's guest creation time and baseline SHA-256, plus the Full VMB
name, UID, and run identity. The Full VMB also receives the proof ID and
baseline hash as annotations. This binds the local expected hash to the exact
VMB rather than merely to a reusable VMB name.

The command creates `<vm>-full` in Push mode, waits for a terminal condition,
collects diagnostics, and reads the resulting qcow2 header from a short-lived
read-only, off-node inspector pod. A Full must have no `backing-filename`.
This is structural evidence only, so the command reports **INCONCLUSIVE**:
the backup has not yet been restored.

### 4. Take an Incremental (CBT) backup

```bash
make cbt-backup VMS=fedora-cbt-1
```

`cbt-backup` requires the matching `full-complete` proof manifest. It verifies
the Full VMB UID, source VM UID, proof ID, and baseline hash before changing
anything. It then appends a new unique/timestamped Incremental record to
`hello.txt`, flushes it, records the new whole-file SHA-256 in the same
manifest, and creates `<vm>-incremental`.

The resulting qcow2 must have a `backing-filename` pointing at
`.../libvirt/qemu/cbt/<disk>.qcow2`. The command records the Incremental VMB
UID and expected post-append SHA-256 in the manifest. It remains
**INCONCLUSIVE** until restore verification.

### 5. Prove the existing Full + Incremental chain restores

```bash
make verify-cbt VMS=fedora-cbt-1
```

This is the normal acceptance command. For each selected VM it:

1. Validates source VM/VMI readiness, CBT enabled state, guest workload, and
   terminal VMB conditions. Tracker checkpoint information and collected CR,
   event, controller, handler, and launcher logs are context/forensics only.
2. Rejects a manifest that does not match the current VM UID, backup-output
   PVC UID, Full/Incremental VMB UIDs, source UID, test IDs, proof ID, or
   expected marker hashes.
3. Confirms the Full and Incremental qcow2 headers are physically the expected
   types from a read-only backup-output-PVC inspector pod.
4. Rebases a *copy* of the Incremental onto the Full artifact, converts the
   chain to a new restore PVC, boots a separate restore VM, and requires the
   restored `hello.txt` SHA-256 to equal the recorded post-append hash.

Only this command, `cbt-cycle`, and `cbt-restore-proof` report **PASS** for
backup recovery. `verify-cbt` never mounts the source data PVC or live CBT
state PVC.

### 6. Quick source and artifact check

```bash
make verify VMS=fedora-cbt-1
```

`verify` checks VM/VMI readiness, CBT enabled state, bound PVCs, Full and
Incremental qcow2 headers, and the advancing live SQLite workload. It does
not restore the chain, so it is useful as a quick health check but remains
**INCONCLUSIVE** for recovery.

### 7. (Optional, repeatable) Re-check backup evidence any time

```bash
make cbt-evidence VMS=fedora-cbt-1
```

Runs only the physical qcow2-header check from steps 3/4 against existing
`<vm>-full`/`<vm>-incremental` backups. It is useful forensic evidence after
chaos, but is deliberately reported as **INCONCLUSIVE**, never backup
success: a header cannot prove payload recovery. A failed VMB is never
classified as a successful backup, even if an artifact header is readable.

Selection for `backup`, `cbt-backup`, `verify-cbt`, `verify`,
`cbt-evidence`, `status`, and `discover-vms` is exactly one of `VMS=a,b`,
`N=2`, `SELECTOR=k=v`, or `ALL=1`. Count selection uses natural/version
name order, so `fedora-cbt-2` precedes `fedora-cbt-10`.

### 8. Look at results

```bash
make report          # prints the newest reports/<run>/summary.json
make list-reports     # lists report directories, newest first
```

Each command writes `run.log`, per-VM results, and `summary.json` below its
run directory. `backup` and `cbt-backup` also maintain
`reports/proofs/<vm>.json`, the local current-chain manifest used by
`verify-cbt`; `reports/` is ignored by Git.

`backup`, `cbt-backup`, `verify`, `cbt-evidence`, and `verify-cbt` write
qcow2 findings beneath `evidence/`. `backup`, `cbt-backup`, and `verify-cbt`
also collect CR, event, controller, handler, and launcher diagnostics. That
bundle is post-mortem context only. `verify-cbt`, `cbt-cycle`, and
`cbt-restore-proof` are the commands that report backup recovery success.
Disable diagnostics with `CBT_DIAGNOSTICS=0`; set
`CBT_DIAGNOSTICS_DEPTH=storage` to also capture CSI node logs and
StorageCluster/CephCluster status.

### 9. Tear down

```bash
make density-teardown          # config.env NAMESPACE only
make density-teardown ALL=1    # every namespace labeled odf-cbt-validator
```

Deletes utility-owned namespaces only (label
`app.kubernetes.io/managed-by=odf-cbt-validator`). Without `ALL=1` it
targets `NAMESPACE` from the config; with `ALL=1` it finds and deletes
every matching namespace (VMs, PVCs, backups, trackers go with them).
Refuses any namespace that lacks the ownership label.

### All-in-one

```bash
make e2e N=2   # density-setup → cbt-cycle (marker→Full→append→Inc→verify→restore-hash)
               # for the first N VMs, no teardown
```

`e2e` continues to use the self-contained `cbt-cycle` marker workflow. For
the simpler persistent-pool workflow, use `density-setup`, `backup`,
`cbt-backup`, then `verify-cbt` as shown above.

### Repeat a cycle on an existing pool

```bash
make backup-reset N=2  # delete Full/Incremental CRs, recreate tracker + backup-output PVC
make backup N=2
make cbt-backup N=2
make verify-cbt N=2
```

`backup-reset` keeps VMs, guest data, and `hello.txt`; it deletes the Full and
Incremental VMBs, tracker, and backup-output PVC, then invalidates the prior
host-side proof manifest. The next `backup` records a new proof ID and
baseline hash.

## Other commands

- **`make density-teardown [ALL=1 CONFIRM=1]`** — deletes the config
  namespace, or every utility-owned namespace when `ALL=1` (requires
  `CONFIRM=1`).
- **`make discover-vms [N=2|ALL=1]`** — lists (or counts, with
  `COUNT_ONLY=1`) the VMs a selection would resolve to, without touching
  anything.
- **`make ssh VM=fedora-cbt-1 CMD='...'`** — runs a command in the guest via
  `virtctl ssh` (defaults to `hostname`). `CMD` is passed via the
  environment so spaces survive Make word-splitting.
- **`make verify-cbt [selection]`** — the recovery acceptance gate for a
  `make backup` + `make cbt-backup` pair. Validates manifest/VMB identities,
  terminal CR conditions, qcow2 artifact headers, and restores the chain to
  a new VM; reports PASS only when restored `hello.txt` matches the recorded
  post-Incremental SHA-256.
- **`make verify [selection]`** — quick source-health and qcow2 artifact check.
  It validates the live SQLite workload and both artifact types but does not
  restore, so a structurally healthy result remains INCONCLUSIVE for recovery.
- **`make backup-reset [selection]`** — deletes `<vm>-full` /
  `<vm>-incremental`, then recreates an empty `<vm>-tracker` and
  `<vm>-backup-output` PVC and invalidates the persistent proof manifest.
  Does not touch the VM, data PVC, or guest files. Required before repeating
  the normal `backup` / `cbt-backup` sequence for that VM.
- **`make cbt-cycle [selection]`** — density-pool CBT cycle: rewrite
  `/data/vm-validator/cbt-marker.bin` (hash0) → Full → append (hash1) →
  Incremental → live verify (SQLite + qcow2 evidence) → restore Full+Inc
  chain onto a temporary restore VM and require `restored_hash == hash1`.
  Cleans restore-only resources afterward; leaves source VMs running. Sizes
  use `RESTORE_PROOF_BASE_MIB` / `RESTORE_PROOF_APPEND_MIB`.
- **`make cbt-diagnostics [selection]`** — ad-hoc forensic dump for existing
  `<vm>-full` / `<vm>-incremental` backups (CR YAML + controller/handler/launcher
  logs). Same bundle shape as the automatic dump written during
  `make backup` / `make cbt-backup`. Does not take new backups and does not
  decide Full vs Incremental correctness. If neither backup exists for a VM,
  that VM is recorded `INCONCLUSIVE` (not a green PASS).
- **`make cbt-payload-proof`** — the heavyweight, from-first-principles
  proof that CBT works at all. Creates its **own disposable namespace**
  (`cbt-proof-<timestamp>`) with **one throwaway VM**, seeds two known byte
  ranges on its data disk, takes a Full backup, writes one new small "canary"
  range, takes an Incremental *and* a forced-Full "control" backup, then
  **stops the VM** (waits until the VMI is gone) before mounting state/data
  PVCs into an inspector for `qemu-img map`. Always deletes its disposable
  namespace afterward (success or failure). Prefer `cbt-cycle` /
  `cbt-restore-proof` + `cbt-evidence` when you need online-safe checks that
  never touch live CBT/data PVCs.
- **`make cbt-restore-proof`** — disposable-namespace restoreability proof
  (same marker/convert/hash helpers as `cbt-cycle`). Creates
  `cbt-restore-<timestamp>`, writes `/data/vm-validator/cbt-restore-proof.bin`
  (hash1) → Full → append (hash2) → Incremental → restore chain → require
  `restored_hash == hash2`. Always tears down its namespace afterward.

## How correctness is verified

Full write-up: **[docs/cbt/CBT-EXPLAINED.md](docs/cbt/CBT-EXPLAINED.md)**.
Short version: a genuine CBT Incremental backup's qcow2 file has a
`backing-filename` header field pointing at the VM's CBT bitmap overlay
(`.../libvirt/qemu/cbt/<disk>.qcow2`); a Full backup has none. That's a
physical fact fixed when the file is written, unaffected by anything chaos
does to pods or controllers afterward. `scripts/cbt-evidence-check.sh` reads
it via a short-lived, read-only inspector pod mounted **only** against the
`<vm>-backup-output` PVC (never the VM's own disk or its live CBT-overlay
PVC — mounting either of those into a second pod while the VM is running
was tried during development and caused a real I/O pause on the live VM; see
§10 of CBT-EXPLAINED.md), scheduled onto a different node than the VM as
defense in depth. Exit codes: `0` match, `1` type mismatch, `2`
uninspectable (`INCONCLUSIVE`).

Layers, backup-file layout, and how a Push-mode chain would be restored
(conceptually) are in **§5** of the same doc.

## Reports

```text
reports/run-<UTC timestamp>-<command>/
├── run.log                          full stdout/stderr of the command
├── summary.txt                      human-readable pass/fail/inconclusive counts
├── per-vm/<vm>.json                 {vm, status: PASS|FAIL|INCONCLUSIVE, message}
├── summary.json                     {runId, command, namespace, selected,
│                                      passed, failed, inconclusive, results: [...]}
├── evidence/<backup-name>-evidence.json   {vm, backup, expectedType,
│                                             physicalType, backingFile,
│                                             artifactPath,
│                                             allocatedDataBytes, match,
│                                             inspectable}
├── evidence/<vm>-verify-cbt.json    Full/Incremental VMB UIDs, tracker context,
│                                      expected/restored proof hashes, match
└── diagnostics/<vm>/<backup-name>/  forensic dump (backup/cbt-backup; also
      ├── manifest.json                make cbt-diagnostics). Not used for pass/fail.
      ├── baseline.json                pre-apply tracker/VMI CBT snapshot
      ├── crs/                         VM/VMI/PVC/VMB/VMBT/pods/events YAML
      ├── cluster/                     vmb.json, tracker.json, vmi-cbt.json, HCO snippet
      ├── logs/                        virt-controller, virt-handler (VMI node),
      │                                launcher describe+compute, filtered events
      └── storage/                     only when CBT_DIAGNOSTICS_DEPTH=storage

reports/proofs/<vm>.json             persistent proof manifest for the current
                                      Full + Incremental chain; invalidated by
                                      backup-reset and never committed
```

Kill-switch: `CBT_DIAGNOSTICS=0`. Depth: `CBT_DIAGNOSTICS_DEPTH=core|storage`.

## Layout

```text
kube-burner/odf-cbt-density.yml         density job definition
kube-burner/templates/fedora-cbt-vm.yml Fedora VM manifest (disks, CBT, workload)
scripts/select-vms.sh                   shared deterministic VM selector
scripts/odf-vm-validator.sh             lifecycle, backup, verify, reports (the `make` targets)
scripts/cbt-evidence-check.sh           the physical qcow2-header CBT proof (see above)
scripts/cbt-diagnostics-collect.sh      forensic CR/log dump around one VMB (forensics only)
scripts/run-cbt-krkn-scenario.sh        wraps a krknctl chaos scenario around a CBT backup
scripts/classify-cbt-result.sh          classifies a chaos-scenario backup using cbt-evidence-check.sh
manifests/                              fixtures for existing chaos runbooks
docs/cbt/CBT-EXPLAINED.md               CBT explained from scratch, with diagrams
docs/cbt/CBT-COMPONENT-DEPENDENCIES.md  per-component roles for CBT chaos/test planning
docs/cbt/                               CBT architecture, ops, and test runbooks
```

## Caveats

Standard `verify` and `cbt-evidence` prove the backup artifact is physically
the type it claims to be. They do not prove arbitrary point-in-time
**restore** works. Use `make verify-cbt` for a normal-pool Full + Incremental
restore-to-new-VM plus `hello.txt` hash comparison, `make cbt-cycle` for its
self-contained marker cycle, or `make cbt-restore-proof` for a disposable
namespace. See
[docs/cbt/CBT-EXPLAINED.md §5.5](docs/cbt/CBT-EXPLAINED.md#55-how-restore-works-conceptually).
