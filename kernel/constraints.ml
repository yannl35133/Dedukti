(********** universes' variables ************)

let just_check = ref false

module UVar =
struct
  open Basic
  type uvar = ident

  let basename = "?"

  exception NotUvar

  let is_uvar t =
    match t with
    | Term.Const(_,n) ->
      let s = string_of_ident (id n) in
      let n = String.length basename in
      String.length s > n && String.sub s 0 n = basename
    | _ -> false

  let ident_of_uvar t =
    match t with
    | Term.Const(_,n) when is_uvar t -> id n
    | _ -> Format.printf "%a@." Term.pp_term t; raise NotUvar

  let counter = ref 0

  let next () = !counter

  let fresh () =
    let name = Format.sprintf "%s%d" basename !counter in
    incr counter; mk_ident name

  let ident_of_counter n =
    mk_ident (Format.sprintf "%s%d" basename n)

  let fresh_uvar sg =
    let id = fresh () in
    let md = Signature.get_name sg in
    let name = Basic.mk_name md id in
    let cst = Term.mk_Const Basic.dloc name in
    Signature.add_declaration sg Basic.dloc id Signature.Static
      (Term.mk_Const Basic.dloc (Basic.mk_name (Basic.mk_mident "cic") (Basic.mk_ident "Sort")));
    cst

  let count () = !counter
end

module ReverseCiC =
struct
  open Basic

  type univ =
    | Prop
    | Type of int

  let term_of_univ univ =
    let md = Basic.mk_mident "cic" in
    let prop = Basic.mk_ident "prop" in
    let utype = Basic.mk_ident "type" in
    let z = Basic.mk_ident "z" in
    let s = Basic.mk_ident "s" in
    let mk_const id = Term.mk_Const Basic.dloc (Basic.mk_name md id) in
    let rec term_of_nat i =
      assert (i>= 0);
      if i = 0 then
        mk_const z
      else
        Term.mk_App (mk_const s) (term_of_nat (i-1)) []
    in
    match univ with
    | Prop -> mk_const prop
    | Type i -> Term.mk_App (mk_const utype) (term_of_nat i) []


  let cic = mk_mident "cic"

  let mk_const id = Term.mk_Const dloc (mk_name cic id)

  let z = mk_name cic (mk_ident "z")

  let s = mk_name cic (mk_ident "s")

  let succ = mk_name cic (mk_ident "succ")

  let sort = mk_name cic (mk_ident "Sort")

  let lift = mk_name cic (mk_ident "lift")

  let max = mk_name cic (mk_ident "max")

  let rule = mk_name cic (mk_ident "rule")

  let prop = mk_name cic (mk_ident "prop")

  let type_ = mk_name cic (mk_ident "type")

  let is_const cst t =
    match t with
    | Term.Const(_,n) -> name_eq cst n
    | _ -> false

  let is_prop t =
    match t with
    | Term.Const(_,n) when is_const prop t -> true
    | _ -> false

  let is_type t =
    match t with
    | Term.App(t,_,[]) when is_const type_ t -> true
    | _ -> false

  let is_succ t =
    match t with
    | Term.App(c,arg,[]) when is_const succ c -> true
    | _ -> false

  let is_lift t =
    match t with
    | Term.App(c, s1, [s2;a]) when is_const lift c -> true
    | _ -> false

  let is_max t =
    match t with
    | Term.App(c, s1, [s2]) when is_const max c -> true
    | _ -> false

  let is_rule t =
    match t with
    | Term.App(c, s1, [s2]) when is_const rule c -> true
    | _ -> false

  let extract_type t =
    let rec to_int t =
      match t with
      | Term.Const(_,z) when is_const z t -> 0
      | Term.App(t,u, []) when is_const s t -> 1+(to_int u)
      | _ -> assert false
    in
    match t with
    | Term.App(t,u,[]) when is_const type_ t -> to_int u
    | _ -> failwith "is not a type"

  let extract_succ t =
    match t with
    | Term.App(c,arg,[]) when is_const succ c -> arg
    | _ -> failwith "is not a succ"

  let extract_lift t =
    match t with
    | Term.App(c,s1,[s2;a]) when is_const lift c -> s1,s2
    | _ -> failwith "is not a lift"

  let extract_max t =
    match t with
    | Term.App(c,s1,[s2]) when is_const max c -> s1,s2
    | _ -> failwith "is not a max"

  let extract_rule t =
    match t with
    | Term.App(c, s1, [s2]) when is_const rule c -> s1, s2
    | _ -> failwith "is not a rule"
end



module type ConstraintsInterface =
sig

  type var

  type constraints =
    | Univ of var * ReverseCiC.univ
    | Eq of var * var
    | Max of var * var * var
    | Succ of var * var
    | Rule of var * var * var

  val generate_constraints : Signature.t -> Term.term -> Term.term -> bool
  (** generate_constraints [sg] [l] [r] returns [true] if some constraints has been generated *)

  module ConstraintsSet : Set.S with type elt = constraints

  val export : unit -> ConstraintsSet.t

  val info : ConstraintsSet.t -> string

  val string_of_var : var -> string

  val is_matching : bool ref

  val var_of_ident : Basic.ident -> var

  val optimize : ConstraintsSet.t -> ConstraintsSet.t
end


module Naive (* :ConstraintsInterface with type var = Basic.ident *) =
struct

  open UVar
  open ReverseCiC
  open Basic

  type var = Basic.ident

  type constraints =
    | Univ of var * ReverseCiC.univ
    | Eq of var * var
    | Max of var * var * var
    | Succ of var * var
    | Rule of var * var * var

  module Variables = Set.Make (struct type t = Basic.ident let compare = compare end)

  module ConstraintsSet = Set.Make (struct type t = constraints let compare = compare end)

  module CS = ConstraintsSet

  module UF =
  struct
    let uf = Hashtbl.create 10007

    let rec find l =
      try
        find (Hashtbl.find uf l)
      with _ -> l

    let union l r =
      let l' = find l in
      let r' = find r in
      if l' = r' then
        ()
      else
        Hashtbl.add uf l' r'

  end

  let is_matching = ref false

  let init = ref false

  let var_of_ident ident = UF.find ident

  let global_constraints = ref ConstraintsSet.empty

  let add_constraint c =
    global_constraints := ConstraintsSet.add c !global_constraints

  let hash_univ = Hashtbl.create 11


  let find_univ univ =
      if Hashtbl.mem hash_univ univ then
        Hashtbl.find hash_univ univ
      else
        let uvar = UVar.fresh () in
        let vi = var_of_ident uvar in
        Hashtbl.add hash_univ univ vi;
        add_constraint(Univ(vi, univ));
        vi

  let var_of_univ () = Hashtbl.fold (fun k v l -> (v,k)::l) hash_univ []

  let add_constraint_prop =
    fun ident ->
      let v = var_of_ident ident in
      UF.union v (find_univ Prop)
      (* add_constraint (Eq(v, find_univ Prop)) *)

  let add_constraint_type =
    fun v u ->
      let v = var_of_ident v in
      UF.union v (find_univ u)
  (* add_constraint (Eq(v, find_univ u)) *)


  let add_constraint_eq v v' =
    let v = var_of_ident v in
    let v' = var_of_ident v' in
    UF.union v v'
    (* add_constraint (Eq(v,v')) *)

  let add_constraint_succ v v' =
    let v = var_of_ident v in
    let v' = var_of_ident v' in
    if UF.find v = UF.find (find_univ (Type 0)) then
      add_constraint_type v' (Type 1)
    else
      add_constraint (Succ(v,v'))

  let add_constraint_max v v' v'' =
    let v = var_of_ident v in
    let v' = var_of_ident v' in
    let v'' = var_of_ident v'' in
    add_constraint (Max(v,v',v''))

  let add_constraint_rule v v' v'' =
    let v = var_of_ident v in
    let v' = var_of_ident v' in
    let v'' = var_of_ident v'' in
    add_constraint (Rule(v,v',v''))

  let info constraints =
    let open ReverseCiC in
    let prop,ty,neq,eq,succ,max,rule = ref 0, ref 0, ref 0, ref 0, ref 0, ref 0, ref 0 in
    CS.iter (fun x ->
        match x with
        | Univ(_,Prop) -> incr prop
        | Univ (_, Type _) -> incr ty
        (*        | Neq _ -> incr neq *)
        | Eq _ -> incr eq
        | Succ _ -> incr succ
        | Max _ -> incr max
        | Rule _ -> incr rule) constraints;

    let print fmt () =
      Format.fprintf fmt "Variable correspondance:@.";
      Format.fprintf fmt "Number of variables  : %d@." (UVar.count ());
      Format.fprintf fmt "Number of constraints:@.";
      Format.fprintf fmt "@[prop:%d@]@." !prop;
      Format.fprintf fmt "@[ty  :%d@]@." !ty;
      (*    Format.fprintf fmt "@[neq :%d@]@." !neq; *)
      Format.fprintf fmt "@[eq  :%d@]@." !eq;
      Format.fprintf fmt "@[succ:%d@]@." !succ;
      Format.fprintf fmt "@[max :%d@]@." !max;
      Format.fprintf fmt "@[rule:%d@]@." !rule
    in
    Format.asprintf "%a" print ()

  module V = UVar

  let rec extract_universe sg (s:Term.term) =
    if is_uvar s then
       V.ident_of_uvar s
    else if is_rule s then
      begin
        let l = V.ident_of_uvar (V.fresh_uvar sg) in
        let s1,s2 = extract_rule s in
        let s1' = extract_universe sg s1 in
        let s2' = extract_universe sg s2 in
        add_constraint_rule s1' s2' l;
        l
      end
    else
      failwith "don't know what to do yet"

  let rec generate_constraints sg (l:Term.term) (r:Term.term) =
    if !just_check || !is_matching then false
    else
    let open ReverseCiC in
    if is_uvar l && is_prop r then
      let l = ident_of_uvar l in
      add_constraint_prop l;
      true
    else if is_prop l && is_uvar r then
      generate_constraints sg r l
    else if is_uvar l && is_type r then
      let l = ident_of_uvar l in
      let i = extract_type r in
      add_constraint_type l (Type i);
      true
    else if is_type l && is_uvar r then
      generate_constraints sg r l
    else if is_uvar l && is_uvar r then
      let l = ident_of_uvar l in
      let r = ident_of_uvar r in
      add_constraint_eq l r;
      true
    else if is_succ l && is_uvar r then
      begin
        let l = extract_succ l in
        let l = ident_of_uvar l in
        let r = ident_of_uvar r in
        add_constraint_succ l r;
        true
      end
    else if is_uvar l && is_succ r then
      generate_constraints sg r l
    else if is_rule l && is_uvar r then
      let s1,s2 = extract_rule l in
      let s1 = extract_universe sg s1 in
      let s2 = extract_universe sg s2 in
      let r = ident_of_uvar r in
      add_constraint_rule s1 s2 r;
      true
    else if is_uvar l && is_rule r then
      generate_constraints sg r l
    else if is_max l && is_uvar r then
      let s1,s2 = extract_max l in
      let s1 = ident_of_uvar s1 in
      let s2 = ident_of_uvar s2 in
      let r = ident_of_uvar r in
      add_constraint_max s1 s2 r;
      true
    else if is_uvar l && is_max r then
      generate_constraints sg r l
    else if is_max l && is_type r then
      let s1,s2 = extract_max l in
      let s1 = ident_of_uvar s1 in
      let s2 = ident_of_uvar s2 in
      let s3 = find_univ (Type (extract_type r)) in
      add_constraint_max s1 s2 s3;
      true
    else if is_type l && is_max r then
      generate_constraints sg r l
    else if is_rule l && is_type r then
      let s1,s2 = extract_rule l in
      let s1 = ident_of_uvar s1 in
      let s2 = ident_of_uvar s2 in
      let s3 = find_univ (Type (extract_type r)) in
      add_constraint_rule s1 s2 s3;
      true
    else if is_type l && is_rule r then
      generate_constraints sg r l
    else if is_lift l && is_succ r then
      failwith "BUG1"
    else if is_succ l && is_lift r then
      failwith "BUG2"
    else if is_lift l && is_prop r then
      failwith "BUG3"
    else if is_prop l && is_lift r then
      failwith "BUG4"
    else if is_lift l && is_uvar r then
      failwith "BUG5"
    else if is_uvar l && is_lift r then
      failwith "BUG6"
    else if is_succ l && is_prop r then
      failwith "BUG7"
    else if is_prop l && is_succ r then
      failwith "BUG8"
    else if is_prop l && is_rule r then
      failwith "BUG9"
    else if is_rule l && is_prop r then
      failwith "BUG10"
    else if is_succ l && is_type r then
      failwith "BUG11"
    else if is_type l && is_succ r then
      failwith "BUG12"
    else if is_succ l && is_rule r then
      failwith "BUG15"
    else if is_rule l && is_succ r then
      failwith "BUG16"
    else if is_succ l && is_type r then
      failwith "BUG17"
    else if is_type l && is_succ r then
      failwith "BUG18"
    else
      false

  (*
  let normalize_univ uvar n u =
    let find n = UF.find !uf n in
    (false,Some (Univ(find n, u)))

  let normalize_eq uvar n n' =
    let find n = UF.find !uf n in
    uf := UF.union !uf (find n) (find n');
    (true, None)

  let rec normalize_max uvar n n' n'' =
    let find n = UF.find !uf n in
    let n = find n in
    let n' = find n' in
    let n'' = find n'' in
    if n = n' then
      (true, Some (Eq(n,n'')))
    else
      (false, Some (Max(n, n', n'')))

  let normalize_succ uvar n n' =
    let find n = UF.find !uf n in
    let n = find n in
    let n' = find n' in
    if List.mem_assoc n uvar then
      (false,Some (Succ(n,n'))) (* TODO optimize that *)
    else if List.mem_assoc n' uvar then
      failwith "succ todo right"
    else
      (false,Some (Succ(n,n')))

  let normalize_rule uvar n n' n'' : bool * constraints option =
    let find n = UF.find !uf n in
    let n = find n in
    let n' = find n' in
    let n'' = find n'' in
    if n = n' then
      (true, Some (Eq(n,n'')))
    else if List.mem_assoc n' uvar then
      match List.assoc n' uvar with
      | Prop -> (Log.append @@ Format.sprintf "Normalize Rr Prop.";  (true,Some (Univ(n,Prop))))
      | Type(i) ->
        if List.mem_assoc n uvar then
          match List.assoc n uvar with
          | Prop -> Log.append @@ Format.sprintf "Normalize Rl Prop"; (true,Some (Eq(n',n'')))
          | Type(j) -> Log.append @@ Format.sprintf "Normalize Rl Type";
            (false, Some (Max(n, n', n'')))
        else
          (false, Some (Rule(n, n', n'')))
    else
      (false, Some (Rule(n, n', n'')))

  let rec normalize uvar cset =
    let add_opt c set =
      match c with
      | None -> set
      | Some c -> ConstraintsSet.add c set
    in
    let fold cstr (b,set) =
      match cstr with
      | Univ(n,u) -> let b', c = normalize_univ uvar n u in b || b', add_opt c set
      | Eq(n,n')  -> let b', c = normalize_eq uvar n n' in b || b', add_opt c set
      | Max(n,n',n'') -> let b', c = normalize_max uvar n n' n'' in b || b', add_opt c set
      | Succ(n,n') -> let b', c = normalize_succ uvar n n' in b || b', add_opt c set
      | Rule(n,n',n'') -> let b', c = normalize_rule uvar n n' n'' in b || b', add_opt c set
    in
    let (b,set) = ConstraintsSet.fold fold cset (false,ConstraintsSet.empty) in
    if b then normalize uvar set else set
*)

  let string_of_var n = string_of_ident n

  let normalize_eq cstr =
    match cstr with
    | Univ(n,u) -> Univ(UF.find n,u)
    | Eq(n,n') ->
      let n = UF.find n in
      let n' = UF.find n' in
      Eq(n,n')
    | Max(n,n',n'') ->
      let n = UF.find n in
      let n' = UF.find n' in
      let n'' = UF.find n'' in
      Max(n,n',n'')
    | Succ(n,n') ->
      let n = UF.find n in
      let n' = UF.find n' in
      Succ(n, n')
    | Rule(n,n',n'') ->
      let n = UF.find n in
      let n' = UF.find n' in
      let n'' = UF.find n'' in
      Rule(n, n', n'')

  let normalize cstr =
    match cstr with
    | Univ(n,u) -> Some(Univ(UF.find n,u))
    | Eq(n,n') ->
      let n = UF.find n in
      let n' = UF.find n' in
      UF.union n n';
      None
    | Max(n,n',n'') ->
      let n = UF.find n in
      let n' = UF.find n' in
      let n'' = UF.find n'' in
      if n = n' then
        Some(Eq(n,n''))
      else
        Some(Max(n,n',n''))
    | Succ(n,n') ->
      let n = UF.find n in
      let n' = UF.find n' in
      Some(Succ(n, n'))
    | Rule(n,n',n'') ->
      let n = UF.find n in
      let n' = UF.find n' in
      let n'' = UF.find n'' in
      if n = n' then
        Some(Eq(n,n''))
      else if n' = UF.find (find_univ (Type 0)) then
        Some(Max(n,n',n''))
      else if n'' = UF.find (find_univ (Type 0)) then
        Some(Max(n, n', n''))
      else
        Some(Rule(n, n', n''))

  let opt_map f cs =
    ConstraintsSet.fold
      (fun elt cs ->
         match f elt with
         | None -> cs
         | Some c -> ConstraintsSet.add c cs) cs ConstraintsSet.empty


  module VarSet = Set.Make(struct type t = Basic.ident let compare = compare end)

  let get_vars cs =
    ConstraintsSet.fold (fun x vs ->
        match x with
        | Eq(n,n') -> VarSet.add n (VarSet.add n' vs)
        | Succ(n,n') -> VarSet.add n (VarSet.add n' vs)
        | Max(n,n', n'') -> VarSet.add n (VarSet.add n' (VarSet.add n'' vs))
        | Rule(n,n', n'') -> VarSet.add n (VarSet.add n' (VarSet.add n'' vs))
        | Univ(n,_) -> VarSet.add n vs
      ) cs VarSet.empty

  let acc var cs =
    let test vs =
      ConstraintsSet.fold (fun x vs ->
          match x with
          | Eq(n,n') ->
            if VarSet.mem n vs || VarSet.mem n' vs then
              VarSet.add n (VarSet.add n' vs)
            else
              vs
          | Succ(n,n') ->
            if VarSet.mem n vs || VarSet.mem n' vs then
              VarSet.add n (VarSet.add n' vs)
            else
              vs
          | Max(n,n', n'') ->
            if VarSet.mem n vs || VarSet.mem n' vs || VarSet.mem n'' vs  then
              VarSet.add n (VarSet.add n' (VarSet.add n'' vs))
            else
              vs
          | Rule(n,n', n'') ->
            if VarSet.mem n vs || VarSet.mem n' vs || VarSet.mem n'' vs  then
              VarSet.add n (VarSet.add n' (VarSet.add n'' vs))
            else
              vs
          | Univ(n,_) -> vs
        ) cs vs
    in
    let rec fp vs =
      let vs' = test vs in
      if VarSet.equal vs' vs then
        vs
      else
        fp vs'
    in
    fp (VarSet.singleton var)


  let print_acc cs vs =
    VarSet.iter (fun var ->
        Format.eprintf "%d@." (VarSet.cardinal (acc var cs))) vs

  let rec optimize s =
    Format.eprintf "Before optimizations.@.%s@." (info s);
    let cs = ConstraintsSet.map normalize_eq (opt_map normalize s) in
    Format.eprintf "After optimizations.@.%s@." (info cs);
    let vs = get_vars cs in
    Format.eprintf "Real number of variables: %d@." (VarSet.cardinal vs);
    print_acc cs vs;
    cs

  let export () =
    optimize !global_constraints
end
