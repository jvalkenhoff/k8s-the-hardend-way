" Enable syntax highlighting
syntax on

" Detect file types
filetype plugin indent on

" Kubernetes / YAML indentation
autocmd FileType yaml setlocal expandtab
autocmd FileType yaml setlocal shiftwidth=2
autocmd FileType yaml setlocal softtabstop=2
autocmd FileType yaml setlocal tabstop=2
autocmd FileType yaml setlocal autoindent