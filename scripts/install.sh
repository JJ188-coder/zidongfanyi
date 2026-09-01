#!/bin/zsh
set -euo pipefail
ROOT=${0:A:h:h}
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
