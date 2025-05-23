#lang racket/base
(require racket/private/place-local
         ffi/unsafe/atomic
         racket/fixnum
         "../compile/serialize-property.rkt"
         "../common/performance.rkt"
         "contract.rkt"
         "parse-module-path.rkt"
         "intern.rkt")

(provide module-path?
         
         resolved-module-path?
         make-resolved-module-path
         resolved-module-path-name
         safe-resolved-module-path-name
         resolved-module-path-root-name
         resolved-module-path->module-path
         
         module-path-index?
         module-path-index-resolve
         module-path-index-fresh
         module-path-index-join
         module-path-index-join*
         module-path-index-split
         module-path-index-submodule
         make-self-module-path-index
         make-generic-self-module-path-index
         imitate-generic-module-path-index!
         module-path-index-shift
         module-path-index-resolved ; returns #f if not yet resolved
         module-path-index-shift/resolved

         top-level-module-path-index
         top-level-module-path-index?
         non-self-module-path-index?
         non-self-derived-module-path-index?

         inside-module-context?

         resolve-module-path
         current-module-name-resolver
         
         current-module-declare-name
         current-module-declare-source
         substitute-module-declare-name
         
         deserialize-module-path-index

         module-path-place-init!)

(module+ for-intern
  (provide (struct-out module-path-index)))

;; ----------------------------------------

(struct resolved-module-path (name)
  #:authentic
  #:property prop:equal+hash
  ;; Although equal resolved module paths are `eq?` externally,
  ;; we need this equality predicate to hash them for the
  ;; interning table
  (list (lambda (a b eql?)
          (eql? (resolved-module-path-name a)
                (resolved-module-path-name b)))
        (lambda (a hash-code)
          (hash-code (resolved-module-path-name a)))
        (lambda (a hash-code)
          (hash-code (resolved-module-path-name a))))
  #:property prop:custom-write
  (lambda (r port mode)
    (when mode
      (write-string "#<resolved-module-path:" port))
    (fprintf port "~a" (format-resolved-module-path-name (resolved-module-path-name r)))
    (when mode
      (write-string ">" port)))
  #:property prop:serialize
  (lambda (r ser-push! state)
    (ser-push! 'tag '#:resolved-module-path)
    (ser-push! (resolved-module-path-name r))))

(define (deserialize-resolved-module-path n)
  (make-resolved-module-path n))

(define (format-resolved-module-path-name p)
  (cond
   [(path? p) (string-append "\"" (path->string p) "\"")]
   [(symbol? p) (format-symbol p)]
   [else (format-submod (format-resolved-module-path-name (car p))
                        (cdr p))]))

(define (format-symbol p)
  (format "'~s~a" p (if (symbol-interned? p)
                        ""
                        (format "[~a]" (eq-hash-code p)))))

(define (format-submod base syms)
  (format "(submod ~a~a)"
          base
          (apply string-append (for/list ([i (in-list syms)])
                                 (format " ~s" i)))))

(define safe-resolved-module-path-name
  (let ([resolved-module-path-name
         (lambda (v)
           (unless (resolved-module-path? v)
             (raise-argument-error 'resolved-module-path-name
                                   "resolved-module-path?"
                                   v))
           (resolved-module-path-name v))])
    resolved-module-path-name))

(define (resolved-module-path-root-name r)
  (define name (resolved-module-path-name r))
  (if (pair? name)
      (car name)
      name))

(define resolved-module-paths (make-weak-intern-table))

(define (make-resolved-module-path p)
  (unless (or (symbol? p)
              (and (path? p) (complete-path? p))
              (and (pair? p)
                   (pair? (cdr p))
                   (list? p)
                   (or (symbol? (car p))
                       (and (path? (car p)) (complete-path? (car p))))
                   (for/and ([s (in-list (cdr p))])
                     (symbol? s))))
    (raise-argument-error 'make-resolved-module-path
                          (string-append
                           "(or/c symbol?\n"
                           "      (and/c path? complete-path?)\n"
                           "      (cons/c (or/c symbol?\n"
                           "                    (and/c path? complete-path?))\n"
                           "              (non-empty-listof symbol?)))")
                          p))
  (weak-intern! resolved-module-paths (resolved-module-path p)))

(define (resolved-module-path->module-path r)
  (define name (resolved-module-path-name r))
  (define root-name (if (pair? name) (car name) name))
  (define root-mod-path (if (path? root-name)
                            root-name
                            `(quote ,root-name)))
  (if (pair? name)
      `(submod ,root-mod-path ,@(cdr name))
      root-mod-path))

;; ----------------------------------------

(struct module-path-index (path base [resolved #:mutable] [shift-cache #:mutable])
  #:authentic
  #:property prop:equal+hash
  (list (lambda (a b eql?)
          (and (eql? (module-path-index-path a)
                     (module-path-index-path b))
               (eql? (module-path-index-base a)
                     (module-path-index-base b))))
        (lambda (a hash-code)
          (+ (hash-code (module-path-index-path a))
             (hash-code (module-path-index-base a))))
        (lambda (a hash-code)
          (+ (hash-code (module-path-index-path a))
             (hash-code (module-path-index-base a)))))
  #:property prop:custom-write
  (lambda (r port mode)
    (write-string "#<module-path-index" port)
    (cond
      [(top-level-module-path-index? r)
       (fprintf port ":top-level")]
      [(module-path-index-path r)
       (define l (let loop ([r r])
                   (cond
                     [(not r) null]
                     [(resolved-module-path? r)
                      (list
                       "+"
                       (format "~a" r))]
                     [(module-path-index-path r)
                      (cons (let loop ([v (module-path-index-path r)])
                              (cond
                                [(and (pair? v)
                                      (eq? 'quote (car v))
                                      (null? (cddr v)))
                                 (format-symbol (cadr v))]
                                [(and (pair? v)
                                      (eq? 'submod (car v)))
                                 (format-submod (loop (cadr v)) (cddr v))]
                                [else
                                 (format "~.s" v)]))
                            (loop (module-path-index-base r)))]
                     [(module-path-index-resolved r)
                      (list
                       "+"
                       (format "~a" (module-path-index-resolved r)))]
                     [else null])))
       (fprintf port ":~.a" (apply string-append
                                   (car l)
                                   (for/list ([i (in-list (cdr l))])
                                     (format " ~a" i))))]
      [(module-path-index-resolved r)
       (fprintf port "=~a" (module-path-index-resolved r))])
    (write-string ">" port)))

(define empty-shift-cache '())

;; Serialization of a module path index is handled specially, because they
;; must be shared across phases of a module
(define deserialize-module-path-index
  (case-lambda
    [(path base) (module-path-index-join* path base)]
    [(name) (make-self-module-path-index (make-resolved-module-path name))]
    [() top-level-module-path-index]))

(define/who (module-path-index-resolve mpi [load? #f] [stx #f])
  (check who module-path-index? mpi)
  (or (module-path-index-resolved mpi)
      (cond
        [(module-path-index-path mpi)
         (let ([mod-name (performance-region
                          ['eval 'resolver]
                          ((current-module-name-resolver)
                           (module-path-index-path mpi)
                           (module-path-index-resolve/maybe
                            (module-path-index-base mpi)
                            load?)
                           stx
                           load?))])
           (unless (resolved-module-path? mod-name)
             (raise-arguments-error 'module-path-index-resolve
                                    "current module name resolver's result is not a resolved module path"
                                    "result" mod-name))
           (set-module-path-index-resolved! mpi mod-name)
           mod-name)]
        [else
         (raise-arguments-error who
                                "\"self\" index has no resolution"
                                "module path index" mpi)])))

(define (module-path-index-fresh mpi)
  (define-values (path base) (module-path-index-split mpi))
  (module-path-index-join* path base))

(define/who (module-path-index-join mod-path base [submod #f])
  (check who #:or-false module-path? mod-path)
  (unless (or (not base)
              (resolved-module-path? base)
              (module-path-index? base))
    (raise-argument-error who "(or/c #f resolved-module-path? module-path-index?)" base))
  (unless (or (not submod)
              (and (pair? submod)
                   (list? submod)
                   (andmap symbol? submod)))
    (raise-argument-error who "(or/c #f (non-empty-listof symbol?))" submod))
  (when (and (not mod-path)
             base)
    (raise-arguments-error who
                           "cannot combine #f path with non-#f base"
                           "given base" base))
  (when (and submod mod-path)
    (raise-arguments-error who
                           "cannot combine #f submodule list with non-#f module path"
                           "given module path" mod-path
                           "given submodule list" submod))
  (cond
   [submod
    (make-self-module-path-index (make-resolved-module-path
                                  (cons generic-module-name submod)))]
   [else
    (module-path-index-join* mod-path base)]))

(define (module-path-index-join* mod-path base)
  (define keep-base
    (let loop ([mod-path mod-path])
      (cond
        [(path? mod-path) #f]
        [(and (pair? mod-path) (eq? 'quote (car mod-path))) #f]
        [(symbol? mod-path) #f]
        [(and (pair? mod-path) (eq? 'lib (car mod-path))) #f]
        [(and (pair? mod-path) (eq? 'submod (car mod-path)))
         (loop (cadr mod-path))]
        [else base])))
  (module-path-index mod-path keep-base #f empty-shift-cache))

(define (module-path-index-resolve/maybe base load?)
  (if (module-path-index? base)
      (module-path-index-resolve base load?)
      base))

(define/who (module-path-index-split mpi)
  (check who module-path-index? mpi)
  (values (module-path-index-path mpi)
          (module-path-index-base mpi)))

(define/who (module-path-index-submodule mpi)
  (check who module-path-index? mpi)
  (and (not (module-path-index-path mpi))
       (let ([r (module-path-index-resolved mpi)])
         (and r
              (let ([p (resolved-module-path-name r)])
                (and (pair? p)
                     (cdr p)))))))

(define make-self-module-path-index
  (case-lambda
    [(name) (module-path-index #f #f name empty-shift-cache)]
    [(name enclosing)
     (make-self-module-path-index (build-module-name name
                                                     (and enclosing
                                                          (module-path-index-resolve enclosing))))]))

;; A "generic" module path index is used by the exansion of `module`; every
;; expanded module (at the same submodule nesting and name) uses the same
;; generic module path, so that compilation can recognize references within
;; the module to itself, and so on
(define-place-local generic-self-mpis (make-weak-hash))
(define generic-module-name '|expanded module|)

(define (module-path-place-init!)
  (set! generic-self-mpis (make-weak-hash)))

;; Return a module path index that is the same for a given
;; submodule path in the given self module path index
(define (make-generic-self-module-path-index self)
  (define r (resolved-module-path-to-generic-resolved-module-path
             (module-path-index-resolved self)))
  ;; The use of `generic-self-mpis` must be atomic, so that the
  ;; current thread cannot be killed, since that could leave
  ;; the table locked
  (start-atomic)
  (begin0
    (or (let ([e (hash-ref generic-self-mpis r #f)])
          (and e (ephemeron-value e)))
        (let ([mpi (module-path-index #f #f r empty-shift-cache)])
          (hash-set! generic-self-mpis r (make-ephemeron r mpi))
          mpi))
    (end-atomic)))

(define (resolved-module-path-to-generic-resolved-module-path r)
  (define name (resolved-module-path-name r))
  (make-resolved-module-path
   (if (symbol? name)
       generic-module-name
       (cons generic-module-name (cdr name)))))

;; Mutate the resolved path in `mpi` to use the root module name of a
;; generic module path index, which means that future
;; `free-identifier=?` comparisons with the generic module path index
;; will succeed<
(define (imitate-generic-module-path-index! mpi)
  (define r (module-path-index-resolved mpi))
  (when r
    (set-module-path-index-resolved! mpi
                                     (resolved-module-path-to-generic-resolved-module-path r))))

(define (module-path-index-shift* mpi from-mpi to-mpi freshen-cache)
  (cond
   [(eq? mpi from-mpi) to-mpi]
   [else
    (define base (module-path-index-base mpi))
    (define result-mpi
      (cond
        [(not base) mpi]
        [else
         (define shifted-base (module-path-index-shift* base from-mpi to-mpi freshen-cache))
         (cond
           [(eq? shifted-base base) mpi]
           [(shift-cache-ref (module-path-index-shift-cache shifted-base) mpi)]
           [else
            (define shifted-mpi
              (module-path-index-join* (module-path-index-path mpi) shifted-base))
            (shift-cache-set! shifted-base shifted-mpi)
            shifted-mpi])]))
    (when (and freshen-cache
               (not (hash-ref freshen-cache result-mpi #f)))
      ;; Create a fresh mpi, but return `result-mpi` to take advantage
      ;; of its caching, instead of re-caching the shift at `fresh-mpi`
      (define result-base (module-path-index-base result-mpi))
      (define fresh-base (hash-ref freshen-cache result-base #f))
      (define fresh-mpi
        (module-path-index (module-path-index-path result-mpi)
                           (or fresh-base result-base)
                           #f
                           empty-shift-cache))
      (when fresh-base
        (shift-cache-set! fresh-base fresh-mpi))
      (hash-set! freshen-cache result-mpi fresh-mpi))
    result-mpi]))

(define (module-path-index-shift mpi from-mpi to-mpi)
  (module-path-index-shift* mpi from-mpi to-mpi #f))

;; ensures that the result module-path index is fresh enough, so that
;; resolving will go through the module name resolver; the `freshen-cache`
;; hash table ensures that sharing in the original is preserved through
;; sharing of fresh MPIs
(define (module-path-index-shift/resolved mpi from-mpi to-mpi freshen-cache rp)
  (define new-mpi (module-path-index-shift* mpi from-mpi to-mpi freshen-cache))
  (define fresh-mpi (hash-ref freshen-cache new-mpi))
  (when rp
    (unless (module-path-index-resolved fresh-mpi)
      (set-module-path-index-resolved! fresh-mpi rp)))
  fresh-mpi)

(define (shift-cache-ref cache mpi)
  (for/or ([wb (in-list cache)])
    (define v (weak-box-value wb))
    (and v
         (equal? (module-path-index-path v)
                 (module-path-index-path mpi))
         v)))

(define (shift-cache-set! base v)
  (define new-cache
    (cons (make-weak-box v)
          ;; Prune empty cache entries, and keep only up to a certain
          ;; number of cached values to avoid quadratic behavior.
          (let loop ([n 32] [l (module-path-index-shift-cache base)])
            (cond
              [(null? l) null]
              [(eqv? n 0) null]
              [(not (weak-box-value (car l)))
               (loop n (cdr l))]
              [else
               (let ([r (loop (fx- n 1) (cdr l))])
                 (if (eq? r (cdr l))
                     l
                     (cons (car l) r)))]))))
  (set-module-path-index-shift-cache! base new-cache))

;; A constant module path index to represent the top level
(define top-level-module-path-index
  (make-self-module-path-index
   (make-resolved-module-path 'top-level)))

(define (top-level-module-path-index? mpi)
  (eq? top-level-module-path-index mpi))

(define (non-self-module-path-index? mpi)
  (and (module-path-index-path mpi) #t))

(define (non-self-derived-module-path-index? mpi)
  (and (non-self-module-path-index? mpi)
       (let ([base (module-path-index-base mpi)])
         (or (not base)
             (non-self-derived-module-path-index? base)))))

(define (inside-module-context? mpi inside-mpi)
  (or (eq? mpi inside-mpi)
      ;; Also recognize the "inside" context created by
      ;; `shift-to-inside-root-context` for use with
      ;; a module's namespace
      (and (module-path-index? mpi)
           (module-path-index? inside-mpi)
           (module-path-index-resolved mpi)
           (eq? (module-path-index-resolved mpi)
                (module-path-index-resolved inside-mpi)))))

;; ----------------------------------------

(define (resolve-module-path mod-path base)
  ((current-module-name-resolver) mod-path base #f #t))

;; The resolver in "../boot/handler.rkt" replaces this one
;; as the value of `current-module-name-resolver`
(define core-module-name-resolver
  (case-lambda
    [(name from-namespace)
     ;; No need to register
     (void)]
    [(p enclosing source-stx-stx load?)
     (unless (module-path? p)
       (raise-argument-error 'core-module-name-resolver "module-path?" p))
     (unless (or (not enclosing)
                 (resolved-module-path? enclosing))
       (raise-argument-error 'core-module-name-resolver "resolved-module-path?" enclosing))
     (cond
      [(and (list? p)
            (= (length p) 2)
            (eq? 'quote (car p))
            (symbol? (cadr p)))
       (make-resolved-module-path (cadr p))]
      [(and (list? p)
            (eq? 'submod (car p))
            (equal? ".." (cadr p)))
       (for/fold ([enclosing enclosing]) ([s (in-list (cdr p))])
         (build-module-name s enclosing #:original p))]
      [(and (list? p)
            (eq? 'submod (car p))
            (equal? "." (cadr p)))
       (for/fold ([enclosing enclosing]) ([s (in-list (cddr p))])
         (build-module-name s enclosing #:original p))]
      [(and (list? p)
            (eq? 'submod (car p)))
       (let ([base ((current-module-name-resolver) (cadr p) enclosing #f #f)])
         (for/fold ([enclosing base]) ([s (in-list (cddr p))])
           (build-module-name s enclosing #:original p)))]
      [else
       (error 'core-module-name-resolver
              "not a supported module path: ~v" p)])]))

;; Build a submodule name given an enclosing module name, if any
(define (build-module-name name ; a symbol or ".."
                           enclosing ; resoved module path or #f; #f => no enclosing module
                           #:original [orig-name name]) ; for error reporting
  (define enclosing-module-name (and enclosing
                                     (resolved-module-path-name enclosing)))
  (make-resolved-module-path
   (cond
     [(equal? name "..")
      ;; At the time of writing, we only get here via `core-module-name-resolver`
      ;; --- which is replaced on startup
      (cond
        [(not (pair? enclosing-module-name))
         (error "too many \"..\"s:" orig-name)]
        [(= 2 (length enclosing-module-name)) (car enclosing-module-name)]
        [else (reverse (cdr (reverse enclosing-module-name)))])]
     [(not enclosing-module-name) name]
     [(pair? enclosing-module-name) (append enclosing-module-name (list name))]
     [else (list enclosing-module-name name)])))

;; Parameter that can be set externally:
(define current-module-name-resolver
  (make-parameter
   core-module-name-resolver
   (lambda (v)
     (unless (and (procedure? v)
                  (procedure-arity-includes? v 2)
                  (procedure-arity-includes? v 4))
       (raise-argument-error 'current-module-name-resolver
                             "(and/c (procedure-arity-includes/c 2) (procedure-arity-includes/c 4))"
                             v))
     v)
   'current-module-name-resolver))

;; ----------------------------------------

(define current-module-declare-name
  (make-parameter #f
                  (lambda (r)
                    (unless (or (not r)
                                (resolved-module-path? r))
                      (raise-argument-error 'current-module-declare-name
                                            "(or/c #f resolved-module-path?)"
                                            r))
                    r)
                  'current-module-declare-name))

(define current-module-declare-source
  (make-parameter #f
                  (lambda (s)
                    (unless (or (not s)
                                (symbol? s)
                                (and (path? s) (complete-path? s)))
                      (raise-argument-error 'current-module-declare-source
                                            "(or/c #f symbol? (and/c path? complete-path?))"
                                            s))
                    s)
                  'current-module-declare-source))

(define (substitute-module-declare-name default-name)
  (define current-name (current-module-declare-name))
  (define root-name (if current-name
                        (resolved-module-path-root-name current-name)
                        (if (pair? default-name)
                            (car default-name)
                            default-name)))
  (make-resolved-module-path
   (if (pair? default-name)
       (cons root-name (cdr default-name))
       root-name)))
