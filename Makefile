# vmetal-openshift convenience targets.
#   make check                verify host prerequisites
#   make bootstrap [OCP_VERSION=4.22.0]   host prep (venv, deps, installer, cert)
#   make configs              render install/agent configs for all clusters
#   make iso CLUSTER=prod     render configs + build discovery ISO (agent mode)
#   make sushy                render sushy Redfish config + systemd unit
#   make host-dns             point the host resolver at the cluster domains
#   make up / make down       provision / tear down (all clusters in group_vars)
#   make bmc CLUSTER=c BMC_ACTION=...  Redfish BMC: status|on|off|force-off|reset|
#                                       cycle|pxe|boot-disk|boot-iso|set-boot|media-* (NODE=node0)
#   make adopt CLUSTER=c                in-cluster BMH adoption (platform baremetal only)
#   make lint / make e2e      offline checks / live test
#   make pdf                  export docs/architecture.pdf
#
# Pass extra ansible flags via ANSIBLE_ARGS, e.g.:
#   make up ANSIBLE_ARGS="-e use_become=false"   # in the libvirt group
#   make up ANSIBLE_ARGS="-K"                    # prompt for sudo

CLUSTER      ?= cluster0
BMC_ACTION   ?= status
NODE         ?=
BOOTDEV      ?= Pxe
ISO_BASE_URL ?=
ANSIBLE_ARGS ?=
OCP_CHANNEL  ?= stable
OCP_VERSION  ?=          # e.g. 4.22.0; empty = newest in channel
ADOPT_HOSTS  ?=
AP           := $(abspath $(shell [ -x .venv/bin/ansible-playbook ] && echo .venv/bin/ansible-playbook || echo ansible-playbook))
PY           := $(abspath $(shell [ -x .venv/bin/python ] && echo .venv/bin/python || echo python3))

.PHONY: check bootstrap configs iso sushy host-dns up down bmc adopt lint e2e pdf clean help

help:
	@grep -E '^#' $(MAKEFILE_LIST)

check:
	./scripts/check-prereqs.sh

bootstrap:
	OCP_CHANNEL=$(OCP_CHANNEL) OCP_VERSION=$(OCP_VERSION) ./scripts/bootstrap.sh

configs:
	cd ansible && $(AP) generate-configs.yml

iso:
	./scripts/build-iso.sh $(CLUSTER)

sushy:
	cd ansible && $(AP) sushy.yml

host-dns:
	cd ansible && $(AP) host-dns.yml $(ANSIBLE_ARGS)

up:
	cd ansible && $(AP) setup.yml $(ANSIBLE_ARGS)

down:
	cd ansible && $(AP) cleanup.yml $(ANSIBLE_ARGS)

bmc:
	cd ansible && $(AP) bmc.yml -e cluster=$(CLUSTER) -e bmc_action=$(BMC_ACTION) \
	  -e node=$(NODE) -e bootdev=$(BOOTDEV) -e iso_base_url=$(ISO_BASE_URL)

adopt:
	ADOPT_HOSTS=$(ADOPT_HOSTS) $(PY) scripts/adopt.py $(CLUSTER)

lint:
	./scripts/lint.sh

e2e:
	./scripts/e2e.sh

pdf:
	./scripts/export-pdf.sh

clean: down
