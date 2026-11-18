# AXI 버스트로 HBM 전송 측정하기

FPGA의 AXI 마스터가 연속 읽기·쓰기를 발생시키고, Vitis 애플리케이션이 여러 AXI 인스턴스의 버스트 길이와 전송 횟수를 설정하는 실험이다.

| 파일 | 확인할 내용 |
| --- | --- |
| [AXI 테스트 IP](rtl/axi4_speed_test_v1_0.v) | 제어 레지스터와 AXI 마스터 연결 |
| [마스터 RTL](rtl/axi4_speed_test_v1_0_M00_AXI.v) | 주소·데이터 채널의 버스트 전송 흐름 |
| [테스트벤치](sim/axi4_speed_test_tb.v) | 테스트 IP, 클록·리셋, 모의 메모리 슬레이브 구성 |
| [Vitis 애플리케이션](vitis/helloworld.c) | 버스트 길이 등의 설정값 기록과 측정 레지스터 읽기 |

Vivado 2022.2 시뮬레이션 소스에 `rtl/`과 `sim/`의 Verilog 다섯 개를 추가하고 최상위를 `axi4_speed_test_tb`로 선택한다. 공개본에서는 모의 슬레이브의 메모리 읽기 감지 목록에 실제 읽는 원소 `mem_data_out[0]`를 지정했다. 다섯 파일 모두 Vivado의 `xvlog` 소스 분석을 통과했다. 테스트벤치의 기능 판정과 보드 대역폭 수치는 별도로 확인해야 한다.

실보드 실행에는 원래 HBM 블록 설계의 XSA와 standalone BSP가 필요하다. 해당 플랫폼으로 Vitis 애플리케이션을 만들고 `vitis/` 파일을 추가한다. BSP에서 생성한 `xparameters.h`의 인스턴스 이름과 주소가 앱과 맞아야 한다. Vitis 예제의 사용 조건은 소스 머리말에 있다.
