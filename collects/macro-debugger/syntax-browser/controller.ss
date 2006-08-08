
(module controller mzscheme
  (require (lib "class.ss")
           "interfaces.ss"
           "partition.ss"
           "properties.ss")
  
  (provide syntax-controller%)
  
  ;; syntax-controller%
  (define syntax-controller%
    (class* object% (syntax-controller<%>
                     syntax-pp-snip-controller<%>
                     color-controller<%>)

      (define colorers null)
      (define selection-listeners null)
      (define selected-syntax #f)
      (init-field (properties-controller
                   (new independent-properties-controller% (controller this))))

      ;; syntax-controller<%> Methods

      (define/public (select-syntax stx)
        (set! selected-syntax stx)
        (send properties-controller set-syntax stx)
        (for-each (lambda (c) (send c select-syntax stx)) colorers)
        (for-each (lambda (p) (p stx)) selection-listeners))

      (define/public (get-selected-syntax)
        selected-syntax)

      (define/public (get-properties-controller) properties-controller)

      (define/public (add-view-colorer c)
        (set! colorers (cons c colorers))
        (send c select-syntax selected-syntax))

      (define/public (get-view-colorers) colorers)

      (define/public (add-selection-listener p)
        (set! selection-listeners (cons p selection-listeners)))
      
      (define/public (on-update-identifier=? id=?)
        (set! -secondary-partition 
              (and id=? (new partition% (relation id=?))))
        (for-each (lambda (c) (send c refresh)) colorers))

      (define/public (erase)
        (set! colorers null))

      ;; syntax-pp-snip-controller<%> Methods

      (define/public (on-select-syntax stx)
        (select-syntax stx))

      ;; color-controller<%> Methods

      (define -primary-partition (new-bound-partition))
      (define -secondary-partition #f)

      (define/public (get-primary-partition) -primary-partition)
      (define/public (get-secondary-partition) -secondary-partition)

      ;; Initialization
      (super-new)
      ))
  
  )