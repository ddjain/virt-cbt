# CBT (Changed Block Tracking) — Explained From Scratch

This is written for someone who has never touched CBT before, and it stands
on its own — it doesn't assume you're using any particular repo's tooling.
It builds up from "what problem are we solving" to "how do you actually
prove it works, even under chaos", using the real Kubernetes/KubeVirt
objects, `oc`/`kubectl`, and `qemu-img` commands you'd type by hand, with
ASCII diagrams at each step.

---

## 1. The problem: backups are slow if you copy everything every time

A VM has a disk. Say it's 10 GiB. Most of that disk doesn't change between
9am and 10am — maybe only a few files were written.

```
Disk (10 GiB)
┌────────────────────────────────────────────────────────────┐
│ mostly unchanged data                                       │
│                                             [a few changed]  │
└────────────────────────────────────────────────────────────┘
```

**Full backup** = copy the whole 10 GiB, every time.
**Incremental backup** = copy *only* the part that changed since the last backup.

To do an incremental backup, something has to remember *which blocks changed*.
That "memory of which blocks changed" is what CBT (Changed Block Tracking) is.

---

## 2. Who remembers the changed blocks? QEMU dirty bitmaps

Under the hood, your VM's disk is served by QEMU (the process that actually
runs the VM). QEMU has a built-in feature called a **dirty bitmap**: one bit
per disk region (e.g. one bit per 256 KiB chunk). Whenever a write happens
to a region, QEMU flips that bit to 1 ("dirty" = "changed since last
backup").

```
Disk blocks:     [0][1][2][3][4][5][6][7][8][9]
Dirty bitmap:      0  0  0  1  0  0  0  1  1  0
                            ^           ^  ^
                     someone wrote to blocks 3, 7, 8
```

When you take a backup, KubeVirt asks QEMU: "give me only the blocks marked
dirty in this bitmap" → that's your incremental backup. Then a new bitmap
starts, so it can track the *next* window of changes.

A **checkpoint** is just a named snapshot-in-time of "the bitmap as of
backup X". A chain of checkpoints looks like this:

```
 checkpoint-1        checkpoint-2        checkpoint-3
     │                    │                   │
     ▼                    ▼                   ▼
 [FULL backup] → [INCREMENTAL] → [INCREMENTAL] → ...
   (everything)   (only blocks     (only blocks
                    dirty since      dirty since
                    checkpoint-1)    checkpoint-2)
```

Each incremental only makes sense *relative to the previous checkpoint*. If
that chain breaks, the next backup can't know what's "changed since last
time" anymore — it has to fall back to a full backup.

---

## 3. Where does KubeVirt actually keep this bitmap?

This is the part that's easy to get wrong by guessing: **the bitmap is NOT
stored inside your VM's real disk file.** KubeVirt creates a *separate*,
small qcow2 file per disk whose only job is to hold the bitmaps.

```
virt-launcher pod (the pod that runs your VM)
┌───────────────────────────────────────────────────────────────┐
│                                                                 │
│   Real VM disk (your actual data, PVC-backed)                  │
│   /var/run/kubevirt-private/vmi-disks/datadisk                 │
│   ┌─────────────────────────────────────┐                      │
│   │  your actual bytes live here         │                      │
│   └─────────────────────────────────────┘                      │
│                                                                 │
│   CBT "overlay" file (bitmap bookkeeping only, tiny)            │
│   /var/run/kubevirt-private/libvirt/qemu/cbt/<diskname>.qcow2   │
│   ┌─────────────────────────────────────┐                      │
│   │ bitmap: checkpoint-1 → 0001000110    │                      │
│   │ bitmap: checkpoint-2 → 0000101000    │                      │
│   └─────────────────────────────────────┘                      │
│                                                                 │
└───────────────────────────────────────────────────────────────┘
```

So there are really **two files that matter**:

1. The real disk — where your data lives (untouched by CBT itself).
2. The CBT overlay — a little qcow2 that only stores bitmaps + checkpoint
   metadata. This file is QEMU's "memory" of what changed.

If the overlay file gets corrupted or its bitmap is lost, KubeVirt still has
your data — it just loses the ability to do an *incremental* backup and has
to fall back to a full one.

> **A tempting but unreliable idea:** since the overlay is "just a qcow2
> file", can't you just read it directly (e.g. `qemu-img info` on it) to see
> the bitmaps and prove the chain is healthy? In principle, yes. In
> practice, while the VM is running, QEMU keeps the bitmap contents mostly
> in memory and only writes them back to that file on a clean close — so
> inspecting the live file from the outside can show *no bitmaps at all*
> even though CBT is working correctly. §7 covers a safer way to get the
> same confidence without touching this file while the VM is up, and §10
> covers a real incident that came from trying to read it live anyway.

---

## 4. What actually happens when you take a Full backup, then an Incremental

Backups are driven by two Kubernetes custom resources KubeVirt provides:
`VirtualMachineBackupTracker` (tracks the checkpoint chain for one VM) and
`VirtualMachineBackup` (one backup job).

First, a tracker (created once per VM):

```yaml
apiVersion: backup.kubevirt.io/v1alpha1
kind: VirtualMachineBackupTracker
metadata:
  name: my-vm-tracker
spec:
  source: {apiGroup: kubevirt.io, kind: VirtualMachine, name: my-vm}
```

**Full backup:**

```yaml
apiVersion: backup.kubevirt.io/v1alpha1
kind: VirtualMachineBackup
metadata:
  name: my-vm-full
spec:
  source: {apiGroup: backup.kubevirt.io, kind: VirtualMachineBackupTracker, name: my-vm-tracker}
  mode: Push
  pvcName: my-vm-backup-output   # a PVC you created beforehand to receive the copy
  skipQuiesce: true
```

```
$ kubectl apply -f full-backup.yaml
$ kubectl wait --for=jsonpath='{.status.conditions[?(@.type=="Done")].status}'=True \
    virtualmachinebackup/my-vm-full --timeout=600s
```

```
   VirtualMachineBackup "my-vm-full" created ──► virt-launcher tells QEMU:
        │                                        "start tracking a bitmap
        │                                         called checkpoint-1,
        │                                         then copy the WHOLE disk
        │                                         out to my-vm-backup-output"
        ▼
   my-vm-backup-output PVC now contains:
   my-vm/checkpoint-1/my-vm-full-datadisk.qcow2
   (size ≈ full disk)
```

**Incremental backup** — same shape, referencing the same tracker (which
now already has one checkpoint recorded):

```yaml
apiVersion: backup.kubevirt.io/v1alpha1
kind: VirtualMachineBackup
metadata:
  name: my-vm-incremental
spec:
  source: {apiGroup: backup.kubevirt.io, kind: VirtualMachineBackupTracker, name: my-vm-tracker}
  mode: Push
  pvcName: my-vm-backup-output
  skipQuiesce: true
```

```
   VirtualMachineBackup "my-vm-incremental" created ──► virt-launcher tells QEMU:
        │                                              "give me everything
        │                                               dirty since
        │                                               checkpoint-1, call
        │                                               this batch
        │                                               checkpoint-2"
        ▼
   my-vm-backup-output PVC now also contains:
   my-vm/checkpoint-2/my-vm-incremental-datadisk.qcow2
   (size ≈ only the changed bytes — should be MUCH smaller than full)
```

You can watch the resulting file sizes directly. Exec into (or `oc debug`) a
pod that has the backup PVC mounted, and run:

```
$ qemu-img map --output=json --force-share my-vm-full-datadisk.qcow2
$ qemu-img map --output=json --force-share my-vm-incremental-datadisk.qcow2
```

`qemu-img map` lists which byte ranges in the file actually hold data
(as opposed to being unallocated/zero). A healthy pair looks like:

```
qemu-img map output (simplified)

Full backup map:        [DATA][DATA][DATA][DATA][DATA][DATA] ← everything
Incremental map:        [    ][    ][    ][DATA][    ][    ] ← only the
                                            ^^^^              changed part
                                       one small write you made
                                       between the two backups
```

That's proof by *physical bytes on disk*, not by trusting a status message
that says "Completed".

---

## 5. Putting it together: QEMU, the VM, disks, backup files, and restore

This section is the end-to-end mental model — how the pieces from §2–§4
relate when a Fedora VM is running on OpenShift Virtualization + ODF, and
what "restore" would mean for the Push-mode artifacts. Names below match a
typical density-validator VM (`fedora-cbt-1`); substitute your own prefix.

### 5.1 Layers: QEMU ↔ VM ↔ disks

```
┌─ OpenShift worker node ──────────────────────────────────────┐
│  virt-launcher pod  (hosts your VM)                          │
│                                                              │
│   ┌─ QEMU process ────────────────────────────────────────┐  │
│   │  = the emulator that actually runs the guest            │  │
│   │  owns disk I/O and the dirty bitmaps                    │  │
│   │                                                          │  │
│   │   Guest OS (Fedora)  ←── "the VM" from your POV         │  │
│   │     writes to /data/...                                  │  │
│   │            │                                             │  │
│   │            ▼                                             │  │
│   │   virtio disk "datadisk"                                 │  │
│   └────────────┼─────────────────────────────────────────────┘  │
│                │                                                │
│   REAL DATA PVC              CBT OVERLAY (bitmap bookkeeping)   │
│   <vm>-data                  persistent-state-for-<vm>-…        │
│   …/vmi-disks/datadisk       …/libvirt/qemu/cbt/datadisk.qcow2  │
│   (your actual bytes)        (tiny; bitmaps + checkpoints only) │
│                                                              │
│   BACKUP OUTPUT PVC  <vm>-backup-output                      │
│   (separate — receives Push-mode .qcow2 copies; safe to      │
│    mount from a short-lived inspector pod off the VM node)   │
└──────────────────────────────────────────────────────────────┘
```

| Term | What it is |
|---|---|
| **VM** | KubeVirt `VirtualMachine` + running `VirtualMachineInstance` |
| **QEMU** | Process inside `virt-launcher` that executes the guest and tracks dirty blocks |
| **Data disk** | PVC `<vm>-data` — guest-visible volume (e.g. mounted at `/data`) |
| **Backup PVC** | PVC `<vm>-backup-output` — where Full/Incremental qcow2 files land |
| **CBT overlay** | Small qcow2 at `…/libvirt/qemu/cbt/<disk>.qcow2` — bitmaps only, not guest data |

### 5.2 How the data disk is attached

```
VirtualMachine.spec
  volumes: PVC <vm>-data
  disks:   name datadisk, changedBlockTracking: true
        │
        ▼
  PVC attached into virt-launcher
        │
        ▼
  QEMU presents it as disk "datadisk"
  Guest sees it as /dev/vdX → filesystem at /data
```

CBT must also be allowed by cluster config (feature gate + label selector);
see `CBT-ARCHITECTURE.md`. When both are in place,
`VirtualMachine.status.changedBlockTracking.state` becomes `Enabled` and
KubeVirt creates/maintains the overlay + dirty bitmaps for that disk.

### 5.3 What files a backup generates, and where they live

Push-mode backups write **into the backup-output PVC**, not into the data
disk and not into the CBT overlay:

```
PVC <vm>-backup-output
└── <vm>/
    ├── <vm>-full-<timestamp>/
    │     └── <vm>-full-datadisk.qcow2
    │           • format: qcow2
    │           • self-contained Full (no backing-filename in the header)
    │           • size ≈ allocated bytes of the whole disk
    │
    └── <vm>-incremental-<timestamp>/
          └── <vm>-incremental-datadisk.qcow2
                • format: qcow2
                • CBT Incremental — header includes:
                  backing-filename =
                    /var/run/kubevirt-private/libvirt/qemu/cbt/datadisk.qcow2
```

The inspector pod in this repo mounts that PVC at `/proof/…`, so the same
paths appear under `/proof/<vm>/…` in evidence JSON.

While a backup runs, KubeVirt temporarily hot-plugs the backup-output PVC
into the virt-launcher, QEMU writes the qcow2, then the PVC is unplugged
again. After that, only the finished files remain on the backup PVC.

### 5.4 CBT overlay format and bookkeeping (recap)

```
CBT overlay file  (NOT your data disk)
  path (in launcher):  /var/run/kubevirt-private/libvirt/qemu/cbt/<disk>.qcow2
  format:              qcow2 used as a bitmap container
  contents:            dirty bitmaps + checkpoint names
  backing PVC:         persistent-state-for-<vm>-<suffix>

Disk blocks:   [0][1][2][3][4][5][6][7][8][9] ...
Dirty bitmap:    0  0  0  1  0  0  0  1  1  0
                         ▲           ▲  ▲
                    guest wrote here since last checkpoint
```

| | Data disk PVC | CBT overlay (state PVC) | Backup-output PVC |
|---|---|---|---|
| Holds guest files? | Yes | No | Copies of disk ranges |
| Holds dirty bitmaps? | No | Yes | No (header may *name* the overlay) |
| Mount from a 2nd pod while VM runs? | **Never** | **Never** | Yes (read-only; prefer off-node) |

While the VM is up, QEMU keeps bitmaps mostly in memory and flushes on a
clean close — so inspecting the *live* overlay from outside is both
unreliable and unsafe (§10). Prove Full-vs-Incremental from the **backup**
qcow2 header instead (§7).

### 5.5 How restore works (conceptually)

This repository's `verify` / `cbt-evidence` path proves that backup
artifacts are physically Full or Incremental. It does **not** restore them
onto a new volume or VM. Restoring a Push-mode CBT chain looks like this:

```
Want the disk as of Incremental-2?

  Full.qcow2  ←── Incremental-1.qcow2  ←── Incremental-2.qcow2
  (base)         (delta since Full)       (delta since Inc-1)

Restore outline:
  1. Create an empty target PVC (or volume)
  2. Rebase the Incremental's backing-filename from the live CBT overlay
     path onto the Full backup qcow2 (`qemu-img rebase -u`), then
     `qemu-img convert` the chain onto the target (e.g. `disk.img`)
  3. Attach that volume to a new VM (or replace the old data PVC)
     and boot; verify guest data independently
```

- **Full alone** restores to the Full checkpoint's point in time.
- **Full + later Incrementals** restores to the latest checkpoint in the
  chain you apply.
- The **CBT overlay** (`…/cbt/datadisk.qcow2`) is bookkeeping for *taking
  the next backup* — you do **not** restore from it.

```
RESTORE FROM THESE                          DO NOT RESTORE FROM THESE
─────────────────────────────────────       ──────────────────────────
<vm>-backup-output/*.qcow2                  live CBT overlay
  (Full + Incremental artifacts)            live <vm>-data PVC
                                            VirtualMachineBackup.status
```

KubeVirt's `VirtualMachineRestore` API restores **snapshots**, not these
Push-mode CBT payloads. A production consumer (backup product) is expected
to own retention, transport, encryption, and restore.

This repo implements three online-safe restore acceptance paths:

- **`make verify-cbt`** proves a normal density-pool sequence. `make backup`
  records a baseline SHA-256 for `/data/vm-validator/hello.txt` in a
  host-side proof manifest, `make cbt-backup` appends a unique record and
  saves the post-append hash, then `make verify-cbt` binds that manifest to
  the exact VM/PVC/VMB UIDs, restores the existing artifacts, and requires the
  restored file hash to match.
- **`make cbt-cycle`** and **`make cbt-restore-proof`** create their own
  marker/write sequence in the density pool or a disposable namespace.

All three paths convert only the Full and Incremental artifacts onto a new
restore PVC, boot a temporary restore VM, and compare a guest-side hash.
They never mount the source data or CBT-state PVCs. A green `verify` alone is
still only proof of source health and artifact *type*, not recoverability.

---

## 6. Why "trust the status field" is dangerous once you add chaos

Normally, the tracker keeps a friendly status:

```
VirtualMachineBackupTracker.status.latestCheckpoint = checkpoint-2   ✅ looks fine
```

But now imagine you're chaos-testing: you kill the virt-launcher pod
(simulate a node crash) *while* a CBT backup is in flight, or right after.

```
                     💥 chaos: virt-launcher pod killed
                          │
                          ▼
   QEMU process dies ──► the CBT overlay's bitmap may not have been
                          closed cleanly ("in-use" / dirty-open state)
                          │
                          ▼
   virt-launcher pod restarts ──► KubeVirt tries to reattach ("redefine")
                          │                the old bitmap to the new
                          │                QEMU process
                          │
               ┌──────────┴──────────┐
               ▼                     ▼
         succeeds cleanly      FAILS
               │                     │
               ▼                     ▼
      chain continues        tracker.status.latestCheckpoint
      normally               gets CLEARED — next backup
                              silently becomes a FULL backup
```

The problem: **this whole detection path lives inside the same controller
that chaos is actively trying to break.** If the controller itself is slow,
crash-looping, or racing during the chaos window, the status field might:

- say "fine" when the bitmap was actually invalidated, or
- lag behind reality, or
- just not update in time for your test assertion to read it.

For a chaos experiment, you want to answer "was the CBT backup actually
correct?" using evidence that exists **independently of the component you
just broke.**

---

## 7. The status-independent check: read the qcow2's own header

The resulting *backup* qcow2 (the one sitting in the backup PVC after a
backup finishes) is just a file. `qemu-img info` decodes its header — no
privileges needed, and critically, no need to even open the file it points
to:

```
┌─────────────────────────────────────────────────────────────┐
│  inspector pod (read-only mount of ONLY the backup PVC —      │
│  see §10 for why "only")                                       │
│                                                                │
│   $ qemu-img info --output=json --force-share my-vm-incremental-datadisk.qcow2
│   {                                                             │
│     "backing-filename":                                        │
│       "/var/run/kubevirt-private/libvirt/qemu/cbt/datadisk.qcow2" │
│     ...                                                         │
│   }                                                             │
│                                                                │
│   $ qemu-img info --output=json --force-share my-vm-full-datadisk.qcow2
│   {  ...no "backing-filename" key at all...  }                  │
└─────────────────────────────────────────────────────────────┘
```

One fact, read straight from the header, decides everything:

- **Has a `backing-filename` pointing at `.../libvirt/qemu/cbt/<disk>.qcow2`?**
  → this artifact is a genuine CBT **Incremental** — its bytes only make
  sense chained to that bitmap overlay, so it could not have been produced
  any other way.
- **No `backing-filename` at all?** → self-contained **Full** backup.
- **Backing file points somewhere else?** → anomalous; treat as a failure.

Two things worth calling out about *why* this simple check is enough:

1. **`qemu-img info` without `--backing-chain` never needs to open the
   backing file.** It just reads the string out of the qcow2 header. That
   means this check works even if the CBT overlay/bitmap file is completely
   unreachable — which matters, because reaching it safely turns out to be
   the hard part (§10).
2. It's tempting to *also* want a size figure for the incremental — "how
   many bytes actually changed?" — via `qemu-img map`. That works fine for
   a Full backup (self-contained, nothing to open). For an Incremental,
   `qemu-img map` needs to open the backing file to compute it accurately,
   which reopens exactly the safety problem in §10. The pragmatic choice:
   get the size for Full backups, and simply don't measure it for
   Incrementals — you already have your correctness answer from the header
   string alone, without needing the size.

---

## 8. Where this fits into chaos testing

```
  1. create the VM(s) and their VirtualMachineBackupTracker
  2. take a baseline Full backup (§4) → verify it's physically Full (§7)
  3. ── inject chaos here ──►  kill virt-launcher / virt-handler /
                                a storage OSD / partition the network /
                                reboot the node
  4. take an Incremental backup (§4), during or right after the chaos
  5. INSPECT — read the Incremental qcow2 header (§7) after chaos:
       → artifact-shape evidence only; never call this backup success
  6. RESTORE — rebuild the Full+Incremental chain and compare a content hash:
       → this is the PASS/FAIL recovery gate
  7. record both the artifact finding and restore outcome, repeat with
     different chaos scenarios
```

The header check in step 5 is deliberately separable from backup creation:
you can re-run it against existing artifacts without disturbing a VM. It is
not a restore proof. A header says that a qcow2 is Full-shaped or
CBT-Incremental-shaped; it cannot establish that every expected byte is
recoverable. The validator therefore reports standalone header checks as
**INCONCLUSIVE**.

For the normal density-pool sequence, `make verify-cbt` is the recovery gate:
it validates that the persistent host-side proof manifest still matches the
current VM, backup-output PVC, and exact Full/Incremental VMB UIDs; collects
CR/log diagnostics; checks both artifact headers; restores the chain into a
new VM; and requires the restored `hello.txt` SHA-256 to equal the recorded
post-Incremental hash. Only then does it report **PASS**.

For post-mortem analysis of *why* a backup behaved a certain way (controller
fallback, attach failures, handler crashes), `make backup` / `make cbt-backup`
and `make verify-cbt` write a forensic bundle under
`reports/run-*/diagnostics/<vm>/<backup-name>/` — CR YAML, filtered events,
and virt-controller / virt-handler (VMI node) / virt-launcher logs for the
backup window. Re-collect later with `make cbt-diagnostics`. Those logs are
**forensics only**; they are never the Full-vs-Incremental pass/fail signal
(§7).

---

## 9. Proving the mechanism works at all, from first principles

Before trusting the header check in §7, it's worth proving to yourself, on
a disposable VM, that CBT genuinely exports only changed bytes:

1. Create a VM with a spare data disk (`/dev/vdb` or similar), with CBT
   enabled on that disk (`changedBlockTracking: true` in its `VirtualMachine`
   spec).
2. Seed two known byte ranges on that disk with known data, e.g.:
   ```
   $ dd if=/dev/urandom of=/dev/vdb bs=1M count=128 seek=0   conv=fsync
   $ dd if=/dev/urandom of=/dev/vdb bs=1M count=128 seek=512 conv=fsync
   ```
3. Take a Full backup (§4).
4. Write one new, small "canary" range you haven't touched before, e.g. 4
   MiB at offset 1 GiB.
5. Take an Incremental backup (§4).
6. Inspect both resulting qcow2 files with `qemu-img map --output=json
   --force-share` and check: the Full contains both seeded ranges; the
   Incremental contains the new 4 MiB canary range and *only* that range
   (the two earlier seeded ranges must be absent from it).

A real run of exactly this procedure produced:

```
Full backup:         271,843,328 bytes allocated (both seeded ranges present)
Incremental backup:    4,194,304 bytes allocated (exactly the canary write —
                                                    both older seeded ranges
                                                    correctly absent)
Forced-full control: 276,037,632 bytes allocated (comparable to the real Full,
                                                    taken with a "force full"
                                                    flag as a sanity control)
```

The incremental is ~65x smaller than a full backup of the same disk and
contains *only* the new bytes — proof, from physical file contents, that
CBT is genuinely tracking and exporting only changed blocks, not silently
copying everything.

---

## 10. A real incident: how *not* to read the CBT overlay, and why

This is worth reading even if you never build this check yourself, because
the failure mode is non-obvious and destructive.

An earlier design for the §7 check tried to gather *extra* evidence by also
mounting the VM's live CBT-overlay/state PVC into a second, separate pod (to
inspect QEMU's dirty-bitmap list and their `in-use` flags directly — the
idea flagged as unreliable back in §3). That PVC is backed by Ceph RBD. On
the cluster this was tested against, attaching an RBD-backed PVC to a
**second pod on the same node** as the running VM disrupted that node's
other RBD-backed mounts badly enough to pause the *live VM* with a genuine
low-level I/O error — twice, reproducibly. This was not a simulated chaos
scenario; it was a real incident caused by the verification tooling itself.

```
  second pod attaches the VM's live CBT-overlay PVC on the SAME node
                          │
                          ▼
       node's RBD (Ceph block) client gets disrupted
                          │
                          ▼
     the VM's own, unrelated data-disk PVC starts throwing I/O errors
                          │
                          ▼
              QEMU pauses the VM: "low-level IO error detected"
```

The fix — and the reason §7's check only ever touches the backup PVC:

- **Never mount the CBT-overlay/state PVC into a second pod while the VM is
  running.** It's genuinely still attached to the live VM; concurrent
  second mounts caused real I/O pauses (see above). `cbt-payload-proof`
  stops the disposable VM and waits until the VMI is gone before mounting
  state/data for `qemu-img map`. Prefer `cbt-evidence` / `cbt-cycle` /
  `cbt-restore-proof` for online-safe checks — those never need the live
  overlay at all, since the backing-file *name* alone proves
  Incremental-vs-Full, and restore rebases Incremental onto the Full
  artifact.
- The backup PVC is safe to mount from a second pod (it isn't part of the
  VM's own pod spec — it's attached transiently, only while a backup is
  actually copying data, and detached again afterward), but schedule that
  inspector pod onto a **different node** than the VM as defense in depth,
  in case some other storage interaction on that node has the same effect.

After this fix, a full baseline-Full → Incremental → re-verify cycle was
re-run end-to-end against a live VM: the VM stayed running and ready
throughout, and both header checks passed (Full → no backing file;
Incremental → backed by
`/var/run/kubevirt-private/libvirt/qemu/cbt/datadisk.qcow2`) — this time
without disturbing the VM at all.

The general lesson, useful well beyond CBT: **verification tooling must be
provably no more invasive than the thing it's trying to verify.** If proving
something is correct requires touching a resource that's still live and
in use, look for a way to prove it from something that *isn't* still live
and in use — here, that was the finished backup file's own header, not the
running VM's in-progress state.
