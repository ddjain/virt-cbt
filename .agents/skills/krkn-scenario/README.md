# krkn-scenario

A Claude Code skill that generates production-ready [Krkn](https://github.com/krkn-chaos/krkn) chaos engineering scenarios with validated `krknctl` and `krkn-hub` commands.

## Installation

```bash
npx skills add https://github.com/krkn-chaos/krkn-skills --skills krkn-scenario
```

<details>
<summary>Alternative installation methods</summary>

### Download to a specific project

```bash
mkdir -p .claude/skills
curl -o .claude/skills/krkn-scenario.md https://raw.githubusercontent.com/krkn-chaos/krkn-skills/main/skills/krkn-scenario/SKILL.md
```

### Global installation (available in all projects)

```bash
mkdir -p ~/.claude/skills
curl -o ~/.claude/skills/krkn-scenario.md https://raw.githubusercontent.com/krkn-chaos/krkn-skills/main/skills/krkn-scenario/SKILL.md
```

</details>

## Usage

```
/krkn-scenario kill etcd pods in openshift-etcd namespace
/krkn-scenario add 200ms network latency to worker nodes for 5 minutes
/krkn-scenario hog 4 CPU cores at 80% on nodes labeled stress-test=true
```
