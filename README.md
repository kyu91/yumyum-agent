# YumYum Phase 0 App Shell

YumYum의 macOS 로컬 Hermes 연결을 검증하기 위한 Swift 기반 기술 골격과 실행 가능한 SwiftUI 제품 셸이다. 실제 Hermes 작업, 네트워크, 캘린더, 자격증명에는 접근하지 않는다.

## 요구 환경

- macOS 14 이상
- Swift 6.0 이상
- XCTest를 포함한 Xcode 또는 정상 설치된 Command Line Tools

패키지는 외부 의존성이 없으며 다음 product를 제공한다.

- `YumYumCore`: 실행 파일 탐색, version probe, process 실행, ACP capability gate, 외부 변경 toolset policy
- `YumYum`: SwiftUI App lifecycle과 메뉴바 진입점을 갖춘 macOS 14+ GUI executable
- `yumyum-probe`: 명시적으로 지정한 실행 파일에만 `--version`을 전달하는 최소 CLI
- `yumyum-process-fixture`: 테스트용 결정적 자식 프로세스

## 빌드와 테스트

```sh
swift build
swift test
```

## GUI 앱 실행

SwiftPM executable로 바로 실행하려면 fixture를 먼저 빌드한 뒤 앱을 실행한다.

```sh
swift build --product yumyum-process-fixture
swift run YumYum
```

기본 창을 닫아도 메뉴바의 YumYum 아이콘에서 창을 다시 열거나 앱을 종료할 수 있다.

로컬 개발용 `.app` 번들은 추가 의존성 없이 만들 수 있다.

```sh
./scripts/build-app.sh
open .build/YumYum.app
```

기본 빌드는 release 설정을 사용하고 `.build/YumYum.app`을 만든다. debug 번들이 필요하면 `CONFIGURATION=debug ./scripts/build-app.sh`로 실행한다. 이 번들은 로컬 실행 검증용이며 배포 서명이나 공증을 수행하지 않는다.

앱의 Hermes 경로 필드는 사용자가 직접 입력하는 절대 경로 문자열만 받는다. 자동 탐색이나 파일 선택기를 제공하지 않으며 입력값을 저장하거나 실행하지 않는다. `안전한 Fixture Probe 실행` 버튼은 앱이 정한 `yumyum-process-fixture`에 `--version`만 전달하고, 대기·실행 중·성공·오류 상태를 표시한다.

현재 개발 머신의 독립 Command Line Tools에는 XCTest 모듈이 없고 `Testing.framework` 검색 경로도 SwiftPM에 자동 전달되지 않는다. 이 환경에서 활성 Swift Testing 회귀 스위트를 실행하려면 다음 우회를 사용한다.

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

`Tests/YumYumCoreTests/PhaseZeroXCTests.swift`에는 `canImport(XCTest)` 조건부 XCTest 회귀 스위트가 별도로 있다. 현재 머신에서는 XCTest 자체가 없어 실행되지 않으며, XCTest가 포함된 Xcode 환경에서 활성화된다.

## 안전한 probe 실행

실제 Hermes 대신 fixture로 전체 CLI 경로를 확인한다.

```sh
swift build
swift run yumyum-probe --hermes "$PWD/.build/debug/yumyum-process-fixture"
```

예상 결과는 exit status `0`과 다음 형태의 JSON이다.

```json
{"exitStatus":0,"standardError":"","standardOutput":"Hermes Fixture 0.0.0\n","timedOut":false}
```

인자 없이 실행하면 `PATH`를 검색하거나 어떤 프로세스도 probe하지 않고 usage와 exit status `64`를 반환한다. 실제 실행 파일을 확인하려면 사용자가 절대 경로를 명시해야 한다.

## Phase 0 경계

- GUI의 Hermes 경로 입력값은 형식만 확인하며 실제 파일 확인, 실행 또는 저장에 사용하지 않는다.
- GUI fixture probe는 사용자 입력과 분리된 고정 이름의 패키지 fixture만 허용한다.
- GUI와 메뉴바는 실제 Hermes, 네트워크, 캘린더, 자격증명 및 외부 변경 기능을 비활성화 상태로 표시한다.
- `HermesExecutableLocator`는 명시적 절대 경로를 우선하며, 명시 경로가 실패해도 `PATH`로 폴백하지 않는다.
- `PATH` 탐색은 호출자가 허용한 디렉터리와 실제 `PATH`의 교집합에서만 `hermes`를 찾는다. 빈 항목과 상대 디렉터리는 무시한다.
- `ProcessRunner`는 Foundation `Process`에 executable URL과 argv를 직접 전달한다. shell을 시작하거나 명령 문자열을 평가하지 않는다.
- stdout과 stderr는 동시에 수집한다. timeout 또는 Swift task cancellation 시 직접 자식에 SIGTERM을 보내고 grace period 후에도 실행 중이면 SIGKILL을 보낸다.
- `HermesVersionProbe`는 주입된 `ProcessRunning`을 통해 `--version`만 구성하며 stdout, stderr, exit status, timeout을 분리한다.
- ACP는 capability가 광고된 경우 `hermes acp` argv를 구성할 뿐 실행하지 않는다.
- 외부 변경 toolset은 기본 거부하며 현재 policy 값에 정확한 toolset ID가 승인된 경우에만 허용한다.

## 미검증 위험

- `scripts/build-app.sh`가 만드는 번들은 로컬 개발용으로 서명·공증·샌드박스·배포 패키징을 검증하지 않았다.
- fixture는 고정 이름과 앱이 결정한 경로로 제한하지만 번들 또는 빌드 산출물 자체의 서명·무결성은 검증하지 않는다.
- 실제 Hermes의 공식 설치 경로, 최소 버전, `--version` 출력과 exit status는 검증하지 않았다.
- `hermes acp` 구문, capability 탐지 방식, 구조화 출력, 승인, 취소 계약은 검증하지 않았다. ACP command를 실제 호출해서는 안 된다.
- 기본 `PATH` allowlist(`/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`)가 실제 Hermes 배포 경로와 일치하는지 검증하지 않았다.
- 실행 가능 파일의 소유자, 서명, symlink 최종 대상 신뢰성은 검증하지 않는다.
- timeout과 cancellation은 직접 자식만 종료한다. 자손 process group, launchd, XPC 정리는 Phase 0 범위 밖이다.
- 출력은 메모리에 누적하므로 무제한 출력을 내는 자식에 대한 상한과 backpressure가 없다.
- 환경을 별도로 지정하지 않으면 Foundation `Process`의 기본 상속 동작을 따른다. Hermes용 환경변수 최소화와 비밀정보 노출 정책은 미검증이다.
- macOS 14 및 15 실기기 회귀와 Intel Mac 동작은 확인하지 않았다.
- 현재 개발 머신에서는 XCTest를 실행하지 못했고 Swift Testing 스위트만 위 우회 명령으로 실행했다.
