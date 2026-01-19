(** Neo4j Bolt - Top-level module

    Re-exports Bolt and Packstream modules for compatibility.
*)

(** Re-export Bolt as submodule for backward compatibility *)
module Bolt = Bolt

(** Also include Bolt at top level for convenience *)
include Bolt

(** Re-export Packstream *)
module Packstream = Packstream
