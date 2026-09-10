#!/usr/bin/env bash
#
# snapshot pre-work: bake the workload image into an EBS snapshot that Bottlerocket
# mounts as its data volume, so nothing is pulled at node start.
#
# This takes 10-20 minutes for a multi-GB image. Run it the day before, not live.
# It wraps aws-samples/bottlerocket-images-cache, which launches a Bottlerocket
# instance, pulls the images over SSM, stops the instance, snapshots the data
# volume and terminates the instance.
#
# The snapshot ID is written to results/snapshot-id.txt and to an SSM parameter,
# and bin/prep.sh substitutes it into the snapshot EC2NodeClass.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"

# Read the same file everything else reads, so the snapshot is built from the image the
# variants will run and is named after the same prefix.
if [[ -f "${ROOT}/config.env" ]]; then
  # shellcheck source=../config.env
  source "${ROOT}/config.env"
fi

REGION="${REGION:-us-west-2}"
NAME_PREFIX="${NAME_PREFIX:-br-startup}"
K8S_VERSION="${K8S_VERSION:-1.34}"
IMAGE="${IMAGE:-${WORKLOAD_IMAGE:-}}"
SNAPSHOT_SIZE="${SNAPSHOT_SIZE:-80}"

# Must have a GPU, because AMI_SSM_PATH below is the NVIDIA variant. See the check further
# down for what happens otherwise. Defaulting to the type the variants run on means the type
# has already been checked for capacity by bin/check_capacity.sh.
BUILDER_INSTANCE_TYPE="${BUILDER_INSTANCE_TYPE:-${GPU_INSTANCE_TYPE:-gr6.8xlarge}}"

# Keyed on NAME_PREFIX, so two people working in one account do not overwrite each other's
# snapshot ID. Everything else this workshop creates is named from the same prefix.
SSM_PARAM="${SSM_PARAM:-/${NAME_PREFIX}/image-cache-snapshot-id}"

WORKDIR="${WORKDIR:-/tmp/bottlerocket-images-cache}"

if [[ -z "${IMAGE}" ]]; then
  echo "IMAGE is required, and WORKLOAD_IMAGE is not set in config.env either. Example:" >&2
  echo "  IMAGE=763104351884.dkr.ecr.us-west-2.amazonaws.com/vllm:0.22.0-gpu-py312-cu130-ubuntu22.04-ec2 $0" >&2
  exit 2
fi

# The NVIDIA variant, so the cached layers land on the same OS the variants run on.
AMI_SSM_PATH="/aws/service/bottlerocket/aws-k8s-${K8S_VERSION}-nvidia/x86_64/latest/image_id"

# The NVIDIA variant does not finish booting on an instance without a GPU, and the failure
# is invisible from here.
#
# load-tesla-kernel-modules.service runs `modprobe nvidia`, which fails with ENODEV when
# there is no NVIDIA device. That unit is RequiredBy=drivers.target, and drivers.target is
# RequiredBy=preconfigured.target. Bottlerocket's boot chain is preconfigured.target ->
# configured.target -> multi-user.target, each requiring the previous, so the boot stops at
# the first of them. The control container that runs the SSM agent is
# WantedBy=multi-user.target, so it never starts. The instance still reaches EC2 state
# `running`, and the wrapped script's SSM wait loop has no timeout, so the symptom is an
# indefinite hang at "[2/8] Launching SSM".
echo "==> checking that ${BUILDER_INSTANCE_TYPE} has a GPU"
GPU_COUNT="$(aws ec2 describe-instance-types \
  --region "${REGION}" \
  --instance-types "${BUILDER_INSTANCE_TYPE}" \
  --query 'InstanceTypes[0].GpuInfo.Gpus[0].Count' \
  --output text 2>/dev/null || true)"

if [[ -z "${GPU_COUNT}" || "${GPU_COUNT}" == "None" ]]; then
  echo "ERROR: BUILDER_INSTANCE_TYPE=${BUILDER_INSTANCE_TYPE} has no GPU, but the AMI is the" >&2
  echo "       NVIDIA variant (${AMI_SSM_PATH})." >&2
  echo "       The instance would boot but never register with SSM, and this script would" >&2
  echo "       hang at \"Launching SSM\". Use a GPU instance type, for example:" >&2
  echo "         BUILDER_INSTANCE_TYPE=g6.xlarge $0" >&2
  exit 2
fi
echo "    ${GPU_COUNT} GPU(s)"

echo "==> region                ${REGION}"
echo "==> bottlerocket AMI path ${AMI_SSM_PATH}"
echo "==> image                 ${IMAGE}"
echo "==> snapshot size         ${SNAPSHOT_SIZE} GiB"

if [[ ! -d "${WORKDIR}" ]]; then
  git clone --depth 1 https://github.com/aws-samples/bottlerocket-images-cache "${WORKDIR}"
fi

# The image lives in the AWS Deep Learning Containers account. The builder pulls
# it over SSM using the instance role, which the sample script grants ECR read.
"${WORKDIR}/snapshot.sh" \
  -r "${REGION}" \
  -a "${AMI_SSM_PATH}" \
  -i "${BUILDER_INSTANCE_TYPE}" \
  -s "${SNAPSHOT_SIZE}" \
  -op "${SSM_PARAM}" \
  "${IMAGE}"

SNAPSHOT_ID="$(aws ssm get-parameter \
  --region "${REGION}" \
  --name "${SSM_PARAM}" \
  --query 'Parameter.Value' \
  --output text)"

# The wrapped script names every snapshot "Bottlerocket Data Volume", which is ambiguous when
# more than one person is working in the same account, and at teardown there is nothing to
# distinguish one from another. Retag it with the prefix everything else uses.
aws ec2 create-tags \
  --region "${REGION}" \
  --resources "${SNAPSHOT_ID}" \
  --tags "Key=Name,Value=${NAME_PREFIX}-image-cache" \
         "Key=Purpose,Value=bottlerocket-startup-workshop" \
         "Key=Image,Value=${IMAGE}" >/dev/null

mkdir -p "${ROOT}/results"
printf '%s\n' "${SNAPSHOT_ID}" > "${ROOT}/results/snapshot-id.txt"

echo
echo "==> snapshot ${SNAPSHOT_ID}"
echo "==> written to results/snapshot-id.txt and SSM ${SSM_PARAM}"
echo "==> bin/prep.sh will substitute it into the snapshot EC2NodeClass"
