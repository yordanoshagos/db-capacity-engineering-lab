# Individual rehost (Yordanos) — C1 / C2 / C8
#
#   make up       LocalStack + remote state + tflocal apply + seed Aiven (10k)
#   make verify   five C8 checks
#   make down     destroy + stop LocalStack
#
# Terraform root is ./terraform (this repo). Group modules are pulled by SHA.
# Requires Linux (Codespace 4 vCPU / 16 GB). Never commit AIVEN_* / the token.

SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

ROOT    := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
TF_DIR  ?= $(ROOT)/terraform
TF      := tflocal -chdir=$(TF_DIR)
EVIDENCE_IAC := $(ROOT)/evidence/01-iac

export AWS_ACCESS_KEY_ID     ?= test
export AWS_SECRET_ACCESS_KEY ?= test
export AWS_DEFAULT_REGION    ?= us-east-1
export AWS_ENDPOINT_URL      ?= http://localhost:4566
export TF_DIR

export TF_VAR_db_host     ?= $(AIVEN_HOST)
export TF_VAR_db_port     ?= $(AIVEN_PORT)
export TF_VAR_db_username ?= $(or $(AIVEN_USER),avnadmin)
export TF_VAR_db_password ?= $(AIVEN_PASSWORD)
export TF_VAR_db_name     ?= $(or $(AIVEN_DB),capacity_lab)
# Bare ami-<12hex>. LocalStack docker tag is localstack-ec2/app:ami-<12hex> —
# aws_instance.ami rejects that as InvalidAMIID.Malformed.
export TF_VAR_app_ami_id  ?= $(APP_AMI_ID)

# First clone: tflocal -chdir=terraform init -backend-config=backend.hcl
# `make up` reuses that cache. Without backend.hcl, init talks to real AWS STS.
.PHONY: help up down verify seed bootstrap localstack-up localstack-down check-token check-aiven check-tfdir obs obs-down

help:
	@echo "Targets: up verify seed down    TF_DIR=$(TF_DIR)"

check-token:
	@test -n "$${LOCALSTACK_AUTH_TOKEN:-}" || { echo "FAIL: LOCALSTACK_AUTH_TOKEN is not set" >&2; exit 1; }

check-aiven:
	@test -n "$${AIVEN_HOST:-}" || { echo "FAIL: AIVEN_HOST is not set" >&2; exit 1; }
	@test -n "$${AIVEN_PORT:-}" || { echo "FAIL: AIVEN_PORT is not set" >&2; exit 1; }
	@test -n "$${AIVEN_PASSWORD:-}" || { echo "FAIL: AIVEN_PASSWORD is not set" >&2; exit 1; }

check-tfdir:
	@test -d "$(TF_DIR)" || { echo "FAIL: no Terraform root at $(TF_DIR)" >&2; exit 1; }

localstack-up: check-token
	@if curl -fsS "$${AWS_ENDPOINT_URL}/_localstack/health" >/dev/null 2>&1; then \
	  echo ">> LocalStack already healthy"; \
	else \
	  localstack start -d; \
	fi
	@for i in $$(seq 1 60); do \
	  curl -fsS "$${AWS_ENDPOINT_URL}/_localstack/health" >/dev/null 2>&1 && break; \
	  sleep 2; \
	done
	@curl -fsS "$${AWS_ENDPOINT_URL}/_localstack/health" >/dev/null \
	  || { echo "FAIL: LocalStack never became healthy" >&2; exit 1; }

localstack-down:
	-localstack stop

bootstrap: localstack-up
	@$(ROOT)/bootstrap/tfstate.sh

up: check-token check-aiven check-tfdir bootstrap
	@mkdir -p "$(EVIDENCE_IAC)"
	$(TF) init $(if $(wildcard $(TF_DIR)/backend.hcl),-backend-config=backend.hcl,)
	$(TF) apply -auto-approve | tee "$(EVIDENCE_IAC)/apply.log"
	$(TF) plan -no-color -detailed-exitcode > "$(EVIDENCE_IAC)/plan-after-apply.txt" \
	  || { echo "FAIL: plan after apply is not empty — see $(EVIDENCE_IAC)/plan-after-apply.txt" >&2; exit 1; }
	@$(ROOT)/scripts/seed.sh
	@echo ">> make up complete. Run: make verify"

seed: check-token check-aiven check-tfdir
	@$(ROOT)/scripts/seed.sh

verify: check-tfdir
	@$(ROOT)/scripts/verify.sh

down: check-token check-tfdir
	@mkdir -p "$(EVIDENCE_IAC)"
	$(TF) destroy -auto-approve | tee "$(EVIDENCE_IAC)/destroy.log"
	@$(MAKE) localstack-down

obs:
	docker compose -f docker-compose.obs.yml up -d
	@echo "Grafana http://localhost:3001  Prometheus http://localhost:9090  Alertmanager http://localhost:9093"

obs-down:
	docker compose -f docker-compose.obs.yml down
