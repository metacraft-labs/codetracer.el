# codetracer.el — task entry points.
#
# Every recipe assumes the dev shell (`nix develop`, or `direnv allow`), which
# provides Emacs and nixfmt.
#
# `test-server` drives a real CodeTracer pane server over a real recording,
# and needs both:
#   CODETRACER_TUI         the `codetracer-tui` binary (a CodeTracer build)
#   CODETRACER_TEST_TRACE  a recording's folder (CodeTracer's `calc` test
#                          program is the one the suite is written against)
#   REPLAY_SERVER_BIN      the replay server, when it is not where
#                          `codetracer-tui` looks for it by default
# The frame viewer's case also needs a recording with graphics:
#   CODETRACER_CT_GFX_PLAYER_CMD  the visual replay player (`ct_gfx_player`),
#                                 with a licence that allows Visual Replay in
#                                 its environment (`ct-native-replay license
#                                 generate-visual-replay-test-license` writes
#                                 a test one)
#   CODETRACER_TEST_GFX_STREAM    a gfx stream to give the recording graphics,
#                                 e.g. codetracer-visual-replay's
#                                 tests/corpus_phase1/mpv
# Without them it fails, by design: a suite that skipped would pass with no
# server at all.

set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

alias t := test
alias fmt := format

emacs := "emacs --batch -Q -L . -L test"

# Byte-compile the package; a warning is an error.
build:
    {{emacs}} --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile codetracer.el

# The suites that need no pane server, after a clean compile.
test: build test-unit

test-unit:
    {{emacs}} -l test/codetracer-test.el --eval '(ert-run-tests-batch-and-exit (quote (tag unit)))'

# The package against a real pane server and recording (see above).
test-server:
    {{emacs}} -l test/codetracer-test.el --eval '(ert-run-tests-batch-and-exit (quote (tag server)))'

lint: lint-elisp lint-nix

# checkdoc on the package's documentation; byte-compiling is `build`.
lint-elisp: build
    {{emacs}} -l scripts/checkdoc.el

lint-nix:
    nixfmt --check flake.nix

format: format-nix

format-nix:
    nixfmt flake.nix

clean:
    rm -f *.elc test/*.elc
