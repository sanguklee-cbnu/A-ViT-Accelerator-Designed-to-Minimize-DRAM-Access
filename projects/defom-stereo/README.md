# DEFOM 스테레오의 정확도와 단계별 추론 시간 측정

KITTI 좌우 영상에서 추정한 시차의 평균 오차(EPE)와 추론 시간을 함께 기록하는 평가 코드다. 단안 깊이 인코더의 입력 크기 배율(`--da_factor`), 반복 추론 횟수(`--valid_iters`), 인코더 종류를 바꿔 비교할 수 있다. 프로파일링 시작 표본과 측정 횟수도 지정할 수 있다. [평가 코드](evaluate_kitti_profile.py)

## 실행 환경

사용하던 DEFOM-Stereo 소스 트리에서 `core/`와 같은 위치에 평가 코드를 둔다. CUDA 환경과 KITTI 데이터, 인코더 구성에 맞는 체크포인트가 필요하다. 아래 예시는 KITTI 2015 분할과 ViT-S 체크포인트를 쓰는 경우다. 체크포인트에 맞춰 나머지 모델 옵션을 설정한다.

```sh
python evaluate_kitti_profile.py --help
python evaluate_kitti_profile.py --restore_ckpt ./weights/model.pth --dinov2_encoder vits --kitti_split 15 --da_factor 3.5
```

백업 과정에서 Python 구문을 확인했다. 학습 가중치와 데이터는 별도로 준비해야 한다. DEFOM-Stereo 모델은 Insta360 Research Team의 연구이며, 이 폴더에는 실험용 평가 코드를 정리했다. [원 논문](https://arxiv.org/abs/2501.09466) · [원본 트리의 라이선스](LICENSE.upstream)
