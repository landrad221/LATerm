
namespace eval ::LATerm {}

oo::class create ::LATerm::CursorOverlay {
    variable canvas screen textWidget
    variable cursorColor
    variable blinkVisible blinkTimer
    variable renderer

    # canvasWidget is a Canvas path used as the cursor overlay;
    # textWidgetPath is the rendered Text widget; rendererObject provides
    # cursorIndex; screenObject provides cursor visibility/style state.
    # color is a Tk color string used as the overlay background.
    constructor {canvasWidget textWidgetPath rendererObject screenObject {color "#1D4ED8"}} {
        set canvas $canvasWidget
        set textWidget $textWidgetPath
        set screen $screenObject
        set cursorColor $color
        set renderer $rendererObject
        set blinkVisible 1
        set blinkTimer ""

        $canvas configure -highlightthickness 0 \
            -borderwidth 0 -background $color

        # Transparent Canvas widgets are not portable in Tk.
        # This overlay should be positioned over the cursor cell only,
        # not across the entire Text widget.
        place forget $canvas
    }

    destructor {
        if {$blinkTimer ne ""} {
            after cancel $blinkTimer
        }
        place forget $canvas
    }

    # Restart blinking from the visible phase and draw at the current cell.
    # No arguments or return value.
    method refresh {} {
        if {$blinkTimer ne ""} {
            after cancel $blinkTimer
            set blinkTimer ""
        }

        set blinkVisible 1
        my draw

        if {[$screen cursorBlinking]} {
            set blinkTimer [after 600 [list [self] blink]]
        }
    }
    # Reposition the overlay after text layout or cursor movement changes.
    # No arguments or return value.
    method updatePosition {} {
       my draw
    }

    # Advance one blink phase and schedule the next timer when appropriate.
    # Invoked by Tk's after callback; no arguments or return value.
    method blink {} {
        set blinkTimer ""
        
        if {![$screen cursorVisible]} {
            place forget $canvas
            return
         }

        if {![$screen cursorBlinking]} {
            set blinkVisible 1
            my draw
            return
        }

        set blinkVisible [expr {!$blinkVisible}]
        my draw

        set blinkTimer [after 600 [list [self] blink]]
    }

    # Place and size the overlay according to the screen cursor shape.
    # If the cursor is hidden or has no visible Text bounding box, hide it.
    # No arguments or return value.
    method draw {} {

         if {![$screen cursorVisible] || !$blinkVisible} {
            place forget $canvas
            return
        }

        lassign [$screen cursor] row col

        set index [$renderer cursorIndex]
        set index [$renderer cursorIndex]
        set bbox [$textWidget bbox $index]

        if {$bbox eq ""} {
            place forget $canvas
            return
        }

        lassign $bbox x y width height

        switch -- [$screen cursorShape] {
            block {
                set cursorWidth $width
                set cursorHeight $height
            }
            underline {
                set cursorWidth $width
                set cursorHeight 3
                set y [expr {$y + $height - 3}]
            }
            bar {
                set cursorWidth 2
                set cursorHeight $height
            }
        }

        place $canvas \
            -in $textWidget \
            -x $x -y $y \
            -width $cursorWidth \
            -height $cursorHeight
        raise $canvas
    }
    
}
