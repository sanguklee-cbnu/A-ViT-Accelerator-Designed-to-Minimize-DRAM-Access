# FPGA · 비전 모델 프로젝트

Vision Transformer의 메모리 접근을 줄이는 RTL 설계부터, 보드에서 중간 결과를 검증하는 코드와 보드 간 통신 실험까지 정리했다. 프로젝트별 폴더에서 설계 설명, 대표 소스, 실행에 필요한 환경을 확인할 수 있다.

## 프로젝트

| 프로젝트 | 살펴볼 내용 | 주요 언어·도구 |
| --- | --- | --- |
| [ViT 가속기](projects/vit-accelerator/) | FC1·FC2 데이터 흐름과 외부 메모리 접근을 다룬 RTL, 테스트벤치와 논문 | Verilog, SystemVerilog |
| [DeiT-Tiny 양자화 평가](projects/deit-k-eval/) | 부분합 반올림에 쓰는 시프트 값 `k`를 바꿔 분류 정확도를 비교하는 평가 패키지 | Python, PyTorch |
| [VCU128 ViT 보드 검증](projects/vcu128-vit/) | 패치와 첫 인코더 블록의 결과를 PCIe로 읽어 소프트웨어 참조값과 비교 | Python, Vivado Tcl |
| [DEFOM 스테레오 프로파일링](projects/defom-stereo/) | 입력 해상도와 반복 횟수를 조절하며 KITTI 시차 오차와 추론 시간을 측정 | Python, PyTorch, CUDA |
| [ONNX → OpenVINO IR](projects/onnx-openvino/) | 모델을 XML·BIN으로 변환하고 노드별 연산 종류와 출력 형태를 확인 | Python, OpenVINO |
| [VCU118–VU19P Chip-to-Chip](projects/c2c-link/) | 두 FPGA 사이의 Master·Slave 연결과 최상위 설계 | Verilog, Vivado |
| [HBM AXI 전송 실험](projects/hbm-axi/) | AXI 버스트를 발생시키는 RTL과 보드 측정에 쓰이는 제어 흐름 | Verilog, Vitis |
| [ZCU106 HDMI 송신](projects/zcu106-hdmi/) | HDMI 영상 송신 블록 설계, 핀·클록 제약과 컬러바 펌웨어 | Vivado Tcl, C |
| [SPI 컨트롤러와 세미나](projects/spi-rtl/) | Master·Slave·SRAM을 연결한 설계와 전송 테스트벤치, 코드 리뷰용 구조도 | Verilog, Vivado |

ViT 가속기의 하드웨어 구조는 [AXI 최상위 모듈](projects/vit-accelerator/vit_axi_top.v)에서 시작해 연산부와 메모리 제어부로 따라갈 수 있다. 보드 없이 실행할 수 있는 예제로는 [DeiT 평가기의 CPU 실행 절차](projects/deit-k-eval/README.md)가 있다.
