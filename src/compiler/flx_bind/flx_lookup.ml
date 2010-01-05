open Flx_util
open Flx_list
open Flx_ast
open Flx_types
open Flx_print
open Flx_exceptions
open Flx_set
open Flx_mtypes2
open Flx_typing
open Flx_typing2
open Flx_unify
open Flx_beta
open Flx_generic
open Flx_overload
open Flx_tpat

let hfind msg h k =
  try Flx_sym_table.find h k
  with Not_found ->
    print_endline ("flx_lookup Flx_sym_table.find failed " ^ msg);
    raise Not_found


type lookup_state_t = {
  syms: Flx_mtypes2.sym_state_t;
  sym_table: Flx_sym_table.t;
  env_cache: (Flx_types.bid_t, Flx_types.env_t) Hashtbl.t;
}

(** Create the state needed for lookup. *)
let make_lookup_state syms sym_table =
  {
    syms = syms;
    sym_table = sym_table;
    env_cache = Hashtbl.create 97;
  }


  (*
(*
  THIS IS A DUMMY BOUND SYMBOL TABLE
  REQUIRED FOR THE PRINTING OF BOUND EXPRESSIONS
*)
let bsym_table = Flx_bsym_table.create ()
*)

let dummy_sr = Flx_srcref.make_dummy "[flx_lookup] generated"

let unit_t = BTYP_tuple []

(* use fresh variables, but preserve names *)
let mkentry state (vs:ivs_list_t) i =
  let is = List.map
    (fun _ -> fresh_bid state.syms.Flx_mtypes2.counter)
    (fst vs)
  in
  let ts = List.map (fun i ->
    (*
    print_endline ("[mkentry] Fudging type variable type " ^ si i);
    *)
    BTYP_var (i, BTYP_type 0)) is
  in
  let vs = List.map2 (fun i (n,_,_) -> n,i) is (fst vs) in
  {base_sym=i; spec_vs=vs; sub_ts=ts}


exception Found of int
exception Tfound of btypecode_t

type kind_t = Parameter | Other

let get_data table index =
  try Flx_sym_table.find table index
  with Not_found ->
    failwith ("[Flx_lookup.get_data] No definition of <" ^
      string_of_bid index ^ ">")

let lookup_name_in_htab htab name : entry_set_t option =
  (* print_endline ("Lookup name in htab: " ^ name); *)
  try Some (Hashtbl.find htab name)
  with Not_found -> None

let merge_functions
  (opens:entry_set_t list)
  name
: entry_kind_t list =
  List.fold_left
    (fun init x -> match x with
    | FunctionEntry ls ->
      List.fold_left
      (fun init x ->
        if List.mem x init then init else x :: init
      )
      init ls
    | NonFunctionEntry x ->
      failwith
      ("[merge_functions] Expected " ^
        name ^ " to be function overload set in all open modules, got non-function:\n" ^
        string_of_entry_kind x
      )
    )
  []
  opens

let lookup_name_in_table_dirs table dirs sr name : entry_set_t option =
  (*
  print_endline ("Lookup name " ^ name ^ " in table dirs");
  flush stdout;
  *)
  match lookup_name_in_htab table name with
  | Some x as y ->
      (*
      print_endline ("Lookup_name_in_htab found " ^ name);
      *)
      y
  | None ->
      let opens = List.concat (
        List.map begin fun table ->
          match lookup_name_in_htab table name with
          | Some x -> [x]
          | None -> []
        end dirs)
      in
      match opens with
      | [x] -> Some x
      | FunctionEntry ls :: rest ->
          (*
          print_endline "HERE 3";
          *)
          Some (FunctionEntry (merge_functions opens name))
    
      | (NonFunctionEntry (i)) as some ::_ ->
          if
            List.fold_left begin fun t -> function
              | NonFunctionEntry (j) when i = j -> t
              | _ -> false
            end true opens
          then
            Some some
          else begin
            List.iter begin fun es ->
              print_endline ("Symbol " ^ (string_of_entry_set es))
            end opens;
            clierr sr ("[lookup_name_in_table_dirs] Conflicting nonfunction definitions for "^
              name ^" found in open modules"
            )
          end
      | [] -> None


let rsground= {
  constraint_overload_trail = [];
  idx_fixlist = [];
  type_alias_fixlist = [];
  as_fixlist = [];
  expr_fixlist = [];
  depth = 0;
  open_excludes = []
}

(* this ugly thing merges a list of function entries
some of which might be inherits, into a list of
actual functions
*)

module EntrySet = Set.Make(
  struct
    type t = entry_kind_t
    let compare = compare
  end
)

let rec trclose state bsym_table rs sr fs =
  let inset = ref EntrySet.empty in
  let outset = ref EntrySet.empty in
  let exclude = ref EntrySet.empty in
  let append fs = List.iter (fun i -> inset := EntrySet.add i !inset) fs in

  let rec trclosem () =
    if EntrySet.is_empty !inset then ()
    else
      (* grab an element *)
      let x = EntrySet.choose !inset in
      inset := EntrySet.remove x !inset;

      (* loop if already handled *)
      if EntrySet.mem x !exclude then trclosem ()
      else begin
        (* say we're handling this one *)
        exclude := EntrySet.add x !exclude;

        match hfind "lookup" state.sym_table (sye x) with
        | { Flx_sym.parent=parent; sr=sr2; symdef=SYMDEF_inherit_fun qn } ->
          let env = build_env state bsym_table parent in
          begin match fst (lookup_qn_in_env2' state bsym_table env rs qn) with
          | NonFunctionEntry _ -> clierr2 sr sr2 "Inherit fun doesn't denote function set"
          | FunctionEntry fs' -> append fs'; trclosem ()
          end

        | _ -> outset := EntrySet.add x !outset; trclosem ()
      end
  in
  append fs;
  trclosem ();
  let output = ref [] in
  EntrySet.iter (fun i -> output := i :: !output) !outset;
  !output

and resolve_inherits state bsym_table rs sr x =
  match x with
  | NonFunctionEntry z ->
    begin match hfind "lookup" state.sym_table (sye z) with
    | { Flx_sym.parent=parent; symdef=SYMDEF_inherit qn } ->
      (*
      print_endline ("Found an inherit symbol qn=" ^ string_of_qualified_name qn);
      *)
      let env = inner_build_env state bsym_table rs parent in
      (*
      print_endline "Environment built for lookup ..";
      *)
      fst (lookup_qn_in_env2' state bsym_table env rs qn)
    | { Flx_sym.sr=sr2; symdef=SYMDEF_inherit_fun qn } ->
      clierr2 sr sr2
      "NonFunction inherit denotes function"
    | _ -> x
    end
  | FunctionEntry fs -> FunctionEntry (trclose state bsym_table rs sr fs)

and inner_lookup_name_in_env state bsym_table env rs sr name : entry_set_t =
  (*
  print_endline ("[lookup_name_in_env] " ^ name);
  *)
  let rec aux env =
    match env with
    | [] -> None
    | (_,_,table,dirs,_) :: tail ->
        match lookup_name_in_table_dirs table dirs sr name with
        | Some _ as x -> x
        | None -> aux tail
  in
    match aux env with
    | Some x ->
      (*
      print_endline "[lookup_name_in_env] Got result, resolve inherits";
      *)
      resolve_inherits state bsym_table rs sr x
    | None ->
      clierr sr
      (
        "[lookup_name_in_env]: Name '" ^
        name ^
        "' not found in environment (depth "^
        string_of_int (List.length env)^ ")"
      )

(* This routine looks up a qualified name in the
   environment and returns an entry_set_t:
   can be either non-function or function set
*)
and lookup_qn_in_env2'
  state
  (bsym_table:Flx_bsym_table.t)
  (env:env_t)
  (rs:recstop)
  (qn: qualified_name_t)
  : entry_set_t * typecode_t list
=
  (*
  print_endline ("[lookup_qn_in_env2] qn=" ^ string_of_qualified_name qn);
  *)
  match qn with
  | `AST_callback (sr,qn) -> clierr sr "[lookup_qn_in_env2] qualified name is callback [not implemented yet]"
  | `AST_void sr -> clierr sr "[lookup_qn_in_env2] qualified name is void"
  | `AST_case_tag (sr,_) -> clierr sr "[lookup_qn_in_env2] Can't lookup a case tag"
  | `AST_typed_case (sr,_,_) -> clierr sr "[lookup_qn_in_env2] Can't lookup a typed case tag"
  | `AST_index (sr,name,_) ->
    print_endline ("[lookup_qn_in_env2] synthetic name " ^ name);
    clierr sr "[lookup_qn_in_env2] Can't lookup a synthetic name"

  | `AST_name (sr,name,ts) ->
    (*
    print_endline ("Found simple name " ^ name);
    *)
    inner_lookup_name_in_env state bsym_table env rs sr name, ts

  | `AST_the (sr,qn) ->
    print_endline ("[lookup_qn_in_env2'] AST_the " ^ string_of_qualified_name qn);
    let es,ts = lookup_qn_in_env2' state bsym_table env rs qn in
    begin match es with
    | NonFunctionEntry  _
    | FunctionEntry [_] -> es,ts
    | _ -> clierr sr
      "'the' expression denotes non-singleton function set"
    end

  | `AST_lookup (sr,(me,name,ts)) ->
    (*
    print_endline ("Searching for name " ^ name);
    *)
    match eval_module_expr state bsym_table env me with
    | Simple_module (impl,ts', htab,dirs) ->
      let env' = mk_bare_env state bsym_table impl in
      let tables = get_pub_tables state bsym_table env' rs dirs in
      let result = lookup_name_in_table_dirs htab tables sr name in
      match result with
      | Some entry ->
        resolve_inherits state bsym_table rs sr entry,
        ts' @ ts
      | None ->
        clierr sr
        (
          "[lookup_qn_in_env2] Can't find " ^ name
        )

      (*
      begin
      try
        let entry = Hashtbl.find htab name in
        resolve_inherits state bsym_table rs sr entry,
        ts' @ ts
      with Not_found ->
        clierr sr
        (
          "[lookup_qn_in_env2] Can't find " ^ name
        )
      end
      *)
and lookup_qn_in_env'
  (state:lookup_state_t)
  bsym_table
  (env:env_t) rs
  (qn: qualified_name_t)
  : entry_kind_t * typecode_t list
=
  match lookup_qn_in_env2' state bsym_table env rs qn with
    | NonFunctionEntry x,ts -> x,ts
    (* experimental, allow singleton function *)
    | FunctionEntry [x],ts -> x,ts

    | FunctionEntry _,_ ->
      let sr = src_of_qualified_name qn in
      clierr sr
      (
        "[lookup_qn_in_env'] Not expecting " ^
        string_of_qualified_name qn ^
        " to be function set"
      )

(* This routine binds a type expression to a bound type expression.
   Note in particular that a type alias is replaced by what
   it as an alias for, recursively so that the result
   globally unique

   if params is present it is a list mapping strings to types
   possibly bound type variable

   THIS IS WEIRD .. expr_fixlist is propagated, but 'depth'
   isn't. But the depth is essential to insert the correct
   fixpoint term .. ????

   i think this arises from:

   val x = e1 + y;
   val y = e2 + x;

   here, the implied typeof() operator is used
   twice: the first bind expression invoking a second
   bind expression which would invoke the first again ..
   here we have to propagate the bind_expression
   back to the original call on the first term,
   but we don't want to accumulate depths? Hmmm...
   I should test that ..

*)
and inner_bind_type state (bsym_table:Flx_bsym_table.t) env sr rs t : btypecode_t =
  (*
  print_endline ("[bind_type] " ^ string_of_typecode t);
  *)
  let mkenv i = build_env state bsym_table (Some i) in
  let bt:btypecode_t =
    try
      bind_type' state bsym_table env rs sr t [] mkenv

    with
      | Free_fixpoint b ->
        clierr sr
        ("Unresolvable recursive type " ^ sbt bsym_table b)
      | Not_found ->
        failwith "Bind type' failed with Not_found"
  in
  (*
  print_endline ("Bound type= " ^ sbt bsym_table bt);
  *)
  let bt =
    try beta_reduce state.syms bsym_table sr bt
    with Not_found -> failwith ("Beta reduce failed with Not_found " ^ sbt bsym_table bt)
  in
    (*
    print_endline ("Beta reduced type= " ^ sbt bsym_table bt);
    *)
    bt

and inner_bind_expression state bsym_table env rs e  =
  let sr = src_of_expr e in
  let e',t' =
    try
     let x = bind_expression' state bsym_table env rs e [] in
     (*
     print_endline ("Bound expression " ^
       string_of_bound_expression_with_type state.sym_table x
     );
     *)
     x
    with
     | Free_fixpoint b ->
       clierr sr
       ("Circular dependency typing expression " ^ string_of_expr e)
     | SystemError (sr,msg) as x ->
       print_endline ("System Error binding expression " ^ string_of_expr e);
       raise x

     | ClientError (sr,msg) as x ->
       print_endline ("Client Error binding expression " ^ string_of_expr e);
       raise x

     | Failure msg as x ->
       print_endline ("Failure binding expression " ^ string_of_expr e);
       raise x

  in
    let t' = beta_reduce state.syms bsym_table sr t' in
    e',t'

and expand_typeset t =
  match t with
  | BTYP_type_tuple ls
  | BTYP_typeset ls
  | BTYP_typesetunion ls -> List.fold_left (fun ls t -> expand_typeset t @ ls) [] ls
  | x -> [x]

and handle_typeset state sr elt tset =
  let ls = expand_typeset tset in
  (* x isin { a,b,c } is the same as
    typematch x with
    | a => 1
    | b => 1
    | c => 1
    | _ => 0
    endmatch

    ** THIS CODE ONLY WORKS FOR BASIC TYPES **

    This is because we don't know what to do with any
    type variables in the terms of the set. The problem
    is that 'bind type' just replaces them with bound
    variables. We have to assume they're not pattern
    variables at the moment, therefore they're variables
    from the environment.

    We should really allow for patterns, however bound
    patterns aren't just types, but types with binders
    indicating 'as' assignments and pattern variables.

    Crudely -- typesets are a hack that we should get
    rid of in the future, since a typematch is just
    more general .. however we have no way to generalise
    type match cases so they can be named at the moment.

    This is why we have typesets.. so I need to fix them,
    so the list of things in a typeset is actually
    a sequence of type patterns, not types.

  *)
  let e = BidSet.empty in
  let un = BTYP_tuple [] in
  let lss = List.rev_map (fun t -> {pattern=t; pattern_vars=e; assignments=[]},un) ls in
  let fresh = fresh_bid state.syms.counter in
  let dflt =
    {
      pattern=BTYP_var (fresh,BTYP_type 0);
      pattern_vars = BidSet.singleton fresh;
      assignments=[]
    },
    BTYP_void
  in
  let lss = List.rev (dflt :: lss) in
  BTYP_type_match (elt, lss)




(* =========================================== *)
(* INTERNAL BINDING ROUTINES *)
(* =========================================== *)

(* RECURSION DETECTORS

There are FOUR type recursion detectors:

idx_fixlist is a list of indexes, used by
bind_index to detect a recursion determining
the type of a function or variable:
the depth is calculated from the list length:
this arises from bind_expression, which uses
bind type : bind_expression is called to deduce
a function return type from returned expressions

TEST CASE:
  val x = (x,x) // type is ('a * 'a) as 'a

RECURSION CYCLE:
  type_of_index' -> bind_type'

type_alias_fixlist is a list of indexes, used by
bind_type_index to detect a recursive type alias,
[list contains depth]

TEST CASE:
  typedef a = a * a // type is ('a * 'a) as 'a


RECURSION CYCLE:
  bind_type' -> type_of_type_index

as_fixlist is a list of (name,depth) pairs, used by
bind_type' to detect explicit fixpoint variables
from the TYP_as terms (x as fv)
[list contains depth]

TEST CASE:
  typedef a = b * b as b // type is ('a * 'a) as 'a

RECURSION CYCLE:
  type_of_index' -> bind_type'

expr_fixlist is a list of (expression,depth)
used by bind_type' to detect recursion from
typeof(e) type terms
[list contains depth]

TEST CASE:
  val x: typeof(x) = (x,x) // type is ('a * 'a) as 'a

RECURSION CYCLE:
  bind_type' -> bind_expression'

TRAP NOTES:
  idx_fixlist and expr_fixlist are related :(

  The expr_fixlist handles an explicit typeof(expr)
  term, for an arbitrary expr term.

  idx_fixlist is initiated by type_of_index, and only
  occurs typing a variable or function from its
  declaration when the declaration is omitted
  OR when cal_ret_type is verifying it

BUG: cal_ret_type is used to verify or compute function
return types. However the equivalent for variables
exists, even uninitialised ones. The two cases
should be handled similarly, if not by the same
routine.

Note it is NOT a error for a cycle to occur, even
in the (useless) examples:

   val x = x;
   var x = x;

In the first case, the val simply might not be used.
In the second case, there may be an assignment.
For a function, a recursive call is NOT an error
for the same reason: a function may
contain other calls, or be unused:
  fun f(x:int)= { return if x = 0 then 0 else f (x-1); }
Note two branches, the first determines the return type
as 'int' quite happily.

DEPTH:
  Depth is used to determine the argument of the
  fixpoint term.

  Depth is incremented when we decode a type
  or expression into subterms.

PROPAGATION.
It appears as_fixlist can only occur
binding a type expression, and doesn't propagate
into bind_expression when a typeof() term is
part of the type expression: it's pure a syntactic
feature of a localised type expression.

  typedef t = a * typeof(x) as a;
  var x : t;

This is NOT the case, for example:

  typedef t = a * typeof (f of (a)) as a;

shows the as_fixlist label has propagated into
the expression: expressions can contain type
terms. However, the 'as' label IS always
localised to a single term.

Clearly, the same thing can happen with a type alias:

  typedef a = a * typeof (f of (a));

However, type aliases are more general because they
can span statement boundaries:

  typedef a = a * typeof (f of (b));
  typedef b = a;

Of course, it comes to the same thing after
substitution .. but lookup and binding is responsible
for that. The key distinction is that an as label
is just a string, whereas a type alias name has
an index in the symtab, and a fully qualified name
can be used to look it up: it's identifid by
its index, not a string label: OTOH non-top level
as labels don't map to any index.

NASTY CASE: It's possible to have this kind of thing:

  typedef a = typeof ( { typedef b = a; return x; } )

so that a type_alias CAN indeed be defined inside a type
expression. That alias can't escape however. In fact,
desugaring restructures this with a lambda (or should):

  typedef a = typeof (f of ());
  fun f() { typedef b = a; return x; }

This should work BUT if an as_label is propagated
we get a failure:

  typedef a = typeof ( { typedef c = b; return x; } ) as b;

This can be made to work by lifting the as label too,
which means creating a typedef. Hmmm. All as labels
could be replaced by typedefs ..


MORE NOTES:
Each of these traps is used to inject a fixpoint
term into the expression, ensuring analysis terminates
and recursions are represented in typing.

It is sometimes a bit tricky to know when to pass, and when
to reset these detectors: in bind_type' and inner
bind_type of a subterm should usually pass the detectors
with a pushed value in appropriate cases, however and
independent typing, say of an instance index value,
should start with reset traps.

*)

(*
  we match type patterns by cheating a bit:
  we convert the pattern to a type, replacing
  the _ with a dummy type variable. We then
  record the 'as' terms of the pattern as a list
  of equations with the as variable index
  on the left, and the type term on the right:
  the RHS cannot contain any as variables.

  The generated type can contain both,
  but we can factor the as variables out
  and leave the type a function of the non-as
  pattern variables
*)

(* params is list of string * bound type *)

and bind_type'
  state
  bsym_table
  env
  (rs:recstop)
  sr t (params: (string * btypecode_t) list)
  mkenv
: btypecode_t =
  let btp t params = bind_type' state bsym_table env
    {rs with depth = rs.depth+1}
    sr t params mkenv
  in
  let bt t = btp t params in
  let bi i ts = bind_type_index state bsym_table rs sr i ts mkenv in
  let bisub i ts = bind_type_index state bsym_table {rs with depth= rs.depth+1} sr i ts mkenv in
  (*
  print_endline ("[bind_type'] " ^ string_of_typecode t);
  print_endline ("expr_fixlist is " ^
    catmap ","
    (fun (e,d) -> string_of_expr e ^ " [depth " ^si d^"]")
    expr_fixlist
  );

  if List.length params <> 0 then
  begin
    print_endline ("  [" ^
    catmap ", "
    (fun (s,t) -> s ^ " -> " ^ sbt bsym_table t)
    params
    ^ "]"
    )
  end
  else print_endline  ""
  ;
  *)
  let t =
  match t with
  | TYP_patvar _ -> failwith "Not implemented patvar in typecode"
  | TYP_patany _ -> failwith "Not implemented patany in typecode"

  | TYP_intersect ts -> BTYP_intersect (List.map bt ts)
  | TYP_record ts -> BTYP_record (List.map (fun (s,t) -> s,bt t) ts)
  | TYP_variant ts -> BTYP_variant (List.map (fun (s,t) -> s,bt t) ts)

  (* We first attempt to perform the match
    at binding time as an optimisation, if that
    fails, we generate a delayed matching construction.
    The latter will be needed when the argument is a type
    variable.
  *)
  | TYP_type_match (t,ps) ->
    let t = bt t in
    (*
    print_endline ("Typematch " ^ sbt bsym_table t);
    print_endline ("Context " ^ catmap "" (fun (n,t) -> "\n"^ n ^ " -> " ^ sbt bsym_table t) params);
    *)
    let pts = ref [] in
    let finished = ref false in
    List.iter
    (fun (p',t') ->
      (*
      print_endline ("Considering case " ^ string_of_tpattern p' ^ " -> " ^ string_of_typecode t');
      *)
      let p',explicit_vars,any_vars, as_vars, eqns =
        type_of_tpattern state.syms p'
      in
      let p' = bt p' in
      let eqns = List.map (fun (j,t) -> j, bt t) eqns in
      let varset =
        let x =
          List.fold_left (fun s (i,_) -> BidSet.add i s)
          BidSet.empty explicit_vars
        in
          List.fold_left (fun s i -> BidSet.add i s)
          x any_vars
      in
      (* HACK! GACK! we have to assume a variable in a pattern is
        is a TYPE variable .. type patterns don't include coercion
        terms at the moment, so there isn't any way to even
        specify the metatype

        In some contexts the kinding can be infered, for example:

        int * ?x

        clearly x has to be a type .. but a lone type variable
        would require the argument typing to be known ... no
        notation for that yet either
      *)
      let args = List.map (fun (i,s) ->
      (*
      print_endline ("Mapping " ^ s ^ "<"^si i^"> to TYPE");
      *)
      s,BTYP_var (i,BTYP_type 0)) (explicit_vars @ as_vars)
      in
      let t' = btp t' (params@args) in
      let t' = list_subst state.syms.Flx_mtypes2.counter eqns t' in
      (*
        print_endline ("Bound matching is " ^ sbt bsym_table p' ^ " => " ^ sbt bsym_table t');
      *)
      pts := ({pattern=p'; pattern_vars=varset; assignments=eqns},t') :: !pts;
      let u = maybe_unification state.syms.Flx_mtypes2.counter [p', t] in
      match u with
      | None ->  ()
        (* CRAP! The below argument is correct BUT ..
        our unification algorithm isn't strong enough ...
        so just let this thru and hope it is reduced
        later on instantiation
        *)
        (* If the initially bound, context free pattern can never
        unify with the argument, we have a choice: chuck an error,
        or just eliminate the match case -- I'm going to chuck
        an error for now, because I don't see why one would
        ever code such a case, except as a mistake.
        *)
        (*
        clierr sr
          ("[bind_type'] type match argument\n" ^
          sbt bsym_table t ^
          "\nwill never unify with pattern\n" ^
          sbt bsym_table p'
          )
        *)
      | Some mgu ->
        if !finished then
          print_endline "[bind_type] Warning: useless match case ignored"
        else
          let mguvars = List.fold_left (fun s (i,_) -> BidSet.add i s) BidSet.empty mgu in
          if varset = mguvars then finished := true
    )
    ps
    ;
    let pts = List.rev !pts in

    let tm = BTYP_type_match (t,pts) in
    (*
    print_endline ("Bound typematch is " ^ sbt bsym_table tm);
    *)
    tm


  | TYP_dual t ->
    let t = bt t in
    dual t

  | TYP_proj (i,t) ->
    let t = bt t in
    ignore (try unfold t with _ -> failwith "TYP_proj unfold screwd");
    begin match unfold t with
    | BTYP_tuple ls ->
      if i < 1 or i> List.length ls
      then
       clierr sr
        (
          "product type projection index " ^
          string_of_int i ^
          " out of range 1 to " ^
          string_of_int (List.length ls)
        )
      else List.nth ls (i-1)

    | _ ->
      clierr sr
      (
        "\ntype projection requires product type"
      )
    end

  | TYP_dom t ->
    let t = bt t in
    begin match unfold t with
    | BTYP_function (a,b) -> a
    | BTYP_cfunction (a,b) -> a
    | _ ->
      clierr sr
      (
        Flx_srcref.short_string_of_src sr ^
        "\ntype domain requires function"
      )
    end
  | TYP_cod t ->
    let t = bt t in
    begin match unfold t with
    | BTYP_function (a,b) -> b
    | BTYP_cfunction (a,b) -> b
    | _ ->
      clierr sr
      (
        Flx_srcref.short_string_of_src sr ^
        "\ntype codomain requires function"
      )
    end

  | TYP_case_arg (i,t) ->
    let t = bt t in
    ignore (try unfold t with _ -> failwith "TYP_case_arg unfold screwd");
    begin match unfold t with
    | BTYP_unitsum k ->
      if i < 0 or i >= k
      then
        clierr sr
        (
          "sum type extraction index " ^
          string_of_int i ^
          " out of range 0 to " ^ si (k-1)
        )
      else unit_t

    | BTYP_sum ls ->
      if i < 0 or i>= List.length ls
      then
        clierr sr
        (
          "sum type extraction index " ^
          string_of_int i ^
          " out of range 0 to " ^
          string_of_int (List.length ls - 1)
        )
      else List.nth ls i

    | _ ->
      clierr sr
      (
        "sum type extraction requires sum type"
      )
    end


  | TYP_ellipsis ->
    failwith "Unexpected TYP_ellipsis (...) in bind type"
  | TYP_none ->
    failwith "Unexpected TYP_none in bind type"

  | TYP_typeset ts
  | TYP_setunion ts ->
    BTYP_typeset (expand_typeset (BTYP_typeset (List.map bt ts)))

  | TYP_setintersection ts -> BTYP_typesetintersection (List.map bt ts)


  | TYP_isin (elt,tset) ->
    let elt = bt elt in
    let tset = bt tset in
    handle_typeset state sr elt tset

  (* HACK .. assume variable is type TYPE *)
  | TYP_var i ->
    (*
    print_endline ("Fudging metatype of type variable " ^ si i);
    *)
    BTYP_var (i,BTYP_type 0)

  | TYP_as (t,s) ->
    bind_type' state bsym_table env
    { rs with as_fixlist = (s,rs.depth)::rs.as_fixlist }
    sr t params mkenv

  | TYP_typeof e ->
    (*
    print_endline ("Evaluating typeof(" ^ string_of_expr e ^ ")");
    *)
    let t =
      if List.mem_assq e rs.expr_fixlist
      then begin
        (*
        print_endline "Typeof is recursive";
        *)
        let outer_depth = List.assq e rs.expr_fixlist in
        let fixdepth = outer_depth -rs.depth in
        (*
        print_endline ("OUTER DEPTH IS " ^ string_of_int outer_depth);
        print_endline ("CURRENT DEPTH " ^ string_of_int rs.depth);
        print_endline ("FIXPOINT IS " ^ string_of_int fixdepth);
        *)
        BTYP_fix fixdepth
      end
      else begin
        snd (bind_expression' state bsym_table env rs e [])
      end
    in
      (*
      print_endline ("typeof --> " ^ sbt bsym_table t);
      *)
      t

  | TYP_array (t1,t2)->
    let index = match bt t2 with
    | BTYP_tuple [] -> BTYP_unitsum 1
    | x -> x
    in
    BTYP_array (bt t1, index)

  | TYP_tuple ts ->
    let ts' = List.map bt ts in
    BTYP_tuple ts'

  | TYP_unitsum k ->
    (match k with
    | 0 -> BTYP_void
    | 1 -> BTYP_tuple[]
    | _ -> BTYP_unitsum k
    )

  | TYP_sum ts ->
    let ts' = List.map bt ts  in
    if all_units ts' then
      BTYP_unitsum (List.length ts)
    else
      BTYP_sum ts'

  | TYP_function (d,c) ->
    let
      d' = bt d  and
      c' = bt c
    in
      BTYP_function (bt d, bt c)

  | TYP_cfunction (d,c) ->
    let
      d' = bt d  and
      c' = bt c
    in
      BTYP_cfunction (bt d, bt c)

  | TYP_pointer t ->
     let t' = bt t in
     BTYP_pointer t'

  | TYP_void _ ->
    BTYP_void

  | TYP_typefun (ps,r,body) ->
    (*
    print_endline ("BINDING TYPE FUNCTION " ^ string_of_typecode t);
    *)
    let data =
      List.rev_map
      (fun (name,mt) ->
        name,
        bt mt,
        fresh_bid state.syms.counter
      )
      ps
    in
    let pnames =  (* reverse order .. *)
      List.map (fun (n, t, i) ->
        (*
        print_endline ("Binding param " ^ n ^ "<" ^ si i ^ "> metatype " ^ sbt bsym_table t);
        *)
        (n,BTYP_var (i,t))) data
    in
    let bbody =
      (*
      print_endline (" ... binding body .. " ^ string_of_typecode body);
      print_endline ("Context " ^ catmap "" (fun (n,t) -> "\n"^ n ^ " -> " ^ sbt bsym_table t) (pnames @ params));
      *)
      bind_type'
        state
        bsym_table
        env
        { rs with depth=rs.depth+1 }
        sr
        body
        (pnames@params)
        mkenv
    in
      let bparams = (* order as written *)
        List.rev_map (fun (n,t,i) -> (i,t)) data
      in
      (*
      print_endline "BINDING typefunction DONE\n";
      *)
      BTYP_typefun (bparams, bt r, bbody)

  | TYP_apply (TYP_name (_,"_flatten",[]),t2) ->
    let t2 = bt t2 in
    begin match t2 with
    | BTYP_unitsum a -> t2
    | BTYP_sum (BTYP_sum a :: t) -> BTYP_sum (List.fold_left (fun acc b ->
      match b with
      | BTYP_sum b -> acc @ b
      | BTYP_void -> acc
      | _ -> clierr sr "Sum of sums required"
      ) a t)

    | BTYP_sum (BTYP_unitsum a :: t) -> BTYP_unitsum (List.fold_left (fun acc b ->
      match b with
      | BTYP_unitsum b -> acc + b
      | BTYP_tuple [] -> acc + 1
      | BTYP_void -> acc
      | _ -> clierr sr "Sum of unitsums required"
      ) a t)

    | BTYP_sum (BTYP_tuple []  :: t) -> BTYP_unitsum (List.fold_left (fun acc b ->
      match b with
      | BTYP_unitsum b -> acc + b
      | BTYP_tuple [] -> acc + 1
      | BTYP_void -> acc
      | _ -> clierr sr "Sum of unitsums required"
      ) 1 t)

    | _ -> clierr sr ("Cannot flatten type " ^ sbt bsym_table t2)
    end

  | TYP_apply (TYP_void _ as qn, t2)
  | TYP_apply (TYP_name _ as qn, t2)
  | TYP_apply (TYP_case_tag _ as qn, t2)
  | TYP_apply (TYP_typed_case _ as qn, t2)
  | TYP_apply (TYP_lookup _ as qn, t2)
  | TYP_apply (TYP_the _ as qn, t2)
  | TYP_apply (TYP_index _ as qn, t2)
  | TYP_apply (TYP_callback _ as qn, t2) ->
     let qn =
       match qualified_name_of_typecode qn with
       | Some qn -> qn
       | None -> assert false
     in
     (*
     print_endline ("Bind application as type " ^ string_of_typecode t);
     *)
     let t2 = bt t2 in
     (*
     print_endline ("meta typing argument " ^ sbt bsym_table t2);
     *)
     let sign = Flx_metatype.metatype state.sym_table bsym_table sr t2 in
     (*
     print_endline ("Arg type " ^ sbt bsym_table t2 ^ " meta type " ^ sbt bsym_table sign);
     *)
     let t =
       try match qn with
       | `AST_name (sr,name,[]) ->
         let t1 = List.assoc name params in
         BTYP_apply(t1,t2)
       | _ -> raise Not_found
       with Not_found ->

       (* Note: parameters etc cannot be found with a qualified name,
       unless it is a simple name .. which is already handled by
       the previous case .. so we can drop them .. ?
       *)

       (* PROBLEM: we don't know if the term is a type alias
         or type constructor. The former don't overload ..
         the latter do .. lookup_type_qn_with_sig is probably
         the wrong routine .. if it finds a constructor, it
         seems to return the type of the constructor instead
         of the actual constructor ..
       *)
       (*
       print_endline ("Lookup type qn " ^ string_of_qualified_name qn ^ " with sig " ^ sbt bsym_table sign);
       *)
       let t1 = lookup_type_qn_with_sig' state bsym_table sr sr env
         {rs with depth=rs.depth+1 } qn [sign]
       in
       (*
       print_endline ("DONE: Lookup type qn " ^ string_of_qualified_name qn ^ " with sig " ^ sbt bsym_table sign);
       let t1 = bisub j ts in
       *)
       (*
       print_endline ("Result of binding function term is " ^ sbt bsym_table t1);
       *)
       BTYP_apply (t1,t2)
     in
     (*
     print_endline ("type Application is " ^ sbt bsym_table t);
     let t = beta_reduce state.syms sr t in
     *)
     (*
     print_endline ("after beta reduction is " ^ sbt bsym_table t);
     *)
     t


  | TYP_apply (t1,t2) ->
    let t1 = bt t1 in
    let t2 = bt t2 in
    let t = BTYP_apply (t1,t2) in
    (*
    let t = beta_reduce state.syms sr t in
    *)
    t

  | TYP_type_tuple ts ->
    BTYP_type_tuple (List.map bt ts)

  | TYP_type -> BTYP_type 0

  | TYP_name (sr,s,[]) when List.mem_assoc s rs.as_fixlist ->
    BTYP_fix ((List.assoc s rs.as_fixlist)-rs.depth)

  | TYP_name (sr,s,[]) when List.mem_assoc s params ->
    (*
    print_endline "Found in assoc list .. ";
    *)
    List.assoc s params

  | TYP_index (sr,name,index) as x ->
    (*
    print_endline ("[bind type] AST_index " ^ string_of_qualified_name x);
    *)
    let { Flx_sym.vs=vs; symdef=entry } =
      try hfind "lookup" state.sym_table index
      with Not_found ->
        syserr sr ("Synthetic name "^name ^ " not in symbol table!")
    in
    begin match entry with
    | SYMDEF_struct _
    | SYMDEF_cstruct _
    | SYMDEF_union _
    | SYMDEF_abs _
      ->
      (*
      if List.length (fst vs) <> 0 then begin
        print_endline ("Synthetic name "^name ^ " is a nominal type!");
        print_endline ("Using ts = [] .. probably wrong since type is polymorphic!");
      end
      ;
      *)
      let ts = List.map (fun (s,i,_) ->
        (*
        print_endline ("[Ast_index] fudging type variable " ^ si i);
        *)
        BTYP_var (i,BTYP_type 0)) (fst vs)
      in
      (*
      print_endline ("Synthetic name "^name ^ "<"^si index^"> is a nominal type, ts=" ^
      catmap "," (sbt bsym_table) ts
      );
      *)
      BTYP_inst (index,ts)

    | SYMDEF_typevar _ ->
      print_endline ("Synthetic name "^name ^ " is a typevar!");
      syserr sr ("Synthetic name "^name ^ " is a typevar!")

    | _
      ->
        print_endline ("Synthetic name "^name ^ " is not a nominal type!");
        syserr sr ("Synthetic name "^name ^ " is not a nominal type!")
    end

  (* QUALIFIED OR UNQUALIFIED NAME *)
  | TYP_the (sr,qn) ->
    (*
    print_endline ("[bind_type] Matched THE qualified name " ^ string_of_qualified_name qn);
    *)
    let es,ts = lookup_qn_in_env2' state bsym_table env rs qn in
    begin match es with
    | FunctionEntry [index] ->
       let ts = List.map bt ts in
       let f =  bi (sye index) ts in
       (*
       print_endline ("f = " ^ sbt bsym_table f);
       *)
       f

       (*
       BTYP_typefun (params, ret, body)


       of (int * 't) list * 't * 't
       *)
       (*
       failwith "TYPE FUNCTION CLOSURE REQUIRED!"
       *)
       (*
       BTYP_typefun_closure (sye index, ts)
       *)

    | NonFunctionEntry index  ->
      let { Flx_sym.id=id;
            vs=vs;
            sr=sr;
            symdef=entry } =
        hfind "lookup" state.sym_table (sye index)
      in
      (*
      print_endline ("NON FUNCTION ENTRY " ^ id);
      *)
      begin match entry with
      | SYMDEF_type_alias t ->
        (* This is HACKY but probably right most of the time: we're defining
           "the t" where t is parameterised type as a type function accepting
           all the parameters and returning a type .. if the result were
           actually a functor this would be wrong .. you'd need to say
           "the (the t)" to bind the domain of the returned functor ..
        *)
        (* NOTE THIS STUFF IGNORES THE VIEW AT THE MOMENT *)
        let ivs,traint = vs in
        let bmt mt =
          match mt with
          | TYP_patany _ -> BTYP_type 0 (* default *)
          | _ -> (try bt mt with _ -> clierr sr "metatyp binding FAILED")
        in
        let body =
          let env = mkenv (sye index) in
          let xparams = List.map (fun (id,idx,mt) -> id, BTYP_var (idx, bmt mt)) ivs in
          bind_type' state bsym_table env {rs with depth = rs.depth+1} sr t (xparams @ params) mkenv
        in
        let ret = BTYP_type 0 in
        let params = List.map (fun (id,idx,mt) -> idx, bmt mt) ivs in
        BTYP_typefun (params, ret, body)

      | _ ->
        let ts = List.map bt ts in
        bi (sye index) ts
      end

    | _ -> clierr sr
      "'the' expression denotes non-singleton function set"
    end

  | TYP_name _
  | TYP_case_tag _
  | TYP_typed_case _
  | TYP_lookup _
  | TYP_callback _ as x ->
    (*
    print_endline ("[bind_type] Matched qualified name " ^ string_of_qualified_name x);
    *)
    if env = [] then print_endline "WOOPS EMPTY ENVIRONMENT!";
    let x =
      match qualified_name_of_typecode x with
      | Some q -> q
      | None -> assert false
    in
    let sr = src_of_qualified_name x in
    begin match lookup_qn_in_env' state bsym_table env rs x with
    | {base_sym=i; spec_vs=spec_vs; sub_ts=sub_ts},ts ->
      let ts = List.map bt ts in
      (*
      print_endline ("Qualified name lookup finds index " ^ si i);
      print_endline ("spec_vs=" ^ catmap "," (fun (s,j)->s^"<"^si j^">") spec_vs);
      print_endline ("spec_ts=" ^ catmap "," (sbt bsym_table) sub_ts);
      print_endline ("input_ts=" ^ catmap "," (sbt bsym_table) ts);
      begin match hfind "lookup" state.sym_table i with
        | { Flx_sym.id=id;vs=vs;symdef=SYMDEF_typevar _} ->
          print_endline (id ^ " is a typevariable, vs=" ^
            catmap "," (fun (s,j,_)->s^"<"^si j^">") (fst vs)
          )
        | { Flx_sym.id=id} -> print_endline (id ^ " is not a type variable")
      end;
      *)
      let baset = bi i sub_ts in
      (* SHOULD BE CLIENT ERROR not assertion *)
      if List.length ts != List.length spec_vs then begin
        print_endline ("Qualified name lookup finds index " ^ string_of_bid i);
        print_endline ("spec_vs=" ^
          catmap "," (fun (s,j)-> s ^ "<" ^ string_of_bid j ^ ">") spec_vs);
        print_endline ("spec_ts=" ^ catmap "," (sbt bsym_table) sub_ts);
        print_endline ("input_ts=" ^ catmap "," (sbt bsym_table) ts);
        begin match hfind "lookup" state.sym_table i with
          | { Flx_sym.id=id; vs=vs; symdef=SYMDEF_typevar _ } ->
            print_endline (id ^ " is a typevariable, vs=" ^
              catmap ","
                (fun (s,j,_)-> s ^ "<" ^ string_of_bid j ^ ">")
                (fst vs)
            )
          | { Flx_sym.id=id } -> print_endline (id ^ " is not a type variable")
        end;
        clierr sr
        ("Wrong number of type variables, expected " ^ si (List.length spec_vs) ^
        ", but got " ^ si (List.length ts))
      end
      ;
      assert (List.length ts = List.length spec_vs);
      let t = tsubst spec_vs ts baset in
      t

    end

  | TYP_suffix (sr,(qn,t)) ->
    let sign = bt t in
    let result =
      lookup_qn_with_sig' state bsym_table sr sr env rs qn [sign]
    in
    begin match result with
    | BEXPR_closure (i,ts),_ ->
      bi i ts
    | _  -> clierr sr
      (
        "[typecode_of_expr] Type expected, got: " ^
        sbe bsym_table result
      )
    end
  in
    (*
    print_endline ("Bound type is " ^ sbt bsym_table t);
    *)
    t

and cal_assoc_type state (bsym_table:Flx_bsym_table.t) sr t =
  let ct t = cal_assoc_type state bsym_table sr t in
  let chk ls =
    match ls with
    | [] -> BTYP_void
    | h::t ->
      List.fold_left (fun acc t ->
        if acc <> t then
          clierr sr ("[cal_assoc_type] typeset elements should all be assoc type " ^ sbt bsym_table acc)
        ;
        acc
     ) h t
  in
  match t with
  | BTYP_type i -> t
  | BTYP_function (a,b) -> BTYP_function (ct a, ct b)

  | BTYP_intersect ls
  | BTYP_typesetunion ls
  | BTYP_typeset ls
    ->
    let ls = List.map ct ls in chk ls

  | BTYP_tuple _
  | BTYP_record _
  | BTYP_variant _
  | BTYP_unitsum _
  | BTYP_sum _
  | BTYP_cfunction _
  | BTYP_pointer _
  | BTYP_array _
  | BTYP_void
    -> BTYP_type 0

  | BTYP_inst (i,ts) ->
    (*
    print_endline ("Assuming named type "^si i^" is a TYPE");
    *)
    BTYP_type 0


  | BTYP_type_match (_,ls) ->
    let ls = List.map snd ls in
    let ls = List.map ct ls in chk ls

  | _ -> clierr sr ("Don't know what to make of " ^ sbt bsym_table t)

and bind_type_index state (bsym_table:Flx_bsym_table.t) (rs:recstop) sr index ts mkenv
=
  (*
  print_endline
  (
    "BINDING INDEX " ^ string_of_int index ^
    " with ["^ catmap ", " (sbt bsym_table) ts^ "]"
  );
  print_endline ("type alias fixlist is " ^ catmap ","
    (fun (i,j) -> si i ^ "(depth "^si j^")") type_alias_fixlist
  );
  *)
  if List.mem_assoc index rs.type_alias_fixlist
  then begin
    (*
    print_endline (
      "Making fixpoint for Recursive type alias " ^
      (
        match get_data state.sym_table index with { Flx_sym.id=id;sr=sr}->
          id ^ " defined at " ^
          Flx_srcref.short_string_of_src sr
      )
    );
    *)
    BTYP_fix ((List.assoc index rs.type_alias_fixlist)-rs.depth)
  end
  else begin
  (*
  print_endline "bind_type_index";
  *)
  let ts = adjust_ts state.sym_table bsym_table sr index ts in
  (*
  print_endline ("Adjusted ts =h ["^ catmap ", " (sbt bsym_table) ts^ "]");
  *)
  let bt t =
      (*
      print_endline "Making params .. ";
      *)
      let vs,_ = find_vs state.sym_table index in
      if List.length vs <> List.length ts then begin
        print_endline ("vs=" ^
          catmap "," (fun (s,i,_)-> s ^ "<" ^ string_of_bid i ^ ">") vs);
        print_endline ("ts=" ^ catmap "," (sbt bsym_table) ts);
        failwith "len vs != len ts"
      end
      else
      let params = List.map2 (fun (s,i,_) t -> s,t) vs ts in

      (*
      let params = make_params state.sym_table sr index ts in
      *)
      (*
      print_endline ("params made");
      *)
      let env:env_t = mkenv index in
      let t =
        bind_type' state bsym_table env
        { rs with type_alias_fixlist = (index,rs.depth):: rs.type_alias_fixlist }
        sr t params mkenv
      in
        (*
        print_endline ("Unravelled and bound is " ^ sbt bsym_table t);
        *)
        (*
        let t = beta_reduce state.syms sr t in
        *)
        (*
        print_endline ("Beta reduced: " ^ sbt bsym_table t);
        *)
        t
  in
  match get_data state.sym_table index with
  | { Flx_sym.id=id; sr=sr; parent=parent; vs=vs; dirs=dirs; symdef=entry } ->
    (*
    if List.length vs <> List.length ts
    then
      clierr sr
      (
        "[bind_type_index] Wrong number of type arguments for " ^ id ^
        ", expected " ^
        si (List.length vs) ^ " got " ^ si (List.length ts)
      );
    *)
    match entry with
    | SYMDEF_typevar mt ->
      (* HACK! We will assume metatype are entirely algebraic,
        that is, they cannot be named and referenced, we also
        assume they cannot be subscripted .. the bt routine
        that works for type aliases doesn't seem to work for
        metatypes .. we get vs != ts .. ts don't make sense
        for type variables, only for named things ..
      *)
      (* WELL the above is PROBABLY because we're calling
      this routine using sye function to strip the view,
      so the supplied ts are wrong ..
      *)
      (*
      print_endline ("CALCULATING TYPE VARIABLE METATYPE " ^ si index ^ " unbound=" ^ string_of_typecode mt);
      *)
      (* weird .. a type variables parent function has an env containing
      the type variable .. so we need ITS parent for resolving the
      meta type ..??

      No? We STILL get an infinite recursion???????
      *)
      (*
      print_endline ("type variable index " ^ si index);
      *)
      let env = match parent with
        | Some parent ->
          (*
          print_endline ("It's parent is " ^ si parent);
          *)
          (*
          let {parent=parent} = hfind "lookup" state.sym_table parent in
          begin match parent with
          | Some parent ->
             print_endline ("and IT's parent is " ^ si parent);
          *)
            let mkenv i = mk_bare_env state bsym_table i in
            mkenv parent
          (*
          | None -> []
          end
          *)
        | None -> []
      in
      let mt = inner_bind_type state bsym_table env sr rs mt in
      (*
      print_endline ("Bound metatype is " ^ sbt bsym_table mt);
      let mt = cal_assoc_type state sr mt in
      print_endline ("Assoc type is " ^ sbt bsym_table mt);
      *)
      BTYP_var (index,mt)

    (* type alias RECURSE *)
    | SYMDEF_type_alias t ->
      (*
      print_endline ("Unravelling type alias " ^ id);
      *)
      bt t

    | SYMDEF_abs _ ->
      BTYP_inst (index,ts)

    | SYMDEF_newtype _
    | SYMDEF_union _
    | SYMDEF_struct _
    | SYMDEF_cstruct _
    | SYMDEF_typeclass
      ->
      BTYP_inst (index,ts)


    (* allow binding to type constructors now too .. *)
    | SYMDEF_const_ctor (uidx,ut,idx,vs') ->
      BTYP_inst (index,ts)

    | SYMDEF_nonconst_ctor (uidx,ut,idx,vs',argt) ->
      BTYP_inst (index,ts)

    | _ ->
      clierr sr
      (
        "[bind_type_index] Type " ^ id ^ "<" ^ string_of_bid index ^ ">" ^
        " must be a type [alias, abstract, union, struct], got:\n" ^
        string_of_symdef entry id vs
      )
  end


and base_typename_of_literal v = match v with
  | AST_int (t,_) -> t
  | AST_float (t,_) -> t
  | AST_string _ -> "string"
  | AST_cstring _ -> "charp"
  | AST_wstring _ -> "wstring"
  | AST_ustring _ -> "string"

and  type_of_literal state bsym_table env sr v : btypecode_t =
  let _,_,root,_,_ = List.hd (List.rev env) in
  let name = base_typename_of_literal v in
  let t = TYP_name (sr,name,[]) in
  let bt = inner_bind_type state bsym_table env sr rsground t in
  bt

and type_of_index' (state:lookup_state_t) bsym_table rs (index:bid_t) : btypecode_t =
    (*
    let () = print_endline ("Top level type of index " ^ si index) in
    *)
    if Hashtbl.mem state.syms.ticache index
    then begin
      let t = Hashtbl.find state.syms.ticache index in
      (*
      let () = print_endline ("Cached .." ^ sbt bsym_table t) in
      *)
      t
    end
    else
      let t = inner_type_of_index state bsym_table rs index in
      (*
      print_endline ("Type of index after inner "^ si index ^ " is " ^ sbt bsym_table t);
      *)
      let _ = try unfold t with _ ->
        print_endline "type_of_index produced free fixpoint";
        failwith ("[type_of_index] free fixpoint constructed for " ^ sbt bsym_table t)
      in
      let sr = try
        match hfind "lookup" state.sym_table index with { Flx_sym.sr=sr }-> sr
        with Not_found -> dummy_sr
      in
      let t = beta_reduce state.syms bsym_table sr t in
      (match t with (* HACK .. *)
      | BTYP_fix _ -> ()
      | _ -> Hashtbl.add state.syms.ticache index t
      );
      t


and type_of_index_with_ts' state bsym_table rs sr (index:bid_t) ts =
  (*
  print_endline "OUTER TYPE OF INDEX with TS";
  *)
  let t = type_of_index' state bsym_table rs index in
  let varmap = make_varmap state.sym_table bsym_table sr index ts in
  let t = varmap_subst varmap t in
  beta_reduce state.syms bsym_table sr t

(* This routine should ONLY 'fail' if the return type
  is indeterminate. This cannot usually happen.

  Otherwise, the result may be recursive, possibly
  Fix 0 -- which is determinate 'indeterminate' value :-)

  For example: fun f(x:int) { return f x; }

  should yield fix 0, and NOT fail.
*)


(* cal_ret_type uses the private name map *)
(* args is string,btype list *)
and cal_ret_type state bsym_table (rs:recstop) index args =
  (*
  print_endline ("[cal_ret_type] index " ^ si index);
  print_endline ("expr_fixlist is " ^
    catmap ","
    (fun (e,d) -> string_of_expr e ^ " [depth " ^si d^"]")
    rs.expr_fixlist
  );
  *)
  let mkenv i = build_env state bsym_table (Some i) in
  let env = mkenv index in
  (*
  print_env_short env;
  *)
  match (get_data state.sym_table index) with
  | { Flx_sym.id=id;
      sr=sr;
      parent=parent;
      vs=vs; 
      dirs=dirs;
      symdef=SYMDEF_function ((ps,_),rt,props,exes)
    } ->
    (*
    print_endline ("Calculate return type of " ^ id);
    *)
    let rt = bind_type' state bsym_table env rs sr rt args mkenv in
    let rt = beta_reduce state.syms bsym_table sr rt in
    let ret_type = ref rt in
    (*
    begin match rt with
    | BTYP_var (i,_) when i = index ->
      print_endline "No return type given"
    | _ ->
      print_endline (" .. given type is " ^ sbt bsym_table rt)
    end
    ;
    *)
    let return_counter = ref 0 in
    List.iter
    (fun exe -> match exe with
    | (sr,EXE_fun_return e) ->
      incr return_counter;
      (*
      print_endline ("  .. Handling return of " ^ string_of_expr e);
      *)
      begin try
        let t =
          (* this is bad code .. we lose detection
          of errors other than recursive dependencies ..
          which shouldn't be errors anyhow ..
          *)
            snd
            (
              bind_expression' state bsym_table env
              { rs with idx_fixlist = index::rs.idx_fixlist }
              e []
            )
        in
        if Flx_do_unify.do_unify
          state.syms
          state.sym_table
          bsym_table
          !ret_type
          t
          (* the argument order is crucial *)
        then
          ret_type := varmap_subst state.syms.varmap !ret_type
        else begin
          (*
          print_endline
          (
            "[cal_ret_type2] Inconsistent return type of " ^ id ^ "<"^string_of_int index^">" ^
            "\nGot: " ^ sbt bsym_table !ret_type ^
            "\nAnd: " ^ sbt bsym_table t
          )
          ;
          *)
          clierr sr
          (
            "[cal_ret_type2] Inconsistent return type of " ^ id ^ "<" ^
            string_of_bid index ^ ">" ^
            "\nGot: " ^ sbt bsym_table !ret_type ^
            "\nAnd: " ^ sbt bsym_table t
          )
        end
      with
        | Stack_overflow -> failwith "[cal_ret_type] Stack overflow"
        | Expr_recursion e -> ()
        | Free_fixpoint t -> ()
        | Unresolved_return (sr,s) -> ()
        | ClientError (sr,s) as e -> raise (ClientError (sr,"Whilst calculating return type:\n"^s))
        | x ->
        (*
        print_endline ("  .. Unable to compute type of " ^ string_of_expr e);
        print_endline ("Reason: " ^ Printexc.to_string x);
        *)
        ()
      end
    | _ -> ()
    )
    exes
    ;
    if !return_counter = 0 then (* it's a procedure .. *)
    begin
      let mgu = Flx_do_unify.do_unify
        state.syms
        state.sym_table
        bsym_table
        !ret_type
        BTYP_void
      in
      ret_type := varmap_subst state.syms.varmap !ret_type
    end
    ;
    (* not sure if this is needed or not ..
      if a type variable is computed during evaluation,
      but the evaluation fails .. substitute now
    ret_type := varmap_subst state.syms.varmap !ret_type
    ;
    *)
    (*
    let ss = ref "" in
    Hashtbl.iter
    (fun i t -> ss:=!ss ^si i^ " --> " ^sbt bsym_table t^ "\n")
    state.syms.varmap;
    print_endline ("state.syms.varmap=" ^ !ss);
    print_endline ("  .. ret type index " ^ si index ^ " = " ^ sbt bsym_table !ret_type);
    *)
    !ret_type

  | _ -> assert false


and inner_type_of_index_with_ts
  state
  bsym_table
  sr
  (rs:recstop)
  (index:bid_t)
  (ts: btypecode_t list)
: btypecode_t =
 (*
 print_endline ("Inner type of index with ts .. " ^ si index ^ ", ts=" ^ catmap "," (sbt bsym_table) ts);
 *)
 let t = inner_type_of_index state bsym_table rs index in
 let pvs,vs,_ = find_split_vs state.sym_table index in
 (*
 print_endline ("#pvs=" ^ si (List.length pvs) ^ ", #vs="^si (List.length vs) ^", #ts="^
 si (List.length ts));
 *)
 (*
 let ts = adjust_ts state.sym_table sr index ts in
 print_endline ("#adj ts = " ^ si (List.length ts));
 let vs,_ = find_vs state.sym_table index in
 assert (List.length vs = List.length ts);
 *)
 if (List.length ts != List.length vs + List.length pvs) then begin
   print_endline ("#pvs=" ^ si (List.length pvs) ^
     ", #vs="^si (List.length vs) ^", #ts="^
     si (List.length ts)
   );
   print_endline ("#ts != #vs + #pvs")
 end
 ;
 assert (List.length ts = List.length vs + List.length pvs);
 let varmap = make_varmap state.sym_table bsym_table sr index ts in
 let t = varmap_subst varmap t in
 let t = beta_reduce state.syms bsym_table sr t in
 (*
 print_endline ("type_of_index=" ^ sbt bsym_table t);
 *)
 t


(* this routine is called to find the type of a function
or variable .. so there's no type_alias_fixlist ..
*)
and inner_type_of_index
  state
  bsym_table
  (rs:recstop)
  (index:bid_t)
: btypecode_t =
  (*
  print_endline ("[inner_type_of_index] " ^ si index);
  print_endline ("expr_fixlist is " ^
    catmap ","
    (fun (e,d) -> string_of_expr e ^ " [depth " ^si d^"]")
    rs.expr_fixlist
  );
  *)
  (* check the cache *)
  try Hashtbl.find state.syms.ticache index
  with Not_found ->

  (* check index recursion *)
  if List.mem index rs.idx_fixlist
  then BTYP_fix (-rs.depth)
  else begin
  match get_data state.sym_table index with
  | { Flx_sym.id=id;
      sr=sr;
      parent=parent;
      vs=vs;
      dirs=dirs;
      symdef=entry }
  ->
  let mkenv i = build_env state bsym_table (Some i) in
  let env:env_t = mkenv index in
  (*
  print_endline ("Setting up env for " ^ si index);
  print_env_short env;
  *)
  let bt t:btypecode_t =
    let t' =
      bind_type' state bsym_table env rs sr t [] mkenv in
    let t' = beta_reduce state.syms bsym_table sr t' in
    t'
  in
  match entry with
  | SYMDEF_callback _ ->
      print_endline "Inner type of index finds callback";
      assert false
  | SYMDEF_inherit qn ->
      failwith ("Woops inner_type_of_index found inherit " ^
        string_of_bid index)
  | SYMDEF_inherit_fun qn ->
      failwith ("Woops inner_type_of_index found inherit fun!! " ^
        string_of_bid index)
  | SYMDEF_type_alias t ->
    begin
      let t = bt t in
      let mt = Flx_metatype.metatype state.sym_table bsym_table sr t in
      (*
      print_endline ("Type of type alias is meta_type: " ^ sbt bsym_table mt);
      *)
      mt
    end

  | SYMDEF_function ((ps,_), rt,props,_) ->
    let pts = List.map (fun(_,_,t,_)->t) ps in
    let rt' =
      try Hashtbl.find state.syms.varmap index with Not_found ->
      cal_ret_type state bsym_table { rs with idx_fixlist = index::rs.idx_fixlist}
      index []
    in
      (* this really isn't right .. need a better way to
        handle indeterminate result .. hmm ..
      *)
      if var_i_occurs index rt' then begin
        (*
        print_endline (
          "[type_of_index'] " ^
          "function "^id^"<"^string_of_int index^
          ">: Can't resolve return type, got : " ^
          sbt bsym_table rt' ^
          "\nPossibly each returned expression depends on the return type" ^
          "\nTry adding an explicit return type annotation"
        );
        *)
        raise (Unresolved_return (sr,
        (
          "[type_of_index'] " ^
          "function " ^ id ^ "<" ^ string_of_bid index ^
          ">: Can't resolve return type, got : " ^
          sbt bsym_table rt' ^
          "\nPossibly each returned expression depends on the return type" ^
          "\nTry adding an explicit return type annotation"
        )))
      end else
        let d =bt (type_of_list pts) in
        let t =
          if List.mem `Cfun props
          then BTYP_cfunction (d,rt')
          else BTYP_function (d, rt')
        in
        t

  | SYMDEF_const (_,t,_,_)

  | SYMDEF_val (t)
  | SYMDEF_var (t) -> bt t
  | SYMDEF_ref (t) -> BTYP_pointer (bt t)

  | SYMDEF_parameter (`PVal,t)
  | SYMDEF_parameter (`PFun,t)
  | SYMDEF_parameter (`PVar,t) -> bt t
  | SYMDEF_parameter (`PRef,t) -> BTYP_pointer (bt t)

  | SYMDEF_const_ctor (_,t,_,_)
    ->
    (*
    print_endline ("Calculating type of variable " ^ id);
    *)
    bt t

  | SYMDEF_nonconst_ctor (_,ut,_,_,argt) ->
    bt (TYP_function (argt,ut))

  | SYMDEF_match_check _ ->
    BTYP_function (BTYP_tuple [], flx_bbool)

  | SYMDEF_fun (_,pts,rt,_,_,_) ->
    let t = TYP_function (type_of_list pts,rt) in
    bt t

  | SYMDEF_union _ ->
    clierr sr ("Union "^id^" doesn't have a type")

  (* struct as function *)
  | SYMDEF_cstruct (ls)
  | SYMDEF_struct (ls) ->
    (* ARGGG WHAT A MESS *)
    let ts = List.map (fun (s,i,_) -> TYP_name (sr,s,[])) (fst vs) in
    let ts = List.map bt ts in
  (*
  print_endline "inner_type_of_index: struct";
  *)
    let ts = adjust_ts state.sym_table bsym_table sr index ts in
    let t = type_of_list (List.map snd ls) in
    let t = BTYP_function(bt t,BTYP_inst (index,ts)) in
    (*
    print_endline ("Struct as function type is " ^ sbt bsym_table t);
    *)
    t

  | SYMDEF_abs _ ->
    clierr sr
    (
      "[type_of_index] Expected declaration of typed entity for index " ^
      string_of_bid index ^ "\ngot abstract type " ^ id  ^ " instead.\n" ^
      "Perhaps a constructor named " ^ "_ctor_" ^ id ^ " is missing " ^
      " or out of scope."
    )

  | _ ->
    clierr sr
    (
      "[type_of_index] Expected declaration of typed entity for index "^
      string_of_bid index ^ ", got " ^ id
    )
  end

and cal_apply state bsym_table sr rs ((be1,t1) as tbe1) ((be2,t2) as tbe2) : tbexpr_t =
  let mkenv i = build_env state bsym_table (Some i) in
  let be i e = bind_expression' state bsym_table (mkenv i) rs e [] in
  (*
  print_endline ("Cal apply of " ^ sbe bsym_table tbe1 ^ " to " ^ sbe bsym_table tbe2);
  *)
  let ((re,rt) as r) = cal_apply' state bsym_table be sr tbe1 tbe2 in
  (*
  print_endline ("Cal_apply, ret type=" ^ sbt bsym_table rt);
  *)
  r

and cal_apply' state bsym_table be sr ((be1,t1) as tbe1) ((be2,t2) as tbe2) : tbexpr_t =
  let rest,reorder =
    match unfold t1 with
    | BTYP_function (argt,rest)
    | BTYP_cfunction (argt,rest) ->
      if type_match state.syms.counter argt t2
      then rest, None
      else
      let reorder: tbexpr_t list option =
        match be1 with
        | BEXPR_closure (i,ts) ->
          begin match t2 with
          (* a bit of a hack .. *)
          | BTYP_record _ | BTYP_tuple [] ->
            let rs = match t2 with
              | BTYP_record rs -> rs
              | BTYP_tuple [] -> []
              | _ -> assert false
            in
            begin let pnames = match hfind "lookup" state.sym_table i with
            | { Flx_sym.symdef=SYMDEF_function (ps,_,_,_) } ->
              List.map (fun (_,name,_,d)->
                name,
                match d with None -> None | Some e -> Some (be i e)
              ) (fst ps)
            | _ -> assert false
            in
            let n = List.length rs in
            let rs= List.sort (fun (a,_) (b,_) -> compare a b) rs in
            let rs = List.map2 (fun (name,t) j -> name,(j,t)) rs (nlist n) in
            try Some (List.map
              (fun (name,d) ->
                try (match List.assoc name rs with
                | j,t-> BEXPR_get_n (j,tbe2),t)
                with Not_found ->
                match d with
                | Some d ->d
                | None -> raise Not_found
              )
              pnames
            )
            with Not_found -> None
            end

          | _ -> None
          end
        | _ -> None
      in
      begin match reorder with
      | Some _ -> rest,reorder
      | None ->
        clierr sr
        (
          "[cal_apply] Function " ^
          sbe bsym_table tbe1 ^
          "\nof type " ^
          sbt bsym_table t1 ^
          "\napplied to argument " ^
          sbe bsym_table tbe2 ^
          "\n of type " ^
          sbt bsym_table t2 ^
          "\nwhich doesn't agree with parameter type\n" ^
          sbt bsym_table argt
        )
      end

    (* HACKERY TO SUPPORT STRUCT CONSTRUCTORS *)
    | BTYP_inst (index,ts) ->
      begin match get_data state.sym_table index with
      { Flx_sym.id=id; vs=vs; symdef=entry } ->
        begin match entry with
        | SYMDEF_cstruct (cs) -> t1, None
        | SYMDEF_struct (cs) -> t1, None
        | _ ->
          clierr sr
          (
            "[cal_apply] Attempt to apply non-struct " ^ id ^ ", type " ^
            sbt bsym_table t1 ^
            " as constructor"
          )
        end
      end
    | _ ->
      clierr sr
      (
        "Attempt to apply non-function\n" ^
        sbe bsym_table tbe1 ^
        "\nof type\n" ^
        sbt bsym_table t1 ^
        "\nto argument of type\n" ^
        sbe bsym_table tbe2
      )
  in
  (*
  print_endline
  (
    "---------------------------------------" ^
    "\nApply type " ^ sbt bsym_table t1 ^
    "\nto argument of type " ^ sbt bsym_table t2 ^
    "\nresult type is " ^ sbt bsym_table rest ^
    "\n-------------------------------------"
  );
  *)

  let rest = varmap_subst state.syms.varmap rest in
  if rest = BTYP_void then
    clierr sr
    (
      "[cal_apply] Function " ^
      sbe bsym_table tbe1 ^
      "\nof type " ^
      sbt bsym_table t1 ^
      "\napplied to argument " ^
      sbe bsym_table tbe2 ^
      "\n of type " ^
      sbt bsym_table t2 ^
      "\nreturns void"
    )
  else

  (* We have to allow type variables now .. the result
  should ALWAYS be determined, and independent of function
  return type unknowns, even if that means it is a recursive
  type, perhaps like 'Fix 0' ..: we should really test
  for the *function* return type variable not being
  eliminated ..
  *)
  (*
  if var_occurs rest
  then
    clierr sr
    (
      "[cal_apply] Type variable in return type applying\n" ^
        sbe bsym_table tbe1 ^
        "\nof type\n" ^
        sbt bsym_table t1 ^
        "\nto argument of type\n" ^
        sbe bsym_table tbe2
    )
  ;
  *)
  let x2 = match reorder with
  | None -> be2,t2
  | Some xs ->
    match xs with
    | [x]-> x
    | _ -> BEXPR_tuple xs,BTYP_tuple (List.map snd xs)
  in
  BEXPR_apply ((be1,t1), x2),rest

and koenig_lookup state bsym_table env rs sra id' name_map fn t2 ts =
  (*
  print_endline ("Applying Koenig lookup for " ^ fn);
  *)
  let entries =
    try Hashtbl.find name_map fn
    with Not_found ->
      clierr sra
      (
        "Koenig lookup: can't find name "^
        fn^ " in " ^
        (match id' with
        | "" -> "top level module"
        | _ -> "module '" ^ id' ^ "'"
        )
      )
  in
  match (entries:entry_set_t) with
  | FunctionEntry fs ->
    (*
    print_endline ("Got candidates: " ^ string_of_entry_set entries);
    *)
    begin match resolve_overload' state bsym_table env rs sra fs fn [t2] ts with
    | Some (index'',t,ret,mgu,ts) ->
      (*
      print_endline "Overload resolution OK";
      *)
      BEXPR_closure (index'',ts),
       type_of_index_with_ts' state bsym_table rs sra index'' ts


    | None ->
        (*
        let n = ref 0
        in Hashtbl.iter (fun _ _ -> incr n) name_map;
        print_endline ("module defines " ^ string_of_int !n^ " entries");
        *)
        clierr sra
        (
          "[flx_ebind] Koenig lookup: Can't find match for " ^ fn ^
          "\ncandidates are: " ^ full_string_of_entry_set bsym_table entries
        )
    end
  | NonFunctionEntry _ -> clierr sra "Koenig lookup expected function"

and lookup_qn_with_sig'
  state
  bsym_table
  sra srn
  env (rs:recstop)
  (qn:qualified_name_t)
  (signs:btypecode_t list)
: tbexpr_t =
  (*
  print_endline ("[lookup_qn_with_sig] " ^ string_of_qualified_name qn);
  print_endline ("sigs = " ^ catmap "," (sbt bsym_table) signs);
  print_endline ("expr_fixlist is " ^
    catmap ","
    (fun (e,d) -> string_of_expr e ^ " [depth " ^si d^"]")
    rs.expr_fixlist
  );
  *)
  let bt sr t =
    (*
    print_endline "NON PROPAGATING BIND TYPE";
    *)
    inner_bind_type state bsym_table env sr rs t
  in
  let handle_nonfunction_index index ts =
    begin match get_data state.sym_table index with
    | { Flx_sym.id=id; sr=sr; parent=parent; vs=vs; dirs=dirs; symdef=entry } ->
      begin match entry with
      | SYMDEF_inherit_fun qn ->
          clierr sr "Chasing functional inherit in lookup_qn_with_sig'";

      | SYMDEF_inherit qn ->
          clierr sr "Chasing inherit in lookup_qn_with_sig'";

      | SYMDEF_cstruct _
      | SYMDEF_struct _ ->
        let sign = try List.hd signs with _ -> assert false in
        let t = type_of_index_with_ts' state bsym_table rs sr index ts in
        (*
        print_endline ("Struct constructor found, type= " ^ sbt bsym_table t);
        *)
(*
print_endline (id ^ ": lookup_qn_with_sig: struct");
*)
        (*
        let ts = adjust_ts state.sym_table sr index ts in
        *)
        begin match t with
        | BTYP_function (a,_) ->
          if not (type_match state.syms.counter a sign) then
            clierr sr
            (
              "[lookup_qn_with_sig] Struct constructor for "^id^" has wrong signature, got:\n" ^
              sbt bsym_table t ^
              "\nexpected:\n" ^
              sbt bsym_table sign
            )
        | _ -> assert false
        end
        ;
        BEXPR_closure (index,ts),
        t

      | SYMDEF_union _
      | SYMDEF_type_alias _ ->
        (*
        print_endline "mapping type name to _ctor_type [2]";
        *)
        let qn =  match qn with
          | `AST_name (sr,name,ts) -> `AST_name (sr,"_ctor_"^name,ts)
          | `AST_lookup (sr,(e,name,ts)) -> `AST_lookup (sr,(e,"_ctor_"^name,ts))
          | _ -> failwith "Unexpected name kind .."
        in
        lookup_qn_with_sig' state bsym_table sra srn env rs qn signs

      | SYMDEF_const (_,t,_,_)
      | SYMDEF_val t
      | SYMDEF_var t
      | SYMDEF_ref t
      | SYMDEF_parameter (_,t)
        ->
print_endline (id ^ ": lookup_qn_with_sig: val/var");
        (*
        let ts = adjust_ts state.sym_table sr index ts in
        *)
        let t = bt sr t in
        let bvs = List.map (fun (s,i,tp) -> s,i) (fst vs) in
        let t = try tsubst bvs ts t with _ -> failwith "[lookup_qn_with_sig] WOOPS" in
        begin match t with
        | BTYP_function (a,b) ->
          let sign = try List.hd signs with _ -> assert false in
          if not (type_match state.syms.counter a sign) then
          clierr srn
          (
            "[lookup_qn_with_sig] Expected variable "^id ^
            "<" ^ string_of_bid index ^
            "> to have function type with signature " ^
            sbt bsym_table sign ^
            ", got function type:\n" ^
            sbt bsym_table t
          )
          else
            BEXPR_name (index, ts),
            t

        | _ ->
          clierr srn
          (
            "[lookup_qn_with_sig] expected variable " ^
            id ^ "<" ^ string_of_bid index ^
            "> to be of function type, got:\n" ^
            sbt bsym_table t

          )
        end
      | _ ->
        clierr sr
        (
          "[lookup_qn_with_sig] Named Non function entry "^id^
          " must be function type: requires struct," ^
          "or value or variable of function type"
        )
      end
    end
  in
  match qn with
  | `AST_callback (sr,qn) ->
    failwith "[lookup_qn_with_sig] Callbacks not implemented yet"

  | `AST_the (sr,qn) ->
    (*
    print_endline ("AST_the " ^ string_of_qualified_name qn);
    *)
    lookup_qn_with_sig' state bsym_table sra srn env rs qn signs

  | `AST_void _ -> clierr sra "qualified-name is void"

  | `AST_case_tag _ -> clierr sra "Can't lookup case tag here"

  (* WEIRD .. this is a qualified name syntactically ..
    but semantically it belongs in bind_expression
    where this code is duplicated ..

    AH NO it isn't. Here, we always return a function
    type, even for constant constructors (because we
    have a signature ..)
  *)
  | `AST_typed_case (sr,v,t) ->
    let t = bt sr t in
    begin match unfold t with
    | BTYP_unitsum k ->
      if v<0 or v>= k
      then clierr sra "Case index out of range of sum"
      else
        let ct = BTYP_function (unit_t,t) in
        BEXPR_case (v,t),ct

    | BTYP_sum ls ->
      if v<0 or v >= List.length ls
      then clierr sra "Case index out of range of sum"
      else let vt = List.nth ls v in
      let ct = BTYP_function (vt,t) in
      BEXPR_case (v,t), ct

    | _ ->
      clierr sr
      (
        "[lookup_qn_with_sig] Type of case must be sum, got " ^
        sbt bsym_table t
      )
    end

  | `AST_name (sr,name,ts) ->
    (* HACKERY TO SUPPORT _ctor_type lookup -- this is really gross,
       since the error could be anything ..  the retry here should
       only be used if the lookup failed because sig_of_symdef found
       a typename..
    *)
    let ts = List.map (bt sr) ts in
    (*
    print_endline ("Lookup simple name " ^ name);
    *)
    begin 
      try
        lookup_name_with_sig
          state
          bsym_table
          sra srn
          env env rs name ts signs
      with 
      | OverloadKindError (sr,s) ->
        begin 
          try
            (*
            print_endline "Trying _ctor_ hack";
            *)
            lookup_name_with_sig
              state
              bsym_table
              sra srn
              env env rs ("_ctor_" ^ name) ts signs
           with ClientError (_,s2) ->
             clierr sr
             (
             "ERROR: " ^ s ^
             "\nERROR2: " ^ s2
             )
        end
      | Free_fixpoint _ as x -> raise x
      | x -> print_endline (
        "Other exn = " ^ Printexc.to_string x);
        raise x;
    end

  | `AST_index (sr,name,index) as x ->
    (*
    print_endline ("[lookup qn with sig] AST_index " ^ string_of_qualified_name x);
    *)
    begin match get_data state.sym_table index with
    | { Flx_sym.vs=vs; id=id; sr=sra; symdef=entry } ->
    match entry with
    | SYMDEF_fun _
    | SYMDEF_function _
    | SYMDEF_match_check _
      ->
      let vs = find_vs state.sym_table index in
      let ts = List.map (fun (_,i,_) -> BTYP_var (i,BTYP_type 0)) (fst vs) in
      BEXPR_closure (index,ts),
      inner_type_of_index state bsym_table rs index

    | _ ->
      (*
      print_endline "Non function ..";
      *)
      let ts = List.map (fun (_,i,_) -> BTYP_var (i,BTYP_type 0)) (fst vs) in
      handle_nonfunction_index index ts
    end

  | `AST_lookup (sr,(qn',name,ts)) ->
    let m =  eval_module_expr state bsym_table env qn' in
    match m with (Simple_module (impl, ts',htab,dirs)) ->
    (* let n = List.length ts in *)
    let ts = List.map (bt sr)( ts' @ ts) in
    (*
    print_endline ("Module " ^ si impl ^ "[" ^ catmap "," (sbt bsym_table) ts' ^"]");
    *)
    let env' = mk_bare_env state bsym_table impl in
    let tables = get_pub_tables state bsym_table env' rs dirs in
    let result = lookup_name_in_table_dirs htab tables sr name in
    begin match result with
    | None ->
      clierr sr
      (
        "[lookup_qn_with_sig] AST_lookup: Simple_module: Can't find name " ^ name
      )
    | Some entries -> match entries with
    | NonFunctionEntry (index) ->
      handle_nonfunction_index (sye index) ts

    | FunctionEntry fs ->
      match
        resolve_overload'
        state bsym_table env rs sra fs name signs ts
      with
      | Some (index,t,ret,mgu,ts) ->
        (*
        print_endline ("Resolved overload for " ^ name);
        print_endline ("ts = [" ^ catmap ", " (sbt bsym_table) ts ^ "]");
        *)
        (*
        let ts = adjust_ts state.sym_table sr index ts in
        *)
        BEXPR_closure (index,ts),
         type_of_index_with_ts' state bsym_table rs sr index ts

      | None ->
        clierr sra
        (
          "[lookup_qn_with_sig] (Simple module) Unable to resolve overload of " ^
          string_of_qualified_name qn ^
          " of (" ^ catmap "," (sbt bsym_table) signs ^")\n" ^
          "candidates are: " ^ full_string_of_entry_set bsym_table entries
        )
    end

and lookup_type_qn_with_sig'
  state
  bsym_table
  sra srn
  env (rs:recstop)
  (qn:qualified_name_t)
  (signs:btypecode_t list)
: btypecode_t =
  (*
  print_endline ("[lookup_type_qn_with_sig] " ^ string_of_qualified_name qn);
  print_endline ("sigs = " ^ catmap "," (sbt bsym_table) signs);
  print_endline ("expr_fixlist is " ^
    catmap ","
    (fun (e,d) -> string_of_expr e ^ " [depth " ^si d^"]")
    rs.expr_fixlist
  );
  *)
  let bt sr t =
    (*
    print_endline "NON PROPAGATING BIND TYPE";
    *)
    inner_bind_type state bsym_table env sr rs t
  in
  let handle_nonfunction_index index ts =
    print_endline ("Found non function? index " ^ string_of_bid index);
    begin match get_data state.sym_table index with
    { Flx_sym.id=id; sr=sr; parent=parent; vs=vs; dirs=dirs; symdef=entry } ->
      begin match entry with
      | SYMDEF_inherit_fun qn ->
          clierr sr "Chasing functional inherit in lookup_qn_with_sig'";

      | SYMDEF_inherit qn ->
          clierr sr "Chasing inherit in lookup_qn_with_sig'";

      | SYMDEF_cstruct _
      | SYMDEF_struct _ ->
        let sign = try List.hd signs with _ -> assert false in
        let t = type_of_index_with_ts' state bsym_table rs sr index ts in
        (*
        print_endline ("[lookup_type_qn_with_sig] Struct constructor found, type= " ^ sbt bsym_table t);
        *)
        begin match t with
        | BTYP_function (a,_) ->
          if not (type_match state.syms.counter a sign) then
            clierr sr
            (
              "[lookup_qn_with_sig] Struct constructor for "^id^" has wrong signature, got:\n" ^
              sbt bsym_table t ^
              "\nexpected:\n" ^
              sbt bsym_table sign
            )
        | _ -> assert false
        end
        ;
        t

      | SYMDEF_union _
      | SYMDEF_type_alias _ ->
        print_endline "mapping type name to _ctor_type [2]";
        let qn =  match qn with
          | `AST_name (sr,name,ts) -> `AST_name (sr,"_ctor_"^name,ts)
          | `AST_lookup (sr,(e,name,ts)) -> `AST_lookup (sr,(e,"_ctor_"^name,ts))
          | _ -> failwith "Unexpected name kind .."
        in
        lookup_type_qn_with_sig' state bsym_table sra srn env rs qn signs

      | SYMDEF_const (_,t,_,_)
      | SYMDEF_val t
      | SYMDEF_var t
      | SYMDEF_ref t
      | SYMDEF_parameter (_,t)
        ->
        clierr sr (id ^ ": lookup_type_qn_with_sig: val/var/const/ref/param: not type");

      | _ ->
        clierr sr
        (
          "[lookup_type_qn_with_sig] Named Non function entry "^id^
          " must be type function"
        )
      end
    end
  in
  match qn with
  | `AST_callback (sr,qn) ->
    failwith "[lookup_qn_with_sig] Callbacks not implemented yet"

  | `AST_the (sr,qn) ->
    print_endline ("AST_the " ^ string_of_qualified_name qn);
    lookup_type_qn_with_sig' state bsym_table sra srn
    env rs
    qn signs

  | `AST_void _ -> clierr sra "qualified-name is void"

  | `AST_case_tag _ -> clierr sra "Can't lookup case tag here"

  | `AST_typed_case (sr,v,t) ->
    let t = bt sr t in
    begin match unfold t with
    | BTYP_unitsum k ->
      if v<0 or v>= k
      then clierr sra "Case index out of range of sum"
      else
        let ct = BTYP_function (unit_t,t) in
        ct

    | BTYP_sum ls ->
      if v<0 or v >= List.length ls
      then clierr sra "Case index out of range of sum"
      else let vt = List.nth ls v in
      let ct = BTYP_function (vt,t) in
      ct

    | _ ->
      clierr sr
      (
        "[lookup_qn_with_sig] Type of case must be sum, got " ^
        sbt bsym_table t
      )
    end

  | `AST_name (sr,name,ts) ->
    (*
    print_endline ("AST_name " ^ name);
    *)
    let ts = List.map (bt sr) ts in
    lookup_type_name_with_sig
      state
      bsym_table
      sra srn
      env env rs name ts signs

  | `AST_index (sr,name,index) as x ->
    (*
    print_endline ("[lookup qn with sig] AST_index " ^ string_of_qualified_name x);
    *)
    begin match get_data state.sym_table index with
    | { Flx_sym.vs=vs; id=id; sr=sra; symdef=entry } ->
    match entry with
    | SYMDEF_fun _
    | SYMDEF_function _
    | SYMDEF_match_check _
      ->
      let vs = find_vs state.sym_table index in
      let ts = List.map (fun (_,i,_) -> BTYP_var (i,BTYP_type 0)) (fst vs) in
      inner_type_of_index state bsym_table rs index

    | _ ->
      (*
      print_endline "Non function ..";
      *)
      let ts = List.map (fun (_,i,_) -> BTYP_var (i,BTYP_type 0)) (fst vs) in
      handle_nonfunction_index index ts
    end

  | `AST_lookup (sr,(qn',name,ts)) ->
    let m =  eval_module_expr state bsym_table env qn' in
    match m with (Simple_module (impl, ts',htab,dirs)) ->
    (* let n = List.length ts in *)
    let ts = List.map (bt sr)( ts' @ ts) in
    (*
    print_endline ("Module " ^ si impl ^ "[" ^ catmap "," (sbt bsym_table) ts' ^"]");
    *)
    let env' = mk_bare_env state bsym_table impl in
    let tables = get_pub_tables state bsym_table env' rs dirs in
    let result = lookup_name_in_table_dirs htab tables sr name in
    begin match result with
    | None ->
      clierr sr
      (
        "[lookup_qn_with_sig] AST_lookup: Simple_module: Can't find name " ^ name
      )
    | Some entries -> match entries with
    | NonFunctionEntry (index) ->
      handle_nonfunction_index (sye index) ts

    | FunctionEntry fs ->
      match
        resolve_overload'
        state bsym_table env rs sra fs name signs ts
      with
      | Some (index,t,ret,mgu,ts) ->
        print_endline ("Resolved overload for " ^ name);
        print_endline ("ts = [" ^ catmap ", " (sbt bsym_table) ts ^ "]");
        (*
        let ts = adjust_ts state.sym_table sr index ts in
        *)
        let t = type_of_index_with_ts' state bsym_table rs sr index ts in
        print_endline "WRONG!";
        t

      | None ->
        clierr sra
        (
          "[lookup_type_qn_with_sig] (Simple module) Unable to resolve overload of " ^
          string_of_qualified_name qn ^
          " of (" ^ catmap "," (sbt bsym_table) signs ^")\n" ^
          "candidates are: " ^ full_string_of_entry_set bsym_table entries
        )
    end

and lookup_name_with_sig
  state
  bsym_table
  sra srn
  caller_env env
  (rs:recstop)
  (name : string)
  (ts : btypecode_t list)
  (t2:btypecode_t list)
: tbexpr_t =
  (*
  print_endline ("[lookup_name_with_sig] " ^ name ^
    " of " ^ catmap "," (sbt bsym_table) t2)
  ;
  *)
  match env with
  | [] ->
    clierr srn
    (
      "[lookup_name_with_sig] Can't find " ^ name ^
      " of " ^ catmap "," (sbt bsym_table) t2
    )
  | (_,_,table,dirs,_)::tail ->
    match
      lookup_name_in_table_dirs_with_sig
      state
      bsym_table
      table
      dirs
      caller_env env rs
      sra srn name ts t2
    with
    | Some result -> (result:>tbexpr_t)
    | None ->
      let tbx=
        lookup_name_with_sig
          state
          bsym_table
          sra srn
          caller_env tail rs name ts t2
       in (tbx:>tbexpr_t)

and lookup_type_name_with_sig
  state
  bsym_table
  sra srn
  caller_env env
  (rs:recstop)
  (name : string)
  (ts : btypecode_t list)
  (t2:btypecode_t list)
: btypecode_t =
  (*
  print_endline ("[lookup_type_name_with_sig] " ^ name ^
    " of " ^ catmap "," (sbt bsym_table) t2)
  ;
  *)
  match env with
  | [] ->
    clierr srn
    (
      "[lookup_name_with_sig] Can't find " ^ name ^
      " of " ^ catmap "," (sbt bsym_table) t2
    )
  | (_,_,table,dirs,_)::tail ->
    match
      lookup_type_name_in_table_dirs_with_sig
      state
      bsym_table
      table
      dirs
      caller_env env rs
      sra srn name ts t2
    with
    | Some result -> result
    | None ->
      let tbx=
        lookup_type_name_with_sig
          state
          bsym_table
          sra srn
          caller_env tail rs name ts t2
       in tbx

and handle_type
  state
  bsym_table
  (rs:recstop)
  sra srn
  name
  ts
  index
: btypecode_t
=

  let mkenv i = build_env state bsym_table (Some i) in
  let bt sr t =
    bind_type' state bsym_table (mkenv index) rs sr t [] mkenv
  in

  match get_data state.sym_table index with
  {
    Flx_sym.id=id;
    sr=sr;
    vs=vs;
    parent=parent;
    dirs=dirs;
    symdef=entry
  }
  ->
  match entry with
  | SYMDEF_match_check _
  | SYMDEF_function _
  | SYMDEF_fun _
  | SYMDEF_struct _
  | SYMDEF_cstruct _
  | SYMDEF_nonconst_ctor _
  | SYMDEF_callback _
    ->
    print_endline ("Handle function " ^ id ^ "<" ^ string_of_bid index ^
      ">, ts=" ^ catmap "," (sbt bsym_table) ts);
    BTYP_inst (index,ts)
    (*
    let t = inner_type_of_index_with_ts state sr rs index ts
    in
    (
      match t with
      | BTYP_cfunction (s,d) as t -> t
      | BTYP_function (s,d) as t -> t
      | t ->
        ignore begin
          match t with
          | BTYP_fix _ -> raise (Free_fixpoint t)
          | _ -> try unfold t with
          | _ -> raise (Free_fixpoint t)
        end
        ;
        clierr sra
        (
          "[handle_function]: closure operator expected '"^name^"' to have function type, got '"^
          sbt bsym_table t ^ "'"
        )
    )
    *)

  | SYMDEF_type_alias _ ->
    (*
    print_endline ("Binding type alias " ^ name ^ "<" ^
      string_of_bid index ^ ">" ^
      "[" ^catmap "," (sbt bsym_table) ts^ "]"
    );
    *)
    bind_type_index state bsym_table (rs:recstop) sr index ts mkenv

  | _ ->
    clierr sra
    (
      "[handle_type] Expected "^name^" to be function, got: " ^
      string_of_symdef entry name vs
    )

and handle_function
  state
  bsym_table
  (rs:recstop)
  sra srn
  name
  ts
  index
: tbexpr_t
=
  match get_data state.sym_table index with
  {
    Flx_sym.id=id;
    sr=sr;
    vs=vs;
    parent=parent;
    dirs=dirs;
    symdef=entry
  }
  ->
  match entry with
  | SYMDEF_match_check _
  | SYMDEF_function _
  | SYMDEF_fun _
  | SYMDEF_struct _
  | SYMDEF_cstruct _
  | SYMDEF_nonconst_ctor _
  | SYMDEF_callback _
    ->
    (*
    print_endline ("Handle function " ^id^"<"^string_of_bid index^">, ts=" ^ catmap "," (sbt bsym_table) ts);
    *)
    let t = inner_type_of_index_with_ts state bsym_table sr rs index ts
    in
    BEXPR_closure (index,ts),
    (
      match t with
      | BTYP_cfunction (s,d) as t -> t
      | BTYP_function (s,d) as t -> t
      | t ->
        ignore begin
          match t with
          | BTYP_fix _ -> raise (Free_fixpoint t)
          | _ -> try unfold t with
          | _ -> raise (Free_fixpoint t)
        end
        ;
        clierr sra
        (
          "[handle_function]: closure operator expected '"^name^"' to have function type, got '"^
          sbt bsym_table t ^ "'"
        )
    )
  | SYMDEF_type_alias (TYP_typefun _) ->
    (* THIS IS A HACK .. WE KNOW THE TYPE IS NOT NEEDED BY THE CALLER .. *)
    (* let t = inner_type_of_index_with_ts state sr rs index ts in *)
    let t = BTYP_function (BTYP_type 0,BTYP_type 0) in
    BEXPR_closure (index,ts),
    (
      match t with
      | BTYP_function (s,d) as t -> t
      | t ->
        ignore begin
          match t with
          | BTYP_fix _ -> raise (Free_fixpoint t)
          | _ -> try unfold t with
          | _ -> raise (Free_fixpoint t)
        end
        ;
        clierr sra
        (
          "[handle_function]: closure operator expected '"^name^"' to have function type, got '"^
          sbt bsym_table t ^ "'"
        )
    )

  | _ ->
    clierr sra
    (
      "[handle_function] Expected "^name^" to be function, got: " ^
      string_of_symdef entry name vs
    )

and handle_variable state bsym_table
  env (rs:recstop)
  index id sr ts t t2
=
  (* HACKED the params argument to [] .. this is WRONG!! *)
  let mkenv i = build_env state bsym_table (Some i) in
  let bt sr t =
    bind_type' state bsym_table env rs sr t [] mkenv
  in

    (* we have to check the variable is the right type *)
    let t = bt sr t in
    let ts = adjust_ts state.sym_table bsym_table sr index ts in
    let vs = find_vs state.sym_table index in
    let bvs = List.map (fun (s,i,tp) -> s,i) (fst vs) in
    let t = beta_reduce state.syms bsym_table sr (tsubst bvs ts t) in
    begin match t with
    | BTYP_cfunction (d,c)
    | BTYP_function (d,c) ->
      if not (type_match state.syms.counter d t2) then
      clierr sr
      (
        "[handle_variable(1)] Expected variable "^id ^
        "<" ^ string_of_bid index ^ "> to have function type with signature " ^
        sbt bsym_table t2 ^
        ", got function type:\n" ^
        sbt bsym_table t
      )
      else
        (*
        let ts = adjust_ts state.sym_table sr index ts in
        *)
        Some
        (
          BEXPR_name (index, ts),t
          (* should equal t ..
          type_of_index_with_ts state sr index ts
          *)
        )

    (* anything other than function type, dont check the sig,
       just return it..
    *)
    | _ ->  Some (BEXPR_name (index,ts),t)
    end

and lookup_name_in_table_dirs_with_sig
  state
  bsym_table
  table
  dirs
  caller_env env (rs:recstop)
  sra srn name (ts:btypecode_t list) (t2: btypecode_t list)
: tbexpr_t option
=
  (*
  print_endline
  (
    "LOOKUP NAME "^name ^"["^
    catmap "," (sbt bsym_table) ts ^
    "] IN TABLE DIRS WITH SIG " ^ catmap "," (sbt bsym_table) t2
  );
  *)
  let result:entry_set_t =
    match lookup_name_in_htab table name  with
    | Some x -> x
    | None -> FunctionEntry []
  in
  match result with
  | NonFunctionEntry (index) ->
    begin match get_data state.sym_table (sye index) with
    { Flx_sym.id=id; sr=sr; parent=parent; vs=vs; symdef=entry }->
    (*
    print_endline ("FOUND " ^ id);
    *)
    begin match entry with
    | SYMDEF_inherit _ ->
      clierr sra "Woops found inherit in lookup_name_in_table_dirs_with_sig"
    | SYMDEF_inherit_fun _ ->
      clierr sra "Woops found inherit function in lookup_name_in_table_dirs_with_sig"

    | (SYMDEF_cstruct _ | SYMDEF_struct _ )
      when
        (match t2 with
        | [BTYP_record _] -> true
        | _ -> false
        )
      ->
        (*
        print_endline ("lookup_name_in_table_dirs_with_sig finds struct constructor " ^ id);
        print_endline ("Record Argument type is " ^ catmap "," (sbt bsym_table) t2);
        *)
        Some (BEXPR_closure (sye index,ts),BTYP_inst (sye index,ts))
        (*
        failwith "NOT IMPLEMENTED YET"
        *)

    | SYMDEF_struct _
    | SYMDEF_cstruct _
    | SYMDEF_nonconst_ctor _
      ->
        (*
        print_endline ("lookup_name_in_table_dirs_with_sig finds struct constructor " ^ id);
        print_endline ("Argument types are " ^ catmap "," (sbt bsym_table) t2);
        *)
        let ro =
          resolve_overload'
          state bsym_table caller_env rs sra [index] name t2 ts
        in
          begin match ro with
          | Some (index,t,ret,mgu,ts) ->
            (*
            print_endline "handle_function (1)";
            *)
            let tb : tbexpr_t =
              handle_function
              state
              bsym_table
              rs
              sra srn name ts index
            in
              Some tb
          | None -> None
          end
    | SYMDEF_abs _
    | SYMDEF_union _
    | SYMDEF_type_alias _ ->

      (* recursively lookup using "_ctor_" ^ name :
         WARNING: we might find a constructor with the
         right name for a different cclass than this one,
         it isn't clear this is wrong though.
      *)
      (*
      print_endline "mapping type name to _ctor_type";
      *)
      lookup_name_in_table_dirs_with_sig
        state
        bsym_table
        table
        dirs
        caller_env env rs sra srn ("_ctor_" ^ name) ts t2

    | SYMDEF_const_ctor (_,t,_,_)
    | SYMDEF_const (_,t,_,_)
    | SYMDEF_var t
    | SYMDEF_ref t
    | SYMDEF_val t
    | SYMDEF_parameter (_,t)
      ->
      let sign = try List.hd t2 with _ -> assert false in
      handle_variable state bsym_table env rs (sye index) id srn ts t sign
    | _
      ->
        clierr sra
        (
          "[lookup_name_in_table_dirs_with_sig] Expected " ^id^
          " to be struct or variable of function type, got " ^
          string_of_symdef entry id vs
        )
    end
    end

  | FunctionEntry fs ->
    (*
    print_endline ("Found function set size " ^ si (List.length fs));
    *)
    let ro =
      resolve_overload'
      state bsym_table caller_env rs sra fs name t2 ts
    in
    match ro with
      | Some (index,t,ret,mgu,ts) ->
        (*
        print_endline ("handle_function (3) ts=" ^ catmap "," (sbt bsym_table) ts);
        let ts = adjust_ts state.sym_table sra index ts in
        print_endline "Adjusted ts";
        *)
        let ((_,tt) as tb) =
          handle_function
          state
          bsym_table
          rs
          sra srn name ts index
        in
          (*
          print_endline ("SUCCESS: overload chooses " ^ full_string_of_entry_kind state.sym_table (mkentry state dfltvs index));
          print_endline ("Value of ts is " ^ catmap "," (sbt bsym_table) ts);
          print_endline ("Instantiated closure value is " ^ sbe bsym_table tb);
          print_endline ("type is " ^ sbt bsym_table tt);
          *)
          Some tb

      | None ->
        (*
        print_endline "Can't overload: Trying opens";
        *)
        let opens : entry_set_t list =
          uniq_cat []
          (
            List.concat
            (
              List.map
              (fun table ->
                match lookup_name_in_htab table name with
                | Some x -> [x]
                | None -> []
              )
              dirs
            )
          )
        in
        (*
        print_endline (si (List.length opens) ^ " OPENS BUILT for " ^ name);
        *)
        match opens with
        | [NonFunctionEntry i] when
          (
            match get_data state.sym_table (sye i) with
            { Flx_sym.id=id; sr=sr; parent=parent; vs=vs; symdef=entry }->
            (*
            print_endline ("FOUND " ^ id);
            *)
            match entry with
            | SYMDEF_abs _
            | SYMDEF_union _ -> true
            | _ -> false
           ) ->
            (*
            print_endline "mapping type name to _ctor_type2";
            *)
            lookup_name_in_table_dirs_with_sig
              state
              bsym_table
              table
              dirs
              caller_env env rs sra srn ("_ctor_" ^ name) ts t2
        | _ ->
        let fs =
          match opens with
          | [NonFunctionEntry i] -> [i]
          | [FunctionEntry ii] -> ii
          | _ ->
            merge_functions opens name
        in
          let ro =
            resolve_overload'
            state bsym_table caller_env rs sra fs name t2 ts
          in
          (*
          print_endline "OVERLOAD RESOLVED .. ";
          *)
          match ro with
          | Some (result,t,ret,mgu,ts) ->
            (*
            print_endline "handle_function (4)";
            *)
            let tb : tbexpr_t =
              handle_function
              state
              bsym_table
              rs
              sra srn name ts result
            in
              Some tb
          | None ->
            (*
            print_endline "FAILURE"; flush stdout;
            *)
            None

and lookup_type_name_in_table_dirs_with_sig
  state
  bsym_table
  table
  dirs
  caller_env env (rs:recstop)
  sra srn name (ts:btypecode_t list) (t2: btypecode_t list)
: btypecode_t option
=
  (*
  print_endline
  (
    "LOOKUP TYPE NAME "^name ^"["^
    catmap "," (sbt bsym_table) ts ^
    "] IN TABLE DIRS WITH SIG " ^ catmap "," (sbt bsym_table) t2
  );
  *)
  let mkenv i = build_env state bsym_table (Some i) in
  let bt sr t =
    bind_type' state bsym_table env rs sr t [] mkenv
  in

  let result:entry_set_t =
    match lookup_name_in_htab table name  with
    | Some x -> x
    | None -> FunctionEntry []
  in
  match result with
  | NonFunctionEntry (index) ->
    begin match get_data state.sym_table (sye index) with
    { Flx_sym.id=id; sr=sr; parent=parent; vs=vs; symdef=entry }->
    (*
    print_endline ("FOUND " ^ id);
    *)
    begin match entry with
    | SYMDEF_inherit _ ->
      clierr sra "Woops found inherit in lookup_type_name_in_table_dirs_with_sig"
    | SYMDEF_inherit_fun _ ->
      clierr sra "Woops found inherit function in lookup_type_name_in_table_dirs_with_sig"

    | SYMDEF_struct _
    | SYMDEF_cstruct _
    | SYMDEF_nonconst_ctor _
      ->
        (*
        print_endline "lookup_name_in_table_dirs_with_sig finds struct constructor";
        *)
        let ro =
          resolve_overload'
          state bsym_table caller_env rs sra [index] name t2 ts
        in
          begin match ro with
          | Some (index,t,ret,mgu,ts) ->
            (*
            print_endline "handle_function (1)";
            *)
            let tb : btypecode_t =
              handle_type
              state
              bsym_table
              rs
              sra srn name ts index
            in
              Some tb
          | None -> None
          end

    | SYMDEF_typevar mt ->
      let mt = bt sra mt in
      (* match function a -> b -> c -> d with sigs a b c *)
      let rec m f s = match f,s with
      | BTYP_function (d,c),h::t when d = h -> m c t
      | BTYP_typefun _,_ -> failwith "Can't handle actual lambda form yet"
      | _,[] -> true
      | _ -> false
      in
      if m mt t2
      then Some (BTYP_var (sye index,mt))
      else
      (print_endline
      (
        "Typevariable has wrong meta-type" ^
        "\nexpected domains " ^ catmap ", " (sbt bsym_table) t2 ^
        "\ngot " ^ sbt bsym_table mt
      ); None)

    | SYMDEF_abs _
    | SYMDEF_union _
    | SYMDEF_type_alias _ ->
      print_endline "Found abs,union or alias";
      Some (BTYP_inst (sye index, ts))


    | SYMDEF_const_ctor _
    | SYMDEF_const _
    | SYMDEF_var _
    | SYMDEF_ref _
    | SYMDEF_val _
    | SYMDEF_parameter _
    | SYMDEF_axiom _
    | SYMDEF_lemma _
    | SYMDEF_callback _
    | SYMDEF_fun _
    | SYMDEF_function _
    | SYMDEF_insert _
    | SYMDEF_instance _
    | SYMDEF_lazy _
    | SYMDEF_match_check _
    | SYMDEF_module
    | SYMDEF_newtype _
    | SYMDEF_reduce _
    | SYMDEF_typeclass
      ->
        clierr sra
        (
          "[lookup_type_name_in_table_dirs_with_sig] Expected " ^id^
          " to be a type or functor, got " ^
          string_of_symdef entry id vs
        )
    end
    end

  | FunctionEntry fs ->
    (*
    print_endline ("Found function set size " ^ si (List.length fs));
    *)
    let ro =
      resolve_overload'
      state bsym_table caller_env rs sra fs name t2 ts
    in
    match ro with
      | Some (index,t,ret,mgu,ts) ->
        (*
        print_endline ("handle_function (3) ts=" ^ catmap "," (sbt bsym_table) ts);
        let ts = adjust_ts state.sym_table sra index ts in
        print_endline "Adjusted ts";
        print_endline ("Found functional thingo, " ^ string_of_bid index);
        print_endline (" ts=" ^ catmap "," (sbt bsym_table) ts);
        *)

        let tb =
          handle_type
          state
          bsym_table
          rs
          sra srn name ts index
        in
          (*
          print_endline ("SUCCESS: overload chooses " ^ full_string_of_entry_kind state.sym_table (mkentry state dfltvs index));
          print_endline ("Value of ts is " ^ catmap "," (sbt bsym_table) ts);
          print_endline ("Instantiated type is " ^ sbt bsym_table tb);
          *)
          Some tb

      | None ->
        (*
        print_endline "Can't overload: Trying opens";
        *)
        let opens : entry_set_t list =
          List.concat
          (
            List.map
            (fun table ->
              match lookup_name_in_htab table name with
              | Some x -> [x]
              | None -> []
            )
            dirs
          )
        in
        (*
        print_endline (si (List.length opens) ^ " OPENS BUILT for " ^ name);
        *)
        match opens with
        | [NonFunctionEntry i] when
          (
              match get_data state.sym_table (sye i) with
              { Flx_sym.id=id; sr=sr; parent=parent; vs=vs; symdef=entry }->
              (*
              print_endline ("FOUND " ^ id);
              *)
              match entry with
              | SYMDEF_abs _
              | SYMDEF_union _ -> true
              | _ -> false
           ) ->
           Some (BTYP_inst (sye i, ts))

        | _ ->
        let fs =
          match opens with
          | [NonFunctionEntry i] -> [i]
          | [FunctionEntry ii] -> ii
          | _ ->
            merge_functions opens name
        in
          let ro =
            resolve_overload'
            state bsym_table caller_env rs sra fs name t2 ts
          in
          (*
          print_endline "OVERLOAD RESOLVED .. ";
          *)
          match ro with
          | Some (result,t,ret,mgu,ts) ->
            (*
            print_endline "handle_function (4)";
            *)
            let tb : btypecode_t =
              handle_type
              state
              bsym_table
              rs
              sra srn name ts result
            in
              Some tb
          | None ->
            (*
            print_endline "FAILURE"; flush stdout;
            *)
            None

and handle_map sr (f,ft) (a,at) =
    let t =
      match ft with
      | BTYP_function (d,c) ->
        begin match at with
        | BTYP_inst (i,[t]) ->
          if t <> d
          then clierr sr
            ("map type of data structure index " ^
            "must agree with function domain")
          else
            BTYP_inst (i,[c])
        | _ -> clierr sr "map requires instance"
        end
      | _ -> clierr sr "map non-function"
    in
      (* actually this part is easy, it's just
      applies ((map[i] f) a) where map[i] denotes
      the map function generated for data structure i
      *)
      failwith "MAP NOT IMPLEMENTED"

and bind_expression_with_args state bsym_table env e args : tbexpr_t =
  bind_expression' state bsym_table env rsground e args

and bind_expression' state bsym_table env (rs:recstop) e args : tbexpr_t =
  let sr = src_of_expr e in
  (*
  print_endline ("[bind_expression'] " ^ string_of_expr e);
  print_endline ("expr_fixlist is " ^
    catmap ","
    (fun (e,d) -> string_of_expr e ^ " [depth " ^si d^"]")
    rs.expr_fixlist
  );
  *)
  if List.mem_assq e rs.expr_fixlist
  then raise (Expr_recursion e)
  ;
  let rs = { rs with expr_fixlist=(e,rs.depth)::rs.expr_fixlist } in
  let be e' = bind_expression' state bsym_table env { rs with depth=rs.depth+1} e' [] in
  let mkenv i = build_env state bsym_table (Some i) in
  let bt sr t =
    (* we're really wanting to call bind type and propagate depth ? *)
    let t = bind_type' state bsym_table env { rs with depth=rs.depth +1 } sr t [] mkenv in
    let t = beta_reduce state.syms bsym_table sr t in
    t
  in
  let ti sr i ts =
    inner_type_of_index_with_ts state bsym_table sr
    { rs with depth = rs.depth + 1}
                               (* CHANGED THIS ------------------*******)
    i ts
  in

  (* model infix operator as function call *)
  let apl2 (sri:Flx_srcref.t) (fn : string) (tup:expr_t list) =
    let sr = rslist tup in
    EXPR_apply
    (
      sr,
      (
        EXPR_name (sri,fn,[]),
        EXPR_tuple (sr,tup)
      )
    )
  in
  (*
  print_endline ("Binding expression " ^ string_of_expr e ^ " depth=" ^ string_of_int depth);
  print_endline ("environment is:");
  print_env env;
  print_endline "==";
  *)
  let rt t = Flx_maps.reduce_type (beta_reduce state.syms bsym_table sr t) in
  let sr = src_of_expr e in
  let cal_method_apply sra fn e2 meth_ts =
    (*
    print_endline ("METHOD APPLY: " ^ string_of_expr e);
    *)
    (* .. PRAPS .. *)
    let meth_ts = List.map (bt sra) meth_ts in
    let (be2,t2) as x2 = be e2 in
    begin match t2 with
    | BTYP_record es ->
      let rcmp (s1,_) (s2,_) = compare s1 s2 in
      let es = List.sort rcmp es in
      let field_name = String.sub fn 4 (String.length fn -4) in
      begin match list_index (List.map fst es) field_name with
      | Some n -> BEXPR_get_n (n,x2),List.assoc field_name es
      | None -> clierr sr
         (
           "Field " ^ field_name ^
           " is not a member of anonymous structure " ^
           sbt bsym_table t2
          )
      end
    | _ ->
    let tbe1 =
      match t2 with
      | BTYP_inst (index,ts) ->
        begin match get_data state.sym_table index with
        { Flx_sym.id=id; parent=parent;sr=sr;symdef=entry} ->
        match parent with
        | None -> clierr sra "Koenig lookup: No parent for method apply (can't handle global yet)"
        | Some index' ->
            let sym = get_data state.sym_table index' in
            match sym.Flx_sym.symdef with
            | SYMDEF_module
            | SYMDEF_function _ ->
                koenig_lookup
                  state
                  bsym_table
                  env
                  rs
                  sra
                  sym.Flx_sym.id
                  sym.Flx_sym.pubmap
                  fn
                  t2
                  (ts @ meth_ts)
            | _ -> clierr sra ("Koenig lookup: parent for method apply not module")
        end

      | _ -> clierr sra ("apply method "^fn^" to nongenerative type")
    in
      cal_apply state bsym_table sra rs tbe1 (be2, t2)
    end
  in  
  match e with
  | EXPR_patvar _
  | EXPR_patany _
  | EXPR_vsprintf _
  | EXPR_type_match _
  | EXPR_noexpand _
  | EXPR_letin _
  | EXPR_cond _
  | EXPR_typeof _
  | EXPR_as _
  | EXPR_void _
  | EXPR_arrow _
  | EXPR_longarrow _
  | EXPR_superscript _
  | EXPR_ellipsis _
  | EXPR_setunion _
  | EXPR_setintersection _
  | EXPR_intersect _
  | EXPR_isin _
  | EXPR_macro_ctor _
  | EXPR_macro_statements  _
  | EXPR_user_expr _
    ->
      clierr sr
     ("[bind_expression] Expected expression, got " ^ string_of_expr e)

  | EXPR_apply (sr,(EXPR_name (_,"_tuple_flatten",[]),e)) ->
    let result = ref [] in
    let stack = ref [] in
    let push () = stack := 0 :: !stack in
    let pop () = stack := List.tl (!stack) in
    let inc () =
      match !stack with
      | [] -> ()
      | _ -> stack := List.hd (!stack) + 1 :: List.tl (!stack)
    in
    let rec term stack = match stack with
      | [] -> e
      | _ -> EXPR_get_n (sr, (List.hd stack, term (List.tl stack)))
    in
    let _,t = be e in
    let rec aux t = match t with
    | BTYP_tuple ls ->
      push (); List.iter aux ls; pop(); inc ()

    | BTYP_array (t,BTYP_unitsum n) when n < 20 ->
      push(); for i = 0 to n-1 do aux t done; pop(); inc();

    | _ ->
      result := term (!stack) :: !result;
      inc ()
    in
    aux t;
    let e = EXPR_tuple (sr,List.rev (!result)) in
    be e

  | EXPR_apply (sr,(EXPR_name (_,"_tuple_trans",[]),e)) ->
    let tr nrows ncolumns =
      let e' = ref [] in
      for i = nrows - 1 downto 0 do
        let x = ref [] in
        for j = ncolumns - 1 downto 0 do
          let v = EXPR_get_n (sr,(i,EXPR_get_n (sr,(j,e)))) in
          x := v :: !x;
        done;
        e' := EXPR_tuple (sr,!x) :: (!e');
      done
      ;
      be (EXPR_tuple (sr,!e'))
    in
    let calnrows t =
      let nrows =
        match t with
        | BTYP_tuple ls -> List.length ls
        | BTYP_array (_,BTYP_unitsum n) -> n
        | _ -> clierrn [sr] "Tuple transpose requires entry to be tuple"
      in
      if nrows < 2 then
        clierr sr "Tuple transpose requires tuple argument with 2 or more elements"
      ;
      nrows
    in
    let colchk nrows t =
      match t with
      | BTYP_tuple ls ->
        if List.length ls != nrows then
          clierr sr ("Tuple transpose requires entry to be tuple of length " ^ si nrows)

      | BTYP_array (_,BTYP_unitsum n) ->
        if n != nrows then
          clierr sr ("Tuple transpose requires entry to be tuple of length " ^ si nrows)

      | _ -> clierr sr "Tuple transpose requires entry to be tuple"
    in
    let _,t = be e in
    let ncolumns, nrows =
      match t with
      | BTYP_tuple ls ->
        let ncolumns  = List.length ls in
        let nrows = calnrows (List.hd ls) in
        List.iter (colchk nrows) ls;
        ncolumns, nrows

      | BTYP_array (t,BTYP_unitsum ncolumns) ->
        let nrows = calnrows t in
        ncolumns, nrows

      | _ -> clierr sr "Tuple transpose requires tuple argument"
    in
      if nrows > 20 then
        clierr sr ("tuple fold: row bound " ^ si nrows ^ ">20, to large")
      ;
      if ncolumns> 20 then
        clierr sr ("tuple fold: column bound " ^ si ncolumns^ ">20, to large")
      ;
      tr nrows ncolumns

  | EXPR_apply
    (
      sr,
      (
        EXPR_apply
        (
          _,
          (
            EXPR_apply ( _, ( EXPR_name(_,"_tuple_fold",[]), f)),
            i
          )
        ),
        c
      )
    ) ->


    let _,t = be c in
    let calfold n =
      let rec aux m result =
        if m = 0 then result else
        let  k = n-m in
        let arg = EXPR_get_n (sr,(k,c)) in
        let arg = EXPR_tuple (sr,[result; arg]) in
        aux (m-1) (EXPR_apply(sr,(f,arg)))
      in be (aux n i)
    in
    begin match t with
    | BTYP_tuple ts  -> calfold (List.length ts)
    | BTYP_array (_,BTYP_unitsum n) ->
       if  n<20 then calfold n
       else
         clierr sr ("Tuple fold array length " ^ si n ^ " too big, limit 20")

    | _ -> clierr sr "Tuple fold requires tuple argument"
    end


  | EXPR_callback (sr,qn) ->
    let es,ts = lookup_qn_in_env2' state bsym_table env rs qn in
    begin match es with
    | FunctionEntry [index] ->
       print_endline "Callback closure ..";
       let ts = List.map (bt sr) ts in
       BEXPR_closure (sye index, ts),
       ti sr (sye index) ts
    | NonFunctionEntry  _
    | _ -> clierr sr
      "'callback' expression denotes non-singleton function set"
    end

  | EXPR_expr (sr,s,t) ->
    let t = bt sr t in
    BEXPR_expr (s,t),t

  | EXPR_andlist (sri,ls) ->
    begin let mksum a b = apl2 sri "land" [a;b] in
    match ls with
    | h::t -> be (List.fold_left mksum h t)
    | [] -> clierr sri "Not expecting empty and list"
    end

  | EXPR_orlist (sri,ls) ->
    begin let mksum a b = apl2 sri "lor" [a;b] in
    match ls with
    | h::t -> be (List.fold_left mksum h t)
    | [] -> clierr sri "Not expecting empty or list"
    end

  | EXPR_sum (sri,ls) ->
    begin let mksum a b = apl2 sri "add" [a;b] in
    match ls with
    | h::t -> be (List.fold_left mksum h t)
    | [] -> clierr sri "Not expecting empty product (unit)"
    end

  | EXPR_product (sri,ls) ->
    begin let mkprod a b = apl2 sri "mul" [a;b] in
    match ls with
    | h::t -> be (List.fold_left mkprod h t)
    | [] -> clierr sri "Not expecting empty sum (void)"
    end

  | EXPR_coercion (sr,(x,t)) ->
    let (e',t') as x' = be x in
    let t'' = bt sr t in
    if type_eq state.syms.counter t' t'' then x'
    else
    let t' = Flx_maps.reduce_type t' in (* src *)
    let t'' = Flx_maps.reduce_type t'' in (* dst *)
    begin match t',t'' with
    | BTYP_inst (i,[]),BTYP_unitsum n ->
      begin match hfind "lookup" state.sym_table i with
      | { Flx_sym.id="int"; symdef=SYMDEF_abs (_, CS_str_template "int", _) }  ->
        begin match e' with
        | BEXPR_literal (AST_int (kind,big)) ->
          let m =
            try Big_int.int_of_big_int big
            with _ -> clierr sr "Integer is too large for unitsum"
          in
          if m >=0 && m < n then
            BEXPR_case (m,t''),t''
          else
            clierr sr "Integer is out of range for unitsum"
        | _ ->
          let inttype = t' in
          let zero = BEXPR_literal (AST_int ("int",Big_int.zero_big_int)),t' in
          let xn = BEXPR_literal (AST_int ("int",Big_int.big_int_of_int n)),t' in
          BEXPR_range_check (zero,x',xn),BTYP_unitsum n

        end
      | _ ->
        clierr sr ("Attempt to to coerce type:\n"^
        sbt bsym_table t'
        ^"to unitsum " ^ si n)
      end

    | BTYP_record ls',BTYP_record ls'' ->
      begin
      try
      BEXPR_record
      (
        List.map
        (fun (s,t)->
          match list_assoc_index ls' s with
          | Some j ->
            let tt = List.assoc s ls' in
            if type_eq state.syms.counter t tt then
              s,(BEXPR_get_n (j,x'),t)
            else clierr sr (
              "Source Record field '" ^ s ^ "' has type:\n" ^
              sbt bsym_table tt ^ "\n" ^
              "but coercion target has the different type:\n" ^
              sbt bsym_table t ^"\n" ^
              "The types must be the same!"
            )
          | None -> raise Not_found
        )
        ls''
      ),
      t''
      with Not_found ->
        clierr sr
         (
         "Record coercion dst requires subset of fields of src:\n" ^
         sbe bsym_table x' ^ " has type " ^ sbt bsym_table t' ^
        "\nwhereas annotation requires " ^ sbt bsym_table t''
        )
      end

    | BTYP_variant lhs,BTYP_variant rhs ->
      begin
      try
        List.iter
        (fun (s,t)->
          match list_assoc_index rhs s with
          | Some j ->
            let tt = List.assoc s rhs in
            if not (type_eq state.syms.counter t tt) then
            clierr sr (
              "Source Variant field '" ^ s ^ "' has type:\n" ^
              sbt bsym_table t ^ "\n" ^
              "but coercion target has the different type:\n" ^
              sbt bsym_table tt ^"\n" ^
              "The types must be the same!"
            )
          | None -> raise Not_found
        )
        lhs
        ;
        print_endline ("Coercion of variant to type " ^ sbt bsym_table t'');
        BEXPR_coerce (x',t''),t''
      with Not_found ->
        clierr sr
         (
         "Variant coercion src requires subset of fields of dst:\n" ^
         sbe bsym_table x' ^ " has type " ^ sbt bsym_table t' ^
        "\nwhereas annotation requires " ^ sbt bsym_table t''
        )
      end
    | _ ->
      clierr sr
      (
        "Wrong type in coercion:\n" ^
        sbe bsym_table x' ^ " has type " ^ sbt bsym_table t' ^
        "\nwhereas annotation requires " ^ sbt bsym_table t''
      )
    end

  | EXPR_get_n (sr,(n,e')) ->
    let expr,typ = be e' in
    let ctyp = match unfold typ with
    | BTYP_array (t,BTYP_unitsum len)  ->
      if n<0 or n>len-1
      then clierr sr
        (
          "[bind_expression] Tuple index " ^
          string_of_int n ^
          " out of range 0.." ^
          string_of_int (len-1)
        )
      else t

    | BTYP_tuple ts
      ->
      let len = List.length ts in
      if n<0 or n>len-1
      then clierr sr
        (
          "[bind_expression] Tuple index " ^
          string_of_int n ^
          " out of range 0.." ^
          string_of_int (len-1)
        )
      else List.nth ts n
    | _ ->
      clierr sr
      (
        "[bind_expression] Expected tuple " ^
        string_of_expr e' ^
        " to have tuple type, got " ^
        sbt bsym_table typ
      )
    in
      BEXPR_get_n (n, (expr,typ)), ctyp

  | EXPR_get_named_variable (sr,(name,e')) ->
    let e'',t'' as x2 = be e' in
    begin match t'' with
    | BTYP_record es
      ->
      let rcmp (s1,_) (s2,_) = compare s1 s2 in
      let es = List.sort rcmp es in
      let field_name = name in
      begin match list_index (List.map fst es) field_name with
      | Some n -> BEXPR_get_n (n,x2),List.assoc field_name es
      | None -> clierr sr
         (
           "Field " ^ field_name ^
           " is not a member of anonymous structure " ^
           sbt bsym_table t''
          )
      end

    | _ -> clierr sr ("[bind_expression] Projection requires record instance")
    end
  | EXPR_case_index (sr,e) ->
    let (e',t) as e  = be e in
    begin match t with
    | BTYP_unitsum _ -> ()
    | BTYP_sum _ -> ()
    | BTYP_variant _ -> ()
    | BTYP_inst (i,_) ->
      begin match hfind "lookup" state.sym_table i with
      | { Flx_sym.symdef=SYMDEF_union _} -> ()
      | { Flx_sym.id=id} -> clierr sr ("Argument of caseno must be sum or union type, got type " ^ id)
      end
    | _ -> clierr sr ("Argument of caseno must be sum or union type, got " ^ sbt bsym_table t)
    end
    ;
    let int_t = bt sr (TYP_name (sr,"int",[])) in
    begin match e' with
    | BEXPR_case (i,_) ->
      BEXPR_literal (AST_int ("int",Big_int.big_int_of_int i))
    | _ -> BEXPR_case_index e
    end
    ,
    int_t

  | EXPR_case_tag (sr,v) ->
     clierr sr "plain case tag not allowed in expression (only in pattern)"

  | EXPR_variant (sr,(s,e)) ->
    let (_,t) as e = be e in
    BEXPR_variant (s,e),BTYP_variant [s,t]

  | EXPR_typed_case (sr,v,t) ->
    let t = bt sr t in
    ignore (try unfold t with _ -> failwith "AST_typed_case unfold screwd");
    begin match unfold t with
    | BTYP_unitsum k ->
      if v<0 or v>= k
      then clierr sr "Case index out of range of sum"
      else
        BEXPR_case (v,t),t  (* const ctor *)

    | BTYP_sum ls ->
      if v<0 or v>= List.length ls
      then clierr sr "Case index out of range of sum"
      else let vt = List.nth ls v in
      let ct =
        match vt with
        | BTYP_tuple [] -> t        (* const ctor *)
        | _ -> BTYP_function (vt,t) (* non-const ctor *)
      in
      BEXPR_case (v,t), ct
    | _ ->
      clierr sr
      (
        "[bind_expression] Type of case must be sum, got " ^
        sbt bsym_table t
      )
    end

  | EXPR_name (sr,name,ts) ->
    (*
    print_endline ("BINDING NAME " ^ name);
    *)
    if name = "_felix_type_name" then
       let sname = catmap "," string_of_typecode ts in
       let x = EXPR_literal (sr, AST_string sname) in
       be x
    else
    let ts = List.map (bt sr) ts in
    begin match inner_lookup_name_in_env state bsym_table env rs sr name with
    | NonFunctionEntry {base_sym=index; spec_vs=spec_vs; sub_ts=sub_ts}
    ->
      (*
      let index = sye index in
      let ts = adjust_ts state.sym_table sr index ts in
      *)
      (*
      print_endline ("NAME lookup finds index " ^ string_of_bid index);
      print_endline ("spec_vs=" ^ catmap "," (fun (s,j)->s^"<"^si j^">") spec_vs);
      print_endline ("spec_ts=" ^ catmap "," (sbt bsym_table) sub_ts);
      print_endline ("input_ts=" ^ catmap "," (sbt bsym_table) ts);
      begin match hfind "lookup" state.sym_table index with
        | { Flx_sym.id=id;vs=vs;symdef=SYMDEF_typevar _} ->
          print_endline (id ^ " is a typevariable, vs=" ^
            catmap "," (fun (s,j,_)->s^"<"^si j^">") (fst vs)
          )
        | { Flx_sym.id=id} -> print_endline (id ^ " is not a type variable")
      end;
      *)
      (* should be a client error not an assertion *)
      if List.length spec_vs <> List.length ts then begin
        print_endline ("BINDING NAME " ^ name);
        begin match hfind "lookup" state.sym_table index with
          | { Flx_sym.id=id;vs=vs;symdef=SYMDEF_typevar _} ->
            print_endline (id ^ " is a typevariable, vs=" ^
              catmap ","
                (fun (s,j,_) -> s ^ "<" ^ string_of_bid j ^ ">")
                (fst vs)
            )
          | { Flx_sym.id=id} -> print_endline (id ^ " is not a type variable")
        end;
        print_endline ("NAME lookup finds index " ^ string_of_bid index);
        print_endline ("spec_vs=" ^
          catmap "," (fun (s,j) -> s ^ "<" ^ string_of_bid j ^ ">") spec_vs);
        print_endline ("spec_ts=" ^ catmap "," (sbt bsym_table) sub_ts);
        print_endline ("input_ts=" ^ catmap "," (sbt bsym_table) ts);
        clierr sr "[lookup,AST_name] ts/vs mismatch"
      end;

      let ts = List.map (tsubst spec_vs ts) sub_ts in
      let ts = adjust_ts state.sym_table bsym_table sr index ts in
      let t = ti sr index ts in
      begin match hfind "lookup:ref-check" state.sym_table index with
      |  { Flx_sym.symdef=SYMDEF_parameter (`PRef,_)}
      |  { Flx_sym.symdef=SYMDEF_ref _ } ->
          let t' = match t with BTYP_pointer t' -> t' | _ ->
            failwith ("[lookup, AST_name] expected ref "^name^" to have pointer type")
          in
          BEXPR_deref (BEXPR_name (index,ts),t),t'
      | _ -> BEXPR_name (index,ts), t
      end

    | FunctionEntry [{base_sym=index; spec_vs=spec_vs; sub_ts=sub_ts}]
    ->
      (* should be a client error not an assertion *)
      if List.length spec_vs <> List.length ts then begin
        print_endline ("BINDING NAME " ^ name);
        begin match hfind "lookup" state.sym_table index with
          | { Flx_sym.id=id;vs=vs;symdef=SYMDEF_typevar _} ->
            print_endline (id ^ " is a typevariable, vs=" ^
              catmap "," (fun (s,j,_) -> s ^ "<" ^ string_of_bid j ^ ">") (fst vs)
            )
          | { Flx_sym.id=id} -> print_endline (id ^ " is not a type variable")
        end;
        print_endline ("NAME lookup finds index " ^ string_of_bid index);
        print_endline ("spec_vs=" ^
          catmap "," (fun (s,j) -> s ^ "<" ^ string_of_bid j ^ ">") spec_vs);
        print_endline ("spec_ts=" ^ catmap "," (sbt bsym_table) sub_ts);
        print_endline ("input_ts=" ^ catmap "," (sbt bsym_table) ts);
        clierr sr "[lookup,AST_name] ts/vs mismatch"
      end;

      let ts = List.map (tsubst spec_vs ts) sub_ts in
      let ts = adjust_ts state.sym_table bsym_table sr index ts in
      let t = ti sr index ts in
      BEXPR_closure (index,ts), t


    | FunctionEntry fs ->
      assert (List.length fs > 0);
      begin match args with
      | [] ->
        clierr sr
        (
          "[bind_expression] Simple name " ^ name ^
          " binds to function set in\n" ^
          Flx_srcref.short_string_of_src sr
        )
      | args ->
        let sufs = List.map snd args in
        let ro = resolve_overload' state bsym_table env rs sr fs name sufs ts in
        begin match ro with
         | Some (index, dom,ret,mgu,ts) ->
           (*
           print_endline "OK, overload resolved!!";
           *)
           BEXPR_closure (index,ts),
            ti sr index ts

         | None -> clierr sr "Cannot resolve overload .."
        end
      end
    end

  | EXPR_index (_,name,index) as x ->
    (*
    print_endline ("[bind expression] AST_index " ^ string_of_qualified_name x);
    *)
    let ts = adjust_ts state.sym_table bsym_table sr index [] in
    (*
    print_endline ("ts=" ^ catmap "," (sbt bsym_table) ts);
    *)
    let t =
      try ti sr index ts
      with _ -> print_endline "type of index with ts failed"; raise Not_found
    in
    (*
    print_endline ("Type is " ^ sbt bsym_table t);
    *)
    begin match hfind "lookup" state.sym_table index with
    | { Flx_sym.symdef=SYMDEF_fun _ }
    | { Flx_sym.symdef=SYMDEF_function _ }
    ->
    (*
    print_endline ("Indexed name: Binding " ^ name ^ "<"^si index^">"^ " to closure");
    *)
      BEXPR_closure (index,ts),t
    | _ ->
    (*
    print_endline ("Indexed name: Binding " ^ name ^ "<"^si index^">"^ " to variable");
    *)
      BEXPR_name (index,ts),t
    end

  | EXPR_the(_,`AST_name (sr,name,ts)) ->
    (*
    print_endline ("[bind_expression] AST_the " ^ name);
    print_endline ("AST_name " ^ name ^ "[" ^ catmap "," string_of_typecode ts^ "]");
    *)
    let ts = List.map (bt sr) ts in
    begin match inner_lookup_name_in_env state bsym_table env rs sr name with
    | NonFunctionEntry (index) ->
      let index = sye index in
      let ts = adjust_ts state.sym_table bsym_table sr index ts in
      BEXPR_name (index,ts),
      let t = ti sr index ts in
      t

    | FunctionEntry [index] ->
      let index = sye index in
      let ts = adjust_ts state.sym_table bsym_table sr index ts in
      BEXPR_closure (index,ts),
      let t = ti sr index ts in
      t

    | FunctionEntry _ ->
      clierr sr
      (
        "[bind_expression] Simple 'the' name " ^ name ^
        " binds to non-singleton function set"
      )
    end
  | EXPR_the (sr,q) -> clierr sr "invalid use of 'the' "

  | (EXPR_lookup (sr,(e,name,ts))) as qn ->
    (*
    print_endline ("Handling qn " ^ string_of_qualified_name qn);
    *)
    let ts = List.map (bt sr) ts in
    let entry =
      match
        eval_module_expr
        state
        bsym_table
        env
        e
      with
      | (Simple_module (impl, ts, htab,dirs)) ->
        let env' = mk_bare_env state bsym_table impl in
        let tables = get_pub_tables state bsym_table env' rs dirs in
        let result = lookup_name_in_table_dirs htab tables sr name in
        result

    in
      begin match entry with
      | Some entry ->
        begin match entry with
        | NonFunctionEntry (i) ->
          let i = sye i in
          begin match hfind "lookup" state.sym_table i with
          | { Flx_sym.sr=srn; symdef=SYMDEF_inherit qn} -> be (expr_of_qualified_name qn)
          | _ ->
            let ts = adjust_ts state.sym_table bsym_table sr i ts in
            BEXPR_name (i,ts),
            ti sr i ts
          end

        | FunctionEntry fs ->
          begin match args with
          | [] ->
            clierr sr
            (
              "[bind_expression] Qualified name " ^
              string_of_expr qn ^
              " binds to function set"
            )

          | args ->
            let sufs = List.map snd args in
            let ro = resolve_overload' state bsym_table env rs sr fs name sufs ts in
            begin match ro with
             | Some (index, dom,ret,mgu,ts) ->
               (*
               print_endline "OK, overload resolved!!";
               *)
               BEXPR_closure (index,ts),
               ti sr index ts

            | None ->
              clierr sr "Overload resolution failed .. "
            end
          end
        end

      | None ->
        clierr sr
        (
          "Can't find " ^ name
        )
      end

  | EXPR_suffix (sr,(f,suf)) ->
    let sign = bt sr suf in
    let srn = src_of_qualified_name f in
    lookup_qn_with_sig' state bsym_table sr srn env rs f [sign]

  | EXPR_likely (srr,e) ->  let (_,t) as x = be e in BEXPR_likely x,t
  | EXPR_unlikely (srr,e) ->  let (_,t) as x = be e in BEXPR_unlikely x,t

  | EXPR_ref (_,(EXPR_deref (_,e))) -> be e
  | EXPR_ref (srr,e) ->
    let has_property i p =
      match get_data state.sym_table i with { Flx_sym.symdef=entry} ->
      match entry with
      | SYMDEF_fun (props,_,_,_,_,_) -> List.mem p props
      | _ -> false
    in
    let e',t' = be e in
    begin match e' with
    | BEXPR_deref e -> e
    | BEXPR_name (index,ts) ->
      begin match get_data state.sym_table index with
      { Flx_sym.id=id; sr=sr; symdef=entry} ->
      begin match entry with
      | SYMDEF_inherit _ -> clierr srr "Woops, bindexpr yielded inherit"
      | SYMDEF_inherit_fun _ -> clierr srr "Woops, bindexpr yielded inherit fun"
      | SYMDEF_ref _
      | SYMDEF_var _
      | SYMDEF_parameter (`PVar,_)
        ->
        let vtype =
          inner_type_of_index_with_ts state bsym_table sr
          { rs with depth = rs.depth+1 }
         index ts
        in
          BEXPR_ref (index,ts), BTYP_pointer vtype


      | SYMDEF_parameter _ ->
         clierr2 srr sr
        (
          "[bind_expression] " ^
          "Address value parameter " ^ id
        )
      | SYMDEF_const _
      | SYMDEF_val _ ->
        clierr2 srr sr
        (
          "[bind_expression] " ^
          "Can't address a value or const " ^ id
        )
      | _ ->
         clierr2 srr sr
        (
          "[bind_expression] " ^
          "Address non variable " ^ id
        )
      end
      end
    | BEXPR_apply ((BEXPR_closure (i,ts),_),a) when has_property i `Lvalue ->
      BEXPR_address (e',t'),BTYP_pointer t'


    | _ ->
       clierr srr
        (
          "[bind_expression] " ^
          "Address non variable " ^ sbe bsym_table (e',t')
        )
    end

  | EXPR_deref (_,EXPR_ref (sr,e)) ->
    let e,t = be e in
(*    let t = lvalify t in *)
    e,t

  | EXPR_deref (sr,e) ->
    let e,t = be e in
    begin match unfold t with
    | BTYP_pointer t'
      -> BEXPR_deref (e,t),t'
    | _ -> clierr sr "[bind_expression'] Dereference non pointer"
    end

  | EXPR_new (srr,e) ->
     let e,t as x = be e in
     BEXPR_new x, BTYP_pointer t

  | EXPR_literal (sr,v) ->
    let t = type_of_literal state bsym_table env sr v in
    BEXPR_literal v, t

  | EXPR_map (sr,f,a) ->
    handle_map sr (be f) (be a)

  | EXPR_apply (sr,(f',a')) ->
    (*
    print_endline ("Apply " ^ string_of_expr f' ^ " to " ^  string_of_expr a');
    print_env env;
    *)
    let (ea,ta) as a = be a' in
    (*
    print_endline ("Recursive descent into application " ^ string_of_expr e);
    *)
    let (bf,tf) as f =
      match qualified_name_of_expr f' with
      | Some name ->
        let sigs = List.map snd args in
        let srn = src_of_qualified_name name in
        (*
        print_endline "Lookup qn with sig .. ";
        *)
        lookup_qn_with_sig' state bsym_table sr srn env rs name (ta::sigs)
      | None -> bind_expression' state bsym_table env rs f' (a :: args)
    in
    (*
    print_endline ("tf=" ^ sbt bsym_table tf);
    print_endline ("ta=" ^ sbt bsym_table ta);
    *)
    begin match tf with
    | BTYP_cfunction _ -> cal_apply state bsym_table sr rs f a
    | BTYP_function _ ->
      (* print_endline "Function .. cal apply"; *)
      cal_apply state bsym_table sr rs f a

    (* NOTE THIS CASE HASN'T BEEN CHECKED FOR POLYMORPHISM YET *)
    | BTYP_inst (i,ts') when
      (
        match hfind "lookup" state.sym_table i with
        | { Flx_sym.symdef=SYMDEF_struct _}
        | { Flx_sym.symdef=SYMDEF_cstruct _} ->
          (match ta with | BTYP_record _ -> true | _ -> false)
        | _ -> false
      )
      ->
      (*
      print_endline "struct applied to record .. ";
      *)
      let id,vs,fls = match hfind "lookup" state.sym_table i with
        | { Flx_sym.id=id; vs=vs; symdef=SYMDEF_struct ls }
        | { Flx_sym.id=id; vs=vs; symdef=SYMDEF_cstruct ls } -> id,vs,ls
        | _ -> assert false
      in
      let alst = match ta with
        |BTYP_record ts -> ts
        | _ -> assert false
      in
      let nf = List.length fls in
      let na = List.length alst in
      if nf <> na then clierr sr
        (
          "Wrong number of components matching record argument to struct"
        )
      else begin
        let bvs = List.map (fun (n,i,_) -> n,BTYP_var (i,BTYP_type 0)) (fst vs) in
        let env' = build_env state bsym_table (Some i) in
        let vs' = List.map (fun (s,i,tp) -> s,i) (fst vs) in
        let alst = List.sort (fun (a,_) (b,_) -> compare a b) alst in
        let ialst = List.map2 (fun (k,t) i -> k,(t,i)) alst (nlist na) in
        let a:tbexpr_t list  =
          List.map (fun (name,ct)->
            let (t,j) =
              try List.assoc name ialst
              with Not_found -> clierr sr ("struct component " ^ name ^ " not provided by record")
            in
          let ct = bind_type' state bsym_table env' rsground sr ct bvs mkenv in
          let ct = tsubst vs' ts' ct in
            if type_eq state.syms.counter ct t then
              BEXPR_get_n (j,a),t
            else clierr sr ("Component " ^ name ^
              " struct component type " ^ sbt bsym_table ct ^
              "\ndoesn't match record type " ^ sbt bsym_table t
            )
          )
          fls
        in
        let cts = List.map snd a in
        let t:btypecode_t = match cts with [t]->t | _ -> BTYP_tuple cts in
        let a: bexpr_t = match a with [x,_]->x | _ -> BEXPR_tuple a in
        let a:tbexpr_t = a,t in
        cal_apply state bsym_table sr rs f a
      end

    | t ->
      (*
      print_endline ("Expected f to be function, got " ^ sbt bsym_table t);
      *)
      let apl name =
        be
        (
          EXPR_apply
          (
            sr,
            (
              EXPR_name (sr,name,[]),
              EXPR_tuple (sr,[f';a'])
            )
          )
        )
      in
      apl "apply"
    end


  | EXPR_arrayof (sr,es) ->
    let bets = List.map be es in
    let _, bts = List.split bets in
    let n = List.length bets in
    if n > 1 then begin
      let t = List.hd bts in
      List.iter
      (fun t' -> if t <> t' then
         clierr sr
         (
           "Elements of this array must all be of type:\n" ^
           sbt bsym_table t ^ "\ngot:\n"^ sbt bsym_table t'
         )
      )
      (List.tl bts)
      ;
      let t = BTYP_array (t,BTYP_unitsum n) in
      BEXPR_tuple bets,t
    end else if n = 1 then List.hd bets
    else syserr sr "Empty array?"

  | EXPR_record_type _ -> assert false
  | EXPR_variant_type _ -> assert false

  | EXPR_record (sr,ls) ->
    begin match ls with
    | [] -> BEXPR_tuple [],BTYP_tuple []
    | _ ->
    let ss,es = List.split ls in
    let es = List.map be es in
    let ts = List.map snd es in
    let t = BTYP_record (List.combine ss ts) in
    BEXPR_record (List.combine ss es),t
    end

  | EXPR_tuple (_,es) ->
    let bets = List.map be es in
    let _, bts = List.split bets in
    let n = List.length bets in
    if n > 1 then
      try
        let t = List.hd bts in
        List.iter
        (fun t' -> if t <> t' then raise Not_found)
        (List.tl bts)
        ;
        let t = BTYP_array (t,BTYP_unitsum n) in
        BEXPR_tuple bets,t
      with Not_found ->
        BEXPR_tuple bets, BTYP_tuple bts
    else if n = 1 then
      List.hd bets
    else
    BEXPR_tuple [],BTYP_tuple []


  | EXPR_dot (sr,(e,e2)) ->

    (* Analyse LHS.
      If it is a pointer, dereference it transparently.
      The component lookup is an lvalue if the argument
      is an lvalue or a pointer, unless an apply method
      is used, in which case the user function result
      determines the lvalueness.
    *)
    let ttt,e,te =
      let (_,tt') as te = be e in (* polymorphic! *)
      let rec aux n t = match t with
        | BTYP_pointer t -> aux (n+1) t
        | _ -> n,t
      in
      let np,ttt = aux 0 (rt tt') in
      let rec dref n x = match n with
          | 0 -> x
          | _ -> dref (n-1) (EXPR_deref (sr,x))
      in
      let e = dref np e in
      let e',t' = be e in
      let te = e',t' in
      ttt,e,te
    in

    begin match e2 with

    (* RHS IS A SIMPLE NAME *)
    | EXPR_name (_,name,ts) ->
      begin match ttt with

      (* LHS IS A NOMINAL TYPE *)
      | BTYP_inst (i,ts') ->
        begin match hfind "lookup" state.sym_table i with

        (* STRUCT *)
        | { Flx_sym.id=id; vs=vs; symdef=SYMDEF_struct ls } ->
          begin try
          let cidx,ct =
            let rec scan i = function
            | [] -> raise Not_found
            | (vn,vat)::_ when vn = name -> i,vat
            | _:: t -> scan (i+1) t
            in scan 0 ls
          in
          let ct =
            let bvs = List.map (fun (n,i,_) -> n,BTYP_var (i,BTYP_type 0)) (fst vs) in
            let env' = build_env state bsym_table (Some i) in
            bind_type' state bsym_table env' rsground sr ct bvs mkenv
          in
          let vs' = List.map (fun (s,i,tp) -> s,i) (fst vs) in
          let ct = tsubst vs' ts' ct in
          BEXPR_get_n (cidx,te),ct
          with Not_found ->
            let get_name = "get_" ^ name in
            begin try cal_method_apply sr get_name e ts 
            with exn1 -> try be (EXPR_apply (sr,(e2,e)))
            with exn2 ->
            clierr sr (
              "AST_dot: cstruct type: koenig apply "^get_name ^
              ", AND apply " ^ name ^
              " failed with " ^ Printexc.to_string exn2
              )
            end
          end
        (* LHS CSTRUCT *)
        | { Flx_sym.id=id; vs=vs; symdef=SYMDEF_cstruct ls } ->
          (* NOTE: we try $1.name binding using get_n first,
          but if we can't find a component we treat the
          entity as abstract.

          Hmm not sure that cstructs can be polymorphic.
          *)
          begin try
            let cidx,ct =
              let rec scan i = function
              | [] -> raise Not_found
              | (vn,vat)::_ when vn = name -> i,vat
              | _:: t -> scan (i+1) t
              in scan 0 ls
            in
            let ct =
              let bvs = List.map (fun (n,i,_) -> n,BTYP_var (i,BTYP_type 0)) (fst vs) in
              let env' = build_env state bsym_table (Some i) in
              bind_type' state bsym_table env' rsground sr ct bvs mkenv
            in
            let vs' = List.map (fun (s,i,tp) -> s,i) (fst vs) in
            let ct = tsubst vs' ts' ct in
            (* propagate lvalueness to struct component *)
            BEXPR_get_n (cidx,te),ct
          with
          | Not_found ->
            (*
            print_endline ("Synth get method .. (1) " ^ name);
            *)
            let get_name = "get_" ^ name in
            begin try cal_method_apply sr get_name e ts 
            with _ -> try be (EXPR_apply (sr,(e2,e)))
            with exn ->
            clierr sr (
              "AST_dot: cstruct type: koenig apply "^get_name ^
              ", AND apply " ^ name ^
              " failed with " ^ Printexc.to_string exn
              )
            end

           end

        (* LHS PRIMITIVE TYPE *)
        | { Flx_sym.id=id; symdef=SYMDEF_abs _ } ->
            (*
            print_endline ("Synth get method .. (4) " ^ name);
            *)
          let get_name = "get_" ^ name in
          begin try cal_method_apply sr get_name e ts
          with exn1 -> try be (EXPR_apply (sr,(e2,e)))
          with exn2 ->
          clierr sr (
            "AST_dot: Abstract type "^id^"="^sbt bsym_table ttt ^
            "\napply " ^ name ^
            " failed with " ^ Printexc.to_string exn2
            )
          end

        | _ ->
          failwith ("[lookup] operator . Expected LHS nominal type to be"^
          " (c)struct or abstract primitive, got " ^
          sbt bsym_table ttt)

        end

      (* LHS RECORD *)
      | BTYP_record es ->
        let rcmp (s1,_) (s2,_) = compare s1 s2 in
        let es = List.sort rcmp es in
        let field_name = name in
        begin match list_index (List.map fst es) field_name with
        | Some n -> BEXPR_get_n (n,te),(List.assoc field_name es)
        | None ->
          try be (EXPR_apply (sr,(e2,e)))
          with exn ->
          clierr sr
          (
            "[bind_expression] operator dot: Field " ^ field_name ^
            " is not a member of anonymous structure type " ^
             sbt bsym_table ttt ^
             "\n and trying " ^ field_name ^
             " as a function also failed"
          )
        end

      (* LHS FUNCTION TYPE *)
      | BTYP_function (d,c) ->
        begin try be (EXPR_apply (sr,(e2,e)))
        with exn ->
        clierr sr (
        "AST_dot, arg "^ string_of_expr e2^
        " is simple name, and attempt to apply it failed with " ^
        Printexc.to_string exn
        )
        end

      (* LHS TUPLE TYPE *)
      | BTYP_tuple _ ->
        begin try be (EXPR_apply (sr,(e2,e)))
        with exn ->
        clierr sr (
        "AST_dot, arg "^ string_of_expr e2^
        " is simple name, and attempt to apply it failed with " ^
        Printexc.to_string exn
        )
        end

      (* LHS OTHER ALGEBRAIC TYPE *)
      | _ ->
        begin try be (EXPR_apply (sr,(e2,e)))
        with exn ->
        clierr sr (
        "AST_dot, arg "^ string_of_expr e2^
        " is not simple name, and attempt to apply it failed with " ^
        Printexc.to_string exn
        )
        end
      end

    (* RHS NOT A SIMPLE NAME: reverse application *)
    | _ ->
      try be (EXPR_apply (sr,(e2,e)))
      with exn ->
      clierr sr (
        "AST_dot, arg "^ string_of_expr e2^
        " is not simple name, and attempt to apply it failed with " ^
        Printexc.to_string exn
        )
  end

  | EXPR_match_case (sr,(v,e)) ->
     BEXPR_match_case (v,be e),flx_bbool

  | EXPR_match_ctor (sr,(qn,e)) ->
    begin match qn with
    | `AST_name (sr,name,ts) ->
      (*
      print_endline ("WARNING(deprecate): match constructor by name! " ^ name);
      *)
      let (_,ut) as ue = be e in
      let ut = rt ut in
      (*
      print_endline ("Union type is " ^ sbt bsym_table ut);
      *)
      begin match ut with
      | BTYP_inst (i,ts') ->
        (*
        print_endline ("OK got type " ^ si i);
        *)
        begin match hfind "lookup" state.sym_table i with
        | { Flx_sym.id=id; symdef=SYMDEF_union ls } ->
          (*
          print_endline ("UNION TYPE! " ^ id);
          *)
          let vidx =
            let rec scan = function
            | [] -> failwith "Can't find union variant"
            | (vn,vidx,vs',vat)::_ when vn = name -> vidx
            | _:: t -> scan t
            in scan ls
          in
          (*
          print_endline ("Index is " ^ si vidx);
          *)
          BEXPR_match_case (vidx,ue),flx_bbool

        (* this handles the case of a C type we want to model
        as a union by provding _match_ctor_name style function
        as C primitives ..
        *)
        | { Flx_sym.id=id; symdef=SYMDEF_abs _ } ->
          let fname = EXPR_name (sr,"_match_ctor_" ^ name,ts) in
          be (EXPR_apply ( sr, (fname,e)))

        | _ -> clierr sr ("expected union of abstract type, got" ^ sbt bsym_table ut)
        end
      | _ -> clierr sr ("expected nominal type, got" ^ sbt bsym_table ut)
      end

    | `AST_lookup (sr,(context,name,ts)) ->
      (*
      print_endline ("WARNING(deprecate): match constructor by name! " ^ name);
      *)
      let (_,ut) as ue = be e in
      let ut = rt ut in
      (*
      print_endline ("Union type is " ^ sbt bsym_table ut);
      *)
      begin match ut with
      | BTYP_inst (i,ts') ->
        (*
        print_endline ("OK got type " ^ si i);
        *)
        begin match hfind "lookup" state.sym_table i with
        | { Flx_sym.id=id; symdef=SYMDEF_union ls } ->
          (*
          print_endline ("UNION TYPE! " ^ id);
          *)
          let vidx =
            let rec scan = function
            | [] -> failwith "Can't find union variant"
            | (vn,vidx,vs,vat)::_ when vn = name -> vidx
            | _:: t -> scan t
            in scan ls
          in
          (*
          print_endline ("Index is " ^ si vidx);
          *)
          BEXPR_match_case (vidx,ue),flx_bbool

        (* this handles the case of a C type we want to model
        as a union by provding _match_ctor_name style function
        as C primitives ..
        *)
        | { Flx_sym.id=id; symdef=SYMDEF_abs _ } ->
          let fname = EXPR_lookup (sr,(context,"_match_ctor_" ^ name,ts)) in
          be (EXPR_apply ( sr, (fname,e)))
        | _ -> failwith "Woooops expected union or abstract type"
        end
      | _ -> failwith "Woops, expected nominal type"
      end

    | `AST_typed_case (sr,v,_)
    | `AST_case_tag (sr,v) ->
       be (EXPR_match_case (sr,(v,e)))

    | _ -> clierr sr "Expected variant constructor name in union decoder"
    end

  | EXPR_case_arg (sr,(v,e)) ->
     let (_,t) as e' = be e in
    ignore (try unfold t with _ -> failwith "AST_case_arg unfold screwd");
     begin match unfold t with
     | BTYP_unitsum n ->
       if v < 0 or v >= n
       then clierr sr "Invalid sum index"
       else
         BEXPR_case_arg (v, e'),unit_t

     | BTYP_sum ls ->
       let n = List.length ls in
       if v<0 or v>=n
       then clierr sr "Invalid sum index"
       else let t = List.nth ls v in
       BEXPR_case_arg (v, e'),t

     | _ -> clierr sr ("Expected sum type, got " ^ sbt bsym_table t)
     end

  | EXPR_ctor_arg (sr,(qn,e)) ->
    begin match qn with
    | `AST_name (sr,name,ts) ->
      (*
      print_endline ("WARNING(deprecate): decode variant by name! " ^ name);
      *)
      let (_,ut) as ue = be e in
      let ut = rt ut in
      (*
      print_endline ("Union type is " ^ sbt bsym_table ut);
      *)
      begin match ut with
      | BTYP_inst (i,ts') ->
        (*
        print_endline ("OK got type " ^ si i);
        *)
        begin match hfind "lookup" state.sym_table i with
        | { Flx_sym.id=id; vs=vs; symdef=SYMDEF_union ls } ->
          (*
          print_endline ("UNION TYPE! " ^ id);
          *)
          let vidx,vt =
            let rec scan = function
            | [] -> failwith "Can't find union variant"
            | (vn,vidx,vs',vt)::_ when vn = name -> vidx,vt
            | _:: t -> scan t
            in scan ls
          in
          (*
          print_endline ("Index is " ^ si vidx);
          *)
          let vt =
            let bvs = List.map (fun (n,i,_) -> n,BTYP_var (i,BTYP_type 0)) (fst vs) in
            (*
            print_endline ("Binding ctor arg type = " ^ string_of_typecode vt);
            *)
            let env' = build_env state bsym_table (Some i) in
            bind_type' state bsym_table env' rsground sr vt bvs mkenv
          in
          (*
          print_endline ("Bound polymorphic type = " ^ sbt bsym_table vt);
          *)
          let vs' = List.map (fun (s,i,tp) -> s,i) (fst vs) in
          let vt = tsubst vs' ts' vt in
          (*
          print_endline ("Instantiated type = " ^ sbt bsym_table vt);
          *)
          BEXPR_case_arg (vidx,ue),vt

        (* this handles the case of a C type we want to model
        as a union by provding _ctor_arg style function
        as C primitives ..
        *)
        | { Flx_sym.id=id; symdef=SYMDEF_abs _ } ->
          let fname = EXPR_name (sr,"_ctor_arg_" ^ name,ts) in
          be (EXPR_apply ( sr, (fname,e)))

        | _ -> failwith "Woooops expected union or abstract type"
        end
      | _ -> failwith "Woops, expected nominal type"
      end


    | `AST_lookup (sr,(e,name,ts)) ->
      (*
      print_endline ("WARNING(deprecate): decode variant by name! " ^ name);
      *)
      let (_,ut) as ue = be e in
      let ut = rt ut in
      (*
      print_endline ("Union type is " ^ sbt bsym_table ut);
      *)
      begin match ut with
      | BTYP_inst (i,ts') ->
        (*
        print_endline ("OK got type " ^ si i);
        *)
        begin match hfind "lookup" state.sym_table i with
        | { Flx_sym.id=id; vs=vs; symdef=SYMDEF_union ls } ->
          (*
          print_endline ("UNION TYPE! " ^ id);
          *)
          let vidx,vt =
            let rec scan = function
            | [] -> failwith "Can't find union variant"
            | (vn,vidx,vs',vt)::_ when vn = name -> vidx,vt
            | _:: t -> scan t
            in scan ls
          in
          (*
          print_endline ("Index is " ^ si vidx);
          *)
          let vt =
            let bvs = List.map (fun (n,i,_) -> n,BTYP_var (i,BTYP_type 0)) (fst vs) in
            (*
            print_endline ("Binding ctor arg type = " ^ string_of_typecode vt);
            *)
            let env' = build_env state bsym_table (Some i) in
            bind_type' state bsym_table env' rsground sr vt bvs mkenv
          in
          (*
          print_endline ("Bound polymorphic type = " ^ sbt bsym_table vt);
          *)
          let vs' = List.map (fun (s,i,tp) -> s,i) (fst vs) in
          let vt = tsubst vs' ts' vt in
          (*
          print_endline ("Instantiated type = " ^ sbt bsym_table vt);
          *)
          BEXPR_case_arg (vidx,ue),vt

        (* this handles the case of a C type we want to model
        as a union by provding _match_ctor_name style function
        as C primitives ..
        *)
        | { Flx_sym.id=id; symdef=SYMDEF_abs _ } ->
          let fname = EXPR_lookup (sr,(e,"_ctor_arg_" ^ name,ts)) in
          be (EXPR_apply ( sr, (fname,e)))

        | _ -> failwith "Woooops expected union or abstract type"
        end
      | _ -> failwith "Woops, expected nominal type"
      end


    | `AST_typed_case (sr,v,_)
    | `AST_case_tag (sr,v) ->
      be (EXPR_case_arg (sr,(v,e)))

    | _ -> clierr sr "Expected variant constructor name in union dtor"
    end

  | EXPR_lambda (sr,_) ->
    syserr sr
    (
      "[bind_expression] " ^
      "Unexpected lambda when binding expression (should have been lifted out)" ^
      string_of_expr e
    )

  | EXPR_match (sr,_) ->
    clierr sr
    (
      "[bind_expression] " ^
      "Unexpected match when binding expression (should have been lifted out)"
    )

and resolve_overload
  state
  bsym_table
  env
  sr
  (fs : entry_kind_t list)
  (name: string)
  (sufs : btypecode_t list)
  (ts:btypecode_t list)
: overload_result option =
  resolve_overload' state bsym_table env rsground sr fs name sufs ts


and hack_name qn = match qn with
| `AST_name (sr,name,ts) -> `AST_name (sr,"_inst_"^name,ts)
| `AST_lookup (sr,(e,name,ts)) -> `AST_lookup (sr,(e,"_inst_"^name,ts))
| _ -> failwith "expected qn .."

and grab_ts qn = match qn with
| `AST_name (sr,name,ts) -> ts
| `AST_lookup (sr,(e,name,ts)) -> ts
| _ -> failwith "expected qn .."

and grab_name qn = match qn with
| `AST_name (sr,name,ts) -> name
| `AST_lookup (sr,(e,name,ts)) -> name
| _ -> failwith "expected qn .."


and check_instances state bsym_table call_sr calledname classname es ts' mkenv =
  let insts = ref [] in
  match es with
  | NonFunctionEntry _ -> print_endline "EXPECTED INSTANCES TO BE FUNCTION SET"
  | FunctionEntry es ->
    (*
    print_endline ("instance Candidates " ^ catmap "," string_of_entry_kind es);
    *)
    List.iter
    (fun {base_sym=i; spec_vs=spec_vs; sub_ts=sub_ts} ->
    match hfind "lookup" state.sym_table i  with
    { Flx_sym.id=id;sr=sr;parent=parent;vs=vs;symdef=entry} ->
    match entry with
    | SYMDEF_instance qn' ->
      (*
      print_endline ("Verified " ^ si i ^ " is an instance of " ^ id);
      print_endline ("  base vs = " ^ print_ivs_with_index vs);
      print_endline ("  spec vs = " ^ catmap "," (fun (s,i) -> s^"<"^si i^">") spec_vs);
      print_endline ("  view ts = " ^ catmap "," (fun t -> sbt bsym_table t) sub_ts);
      *)
      let inst_ts = grab_ts qn' in
      (*
      print_endline ("Unbound instance ts = " ^ catmap "," string_of_typecode inst_ts);
      *)
      let instance_env = mkenv i in
      let bt t = bind_type' state bsym_table instance_env rsground sr t [] mkenv in
      let inst_ts = List.map bt inst_ts in
      (*
      print_endline ("  instance ts = " ^ catmap "," (fun t -> sbt bsym_table t) inst_ts);
      print_endline ("  caller   ts = " ^ catmap "," (fun t -> sbt bsym_table t) ts');
      *)
      let matches =
        if List.length inst_ts <> List.length ts' then false else
        match maybe_specialisation state.syms.counter (List.combine inst_ts ts') with
        | None -> false
        | Some mgu ->
          (*
          print_endline ("MGU: " ^ catmap ", " (fun (i,t)-> si i ^ "->" ^ sbt bsym_table t) mgu);
          print_endline ("check base vs (constraint) = " ^ print_ivs_with_index vs);
          *)
          let cons = try
            Flx_tconstraint.build_type_constraints state.syms bt sr (fst vs)
            with _ -> clierr sr "Can't build type constraints, type binding failed"
          in
          let {raw_type_constraint=icons} = snd vs in
          let icons = bt icons in
          (*
          print_endline ("Constraint = " ^ sbt bsym_table cons);
          print_endline ("VS Constraint = " ^ sbt bsym_table icons);
          *)
          let cons = BTYP_intersect [cons; icons] in
          (*
          print_endline ("Constraint = " ^ sbt bsym_table cons);
          *)
          let cons = list_subst state.syms.counter mgu cons in
          (*
          print_endline ("Constraint = " ^ sbt bsym_table cons);
          *)
          let cons = Flx_maps.reduce_type (beta_reduce state.syms bsym_table sr cons) in
          match cons with
          | BTYP_tuple [] -> true
          | BTYP_void -> false
          | _ ->
             (*
              print_endline (
               "[instance_check] Can't reduce instance type constraint " ^
               sbt bsym_table cons
             );
             *)
             true
      in

      if matches then begin
        (*
        print_endline "INSTANCE MATCHES";
        *)
        insts := `Inst i :: !insts
      end
      (*
      else
        print_endline "INSTANCE DOES NOT MATCH: REJECTED"
      *)
      ;


    | SYMDEF_typeclass ->
      (*
      print_endline ("Verified " ^ si i ^ " is an typeclass specialisation of " ^ classname);
      print_endline ("  base vs = " ^ print_ivs_with_index vs);
      print_endline ("  spec vs = " ^ catmap "," (fun (s,i) -> s^"<"^si i^">") spec_vs);
      print_endline ("  view ts = " ^ catmap "," (fun t -> sbt bsym_table t) sub_ts);
      *)
      if sub_ts = ts' then begin
        (*
        print_endline "SPECIALISATION MATCHES";
        *)
        insts := `Typeclass (i,sub_ts) :: !insts
      end
      (*
      else
        print_endline "SPECIALISATION DOES NOT MATCH: REJECTED"
      ;
      *)

    | _ -> print_endline "EXPECTED TYPECLASS INSTANCE!"
    )
    es
    ;
    (*
    begin match !insts with
    | [`Inst i] -> ()
    | [`Typeclass (i,ts)] -> ()
    | [] ->
      print_endline ("WARNING: In call of " ^ calledname ^", Typeclass instance matching " ^
        classname ^"["^catmap "," (sbt bsym_table) ts' ^"]" ^
        " not found"
      )
    | `Inst i :: t ->
      print_endline ("WARNING: In call of " ^ calledname ^", More than one instances matching " ^
        classname ^"["^catmap "," (sbt bsym_table) ts' ^"]" ^
        " found"
      );
      print_endline ("Call of " ^ calledname ^ " at " ^ Flx_srcref.short_string_of_src call_sr);
      List.iter (fun i ->
        match i with
        | `Inst i -> print_endline ("Instance " ^ si i)
        | `Typeclass (i,ts) -> print_endline ("Typeclass " ^ si i^"[" ^ catmap "," (sbt bsym_table) ts ^ "]")
      )
      !insts

    | `Typeclass (i,ts) :: tail ->
      clierr call_sr ("In call of " ^ calledname ^", Multiple typeclass specialisations matching " ^
        classname ^"["^catmap "," (sbt bsym_table) ts' ^"]" ^
        " found"
      )
    end
    *)


and instance_check state bsym_table caller_env called_env mgu sr calledname rtcr tsub =
  (*
  print_endline ("INSTANCE CHECK MGU: " ^ catmap ", " (fun (i,t)-> si i ^ "->" ^ sbt bsym_table t) mgu);
  print_endline "SEARCH FOR INSTANCE!";
  print_env caller_env;
  *)
  let luqn2 qn = lookup_qn_in_env2' state bsym_table caller_env rsground qn in
  if List.length rtcr > 0 then begin
    (*
    print_endline (calledname ^" TYPECLASS INSTANCES REQUIRED (unbound): " ^
      catmap "," string_of_qualified_name rtcr
    );
    *)
    List.iter
    (fun qn ->
      let call_sr = src_of_qualified_name qn in
      let classname = grab_name qn in
      let es,ts' =
        try luqn2 (hack_name qn)
        with
          (* This is a HACK. we need lookup to throw a specific
             lookup failure exception
          *)
          ClientError (sr',msg) -> raise (ClientError2 (sr,sr',msg))
      in
      (*
      print_endline ("With unbound ts = " ^ catmap "," string_of_typecode ts');
      *)
      let ts' = List.map (fun t -> try inner_bind_type state bsym_table called_env sr rsground t with _ -> print_endline "Bind type failed .."; assert false) ts' in
      (*
      print_endline ("With bound ts = " ^ catmap "," (sbt bsym_table) ts');
      *)
      let ts' = List.map tsub ts' in
      (*
      print_endline ("With bound, mapped ts = " ^ catmap "," (sbt bsym_table) ts');
      *)
      check_instances state bsym_table call_sr calledname classname es ts' (fun i->build_env state bsym_table (Some i))
    )
    rtcr
  end

and resolve_overload'
  state
  bsym_table
  caller_env
  (rs:recstop)
  sr
  (fs : entry_kind_t list)
  (name: string)
  (sufs : btypecode_t list)
  (ts:btypecode_t list)
: overload_result option =
  if List.length fs = 0 then None else
  let env i =
    (*
    print_endline ("resolve_overload': Building env for " ^ name ^ "<" ^ si i ^ ">");
    *)
    inner_build_env state bsym_table rs (Some i)
  in
  let bt rs sr i t =
    inner_bind_type state bsym_table (env i) sr rs t
  in
  let be i e =
    inner_bind_expression state bsym_table (env i) rs e
  in
  let luqn2 i qn = lookup_qn_in_env2' state bsym_table (env i) rs qn in
  let fs = trclose state bsym_table rs sr fs in
  let result : overload_result option =
    overload state.syms state.sym_table bsym_table caller_env rs bt be luqn2 sr fs name sufs ts
  in
  begin match result with
  | None -> ()
  | Some (index,sign,ret,mgu,ts) ->
    (*
    print_endline ("RESOLVED OVERLOAD OF " ^ name);
    print_endline (" .. mgu = " ^ string_of_varlist state.sym_table mgu);
    print_endline ("Resolve ts = " ^ catmap "," (sbt bsym_table) ts);
    *)
    let parent_vs,vs,{raw_typeclass_reqs=rtcr} = find_split_vs state.sym_table index in
    (*
    print_endline ("Function vs=" ^ catmap "," (fun (s,i,_) -> s^"<"^si i^">") vs);
    print_endline ("Parent vs=" ^ catmap "," (fun (s,i,_) -> s^"<"^si i^">") parent_vs);
    *)
    let vs = List.map (fun (s,i,_)->s,i) (parent_vs @ vs) in
    let tsub t = tsubst vs ts t in
    instance_check state bsym_table caller_env (env index) mgu sr name rtcr tsub
  end
  ;
  result

(* an environment is a list of hastables, mapping
   names to definition indicies. Each entity defining
   a scope contains one hashtable, and a pointer to
   its parent, if any. The name 'root' is special,
   it is the name of the single top level module
   created by the desugaring phase. We have to be
   able to find this name, so if when we run out
   of parents, which is when we hit the top module,
   we create a parent name map with a single entry
   'top'->NonFunctionEntry 0.
*)

and split_dirs open_excludes dirs :
    (ivs_list_t * qualified_name_t) list *
    (ivs_list_t * qualified_name_t) list *
    (string * qualified_name_t) list
=
  let opens =
     List.concat
     (
       List.map
       (fun (sr,x) -> match x with
         | DIR_open (vs,qn) -> if List.mem (vs,qn) open_excludes then [] else [vs,qn]
         | DIR_inject_module qn -> []
         | DIR_use (n,qn) -> []
       )
       dirs
     )
  and includes =
     List.concat
     (
       List.map
       (fun (sr,x) -> match x with
         | DIR_open _-> []
         | DIR_inject_module qn -> [dfltvs,qn]
         | DIR_use (n,qn) -> []
       )
       dirs
     )
  and uses =
     List.concat
     (
       List.map
       (fun (sr,x) -> match x with
         | DIR_open _-> []
         | DIR_inject_module qn -> []
         | DIR_use (n,qn) -> [n,qn]
       )
       dirs
     )
  in opens, includes, uses

(* calculate the transitive closure of an i,ts list
  with respect to inherit clauses.

  The result is an i,ts list.

  This is BUGGED because it ignores typeclass requirements ..
  however
  (a) modules can't have them (use inherit clause)
  (b) typeclasses don't use them (use inherit clause)
  (c) the routine is only called for modules and typeclasses?
*)

and get_includes state bsym_table rs xs =
  let rec get_includes' includes ((invs,i, ts) as index) =
    if not (List.mem index !includes) then
    begin
      (*
      if List.length ts != 0 then
        print_endline ("INCLUDES, ts="^catmap "," (sbt bsym_table) ts)
      ;
      *)
      includes := index :: !includes;
      let env = mk_bare_env state bsym_table i in (* should have ts in .. *)
      let qns,sr,vs =
        match hfind "lookup" state.sym_table i with
        { Flx_sym.id=id; sr=sr; parent=parent; vs=vs; dirs=dirs } ->
        (*
        print_endline (id ^", Raw vs = " ^ catmap "," (fun (n,k,_) -> n ^ "<" ^ si k ^ ">") (fst vs));
        *)
        let _,incl_qns,_ = split_dirs [] dirs in
        let vs = List.map (fun (n,i,_) -> n,i) (fst vs) in
        incl_qns,sr,vs
      in
      List.iter (fun (_,qn) ->
          let {base_sym=j; spec_vs=vs'; sub_ts=ts'},ts'' =
            try lookup_qn_in_env' state bsym_table env rsground qn
            with Not_found -> failwith "QN NOT FOUND"
          in
            (*
            print_endline ("BIND types " ^ catmap "," string_of_typecode ts'');
            *)
            let mkenv i = mk_bare_env state bsym_table i in
            let bt t = bind_type' state bsym_table env rs sr t [] mkenv in
            let ts'' = List.map bt ts'' in
            (*
            print_endline ("BOUND types " ^ catmap "," (sbt bsym_table) ts'');
            *)
            (*
            print_endline ("inherit " ^ string_of_qualified_name qn ^
            ", bound ts="^catmap "," (sbt bsym_table) ts'');
            print_endline ("Spec vs = " ^ catmap "," (fun (n,k) -> n ^ "<" ^ si k ^ ">") vs');
            *)

            let ts'' = List.map (tsubst vs ts) ts'' in
            (*
            print_endline ("Inherit after subs(1): " ^ si j ^ "["^catmap "," (sbt bsym_table) ts'' ^"]");
            *)
            let ts' = List.map (tsubst vs' ts'') ts' in
            (*
            print_endline ("Inherit after subs(2): " ^ si j ^ "["^catmap "," (sbt bsym_table) ts' ^"]");
            *)
            get_includes' includes (invs,j,ts')
      )
      qns
    end
  in
  let includes = ref [] in
  List.iter (get_includes' includes) xs;

  (* list is unique due to check during construction *)
  !includes

and bind_dir
  (state:lookup_state_t)
  bsym_table
  (env:env_t) rs
  (vs,qn)
: ivs_list_t * bid_t * btypecode_t list =
  (*
  print_endline ("Try to bind dir " ^ string_of_qualified_name qn);
  *)
  let nullmap=Hashtbl.create 3 in
  (* cheating stuff to add the type variables to the environment *)
  let cheat_table = Hashtbl.create 7 in
  List.iter
  (fun (n,i,_) ->
   let entry = NonFunctionEntry {base_sym=i; spec_vs=[]; sub_ts=[]} in
    Hashtbl.add cheat_table n entry;
    if not (Flx_sym_table.mem state.sym_table i) then
      Flx_sym_table.add state.sym_table i {
        Flx_sym.id=n;
        sr=dummy_sr;
        parent=None;
        vs=dfltvs;
        pubmap=nullmap;
        privmap=nullmap;
        dirs=[];
        symdef=SYMDEF_typevar TYP_type
      }
    ;
  )
  (fst vs)
  ;
  let cheat_env = (dummy_bid,"cheat",cheat_table,[],TYP_tuple []) in
  let {base_sym=i; spec_vs=spec_vs; sub_ts=ts}, ts' =
    try
      lookup_qn_in_env' state bsym_table env
      {rs with open_excludes = (vs,qn)::rs.open_excludes }
      qn
    with Not_found -> failwith "QN NOT FOUND"
  in
  (* the vs is crap I think .. *)
  (*
  the ts' are part of the name and are bound in calling context
  the ts, if present, are part of a view we found if we
  happened to open a view, rather than a base module.
  At present this cannot happen because there is no way
  to actually name a view.
  *)
  (*
  assert (List.length vs = 0);
  assert (List.length ts = 0);
  *)
  let mkenv i = mk_bare_env state bsym_table i in
  (*
  print_endline ("Binding ts=" ^ catmap "," string_of_typecode ts');
  *)
  let ts' = List.map (fun t ->
    beta_reduce
      state.syms
      bsym_table
      dummy_sr
      (bind_type' state bsym_table (cheat_env::env) rsground dummy_sr t [] mkenv)
    ) ts' in
  (*
  print_endline ("Ts bound = " ^ catmap "," (sbt bsym_table) ts');
  *)
  (*
  let ts' = List.map (fun t-> bind_type state env dummy_sr t) ts' in
  *)
  vs,i,ts'

and review_entry state vs ts {base_sym=i; spec_vs=vs'; sub_ts=ts'} : entry_kind_t =
   (* vs is the set of type variables at the call point,
     there are vs in the given ts,
     ts is the instantiation of another view,
     the number of these should agree with the view variables vs',
     we're going to plug these into formula got thru that view
     to form the next one.
     ts' may contain type variables of vs'.
     The ts' are ready to plug into the base objects type variables
     and should agree in number.

     SO .. we have to replace the vs' in each ts' using the given
     ts, and then record that the result contains vs variables
     to allow for the next composition .. whew!
   *)

   (* if vs' is has extra variables,
      (*
      tack them on to the ts
      *)
      synthesise a new vs/ts pair
      if vs' doesn't have enough variables, just drop the extra ts
   *)
    (*
    print_endline ("input vs="^catmap "," (fun (s,i)->s^"<"^si i^">") vs^
      ", input ts="^catmap "," (sbt bsym_table) ts);
    print_endline ("old vs="^catmap "," (fun (s,i)->s^"<"^si i^">") vs'^
      ", old ts="^catmap "," (sbt bsym_table) ts');
   *)
   let vs = ref (List.rev vs) in
   let vs',ts =
     let rec aux invs ints outvs outts =
       match invs,ints with
       | h::t,h'::t' -> aux t t' (h::outvs) (h'::outts)
       | h::t,[] ->
         let i = fresh_bid state.syms.counter in
         let (name,_) = h in
         vs := (name,i)::!vs;
         (*
         print_endline ("SYNTHESISE FRESH VIEW VARIABLE "^si i^" for missing ts");
         *)
         let h' = BTYP_var (i,BTYP_type 0) in
         (*
         let h' = let (_,i) = h in BTYP_var (i,BTYP_type 0) in
         *)
         aux t [] (h::outvs) (h'::outts)
       | _ -> List.rev outvs, List.rev outts
     in aux vs' ts [] []
   in
   let vs = List.rev !vs in
   let ts' = List.map (tsubst vs' ts) ts' in
   {base_sym=i; spec_vs=vs; sub_ts=ts'}

and review_entry_set state v vs ts : entry_set_t = match v with
  | NonFunctionEntry i -> NonFunctionEntry (review_entry state vs ts i)
  | FunctionEntry fs -> FunctionEntry (List.map (review_entry state vs ts) fs)

and make_view_table state table vs ts : name_map_t =
  (*
  print_endline ("vs="^catmap "," (fun (s,_)->s) vs^", ts="^catmap "," (sbt bsym_table) ts);
  print_endline "Building view table!";
  *)
  let h = Hashtbl.create 97 in
  Hashtbl.iter
  (fun k v ->
    (*
    print_endline ("Entry " ^ k);
    *)
    let v = review_entry_set state v vs ts in
    Hashtbl.add h k v
  )
  table
  ;
  h

and pub_table_dir state bsym_table env inst_check (invs,i,ts) : name_map_t =
  let invs = List.map (fun (i,n,_)->i,n) (fst invs) in
  let sym = get_data state.sym_table i in
  match sym.Flx_sym.symdef with
  | SYMDEF_module ->
    if List.length ts = 0 then sym.Flx_sym.pubmap else
    begin
      (*
      print_endline ("TABLE " ^ id);
      *)
      let table = make_view_table state sym.Flx_sym.pubmap invs ts in
      (*
      print_name_table state.sym_table table;
      *)
      table
    end

  | SYMDEF_typeclass ->
    let table = make_view_table state sym.Flx_sym.pubmap invs ts in
    (* a bit hacky .. add the type class specialisation view
       to its contents as an instance
    *)
    let inst = mkentry state sym.Flx_sym.vs i in
    let inst = review_entry state invs ts inst in
    let inst_name = "_inst_" ^ sym.Flx_sym.id in
    Hashtbl.add table inst_name (FunctionEntry [inst]);
    if inst_check then begin
      if state.syms.compiler_options.print_flag then
        print_endline ("Added typeclass " ^ string_of_bid i ^
          " as instance " ^ inst_name ^": " ^
          string_of_myentry bsym_table inst);
      let luqn2 qn =
        try
          Some (lookup_qn_in_env2' state bsym_table env rsground qn)
        with _ -> None
      in
      let res = luqn2 (`AST_name (sym.Flx_sym.sr, inst_name, [])) in
      match res with
      | None ->
          clierr sym.Flx_sym.sr ("Couldn't find any instances to open for " ^
            sym.Flx_sym.id ^ "[" ^ catmap "," (sbt bsym_table) ts ^ "]"
        )
      | Some (es,_) ->
          check_instances
            state
            bsym_table
            sym.Flx_sym.sr
            "open"
            sym.Flx_sym.id
            es
            ts
            (mk_bare_env state bsym_table)
      end;
      table

  | _ ->
      clierr sym.Flx_sym.sr "[map_dir] Expected module"


and get_pub_tables state bsym_table env rs dirs =
  let _,includes,_ = split_dirs rs.open_excludes dirs in
  let xs = uniq_list (List.map (bind_dir state bsym_table env rs) includes) in
  let includes = get_includes state bsym_table rs xs in
  let tables = List.map (pub_table_dir state bsym_table env false) includes in
  tables

and mk_bare_env state bsym_table index =
  let sym = hfind "lookup" state.sym_table index in
  (index, sym.Flx_sym.id, sym.Flx_sym.privmap, [], TYP_tuple []) ::
  match sym.Flx_sym.parent with
  | None -> []
  | Some index -> mk_bare_env state bsym_table index

and merge_directives state bsym_table rs env dirs typeclasses =
  let env = ref env in
  let add table =
   env :=
     match !env with
     | (idx, id, nm, nms,con) :: tail ->
     (idx, id, nm,  table :: nms,con) :: tail
     | [] -> assert false
  in
  let use_map = Hashtbl.create 97 in
  add use_map;

  let add_qn (vs, qn) =
    if List.mem (vs,qn) rs.open_excludes then () else
    begin
      (*
      print_endline ("ADD vs=" ^ catmap "," (fun (s,i,_)->s^ "<"^si i^">") (fst vs) ^ " qn=" ^ string_of_qualified_name qn);
      *)
      let u = [bind_dir state bsym_table !env rs (vs,qn)] in
      (*
      print_endline "dir bound!";
      *)
      let u = get_includes state bsym_table rs u in
      (*
      print_endline "includes got, doing pub_table_dir";
      *)
      let tables = List.map (pub_table_dir state bsym_table !env false) u in
      (*
      print_endline "pub table dir done!";
      *)
      List.iter add tables
    end
  in
  List.iter
  (fun (sr,dir) -> match dir with
  | DIR_inject_module qn -> add_qn (dfltvs,qn)
  | DIR_use (n,qn) ->
    begin let entry,_ = lookup_qn_in_env2' state bsym_table !env rs qn in
    match entry with

    | NonFunctionEntry _ ->
      if Hashtbl.mem use_map n
      then failwith "Duplicate non function used"
      else Hashtbl.add use_map n entry

    | FunctionEntry ls ->
      let entry2 =
        try Hashtbl.find use_map  n
        with Not_found -> FunctionEntry []
      in
      match entry2 with
      | NonFunctionEntry _ ->
        failwith "Use function and non-function kinds"
      | FunctionEntry ls2 ->
        Hashtbl.replace use_map n (FunctionEntry (ls @ ls2))
    end

  | DIR_open (vs,qn) -> add_qn (vs,qn)
 )
 dirs;

 (* these should probably be done first not last, because this is
 the stuff passed through the function interface .. the other
 opens are merely in the body .. but typeclasses can't contain
 modules or types at the moment .. only functions .. so it
 probably doesn't matter
 *)
 List.iter add_qn typeclasses;
 !env

and merge_opens state bsym_table env rs (typeclasses,opens,includes,uses) =
  (*
  print_endline ("MERGE OPENS ");
  *)
  let use_map = Hashtbl.create 97 in
  List.iter
  (fun (n,qn) ->
    let entry,_ = lookup_qn_in_env2' state bsym_table env rs qn in
    match entry with

    | NonFunctionEntry _ ->
      if Hashtbl.mem use_map n
      then failwith "Duplicate non function used"
      else Hashtbl.add use_map n entry

    | FunctionEntry ls ->
      let entry2 =
        try Hashtbl.find use_map  n
        with Not_found -> FunctionEntry []
      in
      match entry2 with
      | NonFunctionEntry _ ->
        failwith "Use function and non-function kinds"
      | FunctionEntry ls2 ->
        Hashtbl.replace use_map n (FunctionEntry (ls @ ls2))
  )
  uses
  ;

  (* convert qualified names to i,ts format *)
  let btypeclasses = List.map (bind_dir state bsym_table env rs) typeclasses in
  let bopens = List.map (bind_dir state bsym_table env rs) opens in

  (* HERE! *)

  let bincludes = List.map (bind_dir state bsym_table env rs) includes in

  (*
  (* HACK to check open typeclass *)
  let _ =
    let xs = get_includes state rs bopens in
    let tables = List.map (pub_table_dir state env true) xs in
    ()
  in
  *)
  (* strip duplicates *)
  let u = uniq_cat [] btypeclasses in
  let u = uniq_cat u bopens in
  let u = uniq_cat u bincludes in

  (* add on any inherited modules *)
  let u = get_includes state bsym_table rs u in

  (* convert the i,ts list to a list of lookup tables *)
  let tables = List.map (pub_table_dir state bsym_table env false) u in

  (* return the list with the explicitly renamed symbols prefixed
     so they can be used for clash resolution
  *)
  use_map::tables

and build_env'' state bsym_table rs index : env_t =
  let sym = hfind "lookup" state.sym_table index in
  let skip_merges = List.mem index rs.idx_fixlist in
  (*
  if skip_merges then
    print_endline ("WARNING: RECURSION: Build_env'' " ^ id ^":" ^ si index ^ " parent="^(match parent with None -> "None" | Some i -> si i))
  ;
  *)

  let rs = { rs with idx_fixlist = index :: rs.idx_fixlist } in
  let env = inner_build_env state bsym_table rs sym.Flx_sym.parent in

  (* build temporary bare innermost environment with a full parent env *)
  let typeclasses, constraints = 
    let _, { raw_type_constraint=con; raw_typeclass_reqs=rtcr } =
      sym.Flx_sym.vs
    in
    rtcr,con
  in
  let env = (index, sym.Flx_sym.id, sym.Flx_sym.privmap, [], constraints) :: env in

  (* exit early if we don't need to do any merges *)
  if skip_merges then env else
  (*
  print_endline ("Build_env'' " ^ id ^":" ^ si index ^ " parent="^(match parent with None -> "None" | Some i -> si i));
  print_endline ("Privmap=");
  Hashtbl.iter (fun s _ ->  print_endline s) table ;
  *)

  (* use that env to process directives and type classes *)
  (*
  if typeclasses <> [] then
    print_endline ("Typeclass qns=" ^ catmap "," string_of_qualified_name typeclasses);
  *)
  let typeclasses = List.map (fun qn -> dfltvs,qn) typeclasses in

  (*
  print_endline ("MERGE DIRECTIVES for " ^ id);
  *)
  let env = merge_directives state bsym_table rs env sym.Flx_sym.dirs typeclasses in
  (*
  print_endline "Build_env'' complete";
  *)
  env

and inner_build_env state bsym_table rs parent : env_t =
  match parent with
  | None -> []
  | Some i ->
    try
      let env = Hashtbl.find state.env_cache i in
      env
    with
      Not_found ->
       let env = build_env'' state bsym_table rs i in
       Hashtbl.add state.env_cache i env;
       env

and build_env state bsym_table parent : env_t =
  (*
  print_endline ("Build env " ^ match parent with None -> "None" | Some i -> si i);
  *)
  inner_build_env state bsym_table rsground parent


(*===========================================================*)
(* MODULE STUFF *)
(*===========================================================*)

(* This routine takes a bound type, and produces a unique form
   of the bound type, by again factoring out type aliases.
   The type aliases can get reintroduced by map_type,
   if an abstract type is mapped to a typedef, so we have
   to factor them out again .. YUK!!
*)

and rebind_btype state bsym_table env sr ts t: btypecode_t =
  let rbt t = rebind_btype state bsym_table env sr ts t in
  match t with
  | BTYP_inst (i,_) ->
    begin match get_data state.sym_table i with
    | { Flx_sym.symdef=SYMDEF_type_alias t'} ->
      inner_bind_type state bsym_table env sr rsground t'
    | _ -> t
    end

  | BTYP_typesetunion ts -> BTYP_typesetunion (List.map rbt ts)
  | BTYP_typesetintersection ts -> BTYP_typesetintersection (List.map rbt ts)

  | BTYP_tuple ts -> BTYP_tuple (List.map rbt ts)
  | BTYP_record ts ->
      let ss,ts = List.split ts in
      BTYP_record (List.combine ss (List.map rbt ts))

  | BTYP_variant ts ->
      let ss,ts = List.split ts in
      BTYP_variant (List.combine ss (List.map rbt ts))

  | BTYP_typeset ts ->  BTYP_typeset (List.map rbt ts)
  | BTYP_intersect ts ->  BTYP_intersect (List.map rbt ts)

  | BTYP_sum ts ->
    let ts = List.map rbt ts in
    if all_units ts then
      BTYP_unitsum (List.length ts)
    else
      BTYP_sum ts

  | BTYP_function (a,r) -> BTYP_function (rbt a, rbt r)
  | BTYP_cfunction (a,r) -> BTYP_cfunction (rbt a, rbt r)
  | BTYP_pointer t -> BTYP_pointer (rbt t)
  | BTYP_array (t1,t2) -> BTYP_array (rbt t1, rbt t2)

  | BTYP_unitsum _
  | BTYP_void
  | BTYP_fix _ -> t

  | BTYP_var (i,mt) -> clierr sr ("[rebind_type] Unexpected type variable " ^ sbt bsym_table t)
  | BTYP_apply _
  | BTYP_typefun _
  | BTYP_type _
  | BTYP_type_tuple _
  | BTYP_type_match _
    -> clierr sr ("[rebind_type] Unexpected metatype " ^ sbt bsym_table t)


and check_module state name sr entries ts =
    begin match entries with
    | NonFunctionEntry (index) ->
        let sym = get_data state.sym_table (sye index) in
        begin match sym.Flx_sym.symdef with
        | SYMDEF_module ->
            Simple_module (sye index, ts, sym.Flx_sym.pubmap, sym.Flx_sym.dirs)
        | SYMDEF_typeclass ->
            Simple_module (sye index, ts, sym.Flx_sym.pubmap, sym.Flx_sym.dirs)
        | _ ->
            clierr sr ("Expected '" ^ sym.Flx_sym.id ^ "' to be module in: " ^
            Flx_srcref.short_string_of_src sr ^ ", found: " ^
            Flx_srcref.short_string_of_src sym.Flx_sym.sr)
        end
    | _ ->
      failwith
      (
        "Expected non function entry for " ^ name
      )
    end

(* the top level table only has a single entry,
  the root module, which is the whole file

  returns the root name, table index, and environment
*)

and eval_module_expr state bsym_table env e : module_rep_t =
  (*
  print_endline ("Eval module expr " ^ string_of_expr e);
  *)
  match e with
  | EXPR_name (sr,name,ts) ->
    let entries = inner_lookup_name_in_env state bsym_table env rsground sr name in
    check_module state name sr entries ts

  | EXPR_lookup (sr,(e,name,ts)) ->
    let result = eval_module_expr state bsym_table env e in
    begin match result with
      | Simple_module (index,ts',htab,dirs) ->
      let env' = mk_bare_env state bsym_table index in
      let tables = get_pub_tables state bsym_table env' rsground dirs in
      let result = lookup_name_in_table_dirs htab tables sr name in
        begin match result with
        | Some x ->
          check_module state name sr x (ts' @ ts)

        | None -> clierr sr
          (
            "Can't find " ^ name ^ " in module"
          )
        end

    end

  | _ ->
    let sr = src_of_expr e in
    clierr sr
    (
      "Invalid module expression " ^
      string_of_expr e
    )

(* ********* THUNKS ************* *)
(* this routine has to return a function or procedure .. *)
let lookup_qn_with_sig
  state
  bsym_table
  sra srn
  env
  (qn:qualified_name_t)
  (signs:btypecode_t list)
=
try
  lookup_qn_with_sig'
    state
    bsym_table
    sra srn
    env rsground
    qn
    signs
with
  | Free_fixpoint b ->
    clierr sra
    ("Recursive dependency resolving name " ^ string_of_qualified_name qn)

let lookup_name_in_env state bsym_table (env:env_t) sr name : entry_set_t =
 inner_lookup_name_in_env state bsym_table (env:env_t) rsground sr name


let lookup_qn_in_env2
  state
  bsym_table
  (env:env_t)
  (qn: qualified_name_t)
  : entry_set_t * typecode_t list
=
  lookup_qn_in_env2' state bsym_table env rsground qn


(* this one isn't recursive i hope .. *)
let lookup_code_in_env state bsym_table env sr qn =
  let result =
    try Some (lookup_qn_in_env2' state bsym_table env rsground qn)
    with _ -> None
  in match result with
  | Some (NonFunctionEntry x,ts) ->
    clierr sr
    (
      "[lookup_qn_in_env] Not expecting " ^
      string_of_qualified_name qn ^
      " to be non-function (code insertions use function entries) "
    )

  | Some (FunctionEntry x,ts) ->
    List.iter
    (fun i ->
      match hfind "lookup" state.sym_table (sye i) with
      | { Flx_sym.symdef=SYMDEF_insert _} -> ()
      | { Flx_sym.id=id; vs=vs; symdef=y} -> clierr sr
        (
          "Expected requirement '"^
          string_of_qualified_name qn ^
          "' to bind to a header or body insertion, instead got:\n" ^
          string_of_symdef y id vs
        )
    )
    x
    ;
    x,ts

  | None -> [mkentry state dfltvs dummy_bid],[]

let lookup_qn_in_env
  state
  bsym_table
  (env:env_t)
  (qn: qualified_name_t)
  : entry_kind_t  * typecode_t list
=
  lookup_qn_in_env' state bsym_table env rsground qn


let lookup_uniq_in_env
  state
  bsym_table
  (env:env_t)
  (qn: qualified_name_t)
  : entry_kind_t  * typecode_t list
=
  match lookup_qn_in_env2' state bsym_table env rsground qn with
    | NonFunctionEntry x,ts -> x,ts
    | FunctionEntry [x],ts -> x,ts
    | _ ->
      let sr = src_of_qualified_name qn in
      clierr sr
      (
        "[lookup_uniq_in_env] Not expecting " ^
        string_of_qualified_name qn ^
        " to be non-singleton function set"
      )

(*
let lookup_function_in_env
  state
  bsym_table
  (env:env_t)
  (qn: qualified_name_t)
  : entry_kind_t  * typecode_t list
=
  match lookup_qn_in_env2' state bsym_table env rsground qn with
    | FunctionEntry [x],ts -> x,ts
    | _ ->
      let sr = src_of_expr (qn:>expr_t) in
      clierr sr
      (
        "[lookup_qn_in_env] Not expecting " ^
        string_of_qualified_name qn ^
        " to be non-function or non-singleton function set"
      )

*)

let lookup_sn_in_env
  state
  bsym_table
  (env:env_t)
  (sn: suffixed_name_t)
  : bid_t * btypecode_t list
=
  let sr = src_of_suffixed_name sn in
  let bt t = inner_bind_type state bsym_table env sr rsground t in
  match sn with
  | #qualified_name_t as x ->
    begin match
      lookup_qn_in_env' state bsym_table env rsground x
    with
    | index,ts -> (sye index), List.map bt ts
    end

  | `AST_suffix (sr,(qn,suf)) ->
    let bsuf = inner_bind_type state bsym_table env sr rsground suf in
    (* OUCH HACKERY *)
    let ((be,t) : tbexpr_t) =
      lookup_qn_with_sig' state bsym_table sr sr env rsground qn [bsuf]
    in match be with
    | BEXPR_name (index,ts) ->
      index,ts
    | BEXPR_closure (index,ts) -> index,ts

    | _ -> failwith "Expected expression to be index"

let bind_type state bsym_table env sr t : btypecode_t =
  inner_bind_type state bsym_table env sr rsground t

let bind_expression state bsym_table env e  =
  inner_bind_expression state bsym_table env rsground e

let type_of_index state bsym_table (index:bid_t) : btypecode_t =
 type_of_index' state bsym_table rsground index

let type_of_index_with_ts state bsym_table sr (index:bid_t) ts =
 type_of_index_with_ts' state bsym_table rsground sr index ts
