(**
 * Copyright (c) 2013-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

module FilenameSet = Utils_js.FilenameSet

type workload = ServerEnv.env -> ServerEnv.env Lwt.t
type env_update = ServerEnv.env -> ServerEnv.env

(* Workloads are client requests which we processes FIFO *)
let workload_stream, push_new_workload = Lwt_stream.create ()
let push_new_workload workload = push_new_workload (Some workload)
(* Env updates are...well...updates to our env. They must be handled in the main thread. Also FIFO
 * but are quick to handle *)
let env_update_stream, push_new_env_update = Lwt_stream.create ()
let push_new_env_update env_update = push_new_env_update (Some env_update)
(* Outstanding cancellation requests are lodged here as soon as they arrive
 * from the monitor (NOT FIFO) as well as being lodged in the normal FIFO
 * queue. (1) if there was a workload sent prior to the cancellation request
 * but we're only just FIFO getting to it now, it can peek to see whether
 * that a cancellation request came after it, and not bother starting.
 * (2) by the time the FIFO queue gets around to seeing the cancellation
 * request in the normal FIFO queue, then we know it can no longer cancel
 * any future requests, so we'll remove it from the set.
 * Observe that our cancellation handling is best-effort only... we won't
 * cancel something already underway, and we might start something even while
 * the cancellation request is queued up somewhere between monitor and server. *)
let cancellation_requests = ref Lsp.IdSet.empty

type recheck_msg = {
  callback: (Profiling_js.finished option -> unit) option;
  file_watcher_metadata: MonitorProt.file_watcher_metadata option;
  files: recheck_files;
}
and recheck_files =
| ChangedFiles of SSet.t
| FilesToForceFocused of SSet.t
| CheckedSetToForce of CheckedSet.t
(* Files which have changed *)
let recheck_stream, push_recheck_msg = Lwt_stream.create ()
let push_recheck_msg ?metadata ?callback files =
  push_recheck_msg (Some { files; callback; file_watcher_metadata = metadata; })
let push_files_to_recheck ?metadata ?callback changed_files =
  push_recheck_msg ?metadata ?callback (ChangedFiles changed_files)
let push_files_to_force_focused ?callback forced_focused_files =
  push_recheck_msg ?callback (FilesToForceFocused forced_focused_files)
let push_checked_set_to_force ?callback checked_set =
  push_recheck_msg ?callback (CheckedSetToForce checked_set)

let pop_next_workload () =
  match Lwt_stream.get_available_up_to 1 workload_stream with
  | [ workload ] -> Some workload
  | [] -> None
  | _ -> failwith "Unreachable"

let update_env env =
  Lwt_stream.get_available env_update_stream
  |> List.fold_left (fun env f -> f env) env

type recheck_workload = {
  files_to_recheck: FilenameSet.t;
  files_to_force: CheckedSet.t;
  profiling_callbacks: (Profiling_js.finished option -> unit) list;
  metadata: MonitorProt.file_watcher_metadata;
}
let empty_recheck_workload = {
  files_to_recheck = FilenameSet.empty;
  files_to_force = CheckedSet.empty;
  profiling_callbacks = [];
  metadata = MonitorProt.empty_file_watcher_metadata;
}

let recheck_workload_is_empty workload =
  let { files_to_recheck; files_to_force; profiling_callbacks=_; metadata=_;} = workload in
  FilenameSet.is_empty files_to_recheck && CheckedSet.is_empty files_to_force
let recheck_acc = ref empty_recheck_workload
let recheck_fetch ~process_updates =
  recheck_acc :=
    Lwt_stream.get_available recheck_stream (* Get all the files which have changed *)
    |> Core_list.fold_left
      ~init:(!recheck_acc)
      ~f:(fun workload { files; callback; file_watcher_metadata; } ->
        let is_empty_msg, workload = match files with
        | ChangedFiles changed_files ->
          let updates = process_updates changed_files in
          FilenameSet.is_empty updates,
            { workload with files_to_recheck = FilenameSet.union updates workload.files_to_recheck }
        | FilesToForceFocused forced_focused_files ->
          let focused = process_updates forced_focused_files in
          FilenameSet.is_empty focused,
            { workload with files_to_force = CheckedSet.add ~focused workload.files_to_force }
        | CheckedSetToForce checked_set ->
          CheckedSet.is_empty checked_set,
            { workload with files_to_force = CheckedSet.union checked_set workload.files_to_force }
        in
        let workload = match callback with
        | None -> workload
        | Some callback ->
          if is_empty_msg
          then begin
            (* Call the callback immediately if there's nothing to recheck *)
            callback None;
            workload
          end else
            { workload with profiling_callbacks = callback :: workload.profiling_callbacks; }
        in
        MonitorProt.(match file_watcher_metadata with
        | None -> workload
        | Some { total_update_distance; changed_mergebase; } ->
          let total_update_distance =
            total_update_distance + workload.metadata.total_update_distance
          in
          let changed_mergebase = changed_mergebase || workload.metadata.changed_mergebase in
          { workload with metadata = { total_update_distance; changed_mergebase; }; }
        )
    )

let get_and_clear_recheck_workload ~process_updates =
  recheck_fetch ~process_updates;
  let recheck_workload = !recheck_acc in
  recheck_acc := empty_recheck_workload;
  recheck_workload

let rec wait_for_updates_for_recheck ~process_updates =
  let%lwt _ = Lwt_stream.is_empty recheck_stream in
  recheck_fetch ~process_updates;
  if recheck_workload_is_empty !recheck_acc
  then wait_for_updates_for_recheck ~process_updates
  else Lwt.return_unit

(* Block until any stream receives something *)
let wait_for_anything ~process_updates =
  let%lwt () = Lwt.pick [
    (let%lwt _ = Lwt_stream.is_empty workload_stream in Lwt.return_unit);
    (let%lwt _ = Lwt_stream.is_empty env_update_stream in Lwt.return_unit);
    (let%lwt _ = Lwt_stream.is_empty recheck_stream in Lwt.return_unit);
    wait_for_updates_for_recheck ~process_updates;
  ] in
  Lwt.return_unit
