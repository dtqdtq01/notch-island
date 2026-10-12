#!/bin/zsh -e
# 빌드 후 ~/Applications 에 설치하고 실행 (로그인 시 실행을 쓰려면 이 위치가 안정적)
cd "${0:A:h}/.."
./scripts/build-app.sh
pkill -x NotchIsland 2>/dev/null || true
mkdir -p ~/Applications
rm -rf ~/Applications/"Notch Island.app"
cp -R "build/Notch Island.app" ~/Applications/
open ~/Applications/"Notch Island.app"
echo "✓ ~/Applications/Notch Island.app 실행됨"
