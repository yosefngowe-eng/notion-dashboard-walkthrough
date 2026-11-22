#!/usr/bin/env bash
# compress_reel.sh  <input.mp4> <out_dir> [target_mb=12] [--dry-run|--apply]
# Idempotent: skips if the output already exists and is under the ceiling.
set -euo pipefail
in="${1:?input}"; out_dir="${2:?out_dir}"; target_mb="${3:-12}"; mode="${4:---apply}"
mkdir -p "$out_dir"
base="$(basename "${in%.*}")"
# '#' becomes 'n' (a '#' in a URL path is read as a fragment and breaks the video src); other symbols dropped
slug="$(echo "$base" | tr '[:upper:] ' '[:lower:]_' | tr '#' 'n' | tr -cd 'a-z0-9_-')"
out="$out_dir/${slug}.mp4"; poster="$out_dir/${slug}.jpg"

dur="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$in")"
audio_kbps=96
# total kbit budget = MB * 8192 ; leave 5% for container overhead
vkbps="$(python3 - <<PY
dur=float("$dur"); mb=float("$target_mb")
budget=mb*8192*0.95
print(max(300,int(budget/dur-$audio_kbps)))
PY
)"
echo "in=$in dur=${dur}s -> video ${vkbps}k + audio ${audio_kbps}k -> $out"
if [ "$mode" = "--dry-run" ]; then echo "[dry-run] nothing written"; exit 0; fi

if [ -f "$out" ] && [ "$(stat -c%s "$out" 2>/dev/null || stat -f%z "$out")" -lt $((target_mb*1024*1024)) ]; then
  echo "SKIPPED (already under ${target_mb} MB)"; exit 0
fi

# scale to fit inside 720x1280 (keep aspect, pad if needed), 30 fps, two-pass for size accuracy
vf="scale=720:1280:force_original_aspect_ratio=decrease,pad=720:1280:(ow-iw)/2:(oh-ih)/2:black,fps=30,format=yuv420p"
tmp="$(mktemp -d)"
ffmpeg -y -v error -i "$in" -vf "$vf" -c:v libx264 -preset medium -b:v "${vkbps}k" \
  -pass 1 -passlogfile "$tmp/p" -an -f mp4 /dev/null
ffmpeg -y -v error -i "$in" -vf "$vf" -c:v libx264 -preset medium -b:v "${vkbps}k" \
  -pass 2 -passlogfile "$tmp/p" -c:a aac -b:a ${audio_kbps}k -movflags +faststart "$out"
# poster frame at 1.0 s (or 10% in for very short clips)
ffmpeg -y -v error -ss "$(python3 -c "print(min(1.0,float('$dur')*0.1))")" -i "$out" -frames:v 1 -q:v 3 "$poster"
size="$(stat -c%s "$out" 2>/dev/null || stat -f%z "$out")"
echo "CREATED $out ($((size/1024)) KB) + $poster"
rm -rf "$tmp"
