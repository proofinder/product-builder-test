# 검증 절차 (Stage 0 · Stage 5)

이 폴더가 **정답지**입니다. Swift 구현은 여기에 맞춰야 하고, 반대가 아닙니다.

| 파일 | 역할 |
|---|---|
| `rPPG_test.m` | 원본. 손대지 않습니다. |
| `pos_reference.m` | `rPPG_test.m` 133–170행의 POS 블록만 떼어내 CSV를 입출력하게 만든 것. 산술은 한 글자도 바꾸지 않았습니다. |

확정된 파라미터 (`rPPG_test.m` 21–22행):

```matlab
lambda1 = 0.99;   % 0.95~0.99   → Cmean, Smean, Svar
lambda2 = 0.9;    % 0.9         → hmean
```

**fps와 무관한 고정 상수**로 둡니다. 시간상수로 환산하면 λ₁은 약 100 샘플이므로
30 fps에서 3.3초, 60 fps에서 1.7초가 됩니다. λ를 fps에 맞춰 재계산하면 MATLAB과의
수치 대조가 깨지므로, 레퍼런스 값을 그대로 씁니다. (앱 화면의 `POS steps`와
`EWMA.timeConstantInSamples`로 실효 메모리를 확인할 수 있습니다.)

---

## A. 합성 데이터로 먼저 확인 (기기 불필요)

```bash
python3 tools/gen_golden.py      # 픽스처 재생성 (이미 커밋되어 있음)
swift test                       # Swift가 골든 데이터와 일치하는지
```

MATLAB에서도 같은 입력으로 돌려 비교합니다.

```matlab
cd matlab
pos_reference('../Tests/RPPGCoreTests/Fixtures/synthetic_C.csv', 'matlab_out.csv');
```

```bash
swift run rppg-replay Tests/RPPGCoreTests/Fixtures/synthetic_C.csv \
    --compare matlab/matlab_out.csv
```

**통과 기준:** 모든 열의 `max|diff|`가 1e-9 미만. `cMeanR` → … → `rppg` 순서로
출력되므로, 어긋나는 첫 열이 곧 처음 갈라진 단계입니다.

합성 데이터에 심어둔 것:

| 성분 | 크기 | 목적 |
|---|---|---|
| 맥파 72 bpm (1.2 Hz) | DC의 1 % | 복원 대상 |
| 호흡성 밝기 변화 0.25 Hz | DC의 3 % | POS가 제거해야 함 |
| 조명 드리프트 0.05 Hz | DC의 5 % | POS가 제거해야 함 |
| 채널별 센서 잡음 | DC의 0.05 % | |

공통 성분이 맥파보다 8배 크지만, `golden_pos.csv`의 `rppg`에서 스펙트럼 피크는
정확히 1.200 Hz = 72.0 bpm으로 나옵니다.

---

## B. 실제 촬영 데이터로 확인

1. 앱에서 **Record CSV** → 60초 촬영 → **Stop recording** → **Export**로 파일을 꺼냅니다.
   (MATLAB과 대조할 녹화라면 **ROI scale을 1.00으로** 두세요. 레퍼런스는 회전된 박스
   전체를 평균합니다.)

2. **Stage 0 게이트 — 녹화가 자기 자신을 재현하는가**

   ```bash
   swift run rppg-replay rppg-2026-08-20-141530.csv --compare rppg-2026-08-20-141530.csv
   ```

   기기에서 계산한 `rppg` 열과, 같은 파일의 `cR/cG/cB`만으로 다시 계산한 값이
   **완전히 일치**해야 합니다 (`max|diff| = 0`). 여기서 어긋나면 CSV가 정밀도를
   잃은 것이고, 이후 단계의 숫자 검증이 전부 의미를 잃습니다.

3. **Stage 5 게이트 — MATLAB과 일치하는가**

   ```matlab
   pos_reference('rppg-2026-08-20-141530.csv', 'matlab_out.csv');
   ```

   ```bash
   swift run rppg-replay rppg-2026-08-20-141530.csv --compare matlab_out.csv
   ```

   **통과 기준:** `max|diff| < 1e-9`.

> 주의 — 여기서 대조하는 것은 `C` **이후**의 계산입니다. `C` 자체를 MATLAB과
> 픽셀 단위로 일치시키는 것은 불가능합니다 (`imwarp` 보간, 크롭 반올림, 카메라가
> 다름). 그래서 두 구현에 **같은 `C` 수열**을 먹여서 그 뒤를 비교합니다. `C`가
> 제대로 만들어지는지는 Stage 3에서 따로 봅니다.

---

## C. 다른 λ 값 실험

```bash
swift run rppg-replay recording.csv out.csv --lambda1 0.95 --lambda2 0.9
```

```matlab
pos_reference('recording.csv', 'matlab_out_095.csv', 0.95, 0.9);
```

녹화된 `C`는 그대로 두고 λ만 바꿔가며 재생할 수 있으므로, 파라미터 튜닝에 매번
다시 촬영할 필요가 없습니다.
