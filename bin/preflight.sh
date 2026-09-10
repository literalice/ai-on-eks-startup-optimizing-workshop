#!/usr/bin/env bash
#
# Check an account against the workshop's prerequisites, before the session.
#
#   bin/preflight.sh
#
# Read-only apart from the optional capacity probe, which bin/check_capacity.sh performs
# separately and which needs the VPC to exist. Nothing here creates or changes anything.
#
# Exit status is 0 when every required check passed. Warnings do not fail the run: they are
# for things that would only affect part of the workshop.
#
# What this cannot check is listed at the end. Permission to create IAM roles is the main
# one, because IAM has no dry-run and the only way to be certain is to run terraform apply.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"

if [[ -f "${ROOT}/config.env" ]]; then
  # shellcheck source=../config.env
  source "${ROOT}/config.env"
else
  REGION="${REGION:-us-west-2}"
  GPU_INSTANCE_TYPE="${GPU_INSTANCE_TYPE:-gr6.8xlarge}"
  WORKLOAD_IMAGE="${WORKLOAD_IMAGE:-763104351884.dkr.ecr.${REGION}.amazonaws.com/vllm:0.22.0-gpu-py312-cu130-ubuntu22.04-ec2}"
  MODEL_HF_REPO="${MODEL_HF_REPO:-Qwen/Qwen2.5-1.5B-Instruct}"
fi

K8S_VERSION="${K8S_VERSION:-1.34}"

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; RESET=$'\033[0m'

FAILED=0
WARNED=0

pass() { printf '  %s[ ok ]%s %s\n' "${GREEN}" "${RESET}" "$1"; }
fail() { printf '  %s[fail]%s %s\n' "${RED}" "${RESET}" "$1"; FAILED=$((FAILED + 1)); }
warn() { printf '  %s[warn]%s %s\n' "${YELLOW}" "${RESET}" "$1"; WARNED=$((WARNED + 1)); }
note() { printf '         %s\n' "$1"; }
head2() { printf '\n%s%s%s\n' "${BOLD}" "$1" "${RESET}"; }

################################################################################
head2 "Command line tools"

for tool in aws kubectl terraform jq python3; do
  if command -v "${tool}" >/dev/null 2>&1; then
    pass "${tool}"
  else
    fail "${tool} is not on PATH"
  fi
done

# Only phase 2 needs this, and only on the machine that stages the model to S3.
if command -v hf >/dev/null 2>&1; then
  pass "hf (Hugging Face CLI)"
else
  warn "hf is not on PATH. Needed only to stage the model for phase 2:"
  note "pip install --upgrade 'huggingface_hub[cli]'"
fi

if command -v aws >/dev/null 2>&1; then
  AWS_MAJOR="$(aws --version 2>&1 | sed -n 's|^aws-cli/\([0-9]*\).*|\1|p')"
  if [[ "${AWS_MAJOR}" == "2" ]]; then
    pass "aws-cli is v2"
  else
    warn "aws-cli reports major version '${AWS_MAJOR:-unknown}'. v2 is what this was tested with."
  fi
fi

################################################################################
head2 "Credentials and region"

if ! CALLER="$(aws sts get-caller-identity --output json 2>/dev/null)"; then
  fail "aws sts get-caller-identity failed. No usable credentials."
  echo
  echo "Stopping here: the remaining checks all need credentials."
  exit 1
fi
ACCOUNT="$(printf '%s' "${CALLER}" | jq -r '.Account')"
ARN="$(printf '%s' "${CALLER}" | jq -r '.Arn')"
pass "credentials resolve to account ${ACCOUNT}"
note "${ARN}"

if aws ec2 describe-availability-zones --region "${REGION}" >/dev/null 2>&1; then
  pass "region ${REGION} is reachable and enabled"
else
  fail "cannot query region ${REGION}. Check the region name and that it is enabled."
fi

################################################################################
head2 "Service quotas in ${REGION}"

# 32 vCPU is one node of the default instance type. The variants run one at a time, so one
# node is the requirement; more headroom lets a run start before the previous node has
# finished terminating.
GPU_VCPUS="$(aws ec2 describe-instance-types --region "${REGION}" \
  --instance-types "${GPU_INSTANCE_TYPE}" \
  --query 'InstanceTypes[0].VCpuInfo.DefaultVCpus' --output text 2>/dev/null)"

if [[ -z "${GPU_VCPUS}" || "${GPU_VCPUS}" == "None" ]]; then
  fail "${GPU_INSTANCE_TYPE} is not offered in ${REGION}, or it could not be described."
  GPU_VCPUS=32
else
  pass "${GPU_INSTANCE_TYPE} is offered in ${REGION} (${GPU_VCPUS} vCPU)"
fi

check_quota() {
  local service="$1" code="$2" need="$3" label="$4"
  local value
  value="$(aws service-quotas get-service-quota --region "${REGION}" \
    --service-code "${service}" --quota-code "${code}" \
    --query 'Quota.Value' --output text 2>/dev/null)"
  if [[ -z "${value}" || "${value}" == "None" ]]; then
    warn "${label}: could not read the quota (needs servicequotas:GetServiceQuota)"
    return
  fi
  if (( $(printf '%.0f' "${value}") >= need )); then
    pass "${label}: ${value%.*} (need ${need})"
  else
    fail "${label}: ${value%.*}, need at least ${need}"
    note "Request an increase for quota ${code} in Service Quotas. Approval is not instant,"
    note "so do this several days before the session."
  fi
}

check_quota ec2 L-DB2E81BA "${GPU_VCPUS}" "Running On-Demand G and VT instances (vCPU)"
check_quota vpc L-F678F1CE 1 "VPCs per Region"
check_quota ec2 L-0263D0A3 1 "EC2-VPC Elastic IPs (the NAT gateway uses one)"

################################################################################
head2 "Existing usage that the quotas above have to accommodate"

VPC_COUNT="$(aws ec2 describe-vpcs --region "${REGION}" \
  --query 'length(Vpcs)' --output text 2>/dev/null)"
VPC_LIMIT="$(aws service-quotas get-service-quota --region "${REGION}" \
  --service-code vpc --quota-code L-F678F1CE --query 'Quota.Value' --output text 2>/dev/null)"
if [[ -n "${VPC_COUNT}" && "${VPC_COUNT}" != "None" ]]; then
  if [[ -n "${VPC_LIMIT}" && "${VPC_LIMIT}" != "None" ]] \
     && (( VPC_COUNT >= $(printf '%.0f' "${VPC_LIMIT}") )); then
    fail "${VPC_COUNT} VPCs already exist and the limit is ${VPC_LIMIT%.*}. This workshop adds one."
  else
    pass "${VPC_COUNT} VPC(s) in use; this workshop adds one"
  fi
fi

RUNNING_G="$(aws ec2 describe-instances --region "${REGION}" \
  --filters "Name=instance-state-name,Values=running,pending" \
  --query 'Reservations[].Instances[?starts_with(InstanceType, `g`) || starts_with(InstanceType, `p`)].InstanceType' \
  --output text 2>/dev/null | wc -w | tr -d ' ')"
if [[ "${RUNNING_G:-0}" -gt 0 ]]; then
  warn "${RUNNING_G} GPU instance(s) already running in ${REGION}, consuming the same quota"
else
  pass "no GPU instances currently running in ${REGION}"
fi

################################################################################
head2 "Container image and model"

IMAGE_REGISTRY="${WORKLOAD_IMAGE%%/*}"
IMAGE_ACCOUNT="${IMAGE_REGISTRY%%.*}"
IMAGE_REPO_TAG="${WORKLOAD_IMAGE#*/}"
IMAGE_REPO="${IMAGE_REPO_TAG%%:*}"
IMAGE_TAG="${IMAGE_REPO_TAG#*:}"

if SIZE="$(aws ecr describe-images --region "${REGION}" \
    --registry-id "${IMAGE_ACCOUNT}" --repository-name "${IMAGE_REPO}" \
    --image-ids "imageTag=${IMAGE_TAG}" \
    --query 'imageDetails[0].imageSizeInBytes' --output text 2>/dev/null)" \
   && [[ -n "${SIZE}" && "${SIZE}" != "None" ]]; then
  pass "the workload image is readable ($(( SIZE / 1000000000 )) GB compressed)"
  note "${WORKLOAD_IMAGE}"
else
  fail "cannot read ${WORKLOAD_IMAGE}"
  note "This is an AWS Deep Learning Container. It needs no registry credentials, but the"
  note "tag does get replaced over time. Check the current tags with:"
  note "  aws ecr describe-images --region ${REGION} --registry-id ${IMAGE_ACCOUNT} \\"
  note "    --repository-name ${IMAGE_REPO} \\"
  note "    --query 'sort_by(imageDetails,&imagePushedAt)[-5:].imageTags'"
fi

if curl -fsSL -o /dev/null --max-time 20 \
   "https://huggingface.co/api/models/${MODEL_HF_REPO}" 2>/dev/null; then
  pass "the model repository is reachable without a token: ${MODEL_HF_REPO}"
else
  warn "could not reach https://huggingface.co/api/models/${MODEL_HF_REPO}"
  note "Only phase 2 needs this. A proxy or a gated model would both show up here."
fi

################################################################################
head2 "Kubernetes version and AMI"

if aws eks describe-cluster-versions --region "${REGION}" \
     --query "clusterVersions[?clusterVersion=='${K8S_VERSION}']" --output text >/dev/null 2>&1; then
  pass "EKS ${K8S_VERSION} is selectable in ${REGION}"
else
  warn "could not confirm EKS ${K8S_VERSION} is selectable (needs eks:DescribeClusterVersions)"
fi

BR_AMI="$(aws ssm get-parameter --region "${REGION}" \
  --name "/aws/service/bottlerocket/aws-k8s-${K8S_VERSION}-nvidia/x86_64/latest/image_id" \
  --query 'Parameter.Value' --output text 2>/dev/null)"
if [[ -n "${BR_AMI}" && "${BR_AMI}" != "None" ]]; then
  BR_VER="$(aws ssm get-parameter --region "${REGION}" \
    --name "/aws/service/bottlerocket/aws-k8s-${K8S_VERSION}-nvidia/x86_64/latest/image_version" \
    --query 'Parameter.Value' --output text 2>/dev/null)"
  pass "Bottlerocket NVIDIA AMI resolves: ${BR_AMI} (${BR_VER:-version unknown})"
  # SOCI parallel pull/unpack landed in 1.44.0. Below that, step 3 silently measures step 1.
  if [[ "${BR_VER}" =~ ^([0-9]+)\.([0-9]+)\. ]]; then
    BR_MAJOR="${BASH_REMATCH[1]}"
    BR_MINOR="${BASH_REMATCH[2]}"
    if (( BR_MAJOR > 1 || (BR_MAJOR == 1 && BR_MINOR >= 44) )); then
      pass "Bottlerocket ${BR_VER} is 1.44.0 or later, so SOCI parallel pull is available"
    else
      fail "Bottlerocket ${BR_VER} is below 1.44.0. Step 3's settings would be ignored silently."
    fi
  elif [[ -n "${BR_VER}" ]]; then
    warn "could not parse the Bottlerocket version '${BR_VER}' to check it is 1.44.0 or later"
  fi
else
  fail "cannot resolve the Bottlerocket NVIDIA AMI for Kubernetes ${K8S_VERSION} in ${REGION}"
fi

################################################################################
head2 "Instance store on the chosen instance type"

DISKS="$(aws ec2 describe-instance-types --region "${REGION}" \
  --instance-types "${GPU_INSTANCE_TYPE}" \
  --query 'InstanceTypes[0].InstanceStorageInfo.Disks[0].Count' --output text 2>/dev/null)"
if [[ -z "${DISKS}" || "${DISKS}" == "None" ]]; then
  fail "${GPU_INSTANCE_TYPE} has no instance store. Steps 3 and 4 would measure the same as step 1."
elif [[ "${DISKS}" -ge 2 ]]; then
  pass "${GPU_INSTANCE_TYPE} has ${DISKS} instance-store disks, so RAID0 actually stripes"
else
  warn "${GPU_INSTANCE_TYPE} has 1 instance-store disk. instanceStorePolicy: RAID0 will move"
  note "container storage to it but will not stripe, because Bottlerocket skips a"
  note "single-member array. The step 3 figures are still valid; the wording about striping"
  note "in steps/03-soci.md will not apply."
fi

################################################################################
head2 "What this cannot check"

cat <<'LIMITS'
  - Permission to create IAM roles and policies. IAM has no dry-run, and a permissions
    boundary or an SCP can deny at apply time without being visible beforehand. Terraform
    creates roles for both clusters, the Karpenter controller, the nodes, and one for the
    workshop's service account.
  - Permission to create EKS clusters, a VPC with a NAT gateway, an S3 bucket, EBS
    snapshots and launch templates.
  - GPU capacity. That varies by instance type and Availability Zone from minute to minute,
    and it can only be tested by launching. Run bin/check_capacity.sh after terraform has
    created the VPC, and again shortly before the session.
LIMITS

################################################################################
echo
if [[ ${FAILED} -eq 0 ]]; then
  printf '%s%d check(s) failed, %d warning(s).%s\n' "${GREEN}" "${FAILED}" "${WARNED}" "${RESET}"
  echo "The account meets the prerequisites this script can verify."
  exit 0
fi

printf '%s%d check(s) failed, %d warning(s).%s\n' "${RED}" "${FAILED}" "${WARNED}" "${RESET}"
echo "Resolve the failures above before the session. Quota increases in particular are not"
echo "granted immediately."
exit 1
