
#!/usr/bin/env tclsh

package require Tk

set root [file dirname [file dirname [info script]]]

source [file join $root render/screen.tcl]
source [file join $root render/tk_renderer.tcl]

namespace eval ::rendererBenchmark {}

proc ::rendererBenchmark::measure {name iterations script} {
    set start [clock microseconds]

    uplevel 1 $script

    update idletasks

    set elapsed [expr {
        ([clock microseconds] - $start) / 1000000.0
    }]

    set rate [expr {
        $elapsed > 0 ? $iterations / $elapsed : 0
    }]

    puts [format "%-25s %9.4f s %10.1f renders/s" \
        $name $elapsed $rate]
}

wm title . "LATerm Renderer Benchmark"
wm geometry . 900x550

text .terminal \
    -font {{DejaVu Sans Mono} 11} \
    -wrap none \
    -width 80 \
    -height 24

pack .terminal -fill both -expand 1

set screen [::LATerm::Screen new 24 80 0]
set renderer [::LATerm::TkRenderer new .terminal $screen]

# Populate the entire screen.
for {set row 0} {$row < 24} {incr row} {
    $screen moveCursor $row 0
    $screen print [string repeat \
        [format %c [expr {65 + ($row % 26)}]] 80]
}

$renderer render
update idletasks

puts "Tk Renderer Benchmark"
puts "Tcl: [info patchlevel]"
puts "Tk: [package provide Tk]"
puts "Screen: 24x80"
puts "-----------------------------------------------"

# 1. Full redraw of a populated screen.
set iterations 200

::rendererBenchmark::measure "Full redraw" $iterations {
    for {set i 0} {$i < $iterations} {incr i} {
        $renderer render
    }
}

# 2. Dirty-row redraw: change one cell each iteration.
set iterations 1000

::rendererBenchmark::measure "Single-row redraw" $iterations {
    for {set i 0} {$i < $iterations} {incr i} {
        set row [expr {$i % 24}]
        set col [expr {$i % 80}]

        $screen moveCursor $row $col
        $screen print "X"

        $renderer renderDirty
    }
}

# 3. Cursor-only updates.
set iterations 2000

::rendererBenchmark::measure "Cursor-only redraw" $iterations {
    for {set i 0} {$i < $iterations} {incr i} {
        $screen moveCursor \
            [expr {$i % 24}] \
            [expr {$i % 80}]

        $renderer renderDirty
    }
}

$renderer destroy
$screen destroy

destroy .

puts "-----------------------------------------------"
puts "Benchmark completed."