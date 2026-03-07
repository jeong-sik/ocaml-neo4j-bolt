(** Neo4j Bolt Protocol Client for OCaml (Eio Version)

    Pure OCaml implementation of the Bolt protocol for Neo4j.
    Uses Eio for direct-style async I/O.
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

(** Parse URI to extract host, port, and TLS mode *)
let parse_uri uri =
  let uri = String.trim uri in
  let scheme_end =
    try String.index uri ':'
    with Not_found -> 0
  in
  let scheme = String.lowercase_ascii (String.sub uri 0 scheme_end) in
  let tls_mode = match scheme with
    | "bolt" -> NoTLS
    | "bolt+s" | "bolts" -> TLS
    | "bolt+ssc" -> TLSSelfSigned
    | _ -> NoTLS
  in
  let rest_start =
    if String.length uri > scheme_end + 3 &&
       String.sub uri scheme_end 3 = "://"
    then scheme_end + 3
    else scheme_end + 1
  in
  let rest = String.sub uri rest_start (String.length uri - rest_start) in
  let host_port =
    try String.sub rest 0 (String.index rest '/')
    with Not_found -> rest
  in
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

let config_from_uri ?(username="neo4j") ?(password="") ?(timeout_s=30.0) uri =
  let (host, port, tls_mode) = parse_uri uri in
  { host; port; username; password; timeout_s; tls_mode }

(** Connection state - using 'a for flow type to support both sockets and TLS *)
type 'a connection = {
  flow: 'a Eio.Resource.t;
  reader: Eio.Buf_read.t;
  version: version;
  timeout_s: float;
  mutable server_info: (string * Packstream.value) list;
  tls_mode: tls_mode;
}

(** Socket connection type *)
type socket_connection = [ `Generic ] Eio.Net.stream_socket_ty connection

(** Error types *)
type error =
  | ConnectionError of string
  | HandshakeError of string
  | AuthError of string
  | ProtocolError of string * string
  | Timeout

let error_to_string = function
  | ConnectionError msg -> Printf.sprintf "Connection error: %s" msg
  | HandshakeError msg -> Printf.sprintf "Handshake error: %s" msg
  | AuthError msg -> Printf.sprintf "Auth error: %s" msg
  | ProtocolError (code, msg) -> Printf.sprintf "Protocol error [%s]: %s" code msg
  | Timeout -> "Request timeout"

(** Run a function with timeout, converting Eio timeout to our error type *)
let with_timeout clock timeout_s f =
  let result =
    Eio.Fiber.first
      (fun () -> `Ok (f ()))
      (fun () ->
        Eio.Time.sleep clock timeout_s;
        `Timeout)
  in
  match result with
  | `Timeout -> Error Timeout
  | `Ok r -> r

(** Write 16-bit big-endian integer *)
let write_be16 buf n =
  Eio.Buf_write.uint8 buf ((n lsr 8) land 0xFF);
  Eio.Buf_write.uint8 buf (n land 0xFF)

(** Write 32-bit big-endian integer *)
let write_be32 buf n =
  Eio.Buf_write.uint8 buf (Int32.to_int (Int32.shift_right_logical n 24) land 0xFF);
  Eio.Buf_write.uint8 buf (Int32.to_int (Int32.shift_right_logical n 16) land 0xFF);
  Eio.Buf_write.uint8 buf (Int32.to_int (Int32.shift_right_logical n 8) land 0xFF);
  Eio.Buf_write.uint8 buf (Int32.to_int n land 0xFF)

(** Read 16-bit big-endian integer *)
let read_be16 reader =
  let b1 = Eio.Buf_read.uint8 reader in
  let b2 = Eio.Buf_read.uint8 reader in
  (b1 lsl 8) lor b2

(** Read 32-bit big-endian integer *)
let read_be32 reader =
  let b1 = Eio.Buf_read.uint8 reader in
  let b2 = Eio.Buf_read.uint8 reader in
  let b3 = Eio.Buf_read.uint8 reader in
  let b4 = Eio.Buf_read.uint8 reader in
  Int32.logor
    (Int32.logor
       (Int32.shift_left (Int32.of_int b1) 24)
       (Int32.shift_left (Int32.of_int b2) 16))
    (Int32.logor
       (Int32.shift_left (Int32.of_int b3) 8)
       (Int32.of_int b4))

(** Write bytes with chunking (Bolt uses 16-bit size prefix) *)
let write_message flow (msg : bytes) =
  let len = Bytes.length msg in
  Eio.Buf_write.with_flow flow @@ fun buf ->
  let rec write_chunks offset =
    if offset >= len then
      (* End marker: zero-length chunk *)
      write_be16 buf 0
    else
      let chunk_size = min (len - offset) 65535 in
      write_be16 buf chunk_size;
      Eio.Buf_write.bytes buf (Bytes.sub msg offset chunk_size);
      write_chunks (offset + chunk_size)
  in
  write_chunks 0

(** Read a complete message (handle chunking) *)
let read_message reader =
  let buffer = Buffer.create 256 in
  let rec read_chunks () =
    let chunk_size = read_be16 reader in
    if chunk_size = 0 then
      Buffer.to_bytes buffer
    else begin
      let chunk = Eio.Buf_read.take chunk_size reader in
      Buffer.add_string buffer chunk;
      read_chunks ()
    end
  in
  read_chunks ()

(** Perform Bolt handshake *)
let handshake flow reader =
  (* Send magic bytes + version proposals *)
  Eio.Buf_write.with_flow flow @@ fun buf ->
  Eio.Buf_write.string buf magic_bytes;
  let versions = [
    { major = 5; minor = 0 };
    { major = 4; minor = 4 };
    { major = 4; minor = 3 };
    { major = 4; minor = 0 };
  ] in
  List.iter (fun v -> write_be32 buf (version_to_int32 v)) versions;
  (* Read server's chosen version *)
  let chosen = read_be32 reader in
  if chosen = 0l then
    Error (HandshakeError "Server rejected all protocol versions")
  else
    Ok (int32_to_version chosen)

(** Send a Bolt message *)
let send_message flow tag fields =
  let msg = Packstream.Structure (tag, fields) in
  let packed = Packstream.pack msg in
  write_message flow packed

(** Receive a Bolt message *)
let recv_message reader =
  let data = read_message reader in
  try
    let value = Packstream.unpack data in
    match value with
    | Packstream.Structure (tag, fields) -> Ok (tag, fields)
    | _ -> Error (ProtocolError ("UNEXPECTED", "Expected structure"))
  with
  | Failure msg -> Error (ProtocolError ("PARSE", msg))
  | Invalid_argument msg -> Error (ProtocolError ("PARSE", msg))
  | End_of_file -> Error (ProtocolError ("PARSE", "Unexpected end of stream"))
  | exn -> Error (ProtocolError ("PARSE_UNKNOWN", Printexc.to_string exn))

(** Send HELLO message and authenticate *)
let authenticate conn ~username ~password =
  let extra = Packstream.Map [
    ("user_agent", Packstream.String "neo4j-bolt-ocaml-eio/1.0");
    ("scheme", Packstream.String "basic");
    ("principal", Packstream.String username);
    ("credentials", Packstream.String password);
  ] in
  send_message conn.flow Tag.hello [extra];
  match recv_message conn.reader with
  | Ok (tag, fields) when tag = Tag.success ->
    (match fields with
     | [Packstream.Map server_info] ->
       conn.server_info <- server_info;
       Ok conn
     | _ -> Ok conn)
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
    if String.length code >= 20 &&
       String.sub code 0 20 = "Neo.ClientError.Secu" then
      Error (AuthError message)
    else
      Error (ProtocolError (code, message))
  | Ok (tag, _) ->
    Error (ProtocolError ("UNEXPECTED", Printf.sprintf "Unexpected tag: %d" tag))
  | Error e -> Error e

(** Connect to Neo4j server (Eio version)
    @param sw Eio switch for resource management
    @param net Eio network capability
    @param clock Eio clock for timeouts
    @param config Connection configuration *)
let connect ~sw ~net ~clock ?(config=default_config) () =
  if config.tls_mode = TLSSelfSigned && not (insecure_tls_opt_in_enabled ()) then
    Error
      (ConnectionError
         "Refusing TLSSelfSigned without explicit opt-in. Set ALLOW_INSECURE_TLS=1 (or NEO4J_ALLOW_INSECURE_TLS=1) for development only.")
  else
  try
    if config.tls_mode = TLSSelfSigned then
      Printf.eprintf
        "neo4j_bolt_eio: WARNING insecure TLS mode enabled for %s:%d (certificate verification disabled)\n%!"
        config.host config.port;
    (* Resolve hostname using Eio's DNS resolver - no Obj.magic! *)
    let service = string_of_int config.port in
    let addrs = Eio.Net.getaddrinfo_stream net config.host ~service in
    match addrs with
    | [] ->
      Error (ConnectionError (Printf.sprintf "Could not resolve host: %s" config.host))
    | addr :: _ ->
    let flow = Eio.Net.connect ~sw net addr in

    (* TODO: TLS support with tls-eio *)
    let _ = config.tls_mode in  (* Suppress unused warning for now *)

    let reader = Eio.Buf_read.of_flow ~max_size:(1024 * 1024) flow in

    (* Perform handshake with timeout using Fiber.first for racing *)
    let handshake_result =
      try
        Eio.Fiber.first
          (fun () -> `Handshake (handshake flow reader))
          (fun () ->
            Eio.Time.sleep clock config.timeout_s;
            `Timeout)
      with Eio.Io _ as exn ->
        `Error (ConnectionError (Printexc.to_string exn))
    in
    match handshake_result with
    | `Timeout -> Error Timeout
    | `Error e -> Error e
    | `Handshake (Error e) -> Error e
    | `Handshake (Ok version) ->
        let conn = {
          flow;
          reader;
          version;
          timeout_s = config.timeout_s;
          server_info = [];
          tls_mode = config.tls_mode;
        } in
        authenticate conn ~username:config.username ~password:config.password
  with
  | Unix.Unix_error (err, _, _) ->
    Error (ConnectionError (Unix.error_message err))
  | Eio.Io _ as exn ->
    Error (ConnectionError (Printexc.to_string exn))
  | Failure msg ->
    Error (ConnectionError ("Internal failure: " ^ msg))
  | Invalid_argument msg ->
    Error (ConnectionError ("Invalid argument: " ^ msg))

(** Close connection *)
let close conn =
  send_message conn.flow Tag.goodbye [];
  Eio.Flow.close conn.flow

(** Execute a Cypher query *)
let run ~clock conn ~cypher ?(params=Packstream.Map []) () =
  (* Send RUN message *)
  let extra = Packstream.Map [] in
  send_message conn.flow Tag.run [
    Packstream.String cypher;
    params;
    extra;
  ];

  (* Read RUN response with timeout *)
  let run_response =
    with_timeout clock conn.timeout_s (fun () ->
      recv_message conn.reader
    )
  in
  match run_response with
  | Error Timeout -> Error Timeout
  | Error e -> Error e
  | Ok (tag, _) when tag = Tag.failure ->
    Error (ProtocolError ("RUN_FAILED", "Query execution failed"))
  | Ok (tag, _) when tag <> Tag.success ->
    Error (ProtocolError ("UNEXPECTED", Printf.sprintf "Expected SUCCESS, got %d" tag))
  | Ok _ ->
    (* Send PULL message *)
    let pull_extra = Packstream.Map [("n", Packstream.Int (-1L))] in
    send_message conn.flow Tag.pull [pull_extra];

    (* Collect all records *)
    let rec collect_records acc =
      match with_timeout clock conn.timeout_s (fun () ->
        recv_message conn.reader
      ) with
      | Error Timeout -> Error Timeout
      | Error e -> Error e
      | Ok (tag, fields) when tag = Tag.record ->
        collect_records (fields :: acc)
      | Ok (tag, _) when tag = Tag.success ->
        Ok (List.rev acc)
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
        Error (ProtocolError (code, message))
      | Ok (tag, _) ->
        Error (ProtocolError ("UNEXPECTED", Printf.sprintf "Unexpected tag in PULL: %d" tag))
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
let query ~clock conn ~cypher ?(params=`Assoc []) () =
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
  match run ~clock conn ~cypher ~params:ps_params () with
  | Error e -> Error e
  | Ok records ->
    let json_records = List.map (fun fields ->
      `List (List.map packstream_to_yojson fields)
    ) records in
    Ok (`Assoc [("records", `List json_records)])

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
let test_connection ~clock conn =
  match run ~clock conn ~cypher:"RETURN 1 as n" () with
  | Ok records ->
    (match extract_first_int records with
     | Some 1L -> Ok true
     | _ -> Ok false)
  | Error e -> Error e

(** Get node count for a label *)
let count_nodes ~clock conn ~label =
  let cypher = Printf.sprintf "MATCH (n:%s) RETURN count(n) as count" label in
  match run ~clock conn ~cypher () with
  | Ok records ->
    (match extract_first_int records with
     | Some count -> Ok (Int64.to_int count)
     | None -> Ok 0)
  | Error e -> Error e

(** Connect using URI string *)
let connect_uri ~sw ~net ~clock ~uri ~username ~password ?timeout_s () =
  let config = config_from_uri ?timeout_s ~username ~password uri in
  connect ~sw ~net ~clock ~config ()

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
