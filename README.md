# Notch Island

Claude Code·Codex 세션을 맥 노치에 띄우고, 권한 요청·질문·계획 승인을 노치에서 처리하고,
클릭 한 번에 해당 터미널로 돌아가는 앱. (Vibe Island의 기능을 처음부터 다시 구현한 무료 대안)

## 설치
```sh
./scripts/install.sh      # 빌드 → ~/Applications/Notch Island.app → 실행
```
처음 실행하면 설정의 **연동** 탭이 열린다 → Claude Code / Codex "설치", Claude 상태줄 "설치".
Vibe Island 훅이 남아 있으면 같은 화면에서 제거할 수 있다 (둘 다 켜져 있으면 요청을 동시에 잡음).

## 기능
| 영역 | 내용 |
|---|---|
| 노치 | 세션 상태 점·개수, hover/클릭 펼침, 전체화면·유휴 시 숨김, 완료/오류/사용량 알림 카드 |
| 승인 | 한 번 허용 / 항상 허용(제안 규칙 적용) / 거부 / 터미널에서 답하기, diff 미리보기, 모두 허용 |
| 질문 | AskUserQuestion 단일·다중 선택, 직접 입력, 여러 문항 마법사 |
| 계획 | ExitPlanMode 계획 미리보기, 승인 / 승인+자동 편집 / 계속 계획 |
| 점프 | iTerm2·Terminal(tty 정확 매칭), tmux 패널, kitty, WezTerm, VS Code·Cursor·Windsurf·Zed(폴더 창), 그 외 앱 활성화 + 손쉬운 사용 권한 시 창 제목 매칭 |
| 단축키 | 세션 스위처(⌥⌘I, ↑↓/Tab/1~9/Enter/Esc), 허용 ⌥⌘Y, 거부 ⌥⌘N, 급한 세션 점프 ⌥⌘J — 설정에서 변경 |
| 사운드 | 이벤트 9종, 시스템 사운드 선택, 볼륨, 조용한 시간, `~/.notch-island/sounds/<이벤트>.wav` 커스텀 |
| 사용량 | 5시간/7일 한도 게이지(상태줄 연동), 경고선 알림, 로컬 로그 기반 비용·토큰 대시보드(모델별·일별) |
| 기타 | 모델·컨텍스트%·서브에이전트 표시, 메뉴바 세션 목록, 로그인 시 실행 |

## 구조
```
에이전트 훅 → notch-bridge (stdin JSON + 터미널 정보) → ~/.notch-island/run/notch.sock → 앱
                  ↑ PermissionRequest만 앱의 결정을 기다렸다가 stdout으로 반환
Claude statusLine → notch-bridge --statusline → 모델/컨텍스트/사용 한도 (기존 statusLine은 이어서 실행)
```
앱이 꺼져 있거나 "터미널에서"를 누르면 bridge는 아무것도 출력하지 않고 끝나서 에이전트가 평소처럼 터미널에서 묻는다.

- `Sources/notch-bridge` — 훅 CLI (터미널 tty·환경변수 수집, statusLine 모드)
- `Sources/NotchIsland` — 소켓 서버, 세션 상태, 노치 UI, 점프, 단축키, 사운드, 사용량, 설정, 연동
- `Tests/` — `./scripts/test.sh` (Xcode 없이 Swift Testing)

## 아직 없는 것
OpenCode·Gemini 등 다른 에이전트, SSH 원격 세션, Claude OAuth 사용량 API(상태줄 방식만 지원), 펼침 애니메이션
