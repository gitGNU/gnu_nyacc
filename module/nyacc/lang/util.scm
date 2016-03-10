;;; module/nyacc/util.scm
;;;
;;; Copyright (C) 2015 Matthew R. Wette
;;;
;;; This software is covered by the GNU GENERAL PUBLIC LICENCE, Version 3,
;;; or any later version published by the Free Software Foundation.  See the
;;; file COPYING included with the nyacc distribution.

;; runtime utilities for the parsers -- needs work

(define-module (nyacc lang util)
  #:export (lang-crn-lic
	    make-tl tl->list ;; rename?? to tl->sx for sxml-expr
	    tl-append tl-insert tl-extend tl+attr
	    sx-tag sx-attr sx-ref sx-tail sx-find
	    ;; for pretty-printing
	    make-protect-expr make-pp-formatter
	    ;; for ???
	    move-if-changed
            fmterr)
  #:use-module ((srfi srfi-1) #:select(find))
  )

;; This is a generic copyright/licence that will be printed in the output
;; of the examples/nyacc/lang/*/ actions.scm and tables.scm files.
(define lang-crn-lic "Copyright (C) 2015,2016 Matthew R. Wette

This software is covered by the GNU GENERAL PUBLIC LICENCE, Version 3,
or any later version published by the Free Software Foundation.  See the
file COPYING included with the this distribution.")


(define (fmterr fmt . args)
  (apply simple-format (current-error-port) fmt args))


;; @section Tagged Lists
;; Tagged lists are
;; They are implemented as a cons cell with the car and the cdr a list.
;; The cdr is used to accumulate appended items and the car is used to
;; keep the tag, attributes and inserted items.
;; @example
;; tl => '(H . T), H => (c a b 'tag); T =>
;; @end example

;; @table code

;; @item make-tl tag [item item ...]
;; Create a tagged-list structure.
(define (make-tl tag . rest)
  (let iter ((tail tag) (l rest))
    (if (null? l) (cons '() tail)
	(iter (cons (car l) tail) (cdr l)))))

;; @item tl->list tl
;; Convert a tagged list structure to a list.  This collects added attributes
;; and puts them right after the (leading) tag, resulting in something like
;; @example
;; (<tag> (@ <attr>) <rest>)
;; @end example
(define (tl->list tl)
  (let ((heda (car tl))
	(head (let iter ((head '()) (attr '()) (tl-head (car tl)))
		(if (null? tl-head)
		    (if (pair? attr)
			(cons (cons '@ attr) (reverse head))
			(reverse head))
		    (if (and (pair? (car tl-head)) (eq? '@ (caar tl-head)))
			(iter head (cons (cdar tl-head) attr) (cdr tl-head))
			(iter (cons (car tl-head) head) attr (cdr tl-head)))))))
    (let iter ((tail '()) (tl-tail (cdr tl)))
      (if (pair? tl-tail)
	  (iter (cons (car tl-tail) tail) (cdr tl-tail))
	  (cons tl-tail (append head tail))))))

;; @item tl-insert tl item
;; Insert item at front of tagged list (but after tag).
(define (tl-insert tl item)
  (cons (cons item (car tl)) (cdr tl)))

;; @item tl-append tl item ...
;; Append item at end of tagged list.
(define (tl-append tl . rest)
  (cons (car tl)
	(let iter ((tail (cdr tl)) (items rest))
	  (if (null? items) tail
	      (iter (cons (car items) tail) (cdr items))))))

;; @item tl-extend tl item-l
;; Extend with a list of items.
(define (tl-extend tl item-l)
  (apply tl-append tl item-l))

;; @item tl+attr tl key val)
;; Add an attribute to a tagged list.  Return the tl.
;; @example
;; (tl+attr tl 'type "int")
;; @end example
(define (tl+attr tl key val)
  (tl-insert tl (cons '@ (list key val))))

;; @item tl-merge tl tl1
;; Merge guts of phony-tl @code{tl1} into @code{tl}.
(define (tl-merge tl tl1)
  (error "not implemented (yet)")
  )

;; =====================================

;; @item sx-ref sx ix => item
;; Reference the @code{ix}-th element of the list, not counting the optional
;; attributes item.  If the list is shorter than the index, return @code{#f}.
;; @example
;; (sx-ref '(abc "def") 1) => "def"
;; (sx-ref '(abc (@ (foo "1")) "def") 1) => "def"
;; @end example
(define (sx-ref sx ix)
  (define (list-xref l x) (if (> (length l) x) (list-ref l x) #f))
  (cond
   ((zero? ix) (car sx))
   ((and (pair? (cadr sx)) (eqv? '@ (caadr sx)))
    (list-xref sx (1+ ix)))
   (else
    (list-xref sx ix))))

;; @item sx-tag sx => tag
;; Return the tag for a tree
(define (sx-tag sx)
  (if (pair? sx) (car sx) #f))

;; @item sx-tail sx ix => (list)
;; Return the tail starting at the ix-th cdr, starting from 0.
;; For example, if sx has 3 items then (sx-tail sx 2) returns '().
;; BUG: not working for (sx '(foo) 1)
(define (sx-tail sx ix)
  (if (zero? ix) (error "zero index not supported"))
  (let ((sx (cdr sx)) (ix (1- ix)))
    (cond
     ((and (null? sx) (zero? ix)) sx)
     ((and (pair? (car sx)) (eqv? '@ (caar sx))) (list-tail sx (1+ ix)))
     (else (list-tail sx ix)))))

;; @item sx-attr sx => '(@ ...)|#f
;; @example
;; (sx-attr '(abc (@ (foo "1")) def) 1) => '(@ (foo "1"))
;; @end example
(define (sx-attr sx)
  (if (and (pair? (car sx)) (pair? (cadr sx)))
      (if (eqv? '@ (caadr sx))
	  (cadr sx)
	  #f)
      #f))

;; @item sx-find tag sx => ((tag ...) (tag ...))
;; Find the first matching element (in the first level).
(define (sx-find tag sx)
  (find (lambda (node)
	    (and (pair? node) (eqv? tag (car node))))
	sx))


;; @deffn make-protect-expr op-prec op-assc => side op expr => #t|#f
;; Generate procedure @code{protect-expr} for pretty-printers, which takes
;; the form @code{(protect-expr? side op expr)} and where @code{side}
;; is @code{'lval} or @code{'rval}, @code{op} is the operator and @code{expr}
;; is the expression.  The argument @arg{op-prec} is a list of equivalent
;; operators in order of decreasing precedence and @arg{op-assc} is an
;; a-list of precedence with keys @code{'left}, @code{'right} and
;; @code{nonassoc}.
;; @example
;; (protect-expr? 'lval '+ '(mul ...)) => TBD
;; @end example
(define (make-protect-expr op-prec op-assc)

  (define (assc-lt? op)
    (memq op (assq-ref op-assc 'left)))

  (define (assc-rt? op)
    (memq op (assq-ref op-assc 'right)))

  ;; @item prec a b => '>|'<|'=|#f
  ;; Returns the prececence relation of @code{a}, @code{b} as
  ;; @code{<}, @code{>}, @code{=} or @code{#f} (no relation).
  (define (prec a b)
    (let iter ((ag #f) (bg #f) (opg op-prec)) ;; a-group, b-group
      (cond
       ((null? opg) #f)			; indeterminate
       ((memq a (car opg))
	(if bg '<
	    (if (memq b (car opg)) '=
		(iter #t bg (cdr opg)))))
       ((memq b (car opg))
	(if ag '>
	    (if (memq a (car opg)) '=
		(iter ag #t (cdr opg)))))
       (else
	(iter ag bg (cdr opg))))))

  (lambda (side op expr)
    (let ((assc? (case side
		   ((lt left) assc-rt?)
		   ((rt right) assc-lt?)))
	  (vtag (car expr)))
      (case (prec op vtag)
	((>) #t)
	((<) #f)
	((=) (assc? op))
	(else #f)))))

;; @make-pp-formatter => fmtr
;; @example
;; (fmtr 'push) ;; push indent level
;; (fmtr 'pop)  ;; pop indent level
;; (fmtr "fmt" arg1 arg2 ...)
;; @end example
(define* (make-pp-formatter)
  (letrec
      ((maxcol 78)
       (maxind 36)
       (column 0)
       (ind-lev 0)
       (ind-len 0)
       (blanks "                                            ")
       (ind-str (lambda () (substring blanks 0 ind-len)))
       (cnt-str (lambda () (substring blanks 0 (+ 4 ind-len))))
       (sf-nl (lambda () (newline) (set! column 0)))

       (push-il
	(lambda ()
	  (set! ind-lev (min maxind (1+ ind-lev)))
	  (set! ind-len (* 2 ind-lev))))

       (pop-il
	(lambda ()
	  (set! ind-lev (max 0 (1- ind-lev)))
	  (set! ind-len (* 2 ind-lev))))
       
       (sf
	(lambda (fmt . args)
	  (let* ((str (apply simple-format #f fmt args))
		 (len (string-length str)))
	    (when (zero? column)
	      (display (ind-str))
	      (set! column (+ column ind-len)))
	    (when (> (+ column len) maxcol)
	      (newline)
	      (display (cnt-str))
	      (set! column (+ column ind-len 4)))
	    (display str)
	    (when (eqv? #\newline (string-ref str (1- len)))
	      (set! column 0))))))

    (lambda (arg0 . rest)
      (cond
       ((string? arg0) (apply sf arg0 rest))
       ((eqv? 'push arg0) (push-il))
       ((eqv? 'pop arg0) (pop-il))
       (else (error "pp-formatter: bad args"))
       ))))

;; @item move-if-changed src-file dst-file [sav-file]
;; Return @code{#t} if changed.
(define (move-if-changed src-file dst-file . rest)

  (define (doit)
    (let ((sav-file (if (pair? rest) (car rest) #f)))
      (if (and sav-file (access? sav-file W_OK))
	  (system (simple-format #f "mv ~A ~A" dst-file sav-file)))
      (system (simple-format #f "mv ~A ~A" src-file dst-file))
      #t))
    
  (cond
   ;; src-file does not exist
   ((not (access? src-file R_OK)) #f)

   ;; dst-file does not exist, update anyhow
   ((not (access? dst-file F_OK))
    (system (simple-format #f "mv ~A ~A" src-file dst-file)) #t)

   ;; both exist, but no changes
   ((zero? (system
	    (simple-format #f "cmp ~A ~A >/dev/null" src-file dst-file)))
    (system (simple-format #f "rm ~A" src-file)) #f)

   ;; both exist, update
   ((access? dst-file W_OK)
    (doit))
   
   (else
    (simple-format (current-error-port) "move-if-changed: no write access\n")
    #f)))

;; @end table

;;; --- last line ---
