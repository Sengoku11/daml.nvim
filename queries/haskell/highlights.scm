;; extends
;; DAML-on-Haskell keywords

;; Treat these like `data` (type-ish keywords)
((variable) @keyword
  (#any-of? @keyword
   "template" "interface" "choice" "nonconsuming" "preconsuming" "postconsuming" "with" "do" "where"))

;; Treat these like builtin functions
((variable) @function.builtin
  (#any-of? @function.builtin
   "controller" "signatory" "viewtype" "observer" "ensure" "this" "arg" "self" "submit" "exercise" "create"))
