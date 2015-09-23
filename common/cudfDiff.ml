(**************************************************************************************)
(*  Copyright (C) 2010 Pietro Abate <pietro.abate@pps.jussieu.fr>                     *)
(*  Copyright (C) 2010 Mancoosi Project                                               *)
(*                                                                                    *)
(*  This library is free software: you can redistribute it and/or modify              *)
(*  it under the terms of the GNU Lesser General Public License as                    *)
(*  published by the Free Software Foundation, either version 3 of the                *)
(*  License, or (at your option) any later version.  A special linking                *)
(*  exception to the GNU Lesser General Public License applies to this                *)
(*  library, see the COPYING file for more information.                               *)
(**************************************************************************************)

(** This module compute the difference between a cudf universe and a cudf solution *)

open ExtLib

module Cudf_set = CudfAdd.Cudf_set
module StringSet = CudfAdd.StringSet

type solution = {
  installed : Cudf_set.t ;
  removed : Cudf_set.t ;
}

(* the 'package' is always taken from the universe *)
let to_set univ l =
  List.fold_left (fun s p ->
    let q = Cudf.lookup_package univ (p.Cudf.package,p.Cudf.version) in
    Cudf_set.add q s
  ) Cudf_set.empty l
;;

(* [diff_set univ sol] return a tuple with the set of packages to install and the
   set of packages to remove *)
let diff_set univ sol =
  let is_installed p = p.Cudf.installed in
  let before = CudfAdd.to_set (Cudf.get_packages ~filter:is_installed univ) in
  let after = CudfAdd.to_set (Cudf.get_packages ~filter:is_installed sol) in
  let install = Cudf_set.diff after before in
  let remove = Cudf_set.diff before after in
  (install, remove)

(** [diff univ sol] for each pkgname returns the list of all 
    versions that were installed (in the solution) or removed (from the
    universe) *)
let diff univ sol =
  let pkgnames = CudfAdd.pkgnames univ in
  let h = Hashtbl.create (StringSet.cardinal pkgnames) in
  StringSet.iter (fun pkgname ->
    let were_installed = to_set univ (Cudf.get_installed univ pkgname) in
    let are_installed = to_set univ (Cudf.get_installed sol pkgname) in
    let r = Cudf_set.diff were_installed are_installed in
    let i = Cudf_set.diff are_installed were_installed in
    let s = { removed = r ; installed = i } in
    Hashtbl.add h pkgname s
  ) pkgnames ;
  h

(**
   [all] : all versions of a package in the universe . 
   [s] : the set of version for version of a package in a solution 
   returns a list that contains for each version its status : installed, 
   removed, upgraded, etc
*)
type summary_t = {
  mutable i : Cudf.package list; (* installed *)
  mutable r : Cudf.package list; (* removed *)
  mutable u : (Cudf.package * Cudf.package) option ; (* upgraded *)
  mutable d : (Cudf.package * Cudf.package) option ; (* downgraded *)
  mutable nc : Cudf.package list; (* not changed *)
}

(* for one package *)
let default_summary () = { u = None; d = None ; i = [] ; r = [] ; nc = [] }

(* *)
let uniqueversion all s =
  let l = default_summary () in
  let i = Cudf_set.filter (fun pkg -> pkg.Cudf.installed) all in
  if (Cudf_set.cardinal i <= 1) && ((Cudf_set.cardinal s.installed) <= 1) then
    begin
      if (Cudf_set.cardinal s.installed) = 1 then begin
        if (Cudf_set.cardinal i) = 1 then begin
          let np = Cudf_set.choose i in
          let op = Cudf_set.choose s.installed in
          if np.Cudf.version < op.Cudf.version
          then l.u <- Some(np,op)
          else l.d <- Some(op,np)
        end
        else
          l.i <- Cudf_set.elements s.installed;
      end else
        if not (Cudf_set.is_empty s.removed) then
          l.r <- Cudf_set.elements s.removed;
      end
  else begin
    if not (Cudf_set.is_empty s.removed) then
      l.r <- Cudf_set.elements s.removed;
    if not (Cudf_set.is_empty s.installed) then
      l.i <- Cudf_set.elements s.installed;
  end;
  l.nc <- Cudf_set.elements (Cudf_set.diff i (Cudf_set.union s.installed s.removed));
  l
;;

(* [summary univ diff] return a tuple with 5 lists containing packages
 * installed, upgraded, downgraded, removed, not upgraded 
 * (all packages marked as installed but not in the categories above) *)
let summary univ diff =
  let i = ref [] in
  let u = ref [] in
  let d = ref [] in
  let r = ref [] in
  let nc = ref [] in
  let names = CudfAdd.pkgnames univ in
  StringSet.iter (fun pkgname ->
    let all = CudfAdd.to_set (Cudf.lookup_packages univ pkgname) in
    let s = Hashtbl.find diff pkgname in
    let l = uniqueversion all s in
    i := l.i @ !i ;
    r := l.r @ !r ;
    if not (Option.is_none l.u) then
      u := (Option.get l.u) :: !u;
    if not (Option.is_none l.d) then
      d := (Option.get l.d) :: !d;
    nc := l.nc @ !nc;
  ) names;
  (!i,!u,!d,!r,!nc)
;;
