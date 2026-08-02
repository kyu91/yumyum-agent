# Release readiness

YumYum 0.1.0은 현재 소스 빌드용 developer preview입니다. Developer ID 서명, hardened runtime, 공증, 배포 체크섬과 릴리스 자동화는 **구현되지 않았습니다**.

## 현재 source gate

```sh
swift build
swift test
./scripts/build-app.sh
git diff --check
```

`swift test`가 `Testing` 모듈을 찾지 못해서 실패한 경우에만 [README의 Command Line Tools 전체 회귀 명령](../README.md#소스-빌드와-실행)을 실행하며, 이 fallback도 성공해야 source gate를 통과합니다. 다른 실패에는 적용하지 않습니다.

번들에는 `Contents/MacOS/YumYum`, `Contents/Resources/yumyum-process-fixture`, `Contents/Info.plist`가 있어야 하며 fixture는 프로세스 진단·회귀 경계용입니다.

## 릴리스 전 결정 사항

- 번들 ID `kr.yumyum.phase0` 유지 또는 공개용 ID 확정
- Apple Silicon 전용 여부와 Intel/universal binary 지원·검증 범위
- Developer ID Application 인증서 소유자와 보관·회전 절차
- hardened runtime, 필요한 entitlements와 앱 샌드박스 전략
- 화면 기록, 입력 모니터링, 손쉬운 사용 등 TCC 권한 설명과 clean-machine 검증
- fixture 포함 필요성과 배포 번들 노출 위험
- ZIP/DMG 형식, 공증·stapling, SHA-256 체크섬 및 검증 안내
- 깨끗한 macOS 계정에서 설치, 최초 실행, CLI 발견, 캡처, VoiceOver, Reduce Motion 검증
- 실패한 릴리스 철회·교체·사용자 공지와 이전 버전 rollback 정책

향후 흐름은 clean source gate → release archive → Developer ID 서명 → hardened runtime/entitlement 확인 → 공증·stapling → clean-machine 검증 → 체크섬 게시 순서로 설계해야 합니다. 자격증명은 저장소나 CI 로그에 두지 않습니다.
