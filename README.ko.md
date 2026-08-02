# YumYum Agent

[English](README.md) | [한국어](README.ko.md) *(현재)*

YumYum Agent는 선택한 화면 영역이나 로컬 파일을 플로팅 펫에게 “먹이고”, 설치된 로컬 CLI 에이전트의 응답을 네이티브 말풍선과 채팅으로 확인할 수 있는 Swift/AppKit macOS 앱입니다.

> **개발자 프리뷰(0.1.0):** 릴리스 파이프라인은 구현되었지만, 공개된 서명·공증 릴리스는 아직 검증되거나 배포되지 않았습니다.

## 기능

- 화면 캡처, 파일 선택, Finder 드롭, 채팅 입력을 위한 하나의 검증된 흐름
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

아직 공식 바이너리는 배포되지 않았습니다. 첫 공개 릴리스 이후 GitHub Releases에서 `YumYum-Agent-<version>-macOS.dmg`와 해당 `.sha256` 파일을 다운로드하고 체크섬을 검증한 다음, DMG를 열어 **YumYum Agent.app**을 **Applications**로 드래그하세요. 처음 실행할 때는 앱을 정상적으로 열고 macOS Gatekeeper 안내를 따르세요. 보안 우회 명령은 지원하지 않습니다.

로컬 개발자는 unsigned DMG를 명시적으로 생성하고 검증할 수 있습니다.

```sh
./scripts/package-release.sh --unsigned
./scripts/test-release.sh .build/release/YumYum-Agent-0.1.0-macOS.dmg
```

## 소스에서 빌드 및 실행

```sh
swift build
swift test
./scripts/build-app.sh
open ".build/YumYum Agent.app"
```

스크립트는 기본적으로 로컬 release `.build/YumYum Agent.app`을 생성합니다. debug bundle에는 `CONFIGURATION=debug ./scripts/build-app.sh`를 사용하세요.

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
2. YumYum Agent를 실행하고 **Settings → Agent**에서 탐색된 실행 파일을 명시적으로 선택합니다.
3. 필요한 경우 macOS Settings에서 Screen Recording, Input Monitoring 또는 Accessibility 권한을 부여합니다.
4. 펫을 클릭하거나 `Control+Option+Space`를 눌러 캡처하거나, 파일을 선택하거나, 채팅합니다.

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
- 로컬 build와 `--unsigned` DMG는 서명되거나 공증되지 않았습니다. 현재 App Store build, 자동 업데이트 또는 배포된 binary는 제공되지 않습니다.
- 실제 모델 응답은 외부 CLI 설치, 로그인, 네트워크 및 provider 상태에 따라 달라집니다.
- 화면 캡처는 직사각형 영역 선택만 지원합니다. 전역 단축키에는 macOS 개인정보 보호 권한이 필요할 수 있습니다.
- 비정상 종료 후 남은 일반 `YumYum-Capture-*` 파일은 다음 앱 실행 시 best-effort 방식으로 정리됩니다.

## 현지화 수동 검증

- **General**에서 `settings-language-picker`가 `English`와 `한국어`를 표시하는지 확인합니다.
- 설정, Soul 초안, 에이전트 상태, 채팅, 첨부 파일 및 panel에 내용이 있는 상태에서 언어를 전환합니다. 다시 실행하지 않아도 label이 갱신되어야 하며 상태나 scroll position이 초기화되면 안 됩니다.
- 종료 후 다시 실행하여 명시적으로 선택한 언어가 유지되는지 확인합니다.
- 저장된 선택이 없을 때, 첫 번째로 해석된 macOS 선호 언어가 한국어인 경우에만 한국어가 선택되고 그 외에는 영어가 사용되는지 확인합니다.

## 기여하기

- [기여 가이드](CONTRIBUTING.md)
- [보안 정책](SECURITY.md)
- [행동 강령](CODE_OF_CONDUCT.md)
- [변경 기록](CHANGELOG.md)
- [릴리스 상태](docs/release.md)

## 라이선스

[Apache License 2.0](LICENSE)
