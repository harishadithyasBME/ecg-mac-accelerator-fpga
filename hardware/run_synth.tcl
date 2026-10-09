# run_synth.tcl  -  Vivado step 2: SYNTHESIS of the whole classifier (ecg_top).
#
# What it does, in plain words:
#   1. checks that all the design files are in this folder,
#   2. runs Vivado synthesis on ecg_top for the PYNQ chip (xc7z020clg400-1) with a 20 ns (50 MHz) clock target,
#      "out of context" = the design is synthesized on its own, with no board, no pins and no processor around it,
#   3. writes the reports into a sub-folder called  synth_out  and prints a short summary,
#   4. also saves the synthesized design (ecg_top_synth.dcp) for the next step.
#
# It does NOT change any of your files. It only creates:  synth_out/  (and the log synth.log if you use the command below).
#
# How to run it (from the VS Code terminal, one line at a time):
#     cd "C:\path\to\hardware"
#     & "D:\2026.1\Vivado\bin\vivado.bat" -mode batch -nojournal -log synth.log -source run_synth.tcl
#
# What a good result looks like (last lines):
#     SYNTHESIS FINISHED - no errors
#   and in the summary: Block RAM about 15-20 (NOT 0), DSP blocks 1 or more, worst slack positive.

# ---------------- settings you may change ----------------
set PART   xc7z020clg400-1   ;# the PYNQ-Z1 / PYNQ-Z2 chip. Change this one line for another chip.
set CLK_NS 20.0              ;# clock period in ns (20 ns = 50 MHz, the design's target)
# ---------------------------------------------------------

set here [file dirname [file normalize [info script]]]
if {[info script] eq ""} { set here [pwd] }
# Work inside the design folder: then the file names below have no spaces in them, and the memory files
# (weights.hex, biases.hex) that weight_rom.v / bias_rom.v read with $readmemh are found by their plain names.
cd $here
set outdir synth_out
file mkdir $outdir

set rtl  [list ecg_top.v layer_seq.v decision.v addr_gen.v layer_ctrl.v mac_unit.v bias_rescale.v \
               max_pool.v pool_pair.v bias_rom.v weight_rom.v data_buffer.v]
set hexf [list weights.hex biases.hex]

set summary {}
proc say {txt} {
    global summary
    puts $txt
    lappend summary $txt
}

puts "=== ecg_top synthesis: folder = $here ==="

# ---- 1. are all the files there? ----
set missing {}
foreach f [concat $rtl $hexf] {
    if {![file exists $f]} { lappend missing $f }
}
if {[llength $missing] > 0} {
    error "These files are missing from $here :  $missing   -  copy them there and run the script again."
}
puts "All [expr {[llength $rtl] + [llength $hexf]}] files found."

catch {close_sim}
catch {close_project}

if {[llength [get_parts -quiet $PART]] == 0} {
    error "The chip $PART is not installed in this Vivado (Zynq-7000 support is missing)."
}

# ---- 2. read the design and the clock constraint ----
puts "=== \[1/4\] reading the design files ==="
foreach f $rtl { read_verilog $f }

set xdc [file join $outdir ecg_top_clk.xdc]
set fh [open $xdc w]
puts $fh "create_clock -name clk -period $CLK_NS \[get_ports clk\]"
close $fh
read_xdc $xdc

# ---- 3. synthesis ----
puts "=== \[2/4\] synthesis - this takes a few minutes, please wait ==="
set t0 [clock seconds]
if {[catch {synth_design -top ecg_top -part $PART -mode out_of_context -include_dirs .} err]} {
    error "SYNTHESIS FAILED: $err"
}
set secs [expr {[clock seconds] - $t0}]
puts "synthesis took $secs seconds"

# ---- 4. reports ----
puts "=== \[3/4\] writing the reports into $outdir ==="
report_utilization -file [file join $outdir utilization.rpt]
set util [report_utilization -return_string]
catch {report_utilization -hierarchical -hierarchical_depth 3 -file [file join $outdir utilization_by_module.rpt]}
report_timing_summary -delay_type max -max_paths 10 -file [file join $outdir timing_summary.rpt]
catch {check_timing -file [file join $outdir check_timing.rpt]}
write_checkpoint -force [file join $outdir ecg_top_synth.dcp]
catch {write_verilog -mode funcsim -force [file join $outdir ecg_top_synth_funcsim.v]}

# ---- 5. the summary ----
puts "=== \[4/4\] summary ==="

# one row of a utilization table, e.g. {Slice LUTs*} -> used / available / percent
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

lassign [util_row $util "Slice LUTs*"]       lut_u lut_a lut_p
lassign [util_row $util "Slice Registers"]   ff_u  ff_a  ff_p
lassign [util_row $util "Block RAM Tile"]    br_u  br_a  br_p
lassign [util_row $util "DSPs"]              dsp_u dsp_a dsp_p

# worst setup slack (this is an ESTIMATE after synthesis: the real wires are only known after implementation)
set wns "n/a"; set sp "n/a"; set ep "n/a"; set lvl "n/a"; set dly "n/a"
if {![catch {set tp [get_timing_paths -max_paths 1 -setup]}] && [llength $tp] > 0} {
    set p0 [lindex $tp 0]
    catch {set wns [get_property SLACK $p0]}
    catch {set sp  [get_property STARTPOINT_PIN $p0]}
    catch {set ep  [get_property ENDPOINT_PIN $p0]}
    catch {set lvl [get_property LOGIC_LEVELS $p0]}
    catch {set dly [get_property DATAPATH_DELAY $p0]}
}
set fmax "n/a"
if {[string is double -strict $wns] && ($CLK_NS - $wns) > 0} {
    set fmax [format %.0f [expr {1000.0 / ($CLK_NS - $wns)}]]
}

# the messages Vivado printed, counted from the log (only if you used  -log synth.log  in the same folder)
set nerr 0; set ncw 0; set nw 0
set cwlines {}; set errlines {}; set readmem {}
array set wcnt {}; array set wex {}
set logf [file join $here synth.log]
set log_ok 0
if {[file exists $logf] && ![catch {set lf [open $logf r]}]} {
    set log_ok 1
    while {[gets $lf line] >= 0} {
        if {[string match -nocase "*readmem*" $line]} { lappend readmem [string trim $line] }
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

say "=========== SYNTHESIS SUMMARY ==========="
say "design       : ecg_top      chip: $PART      clock target: $CLK_NS ns ([format %.0f [expr {1000.0/$CLK_NS}]] MHz)"
say "LUTs         : $lut_u of $lut_a   ($lut_p %)"
say "Registers    : $ff_u of $ff_a   ($ff_p %)"
say "Block RAM    : $br_u of $br_a tiles   ($br_p %)"
say "DSP blocks   : $dsp_u of $dsp_a   ($dsp_p %)"
say "worst setup slack (estimate after synthesis): $wns ns   -> roughly $fmax MHz possible"
say "slowest path : from $sp"
say "               to   $ep"
say "               $lvl logic levels, data path $dly ns"
if {$log_ok} {
    say "messages     : $nerr errors, $ncw critical warnings, $nw warnings (details in $outdir/synth_messages.txt)"
} else {
    say "messages     : synth.log not found here - start Vivado with  -log synth.log  to get the message counts"
}

# sanity checks
set flags {}
if {[string is double -strict $br_u] && $br_u < 8} {
    lappend flags "Block RAM is far lower than expected (about 15-20): weights.hex was probably NOT read - look at the 'readmem' lines in synth_messages.txt"
}
if {[string is double -strict $dsp_u] && $dsp_u < 1} {
    lappend flags "no DSP block was used: the multiplier was built from LUTs"
}
if {[string is double -strict $wns] && $wns < 0} {
    lappend flags "the estimated slack is negative at $CLK_NS ns: the design is too slow at this clock (see $outdir/timing_summary.rpt)"
}
if {$nerr > 0} { lappend flags "Vivado reported $nerr error message(s) - see synth_messages.txt" }
if {$ncw > 0}  { lappend flags "Vivado reported $ncw critical warning(s) - see synth_messages.txt" }
if {[llength $flags] == 0} {
    say "checks       : all sanity checks passed"
} else {
    foreach f $flags { say "CHECK        : $f" }
}
say "==========================================="

# write the summary and the messages to files you can send me
set fo [open [file join $outdir synth_summary.txt] w]
puts $fo [join $summary "\n"]
close $fo

set fm [open [file join $outdir synth_messages.txt] w]
puts $fm "errors: $nerr    critical warnings: $ncw    warnings: $nw"
puts $fm ""
puts $fm "--- lines about reading the memory files (readmem) ---"
foreach l $readmem { puts $fm $l }
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
    puts "SYNTHESIS FINISHED - no errors.  Send me the file  $outdir/synth_summary.txt  (and synth_messages.txt)."
} else {
    puts "SYNTHESIS FINISHED WITH ERRORS - send me synth.log."
}
