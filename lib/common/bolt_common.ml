(** Shared utility functions for Neo4j Bolt protocol clients.

    These functions are backend-agnostic (no Eio/Lwt dependency)
    and used by both [neo4j_bolt] (Lwt) and [neo4j_bolt_eio]. *)

(** Normalize a string to lowercase after trimming whitespace. *)
let normalize_lower s = String.lowercase_ascii (String.trim s)

(** Check whether the environment variable [name] is set to a truthy value.
    Recognises ["1"], ["true"], and ["yes"] (case-insensitive, trimmed). *)
let env_truthy name =
  match Sys.getenv_opt name with
  | Some v ->
    let v = normalize_lower v in
    v = "1" || v = "true" || v = "yes"
  | None -> false

(** Returns [true] when the user has explicitly opted in to insecure
    (self-signed / unverified) TLS by setting [ALLOW_INSECURE_TLS=1]
    or [NEO4J_ALLOW_INSECURE_TLS=1]. *)
let insecure_tls_opt_in_enabled () =
  env_truthy "ALLOW_INSECURE_TLS"
  || env_truthy "NEO4J_ALLOW_INSECURE_TLS"
