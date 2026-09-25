# `status` prints the tracker checkpoint object instead of its name

## Description

The `status` table's Checkpoint column reads `.status.latestCheckpoint` as a whole. On the current API, that field is an object containing `creationTime`, `name`, and `volumes`; `make status` prints the multiline JSON object into the table instead of the checkpoint name. The row becomes misaligned and the displayed checkpoint cannot be consumed as the documented name.

## Environment

- Darwin arm64 workstation; GNU Bash 5.3.20
- OpenShift 4.22.14; ODF 4.21.12
- Disposable namespace `qa-cbt-mktemp-a-20260925`
- `VirtualMachineBackupTracker/qa-cbt-a-1-tracker` had completed Full and Incremental checkpoints

## Reproduction

```bash
make status CONFIG=/tmp/virt-cbt-retest-mktemp-a-20260925.env VMS=qa-cbt-a-1
```

## Expected

The Checkpoint column contains one scalar checkpoint name, e.g. `qa-cbt-a-1-incremental-2026-09-25_01-12-03`, on the VM row.

## Actual

The command exited `0`, but printed `Incremental` followed by a multiline object in the Checkpoint column:

```text
qa-cbt-a-1  true  Running  Enabled  Full  Incremental  {
  "creationTime": "2026-09-25T01:12:03Z",
  "name": "qa-cbt-a-1-incremental-2026-09-25_01-12-03",
  "volumes": [ ... ]
}
```

Independent `oc get virtualmachinebackuptracker ... -o json` confirmed that `status.latestCheckpoint` is an object whose `name` is `qa-cbt-a-1-incremental-2026-09-25_01-12-03`. No cluster resource was modified by `make status`.

- Reproduced again after `cbt-cycle`: `make status CONFIG=/tmp/virt-cbt-retest-mktemp-a-20260925.env VMS=qa-cbt-a-1` exited `0` and printed the object for checkpoint `qa-cbt-a-1-incremental-2026-09-25_01-42-40` (creation time `2026-09-25T01:42:40Z`). `oc` and `kubectl` both reported that same tracker checkpoint name and the matching Incremental VMB.
- Reproduced on the current retest pool: `make status CONFIG=/tmp/virt-cbt-full-20260925-0305.env VMS=qa-cbt-exhaustive-2` exited `0` and printed a multiline Checkpoint object for `qa-cbt-exhaustive-2-incremental-2026-09-25_03-17-50`; `oc`/`kubectl` independently returned that same latest checkpoint object. During an in-progress retry, the Incremental column also rendered the `backup target PVC ... being attached` condition reason instead of a backup type.
- Post-terminal retest: `make status` printed `Full`, `Incremental`, then the multiline object for `qa-cbt-exhaustive-2-incremental-2026-09-25_03-17-50`. `oc` and `kubectl` both showed the tracker at that same Incremental checkpoint; command exited 0.

## Errors / logs

No runtime error or report. The table output itself is malformed for the current checkpoint API shape.

## Source references

- `scripts/odf-vm-validator.sh:531`: `status_selected` evaluates `.status.latestCheckpoint // .status.checkpointName`, returning the object unchanged.
- `README.md` and `Makefile` describe `status` as a VM/tracker/backup state table.

## Root cause

The code handles older scalar checkpoint status but not the current object-shaped `latestCheckpoint`. `jq -r` emits the object as multiline JSON, which is inserted into a fixed-width table cell.

## Suggested fix

Extract `.status.latestCheckpoint.name // .status.latestCheckpoint // .status.checkpointName // "-"` (or handle both API shapes explicitly), then test status formatting against scalar and object checkpoint forms.
