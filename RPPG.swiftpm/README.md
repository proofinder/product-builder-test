# RPPG.swiftpm — iPad에서 바로 빌드·실행

이 폴더는 **Swift Playgrounds(iPadOS)** 로 열면 Mac 없이 아이패드에서 바로 빌드하고
실행할 수 있는 App Playground입니다.

## 아이패드에 받는 법

1. Safari에서 저장소를 열고 **Code ▸ Download ZIP**
2. **파일** 앱에서 받은 zip을 탭해 압축 해제
3. `RPPG.swiftpm` 을 탭 → Swift Playgrounds가 열림
4. 오른쪽 위 **▶︎** 로 실행 (첫 실행 때 카메라 권한 허용)

> 시뮬레이터가 아니라 아이패드 실기기에서 도는 것이므로 카메라가 실제로 동작합니다.

## 이 폴더는 생성물입니다

`tools/make_swiftpm.py` 가 `Sources/RPPGCore` 와 `App/RPPG` 를 여기에 복사합니다.
App Playground는 단일 타깃이라 두 모듈을 하나로 합치고 `import RPPGCore` 줄만 제거합니다.

**여기 있는 파일을 직접 고치지 마세요.** 원본을 고치고 스크립트를 다시 돌리면 됩니다:

```bash
python3 tools/make_swiftpm.py
```

유닛 테스트(`swift test`)와 `rppg-replay` 는 저장소 루트의 `Package.swift` 를 씁니다.
이 매니페스트는 Swift Playgrounds 전용(`import AppleProductTypes`)이라
명령줄 SwiftPM으로는 열리지 않습니다.
