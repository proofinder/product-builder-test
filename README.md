# rPPG for iPad — 전면 카메라 기반 remote PPG / 호흡 측정

태블릿 전면 카메라로 얼굴을 추적하고, 피부 ROI의 색 변화에서 POS 알고리즘으로 맥파(rPPG)를,
추적된 얼굴 코너의 수직 움직임에서 호흡 신호를 추출하는 iOS 앱입니다.

---

## 1. 사양 대응표

| 사양 | 구현 위치 |
|---|---|
| 1. 얼굴 검출 및 tracking (rotation 포함) | `App/RPPG/Capture/FaceTracker.swift` |
| 1. frame rate / tracking rate 이원화 | `App/RPPG/Capture/CaptureCoordinator.swift` |
| 1. 코너 4개 좌표 평균 y = 호흡 신호 | `FaceQuad.meanCornerY` → `RespirationPipeline` |
| 2. 얼굴 중앙 80% ROI | `FaceQuad.scaled(0.8)` → `ROISampler` |
| 3. EWMA `y = λy + (1−λ)x` | `Sources/RPPGCore/EWMA.swift` |
| 4. POS 알고리즘 | `Sources/RPPGCore/POS.swift` |

### 사양 4번에 대한 참고

전달받은 메시지가 **4번 POS 알고리즘 설명 도중에 잘려 있었습니다.** 나머지 내용을 알려주시면 그대로 맞추겠습니다.
그 사이 다음과 같이 구현해 두었습니다.

- 3번에서 EWMA를 "rPPG 추출 알고리즘에 사용될" 것으로 정의하셨으므로, **EWMA 기반 스트리밍 POS**(`StreamingPOS`)를
  기본 구현으로 사용했습니다. 원 논문의 1.6초 윈도우 평균을 persistent EWMA 상태로 대체한 형태이며,
  프레임당 O(1)이라 60 Hz 실시간 처리가 가능합니다.
- 검증/오프라인 분석용으로 **원 논문 그대로의 윈도우 + overlap-add 버전**(`WindowedPOS`)도 함께 넣었습니다.
  테스트에서 두 구현이 같은 심박수를 내는지 비교합니다.

두 구현의 관계:

```
원 논문 POS                          이 저장소의 StreamingPOS
─────────────────────────────────    ─────────────────────────────────
Cn = C / mean(C, 1.6초 윈도우)   →   Cn = C / EWMA(C, τ = 1.6 s)
S1 = [ 0, 1,−1]·Cn                   동일
S2 = [−2, 1, 1]·Cn                   동일
α  = std(S1)/std(S2)  (윈도우)   →   α  = EW-std(S1) / EW-std(S2)
h  = S1 + α·S2                       동일
H += h − mean(h)      (overlap-add) → out = h − EWMA(h)
```

`POSProjection.project(red:green:blue:)`가 두 구현이 공유하는 투영 행렬입니다.

---

## 2. 구조

```
Package.swift                     RPPGCore (순수 Swift, 플랫폼 비의존 — Linux/macOS에서 테스트 가능)
Sources/RPPGCore/
  EWMA.swift                      EWMA, EWStatistics(러닝 표준편차), EWMAHighPass
  RingBuffer.swift                고정 용량 FIFO
  Biquad.swift                    Butterworth band-pass (맥파 0.7–4 Hz, 호흡 0.1–0.6 Hz)
  FFT.swift                       radix-2 FFT (Accelerate 비의존)
  SpectralRateEstimator.swift     detrend → Hann → zero-pad → 피크 + 포물선 보간 + SNR
  FaceGeometry.swift              Point2D / FaceQuad / QuadSmoother
  RGBSample.swift                 ROI 평균 RGB 1샘플
  POS.swift                       StreamingPOS + WindowedPOS(레퍼런스)
  PulsePipeline.swift             맥파 체인 / 호흡 체인
  RPPGEngine.swift                이원화된 두 진입점을 묶는 최상위 엔진

App/RPPG/
  RPPGApp.swift                   앱 진입점
  RPPGViewModel.swift             @MainActor UI 상태
  Capture/
    CameraSession.swift           AVCaptureSession (노출·화이트밸런스 고정, HDR off, 프레임 간격 고정)
    CaptureGeometry.swift         orientation/mirroring 단일 소스
    FaceTracker.swift             Vision 검출 + 객체 추적, roll 포함
    ROISampler.swift              회전된 ROI 내부 픽셀 공간 평균
    CaptureCoordinator.swift      frame rate ↔ tracking rate 이원화의 실제 구현
  Views/                          SwiftUI 화면 (프리뷰, ROI 오버레이, 파형, 진단)

App/RPPG.xcodeproj                Xcode 16 이상에서 바로 열림
project.yml                       XcodeGen으로 프로젝트 재생성용
Tests/RPPGCoreTests/              합성 신호 기반 유닛 테스트
```

---

## 3. frame rate / tracking rate 이원화

`CaptureCoordinator`가 두 경로를 나눕니다.

**프레임 경로 (30 / 60 Hz)** — 카메라 콜백 큐 = 처리 큐. 매 프레임마다
ROI를 한 스텝 전진시키고 픽셀을 평균해 `StreamingPOS`에 넣습니다. 동기·무할당 경로입니다.

**추적 경로 (4 Hz)** — tick이 도래하면 **별도의 vision 큐**로 최신 프레임을 넘깁니다.
Vision이 느려도 카메라 프레임이 드롭되지 않고 tracking tick만 밀립니다.
동시에 한 건만 실행하며, 실행 중 도래한 tick은 건너뜁니다.

### ROI가 4 Hz로 계단처럼 튀지 않게 하는 부분

트래커 결과를 그대로 ROI에 적용하면 초당 4번 ROI가 점프하고, **그 4 Hz 성분이 맥파 대역
(0.7–4 Hz) 안에 그대로 들어옵니다.** 그래서 `QuadSmoother`가 코너 8개 좌표(x, y × 4)를
각각 EWMA(τ ≈ 0.25 s, 프레임 레이트로 동작)에 통과시켜 ROI가 연속적으로 미끄러지게 합니다.
사양 3번의 EWMA가 여기에도 쓰입니다.

---

## 4. 측정 품질에 결정적인 카메라 설정

`CameraSession`에서 다음을 강제합니다. rPPG에서는 화질보다 이쪽이 훨씬 중요합니다.

- **노출·화이트밸런스 잠금** (기본 2초 후). 연속 자동 노출은 맥파와 같은 크기(DC의 약 1%)의
  밝기 변화를 그대로 상쇄해 버립니다. UI의 "Re-balance camera" 버튼으로 재수렴 후 재잠금할 수 있습니다.
- **HDR / 톤 매핑 비활성화.** 측정 대상 자체에 대한 프레임 의존 비선형 변환이기 때문입니다.
- **min == max 프레임 간격 고정.** DSP가 가정하는 샘플레이트와 실제가 일치해야 합니다.

앱은 landscape 고정입니다. 캡처 커넥션의 orientation/mirroring을 `CaptureGeometry` 한 곳에서
프리뷰 레이어와 비디오 출력에 동일하게 적용하므로, Vision의 픽셀 좌표가 균일 스케일 하나만 거쳐
화면 좌표로 매핑됩니다(`AspectFillMapping`).

---

## 5. 빌드 / 실행

**요구사항:** Xcode 16 이상, iOS 16 이상 기기. 카메라가 필요하므로 **시뮬레이터에서는 측정이 되지 않습니다.**

```bash
open App/RPPG.xcodeproj      # 스킴 RPPG, 실기기 선택 후 실행
```

프로젝트 파일을 다시 만들고 싶다면:

```bash
brew install xcodegen
xcodegen generate --spec project.yml --project App
```

**유닛 테스트** (macOS 또는 Linux, 기기 불필요):

```bash
swift test
```

---

## 6. 튜닝 파라미터

| 위치 | 값 | 기본 | 의미 |
|---|---|---|---|
| `CaptureCoordinator.Settings` | `targetFrameRate` | 60 | 카메라가 허용하는 최대치 내에서 요청 |
| | `trackingRate` | 4 | 사양의 tracking rate |
| | `roiScale` | 0.8 | 얼굴 중앙 80% |
| | `roiSmoothingTimeConstant` | 0.25 s | ROI 활강 EWMA |
| `StreamingPOS.Configuration` | `normalizationTimeConstant` | 1.6 s | 원 논문 윈도우 길이에 대응 |
| | `statisticsTimeConstant` | 1.6 s | α-tuning용 러닝 표준편차 |
| | `outputTimeConstant` | 1.0 s | overlap-add의 평균 제거에 대응 |
| `PulsePipeline.Configuration` | `band` | 0.7–4.0 Hz | 42–240 bpm |
| | `bufferSeconds` | 10 s | 길수록 스펙트럼 피크가 날카롭지만 반응이 느려짐 |
| `RespirationPipeline.Configuration` | `band` | 0.1–0.6 Hz | 6–36 회/분 |
| | `bufferSeconds` | 45 s | |
| `ROISampler` | `pixelStride` | 2 | 공간 평균 서브샘플링 |
| | `skinGateEnabled` | false | YCbCr 피부색 게이트 (안경·머리카락 배제용, UI 토글) |

---

## 7. 테스트

`Tests/RPPGCoreTests/SyntheticSignal.swift`가 POS가 가정하는 모델

```
C(t) = I(t) · ( dc + a · p(t) · pulseDirection )
```

로 합성 ROI 신호를 만듭니다. `I(t)`는 전 채널 공통 밝기 변화(조명·움직임)입니다. 주요 검증:

- EWMA 점화식이 사양과 정확히 일치 (`testRecurrenceMatchesSpecification`)
- 맥파의 10배 크기인 공통 밝기 변화가 있어도 심박수 복원 (`testStreamingPOSRecoversTheHeartRate`)
- **맥파가 없고 밝기 변화만 있을 때 출력이 0** — POS가 제 역할을 하는지 (`testPOSRejectsChannelCommonIntensityChanges`)
- 스트리밍 POS와 원 논문 윈도우 POS가 같은 심박수를 냄 (`testStreamingPOSTracksTheWindowedReference`)
- 이원화된 엔진에서 심박 72 bpm / 호흡 15 회/분 동시 복원 (`testEngineDualRateWiring`)
- 회전된 quad의 코너·roll·중앙 80% ROI·점 포함 판정 (`FaceGeometryTests`)

---

## 8. 알려진 제약

- **이 저장소의 코드는 아직 컴파일·실행 검증이 되지 않았습니다.** 작업 환경에 Swift 툴체인이
  없었고(다운로드도 프록시에서 차단됨) Xcode도 없어, `swift test`와 기기 실행은 여러분 쪽에서
  한 번 돌려주셔야 합니다.
- `App/RPPG.xcodeproj/project.pbxproj`는 손으로 작성했습니다(objectVersion 77, file-system
  synchronized group 사용). Xcode가 열지 못하면 위의 `xcodegen generate`로 재생성하세요.
- Vision의 `roll` 부호는 y-down 픽셀 좌표계에 맞추어 뒤집었습니다
  (`FaceTracker.imageRoll(of:)`). 오버레이 ROI가 머리 기울기와 반대로 돌면 이 한 줄의 부호를
  바꾸면 됩니다.
- 화면 회전 대응은 넣지 않았습니다. landscape 고정 전제입니다.
- **의료기기가 아닙니다.** 진단 목적으로 사용하지 마세요.
