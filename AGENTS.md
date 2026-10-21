# Agent Guide

This repository is an editor front-end for CodeTracer. It renders what
CodeTracer's pane server sends and forwards the editor's input; it holds no
debugger logic of its own. The protocol is documented in the CodeTracer
repository (the pane server lives in `src/frontend/tui/host/pane_server.nim`,
its message types in `src/frontend/tui/app/pane_protocol.nim`).

- Write commit messages in the Conventional Commits style; keep them
  user-facing (this repository is public).
- Do not add assistant-attribution trailers to commits or pull requests.
- Feature work lands on `agents`; `dev` is the mainline, `stable` carries
  releases.
