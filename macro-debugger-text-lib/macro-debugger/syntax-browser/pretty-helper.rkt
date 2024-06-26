#lang racket/base
(require racket/pretty
         racket/class/iop
         racket/struct
         syntax/stx
         "../model/stx-util.rkt"
         "partition.rkt")
(provide (all-defined-out))

;; Problem: If stx1 and stx2 are two distinguishable syntax objects, it
;; still may be the case that (syntax-e stx1) and (syntax-e stx2) are 
;; indistinguishable.

;; Solution: Rather than map stx to (syntax-e stx), in the cases where
;; (syntax-e stx) is confusable, map it to a different, unique, value.
;; Use syntax-dummy, and extend pretty-print-remap-stylable to look inside.

;; Old solution: same, except map identifiers to uninterned symbols instead

;; NOTE: Nulls are only wrapped when *not* list-terminators.  
;; If they were always wrapped, the pretty-printer would screw up
;; list printing (I think).

;; UPDATE: In fact, want to treat all atomic values as confusable. The recent
;; reader change (interning strings, etc) highlights the issue.

(define PRINT-PROTECTION? #t)
(define show-taint-info? (make-parameter #f))

(struct wrapped-stx (contents mode)
  #:property prop:custom-write
  (lambda (self out mode)
    (fprintf out "~a" (wrapped-mode-prefix (wrapped-stx-mode self)))
    (fprintf out "~s" (wrapped-stx-contents self))))

(define (wrapped-mode-prefix mode)
  (case mode
    [(armed) "🔒"]
    [(armed-unlocked) "🔓"]
    [(tainted) "💥"]
    [else " "]))

(define (syntax-armed-unlocked? stx)
  (and (syntax? stx) (syntax-property stx property:unlocked-by-expander)))

(define (syntax-armed? stx)
  (and (syntax? stx) (not (syntax-tainted? stx)) (syntax-tainted? (datum->syntax stx #f))))

(define (pretty-print/defaults datum [port (current-output-port)])
  (parameterize
    (;; Printing parameters (defaults from MzScheme and DrScheme 4.2.2.2)
     [print-unreadable #t]
     [print-graph #f]
     [print-struct #t]
     [print-box #t]
     [print-vector-length #f]
     [print-hash-table #t])
    (pretty-write datum port)))

(define-struct syntax-dummy (val))
(define-struct (id-syntax-dummy syntax-dummy) (remap))

;; A SuffixOption is one of
;; - 'never             -- never
;; - 'always            -- suffix > 0
;; - 'over-limit        -- suffix > limit
;; - 'all-if-over-limit -- suffix > 0 if any over limit

;; syntax->datum/tables : stx partition% num SuffixOption
;;                        -> (values s-expr hashtable hashtable)
;; When partition is not false, tracks the partititions that subterms belong to
;; When limit is a number, restarts processing with numbering? set to true
;; 
;; Returns three values:
;;   - an S-expression
;;   - a hashtable mapping S-expressions to syntax objects
;;   - a hashtable mapping syntax objects to S-expressions
;; Syntax objects which are eq? will map to same flat values
(define (syntax->datum/tables stx partition limit suffixopt abbrev?
                              #:taint-icons? [taint-icons? #f])
  (parameterize ((show-taint-info? taint-icons?))
    (table stx partition limit suffixopt abbrev?)))

;; table : syntax maybe-partition% maybe-num SuffixOption boolean -> (values s-expr hashtable hashtable)
(define (table stx partition limit suffixopt abbrev?)
  (define (make-identifier-proxy id)
    (define sym (syntax-e id))
    (case suffixopt
      ((never)
       (make-id-syntax-dummy sym sym))
      ((always)
       (let ([n (send/i partition partition<%> get-partition id)])
         (if (zero? n)
             (make-id-syntax-dummy sym sym)
             (make-id-syntax-dummy (suffix sym n) sym))))
      ((over-limit)
       (let ([n (send/i partition partition<%> get-partition id)])
         (if (<= n limit)
             (make-id-syntax-dummy sym sym)
             (make-id-syntax-dummy (suffix sym n) sym))))))

  (let/ec escape
    (let ([flat=>stx (make-hasheq)]
          [stx=>flat (make-hasheq)])
      (define (link! stx flat)
        (hash-set! flat=>stx flat stx)
        (hash-set! stx=>flat stx flat)
        flat)
      (define (loop obj)
        (cond [(not (syntax? obj)) (loop* obj)]
              [(not (show-taint-info?)) (link! obj (loop* obj))]
              [(syntax-tainted? obj)
               (parameterize ((show-taint-info? #f))
                 (link! obj (wrapped-stx (loop* obj) 'tainted)))]
              [(syntax-armed-unlocked? obj)
               (link! obj (wrapped-stx (loop* obj) 'armed-unlocked))]
              [(syntax-armed? obj)
               (link! obj (wrapped-stx (loop* obj) 'armed))]
              [else (link! obj (loop* obj))]))
      (define (loop* obj)
        (cond [(hash-ref stx=>flat obj #f)
               => (lambda (datum) datum)]
              [(and partition (identifier? obj))
               (when (and (eq? suffixopt 'all-if-over-limit)
                          (> (send/i partition partition<%> count) limit))
                 (call-with-values (lambda () (table stx partition #f 'always abbrev?))
                                   escape))
               (make-identifier-proxy obj)]
              [(and (syntax? obj) abbrev? (check+convert-special-expression obj))
               => (lambda (newobj)
                    (when partition (send/i partition partition<%> get-partition obj))
                    (let* ([inner (cadr newobj)]
                           [lp-inner-datum (loop inner)])
                      (link! inner lp-inner-datum)
                      (list (car newobj) lp-inner-datum)))]
              [(syntax? obj)
               (when partition (send/i partition partition<%> get-partition obj))
               (loop (syntax-e* obj))]
              ;; -- Traversable structures
              [(pair? obj)
               (pairloop obj)]
              [(prefab-struct-key obj)
               => (lambda (pkey)
                    (let-values ([(refold fields) (unfold-pstruct obj)])
                      (refold (map loop fields))))]
              [(vector? obj) 
               (list->vector (map loop (vector->list obj)))]
              [(box? obj)
               (box (loop (unbox obj)))]
              [(hash? obj)
               (let ([constructor
                      (cond [(hash-equal? obj) make-immutable-hash]
                            [(hash-eqv? obj) make-immutable-hasheqv]
                            [(hash-eq? obj) make-immutable-hasheq]
                            [(hash-equal-always? obj) make-immutable-hashalw])])
                 (constructor
                  (for/list ([(k v) (in-hash obj)])
                    (cons k (loop v)))))]
              ;; -- Atoms ("confusable")
              [(symbol? obj)
               (make-id-syntax-dummy obj obj)]
              [else ;; null, boolean, number, keyword, string, bytes, char, regexp, 3D vals
               (make-syntax-dummy obj)]))
      (define (pairloop obj)
        (cond [(pair? obj)
               (cons (loop (car obj))
                     (pairloop (cdr obj)))]
              [(null? obj)
               null]
              [(and (syntax? obj) (null? (syntax-e obj)))
               null]
              [else (loop obj)]))
      (values (loop stx)
              flat=>stx
              stx=>flat))))

;; unfold-pstruct : prefab-struct -> (values (list -> prefab-struct) list)
(define (unfold-pstruct obj)
  (define key (prefab-struct-key obj))
  (define fields (struct->list obj))
  (values (lambda (new-fields)
            (apply make-prefab-struct key new-fields))
          fields))

;; check+convert-special-expression : syntax -> #f/syntaxish
(define (check+convert-special-expression stx)
  (define stx-list (stx->list* stx))
  (and stx-list (= 2 (length stx-list))
       (let ([kw (car stx-list)]
             [expr (cadr stx-list)])
         (and (identifier? kw)
              (memq (syntax-e kw) special-expression-keywords)
              (bound-identifier=? kw (datum->syntax stx (syntax-e kw)))
              (andmap (lambda (f) (equal? (f stx) (f kw)))
                      (list syntax-source
                            syntax-line
                            syntax-column
                            syntax-position
                            syntax-original?
                            syntax-source-module))
              (cons (syntax-e kw)
                    (list expr))))))

(define special-expression-keywords
  '(quote quasiquote unquote unquote-splicing syntax
    quasisyntax unsyntax unsyntax-splicing))

(define (suffix sym n)
  (string->symbol (format "~a:~a" sym n)))

(define (stx->list* stx)
  (if (stx-list? stx)
      (let loop ([stx stx])
        (cond [(syntax? stx)
               (loop (syntax-e (syntax-disarm stx #f)))]
              [(pair? stx)
               (cons (car stx) (loop (cdr stx)))]
              [else stx]))
      #f))

(define (syntax-e* stx)
  (syntax-e (syntax-disarm stx #f)))
