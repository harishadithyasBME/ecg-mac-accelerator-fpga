# run_impl.tcl  -  Vivado step 3: IMPLEMENTATION (place and route) of the whole classifier (ecg_top).
#
# What it does, in plain words:
#   Synthesis (step 2) turned your Verilog into a netlist of LUTs, flip-flops, block RAMs and DSPs, but it only
#   GUESSED the wire delays. Implementation now
#       - places every one of those cells at a real spot on the PYNQ chip (xc7z020),
#       - draws every wire (routing),
#       - and then measures the REAL delays. That is the timing result that counts.
#   It starts from the file synth_out/ecg_top_synth.dcp made by run_synth.tcl, so run_synth.tcl must have been run first.
#
# It does NOT change any of your files. It only creates:  impl_out/  (and the log impl.log if you use the command below).
#
# How to run it (from the VS Code terminal, one line at a time):
#     cd "C:\path\to\hardware"
#     & "D:\2026.1\Vivado\bin\vivado.bat" -mode batch -nojournal -log impl.log -source run_impl.tcl
#
# What a good result looks like (last lines):
#     IMPLEMENTATION FINISHED - no errors
#   and in the summary: "TIMING MET", worst setup slack positive, worst hold slack positive, 0 unrouted nets.
#
# Note: the design is implemented "on its own" (out of context): it has no pins, no board and no processor around it yet,
# so only the paths between its own flip-flops / memories / DSPs are timed (those are the paths that decide the speed).
# Pins and the board come with the PYNQ wrapper later.

set DCP synth_out/ecg_top_synth.dcp

set here [file dirname [file normalize [info script]]]
if {[info script] eq ""} { set here [pwd] }
cd $here
set outdir impl_out
file mkdir $outdir

set summary {}
proc say {txt} {
    global summary
    puts $txt
    lappend summary $txt
}

puts "=== ecg_top implementation: folder = $here ==="

if {![file exists $DCP]} {
    error "The file $DCP is missing. Run run_synth.tcl first (it creates it)."
}

catch {close_sim}
catch {close_project}

# one stage = one Vivado command, with its running time printed
proc run_stage {title cmd} {
    puts "=== $title ==="
    set t0 [clock seconds]
    if {[catch {uplevel #0 $cmd} err]} {
        error "$title FAILED: $err"
    }
    puts "    ($title took [expr {[clock seconds] - $t0}] seconds)"
}

# ---- 1. open the synthesized design ----
puts "=== \[1/6\] opening the synthesized design ==="
open_checkpoint $DCP

set CLK_NS 20.0
catch {set CLK_NS [get_property PERIOD [get_clocks clk]]}
set PART xc7z020clg400-1
catch {set PART [get_property PART [current_design]]}

# ---- 2. implementation ----
run_stage "\[2/6\] opt_design (small clean-ups)"          opt_design
run_stage "\[3/6\] place_design (choosing a spot for every cell) - a few minutes" place_design
run_stage "\[4/6\] phys_opt_design (timing clean-up after placement)" phys_opt_design
run_stage "\[5/6\] route_design (drawing all the wires) - a few minutes" route_design

# ---- 3. reports ----
puts "=== \[6/6\] writing the reports into $outdir ==="
report_timing_summary -delay_type min_max -max_paths 10 -file [file join $outdir timing_summary.rpt]
set tsum [report_timing_summary -delay_type min_max -max_paths 10 -return_string]
catch {report_timing -delay_type max -max_paths 1 -sort_by slack -file [file join $outdir worst_setup_path.rpt]}
catch {report_timing -delay_type min -max_paths 1 -sort_by slack -file [file join $outdir worst_hold_path.rpt]}
report_utilization -file [file join $outdir utilization.rpt]
set util [report_utilization -return_string]
catch {report_utilization -hierarchical -hierarchical_depth 3 -file [file join $outdir utilization_by_module.rpt]}
report_route_status -file [file join $outdir route_status.rpt]
set rstat [report_route_status -return_string]
catch {report_clock_utilization -file [file join $outdir clock_utilization.rpt]}
write_checkpoint -force [file join $outdir ecg_top_routed.dcp]

# ---- 4. read the numbers ----
proc util_row {text pattern} {
    foreach line [split $text "\n"] {
        if {![string match "|*" $line]} { continue }
        set cells {}
        foreach c [split $line "|"] { lappend cells [string trim $c] }
        if {[llength $cells] < 6} { continue }
        if {[string match $pattern [lindex $cells 1]]} {
            set vals [lrange $cells 2 end-1]
            return [list [lindex $vals 0] [lindex $vals end-1] [lindex $vals end]]
        }
    }
    return {n/a n/a n/a}
}

lassign [util_row $util "Slice LUTs*"]     lut_u lut_a lut_p
lassign [util_row $util "Slice Registers"] ff_u  ff_a  ff_p
lassign [util_row $util "Slice"]           sl_u  sl_a  sl_p
lassign [util_row $util "Block RAM Tile"]  br_u  br_a  br_p
lassign [util_row $util "DSPs"]            dsp_u dsp_a dsp_p

# the "Design Timing Summary" table of report_timing_summary: one header line, one dashes line, one line of numbers
set wns n/a; set tns n/a; set tns_fail n/a; set whs n/a; set ths n/a; set ths_fail n/a
set tl [split $tsum "\n"]
for {set i 0} {$i < [llength $tl]} {incr i} {
    if {[string match "*WNS(ns)*TNS(ns)*" [lindex $tl $i]]} {
        set f [regexp -all -inline {\S+} [lindex $tl [expr {$i + 2}]]]
        if {[llength $f] >= 8} {
            lassign [lrange $f 0 7] wns tns tns_fail tns_tot whs ths ths_fail ths_tot
        }
        break
    }
}

# the slowest setup path, and the slowest hold path
set sp "n/a"; set ep "n/a"; set lvl "n/a"; set dly "n/a"; set ldly "n/a"; set ndly "n/a"
if {![catch {set tp [get_timing_paths -max_paths 1 -setup]}] && [llength $tp] > 0} {
    set p0 [lindex $tp 0]
    if {$wns eq "n/a"} { catch {set wns [get_property SLACK $p0]} }
    catch {set sp   [get_property STARTPOINT_PIN $p0]}
    catch {set ep   [get_property ENDPOINT_PIN $p0]}
    catch {set lvl  [get_property LOGIC_LEVELS $p0]}
    catch {set dly  [get_property DATAPATH_DELAY $p0]}
    catch {set ldly [get_property DATAPATH_LOGIC_DELAY $p0]}
    catch {set ndly [get_property DATAPATH_NET_DELAY $p0]}
}
if {$whs eq "n/a" && ![catch {set tph [get_timing_paths -max_paths 1 -hold]}] && [llength $tph] > 0} {
    catch {set whs [get_property SLACK [lindex $tph 0]]}
}

set fmax "n/a"
if {[string is double -strict $wns] && ($CLK_NS - $wns) > 0} {
    set fmax [format %.0f [expr {1000.0 / ($CLK_NS - $wns)}]]
}

# routing check
set unrouted "n/a"; set rerr "n/a"
regexp {# of unrouted nets\.* *: *([0-9]+)}           $rstat -> unrouted
regexp {# of nets with routing errors\.* *: *([0-9]+)} $rstat -> rerr

# the messages Vivado printed, counted from the log (only if you used  -log impl.log  in the same folder)
set nerr 0; set ncw 0; set nw 0
set cwlines {}; set errlines {}
array set wcnt {}; array set wex {}
set logf [file join $here impl.log]
set log_ok 0
if {[file exists $logf] && ![catch {set lf [open $logf r]}]} {
    set log_ok 1
    while {[gets $lf line] >= 0} {
        if {[regexp {^(CRITICAL WARNING|WARNING|ERROR): \[([^\]]+)\]} $line -> sev id]} {
            if {$sev eq "ERROR"} { incr nerr; lappend errlines $line } \
            elseif {$sev eq "CRITICAL WARNING"} { incr ncw; lappend cwlines $line } \
            else {
                incr nw
                if {![info exists wcnt($id)]} { set wcnt($id) 0; set wex($id) $line }
                incr wcnt($id)
            }
        }
    }
    close $lf
}

# ---- 5. the summary ----
set met 0
if {[string is double -strict $wns] && [string is double -strict $whs] && $wns >= 0 && $whs >= 0} { set met 1 }

say "=========== IMPLEMENTATION SUMMARY ==========="
say "design       : ecg_top      chip: $PART      clock target: $CLK_NS ns ([format %.0f [expr {1000.0/$CLK_NS}]] MHz)"
say "routing      : $unrouted unrouted nets, $rerr nets with routing errors"
if {$met} {
    say "TIMING       : MET - every checked path is fast enough at $CLK_NS ns"
} else {
    say "TIMING       : NOT MET (or could not be read) - see worst_setup_path.rpt and timing_summary.rpt"
}
say "setup (speed): worst slack $wns ns   total negative slack $tns ns   failing endpoints $tns_fail   -> roughly $fmax MHz possible"
say "hold         : worst slack $whs ns   total negative slack $ths ns   failing endpoints $ths_fail"
say "slowest path : from $sp"
say "               to   $ep"
say "               $lvl logic levels, data path $dly ns  (logic $ldly ns + wires $ndly ns)"
say "LUTs         : $lut_u of $lut_a   ($lut_p %)"
say "Registers    : $ff_u of $ff_a   ($ff_p %)"
say "Slices       : $sl_u of $sl_a   ($sl_p %)"
say "Block RAM    : $br_u of $br_a tiles   ($br_p %)"
say "DSP blocks   : $dsp_u of $dsp_a   ($dsp_p %)"
if {$log_ok} {
    say "messages     : $nerr errors, $ncw critical warnings, $nw warnings (details in $outdir/impl_messages.txt)"
} else {
    say "messages     : impl.log not found here - start Vivado with  -log impl.log  to get the message counts"
}

set flags {}
if {[string is double -strict $wns] && $wns < 0} {
    lappend flags "setup timing is NOT met at $CLK_NS ns (worst slack $wns ns) - the design is too slow at this clock"
}
if {[string is double -strict $whs] && $whs < 0} {
    lappend flags "hold timing is NOT met (worst hold slack $whs ns)"
}
if {[string is integer -strict $unrouted] && $unrouted > 0} { lappend flags "$unrouted nets were left unrouted" }
if {[string is integer -strict $rerr] && $rerr > 0}         { lappend flags "$rerr nets have routing errors" }
if {$wns eq "n/a" || $whs eq "n/a"} { lappend flags "the timing numbers could not be read - send me impl_out/timing_summary.rpt" }
if {$nerr > 0} { lappend flags "Vivado reported $nerr error message(s) - see impl_messages.txt" }
if {$ncw > 0}  { lappend flags "Vivado reported $ncw critical warning(s) - see impl_messages.txt" }
if {[llength $flags] == 0} {
    say "checks       : all checks passed"
} else {
    foreach f $flags { say "CHECK        : $f" }
}
say "=============================================="

set fo [open [file join $outdir impl_summary.txt] w]
puts $fo [join $summary "\n"]
close $fo

set fm [open [file join $outdir impl_messages.txt] w]
puts $fm "errors: $nerr    critical warnings: $ncw    warnings: $nw"
puts $fm ""
puts $fm "--- errors ---"
foreach l $errlines { puts $fm $l }
puts $fm ""
puts $fm "--- critical warnings ---"
foreach l $cwlines { puts $fm $l }
puts $fm ""
puts $fm "--- warnings (one example of each kind, with how many times it appeared) ---"
foreach id [lsort [array names wcnt]] { puts $fm "x$wcnt($id)   $wex($id)" }
close $fm

if {$nerr == 0} {
    puts "IMPLEMENTATION FINISHED - no errors.  Send me the files  $outdir/impl_summary.txt  and  $outdir/impl_messages.txt."
} else {
    puts "IMPLEMENTATION FINISHED WITH ERRORS - send me impl.log."
}
