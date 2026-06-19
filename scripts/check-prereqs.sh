#!/usr/bin/env bash
# Check host prerequisites for the virtual baremetal OCP lab.
# Prints PASS / WARN / FAIL per item. Exits non-zero if any hard requirement fails.
#   scripts/check-prereqs.sh
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
  for col in community.libvirt community.general; do
    if "$galaxy" collection list 2>/dev/null | grep -q "$col"; then pass "collection $col"
    else warn "collection $col missing (run scripts/bootstrap.sh or ansible-galaxy install -r)"; fi
  done
else
  warn "ansible not installed yet (run scripts/bootstrap.sh)"
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

echo "== docs tooling (optional) =="
for t in pandoc mmdc chromium; do
  if have "$t"; then pass "$t"; else warn "$t missing (only needed for scripts/export-pdf.sh)"; fi
done

echo
if (( fails > 0 )); then
  printf '\033[1;31m%d hard requirement(s) failed.\033[0m\n' "$fails"; exit 1
fi
printf '\033[1;32mAll hard requirements met.\033[0m WARN items are optional / context-dependent.\n'
