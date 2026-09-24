SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

CONFIG ?= config.env
SCRIPT := scripts/odf-vm-validator.sh

ifneq ($(strip $(N)),)
ifneq ($(strip $(n)),)
$(error specify only one of N or n)
endif
endif

.PHONY: help init-config generate-keys check-prereqs density-setup density-status density-teardown discover-vms backup cbt-backup cbt-payload-proof cbt-restore-proof cbt-evidence verify status ssh report list-reports e2e

help:
	@printf '%s\n' \
	  'ODF Fedora VM density validator' \
	  '' \
	  '  make init-config                         Create config.env from the example' \
	  '  make generate-keys                       Create SSH key pair when absent' \
	  '  make check-prereqs                       Validate tools, CRDs, ODF and CBT' \
	  '  make density-setup N=2                   Create deterministic Fedora VM density' \
	  '  make density-status [SUMMARY=1]          Show owned VM pool' \
	  '  make density-teardown [ALL=1 CONFIRM=1]  Delete config namespace, or all utility-owned (CONFIRM=1 required for ALL=1)' \
	  '  make discover-vms [N=2|ALL=1]            List selected utility VMs' \
	  '  make backup VMS=a,b|N=2|SELECTOR=k=v|ALL=1  Full backups' \
	  '  make cbt-backup VMS=a,b|N=2|SELECTOR=k=v|ALL=1 Incremental backups' \
	  '  make verify VMS=a,b|N=2|SELECTOR=k=v|ALL=1     Validate guests and backups' \
	  '  make status [selection]                   Join VM, tracker and backup state' \
	  '  make ssh VM=fedora-cbt-1 CMD="..."       Run a guest command' \
	  '  make report                              Print newest JSON report' \
	  '  make list-reports                        List reports newest first' \
	  '  make e2e N=2                             Setup, full, CBT and verify' \
	  '  make cbt-payload-proof                  Prove CBT using incremental QCOW2 contents' \
	  '  make cbt-restore-proof                  Write+hash, Full, append+hash, Incremental, restore chain, rehash' \
	  '  make cbt-evidence VMS=a,b|N=2|SELECTOR=k=v|ALL=1  Chaos-safe check: verify existing Full/CBT backups from qcow2 backing-file metadata, not .status' \
	  '' \
	  'Selection is exactly one of VMS=csv, N=count, SELECTOR=k=v, or ALL=1.'

init-config:
	@test -e $(CONFIG) || cp config.example.env $(CONFIG)
	@printf 'Config: %s\n' $(CONFIG)

generate-keys:
	@$(SCRIPT) --config $(CONFIG) generate-keys

check-prereqs:
	@$(SCRIPT) --config $(CONFIG) check-prereqs

density-setup:
	@$(SCRIPT) --config $(CONFIG) density-setup $(if $(N),--count $(N),$(if $(n),--count $(n),))

density-status:
	@SUMMARY=$(SUMMARY) COUNT_ONLY=$(COUNT_ONLY) $(SCRIPT) --config $(CONFIG) density-status

density-teardown:
	@CONFIRM=$(CONFIRM) $(SCRIPT) --config $(CONFIG) density-teardown $(if $(ALL),--all,)

discover-vms:
	@SUMMARY=$(SUMMARY) COUNT_ONLY=$(COUNT_ONLY) $(SCRIPT) --config $(CONFIG) discover-vms $(if $(VMS),--vms $(VMS),$(if $(N),--count $(N),$(if $(n),--count $(n),$(if $(SELECTOR),--selector $(SELECTOR),$(if $(ALL),--all,)))))

backup:
	@$(SCRIPT) --config $(CONFIG) backup $(if $(VMS),--vms $(VMS),$(if $(N),--count $(N),$(if $(n),--count $(n),$(if $(SELECTOR),--selector $(SELECTOR),$(if $(ALL),--all,)))))

cbt-backup:
	@$(SCRIPT) --config $(CONFIG) cbt-backup $(if $(VMS),--vms $(VMS),$(if $(N),--count $(N),$(if $(n),--count $(n),$(if $(SELECTOR),--selector $(SELECTOR),$(if $(ALL),--all,)))))

verify:
	@$(SCRIPT) --config $(CONFIG) verify $(if $(VMS),--vms $(VMS),$(if $(N),--count $(N),$(if $(n),--count $(n),$(if $(SELECTOR),--selector $(SELECTOR),$(if $(ALL),--all,)))))

status:
	@$(SCRIPT) --config $(CONFIG) status $(if $(VMS),--vms $(VMS),$(if $(N),--count $(N),$(if $(n),--count $(n),$(if $(SELECTOR),--selector $(SELECTOR),$(if $(ALL),--all,)))))

# Pass CMD via the environment so spaces in guest commands survive Make's
# word-splitting (e.g. make ssh VM=fedora-cbt-1 CMD='echo hello world').
ssh:
	@CMD='$(CMD)' $(SCRIPT) --config $(CONFIG) ssh --vm '$(VM)'

report:
	@$(SCRIPT) --config $(CONFIG) report

list-reports:
	@$(SCRIPT) --config $(CONFIG) list-reports

e2e:
	@$(SCRIPT) --config $(CONFIG) e2e $(if $(N),--count $(N),$(if $(n),--count $(n),))

cbt-payload-proof:
	@$(SCRIPT) --config $(CONFIG) cbt-payload-proof

cbt-restore-proof:
	@$(SCRIPT) --config $(CONFIG) cbt-restore-proof

cbt-evidence:
	@$(SCRIPT) --config $(CONFIG) cbt-evidence $(if $(VMS),--vms $(VMS),$(if $(N),--count $(N),$(if $(n),--count $(n),$(if $(SELECTOR),--selector $(SELECTOR),$(if $(ALL),--all,)))))
