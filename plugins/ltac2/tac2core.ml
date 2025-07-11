(************************************************************************)
(*         *      The Rocq Prover / The Rocq Development Team           *)
(*  v      *         Copyright INRIA, CNRS and contributors             *)
(* <O___,, * (see version control and CREDITS file for authors & dates) *)
(*   \VV/  **************************************************************)
(*    //   *    This file is distributed under the terms of the         *)
(*         *     GNU Lesser General Public License Version 2.1          *)
(*         *     (see LICENSE file for the text of the license)         *)
(************************************************************************)

open Util
open Pp
open Names
open Tac2val
open Tac2ffi
open Tac2extffi
open Tac2expr
open Proofview.Notations

let ltac2_plugin = "rocq-runtime.plugins.ltac2"

let constr_flags =
  let open Pretyping in
  {
    use_coercions = true;
    use_typeclasses = Pretyping.UseTC;
    solve_unification_constraints = true;
    fail_evar = true;
    expand_evars = true;
    program_mode = false;
    polymorphic = false;
    undeclared_evars_patvars = false;
    patvars_abstract = false;
    unconstrained_sorts = false;
  }

let open_constr_no_classes_flags =
  let open Pretyping in
  {
  use_coercions = true;
  use_typeclasses = Pretyping.NoUseTC;
  solve_unification_constraints = true;
  fail_evar = false;
  expand_evars = false;
  program_mode = false;
  polymorphic = false;
  undeclared_evars_patvars = false;
  patvars_abstract = false;
  unconstrained_sorts = false;
  }

let preterm_flags =
  let open Pretyping in
  {
  use_coercions = true;
  use_typeclasses = Pretyping.NoUseTC;
  solve_unification_constraints = true;
  fail_evar = false;
  expand_evars = false;
  program_mode = false;
  polymorphic = false;
  undeclared_evars_patvars = false;
  patvars_abstract = false;
  unconstrained_sorts = false;
  }

(** Standard values *)

open Tac2quote.Refs

let v_blk = Valexpr.make_block

let of_relevance = function
  | Sorts.Relevant -> ValInt 0
  | Sorts.Irrelevant -> ValInt 1
  | Sorts.RelevanceVar q -> ValBlk (0, [|of_qvar q|])

let to_relevance = function
  | ValInt 0 -> Sorts.Relevant
  | ValInt 1 -> Sorts.Irrelevant
  | ValBlk (0, [|qvar|]) ->
    let qvar = to_qvar qvar in
    Sorts.RelevanceVar qvar
  | _ -> assert false

(* XXX ltac2 exposes relevance internals so breaks ERelevance abstraction
   ltac2 Constr.Binder.relevance probably needs to be made an abstract type *)
let relevance = make_repr of_relevance to_relevance

let of_rec_declaration (nas, ts, cs) =
  let binders = Array.map2 (fun na t -> (na, t)) nas ts in
  (Tac2ffi.of_array of_binder binders,
  Tac2ffi.of_array Tac2ffi.of_constr cs)

let to_rec_declaration (nas, cs) =
  let nas = Tac2ffi.to_array to_binder nas in
  (Array.map fst nas,
  Array.map snd nas,
  Tac2ffi.to_array Tac2ffi.to_constr cs)

let of_case_invert = let open Constr in function
  | NoInvert -> ValInt 0
  | CaseInvert {indices} ->
    v_blk 0 [|of_array of_constr indices|]

let to_case_invert = let open Constr in function
  | ValInt 0 -> NoInvert
  | ValBlk (0, [|indices|]) ->
    let indices = to_array to_constr indices in
    CaseInvert {indices}
  | _ -> CErrors.anomaly Pp.(str "unexpected value shape")

let of_result f = function
| Inl c -> v_blk 0 [|f c|]
| Inr e -> v_blk 1 [|Tac2ffi.of_exn e|]

(** Helper functions *)

let thaw f : _ Proofview.tactic = f ()

let fatal_flag : unit Exninfo.t = Exninfo.make "fatal_flag"

let has_fatal_flag info = match Exninfo.get info fatal_flag with
  | None -> false
  | Some () -> true

let set_bt info =
  if !Tac2bt.print_ltac2_backtrace then
    Tac2bt.get_backtrace >>= fun bt ->
    Proofview.tclUNIT (Exninfo.add info Tac2bt.backtrace bt)
  else Proofview.tclUNIT info

let throw ?(info = Exninfo.null) e =
  set_bt info >>= fun info ->
  let info = Exninfo.add info fatal_flag () in
  Proofview.tclLIFT (Proofview.NonLogical.raise (e, info))

let fail ?(info = Exninfo.null) e =
  set_bt info >>= fun info ->
  Proofview.tclZERO ~info e

let return x = Proofview.tclUNIT x
let pname ?(plugin=ltac2_plugin) s = { mltac_plugin = plugin; mltac_tactic = s }

let catchable_exception = function
  | Logic_monad.Exception _ -> false
  | e -> CErrors.noncritical e

(* Adds ltac2 backtrace
   With [passthrough:false], acts like [Proofview.wrap_exceptions] + Ltac2 backtrace handling
*)
let wrap_exceptions ?(passthrough=false) f =
  try f ()
  with e ->
    let e, info = Exninfo.capture e in
    set_bt info >>= fun info ->
    if not passthrough && catchable_exception e
    then begin if has_fatal_flag info
      then Proofview.tclLIFT (Proofview.NonLogical.raise (e, info))
      else Proofview.tclZERO ~info e
    end
    else Exninfo.iraise (e, info)

let assert_focussed =
  Proofview.Goal.goals >>= fun gls ->
  match gls with
  | [_] -> Proofview.tclUNIT ()
  | [] | _ :: _ :: _ -> throw Tac2ffi.err_notfocussed

let pf_apply ?(catch_exceptions=false) f =
  let f env sigma = wrap_exceptions ~passthrough:(not catch_exceptions) (fun () -> f env sigma) in
  Proofview.Goal.goals >>= function
  | [] ->
    Proofview.tclENV >>= fun env ->
    Proofview.tclEVARMAP >>= fun sigma ->
    f env sigma
  | [gl] ->
    gl >>= fun gl ->
    f (Proofview.Goal.env gl) (Tacmach.project gl)
  | _ :: _ :: _ ->
    throw Tac2ffi.err_notfocussed

open Tac2externals

let define ?plugin s = define (pname ?plugin s)

(** Printing *)

let () = define "print" (pp @-> ret unit) Feedback.msg_notice

let () = define "message_empty" (ret pp) (Pp.mt ())

let () = define "message_of_int" (int @-> ret pp) Pp.int

let () = define "message_of_string" (string @-> ret pp) Pp.str

let () = define "message_to_string" (pp @-> ret string) Pp.string_of_ppcmds

let () =
  define "message_of_constr" (constr @-> tac pp) @@ fun c ->
  pf_apply @@ fun env sigma -> return (Printer.pr_econstr_env env sigma c)

let () = define "message_of_ident" (ident @-> ret pp) Id.print

let () =
  define "message_of_exn" (valexpr @-> eret pp) @@ fun v env sigma ->
  Tac2print.pr_valexpr env sigma v (GTypRef (Other t_exn, []))

let () = define "message_concat" (pp @-> pp @-> ret pp) Pp.app

let () = define "message_force_new_line" (ret pp) (Pp.fnl ())

let () = define "message_break" (int @-> int @-> ret pp) (fun i j -> Pp.brk (i,j))

let () = define "message_space" (ret pp) (Pp.spc())

let () = define "message_hbox" (pp @-> ret pp) Pp.h

let () = define "message_vbox" (int @-> pp @-> ret pp) Pp.v

let () = define "message_hvbox" (int @-> pp @-> ret pp) Pp.hv

let () = define "message_hovbox" (int @-> pp @-> ret pp) Pp.hov

let () = define "format_stop" (ret format) []

let () =
  define "format_string" (format @-> ret format) @@ fun s ->
  FmtString :: s

let () =
  define "format_int" (format @-> ret format) @@ fun s ->
  FmtInt :: s

let () =
  define "format_constr" (format @-> ret format) @@ fun s ->
  FmtConstr :: s

let () =
  define "format_ident" (format @-> ret format) @@ fun s ->
  FmtIdent :: s

let () =
  define "format_literal" (string @-> format @-> ret format) @@ fun lit s ->
  FmtLiteral lit :: s

let () =
  define "format_alpha" (format @-> ret format) @@ fun s ->
  FmtAlpha :: s

let () =
  define "format_alpha0" (format @-> ret format) @@ fun s ->
  FmtAlpha0 :: s

let () =
  define "format_message" (format @-> ret format) @@ fun s ->
  FmtMessage :: s

let arity_of_format fmt =
  let open Tac2types in
  let fold accu = function
    | FmtLiteral _ -> accu
    | FmtString | FmtInt | FmtConstr | FmtIdent | FmtMessage -> 1 + accu
    | FmtAlpha | FmtAlpha0 -> 2 + accu
  in
  List.fold_left fold 0 fmt

let () =
  define "format_kfprintf" (closure @-> format @-> tac valexpr) @@ fun k fmt ->
  let open Tac2types in
  let pop1 l = match l with [] -> assert false | x :: l -> (x, l) in
  let pop2 l = match l with [] | [_] -> assert false | x :: y :: l -> (x, y, l) in
  let arity = arity_of_format fmt in
  let rec eval accu args fmt = match fmt with
  | [] -> apply k [of_pp accu]
  | tag :: fmt ->
    match tag with
    | FmtLiteral s ->
      eval (Pp.app accu (Pp.str s)) args fmt
    | FmtString ->
      let (s, args) = pop1 args in
      let pp = Pp.str (to_string s) in
      eval (Pp.app accu pp) args fmt
    | FmtInt ->
      let (i, args) = pop1 args in
      let pp = Pp.int (to_int i) in
      eval (Pp.app accu pp) args fmt
    | FmtConstr ->
      let (c, args) = pop1 args in
      let c = to_constr c in
      pf_apply begin fun env sigma ->
        let pp = Printer.pr_econstr_env env sigma c in
        eval (Pp.app accu pp) args fmt
      end
    | FmtIdent ->
      let (i, args) = pop1 args in
      let pp = Id.print (to_ident i) in
      eval (Pp.app accu pp) args fmt
    | FmtMessage ->
      let (m, args) = pop1 args in
      let m = to_pp m in
      eval (Pp.app accu m) args fmt
    | FmtAlpha ->
      let (f, x, args) = pop2 args in
      Tac2val.apply_val f [of_unit (); x] >>= fun pp ->
      eval (Pp.app accu (to_pp pp)) args fmt
    | FmtAlpha0 ->
      let (f, x, args) = pop2 args in
      Tac2val.apply_val f [x] >>= fun pp ->
      eval (Pp.app accu (to_pp pp)) args fmt
  in
  let eval v = eval (Pp.mt ()) v fmt in
  if Int.equal arity 0 then eval []
  else return (Tac2ffi.of_closure (Tac2val.abstract arity eval))

let () =
  define "format_ikfprintf" (closure @-> valexpr @-> format @-> tac valexpr) @@ fun k v fmt ->
  let arity = arity_of_format fmt in
  let eval _args = apply k [v] in
  if Int.equal arity 0 then eval []
  else return (Tac2ffi.of_closure (Tac2val.abstract arity eval))

(** Array *)

let () = define "array_empty" (ret valexpr) (v_blk 0 [||])

let () =
  define "array_make" (int @-> valexpr @-> tac valexpr) @@ fun n x ->
  try return (v_blk 0 (Array.make n x)) with Invalid_argument _ -> throw Tac2ffi.err_outofbounds

let () =
  define "array_length" (block @-> ret int) @@ fun (_, v) -> Array.length v

let () =
  define "array_set" (block @-> int @-> valexpr @-> tac unit) @@ fun (_, v) n x ->
  try Array.set v n x; return () with Invalid_argument _ -> throw Tac2ffi.err_outofbounds

let () =
  define "array_get" (block @-> int @-> tac valexpr) @@ fun (_, v) n ->
  try return (Array.get v n) with Invalid_argument _ -> throw Tac2ffi.err_outofbounds

let () =
  define "array_blit"
    (block @-> int @-> block @-> int @-> int @-> tac unit)
    @@ fun (_, v0) s0 (_, v1) s1 l ->
  try Array.blit v0 s0 v1 s1 l; return () with Invalid_argument _ ->
  throw Tac2ffi.err_outofbounds

let () =
  define "array_fill" (block @-> int @-> int @-> valexpr @-> tac unit) @@ fun (_, d) s l v ->
  try Array.fill d s l v; return () with Invalid_argument _ -> throw Tac2ffi.err_outofbounds

let () =
  define "array_concat" (list block @-> ret valexpr) @@ fun l ->
  v_blk 0 (Array.concat (List.map snd l))

(** Ident *)

let () = define "ident_equal" (ident @-> ident @-> ret bool) Id.equal

let () = define "ident_to_string" (ident @-> ret string) Id.to_string

let () =
  define "ident_of_string" (string @-> ret (option ident)) @@ fun s ->
  try Some (Id.of_string s) with e when CErrors.noncritical e -> None

(** Int *)

let () = define "int_equal" (int @-> int @-> ret bool) (==)

let () = define "int_neg" (int @-> ret int) (~-)
let () = define "int_abs" (int @-> ret int) abs

let () = define "int_compare" (int @-> int @-> ret int) Int.compare
let () = define "int_add" (int @-> int @-> ret int) (+)
let () = define "int_sub" (int @-> int @-> ret int) (-)
let () = define "int_mul" (int @-> int @-> ret int) ( * )

let () = define "int_div" (int @-> int @-> tac int) @@ fun m n ->
  if n == 0 then throw Tac2ffi.err_division_by_zero else return (m / n)
let () = define "int_mod" (int @-> int @-> tac int) @@ fun m n ->
  if n == 0 then throw Tac2ffi.err_division_by_zero else return (m mod n)

let () = define "int_asr" (int @-> int @-> ret int) (asr)
let () = define "int_lsl" (int @-> int @-> ret int) (lsl)
let () = define "int_lsr" (int @-> int @-> ret int) (lsr)
let () = define "int_land" (int @-> int @-> ret int) (land)
let () = define "int_lor" (int @-> int @-> ret int) (lor)
let () = define "int_lxor" (int @-> int @-> ret int) (lxor)
let () = define "int_lnot" (int @-> ret int) lnot

(** Char *)

let () = define "char_of_int" (int @-> tac char) @@ fun i ->
  try return (Char.chr i)
  with Invalid_argument _ as e ->
    let e, info = Exninfo.capture e in
    throw ~info e

let () = define "char_to_int" (char @-> ret int) Char.code

(** String *)

let () =
  define "string_make" (int @-> char @-> tac bytes) @@ fun n c ->
  try return (Bytes.make n c) with Invalid_argument _ -> throw Tac2ffi.err_outofbounds

let () = define "string_length" (bytes @-> ret int) Bytes.length

let () =
  define "string_set" (bytes @-> int @-> char @-> tac unit) @@ fun s n c ->
  try Bytes.set s n c; return () with Invalid_argument _ -> throw Tac2ffi.err_outofbounds

let () =
  define "string_get" (bytes @-> int @-> tac char) @@ fun s n ->
  try return (Bytes.get s n) with Invalid_argument _ -> throw Tac2ffi.err_outofbounds

let () = define "string_concat" (bytes @-> list bytes @-> ret bytes) Bytes.concat

let () =
  define "string_app" (bytes @-> bytes @-> ret bytes) @@ fun a b ->
  Bytes.concat Bytes.empty [a; b]

let () =
  define "string_sub" (bytes @-> int @-> int @-> tac bytes) @@ fun s off len ->
  try return (Bytes.sub s off len) with Invalid_argument _ -> throw Tac2ffi.err_outofbounds

let () = define "string_equal" (bytes @-> bytes @-> ret bool) Bytes.equal

let () = define "string_compare" (bytes @-> bytes @-> ret int) Bytes.compare

(** Pstring *)

let () =
  define "pstring_max_length" (ret uint63) Pstring.max_length;
  define "pstring_to_string" (pstring @-> ret string) Pstring.to_string;
  define "pstring_of_string" (string @-> ret (option pstring)) Pstring.of_string;
  define "pstring_make" (uint63 @-> uint63 @-> ret pstring) Pstring.make;
  define "pstring_length" (pstring @-> ret uint63) Pstring.length;
  define "pstring_get" (pstring @-> uint63 @-> ret uint63) Pstring.get;
  define "pstring_sub" (pstring @-> uint63 @-> uint63 @-> ret pstring) Pstring.sub;
  define "pstring_cat" (pstring @-> pstring @-> ret pstring) Pstring.cat;
  define "pstring_equal" (pstring @-> pstring @-> ret bool) Pstring.equal;
  define "pstring_compare" (pstring @-> pstring @-> ret int) Pstring.compare

(** Terms *)

(** constr -> constr *)
let () =
  define "constr_type" (constr @-> tac valexpr) @@ fun c ->
  let get_type env sigma =
    let (sigma, t) = Typing.type_of env sigma c in
    let t = Tac2ffi.of_constr t in
    Proofview.Unsafe.tclEVARS sigma <*> Proofview.tclUNIT t
  in
  pf_apply ~catch_exceptions:true get_type

(** constr -> constr *)
let () =
  define "constr_equal" (constr @-> constr @-> tac bool) @@ fun c1 c2 ->
  Proofview.tclEVARMAP >>= fun sigma -> return (EConstr.eq_constr sigma c1 c2)

let () =
  define "constr_kind" (constr @-> eret valexpr) @@ fun c env sigma ->
  let open Constr in
  match EConstr.kind sigma c with
  | Rel n ->
    v_blk 0 [|Tac2ffi.of_int n|]
  | Var id ->
    v_blk 1 [|Tac2ffi.of_ident id|]
  | Meta n ->
    v_blk 2 [|Tac2ffi.of_int n|]
  | Evar (evk, args) ->
    let args = Evd.expand_existential sigma (evk, args) in
    v_blk 3 [|
      Tac2ffi.of_evar evk;
      Tac2ffi.of_array Tac2ffi.of_constr (Array.of_list args);
    |]
  | Sort s ->
    v_blk 4 [|Tac2ffi.of_sort s|]
  | Cast (c, k, t) ->
    v_blk 5 [|
      Tac2ffi.of_constr c;
      Tac2ffi.of_cast k;
      Tac2ffi.of_constr t;
    |]
  | Prod (na, t, u) ->
    v_blk 6 [|
      of_binder (na, t);
      Tac2ffi.of_constr u;
    |]
  | Lambda (na, t, c) ->
    v_blk 7 [|
      of_binder (na, t);
      Tac2ffi.of_constr c;
    |]
  | LetIn (na, b, t, c) ->
    v_blk 8 [|
      of_binder (na, t);
      Tac2ffi.of_constr b;
      Tac2ffi.of_constr c;
    |]
  | App (c, cl) ->
    v_blk 9 [|
      Tac2ffi.of_constr c;
      Tac2ffi.of_array Tac2ffi.of_constr cl;
    |]
  | Const (cst, u) ->
    v_blk 10 [|
      Tac2ffi.of_constant cst;
      Tac2ffi.of_instance u;
    |]
  | Ind (ind, u) ->
    v_blk 11 [|
      Tac2ffi.of_inductive ind;
      Tac2ffi.of_instance u;
    |]
  | Construct (cstr, u) ->
    v_blk 12 [|
      Tac2ffi.of_constructor cstr;
      Tac2ffi.of_instance u;
    |]
  | Case (ci, u, pms, c, iv, t, bl) ->
    (* FIXME: also change representation Ltac2-side? *)
    let (ci, c, iv, t, bl) = EConstr.expand_case env sigma (ci, u, pms, c, iv, t, bl) in
    let c = on_snd (EConstr.ERelevance.kind sigma) c in
    v_blk 13 [|
      Tac2ffi.of_case ci;
      Tac2ffi.(of_pair of_constr of_relevance c);
      of_case_invert iv;
      Tac2ffi.of_constr t;
      Tac2ffi.of_array Tac2ffi.of_constr bl;
    |]
  | Fix ((recs, i), def) ->
    let (nas, cs) = of_rec_declaration def in
    v_blk 14 [|
      Tac2ffi.of_array Tac2ffi.of_int recs;
      Tac2ffi.of_int i;
      nas;
      cs;
    |]
  | CoFix (i, def) ->
    let (nas, cs) = of_rec_declaration def in
    v_blk 15 [|
      Tac2ffi.of_int i;
      nas;
      cs;
    |]
  | Proj (p, r, c) ->
    v_blk 16 [|
      Tac2ffi.of_projection p;
      of_relevance (EConstr.ERelevance.kind sigma r);
      Tac2ffi.of_constr c;
    |]
  | Int n ->
    v_blk 17 [|Tac2ffi.of_uint63 n|]
  | Float f ->
    v_blk 18 [|Tac2ffi.of_float f|]
  | String s ->
    v_blk 19 [|Tac2ffi.of_pstring s|]
  | Array(u,t,def,ty) ->
    v_blk 20 [|
      of_instance u;
      Tac2ffi.of_array Tac2ffi.of_constr t;
      Tac2ffi.of_constr def;
      Tac2ffi.of_constr ty;
    |]

let () =
  define "constr_make" (valexpr @-> eret constr) @@ fun knd env sigma ->
  match Tac2ffi.to_block knd with
  | (0, [|n|]) ->
    let n = Tac2ffi.to_int n in
    EConstr.mkRel n
  | (1, [|id|]) ->
    let id = Tac2ffi.to_ident id in
    EConstr.mkVar id
  | (2, [|n|]) ->
    let n = Tac2ffi.to_int n in
    EConstr.mkMeta n
  | (3, [|evk; args|]) ->
    let evk = to_evar evk in
    let args = Tac2ffi.to_array Tac2ffi.to_constr args in
    EConstr.mkLEvar sigma (evk, Array.to_list args)
  | (4, [|s|]) ->
    let s = Tac2ffi.to_sort s in
    EConstr.mkSort s
  | (5, [|c; k; t|]) ->
    let c = Tac2ffi.to_constr c in
    let k = Tac2ffi.to_cast k in
    let t = Tac2ffi.to_constr t in
    EConstr.mkCast (c, k, t)
  | (6, [|na; u|]) ->
    let (na, t) = to_binder na in
    let u = Tac2ffi.to_constr u in
    EConstr.mkProd (na, t, u)
  | (7, [|na; c|]) ->
    let (na, t) = to_binder na in
    let u = Tac2ffi.to_constr c in
    EConstr.mkLambda (na, t, u)
  | (8, [|na; b; c|]) ->
    let (na, t) = to_binder na in
    let b = Tac2ffi.to_constr b in
    let c = Tac2ffi.to_constr c in
    EConstr.mkLetIn (na, b, t, c)
  | (9, [|c; cl|]) ->
    let c = Tac2ffi.to_constr c in
    let cl = Tac2ffi.to_array Tac2ffi.to_constr cl in
    EConstr.mkApp (c, cl)
  | (10, [|cst; u|]) ->
    let cst = Tac2ffi.to_constant cst in
    let u = to_instance u in
    EConstr.mkConstU (cst, u)
  | (11, [|ind; u|]) ->
    let ind = Tac2ffi.to_inductive ind in
    let u = to_instance u in
    EConstr.mkIndU (ind, u)
  | (12, [|cstr; u|]) ->
    let cstr = Tac2ffi.to_constructor cstr in
    let u = to_instance u in
    EConstr.mkConstructU (cstr, u)
  | (13, [|ci; c; iv; t; bl|]) ->
    let ci = Tac2ffi.to_case ci in
    let c = Tac2ffi.(to_pair to_constr to_relevance c) in
    let c = on_snd EConstr.ERelevance.make c in
    let iv = to_case_invert iv in
    let t = Tac2ffi.to_constr t in
    let bl = Tac2ffi.to_array Tac2ffi.to_constr bl in
    EConstr.mkCase (EConstr.contract_case env sigma (ci, c, iv, t, bl))
  | (14, [|recs; i; nas; cs|]) ->
    let recs = Tac2ffi.to_array Tac2ffi.to_int recs in
    let i = Tac2ffi.to_int i in
    let def = to_rec_declaration (nas, cs) in
    EConstr.mkFix ((recs, i), def)
  | (15, [|i; nas; cs|]) ->
    let i = Tac2ffi.to_int i in
    let def = to_rec_declaration (nas, cs) in
    EConstr.mkCoFix (i, def)
  | (16, [|p; r; c|]) ->
    let p = Tac2ffi.to_projection p in
    let r = to_relevance r in
    let c = Tac2ffi.to_constr c in
    EConstr.mkProj (p, EConstr.ERelevance.make r, c)
  | (17, [|n|]) ->
    let n = Tac2ffi.to_uint63 n in
    EConstr.mkInt n
  | (18, [|f|]) ->
    let f = Tac2ffi.to_float f in
    EConstr.mkFloat f
  | (19, [|s|]) ->
    let s = Tac2ffi.to_pstring s in
    EConstr.mkString s
  | (20, [|u;t;def;ty|]) ->
    let t = Tac2ffi.to_array Tac2ffi.to_constr t in
    let def = Tac2ffi.to_constr def in
    let ty = Tac2ffi.to_constr ty in
    let u = to_instance u in
    EConstr.mkArray(u,t,def,ty)
  | _ -> assert false

let () =
  define "constr_check" (constr @-> tac valexpr) @@ fun c ->
  pf_apply @@ fun env sigma ->
  try
    let (sigma, _) = Typing.type_of env sigma c in
    Proofview.Unsafe.tclEVARS sigma >>= fun () ->
    return (of_result Tac2ffi.of_constr (Inl c))
  with e when CErrors.noncritical e ->
    let e = Exninfo.capture e in
    return (of_result Tac2ffi.of_constr (Inr e))

let () =
  define "constr_liftn" (int @-> int @-> constr @-> ret constr)
    EConstr.Vars.liftn

let () =
  define "constr_substnl" (list constr @-> int @-> constr @-> ret constr)
    EConstr.Vars.substnl

let () =
  define "constr_closenl" (list ident @-> int @-> constr @-> tac constr)
    @@ fun ids k c ->
  Proofview.tclEVARMAP >>= fun sigma ->
  return (EConstr.Vars.substn_vars sigma k ids c)

let () =
  define "constr_closedn" (int @-> constr @-> tac bool) @@ fun n c ->
  Proofview.tclEVARMAP >>= fun sigma ->
  return (EConstr.Vars.closedn sigma n c)

let () =
  define "constr_noccur_between" (int @-> int @-> constr @-> tac bool) @@ fun n m c ->
  Proofview.tclEVARMAP >>= fun sigma ->
  return (EConstr.Vars.noccur_between sigma n m c)

let () =
  define "constr_case" (inductive @-> tac valexpr) @@ fun ind ->
  Proofview.tclENV >>= fun env ->
  try
    let ans = Inductiveops.make_case_info env ind Constr.RegularStyle in
    return (Tac2ffi.of_case ans)
  with e when CErrors.noncritical e ->
    throw Tac2ffi.err_notfound

let () =
  define "case_to_inductive" (case @-> ret inductive) @@ fun case ->
  case.ci_ind

let () = define "constr_cast_default" (ret valexpr) (of_cast DEFAULTcast)
let () = define "constr_cast_vm" (ret valexpr) (of_cast VMcast)
let () = define "constr_cast_native" (ret valexpr) (of_cast NATIVEcast)

let () =
  define "constr_in_context" (ident @-> constr @-> thunk unit @-> tac constr) @@ fun id t c ->
  Proofview.Goal.goals >>= function
  | [gl] ->
    gl >>= fun gl ->
    let env = Proofview.Goal.env gl in
    let sigma = Proofview.Goal.sigma gl in
    let has_var =
      try
        let _ = Environ.lookup_named id env in
        true
      with Not_found -> false
    in
    if has_var then
      Tacticals.tclZEROMSG (str "Variable already exists")
    else
      let open Context.Named.Declaration in
      let sigma, t_rel =
        let t_ty = Retyping.get_type_of env sigma t in
        (* If the user passed eg ['_] for the type we force it to indeed be a type *)
        let sigma, j = Typing.type_judgment env sigma {uj_val=t; uj_type=t_ty} in
        sigma, EConstr.ESorts.relevance_of_sort j.utj_type
      in
      let nenv = EConstr.push_named (LocalAssum (Context.make_annot id t_rel, t)) env in
      let (sigma, (evt, s)) = Evarutil.new_type_evar nenv sigma Evd.univ_flexible in
      let relevance = EConstr.ESorts.relevance_of_sort s in
      let (sigma, evk) = Evarutil.new_pure_evar (Environ.named_context_val nenv) sigma ~relevance evt in
      Proofview.Unsafe.tclEVARS sigma >>= fun () ->
      Proofview.Unsafe.tclSETGOALS [Proofview.with_empty_state evk] >>= fun () ->
      thaw c >>= fun _ ->
      Proofview.Unsafe.tclSETGOALS [Proofview.goal_with_state (Proofview.Goal.goal gl) (Proofview.Goal.state gl)] >>= fun () ->
      let args = EConstr.identity_subst_val (Environ.named_context_val env) in
      let args = SList.cons (EConstr.mkRel 1) args in
      let ans = EConstr.mkEvar (evk, args) in
      return (EConstr.mkLambda (Context.make_annot (Name id) t_rel, t, ans))
  | _ ->
    throw Tac2ffi.err_notfocussed

(** preterm -> constr *)

let () = define "constr_flags" (ret pretype_flags) constr_flags

let () =
  define "pretype_flags_set_use_coercions"
    (bool @-> pretype_flags @-> ret pretype_flags) @@ fun b flags ->
  { flags with use_coercions = b }

let () =
  define "pretype_flags_set_use_typeclasses"
    (bool @-> pretype_flags @-> ret pretype_flags) @@ fun b flags ->
  { flags with use_typeclasses = if b then UseTC else NoUseTC }

let () =
  define "pretype_flags_set_allow_evars"
    (bool @-> pretype_flags @-> ret pretype_flags) @@ fun b flags ->
  { flags with fail_evar = not b }

let () =
  define "pretype_flags_set_nf_evars"
    (bool @-> pretype_flags @-> ret pretype_flags) @@ fun b flags ->
  { flags with expand_evars = b }

let () = define "expected_istype" (ret expected_type) IsType

let () = define "expected_oftype" (constr @-> ret expected_type) @@ fun c ->
  OfType c

let () = define "expected_without_type_constraint" (ret expected_type)
    WithoutTypeConstraint

let () =
  define "constr_pretype" (pretype_flags @-> expected_type @-> preterm @-> tac constr) @@ fun flags expected_type c ->
  let pretype env sigma =
    let sigma, t = Pretyping.understand_uconstr ~flags ~expected_type env sigma c in
    Proofview.Unsafe.tclEVARS sigma <*> Proofview.tclUNIT t
  in
  pf_apply ~catch_exceptions:true pretype

let () =
  define "constr_binder_make" (option ident @-> constr @-> tac binder) @@ fun na ty ->
  pf_apply @@ fun env sigma ->
  match Retyping.relevance_of_type env sigma ty with
  | rel ->
    let na = match na with None -> Anonymous | Some id -> Name id in
    return (Context.make_annot na rel, ty)
  | exception (Retyping.RetypeError _ as e) ->
    let e, info = Exninfo.capture e in
    fail ~info (CErrors.UserError Pp.(str "Not a type."))

let () =
  define "constr_binder_unsafe_make"
    (option ident @-> relevance @-> constr @-> ret binder)
    @@ fun na rel ty ->
  let na = match na with None -> Anonymous | Some id -> Name id in
  Context.make_annot na (EConstr.ERelevance.make rel), ty

let () =
  define "constr_binder_name" (binder @-> ret (option ident)) @@ fun (bnd, _) ->
  match bnd.Context.binder_name with Anonymous -> None | Name id -> Some id

let () =
  define "constr_binder_type" (binder @-> ret constr) @@ fun (_, ty) -> ty

let () =
  define "constr_binder_relevance" (binder @-> ret relevance) @@ fun (na, _) ->
  EConstr.Unsafe.to_relevance na.binder_relevance

let () =
  define "constr_has_evar" (constr @-> tac bool) @@ fun c ->
  Proofview.tclEVARMAP >>= fun sigma ->
  return (Evarutil.has_undefined_evars sigma c)

(** Uint63 *)

let () = define "uint63_compare" (uint63 @-> uint63 @-> ret int) Uint63.compare

let () = define "uint63_of_int" (int @-> ret uint63) Uint63.of_int

let () = define "uint63_print" (uint63 @-> ret pp) @@ fun i ->
  Pp.str (Uint63.to_string i)

(** Extra equalities *)

let () = define "evar_equal" (evar @-> evar @-> ret bool) Evar.equal
let () = define "float_equal" (float @-> float @-> ret bool) Float64.equal
let () = define "uint63_equal" (uint63 @-> uint63 @-> ret bool) Uint63.equal
let () = define "meta_equal" (int @-> int @-> ret bool) Int.equal
let () = define "constr_cast_equal" (cast @-> cast @-> ret bool) Glob_ops.cast_kind_eq

let () =
  define "constant_equal"
    (constant @-> constant @-> ret bool)
    Constant.UserOrd.equal
let () =
  define "constr_case_equal" (case @-> case @-> ret bool) @@ fun x y ->
  Ind.UserOrd.equal x.ci_ind y.ci_ind
let () =
  define "constructor_equal" (constructor @-> constructor @-> ret bool) Construct.UserOrd.equal
let () =
  define "projection_equal" (projection @-> projection @-> ret bool) Projection.UserOrd.equal

(** Patterns *)

let () =
  define "pattern_empty_context" (ret matching_context)
    Constr_matching.empty_context

let () =
  define "pattern_matches" (pattern @-> constr @-> tac valexpr) @@ fun pat c ->
  pf_apply @@ fun env sigma ->
  let ans =
    try Some (Constr_matching.matches env sigma pat c)
    with Constr_matching.PatternMatchingFailure -> None
  in
  begin match ans with
  | None -> fail Tac2ffi.err_matchfailure
  | Some ans ->
    let ans = Id.Map.bindings ans in
    let of_pair (id, c) = Tac2ffi.of_tuple [| Tac2ffi.of_ident id; Tac2ffi.of_constr c |] in
    return (Tac2ffi.of_list of_pair ans)
  end

let () =
  define "pattern_matches_subterm" (pattern @-> constr @-> tac (pair matching_context (list (pair ident constr)))) @@ fun pat c ->
  let open Constr_matching in
  let rec of_ans s = match IStream.peek s with
  | IStream.Nil -> fail Tac2ffi.err_matchfailure
  | IStream.Cons ({ m_sub = (_, sub); m_ctx }, s) ->
    let ans = Id.Map.bindings sub in
    Proofview.tclOR (return (m_ctx, ans)) (fun _ -> of_ans s)
  in
  pf_apply @@ fun env sigma ->
  let ans = Constr_matching.match_subterm env sigma (Id.Set.empty,pat) c in
  of_ans ans

let () =
  define "pattern_matches_vect" (pattern @-> constr @-> tac valexpr) @@ fun pat c ->
  pf_apply @@ fun env sigma ->
  let ans =
    try Some (Constr_matching.matches env sigma pat c)
    with Constr_matching.PatternMatchingFailure -> None
  in
  match ans with
  | None -> fail Tac2ffi.err_matchfailure
  | Some ans ->
    let ans = Id.Map.bindings ans in
    let ans = Array.map_of_list snd ans in
    return (Tac2ffi.of_array Tac2ffi.of_constr ans)

let () =
  define "pattern_matches_subterm_vect" (pattern @-> constr @-> tac (pair matching_context (array constr))) @@ fun pat c ->
  let open Constr_matching in
  let rec of_ans s = match IStream.peek s with
  | IStream.Nil -> fail Tac2ffi.err_matchfailure
  | IStream.Cons ({ m_sub = (_, sub); m_ctx }, s) ->
    let ans = Id.Map.bindings sub in
    let ans = Array.map_of_list snd ans in
    Proofview.tclOR (return (m_ctx,ans)) (fun _ -> of_ans s)
  in
  pf_apply @@ fun env sigma ->
  let ans = Constr_matching.match_subterm env sigma (Id.Set.empty,pat) c in
  of_ans ans

let match_pattern = map_repr
    (fun (b,pat) -> if b then Tac2match.MatchPattern pat else Tac2match.MatchContext pat)
    (function Tac2match.MatchPattern pat -> (true, pat) | MatchContext pat -> (false, pat))
    (pair bool pattern)

let () =
  define "pattern_matches_goal"
    (bool @-> list (pair (option match_pattern) match_pattern) @-> match_pattern @-> tac valexpr)
    @@ fun rev hp cp ->
  assert_focussed >>= fun () ->
  Proofview.Goal.enter_one @@ fun gl ->
  let env = Proofview.Goal.env gl in
  let sigma = Proofview.Goal.sigma gl in
  let concl = Proofview.Goal.concl gl in
  Tac2match.match_goal env sigma concl ~rev (hp, cp) >>= fun (hyps, ctx, subst) ->
  let empty_context = Constr_matching.empty_context in
  let of_ctxopt ctx = Tac2ffi.of_matching_context (Option.default empty_context ctx) in
  let hids = Tac2ffi.of_array Tac2ffi.of_ident (Array.map_of_list pi1 hyps) in
  let hbctx = Tac2ffi.of_array of_ctxopt
      (Array.of_list (CList.filter_map (fun (_,bctx,_) -> bctx) hyps))
  in
  let hctx = Tac2ffi.of_array of_ctxopt (Array.map_of_list pi3 hyps) in
  let subs = Tac2ffi.of_array Tac2ffi.of_constr (Array.map_of_list snd (Id.Map.bindings subst)) in
  let cctx = of_ctxopt ctx in
  let ans = Tac2ffi.of_tuple [| hids; hbctx; hctx; subs; cctx |] in
  Proofview.tclUNIT ans

let () =
  define "pattern_instantiate"
    (matching_context @-> constr @-> ret constr)
    Constr_matching.instantiate_context

(** Error *)

let () =
  define "throw" (exn @-> tac valexpr) @@ fun (e, info) -> throw ~info e

let () =
  define "throw_bt" (exn @-> exninfo @-> tac valexpr) @@ fun (e,_) info ->
    Proofview.tclLIFT (Proofview.NonLogical.raise (e, info))

let () =
  define "clear_err_info" (err @-> ret err) @@ fun (e,_) -> (e, Exninfo.null)

(** Control *)

(** exn -> 'a *)
let () =
  define "zero" (exn @-> tac valexpr) @@ fun (e, info) -> fail ~info e

let () =
  define "zero_bt" (exn @-> exninfo @-> tac valexpr) @@ fun (e,_) info ->
    Proofview.tclZERO ~info e

(** (unit -> 'a) -> (exn -> 'a) -> 'a *)
let () =
  define "plus" (thunk valexpr @-> fun1 exn valexpr @-> tac valexpr) @@ fun x k ->
  Proofview.tclOR (thaw x) k

let () =
  define "plus_bt" (thunk valexpr @-> fun2 exn exninfo valexpr @-> tac valexpr) @@ fun run handle ->
    Proofview.tclOR (thaw run) (fun e -> handle e (snd e))

(** (unit -> 'a) -> 'a *)
let () =
  define "once" (thunk valexpr @-> tac valexpr) @@ fun f ->
  Proofview.tclONCE (thaw f)

(** (unit -> 'a) -> ('a * ('exn -> 'a)) result *)
let () =
  define "case" (thunk valexpr @-> tac (result (pair valexpr (fun1 exn valexpr)))) @@ fun f ->
  Proofview.tclCASE (thaw f) >>= begin function
  | Proofview.Next (x, k) ->
    let k (e,info) = set_bt info >>= fun info -> k (e,info) in
    return (Ok (x, k))
  | Proofview.Fail e -> return (Error e)
  end

let () =
  define "numgoals" (unit @-> tac int) @@ fun () ->
  Proofview.numgoals

(** (unit -> unit) list -> unit *)
let () =
  define "dispatch" (list (thunk unit) @-> tac unit) @@ fun l ->
  let l = List.map (fun f -> thaw f) l in
  Proofview.tclDISPATCH l

(** (unit -> unit) list -> (unit -> unit) -> (unit -> unit) list -> unit *)
let () =
  define "extend" (list (thunk unit) @-> thunk unit @-> list (thunk unit) @-> tac unit) @@ fun lft tac rgt ->
  let lft = List.map (fun f -> thaw f) lft in
  let tac = thaw tac in
  let rgt = List.map (fun f -> thaw f) rgt in
  Proofview.tclEXTEND lft tac rgt

(** (unit -> unit) -> unit *)
let () =
  define "enter" (thunk unit @-> tac unit) @@ fun f ->
  let f = Proofview.tclIGNORE (thaw f) in
  Proofview.tclINDEPENDENT f

(** int -> int -> (unit -> 'a) -> 'a *)
let () =
  define "focus" (int @-> int @-> thunk valexpr @-> tac valexpr) @@ fun i j tac ->
  Proofview.tclFOCUS i j (thaw tac)

(** int -> unit **)
let () =
  define "cycle" (int @-> tac unit) @@ fun i ->
  Proofview.cycle i

(** unit -> unit *)
let () = define "shelve" (unit @-> tac unit) @@ fun _ -> Proofview.shelve

(** unit -> unit *)
let () =
  define "shelve_unifiable" (unit @-> tac unit) @@ fun _ ->
  Proofview.shelve_unifiable

let () =
  define "new_goal" (evar @-> tac unit) @@ fun ev ->
  Proofview.tclEVARMAP >>= fun sigma ->
  if Evd.mem sigma ev then
    let sigma = Evd.remove_future_goal sigma ev in
    let sigma = Evd.unshelve sigma [ev] in
    Proofview.Unsafe.tclEVARS sigma <*>
    Proofview.Unsafe.tclNEWGOALS [Proofview.with_empty_state ev] <*>
    Proofview.tclUNIT ()
  else throw Tac2ffi.err_notfound

let () =
  define "unshelve" (thunk valexpr @-> tac valexpr) @@ fun t ->
  Proofview.with_shelf (thaw t) >>= fun (gls,v) ->
  let gls = List.map Proofview.with_empty_state gls in
  Proofview.Unsafe.tclGETGOALS >>= fun ogls ->
  Proofview.Unsafe.tclSETGOALS (gls @ ogls) >>= fun () ->
  return v

(** unit -> constr *)
let () =
  define "goal" (unit @-> tac constr) @@ fun _ ->
  assert_focussed >>= fun () ->
  Proofview.Goal.enter_one @@ fun gl -> return (Tacmach.pf_nf_concl gl)

(** ident -> constr *)
let () =
  define "hyp" (ident @-> tac constr) @@ fun id ->
  pf_apply @@ fun env _ ->
  let mem = try ignore (Environ.lookup_named id env); true with Not_found -> false in
  if mem then return (EConstr.mkVar id)
  else Tacticals.tclZEROMSG
    (str "Hypothesis " ++ quote (Id.print id) ++ str " not found") (* FIXME: Do something more sensible *)

let () =
  define "hyp_value" (ident @-> tac (option constr)) @@ fun id ->
  pf_apply @@ fun env _ ->
  match EConstr.lookup_named id env with
  | d -> return (Context.Named.Declaration.get_value d)
  | exception Not_found ->
    Tacticals.tclZEROMSG
    (str "Hypothesis " ++ quote (Id.print id) ++ str " not found") (* FIXME: Do something more sensible *)

let () =
  define "hyps" (unit @-> tac valexpr) @@ fun _ ->
  pf_apply @@ fun env _ ->
  let open Context in
  let open Named.Declaration in
  let hyps = List.rev (Environ.named_context env) in
  let map = function
  | LocalAssum (id, t) ->
    let t = EConstr.of_constr t in
    Tac2ffi.of_tuple [|
      Tac2ffi.of_ident id.binder_name;
      Tac2ffi.of_option Tac2ffi.of_constr None;
      Tac2ffi.of_constr t;
    |]
  | LocalDef (id, c, t) ->
    let c = EConstr.of_constr c in
    let t = EConstr.of_constr t in
    Tac2ffi.of_tuple [|
      Tac2ffi.of_ident id.binder_name;
      Tac2ffi.of_option Tac2ffi.of_constr (Some c);
      Tac2ffi.of_constr t;
    |]
  in
  return (Tac2ffi.of_list map hyps)

(** (unit -> constr) -> unit *)
let () =
  define "refine" (thunk constr @-> tac unit) @@ fun c ->
  let c = thaw c >>= fun c -> Proofview.tclUNIT ((), c, None) in
  Proofview.Goal.enter @@ fun gl ->
  Refine.generic_refine ~typecheck:true c gl

let () =
  define "with_holes" (thunk valexpr @-> fun1 valexpr valexpr @-> tac valexpr) @@ fun x f ->
  Tacticals.tclRUNWITHHOLES false (thaw x) f

let () =
  define "progress" (thunk valexpr @-> tac valexpr) @@ fun f ->
  Proofview.tclPROGRESS (thaw f)

let () =
  define "abstract" (option ident @-> thunk unit @-> tac unit) @@ fun id f ->
  Abstract.tclABSTRACT id (thaw f)

let () =
  define "time" (option string @-> thunk valexpr @-> tac valexpr) @@ fun s f ->
  Proofview.tclTIME s (thaw f)

let () =
  define "timeout" (int @-> thunk valexpr @-> tac valexpr) @@ fun i f ->
    Proofview.tclTIMEOUT i (thaw f)

let () =
  define "timeoutf" (float @-> thunk valexpr @-> tac valexpr) @@ fun f64 f ->
    Proofview.tclTIMEOUTF (Float64.to_float f64) (thaw f)

let () =
  define "check_interrupt" (unit @-> tac unit) @@ fun _ ->
  Proofview.tclCHECKINTERRUPT

(** Fresh *)

let () = define "fresh_free_empty" (ret free) Nameops.Fresh.empty

let () = define "fresh_free_add" (ident @-> free @-> ret free) Nameops.Fresh.add

let () =
  define "fresh_free_union" (free @-> free @-> ret free) Nameops.Fresh.union

let () =
  define "fresh_free_of_ids" (list ident @-> ret free) @@ fun ids ->
  List.fold_right Nameops.Fresh.add ids Nameops.Fresh.empty

let () =
  define "fresh_free_of_constr" (constr @-> tac free) @@ fun c ->
  Proofview.tclEVARMAP >>= fun sigma ->
  let rec fold accu c =
    match EConstr.kind sigma c with
    | Constr.Var id -> Nameops.Fresh.add id accu
    | _ -> EConstr.fold sigma fold accu c
  in
  return (fold Nameops.Fresh.empty c)

(* for backwards compat reasons the ocaml and ltac2 APIs
   exchange the meaning of "fresh" and "next" *)
let () =
  define "fresh_next" (free @-> ident @-> ret (pair ident free)) @@ fun avoid id ->
  let id = Namegen.mangle_id id in
  Nameops.Fresh.fresh id avoid

let () =
  define "fresh_fresh" (free @-> ident @-> ret ident) @@ fun avoid id ->
  let id = Namegen.mangle_id id in
  Nameops.Fresh.next id avoid

(** Env *)

let () =
  define "env_get" (list ident @-> ret (option reference)) @@ fun ids ->
  match ids with
  | [] -> None
  | _ :: _ as ids ->
    let (id, path) = List.sep_last ids in
    let path = DirPath.make (List.rev path) in
    let fp = Libnames.make_path path id in
    try Some (Nametab.global_of_path fp) with Not_found -> None

let () =
  define "env_expand" (list ident @-> ret (list reference)) @@ fun ids ->
  match ids with
  | [] -> []
  | _ :: _ as ids ->
    let (id, path) = List.sep_last ids in
    let path = DirPath.make (List.rev path) in
    let qid = Libnames.make_qualid path id in
    Nametab.locate_all qid

let () =
  define "env_path" (reference @-> tac (list ident)) @@ fun r ->
  match Nametab.path_of_global r with
  | fp ->
    let (path, id) = Libnames.repr_path fp in
    let path = DirPath.repr path in
    return (List.rev_append path [id])
  | exception Not_found ->
    throw Tac2ffi.err_notfound

let () =
  define "env_instantiate" (reference @-> tac constr) @@ fun r ->
  Proofview.tclENV >>= fun env ->
  Proofview.tclEVARMAP >>= fun sigma ->
  let (sigma, c) = Evd.fresh_global env sigma r in
  Proofview.Unsafe.tclEVARS sigma >>= fun () ->
  return c

(** Ind *)

let () =
  define "ind_equal" (inductive @-> inductive @-> ret bool) Ind.UserOrd.equal

let () =
  define "ind_data"
    (inductive @-> tac ind_data)
    @@ fun ind ->
  Proofview.tclENV >>= fun env ->
  if Environ.mem_mind (fst ind) env then
    return (ind, Environ.lookup_mind (fst ind) env)
  else
    throw Tac2ffi.err_notfound

let () = define "ind_repr" (ind_data @-> ret inductive) fst
let () = define "ind_index" (inductive @-> ret int) snd

let () =
  define "ind_nblocks" (ind_data @-> ret int) @@ fun (_, mib) ->
  Array.length mib.Declarations.mind_packets

let () =
  define "ind_nconstructors" (ind_data @-> ret int) @@ fun ((_, n), mib) ->
  Array.length Declarations.(mib.mind_packets.(n).mind_consnames)

let () =
  define "ind_get_block"
    (ind_data @-> int @-> tac ind_data)
    @@ fun (ind, mib) n ->
  if 0 <= n && n < Array.length mib.Declarations.mind_packets then
    return ((fst ind, n), mib)
  else throw Tac2ffi.err_notfound

let () =
  define "ind_get_constructor"
    (ind_data @-> int @-> tac constructor)
    @@ fun ((mind, n), mib) i ->
  let open Declarations in
  let ncons = Array.length mib.mind_packets.(n).mind_consnames in
  if 0 <= i && i < ncons then
    (* WARNING: In the ML API constructors are indexed from 1 for historical
       reasons, but Ltac2 uses 0-indexing instead. *)
    return ((mind, n), i + 1)
  else throw Tac2ffi.err_notfound

let () =
  define "ind_get_nparams"
    (ind_data @-> ret int) @@ fun (_, mib) ->
  mib.Declarations.mind_nparams

let () =
  define "ind_get_nparams_rec"
    (ind_data @-> ret int) @@ fun (_, mib) ->
  mib.Declarations.mind_nparams_rec

let () =
  define "constructor_inductive"
    (constructor @-> ret inductive)
  @@ fun (ind, _) -> ind

let () =
  define "constructor_index"
    (constructor @-> ret int)
  @@ fun (_, i) ->
  (* WARNING: ML constructors are 1-indexed but Ltac2 constructors are 0-indexed *)
  i-1

let () =
  define "constructor_nargs"
    (ind_data @-> ret (array int)) @@ fun ((_,i),mib) ->
  let open Declarations in
  mib.mind_packets.(i).mind_consnrealargs

let () =
  define "constructor_ndecls"
    (ind_data @-> ret (array int)) @@ fun ((_,i),mib) ->
  let open Declarations in
  mib.mind_packets.(i).mind_consnrealdecls

let () =
  define "ind_get_projections" (ind_data @-> ret (option (array projection)))
  @@ fun (ind,mib) ->
  Declareops.inductive_make_projections ind mib
  |> Option.map (Array.map (fun (p,_) -> Projection.make p false))

(** Proj *)

let () =
  define "projection_ind" (projection @-> ret inductive) Projection.inductive

let () =
  define "projection_index" (projection @-> ret int) Projection.arg

let () =
  define "projection_unfolded" (projection @-> ret bool) Projection.unfolded

let () =
  define "projection_set_unfolded" (projection @-> bool @-> ret projection) @@ fun p b ->
  Projection.make (Projection.repr p) b

let () =
  define "projection_of_constant" (constant @-> ret (option projection)) @@ fun c ->
  Structures.PrimitiveProjections.find_opt c |> Option.map (fun p -> Projection.make p false)

let () =
  define "projection_to_constant" (projection @-> ret (option constant)) @@ fun p ->
  Some (Projection.constant p)

module MapTagDyn = Dyn.Make()

type ('a,'set,'map) map_tag = ('a * 'set * 'map) MapTagDyn.tag

type any_map_tag = Any : _ map_tag -> any_map_tag
type tagged_set = TaggedSet : (_,'set,_) map_tag * 'set -> tagged_set
type tagged_map = TaggedMap : (_,_,'map) map_tag * 'map -> tagged_map

let map_tag_ext : any_map_tag Tac2dyn.Val.tag = Tac2dyn.Val.create "fmap_tag"
let map_tag_repr = Tac2ffi.repr_ext map_tag_ext

let set_ext : tagged_set Tac2dyn.Val.tag = Tac2dyn.Val.create "fset"
let set_repr = Tac2ffi.repr_ext set_ext
let tag_set tag s = Tac2ffi.repr_of set_repr (TaggedSet (tag,s))

let map_ext : tagged_map Tac2dyn.Val.tag = Tac2dyn.Val.create "fmap"
let map_repr = Tac2ffi.repr_ext map_ext
let tag_map tag m = Tac2ffi.repr_of map_repr (TaggedMap (tag,m))

module type MapType = sig
  (* to have less boilerplate we use S.elt rather than declaring a toplevel type t *)
  module S : CSig.USetS
  module M : CMap.UExtS with type key = S.elt and module Set := S
  type valmap
  val valmap_eq : (valmap, valexpr M.t) Util.eq
  val repr : S.elt Tac2ffi.repr
end

module MapTypeV = struct
  type _ t = Map : (module MapType with type S.elt = 't and type S.t = 'set and type valmap = 'map)
    -> ('t * 'set * 'map) t
end

module MapMap = MapTagDyn.Map(MapTypeV)

let maps = ref MapMap.empty

let register_map ?(plugin=ltac2_plugin) ~tag_name x =
  let tag = MapTagDyn.create (plugin^":"^tag_name) in
  let () = maps := MapMap.add tag (Map x) !maps in
  let () = define ~plugin tag_name (ret map_tag_repr) (Any tag) in
  tag

let get_map (type t s m) (tag:(t,s,m) map_tag)
  : (module MapType with type S.elt = t and type S.t = s and type valmap = m) =
  let Map v = MapMap.find tag !maps in
  v

let map_tag_eq (type a b c a' b' c') (t1:(a,b,c) map_tag) (t2:(a',b',c') map_tag)
  : (a*b*c,a'*b'*c') Util.eq option
  = MapTagDyn.eq t1 t2

let assert_map_tag_eq t1 t2 = match map_tag_eq t1 t2 with
  | Some v -> v
  | None -> assert false

let ident_map_tag : _ map_tag = register_map ~tag_name:"fmap_ident_tag" (module struct
    module S = Id.Set
    module M = Id.Map
    let repr = Tac2ffi.ident
    type valmap = valexpr M.t
    let valmap_eq = Refl
  end)

let int_map_tag : _ map_tag = register_map ~tag_name:"fmap_int_tag" (module struct
    module S = Int.Set
    module M = Int.Map
    let repr = Tac2ffi.int
    type valmap = valexpr M.t
    let valmap_eq = Refl
  end)

let string_map_tag : _ map_tag = register_map ~tag_name:"fmap_string_tag" (module struct
    module S = String.Set
    module M = String.Map
    let repr = Tac2ffi.string
    type valmap = valexpr M.t
    let valmap_eq = Refl
  end)

let inductive_map_tag : _ map_tag = register_map ~tag_name:"fmap_inductive_tag" (module struct
    module S = Indset_env
    module M = Indmap_env
    let repr = inductive
    type valmap = valexpr M.t
    let valmap_eq = Refl
  end)

let constructor_map_tag : _ map_tag = register_map ~tag_name:"fmap_constructor_tag" (module struct
    module S = Constrset_env
    module M = Constrmap_env
    let repr = Tac2ffi.constructor
    type valmap = valexpr M.t
    let valmap_eq = Refl
  end)

let constant_map_tag : _ map_tag = register_map ~tag_name:"fmap_constant_tag" (module struct
    module S = Cset_env
    module M = Cmap_env
    let repr = Tac2ffi.constant
    type valmap = valexpr M.t
    let valmap_eq = Refl
  end)

let () =
  define "fset_empty" (map_tag_repr @-> ret valexpr) @@ fun (Any tag) ->
  let (module V) = get_map tag in
  tag_set tag V.S.empty

let () =
  define "fset_is_empty" (set_repr @-> ret bool) @@ fun (TaggedSet (tag,s)) ->
  let (module V) = get_map tag in
  V.S.is_empty s

let () =
  define "fset_mem" (valexpr @-> set_repr @-> ret bool) @@ fun x (TaggedSet (tag,s)) ->
  let (module V) = get_map tag in
  V.S.mem (repr_to V.repr x) s

let () =
  define "fset_add" (valexpr @-> set_repr @-> ret valexpr) @@ fun x (TaggedSet (tag,s)) ->
  let (module V) = get_map tag in
  tag_set tag (V.S.add (repr_to V.repr x) s)

let () =
  define "fset_remove" (valexpr @-> set_repr @-> ret valexpr) @@ fun x (TaggedSet (tag,s)) ->
  let (module V) = get_map tag in
  tag_set tag (V.S.remove (repr_to V.repr x) s)

let () =
  define "fset_union" (set_repr @-> set_repr @-> ret valexpr)
    @@ fun (TaggedSet (tag,s1)) (TaggedSet (tag',s2)) ->
  let Refl = assert_map_tag_eq tag tag' in
  let (module V) = get_map tag in
  tag_set tag (V.S.union s1 s2)

let () =
  define "fset_inter" (set_repr @-> set_repr @-> ret valexpr)
    @@ fun (TaggedSet (tag,s1)) (TaggedSet (tag',s2)) ->
  let Refl = assert_map_tag_eq tag tag' in
  let (module V) = get_map tag in
  tag_set tag (V.S.inter s1 s2)

let () =
  define "fset_diff" (set_repr @-> set_repr @-> ret valexpr)
    @@ fun (TaggedSet (tag,s1)) (TaggedSet (tag',s2)) ->
  let Refl = assert_map_tag_eq tag tag' in
  let (module V) = get_map tag in
  tag_set tag (V.S.diff s1 s2)

let () =
  define "fset_equal" (set_repr @-> set_repr @-> ret bool)
    @@ fun (TaggedSet (tag,s1)) (TaggedSet (tag',s2)) ->
  let Refl = assert_map_tag_eq tag tag' in
  let (module V) = get_map tag in
  V.S.equal s1 s2

let () =
  define "fset_subset" (set_repr @-> set_repr @-> ret bool)
    @@ fun (TaggedSet (tag,s1)) (TaggedSet (tag',s2)) ->
  let Refl = assert_map_tag_eq tag tag' in
  let (module V) = get_map tag in
  V.S.subset s1 s2

let () =
  define "fset_cardinal" (set_repr @-> ret int) @@ fun (TaggedSet (tag,s)) ->
  let (module V) = get_map tag in
  V.S.cardinal s

let () =
  define "fset_elements" (set_repr @-> ret valexpr) @@ fun (TaggedSet (tag,s)) ->
  let (module V) = get_map tag in
  Tac2ffi.of_list (repr_of V.repr) (V.S.elements s)

let () =
  define "fmap_empty" (map_tag_repr @-> ret valexpr) @@ fun (Any (tag)) ->
  let (module V) = get_map tag in
  let Refl = V.valmap_eq in
  tag_map tag V.M.empty

let () =
  define "fmap_is_empty" (map_repr @-> ret bool) @@ fun (TaggedMap (tag,m)) ->
  let (module V) = get_map tag in
  let Refl = V.valmap_eq in
  V.M.is_empty m

let () =
  define "fmap_mem" (valexpr @-> map_repr @-> ret bool) @@ fun x (TaggedMap (tag,m)) ->
  let (module V) = get_map tag in
  let Refl = V.valmap_eq in
  V.M.mem (repr_to V.repr x) m

let () =
  define "fmap_add" (valexpr @-> valexpr @-> map_repr @-> ret valexpr)
    @@ fun x v (TaggedMap (tag,m)) ->
  let (module V) = get_map tag in
  let Refl = V.valmap_eq in
  tag_map tag (V.M.add (repr_to V.repr x) v m)

let () =
  define "fmap_remove" (valexpr @-> map_repr @-> ret valexpr)
    @@ fun x (TaggedMap (tag,m)) ->
  let (module V) = get_map tag in
  let Refl = V.valmap_eq in
  tag_map tag (V.M.remove (repr_to V.repr x) m)

let () =
  define "fmap_find_opt" (valexpr @-> map_repr @-> ret (option valexpr))
    @@ fun x (TaggedMap (tag,m)) ->
  let (module V) = get_map tag in
  let Refl = V.valmap_eq in
  V.M.find_opt (repr_to V.repr x) m

let () =
  define "fmap_mapi" (closure @-> map_repr @-> tac valexpr)
    @@ fun f (TaggedMap (tag,m)) ->
  let (module V) = get_map tag in
  let Refl = V.valmap_eq in
  let module Monadic = V.M.Monad(Proofview.Monad) in
  Monadic.mapi (fun k v -> apply f [repr_of V.repr k;v]) m >>= fun m ->
  return (tag_map tag m)

let () =
  define "fmap_fold" (closure @-> map_repr @-> valexpr @-> tac valexpr)
    @@ fun f (TaggedMap (tag,m)) acc ->
  let (module V) = get_map tag in
  let Refl = V.valmap_eq in
  let module Monadic = V.M.Monad(Proofview.Monad) in
  Monadic.fold (fun k v acc -> apply f [repr_of V.repr k;v;acc]) m acc

let () =
  define "fmap_cardinal" (map_repr @-> ret int) @@ fun (TaggedMap (tag,m)) ->
  let (module V) = get_map tag in
  let Refl = V.valmap_eq in
  V.M.cardinal m

let () =
  define "fmap_bindings" (map_repr @-> ret valexpr) @@ fun (TaggedMap (tag,m)) ->
  let (module V) = get_map tag in
  let Refl = V.valmap_eq in
  Tac2ffi.(of_list (of_pair (repr_of V.repr) identity) (V.M.bindings m))

let () =
  define "fmap_domain" (map_repr @-> ret valexpr) @@ fun (TaggedMap (tag,m)) ->
  let (module V) = get_map tag in
  let Refl = V.valmap_eq in
  tag_set tag (V.M.domain m)
