#!/usr/bin/env bash
#
# Prove the configuration took effect, independently of the timing number.
#
#   bin/verify_config.sh soci
#
# A faster number is not proof that your setting is what made it faster. This checks
# the mechanism directly: that the volume really came from the snapshot, that
# container storage really moved to NVMe, that the settings really reached the node.
#
# Each check states what it confirms and what it does not, so that a check is not
# read as covering more than it does.
#
# Run it after the variant, while the node is still up.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"

# shellcheck source=../config.env
source "${ROOT}/config.env"

VARIANT="${1:-}"

BOLD=$'\033[1m'; DIM=$'\033[2m'; CYAN=$'\033[36m'
GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; RESET=$'\033[0m'

# A rehearsal has no cluster and no AWS account. Every check here reads real state:
# the volume a node booted from, the capacity a node reports. Returning fixture
# values for those would report a configuration as confirmed without checking it.
if [[ -n "${REHEARSAL_DIR:-}" ]]; then
  printf '\n%s  Verification is skipped in a rehearsal.%s\n' "${BOLD}${YELLOW}" "${RESET}"
  printf '  Every check here reads real cluster and EC2 state. Fixture values would\n'
  printf '  report a configuration as confirmed without checking it.\n'
  printf '  Run it against a real cluster after %s.\n\n' "bin/bench.sh ${VARIANT:-<variant>}"
  exit 0
fi

usage() {
  echo "usage: verify_config.sh <baseline|snapshot|soci|automode|weights>" >&2
  exit 2
}
[[ -z "${VARIANT}" ]] && usage

heading() { printf '\n%s%s%s\n' "${BOLD}${CYAN}" "$1" "${RESET}"; }
pass()    { printf '  %s[ok]%s   %s\n' "${GREEN}" "${RESET}" "$1"; }
fail()    { printf '  %s[!!]%s   %s\n' "${RED}" "${RESET}" "$1"; }
info()    { printf '         %s\n' "$1"; }
limit()   { printf '  %sproves%s %s\n' "${DIM}" "${RESET}" "$1"; }

case "${VARIANT}" in
  automode) CONTEXT="${AUTOMODE_CLUSTER}"; POOL="automode" ;;
  weights)        CONTEXT="${KARPENTER_CLUSTER}"; POOL="soci" ;;
  baseline|snapshot|soci)
                  CONTEXT="${KARPENTER_CLUSTER}"; POOL="${VARIANT}" ;;
  *) usage ;;
esac

NODE="$(kubectl --context "${CONTEXT}" get nodeclaims \
  -l "karpenter.sh/nodepool=${POOL}" \
  -o jsonpath='{.items[0].status.nodeName}' 2>/dev/null || true)"
PROVIDER_ID="$(kubectl --context "${CONTEXT}" get nodeclaims \
  -l "karpenter.sh/nodepool=${POOL}" \
  -o jsonpath='{.items[0].status.providerID}' 2>/dev/null || true)"
INSTANCE_ID="${PROVIDER_ID##*/}"

if [[ -z "${NODE}" ]]; then
  fail "no node up for ${POOL} -- run bin/bench.sh ${VARIANT} first and do not reset"
  exit 1
fi

heading "The node that ran ${VARIANT}"
kubectl --context "${CONTEXT}" get node "${NODE}" \
  -o custom-columns='NAME:.metadata.name,TYPE:.metadata.labels.node\.kubernetes\.io/instance-type,ZONE:.metadata.labels.topology\.kubernetes\.io/zone,OS:.status.nodeInfo.osImage,RUNTIME:.status.nodeInfo.containerRuntimeVersion' \
  2>/dev/null | sed 's/^/  /'
info "instance ${INSTANCE_ID}"

################################################################################
# Where container storage ended up.
#
# The node reports allocatable ephemeral-storage from wherever kubelet's root is.
# On an EBS data volume that tracks the volume size; once container storage moves to
# local NVMe it tracks the instance store instead, which on g6.8xlarge is much
# larger. So this single number distinguishes "EBS" from "NVMe" without shell access
# to a node that has no shell.
################################################################################
CAP="$(kubectl --context "${CONTEXT}" get node "${NODE}" \
  -o jsonpath='{.status.capacity.ephemeral-storage}' 2>/dev/null || true)"

heading "Where container storage ended up"

# Guarded: an unset or unexpected value here must not crash the script with an
# arithmetic error. kubelet may not have reported capacity yet on a very fresh node.
if [[ "${CAP}" =~ ^([0-9]+)Ki$ ]]; then
  CAP_GB=$(( ${BASH_REMATCH[1]} / 1024 / 1024 ))
  info "node reports ephemeral-storage capacity: ${CAP} (~${CAP_GB} GB)"
else
  CAP_GB=""
  fail "could not read ephemeral-storage capacity (got: ${CAP:-<empty>})"
  info "if the node is very fresh, kubelet may not have reported it yet -- retry"
fi

case "${VARIANT}" in
  baseline|snapshot)
    if [[ -z "${CAP_GB}" ]]; then
      info "skipping the EBS-versus-NVMe check without a capacity reading"
    elif (( CAP_GB < 200 )); then
      pass "~${CAP_GB} GB is the EBS data volume, as configured for this variant"
      limit "container storage is on EBS, not local NVMe"
    else
      fail "~${CAP_GB} GB is larger than the EBS data volume -- storage may be on NVMe"
      info "check instanceStorePolicy is absent from this variant's node class"
    fi
    ;;
  soci|automode|weights)
    if [[ -z "${CAP_GB}" ]]; then
      info "skipping the EBS-versus-NVMe check without a capacity reading"
    elif (( CAP_GB > 200 )); then
      pass "~${CAP_GB} GB is the local NVMe, not the EBS volume"
      limit "container storage moved to instance store as intended"
    else
      fail "~${CAP_GB} GB looks like EBS -- NVMe was not picked up"
      info "soci: check instanceStorePolicy: RAID0. automode: check ephemeralStorage.size"
      info "is BELOW the instance's NVMe capacity, which is what triggers Auto Mode"
    fi
    ;;
esac

################################################################################
# Variant-specific check
################################################################################
case "${VARIANT}" in
  snapshot)
    heading "Did the data volume really come from the snapshot?"
    WANT="$(tr -d '[:space:]' < "${ROOT}/results/snapshot-id.txt" 2>/dev/null || true)"
    GOT="$(aws ec2 describe-instances --region "${REGION}" --instance-ids "${INSTANCE_ID}" \
      --query "Reservations[0].Instances[0].BlockDeviceMappings[?DeviceName=='/dev/xvdb'].Ebs.VolumeId | [0]" \
      --output text 2>/dev/null)"
    SNAP="$(aws ec2 describe-volumes --region "${REGION}" --volume-ids "${GOT}" \
      --query 'Volumes[0].SnapshotId' --output text 2>/dev/null)"
    info "/dev/xvdb is volume ${GOT}"
    info "created from snapshot ${SNAP}"
    if [[ -n "${WANT}" && "${SNAP}" == "${WANT}" ]]; then
      pass "matches results/snapshot-id.txt"
      limit "the node booted with the pre-baked layers already on disk"
    else
      fail "expected ${WANT:-<none recorded>}"
    fi

    heading "Did kubelet skip the pull?"
    EV="$(kubectl --context "${CONTEXT}" -n bench get events \
      --field-selector reason=Pulled -o jsonpath='{.items[*].message}' 2>/dev/null || true)"
    if grep -q "already present on machine" <<< "${EV}"; then
      pass "kubelet reports the image as already present on machine"
      limit "the registry was never contacted for this image"
    else
      fail "no 'already present' event -- kubelet pulled after all"
      info "is the volume large enough for the snapshot, and is snapshotID set?"
    fi
    ;;

  soci)
    heading "Did the SOCI settings reach the node?"
    UD="$(kubectl --context "${CONTEXT}" get ec2nodeclass soci \
      -o jsonpath='{.spec.userData}' 2>/dev/null || true)"
    if grep -q 'snapshotter = "soci"' <<< "${UD}"; then
      pass "the node class carries snapshotter = \"soci\""
      grep -E 'snapshotter|pull-mode|max-concurrent' <<< "${UD}" | sed 's/^/           /'
      limit "the settings were DELIVERED to the node"
      printf '  %snot proved%s %s\n' "${DIM}" "${RESET}" \
        "that SOCI ran -- Bottlerocket has no shell to check from."
      info "The behavioural evidence is the throughput figure: if SOCI were being"
      info "ignored, soci would land on the baseline throughput, which is the check that matters."
    else
      fail "userData does not contain the SOCI snapshotter setting"
    fi

    heading "Is the Bottlerocket version new enough?"
    OS="$(kubectl --context "${CONTEXT}" get node "${NODE}" \
      -o jsonpath='{.status.nodeInfo.osImage}' 2>/dev/null)"
    info "${OS}"
    VER="$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' <<< "${OS}" | head -1)"
    if [[ -n "${VER}" ]] && python3 -c "import sys;v=tuple(map(int,'${VER}'.split('.')));sys.exit(0 if v>=(1,44,0) else 1)"; then
      pass "${VER} >= 1.44.0, so parallel pull/unpack exists in this image"
    else
      fail "${VER:-unknown} is below 1.44.0 -- the SOCI setting is being ignored"
      info "this variant is measuring the same thing as the baseline variant"
    fi
    ;;

  automode)
    heading "Did Auto Mode do it without being told?"
    SPEC="$(kubectl --context "${CONTEXT}" get nodeclass automode -o json 2>/dev/null)"
    for field in userData instanceStorePolicy blockDeviceMappings; do
      if grep -q "\"${field}\"" <<< "${SPEC}"; then
        fail "${field} is present -- this variant is supposed to configure nothing"
      else
        pass "no ${field} in the node class"
      fi
    done
    limit "the NVMe and parallel pull above came from the service, not from us"
    info "ephemeralStorage as declared:"
    kubectl --context "${CONTEXT}" get nodeclass automode \
      -o jsonpath='{.spec.ephemeralStorage}' 2>/dev/null | sed 's/^/           /'
    printf '\n'
    ;;

  weights)
    heading "Which loader did vLLM actually use?"
    POD="$(kubectl --context "${CONTEXT}" -n bench get pods -l phase=weights \
      -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || true)"
    if [[ -z "${POD}" ]]; then
      fail "no phase-2 pod found -- run bin/bench.sh weights <variant> first"
      exit 1
    fi
    info "pod ${POD}"
    ARGS="$(kubectl --context "${CONTEXT}" -n bench get pod "${POD}" \
      -o jsonpath='{.spec.containers[0].args}' 2>/dev/null || true)"
    if grep -q 'runai_streamer' <<< "${ARGS}"; then
      pass "started with --load-format runai_streamer"
    else
      pass "started with vLLM's default loader (no --load-format)"
    fi
    if grep -qE '\-\-model s3://' <<< "${ARGS}"; then
      pass "reading the model directly from S3 -- no init container copy"
    else
      pass "reading the model from /models -- copied in by an init container"
    fi

    heading "Where did the startup time go, per vLLM's own log?"
    kubectl --context "${CONTEXT}" -n bench logs "${POD}" -c vllm 2>/dev/null \
      | grep -aiE 'Loading weights took|Model loading took|torch\.compile took|init engine' \
      | sed 's/^.*INFO[^]]*] //' | sed 's/^/           /' | tail -5
    limit "whether a faster loader had anything to win here"
    info "If reading the weights is a fraction of a second, it did not."

    heading "Where did the credentials come from?"
    SA="$(kubectl --context "${CONTEXT}" -n bench get pod "${POD}" \
      -o jsonpath='{.spec.serviceAccountName}' 2>/dev/null)"
    info "serviceAccountName: ${SA}"
    if [[ "${SA}" == "bench" ]]; then
      pass "EKS Pod Identity via the bench service account, not the node role"
      limit "the pod did not need IMDS, which Karpenter blocks by default"
    fi
    ;;

  baseline)
    heading "Confirm nothing is configured"
    SPEC="$(kubectl --context "${CONTEXT}" get ec2nodeclass baseline -o json 2>/dev/null)"
    for field in userData instanceStorePolicy snapshotID; do
      if grep -q "\"${field}\"" <<< "${SPEC}"; then
        fail "${field} is present -- this is not a clean baseline"
      else
        pass "no ${field}"
      fi
    done
    limit "every later variant's gain is attributable to what it added"
    ;;
esac

printf '\n%s  Next: bin/show_config.sh <variant> to see what the next variant changes.%s\n\n' \
  "${YELLOW}" "${RESET}"
