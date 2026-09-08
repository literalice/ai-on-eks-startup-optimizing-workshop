#!/usr/bin/env bash
#
# Render the manifests with the values Terraform produced and apply them to the
# right cluster. Idempotent -- safe to re-run.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"

# shellcheck source=../config.env
source "${ROOT}/config.env"

RENDERED="${ROOT}/manifests/rendered"
mkdir -p "${RENDERED}" "${ROOT}/results" "${ROOT}/raw"

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing dependency: $1" >&2; exit 1; }; }
need aws
need kubectl
need jq
need python3
need terraform

echo "==> reading terraform outputs"
KARPENTER_NODE_IAM_ROLE_NAME="$(terraform -chdir="${ROOT}/terraform" output -raw karpenter_node_iam_role_name)"
MODEL_BUCKET_TF="$(terraform -chdir="${ROOT}/terraform" output -raw model_bucket)"
echo "    karpenter node role : ${KARPENTER_NODE_IAM_ROLE_NAME}"
echo "    model bucket        : ${MODEL_BUCKET_TF}"

if [[ -z "${MODEL_BUCKET}" ]]; then
  echo "    NOTE: MODEL_BUCKET is empty in config.env. Set it to ${MODEL_BUCKET_TF} before phase 2."
fi

echo "==> kubeconfig"
aws eks update-kubeconfig --region "${REGION}" --name "${KARPENTER_CLUSTER}" --alias "${KARPENTER_CLUSTER}" >/dev/null
aws eks update-kubeconfig --region "${REGION}" --name "${AUTOMODE_CLUSTER}" --alias "${AUTOMODE_CLUSTER}" >/dev/null

################################################################################
# Assert the Bottlerocket AMI is new enough for SOCI.
#
# SOCI parallel pull/unpack landed in Bottlerocket 1.44.0. If arm C silently runs
# on something older, the snapshotter setting is ignored and arm C measures the
# same thing as arm A -- a failure mode that looks like "SOCI does not help".
################################################################################
echo "==> checking Bottlerocket version"
K8S_VERSION="$(aws eks describe-cluster --region "${REGION}" --name "${KARPENTER_CLUSTER}" \
  --query 'cluster.version' --output text)"

# image_version, not image_name. The NVIDIA variant publishes only image_id and
# image_version under .../latest/ -- asking for image_name returns ParameterNotFound,
# which would degrade this assertion to a shrug exactly when it matters.
BR_VERSION="$(aws ssm get-parameter \
  --region "${REGION}" \
  --name "/aws/service/bottlerocket/aws-k8s-${K8S_VERSION}-nvidia/x86_64/latest/image_version" \
  --query 'Parameter.Value' --output text 2>/dev/null || echo "unknown")"
BR_AMI_ID="$(aws ssm get-parameter \
  --region "${REGION}" \
  --name "/aws/service/bottlerocket/aws-k8s-${K8S_VERSION}-nvidia/x86_64/latest/image_id" \
  --query 'Parameter.Value' --output text 2>/dev/null || echo "unknown")"
echo "    kubernetes ${K8S_VERSION}, bottlerocket nvidia ${BR_VERSION} (${BR_AMI_ID})"

# assert_br_version.py reads a version out of an AMI name, so hand it a string of
# that shape rather than a bare version.
python3 "${HERE}/assert_br_version.py" "bottlerocket-v${BR_VERSION}" 1.44.0

################################################################################
# Arms A, B, C on the Karpenter cluster
################################################################################
SNAPSHOT_ID=""
if [[ -f "${ROOT}/results/snapshot-id.txt" ]]; then
  SNAPSHOT_ID="$(tr -d '[:space:]' < "${ROOT}/results/snapshot-id.txt")"
fi

# Placeholders in the manifests are delimited (@TOKEN@) rather than bare, so a
# substitution cannot accidentally rewrite prose in a comment, and a short token
# cannot match inside a longer one.
render() {
  local src="$1" dst="$2"
  sed \
    -e "s|@KARPENTER_NODE_IAM_ROLE_NAME@|${KARPENTER_NODE_IAM_ROLE_NAME}|g" \
    -e "s|@GPU_INSTANCE_FAMILY@|${GPU_INSTANCE_TYPE%%.*}|g" \
    -e "s|@GPU_INSTANCE_SIZE@|${GPU_INSTANCE_TYPE##*.}|g" \
    -e "s|@GPU_INSTANCE_TYPE@|${GPU_INSTANCE_TYPE}|g" \
    -e "s|@SNAPSHOT_ID@|${SNAPSHOT_ID}|g" \
    -e "s|@CLUSTER_NAME@|${3}|g" \
    "${src}" > "${dst}"
}

echo "==> rendering + applying arms A/B/C to ${KARPENTER_CLUSTER}"
for f in "${ROOT}"/manifests/karpenter/*.yaml; do
  base="$(basename "${f}")"
  if [[ "${base}" == *arm-b-snapshot* && -z "${SNAPSHOT_ID}" ]]; then
    echo "    skipping ${base}: no snapshot yet. Run snapshot/build-snapshot.sh first."
    continue
  fi
  render "${f}" "${RENDERED}/${base}" "${KARPENTER_CLUSTER}"
  kubectl --context "${KARPENTER_CLUSTER}" apply -f "${RENDERED}/${base}"
done

kubectl --context "${KARPENTER_CLUSTER}" create namespace bench \
  --dry-run=client -o yaml | kubectl --context "${KARPENTER_CLUSTER}" apply -f -

# The phase 2 pods read S3 through this service account, which Terraform binds to an
# IAM role with EKS Pod Identity.
kubectl --context "${KARPENTER_CLUSTER}" -n bench create serviceaccount bench \
  --dry-run=client -o yaml | kubectl --context "${KARPENTER_CLUSTER}" -n bench apply -f -

# The time-to-first-token probe runs inside the workload pod. Loaded from the file
# rather than duplicated into a manifest, so there is one copy to maintain.
echo "==> loading the time-to-first-token probe"
kubectl --context "${KARPENTER_CLUSTER}" -n bench create configmap ttft-probe \
  --from-file="first_token.py=${HERE}/first_token.py" \
  --dry-run=client -o yaml | kubectl --context "${KARPENTER_CLUSTER}" -n bench apply -f -

################################################################################
# Arm D on the Auto Mode cluster
#
# The built-in "default" NodeClass is read-only, so the custom NodeClass has to
# reuse its node IAM role. Read it off the cluster rather than plumbing it
# through Terraform -- this is the method the EKS docs give.
################################################################################
echo "==> rendering + applying arm D to ${AUTOMODE_CLUSTER}"
AUTOMODE_NODE_ROLE="$(kubectl --context "${AUTOMODE_CLUSTER}" get nodeclass default -o jsonpath='{.spec.role}')"
echo "    auto mode node role : ${AUTOMODE_NODE_ROLE}"

for f in "${ROOT}"/manifests/automode/*.yaml; do
  base="$(basename "${f}")"
  render "${f}" "${RENDERED}/${base}" "${AUTOMODE_CLUSTER}"
  sed -i.bak "s|@NODE_IAM_ROLE@|${AUTOMODE_NODE_ROLE}|g" "${RENDERED}/${base}"
  rm -f "${RENDERED}/${base}.bak"
  kubectl --context "${AUTOMODE_CLUSTER}" apply -f "${RENDERED}/${base}"
done

kubectl --context "${AUTOMODE_CLUSTER}" create namespace bench \
  --dry-run=client -o yaml | kubectl --context "${AUTOMODE_CLUSTER}" apply -f -

################################################################################
# Phase 2 depends on runai-streamer being in the workload image.
#
# The AWS vLLM Deep Learning Container base is documented as already bundling it,
# so no custom build should be needed -- but "documented as" is not "verified in
# the tag we are about to run", and the failure mode is a pod that crash-loops in
# front of an audience. Checked here instead.
################################################################################
echo "==> Run:ai streaming support (phase 2)"
echo "    not checked here. Confirming it means pulling a ~9 GB image, which takes"
echo "    minutes. A check that times out reports a false negative, so it is run"
echo "    separately against a node that already has the image:"
echo "        bin/bench.sh arm-c-soci      # warms the node"
echo "        bin/check_runai.sh"
echo "    Phase 2 will also fail loudly and immediately if it is missing."

echo
echo "==> ready"
echo "    phase 1, cold:  bin/bench.sh arm-a-baseline"
echo "                    bin/bench.sh arm-b-snapshot"
echo "                    bin/bench.sh arm-c-soci"
echo "                    bin/bench.sh arm-d-automode"
echo "    warm scale-out: bin/bench.sh arm-c-soci --warm"
echo "    phase 2:        bin/bench.sh weights s3-initcontainer"
echo "                    bin/bench.sh weights runai-local"
echo "                    bin/bench.sh weights runai-s3"
echo "    readout:        bin/report.py"
