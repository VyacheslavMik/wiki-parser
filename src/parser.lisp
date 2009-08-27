;;; parser.lisp

(in-package :wiki-parser)


(defun symbols-category-hash (symbol)
  (symbol-value (find-symbol  "*SYMBOLS-CATEGORY*" (symbol-package symbol))))

;; (defun modes-by-category (mode category)
;;   (iter (for (mode mode-category) in-hashtable *symbols-category*)
;;         (when (eql mode-category category)
;;           (collect mode))))


(defun allowed-modes (mode)
  (labels ((expand-modes (modes)
             (cond
               ((null modes) nil)
               ((keywordp (car modes)) (concatenate 'list
                                                    (iter (for (key value) in-hashtable (symbols-category-hash mode))
                                                          (when (eql value (car modes))
                                                            (collect key)))
                                                    (expand-modes (cdr modes))))
               ((symbolp (car modes)) (cons (car modes)
                                            (expand-modes (cdr modes))))
               (t (error "bad mode: ~A" (car modes))))))
    (sort (set-difference (expand-modes (get mode :allowed))
                          (expand-modes (get mode :not-allowed)))
          #'<
          :key #'(lambda (s) (get s :sort)))))

(defun make-mtable (mode)
  (let ((regexs nil)
        (modes nil))
    (iter (for exit in (get mode :continue))
          (push :continue modes)
          (push (ppcre:parse-string exit) regexs))
    (iter (for exit in (get mode :exit))
          (push :exit modes)
          (push (ppcre:parse-string exit) regexs))
    (iter (for reg in (get mode :exit-border))
          (push :exit-border modes)
          (push (ppcre:parse-string reg) regexs))
    (iter (for amode in (allowed-modes mode))
          (iter (for entry in (get amode :entry))
                (push amode modes)
                (push (ppcre:parse-string entry) regexs))
          (iter (for special in (get amode :special))
                (push (cons :special amode) modes)
                (push (ppcre:parse-string special) regexs))
          (iter (for single in (get amode :single))
                (push (cons :single amode) modes)
                (push (ppcre:parse-string single) regexs)))
    (cons (if (cdr regexs)
              (cons :alternation
                    (iter (for reg in (nreverse regexs))
                          (collect (list :register
                                         reg))))
              (list :register (car regexs)))
          (coerce (nreverse modes) 'vector))))

(defun mtable-regex (mtable)
  (car mtable))

(defun mtable-modes (mtable)
  (cdr mtable))

(defun mtable-scan (mtable target-string &key (start 0) (end (length target-string)))
  (multiple-value-bind (pos1 pos2 arr1) (ppcre:scan 
                                                    (ppcre:create-scanner (mtable-regex mtable)
                                                                          :single-line-mode :MULTI-LINE-MODE-P)
                                                    target-string
                                                    :start start
                                                    :end end)
    (if pos1
        (let ((index (position-if #'identity arr1)))
          (values (aref (mtable-modes mtable)
                        index)
                  pos1
                  pos2)))))

(defun fill-lexer (lexer mode)
  (unless (gethash mode lexer)
    (setf (gethash mode lexer)
          (make-mtable mode))
    (map 'nil
         (alexandria:curry #'fill-lexer lexer)
         (allowed-modes mode)))
  lexer)
    
(defun make-lexer (mode)
  (fill-lexer (make-hash-table) mode))

(defun remake-lexer (mode)
  (let ((package (symbol-package mode)))
    (setf (symbol-value (find-symbol "*LEXER*" package))
          (make-lexer (find-symbol "TOPLEVEL" package)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun lexer-parse/impl (mode target-string &key (start 0) (end (length target-string)) lexer)
  (let ((lex (or (symbol-value (find-symbol  "*LEXER*" (symbol-package mode)))
                 lexer))
        (curpos start)
        (tokens (list mode))
        (continue nil))
    (iter (while (< curpos end))
          (multiple-value-bind (in-mode pos1 pos2) (mtable-scan (gethash mode lex)
                                                                target-string
                                                                :start curpos
                                                                :end end)
            (when (or (not in-mode)
                      (> pos1 curpos))
              (push (subseq target-string 
                            curpos 
                            (or pos1 end))
                    tokens))
            
            (setf curpos (or pos2 end))

            (cond
              ((eql in-mode :exit) (finish))
              ((eql in-mode :exit-border) (progn
                                            (setf curpos pos1)
                                            (finish)))
              ((eql in-mode :continue) (progn
                                         (setf continue t)
                                         (finish)))
              ((and (consp in-mode)
                    (eql (car in-mode) :special)) (push (if (equal (mtable-regex (gethash (cdr in-mode) lex))
                                                                   '(:register nil))
                                                            (list (cdr in-mode)
                                                                  (subseq target-string pos1 pos2))
                                                            (lexer-parse/impl (cdr in-mode)
                                                                              target-string
                                                                              :start pos1
                                                                              :end pos2
                                                                              :lexer lex))
                                                        tokens))
              ((and (consp in-mode)
                    (eql (car in-mode) :single) (push (cdr in-mode)
                                                      tokens)))
              (in-mode (let ((cont t))
                         (iter (while cont)
                               (setf cont nil)
                               (multiple-value-bind (item pos continue) (lexer-parse/impl in-mode
                                                                                          target-string
                                                                                          :start curpos
                                                                                          :end end
                                                                                          :lexer lex)
                                 (push item tokens)
                                 (setf curpos pos)
                                 (setf cont continue))))))))
    (values (nreverse tokens) curpos continue)))



(defun lexer-parse (mode target-string)
  (lexer-parse/impl mode
                    (remove #\Return target-string)))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defgeneric parse (markup-type obj))

(defmethod parse (markup-type (path pathname))
  (parse markup-type (alexandria:read-file-into-string path)))

(defmethod parse (markup-type (string string))
  (lexer-parse (find-symbol "TOPLEVEL" markup-type)
               (concatenate 'string
                            #(#\Newline)
                            string
                            #(#\Newline))))
  

(defmacro define-mode (name (sort &optional category) &rest args)
  `(progn
     (export ',name)
     (setf (get ',name :sort)
           ,sort)
     (setf (gethash ',name (symbols-category-hash ',name))
           ,category)
     (iter (for prop in ',args)
           (setf (get ',name (car prop))
                 (cdr prop)))
     (eval-when (:execute)
       (remake-lexer ',name))))
