import_device ph1_35p.db -package PH1P35MDG324 -speed 3
import_db {@WORK@/routed.db}
clear_sdc
read_sdc {@WORK@/audit_user.sdc}
read_sdc -ip ddr2 {@WORK@/audit_ddr.sdc}
read_sdc -ip w128_d512_fifo {@WORK@/audit_fifo.tcl}
read_sdc {@WORK@/bounds.sdc}
update_timing -mode final

proc audit_bundle {name from to budget} {
 set s [get_regs $from]
 set d [get_regs $to]
 puts "CDC_${name}_SOURCE [llength $s] DEST [llength $d] BUDGET $budget"
 if {[llength $s]==0 || [llength $d]==0} {error "CDC collection empty: $name"}
 report_timing_path -from $s -to $d -ep_num 1024 -file ${name}.timing
}
audit_bundle gray {u_mipi_frame_timing/latest_gray[*]} {u_mipi_latency_measure/frames/gray_meta[*]} 6.0
audit_bundle forward_bundle {u_uart_frame_bridge/forward_mailbox/held[*]} {u_uart_frame_bridge/forward_mailbox/d_data[*]} 10.0
audit_bundle camera_time {u_latency_timebase/gray[*]} {u_mipi_frame_timing/time_meta[*]} 6.0
audit_bundle pixel_time {u_latency_timebase/gray[*]} {u_mipi_latency_measure/elapsed/time_meta[*]} 6.0
audit_bundle isp_bundle {u_mipi_frame_timing/isp_descriptor[*]} {u_video_in/g_capture_tracking$u_capture_frame_metadata/active_id[*] u_video_in/g_capture_tracking$u_capture_frame_metadata/active_time[*] u_video_in/g_capture_tracking$u_capture_frame_metadata/active_valid} 6.0
audit_bundle key_bundle {u_key2_mosaic_size_control/payload[*]} {u_key2_mosaic_size_control/O_strength_pixel[*] u_key2_mosaic_size_control/O_motion_overlay_pixel} 10.0
report_timing_exception -file exceptions.rpt
report_timing_summary -file audit.timing
puts {CDC_AUDIT_COMPLETE}
exit
