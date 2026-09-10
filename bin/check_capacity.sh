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
ERRFILE="$(mktemp -t capacity-probe)"
trap 'rm -f "${ERRFILE}"' EXIT

for row in "${SUBNETS[@]}"; do
  read -r subnet zone <<<"${row}"
  printf '    %-14s %-24s ' "${zone}" "${subnet}"
  if ID="$(aws ec2 run-instances --region "${REGION}" \
      --image-id "${AMI}" \
      --instance-type "${TYPE}" \
      --subnet-id "${subnet}" \
      --tag-specifications 'ResourceType=instance,Tags=[{Key=purpose,Value=capacity-probe}]' \
      --query 'Instances[0].InstanceId' --output text 2>"${ERRFILE}")"; then
    echo "OK (${ID})"
    IDS+=("${ID}")
  else
    echo "FAILED"
    # Print what EC2 said rather than a keyword matched out of it. The message names the
    # error code and, for a capacity failure, lists the Availability Zones that can serve
    # the request right now -- which is the part you act on. A keyword match would also
    # hide an unexpected failure such as VcpuLimitExceeded behind a capacity story.
    sed 's/^/               /' "${ERRFILE}"
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
echo
echo "Capacity is per instance type per Availability Zone, so this does not mean the region is"
echo "out of GPUs, and Karpenter can still succeed by choosing one of the zones that worked."
echo "What it does mean is that Karpenter may try a starved zone first and then hold that"
echo "offering unavailable for 3 minutes, and the pod waits out the TTL before a NodeClaim is"
echo "created. That wait is added to the variant's total as a long \"Karpenter decision\""
echo "segment, with no error to explain it."
echo
echo "For a measurement run, either wait and probe again -- this changes within minutes -- or"
echo "set GPU_INSTANCE_TYPE to a type that has capacity in every zone and re-measure every"
echo "variant on it, because a soci figure does not carry across instance types."
exit 1
