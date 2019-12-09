open Async
open Cmdliner

let setup_log ?style_renderer level =
  let pp_header src ppf (l, h) =
    if l = Logs.App then
      Format.fprintf ppf "%a" Logs_fmt.pp_header (l, h)
    else
      let x =
        match Array.length Sys.argv with
        | 0 ->
          Filename.basename Sys.executable_name
        | _n ->
          Filename.basename Sys.argv.(0)
      in
      let x =
        if Logs.Src.equal src Logs.default then
          x
        else
          Logs.Src.name src
      in
      Format.fprintf ppf "%s: %a " x Logs_fmt.pp_header (l, h)
  in
  let format_reporter =
    let report src =
      let { Logs.report } = Logs_fmt.reporter ~pp_header:(pp_header src) () in
      report src
    in
    { Logs.report }
  in
  Fmt_tty.setup_std_outputs ?style_renderer ();
  Logs.set_level level;
  Logs.set_reporter format_reporter

type cli =
  { follow_redirects : bool
  ; max_redirects : int
  ; meth : Piaf.Method.t
  ; log_level : Logs.level
  ; urls : string list
  ; default_proto : string
  ; head : bool
  ; headers : (string * string) list
  ; max_http_version : Piaf.Versions.HTTP.t
  ; http2_prior_knowledge : bool
  ; cacert : string option
  ; capath : string option
  ; insecure : bool
  }

let format_header formatter (name, value) =
  Format.fprintf formatter "%a: %s" Fmt.(styled `Bold string) name value

let pp_response_headers formatter { Piaf.Response.headers; status; version } =
  Format.fprintf
    formatter
    "@[%a %a@]@\n@[%a@]"
    Piaf.Versions.HTTP.pp_hum
    version
    Piaf.Status.pp_hum
    status
    (Format.pp_print_list
       ~pp_sep:(fun f () -> Format.fprintf f "@\n")
       format_header)
    (Piaf.Headers.to_list headers)

let request ~cli_config:{ head; headers; meth; _ } ~config uri =
  let open Lwt.Syntax in
  let headers = ("user-agent", "carl/0.0.0-experimental") :: headers in
  let* res = Piaf.Client.request ~config ~meth ~headers uri in
  match res with
  | Ok (response, response_body) ->
    let+ () =
      if head then (
        Logs.app (fun m -> m "%a" pp_response_headers response);
        Lwt.async (fun () ->
            Lwt_stream.junk_while (fun _ -> true) response_body);
        Lwt.return_unit)
      else
        Lwt_stream.iter_s
          (fun body_fragment -> Logs_lwt.app (fun m -> m "%s" body_fragment))
          response_body
    in
    `Ok ()
  | Error e ->
    Lwt.return (`Error (false, e))

let log_level_of_list = function [] -> Logs.App | [ _ ] -> Info | _ -> Debug

let rec uri_of_string ~scheme s =
  let maybe_uri = Uri.of_string s in
  match Uri.host maybe_uri, Uri.scheme maybe_uri with
  | None, _ ->
    (* If Uri.of_string didn't get a host it must mean that the scheme wasn't
     * even present. *)
    Logs.debug (fun m ->
        m "Protocol not provided for %s. Using the default scheme: %s" s scheme);
    uri_of_string ~scheme ("//" ^ s)
  | Some _, None ->
    (* e.g. `//example.com` *)
    Uri.with_scheme maybe_uri (Some scheme)
  | Some _, Some _ ->
    maybe_uri

let piaf_config_of_cli
    { follow_redirects
    ; max_redirects
    ; max_http_version
    ; http2_prior_knowledge
    ; cacert
    ; capath
    ; insecure
    ; _
    }
  =
  { Piaf.Config.follow_redirects
  ; max_redirects
  ; max_http_version
  ; http2_prior_knowledge
  ; cacert
  ; capath
  ; allow_insecure = insecure
  }

let main ({ default_proto; log_level; urls; _ } as cli_config) =
  setup_log (Some log_level);
  let config = piaf_config_of_cli cli_config in
  (* TODO: Issue requests for all URLs *)
  let uri = uri_of_string ~scheme:default_proto (List.hd urls) in
  Lwt_main.run (request ~cli_config ~config uri)

(* -d / --data
 * --retry
 * --compressed
 * --connect-timeout
 * --http2-prior-knowledge Use HTTP 2 without HTTP/1.1 Upgrade
 *)
module CLI = struct
  let request =
    let request_conv =
      let parse meth = Ok (Piaf.Method.of_string meth) in
      let print = Piaf.Method.pp_hum in
      Arg.conv ~docv:"method" (parse, print)
    in
    let doc = "Specify request method to use" in
    let docv = "method" in
    Arg.(
      value & opt (some request_conv) None & info [ "X"; "request" ] ~doc ~docv)

  let cacert =
    let doc = "CA certificate to verify peer against" in
    let docv = "file" in
    Arg.(
      value
      & opt (some string) (* lol nix *) None
      (* (Some "/Users/anmonteiro/.nix-profile/etc/ssl/certs/ca-bundle.crt") *)
      & info [ "cacert" ] ~doc ~docv)

  let capath =
    let doc = "CA directory to verify peer against" in
    let docv = "dir" in
    Arg.(value & opt (some string) None & info [ "capath" ] ~doc ~docv)

  let insecure =
    let doc = "Allow insecure server connections when using SSL" in
    Arg.(value & flag & info [ "k"; "insecure" ] ~doc)

  let default_proto =
    let doc = "Use $(docv) for any URL missing a scheme (without `://`)" in
    let docv = "protocol" in
    Arg.(value & opt string "http" & info [ "proto-default" ] ~doc ~docv)

  let head =
    let doc = "Show document info only" in
    Arg.(value & flag & info [ "I"; "head" ] ~doc)

  let headers =
    let header_conv =
      let parse header =
        match String.split_on_char ':' header with
        | [] ->
          Error (`Msg "Header can't be the empty string")
        | [ x ] ->
          Error
            (`Msg (Format.asprintf "Expecting `name: value` string, got: %s" x))
        | name :: values ->
          let value = Util.String.trim_left (String.concat ":" values) in
          Ok (name, value)
      in
      let print = format_header in
      Arg.conv ~docv:"method" (parse, print)
    in
    let doc = "Pass custom header(s) to server" in
    let docv = "header" in
    Arg.(value & opt_all header_conv [] & info [ "H"; "header" ] ~doc ~docv)

  let follow_redirects =
    let doc = "Follow redirects" in
    Arg.(value & flag & info [ "L"; "location" ] ~doc)

  let max_redirects =
    let doc = "Max number of redirects to follow" in
    let docv = "int" in
    Arg.(
      value
      & opt int Piaf.Config.default_config.max_redirects
      & info [ "max-redirs" ] ~doc ~docv)

  let use_http_1_0 =
    let doc = "Use HTTP 1.0" in
    Arg.(value & flag & info [ "0"; "http1.0" ] ~doc)

  let use_http_1_1 =
    let doc = "Use HTTP 1.1" in
    Arg.(value & flag & info [ "http1.1" ] ~doc)

  let use_http_2 =
    let doc = "Use HTTP 2" in
    Arg.(value & flag & info [ "http2" ] ~doc)

  let http_2_prior_knowledge =
    let doc = "Use HTTP 2 without HTTP/1.1 Upgrade" in
    Arg.(value & flag & info [ "http2-prior-knowledge" ] ~doc)

  let verbose =
    let doc = "Verbosity (use multiple times to increase)" in
    Arg.(value & flag_all & info [ "v"; "verbose" ] ~doc)

  let urls =
    let docv = "URLs" in
    Arg.(non_empty & pos_all string [] & info [] ~docv)

  let parse
      cacert
      capath
      default_proto
      head
      headers
      insecure
      follow_redirects
      max_redirects
      request
      use_http_1_0
      use_http_1_1
      use_http_2
      http2_prior_knowledge
      verbose
      urls
    =
    { follow_redirects
    ; max_redirects
    ; meth =
        (match request with
        | None when head ->
          `HEAD
        | None ->
          (* TODO: default to `POST` when we implement --data *)
          `GET
        | Some meth ->
          meth)
    ; log_level = log_level_of_list verbose
    ; urls
    ; default_proto
    ; head
    ; headers
    ; max_http_version =
        (let open Piaf.Versions.HTTP in
        match use_http_2, use_http_1_1, use_http_1_0 with
        | true, _, _ | false, false, false ->
          (* Default to the highest supported if no override specified. *)
          v2_0
        | false, true, _ ->
          v1_1
        | false, false, true ->
          v1_0)
    ; http2_prior_knowledge
    ; cacert
    ; capath
    ; insecure
    }

  let default_cmd =
    Term.(
      const parse
      $ cacert
      $ capath
      $ default_proto
      $ head
      $ headers
      $ insecure
      $ follow_redirects
      $ max_redirects
      $ request
      $ use_http_1_0
      $ use_http_1_1
      $ use_http_2
      $ http_2_prior_knowledge
      $ verbose
      $ urls)

  let cmd =
    let doc = "Like curl, for caml" in
    Term.(ret (const main $ default_cmd)), Term.info "carl" ~version:"todo" ~doc
end

let () = Term.(exit @@ eval CLI.cmd)
