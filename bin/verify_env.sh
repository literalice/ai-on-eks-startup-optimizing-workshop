#!/usr/bin/env bash
#
# Check the environment Terraform built, before running any variant.
#
#   bin/verify_env.sh
#
# Read-only. Every check corresponds to something that fails later and unhelpfully if it is
# wrong: a variant that stays Pending with no error, or a figure that looks like a
# measurement but is not.
#
# bin/preflight.sh is the one to run before Terraform, against the account. This one runs
# after, against what was created.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"

# shellcheck source=../config.env
source "${ROOT}/config.env"

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; RESET=$'\033[0m'

FAILED=0
WARNED=0

pass() { printf '  %s[ ok ]%s %s\n' "${GREEN}" "${RESET}" "$1"; }
fail() { printf '  %s[fail]%s %s\n' "${RED}" "${RESET}" "$1"; FAILED=$((FAILED + 1)); }
warn() { printf '  %s[warn]%s %s\n' "${YELLOW}" "${RESET}" "$1"; WARNED=$((WARNED + 1)); }
note() { printf '         %s\n' "$1"; }
head2() { printf '\n%s%s%s\n' "${BOLD}" "$1" "${RESET}"; }

################################################################################
head2 "Both clusters are reachable"

for ctx in "${KARPENTER_CLUSTER}" "${AUTOMODE_CLUSTER}"; do
  # `kubectl version` accepts only json or yaml for --output, not jsonpath, so read the
  # server line from the plain output instead.
  VER="$(kubectl --context "${ctx}" version 2>/dev/null \
    | sed -n 's|^Server Version: *||p')"
  if [[ -n "${VER}" ]]; then
    pass "${ctx} (${VER})"
  else
    fail "cannot reach ${ctx}"
    note "aws eks update-kubeconfig --region ${REGION} --name ${ctx} --alias ${ctx}"
  fi
done

if [[ ${FAILED} -gt 0 ]]; then
  echo
  echo "Stopping: the remaining checks need both clusters."
  exit 1
fi

################################################################################
head2 "The Karpenter controller has somewhere to run"

# This is the check that matters most, because when it is wrong nothing says so. The
# controller is pinned by nodeSelector to karpenter.sh/controller=true, which the managed
# node group carries. If that group scales to zero, the controller goes Pending, no NodeClaim
# is ever created, and every variant sits Pending until bench.sh times out after 25 minutes
# with no error that names the cause.
CTRL_NODES="$(kubectl --context "${KARPENTER_CLUSTER}" get nodes \
  -l "karpenter.sh/controller=true" --no-headers 2>/dev/null | grep -c Ready)"

if [[ "${CTRL_NODES}" -ge 1 ]]; then
  pass "${CTRL_NODES} Ready node(s) labelled karpenter.sh/controller=true"
else
  fail "no Ready node carries karpenter.sh/controller=true"
  note "The Karpenter controller is pinned to that label, so it cannot be scheduled."
  note "Check the managed node group's desired size:"
  note "  aws eks describe-nodegroup --cluster-name ${KARPENTER_CLUSTER} \\"
  note "    --nodegroup-name \$(aws eks list-nodegroups --cluster-name ${KARPENTER_CLUSTER} \\"
  note "    --query 'nodegroups[0]' --output text) --query 'nodegroup.scalingConfig'"
fi

READY_CTRL="$(kubectl --context "${KARPENTER_CLUSTER}" -n kube-system get pods \
  -l app.kubernetes.io/name=karpenter \
  -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
  | grep -c . || true)"
TOTAL_CTRL="$(kubectl --context "${KARPENTER_CLUSTER}" -n kube-system get pods \
  -l app.kubernetes.io/name=karpenter --no-headers 2>/dev/null | grep -c . || true)"

if [[ "${TOTAL_CTRL:-0}" -eq 0 ]]; then
  fail "no Karpenter controller pods exist in kube-system"
elif [[ "${READY_CTRL}" -ge 1 ]]; then
  pass "${READY_CTRL} of ${TOTAL_CTRL} Karpenter controller pod(s) Running"
else
  fail "${TOTAL_CTRL} Karpenter controller pod(s) exist but none are Running"
  kubectl --context "${KARPENTER_CLUSTER}" -n kube-system get pods \
    -l app.kubernetes.io/name=karpenter --no-headers 2>/dev/null | sed 's/^/         /'
fi

################################################################################
head2 "Node pools and node classes"

for pool in baseline snapshot soci; do
  if kubectl --context "${KARPENTER_CLUSTER}" get nodepool "${pool}" >/dev/null 2>&1; then
    TYPES="$(kubectl --context "${KARPENTER_CLUSTER}" get nodepool "${pool}" \
      -o jsonpath='{.spec.template.spec.requirements[?(@.key=="node.kubernetes.io/instance-type")].values[0]}' 2>/dev/null)"
    if [[ "${TYPES}" == "${GPU_INSTANCE_TYPE}" ]]; then
      pass "nodepool ${pool} is pinned to ${TYPES}"
    else
      fail "nodepool ${pool} is pinned to '${TYPES}', but config.env says ${GPU_INSTANCE_TYPE}"
      note "Run bin/prep.sh to re-apply. Variants on different instance types are not comparable."
    fi
  else
    fail "nodepool ${pool} does not exist. Run bin/prep.sh."
  fi
done

if kubectl --context "${AUTOMODE_CLUSTER}" get nodepool automode >/dev/null 2>&1; then
  pass "nodepool automode exists on ${AUTOMODE_CLUSTER}"
else
  fail "nodepool automode does not exist on ${AUTOMODE_CLUSTER}. Run bin/prep.sh."
fi

SNAP="$(kubectl --context "${KARPENTER_CLUSTER}" get ec2nodeclass snapshot \
  -o jsonpath='{.spec.blockDeviceMappings[?(@.deviceName=="/dev/xvdb")].ebs.snapshotID}' 2>/dev/null)"
if [[ -n "${SNAP}" && "${SNAP}" != "@SNAPSHOT_ID@" ]]; then
  pass "the snapshot node class carries a snapshot ID (${SNAP})"
else
  warn "the snapshot node class has no snapshot ID substituted"
  note "Step 2 will pull the image like the baseline until snapshot/build-snapshot.sh has run"
  note "and bin/prep.sh has been re-run."
fi

################################################################################
head2 "Both clusters share one VPC and its subnets"

# If they do not, the image pull path differs between the Karpenter variants and automode,
# and the comparison between them stops meaning anything.
KVPC="$(aws eks describe-cluster --region "${REGION}" --name "${KARPENTER_CLUSTER}" \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text 2>/dev/null)"
AVPC="$(aws eks describe-cluster --region "${REGION}" --name "${AUTOMODE_CLUSTER}" \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text 2>/dev/null)"

if [[ -n "${KVPC}" && "${KVPC}" == "${AVPC}" ]]; then
  pass "both clusters are in ${KVPC}"
else
  fail "the clusters are in different VPCs (${KVPC} and ${AVPC})"
  note "The image pull path would differ, so automode could not be compared with the rest."
fi

################################################################################
head2 "S3 traffic bypasses the NAT gateway"

if [[ -n "${KVPC}" ]]; then
  EP="$(aws ec2 describe-vpc-endpoints --region "${REGION}" \
    --filters "Name=vpc-id,Values=${KVPC}" "Name=service-name,Values=com.amazonaws.${REGION}.s3" \
    --query 'VpcEndpoints[?VpcEndpointType==`Gateway`].VpcEndpointId | [0]' --output text 2>/dev/null)"
  if [[ -n "${EP}" && "${EP}" != "None" ]]; then
    pass "S3 Gateway endpoint ${EP} is attached"
  else
    warn "no S3 Gateway endpoint in ${KVPC}"
    note "Weight downloads and ECR layer downloads will go through the NAT gateway. The"
    note "figures are still valid; the NAT data-processing charge applies."
  fi
fi

################################################################################
head2 "Credentials for the weights bucket"

if [[ -z "${MODEL_BUCKET}" ]]; then
  warn "MODEL_BUCKET is empty in config.env, so phases 2 and 3 cannot run"
  note "terraform -chdir=terraform output -raw model_bucket"
else
  if aws s3api head-bucket --bucket "${MODEL_BUCKET}" >/dev/null 2>&1; then
    OBJECTS="$(aws s3api list-objects-v2 --bucket "${MODEL_BUCKET}" \
      --prefix "${MODEL_PREFIX}/" --query 'length(Contents)' --output text 2>/dev/null)"
    if [[ -n "${OBJECTS}" && "${OBJECTS}" != "None" && "${OBJECTS}" != "0" ]]; then
      pass "${MODEL_BUCKET} holds ${OBJECTS} object(s) under ${MODEL_PREFIX}/"
    else
      warn "${MODEL_BUCKET} has nothing under ${MODEL_PREFIX}/. Run snapshot/stage-model.sh."
    fi
  else
    fail "cannot reach the bucket ${MODEL_BUCKET}"
  fi
fi

# Karpenter sets the IMDS hop limit to 1, so a container cannot reach instance metadata and a
# node role is not usable from a pod. Phases 2 and 3 depend on the association existing.
if kubectl --context "${KARPENTER_CLUSTER}" -n bench get serviceaccount bench >/dev/null 2>&1; then
  ASSOC="$(aws eks list-pod-identity-associations --region "${REGION}" \
    --cluster-name "${KARPENTER_CLUSTER}" --namespace bench --service-account bench \
    --query 'length(associations)' --output text 2>/dev/null)"
  if [[ "${ASSOC:-0}" -ge 1 ]]; then
    pass "the bench service account has an EKS Pod Identity association"
  else
    fail "no Pod Identity association for serviceaccount bench in namespace bench"
    note "Phases 2 and 3 would report 'Unable to locate credentials'. Karpenter sets the IMDS"
    note "hop limit to 1, so the node role cannot be reached from inside a container."
  fi
else
  warn "serviceaccount bench does not exist yet. Run bin/prep.sh."
fi

################################################################################
head2 "Nothing left over from a previous run"

for ctx in "${KARPENTER_CLUSTER}" "${AUTOMODE_CLUSTER}"; do
  # Only pods that still hold a node matter here. A Completed or Failed pod holds nothing,
  # and the staging Job leaves one behind by design until its TTL expires.
  PODS="$(kubectl --context "${ctx}" -n bench get pods \
    --field-selector=status.phase!=Succeeded,status.phase!=Failed \
    --no-headers 2>/dev/null | grep -c . || true)"
  if [[ "${PODS}" == "0" ]]; then
    pass "no running pods in the bench namespace on ${ctx}"
  else
    warn "${PODS} pod(s) still running in bench on ${ctx}, holding GPU nodes"
    kubectl --context "${ctx}" -n bench get pods \
      --field-selector=status.phase!=Succeeded,status.phase!=Failed \
      --no-headers 2>/dev/null | sed 's/^/         /'
    note "kubectl --context ${ctx} -n bench delete pods --all"
  fi
done

CLAIMS="$(kubectl --context "${KARPENTER_CLUSTER}" get nodeclaims --no-headers 2>/dev/null | wc -l | tr -d ' ')"
if [[ "${CLAIMS}" == "0" ]]; then
  pass "no NodeClaims, so every variant starts cold"
else
  warn "${CLAIMS} NodeClaim(s) exist. A cold run needs none for the variant being measured."
  kubectl --context "${KARPENTER_CLUSTER}" get nodeclaims --no-headers 2>/dev/null | sed 's/^/         /'
fi

################################################################################
echo
if [[ ${FAILED} -eq 0 ]]; then
  printf '%s%d failed, %d warning(s).%s\n' "${GREEN}" "${FAILED}" "${WARNED}" "${RESET}"
  echo "The environment is ready. Check capacity as well, shortly before measuring:"
  echo "  bin/check_capacity.sh"
  exit 0
fi

printf '%s%d failed, %d warning(s).%s\n' "${RED}" "${FAILED}" "${WARNED}" "${RESET}"
exit 1
