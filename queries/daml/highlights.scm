; Highlight 'template' like Haskell `data`
((variable) @keyword.type
  (#eq? @keyword.type "template"))
((identifier) @keyword.type
  (#eq? @keyword.type "template"))
((varid) @keyword.type
  (#eq? @keyword.type "template"))

; Highlight 'interface' like Haskell `class`
((variable) @keyword
  (#eq? @keyword "interface"))
((identifier) @keyword
  (#eq? @keyword "interface"))
((varid) @keyword
  (#eq? @keyword "interface"))
