namespace eval ::LATerm {}

 oo::class create ::LATerm::Parser {
    variable state params intermediates callback

    constructor {handler} {
        set callback $handler
        my reset
    }

    method reset {} {
        set state GROUND
        set params ""
        set intermediates ""
    }

    method state {} { return $state }

    method emit {args} {
        {*}$callback {*}$args
    }

    method feed {bytes} {
        binary scan $bytes cu* octets
        foreach b $octets {
            if {$b == 0x18 || $b == 0x1a} {
                if {$state ne "GROUND"} { my reset } else { my emit control [expr {$b == 0x18 ? "CAN" : "SUB"}] }
                continue
            }
            if {$b == 0x1b} {
                set state ESCAPE
                set params ""
                set intermediates ""
                continue
            }
            switch -- $state {
                GROUND {
                    if {$b < 0x20 || $b == 0x7f} {
                        set names {NUL SOH STX ETX EOT ENQ ACK BEL BS HT LF VT FF CR SO SI DLE DC1 DC2 DC3 DC4 NAK SYN ETB CAN EM SUB ESC FS GS RS US}
                        if {$b == 0x7f} { my emit control DEL } else { my emit control [lindex $names $b] }
                    } elseif {$b < 0x80} {
                        my emit print [format %c $b]
                    } else {
                        my emit byte $b
                    }
                }
                ESCAPE {
                    if {$b < 0x20} {
                        my emit control [my controlName $b]
                    } elseif {$b == 0x5b} {
                        set state CSI
                        set params ""
                        set intermediates ""
                    } elseif {$b >= 0x20 && $b <= 0x2f} {
                        set intermediates [format %c $b]
                        set state ESC_INTERMEDIATE
                    } elseif {$b >= 0x30 && $b <= 0x7e} {
                        my emit escape [format %c $b]
                        my reset
                    } else { my reset }
                }
                ESC_INTERMEDIATE {
                    if {$b < 0x20} {
                        my emit control [my controlName $b]
                    } elseif {$b >= 0x20 && $b <= 0x2f} {
                        append intermediates [format %c $b]
                    } elseif {$b >= 0x30 && $b <= 0x7e} {
                        my emit escape $intermediates[format %c $b]
                        my reset
                    } else { my reset }
                }
                CSI {
                    if {$b < 0x20} {
                        my emit control [my controlName $b]
                    } elseif {$b >= 0x30 && $b <= 0x3f && $intermediates eq ""} {
                        append params [format %c $b]
                    } elseif {$b >= 0x20 && $b <= 0x2f} {
                        append intermediates [format %c $b]
                    } elseif {$b >= 0x40 && $b <= 0x7e} {
                        my emit csi $params $intermediates [format %c $b]
                        my reset
                    } else { my reset }
                }
            }
        }
    }

    method controlName {b} {
        set names {NUL SOH STX ETX EOT ENQ ACK BEL BS HT LF VT FF CR SO SI DLE DC1 DC2 DC3 DC4 NAK SYN ETB CAN EM SUB ESC FS GS RS US}
        return [lindex $names $b]
    }
}
