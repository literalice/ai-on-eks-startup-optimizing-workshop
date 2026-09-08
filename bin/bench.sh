#!/usr/bin/env bash
#
# Run one variant and collect everything needed to break the wait into stages.
#
# Phase 1 -- how the image reaches the node:
#   bin/bench.sh baseline
#   bin/bench.sh snapshot
#   bin/bench.sh soci
#   bin/bench.sh automode
#
# Warm scale-out -- the same variant again onto the node that is already running, so
# the image is in the node's cache. This is what most scale-out events actually
# hit; the cold runs above are the first pod only.
#   bin/bench.sh soci --warm
#
# Phase 2 -- how the weights reach GPU memory (section 4). Adds a
# time-to-first-token measurement, because Ready is not the same as useful:
#   bin/bench.sh weights s3-initcontainer
#   bin/bench.sh weights runai-local
#   bin/bench.sh weights runai-s3
#
# Writes raw Kubernetes objects to raw/<name>-<ts>/ and computed stages to
# results/<name>-<ts>.json, then prints the breakdown. bin/report.py compares runs.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"

# shellcheck source=../config.env
source "${ROOT}/config.env"

# Overridable so a rehearsal cannot write fixture-derived numbers into the real
# results directory and be mistaken for a measurement later.
RESULTS_DIR="${RESULTS_DIR:-${ROOT}/results}"
RAW_DIR="${RAW_DIR:-${ROOT}/raw}"

TARGET="${1:-}"
MODE="${2:-}"

usage() {
  echo "usage:" >&2
  echo "  bench.sh <baseline|snapshot|soci|automode> [--warm]" >&2
  echo "  bench.sh weights <s3-initcontainer|runai-local|runai-s3>" >&2
  exit 2
}

[[ -z "${TARGET}" ]] && usage

WARM=false
VARIANT=""

case "${TARGET}" in
  weights)
    VARIANT="${MODE}"
    case "${VARIANT}" in
      s3-initcontainer|runai-local|runai-s3) ;;
      *) usage ;;
    esac
    CONTEXT="${KARPENTER_CLUSTER}"
    NODEPOOL="soci"
    POD="bench-weights-${VARIANT}"
    RUN_NAME="weights-${VARIANT}"
    ;;
  automode|baseline|snapshot|soci)
    [[ -n "${MODE}" && "${MODE}" != "--warm" ]] && usage
    [[ "${MODE}" == "--warm" ]] && WARM=true
    if [[ "${TARGET}" == "automode" ]]; then
      CONTEXT="${AUTOMODE_CLUSTER}"
    else
      CONTEXT="${KARPENTER_CLUSTER}"
    fi
    NODEPOOL="${TARGET}"
    if [[ "${WARM}" == true ]]; then
      POD="bench-${TARGET}-warm"
      RUN_NAME="${TARGET}-warm"
    else
      POD="bench-${TARGET}"
      RUN_NAME="${TARGET}"
    fi
    ;;
  *) usage ;;
esac

TS="$(date -u +%Y%m%dT%H%M%SZ)"
RAW="${RAW_DIR}/${RUN_NAME}-${TS}"
mkdir -p "${RAW}" "${RESULTS_DIR}"

echo "==> ${RUN_NAME} on ${CONTEXT}"

################################################################################
# Get to the right starting state
#
# Cold: delete the NodeClaim, which terminates the instance and discards its image
# cache. Warm: keep the node, delete only the pod, so the next pod lands on a node
# that already has the image. The node survives because the NodePool's
# consolidateAfter is 30m.
################################################################################
if [[ "${WARM}" == true ]]; then
  echo "==> warm run: keeping the node, deleting only the pod"

  # The variant's GPU is singular on these instance types, so the previous pod has to
  # be gone before the next one can be scheduled onto the same node.
  kubectl --context "${CONTEXT}" -n bench delete pod \
    -l "workshop-variant=${NODEPOOL}" --ignore-not-found --wait=true --timeout=180s >/dev/null 2>&1 || true

  NODE_COUNT="$(kubectl --context "${CONTEXT}" get nodeclaims \
    -l "karpenter.sh/nodepool=${NODEPOOL}" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${NODE_COUNT}" -eq 0 ]]; then
    echo "!!! no node exists for ${NODEPOOL} -- this will provision one and will NOT"
    echo "    be a warm measurement. Run the cold variant first, then --warm."
  else
    echo "    ${NODE_COUNT} node(s) still up, image should be cached"
  fi
elif [[ "${TARGET}" == "weights" ]]; then
  # Phase 2 compares loaders, not provisioning. Reuse the warm variant C node so the
  # image pull does not swamp the numbers we are trying to see.
  echo "==> reusing the variant C node if it is up (this compares loaders, not nodes)"
  kubectl --context "${CONTEXT}" -n bench delete pod \
    -l "workshop-variant=${NODEPOOL}" --ignore-not-found --wait=true --timeout=180s >/dev/null 2>&1 || true
else
  "${HERE}/reset.sh" "${NODEPOOL}"
fi

################################################################################
# Render
################################################################################
if [[ "${TARGET}" == "weights" ]]; then
  if [[ -z "${MODEL_BUCKET}" ]]; then
    echo "MODEL_BUCKET is unset in config.env -- run snapshot/stage-model.sh first" >&2
    exit 1
  fi

  # The three load paths. Only these lines differ between them.
  case "${VARIANT}" in
    s3-initcontainer)
      VLLM_MODEL_ARG="/models"
      VLLM_LOAD_ARGS=""
      USE_INIT=true
      ;;
    runai-local)
      VLLM_MODEL_ARG="/models"
      VLLM_LOAD_ARGS="--load-format runai_streamer --model-loader-extra-config '{\"concurrency\":${RUNAI_CONCURRENCY_LOCAL}}'"
      USE_INIT=true
      ;;
    runai-s3)
      VLLM_MODEL_ARG="s3://${MODEL_BUCKET}/${MODEL_PREFIX}"
      VLLM_LOAD_ARGS="--load-format runai_streamer --model-loader-extra-config '{\"concurrency\":${RUNAI_CONCURRENCY_S3}}'"
      USE_INIT=false
      ;;
  esac

  FRAGMENT="NONE"
  if [[ "${USE_INIT}" == true ]]; then
    FRAGMENT="${ROOT}/manifests/fragments/init-copy-weights.yaml"
  fi

  # Rendered by a script rather than sed: the init block is multi-line, and sed
  # cannot substitute a newline-bearing replacement portably.
  MANIFEST="${RAW}/workload.yaml"
  python3 "${HERE}/render_weights.py" \
    "${ROOT}/manifests/workload-weights.yaml" \
    "${FRAGMENT}" \
    "${MANIFEST}" \
    "VARIANT=${VARIANT}" \
    "IMAGE=${WORKLOAD_IMAGE}" \
    "MODEL_NAME=${MODEL_NAME}" \
    "MODEL_BUCKET=${MODEL_BUCKET}" \
    "MODEL_PREFIX=${MODEL_PREFIX}" \
    "REGION=${REGION}" \
    "VLLM_MODEL_ARG=${VLLM_MODEL_ARG}" \
    "VLLM_LOAD_ARGS=${VLLM_LOAD_ARGS}"
else
  MANIFEST="${RAW}/workload.yaml"
  sed \
    -e "s|@POD_NAME@|${POD}|g" \
    -e "s|@ARM_NAME@|${NODEPOOL}|g" \
    -e "s|@IMAGE@|${WORKLOAD_IMAGE}|g" \
    "${ROOT}/manifests/workload.yaml" > "${MANIFEST}"
fi

# Written before the run so the raw dir is self-describing even if interrupted.
printf '%s\n' "${RUN_NAME}" > "${RAW}/variant.txt"
printf '%s\n' "${GPU_INSTANCE_TYPE}" > "${RAW}/instance-type.txt"
printf '%s\n' "${WORKLOAD_IMAGE}" > "${RAW}/image.txt"

echo "==> submitting ${POD}"
kubectl --context "${CONTEXT}" apply -f "${MANIFEST}" >/dev/null

################################################################################
# Wait, printing each step's number as the step completes
################################################################################
set +e
python3 "${HERE}/watch_stages.py" \
  "${CONTEXT}" bench "${POD}" "${NODEPOOL}" "${BENCH_TIMEOUT_SECONDS}" "${WORKLOAD_IMAGE}"
WATCH_RC=$?
set -e

if [[ ${WATCH_RC} -ne 0 ]]; then
  echo "!!! did not reach Ready -- collecting anyway, the partial run is still evidence"
fi

################################################################################
# Time to first token (phase 2 only)
#
# Ready means /health returns 200. It does not mean the server will produce a
# token promptly, and on a cold CUDA graph it may not. Measured from inside the
# pod, so no port-forward and no assumption about curl being in the image.
################################################################################
if [[ "${TARGET}" == "weights" && ${WATCH_RC} -eq 0 ]]; then
  echo "==> measuring time to first token"
  set +e
  kubectl --context "${CONTEXT}" -n bench exec "${POD}" -c vllm -- \
    python3 /probe/first_token.py "${TTFT_MAX_TOKENS}" > "${RAW}/ttft.json" 2>"${RAW}/ttft.err"
  TTFT_RC=$?
  set -e
  if [[ ${TTFT_RC} -eq 0 ]]; then
    jq -r '"    first token in \(.ttft_seconds)s, then \(.tokens_received) tokens in \(.total_seconds)s total"' \
      "${RAW}/ttft.json" 2>/dev/null || cat "${RAW}/ttft.json"
  else
    echo "    !! probe failed:"
    sed 's/^/       /' "${RAW}/ttft.err" | head -5
    cat "${RAW}/ttft.json" 2>/dev/null | sed 's/^/       /'
  fi
fi

################################################################################
# Collect
#
# Events first: they are namespaced and roll off after an hour, so they are the
# fragile part.
################################################################################
echo "==> collecting"
kubectl --context "${CONTEXT}" -n bench get events \
  --field-selector "involvedObject.name=${POD}" -o json > "${RAW}/events.json" 2>/dev/null || echo '{}' > "${RAW}/events.json"
kubectl --context "${CONTEXT}" -n bench get pod "${POD}" -o json > "${RAW}/pod.json"
kubectl --context "${CONTEXT}" get nodeclaims \
  -l "karpenter.sh/nodepool=${NODEPOOL}" -o json > "${RAW}/nodeclaims.json"

# vLLM prints its own load timings; worth keeping next to the numbers.
kubectl --context "${CONTEXT}" -n bench logs "${POD}" --all-containers --tail=200 \
  > "${RAW}/pod.log" 2>/dev/null || true

NODE_NAME="$(jq -r '.spec.nodeName // empty' "${RAW}/pod.json")"
if [[ -n "${NODE_NAME}" ]]; then
  kubectl --context "${CONTEXT}" get node "${NODE_NAME}" -o json > "${RAW}/node.json"
else
  echo '{}' > "${RAW}/node.json"
fi

################################################################################
# Compute and print
################################################################################
python3 "${HERE}/stages.py" "${RAW}" "${RESULTS_DIR}/${RUN_NAME}-${TS}.json"

# Printed relative to the repo root where possible. Absolute paths are correct but
# they wrap over several lines in a terminal and bury the two filenames that matter.
echo
echo "==> raw     ${RAW/#${ROOT}\//}"
echo "==> result  ${RESULTS_DIR/#${ROOT}\//}/${RUN_NAME}-${TS}.json"
