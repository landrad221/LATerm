
namespace eval ::laterm {}

oo::class create ::laterm::Screen {
    variable rows cols grid
    variable cursorRow cursorCol wrapPending attrs

    constructor {height width} {
        if {![string is integer -strict $height] ||
            ![string is integer -strict $width] ||
            $height < 1 || $width < 1} {
            error "screen dimensions must be positive integers"
        }

        set rows $height
        set cols $width
        set cursorRow 0
        set cursorCol 0
        set wrapPending 0

        set attrs [dict create \
            fg default \
            bg default \
            bold 0 \
            italic 0 \
            underline 0 \
            inverse 0]

        set grid {}

        for {set r 0} {$r < $rows} {incr r} {
            set line {}

            for {set c 0} {$c < $cols} {incr c} {
                lappend line [my blankCell]
            }

            lappend grid $line
        }
    }

    method blankCell {} {
        return [dict merge $attrs \
            [dict create text " " width 1]]
    }

    method dimensions {} {
        return [list $rows $cols]
    }

    method cursor {} {
        return [list $cursorRow $cursorCol]
    }

    method pendingWrap {} {
        return $wrapPending
    }

    method checkPosition {row col} {
        if {![string is integer -strict $row] ||
            ![string is integer -strict $col] ||
            $row < 0 || $row >= $rows ||
            $col < 0 || $col >= $cols} {
            error "cell position out of range: $row,$col"
        }
    }

    method cell {row col} {
        my checkPosition $row $col
        return [lindex $grid $row $col]
    }

    method moveCursor {row col} {
        my checkPosition $row $col

        set cursorRow $row
        set cursorCol $col
        set wrapPending 0
    }

    method print {text} {
        foreach ch [split $text ""] {
            if {$wrapPending} {
                if {$cursorRow == $rows - 1} {
                    error "printing requires scrolling beyond bottom row (milestone 2)"
                }

                set wrapPending 0
                set cursorCol 0
                incr cursorRow
            }

            set newCell [dict merge $attrs \
                [dict create text $ch width 1]]

            lset grid $cursorRow $cursorCol $newCell

            if {$cursorCol == $cols - 1} {
                set wrapPending 1
            } else {
                incr cursorCol
            }
        }
    }

    method dump {} {
        set lines {}

        foreach line $grid {
            set result ""

            foreach cell $line {
                append result [dict get $cell text]
            }

            lappend lines $result
        }

        return [join $lines "\n"]
    }
}
