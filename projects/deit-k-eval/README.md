# DeiT-Tiny/16 부분합 양자화 평가

행렬곱을 입력 채널 방향으로 나누면 각 타일에서 부분합이 생긴다. 이 프로젝트는 DeiT-Tiny/16의 패치 임베딩과 MLP의 두 번째 선형층(`fc2`)에서 부분합을 `2^(-k)` 간격으로 반올림한 뒤 누적하고, 그 결과를 원래 모델의 분류 결과와 비교한다. 실행 시점에 필요한 k의 개수와 분류 정확도를 함께 기록해 하나의 k를 공유하는 방식과 타일별 k를 쓰는 방식을 비교할 수 있다.

## 구현

- 사전학습 모델과 전처리를 불러오고 패치 크기, 층 수, 분류기 출력을 확인한다. 모델은 `timm`의 `deit_tiny_patch16_224.fb_in1k` 또는 Hugging Face의 `facebook/deit-tiny-patch16-224`를 사용한다. [모델 로더](deit_k_eval/models.py)
- 대상 층을 찾아 타일별 부분합 연산을 적용하고 전역·층별·타일별 k를 관리한다. 보정 값을 계산하는 코드도 제공한다. [부분합 시뮬레이션](deit_k_eval/k_assignment/simulation.py) · [k 할당 방식](deit_k_eval/k_assignment/schemes.py) · [보정 코드](deit_k_eval/calibrate_k.py)
- 같은 입력으로 기준 모델과 실험 모드를 평가하고 Top-1, Top-5, 기준 대비 변화량, k 저장량 추정치를 CSV와 JSON으로 기록한다. [실험 실행기](deit_k_eval/run_experiments.py) · [정확도 계산](deit_k_eval/metrics.py) · [결과 형식](deit_k_eval/results.py)

이 폴더에서 제공하는 구현 범위는 모델 로딩 및 검증, 데이터 처리, 부분합 시뮬레이션과 평가 도구다. 학습된 모델과 전처리 설정은 위 모델 제공처에서 가져온다. 실험용 ImageNet 이미지, 사전학습 가중치, 개별 실험에서 산출한 보정 값과 측정 결과는 배포 대상에서 제외했다.

## 합성 입력으로 실행하기

64비트 Python 3.10 이상 환경에서 이 폴더를 작업 디렉터리로 사용한다. 다음은 Windows PowerShell 예시다. 합성 입력 두 개로 기준 모델과 전역 k 모드를 실행한다.

```powershell
py -3.11 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
.\.venv\Scripts\python.exe -m deit_k_eval.run_experiments --model-backend timm --schemes baseline fixed_global_k --synthetic-samples 2 --batch-size 2 --device cpu --num-workers 0 --output-dir runs/smoke
```

가중치를 처음 가져올 때는 모델 제공처에 연결한다. 가중치가 로컬 캐시에 있으면 `$env:HF_HUB_OFFLINE = '1'`을 설정해 `timm` 경로를 오프라인으로 실행할 수 있다. 합성 입력의 정확도는 의미가 없으며 이 실행으로 모델 로딩, 추론, 결과 파일 생성을 확인할 수 있다. `runs/smoke/` 아래에 각 모드의 `result.json`, `result.csv`와 전체 `result_summary.csv`, `result_summary.json`, `accuracy_vs_k_count.png`, `report.md`가 생성된다.

## ImageNet 검증 데이터로 비교하기

직접 준비한 ImageNet 검증 세트를 클래스별 하위 폴더에 배치한다. 다음 명령의 `./data/imagenet/val`을 해당 경로로 바꾼다. 원본 ILSVRC2012 파일 배치를 사용하는 경우 devkit의 라벨 파일과 `meta.mat`도 필요하다. [지원하는 데이터 형식](deit_k_eval/data.py)

```powershell
.\.venv\Scripts\python.exe -m deit_k_eval.run_experiments --model-backend timm --schemes baseline fixed_global_k --dataset-path ./data/imagenet/val --batch-size 32 --device cpu --num-workers 0 --output-dir runs/imagenet
```

학습 또는 보정한 k를 쓰는 모드는 `--learned-k-path`로 자체 보정 파일을 지정한다. 형식과 옵션은 `python -m deit_k_eval.calibrate_k --help`에서 확인할 수 있다.
