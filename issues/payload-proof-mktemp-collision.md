# Concurrent proof runs collide on the rendered kube-burner filename

## Description

Two disposable `cbt-payload-proof` invocations overlapped. The first created the literal shared path `kube-burner/rendered/density.XXXX.yml`; the second failed at `mktemp` with `File exists`, recorded a failed proof, and deleted its namespace. This exposes a non-unique temporary filename on this macOS host and prevents concurrent proof invocations from both reaching kube-burner.

## Environment

- Darwin arm64; `/usr/bin/mktemp`; GNU Bash 5.3.20
- OpenShift 4.22.14; ODF 4.21.12
- Each proof invocation uses its own generated, utility-owned namespace

## Reproduction / evidence

Run in two concurrent shells. Start the second command while the first is still in setup/kube-burner initialization:

```bash
# Terminal A
make cbt-payload-proof

# Terminal B, before Terminal A finishes
make cbt-payload-proof
```

The first run created `cbt-proof-260924202200`. While it was active, the second created and labeled `cbt-proof-260924202312`, then failed before VM creation. Its `run.log` and summary are in `reports/run-20260924T202314Z-cbt-payload-proof/`.

## Expected

Each invocation should allocate a unique rendered job file, or reject concurrent execution before creating a namespace with a clear, intentional message.

## Actual

The second run logged:

```text
mktemp: mkstemp failed on /Users/darjain/projects/redhat-chaos/virt-cbt/kube-burner/rendered/density.XXXX.yml: File exists
namespace "cbt-proof-260924202312" deleted
```

Make exit code: `2`. The report summary recorded `FAIL`, `passed=0`, `failed=1`; its namespace cleanup succeeded. The first run continued separately. The original 10-VM pool was untouched.

## Errors / logs

- Failure log: `reports/run-20260924T202314Z-cbt-payload-proof/run.log:1-7`.
- Failure summary: `reports/run-20260924T202314Z-cbt-payload-proof/summary.json`.
- Rendered path present during overlap: `kube-burner/rendered/density.XXXX.yml`.

## Source references

- `scripts/odf-vm-validator.sh:152`: `density_setup` calls `mktemp "$ROOT/kube-burner/rendered/density.XXXX.yml"` and removes the file only after `kube-burner init` returns.
- `scripts/odf-vm-validator.sh:664-697` and `1168-1198`: both disposable proof workflows call `density_setup`.

## Root cause

The temporary-file template has a shared path with only four `X` characters before the `.yml` suffix. On this Darwin host, `mktemp` tried to create the literal `density.XXXX.yml`; a concurrent invocation then failed because that path already existed.

## Suggested fix

Use a macOS-compatible unique `mktemp` template (for example, six trailing `X` characters or a supported suffix option), keep the generated file unique per run, and install cleanup immediately after creation. If the workflow is intentionally single-run-only, detect and report that condition before creating a namespace.

## Post-fix retest

The source now uses `mktemp "$ROOT/kube-burner/rendered/density.XXXXXX"`. Two sequential payload-proof attempts both passed density setup/rendering and created unique proof namespaces before failing later in guest SSH cleanup; neither reported a `mktemp` collision. Two simultaneous Darwin `mktemp /tmp/virt-cbt-density.XXXXXX` calls returned distinct paths. Concurrent full proof workflows were not rerun to avoid overlapping VM/storage workloads, so full-workflow concurrency remains unverified.

Current-session concurrent rendering retest: `make density-setup` ran simultaneously for `qa-cbt-exhaustive-20260925-0305` (N=2) and `qa-cbt-concurrent-20260925-0305` (N=1). Both reached Ready/CBT Enabled with no `mktemp` collision; `kube-burner/rendered/` was empty afterward. The secondary namespace was deleted and verified `NotFound`.
