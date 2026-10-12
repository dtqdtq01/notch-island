# Vibe Island 1.0.53 정적 분석 (REA + Ghidra)

대상: `/Applications/Vibe Island.app` — 번들 `app.vibeisland.macos`, Developer ID `Guorong Luo (CU3QC9CXTJ)`, 공증됨.
목적: 기능 재구현 참고. 라이선스/체험판 로직은 분석하지 않음. 코드·에셋은 가져오지 않음.

## 방법과 한계
| 대상 | 방법 | 결과 |
|---|---|---|
| `Helpers/vibe-island-bridge` (arm64 1.4MB) | REA `open_binary`(Ghidra 12.1.3), overview, swift types, string/procedure search, 디컴파일 | 완료. 함수 5,439 / 문자열 12,821. Swift 심볼 남아 있음 (`VibeIslandShared` 모듈) |
| `MacOS/vibe-island` (arm64 27MB) | REA `inspect_macho`(프레임워크·import), Ghidra 시도 | Ghidra는 REA 타임아웃(330초) 초과로 실패. 내부 심볼 strip됨 → Swift 메타데이터의 타입 이름 242개 + import + 문자열로 구조 파악 |
| Resources | 매니페스트·로컬라이즈 문자열 1,133개 | 완료 |

정적 분석이라 실행 동작을 관찰한 것은 아니다. "추정"으로 표시한 것은 이름·문자열 기반 추론.

## 1. bridge (훅 CLI)
- 응답 형식(디컴파일 확인, `ClaudePermissionDecision.hookOutput`): `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{...}}}` — Notch Island와 동일.
- PreToolUse 형식도 지원: `permissionDecision`, `permissionDecisionReason`, 기본값 `{"decision":"ask"}`.
- 소켓 `~/.vibe-island/run/vibe-island.sock`. 자체 프레이밍(`WirePreamble.magic`, `WireRecordFraming.maxRecordBytes`, `WireFrameKind`, 버전 협상). 큰 이벤트는 선택 필드를 버려 크기 제한에 맞춤("envelope over cap after shedding"). ack 모드 / fire-and-forget / waitForResponse 3가지 전송.
- **세션 입장 필터(SessionIngressAdmissionPolicy)**: 조상 프로세스의 앱 번들 ID와 cwd 패턴으로 세션을 버림. 내장 차단: `com.steipete.codexbar`(사용량 조회용 백그라운드 claude/codex). 사용자 규칙 `admission-rules.json`. 거부 기록 ledger 저장.
- 이벤트 정리: 중복 AskUserQuestion elicitation 제거, 이미 답한 AskUserQuestion의 PreToolUse 억제, `sessionEnd(reason=complete)`는 Stop과 중복이라 무시, `auth_success` 알림 무시, Claude Desktop 안의 중첩 helper 실행 무시, Stop 누락 시 PostToolUse 뒤 Stop 합성, Stop/UserPromptSubmit을 transcript로 보강.
- 권한 조율: "permission owner conflict; yielding to native", "permission defer failed; forwarding immediately" → 여러 소유자(데스크톱 앱 등)가 있을 때 양보.
- 터미널 식별 환경변수: `TERM_PROGRAM, TERM_SESSION_ID, ITERM_SESSION_ID, TMUX_PANE, KITTY_WINDOW_ID/LISTEN_ON, WEZTERM_PANE/UNIX_SOCKET, ZELLIJ_PANE_ID/SESSION_NAME, WARP_FOCUS_URL/SESSION_ID, CMUX_*, ORCA_*, SUPACODE_*, SUPERSET_*, CONDUCTOR_*, T3CODE_*, HERDR_*, OTTY_*, CURSOR_TRACE_ID, WINDOWSERVER_DISPLAY_UUID`.
- **OSC2 제목 마커**: `/dev/tty`에 직접 써서 터미널 제목에 세션 마커를 넣고(`osc2-titles` 캐시) 나중에 AX로 그 제목의 창을 찾음 → Ghostty 등 AppleScript 없는 터미널 정밀 점프. 끄기 `VIBE_ISLAND_OSC2_DISABLE_DIRECT_TTY`.
- 건너뛰기 스위치: `VIBE_ISLAND_SKIP`, `VIBE_ISLAND_PROBE`.
- **사용량**: bridge가 백그라운드 자식으로 사용량 갱신 — `/usr/bin/security`로 키체인의 Claude OAuth 토큰을 읽어 Anthropic 사용량 API 호출, 429·쿨다운·락 파일·계정 변경 감지, 캐시 원자적 쓰기.
- 지원 데이터 소스(파일): `.claude/projects`, Cursor `state.vscdb`, Kiro sqlite, Devin `sessions.db`, Copilot session-state, DeepSeek/Codewhale sessions, Codex memories 등.

## 2. 메인 앱 구성 (타입 이름 기반)
- 노치: `NotchPanel`, `NotchWindowController`, `TileLayoutManager`, `PanelTabRegistry`, `DisplayHoverPolicy`, `DisplayTimerPolicy`, 레이아웃 Clean/Detailed.
- 세션: `SessionStore`, `SessionTerminalStore`, `SessionNamingCoordinator`, `SessionRecapGeneratorEngine`, `QuestionDraftStore`(답변 초안 보존).
- 점프 리졸버: `ItermResolver, GhosttyResolver, KittyResolver, WezTermResolver, WarpResolver, TmuxResolver, ZellijResolver, CmuxResolver, OrcaResolver, SupacodeResolver, SupersetResolver, ConductorResolver, T3CodeResolver, OttyResolver, HyperResolver, BrowserTabResolver, TerminalAppResolver, AppActivationResolver`.
- 시스템 API(import): `CGSCopyManagedDisplaySpaces/CGSCopySpacesForWindows`(Space 이동, 비공개), `CGEventCreateKeyboardEvent/CGEventPostToPid`(특정 앱에 키 입력 합성), `AXObserver`(창 포커스 감시 → 읽음 처리), `CGEventSourceSecondsSinceLastEventType`(유휴 감지), `proc_listallpids/proc_pidfdinfo`(프로세스 테이블), `AEDeterminePermissionToAutomateTarget`(자동화 권한 사전 확인), `RegisterEventHotKey`(Carbon 단축키), `CGWarpMouseCursorPosition`.
- 방해 금지: `QuietSceneDetector`, `ScreenCaptureDetector`(화면 공유·녹화 중 숨김), `ScreenObscuredDetector`, `FocusModeDetector`(집중 모드 종류별).
- 숨김 규칙(`SilenceRulesStore`): 디렉터리 포함 / 첫 프롬프트 시작·포함 패턴, 세션 카드 우클릭으로 추가. 내장: Codex 내부 워커·메모리·Guardian, Claude-Mem 플러그인, Craft 제목 생성기 등.
- 훅 관리: 에이전트별 `*HookInstaller`(Claude/Copilot/Cursor/Gemini/Grok/Kiro/DeepSeek/VSCodeAgent/OpenCode/OpenClaw/Hyper/Dsh), `HookFileWatcher` — 다른 도구가 훅을 지우면 자동 복구, 반복되면 경고.
- IDE 확장: `IDEExtensionInstaller` — VS Code 계열에 "Vibe Island Terminal Focus" 확장 설치(터미널 PID로 정확한 터미널 탭 `show()`), kitty.conf 2줄 추가 배너.
- 데스크톱 앱: Claude Desktop(LevelDB 로컬스토리지 읽기 `ChromiumLevelDBRecordReader`, Cowork 승인), Codex Desktop(`CodexAppServerClient` JSON-RPC, 스레드·읽음 상태).
- 사용량: `UsageLimitService`, 제공자 Claude/Codex/Kimi/Cursor/OpenCode/Pi/MiniMax, `UsageRollupStore`, 대시보드 창.
- 알림: Bark(아이폰 푸시) 전송 — "Return to your Mac to approve".
- Plan 종료 카드: 승인 후 모드 선택(Auto / Bypass / 수동 승인) + 수정 피드백 입력.
- 기타: JavaScriptCore + `highlight.min.js`(diff 문법 강조), Sparkle 업데이트, Sentry, `MainThreadHangDetector`, `MemoryFootprintMonitor`.

## 3. SSH 원격
- 매니페스트 `RemoteAgent/manifest.json`(Ed25519 서명): darwin/linux/freebsd × amd64/arm64 훅 바이너리(약 3MB), `dl.vibeisland.app`에서 원격 서버가 직접 받거나 Mac이 scp.
- 원격 `~/.vibe-island/bin/vibe-island-hook --setup`, `ssh -R`(TCP 포트 역방향) + `ExitOnForwardFailure=yes`, `BatchMode=yes`, ControlMaster/ControlPath(MFA) 지원.

## 4. Notch Island에 반영할 후보 (우선순위)
1. 세션 입장 필터 + 숨김 규칙(앱 번들·cwd·첫 프롬프트) — 백그라운드 claude/codex 소음 제거
2. OSC2 제목 마커로 Ghostty·Warp 정밀 점프, Warp는 `WARP_FOCUS_URL`
3. 화면 공유·녹화·집중 모드 중 팝업 억제
4. 훅 자동 복구(설정 파일 감시)
5. 프로세스 생존 감시로 죽은 세션 정리
6. Plan 카드에 모드 선택 + 피드백 입력, 질문 초안 보존
7. 이벤트 정리 규칙(auth_success 무시, 중복 질문 제거, SessionEnd complete 무시)
8. 키체인 OAuth 사용량 API(상태줄 없이도 사용량), 다른 제공자
9. Space 이동, VS Code 확장으로 정확한 터미널 탭, SSH 원격, Bark 푸시

## 5. 반영 현황
| 항목 | 상태 |
|---|---|
| 1. 세션 입장 필터 + 숨김 규칙 | ✅ bridge가 조상 앱 번들 ID 수집, 앱이 규칙 판단(차단 앱·폴더·첫 프롬프트·TTY 없음), 우클릭 메뉴, 숨김 세션 권한 요청은 터미널로 |
| 2. OSC2 제목 마커 정밀 점프 | ✅ Ghostty·Warp·Alacritty·Hyper·Tabby·Rio·(원격제어 꺼진)kitty, tmux 안에서는 안 씀, Warp는 `WARP_FOCUS_URL` 우선 |
| 3. 방해 금지 | ✅ `CGSIsScreenWatcherPresent`(dlsym, 없으면 감지 안 함) + `~/Library/DoNotDisturb/DB/Assertions.json`(전체 디스크 접근 필요) |
| 4. 훅 자동 복구 | ✅ 5초 폴링, 사용자가 설치한 연동만, 10분 3회 초과 시 중단 |
| 5. 이벤트 정리 | ✅ 프로세스 생존 감시(agent_pid), tool_response 제거·100KB 초과 문자열 자르기, `NOTCH_ISLAND_SKIP`. Stop 합성·중복 질문 제거는 Claude 훅 흐름에서 필요 없어 생략 |
