(**
 * Copyright (c) 2013-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "flow" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
 *)

 module SpanMap = Span.SpanMap


(* Supports O(m) operations to add a range of suppression rules, where m is
 * the number of rules. (assuming that the rules are processed in order) *)
(* A builder is a sorted list of non-overlapping, non-empty, adjacent ranges, with later
 * ranges appearing at the head of the list and earlier ranges appearing at the
 * tail of the list. *)
(* These functions were built with the case of all ranges belonging to the same file
 * in mind. It may or may not work in other cases. *)
type builder = (Loc.t * LintSettings.t) list

let new_builder =
  let open Loc in
  let full_range source =
    let start = {line = 0; column = 0; offset = 0} in
    let _end = {line = max_int / 2; column = max_int / 2; offset = max_int / 2} in
    {source; start; _end}
  in fun source settings -> [full_range (Some source), settings]

(* Gets all ranges that intersect with the provided range. *)
let get_intersecting =
  let rec get_intersecting' query acc = function
    | [] -> acc (* We've exhausted the list. *)
    | candidate::tail ->
      let cand_range = fst candidate in
      (* We still haven't reached the first intersecting range. *)
      if Loc.(pos_cmp query._end cand_range.start) <= 0 then
        get_intersecting' query acc tail
      (* The current range is intersecting. *)
      else if Loc.(pos_cmp cand_range._end query.start) > 0 then
        get_intersecting' query (candidate::acc) tail
      (* We've passed the last intersecting range. *)
      else acc
  in fun range builder ->
    get_intersecting' range [] builder

let add =
  let rec add' entry visited = function
    | head::tail as builder ->
      (* We found the place the entry is supposed to go *)
      if Loc.compare (fst entry) (fst head) > 0 then
        List.rev_append visited (entry::builder)
      (* We need to keep going *)
      else add' entry (head::visited) tail
    | [] -> List.rev_append visited [entry]
  in
  fun entry builder ->
    add' entry [] builder

let remove =
  let rec remove' entry visited = function
    | head::tail ->
      (* '==' is acceptable because this is only called on ranges that have been
       * taken out of the builder itself. *)
      if head == entry then List.rev_append visited tail
      else remove' entry (head::visited) tail
    | [] -> Utils_js.assert_false
      "Remove is only called on entries that exist in the builder."
  in fun entry builder -> remove' entry [] builder

let get_overlap ~old_loc ~new_loc =
  let open Loc in
  let source = new_loc.source in
  let start, remaining =
    if pos_cmp old_loc.start new_loc.start < 0 then
      new_loc.start, [{source; start = old_loc.start; _end = new_loc.start}]
    else old_loc.start, []
  in let _end, remaining =
    if pos_cmp old_loc._end new_loc._end > 0 then
      new_loc._end, {source; start = new_loc._end; _end = old_loc._end}::remaining
    else old_loc._end, remaining
  in {source; start; _end}, remaining

let update_builder ((old_loc, old_set) as original) new_loc kind_settings builder =
  let overlap, remaining_orig = get_overlap ~old_loc ~new_loc in
  let new_overlap =
    let kind_settings =
      List.map (fun (kind, (enabled, loc)) -> (kind, (enabled, Some loc))) kind_settings in
    (overlap, LintSettings.set_all kind_settings old_set) in
  let new_remaining = List.map (fun loc -> (loc, old_set)) remaining_orig in
  let builder = builder |> remove original |> add new_overlap in
  List.fold_left (fun builder entry -> add entry builder) builder new_remaining

let update_settings range kind_settings builder =
  let original_intersecting = get_intersecting range builder in
  List.fold_left
    (fun builder original -> update_builder original range kind_settings builder)
    builder original_intersecting

let bake =
  List.fold_left (fun map (loc, settings) -> SpanMap.add loc settings map) SpanMap.empty


(* Supports O(log(n)) queries to get the relevant suppression for a loc. *)
type t = LintSettings.t SpanMap.t

let global_settings source settings = new_builder source settings |> bake
(* This isn't a particularly valid suppression map, but it's fine as long as
 * no-one tries to use it. (And even then it shouldn't break; it'll just make
 * no sense.) *)
let invalid_default = global_settings (Loc.SourceFile "") LintSettings.default_settings
(* Gets the lint settings that apply to a certain location in the code. To
 * resolve ambiguity, this looks at the location of the first character in the
 * provided location. *)
(* Because of the invariant that the ranges in a SuppressionMap are adjacent and
 * exhaustive, this should never throw. *)
let settings_at_loc loc suppression_map =
  SpanMap.find_unsafe (Loc.first_char loc) suppression_map

let is_suppressed lint_kind loc suppression_map =
  settings_at_loc loc suppression_map |> LintSettings.is_suppressed lint_kind

let union a b = SpanMap.union a b

let union_settings settings =
  Utils_js.FilenameMap.fold
    (fun _key -> union)
    settings
    SpanMap.empty
