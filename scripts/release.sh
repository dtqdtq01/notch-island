#!/bin/zsh -e
# 배포용 빌드: Intel+Apple Silicon 공용 앱 → 서명 → ZIP·DMG → dist/
#
#   ./scripts/release.sh            # Info.plist의 버전으로
#   ./scripts/release.sh 1.2.0      # 버전 지정
#
# 서명 (선택):
#   NOTCH_SIGN_IDENTITY="Developer ID Application: 이름 (TEAMID)"  → Developer ID 서명 + Hardened Runtime
#   NOTCH_NOTARY_PROFILE=<notarytool 키체인 프로필>                 → 공증 + 스테이플
#   둘 다 없으면 ad-hoc 서명 (받은 사람은 처음 한 번 '그래도 열기'가 필요)
cd "${0:A:h}/.."
VERSION="${1:-$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
DIST=dist
STAGE="$DIST/stage"
APP="$STAGE/Notch Island.app"

echo "▶ Notch Island $VERSION ($BUILD)"
rm -rf "$DIST" && mkdir -p "$STAGE"

for ARCH in arm64 x86_64; do
  echo "▶ $ARCH 빌드"
  swift build -c release --triple "$ARCH-apple-macosx14.0" >/dev/null
done
ARM=.build/arm64-apple-macosx/release
X86=.build/x86_64-apple-macosx/release

echo "▶ 앱 묶기"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
lipo -create "$ARM/NotchIsland" "$X86/NotchIsland" -output "$APP/Contents/MacOS/NotchIsland"
lipo -create "$ARM/notch-bridge" "$X86/notch-bridge" -output "$APP/Contents/Helpers/notch-bridge"
cp Resources/Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD" "$APP/Contents/Info.plist"
cp Resources/AppIcon/AppIcon.icns "$APP/Contents/Resources/"
cp -R Resources/Fonts Resources/Highlight "$APP/Contents/Resources/"
cp Resources/THIRD_PARTY_NOTICES.txt "$APP/Contents/Resources/"

echo "▶ 서명"
if [[ -n "$NOTCH_SIGN_IDENTITY" ]]; then
  codesign --force --options runtime --timestamp --sign "$NOTCH_SIGN_IDENTITY" "$APP/Contents/Helpers/notch-bridge"
  codesign --force --options runtime --timestamp --sign "$NOTCH_SIGN_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP/Contents/Helpers/notch-bridge"
  codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"

echo "▶ ZIP"
ditto -c -k --keepParent "$APP" "$DIST/NotchIsland-$VERSION.zip"

echo "▶ DMG"
DMGSRC="$DIST/dmg"
mkdir -p "$DMGSRC"
cp -R "$APP" "$DMGSRC/"
ln -s /Applications "$DMGSRC/Applications"
cp Resources/FIRST_OPEN.txt "$DMGSRC/처음 열 때 읽어주세요.txt"
hdiutil create -quiet -volname "Notch Island $VERSION" -srcfolder "$DMGSRC" -ov -format UDZO "$DIST/NotchIsland-$VERSION.dmg"
if [[ -n "$NOTCH_SIGN_IDENTITY" ]]; then
  codesign --force --timestamp --sign "$NOTCH_SIGN_IDENTITY" "$DIST/NotchIsland-$VERSION.dmg"
fi

if [[ -n "$NOTCH_NOTARY_PROFILE" && -n "$NOTCH_SIGN_IDENTITY" ]]; then
  echo "▶ 공증"
  xcrun notarytool submit "$DIST/NotchIsland-$VERSION.dmg" --keychain-profile "$NOTCH_NOTARY_PROFILE" --wait
  xcrun stapler staple "$DIST/NotchIsland-$VERSION.dmg"
fi

rm -rf "$DMGSRC"
(cd "$DIST" && shasum -a 256 NotchIsland-$VERSION.zip NotchIsland-$VERSION.dmg > SHA256SUMS.txt)
echo "✓ $DIST/NotchIsland-$VERSION.dmg"
echo "✓ $DIST/NotchIsland-$VERSION.zip"
echo "✓ $DIST/SHA256SUMS.txt"
