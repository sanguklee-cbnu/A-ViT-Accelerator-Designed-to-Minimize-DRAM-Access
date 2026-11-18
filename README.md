# 외부 DRAM 접근을 줄이는 Vision Transformer 가속기

ViT의 MLP에서 FC1과 FC2의 데이터 흐름을 함께 다루는 RTL 프로젝트다. [논문 PDF](Vision_Transformer_Accelerator_with_Integrated_FC1__FC2_Dataflow_for_Reduced_Off_Chip_Memory_Access.pdf)

## 코드를 읽는 순서

1. [vit_axi_top.v](vit_axi_top.v)에서 AXI-Lite 제어 포트와 외부 메모리 인터페이스를 확인한다. [vit.v](vit.v)는 제어기, 메모리 제어기, PE 입력부, PE 배열을 연결한다.
2. [controller_top.v](controller_top.v)와 [addr_map.vh](addr_map.vh)에서 제어 신호와 주소 배치를 따라간다. 읽기와 쓰기 경로는 [read_controller.v](read_controller.v), [write_controller.v](write_controller.v), [writeback_controller.v](writeback_controller.v)에 나뉘어 있다.
3. [pe_feeder.v](pe_feeder.v), [pe_array_32x32.v](pe_array_32x32.v), [pe_int8_mac.v](pe_int8_mac.v)에서 입력 전달과 누산 경로를 확인한다.
4. [tb_vit_slow.sv](tb_vit_slow.sv)는 가속기와 AXI 메모리 경로를 연결하는 SystemVerilog 테스트벤치다. 테스트 벡터 기준 경로는 `test_vector/tests`다.

벤치를 실행하려면 원래 사용한 테스트 벡터와 `writeback_controller.v`가 읽는 softmax LUT 메모리 파일을 준비해야 한다.

## 설계 그림

<img width="1500" height="841" alt="image" src="https://github.com/user-attachments/assets/8d946497-06dc-415b-aec9-48e9e57bc0e6" />


<img width="877" height="664" alt="image" src="https://github.com/user-attachments/assets/35272a3d-3833-46e2-b007-48c38a0aa0e0" />
