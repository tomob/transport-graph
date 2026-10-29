open Cmdliner
open Neodriver
open Transport_graph

let ( let* ) = Result.bind

let origin =
  let doc = "Name of the origin stop." in
  let absent = "error, the option is required" in
  Arg.(value & opt (some string) None & info [ "f"; "from" ] ~doc ~docv:"STOP" ~absent)

let destination =
  let doc = "Name of the destination stop." in
  let absent = "error, the option is required" in
  Arg.(value & opt (some string) None & info [ "t"; "to" ] ~doc ~docv:"STOP" ~absent)

let print_journey (journey : Journey.t) =
  match journey.legs with
  | [] -> Printf.printf "already at the destination\n"
  | legs ->
    List.iteri
      (fun i (leg : Journey.leg) ->
        Printf.printf "%d. %s: board line %s, ride %.1f min to %s\n" (i + 1)
          leg.from_stop leg.line leg.ride leg.to_stop;
        match leg.wait_after with
        | Some wait ->
          Printf.printf "    transfer at %s: expected wait %.1f min\n"
            leg.to_stop wait
        | None -> ())
      legs;
    Printf.printf "total: %.1f min\n" journey.total

let search ~(config : Config.t) ~from ~to_ : (unit, string) result =
  Eio_main.run (fun env ->
    let net = Eio.Stdenv.net env in
    let clock = Eio.Stdenv.mono_clock env in
    Eio.Switch.run (fun sw ->
      let* workspace_config =
        Result.map_error Errors.to_string
          (Neodriver.Config.make_workspace_config
             ~database:(Some config.database) ())
      in
      let* driver =
        Result.map_error Errors.to_string
          (Driver.connect ~uri:config.url
             ~auth:(Conn.basic_auth ~credentials:config.password ())
             ~workspace_config net clock sw)
      in
      let* origins =
        Result.map_error Errors.to_string (Db.find_stops_named ~name:from driver)
      in
      let* destinations =
        Result.map_error Errors.to_string
          (Db.find_stops_named ~name:to_ driver)
      in
      (match origins, destinations with
       | [], _ ->
         Error
           (Printf.sprintf
              "no stop named %S (use find_stop to look up the name)" from)
       | _, [] ->
         Error
           (Printf.sprintf
              "no stop named %S (use find_stop to look up the name)" to_)
       | origins, destinations ->
         (if List.length origins > 1 then
            Printf.eprintf "note: %d stops are named %S: %s\n"
              (List.length origins) from
              (String.concat ", "
                 (List.map (fun (id, _) -> string_of_int id) origins)));
         (if List.length destinations > 1 then
            Printf.eprintf "note: %d stops are named %S: %s\n"
              (List.length destinations) to_
              (String.concat ", "
                 (List.map (fun (id, _) -> string_of_int id) destinations)));
         let destination_ids = List.map fst destinations in
         if List.exists (fun (id, _) -> List.mem id destination_ids) origins
         then (
           Printf.printf "already at the destination\n";
           Ok ())
         else
           let* best =
             Result.map_error Errors.to_string
               (Db.find_best_journey ~from ~to_ driver)
           in
           (match best with
            | None ->
              Error
                (Printf.sprintf "no connection found from %S to %S" from to_)
            | Some journey ->
              print_journey journey;
              Ok ()))))

let run (config : Config.t) origin destination : (unit, string) result =
  match Config.check config with
  | Error msg -> Error msg
  | Ok () ->
    (match origin, destination with
     | None, _ -> Error "missing --from: pass the name of the origin stop"
     | _, None -> Error "missing --to: pass the name of the destination stop"
     | Some from, Some to_ -> search ~config ~from ~to_)

let main =
  let open Term.Syntax in
  let+ config = Config.term
  and+ origin = origin
  and+ destination = destination in
  run config origin destination

let cmd =
  let doc = "Finds the best connection between two stops in a Neo4j database." in
  let man = [ `S Manpage.s_description; `P doc ] in
  Cmd.make (Cmd.info "find_connection" ~doc ~man) main

let () = exit (Cmd.eval_result ~env:Config.env_lookup cmd)
