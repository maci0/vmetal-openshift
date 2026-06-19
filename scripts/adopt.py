#!/usr/bin/env python3
"""Day-2: enable in-cluster BareMetalHost power management on a baremetal cluster.

Deploys the metal3 Provisioning CR, waits for metal3 + its admission webhook,
then enables the BMC on each node:

  * Existing unmanaged BMHs (created by an agent baremetal install) are patched
    with BMC creds -> "externally provisioned", enabling power control WITHOUT
    reprovisioning. This is the default, safe path.
  * With ADOPT_HOSTS=1 and no existing BMHs, fresh BareMetalHosts are enrolled
    (only for genuinely new hardware; applying a BMH to a running node wipes it).

Only works on platform: baremetal (node_count >= 3). Single-node is platform:
none (no metal3); IPI creates BMHs during install.

    scripts/adopt.py [cluster]      (or CLUSTER=... ADOPT_HOSTS=1)
"""
import os
import shutil
import subprocess
import sys
import time

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NS = "openshift-machine-api"


def die(msg):
    sys.stderr.write(f"\033[1;31m!!\033[0m {msg}\n")
    sys.exit(1)


def log(msg):
    print(f"\033[1;32m==>\033[0m {msg}")


def kc(*args, check=True, quiet=False):
    out = subprocess.DEVNULL if quiet else None
    return subprocess.run([KUBECTL, "-n", NS, *args], check=check, stdout=out)


def main():
    global KUBECTL
    cluster = (sys.argv[1] if len(sys.argv) > 1 else os.environ.get("CLUSTER", "cluster0"))
    cdir = os.path.join(ROOT, "clusters", cluster)

    KUBECTL = shutil.which("oc") or shutil.which("kubectl") or die("need oc or kubectl on PATH")
    kubeconfig = os.path.join(cdir, "auth", "kubeconfig")
    if not os.path.isfile(kubeconfig):
        die(f"no kubeconfig for '{cluster}' (install it first)")
    os.environ["KUBECONFIG"] = kubeconfig

    prov = os.path.join(cdir, "provisioning.yaml")
    if not os.path.isfile(prov):
        die(f"no provisioning.yaml for '{cluster}'. Adopt is for agent baremetal "
            "clusters (node_count >= 3). Single-node is platform: none (no metal3); "
            "IPI creates BMHs during install.")

    platform = subprocess.run(
        [KUBECTL, "get", "infrastructure", "cluster", "-o",
         "jsonpath={.status.platform}"], capture_output=True, text=True).stdout.strip()
    if platform != "BareMetal":
        die(f"cluster platform is '{platform}', not BareMetal: metal3 will not deploy.")

    log("Applying metal3 Provisioning CR (deploys metal3/ironic)")
    subprocess.run([KUBECTL, "apply", "-f", prov], check=True)

    log("Waiting for metal3 to roll out")
    kc("rollout", "status", "deploy/metal3", "--timeout=300s", check=False)

    log("Waiting for the baremetal-operator admission webhook")
    for _ in range(40):
        ep = subprocess.run(
            [KUBECTL, "-n", NS, "get", "endpoints", "baremetal-operator-webhook-service",
             "-o", "jsonpath={.subsets[*].addresses[*].ip}"],
            capture_output=True, text=True).stdout.strip()
        if ep:
            break
        time.sleep(6)

    existing = subprocess.run([KUBECTL, "-n", NS, "get", "bmh", "-o", "name"],
                              capture_output=True, text=True).stdout.split()
    bmh_file = os.path.join(cdir, "baremetalhosts.yaml")

    if existing:
        log(f"{len(existing)} existing BMH(s): enabling BMC (power management)")
        secrets, hosts = {}, []
        for d in yaml.safe_load_all(open(bmh_file)):
            if not d:
                continue
            if d["kind"] == "Secret":
                secrets[d["metadata"]["name"]] = d["stringData"]
            elif d["kind"] == "BareMetalHost":
                hosts.append(d)
        for h in hosts:
            name = h["metadata"]["name"]
            bmc = h["spec"]["bmc"]
            cred = bmc["credentialsName"]
            s = secrets.get(cred, {"username": "admin", "password": "password"})
            secret_yaml = subprocess.run(
                [KUBECTL, "-n", NS, "create", "secret", "generic", cred,
                 f"--from-literal=username={s['username']}",
                 f"--from-literal=password={s['password']}",
                 "--dry-run=client", "-o", "yaml"], capture_output=True, text=True).stdout
            subprocess.run([KUBECTL, "apply", "-f", "-"], input=secret_yaml, text=True,
                           check=True, stdout=subprocess.DEVNULL)
            patch = ('{"spec":{"bmc":{"address":"%s","credentialsName":"%s",'
                     '"disableCertificateVerification":true}}}' % (bmc["address"], cred))
            kc("patch", "bmh", name, "--type", "merge", "-p", patch, quiet=True)
            print(f"    enabled BMC on {name}")
    elif os.environ.get("ADOPT_HOSTS") == "1":
        log("ADOPT_HOSTS=1: enrolling fresh BareMetalHosts")
        subprocess.run([KUBECTL, "apply", "-f", bmh_file], check=True)
    else:
        log("No existing BMHs. NOT enrolling (applying a BMH to a running node "
            "reprovisions it). Re-run with ADOPT_HOSTS=1 for fresh hardware.")

    log("metal3 pods + BareMetalHosts:")
    subprocess.run([KUBECTL, "-n", NS, "get", "pods", "--no-headers"], check=False)
    kc("get", "bmh", check=False)


if __name__ == "__main__":
    main()
