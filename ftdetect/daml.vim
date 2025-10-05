" Detect daml files before the lua code is loaded by package manager.
augroup daml_ftdetect
  autocmd!
  autocmd BufRead,BufNewFile *.daml setfiletype daml
augroup END
