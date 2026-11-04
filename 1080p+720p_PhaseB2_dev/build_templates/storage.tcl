import_device ph1_35p.db -package PH1P35MDG324 -speed 3
import_db {@WORK@/routed.db}
update_timing -mode final
set d [get_cells {u_video_algorithm_wrapper/u_pixel_chain_v1/u_luma_tone_modes_v1/u_hist* u_video_algorithm_wrapper/u_pixel_chain_v1/u_luma_tone_modes_v1/hist_valid* u_video_algorithm_wrapper/u_pixel_chain_v1/u_luma_tone_modes_v1/hist_last* u_video_algorithm_wrapper/u_pixel_chain_v1/u_luma_tone_modes_v1/sample_* u_video_algorithm_wrapper/u_pixel_chain_v1/u_luma_tone_modes_v1/calc_* u_video_algorithm_wrapper/u_pixel_chain_v1/u_luma_tone_modes_v1/gamma_* u_video_algorithm_wrapper/u_pixel_chain_v1/u_mosaic_v1/u_blocks*}]
set s [get_regs {S_hdmi_reset_sync*}]
puts "STORAGE_CONTROL_DEST [llength $d] RESET_SOURCE [llength $s]"
if {[llength $d]==0 || [llength $s]==0} {error "Storage control collection empty"}
report_timing_path -to $d -ep_num 2048 -file all.timing
report_timing_path -from $s -to $d -ep_num 2048 -file reset.timing
puts {STORAGE_CONTROL_COMPLETE}
exit
