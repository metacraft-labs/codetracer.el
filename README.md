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

Status: under development.

## License

Apache-2.0. See [LICENSE](LICENSE).
