#!/usr/bin/env python3
"""Break one pod's start-to-ready wait into stages.

Reads the raw Kubernetes objects bench.sh collected and produces the stage
breakdown that section 1 asks for: where the time actually goes.

The method is deliberately dumb. Collect every timestamp Kubernetes already
records, sort them, and report the gap between each consecutive pair. The stages
therefore sum to the total exactly -- there is no residual bucket and no time
quietly unaccounted for, which is what makes the comparison between variants
defensible rather than suggestive.

Timestamps come from:
  Pod              .metadata.creationTimestamp, .status.conditions,
                   .status.containerStatuses[].state, .status.initContainerStatuses[]
  NodeClaim        .metadata.creationTimestamp and the Launched / Registered /
                   Initialized conditions Karpenter sets
  kubelet Events   Pulling and Pulled, which also carry the pull duration and
                   image size in their message text

Kubernetes records these at one-second granularity, so treat sub-second
differences as noise. The numbers that matter here are tens of seconds to
minutes.
"""

from __future__ import annotations

import json
import pathlib
import re
import sys
from datetime import datetime, timezone

# Canonical order. Used to break ties when two anchors share a timestamp, and to
# keep the chain readable when clocks disagree by a second.
ANCHOR_ORDER = [
    "pod_created",
    "nodeclaim_created",
    "nodeclaim_launched",
    "nodeclaim_registered",
    # The Node object's own Ready condition, not the NodeClaim's Initialized.
    # Initialized is Karpenter bookkeeping that can land anywhere -- in real runs it
    # arrived after the image pull had already started -- which split the pull in two
    # and produced a different pair of stage labels on every run. The node's Ready
    # condition is what "the node is usable" actually means and it always precedes
    # the pod being bound.
    "node_ready",
    "pod_scheduled",
    # Init before pull: kubelet pulls the init image, runs the init container, and
    # only then pulls the workload image. Phase 1 has no init container, so this
    # order is right for both. It only decides tie-breaks -- when two anchors share
    # a timestamp, which they often do at one-second granularity.
    "init_started",
    "init_finished",
    "pull_start",
    "pull_end",
    "container_started",
    "pod_ready",
]

# Friendly names for the gaps we expect to see. Anything unexpected still gets
# reported, just with a generated label.
SEGMENT_LABELS = {
    ("pod_created", "nodeclaim_created"): "Karpenter decision",
    ("nodeclaim_created", "nodeclaim_launched"): "EC2 launch call",
    ("nodeclaim_launched", "nodeclaim_registered"): "boot + node registers",
    ("nodeclaim_registered", "node_ready"): "node becomes Ready",
    ("node_ready", "pod_scheduled"): "pod bound to node",
    ("nodeclaim_registered", "pod_scheduled"): "pod bound to node",
    ("pod_scheduled", "pull_start"): "kubelet picks up pod",
    ("pull_start", "pull_end"): "image pull + unpack",
    ("pull_end", "init_started"): "init container starts",
    ("init_started", "init_finished"): "model weights download",
    ("init_finished", "container_started"): "container start",
    ("pull_end", "container_started"): "container start",
    ("container_started", "pod_ready"): "workload becomes Ready",
    # The snapshot variant: no pull events at all, because the layers arrived on the snapshot.
    ("pod_scheduled", "container_started"): "container start (image already on node)",
    # Warm run: the node already existed, so the pod is scheduled straight away and
    # there are no provisioning anchors in front of it.
    ("pod_created", "pod_scheduled"): "scheduled onto the warm node",
    ("pod_created", "container_started"): "container start on the warm node",
    # Phase 2: kubelet pulls the init image, runs the init container, and only
    # then pulls the workload image -- the two are serialised, not overlapped.
    ("pod_scheduled", "init_started"): "init image pull",
    ("init_finished", "pull_start"): "workload image pull begins",
}


def parse_ts(value):
    """RFC3339 to aware datetime. Kubernetes emits Z, Python wants +00:00."""
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def parse_go_duration(text):
    """'1m30.5s' / '45.2s' / '1h2m3s' to seconds. Returns None if unparseable."""
    if not text:
        return None
    total = 0.0
    matched = False
    for value, unit in re.findall(r"([0-9]*\.?[0-9]+)(h|ms|m|s|us|ns)", text):
        matched = True
        number = float(value)
        if unit == "h":
            total += number * 3600
        elif unit == "m":
            total += number * 60
        elif unit == "s":
            total += number
        elif unit == "ms":
            total += number / 1e3
        elif unit == "us":
            total += number / 1e6
        elif unit == "ns":
            total += number / 1e9
    return total if matched else None


def load(path):
    try:
        return json.loads(pathlib.Path(path).read_text())
    except (OSError, json.JSONDecodeError):
        return {}


def read_line(path, default=""):
    try:
        return pathlib.Path(path).read_text().strip()
    except OSError:
        return default


def condition_time(obj, cond_type):
    for cond in (obj.get("status") or {}).get("conditions") or []:
        if cond.get("type") == cond_type:
            return parse_ts(cond.get("lastTransitionTime"))
    return None


def condition_true_time(obj, cond_type):
    """Only return the transition time if the condition is actually True.

    Matters for Ready: a pod that never became Ready still has a Ready condition,
    with status False and a lastTransitionTime that would silently be read as a
    success.
    """
    for cond in (obj.get("status") or {}).get("conditions") or []:
        if cond.get("type") == cond_type:
            return parse_ts(cond.get("lastTransitionTime")) if cond.get("status") == "True" else None
    return None


def node_facts(node):
    """What the node actually turned out to be.

    The comparison between variants rests on them being the same hardware in the same
    place. Reading it back off the node turns that from an assertion into a check.
    osImage also states the Bottlerocket version and variant, which is the other
    thing variant C silently depends on.
    """
    labels = (node.get("metadata") or {}).get("labels") or {}
    info = (node.get("status") or {}).get("nodeInfo") or {}
    return {
        "instance_type": labels.get("node.kubernetes.io/instance-type"),
        "zone": labels.get("topology.kubernetes.io/zone"),
        "capacity_type": labels.get("karpenter.sh/capacity-type")
        or labels.get("eks.amazonaws.com/capacityType"),
        "os_image": info.get("osImage"),
        "kernel": info.get("kernelVersion"),
        "container_runtime": info.get("containerRuntimeVersion"),
        "kubelet": info.get("kubeletVersion"),
    }


def vllm_timings(log_text):
    """Pull vLLM's own startup timings out of its log.

    This is what makes phase 2 answerable rather than suggestive. "Workload becomes
    Ready" is one number covering several unrelated things, and a loader can only
    affect one of them. On the first real run weight loading was 0.31s out of a
    93s startup -- the rest was torch.compile and engine warmup -- so no amount of
    faster tensor reading could have moved the total. Without these lines the table
    would have shown "Run:ai made no difference" and left the reason invisible.
    """
    if not log_text:
        return {}

    patterns = {
        # default_loader / runai_streamer both log this line
        "weight_load_seconds": r"Loading weights took ([0-9.]+) seconds",
        "model_load_seconds": r"Model loading took [0-9.]+ GiB memory and ([0-9.]+) seconds",
        "torch_compile_seconds": r"torch\.compile took ([0-9.]+) s in total",
        "engine_init_seconds": r"init engine \([^)]*\) took ([0-9.]+) s",
        "graph_capture_seconds": r"Graph capturing finished in ([0-9.]+) secs",
    }

    found = {}
    for key, pattern in patterns.items():
        matches = re.findall(pattern, log_text)
        if matches:
            # Last occurrence: on a restart the later one is the run that succeeded.
            found[key] = float(matches[-1])
    return found


def pick_nodeclaim(nodeclaims, node_name):
    items = nodeclaims.get("items") or []
    if not items:
        return {}
    if node_name:
        for item in items:
            if (item.get("status") or {}).get("nodeName") == node_name:
                return item
    # Fall back to the most recently created, which is the one this run made.
    return max(items, key=lambda i: i.get("metadata", {}).get("creationTimestamp", ""))


def event_time(event):
    """Events carry the time in one of three fields depending on the emitter."""
    for field in ("firstTimestamp", "eventTime", "lastTimestamp"):
        parsed = parse_ts(event.get(field))
        if parsed:
            return parsed
    return parse_ts((event.get("metadata") or {}).get("creationTimestamp"))


def analyse_pull(events, workload_image):
    """Find the workload image's pull window, duration and size.

    Phase 2 has two pulls -- the aws-cli init image and the workload image -- so
    match on the image name rather than taking the first Pulled event.
    """
    result = {
        "pull_start": None,
        "pull_end": None,
        "reported_pull_seconds": None,
        "reported_pull_including_waiting_seconds": None,
        "image_bytes": None,
        "image_already_present": False,
    }

    # The repository is enough to match on; the message may or may not carry the
    # full registry path exactly as configured.
    repo = workload_image.split("@")[0].split(":")[0]
    short = repo.rsplit("/", 1)[-1] if "/" in repo else repo

    def mentions_workload(message):
        return repo in message or (short and short in message)

    for event in events.get("items") or []:
        reason = event.get("reason")
        message = event.get("message") or ""
        when = event_time(event)

        if reason == "Pulling" and mentions_workload(message):
            if result["pull_start"] is None or (when and when < result["pull_start"]):
                result["pull_start"] = when

        elif reason == "Pulled" and mentions_workload(message):
            if "already present on machine" in message:
                # The snapshot variant: the snapshot put the layers on the data volume, so
                # containerd never contacts the registry.
                result["image_already_present"] = True
                continue

            if result["pull_end"] is None or (when and when > result["pull_end"]):
                result["pull_end"] = when

            inner = re.search(r"\bin\s+([0-9hms.µunms]+?)\s*\(", message)
            outer = re.search(r"\(([0-9hms.µunms]+?)\s+including waiting\)", message)
            size = re.search(r"Image size:\s*(\d+)\s*bytes", message)
            if inner:
                result["reported_pull_seconds"] = parse_go_duration(inner.group(1))
            if outer:
                result["reported_pull_including_waiting_seconds"] = parse_go_duration(outer.group(1))
            if size:
                result["image_bytes"] = int(size.group(1))

    return result


def collect_anchors(pod, nodeclaim, pull, node=None):
    anchors = {
        "pod_created": parse_ts((pod.get("metadata") or {}).get("creationTimestamp")),
        "nodeclaim_created": parse_ts((nodeclaim.get("metadata") or {}).get("creationTimestamp")),
        "nodeclaim_launched": condition_time(nodeclaim, "Launched"),
        "nodeclaim_registered": condition_time(nodeclaim, "Registered"),
        # Prefer the Node's own Ready condition; fall back to the NodeClaim's
        # Initialized when the node object was not captured.
        "node_ready": (
            condition_true_time(node or {}, "Ready")
            or condition_time(nodeclaim, "Initialized")
        ),
        "pod_scheduled": condition_time(pod, "PodScheduled"),
        "pull_start": pull["pull_start"],
        "pull_end": pull["pull_end"],
        "pod_ready": condition_true_time(pod, "Ready"),
    }

    status = pod.get("status") or {}

    init_statuses = status.get("initContainerStatuses") or []
    if init_statuses:
        terminated = (init_statuses[0].get("state") or {}).get("terminated") or {}
        anchors["init_started"] = parse_ts(terminated.get("startedAt"))
        anchors["init_finished"] = parse_ts(terminated.get("finishedAt"))

    container_statuses = status.get("containerStatuses") or []
    if container_statuses:
        state = container_statuses[0].get("state") or {}
        running = state.get("running") or {}
        anchors["container_started"] = parse_ts(running.get("startedAt"))
        if anchors["container_started"] is None:
            terminated = state.get("terminated") or {}
            anchors["container_started"] = parse_ts(terminated.get("startedAt"))

    return {k: v for k, v in anchors.items() if v is not None}


def drop_pre_pod_anchors(anchors):
    """Discard anchors that predate the pod.

    On a warm run the node is already up, so the NodeClaim was created minutes
    before this pod existed. Those timestamps are real but they belong to the
    previous run, and left in they would sort to the front of the chain and
    manufacture a large negative-then-positive provisioning stage.

    Nothing that happened before the pod was created can be part of this pod's
    wait, so the rule is general -- it also protects a cold run that happens to
    pick up a stale NodeClaim.
    """
    pod_created = anchors.get("pod_created")
    if not pod_created:
        return anchors, []

    kept, dropped = {}, []
    for key, when in anchors.items():
        if key != "pod_created" and when < pod_created:
            dropped.append(key)
        else:
            kept[key] = when
    return kept, sorted(dropped)


def build_chain(anchors):
    order = {name: i for i, name in enumerate(ANCHOR_ORDER)}
    ordered = sorted(anchors.items(), key=lambda kv: (kv[1], order.get(kv[0], 99)))

    segments = []
    for (prev_key, prev_time), (key, time) in zip(ordered, ordered[1:]):
        label = SEGMENT_LABELS.get(
            (prev_key, key),
            f"{prev_key.replace('_', ' ')} to {key.replace('_', ' ')}",
        )
        segments.append(
            {
                "from": prev_key,
                "to": key,
                "label": label,
                "seconds": round((time - prev_time).total_seconds(), 1),
            }
        )
    return segments, ordered


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: stages.py <raw-dir> <out-json>", file=sys.stderr)
        return 2

    raw = pathlib.Path(sys.argv[1])
    out = pathlib.Path(sys.argv[2])

    pod = load(raw / "pod.json")
    nodeclaims = load(raw / "nodeclaims.json")
    events = load(raw / "events.json")
    node = load(raw / "node.json")

    variant = read_line(raw / "variant.txt", raw.name)
    instance_type = read_line(raw / "instance-type.txt")
    workload_image = read_line(raw / "image.txt")

    node_name = (pod.get("spec") or {}).get("nodeName")
    nodeclaim = pick_nodeclaim(nodeclaims, node_name)

    pull = analyse_pull(events, workload_image)
    anchors = collect_anchors(pod, nodeclaim, pull, node)
    anchors, pre_pod = drop_pre_pod_anchors(anchors)
    segments, ordered = build_chain(anchors)

    # Time to first token, if bench.sh ran the probe.
    ttft = load(raw / "ttft.json") or {}

    # vLLM's own view of where its startup went.
    vllm = vllm_timings(read_line(raw / "pod.log", ""))

    pod_created = anchors.get("pod_created")
    pod_ready = anchors.get("pod_ready")
    total = round((pod_ready - pod_created).total_seconds(), 1) if pod_created and pod_ready else None

    # Effective throughput. The one derived number worth having: it converts the
    # pull stage into a rate, which is comparable across images and is what makes
    # "SOCI saturates the link, sequential pull does not" a measurement rather
    # than a claim. Uses the observed pull window, not kubelet's reported figure,
    # so it covers unpack as well as download.
    # Summed, not matched on one label: a real pull window can be split in two by
    # the NodeClaim Initialized event landing inside it, and matching a single exact
    # label silently returns nothing when that happens -- dropping the throughput
    # line precisely on the runs where the pull is the whole story.
    pull_parts = [
        s["seconds"] for s in segments if s["label"].startswith("image pull + unpack")
    ]
    pull_window = sum(pull_parts) if pull_parts else None
    throughput_mb_s = None
    if pull["image_bytes"] and pull_window and pull_window > 0:
        throughput_mb_s = round((pull["image_bytes"] / 1e6) / pull_window, 1)

    facts = node_facts(node)

    record = {
        "variant": variant,
        "instance_type_requested": instance_type,
        "image": workload_image,
        "node": node_name,
        "node_facts": facts,
        "reached_ready": pod_ready is not None,
        "total_seconds": total,
        "vllm": vllm,
        "warm": bool(pre_pod),
        "anchors_dropped_as_pre_pod": pre_pod,
        "ttft_seconds": ttft.get("ttft_seconds"),
        "ttft_total_seconds": ttft.get("total_seconds"),
        "ttft_tokens": ttft.get("tokens_received"),
        "ttft_error": ttft.get("error"),
        "submit_to_first_token_seconds": (
            round(total + ttft["ttft_seconds"], 1)
            if total is not None and ttft.get("ttft_seconds") is not None
            else None
        ),
        "image_already_present": pull["image_already_present"],
        "pull_window_seconds": pull_window,
        "effective_throughput_mb_s": throughput_mb_s,
        "reported_pull_seconds": pull["reported_pull_seconds"],
        "reported_pull_including_waiting_seconds": pull["reported_pull_including_waiting_seconds"],
        "image_bytes": pull["image_bytes"],
        "segments": segments,
        "anchors": {k: v.isoformat() for k, v in ordered},
    }

    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(record, indent=2) + "\n")

    # ------------------------------------------------------------------ print
    print()
    print(f"  variant            {variant}")
    print(f"  instance       {facts['instance_type'] or instance_type}"
          f"{'  ' + facts['zone'] if facts['zone'] else ''}"
          f"{'  ' + facts['capacity_type'] if facts['capacity_type'] else ''}")
    print(f"  node           {node_name or '-'}")
    if facts["os_image"]:
        print(f"  node OS        {facts['os_image']}")
    if facts["container_runtime"]:
        print(f"  runtime        {facts['container_runtime']}")
    if pull["image_bytes"]:
        print(f"  image size     {pull['image_bytes'] / 1e9:.2f} GB (compressed, per kubelet)")
    if pull["image_already_present"]:
        print("  image pull     none -- already present on the node at first use")
    if pre_pod:
        print(f"  warm run       node already existed; dropped {len(pre_pod)} "
              f"pre-pod anchor(s): {', '.join(pre_pod)}")
    if not record["reached_ready"]:
        print("  WARNING        pod never reached Ready; stages below are partial")
    print()

    width = max((len(s["label"]) for s in segments), default=10)
    for segment in segments:
        print(f"  {segment['label']:<{width}}  {segment['seconds']:>7.1f}s")
    print(f"  {'-' * width}  {'-' * 8}")
    if total is not None:
        print(f"  {'start to Ready':<{width}}  {total:>7.1f}s")

    if throughput_mb_s is not None:
        print()
        print(
            f"  effective image throughput  {throughput_mb_s:.0f} MB/s "
            f"({pull['image_bytes'] / 1e9:.2f} GB over {pull_window:.0f}s, download + unpack)"
        )

    if pull["reported_pull_seconds"] is not None:
        including = pull["reported_pull_including_waiting_seconds"]
        line = f"  kubelet reports the pull itself at {pull['reported_pull_seconds']:.1f}s"
        if including is not None:
            line += f" ({including:.1f}s including waiting)"
        print(line)

    if vllm:
        print()
        print("  inside 'workload becomes Ready', per vLLM's own log:")
        for key, label in (
            ("weight_load_seconds", "reading the weights"),
            ("model_load_seconds", "model load total"),
            ("torch_compile_seconds", "torch.compile"),
            ("engine_init_seconds", "engine init, kv cache, warmup"),
            ("graph_capture_seconds", "CUDA graph capture"),
        ):
            if key in vllm:
                print(f"    {label:<32} {vllm[key]:>7.2f}s")
        if "weight_load_seconds" in vllm and total:
            share = (vllm["weight_load_seconds"] / total) * 100
            print(
                f"    reading the weights is {share:.1f}% of start to Ready -- "
                "a faster loader can only move this part"
            )

    if ttft.get("ttft_seconds") is not None:
        print()
        print(f"  time to first token after Ready  {ttft['ttft_seconds']:.2f}s")
        if record["submit_to_first_token_seconds"] is not None:
            print(
                f"  submit to first token            "
                f"{record['submit_to_first_token_seconds']:.1f}s"
                "   <- the number a user would feel"
            )
    elif ttft.get("error"):
        print()
        print(f"  time to first token: probe failed -- {ttft['error']}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
