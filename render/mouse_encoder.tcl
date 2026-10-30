
namespace eval ::LATerm {}

oo::class create ::LATerm::MouseEncoder {
    variable screen

    # screenObject is the Screen model used to read mouse modes and size.
    constructor {screenObject} {
        set screen $screenObject
    }

    # Encode a mouse event using the active terminal protocol.
    # kind is press, release, drag, move, wheel-up, or wheel-down;
    # button is a Tk button number (1..3) for button events (unused for
    # move/wheel), row/col are zero-based screen cells, and shift/alt/ctrl
    # are boolean-like modifier flags.
    # Returns protocol bytes, or "" when the event is not reportable.
    method encode {kind button row col {shift 0} {alt 0} {ctrl 0}} {
        if {![$screen mouseReportingEnabled]} {
            return ""
        }

        lassign [$screen dimensions] rows cols

        if {$row < 0 || $row >= $rows ||
            $col < 0 || $col >= $cols} {
            return ""
        }

        set tracking [$screen mouseTrackingMode]

        switch -- $kind {
            press -
            release {
                if {$button ni {1 2 3}} {
                    return ""
                }
                set code [expr {$button - 1}]
            }
            drag {
                if {$tracking ni {1002 1003}} {
                    return ""
                }
                if {$button ni {1 2 3}} {
                    return ""
                }
                set code [expr {$button - 1 + 32}]
            }
            move {
                if {$tracking != 1003} {
                    return ""
                }
                set code 35
            }
            wheel-up {
                set code 64
            }
            wheel-down {
                set code 65
            }
            default {
                return ""
            }
        }

        set code [expr {
            $code +
            ($shift ? 4 : 0) +
            ($alt ? 8 : 0) +
            ($ctrl ? 16 : 0)
        }]

        # Terminal coordinates are one-based.
        set x [expr {$col + 1}]
        set y [expr {$row + 1}]

        if {[$screen mouseMode 1006]} {
            # SGR release uses the original button code,
            # with lowercase m as the final character.
            set final [expr {$kind eq "release" ? "m" : "M"}]

            return [format "\033\[<%d;%d;%d%s" \
                $code $x $y $final]
        }

        # Legacy X10 encodes button and one-based coordinates as bytes
        # offset by 32. Its coordinate fields cannot represent values
        # above 223, so out-of-range events are intentionally omitted.
        if {$x > 223 || $y > 223} {
            return ""
        }

        if {$kind eq "release"} {
            set code [expr {
                3 +
                ($shift ? 4 : 0) +
                ($alt ? 8 : 0) +
                ($ctrl ? 16 : 0)
            }]
        }

        return [binary format a3ccc "\033\[M" \
            [expr {$code + 32}] \
            [expr {$x + 32}] \
            [expr {$y + 32}]]
    }
}
