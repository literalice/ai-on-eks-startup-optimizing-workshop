#!/usr/bin/env python3
"""Compare every run in results/ and write the readout.

Prints a stage table and stacked bars to the terminal for the live session, and
writes results/report.md so the numbers leave the room in a form that can be
pasted into a document.

If a variant was run more than once the latest run wins, and the earlier ones are
listed underneath so a re-run that contradicts the first is visible rather than
silently overwritten.

  bin/report.py                     the results/ dir next to this repo
  bin/report.py /path/to/results    somewhere else -- e.g. a participant's own run
"""

from __future__ import annotations

import json
import pathlib
import sys

VARIANT_ORDER = [
    "baseline",
    "snapshot",
    "soci",
    "automode",
    "baseline-warm",
    "snapshot-warm",
    "soci-warm",
    "automode-warm",
    "weights-s3-initcontainer",
    "weights-runai-local",
    "weights-runai-s3",
]

VARIANT_DESCRIPTIONS = {
    "baseline": "Bottlerocket as shipped, EBS data volume, sequential pull",
    "snapshot": "images pre-baked into the data volume from an EBS snapshot",
    "soci": "local NVMe + SOCI parallel pull/unpack, configured by hand",
    "automode": "EKS Auto Mode, nothing configured",
    "baseline-warm": "second pod onto the warm baseline node",
    "snapshot-warm": "second pod onto the warm snapshot node",
    "soci-warm": "second pod onto the warm SOCI node",
    "automode-warm": "second pod onto the warm Auto Mode node",
    "weights-s3-initcontainer": "weights copied S3 to disk, vLLM default safetensors loader",
    "weights-runai-local": "weights copied S3 to disk, Run:ai Model Streamer from disk",
    "weights-runai-s3": "no copy: Run:ai Model Streamer reads S3 directly",
}

# Karpenter's unavailable-offerings cache has a 3-minute TTL, so a pod waiting on a
# capacity-starved instance type sits for up to ~180s before a NodeClaim is even created.
# Flag anything over half that, which is already far outside the 1-2s a healthy decision
# takes and cannot be explained by what a variant configures.
DECISION_ANOMALY_S = 90.0

COLD_VARIANTS = ["baseline", "snapshot", "soci", "automode"]
WEIGHTS_VARIANTS = ["weights-s3-initcontainer", "weights-runai-local", "weights-runai-s3"]

# Stages collapsed into the three things a reader actually decides about.
PROVISION_SEGMENTS = {
    "Karpenter decision",
    "EC2 launch call",
    "boot + node registers",
    "node becomes Ready",
    "pod bound to node",
    "kubelet picks up pod",
}
IMAGE_SEGMENTS = {
    "image pull + unpack",
    # A real pull window can be split by the NodeClaim Initialized event landing
    # inside it. Both halves are pull time and must land in the same bucket.
    "image pull + unpack (starts)",
    "image pull + unpack (continues)",
    "init image pull",
    "workload image pull begins",
}
WORKLOAD_SEGMENTS = {
    "init container starts",
    "model weights download",
    "container start",
    "container start (image already on node)",
    "workload becomes Ready",
}


def load_results(results_dir: pathlib.Path):
    runs = {}
    extras = {}
    for path in sorted(results_dir.glob("*.json")):
        try:
            record = json.loads(path.read_text())
        except json.JSONDecodeError:
            print(f"  skipping unreadable {path.name}", file=sys.stderr)
            continue
        variant = record.get("variant", path.stem)
        record["_file"] = path.name
        if variant in runs:
            extras.setdefault(variant, []).append(runs[variant])
        runs[variant] = record
    return runs, extras


def bucket(record):
    provision = image = workload = 0.0
    for segment in record.get("segments") or []:
        label, seconds = segment["label"], segment["seconds"]
        if label in PROVISION_SEGMENTS:
            provision += seconds
        elif label in IMAGE_SEGMENTS:
            image += seconds
        elif label in WORKLOAD_SEGMENTS:
            workload += seconds
        else:
            # Unrecognised gap. Count it as provisioning rather than dropping it,
            # so the buckets still sum to the total.
            provision += seconds
    return provision, image, workload


def bars(runs, order, width=48):
    """Stacked bars, scaled to the slowest variant."""
    totals = [r["total_seconds"] for r in (runs[a] for a in order) if r.get("total_seconds")]
    if not totals:
        return []
    peak = max(totals)
    label_width = max(len(a) for a in order)
    lines = []
    for variant in order:
        record = runs[variant]
        total = record.get("total_seconds")
        if not total:
            lines.append(f"  {variant:<{label_width}}  (never reached Ready)")
            continue
        provision, image, workload = bucket(record)
        scale = width / peak
        segments = [
            ("#", provision),  # provisioning
            ("=", image),      # image
            (".", workload),   # workload
        ]
        bar = "".join(char * max(0, round(seconds * scale)) for char, seconds in segments)
        lines.append(f"  {variant:<{label_width}} |{bar:<{width}}| {total:>7.1f}s")
    return lines


def markdown(runs, order, extras):
    out = []
    out.append("# Bottlerocket startup-time workshop -- measured results")
    out.append("")
    out.append("Every variant ran cold: no node existed for that variant when the pod was submitted.")
    out.append("All variants are pinned to the same instance type, in the same VPC and subnets.")
    out.append("")

    images = {runs[a].get("image") for a in order if runs[a].get("image")}
    if images:
        out.append(f"- Image: `{', '.join(sorted(i for i in images if i))}`")
    sizes = [runs[a].get("image_bytes") for a in order if runs[a].get("image_bytes")]
    if sizes:
        out.append(f"- Compressed image size, per kubelet: {max(sizes) / 1e9:.2f} GB")
    out.append("")

    out.append("## Summary")
    out.append("")
    out.append("| Variant | What it is | Provisioning | Image | Workload | Start to Ready | Image throughput |")
    out.append("|---|---|---:|---:|---:|---:|---:|")
    for variant in order:
        record = runs[variant]
        provision, image, workload = bucket(record)
        total = record.get("total_seconds")
        total_text = f"**{total:.0f}s**" if total else "did not become Ready"
        note = " (no pull)" if record.get("image_already_present") else ""
        throughput = record.get("effective_throughput_mb_s")
        throughput_text = f"{throughput:.0f} MB/s" if throughput else "—"
        out.append(
            f"| `{variant}` | {VARIANT_DESCRIPTIONS.get(variant, '')} | {provision:.0f}s | "
            f"{image:.0f}s{note} | {workload:.0f}s | {total_text} | {throughput_text} |"
        )
    out.append("")
    out.append(
        "Image throughput is the compressed image size over the observed pull window, "
        "so it covers download *and* unpack. It is the number to compare when the "
        "image differs from ours."
    )
    out.append("")

    # ------------------------------------------------- was the comparison fair
    out.append("## What actually launched")
    out.append("")
    out.append(
        "The comparison only means something if the variants ran on the same hardware in "
        "the same place. This is read back off the nodes rather than assumed."
    )
    out.append("")
    out.append("| Variant | Instance | Zone | Capacity | Node OS | Runtime |")
    out.append("|---|---|---|---|---|---|")
    for variant in order:
        facts = runs[variant].get("node_facts") or {}
        out.append(
            f"| `{variant}` | {facts.get('instance_type') or '—'} | {facts.get('zone') or '—'} | "
            f"{facts.get('capacity_type') or '—'} | {facts.get('os_image') or '—'} | "
            f"{facts.get('container_runtime') or '—'} |"
        )
    out.append("")

    launched_types = {
        (runs[a].get("node_facts") or {}).get("instance_type")
        for a in order
        if (runs[a].get("node_facts") or {}).get("instance_type")
    }
    if len(launched_types) > 1:
        out.append(
            f"> **The variants did not all get the same instance type** "
            f"({', '.join(sorted(launched_types))}). Treat the comparison as invalid "
            f"until they are re-run on one type."
        )
        out.append("")

    launched_zones = {
        (runs[a].get("node_facts") or {}).get("zone")
        for a in order
        if (runs[a].get("node_facts") or {}).get("zone")
    }
    if len(launched_zones) > 1:
        out.append(
            f"> Variants landed in more than one Availability Zone "
            f"({', '.join(sorted(launched_zones))}). Same-region pull paths, so the "
            f"effect should be small, but it is a difference the table does not control for."
        )
        out.append("")

    # A long "Karpenter decision" segment is scheduling latency, not something the variant
    # configures, and it lands entirely in the total. The usual cause is Karpenter waiting
    # out its unavailable-offerings cache after an InsufficientInstanceCapacity error: that
    # cache has a 3-minute TTL, so a delay near 180s is that and not the variant.
    slow_decisions = []
    for variant in order:
        for seg in runs[variant].get("segments", []):
            if seg["label"] == "Karpenter decision" and seg["seconds"] >= DECISION_ANOMALY_S:
                slow_decisions.append((variant, seg["seconds"]))
    if slow_decisions:
        listed = ", ".join(f"`{v}` {s:.0f}s" for v, s in slow_decisions)
        out.append(
            f"> **Scheduling latency is inflating some totals.** Karpenter took "
            f"{DECISION_ANOMALY_S:.0f}s or more to create a NodeClaim after the pod "
            f"appeared, for: {listed}. That time is before any instance is launched, so it "
            f"is not attributable to what the variant configures. The usual cause is "
            f"Karpenter waiting out its unavailable-offerings cache after an "
            f"`InsufficientInstanceCapacity` error, which has a 3-minute TTL. Compare the "
            f"image column rather than the total, or re-run when capacity for the instance "
            f"type has recovered."
        )
        out.append("")

    # ------------------------------------------------------- warm scale-out
    warm_pairs = [(a, f"{a}-warm") for a in COLD_VARIANTS if f"{a}-warm" in runs and a in runs]
    if warm_pairs:
        out.append("## Cold first pod vs warm scale-out")
        out.append("")
        out.append(
            "The cold runs measure the first pod on a new node. Most scale-out events "
            "do not look like that -- they land on a node that is already running with "
            "the image already in its cache. Both numbers matter, and the gap between "
            "them is how much of your startup cost is a once-per-node cost."
        )
        out.append("")
        out.append("| Variant | Cold first pod | Warm second pod | Once-per-node cost |")
        out.append("|---|---:|---:|---:|")
        for cold, warm in warm_pairs:
            cold_total = runs[cold].get("total_seconds")
            warm_total = runs[warm].get("total_seconds")
            if not cold_total or not warm_total:
                continue
            out.append(
                f"| `{cold}` | {cold_total:.0f}s | {warm_total:.0f}s | "
                f"{cold_total - warm_total:.0f}s |"
            )
        out.append("")
        out.append(
            "> Read the last column as the part that a pre-warmed or longer-lived node "
            "would avoid entirely. Where it dominates, the mechanisms in this workshop "
            "matter; where it does not, the answer is capacity policy rather than image "
            "delivery."
        )
        out.append("")

    # --------------------------------------------- weights: how they load
    weights_present = [a for a in WEIGHTS_VARIANTS if a in runs]
    if weights_present:
        out.append("## Phase 2 -- how the weights reach GPU memory")
        out.append("")
        out.append(
            "Same node, same model, same bytes. Only the loader differs. "
            "`Ready` here means vLLM answers `/health`; time to first token is measured "
            "after that, because Ready is not the same as able to serve."
        )
        out.append("")
        out.append(
            "| Variant | What it does | Start to Ready | TTFT after Ready | Submit to first token |"
        )
        out.append("|---|---|---:|---:|---:|")
        for variant in weights_present:
            record = runs[variant]
            total = record.get("total_seconds")
            ttft = record.get("ttft_seconds")
            end_to_end = record.get("submit_to_first_token_seconds")
            out.append(
                f"| `{variant.replace('weights-', '')}` | {VARIANT_DESCRIPTIONS.get(variant, '')} | "
                f"{f'{total:.0f}s' if total else '—'} | "
                f"{f'{ttft:.2f}s' if ttft else '—'} | "
                f"{f'**{end_to_end:.0f}s**' if end_to_end else '—'} |"
            )
        out.append("")

        copy_based = runs.get("weights-s3-initcontainer", {}).get("total_seconds")
        direct = runs.get("weights-runai-s3", {}).get("total_seconds")
        if copy_based and direct:
            delta = copy_based - direct
            out.append(
                f"> Streaming from S3 directly removes the init container, and with it "
                f"the copy that kubelet serialises ahead of the workload image pull. "
                f"Measured difference: **{delta:.0f}s** "
                f"({(delta / copy_based) * 100:.0f}% of the copy-based path)."
            )
            out.append("")
        out.append(
            "The three variants isolate two separate things. `s3-initcontainer` to "
            "`runai-local` changes **only the loader** -- identical bytes on identical "
            "disk -- so that difference is what concurrent tensor streaming is worth. "
            "`runai-local` to `runai-s3` changes **only the delivery**, removing the "
            "copy step altogether. Reporting them separately keeps the two effects from "
            "being credited to each other."
        )
        out.append("")

    baseline = runs.get("baseline", {}).get("total_seconds")
    if baseline:
        out.append("## Against the cold baseline")
        out.append("")
        out.append("| Variant | Start to Ready | vs baseline |")
        out.append("|---|---:|---:|")
        for variant in order:
            total = runs[variant].get("total_seconds")
            if not total:
                continue
            delta = total - baseline
            pct = (delta / baseline) * 100
            sign = "+" if delta > 0 else ""
            out.append(f"| `{variant}` | {total:.0f}s | {sign}{delta:.0f}s ({sign}{pct:.0f}%) |")
        out.append("")

    out.append("## Full stage breakdown")
    out.append("")
    for variant in order:
        record = runs[variant]
        out.append(f"### `{variant}`")
        out.append("")
        out.append(f"{VARIANT_DESCRIPTIONS.get(variant, '')}")
        out.append("")
        if record.get("image_already_present"):
            out.append("Image was already on the node at first use, so there is no pull stage.")
            out.append("")
        out.append("| Stage | Seconds |")
        out.append("|---|---:|")
        for segment in record.get("segments") or []:
            out.append(f"| {segment['label']} | {segment['seconds']:.1f} |")
        total = record.get("total_seconds")
        if total:
            out.append(f"| **start to Ready** | **{total:.1f}** |")
        out.append("")
        reported = record.get("reported_pull_seconds")
        if reported is not None:
            including = record.get("reported_pull_including_waiting_seconds")
            out.append(
                f"kubelet reports the pull itself at {reported:.1f}s"
                + (f" ({including:.1f}s including waiting)." if including is not None else ".")
            )
            out.append("")

    if extras:
        out.append("## Superseded runs")
        out.append("")
        out.append("Earlier runs of the same variant, kept so a re-run that disagrees is visible.")
        out.append("")
        out.append("| Variant | File | Start to Ready |")
        out.append("|---|---|---:|")
        for variant, records in extras.items():
            for record in records:
                total = record.get("total_seconds")
                out.append(
                    f"| `{variant}` | `{record['_file']}` | "
                    f"{f'{total:.0f}s' if total else 'did not become Ready'} |"
                )
        out.append("")

    out.append("## What this does not tell you")
    out.append("")
    out.append(
        "- One run per variant. Pull times vary with registry and network conditions, "
        "so treat a difference under roughly 10% as noise until it is repeated."
    )
    out.append(
        "- The snapshot has to be rebuilt whenever the image changes. The "
        "build time is not in this table, and it is the cost that decides whether "
        "the mechanism is worth adopting."
    )
    out.append(
        "- automode ran on a different cluster from the other three, because Auto Mode and "
        "self-managed Karpenter cannot share the karpenter.sh CRDs. Same VPC, "
        "subnets and instance type, so the pull path is identical, but it is not "
        "the same control plane."
    )
    out.append("")
    return "\n".join(out)


def main() -> int:
    root = pathlib.Path(__file__).resolve().parent.parent
    results_dir = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else root / "results"

    if not results_dir.is_dir():
        print(f"no such results directory: {results_dir}", file=sys.stderr)
        return 1

    runs, extras = load_results(results_dir)
    if not runs:
        print("no results yet -- run bin/bench.sh <variant> first", file=sys.stderr)
        return 1

    order = [a for a in VARIANT_ORDER if a in runs] + [a for a in runs if a not in VARIANT_ORDER]

    print()
    print("  provisioning: #   image: =   workload: .")
    print()
    for line in bars(runs, order):
        print(line)
    print()

    width = max(len(a) for a in order)
    print(
        f"  {'variant':<{width}} {'provision':>10} {'image':>8} {'workload':>9} "
        f"{'total':>8} {'MB/s':>7} {'TTFT':>7}"
    )
    print(
        f"  {'-' * width} {'-' * 10} {'-' * 8} {'-' * 9} {'-' * 8} {'-' * 7} {'-' * 7}"
    )
    for variant in order:
        record = runs[variant]
        provision, image, workload = bucket(record)
        total = record.get("total_seconds")
        total_text = f"{total:.0f}s" if total else "n/a"
        throughput = record.get("effective_throughput_mb_s")
        throughput_text = f"{throughput:.0f}" if throughput else "-"
        ttft = record.get("ttft_seconds")
        ttft_text = f"{ttft:.2f}s" if ttft else "-"
        print(
            f"  {variant:<{width}} {provision:>9.0f}s {image:>7.0f}s {workload:>8.0f}s "
            f"{total_text:>8} {throughput_text:>7} {ttft_text:>7}"
        )
    print()

    # Warm vs cold, on screen -- the pair a reader is most likely to want.
    for cold in COLD_VARIANTS:
        warm = f"{cold}-warm"
        if cold in runs and warm in runs:
            cold_total = runs[cold].get("total_seconds")
            warm_total = runs[warm].get("total_seconds")
            if cold_total and warm_total:
                print(
                    f"  {cold}: cold {cold_total:.0f}s -> warm {warm_total:.0f}s "
                    f"(once-per-node cost {cold_total - warm_total:.0f}s)"
                )
    if any(f"{c}-warm" in runs for c in COLD_VARIANTS):
        print()

    # Flag an unfair comparison on screen, not only in the file.
    launched = {
        variant: (runs[variant].get("node_facts") or {}).get("instance_type")
        for variant in order
    }
    distinct = {v for v in launched.values() if v}
    if len(distinct) > 1:
        print(f"  !! variants ran on different instance types: {', '.join(sorted(distinct))}")
        print("     the comparison is not valid until they are re-run on one type")
        print()

    report_path = results_dir / "report.md"
    report_path.write_text(markdown(runs, order, extras))
    try:
        shown = report_path.relative_to(root)
    except ValueError:
        shown = report_path
    print(f"  wrote {shown}")
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
