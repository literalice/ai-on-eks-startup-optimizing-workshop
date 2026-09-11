#!/usr/bin/env bash
#
# Build the snapshot variant's EBS snapshot from a node in a node pool that exists only for
# building, and which has already pulled the image.
#
#   SOURCE_NODEPOOL=snapshot-builder snapshot/snapshot-from-node.sh
#
# SOURCE_NODEPOOL is required. It used to default to `baseline`, which snapshotted a node that
# runs workloads: the result carried everything that node had ever pulled and inherited its
# volume size, so every node restored from it got a volume that large. There is no case where
# that is the better choice, so it is no longer reachable by accident.
#
# Prefer snapshot/build-snapshot.sh, which wraps aws-samples/bottlerocket-images-cache. It
# stops kubelet and then the instance before snapshotting, so the result is
# filesystem-consistent; it removes existing images and pulls only the ones you name; its
# volume size is a parameter; and it runs from an image tag with no cluster involved, which is
# what a pipeline triggered by an image build needs.
#
# Use this script instead when the pull needs credentials the cluster already holds -- the
# builder pulls with its instance role, so an imagePullSecret is not available to it -- or when
# SSM is unreachable from the target subnets, or when launching an ad-hoc instance with its own
# IAM role outside the cluster is not permitted.
#
# The pool must not be a SOCI pool. instanceStorePolicy moves container storage to local NVMe,
# so its EBS data volume is empty and the snapshot would hold no images.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"

# shellcheck source=../config.env
source "${ROOT}/config.env"

DATA_DEVICE="${DATA_DEVICE:-/dev/xvdb}"

if [[ -z "${SOURCE_NODEPOOL:-}" ]]; then
  echo "SOURCE_NODEPOOL is required: the node pool whose node holds the images." >&2
  echo "" >&2
  echo "Create a pool for building, taint it so only your pull pod tolerates it, run a pod" >&2
  echo "that pulls the images, then:" >&2
  echo "  SOURCE_NODEPOOL=snapshot-builder $0" >&2
  echo "" >&2
  echo "Do not point this at a pool that runs workloads. The snapshot would carry everything" >&2
  echo "those nodes have pulled and inherit their volume size." >&2
  echo "" >&2
  echo "For the workshop's own snapshot, use snapshot/build-snapshot.sh instead." >&2
  exit 2
fi

echo "==> finding a node for ${SOURCE_NODEPOOL}"
PROVIDER_ID="$(kubectl --context "${KARPENTER_CLUSTER}" get nodeclaims \
  -l "karpenter.sh/nodepool=${SOURCE_NODEPOOL}" \
  -o jsonpath='{.items[0].status.providerID}' 2>/dev/null || true)"

if [[ -z "${PROVIDER_ID}" ]]; then
  echo "no node found for ${SOURCE_NODEPOOL}." >&2
  echo "Karpenter creates the node when a pod that tolerates its taint is pending. Check that" >&2
  echo "your pull pod is scheduled and Ready, which is when the pull has finished." >&2
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
