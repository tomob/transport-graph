open Cmdliner
open Neodriver
open Transport_graph

let ( let* ) = Result.bind

let data =
  let doc = "$(docv) is the path to the ZIP file with the GTFS data to import." in
  Arg.(required & pos 0 (some string) None & info [] ~doc ~docv:"PATH")

let clear_db =
  let doc = "Whether to clear the database before importing." in
  Arg.(value & flag & info [ "c"; "clear-db" ] ~doc ~docv:"BOOL" ~absent:"false")

let process_data ~clear_db (graph : Graph.t) driver =
  let session = Driver.session driver in
  let result =
    let* () = Db.create_constraints session in
    let* () =
      if clear_db then Db.clear_db session else Ok ()
    in
    let* () = Db.load_stops driver graph.stops in
    let* () = Db.load_route_stops driver graph.route_stops in
    let* () = Db.load_next_stops driver graph.next_stops in
    let* () = Db.load_boards driver graph.boards in
    let* () = Db.create_stop_name_index session in
    Db.invalidate_pathfinding driver
  in
  Session.close session;
  result


let run (config : Config.t) data clear_db : (unit, string) result =
  Printf.printf "connection: %s (user: %s, database: %s)\n"
    config.url config.user config.database;
  Printf.printf "clear-db: %b\n" clear_db;
  let* gtfs = Gtfs.load data in
  Printf.printf "data: %d stops, %d routes, %d trips, %d stop times\n"
    (List.length gtfs.stops) (List.length gtfs.routes)
    (List.length gtfs.trips) (List.length gtfs.stop_times);
  let* graph = Graph.derive gtfs in
  Printf.printf "graph: %d route stops, %d next stops, %d board edges\n"
    (List.length graph.route_stops) (List.length graph.next_stops)
    (List.length graph.boards);
  Eio_main.run (fun env ->
    let net = Eio.Stdenv.net env in
    let clock = Eio.Stdenv.mono_clock env in
    Eio.Switch.run (fun sw ->
      let* workspace_config =
        Neodriver.Config.make_workspace_config ~database:(Some config.database) ()
      in
      let* driver =
        Driver.connect ~uri:config.url
          ~auth:(Conn.basic_auth ~credentials:config.password ())
          ~workspace_config net clock sw
      in
      process_data ~clear_db graph driver
    )
  ) |> Result.map_error Errors.to_string

let main =
  let open Term.Syntax in
  let+ config = Config.term
  and+ data = data
  and+ clear_db = clear_db in
  Result.bind (Config.check config)
    (fun _ -> run config data clear_db)

let cmd =
  let doc = "Reads a GTFS ZIP file and loads it into a Neo4j database." in
  let man = [ `S Manpage.s_description; `P doc ] in
  Cmd.make (Cmd.info "load_data" ~doc ~man) main

let () =
  exit (Cmd.eval_result ~env:Config.env_lookup cmd)
