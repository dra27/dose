
%{

open ExtLib

let parse_relop = function
  | "="  -> `Eq
  | "!=" -> `Neq
  | ">=" -> `Geq
  | ">" | ">>"  -> `Gt
  | "<=" -> `Leq
  | "<" | "<<"  -> `Lt
  | _ -> assert false   (* lexer shouldn't have returned such a RELOP! *)

let parse_multiarch = function
  |("None"|"none") -> "None"
  |("Allowed"|"allowed") -> "Allowed"
  |("Foreign"|"foreign") -> "Foreign"
  |("Same"|"same") -> "Same"
  |s -> raise (Format822.Type_error ("Field Multi-Arch has a wrong value : "^ s))

let parse_request s =
  try 
    let i = String.index s ':' in
    let slen = String.length s in
    let name = String.sub s 0 i in
    let nlen = String.length name in
    let arch = String.sub s (nlen + 1) (slen - nlen -1 ) in
    (name,Some arch)
  with Not_found -> (s,None)
;;

%}

%token <string> IDENT RELOP
%token LBRACKET RBRACKET LPAREN RPAREN
%token COMMA PIPE COLON EQ BANG
%token EOL

%type <Format822.name> pkgname_top
%type <Format822.version> version_top 

%type <Format822.multiarch> multiarch_top 
%type <Format822.source> source_top 

%type <Format822.vpkg> vpkg_top
%type <Format822.vpkglist> vpkglist_top
%type <Format822.vpkgformula> vpkgformula_top

%type <Format822.builddepsformula> builddepsformula_top
%type <Format822.builddepslist> builddepslist_top

%type <Format822.vpkgreq list> request_top
%type <Format822.architecture list> archlist_top

%start pkgname_top version_top
%start multiarch_top source_top
%start vpkg_top vpkglist_top vpkgformula_top
%start builddepsformula_top builddepslist_top
%start request_top archlist_top

%%

pkgname_top: pkgname EOL { $1 } ;
version_top: version EOL { $1 } ;
multiarch_top: multiarch EOL { $1 } ;
source_top: source EOL { $1 } ;

vpkg_top: vpkg EOL { $1 } ;

vpkglist_top: vpkglist EOL { $1 } ;
vpkgformula_top: vpkgformula EOL { $1 } ;

builddepsformula_top: builddepsformula EOL { $1 } ;
builddepslist_top: builddepslist EOL { $1 } ;

request_top: reqlist EOL { $1 } ;
archlist_top: archlist EOL { $1 } ;

/**************************************/ 

pkgname: IDENT { $1 } ;
version: IDENT { $1 } ;
multiarch: IDENT { parse_multiarch $1 }

source:
  |IDENT                        { ($1,None) }
  |IDENT LPAREN version RPAREN  { ($1,Some ($3)) }

relop:
  | RELOP       { $1 }
  | EQ          { "=" }
;

/**************************************/ 

constr:
  |                            { None }
  |LPAREN relop version RPAREN { Some ($2, $3) }
;

vpkg: pkgname constr { ($1, $2) } ;

vpkglist:
  |             { [] }
  | vpkglist_ne { $1 }
;

vpkglist_ne:
  | vpkg                        { [ $1 ] }
  | vpkg COMMA vpkglist_ne      { $1 :: $3 }
;

vpkgformula:
  | or_formula                    { [ $1 ] }
  | or_formula COMMA vpkgformula  { $1 :: $3 }
;

or_formula:
  | vpkg                        { [ $1 ] }
  | vpkg PIPE or_formula        { $1 :: $3 }
;

/**************************************/ 

buidldep:
  |vpkg                            { ($1,[]) }
  |vpkg LBRACKET buildarchlist RBRACKET { ($1,$3) }
;

builddepslist:
  |                  { [] }
  | builddepslist_ne { $1 }
;

builddepslist_ne:
  | buidldep                         { [ $1 ] }
  | buidldep COMMA builddepslist_ne  { $1 :: $3 }
;

builddepsformula:
  | builddeps_or_formula                            { [ $1 ] }
  | builddeps_or_formula COMMA builddepsformula    { $1 :: $3 }
;

builddeps_or_formula:
  | buidldep                             { [ $1 ] }
  | buidldep PIPE builddeps_or_formula   { $1 :: $3 }
;

/**************************************/ 

buildarch:
  | BANG IDENT             { (false,$2) }
  | IDENT                  { (true,$1)  }
;

buildarchlist:
  |             { [] }
  | buildarchlist_ne { $1 }
;

buildarchlist_ne:
  | buildarch                       { [ $1 ] }
  | buildarch buildarchlist_ne      { $1 :: $2 }
;

/**************************************/ 

archlist:
  |             { [] }
  | archlist_ne { $1 }
;

archlist_ne:
  | IDENT                   { [ $1 ] }
  | IDENT archlist_ne       { $1 :: $2 }
;

/**************************************/ 

req:
  |pkgname             { let (n,a) = parse_request $1 in (n,a,None) }
  |pkgname EQ version  { let (n,a) = parse_request $1 in (n,a,Some("=",$3)) }

reqlist:
  |            { [] }
  | reqlist_ne { $1 }
;

reqlist_ne:
  | req                 { [ $1 ] }
  | req reqlist_ne      { $1 :: $2 }
;



%%

let error_wrapper f lexer lexbuf =
  let syntax_error msg =
    raise (Format822.Syntax_error (msg, Format822.loc_of_lexbuf lexbuf)) 
  in
  try f lexer lexbuf with
  |Parsing.Parse_error -> syntax_error "parse error"
  |Failure _m when String.starts_with _m "lexing" -> syntax_error "lexer error"
  |Format822.Type_error _ -> syntax_error "type error"
  |_ -> assert false

let pkgname_top = error_wrapper pkgname_top
let version_top = error_wrapper version_top
let vpkg_top = error_wrapper vpkg_top
let vpkglist_top = error_wrapper vpkglist_top
let vpkgformula_top = error_wrapper vpkgformula_top
let source_top = error_wrapper source_top
let request_top = error_wrapper request_top
