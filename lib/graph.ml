(* The graph model (docs/graph-design.md) derived from a parsed GTFS feed:
   the intermediate representation between the files and the database. *)

let ( let* ) = Result.bind

type route_stop = {
  route_stop_id : string;  (* the "{route_id}:{stop_id}" composite *)
  route_id : string;
  route_short_name : string;
  stop_id : int;
}

type t = {
  stops : Gtfs.stop list;
  route_stops : route_stop list;
}

(* The unique (route, stop) pairs served by the feed's trips, in order of
   first appearance, each with the route's short name. References to
   unknown trips, routes or stops are data errors. *)
let route_stops (gtfs : Gtfs.t) : (route_stop list, string) result =
  let trip_route = Hashtbl.create (1 lsl 19) in
  List.iter
    (fun (trip : Gtfs.trip) ->
      Hashtbl.replace trip_route trip.trip_id trip.route_id)
    gtfs.trips;
  let route_name = Hashtbl.create (1 lsl 14) in
  List.iter
    (fun (route : Gtfs.route) ->
      Hashtbl.replace route_name route.route_id route.route_short_name)
    gtfs.routes;
  let stop_exists = Hashtbl.create (1 lsl 16) in
  List.iter
    (fun (stop : Gtfs.stop) -> Hashtbl.replace stop_exists stop.stop_id ())
    gtfs.stops;
  let seen = Hashtbl.create (1 lsl 18) in
  let acc = ref [] in
  let rec add = function
    | [] -> Ok ()
    | (st : Gtfs.stop_time) :: rest ->
      (match Hashtbl.find_opt trip_route st.trip_id with
       | None ->
         Error (Printf.sprintf "stop_times: trip %d not found in trips.txt" st.trip_id)
       | Some route_id ->
         let key = (route_id, st.stop_id) in
         if Hashtbl.mem seen key then add rest
         else
           (match Hashtbl.find_opt route_name route_id with
            | None ->
              Error
                (Printf.sprintf "trips: route %s not found in routes.txt"
                   route_id)
            | Some route_short_name ->
              if not (Hashtbl.mem stop_exists st.stop_id) then
                Error
                  (Printf.sprintf "stop_times: stop %d not found in stops.txt"
                     st.stop_id)
              else begin
                Hashtbl.add seen key ();
                acc :=
                  { route_stop_id = route_id ^ ":" ^ string_of_int st.stop_id
                  ; route_id
                  ; route_short_name
                  ; stop_id = st.stop_id } :: !acc;
                add rest
              end))
  in
  let* () = add gtfs.stop_times in
  Ok (List.rev !acc)

let derive (gtfs : Gtfs.t) : (t, string) result =
  let* route_stops = route_stops gtfs in
  Ok { stops = gtfs.stops; route_stops }
