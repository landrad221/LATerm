
package require Tk

namespace eval ::LATerm {}

oo::class create ::LATerm::TkRenderer {
    variable widget screen
    variable styleCache styleCount fontCache
    variable renderedRows renderedCols
    variable renderedRowCells
    variable cursorOverlay
    variable profile

    # textWidget is a Tk Text widget displaying the terminal; screenObject
    # is the Screen model supplying dimensions, cells, cursor and dirtiness.
    # The renderer configures the widget and performs its initial redraw.
    constructor {textWidget screenObject} {
        set widget $textWidget
        set screen $screenObject
        set styleCache {}
        set styleCount 0
        set fontCache {}
        set renderedRows -1
        set renderedCols -1
        set renderedRowCells {}
        set cursorOverlay ""
        set profile [dict create \
                    fullRedraws 0 \
                    dirtyRenders 0 \
                    styledRows 0 \
                    styleRuns 0 \
                    cellReplacements 0 \
                    buildUs 0 \
                    tkUs 0 \
                    maxRowUs 0]

        $widget configure \
            -wrap none \
            -undo 0 \
            -autoseparators 0 \
            -state disabled
        $widget tag configure latermCursor \
            -foreground [$widget cget -background] \
            -background [$widget cget -foreground]
        # Perform an initial full redraw.
        my render
    }
    

    # Register an optional cursor overlay object. It must implement
    # updatePosition; an empty value restores the Text-tag cursor.
    method setCursorOverlay {overlayObject} {
        if {$overlayObject ne ""} {
            $widget tag remove latermCursor 1.0 end
        }
        set cursorOverlay $overlayObject
    }

    # Convert one zero-based screen row into its displayed Tcl string.
    # Continuation cells for wide glyphs are omitted because the leading
    # cell already contains the full character.
    method rowText {row} {
        lassign [$screen dimensions] rows cols
        set output ""

        for {set col 0} {$col < $cols} {incr col} {
            set cell [$screen cell $row $col]

            # Skip wide-character continuation cells.
            if {[dict get $cell width] == 0} {
                continue
            }

            append output [dict get $cell text]
        }

        return $output
    }

    # Convert a zero-based terminal column to a zero-based Tk character
    # offset within row. Wide glyphs contribute Tcl string length, not
    # terminal-cell width, because Tk indexes characters rather than cells.
    method columnToIndex {row column} {
        lassign [$screen dimensions] rows cols

        set index 0

        for {set col 0} {$col < $column && $col < $cols} {incr col} {
            set cell [$screen cell $row $col]

            if {[dict get $cell width] == 0} {
                continue
            }

            incr index [string length [dict get $cell text]]
        }

        return $index
    }

    # Replace a zero-based screen row with its plain text representation.
    # row is an integer screen row; this helper does not apply style tags.
    method renderRow {row} {
        set line [expr {$row + 1}]
        set text [my rowText $row]

        $widget configure -state normal

        $widget delete "$line.0" "$line.end"
        $widget insert "$line.0" $text

        $widget configure -state disabled
    }

    # Rebuild all Text lines and styled runs after initial display or a
    # dimension change. Also consumes accumulated dirty state.
    method render {} {

        lassign [$screen dimensions] rows cols
        dict incr profile fullRedraws

        # Rebuild the required number of Text lines.
        set lines [lrepeat $rows ""]
        set renderedRowCells {}

        $widget configure -state normal
        $widget delete 1.0 end
        $widget insert 1.0 [join $lines "\n"]
    
        try {
            for {set row 0} {$row < $rows} {incr row} {
                my renderStyledRow $row
            }
        } finally {
            $widget configure -state disabled
        }

        set renderedRows $rows
        set renderedCols $cols

        $screen consumeDirty
        my updateCursor

        $widget tag raise sel

        if {$cursorOverlay ne ""} {
            $cursorOverlay updatePosition
        } else {
            $widget tag raise latermCursor
        }
    }


    # Render only dirty rows and cursor changes. A size mismatch falls back
    # to render(); dirty metadata is consumed before drawing to avoid
    # replaying stale changes on the next event-loop turn.
    method renderDirty {} {
        lassign [$screen dimensions] rows cols
        dict incr profile dirtyRenders

        # Resizing requires a full redraw.
        if {$rows != $renderedRows || $cols != $renderedCols} {
            my render
            return
        }

        set changes [$screen consumeDirty]
        set dirtyRows [dict get $changes rows]
        set dirtyCount [dict size $dirtyRows]
        set cursorChanged [dict get $changes cursor]

        if {$dirtyCount == 0 && !$cursorChanged} {
            return
        }

        if {$dirtyCount > 0} {
            $widget configure -state normal

            try {
                foreach row [lsort -integer [dict keys $dirtyRows]] {
                    if {![my replaceDirtyCell \
                        $row [dict get $dirtyRows $row]]} {
                        my renderStyledRow $row
                    }
                }
            } finally {
                $widget configure -state disabled
            }
        }

        if {$cursorChanged || $dirtyCount > 0} {
            my updateCursor
        }

        if {$cursorOverlay ne ""} {
            $cursorOverlay updatePosition
        }

        $widget tag raise sel

        if {$cursorOverlay eq ""} {
            $widget tag raise latermCursor
        }

    }


    # Synchronize Tk's insertion mark and block-tag cursor with Screen.
    # A cursor on a wide-character continuation cell is snapped to its
    # leading cell so the rendered index remains valid.
    method updateCursor {} {
        if {$cursorOverlay ne ""} {
            return
        }

        # Remove the previous cursor highlight.
        $widget tag remove latermCursor 1.0 end

        if {![$screen cursorVisible]} {
            return
        }

        lassign [$screen cursor] row col
        lassign [$screen dimensions] rows cols

        if {$row < 0 || $row >= $rows ||
            $col < 0 || $col >= $cols} {
            return
        }

        set cell [$screen cell $row $col]

        # Handle wide-character continuation cells.
        if {[dict get $cell width] == 0 && $col > 0} {
            incr col -1
        }

        set line [expr {$row + 1}]
        set index [my columnToIndex $row $col]

        set start "$line.$index"
        set end "$line.[expr {$index + 1}]"

        # Keep the Tk insertion mark synchronized.
        $widget mark set insert $start
        $widget see $start

        # Draw the legacy block cursor only when
        # no overlay is registered.
        if {$cursorOverlay eq ""} {
            $widget tag add latermCursor $start $end
            $widget tag raise latermCursor
        }
    }

    # Return the Tk tag for a cell-attribute dictionary. attributes must
    # contain fg/bg color strings (or "default") and boolean-like bold,
    # italic, underline, and inverse values. Tags and font variants are
    # cached so repeated cells with the same style do not recreate Tk state.
    method styleTag {attributes} {
        # Normalize attributes into a stable cache key; visual defaults
        # and inverse colors are resolved only when creating the tag.
        set key [list \
            [dict get $attributes fg] \
            [dict get $attributes bg] \
            [dict get $attributes bold] \
            [dict get $attributes italic] \
            [dict get $attributes underline] \
            [dict get $attributes inverse]]

        if {[dict exists $styleCache $key]} {
            return [dict get $styleCache $key]
        }

        set fg [dict get $attributes fg]
        set bg [dict get $attributes bg]

        if {$fg eq "default"} {
            set fg [$widget cget -foreground]
        }
        if {$bg eq "default"} {
            set bg [$widget cget -background]
        }

        if {[dict get $attributes inverse]} {
            set tmp $fg
            set fg $bg
            set bg $tmp
        }

        set bold [dict get $attributes bold]
        set italic [dict get $attributes italic]

        set fontKey [list $bold $italic]

        if {![dict exists $fontCache $fontKey]} {
            set base [$widget cget -font]

            set fontName "latermFont_[string map {: _} [self]]_${bold}_${italic}"

            font create $fontName \
                -family [font actual $base -family] \
                -size [font actual $base -size] \
                -weight [expr {$bold ? "bold" : "normal"}] \
                -slant [expr {$italic ? "italic" : "roman"}]

            dict set fontCache $fontKey $fontName
        }

        set fontName [dict get $fontCache $fontKey]

        set tag "latermStyle[incr styleCount]"

        $widget tag configure $tag \
            -foreground $fg \
            -background $bg \
            -font $fontName \
            -underline [dict get $attributes underline]

        dict set styleCache $key $tag

        return $tag
    }



    # row is a zero-based screen row and ranges is its inclusive dirty-range
    # list. Replace a single cell directly only when old/new geometry and
    # style match; this avoids retagging all 80 cells for common updates.
    method replaceDirtyCell {row ranges} {
        if {[llength $ranges] != 1 ||
            [lindex [lindex $ranges 0] 0] !=
            [lindex [lindex $ranges 0] 1] ||
            ![dict exists $renderedRowCells $row]} {
            return 0
        }

        set col [lindex [lindex $ranges 0] 0]
        set cell [$screen cell $row $col]
        set text [dict get $cell text]

        if {[dict get $cell width] != 1 ||
            [string length $text] != 1} {
            return 0
        }

        lassign [lindex [dict get $renderedRowCells $row] $col] \
            oldWidth oldLength oldStyle index
        if {$oldWidth != 1 || $oldLength != 1} {
            return 0
        }

        set style [my styleTag $cell]
        if {$style ne $oldStyle} {
            return 0
        }

        set line [expr {$row + 1}]
        $widget replace "$line.$index" "$line.[expr {$index + 1}]" $text
        dict incr profile cellReplacements
        return 1
    }

    # Rebuild one zero-based row as contiguous style runs. Rows with one
    # style use a plain insert plus one tag range; varied rows pass the
    # text/tag pairs to Tk in one insert command to reduce widget dispatch.
    method renderStyledRow {row} {
        lassign [$screen dimensions] rows cols
        set line [expr {$row + 1}]
        set rowStart [clock microseconds]

        set output ""
        set previousStyle ""
        set runStart 0
        set textOffset 0
        set runs {}
        set rowMetadata {}

        for {set col 0} {$col < $cols} {incr col} {
            set cell [$screen cell $row $col]
            set width [dict get $cell width]
            if {$width == 0} {
                lappend rowMetadata [list 0 0 "" $textOffset]
                continue
            }

            set style [my styleTag $cell]
            set char [dict get $cell text]
            lappend rowMetadata \
                [list $width [string length $char] $style $textOffset]

            if {$previousStyle ne "" && $style ne $previousStyle} {
                lappend runs [list $runStart $textOffset $previousStyle]
                set runStart $textOffset
            }

            append output $char
            incr textOffset [string length $char]
            set previousStyle $style
        }

        if {$previousStyle ne ""} {
            lappend runs [list $runStart $textOffset $previousStyle]
        }

        set runCount [llength $runs]
        set buildEnd [clock microseconds]
        $widget delete "$line.0" "$line.end"

        if {$runCount == 1} {
            set tag [lindex [lindex $runs 0] 2]
            $widget insert "$line.0" $output
            $widget tag add $tag "$line.0" "$line.end"
        } elseif {$runCount > 1} {
            set segments {}
            foreach run $runs {
                lassign $run start end tag
                lappend segments \
                    [string range $output $start [expr {$end - 1}]] \
                    [list $tag]
            }
            $widget insert "$line.0" {*}$segments
        }

        set rowEnd [clock microseconds]

        dict incr profile styledRows
        dict incr profile styleRuns $runCount
        dict incr profile buildUs [expr {$buildEnd - $rowStart}]
        dict incr profile tkUs [expr {$rowEnd - $buildEnd}]
        dict set renderedRowCells $row $rowMetadata

        set rowUs [expr {$rowEnd - $rowStart}]

        if {$rowUs > [dict get $profile maxRowUs]} {
            dict set profile maxRowUs $rowUs
        }
    }

    # Return the Tk Text index for the current cursor as "line.column".
    # Tk line numbers are one-based; the character column is zero-based.
    method cursorIndex {} {
        lassign [$screen cursor] row col

        set cell [$screen cell $row $col]

        if {[dict get $cell width] == 0 && $col > 0} {
            incr col -1
        }

        set index [my columnToIndex $row $col]

        return "[expr {$row + 1}].$index"
    }

    # Return profiling counters and accumulated microsecond timings as a
    # dictionary. Values remain cumulative until resetStatistics is called.
    method statistics {} {
        return $profile
    }

    # Clear render/profile counters without changing the displayed screen.
    method resetStatistics {} {
        set profile [dict create \
            fullRedraws 0 \
            dirtyRenders 0 \
            styledRows 0 \
            styleRuns 0 \
            cellReplacements 0 \
            buildUs 0 \
            tkUs 0 \
            maxRowUs 0]
    }


# Delete fonts created by this renderer when the object is destroyed.
destructor {
    dict for {key fontName} $fontCache {
        catch {font delete $fontName}
    }
}

}
