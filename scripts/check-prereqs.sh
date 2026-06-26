#!/usr/bin/env bash
# Check host prerequisites for the virtual baremetal OCP lab.
# Prints PASS / WARN / FAIL per item. Exits non-zero if any hard requirement fails.
#   scripts/check-prereqs.sh
# Intentionally no `set -e`: this is a checker that must run every probe and
# report all results, not abort on the first failing test.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0

pass() { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN\033[0m %s\n' "$*"; }
bad()  { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; fails=$((fails + 1)); }

have() { command -v "$1" >/dev/null 2>&1; }

echo "== virtualization =="
if [[ -w /dev/kvm ]]; then pass "/dev/kvm writable (hardware virtualization)"
elif [[ -e /dev/kvm ]]; then warn "/dev/kvm exists but not writable (add user to kvm group)"
else bad "/dev/kvm missing: enable VT-x/AMD-V, or you are in a VM without nested virt"; fi

# Nested virtualization: the OCP nodes are VMs; running OpenShift Virtualization
# (CNV) workloads means VMs INSIDE those nodes, which needs nested virt on the host.
nested="$(cat /sys/module/kvm_intel/parameters/nested /sys/module/kvm_amd/parameters/nested 2>/dev/null | head -1)"
if [[ "$nested" == "Y" || "$nested" == "1" ]]; then
  pass "nested virtualization enabled (OpenShift Virtualization workloads will run)"
else
  warn "nested virtualization OFF: needed only for OpenShift Virtualization (VMs on the cluster).
       Enable: echo 'options kvm_intel nested=1' | sudo tee /etc/modprobe.d/kvm-nested.conf
       (use kvm_amd on AMD), then reload the module or reboot."
fi

# KSM (Kernel Samepage Merging) dedups identical guest pages. Nodes run the same
# RHCOS image, so KSM reclaims several GiB across a cluster.
ksm="$(cat /sys/kernel/mm/ksm/run 2>/dev/null || echo 0)"
if [[ "$ksm" == "1" ]]; then
  pass "KSM enabled (dedups identical node memory; saves GiB across same-image nodes)"
else
  warn "KSM off: enabling it dedups the nodes' identical RHCOS memory (several GiB saved).
       Enable persistently: sudo systemctl enable --now ksmtuned
       (or one-off: echo 1 | sudo tee /sys/kernel/mm/ksm/run)"
fi

# zram: compressed-RAM swap that absorbs the per-VM squeeze (see make optimize).
if grep -q zram /proc/swaps 2>/dev/null; then
  pass "zram swap active ($(zramctl --output ALGORITHM /dev/zram0 2>/dev/null | tail -1 | tr -d ' ')); compresses evicted node memory"
else
  warn "no zram swap: run 'make optimize' (or configure zram-generator) so squeezed pages compress in RAM."
fi

# libvirt hook: per-VM memory.high squeeze that pushes cold pages into zram.
if [[ -x /etc/libvirt/hooks/qemu ]]; then
  pass "libvirt qemu hook installed (per-VM memory.high squeeze)"
else
  warn "libvirt qemu hook not installed: run 'make optimize' to enable the per-VM memory squeeze."
fi

echo "== libvirt =="
if have virsh; then pass "virsh present"; else bad "virsh missing (install libvirt-client)"; fi
if have virsh && virsh -c qemu:///system version >/dev/null 2>&1; then
  pass "can reach qemu:///system"
else
  warn "cannot reach qemu:///system without sudo (add user to the libvirt group, or use sudo / -K)"
fi
if id -nG 2>/dev/null | grep -qw libvirt || [[ "$(id -u)" == 0 ]]; then
  pass "user in libvirt group (or root)"
else
  warn "user not in libvirt group: ansible needs -K or use_become=true"
fi
# Modular libvirt (virtqemud/virtnetworkd/virtstoraged) replaces the monolithic
# libvirtd; if a socket is inactive the matching ops fail (volumes need
# virtstoraged, networks need virtnetworkd). Only relevant when modular daemons exist.
if systemctl cat virtqemud.socket >/dev/null 2>&1; then
  off=""
  for d in virtqemud virtnetworkd virtstoraged; do
    systemctl is-active --quiet "$d.socket" 2>/dev/null || systemctl is-active --quiet "$d.service" 2>/dev/null || off="$off $d"
  done
  if [[ -n "$off" ]]; then
    warn "modular libvirt socket(s) inactive:$off ('make up' fails on the matching resource, e.g. virtstoraged -> volumes).
       Enable: sudo systemctl enable --now virtqemud.socket virtnetworkd.socket virtstoraged.socket"
  else
    pass "modular libvirt daemons active (qemu / network / storage)"
  fi
fi

echo "== firmware (OVMF / UEFI) =="
ovmf_found=""
for c in /usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd /usr/share/edk2/x64/OVMF_CODE.4m.fd \
         /usr/share/edk2/ovmf/OVMF_CODE.secboot.fd /usr/share/edk2/ovmf/OVMF_CODE.fd \
         /usr/share/OVMF/OVMF_CODE.secboot.fd /usr/share/OVMF/OVMF_CODE_4M.secboot.fd \
         /usr/share/OVMF/OVMF_CODE.fd /usr/share/qemu/ovmf-x86_64-code.bin; do
  [[ -f "$c" ]] && { ovmf_found="$c"; break; }
done
if [[ -n "$ovmf_found" ]]; then pass "OVMF firmware: $ovmf_found"; else bad "no OVMF firmware found (install edk2-ovmf / OVMF)"; fi

echo "== host DNS (split-DNS for VIPs) =="
if grep -rqs 'dns=dnsmasq' /etc/NetworkManager/ 2>/dev/null; then
  pass "NetworkManager dnsmasq plugin enabled"
elif systemctl is-active --quiet systemd-resolved 2>/dev/null; then
  pass "systemd-resolved active (split-DNS capable)"
else
  warn "no NM-dnsmasq / systemd-resolved: host may not resolve api/*.apps (see docs/troubleshooting.md)"
fi

echo "== core tools =="
for t in curl jq tar openssl python3; do
  if have "$t"; then pass "$t"; else bad "$t missing"; fi
done
if have nmstatectl; then pass "nmstatectl ($(nmstatectl --version 2>/dev/null | head -1))"
else warn "nmstatectl missing: agent-based install with static/bonded networkConfig needs it (package: nmstate)"; fi

echo "== ansible =="
AP=""
[[ -x "$ROOT/.venv/bin/ansible-playbook" ]] && AP="$ROOT/.venv/bin/ansible-playbook"
have ansible-playbook && AP="${AP:-ansible-playbook}"
if [[ -n "$AP" ]]; then
  pass "ansible-playbook ($AP)"
  galaxy="${AP%ansible-playbook}ansible-galaxy"
  for col in community.libvirt community.general kubernetes.core community.docker; do
    if "$galaxy" collection list 2>/dev/null | grep -q "$col"; then pass "collection $col"
    else warn "collection $col missing (run scripts/bootstrap.sh or ansible-galaxy install -r)"; fi
  done
  # The modules import these python libs from the same venv (see group_vars/local.yml):
  # libvirt for community.libvirt, kubernetes for kubernetes.core, docker for community.docker.
  py="${AP%ansible-playbook}python"
  if [[ -x "$py" ]]; then
    miss=""
    for m in libvirt kubernetes docker; do "$py" -c "import $m" 2>/dev/null || miss="$miss $m"; done
    if [[ -n "$miss" ]]; then warn "venv python missing module(s):$miss (run scripts/bootstrap.sh)"
    else pass "venv python libs (libvirt / kubernetes / docker)"; fi
  fi
else
  warn "ansible not installed yet (run scripts/bootstrap.sh)"
fi

if have oc || [[ -x "$ROOT/build/openshift-install/oc" ]] || have kubectl; then
  pass "oc / kubectl present (day-2: adopt, operators, status, mirror)"
else
  warn "no oc / kubectl: day-2 (make adopt / operators / status) and mirror need it (bootstrap fetches oc)"
fi

echo "== openshift-install =="
if [[ -x "$ROOT/build/openshift-install/openshift-install" ]]; then
  pass "openshift-install present ($("$ROOT/build/openshift-install/openshift-install" version 2>/dev/null | head -1))"
elif have openshift-install; then pass "openshift-install on PATH"
else warn "openshift-install missing (run scripts/bootstrap.sh)"; fi

echo "== capacity =="
if have free; then
  ram=$(free -g | awk '/^Mem:/{print $2}')
  if (( ram >= 32 )); then pass "RAM ${ram}GiB"
  elif (( ram >= 20 )); then warn "RAM ${ram}GiB: ok for SNO, tight for 3-node"
  else bad "RAM ${ram}GiB: a single node wants ~32GiB"; fi
fi
if [[ -d /var/lib/libvirt/images ]]; then
  free_g=$(df -BG --output=avail /var/lib/libvirt/images 2>/dev/null | tail -1 | tr -dc '0-9')
  if [[ -n "$free_g" ]] && (( free_g >= 200 )); then pass "image pool free ${free_g}GiB"
  else warn "image pool free ${free_g:-?}GiB: disks are thin-provisioned (128+1024GiB each) but plan headroom"; fi
fi

echo "== container runtime (optional) =="
if have docker; then
  pass "docker ($(docker --version 2>/dev/null))"
elif have podman; then
  pass "podman ($(podman --version 2>/dev/null))"
  # community.docker (the host appliances) talks to a Docker API socket; podman has
  # no daemon, so its socket is opt-in.
  if systemctl --user is-active --quiet podman.socket 2>/dev/null || systemctl is-active --quiet podman.socket 2>/dev/null; then
    pass "podman.socket active (community.docker can reach it)"
  else
    warn "podman.socket inactive: host appliances (community.docker) need it.
       Enable: systemctl --user enable --now podman.socket (rootless) or sudo for rootful"
  fi
else
  warn "no podman/docker (only needed for host appliances: make haproxy, make nfs, make metallb-bgp, make mirror)"
fi

echo "== docs tooling (optional) =="
for t in pandoc mmdc chromium; do
  if have "$t"; then pass "$t"; else warn "$t missing (only needed for scripts/export-pdf.sh)"; fi
done

echo
if (( fails > 0 )); then
  printf '\033[1;31m%d hard requirement(s) failed.\033[0m\n' "$fails"; exit 1
fi
printf '\033[1;32mAll hard requirements met.\033[0m WARN items are optional / context-dependent.\n'
