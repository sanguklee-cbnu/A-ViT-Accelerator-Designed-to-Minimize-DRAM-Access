# SPI Master·Slave와 SRAM 전송 실험

[최상위 RTL](rtl/SPI.v)은 Master와 Slave 블록을 직렬 신호선으로 연결한다. Master는 주소와 쓰기 데이터를 받아 전송 형식으로 바꾸고, Slave는 명령을 해석해 SRAM을 읽거나 쓴다. 기본 데이터 폭은 16비트, 주소 폭은 15비트다. [Master 블록](rtl/Master%20block.v) · [Slave 블록](rtl/Slave%20block.v) · [듀얼 포트 SRAM](rtl/Two-Port%20SRAM.v)

## 테스트벤치

[테스트벤치](sim/Test_bench.v)는 클록·리셋과 전송 제어 신호를 구동한다. Vivado 2022.2에서 `rtl/`의 Verilog 8개와 테스트벤치를 시뮬레이션 소스로 추가한다. 시뮬레이션 최상위는 `Test_bench`다. 공유본은 포트 폭에 쓰는 파라미터를 포트 목록 앞에서 선언하도록 정리했다.

Vivado `xvlog`로 소스 분석을 확인했다. 이 환경에서 `xelab`은 시뮬레이터가 생성한 C 코드를 컴파일하는 단계에서 중단됐다. SPI 전송 결과는 추가 시뮬레이션으로 확인해야 한다.

## 세미나 자료

[코드 리뷰에 사용한 구조도](seminar/spi_existing_code_structure.svg)는 별도의 SPI 예제를 설명한다. 세미나 예제에서는 포매팅 로직이 Master 상위 모듈과 Slave 메모리 접근 모듈에 들어 있다. 이 폴더의 RTL은 데이터 포매터와 메모리 접근 포매터를 별도 모듈로 두고 있다.
