(** Basic usage example *)

let () = Lwt_main.run begin
  let open Lwt.Syntax in

  Printf.printf "Connecting to Neo4j...\n%!";

  (* Connect with default config (reads NEO4J_PASSWORD from env) *)
  let* result = Neo4j_bolt.Bolt.connect () in

  match result with
  | Error e ->
    Printf.printf "Connection failed: %s\n" (Neo4j_bolt.Bolt.error_to_string e);
    Lwt.return ()

  | Ok conn ->
    Printf.printf "Connected! Protocol version: %d.%d\n"
      conn.version.major conn.version.minor;

    (* Run a simple query *)
    let* query_result = Neo4j_bolt.Bolt.query conn
      ~cypher:"MATCH (n) RETURN count(n) as total LIMIT 1" () in

    (match query_result with
     | Error e ->
       Printf.printf "Query failed: %s\n" (Neo4j_bolt.Bolt.error_to_string e)
     | Ok json ->
       Printf.printf "Result: %s\n" (Yojson.Safe.to_string json));

    (* Close connection *)
    let* () = Neo4j_bolt.Bolt.close conn in
    Printf.printf "Connection closed.\n";
    Lwt.return ()
end
