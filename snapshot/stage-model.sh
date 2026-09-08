#!/usr/bin/env bash
#
# Phase 2 pre-work: put model weights in S3 so the workload can stream them at
# startup instead of carrying them in the image.
#
# Run this before the workshop. Downloading from Hugging Face and uploading to S3
# takes a few minutes and is not interesting to watch.
#
# Qwen2.5-1.5B-Instruct by default: ungated, ~3 GB, loads in well under a minute
# on an L4. Big enough that the download stage is visible in the table, small
# enough that the session does not stall on it. Swap MODEL_HF_REPO in config.env
# for something closer to your real weights if you want a realistic download
# stage.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"

# shellcheck source=../config.env
source "${ROOT}/config.env"

if [[ -z "${MODEL_BUCKET}" ]]; then
  echo "MODEL_BUCKET is empty in config.env." >&2
  echo "Set it to: $(terraform -chdir="${ROOT}/terraform" output -raw model_bucket 2>/dev/null || echo '<terraform output -raw model_bucket>')" >&2
  exit 1
fi

STAGING="${STAGING:-/tmp/model-staging/${MODEL_PREFIX}}"

# huggingface_hub 1.x renamed the CLI to `hf`; `huggingface-cli` still resolves but
# refuses to run ("deprecated and no longer works"), so prefer `hf` and fall back
# only for older installs.
if command -v hf >/dev/null 2>&1; then
  HF_CLI="hf"
elif command -v huggingface-cli >/dev/null 2>&1; then
  HF_CLI="huggingface-cli"
else
  echo "neither 'hf' nor 'huggingface-cli' found. pip install --upgrade 'huggingface_hub[cli]'" >&2
  exit 1
fi

echo "==> downloading ${MODEL_HF_REPO} with ${HF_CLI}"
mkdir -p "${STAGING}"
# Safetensors only. The .bin duplicates are the same weights in the older format,
# and pulling both doubles the transfer for nothing.
#
# One --exclude per pattern: the flag takes a single value, and stacking several
# values after one flag makes the CLI read them as *filenames to download* instead.
# It then prints "Ignoring --exclude since filenames have being explicitly set",
# exits 0, and downloads nothing -- a silent no-op that looks like success.
"${HF_CLI}" download "${MODEL_HF_REPO}" \
  --local-dir "${STAGING}" \
  --exclude "*.pth" \
  --exclude "*.bin" \
  --exclude "original/*"

echo "==> staged locally:"
du -sh "${STAGING}"

echo "==> uploading to s3://${MODEL_BUCKET}/${MODEL_PREFIX}/"
aws s3 sync "${STAGING}" "s3://${MODEL_BUCKET}/${MODEL_PREFIX}/" \
  --region "${REGION}" \
  --only-show-errors

echo "==> objects in place:"
aws s3 ls "s3://${MODEL_BUCKET}/${MODEL_PREFIX}/" --region "${REGION}" --human-readable

echo
echo "==> done. bin/bench.sh s3-weights is now runnable."
