# Unsigned Preview / 서명되지 않은 프리뷰

> **This build is not Developer ID signed or Apple notarized.** Download it only from the official `kyu91/yumyum-agent` repository and verify the provided SHA-256 file before opening it.
>
> **이 빌드는 Developer ID로 서명되거나 Apple 공증을 받지 않았습니다.** 공식 `kyu91/yumyum-agent` 저장소에서만 다운로드하고, 열기 전에 제공된 SHA-256 파일을 검증하세요.

Requires macOS 14 or later. The DMG contains `arm64` and `x86_64` slices, but execution on Intel hardware has not been verified. Model responses require a separately installed and signed-in supported CLI; its network and provider behavior remain outside YumYum Agent.

macOS 14 이상이 필요합니다. DMG에는 `arm64`와 `x86_64` slice가 모두 포함되지만 Intel 하드웨어 실행은 검증되지 않았습니다. 모델 응답을 사용하려면 지원 CLI를 별도로 설치하고 로그인해야 하며, 해당 CLI의 네트워크 및 provider 동작은 YumYum Agent의 범위 밖입니다.

## Install / 설치

1. Verify the checksum: `shasum -a 256 -c YumYum-Agent-<version>-macOS.dmg.sha256`
2. Open the DMG and drag **YumYum.app** to **Applications**.
3. Control-click or right-click the app and choose **Open**. If macOS still blocks it, use **System Settings → Privacy & Security → Open Anyway**. Warning text varies by macOS version.
4. Never disable Gatekeeper globally. macOS may still request Screen Recording, Input Monitoring, or Accessibility permission for app features.

1. 체크섬을 검증합니다: `shasum -a 256 -c YumYum-Agent-<version>-macOS.dmg.sha256`
2. DMG를 열고 **YumYum.app**을 **Applications**로 드래그합니다.
3. 앱을 Control-클릭 또는 우클릭하고 **Open(열기)**을 선택합니다. 계속 차단되면 **System Settings → Privacy & Security → Open Anyway**를 사용하세요. 경고 문구는 macOS 버전에 따라 다릅니다.
4. Gatekeeper를 전역으로 비활성화하지 마세요. 앱 기능 사용 시 macOS가 Screen Recording, Input Monitoring 또는 Accessibility 권한을 요청할 수 있습니다.
