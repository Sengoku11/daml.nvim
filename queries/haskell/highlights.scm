;; extends
;; DAML-on-Haskell keywords

;; Treat these like `data` (type-ish keywords)
((variable) @keyword
  (#any-of? @keyword
   "template" "interface" "choice" "nonconsuming" "preconsuming" "postconsuming" "with"))

;; Treat these like functions
((variable) @function.builtin
  (#any-of? @function.builtin
   "controller" "signatory" "viewtype" "observer" "ensure" "this" "arg" "self"))
