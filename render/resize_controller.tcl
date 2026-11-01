
namespace eval ::LATerm {}

oo::class create ::LATerm::ResizeController {
    variable widget screen ptyChannel
    variable cellWidth cellHeight
    variable lastRows lastCols
    variable pending

    # terminalWidget is the resizable Tk terminal widget; screenObject is
    # the Screen model; channel is the PTY channel to resize when dimensions
    # change. Types: widget path, TclOO object command, and channel name.
    constructor {terminalWidget screenObject channel} {
        set widget $terminalWidget
        set screen $screenObject
        set ptyChannel $channel

        set fontName [$widget cget -font]

        set cellWidth [font measure $fontName "M"]
        set cellHeight [font metrics $fontName -linespace]

        if {$cellWidth <= 0 || $cellHeight <= 0} {
            error "invalid terminal font metrics"
        }

        set lastRows 0
        set lastCols 0
        set pending ""
        
        bind $widget <Configure> [list [self] scheduleResize]
    }

    # Debounce Configure events so a burst of geometry changes results
    # in one resize after 50 ms. Tk callback; takes no arguments.
    method scheduleResize {} {
        if {$pending ne ""} {
            after cancel $pending
        }

        set pending [after 50 [list [self] applyResize]]
    }

    # Recompute rows/columns from widget pixels and font cell metrics,
    # then update the model and PTY only when dimensions have changed.
    # Tk after callback; takes no arguments.
    method applyResize {} {
        set pending ""

        if {![winfo exists $widget]} {
            return
        }

        set width [winfo width $widget]
        set height [winfo height $widget]

        set cols [expr {max(1, $width / $cellWidth)}]
        set rows [expr {max(1, $height / $cellHeight)}]

        if {$rows == $lastRows && $cols == $lastCols} {
            return
        }

        $screen resize $rows $cols

        if {[lsearch -exact [chan names] $ptyChannel] >= 0} {
            pty::resize $ptyChannel $rows $cols
        }

        set lastRows $rows
        set lastCols $cols
    }

    destructor {
        if {$pending ne ""} {
            after cancel $pending
        }

        if {[winfo exists $widget]} {
            bind $widget <Configure> {}
        }
    }
}
