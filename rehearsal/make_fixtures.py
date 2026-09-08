#!/usr/bin/env python3
"""Generate synthetic Kubernetes objects for the rehearsal.

REHEARSAL DATA. These are invented timings, shaped to look like a plausible run so
the narration can be paced and the recording pipeline verified without spending
money. They are not measurements and must never be presented as any.

The relative ordering is realistic (SOCI beats sequential, the snapshot skips the
pull, the init container serialises ahead of the workload image pull) because the
point is to rehearse the story, but the absolute numbers are made up.

  rehearsal/make_fixtures.py <output-dir>
"""

from __future__ import annotations

import json
import pathlib
import sys
from datetime import datetime, timedelta, timezone

BASE = datetime(2026, 9, 11, 5, 0, 0, tzinfo=timezone.utc)
WORKLOAD = "763104351884.dkr.ecr.us-west-2.amazonaws.com/vllm:0.22.0-gpu-py312-cu130-ubuntu22.04-ec2"
INIT_IMAGE = "public.ecr.aws/aws-cli/aws-cli:latest"
IMAGE_BYTES = 11_453_246_976


def ts(offset: float) -> str:
    return (BASE + timedelta(seconds=offset)).strftime("%Y-%m-%dT%H:%M:%SZ")


def node(zone="us-west-2a", os_image="Bottlerocket OS 1.64.0 (aws-k8s-1.34-nvidia)",
         runtime="containerd://2.1.4", name="ip-10-0-1-5"):
    return {
        "metadata": {
            "name": name,
            "labels": {
                "node.kubernetes.io/instance-type": "g6.4xlarge",
                "topology.kubernetes.io/zone": zone,
                "karpenter.sh/capacity-type": "on-demand",
            },
        },
        "status": {
            "nodeInfo": {
                "osImage": os_image,
                "kernelVersion": "6.12.34",
                "containerRuntimeVersion": runtime,
                "kubeletVersion": "v1.34.1-eks-1a2b3c4",
            }
        },
    }


def pod(o, node_name="ip-10-0-1-5", init=None):
    status = {
        "phase": "Running",
        "conditions": [
            {"type": "PodScheduled", "status": "True", "lastTransitionTime": ts(o["scheduled"])},
            {"type": "Ready", "status": "True", "lastTransitionTime": ts(o["ready"])},
        ],
        "containerStatuses": [
            {"name": "workload", "state": {"running": {"startedAt": ts(o["container_started"])}}}
        ],
    }
    if init:
        status["initContainerStatuses"] = [
            {
                "name": "fetch-weights",
                "state": {
                    "terminated": {
                        "startedAt": ts(init["started"]),
                        "finishedAt": ts(init["finished"]),
                        "exitCode": 0,
                    }
                },
            }
        ]
    return {
        "metadata": {"name": "bench", "creationTimestamp": ts(o["created"])},
        "spec": {"nodeName": node_name},
        "status": status,
    }


def nodeclaims(o, node_name="ip-10-0-1-5", pool="pool"):
    return {
        "items": [
            {
                "metadata": {
                    "name": "nc-1",
                    "creationTimestamp": ts(o["nc_created"]),
                    "labels": {"karpenter.sh/nodepool": pool},
                },
                "status": {
                    "nodeName": node_name,
                    "conditions": [
                        {"type": "Launched", "status": "True", "lastTransitionTime": ts(o["launched"])},
                        {"type": "Registered", "status": "True", "lastTransitionTime": ts(o["registered"])},
                        {"type": "Initialized", "status": "True", "lastTransitionTime": ts(o["initialized"])},
                    ],
                },
            }
        ]
    }


def event(reason, message, offset):
    return {
        "reason": reason,
        "message": message,
        "firstTimestamp": ts(offset),
        "lastTimestamp": ts(offset),
        "involvedObject": {"name": "bench"},
    }


def pulled(seconds, offset, waiting=None):
    wait = waiting if waiting is not None else seconds + 2
    return event(
        "Pulled",
        f'Successfully pulled image "{WORKLOAD}" in {seconds}s '
        f"({wait}s including waiting). Image size: {IMAGE_BYTES} bytes.",
        offset,
    )


def already_present(offset):
    return event("Pulled", f'Container image "{WORKLOAD}" already present on machine', offset)


ARMS = {}

# ---------------------------------------------------------------- cold arms
ARMS["arm-a-baseline"] = dict(
    offsets=dict(created=0, nc_created=2, launched=5, registered=45, initialized=50,
                 scheduled=52, container_started=418, ready=425),
    events=[event("Pulling", f'Pulling image "{WORKLOAD}"', 55), pulled("6m0.2s", 415, "6m3.1s")],
    node=node(),
)
ARMS["arm-b-snapshot"] = dict(
    offsets=dict(created=0, nc_created=2, launched=5, registered=48, initialized=53,
                 scheduled=55, container_started=58, ready=64),
    events=[already_present(56)],
    node=node(),
)
ARMS["arm-c-soci"] = dict(
    offsets=dict(created=0, nc_created=2, launched=5, registered=44, initialized=49,
                 scheduled=51, container_started=207, ready=214),
    events=[event("Pulling", f'Pulling image "{WORKLOAD}"', 54), pulled("2m30.0s", 204, "2m32.4s")],
    node=node(),
)
ARMS["arm-d-automode"] = dict(
    offsets=dict(created=0, nc_created=3, launched=7, registered=58, initialized=64,
                 scheduled=66, container_started=232, ready=240),
    events=[event("Pulling", f'Pulling image "{WORKLOAD}"', 69), pulled("2m39.0s", 228, "2m40.1s")],
    node=node(zone="us-west-2b", os_image="Bottlerocket OS 1.64.0 (aws-k8s-1.34-nvidia)"),
)

# ------------------------------------------------------------------ warm run
# NodeClaim created long before the pod, which is what makes this warm.
ARMS["arm-c-soci-warm"] = dict(
    offsets=dict(created=1000, nc_created=0, launched=3, registered=43, initialized=48,
                 scheduled=1002, container_started=1004, ready=1010),
    events=[already_present(1003)],
    node=node(),
)

# ------------------------------------------------------- phase 2, 3 variants
TTFT = {"total_seconds": 2.10, "tokens_received": 64, "model": "qwen2.5-1.5b-instruct"}

ARMS["weights-s3-initcontainer"] = dict(
    offsets=dict(created=2000, nc_created=0, launched=3, registered=43, initialized=48,
                 scheduled=2002, container_started=2196, ready=2251),
    init={"started": 2006, "finished": 2191},
    events=[
        event("Pulling", f'Pulling image "{INIT_IMAGE}"', 2003),
        event("Pulled", f'Successfully pulled image "{INIT_IMAGE}" in 3.0s (3.2s including waiting). Image size: 120000000 bytes.', 2005),
        already_present(2192),
    ],
    node=node(),
    ttft={**TTFT, "ttft_seconds": 0.42},
)
ARMS["weights-runai-local"] = dict(
    offsets=dict(created=3000, nc_created=0, launched=3, registered=43, initialized=48,
                 scheduled=3002, container_started=3196, ready=3214),
    init={"started": 3006, "finished": 3191},
    events=[
        event("Pulling", f'Pulling image "{INIT_IMAGE}"', 3003),
        event("Pulled", f'Successfully pulled image "{INIT_IMAGE}" in 3.0s (3.2s including waiting). Image size: 120000000 bytes.', 3005),
        already_present(3192),
    ],
    node=node(),
    ttft={**TTFT, "ttft_seconds": 0.39, "total_seconds": 2.05},
)
ARMS["weights-runai-s3"] = dict(
    offsets=dict(created=4000, nc_created=0, launched=3, registered=43, initialized=48,
                 scheduled=4002, container_started=4006, ready=4029),
    events=[already_present(4003)],
    node=node(),
    ttft={**TTFT, "ttft_seconds": 0.41, "total_seconds": 2.08},
)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: make_fixtures.py <output-dir>", file=sys.stderr)
        return 2

    out = pathlib.Path(sys.argv[1])
    for name, spec in ARMS.items():
        d = out / name
        d.mkdir(parents=True, exist_ok=True)
        (d / "pod.json").write_text(json.dumps(
            pod(spec["offsets"], init=spec.get("init")), indent=2))
        (d / "nodeclaims.json").write_text(json.dumps(
            nodeclaims(spec["offsets"], pool=name), indent=2))
        (d / "events.json").write_text(json.dumps({"items": spec["events"]}, indent=2))
        (d / "node.json").write_text(json.dumps(spec["node"], indent=2))
        (d / "arm.txt").write_text(name + "\n")
        (d / "instance-type.txt").write_text("g6.4xlarge\n")
        (d / "image.txt").write_text(WORKLOAD + "\n")
        if spec.get("ttft"):
            (d / "ttft.json").write_text(json.dumps(spec["ttft"], indent=2))
        print(f"  {name}")

    print(f"\nREHEARSAL fixtures written to {out}")
    print("These are invented timings. Not measurements.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
