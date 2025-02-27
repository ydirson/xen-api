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
let with_lock = Xapi_stdext_threads.Threadext.Mutex.execute

open Client
open Xapi_stdext_std.Xstringext

module D = Debug.Make (struct let name = "xapi_network" end)

open D
open Network

let bridge_blacklist = ["xen"; "xapi"; "vif"; "tap"; "eth"]

let internal_bridge_m = Mutex.create ()

let assert_network_is_managed ~__context ~self =
  if not (Db.Network.get_managed ~__context ~self) then
    raise
      (Api_errors.Server_error
         (Api_errors.network_unmanaged, [Ref.string_of self])
      )

let create_internal_bridge ~__context ~bridge ~uuid ~persist =
  let dbg = Context.string_of_task __context in
  let current = Net.Bridge.get_all dbg () in
  if List.mem bridge current then (* No serialisation needed in this case *)
    debug "Internal bridge %s exists" bridge
  else (* Atomic test-and-set process *)
    with_lock internal_bridge_m (fun () ->
        let current = Net.Bridge.get_all dbg () in
        if not (List.mem bridge current) then (
          let other_config = [("network-uuids", uuid)] in
          debug "Creating internal bridge %s (uuid:%s)" bridge uuid ;
          Net.Bridge.create dbg None None None (Some other_config) bridge
        )
    ) ;
  Net.Bridge.set_persistent dbg bridge persist

let set_himn_ip ~__context bridge other_config =
  let dbg = Context.string_of_task __context in
  try
    let ip = List.assoc "ip_begin" other_config in
    let netmask = List.assoc "netmask" other_config in
    let persist =
      try List.assoc "persist" other_config |> bool_of_string with _ -> false
    in
    let ipv4_conf =
      Network_interface.(
        Static4 [(Unix.inet_addr_of_string ip, netmask_to_prefixlen netmask)]
      )
    in
    Net.Interface.set_ipv4_conf dbg bridge ipv4_conf ;
    Xapi_mgmt_iface.reconfigure_himn ~__context ~addr:(Some ip) ;
    Net.Interface.set_persistent dbg bridge persist
  with Not_found ->
    error
      "Cannot setup host internal management network: no other-config:ip_begin \
       or other-config:netmask"

let is_himn net =
  List.assoc_opt Xapi_globs.is_guest_installer_network
    net.API.network_other_config
  = Some "true"

let check_himn ~__context =
  let nets = Db.Network.get_all_records ~__context in
  let mnets = List.filter (fun (_, n) -> is_himn n) nets in
  match mnets with
  | [] ->
      ()
  | (_, rc) :: _ ->
      let dbg = Context.string_of_task __context in
      let bridges = Net.Bridge.get_all dbg () in
      if List.mem rc.API.network_bridge bridges then
        set_himn_ip ~__context rc.API.network_bridge rc.API.network_other_config

let attach_internal ?(management_interface = false) ?(force_bringup = false)
    ~__context ~self () =
  let host = Helpers.get_localhost ~__context in
  let net = Db.Network.get_record ~__context ~self in
  let local_pifs =
    Xapi_network_attach_helpers.get_local_pifs ~__context ~network:self ~host
  in
  let persist =
    try List.mem_assoc "persist" net.API.network_other_config with _ -> false
  in
  (* Check whether the network is managed or not. If not, the only thing that it must do is check whether the bridge exists.*)
  if not net.API.network_managed then (
    let dbg = Context.string_of_task __context in
    let bridges = Net.Bridge.get_all dbg () in
    if not (List.mem net.API.network_bridge bridges) then
      raise
        (Api_errors.Server_error
           (Api_errors.bridge_not_available, [net.API.network_bridge])
        )
  ) else (
    (* Ensure internal bridge exists and is up. external bridges will be
       brought up through Nm.bring_pif_up. *)
    if List.length local_pifs = 0 then
      create_internal_bridge ~__context ~bridge:net.API.network_bridge
        ~uuid:net.API.network_uuid ~persist ;
    (* Check if we're a Host-Internal Management Network (HIMN) (a.k.a. guest-installer network) *)
    if is_himn net then
      set_himn_ip ~__context net.API.network_bridge net.API.network_other_config ;
    (* Ensure that required PIFs are attached *)
    List.iter
      (fun pif ->
        let uuid = Db.PIF.get_uuid ~__context ~self:pif in
        if Db.PIF.get_managed ~__context ~self:pif then (
          if
            force_bringup
            || Db.PIF.get_currently_attached ~__context ~self:pif = false
            || management_interface
          then (
            Xapi_network_attach_helpers.assert_no_slave ~__context pif ;
            debug "Trying to attach PIF: %s" uuid ;
            Nm.bring_pif_up ~__context ~management_interface pif
          )
        ) else if management_interface then
          info
            "PIF %s is the management interface, but it is not managed by \
             xapi. The bridge and IP must be configured through other means."
            uuid
        else
          info
            "PIF %s is needed by a VM, but not managed by xapi. The bridge \
             must be configured through other means."
            uuid
      )
      local_pifs
  )

let detach ~__context net =
  let dbg = Context.string_of_task __context in
  let bridge_name = net.API.network_bridge in
  if is_himn net then
    Xapi_mgmt_iface.reconfigure_himn ~__context ~addr:None ;
  if net.API.network_managed && Net.Interface.exists dbg bridge_name then (
    List.iter
      (fun iface ->
        D.warn "Untracked interface %s exists on bridge %s: deleting" iface
          bridge_name ;
        Net.Interface.bring_down dbg iface ;
        Net.Bridge.remove_port dbg bridge_name iface
      )
      (Net.Bridge.get_interfaces dbg bridge_name) ;
    Net.Bridge.destroy dbg false bridge_name
  )

let attach ~__context ~network ~host:_ =
  attach_internal ~force_bringup:true ~__context ~self:network ()

let active_vifs_to_networks : (API.ref_VIF, API.ref_network) Hashtbl.t =
  Hashtbl.create 10

let active_vifs_to_networks_m = Mutex.create ()

let register_vif ~__context vif =
  let network = Db.VIF.get_network ~__context ~self:vif in
  with_lock active_vifs_to_networks_m (fun () ->
      debug "register_vif vif=%s network=%s" (Ref.string_of vif)
        (Ref.string_of network) ;
      Hashtbl.replace active_vifs_to_networks vif network
  )

let deregister_vif ~__context vif =
  let network = Db.VIF.get_network ~__context ~self:vif in
  let network_rc = Db.Network.get_record ~__context ~self:network in
  let bridge = network_rc.API.network_bridge in
  let internal_only = network_rc.API.network_PIFs = [] in
  with_lock active_vifs_to_networks_m (fun () ->
      Hashtbl.remove active_vifs_to_networks vif ;
      (* If a network has PIFs, then we create/destroy when the PIFs are plugged/unplugged.
         			   If a network is entirely internal, then we remove it after we've stopped using it
         			   *unless* someone else is still using it. *)
      if internal_only then (
        (* Are there any more vifs using this network? *)
        let others =
          Hashtbl.fold
            (fun v n acc -> if n = network then v :: acc else acc)
            active_vifs_to_networks []
        in
        debug "deregister_vif vif=%s network=%s remaining vifs = [ %s ]"
          (Ref.string_of vif) (Ref.string_of network)
          (String.concat "; " (List.map Ref.short_string_of others)) ;
        if others = [] then
          let dbg = Context.string_of_task __context in
          let ifs = Net.Bridge.get_interfaces dbg bridge in
          if ifs = [] then
            detach ~__context network_rc
          else
            error
              "Cannot remove bridge %s: other interfaces still present [ %s ]"
              bridge (String.concat "; " ifs)
      )
  )

let counter = ref 0

let mutex = Mutex.create ()

let stem = "xapi"

let pool_introduce ~__context ~name_label ~name_description ~mTU ~other_config
    ~bridge ~managed ~purpose =
  let r = Ref.make () and uuid = Uuid.make () in
  Db.Network.create ~__context ~ref:r ~uuid:(Uuid.to_string uuid)
    ~current_operations:[] ~allowed_operations:[] ~purpose ~name_label
    ~name_description ~mTU ~bridge ~managed ~other_config ~blobs:[] ~tags:[]
    ~default_locking_mode:`unlocked ~assigned_ips:[] ;
  r

let rec choose_bridge_name bridges =
  let name = stem ^ string_of_int !counter in
  incr counter ;
  if List.mem name bridges then
    choose_bridge_name bridges
  else
    name

let create ~__context ~name_label ~name_description ~mTU ~other_config ~bridge
    ~managed ~tags =
  with_lock mutex (fun () ->
      let networks = Db.Network.get_all ~__context in
      let bridges =
        List.map (fun self -> Db.Network.get_bridge ~__context ~self) networks
      in
      let mTU = if mTU <= 0L then 1500L else mTU in
      let is_internal_session =
        try
          Db.Session.get_pool ~__context ~self:(Context.get_session_id __context)
        with _ -> true
      in
      let bridge =
        if bridge = "" then
          choose_bridge_name bridges
        else (
          (* Trust bridge names set on pool-internal sessions (e.g. coming from a VM import) *)
          if
            (not is_internal_session)
            && (String.length bridge > 15
               || List.exists
                    (fun s -> String.startswith s bridge)
                    bridge_blacklist
               )
          then
            raise
              (Api_errors.Server_error
                 (Api_errors.invalid_value, ["bridge"; bridge])
              ) ;
          if List.mem bridge bridges then
            raise
              (Api_errors.Server_error (Api_errors.bridge_name_exists, [bridge])) ;
          bridge
        )
      in
      let r = Ref.make () and uuid = Uuid.make () in
      Db.Network.create ~__context ~ref:r ~uuid:(Uuid.to_string uuid)
        ~current_operations:[] ~allowed_operations:[] ~name_label
        ~name_description ~mTU ~bridge ~managed ~other_config ~blobs:[] ~tags
        ~purpose:[] ~default_locking_mode:`unlocked ~assigned_ips:[] ;
      r
  )

let destroy ~__context ~self =
  let vifs = Db.Network.get_VIFs ~__context ~self in
  let connected =
    List.filter
      (fun self ->
        Db.VIF.get_currently_attached ~__context ~self
        || Db.VIF.get_reserved ~__context ~self
      )
      vifs
  in
  if connected <> [] then
    raise
      (Api_errors.Server_error
         (Api_errors.network_contains_vif, List.map Ref.string_of connected)
      ) ;
  let pifs = Db.Network.get_PIFs ~__context ~self in
  if pifs <> [] then
    raise
      (Api_errors.Server_error
         (Api_errors.network_contains_pif, List.map Ref.string_of pifs)
      ) ;
  (* CA-43250: don't let people remove the internal management network *)
  let oc = Db.Network.get_other_config ~__context ~self in
  if
    List.mem_assoc Xapi_globs.is_host_internal_management_network oc
    &&
    try
      bool_of_string
        (List.assoc Xapi_globs.is_host_internal_management_network oc)
    with _ -> false
  then
    raise
      (Api_errors.Server_error
         (Api_errors.cannot_destroy_system_network, [Ref.string_of self])
      ) ;
  (* destroy all the VIFs now rather than wait for the GC thread. *)
  List.iter
    (fun vif ->
      Helpers.log_exn_continue
        (Printf.sprintf "destroying VIF: %s" (Ref.string_of vif))
        (fun vif -> Db.VIF.destroy ~__context ~self:vif)
        vif
    )
    vifs ;
  Db.Network.destroy ~__context ~self

let create_new_blob ~__context ~network ~name ~mime_type ~public =
  let blob = Xapi_blob.create ~__context ~mime_type ~public in
  Db.Network.add_to_blobs ~__context ~self:network ~key:name ~value:blob ;
  blob

let set_default_locking_mode ~__context ~network ~value =
  (* Get all VIFs which are attached and associated with this network. *)
  let open Db_filter_types in
  match
    Db.VIF.get_records_where ~__context
      ~expr:
        (And
           ( Eq (Field "network", Literal (Ref.string_of network))
           , Eq (Field "currently_attached", Literal "true")
           )
        )
  with
  | [] ->
      Db.Network.set_default_locking_mode ~__context ~self:network ~value
  | (vif, _) :: _ ->
      raise
        (Api_errors.Server_error
           (Api_errors.vif_in_use, [Ref.string_of network; Ref.string_of vif])
        )

let string_of_exn = function
  | Api_errors.Server_error (code, params) ->
      Printf.sprintf "%s [ %s ]" code (String.concat "; " params)
  | e ->
      Printexc.to_string e

(* Networking helper functions for VMs and VIFs *)

let attach_for_vif ~__context ~vif () =
  register_vif ~__context vif ;
  let network = Db.VIF.get_network ~__context ~self:vif in
  attach_internal ~__context ~self:network () ;
  Xapi_udhcpd.maybe_add_lease ~__context vif ;
  Pvs_proxy_control.maybe_start_proxy_for_vif ~__context ~vif

let attach_for_vm ~__context ~host:_ ~vm =
  List.iter
    (fun vif -> attach_for_vif ~__context ~vif ())
    (Db.VM.get_VIFs ~__context ~self:vm)

let detach_for_vif ~__context ~vif =
  deregister_vif ~__context vif ;
  Pvs_proxy_control.maybe_stop_proxy_for_vif ~__context ~vif

let detach_for_vm ~__context ~host:_ ~vm =
  try
    List.iter
      (fun vif -> detach_for_vif ~__context ~vif)
      (Db.VM.get_VIFs ~__context ~self:vm)
  with e -> error "Caught %s while detaching networks" (string_of_exn e)

let with_networks_attached_for_vm ~__context ?host ~vm f =
  ( match host with
  | None ->
      (* use local host *)
      attach_for_vm ~__context ~host:(Helpers.get_localhost ~__context) ~vm
  | Some host ->
      Helpers.call_api_functions ~__context (fun rpc session_id ->
          Client.Network.attach_for_vm ~rpc ~session_id ~host ~vm
      )
  ) ;
  try f ()
  with e ->
    info "Caught %s: detaching networks" (string_of_exn e) ;
    ( try
        match host with
        | None ->
            (* use local host *)
            detach_for_vm ~__context
              ~host:(Helpers.get_localhost ~__context)
              ~vm
        | Some host ->
            Helpers.call_api_functions ~__context (fun rpc session_id ->
                Client.Network.detach_for_vm ~rpc ~session_id ~host ~vm
            )
      with e -> error "Caught %s while detaching networks" (string_of_exn e)
    ) ;
    raise e

(* Note that in the revision history is a version of this function
 * with logic for additional purposes, which may be useful in future. *)
let assert_can_add_purpose ~__context ~network:_ ~current:_ newval =
  let sop (*string-of-porpoise*) = Record_util.network_purpose_to_string in
  let reject conflicting =
    raise
      Api_errors.(
        Server_error
          (network_incompatible_purposes, [sop newval; sop conflicting])
      )
  in
  let assert_no_net_has_bad_porpoise bads =
    (* Sadly we can't use Db.Network.get_refs_where because the expression
     * type doesn't allow searching for a value inside a list. *)
    Db.Network.get_all ~__context
    |> List.iter (fun nwk ->
           Db.Network.get_purpose ~__context ~self:nwk
           |> List.iter (fun suspect ->
                  if List.mem suspect bads then (
                    info
                      "Cannot set new network purpose %s when there is a \
                       network with purpose %s"
                      (sop newval) (sop suspect) ;
                    reject suspect
                  )
              )
       )
  in
  match newval with
  | `nbd ->
      assert_no_net_has_bad_porpoise [`insecure_nbd]
  | `insecure_nbd ->
      assert_no_net_has_bad_porpoise [`nbd]

let add_purpose ~__context ~self ~value =
  let current = Db.Network.get_purpose ~__context ~self in
  if not (List.mem value current) then (
    assert_can_add_purpose ~__context ~network:self ~current value ;
    Db.Network.set_purpose ~__context ~self ~value:(value :: current)
  )

let remove_purpose ~__context ~self ~value =
  let current = Db.Network.get_purpose ~__context ~self in
  if List.mem value current then
    let porpoises = List.filter (( <> ) value) current in
    Db.Network.set_purpose ~__context ~self ~value:porpoises
