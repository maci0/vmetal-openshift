# vmetal-openshift convenience targets.
#   make check                verify host prerequisites
#   make optimize             host memory tuning: KSM + zram + per-VM cgroup hook
#   make optimize-undo        revert the memory tuning
#   make bootstrap [OCP_VERSION=4.22.0]   host prep (venv, deps, installer, cert)
#   make sushy-install        render + start the sushy Redfish BMC (systemd --user)
#   make install CLUSTER=c     one-shot: build ISO, provision, boot, wait for cluster
#   make install-upi CLUSTER=c one-shot UPI install (platform: none); pxe for multi-node
#   make lab CLUSTER=c         infra only: build ISO + boot the nodes, but DON'T install
#                                (practice driving openshift-install yourself)
#   make configs              render install/agent configs for all clusters
#   make iso CLUSTER=prod     render configs + build discovery ISO (agent mode)
#   make sushy                render sushy Redfish config + systemd unit
#   make host-dns             point the host resolver at the cluster domains
#   make up / make down       provision / tear down (all clusters in group_vars)
#   make serve-iso            serve build/ over HTTP (for redfish virtual media)
#   make bmc CLUSTER=c BMC_ACTION=...  Redfish BMC: status|on|off|force-off|reset|
#                                       cycle|pxe|boot-disk|boot-iso|set-boot|media-* (NODE=node0)
#   make adopt CLUSTER=c                in-cluster BMH adoption (agent baremetal or upi)
#   make haproxy CLUSTER=c              external HAProxy for multi-node UPI (host appliance)
#   make haproxy-down CLUSTER=c         stop the UPI HAProxy appliance
#   make mirror CLUSTER=c               disconnected: registry on the gateway + mirror the release
#   make mirror-down CLUSTER=c          stop the mirror registry
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
#   make bench / bench-zram   memory benchmarks: KSM+zram on the cluster / where zram wins
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
AP           := $(shell [ -x .venv/bin/ansible-playbook ] && echo $(CURDIR)/.venv/bin/ansible-playbook || echo ansible-playbook)
PY           := $(shell [ -x .venv/bin/python ] && echo $(CURDIR)/.venv/bin/python || echo python3)

.DEFAULT_GOAL := help
.PHONY: check optimize optimize-undo bootstrap install install-upi lab ignition configs iso sushy sushy-install host-dns up down \
        serve-iso bmc adopt metallb metallb-bgp metallb-bgp-down workers-add workers-remove lvms nfs nfs-down virt status creds lint e2e bench bench-zram haproxy haproxy-down mirror mirror-down pdf clean help

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

ignition:
	./scripts/build-ignition.sh $(CLUSTER)

install-upi:
	./scripts/install-upi.sh $(CLUSTER)

lab:
	./scripts/lab.sh $(CLUSTER)

haproxy:
	cd ansible && $(AP) haproxy.yml -e cluster=$(CLUSTER)

haproxy-down:
	cd ansible && $(AP) haproxy.yml -e cluster=$(CLUSTER) -e appliance_action=down

mirror:
	./scripts/mirror.sh $(CLUSTER) release

mirror-down:
	./scripts/mirror.sh $(CLUSTER) down

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
	-./scripts/appliances-down.sh
	cd ansible && $(AP) cleanup.yml $(ANSIBLE_ARGS)

bmc:
	cd ansible && $(AP) bmc.yml -e cluster=$(CLUSTER) -e bmc_action=$(BMC_ACTION) \
	  -e node=$(NODE) -e bootdev=$(BOOTDEV) -e iso_base_url=$(ISO_BASE_URL)

adopt:
	cd ansible && $(AP) adopt.yml -e cluster=$(CLUSTER) -e adopt_hosts=$(ADOPT_HOSTS)

workers-add:
	./scripts/workers-add.sh $(CLUSTER)

workers-remove:
	./scripts/workers-remove.sh $(CLUSTER)

metallb:
	cd ansible && $(AP) operators.yml -e op=metallb -e cluster=$(CLUSTER)

metallb-bgp:
	cd ansible && $(AP) metallb-bgp.yml -e cluster=$(CLUSTER)

metallb-bgp-down:
	cd ansible && $(AP) metallb-bgp.yml -e cluster=$(CLUSTER) -e appliance_action=down

lvms:
	cd ansible && $(AP) operators.yml -e op=lvms -e cluster=$(CLUSTER)

virt:
	cd ansible && $(AP) operators.yml -e op=virt -e cluster=$(CLUSTER)

nfs:
	cd ansible && $(AP) nfs.yml -e cluster=$(CLUSTER)

nfs-down:
	cd ansible && $(AP) nfs.yml -e cluster=$(CLUSTER) -e appliance_action=down

lint:
	./scripts/lint.sh

e2e:
	./scripts/e2e.sh

bench:
	./scripts/bench-memory.sh $(CLUSTER)

bench-zram:
	./scripts/bench-zram-demo.sh

pdf:
	./scripts/export-pdf.sh

clean: down
