(* Connection configuration shared by the executables. The command line
   takes precedence over the environment; cmdliner performs the fallback
   to the environment variables itself (see the ~env parameters below)
   and documents them in the man pages. *)

open Cmdliner

type t =
  { url : string
  ; user : string
  ; password : string
  ; database : string }

(* Environment lookup passed to cmdliner evaluation: a variable set to
   an empty string counts as unset. *)
let env_lookup var =
  match Sys.getenv_opt var with
  | Some "" -> None
  | value -> value

let make url user password database =
  { url = Option.value url ~default:""
  ; user
  ; password = Option.value password ~default:""
  ; database }

(* [Error msg] when a value required to connect is missing. *)
let check t =
  let missing =
    (if t.url = "" then [ "--uri / NEO4J_URI" ] else []) @
    (if t.password = "" then [ "--password / NEO4J_PASSWORD" ] else [])
  in
  match missing with
  | [] -> Ok ()
  | vars ->
    Error ("missing required connection settings: " ^ String.concat ", " vars)

(* Cmdliner terms for the connection options, shared by both executables. *)

let url_arg =
  let doc = "Connect to Neo4j at this URI." in
  let env = Cmd.Env.info "NEO4J_URI" in
  Arg.(value & opt (some string) None & info [ "u"; "uri" ] ~doc ~docv:"URI" ~env)

let user_arg =
  let doc = "Connect to Neo4j as this user." in
  let env =
    Cmd.Env.info "NEO4J_USERNAME"
      ~doc:"Used when $(opt) is absent; falls back to 'neo4j' when unset or empty."
  in
  Arg.(value & opt string "neo4j" & info [ "s"; "user" ] ~doc ~docv:"USER" ~env)

let password_arg =
  let doc = "Neo4j password." in
  let env = Cmd.Env.info "NEO4J_PASSWORD" in
  Arg.(value & opt (some string) None & info [ "p"; "password" ] ~doc ~docv:"PASSWORD" ~env)

let database_arg =
  let doc = "Neo4j database to use." in
  let env =
    Cmd.Env.info "NEO4J_DATABASE"
      ~doc:"Used when $(opt) is absent; falls back to 'neo4j' when unset or empty."
  in
  Arg.(value & opt string "neo4j" & info [ "b"; "database" ] ~doc ~docv:"NAME" ~env)

let term : t Term.t =
  let open Term.Syntax in
  let+ url = url_arg
  and+ user = user_arg
  and+ password = password_arg
  and+ database = database_arg in
  make url user password database
