
namespace eval ::LATerm {}

oo::class create ::LATerm::ClipboardController {
    variable screen

    constructor {screenObject} {
        set screen $screenObject
    }

    method encodePaste {text} {
        if {$text eq ""} {
            return ""
        }

        if {[$screen bracketedPaste]} {
            set text "\033\[200~${text}\033\[201~"
        }

        return [encoding convertto utf-8 $text]
    }

    method paste {widget channel} {
        if {[catch {
            clipboard get -displayof $widget
        } text]} {
            # Clipboard is empty or unavailable.
            return
        }

        set bytes [my encodePaste $text]

        if {$bytes eq ""} {
            return
        }

        if {[catch {
            puts -nonewline $channel $bytes
            flush $channel
        } err]} {
            puts stderr "Clipboard paste error: $err"
        }
    }

    method copySelection {widget} {
        if {[catch {
            $widget get sel.first sel.last
        } text]} {
            return
        }

        if {$text eq ""} {
            return
        }

        clipboard clear -displayof $widget
        clipboard append -displayof $widget -- $text
    }
}
