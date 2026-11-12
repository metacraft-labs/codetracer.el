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

;; What the user is shown of an `operation/run' answer.  The function is
;; called with answers in the protocol's shape; the server's own refusals
;; (error answers) are exercised against the real server below.  `ok: false'
;; is part of the result's contract but no operation of the server answers it
;; today, so this is the only place that branch can be checked.
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
  (get-buffer-window (gethash pane (codetracer-session-panes session))))

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

(provide 'codetracer-test)
;;; codetracer-test.el ends here
