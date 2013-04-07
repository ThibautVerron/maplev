;;; maplev-proc.el --- mode for displaying Maple procedures

;;; Commentary:
;; 

;;; Code:
;;

(require 'comint)

(eval-when-compile
  (defvar maplev--builtin-functions-alist)
  (defvar maplev--process-item)
  (defvar maplev-cmaple-echoes-flag)
  (defvar maplev-default-release)
  (defvar maplev-help-mode-map)
  (defvar maplev-release))

(declare-function event-point "maplev-common")
(declare-function event-window "maplev-common")
(declare-function maplev--cleanup-buffer "maplev-cmaple")
(declare-function maplev--cmaple-process "maplev-cmaple")
(declare-function maplev-history--stack-process "maplev-history")
(declare-function maplev--ident-around-point "maplev-common")
(declare-function maplev--major-release "maplev-common")
(declare-function maplev-cmaple--lock-access "maplev-cmaple")
(declare-function maplev-cmaple--ready "maplev-cmaple")
(declare-function maplev-cmaple--send-end-notice "maplev-cmaple")
(declare-function maplev-history-clear "maplev-history")
(declare-function maplev-ident-around-point-interactive "maplev-common")
(declare-function maplev-indent-buffer "maplev-indent")
(declare-function maplev-reset-font-lock "maplev")
(declare-function maplev-set-release "maplev-common")


;;{{{ mode map

;; The mode map for maplev-proc-map is identical to that for
;; maplev-help-mode, with one exception: the parent function is not
;; needed, so its key is redefined to self-insert (which generates an
;; error, as does any other insertion, because the buffer if
;; read-only).

(defvar maplev-proc-mode-map nil
  "Keymap used in `maplev-proc-mode'.")

(unless maplev-proc-mode-map
  (let ((map (copy-keymap maplev-help-mode-map)))
    (define-key map [?P] 'self-insert-command)
    (setq maplev-proc-mode-map map)))

;;}}}
;;{{{ mode definition

(defun maplev-proc-mode (&optional release)
  "Major mode for displaying the source code of Maple procedures.
RELEASE is the Maple release, if nil, `maplev-default-release' is used.

\\{maplev-proc-mode-map}"
  (interactive)
  (kill-all-local-variables)

  (setq major-mode 'maplev-proc-mode) ;; needed by maplev-set-release
  (maplev-set-release release)
  (setq mode-name (format "Maple-Proc %s" maplev-release))
  (use-local-map maplev-proc-mode-map)

  (set (make-local-variable 'maplev--process-item)
       (function maplev--proc-process))

  (make-local-variable 'maplev-history--stack) ; set up the stack
  (maplev-history-clear)

  ;; Mint support
  (make-local-variable 'maplev-mint--code-beginning)
  (make-local-variable 'maplev-mint--code-end)

  ;; font-lock support
  (make-local-variable 'font-lock-defaults)
  (make-local-variable 'font-lock-maximum-decoration)
  (maplev-reset-font-lock)

  (setq buffer-read-only t)
  (run-hooks 'maplev-proc-mode-hook))

;;}}}
;;{{{ functions


(defun maplev--proc-buffer ()
  "Return the name of the Maple procedure listing buffer."
  (format "Maple %s proc" maplev-release))


;;; Define functions for displaying a Maple procedure from the Maple
;;; library in a buffer.

(defun maplev-proc-follow-mouse (click)
  "Display the Maple procedure at the mouse CLICK."
  (interactive "e")
  (set-buffer (window-buffer (event-window click)))
  (goto-char (event-point click))
  (maplev--proc-show-topic (maplev--ident-around-point)))

(defun maplev-proc-at-point (proc)
  "Display the Maple procedure PROC.
Request procedure name in minibuffer, using identifier at point as default."
  (interactive (list (maplev-ident-around-point-interactive
                      "Maple procedure" nil t)))
  (maplev--proc-show-topic proc))

(defun maplev--proc-show-topic (proc &optional hide)
  "Display the Maple procedure PROC \(a string\).
Push PROC onto the local stack, unless it is already on the top.
If optional arg HIDE is non-nil do not display buffer."
  ;; Do not try to display builtin procedures.
  (if (assoc proc (mapcar 'list
                          (cdr (assoc (maplev--major-release)
                                      maplev--builtin-functions-alist))))
      (message "Procedure \`%s\' builtin." proc)
    (save-current-buffer
      (let ((release maplev-release)) ;; we switch buffers!
        (set-buffer (get-buffer-create (maplev--proc-buffer)))
        (unless (eq major-mode 'maplev-proc-mode)
          (maplev-proc-mode release))
        (maplev-history--stack-process proc hide)))))

(defun maplev--proc-process (proc)
  "Display the Maple procedure PROC \(a string\) in `maplev--proc-buffer'."
  (let ((process (maplev--cmaple-process)))
    (maplev-cmaple--lock-access)
    (set-process-filter process 'maplev-proc-filter)
    (set-buffer (maplev--proc-buffer))
    (setq mode-line-buffer-identification (format "%-12s" proc))
    (let (buffer-read-only)
      (delete-region (point-min) (point-max))
      (goto-char (point-min))
      ;;(insert proc " := ")
      )
    (comint-simple-send process (concat "maplev_print(\"" proc "\");"))
    (maplev-cmaple--send-end-notice process)))

(defun maplev-proc-filter (process string)
  "Pipe a Maple procedure listing into `maplev--proc-buffer'.
PROCESS calls this filter.  STRING is the Maple procedure."
  (with-current-buffer (maplev--proc-buffer)
    (save-excursion
      (let (buffer-read-only)
        (save-restriction
          (goto-char (point-max))
          (narrow-to-region (point) (point))
          (insert string)
          (maplev--cleanup-buffer))
        (goto-char (point-max))
        (if (maplev-cmaple--ready process)
            (maplev-proc-cleanup-buffer))))))

(defun maplev-proc-cleanup-buffer ()
  "Cleanup Maple procedure listings."
  (save-excursion
    (when maplev-cmaple-echoes-flag
      (goto-char (point-min))
      (if (re-search-forward "maplev_print(.+);\n" nil t)
          (delete-region (match-beginning 0) (match-end 0))))
    ;; Delete multiple spaces.
    (goto-char (point-min))
    (while (re-search-forward "[ \t][ \t]+" nil t)
      (replace-match " "))
    ;; terminate with `;'
    (goto-char (point-max))
    (skip-chars-backward " \t\n")
;;    (insert ";")
    )
  (maplev-indent-buffer)
  (set-buffer-modified-p nil)
  (font-lock-fontify-buffer))

;;}}}

(provide 'maplev-proc)

;;; maplev-proc.el ends here