set ThisScriptDir [file dirname [info script]]
package ifneeded laterm_native_renderer 0.1 \
    [list source [file join $ThisScriptDir native_renderer.tcl]]
