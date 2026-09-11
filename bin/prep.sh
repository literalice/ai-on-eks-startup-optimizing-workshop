#!/usr/bin/env bash
#
# Render the manifests and apply them to the right cluster. Idempotent -- safe to re-run.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"

# shellcheck source=../config.env
source "${ROOT}/config.env"
# shellcheck source=./discover.sh
source "${HERE}/discover.sh"

RENDERED="${ROOT}/manifests/rendered"
mkdir -p "${RENDERED}" "${ROOT}/results" "${ROOT}/raw"

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing dependency: $1" >&2; exit 1; }; }
need aws
need kubectl
need python3

################################################################################
# kubeconfig first, because the values below are read from the cluster where possible.
################################################################################
echo "==> kubeconfig"
aws eks update-kubeconfig --region "${REGION}" --name "${KARPENTER_CLUSTER}" --alias "${KARPENTER_CLUSTER}" >/dev/null
aws eks update-kubeconfig --region "${REGION}" --name "${AUTOMODE_CLUSTER}" --alias "${AUTOMODE_CLUSTER}" >/dev/null

################################################################################
# The node IAM role the EC2NodeClass references, and the weights bucket. Both come from the
# cluster or from AWS where possible rather than from Terraform, so this works against a
# cluster whose state lives somewhere else or nowhere. See bin/discover.sh.
################################################################################
if ! resolve_role; then
  echo "" >&2
  echo "could not resolve the Karpenter node IAM role." >&2
  echo "" >&2
  echo "It was not in the environment, no EC2NodeClass in ${KARPENTER_CLUSTER} names one," >&2
  echo "and ${ROOT}/terraform has no karpenter_node_iam_role_name output." >&2
  echo "" >&2
  echo "If this is the workshop's own environment and Terraform has not run yet:" >&2
  echo "  terraform -chdir=terraform init && terraform -chdir=terraform apply" >&2
  echo "" >&2
  echo "Otherwise supply it. It is the role Karpenter's nodes assume:" >&2
  echo "  KARPENTER_NODE_IAM_ROLE_NAME=<role name> bin/prep.sh" >&2
  echo "" >&2
  echo "Applying these settings to a cluster that already runs your workloads is better done" >&2
  echo "from EXISTING-CLUSTER.md than from this script. This one creates node pools named" >&2
  echo "baseline, snapshot and soci with no prefix and without the taint that keeps existing" >&2
  echo "workloads off them." >&2
  exit 1
fi

resolve_bucket || true

echo "    karpenter node role : ${KARPENTER_NODE_IAM_ROLE_NAME}  (from ${ROLE_SOURCE})"
if [[ -n "${MODEL_BUCKET}" ]]; then
  echo "    model bucket        : ${MODEL_BUCKET}  (from ${BUCKET_SOURCE})"
else
  echo "    model bucket        : <unset>"
  echo "    Steps 6 and 7 read the weights from S3 and need it. Run snapshot/stage-model.sh,"
  echo "    or set MODEL_BUCKET in config.env."
fi

################################################################################
# Refuse a P-family instance type on cost. The model fits in 24 GB, so a P type measures the
# same thing as a G type for several times the hourly rate.
#
# Checked here because this is what writes the instance type into the node pools, so nothing
# can run on a type this did not apply.
################################################################################
case "${GPU_INSTANCE_TYPE}" in
  p*)
    if [[ "${ALLOW_LARGE_GPU_FAMILY:-}" != "1" ]]; then
      echo "GPU_INSTANCE_TYPE=${GPU_INSTANCE_TYPE} is a P type, which this workshop rejects" >&2
      echo "on cost. Pick a G type with local NVMe -- see the table in PREREQUISITES.md -- or" >&2
      echo "set ALLOW_LARGE_GPU_FAMILY=1." >&2
      exit 2
    fi
    echo "==> WARNING: ${GPU_INSTANCE_TYPE} is a P type, allowed by ALLOW_LARGE_GPU_FAMILY=1"
    echo "    The cost figures in the README assume a G type."
    ;;
esac

################################################################################
# Assert the Bottlerocket AMI is new enough for SOCI.
#
# SOCI parallel pull/unpack landed in Bottlerocket 1.44.0. On an earlier version the
# snapshotter setting is ignored and soci measures the same thing as baseline, which
# would read as SOCI having no effect.
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
# baseline, snapshot and soci on the Karpenter cluster
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

  # Every substitution below is a single line by construction. Check it here as well, because
  # sed's failure for a multi-line value names the pattern rather than the value and reads as a
  # problem with the manifest.
  local name value
  for name in KARPENTER_NODE_IAM_ROLE_NAME GPU_INSTANCE_TYPE SNAPSHOT_ID; do
    value="${!name}"
    if [[ "${value}" == *$'\n'* ]]; then
      echo "${name} contains a newline, so it cannot be substituted into a manifest:" >&2
      printf '%s\n' "${value}" | sed 's/^/    /' >&2
      exit 1
    fi
  done

  sed \
    -e "s|@KARPENTER_NODE_IAM_ROLE_NAME@|${KARPENTER_NODE_IAM_ROLE_NAME}|g" \
    -e "s|@GPU_INSTANCE_FAMILY@|${GPU_INSTANCE_TYPE%%.*}|g" \
    -e "s|@GPU_INSTANCE_SIZE@|${GPU_INSTANCE_TYPE##*.}|g" \
    -e "s|@GPU_INSTANCE_TYPE@|${GPU_INSTANCE_TYPE}|g" \
    -e "s|@SNAPSHOT_ID@|${SNAPSHOT_ID}|g" \
    -e "s|@CLUSTER_NAME@|${3}|g" \
    "${src}" > "${dst}"
}

echo "==> rendering + applying baseline, snapshot and soci to ${KARPENTER_CLUSTER}"
for f in "${ROOT}"/manifests/karpenter/*.yaml; do
  base="$(basename "${f}")"
  if [[ "${base}" == *snapshot* && -z "${SNAPSHOT_ID}" ]]; then
    echo "    skipping ${base}: no snapshot yet. Run snapshot/build-snapshot.sh first."
    continue
  fi
  render "${f}" "${RENDERED}/${base}" "${KARPENTER_CLUSTER}"
  kubectl --context "${KARPENTER_CLUSTER}" apply -f "${RENDERED}/${base}"
done

kubectl --context "${KARPENTER_CLUSTER}" create namespace bench \
  --dry-run=client -o yaml | kubectl --context "${KARPENTER_CLUSTER}" apply -f -

# Two service accounts, each bound by Terraform to its own IAM role through EKS Pod Identity.
#
#   bench        the measured pods. Reads the weights, nothing more.
#   stage-model  the Job that puts the weights in the bucket. Writes.
#
# Kept apart so that a measured pod cannot write to the bucket it reads from.
for sa in bench stage-model; do
  kubectl --context "${KARPENTER_CLUSTER}" -n bench create serviceaccount "${sa}" \
    --dry-run=client -o yaml | kubectl --context "${KARPENTER_CLUSTER}" -n bench apply -f -
done

# The time-to-first-token probe runs inside the workload pod. Loaded from the file
# rather than duplicated into a manifest, so there is one copy to maintain.
echo "==> loading the time-to-first-token probe"
kubectl --context "${KARPENTER_CLUSTER}" -n bench create configmap ttft-probe \
  --from-file="first_token.py=${HERE}/first_token.py" \
  --dry-run=client -o yaml | kubectl --context "${KARPENTER_CLUSTER}" -n bench apply -f -

################################################################################
# automode on the Auto Mode cluster
#
# The built-in "default" NodeClass is read-only, so the custom NodeClass has to
# reuse its node IAM role. Read it off the cluster rather than plumbing it
# through Terraform -- this is the method the EKS docs give.
################################################################################
echo "==> rendering + applying automode to ${AUTOMODE_CLUSTER}"
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
echo "        bin/bench.sh soci      # warms the node"
echo "        bin/check_runai.sh"
echo "    Phase 2 will also fail loudly and immediately if it is missing."

echo
echo "==> ready"
echo "    phase 1, cold:  bin/bench.sh baseline"
echo "                    bin/bench.sh snapshot"
echo "                    bin/bench.sh soci"
echo "                    bin/bench.sh automode"
echo "    warm scale-out: bin/bench.sh soci --warm"
echo "    phase 2:        bin/bench.sh weights s3-initcontainer"
echo "                    bin/bench.sh weights runai-local"
echo "                    bin/bench.sh weights runai-s3"
echo "    phase 3:        bin/bench.sh compile cold"
echo "                    bin/bench.sh compile warm"
echo "    readout:        bin/report.py"
