package require Tk 8.6

set nativeLibrary [file join [file dirname [info script]] \
    liblaterm_renderer[info sharedlibextension]]
load $nativeLibrary Laterm_renderer

namespace eval ::LATerm {}

oo::class create ::LATerm::NativeRenderer {
    variable widgetPath fontNames screen blinkTimer blinkEnabled blinkVisible

    constructor {path screenObject {baseFont TkFixedFont}
            {foreground "#e5e7eb"} {background "#111827"}} {
        set screen $screenObject
        set blinkTimer ""
        set blinkEnabled 0
        set blinkVisible 1
        set fontNames {}
        set widgetPath [::LATerm::native::create $path $screenObject]
        my configureAppearance [dict create \
            fontFamily [font actual $baseFont -family] \
            fontSize [font actual $baseFont -size] \
            foreground $foreground \
            background $background]
        my syncCursorBlink
    }

    method widget {} {
        return $widgetPath
    }

    method render {} {
        $widgetPath render
        my syncCursorBlink
    }

    method renderDirty {} {
        $widgetPath renderDirty
        my syncCursorBlink
    }

    method updateCursor {} {
        $widgetPath updateCursor
        my syncCursorBlink
    }

    method cellSize {} {
        return [$widgetPath cellSize]
    }

    method configureAppearance {settings} {
        set family [dict get $settings fontFamily]
        set size [dict get $settings fontSize]
        set foreground [dict get $settings foreground]
        set background [dict get $settings background]
        set newFontNames {}

        try {
            foreach {weight slant} {
                bold roman
                normal italic
                bold italic
            } {
                lappend newFontNames [font create \
                    -family $family \
                    -size $size \
                    -weight $weight \
                    -slant $slant]
            }

            $widgetPath configure \
                -font [list $family $size] \
                -boldfont [lindex $newFontNames 0] \
                -italicfont [lindex $newFontNames 1] \
                -bolditalicfont [lindex $newFontNames 2] \
                -foreground $foreground \
                -background $background
        } on error {message options} {
            foreach fontName $newFontNames {
                font delete $fontName
            }
            return -options $options $message
        }

        set oldFontNames $fontNames
        set fontNames $newFontNames
        foreach fontName $oldFontNames {
            font delete $fontName
        }
        $widgetPath render
    }

    method window {} {
        return $widgetPath
    }

    method setSelection {startRow startCol endRow endCol} {
        $widgetPath selection set $startRow $startCol $endRow $endCol
    }

    method selectionText {} {
        return [$widgetPath selection text]
    }

    method syncCursorBlink {} {
        set shouldBlink [$screen cursorBlinking]
        if {$shouldBlink == $blinkEnabled} {
            return
        }

        set blinkEnabled $shouldBlink
        set blinkVisible 1
        $widgetPath cursorBlink 1

        if {$blinkTimer ne ""} {
            after cancel $blinkTimer
            set blinkTimer ""
        }
        if {$blinkEnabled} {
            set blinkTimer [after 600 [list [self] toggleCursorBlink]]
        }
    }

    method toggleCursorBlink {} {
        set blinkTimer ""
        if {!$blinkEnabled} {
            return
        }

        set blinkVisible [expr {!$blinkVisible}]
        $widgetPath cursorBlink $blinkVisible
        set blinkTimer [after 600 [list [self] toggleCursorBlink]]
    }

    method statistics {} {
        return [$widgetPath statistics]
    }

    method resetStatistics {} {
        $widgetPath resetStatistics
    }

    destructor {
        if {$blinkTimer ne ""} {
            after cancel $blinkTimer
        }
        if {[winfo exists $widgetPath]} {
            destroy $widgetPath
        }
        foreach fontName $fontNames {
            font delete $fontName
        }
    }
}

package provide laterm_native_renderer 0.1
