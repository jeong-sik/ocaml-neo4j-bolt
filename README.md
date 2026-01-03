# ocaml-neo4j-bolt

Pure OCaml Neo4j Bolt protocol client with TLS support.

## Features

- **Bolt 4.x/5.x** protocol support
- **TLS/SSL** connections (`bolt+s://`, `bolt+ssc://`)
- **PackStream** binary serialization ([spec](https://neo4j.com/docs/bolt/current/packstream/))
- Async I/O with Lwt
- No Python subprocess required

## Install

```bash
opam install neo4j_bolt
```

## Quick Start

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

## Connection Schemes

| Scheme | Description | Use Case |
|--------|-------------|----------|
| `bolt://` | Plain TCP | Local development |
| `bolt+s://` | TLS with cert verification | Production (Neo4j Aura, etc.) |
| `bolts://` | Alias for `bolt+s://` | Same as above |
| `bolt+ssc://` | TLS without cert verification | Self-signed certificates |

### URI-based Connection

```ocaml
let* conn = Neo4j_bolt.Bolt.connect_uri
  ~uri:"bolt+s://neo4j.example.com:7687"
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
let config = Neo4j_bolt.Bolt.{
  host = "localhost";
  port = 7687;
  username = "neo4j";
  password = "secret";
  timeout_s = 30.0;
  tls_mode = NoTLS;  (* or TLS, TLSSelfSigned *)
}
```

## API Reference

### Connection

- `connect` - Connect using default/environment config
- `connect_uri` - Connect using URI string
- `close` - Close connection
- `is_tls_connection` - Check if TLS is enabled
- `connection_info` - Get connection info string

### Queries

- `run` - Execute Cypher query (returns PackStream)
- `query` - Execute Cypher query (returns JSON)
- `test_connection` - Verify connection with simple query
- `count_nodes` - Count nodes with a label

### Types

- `tls_mode` - `NoTLS | TLS | TLSSelfSigned`
- `error` - `ConnectionError | HandshakeError | AuthError | ProtocolError | Timeout`

## Examples

### Count Nodes

```ocaml
let* result = Neo4j_bolt.Bolt.count_nodes conn ~label:"Person" in
match result with
| Ok count -> Printf.printf "Found %d Person nodes\n" count
| Error e -> print_endline (Neo4j_bolt.Bolt.error_to_string e)
```

### Parameterized Query

```ocaml
let params = `Assoc [("name", `String "Alice")] in
let* result = Neo4j_bolt.Bolt.query conn
  ~cypher:"MATCH (p:Person {name: $name}) RETURN p"
  ~params
  () in
```

## Requirements

- OCaml >= 4.14
- lwt, lwt_ppx
- lwt_ssl, ssl (for TLS support)
- yojson

## License

MIT
