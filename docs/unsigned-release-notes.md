# Unsigned Preview / 서명되지 않은 프리뷰

> **This build is not Developer ID signed or Apple notarized.** Download it only from the official `kyu91/yumyum-agent` repository.
>
> **이 빌드는 Developer ID로 서명되거나 Apple 공증을 받지 않았습니다.** 공식 `kyu91/yumyum-agent` 저장소에서만 다운로드하세요.

Requires macOS 14 or later. The DMG contains `arm64` and `x86_64` slices, but execution on Intel hardware has not been verified. Model responses require a separately installed and signed-in supported CLI; its network and provider behavior remain outside YumYum Agent.

macOS 14 이상이 필요합니다. DMG에는 `arm64`와 `x86_64` slice가 모두 포함되지만 Intel 하드웨어 실행은 검증되지 않았습니다. 모델 응답을 사용하려면 지원 CLI를 별도로 설치하고 로그인해야 하며, 해당 CLI의 네트워크 및 provider 동작은 YumYum Agent의 범위 밖입니다.

## Install / 설치

1. Download `YumYum-Agent-<version>-macOS.dmg` from this official release.
2. Open the DMG.
3. Drag **YumYum.app** to **Applications**.
4. Launch **YumYum.app** once. If macOS blocks it, acknowledge or close the warning.
5. Open **System Settings → Privacy & Security**, scroll to **Security**, and click **Open Anyway**.
6. Authenticate if prompted, then confirm **Open**.

Button names and warning text can vary by macOS version. macOS may also request Screen Recording, Input Monitoring, or Accessibility permission for app features.

1. 이 공식 릴리스에서 `YumYum-Agent-<version>-macOS.dmg`를 다운로드합니다.
2. DMG를 엽니다.
3. **YumYum.app**을 **Applications(응용 프로그램)**로 드래그합니다.
4. **YumYum.app**을 한 번 실행합니다. macOS가 차단하면 경고를 확인하거나 닫습니다.
5. **시스템 설정 → 개인정보 보호 및 보안**을 열고 **보안** 섹션까지 스크롤한 뒤 **확인 없이 열기**를 클릭합니다.
6. 요청되면 인증하고 **열기**를 확인합니다.

버튼 이름과 경고 문구는 macOS 버전이나 표시 언어에 따라 다를 수 있습니다. 앱 기능 사용 시 macOS가 화면 기록, 입력 모니터링 또는 손쉬운 사용 권한을 요청할 수도 있습니다.

## Optional SHA-256 verification (recommended) / 선택 사항: SHA-256 검증(권장)

Download both release files to **Downloads**, or place them in the same folder. If they are in Downloads, run:

두 릴리스 파일을 모두 **다운로드** 폴더에 받거나 같은 폴더에 둡니다. 다운로드 폴더에 있다면 다음 명령을 실행하세요.

```sh
cd ~/Downloads && shasum -a 256 -c YumYum-Agent-<version>-macOS.dmg.sha256
```
