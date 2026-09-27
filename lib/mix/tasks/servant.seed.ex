defmodule Mix.Tasks.Servant.Seed do
  @shortdoc "Fill the current dev database with random data"

  @moduledoc """
  Populates the database with random but plausible data for every app screen:
  contacts (birthdays, relations, tags), calendar agendas and events, notes
  with wikilinks, checklists, trackers with their logs, bank transactions with
  running balances, savings and crypto snapshots, invoices, files, generated
  landscape photos and agent memory files.

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
  alias Servant.AgentMemory
  alias Servant.Connectors.ConnectorConfig
  alias Servant.Connectors.SyncLog
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
    agent_memory = seed_agent_memory(user.id)
    connectors = seed_connectors(user.id)

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
      "photos" => photos,
      "agent memory files" => agent_memory,
      "connectors (with their commits and activities)" => connectors
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

  @first_names ~w(Alice Ben Chloe Daniel Emma Felix Grace Henry Isla Jack
                  Kate Liam Maya Noah Olivia Paul Quinn Rose Sam Tara)
  @last_names ~w(Adams Baker Carter Davis Evans Foster Green Hughes Irving
                 Jones King Lewis Morgan Nolan Parker)
  @orgs ["Acme", "Northwind", "City Hall", "Studio 41", "Corner Bakery", nil, nil]
  @jobs ["CTO", "Designer", "Teacher", "Doctor", "Carpenter", nil, nil]
  @contact_tags ~w(family work sport neighbors)

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
            %{"value" => "+1 555 01#{:rand.uniform(89) + 10}", "type" => "cell"}
          ],
          "birthday" => maybe(0.6, fn -> random_birthday() end),
          "note" =>
            maybe(0.3, fn -> "Met at a " <> pick(~w(meetup concert conference party)) end),
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

  # A small connected network so the graph screen has something to lay out:
  # a family, a work team, a sports triangle, bridged by a few friendships.
  # Pairs index into the contact list; each relation is written both ways.
  @relation_edges [
    {0, 1, "partner"},
    {0, 2, "sibling"},
    {1, 3, "friend"},
    {2, 4, "friend"},
    {4, 5, "colleague"},
    {4, 6, "colleague"},
    {5, 6, "colleague"},
    {6, 7, "friend"},
    {3, 8, "friend"},
    {8, 9, "friend"},
    {9, 10, "friend"},
    {10, 8, "friend"},
    {11, 5, "colleague"}
  ]

  defp link_contacts(user_id, contacts) do
    by_index = contacts |> Enum.with_index() |> Map.new(fn {contact, i} -> {i, contact} end)

    @relation_edges
    |> Enum.filter(fn {a, b, _type} -> by_index[a] && by_index[b] end)
    |> Enum.flat_map(fn {a, b, type} ->
      [{by_index[a], by_index[b].id, type}, {by_index[b], by_index[a].id, type}]
    end)
    |> Enum.group_by(fn {contact, _other, _type} -> contact end)
    # One write per contact: the struct in hand is the pre-link version, so
    # writing relation by relation would keep only the last one.
    |> Enum.each(fn {contact, links} ->
      relations =
        for {_contact, other_id, type} <- links, do: %{"contact_id" => other_id, "type" => type}

      data = Map.put(contact.data, "relations", relations)
      {:ok, _entry} = Data.update_entry(user_id, contact.id, %{data: data})
    end)
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
    "Dentist",
    "Team meeting",
    "Lunch",
    "Guitar lesson",
    "Car service",
    "Drinks",
    "Physio",
    "Client call",
    "Swimming",
    "Movie night",
    "Farmers market",
    "Haircut"
  ]

  defp seed_calendar(user_id, tz, contacts) do
    for {name, color} <- [{"Work", "#6c9bd0"}, {"Personal", "#e07c5a"}] do
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
      for {title, rec, offset} <- [{"Running club", "weekly", 2}, {"Rent", "monthly", 5}] do
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
        maybe(0.3, fn -> pick(["Downtown", "12 Baker Street", "Video call", "Liam's place"]) end),
      "calendar" => pick(["Work", "Personal", "Manual"]),
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

  @note_folders ["", "projects", "recipes", "reading"]

  defp seed_notes(user_id) do
    titles = [
      "Servant ideas",
      "Sourdough bread",
      "Brittany trip",
      "Home budget",
      "Ratatouille",
      "Vim setup",
      "Books 2026",
      "Garden",
      "Guitar songs",
      "Bike maintenance",
      "Gift ideas",
      "Home automation"
    ]

    for {title, i} <- Enum.with_index(titles) do
      linked = pick(titles -- [title])

      body = """
      A few notes on #{String.downcase(title)}, see also [[#{linked}]].

      - point #{i + 1} to dig into
      - #{pick(["to review", "in progress", "done", "dropped"])}

      #{pick(~w(#idea #todo #personal #home))}
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
      {"Groceries", "Home", true,
       [item("Milk"), item("Eggs"), sub("Free range"), item("Rice"), item("Laundry detergent")]},
      {"Packing list", "Travel", true,
       [item("Passports"), item("Chargers"), item("Toiletry bag"), sub("Toothbrush")]},
      {"Paperwork", "", false,
       [
         item("Pay the rent", due: Date.add(Date.utc_today(), 8)),
         item("Tax return", due: Date.add(Date.utc_today(), 25)),
         item("Bank appointment")
       ]},
      {"Morning routine", "", true, [item("Stretching"), item("Coffee"), item("Journal")]}
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
            "show_on_dashboard" => title == "Morning routine",
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
      {"Guitar practice", %{"type" => "check", "unit" => nil}},
      {"Coffee", %{"type" => "count", "unit" => "cups"}},
      {"Weight", %{"type" => "value", "unit" => "kg"}},
      {"Spending",
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
      log_days(user_id, by_name["Guitar practice"], fn -> if :rand.uniform(10) <= 6, do: 1 end) +
        log_days(user_id, by_name["Coffee"], fn -> maybe(0.8, fn -> :rand.uniform(3) end) end) +
        log_days(user_id, by_name["Weight"], fn ->
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
    {"WHOLE FOODS", "groceries", 15..90},
    {"CORNER BAKERY", "groceries", 2..8},
    {"RAIL TICKETS", "transport", 15..60},
    {"CITY POWER", "home", 40..120},
    {"AMAZON", "shopping", 10..80},
    {"RESTAURANT", "dining", 20..70},
    {"PHARMACY", "health", 5..40},
    {"NETFLIX", "subscriptions", 14..14}
  ]

  defp seed_finance(user_id) do
    {:ok, _checking} =
      Data.create_entry(user_id, %{
        kind: "account",
        source: "finance_app",
        title: "Checking account",
        data: %{
          "type" => "bank",
          "currency" => "EUR",
          "identifier" => "Checking account",
          "shared" => false
        }
      })

    {:ok, savings} =
      Data.create_entry(user_id, %{
        kind: "account",
        source: "finance_app",
        title: "Savings",
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

    txs = seed_bank_txs(user_id, "Checking account")
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
        2 -> [{"SALARY ACME", "salary", 2500.0}]
        5 -> [{"RENT", "home", -750.0}]
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
          title: "Savings: #{amount} EUR",
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
      for i <- 0..11, provider <- ["ovh"] do
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

  # ----- Connectors -----

  # Enabled but on demand: the workers start and show as healthy, yet never
  # sync on their own, so the fake credentials below never reach a real API.
  # The entries they "imported" (articles, bank transactions, invoices) come
  # from the sections above; commits and activities are seeded here.
  @connector_specs [
    {"rss", "Tech news", %{"url" => "https://example.com/feed.xml"}},
    {"bank_csv", "Checking account",
     %{"preset" => "generic", "account_name" => "Checking account"}},
    {"ovh", "OVH invoices",
     %{
       "application_key" => "seed-app-key",
       "application_secret" => "seed-app-secret",
       "consumer_key" => "seed-consumer-key"
     }},
    {"github", "GitHub", %{"token" => "seed-token", "username" => "demo"}},
    {"strava", "Strava",
     %{
       "client_id" => "seed-client",
       "client_secret" => "seed-secret",
       "refresh_token" => "seed-refresh"
     }},
    {"ical", "Team calendar",
     %{"url" => "https://example.com/team.ics", "calendar_name" => "Team"}}
  ]

  defp seed_connectors(user_id) do
    for {type, name, config} <- @connector_specs do
      last_sync = DateTime.add(DateTime.utc_now(:second), -:rand.uniform(50) * 60, :second)

      connector =
        %ConnectorConfig{user_id: user_id}
        |> ConnectorConfig.changeset(%{
          connector_type: type,
          name: name,
          enabled: true,
          schedule: "on_demand",
          config: config,
          last_synced_at: last_sync
        })
        |> Repo.insert!()

      seed_sync_logs(connector, last_sync)
    end

    length(@connector_specs) + seed_commits(user_id) + seed_activities(user_id)
  end

  # A week of runs, newest first; one transient failure keeps the log honest.
  defp seed_sync_logs(connector, last_sync) do
    for day <- 0..6 do
      started = DateTime.add(last_sync, -day * 86_400, :second)
      failed = day == 4 and connector.connector_type == "strava"

      %SyncLog{}
      |> SyncLog.changeset(%{
        connector_config_id: connector.id,
        status: if(failed, do: "failed", else: "completed"),
        entries_count: if(failed, do: 0, else: :rand.uniform(12)),
        error: if(failed, do: "Rate limit exceeded, retrying later"),
        started_at: started,
        finished_at: DateTime.add(started, 2 + :rand.uniform(20), :second)
      })
      |> Repo.insert!()
    end
  end

  @commit_messages [
    "Add weather widget to the dashboard",
    "Fix timezone offset in the planting calendar",
    "Refactor the sowing schedule parser",
    "Bump dependencies",
    "Document the API rate limits",
    "Add frost alerts",
    "Speed up the plant search",
    "Handle empty harvest logs"
  ]

  defp seed_commits(user_id) do
    for {message, i} <- Enum.with_index(@commit_messages) do
      repo = pick(["demo/garden-planner", "demo/recipes-api"])
      sha = Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
      at = DateTime.add(DateTime.utc_now(:second), -(i * 26 + :rand.uniform(20)) * 3600, :second)

      {:ok, _commit} =
        Data.create_entry(user_id, %{
          kind: "commit",
          source: "github",
          external_id: sha,
          title: "#{repo} - #{message}",
          occurred_at: at,
          data: %{
            "repo" => repo,
            "sha" => sha,
            "message" => message,
            "html_url" => "https://github.com/#{repo}/commit/#{sha}",
            "author_name" => "Demo",
            "authored_at" => DateTime.to_iso8601(at)
          }
        })
    end

    length(@commit_messages)
  end

  @activities [
    {"Morning run", "Run", 8_200, 2_700},
    {"Lunch ride", "Ride", 24_500, 3_600},
    {"Evening run", "Run", 5_400, 1_800},
    {"Hill repeats", "Run", 10_100, 3_500},
    {"Sunday long ride", "Ride", 62_000, 9_000},
    {"Recovery swim", "Swim", 1_500, 2_100}
  ]

  defp seed_activities(user_id) do
    for {{name, sport, meters, seconds}, i} <- Enum.with_index(@activities) do
      at = DateTime.add(DateTime.utc_now(:second), -(i * 2 + 1) * 86_400, :second)

      {:ok, _activity} =
        Data.create_entry(user_id, %{
          kind: "activity",
          source: "strava",
          external_id: "seed-activity-#{i}",
          title: name,
          occurred_at: at,
          data: %{
            "sport_type" => sport,
            "distance" => meters,
            "distance_km" => Float.round(meters / 1000, 2),
            "moving_time" => seconds,
            "elapsed_time" => seconds + 120,
            "total_elevation_gain" => :rand.uniform(400),
            "average_speed" => Float.round(meters / seconds, 2)
          }
        })
    end

    length(@activities)
  end

  # ----- Agent memory -----

  @agent_files [
    {"memory/garden-planner/MEMORY.md",
     "# Memory index\n\n- [Stack](stack.md) - Phoenix API + Vue SPA, SQLite\n" <>
       "- [Release habits](release-habits.md) - small commits, deploy on Fridays\n"},
    {"memory/garden-planner/stack.md",
     "---\nname: stack\ndescription: tech stack of the garden planner\n---\n\n" <>
       "Phoenix JSON API, Vue 3 SPA, SQLite. Weather comes from Open-Meteo.\n"},
    {"memory/garden-planner/release-habits.md",
     "---\nname: release-habits\ndescription: how releases go\n---\n\n" <>
       "One logical commit per change. **Why:** easy reverts.\n"},
    {"memory/recipes-api/MEMORY.md", "# Memory index\n\n- [API style](api-style.md)\n"},
    {"memory/recipes-api/api-style.md",
     "---\nname: api-style\ndescription: JSON conventions\n---\n\n" <>
       "snake_case keys, ISO 8601 dates, errors as {error: message}.\n"},
    {"skills/claude/changelog/SKILL.md",
     "---\nname: changelog\ndescription: Draft a changelog from git history\n---\n\n" <>
       "# Changelog\n\nGroup commits by theme since the last tag, one line each.\n"},
    {"skills/shared/code-review/SKILL.md",
     "---\nname: code-review\ndescription: Review the current diff\n---\n\n" <>
       "# Code review\n\nCorrectness first, then naming, then tests.\n"},
    {"rules/garden-planner/style.mdc",
     "---\ndescription: Code style\nalwaysApply: true\n---\n\n" <>
       "Prefer small functions and explicit names.\n"}
  ]

  defp seed_agent_memory(user_id) do
    files = for {path, body} <- @agent_files, do: %{"path" => path, "body" => body}
    {:ok, entries} = AgentMemory.upsert_all(user_id, files)
    length(entries)
  end

  # ----- Files -----

  defp seed_files(user_id) do
    {:ok, folder} =
      Data.create_entry(user_id, %{
        kind: "file",
        source: "files_app",
        title: "Paperwork",
        data: %{"filename" => "Paperwork", "is_folder" => true, "parent_id" => nil}
      })

    files = [
      {"meeting-notes.md", nil},
      {"lease.txt", folder.id},
      {"home-todo.txt", folder.id}
    ]

    for {name, parent_id} <- files do
      content = "Demo file generated by mix servant.seed (#{name}).\n"
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

  @albums ["Camera", "Camera", "Holidays/Brittany"]

  @photo_scenes [
    {"sunset", "big-sur"},
    {"sunset", "cornwall"},
    {"day", "yosemite"},
    {"day", "tuscany"},
    {"night", "lofoten"},
    {"snow", "alps"},
    {"sea", "brittany"},
    {"sea", "algarve"}
  ]

  # Sky gradient top/bottom, sun or moon, far and near hills, sea (or nil).
  @scene_palettes %{
    "sunset" => {"#2b1b4a", "#ff9a5a", "#ffe2a8", "#7a4a6e", "#3b2a44", nil},
    "day" => {"#3d8bd9", "#bfe3ff", "#fff8d6", "#7fae8a", "#3d6b4f", nil},
    "night" => {"#070b1f", "#24305e", "#e8ecff", "#1c2442", "#0e1428", nil},
    "snow" => {"#8fb8de", "#eef5fb", "#fffbe8", "#c9d6e3", "#f4f7fa", nil},
    "sea" => {"#4a90c8", "#d6ecf7", "#fff6d8", "#8aa9a0", "#c9b48a", "#2f6f9f"}
  }

  defp seed_photos(_user_id, count) when count <= 0, do: 0

  defp seed_photos(user_id, count) do
    for i <- 1..count do
      {scene, place} = pick(@photo_scenes)
      name = "#{place}-#{scene}-#{i}.jpg"
      tmp = landscape_jpeg!(name, scene)
      taken = DateTime.add(DateTime.utc_now(), -:rand.uniform(90) * 86_400, :second)
      segments = String.split(pick(@albums), "/") ++ [name]

      {:ok, _status, _entry} = PhotosDav.put_photo(user_id, [], segments, tmp, mtime: taken)
      File.rm(tmp)
    end

    count
  end

  # A stylized landscape rendered from SVG by libvips: random hills and sun
  # position, so the seeded gallery looks like photos without fixture files.
  defp landscape_jpeg!(name, scene) do
    {sky_top, sky_bottom, sun, far, near, sea} = @scene_palettes[scene]
    sun_x = 120 + :rand.uniform(400)
    sun_y = 90 + :rand.uniform(110)
    far_y = 250 + :rand.uniform(40)
    near_y = 320 + :rand.uniform(40)

    sea_layer =
      if sea, do: ~s(<rect y="#{near_y - 20}" width="640" height="200" fill="#{sea}"/>), else: ""

    svg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="640" height="480">
      <defs><linearGradient id="sky" x1="0" y1="0" x2="0" y2="1">
        <stop offset="0" stop-color="#{sky_top}"/><stop offset="1" stop-color="#{sky_bottom}"/>
      </linearGradient></defs>
      <rect width="640" height="480" fill="url(#sky)"/>
      <circle cx="#{sun_x}" cy="#{sun_y}" r="#{28 + :rand.uniform(30)}" fill="#{sun}" opacity="0.9"/>
      <path d="M0 #{far_y} Q#{80 + :rand.uniform(160)} #{far_y - 90} 320 #{far_y - 10} T640 #{far_y - 30} V480 H0Z" fill="#{far}"/>
      #{sea_layer}
      <path d="M0 #{near_y + 40} Q#{:rand.uniform(200)} #{near_y - 40} #{260 + :rand.uniform(120)} #{near_y + 10} T640 #{near_y + 60} V480 H0Z" fill="#{near}"/>
    </svg>
    """

    {:ok, image} = Vix.Vips.Image.new_from_buffer(svg)
    {:ok, flat} = Vix.Vips.Operation.flatten(image)
    path = Path.join(System.tmp_dir!(), name)
    :ok = Vix.Vips.Image.write_to_file(flat, path)
    path
  end

  # ----- Helpers -----

  defp pick(list), do: Enum.random(list)

  defp maybe(prob, fun) do
    if :rand.uniform() < prob, do: fun.()
  end
end
