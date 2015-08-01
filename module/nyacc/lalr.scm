;;; nyacc/lalr.scm
;;;
;;; Copyright (C) 2014, 2015 Matthew R. Wette
;;;
;;; This library is free software; you can redistribute it and/or
;;; modify it under the terms of the GNU Lesser General Public
;;; License as published by the Free Software Foundation; either
;;; version 3 of the License, or (at your option) any later version.
;;;
;;; This library is distributed in the hope that it will be useful,
;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;;; Lesser General Public License for more details.
;;;
;;; You should have received a copy of the GNU Lesser General Public
;;; License along with this library; if not, write to the Free Software
;;; Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA

(define-module (nyacc lalr)
  #:export-syntax (lalr-spec)
  #:export (*nyacc-version*
	    make-lalr-machine
	    compact-machine hashify-machine
	    lalr-match-table
	    make-lalr-parser
	    pp-lalr-grammar pp-lalr-machine
	    write-lalr-tables
	    wrap-action
	    )
  ;;#:use-module ((rnrs base) #:select (vector-map))
  #:use-module ((rnrs lists) #:select (remq remp remove fold-left fold-right))
  #:use-module ((srfi srfi-1)
		#:select (lset-intersection lset-union lset-difference fold))
  #:use-module ((srfi srfi-9) #:select (define-record-type))
  #:use-module ((srfi srfi-43) #:select (vector-map vector-for-each))
  #:use-module (nyacc util)
  )

(define *nyacc-version* "0.60.2")

#|
(define-syntax $?
  (syntax-rules ()
    ((_ <symb>)
     (let* ((s (symbol->string (quote <symb>)))
	    (os (string-append "opt-" s))
	    (sy (string->symbol os)))
       `(rule ,sy (,sy () (<symb>)))))))
|#
;; maybe?: (rule-macro $* ((_ ssss ($$ ...)

;; @item proxy-? sym rhs
;; @example
;; (LHS (($? RHS))
;; ($P (($$ #f))
;;     ($P RHS ($$ (set-cdr! (last-pair $1) (list $2)) $1)))
;; @end example
(define (proxy-? sym rhs)
  (list sym
	(list '(action #f #f (list)))
	rhs))

;; @item proxy-+ sym rhs
;; @example
;; (LHS (($* RHS))
;; ($P (($$ '()))
;;     ($P RHS ($$ (set-cdr! (last-pair $1) (list $2)) $1)))
;; @end example
(define (proxy-* sym rhs)
  (if (pair? (filter (lambda (elt) (eqv? 'action (car elt))) rhs))
      (error "no RHS action allowed")) ;; rhs
  (list
   sym
   (list '(action #f #f (list)))
   (append (cons (cons 'non-terminal sym) rhs)
	   (list '(action #f #f
			  (set-cdr! (last-pair $1) (list $2))
			  $1)))))

;; @item proxy-+ sym rhs
;; @example
;; (LHS (($+ RHS))
;; ($P (RHS ($$ (list $1)))
;;     ($P RHS ($$ (set-cdr! (last-pair $1) (list $2)) $1)))
;; @end example
(define (proxy-+ sym rhs)
  (if (pair? (filter (lambda (elt) (eq? 'action (car elt))) rhs))
      (error "no RHS action allowed")) ;; rhs
  (list
   sym
   (append rhs (list '(action #f #f (list $1))))
   (append (cons (cons 'non-terminal sym) rhs)
	   (list '(action #f #f
			  (set-cdr! (last-pair $1) (list $2))
			  $1)))))
  
;; @item lalr-spec grammar => spec
;; This routine reads a grammar in a scheme-like syntax and returns a SRFI-9
;; record of type @code{lalr-record-type}.   This spec' can be an input for
;; @item{make-parser-generator} or @item{pp-spec}.
;;.This will return the specification.  Notably the grammar will have rhs
;; arguments decorated with type (e.g., @code{(terminal . #\,)}).
;; Each production rule in the grammar will be of the form
;; @code{(lhs rhs1 rhs2 ...)} where each element of the RHS is one of
;; @itemize
;; @item @code{('terminal . atom)}
;; @item @code{('non-terminal . symbol)}
;; @item @code{('action . (ref narg guts)}
;; @item @code{('proxy . production-rule)}
;; @end itemize
;; Currently, the number of arguments for items is computed in the routine
;; @code{process-grammar}.
(define-syntax lalr-spec
  (syntax-rules +++ () 
    ((_ <expr> +++)
     (let* (#;(xtra-rules '())		; symbols for optional's
	    #;(nxsymb 0)			; number of extra symbols
	    #;(make-symb
	     (lambda ()
	       (let ((n nxsymb))
		 (set! nxsymb (1+ n))
		 (string->symbol
		  (string-append "$opt-" (number->string n))))))
	    )
       (letrec-syntax
	   ((with-attr-list
	     (syntax-rules ($prune)
	       ((_ ($prune <symb>) <ex> ...)
		(cons '(prune . <symb>) (with-attr-list <ex> ...)))
	       ((_) '())))
	    (parse-rhs
	     (lambda (x)
	       ;; The following is syntax-case because we use a fender.
	       (syntax-case x (quote
			       $$ $$/ref $$-ref
			       $action $action/ref $action-ref
			       $with
			       $? $* $+)
		 ;; action specifications
		 ((_ ($$ <guts> ...) <e2> ...)
		  #'(cons '(action #f #f <guts> ...) (parse-rhs <e2> ...)))
		 ((_ ($$-ref <ref>) <e2> ...)
		  #'(cons '(action #f '<ref> #f) (parse-rhs <e2> ...)))
		 ((_ ($$/ref <ref> <guts> ...) <e2> ...)
		  #'(cons '(action #f <ref> <guts> ...) (parse-rhs <e2> ...)))
		 ((_ ($action <guts> ...) <e2> ...)
		  #'(cons '(action #f #f <guts> ...) (parse-rhs <e2> ...)))
		 ((_ ($action-ref <ref>) <e2> ...)
		  #'(cons '(action #f '<ref> #f) (parse-rhs <e2> ...)))
		 ((_ ($action/ref <ref> <guts> ...) <e2> ...)
		  #'(cons '(action #f <ref> <guts> ...) (parse-rhs <e2> ...)))

		 ;; other internal $-syntax
		 ((_ ($with <lhs-ref> <ex> ...) <e2> ...)
		  #'(cons `(with <lhs-ref> ,@(with-attr-list <ex> ...))
			  (parse-rhs <e2> ...)))
		 
		 ;; (experimental) proxies
		 ((_ ($? <s1> <s2> ...) <e2> ...)
		  #'(cons (cons* 'proxy proxy-? (parse-rhs <s1> <s2> ...))
			  (parse-rhs <e2> ...)))
		 ((_ ($+ <s1> <s2> ...) <e2> ...)
		  #'(cons (cons* 'proxy proxy-+ (parse-rhs <s1> <s2> ...))
			  (parse-rhs <e2> ...)))
		 ((_ ($* <s1> <s2> ...) <e2> ...)
		  #'(cons (cons* 'proxy proxy-* (parse-rhs <s1> <s2> ...))
			  (parse-rhs <e2> ...)))
		 
		 ((_ (quote <e1>) <e2> ...)
		  #'(cons '(terminal . <e1>) (parse-rhs <e2> ...)))
		 ((_ (<f> ...) <e2> ...)
		  #'(cons (<f> ...) (parse-rhs <e2> ...)))
		 ((_ <e1> <e2> ...)
		  (identifier? (syntax <e1>)) ; fender to trap non-term's
		  #'(cons '(non-terminal . <e1>) (parse-rhs <e2> ...)))
		 ((_ <e1> <e2> ...)
		  #'(cons '(terminal . <e1>) (parse-rhs <e2> ...)))
		 ((_) #'(list)))))
	    (parse-rhs-list
	     (syntax-rules ()
	       ((_ (<e1> ...) <rhs2> <rhs3> ...)
		(cons (parse-rhs <e1> ...)
		      (parse-rhs-list <rhs2> <rhs3> ...)))
	       ((_ (<e1> ...))
		(list (parse-rhs <e1> ...)))))
	    (parse-grammar
	     (syntax-rules ()
	       ((_ (<lhs> <rhs1> ...) <prod2> <prod3> ...)
		(cons (cons '<lhs> (parse-rhs-list <rhs1> ...))
		      (parse-grammar <prod2> <prod3> ...)))
	       ((_ (<lhs> <rhs1> ...))
		(list (cons '<lhs> (parse-rhs-list <rhs1> ...))))))
	    (parse-precedence
	     (syntax-rules (left right nonassoc)
	       ((_ (left <tk> ...) <ex> ...)
		(cons '(left <tk> ...) (parse-precedence <ex> ...)))
	       ((_ (right <tk> ...) <ex> ...)
		(cons '(right <tk> ...) (parse-precedence <ex> ...)))
	       ((_ (nonassoc <tk> ...) <ex> ...)
		(cons '(nonassoc <tk> ...) (parse-precedence <ex> ...)))
	       ((_) '())))
	    (lalr-spec-1
	     (syntax-rules (start expect precedence< precedence> grammar)
	       ((_ (start <symb>) <e> ...)
		(cons (cons 'start '<symb>) (lalr-spec-1 <e> ...)))
	       ((_ (expect <n>) <e> ...)
		(cons (cons 'expect <n>) (lalr-spec-1 <e> ...)))
	       ((_ (precedence< <ex> ...) <e> ...)
		(cons (cons 'prece (reverse (parse-precedence <ex> ...)))
		      (lalr-spec-1 <e> ...)))
	       ((_ (precedence> <ex> ...) <e> ...)
		(cons (cons 'prece (parse-precedence <ex> ...))
		      (lalr-spec-1 <e> ...)))
	       ((_ (grammar <prod> ...) <e> ...)
		(cons (cons 'grammar (parse-grammar <prod> ...))
		      (lalr-spec-1 <e> ...))) 
	       ((_) '()))))
	 (process-spec (lalr-spec-1 <expr> +++)))))))

;; @item atomize terminal => object
;; Generate an atomic object for a terminal.   Expected terminals are strings,
;; characters and symbols.  This will convert the strings @code{s} to symbols
;; of the form @code{'$:s}.
(define (atomize terminal)
  (if (string? terminal)
      (string->symbol (string-append "$:" terminal))
      terminal))

;; @item normize terminal => char|symbol
;; Normalize a token. This routine will normalize tokens in order to check
;; for similarities. For example, @code{"+"} and @code{#\+} are similar,
;; @code{'foo} and @code{"foo"} are similar.
(define (normize terminal)
  (if (not (string? terminal)) terminal
      (if (= 1 (string-length terminal))
	  (string-ref terminal 0)
	  (string->symbol terminal))))

;; @item eqv-terminal? a b
;; This is a predicate to determine if the terminals @code{a} and @code{b}
;; are equivalent.
(define (eqv-terminal? a b)
  (eqv? (atomize a) (atomize b)))

;; @item find-terminal symb term-l => term-symb
;; Find the terminal in @code{term-l} that is equivalent to @code{symb}.
(define (find-terminal symb term-l)
  (let iter ((tl term-l))
    (if (null? tl) #f
	(if (eqv-terminal? symb (car tl)) (car tl)
	    (iter (cdr tl))))))
  
;; @item process-spec tree => specification (as a-list)
;; Here we sweep through the production rules. We flatten and order the rules
;; and place all p-rules with like LHSs together.  There is a non-trivial
;; amount of extra code to deal with mid-rule actions (MRAs).
(define (process-spec tree)

  ;; Make a new symbol. This is a helper for proxies and mid-rule-actions.
  ;; The counter here is the one item in @code{process-spec} that is redefined.
  ;; Otherwise, I believe @code{process-spec} is referentially transparent.
  (define maksy
    (let ((cntr 1))
      (lambda ()
	(let ((c cntr))
	  (set! cntr (1+ cntr))
	  (string->symbol (string-append "$P" (number->string c)))))))

  ;; Compute precedence and associativity rules.
  ;; The goal here is to have a predicate which provides
  ;; @code{(prec>? a b)} and associativity @code{(left? a)}.
  ;; The tree will have 'left <list> and prece
  (define (prec-n-assc tree)
    (let iter ((p-l '()) (a-l '()) (tree tree) (node '()) (pspec '()))
      (cond
       ((pair? pspec)
	;; psp looks like ('left "+" "-"); pel ("+" "-"); psy (#\+ #\-)
	(let* ((psp (car pspec)) (pel (cdr psp)) (psy (map atomize pel)))
	  (iter (append (x-comb psy node)
			;; append (+ -) => ((+ -) (- +))
			(filter (lambda (p) (not (eqv? (car p) (cdr p))))
				(x-comb psy psy))
			p-l)
		(append (x-flip (cons (car psp) psy)) a-l)
		tree psy (cdr pspec))))
       ((pair? tree)
	(iter p-l a-l (cdr tree) '()
	      (if (eq? 'prece (caar tree)) (cdar tree) '())))
       (else
	(list (cons 'prec p-l) (cons 'assc a-l))))))

  ;;.@item make-mra-proxy sy pel act => ???
  ;; Generate a mid-rule-action proxy.
  (define (make-mra-proxy sy pel act)
    (list sy (list (cons* 'action (length pel) (cdr act)))))

  ;; fatal: symbol used as terminal and non-terminal
  (define (gram-check-2 tl nl err-l)
    (let ((cf (lset-intersection eqv? (map atomize tl) nl)))
      (if (pair? cf)
	  (cons (fmtstr "*** symbol is terminal and non-terminal: ~S" cf)
		err-l) err-l)))
	       
  ;; fatal: non-terminal's w/o production rule		  
  (define (gram-check-3 ll nl err-l)
    (fold-left
     (lambda (l n)
       (if (not (memq n ll))
	   (cons (fmtstr "*** non-terminal with no production rule: ~A" n) l)
	   l))
     err-l nl))

  ;; warning: unused LHS
  ;; TODO: which don't appear in OTHER RHS, e.g., (foo (foo))
  (define (gram-check-4 ll nl err-l)
    (fold-left
     (lambda (l s) (cons (fmtstr "+++ LHS not used in any RHS: ~A" s) l))
     err-l
     (let iter ((ull '()) (all ll)) ; unused LHSs, all LHS's
       (if (null? all) ull
	   (iter (if (or (memq (car all) nl)
			 (memq (car all) ull)
			 (eq? (car all) '$start))
		     ull (cons (car all) ull))
		 (cdr all))))))
	       
  ;; warning: duplicate terminals under atomize (e.g., 'foo "foo")
  (define (gram-check-5 terminals prev-errs)
    (let ((f "warning: similar terminals: ~A ~A"))
      (let iter ((errs prev-errs) (head '()) (tail terminals))
	(if (null? tail) errs
	    (let* ((tok (car tail)) (nzt (normize tok))
		   (pair (cons nzt tok)) (dup (assq-ref head nzt)))
	      (iter (if dup (cons (fmtstr f (obj->str tok) (obj->str dup)) errs)
			errs)
		    (cons pair head) (cdr tail)))))))

  (let* ((gram (assq-ref tree 'grammar))
	 (start-symbol (assq-ref tree 'start))
	 (expect (or (assq-ref tree 'expect) 0))
	 (start-rule (lambda () (list start-symbol)))
	 (add-el (lambda (e l) (if (memq e l) l (cons e l))))
	 (pna (prec-n-assc tree)))
    ;; Sweep through the grammar to generate a canonical specification.
    ;; Note: the local rhs is used to hold RHS terms, but a
    ;; value of @code{'()} is used to signal "add rule", and a value of
    ;; @code{#f} is used to signal ``done, proceed to next rule.''
    ;; We use @code{tail} below to go through all remaining rules so that any
    ;; like LHS get absorbed before proceeding: This keeps LHS in sequence.
    (let iter ((ll '($start))		; LHS list
	       (rl (list (start-rule))) ; RHS list
	       (al (list (list 1 'all '$1))) ; narg-ref-action list
	       (xl (list 1))		     ; reduction size
	       (tl (list '$end))	; set of terminals (add $end?)
	       (nl (list start-symbol))	; set of non-terminals
	       (zl (list))		; wierd stuff
	       ;;
	       (head gram)	       ; head of grammar productions
	       (prox '())	       ; proxy productions for MRA
	       (lhs #f)		       ; current LHS (symbol)
	       (tail '())	       ; tail of grammar productions
	       (rhs-l '())	       ; list of RHSs being processed
	       (act #f)		       ; action if seen in RHS
	       (pel '())	       ; processed (RHS) terms list
	       (rhs #f))	       ; list of el'ts being processed
      (cond
       ((pair? rhs)
	;; Capture info on RHS term.
	(case (caar rhs)
	  ((terminal)
	   (iter ll rl al xl (add-el (cdar rhs) tl) nl zl head prox lhs tail
		 rhs-l act (cons (atomize (cdar rhs)) pel) (cdr rhs)))
	  ((non-terminal)
	   (iter ll rl al xl tl (add-el (cdar rhs) nl) zl head prox lhs tail
		 rhs-l act (cons (cdar rhs) pel) (cdr rhs)))
	  ((action)
	   (if (pair? (cdr rhs)) ;; not last elemnt in RHS
	       ;; mid-rule action: generate a proxy (car act is # args)
	       (let* ((sy (maksy))
		      (pr (make-mra-proxy sy pel (cdar rhs))))
		 (iter ll rl al xl tl (cons sy nl) zl head (cons pr prox)
		       lhs tail rhs-l act (cons sy pel) (cdr rhs)))
	       ;; end-rule action
	       (iter ll rl al xl tl nl zl head prox lhs tail
		     rhs-l (cdar rhs) pel (cdr rhs))))
	  ((proxy)
	   (let* ((sy (maksy))
		  (pf (cadar rhs))	; proxy function
		  (p1 (pf sy (cddar rhs))))
	     (iter ll rl al xl tl (cons sy nl) zl head (cons p1 prox) lhs tail
		   rhs-l act (cons sy pel) (cdr rhs))))

	  ((with)
	   (let* ((psy (maksy))		; proxy symbol
		  (rhsx (cadar rhs))	; symbol to expand
		  (p-l (map cdr (cddar rhs))) ; prune list
		  (p1 (list psy `((non-terminal . ,rhsx)
				  (action #f #f $1))))
		  )
	     ;;(fmtout "with: psy=~S\n" psy)
	     ;;(fmtout "      rhsx=~S\n" rhsx)
	     ;;(fmtout "      prune=~S\n" p1)
	     (iter ll rl al xl tl (cons psy nl) (acons psy p-l zl) head
		   (cons p1 prox) lhs tail rhs-l act (cons psy pel) (cdr rhs))))

	  (else
	   (error (fmtstr "bug=~S" (caar rhs))))))

       ((null? rhs)
	;; End of RHS items for current rule.
	(let* ((ln (length pel))
	       (r1 (reverse pel))
	       (a1 (cond ((and act (car act)) act) ; mid rule action
			 (act (cons ln (cdr act))) ; standard act
			 ((null? pel) (list 0 #f '(list))) ; def act w/ 0 RHS
			 (else (list ln #f '$1))))) ; def act w/ 1+ RHS
	  (iter (cons lhs ll) (cons r1 rl) (cons a1 al)
		(cons ln xl) tl nl zl head prox lhs tail rhs-l act pel #f)))

       ((pair? rhs-l)
	;; Work through next RHS.
	(iter ll rl al xl tl nl zl head prox lhs tail
	      (cdr rhs-l) #f '() (car rhs-l)))

       ((pair? tail)
	;; Check the next CAR of the tail.  If it matches
	;; the current LHS process it, else skip it.
	(iter ll rl al xl tl nl zl head prox lhs (cdr tail) 
	      (if (eqv? (caar tail) lhs) (cdar tail) '())
	      act pel #f))

       ((pair? prox)
	;; If a proxy then we have ((lhs RHS) (lhs RHS))
	(iter ll rl al xl tl nl zl (cons (car prox) head) (cdr prox)
		lhs tail rhs-l act pel rhs))

       ((pair? head)
	;; Check the next rule-set.  If the lhs has aready
	;; been processed, then skip.  Otherwise, copy copy
	;; to tail and process.
	(let ((lhs (caar head)) (rhs-l (cdar head))
	      (rest (cdr head)))
	  (if (memq lhs ll)
	      (iter ll rl al xl tl nl zl rest prox
		    #f '() '() act pel #f)
	      (iter ll rl al xl tl nl zl rest prox
		    lhs rest rhs-l act pel rhs))))

       (else
	;;(simple-format #t "rl=~S\n" rl)
	(let* ((rv (list->vector (map list->vector (reverse rl))))
	       (ral (reverse al))
	       (err-1 '()) ;; not used
	       ;; symbol used as terminal and non-terminal
	       (err-2 (gram-check-2 tl nl err-1))
	       ;; non-terminal's w/o production rule		  
	       (err-3 (gram-check-3 ll nl err-2))
	       ;; TODO: which don't appear in OTHER RHS, e.g., (foo (foo))
	       (err-4 (gram-check-4 ll nl err-3))
	       ;; Get duplicate terminals under atomize (e.g., 'foo "foo"):
	       (err-5 (gram-check-5 tl err-4))
	       ;; todo: Check that with withs are not mixed
	       (err-l err-5))
	  (for-each (lambda (e) (fmterr "~A\n" e)) err-l)
	  (if (pair? (filter (lambda (s) (char=? #\* (string-ref s 0))) err-l))
	      #f
	      (list
	       ;; most referenced
	       (cons 'non-terms nl)
	       (cons 'lhs-v (list->vector (reverse ll)))
	       (cons 'rhs-v rv)
	       ;; not as much
	       (cons 'terminals tl)
	       (cons 'start start-symbol)
	       (cons 'attr (list (cons 'expect expect)))
	       (cons 'prec (assq-ref pna 'prec))
	       (cons 'assc (assq-ref pna 'assc))
	       (cons 'act-v (list->vector (map cddr ral)))
	       (cons 'ref-v (list->vector (map cadr ral)))
	       (cons 'nrg-v (list->vector (map car ral)))
	       (cons 'prune zl)
	       (cons 'err-l err-l)))))))))
  
;;; === Code for processing the specification. ================================

;; @subsubheading Note
;; The fluid @code{*lalr-core*} is used during the machine generation
;; cycles to access core parameters of the specification.  This includes
;; the list of non-terminals, the vector of left-hand side symbols and the
;; vector of vector of right-hand side symbols.
(define *lalr-core* (make-fluid #f))

;; This record holds the minimum data from the grammar needed to build the
;; machine from the grammar specification.
(define-record-type lalr-core-type
  (make-lalr-core non-terms terminals lhs-v rhs-v eps-l)
  lalr-core-type?
  (non-terms core-non-terms)	      ; list of non-terminals
  (terminals core-terminals)	      ; list of non-terminals
  (lhs-v core-lhs-v)		      ; vec of left hand sides
  (rhs-v core-rhs-v)		      ; vec of right hand sides
  (eps-l core-eps-l))		      ; non-terms w/ eps prod's

;; @item make-core spec => lalr-core-type
;; Need to add @code{terminals} if we want @code{pp-lalr-machine} to work
;; right.
(define (make-core spec)
  (make-lalr-core (assq-ref spec 'non-terms)
		  (assq-ref spec 'terminals)
		  (assq-ref spec 'lhs-v)
		  (assq-ref spec 'rhs-v)
		  '()))

;; @item make-core/eps spec => lalr-core-type
;; Add list of symbols with epsilon productions.
(define (make-core/eps spec)
  (let ((non-terms (assq-ref spec 'non-terms))
	(terminals (assq-ref spec 'terminals))
	(lhs-v (assq-ref spec 'lhs-v))
	(rhs-v (assq-ref spec 'rhs-v)))
    (make-lalr-core non-terms terminals lhs-v rhs-v
		    (find-eps non-terms lhs-v rhs-v))))


;; @section Routines

;; @item <? a b po => #t | #f
;; Given tokens @code{a} and @code{b} and partial ordering @code{po} report
;; if precedence of @code{b} is greater than @code{a}?
(define (<? a b po)
  (if (member (cons a b) po) #t
      (let iter ((po po))
	(if (null? po) #f
	    (if (and (eqv? (caar po) a)
		     (<? (cdar po) b po))
		#t
		(iter (cdr po)))))))

;; @item prece a b po
;; Return precedence for @code{a,b} given the partial order @code{po} as
;; @code{#\<}, @code{#\>}, @code{#\=} or @code{#f}.
;; This is not a true partial order as we can have a<b and b<a => a=b.
;; @example
;; @code{(prece a a po)} => @code{#\=}.
;; @end example
(define (prece a b po)
  (if (eqv? a b)
      #\=
      (if (<? a b po)
	  (if (<? b a po) #\= #\<)
	  (if (<? b a po) #\> #f))))
  
;; @item non-terminal? symb
(define (non-terminal? symb)
  (cond
   ((eqv? symb '$epsilon) #t)
   ((eqv? symb '$end) #f)
   ((eqv? symb '$@) #f)
   ((string? symb) #f)
   (else
    (memq symb (core-non-terms (fluid-ref *lalr-core*))))))

;; @item terminal? symb
(define (terminal? symb)
  (not (non-terminal? symb)))

;; @item prule-range lhs => (start-ix . (1+ end-ix))
;; Find the range of productiion rules for the lhs.
;; If not found raise error.
(define (prule-range lhs)
  ;; If this needs to be really fast then we move to where lhs is an integer
  ;; and that used to index into a table that provides the ranges.
  (let* ((core (fluid-ref *lalr-core*))
	 (lhs-v (core-lhs-v core))
	 (n (vector-length lhs-v))
	 (match? (lambda (ix symb) (eqv? (vector-ref lhs-v ix) symb))))
    (cond
     ((terminal? lhs) '())
     ((eq? lhs '$epsilon) '())
     (else
      (let iter-st ((st 0))
	;; Iterate to find the start index.
	(if (= st n) '()		; not found
	    (if (match? st lhs)
		;; Start found, now iteratate to find end index.
		(let iter-nd ((nd st))
		  (if (= nd n) (cons st nd)
		      (if (not (match? nd lhs)) (cons st nd)
			  (iter-nd (1+ nd)))))
		(iter-st (1+ st)))))))))

;; @item range-next rng -> rng
;; Given a range in the form of @code{(cons start (1+ end))} return the next
;; value or '() if at end.  That is @code{(3 . 4)} => @code{'()}.
(define (range-next rng)
  (if (null? rng) '()
      (let ((nxt (cons (1+ (car rng)) (cdr rng))))
	(if (= (car nxt) (cdr nxt)) '() nxt))))

;; @item range-last? rng
;; Predicate to indicate last p-rule in range.
;; If off end (i.e., null rng) then #f.
(define (range-last? rng)
  (and (pair? rng) (= (1+ (car rng)) (cdr rng))))

;; @item lhs-symb prod-ix
;; Return the LHS symbol for the production at index @code{prod-id}.
(define (lhs-symb gx)
  (vector-ref (core-lhs-v (fluid-ref *lalr-core*)) gx))

;; @item looking-at (p-rule-ix . rhs-ix)
;; Return symbol we are looking at for this item state.
;; If at the end (position = -1) (or rule is zero-length) then return
;; @code{'$epsilon}.
(define (looking-at item)
  (let* ((core (fluid-ref *lalr-core*))
	 (rhs-v (core-rhs-v core))
	 (rule (vector-ref rhs-v (car item))))
    (if (last-item? item)
	'$epsilon
	(vector-ref rule (cdr item)))))

;; @item first-item gx
;; Given grammar rule index return the first item.
;; This will return @code{(gx . 0)}, or @code{(gx . -1)} if the rule has
;; no RHS elements.
(define (first-item gx)
  (let* ((core (fluid-ref *lalr-core*))
	 (rlen (vector-length (vector-ref (core-rhs-v core) gx))))
    (cons gx (if (zero? rlen) -1 0))))

;; @item last-item? item
;; Predictate to indicate last item in (or end of) production rule.
(define (last-item? item)
  (negative? (cdr item)))

;; @item next-item item
;; Return the next item in the production rule.
;; A position of @code{-1} means the end.  If at end, then @code{'()}
(define (next-item item)
  (let* ((core (fluid-ref *lalr-core*))
	 (gx (car item)) (rx (cdr item)) (rxp1 (1+ rx))
	 (rlen (vector-length (vector-ref (core-rhs-v core) gx))))
    (cond
     ((negative? rx) '())
     ((eqv? rxp1 rlen) (cons gx -1))
     (else (cons gx rxp1)))))

;; @item prev-item item
;; Return the previous item in the grammar.
;; prev (0 . 0) is currently (0 . 0)
(define (prev-item item)
  (let* ((core (fluid-ref *lalr-core*))
	 (rhs-v (core-rhs-v core))
	 (p-ix (car item))
	 (p-ixm1 (1- p-ix))
	 (r-ix (cdr item))
	 (r-ixm1 (if (negative? r-ix)
		     (1- (vector-length (vector-ref rhs-v p-ix)))
		     (1- r-ix))))
    (if (zero? r-ix)
	(if (zero? p-ix) item		; start, i.e., (0 . 0)
	    (cons p-ixm1 -1))		; prev p-rule
	(cons p-ix r-ixm1))))

;; @item non-kernels symb => list of prule indices
;; Compute the set of non-kernel rules for symbol @code{symb}.
;; If A => Bcd, B => Cde, B => Abe then non-kerns A gives TBD
(define (non-kernels symb)
  (let* ((core (fluid-ref *lalr-core*))
	 (lhs-v (core-lhs-v core))
	 (glen (vector-length lhs-v))
	 (lhs-symb (lambda (gx) (vector-ref lhs-v gx))))
    (let iter ((rslt '())		; result is set of states
	       (done '())		; symbols completed or queued
	       (next '())		; next round of symbols to process
	       (curr (list symb))	; this round of symbols to process
	       (gx 0))			; p-rule index
      (cond
       ((and (< gx glen) (memq (lhs-symb gx) curr))
	;; Add rhs to next and rslt if not already done.
	(let* ((rslt1 (if (memq gx rslt) rslt (cons gx rslt)))
	       ;;(rhs1 (looking-at (cons gx 0)))
	       (rhs1 (looking-at (first-item gx)))
	       (done1 (if (memq rhs1 done) done (cons rhs1 done)))
	       (next1 (cond
		       ((memq rhs1 done) next)
		       ((terminal? rhs1) next)
		       (else (cons rhs1 next)))))
	  (iter rslt1 done1 next1 curr (1+ gx))))
       ((< gx glen)
	;; Nothing to check; process next rule.
	(iter rslt done next curr (1+ gx)))
       ((pair? next)
	;; Start another sweep throught the grammar.
	(iter rslt done '() next 0))
       (else
	;; Done, so return.
	(reverse rslt))))))

;; @item non-kernel-items symb
;; Compute the set of non-kernel states for symbol @code{symb}.
(define (non-kernel-items symb)
  (map (lambda (gx) (cons gx 0)) (non-kernels symb)))

;; @item expand-k-item => item-set
;; Expand a kernel-item into a list with the non-kernels.
(define (expand-k-item k-item)
  (reverse
   (fold-left (lambda (items gx) (cons (first-item gx) items))
	      (list k-item)
	      (non-kernels (looking-at k-item)))))

;; @item its-trans itemset => alist of (symb . itemset)
;; Map a list of kernel items to a list of (symbol . post-shift items).
;; ((0 . 1) (2 . 3) => ((A . ((0 . 2) (2 . 4))) (B . (...)))
(define (its-trans items)
  (let iter ((rslt '())			; result
	     (k-items items)		; items
	     (itl '()))			; one k-item w/ added non-kernels
    (cond
     ((pair? itl)
      (let* ((it (car itl))		; item
	     (sy (looking-at it))	; symbol
	     (nx (next-item it))
	     (sq (assq sy rslt)))	; if we have seen it
	(cond
	 ((eq? sy '$epsilon)
	  ;; don't transition end-of-rule items
	  (iter rslt k-items (cdr itl)))
	 ((not sq)
	  ;; haven't seen this symbol yet
	  (iter (acons sy (list nx) rslt) k-items (cdr itl)))
	 ((member nx (cdr sq))
	  ;; repeat
	  (iter rslt k-items (cdr itl)))
	 (else
	  ;; SY is in RSLT and item not yet in: add it.
	  (set-cdr! sq (cons nx (cdr sq)))
	  (iter rslt k-items (cdr itl))))))
     ((pair? k-items)
      (iter rslt (cdr k-items) (expand-k-item (car k-items))))
     (else
      rslt))))

;; @item its-equal?
;; Helper for step1
(define (its-equal? its-1 its-2)
  (let iter ((its1 its-1) (its2 its-2)) ; cdr to strip off the ind
    (if (and (null? its1) (null? its2)) #t ; completed run through => #f
	(if (or (null? its1) (null? its2)) #f ; lists not equal length => #f
	    (if (not (member (car its1) its-2)) #f ; mismatch => #f
		(iter (cdr its1) (cdr its2)))))))

;; @item its-member its its-l
;; Helper for step1
;; If itemset @code{its} is a member of itemset list @code{its-l} return the
;; index, else return #f.
(define (its-member its its-l)
  (let iter ((itsl its-l))
    (if (null? itsl) #f
	(if (its-equal? its (cdar itsl)) (caar itsl)
	    (iter (cdr itsl))))))
  
;; @item step1 [input-a-list] => output-a-list
;; Compute the sets of LR(0) kernel items and the transitions associated with
;; spec.  These are returned as vectors in the alist with keys @code{'kis-v}
;; and @code{'kix-v}, repspectively.   Each entry in @code{kis-v} is a list of
;; items in the form @code{(px . rx)} where @code{px} is the production rule
;; index and @code{rx} is the index of the RHS symbol.  Each entry in the
;; vector @code{kix-v} is an a-list of the form @code{sy . kx} where @code{sy}
;; is a (terminal or non-terminal) symbol and @code{kx} is the index of the
;; kernel itemset.  The basic algorithm is discussed on pp. 228-229 of the
;; DB except that we compute non-kernel items on the fly using
;; @code{expand-k-item}.  See Example 4.46 on p. 241 of the DB.
(define (step1 . rest)
  (let* ((al-in (if (pair? rest) (car rest) '()))
	 (add-kset (lambda (upd kstz)	; give upd a ks-ix and add to kstz
		     (acons (1+ (caar kstz)) upd kstz)))
	 (init '(0 (0 . 0))))
    (let iter ((ksets (list init))	; w/ index
	       (ktrnz '())		; ((symb src dst) (symb src dst) ...)
	       (next '())		; w/ index
	       (todo (list init))	; w/ index
	       (curr #f)		; current state ix
	       (trans '()))		; ((symb it1 it2 ...) (symb ...))
      (cond
       ((pair? trans)
	;; Check next symbol for transitions (symb . (item1 item2 ...)).
	(let* ((dst (cdar trans))	       ; destination item
	       (dst-ix (its-member dst ksets)) ; return ix else #f
	       (upd (if dst-ix '() (cons (1+ (caar ksets)) dst)))
	       (ksets1 (if dst-ix ksets (cons upd ksets)))
	       (next1 (if dst-ix next (cons upd next)))
	       (dsx (if dst-ix dst-ix (car upd))) ; dest state index
	       (ktrnz1 (cons (list (caar trans) curr dsx) ktrnz)))
	  (iter ksets1 ktrnz1 next1 todo curr (cdr trans))))
       ((pair? todo)
	;; Process the next state (aka itemset).
	(iter ksets ktrnz next (cdr todo) (caar todo) (its-trans (cdar todo))))
       ((pair? next)
	;; Sweep throught the grammar again.
	(iter ksets ktrnz '() next curr '()))
       (else
	(let* ((nkis (length ksets))	; also (caar ksets)
	       (kisv (make-vector nkis #f))
	       (kitv (make-vector nkis '())))
	  ;; Vectorize kernel sets
	  (for-each
	   (lambda (kis) (vector-set! kisv (car kis) (cdr kis)))
	   ksets)
	  ;; Vectorize transitions (by src kx).
	  (for-each
	   (lambda (kit)
	     (vector-set! kitv (cadr kit)
			  (acons (car kit) (caddr kit)
				 (vector-ref kitv (cadr kit)))))
	   ktrnz)
	  ;; Return kis-v, kernel itemsets, and kix-v transitions.
	  (cons* (cons 'kis-v kisv) (cons 'kix-v kitv) al-in)))))))

;; @item find-eps non-terms lhs-v rhs-v => eps-l
;; Generate a list of non-terminals which have epsilon productions.
(define (find-eps nterms lhs-v rhs-v)
  (let* ((nprod (vector-length lhs-v))
	 (find-new
	  (lambda (e l)
	    (let iter ((ll l) (gx 0) (lhs #f) (rhs #()) (rx 0))
	      (cond
	       ((< rx (vector-length rhs))
		(if (and (memq (vector-ref rhs rx) nterms) ; non-term
			 (memq (vector-ref rhs rx) ll))	   ; w/ eps prod
		    (iter ll gx lhs rhs (1+ rx)) ; yes: check next
		    (iter ll (1+ gx) #f #() 0))) ; no: next p-rule
	       ((and lhs (= rx (vector-length rhs))) ; we have eps-prod
		(iter (if (memq lhs ll) ll (cons lhs ll)) (1+ gx) #f #() 0))
	       ((< gx nprod)		; check next p-rule if not on list
		(if (memq (vector-ref lhs-v gx) ll)
		    (iter ll (1+ gx) #f #() 0)
		    (iter ll gx (vector-ref lhs-v gx) (vector-ref rhs-v gx) 0)))
	       (else ll))))))
    (fixed-point find-new (find-new #f '()))))

;; @item merge1 v l
;; add v to l if not in l
(define	(merge1 v l)
  (if (memq v l) l (cons v l)))

;; @item merge2 v l al
;; add v to l if not in l or al
(define (merge2 v l al)	
  (if (memq v l) l (if (memq v al) l (cons v l))))

;; @item first symbol-list end-token-list
;; Return list of terminals starting the string @code{symbol-list}
;; (see DB, p. 188).  If the symbol-list can generate epsilon then the
;; result will include @code{end-token-list}.
(define (first symbol-list end-token-list)
  (let* ((core (fluid-ref *lalr-core*))
	 (eps-l (core-eps-l core))
	 ;; new: (prune-al (core-prune-al core)) ;; alist of symb -> prune
	 (stng symbol-list)
	 (latoks end-token-list))
    ;; This loop strips off the leading symbol from stng and then adds to
    ;; todo list, which results in range of p-rules getting checked for
    ;; terminals.
    (let iter ((rslt '())		; terminals collected
	       (stng stng)		; what's left of input string
	       (hzeps #t)		; haseps
	       (done '())		; non-terminals checked
	       (todo '())		; non-terminals to assess
	       (p-range '())		; range of p-rules to check
	       (it '()))
      (cond
       ((pair? it)
	(let ((sym (looking-at it)))
	  (cond
	   ((eq? sym '$epsilon)		; at end of rule, go next
	    (iter rslt stng hzeps done todo p-range '()))
	   ((terminal? sym)
	    (iter (merge1 sym rslt) stng hzeps done todo p-range '()))
	   ((memq sym eps-l)		; symbol has eps prod
	    (iter rslt stng hzeps (merge1 sym done) (merge2 sym todo done)
		  p-range (next-item it)))
	   (else ;; non-terminal, add to todo/done, goto next
	    (iter rslt stng hzeps
		  (merge1 sym done) (merge2 sym todo done) p-range '())))))
       
       ((pair? p-range)			; next one to do
	;; run through next rule
	(iter rslt stng hzeps done todo
	      (range-next p-range) (first-item (car p-range))))

      ((pair? todo)
       ;; Process the next non-terminal for grammar rules.
       ;; new: (if (assq-ref prune-al (car todo) (add to prune-l)))
       ;;      (if (memq (car toto) prune-l) skip else:
       (iter rslt stng hzeps done (cdr todo) (prule-range (car todo)) '()))

      ((and hzeps (pair? stng))
       ;; Last pass saw an $epsilon so check the next input symbol,
       ;; with saweps reset to #f.
       (let* ((symb (car stng)) (stng1 (cdr stng)) (symbl (list symb)))
	 (if (terminal? symb)
	     (iter (cons symb rslt) stng1
		   (and hzeps (memq symb eps-l))
		   done todo p-range '())
	     (iter rslt stng1
		   (or (eq? symb '$epsilon) (memq symb eps-l))
		   symbl symbl '() '()))))
      (hzeps
       ;; $epsilon passes all the way through.  If latoks provided use that.
       (if (pair? latoks)
	   (lset-union eqv? rslt latoks)
	   (cons '$epsilon rslt)))
      (else
       rslt)))))

;; @item item->stng item => list-of-symbols
;; Convert item (e.g., @code{(1 . 2)}) to list of symbols to the end of the
;; production(?). If item is at the end of the rule then return
;; @code{'$epsilon}.  The term "stng" is used to avoid confusion about the
;; term string.
(define (item->stng item)
  (if (eqv? (cdr item) -1)
      (list '$epsilon)
      (let* ((core (fluid-ref *lalr-core*))
	     (rhs-v (core-rhs-v core))
	     (rhs (vector-ref rhs-v (car item))))
	(let iter ((res '()) (ix (1- (vector-length rhs))))
	  (if (< ix (cdr item)) res
	      (iter (cons (vector-ref rhs ix) res) (1- ix)))))))

;; add (item . toks) to (front of) la-item-l
;; i.e., la-item-l is unmodified
(define (merge-la-item la-item-l item toks)
  (let* ((pair (assoc item la-item-l))
	 (tokl (if (pair? pair) (cdr pair) '()))
	 (allt ;; union of toks and la-item-l toks
	  (let iter ((tl tokl) (ts toks))
	    (if (null? ts) tl
		(iter (if (memq (car ts) tl) tl (cons (car ts) tl))
		      (cdr ts))))))
    (if (not pair) (acons item allt la-item-l)
	(if (eqv? tokl allt) la-item-l
	    (acons item allt la-item-l)))))

;; @item first-following item toks => token-list
;; For la-item A => x.By,z (as @code{item}, @code{toks}), this procedure
;; computes @code{FIRST(yz)}.
(define (first-following item toks)
  (first (item->stng (next-item item)) toks))

;; @item closure la-item-l => la-item-l
;; Compute the closure of a list of la-items.
;; Ref: DB, Fig 4.38, Sec. 4.7, p. 232
(define (closure la-item-l)
  ;; Compute the fixed point of I, aka @code{la-item-l}, with procedure
  ;;    for each item [A => x.By, a] in I
  ;;      each production B => z in G
  ;;      and each terminal b in FIRST(ya)
  ;;      such that [B => .z, b] is not in I do
  ;;        add [B => .z, b] to I
  ;; The routine @code{fixed-point} operates on one element of the input set.
  (prune-assoc
   (fixed-point
    (lambda (la-item seed)
      (let* ((item (car la-item)) (toks (cdr la-item)) (symb (looking-at item)))
	(cond
	 ((last-item? (car la-item)) seed)
	 ((terminal? (looking-at (car la-item))) seed)
	 (else
	  (let iter ((seed seed) (pr (prule-range symb)))
	    (if (null? pr) seed
		(iter (merge-la-item seed (first-item (car pr))
				     (first-following item toks))
		      (range-next pr))))))))
    la-item-l)))

;; @item kit-add kit-v tokens sx item
;; Add @code{tokens} to the list of lookaheads for the (kernel) @code{item}
;; in state @code{sx}.   This is a helper for @code{step2}.
(define (kit-add kit-v tokens kx item)
  (let* ((al (vector-ref kit-v kx))	; a-list for k-set kx
	 (ar (assoc item al))		; tokens for item
	 (sd (if (pair? ar)		; set difference
		 (lset-difference eqv? tokens (cdr ar))
		 tokens)))
    (cond ; no entry, update entry, no update
     ((null? tokens) #f)
     ((not ar) (vector-set! kit-v kx (acons item tokens al)) #t)
     ((pair? sd) (set-cdr! ar (append sd (cdr ar))) #t)
     (else #f))))

;; @item kip-add kip-v sx0 it0 sx1 it1
;; This is a helper for step2.  It updates kip-v with a propagation from
;; state @code{sx0}, item @code{it0} to state @code{sx1}, item @code{it1}.
;; [kip-v sx0] -> (it0 . ((sx1 . it1)
(define (kip-add kip-v sx0 it0 sx1 it1)
  (let* ((al (vector-ref kip-v sx0)) (ar (assoc it0 al)))
    (cond
     ((not ar)
      (vector-set! kip-v sx0 (acons it0 (list (cons sx1 it1)) al)) #t)
     ((member it1 (cdr ar)) #f)
     (else
      (set-cdr! ar (acons sx1 it1 (cdr ar))) #t))))

;; @item step2 subm1 => subm2
;; This implements steps 2 and 3 of Algorithm 4.13 on p. 242 of the DB.
;; The a-list @code{subm1} includes the kernel itemsets and transitions
;; from @code{step1}.   This routine adds two entries to the alist:
;; the initial set of lookahead tokens in a vector associated with key
;; @code{'kit-v} and a vector of spontaneous propagations associated with
;; key @code{'kip-v}.
;; @example
;; for-each item I in some itemset
;;   for-each la-item J in closure(I,#)
;;     for-each token T in lookaheads(J)
;;       if LA is #, then add to J propagate-to list
;;       otherwise add T to spontaneously-generated list
;; @end example
;;   
(define (step2 subm)
  (let* ((kis-v (assq-ref subm 'kis-v))
	 (kix-v (assq-ref subm 'kix-v)) ; transitions?
	 (nkset (vector-length kis-v))	; number of k-item-sets
	 ;; kernel-itemset tokens
	 (kit-v (make-vector nkset '())) ; sx => alist: (item latoks)
	 ;; kernel-itemset propagations
	 (kip-v (make-vector nkset '()))) ; sx0 => ((ita (sx1a . it1a) (sx2a
    (vector-set! kit-v 0 (closure (list (list '(0 . 0) '$end))))
    (let iter ((kx -1) (kset '()))
      (cond
       ((pair? kset)
	(for-each
	 (lambda (la-item)
	   (let* ((item (car la-item))	   ; closure item
		  (tokl (cdr la-item))	   ; tokens
		  (sym (looking-at item))  ; transition symbol
		  (item1 (next-item item)) ; next item after sym
		  (sx1 (assq-ref (vector-ref kix-v kx) sym)) ; goto(I,sym)
		  (item0 (car kset)))	   ; kernel item
	     (kit-add kit-v (remq '$@ tokl) sx1 item1) ; spontaneous
	     (if (memq '$@ tokl)	; propagates
		 (kip-add kip-v kx item0 sx1 item1))))
	 (remp ;; todo: check this remove
	  (lambda (li) (last-item? (car li)))
	  (closure (list (cons (car kset) '($@))))))
	(iter kx (cdr kset)))

       ((< (1+ kx) nkset)
	(iter (1+ kx)
	      ;; Don't propagate end-items.
	      (remp last-item? (vector-ref kis-v (1+ kx)))))))
    ;;(pp-kip-v kip-v)
    ;;(pp-kit-v kit-v)
    (cons* (cons 'kit-v kit-v) (cons 'kip-v kip-v) subm)))

;; debug for step2
(define (pp-kit ix kset)
  (fmtout "~S:\n" ix)
  (for-each
   (lambda (item) (fmtout "    ~A, ~S\n" (pp-item (car item)) (cdr item)))
   kset))
(define (pp-kit-v kit-v)
  (fmtout "spontaneous:\n")
  (vector-for-each pp-kit kit-v))
(define (pp-kip ix kset)
  (for-each
   (lambda (x)
     (fmtout "~S: ~A\n" ix (pp-item (car x)))
     (for-each
      (lambda (y) (fmtout "   => ~S: ~A\n" (car y) (pp-item (cdr y))))
      (cdr x)))
   kset))
(define (pp-kip-v kip-v)
  (fmtout "propagate:\n")
  (vector-for-each pp-kip kip-v))

;; @item step3 subm2 => subm3
;; This implements step 4 of Algorithm 4.13 from the DB.
(define (step3 subm)
  (let* ((kit-v (assq-ref subm 'kit-v))
	 (kip-v (assq-ref subm 'kip-v))
	 (nkset (vector-length kit-v)))
    (let iter ((upd #t)			; token propagated?
	       (kx -1)			; current index
	       (ktal '())		; (item . LA) list for kx
	       (toks '())		; LA tokens being propagated
	       (item '())		; from item 
	       (prop '()))		; to items
      (cond
       ((pair? prop)
	;; Propagate lookaheads.
	(let* ((sx1 (caar prop)) (it1 (cdar prop)))
	  (iter (or (kit-add kit-v toks sx1 it1) upd)
		kx ktal toks item (cdr prop))))

       ((pair? ktal)
	;; Process the next (item . tokl) in the alist ktal.
	(iter upd kx (cdr ktal) (cdar ktal) (caar ktal)
	      (assoc-ref (vector-ref kip-v kx) (caar ktal))))

       ((< (1+ kx) nkset)
	;; Process the next itemset.
	(iter upd (1+ kx) (vector-ref kit-v (1+ kx)) '() '() '()))

       (upd
	;; Have updates, rerun.
	(iter #f 0 '() '() '() '()))))
    subm))

;; @item reductions kit-v sx => ((tokA gxA1 ...) (tokB gxB1 ...) ...)
;; This is a helper for @code{step4}.
;; Return an a-list of reductions for state @code{sx}.
;; The a-list pairs are make of a token and a list of prule indicies.
;; CHECK the following.  We are brute-force using @code{closure} here.
;; It works, but there should be a better algorithm.
;; Note on reductions: We reduce if the kernel-item is an end-item or a 
;; non-kernel item with an epsilon-production.  That is, if we have a
;; kernel item of the form
;; @example
;; A => abc.
;; @end example
;; or if we have the non-kernel item of the form
;; @example
;; B => .de
;; @end example
;; where FIRST(de,#) includes #.  See the second paragraph under ``Efficient
;; Construction of LALR Parsing Tables'' in DB Sec 4.7.
(define (old-reductions kit-v sx)
  (let iter ((ral '())			  ; result: reduction a-list
	     (lais (vector-ref kit-v sx)) ; la-item list
	     (toks '())			  ; kernel la-item LA tokens
	     (itms '())			  ; all items
	     (gx #f)			  ; rule reduced by tl
	     (tl '()))			  ; LA-token list
    (cond
     ((pair? tl) ;; add (token . p-rule) to reduction list
      (let* ((tk (car tl)) (rp (assq tk ral)))
	(cond
	 ;; already have this, skip to next token
	 ((and rp (memq gx (cdr rp)))
	  (iter ral lais toks itms gx (cdr tl)))
	 (rp
	  ;; have token, add prule
	  (set-cdr! rp (cons gx (cdr rp)))
	  (iter ral lais toks itms gx (cdr tl)))
	 (else
	  ;; add token w/ prule
	  (iter (cons (list tk gx) ral) lais toks itms gx (cdr tl))))))

     ((pair? itms)
      (if (last-item? (car itms))
	  ;; last item, add it 
	  (iter ral lais toks (cdr itms) (caar itms) toks)
	  ;; skip to next
	  (iter ral lais toks (cdr itms) 0 '())))

     ((pair? lais) ;; process next la-item
      (iter ral (cdr lais) (cdar lais) (expand-k-item (caar lais)) 0 '()))

     (else ral))))
;; I think the above is broken because I'm not including the proper tail
;; string.  The following just uses closure to do the job.  It works but
;; may not be very efficient: seems a little brute force.
(define (new-reductions kit-v sx)
  (let iter ((ral '())			  ; result: reduction a-list
	     (klais (vector-ref kit-v sx)) ; kernel la-item list
	     (laits '())		   ; all la-items
	     (gx #f)			   ; rule reduced by tl
	     (tl '()))			  ; LA-token list
    (cond
     ((pair? tl) ;; add (token . p-rule) to reduction list
      (let* ((tk (car tl)) (rp (assq tk ral)))
	(cond
	 ;; already have this, skip to next token
	 ((and rp (memq gx (cdr rp)))
	  (iter ral klais laits gx (cdr tl)))
	 (rp
	  ;; have token, add prule
	  (set-cdr! rp (cons gx (cdr rp)))
	  (iter ral klais laits gx (cdr tl)))
	 (else
	  ;; add token w/ prule
	  (iter (cons (list tk gx) ral) klais laits gx (cdr tl))))))

     ((pair? laits) ;; process an
      (if (last-item? (caar laits))
	  ;; last item, add it 
	  (iter ral klais (cdr laits) (caaar laits) (cdar laits))
	  ;; skip to next
	  (iter ral klais (cdr laits) 0 '())))

     ((pair? klais) ;; expand next kernel la-item
      ;; There is a cheaper way than closure to do this but for now ...
      (iter ral (cdr klais) (closure (list (car klais))) 0 '()))

     (else
      ral))))
(define reductions new-reductions)

;; Generate parse-action-table from the shift a-list and reduce a-list.
;; This is a helper for @code{step4}.  It converts a list of state transitions
;; and a list of reductions into a parse-action table of shift, reduce,
;; accept, shift-reduce conflict or reduce-reduce conflict.
;; The actions take the form:
;; @example
;; (shift . <dst-state>)
;; (reduce . <rule-index>)
;; (accept . 0)
;; (srconf . (<dst-state> . <p-rule>))
;; (rrconf . <list of p-rules indices>)
;; @end example
;; If a shift has multiple reduce conflicts we report only one reduction.
(define (gen-pat sft-al red-al)
  (let iter ((res '()) (sal sft-al) (ral red-al))
    (cond
     ((pair? sal)
      (let* ((term (caar sal))		 ; terminal 
	     (goto (cdar sal))		 ; target state
	     (redp (assq term ral))	 ; a-list entry, may be removed
	     ;;(redl (if redp (cdr redp) #f))) ; reductions on terminal
	     (redl (and=> redp cdr)))	; reductions on terminal
	(cond
	 ((and redl (pair? (cdr redl)))
	  ;; This means we have a shift-reduce and reduce-reduce conflicts.
	  ;; We record only one shift-reduce and keep the reduce-reduce.
	  (iter (cons (cons* term 'srconf goto (car redl)) res)
		(cdr sal) ral))
	 (redl
	  ;; The terminal (aka token) signals a single reduction.  This means
	  ;; we have one shift-reduce conflict.  We have a chance to repair
	  ;; the parser using precedence/associativity rules so we remove the
	  ;; reduction from the reduction-list.
	  (iter (cons (cons* term 'srconf goto (car redl)) res)
		(cdr sal) (remove redp ral)))
	 (else
	  ;; The terminal (aka token) signals a shift only.
	  (iter (cons (cons* term 'shift goto) res)
		(cdr sal) ral)))))
     ((pair? ral)
      (let ((term (caar ral)) (rest (cdar ral)))
	;; We keep 'accept as explict action.  Another option is to reduce and
	;; have 0-th p-rule action generate return from parser (via prompt?).
	(iter
	 (cons (cons term
		     (cond ;; => action and arg(s)
		      ((zero? (car rest)) (cons 'accept 0))
		      ((zero? (car rest)) (cons 'reduce (car rest)))
		      ((> (length rest) 1) (cons 'rrconf rest))
		      (else (cons 'reduce (car rest)))))
	       res) sal (cdr ral))))
     (else res))))



;; This is a helper for step4.
(define (prev-symb act its)
  (let* ((a act)
	 (tok (car a)) (sft (caddr a)) (red (cdddr a))
	 ;; @code{pit} is the end-item in the p-rule to be reduced.
	 (pit (prev-item (prev-item (cons red -1))))
	 ;; @code{psy} is the last symbol in the p-rule to be reduced.
	 (psy (looking-at pit)))
    psy))

;; @item step4 subm => more-subm
;; This generates the parse action table from the itemsets and then applies
;; precedence and associativity rules to eliminate shift-reduce conflicts
;; where possible.  The output includes the parse action table (entry
;; @code{'pat-v} and TBD (list of errors in @code{'err-l}).
;;.per-state: alist by symbol:
;;   (symb <id>) if <id> > 0 SHIFT to <id>, else REDUCE by <id> else
;; so ('$end . 0) means ACCEPT!
;; but 0 for SHIFT and REDUCE, but reduce 0 is really ACCEPT
;; if reduce by zero we are done. so never hit state zero accept on ACCEPT?
;; For each state, the element of pat-v looks like
;; ((tokenA . (reduce . 79)) (tokenB . (reduce . 91)) ... )
(define (step4 subm)
  (let* ((kis-v (assq-ref subm 'kis-v)) ; states
	 (kit-v (assq-ref subm 'kit-v)) ; la-toks
	 (kix-v (assq-ref subm 'kix-v)) ; transitions
	 (assc (assq-ref subm 'assc))	 ; associativity rules
	 (prec (assq-ref subm 'prec))	 ; precedence rules
	 (nst (vector-length kis-v))	 ; number of states
	 (pat-v (make-vector nst '()))	 ; parse-action table per state
	 (rat-v (make-vector nst '()))	 ; removed-action table per state
	 (gen-pat-ix (lambda (ix)	 ; pat from shifts and reduc's
		       (gen-pat (vector-ref kix-v ix) (reductions kit-v ix))))
	 )
    ;; We run through each itemset.
    ;; @enumerate
    ;; @item We have a-list of symbols to shift state (i.e., @code{kix-v}).
    ;; @item We generate a list of tokens to reduction from @code{kit-v}.
    ;; @end enumerate
    ;; Q: should '$end be edited out of shifts?
    ;; kit-v is vec of a-lists of form ((item tok1 tok2 ...) ...)
    ;; turn to (tok1 item1 item2 ...)
    (let iter ((ix 0)		; state index
	       (pat '())	; parse-action table
	       (rat '())	; removed-action table
	       (wrn '())	; warnings on unsolicited removals
	       (ftl '())	; fatal conflicts
	       (actl (gen-pat-ix 0))) ; action list
      (cond
       ((pair? actl)
	(case (cadar actl)
	  ((shift reduce accept)
	   (iter ix (cons (car actl) pat) rat wrn ftl (cdr actl)))
	  ((srconf)
	   (let* ((act (car actl))
		  (tok (car act)) (sft (caddr act)) (red (cdddr act))
		  (psy (prev-symb act (vector-ref kis-v ix)))
		  (pre (prece psy tok prec))
		  (sft-a (cons* tok 'shift sft))
		  (red-a (cons* tok 'reduce red)))
	     (call-with-values
		 (lambda ()
		   ;; If precedence applies use that else use associativity.
		   (case pre ;; precedence
		     ((#\=) ;; use associativity
		      (case (assq-ref assc tok)
			((left)
			 (values red-a (cons sft-a 'ass) #f #f))
			((right)
			 (values sft-a (cons red-a 'ass) #f #f))
			((nonassoc)
			 (values (cons* tok 'error red) #f #f (cons ix act)))
			(else
			 (values sft-a (cons red-a 'def) (cons ix act) #f))))
		     ((#\>)
		      (values red-a (cons sft-a 'pre) #f #f))
		     ((#\<)
		      (values sft-a (cons red-a 'pre) #f #f))
		     (else
		      (values sft-a (cons red-a 'pre) (cons ix act) #f))))
	       (lambda (a r w f)
		 (iter ix
		       (if a (cons a pat) pat)
		       (if r (cons r rat) rat)
		       (if w (cons w wrn) wrn)
		       (if f (cons f ftl) ftl)
		       (cdr actl))))))
	  ((rrconf)
	   (fmterr "*** reduce-reduce conflict: in state ~A on ~A: ~A\n"
		   ix (caar actl) (cddar actl))
	   (iter ix (cons (car actl) pat) rat wrn
		 (cons (cons ix (car actl)) ftl) (cdr actl)))
	  (else
	   (error "PROBLEM"))))
       ((null? actl)
	(vector-set! pat-v ix pat)
	(vector-set! rat-v ix rat)
	(iter ix pat rat wrn ftl #f))
       ((< (1+ ix) nst)
	(iter (1+ ix) '() '() wrn ftl (gen-pat-ix (1+ ix))))
       (else
	(let* ((attr (assq-ref subm 'attr))
	       (expect (assq-ref attr 'expect))) ; expected # srconf
	  (if (not (= (length wrn) expect))
	      (for-each (lambda (m) (fmterr "+++ warning: ~A\n" (conf->str m)))
			(reverse wrn)))
	  (for-each (lambda (m) (fmterr "*** fatal  : ~S\n" m))
		    (reverse ftl))
	))))
    ;; Return mach with parse-action and removed-action tables.
    (cons* (cons 'pat-v pat-v) (cons 'rat-v rat-v) subm)))

;; @item conf->str cfl => string
;; map conflict (e.g., @code{('rrconf 1 . 2}) to string.
(define (conf->str cfl)
  (let* ((st (list-ref cfl 0)) (tok (list-ref cfl 1)) (typ (list-ref cfl 2))
	 (core (fluid-ref *lalr-core*)) (terms (core-terminals core)))
    (fmtstr "in state ~A, ~A conflict on ~A"
	    st
	    (case typ
	      ((srconf) "shift-reduce")
	      ((rrconf) "reduce-reduce")
	      (else "unknown"))
	    (obj->str (find-terminal tok terms)))))
		     
;; @item gen-match-table mach => mach
;; Generate the match-table for a machine.  The match-table may be passed to
;; the lexical analyzer builder to identify strings or string-types as tokens.
;; Key is @code{mtab}.  The format is as follows
;; @enumerate
;; @item
;; @sc{nyacc}-reserved symbols are provided as symbols
;; @example
;; $symbol -> ($symbol . $symbol)
;; @end example
;; @item
;; Terminals used as symbols (@code{'comment} versus @code{"comment"}) are
;; provided as symbols.  The spec parser should warn if symbols are used in
;; both ways.  (This is a conflict.)
;; @item
;; Others are provided as strings.
;; @end enumerate
;; The procedure @code{hashify-machine} will convert the cdrs to integers.
;; Test: "$abc" => ("$abc" '$abc) '$abc => ('$abc . '$abc)
;; FIX: need to return to old-gen-match-table and make lexer sync up with that.
(define (old1-gen-match-table mach)
  (let ((terminals (assq-ref mach 'terminals)))
    (cons*
     (cons 'mtab
	   (let iter ((mt '(($default . $default) ($error . $error)))
		      (tl terminals))
	     (if (null? tl) (reverse mt)
		 (let* ((tok (car tl))
			(str (if (symbol? tok) (symbol->string tok) #f))
			(rez (and str (eqv? #\$ (string-ref str 0)))))
		   (iter (acons (cond (rez tok) (str str) (else tok))
				(atomize tok)
				mt)
			 (cdr tl))))))
     mach)))
(define (old2-gen-match-table mach)
  (let ((terminals (assq-ref mach 'terminals)))
    (cons*
     (cons 'mtab
	   (let iter ((mt '(($default . $default) ($error . $error)))
		      (tl terminals))
	     (if (null? tl) (reverse mt)
		 (let* ((tok (car tl))
			(str (cond
			      ((symbol? tok) (symbol->string tok))
			      ((char? tok) (list->string (list tok)))
			      (else tok)))
			(rez (and (symbol? tok) (eqv? #\$ (string-ref str 0)))))
		   (iter (acons (if rez tok str) (atomize tok) mt)(cdr tl))))))
     mach)))
(define (gen-match-table mach)
  (cons
   (cons 'mtab (map (lambda (term) (cons term (atomize term)))
		    (assq-ref mach 'terminals)))
   mach))
(define (old4-gen-match-table mach)
  (acons
   'mtab (fold (lambda (term seed) (cons (cons term (atomize term)) seed))
	       '(($default . $default))
	       (assq-ref mach 'terminals))
   mach))

;; @item lalr-match-table mach => match-table
;; Get the match-table
(define (lalr-match-table mach)
  (assq-ref mach 'mtab))

;; @item compact-machine mach [#:keep 3] => mach
;; A "filter" to compact the parse table.
(define* (compact-machine mach #:key (keep 3))
  (let* ((pat-v (assq-ref mach 'pat-v))
	 (nst (vector-length pat-v))
	 (hashed (number? (caar (vector-ref pat-v 0)))) ; been hashified?
	 (reduce? (if hashed
		      (lambda (a) (negative? a))
		      (lambda (a) (eq? 'reduce (car a)))))
	 (reduce-pr (if hashed abs cdr))
	 (reduce-to? (if hashed
			 (lambda (a r) (eqv? (- r) a))
			 (lambda (a r) (and (eq? 'reduce (car a))
					    (eqv? r (cdr a))))))
	 (mk-default (if hashed
			 (lambda (r) (cons -1 (- r)))
			 (lambda (r) `($default reduce . ,r))))
	 )
    (let iter ((sx nst) (trn-l #f) (cnt-al '()) (p-max '(0 . 0)))
      (cond
       ((pair? trn-l)
	;;(if (not (eq? 'reduce (cadar trn-l)))
	(if (not (reduce? (cdar trn-l)))
	    (iter sx (cdr trn-l) cnt-al p-max)
	    (let* ((ix (reduce-pr (cdar trn-l)))
		   ;;(ix (cddar trn-l))
		   (cnt (1+ (or (assq-ref cnt-al ix) 0)))
		   (cnt-p (cons ix cnt)))
	      (iter sx (cdr trn-l) (cons cnt-p cnt-al)
		    (if (> cnt (cdr p-max)) cnt-p p-max)))))
	      
       ((null? trn-l)
	;; If more than @code{keep} common reductions then generate default
	;; rule to replace those.
	(if (> (cdr p-max) keep)
	    (vector-set!
	     pat-v sx
	     (fold-right
	      (lambda (trn pat)
		;;(if (equal? (cdr trn) `(reduce . ,(car p-max))) pat
		(if (reduce-to? (cdr trn) (car p-max)) pat (cons trn pat)))
	      ;;(list `($default reduce . ,(car p-max))) ;; default is last
	      (list (mk-default (car p-max))) ;; default is last
	      (vector-ref pat-v sx))))
	(iter sx #f #f #f))
       ((positive? sx) ;; next state
	(iter (1- sx) (vector-ref pat-v (1- sx)) '() '(0 . 0)))))
    mach))

;; @item machine-compacted? mach => #t|#f
;; Indicate if the machine has been compacted.
(define (machine-compacted? mach)
  ;; Works by searching for $default phony-token.
  (call-with-prompt
   'got-it
   (lambda ()
     (vector-for-each
      (lambda (ix pat)
	(for-each
	 (lambda (a) (if (or (eqv? (car a) '$default) (eqv? (car a) -1))
			 (abort-to-prompt 'got-it)))
	 pat))
      (assq-ref mach 'pat-v))
     #f) ;; default not found
   (lambda () #t))) ;; default found

;; to build parser, need:
;;   pat-v - parse action table
;;   ref-v - references
;;   nrg-v - number of args
;;   len-v - rule lengths
;;   rto-v - rule lengths
;; to print itemsets need:
;;   kis-v - itemsets
;;   lhs-v - left hand sides
;;   rhs-v - right hand sides
;;   pat-v - action table

;; @item make-lalr-machine spec => pgen
;; Generate a-list of items used for building/debugging parsers.
;; It might be useful to add hashify and compact with keyword arguments.
(define (make-lalr-machine spec)
  (let ((prev-core (fluid-ref *lalr-core*)))
    (dynamic-wind
	(lambda () (fluid-set! *lalr-core* (make-core/eps spec)))
	(lambda ()
	  ;; build up "sub-machines"
	  (let* ((sm1 (step1 spec))
		 (sm2 (step2 sm1))
		 (sm3 (step3 sm2))
		 (sm4 (step4 sm3))
		 (sm5 (gen-match-table sm4))
		 (sm9 sm5))
	    (cons*
	     (cons 'len-v (vector-map (lambda (i v) (vector-length v))
				      (assq-ref sm9 'rhs-v)))
	     (cons 'rto-v (vector-copy (assq-ref sm9 'lhs-v)))
	     sm9)))
	(lambda () (fluid-set! *lalr-core* prev-core)))))

;; @item elt->str elt terms => string
(define (elt->str elt terms)
  (or (and=> (find-terminal elt terms) obj->str)
      (symbol->string elt)))

;; @item pp-rule indent gx [port]
;; Pretty-print a production rule.
(define (pp-rule il gx . rest)
  (let* ((port (if (pair? rest) (car rest) (current-output-port)))
	 (core (fluid-ref *lalr-core*))
	 (lhs (vector-ref (core-lhs-v core) gx))
	 (rhs (vector-ref (core-rhs-v core) gx))
	 (tl (core-terminals core)))
    (display (substring "                     " 0 (min il 20)) port)
    (fmt port "~A =>" lhs)
    (vector-for-each (lambda (ix e) (fmt port " ~A" (elt->str e tl))) rhs)
    (newline port)))
	 
;; @item pp-item item => string
;; This could be called item->string.
;; This needs terminals to work correctly, like pp-lalr-grammar.
(define (pp-item item) 
  (let* ((core (fluid-ref *lalr-core*))
	 (tl (core-terminals core))
	 (gx (car item))
	 (lhs (vector-ref (core-lhs-v core) gx))
	 (rhs (vector-ref (core-rhs-v core) gx))
	 (rhs-len (vector-length rhs)))
    (apply
     string-append
     (let iter ((rx 0) (sl (list (fmtstr "~S =>" lhs))))
       (if (= rx rhs-len)
	   (append sl (if (= -1 (cdr item)) '(" .") '()))
	   (iter (1+ rx)
		 (append
		  sl (if (= rx (cdr item)) '(" .") '())
		  (let ((e (vector-ref rhs rx)))
		    (list (string-append " " (elt->str e tl)))))))))))

;; @item pp-lalr-grammar spec [port]
;; Pretty-print the grammar to the specified port, or current output.
(define (pp-lalr-grammar spec . rest)
  (let* ((port (if (pair? rest) (car rest) (current-output-port)))
	 (lhs-v (assq-ref spec 'lhs-v))
	 (rhs-v (assq-ref spec 'rhs-v))
	 (nrule (vector-length lhs-v))
	 (act-v (assq-ref spec 'act-v))
	 (terms (assq-ref spec 'terminals))
	 (prev-core (fluid-ref *lalr-core*)))
    (fluid-set! *lalr-core* (make-core spec)) ; OR dynamic-wind ???
    ;; Print out the grammar.
    (do ((i 0 (1+ i))) ((= i nrule))
      (let* ((lhs (vector-ref lhs-v i)) (rhs (vector-ref rhs-v i)))
	(if #f
	    (pp-rule 0 i)
	    (begin
	      (fmt port "~A ~A =>" i lhs)
	      (vector-for-each
	       (lambda (ix e) (fmt port " ~A" (elt->str e terms)))
	       rhs)
	      ;;(fmt port "\t~S" (vector-ref act-v i))
	      (newline port)))))
    (newline port)
    (fluid-set! *lalr-core* prev-core)))

;; @item pp-lalr-machine mach [port]
;; Print the states of the parser with items and shift/reduce actions.
(define (pp-lalr-machine mach . rest)
  (let* ((port (if (pair? rest) (car rest) (current-output-port)))
	 (lhs-v (assq-ref mach 'lhs-v))
	 (rhs-v (assq-ref mach 'rhs-v))
	 (nrule (vector-length lhs-v))
	 (act-v (assq-ref mach 'act-v))
	 (pat-v (assq-ref mach 'pat-v))
	 (rat-v (assq-ref mach 'rat-v))
	 (kis-v (assq-ref mach 'kis-v))
	 (kit-v (assq-ref mach 'kit-v))
	 (nst (vector-length kis-v))	; number of states
	 (i->s (or (and=> (assq-ref mach 'siis) cdr) '()))
	 (terms (assq-ref mach 'terminals))
	 (prev-core (fluid-ref *lalr-core*)))
    (fluid-set! *lalr-core* (make-core mach))
    ;; Print out the itemsets and shift reduce actions.
    (do ((i 0 (1+ i))) ((= i nst))
      (let* ((state (vector-ref kis-v i))
	     (pat (vector-ref pat-v i))
	     (rat (vector-ref rat-v i)))
	(fmt port "~A:" i)	; itemset index (aka state index)
	(for-each
	 (lambda (k-item)
	   (for-each			; item, print it
	    (lambda (item)
	      (fmt port "\t~A" (pp-item item))
	      (if (equal? item k-item)
		  (fmt port " ~A"
		       (map (lambda (tok) (elt->str tok terms))
			    (assoc-ref (vector-ref kit-v i) k-item))))
	      (fmt port "\n"))
	    (expand-k-item k-item)))
	 state)
	(for-each			; action, print it
	 (lambda (act)
	   (if (pair? (cdr act))
	       (let ((sy (car act)) (pa (cadr act)) (gt (cddr act)))
		 (case pa
		   ((srconf)
		    (fmt port "\t\t~S => CONFLICT: shift ~A, reduce ~A\n" sy
			 (car gt) (cdr gt)))
		   ((rrconf)
		    (fmt port "\t\t~S => CONFLICT: reduce ~A\n" sy
			 (string-join (map number->string gt) ", reduce ")))
		   (else
		    (fmt port "\t\t~A => ~A ~A\n" (elt->str sy terms) pa gt))))
	       (let* ((sy (car act)) (p (cdr act))
		      (pa (cond ((positive? p) 'shift)
				((negative? p) 'reduce)
				(else 'accept)))
		      (gt (abs p)))
		 (fmt port "\t\t~A => ~A ~A\n"
		      (elt->str (assq-ref i->s sy) terms)
		      pa gt))))
	 pat)
	(for-each			; action, print it
	 (lambda (ra)
	   ;; FIX: should indicate if precedence removed user rule or default
	   (fmt port "\t\t[~A => ~A ~A] REMOVED by ~A\n"
		(elt->str (caar ra) terms) (cadar ra) (cddar ra)
		(case (cdr ra)
		  ((pre) "precedence")
		  ((ass) "associativity")
		  ((def) "default shift")
		  (else (cdr ra)))))
	 rat)
	(newline)))
    (fluid-set! *lalr-core* prev-core)
    (values)))

;;.@section Using hash tables
;; The lexical analyzer will generate tokens.  The parser generates state
;; transitions based on these tokens.  When we build a lexical analyzer
;; (via @code{make-lexer}) we provide a list of strings to detect along with
;; associated tokens to return to the parser.  By default the tokens returned
;; are symbols or characters.  But these could as well be integers.  Also,
;; the parser uses symbols to represent non-terminals, which are also used
;; to trigger state transitions.  We could use integers instead of symbols
;; and characters by mapping via a hash table.   We will bla bla bla.
;; There are also standard tokens we need to worry about.  These are
;; @enumerate
;; @item the @code{$end} marker
;; @item identifiers (using the symbolic token @code{$ident}
;; @item non-negative integers (using the symbolic token @code{$fx})
;; @item non-negative floats (using the symbolic token @code{$fl})
;; @item @code{$default} => 0
;; @end enumerate
;; And action
;; @enumerate
;; @item positive => shift
;; @item negative => reduce
;; @item zero => accept
;; @end enumerate
;; However, if these are used they should appear in the spec's terminal list.
;; For the hash table we use positive integers for terminals and negative
;; integers for non-terminals.  To apply such a hash table we need to:
;; @enumerate
;; @item from the spec's list of terminals (aka tokens), generate a list of
;; terminal to integer pairs (and vice versa)
;; @item from the spec's list of non-terminals generate a list of symbols
;; to integers and vice versa.
;; @item Go through the parser-action table and convert symbols and characters
;; to integers
;; @item Go through the XXX list passed to the lexical analyizer and replace
;; symbols and characters with integers.
;; @end enumerate
;; One issue we need to deal with is separating out the identifier-like
;; terminals (aka keywords) from those that are not identifier-like.  I guess
;; this should be done as part of @code{make-lexer}, by filtering the token
;; list through the ident-reader.
;; NOTE: The parser is hardcoded to assume that the phony token for the
;; default action is @code{'$default} for unhashed machine or @code{-1} for
;; a hashed machine.
;; @item hashify-machine mach => mach
(define (hashify-machine mach)
  (let* ((terminals (assq-ref mach 'terminals))
	 (non-terms (assq-ref mach 'non-terms))
	 (lhs-v (assq-ref mach 'lhs-v))
	 (sm ;; symbol-to-int int-to-symbol maps
	  (let iter ((si (list (cons '$default -1)))
		     (is (list (cons -1 '$default)))
		     (ix 1) (tl terminals) (nl non-terms))
	    (if (null? nl) (cons (reverse si) (reverse is))
		(let* ((s (atomize (if (pair? tl) (car tl) (car nl))))
		       (tl1 (if (pair? tl) (cdr tl) tl))
		       (nl1 (if (pair? tl) nl (cdr nl))))
		  (iter (acons s ix si) (acons ix s is) (1+ ix) tl1 nl1)))))
	 (sym->int (lambda (s) (assq-ref (car sm) s)))
	 ;;
	 (old-pat-v (assq-ref mach 'pat-v))
	 (npat (vector-length old-pat-v))
	 (new-pat-v (make-vector npat)))
    ;; wtf is this for?
    ;;(let iter1 ((ix 0)) (unless (= ix npat) (iter1 (1+ ix))))
    ;; replace symbol/chars with integers
    (let iter1 ((ix 0))
      (unless (= ix npat)
	;;(if (zero? ix) (fmtout "~S\n" (vector-ref old-pat-v ix)))
	(let iter2 ((al1 '()) (al0 (vector-ref old-pat-v ix)))
	  (if (null? al0) (vector-set! new-pat-v ix (reverse al1))
	      (let* ((a0 (car al0))
		     ;; tk: token; ac: action; ds: destination
		     (tk (car a0)) (ac (cadr a0)) (ds (cddr a0))
		     ;; t: encoded token; d: encoded destination
		     (t (sym->int tk))
		     (d (case ac ((shift) ds) ((reduce) (- ds)) ((accept) 0))))
		(unless t
		  (fmterr "~S ~S ~S\n" tk ac ds) 
		  (error "expect something"))
		(iter2 (acons t d al1) (cdr al0)))))
	(iter1 (1+ ix))))
    ;;
    (cons*
     (cons 'pat-v new-pat-v)
     (cons 'siis sm)			; (cons al:sym->int al:int->sym)
     (cons 'mtab
	   (let iter ((mt1 '()) (mt0 (assq-ref mach 'mtab)))
	     (if (null? mt0) (reverse mt1)
		 (iter (cons (cons (caar mt0) (sym->int (cdar mt0))) mt1)
		       (cdr mt0)))))
     ;; reduction symbols = lhs:
     (cons 'rto-v (vector-map (lambda (i v) (sym->int v)) lhs-v))
     mach)))

;; @item (machine-hashed? mach) => #t|#f
;; Indicate if the machine has been hashed.
(define (machine-hashed? mach)
  (number? (caar (vector-ref (assq-ref mach 'pat-v) 0))))

;; @item make-arg-list N => '($N $Nm1 $Nm2 ... $1 . $rest)
;; This is a helper for @code{mkact}.
(define (make-arg-list n)
  (let ((mkarg
	 (lambda (i) (string->symbol (string-append "$" (number->string i))))))
    (let iter ((r '(. $rest)) (i 1))
      (if (> i n) r (iter (cons (mkarg i) r) (1+ i))))))

;; @item wrap-action n act => `(lambda ($n ... $2 $1 . $rest) ,@act)
;; Wrap user-specified action (body, as list) of n arguments in a lambda.
;; The rationale for the arglist format is that we can @code{apply} this
;; lambda to the the semantic stack.
(define (wrap-action n act)
  (cons* 'lambda (make-arg-list n) act))

;; @item make-lalr-parser mach => parser
;; This generates a procedure that takes one argument, a lexical analyzer:
;; @example
;; (parser lexical-analyzer [#:debug #t])
;; @end example
;; and is used as
;; @example
;; (define xyz-parse (make-lalr-parser xyz-mach))
;; (with-input-from-file "sourcefile.xyz" (lambda () (xyz-parse (gen-lexer))))
;; @end example
;; The generated parser is reentrant.
(define* (make-lalr-parser mach)
  (let* ((len-v (assq-ref mach 'len-v))
	 (rto-v (assq-ref mach 'rto-v))	; reduce to
	 (pat-v (assq-ref mach 'pat-v))
	 (sya-v (vector-map ;; symbolic action
		 (lambda (ix nrg guts) (wrap-action nrg guts))
		 (assq-ref mach 'nrg-v) (assq-ref mach 'act-v)))
	 ;; Turn symbolic action into executable procedures:
	 (act-v (vector-map (lambda (ix f) (eval f (current-module))) sya-v))
	 ;;
	 (dmsg (lambda (s t a) (fmtout "state ~S, token ~S\t=> ~S\n" s t a)))
	 (hashed (number? (caar (vector-ref pat-v 0)))) ; been hashified?
	 ;;(def (assq-ref (assq-ref mach 'mtab) '$default))
	 (def (if hashed -1 '$default))
	 ;; predicate to test for shift action:
	 (shift? (if hashed
		     (lambda (a) (positive? a))
		     (lambda (a) (eq? 'shift (car a)))))
	 ;; On shift, transition to this state:
	 (shift-to (if hashed (lambda (x) x) (lambda (x) (cdr x))))
	 ;; predicate to test for reduce action:
	 (reduce? (if hashed
		      (lambda (a) (negative? a))
		      (lambda (a) (eq? 'reduce (car a)))))
	 ;; On reduce, reduce this production-rule:
	 ;;(reduce-pr (if hashed (lambda (a) (abs a)) (lambda (a) (cdr a))))
	 (reduce-pr (if hashed abs cdr))
	 ;; If no action found in transition list, then this:
	 (parse-error (if hashed #f (cons 'error 0)))
	 ;; predicate to test for error
	 (error? (if hashed
		     (lambda (a) (eq? #f a))
		     (lambda (a) (eq? 'error (car a)))))
	 )
    (lambda* (lexr #:key debug)
      (let iter ((state (list 0))	; state stack
		 (stack (list '$@))	; sval stack
		 (nval #f)		; prev reduce to non-term val
		 (lval (lexr)))		; lexical value (from lex'er)
	(let* ((tval (car (if nval nval lval))) ; token (syntax value)
	       (sval (cdr (if nval nval lval))) ; semantic value
	       (stxl (vector-ref pat-v (car state))) ; state transition list
	       (stx (or (assq-ref stxl tval) ; trans action (e.g. shift 32)
			(assq-ref stxl def)  ; default action
			parse-error)))
	  (when debug (dmsg (car state) (if nval tval sval) stx))
	  (cond
	   ((error? stx)
	    ;; Ugly to have to check this first every time, but
	    ;; @code{positive?} and @code{negative?} fail otherwise.
	    (let ((fn (or (port-filename (current-input-port)) "(unknown)"))
		  (ln (1+ (port-line (current-input-port)))))
	      (fmterr "~A: ~A: parse failed at state ~A, on input ~S\n"
		      fn ln (car state) sval))
	    #f)
	   ((shift? stx)
	    ;; We could check here to determine if next transition only has a
	    ;; default reduction and, if so, go ahead and process the reduction
	    ;; without reading another input token.  Needed for interactive.
	    (iter (cons (shift-to stx) state) (cons sval stack)
		  #f (if nval lval (lexr))))
	   ((reduce? stx)
	    (let* ((gx (reduce-pr stx)) (gl (vector-ref len-v gx))
		   ($$ (apply (vector-ref act-v gx) stack)))
	      (iter (list-tail state gl) 
		    (list-tail stack gl)
		    (cons (vector-ref rto-v gx) $$)
		    lval)))
	   (else ;; accept
	    (car stack))))))))


(use-modules (ice-9 pretty-print))
(use-modules (ice-9 regex))

;; @item write-lalr-tables mach filename [#:lang output-lang]
;; For example,
;; @example
;; write-lalr-tables mach "tables.scm"
;; write-lalr-tables mach "tables.tcl" #:lang 'tcl
;; @end example
(define* (write-lalr-tables mach filename #:key (lang 'scheme))

  (define (write-table mach name port)
    (fmt port "(define ~A\n  " name)
    (ugly-print (assq-ref mach name) port)
    (fmt port ")\n\n"))

  (define (pp-rule/ts gx)
    (let* ((core (fluid-ref *lalr-core*))
	   (lhs (vector-ref (core-lhs-v core) gx))
	   (rhs (vector-ref (core-rhs-v core) gx))
	   (tl (core-terminals core))
	   (line (string-append
		  (symbol->string lhs) " => "
		  (string-join 
		   (map (lambda (elt) (elt->str elt tl))
			(vector->list rhs))
		   " "))))
      (if (> (string-length line) 72)
	  (string-append (substring/shared line 0 69) "...")
	  line)))
    
  (define (write-actions mach port)
    (with-fluid*
     *lalr-core* (make-core mach)
     (lambda ()
       (fmt port "(define act-v\n  (vector\n")
       (vector-for-each
	(lambda (ix nrg act)
	  (fmt port "   ;; ~A\n" (pp-rule/ts ix))
	  (pretty-print (wrap-action nrg act) port #:per-line-prefix "   "))
	(assq-ref mach 'nrg-v) (assq-ref mach 'act-v))
       (fmt port "   ))\n\n"))))

  (call-with-output-file filename
    (lambda (port)
      (fmt port ";; ~A\n\n"
	   (regexp-substitute #f (string-match ".new$" filename) 'pre))
      (write-table mach 'len-v port)
      (write-table mach 'pat-v port)
      (write-table mach 'rto-v port)
      (write-table mach 'mtab port)
      (write-actions mach port)
      (display ";;; end tables" port)
      (newline port))))

#;(define (write-lalr-tables-in-tcl mach filename)

  (define (write-table mach name port)
    (fmt port "(define ~A\n  " name)
    (ugly-print-to-tcl (assq-ref mach name) port)
    (fmt port ")\n\n"))
			
  (call-with-output-file filename
    (lambda (port)
      (fmt port ";; ~A\n\n"
	   (regexp-substitute #f (string-match ".new$" filename) 'pre))
      (write-table mach 'len-v port)
      )))

;; @end itemize

;;; --- last line