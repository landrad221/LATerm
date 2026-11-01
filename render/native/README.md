# Native Tk renderer

LATerm uses the native renderer as its only application backend. It is
X11-based, so on Wayland desktops it requires Tk to run through XWayland.
Build the extension before launching LATerm:

```sh
cmake -S render/native -B /tmp/laterm-native-build \
  -DCMAKE_BUILD_TYPE=Release
cmake --build /tmp/laterm-native-build
wish main.tcl
```

Open **Settings → Appearance** (or press **Ctrl+,**) to change the font,
text color, and background. Apply previews changes immediately; Save stores
them in `$XDG_CONFIG_HOME/laterm/appearance.conf`, or
`$HOME/.config/laterm/appearance.conf` when `XDG_CONFIG_HOME` is unset.
Cancel restores the appearance that was active when the dialog opened.
Scroll through retained output with the mouse wheel; **Shift+PageUp** and
**Shift+PageDown** move by one screen. Scrolling returns to live output at
the newest row.

This X11 renderer provides `::LATerm::NativeRenderer`, a C-backed renderer
with `render`, `renderDirty`, `updateCursor`, `statistics`, and
`resetStatistics` methods, plus `configureAppearance` for runtime font and
color changes. It creates a native Tk window; ask for its Tk path
with `$renderer widget` and pack that window to display it. The optional third
constructor argument is a Tk font description, for example
`{{DejaVu Sans Mono} 11}`.

The renderer draws terminal cell backgrounds, foreground text, bold/italic
font variants, underlines, wide glyphs, and a block/underline/bar cursor
directly into its Tk window, including cursor blinking.
The native backend supports keyboard input, focus reporting, terminal mouse
reporting, resize, mouse selection, and Ctrl+Shift+C clipboard copying. It
does not provide Text widget semantics such as Tk's native selection export
or text indexing.

Example:

```tcl
lappend auto_path [file join [file dirname [info script]] render native]
package require laterm_native_renderer
source render/screen.tcl

set screen [::LATerm::Screen new 24 80]
set renderer [::LATerm::NativeRenderer new .nativeTerminal $screen]
pack [$renderer widget] -fill both -expand 1
```

## Build

Requirements are Tcl/Tk 8.6 development headers, CMake, and a C compiler.
From the repository root:

```sh
cmake -S render/native -B /tmp/laterm-native-build \
  -DCMAKE_BUILD_TYPE=Release
cmake --build /tmp/laterm-native-build
```

The build produces `render/native/liblaterm_renderer.so`. The shared library
is ignored by Git; remove it after testing if you do not want the built
extension in the worktree.

## Test and benchmark

Run the native renderer tests with:

```sh
tclsh tests/native_renderer.test
tclsh tests/appearance_dialog.test
```

Run the native renderer benchmark with:

```sh
wish tests/native_renderer_benchmark.tcl
```
