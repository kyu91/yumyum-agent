# YumYum Agent

[English](README.md) | [한국어](README.ko.md) *(현재)*

YumYum Agent는 선택한 화면 영역이나 로컬 파일을 플로팅 펫에게 “먹이고”, 설치된 로컬 CLI 에이전트의 응답을 네이티브 말풍선과 채팅으로 확인할 수 있는 Swift/AppKit macOS 앱입니다.

> **미서명 개발자 프리뷰:** [최신 Unsigned Preview 릴리스](https://github.com/kyu91/yumyum-agent/releases/latest)는 공개 prerelease로 제공됩니다. **Developer ID 서명 또는 Apple 공증을 받지 않았습니다.**

## 기능

- 클립보드를 채팅 초안에 담기, 화면 캡처, 파일 선택, Finder 드롭, 채팅 입력을 위한 하나의 검증된 흐름
- Reduce Motion과 VoiceOver를 지원하는 스트리밍 응답, 대화 기록 연속성, 취소 및 재시도
- 정확한 실행 파일 경로와 로컬 `--version`/`--help` 계약을 사용하는 CLI 탐색 및 재검증
- 안전 및 개인정보 보호 정책보다 낮은 우선순위로 적용되는 앱 소유 `SOUL.md` 응답 맞춤 설정
- 외부 변경 기본 거부, Hermes 권한 요청은 항상 취소
- **Settings → General → Language**에서 즉시 전환할 수 있는 영어 및 한국어 인터페이스

## 요구 사항

- macOS 14 이상
- Swift 6.0 이상이 포함된 Xcode 또는 Command Line Tools
- 아래 지원 CLI 중 하나를 별도로 설치하고 로그인

이 Apple Silicon Command Line Tools 호스트에서는 로컬 unsigned Universal DMG를 빌드하고 마운트했으며, 체크섬을 검증하고 앱 실행 파일과 fixture 모두에서 `x86_64` 및 `arm64` slice를 확인했습니다. 서명·공증 배포, Gatekeeper 평가, clean-machine 검증, Intel 하드웨어 실행은 아직 검증되지 않았습니다.

## 다운로드 및 설치

이 **Unsigned Preview**는 Developer ID 서명 또는 Apple 공증을 받지 않았습니다. [공식 릴리스 페이지](https://github.com/kyu91/yumyum-agent/releases/latest)에서만 다운로드하세요.

1. `YumYum-Agent-<version>-macOS.dmg`를 다운로드합니다.
2. DMG를 엽니다.
3. **YumYum.app**을 **Applications(응용 프로그램)**로 드래그합니다.
4. **YumYum.app**을 한 번 실행합니다. macOS가 차단하면 경고를 확인하거나 닫습니다.
5. **시스템 설정 → 개인정보 보호 및 보안**을 열고 **보안** 섹션까지 스크롤한 뒤 **확인 없이 열기**를 클릭합니다.
6. 요청되면 인증하고 **열기**를 확인합니다.

버튼 이름과 경고 문구는 macOS 버전이나 표시 언어에 따라 다를 수 있습니다. 앱 기능 사용 시 macOS가 화면 기록, 입력 모니터링 또는 손쉬운 사용 권한을 요청할 수도 있습니다. 두 architecture slice가 있어도 clean-machine Gatekeeper 동작과 Intel 하드웨어 실행은 검증되지 않았습니다.

### 선택 사항: SHA-256 체크섬 검증(권장)

`YumYum-Agent-<version>-macOS.dmg`와 `YumYum-Agent-<version>-macOS.dmg.sha256`를 모두 **다운로드** 폴더에 받거나, 두 파일을 같은 폴더에 둡니다. 다운로드 폴더에 있다면 다음 명령을 실행하세요.

```sh
cd ~/Downloads && shasum -a 256 -c YumYum-Agent-<version>-macOS.dmg.sha256
```

로컬 개발자는 unsigned DMG를 명시적으로 생성하고 검증할 수 있습니다.

```sh
./scripts/package-release.sh --unsigned
./scripts/test-release.sh .build/release/YumYum-Agent-<version>-macOS.dmg
```

## 소스에서 빌드 및 실행

```sh
swift build
swift test
./scripts/build-app.sh
open ".build/YumYum.app"
```

스크립트는 기본적으로 로컬 release `.build/YumYum.app`을 생성합니다. debug bundle에는 `CONFIGURATION=debug ./scripts/build-app.sh`를 사용하세요.

독립 실행형 Command Line Tools가 `Testing` 모듈을 찾지 못할 때만 다음 전체 회귀 명령을 실행하세요.

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

## 처음 사용하기

1. 지원 CLI를 설치하고 해당 CLI의 로그인 절차를 완료합니다.
2. **Settings → Agent**에서 연결할 에이전트를 선택하고 **찾아 등록**을 누릅니다. YumYum Agent가 안전한 기본 설치 위치를 확인하고 로컬 실행 계약을 검증한 뒤, 사용할 준비가 된 CLI를 기본 에이전트로 선택합니다. 찾지 못하면 **설치 안내**를 열고, 다른 위치에 설치했다면 **직접 선택**을 사용하세요. Codex는 기본 에이전트가 되기 전에 ChatGPT 로그인이 필요합니다.
3. 화면 기록, 손쉬운 사용, 입력 모니터링 권한을 요청하면 허용합니다. 이 창은 세 권한을 모두 허용할 때까지 실행할 때마다 다시 뜨며(**Settings → 권한 확인**에서 언제든 다시 열 수 있음), 클립보드 먹이기 단축키가 다른 앱 포커스 상태에서도 동작하려면 손쉬운 사용과 입력 모니터링이 모두 필요합니다.
4. 펫을 오른쪽 클릭하여 빠른 메뉴를 엽니다. 펫을 왼쪽 클릭하면 컴팩트 응답 말풍선이 토글됩니다 — 처음 클릭하면 파일, 이미지, 텍스트 순서로 클립보드를 채팅 초안에 담고 인라인 입력창이 열린 말풍선을 띄우며, 말풍선이 열려 있을 때 다시 클릭하면 초안은 그대로 둔 채 말풍선만 닫고, 한 번 더 클릭하면 클립보드를 다시 읽지 않고 같은 내용을 다시 보여줍니다. 클립보드 먹이기 단축키의 기본값은 `Option+S`이며, Settings의 단축키 입력란을 클릭한 뒤 ⌃/⌥/⌘ 중 하나 이상을 포함한 키 조합을 눌러 원하는 대로 다시 등록할 수 있고, **기본값** 버튼으로 초기화할 수 있습니다. 지침을 추가한 뒤 Return을 누르면 클립보드 내용과 지침을 함께 전송합니다.

취소, 권한 거부, 빈 입력, 유효하지 않은 첨부 파일, 에이전트 미선택 시에는 요청을 전송하지 않습니다. 각 파일은 20 MB로 제한되며 폴더, symlink, alias, 지원하지 않는 형식, 알려진 credential 파일은 거부됩니다.

## 지원하는 로컬 CLI

| CLI | 검증된 실행 경계 |
|---|---|
| Hermes | `hermes acp` / ACP v1; 모든 권한 요청은 `cancelled` 반환 |
| OpenCode | `opencode run --pure --format json` |
| Codex | `codex exec`, read-only sandbox, untrusted approval |
| Claude Code | structured print 실행, plan permission mode |

이 이름들은 호환성을 설명하기 위해서만 사용된 상표입니다. YumYum Agent는 해당 벤더들과 독립적이며 후원이나 보증을 주장하지 않습니다. 로그인, 네트워크 요청, 모델 제공자 처리 및 결과는 각 CLI가 담당합니다.

## 개인정보 보호 및 Soul

YumYum Agent는 telemetry를 전송하지 않으며 Keychain이나 CLI 로그인 파일을 읽지 않습니다. 첫 요청에서는 사용자가 선택한 텍스트, 파일 또는 캡처만 선택된 CLI에 전달합니다. 후속 요청에는 대화 기록 텍스트와 맥락도 포함되지만, 로컬 첨부 파일 경로는 화면에 표시되는 대화 기록 텍스트에서 제외됩니다. CLI는 자체 설정에 따라 네트워크를 사용할 수 있습니다. Soul은 `~/Library/Application Support/YumYum/SOUL.md`에 plaintext로 저장되며, 새 논리 세션의 첫 prompt에 안전 정책보다 낮은 우선순위로 삽입됩니다.

공개 앱 ID는 `io.github.kyu91.yumyumagent`입니다. 이 마이그레이션이 도입된 뒤 처음 실행할 때 `kr.yumyum.phase0` 프리뷰 설정을 한 번만 확인하고, 새 도메인에 해당 값이 없는 경우에만 언어, 테마, 단축키, 선택한 에이전트 설정을 복사합니다. 이후 실행에서는 다시 확인하지 않으며, 기존 프리뷰 설정을 삭제하거나 Soul, 자격증명, 선택한 에이전트 설정 외 경로, macOS 개인정보 보호 권한을 이전하지 않습니다.

[개인정보 보호](PRIVACY.md) 및 [Soul 형식](docs/soul-format.md)을 참고하세요.

기본 영어 제품 기준 문서는 [제품 명세](docs/product-spec.md)입니다. [보존된 한국어 명세](YumYum-Agent-Product-Spec.ko.md)는 완전한 목표 상태 원문이며, 현재 소스, 테스트 또는 이 README보다 우선하지 않습니다.

## 안전 경계 및 제한 사항

- 현재 connector는 분석 전용입니다. 외부 변경 UI와 실행 연결은 구현되지 않았습니다.
- 로컬 build와 **Unsigned Preview** DMG는 서명되거나 공증되지 않았습니다. App Store build와 자동 업데이트는 제공되지 않습니다.
- 로컬 `.app` bundle이 서명되지 않았거나(ad-hoc) 서명이라, macOS가 rebuild할 때마다 TCC 권한을 다시 키잉합니다. `./scripts/build-app.sh`를 실행할 때마다 입력 모니터링, 손쉬운 사용, 화면 기록 권한을 다시 허용해야 합니다.
- 실제 모델 응답은 외부 CLI 설치, 로그인, 네트워크 및 provider 상태에 따라 달라집니다.
- 화면 캡처는 직사각형 영역 선택만 지원합니다. 전역 단축키에는 macOS 개인정보 보호 권한이 필요할 수 있습니다.
- 비정상 종료 후 남은 일반 `YumYum-Capture-*` 파일은 다음 앱 실행 시 best-effort 방식으로 정리됩니다.

## 현지화 수동 검증

- **General**에서 `settings-language-picker`가 `English`와 `한국어`를 표시하는지 확인합니다.
- 설정, Soul 초안, 에이전트 상태, 채팅, 첨부 파일 및 panel에 내용이 있는 상태에서 언어를 전환합니다. 다시 실행하지 않아도 label이 갱신되어야 하며 상태나 scroll position이 초기화되면 안 됩니다.
- 대화 중간에 한국어로 전환하고 session을 reset하지 않은 채 follow-up을 보냅니다. 에이전트의 답변이 한국어로 오는지 확인한 뒤, 영어로 되돌리고 다음 답변이 영어로 오는지 확인합니다.
- 종료 후 다시 실행하여 명시적으로 선택한 언어가 유지되는지 확인합니다.
- 저장된 선택이 없을 때, 첫 번째로 해석된 macOS 선호 언어가 한국어인 경우에만 한국어가 선택되고 그 외에는 영어가 사용되는지 확인합니다.

## 펫 동작 수동 검증

- 왼쪽 드래그는 계속 펫 창을 이동하고 클립보드를 담지 않으며, 오른쪽 클릭은 창을 이동하지 않는지 확인합니다. 오른쪽 클릭은 빠른 메뉴를 열고 왼쪽 클릭은 컴팩트 응답 말풍선에 클립보드를 채팅 초안으로 담되 Return 전에는 전송하지 않아야 합니다. 초안 이미지는 썸네일과 제거 컨트롤을 표시해야 합니다. 말풍선이 열린 상태에서 펫을 다시 클릭하면 초안은 그대로 둔 채 닫혀야 하고, 한 번 더 클릭하면 클립보드를 다시 읽지 않고 같은 내용으로 다시 열려야 합니다.
- **시스템 설정 → 개인정보 보호 및 보안**에서 손쉬운 사용과 입력 모니터링을 모두 허용하고 앱을 다시 실행한 뒤, 다른 앱을 전면에 둔 상태에서 이미지를 복사하고 클립보드 먹이기 단축키를 누른 뒤, 응답 말풍선이 포커스를 가진 채 열리는지 확인하고 Return을 눌러 메시지가 전송되는지 확인합니다.
- 컴팩트 말풍선에서 두 번 연속 후속 메시지를 보내고, 모든 턴이 말풍선 안에 쌓이며 스크롤되는지, 닫았다 다시 열어도 대화 기록이 유지되는지, 상세 채팅창의 **새 세션**을 누르면 비워지는지 확인합니다.

## 에이전트 설정 수동 검증

- **Agent** 상단에는 `agent-setup-card`가 항상 표시되어 에이전트 선택, **찾아 등록**, **설치 안내**로 이미 하나를 등록한 뒤에도 다른 에이전트를 계속 등록할 수 있는지 확인하고, 이전에 제거한 에이전트가 있으면 **숨긴 에이전트**도 그 안에 함께 표시되는지 확인합니다.
- 설치 여부와 관계없이 각 에이전트 행에 해당 **설치 안내**가 표시되는지 확인합니다.
- 지원 에이전트를 찾아 등록하면 로컬에서 검증한 뒤 기본 에이전트로 선택되는지 확인합니다. Codex는 ChatGPT 로그인이 성공할 때까지 선택되지 않아야 합니다.
- 에이전트를 목록에서 제거하면 실행 파일은 삭제하지 않고 YumYum에서만 숨기며, 다시 찾아 등록하면 목록에 복원되는지 확인합니다.

## 기여하기

- [기여 가이드](CONTRIBUTING.md)
- [보안 정책](SECURITY.md)
- [행동 강령](CODE_OF_CONDUCT.md)
- [변경 기록](CHANGELOG.md)
- [릴리스 상태](docs/release.md)

## 라이선스

[Apache License 2.0](LICENSE)
