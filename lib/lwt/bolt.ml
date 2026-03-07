(** Neo4j Bolt Protocol Client for OCaml

    Pure OCaml implementation of the Bolt protocol for Neo4j.
    Supports Bolt 4.x/5.x protocol versions.

    Reference: https://neo4j.com/docs/bolt/current/
*)

(** Bolt protocol constants *)
let magic_bytes = "\x60\x60\xB0\x17"
let default_port = 7687

(** Bolt message tags - https://neo4j.com/docs/bolt/current/bolt/message/ *)
module Tag = struct
  (* Request tags *)
  let hello = 0x01      (* HELLO - initialize connection *)
  let goodbye = 0x02    (* GOODBYE - close connection *)
  let reset = 0x0F      (* RESET - reset session state *)
  let run = 0x10        (* RUN - execute Cypher query *)
  let discard = 0x2F    (* DISCARD - discard pending results *)
  let pull = 0x3F       (* PULL - fetch results *)
  let begin_tx = 0x11   (* BEGIN - start transaction *)
  let commit = 0x12     (* COMMIT - commit transaction *)
  let rollback = 0x13   (* ROLLBACK - rollback transaction *)
  let route = 0x66      (* ROUTE - routing info (cluster) *)
  let logon = 0x6A      (* LOGON - re-authenticate *)
  let logoff = 0x6B     (* LOGOFF - de-authenticate *)

  (* Response tags *)
  let success = 0x70    (* SUCCESS - operation succeeded *)
  let record = 0x71     (* RECORD - result row *)
  let ignored = 0x7E    (* IGNORED - request ignored *)
  let failure = 0x7F    (* FAILURE - operation failed *)
end

(** Bolt version *)
type version = {
  major: int;
  minor: int;
}

let version_to_int32 v =
  Int32.logor
    (Int32.shift_left (Int32.of_int v.minor) 8)
    (Int32.of_int v.major)

let int32_to_version n =
  { major = Int32.to_int n land 0xFF;
    minor = Int32.to_int (Int32.shift_right n 8) land 0xFF }

(** TLS mode for connection *)
type tls_mode =
  | NoTLS              (* bolt:// - plain TCP *)
  | TLS                (* bolt+s:// - TLS with cert verification *)
  | TLSSelfSigned      (* bolt+ssc:// - TLS without cert verification *)

let insecure_tls_opt_in_enabled = Bolt_common.insecure_tls_opt_in_enabled

(** Configuration *)
type config = {
  host: string;
  port: int;
  username: string;
  password: string;
  timeout_s: float;
  tls_mode: tls_mode;
}

(** Parse URI to extract host, port, and TLS mode
    Supported schemes: bolt://, bolt+s://, bolt+ssc://, bolts://
*)
let parse_uri uri =
  let uri = String.trim uri in
  (* Extract scheme *)
  let scheme_end =
    try String.index uri ':'
    with Not_found -> 0
  in
  let scheme = String.lowercase_ascii (String.sub uri 0 scheme_end) in

  (* Determine TLS mode from scheme *)
  let tls_mode = match scheme with
    | "bolt" -> NoTLS
    | "bolt+s" | "bolts" -> TLS
    | "bolt+ssc" -> TLSSelfSigned
    | _ -> NoTLS  (* default to plain if unknown *)
  in

  (* Extract host:port from rest of URI *)
  let rest_start =
    if String.length uri > scheme_end + 3 &&
       String.sub uri scheme_end 3 = "://"
    then scheme_end + 3
    else scheme_end + 1
  in
  let rest = String.sub uri rest_start (String.length uri - rest_start) in

  (* Remove trailing path if any *)
  let host_port =
    try String.sub rest 0 (String.index rest '/')
    with Not_found -> rest
  in

  (* Split host:port *)
  let (host, port) =
    try
      let colon = String.rindex host_port ':' in
      let h = String.sub host_port 0 colon in
      let p = String.sub host_port (colon + 1) (String.length host_port - colon - 1) in
      (h, int_of_string_opt p |> Option.value ~default:7687)
    with Not_found -> (host_port, 7687)
  in

  (host, port, tls_mode)

let default_config =
  (* Check for URI first (preferred), then individual vars *)
  let uri = Sys.getenv_opt "NEO4J_URI" in
  match uri with
  | Some u ->
    let (host, port, tls_mode) = parse_uri u in
    {
      host;
      port;
      username = Sys.getenv_opt "NEO4J_USERNAME" |> Option.value ~default:"neo4j";
      password = Sys.getenv_opt "NEO4J_PASSWORD" |> Option.value ~default:"";
      timeout_s = (match Sys.getenv_opt "NEO4J_TIMEOUT" with
        | Some t -> float_of_string_opt t |> Option.value ~default:30.0
        | None -> 30.0);
      tls_mode;
    }
  | None ->
    {
      host = Sys.getenv_opt "NEO4J_HOST" |> Option.value ~default:"localhost";
      port = (match Sys.getenv_opt "NEO4J_PORT" with
        | Some p -> int_of_string_opt p |> Option.value ~default:7687
        | None -> 7687);
      username = Sys.getenv_opt "NEO4J_USERNAME" |> Option.value ~default:"neo4j";
      password = Sys.getenv_opt "NEO4J_PASSWORD" |> Option.value ~default:"";
      timeout_s = (match Sys.getenv_opt "NEO4J_TIMEOUT" with
        | Some t -> float_of_string_opt t |> Option.value ~default:30.0
        | None -> 30.0);
      tls_mode = NoTLS;
    }

(** Create config from URI string *)
let config_from_uri ?(username="neo4j") ?(password="") ?(timeout_s=30.0) uri =
  let (host, port, tls_mode) = parse_uri uri in
  { host; port; username; password; timeout_s; tls_mode }

(** Connection state *)
type connection = {
  ic: Lwt_io.input_channel;
  oc: Lwt_io.output_channel;
  version: version;
  timeout_s: float;
  mutable server_info: (string * Packstream.value) list;
  ssl_socket: Lwt_ssl.socket option;  (* For TLS connections *)
  tls_mode: tls_mode;
}

(** Error types *)
type error =
  | ConnectionError of string
  | HandshakeError of string
  | AuthError of string
  | ProtocolError of string * string  (* code, message *)
  | Timeout

let error_to_string = function
  | ConnectionError msg -> Printf.sprintf "Connection error: %s" msg
  | HandshakeError msg -> Printf.sprintf "Handshake error: %s" msg
  | AuthError msg -> Printf.sprintf "Auth error: %s" msg
  | ProtocolError (code, msg) -> Printf.sprintf "Protocol error [%s]: %s" code msg
  | Timeout -> "Request timeout"

(** Write bytes with chunking (Bolt uses 16-bit size prefix) *)
let write_message oc (msg : bytes) =
  let len = Bytes.length msg in
  (* Chunk the message (max chunk size is 65535) *)
  let rec write_chunks offset =
    if offset >= len then
      (* End marker: zero-length chunk *)
      let%lwt () = Lwt_io.BE.write_int16 oc 0 in
      Lwt_io.flush oc
    else
      let chunk_size = min (len - offset) 65535 in
      let%lwt () = Lwt_io.BE.write_int16 oc chunk_size in
      let%lwt () = Lwt_io.write_from_exactly oc msg offset chunk_size in
      write_chunks (offset + chunk_size)
  in
  write_chunks 0

(** Read a complete message (handle chunking) with timeout *)
let read_message ~timeout_s ic =
  let buffer = Buffer.create 256 in
  let rec read_chunks () =
    let%lwt chunk_size = Lwt_io.BE.read_int16 ic in
    if chunk_size = 0 then
      Lwt.return_ok (Buffer.to_bytes buffer)
    else begin
      let chunk = Bytes.create chunk_size in
      let%lwt () = Lwt_io.read_into_exactly ic chunk 0 chunk_size in
      Buffer.add_bytes buffer chunk;
      read_chunks ()
    end
  in
  (* Apply timeout *)
  Lwt.pick [
    read_chunks ();
    (let%lwt () = Lwt_unix.sleep timeout_s in Lwt.return_error Timeout)
  ]

(** Perform Bolt handshake *)
let handshake ic oc =
  (* Send magic bytes *)
  let%lwt () = Lwt_io.write oc magic_bytes in

  (* Send 4 version proposals (we support 5.0, 4.4, 4.3, 4.0) *)
  let versions = [
    { major = 5; minor = 0 };
    { major = 4; minor = 4 };
    { major = 4; minor = 3 };
    { major = 4; minor = 0 };
  ] in
  let%lwt () = Lwt_list.iter_s (fun v ->
    Lwt_io.BE.write_int32 oc (version_to_int32 v)
  ) versions in
  let%lwt () = Lwt_io.flush oc in

  (* Read server's chosen version *)
  let%lwt chosen = Lwt_io.BE.read_int32 ic in
  if chosen = 0l then
    Lwt.return_error (HandshakeError "Server rejected all protocol versions")
  else
    let version = int32_to_version chosen in
    Lwt.return_ok version

(** Send a Bolt message *)
let send_message oc tag fields =
  let msg = Packstream.Structure (tag, fields) in
  let packed = Packstream.pack msg in
  write_message oc packed

(** Receive a Bolt message with timeout *)
let recv_message ~timeout_s ic =
  let%lwt data_result = read_message ~timeout_s ic in
  match data_result with
  | Error e -> Lwt.return_error e
  | Ok data ->
    try
      let value = Packstream.unpack data in
      match value with
      | Packstream.Structure (tag, fields) -> Lwt.return_ok (tag, fields)
      | _ -> Lwt.return_error (ProtocolError ("UNEXPECTED", "Expected structure"))
    with exn ->
      Lwt.return_error (ProtocolError ("PARSE", Printexc.to_string exn))

(** Send HELLO message and authenticate *)
let authenticate conn ~username ~password =
  let extra = Packstream.Map [
    ("user_agent", Packstream.String "neo4j-bolt-ocaml/1.0");
    ("scheme", Packstream.String "basic");
    ("principal", Packstream.String username);
    ("credentials", Packstream.String password);
  ] in
  let%lwt () = send_message conn.oc Tag.hello [extra] in
  let%lwt response = recv_message ~timeout_s:conn.timeout_s conn.ic in
  match response with
  | Ok (tag, fields) when tag = Tag.success ->
    (match fields with
     | [Packstream.Map server_info] ->
       Lwt.return_ok { conn with server_info }
     | _ ->
       Lwt.return_ok conn)
  | Ok (tag, fields) when tag = Tag.failure ->
    let code = match fields with
      | [Packstream.Map m] ->
        (match List.assoc_opt "code" m with
         | Some (Packstream.String c) -> c
         | _ -> "UNKNOWN")
      | _ -> "UNKNOWN"
    in
    let message = match fields with
      | [Packstream.Map m] ->
        (match List.assoc_opt "message" m with
         | Some (Packstream.String msg) -> msg
         | _ -> "Authentication failed")
      | _ -> "Authentication failed"
    in
    if String.sub code 0 (min 20 (String.length code)) = "Neo.ClientError.Secu" then
      Lwt.return_error (AuthError message)
    else
      Lwt.return_error (ProtocolError (code, message))
  | Ok (tag, _) ->
    Lwt.return_error (ProtocolError ("UNEXPECTED", Printf.sprintf "Unexpected tag: %d" tag))
  | Error e ->
    Lwt.return_error e

(** Create SSL context based on TLS mode *)
let create_ssl_context = function
  | NoTLS -> None
  | TLS ->
    let ctx = Ssl.create_context Ssl.TLSv1_2 Ssl.Client_context in
    Ssl.set_verify ctx [Ssl.Verify_peer] None;
    (* Use system CA certificates *)
    (let ok = try Ssl.set_default_verify_paths ctx with exn ->
       Printf.eprintf "neo4j_bolt: WARNING: exception loading system CA certificates: %s\n%!"
         (Printexc.to_string exn);
       false
     in
     if not ok then
       Printf.eprintf "neo4j_bolt: WARNING: failed to load system CA certificates; peer verification may fail\n%!");
    Some ctx
  | TLSSelfSigned ->
    let ctx = Ssl.create_context Ssl.TLSv1_2 Ssl.Client_context in
    (* No verification for self-signed certs *)
    Ssl.set_verify ctx [] None;
    Some ctx

(** Connect to Neo4j server
    Supports bolt://, bolt+s:// (TLS), and bolt+ssc:// (self-signed TLS)
*)
let connect ?(config=default_config) () =
  if config.tls_mode = TLSSelfSigned && not (insecure_tls_opt_in_enabled ()) then
    Lwt.return_error
      (ConnectionError
         "Refusing TLSSelfSigned without explicit opt-in. Set ALLOW_INSECURE_TLS=1 (or NEO4J_ALLOW_INSECURE_TLS=1) for development only.")
  else
  try%lwt
    if config.tls_mode = TLSSelfSigned then
      Printf.eprintf
        "neo4j_bolt: WARNING insecure TLS mode enabled for %s:%d (certificate verification disabled)\n%!"
        config.host config.port;
    (* Resolve hostname — non-blocking via Lwt_unix.getaddrinfo *)
    let%lwt addrs = Lwt_unix.getaddrinfo config.host (string_of_int config.port)
        [Unix.AI_SOCKTYPE Unix.SOCK_STREAM; Unix.AI_FAMILY Unix.PF_INET] in
    let ai = match addrs with
      | [] -> failwith (Printf.sprintf "DNS resolution failed for %s" config.host)
      | ai :: _ -> ai
    in
    let addr = ai.Unix.ai_addr in

    (* Create connection based on TLS mode *)
    let%lwt (ic, oc, ssl_socket) =
      match config.tls_mode with
      | NoTLS ->
        (* Plain TCP connection *)
        let%lwt (ic, oc) = Lwt_io.open_connection addr in
        Lwt.return (ic, oc, None)

      | TLS | TLSSelfSigned as tls_mode ->
        (* TLS connection using Lwt_ssl *)
        let ctx = match create_ssl_context tls_mode with
          | Some c -> c
          | None -> failwith "Failed to create SSL context"
        in
        let fd = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
        let%lwt () = Lwt_unix.connect fd addr in
        let%lwt ssl_sock = Lwt_ssl.ssl_connect fd ctx in
        let ic = Lwt_ssl.in_channel_of_descr ssl_sock in
        let oc = Lwt_ssl.out_channel_of_descr ssl_sock in
        Lwt.return (ic, oc, Some ssl_sock)
    in

    (* Perform Bolt handshake *)
    let%lwt version_result = handshake ic oc in
    match version_result with
    | Error e -> Lwt.return_error e
    | Ok version ->
      let conn = {
        ic; oc; version;
        timeout_s = config.timeout_s;
        server_info = [];
        ssl_socket;
        tls_mode = config.tls_mode;
      } in
      (* Authenticate *)
      authenticate conn
        ~username:config.username
        ~password:config.password
  with
  | Unix.Unix_error (err, _, _) ->
    Lwt.return_error (ConnectionError (Unix.error_message err))
  | Ssl.Connection_error _ | Ssl.Accept_error _ | Ssl.Read_error _ | Ssl.Write_error _ as e ->
    Lwt.return_error (ConnectionError (Printf.sprintf "SSL error: %s" (Printexc.to_string e)))
  | exn ->
    Lwt.return_error (ConnectionError (Printexc.to_string exn))

(** Close connection *)
let close conn =
  let%lwt () = send_message conn.oc Tag.goodbye [] in
  match conn.ssl_socket with
  | Some ssl_sock ->
    (* SSL connection - close properly *)
    let%lwt () = Lwt_ssl.ssl_shutdown ssl_sock in
    Lwt_ssl.close ssl_sock
  | None ->
    (* Plain connection *)
    let%lwt () = Lwt_io.close conn.oc in
    Lwt_io.close conn.ic

(** Execute a Cypher query *)
let run conn ~cypher ?(params=Packstream.Map []) () =
  (* Send RUN message *)
  let extra = Packstream.Map [] in
  let%lwt () = send_message conn.oc Tag.run [
    Packstream.String cypher;
    params;
    extra;
  ] in

  (* Read RUN response (SUCCESS with metadata) *)
  let%lwt run_response = recv_message ~timeout_s:conn.timeout_s conn.ic in
  match run_response with
  | Error e -> Lwt.return_error e
  | Ok (tag, _) when tag = Tag.failure ->
    Lwt.return_error (ProtocolError ("RUN_FAILED", "Query execution failed"))
  | Ok (tag, _) when tag <> Tag.success ->
    Lwt.return_error (ProtocolError ("UNEXPECTED", Printf.sprintf "Expected SUCCESS, got %d" tag))
  | Ok _ ->
    (* Send PULL message to get all results *)
    let pull_extra = Packstream.Map [("n", Packstream.Int (-1L))] in
    let%lwt () = send_message conn.oc Tag.pull [pull_extra] in

    (* Collect all records (functional style - no ref) *)
    let rec collect_records acc =
      let%lwt response = recv_message ~timeout_s:conn.timeout_s conn.ic in
      match response with
      | Error e -> Lwt.return_error e
      | Ok (tag, fields) when tag = Tag.record ->
        collect_records (fields :: acc)
      | Ok (tag, _) when tag = Tag.success ->
        Lwt.return_ok (List.rev acc)
      | Ok (tag, fields) when tag = Tag.failure ->
        let code = match fields with
          | [Packstream.Map m] ->
            (match List.assoc_opt "code" m with
             | Some (Packstream.String c) -> c
             | _ -> "UNKNOWN")
          | _ -> "UNKNOWN"
        in
        let message = match fields with
          | [Packstream.Map m] ->
            (match List.assoc_opt "message" m with
             | Some (Packstream.String msg) -> msg
             | _ -> "Query failed")
          | _ -> "Query failed"
        in
        Lwt.return_error (ProtocolError (code, message))
      | Ok (tag, _) ->
        Lwt.return_error (ProtocolError ("UNEXPECTED", Printf.sprintf "Unexpected tag in PULL: %d" tag))
    in
    collect_records []

(** Convert PackStream value to Yojson *)
let rec packstream_to_yojson = function
  | Packstream.Null -> `Null
  | Packstream.Bool b -> `Bool b
  | Packstream.Int n -> `Int (Int64.to_int n)
  | Packstream.Float f -> `Float f
  | Packstream.String s -> `String s
  | Packstream.Bytes _ -> `String "<bytes>"
  | Packstream.List items -> `List (List.map packstream_to_yojson items)
  | Packstream.Map entries ->
    `Assoc (List.map (fun (k, v) -> (k, packstream_to_yojson v)) entries)
  | Packstream.Structure (tag, fields) ->
    `Assoc [
      ("_struct_tag", `Int tag);
      ("fields", `List (List.map packstream_to_yojson fields));
    ]

(** Run query and return JSON result *)
let query conn ~cypher ?(params=`Assoc []) () =
  (* Convert Yojson params to PackStream *)
  let rec yojson_to_packstream = function
    | `Null -> Packstream.Null
    | `Bool b -> Packstream.Bool b
    | `Int n -> Packstream.Int (Int64.of_int n)
    | `Float f -> Packstream.Float f
    | `String s -> Packstream.String s
    | `List items -> Packstream.List (List.map yojson_to_packstream items)
    | `Assoc entries -> Packstream.Map (List.map (fun (k, v) -> (k, yojson_to_packstream v)) entries)
    | _ -> Packstream.Null
  in
  let ps_params = yojson_to_packstream params in
  let%lwt result = run conn ~cypher ~params:ps_params () in
  match result with
  | Error e -> Lwt.return_error e
  | Ok records ->
    let json_records = List.map (fun fields ->
      `List (List.map packstream_to_yojson fields)
    ) records in
    Lwt.return_ok (`Assoc [("records", `List json_records)])

(** Helper: extract first int from record result *)
let extract_first_int records =
  match records with
  | [fields] ->
    (match fields with
     | [Packstream.Int n] -> Some n
     | [Packstream.List items] ->
       (match items with
        | Packstream.Int n :: _ -> Some n
        | _ -> None)
     | _ -> None)
  | _ -> None

(** Test connection with simple query *)
let test_connection conn =
  let%lwt result = run conn ~cypher:"RETURN 1 as n" () in
  match result with
  | Ok records ->
    (match extract_first_int records with
     | Some 1L -> Lwt.return_ok true
     | _ -> Lwt.return_ok false)
  | Error e -> Lwt.return_error e

(** Get node count for a label *)
let count_nodes conn ~label =
  let cypher = Printf.sprintf "MATCH (n:%s) RETURN count(n) as count" label in
  let%lwt result = run conn ~cypher () in
  match result with
  | Ok records ->
    (match extract_first_int records with
     | Some count -> Lwt.return_ok (Int64.to_int count)
     | None -> Lwt.return_ok 0)
  | Error e -> Lwt.return_error e

(** Connect using URI string (convenience function)
    Examples:
    - "bolt://localhost:7687"
    - "bolt+s://neo4j.example.com:7687" (TLS)
    - "bolt+ssc://neo4j.example.com:7687" (self-signed TLS)
*)
let connect_uri ~uri ~username ~password ?timeout_s () =
  let config = config_from_uri ?timeout_s ~username ~password uri in
  connect ~config ()

(** Check if connection uses TLS *)
let is_tls_connection conn =
  match conn.tls_mode with
  | NoTLS -> false
  | TLS | TLSSelfSigned -> true

(** Get TLS mode description *)
let tls_mode_to_string = function
  | NoTLS -> "plain"
  | TLS -> "tls"
  | TLSSelfSigned -> "tls-self-signed"

(** Get connection info as string *)
let connection_info conn =
  let tls_str = tls_mode_to_string conn.tls_mode in
  Printf.sprintf "Neo4j Bolt %d.%d (%s)"
    conn.version.major conn.version.minor tls_str
