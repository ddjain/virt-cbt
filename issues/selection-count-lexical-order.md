# Count selection includes `-10` before `-2`

## Description

Count-based selection sorts VM names lexically. In a pool with ten replicas, `N=2` selects `fedora-cbt-1` and `fedora-cbt-10`, not `fedora-cbt-1` and `fedora-cbt-2`. The test guide's example explicitly names the latter pair while saying the order is lexical, so the operator-facing contract is inconsistent and can target a different VM than expected.

## Environment

- Darwin arm64 workstation; GNU Bash 5.3.20
- OpenShift `system:admin`; namespace `cbt-gcp-20260923`
- Current managed pool contains `fedora-cbt-1` through `fedora-cbt-10`

## Reproduction

```bash
make discover-vms N=2
```

## Expected

The guide's example implies `fedora-cbt-1` and `fedora-cbt-2`. The README and guide also state count selection uses name/lexical order, which implies `fedora-cbt-1` and `fedora-cbt-10` for this pool. Those statements conflict.

## Actual

```text
fedora-cbt-1
fedora-cbt-10
```

Exit code: `0`. No cluster resources were modified.

## Errors / logs

No runtime error. Selection order was independently compared with `make discover-vms ALL=1`, which listed the same lexically sorted names.

## Source references

- `scripts/select-vms.sh:24`: count mode sorts names and selects the first N lines.
- `docs/cbt/CBT-TEST-GUIDE.md:30`: says lexical order but gives `fedora-cbt-1`, `fedora-cbt-2` as the first two.
- `README.md:122-124`: documents first N by name.

## Root cause

The implementation uses lexical string sorting. The example assumes numeric/natural ordering, which differs once replica numbers reach two digits.

## Suggested fix

Choose and state one contract. If lexical order is intentional, correct the example and explicitly warn that `N=2` may select `-10`; otherwise use a numeric suffix sort and test counts across the 9-to-10 boundary. Exact `VMS=` selection avoids ambiguity until resolved.

## Post-fix retest

On 2026-09-25, `make discover-vms CONFIG=/tmp/virt-cbt-retest-pool-20260925.env N=2` exited `0` and returned `fedora-cbt-1`, `fedora-cbt-2`. Independent `oc` inventory confirmed ten managed replicas through `fedora-cbt-10`; count mode now follows natural version order. No resources were modified.

Current-session boundary retest used the live two-VM pool for `N=2` and a temporary `oc` fixture for the 9-to-10 boundary. With fixture names `fedora-cbt-1`, `fedora-cbt-10`, `fedora-cbt-2`, count 2 returned `-1`, `-2`; `--all` returned natural order `-1`, `-2`, `-10`. The fixture was removed from `/tmp`.
