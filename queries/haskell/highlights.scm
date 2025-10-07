;; extends
;; DAML-on-Haskell keywords without using huge `_` captures

; Type-ish keywords you want colored like keywords
((variable) @keyword
  (#any-of? @keyword
   "template" "interface" "choice" "nonconsuming" "preconsuming" "postconsuming"))

; Builtin-ish DSL words you want colored like functions
((variable) @function.builtin
  (#any-of? @function.builtin
   "controller" "signatory" "viewtype" "observer" "ensure" "this" "arg" "self"))
