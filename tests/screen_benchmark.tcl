
#!/usr/bin/env tclsh

# Screen model benchmark
# Run: tclsh tests/screen_benchmark.tcl

set root [file dirname [file dirname [info script]]]
source [file join $root render/screen.tcl]

namespace eval ::screenBenchmark {
    variable rows 24
    variable cols 80
}

proc ::screenBenchmark::measure {name operations script} {
    set start [clock microseconds]

    uplevel 1 $script

    set elapsed [expr {
        ([clock microseconds] - $start) / 1000000.0
    }]

    set rate [expr {
        $elapsed > 0 ? $operations / $elapsed : 0
    }]

    puts [format "%-24s %10.4f s %12.0f ops/s" \
        $name $elapsed $rate]
}

proc ::screenBenchmark::newScreen {} {
    variable rows
    variable cols

    return [::LATerm::Screen new $rows $cols 0]
}

puts "Screen Model Benchmark"
puts "Tcl version: [info patchlevel]"
puts "Screen size: 24x80"
puts "-----------------------------------------------"

# 1. Sequential ASCII printing
set s [::screenBenchmark::newScreen]

set text [string repeat "A" 80]
set iterations 1000

::screenBenchmark::measure \
    "Sequential printing" \
    [expr {$iterations * 80}] {

    for {set i 0} {$i < $iterations} {incr i} {
        $s print $text
    }
}

$s destroy

# 2. Cursor positioning
set s [::screenBenchmark::newScreen]

set iterations 100000

::screenBenchmark::measure \
    "Cursor positioning" \
    $iterations {

    for {set i 0} {$i < $iterations} {incr i} {
        $s moveCursor \
            [expr {$i % 24}] \
            [expr {$i % 80}]
    }
}

$s destroy

# 3. Scrolling
set s [::screenBenchmark::newScreen]

set iterations 2000

::screenBenchmark::measure \
    "Full-screen scrolling" \
    $iterations {

    for {set i 0} {$i < $iterations} {incr i} {
        $s scrollUp 1
    }
}

$s destroy

# 4. Dirty tracking
set s [::screenBenchmark::newScreen]

set iterations 100000

::screenBenchmark::measure \
    "Dirty-state consumption" \
    $iterations {

    for {set i 0} {$i < $iterations} {incr i} {
        $s moveCursor \
            [expr {$i % 24}] \
            [expr {$i % 80}]

        $s consumeDirty
    }
}

$s destroy

puts "-----------------------------------------------"
puts "Benchmark completed."