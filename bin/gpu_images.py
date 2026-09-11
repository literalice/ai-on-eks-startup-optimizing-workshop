#!/usr/bin/env python3
"""List the container images the cluster's GPU pods run, so the image to pre-bake does not
have to be recalled or copied out of a manifest by hand.

    bin/gpu_images.py                    # current kubectl context
    bin/gpu_images.py --context <name>
    bin/gpu_images.py --one              # print one image and nothing else, or exit 1

Read-only. Every image printed is one that is running now, which is the point: a snapshot
built from a tag nothing runs is a snapshot the measurement will not use.

Two passes, because not every GPU workload declares the resource. First, containers that
request a *gpu resource. If none do, pods running on nodes that advertise gpu capacity, which
catches time-slicing and setups where the device plugin is not installed. Which pass produced
the list is printed, since the second is a weaker signal.
"""

import argparse
import json
import subprocess
import sys
from collections import defaultdict

# Pause containers, the device plugin and the like. Not a security boundary, just noise
# removal: these are never the workload whose startup is being measured.
SKIP_NAMESPACES = {"kube-system", "karpenter", "amazon-cloudwatch", "kube-node-lease",
                   "kube-public", "gpu-operator", "nvidia-device-plugin"}


def kubectl(args, context):
    cmd = ["kubectl"]
    if context:
        cmd += ["--context", context]
    cmd += args + ["-o", "json"]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, check=True).stdout
    except FileNotFoundError:
        sys.exit("kubectl is not on PATH")
    except subprocess.CalledProcessError as e:
        sys.exit(f"{' '.join(cmd)} failed:\n{e.stderr.strip()}")
    return json.loads(out).get("items", [])


def is_gpu_resource(name):
    return "gpu" in name.lower()


def gpu_containers(pod):
    """Containers in this pod that ask for a gpu resource, init containers included."""
    spec = pod.get("spec") or {}
    for key in ("containers", "initContainers"):
        for c in spec.get(key) or []:
            res = c.get("resources") or {}
            for section in ("limits", "requests"):
                if any(is_gpu_resource(k) for k in (res.get(section) or {})):
                    yield c
                    break


def all_containers(pod):
    spec = pod.get("spec") or {}
    for key in ("containers", "initContainers"):
        yield from (spec.get(key) or [])


def gpu_node_names(context):
    names = set()
    for node in kubectl(["get", "nodes"], context):
        cap = (node.get("status") or {}).get("capacity") or {}
        if any(is_gpu_resource(k) and cap[k] not in ("0", 0) for k in cap):
            names.add(node["metadata"]["name"])
    return names


def collect(context):
    """Returns (rows, how), where rows map image -> {"pods": n, "namespaces": set}."""
    pods = [p for p in kubectl(["get", "pods", "--all-namespaces"], context)
            if p["metadata"]["namespace"] not in SKIP_NAMESPACES
            and (p.get("status") or {}).get("phase") in ("Running", "Pending")]

    rows = defaultdict(lambda: {"pods": 0, "namespaces": set()})
    for pod in pods:
        for c in gpu_containers(pod):
            entry = rows[c["image"]]
            entry["pods"] += 1
            entry["namespaces"].add(pod["metadata"]["namespace"])
    if rows:
        return rows, "containers requesting a GPU resource"

    on_gpu_nodes = gpu_node_names(context)
    if on_gpu_nodes:
        for pod in pods:
            if (pod.get("spec") or {}).get("nodeName") not in on_gpu_nodes:
                continue
            for c in all_containers(pod):
                entry = rows[c["image"]]
                entry["pods"] += 1
                entry["namespaces"].add(pod["metadata"]["namespace"])
    if rows:
        return rows, "pods running on nodes that advertise GPU capacity"
    return rows, None


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--context", default=None, help="kubectl context. Default: current")
    ap.add_argument("--one", action="store_true",
                    help="print a single image and nothing else. Exits 1 if it is ambiguous")
    args = ap.parse_args()

    rows, how = collect(args.context)
    ordered = sorted(rows.items(), key=lambda kv: (-kv[1]["pods"], kv[0]))

    if args.one:
        if len(ordered) != 1:
            return 1
        print(ordered[0][0])
        return 0

    where = args.context or "the current context"
    if not ordered:
        print(f"==> no GPU pods found in {where}")
        print("    Nothing requests a GPU resource, and no node advertises GPU capacity.")
        print("    Name the image directly:")
        print('      IMAGE="<registry>/<repo>:<tag>" snapshot/build-snapshot.sh')
        return 1

    print(f"==> images running in {where}, from {how}")
    print()
    width = max(len(image) for image, _ in ordered)
    print(f"    {'pods':>4}  {'image':<{width}}  namespaces")
    for image, info in ordered:
        namespaces = ",".join(sorted(info["namespaces"]))
        print(f"    {info['pods']:>4}  {image:<{width}}  {namespaces}")
    print()

    if len(ordered) == 1:
        print("==> one candidate. To pre-bake it:")
        print(f'      IMAGE="{ordered[0][0]}" snapshot/build-snapshot.sh')
    else:
        print(f"==> {len(ordered)} candidates. Pick the one whose startup you are measuring:")
        print(f'      IMAGE="{ordered[0][0]}" snapshot/build-snapshot.sh')
        print()
        print("    A snapshot holds the images you name, so several can go in one:")
        print("      the wrapped script takes more than one image argument.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
