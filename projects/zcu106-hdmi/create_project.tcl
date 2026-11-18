set script_dir [file normalize [file dirname [info script]]]
set project_name zcu106_hdmi_rebuild

if {[info exists ::env(ZCU106_HDMI_PROJECT_NAME)] && $::env(ZCU106_HDMI_PROJECT_NAME) ne ""} {
  set project_name $::env(ZCU106_HDMI_PROJECT_NAME)
} elseif {[info exists ::project_name_override] && $::project_name_override ne ""} {
  set project_name $::project_name_override
}

if {[info exists ::env(ZCU106_HDMI_PROJECT_DIR)] && $::env(ZCU106_HDMI_PROJECT_DIR) ne ""} {
  set proj_dir [file normalize $::env(ZCU106_HDMI_PROJECT_DIR)]
} elseif {[info exists ::proj_dir_override] && $::proj_dir_override ne ""} {
  set proj_dir [file normalize $::proj_dir_override]
} else {
  set proj_dir [file join $script_dir project]
}

set bd_name design_1

create_project $project_name $proj_dir -part xczu7ev-ffvc1156-2-e -force
set_property board_part xilinx.com:zcu106:part0:2.6 [current_project]

create_bd_design $bd_name

# Processing system
create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e:3.4 zynq_ultra_ps_e_0
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e -config {apply_board_preset "1"} [get_bd_cells zynq_ultra_ps_e_0]
set_property -dict [list \
  CONFIG.PSU__USE__M_AXI_GP0 {1} \
  CONFIG.PSU__USE__M_AXI_GP1 {0} \
  CONFIG.PSU__USE__S_AXI_GP2 {1} \
  CONFIG.PSU__MAXIGP0__DATA_WIDTH {128} \
  CONFIG.PSU__SAXIGP2__DATA_WIDTH {128} \
] [get_bd_cells zynq_ultra_ps_e_0]

# AXI-Lite control plane
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 ctrl_smc
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {4}] [get_bd_cells ctrl_smc]
set_property CONFIG.ADVANCED_PROPERTIES {__experimental_features__ {disable_low_area_mode 1}} [get_bd_cells ctrl_smc]

create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 mem_axi_ic
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] [get_bd_cells mem_axi_ic]

create_bd_cell -type ip -vlnv xilinx.com:ip:axi_iic:2.1 axi_iic_0
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 sys_rst_ctrl

# Video path
create_bd_cell -type ip -vlnv xilinx.com:ip:v_frmbuf_rd:2.4 v_frmbuf_rd_0
set_property -dict [list \
  CONFIG.C_M_AXI_MM_VIDEO_DATA_WIDTH {128} \
  CONFIG.C_M_AXI_MM_VIDEO_ENABLE_USER_PORTS {true} \
  CONFIG.C_M_AXI_MM_VIDEO_AWUSER_WIDTH {1} \
  CONFIG.C_M_AXI_MM_VIDEO_WUSER_WIDTH {1} \
  CONFIG.C_M_AXI_MM_VIDEO_BUSER_WIDTH {1} \
  CONFIG.C_M_AXI_MM_VIDEO_ARUSER_WIDTH {1} \
  CONFIG.C_M_AXI_MM_VIDEO_RUSER_WIDTH {1} \
] [get_bd_cells v_frmbuf_rd_0]

create_bd_cell -type ip -vlnv xilinx.com:ip:v_hdmi_tx_ss:3.2 v_hdmi_tx_ss_0
set_property -dict [list \
  CONFIG.C_ADDR_WIDTH {10} \
  CONFIG.C_CH_WIDTH {8} \
  CONFIG.C_EXDES_AXILITE_FREQ {100} \
  CONFIG.C_EXDES_NIDRU {false} \
  CONFIG.C_EXDES_RX_PLL_SELECTION {0} \
  CONFIG.C_EXDES_TOPOLOGY {1} \
  CONFIG.C_EXDES_TX_PLL_SELECTION {6} \
  CONFIG.C_HDMI_FAST_SWITCH {false} \
  CONFIG.C_HDMI_VERSION {3} \
  CONFIG.C_HPD_INVERT {false} \
  CONFIG.C_INCLUDE_HDCP_1_4 {false} \
  CONFIG.C_INCLUDE_HDCP_2_2 {false} \
  CONFIG.C_INCLUDE_LOW_RESO_VID {true} \
  CONFIG.C_INCLUDE_YUV420_SUP {true} \
  CONFIG.C_INPUT_PIXELS_PER_CLOCK {2} \
  CONFIG.C_MAX_BITS_PER_COMPONENT {8} \
  CONFIG.C_SMARTCONNECT_ENABLE {false} \
  CONFIG.C_VALIDATION_ENABLE {false} \
  CONFIG.C_VIDEO_MASK_ENABLE {1} \
  CONFIG.C_VID_INTERFACE {0} \
] [get_bd_cells v_hdmi_tx_ss_0]

create_bd_cell -type ip -vlnv xilinx.com:ip:vid_phy_controller:2.2 vid_phy_controller_0
set_property -dict [list \
  CONFIG.C_Axi4Lite_Enable {true} \
  CONFIG.C_Hdmi_Fast_Switch {true} \
  CONFIG.C_INPUT_PIXELS_PER_CLOCK {2} \
  CONFIG.C_NIDRU {false} \
  CONFIG.C_Txrefclk_Rdy_Invert {1} \
  CONFIG.C_TX_PLL_SELECTION {6} \
  CONFIG.C_TX_REFCLK_SEL {0} \
  CONFIG.C_Tx_No_Of_Channels {3} \
  CONFIG.C_Tx_Protocol {HDMI} \
  CONFIG.C_Tx_SB_Ports {true} \
  CONFIG.C_Use_Oddr_for_Tmds_Clkout {true} \
  CONFIG.CHANNEL_SITE {X0Y0} \
  CONFIG.C_Rx_Protocol {None} \
  CONFIG.Transceiver_Width {2} \
] [get_bd_cells vid_phy_controller_0]

# Helper constants
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 vcc_const
set_property -dict [list CONFIG.CONST_VAL {1} CONFIG.CONST_WIDTH {1}] [get_bd_cells vcc_const]

create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 gnd_const
set_property -dict [list CONFIG.CONST_VAL {0} CONFIG.CONST_WIDTH {1}] [get_bd_cells gnd_const]

create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 gnd_const_20
set_property -dict [list CONFIG.CONST_VAL {0} CONFIG.CONST_WIDTH {20}] [get_bd_cells gnd_const_20]

# Control interconnect
connect_bd_intf_net [get_bd_intf_pins zynq_ultra_ps_e_0/M_AXI_HPM0_FPD] [get_bd_intf_pins ctrl_smc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins ctrl_smc/M00_AXI] [get_bd_intf_pins v_frmbuf_rd_0/s_axi_CTRL]
connect_bd_intf_net [get_bd_intf_pins ctrl_smc/M01_AXI] [get_bd_intf_pins vid_phy_controller_0/vid_phy_axi4lite]
connect_bd_intf_net [get_bd_intf_pins ctrl_smc/M02_AXI] [get_bd_intf_pins v_hdmi_tx_ss_0/S_AXI_CPU_IN]
connect_bd_intf_net [get_bd_intf_pins ctrl_smc/M03_AXI] [get_bd_intf_pins axi_iic_0/S_AXI]

# DDR read path
connect_bd_intf_net [get_bd_intf_pins v_frmbuf_rd_0/m_axi_mm_video] [get_bd_intf_pins mem_axi_ic/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins mem_axi_ic/M00_AXI] [get_bd_intf_pins zynq_ultra_ps_e_0/S_AXI_HP0_FPD]
connect_bd_intf_net [get_bd_intf_pins v_frmbuf_rd_0/m_axis_video] [get_bd_intf_pins v_hdmi_tx_ss_0/VIDEO_IN]

# HDMI TX datapath
connect_bd_intf_net [get_bd_intf_pins v_hdmi_tx_ss_0/LINK_DATA0_OUT] [get_bd_intf_pins vid_phy_controller_0/vid_phy_tx_axi4s_ch0]
connect_bd_intf_net [get_bd_intf_pins v_hdmi_tx_ss_0/LINK_DATA1_OUT] [get_bd_intf_pins vid_phy_controller_0/vid_phy_tx_axi4s_ch1]
connect_bd_intf_net [get_bd_intf_pins v_hdmi_tx_ss_0/LINK_DATA2_OUT] [get_bd_intf_pins vid_phy_controller_0/vid_phy_tx_axi4s_ch2]
connect_bd_intf_net [get_bd_intf_pins vid_phy_controller_0/vid_phy_status_sb_tx] [get_bd_intf_pins v_hdmi_tx_ss_0/SB_STATUS_IN]

# External I2C interfaces
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:iic_rtl:1.0 TX_DDC_OUT
connect_bd_intf_net [get_bd_intf_ports TX_DDC_OUT] [get_bd_intf_pins v_hdmi_tx_ss_0/DDC_OUT]

create_bd_intf_port -mode Master -vlnv xilinx.com:interface:iic_rtl:1.0 fmch_iic
connect_bd_intf_net [get_bd_intf_ports fmch_iic] [get_bd_intf_pins axi_iic_0/IIC]

# Common AXI/control clocking
connect_bd_net \
  [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] \
  [get_bd_pins zynq_ultra_ps_e_0/maxihpm0_fpd_aclk] \
  [get_bd_pins zynq_ultra_ps_e_0/saxihp0_fpd_aclk] \
  [get_bd_pins ctrl_smc/aclk] \
  [get_bd_pins mem_axi_ic/ACLK] \
  [get_bd_pins mem_axi_ic/S00_ACLK] \
  [get_bd_pins mem_axi_ic/M00_ACLK] \
  [get_bd_pins v_frmbuf_rd_0/ap_clk] \
  [get_bd_pins v_hdmi_tx_ss_0/s_axi_cpu_aclk] \
  [get_bd_pins v_hdmi_tx_ss_0/s_axis_video_aclk] \
  [get_bd_pins v_hdmi_tx_ss_0/s_axis_audio_aclk] \
  [get_bd_pins vid_phy_controller_0/vid_phy_axi4lite_aclk] \
  [get_bd_pins vid_phy_controller_0/vid_phy_sb_aclk] \
  [get_bd_pins vid_phy_controller_0/drpclk] \
  [get_bd_pins sys_rst_ctrl/slowest_sync_clk] \
  [get_bd_pins axi_iic_0/s_axi_aclk]

connect_bd_net \
  [get_bd_pins zynq_ultra_ps_e_0/pl_resetn0] \
  [get_bd_pins sys_rst_ctrl/ext_reset_in]

connect_bd_net [get_bd_pins gnd_const/dout] [get_bd_pins sys_rst_ctrl/aux_reset_in] [get_bd_pins sys_rst_ctrl/mb_debug_sys_rst]
connect_bd_net [get_bd_pins vcc_const/dout] [get_bd_pins sys_rst_ctrl/dcm_locked]

connect_bd_net \
  [get_bd_pins sys_rst_ctrl/peripheral_aresetn] \
  [get_bd_pins ctrl_smc/aresetn] \
  [get_bd_pins mem_axi_ic/ARESETN] \
  [get_bd_pins mem_axi_ic/S00_ARESETN] \
  [get_bd_pins mem_axi_ic/M00_ARESETN] \
  [get_bd_pins v_frmbuf_rd_0/ap_rst_n] \
  [get_bd_pins v_hdmi_tx_ss_0/s_axi_cpu_aresetn] \
  [get_bd_pins v_hdmi_tx_ss_0/s_axis_video_aresetn] \
  [get_bd_pins v_hdmi_tx_ss_0/s_axis_audio_aresetn] \
  [get_bd_pins vid_phy_controller_0/vid_phy_axi4lite_aresetn] \
  [get_bd_pins vid_phy_controller_0/vid_phy_sb_aresetn] \
  [get_bd_pins axi_iic_0/s_axi_aresetn]

# PHY/video clocks
connect_bd_net [get_bd_pins vid_phy_controller_0/tx_video_clk] [get_bd_pins v_hdmi_tx_ss_0/video_clk]
connect_bd_net [get_bd_pins vid_phy_controller_0/txoutclk] [get_bd_pins v_hdmi_tx_ss_0/link_clk] [get_bd_pins vid_phy_controller_0/vid_phy_tx_axi4s_aclk]
connect_bd_net [get_bd_pins vcc_const/dout] [get_bd_pins vid_phy_controller_0/vid_phy_tx_axi4s_aresetn]

# Tie off unused helper inputs
connect_bd_net [get_bd_pins gnd_const/dout] [get_bd_pins v_hdmi_tx_ss_0/acr_valid] [get_bd_pins v_hdmi_tx_ss_0/fid]
connect_bd_net [get_bd_pins gnd_const_20/dout] [get_bd_pins v_hdmi_tx_ss_0/acr_cts] [get_bd_pins v_hdmi_tx_ss_0/acr_n]

# Board-facing ports
create_bd_port -dir I -type clk -freq_hz 297000000 TX_REFCLK_P_IN
create_bd_port -dir I -type clk -freq_hz 297000000 TX_REFCLK_N_IN
connect_bd_net [get_bd_ports TX_REFCLK_P_IN] [get_bd_pins vid_phy_controller_0/mgtrefclk0_pad_p_in]
connect_bd_net [get_bd_ports TX_REFCLK_N_IN] [get_bd_pins vid_phy_controller_0/mgtrefclk0_pad_n_in]

create_bd_port -dir I TX_HPD_IN
connect_bd_net [get_bd_ports TX_HPD_IN] [get_bd_pins v_hdmi_tx_ss_0/hpd]

create_bd_port -dir I SI5324_LOL_IN
connect_bd_net [get_bd_ports SI5324_LOL_IN] [get_bd_pins vid_phy_controller_0/tx_refclk_rdy]

create_bd_port -dir O SI5324_RST_OUT
connect_bd_net [get_bd_ports SI5324_RST_OUT] [get_bd_pins sys_rst_ctrl/peripheral_aresetn]

create_bd_port -dir O TX_EN_OUT
connect_bd_net [get_bd_ports TX_EN_OUT] [get_bd_pins vcc_const/dout]

create_bd_port -dir O LED0
connect_bd_net [get_bd_ports LED0] [get_bd_pins v_hdmi_tx_ss_0/locked]

create_bd_port -dir O -type clk HDMI_TX_CLK_P_OUT
create_bd_port -dir O -type clk HDMI_TX_CLK_N_OUT
connect_bd_net [get_bd_ports HDMI_TX_CLK_P_OUT] [get_bd_pins vid_phy_controller_0/tx_tmds_clk_p]
connect_bd_net [get_bd_ports HDMI_TX_CLK_N_OUT] [get_bd_pins vid_phy_controller_0/tx_tmds_clk_n]

create_bd_port -dir O -from 2 -to 0 HDMI_TX_DAT_P_OUT
create_bd_port -dir O -from 2 -to 0 HDMI_TX_DAT_N_OUT
connect_bd_net [get_bd_ports HDMI_TX_DAT_P_OUT] [get_bd_pins vid_phy_controller_0/phy_txp_out]
connect_bd_net [get_bd_ports HDMI_TX_DAT_N_OUT] [get_bd_pins vid_phy_controller_0/phy_txn_out]

assign_bd_address
validate_bd_design
save_bd_design

set bd_path [file normalize [file join $proj_dir ${project_name}.srcs sources_1 bd $bd_name ${bd_name}.bd]]
set bd_file [get_files -all [list $bd_path]]
generate_target all $bd_file
make_wrapper -files $bd_file -top
set wrapper_path [file normalize [file join $proj_dir ${project_name}.gen sources_1 bd $bd_name hdl ${bd_name}_wrapper.v]]
add_files -norecurse [list $wrapper_path]
set_property top ${bd_name}_wrapper [current_fileset]

add_files -fileset constrs_1 [list [file normalize [file join $script_dir constraints zcu106_hdmi_tx_example.xdc]]]

puts "Created project at $proj_dir"
