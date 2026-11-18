set project_name zcu106_hdmi_rebuild

if {[info exists ::env(ZCU106_HDMI_PROJECT_NAME)] && $::env(ZCU106_HDMI_PROJECT_NAME) ne ""} {
  set project_name $::env(ZCU106_HDMI_PROJECT_NAME)
}

if {[info exists ::env(ZCU106_HDMI_PROJECT_DIR)] && $::env(ZCU106_HDMI_PROJECT_DIR) ne ""} {
  set proj_dir [file normalize $::env(ZCU106_HDMI_PROJECT_DIR)]
} else {
  set proj_dir [file normalize [file join [file dirname [info script]] project]]
}

set xpr_path [file normalize [file join $proj_dir ${project_name}.xpr]]

if {![file exists $xpr_path]} {
  error "Project file not found: $xpr_path"
}

open_project $xpr_path

set_param general.maxThreads 1
catch {config_ip_cache -disable_cache}
catch {set_param project.enableIPCache 0}

if {[llength [get_runs -quiet synth_1]]} {
  catch {reset_run synth_1}
}
if {[llength [get_runs -quiet impl_1]]} {
  catch {reset_run impl_1}
}

puts "Launching synth_1 for $xpr_path"
launch_runs synth_1 -jobs 1
wait_on_run synth_1

set synth_status [get_property STATUS [get_runs synth_1]]
puts "synth_1 status: $synth_status"
if {![string match "*Complete*" $synth_status]} {
  error "Synthesis did not complete successfully: $synth_status"
}

puts "Launching impl_1 through write_bitstream"
launch_runs impl_1 -to_step write_bitstream -jobs 1
wait_on_run impl_1

set impl_status [get_property STATUS [get_runs impl_1]]
puts "impl_1 status: $impl_status"
if {![string match "*write_bitstream Complete*" $impl_status] && ![string match "*Complete*" $impl_status]} {
  error "Implementation/bitstream did not complete successfully: $impl_status"
}

set bit_files [glob -nocomplain -directory [file join $proj_dir ${project_name}.runs impl_1] *.bit]
if {[llength $bit_files] == 0} {
  error "Bitstream was not found under [file join $proj_dir ${project_name}.runs impl_1]"
}

puts "Bitstream generated:"
foreach bit_file $bit_files {
  puts [file normalize $bit_file]
}

close_project
