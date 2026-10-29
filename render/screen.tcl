

namespace eval ::laterm {}
source [file join [file dirname [info script]] "../unicode.tcl"]

oo::class create ::laterm::Screen {
    variable rows cols grid
    variable cursorRow cursorCol wrapPending attrs
    variable scrollTop scrollBottom tabStops
    variable dirtyRows cursorDirty
    variable primaryState alternateState activeBuffer
    variable scrollback scrollbackLimit
    variable savedCursor
    variable mode1049Active
    variable cursorVisible
    variable applicationCursorKeys
    variable bracketedPaste
    variable mouseModes
    variable focusReporting
    variable cursorStyle

    constructor {height width {historyLimit 1000}} {
        if {![string is integer -strict $historyLimit] ||
           $historyLimit < 0} {
            error "scrollback limit must be a nonnegative integer"
        }

        if {![string is integer -strict $height] ||
            ![string is integer -strict $width] ||
            $height < 1 || $width < 1} {
            error "screen dimensions must be positive integers"
        }

        set cursorVisible 1
        set rows $height
        set cols $width
        set cursorRow 0
        set cursorCol 0
        set wrapPending 0
        set applicationCursorKeys 0
        set bracketedPaste 0
        set cursorStyle 1
        set mouseModes [dict create \
                             1000 0 \
                             1002 0 \
                             1003 0 \
                             1006 0]

        set scrollTop 0
        set scrollBottom [expr {$rows - 1}]
        set focusReporting 0

        set attrs [dict create \
            fg default bg default \
            bold 0 italic 0 \
            underline 0 inverse 0]

        set grid {}
        for {set r 0} {$r < $rows} {incr r} {
            lappend grid [my blankRow]
        }

        # Standard tab stops at columns 8, 16, 24...
        set tabStops [my defaultTabStops $cols]
        set dirtyRows {}
        set cursorDirty 1


        # A newly created screen must be drawn in full.
        my markAllDirty

        set primaryState {}
        set alternateState {}
        set activeBuffer primary
        set scrollback {}
        set scrollbackLimit $historyLimit
        set savedCursor {}
        set mode1049Active 0
    }


method setCursorStyle {style} {
    if {![string is integer -strict $style]} {
        return
    }

    if {$style < 0 || $style > 6} {
        return
    }

    set cursorStyle $style
}

method cursorStyle {} {
    return $cursorStyle
}

method cursorShape {} {
    switch -- $cursorStyle {
        0 - 1 - 2 { return block }
        3 - 4     { return underline }
        5 - 6     { return bar }
    }
}

method cursorBlinking {} {
    return [expr {$cursorStyle in {0 1 3 5}}]
}


method setFocusReporting {enabled} {
    set focusReporting [expr {$enabled ? 1 : 0}]
}

method focusReporting {} {
    return $focusReporting
}

method setMouseMode {mode enabled} {
    if {![dict exists $mouseModes $mode]} {
        return
    }

    dict set mouseModes $mode [expr {$enabled ? 1 : 0}]
}

method mouseMode {mode} {
    if {![dict exists $mouseModes $mode]} {
        return 0
    }

    return [dict get $mouseModes $mode]
}

method mouseTrackingMode {} {
    # Choose the most comprehensive enabled tracking mode.
    foreach mode {1003 1002 1000} {
        if {[dict get $mouseModes $mode]} {
            return $mode
        }
    }

    return 0
}

method mouseReportingEnabled {} {
    return [expr {[my mouseTrackingMode] != 0}]
}


method bracketedPaste {} {
    return $bracketedPaste
}

method setBracketedPaste {enabled} {
    set bracketedPaste [expr {$enabled ? 1 : 0}]
}

    

method applicationCursorKeys {} {
    return $applicationCursorKeys
}

method setApplicationCursorKeys {enabled} {
    set applicationCursorKeys [expr {$enabled ? 1 : 0}]
}

method resize {newRows newCols} {
    if {![string is integer -strict $newRows] ||
        ![string is integer -strict $newCols] ||
        $newRows <= 0 || $newCols <= 0} {
        error "screen dimensions must be positive integers"
    }

    # No work required if dimensions are unchanged.
    if {$newRows == $rows && $newCols == $cols} {
        return
    }

    # Resize the currently active grid.
    set grid [my resizeGrid $grid $newRows $newCols]

    # Resize both inactive/saved snapshots.
    set primaryState \
        [my resizeState $primaryState $newRows $newCols]

    set alternateState \
        [my resizeState $alternateState $newRows $newCols]

    # Update dimensions.
    set rows $newRows
    set cols $newCols

    # Clamp the active cursor.
    set cursorRow [expr {min($cursorRow, $rows - 1)}]
    set cursorCol [expr {min($cursorCol, $cols - 1)}]

    set wrapPending 0

    # Reset scrolling margins.
    set scrollTop 0
    set scrollBottom [expr {$rows - 1}]

    # Regenerate tab stops.
    set tabStops [my defaultTabStops $cols]

    # Clamp any saved cursor state.
    if {$savedCursor ne ""} {
        dict set savedCursor row \
            [expr {min([dict get $savedCursor row], $rows - 1)}]

        dict set savedCursor col \
            [expr {min([dict get $savedCursor col], $cols - 1)}]

        dict set savedCursor wrapPending 0
    }

    # Old dirty coordinates are no longer meaningful.
    set dirtyRows {}
    my markAllDirty
    set cursorDirty 1
}


method cursorVisible {} {
    return $cursorVisible
}

method setCursorVisible {visible} {
    set visible [expr {$visible ? 1 : 0}]

    if {$cursorVisible != $visible} {
        set cursorVisible $visible
        set cursorDirty 1
    }
}


method setAttributes {changes} {
    dict for {name value} $changes {
        if {$name ni {
            fg bg bold italic underline inverse
        }} {
            error "Unknown cell attribute: $name"
        }

        dict set attrs $name $value
    }
}

method resetAttributes {} {
    set attrs [dict create \
        fg default \
        bg default \
        bold 0 \
        italic 0 \
        underline 0 \
        inverse 0]
}

method currentAttributes {} {
    return $attrs
}


method saveCursorState {} {
    set savedCursor [dict create \
        row $cursorRow \
        col $cursorCol \
        wrapPending $wrapPending \
        attrs $attrs]
}

method restoreCursorState {} {
    if {$savedCursor eq ""} {
        return
    }

    set cursorRow [dict get $savedCursor row]
    set cursorCol [dict get $savedCursor col]
    set wrapPending [dict get $savedCursor wrapPending]
    set attrs [dict get $savedCursor attrs]

    # Defensive bounds checking for future resize support.
    set cursorRow [expr {
        max(0, min($cursorRow, $rows - 1))
    }]

    set cursorCol [expr {
        max(0, min($cursorCol, $cols - 1))
    }]

    set cursorDirty 1
}


method clearAlternateBuffer {} {
    if {$activeBuffer eq "alternate"} {
        # Clear the currently visible alternate buffer.
        set grid {}

        for {set r 0} {$r < $rows} {incr r} {
            lappend grid [my blankRow]
        }

        set cursorRow 0
        set cursorCol 0
        set wrapPending 0
        set scrollTop 0
        set scrollBottom [expr {$rows - 1}]

        my markAllDirty
        set cursorDirty 1
    } else {
        # Clear the inactive alternate snapshot.
        set alternateState [my freshState]
    }
}


method setPrivateMode {mode enabled} {
    set enabled [expr {!!$enabled}]

    switch -- $mode {
        1 {
            my setApplicationCursorKeys $enabled
        }
        25 {
            my setCursorVisible $enabled
        }
        47 {
            if {$enabled} {
                my enterAlternate
            } else {
                my leaveAlternate
            }
        }
        1004 {
            my setFocusReporting $enabled
        }

        1047 {
            if {$enabled} {
                my enterAlternate
            } else {
                my leaveAlternate
                my clearAlternateBuffer
            }
        }

        1048 {
            if {$enabled} {
                my saveCursorState
            } else {
                my restoreCursorState
            }
        }

        1049 {
            if {$enabled} {
                if {!$mode1049Active} {
                    my saveCursorState
                    my enterAlternate
                    my clearAlternateBuffer
                    set mode1049Active 1
                }
            } else {
                if {$mode1049Active} {
                    my leaveAlternate
                    my restoreCursorState
                    set mode1049Active 0
                }
            }
        }
        
        2004 {
           my setBracketedPaste $enabled
        }
        1000 -
        1002 -
        1003 -
        1006 {
            my setMouseMode $mode $enabled
        }   

        default {
            # Ignore unsupported DEC private modes for now.
        }
    }
}

    
method appendScrollback {line} {
    if {$scrollbackLimit == 0} {
        return
    }

    lappend scrollback $line

    set excess [expr {
        [llength $scrollback] - $scrollbackLimit
    }]

    if {$excess > 0} {
        set scrollback [lrange $scrollback $excess end]
    }
}

method scrollbackSize {} {
    return [llength $scrollback]
}

method scrollbackLimit {} {
    return $scrollbackLimit
}

method scrollbackRow {index} {
    if {![string is integer -strict $index] ||
        $index < 0 ||
        $index >= [llength $scrollback]} {
        error "scrollback row out of range: $index"
    }

    return [lindex $scrollback $index]
}

method clearScrollback {} {
    set scrollback {}
}

method setScrollbackLimit {limit} {
    if {![string is integer -strict $limit] ||
        $limit < 0} {
        error "scrollback limit must be a nonnegative integer"
    }

    set scrollbackLimit $limit

    if {$limit == 0} {
        set scrollback {}
        return
    }

    set excess [expr {
        [llength $scrollback] - $limit
    }]

    if {$excess > 0} {
        set scrollback [lrange $scrollback $excess end]
    }
}

    
method captureState {} {
    return [dict create \
        grid $grid \
        cursorRow $cursorRow \
        cursorCol $cursorCol \
        wrapPending $wrapPending \
        scrollTop $scrollTop \
        scrollBottom $scrollBottom \
        tabStops $tabStops \
        attrs $attrs]
}

method restoreState {state} {
    set grid [dict get $state grid]
    set cursorRow [dict get $state cursorRow]
    set cursorCol [dict get $state cursorCol]
    set wrapPending [dict get $state wrapPending]
    set scrollTop [dict get $state scrollTop]
    set scrollBottom [dict get $state scrollBottom]
    set tabStops [dict get $state tabStops]
    set attrs [dict get $state attrs]

    # The restored buffer must be redrawn.
    my markAllDirty
    set cursorDirty 1
}


method freshState {} {
    set newGrid {}

    for {set r 0} {$r < $rows} {incr r} {
        lappend newGrid [my blankRow]
    }

    return [dict create \
        grid $newGrid \
        cursorRow 0 \
        cursorCol 0 \
        wrapPending 0 \
        scrollTop 0 \
        scrollBottom [expr {$rows - 1}] \
        tabStops $tabStops \
        attrs $attrs]
}



method enterAlternate {} {
    if {$activeBuffer eq "alternate"} {
        return
    }

    # Preserve the primary screen.
    set primaryState [my captureState]

    # Restore an existing alternate buffer,
    # or create a new one on first entry.
    if {$alternateState eq ""} {
        set alternateState [my freshState]
    }

    set activeBuffer alternate
    my restoreState $alternateState
}

method leaveAlternate {} {
    if {$activeBuffer eq "primary"} {
        return
    }

    # Preserve the alternate buffer for possible reuse.
    set alternateState [my captureState]

    set activeBuffer primary
    my restoreState $primaryState
}

method activeScreen {} {
    return $activeBuffer
}


method resizeRow {line newCols} {
    set oldCols [llength $line]

    if {$newCols > $oldCols} {
        # Extend the row with blank cells.
        for {set col $oldCols} {$col < $newCols} {incr col} {
            lappend line [my blankCell]
        }
    } elseif {$newCols < $oldCols} {
        # Truncate the row.
        set line [lrange $line 0 [expr {$newCols - 1}]]
    }

    # Repair a wide character split by truncation.
    # Only the final cell can become an orphaned
    # leading cell when a valid row is shortened.
    set last [expr {$newCols - 1}]
    set cell [lindex $line $last]

    if {[dict get $cell width] == 2} {
        lset line $last [my blankCell]
    }

    return $line
}

method resizeGrid {oldGrid newRows newCols} {
    set newGrid {}
    set oldRows [llength $oldGrid]

    # Preserve rows from the top.
    set retained [expr {min($oldRows, $newRows)}]

    for {set row 0} {$row < $retained} {incr row} {
        set line [lindex $oldGrid $row]
        lappend newGrid [my resizeRow $line $newCols]
    }

    # Append blank rows when increasing height.
    for {set row $retained} {$row < $newRows} {incr row} {
        set line {}

        for {set col 0} {$col < $newCols} {incr col} {
            lappend line [my blankCell]
        }

        lappend newGrid $line
    }

    return $newGrid
}

method resizeState {state newRows newCols} {
    if {$state eq ""} {
        return {}
    }

    dict set state grid \
        [my resizeGrid [dict get $state grid] $newRows $newCols]

    set row [dict get $state cursorRow]
    set col [dict get $state cursorCol]

    dict set state cursorRow \
        [expr {min($row, $newRows - 1)}]

    dict set state cursorCol \
        [expr {min($col, $newCols - 1)}]

    # A pending wrap at the previous right edge
    # is no longer reliable after resizing.
    dict set state wrapPending 0

    dict set state scrollTop 0
    dict set state scrollBottom [expr {$newRows - 1}]

    dict set state tabStops [my defaultTabStops $newCols]

    return $state
}


method defaultTabStops {width} {
    set stops {}

    for {set col 8} {$col < $width} {incr col 8} {
        lappend stops $col
    }

    return $stops
}

    
    method continuationCell {} {
        return [dict merge $attrs [dict create \
            text "" \
            width 0 \
        ]]
    }


    
method clearGlyphAt {row col} {
    my checkPosition $row $col

    set cell [my cell $row $col]
    set width [dict get $cell width]

    switch -- $width {
        2 {
            # Clear the wide character and its continuation.
            lset grid $row $col [my blankCell]
            my markDirty $row $col $col

            if {$col + 1 < $cols} {
                lset grid $row [expr {$col + 1}] [my blankCell]
                my markDirty $row [expr {$col + 1}] \
                    [expr {$col + 1}]
            }
        }

        0 {
            # Continuation cell: clear the leading cell too.
            lset grid $row $col [my blankCell]
            my markDirty $row $col $col

            if {$col > 0} {
                set prev [my cell $row [expr {$col - 1}]]

                if {[dict get $prev width] == 2} {
                    lset grid $row [expr {$col - 1}] [my blankCell]
                    my markDirty $row [expr {$col - 1}] \
                        [expr {$col - 1}]
                }
            }
        }

        default {
            lset grid $row $col [my blankCell]
            my markDirty $row $col $col
        }
    }
}   


method appendCombining {ch} {
    # If wrap is pending, the previous glyph is
    # at the current cursor position.
    if {$wrapPending} {
        set col $cursorCol
    } else {
        set col [expr {$cursorCol - 1}]
    }

    # No preceding glyph on this row.
    if {$col < 0} {
        return
    }

    # A wide character may occupy the previous two cells.
    set cell [my cell $cursorRow $col]

    if {[dict get $cell width] == 0} {
        incr col -1

        if {$col < 0} {
            return
        }

        set cell [my cell $cursorRow $col]
    }

    # Only attach to a real, nonblank glyph.
    if {[dict get $cell text] eq " "} {
        return
    }

    dict append cell text $ch
    lset grid $cursorRow $col $cell

    set width [dict get $cell width]
    my markDirty $cursorRow $col \
        [expr {min($cols - 1, $col + $width - 1)}]
}

    method markDirty {row start end} {
        if {$row < 0 || $row >= $rows} {
            error "dirty row out of range"
        }

        set start [expr {max(0, $start)}]
        set end [expr {min($cols - 1, $end)}]

        if {$start > $end} {
            return
        }

        set ranges {}

        if {[dict exists $dirtyRows $row]} {
            set ranges [dict get $dirtyRows $row]
        }


        # Fast path: the new range extends or overlaps
        # the final existing range.
        #
        # This is common during sequential printing.

        if {[llength $ranges] > 0} {
            set last [lindex $ranges end]
            lassign $last lastStart lastEnd

            if {$start >= $lastStart &&
                $start <= $lastEnd + 1} {

                if {$end > $lastEnd} {
                    lset ranges end [list $lastStart $end]
                    dict set dirtyRows $row $ranges
                }

                return
            }
        }

        # General case: insert, sort and merge.
        lappend ranges [list $start $end]
        set ranges [lsort -integer -index 0 $ranges]


        set merged {}

        foreach range $ranges {
            lassign $range a b

            if {[llength $merged] == 0} {
                lappend merged [list $a $b]
                continue
            }

            set last [lindex $merged end]
            lassign $last x y

            if {$a <= $y + 1} {
                lset merged end [list $x [expr {max($y, $b)}]]
            } else {
                lappend merged [list $a $b]
            }
        }

        dict set dirtyRows $row $merged
    }

    method markRowDirty {row} {
        my markDirty $row 0 [expr {$cols - 1}]
    }

    method markAllDirty {} {
        for {set r 0} {$r < $rows} {incr r} {
            my markRowDirty $r
        }
    }

    method consumeDirty {} {
        set result [dict create \
            rows $dirtyRows \
            cursor $cursorDirty]

        set dirtyRows {}
        set cursorDirty 0

        return $result
    }

    method peekDirty {} {
        return [dict create \
            rows $dirtyRows \
            cursor $cursorDirty]
    }


    method blankCell {} {
        return [dict merge $attrs \
            [dict create text " " width 1]]
    }

    method blankRow {} {
        set line {}
        for {set c 0} {$c < $cols} {incr c} {
            lappend line [my blankCell]
        }
        return $line
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

    method scrollRegion {} {
        return [list $scrollTop $scrollBottom]
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
        set cursorDirty 1
    }

    
method validateRow {row} {
    if {![string is integer -strict $row] ||
        $row < 0 || $row >= $rows} {
        error "row out of range"
    }

    for {set col 0} {$col < $cols} {incr col} {
        set cell [my cell $row $col]
        set width [dict get $cell width]

        switch -- $width {
            0 {
                if {$col == 0} {
                    error "orphan continuation at $row,$col"
                }

                set prev [my cell $row [expr {$col - 1}]]

                if {[dict get $prev width] != 2} {
                    error "orphan continuation at $row,$col"
                }
            }

            1 {
                # Ordinary single-column cell.
            }

            2 {
                if {$col == $cols - 1} {
                    error "wide glyph crosses right edge at $row,$col"
                }

                set next [my cell $row [expr {$col + 1}]]

                if {[dict get $next width] != 0} {
                    error "missing continuation at $row,$col"
                }
            }

            default {
                error "invalid cell width $width at $row,$col"
            }
        }
    }

    return 1
}

method validateScreen {} {
    for {set row 0} {$row < $rows} {incr row} {
        my validateRow $row
    }

    return 1
}


    # ------------------------------
    # Scrolling
    # ------------------------------


method scrollUp {{count 1}} {
    if {![string is integer -strict $count] || $count < 0} {
        error "invalid scroll count"
    }

    set height [expr {$scrollBottom - $scrollTop + 1}]
    set count [expr {min($count, $height)}]

    # Only full-screen scrolling on the primary
    # buffer contributes to scrollback.
    set captureHistory [expr {
        $activeBuffer eq "primary" &&
        $scrollTop == 0 &&
        $scrollBottom == $rows - 1
    }]

    for {set i 0} {$i < $count} {incr i} {

        # Capture the row before removing it.
        if {$captureHistory} {
            set removedRow [lindex $grid $scrollTop]
            my appendScrollback $removedRow
        }

        # Remove the top row of the scrolling region.
        set grid [lreplace \
            $grid $scrollTop $scrollTop]

        # Insert a blank row at the bottom margin.
        set grid [linsert \
            $grid $scrollBottom [my blankRow]]
    }

    # Dirty tracking: only rows inside the
    # scrolling region have changed.
    if {$count > 0} {
        for {set r $scrollTop} {$r <= $scrollBottom} {incr r} {
            my markRowDirty $r
        }
    }
}

    method scrollDown {{count 1}} {
        if {![string is integer -strict $count] || $count < 0} {
            error "invalid scroll count"
        }

        set height [expr {$scrollBottom - $scrollTop + 1}]
        set count [expr {min($count, $height)}]

        for {set i 0} {$i < $count} {incr i} {
            set grid [lreplace $grid $scrollBottom $scrollBottom]
            set grid [linsert $grid $scrollTop [my blankRow]]
        }

        for {set r $scrollTop} {$r <= $scrollBottom} {incr r} {
            my markRowDirty $r
        }
    }

    method setScrollRegion {top bottom} {
        if {![string is integer -strict $top] ||
            ![string is integer -strict $bottom] ||
            $top < 0 || $bottom >= $rows ||
            $top >= $bottom} {
            error "invalid scroll region"
        }

        set scrollTop $top
        set scrollBottom $bottom

        my moveCursor 0 0
    }

    method resetScrollRegion {} {
        set scrollTop 0
        set scrollBottom [expr {$rows - 1}]
        my moveCursor 0 0
    }

    # ------------------------------
    # Cursor control
    # ------------------------------

    method cr {} {
        set cursorCol 0
        set wrapPending 0
    }

    method bs {} {
        if {$cursorCol > 0} {
            incr cursorCol -1
        }
        set wrapPending 0
    }

    method tab {} {
        foreach stop $tabStops {
            if {$stop > $cursorCol} {
                set cursorCol $stop
                set wrapPending 0
                return
            }
        }

        set cursorCol [expr {$cols - 1}]
        set wrapPending 0
    }

    method index {} {
        set wrapPending 0

        if {$cursorRow == $scrollBottom} {
            my scrollUp 1
        } elseif {$cursorRow < $rows - 1} {
            incr cursorRow
        }
    }

    method reverseIndex {} {
        set wrapPending 0

        if {$cursorRow == $scrollTop} {
            my scrollDown 1
        } elseif {$cursorRow > 0} {
            incr cursorRow -1
        }
    }

    method lf {} {
        my index
    }

    # ------------------------------
    # Printing
    # ------------------------------


method print {text} {
    foreach ch [split $text ""] {
        set width [::laterm::unicode::charWidth $ch]

        # The parser must handle C0/C1 controls.
        # They must not become combining marks.
        set cp [::laterm::unicode::codepoint $ch]

        if {$cp < 0x20 || ($cp >= 0x7F && $cp < 0xA0)} {
            error "control character passed to Screen.print"
        }

        # Combining marks do not advance the cursor.
        if {$width == 0} {
            my appendCombining $ch
            continue
        }

        # A wide glyph cannot fit in a one-column screen.
        if {$width > $cols} {
            error "character wider than screen"
        }

        # Resolve delayed autowrap before printing.
        if {$wrapPending} {
            set cursorCol 0
            my index
        }

        # A wide character must fit entirely on a row.
        if {$width == 2 && $cursorCol == $cols - 1} {
            # Leave a blank at the final column.
            my clearGlyphAt $cursorRow $cursorCol

            set cursorCol 0
            my index
        }

 
        # A normal width-1 destination will be overwritten
        # immediately, so clearing it first is unnecessary.
        #
        # Wide glyphs and continuation cells still require
        # cleanup to preserve screen-grid invariants.

        set existing [lindex $grid $cursorRow $cursorCol]
        set existingWidth [dict get $existing width]

        if {$existingWidth != 1} {
            my clearGlyphAt $cursorRow $cursorCol
        }

        if {$width == 2} {
            set nextCol [expr {$cursorCol + 1}]
            set nextCell [lindex $grid $cursorRow $nextCol]

            if {[dict get $nextCell width] != 1} {
                my clearGlyphAt $cursorRow $nextCol
            }
        }


        # Write the leading cell.
        set newCell [dict merge $attrs \
            [dict create text $ch width $width]]

        lset grid $cursorRow $cursorCol $newCell

        my markDirty $cursorRow $cursorCol \
            [expr {$cursorCol + $width - 1}]

        # Write the continuation cell for wide characters.
        if {$width == 2} {
            lset grid $cursorRow [expr {$cursorCol + 1}] \
                [my continuationCell]
        }

        set nextCol [expr {$cursorCol + $width}]

        if {$nextCol >= $cols} {
            set cursorCol [expr {$cols - 1}]
            set wrapPending 1
        } else {
            set cursorCol $nextCol
            set wrapPending 0
        }

        set cursorDirty 1
    }
}

    # ------------------------------
    # Debugging
    # ------------------------------

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
    
method dumpScrollback {} {
    set lines {}

    foreach row $scrollback {
        set text ""

        foreach cell $row {
            append text [dict get $cell text]
        }

        lappend lines $text
    }

    return [join $lines "\n"]
}

    
method dumpCells {} {
    set lines {}

    foreach line $grid {
        set result ""

        foreach cell $line {
            set width [dict get $cell width]

            if {$width == 0} {
                append result "·"
            } else {
                append result [dict get $cell text]
            }
        }

        lappend lines $result
    }

    return [join $lines "\n"]
}

    
    # Replace cells from start through end (inclusive).
#
#
# 
method eraseRange {row start end} {
    if {![string is integer -strict $row] ||
        $row < 0 || $row >= $rows} {
        error "row out of range"
    }

    set start [expr {max(0, $start)}]
    set end [expr {min($cols - 1, $end)}]

    if {$start > $end} {
        return
    }

    # Expand the left boundary if it starts
    # inside a wide character.
    set first [my cell $row $start]

    if {[dict get $first width] == 0 && $start > 0} {
        incr start -1
    }

    # Expand the right boundary if it ends
    # on a wide-character leading cell.
    set last [my cell $row $end]

    if {[dict get $last width] == 2 && $end < $cols - 1} {
        incr end
    }

    for {set col $start} {$col <= $end} {incr col} {
        lset grid $row $col [my blankCell]
    }

    my markDirty $row $start $end
}

    # Validate and normalize CSI counts.
    # A count of zero behaves like one.
    method normalizeCount {count} {
        if {![string is integer -strict $count] || $count < 0} {
            error "invalid count"
        }

        return [expr {max(1, $count)}]
    }

    
method repairRow {row} {
    set line [lindex $grid $row]
    set changed {}

    for {set col 0} {$col < $cols} {incr col} {
        set cell [lindex $line $col]
        set width [dict get $cell width]

        if {$width == 2} {
            if {$col == $cols - 1 ||
                [dict get [lindex $line [expr {$col + 1}]] width] != 0} {
                lset line $col [my blankCell]
                lappend changed $col
            }
        } elseif {$width == 0} {
            if {$col == 0 ||
                [dict get [lindex $line [expr {$col - 1}]] width] != 2} {
                lset line $col [my blankCell]
                lappend changed $col
            }
        }
    }

    lset grid $row $line

    foreach col $changed {
        my markDirty $row $col $col
    }
}
    
    method eraseInLine {{mode 0}} {
        switch -- $mode {
            0 {
                my eraseRange $cursorRow $cursorCol [expr {$cols - 1}]
            }
            1 {
                my eraseRange $cursorRow 0 $cursorCol
            }
            2 {
                my eraseRange $cursorRow 0 [expr {$cols - 1}]
            }
            default {
                error "invalid erase-in-line mode: $mode"
            }
        }

        set wrapPending 0
    }

    
    method eraseInDisplay {{mode 0}} {
        switch -- $mode {
            0 {
                my eraseRange $cursorRow $cursorCol [expr {$cols - 1}]

                for {set r [expr {$cursorRow + 1}]} {$r < $rows} {incr r} {
                    my eraseRange $r 0 [expr {$cols - 1}]
                }
            }
            1 {
                for {set r 0} {$r < $cursorRow} {incr r} {
                    my eraseRange $r 0 [expr {$cols - 1}]
                }

                my eraseRange $cursorRow 0 $cursorCol
            }
            2 {
                for {set r 0} {$r < $rows} {incr r} {
                    my eraseRange $r 0 [expr {$cols - 1}]
                }
            }
            3 {
                # No scrollback buffer exists yet.
                # This becomes meaningful in milestone 6.
            }
            default {
                error "invalid erase-in-display mode: $mode"
            }
        }

        set wrapPending 0
    }

    
    method eraseCharacters {{count 1}} {
        set count [my normalizeCount $count]

        set last [expr {
            min($cols - 1, $cursorCol + $count - 1)
        }]

        my eraseRange $cursorRow $cursorCol $last
        set wrapPending 0
    }


method insertCharacters {{count 1}} {
    set count [my normalizeCount $count]
    set count [expr {min($count, $cols - $cursorCol)}]

    # Inserting inside a continuation cell would
    # split the existing wide glyph.
    set current [my cell $cursorRow $cursorCol]

    if {[dict get $current width] == 0} {
        my clearGlyphAt $cursorRow $cursorCol
    }

    set line [lindex $grid $cursorRow]

    set prefix [lrange $line 0 [expr {$cursorCol - 1}]]
    set suffix [lrange $line $cursorCol end]

    set blanks {}
    for {set i 0} {$i < $count} {incr i} {
        lappend blanks [my blankCell]
    }

    set newLine [concat $prefix $blanks $suffix]
    set newLine [lrange $newLine 0 [expr {$cols - 1}]]

    lset grid $cursorRow $newLine

    my repairRow $cursorRow
    my markDirty $cursorRow $cursorCol [expr {$cols - 1}]

    set wrapPending 0
}


method deleteCharacters {{count 1}} {
    set count [my normalizeCount $count]
    set count [expr {min($count, $cols - $cursorCol)}]

    set line [lindex $grid $cursorRow]

    set prefix [lrange $line 0 [expr {$cursorCol - 1}]]
    set suffix [lrange $line [expr {$cursorCol + $count}] end]

    set blanks {}
    for {set i 0} {$i < $count} {incr i} {
        lappend blanks [my blankCell]
    }

    lset grid $cursorRow [concat $prefix $suffix $blanks]

    my repairRow $cursorRow
    my markDirty $cursorRow $cursorCol [expr {$cols - 1}]

    set wrapPending 0
}

    method insertLines {{count 1}} {
        set count [my normalizeCount $count]

        # IL has no effect outside the scroll region.
        if {$cursorRow < $scrollTop ||
            $cursorRow > $scrollBottom} {
            set wrapPending 0
            return
        }

        for {set r $cursorRow} {$r <= $scrollBottom} {incr r} {
            my markRowDirty $r
}

        set count [expr {
            min($count, $scrollBottom - $cursorRow + 1)
        }]

        for {set i 0} {$i < $count} {incr i} {
            # Remove bottom row of affected region.
            set grid [lreplace \
                $grid $scrollBottom $scrollBottom]

            # Insert blank row at cursor.
            set grid [linsert \
                $grid $cursorRow [my blankRow]]
        }

        set cursorCol 0
        set wrapPending 0
    }

    
    method deleteLines {{count 1}} {
        set count [my normalizeCount $count]

        if {$cursorRow < $scrollTop ||
            $cursorRow > $scrollBottom} {
            set wrapPending 0
            return
        }

        for {set r $cursorRow} {$r <= $scrollBottom} {incr r} {
            my markRowDirty $r
        }

        set count [expr {
            min($count, $scrollBottom - $cursorRow + 1)
        }]

        for {set i 0} {$i < $count} {incr i} {
            # Remove current row.
            set grid [lreplace \
                $grid $cursorRow $cursorRow]

            # Add blank row at bottom margin.
            set grid [linsert \
                $grid $scrollBottom [my blankRow]]
        }

        set cursorCol 0
        set wrapPending 0
    }



}
