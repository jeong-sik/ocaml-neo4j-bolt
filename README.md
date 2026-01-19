# ocaml-neo4j-bolt

Pure OCaml Neo4j Bolt protocol client with TLS support.

## Features

- **Bolt 4.x/5.x** protocol support
- **TLS/SSL** connections (`bolt+s://`, `bolt+ssc://`)
- **PackStream** binary serialization ([spec](https://neo4j.com/docs/bolt/current/packstream/))
- **Two async backends**: Lwt (monadic) or Eio (direct-style)
- No Python subprocess required

## Packages

| Package | Backend | OCaml | Description |
|---------|---------|-------|-------------|
| `neo4j_bolt` | Lwt | >= 4.14 | Monadic async with TLS support |
| `neo4j_bolt_eio` | Eio | >= 5.0 | Direct-style with structured concurrency |

## Install

```bash
# Lwt version (TLS support)
opam install neo4j_bolt

# Eio version (OCaml 5.0+)
opam install neo4j_bolt_eio
```

## Quick Start

### Lwt Version

```ocaml
let () = Lwt_main.run begin
  let open Lwt.Syntax in
  let open Neo4j_bolt.Bolt in

  (* Connect using environment variables *)
  let* conn = connect () in
  match conn with
  | Error e -> print_endline (error_to_string e); Lwt.return ()
  | Ok c ->
    Printf.printf "Connected: %s\n" (connection_info c);

    (* Run query *)
    let* res = query c ~cypher:"MATCH (n) RETURN count(n) as total" () in
    let* () = close c in
    (match res with
     | Ok j -> print_endline (Yojson.Safe.to_string j)
     | Error e -> print_endline (error_to_string e));
    Lwt.return ()
end
```

### Eio Version

```ocaml
let () = Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in

  Eio.Switch.run @@ fun sw ->
  let config = Neo4j_bolt_eio.Bolt.{
    host = "localhost";
    port = 7687;
    username = "neo4j";
    password = "secret";
    timeout_s = 30.0;
  } in

  match Neo4j_bolt_eio.Bolt.connect ~sw ~net ~clock ~config () with
  | Error e -> print_endline (Neo4j_bolt_eio.Bolt.error_to_string e)
  | Ok c ->
    Printf.printf "Connected: %s\n" (Neo4j_bolt_eio.Bolt.connection_info c);

    (* Run query - no monadic syntax needed! *)
    (match Neo4j_bolt_eio.Bolt.query c ~cypher:"MATCH (n) RETURN count(n) as total" () with
     | Ok j -> print_endline (Yojson.Safe.to_string j)
     | Error e -> print_endline (Neo4j_bolt_eio.Bolt.error_to_string e));

    Neo4j_bolt_eio.Bolt.close c
```

## Connection Schemes

| Scheme | Description | Lwt | Eio |
|--------|-------------|-----|-----|
| `bolt://` | Plain TCP | ✅ | ✅ |
| `bolt+s://` | TLS with cert verification | ✅ | 🚧 |
| `bolts://` | Alias for `bolt+s://` | ✅ | 🚧 |
| `bolt+ssc://` | TLS without cert verification | ✅ | 🚧 |

> 🚧 Eio TLS support coming soon via `tls-eio`

### URI-based Connection

```ocaml
(* Lwt *)
let* conn = Neo4j_bolt.Bolt.connect_uri
  ~uri:"bolt+s://neo4j.example.com:7687"
  ~username:"neo4j"
  ~password:"secret"
  () in

(* Eio *)
let conn = Neo4j_bolt_eio.Bolt.connect_uri ~sw ~net ~clock
  ~uri:"bolt://localhost:7687"
  ~username:"neo4j"
  ~password:"secret"
  () in
```

## Configuration

### Environment Variables

```bash
# Option 1: URI (recommended)
export NEO4J_URI="bolt+s://neo4j.example.com:7687"
export NEO4J_USERNAME="neo4j"
export NEO4J_PASSWORD="your-password"

# Option 2: Individual settings
export NEO4J_HOST="localhost"
export NEO4J_PORT="7687"
export NEO4J_USERNAME="neo4j"
export NEO4J_PASSWORD="your-password"
```

### Programmatic Config

```ocaml
(* Lwt *)
let config = Neo4j_bolt.Bolt.{
  host = "localhost";
  port = 7687;
  username = "neo4j";
  password = "secret";
  timeout_s = 30.0;
  tls_mode = NoTLS;  (* or TLS, TLSSelfSigned *)
}

(* Eio *)
let config = Neo4j_bolt_eio.Bolt.{
  host = "localhost";
  port = 7687;
  username = "neo4j";
  password = "secret";
  timeout_s = 30.0;
}
```

## API Reference

### Connection

- `connect` - Connect using default/environment config
- `connect_uri` - Connect using URI string
- `close` - Close connection
- `is_tls_connection` - Check if TLS is enabled (Lwt only)
- `connection_info` - Get connection info string

### Queries

- `run` - Execute Cypher query (returns PackStream)
- `query` - Execute Cypher query (returns JSON)
- `test_connection` - Verify connection with simple query
- `count_nodes` - Count nodes with a label

### Types

- `tls_mode` - `NoTLS | TLS | TLSSelfSigned` (Lwt only)
- `error` - `ConnectionError | HandshakeError | AuthError | ProtocolError | Timeout`

## Examples

### Count Nodes

```ocaml
(* Lwt *)
let* result = Neo4j_bolt.Bolt.count_nodes conn ~label:"Person" in
match result with
| Ok count -> Printf.printf "Found %d Person nodes\n" count
| Error e -> print_endline (Neo4j_bolt.Bolt.error_to_string e)

(* Eio *)
match Neo4j_bolt_eio.Bolt.count_nodes conn ~label:"Person" with
| Ok count -> Printf.printf "Found %d Person nodes\n" count
| Error e -> print_endline (Neo4j_bolt_eio.Bolt.error_to_string e)
```

### Parameterized Query

```ocaml
let params = `Assoc [("name", `String "Alice")] in

(* Lwt *)
let* result = Neo4j_bolt.Bolt.query conn
  ~cypher:"MATCH (p:Person {name: $name}) RETURN p"
  ~params
  () in

(* Eio *)
let result = Neo4j_bolt_eio.Bolt.query conn
  ~cypher:"MATCH (p:Person {name: $name}) RETURN p"
  ~params
  () in
```

## Requirements

### neo4j_bolt (Lwt)
- OCaml >= 4.14
- lwt, lwt_ppx
- lwt_ssl, ssl (for TLS support)
- yojson

### neo4j_bolt_eio (Eio)
- OCaml >= 5.0
- eio, eio_main
- tls-eio (for future TLS support)
- yojson

## License

MIT
