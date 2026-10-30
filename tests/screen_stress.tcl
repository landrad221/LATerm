
#!/usr/bin/env tclsh

# Screen model stress tests
# Run: tclsh tests/screen_stress.tcl

set root [file dirname [file dirname [info script]]]
source [file join $root render/screen.tcl]

namespace eval ::screenStress {
    variable passed 0
    variable failed 0
}

proc ::screenStress::assert {condition message} {
    if {![uplevel 1 [list expr $condition]]} {
        error "Assertion failed: $message"
    }
}

proc ::screenStress::run {name script} {
    variable passed
    variable failed

    puts "\nRunning: $name"

    set start [clock microseconds]

    if {[catch {uplevel 1 $script} result opts]} {
        incr failed
        puts "FAIL: $name"
        puts "Reason: $result"
        puts [dict get $opts -errorinfo]
        return
    }

    set elapsed [expr {
        ([clock microseconds] - $start) / 1000000.0
    }]

    incr passed

    puts [format "PASS: %s (%.3f s)" $name $elapsed]
}

proc ::screenStress::newScreen {rows cols {history 1000}} {
    return [::laterm::Screen new $rows $cols $history]
}

puts "=========================================="
puts "Screen Stress Testing"
puts "Tcl version: [info patchlevel]"
puts "=========================================="

# ------------------------------------------
# 1. Sustained ASCII output
# ------------------------------------------

::screenStress::run "Sustained ASCII output" {
    set screen [::screenStress::newScreen 24 80 1000]

    try {
        set line [string repeat "A" 80]
        set iterations 2000

        set start [clock microseconds]

        for {set i 0} {$i < $iterations} {incr i} {
            $screen print $line

            if {$i % 200 == 0} {
                ::screenStress::assert \
                    {[$screen validateScreen] == 1} \
                    "Invalid screen during ASCII output"

                $screen consumeDirty
            }
        }

        set elapsed [expr {
            ([clock microseconds] - $start) / 1000000.0
        }]

        set characters [expr {$iterations * 80}]
        set rate [expr {$characters / $elapsed}]

        ::screenStress::assert \
            {[$screen validateScreen] == 1} \
            "Invalid final ASCII screen"

        puts [format "Characters: %d" $characters]
        puts [format "Throughput: %.0f chars/s" $rate]
        puts "Scrollback: [$screen scrollbackSize] rows"
    } finally {
        $screen destroy
    }
}

# ------------------------------------------
# 2. Scrollback pressure
# ------------------------------------------

::screenStress::run "Scrollback pressure" {
    set screen [::screenStress::newScreen 24 80 500]

    try {
        set iterations 3000

        for {set i 0} {$i < $iterations} {incr i} {
            $screen scrollUp 1

            if {$i % 250 == 0} {
                ::screenStress::assert \
                    {[$screen scrollbackSize] <= 500} \
                    "Scrollback exceeded configured limit"
            }
        }

        ::screenStress::assert \
            {[$screen scrollbackSize] == 500} \
            "Scrollback did not reach expected limit"

        ::screenStress::assert \
            {[$screen validateScreen] == 1} \
            "Invalid screen after scrolling"

        puts "Scroll operations: $iterations"
        puts "Scrollback limit: [$screen scrollbackLimit]"
        puts "Scrollback size: [$screen scrollbackSize]"
    } finally {
        $screen destroy
    }
}

# ------------------------------------------
# 3. Repeated resizing
# ------------------------------------------

::screenStress::run "Repeated resizing" {
    set screen [::screenStress::newScreen 24 80 100]

    try {
        set sizes {
            {24 80}
            {30 100}
            {40 120}
            {12 40}
            {50 160}
            {24 80}
        }

        set iterations 200

        for {set i 0} {$i < $iterations} {incr i} {
            lassign [lindex $sizes \
                [expr {$i % [llength $sizes]}]] rows cols

            $screen resize $rows $cols

            ::screenStress::assert \
                {[$screen dimensions] eq [list $rows $cols]} \
                "Incorrect dimensions after resize"

            ::screenStress::assert \
                {[$screen validateScreen] == 1} \
                "Invalid grid after resize"

            $screen moveCursor 0 0
            $screen print "LATerm"

            $screen consumeDirty
        }

        puts "Resize operations: $iterations"
        puts "Final dimensions: [$screen dimensions]"
    } finally {
        $screen destroy
    }
}

# ------------------------------------------
# 4. Unicode and wide characters
# ------------------------------------------

::screenStress::run "Unicode-heavy output" {
    set screen [::screenStress::newScreen 24 80 200]

    try {
        set samples [list \
            "Hello" \
            "Olá" \
            "日本語" \
            "漢字" \
            "🙂" \
            "e\u0301" \
            "A界B" \
        ]

        set iterations 3000

        for {set i 0} {$i < $iterations} {incr i} {
            set sample [lindex $samples \
                [expr {$i % [llength $samples]}]]

            $screen print $sample

            if {$i % 100 == 0} {
                ::screenStress::assert \
                    {[$screen validateScreen] == 1} \
                    "Invalid Unicode cell structure"

                $screen consumeDirty
            }
        }

        ::screenStress::assert \
            {[$screen validateScreen] == 1} \
            "Invalid final Unicode screen"

        puts "Unicode write operations: $iterations"
        puts "Final cursor: [$screen cursor]"
    } finally {
        $screen destroy
    }
}

# ------------------------------------------
# 5. Dirty tracking under repeated updates
# ------------------------------------------

::screenStress::run "Dirty tracking pressure" {
    set screen [::screenStress::newScreen 24 80 0]

    try {
        set iterations 10000

        for {set i 0} {$i < $iterations} {incr i} {
            set row [expr {$i % 24}]
            set col [expr {($i * 7) % 80}]

            $screen moveCursor $row $col
            $screen print "X"

            if {$i % 100 == 0} {
                set dirty [$screen consumeDirty]

                ::screenStress::assert \
                    {[dict exists $dirty rows]} \
                    "Missing dirty rows"

                ::screenStress::assert \
                    {[dict exists $dirty cursor]} \
                    "Missing cursor dirty state"
            }
        }

        ::screenStress::assert \
            {[$screen validateScreen] == 1} \
            "Invalid screen after dirty updates"

        puts "Cell updates: $iterations"
    } finally {
        $screen destroy
    }
}

# ------------------------------------------
# Summary
# ------------------------------------------

puts "\n=========================================="
puts "Stress test results"
puts "=========================================="

puts "Passed: $::screenStress::passed"
puts "Failed: $::screenStress::failed"

if {$::screenStress::failed > 0} {
    exit 1
}

puts "All stress tests passed."
exit 0
