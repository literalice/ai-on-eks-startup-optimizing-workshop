#!/usr/bin/env bash
#
# Show what configuration makes one arm different, before running it.
#
#   bin/show_config.sh arm-b-snapshot
#
# Exists because a timing number on its own does not teach anyone anything. A
# participant needs to see the field, the resource it goes in, and why it is there --
# otherwise the workshop demonstrates that a mechanism works without showing how to
# use it.
#
# The diff is taken against the baseline arm and comments are stripped, so what
# prints is only the configuration that actually differs. It reads the real rendered
# manifests, not a copy, so it cannot drift from what is applied.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"

# shellcheck source=../config.env
source "${ROOT}/config.env"

ARM="${1:-}"
RENDERED="${ROOT}/manifests/rendered"

BOLD=$'\033[1m'; DIM=$'\033[2m'; CYAN=$'\033[36m'
GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; RESET=$'\033[0m'

usage() {
  echo "usage: show_config.sh <arm-a-baseline|arm-b-snapshot|arm-c-soci|arm-d-automode|weights>" >&2
  exit 2
}
[[ -z "${ARM}" ]] && usage

heading() { printf '\n%s%s%s\n' "${BOLD}${CYAN}" "$1" "${RESET}"; }
why()     { printf '  %s%s%s\n' "${GREEN}" "$1" "${RESET}"; }
warn()    { printf '  %s%s%s\n' "${RED}" "$1" "${RESET}"; }
plain()   { printf '  %s\n' "$1"; }

# Strip comments and blank lines so the diff shows configuration, not prose.
strip() { grep -vE '^\s*#|^\s*$' "$1"; }

# Drop lines that differ only because the arm is called something else -- resource
# names, labels, tags. Without this the rename noise buries the one or two lines
# that are the actual lesson, which defeats the purpose of showing a diff at all.
drop_identity() {
  grep -vE 'arm-a-baseline|arm-b-snapshot|arm-c-soci|arm-d-automode'
}

show_diff() {
  local base="$1" arm="$2" label="$3"
  if [[ ! -f "${base}" || ! -f "${arm}" ]]; then
    warn "rendered manifests not found -- run bin/prep.sh first"
    return 1
  fi
  heading "${label}"
  printf '%s' "${DIM}"
  printf '  %s\n' "--- $(basename "${base}")"
  printf '  %s\n' "+++ $(basename "${arm}")"
  printf '%s' "${RESET}"
  diff -U0 <(strip "${base}") <(strip "${arm}") \
    | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' \
    | drop_identity \
    | sed -e "s/^-/  ${RED}-/" -e "s/^+/  ${GREEN}+/" -e "s/$/${RESET}/"
  printf '  %s(lines differing only by the arm name are omitted)%s\n' "${DIM}" "${RESET}"
}

BASE="${RENDERED}/10-arm-a-baseline.yaml"

case "${ARM}" in
  arm-a-baseline)
    heading "Arm A -- the baseline. Nothing is configured."
    plain ""
    why "This is Bottlerocket exactly as it ships. Two EBS volumes: a small control"
    why "volume, and a data volume that holds container images and logs. containerd"
    why "pulls layers one at a time with its default snapshotter."
    plain ""
    plain "The only thing worth pointing at is the shape of the node class:"
    plain ""
    grep -A12 'blockDeviceMappings:' "${BASE}" 2>/dev/null | grep -vE '^\s*#' | sed 's/^/    /'
    plain ""
    why "deviceName /dev/xvda -> Bottlerocket's control volume (OS)"
    why "deviceName /dev/xvdb -> the data volume: container images live here"
    plain ""
    plain "Everything the other arms do is a change to how that second volume is used."
    ;;

  arm-b-snapshot)
    show_diff "${BASE}" "${RENDERED}/11-arm-b-snapshot.yaml" \
      "Arm B -- one field added to the data volume"
    plain ""
    why "snapshotID on /dev/xvdb"
    plain "    Restores the data volume from an EBS snapshot that already contains the"
    plain "    image layers. containerd finds them locally, so there is nothing to pull."
    plain ""
    why "encrypted: true disappears, and that is not a downgrade"
    plain "    A volume restored from a snapshot inherits the snapshot's encryption."
    plain "    The snapshot came from arm A's encrypted volume, so this one is encrypted"
    plain "    too. Setting the flag as well is allowed but redundant."
    plain ""
    warn "Note what is NOT here: instanceStorePolicy."
    plain "    That is the whole point of the exclusivity. Arm B needs the images on the"
    plain "    volume restored from the snapshot. Adding instanceStorePolicy would move"
    plain "    container storage to local NVMe and the snapshot would be bypassed."
    plain ""
    plain "  Where the snapshot comes from:"
    plain "    bin/bench.sh arm-a-baseline        # leaves a node with the image pulled"
    plain "    snapshot/snapshot-from-node.sh     # snapshots that node's /dev/xvdb"
    plain ""
    if [[ -f "${ROOT}/results/snapshot-id.txt" ]]; then
      why "current snapshot: $(tr -d '[:space:]' < "${ROOT}/results/snapshot-id.txt")"
    else
      warn "no snapshot yet -- results/snapshot-id.txt is missing"
    fi
    ;;

  arm-c-soci)
    show_diff "${BASE}" "${RENDERED}/12-arm-c-soci.yaml" \
      "Arm C -- two changes, and they work together"
    plain ""
    why "instanceStorePolicy: RAID0"
    plain "    Karpenter builds a RAID0 array from the instance's NVMe disks and moves"
    plain "    /var/lib/containerd, /var/lib/kubelet, /var/log/pods and SOCI's data"
    plain "    directory onto it. Without this, SOCI still works but buffers layers on"
    plain "    EBS while downloading, which becomes the limit."
    plain ""
    why "userData -- Bottlerocket settings in TOML, not shell"
    plain "    snapshotter = \"soci\"            switches containerd's snapshotter"
    plain "    pull-mode = \"parallel-pull-unpack\"   the mode that does the work"
    plain "    max-concurrent-downloads-per-image   HTTP connections per layer"
    plain "    max-concurrent-unpacks-per-image     layers decompressed at once"
    plain ""
    warn "Requires Bottlerocket >= 1.44.0. Below that the snapshotter setting is"
    warn "silently ignored -- the node boots, the pod runs, and the arm quietly"
    warn "measures the same thing as arm A. bin/prep.sh asserts the version."
    plain ""
    plain "  The image is unmodified. No SOCI index to build, no registry change,"
    plain "  no build-pipeline change."
    ;;

  arm-d-automode)
    show_diff "${RENDERED}/12-arm-c-soci.yaml" "${RENDERED}/13-arm-d-automode.yaml" \
      "Arm D -- against arm C. Count what is absent."
    plain ""
    why "Gone: instanceStorePolicy, the userData block, blockDeviceMappings."
    plain "    On a GPU instance with local NVMe, EKS Auto Mode formats the NVMe, puts"
    plain "    container storage on it, and pulls and unpacks in parallel. That is arm"
    plain "    C's configuration, done by the service."
    plain ""
    why "ephemeralStorage.size is deliberately BELOW the instance's NVMe capacity."
    plain "    Per the Auto Mode docs that is the trigger: Auto Mode attaches a small"
    plain "    20 GiB EBS volume and puts ephemeral data on the NVMe. Set it at or above"
    plain "    NVMe capacity and Auto Mode hands the NVMe to the workload instead."
    plain ""
    warn "Two things Auto Mode cannot do:"
    warn "  1. No snapshotID. ephemeralStorage is size/iops/throughput/kmsKeyID only,"
    warn "     so arm B's mechanism is unavailable here."
    warn "  2. The SOCI tuning knobs are not exposed. You get the service defaults."
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
    plain "  1 -> 2 changes only the loader. 2 -> 3 changes only the delivery."
    plain "  Reported separately so one effect is not credited to the other."
    plain ""
    why "Credentials: serviceAccountName: bench, bound to an IAM role by EKS Pod"
    why "Identity in terraform/main.tf."
    warn "  Not the node role. Karpenter sets the IMDS hop limit to 1, so a container"
    warn "  cannot reach instance metadata at all and the AWS SDK reports"
    warn "  'Unable to locate credentials'. That default is correct -- keep it."
    plain ""
    plain "  runai-streamer already ships in the AWS vLLM DLC base image:"
    plain "    bin/check_runai.sh"
    ;;

  *) usage ;;
esac

printf '\n%s' "${YELLOW}"
printf '  %s\n' "Apply and measure:"
printf '%s' "${RESET}"
case "${ARM}" in
  weights) printf '    bin/bench.sh weights <variant>\n' ;;
  *)       printf '    bin/prep.sh          # applies the node class and node pool\n'
           printf '    bin/bench.sh %s\n' "${ARM}" ;;
esac
printf '  %sThen prove the setting took effect:%s\n' "${YELLOW}" "${RESET}"
printf '    bin/verify_config.sh %s\n\n' "${ARM}"
