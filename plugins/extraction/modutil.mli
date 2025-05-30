(************************************************************************)
(*         *      The Rocq Prover / The Rocq Development Team           *)
(*  v      *         Copyright INRIA, CNRS and contributors             *)
(* <O___,, * (see version control and CREDITS file for authors & dates) *)
(*   \VV/  **************************************************************)
(*    //   *    This file is distributed under the terms of the         *)
(*         *     GNU Lesser General Public License Version 2.1          *)
(*         *     (see LICENSE file for the text of the license)         *)
(************************************************************************)

open Names
open Miniml

(*s Functions upon ML modules. *)

val struct_ast_search : (ml_ast -> bool) -> ml_structure -> bool
val struct_type_search : (ml_type -> bool) -> ml_structure -> bool

type do_ref = global -> unit

val type_iter_references : do_ref -> ml_type -> unit
val ast_iter_references : do_ref -> do_ref -> do_ref -> ml_ast -> unit
val decl_iter_references : do_ref -> do_ref -> do_ref -> ml_decl -> unit
val spec_iter_references : do_ref -> do_ref -> do_ref -> ml_spec -> unit

val signature_of_structure : ml_structure -> ml_signature

val mtyp_of_mexpr : ml_module_expr -> ml_module_type

val msid_of_mt : ml_module_type -> ModPath.t

val get_decl_in_structure : global -> ml_structure -> ml_decl

(* Some transformations of ML terms. [optimize_struct] simplify
   all beta redexes (when the argument does not occur, it is just
   thrown away; when it occurs exactly once it is substituted; otherwise
   a let-in redex is created for clarity) and iota redexes, plus some other
   optimizations. The first argument is the list of objects we want to appear.
*)

val optimize_struct : Common.State.t -> global list * ModPath.t list ->
  ml_structure -> ml_structure
