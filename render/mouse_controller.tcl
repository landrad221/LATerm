
package require Tk

namespace eval ::LATerm {}

oo::class create ::LATerm::MouseController {
    variable widget screen encoder writer
    variable pressedButton lastPosition

    # textWidget is the Tk Text widget; screenObject provides cell
    # coordinates and tracking modes; mouseEncoder encodes terminal
    # reports; writerObject queues reports to the PTY.
    constructor {textWidget screenObject mouseEncoder writerObject} {
        set widget $textWidget
        set screen $screenObject
        set encoder $mouseEncoder
        set writer $writerObject

        set pressedButton 0
        set lastPosition {}
    }

    # Return whether the screen currently requests mouse reports.
    method reporting {} {
        return [$screen mouseReportingEnabled]
    }

    # Translate widget-relative pixel coordinates into zero-based
    # terminal row/column coordinates. x and y are integer Tk event
    # coordinates; returns {row col}, or {} when outside the screen.
    method coordinates {x y} {
        # Convert a Tk Text index to a screen row and cell column.
        #
        # This handles the Text widget's internal padding and
        # viewport position more reliably than dividing x/y
        # by a fixed character size.
        set index [$widget index "@${x},${y}"]
        lassign [split $index .] line charOffset

        set row [expr {$line - 1}]

        lassign [$screen dimensions] rows cols

        if {$row < 0 || $row >= $rows} {
            return {}
        }

        # Convert character offset into terminal cell columns.
        # Wide characters occupy two cells in the screen model.
        set col 0
        set charCount 0

        for {set c 0} {$c < $cols} {incr c} {
            set cell [$screen cell $row $c]
            set width [dict get $cell width]

            if {$width == 0} {
                continue
            }

            set text [dict get $cell text]
            set length [string length $text]

            # A blank terminal cell still occupies one Text
            # character in the renderer.
            if {$length == 0} {
                set length 1
            }

            if {$charCount >= $charOffset} {
                break
            }

            incr charCount $length
            incr col $width
        }

        if {$col >= $cols} {
            set col [expr {$cols - 1}]
        }

        return [list $row $col]
    }

    # Encode and queue one event. kind is press/release/drag/move or a
    # wheel direction; button is the Tk button number; x/y are event
    # coordinates and state is Tk's integer modifier-state mask.
    # Returns 1 when the event is consumed, or 0 when reporting is off.
    method send {kind button x y state} {
        if {![my reporting]} {
            return 0
        }

        set position [my coordinates $x $y]

        if {$position eq ""} {
            return 1
        }

        lassign $position row col

        set shift [expr {($state & 0x0001) != 0}]
        set ctrl  [expr {($state & 0x0004) != 0}]
        set alt   [expr {($state & 0x0008) != 0}]

        set data [$encoder encode \
            $kind $button $row $col $shift $alt $ctrl]

        if {$data ne ""} {
            if {[catch {
                $writer send $data
            } err]} {
                puts stderr "LATerm mouse PTY error: $err"
            }
        }

        return 1
    }

    # Handle a Tk button press. button is 1..3; x/y are widget pixels;
    # state is the Tk modifier-state bitmask. Returns the event-consumed
    # flag used by the application binding.
    method press {button x y state} {
        if {![my reporting]} {
            return 0
        }

        set pressedButton $button
        set lastPosition {}

        return [my send press $button $x $y $state]
    }

    # Handle a Tk button release; arguments have the same types as press.
    method release {button x y state} {
        if {![my reporting]} {
            return 0
        }

        set pressedButton 0
        set lastPosition {}

        return [my send release $button $x $y $state]
    }

    # Handle pointer motion using the current pressed button, if any.
    # Repeated events for the same terminal cell are suppressed.
    # x/y are widget pixels and state is the Tk modifier-state bitmask.
    method motion {x y state} {
        if {![my reporting]} {
            return 0
        }

        set position [my coordinates $x $y]

        if {$position eq ""} {
            return 1
        }

        # Avoid repeated reports for the same terminal cell.
        if {$position eq $lastPosition} {
            return 1
        }

        set lastPosition $position

        if {$pressedButton != 0} {
            return [my send drag $pressedButton $x $y $state]
        }

        return [my send move 0 $x $y $state]
    }

    # Handle a wheel event. direction is wheel-up or wheel-down; x/y are
    # widget pixels and state is the Tk modifier-state bitmask.
    method wheel {direction x y state} {
        if {![my reporting]} {
            return 0
        }

        return [my send $direction 0 $x $y $state]
    }
}
