# run_sim.tcl  -  Vivado step 1: simulate the whole classifier (ecg_top) in Vivado's own simulator.
#
# What it does, in plain words:
#   1. makes a new Vivado project in a sub-folder called  vivado_ecg  (next to this file),
#   2. adds the 12 design files and the testbench ecg_top_tb.v,
#   3. runs the same test you already ran with iverilog (real beats against the Python answer key),
#   4. prints the result in the Tcl Console at the bottom of the Vivado window.
#
# How to run it:  in Vivado click  Tools -> Run Tcl Script...  and pick this file.
#   This file must be in the SAME folder as the .v files, weights.hex, biases.hex and the answer_key folder
#   (that is your mac_unit_test folder).
#
# What a good result looks like (last lines in the Tcl Console):
#     total errors : 0
#     ALL TESTS PASSED

# ---------------- settings you may change ----------------
set NBEATS 2      ;# how many real beats to test.  2 = quick test.  16 = the full test (same as iverilog).
set FIRST  0      ;# number of the first beat to test (0 .. 15). Leave at 0 for the full test.
# ---------------------------------------------------------

set here [file dirname [file normalize [info script]]]
if {[info script] eq ""} { set here [pwd] }
set pname ecg_top_proj
set pdir  [file join $here vivado_ecg]

set rtl  [list ecg_top.v layer_seq.v decision.v addr_gen.v layer_ctrl.v mac_unit.v bias_rescale.v \
               max_pool.v pool_pair.v bias_rom.v weight_rom.v data_buffer.v]
set tb   ecg_top_tb.v
set data [list weights.hex biases.hex]
set keyf [list beats_in.hex exp_conv1_relu.hex exp_conv1_pool.hex exp_conv2_relu.hex exp_conv2_pool.hex \
               exp_fc1.hex exp_fc2.hex exp_decision.hex]

puts "=== ecg_top simulation: folder = $here ==="

# ---- 1. are all the files there? ----
set missing {}
foreach f [concat $rtl $tb $data] {
    if {![file exists [file join $here $f]]} { lappend missing $f }
}
foreach f $keyf {
    if {![file exists [file join $here answer_key $f]]} { lappend missing answer_key/$f }
}
if {[llength $missing] > 0} {
    error "These files are missing from $here :  $missing   -  copy them there and run the script again."
}
puts "All [expr {[llength $rtl] + 1 + [llength $data] + [llength $keyf]}] files found."

# ---- 2. make the project ----
catch {close_sim}
catch {close_project}
# The chip does not matter for simulation. We want the PYNQ chip (xc7z020clg400-1), but not every Vivado
# install has it. If it is missing, use another installed chip so the simulation can still run.
set part xc7z020clg400-1
if {[llength [get_parts -quiet $part]] == 0} {
    puts "NOTE: chip $part (the PYNQ board chip) is not installed in this Vivado."
    puts "      That is fine for simulation - the simulator does not use the chip."
    set part ""
    foreach cand {xc7a35tcpg236-1 xc7a100tcsg324-1 xc7a35tcsg324-1 xc7k70tfbg676-1} {
        if {[llength [get_parts -quiet $cand]] > 0} { set part $cand; break }
    }
    if {$part eq ""} {
        set allp [get_parts -quiet]
        if {[llength $allp] > 0} { set part [get_property NAME [lindex $allp 0]] }
    }
    if {$part eq ""} { error "This Vivado has no FPGA chips installed at all - send me a screenshot of this message." }
    puts "      Using chip $part for now."
}
create_project -force $pname $pdir -part $part

set rtl_paths {}
foreach f $rtl { lappend rtl_paths [file join $here $f] }
add_files -norecurse $rtl_paths
# (a path with a space in it, like "My Projects", must be wrapped in [list ...] or Vivado cuts it at the space)
add_files -fileset sim_1 -norecurse [list [file join $here $tb]]
foreach f $data { catch {add_files -fileset sim_1 -norecurse [list [file join $here $f]]} }

set_property top ecg_top    [get_filesets sources_1]
set_property top ecg_top_tb [get_filesets sim_1]
set_property verilog_define [list NBEATS=$NBEATS FIRST=$FIRST] [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

# ---- 3. start the simulator ----
puts "=== starting the simulator (this compiles everything, it can take a minute) ==="
launch_simulation

# The test reads weights.hex, biases.hex and answer_key/*.hex from the simulator's own folder.
# If Vivado did not copy them there, copy them now and restart the simulation from time 0.
set simdir [file join $pdir $pname.sim sim_1 behav xsim]
if {![file isdirectory $simdir]} {
    error "Could not find the simulator folder $simdir"
}
foreach f $data {
    if {![file exists [file join $simdir $f]]} { file copy -force [file join $here $f] $simdir }
}
if {![file isdirectory [file join $simdir answer_key]]} {
    file copy -force [file join $here answer_key] $simdir
}
restart

# ---- 4. run the test ----
puts "=== running the test with NBEATS=$NBEATS, FIRST=$FIRST ==="
run all
puts "=== finished. Look above for:  total errors : 0   and   ALL TESTS PASSED ==="
