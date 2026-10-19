package require Tk

lappend auto_path [file dirname [info script]]
package require pty

set pty_pair [pty::open]
set pty_chan [lindex $pty_pair 0]
set pty_file [lindex $pty_pair 1]
proc sendkey {keysym} {
	if {[string length $keysym]==1} {
	   puts -nonewline $::pty_chan $keysym
        } else {
		puts -nonewline $::pty_chan [process_no_readable $keysym]
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
	set buf [read $::pty_chan 1]

	if {[string compare $buf "\x08"]==0} {
		.terminal delete end-2c
	} else {
		.terminal insert end $buf
	}
}

fconfigure $pty_chan -translation binary -blocking no -buffering none
fileevent $pty_chan readable readpty

exec setsid sh -c "exec bash <> $pty_file >&0 2>&1 &"

wm title . 'LATerm'
text .terminal
pack .terminal -fill both -expand true
bind .terminal <Key> {sendkey %K}

