SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

CONFIG ?= config.env
SCRIPT := scripts/odf-vm-validator.sh

ifneq ($(strip $(N)),)
ifneq ($(strip $(n)),)
$(error specify only one of N or n)
endif
endif

# Exactly one of VMS / N|n / SELECTOR / ALL when any selection mode is supplied.
# Nested $(if ...) precedence previously collapsed conflicts before the script could reject them.
_SELECTION_FLAGS := $(strip $(if $(strip $(VMS)),1) $(if $(or $(strip $(N)),$(strip $(n))),1) $(if $(strip $(SELECTOR)),1) $(if $(strip $(ALL)),1))
ifneq ($(_SELECTION_FLAGS),)
ifneq ($(words $(_SELECTION_FLAGS)),1)
$(error specify exactly one of VMS, N/n, SELECTOR, or ALL=1)
endif
endif

# Quote VMS/SELECTOR so CSV values with spaces after commas stay one argv word.
SELECTION_ARGS = $(if $(VMS),--vms '$(VMS)',$(if $(N),--count $(N),$(if $(n),--count $(n),$(if $(SELECTOR),--selector '$(SELECTOR)',$(if $(ALL),--all,)))))

.PHONY: help init-config generate-keys check-prereqs density-setup density-status density-teardown discover-vms backup cbt-backup verify-cbt backup-reset cbt-cycle cbt-payload-proof cbt-restore-proof cbt-evidence cbt-diagnostics verify status ssh report list-reports e2e

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
	  '  make backup VMS=a,b|N=2|SELECTOR=k=v|ALL=1  Record proof baseline and take Full backup' \
	  '  make cbt-backup VMS=a,b|N=2|SELECTOR=k=v|ALL=1  Append proof record and take Incremental backup' \
	  '  make verify-cbt VMS=a,b|N=2|SELECTOR=k=v|ALL=1  Validate CRs+qcow2, restore chain, require proof hash' \
	  '  make backup-reset VMS=a,b|N=2|SELECTOR=k=v|ALL=1  Clear backups/tracker/backup-output and invalidate proof' \
	  '  make cbt-cycle VMS=a,b|N=2|SELECTOR=k=v|ALL=1  Marker→Full→append→Inc→verify→restore-hash' \
	  '  make verify VMS=a,b|N=2|SELECTOR=k=v|ALL=1     Quick source and backup artifact check (no restore)' \
	  '  make status [selection]                   Join VM, tracker and backup state' \
	  '  make ssh VM=fedora-cbt-1 CMD="..."       Run a guest command' \
	  '  make report                              Print newest JSON report' \
	  '  make list-reports                        List reports newest first' \
	  '  make e2e N=2                             density-setup + cbt-cycle (no teardown)' \
	  '  make cbt-payload-proof                  Prove CBT using incremental QCOW2 contents' \
	  '  make cbt-restore-proof                  Disposable NS: write+hash, Full, append+hash, Incremental, restore, rehash' \
	  '  make cbt-evidence VMS=a,b|N=2|SELECTOR=k=v|ALL=1  Chaos-safe check: verify existing Full/CBT backups from qcow2 backing-file metadata, not .status' \
	  '  make cbt-diagnostics VMS=a,b|N=2|SELECTOR=k=v|ALL=1  Forensic dump: CR YAML + controller/handler/launcher logs for existing Full/Incremental backups' \
	  '' \
	  'Selection is exactly one of VMS=csv, N=count, SELECTOR=k=v, or ALL=1.' \
	  'Count selection uses natural (version) name order so N=2 yields <prefix>-1 then <prefix>-2.'

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
	@SUMMARY=$(SUMMARY) COUNT_ONLY=$(COUNT_ONLY) $(SCRIPT) --config $(CONFIG) discover-vms $(SELECTION_ARGS)

backup:
	@$(SCRIPT) --config $(CONFIG) backup $(SELECTION_ARGS)

cbt-backup:
	@$(SCRIPT) --config $(CONFIG) cbt-backup $(SELECTION_ARGS)

backup-reset:
	@$(SCRIPT) --config $(CONFIG) backup-reset $(SELECTION_ARGS)

cbt-cycle:
	@$(SCRIPT) --config $(CONFIG) cbt-cycle $(SELECTION_ARGS)

verify:
	@$(SCRIPT) --config $(CONFIG) verify $(SELECTION_ARGS)
verify-cbt:
	@$(SCRIPT) --config $(CONFIG) verify-cbt $(SELECTION_ARGS)

status:
	@$(SCRIPT) --config $(CONFIG) status $(SELECTION_ARGS)

# Pass CMD via the environment so spaces and nested quotes survive Make.
# Escape embedded single quotes as '\'' so CMD='...' stays one shell word.
ssh:
	@CMD='$(subst ','\'',$(CMD))' $(SCRIPT) --config $(CONFIG) ssh --vm '$(VM)'

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
	@$(SCRIPT) --config $(CONFIG) cbt-evidence $(SELECTION_ARGS)

cbt-diagnostics:
	@$(SCRIPT) --config $(CONFIG) cbt-diagnostics $(SELECTION_ARGS)
