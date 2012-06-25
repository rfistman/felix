open Flx_btype
open Flx_bbdcl

(* Count number of cases in variant *)
let rec cal_variant_cases bsym_table t =
  match t with
  | BTYP_void -> 0
  | BTYP_sum ls -> List.length ls
  | BTYP_unitsum i -> i
  | BTYP_variant ls -> List.length ls
  | BTYP_inst (i,ts) ->
    let bsym =
      try Flx_bsym_table.find bsym_table i with Not_found -> assert false
    in
    begin match Flx_bsym.bbdcl bsym with
    (* special: we take the max of declared constructors and the maximum user defined index
     * It's not clear this is right, however the index actually stored in a packed pointer
     * is the user asssigned one so it has to fit. Note: we have to use the assigned value + 1,
     * since we're calculating a case count, an 0 .. n is n+1 cases. We're assuming non-negative
     * values here .. urrggg.. review this!
     *)
    | BBDCL_union (bvs,cts) -> List.fold_left (fun a (s,i,t) -> max a (i+1)) (List.length cts) cts
    | x -> failwith 
        ("cal variant cases of non-variant nominal type " ^ 
          Flx_print.string_of_bbdcl bsym_table x i 
        )
    end
  | BTYP_tuple ls ->
    List.fold_left (fun acc t -> acc * cal_variant_cases bsym_table t) 1 ls

  | _ -> assert false 

(* size of data type in machine words, 2 means 2 or more *)
let size t = match t with
  | BTYP_void -> -1
  | BTYP_tuple [] -> 0

  | BTYP_pointer _ 
  | BTYP_function _
  | BTYP_cfunction _
  | BTYP_unitsum _ 
    -> 1
  | _ -> 2

let rec cal_variant_maxarg bsym_table t =
  match t with
  | BTYP_void -> -1 (* special for void *)
  | BTYP_sum ls -> List.fold_left (fun r t -> max r (size t)) 0 ls
  | BTYP_unitsum i -> 0
  | BTYP_variant ls -> List.fold_left (fun r (_,t) -> max r (size t)) 0 ls
  | BTYP_inst (i,ts) ->
    let bsym =
      try Flx_bsym_table.find bsym_table i with Not_found -> assert false
    in
    begin match Flx_bsym.bbdcl bsym with
    | BBDCL_union (bvs,cts) -> 
      (* Note hack: ignore type variables .. might come back to bite us
       * Means that a polymorphic variant might not have optimal size
       * if a type variable were instantiated with a small size, but
       * hopefully this will be consistent!
       *)
      List.fold_left (fun r (_,_,t) -> max r (size t)) 0  cts
    | _ -> assert false 
    end
  | BTYP_tuple ls ->
    (* not really sure about this ... *)
    List.fold_left (fun r t -> r + cal_variant_maxarg bsym_table t) 0 ls

  | _ -> assert false 

let isnullptr bsym_table t = match t with
  | BTYP_inst (i,_) ->
    let bsym =
      try Flx_bsym_table.find bsym_table i with Not_found -> assert false
    in
    begin match Flx_bsym.bbdcl bsym with
    | BBDCL_union (bvs,[id1,0,BTYP_void; id2, 1, t2]) -> true
(*
      begin
        match t2 with
        | BTYP_pointer _
        | BTYP_function _
        | BTYP_cfunction _ -> true
        | _ -> false
      end 
*)
    | _ -> false
    end
  | _ -> false

type variant_rep = VR_self | VR_int |  VR_nullptr | VR_packed | VR_uctor

let cal_variant_rep bsym_table t =
  if isnullptr bsym_table t then 
    begin
      (* print_endline ("type " ^ Flx_print.sbt bsym_table t ^" is a VR_nullptr"); *)
      VR_nullptr
    end
  else
  let n = cal_variant_cases bsym_table t in
  let z = cal_variant_maxarg bsym_table t in
  let rep =
    match n,z with
    | -1,_ -> assert false
  (* Remove this case temporarily because it is a bit tricky to implement *)
    | 1,_ -> VR_self                  (* only one case do drop variant *)
    | _,0 -> VR_int                  (* no arguments, just use an int *)
    | k,_ when k <= 4 -> VR_packed   (* At most 4 cases, encode caseno in point low bits *)
    | _,_ -> VR_uctor                (* Standard Uctor *)

  in 
  (*
    (print_endline 
    (match rep with
    | VR_self -> "VR_self"
    | VR_int -> "VR_int"
    | VR_packed -> "VR_packed"
    | VR_uctor -> "VR_uctor"
  )) ; 
  *)
rep
