
namespace eval ::LATerm {}

oo::class create ::LATerm::ClipboardController {
    variable screen writer

    constructor {screenObject writerObject} {
        set screen $screenObject
        set writer $writerObject
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

    method paste {widget} {
        if {[catch {
            clipboard get -displayof $widget
        } text]} {
            puts stderr "LATerm: clipboard unavailable: $text"
            return
        }

        set bytes [my encodePaste $text]

        if {$bytes eq ""} {
            return
        }

        if {[catch {
            $writer send $bytes
        } err]} {
            puts stderr "LATerm: PTY paste error: $err"
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
