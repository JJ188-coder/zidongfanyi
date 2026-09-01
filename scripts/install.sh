#!/bin/zsh
set -euo pipefail
ROOT=${0:A:h:h}
SUPPORT="$HOME/Library/Application Support/Lecture"
WHISPER_DIR="$SUPPORT/Whisper"
VAD_MODEL="$WHISPER_DIR/ggml-silero-v6.2.0.bin"
VAD_SHA256="2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987"
QUALITY_MODEL="$WHISPER_DIR/ggml-small.en.bin"
QUALITY_SHA256="c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d"
mkdir -p "$WHISPER_DIR"
chmod 700 "$SUPPORT" "$WHISPER_DIR"
if [[ ! -f "$VAD_MODEL" ]] || [[ "$(shasum -a 256 "$VAD_MODEL" | awk '{print $1}')" != "$VAD_SHA256" ]]; then
  TEMP_VAD="$VAD_MODEL.download.$$"
  rm -f "$TEMP_VAD"
  curl --fail --location --retry 3 --output "$TEMP_VAD" \
    "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin"
  [[ "$(shasum -a 256 "$TEMP_VAD" | awk '{print $1}')" == "$VAD_SHA256" ]] || { rm -f "$TEMP_VAD"; echo "Invalid Silero VAD model checksum" >&2; exit 1; }
  chmod 600 "$TEMP_VAD"
  mv "$TEMP_VAD" "$VAD_MODEL"
fi
chmod 600 "$VAD_MODEL"
if [[ ! -f "$QUALITY_MODEL" ]] || [[ "$(shasum -a 256 "$QUALITY_MODEL" | awk '{print $1}')" != "$QUALITY_SHA256" ]]; then
  TEMP_QUALITY="$QUALITY_MODEL.download.$$"
  curl --fail --location --retry 3 --output "$TEMP_QUALITY" \
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin"
  [[ "$(shasum -a 256 "$TEMP_QUALITY" | awk '{print $1}')" == "$QUALITY_SHA256" ]] || { rm -f "$TEMP_QUALITY"; echo "Invalid Whisper small.en model checksum" >&2; exit 1; }
  chmod 600 "$TEMP_QUALITY"
  mv "$TEMP_QUALITY" "$QUALITY_MODEL"
fi
chmod 600 "$QUALITY_MODEL"
"$ROOT/scripts/build-app.sh" >/dev/null
pkill -x Lecture 2>/dev/null || true
STAGED="/Applications/.Lecture.app.new.$$"
BACKUP="/Applications/.Lecture.app.previous.$$"
rm -rf "$STAGED" "$BACKUP"
cp -R "$ROOT/dist/Lecture.app" "$STAGED"
if [[ -d /Applications/Lecture.app ]]; then
  mv /Applications/Lecture.app "$BACKUP"
fi
mv "$STAGED" /Applications/Lecture.app
rm -rf "$BACKUP"
if [[ -n "${LECTURE_DEEPSEEK_API_KEY:-}" ]]; then
  KEY_DIR="$HOME/Library/Application Support/Lecture"
  mkdir -p "$KEY_DIR"
  umask 077
  printf %s "$LECTURE_DEEPSEEK_API_KEY" > "$KEY_DIR/.pending-deepseek-key"
fi
open /Applications/Lecture.app
echo /Applications/Lecture.app
