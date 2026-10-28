
package require Tk

namespace eval ::LATerm {}

oo::class create ::LATerm::MouseController {
    variable widget screen encoder channel
    variable pressedButton lastPosition

    constructor {textWidget screenObject mouseEncoder ptyChannel} {
        set widget $textWidget
        set screen $screenObject
        set encoder $mouseEncoder
        set channel $ptyChannel

        set pressedButton 0
        set lastPosition {}
    }

    method reporting {} {
        return [$screen mouseReportingEnabled]
    }

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
                puts -nonewline $channel $data
                flush $channel
            } err]} {
                puts stderr "LATerm mouse PTY error: $err"
            }
        }

        return 1
    }

    method press {button x y state} {
        if {![my reporting]} {
            return 0
        }

        set pressedButton $button
        set lastPosition {}

        return [my send press $button $x $y $state]
    }

    method release {button x y state} {
        if {![my reporting]} {
            return 0
        }

        set pressedButton 0
        set lastPosition {}

        return [my send release $button $x $y $state]
    }

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

    method wheel {direction x y state} {
        if {![my reporting]} {
            return 0
        }

        return [my send $direction 0 $x $y $state]
    }
}
