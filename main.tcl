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

namespace eval ::LATerm {}

oo::class create ::LATerm::Application {
    variable terminal cursorCanvas
    variable ptyChannel ptyFile pid
    variable writer screen adapter parser renderer keyboard clipboard
    variable mouseEncoder mouseController focusController cursorOverlay
    variable resizeController
    variable shuttingDown childReaped ptyClosed shutdownAttempts
    variable childMonitorTimer shutdownTimer ptyResumeTimer
    variable ptyReadBudget renderTimer renderInterval
    variable renderScheduled renderExecuted
    variable heartbeatTimer heartbeatLast heartbeatMaxDelay
    variable pipelineStats

    constructor {} {
        set terminal .terminal
        set cursorCanvas .cursorOverlay

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

    method initialize {} {
        set cursorCanvas [canvas $cursorCanvas]
        text $terminal

        lassign [pty::open] ptyChannel ptyFile
        set writer [::LATerm::PtyWriter new \
            $ptyChannel 1048576 [list [self] onPtyWriterFailure]]
        set screen [::LATerm::Screen new 24 80]
        set adapter [::LATerm::ScreenAdapter new \
            $screen [list $writer send]]
        set parser [::LATerm::Parser new [list $adapter event]]
        set renderer [::LATerm::TkRenderer new $terminal $screen]
        set keyboard [::LATerm::KeyboardEncoder new $screen]
        set clipboard [::LATerm::ClipboardController new $screen $writer]
        set mouseEncoder [::LATerm::MouseEncoder new $screen]
        set focusController [::LATerm::FocusController new \
            $screen [list $writer send]]
        set mouseController [::LATerm::MouseController new \
            $terminal $screen $mouseEncoder $writer]
        set cursorOverlay [::LATerm::CursorOverlay new \
            $cursorCanvas $terminal $renderer $screen]

        $renderer setCursorOverlay $cursorOverlay
        $renderer updateCursor
        $cursorOverlay refresh

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

        $terminal configure \
            -wrap none \
            -selectbackground "#365a85" \
            -selectforeground "#ffffff" \
            -inactiveselectbackground "#365a85" \
            -exportselection 1 \
            -takefocus 1

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

    method resumePtyReading {} {
        set ptyResumeTimer ""

        if {$shuttingDown || $ptyClosed} {
            return
        }

        fileevent $ptyChannel readable [list [self] readPty]
    }

    method schedulePtyResume {} {
        if {$shuttingDown || $ptyClosed || $ptyResumeTimer ne ""} {
            return
        }

        set ptyResumeTimer [after 1 [list [self] resumePtyReading]]
    }

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

    method scheduleTerminalRender {} {
        if {$shuttingDown || $ptyClosed || $renderTimer ne ""} {
            return
        }

        incr renderScheduled
        set renderTimer [after \
            $renderInterval [list [self] flushTerminalRender]]
    }

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

    method handleMouse {operation button args} {
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

    method handleClipboardPaste {widget} {
        $clipboard paste $widget
        return -code break
    }

    method handleClipboardCopy {widget} {
        $clipboard copySelection $widget
        return -code break
    }

    method onPtyWriterFailure {message} {
        puts stderr "LATerm: PTY write failure: $message"

        if {!$shuttingDown} {
            after idle [list [self] terminalExited]
        }
    }

    method closePty {} {
        if {$ptyClosed} {
            return
        }

        set ptyClosed 1
        catch {fileevent $ptyChannel readable {}}
        catch {$writer close}
        catch {close $ptyChannel}
    }

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

    method shutdownTerminal {} {
        my terminalExited
    }

    method scheduleShutdownCheck {} {
        if {$shutdownTimer eq ""} {
            set shutdownTimer [after 100 [list [self] finishShutdown]]
        }
    }

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
