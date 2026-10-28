open Cmdliner
open Neodriver

let ( let* ) = Result.bind

let data =
  let doc = "$(docv) is the path to the ZIP file with the GTFS data to import." in
  Arg.(required & pos 0 (some string) None & info [] ~doc ~docv:"PATH")

let clear_db =
  let doc = "Whether to clear the database before importing." in
  Arg.(value & flag & info [ "c"; "clear-db" ] ~doc ~docv:"BOOL" ~absent:"false")

let process_data ~clear_db driver =
  let session = Driver.session driver in
  let result =
    if clear_db then Transport_graph.Db.clear_db session else Ok ()
  in
  Session.close session;
  result


let run (config : Transport_graph.Config.t) data clear_db : (unit, string) result =
  Printf.printf "connection: %s (user: %s, database: %s)\n"
    config.url config.user config.database;
  Printf.printf "data: %s\n" data;
  Printf.printf "clear-db: %b\n" clear_db;
  Eio_main.run (fun env ->
    let net = Eio.Stdenv.net env in
    let clock = Eio.Stdenv.mono_clock env in
    Eio.Switch.run (fun sw ->
      let* workspace_config =
        Config.make_workspace_config ~database:(Some config.database) ()
      in
      let* driver =
        Driver.connect ~uri:config.url
          ~auth:(Conn.basic_auth ~credentials:config.password ())
          ~workspace_config net clock sw
      in
      process_data ~clear_db driver
    )
  ) |> Result.map_error Errors.to_string

let main =
  let open Term.Syntax in
  let+ config = Transport_graph.Config.term
  and+ data = data
  and+ clear_db = clear_db in
  Result.bind (Transport_graph.Config.check config)
    (fun _ -> run config data clear_db)

let cmd =
  let doc = "Reads a GTFS ZIP file and loads it into a Neo4j database." in
  let man = [ `S Manpage.s_description; `P doc ] in
  Cmd.make (Cmd.info "load_data" ~doc ~man) main

let () =
  exit (Cmd.eval_result ~env:Transport_graph.Config.env_lookup cmd)
