#!/usr/bin/env python3
"""Print each startup milestone, with its elapsed time, as it is reached.

bench.sh's old progress loop printed `phase=Pending ready=False`, which on a cold
multi-GB pull is six or seven minutes of no information. This prints the number
for each step at the moment the step completes, so the breakdown builds up on
screen during the run instead of only appearing at the end.

  bin/watch_stages.py <context> <namespace> <pod> <nodepool> <timeout-seconds> <image>

Exits 0 when the pod reaches Ready, 1 on timeout or pod failure. Either way
bench.sh goes on to collect and compute -- a partial run is still evidence.
"""

from __future__ import annotations

import json
import pathlib
import subprocess
import sys
import time
from datetime import datetime, timezone

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from stages import (  # noqa: E402
    analyse_pull,
    condition_time,
    condition_true_time,
    drop_pre_pod_anchors,
    parse_ts,
    pick_nodeclaim,
)

# (key, label) in the order they are expected to happen. Printed once each, when
# first observed, with elapsed-since-submit and the delta from the previous
# milestone -- the delta is the per-step number.
MILESTONES = [
    ("nodeclaim_created", "Karpenter decided, NodeClaim created"),
    ("nodeclaim_launched", "EC2 instance launched"),
    ("nodeclaim_registered", "node registered with the cluster"),
    ("node_ready", "node Ready"),
    ("pod_scheduled", "pod bound to the node"),
    # Init before pull: kubelet pulls the init image, runs the init container, and
    # only then pulls the workload image. Phase 1 has no init container, so this
    # order is right for both.
    ("init_started", "init container started"),
    ("init_finished", "init container finished"),
    ("pull_start", "image pull started"),
    ("pull_end", "image pull finished"),
    ("container_started", "container started"),
    ("pod_ready", "workload Ready"),
]

TICK_SECONDS = 3


def kubectl_json(context, *args):
    cmd = ["kubectl", "--context", context, *args, "-o", "json"]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=30, check=False)
    except subprocess.TimeoutExpired:
        return {}
    if out.returncode != 0:
        return {}
    try:
        return json.loads(out.stdout)
    except json.JSONDecodeError:
        return {}


def gather(context, namespace, pod_name, nodepool, workload_image):
    pod = kubectl_json(context, "-n", namespace, "get", "pod", pod_name)
    nodeclaims = kubectl_json(context, "get", "nodeclaims", "-l", f"karpenter.sh/nodepool={nodepool}")
    events = kubectl_json(
        context, "-n", namespace, "get", "events",
        "--field-selector", f"involvedObject.name={pod_name}",
    )

    node_name = (pod.get("spec") or {}).get("nodeName")
    nodeclaim = pick_nodeclaim(nodeclaims, node_name)
    pull = analyse_pull(events, workload_image)

    # Fetched so the live view uses the same node-readiness anchor as the final
    # table. Without it the two disagree about when the node became usable.
    node = kubectl_json(context, "get", "node", node_name) if node_name else {}

    found = {
        "pod_created": parse_ts((pod.get("metadata") or {}).get("creationTimestamp")),
        "nodeclaim_created": parse_ts((nodeclaim.get("metadata") or {}).get("creationTimestamp")),
        "nodeclaim_launched": condition_time(nodeclaim, "Launched"),
        "nodeclaim_registered": condition_time(nodeclaim, "Registered"),
        "node_ready": (
            condition_true_time(node, "Ready") or condition_time(nodeclaim, "Initialized")
        ),
        "pod_scheduled": condition_time(pod, "PodScheduled"),
        "pull_start": pull["pull_start"],
        "pull_end": pull["pull_end"],
        "pod_ready": condition_true_time(pod, "Ready"),
    }

    status = pod.get("status") or {}

    init_statuses = status.get("initContainerStatuses") or []
    if init_statuses:
        state = init_statuses[0].get("state") or {}
        running = state.get("running") or {}
        terminated = state.get("terminated") or {}
        found["init_started"] = parse_ts(running.get("startedAt") or terminated.get("startedAt"))
        found["init_finished"] = parse_ts(terminated.get("finishedAt"))

    container_statuses = status.get("containerStatuses") or []
    if container_statuses:
        state = container_statuses[0].get("state") or {}
        found["container_started"] = parse_ts((state.get("running") or {}).get("startedAt"))

    extra = {
        "phase": status.get("phase", "Pending"),
        "node_name": node_name,
        "image_already_present": pull["image_already_present"],
        "image_bytes": pull["image_bytes"],
        "reported_pull_seconds": pull["reported_pull_seconds"],
        "waiting_reason": None,
    }

    for container in container_statuses:
        waiting = (container.get("state") or {}).get("waiting") or {}
        if waiting.get("reason"):
            extra["waiting_reason"] = waiting["reason"]

    found = {k: v for k, v in found.items() if v is not None}

    # Same filter the final table applies. On a warm run the node is already up, so
    # the NodeClaim's conditions predate this pod; without dropping them the live
    # view prints large negative elapsed times and disagrees with the table that
    # follows it.
    found, dropped = drop_pre_pod_anchors(found)
    extra["dropped_pre_pod"] = dropped

    return found, extra


def main() -> int:
    if len(sys.argv) != 7:
        print(
            "usage: watch_stages.py <context> <namespace> <pod> <nodepool> "
            "<timeout-seconds> <image>",
            file=sys.stderr,
        )
        return 2

    context, namespace, pod_name, nodepool, timeout, image = sys.argv[1:7]
    timeout = int(timeout)

    deadline = time.monotonic() + timeout

    # Elapsed is measured from the pod's own creationTimestamp, the same anchor
    # stages.py uses, so the live numbers and the final table agree. Falling back
    # to now() only matters for the first tick or two, before the pod is visible.
    #
    # Not using now() as the baseline is deliberate: Kubernetes timestamps are
    # floored to the second, so a milestone stamped in the same second the pod was
    # submitted can otherwise come out negative.
    started = None
    fallback_start = datetime.now(timezone.utc)

    # Ties are common for the same reason -- several milestones inside one second
    # share a timestamp -- so break them on the canonical order rather than
    # whatever order the dict happens to be in.
    canonical = {key: i for i, (key, _) in enumerate(MILESTONES)}
    canonical["pod_created"] = -1

    seen: dict[str, datetime] = {}
    previous_time = None
    reported_flags: set[str] = set()

    print()
    print(f"  {'step':<38} {'at':>8} {'step took':>11}")
    print(f"  {'-' * 38} {'-' * 8} {'-' * 11}")

    exit_code = 1

    while True:
        found, extra = gather(context, namespace, pod_name, nodepool, image)

        if started is None and "pod_created" in found:
            started = found["pod_created"]
            previous_time = started
        base = started if started is not None else fallback_start
        if previous_time is None:
            previous_time = base

        # Notes first, so that on a fast arm the "nothing to pull" line does not
        # land underneath the total it explains.
        if extra["image_already_present"] and "already_present" not in reported_flags:
            print("  image already on node, nothing to pull")
            reported_flags.add("already_present")

        if extra["node_name"] and "node" not in reported_flags:
            print(f"  -> node {extra['node_name']}")
            reported_flags.add("node")

        if extra.get("dropped_pre_pod") and "warm" not in reported_flags:
            print("  warm run: node already existed, provisioning steps not repeated")
            reported_flags.add("warm")

        # Print newly observed milestones in the order they actually happened, not
        # the order they were discovered -- several can land inside one tick.
        fresh = [(k, v) for k, v in found.items() if k not in seen and k != "pod_created"]
        for key, when in sorted(fresh, key=lambda kv: (kv[1], canonical.get(kv[0], 99))):
            label = dict(MILESTONES).get(key, key)
            elapsed = (when - base).total_seconds()
            step = (when - previous_time).total_seconds()
            print(f"  {label:<38} {elapsed:>7.0f}s {step:>10.0f}s")
            seen[key] = when
            previous_time = max(previous_time, when)

        if extra["waiting_reason"] in ("ErrImagePull", "ImagePullBackOff", "CreateContainerError"):
            if extra["waiting_reason"] not in reported_flags:
                print(f"  !! container waiting: {extra['waiting_reason']}")
                reported_flags.add(extra["waiting_reason"])

        if "pod_ready" in seen:
            total = (seen["pod_ready"] - base).total_seconds()
            print(f"  {'-' * 38} {'-' * 8} {'-' * 11}")
            print(f"  {'submit to Ready':<38} {total:>7.0f}s")
            exit_code = 0
            break

        if extra["phase"] == "Failed":
            print("  !! pod Failed")
            break

        if time.monotonic() > deadline:
            print(f"  !! timed out after {timeout}s")
            break

        time.sleep(TICK_SECONDS)

    print()
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
