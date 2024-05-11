open Common
open Fpath_.Operators

(*****************************************************************************)
(* Subsystem testing *)
(*****************************************************************************)

let test_parse_c xs =
  Parse_cpp.init_defs !Flag_parsing_cpp.macros_h;

  let xs = Fpath_.of_strings xs in
  let fullxs = Lib_parsing_c.find_source_files_of_dir_or_files xs in
  let stat_list = ref [] in

  fullxs
  |> (*Console.progress (fun k -> *)
  List.iter (fun file ->
      (*k(); *)
      UCommon.pr (spf "PARSING: %s" !!file);
      let { Parsing_result.stat; _ } = Parse_c.parse file in
      Stack_.push stat stat_list);
  UCommon.pr (Parsing_stat.recurring_problematic_tokens !stat_list);
  UCommon.pr (Parsing_stat.string_of_stats !stat_list);
  ()

let test_dump_c file =
  let file = Fpath.v file in
  Parse_cpp.init_defs !Flag_parsing_cpp.macros_h;
  let ast = Parse_c.parse_program file in
  let s = Ast_c.show_program ast in
  UCommon.pr s

(*****************************************************************************)
(* Main entry for Arg *)
(*****************************************************************************)

let actions () =
  [
    ("-parse_c", "   <file or dir>", Arg_.mk_action_n_arg test_parse_c);
    ("-dump_c", "   <file>", Arg_.mk_action_1_arg test_dump_c);
  ]
