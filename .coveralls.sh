#!/bin/sh

eval `opam config env`
opam install ocveralls -y
make TESTS=--enable-tests
BISECT_FILE=_build/coverage ./setup.bin -test
`opam config var bin`/ocveralls --prefix _build _build/coverage*.out --send
