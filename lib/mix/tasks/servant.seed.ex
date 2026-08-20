defmodule Mix.Tasks.Servant.Seed do
  @shortdoc "Fill the current dev database with random data"

  @moduledoc """
  Populates the database with random but plausible data for every app screen:
  contacts (birthdays, relations, tags), calendar agendas and events, notes
  with wikilinks, checklists, trackers with their logs, bank transactions with
  running balances, savings and crypto snapshots, invoices, files and
  generated photos.

      $ mix servant.seed
      $ mix servant.seed --user alice
      $ mix servant.seed --photos 0
      $ DEV_DB=demo mix servant.seed    # seed an alternate database

  Without `--user`, the first account is used; on an empty database a "demo"
  account (password "demo1234") is created first. Running the task twice adds
  a second batch on top of the first. Refused when MIX_ENV=prod.
  """

  use Mix.Task

  alias Servant.Accounts
  alias Servant.Accounts.User
  alias Servant.Data
  alias Servant.Notes
  alias Servant.PhotosDav
  alias Servant.Repo
  alias Servant.Storage

  @requirements ["app.start"]

  @impl true
  def run(args) do
    if Mix.env() == :prod do
      Mix.raise("mix servant.seed is a development task, refusing to run in prod")
    end

    {opts, _argv} = OptionParser.parse!(args, strict: [user: :string, photos: :integer])
    user = fetch_user!(opts[:user])
    counts = seed(user, photos: Keyword.get(opts, :photos, 10))

    summary =
      counts
      |> Enum.sort()
      |> Enum.map_join(", ", fn {kind, count} -> "#{count} #{kind}" end)

    Mix.shell().info("Seeded #{user.username}: #{summary}")
  end

  @doc "Seeds every app's data for the given user. Returns a count per kind."
  def seed(%User{} = user, opts \\ []) do
    tz = valid_tz(user.timezone)

    contacts = seed_contacts(user.id)
    events = seed_calendar(user.id, tz, contacts)
    notes = seed_notes(user.id)
    checklists = seed_checklists(user.id)
    trackers = seed_trackers(user.id)
    finance = seed_finance(user.id)
    invoices = seed_invoices(user.id)
    articles = seed_articles(user.id)
    files = seed_files(user.id)
    photos = seed_photos(user.id, Keyword.get(opts, :photos, 10))

    %{
      "contacts" => length(contacts),
      "events" => events,
      "notes" => notes,
      "checklists" => checklists,
      "trackers and logs" => trackers,
      "finance entries" => finance,
      "invoices" => invoices,
      "articles" => articles,
      "files" => files,
      "photos" => photos
    }
  end

  defp fetch_user!(nil) do
    case Repo.all(User) do
      [user | _rest] ->
        user

      [] ->
        {:ok, user} =
          Accounts.register_user(%{
            "username" => "demo",
            "password" => "demo1234",
            "display_name" => "Demo"
          })

        Mix.shell().info("Created user demo (password: demo1234)")
        user
    end
  end

  defp fetch_user!(username) do
    Repo.get_by(User, username: username) ||
      Mix.raise("no user named #{inspect(username)} in this database")
  end

  defp valid_tz(tz) when is_binary(tz) do
    case DateTime.now(tz) do
      {:ok, _now} -> tz
      _error -> "Etc/UTC"
    end
  end

  defp valid_tz(_tz), do: "Etc/UTC"

  # ----- Contacts -----

  @first_names ~w(Alice Bruno Camille David Emma Farid Gabrielle Hugo Ines Jules
                  Karim Lea Marc Nadia Oscar Paula Quentin Rosa Sami Theo)
  @last_names ~w(Martin Bernard Dubois Robert Petit Durand Leroy Moreau Simon
                 Laurent Girard Roux Fontaine Chevalier Gauthier)
  @orgs ["Acme", "CG Wire", "Mairie", "Studio 41", "Boulangerie Paul", nil, nil]
  @jobs ["CTO", "Designer", "Prof", "Medecin", "Artisan", nil, nil]
  @contact_tags ~w(famille travail sport voisins)

  defp seed_contacts(user_id) do
    last_names = Enum.take(Stream.cycle(Enum.shuffle(@last_names)), 18)

    contacts =
      for {first, last} <- Enum.zip(Enum.shuffle(@first_names), last_names) do
        name = "#{first} #{last}"
        org = pick(@orgs)
        job = if org, do: pick(@jobs)
        email = String.downcase("#{first}.#{last}@example.com")

        data = %{
          "display_name" => name,
          "org" => org,
          "title" => job,
          "emails" => [%{"value" => email, "type" => "home"}],
          "phones" => [
            %{"value" => "+336#{:rand.uniform(89_999_999) + 10_000_000}", "type" => "cell"}
          ],
          "birthday" => maybe(0.6, fn -> random_birthday() end),
          "note" => maybe(0.3, fn -> "Rencontre " <> pick(~w(meetup concert lycee travail)) end),
          "tags" => Enum.take_random(@contact_tags, :rand.uniform(3) - 1)
        }

        title = Enum.join(Enum.filter([name, org, job, email], & &1), " - ")

        {:ok, entry} =
          Data.create_entry(user_id, %{
            kind: "contact",
            source: "manual",
            title: title,
            data: data
          })

        entry
      end

    link_contacts(user_id, contacts)
    seed_birthday_prefs(user_id, contacts)
    contacts
  end

  defp random_birthday do
    year = 1955 + :rand.uniform(50)
    month = :rand.uniform(12)
    day = :rand.uniform(28)
    Date.to_iso8601(Date.new!(year, month, day))
  end

  # A few reciprocal relations so the graph screen has edges to draw.
  defp link_contacts(user_id, contacts) do
    contacts
    |> Enum.take(8)
    |> Enum.chunk_every(2, 2, :discard)
    |> Enum.each(fn [a, b] ->
      type = pick(~w(partner friend sibling colleague))
      add_relation(user_id, a, b.id, type)
      add_relation(user_id, b, a.id, type)
    end)
  end

  defp add_relation(user_id, contact, other_id, type) do
    relations = (contact.data["relations"] || []) ++ [%{"contact_id" => other_id, "type" => type}]
    data = Map.put(contact.data, "relations", relations)
    {:ok, _entry} = Data.update_entry(user_id, contact.id, %{data: data})
  end

  # Feeds the virtual Birthdays agenda of the calendar.
  defp seed_birthday_prefs(user_id, contacts) do
    ids = for c <- contacts, c.data["birthday"], do: c.id

    {:ok, _entry} =
      Data.create_entry(user_id, %{
        kind: "prefs",
        source: "contacts_app",
        title: "birthdays",
        data: %{"contact_ids" => Enum.take(ids, 6)}
      })
  end

  # ----- Calendar -----

  @event_titles [
    "Dentiste",
    "Reunion equipe",
    "Dejeuner",
    "Cours de guitare",
    "Garage",
    "Apero",
    "Kine",
    "Visio client",
    "Piscine",
    "Cinema",
    "Marche",
    "Coiffeur"
  ]

  defp seed_calendar(user_id, tz, contacts) do
    for {name, color} <- [{"Work", "#6c9bd0"}, {"Perso", "#e07c5a"}] do
      {:ok, _cal} =
        Data.create_entry(user_id, %{
          kind: "calendar",
          source: "calendar_app",
          title: name,
          data: %{"color" => color}
        })
    end

    events =
      for _i <- 1..30 do
        date = Date.add(Date.utc_today(), :rand.uniform(90) - 45)
        all_day = :rand.uniform(6) == 1
        title = pick(@event_titles)
        contact = maybe(0.2, fn -> pick(contacts) end)
        create_event(user_id, tz, title, date, all_day, contact, nil)
      end

    recurring =
      for {title, rec, offset} <- [{"Sport", "weekly", 2}, {"Loyer", "monthly", 5}] do
        date = Date.add(Date.utc_today(), offset)
        create_event(user_id, tz, title, date, false, nil, rec)
      end

    length(events) + length(recurring) + 2
  end

  defp create_event(user_id, tz, title, date, all_day, contact, recurrence) do
    hour = 8 + :rand.uniform(11)
    start_naive = NaiveDateTime.new!(date, Time.new!(hour, pick([0, 30]), 0))
    end_naive = NaiveDateTime.add(start_naive, :rand.uniform(2) * 3600, :second)

    {dtstart, dtend, occurred_at, end_at} =
      if all_day do
        stamp = Calendar.strftime(date, "%Y%m%d")

        {stamp, stamp, to_utc(NaiveDateTime.new!(date, ~T[00:00:00]), tz),
         to_utc(NaiveDateTime.new!(date, ~T[23:59:00]), tz)}
      else
        {Calendar.strftime(start_naive, "%Y%m%dT%H%M%S"),
         Calendar.strftime(end_naive, "%Y%m%dT%H%M%S"), to_utc(start_naive, tz),
         to_utc(end_naive, tz)}
      end

    data = %{
      "summary" => title,
      "dtstart" => dtstart,
      "dtend" => dtend,
      "end_at" => DateTime.to_iso8601(end_at),
      "all_day" => all_day,
      "location" =>
        maybe(0.3, fn -> pick(["Nantes", "12 rue Pasteur", "Visio", "Chez Marc"]) end),
      "calendar" => pick(["Work", "Perso", "Manual"]),
      "recurrence" => recurrence,
      "contact_name" => contact && contact.data["display_name"],
      "contact_id" => contact && contact.id
    }

    {:ok, entry} =
      Data.create_entry(user_id, %{
        kind: "event",
        source: "manual",
        title: title,
        occurred_at: occurred_at,
        data: data
      })

    entry
  end

  defp to_utc(naive, tz) do
    case DateTime.from_naive(naive, tz) do
      {:ok, dt} -> DateTime.shift_zone!(dt, "Etc/UTC")
      {:ambiguous, dt, _later} -> DateTime.shift_zone!(dt, "Etc/UTC")
      {:gap, dt, _after} -> DateTime.shift_zone!(dt, "Etc/UTC")
      _error -> DateTime.from_naive!(naive, "Etc/UTC")
    end
  end

  # ----- Notes -----

  @note_folders ["", "projets", "recettes", "lectures"]

  defp seed_notes(user_id) do
    titles = [
      "Idees servant",
      "Pain au levain",
      "Voyage Bretagne",
      "Budget maison",
      "Ratatouille",
      "Setup vim",
      "Livres 2026",
      "Jardin",
      "Guitare morceaux",
      "Velo entretien",
      "Cadeaux",
      "Domotique"
    ]

    for {title, i} <- Enum.with_index(titles) do
      linked = pick(titles -- [title])

      body = """
      Quelques notes sur #{String.downcase(title)}, voir aussi [[#{linked}]].

      - point #{i + 1} a creuser
      - #{pick(["a relire", "en cours", "fait", "abandonne"])}

      #{pick(~w(#idee #todo #perso #maison))}
      """

      {:ok, _note} =
        Notes.create_note(user_id, %{
          "title" => title,
          "folder" => pick(@note_folders),
          "body" => body
        })
    end

    length(titles)
  end

  # ----- Checklists -----

  defp seed_checklists(user_id) do
    lists = [
      {"Courses", "Maison", true,
       [item("Lait"), item("Oeufs"), sub("Bio"), item("Riz"), item("Lessive")]},
      {"Valise", "Voyages", true,
       [item("Passeports"), item("Chargeurs"), item("Trousse de toilette"), sub("Brosse a dents")]},
      {"Administratif", "", false,
       [
         item("Payer le loyer", due: Date.add(Date.utc_today(), 8)),
         item("Declaration impots", due: Date.add(Date.utc_today(), 25)),
         item("Rdv banque")
       ]},
      {"Routine matin", "", true, [item("Etirements"), item("Cafe"), item("Journal")]}
    ]

    for {title, folder, recurring, items} <- lists do
      {:ok, _list} =
        Data.create_entry(user_id, %{
          kind: "checklist",
          source: "manual",
          title: title,
          data: %{
            "folder" => folder,
            "recurring" => recurring,
            "show_on_dashboard" => title == "Routine matin",
            "items" => items
          }
        })
    end

    length(lists)
  end

  defp item(text, opts \\ []) do
    base = %{"text" => text, "done" => :rand.uniform(3) == 1}

    case opts[:due] do
      nil -> base
      due -> base |> Map.put("due", Date.to_iso8601(due)) |> Map.put("done", false)
    end
  end

  defp sub(text), do: Map.put(item(text), "indent", 1)

  # ----- Trackers -----

  defp seed_trackers(user_id) do
    trackers = [
      {"Guitare", %{"type" => "check", "unit" => nil}},
      {"Alcool", %{"type" => "count", "unit" => "doses"}},
      {"Poids", %{"type" => "value", "unit" => "kg"}},
      {"Depenses",
       %{
         "type" => "entry",
         "unit" => "EUR",
         "entry_kind" => "bank_tx",
         "agg" => "sum",
         "field" => "abs_amount"
       }}
    ]

    created =
      for {name, data} <- trackers do
        {:ok, tracker} =
          Data.create_entry(user_id, %{
            kind: "tracker",
            source: "trackers_app",
            title: name,
            data: data
          })

        {name, tracker}
      end

    by_name = Map.new(created)

    logs =
      log_days(user_id, by_name["Guitare"], fn -> if :rand.uniform(10) <= 6, do: 1 end) +
        log_days(user_id, by_name["Alcool"], fn -> maybe(0.4, fn -> :rand.uniform(3) end) end) +
        log_days(user_id, by_name["Poids"], fn ->
          maybe(0.3, fn -> 73.0 + :rand.uniform(30) / 10 end)
        end)

    length(trackers) + logs
  end

  defp log_days(user_id, tracker, value_fun) do
    days = for offset <- 0..120, value = value_fun.(), value != nil, do: {offset, value}

    for {offset, value} <- days do
      date = Date.add(Date.utc_today(), -offset)

      {:ok, _log} =
        Data.create_entry(user_id, %{
          kind: "tracker_log",
          source: "trackers_app",
          title: "#{tracker.title}: #{value}",
          occurred_at: DateTime.new!(date, ~T[12:00:00]),
          data: %{"tracker_id" => tracker.id, "value" => value}
        })
    end

    length(days)
  end

  # ----- Finance -----

  @spend [
    {"CARREFOUR MARKET", "courses", 15..90},
    {"BOULANGERIE", "courses", 2..8},
    {"SNCF", "transport", 15..60},
    {"TOTAL ENERGIE", "maison", 40..120},
    {"AMAZON", "achats", 10..80},
    {"RESTAURANT", "sorties", 20..70},
    {"PHARMACIE", "sante", 5..40},
    {"NETFLIX", "abonnements", 14..14}
  ]

  defp seed_finance(user_id) do
    {:ok, _checking} =
      Data.create_entry(user_id, %{
        kind: "account",
        source: "finance_app",
        title: "Compte courant",
        data: %{
          "type" => "bank",
          "currency" => "EUR",
          "identifier" => "Compte courant",
          "shared" => false
        }
      })

    {:ok, savings} =
      Data.create_entry(user_id, %{
        kind: "account",
        source: "finance_app",
        title: "Livret A",
        data: %{"type" => "livret", "currency" => "EUR", "shared" => false}
      })

    {:ok, wallet} =
      Data.create_entry(user_id, %{
        kind: "account",
        source: "finance_app",
        title: "BTC",
        data: %{"type" => "wallet", "currency" => "BTC"}
      })

    {:ok, _prefs} =
      Data.create_entry(user_id, %{
        kind: "prefs",
        source: "finance_app",
        title: "finance",
        data: %{
          "reference_currency" => "EUR",
          "rates" => %{"BTC" => 58_000},
          "tax_provision" => 0
        }
      })

    txs = seed_bank_txs(user_id, "Compte courant")
    snapshots = seed_balances(user_id, savings, wallet)
    3 + 1 + txs + snapshots
  end

  defp seed_bank_txs(user_id, account) do
    start = Date.add(Date.utc_today(), -420)

    {count, _balance} =
      Enum.reduce(0..420, {0, 1200.0}, fn offset, {count, balance} ->
        date = Date.add(start, offset)
        txs = day_txs(date)

        new_balance =
          Enum.reduce(txs, balance, fn {desc, category, amount}, acc ->
            acc = Float.round(acc + amount, 2)
            insert_tx(user_id, account, date, desc, category, amount, acc)
            acc
          end)

        {count + length(txs), new_balance}
      end)

    count
  end

  # Salary on the 2nd, rent on the 5th, a random slice of daily spending.
  defp day_txs(date) do
    fixed =
      case date.day do
        2 -> [{"VIREMENT SALAIRE", "salaire", 2500.0}]
        5 -> [{"LOYER AGENCE", "maison", -750.0}]
        _day -> []
      end

    spend =
      if :rand.uniform(10) <= 6 do
        {desc, category, range} = pick(@spend)
        [{desc, category, -Float.round(Enum.random(range) + :rand.uniform(99) / 100, 2)}]
      else
        []
      end

    fixed ++ spend
  end

  defp insert_tx(user_id, account, date, desc, category, amount, balance) do
    direction = if amount < 0, do: "sent", else: "received"
    verb = if amount < 0, do: "Paid", else: "Received"
    abs_amount = abs(amount)

    {:ok, _tx} =
      Data.create_entry(user_id, %{
        kind: "bank_tx",
        source: "bank_csv",
        external_id: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
        title: "#{verb} #{:erlang.float_to_binary(abs_amount, decimals: 2)} EUR - #{desc}",
        occurred_at: DateTime.new!(date, ~T[12:00:00]),
        data: %{
          "description" => desc,
          "amount" => amount,
          "abs_amount" => abs_amount,
          "currency" => "EUR",
          "direction" => direction,
          "balance" => balance,
          "account" => account,
          "category" => maybe(0.8, fn -> category end)
        },
        metadata: %{"import_source" => "seed"}
      })
  end

  defp seed_balances(user_id, savings, wallet) do
    months = 0..11

    for i <- months do
      date = Date.add(Date.utc_today(), -30 * i)
      amount = 8000 + (11 - i) * 150

      {:ok, _snap} =
        Data.create_entry(user_id, %{
          kind: "balance",
          source: "finance_app",
          title: "Livret A: #{amount} EUR",
          occurred_at: DateTime.new!(date, ~T[12:00:00]),
          data: %{"account_id" => savings.id, "amount" => amount, "currency" => "EUR"}
        })

      if rem(i, 2) == 0 do
        qty = Float.round(0.03 + (11 - i) * 0.002, 4)

        {:ok, _qty_snap} =
          Data.create_entry(user_id, %{
            kind: "balance",
            source: "finance_app",
            title: "BTC: #{qty}",
            occurred_at: DateTime.new!(date, ~T[12:00:00]),
            data: %{"account_id" => wallet.id, "amount" => qty, "currency" => "BTC"}
          })
      end
    end

    Enum.count(months) + Enum.count(months, &(rem(&1, 2) == 0))
  end

  # ----- Invoices (Files app, virtual Invoices folder) -----

  defp seed_invoices(user_id) do
    invoices =
      for i <- 0..5, provider <- ["ovh", "free"] do
        date = Date.add(Date.utc_today(), -30 * i - :rand.uniform(5))
        amount = Float.round(:rand.uniform(40) + :rand.uniform(99) / 100, 2)

        {:ok, _invoice} =
          Data.create_entry(user_id, %{
            kind: "invoice",
            source: provider,
            external_id: "seed-#{provider}-#{i}",
            title: "#{String.capitalize(provider)} - #{amount} EUR",
            occurred_at: DateTime.new!(date, ~T[00:00:00]),
            data: %{
              "provider" => provider,
              "amount" => amount,
              "currency" => "EUR",
              "status" => "paid",
              "url" => "https://example.com/#{provider}/invoice-#{i}.pdf"
            }
          })
      end

    length(invoices)
  end

  # ----- Articles (data browser / palette variety) -----

  defp seed_articles(user_id) do
    titles = [
      "Release notes 1.20",
      "SQLite internals",
      "Self-hosting in 2026",
      "Vue 3.6 preview",
      "Sourdough science",
      "E-bike maintenance"
    ]

    for {title, i} <- Enum.with_index(titles) do
      {:ok, _article} =
        Data.create_entry(user_id, %{
          kind: "article",
          source: "rss",
          external_id: "seed-article-#{i}",
          title: title,
          occurred_at: DateTime.add(DateTime.utc_now(), -:rand.uniform(30) * 86_400, :second),
          data: %{
            "link" => "https://example.com/articles/#{i}",
            "description" => "Seeded article."
          },
          metadata: %{"feed_url" => "https://example.com/feed.xml"}
        })
    end

    length(titles)
  end

  # ----- Files -----

  defp seed_files(user_id) do
    {:ok, folder} =
      Data.create_entry(user_id, %{
        kind: "file",
        source: "files_app",
        title: "Administratif",
        data: %{"filename" => "Administratif", "is_folder" => true, "parent_id" => nil}
      })

    files = [{"notes-reunion.md", nil}, {"bail.txt", folder.id}, {"todo-maison.txt", folder.id}]

    for {name, parent_id} <- files do
      content = "Fichier de demonstration genere par mix servant.seed (#{name}).\n"
      tmp = Path.join(System.tmp_dir!(), "seed-#{name}")
      File.write!(tmp, content)

      {:ok, relative, _absolute} =
        Storage.store_app_file(user_id, "files", tmp, ext: Path.extname(name))

      File.rm(tmp)

      {:ok, _file} =
        Data.create_entry(user_id, %{
          kind: "file",
          source: "files_app",
          title: name,
          data: %{
            "filename" => name,
            "size" => byte_size(content),
            "mime_type" => "text/plain",
            "path" => Storage.public_url(relative),
            "parent_id" => parent_id,
            "is_folder" => false
          }
        })
    end

    length(files) + 1
  end

  # ----- Photos -----

  @albums ["Camera", "Camera", "Vacances/Bretagne"]

  defp seed_photos(_user_id, count) when count <= 0, do: 0

  defp seed_photos(user_id, count) do
    for i <- 1..count do
      name = "seed-#{System.unique_integer([:positive])}-#{i}.jpg"
      tmp = noise_jpeg!(name)
      taken = DateTime.add(DateTime.utc_now(), -:rand.uniform(90) * 86_400, :second)
      segments = String.split(pick(@albums), "/") ++ [name]

      {:ok, _status, _entry} = PhotosDav.put_photo(user_id, [], segments, tmp, mtime: taken)
      File.rm(tmp)
    end

    count
  end

  # A colored-noise JPEG: three gaussian-noise bands joined into an sRGB image,
  # enough for real thumbnails without shipping fixture binaries.
  defp noise_jpeg!(name) do
    bands =
      for _band <- 1..3 do
        {:ok, band} =
          Vix.Vips.Operation.gaussnoise(320, 240,
            mean: 40.0 + :rand.uniform(160),
            sigma: 20.0 + :rand.uniform(40)
          )

        band
      end

    {:ok, joined} = Vix.Vips.Operation.bandjoin(bands)
    {:ok, cast} = Vix.Vips.Operation.cast(joined, :VIPS_FORMAT_UCHAR)
    {:ok, srgb} = Vix.Vips.Operation.copy(cast, interpretation: :VIPS_INTERPRETATION_sRGB)
    path = Path.join(System.tmp_dir!(), name)
    :ok = Vix.Vips.Image.write_to_file(srgb, path)
    path
  end

  # ----- Helpers -----

  defp pick(list), do: Enum.random(list)

  defp maybe(prob, fun) do
    if :rand.uniform() < prob, do: fun.()
  end
end
