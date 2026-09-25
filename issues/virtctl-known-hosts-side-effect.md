# virtctl SSH writes test VM keys to the user's known_hosts

## Description

The repository passes `--known-hosts=/dev/null` and disables strict checking for guest SSH, but a successful `virtctl ssh` to a disposable restore VM still added its host key to `~/.ssh/known_hosts`. This leaves machine-specific test state in the user's SSH configuration and can produce stale-key warnings after the disposable VM is deleted or recreated.

## Environment

- Darwin arm64 workstation; OpenSSH client from `/usr/bin/ssh`
- `virtctl` client `v1.7.0`; KubeVirt server `v1.8.4`
- Disposable namespace `cbt-restore-260924190509`; restore VM `cbt-restore-vm-1-restored`

## Reproduction

The guest-hash query used the repository's host-key options:

```bash
KUBECONFIG=/Users/darjain/projects/redhat-chaos/virt-cbt/kubeconfig virtctl ssh \
  -n cbt-restore-260924190509 -i keys/cbt-validator \
  --known-hosts=/dev/null \
  --local-ssh-opts='-o' --local-ssh-opts='StrictHostKeyChecking=no' \
  --local-ssh-opts='-o' --local-ssh-opts='ConnectTimeout=15' \
  --local-ssh-opts='-o' --local-ssh-opts='ServerAliveInterval=10' \
  --local-ssh-opts='-o' --local-ssh-opts='ServerAliveCountMax=3' \
  fedora@vm/cbt-restore-vm-1-restored \
  --command 'sha256sum /data/vm-validator/cbt-restore-proof.bin'
```

## Expected

With known-host storage directed to `/dev/null`, a temporary VM key should not be persisted in the user's default `~/.ssh/known_hosts`.

## Actual

The command printed:

```text
Warning: Permanently added 'vm.cbt-restore-vm-1-restored.cbt-restore-260924190509' (ED25519) to the list of known hosts.
c9d086500d9747fdb7bea1649c198e9e455f92bed06367297145de59a68481f2  /data/vm-validator/cbt-restore-proof.bin
```

`ssh-keygen -F` found the restored VM hostname in `~/.ssh/known_hosts` (line 126). I removed only that test hostname with `ssh-keygen -R`; a follow-up lookup returned no match. `ssh-keygen` retained its automatic backup at `~/.ssh/known_hosts.old`, left intact. No unrelated key entries were removed. A subsequent source-VM query explicitly added `UserKnownHostsFile=/dev/null`; it printed the generic host-key-added message, but `ssh-keygen -F` found no entry for that source VM in the default `~/.ssh/known_hosts`.

## Errors / logs

An earlier query without `StrictHostKeyChecking=no` failed with `Host key verification failed` and the virtctl version-mismatch warning. The retry succeeded but persisted the key. The successful hash matches the recorded post-Incremental hash; the SSH side effect is independent of CBT correctness.

## Source references

- `scripts/odf-vm-validator.sh:460-465` (`guest_check`)
- `scripts/odf-vm-validator.sh:502-507` (`ssh_guest`)
- `scripts/odf-vm-validator.sh:530-537` (`proof_guest_command`)
- `virtctl ssh --help`: documents `--known-hosts` separately from `--local-ssh-opts`.

## Root cause

The repository's `--known-hosts=/dev/null` did not isolate the local OpenSSH default known-hosts file: an accepted first-use key was persisted there. An explicit `UserKnownHostsFile=/dev/null` local SSH option prevented a matching entry in the default file in the follow-up query; the generic "Permanently added" message alone did not identify the destination file.

## Suggested fix

Pass and verify `-o UserKnownHostsFile=/dev/null` through `--local-ssh-opts` for ephemeral guest connections, then check both the default OpenSSH file and virtctl's own known-hosts path. Add a test that confirms no disposable VM hostname appears in either persistent file after SSH.

## Post-fix retest

On 2026-09-25, `cbt-cycle`, `cbt-restore-proof`, and a direct `make ssh ... CMD=hostname` printed generic “Permanently added” warnings, but `ssh-keygen -F` found no entries for `vm.qa-cbt-a-1.qa-cbt-mktemp-a-20260925`, `vm.qa-cbt-a-1-restored.qa-cbt-mktemp-a-20260925`, `vm.cbt-restore-vm-1.cbt-restore-260925015538`, or its restored VM in `~/.ssh/known_hosts`. The restored proof completed with a hash match; no known-host entry was persisted.

Current-session check: `make ssh ... CMD=hostname`, a direct quoted `validator ssh` control, and `verify` emitted generic first-use warnings for `qa-cbt-exhaustive-1/2`. `ssh-keygen -F` found neither test hostname in `~/.ssh/known_hosts`; no persistent entry was created.
