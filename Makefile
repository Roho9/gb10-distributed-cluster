# GB10 distributed cluster - convenience targets
# Every target is a thin wrapper over the scripts and workloads so the common
# operations have one obvious entry point. Override variables on the command line,
# for example: make run-nccl-test HOSTS=gb10-01,gb10-02,gb10-03

SHELL := /bin/bash
HOSTS ?= gb10-01,gb10-02
NP    ?= 2

.PHONY: help
help:
	@echo "GB10 distributed cluster targets:"
	@echo "  make deploy          Run the Ansible site playbook on all nodes"
	@echo "  make validate        Check link state and RDMA bandwidth across the fabric"
	@echo "  make run-nccl-test   Run NCCL all_reduce_perf across HOSTS"
	@echo "  make health          One-shot health check on the local node"
	@echo "  make serve-vllm      Launch vLLM tensor/pipeline-parallel serving"
	@echo "  make llama-rpc       Launch llama.cpp RPC pooled-memory inference"
	@echo "  make train-ddp       Launch the PyTorch DDP training example"

.PHONY: deploy
deploy:
	cd ansible && ansible-playbook -i inventory.ini site.yml

.PHONY: validate
validate:
	./scripts/validate-fabric.sh

.PHONY: run-nccl-test
run-nccl-test:
	./scripts/run-nccl-test.sh $(HOSTS)

.PHONY: health
health:
	./scripts/health-check.sh

.PHONY: serve-vllm
serve-vllm:
	./workloads/vllm/serve.sh

.PHONY: llama-rpc
llama-rpc:
	./workloads/llama-cpp-rpc/start-cluster.sh

.PHONY: train-ddp
train-ddp:
	./workloads/pytorch-ddp/launch.sh
