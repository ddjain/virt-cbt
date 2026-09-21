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
- Backup verification must require the expected type (`Full` or `Incremental`) and tracker checkpoint progression. A completed backup CR is not proof of restoreability.
- Reports must not contain kubeconfig contents, private keys, or other credentials.
- Update README and `docs/cbt/CBT-TEST-GUIDE.md` when changing the operator workflow or Make target surface.
- Retain `manifests/` compatibility for existing chaos-specific runbooks unless the task explicitly migrates them.

## Validation commands

Run focused checks before committing:

```bash
bash -n scripts/odf-vm-validator.sh scripts/select-vms.sh
make help
make -n density-setup N=2
make -n backup VMS=fedora-cbt-0,fedora-cbt-1
make -n cbt-backup n=2
make -n verify ALL=1
```

For selector changes, exercise sorted count selection, explicit names, duplicate names, missing names, zero counts, over-sized counts, and multiple selection modes. For kube-burner changes, render a sample job and parse the resulting YAML.

Cloud-cluster validation is disposable and must use a unique namespace, the blue-cluster kubeconfig, and cleanup via a shell `trap`. Do not install software or change cluster-level ODF/CBT configuration as a fallback.

## Change workflow

1. Read the affected Make, script, template, and documentation sections before editing.
2. Keep changes focused; do not add unrelated tooling or generated files.
3. Run focused syntax, dry-run, and scenario checks for the changed behavior.
4. Report any cloud-cluster limitation or failed prerequisite exactly; do not claim unexecuted verification.
