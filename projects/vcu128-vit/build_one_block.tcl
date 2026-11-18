if {$argc != 1} {
    puts stderr "Usage: vivado -mode batch -source build_one_block.tcl -tclargs <project.xpr>"
    exit 2
}
open_project [file normalize [lindex $argv 0]]

reset_run design_1_vit_axi_top_0_0_synth_1
reset_run synth_1
reset_run impl_1

launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

set status [get_property STATUS [get_runs impl_1]]
puts "impl_1 status: $status"
if {[string first "write_bitstream Complete" $status] < 0} {
    puts "ERROR: bitstream generation did not complete successfully"
    exit 1
}

puts "DONE: DINO560 one-block bitstream build complete"
