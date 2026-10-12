# Notch Island (MVP)

Claude Code 세션을 맥 노치에 띄우고, 권한 요청을 노치에서 바로 승인/거부하는 앱.

```
Claude Code 훅 → notch-bridge (stdin JSON) → ~/.notch-island/run/notch.sock → NotchIsland.app
                       ↑ PermissionRequest만 앱의 결정을 기다렸다가 stdout으로 반환
```

## 빌드
```sh
./scripts/build-app.sh          # build/Notch Island.app + ~/.notch-island/bin/notch-bridge
open "build/Notch Island.app"
```

## 훅 연결
```sh
# 임시 테스트 (settings.json 안 건드림)
python3 scripts/hooks.py print > /tmp/notch-hooks.json
claude --settings /tmp/notch-hooks.json

# 상시 설치 / 제거 (자동 백업)
python3 scripts/hooks.py install
python3 scripts/hooks.py uninstall
```

앱이 꺼져 있으면 bridge는 아무 출력 없이 끝나서 Claude가 평소처럼 터미널에서 묻는다.
터미널에서 먼저 답하면 노치 카드는 자동으로 사라진다.

## 구조
- `Sources/NotchShared` — 소켓 경로, 줄 단위 프로토콜
- `Sources/notch-bridge` — 훅 CLI
- `Sources/NotchIsland` — 소켓 서버, 세션 상태, 노치 패널(SwiftUI)

## 다음 단계
4. 터미널 점프 (iTerm2/Terminal AppleScript, tmux)
5. 전역 단축키, 사운드, 사용량
