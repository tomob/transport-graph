(* The graph model (docs/graph-design.md) derived from a parsed GTFS feed:
   the intermediate representation between the files and the database. *)

let ( let* ) = Result.bind

type route_stop = {
  route_stop_id : string;  (* the "{route_id}:{stop_id}" composite *)
  route_id : string;
  route_short_name : string;
  stop_id : int;
}

type next_stop = {
  from_id : string;  (* route_stop_id of the source *)
  to_id : string;    (* route_stop_id of the target *)
  time : float;      (* averaged travel time, minutes *)
}

type board = {
  stop_id : int;           (* the Stop the journey boards at *)
  route_stop_id : string;  (* the RouteStop being boarded *)
  time : float;            (* half the average headway, minutes *)
}

type t = {
  stops : Gtfs.stop list;
  route_stops : route_stop list;
  next_stops : next_stop list;
  boards : board list;
}

(* "H+:MM:SS" to seconds since the start of the service day — GTFS allows
   the hours to exceed 24. *)
let parse_time ~trip s =
  let digits s = s <> "" && String.for_all (fun c -> c >= '0' && c <= '9') s in
  match String.split_on_char ':' s with
  | [ hh; mm; ss ]
    when digits hh && digits mm && digits ss
      && int_of_string mm < 60 && int_of_string ss < 60 ->
    Ok (int_of_string hh * 3600 + int_of_string mm * 60 + int_of_string ss)
  | _ -> Error (Printf.sprintf "stop_times: trip %d: invalid time %S" trip s)

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

(* Consecutive-stop pairs along every trip, averaged per (route, from, to)
   into the NEXT_STOP travel times (in minutes). *)
let next_stops (gtfs : Gtfs.t) : (next_stop list, string) result =
  let trip_route = Hashtbl.create (1 lsl 19) in
  List.iter
    (fun (trip : Gtfs.trip) ->
      Hashtbl.replace trip_route trip.trip_id trip.route_id)
    gtfs.trips;
  (* (stop_sequence, stop_id, departure, arrival in seconds) per trip *)
  let rows = Hashtbl.create (1 lsl 19) in
  let push table key row =
    let current =
      match Hashtbl.find_opt table key with
      | Some l -> l
      | None -> []
    in
    Hashtbl.replace table key (row :: current)
  in
  let rec group = function
    | [] -> Ok ()
    | (st : Gtfs.stop_time) :: rest ->
      let* dep = parse_time ~trip:st.trip_id st.departure_time in
      let* arr = parse_time ~trip:st.trip_id st.arrival_time in
      push rows st.trip_id (st.stop_sequence, st.stop_id, dep, arr);
      group rest
  in
  let* () = group gtfs.stop_times in
  (* (sum of travel seconds, instances) per (route, from, to) *)
  let sums = Hashtbl.create (1 lsl 18) in
  let* () =
    Hashtbl.fold
      (fun trip_id stops acc ->
        match acc with
        | Error _ -> acc
        | Ok () ->
          (match Hashtbl.find_opt trip_route trip_id with
           | None ->
             Error
               (Printf.sprintf "stop_times: trip %d not found in trips.txt"
                  trip_id)
           | Some route_id ->
             let sorted =
               List.sort (fun (s1, _, _, _) (s2, _, _, _) -> compare s1 s2)
                 stops
             in
             let rec pairs = function
               | [] | [ _ ] -> Ok ()
               | (_, from_stop, _, dep)
                 :: ((_, to_stop, arr, _) :: _ as tl) ->
                 let travel = arr - dep in
                 if travel < 0 then
                   Error
                     (Printf.sprintf
                        "stop_times: trip %d: negative travel time %d s \
                         from stop %d to stop %d"
                        trip_id travel from_stop to_stop)
                 else begin
                   let key = (route_id, from_stop, to_stop) in
                   let sum, n =
                     match Hashtbl.find_opt sums key with
                     | Some acc -> acc
                     | None -> (0, 0)
                   in
                   Hashtbl.replace sums key (sum + travel, n + 1);
                   pairs tl
                 end
             in
             pairs sorted))
      rows (Ok ())
  in
  Ok
    (Hashtbl.fold
       (fun (route_id, from_stop, to_stop) (sum, n) acc ->
         { from_id = route_id ^ ":" ^ string_of_int from_stop
         ; to_id = route_id ^ ":" ^ string_of_int to_stop
         ; time = float_of_int sum /. (60.0 *. float_of_int n) } :: acc)
       sums [])

(* One BOARD edge per (route, stop): half the average gap between the
   route's consecutive departures at that stop — the expected wait when
   boarding at a random moment. A single departure means a daily cycle: a
   24 h headway. *)
let boards (gtfs : Gtfs.t) : (board list, string) result =
  let trip_route = Hashtbl.create (1 lsl 19) in
  List.iter
    (fun (trip : Gtfs.trip) ->
      Hashtbl.replace trip_route trip.trip_id trip.route_id)
    gtfs.trips;
  (* (earliest, latest departure in seconds, count) per (route, stop) *)
  let deps = Hashtbl.create (1 lsl 18) in
  let rec add = function
    | [] -> Ok ()
    | (st : Gtfs.stop_time) :: rest ->
      (match Hashtbl.find_opt trip_route st.trip_id with
       | None ->
         Error
           (Printf.sprintf "stop_times: trip %d not found in trips.txt"
              st.trip_id)
       | Some route_id ->
         let* dep = parse_time ~trip:st.trip_id st.departure_time in
         let key = (route_id, st.stop_id) in
         let earliest, latest, n =
           match Hashtbl.find_opt deps key with
           | Some v -> v
           | None -> (dep, dep, 0)
         in
          let earliest = if dep < earliest then dep else earliest in
          let latest = if dep > latest then dep else latest in
          Hashtbl.replace deps key (earliest, latest, n + 1);
         add rest)
  in
  let* () = add gtfs.stop_times in
  Ok
    (Hashtbl.fold
       (fun (route_id, stop_id) (earliest, latest, n) acc ->
         let headway =
           if n > 1 then
             float_of_int (latest - earliest) /. float_of_int (n - 1)
           else 86_400.0
         in
         { stop_id
         ; route_stop_id = route_id ^ ":" ^ string_of_int stop_id
         ; time = headway /. 120.0 } :: acc)
       deps [])

let derive (gtfs : Gtfs.t) : (t, string) result =
  let* route_stops = route_stops gtfs in
  let* next_stops = next_stops gtfs in
  let* boards = boards gtfs in
  Ok { stops = gtfs.stops; route_stops; next_stops; boards }
