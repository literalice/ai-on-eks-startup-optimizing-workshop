#!/usr/bin/env bash
#
# Build the arm B snapshot from a node that has already pulled the image.
#
#   bin/bench.sh arm-a-baseline          # leaves a node with the image cached
#   snapshot/snapshot-from-node.sh       # snapshot that node's data volume
#
# Why this instead of aws-samples/bottlerocket-images-cache: that script launches
# its own Bottlerocket instance and drives it over SSM Run Command. On the
# EKS-optimized Bottlerocket NVIDIA AMI the instance never registered with SSM for
# us -- public subnet, public IP, instance profile all correct -- and the script sat
# at "Launching SSM" indefinitely with no timeout.
#
# Using a node the workshop already produced is faster and strictly more faithful:
# the cached layers were written by the same containerd and OS version that will
# later consume them, rather than by a separately built instance that might differ.
#
# Requirements: an arm A (or any non-NVMe) node must be up with the image pulled.
# Arm C is not a valid source -- instanceStorePolicy moves container storage to
# local NVMe, so its EBS data volume is empty.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"

# shellcheck source=../config.env
source "${ROOT}/config.env"

SOURCE_NODEPOOL="${SOURCE_NODEPOOL:-arm-a-baseline}"
DATA_DEVICE="${DATA_DEVICE:-/dev/xvdb}"

echo "==> finding a node for ${SOURCE_NODEPOOL}"
PROVIDER_ID="$(kubectl --context "${KARPENTER_CLUSTER}" get nodeclaims \
  -l "karpenter.sh/nodepool=${SOURCE_NODEPOOL}" \
  -o jsonpath='{.items[0].status.providerID}' 2>/dev/null || true)"

if [[ -z "${PROVIDER_ID}" ]]; then
  echo "no node found for ${SOURCE_NODEPOOL}." >&2
  echo "Run 'bin/bench.sh ${SOURCE_NODEPOOL}' first and do not reset afterwards." >&2
  exit 1
fi

INSTANCE_ID="${PROVIDER_ID##*/}"
echo "    instance ${INSTANCE_ID}"

echo "==> locating its ${DATA_DEVICE} volume"
VOLUME_ID="$(aws ec2 describe-instances \
  --region "${REGION}" \
  --instance-ids "${INSTANCE_ID}" \
  --query "Reservations[0].Instances[0].BlockDeviceMappings[?DeviceName=='${DATA_DEVICE}'].Ebs.VolumeId | [0]" \
  --output text)"

if [[ -z "${VOLUME_ID}" || "${VOLUME_ID}" == "None" ]]; then
  echo "no ${DATA_DEVICE} on ${INSTANCE_ID}." >&2
  echo "If this is an NVMe arm (arm C), its container storage is not on EBS." >&2
  exit 1
fi
echo "    volume ${VOLUME_ID}"

# Snapshotting a live, mounted volume. containerd may be mid-write, which for a
# read-only image cache is acceptable: worst case a partially written layer is
# discarded and re-pulled. Stopping the node first would be cleaner but would mean
# draining and replacing it, and the point of the exercise is the cached layers.
echo "==> creating snapshot"
SNAPSHOT_ID="$(aws ec2 create-snapshot \
  --region "${REGION}" \
  --volume-id "${VOLUME_ID}" \
  --description "Bottlerocket data volume with ${WORKLOAD_IMAGE} pre-pulled (workshop arm B)" \
  --tag-specifications "ResourceType=snapshot,Tags=[{Key=Name,Value=${NAME_PREFIX}-image-cache},{Key=Purpose,Value=bottlerocket-startup-workshop}]" \
  --query 'SnapshotId' --output text)"
echo "    ${SNAPSHOT_ID}"

echo "==> waiting for it to complete (a few minutes)"
aws ec2 wait snapshot-completed --region "${REGION}" --snapshot-ids "${SNAPSHOT_ID}"

aws ec2 describe-snapshots --region "${REGION}" --snapshot-ids "${SNAPSHOT_ID}" \
  --query 'Snapshots[0].{State:State,Size:VolumeSize,Started:StartTime}' --output json | sed 's/^/    /'

mkdir -p "${ROOT}/results"
printf '%s\n' "${SNAPSHOT_ID}" > "${ROOT}/results/snapshot-id.txt"

echo
echo "==> written to results/snapshot-id.txt"
echo "==> now run bin/prep.sh to apply the arm B node class, then bin/bench.sh arm-b-snapshot"
