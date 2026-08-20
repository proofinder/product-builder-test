# 개발 계획 — 단계별 검증 기반

목표: 각 단계마다 **눈으로 보고 숫자로 확인한 뒤** 다음 단계로 넘어가는 구조로 개발한다.

---

## 진행 현황

| Stage | 상태 |
|---|---|
| 0. 검증 인프라 | **완료** — CSV 스키마·기록기·`rppg-replay`·`pos_reference.m`·골든 픽스처 |
| 1. 캡처 + 레이트 이원화 | 코드 완료 + **앱에 통과 기준 실시간 표시**, 기기 검증 대기 |
| 2. 검출·트래킹·rotation | **레퍼런스 방식으로 재작성 완료** (랜드마크 + similarity 변환), 기기 검증 대기 |
| 3. ROI + C | 코드 완료, **기기 검증 대기** |
| 4. EWMA | **완료** — 사양 점화식 고정, 유닛 테스트 |
| 5. POS | **완료** — MATLAB 133–170행 그대로, 골든 대조 테스트 |
| 6. 호흡 | 코드 완료, **기기 검증 대기** |
| 7. 심박 + 마감 | 후처리만 배선됨 |

`lambda1 = 0.99`, `lambda2 = 0.9` — `rPPG_test.m` 21–22행에서 확정. fps 무관 고정 상수.

아이패드만으로 빌드·실행하려면 [`docs/IPAD.md`](IPAD.md).
트래킹 방식 후보 검토 결과는 [`docs/TRACKING.md`](TRACKING.md).

---

## 0. 폐기된 첫 구현과 확정 사양의 차이 (완료)

사양 4번이 잘린 상태에서 작성했던 `StreamingPOS`는 논문 표준형(alpha-tuning + overlap-add)이라
확정 사양과 **세 군데가 달랐다.** `POSProcessor`로 다시 썼다.

| 항목 | 폐기한 코드 | 확정 사양 (현재) |
|---|---|---|
| 분산 | `E[S²] − E[S]²` | `Svar = λ₁·Svar + (1−λ₁)·(S−Smean)²` |
| h | `h = S₁ + α·S₂`, `α = σ₁/σ₂` | `h = S₁/(σ₁+1e−9) + 1/(σ₂+1e−9)·S₂` |
| 출력 | `out = h − EWMA(h)` (high-pass) | `rPPG(n) = rPPG(n−1) + (h − hmean)` (**누적합**) |
| λ | 시간상수 하나 | `λ₁`(Cmean·Smean·Svar), `λ₂`(hmean) **두 개** |

`h`는 `S₁+ (σ₁/σ₂)·S₂`를 `1/σ₁`로 스케일한 것과 방향은 같지만, **시변 이득 `1/σ₁`이 붙는다는 점**이
다르다. 진폭 정규화 효과가 있고 초기 구간(σ가 0에 가까울 때) 거동도 달라지므로 사양대로 간다.

재사용한 것: `EWMA`, `FaceQuad`/`QuadSmoother`, `ROISampler`, `FaceTracker`, `CameraSession`,
`CaptureCoordinator`의 이원화 골격, FFT/스펙트럼 추정기.
폐기한 것: `StreamingPOS`, `WindowedPOS`, `EWStatistics`, `EWMAHighPass`, `RGBSample`.

---

## 1. 모든 단계의 전제 — 검증 인프라 (Stage 0)

단계별 검증이 가능하려면 이게 먼저 있어야 한다. 이것 없이는 "잘 되는 것 같다"밖에 말할 수 없다.

### 1-1. 프레임별 전 중간값 CSV 기록기 (`SignalRecorder`)

매 프레임 한 줄씩, POS의 **모든 중간 변수**를 기록한다.

```
frameCount, t, dtMs,
  cornerX1,cornerY1, cornerX2,cornerY2, cornerX3,cornerY3, cornerX4,cornerY4, roll, meanCornerY,
  roiPixelCount,
  Cr,Cg,Cb,  CmeanR,CmeanG,CmeanB,
  S1,S2,  Smean1,Smean2,  Svar1,Svar2,  Sstd1,Sstd2,
  h, hmean, rPPG,
  trackSource, faceTracked
```

기기에서 Files/공유 시트로 내보낸다. **이 CSV가 모든 단계의 검증 근거**가 된다.

### 1-2. 리플레이 러너 (`ReplayRunner`)

CSV의 `Cr,Cg,Cb` 열만 읽어 POS를 다시 돌려 출력 CSV를 만드는 오프라인 실행기
(`swift run rppg-replay input.csv output.csv`). 카메라 없이 알고리즘만 재현·회귀 검증할 수 있다.

### 1-3. MATLAB 레퍼런스 (`matlab/pos_reference.m`)

`rPPG_test.m` 133–170행을 **산술을 한 글자도 바꾸지 않고** 떼어내 CSV 입출력만 붙인 스크립트.
Swift 출력과 `max(abs(diff))`로 대조하는 것이 5단계의 통과 기준이다.
절차는 `matlab/README.md` 참고.

### 1-4. 골든 픽스처 (`tools/gen_golden.py`)

MATLAB이 없는 환경에서도 회귀가 잡히도록, 합성 `C` 수열과 그 POS 출력 전체를
`Tests/RPPGCoreTests/Fixtures/`에 커밋해 둔다. `swift test`가 매번 이것과 대조한다.
17자리(`%.17g`)로 기록하므로 CSV 왕복이 비트 단위로 무손실임을 확인했다.

### 1-5. 디버그 화면

`rPPG(H)` / `rPPG band-passed` / `Respiration` 파형을 골라 볼 수 있고,
그 아래 `C`, `Cmean`, `C./Cmean`, `S`, `Smean`, `Sstd`, `h`, `hmean`, `rPPG`의
**현재 수치를 매 프레임 표시**한다. Stage 5를 CSV 없이 화면에서도 볼 수 있게 하기 위한 것.

> **통과 기준:** 60초 녹화 후 CSV가 나오고, 그 CSV를 리플레이 러너에 넣었을 때
> `rPPG` 열이 기기에서 계산된 값과 **완전히 동일**(double 비트 일치)해야 한다.
> 이게 맞아야 이후 단계의 "숫자 검증"이 의미를 가진다.

---

## 2. 단계별 계획

### Stage 1 — 캡처 + frame/tracking rate 이원화

**만드는 것**
- 카메라 30/60 Hz 고정(min==max), 노출·화이트밸런스·HDR 잠금
- 프레임 경로와 4 Hz 트래킹 경로 분리 (별도 큐)
- 프레임 카운터, 실측 FPS, 드롭 프레임 수, 트래킹 tick 간격 계측

**검증 방법 (사용자)**
- 화면 상단 진단 패널에서 실측 FPS / tracking Hz / 드롭 수 확인
- 60초 녹화 → CSV의 `dtMs` 열을 엑셀·MATLAB에서 히스토그램

**통과 기준**

| 항목 | 기준 |
|---|---|
| 실측 프레임 레이트 | 설정값 ±0.5 Hz |
| 프레임 간격 지터 | std < 2 ms |
| 드롭 프레임 | 60초간 < 0.5 % |
| 트래킹 tick 간격 | 250 ms ±25 ms |
| 노출 잠금 확인 | 손을 화면 앞에서 흔들어도 배경 밝기 변화 없음 |

---

### Stage 2 — 얼굴 검출 / 트래킹 / rotation

**만드는 것**
- Vision 검출(roll 포함) + 객체 트래킹 fallback, 4 Hz
- 코너 4개 좌표를 이미지 픽셀 좌표로 CSV 기록
- 화면에 얼굴 quad 오버레이 (roll 반영)

**검증 방법 (사용자)**
- **오버레이 눈으로 확인**: 머리를 좌우로 ±30° 기울였을 때 quad의 위쪽 변이 눈 라인과 평행 유지되는가
  (여기서 roll 부호가 반대면 즉시 보인다)
- 정면 정지 60초 → CSV에서 face-lost 이벤트 수, 코너 좌표 지터
- 좌우 이동 / 앞뒤 이동 / 빠른 고개 돌림 시 재검출까지 걸린 tick 수

**통과 기준**

| 항목 | 기준 |
|---|---|
| roll 부호·크기 | 실제 기울기와 같은 방향, ±5° 이내 |
| 정지 시 트래킹 유실 | 60초간 0회 |
| 정지 시 코너 좌표 지터 | std < 얼굴 폭의 0.5 % |
| 고개 45° 돌림 후 복귀 | 2 tick(0.5초) 이내 재검출 |

---

### Stage 3 — ROI 중앙 80% + C 벡터

**만드는 것**
- `FaceQuad.scaled(0.8)` → 회전된 ROI 내부 픽셀 공간 평균 → `C = [R;G;B]`
- ROI 오버레이, `C` 3채널 실시간 파형, CSV 기록

**검증 방법 (사용자)**
- **ROI 오버레이 눈으로 확인**: 머리 기울여도 ROI가 피부 위에 남아 있는가, 배경/머리카락이 들어오는가
- **렌즈 가리기 테스트**: 손으로 카메라를 덮으면 `C`가 즉시 급락하는가 (파이프라인이 실제 픽셀을 보는지)
- **조명 테스트**: 방 조명을 껐다 켜면 R/G/B가 **함께** 움직이는가
- 정지 상태 60초 CSV → `C` 각 채널의 표준편차

**통과 기준**

| 항목 | 기준 |
|---|---|
| ROI 픽셀 수 | 얼굴이 화면의 1/3일 때 5,000 px 이상 |
| 정지 시 C 표준편차 | 각 채널 < 0.5 (0–255 스케일). 이보다 크면 노출이 안 잠긴 것 |
| 렌즈 가리기 | C 급락 후 복귀 |
| ROI 이탈 | 머리 ±30° 기울임에서 배경 픽셀 유입 없음 |

> 이 단계의 `C` CSV가 Stage 5의 MATLAB 대조 입력이 된다.

---

### Stage 4 — EWMA 유닛

**만드는 것**
- `EWMA(λ)` — `y = λy + (1−λ)x`, 첫 샘플로 초기화 (`isempty` 분기와 동일)
- 3×1 / 2×1 값 타입 (`ChannelTriple`, `ProjectionPair`) — MATLAB의 `.*`/`./`/`.^` 의미 그대로
- `Svar`는 별도 타입 없이 `POSProcessor` 안에서 사양 형태 그대로:
  `Svar = λ₁·Svar + (1−λ₁)·(S−Smean)²`, 초기값 `(S−Smean)²`

**검증 방법 (사용자)** — `swift test`

- `testEWMARecurrenceMatchesSpecification` — 점화식을 **오차 0**으로 재현
- `testOneMinusLambdaIsComputedNotLiteral` — `1−0.99 ≠ 0.01`임을 이용해,
  `(1−λ)`를 리터럴로 쓰지 않았음을 고정

**통과 기준:** 유닛 테스트 전부 통과.

---

### Stage 5 — POS 전체 (핵심 단계)

**만드는 것 — 사양 순서 그대로, 한 줄씩 대응**

```swift
// C(3×1)                      ← Stage 3
Cmean = λ1*Cmean + (1-λ1)*C            // 초기값 C
S     = [0 1 -1; -2 1 1] * (C ./ Cmean)
Smean = λ1*Smean + (1-λ1)*S            // 초기값 S
Svar  = λ1*Svar  + (1-λ1)*(S-Smean).^2 // 초기값 (S-Smean).^2
Sstd  = sqrt(Svar)
h     = S[0]/(Sstd[0]+1e-9) + (1/(Sstd[1]+1e-9))*S[1]   // 레퍼런스의 비대칭 형태 그대로
hmean = λ2*hmean + (1-λ2)*h            // 초기값 h
rPPG += (h - hmean)
```

**검증 방법 (사용자)** — 이 단계는 눈이 아니라 숫자로 본다.

1. **MATLAB 대조 (주 검증)**
   Stage 3에서 뽑은 실제 `C` CSV → ① 기기 계산 rPPG, ② `swift run rppg-replay`, ③ `pos_reference.m`.
   셋을 겹쳐 그리고 `max|diff|`를 출력.
2. **합성 신호 대조**
   72 bpm 맥파를 심은 합성 `C` CSV를 만들어 rPPG 스펙트럼 피크가 1.2 Hz에 오는지.
3. **중간 변수 스냅샷**
   디버그 화면에서 `Cmean`, `S₁,S₂`, `Sstd`, `h`, `hmean`을 직접 눈으로 확인
   (`Sstd`가 초기 몇 프레임간 0 근처인지, `h`가 폭주하지 않는지).

**통과 기준**

| 항목 | 기준 |
|---|---|
| MATLAB vs Swift (동일 C 입력) | `max abs(rPPG_swift − rPPG_matlab) < 1e−9` |
| 기기 vs 리플레이 | 비트 단위 일치 |
| 합성 72 bpm 신호 | rPPG 스펙트럼 피크 72 ±1 bpm — **확인됨: 정확히 1.200 Hz** |
| 초기 폭주 | 없음 — **확인됨: 40초 합성 데이터에서 max\|h\| = 20.2** |

---

### Stage 6 — 호흡 신호

**만드는 것**
- 코너 4개 y좌표의 평균(`meanCornerY`)을 tracking rate(4 Hz)로 기록
- 실시간 파형 + 스펙트럼 기반 호흡수

**검증 방법 (사용자)**
- **메트로놈 호흡 프로토콜**: 6초 주기(10회/분)로 60초 호흡 → 피크가 0.167 Hz에 오는가
- 4초 주기(15회/분)로 반복 → 피크가 따라 움직이는가
- **숨 참기 30초** → 신호가 평평해지는가

**통과 기준:** 지정 호흡수 대비 ±1.5회/분, 숨 참기 구간에서 진폭이 호흡 구간의 20 % 이하.

---

### Stage 7 — 심박수 추정 + 마감

**만드는 것**
- rPPG(누적합이라 서서히 drift)에 detrend/band-pass를 적용한 **표시·추정 전용 후처리**
  (사양의 rPPG 값 자체는 그대로 두고, HR 추정 입력에만 적용)
- 스펙트럼 피크 + SNR 기반 신뢰도, 품질 경고(과노출·얼굴 이탈·움직임)

**검증 방법 (사용자)**
- 손가락 PPG 또는 스마트워치와 동시 측정 60초 × 5회
- 계단 오르기 직후 등 심박 변화 구간에서 따라가는지

**통과 기준:** 안정 상태 MAE < 3 bpm, 측정 실패(신뢰도 미달) 구간을 스스로 표시.

---

## 3. 진행 방식

- 각 Stage는 **별도 커밋 + 태그**(`stage-1` … `stage-7`)로 나눠서, 단계별로 리뷰·롤백 가능하게 한다.
- 각 Stage 종료 시 제출물: ① 동작 화면 ② 60초 CSV ③ 통과 기준 표에 채운 실측값.
- 통과 기준을 못 맞추면 다음 Stage로 넘어가지 않는다.

**예상 순서와 의존성**

```
Stage 0 (검증 인프라)
   ├─→ Stage 4 (EWMA)  ─┐        ← 카메라 없이 바로 검증 가능
   └─→ Stage 1 (캡처)   │
        └─→ Stage 2 (트래킹)
             └─→ Stage 3 (ROI, C) ─┴─→ Stage 5 (POS)
                  └─→ Stage 6 (호흡)      └─→ Stage 7 (심박·마감)
```

Stage 4는 하드웨어가 필요 없으므로 Stage 1과 병행 가능하다.

---

## 4. 해결된 결정 사항

1. **λ₁ = 0.99, λ₂ = 0.9** — `rPPG_test.m` 21–22행. **fps 무관 고정 상수**로 확정.
   λ를 fps에 맞춰 재계산하면 MATLAB 대조가 깨지므로 하지 않는다. 실효 메모리는
   `EWMA.timeConstantInSamples`와 화면 진단에서 확인할 수 있다.
2. **초기 `Sstd ≈ 0` 폭주는 일어나지 않는다.** 첫 스텝은 `C == Cmean`이라 `S = [0;0]`,
   따라서 `h = 0/1e−9 = 0`이다. 이후에도 `Sstd`가 `|S|`에 비례해 자라므로 `h`는
   대략 `1/sqrt(1−λ₁) ≈ 10` 규모에 머문다. 40초 합성 데이터에서 실측 `max|h| = 20.2`.
   테스트 `testHStaysBoundedThroughTheWholeFixture`가 이를 고정한다. **별도 warm-up 억제 없음.**
3. **rPPG 누적합의 drift** — 저장·검증용 `rppg`는 사양 그대로 손대지 않고,
   화면 표시와 심박 추정 입력에만 band-pass 사본(`analysisWaveform`)을 쓴다.
   두 신호가 CSV와 API에서 분리되어 있다.
4. **프레임 드롭 시** — 그냥 다음 프레임으로 진행한다(C를 채워 넣지 않는다).
   드롭률은 Stage 1 통과 기준(< 0.5 %)으로 감시하고 화면·CSV에 남긴다.
5. **얼굴 유실 시** — 3초 이상 유실되면 POS 상태 전체를 초기화한다.
6. **ROI 크기** — 사양의 "중앙 80 %"는 예시였고 레퍼런스는 회전된 박스 **전체**를 평균한다.
   기본 0.8, UI 슬라이더로 조절, **MATLAB과 대조할 녹화는 1.00으로** 둔다.

## 5. 레퍼런스와의 남은 차이

| 항목 | 레퍼런스 | 이 구현 | 이유 |
|---|---|---|---|
| 특징점 | `detectMinEigenFeatures` + KLT | Vision 얼굴 랜드마크 | iOS에 KLT 없음. 랜드마크는 대응이 이미 잡혀 있고 서브픽셀 |
| 변환 기준 | 이전 프레임 (누적) | 최초 앵커 (절대) | 누적 드리프트가 호흡과 구분되지 않음 |
| 얼굴 검출 | Haar cascade | Vision `VNDetectFaceLandmarksRequest` rev3 | roll/yaw/pitch 제공 |
| ROI | 회전된 박스 **전체** | 기본 0.8, 슬라이더 (대조 시 1.0) | 사양의 "중앙 80%"와 레퍼런스가 다름 |

similarity 피팅 자체는 유닛 테스트로 고정되어 있다 (`SimilarityTransformTests`):
알려진 변환을 1e-10으로 복원, 이상치 3개 정확히 배제, 랜드마크 잡음을 코너 위치에서
**3배 이상 줄임**(1.84 px → 0.57 px).
