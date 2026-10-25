
namespace eval ::LATerm {}

oo::class create ::LATerm::KeyboardEncoder {
    variable screen

    constructor {screenObject} {
        set screen $screenObject
    }

    method encode {keysym character {shift 0} {alt 0} {ctrl 0}} {
        set shift [expr {$shift ? 1 : 0}]
        set alt   [expr {$alt ? 1 : 0}]
        set ctrl  [expr {$ctrl ? 1 : 0}]

        set modifier [expr {1 + $shift + 2*$alt + 4*$ctrl}]
        set esc "\033"

        # Cursor keys and Home/End.
        set cursorCodes [dict create \
            Up A Down B Right C Left D \
            Home H End F]

        if {[dict exists $cursorCodes $keysym]} {
            set code [dict get $cursorCodes $keysym]

            if {$modifier != 1} {
                return "${esc}\[1;${modifier}${code}"
            }

            if {[$screen applicationCursorKeys]} {
                return "${esc}O${code}"
            }

            return "${esc}\[${code}"
        }

        # Editing/navigation keys use CSI ~ sequences.
        set tildeCodes [dict create \
            Insert 2 Delete 3 \
            Prior 5 Next 6 \
            F5 15 F6 17 F7 18 F8 19 \
            F9 20 F10 21 F11 23 F12 24]

        if {[dict exists $tildeCodes $keysym]} {
            set code [dict get $tildeCodes $keysym]

            if {$modifier == 1} {
                return "${esc}\[${code}~"
            }

            return "${esc}\[${code};${modifier}~"
        }

        # F1-F4 use SS3 without modifiers.
        set functionCodes [dict create \
            F1 P F2 Q F3 R F4 S]

        if {[dict exists $functionCodes $keysym]} {
            set code [dict get $functionCodes $keysym]

            if {$modifier == 1} {
                return "${esc}O${code}"
            }

            return "${esc}\[1;${modifier}${code}"
        }

        # Special character keys.
        switch -- $keysym {
            Return -
            KP_Enter {
                set output "\r"
            }
            Tab {
                set output "\t"
            }
            ISO_Left_Tab {
                set output "\033\[Z"
            }
            BackSpace {
                set output "\177"
            }
            Escape {
                set output "\033"
            }
            space {
                set output " "
            }
            default {
                set output $character
            }
        }

        # Ctrl + alphabetic character produces a C0 control.
        if {$ctrl && [regexp -nocase {^[a-z]$} $keysym]} {
            scan [string toupper $keysym] %c code
            set output [format %c [expr {$code - 64}]]
        } elseif {$ctrl} {
            # Additional common control-key combinations.
            switch -- $keysym {
                bracketleft { set output "\033" }
                backslash   { set output "\034" }
                bracketright { set output "\035" }
                asciicircum { set output "\036" }
                underscore  { set output "\037" }
                space       { set output "\000" }
            }
        }

        if {$output eq ""} {
            return ""
        }

        # Meta/Alt prefix for ordinary character input.
        if {$alt} {
            set output "${esc}${output}"
        }

        return $output
    }
}
