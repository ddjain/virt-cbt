# CBT E2E Smoke Run — 2026-09-24

Record of a fresh-VM Full → Incremental → verify pipeline run against the
blue-cluster ODF/KubeVirt environment. Correctness was decided from qcow2
`backing-filename` evidence (via `scripts/cbt-evidence-check.sh`), **not**
from `VirtualMachineBackup.status`.

For concepts, see [CBT-EXPLAINED.md](CBT-EXPLAINED.md). For the operator
workflow, see the root [README.md](../../README.md) and
[CBT-TEST-GUIDE.md](CBT-TEST-GUIDE.md).

---

## Verdict: PASS — CBT Incremental backup is physically in place

Fresh VM pool was left **running** in `cbt-gcp-20260923` after this run.

---

## 1. What was created

| Item | Value |
|---|---|
| Cluster | blue-cluster (`KUBECONFIG=…/virt-cbt/kubeconfig`) |
| Namespace | `cbt-gcp-20260923` |
| VM | `fedora-cbt-1` (1-indexed) |
| Node | `blue-cluster-qjm5h-worker-c-b8rlx.c.cclm-chaos-testing.internal` |
| Launcher pod | `virt-launcher-fedora-cbt-1-24lpd` |
| CBT state | `Enabled` |
| Guest IP | `10.225.5.173` |

---

## 2. Pass / Fail summary

| Step | Result | Physical proof |
|---|---|---|
| Full backup | **PASS** | No `backing-filename`; allocated **3,892,314,112 B (~3.6 GiB)** |
| Incremental (CBT) | **PASS** | `backing-filename` = `/var/run/kubevirt-private/libvirt/qemu/cbt/datadisk.qcow2` |
| Verify | **PASS** | Both evidence checks + guest workload integrity |
| Standalone `cbt-evidence` re-check | **PASS** | Same Full / Incremental verdict again |

---

## 3. Where everything lives

### A. Backup destination PVC (where qcow2 backups are written)

- **PVC name:** `fedora-cbt-1-backup-output`
- **PV:** `pvc-1939bb2d-b8d3-493d-b309-73e64d29c11c`
- **Size / SC:** 8Gi, `ocs-storagecluster-ceph-rbd`
- **Role:** KubeVirt hot-plugs this into the launcher during backup, then unplugs it. Safe to mount from a second inspector pod (off the VM node).

### B. Full backup artifact

| Field | Value |
|---|---|
| CR | `VirtualMachineBackup/fedora-cbt-1-full` |
| Mode | `Push` |
| Target PVC | `fedora-cbt-1-backup-output` |
| Checkpoint name | `fedora-cbt-1-full-2026-09-24_06-55-07` |
| File path **inside** backup PVC | `fedora-cbt-1/fedora-cbt-1-full-2026-09-24_06-55-07/fedora-cbt-1-full-datadisk.qcow2` |
| Inspector mount path | `/proof/fedora-cbt-1/fedora-cbt-1-full-2026-09-24_06-55-07/fedora-cbt-1-full-datadisk.qcow2` |
| Physical type | **Full** (empty backing file) |

### C. Incremental / dirty-block backup artifact

| Field | Value |
|---|---|
| CR | `VirtualMachineBackup/fedora-cbt-1-incremental` |
| Mode | `Push` |
| Target PVC | **same** `fedora-cbt-1-backup-output` |
| Checkpoint name | `fedora-cbt-1-incremental-2026-09-24_06-57-31` |
| File path **inside** backup PVC | `fedora-cbt-1/fedora-cbt-1-incremental-2026-09-24_06-57-31/fedora-cbt-1-incremental-datadisk.qcow2` |
| Inspector mount path | `/proof/fedora-cbt-1/fedora-cbt-1-incremental-2026-09-24_06-57-31/fedora-cbt-1-incremental-datadisk.qcow2` |
| Physical type | **Incremental** |
| Backing file (proves CBT) | `/var/run/kubevirt-private/libvirt/qemu/cbt/datadisk.qcow2` |

Both backup files sit on the **same** backup-output PVC, under different checkpoint directories.

### D. Dirty-bitmap / CBT overlay (live tracking — not the backup copy)

This is **not** inside `fedora-cbt-1-backup-output`. It is the live QEMU dirty-bitmap store:

| Field | Value |
|---|---|
| PVC name | `persistent-state-for-fedora-cbt-1-sgrmk` |
| PV | `pvc-7a8ab2b1-0b24-4e3c-8b12-8fdedc25b4fd` |
| Size | 554Mi |
| Mount in launcher | `/var/run/kubevirt-private/libvirt/qemu/cbt` |
| Overlay file | `…/cbt/datadisk.qcow2` |
| Real guest data disk PVC | `fedora-cbt-1-data` → mounted at `/var/run/kubevirt-private/vmi-disks/datadisk` (guest `/dev/vdc`) |

**Important:** this CBT-state PVC was **not** mounted from a second pod (known to cause live VM I/O pause on this class of cluster). Proof of CBT used only the backup-output qcow2 header.

### E. Checkpoint / bitmap names (tracker)

| Checkpoint | Created by | Role |
|---|---|---|
| `fedora-cbt-1-full-2026-09-24_06-55-07` | Full backup | Baseline bitmap checkpoint |
| `fedora-cbt-1-incremental-2026-09-24_06-57-31` | Incremental | Current latest; dirty blocks since Full |

Tracker `fedora-cbt-1-tracker` reported:

```text
latestCheckpoint.name = fedora-cbt-1-incremental-2026-09-24_06-57-31
volumes = [{ volumeName: datadisk, diskTarget: vdc }]
```

---

## 4. Step-by-step: commands run, and what ran underneath

Every `make` target is a thin wrapper around `scripts/odf-vm-validator.sh`.
Session `PATH` put `/opt/homebrew/bin` first (bash 4+); `KUBECONFIG` pointed
at the repo kubeconfig.

### Step 0 — Preflight

**Executed:**

```bash
export PATH="/opt/homebrew/bin:$PATH"
export KUBECONFIG=/Users/darjain/projects/redhat-chaos/virt-cbt/kubeconfig
which oc virtctl kube-burner jq
bash --version
grep -E '^(KUBECONFIG|NAMESPACE|VM_COUNT|VM_PREFIX)=' config.env
oc whoami
oc get storagecluster,cephcluster -n openshift-storage
make check-prereqs
make density-status
```

**Under `check-prereqs`:**

- `oc get crd virtualmachines.kubevirt.io virtualmachinebackups… virtualmachinebackuptrackers…`
- `oc get storageclass …`
- `oc get storagecluster,cephcluster -n openshift-storage`
- `oc get volumesnapshotclass …`
- `oc get hyperconverged -A …` (CBT enabled check)

Result: `system:admin`, ODF `HEALTH_OK`, `Prerequisites OK`. An existing
pool with `fedora-cbt-1` + Full checkpoint was found and then torn down
(user requested a fresh start).

### Step 1 — Tear down old pool

**Executed:** `make density-teardown`

**Underneath:**

```bash
oc get namespace cbt-gcp-20260923 -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}'
# must be odf-cbt-validator
oc delete namespace cbt-gcp-20260923 --wait=true
```

### Step 2 — Fresh VM (`N=1`)

**Executed:** `make density-setup N=1` then `make density-status`

**Underneath:**

```bash
oc create namespace cbt-gcp-20260923
oc label namespace cbt-gcp-20260923 app.kubernetes.io/managed-by=odf-cbt-validator --overwrite
# render kube-burner/odf-cbt-density.yml → kube-burner/rendered/density.XXXX.yml
kube-burner init --config rendered/<job>.yml --kubeconfig "$KUBECONFIG" --log-level error
# poll until ready=true AND changedBlockTracking.state=Enabled
oc wait --for=jsonpath='{.status.ready}'=true vm/fedora-cbt-1 -n cbt-gcp-20260923 …
oc wait --for=jsonpath='{.status.phase}'=Running vmi/fedora-cbt-1 …
```

Kube-burner created: VM, `fedora-cbt-1-data`, `fedora-cbt-1-backup-output`,
`fedora-cbt-1-tracker`. KubeVirt later attached
`persistent-state-for-fedora-cbt-1-sgrmk` for CBT.

Confirmed: `ready=true`, `changedBlockTracking.state=Enabled`.

### Step 3 — Full backup

**Executed:** `make backup VMS=fedora-cbt-1`

**Underneath:**

```bash
# select-vms.sh → fedora-cbt-1
oc get virtualmachinebackuptracker fedora-cbt-1-tracker …  # ensure no prior checkpoint
oc delete virtualmachinebackup fedora-cbt-1-full --ignore-not-found --wait=true
oc apply -f -   # VirtualMachineBackup fedora-cbt-1-full, mode=Push, pvcName=fedora-cbt-1-backup-output
oc wait --for=jsonpath='{.status.conditions[?(@.type=="Done")].status}'=True virtualmachinebackup/fedora-cbt-1-full …
# then scripts/cbt-evidence-check.sh:
oc apply … pod/fedora-cbt-1-full-evidence   # RO mount of backup-output ONLY, NotIn VM node
oc exec … -- qemu-img info --output=json /proof/.../fedora-cbt-1-full-datadisk.qcow2
oc delete pod fedora-cbt-1-full-evidence
```

Output: `physically Full (backing=), allocated=3892314112B`

### Step 4 — Dirty marker attempt + Incremental

**Attempted:** `make ssh VM=fedora-cbt-1 CMD='sudo -n dd …'` → **failed**
(`make` Error 2: `CMD=` quoting broke `--cmd` parsing). Guest workload
still dirties blocks continuously via `vm-validator`.

**Executed:** `make cbt-backup VMS=fedora-cbt-1`

**Underneath:**

```bash
sleep $CBT_CHANGE_WAIT   # default 5s
oc get virtualmachinebackup fedora-cbt-1-full …           # require Full exists
oc get tracker … latestCheckpoint                         # require prior checkpoint
oc delete virtualmachinebackup fedora-cbt-1-incremental …
oc apply -f -   # VirtualMachineBackup fedora-cbt-1-incremental → same backup-output PVC
oc wait … Done
# cbt-evidence-check.sh again expecting Incremental
```

Output: `physically Incremental (backing=/var/run/kubevirt-private/libvirt/qemu/cbt/datadisk.qcow2)`

### Step 5 — Verify

**Executed:** `make verify VMS=fedora-cbt-1`

**Underneath:**

```bash
oc wait vm/vmi ready+Running
oc get vm … | jq 'changedBlockTracking.state=="Enabled"'
oc get pvc fedora-cbt-1-data fedora-cbt-1-backup-output … Bound
# re-evidence Full + Incremental via cbt-evidence-check.sh
virtctl ssh … --command '… sqlite integrity + digest check …'   # twice
```

Result: `passed=1`. Transient noise: stale SSH host key warning (VM
recreated with same name) + one `database is locked` from the live SQLite
writer; second guest check succeeded.

### Step 6 — Standalone evidence re-check

**Executed:** `make cbt-evidence VMS=fedora-cbt-1` → both still match.

---

## 5. Local reports written

| Report dir | Command |
|---|---|
| `reports/run-20260924T065503Z-backup/` | Full |
| `reports/run-20260924T065721Z-cbt-backup/` | Incremental |
| `reports/run-20260924T070349Z-verify/` | Verify |
| `reports/run-20260924T070749Z-cbt-evidence/` | Re-check |

Evidence JSONs under each `evidence/` folder record `physicalType`,
`backingFile`, `artifactPath`, `allocatedDataBytes`, `match`.

---

## 6. Anomalies checked

| Issue | Severity | Notes |
|---|---|---|
| SSH dirty-marker write failed | Low | Make `CMD=` quoting; CBT still proven via qcow2 backing-file |
| Stale `known_hosts` after recreate | Expected | Verify still passed via virtctl `--known-hosts=/dev/null` |
| SQLite “database is locked” once | Transient | Live guest writer; retry passed |
| VMI `Paused` / `PausedIOError` | None | Not present |

---

## 7. Mental model (this run)

```text
Guest data disk PVC:     fedora-cbt-1-data
CBT dirty-bitmap PVC:    persistent-state-for-fedora-cbt-1-sgrmk
                         └─ file: /var/run/kubevirt-private/libvirt/qemu/cbt/datadisk.qcow2
                            (live bitmaps for checkpoints)

Backup destination PVC:  fedora-cbt-1-backup-output
  ├─ …/fedora-cbt-1-full-2026-09-24_06-55-07/fedora-cbt-1-full-datadisk.qcow2
  │     = Full copy of whole disk (no backing)
  └─ …/fedora-cbt-1-incremental-2026-09-24_06-57-31/fedora-cbt-1-incremental-datadisk.qcow2
        = dirty blocks only since Full checkpoint
        = backing-filename points at CBT overlay → proves CBT was used
```
