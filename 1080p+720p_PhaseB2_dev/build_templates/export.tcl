import_device ph1_35p.db -package PH1P35MDG324 -speed 3
set run_output [pwd]
cd {@PROJECT_ROOT@/td_project}
open_project {@PROJECT_ROOT@/td_project/camera_to_dsi_display.al} -single_run
load_run_param -run phy_1
cd $run_output
import_db {@WORK@/routed.db}
report_route_status -drc -file final_route_drc.txt
report_timing_exception -file final_exceptions.timing
report_clock_utilization -file final_clocks.txt
check_timing -file final_check_timing.rpt
flow_status -file final_flow.status
set_param bitgen compress on
commit_param -step bitgen
bitgen -bit camera_to_dsi_display_A_mipi_latency.bit
puts {SIGNOFF_EXPORT_COMPLETE}
exit
