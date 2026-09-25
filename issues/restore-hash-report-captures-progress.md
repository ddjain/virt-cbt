# Restore proof summary stores command output as restoredHash

## Description

A successful `cbt-restore-proof` run recorded `match: true`, but its `restoredHash` JSON field contains PVC/VM create messages and SSH progress lines before the final hash. The Full+Incremental restore itself passed: the final hash in that string equals `hash2`, and an independent `virtctl ssh sha256sum` returned the same hash. The report's structured hash field is not a hash, so downstream consumers comparing `hash2` to `restoredHash` cannot trust it.

## Environment

- Darwin arm64 workstation; GNU Bash 5.3.20
- OpenShift 4.22.14, ODF 4.21.12; OpenShift StorageCluster Ready and Ceph `HEALTH_OK`
- Disposable namespace `cbt-restore-260924194421`, cleaned after the proof

## Reproduction

```bash
make cbt-restore-proof
```

Retained run: `reports/run-20260924T194422Z-cbt-restore-proof/`.

Expected `hash2`: `0b7ef0a518b06a490e2efa418f8345612a96b0263e27fd8c17acdd813d6d1adb`.

Independent check against the restored guest returned that exact SHA-256 for `/data/vm-validator/cbt-restore-proof.bin`.

## Expected

`evidence/cbt-restore-vm-1-restore-proof.json.restoredHash` is exactly the 64-character `hash2`, and `match` is true only when those two strings are equal.

## Actual

The Make target exited successfully and its summary reported `passed=1`, `failed=0`. However, `restoredHash` contains:

```text
persistentvolumeclaim/cbt-restore-vm-1-restore-data created
persistentvolumeclaim/cbt-restore-vm-1-restore-data condition met
pod/cbt-restore-vm-1-restore-converter created
pod/cbt-restore-vm-1-restore-converter condition met
secret/cbt-restore-vm-1-restored-userdata created
virtualmachine.kubevirt.io/cbt-restore-vm-1-restored created
virtualmachine.kubevirt.io/cbt-restore-vm-1-restored condition met
virtualmachineinstance.kubevirt.io/cbt-restore-vm-1-restored condition met
Waiting for guest SSH on cbt-restore-vm-1-restored
Guest SSH ready: cbt-restore-vm-1-restored
0b7ef0a518b06a490e2efa418f8345612a96b0263e27fd8c17acdd813d6d1adb
```

The final line is the real hash and matches `hash2`; the structured `restoredHash` value as a whole does not. `run.log` separately prints `restored_hash=<hash2>` and `CBT restore proof PASS`.

## Errors / logs

No command error; Make exit code was `0`. The inconsistency is in the JSON report and per-VM evidence. Files:

- `reports/run-20260924T194422Z-cbt-restore-proof/evidence/cbt-restore-vm-1-restore-proof.json`
- `reports/run-20260924T194422Z-cbt-restore-proof/summary.json`
- `reports/run-20260924T194422Z-cbt-restore-proof/run.log:28-33`

## Source references

- `scripts/odf-vm-validator.sh:1055-1081`: `restore_chain_and_verify_hash` emits progress and the final hash on stdout.
- `scripts/odf-vm-validator.sh:1220-1235`: the caller captures the whole function stdout into `restored_hash` and serializes that value.

## Root cause

`restored_hash=$(restore_chain_and_verify_hash ...)` captures every stdout line from the function's nested `oc apply`, `oc wait`, and guest-readiness messages, not only the final `printf` hash. The function's internal local hash comparison succeeds, but the caller serializes the noisy command-substitution output as the hash.

## Suggested fix

Keep progress/status messages from `restore_chain_and_verify_hash` and its nested helpers on stderr (including `oc apply`/`oc wait` output), leaving stdout exclusively for the 64-character hash. Before writing evidence, validate that `restored_hash` is exactly a SHA-256 string and compute `match` from `restored_hash == hash2`; apply the same contract to `cbt-cycle`.

## Post-fix retest

On 2026-09-25, both `make cbt-cycle CONFIG=/tmp/virt-cbt-retest-mktemp-a-20260925.env VMS=qa-cbt-a-1` and `make cbt-restore-proof CONFIG=/tmp/virt-cbt-retest-mktemp-a-20260925.env` produced structured evidence whose `restoredHash` is exactly 64 lowercase hex characters and equals the corresponding `hash1`/`hash2`. The dedicated proof summary has `match=true`, `passed=1`; its run log confirms Full and Incremental physical headers match, and the disposable namespace was independently `NotFound` in both `oc` and `kubectl`. The report-format defect is fixed.

Current-session `cbt-cycle` run `reports/run-20260925T033316Z-cbt-cycle/` produced `hash1 == restoredHash == a2c1538dd1fa718fb411e352ee77de3f41f76d9f377918ebbc10486c1ccbb379` and `match:true`; its summary reports one PASS and `oc`/`kubectl` agree on both checkpoint names. A direct SSH probe against the transient restored VM raced its cleanup and returned `NotFound`; a separate read-only SHA-256 query of the still-running source marker returned `hash1`.

Current-session dedicated proof `reports/run-20260925T035854Z-cbt-restore-proof/summary.json` contains `hash1=374823978e55f9d02f23eea7d33e1792a37a0959ba46e04f4638ae1e17b2c3f2`, `hash2=restoredHash=baf5862d51e098214420f9428851876519b255623876c4d348b50b886d684eb3`, and `match=true`. Both `oc` and `kubectl` confirmed the disposable namespace was removed. This directly re-verifies the dedicated target's structured hash field.

