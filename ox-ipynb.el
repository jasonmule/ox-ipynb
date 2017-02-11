;;; ox-ipynb.el --- Convert an org-file to an ipynb.  -*- lexical-binding: t; -*-

;;; Commentary:
;; 

;;; Code:
(require 'ox-md)
(require 'ox-org)

(defun export-ipynb-code-cell (src-result)
  "Return a lisp code cell for the org-element SRC-BLOCK."
  (let* ((src-block (car src-result))
	 (results-end (cdr src-result))
	 (results (org-no-properties (car results-end)))
	 (output-cells '())
	 img-path img-data
	 (start 0)
	 end
	 block-start block-end
	 html
	 latex)

    ;; Handle inline images first
    (while (string-match "\\[\\[file:\\(.*?\\)\\]\\]" (or results "") start)
      (setq start (match-end 0))
      (setq img-path (match-string 1 results) 
	    img-data (base64-encode-string
		      (encode-coding-string
		       (with-temp-buffer
			 (insert-file-contents img-path)
			 (buffer-string))
		       'binary)
		      t))
      (add-to-list 'output-cells `((data . ((image/png . ,img-data)
					    ("text/plain" . "<matplotlib.figure.Figure>")))
				   (metadata . ,(make-hash-table))
				   (output_type . "display_data"))
		   t))
    ;; now remove the inline images and put the results in.
    (setq results (s-trim (replace-regexp-in-string "\\[\\[file:\\(.*?\\)\\]\\]" ""
						    (or results ""))))
    
    ;; Check for HTML cells. I think there can only be one I don't know what the
    ;; problem is, but I can't get the match-end functions to work correctly
    ;; here. Its like the match-data is not getting updated.
    (when (string-match "#\\+BEGIN_EXPORT HTML" (or results ""))
      (setq block-start (s-index-of "#+BEGIN_EXPORT HTML" results)
	    start (+ block-start (length "#+BEGIN_EXPORT HTML\n")))
      
      ;; Now, get the end of the block. 
      (setq end (s-index-of "#+END_EXPORT" results)
	    block-end (+ end (length "#+END_EXPORT")))
      
      (setq html (substring results start end))
      
      ;; remove the old output.
      (setq results (concat (substring results 0 block-start)
			    (substring results block-end)))
      (message "html: %s\nresults: %s" html results)
      (add-to-list 'output-cells `((data . ((text/html . ,html)
					    ("text/plain" . "HTML object")))
				   (metadata . ,(make-hash-table))
				   (output_type . "display_data"))
		   t))

    ;; Handle latex cells
    (when (string-match "#\\+BEGIN_EXPORT latex" (or results ""))
      (setq block-start (s-index-of "#+BEGIN_EXPORT latex" results)
	    start (+ block-start (length "#+BEGIN_EXPORT latex\n")))
      
      ;; Now, get the end of the block. 
      (setq end (s-index-of "#+END_EXPORT" results)
	    block-end (+ end (length "#+END_EXPORT")))
      
      (setq latex (substring results start end))
      
      ;; remove the old output.
      (setq results (concat (substring results 0 block-start)
			    (substring results block-end)))
      
      (add-to-list 'output-cells `((data . ((text/latex . ,latex)
					    ("text/plain" . "Latex object")))
				   (metadata . ,(make-hash-table))
				   (output_type . "display_data"))
		   t))
    

    ;; Check for Latex cells
    
    (setq output-cells (append `(((name . "stdout")
				  (output_type . "stream")
				  (text . ,results)))
			       output-cells))
    
    
    `((cell_type . "code")
      (execution_count . 1)
      ;; the hashtable trick converts to {} in json. jupyter can't take a null here.
      (metadata . ,(make-hash-table)) 
      (outputs . ,(if (null output-cells)
		      ;; (vector) json-encodes to  [], not null which
		      ;; jupyter does not like.
		      (vector)
		    (vconcat output-cells)))
      (source . ,(vconcat
		  (list (s-trim (org-element-property :value src-block))))))))


(defun ox-ipynb-filter-latex-fragment (text back-end info)
  "Export fragments the right way for markdown.
They usually come as \(fragment\) and they need to be $fragment$
in the notebook."
  (replace-regexp-in-string "\\\\(\\|\\\\)" "$" text))


(defun ox-ipynb-filter-link (text back-end info)
  "Make a link into markdown.
For some reason I was getting angle brackets in them I wanted to remove.
This only fixes file links with no description I think."
  (if (s-starts-with? "<" text)
      (let ((path (substring text 1 -1)))
	(format "[%s](%s)" path path))
    text))


(defun export-ipynb-markdown-cell (beg end)
  "Return the markdown cell for the region defined by BEG and END."
  (let* ((org-export-filter-latex-fragment-functions '(ox-ipynb-filter-latex-fragment))
	 (org-export-filter-link-functions '(ox-ipynb-filter-link))
	 (org-export-filter-keyword-functions '(ox-ipynb-keyword-link)) 
	 (md (org-export-string-as
	      (buffer-substring-no-properties
	       beg end)
	      'md t '(:with-toc nil :with-tags nil))))

    `((cell_type . "markdown")
      (metadata . ,(make-hash-table))
      (source . ,(vconcat
		  (list md))))))

(defun export-ipynb-keyword-cell ()
  "Make a markdown cell containing org-file keywords."
  (let* ((keywords (org-element-map (org-element-parse-buffer)
		       'keyword
		     (lambda (key)
		       (cons (org-element-property :key key)
			     (org-element-property :value key))))))
    (loop for key in '("RESULTS" "OPTIONS" "LATEX_HEADER" "ATTR_ORG")
	  do 
	  (setq keywords (-remove (lambda (cell) (string= (car cell) key)) keywords)))

    (setq keywords
	  (loop for (key . value) in keywords
		collect
		(format "- %s: %s\n"
			key
			(replace-regexp-in-string
			 "<\\|>" ""
			 value))))
    (when keywords
      `((cell_type . "markdown")
	(metadata . ,(make-hash-table))
	(source . ,(vconcat keywords))))))

(defun ox-ipynb-export-to-buffer ()
  "Export the current buffer to ipynb format in a buffer.
Only ipython source blocks are exported as code cells. Everything
else is exported as a markdown cell. The output is in *ox-ipynb*."
  (interactive)
  (let ((cells (if (export-ipynb-keyword-cell) (list (export-ipynb-keyword-cell)) '()))
	(metadata `(metadata . ((org . ,(org-element-map (org-element-parse-buffer)
					    'keyword
					  (lambda (key)
					    (cons (org-element-property :key key)
						  (org-element-property :value key)))))
				(kernelspec . ((display_name . "Python 3")
					       (language . "python")
					       (name . "python3")))
				(language_info . ((codemirror_mode . ((name . ipython)
								      (version . 3)))
						  (file_extension . ".py")
						  (mimetype . "text/x-python")
						  (name . "python")
						  (nbconvert_exporter . "python")
						  (pygments_lexer . "ipython3")
						  (version . "3.5.2"))))))
	(ipynb (or (and (boundp 'export-file-name) export-file-name)
		   (concat (file-name-base (buffer-file-name)) ".ipynb")))
	src-blocks
	src-results
	current-src
	result
	result-end
	end
	data)

    (setq src-blocks (org-element-map (org-element-parse-buffer) 'src-block
		       (lambda (src)
			 (when (string= "ipython" (org-element-property :language src))
			   src))))

    ;; Get a list of (src . results)
    (setq src-results
	  (loop for src in src-blocks
		with result=nil
		do
		(setq result
		      (save-excursion
			(goto-char (org-element-property :begin src))
			(let ((location (org-babel-where-is-src-block-result nil nil))
			      start end
			      result-content)
			  (when location
			    (save-excursion
			      (goto-char location)
			      (when (looking-at
				     (concat org-babel-result-regexp ".*$")) 
				(setq start (1- (match-beginning 0))
				      end (progn (forward-line 1) (org-babel-result-end))
				      result-content (buffer-substring-no-properties start end))
				;; clean up the results a little. This gets rid
				;; of the RESULTS markers for output and drawers
				(loop for pat in '("#\\+RESULTS:" "^: " "^:RESULTS:\\|^:END:")
				      do
				      (setq result-content (replace-regexp-in-string
							    pat
							    ""
							    result-content)))
				;; the results and the end of the results.
				;; we use the end later to move point.
				(cons (s-trim result-content) end))))))) 
		collect
		(cons src result)))
    
    (setq current-source (pop src-results))

    ;; First block before a src is markdown
    (if (car current-source)
	(unless (string= "" (s-trim
			     (buffer-substring-no-properties
			      (point-min)
			      (org-element-property :begin (car current-source)))))
	  (push (export-ipynb-markdown-cell
		 (point-min) (org-element-property :begin (car current-source)))
		cells))
      (push (export-ipynb-markdown-cell
	     (point-min) (point-max))
	    cells))
    
    (while current-source
      ;; add the src cell
      (push (export-ipynb-code-cell current-source) cells)
      (setq result-end (cdr current-source)
	    result (car result-end)
	    result-end (cdr result-end))
      
      (setq end (max
		 (or result-end 0)
		 (org-element-property :end (car current-source))))
      
      (setq current-source (pop src-results))
      
      (if current-source
	  (when (not (string= "" (s-trim (buffer-substring
					  end
					  (org-element-property :begin
								(car current-source))))))
	    (push (export-ipynb-markdown-cell 
		   end
		   (org-element-property :begin
					 (car current-source)))
		  cells))
	;; on last block so add rest of document
	(push (export-ipynb-markdown-cell end (point-max)) cells)))

    (setq data (append
		`((cells . ,(reverse cells)))
		(list metadata)
		'((nbformat . 4)
		  (nbformat_minor . 0))))

    (with-current-buffer (get-buffer-create "*ox-ipynb*")
      (erase-buffer)
      (insert (json-encode data)))

    (switch-to-buffer "*ox-ipynb*")
    (setq-local export-file-name ipynb)
    (get-buffer "*ox-ipynb*")))


(defun ox-ipynb-export-to-file ()
  "Export current buffer to an ipynb file."
  (interactive)
  (with-current-buffer (ox-ipynb-export-to-buffer)
    (write-file export-file-name))
  export-file-name)


(defun ox-ipynb-export-to-file-and-open ()
  "Export the current buffer to a notebook and open it."
  (interactive)
  (async-shell-command (format "jupyter notebook %s" (ox-ipynb-export-to-file))))


(defun nbopen (fname)
  "Open fname in jupyter notebook."
  (interactive  (list (read-file-name "Notebook: ")))
  (shell-command (format "nbopen %s&" fname)))


;; * export menu
(defun ox-ipynb-export-to-ipynb-buffer (async subtreep visible-only body-only &optional info) 
  (let ((ipynb (concat (file-name-base (buffer-file-name)) ".ipynb")))
    (org-org-export-as-org async subtreep visible-only body-only info)
    (with-current-buffer "*Org ORG Export*"
      (setq-local export-file-name ipynb)
      (ox-ipynb-export-to-buffer))))


(defun ox-ipynb-export-to-ipynb-file (async subtreep visible-only body-only &optional info) 
  (let ((ipynb (concat (file-name-base (buffer-file-name)) ".ipynb")))
    (org-org-export-as-org async subtreep visible-only body-only info)
    (with-current-buffer "*Org ORG Export*"
      (setq-local export-file-name ipynb)
      (ox-ipynb-export-to-file))))


(defun ox-ipynb-export-to-ipynb-file-and-open (async subtreep visible-only body-only &optional info) 
  (let ((ipynb (concat (file-name-base (buffer-file-name)) ".ipynb")))
    (org-org-export-as-org async subtreep visible-only body-only info)
    (with-current-buffer "*Org ORG Export*"
      (setq-local export-file-name ipynb)
      (ox-ipynb-export-to-file-and-open))))


(org-export-define-derived-backend 'jupyter-notebook 'org
  :menu-entry
  '(?n "Export to jupyter notebook"
       ((?b "to buffer" ox-ipynb-export-to-buffer)
	(?n "to notebook" ox-ipynb-export-to-ipynb-file)
	(?o "to notebook and open" ox-ipynb-export-to-ipynb-file-and-open))))


(provide 'ox-ipynb)

;;; ox-ipynb.el ends here
