package require Tk

lappend auto_path [file dirname [info script]]
package require pty

set pty_pair [pty::open]
set pty_chan [lindex $pty_pair 0]
set pty_file [lindex $pty_pair 1]
proc sendkey {keysym} {
	puts $keysym
}

exec bash -c "bash &>$pty_file <$pty_file &"


wm title . 'LATerm'
text .terminal
pack .terminal -fill both -expand true
bind .terminal <Key> {sendkey %K}
