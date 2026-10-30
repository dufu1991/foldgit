#!/bin/sh
# 一键生成 4 支成片与封面：sh build.sh [临时目录]
set -e
cd "$(dirname "$0")"
OUT=..
TMP=${1:-$(mktemp -d)}
python3 music.py "$TMP/music.wav"
for lang in zh en; do
  for ratio in 16x9 9x16; do
    node render.mjs --lang $lang --ratio $ratio --out "$TMP/$lang-$ratio.mp4"
    ffmpeg -y -loglevel error -i "$TMP/$lang-$ratio.mp4" -i "$TMP/music.wav" \
      -c:v copy -af "loudnorm=I=-16:TP=-1.5:LRA=11" -c:a aac -b:a 192k -ar 48000 -shortest -movflags +faststart \
      "$OUT/FoldGit-$lang-$ratio.mp4"
    node render.mjs --lang $lang --ratio $ratio --stills 14.2 --outdir "$TMP"
    cp "$TMP/$lang-$ratio-14.20.png" "$OUT/FoldGit-$lang-$ratio-cover.png"
  done
done
