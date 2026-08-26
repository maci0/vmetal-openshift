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

import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

import yaml
from jinja2 import Environment, FileSystemLoader

ROOT = Path(__file__).resolve().parent.parent
ANS = ROOT / "ansible"
HAVE_XMLLINT = shutil.which("xmllint") is not None

Cluster = dict[str, Any]

failures: list[str] = []


def xmllint(xml: str, label: str) -> None:
    if not HAVE_XMLLINT:
        return
    p = subprocess.run(["xmllint", "--noout", "-"], input=xml.encode(), capture_output=True)
    if p.returncode != 0:
        failures.append(f"{label}: {p.stderr.decode().strip()}")


def check(env: Environment, base: dict[str, Any], label: str, clusters: list[Cluster]) -> None:
    v = dict(base)
    v["clusters"] = clusters
    topo = yaml.safe_load(env.get_template("topology.yml.j2").render(**v))
    nt = env.get_template("libvirt/network.xml.j2")
    dt = env.get_template("libvirt/domain.xml.j2")
    subs: set[str] = set()
    brs: set[str] = set()
    macs: set[str] = set()

    def attaches(b: dict[str, Any], role: str, sched: bool) -> bool:
        """Role-aware NIC layout, matching topology.yml.j2 and the nmstate template."""
        roles = b.get("roles")
        return roles is None or role in roles or (role == "master" and sched and "worker" in roles)

    def expected_nics(role: str, sched: bool) -> int:
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
                    f"{node['fullname']} ({node['role']}): {len(ifaces)} NICs, expected {exp}"
                )
            for nic in ifaces:
                if nic["mac"] in macs:
                    failures.append(f"dup mac {nic['mac']}")
                macs.add(nic["mac"])
                if nic["attach"].endswith("-oob"):
                    failures.append(f"{node['fullname']}: NIC attached to OOB LAN")
            xmllint(dt.render(cluster=c, node=node, **v), f"dom {node['fullname']}")
    print(f"  {label}: {len(topo)} cluster(s), {len(subs)} subnets, {len(macs)} MACs checked")


def main() -> None:
    if not HAVE_XMLLINT:
        print("SKIP: xmllint not installed (libxml2-utils); XML well-formedness not checked")

    env = Environment(loader=FileSystemLoader(ANS / "templates"))
    with (ANS / "group_vars" / "all.yml").open(encoding="utf-8") as fh:
        base = yaml.safe_load(fh)
    # Match real lifecycle playbooks (playbook_dir = ansible/lifecycle).
    base["playbook_dir"] = str(ANS / "lifecycle")
    base["repo_root"] = str(ROOT)

    check(env, base, "default", base["clusters"])
    check(
        env,
        base,
        "multi-3node+SNO",
        [
            {"name": "c0", "control_plane": 3, "workers": 0, "subnet_index": 0},
            {"name": "c1", "control_plane": 1, "workers": 0, "subnet_index": 1},
        ],
    )
    # Non-schedulable masters + workers: exercises role-aware bond1 filtering.
    check(
        env,
        base,
        "ha+workers",
        [
            {"name": "ha", "control_plane": 3, "workers": 2, "subnet_index": 0},
        ],
    )

    if failures:
        print("\nFAIL:")
        for f in failures:
            print("  -", f)
        sys.exit(1)
    print("\nrender_check: PASS")


if __name__ == "__main__":
    main()
