# scenario_spec.md template (CBT V3)

Copy this structure for any new scenario under `docs/chaos-test/scenario/<folder>/`.

```markdown
# CBT-V3-XX — Title

> Plan + evidence rule banners…

## 1. Metadata
## 2. Objective
## 3. Traceability
## 4. Target and inject window
## 5. Risk / blast radius
## 6. Preconditions
## 7. Test environment
## 8. Procedure
### 8.1 Phase A — Arm backup window
### 8.2 Phase B — Inject chaos (krknctl)
### 8.3 Phase C — Validate correct component @ correct time
### 8.4 Phase D — Validate CBT backup integrity
### 8.5 Phase E — Cleanup
## 9. Expected results
## 10. Pass criteria
## 11. Fail criteria
## 12. Safety notes
## 13. Evidence to capture
## 14. Execution log
```

Mandatory behavioral requirements:

- Phase **C** must prove the fault hit the intended component inside the intended `T-*` window.
- Phase **D** must prove backup correctness/corruption via `cbt-evidence` / qcow2 header (and tracker honesty), not status alone.
- Basic `krknctl run …` stub required when a Krkn scenario applies; always note `--help` drift.
- Prefer **Krkn event-driven triggers** (e.g. `Progressing=True`, `on_timeout: fail`) over sleep-only timing where it makes sense; prefer **`krknctl`**, with **`oc`/`kubectl`** only when krknctl is awkward.
- Note that a future **`chaos-trigger.sh`** will live in **this same scenario folder** next to `scenario_spec.md` (not under shared `scripts/`).
- Link `_common.md` for shared env and evidence commands.
