open Core.Std
open Phat_pure.Core2
open Async.Std
module Path = Phat_path

let and_check f x e =
  match e with
  | `Yes -> f x
  | `No -> return `No
  | `Unknown -> return `Unknown

let and_check2 f (seen, e) =
  match e with
  | `Yes -> f seen
  | `No -> return (seen, `No)
  | `Unknown -> return (seen, `Unknown)

let negate = function
  | `Yes -> `No
  | `No -> `Yes
  | `Unknown -> `Unknown

(** Async's [file_exists] has a
    {{:https://github.com/janestreet/async_unix/issues/6}bug} that
    doesn't allow setting follow_symlinks to false. *)
let file_exists x =
  In_thread.run (fun () -> Core.Std.Sys.file_exists ~follow_symlinks:false x)

let is_file = Sys.is_file ~follow_symlinks:false
let is_directory = Sys.is_directory ~follow_symlinks:false

let wrap_unix loc f =
  try_with f >>|
  Or_error.of_exn_result >>|
  Or_error.tag_loc loc

let unix_mkdir p =
  wrap_unix _here_ (fun () -> Unix.mkdir (Path.to_string p))

let unix_symlink link_path ~targets:link_target =
  wrap_unix _here_ (fun () ->
      Unix.symlink ~dst:(Path.to_string link_path) ~src:(Path.to_string link_target)
    )

let realpath x =
  wrap_unix _here_ (fun () ->
      In_thread.run (fun () -> Filename.realpath x)
    )


let is_link p =
  file_exists p >>= function
  | `No
  | `Unknown as x ->
    return x
  | `Yes ->
    Unix.lstat p >>| fun {Unix.Stats.kind; _} ->
    match kind with
    | `Link ->
      `Yes
    | `File | `Directory | `Char | `Block | `Fifo | `Socket ->
      `No


(* Represents a position in a path. This is useful when building or
   checking a path, which is a step by step operation: each step is
   performed by a recursive call on a (p_abs, p_rel) pair, with the
   invariant that:
   - the path that we want to build/check is concat p_abs p_rel
   - p_abs has already been built/checked
   - p_abs is resolved

   In general, we'd like to avoid calling the recursive function twice
   with the same arguments (to avoid duplicating work on shared
   subtrees, or to be cycle-tolerant) and so the build/check function
   will generally carry a set of cursors to remember which calls have
   already been made.
 *)
module Path_cursor : sig
  type t
  val make : (_,_) Path.t -> (_,_) Path.t -> t
  val compare : t -> t -> int
  val t_of_sexp : Sexp.t -> t
  val sexp_of_t : t -> Sexp.t
end
= struct
  type t = P : (_,_) Path.t * (_,_) Path.t -> t
  let make p q = P (p, q)
  let compare = compare
  let t_of_sexp _ = assert false
  let sexp_of_t _ = assert false
end

module Cursor_set = struct
  include Set.Make(Path_cursor)
  let add set p q = add set (Path_cursor.make p q)
  let mem set p q = mem set (Path_cursor.make p q)
end

let rec exists_main
  : type typ. Cursor_set.t -> (Path.abs, typ) Path.t -> (Cursor_set.t * [ `Yes | `Unknown | `No ]) Deferred.t
  =
  let open Path in
  fun seen -> function
    | Item Root ->
      file_exists "/" >>| fun r ->
      (seen, r)
    | Cons (Root, p_rel) ->
      file_exists "/" >>= fun r ->
      and_check2 (fun seen -> exists_rel_path seen root p_rel) (seen, r)

and exists_item
    : type typ. Cursor_set.t -> Path.abs_dir -> (Path.rel,typ) Path.item -> (Cursor_set.t * [ `Yes | `Unknown | `No ]) Deferred.t
    =
    fun seen p_abs item ->
      match item with
      | Path.Dot -> return (seen, `Yes)
      | Path.Dotdot -> return (seen, `Yes)
      | Path.File _ ->
        let p_abs' = Path.to_string (Path.cons p_abs item) in
        file_exists p_abs' >>= and_check is_file p_abs' >>| fun file_exists ->
        seen, file_exists
      | Path.Dir _ ->
        let p_abs' = Path.to_string (Path.cons p_abs item) in
        file_exists p_abs' >>= and_check is_directory p_abs' >>| fun dir_exists ->
        seen, dir_exists
      | Path.Broken_link (_, target) ->
        let target_does_not_exist target =
          let target_as_str = Filename.of_parts target in
          file_exists (
            match target with
            | "/" :: _ -> target_as_str
            | _ -> Filename.concat (Path.to_string p_abs) target_as_str
          )
          >>| negate
        in
        let p_abs' = Path.to_string (Path.cons p_abs item) in
        file_exists p_abs'
        >>= and_check is_link p_abs'
        >>= and_check target_does_not_exist target >>| fun broken_link_exists ->
        seen, broken_link_exists
      | Path.Link (_, target) ->
        let target_exists seen =
          match Path.kind_of target with
          | `Abs p -> exists_main seen p
          | `Rel p -> exists_rel_path seen p_abs p
        in
        let p_abs' = Path.to_string (Path.cons p_abs item) in
        file_exists p_abs' >>= and_check is_link p_abs' >>= fun link_exists ->
        (seen, link_exists) |> and_check2 target_exists

and exists_rel_path
    : type typ. Cursor_set.t -> Path.abs_dir -> (Path.rel,typ) Path.t -> (Cursor_set.t * [ `Yes | `Unknown | `No ]) Deferred.t
    =
    fun seen p_abs p_rel ->
      if Cursor_set.mem seen p_abs p_rel then return (seen, `Yes)
      else (
        let seen' = Cursor_set.add seen p_abs p_rel in
        match p_rel with
        | Path.Item x -> exists_item seen' p_abs x
        | Path.Cons (x, y) ->
          exists_item seen' p_abs x
          >>= and_check2 (fun seen -> exists_rel_path seen (Path.cons p_abs x) y)
      )

and exists p =
  exists_main Cursor_set.empty p >>| snd


let lstat p : Unix.Stats.t Or_error.t Deferred.t =
  try_with (fun () -> Unix.lstat (Path.to_string p)) >>|
  Or_error.of_exn_result >>|
  Or_error.tag_loc _here_

let rec mkdir_main
  : Cursor_set.t -> Path.abs_dir -> Cursor_set.t Or_error.t Deferred.t
  = fun seen p ->
    match p with
    | Path.Item Path.Root -> return (Ok seen)
    | Path.Cons (Path.Root, rel_p) ->
      mkdir_aux seen Path.root rel_p

and mkdir_aux
  : Cursor_set.t -> Path.abs_dir -> Path.rel_dir -> Cursor_set.t Or_error.t Deferred.t
  = fun seen p_abs p_rel ->
    if Cursor_set.mem seen p_abs p_rel then return (Ok seen)
    else
      let seen' = Cursor_set.add seen p_abs p_rel in
      match p_rel with
      | Path.Item (Path.Dir _) -> (
          let p = Path.concat p_abs p_rel in
          exists p >>= (fun x -> match x with
            | `Yes -> return (Ok ())
            | `No | `Unknown -> unix_mkdir p
          ) >>|? fun () ->
          seen'
        )
      | Path.Item Path.Dot -> return (Ok seen')
      | Path.Item Path.Dotdot -> return (Ok seen')
      | Path.Item (Path.Link (_, dir)) -> (
          let p = Path.concat p_abs p_rel in
          unix_symlink p ~targets:dir >>=? fun () ->
          match Path.kind_of dir with
          | `Rel dir -> mkdir_aux seen' p_abs dir
          | `Abs dir -> mkdir_main seen' dir
        )
      | Path.Cons (Path.Dir n, p_rel') -> (
          let p_abs' = Path.cons p_abs (Path.Item.dir n) in
          exists p_abs' >>= (fun x -> match x with
            | `Yes -> return (Ok ())
            | `No | `Unknown -> unix_mkdir p_abs'
          ) >>=? fun () ->
          mkdir_aux seen' p_abs' p_rel'
        )
      | Path.Cons (Path.Link (_, dir) as l, p_rel') -> (
          unix_symlink (Path.cons p_abs l) ~targets:dir >>=? fun () ->
          match Path.kind_of dir with
          | `Rel dir ->
            mkdir_aux seen' p_abs (Path.concat dir p_rel')
          | `Abs dir ->
            mkdir_main seen' (Path.concat dir p_rel')
        )
      | Path.Cons (Path.Dot, p_rel') -> mkdir_aux seen' p_abs p_rel'
      | Path.Cons (Path.Dotdot, p_rel') ->
        mkdir_aux seen' (Path.parent p_abs) p_rel'

and mkdir p =
  mkdir_main Cursor_set.empty p >>| fun _ ->
  Ok ()

let rec find_item item path =
  match path with
  | [] -> return None
  | dir::path ->
     let x = Path.cons dir item in
     exists x >>= function
     | `Yes -> return (Some x)
     | `Unknown | `No -> find_item item path


let rec fold_aux p_abs p_rel obj ~f ~init =
  let dir = Path.(concat p_abs p_rel |> normalize) in
  match obj with
  | `File file -> f init p_abs (`File (Path.cons p_rel file))
  | `Broken_link bl ->  f init p_abs (`Broken_link (Path.cons p_rel bl))
  | `Dir subdir_item ->
    let subdir_rel = Path.cons p_rel subdir_item in
    let subdir = Path.cons dir subdir_item in
    let subdir_as_str = Path.to_string subdir in
    f init p_abs (`Dir subdir_rel) >>= fun accu -> (* prefix traversal *)
    Sys.readdir subdir_as_str >>= fun dir_contents ->
    Deferred.Array.fold dir_contents ~init:accu ~f:(fun accu obj ->
        let obj_as_str = Filename.concat subdir_as_str obj in
        let n = Path.name_exn obj in
        Unix.(lstat obj_as_str) >>= fun stats ->
        (
          match stats.Unix.Stats.kind with
          | `File | `Block | `Char | `Fifo | `Socket ->
            return (`File (Path.Item.file n))

          | `Directory ->
            return (`Dir (Path.Item.dir n))

          | `Link ->
            reify_link subdir_as_str n
        )
        >>= fun item ->
        fold_aux p_abs (Path.cons p_rel subdir_item) item ~f ~init:accu
      )

and reify_link dir_as_str n =
  let link_as_str = Filename.concat dir_as_str (n : Path.name :> string) in
  Unix.readlink link_as_str >>= fun target ->
  try_with Unix.(fun () -> stat link_as_str) >>| function
  | Ok stats -> (
      let make_link f cons =
        match f target with (* parse target of the link *)
        | Ok target ->
          Path.map_any_kind target { Path.map = fun x ->
              match Path.Item.link n x with
              | `Ok x -> cons x
              | `Broken _ -> assert false
            }
        | Error _ ->
          (* should not happen since the target exists
                       according to the file system *)
          assert false
      in
      match stats.Unix.Stats.kind with
      | `File | `Block | `Char | `Fifo | `Socket ->
        make_link Path.file_of_any_kind (fun x -> `File x)

      | `Directory ->
        make_link Path.dir_of_any_kind (fun x -> `Dir x)

      | `Link ->
        (* should not happen: Unix.stat resolves to a
                     link-free path *)
        assert false
    )
  | Error _ ->
    let bl = Path.Item.broken_link n (String.split ~on:'/' target) in
    `Broken_link bl

let fold start ~f ~init =
  exists start >>= function
  | `Yes ->
    fold_aux start Path.(Item (Item.dot)) (`Dir Path.Item.dot) ~f ~init >>| fun r ->
    Ok r

  | `No | `Unknown ->
    errorh _here_ "Directory does not exist" () sexp_of_unit
    |> return

(* file system object *)
module Wrapped_path = struct
  type t = P : (_, _) Path.t -> t
  let compare = compare
  let t_of_sexp _ = assert false
  let sexp_of_t _ = assert false
end

(* wrapped path set *)
module WPS = struct
  open Wrapped_path
  include Set.Make(Wrapped_path)
  let add set p = add set (P p)
  let add_obj set = function
      `File file -> add set file
    | `Dir dir -> add set dir
    | `Broken_link bl -> add set bl
  let mem set p = mem set (P p)
  let mem_obj set = function
      `File file -> mem set file
    | `Dir dir -> mem set dir
    | `Broken_link bl -> mem set bl
end

module Fold_wrap = struct
  type ('a, 'b) path = ('a, 'b) Path.t
  open Path

  type t =
    | `File of (abs, file) path
    | `Dir of (abs, dir) path
    | `Link
end

(*
   PRECONDITIONS:
   - [obj] refers to an existing object
   - [obj] contains only normalized paths
 *)
let rec fold_follows_links visited resolved_visited obj ~f ~(init:'a) : ('a * WPS.t * WPS.t) Deferred.Or_error.t =
  if WPS.mem_obj visited obj then Deferred.Or_error.return (init, visited, resolved_visited) else (
    match obj with
    | `File file ->
      let file_str = Path.to_string file in
      realpath file_str >>=? fun resolved_file_str ->
      return (Path.abs_file resolved_file_str) >>=? fun resolved_file ->
      let already_visited = WPS.mem resolved_visited resolved_file in
      f init (`File (file, resolved_file, already_visited)) >>= fun result ->
      let visited' = WPS.add_obj visited obj in
      let resolved_visited' = WPS.add resolved_visited resolved_file in
      Deferred.Or_error.return (result, visited', resolved_visited')

    | `Dir dir ->
      let dir_str = Path.to_string dir in
      realpath dir_str >>=? fun resolved_dir_str ->
      return (Path.abs_dir resolved_dir_str) >>=? fun resolved_dir ->
      let already_visited = WPS.mem resolved_visited resolved_dir in
      f init (`Dir (dir, resolved_dir, already_visited)) >>= fun result ->
      let visited' = WPS.add_obj visited obj in
      let resolved_visited' = WPS.add resolved_visited resolved_dir in

      Sys.readdir dir_str >>| Array.to_list >>= fun dir_contents ->
      let init = result, visited', resolved_visited' in
      Deferred.Or_error.List.fold dir_contents ~init ~f:(fun (accu, visited, resolved_visited) obj ->
          let obj_as_str = Filename.concat dir_str obj in
          let n = Path.name_exn obj in
          Unix.(lstat obj_as_str) >>= fun stats ->
          match stats.Unix.Stats.kind with
          | `File | `Block | `Char | `Fifo | `Socket ->
            let next_obj = `File (Path.(cons dir (Item.file n))) in
            fold_follows_links visited resolved_visited next_obj ~f ~init:accu

          | `Directory ->
            let next_obj = `Dir (Path.(cons dir (Item.dir n))) in
            fold_follows_links visited resolved_visited next_obj ~f ~init:accu

          | `Link ->
            reify_link dir_str (Path.name_exn obj) >>= function
            | `File link_item ->
              let link = Path.cons dir link_item in
              
        )

    | `Broken_link bl ->
(*
      let bl_str = Path.to_string bl in
      let bl_parent_str = Filename.dirname bl_str in
      let bl_name = Filename.basename bl_str in
      realpath bl_parent_str >>=? fun resolved_bl_parent_str ->
      let resolved_bl_str = Filename.concat resolved_bl_parent_str bl_name in

   (* ARG: should parse a broken_link *)
      return (Path.abs_file resolved_bl_str) >>=? fun resolved_file ->
      let already_visited = WPS.mem resolved_visited resolved_file in
      f init (`File (file, resolved_file, already_visited)) >>= fun result ->
      let visited' = WPS.add_obj visited obj in
      let resolved_visited' = WPS.add resolved_visited in
      return (result, visited', resolved_visited')
*)
      assert false
  )



let fold_follows_links start ~f ~init =
  exists start >>= function
  | `Yes ->
    fold_follows_links WPS.empty WPS.empty (`Dir start)  ~f ~init >>| fun r ->
    Ok r

  | `No | `Unknown ->
    errorh _here_ "Directory does not exist" () sexp_of_unit
    |> return
