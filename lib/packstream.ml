(** PackStream - Neo4j Binary Serialization Format

    PackStream is a binary serialization format used by Neo4j's Bolt protocol.
    Similar to MessagePack but with Neo4j-specific extensions.

    Reference: https://neo4j.com/docs/bolt/current/packstream/
*)

(** PackStream value types *)
type value =
  | Null
  | Bool of bool
  | Int of int64
  | Float of float
  | String of string
  | Bytes of bytes
  | List of value list
  | Map of (string * value) list
  | Structure of int * value list  (* tag, fields *)

(** Marker bytes - see https://neo4j.com/docs/bolt/current/packstream/ *)
let marker_tiny_string = 0x80  (* 0x80-0x8F: string length 0-15 *)
let marker_tiny_list = 0x90    (* 0x90-0x9F: list length 0-15 *)
let marker_tiny_map = 0xA0     (* 0xA0-0xAF: map length 0-15 *)
let marker_tiny_struct = 0xB0  (* 0xB0-0xBF: struct length 0-15 *)
let marker_null = 0xC0
let marker_float_64 = 0xC1
let marker_false = 0xC2
let marker_true = 0xC3
let marker_int_8 = 0xC8
let marker_int_16 = 0xC9
let marker_int_32 = 0xCA
let marker_int_64 = 0xCB
let marker_bytes_8 = 0xCC
let marker_bytes_16 = 0xCD
let marker_bytes_32 = 0xCE
let marker_string_8 = 0xD0
let marker_string_16 = 0xD1
let marker_string_32 = 0xD2
let marker_list_8 = 0xD4
let marker_list_16 = 0xD5
let marker_list_32 = 0xD6
let marker_map_8 = 0xD8
let marker_map_16 = 0xD9
let marker_map_32 = 0xDA
let marker_struct_8 = 0xDC
let marker_struct_16 = 0xDD

(** Buffer for building packed data *)
type packer = {
  mutable data: bytes;
  mutable pos: int;
}

let create_packer ?(initial_size=256) () =
  { data = Bytes.create initial_size; pos = 0 }

let ensure_capacity p n =
  let required = p.pos + n in
  if required > Bytes.length p.data then begin
    let new_size = max required (Bytes.length p.data * 2) in
    let new_data = Bytes.create new_size in
    Bytes.blit p.data 0 new_data 0 p.pos;
    p.data <- new_data
  end

let write_byte p b =
  ensure_capacity p 1;
  Bytes.set_uint8 p.data p.pos b;
  p.pos <- p.pos + 1

let write_int16_be p n =
  ensure_capacity p 2;
  Bytes.set_int16_be p.data p.pos n;
  p.pos <- p.pos + 2

let write_int32_be p n =
  ensure_capacity p 4;
  Bytes.set_int32_be p.data p.pos n;
  p.pos <- p.pos + 4

let write_int64_be p n =
  ensure_capacity p 8;
  Bytes.set_int64_be p.data p.pos n;
  p.pos <- p.pos + 8

let write_bytes p b =
  let len = Bytes.length b in
  ensure_capacity p len;
  Bytes.blit b 0 p.data p.pos len;
  p.pos <- p.pos + len

let write_string_raw p s =
  let len = String.length s in
  ensure_capacity p len;
  Bytes.blit_string s 0 p.data p.pos len;
  p.pos <- p.pos + len

let get_bytes p =
  Bytes.sub p.data 0 p.pos

(** Pack a value to bytes *)
let rec pack_value p = function
  | Null ->
    write_byte p marker_null

  | Bool false ->
    write_byte p marker_false

  | Bool true ->
    write_byte p marker_true

  | Int n ->
    if n >= -16L && n < 128L then
      (* Tiny int: single byte *)
      write_byte p (Int64.to_int n land 0xFF)
    else if n >= -128L && n < 128L then begin
      write_byte p marker_int_8;
      write_byte p (Int64.to_int n land 0xFF)
    end else if n >= -32768L && n < 32768L then begin
      write_byte p marker_int_16;
      write_int16_be p (Int64.to_int n)
    end else if n >= -2147483648L && n < 2147483648L then begin
      write_byte p marker_int_32;
      write_int32_be p (Int64.to_int32 n)
    end else begin
      write_byte p marker_int_64;
      write_int64_be p n
    end

  | Float f ->
    write_byte p marker_float_64;
    write_int64_be p (Int64.bits_of_float f)

  | String s ->
    let len = String.length s in
    if len < 16 then begin
      write_byte p (marker_tiny_string lor len)
    end else if len < 256 then begin
      write_byte p marker_string_8;
      write_byte p len
    end else if len < 65536 then begin
      write_byte p marker_string_16;
      write_int16_be p len
    end else begin
      write_byte p marker_string_32;
      write_int32_be p (Int32.of_int len)
    end;
    write_string_raw p s

  | Bytes b ->
    let len = Bytes.length b in
    if len < 256 then begin
      write_byte p marker_bytes_8;
      write_byte p len
    end else if len < 65536 then begin
      write_byte p marker_bytes_16;
      write_int16_be p len
    end else begin
      write_byte p marker_bytes_32;
      write_int32_be p (Int32.of_int len)
    end;
    write_bytes p b

  | List items ->
    let len = List.length items in
    if len < 16 then
      write_byte p (marker_tiny_list lor len)
    else if len < 256 then begin
      write_byte p marker_list_8;
      write_byte p len
    end else if len < 65536 then begin
      write_byte p marker_list_16;
      write_int16_be p len
    end else begin
      write_byte p marker_list_32;
      write_int32_be p (Int32.of_int len)
    end;
    List.iter (pack_value p) items

  | Map entries ->
    let len = List.length entries in
    if len < 16 then
      write_byte p (marker_tiny_map lor len)
    else if len < 256 then begin
      write_byte p marker_map_8;
      write_byte p len
    end else if len < 65536 then begin
      write_byte p marker_map_16;
      write_int16_be p len
    end else begin
      write_byte p marker_map_32;
      write_int32_be p (Int32.of_int len)
    end;
    List.iter (fun (k, v) ->
      pack_value p (String k);
      pack_value p v
    ) entries

  | Structure (tag, fields) ->
    let len = List.length fields in
    if len < 16 then begin
      write_byte p (marker_tiny_struct lor len);
      write_byte p tag
    end else if len < 256 then begin
      write_byte p marker_struct_8;
      write_byte p len;
      write_byte p tag
    end else begin
      write_byte p marker_struct_16;
      write_int16_be p len;
      write_byte p tag
    end;
    List.iter (pack_value p) fields

(** Pack a value to bytes (convenience function) *)
let pack value =
  let p = create_packer () in
  pack_value p value;
  get_bytes p

(** Unpacker state *)
type unpacker = {
  data: bytes;
  mutable rpos: int;
  len: int;
}

let create_unpacker data =
  { data; rpos = 0; len = Bytes.length data }

let remaining u = u.len - u.rpos

let read_byte u =
  if remaining u < 1 then failwith "Unexpected end of data";
  let b = Bytes.get_uint8 u.data u.rpos in
  u.rpos <- u.rpos + 1;
  b

let read_int16_be u =
  if remaining u < 2 then failwith "Unexpected end of data";
  let n = Bytes.get_int16_be u.data u.rpos in
  u.rpos <- u.rpos + 2;
  n

let read_int32_be u =
  if remaining u < 4 then failwith "Unexpected end of data";
  let n = Bytes.get_int32_be u.data u.rpos in
  u.rpos <- u.rpos + 4;
  n

let read_int64_be u =
  if remaining u < 8 then failwith "Unexpected end of data";
  let n = Bytes.get_int64_be u.data u.rpos in
  u.rpos <- u.rpos + 8;
  n

let read_bytes u len =
  if remaining u < len then failwith "Unexpected end of data";
  let b = Bytes.sub u.data u.rpos len in
  u.rpos <- u.rpos + len;
  b

let read_string_raw u len =
  if remaining u < len then failwith "Unexpected end of data";
  let s = Bytes.sub_string u.data u.rpos len in
  u.rpos <- u.rpos + len;
  s

(** Unpack a value from bytes *)
let rec unpack_value u =
  let marker = read_byte u in

  (* Tiny types (high nibble) *)
  let high = marker land 0xF0 in
  let low = marker land 0x0F in

  match marker with
  (* Null *)
  | m when m = marker_null -> Null

  (* Booleans *)
  | m when m = marker_false -> Bool false
  | m when m = marker_true -> Bool true

  (* Float 64 *)
  | m when m = marker_float_64 ->
    let bits = read_int64_be u in
    Float (Int64.float_of_bits bits)

  (* Integers *)
  | m when m = marker_int_8 ->
    let n = read_byte u in
    Int (Int64.of_int (if n >= 128 then n - 256 else n))
  | m when m = marker_int_16 ->
    let n = read_int16_be u in
    Int (Int64.of_int n)
  | m when m = marker_int_32 ->
    let n = read_int32_be u in
    Int (Int64.of_int32 n)
  | m when m = marker_int_64 ->
    Int (read_int64_be u)

  (* Bytes *)
  | m when m = marker_bytes_8 ->
    let len = read_byte u in
    Bytes (read_bytes u len)
  | m when m = marker_bytes_16 ->
    let len = read_int16_be u in
    Bytes (read_bytes u len)
  | m when m = marker_bytes_32 ->
    let len = Int32.to_int (read_int32_be u) in
    Bytes (read_bytes u len)

  (* Strings *)
  | m when m = marker_string_8 ->
    let len = read_byte u in
    String (read_string_raw u len)
  | m when m = marker_string_16 ->
    let len = read_int16_be u in
    String (read_string_raw u len)
  | m when m = marker_string_32 ->
    let len = Int32.to_int (read_int32_be u) in
    String (read_string_raw u len)

  (* Lists *)
  | m when m = marker_list_8 ->
    let len = read_byte u in
    List (unpack_list u len)
  | m when m = marker_list_16 ->
    let len = read_int16_be u in
    List (unpack_list u len)
  | m when m = marker_list_32 ->
    let len = Int32.to_int (read_int32_be u) in
    List (unpack_list u len)

  (* Maps *)
  | m when m = marker_map_8 ->
    let len = read_byte u in
    Map (unpack_map u len)
  | m when m = marker_map_16 ->
    let len = read_int16_be u in
    Map (unpack_map u len)
  | m when m = marker_map_32 ->
    let len = Int32.to_int (read_int32_be u) in
    Map (unpack_map u len)

  (* Structures *)
  | m when m = marker_struct_8 ->
    let len = read_byte u in
    let tag = read_byte u in
    Structure (tag, unpack_list u len)
  | m when m = marker_struct_16 ->
    let len = read_int16_be u in
    let tag = read_byte u in
    Structure (tag, unpack_list u len)

  (* Tiny types based on high nibble *)
  | _ when high = marker_tiny_string ->
    String (read_string_raw u low)
  | _ when high = marker_tiny_list ->
    List (unpack_list u low)
  | _ when high = marker_tiny_map ->
    Map (unpack_map u low)
  | _ when high = marker_tiny_struct ->
    let tag = read_byte u in
    Structure (tag, unpack_list u low)

  (* Tiny int (positive: 0x00-0x7F, negative: 0xF0-0xFF) *)
  | m when m <= 0x7F ->
    Int (Int64.of_int m)
  | m when m >= 0xF0 ->
    Int (Int64.of_int (m - 256))

  | _ ->
    failwith (Printf.sprintf "Unknown PackStream marker: 0x%02X" marker)

and unpack_list u len =
  List.init len (fun _ -> unpack_value u)

and unpack_map u len =
  List.init len (fun _ ->
    match unpack_value u with
    | String k -> (k, unpack_value u)
    | _ -> failwith "Map key must be a string"
  )

(** Unpack bytes to value *)
let unpack data =
  let u = create_unpacker data in
  unpack_value u

(** Pretty print value *)
let rec pp_value = function
  | Null -> "null"
  | Bool b -> string_of_bool b
  | Int n -> Int64.to_string n
  | Float f -> string_of_float f
  | String s -> Printf.sprintf "%S" s
  | Bytes b -> Printf.sprintf "<bytes:%d>" (Bytes.length b)
  | List items ->
    "[" ^ String.concat ", " (List.map pp_value items) ^ "]"
  | Map entries ->
    "{" ^ String.concat ", " (List.map (fun (k, v) ->
      Printf.sprintf "%S: %s" k (pp_value v)
    ) entries) ^ "}"
  | Structure (tag, fields) ->
    Printf.sprintf "Struct(%d, [%s])" tag
      (String.concat ", " (List.map pp_value fields))
