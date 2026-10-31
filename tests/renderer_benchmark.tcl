
#!/usr/bin/env tclsh

package require Tk

set root [file dirname [file dirname [info script]]]

source [file join $root render/screen.tcl]
source [file join $root render/tk_renderer.tcl]
source [file join $root cursor_overlay.tcl]
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

wm title . "LATerm Renderer Benchmark"
wm geometry . 900x550

text .terminal \
    -font {{DejaVu Sans Mono} 11} \
    -foreground "#e5e7eb" \
    -background "#111827" \
    -wrap none \
    -width 80 \
    -height 24

pack .terminal -fill both -expand 1
canvas .cursorOverlay

set screen [::LATerm::Screen new 24 80 0]
set renderer [::LATerm::TkRenderer new .terminal $screen]
set cursorOverlay [::LATerm::CursorOverlay new \
    .cursorOverlay .terminal $renderer $screen]
$renderer setCursorOverlay $cursorOverlay
$cursorOverlay refresh
update idletasks

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

# 2. Full redraw with frequent foreground changes, approximating output
#    that creates many adjacent style runs (for example colored dashboards).
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

# Restore a uniform screen so the dirty-row benchmark measures a one-cell
# update rather than the high-color workload above.
for {set row 0} {$row < 24} {incr row} {
    $screen resetAttributes
    $screen moveCursor $row 0
    $screen print [string repeat A 80]
}
$renderer render
update idletasks

# 3. Dirty-row redraw: change one cell each iteration.
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

# Force the same one-character writes through the row-redraw fallback by
# marking an adjacent unchanged cell dirty as well.
::rendererBenchmark::measure "Forced row-redraw fallback" $iterations {
    for {set i 0} {$i < $iterations} {incr i} {
        set row [expr {$i % 24}]
        set col [expr {$i % 80}]
        set adjacent [expr {$col == 79 ? 78 : $col + 1}]
        set start [expr {min($col, $adjacent)}]
        set end [expr {max($col, $adjacent)}]

        $screen moveCursor $row $col
        $screen print "Y"
        $screen markDirty $row $start $end
        $renderer renderDirty
    }
}

# 4. Cursor-only updates.
set iterations 2000

::rendererBenchmark::measure "Cursor-only redraw" $iterations {
    for {set i 0} {$i < $iterations} {incr i} {
        $screen moveCursor \
            [expr {$i % 24}] \
            [expr {$i % 80}]

        $renderer renderDirty
    }
}

puts "Single-cell replacements: \
    [dict get [$renderer statistics] cellReplacements]"

set nativeScreen [::LATerm::Screen new 24 80 0]
set nativeRenderer [::LATerm::NativeRenderer new \
    .nativeTerminal $nativeScreen {{DejaVu Sans Mono} 11}]
pack [$nativeRenderer widget] -fill both -expand 1
update idletasks

for {set row 0} {$row < 24} {incr row} {
    $nativeScreen moveCursor $row 0
    $nativeScreen print [string repeat \
        [format %c [expr {65 + ($row % 26)}]] 80]
}
$nativeRenderer render
update idletasks

puts "\nNative C renderer"
puts "-----------------------------------------------"

set iterations 200
::rendererBenchmark::measure "Native full redraw" $iterations {
    for {set i 0} {$i < $iterations} {incr i} {
        $nativeRenderer render
    }
}

for {set row 0} {$row < 24} {incr row} {
    $nativeScreen moveCursor $row 0
    for {set col 0} {$col < 80} {incr col} {
        set red [format %02x [expr {($col * 37 + $row * 11) % 256}]]
        set green [format %02x [expr {($col * 19 + $row * 29) % 256}]]
        set blue [format %02x [expr {($col * 13 + $row * 7) % 256}]]
        $nativeScreen setAttributes [dict create fg "#$red$green$blue"]
        $nativeScreen print X
    }
}
$nativeRenderer render
update idletasks

set iterations 5
::rendererBenchmark::measure "Native high-color redraw" $iterations {
    for {set i 0} {$i < $iterations} {incr i} {
        $nativeRenderer render
    }
}

$nativeScreen resetAttributes
for {set row 0} {$row < 24} {incr row} {
    $nativeScreen moveCursor $row 0
    $nativeScreen print [string repeat A 80]
}
$nativeRenderer render
update idletasks

set iterations 1000
::rendererBenchmark::measure "Native single-row redraw" $iterations {
    for {set i 0} {$i < $iterations} {incr i} {
        set row [expr {$i % 24}]
        set col [expr {$i % 80}]
        $nativeScreen moveCursor $row $col
        $nativeScreen print X
        $nativeRenderer renderDirty
    }
}

set iterations 2000
::rendererBenchmark::measure "Native cursor-only update" $iterations {
    for {set i 0} {$i < $iterations} {incr i} {
        $nativeScreen moveCursor \
            [expr {$i % 24}] \
            [expr {$i % 80}]
        $nativeRenderer renderDirty
    }
}

$nativeRenderer destroy
$nativeScreen destroy
$renderer destroy
$cursorOverlay destroy
$screen destroy

destroy .

puts "-----------------------------------------------"
puts "Benchmark completed."