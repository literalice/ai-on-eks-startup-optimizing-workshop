#!/usr/bin/env bash
#
# Confirm the workload image can actually do Run:ai model streaming, before phase 2
# depends on it.
#
#   bin/check_runai.sh
#
# Run this after an variant C run, so the node already has the image and the check is
# a few seconds rather than a cold multi-gigabyte pull. Pinned to the variant C
# nodepool for that reason; if no variant C node exists it will provision one and take
# as long as a cold pull.
#
# The AWS vLLM Deep Learning Container base is documented as bundling
# runai-streamer. This verifies it in the tag actually configured, because the
# failure mode otherwise is a pod that crash-loops during the workshop.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"

# shellcheck source=../config.env
source "${ROOT}/config.env"

POD="runai-check"
CONTEXT="${KARPENTER_CLUSTER}"
MANIFEST="$(mktemp)"
trap 'rm -f "${MANIFEST}"' EXIT

cat > "${MANIFEST}" <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: ${POD}
  namespace: bench
  labels:
    app: runai-check
    workshop-variant: soci
spec:
  restartPolicy: Never
  nodeSelector:
    workshop-variant: soci
  tolerations:
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule
  containers:
    - name: check
      image: "${WORKLOAD_IMAGE}"
      imagePullPolicy: IfNotPresent
      command: ["python3", "-c"]
      args:
        - |
          import importlib, json
          out = {}
          for mod in ("runai_model_streamer", "runai_model_streamer_s3"):
              try:
                  importlib.import_module(mod)
                  out[mod] = "present"
              except Exception as exc:
                  out[mod] = f"MISSING ({type(exc).__name__})"
          try:
              from vllm.config import LoadFormat
              out["vllm_runai_load_format"] = "runai_streamer" in [f.value for f in LoadFormat]
          except Exception as exc:
              out["vllm_runai_load_format"] = f"could not check ({type(exc).__name__})"
          print(json.dumps(out, indent=2))
      resources:
        requests:
          nvidia.com/gpu: 1
        limits:
          nvidia.com/gpu: 1
YAML

echo "==> checking ${WORKLOAD_IMAGE}"
kubectl --context "${CONTEXT}" -n bench delete pod "${POD}" --ignore-not-found --wait=true >/dev/null 2>&1 || true
kubectl --context "${CONTEXT}" apply -f "${MANIFEST}" >/dev/null

echo "    waiting for the pod to finish (cold pull can take several minutes)"
for _ in $(seq 1 180); do
  phase="$(kubectl --context "${CONTEXT}" -n bench get pod "${POD}" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo Pending)"
  [[ "${phase}" == "Succeeded" || "${phase}" == "Failed" ]] && break
  sleep 5
done

echo
kubectl --context "${CONTEXT}" -n bench logs "${POD}" 2>&1 | sed 's/^/    /'
echo

if kubectl --context "${CONTEXT}" -n bench logs "${POD}" 2>/dev/null | grep -q MISSING; then
  echo "!!! runai-streamer is not in this image. Phase 2's runai-local and runai-s3"
  echo "    variants will fail. Add to a derived image:"
  echo "      RUN pip install runai-model-streamer runai-model-streamer-s3"
  RC=1
else
  echo "==> Run:ai streaming is available"
  RC=0
fi

kubectl --context "${CONTEXT}" -n bench delete pod "${POD}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
exit "${RC}"
