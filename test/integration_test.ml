(** Integration Test - Railway Neo4j Connection *)

module B = Neo4j_bolt.Bolt

let () = Lwt_main.run begin
  let open Lwt.Syntax in

  Printf.printf "=== Neo4j Bolt TLS Integration Test ===\n%!";

  (* Test 1: Parse environment URI *)
  let uri = Sys.getenv_opt "NEO4J_URI" |> Option.value ~default:"bolt://localhost:7687" in
  let (host, port, tls_mode) = B.parse_uri uri in
  Printf.printf "URI: %s\n" uri;
  Printf.printf "Parsed: host=%s port=%d mode=%s\n%!" host port (B.tls_mode_to_string tls_mode);

  (* Test 2: Connect using default config (uses NEO4J_URI) *)
  Printf.printf "\n--- Connecting to Neo4j ---\n%!";
  let* conn_result = B.connect () in
  match conn_result with
  | Error e ->
    Printf.printf "Connection failed: %s\n" (B.error_to_string e);
    Lwt.return_unit

  | Ok conn ->
    Printf.printf "Connected: %s\n%!" (B.connection_info conn);
    Printf.printf "TLS enabled: %b\n%!" (B.is_tls_connection conn);

    (* Test 3: Run simple query *)
    let* result = B.run conn ~cypher:"RETURN 1 as n" () in
    begin match result with
    | Ok _ -> Printf.printf "Query test: PASSED\n%!"
    | Error e -> Printf.printf "Query test: FAILED - %s\n%!" (B.error_to_string e)
    end;

    (* Test 4: Count nodes *)
    let* count_result = B.run conn ~cypher:"MATCH (n) RETURN count(n) as total" () in
    begin match count_result with
    | Ok records ->
      let total = B.extract_first_int records |> Option.value ~default:0L in
      Printf.printf "Total nodes: %Ld\n%!" total
    | Error e -> Printf.printf "Count failed: %s\n%!" (B.error_to_string e)
    end;

    (* Clean up *)
    let* () = B.close conn in
    Printf.printf "\nConnection closed. Test complete!\n%!";
    Lwt.return_unit
end
