#!/usr/bin/env bash
#
# Show what configuration makes one variant different, before running it.
#
#   bin/show_config.sh snapshot
#
# A timing figure on its own does not show how the result was produced. This prints
# the field, the resource it belongs to, and the reason for it, so a participant can
# apply the same configuration themselves.
#
# The diff is taken against the baseline variant and comments are stripped, so what
# prints is only the configuration that actually differs. It reads the real rendered
# manifests, not a copy, so it cannot drift from what is applied.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"

# shellcheck source=../config.env
source "${ROOT}/config.env"

VARIANT="${1:-}"
RENDERED="${ROOT}/manifests/rendered"

BOLD=$'\033[1m'; DIM=$'\033[2m'; CYAN=$'\033[36m'
GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; RESET=$'\033[0m'

usage() {
  echo "usage: show_config.sh <baseline|snapshot|soci|automode|weights>" >&2
  exit 2
}
[[ -z "${VARIANT}" ]] && usage

heading() { printf '\n%s%s%s\n' "${BOLD}${CYAN}" "$1" "${RESET}"; }
why()     { printf '  %s%s%s\n' "${GREEN}" "$1" "${RESET}"; }
warn()    { printf '  %s%s%s\n' "${RED}" "$1" "${RESET}"; }
plain()   { printf '  %s\n' "$1"; }

# Strip comments and blank lines so the diff shows configuration, not prose.
strip() { grep -vE '^\s*#|^\s*$' "$1"; }

# Drop lines that differ only because the variant is called something else: resource
# names, labels and tags. Without this filter those lines outnumber the one or two lines
# of configuration that differ.
#
# Matched on the key, not the value. Matching the value would also remove
# `snapshotter = "soci"`, which is the setting the soci variant exists to demonstrate.
drop_identity() {
  grep -vE '^[+-][[:space:]]*(name|workshop-variant):[[:space:]]*"?[a-z-]+"?[[:space:]]*$'
}

show_diff() {
  local base="$1" variant="$2" label="$3"
  if [[ ! -f "${base}" || ! -f "${variant}" ]]; then
    warn "rendered manifests not found -- run bin/prep.sh first"
    return 1
  fi
  heading "${label}"
  printf '%s' "${DIM}"
  printf '  %s\n' "--- $(basename "${base}")"
  printf '  %s\n' "+++ $(basename "${variant}")"
  printf '%s' "${RESET}"
  diff -U0 <(strip "${base}") <(strip "${variant}") \
    | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' \
    | drop_identity \
    | sed -e "s/^-/  ${RED}-/" -e "s/^+/  ${GREEN}+/" -e "s/$/${RESET}/"
  printf '  %s(lines differing only by the variant name are omitted)%s\n' "${DIM}" "${RESET}"
}

BASE="${RENDERED}/10-baseline.yaml"

case "${VARIANT}" in
  baseline)
    heading "baseline -- nothing is configured"
    plain ""
    why "Bottlerocket with its default settings. Two EBS volumes: a small control"
    why "volume, and a data volume that holds container images and logs. containerd"
    why "pulls layers one at a time with its default snapshotter."
    plain ""
    plain "The node class is worth reading because the later variants modify it:"
    plain ""
    grep -A12 'blockDeviceMappings:' "${BASE}" 2>/dev/null | grep -vE '^\s*#' | sed 's/^/    /'
    plain ""
    why "deviceName /dev/xvda -> Bottlerocket's control volume (OS)"
    why "deviceName /dev/xvdb -> the data volume: container images live here"
    plain ""
    plain "The other variants change how that second volume is used."
    ;;

  snapshot)
    show_diff "${BASE}" "${RENDERED}/11-snapshot.yaml" \
      "snapshot -- one field added to the data volume"
    plain ""
    why "snapshotID on /dev/xvdb"
    plain "    Restores the data volume from an EBS snapshot that already contains the"
    plain "    image layers. containerd finds them locally, so there is nothing to pull."
    plain ""
    why "encrypted: true is not set here"
    plain "    A volume restored from a snapshot inherits the snapshot's encryption."
    plain "    The snapshot came from the baseline's encrypted volume, so this volume is"
    plain "    encrypted. Setting the field as well has no additional effect."
    plain ""
    warn "Note what is NOT here: instanceStorePolicy."
    plain "    This variant needs the images on the volume restored from the snapshot."
    plain "    Adding instanceStorePolicy moves container storage to local NVMe, and the"
    plain "    restored volume is then unused."
    plain ""
    plain "  Where the snapshot comes from:"
    plain "    bin/bench.sh baseline        # leaves a node with the image pulled"
    plain "    snapshot/snapshot-from-node.sh     # snapshots that node's /dev/xvdb"
    plain ""
    if [[ -f "${ROOT}/results/snapshot-id.txt" ]]; then
      why "current snapshot: $(tr -d '[:space:]' < "${ROOT}/results/snapshot-id.txt")"
    else
      warn "no snapshot yet -- results/snapshot-id.txt is missing"
    fi
    ;;

  soci)
    show_diff "${BASE}" "${RENDERED}/12-soci.yaml" \
      "soci -- two additions"
    plain ""
    why "instanceStorePolicy: RAID0"
    plain "    Karpenter builds a RAID0 array from the instance's NVMe disks and moves"
    plain "    /var/lib/containerd, /var/lib/kubelet, /var/log/pods and SOCI's data"
    plain "    directory onto it. Without this, SOCI still works but buffers layers on"
    plain "    EBS while downloading, and the EBS throughput then limits the result."
    plain ""
    why "userData -- Bottlerocket reads TOML settings here, not a shell script"
    plain "    snapshotter = \"soci\"            switches containerd's snapshotter"
    plain "    pull-mode = \"parallel-pull-unpack\"   selects the parallel mode"
    plain "    max-concurrent-downloads-per-image   HTTP connections per layer"
    plain "    max-concurrent-unpacks-per-image     layers decompressed at once"
    plain ""
    warn "Requires Bottlerocket >= 1.44.0. On an earlier version the snapshotter"
    warn "setting is ignored without an error: the node boots, the pod runs, and"
    warn "this variant measures the same thing as the baseline. bin/prep.sh checks it."
    plain ""
    plain "  The image is unmodified. No SOCI index to build, no registry change,"
    plain "  no build-pipeline change."
    ;;

  automode)
    show_diff "${RENDERED}/12-soci.yaml" "${RENDERED}/13-automode.yaml" \
      "automode -- compared with soci"
    plain ""
    why "Absent: instanceStorePolicy, the userData block, blockDeviceMappings."
    plain "    On a GPU instance with local NVMe, EKS Auto Mode formats the NVMe, puts"
    plain "    container storage on it, and pulls and unpacks in parallel."
    plain ""
    why "ephemeralStorage.size is below the instance's NVMe capacity."
    plain "    Per the Auto Mode docs, a value below NVMe capacity causes Auto Mode to"
    plain "    attach a 20 GiB EBS volume and put ephemeral data on the NVMe. A value at"
    plain "    or above NVMe capacity makes the NVMe available to the workload instead."
    plain ""
    warn "Two things Auto Mode cannot do:"
    warn "  1. No snapshotID. ephemeralStorage is size/iops/throughput/kmsKeyID only,"
    warn "     so the snapshot mechanism is unavailable here."
    warn "  2. The SOCI settings are not exposed. The service defaults apply."
    plain ""
    plain "  Also note the API group differs: eks.amazonaws.com/v1 NodeClass, not"
    plain "  karpenter.k8s.aws/v1 EC2NodeClass. Different controller, same NodePool CRD."
    ;;

  weights)
    heading "Phase 2 -- the three loader variants are three command lines"
    plain ""
    plain "  Same pod spec, same node, same model. Only the vLLM arguments differ."
    plain ""
    why "1. s3-initcontainer  -- copy to disk, then vLLM's default loader"
    plain "     initContainer:  aws s3 cp s3://BUCKET/PREFIX/ /models/ --recursive"
    plain "     vllm:           --model /models"
    plain ""
    why "2. runai-local       -- same copy, different loader"
    plain "     initContainer:  unchanged"
    plain "     vllm:           --model /models \\"
    plain "                     --load-format runai_streamer \\"
    plain "                     --model-loader-extra-config '{\"concurrency\":${RUNAI_CONCURRENCY_LOCAL}}'"
    plain ""
    why "3. runai-s3          -- no copy at all"
    plain "     initContainer:  REMOVED"
    plain "     vllm:           --model s3://BUCKET/PREFIX \\"
    plain "                     --load-format runai_streamer \\"
    plain "                     --model-loader-extra-config '{\"concurrency\":${RUNAI_CONCURRENCY_S3}}'"
    plain ""
    plain "  1 to 2 changes the loader only. 2 to 3 changes the delivery only."
    plain "  Reported separately to show which change affected the total."
    plain ""
    why "Credentials: serviceAccountName: bench, bound to an IAM role by EKS Pod"
    why "Identity in terraform/main.tf."
    warn "  Not the node role. Karpenter sets the IMDS hop limit to 1, so a container"
    warn "  cannot reach instance metadata and the AWS SDK reports"
    warn "  'Unable to locate credentials'. The hop limit prevents pods from using"
    warn "  node permissions, so it is left as it is."
    plain ""
    plain "  runai-streamer already ships in the AWS vLLM DLC base image:"
    plain "    bin/check_runai.sh"
    ;;

  *) usage ;;
esac

printf '\n%s' "${YELLOW}"
printf '  %s\n' "Apply and measure:"
printf '%s' "${RESET}"
case "${VARIANT}" in
  weights) printf '    bin/bench.sh weights <variant>\n' ;;
  *)       printf '    bin/prep.sh          # applies the node class and node pool\n'
           printf '    bin/bench.sh %s\n' "${VARIANT}" ;;
esac
printf '  %sThen prove the setting took effect:%s\n' "${YELLOW}" "${RESET}"
printf '    bin/verify_config.sh %s\n\n' "${VARIANT}"
