let ( let* ) = Result.bind

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
