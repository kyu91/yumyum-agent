# Contributing

YumYum은 macOS 14 이상과 Swift tools 6.0을 대상으로 합니다. 작업 전 [AGENTS.md](AGENTS.md)의 안전·구조·검증 규칙을 읽어 주세요.

## 개발 흐름

1. 하나의 목적에 필요한 최소 변경만 만듭니다. 새 의존성, 범위 밖 리팩터링, 외부 변경 기능을 함께 넣지 않습니다.
2. API 키, 토큰, 로그인 파일, 개인 정보, 실제 사용자 경로나 캡처를 소스·fixture·로그에 넣지 않습니다.
3. CLI 계약 변경은 설치된 CLI의 `--version` 및 관련 `--help` 출력 근거와 정확한 executable URL·argv를 PR에 기록합니다. shell, `which`, 임의 PATH 검색을 추가하지 않습니다.
4. 버그 수정은 재현 테스트를 먼저, 기능 변경은 Core 정책·상태 테스트를 함께 추가합니다.
5. PR에는 변경 이유, 보안·개인정보·외부 변경 영향, 실행한 검증과 미실행 수동 검증을 적습니다.

## 자동 검증

```sh
swift build
swift test
./scripts/build-app.sh
git diff --check
git status --short --untracked-files=all
```

`swift test`가 `Testing` 모듈을 찾지 못해서 실패한 경우에만 [README의 Command Line Tools 전체 회귀 명령](README.md#소스-빌드와-실행)을 실행하고 성공해야 합니다. 다른 테스트 실패를 이 fallback으로 우회할 수 없습니다.

외부 CLI probe, 로그인, 네트워크 또는 모델 응답은 자동 검증으로 간주하지 않습니다.

## 수동 UI 확인

UI 변경은 실제 macOS에서 관련 항목을 확인합니다: VoiceOver label·순서, Reduce Motion, 포커스 비탈취, 다중 디스플레이와 혼합 배율 캡처, 화면 권한 거부, Finder 다중 드롭, 패널의 `visibleFrame` 보정, 테마·대비·투명도 변경 뒤 상태 보존.

## 보안 문제

민감한 취약점은 공개 Issue나 PR에 쓰지 말고 [SECURITY.md](SECURITY.md)를 따르세요. 모든 기여는 [행동 강령](CODE_OF_CONDUCT.md)과 [Apache License 2.0](LICENSE)의 적용을 받습니다.
