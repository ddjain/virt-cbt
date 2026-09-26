# CBT Branch Cluster-Test Issues

## Scope and outcome

The new `make verify-cbt` target was exercised against the configured Blue cluster using an isolated namespace, `cbt-verify-1790405609`. The namespace was deleted after testing; the pre-existing `cbt-gcp-20260923` pool was left intact. No kubeconfig contents, private keys, or credentials are included here.

The end-to-end Full → Incremental → restore-hash path passed after two branch defects were fixed in commit `78c0491` (`Fix CBT backup lock and guest check`). The two remaining findings below are resolved in this branch.

## Resolved findings

### 1. `config.env` contains an unsupported key

`make check-prereqs` exits before contacting the cluster because the script rejects `BACKUP_CONCURRENCY` in the local `config.env`.

```console
$ /usr/bin/time -p make check-prereqs CONFIG=config.env
ERROR: unsupported config key in config.env: BACKUP_CONCURRENCY
make: *** [check-prereqs] Error 2
real 1.27
user 0.01
sys 0.02
```

For preflight, a temporary config omitted only that key. The end-to-end run used a second temporary copy with the key omitted and a unique test namespace; the repository's `config.env` was not changed.

```console
$ /usr/bin/time -p make check-prereqs CONFIG=<temporary config>
Prerequisites OK
real 7.62
user 0.61
sys 0.58
```

**Status:** Resolved. `BACKUP_CONCURRENCY` was retired in `ebabdb3` because the validator executes selected VMs serially. The loader now warns and ignores the stale setting so existing private configs can run; new configs must omit it.

### 2. `make backup-reset` is not dispatched by the script

The Make target invokes `backup-reset`, but the script command dispatcher falls through to usage instead of calling `backup_reset_selected`.

```console
$ /usr/bin/time -p make backup-reset N=1 CONFIG=<temporary config>
Usage: odf-vm-validator.sh [--config FILE] COMMAND [options]
Commands: generate-keys check-prereqs density-setup density-status density-teardown[--all] discover-vms backup cbt-backup verify-cbt backup-reset cbt-cycle cbt-payload-proof cbt-restore-proof cbt-evidence cbt-diagnostics verify status ssh report list-reports e2e
Selection options: --vms CSV | --count N | --selector key=value | --all
make: *** [backup-reset] Error 2
real 0.42
user 0.02
sys 0.01
```

The usage text lists `backup-reset`, but it is absent from the dispatch `case`. The command made no cluster changes: `oc` still showed `fedora-cbt-1-full`, `fedora-cbt-1-incremental`, the prior tracker checkpoint `fedora-cbt-1-incremental-2026-09-25_16-28-21`, and the unchanged backup-output PVC UID `edbf31df-6285-4c38-917c-f8a7a00a6f9a` in `cbt-gcp-20260923`.

**Status:** Resolved. `backup-reset` is dispatched to `backup_reset_selected`, which retains the existing ownership safeguards before deleting or recreating resources.

## Fixed branch defects

### 3. VM lock creation used an unsupported `oc` flag

The initial Full-backup attempt failed while creating the validator lock ConfigMap:

```text
error: unknown flag: --labels
See 'oc create configmap --help' for usage.
ERROR: VM/fedora-cbt-1 is already locked by another validator run (fedora-cbt-1-cbt-lock)
[06:55:48] [INFO] [RESULT] fedora-cbt-1 FAIL — backup failed
real 2.95
```

The lock error was misleading: independent `oc` queries found no lock ConfigMap, no backup CRs, and no tracker checkpoint in the isolated namespace. Commit `78c0491` creates the labeled ConfigMap from YAML using `oc create -f -`, preserving create-if-absent lock semantics.

### 4. `guest_check` sent an invalid remote shell command

The next attempt reached the guest but repeatedly failed on an extra `)` at the end of the multiline Python command:

```text
bash: -c: line 11: syntax error near unexpected token `)'
bash: -c: line 11: `")'
Client Version: v1.7.0
Server Version: v1.8.4
exit status 2
ERROR: guest workload did not become healthy on fedora-cbt-1 within 1200s
[07:17:33] [INFO] [RESULT] fedora-cbt-1 FAIL — backup failed
real 1215.23
```

Commit `78c0491` removes the extra parenthesis. `bash -n scripts/odf-vm-validator.sh` passed, and the subsequent cluster run exercised the corrected guest check.

## Successful verification after fixes

- Full backup: 582.47 s. VMB reached `Done`; the qcow2 evidence reported `physicalType=Full`, empty `backingFile`, `match=true`, and `allocatedDataBytes=2761949184`. The report was `INCONCLUSIVE` with `failed=0`, as expected before restore verification.
- Incremental backup: 560.33 s. VMB reached `Done`; the qcow2 evidence reported `physicalType=Incremental`, `backingFile=/var/run/kubevirt-private/libvirt/qemu/cbt/datadisk.qcow2`, and `match=true`. The report was `INCONCLUSIVE` pending restore verification.
- New `make verify-cbt VMS=fedora-cbt-1`: 562.46 s; `passed=1`, `failed=0`, `inconclusive=0`. The expected and restored hashes both equaled `a425a06d0796e7c39de8effaa385ff3482ef1f998536f3b699fc5d7a5ac8f94f`.
- Independent `oc` checks showed the source VM remained `ready=true`, CBT `Enabled`, and its VMI `Running`; Full and Incremental UIDs matched the report and tracker. Temporary restore VM/PVC resources were absent after verification.
- The LLM judge assessed the Full and Incremental results as structurally correct but not recovery passes, judged `verify-cbt` **PASS**, and judged teardown safe. The isolated namespace was deleted; the original namespace and VM remained active and healthy.

Run reports and detailed evidence are retained under `reports/`, including the Full, Incremental, and `verify-cbt` run summaries and qcow2 evidence JSON.

### Make command timings

Measured with `/usr/bin/time -p` (`real`):

| Command | Time | Result |
|---|---:|---|
| `make check-prereqs CONFIG=config.env` | 1.27 s | Rejected `BACKUP_CONCURRENCY` |
| `make check-prereqs CONFIG=<temporary config>` | 7.62 s | PASS |
| `make density-status CONFIG=<temporary config>` | 2.36 s | PASS; existing pool healthy |
| `make backup-reset N=1 CONFIG=<temporary config>` | 0.42 s | Usage error; no reset |
| `make density-setup N=1 CONFIG=<isolated config>` | 85.74 s | PASS |
| `make backup VMS=fedora-cbt-1` — first attempt | 2.95 s | Failed on unsupported `--labels` |
| `make backup VMS=fedora-cbt-1` — second attempt | 20:15.23 | Failed on guest shell syntax error and timeout |
| `make backup VMS=fedora-cbt-1` — after fixes | 9:42.47 | INCONCLUSIVE; physical Full verified |
| `make cbt-backup VMS=fedora-cbt-1` | 9:20.33 | INCONCLUSIVE; physical Incremental verified |
| `make verify-cbt VMS=fedora-cbt-1` | 9:22.46 | PASS |
| `make density-teardown CONFIG=<isolated config>` | 56.41 s | PASS; isolated namespace deleted |
