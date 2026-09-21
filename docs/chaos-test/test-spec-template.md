# Test-Case Specification Template — CBT Chaos Scenario

Formal per-scenario test case derived from `docs/chaos-test/scenarios_v2.md`. One document per `CBT-CH-XX`. Intended for QA sign-off / test-management import, distinct from the Jira execution ticket (`jira-issue-template.md`), which tracks scheduling, ownership, and result status.

---

## Test Case ID
`CBT-CH-{{NN}}`

## Title
{{Scenario title}}

## Objective
{{"Description" field from scenarios_v2.md}}

## Traceability
- Scenario source: `docs/chaos-test/scenarios_v2.md#cbt-ch-{{nn}}`
- Architecture reference: `docs/cbt/CBT-ARCHITECTURE.md`
- Baseline procedure: `docs/cbt/CBT-TEST-GUIDE.md`
- Campaign order position: {{position from §5, e.g. "3rd, after CBT-CH-02, before CBT-CH-05"}}
- Depends on: baseline Full + Incremental backup (§2.3); cleanup gate `CBT-CH-10` after this test if interrupted

## Risk / Blast Radius
`{{Low|Medium|High}}` — {{one line, e.g. "single controller replica killed, Deployment recreates it; no data-plane impact"}}

## Preconditions
1. Disposable OpenShift cluster with OpenShift Virtualization + ODF/Ceph-RBD.
2. Repository manifests applied in `{{namespace}}`: VM `{{vm}}` (`runStrategy: Always`, CBT enabled on `datadisk`), data/backend-state/backup PVCs, tracker `{{tracker}}`.
3. `incrementalBackup` feature gate enabled; cluster CBT label selector matches `changedBlockTracking: "true"`.
4. Baseline verified via §2.2 commands — CBT `Enabled`, VM/VMI `Running`, all PVCs `Bound`, nodes `Ready`, ODF `Ready`, control components healthy, no backup in progress.
5. Baseline Full backup (`{{vm}}-full`) and Incremental backup (`{{vm}}-incremental`) both completed with `Done=True` (or release-equivalent) and recorded checkpoint names.
6. Krkn/Krknctl version pinned and recorded; `krknctl run {{scenario}} --help` reviewed against this release.
7. A repeatable write workload is running against `/data` on the VM.

## Test Environment / Data
| Item | Value |
|---|---|
| Namespace | `{{cbt-demo}}` |
| VM | `{{fedora-cbt-vm}}` |
| Tracker | `{{fedora-cbt-tracker}}` |
| Backup PVC | `{{cbt-backup-output}}` |
| Target fault component | `{{e.g. virt-controller pod}}` |
| Krkn scenario | `{{krknctl scenario name}}` |
| KUBECONFIG | `{{path}}` |

## Test Steps

| # | Step | Command / Action | Expected intermediate result |
|---|------|-------------------|-------------------------------|
| 1 | Confirm baseline health | §2.2 baseline commands | All preconditions green |
| 2 | Create uniquely-named chaos VMB | `oc apply -f {{chaos-backup.yaml}}` | VMB created, `Progressing=True` |
| 3 | Arm event-driven trigger | Krkn trigger block watching VMB `Progressing` (§3), `on_timeout: fail` | Trigger fires only while backup is in-flight |
| 4 | Inject fault at defined lifecycle point | `{{exact krknctl run ... command}}` | Fault applied to `{{exact target identity}}`; start time recorded |
| 5 | Observe recovery | Watch target component/pod/VMI, VMB status, tracker status | Component recreated / recovers within SLO |
| 6 | Capture evidence | §2.3 evidence commands (`cbt-diagnostics.yaml`, events, controller/handler logs) | Full before/after evidence captured |
| 7 | Verify VMB terminal state | `oc get virtualmachinebackup ... -o json \| jq status` | Complete or explicit recoverable failure — never indefinite `Progressing` |
| 8 | Verify tracker state | `oc get virtualmachinebackuptracker ... -o json \| jq .status.latestCheckpoint` | Advances only on valid completed backup |
| 9 | Run follow-up backup | Full or Incremental per scenario expectation | Expected type observed, or explained safe Full fallback |
| 10 | Run cleanup gate | `CBT-CH-10` procedure if step 4 left an interrupted/stuck VMB | Finalizers clear, PVC detaches, namespace not blocked |

## Expected Results
{{copy "Expected result" field verbatim from scenarios_v2.md}}

## Pass Criteria
_(all applicable, per scenarios_v2.md §5)_
- [ ] Fault recorded with start/end time and target identity
- [ ] Recovery within SLO, or bounded documented failure
- [ ] VMB status/conditions/events/finalizers consistent with observed interruption
- [ ] Tracker advances only after valid completed backup
- [ ] Next backup is expected `Incremental`, or explained safe `Full` fallback
- [ ] All PVCs usable and detached correctly
- [ ] VM/VMI `Running`, CBT `Enabled`; controller/handler/CSI/node/ODF recovered
- [ ] No unrelated Krkn/Cerberus/Prometheus health regression

## Fail Criteria
Silent data loss; false successful checkpoint; stale finalizer; stuck attachment; unrecovered VMI; unexplained full fallback; permanent workqueue retry; cluster-health regression outside intended blast radius; inability to restore the injected fault.

## Additional Notes
{{copy "Additional notes" field verbatim from scenarios_v2.md}}

## Evidence to Capture (§6)
- Test ID/title, date, operator, cluster, OCP-Virt/KubeVirt/ODF versions
- Krkn/Krknctl version, exact command, resolved targets, trigger config
- Baseline + post-chaos VMB/VMBT JSON, checkpoint names, per-volume types, conditions, finalizers
- VM/VMI state, CBT state, launcher node, PVC/PV/StorageClass state, attachment events
- Krkn telemetry timings, Cerberus result, Prometheus queries/results, controller/handler/CSI/Ceph evidence
- Fault start/end timestamps, recovery timestamp, backup duration, Incremental-vs-Full outcome
- Failure reason, cleanup actions, residual objects, resilience improvement recommendation

---

## Execution Log _(fill in per run — one table row per attempt)_

| Run # | Date | Operator | Result | Notes |
|---|---|---|---|---|
| | | | | |
