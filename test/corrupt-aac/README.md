# Corrupt AAC reproduction

Generator for the FFmpeg producer decoder bug: one truncated AAC ADTS
frame (`Input buffer exhausted before END element found` /
`AVERROR_INVALIDDATA` from `avcodec_send_packet`) while video stays valid.

## Generate

```bash
./make-corrupt-aac.sh
# optional output path:
./make-corrupt-aac.sh /tmp/corrupt-aac.ts
```

Requires `ffmpeg` and `python3`. The generated `.ts` is not committed.

## Standalone ffmpeg

```bash
ffmpeg -v warning -i corrupt-aac.ts -f null -
```

Expected: an AAC decoder error such as
`Error submitting packet to decoder: Invalid data found when processing input`
(same class as `Input buffer exhausted before END element found`). ffmpeg
itself usually continues and finishes the file.

## CasparCG

Copy `corrupt-aac.ts` into the media folder, then:

```
PLAY 1-1 "corrupt-aac"
```

Or push the same file over RTMP into an ingest.

**Before the fix** (`Decoder` throws on `avcodec_send_packet` in
`src/modules/ffmpeg/producer/av_producer.cpp`):

- Exception logged, decoder `eof = true`
- Video continues; audio ratchets then goes silent

**After the fix** (`fix/ffmpeg-producer-skip-bad-packets`):

```
[warning] av_producer[decoder] audio avcodec_send_packet failed (...): ...; skipping packet and flushing audio decoder
```

Audio keeps playing after that single warning.
