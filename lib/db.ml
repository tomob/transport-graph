let ( let* ) = Result.bind

(* Number of rows per UNWIND batch of the loading queries. *)
let batch_size = 10_000

(* Split [l] into chunks of at most [size] elements. *)
let chunk size l =
  let rec split acc n rest =
    match rest with
    | [] -> (List.rev acc, [])
    | _ when n = 0 -> (List.rev acc, rest)
    | x :: r -> split (x :: acc) (n - 1) r
  in
  let rec loop = function
    | [] -> []
    | rest ->
      let batch, rest = split [] size rest in
      batch :: loop rest
  in
  loop l

(* Create the uniqueness constraints of the graph model (see
   docs/graph-design.md, "Constraints and indexes") before any data is
   loaded: they double as the range indexes the later loading phases look
   nodes up by. *)
let create_constraints session =
  let run query =
    let* result = Neodriver.Session.run session ~query ~parameters:[] in
    let* _summary = Neodriver.Neo4jResult.consume result in
    Ok ()
  in
  let* () =
    run "CREATE CONSTRAINT stop_id IF NOT EXISTS \
         FOR (s:Stop) REQUIRE s.stop_id IS UNIQUE"
  in
  run "CREATE CONSTRAINT route_stop_id IF NOT EXISTS \
       FOR (rs:RouteStop) REQUIRE rs.route_stop_id IS UNIQUE"

(* The Stop nodes, straight from stops.txt. Each batch runs in its
   own managed, retried transaction (Driver.execute_query). *)
let load_stops driver stops =
  let query =
    "UNWIND $rows AS row \
     CREATE (:Stop { stop_id: row.id, stop_name: row.name, \
                     stop_lat: row.lat, stop_lon: row.lon })"
  in
  let row_value (stop : Gtfs.stop) =
    let open Neodriver.Values in
    Map
      [ ("id", Int (Int64.of_int stop.stop_id))
      ; ("name", String stop.stop_name)
      ; ("lat", Float stop.stop_lat)
      ; ("lon", Float stop.stop_lon) ]
  in
  let rec run created = function
    | [] -> Printf.printf "stops: %d created\n" created; Ok ()
    | batch :: rest ->
      let parameters =
        [ ("rows", Neodriver.Values.List (List.map row_value batch)) ]
      in
      let* eager = Neodriver.Driver.execute_query driver ~query ~parameters in
      run (created + eager.summary.counters.nodes_created) rest
  in
  run 0 (chunk batch_size stops)

(* The RouteStop nodes together with their LOCATED_AT edges — one
   pass, every row a unique (route, stop) pair derived in Graph. The Stop is
   matched before anything is created, so an inconsistent row cannot leave
   an orphaned node behind. *)
let load_route_stops driver route_stops =
  let query =
    "UNWIND $rows AS row \
     MATCH (s:Stop { stop_id: row.stop_id }) \
     CREATE (rs:RouteStop { route_stop_id: row.id, route_id: row.route_id, \
                            route_short_name: row.name }) \
     CREATE (rs)-[:LOCATED_AT]->(s)"
  in
  let row_value (rs : Graph.route_stop) =
    let open Neodriver.Values in
    Map
      [ ("id", String rs.route_stop_id)
      ; ("route_id", String rs.route_id)
      ; ("name", String rs.route_short_name)
      ; ("stop_id", Int (Int64.of_int rs.stop_id)) ]
  in
  let rec run nodes relationships = function
    | [] ->
      Printf.printf "route stops: %d nodes, %d LOCATED_AT created\n" nodes
        relationships;
      Ok ()
    | batch :: rest ->
      let parameters =
        [ ("rows", Neodriver.Values.List (List.map row_value batch)) ]
      in
      let* eager = Neodriver.Driver.execute_query driver ~query ~parameters in
      let counters = eager.summary.counters in
      run (nodes + counters.nodes_created)
        (relationships + counters.relationships_created) rest
  in
  run 0 0 (chunk batch_size route_stops)

(* Delete every Stop and RouteStop node together with all its relationships
   (LOCATED_AT, NEXT_STOP, BOARD) — these are the only node types of the
   model, so this clears the whole graph. *)
let clear_db session =
  let* result =
    Neodriver.Session.run session
      ~query:"MATCH (n:Stop|RouteStop) DETACH DELETE n"
      ~parameters:[]
  in
  let* summary = Neodriver.Neo4jResult.consume result in
  Printf.printf "cleared: %d nodes, %d relationships deleted\n"
    summary.counters.nodes_deleted summary.counters.relationships_deleted;
  Ok ()
