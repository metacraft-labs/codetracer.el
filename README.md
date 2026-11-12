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
- Pane buffers are named `ct://SESSION/PANE` (`ct://1/calltrace`). A
  window showing one of several stacked panes lists them in its header
  line, the shown one highlighted; click a name to show that pane there.
- In a pane, the keys are your CodeTracer keymap's for that pane. Your own
  bindings in `codetracer-pane-user-map` (every pane) or
  `codetracer-pane-user-maps` (one pane) win over them; run
  `codetracer-report-user-bindings` after changing them so CodeTracer's
  keymap help shows what is really bound. A click or `RET` on a pane's
  active text (a call, an event, a value) runs what it offers.
- Every CodeTracer operation is a command: `codetracer-` and the
  operation's name, the dot replaced by a dash
  (`codetracer-debugger-step-over`); `codetracer-run-operation` picks one
  by name. The debugger's are defined as soon as the package loads, so you
  can bind them before a session is open, and have short names too:
  `codetracer-step-over`, `codetracer-step-into`, `codetracer-step-out`,
  their `codetracer-reverse-` counterparts, `codetracer-continue`,
  `codetracer-reverse-continue`, `codetracer-run-to-entry`,
  `codetracer-stop`, `codetracer-toggle-breakpoint` and
  `codetracer-toggle-tracepoint`.
- An operation the session cannot perform now (a disabled control, a test
  that is no longer listed) is refused, and the reason is shown in the echo
  area: `CodeTracer: tests.open-test: that test is no longer listed`.
- The debugger controls (reverse and forward Next, Step in, Step out and
  Continue, Run to entry, Stop) are drawn at the right of the tab bar while
  a session's tab is current: click one to run it. A control that cannot
  act now is dimmed and does nothing; hovering one shows its name and key.
  CodeTracer adds its item to `tab-bar-format` only when the format is
  Emacs's default, and gives the format back when the last session closes.
  With a format of your own, add `codetracer-tab-bar-controls` to it
  yourself, after `tab-bar-format-align-right`:

  ```elisp
  (setq tab-bar-format
        '(tab-bar-format-tabs
          tab-bar-separator
          tab-bar-format-align-right
          codetracer-tab-bar-controls))
  ```

  `codetracer-controls-glyphs` picks how a control is drawn (`unicode`,
  the default; `nerd`, for a Nerd Font; or `text`), and
  `codetracer-controls` set to nil draws none.

- In the session's source buffer, while its tab is current, the debugger
  keys of your CodeTracer keymap are bound -- stepping, continuing, the
  breakpoint and tracepoint toggles -- but only their function-key chords
  (`<f10>`, `S-<f11>`, `C-<f10>` ...), never a printable key or a `C-`
  letter, which are Emacs's own. They are a buffer-local minor mode,
  `codetracer-source-mode`, so `C-h k` and `C-h m` show them. A key you
  bind yourself, globally or in the buffer's modes, wins; only Emacs's own
  default function-key commands (F10's `menu-bar-open`, F11's
  `toggle-frame-fullscreen` ...) give way. Set `codetracer-source-keys` to
  nil to bind none.
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
- Edit mode works on a project: the directory the pane server started in,
  which is the `default-directory` of the buffer you ran `codetracer-open`
  from the first time (a remote one cannot be: the home directory is used
  then). Its Files pane lists that project, and its Test Results, Build
  Output and Problems panes run its tests and builds. To work on another
  project, `codetracer-quit` and open from a buffer in it.
- A recording CodeTracer makes for you -- a test recorded from the Test
  Results pane, a Nim compile-time trace -- opens as a session of its own,
  in a new tab, and the echo area says so. With the "current tab"
  placement it takes the place of the session it was made from, whose tab
  closes.
- A source file's tests -- the ones the Test Results pane lists -- are
  marked in the left fringe of their lines: a play mark, or the last
  verdict (passed, failed). Click a mark to record that test; its
  recording opens in a tab of its own. Ctrl+click records it in place of
  the current session instead. Clicks anywhere else, and in the text, are
  left alone. `codetracer-test-at-point` records the test point is in (the
  last one at or above it); with a prefix argument (`C-u`) the recording
  takes the current session's place. It has no default key: bind it. A
  test that cannot be recorded now (a build is running, say) says why in
  the echo area. Set `codetracer-tests-placement` to `above-line` for a
  `▶ Record <test>` button above each test instead of the fringe mark, or
  to `both`. The marks' faces are `codetracer-test-fringe`,
  `codetracer-test-passed-fringe` and `codetracer-test-failed-fringe`.
- In a Nim project, CodeTracer traces what the compiler runs: a macro's
  expansion, a `static:` block, a constant's evaluation, a NimScript run
  (`nim e`). With `context-menu-mode` on, right-click on the construct in
  a `.nim` or `.nims` buffer (or one in `nim-mode`) while a session is
  open: the CodeTracer submenu traces the macro, the static block or the
  constant at the click, or evaluates the file with `nim e`, and the
  recording opens as a session in a tab of its own; the session you
  traced from keeps its mode. The same operations are commands, at point:
  `codetracer-trace-macro-at-point`,
  `codetracer-trace-static-block-at-point`,
  `codetracer-trace-constant-at-point` and `codetracer-trace-eval`. Each
  reports point to CodeTracer before it runs, so it traces where you are.
  The trace reads the **saved** file: save the buffer first, or unsaved
  edits are not traced. It needs codetracer-nim -- its trace-enabled
  nimsuggest named by `CODETRACER_NIMSUGGEST` and its `nim` on `PATH`, in
  the environment the pane server starts in (`codetracer-server-environment`
  can set both) -- as CodeTracer's terminal does; without them the command
  says in the echo area what is missing.
- While debugging a native Nim recording, `codetracer-view-generated-c`
  shows the C the Nim line at point compiled to in the Low Level Code
  pane, and `codetracer-view-disassembly` shows the stop's machine code
  there. CodeTracer places the pane beside the source if the layout has
  none. Both are also in the Nim buffer's CodeTracer submenu. The C comes
  from the recording, which bundles a native Nim program's generated C
  files and maps each run of C back to its Nim line by the compiler's
  `#line` directives.
- `codetracer-dap-endpoint` names the pane server's DAP port, where a DAP
  client (dap-mode, dape) can attach and drive the same session.

## Development

`nix develop` (or `direnv allow`) gives a shell with Emacs and the
repository's hooks; then `just build`, `just test`, `just lint`.
`just test-server` runs the scenarios against a real pane server and
recording, and `just test-edit` records a test of a Noir crate from the
Test Results pane with the real `ct` and `nargo`, and `just test-nim`
traces a Nim static block from the context menu with codetracer-nim; the
Justfile names the environment they need.

Status: under development.

## License

Apache-2.0. See [LICENSE](LICENSE).
