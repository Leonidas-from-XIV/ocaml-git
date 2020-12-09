let () = Random.self_init ()

open Git_unix
module Sync = Sync (Store) (Git_cohttp_unix)

let src = Logs.Src.create "ogit-fetch" ~doc:"logs binary event"

module Log = (val Logs.src_log src : Logs.LOG)

let pad n x =
  if String.length x > n then x else x ^ String.make (n - String.length x) ' '

let pp_header ppf (level, header) =
  let level_style =
    match level with
    | Logs.App -> Logs_fmt.app_style
    | Logs.Debug -> Logs_fmt.debug_style
    | Logs.Warning -> Logs_fmt.warn_style
    | Logs.Error -> Logs_fmt.err_style
    | Logs.Info -> Logs_fmt.info_style
  in
  let level = Logs.level_to_string (Some level) in
  Fmt.pf ppf "[%a][%a]"
    (Fmt.styled level_style Fmt.string)
    level (Fmt.option Fmt.string)
    (Option.map (pad 10) header)

let reporter ppf =
  let report src level ~over k msgf =
    let k _ =
      over ();
      k ()
    in
    let with_src_and_stamp h _ k fmt =
      let dt = Mtime.Span.to_us (Mtime_clock.elapsed ()) in
      Fmt.kpf k ppf
        ("%s %a %a: @[" ^^ fmt ^^ "@]@.")
        (pad 10 (Fmt.strf "%+04.0fus" dt))
        pp_header (level, h)
        Fmt.(styled `Magenta string)
        (pad 10 @@ Logs.Src.name src)
    in
    msgf @@ fun ?header ?tags fmt -> with_src_and_stamp header tags k fmt
  in
  { Logs.report }

let setup_logs style_renderer level ppf =
  Fmt_tty.setup_std_outputs ?style_renderer ();
  Logs.set_level level;
  Logs.set_reporter (reporter ppf);
  let quiet = match style_renderer with Some _ -> true | None -> false in
  quiet, ppf

type error = [ `Store of Store.error | `Sync of Sync.error ]

let store_err err = `Store err
let sync_err err = `Sync err

let pp_error ppf = function
  | `Store err -> Fmt.pf ppf "(`Store %a)" Store.pp_error err
  | `Sync err -> Fmt.pf ppf "(`Sync %a)" Sync.pp_error err

module SSH = Awa_conduit.Make (Lwt) (Conduit_lwt) (Mclock)

let ssh_protocol = SSH.protocol_with_ssh Conduit_lwt.TCP.protocol

let ssh_cfg edn ssh_seed =
  assert (String.length ssh_seed > 0);
  let key = Awa.Keys.of_seed ssh_seed in
  match edn with
  | { Smart_git.scheme = `SSH user; path; _ } ->
      let req = Awa.Ssh.Exec (Fmt.strf "git-upload-pack '%s'" path) in
      Some { Awa_conduit.user; key; req; authenticator = None }
  | _ -> None

let ssh_resolve (ssh_cfg : Awa_conduit.endpoint) domain_name =
  let open Lwt.Infix in
  Conduit_lwt.TCP.resolve ~port:22 domain_name >|= function
  | Some edn -> Some (edn, ssh_cfg)
  | None -> None

let main (ssh_seed : string)
    (references : (Git.Reference.t * Git.Reference.t) list) (directory : string)
    (repository : Smart_git.endpoint) : (unit, 'error) Lwt_result.t =
  let repo_root =
    (match directory with "" -> Sys.getcwd () | _ -> directory) |> Fpath.v
  in
  let ( >>?= ) = Lwt_result.bind in
  let ( >>!= ) v f = Lwt_result.map_err f v in
  let resolvers =
    let git_scheme_resolver = Conduit_lwt.TCP.resolve ~port:9418 in
    let ssh_cfg = ssh_cfg repository ssh_seed in
    Conduit.empty
    |> Conduit_lwt.add Conduit_lwt.TCP.protocol git_scheme_resolver
    |> Conduit_lwt.add ssh_protocol (ssh_resolve @@ Option.get ssh_cfg)
  in
  Store.v repo_root >>!= store_err >>?= fun store ->
  let push_stdout = print_endline in
  let push_stderr = prerr_endline in
  Sync.fetch ~push_stdout ~push_stderr ~resolvers repository store
    (`Some references)
  >>!= sync_err
  >>?= fun _ -> Lwt.return (Ok ())

open Cmdliner

module Flag = struct
  (** We want ogit-fetch to have the following interface:
     ogit-fetch [-r <path> | --root <path>] [--output <output_channel>] [--progress] <repository> <refspec>... *)

  (* TODO polish code & CLI *)

  let output =
    let conv' =
      let parse str =
        match str with
        | "stdout" -> Ok Fmt.stdout
        | "stderr" -> Ok Fmt.stderr
        | s -> Error (`Msg (Fmt.strf "%s is not an output." s))
      in
      let print ppf v =
        Fmt.pf ppf "%s" (if v = Fmt.stdout then "stdout" else "stderr")
      in
      Arg.conv ~docv:"<output>" (parse, print)
    in
    let doc =
      "Output of the progress status. Can take values 'stdout' (default) or \
       'stderr'."
    in
    Arg.(value & opt conv' Fmt.stdout & info [ "output" ] ~doc ~docv:"<output>")

  let progress =
    let doc =
      "Progress status is reported on the standard error stream by default \
       when it is attached to a terminal, unless -q is specified. This flag \
       forces progress status even if the standard error stream is not \
       directed to a terminal."
    in
    Arg.(value & flag & info [ "progress" ] ~doc)

  let directory =
    let doc = "indicate path to repository root containing '.git' folder" in
    Arg.(value & opt string "" & info [ "r"; "root" ] ~doc ~docv:"<directory>")

  let ssh_seed =
    let doc = "seed for SSH generated by awa_gen_key" in
    Arg.(value & opt string "" & info [ "s"; "seed" ] ~doc ~docv:"<ssh_seed>")

  (** passed argument needs to be a URI of the repository *)
  let repository =
    let endpoint =
      let parse = Smart_git.endpoint_of_string in
      let print = Smart_git.pp_endpoint in
      Arg.conv ~docv:"<uri>" (parse, print)
    in
    let doc = "URI leading to repository" in
    Arg.(
      required & pos 0 (some endpoint) None & info [] ~docv:"<repository>" ~doc)

  (** can be several references of form "remote_ref:local_ref" or "remote_ref", where the latter means that the local_ref should
  have the same name *)
  let references =
    let reference =
      let parse str = Ok (Git.Reference.v str) in
      let print = Git.Reference.pp in
      Arg.conv ~docv:"<ref>" (parse, print)
    in
    let doc = "" in
    Arg.(
      non_empty
      & pos_right 0 (pair ~sep:':' reference reference) []
      & info ~doc ~docv:"<ref>" [])
end

let setup_log =
  Term.(
    const setup_logs
    $ Fmt_cli.style_renderer ()
    $ Logs_cli.level ()
    $ Flag.output)

let main _ ssh_seed references directory repository _ =
  match Lwt_main.run (main ssh_seed references directory repository) with
  | Ok () -> `Ok ()
  | Error (#error as err) -> `Error (false, Fmt.strf "%a" pp_error err)

let command =
  let doc = "Fetch a Git repository by the HTTP protocol." in
  let exits = Term.default_exits in
  ( Term.(
      ret
        ( const main
        $ Flag.progress
        $ Flag.ssh_seed
        $ Flag.references
        $ Flag.directory
        $ Flag.repository
        $ setup_log )),
    Term.info "ogit-fetch" ~version:"v0.1" ~doc ~exits )

let () = Term.(exit @@ eval command)
