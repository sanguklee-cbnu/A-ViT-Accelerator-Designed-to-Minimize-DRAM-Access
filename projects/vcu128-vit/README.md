# VCU128에서 ViT의 첫 인코더 블록 검증

DINO 입력을 FPGA에 보낼 때 패치 임베딩과 첫 인코더 블록의 값이 참조 모델과 어느 단계에서 달라지는지 살펴보는 보드 검증 프로젝트다. 호스트 코드는 PCIe로 입력·가중치·양자화 파라미터를 기록하고, 패치 출력과 Q·V 중간값 및 블록 최종 출력을 읽어 참조 벡터와 비교한다. [보드 검증 코드](test_DINO_oneblk_board.py)

## 빌드와 실행 조건

[빌드 Tcl](build_one_block.tcl)은 기존 VCU128 Vivado 프로젝트의 합성 및 구현 실행을 초기화한 뒤 비트스트림을 생성한다. 사용하던 XPR을 별도 작업 폴더에 복구한 다음 그 경로를 넘긴다.

```sh
vivado -mode batch -source build_one_block.tcl -tclargs path/to/project.xpr
```

보드 검증에는 이 설계에 맞는 비트스트림, PCIe 드라이버와 호스트 모듈 `NPUv4`·`PCIeAccess`가 필요하다. 입력·가중치·파라미터 텍스트가 있는 디렉터리는 `DINO_VEC_DIR`, 참조 출력 디렉터리는 `DINO_GOLD_DIR`로 지정한다. `DINO_VERIFY_ROOT`는 결과 덤프를 쓸 디렉터리다. 환경을 준비한 뒤 호스트에서 아래 명령을 실행한다.

```sh
python test_DINO_oneblk_board.py
```

공유본에서는 PC별 프로젝트 경로를 Tcl 인자로 받고 테스트 벡터의 기본 경로를 상대 경로로 바꿨다. 정리 과정에서 Python 구문을 확인했으며, 실제 보드 측정은 수행하지 않았다.
