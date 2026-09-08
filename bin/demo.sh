#!/usr/bin/env bash
#
# The narrated live demo. This is what gets recorded.
#
# Prints English commentary between the real commands, so the recording explains
# itself without a voice track. Every number on screen comes from the actual run --
# the narration is text, the measurements are not.
#
#   bin/demo.sh            run the whole thing
#   bin/demo.sh --quick    skip the cold baseline (variant A), for a shorter recording
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

say "One point at the start. The image and instance type here are ours, so the absolute figures will differ from yours. What can be compared is which stage accounts for most of the time, and how each mechanism changes it. Your own figures come from running these steps in your account."

say "Four variants. Same pod spec, same instance type, same VPC and subnets, same container image. The only thing that differs between them is how the container image reaches the node."

cat <<'ARMS'
    A  baseline    Bottlerocket as shipped -- EBS data volume, sequential pull
    B  snapshot    data volume restored from an EBS snapshot holding the layers
    C  soci        container storage on local NVMe + SOCI parallel pull/unpack
    D  automode    EKS Auto Mode: local NVMe and parallel pull, set up for you
ARMS
sleep "${BEAT}"

say "Two constraints before any figures appear. The snapshot and SOCI variants cannot both be applied to the same node, because both govern the volume Bottlerocket uses for container images. And the snapshot mechanism is not available on Auto Mode, because its NodeClass has no snapshotID field."

note "Every run below starts cold: the variant's node is deleted first, so nothing is cached."
note "Stages are computed from timestamps Kubernetes already records, so they sum to the total exactly. No time is unattributed."

################################################################################
title "The environment"

say "Two clusters, one shared VPC. Self-managed Karpenter carries variants A, B and C; EKS Auto Mode carries variant D. Two clusters rather than one because both Karpenters own the same CRDs."

run kubectl --context "${KARPENTER_CLUSTER}" get nodes -o wide
run kubectl --context "${AUTOMODE_CLUSTER}" get nodes -o wide

say "No NVIDIA device plugin is installed in either cluster. The Bottlerocket NVIDIA AMI contains the driver, the container toolkit and the device plugin. The readiness probe runs nvidia-smi inside the container, so a pod reaching Ready means the GPU is available to the container."

run kubectl --context "${KARPENTER_CLUSTER}" get nodepools

################################################################################
if [[ "${QUICK}" == false ]]; then
  title "Step 1 -- where the time goes"

  say "The baseline variant first: Bottlerocket exactly as it ships. This is the number everything else is measured against. Watch the step timings appear as each step completes."

  say "The provisioning steps will print quickly. The output then stops after the image pull starts, and resumes when the pull finishes. That interval is what this workshop measures."

  say "The configuration first. This is the baseline, so nothing is configured. The node class is still worth reading, because the later variants modify it."

  run "${HERE}/show_config.sh" baseline

  run "${HERE}/bench.sh" baseline

  say "Now the check that this was a clean baseline: no userData, no instanceStorePolicy, no snapshotID, and container storage on EBS rather than NVMe. With those confirmed, an improvement in a later variant can be attributed to what that variant added."

  run "${HERE}/verify_config.sh" baseline

  say "The node was ready in about half a minute. The image pull took roughly three times as long as all the other stages combined. So the difference between the variants will come from how the image reaches the node, rather than from how the node is provisioned."

  note "Compare the effective throughput line with the instance's network bandwidth of up to 25 Gbps. The pull was not limited by the network."
fi

################################################################################
title "Step 2 and 3 -- two image mechanisms that cannot be combined"

say "The snapshot variant: the image layers were baked into an EBS snapshot ahead of time, and the node restores its data volume from that snapshot. There is nothing to pull, because the layers are already on the disk when the node boots."

say "Here is the entire configuration change for variant B. One field."

run "${HERE}/show_config.sh" snapshot

run "${HERE}/bench.sh" snapshot

say "There is no pull stage. kubelet reports the image as already present on the machine, so the registry was not contacted."

say "The next check does not use the timing figures. It reads the volume the node booted with and compares its snapshot ID with the one we built, then confirms kubelet reported the image as already present."

run "${HERE}/verify_config.sh" snapshot

say "Building that snapshot took three to five minutes, and it has to be rebuilt whenever the image changes. That is the figure to weigh against this improvement in the last section."

say "The SOCI variant now: instead of pre-baking, we move container storage onto the instance's local NVMe and switch the snapshotter to SOCI in parallel pull/unpack mode. SOCI opens several connections per layer and unpacks several layers at once. The image is completely unmodified -- no index to build, no change to your build pipeline."

say "The SOCI variant is two changes, and this is the whole of it -- a policy line, and Bottlerocket settings in TOML. Note that Bottlerocket takes settings, not a shell script; that is the most common thing to get wrong coming from Amazon Linux."

run "${HERE}/show_config.sh" soci

run "${HERE}/bench.sh" soci

say "The proof for variant C. Container storage moved to NVMe -- visible in the node's ephemeral-storage capacity, which now reflects the instance store rather than the EBS volume. And the settings reached the node. Note what this does not prove: that SOCI ran. Bottlerocket has no shell to check from, so the behavioural evidence is the throughput figure."

run "${HERE}/verify_config.sh" soci

say "The baseline and SOCI variants differ by one mechanism, with the same provisioner, operating system and instance type. That makes the difference between them attributable to that mechanism."

note "Compare the throughput figures for variants A and C. The difference is the effect of parallel pull and unpack."

################################################################################
title "Step 4 -- what Auto Mode does without being configured"

say "Before the numbers, look at the configuration. This is the SOCI node class against variant D's. Count what is present on the left and absent on the right."

run "${HERE}/show_config.sh" automode

say "The instanceStorePolicy is gone. The six lines of Bottlerocket settings are gone. The block device mappings are gone. And yet on a GPU instance with local NVMe, Auto Mode formats the NVMe, puts container storage on it, and pulls and unpacks in parallel. That is the SOCI variant's configuration, done by the service."

run "${HERE}/bench.sh" automode

say "And the proof that we did not quietly configure it after all: no userData, no instanceStorePolicy, no block device mappings -- yet the node still reports the NVMe."

run "${HERE}/verify_config.sh" automode

say "Two things Auto Mode cannot do, and both belong on the record. There is no snapshotID on its NodeClass, so the snapshot mechanism is unavailable -- if pre-baked images are the right answer for a workload, that workload does not go on Auto Mode. And the SOCI tuning knobs from variant C are not exposed; you get the service defaults."

################################################################################
title "Step 5 -- cold first pod versus warm scale-out"

say "Everything so far measured the first pod onto a brand new node. Most scale-out events do not look like that. They land on a node that is already running, with the image already in its cache. Same variant, node kept this time."

run "${HERE}/bench.sh" soci --warm

say "Almost all of the cold measurement was incurred once per node rather than once per pod. This matters for reading variant B: a snapshot affects the first pod on a node and does not affect this one."

say "If most of your pods are scheduled onto nodes that are already running, the three mechanisms we just measured affect a small part of your total startup time. Node capacity policy would affect more of it: keeping nodes for longer, or provisioning them before they are needed."

note "The question this raises for you: when pods scale out, what fraction land on new nodes versus existing ones?"

################################################################################
title "Step 6 -- how the model weights reach GPU memory"

say "Once the image stops being the bottleneck, the weights become the story. Three variants, same node, same model, same bytes. Only the loader differs -- and the effect splits into two separate things, which is why there are three and not two."

cat <<'VARIANTS'
    s3-initcontainer   copy S3 to disk, then vLLM's default safetensors loader
    runai-local        same copy, but Run:ai Model Streamer reads from disk
    runai-s3           no copy at all: the streamer reads S3 directly
VARIANTS
sleep "${BEAT}"

say "First to second changes only the loader: identical bytes on identical disk. Second to third changes only the delivery. Reporting them separately keeps one effect from being credited to the other."

run "${HERE}/show_config.sh" weights

run "${HERE}/bench.sh" weights s3-initcontainer

say "The lines under workload becomes Ready come from vLLM's log. Reading the weights took a fraction of a second. Compiling and warming the engine took tens of seconds. A faster loader can only affect the first of those."

say "The same copy on the same disk, with a different loader. Run:ai Model Streamer is Apache-2.0 licensed and is included in the AWS vLLM deep learning container, so there is nothing to install."

run "${HERE}/bench.sh" weights runai-local

say "The total did not change. At this model size reading the weights was already a small part of the startup time, so a faster way of reading them had little to affect. Without the vLLM timings, this result would show only that the total did not change, without indicating why."

say "The third variant changes the delivery rather than the loader. vLLM reads from an S3 URI, so the init container is removed, and with it the copy step that kubelet runs before the workload image pull rather than alongside it."

run "${HERE}/bench.sh" weights runai-s3

say "This one reduced the total. The model load time went up, because streaming from S3 is slower per tensor than reading local disk. The reduction comes from removing the copy step. At a larger model size the loader would account for more of the time."

say "The proof for phase 2 -- which loader the pod actually started with, whether the model came from disk or straight from S3, and the timing breakdown from vLLM's own log."

run "${HERE}/verify_config.sh" weights

say "These runs also measure time to first token. A pod reaching Ready means vLLM answers its health endpoint, which does not indicate how soon it produces a token. Submit to first token covers that."

################################################################################
title "The readout"

say "All variants together. Provisioning, image, and workload, plus effective throughput and time to first token where we measured it."

run "${HERE}/report.py" "${RESULTS_DIR}"

say "What this does not tell you, stated plainly. One run per variant, so treat anything under about ten percent as noise until it repeats. The snapshot build time is not in the table, and that is the cost that decides whether it is worth adopting. And variant D ran on a different control plane, so read it as indicative rather than like-for-like."

################################################################################
title "Section 5 -- what to adopt"

cat <<'DECISION'
    Images change rarely, latency critical .... B, the snapshot
    Images change often ...................... C, SOCI on NVMe
    Neither should be your problem ........... D, Auto Mode
    Weights dominate, not layers ............. stream them from S3
    Warm-node time already dominates ......... none of these; capacity policy
DECISION
sleep "${BEAT}"

say "Two measurements determine most of this choice. How often your images change, which decides between the snapshot and SOCI variants. And how much of your startup time is incurred once per node, which decides whether any of these mechanisms affects most of it."

say "Each configuration shown here is written up in the steps directory: the YAML, which field goes in which resource, the reason for it, what happens if it is missing, and how to check it took effect. Those are the documents to follow in your own account."

run ls "${ROOT}/steps"

say "The runbook and these scripts go with you. Run the same steps in your own dev account, and the numbers that come out are the ones worth deciding on."

rule
printf '\n'
