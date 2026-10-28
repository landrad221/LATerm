
package require Tk

namespace eval ::laterm {}

oo::class create ::laterm::TkRenderer {
    variable widget screen
    variable styleCache styleCount fontCache
    variable renderedRows renderedCols
    variable cursorOverlay

    constructor {textWidget screenObject} {
        set widget $textWidget
        set screen $screenObject
        set styleCache {}
        set styleCount 0
        set fontCache {}
        set renderedRows -1
        set renderedCols -1
        set cursorOverlay ""

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
    

    method setCursorOverlay {overlayObject} {
        set cursorOverlay $overlayObject
    }

    # Convert one logical screen row into Tk text.
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

    # Convert a terminal column into a Tk character index.
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

    # Replace a single row in the Text widget.
    method renderRow {row} {
        set line [expr {$row + 1}]
        set text [my rowText $row]

        $widget configure -state normal

        $widget delete "$line.0" "$line.end"
        $widget insert "$line.0" $text

        $widget configure -state disabled
    }

    # Full-screen redraw.
    
method render {} {
    lassign [$screen dimensions] rows cols

    # Rebuild the required number of Text lines.
    set lines [lrepeat $rows ""]

    $widget configure -state normal
    $widget delete 1.0 end
    $widget insert 1.0 [join $lines "\n"]
    $widget configure -state disabled

    for {set row 0} {$row < $rows} {incr row} {
        my renderStyledRow $row
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


method renderDirty {} {
    lassign [$screen dimensions] rows cols

    # Resizing requires a full redraw.
    if {$rows != $renderedRows || $cols != $renderedCols} {
        my render
        return
    }

    set changes [$screen consumeDirty]
    set dirtyRows [dict get $changes rows]

    foreach row [lsort -integer [dict keys $dirtyRows]] {
        my renderStyledRow $row
    }

    if {[dict get $changes cursor] ||
        [dict size $dirtyRows] > 0} {
        my updateCursor
    }

    # Update the overlay after text and cursor positioning.
    if {$cursorOverlay ne ""} {
        $cursorOverlay updatePosition
    }

    $widget tag raise sel

    if {$cursorOverlay eq ""} {
        $widget tag raise latermCursor
    }
}


method updateCursor {} {
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

method styleTag {attributes} {
    # Normalize the attributes into a stable cache key.
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

method renderStyledRow {row} {
    lassign [$screen dimensions] rows cols

    set line [expr {$row + 1}]

    $widget configure -state normal
    $widget delete "$line.0" "$line.end"

    set output ""
    set previousStyle ""
    set runStart 0
    set textOffset 0
    set runs {}

    for {set col 0} {$col < $cols} {incr col} {
        set cell [$screen cell $row $col]

        if {[dict get $cell width] == 0} {
            continue
        }

        set style [my styleTag $cell]
        set char [dict get $cell text]

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

    $widget insert "$line.0" $output

    foreach run $runs {
        lassign $run start end tag

        $widget tag add $tag \
            "$line.$start" "$line.$end"
    }

    $widget configure -state disabled
}

method cursorIndex {} {
    lassign [$screen cursor] row col

    set cell [$screen cell $row $col]

    if {[dict get $cell width] == 0 && $col > 0} {
        incr col -1
    }

    set index [my columnToIndex $row $col]

    return "[expr {$row + 1}].$index"
}

destructor {
    dict for {key fontName} $fontCache {
        catch {font delete $fontName}
    }
}

}

