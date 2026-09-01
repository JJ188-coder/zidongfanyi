#!/bin/zsh
set -euo pipefail
ROOT=${0:A:h:h}
cd "$ROOT"
swift build -c release --product Lecture
BIN_DIR=$(swift build -c release --show-bin-path)
APP="$ROOT/dist/Lecture.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Lecture" "$APP/Contents/MacOS/Lecture"
cp -R "$BIN_DIR/Lecture_LectureApp.bundle" "$APP/Contents/Resources/Lecture_LectureApp.bundle"
WHISPER_CLI="/opt/homebrew/bin/whisper-cli"
WHISPER_PREFIX="/opt/homebrew/opt/whisper-cpp"
GGML_PREFIX="/opt/homebrew/opt/ggml"
LIBOMP_PREFIX="/opt/homebrew/opt/libomp"
if [[ ! -x "$WHISPER_CLI" || ! -f "$WHISPER_PREFIX/lib/libwhisper.1.dylib" \
      || ! -f "$GGML_PREFIX/lib/libggml.0.dylib" \
      || ! -f "$GGML_PREFIX/lib/libggml-base.0.dylib" \
      || ! -f "$LIBOMP_PREFIX/lib/libomp.dylib" ]]; then
  echo "Missing the local whisper-cpp runtime" >&2
  exit 1
fi
cp "$WHISPER_CLI" "$APP/Contents/MacOS/whisper-cli"
chmod 755 "$APP/Contents/MacOS/whisper-cli"
codesign --remove-signature "$APP/Contents/MacOS/whisper-cli" 2>/dev/null || true
RUNTIME="$APP/Contents/Resources/WhisperRuntime"
mkdir -p "$RUNTIME/lib" "$RUNTIME/libexec"
cp "$WHISPER_PREFIX/lib/libwhisper.1.dylib" "$RUNTIME/lib/libwhisper.1.dylib"
cp "$GGML_PREFIX/lib/libggml.0.dylib" "$RUNTIME/lib/libggml.0.dylib"
cp "$GGML_PREFIX/lib/libggml-base.0.dylib" "$RUNTIME/lib/libggml-base.0.dylib"
cp "$LIBOMP_PREFIX/lib/libomp.dylib" "$RUNTIME/lib/libomp.dylib"
cp "$GGML_PREFIX/libexec/libggml-blas.so" "$RUNTIME/libexec/libggml-blas.so"
cp "$GGML_PREFIX/libexec/libggml-metal.so" "$RUNTIME/libexec/libggml-metal.so"
CPU_BACKENDS=($GGML_PREFIX/libexec/libggml-cpu-apple_*.so(N))
if [[ ${#CPU_BACKENDS[@]} -eq 0 ]]; then
  echo "Missing the local ggml CPU backend" >&2
  exit 1
fi
for backend in $CPU_BACKENDS; do
  cp "$backend" "$RUNTIME/libexec/${backend:t}"
done
chmod u+w "$APP/Contents/MacOS/whisper-cli" "$RUNTIME/lib/"* "$RUNTIME/libexec/"*
install_name_tool -change /opt/homebrew/opt/ggml/lib/libggml.0.dylib @rpath/libggml.0.dylib "$APP/Contents/MacOS/whisper-cli"
install_name_tool -change /opt/homebrew/opt/ggml/lib/libggml-base.0.dylib @rpath/libggml-base.0.dylib "$APP/Contents/MacOS/whisper-cli"
install_name_tool -id @rpath/libwhisper.1.dylib "$RUNTIME/lib/libwhisper.1.dylib"
install_name_tool -change /opt/homebrew/opt/whisper-cpp/lib/libwhisper.1.dylib @rpath/libwhisper.1.dylib "$RUNTIME/lib/libwhisper.1.dylib"
install_name_tool -change /opt/homebrew/opt/ggml/lib/libggml.0.dylib @rpath/libggml.0.dylib "$RUNTIME/lib/libwhisper.1.dylib"
install_name_tool -change /opt/homebrew/opt/ggml/lib/libggml-base.0.dylib @rpath/libggml-base.0.dylib "$RUNTIME/lib/libwhisper.1.dylib"
install_name_tool -id @rpath/libggml.0.dylib "$RUNTIME/lib/libggml.0.dylib"
install_name_tool -id @rpath/libggml-base.0.dylib "$RUNTIME/lib/libggml-base.0.dylib"
install_name_tool -change /opt/homebrew/opt/libomp/lib/libomp.dylib @rpath/libomp.dylib "$RUNTIME/lib/libggml-base.0.dylib"
install_name_tool -id @rpath/libomp.dylib "$RUNTIME/lib/libomp.dylib"
for backend in "$RUNTIME"/libexec/libggml-cpu-apple_*.so; do
  install_name_tool -change /opt/homebrew/opt/libomp/lib/libomp.dylib @rpath/libomp.dylib "$backend"
done
for library in "$RUNTIME/lib/"* "$RUNTIME/libexec/"*; do
  codesign --remove-signature "$library" 2>/dev/null || true
  codesign --force --sign - "$library" >/dev/null
done
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Lecture</string>
  <key>CFBundleDisplayName</key><string>Lecture</string>
  <key>CFBundleIdentifier</key><string>com.jiyuanyi.Lecture</string>
  <key>CFBundleExecutable</key><string>Lecture</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.4</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Lecture 使用麦克风在本机录制课堂并实时识别英文。</string>
</dict></plist>
PLIST
codesign \
  --force \
  --sign - \
  --identifier com.jiyuanyi.Lecture.whisper-cli \
  --requirements '=designated => identifier "com.jiyuanyi.Lecture.whisper-cli"' \
  "$APP/Contents/MacOS/whisper-cli" >/dev/null
codesign \
  --force \
  --sign - \
  --requirements '=designated => identifier "com.jiyuanyi.Lecture"' \
  "$APP" >/dev/null
echo "$APP"
