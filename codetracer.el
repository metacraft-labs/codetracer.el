;;; codetracer.el --- CodeTracer's panes, keymaps and source marks in Emacs  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Metacraft Labs

;; Author: Metacraft Labs <info@metacraft-labs.com>
;; Maintainer: Metacraft Labs <info@metacraft-labs.com>
;; URL: https://github.com/metacraft-labs/codetracer.el
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (jsonrpc "1.0.16"))
;; Keywords: debugging, tools, processes
;; SPDX-License-Identifier: Apache-2.0

;; Licensed under the Apache License, Version 2.0 (the "License");
;; you may not use this file except in compliance with the License.
;; You may obtain a copy of the License at
;;
;;     http://www.apache.org/licenses/LICENSE-2.0
;;
;; Unless required by applicable law or agreed to in writing, software
;; distributed under the License is distributed on an "AS IS" BASIS,
;; WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
;; See the License for the specific language governing permissions and
;; limitations under the License.

;;; Commentary:

;; CodeTracer is a time-traveling debugger.  This package shows its panes
;; (call trace, state, event log, terminal output, ...) in Emacs windows,
;; binds CodeTracer's keymaps in them, and marks the debugger's position and
;; the recorded values in your source buffers.
;;
;; The package is a view.  The debugging session, the panes' contents and
;; their layouts live in CodeTracer's pane server, `codetracer-tui
;; --pane-server', which this package starts as a child process and speaks
;; to with JSON-RPC 2.0 over stdio (the LSP base protocol's framing, through
;; the built-in `jsonrpc' library).  The protocol is documented with the
;; server, in the CodeTracer repository; this package implements version 1.
;;
;; Start with `M-x codetracer-open' and a recording.  Each recording opened
;; is a session in a `tab-bar' tab of its own.  The panes of the session's
;; current mode (debug or edit) are placed in side windows, with
;; `display-buffer', so the rules in your `display-buffer-alist' apply to
;; them first.  Resizing or closing a pane is reported to the server, which
;; keeps it in that mode's layout.
;;
;; In a pane buffer the keys are CodeTracer's: the server sends the bindings
;; of your shared CodeTracer keymap, and they are installed buffer-locally.
;; A binding you make yourself, in `codetracer-pane-user-map' or in a pane's
;; entry of `codetracer-pane-user-maps', wins over CodeTracer's and is
;; reported to the server, so CodeTracer's keymap help shows what is really
;; bound.  Every CodeTracer operation is also an `M-x' command named
;; `codetracer-' followed by the operation's name, with the dot replaced by
;; a dash (`codetracer-debugger-step-over').
;;
;; While a session's tab is current, the debugger controls are drawn at the
;; right of the tab bar (`codetracer-tab-bar-controls'), and the debugger's
;; function keys of your CodeTracer keymap are bound in the session's source
;; buffer (`codetracer-source-mode'), your own bindings first.  A recording
;; CodeTracer makes itself, such as a test recorded from the Test Results
;; pane, opens in a tab of its own; so does a test recorded from its line in
;; the source, where its fringe mark records it (`codetracer-test-at-point'
;; is the keyboard's way).  Edit mode works on the directory the
;; pane server was started in: the `default-directory' of the buffer the
;; first session was opened from.  In a Nim buffer, the context menu
;; (`context-menu-mode') and `codetracer-trace-static-block-at-point' and
;; its siblings trace what the compiler runs at point -- a macro, a static
;; block, a constant, a `nim e' evaluation -- over the saved file, and the
;; recording opens in a tab of its own.

;;; Code:

(require 'cl-lib)
(require 'jsonrpc)
(require 'tab-bar)
(require 'subr-x)
(require 'dired)
(require 'filenotify)

(defvar desktop-save-buffer)
(defvar desktop-buffer-mode-handlers)

(defgroup codetracer nil
  "CodeTracer, the time-traveling debugger, in Emacs."
  :group 'tools
  :prefix "codetracer-")

(defconst codetracer-protocol-version 1
  "The pane server protocol version this package speaks.")

(defcustom codetracer-server-program "codetracer-tui"
  "The CodeTracer terminal front-end binary, which carries the pane server."
  :type 'string)

(defcustom codetracer-server-arguments '("--pane-server")
  "Arguments that start `codetracer-server-program' as a pane server."
  :type '(repeat string))

(defcustom codetracer-server-environment nil
  "Extra environment entries for the pane server, as \"NAME=VALUE\" strings."
  :type '(repeat string))

(defcustom codetracer-panels-file-tree 'codetracer
  "Who fills the file-tree role: CodeTracer's file pane, or Emacs.
With `editor', the file tree's place in a layout shows a `dired'
listing of the recording's sources (the files it recorded, read-only
copies of those not on this disk), and opening, selecting, creating,
renaming and deleting files in Emacs is reported to CodeTracer as its
own file pane reports them."
  :type '(choice (const :tag "CodeTracer's file pane" codetracer)
                 (const :tag "Emacs (dired)" editor)))

(defcustom codetracer-request-timeout 120
  "Seconds to wait for the pane server to answer a request."
  :type 'number)

(defcustom codetracer-media nil
  "The media this Emacs takes from the pane server (`initialize').
Nil means all it can draw: text, and images when `display-images-p'."
  :type '(choice (const :tag "All this Emacs can draw" nil)
                 (repeat string)))

(defun codetracer--media ()
  "The media to declare at `initialize'."
  (or codetracer-media
      (if (display-images-p) '("text" "image") '("text"))))

(defcustom codetracer-controls 'tab-bar
  "Where the debugger controls are drawn while a session's tab is current.
With `tab-bar', they are drawn at the right of the tab bar: while a
session is open, `codetracer-tab-bar-controls' is added to
`tab-bar-format' after `tab-bar-format-align-right', and the format is
given back when the last session closes.  That is done only when
`tab-bar-format' is Emacs's default; a format of your own is left
alone, and you add `codetracer-tab-bar-controls' to it where you want
the controls.  With nil, the controls are not drawn."
  :type '(choice (const :tag "At the right of the tab bar" tab-bar)
                 (const :tag "Nowhere" nil)))

(defcustom codetracer-controls-glyphs 'unicode
  "How a debugger control is drawn.
As its `unicode' symbol, its `nerd' Font icon (Codicons), or its
`text' label."
  :type '(choice (const :tag "Unicode symbols" unicode)
                 (const :tag "Nerd Font icons" nerd)
                 (const :tag "Text labels" text)))

(defcustom codetracer-source-keys t
  "Non-nil binds CodeTracer's debugger keys in the session's source buffer.
They are the function-key bindings (F10, S-<f11>, C-<f10> ...) of the
debugger operations in your CodeTracer keymap, bound while the
session's tab is current, by `codetracer-source-mode'.  A key bound
anywhere else in that buffer -- your global map, the major mode's map,
another minor mode -- is left to that binding; only Emacs's own
default function-key commands (F10's `menu-bar-open', F11's
`toggle-frame-fullscreen', ...) give way."
  :type 'boolean)

(defcustom codetracer-tests-placement 'gutter
  "Where a test's control is drawn in the source.
The tests are the ones CodeTracer's Test Results pane lists for the
file.  `gutter' puts a mark in the left fringe of the test's line: a
play mark, or the test's last verdict; click it to record the test
\(Ctrl+click: in place of the current session).  `above-line' puts a
line reading \"▶ Record NAME\" above the test instead, a button that
records it; `both' draws both."
  :type '(choice (const :tag "A fringe mark on the test's line" gutter)
                 (const :tag "A button line above the test" above-line)
                 (const :tag "Both" both)))

;;;; Faces

(defface codetracer-chrome '((t :inherit default))
  "CodeTracer pane text.")
(defface codetracer-chrome-muted '((t :inherit shadow))
  "Secondary text in CodeTracer panes.")
(defface codetracer-chrome-title '((t :inherit bold))
  "Titles in CodeTracer panes.")
(defface codetracer-chrome-error '((t :inherit error))
  "Errors in CodeTracer panes.")
(defface codetracer-chrome-success '((t :inherit success))
  "Successes in CodeTracer panes.")
(defface codetracer-chrome-info '((t :inherit font-lock-doc-face))
  "Information in CodeTracer panes.")
(defface codetracer-chrome-accent '((t :inherit link))
  "Accented text in CodeTracer panes.")
(defface codetracer-call-args '((t :inherit font-lock-variable-name-face))
  "Call arguments in the call trace.")
(defface codetracer-call-return '((t :inherit font-lock-constant-face))
  "Return values in the call trace.")
(defface codetracer-value '((t :inherit font-lock-constant-face))
  "Recorded values.")
(defface codetracer-value-string '((t :inherit font-lock-string-face))
  "Recorded string values.")
(defface codetracer-value-modified '((t :inherit warning))
  "A value the step that produced the current stop changed.")
(defface codetracer-value-error '((t :inherit error))
  "A value that could not be read.")
(defface codetracer-active-row '((t :inherit hl-line))
  "The active row of a list, such as the call the debugger is in.")
(defface codetracer-selection '((t :inherit region))
  "The selected row of a list.")
(defface codetracer-event '((t :inherit font-lock-function-name-face))
  "Event kinds in the event log.")
(defface codetracer-mark '((t :inherit font-lock-keyword-face))
  "Marks on scrollbars and timelines.")
(defface codetracer-execution-line '((t :inherit highlight))
  "The source line the debugger is stopped on.")
(defface codetracer-inline-value '((t :inherit shadow :slant italic))
  "Values shown at the end of a source line.")
(defface codetracer-flow-value '((t :inherit font-lock-comment-face))
  "Flow values shown at the end of a source line.")
(defface codetracer-breakpoint-fringe '((t :inherit error))
  "The fringe mark of a breakpoint.")
(defface codetracer-tracepoint-fringe '((t :inherit warning))
  "The fringe mark of a tracepoint.")
(defface codetracer-execution-fringe '((t :inherit success))
  "The fringe arrow on the execution line.")
(defface codetracer-test-fringe '((t :inherit font-lock-function-name-face))
  "The fringe mark of a test not yet run, and the above-line button.")
(defface codetracer-test-passed-fringe '((t :inherit success))
  "The fringe mark of a test whose last run passed.")
(defface codetracer-test-failed-fringe '((t :inherit error))
  "The fringe mark of a test whose last run failed.")
(defface codetracer-stack-tab '((t :inherit shadow))
  "The name of a stacked pane its window does not show, in the window's tabs.")
(defface codetracer-stack-tab-active '((t :inherit (highlight bold)))
  "The name of the stacked pane its window shows, in the window's tabs.")
(defface codetracer-control '((t :inherit tab-bar))
  "A debugger control in the tab bar.")
(defface codetracer-control-disabled '((t :inherit (shadow tab-bar)))
  "A debugger control that cannot act now, in the tab bar.")

(defcustom codetracer-style-faces
  '(("chrome-text" . codetracer-chrome)
    ("editor-text" . codetracer-chrome)
    ("chrome-muted" . codetracer-chrome-muted)
    ("chrome-title" . codetracer-chrome-title)
    ("chrome-title-focused" . codetracer-chrome-title)
    ("chrome-notification" . codetracer-chrome-info)
    ("chrome-error" . codetracer-chrome-error)
    ("chrome-success" . codetracer-chrome-success)
    ("chrome-info" . codetracer-chrome-info)
    ("chrome-accent" . codetracer-chrome-accent)
    ("chrome-prompt" . minibuffer-prompt)
    ("call-args" . codetracer-call-args)
    ("call-return" . codetracer-call-return)
    ("value-modified" . codetracer-value-modified)
    ("value-string" . codetracer-value-string)
    ("value-error" . codetracer-value-error)
    ("surface-active-row" . codetracer-active-row)
    ("surface-selection" . codetracer-selection)
    ("surface-current-line" . codetracer-active-row)
    ("line-execution" . codetracer-execution-line)
    ("line-search-match" . isearch)
    ("line-not-taken" . shadow)
    ("gutter-breakpoint" . codetracer-breakpoint-fringe)
    ("gutter-tracepoint" . codetracer-tracepoint-fringe)
    ("gutter-execution-pointer" . codetracer-execution-fringe)
    ("scrubber-mark" . codetracer-mark)
    ("timeline-mark" . codetracer-mark)
    ("timeline-needle" . codetracer-mark)
    ("syntax-keyword" . font-lock-keyword-face)
    ("syntax-keyword-type" . font-lock-type-face)
    ("syntax-type" . font-lock-type-face)
    ("syntax-type-identifier" . font-lock-type-face)
    ("syntax-string" . font-lock-string-face)
    ("syntax-string-escape" . font-lock-escape-face)
    ("syntax-regexp" . font-lock-regexp-face)
    ("syntax-number" . font-lock-number-face)
    ("syntax-comment" . font-lock-comment-face)
    ("syntax-comment-doc" . font-lock-doc-face)
    ("syntax-operator" . font-lock-operator-face)
    ("syntax-punctuation" . font-lock-punctuation-face)
    ("syntax-bracket" . font-lock-bracket-face)
    ("syntax-variable" . font-lock-variable-name-face)
    ("syntax-identifier" . font-lock-variable-use-face)
    ("syntax-namespace" . font-lock-constant-face)
    ("syntax-attribute-name" . font-lock-property-name-face)
    ("syntax-tag" . font-lock-function-name-face)
    ("syntax-metatag" . font-lock-preprocessor-face))
  "Faces for the pane server's semantic styles.
Each entry maps a style's role (the style name without its \"ct.\"
prefix) to a face.  A role missing here is drawn by family: values
in `codetracer-value', events in `codetracer-event', and anything
else unstyled."
  :type '(alist :key-type string :value-type face))

(defun codetracer--style-face (style)
  "The face for the semantic STYLE (\"ct.<role>\"), or nil."
  (when (and (stringp style) (string-prefix-p "ct." style))
    (let ((role (substring style 3)))
      (or (cdr (assoc role codetracer-style-faces))
          (cond ((string-prefix-p "value-" role) 'codetracer-value)
                ((string-prefix-p "event-" role) 'codetracer-event)
                ((string-prefix-p "category-" role) 'codetracer-chrome-muted)
                ((string-prefix-p "frame-" role) 'codetracer-chrome-muted))))))

;;;; State

(cl-defstruct (codetracer-session (:constructor codetracer--make-session)
                                  (:copier nil))
  "One recording open in the pane server."
  id trace title mode layout tab graphics realized sources watches
  (panes (make-hash-table :test #'equal))
  position
  (decorations (make-hash-table :test #'equal))
  ;; A sizes-only `layout/edited' awaits its answer, and the windows were
  ;; resized again meanwhile (see `codetracer--report-layout').
  reporting sizes-dirty
  ;; The stacked panes the user picked from a window's tabs, as
  ;; (MODE . STACK-PATH) -> child index: the server's layouts do not carry
  ;; them, so they are applied to each layout it sends.
  (stack-choices (make-hash-table :test #'equal))
  ;; The debugger controls (`controls/state' buttons, as plists) and the
  ;; source buffer's keys, (EMACS-KEY . OPERATION) from the `editor' pane's
  ;; keymap.
  controls source-bindings
  ;; The `source/tests' controls, as lists of plists, by the file's
  ;; `codetracer--test-file-key'.
  (tests (make-hash-table :test #'equal)))

(defvar codetracer--connection nil
  "The `jsonrpc-process-connection' to the pane server, or nil.")

(defvar codetracer--server-info nil
  "The pane server's `initialize' result, as a plist.")

(defvar codetracer--sessions (make-hash-table)
  "The open sessions, by id.")

(defvar codetracer--active-session nil
  "The id of the session the server considers active.")

(defvar codetracer--operations nil
  "The pane server's operation catalogue (`operations/list').")

(defvar codetracer--early-positions (make-hash-table)
  "Positions that arrived before their session was registered, by id.
`session/open' is answered first and followed by the session's position,
which the process filter can dispatch before `codetracer-open' resumes.")

(defvar codetracer--early-notifications (make-hash-table)
  "Notifications for a session not registered yet, by id, newest first.
Like its position, a session's keymaps and controls follow the answer to
`session/open'; they are dispatched once the session is registered.")

(defvar codetracer--window-change-timer nil
  "The pending timer that reports window changes, or nil.")

(defvar codetracer--realizing nil
  "Non-nil while this package itself is changing windows.
Window changes made then are not the user's edits.")

(defvar codetracer--reported-shadowed nil
  "The editor bindings last reported to the server, as an alist.")

(defvar-local codetracer--pane nil
  "In a pane buffer, the pane it shows (its wire name).")

(defvar-local codetracer--pane-session nil
  "In a pane buffer, the id of the session it belongs to.")

(defvar-local codetracer--pane-size nil
  "In a pane buffer, the (WIDTH . HEIGHT) last sent to the server.")

(defvar-local codetracer--pane-resizing nil
  "In a pane buffer, non-nil while a `pane/resize' awaits its answer.")

(defvar-local codetracer--pane-open nil
  "In a pane buffer, non-nil once the server was told it is open.")

(defvar-local codetracer--server-map nil
  "In a pane buffer, the keymap of the server's bindings.")

(defvar-local codetracer--recorded-path nil
  "In a buffer holding a recorded source, the source's path.")

(defvar-local codetracer--role nil
  "In a buffer Emacs fills a CodeTracer role with, the role's name.")

(defvar-local codetracer--image nil
  "In a pane buffer, the image its last `pane/content' carried, or nil.")

(defvar-local codetracer--image-spec nil
  "In a pane buffer, the last `pane/content' image: its size and frame.")

(defvar-local codetracer--restored nil
  "In a pane buffer `desktop' restored, what it saved about its session.")

;;;; Transport

(defun codetracer--live-p ()
  "Non-nil when the pane server is running."
  (and codetracer--connection (jsonrpc-running-p codetracer--connection)))

(defun codetracer--connection ()
  "The connection to the pane server; an error when there is none."
  (unless (codetracer--live-p)
    (user-error "CodeTracer is not running; start it with `codetracer-open'"))
  codetracer--connection)

(defun codetracer--request (method &optional params)
  "Send METHOD with PARAMS to the pane server and return its result."
  (jsonrpc-request (codetracer--connection) method (or params '())
                   :timeout codetracer-request-timeout))

(defun codetracer--send (method &optional params on-result on-failure)
  "Send METHOD with PARAMS without waiting; ON-RESULT receives its result.
ON-FAILURE, when given, is called with no argument when the request
fails or times out instead.  Return non-nil when the request was sent.
For requests made from notification handlers, hooks and timers:
`jsonrpc' dispatches the server's messages from timers, and a request
that waited there could run while another waits, out of order."
  (when (codetracer--live-p)
    (jsonrpc-async-request codetracer--connection method (or params '())
                           :success-fn (or on-result #'ignore)
                           :error-fn (lambda (err)
                                       (message "CodeTracer: %s failed: %s"
                                                method (plist-get err :message))
                                       (when on-failure (funcall on-failure)))
                           :timeout-fn (lambda ()
                                         (message "CodeTracer: %s timed out" method)
                                         (when on-failure (funcall on-failure)))
                           :timeout codetracer-request-timeout)
    t))

(defun codetracer--notify (method &optional params)
  "Send the notification METHOD with PARAMS to the pane server."
  (jsonrpc-notify (codetracer--connection) method (or params '())))

(defun codetracer--server-directory ()
  "The directory to start the pane server in: the current `default-directory'.
The server's Edit mode works on the project it starts in, as `ct
replay' works on the shell's, so this is the directory of the buffer
the first session is opened from.  A remote or missing directory cannot
be a local process's: the home directory is used then."
  (let ((dir default-directory))
    (if (and (stringp dir) (not (file-remote-p dir)) (file-directory-p dir))
        (expand-file-name dir)
      (expand-file-name "~/"))))

(defun codetracer--start-server ()
  "Start the pane server, in `codetracer--server-directory', and initialize it."
  (let* ((default-directory (codetracer--server-directory))
         (process-environment (append codetracer-server-environment
                                      process-environment))
         (stderr (get-buffer-create " *codetracer stderr*"))
         (proc (make-process
                :name "codetracer"
                :command (cons codetracer-server-program
                               codetracer-server-arguments)
                :connection-type 'pipe
                :coding 'utf-8-emacs-unix
                :noquery t
                :stderr stderr)))
    (setq codetracer--connection
          (make-instance 'jsonrpc-process-connection
                         :name "codetracer"
                         :process proc
                         :events-buffer-config '(:size 2000000 :format full)
                         :notification-dispatcher #'codetracer--dispatch
                         :request-dispatcher #'codetracer--server-request
                         :on-shutdown #'codetracer--on-shutdown))
    (let ((info (codetracer--request
                 :initialize
                 `(:capabilities
                   (:media ,(vconcat (codetracer--media))
                           :tabs t :mouseResize t)
                   :keymapOverrides ,(codetracer--overrides-vector)))))
      (unless (eql (plist-get info :protocolVersion) codetracer-protocol-version)
        (jsonrpc-shutdown codetracer--connection)
        (setq codetracer--connection nil)
        (error "CodeTracer: the pane server speaks protocol %s; this package speaks %s"
               (plist-get info :protocolVersion) codetracer-protocol-version))
      (setq codetracer--server-info info
            codetracer--reported-shadowed (codetracer--user-shadowed))
      (setq codetracer--operations (append (codetracer--request :operations/list) nil))
      (codetracer--define-operation-commands)
      (codetracer--install-hooks)
      info)))

(defun codetracer--server-request (_conn method _params)
  "The pane server sends no requests; refuse METHOD."
  (jsonrpc-error :code -32601 :message (format "unknown method %s" method)))

(defun codetracer--on-shutdown (_conn)
  "Forget the server's state once its process has ended."
  (setq codetracer--connection nil
        codetracer--server-info nil
        codetracer--active-session nil)
  (clrhash codetracer--sessions)
  (clrhash codetracer--early-notifications)
  (codetracer--render-all-tests)
  (codetracer--sync-source-keys)
  (codetracer--sync-controls)
  (codetracer--remove-hooks))

(defun codetracer--dispatch (_conn method params)
  "Handle the server's notification METHOD with PARAMS."
  (if (and (memq method '(pane/keymap controls/state source/tests))
           (not (codetracer--session (plist-get params :session))))
      (push (cons method params)
            (gethash (plist-get params :session) codetracer--early-notifications))
    (pcase method
      ('pane/content (codetracer--on-pane-content params))
      ('pane/keymap (codetracer--on-pane-keymap params))
      ('layout/changed (codetracer--on-layout-changed params))
      ('session/position (codetracer--on-position params))
      ('source/decorations (codetracer--on-decorations params))
      ('source/show (codetracer--on-source-show params))
      ('session/opened (codetracer--on-session-opened params))
      ('controls/state (codetracer--on-controls-state params))
      ('source/tests (codetracer--on-source-tests params))
      (_ nil))))

;;;; Sessions and tabs

(defun codetracer--session (id)
  "The session ID, or nil."
  (gethash id codetracer--sessions))

(defun codetracer--tab-name (session)
  "The tab-bar tab name of SESSION."
  (format "CodeTracer %s: %s" (codetracer-session-id session)
          (codetracer-session-title session)))

(defun codetracer--current-tab-session ()
  "The session whose tab is the current one, or nil."
  (let ((name (alist-get 'name (tab-bar--current-tab))))
    (cl-loop for s being the hash-values of codetracer--sessions
             when (equal (codetracer-session-tab s) name) return s)))

(defun codetracer--select-tab (session)
  "Make SESSION's tab the current one, creating it when it has none."
  (tab-bar-mode 1)
  (let ((name (codetracer--tab-name session)))
    (if (tab-bar--tab-index-by-name name)
        (let ((codetracer--realizing t))
          (tab-bar-select-tab-by-name name))
      (let ((codetracer--realizing t))
        (tab-bar-new-tab)
        (tab-bar-rename-tab name)))
    (setf (codetracer-session-tab session) name)))

;;;###autoload
(defun codetracer-open (trace)
  "Open the CodeTracer recording or project TRACE in a session of its own.
A folder is sent as a project: the server opens the recording when the
folder holds one, as `ct' does, and otherwise opens the folder in Edit
mode, with no recording.  The first session starts the pane server, in
this buffer's `default-directory': that directory is the project Edit
mode works on for a recording."
  (interactive (list (read-file-name "CodeTracer recording or project: " nil nil t)))
  (unless (codetracer--live-p)
    (codetracer--start-server))
  (let* ((folder (directory-file-name (expand-file-name trace)))
         (result (codetracer--request
                  :session/open
                  (if (file-directory-p folder)
                      `(:project ,folder)
                    `(:trace ,folder))))
         (session (codetracer--new-session folder result)))
    (setq codetracer--active-session (codetracer-session-id session))
    (codetracer--fetch-sources session)
    (codetracer--watch-sources session)
    (codetracer--select-tab session)
    (codetracer--realize session)
    ;; The session's first position arrived with the answer; show it now
    ;; that the session's windows exist.
    (when-let ((pos (codetracer-session-position session)))
      (codetracer--show-position session pos))
    (codetracer--sync-source-keys)
    session))

(defun codetracer--trace-title (trace)
  "The title of the recording TRACE when the server gives none.
It is the name of the recording's folder."
  (file-name-nondirectory (directory-file-name trace)))

(defun codetracer--new-session (trace result)
  "Register the session RESULT describes, on the recording TRACE.
RESULT is the answer to `session/open', or a `session/opened'
notification: `session', `mode', `layout', `graphics', and `title'.
What arrived for the session before it was registered is applied now:
its position, and its keymaps and controls."
  (let* ((id (plist-get result :session))
         (title (plist-get result :title))
         (session (codetracer--make-session
                   :id id :trace trace
                   :title (if (and (stringp title) (not (string-empty-p title)))
                              title
                            (codetracer--trace-title trace))
                   :mode (plist-get result :mode)
                   :layout (plist-get result :layout)
                   :graphics (plist-get result :graphics))))
    (puthash id session codetracer--sessions)
    (when-let ((pos (gethash id codetracer--early-positions)))
      (setf (codetracer-session-position session) pos)
      (remhash id codetracer--early-positions))
    (let ((early (gethash id codetracer--early-notifications)))
      (remhash id codetracer--early-notifications)
      (dolist (n (reverse early))
        (codetracer--dispatch nil (car n) (cdr n))))
    session))

(defun codetracer--on-session-opened (params)
  "Show the session PARAMS announces (`session/opened') in a tab of its own.
The server opened it itself: a test recorded from the Test Results
pane, a Nim trace.  With `replaces' (the \"current tab\" placement), the
session it replaces is closed once the new one is shown.  This runs as
a notification: what it asks the server is sent without waiting."
  (let ((id (plist-get params :session))
        (trace (plist-get params :trace)))
    (when (and id (stringp trace) (not (codetracer--session id)))
      (let ((session (codetracer--new-session trace params)))
        (codetracer--send :session/files `(:session ,id)
                          (lambda (files)
                            (when (eq (codetracer--session id) session)
                              (setf (codetracer-session-sources session) (append files nil))
                              (codetracer--watch-sources session)
                              ;; Emacs's file tree lists the sources it now has.
                              (when (and (eq codetracer-panels-file-tree 'editor)
                                         (eq (codetracer--current-tab-session) session))
                                (codetracer--realize session)))))
        (codetracer--select-tab session)
        (codetracer--activate session)
        (codetracer--realize session)
        (when-let ((pos (codetracer-session-position session)))
          (codetracer--show-position session pos))
        (when-let ((old (codetracer--session (plist-get params :replaces))))
          (codetracer--close-session old t))
        (codetracer--sync-source-keys)
        (codetracer--sync-controls)
        (message "CodeTracer: opened %s" (codetracer-session-title session))))))

(defun codetracer-switch-session (id)
  "Show the session ID, in its tab."
  (interactive
   (list (let* ((choices (cl-loop for s being the hash-values of codetracer--sessions
                                  collect (cons (codetracer--tab-name s)
                                                (codetracer-session-id s))))
                (pick (completing-read "Session: " choices nil t)))
           (cdr (assoc pick choices)))))
  (let ((session (or (codetracer--session id) (user-error "No session %s" id))))
    (codetracer--select-tab session)
    (codetracer--activate session)))

(defun codetracer--activate (session)
  "Tell the server SESSION is the one shown; it answers with its layout."
  (unless (eql codetracer--active-session (codetracer-session-id session))
    (setq codetracer--active-session (codetracer-session-id session))
    (codetracer--send :session/activate
                      `(:session ,(codetracer-session-id session)))))

(defun codetracer--on-tab-selected (&rest _)
  "Make the session whose tab the user selected the active one.
The debugger keys follow the tab, whoever selected it."
  (unless codetracer--realizing
    (when-let ((session (codetracer--current-tab-session)))
      (codetracer--activate session)))
  ;; A file two sessions hold tests for shows the current tab's.
  (codetracer--render-all-tests)
  (codetracer--sync-source-keys))

(defun codetracer-close-session (id)
  "Close the session ID and its tab."
  (interactive (list (or (and-let* ((s (codetracer--current-tab-session)))
                           (codetracer-session-id s))
                         (user-error "This tab shows no CodeTracer session"))))
  (when-let ((session (codetracer--session id)))
    (codetracer--close-session session)))

(defun codetracer--close-session (session &optional no-wait)
  "Close SESSION and its tab.
With NO-WAIT, `session/close' is sent without waiting for its answer,
as a notification handler must."
  (let ((id (codetracer-session-id session)))
    (if no-wait
        (codetracer--send :session/close `(:session ,id))
      (codetracer--request :session/close `(:session ,id)))
    (maphash (lambda (_pane buffer) (when (buffer-live-p buffer) (kill-buffer buffer)))
             (codetracer-session-panes session))
    (codetracer--clear-decorations session)
    (codetracer--unwatch-sources session)
    (remhash id codetracer--sessions)
    ;; Its tests leave the source with it (another session's, if one holds
    ;; the same file's, take their place).
    (codetracer--render-all-tests)
    (when (equal codetracer--active-session id)
      (setq codetracer--active-session nil))
    (when-let ((index (tab-bar--tab-index-by-name (codetracer-session-tab session))))
      (let ((codetracer--realizing t))
        (tab-bar-close-tab (1+ index))))
    (codetracer--sync-source-keys)
    (codetracer--sync-controls)))

(defun codetracer-quit ()
  "Close every session and stop the pane server."
  (interactive)
  (when (codetracer--live-p)
    (dolist (id (hash-table-keys codetracer--sessions))
      (ignore-errors (codetracer-close-session id)))
    (ignore-errors (codetracer--request :shutdown))
    (ignore-errors (codetracer--notify :exit))
    (jsonrpc-shutdown codetracer--connection)))

;;;; Layouts in side windows

;; A layout is the server's tree: `row' / `column' splits with weights,
;; `stack' nodes showing their `activeIndex' child, `pane' leaves.  The leaf
;; `editor' is the source: Emacs's own windows.  The root's children before
;; the one holding the editor become side windows on the left (a row) or the
;; top (a column), those after it on the right or the bottom.  A side holds
;; its windows in one line, so the panes of a side's subtree are its slots in
;; tree order, each with the share of the side the tree's weights give it
;; (the product of its weight's fraction among its siblings at every level).
;; Reported back, the realized sizes become weights by node path, so the same
;; projection reproduces them.

(defun codetracer--node-kind (node)
  "NODE's kind: \"row\", \"column\", \"stack\" or \"pane\"."
  (plist-get node :kind))
(defun codetracer--node-pane (node)
  "The pane a \"pane\" NODE names."
  (plist-get node :pane))
(defun codetracer--node-children (node)
  "NODE's children, as a list."
  (append (plist-get node :children) nil))
(defun codetracer--node-weight (node)
  "NODE's weight among its siblings, 1 when it has none."
  (or (plist-get node :weight) 1.0))

(defun codetracer--servable-p (pane)
  "Non-nil when the pane server draws PANE."
  (and pane (member pane (append (plist-get (plist-get codetracer--server-info
                                                       :capabilities)
                                            :panes)
                                 nil))))

(defun codetracer--holds-editor-p (node)
  "Return non-nil when the source editor is in NODE's subtree."
  (if (equal (codetracer--node-kind node) "pane")
      (equal (codetracer--node-pane node) "editor")
    (cl-some #'codetracer--holds-editor-p (codetracer--node-children node))))

(defun codetracer--visible-leaves (node path share)
  "Return the servable panes NODE displays, as (PANE PATH SHARE REGION-PATH) lists.
PATH is NODE's path from the root, SHARE the fraction of its side it
covers.  REGION-PATH is the path of the node whose weight sizes the pane:
the pane's own, or its stack's."
  (pcase (codetracer--node-kind node)
    ("pane"
     (let ((pane (codetracer--node-pane node)))
       (when (codetracer--servable-p pane)
         (list (list pane path share path)))))
    ("stack"
     (let* ((kids (codetracer--node-children node))
            (active (min (max 0 (or (plist-get node :activeIndex) 0))
                         (max 0 (1- (length kids)))))
            (kid (nth active kids)))
       (when kid
         (mapcar (lambda (leaf) (list (nth 0 leaf) (nth 1 leaf) (nth 2 leaf) path))
                 (codetracer--visible-leaves kid (append path (list active)) share)))))
    (_
     (let* ((kids (codetracer--node-children node))
            (total (apply #'+ (mapcar #'codetracer--node-weight kids)))
            (i -1))
       (cl-loop for kid in kids
                do (cl-incf i)
                append (codetracer--visible-leaves
                        kid (append path (list i))
                        (* share (if (> total 0)
                                     (/ (codetracer--node-weight kid) total)
                                   (/ 1.0 (length kids))))))))))

(defun codetracer--sides (layout)
  "Return LAYOUT's sides: a list of (SIDE SIZE-FRACTION PANE-LIST PATH).
SIDE is a symbol `display-buffer-in-side-window' understands, SIZE the
side's fraction of the frame across it, PANE-LIST its panes as
`codetracer--visible-leaves' gives them, PATH the path of the node the
side shows.  The user's windows take the editor's place: each node beside
the editor's path, at every depth of it, is a side (a pane split off the
editor -- the Low Level Code pane an operation places, say -- is one), so
one SIDE symbol may come more than once, the outer node first."
  (if (not (member (codetracer--node-kind layout) '("row" "column")))
      ;; A layout that is one pane or one stack: a side of its own.
      (list (list 'right 0.5 (codetracer--visible-leaves layout nil 1.0) nil))
    (codetracer--sides-around-editor layout nil 1.0 1.0)))

(defun codetracer--sides-around-editor (node path width height)
  "The sides of row or column NODE, at PATH, which spans WIDTH and HEIGHT.
Those are fractions of the frame.  The child holding the editor is not a
side; when it is itself a row or a column, the sides around the editor
inside it follow."
  (let* ((kind (codetracer--node-kind node))
         (row (equal kind "row"))
         (kids (codetracer--node-children node))
         (total (apply #'+ (mapcar #'codetracer--node-weight kids)))
         (editor (cl-position-if #'codetracer--holds-editor-p kids))
         (i -1)
         (sides
          (cl-loop for kid in kids
                   do (cl-incf i)
                   unless (eql i editor)
                   collect (let ((fraction (if (> total 0)
                                               (/ (codetracer--node-weight kid) (float total))
                                             0.25)))
                             (list (if row
                                       (if (and editor (< i editor)) 'left 'right)
                                     (if (and editor (< i editor)) 'top 'bottom))
                                   (* fraction (if row width height))
                                   (codetracer--visible-leaves kid (append path (list i)) 1.0)
                                   (append path (list i)))))))
    (if-let* ((editor)
              (inner (nth editor kids))
              ((member (codetracer--node-kind inner) '("row" "column"))))
        (let ((fraction (if (> total 0) (/ (codetracer--node-weight inner) (float total)) 1.0)))
          (append sides
                  (codetracer--sides-around-editor
                   inner (append path (list editor))
                   (if row (* width fraction) width)
                   (if row height (* height fraction)))))
      sides)))

(defun codetracer--pane-buffer-name (id pane)
  "The name of the buffer showing session ID's PANE: ct://ID/PANE.
Short on purpose: it is what the mode line shows, and pane windows are
narrow, so a long name leaves no room for the pane's."
  (format "ct://%s/%s" id pane))

(defun codetracer--legacy-pane-buffer-name (id pane)
  "The name session ID's PANE buffer had before `ct://' names.
A `desktop' file saved then restores the buffer under it."
  (format "*codetracer %s: %s*" id pane))

(defun codetracer--named-pane-buffer (id pane)
  "The buffer named for session ID's PANE, created when there is none.
A buffer carrying the name pane buffers had before (one `desktop'
restored, say) is adopted and renamed, so no buffer is left answering
to the old name; when both names are taken, the old one goes."
  (let* ((name (codetracer--pane-buffer-name id pane))
         (current (get-buffer name))
         (legacy (get-buffer (codetracer--legacy-pane-buffer-name id pane))))
    (cond ((and current legacy)
           (kill-buffer legacy)
           current)
          (current current)
          (legacy
           (with-current-buffer legacy (rename-buffer name))
           legacy)
          (t (get-buffer-create name)))))

(defun codetracer--pane-buffer (session pane)
  "SESSION's buffer for PANE, created when it does not exist."
  (let ((buffer (gethash pane (codetracer-session-panes session))))
    (unless (buffer-live-p buffer)
      (setq buffer (codetracer--named-pane-buffer (codetracer-session-id session) pane))
      (with-current-buffer buffer
        (codetracer-pane-mode)
        (setq codetracer--pane pane
              codetracer--pane-session (codetracer-session-id session))
        (setq-local desktop-save-buffer #'codetracer--desktop-buffer-misc))
      (puthash pane buffer (codetracer-session-panes session)))
    buffer))

(defun codetracer--pane-windows (&optional frame)
  "The windows of FRAME showing a CodeTracer pane, or a role Emacs fills."
  (cl-remove-if-not (lambda (w) (or (buffer-local-value 'codetracer--pane (window-buffer w))
                                    (buffer-local-value 'codetracer--role (window-buffer w))))
                    (window-list frame 'nomini)))

(defun codetracer--side-axis-size (window side)
  "WINDOW's size along the line its SIDE's slots form, in cells."
  (if (memq side '(left right)) (window-total-height window) (window-total-width window)))

(defun codetracer--realize (session)
  "Show SESSION's layout in the selected frame, in side windows."
  (setf (codetracer-session-realized session) (codetracer-session-layout session))
  (let ((codetracer--realizing t)
        (sides (codetracer--sides (codetracer-session-layout session)))
        (shown nil)
        ;; Per SIDE symbol: the next slot, and the leaves shown there (a
        ;; symbol may come more than once, `codetracer--sides').
        (slots nil)
        (along nil))
    ;; Our previous windows go; the user's source windows stay.
    (dolist (w (codetracer--pane-windows))
      (when (window-live-p w)
        (ignore-errors (delete-window w))))
    (dolist (side sides)
      (pcase-let ((`(,where ,size ,leaves ,_path) side))
        (dolist (leaf leaves)
          (let* ((slot (setf (alist-get where slots) (1+ (alist-get where slots -1))))
                 (pane (nth 0 leaf))
                 (buffer (codetracer--leaf-buffer session pane))
                 (window (display-buffer
                          buffer
                          `((display-buffer-in-side-window)
                            (side . ,where) (slot . ,slot)
                            ,(if (memq where '(left right))
                                 `(window-width . ,size)
                               `(window-height . ,size))
                            (dedicated . t)
                            (window-parameters (no-delete-other-windows . t))))))
            (when window
              (set-window-parameter window 'codetracer-side where)
              (push (cons window leaf) shown))))
        (setf (alist-get where along) (append (alist-get where along) leaves))))
    (dolist (entry along)
      (codetracer--apply-shares (car entry) (cdr entry)))
    ;; Panes the server keeps open that this layout does not show.
    (maphash (lambda (_pane buffer)
               (when (and (buffer-live-p buffer) (not (get-buffer-window buffer)))
                 (codetracer--close-pane buffer)))
             (codetracer-session-panes session))
    ;; The tabs change the windows' body heights: before the sizes are sent.
    (codetracer--update-stack-tabs session)
    (dolist (entry shown)
      (codetracer--sync-pane-size (car entry)))
    shown))

(defun codetracer--leaf-buffer (session pane)
  "The buffer showing SESSION's PANE: the pane's, or the role Emacs fills."
  (if (and (equal pane "fileTree") (eq codetracer-panels-file-tree 'editor))
      (codetracer--file-tree-buffer session)
    (codetracer--pane-buffer session pane)))

(defun codetracer--close-pane (buffer)
  "Tell the server that the pane in BUFFER is no longer shown, if it was open.
A `pane/resize' still awaiting its answer is not followed by another:
the answer finds the pane closed (`codetracer--resize-answered')."
  (with-current-buffer buffer
    (when (and codetracer--pane codetracer--pane-open)
      (setq codetracer--pane-open nil
            codetracer--pane-size nil)
      (codetracer--send :pane/close `(:session ,codetracer--pane-session
                                               :pane ,codetracer--pane)))))

(defun codetracer--apply-shares (side pane-list)
  "Resize the slots of SIDE to the shares in PANE-LIST."
  (let* ((windows (cl-remove-if-not
                   (lambda (w) (eq (window-parameter w 'codetracer-side) side))
                   (codetracer--pane-windows)))
         (windows (sort windows (lambda (a b) (< (or (window-parameter a 'window-slot) 0)
                                                 (or (window-parameter b 'window-slot) 0)))))
         (horizontal (memq side '(top bottom)))
         (total (apply #'+ (mapcar (lambda (w) (codetracer--side-axis-size w side)) windows)))
         (shares (mapcar (lambda (leaf) (nth 2 leaf)) pane-list))
         (share-total (apply #'+ shares)))
    (when (and (> (length windows) 1) (> share-total 0))
      (cl-loop for w in (butlast windows)
               for share in shares
               do (let* ((target (max 1 (round (* total (/ share share-total)))))
                         (delta (- target (codetracer--side-axis-size w side))))
                    (ignore-errors (window-resize w delta horizontal t)))))))

(defun codetracer--on-layout-changed (params)
  "The server's layout for a session's mode: PARAMS."
  (when-let ((session (codetracer--session (plist-get params :session))))
    (setf (codetracer-session-mode session) (plist-get params :mode)
          (codetracer-session-layout session)
          (codetracer--apply-stack-choices session (plist-get params :layout)
                                           (plist-get params :mode)))
    (when (eq (codetracer--current-tab-session) session)
      (codetracer--show-layout session))))

(defun codetracer--session-windows (session)
  "The selected frame's windows showing one of SESSION's panes."
  (cl-remove-if-not
   (lambda (w) (eql (buffer-local-value 'codetracer--pane-session (window-buffer w))
                    (codetracer-session-id session)))
   (codetracer--pane-windows)))

(defun codetracer--show-layout (session)
  "Show SESSION's layout in its tab, keeping the user's arrangement.
When the tab already shows the layout last realized there (a tab the
user returned to, or one `desktop' restored), its windows are the
user's and stay; the server is told their sizes.  Otherwise the layout
is realized."
  (let ((windows (codetracer--session-windows session)))
    (if (and windows (equal (codetracer-session-realized session)
                            (codetracer-session-layout session)))
        (progn
          (codetracer--update-stack-tabs session)
          (dolist (w windows) (codetracer--sync-pane-size w)))
      (codetracer--realize session))))

;;;; Stacked panes

;; A stack shows one of its children at a time.  The window showing a
;; stacked pane lists the stack's children in its header line, the shown
;; one in `codetracer-stack-tab-active'; a click on a name shows that pane
;; in the window.  The choice is the editor's: the server's layouts keep
;; their own `activeIndex', so the choice is applied to every layout of
;; that mode the server sends.

(defvar codetracer-stack-tab-map
  (let ((map (make-sparse-keymap)))
    (define-key map [header-line mouse-1] #'codetracer-stack-tab-click)
    map)
  "The keymap on a stacked pane's name in its window's tabs.")

(defun codetracer--node-at (layout path)
  "The node of LAYOUT at PATH (child indices from the root), or nil."
  (let ((node layout))
    (dolist (i path node)
      (setq node (and node (nth i (codetracer--node-children node)))))))

(defun codetracer--stack-active (stack)
  "The index of STACK's shown child among its children."
  (min (max 0 (or (plist-get stack :activeIndex) 0))
       (max 0 (1- (length (codetracer--node-children stack))))))

(defun codetracer--stack-tabs (stack)
  "STACK's tabs: one clickable name per child, as a header line."
  (let ((active (codetracer--stack-active stack))
        (i -1))
    (mapconcat (lambda (child)
                 (cl-incf i)
                 (propertize (format " %s " (string-replace
                                             "%" "%%"
                                             (if (equal (codetracer--node-kind child) "pane")
                                                 (codetracer--node-pane child)
                                               (codetracer--node-kind child))))
                             'face (if (= i active)
                                       'codetracer-stack-tab-active
                                     'codetracer-stack-tab)
                             'mouse-face 'mode-line-highlight
                             'help-echo "mouse-1: show this pane"
                             'keymap codetracer-stack-tab-map
                             'codetracer-stack-index i))
               (codetracer--node-children stack) "")))

(defun codetracer--update-stack-tabs (session)
  "Give each window showing one of several stacked panes of SESSION its tabs.
The window remembers the stack's path, in its `codetracer-stack'
parameter (a vector), for a click on a tab."
  (let ((layout (codetracer-session-layout session)))
    (dolist (side (codetracer--sides layout))
      (dolist (leaf (nth 2 side))
        (when-let* ((buffer (gethash (nth 0 leaf) (codetracer-session-panes session)))
                    ((buffer-live-p buffer))
                    (window (get-buffer-window buffer)))
          (let* ((region (nth 3 leaf))
                 (node (codetracer--node-at layout region))
                 (stack (and (equal (codetracer--node-kind node) "stack")
                             (> (length (codetracer--node-children node)) 1)
                             node)))
            (set-window-parameter window 'codetracer-stack (and stack (vconcat region)))
            (with-current-buffer buffer
              (setq header-line-format (and stack (codetracer--stack-tabs stack))))))))))

(defun codetracer--apply-stack-choices (session layout mode)
  "Show, in SESSION's LAYOUT of MODE, the stacked panes the user picked.
Return LAYOUT, changed in place."
  (when layout
    (maphash (lambda (key index)
               (when (equal (car key) mode)
                 (let ((node (codetracer--node-at layout (cdr key))))
                   (when (and (equal (codetracer--node-kind node) "stack")
                              (< index (length (codetracer--node-children node))))
                     (plist-put node :activeIndex index)))))
             (codetracer-session-stack-choices session)))
  layout)

(defun codetracer--stack-select (session window index)
  "Show child INDEX of the stack whose pane SESSION's WINDOW displays.
When both the shown child and child INDEX are panes, the window
changes buffer and keeps its size; otherwise the layout is realized
again."
  (let* ((path (append (window-parameter window 'codetracer-stack) nil))
         (layout (codetracer-session-layout session))
         (stack (and (window-parameter window 'codetracer-stack)
                     (codetracer--node-at layout path)))
         (kids (and stack (codetracer--node-children stack)))
         (before (and kids (nth (codetracer--stack-active stack) kids)))
         (after (and kids (nth index kids))))
    (when (and (equal (codetracer--node-kind stack) "stack") after
               (not (eq before after)))
      (puthash (cons (codetracer-session-mode session) path) index
               (codetracer-session-stack-choices session))
      (codetracer--apply-stack-choices session layout (codetracer-session-mode session))
      (unless (eq (codetracer-session-realized session) layout)
        (codetracer--apply-stack-choices session (codetracer-session-realized session)
                                         (codetracer-session-mode session)))
      (if (not (and (equal (codetracer--node-kind before) "pane")
                    (equal (codetracer--node-kind after) "pane")
                    (codetracer--servable-p (codetracer--node-pane after))))
          (codetracer--realize session)
        (let ((codetracer--realizing t)
              (old (window-buffer window))
              (buffer (codetracer--leaf-buffer session (codetracer--node-pane after))))
          (codetracer--close-pane old)
          (with-current-buffer old (setq header-line-format nil))
          (set-window-dedicated-p window nil)
          (set-window-buffer window buffer)
          (set-window-dedicated-p window t)
          (codetracer--update-stack-tabs session)
          (codetracer--sync-pane-size window))))))

(defun codetracer-stack-tab-click (event)
  "Show the stacked pane whose name EVENT clicked in a window's tabs."
  (interactive "e")
  (let* ((posn (event-start event))
         (window (posn-window posn))
         (object (posn-string posn))
         (index (and (consp object) (stringp (car object)) (integerp (cdr object))
                     (get-text-property (cdr object) 'codetracer-stack-index
                                        (car object))))
         (session (and (window-live-p window)
                       (codetracer--session (buffer-local-value 'codetracer--pane-session
                                                                (window-buffer window))))))
    (when (and session index)
      (codetracer--stack-select session window index))))

(defun codetracer--report-layout (session)
  "Report the user's sizes of SESSION's windows as the mode's layout weights.
At most one such report is in flight: dragging a divider resizes the
windows once per mouse motion, faster than the server answers, and each
report would queue behind the last.  A resize made while one is pending
is reported when its answer arrives, measured then, so the last report
carries the sizes the windows ended at.  A pane closed is reported at
once all the same (`codetracer--report-closed')."
  (if (codetracer-session-reporting session)
      (setf (codetracer-session-sizes-dirty session) t)
    (setf (codetracer-session-sizes-dirty session) nil)
    (setf (codetracer-session-reporting session)
          (codetracer--send :layout/edited (codetracer--measured-layout session)
                            (lambda (result)
                              (codetracer--edited session result)
                              (codetracer--layout-reported session))
                            (lambda () (codetracer--layout-reported session))))))

(defun codetracer--layout-reported (session)
  "The server answered SESSION's sizes report: send the next one, if any.
Only while SESSION's windows are on screen: they are what is measured."
  (setf (codetracer-session-reporting session) nil)
  (when (and (codetracer-session-sizes-dirty session)
             (eq (codetracer--session (codetracer-session-id session)) session)
             (eq (codetracer--current-tab-session) session)
             (not codetracer--realizing))
    (codetracer--report-layout session)))

(defun codetracer--measured-layout (session)
  "The `layout/edited' parameters for the sizes of SESSION's windows now."
  (let ((weights nil) (sizes nil))
    (dolist (side (codetracer--sides (codetracer-session-layout session)))
      (pcase-let ((`(,where ,_size ,leaves ,path) side))
        (let ((across 0) (regions (make-hash-table :test #'equal)))
          (dolist (leaf leaves)
            (when-let* ((buffer (gethash (nth 0 leaf) (codetracer-session-panes session)))
                        (window (get-buffer-window buffer)))
              (let ((along (codetracer--side-axis-size window where)))
                (setq across (max across (if (memq where '(left right))
                                             (window-total-width window)
                                           (window-total-height window))))
                (push (cons (intern (concat ":" (nth 0 leaf))) along) sizes)
                ;; Every node from the side's root down to the pane's region
                ;; holds the pane's cells along the side.
                (let ((region (nth 3 leaf)))
                  (cl-loop for n from (1+ (length path)) to (length region)
                           do (let ((prefix (cl-subseq region 0 n)))
                                (puthash prefix (+ along (gethash prefix regions 0))
                                         regions)))))))
          (when (> across 0)
            (push `(:path ,(vconcat path) :weight ,across) weights))
          (maphash (lambda (p w) (push `(:path ,(vconcat p) :weight ,w) weights))
                   regions))))
    ;; The editor's share across the root: what the sides leave.
    (let* ((layout (codetracer-session-layout session))
           (kids (codetracer--node-children layout))
           (editor (cl-position-if #'codetracer--holds-editor-p kids))
           (main (window-main-window)))
      (when (and editor main (member (codetracer--node-kind layout) '("row" "column")))
        (push `(:path ,(vector editor)
                      :weight ,(if (equal (codetracer--node-kind layout) "row")
                                   (window-total-width main)
                                 (window-total-height main)))
              weights)))
    `(:session ,(codetracer-session-id session)
               :mode ,(codetracer-session-mode session)
               :sizes ,(apply #'append (mapcar (lambda (c) (list (car c) (cdr c)))
                                               sizes))
               :weights ,(vconcat weights)
               :closed [])))

(defun codetracer--edited (session result)
  "Take the layout RESULT the server recorded for SESSION's user edit.
It is the arrangement on screen, so it is also the one realized."
  (when-let ((layout (codetracer--apply-stack-choices
                      session (plist-get result :layout) (codetracer-session-mode session))))
    (setf (codetracer-session-layout session) layout
          (codetracer-session-realized session) layout)))

(defun codetracer--report-closed (session pane buffer)
  "Report that the user closed SESSION's PANE, which BUFFER showed.
Sent at once, even while a sizes-only report is in flight."
  (codetracer--send :layout/edited
                    `(:session ,(codetracer-session-id session)
                               :mode ,(codetracer-session-mode session)
                               :closed ,(vector pane))
                    (lambda (result) (codetracer--edited session result)))
  (codetracer--close-pane buffer))

;;;; Pane sizes

(defun codetracer--sync-pane-size (window)
  "Tell the server the size of WINDOW's pane, if it changed.
A pane that is not open is opened (`pane/open') at once.  An open one
is resized (`pane/resize'), with at most one resize in flight: dragging
a divider resizes the window once per mouse motion, far faster than the
server repaints, and sending every size between would queue repaints
the user has already dragged past.  When the answer arrives, the size
the window has reached by then is sent if it differs
\(`codetracer--resize-answered'), so the pane trails the divider by at
most one repaint and the size the drag stops at is the last one sent."
  (let ((buffer (window-buffer window)))
    (with-current-buffer buffer
      (when codetracer--pane
        (let ((size (cons (max 1 (window-body-width window))
                          (max 1 (window-body-height window))))
              (params (lambda (size)
                        `(:session ,codetracer--pane-session
                                   :pane ,codetracer--pane
                                   :width ,(car size) :height ,(cdr size)))))
          (cond
           ((not codetracer--pane-open)
            (setq codetracer--pane-size size
                  codetracer--pane-open t)
            (codetracer--send :pane/open (funcall params size)))
           ((and (not codetracer--pane-resizing)
                 (not (equal size codetracer--pane-size)))
            (setq codetracer--pane-size size)
            (setq codetracer--pane-resizing
                  (codetracer--send :pane/resize (funcall params size)
                                    (lambda (_) (codetracer--resize-answered buffer))
                                    (lambda () (codetracer--resize-answered buffer)))))))))))

(defun codetracer--resize-answered (buffer)
  "Follow up the answer to the `pane/resize' of the pane in BUFFER.
Send the size its window has reached since, if it differs; nothing when
the pane was closed meanwhile."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq codetracer--pane-resizing nil)
      (when-let* ((codetracer--pane-open)
                  (window (get-buffer-window buffer t)))
        (codetracer--sync-pane-size window)))))

(defun codetracer--schedule-window-change (frame)
  "Report what happened to FRAME's windows once redisplay is done."
  (unless (or codetracer--realizing codetracer--window-change-timer)
    (setq codetracer--window-change-timer
          (run-at-time 0 nil (lambda ()
                               (setq codetracer--window-change-timer nil)
                               (when (frame-live-p frame)
                                 (codetracer--on-window-buffer-change frame)
                                 (codetracer--on-window-size-change frame)
                                 ;; The source window may show another buffer.
                                 (with-selected-frame frame
                                   (codetracer--sync-source-keys))))))))

(defun codetracer--on-window-size-change (frame)
  "Report FRAME's pane windows whose sizes changed, and the user's layout."
  (when (codetracer--live-p)
    (let ((session (with-selected-frame frame (codetracer--current-tab-session)))
          (changed nil))
      (dolist (window (codetracer--pane-windows frame))
        (with-current-buffer (window-buffer window)
          (when (and session (eql codetracer--pane-session (codetracer-session-id session))
                     codetracer--pane-open
                     (not (equal codetracer--pane-size
                                 (cons (window-body-width window)
                                       (window-body-height window)))))
            (setq changed t)
            (codetracer--sync-pane-size window))))
      (when (and changed session (not codetracer--realizing))
        (codetracer--report-layout session)))))

(defun codetracer--on-window-buffer-change (frame)
  "Report the panes of FRAME's session the user closed."
  (when (and (codetracer--live-p) (not codetracer--realizing))
    (when-let ((session (with-selected-frame frame (codetracer--current-tab-session))))
      (maphash (lambda (pane buffer)
                 (when (and (buffer-live-p buffer)
                            (buffer-local-value 'codetracer--pane-open buffer)
                            (not (get-buffer-window buffer frame)))
                   (codetracer--report-closed session pane buffer)))
               (codetracer-session-panes session)))))

;;;; Pane content

(defvar codetracer-pane-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    map)
  "The base keymap of CodeTracer pane buffers.")

(defvar codetracer-hotspot-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'codetracer-activate-hotspot)
    (define-key map [mouse-1] #'codetracer-activate-hotspot)
    map)
  "The keymap on a pane's hotspots: a click or RET runs its operation.")

(define-derived-mode codetracer-pane-mode special-mode "CodeTracer"
  "A CodeTracer pane: rows the pane server draws at the window's size.
The keys are the bindings of your CodeTracer keymap for this pane, with
your own (`codetracer-pane-user-map', `codetracer-pane-user-maps') first."
  (setq-local truncate-lines t
              buffer-read-only t
              cursor-in-non-selected-windows nil)
  (buffer-disable-undo))

(defun codetracer--byte-offsets (text)
  "A function mapping UTF-8 byte offsets in TEXT to character offsets."
  (if (= (string-bytes text) (length text))
      #'identity
    (let ((table (make-hash-table)) (byte 0))
      (dotimes (i (length text))
        (puthash byte i table)
        (setq byte (+ byte (length (encode-coding-string
                                    (string (aref text i)) 'utf-8 t)))))
      (puthash byte (length text) table)
      (lambda (b) (gethash b table (length text))))))

(defun codetracer--render-row (row)
  "ROW of a `pane/content' notification as a propertized string."
  (let* ((text (copy-sequence (or (plist-get row :text) "")))
         (at (codetracer--byte-offsets text))
         (len (length text)))
    (seq-doseq (span (plist-get row :spans))
      (let ((start (min len (funcall at (plist-get span :start))))
            (end (min len (funcall at (plist-get span :end))))
            (faces nil))
        (when-let ((face (codetracer--style-face (plist-get span :style))))
          (push face faces))
        (when-let ((surface (codetracer--style-face (plist-get span :surface))))
          (push surface faces))
        (when (eq (plist-get span :bold) t) (push 'bold faces))
        (when (eq (plist-get span :italic) t) (push 'italic faces))
        (when (eq (plist-get span :underline) t) (push 'underline faces))
        (when (and faces (< start end))
          (add-face-text-property start end (nreverse faces) t text))))
    (seq-doseq (spot (plist-get row :hotspots))
      (let ((start (min len (funcall at (plist-get spot :start))))
            (end (min len (funcall at (plist-get spot :end)))))
        (when (< start end)
          (add-text-properties
           start end
           `(codetracer-hotspot (,(plist-get spot :operation) . ,(plist-get spot :args))
                                mouse-face highlight
                                keymap ,codetracer-hotspot-map
                                help-echo ,(format "%s" (plist-get spot :operation)))
           text))))
    text))

(defun codetracer--on-pane-content (params)
  "Draw the rows of PARAMS, a `pane/content' notification, in their pane.
The buffer is a screen: one line per row, HEIGHT lines.  A full update
replaces it; otherwise each row replaces the line it indexes."
  (when-let* ((session (codetracer--session (plist-get params :session)))
              (buffer (codetracer--pane-buffer session (plist-get params :pane))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t)
            (height (plist-get params :height))
            (rows (append (plist-get params :rows) nil))
            (line (line-number-at-pos))
            (column (current-column)))
        (if (eq (plist-get params :full) t)
            (progn
              (erase-buffer)
              (insert (mapconcat #'codetracer--render-row
                                 (sort rows (lambda (a b) (< (plist-get a :index)
                                                             (plist-get b :index))))
                                 "\n")))
          (dolist (row rows)
            (goto-char (point-min))
            (let ((missing (forward-line (plist-get row :index))))
              (when (> missing 0)
                (goto-char (point-max))
                (insert (make-string missing ?\n))))
            (delete-region (point) (line-end-position))
            (insert (codetracer--render-row row))))
        ;; Lines past the height the server drew at are gone, and so is the
        ;; image under them, which is drawn again below.
        (goto-char (point-min))
        (when (zerop (forward-line (max 1 height)))
          (delete-region (1- (point)) (point-max)))
        (when-let ((spec (plist-get params :image)))
          (setq codetracer--image (codetracer--pane-image spec)
                codetracer--image-spec (list :width (plist-get spec :width)
                                             :height (plist-get spec :height)
                                             :frame (plist-get spec :frame)
                                             :frameCount (plist-get spec :frameCount))))
        (codetracer--insert-image)
        (goto-char (point-min))
        (forward-line (1- line))
        (move-to-column column)))))

(defun codetracer--pane-image (spec)
  "The image `pane/content' SPEC carries, as an image descriptor, or nil."
  (when (and spec (equal (plist-get spec :encoding) "base64"))
    (let ((data (base64-decode-string (plist-get spec :data)))
          (type (pcase (plist-get spec :mediaType)
                  ("image/png" 'png) ("image/jpeg" 'jpeg) (_ nil)))
          (window (get-buffer-window (current-buffer))))
      ;; An Emacs built without the image's library draws the pane's text
      ;; only; the rows above say what the frame is.
      (when (and type (image-type-available-p type))
        (apply #'create-image data type t
               (when (and window (display-images-p))
                 (list :max-width (window-body-width window t)
                       :max-height (window-body-height window t))))))))

(defun codetracer--insert-image ()
  "Insert the pane's image under its rows."
  (when codetracer--image
    (goto-char (point-max))
    (insert "\n")
    (insert-image codetracer--image "[frame]")))

(defun codetracer--hotspot-at (pos)
  "The hotspot (OPERATION . ARGS) at POS, or nil."
  (get-text-property pos 'codetracer-hotspot))

(defun codetracer-activate-hotspot (&optional event)
  "Run the operation of the hotspot at point, or at EVENT's position."
  (interactive (list last-nonmenu-event))
  (let* ((pos (if (mouse-event-p event)
                  (posn-point (event-start event))
                (point)))
         (buffer (if (mouse-event-p event)
                     (window-buffer (posn-window (event-start event)))
                   (current-buffer))))
    (with-current-buffer buffer
      (when-let ((spot (codetracer--hotspot-at pos)))
        (codetracer--run (car spot) :args (cdr spot) :pane codetracer--pane
                         :session codetracer--pane-session)))))

;;;; Operations

(cl-defun codetracer--run (operation &key args pane session)
  "Run OPERATION on SESSION (the active one when nil) and return the result.
ARGS are a hotspot's arguments; PANE is focused first.  What the server
says about the run is shown to the user: a refusal (an error answer, or
`ok' false) as a message naming OPERATION, the answer's `detail' (\"frame
2 of 5\", the operation's notification) as it is.  A refusal returns nil."
  (condition-case err
      (let ((result (codetracer--request
                     :operation/run
                     `(,@(when session `(:session ,session))
                       :operation ,operation
                       ,@(when pane `(:pane ,pane))
                       ,@(when args `(:args ,args))))))
        (codetracer--show-run-result operation result)
        result)
    (jsonrpc-error
     (message "CodeTracer: %s: %s" operation
              (or (alist-get 'jsonrpc-error-message (cdr err))
                  (error-message-string err)))
     nil)))

(defun codetracer--show-run-result (operation result)
  "Show the user what the server said of running OPERATION: its RESULT."
  (let ((detail (plist-get result :detail)))
    (cond ((eq (plist-get result :ok) :json-false)
           (message "CodeTracer: %s: %s" operation
                    (if (and (stringp detail) (not (string-empty-p detail)))
                        detail
                      "refused")))
          ((and (stringp detail) (not (string-empty-p detail)))
           (message "CodeTracer: %s" detail)))))

(defun codetracer--command-name (operation)
  "The `M-x' command for OPERATION, the catalogue's name."
  (intern (concat "codetracer-"
                  (replace-regexp-in-string "[^[:alnum:]-]+" "-"
                                            (string-trim-right operation "[)]")))))

(defun codetracer--operation-command (operation &optional label)
  "The command running OPERATION, defined when it does not exist yet.
LABEL is its catalogue label, used in the command's documentation."
  (let ((name (codetracer--command-name operation)))
    (unless (and (fboundp name) (get name 'codetracer-operation))
      (defalias name
        (lambda ()
          (interactive)
          (codetracer--run operation :pane codetracer--pane
                           :session codetracer--pane-session))
        (format "Run CodeTracer's %s operation (%s)." operation (or label operation)))
      (put name 'codetracer-operation operation))
    name))

(defun codetracer--define-operation-commands ()
  "Define an `M-x' command for every operation in the catalogue."
  (dolist (op codetracer--operations)
    (codetracer--operation-command (plist-get op :name) (plist-get op :label))))

(defun codetracer-run-operation (operation)
  "Run the CodeTracer OPERATION, chosen from the catalogue."
  (interactive
   (list (completing-read "CodeTracer operation: "
                          (mapcar (lambda (op) (plist-get op :name)) codetracer--operations)
                          nil t)))
  (codetracer--run operation :pane codetracer--pane :session codetracer--pane-session))

;;;; Keymaps

(defvar codetracer-pane-user-map (make-sparse-keymap)
  "Your bindings in every CodeTracer pane.
They take precedence over CodeTracer's keymap, and are reported to the
pane server so its keymap help shows them.")

(defcustom codetracer-pane-user-maps nil
  "Your bindings in particular CodeTracer panes: an alist of (PANE . KEYMAP).
PANE is the pane's wire name (\"calltrace\", \"state\", ...).  They take
precedence over `codetracer-pane-user-map' and CodeTracer's keymap."
  :type '(alist :key-type string :value-type variable))

(defun codetracer--pane-user-map (pane)
  "Your keymap for PANE, or nil."
  (let ((map (cdr (assoc pane codetracer-pane-user-maps))))
    (if (and (symbolp map) (boundp map)) (symbol-value map) map)))

(defconst codetracer--named-keys
  '(("Enter" . "RET") ("Return" . "RET") ("Escape" . "ESC") ("Esc" . "ESC")
    ("Tab" . "TAB") ("Space" . "SPC") ("Backspace" . "DEL")
    ("Up" . "<up>") ("Down" . "<down>") ("Left" . "<left>") ("Right" . "<right>")
    ("PageUp" . "<prior>") ("PageDown" . "<next>") ("Home" . "<home>")
    ("End" . "<end>") ("Delete" . "<delete>") ("Insert" . "<insert>"))
  "CodeTracer's spelling of named keys, and Emacs's.")

(defconst codetracer--modifiers
  '(("Ctrl" . "C-") ("Control" . "C-") ("Alt" . "M-") ("Meta" . "M-")
    ("Shift" . "S-") ("Super" . "s-") ("Cmd" . "s-"))
  "CodeTracer's spelling of modifiers, and Emacs's.")

(defun codetracer--emacs-key (key)
  "KEY in the CodeTracer keymap's spelling (\"Ctrl+F5\") as `keymap-set' takes it.
Nil when there is no Emacs spelling for it."
  (let* ((parts (split-string key "+"))
         ;; "Ctrl++" names the plus key.
         (parts (if (string-suffix-p "++" key)
                    (append (butlast (split-string (substring key 0 -2) "+")) '("+"))
                  parts))
         (base (car (last parts)))
         (mods (mapcar (lambda (m) (cdr (assoc m codetracer--modifiers))) (butlast parts))))
    (unless (or (memq nil mods) (string-empty-p base))
      (let* ((named (cdr (assoc base codetracer--named-keys)))
             (fkey (and (string-match-p "\\`F[0-9]+\\'" base)
                        (concat "<" (downcase base) ">")))
             (name (cond ((and named mods (not (string-prefix-p "<" named)))
                          ;; C-RET is not a key; C-<return> is.
                          (pcase named ("RET" "<return>") ("TAB" "<tab>")
                                 ("ESC" "<escape>") ("SPC" "SPC") ("DEL" "<backspace>")))
                         (named named)
                         (fkey fkey)
                         ((= (length base) 1) base)))
             (spelled (and name (concat (apply #'concat mods) name))))
        (and spelled (key-valid-p spelled) spelled)))))

(defun codetracer--codetracer-key (event)
  "EVENT in the CodeTracer keymap's spelling, or nil."
  ;; RET, TAB and ESC are control characters, which `event-modifiers' would
  ;; decompose into Control and a letter.
  (pcase event
    (13 "Enter") (9 "Tab") (27 "Escape") (127 "Backspace") (32 "Space")
    (_ (codetracer--codetracer-key-1 event))))

(defun codetracer--codetracer-key-1 (event)
  "EVENT, not a named control character, in CodeTracer's spelling, or nil."
  (let* ((mods (event-modifiers event))
         (basic (event-basic-type event))
         (base (cond ((integerp basic)
                      (pcase basic (?\r "Enter") (?\t "Tab") (27 "Escape")
                             (32 "Space") (127 "Backspace")
                             (_ (string (if (memq 'shift mods) (upcase basic) basic)))))
                     ((symbolp basic)
                      (let ((n (symbol-name basic)))
                        (or (car (rassoc (concat "<" n ">") codetracer--named-keys))
                            (pcase n ("return" "Enter") ("tab" "Tab")
                                   ("escape" "Escape") ("backspace" "Backspace"))
                            (and (string-match-p "\\`f[0-9]+\\'" n) (upcase n))))))))
    (when base
      (concat (if (memq 'control mods) "Ctrl+" "")
              (if (memq 'meta mods) "Alt+" "")
              (if (and (memq 'shift mods) (not (integerp basic))) "Shift+" "")
              (if (memq 'super mods) "Super+" "")
              base))))

(defun codetracer--keymap-keys (map)
  "The single-event keys MAP binds, in CodeTracer's spelling."
  (let (keys)
    (when (keymapp map)
      (map-keymap (lambda (event binding)
                    (when (and binding (not (keymapp binding)))
                      (when-let ((k (codetracer--codetracer-key event)))
                        (push k keys))))
                  map))
    (delete-dups (nreverse keys))))

(defun codetracer--user-shadowed ()
  "Your bindings in CodeTracer panes, as an alist of (PANE-OR-NIL . KEYS)."
  (cons (cons nil (codetracer--keymap-keys codetracer-pane-user-map))
        (mapcar (lambda (entry)
                  (cons (car entry) (codetracer--keymap-keys
                                     (codetracer--pane-user-map (car entry)))))
                codetracer-pane-user-maps)))

(defun codetracer--overrides-vector ()
  "Your bindings, as `initialize''s `keymapOverrides'."
  (vconcat (cl-loop for (pane . keys) in (codetracer--user-shadowed)
                    append (mapcar (lambda (k) (if pane `(:pane ,pane :key ,k) `(:key ,k)))
                                   keys))))

(defun codetracer-report-user-bindings ()
  "Tell the pane server which keys your own bindings take in its panes.
Run this after changing `codetracer-pane-user-map' or
`codetracer-pane-user-maps'; the panes' keymaps are rebuilt."
  (interactive)
  (let ((now (codetracer--user-shadowed)))
    (unless (equal now codetracer--reported-shadowed)
      ;; Each scope is replaced; one that no longer binds anything is
      ;; cleared.
      (dolist (scope (delete-dups (append (mapcar #'car now)
                                          (mapcar #'car codetracer--reported-shadowed))))
        (codetracer--request :keymap/shadowed
                             `(,@(when scope `(:pane ,scope))
                               :keys ,(vconcat (cdr (assoc scope now))))))
      (setq codetracer--reported-shadowed now))
    (codetracer--refresh-pane-keymaps)))

(defun codetracer--refresh-pane-keymaps ()
  "Rebuild every pane buffer's local keymap."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when codetracer--pane (codetracer--install-local-map)))))

(defun codetracer--install-local-map ()
  "Compose this pane buffer's keymap: yours first, then the server's."
  (use-local-map
   (make-composed-keymap
    (delq nil (list (codetracer--pane-user-map codetracer--pane)
                    codetracer-pane-user-map
                    codetracer--server-map))
    codetracer-pane-mode-map)))

(defun codetracer--on-pane-keymap (params)
  "Install the bindings of PARAMS, a `pane/keymap' notification.
The `editor' pane's are the source buffer's (`codetracer-source-mode')."
  (when-let* ((session (codetracer--session (plist-get params :session)))
              ((not (and (equal (plist-get params :pane) "editor")
                         (codetracer--on-editor-keymap session params))))
              (buffer (codetracer--pane-buffer session (plist-get params :pane))))
    (with-current-buffer buffer
      (let ((map (make-sparse-keymap)))
        ;; In resolution order: the first binding of a key wins.
        (seq-doseq (binding (reverse (plist-get params :bindings)))
          (let ((key (codetracer--emacs-key (plist-get binding :key))))
            (when (and key (not (plist-get binding :shadowedBy)))
              (keymap-set map key (codetracer--operation-command
                                   (plist-get binding :operation))))))
        (setq codetracer--server-map map)
        (codetracer--install-local-map)))))

;;;; Debugger controls

;; The debugger controls -- reverse and forward next, step in, step out and
;; continue, run to entry, stop -- are the server's (`controls/state'), the
;; ones CodeTracer's terminal draws in its top bar, in the same order.  They
;; are drawn at the right of the tab bar while a session's tab is current: the
;; tab bar is the row Emacs already shows for the sessions' tabs, so the
;; controls cost no window line and do not repeat in every source window.  A
;; click on one runs its operation; one that cannot act now is dimmed and does
;; nothing.

(defvar codetracer--tab-bar-format-taken nil
  "When CodeTracer added its item to `tab-bar-format': (BEFORE . AFTER).
BEFORE is the format it replaced, AFTER the one it set; nil otherwise.")

(defvar codetracer--tab-bar-format-offered nil
  "Non-nil once the user was told how to add the controls to their format.")

(defun codetracer--default-tab-bar-format-p ()
  "Non-nil when `tab-bar-format' is Emacs's default."
  (equal tab-bar-format (eval (car (get 'tab-bar-format 'standard-value)) t)))

(defun codetracer--sync-controls ()
  "Take `tab-bar-format' for the controls while sessions are open.
It is given back when the last one closes.  The format is taken only
when it is Emacs's default, and given back only when it is still what
CodeTracer set."
  (if (and (eq codetracer-controls 'tab-bar)
           (> (hash-table-count codetracer--sessions) 0))
      (cond ((or codetracer--tab-bar-format-taken
                 (memq 'codetracer-tab-bar-controls tab-bar-format)))
            ((codetracer--default-tab-bar-format-p)
             (let ((after (append tab-bar-format
                                  '(tab-bar-format-align-right codetracer-tab-bar-controls))))
               (setq codetracer--tab-bar-format-taken (cons tab-bar-format after)
                     tab-bar-format after)))
            ((not codetracer--tab-bar-format-offered)
             (setq codetracer--tab-bar-format-offered t)
             (message "CodeTracer: %s"
                      (substitute-command-keys
                       "add `codetracer-tab-bar-controls' to your `tab-bar-format' \
to show the debugger controls"))))
    (when codetracer--tab-bar-format-taken
      (when (equal tab-bar-format (cdr codetracer--tab-bar-format-taken))
        (setq tab-bar-format (car codetracer--tab-bar-format-taken)))
      (setq codetracer--tab-bar-format-taken nil)))
  (force-mode-line-update t))

(defun codetracer--on-controls-state (params)
  "Keep the controls PARAMS, a `controls/state' notification, sends."
  (when-let ((session (codetracer--session (plist-get params :session))))
    (setf (codetracer-session-controls session) (append (plist-get params :buttons) nil))
    (codetracer--sync-controls)))

(defun codetracer--control-glyph (button)
  "Return BUTTON's glyph, the one `codetracer-controls-glyphs' names."
  (let ((glyph (plist-get (plist-get button :glyphs)
                          (intern (format ":%s" codetracer-controls-glyphs)))))
    (if (and (stringp glyph) (not (string-empty-p glyph)))
        glyph
      (plist-get button :label))))

(defun codetracer--control-enabled-p (button)
  "Non-nil when BUTTON can act now."
  (eq (plist-get button :enabled) t))

(defun codetracer--control-command (session button)
  "Return the command of SESSION's BUTTON: its operation, on SESSION."
  (let ((operation (plist-get button :operation))
        (id (codetracer-session-id session)))
    (lambda ()
      (interactive)
      (codetracer--run operation :session id))))

(defun codetracer-tab-bar-controls ()
  "The current tab's debugger controls, as `tab-bar-format' items.
Nothing outside a session's tab.  Each control that can act is a
button running its operation; one that cannot is dimmed and inert.
Put this function in `tab-bar-format', after
`tab-bar-format-align-right', when you keep a format of your own
\(see `codetracer-controls')."
  (when-let ((session (codetracer--current-tab-session)))
    (mapcar (lambda (button)
              (let ((enabled (codetracer--control-enabled-p button)))
                `(,(intern (format "codetracer-control-%s" (plist-get button :id)))
                  menu-item
                  ,(propertize (format " %s " (codetracer--control-glyph button))
                               'face (if enabled 'codetracer-control
                                       'codetracer-control-disabled))
                  ,(if enabled (codetracer--control-command session button) #'ignore)
                  :help ,(or (plist-get button :tooltip) (plist-get button :label)))))
            (codetracer-session-controls session))))

;;;; Debugger keys in source buffers

;; In the session's source buffer, while its tab is current, the function-key
;; bindings of the debugger operations in the user's CodeTracer keymap (the
;; `editor' pane's `pane/keymap') are bound: F10 steps over where the code is
;; read, not only in CodeTracer's panes.  Only function-key chords: a
;; printable key or a C- chord is one of Emacs's own commands, and CodeTracer's
;; own text editing keys are not wanted in an Emacs buffer.  The keys live in
;; `codetracer-source-mode', a buffer-local minor mode, so `describe-key' and
;; `describe-mode' show them; each binding gives way, at the moment the key
;; is pressed, to any binding the buffer has without the mode other than one
;; of Emacs's own defaults.

(defconst codetracer--emacs-function-keys
  '(("<f1>" . help-command) ("<f2>" . 2C-command)
    ("<f3>" . kmacro-start-macro-or-insert-counter)
    ("<f4>" . kmacro-end-or-call-macro)
    ("<f10>" . menu-bar-open) ("<f11>" . toggle-frame-fullscreen)
    ("S-<f10>" . context-menu-open) ("C-<f10>" . buffer-menu-open)
    ("M-<f10>" . toggle-frame-maximized))
  "The function keys `emacs -Q' binds, and to what (Emacs 29 and 30).
A source buffer's debugger key takes the place of these; any other
binding of the key is the user's, and wins.")

(defvar codetracer-source-mode-map (make-sparse-keymap)
  "The keymap of `codetracer-source-mode'.
Each buffer's keys are its session's; they are installed with
`minor-mode-overriding-map-alist', so this map stays empty.")

(define-minor-mode codetracer-source-mode
  "CodeTracer's debugger keys in a session's source buffer.
The package turns it on in the source buffer of the session whose tab is
current, and off when the tab is left, the window shows another buffer,
or `codetracer-source-keys' is nil.  The keys are the function-key
bindings of the debugger operations in your CodeTracer keymap; a key
you bind yourself wins."
  :lighter " CT"
  :keymap codetracer-source-mode-map)

(defvar codetracer--source-key-buffers nil
  "The buffers in which `codetracer-source-mode' carries a session's keys.")

(defvar-local codetracer--source-keys-of nil
  "In a source buffer with CodeTracer's keys: (SESSION-ID . BINDINGS).")

(defun codetracer--source-key-p (key operation)
  "Non-nil when KEY for OPERATION may be bound in a source buffer.
KEY is in Emacs's spelling.  The debugger's operations and the
breakpoint and tracepoint toggles, on function-key chords only."
  (and (stringp key) (stringp operation)
       (string-match-p "\\`\\(?:[ACHMSs]-\\)*<f[0-9]+>\\'" key)
       (or (string-prefix-p "debugger." operation)
           (member operation '("editor.toggle-breakpoint" "editor.toggle-tracepoint")))))

(defun codetracer--source-bindings (bindings)
  "The keys of BINDINGS (a `pane/keymap''s) for a source buffer.
A list of (EMACS-KEY . OPERATION), the first binding of a key winning.
A key the editor already binds there (`shadowedBy') is left out."
  (let (out)
    (seq-doseq (b bindings)
      (let ((key (codetracer--emacs-key (or (plist-get b :key) "")))
            (operation (plist-get b :operation)))
        (when (and key (not (plist-get b :shadowedBy))
                   (codetracer--source-key-p key operation)
                   (not (assoc key out)))
          (push (cons key operation) out))))
    (nreverse out)))

(defun codetracer--on-editor-keymap (session params)
  "Keep the source keys of PARAMS for SESSION.
PARAMS is the `editor' pane's `pane/keymap'.  Return non-nil: the
`editor' pane has no buffer of its own."
  (setf (codetracer-session-source-bindings session)
        (codetracer--source-bindings (plist-get params :bindings)))
  ;; Rebound with the new keys.
  (dolist (b codetracer--source-key-buffers)
    (when (buffer-live-p b)
      (with-current-buffer b (setq codetracer--source-keys-of nil))))
  (codetracer--sync-source-keys)
  t)

(defun codetracer--user-binding (key)
  "The binding of KEY in this buffer, without `codetracer-source-mode'.
Nil when there is none, or when it is one of Emacs's own defaults."
  (let* ((codetracer-source-mode nil)
         (binding (key-binding (kbd key))))
    (unless (or (null binding)
                (eq binding (cdr (assoc key codetracer--emacs-function-keys))))
      binding)))

(defun codetracer--source-keymap (bindings)
  "The keymap of BINDINGS, (EMACS-KEY . OPERATION) pairs.
Each key runs its operation's command, unless the buffer binds the key
otherwise when it is pressed (`codetracer--user-binding')."
  (let ((map (make-sparse-keymap)))
    (pcase-dolist (`(,key . ,operation) bindings)
      (keymap-set map key
                  `(menu-item ,operation ,(codetracer--operation-command operation)
                              :filter ,(lambda (command)
                                         (unless (codetracer--user-binding key)
                                           command)))))
    map))

(defun codetracer--bind-source-keys (session buffer)
  "Turn on `codetracer-source-mode' in BUFFER, with SESSION's keys."
  (with-current-buffer buffer
    (let ((keys (cons (codetracer-session-id session)
                      (codetracer-session-source-bindings session))))
      (unless (and codetracer-source-mode (equal codetracer--source-keys-of keys))
        (setq-local minor-mode-overriding-map-alist
                    (cons (cons 'codetracer-source-mode
                                (codetracer--source-keymap (cdr keys)))
                          (assq-delete-all 'codetracer-source-mode
                                           (copy-sequence minor-mode-overriding-map-alist))))
        (setq codetracer--source-keys-of keys)
        (codetracer-source-mode 1))))
  (cl-pushnew buffer codetracer--source-key-buffers))

(defun codetracer--unbind-source-keys (buffer)
  "Turn off `codetracer-source-mode' in BUFFER and drop its keys."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (codetracer-source-mode -1)
      (setq-local minor-mode-overriding-map-alist
                  (assq-delete-all 'codetracer-source-mode
                                   (copy-sequence minor-mode-overriding-map-alist)))
      (setq codetracer--source-keys-of nil)))
  (setq codetracer--source-key-buffers (delq buffer codetracer--source-key-buffers)))

(defun codetracer--sync-source-keys ()
  "Bind the debugger keys in the current tab's source buffer, and nowhere else.
The source buffer is the buffer of the current tab's session's source
window, when it is a source: a file, or a source read from the recording."
  (let* ((session (and codetracer-source-keys (codetracer--current-tab-session)))
         (window (and session (codetracer-session-source-bindings session)
                      (codetracer--source-window session)))
         (buffer (and (window-live-p window) (window-buffer window)))
         (keep (and buffer
                    (with-current-buffer buffer
                      (or buffer-file-name codetracer--recorded-path))
                    buffer)))
    (dolist (b (copy-sequence codetracer--source-key-buffers))
      (unless (eq b keep)
        (codetracer--unbind-source-keys b)))
    (when keep
      (codetracer--bind-source-keys session keep))))

;;;; Source buffers

(define-fringe-bitmap 'codetracer-breakpoint
  [#b00111100 #b01111110 #b11111111 #b11111111
              #b11111111 #b11111111 #b01111110 #b00111100]
  nil nil 'center)

(defun codetracer--fringe-string (bitmap face)
  "A `before-string' drawing BITMAP in the left fringe with FACE."
  (propertize " " 'display `(left-fringe ,bitmap ,face)))

(defun codetracer--source-window (session)
  "The window SESSION's source is shown in.
The window already showing the position's file, else the selected
window when it is not a side window, else any live window that is not."
  (let* ((file (plist-get (codetracer-session-position session) :file))
         (windows (cl-remove-if (lambda (w) (window-parameter w 'window-side))
                                (window-list nil 'nomini))))
    (or (and file (cl-find-if (lambda (w) (equal (buffer-file-name (window-buffer w))
                                                 file))
                              windows))
        (and (memq (selected-window) windows) (selected-window))
        (car windows)
        (selected-window))))

(defun codetracer--on-position (params)
  "Follow the debugger to the position in PARAMS."
  (let ((session (codetracer--session (plist-get params :session))))
    (if (not session)
        (puthash (plist-get params :session) params codetracer--early-positions)
      (setf (codetracer-session-position session) params)
      (when (eq (codetracer--current-tab-session) session)
        (codetracer--show-position session params)))))

(defun codetracer--show-position (session pos)
  "Show SESSION's position POS in its source window and mark the line."
  (let ((buffer (codetracer--source-buffer session (plist-get pos :file))))
    (when buffer
      (let* (
             (window (codetracer--source-window session))
             (codetracer--realizing t))
        (set-window-dedicated-p window nil)
        (set-window-buffer window buffer)
        (with-current-buffer buffer
          (goto-char (point-min))
          (forward-line (1- (max 1 (plist-get pos :line))))
          (move-to-column (max 0 (1- (or (plist-get pos :column) 1))))
          (set-window-point window (point))
          (codetracer--mark-execution session buffer (line-beginning-position)))
        (codetracer--report-source-viewport session window)
        (codetracer--sync-source-keys)))))

(defun codetracer--mark-execution (session buffer pos)
  "Mark the execution line at POS in BUFFER for SESSION."
  (let ((key (cons :execution (codetracer-session-id session))))
    (when-let ((old (gethash key (codetracer-session-decorations session))))
      (mapc #'delete-overlay old))
    (with-current-buffer buffer
      (save-excursion
        (goto-char pos)
        (let ((ov (make-overlay (line-beginning-position) (1+ (line-end-position)))))
          (overlay-put ov 'face 'codetracer-execution-line)
          (overlay-put ov 'before-string
                       (codetracer--fringe-string 'right-triangle 'codetracer-execution-fringe))
          (overlay-put ov 'codetracer t)
          (overlay-put ov 'priority 10)
          (puthash key (list ov) (codetracer-session-decorations session)))))))

(defun codetracer--report-source-viewport (session window)
  "Tell the server the lines visible in SESSION's source WINDOW.
The server answers with that file's decorations and its tests."
  (let ((file (with-current-buffer (window-buffer window)
                (or codetracer--recorded-path buffer-file-name))))
    (when file
      (with-current-buffer (window-buffer window)
        (let ((first (line-number-at-pos (window-start window)))
              (last (line-number-at-pos (or (window-end window t) (point-max)))))
          (codetracer--send :source/viewport
                            `(:session ,(codetracer-session-id session)
                                       :file ,file :firstLine ,first
                                       :lastLine ,(max first last))))))))

(defun codetracer--on-window-scroll (window _start)
  "When the user scrolls a source WINDOW, report its visible lines."
  (when (and (codetracer--live-p) (not codetracer--realizing)
             (with-current-buffer (window-buffer window)
               (or codetracer--recorded-path buffer-file-name)))
    (when-let ((session (codetracer--current-tab-session)))
      (when (eq window (codetracer--source-window session))
        (codetracer--report-source-viewport session window)))))

(defun codetracer--decoration-string (items face)
  "ITEMS (name/value plists) as an `after-string' in FACE."
  (propertize (concat "  "
                      (mapconcat (lambda (it) (format "%s = %s" (plist-get it :name)
                                                      (plist-get it :value)))
                                 items ", "))
              'face face))

(defun codetracer--on-decorations (params)
  "Draw the inline values and the fringe mark of each row of PARAMS."
  (when-let* ((session (codetracer--session (plist-get params :session)))
              (file (plist-get params :file))
              (buffer (find-buffer-visiting file)))
    (let ((key (cons :file file)))
      (when-let ((old (gethash key (codetracer-session-decorations session))))
        (mapc #'delete-overlay old))
      (let (overlays)
        (with-current-buffer buffer
          (save-excursion
            (seq-doseq (row (plist-get params :rows))
              (goto-char (point-min))
              (when (zerop (forward-line (1- (plist-get row :line))))
                (let ((bol (line-beginning-position)) (eol (line-end-position)))
                  (pcase (plist-get row :mark)
                    ((and (pred stringp) mark (guard (not (string-empty-p mark))))
                     (let ((ov (make-overlay bol bol)))
                       (overlay-put ov 'before-string
                                    (codetracer--fringe-string
                                     'codetracer-breakpoint
                                     (if (equal mark "tracepoint")
                                         'codetracer-tracepoint-fringe
                                       'codetracer-breakpoint-fringe)))
                       (overlay-put ov 'codetracer-mark mark)
                       (push ov overlays))))
                  (let ((values (append (plist-get row :values) nil))
                        (flow (append (plist-get row :flow) nil)))
                    (when (or values flow)
                      (let ((ov (make-overlay eol eol)))
                        (overlay-put ov 'after-string
                                     (concat (if values (codetracer--decoration-string
                                                         values 'codetracer-inline-value)
                                               "")
                                             (if flow (codetracer--decoration-string
                                                       flow 'codetracer-flow-value)
                                               "")))
                        (overlay-put ov 'codetracer-values (or values flow))
                        (push ov overlays)))))))))
        (puthash key overlays (codetracer-session-decorations session))))))

(defun codetracer--clear-decorations (session)
  "Remove every overlay SESSION drew."
  (maphash (lambda (_k overlays) (mapc #'delete-overlay overlays))
           (codetracer-session-decorations session))
  (clrhash (codetracer-session-decorations session)))

;;;; Tests from the source

;; A source file's tests -- the ones the session's Test Results pane lists,
;; with their lines and last verdicts -- arrive as `source/tests' for the
;; file the source window shows, and again when a test or its state
;; changes.  They are drawn in every buffer visiting that file: a fringe
;; mark on the test's line (`codetracer-tests-placement'), whose
;; `[left-fringe mouse-1]' records the test, or a button line above it.  A
;; press is the Test Results pane's own (`tests.open-test'), so the source
;; and the pane cannot disagree about what a test is or what it did; the
;; recording opens as a session of its own (`session/opened').
;;
;; The click binding lives in a `keymap' overlay property on the test's
;; line only.  A mouse event is looked up in the keymaps at its position,
;; so a fringe click on any other line, and every key and click in the
;; text, stay what they were.

(define-fringe-bitmap 'codetracer-test-play
  [#b11000000 #b11110000 #b11111100 #b11111111
              #b11111111 #b11111100 #b11110000 #b11000000]
  nil nil 'center)

(define-fringe-bitmap 'codetracer-test-passed
  [#b00000000 #b00000011 #b00000110 #b11001100
              #b01111000 #b00110000 #b00000000 #b00000000]
  nil nil 'center)

(define-fringe-bitmap 'codetracer-test-failed
  [#b11000011 #b01100110 #b00111100 #b00011000
              #b00111100 #b01100110 #b11000011 #b00000000]
  nil nil 'center)

(defvar codetracer-test-line-map
  (let ((map (make-sparse-keymap)))
    (define-key map [left-fringe mouse-1] #'codetracer-test-fringe-click)
    (define-key map [left-fringe C-mouse-1] #'codetracer-test-fringe-click-here)
    ;; The presses whose releases are the clicks above: without these,
    ;; Emacs would read them as the text area's (C-down-mouse-1 pops up
    ;; the buffer menu).
    (define-key map [left-fringe down-mouse-1] #'ignore)
    (define-key map [left-fringe C-down-mouse-1] #'ignore)
    map)
  "The fringe clicks on a test's line, from its overlay's `keymap'.")

(defvar-local codetracer--test-overlays nil
  "The overlays drawing this buffer's tests.")

(defun codetracer--test-file-key (file)
  "The key of FILE's test controls: its absolute name, links resolved."
  (file-truename (expand-file-name file)))

(defun codetracer--buffer-test-file (buffer)
  "The key of the file in BUFFER (a visited file or a recorded source), or nil."
  (with-current-buffer buffer
    (let ((file (or codetracer--recorded-path buffer-file-name)))
      (and file (codetracer--test-file-key file)))))

(defun codetracer--tests-session (key)
  "The session whose test controls for the file KEY are drawn.
It is the current tab's when it holds that file's, else any that does."
  (let ((current (codetracer--current-tab-session)))
    (if (and current (gethash key (codetracer-session-tests current)))
        current
      (cl-loop for s being the hash-values of codetracer--sessions
               when (gethash key (codetracer-session-tests s)) return s))))

(defun codetracer--test-fringe (control)
  "The fringe bitmap and face of the test CONTROL: its last verdict, or play."
  (pcase (plist-get control :state)
    ("passed" '(codetracer-test-passed . codetracer-test-passed-fringe))
    ("failed" '(codetracer-test-failed . codetracer-test-failed-fringe))
    (_ '(codetracer-test-play . codetracer-test-fringe))))

(defun codetracer--test-button (session control)
  "The above-line button recording SESSION's test CONTROL, newline included."
  (let ((id (codetracer-session-id session))
        (test (plist-get control :testId)))
    (concat (make-text-button
             (format "▶ Record %s" (plist-get control :name)) nil
             'face 'codetracer-test-fringe
             'follow-link t
             'help-echo "Record this test"
             'action (lambda (_button)
                       (when-let* ((s (codetracer--session id)))
                         (codetracer--record-test s (codetracer--test-control s test)))))
            "\n")))

(defun codetracer--render-tests (buffer)
  "Draw in BUFFER the test controls of its file, from a session."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (mapc #'delete-overlay codetracer--test-overlays)
      (setq codetracer--test-overlays nil)
      (when-let* ((key (codetracer--buffer-test-file buffer))
                  (session (codetracer--tests-session key)))
        (let ((gutter (memq codetracer-tests-placement '(gutter both)))
              (above (memq codetracer-tests-placement '(above-line both))))
          (save-excursion
            (save-restriction
              (widen)
              (dolist (control (gethash key (codetracer-session-tests session)))
                (let ((line (plist-get control :line)))
                  (goto-char (point-min))
                  (when (and (integerp line) (> line 0) (zerop (forward-line (1- line))))
                    (let ((ov (make-overlay (line-beginning-position)
                                            (min (point-max) (1+ (line-end-position)))
                                            nil t nil))
                          (fringe (codetracer--test-fringe control)))
                      (overlay-put ov 'codetracer-test control)
                      (overlay-put ov 'codetracer-test-session (codetracer-session-id session))
                      (overlay-put ov 'before-string
                                   (concat (if above (codetracer--test-button session control) "")
                                           (if gutter
                                               (codetracer--fringe-string (car fringe) (cdr fringe))
                                             "")))
                      (when gutter
                        (overlay-put ov 'keymap codetracer-test-line-map))
                      (push ov codetracer--test-overlays))))))))))))

(defun codetracer--render-file-tests (key)
  "Draw the test controls in every buffer visiting the file KEY."
  (dolist (buffer (buffer-list))
    (when (equal (codetracer--buffer-test-file buffer) key)
      (codetracer--render-tests buffer))))

(defun codetracer--render-all-tests ()
  "Draw the test controls in every buffer visiting a file.
After a session closed or the tab changed, another session's may now be
the ones drawn."
  (dolist (buffer (buffer-list))
    (when (or (buffer-local-value 'codetracer--test-overlays buffer)
              (and (codetracer--buffer-test-file buffer)
                   (codetracer--tests-session (codetracer--buffer-test-file buffer))))
      (codetracer--render-tests buffer))))

(defun codetracer--render-current-tests ()
  "Draw the test controls of the current buffer, a file just visited."
  (when (codetracer--live-p)
    (codetracer--render-tests (current-buffer))))

(defun codetracer--on-source-tests (params)
  "Keep and draw the test controls of a file, from PARAMS.
PARAMS are a `source/tests' notification's."
  (when-let* ((session (codetracer--session (plist-get params :session)))
              (file (plist-get params :file))
              ((stringp file)))
    (let ((key (codetracer--test-file-key file)))
      (puthash key (append (plist-get params :controls) nil)
               (codetracer-session-tests session))
      (codetracer--render-file-tests key))))

(defun codetracer--test-control (session test)
  "SESSION's control of the test whose id is TEST, or nil."
  (cl-loop for controls being the hash-values of (codetracer-session-tests session)
           thereis (cl-find test controls
                            :key (lambda (c) (plist-get c :testId)) :test #'equal)))

(defun codetracer--record-test (session control &optional here)
  "Record SESSION's test CONTROL and open its recording.
The recording opens in a tab of its own; with HERE, in place of
SESSION (the Test Results pane's Ctrl on the press).  A control that
cannot act now shows why instead."
  (let ((open (plist-get control :open)))
    (cond ((null control)
           (message "CodeTracer: that test is no longer listed"))
          ((eq (plist-get open :enabled) :json-false)
           (message "CodeTracer: %s" (or (plist-get open :title)
                                         "this test cannot be recorded now")))
          (t
           (codetracer--run "tests.open-test"
                            :session (codetracer-session-id session)
                            :pane "testResults"
                            :args `(:path ,(plist-get control :testId)
                                          ,@(when here '(:text "redirect"))))))))

(defun codetracer--test-at-event (event)
  "The (SESSION . CONTROL) of the test on the line EVENT was on, or nil."
  (let* ((posn (event-start event))
         (window (posn-window posn))
         (pos (posn-point posn)))
    (when (and (windowp window) (integer-or-marker-p pos))
      (with-current-buffer (window-buffer window)
        (cl-loop for ov in (overlays-at pos)
                 for control = (overlay-get ov 'codetracer-test)
                 for session = (codetracer--session (overlay-get ov 'codetracer-test-session))
                 when (and control session) return (cons session control))))))

(defun codetracer-test-fringe-click (event &optional here)
  "Record the test whose fringe mark EVENT clicked; its recording opens.
With HERE, it opens in place of the session the test is from."
  (interactive "e")
  (if-let* ((hit (codetracer--test-at-event event)))
      (codetracer--record-test (car hit) (cdr hit) here)
    (message "CodeTracer: no test on this line")))

(defun codetracer-test-fringe-click-here (event)
  "Record the test whose fringe mark EVENT clicked, in place of its session."
  (interactive "e")
  (codetracer-test-fringe-click event t))

(defun codetracer-test-at-point (&optional here)
  "Record the test point is in, and open its recording in a tab of its own.
The test is the last one CodeTracer lists in this file whose line is at
or above point.  With a prefix argument HERE, the recording takes the
place of the current session instead."
  (interactive "P")
  (let* ((key (or (codetracer--buffer-test-file (current-buffer))
                  (user-error "This buffer shows no file")))
         (session (codetracer--tests-session key))
         (line (line-number-at-pos))
         (best nil))
    (dolist (control (and session (gethash key (codetracer-session-tests session))))
      (let ((at (plist-get control :line)))
        (when (and (integerp at) (<= at line)
                   (or (null best) (> at (plist-get best :line))))
          (setq best control))))
    (unless best
      (user-error "No test of CodeTracer's at point"))
    (codetracer--record-test session best here)))

;;;; Panel roles

;; The source editor is always Emacs's own buffers (E7): the source window
;; reports its cursor (`source/cursor'), which is what an operation "at the
;; cursor" acts on and how the server learns which file the user opened.
;; The file tree is CodeTracer's file pane unless `codetracer-panels-file-tree'
;; gives the role to Emacs: a `dired' listing of the recording's sources then
;; takes the file pane's place, its selection is reported (`files/selected'),
;; and the files created, renamed and deleted beside the sources are reported
;; (`files/changed').  A source that is not on this disk is read from the
;; recording (`source/read') into a read-only buffer.

(defun codetracer--source-paths (session)
  "The paths of SESSION's recorded sources."
  (mapcar (lambda (e) (plist-get e :path)) (codetracer-session-sources session)))

(defun codetracer--recorded-buffer (session path)
  "A read-only buffer holding SESSION's recorded source PATH.
For a source that is not on this disk: its text as the recording holds
it, filled in when the server answers `source/read' (this may run from a
notification, where a request must not wait)."
  (let* ((name (format "*codetracer %s: %s*" (codetracer-session-id session)
                       (file-name-nondirectory path)))
         (buffer (get-buffer name)))
    (or buffer
        (with-current-buffer (get-buffer-create name)
          ;; The file's own major mode, as visiting it would choose.
          (let ((buffer-file-name path))
            (set-auto-mode))
          (setq-local codetracer--recorded-path path)
          (setq-local codetracer--pane-session (codetracer-session-id session))
          (read-only-mode 1)
          (codetracer--render-tests (current-buffer))
          (let ((target (current-buffer)))
            (codetracer--send :source/read
                              `(:session ,(codetracer-session-id session) :file ,path)
                              (lambda (result)
                                (when (buffer-live-p target)
                                  (with-current-buffer target
                                    (let ((inhibit-read-only t)
                                          (point (point)))
                                      (erase-buffer)
                                      (insert (or (plist-get result :text) ""))
                                      (set-buffer-modified-p nil)
                                      (goto-char (min point (point-max)))))))))
          (current-buffer)))))

(defun codetracer--source-buffer (session path)
  "The buffer to show SESSION's source PATH in: the file, or its recorded text."
  (cond ((not (stringp path)) nil)
        ((file-exists-p path) (find-file-noselect path))
        (t (codetracer--recorded-buffer session path))))

(defun codetracer-sources ()
  "Open one of the recording's sources, read-only when it is not on this disk."
  (interactive)
  (let* ((session (or (codetracer--current-tab-session)
                      (user-error "This tab shows no CodeTracer session")))
         (path (completing-read "Recorded source: "
                                (codetracer--source-paths session) nil t)))
    (pop-to-buffer-same-window (codetracer--source-buffer session path))))

(defun codetracer--common-directory (files)
  "The deepest directory holding every one of FILES."
  (let ((dir (if files (file-name-directory (car files)) default-directory)))
    (while (and (cl-notevery (lambda (f) (string-prefix-p dir f)) files)
                (not (equal dir (file-name-directory (directory-file-name dir)))))
      (setq dir (file-name-directory (directory-file-name dir))))
    dir))

(defun codetracer--file-tree-name (session)
  "The name of SESSION's file-tree listing."
  (format "*codetracer %s: files*" (codetracer-session-id session)))

(defun codetracer--file-tree-buffer (session)
  "SESSION's `dired' listing of its sources: the file-tree role in Emacs.
It lists the sources on this disk; `codetracer-sources' offers them all."
  (let* ((files (cl-remove-if-not #'file-exists-p (codetracer--source-paths session)))
         (root (codetracer--common-directory files))
         (old (get-buffer (codetracer--file-tree-name session))))
    (when old (kill-buffer old))
    (let ((buffer (dired-noselect (cons root (mapcar (lambda (f) (file-relative-name f root))
                                                     files)))))
      (with-current-buffer buffer
        (rename-buffer (codetracer--file-tree-name session) t)
        (setq codetracer--role "fileTree"
              codetracer--pane-session (codetracer-session-id session))
        (add-hook 'post-command-hook #'codetracer--file-tree-selection nil t))
      (puthash "fileTree" buffer (codetracer-session-panes session))
      buffer)))

(defvar-local codetracer--file-tree-selected nil
  "In a file-tree listing, the file last reported selected.")

(defun codetracer--file-tree-selection ()
  "Report the file under point in a file-tree listing, when it changed."
  (when-let* (((codetracer--live-p))
              (file (ignore-errors (dired-get-filename nil t))))
    (unless (equal file codetracer--file-tree-selected)
      (setq codetracer--file-tree-selected file)
      (codetracer--notify :files/selected `(:session ,codetracer--pane-session
                                            :path ,file)))))

(defvar codetracer--cursor-sent nil
  "The (FILE LINE COLUMN) last reported with `source/cursor'.")

(defun codetracer--byte-column ()
  "Point's column as the protocol counts it: 1-based, in bytes of UTF-8.
The pane server's positions are byte offsets (`positionEncoding' utf-8,
the LSP base protocol's), so a tab is one byte and a non-ASCII character
its UTF-8 length; `current-column' counts display columns instead, and
the two differ on any line with either."
  (1+ (- (position-bytes (point))
         (position-bytes (line-beginning-position)))))

(defun codetracer--send-cursor (session file &optional force)
  "Report point, in FILE, as SESSION's cursor (`source/cursor').
The line and the column are 1-based, the column in bytes
\=(`codetracer--byte-column').  A cursor already reported is not sent
again, unless FORCE: an operation about to act at the cursor sends it
whatever was sent before, since another session's report may have come
between."
  (let ((at (list file (line-number-at-pos) (codetracer--byte-column))))
    (when (or force (not (equal at codetracer--cursor-sent)))
      (setq codetracer--cursor-sent at)
      (codetracer--notify :source/cursor
                          `(:session ,(codetracer-session-id session)
                            :file ,(nth 0 at) :line ,(nth 1 at) :column ,(nth 2 at))))))

(defun codetracer--report-cursor ()
  "Report the cursor of the selected window when it is in a recorded source."
  (when-let* (((codetracer--live-p))
              (session (codetracer--current-tab-session))
              (file (or codetracer--recorded-path buffer-file-name))
              ((member file (codetracer--source-paths session))))
    (codetracer--send-cursor session file)))

(defun codetracer--watch-sources (session)
  "Report files created, renamed and deleted beside SESSION's sources.
Only when Emacs fills the file-tree role: CodeTracer's own pane lists the
project itself."
  (when (and (eq codetracer-panels-file-tree 'editor)
             (null (codetracer-session-watches session)))
    (let ((dirs (delete-dups
                 (delq nil (mapcar (lambda (p) (and (file-exists-p p) (file-name-directory p)))
                                   (codetracer--source-paths session))))))
      (setf (codetracer-session-watches session)
            (delq nil (mapcar (lambda (dir)
                                (ignore-errors
                                  (file-notify-add-watch
                                   dir '(change)
                                   (lambda (event) (codetracer--on-file-event session event)))))
                              dirs))))))

(defun codetracer--own-file-p (file)
  "Non-nil when FILE is Emacs's own lock, backup or auto-save file."
  (let ((name (file-name-nondirectory file)))
    (or (string-prefix-p ".#" name)
        (string-suffix-p "~" name)
        (and (string-prefix-p "#" name) (string-suffix-p "#" name)))))

(defun codetracer--on-file-event (session event)
  "Report the file EVENT beside SESSION's sources as `files/changed'.
Emacs's own lock, backup and auto-save files are not the user's files."
  (let ((id (codetracer-session-id session)))
    (pcase (and (not (codetracer--own-file-p (nth 2 event))) event)
      (`(,_ created ,file . ,_)
       (codetracer--notify :files/changed `(:session ,id :created ,(vector file)
                                            :deleted [] :renamed [])))
      (`(,_ deleted ,file . ,_)
       (codetracer--notify :files/changed `(:session ,id :created [] :deleted ,(vector file)
                                            :renamed [])))
      (`(,_ renamed ,file ,new . ,_)
       (codetracer--notify :files/changed `(:session ,id :created [] :deleted []
                                            :renamed [(:from ,file :to ,new)]))))))

(defun codetracer--unwatch-sources (session)
  "Stop watching SESSION's source directories."
  (mapc #'file-notify-rm-watch (codetracer-session-watches session))
  (setf (codetracer-session-watches session) nil))

(defun codetracer--fetch-sources (session)
  "Ask for SESSION's recorded sources and keep them."
  (setf (codetracer-session-sources session)
        (append (codetracer--request :session/files
                                     `(:session ,(codetracer-session-id session)))
                nil)))

(defun codetracer--on-source-show (params)
  "Show the file PARAMS names in the source window: a pane opened it.
When PARAMS names a place in it (`line', and `column' in UTF-8 bytes,
both 1-based -- a press on an instruction of the generated C, a
Problems row), point goes there."
  (when-let* ((session (codetracer--session (plist-get params :session)))
              (buffer (codetracer--source-buffer session (plist-get params :file))))
    (let ((window (codetracer--source-window session))
          (line (plist-get params :line))
          (column (plist-get params :column))
          (codetracer--realizing t))
      (set-window-dedicated-p window nil)
      (set-window-buffer window buffer)
      (when (and (integerp line) (> line 0))
        (with-current-buffer buffer
          (let ((pos (codetracer--byte-position line (if (integerp column) column 1))))
            (goto-char pos)
            (set-window-point window pos))))
      (codetracer--sync-source-keys))))

(defun codetracer--byte-position (line column)
  "The position of 1-based LINE and 1-based UTF-8 byte COLUMN, clamped."
  (save-excursion
    (goto-char (point-min))
    (forward-line (1- line))
    (let* ((start (point))
           (end (line-end-position))
           (text (encode-coding-string (buffer-substring-no-properties start end) 'utf-8))
           (bytes (min (max 0 (1- column)) (length text))))
      (+ start (length (decode-coding-string (substring text 0 bytes) 'utf-8))))))

;;;; Desktop

;; Emacs's `desktop' keeps the user's arrangement across restarts: the
;; frames, the tab-bar tabs and the windows, including windows the user
;; added beside ours.  A pane buffer saves which recording, pane, mode and
;; tab it belonged to; after `desktop-read', each recording is opened again,
;; the restored buffers become its panes, and the windows `desktop' put back
;; are kept.  The server's layout is used only where no window survived.

(defvar codetracer--restored-panes nil
  "Pane buffers `desktop' restored, waiting for their session.")

(defun codetracer--desktop-buffer-misc (_dirname)
  "Return this pane buffer's session, for `desktop' to save, as a plist."
  (when-let ((session (codetracer--session codetracer--pane-session)))
    (list :trace (codetracer-session-trace session)
          :pane codetracer--pane
          :mode (codetracer-session-mode session)
          :tab (codetracer-session-tab session))))

;;;###autoload
(defun codetracer--desktop-restore-pane (_file-name buffer-name misc)
  "Restore the pane buffer BUFFER-NAME from its `desktop' MISC data."
  (when (plist-get misc :trace)
    (with-current-buffer (get-buffer-create buffer-name)
      (codetracer-pane-mode)
      (setq codetracer--pane (plist-get misc :pane))
      (setq-local codetracer--restored misc)
      (setq-local desktop-save-buffer #'codetracer--desktop-buffer-misc)
      (push (current-buffer) codetracer--restored-panes)
      (current-buffer))))

;;;###autoload
(with-eval-after-load 'desktop
  (add-to-list 'desktop-buffer-mode-handlers
               '(codetracer-pane-mode . codetracer--desktop-restore-pane))
  (add-hook 'desktop-after-read-hook #'codetracer--desktop-reconnect))

(defun codetracer--desktop-reconnect ()
  "Open the sessions the restored pane buffers belonged to, and adopt them."
  (let ((buffers (cl-remove-if-not #'buffer-live-p (nreverse codetracer--restored-panes)))
        (traces nil))
    (setq codetracer--restored-panes nil)
    (dolist (b buffers)
      (let ((misc (buffer-local-value 'codetracer--restored b)))
        (unless (assoc (plist-get misc :trace) traces)
          (push (cons (plist-get misc :trace) misc) traces))))
    (dolist (entry (nreverse traces))
      (condition-case err
          (codetracer--adopt-restored (car entry) (cdr entry)
                                      (cl-remove-if-not
                                       (lambda (b) (equal (plist-get (buffer-local-value
                                                                      'codetracer--restored b)
                                                                     :trace)
                                                          (car entry)))
                                       buffers))
        (error (message "CodeTracer: could not reopen %s: %s"
                        (car entry) (error-message-string err)))))))

(defun codetracer--adopt-restored (trace misc buffers)
  "Reopen TRACE as `desktop' saved it (MISC) and adopt its pane BUFFERS."
  (unless (codetracer--live-p)
    (codetracer--start-server))
  (let* ((result (codetracer--request :session/open `(:trace ,trace)))
         (session (codetracer--new-session trace result))
         (id (codetracer-session-id session))
         (old-tab (plist-get misc :tab)))
    (setq codetracer--active-session id)
    (codetracer--fetch-sources session)
    (codetracer--watch-sources session)
    ;; The restored tab becomes the session's; its name names the new id.
    (let ((codetracer--realizing t))
      (tab-bar-mode 1)
      (if (and old-tab (tab-bar--tab-index-by-name old-tab))
          (tab-bar-select-tab-by-name old-tab)
        (tab-bar-new-tab))
      (tab-bar-rename-tab (codetracer--tab-name session)))
    (setf (codetracer-session-tab session) (codetracer--tab-name session))
    (dolist (b buffers)
      (with-current-buffer b
        (setq codetracer--pane-session id
              codetracer--pane-open nil
              codetracer--pane-size nil
              codetracer--restored nil)
        (rename-buffer (codetracer--pane-buffer-name id codetracer--pane) t))
      (puthash (buffer-local-value 'codetracer--pane b) b (codetracer-session-panes session)))
    ;; The mode the user left it in.
    (unless (equal (plist-get misc :mode) (codetracer-session-mode session))
      (codetracer--run "session.toggle-product-mode" :session id))
    ;; The windows `desktop' restored are the user's arrangement.
    (if (codetracer--session-windows session)
        (progn
          (setf (codetracer-session-realized session) (codetracer-session-layout session))
          (codetracer--show-layout session))
      (codetracer--realize session))
    (when-let ((pos (codetracer-session-position session)))
      (codetracer--show-position session pos))
    session))

;;;; Nim compile-time tracing

;; In a Nim project, CodeTracer traces what the compiler runs: a macro's
;; expansion, a `static:' block, a constant's evaluation, a NimScript run
;; (`nim e').  The trace runs codetracer-nim's trace-enabled nimsuggest (or
;; `nim e --trace') over the saved file at the session's cursor, and its
;; recording opens as a session of its own (`session/opened'), in a new tab;
;; the session it was started from keeps its mode.  The commands below
;; report point first, since the server acts at the cursor it was last told
;; of, and `codetracer-context-menu' offers them on a right click in a Nim
;; buffer (`context-menu-mode').

(defconst codetracer--nim-trace-items
  '(("Trace macro" . codetracer-trace-macro-at-point)
    ("Trace static block" . codetracer-trace-static-block-at-point)
    ("Trace constant" . codetracer-trace-constant-at-point)
    ("Evaluate with nim e" . codetracer-trace-eval))
  "The CodeTracer submenu of a Nim buffer's context menu: label, command.")

(defconst codetracer--generated-code-items
  '(("View generated C" . codetracer-view-generated-c)
    ("View disassembly" . codetracer-view-disassembly))
  "The generated-code entries of a Nim buffer's CodeTracer submenu.")

(defun codetracer--nim-buffer-p (&optional buffer)
  "Non-nil when BUFFER (the current one when nil) is Nim source.
That is a `.nim' or `.nims' file, or a buffer in `nim-mode' or a mode
derived from it (`nimscript-mode' among them)."
  (with-current-buffer (or buffer (current-buffer))
    (or (derived-mode-p 'nim-mode 'nimscript-mode)
        (let ((file (or codetracer--recorded-path buffer-file-name)))
          (and (stringp file) (string-match-p "\\.nims?\\'" file))))))

(defun codetracer--nim-session ()
  "The session a Nim trace is run for: the current tab's, or the active one."
  (or (codetracer--current-tab-session)
      (and codetracer--active-session (codetracer--session codetracer--active-session))))

(defun codetracer--run-at-point (operation)
  "Run OPERATION at point, in the selected window.
Point is reported as the session's cursor first (`source/cursor'), since
the server acts at the cursor it was last told of.  A refusal is shown in
the echo area."
  (unless (codetracer--live-p)
    (user-error "CodeTracer is not running; start it with `codetracer-open'"))
  (let ((session (or (codetracer--nim-session)
                     (user-error "No CodeTracer session is open")))
        (file (or codetracer--recorded-path buffer-file-name
                  (user-error "This buffer shows no file"))))
    (codetracer--send-cursor session file t)
    (codetracer--run operation :session (codetracer-session-id session))))

(defun codetracer--trace-at-point (operation)
  "Run the Nim trace OPERATION at point, in the selected window.
A refusal -- no Nim tracer, nothing to trace at the cursor -- is shown in
the echo area; the recording opens in a tab of its own when it is made."
  (codetracer--run-at-point operation))

(defun codetracer-trace-macro-at-point ()
  "Trace the expansion of the Nim macro at point; its recording opens.
The trace reads the saved file."
  (interactive)
  (codetracer--trace-at-point "editor.trace-macro-at-cursor"))

(defun codetracer-trace-static-block-at-point ()
  "Trace the Nim `static:' block point is in; its recording opens.
The trace reads the saved file."
  (interactive)
  (codetracer--trace-at-point "editor.trace-static-block-at-cursor"))

(defun codetracer-trace-constant-at-point ()
  "Trace the evaluation of the Nim constant at point; its recording opens.
The trace reads the saved file."
  (interactive)
  (codetracer--trace-at-point "editor.trace-constant-at-cursor"))

(defun codetracer-trace-eval ()
  "Evaluate this NimScript with `nim e', traced; its recording opens.
The trace reads the saved file."
  (interactive)
  (codetracer--trace-at-point "editor.trace-eval"))

;; The C a Nim line compiled to, and the machine code: both are shown in the
;; Low Level Code pane, which the server places beside the source when the
;; layout has none (its `layout/changed' opens the pane's window).  The C is
;; read from the recording, which bundles the generated C of a native Nim
;; program; a line of another language is refused with the reason.

(defun codetracer-view-generated-c ()
  "Show the C the Nim line at point compiled to, in the Low Level Code pane."
  (interactive)
  (codetracer--run-at-point "view.generated-c-source"))

(defun codetracer-view-disassembly ()
  "Show the machine code of the stop in the Low Level Code pane."
  (interactive)
  (codetracer--run-at-point "view.disassembly"))

(defun codetracer--at-click (click command)
  "A command running COMMAND with point where CLICK was."
  (lambda ()
    (interactive)
    (let ((posn (event-start click)))
      (when (and (windowp (posn-window posn)) (integer-or-marker-p (posn-point posn)))
        (posn-set-point posn)))
    (call-interactively command)))

(defun codetracer-context-menu (menu click)
  "Add CodeTracer's Nim tracing to MENU, the context menu CLICK opened.
In a Nim buffer while a CodeTracer session is open, a \"CodeTracer\"
submenu traces the macro, the static block or the constant at the click,
evaluates the file with `nim e', or shows the click's line's generated C
or the stop's disassembly; the click's position becomes point
before the item runs.  Anywhere else MENU is left as it is.  This is an
entry of `context-menu-functions', added while the pane server runs."
  (let* ((window (posn-window (event-start click)))
         (buffer (if (windowp window) (window-buffer window) (current-buffer))))
    (when (and (codetracer--live-p) (codetracer--nim-session)
               (codetracer--nim-buffer-p buffer))
      (let ((submenu (make-sparse-keymap "CodeTracer")))
        (dolist (item (reverse (append codetracer--nim-trace-items
                                       codetracer--generated-code-items)))
          (define-key submenu (vector (cdr item))
                      `(menu-item ,(car item) ,(codetracer--at-click click (cdr item)))))
        (define-key-after menu [codetracer-separator] menu-bar-separator)
        (define-key-after menu [codetracer] `(menu-item "CodeTracer" ,submenu)))))
  menu)

;;;; Hooks

(defun codetracer--install-hooks ()
  "Watch the windows and tabs the sessions live in."
  (add-hook 'window-size-change-functions #'codetracer--schedule-window-change)
  (add-hook 'window-buffer-change-functions #'codetracer--schedule-window-change)
  (add-hook 'window-scroll-functions #'codetracer--on-window-scroll)
  (add-hook 'tab-bar-tab-post-select-functions #'codetracer--on-tab-selected)
  (add-hook 'tab-bar-tab-post-open-functions #'codetracer--on-tab-selected)
  (add-hook 'post-command-hook #'codetracer--report-cursor)
  (add-hook 'find-file-hook #'codetracer--render-current-tests)
  (add-hook 'context-menu-functions #'codetracer-context-menu))

(defun codetracer--remove-hooks ()
  "Stop watching windows and tabs."
  (remove-hook 'window-size-change-functions #'codetracer--schedule-window-change)
  (remove-hook 'window-buffer-change-functions #'codetracer--schedule-window-change)
  (remove-hook 'window-scroll-functions #'codetracer--on-window-scroll)
  (remove-hook 'tab-bar-tab-post-select-functions #'codetracer--on-tab-selected)
  (remove-hook 'tab-bar-tab-post-open-functions #'codetracer--on-tab-selected)
  (remove-hook 'post-command-hook #'codetracer--report-cursor)
  (remove-hook 'find-file-hook #'codetracer--render-current-tests)
  (remove-hook 'context-menu-functions #'codetracer-context-menu))

;;;; Commands most people bind

;; Every operation of the server's catalogue becomes a command when the server
;; starts (`codetracer--define-operation-commands').  The debugger's are also
;; defined when the package loads, so they can be bound before a session is
;; open: `codetracer-debugger-step-over' and the rest, and the short names
;; below.

(defconst codetracer--debugger-operations
  '("debugger.continue" "debugger.reverse-continue"
    "debugger.step-over" "debugger.reverse-step-over"
    "debugger.step-into" "debugger.reverse-step-into"
    "debugger.step-out" "debugger.reverse-step-out"
    "debugger.run-to-entry" "debugger.stop" "debugger.restart"
    "editor.toggle-breakpoint" "editor.toggle-tracepoint")
  "The debugger operations offered as commands before the server starts.")

(dolist (operation codetracer--debugger-operations)
  (codetracer--operation-command operation))

(defun codetracer-step-over ()
  "Step over, to the next line."
  (interactive)
  (codetracer--run "debugger.step-over"))

(defun codetracer-step-into ()
  "Step into the call on this line."
  (interactive)
  (codetracer--run "debugger.step-into"))

(defun codetracer-step-out ()
  "Step out of the current call."
  (interactive)
  (codetracer--run "debugger.step-out"))

(defun codetracer-reverse-step-over ()
  "Step back over the previous line."
  (interactive)
  (codetracer--run "debugger.reverse-step-over"))

(defun codetracer-continue ()
  "Continue to the next breakpoint."
  (interactive)
  (codetracer--run "debugger.continue"))

(defun codetracer-reverse-continue ()
  "Continue backwards to the previous breakpoint."
  (interactive)
  (codetracer--run "debugger.reverse-continue"))

(defun codetracer-reverse-step-into ()
  "Step back into the call that returned to this line."
  (interactive)
  (codetracer--run "debugger.reverse-step-into"))

(defun codetracer-reverse-step-out ()
  "Step back out, to the line that called the current function."
  (interactive)
  (codetracer--run "debugger.reverse-step-out"))

(defun codetracer-run-to-entry ()
  "Go to the recording's entry point."
  (interactive)
  (codetracer--run "debugger.run-to-entry"))

(defun codetracer-stop ()
  "Stop debugging and return to editing."
  (interactive)
  (codetracer--run "debugger.stop"))

(defun codetracer-toggle-breakpoint ()
  "Toggle a breakpoint on the line point is on in the source window."
  (interactive)
  (codetracer--report-cursor)
  (codetracer--run "editor.toggle-breakpoint"))

(defun codetracer-toggle-tracepoint ()
  "Toggle a tracepoint on the line point is on in the source window."
  (interactive)
  (codetracer--report-cursor)
  (codetracer--run "editor.toggle-tracepoint"))

(defun codetracer-toggle-mode ()
  "Switch the session between its debug and edit modes."
  (interactive)
  (codetracer--run "session.toggle-product-mode"))

(defun codetracer-show-frames ()
  "Show the frames a recording with graphics carries, in a pane of their own.
The frame viewer draws the current frame as an image when this Emacs
can display images, and as a line of text otherwise."
  (interactive)
  (let ((session (or (codetracer--current-tab-session)
                     (user-error "This tab shows no CodeTracer session"))))
    (unless (eq (plist-get (codetracer-session-graphics session) :available) t)
      (user-error "This recording carries no graphics%s"
                  (if-let ((why (plist-get (codetracer-session-graphics session) :error)))
                      (concat ": " why) "")))
    (let* ((buffer (codetracer--pane-buffer session "frameViewer"))
           (codetracer--realizing t)
           (window (display-buffer buffer '((display-buffer-in-side-window)
                                            (side . bottom) (slot . 0)
                                            (window-height . 0.4)
                                            (dedicated . t)))))
      (when window
        (codetracer--sync-pane-size window))
      window)))

(defun codetracer-dap-endpoint ()
  "The pane server's DAP endpoint, as (HOST . PORT), or nil.
A DAP client (dap-mode, dape) attached there drives the session the
panes show."
  (interactive)
  (let* ((dap (plist-get (plist-get codetracer--server-info :capabilities) :dap))
         (endpoint (and dap (cons (plist-get dap :host) (plist-get dap :port)))))
    (when (called-interactively-p 'any)
      (message "CodeTracer DAP endpoint: %s"
               (if endpoint (format "%s:%s" (car endpoint) (cdr endpoint)) "none")))
    endpoint))

(provide 'codetracer)
;;; codetracer.el ends here
