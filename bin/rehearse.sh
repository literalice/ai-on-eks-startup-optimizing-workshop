#!/usr/bin/env bash
#
# Run bin/demo.sh against fixture data, with a fake kubectl on PATH and no AWS
# calls at all. For rehearsing the narration and verifying the recording pipeline.
#
#   bin/rehearse.sh [--quick]
#
# The real bench.sh, watch_stages.py, stages.py and report.py all run unmodified --
# only kubectl is replaced. So this exercises the tooling, not a transcript of it.
#
# EVERY NUMBER PRODUCED HERE IS INVENTED. See rehearsal/make_fixtures.py. A
# rehearsal must never be handed over as a measurement; bin/record.sh puts
# REHEARSAL in the filename for that reason.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"

FIXTURES="${ROOT}/rehearsal/.fixtures"
SANDBOX="${ROOT}/rehearsal/.sandbox"

rm -rf "${FIXTURES}" "${SANDBOX}"
mkdir -p "${FIXTURES}" "${SANDBOX}"

python3 "${ROOT}/rehearsal/make_fixtures.py" "${FIXTURES}" >/dev/null

# The demo diffs the rendered node classes. Render them here with placeholder
# values so the diff in the recording is the real file difference.
mkdir -p "${ROOT}/manifests/rendered"
for f in "${ROOT}"/manifests/karpenter/*.yaml "${ROOT}"/manifests/automode/*.yaml; do
  base="$(basename "${f}")"
  if [[ ! -f "${ROOT}/manifests/rendered/${base}" ]]; then
    sed \
      -e "s|@KARPENTER_NODE_IAM_ROLE_NAME@|br-startup-karpenter|g" \
      -e "s|@GPU_INSTANCE_FAMILY@|g6|g" \
      -e "s|@GPU_INSTANCE_SIZE@|4xlarge|g" \
      -e "s|@GPU_INSTANCE_TYPE@|g6.4xlarge|g" \
      -e "s|@SNAPSHOT_ID@|snap-0f3c9a1e7b2d84c5f|g" \
      -e "s|@CLUSTER_NAME@|br-startup-karpenter|g" \
      -e "s|@NODE_IAM_ROLE@|br-startup-automode-eks-auto|g" \
      "${f}" > "${ROOT}/manifests/rendered/${base}"
  fi
done

export REHEARSAL_DIR="${FIXTURES}"
export REHEARSAL_SPEED="${REHEARSAL_SPEED:-30}"
export PATH="${ROOT}/rehearsal/fake-bin:${PATH}"

# Phase 2 refuses to run without a bucket. Nothing is read from it in a rehearsal --
# the fake kubectl serves fixtures -- but the guard is real, so satisfy it.
export MODEL_BUCKET="${MODEL_BUCKET:-rehearsal-not-a-real-bucket}"

# The production timeout is 25 minutes, which is right for a real 10 GB pull and
# useless here: a rehearsal that stalls should fail in seconds, not sit there.
export BENCH_TIMEOUT_SECONDS="${BENCH_TIMEOUT_SECONDS:-90}"

# Point the run at a scratch results dir so a rehearsal never contaminates real
# measurements sitting in results/.
export RESULTS_DIR="${SANDBOX}/results"
export RAW_DIR="${SANDBOX}/raw"
mkdir -p "${RESULTS_DIR}" "${RAW_DIR}"

# Rehearsal pacing: the narration beats dominate, so shorten them a little.
export DEMO_BEAT="${DEMO_BEAT:-3}"
export DEMO_SHORT_BEAT="${DEMO_SHORT_BEAT:-1}"

printf '\033[1;31m'
cat <<'WARNING'

  ############################################################################
  #  REHEARSAL -- fixture data, no AWS calls, every number below is invented  #
  #  For pacing the narration and checking the recording pipeline only.       #
  ############################################################################

WARNING
printf '\033[0m'
sleep 3

exec "${HERE}/demo.sh" "$@"
