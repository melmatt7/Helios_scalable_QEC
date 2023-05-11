create_project qec_fpga C:/Helios_scalable_QEC/qec_fpga -part xczu7ev-ffvc1156-2-e
set_property board_part xilinx.com:zcu106:part0:2.6 [current_project]
add_files -norecurse {C:/Helios_scalable_QEC/design/stage_controller/decoder_stage_controller_partial.sv C:/Helios_scalable_QEC/design/wrappers/standard_planar_code_2d_right.sv C:/Helios_scalable_QEC/design/generics/tree_compare_solver.sv C:/Helios_scalable_QEC/design/stage_controller/get_boundry_cardinality_3d.sv C:/Helios_scalable_QEC/design/channels/pu_arbitration.sv C:/Helios_scalable_QEC/design/channels/neighbor_link.sv C:/Helios_scalable_QEC/design/generics/fifo_fwft.v C:/Helios_scalable_QEC/design/generics/tree_distance_3d_solver.sv C:/Helios_scalable_QEC/design/channels/blocking_channel.sv C:/Helios_scalable_QEC/design/channels/final_arbitration.sv C:/Helios_scalable_QEC/design/channels/nonblocking_channel.sv C:/Helios_scalable_QEC/design/wrappers/standard_planar_code_2d_left.sv C:/Helios_scalable_QEC/design/channels/neigbor_link_fifo.sv C:/Helios_scalable_QEC/design/wrappers/standard_planar_code_2d_no_fast_channel_with_stage_controller.sv C:/Helios_scalable_QEC/parameters/parameters.sv C:/Helios_scalable_QEC/design/channels/nonoblockingchannel_fifo.sv C:/Helios_scalable_QEC/design/pe/processing_unit.sv}
add_files -norecurse C:/Helios_scalable_QEC/design/wrappers/standard_planar_code_2d_no_fast_channel_synthesizable_top.sv
set_property top standard_planar_code_3d_no_fast_channel_synthesizable_top [current_fileset]
set_property SOURCE_SET sources_1 [get_filesets sim_1]
add_files -fileset sim_1 -norecurse C:/Helios_scalable_QEC/test_benches/full_tests/bench_decoder.sv
update_compile_order -fileset sources_1