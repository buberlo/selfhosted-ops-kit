# selfhosted-ops-kit - one-command entry points. Every target is a thin wrapper
# around a script in scripts/, so the same steps work without make.
SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

.PHONY: help up test demo down lint diag images

help: ## Show targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-8s %s\n", $$1, $$2}'

up: ## Build images, create kind cluster (Terraform), install chart, smoke test
	./scripts/up.sh

test: ## End-to-end: upgrade, failed upgrade + auto-rollback, rollback, backup/restore, NetworkPolicy
	./scripts/e2e.sh

demo: ## Narrated walkthrough (what docs/demo/ was recorded from)
	./scripts/demo.sh

down: ## Destroy the kind cluster
	./scripts/down.sh

images: ## Build the demo API images only
	./scripts/build-images.sh

diag: ## Collect a support bundle (no secret values)
	./scripts/collect-diagnostics.sh

lint: ## Static checks (same as CI lint job, needs the tools locally)
	helm lint charts/notes --strict
	helm lint charts/notes --strict -f charts/notes/values-ha.yaml
	helm template notes charts/notes -f charts/notes/values-ha.yaml | kubeconform -strict -summary
	terraform -chdir=terraform/kind fmt -check -recursive
	terraform -chdir=terraform/kind init -backend=false -input=false > /dev/null
	terraform -chdir=terraform/kind validate
	cd terraform/kind && tflint --init > /dev/null && tflint
	shellcheck -x -P SCRIPTDIR scripts/*.sh
