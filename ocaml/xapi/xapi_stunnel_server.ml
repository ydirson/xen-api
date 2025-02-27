(*
 * Copyright (C) Citrix Systems Inc.
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

module Unixext = Xapi_stdext_unix.Unixext

module D = Debug.Make (struct let name = "xapi_stunnel_server" end)

open D

let cert = !Xapi_globs.server_cert_path

let pool_cert = !Xapi_globs.server_cert_internal_path

(** protect ourselves from concurrent writes to files *)
module Config : sig
  val update : accept:string -> client_auth_name:string option -> bool
  (** Create or update stunnel config file.
      Returns a Boolean indicating whether a change was made. *)
end = struct
  let m = Mutex.create ()

  let current_accept = ref None

  let current_client_auth_name = ref None

  let update_xapi_ssl_config_file ~accept ~client_auth_name =
    let fips =
      Xapi_inventory.lookup ~default:"false" "CC_PREPARATIONS" |> function
      | "true" ->
          "yes"
      | "false" ->
          "no"
      | unknown ->
          info
            "CC_PREPARATIONS has unexpected value '%s'. assuming fips mode \
             should be disabled"
            unknown ;
          "no"
    in
    let conf_contents =
      let open Printf in
      let cipher_options =
        [
          sprintf "ciphers = %s" Xcp_const.good_ciphersuites
        ; "curve = secp384r1"
        ; "options = CIPHER_SERVER_PREFERENCE"
        ; "sslVersion = TLSv1.2"
        ]
      in
      [
        [
          "; autogenerated by xapi"
        ; sprintf "fips = %s" fips
        ; "pid = /var/run/xapissl.pid"
        ; "socket = r:TCP_NODELAY=1"
        ; "socket = a:TCP_NODELAY=1"
        ; "socket = l:TCP_NODELAY=1"
        ; "socket = r:SO_KEEPALIVE=1"
        ; "socket = a:SO_KEEPALIVE=1"
        ; "TIMEOUTclose = 1"
        ; ( match Sys.getenv_opt "STUNNEL_IDLE_TIMEOUT" with
          | None ->
              "; no idle timeout"
          | Some x ->
              sprintf "TIMEOUTidle = %s" x
          )
        ; Stunnel.debug_conf_of_env ()
        ; "protocol = proxy" (* tells stunnel to include inet address info *)
        ; ""
        ; "[xapi]"
        ; sprintf "accept = %s%d" accept !Constants.https_port
        ; sprintf "cert = %s" cert
        ]
      ; ( match client_auth_name with
        | None ->
            (* No client certificate auth: forward to xapi on port 80
               for authentication by username+password or session/token. *)
            ["connect = 80"]
        | Some name ->
            (* Verify the client certificate wrt the stored CA certs and name.
               Connect to xapi's dedicated unix socket if the cert is accepted,
               and no further auth is needed. Otherwise, redirect to port 80
               as above. *)
            [
              Printf.sprintf "connect = %s"
                Xapi_globs.unix_domain_socket_clientcert
            ; "redirect = 80"
            ; "verifyChain = yes"
            ; Printf.sprintf "CAfile = %s" !Xapi_globs.stunnel_bundle_path
            ; Printf.sprintf "checkHost = %s" name
            ]
        )
      ; cipher_options
      ; [
          ""
        ; "# xapi connections use SNI 'pool' to request a cert"
        ; "[pool]"
        ; "sni = xapi:pool"
        ; "connect = 80"
        ; sprintf "cert = %s" pool_cert
        ]
      ; cipher_options
      ]
      |> List.concat
      |> String.concat "\n"
    in
    let len = String.length conf_contents in
    Unixext.atomic_write_to_file !Xapi_globs.stunnel_conf 0o0600 (fun fd ->
        let (_ : int) = Unix.single_write_substring fd conf_contents 0 len in
        ()
    )

  let update ~accept ~client_auth_name =
    Xapi_stdext_threads.Threadext.Mutex.execute m (fun () ->
        match (!current_accept, !current_client_auth_name) with
        | Some current_accept, Some current_client_auth_name
          when current_accept = accept
               && current_client_auth_name = client_auth_name ->
            false
        | _ ->
            (* Update the stunnel config file, which will be picked
               up when restarting the service *)
            current_accept := Some accept ;
            current_client_auth_name := Some client_auth_name ;
            update_xapi_ssl_config_file ~accept ~client_auth_name ;
            true
    )
end

let systemctl cmd =
  Helpers.call_script !Xapi_globs.systemctl [cmd; "stunnel@xapi"]

let systemctl_ cmd = systemctl cmd |> ignore

let reload ?(wait = 5.0) () =
  systemctl_ "reload-or-restart" ;
  (* We can't be sure that the reload is finished, so wait a moment *)
  Thread.delay wait

let is_enabled () =
  let is_enabled_stdout =
    try systemctl "is-enabled"
    with
    (* systemctl is-enabled appears to return error code 1 when the service is disabled *)
    | Forkhelpers.Spawn_internal_error (stderr, stdout, status) as e -> (
      match status with
      | Unix.WEXITED n
        when n = 1
             && Astring.String.is_prefix ~affix:"disabled" stdout
             && Astring.String.is_empty stderr ->
          "disabled"
      | _ ->
          raise e
    )
  in
  is_enabled_stdout |> Astring.String.trim |> function
  | "enabled" ->
      true
  | "disabled" ->
      false
  | unknown ->
      D.error
        "Stunnel.is_enabled: expected 'enabled' or 'disabled', but got: %s"
        unknown ;
      false

let update_certificates ~__context () =
  info "syncing certificates on xapi start" ;
  match Certificates_sync.update ~__context with
  | Ok () ->
      info "successfully synced certificates"
  | Error (`Msg (msg, _)) ->
      error "Failed to update host certificates: %s" msg
  | exception e ->
      error "Failed to update host certificates: %s" (Printexc.to_string e)

let sync ~__context ipv6_enabled =
  try
    let accept =
      let management_enabled =
        Xapi_inventory.lookup Xapi_inventory._management_interface <> ""
      in
      match (management_enabled, ipv6_enabled) with
      | true, true ->
          ":::"
      | true, false ->
          ""
      | false, true ->
          "::1:"
      | false, false ->
          "127.0.0.1:"
    in
    let client_auth_name =
      let pool = Helpers.get_pool ~__context in
      if
        Pool_role.is_master ()
        && Db.Pool.get_client_certificate_auth_enabled ~__context ~self:pool
      then
        Some (Db.Pool.get_client_certificate_auth_name ~__context ~self:pool)
      else
        None
    in
    info "Synchronising stunnel (accept = %s, client_auth_name = %s)" accept
      (Option.value ~default:"(none)" client_auth_name) ;
    let needs_restart = Config.update ~accept ~client_auth_name in
    if needs_restart then (
      (* we do not worry about generating certificates here, because systemd will handle this for us, via the gencert service *)
      if not @@ is_enabled () then systemctl_ "enable" ;
      systemctl_ "restart" ;
      (* the stunnel start may have caused gencert to generate new certificates: now sync the DB *)
      update_certificates ~__context ()
    ) else
      debug "No configuration changes: not restarting stunnel"
  with e ->
    Backtrace.is_important e ;
    D.error "Xapi_stunnel_server.restart: failed to restart stunnel" ;
    raise e
