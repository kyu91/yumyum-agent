# AGENTS.md

이 문서는 저장소 전체에 적용되는 작업 지침이다.

## 프로젝트 목적과 제품 안전 원칙

YumYum은 사용자가 선택한 화면 영역이나 로컬 파일을 macOS 플로팅 펫에 “먹이고”, 검증된 로컬 CLI 에이전트(Hermes, OpenCode, Codex, Claude Code)의 응답을 네이티브 말풍선과 채팅 transcript로 보여 주는 Swift/AppKit 앱이다.

- 외부 상태를 바꾸는 동작은 실행 직전에 사용자가 해당 작업과 별개로 명시적으로 승인해야 한다. 이전 승인, 포괄 승인, 다른 Task·approval·toolset의 승인을 재사용하지 않는다.
- 현재 제품은 외부 변경을 실행하지 않는다. `ExternalChangeToolsetPolicy`는 기본 거부이고, `TaskApprovalGate`는 메모리 내 일회성 승인 모델만 구현했으며 UI 및 Connector 실행 흐름과 연결되어 있지 않다.
- Hermes ACP의 `session/request_permission`은 현재 항상 `cancelled`로 응답한다. 승인 UI와 Task 범위 검증이 실제 실행 경로에 연결되기 전에는 이 동작을 완화하지 않는다.
- 입력은 사용자가 명시적으로 선택한 자료와 에이전트에만 전달한다. 빈 입력, 무효 첨부, 취소, 권한 거부, 에이전트 미선택 상태에서는 요청을 만들거나 전송하지 않는다.

## 기술 스택과 구조

- macOS 14 이상, Swift tools 6.0, Swift Package Manager
- UI: SwiftUI 앱 수명 주기 + AppKit `NSPanel`/`NSWindow`/`NSOpenPanel`; 화면 캡처는 ScreenCaptureKit
- 동시성·상태: Swift Concurrency(`actor`, `Task`, `AsyncThrowingStream`), Combine `ObservableObject`
- 테스트: 주로 Swift Testing(`@Test`, `#expect`), 일부 XCTest
- 외부 패키지 의존성은 없다.

주요 경로:

- `Package.swift`: `YumYumCore` 라이브러리, `YumYum` 앱, `yumyum-probe`, `yumyum-process-fixture`, `YumYumCoreTests` 정의
- `Sources/YumYumCore/`: UI 독립 정책, 상태 머신, 입력 검증, 에이전트 발견·선택·실행, 프로세스 및 ACP 전송
- `Sources/YumYumApp/`: 앱 진입점, 플로팅 펫, 액션/채팅 패널, 캡처 UI
- `Sources/YumYumProbe/`: 명시한 Hermes 절대 경로에 `--version`만 실행하는 진단 CLI
- `Sources/YumYumProcessFixture/`: 프로세스·스트리밍·종료 테스트용 결정적 fixture
- `Tests/YumYumCoreTests/`: Core와 App 내부 정책 및 통합 경계 테스트
- `AppBundle/Info.plist`: 로컬 `.app` 번들 메타데이터
- `scripts/build-app.sh`: release/debug 실행 파일과 fixture를 `.app` 구조로 조립
- `README.md`: 현재 구현·실행·수동 검증 기준
- `YumYum-Agent-Product-Spec.md`: 장기 제품 정의와 요구사항. 현재 구현 여부는 README와 실제 소스/테스트를 우선한다.
- `.gitignore`: `.DS_Store`, `.build/`, `.swiftpm/`, `DerivedData/`, Xcode 사용자 상태만 제외

## 핵심 아키텍처와 실행 흐름

### 앱과 UI 진입점

`YumYumApplication`이 `@main` 진입점이다. 시작 시 `CaptureTemporaryFileCleanup.removeStaleFiles()`로 남은 `YumYum-Capture-*` 일반 파일을 정리하고 `YumYumAppViewModel`을 만든다. `YumYumAppDelegate`가 플로팅 펫, 전역 단축키, `QuickMenuPanelController`, `FeedWorkflow`를 조립하며 종료 전에 `AgentRuntime.close()`를 기다린다.

펫 클릭 또는 설정된 전역 단축키는 액션 말풍선을 연다. 액션 순서와 상태 전이는 `ActionBubbleAction` 및 `ActionFlowStateMachine`이 소유하고, `QuickMenuPanelController`가 효과를 AppKit UI에 반영한다. 채팅 상태는 `ChatBubbleState`, 비동기 전송 수명은 `ChatBubbleSession`이 소유한다. 패널을 숨기는 것만으로 전송을 취소하지 않으며 명시적 취소만 `Task`를 취소한다.

### 입력과 응답

캡처는 `ScreenCaptureCoordinator`가 모든 화면에 선택 오버레이를 띄우고 `CaptureRegionPolicy`로 최소 8pt 및 디스플레이별 픽셀 조각을 계산한다. macOS 15.2 이상은 단일 영역 API를, macOS 14~15.1은 디스플레이별 캡처 후 합성을 사용한다. 성공한 캡처는 임시 PNG와 원래 화면 좌표를 유지한다.

파일 선택과 캡처는 `FeedInput`으로 합쳐진다. `FeedValidator`는 절대 경로의 일반 파일만 허용하고 중복을 제거하며, 파일당 20MB 제한, 지원 확장자, 자격증명 파일명/확장자 차단을 적용한다. `FeedWorkflow`는 검증 → 미리보기 애니메이션 → `PromptRequest` 생성 → 스트리밍 전송 → 완료/실패/취소 피드백 순서를 직렬화하고 모든 종료 경로에서 입 상태와 임시 파일을 정리한다.

응답은 `PromptResponseEvent`의 snapshot/delta/completed 스트림으로 UI에 도착한다. `ChatBubbleState`는 transcript와 현재 스트리밍 응답을 갱신하고, `AssistantMarkdownRenderer`는 진행 중인 불완전 Markdown과 완료된 Markdown을 다르게 렌더링한다. 사용자 표시 오류는 `UserFacingErrorRedactor`를 거쳐 경로·토큰·원시 stderr 노출을 막는다.

### 에이전트 발견, 선택, 실행

`AgentDiscovery`는 고정 후보 디렉터리의 직접 실행 파일과 사용자가 추가한 정확한 절대 경로만 확인한다. 각 후보에 shell 없이 `--version`과 에이전트별 `--help` 인자를 직접 전달하고, 2초 timeout·64KB 합산 출력 상한·최소 환경을 적용한다.

`AgentRegistry`는 정의 ID와 정확한 실행 경로만 `UserDefaultsAgentSelectionStore`에 저장한다. 앱 시작, 수동 검색, 빠른 메뉴 열기, 전송 직전에 다시 검증하며 선택 경로가 무효해지면 자동 폴백하지 않는다.

전송 경로는 다음과 같다.

`FeedWorkflow` → `AgentRuntime` → `AgentRegistry.validatedSelection()` → 선택된 `AgentConnecting` 구현 → `ProcessRunner` 또는 `ACPProcessTransport`

- Hermes: `HermesACPConnector` → 장기 연결 `ACPProcessTransport` → `HermesACPProtocolClient`; `initialize`, `session/new`, `session/prompt`를 사용하고 권한 요청은 취소한다.
- OpenCode: 구조화된 `opencode run --pure --format json`; 확인된 첨부는 `--file`로 전달한다.
- Codex: read-only sandbox와 untrusted approval 정책의 구조화된 `codex exec`; 이미지만 `--image`로 전달한다.
- Claude Code: plan permission mode와 비영속 세션의 구조화된 print 실행.

CLI는 shell을 거치지 않고 정확한 실행 URL과 argv로 시작한다. 일반 에이전트 실행은 120초 timeout과 stdout/stderr 합산 2MB 상한을 유지한다. Codex/Claude 세션 재사용, 취소 후 reset, stale generation 억제 동작을 보존한다.

## 개발, 빌드, 테스트, 실행

저장소 루트에서 실행한다.

```sh
swift build
swift test
./scripts/build-app.sh
open .build/YumYum.app
```

`scripts/build-app.sh`는 기본 release 번들을 `.build/YumYum.app`에 만든다. debug 번들은 다음과 같다.

```sh
CONFIGURATION=debug ./scripts/build-app.sh
```

독립 Command Line Tools 환경에서 `Testing` 모듈 검색 경로가 잡히지 않을 때만 README의 전체 회귀 명령을 사용한다.

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

명시한 Hermes 실행 파일의 버전 probe:

```sh
swift run yumyum-probe --hermes /absolute/path/to/hermes
```

실제 경로와 외부 CLI 로그인/네트워크 상태가 필요한 probe 및 모델 응답은 자동 검증 명령으로 취급하지 않는다. 저장소에는 formatter나 linter 설정이 없으므로 존재하지 않는 검사 명령을 추가하지 않는다.

## 코드 스타일과 기존 패턴

- 기존 파일의 import 순서, 4칸 들여쓰기, trailing comma, 줄바꿈 스타일을 그대로 따른다.
- 공개 API는 `public`, 구현 세부는 `private`/파일 내부 타입으로 제한한다. 새 추상화보다 기존 protocol(`ProcessRunning`, `AgentConnecting`, `FeedSubmitting`, `FeedFeedback`)과 정책 타입을 재사용한다.
- UI와 상태 변경은 `@MainActor`, 공유 가변 비동기 상태는 `actor`, 동기 잠금 래퍼는 필요한 경우에만 `@unchecked Sendable`을 사용한다.
- 실행 정책·레이아웃·상태 전이는 Core의 값 타입/상태 머신에 두고 AppKit controller는 효과 적용과 프레임워크 호출에 집중한다.
- 프로세스 실행은 `ProcessCommand`/`ProcessRunner`를 사용한다. shell 문자열, `which`, 임의 `PATH` 탐색, 홈 디렉터리 재귀 검색을 추가하지 않는다.
- 사용자 오류에는 원시 `error.localizedDescription`, stderr, 로컬 경로를 직접 표시하지 말고 `UserFacingErrorRedactor`를 사용한다.
- 구현과 테스트 이름은 동작을 설명하는 영어를 사용한다. 주석은 코드만으로 드러나지 않는 이유가 있을 때만 쓴다.
- 요청 범위 밖 리팩터링, 새 의존성, 배포 설정, 미래용 추상화를 추가하지 않는다.

## 테스트와 검증 요구사항

- 버그 수정은 해당 실패를 재현하는 최소 테스트를 먼저 추가하고 수정 후 전체 `swift test`를 실행한다.
- 기능 변경은 Core 정책/상태를 Swift Testing으로 검증한다. 기존 XCTest 기반 프로세스 회귀와 연결되는 경우 `PhaseZeroXCTests` 패턴을 유지한다.
- 에이전트/프로세스 변경은 정확한 executable URL과 argv, 최소 환경, timeout, 출력 상한, shell 미사용, 취소·강제 종료, 스트림 drain을 검증한다.
- ACP 변경은 초기화/세션 재사용, permission 취소, cancellation 알림, timeout 후 연결 폐기·재연결, stale event 억제를 검증한다.
- 입력/채팅 변경은 정확히 한 번 전송, busy 거부, transcript 맥락, 첨부 경로 노출 방지, retry/cancel, 모든 경로의 임시 파일 정리를 검증한다.
- 캡처 변경은 네 방향 드래그, 최소 영역, 음수/수직 화면 좌표, 혼합 배율, 디스플레이 경계 합성, 취소 뒤 늦은 callback 억제를 검증한다.
- UI/접근성 변경은 README의 수동 확인 항목 중 관련 항목을 실제 macOS에서 확인한다. 특히 VoiceOver, Reduce Motion, 다중 디스플레이, 포커스 비탈취는 단위 테스트만으로 완료 처리하지 않는다.
- 완료 전 최소 검증:

```sh
swift test
git diff --check
git status --short --untracked-files=all
```

앱 번들 또는 패키지 설정을 바꾸면 `swift build`와 `./scripts/build-app.sh`도 실행한다.

## 변경 영역별 주의사항

- `ActionFlowPolicy`, `ChatBubbleState`, `ChatBubbleSession`: stale generation/submission 결과가 새 UI에 섞이지 않게 한다. 취소·권한 거부·실패 뒤 액션/채팅을 자동 재오픈하지 않고 펫만 복원하는 현재 동작을 보존한다.
- `FeedWorkflow`, `FeedValidator`: 검증 전에 `PromptRequest`를 만들지 않는다. 파일 제한, 자격증명 차단, 중복 제거, 단일 전송, 임시 캡처 정리를 약화하지 않는다.
- `AgentDiscovery`, `AgentSelection`: 정확한 절대 경로와 로컬 help 계약을 재검증한다. 선택 경로가 사라져도 다른 설치로 자동 전환하지 않는다.
- `AgentRuntime`, `StructuredCLIStreaming`: 각 CLI에서 실제 확인된 argv만 사용한다. 첨부 지원 차이를 합쳐 추상화하거나 확인되지 않은 flag를 추가하지 않는다.
- `HermesACPTransport`: ACP v1 JSON-RPC 순서, 연결/세션 재사용, permission `cancelled`, 2MB 예산 reset, timeout/cancel 시 프로세스 폐기와 다음 요청 재연결을 보존한다.
- `ProcessRunner`: stdout/stderr를 동시에 계속 drain하고 출력 상한 도달 뒤에도 child deadlock을 막는다. timeout/cancel 시 terminate 후 필요하면 kill하며 descendant가 pipe를 잡아도 직접 child 종료를 기다리지 않는다.
- `ScreenCaptureCoordinator`, `CaptureRegionPolicy`: macOS 버전별 API 분기와 AppKit/ScreenCaptureKit 좌표계 변환을 유지한다. 캡처 직전 모든 YumYum 표면을 숨기고 결과의 source rect를 미리보기 시작점으로 유지한다.
- `FloatingPetWindowController`, 패널 controller: 펫 드래그 위치와 모든 말풍선을 해당 디스플레이 `visibleFrame` 안에 보정한다. 액션 네 행 순서, 248pt 폭, 키보드 이동, VoiceOver label을 보존한다.
- Markdown/응답 UI: 스트리밍 중 불완전 delimiter를 숨기고 완료 시 block/inline 스타일과 원문 줄바꿈을 유지한다. 긴 응답은 말풍선 자체가 아니라 내부 문서를 스크롤한다.
- `Package.swift`, `AppBundle`, `scripts/build-app.sh`: fixture가 앱 Resources에 포함되어야 한다. 현재 번들은 로컬 개발용이며 서명·공증·샌드박스 배포가 검증되지 않았다.

## 보안, 개인정보, 자격증명, 외부 부작용

- API 키, 토큰, 비밀번호, 계정 정보, 개인 식별 정보를 소스·테스트 fixture·문서·로그에 넣지 않는다.
- Keychain, CLI 로그인 파일, 토큰 파일을 읽거나 복사하지 않는다. 실행된 CLI의 기존 인증과 네트워크 동작은 해당 CLI의 경계다.
- 선택하지 않은 파일, 폴더, symlink, 지원하지 않는 확장자, 차단된 자격증명 파일을 전송하지 않는다.
- 사용자 표시 메시지와 transcript에 로컬 절대 경로, raw stderr, token 형태의 문자열을 노출하지 않는다. Connector가 경로 입력을 요구할 때만 현재 요청에서 사용자가 선택한 경로를 제한적으로 전달한다.
- 외부 변경 도구를 추가하거나 permission 응답을 허용하려면 독립 승인 UI, Task/approval/toolset 일치, 일회성 consume, 취소·거부 경로를 함께 구현하고 검증해야 한다. 일부만 구현한 상태로 실행 가능하게 만들지 않는다.
- 네트워크 호출, 패키지 추가, 원격 서비스 연동, telemetry를 사용자의 명시적 요청 없이 추가하지 않는다.

## Git 작업 규칙

- 현재 작업 트리에서 작업하며 별도 worktree를 만들지 않는다.
- 작업 전후 `git status --short --untracked-files=all`을 확인하고 기존 사용자 변경을 보존한다.
- 요청한 파일과 직접 연결된 최소 범위만 수정한다. 무관한 포맷 변경, dead code 삭제, 생성물 커밋을 하지 않는다.
- `.build/`, `.swiftpm/`, `DerivedData/`, `.DS_Store`, Xcode 사용자 상태를 커밋하지 않는다.
- 비가역 작업(파일 삭제, 강제 push, history rewrite)은 사전 승인을 받는다.
- 요청 없이 commit, push, branch 생성, tag 생성, 원격 변경을 하지 않는다.
- 완료 전 `git diff --check`와 전체 status를 확인하고, 실행하지 못한 검증은 이유와 함께 보고한다.
