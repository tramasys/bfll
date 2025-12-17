# bfll

this project was done for the compiler course at hslu.

requires llvm 23.1.1 with `clang`, `llvm-as` and `opt` on the path, make, python 3 and a 64-bit posix host.

compile and run the hello world example:

```sh
make
mkdir -p build
./bfc examples/hello.bf > build/hello.ll
llvm-as build/hello.ll -o build/hello.bc
opt -passes=verify build/hello.bc -disable-output
clang -O2 build/hello.ll -o build/hello
./build/hello
make test
```

compare the generated ir with llvm's optimized output:

```sh
./bfc --no-bf-opt examples/hello.bf > build/hello.plain.ll
opt -S -passes='mem2reg,sroa,instcombine,simplifycfg' build/hello.ll -o build/hello.opt.ll
opt -S -O2 build/hello.ll -o build/hello.O2.ll
```

`--no-bf-opt` keeps run folding and bracket validation but disables clear, scan and linear loop optimization.

the handwritten source follows the [llvm 23.1.1 language reference](https://github.com/llvm/llvm-project/blob/llvmorg-23.1.1/llvm/docs/LangRef.md).
