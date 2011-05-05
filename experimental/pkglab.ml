open Common
open CudfAdd
open Algo

module Package =
struct
	type t = Cudf.package

	let compare = Cudf.(<%)
end;;
module PS = Set.Make(Package);;

(*** [load] reads a source of package metadata from [url] and returns a universe
     together with the efficient internal representation (in mdf format) 
     which is necessary to quickly perform operations on the dependency graph
*)

let load url =
begin
	let (univ, _, _) = Boilerplate.load_universe [url] in
	let mdf = Mdf.load_from_universe univ in
	(univ, mdf)
end;;

let original_version p =
	Cudf.lookup_package_property p "number";;

let get_packages ?filter (u, mdf) =
	Cudf.get_packages ?filter u;;

let search_packages (u, mdf) re =
  let rex = Pcre.regexp re in
   Cudf.get_packages 
    ~filter:(fun p -> Pcre.pmatch ~rex (Cudf_types_pp.string_of_pkgname p.Cudf.package))
		u
;;

let trim (u, mdf) = 
	let trimmed_pkgs = ref [] in
	let callback (res, req) =
	begin
		match res with
		| Diagnostic_int.Success _ ->
			begin
				match req with
				| Diagnostic_int.Sng p ->
						trimmed_pkgs := (mdf.Mdf.maps.map#inttovar p)::!trimmed_pkgs
				| _ -> assert false
			end
		| Diagnostic_int.Failure _ -> ()
	end in
  ignore (Depsolver_int.univcheck ~callback mdf);
	let u' = Cudf.load_universe !trimmed_pkgs in
  (u', Mdf.load_from_universe u')
;;

let cone ?maxdepth ?conjunctive (_, mdf) pl : Cudf.package list =
  let maps = mdf.Mdf.maps in
  let idlist = List.rev_map maps.map#vartoint pl in
  let closure =
		Depsolver_int.dependency_closure ?maxdepth ?conjunctive mdf idlist in
  List.rev_map maps.map#inttovar closure
;;

let rev_cone ?maxdepth (_, mdf) pl : Cudf.package list =
  let maps = mdf.Mdf.maps in
  let idlist = List.rev_map maps.map#vartoint pl in
  let reverse = Depsolver_int.reverse_dependencies mdf in
  let closure =
		Depsolver_int.reverse_dependency_closure ?maxdepth reverse idlist in
  List.rev_map maps.map#inttovar closure
;;

let filter_packages f (u, _) =
	List.rev (Cudf.fold_packages (fun acc p -> if f p then p::acc else acc) [] u)
;;

let provides_set (u, mdf) p =
	List.fold_left (fun acc (pn, pv) ->
		List.fold_left (fun acc' p' ->
			PS.add p' acc'
		) acc (mdf.who_provides (pn, (pv :> Cudf_types.constr)))
	) PS.empty p.Cudf.provides
;;

let conflicts_set (u, _) p =
	List.fold_left (fun acc (cn, cv) ->
		List.fold_left (fun acc' c ->
			PS.add c acc'
		) acc (Cudf.lookup_packages ~filter:cv u cn)
	) PS.empty p.Cudf.conflicts
;;

(* XXX it probably would be advisable to initialise the solver while loading *)
let check (u, mdf) (* slv *) p =
	let req = Diagnostic_int.Sng (mdf.Mdf.maps.map#vartoint p) in
	let slv = Depsolver_int.init_solver mdf.Mdf.index in
	let res = Depsolver_int.solve slv req in
		match res with
		| Diagnostic_int.Success _ -> true
		| Diagnostic_int.Failure _ -> false
;;	

let check_together (u, mdf) l =
	let req = Diagnostic_int.Lst (List.rev_map mdf.Mdf.maps.map#vartoint l) in
	let slv = Depsolver_int.init_solver mdf.Mdf.index in
	let res = Depsolver_int.solve slv req in
		match res with
		| Diagnostic_int.Success _ -> true
		| Diagnostic_int.Failure _ -> false
;;

let install (u, mdf) l =
	let req = Diagnostic_int.Lst (List.rev_map mdf.Mdf.maps.map#vartoint l) in
	let slv = Depsolver_int.init_solver mdf.Mdf.index in
	let res = Depsolver_int.solve slv req in
		match res with
		| Diagnostic_int.Success f -> List.rev_map mdf.Mdf.maps.map#inttovar
				(f ~all:false ())
		| Diagnostic_int.Failure _ -> []
;;

(* TODO: add
 - impactset
 - strongdeps
 - strongconflicts
 - enregistrement pour stateful time optimization
 *) 

(* examples:
(* load a universe from a Debian Packages file *)
let u = load "deb:///var/lib/apt/lists/ftp.be.debian.org_debian_dists_squeeze_main_binary-amd64_Packages";;
(* all packages whose names starts with ocaml *)
let ocamlunits= search_packages u "^ocaml";;
(* union of the cones of 2 OCaml packages *)
let c12 = let (a::b::_) = ocamlunits in cone u [a;b];;
(* packages with self conflicts on provides *)
let l = filter_packages (fun p -> not (PS.is_empty (PS.inter (provides_set u p) (conflicts_set u p)))) u;;
(* compute list of packages with the size of their cones *)
let ul = Cudf.get_packages (fst u);;
let cl = List.map (fun p -> (p,cone u [p])) ul;;
let conesizes = List.map 
   (fun (p,cone) -> 
   (p.Cudf.package,original_version p, List.length cone)) 
   cl;;
 *)
