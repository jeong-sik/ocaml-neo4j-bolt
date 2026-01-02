# ocaml-neo4j-bolt

Pure OCaml Neo4j Bolt protocol client.

## Features

- **Bolt 4.x/5.x** protocol support
- **PackStream** binary serialization ([spec](https://neo4j.com/docs/bolt/current/packstream/))
- Async I/O with Lwt

## Install

```bash
opam install neo4j_bolt
```

## Usage

```ocaml
let () = Lwt_main.run begin
  let open Lwt.Syntax in
  let* conn = Neo4j_bolt.Bolt.connect () in
  match conn with
  | Error e -> print_endline (Neo4j_bolt.Bolt.error_to_string e); Lwt.return ()
  | Ok c ->
    let* res = Neo4j_bolt.Bolt.query c ~cypher:"MATCH (n) RETURN count(n)" () in
    let* () = Neo4j_bolt.Bolt.close c in
    (match res with Ok j -> print_endline (Yojson.Safe.to_string j) | _ -> ());
    Lwt.return ()
end
```

## Config

```bash
export NEO4J_PASSWORD="your-password"
```

Or:

```ocaml
let config = Neo4j_bolt.Bolt.{
  host = "localhost"; port = 7687;
  username = "neo4j"; password = "secret";
  timeout_s = 30.0;
}
```

## License

MIT
