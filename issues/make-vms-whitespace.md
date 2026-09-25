# Make selection breaks CSV values containing whitespace

## Description

`select-vms.sh` explicitly removes whitespace around CSV VM names, but the Make recipes expand `VMS` unquoted. A comma-separated value with a conventional space after the comma is split into extra shell arguments, so the documented Make interface fails even though the selector script supports the same input.

## Environment

- Darwin arm64 workstation; GNU Bash 5.3.20; GNU Make
- OpenShift identity: `system:admin`
- Namespace: `cbt-gcp-20260923`; both requested VMs exist and are utility-managed

## Reproduction

The helper accepts the CSV as one argument:

```bash
scripts/select-vms.sh \
  --kubeconfig /Users/darjain/projects/redhat-chaos/virt-cbt/kubeconfig \
  --namespace cbt-gcp-20260923 \
  --base-selector app.kubernetes.io/name=odf-cbt-validator \
  --vms 'fedora-cbt-1, fedora-cbt-2'
```

Then use the Make operator interface:

```bash
make discover-vms VMS='fedora-cbt-1, fedora-cbt-2'
```

## Expected

Print both `fedora-cbt-1` and `fedora-cbt-2`, matching the helper's normalization behavior.

## Actual

The direct helper printed both VM names. The Make target exited non-zero with:

```text
ERROR: unknown option fedora-cbt-2
make: *** [discover-vms] Error 2
```

No cluster resources were modified.

## Errors / logs

No run report. Failure occurs during argument parsing in `scripts/odf-vm-validator.sh`.

## Source references

- `scripts/select-vms.sh:28-29`: splits CSV entries and removes whitespace from each name.
- `Makefile:63`: emits `--vms $(VMS)` without quoting; the same unquoted expansion appears in selection-bearing recipes.
- `README.md:122-124`: documents `VMS=a,b` as a selector but does not explicitly forbid spaces.

## Root cause

The Make recipe expands a CSV containing spaces into multiple shell words, while the validator expects the CSV value as the single argument following `--vms`.

## Suggested fix

Quote the expanded `VMS` argument in each Make recipe (or reject/document whitespace consistently). Preserve the helper's existing trimming behavior if spaced CSV is intended to be supported.

## Post-fix retest

On 2026-09-25, `make discover-vms CONFIG=/tmp/virt-cbt-retest-pool-20260925.env VMS='fedora-cbt-1, fedora-cbt-2'` exited `0` and printed both names in order. Make preserved the CSV as one argument; no resources were modified.

Current-session retest against the live two-VM pool: `make discover-vms CONFIG=/tmp/virt-cbt-full-20260925-0305.env VMS='qa-cbt-exhaustive-1, qa-cbt-exhaustive-2'` returned both names successfully; the CSV stayed a single argument.
