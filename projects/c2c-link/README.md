# VCU118–VU19P Chip-to-Chip 연결

VCU118의 Master와 VU19P의 Slave를 AXI Chip2Chip·Aurora로 연결하는 설계다. 두 FPGA가 트랜시버 초기화 신호를 언제 해제하는지 살펴볼 수 있도록, 양쪽 최상위 RTL의 카운터 동작을 별도 예제 모듈로 재현했다. [초기화 동작을 재현한 RTL](aurora_pma_hold.v)

리셋 시 `pma_init`이 올라가고 초기화 클록이 1,048,576번 상승하면 내려간다. [테스트벤치](tb_aurora_pma_hold.sv)는 해제 직전·직후의 값과 재리셋 동작을 검사하도록 구성했다. 각 보드의 원래 XDC에서 가져온 [Master 기준 클록](constraints/master_refclk.xdc)과 [Slave 기준 클록](constraints/slave_refclk.xdc)은 10 ns 입력 클록을 정의한다. 기준 클록과 카운터 입력인 초기화 클록은 서로 다른 신호다.

공유 예제는 초기화 동작과 클록 제약을 다룬다. 전체 보드 연결을 재현하려면 Vivado 블록 설계, 보드별 핀 매핑, IP 및 펌웨어가 필요하다. 이 예제만으로 실제 보드 링크를 검증할 수는 없다.
