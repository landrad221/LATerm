# import libs 
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

set cursorCanvas [canvas .cursorOverlay]

text .terminal

# setup vars
#
set pty_pair [pty::open]
set pty_chan [lindex $pty_pair 0]
set pty_file [lindex $pty_pair 1]

set writer [::LATerm::PtyWriter new $pty_chan \
    1048576 ::LATerm::onPtyWriterFailure]

set screen   [::laterm::Screen new 24 80]
set adapter  [::LATerm::ScreenAdapter new $screen [list $writer send]]
set parser   [::LATerm::Parser new [list $adapter event]]
set renderer [::laterm::TkRenderer new .terminal $screen]
set keyboard [::LATerm::KeyboardEncoder new $screen]
set clipboard [::LATerm::ClipboardController new $screen $writer]
set mouseEncoder [::LATerm::MouseEncoder new $screen]
set focusController [::LATerm::FocusController new \
    $screen [list $writer send  ]]



set mouseController [::LATerm::MouseController new \
    .terminal $screen $mouseEncoder $writer]

set cursorOverlay [::laterm::CursorOverlay new \
    .cursorOverlay .terminal $renderer $screen]

$renderer setCursorOverlay $cursorOverlay
$renderer updateCursor
$cursorOverlay refresh

# LATerm lifecycle state
set ::shuttingDown 0
set ::childReaped 0
set ::ptyClosed 0
set ::shutdownAttempts 0
set ::childMonitorTimer ""
set ::shutdownTimer ""




# LATerm 8.16.3 - Cooperative PTY scheduling

set ::ptyResumeTimer ""
set ::ptyReadBudget 1024

proc resumePtyReading {} {
    set ::ptyResumeTimer ""

    if {$::shuttingDown || $::ptyClosed} {
        return
    }

    fileevent $::pty_chan readable readpty
}

proc schedulePtyResume {} {
    if {$::shuttingDown || $::ptyClosed} {
        return
    }

    if {$::ptyResumeTimer ne ""} {
        return
    }

    # Resume on a later event-loop iteration.
    set ::ptyResumeTimer [after 1 resumePtyReading]
}



# LATerm 8.16.2 - Coalesced rendering
set ::renderTimer ""
set ::renderInterval 16
set ::renderScheduled 0
set ::renderExecuted 0


set ::heartbeatTimer ""
set ::heartbeatLast [clock milliseconds]
set ::heartbeatMaxDelay 0

set ::heartbeatLast [clock milliseconds]
set ::heartbeatTimer [after 100 pipelineHeartbeat]

proc pipelineHeartbeat {} {
    if {$::shuttingDown} {
        return
    }

    set now [clock milliseconds]
    set elapsed [expr {$now - $::heartbeatLast}]

    # Expected interval is 100 ms.
    set delay [expr {max(0, $elapsed - 100)}]

    if {$delay > $::heartbeatMaxDelay} {
        set ::heartbeatMaxDelay $delay
    }

    set ::heartbeatLast $now
    set ::heartbeatTimer [after 100 pipelineHeartbeat]
}


proc scheduleTerminalRender {} {
    if {$::shuttingDown || $::ptyClosed} {
        return
    }

    # A redraw is already pending.
    if {$::renderTimer ne ""} {
        return
    }

    incr ::renderScheduled

    set ::renderTimer [after \
        $::renderInterval \
        flushTerminalRender]
}

proc flushTerminalRender {} {
    set ::renderTimer ""

    if {$::shuttingDown || $::ptyClosed} {
        return
    }

    set start [clock microseconds]

    $::renderer renderDirty

    set renderUs [expr {
        [clock microseconds] - $start
    }]

    incr ::renderExecuted

    dict incr ::pipelineStats renderUs $renderUs

    if {$renderUs >
        [dict get $::pipelineStats maxRenderUs]} {

        dict set ::pipelineStats maxRenderUs $renderUs
    }
}

# LATerm 8.16.1 - Pipeline instrumentation
set ::pipelineStats [dict create \
    reads 0 \
    bytes 0 \
    parseUs 0 \
    renderUs 0 \
    maxParseUs 0 \
    maxRenderUs 0]

proc reportPipelineStats {} {
    set s $::pipelineStats

    set reads [dict get $s reads]
    set bytes [dict get $s bytes]
    set parseUs [dict get $s parseUs]
    set renderUs [dict get $s renderUs]

    puts stderr "\nLATerm pipeline statistics"
    puts stderr "---------------------------"
    puts stderr "PTY reads: $reads"
    puts stderr "Bytes processed: $bytes"

    set renders $::renderExecuted

    puts stderr "Render requests: $::renderScheduled"
    puts stderr "Render executions: $renders"

    if {$renders > 0} {
        puts stderr [format "Avg render/execution: %.3f ms" \
            [expr {$renderUs / 1000.0 / $renders}]]
    }

    puts stderr [format "Total parse time: %.3f s" \
        [expr {$parseUs / 1000000.0}]]

    puts stderr [format "Total render time: %.3f s" \
        [expr {$renderUs / 1000000.0}]]

    puts stderr [format "Max parse time: %.3f ms" \
        [expr {[dict get $s maxParseUs] / 1000.0}]]

    puts stderr [format "Max render time: %.3f ms" \
        [expr {[dict get $s maxRenderUs] / 1000.0}]]

    puts stderr "Max event-loop delay: $::heartbeatMaxDelay ms"
}

proc cancelLifecycleTimer {variableName} {
    upvar #0 $variableName timerId

    if {$timerId ne ""} {
        after cancel $timerId
        set timerId ""
    }
}

proc scheduleShutdownCheck {} {
    if {![info exists ::shutdownTimer]} {
        set ::shutdownTimer ""
    }

    if {$::shutdownTimer ne ""} {
        return
    }

    set ::shutdownTimer [after 100 finishShutdown]
}

proc handleTerminalKey {widget writer encoder keysym character state} {
    set shift [expr {($state & 0x0001) != 0}]
    set alt   [expr {($state & 0x0008) != 0}]
    set ctrl  [expr {($state & 0x0004) != 0}]

    if {$keysym eq "ISO_Left_Tab"} {
        set keysym "Tab"
        set shift 0
    }

    set sequence [$encoder encode $keysym $character $shift $alt $ctrl]

    if {$sequence ne ""} {
        set bytes [ encoding convertto utf-8 $sequence]
        $writer send $bytes
    }

    return -code break
}

proc closePty {} {
    if {$::ptyClosed} {
        return
    }

    set ::ptyClosed 1

    # Disable callbacks before closing the channel.
    catch {fileevent $::pty_chan readable {}}
    catch {$::writer close}

    catch {close $::pty_chan}
}

proc terminalExited {} {
    if {$::shuttingDown} {
        return
    }
    cancelLifecycleTimer ::ptyResumeTimer

    reportPipelineStats

    set ::shuttingDown 1

     # Stop periodic child monitoring.
    cancelLifecycleTimer ::childMonitorTimer

    cancelLifecycleTimer ::renderTimer

    # Disable further keyboard input.
    bind .terminal <KeyPress> {}

    cancelLifecycleTimer ::heartbeatTimer

    closePty

    # Hide the window while the child is reaped.
    wm withdraw .


    scheduleShutdownCheck
}

proc shutdownTerminal {} {
  terminalExited 
}

proc finishShutdown {} {
    set ::shutdownTimer ""

    if {!$::shuttingDown} {
        return
    }

    if {$::childReaped} {
        destroy .
        return
    }

    if {[catch {pty::wait $::pid} result]} {
        puts stderr "waitpid error: $result"
        destroy .
        return
    }

    if {$result ne "running"} {
        set ::childReaped 1
        puts "Shell terminated: $result"
        destroy .
        return
    }

    incr ::shutdownAttempts

    if {$::shutdownAttempts == 10} {
        catch {pty::signal $::pid 15}
    }

    if {$::shutdownAttempts == 20} {
        catch {pty::signal $::pid 9}
    }
    scheduleShutdownCheck
}

proc checkChild {} {
    set ::childMonitorTimer ""

    if {$::shuttingDown || $::childReaped} {
        return
    }

    if {[catch {pty::wait $::pid} result]} {
        puts stderr "Child monitor error: $result"
        terminalExited
        return
    }

    if {$result ne "running"} {
        set ::childReaped 1
        terminalExited
        return
    }

    set ::childMonitorTimer [after 200 checkChild]
}


proc readpty {} {
    if {$::shuttingDown || $::ptyClosed} {
        return
    }

    # Prevent another readable callback from being
    # dispatched until this processing turn finishes.
    fileevent $::pty_chan readable {}

    if {[catch {
        read $::pty_chan $::ptyReadBudget
    } data options]} {

        if {[dict exists $options -errorcode] &&
            [lindex [dict get $options -errorcode] 0] eq "POSIX" &&
            [lindex [dict get $options -errorcode] 1] eq "EIO"} {

            terminalExited
            return
        }

        puts stderr "PTY read error: $data"
        terminalExited
        return
    }

    if {$data eq ""} {
        if {[eof $::pty_chan]} {
            terminalExited
            return
        }

        schedulePtyResume
        return
    }

    set start [clock microseconds]

    if {[catch {
        $::parser feed $data
    } result options]} {
        puts stderr "Parser error: $result"
        puts stderr [dict get $options -errorinfo]
        terminalExited
        return
    }

    set parseUs [expr {
        [clock microseconds] - $start
    }]

    dict incr ::pipelineStats reads
    dict incr ::pipelineStats bytes [string length $data]
    dict incr ::pipelineStats parseUs $parseUs

    if {$parseUs > [dict get $::pipelineStats maxParseUs]} {
        dict set ::pipelineStats maxParseUs $parseUs
    }

    # Schedule the next screen update.
    scheduleTerminalRender

    # Allow Tk to process other events before
    # reading more PTY output.
    schedulePtyResume
}





fconfigure $pty_chan -translation binary -blocking no -buffering none -encoding binary
fileevent $pty_chan readable readpty

set pid [pty::spawn $pty_chan $pty_file /bin/bash -i]

pty::resize $::pty_chan 40 120
set ::childMonitorTimer [after 200 checkChild]

wm title . 'LATerm'
wm protocol . WM_DELETE_WINDOW shutdownTerminal

set fontName [.terminal cget -font]
set cellWidth  [font measure $fontName "M"]
set cellHeight [font metrics $fontName -linespace]

set resizeController [::laterm::ResizeController new .terminal $screen $pty_chan]

.terminal configure \
    -wrap none \
    -selectbackground "#365a85" \
    -selectforeground "#ffffff" \
    -inactiveselectbackground "#365a85" \
    -exportselection 1 \
    -takefocus 1


pack .terminal -fill both -expand true
bind .terminal <KeyPress> {handleTerminalKey %W $::writer $keyboard %K %A %s}
focus .terminal


# Install before the widget and Text class binding tags.
set tags [bindtags .terminal]

if {"LATermMouse" ni $tags} {
    bindtags .terminal [linsert $tags 0 LATermMouse]
}

bind LATermMouse <ButtonPress-1> {
    if {[$mouseController press 1 %x %y %s]} break
}

bind LATermMouse <ButtonRelease-1> {
    if {[$mouseController release 1 %x %y %s]} break
}

bind LATermMouse <ButtonPress-2> {
    if {[$mouseController press 2 %x %y %s]} break
}

bind LATermMouse <ButtonRelease-2> {
    if {[$mouseController release 2 %x %y %s]} break
}

bind LATermMouse <ButtonPress-3> {
    if {[$mouseController press 3 %x %y %s]} break
}

bind LATermMouse <ButtonRelease-3> {
    if {[$mouseController release 3 %x %y %s]} break
}

bind LATermMouse <Motion> {
    if {[$mouseController motion %x %y %s]} break
}

# X11 wheel events.
bind LATermMouse <ButtonPress-4> {
    if {[$mouseController wheel wheel-up %x %y %s]} break
}

bind LATermMouse <ButtonPress-5> {
    if {[$mouseController wheel wheel-down %x %y %s]} break
}

bind .terminal <FocusIn> {
    $focusController send 1
}

bind .terminal <FocusOut> {
    $focusController send 0
}

bind .terminal <Control-Shift-KeyPress-V> {
    $clipboard paste %W
    break
}

bind .terminal <Control-Shift-KeyPress-C> {
    $clipboard copySelection %W
    break
}