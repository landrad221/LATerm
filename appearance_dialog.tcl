package require Tk 8.6

namespace eval ::LATerm::Appearance {}

proc ::LATerm::Appearance::defaults {} {
    return [dict create \
        fontFamily [font actual TkFixedFont -family] \
        fontSize [font actual TkFixedFont -size] \
        foreground "#e5e7eb" \
        background "#111827"]
}

proc ::LATerm::Appearance::configPath {} {
    if {[info exists ::env(XDG_CONFIG_HOME)] &&
        $::env(XDG_CONFIG_HOME) ne ""} {
        set configHome $::env(XDG_CONFIG_HOME)
    } elseif {[info exists ::env(HOME)] && $::env(HOME) ne ""} {
        set configHome [file join $::env(HOME) .config]
    } else {
        error "cannot locate appearance settings: HOME and XDG_CONFIG_HOME are unset"
    }

    return [file join $configHome laterm appearance.conf]
}

proc ::LATerm::Appearance::validate {settings} {
    foreach key {fontFamily fontSize foreground background} {
        if {![dict exists $settings $key]} {
            error "appearance settings are missing \"$key\""
        }
    }

    set family [dict get $settings fontFamily]
    if {$family ni [font families]} {
        error "font family \"$family\" is not installed"
    }

    set size [dict get $settings fontSize]
    if {![string is integer -strict $size] || $size < 6 || $size > 48} {
        error "font size must be an integer from 6 to 48"
    }

    foreach key {foreground background} {
        set color [dict get $settings $key]
        if {[catch {winfo rgb . $color}]} {
            error "invalid $key color \"$color\""
        }
    }

    return [dict create \
        fontFamily $family \
        fontSize $size \
        foreground [dict get $settings foreground] \
        background [dict get $settings background]]
}

proc ::LATerm::Appearance::load {{path ""}} {
    if {$path eq ""} {
        set path [::LATerm::Appearance::configPath]
    }
    if {![file exists $path]} {
        return [::LATerm::Appearance::defaults]
    }

    set channel [open $path r]
    try {
        set contents [read $channel]
    } finally {
        close $channel
    }

    if {[catch {dict size $contents}]} {
        error "appearance settings file is not a valid Tcl dictionary: $path"
    }
    return [::LATerm::Appearance::validate $contents]
}

proc ::LATerm::Appearance::save {settings {path ""}} {
    if {$path eq ""} {
        set path [::LATerm::Appearance::configPath]
    }
    set settings [::LATerm::Appearance::validate $settings]
    set directory [file dirname $path]
    file mkdir $directory

    set temporaryPath "${path}.tmp.[pid]"
    set channel [open $temporaryPath w]
    try {
        puts $channel $settings
        flush $channel
        close $channel
        set channel ""
        file rename -force $temporaryPath $path
    } on error {message options} {
        if {$channel ne ""} {
            catch {close $channel}
        }
        catch {file delete $temporaryPath}
        return -options $options $message
    }
}

oo::class create ::LATerm::AppearanceDialog {
    variable window initialSettings applyCallback saveCallback
    variable family size foreground background preset

    constructor {settings applyCommand saveCommand} {
        set initialSettings [::LATerm::Appearance::validate $settings]
        set applyCallback $applyCommand
        set saveCallback $saveCommand
        set family [dict get $initialSettings fontFamily]
        set size [dict get $initialSettings fontSize]
        set foreground [dict get $initialSettings foreground]
        set background [dict get $initialSettings background]
        set preset ""
        set window .appearance

        if {[winfo exists $window]} {
            destroy $window
        }
        toplevel $window
        wm title $window "Terminal Appearance"
        wm resizable $window 0 0
        wm transient $window .
        wm protocol $window WM_DELETE_WINDOW [list [self] cancel]

        ttk::frame $window.content -padding 12
        ttk::label $window.content.presetLabel -text "Preset"
        ttk::combobox $window.content.preset \
            -textvariable [namespace which -variable preset] \
            -state readonly \
            -values {"Dark" "Light" "Solarized Dark"}
        ttk::label $window.content.familyLabel -text "Font family"
        ttk::combobox $window.content.family \
            -textvariable [namespace which -variable family] \
            -state readonly \
            -values [lsort -dictionary [font families]]
        ttk::label $window.content.sizeLabel -text "Font size"
        spinbox $window.content.size \
            -from 6 -to 48 -width 6 \
            -textvariable [namespace which -variable size]
        ttk::label $window.content.foregroundLabel -text "Text color"
        ttk::button $window.content.foreground \
            -text "Choose..." -command [list [self] chooseColor foreground]
        ttk::label $window.content.backgroundLabel -text "Background"
        ttk::button $window.content.background \
            -text "Choose..." -command [list [self] chooseColor background]
        ttk::frame $window.buttons
        ttk::button $window.buttons.cancel -text "Cancel" \
            -command [list [self] cancel]
        ttk::button $window.buttons.apply -text "Apply" \
            -command [list [self] apply]
        ttk::button $window.buttons.save -text "Save" -default active \
            -command [list [self] save]

        grid $window.content.presetLabel -row 0 -column 0 -sticky w -pady 4
        grid $window.content.preset -row 0 -column 1 -sticky ew -pady 4
        grid $window.content.familyLabel -row 1 -column 0 -sticky w -pady 4
        grid $window.content.family -row 1 -column 1 -sticky ew -pady 4
        grid $window.content.sizeLabel -row 2 -column 0 -sticky w -pady 4
        grid $window.content.size -row 2 -column 1 -sticky w -pady 4
        grid $window.content.foregroundLabel -row 3 -column 0 -sticky w -pady 4
        grid $window.content.foreground -row 3 -column 1 -sticky ew -pady 4
        grid $window.content.backgroundLabel -row 4 -column 0 -sticky w -pady 4
        grid $window.content.background -row 4 -column 1 -sticky ew -pady 4
        grid columnconfigure $window.content 1 -weight 1
        pack $window.content -fill both -expand 1

        pack $window.buttons.cancel -side right -padx {4 0}
        pack $window.buttons.save -side right -padx {4 0}
        pack $window.buttons.apply -side right -padx {4 0}
        pack $window.buttons -fill x -padx 12 -pady {0 12}

        bind $window.content.preset <<ComboboxSelected>> \
            [list [self] applyPreset]
        bind $window <Escape> [list [self] cancel]
        bind $window <Return> [list [self] apply]
        focus $window.content.preset
    }

    method settings {} {
        return [::LATerm::Appearance::validate [dict create \
            fontFamily $family \
            fontSize $size \
            foreground $foreground \
            background $background]]
    }

    method applyPreset {} {
        switch -- $preset {
            Dark {
                set foreground "#e5e7eb"
                set background "#111827"
            }
            Light {
                set foreground "#202124"
                set background "#f5f5f5"
            }
            "Solarized Dark" {
                set foreground "#839496"
                set background "#002b36"
            }
        }
        my apply
    }

    method chooseColor {target} {
        set variableName [expr {
            $target eq "foreground" ? "foreground" : "background"
        }]
        set initialColor [set $variableName]
        set selected [tk_chooseColor \
            -parent $window \
            -initialcolor $initialColor]
        if {$selected ne ""} {
            set $variableName $selected
            my apply
        }
    }

    method apply {} {
        if {[catch {my settings} settings options]} {
            tk_messageBox -parent $window -icon error \
                -title "Invalid appearance" -message $settings
            return
        }
        if {[catch {uplevel #0 [list {*}$applyCallback $settings]} message]} {
            tk_messageBox -parent $window -icon error \
                -title "Could not apply appearance" -message $message
        }
    }

    method save {} {
        if {[catch {my settings} settings]} {
            tk_messageBox -parent $window -icon error \
                -title "Invalid appearance" -message $settings
            return
        }
        if {[catch {uplevel #0 [list {*}$applyCallback $settings]} message]} {
            tk_messageBox -parent $window -icon error \
                -title "Could not apply appearance" -message $message
            return
        }
        if {[catch {uplevel #0 [list {*}$saveCallback $settings]} message]} {
            tk_messageBox -parent $window -icon error \
                -title "Could not save appearance" -message $message
            return
        }
        destroy $window
        my destroy
    }

    method cancel {} {
        if {[catch {
            uplevel #0 [list {*}$applyCallback $initialSettings]
        } message]} {
            tk_messageBox -parent $window -icon error \
                -title "Could not restore appearance" -message $message
        }
        destroy $window
        my destroy
    }

    method window {} {
        return $window
    }

    destructor {
        if {[winfo exists $window]} {
            destroy $window
        }
    }
}