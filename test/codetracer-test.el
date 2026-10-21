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
          (second (codetracer-open trace)))
     (codetracer-test--settle)
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
