#!/usr/bin/env bash
#
# Phase 2 and 3 pre-work: put the model weights in S3, so the workload streams them at startup
# instead of carrying them in the image.
#
#   snapshot/stage-model.sh
#
# The download and the upload run in a Kubernetes Job on the cluster, not here. That keeps the
# only requirement on this machine to kubectl and the AWS CLI: no local Python, no `hf`
# install, and no multi-gigabyte round trip through whoever is running the workshop. The Job
# also uses the S3 Gateway endpoint, so its upload does not go through the NAT gateway.
#
# Qwen2.5-1.5B-Instruct by default: ungated, about 3 GB, and it loads in well under a minute on
# an L4. Large enough that the download stage is visible in the table, small enough that a
# session does not stall on it. Set MODEL_HF_REPO in config.env to something closer to your own
# weights for a more representative load stage.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"

# shellcheck source=../config.env
source "${ROOT}/config.env"
# shellcheck source=../bin/discover.sh
source "${ROOT}/bin/discover.sh"

JOB_TIMEOUT="${JOB_TIMEOUT:-1800}"

if ! resolve_bucket; then
  echo "no weights bucket found." >&2
  echo "" >&2
  echo "Nothing set MODEL_BUCKET, no bucket carries the Purpose tag with the" >&2
  echo "${NAME_PREFIX}-models- prefix, and ${ROOT}/terraform has no model_bucket output." >&2
  echo "Set MODEL_BUCKET in config.env to the bucket the Job should write to." >&2
  exit 1
fi
echo "==> bucket ${MODEL_BUCKET} (from ${BUCKET_SOURCE})"

if ! kubectl --context "${KARPENTER_CLUSTER}" -n bench get serviceaccount stage-model >/dev/null 2>&1; then
  echo "the stage-model service account does not exist in namespace bench." >&2
  echo "Run bin/prep.sh first. The Job writes to the bucket through that account's EKS Pod" >&2
  echo "Identity binding, which is separate from the read-only one the measured pods use." >&2
  exit 1
fi

RENDERED="${ROOT}/manifests/rendered"
mkdir -p "${RENDERED}"
MANIFEST="${RENDERED}/stage-model-job.yaml"

sed \
  -e "s|@MODEL_HF_REPO@|${MODEL_HF_REPO}|g" \
  -e "s|@MODEL_PREFIX@|${MODEL_PREFIX}|g" \
  -e "s|@MODEL_BUCKET@|${MODEL_BUCKET}|g" \
  -e "s|@REGION@|${REGION}|g" \
  "${ROOT}/manifests/stage-model-job.yaml" > "${MANIFEST}"

echo "==> model      ${MODEL_HF_REPO}"
echo "==> bucket     s3://${MODEL_BUCKET}/${MODEL_PREFIX}/"
echo "==> cluster    ${KARPENTER_CLUSTER}"

# A completed Job of the same name would block the apply, and its TTL may not have expired.
kubectl --context "${KARPENTER_CLUSTER}" -n bench delete job stage-model \
  --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1 || true

echo "==> submitting the Job"
kubectl --context "${KARPENTER_CLUSTER}" apply -f "${MANIFEST}" >/dev/null

echo "==> following it. The download and upload take a few minutes."
echo

# Follow the logs rather than waiting silently. --pod-running-timeout covers the wait for the
# pod to be scheduled and the image to be pulled.
set +e
kubectl --context "${KARPENTER_CLUSTER}" -n bench logs -f job/stage-model \
  --pod-running-timeout=5m 2>&1 | sed 's/^/    /'
set -e

echo
echo "==> waiting for the Job to report completion"
if ! kubectl --context "${KARPENTER_CLUSTER}" -n bench wait --for=condition=complete \
     job/stage-model --timeout="${JOB_TIMEOUT}s" 2>/dev/null; then
  echo
  echo "the Job did not complete. Its pod's state and events:" >&2
  kubectl --context "${KARPENTER_CLUSTER}" -n bench describe job stage-model >&2
  exit 1
fi

echo
echo "==> objects in the bucket"
aws s3 ls "s3://${MODEL_BUCKET}/${MODEL_PREFIX}/" --region "${REGION}" --human-readable \
  | sed 's/^/    /'

echo
echo "==> done. Phase 2 and phase 3 are now runnable."
