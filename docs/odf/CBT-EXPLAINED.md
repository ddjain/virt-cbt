# CBT (Changed Block Tracking) — Explained From Scratch

This is written for someone who has never touched CBT before. It builds up from
"what problem are we solving" to "how do we prove it under chaos", with ASCII
diagrams at each step.

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

Under the hood, your VM's disk is served by QEMU (the thing that actually runs
the VM). QEMU has a built-in feature called a **dirty bitmap**: one bit per
disk region (e.g. one bit per 256 KiB chunk). Whenever a write happens to a
region, QEMU flips that bit to 1 ("dirty" = "changed since last backup").

```
Disk blocks:     [0][1][2][3][4][5][6][7][8][9]
Dirty bitmap:      0  0  0  1  0  0  0  1  1  0
                            ^           ^  ^
                     someone wrote to blocks 3, 7, 8
```

When you take a backup, KubeVirt asks QEMU: "give me only the blocks marked
dirty in this bitmap" → that's your incremental backup. Then the bitmap is
cleared (or a new one starts) so it can track the *next* window of changes.

A **checkpoint** is just a named snapshot-in-time of "the bitmap as of backup
X". A chain of checkpoints looks like this:

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

---

## 4. What actually happens when you run `make backup` / `make cbt-backup`

```
   You: make backup VMS=fedora-cbt-1        (FULL)
        │
        ▼
   VirtualMachineBackup CR created ──► virt-launcher tells QEMU:
        │                              "start tracking a bitmap called
        │                               checkpoint-1, then copy the
        │                               WHOLE disk out to the backup PVC"
        ▼
   backup-output PVC now has:
   fedora-cbt-1-full/checkpoint-1/fedora-cbt-1-full-datadisk.qcow2
   (size ≈ full disk)


   You: make cbt-backup VMS=fedora-cbt-1     (INCREMENTAL)
        │
        ▼
   VirtualMachineBackup CR created ──► virt-launcher tells QEMU:
        │                              "give me everything dirty
        │                               since checkpoint-1, call this
        │                               batch checkpoint-2"
        ▼
   backup-output PVC now has:
   fedora-cbt-1-incremental/checkpoint-2/..-datadisk.qcow2
   (size ≈ only the changed bytes — should be MUCH smaller than full)
```

This is exactly what `make cbt-payload-proof` measures: it seeds known bytes,
takes a full backup, changes a *known, small* region, takes an incremental,
and then checks with `qemu-img map` (a tool that shows which byte ranges are
actually allocated in a qcow2 file) that:

- the incremental file contains the new bytes,
- the incremental file does **not** contain the old, already-backed-up bytes,
- the incremental is much smaller than a full backup of the same disk.

```
qemu-img map output (simplified)

Full backup map:        [DATA][DATA][DATA][DATA][DATA][DATA] ← everything
Incremental map:        [    ][    ][    ][DATA][    ][    ] ← only the
                                            ^^^^              changed part
                                       our canary write
```

That's proof by *physical bytes on disk*, not by trusting a status message
that says "Completed".

---

## 5. Why "trust the status field" is dangerous once you add chaos

Normally, KubeVirt's controller keeps a friendly status:

```
VirtualMachineBackupTracker.status.latestCheckpoint = checkpoint-2   ✅ looks fine
```

But now imagine we're chaos-testing: we kill the virt-launcher pod (simulate
a node crash) *while* a CBT backup is in flight, or right after.

```
                     💥 chaos: virt-launcher pod killed
                          │
                          ▼
   QEMU process dies ──► the CBT overlay's bitmap may not have been
                          closed cleanly ("in-use" / dirty-open state)
                          │
                          ▼
   virt-launcher pod restarts ──► KubeVirt tries RedefineCheckpoint()
                          │                to reattach the old bitmap
                          │                to the new QEMU process
                          │
               ┌──────────┴──────────┐
               ▼                     ▼
         succeeds cleanly      FAILS (HTTP 422)
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

## 6. The status-independent check: read the qcow2's own header

The resulting *backup* qcow2 (the one sitting in `backup-output` PVC after a
backup finishes) is just a file. `qemu-img info` decodes its header —
no privileges needed, no need to even open the file it's chained to:

```
┌─────────────────────────────────────────────────────────────┐
│  inspector pod (read-only mount of the backup-output PVC     │
│  ONLY — see the safety note below for why)                   │
│                                                                │
│   $ qemu-img info --output=json fedora-cbt-1-incremental-datadisk.qcow2
│   {                                                             │
│     "backing-filename":                                        │
│       "/var/run/kubevirt-private/libvirt/qemu/cbt/datadisk.qcow2" │
│     ...                                                         │
│   }                                                             │
│                                                                │
│   $ qemu-img info --output=json fedora-cbt-1-full-datadisk.qcow2 │
│   {  ...no "backing-filename" key at all...  }                  │
└─────────────────────────────────────────────────────────────┘
```

One fact, read straight from the header, decides everything:

- **Has a `backing-filename` pointing at `.../libvirt/qemu/cbt/<disk>.qcow2`?**
  → this artifact is a genuine CBT **Incremental** — its bytes only make sense
  chained to that bitmap overlay, so KubeVirt could not have produced this
  file any other way.
- **No `backing-filename` at all?** → self-contained **Full** backup.
- **Backing file points somewhere else?** → anomalous; treat as a failure.

This is exactly what `scripts/cbt-evidence-check.sh` does, and it is the
"correct way" this repo settled on. Two things worth calling out about *why*
it looks this simple:

1. **`qemu-img info` (no `--backing-chain`) never needs to open the backing
   file.** It just reads the string out of the qcow2 header. That means this
   check works even if the CBT overlay/bitmap PVC is completely unreachable
   — which matters, because reaching it safely turned out to be the hard
   part (see below).
2. An earlier design for this check also tried to open the *live* CBT
   overlay itself (to inspect QEMU's dirty-bitmap list and their `in-use`
   flags) for extra chain-integrity evidence. That was dropped — not because
   the idea was wrong in theory, but because doing it safely against a
   *running* VM turned out to be unsafe in practice. See §8.

---

## 7. Where this fits into chaos testing

```
  1. make density-setup N=<count>          create the VM pool
  2. make backup VMS=...                   baseline Full backup + evidence check
  3. ── inject chaos here ──►  kill virt-launcher / virt-handler /
                                ceph OSD / network partition / node reboot
  4. make cbt-backup VMS=...               Incremental backup taken during/after chaos
  5. make cbt-evidence VMS=...             re-check Full+Incremental evidence any time
                                            after chaos, independent of step 2/4's own
                                            in-line checks (useful if you want to
                                            re-verify later, e.g. after the controller
                                            has had time to reconcile)
     → PASS/FAIL decided by reading the backup qcow2's own header,
       never VirtualMachineBackup.status or controller logs
  6. record result (reports/<run>/summary.json + evidence/*.json), repeat with
     different chaos scenarios
```

`make backup`/`make cbt-backup`/`make verify` already run the evidence check
inline as part of the command. `make cbt-evidence` exists so you can re-run
just the evidence check standalone, any time later, without redoing the
backup — which is exactly the shape a chaos experiment needs ("inject chaos,
then verify what actually happened, without disturbing it further").

---

## 8. How this was actually verified — including a mistake worth knowing about

Verification happened in two stages against a real GCP OpenShift + ODF
cluster, not in the abstract.

**Stage 1 — prove the mechanism works at all (`make cbt-payload-proof`).**
This spins up a disposable, throwaway VM, seeds two known byte ranges,
takes a Full backup, writes a single new 4 MiB canary range, takes an
Incremental backup, and inspects both resulting qcow2 files with
`qemu-img map` (which byte ranges actually have data). A real run produced:

```
Full backup:         271,843,328 bytes allocated (both seeded ranges present)
Incremental backup:    4,194,304 bytes allocated (exactly the canary write —
                                                    both older seeded ranges
                                                    correctly absent)
Forced-full control: 276,037,632 bytes allocated (comparable to the real Full)
```

The incremental is ~65x smaller than a full backup of the same disk and
contains *only* the new bytes — proof, from physical file contents, that
CBT is genuinely tracking and exporting only changed blocks, not silently
copying everything.

**Stage 2 — make the ongoing evidence check itself safe (`cbt-evidence-check.sh`).**
This is where a real mistake happened and is worth recording so it isn't
repeated: an earlier version of the check mounted the VM's CBT-overlay/state
PVC into a *second* pod (to read live QEMU dirty-bitmap flags for extra
evidence). On this cluster, attaching an RBD-backed PVC to a second pod **on
the same node** as the running VM disrupted that node's other RBD mounts
badly enough to pause the live VM twice with a genuine low-level I/O error
— not a simulated chaos scenario, an actual incident caused by the
verification tooling itself.

The fix, and the reason the final design in §6 looks the way it does:

- **Never mount the CBT-overlay/state PVC into a second pod at all.** It's
  genuinely still attached to the live VM; there is no safe way to read it
  concurrently, and — per §6.1 — it isn't even necessary, since the backing
  file *name* is enough to prove Incremental-vs-Full without ever opening
  that file.
- The evidence-check pod only ever mounts the `*-backup-output` PVC (never
  attached to the live VM's own pod spec — it's hotplugged in transiently by
  the backup controller and detached again once the backup finishes), and is
  explicitly scheduled onto a **different node** than the VM as defense in
  depth.

After this fix, a full `make backup` → `make cbt-backup` → `make verify`
cycle was re-run end-to-end against a live VM: the VM stayed `Running` /
`ready: true` throughout, and both evidence checks passed
(`fedora-cbt-1-full` → physically `Full`; `fedora-cbt-1-incremental` →
physically `Incremental`, backed by
`/var/run/kubevirt-private/libvirt/qemu/cbt/datadisk.qcow2`) — this time
without disturbing the VM at all. That's the standard the rest of this repo
now holds itself to: verification tooling must be provably no more invasive
than the thing it's trying to verify.
