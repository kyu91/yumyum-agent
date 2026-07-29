# YumYum Native Action and Response Flow

YumYum은 macOS 플로팅 펫의 네이티브 액션 말풍선에서 화면 영역과 파일을 먹이고, 생각 중 상태와 답변 말풍선을 거쳐 기존 채팅 transcript로 이어지는 Swift/AppKit 앱이다. 입력은 사용자가 선택한 로컬 Hermes, OpenCode, Codex, Claude Code에만 전달하며 외부 패키지나 shell, `which`, 홈 디렉터리 재귀 검색을 사용하지 않는다.

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
| OpenCode | `opencode run --pure --format json` | 확인된 `--file` argv |
| Codex | `codex --ask-for-approval untrusted exec --json --sandbox read-only --skip-git-repo-check` | 이미지만 확인된 `--image`; 나머지는 선택 경로를 사용자 표시 프롬프트에 명시 |
| Claude Code | `claude --print --verbose --output-format stream-json --include-partial-messages --permission-mode plan` | 선택 경로를 사용자 표시 프롬프트에 명시; 세션 ID 재사용 |

Hermes의 설치된 로컬 도움말에서 ACP 계약을 확인할 수 없으면 one-shot이나 임의 프로토콜로 대체하지 않고 사용 불가 이유를 표시한다. 모든 프로세스는 shell 없이 실행되며 120초 제한과 stdout+stderr 합산 2MB 상한을 사용한다.

YumYum은 Keychain, 토큰, 로그인 파일을 읽거나 복사하지 않는다. 실행된 CLI 자체의 기존 로그인 상태와 내부 동작은 해당 CLI의 책임이다.

## 액션·채팅·답변 흐름

- 펫 클릭 또는 기본 전역 단축키 `Control+Option+Space`는 펫 옆 248pt 액션 말풍선을 연다.
- 설정에서 제공하는 네이티브 단축키 선택지로 변경 가능
- 액션은 `캡처하기`, `파일 찾기`, `채팅 열기`, `설정` 네 행만 이 순서로 제공한다.
- `캡처하기`: 모든 YumYum 창과 펫을 먼저 숨긴 뒤 모든 디스플레이에 네이티브 투명 오버레이를 띄우고 어느 방향으로든 8pt 이상 영역을 드래그해 선택한다. 성공한 캡처는 즉시 한 Meal로 전송한다.
- `파일 찾기`: NSOpenPanel에서 이미지, PDF, 일반 텍스트, 소스 파일을 다중 선택하고 한 번의 선택 전체를 즉시 한 Meal로 전송한다.
- Finder의 여러 파일을 펫 위에 올리면 입과 drop outline으로 수신 가능 상태를 표시한다. hover에서는 파일 내용을 읽지 않고 기존 `FeedValidator`의 메타데이터 검증만 사용하며, drop 직전에 같은 검증을 다시 거쳐 공통 미리보기·전송 경로로 정확히 한 Meal을 시작한다.
- Finder drop은 절대 경로의 읽을 수 있는 일반 파일만 받는다. 폴더, symlink, alias, 미지원 확장자, 자격증명 파일, 파일당 20MB 초과 항목은 거부하고, 혼합 입력은 하나라도 무효하면 전체를 원자적으로 거부한다. 처리 중 drop도 큐에 넣지 않고 전체 거부하며 사용자 메시지에 로컬 경로를 노출하지 않는다.
- `채팅 열기`: 기존 사용자/어시스턴트 transcript, composer, 첨부, 보내기, 명시적 취소, 오류와 재시도를 연다. 채팅 내부에서 추가한 첨부는 기존처럼 초안에 머물며 Return 또는 `보내기`로 전송한다.
- 답변 말풍선은 본문만 담은 큰 bubble 아래에 독립된 작은 `채팅 입력하기`, `채팅창 상세` bubble을 둔다. `채팅 입력하기`를 펼치면 composer bubble이 두 CTA보다 위에 나타나고 같은 초안·첨부·transcript를 이어 쓰며, 인라인 첨부는 파일명과 개수를 표시한다. 입력과 상세는 서로 독립되어 입력 collapse가 상세 열기를 실행하거나 전송하지 않는다.
- `채팅창 상세`를 열면 외부 생각 bubble과 완료 답변 bubble을 숨겨 중복 응답을 표시하지 않는다. 상세 채팅을 닫으면 진행 중인 생각 bubble만 다시 나타나며, 완료 답변 bubble은 자동 재표시하지 않는다.
- 처리 중에는 캡처 썸네일 또는 겹친 네이티브 파일 아이콘이 펫 입으로 이동하고, `Yum.`/`Yum..`/`Yum...` 생각 말풍선과 씹기 동작이 이어진다. 완료 후 외부 답변은 본문만 담은 큰 bubble에서 전체 답변과 줄바꿈을 유지하고, 최대 높이를 넘으면 bubble 내부에서 스크롤한다.
- 에이전트 경로, 버전, 발견 및 선택 UI는 설정 창에서만 제공

파일은 각각 최대 20MB다. 폴더, symlink, 미지원 확장자, 자격증명으로 식별되는 파일은 거부한다. 빈 초안, 선택 취소, 캡처 권한 거부, 미지원·초과 파일, 에이전트 미선택은 `PromptRequest`를 만들거나 보내지 않는다. 액션 캡처의 취소·권한 거부·실패와 파일 선택 취소는 액션이나 채팅을 다시 열지 않고 펫만 표시한다.

Light 상세 채팅은 불투명한 warm ivory canvas, cream assistant bubble, pale terracotta user·attachment bubble, white composer, warm-neutral 보조 surface를 사용한다. Dark는 warm charcoal 계열이다. 커스텀 말풍선은 gray glass나 vibrancy를 사용하지 않으며, 실행 중 테마를 바꿔도 transcript·초안·첨부·busy 상태와 스크롤 위치를 유지한다. 네이티브 컨트롤과 시스템 accent는 유지하며 Increase Contrast와 Reduce Transparency 설정을 따른다.

유효한 입력은 420ms 미리보기 비행 뒤 공통 `PromptRequest`로 정확히 한 번 전달된다. 상세·인라인 composer의 Return과 보내기 버튼도 busy guard를 공유해 한 번만 전송한다. 상세 채팅과 외부 답변은 하나의 세션에서 transcript·초안·첨부·busy 상태를 공유한다. 후속 요청에는 transcript의 대화 텍스트만 맥락으로 포함하며 로컬 첨부 경로는 화면에 표시하지 않는다. Reduce Motion에서는 이동·크기·몸·볼 애니메이션 없이 100ms 미리보기 페이드, 고정 `Yum...`, 반쯤 닫힌 입을 사용한다. 채팅을 숨겨도 전송 Task는 계속되며 `취소`를 명시적으로 누른 경우에만 취소한다. 모든 완료·실패·취소 경로에서 씹기 상태를 정확히 초기화하고 임시 캡처를 정리한다. 비정상 종료로 남은 `YumYum-Capture-*` 파일은 다음 앱 시작 시 삭제한다.

macOS 15.2 이상에서는 `SCScreenshotManager.captureImage(in:)`를 사용한다. macOS 14·15.0·15.1에서는 선택 영역을 `SCDisplay`별 `sourceRect`로 캡처해 합성한다. 음수 좌표, 수직 배치, 디스플레이를 가로지르는 선택과 Retina/혼합 배율을 점 좌표에서 픽셀 조각으로 변환한다. 선택 영역의 화면 좌표는 캡처 URL과 함께 유지해 썸네일 비행 시작점으로 사용한다. 캡처 직전 액션·채팅·생각·답변 말풍선과 펫을 모두 숨기며 취소·권한 거부·실패 후에는 펫만 복원한다.

펫 드래그와 다중 디스플레이 보정은 기존 동작을 유지한다. 말풍선도 펫이 있는 디스플레이의 `visibleFrame` 안으로 보정된다.

## 외부 변경 안전 경계

현재 Connector는 분석 전용이며 Codex는 read-only, Claude Code는 plan, OpenCode는 pure 실행 계약을 사용한다. 외부 상태를 바꾸는 작업은 실행하지 않고 `ExternalChangeToolsetPolicy`는 기본 거부한다. Core의 `TaskApprovalGate`는 Task ID, approval ID, toolset ID에 묶인 메모리 내 일회성 승인 원칙만 검증하며 빠른 메뉴 승인 UI나 Connector 실행 흐름에는 연결되지 않았다. Hermes ACP의 `session/request_permission`은 항상 `cancelled`로 응답한다.

승인은 이전 요청, 포괄 승인, 다른 Task·approval·toolset에서 재사용하지 않는다. 입력은 사용자가 명시적으로 선택한 파일·캡처와 에이전트에만 전달하며 빈 입력, 무효 첨부, 취소, 권한 거부, 에이전트 미선택에서는 요청을 만들거나 보내지 않는다.

## 수동 확인 항목

플랫폼 UI는 자동화 테스트 대신 실제 macOS에서 다음을 확인한다.
Finder drop의 `NSDraggingDestination` override는 자동 검증하지만 실제 AppKit drag dispatch와 hit test는 GUI 수동 확인 대상으로 남는다.

1. 펫 클릭과 `Control+Option+Space`가 네 행의 248pt 액션 말풍선을 열고 다른 앱의 포커스를 불필요하게 가져오지 않는지
2. 모든 디스플레이의 오버레이에서 네 방향 드래그, 디스플레이 경계 통과, 8pt 미만 거부와 Esc 취소가 동작하는지
3. 화면 캡처 권한 거부와 캡처 실패 후 액션·채팅이 다시 열리지 않고 펫만 표시되는지
4. Retina/비-Retina 혼합, 음수 좌표와 수직 배치에서 결과 이미지의 크기·방향·이음새가 올바른지
5. 액션의 캡처, 파일 다중 선택, Finder 다중 drop은 각각 정확히 한 Meal로 전송되고 drop hover의 입·outline, invalid/mixed/busy 전체 거부, drop 시 재검증이 동작하며, 채팅 내부 첨부는 초안·제거·Return 전송을 유지하는지
6. 채팅을 닫아도 백그라운드 전송이 계속되고 명시적 `취소`만 전송을 중단하는지
7. VoiceOver가 액션 네 행, transcript, composer, 전송·취소·재시도와 상태를 읽되 생각 말풍선의 점 변화는 반복 발표하지 않는지
8. Reduce Motion에서 100ms 페이드, 고정 `Yum...`, 반쯤 닫힌 입만 유지되는지
9. 해상도 변경과 fullscreen Space에서 액션·채팅·생각·답변 말풍선이 펫 디스플레이 안에 유지되는지
10. 완료 답변이 본문 큰 bubble → 선택적 composer → 독립된 입력·상세 작은 bubble 순서로 배치되고, 인라인 입력이 즉시 포커스되며 collapse가 전송·상세 열기를 일으키지 않는지
11. `채팅창 상세`가 외부 생각·완료 답변 bubble을 숨겨 중복 표시하지 않고, 닫은 뒤 진행 중 생각만 복원하며 초안·첨부·busy·transcript·스크롤 위치를 유지하는지
12. 선택한 CLI 삭제·교체 후 전송이 실패하고 자동 폴백하지 않는지
13. Light 상세 채팅의 warm ivory·cream·pale terracotta·white·warm-neutral surface와 Dark warm charcoal이 구분되고 gray glass/vibrancy가 없으며, 테마·Increase Contrast·Reduce Transparency 즉시 변경 뒤 transcript·초안·첨부·busy·스크롤·인라인 펼침이 유지되는지

## 현재 제한

- 전역 키 이벤트 모니터는 macOS 개인정보 보호 설정에 따라 입력 모니터링 또는 손쉬운 사용 허용이 필요할 수 있다.
- 영역 선택 중에는 macOS가 제공하는 개별 창 선택 대신 YumYum의 사각 드래그 오버레이만 제공한다.
- `.app`은 로컬 개발용으로 서명, 공증, 샌드박스 배포를 검증하지 않았다.
- CLI의 실제 모델 응답은 각 CLI의 로그인, 네트워크, 제공자 상태에 의존한다.
