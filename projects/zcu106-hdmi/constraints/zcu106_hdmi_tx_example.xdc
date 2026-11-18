# ZCU106 HDMI TX constraints derived from the Xilinx v_hdmi_tx_ss example design.

set_property PACKAGE_PIN AD8 [get_ports TX_REFCLK_P_IN]
create_clock -name tx_mgt_refclk -period 3.367 [get_ports TX_REFCLK_P_IN]

set_property PACKAGE_PIN G21 [get_ports HDMI_TX_CLK_P_OUT]
set_property IOSTANDARD LVDS [get_ports HDMI_TX_CLK_P_OUT]

set_property PACKAGE_PIN N13 [get_ports TX_HPD_IN]
set_property IOSTANDARD LVCMOS33 [get_ports TX_HPD_IN]

set_property PACKAGE_PIN N8 [get_ports TX_DDC_OUT_scl_io]
set_property IOSTANDARD LVCMOS33 [get_ports TX_DDC_OUT_scl_io]
set_property PACKAGE_PIN N9 [get_ports TX_DDC_OUT_sda_io]
set_property IOSTANDARD LVCMOS33 [get_ports TX_DDC_OUT_sda_io]

set_property PACKAGE_PIN N12 [get_ports fmch_iic_scl_io]
set_property IOSTANDARD LVCMOS33 [get_ports fmch_iic_scl_io]
set_property PACKAGE_PIN P12 [get_ports fmch_iic_sda_io]
set_property IOSTANDARD LVCMOS33 [get_ports fmch_iic_sda_io]

set_property PACKAGE_PIN AL11 [get_ports LED0]
set_property IOSTANDARD LVCMOS12 [get_ports LED0]

set_property PACKAGE_PIN H8 [get_ports SI5324_RST_OUT]
set_property IOSTANDARD LVCMOS33 [get_ports SI5324_RST_OUT]

set_property PACKAGE_PIN G8 [get_ports SI5324_LOL_IN]
set_property IOSTANDARD LVCMOS33 [get_ports SI5324_LOL_IN]

set_property PACKAGE_PIN N11 [get_ports TX_EN_OUT]
set_property IOSTANDARD LVCMOS33 [get_ports TX_EN_OUT]
