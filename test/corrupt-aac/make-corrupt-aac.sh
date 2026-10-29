#!/usr/bin/env bash
# Build a short H.264 + AAC MPEG-TS file with one truncated AAC frame.
# The ADTS length field is left unchanged so the decoder sees
# "Input buffer exhausted before END element found" / AVERROR_INVALIDDATA.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$DIR/corrupt-aac.ts}"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

echo "Generating valid H.264+AAC clip..."
ffmpeg -y -hide_banner -loglevel error \
  -f lavfi -i testsrc2=size=320x180:rate=25 \
  -f lavfi -i sine=frequency=440:sample_rate=48000 \
  -c:v libx264 -pix_fmt yuv420p -preset ultrafast -tune zerolatency \
  -c:a aac -b:a 128k -ac 2 -ar 48000 \
  -t 3 -shortest \
  -f mpegts "$WORKDIR/valid.ts"

echo "Extracting ADTS AAC..."
ffmpeg -y -hide_banner -loglevel error \
  -i "$WORKDIR/valid.ts" -map 0:a:0 -c copy -f adts "$WORKDIR/audio.aac"

echo "Truncating one AAC payload (keeping ADTS length field)..."
python3 - "$WORKDIR/audio.aac" "$WORKDIR/audio-corrupt.aac" <<'PY'
import sys

src, dst = sys.argv[1], sys.argv[2]
data = open(src, "rb").read()
out = bytearray()
i = 0
frame_idx = 0
corrupted = False

while i + 7 <= len(data):
    if data[i] != 0xFF or (data[i + 1] & 0xF0) != 0xF0:
        i += 1
        continue
    hdr_len = 7 if (data[i + 1] & 0x01) else 9
    frame_len = ((data[i + 3] & 0x03) << 11) | (data[i + 4] << 3) | ((data[i + 5] & 0xE0) >> 5)
    if frame_len < hdr_len or i + frame_len > len(data):
        sys.exit("invalid ADTS frame at offset %d" % i)
    frame = bytearray(data[i : i + frame_len])
    # Skip the first few frames (codec config / small frames), then truncate.
    if not corrupted and frame_idx >= 8 and frame_len > hdr_len + 24:
        keep = hdr_len + max(8, (frame_len - hdr_len) // 3)
        frame = frame[:keep]
        corrupted = True
        print("  corrupted ADTS frame %d: header claims %d bytes, payload now %d"
              % (frame_idx, frame_len, len(frame)))
    out.extend(frame)
    i += frame_len
    frame_idx += 1

if not corrupted:
    sys.exit("could not find an AAC frame large enough to truncate")

open(dst, "wb").write(out)
PY

echo "Remuxing video + corrupt audio..."
ffmpeg -y -hide_banner -loglevel error \
  -i "$WORKDIR/valid.ts" -i "$WORKDIR/audio-corrupt.aac" \
  -map 0:v:0 -map 1:a:0 -c copy -f mpegts "$OUT"

echo "Wrote $OUT"
echo
echo "Standalone decode (expect an AAC error; ffmpeg should continue):"
ffmpeg -v warning -i "$OUT" -f null - || true
