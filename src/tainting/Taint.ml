(* Iago Abal
 *
 * Copyright (C) 2022 r2c
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public License
 * version 2.1 as published by the Free Software Foundation, with the
 * special exception on linking described in file LICENSE.
 *
 * This library is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the file
 * LICENSE for more details.
 *)

module G = AST_generic
module PM = Pattern_match

let logger = Logging.get_logger [ __MODULE__ ]

(*****************************************************************************)
(* Call traces *)
(*****************************************************************************)

type tainted_tokens = G.tok list [@@deriving show]
(* TODO: Given that the analysis is path-insensitive, the trace should capture
 * all potential paths. So a set of tokens seems more appropriate than a list.
 * TODO: May have to annotate each tainted token with a `call_trace` that explains
 * how it got tainted, so it may help triaging. For example, if we got
 * `x = f(tainted)`, it may be interesting to see how is `f` propagating the
 * taint from its input.
 *)

type 'a call_trace =
  | PM of PM.t * 'a
  | Call of G.expr * tainted_tokens * 'a call_trace
[@@deriving show]

let length_of_call_trace ct =
  let rec loop acc = function
    | PM _ -> acc
    | Call (_, _, ct') -> loop (acc + 1) ct'
  in
  loop 0 ct

type sink = { pm : Pattern_match.t; rule_sink : Rule.taint_sink }
[@@deriving show]

let rec pm_of_trace = function
  | PM (pm, x) -> (pm, x)
  | Call (_, _, trace) -> pm_of_trace trace

let trace_of_pm (pm, x) = PM (pm, x)

let rec _show_call_trace show_thing = function
  | PM (pm, x) ->
      let toks = Lazy.force pm.PM.tokens |> List.filter Tok.is_origintok in
      let s = toks |> Common.map Tok.content_of_tok |> String.concat " " in
      Printf.sprintf "%s [%s]" s (show_thing x)
  | Call (_e, _, trace) ->
      Printf.sprintf "Call(... %s)" (_show_call_trace show_thing trace)

(*****************************************************************************)
(* Signatures *)
(*****************************************************************************)

type arg_pos = string * int [@@deriving show]
type arg = { pos : arg_pos; offset : IL.name list } [@@deriving show]

let _show_arg { pos = s, i; offset = os } =
  if os <> [] then
    let os_str =
      os |> Common.map (fun n -> fst n.IL.ident) |> String.concat "."
    in
    Printf.sprintf "arg(%s)#%d.%s" s i os_str
  else Printf.sprintf "arg(%s)#%d" s i

(*****************************************************************************)
(* Preconditions *)
(*****************************************************************************)

(* We roll our own boolean formula type here because we need to be
   able to use polymorphic compare. Comparison on the Generic AST
   isn't possible, and polymorphic compare would otherwise take into account
   unimportant details like tokens.
*)
type precondition =
  | Label of string
  | Bool of bool
  | And of precondition list
  | Or of precondition list
  | Not of precondition
[@@deriving show]

let rec expr_to_precondition e =
  match e.G.e with
  | G.L (G.Bool (v, _)) -> Bool v
  | G.N (G.Id ((str, _), _)) -> Label str
  | G.Call ({ e = G.IdSpecial (G.Op G.Not, _); _ }, (_, [ Arg e1 ], _)) ->
      Not (expr_to_precondition e1)
  | G.Call ({ e = G.IdSpecial (G.Op op, _); _ }, (_, args, _)) -> (
      match (op, args_to_precondition args) with
      | G.And, xs -> And xs
      | G.Or, xs -> Or xs
      | __else__ ->
          logger#error "Unexpected Boolean operator";
          Bool false)
  | G.ParenExpr (_, e, _) -> expr_to_precondition e
  | ___else__ ->
      logger#error "Unexpected `requires' expression";
      Bool false

and args_to_precondition args =
  match args with
  | [] -> []
  | G.Arg e :: args' -> expr_to_precondition e :: args_to_precondition args'
  | _ :: args' ->
      logger#error "Unexpected argument kind";
      Bool false :: args_to_precondition args'

(*****************************************************************************)
(* Taint *)
(*****************************************************************************)

type source = {
  call_trace : Rule.taint_source call_trace;
  label : string;
      (* This is needed because we may change the label of a taint,
         from the original source that it came from.
         This happens from propagators which change the label of the taint.
         We don't put it under `taint`, though, because Arg taints are
         supposed to be polymorphic in label.
      *)
  precondition : (taint list * precondition) option;
}
[@@deriving show]

and orig = Src of source | Arg of arg [@@deriving show]
and taint = { orig : orig; tokens : tainted_tokens } [@@deriving show]

let substitute_precondition_arg_taint ~arg_fn taint =
  let rec aux taint =
    match taint.orig with
    | Arg arg -> arg_fn arg
    | Src ({ precondition = None; _ } as src) ->
        [ { taint with orig = Src src } ]
    | Src ({ precondition = Some (incoming, expr); _ } as src) ->
        let new_incoming = List.concat_map aux incoming in
        let new_precondition = Some (new_incoming, expr) in
        [
          { taint with orig = Src { src with precondition = new_precondition } };
        ]
  in
  (* We only want to replace preconditions! This function is called after
     we already have replaced the top-level Arg taints, meaning that if we
     just call `aux` outright, we might replace an Arg that we just produced.

     For instance, suppose we replace Arg x with Arg y. Then, we run this
     function on Arg y, and replace it with []. The ultimate effect is that
     we erase the taint we just put in.
  *)
  match taint.orig with
  | Arg _ -> [ taint ]
  | Src _ -> aux taint

let rec compare_precondition (ts1, f1) (ts2, f2) =
  match List.compare compare_taint ts1 ts2 with
  | 0 ->
      (* We use polymorphic compare here, because these preconditions
         should be safe to compare, due to carrying no extraneous
         data, and otherwise only comprising of base types.
      *)
      Stdlib.compare f1 f2
  | other -> other

and compare_sources s1 s2 =
  (* Comparing metavariable environments this way is not robust, e.g.:
   * [("$A",e1);("$B",e2)] is not considered equal to [("$B",e2);("$A",e1)].
   * For our purposes, this is OK.
   *)
  let pm1, ts1 = pm_of_trace s1.call_trace
  and pm2, ts2 = pm_of_trace s2.call_trace in
  match
    Stdlib.compare
      (pm1.rule_id, pm1.range_loc, pm1.env, s1.label, ts1.Rule.label)
      (pm2.rule_id, pm2.range_loc, pm2.env, s2.label, ts2.Rule.label)
  with
  | 0 ->
      (* It's important that we include preconditions as a distinguishing factor
         between two taints.

         Otherwise, suppose that we had a taint with label A with precondition `false`
         and one with precondition `true`. Obviously, only one actually exists. But
         if we pick the wrong one, we might fallaciously say a taint label finding does
         not actually occur.
      *)
      Option.compare compare_precondition s1.precondition s2.precondition
  | other -> other

and compare_orig orig1 orig2 =
  match (orig1, orig2) with
  | Arg { pos = s, i; _ }, Arg { pos = s', j; _ } -> (
      match String.compare s s' with
      | 0 -> Int.compare i j
      | other -> other)
  | Src p, Src q -> compare_sources p q
  | Arg _, Src _ -> -1
  | Src _, Arg _ -> 1

and compare_taint taint1 taint2 =
  (* THINK: Right now we disregard the trace because we just want to keep one
   * potential path. *)
  compare_orig taint1.orig taint2.orig

let _show_taint_label taint =
  match taint.orig with
  | Arg { pos = s, i; _ } -> Printf.sprintf "arg(%s)#%d" s i
  | Src src -> src.label

let rec _show_source { call_trace; label; precondition } =
  (* We want to show the actual label, not the originating label.
     This may change, for instance, if we have ever propagated this taint to
     a different label.
  *)
  let precondition_prefix = _show_precondition precondition in
  precondition_prefix ^ _show_call_trace (fun _ -> label) call_trace

and _show_precondition precondition =
  match precondition with
  | None -> ""
  | Some (ts, _) -> Common.spf "[pre%d]" (List.length ts)

and _show_taint taint =
  let rec depth acc = function
    | PM _ -> acc
    | Call (_, _, x) -> depth (acc + 1) x
  in
  match taint.orig with
  | Src { call_trace; label; precondition } ->
      let pm, _ = pm_of_trace call_trace in
      let tok1, tok2 = pm.range_loc in
      let r = Range.range_of_token_locations tok1 tok2 in
      let precondition_prefix = _show_precondition precondition in
      Printf.sprintf "%s(%d,%d)#%s|%d|" precondition_prefix r.start r.end_ label
        (depth 0 call_trace)
  | Arg arg_lval -> _show_arg arg_lval

let _show_sink { rule_sink; _ } = rule_sink.Rule.sink_id

type taint_to_sink_item = { taint : taint; sink_trace : unit call_trace }
[@@deriving show]

let _show_taint_to_sink_item { taint; sink_trace } =
  Printf.sprintf "%s@{%s}" (_show_taint taint)
    (_show_call_trace [%show: unit] sink_trace)

let _show_taints_and_traces taints =
  Common2.string_of_list _show_taint_to_sink_item taints

type taints_to_sink = {
  (* These taints were incoming to the sink, under a certain
     REQUIRES expression.
     When we discharge the taint signature, we will produce
     a certain number of findings suitable to how the sink was
     reached.
  *)
  taints_with_precondition : taint_to_sink_item list * precondition;
  sink : sink;
  merged_env : Metavariable.bindings;
}
[@@deriving show]

type finding =
  | ToSink of taints_to_sink
  | ToReturn of taint list * G.tok
  | ArgToArg of arg * tainted_tokens * arg (* TODO: CleanArg ? *)
[@@deriving show]

type signature = finding list

let _show_taints_to_sink { taints_with_precondition = taints, _; sink; _ } =
  Common.spf "%s ~~~> %s" (_show_taints_and_traces taints) (_show_sink sink)

let _show_finding = function
  | ToSink x -> _show_taints_to_sink x
  | ToReturn (taints, _) ->
      Printf.sprintf "return (%s)" (Common2.string_of_list _show_taint taints)
  | ArgToArg (a1, _, a2) ->
      Printf.sprintf "%s ----> %s" (_show_arg a1) (_show_arg a2)

(*****************************************************************************)
(* Taint sets *)
(*****************************************************************************)

let pick_taint taint1 taint2 =
  (* Here we assume that 'compare taint1 taint2 = 0' so we could keep any
     * of them, but we want the one with the shortest trace. *)
  match (taint1.orig, taint1.orig) with
  | Arg _, Arg _ -> taint2
  | Src src1, Src src2 ->
      let call_trace_cmp =
        Int.compare
          (length_of_call_trace src1.call_trace)
          (length_of_call_trace src2.call_trace)
      in
      if call_trace_cmp < 0 then taint1
      else if call_trace_cmp > 0 then taint2
      else if
        (* same length *)
        List.length taint1.tokens < List.length taint2.tokens
      then taint1
      else taint2
  | Src _, Arg _
  | Arg _, Src _ ->
      logger#error "Taint_set.pick_taint: Ooops, the impossible happened!";
      taint2

module Taint_set = struct
  module Taint_map = Map.Make (struct
    type t = orig

    let compare k1 k2 =
      match (k1, k2) with
      | Arg _, Src _ -> -1
      | Src _, Arg _ -> 1
      | Arg a1, Arg a2 -> Stdlib.compare a1 a2
      | Src s1, Src s2 -> compare_sources s1 s2
  end)

  type t = taint Taint_map.t

  let empty = Taint_map.empty
  let is_empty set = Taint_map.is_empty set

  let equal set1 set2 =
    let eq t1 t2 = compare_taint t1 t2 = 0 in
    Taint_map.equal eq set1 set2

  let add taint set =
    (* We only want to keep one trace per taint source.
     *
     * This also helps avoiding infinite loops, which can happen when inferring
     * taint sigantures for functions like this:
     *
     *     f(tainted) {
     *         while (true) {
     *             x = g(tainted, f(tainted));
     *             if (true) return x;
     *         }
     *     }
     *
     * Intuitively `f` propagates taint from its input to its output, and with every
     * iteration we have a "new" taint source made by the tainted input passing N
     * times through `f`, and so the fixpoint computation diverges. This is actually
     * rather tricky and removing the `if (true)` or the `g` breaks the infinite loop,
     * but this has not been investigated in detail.
     *
     * THINK: We could do more clever things like checking whether a trace is an
     *   extension of another trace and such. This could also be dealt with in the
     *   taint-signatures themselves. But for now this solution is good.
     *
     * coupling: If this changes, make sure to update docs for the `Taint.signature` type.
     *)
    set
    |> Taint_map.update taint.orig (function
         | None -> Some taint
         | Some taint' -> Some (pick_taint taint taint'))

  let union set1 set2 =
    Taint_map.union
      (fun _k taint1 taint2 -> Some (pick_taint taint1 taint2))
      set1 set2

  let diff set1 set2 =
    set1 |> Taint_map.filter (fun k _ -> not (Taint_map.mem k set2))

  let singleton taint = add taint empty

  (* Because `Taint_set` is internally represented with a map, we cannot just
     map the codomain taint, using the internal provided `map` function. We
     want to map the keys too.
     Unfortunately, the keys and values are different types, so it's not as
     straightforward.
     Fortunately, we can exploit a property of the map, which is that the
     `orig` of the domain and codomain should be the same. So it should be fine
     to simply map the codomain taint, and then take its `orig` as the key.
  *)
  let map f set =
    let bindings = Taint_map.bindings set in
    bindings
    (* Here, we assume the invariant that the orig must be
       the same in the domain and codomain.
    *)
    |> Common.map (fun (_, t2) ->
           let new_taint = f t2 in
           (new_taint.orig, new_taint))
    |> List.to_seq |> Taint_map.of_seq

  let iter f set = Taint_map.iter (fun _k -> f) set
  let fold f set acc = Taint_map.fold (fun _k -> f) set acc

  let of_list taints =
    List.fold_left (fun set taint -> add taint set) Taint_map.empty taints

  let to_seq set = set |> Taint_map.to_seq |> Seq.map snd
  let elements set = set |> to_seq |> List.of_seq
end

type taints = Taint_set.t

let src_of_pm ~incoming (pm, (x : Rule.taint_source)) =
  let incoming = Taint_set.elements incoming in
  let precondition =
    match expr_to_precondition x.source_requires with
    | Bool true -> None
    | other -> Some (incoming, other)
  in
  Src { call_trace = PM (pm, x); label = x.label; precondition }

let taint_of_pm ~incoming pm = { orig = src_of_pm ~incoming pm; tokens = [] }

let taints_of_pms ~incoming pms =
  pms |> Common.map (taint_of_pm ~incoming) |> Taint_set.of_list

let show_taints taints =
  taints |> Taint_set.elements |> Common.map _show_taint |> String.concat ", "
  |> fun str -> "{ " ^ str ^ " }"
