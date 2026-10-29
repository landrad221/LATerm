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

    set ::shuttingDown 1

     # Stop periodic child monitoring.
    cancelLifecycleTimer ::childMonitorTimer

    # Disable further keyboard input.
    bind .terminal <KeyPress> {}

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

    if {[catch {read $::pty_chan 4096} data options]} {
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
        }
        return
    }

    $::parser feed $data 
    $::renderer renderDirty
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