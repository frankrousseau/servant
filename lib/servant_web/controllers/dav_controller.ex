defmodule ServantWeb.DavController do
  @moduledoc """
  Minimal CalDAV (RFC 4791) + CardDAV (RFC 6352) server for phone sync.
  The discovery + sync flows of iOS and DAVx5 exercised it.

  Layout: `/dav` -> `/dav/principals/:uid/` -> the calendar home and the
  address book home.

  - The calendar home is `/dav/calendars/:uid/`. It has one collection per
    Servant calendar, with `.ics` resources.
  - The address book home is `/dav/addressbooks/:uid/`. It has a single
    `contacts` collection, with `.vcf` resources.

  Simplifications, on purpose:

  - PROPFIND ignores the requested prop list. It always answers the full
    supported set for the resource type (clients ignore extras).
  - calendar-query/addressbook-query return the whole collection (clients
    filter locally).
  - A regex extracts the REPORT hrefs, not an XML parser.

  Upgrade to xmerl_sax if a client fails on these simplifications.
  """

  use ServantWeb, :controller

  alias Servant.ApiTokens.Scopes
  alias Servant.CalDAV
  alias Servant.CalDAV.ICS
  alias Servant.CardDAV
  alias Servant.CardDAV.VCard
  alias Servant.Dav
  alias Servant.FilesDav
  alias Servant.PhotosDav
  alias Servant.Storage

  @dav_compliance "1, 3, calendar-access, addressbook"
  @allow "OPTIONS, GET, HEAD, PUT, DELETE, PROPFIND, REPORT, MKCOL"
  @addressbook "contacts"
  # Same ceiling as the upload endpoint.
  @max_put_bytes 1_073_741_824

  def well_known(conn, _params) do
    conn
    |> put_resp_header("location", "/dav")
    |> send_resp(301, "")
  end

  def dav(conn, %{"path" => segments}) do
    case conn.method do
      "OPTIONS" -> send_options(conn)
      "PROPFIND" -> authorized(conn, segments, :read, &propfind/2)
      "REPORT" -> authorized(conn, segments, :read, &report/2)
      "GET" -> authorized(conn, segments, :read, &get_resource/2)
      "HEAD" -> authorized(conn, segments, :read, &get_resource/2)
      "PUT" -> authorized(conn, segments, :write, &put_resource/2)
      "DELETE" -> authorized(conn, segments, :write, &delete_resource/2)
      "MKCOL" -> authorized(conn, segments, :write, &mkcol/2)
      "PROPPATCH" -> send_resp(conn, 403, "")
      _ -> conn |> put_resp_header("allow", @allow) |> send_resp(405, "")
    end
  end

  defp send_options(conn) do
    conn
    |> put_resp_header("dav", @dav_compliance)
    |> put_resp_header("allow", @allow)
    |> send_resp(200, "")
  end

  defp authorized(conn, segments, action, fun) do
    scopes = conn.assigns.api_scopes

    ok? =
      case segments do
        ["calendars" | _] ->
          Scopes.can?(scopes, "calendar", action)

        ["addressbooks" | _] ->
          Scopes.can?(scopes, "contacts", action)

        ["files" | _] ->
          Scopes.can?(scopes, "files", action)

        ["photos" | _] ->
          Scopes.can?(scopes, "photos", action)

        # Root and principal serve the discovery of both trees.
        _ ->
          Scopes.can?(scopes, "calendar", action) or Scopes.can?(scopes, "contacts", action)
      end

    if ok? do
      fun.(conn, segments)
    else
      send_resp(conn, 403, "Insufficient token scope for this DAV tree")
    end
  end

  defp user(conn), do: conn.assigns.current_user
  defp user_tz(conn), do: user(conn).timezone || "Etc/UTC"

  # ----- PROPFIND -----

  defp propfind(conn, []) do
    multistatus(conn, [response_xml("/dav/", root_props(user(conn)))])
  end

  defp propfind(conn, ["principals", uid]) do
    with_owner(conn, uid, fn ->
      multistatus(conn, [response_xml(principal_href(user(conn)), principal_props(user(conn)))])
    end)
  end

  defp propfind(conn, ["calendars", uid]) do
    with_owner(conn, uid, fn ->
      u = user(conn)
      home = [response_xml(cal_home_href(u), home_props())]

      children =
        if depth(conn) > 0 do
          for cal <- CalDAV.calendars(u.id) do
            response_xml(cal_href(u, cal), calendar_props(u.id, cal))
          end
        else
          []
        end

      multistatus(conn, home ++ children)
    end)
  end

  defp propfind(conn, ["calendars", uid, cal]) do
    with_calendar(conn, uid, cal, fn ->
      u = user(conn)
      self_resp = [response_xml(cal_href(u, cal), calendar_props(u.id, cal))]

      children =
        if depth(conn) > 0 do
          for event <- CalDAV.events(u.id, cal) do
            response_xml(event_href(u, cal, event), resource_props(event, "text/calendar"))
          end
        else
          []
        end

      multistatus(conn, self_resp ++ children)
    end)
  end

  defp propfind(conn, ["calendars", uid, cal, name]) do
    with_calendar(conn, uid, cal, fn ->
      u = user(conn)

      case CalDAV.get_event(u.id, cal, name) do
        nil ->
          send_resp(conn, 404, "")

        event ->
          multistatus(conn, [
            response_xml(event_href(u, cal, event), resource_props(event, "text/calendar"))
          ])
      end
    end)
  end

  defp propfind(conn, ["addressbooks", uid]) do
    with_owner(conn, uid, fn ->
      u = user(conn)
      home = [response_xml(card_home_href(u), home_props())]

      children =
        if depth(conn) > 0 do
          [response_xml(book_href(u), addressbook_props(u.id))]
        else
          []
        end

      multistatus(conn, home ++ children)
    end)
  end

  defp propfind(conn, ["addressbooks", uid, @addressbook]) do
    with_owner(conn, uid, fn ->
      u = user(conn)
      self_resp = [response_xml(book_href(u), addressbook_props(u.id))]

      children =
        if depth(conn) > 0 do
          for contact <- CardDAV.contacts(u.id) do
            response_xml(contact_href(u, contact), resource_props(contact, "text/vcard"))
          end
        else
          []
        end

      multistatus(conn, self_resp ++ children)
    end)
  end

  defp propfind(conn, ["addressbooks", uid, @addressbook, name]) do
    with_owner(conn, uid, fn ->
      u = user(conn)

      case CardDAV.get_contact(u.id, name) do
        nil ->
          send_resp(conn, 404, "")

        contact ->
          multistatus(conn, [
            response_xml(contact_href(u, contact), resource_props(contact, "text/vcard"))
          ])
      end
    end)
  end

  defp propfind(conn, ["files" | rest]) do
    u = user(conn)
    entries = FilesDav.tree(u.id)

    case FilesDav.resolve(entries, rest) do
      {:folder, folder} ->
        self_name = if folder, do: FilesDav.name(folder), else: "files"
        self_resp = [response_xml(files_href(rest, true), folder_props(self_name))]

        children =
          if depth(conn) > 0 do
            for child <- FilesDav.children(entries, folder && folder.id) do
              child_href =
                files_href(rest ++ [FilesDav.name(child)], FilesDav.folder?(child))

              response_xml(child_href, file_props(child))
            end
          else
            []
          end

        multistatus(conn, self_resp ++ children)

      {:file, entry} ->
        multistatus(conn, [response_xml(files_href(rest, false), file_props(entry))])

      :not_found ->
        send_resp(conn, 404, "")
    end
  end

  defp propfind(conn, ["photos" | rest]) do
    u = user(conn)
    photos = PhotosDav.photos(u.id)

    case PhotosDav.resolve(photos, rest) do
      {:folder, prefix} ->
        self_name = if prefix, do: Path.basename(prefix), else: "photos"
        self_resp = [response_xml(photos_href(rest, true), folder_props(self_name))]

        children =
          if depth(conn) > 0 do
            folders =
              for name <- PhotosDav.child_folders(photos, prefix) do
                response_xml(photos_href(rest ++ [name], true), folder_props(name))
              end

            files =
              for entry <- PhotosDav.photos_in(photos, prefix) do
                name = PhotosDav.filename(entry)
                response_xml(photos_href(rest ++ [name], false), binary_props(name, entry))
              end

            folders ++ files
          else
            []
          end

        multistatus(conn, self_resp ++ children)

      {:file, entry} ->
        multistatus(conn, [
          response_xml(photos_href(rest, false), binary_props(PhotosDav.filename(entry), entry))
        ])

      :not_found ->
        send_resp(conn, 404, "")
    end
  end

  defp propfind(conn, _), do: send_resp(conn, 404, "")

  # ----- REPORT (multiget / query) -----

  defp report(conn, ["calendars", uid, cal]) do
    with_calendar(conn, uid, cal, fn ->
      with_body(conn, fn body, conn ->
        u = user(conn)
        tz = user_tz(conn)
        props = fn event -> data_props(event, ICS.to_ics(event, tz), "c:calendar-data") end

        responses =
          if String.contains?(body, "multiget") do
            for href <- extract_hrefs(body) do
              case CalDAV.get_event(u.id, cal, basename(href)) do
                nil -> not_found_xml(href)
                event -> response_xml(event_href(u, cal, event), props.(event))
              end
            end
          else
            for event <- CalDAV.events(u.id, cal) do
              response_xml(event_href(u, cal, event), props.(event))
            end
          end

        multistatus(conn, responses)
      end)
    end)
  end

  defp report(conn, ["addressbooks", uid, @addressbook]) do
    with_owner(conn, uid, fn ->
      with_body(conn, fn body, conn ->
        u = user(conn)
        names = CardDAV.contact_names(u.id)

        props = fn contact ->
          data_props(contact, VCard.to_vcf(contact, names: names), "card:address-data")
        end

        responses =
          if String.contains?(body, "multiget") do
            for href <- extract_hrefs(body) do
              case CardDAV.get_contact(u.id, basename(href)) do
                nil -> not_found_xml(href)
                contact -> response_xml(contact_href(u, contact), props.(contact))
              end
            end
          else
            for contact <- CardDAV.contacts(u.id) do
              response_xml(contact_href(u, contact), props.(contact))
            end
          end

        multistatus(conn, responses)
      end)
    end)
  end

  defp report(conn, _), do: send_resp(conn, 404, "")

  # Client REPORT bodies are machine-generated. A regex is sufficient to
  # extract the requested hrefs.
  defp extract_hrefs(body) do
    ~r|<[^>]*?href[^>]*?>\s*([^<]+?)\s*</|i
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.map(&hd/1)
  end

  defp basename(href), do: href |> Path.basename() |> URI.decode()

  # ----- GET / PUT / DELETE on resources -----

  defp get_resource(conn, ["calendars", uid, cal, name]) do
    with_calendar(conn, uid, cal, fn ->
      case CalDAV.get_event(user(conn).id, cal, name) do
        nil -> send_resp(conn, 404, "")
        event -> send_payload(conn, event, "text/calendar", ICS.to_ics(event, user_tz(conn)))
      end
    end)
  end

  defp get_resource(conn, ["addressbooks", uid, @addressbook, name]) do
    with_owner(conn, uid, fn ->
      u = user(conn)

      case CardDAV.get_contact(u.id, name) do
        nil ->
          send_resp(conn, 404, "")

        contact ->
          vcf = VCard.to_vcf(contact, names: CardDAV.contact_names(u.id))
          send_payload(conn, contact, "text/vcard", vcf)
      end
    end)
  end

  defp get_resource(conn, ["files" | rest]) do
    u = user(conn)

    case FilesDav.resolve(FilesDav.tree(u.id), rest) do
      {:file, entry} -> send_stored_file(conn, u.id, entry)
      {:folder, _} -> conn |> put_resp_header("allow", @allow) |> send_resp(405, "")
      :not_found -> send_resp(conn, 404, "")
    end
  end

  defp get_resource(conn, ["photos" | rest]) do
    u = user(conn)

    case PhotosDav.resolve(PhotosDav.photos(u.id), rest) do
      {:file, entry} -> send_stored_file(conn, u.id, entry)
      {:folder, _} -> conn |> put_resp_header("allow", @allow) |> send_resp(405, "")
      :not_found -> send_resp(conn, 404, "")
    end
  end

  defp get_resource(conn, _), do: send_resp(conn, 404, "")

  defp send_stored_file(conn, user_id, entry) do
    with path when is_binary(path) <- entry.data["path"],
         relative when is_binary(relative) <- Storage.relative_from_public(path),
         {:ok, absolute} <- Storage.resolve_owned_path(user_id, relative),
         {:ok, _stat} <- File.stat(absolute) do
      conn
      |> put_resp_header("etag", Dav.etag(entry))
      |> put_resp_content_type(entry.data["mime_type"] || "application/octet-stream")
      |> send_file(200, absolute)
    else
      _ -> send_resp(conn, 404, "")
    end
  end

  defp send_payload(conn, entry, content_type, payload) do
    conn
    |> put_resp_header("etag", Dav.etag(entry))
    |> put_resp_content_type(content_type)
    |> send_resp(200, payload)
  end

  defp put_resource(conn, ["calendars", uid, cal, name]) do
    with_calendar(conn, uid, cal, fn ->
      u = user(conn)
      tz = user_tz(conn)

      upsert(conn, CalDAV.get_event(u.id, cal, name), fn body ->
        CalDAV.put_event(u.id, cal, name, body, tz)
      end)
    end)
  end

  defp put_resource(conn, ["addressbooks", uid, @addressbook, name]) do
    with_owner(conn, uid, fn ->
      u = user(conn)
      upsert(conn, CardDAV.get_contact(u.id, name), &CardDAV.put_contact(u.id, name, &1))
    end)
  end

  defp put_resource(conn, ["files" | rest]) when rest != [] do
    u = user(conn)

    case stream_body_to_tmp(conn, u.id) do
      {:ok, tmp, conn} ->
        result = FilesDav.put_file(u.id, FilesDav.tree(u.id), rest, tmp)
        Storage.cleanup_tmp(Path.dirname(tmp))

        case result do
          {:ok, :created, entry} ->
            conn |> put_resp_header("etag", Dav.etag(entry)) |> send_resp(201, "")

          {:ok, :updated, entry} ->
            conn |> put_resp_header("etag", Dav.etag(entry)) |> send_resp(204, "")

          {:error, :conflict} ->
            send_resp(conn, 409, "")

          {:error, _} ->
            send_resp(conn, 400, "")
        end

      {:too_large, tmp, conn} ->
        Storage.cleanup_tmp(Path.dirname(tmp))
        send_resp(conn, 413, "")

      {:read_error, tmp, conn} ->
        Storage.cleanup_tmp(Path.dirname(tmp))
        send_resp(conn, 400, "")
    end
  end

  defp put_resource(conn, ["photos" | rest]) when rest != [] do
    u = user(conn)
    mtime = oc_mtime(conn)

    case stream_body_to_tmp(conn, u.id) do
      {:ok, tmp, conn} ->
        result = PhotosDav.put_photo(u.id, PhotosDav.photos(u.id), rest, tmp, mtime: mtime)
        Storage.cleanup_tmp(Path.dirname(tmp))

        case result do
          {:ok, :created, entry} ->
            conn |> photo_put_headers(entry, mtime) |> send_resp(201, "")

          {:ok, :updated, entry} ->
            conn |> photo_put_headers(entry, mtime) |> send_resp(204, "")

          {:error, _} ->
            send_resp(conn, 400, "")
        end

      {:too_large, tmp, conn} ->
        Storage.cleanup_tmp(Path.dirname(tmp))
        send_resp(conn, 413, "")

      {:read_error, tmp, conn} ->
        Storage.cleanup_tmp(Path.dirname(tmp))
        send_resp(conn, 400, "")
    end
  end

  defp put_resource(conn, _), do: send_resp(conn, 404, "")

  # X-OC-MTime (Nextcloud dialect, unix seconds): the capture-date fallback
  # for media without EXIF. PhotoSync and rclone both send it.
  defp oc_mtime(conn) do
    with [value] <- get_req_header(conn, "x-oc-mtime"),
         {seconds, ""} <- Integer.parse(value),
         {:ok, dt} <- DateTime.from_unix(seconds) do
      dt
    else
      _ -> nil
    end
  end

  defp photo_put_headers(conn, entry, mtime) do
    conn = put_resp_header(conn, "etag", Dav.etag(entry))
    if mtime, do: put_resp_header(conn, "x-oc-mtime", "accepted"), else: conn
  end

  # Bodies can be large (photos, videos). Stream the chunks to a tmp file.
  # The single 8MB read is sufficient only for the ICS/vCard paths.
  defp stream_body_to_tmp(conn, user_id) do
    dir = Storage.tmp_workspace(user_id)
    path = Path.join(dir, "dav-body")
    file = File.open!(path, [:write, :binary])

    try do
      stream_chunks(conn, file, path, 0)
    after
      File.close(file)
    end
  end

  defp stream_chunks(conn, file, path, total) do
    case read_body(conn, length: 8_000_000) do
      {:ok, chunk, conn} ->
        IO.binwrite(file, chunk)

        if total + byte_size(chunk) > @max_put_bytes,
          do: {:too_large, path, conn},
          else: {:ok, path, conn}

      {:more, chunk, conn} ->
        IO.binwrite(file, chunk)
        new_total = total + byte_size(chunk)

        if new_total > @max_put_bytes,
          do: {:too_large, path, conn},
          else: stream_chunks(conn, file, path, new_total)

      {:error, _reason} ->
        {:read_error, path, conn}
    end
  end

  defp upsert(conn, existing, put_fun) do
    with_body(conn, fn body, conn ->
      cond do
        get_req_header(conn, "if-none-match") == ["*"] and existing != nil ->
          send_resp(conn, 412, "")

        not etag_matches?(conn, existing) ->
          send_resp(conn, 412, "")

        true ->
          case put_fun.(body) do
            {:ok, entry, verb} ->
              conn
              |> put_resp_header("etag", Dav.etag(entry))
              |> send_resp(if(verb == :created, do: 201, else: 204), "")

            {:error, reason} when is_binary(reason) ->
              send_resp(conn, 400, reason)

            {:error, _changeset} ->
              send_resp(conn, 409, "")
          end
      end
    end)
  end

  defp delete_resource(conn, ["calendars", uid, cal, name]) do
    with_calendar(conn, uid, cal, fn ->
      u = user(conn)
      remove(conn, CalDAV.get_event(u.id, cal, name), &CalDAV.delete_event(u.id, &1))
    end)
  end

  defp delete_resource(conn, ["addressbooks", uid, @addressbook, name]) do
    with_owner(conn, uid, fn ->
      u = user(conn)
      remove(conn, CardDAV.get_contact(u.id, name), &CardDAV.delete_contact(u.id, &1))
    end)
  end

  defp delete_resource(conn, ["files" | rest]) when rest != [] do
    u = user(conn)
    entries = FilesDav.tree(u.id)

    case FilesDav.resolve(entries, rest) do
      :not_found ->
        send_resp(conn, 404, "")

      {_kind, entry} ->
        FilesDav.delete(u.id, entries, entry)
        send_resp(conn, 204, "")
    end
  end

  defp delete_resource(conn, ["photos" | rest]) when rest != [] do
    u = user(conn)
    photos = PhotosDav.photos(u.id)

    case PhotosDav.resolve(photos, rest) do
      :not_found ->
        send_resp(conn, 404, "")

      resolved ->
        PhotosDav.delete(u.id, photos, resolved)
        send_resp(conn, 204, "")
    end
  end

  defp delete_resource(conn, _), do: send_resp(conn, 404, "")

  defp mkcol(conn, ["files" | rest]) when rest != [] do
    case FilesDav.mkcol(user(conn).id, FilesDav.tree(user(conn).id), rest) do
      {:ok, _} -> send_resp(conn, 201, "")
      {:error, :exists} -> send_resp(conn, 405, "")
      {:error, :conflict} -> send_resp(conn, 409, "")
      {:error, _} -> send_resp(conn, 400, "")
    end
  end

  defp mkcol(conn, ["photos" | rest]) when rest != [] do
    # Albums are virtual: answer 201 and persist nothing. After that, resolve/2
    # treats unknown paths without an extension as empty albums.
    case PhotosDav.mkcol_status(PhotosDav.photos(user(conn).id), rest) do
      :created -> send_resp(conn, 201, "")
      :exists -> send_resp(conn, 405, "")
    end
  end

  defp mkcol(conn, _), do: send_resp(conn, 405, "")

  defp remove(conn, existing, delete_fun) do
    case existing do
      nil ->
        send_resp(conn, 404, "")

      entry ->
        cond do
          not etag_matches?(conn, entry) ->
            send_resp(conn, 412, "")

          match?({:ok, _}, delete_fun.(entry)) ->
            send_resp(conn, 204, "")

          true ->
            send_resp(conn, 500, "")
        end
    end
  end

  # Reads the request body. Answers 413 and does not crash on a body larger
  # than the default 8 MB limit of Plug (a huge multiget REPORT, a vCard with
  # a big embedded photo).
  defp with_body(conn, fun) do
    case read_body(conn) do
      {:ok, body, conn} -> fun.(body, conn)
      {:more, _partial, conn} -> send_resp(conn, 413, "")
      {:error, _reason} -> send_resp(conn, 400, "")
    end
  end

  # If-Match precondition. An absent header always passes.
  defp etag_matches?(conn, existing) do
    case get_req_header(conn, "if-match") do
      [] -> true
      ["*"] -> existing != nil
      [tag] -> existing != nil and tag == Dav.etag(existing)
      _ -> false
    end
  end

  # ----- guards -----

  defp with_owner(conn, uid, fun) do
    if uid == user(conn).id, do: fun.(), else: send_resp(conn, 404, "")
  end

  defp with_calendar(conn, uid, cal, fun) do
    cond do
      uid != user(conn).id -> send_resp(conn, 404, "")
      cal not in CalDAV.calendars(user(conn).id) -> send_resp(conn, 404, "")
      true -> fun.()
    end
  end

  defp depth(conn) do
    case get_req_header(conn, "depth") do
      ["0"] -> 0
      _ -> 1
    end
  end

  # ----- hrefs -----

  defp files_href(segments, collection?) do
    base = "/dav/files/" <> Enum.map_join(segments, "/", &encode_segment/1)
    if collection? and segments != [], do: base <> "/", else: base
  end

  defp photos_href(segments, collection?) do
    base = "/dav/photos/" <> Enum.map_join(segments, "/", &encode_segment/1)
    if collection? and segments != [], do: base <> "/", else: base
  end

  defp folder_props(name) do
    [
      "<d:displayname>",
      xml_escape(name),
      "</d:displayname><d:resourcetype><d:collection/></d:resourcetype>"
    ]
  end

  defp file_props(entry) do
    if FilesDav.folder?(entry) do
      folder_props(FilesDav.name(entry))
    else
      binary_props(FilesDav.name(entry), entry)
    end
  end

  # Non-collection props shared by the files and photos trees.
  defp binary_props(name, entry) do
    [
      "<d:displayname>",
      xml_escape(name),
      "</d:displayname><d:resourcetype/>",
      "<d:getcontentlength>",
      to_string(entry.data["size"] || 0),
      "</d:getcontentlength>",
      "<d:getcontenttype>",
      xml_escape(entry.data["mime_type"] || "application/octet-stream"),
      "</d:getcontenttype>",
      "<d:getlastmodified>",
      http_date(entry.updated_at),
      "</d:getlastmodified>",
      "<d:getetag>",
      xml_escape(Dav.etag(entry)),
      "</d:getetag>"
    ]
  end

  defp http_date(%DateTime{} = dt), do: Calendar.strftime(dt, "%a, %d %b %Y %H:%M:%S GMT")

  defp http_date(%NaiveDateTime{} = ndt),
    do: ndt |> DateTime.from_naive!("Etc/UTC") |> http_date()

  defp http_date(_), do: ""

  defp principal_href(u), do: "/dav/principals/#{u.id}/"
  defp cal_home_href(u), do: "/dav/calendars/#{u.id}/"
  defp card_home_href(u), do: "/dav/addressbooks/#{u.id}/"
  defp cal_href(u, cal), do: cal_home_href(u) <> encode_segment(cal) <> "/"
  defp book_href(u), do: card_home_href(u) <> @addressbook <> "/"

  defp event_href(u, cal, event),
    do: cal_href(u, cal) <> encode_segment(CalDAV.resource_name(event))

  defp contact_href(u, contact),
    do: book_href(u) <> encode_segment(CardDAV.resource_name(contact))

  defp encode_segment(seg), do: URI.encode(seg, &URI.char_unreserved?/1)

  # ----- prop sets -----
  # They are fixed per resource type. See @moduledoc.

  defp root_props(u) do
    [
      "<d:resourcetype><d:collection/></d:resourcetype>",
      current_user_principal(u)
    ]
  end

  defp principal_props(u) do
    [
      "<d:resourcetype><d:principal/></d:resourcetype>",
      "<d:displayname>",
      xml_escape(u.display_name || u.username),
      "</d:displayname>",
      current_user_principal(u),
      "<d:principal-URL><d:href>",
      principal_href(u),
      "</d:href></d:principal-URL>",
      "<c:calendar-home-set><d:href>",
      cal_home_href(u),
      "</d:href></c:calendar-home-set>",
      "<card:addressbook-home-set><d:href>",
      card_home_href(u),
      "</d:href></card:addressbook-home-set>",
      "<c:calendar-user-address-set><d:href>mailto:",
      xml_escape(u.email || u.username),
      "</d:href></c:calendar-user-address-set>"
    ]
  end

  defp home_props do
    ["<d:resourcetype><d:collection/></d:resourcetype>", "<d:displayname>Servant</d:displayname>"]
  end

  defp calendar_props(user_id, cal) do
    [
      "<d:resourcetype><d:collection/><c:calendar/></d:resourcetype>",
      "<d:displayname>",
      xml_escape(cal),
      "</d:displayname>",
      "<cs:getctag>",
      Dav.ctag(CalDAV.events(user_id, cal)),
      "</cs:getctag>",
      "<c:supported-calendar-component-set><c:comp name=\"VEVENT\"/>",
      "</c:supported-calendar-component-set>",
      "<d:supported-report-set>",
      "<d:supported-report><d:report><c:calendar-multiget/></d:report></d:supported-report>",
      "<d:supported-report><d:report><c:calendar-query/></d:report></d:supported-report>",
      "</d:supported-report-set>",
      privilege_set()
    ]
  end

  defp addressbook_props(user_id) do
    [
      "<d:resourcetype><d:collection/><card:addressbook/></d:resourcetype>",
      "<d:displayname>Contacts</d:displayname>",
      "<cs:getctag>",
      Dav.ctag(CardDAV.contacts(user_id)),
      "</cs:getctag>",
      "<d:supported-report-set>",
      "<d:supported-report><d:report><card:addressbook-multiget/></d:report>",
      "</d:supported-report>",
      "<d:supported-report><d:report><card:addressbook-query/></d:report>",
      "</d:supported-report>",
      "</d:supported-report-set>",
      privilege_set()
    ]
  end

  defp privilege_set do
    [
      "<d:current-user-privilege-set>",
      "<d:privilege><d:read/></d:privilege><d:privilege><d:write/></d:privilege>",
      "</d:current-user-privilege-set>"
    ]
  end

  defp resource_props(entry, content_type) do
    [
      "<d:resourcetype/>",
      "<d:getetag>",
      xml_escape(Dav.etag(entry)),
      "</d:getetag>",
      "<d:getcontenttype>",
      content_type,
      "; charset=utf-8</d:getcontenttype>"
    ]
  end

  defp data_props(entry, payload, data_element) do
    [
      "<d:getetag>",
      xml_escape(Dav.etag(entry)),
      "</d:getetag>",
      "<",
      data_element,
      ">",
      xml_escape(payload),
      "</",
      data_element,
      ">"
    ]
  end

  defp current_user_principal(u) do
    [
      "<d:current-user-principal><d:href>",
      principal_href(u),
      "</d:href>",
      "</d:current-user-principal>"
    ]
  end

  # ----- multistatus rendering -----

  defp multistatus(conn, responses) do
    body = [
      ~s(<?xml version="1.0" encoding="utf-8"?>\n),
      ~s(<d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" ),
      ~s(xmlns:card="urn:ietf:params:xml:ns:carddav" ),
      ~s(xmlns:cs="http://calendarserver.org/ns/">),
      responses,
      "</d:multistatus>"
    ]

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(207, IO.iodata_to_binary(body))
  end

  defp response_xml(href, props) do
    [
      "<d:response><d:href>",
      xml_escape(href),
      "</d:href>",
      "<d:propstat><d:prop>",
      props,
      "</d:prop>",
      "<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
    ]
  end

  defp not_found_xml(href) do
    [
      "<d:response><d:href>",
      xml_escape(href),
      "</d:href>",
      "<d:status>HTTP/1.1 404 Not Found</d:status></d:response>"
    ]
  end

  defp xml_escape(text) do
    text
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
