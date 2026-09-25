# Historical restore proof failed after a virtctl version warning

## Status

**Not a script bug** (triaged 2026-09-25). No code change.

A retained disposable restore-proof run failed while writing its baseline marker.
The workstation's `virtctl` emitted a client/server version-mismatch warning
immediately before `exit status 1`. The same client `v1.7.0` / server `v1.8.4`
pair succeeded on the immediate retry and on later runs, so the warning is
correlated, not causal. Cleanup trap deleted the disposable namespace correctly.

## Suggested action

Keep version info in diagnostics if useful; do not treat the warning alone as
a failure cause. Pin `virtctl` only if a supported matrix requires it.
