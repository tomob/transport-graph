open Cmdliner

let data =
  let doc = "Path to the ZIP file with the GTFS data to import." in
  let absent = "error, the option is required" in
  Arg.(value & opt (some string) None & info [ "d"; "data" ] ~doc ~docv:"PATH" ~absent)

let clear_db =
  let doc = "Whether to clear the database before importing." in
  Arg.(value & flag & info [ "c"; "clear-db" ] ~doc ~docv:"BOOL" ~absent:"false")

let run (config : Transport_graph.Config.t) data clear_db : (unit, string) result =
  match Transport_graph.Config.check config with
  | Error msg -> Error msg
  | Ok () ->
    (match data with
     | None -> Error "missing --data: pass the path to the GTFS ZIP file"
     | Some data ->
       (* TODO: connect, optionally clear the database, load the data. *)
       Printf.printf "connection: %s (user: %s, database: %s)\n"
         config.url config.user config.database;
       Printf.printf "data: %s\n" data;
       Printf.printf "clear-db: %b\n" clear_db;
       Ok ())

let main =
  let open Term.Syntax in
  let+ config = Transport_graph.Config.term
  and+ data = data
  and+ clear_db = clear_db in
  run config data clear_db

let cmd =
  let doc = "Reads a GTFS ZIP file and loads it into a Neo4j database." in
  let man = [ `S Manpage.s_description; `P doc ] in
  Cmd.make (Cmd.info "load_data" ~doc ~man) main

let () =
  exit (Cmd.eval_result ~env:Transport_graph.Config.env_lookup cmd)
