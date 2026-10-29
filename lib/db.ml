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
     CREATE (rs)-[:LOCATED_AT { time: 0.0 }]->(s) \
     CREATE (s)-[:LOCATED_REV { time: 0.0 }]->(rs)"
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
      Printf.printf "route stops: %d nodes, %d relationships created\n" nodes
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
     CREATE (a)-[:NEXT_STOP { time: row.time }]->(b) \
     CREATE (b)-[:PREV_STOP { time: row.time }]->(a)"
  in
  let row_value (n : Graph.next_stop) =
    let open Neodriver.Values in
    Map
      [ ("from", String n.from_id)
      ; ("to", String n.to_id)
      ; ("time", Float n.time) ]
  in
  let expected = 2 * List.length next_stops in
  let rec run created = function
    | [] ->
      if created <> expected then
        Error
          (Neodriver.Errors.Session_error
             (Printf.sprintf "next stops: created %d of %d relationships"
                created expected))
      else begin
        Printf.printf "next stops: %d relationships created\n" created;
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
     CREATE (s)-[:BOARD { time: row.time }]->(rs) \
     CREATE (rs)-[:BOARD_REV { time: row.time }]->(s)"
  in
  let row_value (b : Graph.board) =
    let open Neodriver.Values in
    Map
      [ ("stop_id", Int (Int64.of_int b.stop_id))
      ; ("route_stop_id", String b.route_stop_id)
      ; ("time", Float b.time) ]
  in
  let expected = 2 * List.length boards in
  let rec run created = function
    | [] ->
      if created <> expected then
        Error
          (Neodriver.Errors.Session_error
             (Printf.sprintf "board: created %d of %d relationships" created
                expected))
      else begin
        Printf.printf "board: %d relationships created\n" created;
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

(* Resolve the origin and destination stops — all same-named candidates
   for each — in a single round trip. *)
let resolve_stops ~from ~to_ driver =
  let pairs = function
    | Neodriver.Values.List rows ->
      List.filter_map
        (function
          | Neodriver.Values.List
              [ Neodriver.Values.Int id; Neodriver.Values.String name ] ->
            Some (Int64.to_int id, name)
          | _ -> None)
        rows
    | _ -> []
  in
  let* eager =
    Neodriver.Driver.execute_query driver
      ~query:
        "MATCH (o:Stop) WHERE toLower(o.stop_name) = toLower($from) \
         WITH collect([o.stop_id, o.stop_name]) AS origins \
         MATCH (d:Stop) WHERE toLower(d.stop_name) = toLower($to) \
         RETURN origins, collect([d.stop_id, d.stop_name]) AS destinations"
      ~parameters:
        [ ("from", Neodriver.Values.String from)
        ; ("to", Neodriver.Values.String to_) ]
  in
  match eager.Neodriver.EagerResult.records with
  | [ [ origins; destinations ] ] ->
    Ok (pairs origins, pairs destinations)
  | _ -> Ok ([], [])

(* The fastest connection between two stops, found by the database itself:
   the native Dijkstra of the Neo4j Graph Data Science library. The search
   runs FROM the destination through the reversed mirror of the graph
   (PREV_STOP, LOCATED_REV, BOARD_REV) TO the origin's RouteStops — the free
   entry at the origin is implicit, as no edge leads into it — so the
   projection carries nothing query-specific and stays cached in the GDS
   session (or the server catalog) until load_data invalidates it. Requires
   the GDS plugin or Aura Graph Analytics. *)
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
           (Journey.of_reversed_path ~origin:(string origin)
              ~names:(strings names) ~stops:(bools stop_flags)
              ~costs:(floats costs) ~total))
    | _ -> Ok None
  in
  (* The warm path is a single bridge call: the Dijkstra resolves the
     cached projection by name, without any session handshake. Everything
     below runs only when the projection is missing. *)
  let search_query =
    "MATCH (o:Stop) WHERE toLower(o.stop_name) = toLower($from) \
     OPTIONAL MATCH (o)<-[:LOCATED_AT]-(rs:RouteStop) \
     WITH o, collect(DISTINCT rs) AS sources \
     WHERE size(sources) > 0 \
     MATCH (d:Stop) WHERE toLower(d.stop_name) = toLower($to) \
     CALL gds.shortestPath.dijkstra.stream('transport-rev', \
       { sourceNode: d, targetNodes: sources, \
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
  in
  let search () =
    run search_query
      [ ("from", Neodriver.Values.String from)
      ; ("to", Neodriver.Values.String to_) ]
  in
  match search () with
  | Ok eager -> journey_of eager.Neodriver.EagerResult.records
  | Error error ->
    (* The cached projection may be missing — a fresh session, an expired
       one, or reloaded data. Check, and only then pay for the session
       handshake and the projection. *)
    let* cached =
      let* exists_eager =
        run
          "CALL gds.graph.exists('transport-rev') YIELD exists RETURN exists"
          []
      in
      Ok
        (match exists_eager.Neodriver.EagerResult.records with
         | [ [ Neodriver.Values.Bool exists ] ] -> exists
         | _ -> false)
    in
    if cached then Error error
    else begin
      Printf.eprintf "note: projecting the graph for pathfinding\n";
      (* Aura Graph Analytics runs GDS in ephemeral sessions; its
         projection takes flat label/type lists and needs a session. The
         session procedures exist only there, so they tell the two
         variants apart. *)
      let* aga =
        let* procedures =
          run
            "SHOW PROCEDURES YIELD name \
             WHERE name = 'gds.session.getOrCreate' RETURN name"
            []
        in
        Ok (procedures.Neodriver.EagerResult.records <> [])
      in
      let session_name = "transport-graph" in
      let session_memory = "2GB" in
      let* session_id =
        if aga then
          let* session_eager =
            run
              (Printf.sprintf
                 "CALL gds.session.getOrCreate('%s', '%s', \
                  duration({ minutes: 30 })) YIELD id RETURN id"
                 session_name session_memory)
              []
          in
          Ok
            (match session_eager.Neodriver.EagerResult.records with
             | [ [ Neodriver.Values.String id ] ] -> Some id
             | _ -> None)
        else Ok None
      in
      let session_config =
        match session_id with
        | Some id -> Printf.sprintf ", sessionId: '%s' " id
        | None ->
          if aga then Printf.sprintf ", memory: '%s' " session_memory
          else " "
      in
      let* _ =
        run
          (Printf.sprintf
             "CALL gds.graph.project('transport-rev', ['Stop', 'RouteStop'], \
              ['PREV_STOP', 'LOCATED_REV', 'BOARD_REV'], \
              { relationshipProperties: ['time']%s}) \
              YIELD graphName RETURN graphName"
             session_config)
          []
      in
      let* eager = search () in
      journey_of eager.Neodriver.EagerResult.records
    end


(* Drop the cached pathfinding projection: the data has changed, so the
   reversed mirror in the GDS session is stale. Best effort — the server
   may not have GDS at all. *)
let invalidate_pathfinding driver =
  let drop name =
    match
      Neodriver.Driver.execute_query ~timeout:query_timeout driver
        ~query:(Printf.sprintf "CALL gds.graph.drop('%s', false)" name)
        ~parameters:[]
    with
    | Ok _ | Error _ -> ()
  in
  drop "transport-rev";
  drop "transport";
  Ok ()
