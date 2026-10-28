
namespace eval ::LATerm {}

oo::class create ::LATerm::PtyWriter {
    variable channel queue scheduled closed
    variable maxPending idleCallback

    constructor {ptyChannel {limit 1048576}} {
        set channel $ptyChannel
        set queue {}
        set scheduled 0
        set closed 0
        set maxPending $limit
        set idleCallback ""

        fconfigure $channel \
            -blocking 0 \
            -buffering none \
            -translation binary \
            -encoding binary
    }

    method send {bytes} {
        if {$closed} {
            error "PTY writer is closed"
        }

        if {$bytes eq ""} {
            return
        }

        set pending [chan pending output $channel]

        foreach item $queue {
            incr pending [string bytelength $item]
        }

        if {$pending + [string bytelength $bytes] > $maxPending} {
            error "PTY writer pending limit exceeded"
        }

        lappend queue $bytes

        
        if {!$scheduled} {
            set scheduled 1
            set idleCallback [after idle [list [self] drain]]
        }
    }

    method drain {} {
        set scheduled 0
        set idleCallback ""

        if {$closed} {
            return
        }

        while {[llength $queue] > 0} {
            set bytes [lindex $queue 0]

            if {[catch {
                puts -nonewline $channel $bytes
            } err opts]} {
                my fail $err
                return
            }

            set queue [lrange $queue 1 end]
        }

        if {[catch {flush $channel} err]} {
            my fail $err
        }
    }

    method fail {message} {
        puts stderr "LATerm PTY writer error: $message"
        my close
    }

    method close {} {
        if {$closed} {
            return
        }

        set closed 1

        if {$idleCallback ne ""} {
            after cancel $idleCallback
            set idleCallback ""
        }

        set scheduled 0

        set queue {}
    }

    method pending {} {
        set total [chan pending output $channel]

        foreach item $queue {
            incr total [string bytelength $item]
        }

        return $total
    }

    method isClosed {} {
        return $closed
    }

    destructor {
        my close
    }
}