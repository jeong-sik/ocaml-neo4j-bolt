(** Bolt Module Unit Tests - URI parsing and TLS mode detection *)

module B = Neo4j_bolt.Bolt

(* Test helpers *)
let tls_mode = Alcotest.testable
  (fun fmt v -> Format.fprintf fmt "%s" (B.tls_mode_to_string v))
  (=)

(* URI parsing tests *)
let test_parse_bolt_plain () =
  let (host, port, mode) = B.parse_uri "bolt://localhost:7687" in
  Alcotest.(check string) "host" "localhost" host;
  Alcotest.(check int) "port" 7687 port;
  Alcotest.(check tls_mode) "mode" B.NoTLS mode

let test_parse_bolt_tls () =
  let (host, port, mode) = B.parse_uri "bolt+s://neo4j.example.com:7687" in
  Alcotest.(check string) "host" "neo4j.example.com" host;
  Alcotest.(check int) "port" 7687 port;
  Alcotest.(check tls_mode) "mode" B.TLS mode

let test_parse_bolts_shorthand () =
  let (host, port, mode) = B.parse_uri "bolts://neo4j.example.com:7687" in
  Alcotest.(check string) "host" "neo4j.example.com" host;
  Alcotest.(check int) "port" 7687 port;
  Alcotest.(check tls_mode) "mode" B.TLS mode

let test_parse_bolt_self_signed () =
  let (host, port, mode) = B.parse_uri "bolt+ssc://neo4j.example.com:7687" in
  Alcotest.(check string) "host" "neo4j.example.com" host;
  Alcotest.(check int) "port" 7687 port;
  Alcotest.(check tls_mode) "mode" B.TLSSelfSigned mode

let test_parse_default_port () =
  let (host, port, _) = B.parse_uri "bolt://localhost" in
  Alcotest.(check string) "host" "localhost" host;
  Alcotest.(check int) "port" 7687 port

let test_parse_with_path () =
  let (host, port, _) = B.parse_uri "bolt://localhost:7687/neo4j" in
  Alcotest.(check string) "host" "localhost" host;
  Alcotest.(check int) "port" 7687 port

(* Config from URI tests *)
let test_config_from_uri_tls () =
  let config = B.config_from_uri ~username:"neo4j" ~password:"secret" "bolt+s://db.example.com:7688" in
  Alcotest.(check string) "host" "db.example.com" config.host;
  Alcotest.(check int) "port" 7688 config.port;
  Alcotest.(check string) "username" "neo4j" config.username;
  Alcotest.(check string) "password" "secret" config.password;
  Alcotest.(check tls_mode) "mode" B.TLS config.tls_mode

(* TLS mode to string tests *)
let test_tls_mode_strings () =
  Alcotest.(check string) "plain" "plain" (B.tls_mode_to_string B.NoTLS);
  Alcotest.(check string) "tls" "tls" (B.tls_mode_to_string B.TLS);
  Alcotest.(check string) "self-signed" "tls-self-signed" (B.tls_mode_to_string B.TLSSelfSigned)

let with_env name value f =
  let original = Sys.getenv_opt name in
  (match value with
   | Some v -> Unix.putenv name v
   | None -> Unix.putenv name "");
  Fun.protect
    ~finally:(fun () ->
      match original with
      | Some v -> Unix.putenv name v
      | None -> Unix.putenv name "")
    f

let test_insecure_tls_opt_in_default_false () =
  with_env "ALLOW_INSECURE_TLS" None @@ fun () ->
  with_env "NEO4J_ALLOW_INSECURE_TLS" None @@ fun () ->
  Alcotest.(check bool) "default false" false (B.insecure_tls_opt_in_enabled ())

let test_insecure_tls_opt_in_primary_env () =
  with_env "ALLOW_INSECURE_TLS" (Some "1") @@ fun () ->
  with_env "NEO4J_ALLOW_INSECURE_TLS" None @@ fun () ->
  Alcotest.(check bool) "ALLOW_INSECURE_TLS=1" true (B.insecure_tls_opt_in_enabled ())

let test_insecure_tls_opt_in_legacy_env () =
  with_env "ALLOW_INSECURE_TLS" None @@ fun () ->
  with_env "NEO4J_ALLOW_INSECURE_TLS" (Some "true") @@ fun () ->
  Alcotest.(check bool) "NEO4J_ALLOW_INSECURE_TLS=true" true (B.insecure_tls_opt_in_enabled ())

(* Test suites *)
let () =
  Alcotest.run "Bolt" [
    "uri_parsing", [
      ("bolt:// plain", `Quick, test_parse_bolt_plain);
      ("bolt+s:// TLS", `Quick, test_parse_bolt_tls);
      ("bolts:// shorthand", `Quick, test_parse_bolts_shorthand);
      ("bolt+ssc:// self-signed", `Quick, test_parse_bolt_self_signed);
      ("default port", `Quick, test_parse_default_port);
      ("with path", `Quick, test_parse_with_path);
    ];
    "config", [
      ("config_from_uri TLS", `Quick, test_config_from_uri_tls);
    ];
    "tls_mode", [
      ("mode strings", `Quick, test_tls_mode_strings);
    ];
    "security", [
      ("insecure tls opt-in default false", `Quick, test_insecure_tls_opt_in_default_false);
      ("insecure tls opt-in primary env", `Quick, test_insecure_tls_opt_in_primary_env);
      ("insecure tls opt-in legacy env", `Quick, test_insecure_tls_opt_in_legacy_env);
    ];
  ]
