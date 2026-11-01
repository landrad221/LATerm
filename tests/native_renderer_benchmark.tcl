#!/usr/bin/env tclsh

package require Tk

set root [file dirname [file dirname [info script]]]

source [file join $root render/screen.tcl]
lappend auto_path [file join $root render native]
package require laterm_native_renderer

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

wm title . "LATerm Native Renderer Benchmark"
wm geometry . 900x550

set screen [::LATerm::Screen new 24 80 0]
set renderer [::LATerm::NativeRenderer new \
    .nativeTerminal $screen {{DejaVu Sans Mono} 11}]
pack [$renderer widget] -fill both -expand 1
update idletasks

for {set row 0} {$row < 24} {incr row} {
    $screen moveCursor $row 0
    $screen print [string repeat \
        [format %c [expr {65 + ($row % 26)}]] 80]
}
$renderer render
update idletasks

puts "LATerm Native Renderer Benchmark"
puts "Tcl: [info patchlevel]"
puts "Tk: [package provide Tk]"
puts "Screen: 24x80"
puts "-----------------------------------------------"

set iterations 200
::rendererBenchmark::measure "Full redraw" $iterations {
    for {set i 0} {$i < $iterations} {incr i} {
        $renderer render
    }
}

for {set row 0} {$row < 24} {incr row} {
    $screen moveCursor $row 0
    for {set col 0} {$col < 80} {incr col} {
        set red [format %02x [expr {($col * 37 + $row * 11) % 256}]]
        set green [format %02x [expr {($col * 19 + $row * 29) % 256}]]
        set blue [format %02x [expr {($col * 13 + $row * 7) % 256}]]
        $screen setAttributes [dict create fg "#$red$green$blue"]
        $screen print X
    }
}
$renderer render
update idletasks

set iterations 5
::rendererBenchmark::measure "High-color full redraw" $iterations {
    for {set i 0} {$i < $iterations} {incr i} {
        $renderer render
    }
}

$screen resetAttributes
for {set row 0} {$row < 24} {incr row} {
    $screen moveCursor $row 0
    $screen print [string repeat A 80]
}
$renderer render
update idletasks

set iterations 1000
::rendererBenchmark::measure "Single-cell redraw" $iterations {
    for {set i 0} {$i < $iterations} {incr i} {
        set row [expr {$i % 24}]
        set col [expr {$i % 80}]
        $screen moveCursor $row $col
        $screen print X
        $renderer renderDirty
    }
}

set iterations 2000
::rendererBenchmark::measure "Cursor-only redraw" $iterations {
    for {set i 0} {$i < $iterations} {incr i} {
        $screen moveCursor [expr {$i % 24}] [expr {$i % 80}]
        $renderer renderDirty
    }
}

puts "Renderer statistics: [$renderer statistics]"

$renderer destroy
$screen destroy
destroy .

puts "-----------------------------------------------"
puts "Benchmark completed."
