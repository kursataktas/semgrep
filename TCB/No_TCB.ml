(* just to speedup compilation *)

module UStdlib = Pervasives [@@alert "-all"]
module USys = Sys
module UUnix = Unix
module UPrintf = Printf
module UFormat = Format
module UMarshal = Marshal
module UParsing = Parsing
