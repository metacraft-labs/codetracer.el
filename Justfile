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
#
# `test-edit` records the tests of a two-test Noir crate from the Test
# Results pane and from their lines in the source (the fringe marks and
# `codetracer-test-at-point`), and checks each recording opens in a tab of
# its own, or in place of the session it was made from. Besides the
# variables above (CODETRACER_TUI, CODETRACER_TEST_TRACE) it needs the real
# recorder:
#   CT_BIN                 the `ct` binary, when it is not on PATH
#   nargo                  on PATH (the crate is a Noir one)
#
# `test-nim` traces the static block of PLAT-65's tracing.nim from the
# context menu of a Nim buffer, and checks the recording opens in a tab of
# its own. Besides CODETRACER_TUI and CODETRACER_TEST_TRACE it needs
# codetracer-nim (CodeTracer's dev shell provides both):
#   CODETRACER_NIMSUGGEST  its trace-enabled nimsuggest
#   nim                    its compiler, on PATH
#
# `test-native` shows a Nim line's generated C and the stop's disassembly in
# the Low Level Code pane, over CodeTracer's native Nim example recording.
# Besides CODETRACER_TUI it needs:
#   CODETRACER_TEST_NATIVE_NIM_TRACE  codetracer-example-recordings/nim/flow_test
#   CODETRACER_CT_NATIVE_REPLAY_CMD   the native backend (`ct-native-replay`)

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

# Edit-mode services: a test recorded from Test Results opens as a session
# of its own (see above).
test-edit:
    {{emacs}} -l test/codetracer-test.el --eval '(ert-run-tests-batch-and-exit (quote (tag edit)))'

# Nim compile-time tracing from the context menu (see above).
test-nim:
    {{emacs}} -l test/codetracer-test.el --eval '(ert-run-tests-batch-and-exit (quote (tag nim)))'

# A Nim line's generated C, from a native recording (see above).
test-native:
    {{emacs}} -l test/codetracer-test.el --eval '(ert-run-tests-batch-and-exit (quote (tag native)))'

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
