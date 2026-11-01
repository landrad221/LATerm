package require Tk

lappend auto_path [file dirname [info script]]
package require pty

source parser.tcl
source render/resize_controller.tcl
source render/screen.tcl
source render/tk_renderer.tcl
source render/screen_adapter.tcl
source keyboard_encoder.tcl
source clipboard_controller.tcl
source render/mouse_encoder.tcl
source render/mouse_controller.tcl
source focus_controller.tcl
source cursor_overlay.tcl
source pty_writer.tcl

lappend auto_path [file join [file dirname [file normalize [info script]]] render native]

namespace eval ::LATerm {}

oo::class create ::LATerm::Application {
    # Owns the Tk widgets, terminal model, PTY channel/child process,
    # controllers, and every event-loop callback that references them.
    # Keeping those resources together makes shutdown cancel callbacks
    # before destroying the window or channel.
    variable terminal cursorCanvas
    variable ptyChannel ptyFile pid
    variable writer screen adapter parser renderer keyboard clipboard
    variable rendererBackend selectionAnchor
    variable mouseEncoder mouseController focusController cursorOverlay
    variable resizeController
    variable shuttingDown childReaped ptyClosed shutdownAttempts
    variable childMonitorTimer shutdownTimer ptyResumeTimer
    variable ptyReadBudget renderTimer renderInterval
    variable renderScheduled renderExecuted
    variable heartbeatTimer heartbeatLast heartbeatMaxDelay
    variable pipelineStats

    # Initialize lifecycle flags/statistics, then build and start LATerm.
    constructor {} {
        set rendererBackend text
        if {[info exists ::env(LATerm_RENDERER)]} {
            set rendererBackend [string tolower $::env(LATerm_RENDERER)]
        }
        if {$rendererBackend ni {text native}} {
            error "unsupported LATerm_RENDERER \"$rendererBackend\" (expected text or native)"
        }

        set terminal .terminal
        set cursorCanvas .cursorOverlay
        set selectionAnchor ""

        set pid ""
        set shuttingDown 0
        set childReaped 0
        set ptyClosed 0
        set shutdownAttempts 0
        set childMonitorTimer ""
        set shutdownTimer ""
        set ptyResumeTimer ""
        set ptyReadBudget 1024
        set renderTimer ""
        set renderInterval 16
        set renderScheduled 0
        set renderExecuted 0
        set heartbeatTimer ""
        set heartbeatLast [clock milliseconds]
        set heartbeatMaxDelay 0
        set pipelineStats [dict create \
            reads 0 \
            bytes 0 \
            parseUs 0 \
            renderUs 0 \
            maxParseUs 0 \
            maxRenderUs 0]

        my initialize
    }

    # Create widgets and terminal components, attach callbacks, and spawn
    # the interactive shell. PTY data is handled asynchronously by
    # readPty; the read budget limits work per event-loop callback.
    method initialize {} {
        lassign [pty::open] ptyChannel ptyFile
        set writer [::LATerm::PtyWriter new \
            $ptyChannel 1048576 [list [self] onPtyWriterFailure]]
        set screen [::LATerm::Screen new 24 80]
        set adapter [::LATerm::ScreenAdapter new \
            $screen [list $writer send]]
        set parser [::LATerm::Parser new [list $adapter event]]

        if {$rendererBackend eq "native"} {
            text $terminal
            set defaultForeground [$terminal cget -foreground]
            set defaultBackground [$terminal cget -background]
            destroy $terminal
            package require laterm_native_renderer
            set renderer [::LATerm::NativeRenderer new \
                $terminal $screen TkFixedFont \
                $defaultForeground $defaultBackground]
            set terminal [$renderer widget]
        } else {
            set cursorCanvas [canvas $cursorCanvas]
            text $terminal
            set renderer [::LATerm::TkRenderer new $terminal $screen]
        }

        set keyboard [::LATerm::KeyboardEncoder new $screen]
        set clipboard [::LATerm::ClipboardController new $screen $writer]
        set mouseEncoder [::LATerm::MouseEncoder new $screen]
        set focusController [::LATerm::FocusController new \
            $screen [list $writer send]]
        set mouseController [::LATerm::MouseController new \
            $terminal $screen $mouseEncoder $writer \
            [expr {$rendererBackend eq "native" ? [$renderer cellSize] : ""}]]
        if {$rendererBackend eq "text"} {
            set cursorOverlay [::LATerm::CursorOverlay new \
                $cursorCanvas $terminal $renderer $screen]
            $renderer setCursorOverlay $cursorOverlay
            $renderer updateCursor
            $cursorOverlay refresh
        } else {
            set cursorOverlay ""
        }

        set heartbeatLast [clock milliseconds]
        set heartbeatTimer [after 100 [list [self] pipelineHeartbeat]]

        fconfigure $ptyChannel \
            -translation binary \
            -blocking no \
            -buffering none \
            -encoding binary
        fileevent $ptyChannel readable [list [self] readPty]

        set pid [pty::spawn $ptyChannel $ptyFile /bin/bash -i]
        pty::resize $ptyChannel 40 120
        set childMonitorTimer [after 200 [list [self] checkChild]]

        wm title . 'LATerm'
        wm protocol . WM_DELETE_WINDOW [list [self] shutdownTerminal]

        set resizeController [::LATerm::ResizeController new \
            $terminal $screen $ptyChannel]

        if {$rendererBackend eq "text"} {
            $terminal configure \
                -wrap none \
                -selectbackground "#365a85" \
                -selectforeground "#ffffff" \
                -inactiveselectbackground "#365a85" \
                -exportselection 1 \
                -takefocus 1
        }

        pack $terminal -fill both -expand true
        bind $terminal <KeyPress> \
            [list [self] handleTerminalKey %W %K %A %s]
        focus $terminal

        set tags [bindtags $terminal]
        if {"LATermMouse" ni $tags} {
            bindtags $terminal [linsert $tags 0 LATermMouse]
        }

        my installBindings
    }

    # Install terminal mouse, focus, clipboard, and keyboard bindings.
    # The custom bindtag runs before Tk's default Text selection bindings,
    # allowing terminal mouse-reporting modes to consume those events and
    # providing cell-based selection for the native widget.
    method installBindings {} {
        bind LATermMouse <ButtonPress-1> \
            [list [self] handleMouse press 1 %x %y %s]
        bind LATermMouse <ButtonRelease-1> \
            [list [self] handleMouse release 1 %x %y %s]
        bind LATermMouse <ButtonPress-2> \
            [list [self] handleMouse press 2 %x %y %s]
        bind LATermMouse <ButtonRelease-2> \
            [list [self] handleMouse release 2 %x %y %s]
        bind LATermMouse <ButtonPress-3> \
            [list [self] handleMouse press 3 %x %y %s]
        bind LATermMouse <ButtonRelease-3> \
            [list [self] handleMouse release 3 %x %y %s]
        bind LATermMouse <Motion> \
            [list [self] handleMouse motion 0 %x %y %s]
        bind LATermMouse <ButtonPress-4> \
            [list [self] handleMouse wheel wheel-up %x %y %s]
        bind LATermMouse <ButtonPress-5> \
            [list [self] handleMouse wheel wheel-down %x %y %s]

        bind $terminal <FocusIn> [list $focusController send 1]
        bind $terminal <FocusOut> [list $focusController send 0]
        bind $terminal <Control-Shift-KeyPress-V> \
            [list [self] handleClipboardPaste %W]
        bind $terminal <Control-Shift-KeyPress-C> \
            [list [self] handleClipboardCopy %W]
    }

    # Re-enable readable notifications after the one-millisecond yield.
    # Tk after callback; no arguments or return value.
    method resumePtyReading {} {
        set ptyResumeTimer ""

        if {$shuttingDown || $ptyClosed} {
            return
        }

        fileevent $ptyChannel readable [list [self] readPty]
    }

    # Yield to other Tk events before re-enabling PTY reads. This bounds
    # time spent processing a continuously readable child process.
    method schedulePtyResume {} {
        if {$shuttingDown || $ptyClosed || $ptyResumeTimer ne ""} {
            return
        }

        set ptyResumeTimer [after 1 [list [self] resumePtyReading]]
    }

    # Sample actual event-loop delay against the expected 100 ms timer.
    # This metric includes time spent in all Tk callbacks.
    method pipelineHeartbeat {} {
        if {$shuttingDown} {
            return
        }

        set now [clock milliseconds]
        set elapsed [expr {$now - $heartbeatLast}]
        set delay [expr {max(0, $elapsed - 100)}]

        if {$delay > $heartbeatMaxDelay} {
            set heartbeatMaxDelay $delay
        }

        set heartbeatLast $now
        set heartbeatTimer [after 100 [list [self] pipelineHeartbeat]]
    }

    # Coalesce multiple PTY updates into one render after renderInterval
    # milliseconds; at most one render timer may be pending.
    method scheduleTerminalRender {} {
        if {$shuttingDown || $ptyClosed || $renderTimer ne ""} {
            return
        }

        incr renderScheduled
        set renderTimer [after \
            $renderInterval [list [self] flushTerminalRender]]
    }

    # Render accumulated dirty state once and update cumulative timing.
    # Tk after callback; no arguments or return value.
    method flushTerminalRender {} {
        set renderTimer ""

        if {$shuttingDown || $ptyClosed} {
            return
        }

        set start [clock microseconds]
        $renderer renderDirty
        set renderUs [expr {[clock microseconds] - $start}]

        incr renderExecuted
        dict incr pipelineStats renderUs $renderUs

        if {$renderUs > [dict get $pipelineStats maxRenderUs]} {
            dict set pipelineStats maxRenderUs $renderUs
        }
    }

    # Print renderer-level counters/timings to stderr during shutdown.
    method reportRendererStats {} {
        set stats [$renderer statistics]
        set rows [dict get $stats styledRows]
        set runs [dict get $stats styleRuns]
        set buildUs [dict get $stats buildUs]
        set tkUs [dict get $stats tkUs]

        puts stderr "\nLATerm renderer statistics"
        puts stderr "---------------------------"
        puts stderr "Full redraws: [dict get $stats fullRedraws]"
        puts stderr "Dirty render calls: [dict get $stats dirtyRenders]"
        puts stderr "Styled rows: $rows"
        puts stderr "Style runs: $runs"
        puts stderr "Single-cell replacements: [dict get $stats cellReplacements]"

        if {$rows > 0} {
            puts stderr [format "Avg style runs/row: %.2f" \
                [expr {double($runs) / $rows}]]
            puts stderr [format "Avg row time: %.3f ms" \
                [expr {($buildUs + $tkUs) / 1000.0 / $rows}]]
        }

        puts stderr [format "Row construction time: %.3f s" \
            [expr {$buildUs / 1000000.0}]]
        puts stderr [format "Tk command time: %.3f s" \
            [expr {$tkUs / 1000000.0}]]
        puts stderr [format "Maximum row time: %.3f ms" \
            [expr {[dict get $stats maxRowUs] / 1000.0}]]
    }

    # Print PTY, parsing, render, and event-loop counters to stderr.
    method reportPipelineStats {} {
        set reads [dict get $pipelineStats reads]
        set bytes [dict get $pipelineStats bytes]
        set parseUs [dict get $pipelineStats parseUs]
        set renderUs [dict get $pipelineStats renderUs]

        puts stderr "\nLATerm pipeline statistics"
        puts stderr "---------------------------"
        puts stderr "PTY reads: $reads"
        puts stderr "Bytes processed: $bytes"
        puts stderr "Render requests: $renderScheduled"
        puts stderr "Render executions: $renderExecuted"

        if {$renderExecuted > 0} {
            puts stderr [format "Avg render/execution: %.3f ms" \
                [expr {$renderUs / 1000.0 / $renderExecuted}]]
        }

        puts stderr [format "Total parse time: %.3f s" \
            [expr {$parseUs / 1000000.0}]]
        puts stderr [format "Total render time: %.3f s" \
            [expr {$renderUs / 1000000.0}]]
        puts stderr [format "Max parse time: %.3f ms" \
            [expr {[dict get $pipelineStats maxParseUs] / 1000.0}]]
        puts stderr [format "Max render time: %.3f ms" \
            [expr {[dict get $pipelineStats maxRenderUs] / 1000.0}]]
        puts stderr "Max event-loop delay: $heartbeatMaxDelay ms"
    }

    # Process a Tk KeyPress binding. widget is a widget path, keysym and
    # character are Tk event strings, and state is Tk's integer modifier
    # mask. Encoded UTF-8 bytes are queued to the PTY; always return Tk's
    # break code to prevent the Text widget from editing terminal output.
    method handleTerminalKey {widget keysym character state} {
        set shift [expr {($state & 0x0001) != 0}]
        set alt [expr {($state & 0x0008) != 0}]
        set ctrl [expr {($state & 0x0004) != 0}]

        if {$keysym eq "ISO_Left_Tab"} {
            set keysym Tab
            set shift 0
        }

        set sequence [$keyboard encode \
            $keysym $character $shift $alt $ctrl]
        if {$sequence ne ""} {
            $writer send [encoding convertto utf-8 $sequence]
        }

        return -code break
    }

    # Dispatch mouse events from the custom bindtag. operation is motion,
    # press, release, or wheel; button is a button number/direction string;
    # args contains the callback-specific integer x, y, and state values.
    # Return Tk's break code only when MouseController consumed the event.
    method handleMouse {operation button args} {
        if {$rendererBackend eq "native" &&
            ![$mouseController reporting]} {
            switch -- $operation {
                press {
                    if {$button == 1} {
                        lassign $args x y state
                        set selectionAnchor \
                            [$mouseController coordinates $x $y]
                        if {$selectionAnchor ne ""} {
                            $renderer setSelection {*}$selectionAnchor \
                                {*}$selectionAnchor
                        }
                        return -code break
                    }
                }
                motion {
                    if {$selectionAnchor ne ""} {
                        lassign $args x y state
                        set position [$mouseController coordinates $x $y]
                        if {$position ne ""} {
                            $renderer setSelection {*}$selectionAnchor {*}$position
                        }
                        return -code break
                    }
                }
                release {
                    if {$button == 1 && $selectionAnchor ne ""} {
                        lassign $args x y state
                        set position [$mouseController coordinates $x $y]
                        if {$position ne ""} {
                            $renderer setSelection {*}$selectionAnchor {*}$position
                        }
                        set selectionAnchor ""
                        return -code break
                    }
                }
                wheel {
                    return
                }
            }
        }

        switch -- $operation {
            motion {
                set handled [$mouseController motion {*}$args]
            }
            default {
                set handled \
                    [$mouseController $operation $button {*}$args]
            }
        }

        if {$handled} {
            return -code break
        }
    }

    # Handle Ctrl+Shift+V for the Tk widget path; always stop Tk's default
    # key handling after delegating clipboard work.
    method handleClipboardPaste {widget} {
        $clipboard paste $widget
        return -code break
    }

    # Handle Ctrl+Shift+C for the Tk widget path and suppress default
    # Text-widget handling.
    method handleClipboardCopy {widget} {
        if {$rendererBackend eq "native"} {
            set text [$renderer selectionText]
            if {$text ne ""} {
                clipboard clear -displayof $widget
                clipboard append -displayof $widget -- $text
            }
        } else {
            $clipboard copySelection $widget
        }
        return -code break
    }

    # Receive a PTY writer error message and defer shutdown until idle so
    # writer failure handling does not recursively close the writer.
    method onPtyWriterFailure {message} {
        puts stderr "LATerm: PTY write failure: $message"

        if {!$shuttingDown} {
            after idle [list [self] terminalExited]
        }
    }

    # Idempotently stop PTY notifications and close writer/channel state.
    # The ptyClosed flag prevents queued callbacks from using a closed
    # channel.
    method closePty {} {
        if {$ptyClosed} {
            return
        }

        set ptyClosed 1
        catch {fileevent $ptyChannel readable {}}
        catch {$writer close}
        catch {close $ptyChannel}
    }

    # Begin application shutdown once: stop timers/input, report metrics,
    # close the PTY, hide the window, and start child-reaping checks.
    method terminalExited {} {
        if {$shuttingDown} {
            return
        }

        if {$ptyResumeTimer ne ""} {
            after cancel $ptyResumeTimer
            set ptyResumeTimer ""
        }

        my reportPipelineStats
        my reportRendererStats
        set shuttingDown 1

        foreach timerId [list \
            $childMonitorTimer $renderTimer $heartbeatTimer] {
            if {$timerId ne ""} {
                after cancel $timerId
            }
        }
        set childMonitorTimer ""
        set renderTimer ""
        set heartbeatTimer ""

        bind $terminal <KeyPress> {}
        my closePty
        wm withdraw .
        my scheduleShutdownCheck
    }

    # WM_DELETE_WINDOW callback. Delegates to the shared shutdown path.
    method shutdownTerminal {} {
        my terminalExited
    }

    # Ensure only one delayed child-reaping check is pending.
    method scheduleShutdownCheck {} {
        if {$shutdownTimer eq ""} {
            set shutdownTimer [after 100 [list [self] finishShutdown]]
        }
    }

    # Poll the child process. If it remains alive, retry and escalate from
    # SIGTERM to SIGKILL after bounded intervals before checking again.
    method finishShutdown {} {
        set shutdownTimer ""

        if {!$shuttingDown} {
            return
        }

        if {$childReaped} {
            destroy .
            return
        }

        if {[catch {pty::wait $pid} result]} {
            puts stderr "waitpid error: $result"
            destroy .
            return
        }

        if {$result ne "running"} {
            set childReaped 1
            puts "Shell terminated: $result"
            destroy .
            return
        }

        incr shutdownAttempts
        if {$shutdownAttempts == 10} {
            catch {pty::signal $pid 15}
        }
        if {$shutdownAttempts == 20} {
            catch {pty::signal $pid 9}
        }

        my scheduleShutdownCheck
    }

    # Periodically detect a child that exited independently of PTY EOF.
    # pty::wait returns "running" while the process is still alive.
    method checkChild {} {
        set childMonitorTimer ""

        if {$shuttingDown || $childReaped} {
            return
        }

        if {[catch {pty::wait $pid} result]} {
            puts stderr "Child monitor error: $result"
            my terminalExited
            return
        }

        if {$result ne "running"} {
            set childReaped 1
            my terminalExited
            return
        }

        set childMonitorTimer [after 200 [list [self] checkChild]]
    }

    # Read at most ptyReadBudget bytes per callback, parse them, and
    # schedule rendering/another read. Read events are temporarily removed
    # so the application can yield instead of monopolizing Tk's event loop.
    method readPty {} {
        if {$shuttingDown || $ptyClosed} {
            return
        }

        fileevent $ptyChannel readable {}

        if {[catch {
            read $ptyChannel $ptyReadBudget
        } data options]} {
            if {[dict exists $options -errorcode] &&
                [lindex [dict get $options -errorcode] 0] eq "POSIX" &&
                [lindex [dict get $options -errorcode] 1] eq "EIO"} {
                my terminalExited
                return
            }

            puts stderr "PTY read error: $data"
            my terminalExited
            return
        }

        if {$data eq ""} {
            if {[eof $ptyChannel]} {
                my terminalExited
                return
            }

            my schedulePtyResume
            return
        }

        set start [clock microseconds]
        if {[catch {$parser feed $data} result options]} {
            puts stderr "Parser error: $result"
            puts stderr [dict get $options -errorinfo]
            my terminalExited
            return
        }

        set parseUs [expr {[clock microseconds] - $start}]
        dict incr pipelineStats reads
        dict incr pipelineStats bytes [string length $data]
        dict incr pipelineStats parseUs $parseUs

        if {$parseUs > [dict get $pipelineStats maxParseUs]} {
            dict set pipelineStats maxParseUs $parseUs
        }

        my scheduleTerminalRender
        my schedulePtyResume
    }
}

set ::latermApplication [::LATerm::Application new]
