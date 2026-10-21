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

;;; Code:

(require 'cl-lib)
(require 'jsonrpc)
(require 'tab-bar)
(require 'subr-x)

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

(defcustom codetracer-request-timeout 120
  "Seconds to wait for the pane server to answer a request."
  :type 'number)

(defcustom codetracer-media '("text")
  "The media this Emacs offers the pane server for values (`initialize')."
  :type '(repeat string))

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
  id trace title mode layout tab
  (panes (make-hash-table :test #'equal))
  position
  (decorations (make-hash-table :test #'equal)))

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

(defvar-local codetracer--pane-open nil
  "In a pane buffer, non-nil once the server was told it is open.")

(defvar-local codetracer--server-map nil
  "In a pane buffer, the keymap of the server's bindings.")

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

(defun codetracer--notify (method &optional params)
  "Send the notification METHOD with PARAMS to the pane server."
  (jsonrpc-notify (codetracer--connection) method (or params '())))

(defun codetracer--start-server ()
  "Start the pane server and initialize it."
  (let* ((process-environment (append codetracer-server-environment
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
                   (:media ,(vconcat codetracer-media)
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
  (codetracer--remove-hooks))

(defun codetracer--dispatch (_conn method params)
  "Handle the server's notification METHOD with PARAMS."
  (pcase method
    ('pane/content (codetracer--on-pane-content params))
    ('pane/keymap (codetracer--on-pane-keymap params))
    ('layout/changed (codetracer--on-layout-changed params))
    ('session/position (codetracer--on-position params))
    ('source/decorations (codetracer--on-decorations params))
    (_ nil)))

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
  "Open the CodeTracer recording TRACE in a session of its own."
  (interactive (list (read-file-name "CodeTracer recording: " nil nil t)))
  (unless (codetracer--live-p)
    (codetracer--start-server))
  (let* ((result (codetracer--request :session/open
                                      `(:trace ,(expand-file-name trace))))
         (id (plist-get result :session))
         (session (codetracer--make-session
                   :id id :trace (expand-file-name trace)
                   :title (file-name-nondirectory
                           (directory-file-name (expand-file-name trace)))
                   :mode (plist-get result :mode)
                   :layout (plist-get result :layout))))
    (puthash id session codetracer--sessions)
    (when-let ((pos (gethash id codetracer--early-positions)))
      (setf (codetracer-session-position session) pos)
      (remhash id codetracer--early-positions))
    (setq codetracer--active-session id)
    (codetracer--select-tab session)
    (codetracer--realize session)
    ;; The session's first position arrived with the answer; show it now
    ;; that the session's windows exist.
    (when-let ((pos (codetracer-session-position session)))
      (codetracer--show-position session pos))
    session))

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
    (codetracer--request :session/activate
                         `(:session ,(codetracer-session-id session)))))

(defun codetracer--on-tab-selected (_previous _current)
  "Make the session whose tab the user selected the active one."
  (unless codetracer--realizing
    (when-let ((session (codetracer--current-tab-session)))
      (codetracer--activate session))))

(defun codetracer-close-session (id)
  "Close the session ID and its tab."
  (interactive (list (or (and-let* ((s (codetracer--current-tab-session)))
                           (codetracer-session-id s))
                         (user-error "This tab shows no CodeTracer session"))))
  (when-let ((session (codetracer--session id)))
    (codetracer--request :session/close `(:session ,id))
    (maphash (lambda (_pane buffer) (when (buffer-live-p buffer) (kill-buffer buffer)))
             (codetracer-session-panes session))
    (codetracer--clear-decorations session)
    (remhash id codetracer--sessions)
    (when (equal codetracer--active-session id)
      (setq codetracer--active-session nil))
    (when-let ((index (tab-bar--tab-index-by-name (codetracer-session-tab session))))
      (let ((codetracer--realizing t))
        (tab-bar-close-tab (1+ index))))))

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
`codetracer--visible-leaves' gives them, PATH the root child's path."
  (let* ((kind (codetracer--node-kind layout))
         (kids (codetracer--node-children layout))
         (total (apply #'+ (mapcar #'codetracer--node-weight kids)))
         (editor (cl-position-if #'codetracer--holds-editor-p kids))
         (i -1))
    (if (not (member kind '("row" "column")))
        ;; A layout that is one pane or one stack: a side of its own.
        (list (list 'right 0.5 (codetracer--visible-leaves layout nil 1.0) nil))
      (cl-loop for kid in kids
               do (cl-incf i)
               unless (eql i editor)
               collect (list (if (equal kind "row")
                                 (if (and editor (< i editor)) 'left 'right)
                               (if (and editor (< i editor)) 'top 'bottom))
                             (if (> total 0) (/ (codetracer--node-weight kid) total) 0.25)
                             (codetracer--visible-leaves kid (list i) 1.0)
                             (list i))))))

(defun codetracer--pane-buffer (session pane)
  "SESSION's buffer for PANE, created when it does not exist."
  (let ((buffer (gethash pane (codetracer-session-panes session))))
    (unless (buffer-live-p buffer)
      (setq buffer (get-buffer-create
                    (format "*codetracer %s: %s*" (codetracer-session-id session) pane)))
      (with-current-buffer buffer
        (codetracer-pane-mode)
        (setq codetracer--pane pane
              codetracer--pane-session (codetracer-session-id session)))
      (puthash pane buffer (codetracer-session-panes session)))
    buffer))

(defun codetracer--pane-windows (&optional frame)
  "The windows of FRAME showing a CodeTracer pane."
  (cl-remove-if-not (lambda (w) (buffer-local-value 'codetracer--pane (window-buffer w)))
                    (window-list frame 'nomini)))

(defun codetracer--side-axis-size (window side)
  "WINDOW's size along the line its SIDE's slots form, in cells."
  (if (memq side '(left right)) (window-total-height window) (window-total-width window)))

(defun codetracer--realize (session)
  "Show SESSION's layout in the selected frame, in side windows."
  (let ((codetracer--realizing t)
        (sides (codetracer--sides (codetracer-session-layout session)))
        (shown nil))
    ;; Our previous windows go; the user's source windows stay.
    (dolist (w (codetracer--pane-windows))
      (when (window-live-p w)
        (ignore-errors (delete-window w))))
    (dolist (side sides)
      (pcase-let ((`(,where ,size ,leaves ,_path) side)
                  (slot -1))
        (dolist (leaf leaves)
          (cl-incf slot)
          (let* ((pane (nth 0 leaf))
                 (buffer (codetracer--pane-buffer session pane))
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
        (codetracer--apply-shares where leaves)))
    ;; Panes the server keeps open that this layout does not show.
    (maphash (lambda (pane buffer)
               (when (and (buffer-live-p buffer)
                          (buffer-local-value 'codetracer--pane-open buffer)
                          (not (get-buffer-window buffer)))
                 (with-current-buffer buffer (setq codetracer--pane-open nil
                                                   codetracer--pane-size nil))
                 (codetracer--request :pane/close
                                      `(:session ,(codetracer-session-id session)
                                        :pane ,pane))))
             (codetracer-session-panes session))
    (dolist (entry shown)
      (codetracer--sync-pane-size (car entry) 'open))
    shown))

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
          (codetracer-session-layout session) (plist-get params :layout))
    (when (eq (codetracer--current-tab-session) session)
      (codetracer--realize session))))

(defun codetracer--report-layout (session)
  "Report the user's sizes of SESSION's windows as the mode's layout weights."
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
    (let ((result (codetracer--request
                   :layout/edited
                   `(:session ,(codetracer-session-id session)
                     :mode ,(codetracer-session-mode session)
                     :sizes ,(apply #'append (mapcar (lambda (c) (list (car c) (cdr c)))
                                                     sizes))
                     :weights ,(vconcat weights)
                     :closed []))))
      (when-let ((layout (plist-get result :layout)))
        (setf (codetracer-session-layout session) layout)))))

(defun codetracer--report-closed (session pane)
  "Report that the user closed SESSION's PANE."
  (let ((result (codetracer--request
                 :layout/edited
                 `(:session ,(codetracer-session-id session)
                   :mode ,(codetracer-session-mode session)
                   :closed ,(vector pane)))))
    (when-let ((layout (plist-get result :layout)))
      (setf (codetracer-session-layout session) layout))
    (codetracer--request :pane/close `(:session ,(codetracer-session-id session)
                                       :pane ,pane))))

;;;; Pane sizes

(defun codetracer--sync-pane-size (window &optional open)
  "Tell the server the size of WINDOW's pane, if it changed.
With OPEN, the pane is opened rather than resized."
  (let ((buffer (window-buffer window)))
    (with-current-buffer buffer
      (when codetracer--pane
        (let ((size (cons (max 1 (window-body-width window))
                          (max 1 (window-body-height window)))))
          (when (or (and open (not codetracer--pane-open))
                    (not (equal size codetracer--pane-size)))
            (let ((method (if codetracer--pane-open :pane/resize :pane/open)))
              (setq codetracer--pane-size size
                    codetracer--pane-open t)
              (codetracer--request method
                                   `(:session ,codetracer--pane-session
                                     :pane ,codetracer--pane
                                     :width ,(car size) :height ,(cdr size))))))))))

(defun codetracer--schedule-window-change (frame)
  "Report what happened to FRAME's windows once redisplay is done."
  (unless (or codetracer--realizing codetracer--window-change-timer)
    (setq codetracer--window-change-timer
          (run-at-time 0 nil (lambda ()
                               (setq codetracer--window-change-timer nil)
                               (when (frame-live-p frame)
                                 (codetracer--on-window-buffer-change frame)
                                 (codetracer--on-window-size-change frame)))))))

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
                   (with-current-buffer buffer
                     (setq codetracer--pane-open nil codetracer--pane-size nil))
                   (codetracer--report-closed session pane)))
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
        ;; Lines past the height the server drew at are gone.
        (goto-char (point-min))
        (when (zerop (forward-line (max 1 height)))
          (delete-region (1- (point)) (point-max)))
        (goto-char (point-min))
        (forward-line (1- line))
        (move-to-column column)))))

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
  "Run OPERATION on SESSION (the active one when nil).
ARGS are a hotspot's arguments; PANE is focused first."
  (let ((result (codetracer--request
                 :operation/run
                 `(,@(when session `(:session ,session))
                   :operation ,operation
                   ,@(when pane `(:pane ,pane))
                   ,@(when args `(:args ,args))))))
    (when (and (called-interactively-p 'any) (plist-get result :detail)
               (not (string-empty-p (plist-get result :detail))))
      (message "%s" (plist-get result :detail)))
    result))

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
          (let ((result (codetracer--run operation
                                         :pane codetracer--pane
                                         :session codetracer--pane-session)))
            (when-let ((detail (plist-get result :detail)))
              (unless (string-empty-p detail) (message "%s" detail)))))
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
  "Install the bindings of PARAMS, a `pane/keymap' notification."
  (when-let* ((session (codetracer--session (plist-get params :session)))
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
  (let ((file (plist-get pos :file)))
    (when (and (stringp file) (file-exists-p file))
      (let* ((buffer (find-file-noselect file))
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
        (codetracer--report-source-viewport session window)))))

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
  "Tell the server the lines visible in SESSION's source WINDOW."
  (let ((file (buffer-file-name (window-buffer window))))
    (when file
      (with-current-buffer (window-buffer window)
        (let ((first (line-number-at-pos (window-start window)))
              (last (line-number-at-pos (or (window-end window t) (point-max)))))
          (codetracer--request :source/viewport
                               `(:session ,(codetracer-session-id session)
                                 :file ,file :firstLine ,first
                                 :lastLine ,(max first last))))))))

(defun codetracer--on-window-scroll (window _start)
  "When the user scrolls a source WINDOW, report its visible lines."
  (when (and (codetracer--live-p) (not codetracer--realizing)
             (buffer-file-name (window-buffer window)))
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

;;;; Hooks

(defun codetracer--install-hooks ()
  "Watch the windows and tabs the sessions live in."
  (add-hook 'window-size-change-functions #'codetracer--schedule-window-change)
  (add-hook 'window-buffer-change-functions #'codetracer--schedule-window-change)
  (add-hook 'window-scroll-functions #'codetracer--on-window-scroll)
  (add-hook 'tab-bar-tab-post-select-functions #'codetracer--on-tab-selected))

(defun codetracer--remove-hooks ()
  "Stop watching windows and tabs."
  (remove-hook 'window-size-change-functions #'codetracer--schedule-window-change)
  (remove-hook 'window-buffer-change-functions #'codetracer--schedule-window-change)
  (remove-hook 'window-scroll-functions #'codetracer--on-window-scroll)
  (remove-hook 'tab-bar-tab-post-select-functions #'codetracer--on-tab-selected))

;;;; Commands most people bind

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

(defun codetracer-toggle-mode ()
  "Switch the session between its debug and edit modes."
  (interactive)
  (codetracer--run "session.toggle-product-mode"))

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
