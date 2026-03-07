(lang dune 3.13)
(name neo4j_bolt)
(version 0.5.1)
(license MIT)
(authors "Jeongshik Yoon <yousleepwhen@gmail.com>")
(maintainers "Jeongshik Yoon <yousleepwhen@gmail.com>")
(source (github jeong-sik/ocaml-neo4j-bolt))
(documentation https://jeong-sik.github.io/ocaml-neo4j-bolt)

(generate_opam_files true)

; Shared utilities (backend-agnostic, no Lwt/Eio dependency)
(package
 (name neo4j_bolt_common)
 (synopsis "Shared utilities for Neo4j Bolt protocol clients")
 (description "Backend-agnostic helper functions shared by both the Lwt and Eio Neo4j Bolt protocol clients.")
 (depends
  (ocaml (>= 4.14))
  (dune (>= 3.13))
  (bisect_ppx (and :with-test (>= 2.8)))))

; PackStream serialization library (shared by both Lwt and Eio versions)
(package
 (name neo4j_packstream)
 (synopsis "PackStream binary serialization format for Neo4j Bolt protocol")
 (description "Pure OCaml implementation of PackStream, the binary serialization format used by Neo4j's Bolt protocol. No async dependencies - can be used with any runtime.")
 (depends
  (ocaml (>= 4.14))
  (dune (>= 3.13))
  (bisect_ppx (and :with-test (>= 2.8)))))

; Main package (Lwt version)
(package
 (name neo4j_bolt)
 (synopsis "Pure OCaml Neo4j Bolt protocol client with TLS support (Lwt)")
 (description "A pure OCaml implementation of the Neo4j Bolt protocol with TLS/SSL support. Uses Lwt for async I/O. Supports bolt://, bolt+s://, and bolt+ssc:// connection schemes.")
 (depends
  (ocaml (>= 4.14))
  (dune (>= 3.13))
  (neo4j_bolt_common (= :version))
  (neo4j_packstream (= :version))
  (lwt (>= 5.6))
  (lwt_ppx (>= 2.1))
  (lwt_ssl (>= 1.2))
  (ssl (>= 0.7))
  (yojson (>= 2.0))
  (alcotest :with-test)
  (bisect_ppx (and :with-test (>= 2.8)))))

; Eio version package
(package
 (name neo4j_bolt_eio)
 (synopsis "Pure OCaml Neo4j Bolt protocol client (Eio)")
 (description "A pure OCaml implementation of the Neo4j Bolt protocol using Eio for direct-style async I/O. Supports bolt:// connections.")
 (depends
  (ocaml (>= 5.0))
  (dune (>= 3.13))
  (neo4j_bolt_common (= :version))
  (neo4j_packstream (= :version))
  (eio (>= 1.0))
  (eio_main (>= 1.0))
  (tls-eio (>= 1.0))
  (yojson (>= 2.0))
  (bisect_ppx (and :with-test (>= 2.8)))))
