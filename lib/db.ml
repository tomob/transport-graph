let ( let* ) = Result.bind

(* Delete every Stop and RouteStop node together with all its relationships
   (LOCATED_AT, NEXT_STOP, TRANSFER) — these are the only node types of the
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
