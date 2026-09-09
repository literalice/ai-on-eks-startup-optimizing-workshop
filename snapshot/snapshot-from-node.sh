#!/usr/bin/env bash
#
# Build the snapshot variant's EBS snapshot from a node that has already pulled the image.
#
#   bin/bench.sh baseline          # leaves a node with the image cached
#   snapshot/snapshot-from-node.sh       # snapshot that node's data volume
#
# This is the FALLBACK method. Prefer snapshot/build-snapshot.sh, which wraps
# aws-samples/bottlerocket-images-cache. Reasons, in the order that matters for running
# this in production:
#
#   1. That script stops kubelet and then stops the instance before snapshotting, so the
#      snapshot is filesystem-consistent. This script snapshots a live, mounted volume.
#   2. It removes any existing images first and pulls only the images you name, so the
#      snapshot holds nothing else. A node's data volume also carries kubelet state, pod
#      logs and any other image that node happened to pull.
#   3. Its volume size is a parameter. This script inherits the node's data volume size, so
#      every node restored from the result gets a volume that large whether it needs it or
#      not.
#   4. It runs from an image tag with no cluster involved, which is what a pipeline
#      triggered by an image build needs.
#
# Use this script when a dedicated builder instance is not an option: SSM unreachable from
# the target subnets, or an account where launching an ad-hoc instance with its own IAM role
# is not permitted. Drain the node first if you use it for anything beyond a demo.
#
# Requirements: a baseline (or any non-NVMe) node must be up with the image pulled.
# The SOCI variant is not a valid source -- instanceStorePolicy moves container storage to
# local NVMe, so its EBS data volume is empty.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"

# shellcheck source=../config.env
source "${ROOT}/config.env"

SOURCE_NODEPOOL="${SOURCE_NODEPOOL:-baseline}"
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
  echo "If this is an NVMe variant (soci), its container storage is not on EBS." >&2
  exit 1
fi
echo "    volume ${VOLUME_ID}"

# Snapshotting a live, mounted volume. containerd may be mid-write. For a read-only
# image cache the effect is limited: a partially written layer is discarded and
# re-pulled. Stopping the node first would avoid that, but would require draining
# and replacing the node.
echo "==> creating snapshot"
SNAPSHOT_ID="$(aws ec2 create-snapshot \
  --region "${REGION}" \
  --volume-id "${VOLUME_ID}" \
  --description "Bottlerocket data volume with ${WORKLOAD_IMAGE} pre-pulled (workshop snapshot variant)" \
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
echo "==> now run bin/prep.sh to apply the snapshot node class, then bin/bench.sh snapshot"
