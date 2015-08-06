;; Tlangc.scm - clang dev
;;
;; Copyright (C) 2015 Matthew R. Wette
;; 
;; Copying and distribution of this file, with or without modification,
;; are permitted in any medium without royalty provided the copyright
;; notice and this notice are preserved.  This file is offered as-is,
;; without any warranty.

(add-to-load-path (getcwd))
(add-to-load-path (string-append (getcwd) "/../../module"))

(use-modules (lang c pgen))
(use-modules (nyacc lalr))
(use-modules (nyacc lex))
(use-modules (nyacc export))
(use-modules (sxml simple))
(use-modules (ice-9 pretty-print))

(with-output-to-file "lang/c/lang.txt.new"
  (lambda ()
    (pp-lalr-grammar clang-spec)
    (pp-lalr-machine clang-mach)))
(with-output-to-file "lang/c/gram.y.new"
  (lambda () (lalr->bison clang-spec)))
(write-lalr-tables clang-mach "lang/c/tables.scm.new")

(define defs '((arch . "x86_64")))
(define incs '("." "lang/c"))

(let ((sx (with-input-from-file "lang/c/ex1.c"
	    (lambda () (parse-c #:cpp-defs defs #:inc-dirs incs)))))
  (pretty-print sx)
  ;;(sxml->xml sx) (newline)
  #f)

;; --- last line