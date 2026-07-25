# YumYum Floating Pet and Hermes Connection

YumYum의 macOS 플로팅 펫과 로컬 Hermes 연결을 검증하기 위한 Swift 기반 기술 골격 및 실행 가능한 SwiftUI 앱이다. 사용자가 지정한 Hermes 실행 파일의 `--version`만 확인하며 ACP, 네트워크, 캘린더, 자격증명 및 외부 변경 기능에는 접근하지 않는다.

## 요구 환경

- macOS 14 이상
- Swift 6.0 이상
- XCTest를 포함한 Xcode 또는 정상 설치된 Command Line Tools

패키지는 외부 의존성이 없으며 다음 product를 제공한다.

- `YumYumCore`: 플로팅 펫 위치·표시 정책, 명시 경로 연결 확인, 실행 파일 탐색, version probe, process 실행, ACP capability gate, 외부 변경 toolset policy
- `YumYum`: SwiftUI App lifecycle, 네이티브 플로팅 패널과 메뉴바 진입점을 갖춘 macOS 14+ GUI executable
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

앱을 실행하면 마우스가 있는 화면의 사용 가능 영역 우하단에 96×96pt YumYum 펫이 표시된다. 메뉴바와 Dock을 제외한 `visibleFrame`에서 우측·하단 20pt 간격을 두며, 모든 Space와 fullscreen 앱 위에서도 보조 패널로 표시된다.

- 펫 클릭: YumYum 앱을 활성화하고 기본 창 열기
- 펫 드래그: 현재 실행 중 원하는 위치로 이동
- 메뉴바 `플로팅 펫 보이기`: 펫 표시·숨김 전환
- 디스플레이 연결·해제 또는 해상도 변경: 현재 펫 위치를 사용 가능 화면 안으로 자동 보정

펫 위치와 표시 여부는 저장하지 않는다. 앱을 다시 실행하면 표시 상태로 시작하고 현재 마우스 화면의 우하단에 다시 배치된다. 펫에는 VoiceOver 라벨·실행 액션·조작 힌트가 있으며, Reduce Motion이 켜지면 hover 전환 애니메이션을 사용하지 않는다.

로컬 개발용 `.app` 번들은 추가 의존성 없이 만들 수 있다.

```sh
./scripts/build-app.sh
open .build/YumYum.app
```

기본 빌드는 release 설정을 사용하고 `.build/YumYum.app`을 만든다. debug 번들이 필요하면 `CONFIGURATION=debug ./scripts/build-app.sh`로 실행한다. 이 번들은 로컬 실행 검증용이며 배포 서명이나 공증을 수행하지 않는다.

앱을 열면 Hermes 경로는 비어 있다. 다음 순서로 연결을 확인한다.

1. Hermes 실행 파일의 절대 경로를 직접 입력한다. 예: `/Users/username/.local/bin/hermes`
2. `연결 확인`을 누른다.
3. 앱에서 실행 중, 성공과 버전 원문, 경로 오류, 실행 오류 또는 시간 초과 상태를 확인한다.
4. 실행 중 중단하려면 `취소`를 누른다.

입력 경로는 자동 탐색하거나 저장하지 않는다. 절대 경로 형식일 때만 버튼이 활성화되며, 연결 확인 시 해당 파일의 실행 가능 여부를 검증한 다음 shell 없이 `--version` argv 하나만 직접 전달한다. 명시 경로가 실패해도 `PATH` 후보로 폴백하지 않는다.

하단 `개발 진단`의 `Fixture Probe 실행`은 실제 Hermes와 분리된 `yumyum-process-fixture`를 점검하기 위한 보조 기능이다.

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

## 현재 안전 경계

- GUI의 Hermes 경로 입력값은 저장하지 않으며 앱을 시작할 때 항상 비어 있다.
- 플로팅 펫은 별도 이미지·외부 의존성 없이 Canvas와 SF Symbol로 그리며 위치·표시 상태를 저장하지 않는다.
- 플로팅 패널은 Hermes 연결 상태나 실행 경로를 변경하지 않으며, 클릭 시 기본 창을 여는 동작만 수행한다.
- GUI 연결 확인은 명시한 Hermes 실행 파일의 `--version`만 실행한다. 로딩, 성공, 경로 오류, 실행 오류, 시간 초과를 구분하고 실행 중 취소를 지원한다.
- GUI fixture probe는 사용자 입력과 분리된 고정 이름의 패키지 fixture만 허용하며 개발 진단으로만 제공한다.
- GUI와 메뉴바는 연결 확인 외 ACP, 네트워크, 캘린더, 자격증명 및 외부 변경 기능을 비활성화 상태로 표시한다.
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
- 실제 Hermes의 공식 설치 경로와 최소 지원 버전 정책은 정하지 않았다.
- `hermes acp` 구문, capability 탐지 방식, 구조화 출력, 승인, 취소 계약은 검증하지 않았다. ACP command를 실제 호출해서는 안 된다.
- 기본 `PATH` allowlist(`/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`)가 실제 Hermes 배포 경로와 일치하는지 검증하지 않았다.
- 실행 가능 파일의 소유자, 서명, symlink 최종 대상 신뢰성은 검증하지 않는다.
- timeout과 cancellation은 직접 자식만 종료한다. 자손 process group, launchd, XPC 정리는 Phase 0 범위 밖이다.
- 출력은 메모리에 누적하므로 무제한 출력을 내는 자식에 대한 상한과 backpressure가 없다.
- 환경을 별도로 지정하지 않으면 Foundation `Process`의 기본 상속 동작을 따른다. Hermes용 환경변수 최소화와 비밀정보 노출 정책은 미검증이다.
- 현재 실기 확인은 Apple Silicon macOS 26.5.2에서 수행했다. 최소 지원 버전인 macOS 14·15와 Intel Mac 동작은 별도 확인하지 않았다.
- 현재 개발 머신에서는 XCTest를 실행하지 못했고 46개 Swift Testing 테스트만 위 우회 명령으로 실행했다.
