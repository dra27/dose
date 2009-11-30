(**************************************************************************************)
(*  Copyright (c) 2009 Jaap Boender                                                   *)
(*  Copyright (C) 2009 Mancoosi Project                                               *)
(*                                                                                    *)
(*  This library is free software: you can redistribute it and/or modify              *)
(*  it under the terms of the GNU Lesser General Public License as                    *)
(*  published by the Free Software Foundation, either version 3 of the                *)
(*  License, or (at your option) any later version.  A special linking                *)
(*  exception to the GNU Lesser General Public License applies to this                *)
(*  library, see the COPYING file for more information.                               *)
(**************************************************************************************)

open Common
open ExtLib
open Cudf
open Cudf_types

let outchan = ref stdout;;

let usage = Printf.sprintf "usage: %s [--debug] [--output file] uri" Sys.argv.(0);;
let options = [
  ("--debug", Arg.Unit (fun () -> Util.set_verbosity Util.Summary), "Print debug information");
  ("--output", Arg.String (fun s -> outchan := open_out s), "Send output to a file");
];;

let _ =
let uri = ref "" in
begin
  at_exit (fun () -> Util.dump Format.err_formatter);
  let _ =
    try Arg.parse options (fun f -> uri := f) usage
    with Arg.Bad s -> failwith s
  in
  if !uri == "" then
  begin
    Arg.usage options (usage ^ "\nNo input file specified");
    exit 2
  end;

  Printf.eprintf "Parsing...%!";
  let timer = Util.Timer.create "Parsing" in
  Util.Timer.start timer;
  let u = match Input.parse_uri !uri with
  | ("deb", (_,_,_,_,file),_) ->
    begin
      let l = Debian.Packages.input_raw [file] in
      Debian.Debcudf.load_universe l
    end
  | ("cudf", (_,_,_,_,file),_) ->
    begin
      let (_, u, _) = Cudf_parser.load_from_file file in
      u
    end
  | (s, _, _) -> failwith (Printf.sprintf "%s: not supported\n" s) in
  ignore (Util.Timer.stop timer ());
  Printf.eprintf "done\n%!";

  Depsolver.output_clauses !outchan u
end;;
