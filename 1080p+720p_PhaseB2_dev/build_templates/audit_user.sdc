create_clock -name {sys_clk_50m} -period 20.000 -waveform {0.000 10.000} [get_ports {I_sys_clk}]
# UART and KEY1 enter dedicated two-flop synchronizers. Internal stages stay timed.
set_false_path -from [get_ports {I_uart_rx}]
set_false_path -from [get_ports {I_button[3]}]
# SC500CS FHD table: 0x4837=0x21, approximately 960 Mbps/lane.
# The forwarded MIPI clock lane is approximately 480 MHz.
create_clock -name {mipi_rx_ck_pad} -period 2.083 -waveform {0.000 1.042} [get_nets {IO_rx_clk_pad_p}]

create_clock -name {ETH_RX_CLK} -period 8.000 -waveform {0.000 4.000} [get_ports {I_a_rgmii_rxc}]
derive_clocks

# PHY pins from HX1P35; TX timing now uses clock-centered RGMII, not the
# official demo's zero-phase, opposite-edge exception model.
rename_clock -name {ETH_TX_CLK} [get_clocks {u_ethernet_image_bridge/u_eth_pll/ph1p_phy_pll_wrapper_d2616deaaa79_Inst/u_PH1P_PHY_PLL.clkc[0]}]
rename_clock -name {ETH_TX_CLK_90} [get_clocks {u_ethernet_image_bridge/u_eth_pll/ph1p_phy_pll_wrapper_d2616deaaa79_Inst/u_PH1P_PHY_PLL.clkc[1]}]
rename_clock -name {ETH_REF25_CLK} [get_clocks {u_ethernet_image_bridge/u_eth_pll/ph1p_phy_pll_wrapper_d2616deaaa79_Inst/u_PH1P_PHY_PLL.clkc[2]}]
rename_clock -name {ETH_GMII_RX_CLK} [get_clocks {u_ethernet_image_bridge/u_rgmii/u_gmii_rx_clk.clkout}]
# C1 already has +90 degrees. Do not add another +90 here.
create_generated_clock -name {ETH_FORWARD_CLK} -source [get_pins {u_ethernet_image_bridge/u_eth_pll/ph1p_phy_pll_wrapper_d2616deaaa79_Inst/u_PH1P_PHY_PLL.clkc[1]}] -master_clock {ETH_TX_CLK_90} -multiply_by 1 [get_ports {O_a_rgmii_txc}]
set_input_delay -clock [get_clocks {ETH_RX_CLK}] -max 2.500 [get_ports {{I_a_rgmii_rxd[*]} I_a_rgmii_rx_ctl}]
set_input_delay -clock [get_clocks {ETH_RX_CLK}] -min 1.500 [get_ports {{I_a_rgmii_rxd[*]} I_a_rgmii_rx_ctl}]
set_input_delay -clock [get_clocks {ETH_RX_CLK}] -clock_fall -add_delay -max 2.500 [get_ports {{I_a_rgmii_rxd[*]} I_a_rgmii_rx_ctl}]
set_input_delay -clock [get_clocks {ETH_RX_CLK}] -clock_fall -add_delay -min 1.500 [get_ports {{I_a_rgmii_rxd[*]} I_a_rgmii_rx_ctl}]
# YT8511C/H datasheet p85: clock-centered receiver setup/hold >= 1 ns.
# Add 0.2 ns PCB/skew engineering margin on each side: max=+1.2, min=-1.2.
# This is a receiver requirement, NOT a measured PHY/PCB timing guarantee.
# Do not credit the PHY's *typical* 0.5 ns internal delay as extra slack.
# All rising/falling setup AND hold checks remain enabled.
# Reference the forwarded *pin*, so its IO clock path latency participates
# (TD SWUG200 3.9.2). Never replace that path by a guessed constant latency.
set_output_delay -clock [get_clocks {ETH_FORWARD_CLK}] -reference_pin [get_ports {O_a_rgmii_txc}] -max 1.200 [get_ports {{O_a_rgmii_txd[*]} O_a_rgmii_tx_ctl}]
set_output_delay -clock [get_clocks {ETH_FORWARD_CLK}] -reference_pin [get_ports {O_a_rgmii_txc}] -min -1.200 [get_ports {{O_a_rgmii_txd[*]} O_a_rgmii_tx_ctl}]
set_output_delay -clock [get_clocks {ETH_FORWARD_CLK}] -reference_pin [get_ports {O_a_rgmii_txc}] -clock_fall -add_delay -max 1.200 [get_ports {{O_a_rgmii_txd[*]} O_a_rgmii_tx_ctl}]
set_output_delay -clock [get_clocks {ETH_FORWARD_CLK}] -reference_pin [get_ports {O_a_rgmii_txc}] -clock_fall -add_delay -min -1.200 [get_ports {{O_a_rgmii_txd[*]} O_a_rgmii_tx_ctl}]
# Only the asynchronous *entry* to the new reset-release synchronizers is
# excluded. Their Q -> functional/DATA ODDR reset paths are NOT false-pathed.
# TXC ODDR reset is tied inactive in RTL: no TXC reset synchronizer exists.
# TD 6.2.1 rejects get_regs -o: consume default opaque collections directly.
# Empty matches are a hard error, not a silently missing reset-entry exception.
# New USER synthesis must verify preserved IO FFs and their real timed outputs.
set eth_reset_entry_from [get_regs {u_ethernet_image_bridge/phy_run*}]
set eth_reset_entry_fabric [get_regs {u_ethernet_image_bridge/*release_pipe*}]
set eth_reset_entry_data [get_regs {u_ethernet_image_bridge/u_tx_data_io_reset_sync/io_*_q*}]
if {[llength $eth_reset_entry_from] == 0 || [llength $eth_reset_entry_fabric] == 0 || [llength $eth_reset_entry_data] == 0} {
    error "ETH reset synchronizer collection empty: verify current synthesized hierarchy"
}
set eth_reset_entry_to [concat $eth_reset_entry_fabric $eth_reset_entry_data]
set_false_path -from $eth_reset_entry_from -to $eth_reset_entry_to

rename_clock -name {HDMI1080_PIXEL_CLK} \
    [get_clocks {u_hdmi_pll_1080p60/u_hdmi_pll.clkc[0]}]
rename_clock -name {HDMI1080_SERIAL_CLK} \
    [get_clocks {u_hdmi_pll_1080p60/u_hdmi_pll.clkc[1]}]

rename_clock -name {pll_clk_100m} [get_clocks {u_PLL/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[0]}]
rename_clock -name {pll_clk_24m} [get_clocks {u_PLL/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[1]}]
rename_clock -name {HDMI720_PIXEL_CLK} [get_clocks {u_PLL/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[4]}]
rename_clock -name {HDMI720_SERIAL_CLK} [get_clocks {u_PLL/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[5]}]
rename_clock -name {MIPI_RX_BYTE_CLK} [get_clocks {u_mipi_dphy_rx_ph1p_mipiio_wrapper/u_ph1p_mipiio_rx_wrapper/u_PH1P_LOGIC_DPHY_MIPI_RX.o_fabric_div4_8_clk}]


# TD SWUG200 section 5.1.6: both possible clocks must be represented
# at each mux output. Only these mutually exclusive clock scenarios are split.
create_generated_clock -name {HDMI720_PIXEL_MUX} -source [get_pins {u_PLL/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[4]}] -master_clock {HDMI720_PIXEL_CLK} -multiply_by 1 [get_pins {u_pixel_clock_mux/u_clock_select.clkout}]
create_generated_clock -name {HDMI1080_PIXEL_MUX} -source [get_pins {u_hdmi_pll_1080p60/u_hdmi_pll.clkc[0]}] -master_clock {HDMI1080_PIXEL_CLK} -multiply_by 1 [get_pins {u_pixel_clock_mux/u_clock_select.clkout}] -add
create_generated_clock -name {HDMI720_SERIAL_MUX} -source [get_pins {u_PLL/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[5]}] -master_clock {HDMI720_SERIAL_CLK} -multiply_by 1 [get_pins {u_serial_clock_mux/u_clock_select.clkout}]
create_generated_clock -name {HDMI1080_SERIAL_MUX} -source [get_pins {u_hdmi_pll_1080p60/u_hdmi_pll.clkc[1]}] -master_clock {HDMI1080_SERIAL_CLK} -multiply_by 1 [get_pins {u_serial_clock_mux/u_clock_select.clkout}] -add


# SW2 enters a dedicated two-flop synchronizer; its internal stages remain timed.
set_false_path -from [get_ports {I_cascade_sw2}]
