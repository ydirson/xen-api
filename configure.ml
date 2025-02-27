module C = Configurator.V1

let config = Hashtbl.create 20

(** [flag arg ~doc ~default] sets the default value of [arg] to [default].
    Allow the user to override from the command-line with [--arg], and show
    [doc] on [--help].
    *)
let flag arg ~doc ~default =
  let key = String.uppercase_ascii arg in
  Hashtbl.replace config key default ;
  ("--" ^ arg, Arg.String (Hashtbl.replace config key), doc)

let libdir_default =
  (* This is the same that [dune install] does by default when invoked without --prefix.
     This ensures that files end up in the right place regardless of whether [opam] is used or not.
     We unconditionally use `--prefix` on the command-line so we need to use this too.
  *)
  Findlib.default_location ()

let args =
  [
    flag "prefix" ~doc:"DIR Final install destination" ~default:"/usr"
    (* ensures bin and sbin end up in right places *)
  ; flag "libdir" ~doc:"DIR Directory where library files are copied"
      ~default:libdir_default
  ; flag "mandir" ~doc:"DIR Manpages" ~default:"/usr/share/man"
  ; flag "varpatchdir" ~doc:"DIR hotfixes" ~default:"/var/patch"
  ; flag "etcxendir" ~doc:"DIR configuration files" ~default:"/etc/xensource"
  ; flag "optdir" ~doc:"DIR system files" ~default:"/opt/xensource"
  ; flag "plugindir" ~doc:"DIR xapi plugins" ~default:"/etc/xapi.d/plugins"
  ; flag "extensiondir" ~doc:"DIR XenAPI extensions"
      ~default:"/etc/xapi.d/extensions"
  ; flag "hooksdir" ~doc:"DIR hook scripts" ~default:"/etc/xapi.d"
  ; flag "inventory" ~doc:"FILE the inventory file"
      ~default:"/etc/xensource-inventory"
  ; flag "xapiconf" ~doc:"DIR xapi master config file" ~default:"/etc/xapi.conf"
  ; flag "libexecdir" ~doc:"DIR utility binaries"
      ~default:"/opt/xensource/libexec"
  ; flag "scriptsdir" ~doc:"DIR utility scripts"
      ~default:"/etc/xensource/scripts"
  ; flag "sharedir" ~doc:"DIR shared binary files" ~default:"/opt/xensource"
  ; flag "webdir" ~doc:"DIR html files" ~default:"/opt/xensource/www"
  ; flag "cluster_stack_root" ~doc:"DIR cluster stacks"
      ~default:"/usr/libexec/xapi/cluster-stack"
  ; flag "udevdir" ~doc:"DIR udev scripts" ~default:"/etc/udev"
  ; flag "docdir" ~doc:"DIR XenAPI documentation" ~default:"/usr/share/xapi/doc"
  ; flag "sdkdir" ~doc:"DIR XenAPI SDK" ~default:"/usr/share/xapi/sdk"
  ; flag "bindir" ~doc:"DIR binaries" ~default:"/usr/bin"
  ; flag "sbindir" ~doc:"DIR superuser binaries" ~default:"/usr/sbin"
  ; flag "xenopsd_libexecdir" ~doc:"DIR xenopsd helper executables"
      ~default:"/usr/lib/xenopsd"
  ; flag "qemu_wrapper_dir" ~doc:"DIR xen helper executables"
      ~default:"/usr/lib/xenopsd"
  ; flag "etcdir" ~doc:"DIR configuration files" ~default:"/etc"
  ; flag "yumplugindir" ~doc:"DIR YUM plugins" ~default:"/usr/lib/yum-plugins"
  ; flag "yumpluginconfdir" ~doc:"DIR YUM plugins conf dir"
      ~default:"/etc/yum/pluginconf.d"
  ]
  |> Arg.align

let expand start finish input output =
  let command =
    Printf.sprintf "cat %s | sed -r 's=%s=%s=g' > %s" input start finish output
  in
  if Sys.command command <> 0 then (
    Printf.fprintf stderr "Failed to expand %s -> %s in %s producing %s\n" start
      finish input output ;
    Printf.fprintf stderr "Command-line was:\n%s\n%!" command ;
    exit 1
  )

let () =
  C.main ~args ~name:"xapi" @@ fun _c ->
  let lines =
    "# Warning - this file is autogenerated by the configure script"
    :: "# Do not edit"
    :: (config
       |> Hashtbl.to_seq
       |> (Seq.map @@ fun (k, v) -> Printf.sprintf "export %s=%s" k v)
       |> List.of_seq
       )
  in
  List.iter print_endline lines ;
  (* Expand @LIBEXEC@ in udev rules *)
  try
    let xenopsd_libexecdir = Hashtbl.find config "XENOPSD_LIBEXECDIR" in
    expand "@LIBEXEC@" xenopsd_libexecdir "ocaml/xenopsd/scripts/vif.in"
      "ocaml/xenopsd/scripts/vif" ;
    expand "@LIBEXEC@" xenopsd_libexecdir
      "ocaml/xenopsd/scripts/xen-backend.rules.in"
      "ocaml/xenopsd/scripts/xen-backend.rules"
  with Not_found -> failwith "xenopsd_libexecdir not set"
