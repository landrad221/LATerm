namespace eval ::LATerm {}

oo::class create ::LATerm::ScreenAdapter {
    variable screen utf8Buffer responseCallback

    constructor {screenObject {responseHandler {}}} {
        set screen $screenObject
        set utf8Buffer {}
        set responseCallback $responseHandler
    }

    method respond {data} {
        if {$responseCallback eq ""} {
            return
        }

        {*}$responseCallback $data

    }       

    method event {type args} {
        # A pending UTF-8 sequence must not cross a control
        # sequence boundary.
        if {$type ne "byte" && $type ne "print"} {
            my flushIncompleteUtf8
        }

        switch -- $type {
            print {
                # ASCII bytes can interrupt an incomplete UTF-8
                # sequence. Replace the incomplete sequence.
                my flushIncompleteUtf8
                $screen print [lindex $args 0]
            }

            byte {
                my utf8Byte [lindex $args 0]
            }

            control {
                my control [lindex $args 0]
            }

            escape {
                my escape [lindex $args 0]
            }

            csi {
                lassign $args params intermediates final
                my csi $params $intermediates $final
            }
        }
    }

    method flushIncompleteUtf8 {} {
        if {[llength $utf8Buffer] > 0} {
            set utf8Buffer {}
            $screen print "\uFFFD"
        }
    }

    method utf8Byte {b} {
        lappend utf8Buffer $b

        set first [lindex $utf8Buffer 0]

        if {$first >= 0xC2 && $first <= 0xDF} {
            set expected 2
        } elseif {$first >= 0xE0 && $first <= 0xEF} {
            set expected 3
        } elseif {$first >= 0xF0 && $first <= 0xF4} {
            set expected 4
        } else {
            set utf8Buffer {}
            $screen print "\uFFFD"
            return
        }

        if {[llength $utf8Buffer] < $expected} {
            return
        }

        set bytes [binary format cu* $utf8Buffer]
        set utf8Buffer {}

        if {[catch {
            set decoded [encoding convertfrom utf-8 $bytes]
        }]} {
            $screen print "\uFFFD"
            return
        }

        $screen print $decoded
    }

    method control {name} {
        switch -- $name {
            CR  { $screen cr }
            LF  { $screen lf }
            VT  { $screen lf }
            FF  { $screen lf }
            BS  { $screen bs }
            HT  { $screen tab }

            default {
                # Unsupported or nonvisual control.
            }
        }
    }

    method escape {sequence} {
        switch -- $sequence {

            7 {$screen saveCursorState}
            8 {$screen restoreCursorState}
            D { $screen index }
            E {
                $screen cr
                $screen index
            }
            M { $screen reverseIndex }
            default {
                # Other ESC commands will be implemented later.
            }
        }
    }

    method parameter {values index {default 1}} {
        set value [lindex $values $index]

        if {$value eq "" || $value eq "0"} {
            return $default
        }

        if {![string is integer -strict $value]} {
            return $default
        }

        return $value
    }

    method csi {params intermediates final} {
        if {[string index $params 0] eq "?" && $intermediates eq ""} {
        if {$final eq "h" || $final eq "l"} {
            set enabled [expr {$final eq "h"}]

            foreach mode [split [string range $params 1 end] ";"] {
                if {[string is integer -strict $mode]} {
                    $screen setPrivateMode $mode $enabled
                }
            }
        }
        return
    }

    if {$intermediates ne ""} {
        return
    }

    set values [split $params ";"]
    set n [my parameter $values 0]

    lassign [$screen cursor] row col
    lassign [$screen dimensions] rows cols


           switch -exact -- $final {
            A {
                $screen moveCursor \
                    [expr {max(0, $row - $n)}] $col
            }

            B {
                $screen moveCursor \
                    [expr {min($rows - 1, $row + $n)}] $col
            }

            C {
                $screen moveCursor $row \
                    [expr {min($cols - 1, $col + $n)}]
            }

            D {
                $screen moveCursor $row \
                    [expr {max(0, $col - $n)}]
            }

            H -
            f {
                set r [my parameter $values 0]
                set c [my parameter $values 1]

                $screen moveCursor \
                    [expr {min($rows - 1, max(0, $r - 1))}] \
                    [expr {min($cols - 1, max(0, $c - 1))}]
            }

            G {
                $screen moveCursor $row \
                    [expr {min($cols - 1, $n - 1)}]
            }

            d {
                $screen moveCursor \
                    [expr {min($rows - 1, $n - 1)}] $col
            }

            J {
                $screen eraseInDisplay \
                    [my parameter $values 0 0]
            }

            K {
                $screen eraseInLine \
                    [my parameter $values 0 0]
            }

            X {
                $screen eraseCharacters $n
            }

            @ {
                $screen insertCharacters $n
            }

            P {
                $screen deleteCharacters $n
            }

            L {
                $screen insertLines $n
            }

            M {
                $screen deleteLines $n
            }

            S {
                $screen scrollUp $n
            }

            T {
                $screen scrollDown $n
            }

            r {
                set top [my parameter $values 0 1]
                set bottom [my parameter $values 1 $rows]

                if {$top < $bottom &&
                    $top >= 1 && $bottom <= $rows} {
                    $screen setScrollRegion \
                        [expr {$top - 1}] \
                        [expr {$bottom - 1}]
                    $screen moveCursor 0 0
                }
            }
            m {
                my sgr $params
            }
            n {
               my deviceStatusReport $params
            }
            c {
              my deviceAttributes $params
            }

            default {
                # SGR, DSR and other CSI operations
                # will be added in later milestones.
            }
        }
    }
    
    method ansiColor {index} {
        # Return an RGB hex string for an ANSI 256-color index.
        set basic {
            #000000 #800000 #008000 #808000
            #000080 #800080 #008080 #c0c0c0
            #808080 #ff0000 #00ff00 #ffff00
            #0000ff #ff00ff #00ffff #ffffff
        }

        if {$index < 0 || $index > 255} {
            error "Invalid ANSI color index: $index"
        }

        if {$index < 16} {
            return [lindex $basic $index]
        }

        if {$index < 232} {
            set n [expr {$index - 16}]
            set r [expr {$n / 36}]
            set g [expr {($n / 6) % 6}]
            set b [expr {$n % 6}]

            set levels {0 95 135 175 215 255}

            return [format "#%02x%02x%02x" \
                [lindex $levels $r] \
                [lindex $levels $g] \
                [lindex $levels $b]]
        }

        set gray [expr {8 + ($index - 232) * 10}]

        return [format "#%02x%02x%02x" \
            $gray $gray $gray]
    }

    method sgr {params} {
        if {$params eq ""} {
            set params 0
        }

        # This milestone supports semicolon-separated SGR.
        # Colon-separated extended SGR will be added later.
        if {![regexp {^[0-9;]+$} $params]} {
            return
        }

        set codes [split $params ";"]
        set count [llength $codes]

        for {set i 0} {$i < $count} {incr i} {
            set code [lindex $codes $i]
            if {$code eq ""} { set code 0 }

            switch -- $code {
                0 {
                    $screen resetAttributes
                }
                1 {
                    $screen setAttributes [dict create bold 1]
                }
                3 {
                    $screen setAttributes [dict create italic 1]
                }
                4 {
                    $screen setAttributes [dict create underline 1]
                }
                7 {
                    $screen setAttributes [dict create inverse 1]
                }
                22 {
                    $screen setAttributes [dict create bold 0]
                }
                23 {
                    $screen setAttributes [dict create italic 0]
                }
                24 {
                    $screen setAttributes [dict create underline 0]
                }
                27 {
                    $screen setAttributes [dict create inverse 0]
                }
                39 {
                    $screen setAttributes [dict create fg default]
                }
                49 {
                    $screen setAttributes [dict create bg default]
                }
                default {
                    if {$code >= 30 && $code <= 37} {
                        set color [my ansiColor [expr {$code - 30}]]
                        $screen setAttributes [dict create fg $color]

                    } elseif {$code >= 40 && $code <= 47} {
                        set color [my ansiColor [expr {$code - 40}]]
                        $screen setAttributes [dict create bg $color]

                    } elseif {$code >= 90 && $code <= 97} {
                        set color [my ansiColor [expr {$code - 90 + 8}]]
                        $screen setAttributes [dict create fg $color]

                    } elseif {$code >= 100 && $code <= 107} {
                        set color [my ansiColor [expr {$code - 100 + 8}]]
                        $screen setAttributes [dict create bg $color]

                    } elseif {$code == 38 || $code == 48} {
                        set key [expr {$code == 38 ? "fg" : "bg"}]
                        set mode [lindex $codes [expr {$i + 1}]]

                        if {$mode eq "5" && $i + 2 < $count} {
                            set value [lindex $codes [expr {$i + 2}]]

                            if {[string is integer -strict $value] &&
                                $value >= 0 && $value <= 255} {
                                $screen setAttributes [dict create \
                                    $key [my ansiColor $value]]
                            }

                            incr i 2

                        } elseif {$mode eq "2" && $i + 4 < $count} {
                            set rgb [lrange $codes \
                                [expr {$i + 2}] [expr {$i + 4}]]

                            set valid 1
                            foreach component $rgb {
                                if {![string is integer -strict $component] ||
                                    $component < 0 || $component > 255} {
                                    set valid 0
                                    break
                                }
                            }

                            if {$valid} {
                                lassign $rgb r g b
                                set color [format "#%02x%02x%02x" \
                                    $r $g $b]
                                $screen setAttributes [dict create \
                                    $key $color]
                            }

                            incr i 4
                        }
                    }
                }
            }
        }
    }
 
    method deviceStatusReport {params} {
        switch -- $params {
            5 {
                # Terminal is operational.
                my respond "\033\[0n"
            }

            6 {
                # Screen coordinates are zero-based;
                # CPR coordinates are one-based.
                lassign [$screen cursor] row col

                my respond [format "\033\[%d;%dR" \
                    [expr {$row + 1}] \
                    [expr {$col + 1}]]
            }
        }
    }

    method deviceAttributes {params} {
        # Respond to primary DA queries only.
        if {$params eq "" || $params eq "0"} {
            my respond "\033\[?1;2c"
        }
    }
}

