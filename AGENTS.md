# AGENTS.md

## Repository purpose

This repository contains Fedora-only OpenShift Virtualization and OpenShift Data Foundation CBT validation workflows. The primary operator interface is the root `Makefile`; the density workflow uses kube-burner and `scripts/odf-vm-validator.sh`.

## Project rules

- Keep the implementation Fedora-only unless the task explicitly expands scope.
- Use `config.example.env` for new configuration keys. Never commit `config.env`, kubeconfigs, SSH keys, or generated reports.
- Preserve namespace ownership safeguards. The validator may create or delete only namespaces labeled `app.kubernetes.io/managed-by=odf-cbt-validator`.
- Use `scripts/select-vms.sh` for every multi-VM operation. Do not rediscover VM selections independently in backup, CBT, status, or verification paths.
- Keep VM names and backup resources deterministic. Per-VM resources use the configured prefix and replica name, including the data PVC, backup PVC, tracker, Full backup, and Incremental backup.
- Keep guest workload data under `/data/vm-validator`; never silently fall back to the container disk.
- Backup verification must never rely on `VirtualMachineBackup.status`, `VirtualMachineBackupTracker.status`, or controller logs to decide Full-vs-Incremental correctness — those are exactly the signals a chaos scenario can leave stale, racy, or wrong. Use `scripts/cbt-evidence-check.sh` (reads the backup qcow2's own `backing-filename` header) as the authoritative signal instead; status/conditions may still be used as synchronization barriers (e.g. "has this backup CR reached a terminal condition yet") or as informational context. A completed backup CR is not proof of restoreability — use `make cbt-restore-proof` for Full+Incremental chain restore + guest hash comparison.
- **Never mount a VM's data PVC or CBT-overlay/state PVC (`persistent-state-for-<vm>-...`) into a second pod while the VM is running.** This was tried during development and caused a real low-level I/O pause on the live VM (RBD attach churn disrupting other mounts on the same node) — twice. The `<vm>-backup-output` PVC is safe to mount from a second, short-lived, read-only inspector pod (it's not part of the VM's own pod spec; KubeVirt only hotplugs it in transiently during a backup), but schedule that pod off the VM's current node as defense in depth (see `cbt-evidence-check.sh`'s `avoid_node` nodeAffinity). If a change needs evidence from the live CBT overlay/state PVC, stop the VM and wait until the VMI is gone first (as `cbt-payload-proof` does), or find another way — do not add a second concurrent mount while the guest is live. Prefer `cbt-restore-proof` + `cbt-evidence` for online-safe proofs.
- Reports must not contain kubeconfig contents, private keys, or other credentials.
- Update README and `docs/cbt/CBT-EXPLAINED.md` when changing the operator workflow, the verification mechanism, or the Make target surface.
- Retain `manifests/` compatibility for existing chaos-specific runbooks unless the task explicitly migrates them.

## Validation commands

Run focused checks before committing:

```bash
bash -n scripts/odf-vm-validator.sh scripts/select-vms.sh scripts/cbt-evidence-check.sh scripts/classify-cbt-result.sh scripts/run-cbt-krkn-scenario.sh
make help
make -n density-setup N=2
make -n backup VMS=fedora-cbt-1,fedora-cbt-2
make -n cbt-backup n=2
make -n verify ALL=1
make -n cbt-evidence ALL=1
make -n cbt-restore-proof
make -n density-teardown ALL=1 CONFIRM=1
```

For selector changes, exercise sorted count selection, explicit names, duplicate names, missing names, zero counts, over-sized counts, and multiple selection modes. For kube-burner changes, render a sample job and parse the resulting YAML. VM names produced by `density-setup` are 1-indexed (`<VM_PREFIX>-1` .. `<VM_PREFIX>-N`), not 0-indexed.

Cloud-cluster validation is disposable and must use a unique namespace, the blue-cluster kubeconfig, and cleanup via a shell `trap`. Do not install software or change cluster-level ODF/CBT configuration as a fallback. macOS ships bash 3.2; these scripts need bash 4+ (`declare -A`) — put `/opt/homebrew/bin` ahead of `/bin` in `PATH` before running anything against a real cluster.

For a full end-to-end exercise of this workflow against a live cluster (VM creation → Full backup → Incremental backup → verify → evidence-based result analysis), use the `cbt-test` skill (`.claude/skills/cbt-test/SKILL.md`) rather than improvising the command sequence — it encodes the ordering, the known_hosts/bash gotchas, and the safety rule about not mounting the CBT-overlay PVC from a second pod.

## Change workflow

1. Read the affected Make, script, template, and documentation sections before editing.
2. Keep changes focused; do not add unrelated tooling or generated files.
3. Run focused syntax, dry-run, and scenario checks for the changed behavior.
4. Report any cloud-cluster limitation or failed prerequisite exactly; do not claim unexecuted verification.
5. If a change to cluster-facing scripts risks disrupting a running VM (e.g. adding a new pod that mounts a PVC), reason through what else already has that PVC attached before running it against anything other than a fully disposable VM/namespace.
