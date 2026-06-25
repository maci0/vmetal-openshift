#!/usr/bin/env python3
"""Offline topology/template validation. No libvirt required.

Renders the topology + network/domain templates for a few cluster shapes and
asserts:
  * all generated XML is well-formed (xmllint)
  * subnets, bridge names, and MACs are globally unique
  * each node has sum(nic_layout NIC counts) interfaces
  * OOB role gets no guest NIC
Run: python3 tests/render_check.py
"""
import os
import subprocess
import sys

try:
    import yaml
    from jinja2 import Environment, FileSystemLoader
except ImportError:
    print("SKIP: pyyaml/jinja2 not installed (activate .venv)")
    sys.exit(0)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ANS = os.path.join(ROOT, "ansible")
env = Environment(loader=FileSystemLoader(os.path.join(ANS, "templates")))
base = yaml.safe_load(open(os.path.join(ANS, "group_vars", "all.yml")))
base["playbook_dir"] = ANS

failures = []


def xmllint(xml, label):
    p = subprocess.run(["xmllint", "--noout", "-"], input=xml.encode(),
                       capture_output=True)
    if p.returncode != 0:
        failures.append(f"{label}: {p.stderr.decode().strip()}")


def check(label, clusters):
    v = dict(base)
    v["clusters"] = clusters
    topo = yaml.safe_load(env.get_template("topology.yml.j2").render(**v))
    nt = env.get_template("libvirt/network.xml.j2")
    dt = env.get_template("libvirt/domain.xml.j2")
    subs, brs, macs = set(), set(), set()

    def attaches(b, role, sched):  # role-aware NIC layout (matches topology/nmstate)
        roles = b.get("roles")
        return (roles is None or role in roles
                or (role == "master" and sched and "worker" in roles))

    def expected_nics(role, sched):
        return sum(b["nics"] for b in base["nic_layout"] if attaches(b, role, sched))

    for c in topo:
        for net in c["networks"]:
            if net.get("gateway"):
                s = net["gateway"].rsplit(".", 1)[0]
                if s in subs:
                    failures.append(f"dup subnet {s}")
                subs.add(s)
            if net["bridge"] in brs:
                failures.append(f"dup bridge {net['bridge']}")
            brs.add(net["bridge"])
            xmllint(nt.render(net=net, **v), f"net {net['name']}")
        sched = c["masters_schedulable"]
        for node in c["nodes"] + (c.get("day2_workers") or []):
            # The transient upi bootstrap node only needs the machine NIC.
            if node["role"] == "bootstrap":
                continue
            ifaces = node["interfaces"]
            exp = expected_nics(node["role"], sched)
            if len(ifaces) != exp:
                failures.append(
                    f"{node['fullname']} ({node['role']}): {len(ifaces)} NICs, expected {exp}")
            for nic in ifaces:
                if nic["mac"] in macs:
                    failures.append(f"dup mac {nic['mac']}")
                macs.add(nic["mac"])
                if nic["attach"].endswith("-oob"):
                    failures.append(f"{node['fullname']}: NIC attached to OOB LAN")
            xmllint(dt.render(cluster=c, node=node, **v), f"dom {node['fullname']}")
    print(f"  {label}: {len(topo)} cluster(s), "
          f"{len(subs)} subnets, {len(macs)} MACs checked")


check("default", base["clusters"])
check("multi-2x3", [
    {"name": "c0", "node_count": 3, "subnet_index": 0},
    {"name": "c1", "node_count": 1, "subnet_index": 1},
])

if failures:
    print("\nFAIL:")
    for f in failures:
        print("  -", f)
    sys.exit(1)
print("\nrender_check: PASS")
