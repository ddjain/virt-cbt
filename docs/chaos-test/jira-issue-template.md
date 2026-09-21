# Jira Issue Template — CBT Chaos Scenario

One Jira issue per scenario in `docs/chaos-test/scenarios_v2.md`. File all scenario issues as subtasks/stories under a single epic for the campaign (e.g. "CBT Resilience Chaos Campaign — Scenario V2"), linked in campaign order per §5 of that document.

Copy this block per scenario and replace every `{{...}}` placeholder using the matching `### CBT-CH-XX` section of `scenarios_v2.md`.

---

## Summary
`[CBT-CH-{{NN}}] {{Scenario title}} — chaos test execution`

## Issue Type
Test (subtask of epic `{{CBT-RESILIENCE-EPIC-KEY}}`)

## Priority
`{{Critical|High|Medium|Low}}` — set High/Critical for high-blast-radius scenarios called out in scenarios_v2.md (CBT-CH-04, CBT-CH-11); Low for CBT-CH-12 per its explicit "lower priority" note.

## Components
`{{virt-controller | virt-handler | virt-launcher/VMI | storage/ODF-Ceph | network | live-migration | time}}`

## Labels
`chaos-testing`, `cbt`, `kubevirt`, `krkn`, `scenario-v2`

## Linked Issues
- Epic: `{{CBT-RESILIENCE-EPIC-KEY}}`
- Blocked by: `{{prior scenario issue key per §5 campaign order}}`
- Cleanup gate: `{{CBT-CH-10 issue key}}` (required after any interrupted run — link as "relates to")

---

## Description

**Objective:** {{one-line description from the scenario's "Description" field}}

**Target component(s) / fault:** {{krknctl scenario name, e.g. pod-scenarios}} against `{{exact pod/node/pvc selector}}`.

**Injection point ("When"):** {{copy the scenario's "When" field verbatim}}

**Preconditions (must all be true before injecting):**
- [ ] CBT `Enabled` on the target VM/VMI
- [ ] VM/VMI `Running`
- [ ] Data, backend-state, and backup PVCs `Bound`
- [ ] All relevant nodes `Ready`
- [ ] ODF/Ceph `Ready`, `virt-controller`/`virt-handler`/CSI/Ceph pods healthy
- [ ] No backup currently in progress; backup PVC not mounted elsewhere
- [ ] Baseline Full backup and baseline Incremental backup already completed successfully (§2.3)
- [ ] Krkn/Krknctl version recorded; `krknctl run {{scenario}} --help` reviewed for this release

**Command:**
```bash
{{exact krknctl run ... command with resolved flags, including the trigger block}}
```

**Expected Result:** {{copy the scenario's "Expected result" field verbatim}}

**Additional notes / blast radius:** {{copy the scenario's "Additional notes" field verbatim}}

---

## Acceptance Criteria
_(scenario passes only if all applicable items hold — from scenarios_v2.md §5)_
- [ ] Injected fault recorded with start/end time and exact target identity
- [ ] Recovery met the scenario SLO, or produced a bounded and documented failure
- [ ] VMB status/conditions/events/finalizers are consistent with the observed interruption
- [ ] Tracker advanced only after a valid, completed backup
- [ ] Next backup was the expected `Incremental`, or an explained safe `Full` fallback
- [ ] Data, backend-state, and backup PVCs usable and detached correctly afterward
- [ ] VM/VMI back to `Running` with CBT `Enabled`; controller/handler/CSI/node/ODF healthy
- [ ] No unrelated Krkn/Cerberus/Prometheus health regression

Automatic fail conditions: silent data loss, false successful checkpoint, stale finalizer, stuck attachment, unrecovered VMI, unexplained full fallback, permanent workqueue retry, out-of-blast-radius cluster health regression, inability to restore the injected fault.

---

## Execution Record _(fill in after the run)_

| Field | Value |
|---|---|
| Date / Operator | |
| Cluster | |
| OpenShift Virtualization / KubeVirt / ODF versions | |
| Krkn / Krknctl version | |
| Fault start time | |
| Fault end time | |
| Recovery time | |
| Backup type before → after | |
| Result | `Pass / Fail / Blocked` |

**Actual Result:**
{{what happened}}

**Failure reason (if any):**
{{}}

**Cleanup actions / residual objects:**
{{}}

**Resilience improvement recommendation:**
{{}}

**Evidence attached:** `{{diagnostics file(s), log excerpts, screenshots}}`
