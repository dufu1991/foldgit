#!/bin/sh
# 一键生成 4 支成片与封面：EARSHOT_PY=装好 earshot 的 python sh build.sh [临时目录]
set -e
cd "$(dirname "$0")"
OUT=..
TMP=${1:-$(mktemp -d)}
EARSHOT_PY=${EARSHOT_PY:-python3}
python3 glassmaps.py
python3 music.py "$TMP/bed.wav"
"$EARSHOT_PY" -I sfx_earshot.py "$TMP/bed.wav" "$TMP/music.wav" "$TMP/earshot"
for lang in zh en; do
  for ratio in 16x9 9x16; do
    node render.mjs --lang $lang --ratio $ratio --out "$TMP/$lang-$ratio.mp4"
    ffmpeg -y -loglevel error -i "$TMP/$lang-$ratio.mp4" -i "$TMP/music.wav" \
      -c:v copy -af "loudnorm=I=-16:TP=-1.5:LRA=11" -c:a aac -b:a 192k -ar 48000 -shortest -movflags +faststart \
      "$OUT/FoldGit-$lang-$ratio.mp4"
    node render.mjs --lang $lang --ratio $ratio --stills 10.6 --outdir "$TMP"
    cp "$TMP/$lang-$ratio-10.60.png" "$OUT/FoldGit-$lang-$ratio-cover.png"
  done
done
