(**
 * Copyright (c) 2013-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "flow" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
 *)

open Hoister
open Scope_builder

(* For every read of a variable x, we are interested in tracking writes to x
   that can reach that read. Ultimately the writes are going to be represented
   as a list of locations, where each location corresponds to a "single static
   assignment" of the variable in the code. But for the purposes of analysis, it
   is useful to represent these writes with a data type that contains either a
   single write, or a "join" of writes (in compiler terminology, a PHI node), or
   a reference to something that is unknown at a particular point in the AST
   during traversal, but will be known by the time traversal is complete. *)
module Val = struct
  type t =
    | Uninitialized
    | Loc of Loc.t
    | PHI of t list
    | REF of t option ref

  let mk_unresolved () =
    REF (ref None)

  let empty = PHI []

  let uninitialized = Uninitialized

  let merge t1 t2 =
    PHI [t1;t2]

  (* Resolving unresolved to t essentially models an equation of the form
     unresolved = t, where unresolved is a reference to an unknown and t is the
     known. Since the only non-trivial operation in t is joining, it is OK to
     erase any occurrences of unresolved in t: if t = unresolved | t' then
     unresolved = t is the same as unresolved = t'. *)
  let rec resolve ~unresolved t =
    match unresolved with
      | REF r when !r = None ->
        r := Some (erase r t)
      | _ -> failwith "Only an unresolved REF can be resolved"
  and erase r t = match t with
    | Uninitialized -> t
    | Loc _ -> t
    | PHI ts -> PHI (List.map (erase r) ts)
    | REF r' ->
      if r == r' then PHI []
      else begin
        r' := Option.map !r' (erase r);
        t
      end

  (* Simplification converts a Val.t to a list of locations. *)
  let rec simplify t = match t with
    | Uninitialized -> [Ssa_api.Uninitialized]
    | Loc loc -> [Ssa_api.Write loc]
    | PHI ts ->
      let locs' = List.fold_left (fun locs' t ->
        let locs = simplify t in
        List.rev_append locs locs'
      ) [] ts in
      List.sort_uniq Pervasives.compare locs'
    | REF { contents = Some t } -> simplify t
    | _ ->
      failwith "An unresolved REF cannot be simplified"

end

(* An environment is a map from variables to values. *)
module Env = struct
  type t = Val.t SMap.t
end

(* Abrupt completions induce control flows, so modeling them accurately is
   necessary for soundness. *)
module AbruptCompletion = struct
  type label = string
  type t =
    | Break of label option
    | Continue of label option
    | Return
    | Throw

  let label_opt = Option.map ~f:(fun (_loc, label) -> label)

  let break x = Break (label_opt x)
  let continue x = Continue (label_opt x)
  let return = Return
  let throw = Throw

  (* match particular abrupt completions *)
  let mem list: t -> bool =
    fun t -> List.mem t list
  (* match all abrupt completions *)
  let all: t -> bool =
    fun _t -> true

  (* Model an abrupt completion as an OCaml exception. *)
  exception Exn of t

  (* An abrupt completion carries an environment, which is the current
     environment at the point where the abrupt completion is "raised." This
     environment is merged wherever the abrupt completion is "handled." *)
  type env = t * Env.t

end

(* Collect all values assigned to a variable, as a conservative fallback when we
   don't have precise information. *)
module Havoc = struct
  type t = {
    unresolved: Val.t; (* always REF *)
    mutable locs: Loc.t list;
  }
end

class ssa_builder = object(this)
  inherit scope_builder as super

  (* We maintain a map of read locations to raw Val.t terms, which are
     simplified to lists of write locations once the analysis is done. *)
  val mutable values: Val.t LocMap.t = LocMap.empty
  method values: Ssa_api.values =
    LocMap.map Val.simplify values

  (* Utils to manipulate single-static-assignment (SSA) environments.

     TODO: These low-level operations should probably be replaced by
     higher-level "control-flow-graph" operations that can be implemented using
     them, e.g., those that deal with branches and loops. *)
  val mutable ssa_env: Val.t ref SMap.t = SMap.empty
  val mutable havoc_env: Havoc.t SMap.t = SMap.empty
  method ssa_env: Env.t =
    SMap.map (fun val_ref -> !val_ref) ssa_env
  method merge_ssa_env (env1: Env.t) (env2: Env.t): unit =
    SMap.iter (fun x val_ref ->
      val_ref := Val.merge (SMap.find x env1) (SMap.find x env2)
    ) ssa_env
  method reset_ssa_env (env0: Env.t): unit =
    SMap.iter (fun x val_ref ->
      val_ref := SMap.find x env0
    ) ssa_env
  method fresh_ssa_env: Env.t =
    SMap.map (fun _ -> Val.mk_unresolved ()) ssa_env
  method assert_ssa_env (env0: Env.t): unit =
    SMap.iter (fun x val_ref ->
      Val.resolve ~unresolved:(SMap.find x env0) !val_ref
    ) ssa_env
  method empty_ssa_env: Env.t =
    SMap.map (fun _ -> Val.empty) ssa_env
  method havoc_current_ssa_env: unit =
    SMap.iter (fun x val_ref ->
      (* NOTE: havoc_env should already have all writes to x, so the only
         additional thing that could come from ssa_env is "uninitialized." On
         the other hand, we *dont* want to include "uninitialized" if it's no
         longer in ssa_env, since that means that x has been initialized (and
         there's no going back). *)
      val_ref := Val.merge !val_ref (SMap.find x havoc_env).Havoc.unresolved
    ) ssa_env
  method havoc_uninitialized_ssa_env: unit =
    SMap.iter (fun x val_ref ->
      val_ref := Val.merge Val.uninitialized (SMap.find x havoc_env).Havoc.unresolved
    ) ssa_env

  method private mk_ssa_env =
    SMap.map (fun _ -> ref Val.uninitialized)

  method private mk_havoc_env =
    SMap.map (fun _ -> Havoc.{ unresolved = Val.mk_unresolved (); locs = [] })

  method private push_ssa_env bindings =
    let old_ssa_env = ssa_env in
    let old_havoc_env = havoc_env in
    let bindings = Bindings.to_map bindings in
    ssa_env <- SMap.fold SMap.add (this#mk_ssa_env bindings) old_ssa_env;
    havoc_env <- SMap.fold SMap.add (this#mk_havoc_env bindings) old_havoc_env;
    bindings, old_ssa_env, old_havoc_env

  method private resolve_havoc_env =
    SMap.iter (fun x _loc ->
      let { Havoc.unresolved; locs } = SMap.find x havoc_env in
      Val.(resolve ~unresolved (PHI (List.map (fun loc -> Loc loc) locs)))
    )

  method private pop_ssa_env (bindings, old_ssa_env, old_havoc_env) =
    this#resolve_havoc_env bindings;
    ssa_env <- old_ssa_env;
    havoc_env <- old_havoc_env

  method! with_bindings: 'a. ?lexical:bool -> Bindings.t -> ('a -> 'a) -> 'a -> 'a =
    fun ?lexical bindings visit node ->
      let saved_state = this#push_ssa_env bindings in
      this#run (fun () ->
        ignore @@ super#with_bindings ?lexical bindings visit node
      ) ~finally:(fun () ->
        this#pop_ssa_env saved_state
      );
      node

  (* Run some computation, catching any abrupt completions; do some final work,
     and then re-raise any abrupt completions that were caught. *)
  method run f ~finally =
    let completion_state = this#run_to_completion f in
    finally ();
    this#from_completion completion_state
  method run_to_completion f =
    try f (); None with
      | AbruptCompletion.Exn abrupt_completion -> Some abrupt_completion
      | e -> raise e (* unexpected shit *)
  method from_completion = function
    | None -> ()
    | Some abrupt_completion -> raise (AbruptCompletion.Exn abrupt_completion)

  (* When an abrupt completion is raised, it falls through any subsequent
     straight-line code, until it reaches a merge point in the control-flow
     graph. At that point, it can be re-raised if and only if all other reaching
     control-flow paths also raise the same abrupt completion.

     When re-raising is not possible, we have to save the abrupt completion and
     the current environment in a list, so that we can merge such environments
     later (when that abrupt completion and others like it are handled).

     Even when raising is possible, we still have to save the current
     environment, since the current environment will have to be cleared to model
     that the current values of all variables are unreachable.

     NOTE that raising is purely an optimization: we can have more precise
     results with raising, but even if we never raised we'd still be sound. *)

  val mutable abrupt_completion_envs: AbruptCompletion.env list = []
  method raise_abrupt_completion: 'a. (AbruptCompletion.t -> 'a) = fun abrupt_completion ->
    let env = this#ssa_env in
    this#reset_ssa_env this#empty_ssa_env;
    abrupt_completion_envs <- (abrupt_completion, env) :: abrupt_completion_envs;
    raise (AbruptCompletion.Exn abrupt_completion)

  method expecting_abrupt_completions f =
    let saved = abrupt_completion_envs in
    abrupt_completion_envs <- [];
    this#run f ~finally:(fun () ->
      abrupt_completion_envs <- List.rev_append saved abrupt_completion_envs
    )

  (* Given multiple completion states, (re)raise if all of them are the same
     abrupt completion. This function is called at merge points. *)
  method merge_completion_states (hd_completion_state, tl_completion_states) =
    match hd_completion_state with
      | None -> ()
      | Some abrupt_completion ->
        if List.for_all (function
          | None -> false
          | Some abrupt_completion' -> abrupt_completion = abrupt_completion'
        ) tl_completion_states
        then raise (AbruptCompletion.Exn abrupt_completion)

  (* Given a filter for particular abrupt completions to expect, find the saved
     environments corresponding to them, and merge those environments with the
     current environment. This function is called when exiting ASTs that
     introduce (and therefore expect) particular abrupt completions. *)
  method commit_abrupt_completion_matching =
    let merge_abrupt_completions_matching filter =
      let matching, non_matching = List.partition (fun (abrupt_completion, _env) ->
        filter abrupt_completion
      ) abrupt_completion_envs in
      List.iter (fun (_abrupt_completion, env) ->
        this#merge_ssa_env this#ssa_env env
      ) matching;
      abrupt_completion_envs <- non_matching
    in fun filter -> function
      | None -> merge_abrupt_completions_matching filter
      | Some abrupt_completion ->
        if filter abrupt_completion
        then merge_abrupt_completions_matching filter
        else raise (AbruptCompletion.Exn abrupt_completion)

  (* Track the list of labels that might describe a loop. Used to detect which
     labeled continues need to be handled by the loop.

     The idea is that a labeled statement adds its label to the list before
     entering its child, and if the child is not a loop or another labeled
     statement, the list will be cleared. A loop will consume the list, so we
     also clear the list on our way out of any labeled statement. *)
  val mutable possible_labeled_continues = []

  (* write *)
  method! pattern_identifier ?kind (ident: Loc.t Ast.Identifier.t) =
    ignore kind;
    let loc, x = ident in
    begin match SMap.get x ssa_env, SMap.get x havoc_env with
      | Some val_ref, Some havoc ->
        val_ref := Val.(Loc loc);
        Havoc.(havoc.locs <- loc :: havoc.locs)
      | _ -> ()
    end;
    super#identifier ident

  (* read *)
  method! identifier (ident: Loc.t Ast.Identifier.t) =
    let loc, x = ident in
    begin match SMap.get x ssa_env with
      | Some val_ref ->
        values <- LocMap.add loc !val_ref values
      | None -> ()
    end;
    super#identifier ident

  (* Order of evaluation matters *)
  method! assignment (expr: Loc.t Ast.Expression.Assignment.t) =
    let open Ast.Expression.Assignment in
    let { operator = _; left; right } = expr in
    ignore @@ this#expression right;
    ignore @@ this#assignment_pattern left;
    expr

  (* Order of evaluation matters *)
  method! variable_declarator ~kind (decl: Loc.t Ast.Statement.VariableDeclaration.Declarator.t) =
    let open Ast.Statement.VariableDeclaration.Declarator in
    let (_loc, { id; init }) = decl in
    ignore @@ Flow_ast_mapper.map_opt this#expression init;
    ignore @@ this#variable_declarator_pattern ~kind id;
    decl

  (* read and write (when the argument is an identifier) *)
  method! update_expression (expr: Loc.t Ast.Expression.Update.t) =
    let open Ast.Expression.Update in
    let { argument; operator = _; prefix = _ } = expr in
    ignore @@ this#expression argument;
    begin match argument with
      | _, Ast.Expression.Identifier x -> ignore @@ this#pattern_identifier x
      | _ -> ()
    end;
    expr

  (* things that cause abrupt completions *)
  method! break (stmt: Loc.t Ast.Statement.Break.t) =
    let open Ast.Statement.Break in
    let { label } = stmt in
    this#raise_abrupt_completion (AbruptCompletion.break label)

  method! continue (stmt: Loc.t Ast.Statement.Continue.t) =
    let open Ast.Statement.Continue in
    let { label } = stmt in
    this#raise_abrupt_completion (AbruptCompletion.continue label)

  method! return (stmt: Loc.t Ast.Statement.Return.t) =
    let open Ast.Statement.Return in
    let { argument } = stmt in
    ignore @@ Flow_ast_mapper.map_opt this#expression argument;
    this#raise_abrupt_completion AbruptCompletion.return

  method! throw (stmt: Loc.t Ast.Statement.Throw.t) =
    let open Ast.Statement.Throw in
    let { argument } = stmt in
    ignore @@ this#expression argument;
    this#raise_abrupt_completion AbruptCompletion.throw

  (** Control flow **)

  (** We describe the effect on the environment of evaluating node n using Hoare
      triples of the form [PRE] n [POST], where PRE is the environment before
      and POST is the environment after the evaluation of node n. Environments
      must be joined whenever a node is reachable from multiple nodes, as can
      happen after a branch or before a loop. **)

  (******************************************)
  (* [PRE] if (e) { s1 } else { s2 } [POST] *)
  (******************************************)
  (*    |                                   *)
  (*    e                                   *)
  (*   / \                                  *)
  (* s1   s2                                *)
  (*   \./                                  *)
  (*    |                                   *)
  (******************************************)
  (* [PRE] e [ENV0]                         *)
  (* [ENV0] s1 [ENV1]                       *)
  (* [ENV0] s2 [ENV2]                       *)
  (* POST = ENV1 | ENV2                     *)
  (******************************************)
  method! if_statement (stmt: Loc.t Ast.Statement.If.t) =
    let open Ast.Statement.If in
    let { test; consequent; alternate } = stmt in
    ignore @@ this#expression test;
    let env0 = this#ssa_env in
    (* collect completions and environments of every branch *)
    let then_completion_state = this#run_to_completion (fun () ->
      ignore @@ this#if_consequent_statement ~has_else:(alternate <> None) consequent
    ) in
    let env1 = this#ssa_env in
    this#reset_ssa_env env0;
    let else_completion_state = this#run_to_completion (fun () ->
      ignore @@ Flow_ast_mapper.map_opt this#statement alternate
    ) in
    let env2 = this#ssa_env in
    (* merge environments *)
    this#merge_ssa_env env1 env2;
    (* merge completions *)
    let if_completion_states = then_completion_state, [else_completion_state] in
    this#merge_completion_states if_completion_states;
    stmt

  (********************************)
  (* [PRE] while (e) { s } [POST] *)
  (********************************)
  (*    |                         *)
  (*    e <-.                     *)
  (*   / \ /                      *)
  (*  |   s                       *)
  (*   \                          *)
  (*    |                         *)
  (********************************)
  (* PRE = ENV0                   *)
  (* [ENV0 | ENV1] e [ENV2]       *)
  (* [ENV2] s [ENV1]              *)
  (* POST = ENV2                  *)
  (********************************)
  method! while_ (stmt: Loc.t Ast.Statement.While.t) =
    this#expecting_abrupt_completions (fun () ->
      let continues = (AbruptCompletion.continue None)::possible_labeled_continues in
      let open Ast.Statement.While in
      let { test; body } = stmt in
      let env0 = this#ssa_env in
      (* placeholder for environment at the end of the loop body *)
      let env1 = this#fresh_ssa_env in
      this#merge_ssa_env env0 env1;
      ignore @@ this#expression test;
      let env2 = this#ssa_env in
      let loop_completion_state = this#run_to_completion (fun () ->
        ignore @@ this#statement body
      ) in
      (* continue exits *)
      let loop_completion_state = this#run_to_completion (fun () ->
        this#commit_abrupt_completion_matching (AbruptCompletion.mem continues) loop_completion_state
      ) in
      (* end of loop body *)
      this#assert_ssa_env env1;
      (* out of the loop! this always happens right after evaluating the loop test *)
      this#reset_ssa_env env2;
      (* we might also never enter the loop body *)
      let while_completion_states = None, [loop_completion_state] in
      let completion_state = this#run_to_completion (fun () ->
        this#merge_completion_states while_completion_states
      ) in (* completion_state = None *)
      (* break exits *)
      this#commit_abrupt_completion_matching AbruptCompletion.(mem [break None]) completion_state
    );
    stmt

  (***********************************)
  (* [PRE] do { s } while (e) [POST] *)
  (***********************************)
  (*    |                            *)
  (*    s <-.                        *)
  (*     \ /                         *)
  (*      e                          *)
  (*      |                          *)
  (***********************************)
  (* PRE = ENV0                      *)
  (* [ENV0 | ENV1] s; e [ENV1]       *)
  (* POST = ENV1                     *)
  (***********************************)
  method! do_while (stmt: Loc.t Ast.Statement.DoWhile.t) =
    this#expecting_abrupt_completions (fun () ->
      let continues = (AbruptCompletion.continue None)::possible_labeled_continues in
      let open Ast.Statement.DoWhile in
      let { body; test } = stmt in
      let env0 = this#ssa_env in
      let env1 = this#fresh_ssa_env in
      this#merge_ssa_env env0 env1;
      let loop_completion_state = this#run_to_completion (fun () ->
        ignore @@ this#statement body
      ) in
      let loop_completion_state = this#run_to_completion (fun () ->
        this#commit_abrupt_completion_matching (AbruptCompletion.mem continues) loop_completion_state
      ) in
      begin match loop_completion_state with
        | None -> ignore @@ this#expression test
        | _ -> ()
      end;
      this#assert_ssa_env env1;
      let do_while_completion_states = loop_completion_state, [] in
      let completion_state = this#run_to_completion (fun () ->
        this#merge_completion_states do_while_completion_states
      ) in  (* completion_state = loop_completion_state *)
      this#commit_abrupt_completion_matching AbruptCompletion.(mem [break None]) completion_state
    );
    stmt

  (**************************************)
  (* [PRE] for (e; e1; e2) { s } [POST] *)
  (**************************************)
  (*    |                               *)
  (*    e                               *)
  (*    |                               *)
  (*   e1 <---.                         *)
  (*   / \    |                         *)
  (*  |   s   |                         *)
  (*  |    \ /                          *)
  (*  |    e2                           *)
  (*   \                                *)
  (*    |                               *)
  (**************************************)
  (* [PRE] e [ENV0]                     *)
  (* [ENV0 | ENV1] e1 [ENV2]            *)
  (* [ENV2] s; e2 [ENV1]                *)
  (* POST = ENV2                        *)
  (**************************************)
  method! scoped_for_statement (stmt: Loc.t Ast.Statement.For.t) =
    this#expecting_abrupt_completions (fun () ->
      let continues = (AbruptCompletion.continue None)::possible_labeled_continues in
      let open Ast.Statement.For in
      let { init; test; update; body } = stmt in
      ignore @@ Flow_ast_mapper.map_opt this#for_statement_init init;
      let env0 = this#ssa_env in
      let env1 = this#fresh_ssa_env in
      this#merge_ssa_env env0 env1;
      ignore @@ Flow_ast_mapper.map_opt this#expression test;
      let env2 = this#ssa_env in
      let loop_completion_state = this#run_to_completion (fun () ->
        ignore @@ this#statement body;
      ) in
      (* continue *)
      let loop_completion_state = this#run_to_completion (fun () ->
        this#commit_abrupt_completion_matching (AbruptCompletion.mem continues) loop_completion_state
      ) in
      begin match loop_completion_state with
        | None -> ignore @@ Flow_ast_mapper.map_opt this#expression update
        | _ -> ()
      end;
      this#assert_ssa_env env1;
      this#reset_ssa_env env2;
      let for_completion_states = None, [loop_completion_state] in
      let completion_state = this#run_to_completion (fun () ->
        this#merge_completion_states for_completion_states
      ) in
      this#commit_abrupt_completion_matching AbruptCompletion.(mem [break None]) completion_state
    );
    stmt

  (*************************************)
  (* [PRE] for (e1 in e2) { s } [POST] *)
  (*************************************)
  (*    |                              *)
  (*    e2                             *)
  (*    |                              *)
  (*    . <---.                        *)
  (*   / \    |                        *)
  (*  |   e1  |                        *)
  (*  |    \ /                         *)
  (*  |     s                          *)
  (*   \                               *)
  (*    |                              *)
  (*************************************)
  (* [PRE] e2 [ENV0]                   *)
  (* ENV2 = ENV0 | ENV1                *)
  (* [ENV2] e2 [ENV0]                  *)
  (* [ENV0 | ENV1] e1; s [ENV1]        *)
  (* POST = ENV2                       *)
  (*************************************)
  method! scoped_for_in_statement (stmt: Loc.t Ast.Statement.ForIn.t) =
    this#expecting_abrupt_completions (fun () ->
      let continues = (AbruptCompletion.continue None)::possible_labeled_continues in
      let open Ast.Statement.ForIn in
      let { left; right; body; each = _ } = stmt in
      ignore @@ this#expression right;
      let env0 = this#ssa_env in
      let env1 = this#fresh_ssa_env in
      this#merge_ssa_env env0 env1;
      let env2 = this#ssa_env in
      ignore @@ this#for_in_statement_lhs left;
      let loop_completion_state = this#run_to_completion (fun () ->
        ignore @@ this#statement body;
      ) in
      (* continue *)
      let loop_completion_state = this#run_to_completion (fun () ->
        this#commit_abrupt_completion_matching (AbruptCompletion.mem continues) loop_completion_state
      ) in
      this#assert_ssa_env env1;
      this#reset_ssa_env env2;
      let for_in_completion_states = None, [loop_completion_state] in
      let completion_state = this#run_to_completion (fun () ->
        this#merge_completion_states for_in_completion_states
      ) in
      this#commit_abrupt_completion_matching AbruptCompletion.(mem [break None]) completion_state
    );
    stmt

  (*************************************)
  (* [PRE] for (e1 of e2) { s } [POST] *)
  (*************************************)
  (*    |                              *)
  (*    e2                             *)
  (*    |                              *)
  (*    . <---.                        *)
  (*   / \    |                        *)
  (*  |   e1  |                        *)
  (*  |    \ /                         *)
  (*  |     s                          *)
  (*   \                               *)
  (*    |                              *)
  (*************************************)
  (* [PRE] e2 [ENV0]                   *)
  (* ENV2 = ENV0 | ENV1                *)
  (* [ENV2] e2 [ENV0]                  *)
  (* [ENV0 | ENV1] e1; s [ENV1]        *)
  (* POST = ENV2                       *)
  (*************************************)
  method! scoped_for_of_statement (stmt: Loc.t Ast.Statement.ForOf.t) =
    this#expecting_abrupt_completions (fun () ->
      let continues = (AbruptCompletion.continue None)::possible_labeled_continues in
      let open Ast.Statement.ForOf in
      let { left; right; body; async = _ } = stmt in
      ignore @@ this#expression right;
      let env0 = this#ssa_env in
      let env1 = this#fresh_ssa_env in
      this#merge_ssa_env env0 env1;
      let env2 = this#ssa_env in
      ignore @@ this#for_of_statement_lhs left;
      let loop_completion_state = this#run_to_completion (fun () ->
        ignore @@ this#statement body;
      ) in
      (* continue *)
      let loop_completion_state = this#run_to_completion (fun () ->
        this#commit_abrupt_completion_matching (AbruptCompletion.mem continues) loop_completion_state
      ) in
      this#assert_ssa_env env1;
      this#reset_ssa_env env2;
      let for_of_completion_states = None, [loop_completion_state] in
      let completion_state = this#run_to_completion (fun () ->
        this#merge_completion_states for_of_completion_states
      ) in
      this#commit_abrupt_completion_matching AbruptCompletion.(mem [break None]) completion_state
    );
    stmt

  (***********************************************************)
  (* [PRE] switch (e) { case e1: s1 ... case eN: sN } [POST] *)
  (***********************************************************)
  (*     |                                                   *)
  (*     e                                                   *)
  (*    /                                                    *)
  (*   e1                                                    *)
  (*   | \                                                   *)
  (*   .  s1                                                 *)
  (*   |   |                                                 *)
  (*   ei  .                                                 *)
  (*   | \ |                                                 *)
  (*   .  si                                                 *)
  (*   |   |                                                 *)
  (*   eN  .                                                 *)
  (*   | \ |                                                 *)
  (*   |  sN                                                 *)
  (*    \  |                                                 *)
  (*      \|                                                 *)
  (*       |                                                 *)
  (***********************************************************)
  (* [PRE] e [ENV0]                                          *)
  (* ENV0' = empty                                           *)
  (* \forall i = 0..N-1:                                     *)
  (*   [ENVi] ei+1 [ENVi+1]                                  *)
  (*   [ENVi+1 | ENVi'] si+1 [ENVi+1']                       *)
  (* POST = ENVN | ENVN'                                     *)
  (***********************************************************)
  method! switch (switch: Loc.t Ast.Statement.Switch.t) =
    this#expecting_abrupt_completions (fun () ->
      let open Ast.Statement.Switch in
      let { discriminant; cases } = switch in
      ignore @@ this#expression discriminant;
      let env0 = this#ssa_env in
      let env1, env2, case_completion_states = List.fold_left (fun acc stuff ->
        let _loc, case = stuff in
        this#ssa_switch_case acc case
      ) (env0, this#empty_ssa_env, []) cases in
      this#merge_ssa_env env1 env2;
      (* In general, cases are non-exhaustive. TODO: optimize with `default`. *)
      let switch_completion_states = None, case_completion_states in
      let completion_state = this#run_to_completion (fun () ->
        this#merge_completion_states switch_completion_states
      ) in
      this#commit_abrupt_completion_matching AbruptCompletion.(mem [break None]) completion_state
    );
    switch

  method private ssa_switch_case (env1, env2, case_completion_states) (case: Loc.t Ast.Statement.Switch.Case.t') =
    let open Ast.Statement.Switch.Case in
    let { test; consequent } = case in
    this#reset_ssa_env env1;
    ignore @@ Flow_ast_mapper.map_opt this#expression test;
    let env1' = this#ssa_env in
    this#merge_ssa_env env1' env2;
    let case_completion_state = this#run_to_completion (fun () ->
      ignore @@ this#statement_list consequent
    ) in
    let env2' = this#ssa_env in
    (env1', env2', case_completion_state :: case_completion_states)

  (****************************************)
  (* [PRE] try { s1 } catch { s2 } [POST] *)
  (****************************************)
  (*    |                                 *)
  (*    s1 ..~                            *)
  (*    |    |                            *)
  (*    |   s2                            *)
  (*     \./                              *)
  (*      |                               *)
  (****************************************)
  (* [PRE] s1 [ENV1]                      *)
  (* [HAVOC] s2 [ENV2 ]                   *)
  (* POST = ENV1 | ENV2                   *)
  (****************************************)
  (*******************************************************)
  (* [PRE] try { s1 } catch { s2 } finally { s3 } [POST] *)
  (*******************************************************)
  (*    |                                                *)
  (*    s1 ..~                                           *)
  (*    |    |                                           *)
  (*    |   s2 ..~                                       *)
  (*     \./     |                                       *)
  (*      |______|                                       *)
  (*             |                                       *)
  (*            s3                                       *)
  (*             |                                       *)
  (*******************************************************)
  (* [PRE] s1 [ENV1]                                     *)
  (* [HAVOC] s2 [ENV2 ]                                  *)
  (* [HAVOC] s3 [ENV3 ]                                  *)
  (* POST = ENV3                                         *)
  (*******************************************************)
  method! try_catch (stmt: Loc.t Ast.Statement.Try.t) =
    this#expecting_abrupt_completions (fun () ->
      let open Ast.Statement.Try in
      let { block = (_loc, block); handler; finalizer } = stmt in
      let try_completion_state = this#run_to_completion (fun () ->
        ignore @@ this#block block
      ) in
      let env1 = this#ssa_env in
      let catch_completion_state, env2 = match handler with
        | Some (_loc, clause) ->
          (* NOTE: Havoc-ing the state when entering the handler is probably
             overkill. We can be more precise but still correct by collecting all
             possible writes in the try-block and merging them with the state when
             entering the try-block. *)
          this#havoc_current_ssa_env;
          let catch_completion_state = this#run_to_completion (fun () ->
            ignore @@ this#catch_clause clause
          ) in
          catch_completion_state, this#ssa_env
        | None -> None, this#empty_ssa_env
      in
      this#merge_ssa_env env1 env2;
      let try_catch_completion_states = try_completion_state, [catch_completion_state] in
      let completion_state = this#run_to_completion (fun () ->
        this#merge_completion_states try_catch_completion_states
      ) in
      this#commit_abrupt_completion_matching AbruptCompletion.all completion_state;
      begin match finalizer with
        | Some (_loc, block) ->
          (* NOTE: Havoc-ing the state when entering the finalizer is probably
             overkill. We can be more precise but still correct by collecting
             all possible writes in the handler and merging them with the state
             when entering the handler (which in turn should already account for
             any contributions by the try-block). *)
          this#havoc_current_ssa_env;
          ignore @@ this#block block
        | None -> ()
      end;
      this#from_completion completion_state
    );
    stmt

  (* We also havoc state when entering functions and exiting calls. *)
  method! lambda params body =
    this#expecting_abrupt_completions (fun () ->
      let env = this#ssa_env in
      this#run (fun () ->
        this#havoc_uninitialized_ssa_env;
        let completion_state = this#run_to_completion (fun () ->
          super#lambda params body
        ) in
        this#commit_abrupt_completion_matching AbruptCompletion.(mem [return; throw]) completion_state
      ) ~finally:(fun () ->
        this#reset_ssa_env env
      )
    )

  method! call (expr: Loc.t Ast.Expression.Call.t) =
    let open Ast.Expression.Call in
    let { callee; arguments } = expr in
    ignore @@ this#expression callee;
    ignore @@ Flow_ast_mapper.map_list this#expression_or_spread arguments;
    this#havoc_current_ssa_env;
    expr

  (* Labeled statements handle labeled breaks, but also push labeled continues
     that are expected to be handled by immediately nested loops. *)
  method! labeled_statement (stmt: Loc.t Ast.Statement.Labeled.t) =
    this#expecting_abrupt_completions (fun () ->
      let open Ast.Statement.Labeled in
      let { label; body } = stmt in
      possible_labeled_continues <- (AbruptCompletion.continue (Some label)) :: possible_labeled_continues;
      let completion_state = this#run_to_completion (fun () ->
        ignore @@ this#statement body;
      ) in
      possible_labeled_continues <- [];
      this#commit_abrupt_completion_matching AbruptCompletion.(mem [break (Some label)]) completion_state
    );
    stmt

  method! statement (stmt: Loc.t Ast.Statement.t) =
    let open Ast.Statement in
    begin match stmt with
      | _, While _
      | _, DoWhile _
      | _, For _
      | _, ForIn _
      | _, ForOf _
      | _, Labeled _ -> ()
      | _ -> possible_labeled_continues <- []
    end;
    super#statement stmt

end

let program program =
  let ssa_walk = new ssa_builder in
  ignore @@ ssa_walk#program program;
  ssa_walk#values
