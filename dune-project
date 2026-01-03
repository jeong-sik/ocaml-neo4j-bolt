(lang dune 3.0)
(name neo4j_bolt)
(version 0.3.0)
(license MIT)
(authors "Jeongshik Yoon <yousleepwhen@gmail.com>")
(maintainers "Jeongshik Yoon <yousleepwhen@gmail.com>")
(source (github jeong-sik/ocaml-neo4j-bolt))
(documentation https://jeong-sik.github.io/ocaml-neo4j-bolt)

(generate_opam_files true)

(package
 (name neo4j_bolt)
 (synopsis "Pure OCaml Neo4j Bolt protocol client with TLS support")
 (description "A pure OCaml implementation of the Neo4j Bolt protocol with TLS/SSL support. Supports bolt://, bolt+s://, and bolt+ssc:// connection schemes.")
 (depends
  (ocaml (>= 4.14))
  (dune (>= 3.0))
  (lwt (>= 5.6))
  (lwt_ppx (>= 2.1))
  (lwt_ssl (>= 1.2))
  (ssl (>= 0.7))
  (yojson (>= 2.0))))
