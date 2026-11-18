# ZCU106 HDMI 송신 경로

DDR 프레임 버퍼에 1080p60 컬러바를 준비하고 HDMI 송신 서브시스템과 Video PHY를 구성하는 보드 프로젝트다. [Vivado 프로젝트 생성 Tcl](create_project.tcl), [보드 제약](constraints/zcu106_hdmi_tx_example.xdc), [Vitis 펌웨어](vitis_template/main.c)를 함께 보면 하드웨어와 소프트웨어의 역할을 따라갈 수 있다.

## 프로젝트 생성

Vivado 2022.2와 ZCU106 보드 정의 `xilinx.com:zcu106:part0:2.6`, Tcl이 참조하는 HDMI·Video PHY·Frame Buffer Read IP를 준비한다. Tcl이 프로젝트를 다시 만들고 합성·구현 결과를 초기화하므로 새 작업 디렉터리에 이 폴더를 복사해 실행한다.

```sh
vivado -mode batch -source create_project.tcl
vivado -mode batch -source run_bitstream.tcl
```

구현이 끝나면 XSA를 내보내 Vitis 2022.2에서 standalone 애플리케이션을 만든다. `vitis_template/main.c`를 앱에 추가하고 `BoardClockInit()`에 보드 리비전에 맞는 클록 칩 초기화를 구현해야 한다. 정리 과정에서는 Tcl이 참조하는 파일을 확인했다. 새 비트스트림을 생성하거나 실제 모니터 출력을 시험하지 않았다.
