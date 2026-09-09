#!/usr/bin/env bash
#
# Record bin/demo.sh to an mp4.
#
#   bin/record.sh [--quick] [--rehearse]
#
# Pipeline: asciinema records the terminal session, agg renders it to a gif, and
# ffmpeg turns that into an mp4. Terminal-native capture rather than a screen
# grab, so the text is crisp at any size and the cast file stays as a re-renderable
# source.
#
# --rehearse runs against fixture data via a fake kubectl, so the format can be
# reviewed without touching AWS. A rehearsal mp4 is watermarked in its filename;
# do not hand one over as a measurement.
#
# On idle compression: asciinema is given --idle-time-limit, which caps dead air
# in *playback*. A six-minute image pull becomes a couple of seconds of video. The
# elapsed times printed on screen are the real ones and are not touched -- only the
# waiting between them is shortened. Worth saying out loud if you show this to
# someone, because a viewer will otherwise read the pace as the measurement.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"

QUICK=""
REHEARSE=false
for arg in "$@"; do
  case "${arg}" in
    --quick) QUICK="--quick" ;;
    --rehearse) REHEARSE=true ;;
    *) echo "unknown argument: ${arg}" >&2; exit 2 ;;
  esac
done

for tool in asciinema agg ffmpeg; do
  command -v "${tool}" >/dev/null 2>&1 || { echo "missing: ${tool}" >&2; exit 1; }
done

OUTDIR="${ROOT}/recording"
mkdir -p "${OUTDIR}"

TS="$(date -u +%Y%m%dT%H%M%SZ)"
TAG="demo"
[[ "${REHEARSE}" == true ]] && TAG="REHEARSAL-fixture-data"
[[ -n "${QUICK}" ]] && TAG="${TAG}-quick"

CAST="${OUTDIR}/${TAG}-${TS}.cast"
GIF="${OUTDIR}/${TAG}-${TS}.gif"
MP4="${OUTDIR}/${TAG}-${TS}.mp4"

# 108x32 is a good compromise: wide enough that the stage tables do not wrap, small
# enough that the text stays legible when the video is scaled down.
COLS="${DEMO_COLS:-108}"
ROWS="${DEMO_ROWS:-32}"

# Idle capping is matched to the narration beat rather than set shorter. A shorter
# cap would compress the reading pauses too, and the narration would scroll past
# faster than anyone can read it. At this value the paragraphs hold for their full
# beat while a six-minute image pull collapses to the same few seconds.
BEAT="${DEMO_BEAT:-5}"
IDLE="${DEMO_IDLE:-${BEAT}}"
export DEMO_BEAT="${BEAT}"

echo "==> recording to ${CAST}"
echo "    ${COLS}x${ROWS}, narration beat ${BEAT}s, idle capped at ${IDLE}s"

RECORD_CMD="${HERE}/demo.sh ${QUICK}"
if [[ "${REHEARSE}" == true ]]; then
  echo "    REHEARSAL: fixture data via fake kubectl, no AWS calls"
  RECORD_CMD="${HERE}/rehearse.sh ${QUICK}"
fi

# --idle-time-limit compresses waiting, not the printed measurements.
# --overwrite so a re-run of the same second does not fail.
# --window-size, not --cols/--rows. asciinema 3.x renamed them and still accepts the old
# flags without applying them, so passing --cols 108 --rows 32 produces a cast recorded at
# the default 80x24 and exits 0. Check the cast header if a table wraps unexpectedly.
env COLUMNS="${COLS}" LINES="${ROWS}" TERM=xterm-256color \
  asciinema rec \
    --overwrite \
    --idle-time-limit "${IDLE}" \
    --window-size "${COLS}x${ROWS}" \
    --command "${RECORD_CMD}" \
    "${CAST}"

echo
echo "==> rendering gif"
# font-size 24 puts the frame near 1200x900. Rendering large and letting the viewer
# scale down keeps the text crisp; rendering small and scaling up does not.
agg \
  --font-size "${DEMO_FONT_SIZE:-24}" \
  --theme asciinema \
  --speed 1.0 \
  "${CAST}" "${GIF}"

echo "==> encoding mp4"
# yuv420p and even dimensions: required for the file to play in QuickTime, Slack
# previews and PowerPoint. Without the scale filter an odd pixel dimension makes
# libx264 fail outright.
ffmpeg -y -loglevel error \
  -i "${GIF}" \
  -movflags +faststart \
  -pix_fmt yuv420p \
  -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2" \
  -c:v libx264 \
  -crf 20 \
  "${MP4}"

echo
echo "==> done"
ls -lh "${CAST}" "${GIF}" "${MP4}" | awk '{printf "    %-10s %s\n", $5, $9}'
echo
echo "    duration: $(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "${MP4}" 2>/dev/null | cut -d. -f1)s"
echo "    replay in the terminal: asciinema play ${CAST}"
