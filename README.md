# codetracer.el

Emacs front-end for [CodeTracer](https://github.com/metacraft-labs/codetracer),
the time-traveling debugger. It shows CodeTracer's panes (call trace, state,
event log, terminal output and the rest) in Emacs windows, binds CodeTracer's
keymaps in them, and marks the debugger's position and recorded values in your
source buffers.

The package is a view: the panes, their contents and the debugging session
live in CodeTracer's pane server (`codetracer-tui --pane-server`), which the
package starts and talks to over JSON-RPC on stdio (`jsonrpc.el`). A DAP
client such as dap-mode or dape can drive the same session through the
server's DAP endpoint.

Requires Emacs 29.1 or later. It uses only libraries Emacs ships:
`jsonrpc`, `tab-bar` and the window and overlay primitives.

## Use

Put `codetracer.el` on your `load-path` (or install the flake's package)
and make sure `codetracer-tui`, from a CodeTracer build, is on your `PATH`
or named by `codetracer-server-program`.

    M-x codetracer-open RET /path/to/recording RET

- Each recording is a session in a `tab-bar` tab of its own;
  `codetracer-switch-session` and the tab bar switch between them.
- The panes of the session's mode are placed in side windows through
  `display-buffer`, so your `display-buffer-alist` rules apply to them
  first. Resizing or closing a pane is kept in that mode's layout:
  switching to the other mode and back (`codetracer-toggle-mode`) brings
  your arrangement back.
- In a pane, the keys are your CodeTracer keymap's for that pane. Your own
  bindings in `codetracer-pane-user-map` (every pane) or
  `codetracer-pane-user-maps` (one pane) win over them; run
  `codetracer-report-user-bindings` after changing them so CodeTracer's
  keymap help shows what is really bound. A click or `RET` on a pane's
  active text (a call, an event, a value) runs what it offers.
- Every CodeTracer operation is a command: `codetracer-` and the
  operation's name, the dot replaced by a dash
  (`codetracer-debugger-step-over`); `codetracer-run-operation` picks one
  by name. The usual ones have short names: `codetracer-step-over`,
  `codetracer-step-into`, `codetracer-step-out`,
  `codetracer-reverse-step-over`, `codetracer-continue`,
  `codetracer-reverse-continue`.
- The source window follows the debugger. The execution line is
  highlighted with an arrow in the fringe, breakpoints and tracepoints are
  fringe marks, and recorded values are shown at the ends of lines.
- A source that is not on this disk is read from the recording into a
  read-only buffer; `codetracer-sources` opens any of the recording's
  sources.
- `codetracer-show-frames` shows the frames of a recording that carries
  graphics, drawn as images when Emacs can display them.
- The file tree is CodeTracer's file pane by default. Set
  `codetracer-panels-file-tree` to `editor` to use Emacs instead: a `dired`
  listing of the recording's sources takes the pane's place, and the files
  you select, open, create, rename and delete are reported to CodeTracer.
- Sessions survive a restart with `desktop-save-mode`: the recordings are
  opened again and their panes keep the windows you arranged, beside your
  own.
- `codetracer-dap-endpoint` names the pane server's DAP port, where a DAP
  client (dap-mode, dape) can attach and drive the same session.

## Development

`nix develop` (or `direnv allow`) gives a shell with Emacs and the
repository's hooks; then `just build`, `just test`, `just lint`.
`just test-server` runs the scenarios against a real pane server and
recording; the Justfile names the environment it needs.

Status: under development.

## License

Apache-2.0. See [LICENSE](LICENSE).
