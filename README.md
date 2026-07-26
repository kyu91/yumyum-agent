# YumYum Local Agents and Chat Bubble

YumYum은 macOS 플로팅 펫의 채팅 말풍선에서 화면 영역, 대화 텍스트, 파일을 로컬 Hermes, OpenCode, Codex, Claude Code에 전달하는 Swift/AppKit 앱이다. 외부 패키지나 shell, `which`, 홈 디렉터리 재귀 검색을 사용하지 않는다.

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

## 채팅 말풍선

- 펫 클릭 또는 기본 전역 단축키 `Control+Option+Space`
- 설정에서 제공하는 네이티브 단축키 선택지로 변경 가능
- AppKit 말풍선에 사용자/어시스턴트 transcript, 하단 composer, 로딩 응답, 취소, 오류와 재시도 상태 표시
- `화면 캡처`: 모든 디스플레이에 네이티브 투명 오버레이를 띄우고 어느 방향으로든 8pt 이상 영역을 드래그해 선택
- `파일`: NSOpenPanel에서 이미지, PDF, 일반 텍스트, 소스 파일 다중 선택
- 캡처와 파일은 초안 미리보기에만 추가되며 자동 전송하지 않음. 개별 첨부 제거 후 Return 또는 `보내기`로 명시적 전송
- 에이전트 경로, 버전, 발견 및 선택 UI는 설정 창에서만 제공

파일은 각각 최대 20MB다. 폴더, symlink, 미지원 확장자, 자격증명으로 식별되는 파일은 거부한다. 빈 초안, 선택 취소, 캡처 권한 거부, 미지원·초과 파일, 에이전트 미선택은 `PromptRequest`를 만들거나 보내지 않는다. 캡처 취소·권한 거부·실패는 앱을 종료하지 않고 기존 대화로 복귀한다.

유효한 입력은 펫의 입 열기, 미리보기 칩 이동, 입 닫기 순서 뒤 공통 `PromptRequest`로 정확히 한 번 전달된다. 후속 요청에는 transcript의 대화 텍스트만 맥락으로 포함하며 로컬 첨부 경로는 화면에 표시하지 않는다. Reduce Motion에서는 이동을 생략하고 상태 텍스트와 입 상태는 유지한다. 전송 Task는 취소할 수 있고 모든 완료·실패·취소 경로에서 입을 닫고 임시 캡처를 삭제한다. 비정상 종료로 남은 `YumYum-Capture-*` 파일은 다음 앱 시작 시 삭제한다.

macOS 15.2 이상에서는 `SCScreenshotManager.captureImage(in:)`를 사용한다. macOS 14·15.0·15.1에서는 선택 영역을 `SCDisplay`별 `sourceRect`로 캡처해 합성한다. 음수 좌표, 수직 배치, 디스플레이를 가로지르는 선택과 Retina/혼합 배율을 점 좌표에서 픽셀 조각으로 변환한다. 캡처 직전 오버레이, 말풍선, 펫을 숨기고 성공·취소·실패 후 기존 표시 상태를 복원한다.

펫 드래그와 다중 디스플레이 보정은 기존 동작을 유지한다. 말풍선도 펫이 있는 디스플레이의 `visibleFrame` 안으로 보정된다.

## 외부 변경 안전 경계

외부 상태를 바꾸는 작업은 현재 Connector에서 실행하지 않으며 Hermes ACP 권한 요청은 `cancelled`로 응답한다. Core의 `TaskApprovalGate`는 Task ID, approval ID, toolset ID에 묶인 메모리 내 일회성 승인 원칙만 검증한다. 빠른 메뉴의 승인 UI와 Connector 실행 흐름에는 아직 연결되지 않았다.

## 수동 확인 항목

플랫폼 UI는 자동화 테스트 대신 실제 macOS에서 다음을 확인한다.

1. 펫 클릭과 `Control+Option+Space`가 펫 옆 패널을 열고 다른 앱의 포커스를 불필요하게 가져오지 않는지
2. 모든 디스플레이의 오버레이에서 네 방향 드래그, 디스플레이 경계 통과, 8pt 미만 거부와 Esc 취소가 동작하는지
3. 화면 캡처 권한 거부와 캡처 실패 후 말풍선·펫 표시 상태와 기존 대화가 복원되는지
4. Retina/비-Retina 혼합, 음수 좌표와 수직 배치에서 결과 이미지의 크기·방향·이음새가 올바른지
5. 캡처·파일이 자동 전송되지 않고 미리보기 추가·제거, Return 전송, 취소와 재시도가 동작하는지
6. VoiceOver가 transcript 역할, composer, 캡처·파일·전송·취소·재시도와 상태 발표를 읽는지
7. Reduce Motion에서 칩 이동 없이 상태 피드백이 유지되는지
8. 해상도 변경과 fullscreen Space에서 400×520 말풍선이 펫 디스플레이 안에 유지되는지
9. 선택한 CLI 삭제·교체 후 전송이 실패하고 자동 폴백하지 않는지

## 현재 제한

- 전역 키 이벤트 모니터는 macOS 개인정보 보호 설정에 따라 입력 모니터링 또는 손쉬운 사용 허용이 필요할 수 있다.
- 영역 선택 중에는 macOS가 제공하는 개별 창 선택 대신 YumYum의 사각 드래그 오버레이만 제공한다.
- `.app`은 로컬 개발용으로 서명, 공증, 샌드박스 배포를 검증하지 않았다.
- CLI의 실제 모델 응답은 각 CLI의 로그인, 네트워크, 제공자 상태에 의존한다.
