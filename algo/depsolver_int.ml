(**************************************************************************************)
(*  Copyright (C) 2009 Pietro Abate <pietro.abate@pps.jussieu.fr>                     *)
(*  Copyright (C) 2009 Mancoosi Project                                               *)
(*                                                                                    *)
(*  This library is free software: you can redistribute it and/or modify              *)
(*  it under the terms of the GNU Lesser General Public License as                    *)
(*  published by the Free Software Foundation, either version 3 of the                *)
(*  License, or (at your option) any later version.  A special linking                *)
(*  exception to the GNU Lesser General Public License applies to this                *)
(*  library, see the COPYING file for more information.                               *)
(**************************************************************************************)

(** Dependency solver. Low Level API *)

(** Implementation of the EDOS algorithms (and more). This module respect the cudf semantic. *)

open ExtLib
open Common

(** progress bar *)
let progressbar_init = Util.Progress.create "Depsolver_int.init_solver"
let progressbar_univcheck = Util.Progress.create "Depsolver_int.univcheck"

module R = struct type reason = Diagnostic_int.reason end
module S = EdosSolver.M(R)

(** associate a sat solver variable to a package id
    if size = 0 then the mapping is the identity function *)
class intprojection size = object

  val vartoint = Hashtbl.create (2 * size)
  val inttovar = Array.create size 0
  val mutable counter = 0

  (** add a package id to the map *)
  method add v =
    if (size = 0) then assert false ;
    if (counter > size - 1) then assert false;
    (* Printf.eprintf "var %d -> int %d\n%!" v counter; *)
    Hashtbl.add vartoint v counter;
    inttovar.(counter) <- v;
    counter <- counter + 1

  (** given a package id return a sat solver variable *)
  method vartoint v =
    if size = 0 then v
    else Hashtbl.find vartoint v
      
  (* given a sat solver variable return a package id *)
  method inttovar i =
    if size = 0 then i else begin
      if (i > size - 1) then assert false;
      inttovar.(i)
    end
end

(** low level solver data type *)
type solver = {
  constraints : S.state ; (** the sat problem *)
  conflicts : int ;       (** total number of conflicts *)
  disjunctions : int ;    (** total number of disjunctions *)
  dependencies : int ;    (** total number of dependencies *)
  map : intprojection;    (** map a package id to a sat solver variable *)
  proxy : int -> int;     (** return the index of a proxy variable. 
                              Proxy variables are numbered from 0 to proxy_size - 1 *)
  nr_variables : int ;    (** number of non-proxy variables *)
}

(** low level constraint solver initialization
 
    @param buffer debug buffer to print out debug messages
    @param proxy_size  proxy variables. These are additional variables 
                       used to encode specific contraint.
    @param closure init the solver with a subset of packages. This must be
                   the **dependency closure** of the subset of packages.
    @param index package index
 *)
let init_solver ?(buffer=false) ?(proxy_size=0) ?closure index =
  let num_conflicts = ref 0 in
  let num_disjunctions = ref 0 in
  let num_dependencies = ref 0 in

  (* add dependencies *)
  let exec_depends map constraints pkg_id pkg =
    let satvar = map#vartoint pkg_id in
    let lit = S.lit_of_var satvar false in
    for i = 0 to (Array.length pkg.Mdf.depends) - 1 do
      incr num_dependencies;
      let (vpkg,disjunction,_) = pkg.Mdf.depends.(i) in
      if Array.length disjunction = 0 then
        S.add_un_rule constraints lit [Diagnostic_int.EmptyDependency(pkg_id,vpkg)]
      else begin
        let lit_array =
          let a =
            Array.map (fun i -> 
              incr num_disjunctions;
              S.lit_of_var (map#vartoint i) true
            ) disjunction
          in
          Array.append [|lit|] a
        in
        S.add_rule constraints lit_array
        [Diagnostic_int.Dependency(pkg_id,Array.to_list disjunction)]
        ;
        if Array.length disjunction > 1 then
          S.associate_vars constraints
          (S.lit_of_var satvar true)
          (List.map map#vartoint (Array.to_list disjunction))
      end
    done
  in

  (* add conflicts *)
  let exec_conflicts map constraints pkg_id1 pkg =
    try
      let conjunction = pkg.Mdf.conflicts in
      let x = S.lit_of_var (map#vartoint pkg_id1) false in 
      for i = 0 to (Array.length conjunction) - 1 do
        let (_, pkg_id2) = conjunction.(i) in
        if pkg_id1 <> pkg_id2 then begin
            let y = S.lit_of_var (map#vartoint pkg_id2) false in
            incr num_conflicts;
            S.add_bin_rule constraints x y [Diagnostic_int.Conflict(pkg_id1, pkg_id2)]
        end
      done
    with Not_found ->
      (* ignore conflicts that are not in the closure.
       * if nobody depends on a conflict package, then it is irrelevant.
       * This requires a leap of faith in the user ability to build an
       * appropriate closure. If the closure is wrong, you are on your own *)
      (* Util.print_warning "Conflict for package %s not in the universe!\n" pkg.Mdf.pkg.Cudf.package *)
      ()
  in

  let nvars = 
    if Option.is_none closure then Array.length index
    else List.length (Option.get closure)
  in

  let size = nvars + proxy_size in
  Util.Progress.set_total progressbar_init size ;

  let constraints = S.initialize_problem ~buffer size in

  let proxy =
    let a = Array.init proxy_size (fun i -> nvars + i) in 
    fun i -> try a.(i) with _ -> assert false
  in

  let map =
    (* intprojection 0 => identity function *)
    if Option.is_none closure then new intprojection 0
    else new intprojection size
  in

  if Option.is_none closure then
    for i = 0 to (Array.length index) - 1 do
      Util.Progress.progress progressbar_init;
      exec_depends map constraints i index.(i);
      exec_conflicts map constraints i index.(i); 
    done
  else begin
    let closure = Option.get closure in
    List.iter map#add closure;
    List.iter (fun i ->
      Util.Progress.progress progressbar_init;
      exec_depends map constraints i index.(i);
      exec_conflicts map constraints i index.(i);
    ) closure
  end;

  S.propagate constraints ;
  {
    constraints = constraints ;
    conflicts = !num_conflicts ;
    dependencies = !num_dependencies ;
    disjunctions = !num_disjunctions ;
    map = map ;
    proxy = proxy ;
    nr_variables = nvars ;
  }
;;

(** return a copy of the state of the solver *)
let copy_solver solver =
  { solver with constraints = S.copy solver.constraints }

(** low level call to the sat solver *)
let solve solver request =
  S.reset solver.constraints;

  let result solve collect ?(proxies=[]) var =
    if solve solver.constraints var then begin
      let get_assignent () =
        let l = ref [] in
        Array.iteri (fun i v ->
          if v = S.True then
            if not(List.mem i proxies) then
              l := (solver.map#inttovar i) :: !l
        ) (S.assignment solver.constraints);
        !l
      in
      Diagnostic_int.Success(get_assignent)
    end
    else
      let get_reasons () = collect solver.constraints var in
      Diagnostic_int.Failure(get_reasons)
  in

  match request with
  |Diagnostic_int.Req i ->
      let proxy_var = solver.proxy i in
      result S.solve S.collect_reasons ~proxies:[proxy_var] proxy_var
  |Diagnostic_int.Sng i ->
      result S.solve S.collect_reasons (solver.map#vartoint i)
  |Diagnostic_int.Lst il ->
      result S.solve_lst S.collect_reasons_lst (List.map solver.map#vartoint il)
;;

(***********************************************************)

(** [reverse_dependencies index] return an array that associates to a package id
    [i] the list of all packages ids that have a dependency on [i].

    @param index the package universe
*)
let reverse_dependencies mdf =
  let index = mdf.Mdf.index in
  let size = Array.length index in
  let reverse = Array.create size [] in
  let rev i dl = 
    Array.iter (fun (_,a,_) ->
      Array.iter (fun j ->
        if i <> j then
          if not(List.mem i reverse.(j)) then
            reverse.(j) <- i::reverse.(j)
      ) a
    ) dl
  in
  for i = 0 to size - 1 do rev i index.(i).Mdf.depends done;
  reverse

(** [dependency_closure index l] return the union of the dependency closure of
    all packages in [l] .

    @param maxdepth the maximum cone depth (infinite by default)
    @param conjuntive consider only conjuntive dependencies (false by default)
    @param index the package universe
    @param l a subset of [index]
*)
let dependency_closure ?(maxdepth=max_int) ?(conjuntive=false) mdf =
  let h = Hashtbl.create (Array.length mdf.Mdf.index) in
  fun idlist ->
    try Hashtbl.find h (idlist,conjuntive,maxdepth)
    with Not_found -> begin
      let index = mdf.Mdf.index in
      let queue = Queue.create () in
      let visited = Hashtbl.create (2 * (List.length idlist)) in
      List.iter (fun e -> Queue.add (e,0) queue) (List.unique idlist);
      while (Queue.length queue > 0) do
        let (id,level) = Queue.take queue in
        if not(Hashtbl.mem visited id) && level < maxdepth then begin
          Hashtbl.add visited id ();
          Array.iter (function
            |(_,[|i|],_) when conjuntive = true ->
              if not(Hashtbl.mem visited i) then
                Queue.add (i,level+1) queue
            |(_,dsj,_) when conjuntive = false ->
              Array.iter (fun i ->
                if not(Hashtbl.mem visited i) then
                  Queue.add (i,level+1) queue
              ) dsj
            |_ -> ()
          ) index.(id).Mdf.depends
        end
      done;
      let result = Hashtbl.fold (fun k _ l -> k::l) visited [] in
      Hashtbl.add h (idlist,conjuntive,maxdepth) result;
      result
    end

(*    XXX : elements in idlist should be included only if because
 *    of circular dependencies *)
(** return the dependency closure of the reverse dependency graph.
    The visit is bfs.    

    @param maxdepth the maximum cone depth (infinite by default)
    @param index the package universe
    @param idlist a subset of [index]
*)
let reverse_dependency_closure ?(maxdepth=max_int) reverse =
  let h = Hashtbl.create (Array.length reverse) in
  fun idlist ->
    try Hashtbl.find h (idlist,maxdepth)
    with Not_found -> begin
      let queue = Queue.create () in
      let visited = Hashtbl.create (List.length idlist) in
      List.iter (fun e -> Queue.add (e,0) queue) (List.unique idlist);
      while (Queue.length queue > 0) do
        let (id,level) = Queue.take queue in
        if not(Hashtbl.mem visited id) && level < maxdepth then begin
          Hashtbl.add visited id ();
          List.iter (fun i ->
            if not(Hashtbl.mem visited i) then
              Queue.add (i,level+1) queue
          ) reverse.(id)
        end
      done;
      let result = Hashtbl.fold (fun k _ l -> k::l) visited [] in
      Hashtbl.add h (idlist,maxdepth) result;
      result
    end

(***********************************************************)

let pkgcheck callback solver failed tested id =
  try
    let req = Diagnostic_int.Sng id in
    let res =
      if not(tested.(id)) then begin
        let res = solve solver req in
        begin match res with
        |Diagnostic_int.Success(f) -> 
            (try
              List.iter (fun i ->
                Util.Progress.progress progressbar_univcheck;
                tested.(i) <- true
              ) (f ())
            with Not_found -> assert false)
        |_ -> incr failed
        end
        ;
        res
      end
      else begin (* we know this package is not broken *)
        let f () = Printf.eprintf
        "Warning: this installation set is empty.\n" ; []
        in Diagnostic_int.Success(f) 
      end
    in
    match callback with
    |None -> ()
    |Some f -> f (res,req) 
  with Not_found -> assert false

(** [listcheck ?callback idlist mdf] check if a subset of packages 
    known by the solver [idlist] are installable

    @param idlist list of packages id to be checked
    @param mdf package index
    @return the number of packages that cannot be installed
*)
let listcheck ?callback mdf idlist =
  let closure = dependency_closure mdf idlist in
  let solver = init_solver ~closure mdf.Mdf.index in
  let timer = Util.Timer.create "Algo.Depsolver.listcheck" in
  Util.Timer.start timer;
  let failed = ref 0 in
  let size = Array.length mdf.Mdf.index in
  Util.Progress.set_total progressbar_univcheck size ;
  let tested = Array.make size false in
  let check = pkgcheck callback solver failed tested in
  List.iter check idlist ;
  Util.Timer.stop timer !failed
;;

(** [univcheck ?callback (mdf,solver)] check if all packages known by 
    the solver are installable. XXX

    @param mdf package index 
    @param solver dependency solver
    @return the number of packages that cannot be installed
*)
let univcheck ?callback (mdf,solver) =
  let timer = Util.Timer.create "Algo.Depsolver.univcheck" in
  Util.Timer.start timer;
  let failed = ref 0 in
  let size = Array.length mdf.Mdf.index in
  let tested = Array.make size false in
  Util.Progress.set_total progressbar_univcheck size ;
  let check = pkgcheck callback solver failed tested in
  for i = 0 to (Array.length mdf.Mdf.index) - 1 do check i done;
  Util.Timer.stop timer !failed
;;
