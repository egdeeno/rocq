How to write plugins in Rocq
===========================

This document describes how to extend Rocq by writing plugins in the
[OCaml](https://ocaml.org/) functional programming language.
Before writing a plugin, you should consider whether easier approaches
can achieve your goal. It is often easier to use an
extension language such as Ltac2 or Elpi. Ltac2 is documented in the
[refman](https://rocq-prover.org/refman/proof-engine/ltac2.html)
and Elpi comes with excellent
[tutorials](https://github.com/LPCIC/coq-elpi/#tutorials). Plugin
development is harder due to the lower level OCaml API it uses.
It is also more maintenance intensive because the OCaml API can
change from release to release without any backward compatibility
(it's not uncommon for plugins to only work with a given
version of Rocq).

# Working environment

In addition to installing OCaml and Rocq, you need to make sure that you also have the development
headers for Rocq, because you will need them to compile extensions. If you installed Rocq from source or
from [OPAM](http://opam.ocaml.org/doc/Install.html), you already have the required headers. If you
installed them from your system package manager, there may be a separate package
which contains the development headers (for example, in Ubuntu they are contained in the package
`libcoq-ocaml-dev`). It can help to install several tools for development.

## Tuareg and Merlin

These instructions use [OPAM](http://opam.ocaml.org/doc/Install.html)

```shell
opam install merlin               # prints instructions for vim and emacs
opam install tuareg               # syntax highlighting for OCaml
opam user-setup install           # automatically configures editors for merlin
```

Adding this line to your .emacs helps Tuareg recognize the .mlg extension:

```shell
(add-to-list 'auto-mode-alist '("\\.mlg$"      . tuareg-mode) t)
```

If you are using [vscoq](https://github.com/coq-community/vscoq),
you will need to ensure that vscoq loads the `_CoqProject` file for the extension
you are working on. You can do this by opening Visual Studio Code with the `_CoqProject`
file in the project root directory, or by editing the `coqtop.coqProjectRoot` setting for vscoq.

## This tutorial

```shell
cd plugin_tutorials/tuto0
make .merlin                # run before opening .ml files in your editor
make                        # build
```

# tuto0 : basics of project organization
package an mlg file in a plugin, organize a `Makefile`, `_CoqProject` (note comments in those files)
- Example of syntax to add a new toplevel command
- Example of function call to print a simple message
- Example of function call to print a simple warning
- Example of function call to raise a simple error to the user
- Example of syntax to add a simple tactic
    (that does nothing and prints a message)
- To use it:

```bash
  cd tuto0; make
  rocq top -I src -R theories Tuto0
```

In the Rocq session type:
```coq
  Require Import Tuto0.Loader. HelloWorld.
```

You can also modify and run `theories/Demo.v`.

Because the `.mlpack` file format does not support comments, we
explain it here: this file is used by `rocq makefile` to compile the
plugin. It lists the OCaml modules used in the plugin in dependency
order. From `foo.mlpack`, `rocq makefile` will build `foo.cma`
(bytecode plugin) and `foo.cmxs` (native plugin), so the file names in
the `META` file must match this.

# tuto1 : OCaml to Rocq communication
Explore the memory of Rocq, modify it
- Commands that take arguments: strings, integers, symbols, expressions of the calculus of constructions
- Examples of using environments correctly
- Examples of using state (the evar_map) correctly
- Commands that interact with type-checking in Rocq
- A command that checks convertibility between two terms
- A command that adds a new definition or theorem
- A command that uses a name and exploits the existing definitions or theorems
- A command that exploits an existing ongoing proof
- A command that defines a new tactic

Compilation and loading must be performed as for `tuto0`.

# tuto2 : OCaml to Rocq communication
A more step by step introduction to writing commands
- Explanation of the syntax of entries
- Adding a new type to and parsing to the available choices
- Handling commands that store information in user-chosen registers and tables

Compilation and loading must be performed as for `tuto0`.

# tuto3 : manipulating terms of the calculus of constructions
Manipulating terms, inside commands and tactics.
- Obtaining existing values from memory
- Composing values
- Verifying types
- Using these terms in commands
- Using these terms in tactics
- Automatic proofs without tactics using type classes and canonical structures

Compilation and loading must be performed as for `tuto0`.

# tuto4: extending Ltac2
Define new primitives ("externals") for Ltac2.

Note that in this case we have no `.mlg` file, but the `Loader.v` is less trivial.

Compilation and loading must be performed as for `tuto0`.
