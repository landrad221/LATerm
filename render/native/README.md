# Native Tk renderer

This X11 renderer provides `::LATerm::NativeRenderer`, a C-backed renderer
with the same `render`, `renderDirty`, `updateCursor`, `statistics`, and
`resetStatistics` methods as `::LATerm::TkRenderer`. It creates a native Tk
window; ask for its Tk path with `$renderer widget` and pack that window to
display it. The optional third constructor argument is a Tk font description,
for example `{{DejaVu Sans Mono} 11}`.

The renderer draws terminal cell backgrounds, foreground text, bold/italic
font variants, underlines, wide glyphs, and a block/underline/bar cursor
directly into its Tk window, including cursor blinking.
LATerm can use the native renderer with `LATerm_RENDERER=native wish main.tcl`.
The native backend inherits the default foreground and background colors
from the `.terminal` Text widget configuration so existing Tk themes remain
consistent. The default renderer remains `LATerm_RENDERER=text`. The native
backend supports keyboard input, focus reporting, terminal mouse reporting,
resize, mouse selection, and Ctrl+Shift+C clipboard copying. It does not
provide Text widget semantics such as Tk's native selection export or text
indexing.

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
```

The benchmark script compares the native renderer with the existing Tk Text
renderer when the extension has been built.
