# rPPG for iPad — 전면 카메라 기반 remote PPG / 호흡 측정

태블릿 전면 카메라로 얼굴을 추적하고, 피부 ROI의 색 변화에서 POS 알고리즘으로 맥파(rPPG)를,
추적된 얼굴 코너의 수직 움직임에서 호흡 신호를 추출하는 iOS 앱입니다.

**기준 구현은 `matlab/rPPG_test.m`입니다.** Swift는 여기에 맞추고, 반대가 아닙니다.
개발은 단계별로 검증하며 진행합니다 — [`docs/PLAN.md`](docs/PLAN.md), 검증 절차는
[`matlab/README.md`](matlab/README.md).

---

## 사양 대응표

| 사양 | 구현 위치 |
|---|---|
| 1. 얼굴 검출 및 tracking (rotation 포함) | `App/RPPG/Capture/FaceTracker.swift` |
| 1. frame rate / tracking rate 이원화 | `App/RPPG/Capture/CaptureCoordinator.swift` |
| 1. 코너 4개 좌표 평균 y = 호흡 신호 | `FaceQuad.meanCornerY` → `RespirationPipeline` |
| 2. 얼굴 중앙 80% ROI | `FaceQuad.scaled(_:)` → `ROISampler` |
| 3. EWMA `y = λy + (1−λ)x` | `Sources/RPPGCore/EWMA.swift` |
| 4. POS 알고리즘 | `Sources/RPPGCore/POSProcessor.swift` |

### POS — `rPPG_test.m` 133–170행 그대로

```
Cmean = λ1*Cmean + (1-λ1)*C                 // 초기값 C
S     = [0 1 -1; -2 1 1] * (C ./ Cmean)
Smean = λ1*Smean + (1-λ1)*S                 // 초기값 S
Svar  = λ1*Svar  + (1-λ1)*(S-Smean).^2      // 초기값 (S-Smean).^2
Sstd  = sqrt(Svar)
h     = S(1)/(Sstd(1)+1e-9) + 1/(Sstd(2)+1e-9)*S(2)
hmean = λ2*hmean + (1-λ2)*h                 // 초기값 h
rPPG += (h - hmean)                         // 누적합
```

`λ1 = 0.99`, `λ2 = 0.9` — 레퍼런스 21–22행. **fps와 무관한 고정 상수**입니다.
λ를 fps에 맞춰 재계산하면 MATLAB과의 수치 대조가 깨지므로 하지 않습니다.

수치가 일치하도록 지킨 것들:

- `(1 - λ)`를 **계산**합니다. `1 - 0.99`는 `0.010000000000000009`이지 `0.01`이 아닙니다.
- `h`의 **비대칭 형태**를 유지합니다 — `S(1)`은 나누고, `S(2)`는 역수를 곱합니다.
  마지막 비트가 다르고, 그 차이가 누적합을 타고 커집니다.
- `Svar`는 `E[S²]−E[S]²`가 아니라 사양의 `(S−Smean)²` EWMA 형태입니다.

초기 구간 폭주는 일어나지 않습니다. 첫 스텝은 `C == Cmean`이라 `S = [0;0]`,
따라서 `h = 0/1e−9 = 0`입니다. 이후에도 `Sstd`가 `|S|`에 비례해 자라므로 `h`는
`1/√(1−λ1) ≈ 10` 규모에 머뭅니다 (40초 합성 데이터 실측 `max|h| = 20.2`).

---

## 구조

```
Sources/RPPGCore/                 순수 Swift, 플랫폼 비의존 — 기기 없이 테스트 가능
  EWMA.swift                      y = λy + (1-λ)x, 첫 샘플로 priming
  POSVectors.swift                ChannelTriple(3×1) / ProjectionPair(2×1)
  POSProcessor.swift              POS 본체 + 모든 중간값(Step)
  SignalRecord.swift              프레임별 CSV 스키마 + 파서 (17자리 무손실)
  PulsePipeline.swift             rppg(원본) / analysis(band-pass 사본) 분리, 호흡 체인
  RPPGEngine.swift                이원화된 두 진입점
  Biquad / FFT / SpectralRateEstimator / RingBuffer / FaceGeometry / ROISample

Sources/rppg-replay/              오프라인 러너: CSV의 C만으로 POS 재계산 · MATLAB 대조

App/RPPG/
  Capture/CameraSession.swift     노출·화이트밸런스·HDR 잠금, 프레임 간격 고정
  Capture/FaceTracker.swift       Vision 검출(roll) + 객체 추적 fallback, 4 Hz
  Capture/ROISampler.swift        회전된 ROI 내부 픽셀 평균 → C
  Capture/CaptureCoordinator.swift  frame rate ↔ tracking rate 이원화, 녹화
  Capture/SignalRecorder.swift    프레임별 CSV 기록 + 내보내기
  Views/                          프리뷰, ROI 오버레이, 파형, POS 중간값, 진단

matlab/rPPG_test.m                원본 레퍼런스 (수정 금지)
matlab/pos_reference.m            133–170행만 CSV 입출력으로 감싼 것
tools/gen_golden.py               합성 C + 골든 POS 출력 생성
Tests/RPPGCoreTests/Fixtures/     synthetic_C.csv, golden_pos.csv
```

---

## frame rate / tracking rate 이원화

`CaptureCoordinator`가 두 경로를 나눕니다.

**프레임 경로 (30 / 60 Hz)** — 카메라 콜백 큐 = 처리 큐. 매 프레임 ROI를 한 스텝 전진시키고
픽셀을 평균해 `C`를 만들어 POS에 넣습니다. 동기·무할당 경로입니다.

**추적 경로 (4 Hz)** — tick이 도래하면 **별도의 vision 큐**로 최신 프레임을 넘깁니다.
Vision이 느려도 카메라 프레임이 드롭되지 않고 tracking tick만 밀립니다.

### ROI가 4 Hz로 계단처럼 튀지 않게 하는 부분

트래커 결과를 그대로 ROI에 적용하면 초당 4번 ROI가 점프하고, **그 4 Hz 성분이 맥파 대역
(0.7–4 Hz) 안에 그대로 들어옵니다.** `QuadSmoother`가 코너 8개 좌표를 각각
EWMA(τ ≈ 0.25 s, 프레임 레이트)에 통과시켜 ROI가 연속적으로 미끄러지게 합니다.

---

## 측정 품질에 결정적인 카메라 설정

`CameraSession`에서 강제합니다. rPPG에서는 화질보다 이쪽이 훨씬 중요합니다.

- **노출·화이트밸런스 잠금** (기본 2초 후). 연속 자동 노출은 맥파와 같은 크기(DC의 약 1%)의
  밝기 변화를 그대로 상쇄해 버립니다. UI의 "Re-balance camera"로 재수렴 후 재잠금할 수 있습니다.
- **HDR / 톤 매핑 비활성화.** 측정 대상 자체에 대한 프레임 의존 비선형 변환이기 때문입니다.
- **min == max 프레임 간격 고정.** DSP가 가정하는 샘플레이트와 실제가 일치해야 합니다.

앱은 landscape 고정입니다. orientation/mirroring을 `CaptureGeometry` 한 곳에서 프리뷰 레이어와
비디오 출력에 동일하게 적용하므로, Vision의 픽셀 좌표가 균일 스케일 하나만 거쳐 화면으로 매핑됩니다.

---

## 빌드 / 실행

**요구사항:** Xcode 16 이상, iOS 16 이상 기기. 카메라가 필요하므로 **시뮬레이터에서는 측정이 안 됩니다.**

```bash
open App/RPPG.xcodeproj      # 스킴 RPPG, 실기기 선택 후 실행
```

프로젝트 파일 재생성:

```bash
brew install xcodegen && xcodegen generate --spec project.yml --project App
```

**유닛 테스트 / 오프라인 검증** (기기 불필요):

```bash
swift test
swift run rppg-replay Tests/RPPGCoreTests/Fixtures/synthetic_C.csv --compare <matlab 출력>
```

---

## 튜닝 파라미터

| 위치 | 값 | 기본 | 의미 |
|---|---|---|---|
| `POSProcessor.Configuration` | `lambda1` | **0.99** | Cmean·Smean·Svar (레퍼런스 고정값) |
| | `lambda2` | **0.9** | hmean (레퍼런스 고정값) |
| | `epsilon` | 1e−9 | Sstd 나눗셈 가드 |
| `CaptureCoordinator.Settings` | `targetFrameRate` | 60 | 카메라 허용 범위 내 요청 |
| | `trackingRate` | 4 | 사양의 tracking rate |
| | `roiScale` | 0.8 | **MATLAB 대조 시 1.0** (레퍼런스는 박스 전체 평균) |
| | `roiSmoothingTimeConstant` | 0.25 s | ROI 활강 EWMA |
| `PulsePipeline.Configuration` | `band` | 0.7–4.0 Hz | **표시·심박 추정 전용** 사본에만 적용 |
| `RespirationPipeline.Configuration` | `band` | 0.1–0.6 Hz | 6–36 회/분 |
| `ROISampler` | `pixelStride` | 2 | 공간 평균 서브샘플링 |
| | `skinGateEnabled` | false | 켜면 `C`가 레퍼런스와 달라짐 — 대조용 녹화에는 끌 것 |

---

## 알려진 제약

- **Swift 코드는 아직 컴파일·실행 검증이 되지 않았습니다.** 작업 환경에 Swift 툴체인이 없고
  (다운로드도 프록시에서 차단) Xcode도 없어, `swift test`와 기기 실행은 여러분 쪽에서
  돌려주셔야 합니다. 반면 **알고리즘 자체는 검증되어 있습니다** — 골든 픽스처를 생성한
  Python 레퍼런스가 여기서 실행되었고, CSV 왕복 무손실(오차 0)과 72 bpm 복원을 확인했습니다.
- `App/RPPG.xcodeproj/project.pbxproj`는 손으로 작성했습니다(objectVersion 77, file-system
  synchronized group). Xcode가 열지 못하면 위의 `xcodegen generate`로 재생성하세요.
- Vision의 `roll` 부호는 y-down 픽셀 좌표계에 맞추어 뒤집었습니다
  (`FaceTracker.imageRoll(of:)`). ROI 오버레이가 머리 기울기와 반대로 돌면 그 한 줄의 부호를
  바꾸면 됩니다. Stage 2에서 가장 먼저 확인할 지점입니다.
- **트래킹 방식이 레퍼런스와 다릅니다.** MATLAB은 KLT 특징점 추적 + similarity 변환으로
  코너를 서브픽셀로 움직이는데, 현재는 Vision의 얼굴 bbox를 씁니다. Stage 2에서 랜드마크 기반
  similarity 피팅으로 교체할 것을 제안합니다 (`docs/PLAN.md` 5절).
- 화면 회전 대응은 없습니다. landscape 고정 전제입니다.
- **의료기기가 아닙니다.** 진단 목적으로 사용하지 마세요.
