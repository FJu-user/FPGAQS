set area_option -packarea
import_device ph1_35p.db -package PH1P35MDG324 -speed 3
set run_output [pwd]
cd {@PROJECT_ROOT@/td_project}
open_project {@PROJECT_ROOT@/td_project/camera_to_dsi_display.al} -single_run
load_run_param -run syn_1
report_param
commit_param -step design
elaborate -top design_top_wrapper
cd $run_output
read_adc {@PROJECT_ROOT@/user_source/constraints_source/pin.adc}
read_ip_adc -ip ddr2 -file {@PROJECT_ROOT@/user_source/hdl_source/ph1p35_ddr/ddr2/src/adc/ddr2.adc}
read_sdc {@PROJECT_ROOT@/td_project/camera_to_dsi_display.sdc}
read_sdc -ip ddr2 {@PROJECT_ROOT@/user_source/hdl_source/ph1p35_ddr/ddr2/src/sdc/ddr2.sdc}
read_sdc -ip w128_d512_fifo {@PROJECT_ROOT@/user_source/ip_source/w128_d512_fifo/w128_d512_fifo.tcl}
commit_param -step rtl
optimize_rtl
report_area -file rtl.area
set_param gate pack_effort high
commit_param -step gate
optimize_gate -packarea gate.area
export_db gate_mapped.db
legalize_phy_inst
update_timing
report_timing_status -file gate.ts
report_timing_summary -file gate.timing
report_clock_summary -file clocks.rpt
report_timing_exception -file exceptions.rpt
report_timing_ignored -file ignored.rpt
check_timing -file check_timing.rpt
export_db gate.db
write_verilog gate.v
puts {FRAME_GATE_COMPLETE}
exit
