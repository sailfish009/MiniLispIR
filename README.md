For user convenience, a low-level language utilizing ir-gen and ir-eval; this language is currently not operational.

v0.0005 : eval + repl 

> llc minilispir.ll -filetype=obj -mtriple=x86_64-linux-gnu -relocation-model=pic -o minilispir.o

> clang minilispir.o -o minilispir -fPIE -lc -g

> ./minilispir


