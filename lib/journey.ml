(* Presentation of a connection found by the database: the GDS Dijkstra
   returns the winning path as the node names, a per-node flag telling Stops
   from RouteStops, and the accumulated cost per node — this module turns
   the cost deltas into edge times and groups the edges into journey legs. *)

type leg = {
  line : string;  (* route_short_name, or route_id when empty *)
  from_stop : string;
  to_stop : string;
  ride : float;  (* minutes *)
  wait_after : float option;  (* the BOARD wait at to_stop, when transferring *)
}

type t = {
  legs : leg list;
  total : float;  (* minutes *)
}

let of_path ~(origin : string) ~(names : string list) ~(stops : bool list)
    ~(costs : float list) ~(total : float) : t =
  let legs = ref [] in
  let current = ref None in
  let edge_time i = List.nth costs (i + 1) -. List.nth costs i in
  for i = 0 to List.length names - 2 do
    let stop_here = List.nth stops i in
    let stop_next = List.nth stops (i + 1) in
    let name = List.nth names i in
    let next = List.nth names (i + 1) in
    match (stop_here, stop_next) with
    | false, false ->
      (* RouteStop -> RouteStop: riding *)
      (match !current with
       | Some (line, from_stop, ride) ->
         current := Some (line, from_stop, ride +. edge_time i)
       | None ->
         (* the first leg boards at the origin; later ones at the stop
            before the RouteStop they ride from — the transfer stop *)
         let from_stop =
           if !legs = [] then origin else List.nth names (i - 1)
         in
         current := Some (name, from_stop, edge_time i))
    | false, true ->
      (* RouteStop -> Stop: the leg ends at the stop *)
      (match !current with
       | Some (line, from_stop, ride) ->
         legs :=
           { line; from_stop; to_stop = next; ride; wait_after = None }
           :: !legs;
         current := None
       | None -> ())
    | true, false ->
      (* Stop -> RouteStop: boarding — free at the origin (the ANCHOR
         edge), the expected wait everywhere else *)
      if i > 0 then
        (match !legs with
         | last :: rest when last.wait_after = None ->
           legs := { last with wait_after = Some (edge_time i) } :: rest
         | _ -> ())
    | true, true -> ()
  done;
  { legs = List.rev !legs; total }
