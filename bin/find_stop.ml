open Cmdliner
open Neodriver
open Transport_graph

let ( let* ) = Result.bind

let fragment =
  let doc = "$(docv) is the fragment of a stop name to look for." in
  Arg.(required & pos 0 (some string) None & info [] ~doc ~docv:"NAME")

let run (config : Config.t) fragment : (unit, string) result =
  if fragment = "" then Error "the stop name fragment is empty"
  else
    Eio_main.run (fun env ->
      let net = Eio.Stdenv.net env in
      let clock = Eio.Stdenv.mono_clock env in
      Eio.Switch.run (fun sw ->
        let* workspace_config =
          Neodriver.Config.make_workspace_config
            ~database:(Some config.database) ()
        in
        let* driver =
          Driver.connect ~uri:config.url
            ~auth:(Conn.basic_auth ~credentials:config.password ())
            ~workspace_config net clock sw
        in
        let* stops = Db.find_stops ~fragment driver in
        List.iter (fun (_id, name) -> Printf.printf "%s\n" name) stops;
        Ok ())
    ) |> Result.map_error Errors.to_string

let main =
  let open Term.Syntax in
  let+ config = Config.term
  and+ fragment = fragment in
  Result.bind (Config.check config) (fun _ -> run config fragment)

let cmd =
  let doc = "Finds stops by a fragment of their name in a Neo4j database." in
  let man = [ `S Manpage.s_description; `P doc ] in
  Cmd.make (Cmd.info "find_stop" ~doc ~man) main

let () = exit (Cmd.eval_result ~env:Config.env_lookup cmd)
