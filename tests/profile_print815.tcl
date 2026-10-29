
#!/usr/bin/env tclsh

set root [file dirname [file dirname [info script]]]
source [file join $root render/screen.tcl]

namespace eval ::profile815 {}

proc ::profile815::measure {label count script} {
    set start [clock microseconds]
    uplevel 1 $script
    set elapsed [expr {
        ([clock microseconds] - $start) / 1000000.0
    }]

    puts [format "%-27s %8.4f s %12.0f ops/s" \
        $label $elapsed \
        [expr {$elapsed > 0 ? $count / $elapsed : 0}]]
}

set iterations 50000
set sample "A"

puts "LATerm 8.15.3 - Printing Profile"
puts "Tcl: [info patchlevel]"
puts "Operations per test: $iterations"
puts "--------------------------------------------------"

::profile815::measure "Unicode width" $iterations {
    for {set i 0} {$i < $iterations} {incr i} {
        ::laterm::unicode::charWidth $sample
    }
}

::profile815::measure "Unicode codepoint" $iterations {
    for {set i 0} {$i < $iterations} {incr i} {
        ::laterm::unicode::codepoint $sample
    }
}

set screen [::laterm::Screen new 24 80 0]

::profile815::measure "Single-char print" $iterations {
    for {set i 0} {$i < $iterations} {incr i} {
        $screen print $sample
    }
}

$screen destroy

set screen [::laterm::Screen new 24 80 0]
set chunk [string repeat "A" 80]
set chunks 625

::profile815::measure "80-char batch print" $iterations {
    for {set i 0} {$i < $chunks} {incr i} {
        $screen print $chunk
    }
}

$screen destroy

puts "--------------------------------------------------"
puts "Profile completed."
