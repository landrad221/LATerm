
namespace eval ::LATerm {}

oo::class create ::LATerm::FocusController {
    variable screen writer focused

    constructor {screenObject writeCallback} {
        set screen $screenObject
        set writer $writeCallback
        set focused -1
    }

    method send {hasFocus} {
        set hasFocus [expr {$hasFocus ? 1 : 0}]

        # Avoid duplicate focus notifications.
        if {$focused == $hasFocus} {
            return
        }

        set focused $hasFocus

        if {![$screen focusReporting]} {
            return
        }

        if {$hasFocus} {
            set sequence "\033\[I"
        } else {
            set sequence "\033\[O"
        }

        {*}$writer $sequence
    }
}
