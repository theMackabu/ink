# ink 🖋️

A tiny, fast markdown renderer for your terminal. Written in Zig.

Parses markdown and renders it with beautiful ANSI colors, syntax highlighting, and even a built-in TUI viewer.

## Usage

```
ink file.md            # render to terminal
ink --view file.md     # open in TUI viewer
ink --watch file.md    # re-render on file changes
ink --json file.md     # dump the AST as JSON
ink --timing file.md   # show parse speed
```

## Features

- Headings, **bold**, _italic_, `inline code`, and fenced code blocks with syntax highlighting
- Links, blockquotes, ordered/unordered lists, task lists, tables
- GitHub-style callouts (note, tip, warning, caution, important)
- Horizontal rules and line breaks
- TUI viewer with scrolling, search, and file watching
- JSON AST output

## Building

Requires [Zig](https://ziglang.org) (0.15.x).

```sh
zig build                  # build
zig build run -- file.md   # build & run
zig build install-local    # install to ~/.local/bin
```
