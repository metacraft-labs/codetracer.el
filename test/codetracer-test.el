;;; codetracer-test.el --- Tests for codetracer.el  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Metacraft Labs
;; SPDX-License-Identifier: Apache-2.0

;;; Commentary:

;; Two kinds of tests.
;;
;; The unit tests (tag `unit') exercise the translations the package makes
;; on its own: key spellings, byte offsets, styles, a pane row's text
;; properties, and the projection of a layout tree onto side windows and
;; back.  They need nothing but Emacs.
;;
;; The scenario tests (tag `server') drive a real pane server over a real
;; recording, in batch Emacs's own frame, with no stand-in for either: the
;; package starts `codetracer-tui --pane-server' and speaks to it over
;; stdio, as it does for a user.  They need two environment variables:
;;
;;   CODETRACER_TUI  the `codetracer-tui' binary
;;   CODETRACER_TEST_TRACE   a recording folder
;;
;; plus whatever the server needs to open the recording (it finds
;; `replay-server' itself, or through REPLAY_SERVER_BIN).  When either
;; variable is missing the scenario tests FAIL rather than skip: a suite that
;; skips its subject passes with nothing tested.  `just test' runs only the
;; unit tests; `just test-server' runs the scenarios.
;;
;; Batch Emacs does not redisplay, so `window-size-change-functions' never
;; run on their own.  Where a scenario resizes a window, it calls the
;; handler those hooks schedule (`codetracer--on-window-size-change')
;; directly, which is what the hook would do after the next redisplay.

;;; Code:

(require 'ert)
(require 'codetracer)

(defvar desktop-path)
(defvar desktop-restore-frames)
(defvar desktop-load-locked-desktop)
(defvar desktop-restore-eager)

;;;; Unit tests

(ert-deftest codetracer-test-emacs-keys ()
  :tags '(unit)
  (should (equal (codetracer--emacs-key "n") "n"))
  (should (equal (codetracer--emacs-key "Ctrl+F5") "C-<f5>"))
  (should (equal (codetracer--emacs-key "Alt+Left") "M-<left>"))
  (should (equal (codetracer--emacs-key "Enter") "RET"))
  (should (equal (codetracer--emacs-key "Ctrl+Enter") "C-<return>"))
  (should (equal (codetracer--emacs-key "Shift+Tab") "S-<tab>"))
  (should (equal (codetracer--emacs-key "PageDown") "<next>"))
  (should (equal (codetracer--emacs-key "Ctrl+Shift+F10") "C-S-<f10>"))
  (should-not (codetracer--emacs-key "Hyper+x")))

(ert-deftest codetracer-test-codetracer-keys-round-trip ()
  :tags '(unit)
  (dolist (key '("n" "Ctrl+F5" "Alt+Left" "Enter" "PageDown" "Ctrl+x"))
    (let ((events (key-parse (codetracer--emacs-key key))))
      (should (equal (codetracer--codetracer-key (aref events 0)) key)))))

(ert-deftest codetracer-test-byte-offsets ()
  :tags '(unit)
  (let ((at (codetracer--byte-offsets "▾ ab")))
    ;; "▾" is three bytes.
    (should (= (funcall at 0) 0))
    (should (= (funcall at 3) 1))
    (should (= (funcall at 4) 2))
    (should (= (funcall at 6) 4)))
  (should (eq (codetracer--byte-offsets "plain") #'identity)))

(ert-deftest codetracer-test-byte-column ()
  "The cursor's column is reported in UTF-8 bytes, as the protocol counts."
  :tags '(unit)
  (with-temp-buffer
    ;; A tab (one byte, eight display columns) and "▾" (three bytes, one
    ;; display column) before "x".
    (insert "\t▾x")
    (goto-char (point-min))
    (search-forward "x")
    (backward-char)
    (should (= (codetracer--byte-column) 5))
    (should (/= (codetracer--byte-column) (1+ (current-column))))
    (goto-char (line-beginning-position))
    (should (= (codetracer--byte-column) 1))))

(ert-deftest codetracer-test-style-faces ()
  :tags '(unit)
  (should (eq (codetracer--style-face "ct.value-modified") 'codetracer-value-modified))
  (should (eq (codetracer--style-face "ct.value-number") 'codetracer-value))
  (should (eq (codetracer--style-face "ct.event-output") 'codetracer-event))
  (should-not (codetracer--style-face "ct.border-pane"))
  (should-not (codetracer--style-face "not-a-style")))

(ert-deftest codetracer-test-render-row ()
  :tags '(unit)
  (let* ((row '(:index 0 :text "▾ main() => 0"
                       :spans [(:start 0 :end 3 :style "ct.chrome-muted")
                               (:start 4 :end 8 :style "ct.chrome-text" :bold t)
                               (:start 13 :end 14 :style "ct.call-return"
                                       :surface "ct.surface-active-row")]
                       :hotspots [(:start 0 :end 3 :operation "calltrace.toggle-call"
                                          :args (:index 0))]))
         (text (codetracer--render-row row)))
    (should (equal text "▾ main() => 0"))
    (should (memq 'codetracer-chrome-muted (ensure-list (get-text-property 0 'face text))))
    (let ((face (ensure-list (get-text-property 2 'face text))))
      (should (memq 'codetracer-chrome face))
      (should (memq 'bold face)))
    (let ((face (ensure-list (get-text-property 11 'face text))))
      (should (memq 'codetracer-call-return face))
      (should (memq 'codetracer-active-row face)))
    (should (equal (get-text-property 0 'codetracer-hotspot text)
                   '("calltrace.toggle-call" :index 0)))
    (should-not (get-text-property 1 'codetracer-hotspot text))
    (should (eq (get-text-property 0 'keymap text) codetracer-hotspot-map))))

(defconst codetracer-test--layout
  '(:kind "row"
          :children [(:kind "stack" :activeIndex 0 :weight 28.0
                            :children [(:kind "pane" :pane "fileTree") (:kind "pane" :pane "vcs")])
                     (:kind "pane" :pane "editor" :weight 85.0)
                     (:kind "column" :weight 87.0
                            :children [(:kind "row" :weight 29.0
                                              :children [(:kind "stack" :activeIndex 0 :weight 43.0
                                                                :children [(:kind "pane" :pane "state")])
                                                         (:kind "stack" :activeIndex 0 :weight 44.0
                                                                :children [(:kind "pane" :pane "calltrace")])])
                                       (:kind "stack" :activeIndex 0 :weight 29.0
                                              :children [(:kind "pane" :pane "eventLog")
                                                         (:kind "pane" :pane "terminalOutput")])])])
  "The terminal's debug layout, as the server sends it.")

(defmacro codetracer-test--with-panes (&rest body)
  "Run BODY with the server declaring the usual panes servable."
  `(let ((codetracer--server-info
          '(:capabilities (:panes ["calltrace" "state" "eventLog" "fileTree" "vcs"
                                   "terminalOutput"]))))
     ,@body))

(ert-deftest codetracer-test-sides ()
  :tags '(unit)
  (codetracer-test--with-panes
   (let ((sides (codetracer--sides codetracer-test--layout)))
     (should (equal (mapcar #'car sides) '(left right)))
     ;; The left side: the stack's active pane only.
     (should (equal (mapcar #'car (nth 2 (nth 0 sides))) '("fileTree")))
     (should (equal (nth 3 (car (nth 2 (nth 0 sides)))) '(0)))
     ;; The right side: its panes in tree order, with their region paths.
     (let ((leaves (nth 2 (nth 1 sides))))
       (should (equal (mapcar #'car leaves) '("state" "calltrace" "eventLog")))
       (should (equal (mapcar (lambda (l) (nth 3 l)) leaves)
                      '((2 0 0) (2 0 1) (2 1))))
       ;; Shares: the product of the weights' fractions down the path.
       (should (< (abs (- (apply #'+ (mapcar (lambda (l) (nth 2 l)) leaves)) 1.0)) 1e-9))
       (should (< (abs (- (nth 2 (nth 2 leaves)) (/ 29.0 58.0))) 1e-9)))
     (should (< (abs (- (nth 1 (nth 0 sides)) (/ 28.0 200.0))) 1e-9)))))

(ert-deftest codetracer-test-sides-beside-the-editor ()
  "A pane split off the editor, inside the editor's node, is a side too."
  :tags '(unit)
  (codetracer-test--with-panes
   ;; row[fileTree 1, column[row[editor 3, state 1] 3, calltrace 1] 3]: the
   ;; layout after `split(editor, state, row, after)' and one below.
   (let ((sides (codetracer--sides
                 '(:kind "row"
                   :children [(:kind "pane" :pane "fileTree" :weight 1)
                              (:kind "column" :weight 3
                               :children [(:kind "row" :weight 3
                                           :children [(:kind "pane" :pane "editor" :weight 3)
                                                      (:kind "pane" :pane "state" :weight 1)])
                                          (:kind "pane" :pane "calltrace" :weight 1)])]))))
     (should (equal (mapcar #'car sides) '(left bottom right)))
     (should (equal (mapcar (lambda (s) (mapcar #'car (nth 2 s))) sides)
                    '(("fileTree") ("calltrace") ("state"))))
     (should (equal (mapcar (lambda (s) (nth 3 s)) sides) '((0) (1 1) (1 0 1))))
     ;; Sizes are fractions of the frame across the side.
     (should (< (abs (- (nth 1 (nth 0 sides)) 0.25)) 1e-9))
     (should (< (abs (- (nth 1 (nth 1 sides)) 0.25)) 1e-9))
     (should (< (abs (- (nth 1 (nth 2 sides)) (* 0.75 0.25))) 1e-9)))))

(ert-deftest codetracer-test-sides-without-editor ()
  :tags '(unit)
  (codetracer-test--with-panes
   (let ((sides (codetracer--sides '(:kind "stack" :activeIndex 1
                                           :children [(:kind "pane" :pane "state")
                                                      (:kind "pane" :pane "calltrace")]))))
     (should (= (length sides) 1))
     (should (equal (mapcar #'car (nth 2 (car sides))) '("calltrace"))))))

(defconst codetracer-test--png
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
  "A 1x1 PNG, base64: what a `pane/content' image carries.")

(ert-deftest codetracer-test-own-files-are-not-reported ()
  :tags '(unit)
  (should (codetracer--own-file-p "/src/.#main.py"))
  (should (codetracer--own-file-p "/src/main.py~"))
  (should (codetracer--own-file-p "/src/#main.py#"))
  (should-not (codetracer--own-file-p "/src/main.py")))

(ert-deftest codetracer-test-pane-image ()
  "A frame's image is drawn under the pane's rows, and kept across partial updates."
  :tags '(unit)
  (let ((codetracer--sessions (make-hash-table))
        (session (codetracer--make-session :id 7 :trace "/t" :title "t")))
    (puthash 7 session codetracer--sessions)
    (unwind-protect
        (progn
          (codetracer--on-pane-content
           `(:session 7 :pane "frameViewer" :width 30 :height 2 :full t
                      :rows [(:index 0 :text "Frame 1 of 3" :spans [])
                             (:index 1 :text "next" :spans [])]
                      :image (:mediaType "image/png" :encoding "base64"
                                         :data ,codetracer-test--png :width 1 :height 1
                                         :frame 0 :frameCount 3)))
          (with-current-buffer (gethash "frameViewer" (codetracer-session-panes session))
            ;; An Emacs without PNG support draws the rows only; the dev
            ;; shell's Emacs has it, so there the image is checked.
            (let* ((png (image-type-available-p 'png))
                   (pos (next-single-property-change (point-min) 'display))
                   (image (and pos (get-text-property pos 'display))))
              (if (not png)
                  (should-not image)
                (should image)
                (should (eq (car image) 'image))
                (should (eq (plist-get (cdr image) :type) 'png))
                (should (string-prefix-p "\x89PNG" (plist-get (cdr image) :data)))))
            (should (equal (buffer-substring-no-properties (point-min) (line-end-position))
                           "Frame 1 of 3"))
            ;; A partial update replaces its row and keeps the image.
            (codetracer--on-pane-content
             '(:session 7 :pane "frameViewer" :width 30 :height 2 :full :json-false
                        :rows [(:index 0 :text "Frame 2 of 3" :spans [])]))
            (goto-char (point-min))
            (should (equal (buffer-substring-no-properties (point-min) (line-end-position))
                           "Frame 2 of 3"))
            (when (image-type-available-p 'png)
              (should (= (count-lines (point-min) (point-max)) 3))
              (should (next-single-property-change (point-min) 'display)))))
      (maphash (lambda (_ b) (kill-buffer b)) (codetracer-session-panes session)))))

(ert-deftest codetracer-test-media-declaration ()
  "Images are declared when this Emacs can display them, or when asked for."
  :tags '(unit)
  (let ((codetracer-media nil))
    (should (equal (codetracer--media)
                   (if (display-images-p) '("text" "image") '("text")))))
  (let ((codetracer-media '("text" "image")))
    (should (equal (codetracer--media) '("text" "image")))))

;; What the user is shown of an `operation/run' answer, for answers in the
;; protocol's shape, including the ones the real server does not give for any
;; operation on the recordings the scenarios use (an empty refusal reason).
;; Both kinds of refusal the server gives, an error answer and `ok: false'
;; with its reason, are exercised against it below.
(ert-deftest codetracer-test-operation-results-shown ()
  "A refusal or a detail in an `operation/run' answer is shown to the user."
  :tags '(unit)
  (let ((shown nil))
    (cl-flet ((shown-for (result)
                (setq shown nil)
                (let ((inhibit-message t)
                      (message-log-max nil))
                  (setq shown (codetracer--show-run-result "debugger.step-over" result)))
                shown))
      (should (equal (shown-for '(:ok :json-false :detail "no recording"))
                     "CodeTracer: debugger.step-over: no recording"))
      (should (equal (shown-for '(:ok :json-false :detail ""))
                     "CodeTracer: debugger.step-over: refused"))
      (should (equal (shown-for '(:ok t :detail "frame 2 of 5"))
                     "CodeTracer: frame 2 of 5"))
      (should-not (shown-for '(:ok t :detail "")))
      (should-not (shown-for '(:ok t))))))

(ert-deftest codetracer-test-pane-buffer-names ()
  "Pane buffers are named ct://SESSION/PANE; one with the old name is adopted."
  :tags '(unit)
  (let ((codetracer--sessions (make-hash-table))
        (session (codetracer--make-session :id 7 :trace "/t" :title "t"))
        (legacy (get-buffer-create "*codetracer 7: state*")))
    (puthash 7 session codetracer--sessions)
    (unwind-protect
        (progn
          (let ((calltrace (codetracer--pane-buffer session "calltrace")))
            (should (equal (buffer-name calltrace) "ct://7/calltrace"))
            (should (eq (codetracer--pane-buffer session "calltrace") calltrace)))
          ;; The buffer a `desktop' file saved under the old name is the pane's.
          (should (eq (codetracer--pane-buffer session "state") legacy))
          (should (equal (buffer-name legacy) "ct://7/state"))
          (should-not (get-buffer "*codetracer 7: state*"))
          (should (equal (buffer-local-value 'codetracer--pane legacy) "state"))
          ;; Both names taken: the new one is the pane's, the old one goes.
          (let ((current (get-buffer-create "ct://7/eventLog"))
                (old (get-buffer-create "*codetracer 7: eventLog*")))
            (should (eq (codetracer--pane-buffer session "eventLog") current))
            (should-not (buffer-live-p old))))
      (maphash (lambda (_ b) (when (buffer-live-p b) (kill-buffer b)))
               (codetracer-session-panes session)))))

(ert-deftest codetracer-test-stack-tabs ()
  "A stack's tabs name its children, mark the shown one, and are clickable."
  :tags '(unit)
  (let* ((stack '(:kind "stack" :activeIndex 1
                        :children [(:kind "pane" :pane "eventLog")
                                   (:kind "pane" :pane "terminalOutput")]))
         (tabs (codetracer--stack-tabs stack)))
    (should (equal (substring-no-properties tabs) " eventLog  terminalOutput "))
    (should (eq (get-text-property 1 'face tabs) 'codetracer-stack-tab))
    (should (eq (get-text-property 11 'face tabs) 'codetracer-stack-tab-active))
    (should (eql (get-text-property 1 'codetracer-stack-index tabs) 0))
    (should (eql (get-text-property 11 'codetracer-stack-index tabs) 1))
    (should (eq (lookup-key (get-text-property 1 'keymap tabs) [header-line mouse-1])
                #'codetracer-stack-tab-click))
    ;; The two faces differ: the shown tab is visibly the selected one.
    (should-not (equal (face-attribute 'codetracer-stack-tab-active :inherit)
                       (face-attribute 'codetracer-stack-tab :inherit))))
  (let ((layout (copy-tree codetracer-test--layout t))
        (session (codetracer--make-session :id 1 :mode "debug")))
    ;; A pick is applied to each layout of its mode the server sends.
    (puthash '("debug" 2 1) 1 (codetracer-session-stack-choices session))
    (codetracer--apply-stack-choices session layout "edit")
    (should (eql (plist-get (codetracer--node-at layout '(2 1)) :activeIndex) 0))
    (codetracer--apply-stack-choices session layout "debug")
    (should (eql (plist-get (codetracer--node-at layout '(2 1)) :activeIndex) 1))
    (codetracer-test--with-panes
     (should (equal (mapcar #'car (nth 2 (nth 1 (codetracer--sides layout))))
                    '("state" "calltrace" "terminalOutput"))))))

(ert-deftest codetracer-test-source-bindings ()
  "Only the debugger's function-key chords of the editor keymap are a source buffer's."
  :tags '(unit)
  (should (equal (codetracer--source-bindings
                  [(:key "F10" :operation "debugger.step-over" :layer "base:global")
                   (:key "n" :operation "debugger.step-over" :layer "base:global")
                   (:key "Ctrl+A" :operation "select-all" :layer "base:editor")
                   (:key "Shift+F11" :operation "debugger.reverse-step-into" :layer "base:global")
                   (:key "Ctrl+F5" :operation "session.toggle-product-mode" :layer "base:global")
                   (:key "F3" :operation "find.next" :layer "base:editor")
                   (:key "F9" :operation "editor.toggle-breakpoint" :layer "base:editor")
                   (:key "Ctrl+K Shift+F10" :operation "context-menu.open" :layer "base:global")
                   (:key "Alt+Shift+F10" :operation "debugger.reverse-step-over-statement")
                   (:key "F10" :operation "debugger.continue" :layer "user")
                   (:key "F12" :operation "debugger.step-out" :shadowedBy "editor")
                   (:key "Ctrl+Enter" :operation "editor.toggle-tracepoint")])
                 '(("<f10>" . "debugger.step-over")
                   ("S-<f11>" . "debugger.reverse-step-into")
                   ("<f9>" . "editor.toggle-breakpoint")
                   ("M-S-<f10>" . "debugger.reverse-step-over-statement")))))

(ert-deftest codetracer-test-source-keys-give-way-to-the-users ()
  "A source buffer's debugger key gives way to any binding but Emacs's default."
  :tags '(unit)
  (let ((codetracer--source-key-buffers nil)
        (session (codetracer--make-session
                  :id 9 :source-bindings '(("<f10>" . "debugger.step-over")
                                           ("<f5>" . "debugger.continue"))))
        (old (keymap-lookup global-map "<f5>")))
    (with-temp-buffer
      (unwind-protect
          (progn
            (codetracer--bind-source-keys session (current-buffer))
            (should codetracer-source-mode)
            ;; F10 is Emacs's `menu-bar-open' by default: the debugger's here.
            (should (eq (key-binding (kbd "<f10>")) 'codetracer-debugger-step-over))
            (should (eq (key-binding (kbd "<f5>")) 'codetracer-debugger-continue))
            ;; The user's own F5 wins, from the moment it is bound.
            (keymap-global-set "<f5>" #'ignore)
            (should (eq (key-binding (kbd "<f5>")) #'ignore))
            (should (eq (key-binding (kbd "<f10>")) 'codetracer-debugger-step-over))
            ;; And so does the major mode's.
            (use-local-map (let ((m (make-sparse-keymap))) (keymap-set m "<f10>" #'undo) m))
            (should (eq (key-binding (kbd "<f10>")) #'undo))
            (codetracer--unbind-source-keys (current-buffer))
            (should-not codetracer-source-mode)
            (should-not (assq 'codetracer-source-mode minor-mode-overriding-map-alist))
            (should-not codetracer--source-key-buffers))
        (keymap-global-set "<f5>" old)))))

(defconst codetracer-test--buttons
  [(:id "next" :label "Next" :tooltip "Next (F10)" :operation "debugger.step-over"
        :enabled t :glyphs (:nerd "N" :unicode "↷" :text "Next"))
   (:id "reverse-next" :label "Reverse next" :tooltip "Reverse next (Shift+F10)"
        :operation "debugger.reverse-step-over" :enabled :json-false
        :glyphs (:nerd "R" :unicode "↶" :text ""))]
  "Two `controls/state' buttons, one enabled, in the server's shape.")

(ert-deftest codetracer-test-controls-items ()
  "The current tab's controls are tab-bar items; a disabled one is dimmed and inert."
  :tags '(unit)
  (let* ((codetracer--sessions (make-hash-table))
         (codetracer--tab-bar-format-taken nil)
         (tab-bar-format (eval (car (get 'tab-bar-format 'standard-value)) t))
         (session (codetracer--make-session
                   :id 3 :tab (alist-get 'name (tab-bar--current-tab)))))
    (puthash 3 session codetracer--sessions)
    (codetracer--on-controls-state `(:session 3 :buttons ,codetracer-test--buttons))
    (let ((items (codetracer-tab-bar-controls)))
      (should (= (length items) 2))
      (pcase-let ((`(,key menu-item ,caption ,binding :help ,help) (nth 0 items)))
        (should (eq key 'codetracer-control-next))
        (should (equal (substring-no-properties caption) " ↷ "))
        (should (eq (get-text-property 1 'face caption) 'codetracer-control))
        (should (commandp binding))
        (should (equal help "Next (F10)")))
      (pcase-let ((`(,_ menu-item ,caption ,binding . ,_) (nth 1 items)))
        (should (eq (get-text-property 1 'face caption) 'codetracer-control-disabled))
        (should (eq binding #'ignore))))
    ;; The glyph set is the user's choice; an empty glyph is the label.
    (let ((codetracer-controls-glyphs 'text))
      (should (equal (mapcar (lambda (i) (substring-no-properties (nth 2 i)))
                             (codetracer-tab-bar-controls))
                     '(" Next " " Reverse next "))))
    ;; Outside a session's tab, nothing.
    (setf (codetracer-session-tab session) "not this tab")
    (should-not (codetracer-tab-bar-controls))))

(ert-deftest codetracer-test-tab-bar-format-taken-and-given-back ()
  "The default `tab-bar-format' gets the controls while sessions are open; a
format of the user's own is left alone."
  :tags '(unit)
  (let* ((default (eval (car (get 'tab-bar-format 'standard-value)) t))
         (codetracer--sessions (make-hash-table))
         (codetracer--tab-bar-format-taken nil)
         (codetracer--tab-bar-format-offered t)
         (codetracer-controls 'tab-bar)
         (tab-bar-format (copy-sequence default)))
    (puthash 1 (codetracer--make-session :id 1) codetracer--sessions)
    (codetracer--sync-controls)
    (should (equal tab-bar-format (append default '(tab-bar-format-align-right
                                                    codetracer-tab-bar-controls))))
    ;; Once only.
    (codetracer--sync-controls)
    (should (= (cl-count 'codetracer-tab-bar-controls tab-bar-format) 1))
    (clrhash codetracer--sessions)
    (codetracer--sync-controls)
    (should (equal tab-bar-format default))
    ;; The user's own format.
    (let ((mine '(tab-bar-format-tabs tab-bar-format-global)))
      (setq tab-bar-format mine)
      (puthash 1 (codetracer--make-session :id 1) codetracer--sessions)
      (codetracer--sync-controls)
      (should (eq tab-bar-format mine))
      (clrhash codetracer--sessions)
      (codetracer--sync-controls)
      (should (eq tab-bar-format mine)))
    ;; Turned off: nothing is taken.
    (let ((codetracer-controls nil))
      (setq tab-bar-format (copy-sequence default))
      (puthash 1 (codetracer--make-session :id 1) codetracer--sessions)
      (codetracer--sync-controls)
      (should (equal tab-bar-format default)))))

;; With Emacs 30's jsonrpc the notifications that follow `session/open' are
;; dispatched after its answer (measured: none of a session's arrive before it
;; is registered), but a jsonrpc that dispatches from the process filter runs
;; them while `codetracer-open' still waits.  The buffer is exercised here.
(ert-deftest codetracer-test-early-notifications-applied ()
  "Controls and keymaps that arrive before their session is registered are kept."
  :tags '(unit)
  (let ((codetracer--sessions (make-hash-table))
        (codetracer--early-notifications (make-hash-table))
        (codetracer--early-positions (make-hash-table))
        (codetracer--tab-bar-format-taken nil)
        (codetracer--source-key-buffers nil)
        (codetracer-controls nil))
    (codetracer--dispatch nil 'controls/state `(:session 4 :buttons ,codetracer-test--buttons))
    (codetracer--dispatch nil 'pane/keymap
                          '(:session 4 :pane "editor"
                                     :bindings [(:key "F10" :operation "debugger.step-over")]))
    (should (= (length (gethash 4 codetracer--early-notifications)) 2))
    (let ((session (codetracer--new-session "/rec/calc" '(:session 4 :mode "debug"))))
      (should (equal (codetracer-session-title session) "calc"))
      (should (= (length (codetracer-session-controls session)) 2))
      (should (equal (codetracer-session-source-bindings session)
                     '(("<f10>" . "debugger.step-over"))))
      (should-not (gethash 4 codetracer--early-notifications)))))

(defmacro codetracer-test--with-test-controls (controls &rest body)
  "Run BODY in a buffer visiting the crate's main.nr, CONTROLS its tests.
CONTROLS are `source/tests' controls of session 7, registered alone."
  (declare (indent 1))
  `(let* ((codetracer--sessions (make-hash-table))
          (file (make-temp-file "codetracer-el-main" nil ".nr" codetracer-test--main-nr))
          (session (codetracer--make-session :id 7 :title "calc")))
     (puthash 7 session codetracer--sessions)
     (unwind-protect
         (with-current-buffer (find-file-noselect file)
           (codetracer--on-source-tests `(:session 7 :file ,file :controls ,(vconcat ,controls)))
           ,@body)
       (when-let* ((b (find-buffer-visiting file))) (kill-buffer b))
       (delete-file file))))

(defun codetracer-test--before-strings ()
  "The current buffer's test overlays' `before-string's, by line."
  (mapcar (lambda (m) (cons (car m) (overlay-get (cddr m) 'before-string)))
          (codetracer-test--test-overlays (current-buffer))))

(ert-deftest codetracer-test-test-controls-drawn-by-placement ()
  "A test's control is a fringe mark showing its verdict, a button line, or both."
  :tags '(unit)
  (let ((controls '((:line 5 :testId "t1" :name "test_passes" :state "passed"
                           :open (:enabled t))
                    (:line 10 :testId "t2" :name "test_fails" :state "failed"
                           :open (:enabled :json-false :title "a build is running")))))
    (let ((codetracer-tests-placement 'gutter))
      (codetracer-test--with-test-controls controls
        (let ((marks (codetracer-test--test-overlays (current-buffer))))
          (should (equal (mapcar #'car marks) '(5 10)))
          (should (equal (mapcar #'cadr marks)
                         '(codetracer-test-passed codetracer-test-failed)))
          (should (eq (overlay-get (cddr (car marks)) 'keymap) codetracer-test-line-map)))
        (should-not (cl-some (lambda (b) (string-search "Record" (cdr b)))
                             (codetracer-test--before-strings)))))
    (let ((codetracer-tests-placement 'above-line))
      (codetracer-test--with-test-controls controls
        (let* ((strings (codetracer-test--before-strings))
               (button (cdr (car strings))))
          (should (equal (mapcar #'car strings) '(5 10)))
          (should (string-prefix-p "▶ Record test_passes\n" button))
          ;; No fringe mark, and no fringe click to take.
          (should-not (cl-find-if (lambda (m) (cadr m))
                                  (codetracer-test--test-overlays (current-buffer))))
          (should-not (overlay-get (cddr (car (codetracer-test--test-overlays (current-buffer))))
                                   'keymap))
          ;; A button: mouse-1 follows it, RET and mouse-2 press it.
          (should (get-text-property 0 'button button))
          (should (eq (get-text-property 0 'follow-link button) t))
          ;; The disabled test's button says why instead of recording.
          (let ((disabled (cdr (nth 1 strings))))
            (should (equal (funcall (get-text-property 0 'action disabled) nil)
                           "CodeTracer: a build is running"))))))
    (let ((codetracer-tests-placement 'both))
      (codetracer-test--with-test-controls controls
        (should (equal (mapcar #'cadr (codetracer-test--test-overlays (current-buffer)))
                       '(codetracer-test-passed codetracer-test-failed)))
        (should (string-prefix-p "▶ Record test_fails\n"
                                 (cdr (nth 1 (codetracer-test--before-strings)))))))
    ;; A later `source/tests' replaces the drawing; one with none clears it.
    (codetracer-test--with-test-controls controls
      (codetracer--on-source-tests `(:session 7 :file ,buffer-file-name
                                              :controls [(:line 10 :testId "t2" :name "test_fails"
                                                                :state "" :open (:enabled t))]))
      (should (equal (mapcar (lambda (m) (list (car m) (cadr m)))
                             (codetracer-test--test-overlays (current-buffer)))
                     '((10 codetracer-test-play))))
      (codetracer--on-source-tests `(:session 7 :file ,buffer-file-name :controls []))
      (should-not codetracer--test-overlays))))

(ert-deftest codetracer-test-test-at-point-refusals ()
  "Above every test there is none; a disabled test's control says why."
  :tags '(unit)
  (codetracer-test--with-test-controls
      '((:line 5 :testId "t1" :name "test_passes" :state "" :open (:enabled t))
        (:line 10 :testId "t2" :name "test_fails" :state ""
               :open (:enabled :json-false :title "the test is being recorded")))
    (goto-char (point-min))
    (should-error (codetracer-test-at-point) :type 'user-error)
    (forward-line 10)                   ; line 11, inside test_fails
    (should (equal (codetracer-test-at-point) "CodeTracer: the test is being recorded"))))

(ert-deftest codetracer-test-server-directory ()
  "The pane server starts in the current buffer's directory, the Edit-mode project."
  :tags '(unit)
  (let ((default-directory temporary-file-directory))
    (should (equal (codetracer--server-directory)
                   (expand-file-name temporary-file-directory))))
  (let ((default-directory "/ssh:example.invalid:/srv/"))
    (should (equal (codetracer--server-directory) (expand-file-name "~/")))))

;;;; Scenario tests against a real pane server

(defun codetracer-test--env (name)
  "The environment variable NAME, or a failure naming it."
  (let ((value (getenv name)))
    (unless (and value (not (string-empty-p value)))
      (ert-fail (format "%s is not set: the scenario tests need a real pane server and recording"
                        name)))
    value))

(defun codetracer-test--settle ()
  "Wait until the server has sent everything the last request caused.
The server answers a request before the notifications it causes, and
handles requests in order, so the answer to a later request comes after
all of them."
  (codetracer--request :session/list)
  ;; Timers the package scheduled (window-change reports) run now.
  (accept-process-output nil 0.05))

(defun codetracer-test--shown-panes ()
  "The panes the selected frame shows, sorted."
  (sort (mapcar (lambda (w) (buffer-local-value 'codetracer--pane (window-buffer w)))
                (codetracer--pane-windows))
        #'string<))

(defun codetracer-test--expected-panes (session)
  "The panes SESSION's current layout shows, sorted."
  (sort (cl-loop for side in (codetracer--sides (codetracer-session-layout session))
                 append (mapcar #'car (nth 2 side)))
        #'string<))

(defun codetracer-test--pane-window (session pane)
  "The window showing SESSION's PANE, or nil."
  (when-let ((buffer (gethash pane (codetracer-session-panes session))))
    (get-buffer-window buffer)))

(defun codetracer-test--reset-windows ()
  "One tab, one ordinary window, whatever the last test left.
`desktop' may have restored a window configuration in which no
ordinary window is left to keep, so window parameters are ignored."
  (ignore-errors (tab-bar-close-other-tabs))
  (let ((ignore-window-parameters t))
    (delete-other-windows
     (or (cl-find-if-not (lambda (w) (window-parameter w 'window-side))
                         (window-list nil 'nomini))
         (selected-window))))
  (set-window-parameter (selected-window) 'window-side nil)
  (set-window-parameter (selected-window) 'window-slot nil)
  (set-window-dedicated-p (selected-window) nil))

(defmacro codetracer-test--with-server (&rest body)
  "Run BODY with a pane server started and torn down around it."
  (declare (indent 0))
  `(let ((codetracer-server-program (codetracer-test--env "CODETRACER_TUI"))
         (trace (codetracer-test--env "CODETRACER_TEST_TRACE"))
         (codetracer-pane-user-map (make-sparse-keymap))
         (codetracer-pane-user-maps nil))
     (ignore trace)
     (set-frame-size (selected-frame) 200 60)
     (codetracer-test--reset-windows)
     (unwind-protect
         (progn ,@body)
       (ignore-errors (codetracer-quit))
       (let ((deadline (+ (float-time) 10)))
         (while (and (codetracer--live-p) (< (float-time) deadline))
           (accept-process-output nil 0.1)))
       (codetracer-test--reset-windows))))

(ert-deftest codetracer-test-layouts-per-mode ()
  "Each mode's layout is realized in side windows; a mode switch re-arranges them."
  :tags '(server)
  (codetracer-test--with-server
   (let ((session (codetracer-open trace)))
     (codetracer-test--settle)
     (should (equal (codetracer-session-mode session) "debug"))
     (let ((debug-panes (codetracer-test--shown-panes)))
       (should (equal debug-panes (codetracer-test--expected-panes session)))
       (should (member "calltrace" debug-panes))
       ;; Every shown pane was opened at its window's size and drawn there.
       (dolist (w (codetracer--pane-windows))
         (with-current-buffer (window-buffer w)
           (should codetracer--pane-open)
           (should (equal codetracer--pane-size
                          (cons (window-body-width w) (window-body-height w))))))
       (with-current-buffer (gethash "calltrace" (codetracer-session-panes session))
         (should (> (buffer-size) 0)))
       ;; The user's source window is kept.
       (should (cl-find-if-not (lambda (w) (window-parameter w 'window-side))
                               (window-list nil 'nomini)))
       (codetracer-toggle-mode)
       (codetracer-test--settle)
       (should (equal (codetracer-session-mode session) "edit"))
       (let ((edit-panes (codetracer-test--shown-panes)))
         (should (equal edit-panes (codetracer-test--expected-panes session)))
         (should-not (equal edit-panes debug-panes)))
       (codetracer-toggle-mode)
       (codetracer-test--settle)
       (should (equal (codetracer-session-mode session) "debug"))
       (should (equal (codetracer-test--shown-panes) debug-panes))))))

(ert-deftest codetracer-test-step-updates-position-and-panes ()
  "A step moves the source window and the execution mark, and redraws the panes."
  :tags '(server)
  (codetracer-test--with-server
   (let* ((session (codetracer-open trace))
          (_ (codetracer-test--settle))
          (before (codetracer-session-position session))
          (state (gethash "state" (codetracer-session-panes session)))
          (state-before (with-current-buffer state (buffer-string))))
     (should before)
     (let ((source (codetracer--source-window session)))
       (should (equal (buffer-file-name (window-buffer source)) (plist-get before :file)))
       (with-current-buffer (window-buffer source)
         (should (= (line-number-at-pos (window-point source)) (plist-get before :line)))))
     (codetracer-step-over)
     (codetracer-test--settle)
     (let ((after (codetracer-session-position session)))
       (should (> (plist-get after :tick) (plist-get before :tick)))
       (let ((source (codetracer--source-window session)))
         (with-current-buffer (window-buffer source)
           (should (= (line-number-at-pos (window-point source)) (plist-get after :line)))
           ;; The execution mark is on the new line, and only there.
           (let ((marks (cl-remove-if-not
                         (lambda (ov) (eq (overlay-get ov 'face) 'codetracer-execution-line))
                         (overlays-in (point-min) (point-max)))))
             (should (= (length marks) 1))
             (should (= (line-number-at-pos (overlay-start (car marks)))
                        (plist-get after :line)))))))
     (should-not (equal (with-current-buffer state (buffer-string)) state-before)))))

(ert-deftest codetracer-test-resize-changes-request-window ()
  "A pane window's new size reaches the server, which redraws at that size."
  :tags '(server)
  (codetracer-test--with-server
   (let* ((session (codetracer-open trace))
          (_ (codetracer-test--settle))
          (window (codetracer-test--pane-window session "calltrace"))
          (height (window-body-height window)))
     (should (> height 6))
     (window-resize window -4)
     (should (= (window-body-height window) (- height 4)))
     (codetracer--on-window-size-change (selected-frame))
     (codetracer-test--settle)
     (with-current-buffer (window-buffer window)
       (should (equal codetracer--pane-size (cons (window-body-width window) (- height 4))))
       ;; The pane holds exactly the rows that fit.
       (should (= (count-lines (point-min) (point-max)) (- height 4)))))))

(ert-deftest codetracer-test-user-binding-shadows-codetracer-keymap ()
  "Your binding in a pane wins over CodeTracer's, and the server is told."
  :tags '(server)
  (codetracer-test--with-server
   (let* ((session (codetracer-open trace))
          (_ (codetracer-test--settle))
          (buffer (gethash "calltrace" (codetracer-session-panes session)))
          (theirs (with-current-buffer buffer (key-binding (kbd "<down>")))))
     ;; CodeTracer binds Down in the call trace.
     (should (get theirs 'codetracer-operation))
     (keymap-set codetracer-pane-user-map "<down>" #'ignore)
     (codetracer-report-user-bindings)
     (codetracer-test--settle)
     (with-current-buffer buffer
       (should (eq (key-binding (kbd "<down>")) #'ignore)))
     ;; The server's keymap now says the editor holds that key.
     (let ((keymap (codetracer--request :pane/keymap
                                        `(:session ,(codetracer-session-id session)
                                                   :pane "calltrace"))))
       (should (cl-find-if (lambda (b) (and (equal (plist-get b :key) "Down")
                                            (equal (plist-get b :shadowedBy) "editor")))
                           (plist-get keymap :bindings))))
     ;; Unbinding it gives the key back.
     (keymap-unset codetracer-pane-user-map "<down>" t)
     (codetracer-report-user-bindings)
     (codetracer-test--settle)
     (with-current-buffer buffer
       (should (get (key-binding (kbd "<down>")) 'codetracer-operation))))))

(ert-deftest codetracer-test-resize-survives-mode-round-trip ()
  "The user's pane sizes are the mode's layout: they come back with the mode."
  :tags '(server)
  (codetracer-test--with-server
   (let* ((session (codetracer-open trace))
          (_ (codetracer-test--settle))
          (window (codetracer-test--pane-window session "calltrace")))
     (window-resize window 5)
     (let ((resized (window-total-height window))
           (others (mapcar (lambda (p) (cons p (window-total-height
                                                (codetracer-test--pane-window session p))))
                           '("state" "eventLog"))))
       (codetracer--on-window-size-change (selected-frame))
       (codetracer-test--settle)
       (codetracer-toggle-mode)
       (codetracer-test--settle)
       (codetracer-toggle-mode)
       (codetracer-test--settle)
       (let ((window (codetracer-test--pane-window session "calltrace")))
         (should window)
         (should (<= (abs (- (window-total-height window) resized)) 1))
         (dolist (o others)
           (should (<= (abs (- (window-total-height
                                (codetracer-test--pane-window session (car o)))
                               (cdr o)))
                       1))))))))

(ert-deftest codetracer-test-switching-sessions-shows-their-layouts ()
  "Each session has its tab; selecting it shows that session's layout."
  :tags '(server)
  (codetracer-test--with-server
   (let* ((first (codetracer-open trace))
          (_ (codetracer-test--settle))
          (first-panes (codetracer-test--shown-panes))
          ;; A buffer named the way pane buffers were before `ct://', as a
          ;; `desktop' file saved then restores it: the second session's call
          ;; trace adopts it under the new name rather than leaving it behind.
          (legacy-name (format "*codetracer %s: calltrace*"
                               (1+ (codetracer-session-id first))))
          (legacy (get-buffer-create legacy-name))
          (second (codetracer-open trace)))
     (codetracer-test--settle)
     (should (eql (codetracer-session-id second) (1+ (codetracer-session-id first))))
     (should (eq (gethash "calltrace" (codetracer-session-panes second)) legacy))
     (should (equal (buffer-name legacy)
                    (format "ct://%s/calltrace" (codetracer-session-id second))))
     (should-not (get-buffer legacy-name))
     (should (get-buffer-window legacy))
     (should-not (eql (codetracer-session-id first) (codetracer-session-id second)))
     (should (= (length (tab-bar-tabs)) 3))
     ;; The second session goes to its edit mode; the first stays in debug.
     (codetracer-toggle-mode)
     (codetracer-test--settle)
     (should (equal (codetracer-session-mode second) "edit"))
     (let ((second-panes (codetracer-test--shown-panes)))
       (should-not (equal second-panes first-panes))
       (codetracer-switch-session (codetracer-session-id first))
       (codetracer-test--settle)
       (should (eq (codetracer--current-tab-session) first))
       (should (eql codetracer--active-session (codetracer-session-id first)))
       (should (equal (codetracer-test--shown-panes) first-panes))
       (should (equal (codetracer-session-mode first) "debug"))
       ;; Its panes are its own buffers.
       (dolist (w (codetracer--pane-windows))
         (should (eql (buffer-local-value 'codetracer--pane-session (window-buffer w))
                      (codetracer-session-id first))))
       (codetracer-switch-session (codetracer-session-id second))
       (codetracer-test--settle)
       (should (equal (codetracer-test--shown-panes) second-panes))))))

(ert-deftest codetracer-test-image-medium-declared ()
  "The server is told this Emacs takes images, and answers that it will send them."
  :tags '(server)
  (codetracer-test--with-server
   (let ((codetracer-media '("text" "image")))
     (let ((session (codetracer-open trace)))
       (codetracer-test--settle)
       (should (member "image" (append (plist-get (plist-get codetracer--server-info
                                                             :capabilities)
                                                  :media)
                                       nil)))
       (should (member "frameViewer" (append (plist-get (plist-get codetracer--server-info
                                                                   :capabilities)
                                                        :panes)
                                             nil)))
       ;; The `calc' recording carries no graphics: the frames command says so.
       (should-not (eq (plist-get (codetracer-session-graphics session) :available) t))
       (should-error (codetracer-show-frames) :type 'user-error)))))

(ert-deftest codetracer-test-desktop-keeps-the-arrangement ()
  "`desktop' restores the panes, their windows and the user's own; they reconnect."
  :tags '(server)
  (require 'desktop)
  (codetracer-test--with-server
   (let* ((dir (make-temp-file "codetracer-desktop" t))
          (notes (let ((f (make-temp-file "codetracer-notes" nil ".txt")))
                   (with-temp-file f (insert "my notes\n"))
                   f))
          (desktop-path (list dir))
          (desktop-restore-frames t)
          (desktop-load-locked-desktop t)
          (desktop-restore-eager t)
          (session (codetracer-open trace)))
     (unwind-protect
         (progn
           (codetracer-test--settle)
           (codetracer-toggle-mode)
           (codetracer-test--settle)
           (should (equal (codetracer-session-mode session) "edit"))
           ;; The user's own window beside ours, and a pane they resized.
           (let ((user-window (split-window (codetracer--source-window session) nil 'below)))
             (set-window-buffer user-window (find-file-noselect notes)))
           (let* ((panes (codetracer-test--shown-panes))
                  (pane (car panes))
                  (window (codetracer-test--pane-window session pane)))
             (ignore-errors (window-resize window 3))
             (codetracer--on-window-size-change (selected-frame))
             (codetracer-test--settle)
             (let ((sizes (mapcar (lambda (p) (cons p (window-total-height
                                                       (codetracer-test--pane-window session p))))
                                  panes)))
               (cl-letf (((symbol-function 'yes-or-no-p) #'always))
                 (desktop-save dir t))
               ;; Everything goes, as when Emacs exits.
               (codetracer-quit)
               (let ((deadline (+ (float-time) 10)))
                 (while (and (codetracer--live-p) (< (float-time) deadline))
                   (accept-process-output nil 0.1)))
               (dolist (b (buffer-list))
                 (when (or (buffer-local-value 'codetracer--pane b)
                           (equal (buffer-file-name b) notes))
                   (kill-buffer b)))
               (tab-bar-close-other-tabs)
               (delete-other-windows)
               (should-not (codetracer-test--shown-panes))
               ;; `desktop-read' does nothing in batch Emacs unless told
               ;; otherwise; it is the same call a starting Emacs makes.
               (let ((noninteractive nil))
                 (should (desktop-read dir)))
               (codetracer-test--settle)
               (let ((restored (codetracer--current-tab-session)))
                 (should restored)
                 (should (equal (codetracer-session-trace restored) (expand-file-name trace)))
                 (should (equal (codetracer-session-mode restored) "edit"))
                 ;; The same panes, in the same windows, at the same sizes.
                 (should (equal (codetracer-test--shown-panes) panes))
                 (dolist (s sizes)
                   (should (<= (abs (- (window-total-height
                                        (codetracer-test--pane-window restored (car s)))
                                       (cdr s)))
                               1)))
                 ;; The user's window is still there.
                 (should (get-buffer-window (find-buffer-visiting notes)))
                 ;; The panes are live again: open on the server, drawn.
                 (dolist (w (codetracer--pane-windows))
                   (with-current-buffer (window-buffer w)
                     (should codetracer--pane-open)
                     (should (eql codetracer--pane-session (codetracer-session-id restored)))
                     ;; Under the session's own name.
                     (should (equal (buffer-name)
                                    (format "ct://%s/%s" (codetracer-session-id restored)
                                            codetracer--pane)))
                     (should (> (buffer-size) 0))))))))
       (delete-directory dir t)
       (delete-file notes)))))

;; The scenario helpers below read the transport's own log of what crossed
;; it (jsonrpc's events buffer), to see what the package sent.
(defun codetracer-test--sent-p (method needle)
  "Non-nil when the transport log shows METHOD sent with NEEDLE in it."
  (with-current-buffer (jsonrpc-events-buffer codetracer--connection)
    (save-excursion
      (goto-char (point-min))
      (cl-loop while (search-forward method nil t)
               thereis (save-excursion
                         (search-forward needle (min (point-max) (+ (point) 4000)) t))))))

(defun codetracer-test--wait-sent (method needle)
  "Wait up to 10 seconds for METHOD with NEEDLE to be sent.
`read-event' rather than `accept-process-output': file notifications
reach Lisp as input events, which batch Emacs reads only there."
  (let ((deadline (+ (float-time) 10)))
    (while (and (not (codetracer-test--sent-p method needle))
                (< (float-time) deadline))
      (read-event nil nil 0.1)))
  (codetracer-test--sent-p method needle))

(ert-deftest codetracer-test-file-tree-role-filled-by-emacs ()
  "With the file-tree role given to Emacs, a dired listing takes the file pane's
place, and what the user does with files is reported as the pane would."
  :tags '(server)
  (codetracer-test--with-server
   (let ((codetracer-panels-file-tree 'editor))
     (let* ((session (codetracer-open trace))
            (_ (codetracer-test--settle))
            (main (plist-get (codetracer-session-position session) :file))
            (listing (get-buffer (codetracer--file-tree-name session))))
       (should (member main (codetracer--source-paths session)))
       ;; The listing is shown where the file pane would be, and lists the source.
       (should listing)
       (should (get-buffer-window listing))
       (with-current-buffer listing
         (should (derived-mode-p 'dired-mode))
         (should (dired-goto-file main)))
       ;; CodeTracer's own file pane is not opened.
       (should-not (cl-find-if (lambda (b) (and (equal (buffer-local-value 'codetracer--pane b)
                                                       "fileTree")
                                                (buffer-local-value 'codetracer--pane-open b)))
                               (buffer-list)))
       ;; Selecting the file in the listing is reported (what the listing's
       ;; `post-command-hook' runs after each command).
       (with-current-buffer listing
         (dired-goto-file main)
         (codetracer--file-tree-selection))
       (should (codetracer-test--wait-sent "files/selected" main))
       ;; Opening it: the source window's cursor is reported (what the global
       ;; `post-command-hook' runs).
       (with-selected-window (codetracer--source-window session)
         (find-file main)
         (goto-char (point-min))
         (forward-line 2)
         (setq codetracer--cursor-sent nil)
         (codetracer--report-cursor))
       (should (codetracer-test--wait-sent "source/cursor" main))
       ;; A file created and deleted beside the sources is reported.
       (let ((probe (expand-file-name "codetracer-el-probe.txt" (file-name-directory main))))
         (unwind-protect
             (progn
               (with-temp-file probe (insert "probe\n"))
               (should (codetracer-test--wait-sent "files/changed" probe)))
           (delete-file probe)))))))

(ert-deftest codetracer-test-file-pane-row-opens-the-file ()
  "A row of CodeTracer's file pane opens its file in Emacs's source window; a
recorded source is readable, read-only, from the recording."
  :tags '(server)
  (codetracer-test--with-server
   (let* ((session (codetracer-open trace))
          (_ (codetracer-test--settle))
          (main (plist-get (codetracer-session-position session) :file))
          (pane (gethash "fileTree" (codetracer-session-panes session)))
          (source (codetracer--source-window session)))
     (should (get-buffer-window pane))
     (set-window-buffer source (get-buffer-create "*elsewhere*"))
     (with-current-buffer pane
       (goto-char (point-min))
       (let ((match (text-property-search-forward
                     'codetracer-hotspot nil
                     (lambda (_ v) (and v (equal (car v) "file-tree.open"))))))
         (should match)
         (goto-char (prop-match-beginning match))
         (should (string-suffix-p "main.py" (plist-get (cdr (codetracer--hotspot-at (point)))
                                                       :path)))
         (codetracer-activate-hotspot)))
     (codetracer-test--settle)
     (should (equal (buffer-file-name (window-buffer source)) main))
     ;; The recording's text of the same source, as shown for one that is
     ;; not on this disk: read-only, and the recorded text.
     (let ((buffer (codetracer--recorded-buffer session main)))
       (codetracer-test--settle)
       (with-current-buffer buffer
         (should buffer-read-only)
         (should (equal (buffer-string)
                        (with-temp-buffer (insert-file-contents main) (buffer-string)))))
       (kill-buffer buffer)))))

;;;; Stacked panes, divider drags and refusals

(defvar codetracer-test--sent nil
  "The requests the package sent, newest first, as (METHOD . PARAMS).")

(defun codetracer-test--record-send (_connection &rest args)
  "Record the request or notification in ARGS (`jsonrpc-connection-send')."
  (when-let ((method (plist-get args :method)))
    (push (cons (string-remove-prefix ":" (format "%s" method)) (plist-get args :params))
          codetracer-test--sent)))

(defmacro codetracer-test--recording-sends (&rest body)
  "Run BODY recording, in `codetracer-test--sent', what the package sends.
The record is taken where every message leaves for the server, the
transport's own send; nothing is changed on the way."
  (declare (indent 0))
  `(let ((codetracer-test--sent nil))
     (advice-add 'jsonrpc-connection-send :before #'codetracer-test--record-send)
     (unwind-protect (progn ,@body)
       (advice-remove 'jsonrpc-connection-send #'codetracer-test--record-send))))

(defun codetracer-test--count-sent (method pane)
  "How many METHOD requests for PANE `codetracer-test--sent' holds."
  (cl-count-if (lambda (m) (and (equal (car m) method)
                                (equal (plist-get (cdr m) :pane) pane)))
               codetracer-test--sent))

(defun codetracer-test--wait-for (predicate seconds what)
  "Wait up to SECONDS for PREDICATE to hold, failing with WHAT if it does not."
  (let ((deadline (+ (float-time) seconds)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (unless (funcall predicate)
      (ert-fail (format "timed out waiting for %s" what)))))

;; The drag case's control runs it against the package without its
;; coalescing, which has neither the pending-resize flag nor the pending
;; report: the reads below tolerate their absence, so the control fails on
;; what it measures rather than on a missing variable.
(defun codetracer-test--resize-pending-p (buffer)
  "Non-nil while BUFFER's pane has a `pane/resize' awaiting its answer."
  (and (local-variable-p 'codetracer--pane-resizing buffer)
       (buffer-local-value 'codetracer--pane-resizing buffer)))

(defun codetracer-test--report-pending-p (session)
  "Non-nil while SESSION's sizes-only `layout/edited' awaits its answer."
  (and (fboundp 'codetracer-session-reporting)
       (funcall 'codetracer-session-reporting session)))

(defun codetracer-test--painted-p (window)
  "Non-nil when WINDOW's pane is painted at the window's size, nothing pending."
  (with-current-buffer (window-buffer window)
    (and (not (codetracer-test--resize-pending-p (current-buffer)))
         (equal codetracer--pane-size (cons (window-body-width window)
                                            (window-body-height window)))
         (= (count-lines (point-min) (point-max)) (window-body-height window)))))

(defun codetracer-test--stack-window ()
  "A window showing one of several stacked panes, or nil."
  (cl-find-if (lambda (w) (window-parameter w 'codetracer-stack))
              (codetracer--pane-windows)))

(defun codetracer-test--header-line (window)
  "The header line WINDOW shows, as a string.
The package's header line is a string with no %-constructs but `%%',
so it is what is displayed; `format-mode-line' would say so too, but
returns \"\" in batch Emacs."
  (let ((line (buffer-local-value 'header-line-format (window-buffer window))))
    (should (stringp line))
    line))

(defun codetracer-test--click-tab (window index)
  "Click tab INDEX in WINDOW's header line, as the command loop runs a click.
The click is the event a click there is, prefixed with the area it hit
as `read-key-sequence' prefixes it (batch Emacs's does not), and run
through the binding Emacs finds for it at that position: the keymap on
the clicked text."
  (let* ((line (codetracer-test--header-line window))
         (at (text-property-any 0 (length line) 'codetracer-stack-index index line))
         (event `(mouse-1 (,window header-line (,at . 0) 0 (,line . ,(1+ at))
                                   nil (,(1+ at) . 0) nil (0 . 0) (1 . 1))))
         (keys (vector 'header-line event))
         (command (key-binding keys t nil (event-start event))))
    (should at)
    (should (eq command #'codetracer-stack-tab-click))
    (call-interactively command nil keys)))

(defun codetracer-test--active-tab (window)
  "The name WINDOW's tabs show as the active one."
  (let* ((line (codetracer-test--header-line window))
         (at (text-property-any 0 (length line) 'face 'codetracer-stack-tab-active line)))
    (and at (string-trim (substring-no-properties
                          line at (next-single-property-change at 'face line (length line)))))))

(ert-deftest codetracer-test-clicking-a-stack-tab-shows-that-pane ()
  "A click on a stacked pane's name in its window's tabs shows that pane there."
  :tags '(server)
  (codetracer-test--with-server
   (let* ((session (codetracer-open trace))
          (_ (codetracer-test--settle))
          (window (codetracer-test--stack-window)))
     (should window)
     (let* ((path (append (window-parameter window 'codetracer-stack) nil))
            (stack (codetracer--node-at (codetracer-session-layout session) path))
            (kids (codetracer--node-children stack))
            (shown (codetracer--stack-active stack))
            (target (mod (1+ shown) (length kids)))
            (before (window-buffer window))
            (before-pane (buffer-local-value 'codetracer--pane before))
            (target-pane (codetracer--node-pane (nth target kids))))
       (should (equal (codetracer-test--active-tab window) before-pane))
       (codetracer-test--click-tab window target)
       (codetracer-test--settle)
       ;; The same window, now the clicked pane's buffer, its tab active.
       (should (window-live-p window))
       (should (equal (buffer-name (window-buffer window))
                      (format "ct://%s/%s" (codetracer-session-id session) target-pane)))
       (should (equal (codetracer-test--active-tab window) target-pane))
       (should (eql (codetracer--stack-active
                     (codetracer--node-at (codetracer-session-layout session) path))
                    target))
       ;; The pane the window showed is closed; the clicked one is painted.
       (should-not (buffer-local-value 'codetracer--pane-open before))
       (codetracer-test--wait-for (lambda () (codetracer-test--painted-p window))
                                  15 "the clicked pane's content")
       ;; A resize keeps the pick: the server's answer does not undo it.
       (window-resize window -1)
       (codetracer--on-window-size-change (selected-frame))
       (codetracer-test--settle)
       (should (equal (buffer-local-value 'codetracer--pane (window-buffer window)) target-pane))
       ;; And back.
       (codetracer-test--click-tab window shown)
       (codetracer-test--settle)
       (should (eq (window-buffer window) before))
       (should (equal (codetracer-test--active-tab window) before-pane))
       (codetracer-test--wait-for (lambda () (codetracer-test--painted-p window))
                                  15 "the first pane's content again")))))

(ert-deftest codetracer-test-drag-coalesces-resizes ()
  "Dragging a divider paints the size it stops at without queueing those between.
The window shrinks one row per turn of the event loop, as a drag
delivers mouse motions: each turn runs the window-change hook, far
sooner than the server repaints."
  :tags '(server)
  (codetracer-test--with-server
   (let* ((session (codetracer-open trace))
          (_ (codetracer-test--settle))
          (window (codetracer-test--pane-window session "calltrace"))
          (steps 10)
          (height nil) (final nil)
          (resizes 0) (reports 0) (started 0) (settled 0))
     ;; Batch Emacs's frame is a terminal's few rows: the window first
     ;; takes the room its neighbours can give, for ten rows to drag over.
     (window-resize window (window-max-delta window))
     (codetracer--on-window-size-change (selected-frame))
     (codetracer-test--wait-for (lambda () (codetracer-test--painted-p window))
                                15 "content at the grown height")
     (setq height (window-body-height window)
           final (- height steps))
     (should (> final 1))
     (codetracer-test--recording-sends
       (setq started (float-time))
       (dotimes (_ steps)
         (window-resize window -1)
         ;; What redisplay does after the change: the hook schedules the
         ;; report for the next turn, which this wait gives it.
         (codetracer--schedule-window-change (selected-frame))
         (accept-process-output nil 0.001))
       (should (= (window-body-height window) final))
       (codetracer-test--wait-for (lambda () (and (codetracer-test--painted-p window)
                                                  (not (codetracer-test--report-pending-p
                                                        session))))
                                  15 "content at the height the drag stopped at")
       (setq settled (float-time))
       (setq resizes (codetracer-test--count-sent "pane/resize" "calltrace")
             reports (cl-count-if (lambda (m) (and (equal (car m) "layout/edited")
                                                   (equal (plist-get (cdr m) :closed) [])))
                                  codetracer-test--sent)))
     (message "drag: %d rows to %d in %d steps, %d pane/resize, %d layout/edited, settled %.0f ms after the start"
              height final steps resizes reports (* 1000 (- settled started)))
     (with-current-buffer (window-buffer window)
       (should (equal codetracer--pane-size (cons (window-body-width window) final))))
     ;; Sending every size is one request per step; one in flight at a time
     ;; is the first size and the last.
     (should (> resizes 0))
     (should (<= resizes (/ steps 2)))
     (should (> reports 0))
     (should (<= reports (/ steps 2)))
     ;; The last layout reported is the one on screen.
     (let ((window (codetracer-test--pane-window session "calltrace")))
       (window-resize window steps)
       (codetracer--on-window-size-change (selected-frame))
       (codetracer-test--wait-for (lambda () (codetracer-test--painted-p window))
                                  15 "content at the old height again")))))

(ert-deftest codetracer-test-closed-pane-gets-no-resize ()
  "A pane closed while its resize is in flight is not resized when it is answered."
  :tags '(server)
  (codetracer-test--with-server
   (let* ((session (codetracer-open trace))
          (_ (codetracer-test--settle))
          (window (codetracer-test--pane-window session "calltrace"))
          (buffer (window-buffer window)))
     (codetracer-test--recording-sends
       (window-resize window -2)
       (codetracer--on-window-size-change (selected-frame))
       (should (buffer-local-value 'codetracer--pane-resizing buffer))
       (should (codetracer-session-reporting session))
       ;; The user closes the pane while both are pending: the close is
       ;; reported at once, not held back behind the sizes report.
       (delete-window window)
       (codetracer--on-window-buffer-change (selected-frame))
       (should (cl-find-if (lambda (m) (and (equal (car m) "layout/edited")
                                            (equal (plist-get (cdr m) :closed) ["calltrace"])))
                           codetracer-test--sent))
       (should (= (codetracer-test--count-sent "pane/close" "calltrace") 1))
       (should (codetracer-session-reporting session))
       (let ((after-close (length codetracer-test--sent)))
         ;; The buffer is shown again by the user, outside the layout, before
         ;; the answer arrives: still no request for the closed pane.
         (set-window-buffer (codetracer--source-window session) buffer)
         (codetracer-test--wait-for
          (lambda () (not (buffer-local-value 'codetracer--pane-resizing buffer)))
          15 "the resize's answer")
         (codetracer-test--settle)
         (should-not (cl-find-if (lambda (m) (and (member (car m) '("pane/resize" "pane/open"))
                                                  (equal (plist-get (cdr m) :pane) "calltrace")))
                                 (butlast codetracer-test--sent after-close)))
         (should-not (buffer-local-value 'codetracer--pane-open buffer)))))))

(ert-deftest codetracer-test-pane-open-is-not-held-back ()
  "Opening a pane that is not open is sent at once, even with a resize pending."
  :tags '(server)
  (codetracer-test--with-server
   (let* ((session (codetracer-open trace))
          (_ (codetracer-test--settle))
          (window (codetracer-test--pane-window session "calltrace"))
          (buffer (window-buffer window)))
     (codetracer-test--recording-sends
       (window-resize window -1)
       (codetracer--on-window-size-change (selected-frame))
       (should (buffer-local-value 'codetracer--pane-resizing buffer))
       ;; Closed and shown again (a mode round trip does this) before the
       ;; resize is answered: the open goes out immediately.
       (codetracer--close-pane buffer)
       (codetracer--sync-pane-size window)
       (should (= (codetracer-test--count-sent "pane/open" "calltrace") 1))
       (should (buffer-local-value 'codetracer--pane-open buffer))
       (codetracer-test--wait-for (lambda () (codetracer-test--painted-p window))
                                  15 "the reopened pane's content")))))

(ert-deftest codetracer-test-refusal-is-shown ()
  "An operation the server refuses tells the user why."
  :tags '(server)
  (codetracer-test--with-server
   (let* ((session (codetracer-open trace))
          (_ (codetracer-test--settle))
          (shown nil)
          (record (lambda (format &rest args)
                    (when format (push (apply #'format-message format args) shown)))))
     (advice-add 'message :before record)
     (unwind-protect
         ;; The `calc' recording carries no graphics: the frame viewer refuses.
         (should-not (codetracer--run "frame-viewer.next-frame"
                                      :session (codetracer-session-id session)))
       (advice-remove 'message record))
     (should (cl-find-if (lambda (m) (string-match-p
                                      "\\`CodeTracer: frame-viewer.next-frame: .*graphics" m))
                         shown)))))

(ert-deftest codetracer-test-ok-false-refusal-is-shown ()
  "An operation the session cannot perform answers `ok: false' with its reason,
and the user is shown it, from a pane's hotspot as from a command."
  :tags '(server)
  (codetracer-test--with-server
   (let* ((session (codetracer-open trace))
          (_ (codetracer-test--settle))
          (shown nil)
          (record (lambda (format &rest args)
                    (when format (push (apply #'format-message format args) shown)))))
     (advice-add 'message :before record)
     (unwind-protect
         ;; What a click on a Test Results row's ⏵ sends, for a test that is
         ;; not listed.
         (let ((result (codetracer--run "tests.open-test" :pane "testResults"
                                        :args '(:path "no-such-test")
                                        :session (codetracer-session-id session))))
           (should (eq (plist-get result :ok) :json-false))
           (should (stringp (plist-get result :detail)))
           (should-not (string-empty-p (plist-get result :detail))))
       (advice-remove 'message record))
     (should (cl-find-if (lambda (m) (string-match-p
                                      "\\`CodeTracer: tests.open-test: .*no longer listed" m))
                         shown)))))

;;;; Debugger controls and source keys

(defun codetracer-test--tick (session)
  "SESSION's position's tick."
  (plist-get (codetracer-session-position session) :tick))

(defun codetracer-test--wait-tick-change (session tick what)
  "Wait for SESSION's tick to differ from TICK, failing with WHAT."
  (codetracer-test--wait-for (lambda () (not (eql (codetracer-test--tick session) tick)))
                             30 what))

(defun codetracer-test--tab-bar-item (key)
  "The tab bar's item KEY as Emacs builds the tab bar: (KEY menu-item CAPTION ...)."
  (cl-find key (cdr (tab-bar-make-keymap-1)) :key #'car-safe))

(ert-deftest codetracer-test-controls-strip-in-the-tab-bar ()
  "The debugger controls are drawn at the right of the tab bar; a click steps;
after Stop every control is disabled and a click sends nothing; the
tab bar's format is given back when the last session closes."
  :tags '(server)
  (let ((default (eval (car (get 'tab-bar-format 'standard-value)) t)))
    (codetracer-test--with-server
     (let ((tab-bar-format (copy-sequence default))
           (codetracer-controls 'tab-bar)
           (codetracer-controls-glyphs 'unicode))
       (let* ((session (codetracer-open trace))
              (_ (codetracer-test--settle))
              (buttons (codetracer-session-controls session)))
         (should (= (length buttons) 10))
         (should (cl-find "next" buttons :key (lambda (b) (plist-get b :id)) :test #'equal))
         ;; The format is the default one with the controls at its right.
         (should (equal (last tab-bar-format 2)
                        '(tab-bar-format-align-right codetracer-tab-bar-controls)))
         ;; Built into the tab bar: the Next glyph, a button running Next.
         (let ((next (codetracer-test--tab-bar-item 'codetracer-control-next)))
           (should next)
           (should (string-match-p "↷" (nth 2 next)))
           (should (codetracer-test--tab-bar-item 'align-right))
           (let ((tick (codetracer-test--tick session)))
             ;; What `tab-bar-mouse-down-1' does with a click on the item.
             (call-interactively (nth 3 next))
             (codetracer-test--wait-tick-change session tick "the click's step")))
         ;; Stop: every control is disabled, and a click does nothing.
         (codetracer-stop)
         (codetracer-test--settle)
         (should (= (length (codetracer-session-controls session)) 10))
         (should-not (cl-find-if #'codetracer--control-enabled-p
                                 (codetracer-session-controls session)))
         (let ((next (codetracer-test--tab-bar-item 'codetracer-control-next))
               (tick (codetracer-test--tick session)))
           (should (eq (nth 3 next) #'ignore))
           (should (eq (get-text-property 1 'face (nth 2 next)) 'codetracer-control-disabled))
           (codetracer-test--recording-sends
             (call-interactively (nth 3 next))
             (codetracer-test--settle)
             (should-not (assoc "operation/run" codetracer-test--sent)))
           (should (eql (codetracer-test--tick session) tick)))
         ;; The last session closes: the format is the user's again.
         (codetracer-close-session (codetracer-session-id session))
         (should (equal tab-bar-format default))
         (should-not (memq 'codetracer-tab-bar-controls tab-bar-format)))))))

(ert-deftest codetracer-test-source-keys-step-and-yield ()
  "The debugger's function keys work in the source buffer, the user's own
binding of one of them wins, and leaving the session's tab takes them away."
  :tags '(server)
  (codetracer-test--with-server
   (let* ((session (codetracer-open trace))
          (_ (codetracer-test--settle))
          (window (codetracer--source-window session))
          (buffer (window-buffer window))
          (bindings (codetracer-session-source-bindings session))
          (step (car (rassoc "debugger.step-over" bindings)))
          (other (car (cl-find-if (lambda (b) (not (equal (cdr b) "debugger.step-over")))
                                  bindings))))
     (should bindings)
     ;; Only function-key chords, only the debugger's operations.
     (pcase-dolist (`(,key . ,op) bindings)
       (should (string-match-p "\\`\\(?:[ACHMSs]-\\)*<f[0-9]+>\\'" key))
       (should (or (string-prefix-p "debugger." op) (string-prefix-p "editor.toggle-" op))))
     (should step)
     (should other)
     (should (buffer-file-name buffer))
     (with-current-buffer buffer
       (should codetracer-source-mode)
       (should (eq (key-binding (kbd step)) 'codetracer-debugger-step-over)))
     ;; Pressing it steps.
     (let ((tick (codetracer-test--tick session)))
       (with-selected-window window
         (execute-kbd-macro (kbd step)))
       (codetracer-test--wait-tick-change session tick (format "%s's step" step)))
     ;; The user's global binding of another of the keys wins.
     (let* ((old (keymap-lookup global-map other))
            (hit nil)
            (mine (lambda () (interactive) (setq hit t))))
       (unwind-protect
           (progn
             (keymap-global-set other mine)
             (with-current-buffer buffer
               (should codetracer-source-mode)
               (should (eq (key-binding (kbd other)) mine)))
             (with-selected-window window
               (execute-kbd-macro (kbd other)))
             (should hit))
         (keymap-global-set other old)))
     ;; Another tab: the source buffer has no CodeTracer keys there.
     (tab-bar-new-tab)
     (with-current-buffer buffer
       (should-not codetracer-source-mode)
       (should-not (eq (key-binding (kbd step)) 'codetracer-debugger-step-over)))
     ;; Back in the session's tab, they are back.
     (tab-bar-close-tab)
     (codetracer-switch-session (codetracer-session-id session))
     (with-current-buffer buffer
       (should codetracer-source-mode))
     ;; Turned off, none are bound.
     (let ((codetracer-source-keys nil))
       (codetracer--sync-source-keys)
       (with-current-buffer buffer
         (should-not codetracer-source-mode))))))

;;;; Edit mode (tag `edit')

;; A test recorded from CodeTracer's Test Results pane opens its recording as
;; a session of its own, in a tab of its own (`session/opened').  Nothing is
;; mocked: the project is the two-test Noir crate CodeTracer's own Test
;; Results suites run (`plat53_noir_project.nim' in CodeTracer, byte for
;; byte), written to a temporary directory the pane server is started in --
;; its Edit-mode project is the directory it starts in.  Recording the test
;; runs the real `ct record-test', which needs `ct' (CT_BIN, or on PATH) and
;; `nargo' on PATH, besides what every scenario needs.  `just test-edit'
;; runs it.

(defconst codetracer-test--nargo-toml
  "[package]\nname = \"plat53_suite\"\ntype = \"bin\"\nauthors = [\"\"]\n\n[dependencies]\n"
  "The crate's Nargo.toml.")

(defconst codetracer-test--main-nr
  "fn main(x: Field, y: pub Field) {
    assert(x != y);
}

#[test]
fn test_passes() {
    main(1, 2);
}

#[test]
fn test_fails() {
    main(1, 1);
}
"
  "The crate's src/main.nr: one test that passes, one that fails.")

(defun codetracer-test--write-crate ()
  "Write the two-test Noir crate to a new temporary directory; return it."
  (let ((dir (file-name-as-directory (make-temp-file "codetracer-el-crate" t))))
    (make-directory (expand-file-name "src" dir))
    (with-temp-file (expand-file-name "Nargo.toml" dir) (insert codetracer-test--nargo-toml))
    (with-temp-file (expand-file-name "src/main.nr" dir) (insert codetracer-test--main-nr))
    dir))

(defun codetracer-test--show-stacked-pane (session pane)
  "Show SESSION's PANE in the window of the stack it is one of; return the window."
  (cl-loop for window in (codetracer--pane-windows)
           for path = (append (window-parameter window 'codetracer-stack) nil)
           for stack = (and path (codetracer--node-at (codetracer-session-layout session) path))
           for index = (and stack (cl-position pane (codetracer--node-children stack)
                                               :key #'codetracer--node-pane :test #'equal))
           when index
           do (codetracer--stack-select session window index)
           and return window))

(defun codetracer-test--row-hotspot (buffer needle operation)
  "The hotspot (OPERATION . ARGS) on the row of BUFFER that contains NEEDLE, or nil."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (cl-loop while (search-forward needle nil t)
               thereis (let ((end (line-end-position)))
                         (cl-loop for pos from (line-beginning-position) below end
                                  for spot = (codetracer--hotspot-at pos)
                                  when (equal (car spot) operation) return spot))))))

(defun codetracer-test--check-recorder ()
  "Fail unless the real recorder the edit-mode cases use is there."
  (let ((ct (or (getenv "CT_BIN") (executable-find "ct"))))
    (unless (and ct (file-executable-p ct))
      (ert-fail "ct is not found (CT_BIN or PATH): the edit-mode suite records with it"))
    (unless (executable-find "nargo")
      (ert-fail "nargo is not on PATH: the edit-mode suite's crate is a Noir one"))))

(defmacro codetracer-test--with-crate-session (&rest body)
  "Run BODY with `crate' and `session': the calc recording, its server in the crate.
The crate is the two-test Noir one, written to a temporary directory the
pane server is started in, so it is the session's Edit-mode project."
  (declare (indent 0))
  `(progn
     (codetracer-test--check-recorder)
     (let* ((crate (codetracer-test--write-crate))
            (certificates (make-temp-file "codetracer-el-certificates" t))
            (process-environment (cons (concat "TEST_CERTIFICATES_DIR=" certificates)
                                       process-environment)))
       (unwind-protect
           (codetracer-test--with-server
             (let ((session (let ((default-directory crate)) (codetracer-open trace))))
               (codetracer-test--settle)
               ,@body))
         (dolist (b (buffer-list))
           (when (and (buffer-file-name b) (string-prefix-p crate (buffer-file-name b)))
             (kill-buffer b)))
         (delete-directory crate t)
         (delete-directory certificates t)))))

(ert-deftest codetracer-test-recorded-test-opens-a-session-tab ()
  "A test recorded from Test Results opens its recording in a tab of its own."
  :tags '(edit)
  (codetracer-test--with-crate-session
          (let* ((window (codetracer-test--show-stacked-pane session "testResults"))
                 (buffer (gethash "testResults" (codetracer-session-panes session)))
                 (spot nil))
            (should window)
            (should (eq (window-buffer window) buffer))
            ;; Batch Emacs's frame is 80 columns: the pane is widened, as a
            ;; user would drag it, so the rows have room for the tests' names.
            (window-resize window (window-max-delta window t) t)
            (codetracer--on-window-size-change (selected-frame))
            ;; The server lists the crate's tests; the failing one's ⏵ records it.
            (codetracer-test--wait-for
             (lambda () (setq spot (codetracer-test--row-hotspot buffer "test_fails"
                                                                 "tests.open-test")))
             60 "the failing test's row in Test Results")
            (let ((tabs (length (tab-bar-tabs))))
              ;; What a click on the ⏵ runs (`codetracer-activate-hotspot').
              (with-current-buffer buffer
                (codetracer--run (car spot) :args (cdr spot) :pane codetracer--pane
                                 :session codetracer--pane-session))
              (let ((opened nil))
                (codetracer-test--wait-for
                 (lambda ()
                   (setq opened (cl-loop for s being the hash-values of codetracer--sessions
                                         unless (eq s session) return s)))
                 240 "the recorded test's session")
                (should (= (length (tab-bar-tabs)) (1+ tabs)))
                (should (eq (codetracer--current-tab-session) opened))
                (should-not (equal (codetracer-session-tab opened) (codetracer-session-tab session)))
                (should (file-directory-p (codetracer-session-trace opened)))
                (should (codetracer--session (codetracer-session-id session)))
                (codetracer-test--wait-for (lambda () (codetracer-session-position opened))
                                           60 "the recording's position")
                ;; Its panes are shown, and its source followed.
                (should (cl-find-if (lambda (w) (eql (buffer-local-value 'codetracer--pane-session
                                                                         (window-buffer w))
                                                     (codetracer-session-id opened)))
                                    (codetracer--pane-windows))))))))

;;;;; Tests from the source

;; The crate's tests, as the source shows them (`source/tests'): a fringe
;; mark on each test's line whose `[left-fringe mouse-1]' records it, and
;; `codetracer-test-at-point'.  Batch Emacs cannot click, and runs no
;; redisplay: the click is the event a fringe click delivers, constructed
;; (a `left-fringe' position on the line), its command found the way the
;; command loop finds it -- `key-binding' in the keymaps at the event's
;; position -- and called with that event.  The file is shown with
;; `find-file', whose `set-window-buffer' runs `window-scroll-functions'
;; even in batch: that is what reports the source window's file to the
;; server (`source/viewport'), which then sends its tests.

(defun codetracer-test--test-overlays (buffer)
  "BUFFER's test overlays, as (LINE BITMAP . OVERLAY), sorted by line.
BITMAP is the left-fringe bitmap the overlay draws, or nil."
  (with-current-buffer buffer
    (sort (mapcar (lambda (ov)
                    (let* ((string (overlay-get ov 'before-string))
                           (display (cl-loop for i below (length string)
                                             for d = (get-text-property i 'display string)
                                             when (eq (car-safe d) 'left-fringe) return d)))
                      (cons (line-number-at-pos (overlay-start ov))
                            (cons (nth 1 display) ov))))
                  codetracer--test-overlays)
          (lambda (a b) (< (car a) (car b))))))

(defun codetracer-test--visit-main (session crate)
  "Show the crate's src/main.nr in SESSION's source window; return its buffer.
It waits for the file's two tests to be drawn."
  (select-window (codetracer--source-window session))
  (let ((buffer (find-file (expand-file-name "src/main.nr" crate))))
    (codetracer-test--wait-for
     (lambda () (= (length (codetracer-test--test-overlays buffer)) 2))
     60 "the crate's two tests drawn in src/main.nr")
    buffer))

(defun codetracer-test--fringe-event (window line &optional modifiers)
  "A mouse-1 click event in WINDOW's left fringe on LINE, with MODIFIERS.
MODIFIERS is a list such as (control).  The position is what Emacs gives a
fringe click: the window, the `left-fringe' area, the line's start."
  (let ((pos (with-current-buffer (window-buffer window)
               (save-excursion (goto-char (point-min))
                               (forward-line (1- line))
                               (point)))))
    (list (event-convert-list (append modifiers '(mouse-1)))
          (list window 'left-fringe '(0 . 0) 0 nil pos '(0 . 0) nil '(0 . 0) '(0 . 0)))))

(defun codetracer-test--wait-new-session (known what &optional seconds)
  "Wait for a session whose id is not in KNOWN; return it.  WHAT names it.
It waits up to SECONDS, 240 by default."
  (let (found)
    (codetracer-test--wait-for
     (lambda ()
       (setq found (cl-loop for s being the hash-values of codetracer--sessions
                            unless (memq (codetracer-session-id s) known) return s)))
     (or seconds 240) what)
    found))

(defun codetracer-test--session-ids ()
  "The ids of the open sessions."
  (hash-table-keys codetracer--sessions))

(ert-deftest codetracer-test-source-tests-are-fringe-marks-that-record ()
  "The file's tests are fringe marks on their lines; a click records one.
A fringe click on another line, and a click in the text, are not taken."
  :tags '(edit)
  (codetracer-test--with-crate-session
    (let* ((buffer (codetracer-test--visit-main session crate))
           (window (get-buffer-window buffer))
           (marks (codetracer-test--test-overlays buffer)))
      ;; On each test's line, its `#[test]': a play mark, not yet run.
      (should (equal (mapcar #'car marks) '(5 10)))
      (should (equal (mapcar #'cadr marks) '(codetracer-test-play codetracer-test-play)))
      (let* ((click (codetracer-test--fringe-event window 10))
             (command (key-binding [left-fringe mouse-1] t nil (event-start click))))
        (should (eq command #'codetracer-test-fringe-click))
        ;; Not another line's fringe, not the text area.
        (should-not (eq (key-binding [left-fringe mouse-1] t nil
                                     (event-start (codetracer-test--fringe-event window 9)))
                        #'codetracer-test-fringe-click))
        (should-not (memq (key-binding [mouse-1] t nil (event-start click))
                          '(codetracer-test-fringe-click codetracer-test-fringe-click-here)))
        (let ((known (codetracer-test--session-ids))
              (tabs (length (tab-bar-tabs))))
          (funcall command click)
          (let ((opened (codetracer-test--wait-new-session known "the clicked test's recording")))
            (should (equal (codetracer-session-title opened) "test_fails"))
            (should (= (length (tab-bar-tabs)) (1+ tabs)))
            (should (eq (codetracer--current-tab-session) opened))
            ;; The session it was recorded from is still open.
            (should (codetracer--session (codetracer-session-id session)))))))))

(ert-deftest codetracer-test-test-at-point-records-the-test-point-is-in ()
  "`codetracer-test-at-point' in a test's body records that test, in a new tab.
A buffer visiting the file opened later shows its tests at once."
  :tags '(edit)
  (codetracer-test--with-crate-session
    (let ((buffer (codetracer-test--visit-main session crate))
          (known (codetracer-test--session-ids)))
      ;; Visited again later, the file shows the tests the session holds:
      ;; the server does not send them again, as they have not changed.
      (kill-buffer buffer)
      (setq buffer (find-file-noselect (expand-file-name "src/main.nr" crate)))
      (should (equal (mapcar #'car (codetracer-test--test-overlays buffer)) '(5 10)))
      (with-current-buffer buffer
        (goto-char (point-min))
        ;; Line 1, above every test: there is none to record.
        (should-error (codetracer-test-at-point) :type 'user-error)
        (forward-line 6)                ; line 7, `main(1, 2);'
        (codetracer-test-at-point))
      (let ((opened (codetracer-test--wait-new-session known "the test at point's recording")))
        (should (equal (codetracer-session-title opened) "test_passes"))
        (should (codetracer--session (codetracer-session-id session)))))))

(defvar codetracer-test--opened nil
  "The `session/opened' notifications received, newest first.")

(defun codetracer-test--record-opened (params)
  "Record the `session/opened' PARAMS."
  (push params codetracer-test--opened))

(defun codetracer-test--check-replaced (session opened title)
  "Check OPENED, the recording of TITLE, took SESSION's place."
  (should (equal (codetracer-session-title opened) title))
  (let ((announced (cl-find (codetracer-session-id opened) codetracer-test--opened
                            :key (lambda (p) (plist-get p :session)))))
    (should (equal (plist-get announced :placement) "current-tab"))
    (should (eql (plist-get announced :replaces) (codetracer-session-id session))))
  (should-not (codetracer--session (codetracer-session-id session)))
  (should-not (tab-bar--tab-index-by-name (codetracer-session-tab session)))
  (should (eq (codetracer--current-tab-session) opened)))

(ert-deftest codetracer-test-test-at-point-here-replaces-the-session ()
  "With a prefix argument, the test's recording takes the place of the session."
  :tags '(edit)
  (codetracer-test--with-crate-session
    (let ((buffer (codetracer-test--visit-main session crate))
          (known (codetracer-test--session-ids))
          (codetracer-test--opened nil))
      (advice-add 'codetracer--on-session-opened :before #'codetracer-test--record-opened)
      (unwind-protect
          (progn
            (with-current-buffer buffer
              (goto-char (point-min))
              (forward-line 11)         ; line 12, `main(1, 1);'
              (codetracer-test-at-point '(4)))
            (codetracer-test--check-replaced
             session (codetracer-test--wait-new-session known "the recording that replaces the session")
             "test_fails"))
        (advice-remove 'codetracer--on-session-opened #'codetracer-test--record-opened)))))

(ert-deftest codetracer-test-ctrl-click-on-a-test-replaces-the-session ()
  "A Ctrl+click on a test's fringe mark records it in place of the session."
  :tags '(edit)
  (codetracer-test--with-crate-session
    (let* ((buffer (codetracer-test--visit-main session crate))
           (click (codetracer-test--fringe-event (get-buffer-window buffer) 5 '(control)))
           (command (key-binding [left-fringe C-mouse-1] t nil (event-start click)))
           (known (codetracer-test--session-ids))
           (codetracer-test--opened nil))
      (should (eq command #'codetracer-test-fringe-click-here))
      ;; The press before it is taken too: unbound, it would be the text
      ;; area's buffer menu.
      (should (eq (key-binding [left-fringe C-down-mouse-1] t nil (event-start click)) #'ignore))
      (advice-add 'codetracer--on-session-opened :before #'codetracer-test--record-opened)
      (unwind-protect
          (progn
            (funcall command click)
            (codetracer-test--check-replaced
             session (codetracer-test--wait-new-session known "the recording that replaces the session")
             "test_passes"))
        (advice-remove 'codetracer--on-session-opened #'codetracer-test--record-opened)))))

(defun codetracer-test--png-size (data)
  "The (WIDTH . HEIGHT) a PNG's header in DATA declares."
  (should (string-prefix-p "\x89PNG\r\n\x1a\n" data))
  (cl-flet ((u32 (at) (+ (ash (aref data at) 24) (ash (aref data (+ at 1)) 16)
                         (ash (aref data (+ at 2)) 8) (aref data (+ at 3)))))
    ;; The IHDR chunk follows the 8-byte signature and its 8-byte header.
    (cons (u32 16) (u32 20))))

(defun codetracer-test--frame-image (buffer)
  "The image descriptor BUFFER displays, or nil."
  (with-current-buffer buffer
    (let ((pos (next-single-property-change (point-min) 'display)))
      (and pos (get-text-property pos 'display)))))

(ert-deftest codetracer-test-frames-drawn-from-a-real-recording ()
  "A recording with graphics: its frames arrive as PNGs and Emacs draws each,
at the size the server reports; the next frame replaces the first.
Needs CODETRACER_CT_GFX_PLAYER_CMD (the visual replay player, licensed in
the environment) and CODETRACER_TEST_GFX_STREAM (a gfx stream), as well as
the variables every scenario needs."
  :tags '(server)
  (unless (image-type-available-p 'png)
    (ert-fail "this Emacs cannot draw PNG images"))
  (codetracer-test--with-server
   (let* ((player (codetracer-test--env "CODETRACER_CT_GFX_PLAYER_CMD"))
          (stream (codetracer-test--env "CODETRACER_TEST_GFX_STREAM"))
          (gfx-trace (make-temp-file "codetracer-gfx" t))
          (codetracer-media '("text" "image")))
     (ignore player)
     (unwind-protect
         (progn
           ;; The recording, given the stream as its graphics.
           (copy-directory trace gfx-trace nil t t)
           (copy-directory stream (expand-file-name "gfx_stream" gfx-trace) nil t t)
           (let ((session (codetracer-open gfx-trace)))
             (codetracer-test--settle)
             (should (eq (plist-get (codetracer-session-graphics session) :available) t))
             (should (codetracer-show-frames))
             (let* ((buffer (gethash "frameViewer" (codetracer-session-panes session)))
                    (deadline (+ (float-time) 60)))
               (while (and (not (codetracer-test--frame-image buffer))
                           (< (float-time) deadline))
                 (accept-process-output nil 0.2))
               (let* ((first (codetracer-test--frame-image buffer))
                      (spec (buffer-local-value 'codetracer--image-spec buffer)))
                 (should first)
                 (should (eq (plist-get (cdr first) :type) 'png))
                 ;; The image Emacs draws is the frame at the reported size.
                 (should (equal (codetracer-test--png-size (plist-get (cdr first) :data))
                                (cons (plist-get spec :width) (plist-get spec :height))))
                 (should (> (plist-get spec :frameCount) 1))
                 (should (eql (plist-get spec :frame) 0))
                 ;; The next frame replaces it.
                 (codetracer--run "frame-viewer.next-frame"
                                  :session (codetracer-session-id session))
                 (let ((deadline (+ (float-time) 60)))
                   (while (and (eql (plist-get (buffer-local-value 'codetracer--image-spec
                                                                   buffer)
                                               :frame)
                                    0)
                               (< (float-time) deadline))
                     (accept-process-output nil 0.2)))
                 (let ((second (codetracer-test--frame-image buffer))
                       (spec (buffer-local-value 'codetracer--image-spec buffer)))
                   (should (eql (plist-get spec :frame) 1))
                   (should second)
                   (should-not (equal (plist-get (cdr second) :data)
                                      (plist-get (cdr first) :data)))
                   (should (equal (codetracer-test--png-size (plist-get (cdr second) :data))
                                  (cons (plist-get spec :width) (plist-get spec :height))))
                   ;; One image in the pane: the previous one is gone.
                   (with-current-buffer buffer
                     (let ((images 0) (pos (point-min)))
                       (while (setq pos (next-single-property-change pos 'display))
                         (when (eq (car-safe (get-text-property pos 'display)) 'image)
                           (cl-incf images)))
                       (should (= images 1)))))))))
       (delete-directory gfx-trace t)))))

;;;; Nim compile-time tracing (tag `nim')

;; Editor-Hosted-Front-Ends §E12: with a Nim project in Edit mode, the
;; context menu's CodeTracer submenu traces the static block at the click,
;; and what the trace records opens as a session of its own, in a tab of
;; its own.  Nothing is mocked: the pane server ($CODETRACER_TUI) over the
;; calc recording ($CODETRACER_TEST_TRACE), started in the project's
;; directory, which is its Edit-mode project; the project is PLAT-65's
;; `tracing.nim', byte for byte (CodeTracer's `plat65_nim_project.nim',
;; `TracingNim'); the trace is codetracer-nim's trace-enabled nimsuggest
;; ($CODETRACER_NIMSUGGEST) and compiler (`nim' on PATH).  Batch Emacs
;; cannot right-click: the click is the event a mouse-3 press delivers,
;; constructed at a buffer position, and the menu is the one
;; `context-menu-mode' builds from it (`context-menu-map').

(defconst codetracer-test--tracing-nim
  "import std/macros

macro twice(body: untyped): untyped =
  result = newStmtList(body, body)

proc compute(n: int): int =
  result = 0
  for i in 1..n:
    result += i * i

const squares = compute(3)

const
  limit = 4
  cubes = compute(limit)

static:
  var acc = 0
  for i in 0..<limit:
    acc += i
  echo \"acc=\", acc

echo \"after\"
let folded = static(compute(5))

twice:
  echo squares
"
  "PLAT-65's tracing.nim: a macro, constants, a static block.")

(defconst codetracer-test--static-line 18
  "A line inside tracing.nim's `static:' block.")

(ert-deftest codetracer-test-nim-buffers ()
  "A Nim buffer is a .nim or .nims file, or one in `nim-mode'."
  :tags '(unit)
  (dolist (case '(("a.nim" . t) ("build.nims" . t) ("a.nimble" . nil)
                  ("a.nim.txt" . nil) (nil . nil)))
    (with-temp-buffer
      (setq buffer-file-name (car case))
      (should (eq (and (codetracer--nim-buffer-p) t) (cdr case)))
      (setq buffer-file-name nil)))
  ;; A buffer, not visiting a file, in a mode derived from nim-mode (the
  ;; package is not loaded: the mode's parentage is what is tested).
  (put 'codetracer-test--nim-mode 'derived-mode-parent 'nim-mode)
  (with-temp-buffer
    (setq major-mode 'codetracer-test--nim-mode)
    (should (codetracer--nim-buffer-p)))
  (with-temp-buffer
    (setq major-mode 'text-mode)
    (should-not (codetracer--nim-buffer-p))))

(defun codetracer-test--check-nim-tracer ()
  "Fail unless codetracer-nim's nimsuggest and compiler are there."
  (let ((nimsuggest (getenv "CODETRACER_NIMSUGGEST")))
    (unless (and nimsuggest (file-executable-p nimsuggest))
      (ert-fail "CODETRACER_NIMSUGGEST is not codetracer-nim's nimsuggest: the Nim suite traces with it"))
    (unless (executable-find "nim")
      (ert-fail "nim is not on PATH: the Nim suite traces with codetracer-nim's compiler"))))

(defun codetracer-test--right-click (window pos)
  "The mouse-3 press event a right click in WINDOW at buffer position POS gives."
  (list 'down-mouse-3
        (list window pos '(0 . 0) 0 nil pos '(0 . 0) nil '(0 . 0) '(0 . 0))))

(defun codetracer-test--menu-binding (map key)
  "The command or keymap MAP binds KEY (a symbol) to, a menu item's included."
  (let ((binding (lookup-key map (vector key))))
    (if (eq (car-safe binding) 'menu-item) (nth 2 binding) binding)))

(defun codetracer-test--line-pos (buffer line column)
  "BUFFER's position at 1-based LINE and 0-based COLUMN."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (forward-line (1- line))
      (move-to-column column)
      (point))))

(ert-deftest codetracer-test-nim-static-block-traced-from-the-context-menu ()
  "The context menu traces a Nim static block; its recording opens in a tab.
The menu is offered in a Nim buffer only; the session it was traced from
stays in Edit mode."
  :tags '(nim)
  (codetracer-test--check-nim-tracer)
  (let ((project (file-name-as-directory (make-temp-file "codetracer-el-nim" t))))
    (with-temp-file (expand-file-name "tracing.nim" project)
      (set-buffer-file-coding-system 'utf-8-unix)
      (insert codetracer-test--tracing-nim))
    (unwind-protect
        (codetracer-test--with-server
          (let* ((session (let ((default-directory project)) (codetracer-open trace)))
                 (id (codetracer-session-id session)))
            (codetracer-test--settle)
            (codetracer--run "session.toggle-product-mode" :session id)
            (codetracer-test--wait-for
             (lambda () (equal (codetracer-session-mode session) "edit")) 30 "Edit mode")
            (should (memq #'codetracer-context-menu (default-value 'context-menu-functions)))
            (select-window (codetracer--source-window session))
            (let* ((buffer (find-file (expand-file-name "tracing.nim" project)))
                   (window (get-buffer-window buffer))
                   (click (codetracer-test--right-click
                           window (codetracer-test--line-pos
                                   buffer codetracer-test--static-line 4)))
                   (menu (context-menu-map click))
                   (submenu (codetracer-test--menu-binding menu 'codetracer))
                   (known (codetracer-test--session-ids))
                   (tabs (length (tab-bar-tabs))))
              (should (keymapp submenu))
              (should (equal (cl-loop for (_label . command) in codetracer--nim-trace-items
                                      when (codetracer-test--menu-binding submenu command)
                                      collect command)
                             (mapcar #'cdr codetracer--nim-trace-items)))
              ;; Point is elsewhere: the item acts at the click.
              (with-current-buffer buffer (goto-char (point-min)))
              (set-window-point window (with-current-buffer buffer (point-min)))
              (funcall (codetracer-test--menu-binding
                        submenu 'codetracer-trace-static-block-at-point))
              (should (eq (selected-window) window))
              (should (= (line-number-at-pos (window-point window)) codetracer-test--static-line))
              (should (equal codetracer--cursor-sent
                             (list (expand-file-name "tracing.nim" project)
                                   codetracer-test--static-line 5)))
              (let ((opened (codetracer-test--wait-new-session known "the trace's recording" 300)))
                (should (file-directory-p (codetracer-session-trace opened)))
                (should (= (length (tab-bar-tabs)) (1+ tabs)))
                (should (eq (codetracer--current-tab-session) opened))
                (should-not (equal (codetracer-session-tab opened) (codetracer-session-tab session)))
                ;; The session it was traced from is still in Edit mode.
                (should (cl-find-if (lambda (s) (and (eql (plist-get s :session) id)
                                                     (equal (plist-get s :mode) "edit")))
                                    (codetracer--request :session/list))))
              ;; Outside a Nim buffer the menu offers nothing of CodeTracer's.
              (let ((other (find-file (expand-file-name "notes.txt" project))))
                (should-not (codetracer-test--menu-binding
                             (context-menu-map
                              (codetracer-test--right-click (get-buffer-window other) 1))
                             'codetracer))
                (set-buffer-modified-p nil)))))
      (dolist (b (buffer-list))
        (when (and (buffer-file-name b) (string-prefix-p project (buffer-file-name b)))
          (with-current-buffer b (set-buffer-modified-p nil))
          (kill-buffer b)))
      (delete-directory project t))))

;;;; The generated C of a Nim line, over a native recording

(ert-deftest codetracer-test-native-generated-c-of-a-nim-line ()
  "The C a Nim line compiled to is shown in the Low Level Code pane.
The recording is CodeTracer's native Nim example, which bundles its
generated C; the layout has no Low Level Code pane, so the server places
one beside the source and the package opens its window.  The Nim buffer's
context menu offers the command."
  :tags '(native)
  (codetracer-test--env "CODETRACER_CT_NATIVE_REPLAY_CMD")
  (codetracer-test--with-server
    (let* ((native (codetracer-test--env "CODETRACER_TEST_NATIVE_NIM_TRACE"))
           (session (codetracer-open native)))
      (codetracer-test--wait-for
       (lambda ()
         (let ((file (plist-get (codetracer-session-position session) :file)))
           (and (stringp file) (string-match-p "nim_flow_test\\.nim\\'" file))))
       120 "the stop in nim_flow_test.nim")
      (codetracer-test--settle)
      (should-not (codetracer-test--pane-window session "lowLevelCode"))
      (let ((window (codetracer--source-window session)))
        (should (window-live-p window))
        (select-window window)
        (with-current-buffer (window-buffer window)
          (should (codetracer--nim-buffer-p))
          ;; Point on the stop's line, where the user asks about its C.
          (goto-char (point-min))
          (forward-line (1- (plist-get (codetracer-session-position session) :line)))
          (let ((submenu (codetracer-test--menu-binding
                          (context-menu-map
                           (codetracer-test--right-click window (window-point window)))
                          'codetracer)))
            (should (keymapp submenu))
            (should (codetracer-test--menu-binding submenu 'codetracer-view-generated-c))
            (should (codetracer-test--menu-binding submenu 'codetracer-view-disassembly)))
          (should (eq (plist-get (codetracer-view-generated-c) :ok) t))))
      (codetracer-test--wait-for
       (lambda () (codetracer-test--pane-window session "lowLevelCode"))
       60 "the Low Level Code window the layout now places")
      ;; The C of the stop's line is in view: the directive naming it, not
      ;; the `#define's at the top of the file.
      (let ((directive (format "#line %d " (plist-get (codetracer-session-position session)
                                                      :line)))
            (pane (gethash "lowLevelCode" (codetracer-session-panes session))))
        (condition-case nil
            (codetracer-test--wait-for
             (lambda ()
               (with-current-buffer pane
                 (save-excursion
                   (goto-char (point-min))
                   (search-forward directive nil t))))
             60 directive)
          (ert-test-failed
           (ert-fail (format "the pane does not show %S; it shows:\n%s" directive
                             (with-current-buffer pane (buffer-string))))))))))

;;;; A project folder in Edit mode, and its generated C (HSF-E11)

(defconst codetracer-test--zebra-line 42
  "The line of `codetracer-test--zebra-nim' whose C the test asks for.")

(defun codetracer-test--zebra-nim ()
  "A Nim file whose line 42 is far below the top of its C."
  (concat (mapconcat (lambda (i) (format "proc filler%d(): int = %d\n" i i))
                     (number-sequence 1 40) "")
          "proc triple(n: int): int =\n"
          "  let zebraCount = n * 3\n"
          "  result = zebraCount + 1\n"
          "\n"
          "echo triple(14)\n"))

(ert-deftest codetracer-test-native-project-generated-c-in-edit-mode ()
  "A folder with no recording opens in Edit mode, and shows a line's C.
`codetracer-open' sends the folder as a project (Editor-Hosted-Front-Ends
E9); `codetracer-view-generated-c' there compiles the saved file with the
real `nim' on PATH, and the pane shows the C of the line at point -- far
below the file's top, so shown means scrolled to.  A press on that C puts
point back on the line."
  :tags '(native)
  (unless (executable-find "nim")
    (ert-fail "the edit-mode generated-C case needs `nim' on PATH"))
  (let ((project (file-name-as-directory (make-temp-file "codetracer-el-e11" t))))
    (with-temp-file (expand-file-name "tiny.nim" project)
      (insert (codetracer-test--zebra-nim)))
    (unwind-protect
        (codetracer-test--with-server
          (let ((session (codetracer-open project)))
            (should (equal (codetracer-session-mode session) "edit"))
            (should (cl-find-if (lambda (s) (and (eql (plist-get s :session)
                                                      (codetracer-session-id session))
                                                 (equal (plist-get s :project)
                                                        (directory-file-name project))))
                                (codetracer--request :session/list)))
            (codetracer-test--settle)
            (select-window (codetracer--source-window session))
            (let ((buffer (find-file (expand-file-name "tiny.nim" project))))
              (with-current-buffer buffer
                (goto-char (point-min))
                (forward-line (1- codetracer-test--zebra-line))
                (forward-char 2)
                (should (eq (plist-get (codetracer-view-generated-c) :ok) t))))
            (codetracer-test--wait-for
             (lambda () (codetracer-test--pane-window session "lowLevelCode"))
             60 "the Low Level Code window the layout now places")
            (let ((pane (gethash "lowLevelCode" (codetracer-session-panes session))))
              (condition-case nil
                  (codetracer-test--wait-for
                   (lambda ()
                     (with-current-buffer pane
                       (save-excursion
                         (goto-char (point-min))
                         (search-forward "zebraCount" nil t))))
                   120 "the compiled C of the line at point")
                (ert-test-failed
                 (ert-fail (format "the pane does not show the line's C; it shows:\n%s"
                                   (with-current-buffer pane (buffer-string))))))
              ;; A press on the line's C puts point on its Nim line
              ;; (`source/show' carries the position, Editor-Hosted E7).
              ;; Point is elsewhere first, so the move is the press's.
              (let ((source (codetracer--source-window session)))
                (with-current-buffer (window-buffer source) (goto-char (point-min)))
                (set-window-point source 1)
                (with-current-buffer pane
                  (goto-char (point-min))
                  (should (search-forward (format "nimlf_(%d" codetracer-test--zebra-line) nil t))
                  (beginning-of-line)
                  (let ((match (text-property-search-forward
                                'codetracer-hotspot nil
                                (lambda (_ v) (and v (equal (car v) "low-level.go-to-source-line"))))))
                    (should match)
                    (goto-char (prop-match-beginning match))
                    (codetracer-activate-hotspot)))
                (codetracer-test--wait-for
                 (lambda ()
                   (with-current-buffer (window-buffer source)
                     (= (line-number-at-pos (window-point source))
                        codetracer-test--zebra-line)))
                 15 "point on the Nim line the C came from")
                (should (string-suffix-p "tiny.nim"
                                         (buffer-file-name (window-buffer source))))))))
      (dolist (b (buffer-list))
        (when (and (buffer-file-name b) (string-prefix-p project (buffer-file-name b)))
          (with-current-buffer b (set-buffer-modified-p nil))
          (kill-buffer b)))
      (delete-directory project t))))

(provide 'codetracer-test)
;;; codetracer-test.el ends here
