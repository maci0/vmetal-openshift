# vmetal-openshift convenience targets.
#   make check                verify host prerequisites
#   make optimize             host memory tuning: KSM + zram + per-VM cgroup hook
#   make optimize-undo        revert the memory tuning
#   make bootstrap [OCP_VERSION=4.22.0]   host prep (venv, deps, installer, cert)
#   make sushy-install        render + start the sushy Redfish BMC (systemd --user)
#   make install CLUSTER=c     one-shot: build ISO, provision, boot, wait for cluster
#   make configs              render install/agent configs for all clusters
#   make iso CLUSTER=prod     render configs + build discovery ISO (agent mode)
#   make sushy                render sushy Redfish config + systemd unit
#   make host-dns             point the host resolver at the cluster domains
#   make up / make down       provision / tear down (all clusters in group_vars)
#   make serve-iso            serve build/ over HTTP (for redfish virtual media)
#   make bmc CLUSTER=c BMC_ACTION=...  Redfish BMC: status|on|off|force-off|reset|
#                                       cycle|pxe|boot-disk|boot-iso|set-boot|media-* (NODE=node0)
#   make adopt CLUSTER=c                in-cluster BMH adoption (platform baremetal only)
#   make metallb CLUSTER=c              install MetalLB (LoadBalancer services, L2 pool)
#   make metallb-bgp CLUSTER=c          MetalLB BGP mode + FRR peer on the host (ECMP)
#   make metallb-bgp-down CLUSTER=c     stop the FRR peer + remove BGP config
#   make lvms CLUSTER=c                 LVM Storage operator -> RWO StorageClass (workers' vdc)
#   make virt CLUSTER=c                 OpenShift Virtualization (CNV) operator + HyperConverged
#   make nfs CLUSTER=c                  host NFS-Ganesha appliance -> RWX StorageClass
#   make nfs-down CLUSTER=c             stop the NFS appliance + provisioner
#   make workers-add CLUSTER=c          add day-2 workers (set day2_workers: N first)
#   make workers-remove CLUSTER=c       drain + delete the day-2 workers
#   make status CLUSTER=c     nodes + operators + BareMetalHosts
#   make creds CLUSTER=c      console URL + kubeadmin + kubeconfig
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
HTTP_PORT    ?= 8099
ANSIBLE_ARGS ?=
OCP_CHANNEL  ?= stable
OCP_VERSION  ?=          # e.g. 4.22.0; empty = newest in channel
ADOPT_HOSTS  ?=
AP           := $(abspath $(shell [ -x .venv/bin/ansible-playbook ] && echo .venv/bin/ansible-playbook || echo ansible-playbook))
PY           := $(abspath $(shell [ -x .venv/bin/python ] && echo .venv/bin/python || echo python3))

.DEFAULT_GOAL := help
.PHONY: check optimize optimize-undo bootstrap install configs iso sushy sushy-install host-dns up down \
        serve-iso bmc adopt metallb metallb-bgp metallb-bgp-down workers-add workers-remove lvms nfs nfs-down virt status creds lint e2e bench pdf clean help

help:
	@grep -E '^#' $(MAKEFILE_LIST)

check:
	./scripts/check-prereqs.sh

optimize:
	./scripts/optimize-host.sh apply

optimize-undo:
	./scripts/optimize-host.sh undo

bootstrap:
	OCP_CHANNEL=$(OCP_CHANNEL) OCP_VERSION=$(OCP_VERSION) ./scripts/bootstrap.sh

configs:
	cd ansible && $(AP) generate-configs.yml

iso:
	./scripts/build-iso.sh $(CLUSTER)

sushy:
	cd ansible && $(AP) sushy.yml

sushy-install: sushy
	mkdir -p $(HOME)/.config/systemd/user
	cp sushy/sushy-emulator.service $(HOME)/.config/systemd/user/
	systemctl --user daemon-reload
	systemctl --user enable --now sushy-emulator

install:
	./scripts/install.sh $(CLUSTER)

serve-iso:
	$(PY) -m http.server $(HTTP_PORT) --directory build

status:
	./scripts/status.sh $(CLUSTER)

creds:
	./scripts/creds.sh $(CLUSTER)

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

workers-add:
	./scripts/workers-add.sh $(CLUSTER)

workers-remove:
	./scripts/workers-remove.sh $(CLUSTER)

metallb:
	./scripts/metallb.sh $(CLUSTER)

metallb-bgp:
	./scripts/metallb-bgp.sh $(CLUSTER) up

metallb-bgp-down:
	./scripts/metallb-bgp.sh $(CLUSTER) down

lvms:
	./scripts/lvms.sh $(CLUSTER)

virt:
	./scripts/virt.sh $(CLUSTER)

nfs:
	./scripts/nfs.sh $(CLUSTER) up

nfs-down:
	./scripts/nfs.sh $(CLUSTER) down

lint:
	./scripts/lint.sh

e2e:
	./scripts/e2e.sh

bench:
	./scripts/bench-memory.sh $(CLUSTER)

pdf:
	./scripts/export-pdf.sh

clean: down
