# YumYum Local Agents and Quick Menu

YumYum은 macOS 플로팅 펫에서 로컬 Hermes, OpenCode, Codex, Claude Code를 선택해 화면 캡처, 대화 텍스트, 파일을 전달하는 Swift/AppKit 앱이다. 외부 패키지나 shell, `which`, 홈 디렉터리 재귀 검색을 사용하지 않는다.

## 요구 환경

- macOS 14 이상
- Swift 6.0 이상
- XCTest를 포함한 Xcode 또는 정상 설치된 Command Line Tools

## 빌드와 실행

```sh
swift build
swift test
./scripts/build-app.sh
open .build/YumYum.app
```

현재 머신처럼 독립 Command Line Tools에서 `Testing` 모듈 검색 경로가 자동 설정되지 않으면 다음 명령으로 전체 회귀 테스트를 실행한다.

```sh
swift test \
  -Xswiftc -F \
  -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath \
  -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath \
  -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

`scripts/build-app.sh`는 기본적으로 release 설정의 `.build/YumYum.app`을 만든다. debug 번들은 `CONFIGURATION=debug ./scripts/build-app.sh`로 만든다. 로컬 개발 번들이며 배포 서명과 공증은 하지 않는다.

## 에이전트 발견과 선택

앱 시작, `다시 검색`, 빠른 메뉴 열기, 전송 직전에 다음 항목을 다시 확인한다.

- 고정된 안전 후보 디렉터리의 직접 자식만 검사
- 사용자가 입력한 정확한 절대 경로 검사
- 일반 파일과 실행 권한 확인
- 정확한 실행 파일 URL에 `--version`과 에이전트별 `--help` argv를 직접 전달
- 2초 제한, 최소 환경, stdout+stderr 합산 64KB 상한 적용
- 버전과 로컬 CLI 계약이 모두 확인된 설치만 선택 가능

기본 후보는 `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, `~/.opencode/bin`, `~/.claude/local`, `~/.bun/bin`이다. 디렉터리를 재귀 탐색하거나 현재 `PATH`에서 임의 후보를 찾지 않는다.

설정에는 발견된 모든 정의의 상태, 정확한 경로, 버전이 표시된다. 저장하는 에이전트 정보는 다음 두 값뿐이다.

- 정의 ID
- 사용자가 선택한 정확한 실행 경로

선택한 경로가 사라지거나 검증에 실패하면 전송을 즉시 막는다. 같은 정의의 다른 설치로 자동 폴백하지 않으며, 기존 경로가 다시 나타나도 사용자가 명시적으로 다시 선택해야 한다.

## 로컬 Connector

각 Connector는 설치된 CLI의 로컬 도움말에서 확인한 전용 계약만 사용한다.

| 에이전트 | 실행 계약 | 첨부 처리 |
|---|---|---|
| Hermes | `hermes acp`와 ACP v1 | `resource_link`; 모든 권한 요청은 승인 전 `cancelled` |
| OpenCode | `opencode run --pure --format default` | 확인된 `--file` argv |
| Codex | `codex --ask-for-approval untrusted exec --ephemeral --sandbox read-only --skip-git-repo-check` | 이미지만 확인된 `--image`; 나머지는 선택 경로를 사용자 표시 프롬프트에 명시 |
| Claude Code | `claude --safe-mode --print --output-format text --permission-mode plan --no-session-persistence` | 선택 경로를 사용자 표시 프롬프트에 명시 |

Hermes의 설치된 로컬 도움말에서 ACP 계약을 확인할 수 없으면 one-shot이나 임의 프로토콜로 대체하지 않고 사용 불가 이유를 표시한다. 모든 프로세스는 shell 없이 실행되며 120초 제한과 stdout+stderr 합산 2MB 상한을 사용한다.

YumYum은 Keychain, 토큰, 로그인 파일을 읽거나 복사하지 않는다. 실행된 CLI 자체의 기존 로그인 상태와 내부 동작은 해당 CLI의 책임이다.

## 빠른 메뉴

- 펫 클릭 또는 기본 전역 단축키 `Control+Option+Space`
- 설정에서 제공하는 네이티브 단축키 선택지로 변경 가능
- 비활성 AppKit 말풍선 패널로 열어 불필요하게 현재 앱 포커스를 가져오지 않음
- `화면 캡처`: ScreenCaptureKit 시스템 선택기 사용
- `파일 선택`: NSOpenPanel에서 이미지, PDF, 일반 텍스트, 소스 파일 다중 선택
- `대화`: 텍스트 입력 후 Return 또는 `보내기`

파일은 각각 최대 20MB다. 폴더, symlink, 미지원 확장자, 자격증명으로 식별되는 파일은 거부한다. 빈 텍스트, 선택 취소, 캡처 권한 거부, 미지원·초과 파일, 에이전트 미선택은 `PromptRequest`를 만들거나 보내지 않는다.

유효한 입력은 펫의 입 열기, 미리보기 칩 이동, 입 닫기 순서 뒤 공통 `PromptRequest`로 정확히 한 번 전달된다. Reduce Motion에서는 이동을 생략하고 상태 텍스트와 입 상태는 유지한다. 임시 캡처는 성공, 실패, 취소, busy 거절 후 삭제하며 비정상 종료로 남은 `YumYum-Capture-*` 파일은 다음 앱 시작 시 삭제한다.

펫 드래그와 다중 디스플레이 보정은 기존 동작을 유지한다. 말풍선도 펫이 있는 디스플레이의 `visibleFrame` 안으로 보정된다.

## 외부 변경 안전 경계

외부 상태를 바꾸는 작업은 현재 Connector에서 실행하지 않으며 Hermes ACP 권한 요청은 `cancelled`로 응답한다. Core의 `TaskApprovalGate`는 Task ID, approval ID, toolset ID에 묶인 메모리 내 일회성 승인 원칙만 검증한다. 빠른 메뉴의 승인 UI와 Connector 실행 흐름에는 아직 연결되지 않았다.

## 수동 확인 항목

플랫폼 UI는 자동화 테스트 대신 실제 macOS에서 다음을 확인한다.

1. 펫 클릭과 `Control+Option+Space`가 펫 옆 패널을 열고 다른 앱의 포커스를 불필요하게 가져오지 않는지
2. ScreenCaptureKit 선택, 취소, 화면 기록 권한 거부가 각각 올바른 상태를 표시하는지
3. NSOpenPanel 다중 선택과 20MB/형식 제한이 동작하는지
4. VoiceOver가 펫, 에이전트 선택, 세 입력 액션, 상태를 읽는지
5. Reduce Motion에서 칩 이동 없이 상태 피드백이 유지되는지
6. 음수 좌표 보조 디스플레이, 해상도 변경, fullscreen Space에서 패널이 화면 안에 유지되는지
7. 선택한 CLI 삭제·교체 후 빠른 메뉴와 전송이 잠기고 자동 폴백하지 않는지

## 현재 제한

- 전역 키 이벤트 모니터는 macOS 개인정보 보호 설정에 따라 입력 모니터링 또는 손쉬운 사용 허용이 필요할 수 있다.
- ScreenCaptureKit 시스템 선택기는 디스플레이 또는 창 선택 UI를 제공하며 별도 사각 영역 편집기는 없다.
- `.app`은 로컬 개발용으로 서명, 공증, 샌드박스 배포를 검증하지 않았다.
- CLI의 실제 모델 응답은 각 CLI의 로그인, 네트워크, 제공자 상태에 의존한다.
