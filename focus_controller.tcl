
namespace eval ::LATerm {}

oo::class create ::LATerm::FocusController {
    variable screen writer focused

    # screenObject supplies the terminal's focus-reporting mode.
    # writeCallback is a command prefix accepting one byte-string argument.
    constructor {screenObject writeCallback} {
        set screen $screenObject
        set writer $writeCallback
        set focused -1
    }

    # Send a DEC focus-in/out report when enabled. hasFocus is a
    # boolean-like value; duplicate state transitions are suppressed.
    # Returns no value. Local focus state is tracked even while reporting
    # is disabled so enabling the mode does not replay a stale transition.
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
