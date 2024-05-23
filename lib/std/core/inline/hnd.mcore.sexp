(define $"import$std/core/hnd":ptr (this-lib))

;; Current evidence vector
;; -----------------------
(define $getCurrentEvv:(fun Effectful () ptr) (lambda ()
  ("getRef(Ref[Ptr]): Ptr" ("getGlobal(String): Ptr" "current-evv")))
  :export-as ("getCurrentEvv"))
(define $setCurrentEvv:(fun Effectful (ptr) unit) (lambda ($evv:ptr)
  ("setRef(Ref[Ptr], Ptr): Unit" ("getGlobal(String): Ptr" "current-evv") $evv:ptr))
  :export-as ("setCurrentEvv"))
(define $swapCurrentEvv:(fun Effectful (ptr) ptr) (lambda ($evv:ptr)
  (letrec ((define $ref:ptr ("getGlobal(String): Ptr" "current-evv"))
           (define $old:ptr ("getRef(Ref[Ptr]): Ptr" $ref:ptr)))
    (begin
      ("setRef(Ref[Ptr], Ptr): Unit" $ref:ptr $evv:ptr)
      $old:ptr)))
  :export-as ("swapCurrentEvv"))
(define $evvSwapCreate1:(fun Effectful (int) ptr) (lambda ($n:int)
  (letrec ((define $cur:ptr ($getCurrentEvv:(fun Effectful () ptr)))
           (define $ev:ptr ($elt:top $cur:ptr $n:int))
           (define $next:ptr (make $evv $cons ($ev:ptr (make $evv $nil ())))))
    (begin
      ($setCurrentEvv:(fun Effectful (ptr) unit) $next:ptr)
      $cur:ptr)))
  :export-as ("evvSwapCreate1"))
(define $evvSwapCreate0:(fun Effectful () ptr) (lambda ()
  (letrec ((define $cur:ptr ($getCurrentEvv:(fun Effectful () ptr)))
           (define $next:ptr (make $evv $nil ())))
    (begin
      ($setCurrentEvv:(fun Effectful (ptr) unit) $next:ptr)
      $cur:ptr)))
  :export-as ("evvSwapCreate0"))

;; List utilities
;; --------------
(define $elt:top (lambda ($l:ptr $n:int) 
  (switch $n:int 
    (0 (project $l:ptr $evv $cons 0)) 
    (_ ($elt:top (project $l:ptr $evv $cons 1) 
                 ("infixSub(Int, Int): Int" $n:int 1)))))
  :export-as ("elt"))

(unit)