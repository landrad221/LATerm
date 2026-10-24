# import libs 
package require Tk

lappend auto_path [file dirname [info script]]
package require pty

source parser.tcl 
source resize_controller.tcl
source render/screen.tcl 

# setup vars
#
set pty_pair [pty::open]
set pty_chan [lindex $pty_pair 0]
set pty_file [lindex $pty_pair 1]

set parser [::LATerm::Parser new onTerminalEvent]

set screen [::laterm::Screen new 24 80]


# LATerm lifecycle state
set ::shuttingDown 0
set ::childReaped 0
set ::ptyClosed 0
set ::shutdownAttempts 0

proc closePty {} {
    if {$::ptyClosed} {
        return
    }

    set ::ptyClosed 1

    # Disable callbacks before closing the channel.
    catch {fileevent $::pty_chan readable {}}
    catch {close $::pty_chan}
}

proc terminalExited {} {
    if {$::shuttingDown} {
        return
    }

    set ::shuttingDown 1

    # Disable further keyboard input.
    bind .terminal <KeyPress> {}

    closePty

    # Hide the window while the child is reaped.
    wm withdraw .

    after 100 finishShutdown
}

proc shutdownTerminal {} {
  terminalExited 
}

proc finishShutdown {} {
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

    after 100 finishShutdown
}


proc checkChild {} {
    if {$::shuttingDown || $::childReaped} {
        return
    }

    if {[catch {pty::wait $::pid} result]} {
        puts stderr "Child monitor error: $result"
        return
    }

    if {$result ne "running"} {
        set ::childReaped 1
        puts "Shell exited: $result"
        terminalExited
        return
    }

    after 200 checkChild
}

proc onTerminalEvent {args} {
    puts "TERMINAL: $args"
}
proc controlCharacter {keysym} {
    set key [string toupper $keysym]

    if {![regexp {^[A-Z]$} $key]} {
        return ""
    }

    set ascii [scan $key %c]
    return [format %c [expr {$ascii - 64}]]
}

proc sendkey {keysym char state} {
    # Tk Control modifier bit
    set ctrl [expr {($state & 0x4) != 0}]

    if {$ctrl} {
        # Convert Ctrl+C to \x03, Ctrl+Z to \x1a, etc.
        set data [controlCharacter $keysym]

        if {$data eq ""} {
            return -code break
        }

    } else {
        switch -- $keysym {
            Return    {set data "\r"}
            BackSpace {set data "\x7f"}
            Tab       {set data "\t"}
            Escape    {set data "\x1b"}
            Up        {set data "\x1b\[A"}
            Down      {set data "\x1b\[B"}
            Right     {set data "\x1b\[C"}
            Left      {set data "\x1b\[D"}
            Delete    {set data "\x1b\[3~"}
            default {
                if {$char eq ""} {
                    return -code break
                }
                set data $char
            }
        }
    }
if {$::shuttingDown || $::ptyClosed} {
    return -code break
}

# Verify that the channel still exists.
if {$::pty_chan ni [chan names]} {
    return -code break
}

# Handle a channel that closes or fails during writing.
if {[catch {
    puts -nonewline $::pty_chan $data
} err]} {
    puts stderr "PTY write error: $err"
    return -code break
}

    return -code break
}

proc process_no_readable {k} {
	switch $k {
		{BackSpace} {return "\x08"}
		{Return} {return "\x0a"}
		{space} {return " "}
	}
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

    # Temporary rendering until ANSI parsing is integrated.
    .terminal insert end $data
    .terminal see end
}


fconfigure $pty_chan -translation binary -blocking no -buffering none
fileevent $pty_chan readable readpty

set pid [pty::spawn $pty_chan $pty_file /bin/bash -i]

pty::resize $::pty_chan 40 120
after 200 checkChild 

wm title . 'LATerm'
wm protocol . WM_DELETE_WINDOW shutdownTerminal
text .terminal

set fontName [.terminal cget -font]
set cellWidth  [font measure $fontName "M"]
set cellHeight [font metrics $fontName -linespace]

set resizeController [::laterm::ResizeController new .terminal $screen $pty_chan]

.terminal configure -wrap none
pack .terminal -fill both -expand true
bind .terminal <Key> {sendkey %K %A %s}

