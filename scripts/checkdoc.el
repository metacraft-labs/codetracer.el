;;; checkdoc.el --- Run checkdoc on the package, failing on any finding  -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: Apache-2.0

;;; Commentary:

;; `just lint-elisp': `checkdoc' prints its findings and exits non-zero when
;; there is one, so a documentation defect fails the lint like a compile
;; warning fails the build.

;;; Code:

(require 'checkdoc)

(defvar codetracer-checkdoc--findings 0
  "How many findings checkdoc reported.")

(let ((checkdoc-autofix-flag 'never)
      (checkdoc-arguments-in-order-flag nil)
      (checkdoc-create-error-function
       (lambda (text start _end &optional _unfixable)
         (setq codetracer-checkdoc--findings (1+ codetracer-checkdoc--findings))
         (princ (format "codetracer.el:%d: %s\n" (line-number-at-pos start) text))
         nil)))
  (with-current-buffer (find-file-noselect "codetracer.el")
    (checkdoc-current-buffer t)))

(kill-emacs (if (> codetracer-checkdoc--findings 0) 1 0))

;;; checkdoc.el ends here
