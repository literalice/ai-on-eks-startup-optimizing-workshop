#!/usr/bin/env bash
#
# Return an arm to cold. Every measurement has to start with no node, or the
# image is already in the node's cache and the number is meaningless.
#
#   bin/reset.sh                 all arms
#   bin/reset.sh arm-c-soci      one arm

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"

# shellcheck source=../config.env
source "${ROOT}/config.env"

ARMS=("arm-a-baseline" "arm-b-snapshot" "arm-c-soci" "arm-d-automode")
if [[ $# -gt 0 ]]; then
  ARMS=("$@")
fi

context_for() {
  case "$1" in
    arm-d-automode) echo "${AUTOMODE_CLUSTER}" ;;
    *)              echo "${KARPENTER_CLUSTER}" ;;
  esac
}

for arm in "${ARMS[@]}"; do
  ctx="$(context_for "${arm}")"
  echo "==> resetting ${arm} on ${ctx}"

  kubectl --context "${ctx}" -n bench delete pod \
    -l "workshop-arm=${arm}" --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1 || true

  # Deleting the NodeClaim is what actually terminates the instance and discards
  # the image cache. Waiting matters: if the old node is still draining, the next
  # run may land on it.
  claims="$(kubectl --context "${ctx}" get nodeclaims \
    -l "karpenter.sh/nodepool=${arm}" -o name 2>/dev/null || true)"

  if [[ -n "${claims}" ]]; then
    echo "    deleting: ${claims//$'\n'/ }"
    # shellcheck disable=SC2086
    kubectl --context "${ctx}" delete ${claims} --wait=true --timeout=300s >/dev/null || true
  fi

  remaining="$(kubectl --context "${ctx}" get nodeclaims \
    -l "karpenter.sh/nodepool=${arm}" -o name 2>/dev/null | wc -l | tr -d ' ')"
  echo "    nodeclaims remaining: ${remaining}"
done

echo "==> cold"
