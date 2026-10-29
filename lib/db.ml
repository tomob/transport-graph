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

(* The stop_name lookup index used by find_connection — created once the
   data is loaded, so the bulk load does not pay for maintaining it. *)
let create_stop_name_index session =
  let* result =
    Neodriver.Session.run session
      ~query:"CREATE INDEX stop_name IF NOT EXISTS \
              FOR (s:Stop) ON (s.stop_name)"
      ~parameters:[]
  in
  let* _summary = Neodriver.Neo4jResult.consume result in
  Ok ()

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
     CREATE (rs)-[:LOCATED_AT { time: 0.0 }]->(s)"
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

(* The NEXT_STOP edges with their route-averaged travel times. Both
   endpoints are matched before anything is created, and the final counter
   must account for every row. *)
let load_next_stops driver next_stops =
  let query =
    "UNWIND $rows AS row \
     MATCH (a:RouteStop { route_stop_id: row.from }) \
     MATCH (b:RouteStop { route_stop_id: row.to }) \
     CREATE (a)-[:NEXT_STOP { time: row.time }]->(b)"
  in
  let row_value (n : Graph.next_stop) =
    let open Neodriver.Values in
    Map
      [ ("from", String n.from_id)
      ; ("to", String n.to_id)
      ; ("time", Float n.time) ]
  in
  let expected = List.length next_stops in
  let rec run created = function
    | [] ->
      if created <> expected then
        Error
          (Neodriver.Errors.Session_error
             (Printf.sprintf "next stops: created %d of %d relationships"
                created expected))
      else begin
        Printf.printf "next stops: %d created\n" created;
        Ok ()
      end
    | batch :: rest ->
      let parameters =
        [ ("rows", Neodriver.Values.List (List.map row_value batch)) ]
      in
      let* eager = Neodriver.Driver.execute_query driver ~query ~parameters in
      run (created + eager.summary.counters.relationships_created) rest
  in
  run 0 (chunk batch_size next_stops)

(* The BOARD edges: one per RouteStop — the expected wait (half the average
   headway) to board that route at that stop. Both endpoints are matched
   before anything is created, and the final counter must account for every
   row. *)
let load_boards driver boards =
  let query =
    "UNWIND $rows AS row \
     MATCH (s:Stop { stop_id: row.stop_id }) \
     MATCH (rs:RouteStop { route_stop_id: row.route_stop_id }) \
     CREATE (s)-[:BOARD { time: row.time }]->(rs)"
  in
  let row_value (b : Graph.board) =
    let open Neodriver.Values in
    Map
      [ ("stop_id", Int (Int64.of_int b.stop_id))
      ; ("route_stop_id", String b.route_stop_id)
      ; ("time", Float b.time) ]
  in
  let expected = List.length boards in
  let rec run created = function
    | [] ->
      if created <> expected then
        Error
          (Neodriver.Errors.Session_error
             (Printf.sprintf "board: created %d of %d relationships" created
                expected))
      else begin
        Printf.printf "board: %d created\n" created;
        Ok ()
      end
    | batch :: rest ->
      let parameters =
        [ ("rows", Neodriver.Values.List (List.map row_value batch)) ]
      in
      let* eager = Neodriver.Driver.execute_query driver ~query ~parameters in
      run (created + eager.summary.counters.relationships_created) rest
  in
  run 0 (chunk batch_size boards)

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

(* Every Stop whose name contains the fragment, ignoring case, ordered by
   name. *)
let find_stops ~fragment driver =
  let query =
    "MATCH (s:Stop) \
     WHERE toLower(s.stop_name) CONTAINS toLower($fragment) \
     RETURN s.stop_id AS id, s.stop_name AS name \
     ORDER BY s.stop_name, s.stop_id"
  in
  let* eager =
    Neodriver.Driver.execute_query driver ~query
      ~parameters:[ ("fragment", Neodriver.Values.String fragment) ]
  in
  Ok
    (List.filter_map
       (function
         | [ Neodriver.Values.Int id; Neodriver.Values.String name ] ->
           Some (Int64.to_int id, name)
         | _ -> None)
       eager.records)

(* The stops whose name equals [name] exactly, ignoring case. *)
let find_stops_named ~name driver =
  let query =
    "MATCH (s:Stop) WHERE toLower(s.stop_name) = toLower($name) \
     RETURN s.stop_id AS id, s.stop_name AS name ORDER BY s.stop_id"
  in
  let* eager =
    Neodriver.Driver.execute_query driver ~query
      ~parameters:[ ("name", Neodriver.Values.String name) ]
  in
  Ok
    (List.filter_map
       (function
         | [ Neodriver.Values.Int id; Neodriver.Values.String name ] ->
           Some (Int64.to_int id, name)
         | _ -> None)
       eager.records)

(* The fastest connection between two stops, found by the database itself:
   the native Dijkstra of the Neo4j Graph Data Science library, over an
   in-memory projection of the graph. Temporary zero-cost ANCHOR
   relationships from the origin Stop to its RouteStops carry the free
   entry into the network; the search then rides NEXT_STOP edges,
   transfers through the shared Stops (LOCATED_AT in, BOARD out — paying
   the expected wait) and arrives at the destination Stop via LOCATED_AT.
   Requires the GDS plugin. *)
let query_timeout = 60.0

let find_best_journey ~from ~to_ driver =
  let run query parameters =
    Neodriver.Driver.execute_query ~timeout:query_timeout driver ~query
      ~parameters
  in
  let string = function
    | Neodriver.Values.String s -> s
    | _ -> ""
  in
  let strings = function
    | Neodriver.Values.List l ->
      List.filter_map
        (function Neodriver.Values.String s -> Some s | _ -> None)
        l
    | _ -> []
  in
  let floats = function
    | Neodriver.Values.List l ->
      List.filter_map
        (function Neodriver.Values.Float f -> Some f | _ -> None)
        l
    | _ -> []
  in
  let bools = function
    | Neodriver.Values.List l ->
      List.filter_map
        (function Neodriver.Values.Bool b -> Some b | _ -> None)
        l
    | _ -> []
  in
  let journey_of records =
    match records with
    | [ [ origin; names; stop_flags; costs; Neodriver.Values.Float total ] ] ->
      Ok
        (Some
           (Journey.of_path ~origin:(string origin) ~names:(strings names)
              ~stops:(bools stop_flags) ~costs:(floats costs) ~total))
    | _ -> Ok None
  in
  (* Aura Graph Analytics runs GDS in ephemeral sessions: its native
     projection takes flat label/type lists, loads properties via the flat
     relationshipProperties configuration, and requires a session (implicit
     — created with the projection, deleted with gds.graph.drop — when
     memory is given). The session procedures exist only there, so they
     tell the two variants apart. *)
  let* aga =
    let* eager =
      run
        "SHOW PROCEDURES YIELD name WHERE name = 'gds.session.getOrCreate' \
         RETURN name"
        []
    in
    Ok (eager.Neodriver.EagerResult.records <> [])
  in
  (* Clean up leftovers from an interrupted run: a stale projection and
     stale ANCHOR relationships. The ANCHOR edges carry the free entry into
     the network — zero-cost relationships from every origin-candidate Stop
     to its RouteStops. They are real relationships, created for the
     duration of the search and deleted afterwards. *)
  let delete_anchors () =
    match run "MATCH (:Stop)-[r:ANCHOR]->(:RouteStop) DELETE r" [] with
    | Ok _ | Error _ -> ()
  in
  let session_name = "transport-graph" in
  let session_memory = "2GB" in
  (* a named session is reused across runs instead of paying the cold start
     of an implicit session every time; it expires after 30 minutes of
     inactivity *)
  let* session_id =
    if aga then
      let* eager =
        run
          (Printf.sprintf
             "CALL gds.session.getOrCreate('%s', '%s', \
              duration({ minutes: 30 })) YIELD id RETURN id"
             session_name session_memory)
          []
      in
      Ok
        (match eager.Neodriver.EagerResult.records with
         | [ [ Neodriver.Values.String id ] ] -> Some id
         | _ -> None)
    else Ok None
  in
  let session_config =
    match session_id with
    | Some id -> Printf.sprintf ", sessionId: '%s' " id
    | None ->
      if aga then Printf.sprintf ", memory: '%s' " session_memory else " "
  in
  (match run "CALL gds.graph.drop('transport', false)" [] with
   | Ok _ | Error _ -> ());
  delete_anchors ();
  (* self-heal data loaded before LOCATED_AT carried its time *)
  let* _ =
    run "MATCH ()-[r:LOCATED_AT]->() WHERE r.time IS NULL SET r.time = 0.0" []
  in
  let* _ =
    run
      "MATCH (o:Stop) WHERE toLower(o.stop_name) = toLower($from) \
       MATCH (o)<-[:LOCATED_AT]-(rs:RouteStop) \
       CREATE (o)-[:ANCHOR { time: 0.0 }]->(rs)"
      [ ("from", Neodriver.Values.String from) ]
  in
  let* _ =
    run
      (Printf.sprintf
         "CALL gds.graph.project('transport', ['Stop', 'RouteStop'], \
          ['NEXT_STOP', 'BOARD', 'LOCATED_AT', 'ANCHOR'], \
          { relationshipProperties: ['time']%s}) \
          YIELD graphName RETURN graphName"
         session_config)
      []
  in
  let search =
    run
      "MATCH (o:Stop) WHERE toLower(o.stop_name) = toLower($from) \
       MATCH (d:Stop) WHERE toLower(d.stop_name) = toLower($to) \
       CALL gds.shortestPath.dijkstra.stream('transport', \
         { sourceNode: o, targetNode: d, \
           relationshipWeightProperty: 'time' }) \
       YIELD totalCost, nodeIds, costs \
       WITH o, totalCost, nodeIds, costs ORDER BY totalCost LIMIT 1 \
       UNWIND nodeIds AS nodeId \
       MATCH (n) WHERE id(n) = nodeId \
       WITH o, totalCost, costs, collect(n) AS nodes \
       RETURN o.stop_name AS origin, \
              [n IN nodes | CASE WHEN n:Stop THEN n.stop_name ELSE \
                CASE WHEN n.route_short_name = '' THEN n.route_id \
                     ELSE n.route_short_name END END] AS names, \
              [n IN nodes | n:Stop] AS stops, \
              costs, \
              totalCost AS total"
      [ ("from", Neodriver.Values.String from)
      ; ("to", Neodriver.Values.String to_) ]
  in
  (* the graph is dropped but the named session is kept for reuse; it
     expires after its ttl of inactivity *)
  (match run "CALL gds.graph.drop('transport')" [] with
   | Ok _ | Error _ -> ());
  delete_anchors ();
  let* eager = search in
  journey_of eager.Neodriver.EagerResult.records
