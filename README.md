# LATerm

LATerm is a terminal emulator written in Tcl/Tk with a native C renderer.
It runs an interactive shell inside a pseudo-terminal (PTY). The renderer
uses X11, including through XWayland on Wayland desktops.

## Features

- Native rendering of terminal cells, colors, bold/italic text, underlines,
  wide characters, and cursor styles.
- Keyboard input, terminal mouse reporting, window resizing, and text
  selection.
- Scrollback with mouse-wheel navigation and **Shift+PageUp** /
  **Shift+PageDown**.
- Appearance dialog for changing font family, font size, foreground, and
  background, with Dark, Light, and Solarized Dark presets.
- Ctrl+Shift+C and Ctrl+Shift+V for copying and pasting.

## Requirements

- Linux with X11, or Wayland with XWayland available.
- Tcl/Tk 8.6.
- CMake and a C compiler.
- Tcl/Tk development headers and X11 development libraries.

LATerm uses the [`pty`](./pty) Git submodule. Clone the repository with
submodules enabled:

```sh
git clone --recurse-submodules https://github.com/landrad221/LATerm.git
cd LATerm
```

If you already cloned without submodules, initialize it with:

```sh
git submodule update --init --recursive
```

## Build and run

Build the PTY extension and install it into a local build directory:

```sh
cmake -S pty -B build/pty
cmake --build build/pty
cmake --install build/pty --prefix "$PWD/build/pty-install"
```

Build the native renderer:

```sh
cmake -S render/native -B build/native -DCMAKE_BUILD_TYPE=Release
cmake --build build/native
```

Start LATerm from the repository root:

```sh
TCLLIBPATH="$PWD/build/pty-install/lib/pty-tcl0.1" wish main.tcl
```

The renderer library is built at `render/native/liblaterm_renderer.so`.
Rebuild it after changing the C renderer. Run `wish main.tcl` from the
repository root so application scripts and assets are resolved correctly.

## Using LATerm

- **Settings → Appearance**, or **Ctrl+,**: open appearance settings.
- **Apply** previews appearance changes; **Save** persists them; **Cancel**
  restores the appearance active when the dialog opened.
- **Mouse wheel**: scroll through retained output. Scroll to the newest row
  to return to live output.
- **Shift+PageUp / Shift+PageDown**: move through scrollback by one screen.
- **Ctrl+Shift+C / Ctrl+Shift+V**: copy the current selection / paste from
  the clipboard.

Appearance settings are stored in
`$XDG_CONFIG_HOME/laterm/appearance.conf`, or
`$HOME/.config/laterm/appearance.conf` if `XDG_CONFIG_HOME` is unset.
The screen model retains up to 1,000 scrollback rows by default.

## Tests

Run the Tcl test suite from the repository root:

```sh
bash tests/run.sh
```

Tk-dependent renderer and appearance tests need a graphical display. The
native renderer tests also require the renderer library to have been built.
For renderer-specific build and benchmark details, see
[`render/native/README.md`](./render/native/README.md).

## Platform notes

The native renderer currently targets X11. On Wayland, LATerm needs XWayland
and a Tk build capable of using it. Other window-system backends are not
currently supported by the native renderer.
