(*
 * Copyright (C) 2006-2009 Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)
(** HTTP handler for importing a raw VDI.
 * @group Import and Export
 *)

module D=Debug.Make(struct let name="import" end)
open D

open Http
open Importexport
open Sparse_encoding
open Unixext
open Pervasiveext
open Client

let vhd_tool = "/opt/xensource/libexec/vhd-tool"

let receive protocol (s: Unix.file_descr) (path: string) =
  let s' = Uuidm.to_string (Uuidm.create `V4) in
  let args = [ "serve";
               "--direct";
               "--source-protocol"; protocol;
               "--source-fd"; s';
               "--destination"; "file://" ^ path;
               "--destination-format"; "raw" ] in
  info "Executing %s %s" vhd_tool (String.concat " " args);
  let open Forkhelpers in
  match with_logfile_fd "vhd-tool"
    (fun log_fd ->
      let pid = safe_close_and_exec None (Some log_fd) (Some log_fd) [ s', s ] vhd_tool args in
      let (_, status) = waitpid pid in
      if status <> Unix.WEXITED 0 then begin
        error "vhd-tool failed, returning VDI_IO_ERROR";
        raise (Api_errors.Server_error (Api_errors.vdi_io_error, ["Device I/O errors"])) 
      end
    ) with
  | Success(out, _) -> debug "%s" out
  | Failure(out, e) -> error "vhd-tool output: %s" out; raise e


let localhost_handler rpc session_id vdi (req: Request.t) (s: Unix.file_descr) =
  req.Request.close <- true;
  Xapi_http.with_context "Importing raw VDI" req s
    (fun __context ->
	let all = req.Request.query @ req.Request.cookie in
      let chunked = List.mem_assoc "chunked" all in
      let task_id = Context.get_task_id __context in
	 debug "import_raw_vdi task_id = %s vdi = %s; chunked = %b" (Ref.string_of task_id) (Ref.string_of vdi) chunked;
	 try
	match req.Request.transfer_encoding with
	| Some x ->
	    error "Chunked encoding not yet implemented in the import code";
	    Http_svr.headers s (http_403_forbidden ());
	    raise (Failure (Printf.sprintf "import code cannot handle encoding: %s" x))
	| None ->
		Server_helpers.exec_with_new_task "VDI.import" 
		(fun __context -> 
		 Sm_fs_ops.with_block_attached_device __context rpc session_id vdi `RW
		   (fun path ->
			   let headers = Http.http_200_ok ~keep_alive:false () @
				   [ Http.Hdr.task_id ^ ":" ^ (Ref.string_of task_id);
				   content_type ] in
               Http_svr.headers s headers;
			     if chunked
			     then receive "chunked" s path
			     else receive "none" s path
		   )
	    );
	    TaskHelper.complete ~__context None;
      with e ->
	error "Caught exception: %s" (ExnHelper.string_of_exn e);
	log_backtrace ();
	TaskHelper.failed ~__context (Api_errors.internal_error, ["Caught exception: " ^ (ExnHelper.string_of_exn e)]);
	raise e)

let import vdi (req: Request.t) (s: Unix.file_descr) _ =
	Xapi_http.assert_credentials_ok "VDI.import" ~http_action:"put_import_raw_vdi" req;

	(* Perform the SR reachability check using a fresh context/task because
	   we don't want to complete the task in the forwarding case *)
	Server_helpers.exec_with_new_task "VDI.import" 
	(fun __context -> 
		Helpers.call_api_functions ~__context 
		(fun rpc session_id ->
			let sr = Db.VDI.get_SR ~__context ~self:vdi in
			debug "Checking whether localhost can see SR: %s" (Ref.string_of sr);
			if (Importexport.check_sr_availability ~__context sr)
			then localhost_handler rpc session_id vdi req s
			else 
				let host = Importexport.find_host_for_sr ~__context sr in
				let address = Db.Host.get_address ~__context ~self:host in
				return_302_redirect req s address
		)
       )


let handler (req: Request.t) (s: Unix.file_descr) _ =
	Xapi_http.assert_credentials_ok "VDI.import" ~http_action:"put_import_raw_vdi" req;

	(* Using a fresh context/task because we don't want to complete the
	   task in the forwarding case *)
	Server_helpers.exec_with_new_task "VDI.import" 
	(fun __context ->
		import (vdi_of_req ~__context req) req s ()
	)
