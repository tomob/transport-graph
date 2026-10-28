open Cmdliner

let origin =
  let doc = "Name of the origin stop." in
  let absent = "error, the option is required" in
  Arg.(value & opt (some string) None & info [ "f"; "from" ] ~doc ~docv:"STOP" ~absent)

let destination =
  let doc = "Name of the destination stop." in
  let absent = "error, the option is required" in
  Arg.(value & opt (some string) None & info [ "t"; "to" ] ~doc ~docv:"STOP" ~absent)

let run (config : Transport_graph.Config.t) origin destination
  : (unit, string) result =
  match Transport_graph.Config.check config with
  | Error msg -> Error msg
  | Ok () ->
    (match origin, destination with
     | None, _ -> Error "missing --from: pass the name of the origin stop"
     | _, None -> Error "missing --to: pass the name of the destination stop"
     | Some from, Some to_ ->
       (* TODO: connect and search for the best connection. *)
       Printf.printf "connection: %s (user: %s, database: %s)\n"
         config.url config.user config.database;
       Printf.printf "from: %s\n" from;
       Printf.printf "to: %s\n" to_;
       Ok ())

let main =
  let open Term.Syntax in
  let+ config = Transport_graph.Config.term
  and+ origin = origin
  and+ destination = destination in
  run config origin destination

let cmd =
  let doc = "Finds the best connection between two stops in a Neo4j database." in
  let man = [ `S Manpage.s_description; `P doc ] in
  Cmd.make (Cmd.info "find_connection" ~doc ~man) main

let () =
  exit (Cmd.eval_result ~env:Transport_graph.Config.env_lookup cmd)
