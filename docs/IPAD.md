# 아이패드에서 받아서 바로 실행하기

Mac도 Xcode도 없이, **아이패드 하나로** 소스를 받아 빌드하고 실행할 수 있습니다.
`RPPG.swiftpm` 폴더가 그 용도입니다 (Swift Playgrounds용 App Playground).

## 준비물

- iPadOS 16 이상
- **Swift Playgrounds** (App Store 무료)

## 받는 순서

1. 아이패드 **Safari**에서 저장소를 엽니다
   `https://github.com/proofinder/product-builder-test`
2. 브랜치를 `claude/ios-tablet-remote-ppg-ld2gl6` 으로 바꿉니다
3. 초록색 **Code ▸ Download ZIP**
4. 다운로드가 끝나면 **파일** 앱 ▸ 다운로드 ▸ 받은 zip을 탭해서 압축 해제
5. 풀린 폴더 안의 **`RPPG.swiftpm`** 을 탭 → Swift Playgrounds가 열립니다
6. 오른쪽 위 **▶︎** 실행. 첫 실행 때 카메라 권한을 허용하면 바로 측정 화면이 뜹니다

> 시뮬레이터가 아니라 아이패드 실기기에서 도는 것이라 카메라가 실제로 동작합니다.
> 앱은 landscape 고정이므로 아이패드를 가로로 두세요.

### 특정 폴더만 받고 싶다면

zip 전체가 부담스러우면 Working Copy(유료) 같은 iPad용 git 클라이언트로
브랜치를 클론한 뒤 `RPPG.swiftpm` 을 Swift Playgrounds로 열어도 됩니다.

## 녹화 파일 꺼내기

앱의 **Record CSV ▸ Stop recording ▸ Export** 를 누르면 공유 시트가 뜹니다.
파일 앱에 저장하거나 AirDrop / 메일로 Mac에 보낼 수 있습니다.
그 CSV가 `rppg-replay` 와 `matlab/pos_reference.m` 의 입력입니다
(`matlab/README.md` 참고).

## 아이패드 버전과 Mac 버전의 관계

| | 무엇 | 언제 |
|---|---|---|
| `RPPG.swiftpm` | Swift Playgrounds용, **아이패드에서 빌드·실행** | 기기에서 바로 돌려볼 때 |
| `App/RPPG.xcodeproj` | Xcode용 | Mac에서 개발·디버깅할 때 |
| 루트 `Package.swift` | `swift test`, `swift run rppg-replay` | 알고리즘 검증 (기기 불필요) |

**소스는 하나입니다.** `Sources/RPPGCore` 와 `App/RPPG` 가 원본이고,
`RPPG.swiftpm` 은 거기서 생성됩니다:

```bash
python3 tools/make_swiftpm.py
```

App Playground는 타깃이 하나뿐이라 두 모듈을 합치고 `import RPPGCore` 줄만 제거합니다.
그래서 `RPPG.swiftpm` 안의 파일은 **직접 고치면 안 됩니다** — 다음 생성 때 덮어써집니다.

## 알려진 제약

- Swift Playgrounds에는 유닛 테스트 러너가 없습니다. `swift test` 는 Mac(또는 Linux)에서
  루트 패키지로 돌려야 합니다.
- `RPPG.swiftpm/Package.swift` 는 `import AppleProductTypes` 를 쓰므로 명령줄 SwiftPM으로는
  열리지 않습니다. 정상입니다.
- Swift Playgrounds로 만든 앱은 기기에 설치되지만, App Store 배포는 Xcode가 필요합니다.
