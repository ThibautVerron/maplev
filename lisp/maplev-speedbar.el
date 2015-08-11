;;; maplev-speedbar.el --- Speedbar for maplev

;;; Purpose:
;;
;; Provide a speedbar extension for Maple source code.  The speedbar
;; lists the procedures and modules in the file.  The display is
;; hierarchical, that is, a module can contain modules and procedures.
;;
;; Usage:
;;
;; Add the following to .emacs
;;
;;  (add-hook 'maplev-mode-hook
;;	  (lambda ()
;;	    (require 'maplev-speedbar)))

;;; Code:

(require 'speedbar)
(require 'maplev-re)

;; Attach new functions to handle maplev-mode.
(add-to-list 'speedbar-dynamic-tags-function-list
	     '(maplev-sb-fetch-dynamic-tags . maplev-sb-insert-tags-list))

(speedbar-add-supported-extension '(".mpl" ".mm"))

(defconst maplev-sb-keyword-re
  "\\_<\\(module\\|proc\\|do\\|end\\|fi\\|if\\|od\\|try\\|use\\)\\_>"
  "Regular expression that matches Maple keywords. Keyword is in group 1.")

(defconst maplev-sb-assign-re
  (concat "^\\s-*"
	  "\\(?:\\(?:export\\|local\\)\\s-+\\)?"
	  "\\(" maplev--name-re "\\)"
	  "\\(?:\\s-*::\\s-*static\\s-\\)?"
	  "\\s-*:=\\s-*")
  "Regular expression that matches Maple assignment. Name is in group 1.")

(defvar maplev-sb-stack nil
  "Stack used by `maplev-sb-fetch-dynamic-tags' and `maplev-sb-get-hier'.
Each element is either the symbol 'end, or a cons-cell, (id . tag), 
where id is the identifier of a module or procedure and
tag is the point in the text where it begins.")

(defun maplev-sb-insert-tags-list (level lst)
  "At LEVEL level, insert LST, a generic multi-level alist.
See `speedbar-insert-generic-list'."
  (speedbar-insert-generic-list level lst
				'speedbar-tag-expand
				'speedbar-tag-find))

(defvar maplev-markers nil
  "Buffer local list of markers used to mark modules and procedures.
Generated by `maplev-sb-mark-defuns.")

(make-variable-buffer-local 'maplev-markers)

(defun maplev-sb-fetch-dynamic-tags (filename)
  "Return a multi-level alist for the Maple source file FILENAME.
The created alist is passed to `speedbar-insert-generic-list' via
`maplev-sb-insert-tags-list'. If a parsing error occurs, or the
major-mode associated with FILENAME is not `maplev-mode' return
t. The returned alist has the following grammar:

  alist ::= (item*)
  item  ::= term | hier
  term  ::= (id . tag)
  hier  ::= (id tag item+)

See Info node `(speedbar)Creating a display'."
  (set-buffer (find-file-noselect filename))
  ;; verify buffer has appropriate mode
  (if (not (or (eq major-mode 'maplev-mode)
	       (eq major-mode 'mpldoc-mode)))
      t
    (setq maplev-sb-stack (maplev-sb-mark-defuns))
    (maplev-sb-make-alist)))

(defun maplev-sb-mark-defuns ()
  "Add markers to modules and procedures in the current buffer,
update the buffer-local variable `maplev-markers', and return a
list of the ..."

  ;; null existing markers
  (while maplev-markers
    (set-marker (pop maplev-markers) nil))

  (save-excursion
    ;; Set `speedbar-tag-hierarchy-method' to nil so that 
    ;; `speedbar-create-tag-hierarchy' won't reorder the list.
    ;; Make it buffer local so that the global value is not touched.
    (set (make-local-variable 'speedbar-tag-hierarchy-method) nil)
    (set (make-local-variable 'speedbar-generic-list-group-expand-button-type) 'expandtag)
    (set (make-local-variable 'speedbar-generic-list-tag-button-type) 'statictag)
    
    (setq case-fold-search nil) ; use case-sensitive searches/matching
    (goto-char (point-min))     ; start at top of buffer
    (let ((point (point))
	  (skip 0) 	; number of ends to skip over
	  marker        ; marker used to point to start of keyword
	  stack         ; stack
	  state    	; parse-state
	  id)      	; proc/module identifier
      ;; create stack of (id . marker) or 'end
      (while (re-search-forward maplev-sb-keyword-re nil 'noerror)
	(setq state (parse-partial-sexp point (point) nil nil state)
	      point (point))
	(unless (or (nth 3 state) (nth 4 state)) ; skip comments and strings
	  (let ((keyword (match-string-no-properties 1))
		(beg (match-beginning 0))
		(end (match-end 0)))
	    (cond
	     ((or (when (string= keyword "end")
		    ;; skip optional part
		    (if (looking-at "\\s-+\\w+") 
			(goto-char (match-end 0)))
		    t)
		  (string= keyword "fi")
		  (string= keyword "od"))
	      ;; handle end-statement
	      (if (zerop skip)
		  (setq stack (cons 'end stack))
		(setq skip (1- skip))))
	     ((not (zerop skip))
	      ;; already skipping; increment skip
	      (setq skip (1+ skip)))
	     ((string= keyword "module")
	      (setq id (if (looking-at (concat "\\s-*\\(" maplev--symbol-re "\\)"))
			   ;; module ID()
			   (match-string-no-properties 1)
			 ;; ID := module()
			 (save-excursion
			   (beginning-of-line)
			   (if (looking-at maplev-sb-assign-re)
			       (match-string-no-properties 1)
			     "Anonymous Module"))))
	      (setq marker (set-marker (make-marker) beg))
	      (push marker maplev-markers)
	      (push (cons id marker) stack))
	     ((string= keyword "proc")
	      ;; ID := proc()
	      (save-excursion
		(beginning-of-line)
		(if (not (looking-at maplev-sb-assign-re))
		    ;; skip anonymous procedures
		    (setq skip (1+ skip))
		  (setq id (match-string-no-properties 1))
		  (setq marker (set-marker (make-marker) beg))
		  (push marker maplev-markers)
		  (push (cons id marker) stack))))
	     (t 
	      (setq skip (1+ skip)))))))
      stack)))

(defun maplev-sb-make-alist ()
  "Convert `maplev-sb-stack' to a multi-level alist."
  (let ((cont t) elem lst)
    (while (and cont maplev-sb-stack)
      (setq elem (pop maplev-sb-stack)
	    lst (if (eq elem 'end)
		    (if (eq (car maplev-sb-stack) 'end)
			(cons (maplev-sb-make-alist) lst)
		      (cons (pop maplev-sb-stack) lst))
		  (setq cont nil)
		  (cons (car elem) (cons (cdr elem) lst)))))
    lst))

(provide 'maplev-speedbar)

;;; maplev-speedbar.el ends here
