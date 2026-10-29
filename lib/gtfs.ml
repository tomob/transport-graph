(* GTFS Schedule reading: the four files the graph model uses (see
   docs/graph-design.md), read from a ZIP archive and parsed with
   Gendarme's CSV marshalling. *)

[%%marshal.load Csv]

let ( let* ) = Result.bind

(* Identifiers that the target feeds carry as plain numbers are parsed as
   [int] (stop_id: up to 9 digits; trip_id: up to 18, still well below the
   63-bit int range); route_id stays a string — in the Sweden feed every
   route_id carries a variant suffix ("100000000001000001-1"). A non-numeric
   value where a number is expected fails the whole parse. *)

type stop = {
  stop_id : int [@csv "stop_id"];
  stop_name : string [@csv "stop_name"];
  stop_lat : float [@csv "stop_lat"];
  stop_lon : float [@csv "stop_lon"];
} [@@marshal]

(* A row of routes.txt. *)
type route = {
  route_id : string [@csv "route_id"];
  route_short_name : string [@csv "route_short_name"];
} [@@marshal]

(* A row of trips.txt. *)
type trip = {
  route_id : string [@csv "route_id"];
  trip_id : int [@csv "trip_id"];
} [@@marshal]

(* A row of stop_times.txt. *)
type stop_time = {
  trip_id : int [@csv "trip_id"];
  arrival_time : string [@csv "arrival_time"];
  departure_time : string [@csv "departure_time"];
  stop_id : int [@csv "stop_id"];
  stop_sequence : int [@csv "stop_sequence"];
} [@@marshal]

(* The four files together. *)
type t = {
  stops : stop list;
  routes : route list;
  trips : trip list;
  stop_times : stop_time list;
}

(* The whole contents of one entry of the archive. *)
let read_entry zip name = Zip.read_entry zip (Zip.find_entry zip name)

let load path : (t, string) result =
  try
    let zip = Zip.open_in path in
    Fun.protect ~finally:(fun () -> Zip.close_in zip) @@ fun () ->
    let stops =
      [%decode.Csv] ~v:(read_entry zip "stops.txt") (Gendarme.list stop)
    in
    let routes =
      [%decode.Csv] ~v:(read_entry zip "routes.txt") (Gendarme.list route)
    in
    let trips =
      [%decode.Csv] ~v:(read_entry zip "trips.txt") (Gendarme.list trip)
    in
    let stop_times =
      [%decode.Csv] ~v:(read_entry zip "stop_times.txt")
        (Gendarme.list stop_time)
    in
    Ok { stops; routes; trips; stop_times }
  with
  | Not_found -> Error (path ^ ": missing one of the GTFS files")
  | e -> Error (Printexc.to_string e)
