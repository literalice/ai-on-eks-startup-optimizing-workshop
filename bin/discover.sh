#!/usr/bin/env bash
#
# Find the two values the harness needs without depending on Terraform state being in this
# directory. Sourced, not run:
#
#   source "${ROOT}/bin/discover.sh"
#   resolve_bucket        # sets MODEL_BUCKET and BUCKET_SOURCE
#   resolve_role          # sets KARPENTER_NODE_IAM_ROLE_NAME and ROLE_SOURCE
#
# Both read config.env's REGION, NAME_PREFIX and KARPENTER_CLUSTER, so source that first.
# resolve_role needs a working kubeconfig for KARPENTER_CLUSTER.
#
# Order for each value: what the caller set, then the cluster or AWS, then Terraform. Terraform
# last because the state is often somewhere else, or was never created -- the cluster may have
# existed before this workshop.

# `terraform output -raw` writes its warnings to stdout as well as stderr, and exits 0 when the
# state has no outputs. Capturing it without checking puts a multi-line warning into the
# variable, which then fails somewhere further on, in a message that names neither Terraform nor
# the output. So everything goes through this.
sane_name() {
  local value="$1"
  [[ "$(printf '%s' "${value}" | wc -l | tr -d ' ')" == "0" ]] || return 1
  [[ -n "${value}" && "${value}" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  printf '%s' "${value}"
}

tf_output() {
  local value
  value="$(terraform -chdir="${ROOT}/terraform" output -raw "$1" 2>/dev/null)" || return 1
  sane_name "${value}"
}

# The Karpenter node role, from any EC2NodeClass in the cluster.
#
# There is no way to find this from AWS alone. Both a Karpenter node role and a managed node
# group's role appear as EC2_LINUX access entries on the cluster, and they can carry identical
# tags, so neither the entry type nor the tags tell them apart. An EC2NodeClass naming one is
# unambiguous.
#
# Node classes this workshop created are considered last, so that a cluster which had its own
# before the workshop ran is read rather than this script's previous output being echoed back.
discover_role() {
  local value
  value="$(kubectl --context "${KARPENTER_CLUSTER}" get ec2nodeclass -o json 2>/dev/null \
    | python3 -c '
import json, sys

ours = {"baseline", "snapshot", "soci"}
try:
    items = json.load(sys.stdin).get("items", [])
except Exception:
    sys.exit(1)

for consider_ours in (False, True):
    for item in items:
        if (item["metadata"]["name"] in ours) is not consider_ours:
            continue
        role = (item.get("spec") or {}).get("role")
        if role:
            print(role)
            sys.exit(0)
sys.exit(1)
' 2>/dev/null)" || return 1
  sane_name "${value}"
}

# The weights bucket, by tag. Terraform puts Purpose on everything it creates. Matching the name
# prefix as well keeps this from picking up a bucket belonging to another copy of the workshop in
# the same account.
discover_bucket() {
  local value
  value="$(aws resourcegroupstaggingapi get-resources --region "${REGION}" \
    --tag-filters "Key=Purpose,Values=bottlerocket-startup-workshop" \
    --resource-type-filters s3 \
    --query "ResourceTagMappingList[].ResourceARN" --output text 2>/dev/null \
    | tr '\t' '\n' | sed 's|^arn:aws:s3:::||' \
    | grep "^${NAME_PREFIX}-models-" | head -1)" || return 1
  sane_name "${value}"
}

# Sets KARPENTER_NODE_IAM_ROLE_NAME and ROLE_SOURCE. Returns 1 if no source had it, leaving the
# message to the caller, since what to suggest differs between scripts.
resolve_role() {
  if [[ -n "${KARPENTER_NODE_IAM_ROLE_NAME:-}" ]]; then
    ROLE_SOURCE="the environment"
  elif KARPENTER_NODE_IAM_ROLE_NAME="$(discover_role)"; then
    ROLE_SOURCE="an existing EC2NodeClass in ${KARPENTER_CLUSTER}"
  elif KARPENTER_NODE_IAM_ROLE_NAME="$(tf_output karpenter_node_iam_role_name)"; then
    ROLE_SOURCE="terraform output"
  else
    KARPENTER_NODE_IAM_ROLE_NAME=""
    ROLE_SOURCE=""
    return 1
  fi
  export KARPENTER_NODE_IAM_ROLE_NAME
}

# Sets MODEL_BUCKET and BUCKET_SOURCE. Returns 1 if no source had it. Only phases 2 and 3 need
# it, so most callers treat that as a note rather than an error.
resolve_bucket() {
  if [[ -n "${MODEL_BUCKET:-}" ]]; then
    BUCKET_SOURCE="config.env or the environment"
  elif MODEL_BUCKET="$(discover_bucket)"; then
    BUCKET_SOURCE="the Purpose tag"
  elif MODEL_BUCKET="$(tf_output model_bucket)"; then
    BUCKET_SOURCE="terraform output"
  else
    MODEL_BUCKET=""
    BUCKET_SOURCE=""
    return 1
  fi
  export MODEL_BUCKET
}
