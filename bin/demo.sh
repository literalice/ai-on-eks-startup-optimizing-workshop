#!/usr/bin/env bash
#
# The narrated live demo. This is what gets recorded.
#
# Prints English commentary between the real commands, so the recording explains
# itself without a voice track. Every number on screen comes from the actual run --
# the narration is text, the measurements are not.
#
#   bin/demo.sh            run the whole thing
#   bin/demo.sh --quick    skip the cold baseline (arm A), for a shorter recording
#
# Prerequisites, all done before recording (see README):
#   terraform apply, snapshot/build-snapshot.sh, snapshot/stage-model.sh, bin/prep.sh
#
# Recorded with bin/record.sh, which wraps this in asciinema and renders to mp4.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"

# shellcheck source=../config.env
source "${ROOT}/config.env"

# Matches bench.sh, so a rehearsal reads back its own scratch results.
RESULTS_DIR="${RESULTS_DIR:-${ROOT}/results}"

QUICK=false
[[ "${1:-}" == "--quick" ]] && QUICK=true

# Pacing. Long enough to read a paragraph before the next command starts.
BEAT="${DEMO_BEAT:-4}"
SHORT_BEAT="${DEMO_SHORT_BEAT:-2}"

BOLD=$'\033[1m'
DIM=$'\033[2m'
CYAN=$'\033[36m'
YELLOW=$'\033[33m'
GREEN=$'\033[32m'
RESET=$'\033[0m'

rule() { printf '%s%s%s\n' "${DIM}" "$(printf '─%.0s' $(seq 1 78))" "${RESET}"; }

title() {
  printf '\n\n'
  rule
  printf '%s  %s%s\n' "${BOLD}${CYAN}" "$1" "${RESET}"
  rule
  printf '\n'
  sleep "${SHORT_BEAT}"
}

say() {
  # Wrap narration at 78 columns so it reads well in the video.
  printf '%s' "${YELLOW}"
  printf '%s\n' "$1" | fold -s -w 78 | sed 's/^/  /'
  printf '%s\n' "${RESET}"
  sleep "${BEAT}"
}

note() {
  printf '%s' "${GREEN}"
  printf '%s\n' "$1" | fold -s -w 78 | sed 's/^/  → /'
  printf '%s\n' "${RESET}"
  sleep "${SHORT_BEAT}"
}

run() {
  # Echo the command the way a person would type it. Absolute paths are correct but
  # they wrap and swamp the line in a recording, so strip the repo root off.
  local shown=()
  for arg in "$@"; do
    shown+=("${arg/#${ROOT}\//}")
  done
  printf '%s$ %s%s\n\n' "${BOLD}" "${shown[*]}" "${RESET}"
  sleep 1
  "$@"
  printf '\n'
}

################################################################################
title "Bottlerocket startup-time workshop"

say "The problem we are here to solve: GPU inference pods take too long to become ready. Rather than assume where the time goes, we are going to measure it, and then measure three different ways of making it shorter."

say "One thing to say at the start. The image and instance type here are ours, not yours, so the absolute numbers will not match what you see. What transfers is the shape -- which stage dominates, and what each mechanism does to it. Your own numbers come from running these same steps in your account."

say "Four arms. Same pod spec, same instance type, same VPC and subnets, same container image. The only thing that differs between them is how the container image reaches the node."

cat <<'ARMS'
    A  baseline    Bottlerocket as shipped -- EBS data volume, sequential pull
    B  snapshot    data volume restored from an EBS snapshot holding the layers
    C  soci        container storage on local NVMe + SOCI parallel pull/unpack
    D  automode    EKS Auto Mode: local NVMe and parallel pull, set up for you
ARMS
sleep "${BEAT}"

say "Two things worth saying before any numbers appear. B and C are mutually exclusive -- they compete for the same volume, so you pick one. And D cannot do B's mechanism at all, because Auto Mode's NodeClass has no snapshotID field."

note "Every run below starts cold: the arm's node is deleted first, so nothing is cached."
note "Stages are computed from timestamps Kubernetes already records, so they sum to the total exactly. No time is unattributed."

################################################################################
title "The environment"

say "Two clusters, one shared VPC. Self-managed Karpenter carries arms A, B and C; EKS Auto Mode carries arm D. Two clusters rather than one because both Karpenters own the same CRDs."

run kubectl --context "${KARPENTER_CLUSTER}" get nodes -o wide
run kubectl --context "${AUTOMODE_CLUSTER}" get nodes -o wide

say "Note what is not installed anywhere in either cluster: an NVIDIA device plugin. The Bottlerocket NVIDIA AMI already contains the driver, the container toolkit and the device plugin. Our readiness probe runs nvidia-smi inside the container, so Ready proves the GPU is genuinely usable."

run kubectl --context "${KARPENTER_CLUSTER}" get nodepools

################################################################################
if [[ "${QUICK}" == false ]]; then
  title "Item 1 -- where the time actually goes"

  say "Arm A first: Bottlerocket exactly as it ships. This is the number everything else is measured against. Watch the step timings appear as each step completes."

  say "The interesting moment is coming up. The provisioning steps will scroll past quickly, and then one line will sit there on its own for a while. That line is the whole point of this workshop."

  run "${HERE}/bench.sh" arm-a-baseline

  say "There it is. The node was ready in about half a minute. The image pull then took roughly three times as long as everything else put together. That matters because it means the fix is not in how you provision nodes -- it is in how the image gets to them."

  note "Look at the effective throughput line, and compare it to what this instance's network can actually do. It is not close."
fi

################################################################################
title "Item 2 -- two ways to deal with the image, and you only get one"

say "Arm B: the image layers were baked into an EBS snapshot ahead of time, and the node restores its data volume from that snapshot. There is nothing to pull, because the layers are already on the disk when the node boots."

run "${HERE}/bench.sh" arm-b-snapshot

say "No pull stage at all -- kubelet reports the image as already present on the machine. It never contacted the registry."

say "That speed has a price, and I would rather state it than have you find it. Building that snapshot took about fifteen minutes, and it has to be rebuilt every time the image changes. Hold that thought for the last section."

say "Arm C now: instead of pre-baking, we move container storage onto the instance's local NVMe and switch the snapshotter to SOCI in parallel pull/unpack mode. SOCI opens several connections per layer and unpacks several layers at once. The image is completely unmodified -- no index to build, no change to your build pipeline."

run "${HERE}/bench.sh" arm-c-soci

say "This is the honest comparison in the whole workshop: A against C. Same provisioner, same operating system, same instance type. One mechanism changed."

note "Compare the throughput figures for A and C. That difference is what parallelism bought."

################################################################################
title "Item 3 -- what Auto Mode does without being asked"

say "Before the numbers, look at the configuration. This is arm C's node class against arm D's. Count what is present on the left and absent on the right."

run diff -u "${ROOT}/manifests/rendered/12-arm-c-soci.yaml" "${ROOT}/manifests/rendered/13-arm-d-automode.yaml"

say "The instanceStorePolicy is gone. The six lines of Bottlerocket settings are gone. The block device mappings are gone. And yet on a GPU instance with local NVMe, Auto Mode formats the NVMe, puts container storage on it, and pulls and unpacks in parallel. That is arm C's configuration, done by the service."

run "${HERE}/bench.sh" arm-d-automode

say "Two things Auto Mode cannot do, and both belong on the record. There is no snapshotID on its NodeClass, so arm B's mechanism is unavailable -- if pre-baked images are the right answer for a workload, that workload does not go on Auto Mode. And the SOCI tuning knobs from arm C are not exposed; you get the service defaults."

################################################################################
title "Cold first pod versus warm scale-out"

say "Everything so far measured the first pod onto a brand new node. Most scale-out events do not look like that. They land on a node that is already running, with the image already in its cache. Same arm, node kept this time."

run "${HERE}/bench.sh" arm-c-soci --warm

say "Almost all of the cold number was a once-per-node cost, not a once-per-pod cost. I am showing you this for one specific reason: it stops the snapshot being over-credited. A snapshot helps the cold pod and does nothing at all for the warm one."

say "It also reframes the whole question. If most of your scale-out lands on nodes that are already running, then none of the three mechanisms we just measured is where your time goes, and the answer is capacity policy instead -- keeping nodes longer, or warming them before you need them."

note "The question this raises for you: when pods scale out, what fraction land on new nodes versus existing ones?"

################################################################################
title "Item 4 -- how the model weights reach GPU memory"

say "Once the image stops being the bottleneck, the weights become the story. Three variants, same node, same model, same bytes. Only the loader differs -- and the effect splits into two separate things, which is why there are three and not two."

cat <<'VARIANTS'
    s3-initcontainer   copy S3 to disk, then vLLM's default safetensors loader
    runai-local        same copy, but Run:ai Model Streamer reads from disk
    runai-s3           no copy at all: the streamer reads S3 directly
VARIANTS
sleep "${BEAT}"

say "First to second changes only the loader: identical bytes on identical disk. Second to third changes only the delivery. Reporting them separately keeps one effect from being credited to the other."

run "${HERE}/bench.sh" weights s3-initcontainer

say "Look at the breakdown under 'workload becomes Ready'. Those lines come from vLLM's own log, and they are the reason this section has three variants instead of two. Reading the weights is a fraction of a second. Compiling and warming the engine is tens of seconds. A faster loader can only touch the fraction of a second."

say "Same copy, same disk, different loader. Run:ai Model Streamer is Apache-2.0 open source and already ships in the AWS vLLM deep learning container -- nothing to install, no licence to buy. Watch what it does to the total."

run "${HERE}/bench.sh" weights runai-local

say "Essentially nothing, and that is the useful result. At this model size the weights were never the bottleneck, so a faster way of reading them has nothing to win. Had we shown only a before and after total, we would have concluded the tool does not work. The vLLM timings show it was never given anything to do."

say "The third variant changes the delivery instead of the loader. vLLM points straight at an S3 URI, so the init container disappears completely -- and with it the copy step, which kubelet runs strictly before the workload image pull rather than alongside it."

run "${HERE}/bench.sh" weights runai-s3

say "That one does move. Note where the gain comes from: not from loading faster -- streaming from S3 is actually a little slower per tensor than reading local disk -- but from deleting a step. On a larger model the loader would matter too; at this size, only the delivery does."

say "One more number in these runs: time to first token. Ready only means vLLM answers its health endpoint. It does not mean the server will produce a token promptly. Submit-to-first-token is the number a user would actually feel."

################################################################################
title "The readout"

say "All arms together. Provisioning, image, and workload, plus effective throughput and time to first token where we measured it."

run "${HERE}/report.py" "${RESULTS_DIR}"

say "What this does not tell you, stated plainly. One run per arm, so treat anything under about ten percent as noise until it repeats. Arm B's snapshot build time is not in the table, and that is the cost that decides whether it is worth adopting. And arm D ran on a different control plane, so read it as indicative rather than like-for-like."

################################################################################
title "Item 5 -- what to adopt"

cat <<'DECISION'
    Images change rarely, latency critical .... B, the snapshot
    Images change often ...................... C, SOCI on NVMe
    Neither should be your problem ........... D, Auto Mode
    Weights dominate, not layers ............. stream them from S3
    Warm-node time already dominates ......... none of these; capacity policy
DECISION
sleep "${BEAT}"

say "Two questions decide most of this, and neither is a matter of opinion. How often do your images change -- that is the fork between B and C. And how much of your startup cost is once-per-node -- that is whether any of this is the right thing to optimise at all."

say "The runbook and these scripts go with you. Run the same steps in your own dev account, and the numbers that come out are the ones worth deciding on."

rule
printf '\n'
