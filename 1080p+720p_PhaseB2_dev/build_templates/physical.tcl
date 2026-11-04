import_device ph1_35p.db -package PH1P35MDG324 -speed 3
set run_output [pwd]
cd {@PROJECT_ROOT@/td_project}
open_project {@PROJECT_ROOT@/td_project/camera_to_dsi_display.al} -single_run
load_run_param -run phy_1
cd $run_output
import_db {@WORK@/gate.db}
set_param place opt_timing high
set_param place ofv 70
set_param place opt_max_density 50
set_param place target_density 0.6
set_param place target_density_pp 0.7
set_param place aggressive_opt 20
set_param place enhanced_beeline_opt 2
set_param place enhanced_gp on
set_param place non_crit_opt on
set_param place post_place_opt high
set_param place enable_congestion_recovery on
set_param route post_route_opt high
report_param
set_param place seed 0
read_adc {@PROJECT_ROOT@/user_source/constraints_source/macro_layout.adc}
place
report_area -io_info -file placed.area
update_timing -mode manhattan
report_timing_summary -file placed.timing
export_db placed.db
puts {PLACE_COMPLETE}
set_param route effort normal
route
report_area -io_info -file routed.area
update_timing -mode final
report_timing_status -file routed.ts
report_timing_summary -file routed.timing
report_route_status -file routed.status
report_clock_utilization -file routed.clocks
export_db routed.db
puts {ROUTE_COMPLETE}
exit
