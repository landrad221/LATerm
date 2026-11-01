
namespace eval ::LATerm {}

oo::class create ::LATerm::ClipboardController {
    variable screen writer

    # screenObject supplies bracketed-paste mode; writerObject accepts
    # PTY bytes through its send method. Both are TclOO object commands.
    constructor {screenObject writerObject} {
        set screen $screenObject
        set writer $writerObject
    }

    # Prepare clipboard text for the PTY. text is a Tcl string; bracketed
    # paste delimiters are included when the screen has enabled that mode.
    # Returns UTF-8 encoded bytes, or "" for empty text.
    method encodePaste {text} {
        if {$text eq ""} {
            return ""
        }

        if {[$screen bracketedPaste]} {
            set text "\033\[200~${text}\033\[201~"
        }

        return [encoding convertto utf-8 $text]
    }

    # Read the Tk clipboard associated with widget and queue it for PTY
    # input. widget is a Tk widget path. Clipboard or write errors are
    # reported to stderr; this event-handler method returns no value.
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
}
