set_max_delay -from [get_regs {u_mipi_frame_timing/latest_gray[*]}] -to [get_regs {u_mipi_latency_measure/frames/gray_meta[*]}] -datapath_only 6.000
set_max_delay -from [get_regs {u_uart_frame_bridge/forward_mailbox/held[*]}] -to [get_regs {u_uart_frame_bridge/forward_mailbox/d_data[*]}] -datapath_only 10.000

# Gray time source is registered; constrain entry-stage flight time separately.
set_max_delay -from [get_regs {u_latency_timebase/gray[*]}] -to [get_regs {u_mipi_frame_timing/time_meta[*] u_mipi_latency_measure/elapsed/time_meta[*]}] -datapath_only 6.000
# Held since the original ISP SOF; the original synchronizer supplies settling.
set_max_delay -from [get_regs {u_mipi_frame_timing/isp_descriptor[*]}] -to [get_regs {u_video_in/g_capture_tracking$u_capture_frame_metadata/active_id[*] u_video_in/g_capture_tracking$u_capture_frame_metadata/active_time[*] u_video_in/g_capture_tracking$u_capture_frame_metadata/active_valid}] -datapath_only 6.000

# Three held KEY2 control bits share one request/ack mailbox.
set_max_delay -from [get_regs {u_key2_mosaic_size_control/payload[*]}] -to [get_regs {u_key2_mosaic_size_control/O_strength_pixel[*] u_key2_mosaic_size_control/O_motion_overlay_pixel}] -datapath_only 10.000
