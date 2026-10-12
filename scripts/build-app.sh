#!/bin/zsh -e
# release 빌드 → build/Notch Island.app 생성, bridge를 ~/.notch-island/bin 에 설치
cd "${0:A:h}/.."
swift build -c release
BIN="$(swift build -c release --show-bin-path)"
APP="build/Notch Island.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers"
cp Resources/Info.plist "$APP/Contents/"
cp "$BIN/NotchIsland" "$APP/Contents/MacOS/"
cp "$BIN/notch-bridge" "$APP/Contents/Helpers/"
mkdir -p "$APP/Contents/Resources/Fonts"
cp Resources/Fonts/* "$APP/Contents/Resources/Fonts/"
mkdir -p "$APP/Contents/Resources/Highlight"
cp Resources/Highlight/* "$APP/Contents/Resources/Highlight/"
codesign --force --deep --sign - "$APP" >/dev/null

mkdir -p ~/.notch-island/bin
cp "$BIN/notch-bridge" ~/.notch-island/bin/notch-bridge
chmod 755 ~/.notch-island/bin/notch-bridge
echo "✓ $APP"
echo "✓ ~/.notch-island/bin/notch-bridge"
