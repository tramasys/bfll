CLANG ?= clang
LLVM_AS ?= llvm-as
OPT ?= opt
CFLAGS ?= -O2

.PHONY: all verify test clean

all: bfc

bfc: src/bfc.ll
	$(CLANG) $(CFLAGS) $< -o $@

build:
	mkdir -p build

verify: | build
	$(LLVM_AS) src/bfc.ll -o build/bfc.bc
	$(OPT) -passes=verify build/bfc.bc -disable-output

test: bfc verify
	CLANG="$(CLANG)" LLVM_AS="$(LLVM_AS)" OPT="$(OPT)" sh tests/run-tests.sh

clean:
	$(RM) bfc build/bfc.bc
