# cbt-chaos-test

Project skill that runs one CBT chaos catalog scenario against a live
OpenShift + ODF cluster: read the spec, discover env, build an event-driven
`krknctl` command via **krkn-scenario**, get a short approval, write
`chaos-trigger.sh` beside the spec, then execute and grade with
`make cbt-evidence`.

## Usage

```text
cbt-chaos-test cbt-01
cbt-chaos-test CBT-V3-03
run chaos scenario cbt-08b
```

## Depends on

- Sibling skill: `krkn-scenario` (`.claude/skills/krkn-scenario/`)
- Specs: `docs/chaos-test/scenario/cbt-*/scenario_spec.md`
- Cluster tools: `oc`, `virtctl`, `krknctl`, `jq`, bash 4+, `make` density/CBT targets

## Output

Per scenario folder:

```text
docs/chaos-test/scenario/cbt-01-…/chaos-trigger.sh
```

Plus a pass/fail/invalid summary using qcow2 header evidence (not VMB status alone).
