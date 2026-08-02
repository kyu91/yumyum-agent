# YumYum

YumYum은 화면 영역이나 로컬 파일을 macOS 플로팅 펫에 “먹이고”, 설치된 로컬 CLI 에이전트의 답변을 네이티브 말풍선과 채팅으로 보여 주는 Swift/AppKit 앱입니다.

> **Developer preview (0.1.0):** 현재는 소스 빌드용입니다. 배포 서명, 공증, 샌드박스 배포는 구현·검증되지 않았습니다.

## 주요 기능

- 화면 영역 캡처, 파일 선택, Finder 드롭, 채팅 입력을 하나의 검증·전송 흐름으로 처리
- 스트리밍 답변, transcript, 취소·재시도, Reduce Motion과 VoiceOver 고려
- 정확한 실행 경로와 로컬 `--version`/`--help` 계약으로 CLI를 발견·재검증
- 앱 소유 `SOUL.md`로 응답 성격을 설정하되 안전·개인정보 정책을 우선
- 외부 변경을 기본 거부하고 Hermes 권한 요청을 항상 취소

## 요구 환경

- macOS 14 이상
- Swift 6.0 이상이 포함된 Xcode 또는 Command Line Tools
- 아래 지원 CLI 중 하나(별도 설치·로그인 필요)

현재 수동 검증은 Apple Silicon macOS를 기준으로 합니다. Intel Mac 지원은 검증되지 않았습니다.

## 소스 빌드와 실행

```sh
swift build
swift test
./scripts/build-app.sh
open .build/YumYum.app
```

스크립트는 기본적으로 release 설정의 로컬 `.build/YumYum.app`을 만들며, `CONFIGURATION=debug ./scripts/build-app.sh`로 debug 번들을 만들 수 있습니다.

독립 Command Line Tools에서 `Testing` 모듈을 찾지 못할 때만 다음 전체 회귀 명령을 사용하세요.

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

1. 지원 CLI를 설치하고 해당 CLI에서 로그인을 완료합니다.
2. YumYum을 실행해 **설정 → Agent**에서 발견된 실행 파일을 명시적으로 선택합니다.
3. 필요하면 화면 기록, 입력 모니터링 또는 손쉬운 사용 권한을 macOS 설정에서 허용합니다.
4. 펫을 클릭하거나 `Control+Option+Space`를 눌러 캡처, 파일, 채팅을 시작합니다.

선택 취소, 권한 거부, 빈 입력, 무효 첨부, 에이전트 미선택 상태에서는 요청을 전송하지 않습니다. 파일은 각각 최대 20MB이며 폴더, symlink, alias, 미지원 형식과 알려진 자격증명 파일은 거부됩니다.

## 지원 로컬 CLI

| CLI | 확인된 실행 경계 |
|---|---|
| Hermes | `hermes acp` / ACP v1, 모든 권한 요청 `cancelled` |
| OpenCode | `opencode run --pure --format json` |
| Codex | `codex exec`, read-only sandbox, untrusted approval |
| Claude Code | 구조화된 print 실행, plan permission mode |

이 이름은 호환성을 설명하기 위한 상표입니다. YumYum은 해당 공급업체와 독립적인 프로젝트이며 공급업체의 후원·보증을 받았다고 주장하지 않습니다. 각 CLI의 로그인, 네트워크 요청, 모델 제공자 처리와 결과는 해당 CLI의 경계입니다.

## 개인정보와 Soul

YumYum은 telemetry를 전송하지 않으며 Keychain이나 CLI 로그인 파일을 읽지 않습니다. 최초 요청은 사용자가 선택한 텍스트·파일·캡처만 선택한 CLI에 전달됩니다. 후속 요청에는 대화 transcript의 텍스트와 문맥도 포함되지만, 로컬 첨부 경로는 transcript 텍스트에서 제외됩니다. 해당 CLI는 자체 설정에 따라 네트워크를 사용할 수 있습니다. Soul은 평문 `~/Library/Application Support/YumYum/SOUL.md`에 저장되고 새 논리 세션의 첫 프롬프트에 안전 정책보다 낮은 우선순위로 적용됩니다.

자세한 내용은 [개인정보 문서](PRIVACY.md)와 [Soul 형식](docs/soul-format.md)을 확인하세요.

## 안전 경계와 제한

- 현재 Connector는 분석 전용입니다. 외부 변경 UI와 실행 연결은 구현되지 않았습니다.
- 로컬 `.app`은 서명·공증되지 않았고 App Store, 자동 업데이트, 배포 바이너리를 제공하지 않습니다.
- 실제 모델 응답은 외부 CLI의 설치, 로그인, 네트워크와 제공자 상태에 의존합니다.
- 화면 캡처는 사각 영역 선택만 제공하며 전역 단축키는 macOS 개인정보 권한이 필요할 수 있습니다.
- 비정상 종료로 남은 YumYum 캡처 일반 파일은 다음 앱 시작 시 정리됩니다.

## 참여

- [기여 가이드](CONTRIBUTING.md)
- [보안 정책](SECURITY.md)
- [행동 강령](CODE_OF_CONDUCT.md)
- [변경 기록](CHANGELOG.md)
- [릴리스 상태](docs/release.md)

## 라이선스

[Apache License 2.0](LICENSE)
