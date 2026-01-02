(** PackStream Unit Tests *)

module P = Neo4j_bolt.Packstream

(* Test helpers *)
let packstream_value = Alcotest.testable
  (fun fmt v -> Format.fprintf fmt "%s" (P.pp_value v))
  (=)

let roundtrip name value =
  let test () =
    let packed = P.pack value in
    let unpacked = P.unpack packed in
    Alcotest.(check packstream_value) name value unpacked
  in
  (name, `Quick, test)

(* Null *)
let test_null = roundtrip "null" P.Null

(* Booleans *)
let test_bool_true = roundtrip "bool true" (P.Bool true)
let test_bool_false = roundtrip "bool false" (P.Bool false)

(* Integers *)
let test_int_zero = roundtrip "int 0" (P.Int 0L)
let test_int_positive = roundtrip "int 42" (P.Int 42L)
let test_int_negative = roundtrip "int -17" (P.Int (-17L))
let test_int_tiny_max = roundtrip "int 127" (P.Int 127L)
let test_int_int8 = roundtrip "int 200" (P.Int 200L)
let test_int_int16 = roundtrip "int 30000" (P.Int 30000L)
let test_int_int32 = roundtrip "int 100000" (P.Int 100000L)
let test_int_int64 = roundtrip "int large" (P.Int 9999999999L)
let test_int_neg_large = roundtrip "int -100000" (P.Int (-100000L))

(* Floats *)
let test_float_zero = roundtrip "float 0.0" (P.Float 0.0)
let test_float_pi = roundtrip "float pi" (P.Float 3.14159)
let test_float_neg = roundtrip "float -1.5" (P.Float (-1.5))

(* Strings *)
let test_string_empty = roundtrip "string empty" (P.String "")
let test_string_tiny = roundtrip "string hello" (P.String "hello")
let test_string_unicode = roundtrip "string unicode" (P.String "한글 테스트 🎉")
let test_string_long = roundtrip "string 100 chars" (P.String (String.make 100 'x'))
let test_string_256 = roundtrip "string 256 chars" (P.String (String.make 256 'y'))

(* Bytes *)
let test_bytes_empty = roundtrip "bytes empty" (P.Bytes (Bytes.create 0))
let test_bytes_small = roundtrip "bytes small" (P.Bytes (Bytes.of_string "binary"))

(* Lists *)
let test_list_empty = roundtrip "list empty" (P.List [])
let test_list_ints = roundtrip "list ints" (P.List [P.Int 1L; P.Int 2L; P.Int 3L])
let test_list_mixed = roundtrip "list mixed" (P.List [P.Int 1L; P.String "two"; P.Bool true])
let test_list_nested = roundtrip "list nested" (P.List [P.List [P.Int 1L]; P.List [P.Int 2L]])

(* Maps *)
let test_map_empty = roundtrip "map empty" (P.Map [])
let test_map_simple = roundtrip "map simple" (P.Map [("key", P.String "value")])
let test_map_multi = roundtrip "map multi" (P.Map [
  ("name", P.String "test");
  ("count", P.Int 42L);
  ("active", P.Bool true);
])

(* Structures (Bolt messages) *)
let test_struct_empty = roundtrip "struct empty" (P.Structure (0x01, []))
let test_struct_hello = roundtrip "struct HELLO" (P.Structure (0x01, [
  P.Map [
    ("user_agent", P.String "test/1.0");
    ("scheme", P.String "basic");
  ]
]))

(* Test suites *)
let () =
  Alcotest.run "PackStream" [
    "null", [test_null];
    "bool", [test_bool_true; test_bool_false];
    "int", [
      test_int_zero; test_int_positive; test_int_negative;
      test_int_tiny_max; test_int_int8; test_int_int16;
      test_int_int32; test_int_int64; test_int_neg_large;
    ];
    "float", [test_float_zero; test_float_pi; test_float_neg];
    "string", [
      test_string_empty; test_string_tiny; test_string_unicode;
      test_string_long; test_string_256;
    ];
    "bytes", [test_bytes_empty; test_bytes_small];
    "list", [test_list_empty; test_list_ints; test_list_mixed; test_list_nested];
    "map", [test_map_empty; test_map_simple; test_map_multi];
    "struct", [test_struct_empty; test_struct_hello];
  ]
