#!/usr/bin/env bash
#
# Probe whether the GPU instance type has capacity right now, before spending 25 minutes on
# a demo run that would be contaminated.
#
#   bin/check_capacity.sh
#
# Why this exists: Karpenter caches an offering as unavailable for 3 minutes after an
# InsufficientInstanceCapacity error. A pod submitted during that window waits out the TTL
# before a NodeClaim is created at all, and that wait is added to the variant's total as a
# "Karpenter decision" segment. Nothing reports an error, so the variant simply looks slow.
# It can reach 190s or more, which is larger than most of the differences being measured.
#
# There is no API that reports real capacity: describe-instance-type-offerings tells you the
# type is offered in the AZ, not that it can be launched. --dry-run does not check capacity
# either. So this launches one instance per subnet and terminates it immediately. A minute of
# a GPU instance per AZ is cheap next to a wasted demo run.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"

# shellcheck source=../config.env
source "${ROOT}/config.env"

TYPE="${GPU_INSTANCE_TYPE}"
# Any small AMI works; nothing boots far enough to matter.
AMI="$(aws ssm get-parameter --region "${REGION}" \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query 'Parameter.Value' --output text)"

mapfile -t SUBNETS < <(aws ec2 describe-subnets --region "${REGION}" \
  --filters "Name=tag:karpenter.sh/discovery,Values=${KARPENTER_CLUSTER}" \
  --query 'Subnets[].[SubnetId,AvailabilityZone]' --output text)

if [[ ${#SUBNETS[@]} -eq 0 ]]; then
  echo "no subnets tagged karpenter.sh/discovery=${KARPENTER_CLUSTER}" >&2
  exit 1
fi

echo "==> probing ${TYPE} in ${#SUBNETS[@]} subnet(s)"
FAILED=0
IDS=()

for row in "${SUBNETS[@]}"; do
  read -r subnet zone <<<"${row}"
  printf '    %-14s %-24s ' "${zone}" "${subnet}"
  if ID="$(aws ec2 run-instances --region "${REGION}" \
      --image-id "${AMI}" \
      --instance-type "${TYPE}" \
      --subnet-id "${subnet}" \
      --tag-specifications 'ResourceType=instance,Tags=[{Key=purpose,Value=capacity-probe}]' \
      --query 'Instances[0].InstanceId' --output text 2>/tmp/capacity-probe-err)"; then
    echo "OK (${ID})"
    IDS+=("${ID}")
  else
    REASON="$(grep -oE 'InsufficientInstanceCapacity|Unsupported|VcpuLimitExceeded|[A-Za-z]+LimitExceeded' /tmp/capacity-probe-err | head -1)"
    echo "FAILED ${REASON:-see /tmp/capacity-probe-err}"
    FAILED=$((FAILED + 1))
  fi
done

if [[ ${#IDS[@]} -gt 0 ]]; then
  echo "==> terminating the probes"
  aws ec2 terminate-instances --region "${REGION}" --instance-ids "${IDS[@]}" \
    --query 'TerminatingInstances[].InstanceId' --output text
fi

echo
if [[ ${FAILED} -eq 0 ]]; then
  echo "capacity available in every subnet. Safe to run bin/record.sh."
  exit 0
fi

echo "${FAILED} of ${#SUBNETS[@]} subnet(s) could not launch ${TYPE}."
echo "Karpenter will hold those offerings unavailable for 3 minutes at a time, which shows"
echo "up as a long \"Karpenter decision\" segment. Wait, or set GPU_INSTANCE_TYPE to a type"
echo "with capacity and re-baseline every variant."
exit 1
