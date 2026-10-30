
namespace eval ::LATerm {}

oo::class create ::LATerm::PtyWriter {
    variable channel queue scheduled closed
    variable maxPending idleCallback
    variable chunkSize writableArmed
    variable queuedBytes
    variable failed errorMessage
    variable failureCallback

    constructor {ptyChannel {limit 1048576} {onFailure {}}} {
        set channel $ptyChannel
        set queue {}
        set queuedBytes 0
        set scheduled 0
        set closed 0
        set failureCallback $onFailure
        set maxPending $limit
        set idleCallback ""
        set chunkSize 4096
        set writableArmed 0
        set failed 0
        set errorMessage ""

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

        set size [string bytelength $bytes]
        set pending [my pending]

        if {$closed} {
            error "PTY writer is closed"
        }

        if {$pending + $size > $maxPending} {
            error "PTY writer pending limit exceeded"
        }


        lappend queue $bytes
        incr queuedBytes $size

        my schedule

        return
    }

    method schedule {} {
        if {$closed || $scheduled || $writableArmed} {
            return
        }

        set scheduled 1
        set idleCallback [after idle [list [self] drain]]
    }

    method armWritable {} {
        if {$closed || $writableArmed} {
            return
        }

        set writableArmed 1
        fileevent $channel writable [list [self] onWritable]
    }

    method disarmWritable {} {
        if {!$writableArmed} {
            return
        }

        set writableArmed 0
        catch {fileevent $channel writable {}}
    }

    method drain {} {
        set scheduled 0
        set idleCallback ""

        if {$closed} {
            return
        }

        # Do not add more data while Tcl still has
        # buffered output waiting for the channel.
        if {[catch {chan pending output $channel} buffered]} {
            my fail $buffered
            return
        }
        if {$buffered > 0} {
            my armWritable
            return
        }

        if {[llength $queue] == 0} {
            my disarmWritable
            return
        }

        set bytes [lindex $queue 0]

        # Split the next message into bounded chunks.
        set size [string bytelength $bytes]
        set count [expr {min($size, $chunkSize)}]

        set part [string range $bytes 0 [expr {$count - 1}]]
        set rest [string range $bytes $count end]

        if {[catch {
            puts -nonewline $channel $part
            flush $channel
        } err]} {
            my fail $err
            return
        }

        incr queuedBytes -$count

        if {$rest eq ""} {
            set queue [lrange $queue 1 end]
        } else {
            set queue [lreplace $queue 0 0 $rest]
        }

        if {[catch {chan pending output $channel} buffered]} {
            my fail $buffered
        } elseif {$buffered > 0} {
            my armWritable
        } elseif {[llength $queue] > 0} {
            my schedule
        }
    }

    method onWritable {} {
        if {$closed} {
            return
        }

        if {[catch {
            flush $channel
        } err]} {
            my fail $err
            return
        }

        if {[catch {chan pending output $channel} buffered]} {
            my fail $buffered
            return
        }
        if {$buffered > 0} {
            return
        }

        my disarmWritable

        if {[llength $queue] > 0} {
            my schedule
        }
    }

    method fail {message} {
        if {$closed} {
            return
        }

        set failed 1
        set errorMessage $message
        my close

        puts stderr "LATerm PTY writer error: $message"


        if {$failureCallback ne ""} {
            if {[catch {
                {*}$failureCallback $message
            } callbackError]} {
                puts stderr \
                    "LATerm PTY failure callback error: $callbackError"
            }
        }
        
    }

    method pending {} {
        set buffered 0

        if {!$closed} {
            if {[catch {
                chan pending output $channel
            } buffered]} {
                my fail $buffered
                return 0
            }
        }

        return [expr {$queuedBytes + $buffered}]
    }

    method isClosed {} {
        return $closed
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

        my disarmWritable

        set scheduled 0
        set queue {}
        set queuedBytes 0
    }
    method hasFailed {} {
       return $failed
    }

    method lastError {} {
        return $errorMessage
    }

    method state {} {
        if {$failed} {
            return failed
        }

        if {$closed} {
            return closed
        }

        return open
    }

    destructor {
        my close
    }
}
