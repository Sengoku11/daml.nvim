;; extends
;; DAML-on-Haskell: color extra keywords without relying on specific node names.

;; Treat these like `data` (type-ish keywords)
((_) @keyword.type
  (#match? @keyword.type "^(template|interface|choice|nonconsuming|preconsuming|postconsuming)$"))

;; Treat these like functions
((_) @function
  (#match? @function "^(controller|signatory|viewtype|observer|ensure)$"))
