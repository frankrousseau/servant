# Audit de code - Servant

**Date :** 2026-07-16
**Périmètre :** dépôt complet `servant` (backend Phoenix/Elixir + frontend Vue 3 SPA)
**Contexte :** second audit complet; le précédent date du 2026-06-22 (`.audit/code-audit-2026-06-22.md`).
Depuis : ~25 commits de features (photos + reconnaissance faciale, CalDAV/CardDAV, trackers,
connecteurs GitHub/Invoice Collector, date picker, apps installables, audit sécurité de juillet).

> Audit en lecture seule. Aucune modification du code source. Ce fichier est le livrable.
> Exécuté en 8 phases x 2 passes (Backend puis Frontend), suivi d'une synthèse transversale.

Repères taille : 103 fichiers `.ex` dans `lib/`, 60 fichiers de test ExUnit,
33 composants Vue, 43 modules TS, 21 fichiers de test Vitest.

---

# Synthèse transversale

## Résumé exécutif

Servant est en **bien meilleure santé qu'en juin** : l'audit précédent avait révélé des trous béants (fichiers servis sans auth, export de toute la base, secrets en clair, temps réel cassé) ; **tous les critiques et hauts de juin sont fermés**, avec preuve à l'appui. L'isolation multi-utilisateur, cœur de la promesse, est désormais solide et testée en profondeur, sans IDOR ni injection SQL/commande. Le code est idiomatiquement propre (aucune violation des règles Elixir d'AGENTS.md, simplifications `ponytail:` toutes sous leur plafond).

Le thème dominant de ce nouvel audit n'est plus la faille béante mais **la défaillance silencieuse** : le système échoue sans le dire. Côté backend, plusieurs connecteurs perdent leur état ou avalent des erreurs (refresh token Strava perdu sur échec, comptes bancaires amputés en silence, superviseur qui peut s'effondrer sans redémarrer les workers). Côté frontend, l'infra de report d'erreur existe mais n'est branchée qu'aux uploads, donc la majorité des échecs disparaissent dans la console navigateur. À cela s'ajoutent une **XSS stockée réelle** (URL de facture), des **CVE de dépendances backend** corrigeables par simple montée de version, et une **couverture de tests en trompe-l'œil** (le critique est bien testé, mais tout ce qui a été ajouté récemment, ainsi que l'infra front, ne l'est pas).

## Top priorités (à traiter en premier)

| # | Sévérité | Constat | Où | Pourquoi |
|---|---|---|---|---|
| 1 | Haute | XSS stockée : URL de facture rendue sans `safeUrl` | Front phase 4 #2 (`FilesApp.vue:790,229`) | `javascript:` scrapé d'un portail → exécution avec session complète, au clic |
| 2 | Haute | CVE backend (plug retiré, phoenix, req/mint) | Phase 7 #1-4 | DoS exploitables sur des libs exposées aux données externes ; `mix deps.update` |
| 3 | Haute | Refresh token Strava perdu sur sync en échec | Back phase 2 #1 (`worker.ex:113`) | Un échec réseau + redéploiement casse le connecteur jusqu'à re-saisie manuelle |
| 4 | Haute | Superviseur connecteurs peut s'effondrer sans relance | Back phase 2 #4 (`connectors.ex:153`) | 3 crashs en 5 s → tous les connecteurs de tous les users s'arrêtent en silence |
| 5 | Haute | Zombies node/Chromium du scraper + clause `{:exit,_}` non gérée | Back phase 2 #2 (`invoice_scraper:135`) | Un Playwright bloqué sature la RAM du conteneur ; crash du worker |
| 6 | Haute | Enable Banking avale les erreurs par compte | Back phase 2 #3 (`enable_banking:90`) | Suivi de finances amputé d'un compte pendant des mois, "completed" affiché |
| 7 | Haute | Note créable via `POST /api/entries` (garde manquante) | Back phase 2 #2 / phase 8 #3 (`data.ex:142`) | Court-circuite le graphe de notes, contredit la promesse OpenAPI |
| 8 | Haute | Index SQLite manquant + recherche `LIKE` sur tout le JSON | Back phase 5 #1-2 (`data.ex:312`) | Timeline et palette scannent des dizaines de Mo à chaque interaction, croît avec l'historique |
| 9 | Haute | Docs onboarding + Dockerfile faux (risque perte de données) | Phase 8 #1-2 | `./bin/dev` inexistant ; Dockerfile de la doc met `FILES_DIR` dans la release (effacé au redéploiement) |
| 10 | Haute | Trous de tests sur tout ce qui est récent | Back phase 3 #1-5, Front phase 3 #1-6 | Cycle de vie connecteurs, planification, If-Match DAV, pagination apps, clustering faces : régressions invisibles |
| 11 | Haute | Accessibilité clavier + absence d'i18n | Front phase 6 #4,5,7 | Divs-boutons inactivables au clavier, modales sans focus-trap, UI 100% anglaise pour un user FR |

## Quick wins (immédiat, faible effort)

- **`rm erl_crash.dump`** (contient `secret_key_base` + un refresh_token) et l'ajouter à `.dockerignore` (sécurité N6).
- **`mix deps.update plug phoenix req`** ferme les trois CVE hautes du backend (phase 7 #1-3).
- **`config :bcrypt_elixir, log_rounds: 1` en test** : divise la durée de la suite (45 s → quelques s) sans rien changer (back phase 3 #11).
- **Router l'URL de facture par `safeUrl`** : deux lignes, ferme la XSS (front phase 4 #2).
- **Ajouter `delete_public_path(display_path)`** dans `delete_entry_file/2` : une photo supprimée cesse de laisser son plein format sur disque (back phase 2 #5).
- **Enregistrer `app.config.errorHandler` + `unhandledrejection`** dans `main.ts` : rend diagnosticables tous les échecs front aujourd'hui muets (front phase 2 #1).
- **Supprimer `Process.alive?`** (worker_test.exs:112) et les 3 modules `hyperevm/` morts (back phase 1 #9).

## Thèmes récurrents (à corriger structurellement, pas au cas par cas)

1. **Défaillance silencieuse** : persister les curseurs aussi en branche erreur, propager les erreurs partielles, brancher le report d'erreur front partout, superviser en `rest_for_one`.
2. **Fraîcheur des données** : l'upsert `on_conflict: :nothing` n'est jamais rafraîchi (back phase 1 #1), le temps réel ne couvre que 2 vues sur 8 (front phase 1 #1) : les données amont modifiées restent périmées.
3. **Le récent n'est pas testé** : tout ce qui a été ajouté depuis juin (connecteurs, DAV, faces, pagination apps) manque de filet ; y remédier avant d'en ajouter.
4. **Croissance non bornée** : `sync_logs` jamais purgé, grilles/listes non virtualisées, requêtes non paginées en mémoire (export, mentions, DAV) : ça tient à petite échelle, pas au-delà.

---

# PASSE BACKEND

## Phase 1 : Architecture

### Carte du backend

103 fichiers `.ex`, 13 656 lignes dans `lib/`. Organisation en deux espaces classiques Phoenix : `lib/servant` (domaine) et `lib/servant_web` (web, JSON uniquement, pas de LiveView). La structure observée correspond à ce que décrivent CLAUDE.md/AGENTS.md/DEVELOPMENT.md ; seul l'arbre de DEVELOPMENT.md est en retard sur le code (il omet `apps.ex`, `api_tokens/`, `audit/`, `caldav/`, `carddav/`, `dav.ex`, `http.ex`, `auth/throttle.ex`).

#### Supervision OTP (`lib/servant/application.ex`)
Arbre plat `one_for_one` : Telemetry, Repo (SQLite), `Ecto.Migrator` (migrations au boot en release), `Phoenix.PubSub`, `Registry` `Servant.Connectors.Registry` (clé `{user_id, config_id}`), `DynamicSupervisor` `Servant.Connectors.Supervisor`, `Connectors.Scheduler` (démarre les workers actifs au boot + purge quotidienne de `connector_environments`), `Audit.LogBuffer` (ring buffers accès/erreurs), `Auth.Throttle` (ETS anti-brute-force), Endpoint, plus `Media.Backfill.child_specs()` (Task.Supervisor + Registry single-flight par user). Un handler logger miroir les erreurs vers le buffer d'audit.

#### Contexts métier (`lib/servant/`)
| Module | Rôle |
|---|---|
| `Data` (352) + `Data.Entry` | Conteneur universel : CRUD scopé `user_id`, filtres/pagination/stats/agrégats, `create_entries/2` bulk (insert_all par lots de 500, upsert `:nothing` sur `(user_id, source, external_id)`), broadcast PubSub |
| `Notes` (476) + `NoteLink` | Notes = entries `kind:"note"`; parsing wikilinks/mentions/tags, table `note_links`, propagation de renommage façon Obsidian |
| `Accounts` (155) + `User` | Register (1er compte = admin), bcrypt, TOTP (secret chiffré, anti-replay), `token_version` pour invalidation globale |
| `ApiTokens` + `Scopes` | Tokens `srv_` hashés SHA-256, scopes `app:<domaine>:<r/w>` + `data:*` + `data:read-binary`; `Scopes` = source unique du mapping kind vers domaine |
| `Connectors` (389) + `ConnectorConfig`/`SyncLog`/`ConnectorEnvironment`/`Worker`/`Scheduler` | Registre de 15 types, cycle de vie des workers, import de fichiers, redaction des secrets, persistance des curseurs, cache partagé d'env (tokens Strava) |
| `Apps` (240) + `UserApp` | Apps git : clone https `--depth 1`, validation manifeste (`servant-app.json`, ids réservés, `Path.safe_relative` sur l'entry), fichiers sous `FILES_DIR/<user>/installed_apps/` |
| `Storage` (257) | Layout disque par user, garde anti-traversal (`path_safe?`), résolution des chemins legacy, propriété par user |
| `Media.*` | `Thumbnail` (vix/libvips, backfill paginé keyset), `PhotoEdit` (rotation), `Exif`, `VideoMeta`, `Backfill` (single-flight) |
| `CalDAV`/`CardDAV`/`Dav` + `CalDAV.ICS` (356)/`CardDAV.VCard` (164) | Accès données DAV (filtrage en mémoire sur `Data.all_entries`), codecs iCal/vCard avec round-trip du payload brut, ETag/CTag |
| `Events`, `Encrypted(.Map)`, `HTTP`, `Util`, `Audit`, `Auth.Throttle` | PubSub `"data:<user_id>"`, AES-256-GCM, defaults Req + garde SSRF, helpers, sondes /proc + ring buffers, throttle ETS |

#### Connecteurs (15 types, 24 fichiers)
Behaviour `Servant.Connectors.Connector` (id/name/kind/required_credentials/init/sync + optionnels supported_schedules/default_schedule/persisted_config, defaults via `__using__`). Famille EVM factorisée par la macro `EVMConnector` (arbitrum/base/ethereum/hyperevm = modules de 15 lignes) sur `EVM.{Explorer, TransactionParser, ENS}` partagés. Solana avec `Solana.{RPC, TransactionParser, TokenMetadata}`. Autres : `enable_banking` (430, JWT RS256 maison + flux de consentement PSD2 piloté par le controller), `bank_csv` (+ parser 365), `invoice_scraper` (Node/Playwright via Task avec timeout), `strava` (refresh OAuth via ConnectorEnvironment), `github`, `gitlab`, `rss`, `ical`, `vcard`, `apple_health` (+ xml_parser). Quatre types importables par fichier (`@importable_types`). Le contrat est suivi uniformément : curseurs incrémentaux persistés via `persisted_config/1`, erreurs `{:error, reason, state}`, entries en maps à clés strings.

#### Web (`lib/servant_web/`)
- **Auth** : `ServantWeb.Auth` (Bearer ou cookie HttpOnly `_servant_auth`; tokens `srv_` avec throttle par IP; `token_version` vérifié), plugs `DavAuth` (Basic, token en mot de passe), `FileAuth` (cookie ou scope `data:read-binary`), `Scope`, `SessionOnly`, `RequireAdmin`, `AccessLog`.
- **Controllers** (14) : auth (631), dav (577), entry (556), connector (484), upload (238), app (200), notes (185), export (146), files, api_token, audit, client_error, spa, error_json. Tous les controllers `/api` portent des annotations OpenApiSpex (spec générée du router, servie sur `/api/openapi.json`).
- **Channels** : `UserSocket` (même chemin d'auth que HTTP) + `DataChannel` (join `data:<user_id>` vérifié, push `entry_change`/`entries_changed`).
- **Router** : `/api` (openapi, public auth, `:auth`, sous-scope `:session_only`, sous-scope `:admin`), `/dav/*` (match toutes méthodes), `/files|/uploads` (FileAuth), catch-all SPA. Endpoint : RemoteIp, parsers JSON+multipart sans `:urlencoded` (anti login-CSRF documenté).

#### Flux critiques
1. **Auth** : login (throttle par username, bcrypt) -> ticket TOTP éventuel -> `Phoenix.Token` signé `{user_id, token_version}` + cookie HttpOnly; chaque requête passe par `ServantWeb.Auth`; socket réutilise `authenticate_token`.
2. **Création d'entry** : `EntryController.create` -> check scope kind -> `Data.create_entry` -> insert + `Events.broadcast` -> `DataChannel`. Aucun accès `Repo` direct dans la couche web (vérifié par grep) : le layering controller vers context est respecté partout.
3. **Sync connecteur** : Scheduler au boot -> `start_all_enabled` -> Worker (`restart: :transient`, relit la config en DB à l'init pour ne pas perdre le curseur) -> timer selon schedule (plancher 5 s pour `continuous`) -> `module.sync(state)` dans le process du worker -> `Data.create_entries` (upsert `:nothing`) -> sync_log + persistance curseur (transaction read-merge-write) + broadcast agrégé.
4. **Upload** : scope photos/files -> taille/type -> `Storage.store_app_file` -> EXIF/date vidéo -> thumbnail + display JPEG (photos); l'entry est créée ensuite par le client.
5. **Requête DAV** : Basic auth -> dispatch méthode -> scopes par sous-arbre -> contexts CalDAV/CardDAV (filtrage en mémoire) -> codecs ICS/VCard avec round-trip du payload brut, préconditions ETag.
6. **Install d'app** : session-only -> clone https -> validation manifeste (id regex + réservés, entry `.js` committé, `Path.safe_relative`) -> copie sous FILES_DIR -> servie via `/files` (cookie).

#### Points chauds
Top 15 (wc -l) : auth_controller 631, dav_controller 577, entry_controller 556, connector_controller 484, notes.ex 476, enable_banking_connector 430, connectors.ex 389, bank_csv/parser 365, caldav/ics 356, data.ex 352, vcard_connector 297, solana_connector 296, invoice_scraper 284, github_connector 280, strava_connector 268. Les gros controllers sont gonflés surtout par les blocs `operation(...)` OpenAPI, pas par la logique. Modules les plus couplés (fan-in) : `Servant.Data` (controllers, CalDAV, CardDAV, Worker, PhotoEdit, export), `Servant.Storage` (upload, data, apps, media, accounts, connecteurs), `Servant.Connectors` (controller, worker, scheduler, strava).

### Findings

#### 1. [HAUTE] Les syncs connecteurs sont insert-only : les modifications amont ne se propagent jamais
`lib/servant/data.ex:183` : `create_entries/2` insère avec `on_conflict: :nothing`, et rien ne supprime ni ne remplace les entries d'une source lors d'un re-sync. Un événement déplacé dans un flux iCal, un contact corrigé dans une source vCard ou un commit amendé gardent donc pour toujours leur première version dans Servant (même `external_id`, données ignorées). Le constat est aggravé par une doc interne fausse : `lib/servant/caldav.ex:6` et `lib/servant/carddav.ex:5` justifient l'exclusion DAV des sources connecteurs par "their syncs wholesale-replace entries", ce que le code ne fait pas. Pour un hub de données personnelles, la fraîcheur silencieusement cassée est le pire mode de défaillance. Correction : pour les connecteurs à contenu mutable (ical, vcard au minimum), passer à `on_conflict: {:replace, [:title, :occurred_at, :data, :metadata, :updated_at]}` (option par connecteur, ex. callback `upsert_strategy/0`), et corriger les moduledocs CalDAV/CardDAV.

#### 2. [HAUTE] Le contournement du context Notes est bloqué en update mais pas en create
`lib/servant/data.ex:230` protège `update_entry` (`{:error, :notes_api_required}`), mais `create_entry` (`lib/servant/data.ex:142`) accepte `kind: "note", source: "notes"` sans garde, alors que la doc de l'endpoint promet le contraire (`lib/servant_web/controllers/entry_controller.ex:405` : "Notes cannot be created here (use /api/notes)"). Une note créée par `POST /api/entries` échappe à `Servant.Notes` : pas de `note_links`, pas de slug `external_id` (donc invisible ou incohérente dans l'arbre, unicité de titre non vérifiée), pas de propagation. Correction : dans `Data.create_entry`, refuser `kind == "note"` (miroir exact de la garde d'update), et couvrir aussi `create_entries` par principe.

#### 3. [HAUTE] `verify: false` systématique sur les URLs fournies par l'utilisateur, en contradiction avec la politique TLS du projet
`lib/servant/http.ex:8-11` pose la règle : vérification TLS par défaut, `verify: false` réservé à des hôtes précis touchés par la régression OTP 27, "never globally". Or les trois connecteurs qui fetchent des URLs arbitraires la désactivent en dur pour toutes les requêtes : `lib/servant/connectors/rss_connector.ex:73`, `lib/servant/connectors/ical_connector.ex:104`, `lib/servant/connectors/vcard_connector.ex:69`. La garde SSRF (`ensure_public_url`) est bien appliquée, mais tout feed RSS/iCal/vCard est exposé au MITM, et la politique documentée et son implémentation ont divergé. Correction : vérifier par défaut et ne retomber en `verify: false` que sur échec `key_usage_mismatch` (retry ciblé), ou en faire une option de config par connecteur, explicite et visible. À creuser en phase sécurité.

#### 4. [MOYENNE] Modifier une config connecteur n'a aucun effet sur un worker en cours d'exécution
`lib/servant/connectors.ex:57` (`update_connector_config`) écrit en DB seulement; le worker fige config et schedule à l'init (`lib/servant/connectors/worker.ex:55-60`) et ne relit jamais rien ensuite. Changer une URL de flux, un token, le schedule ou `enabled: false` via `PUT /api/connectors/:id` (`lib/servant_web/controllers/connector_controller.ex:111`) reste donc sans effet jusqu'à un stop/start manuel; seul le flux Enable Banking redémarre explicitement le worker (`connector_controller.ex:316-317`), preuve que le besoin est connu. C'est un piège silencieux pour l'utilisateur (l'API répond 200, rien ne change). Correction : dans `update_connector_config`, si un worker tourne (`Registry.lookup`), le redémarrer (et démarrer/arrêter selon la nouvelle valeur d'`enabled`), en réutilisant la mécanique d'eb_exchange.

#### 5. [MOYENNE] DAV : collections rechargées entières en mémoire, avec N+1 par requête
Toute la couche DAV repose sur `Data.all_entries` puis filtrage Elixir : `lib/servant/caldav.ex:31-38` (`events/2` recharge tous les événements du user à chaque appel), `caldav.ex:50` (`get_event` idem). Conséquences dans le controller : un PROPFIND Depth:1 sur le home calendrier recharge tous les événements une fois par calendrier (`lib/servant_web/controllers/dav_controller.ex:102-105` + `calendar_props` qui rappelle `CalDAV.events` en :459 pour le ctag), et un REPORT multiget de N hrefs fait N rechargements complets (`dav_controller.ex:212-216`). Les clients DAV (iOS, DAVx5) pollent le ctag en continu : coût O(calendriers x événements) par poll, croissant avec l'historique. Correction : charger `exposed_events(user_id)` une fois par requête dans le controller et le passer aux fonctions CalDAV (les signatures s'y prêtent), ou pousser le filtre `data.calendar`/`filename` en SQL (`json_extract`). Même schéma côté CardDAV.

#### 6. [MOYENNE] Trois implémentations iCal qui divergent sur la sémantique des fuseaux
Le parsing/génération iCal existe en trois exemplaires : `lib/servant/caldav/ics.ex` (parse + génération, gestion TZID/all-day rigoureuse), `lib/servant/connectors/ical_connector.ex:114-221` (parser maison distinct), `lib/servant_web/controllers/export_controller.ex:68-146` (génération VCALENDAR + `ical_escape` recopiant `ICS.escape` de `ics.ex:119`). Divergence de comportement réelle : une heure flottante `20260713T100000` est ancrée dans le fuseau de l'utilisateur côté CalDAV (`ics.ex:143-148`) mais traitée comme UTC côté connecteur (`ical_connector.ex:193-195`), donc le même flux importé et le même événement lu par DAV n'ont pas la même heure. À noter en contre-exemple : le côté vCard est bien factorisé (`CardDAV.VCard` réutilise `VCardConnector.parse_vcards`, `carddav/vcard.ex:18`). Correction : extraire un module `Servant.ICal` (unfold/escape/parse datetime/génération VEVENT) utilisé par les trois, et aligner la règle des heures flottantes; déplacer au passage la génération iCal hors du controller d'export.

#### 7. [MOYENNE] Le format d'erreur JSON réel ne correspond pas au schéma OpenAPI déclaré
`lib/servant_web/schemas/error.ex:21` déclare `required: [:error]`, mais : les 404 issus des `get_*!` qui raisent rendent `%{errors: %{detail: "Not Found"}}` via `lib/servant_web/controllers/error_json.ex:18-20` (sans clé `error`), alors que ces réponses sont documentées `Schemas.Error` (ex. `entry_controller.ex:387`); les fallbacks de l'AuthController rendent aussi `%{errors: %{detail: ...}}` (`auth_controller.ex:86`, `:182`); les 422 changeset rendent `%{errors: %{champ: [...]}}` sans `error`. Trois formes coexistent donc pour le front et les clients API, et deux d'entre elles violent le schéma publié. Correction : soit retirer `required: [:error]` et documenter les variantes (schémas `Error` vs `ValidationError`), soit normaliser : ajouter des clauses `render("404.json")`/`render("500.json")` dans ErrorJSON renvoyant `%{error: ...}` et aligner les deux fallbacks d'auth.

#### 8. [MOYENNE] Sync GitHub non bornée dans le process du worker : un arrêt en plein backfill perd tout le travail
`lib/servant/connectors/worker.ex:98-99` exécute `sync/1` dans le GenServer lui-même; le connecteur GitHub y déroule tout l'historique en une seule sync (fenêtres successives, `Process.sleep` de 2,1 s par page et attentes rate-limit jusqu'à 90 s, `github_connector.ex:117-139`), assumé par le moduledoc ("a single (slow) sync"). Mais le curseur n'atteint la DB qu'après la fin complète de la sync (`worker.ex:105-108`) : un `stop_connector` (kill par le DynamicSupervisor après 5 s), un redéploiement ou un crash en plein backfill de plusieurs heures perd toute la progression et rejouera tout le quota API. Solana a le garde-fou nommé (`@max_tx_per_sync 50`, `solana_connector.ex:23-26`); GitHub n'a pas d'équivalent. Correction minimale : persister le curseur à chaque fenêtre (callback déjà disponible via `Connectors.persist_connector_cursor`, appelable depuis `fetch_all_commits`), ou borner le nombre de fenêtres par sync comme Solana.

#### 9. [BASSE] Code mort : les trois modules `hyperevm/` ne sont plus référencés
`lib/servant/connectors/hyperevm/explorer.ex` et `hyperevm/transaction_parser.ex` sont des délégations "kept for backward compatibility" que plus rien n'appelle (grep lib/ + test/ : zéro référence), et `hyperevm/rpc.ex` (82 lignes) n'a aucun call site non plus depuis que `HyperEVMConnector` passe par la macro `EVMConnector`. Correction : supprimer les trois fichiers.

#### 10. [BASSE] Le behaviour Connector impose trois callbacks que rien ne consomme
`lib/servant/connectors/connector.ex:12-15` : `name/0`, `kind/0` et `required_credentials/0` sont implémentés par les 15 connecteurs mais n'ont aucun consommateur runtime (seuls des tests tautologiques les vérifient; `id/0` ne sert qu'à une ligne de log, `worker.ex:90`). Le moduledoc admet déjà que `required_credentials/0` est "advisory... does not gate anything today". C'est du contrat mort qui alourdit chaque nouveau connecteur et laisse croire à une validation qui n'existe pas. Correction : supprimer les trois callbacks (ou les brancher réellement : exposer name/kind côté API et valider `required_credentials` dans `Connectors.start_connector`).

#### 11. [BASSE] Payload JSON utilisateur dupliqué quatre fois dans AuthController avec des ensembles de champs qui divergent
`lib/servant_web/controllers/auth_controller.ex:62-69` (register), `:198-206` (issue_session), `:444-457` (me), `:518-529` (update_profile) : quatre maps construites à la main; register/login omettent `timezone`/`enabled_apps`, me ajoute `totp_enabled`/`admin`/`inserted_at`, update_profile en omet une partie. Tout champ ajouté au profil devra être reporté à la main aux quatre endroits (l'oubli est déjà visible entre register et me). Correction : un helper `user_json(user, :session | :full)` unique dans le controller (même patron que `Entry.to_json/1`).

#### 12. [BASSE] Accès config incohérent dans trois connecteurs : `Map.get` direct au lieu de `config_value/2`
Le behaviour fournit `config_value/2,3` précisément pour absorber clés string (DB) et atomes (tests) (`connector.ex:47-53`), et la plupart des connecteurs l'utilisent. Exceptions : `ical_connector.ex:27` (`calendar_name`), `vcard_connector.ex:30` (`source_name`), `solana_connector.ex:59-61` (`rpc_url`, `min_sol_amount`, `last_signature`). Le mélange des deux styles dans un même `init/2` (ex. solana lit `wallet_address` via `config_value` mais `last_signature` via `Map.get`) est un piège pour le prochain connecteur écrit par imitation. Correction : uniformiser sur `config_value`.

### Seam front-back (bref)

- **Enveloppes** : `%{data: ...}` (+ `meta` paginée sur l'index des entries) est la norme, respectée par entries/notes/connectors/apps/tokens. Écarts assumés : auth (`token`/`user` à plat), upload (réponse à plat), actions de statut (`%{status: ...}`). Cohérent dans l'ensemble; le vrai point de friction est le triple format d'erreur (finding 7).
- **Nommage des routes** : REST via `resources` partout, deux écarts : `POST /apps/:id/update` (`router.ex:87`) là où `PUT /apps/:id` serait attendu, et les sous-routes d'action type `POST /connectors/:id/sync` (acceptable, style RPC homogène).
- **OpenAPI vs router** : la spec est générée depuis le router (`Paths.from_router`, `api_spec.ex:30`) et tous les controllers `/api` portent des `operation(...)`, donc pas de dérive structurelle possible sur `/api`. Hors spec, volontairement : `/dav`, `/files`, catch-all SPA (documentés dans `docs/dav.md`). Les descriptions d'opérations portent les contraintes de scope, y compris `data:read-binary`. La seule inexactitude relevée est le schéma d'erreur (finding 7) et la promesse non tenue "Notes cannot be created here" (finding 2).

## Phase 2 : Bugs de correction et observabilité

### Sévérité haute

#### 1. [HAUTE] Un refresh token Strava tourné n'est jamais persisté quand le sync échoue ensuite
`lib/servant/connectors/worker.ex:113-117` (avec `strava_connector.ex:139-148`). Le connecteur thread l'état à travers `sync/1` pour ne pas perdre un `refresh_token` tourné, mais le Worker ne persiste `persisted_config/1` que dans la branche succès de `run_sync/2`. Dans la branche `{:error, reason, new_connector_state}`, le nouvel état (token tourné) ne vit qu'en mémoire du GenServer. Scénario : le refresh tourne le token (l'ancien devient invalide), puis `fetch_all_activities` échoue (429, réseau) ; la DB garde l'ancien token ; un redémarrage avant le prochain sync réussi relit l'ancien token → "invalid grant", connecteur cassé jusqu'à re-saisie manuelle. Correction : persister aussi dans la branche erreur, ou immédiatement au moment de la rotation dans `refresh_access_token`.

#### 2. [HAUTE] Timeout du scraper = processus node/Chromium zombie, et clause `{:exit, _}` non gérée
`lib/servant/connectors/invoice_scraper_connector.ex:135-157`. `Task.shutdown` tue le process Elixir propriétaire du port (donc ferme le port) mais pas le processus OS : `System.cmd` ne termine jamais le programme externe. Un Playwright suspendu survit au timeout de 90 s avec tout son Chromium (centaines de Mo). Chaque sync `every_day` laisse un couple node+Chromium orphelin → RAM du conteneur saturée en une semaine. Bug secondaire : `Task.yield/2` peut retourner `{:exit, reason}` non matché par le `case` (ligne 144) → `CaseClauseError`, crash du Worker, sync_log bloqué en "running". Correction : superviser le process OS (MuonTrap/erlexec) ou wrapper shell qui tue son fils sur EOF stdin ; ajouter la clause `{:exit, reason}`.

#### 3. [HAUTE] Enable Banking : les échecs par compte sont avalés dès qu'un autre compte a renvoyé des données
`lib/servant/connectors/enable_banking_connector.ex:90-113`. `sync_accounts` accumule les erreurs par compte mais ne les remonte que si `entries == []`. Dès qu'un compte renvoie une transaction, le sync retourne `{:ok, ...}` : sync_log "completed", `config.error` remis à nil, aucune trace des comptes en échec (et quand toutes échouent, seule la dernière `[reason | _]` est gardée). Scénario : consentement PSD2 partiellement révoqué sur le compte B (403), le compte A continue ; l'utilisateur voit "completed" pendant des mois, son suivi est amputé des transactions de B sans aucune alerte. Correction : propager les erreurs partielles (statut "completed_with_errors" ou `Enum.join(errors, "; ")` dans `config.error`).

#### 4. [HAUTE] Échecs de démarrage silencieux et effondrement non rattrapé du DynamicSupervisor
`lib/servant/connectors.ex:153-160` (avec `application.ex:17-19`, `scheduler.ex:26-38`). (a) `start_all_enabled` fait `Enum.each` en ignorant le retour de `start_connector` : un worker dont `init/1` renvoie `{:stop, reason}` meurt au boot sans log, sans `config.error`, sans sync_log (connecteur "enabled" mais mort). (b) Le Worker `:transient` est redémarré, mais si l'intensité de restart du `Servant.Connectors.Supervisor` (3 en 5 s) est dépassée, le DynamicSupervisor meurt ; le racine `one_for_one` le relance vide, et comme `start_all_enabled` ne tourne qu'au boot, plus aucun worker n'est relancé jusqu'au redémarrage complet. Scénario : 3 connecteurs `every_hour` lèvent `insert_all` (NOT NULL) en < 5 s → le superviseur tombe → tous les connecteurs de tous les users cessent de syncer, silencieusement. Correction : loguer chaque échec de `start_connector` (+ `config.error`) ; superviser DynamicSupervisor + Scheduler en `rest_for_one` pour que la mort du premier relance `start_all_enabled`.

### Sévérité moyenne

#### 5. [MOYENNE] La suppression d'une entrée n'efface pas `display_path` : le JPEG plein format survit
`lib/servant/data.ex:260-266`. `delete_entry_file/2` supprime `data["path"]` et `data["thumb_path"]` mais pas `data["display_path"]`, alors que l'upload photo génère systématiquement un display JPEG 1920px (`upload_controller.ex:208-211`). Une photo "supprimée" reste lisible via `/files/..._display.jpg` et présente dans les backups (fuite disque + surprise vie privée). Correction : ajouter `delete_public_path(user_id, data["display_path"])` (+ balayage one-shot des `_display.jpg` orphelins).

#### 6. [MOYENNE] `reconcile_inbound` s'approprie les liens à titre ambigu, contredisant `resolve_targets`
`lib/servant/notes.ex:288-291`. `resolve_targets` ne résout un lien `[[titre]]` nu que si exactement une note porte ce titre, mais `reconcile_inbound` fait un `update_all` inconditionnel : tout `note_link` dont `target_path` figure dans les clés de la note écrite est repointé, y compris la clé titre nu. Scénario : "a/Foo" existe, `[[Foo]]` résout vers elle ; création de "b/Foo" → le lien repointe vers b/Foo ; puis chaque édition rebascule le backlink vers la dernière note écrite. Correction : exclure la clé titre nu quand plusieurs notes du user la partagent (réutiliser la vérification d'unicité de `resolve_targets`).

#### 7. [MOYENNE] sync_log figé en "running" après un crash, et table `sync_logs` jamais purgée
`lib/servant/connectors/worker.ex:98-119` et `connectors.ex:196-224`. `run_sync` n'a aucun rescue : si `sync/1` ou `create_entries` lève, le Worker crashe et le sync_log reste "running" pour toujours (incident indiagnosticable). Aucune purge de `sync_logs` (la purge quotidienne ne concerne que `connector_environments`) : un schedule "continuous" (plancher 5 s) crée ~17 000 lignes/jour. Correction : try/rescue autour de `run_sync` appelant `fail_sync_log` avant re-raise (ou marquer "failed" les "running" au démarrage) ; purge périodique (N jours ou N lignes/config).

#### 8. [MOYENNE, observabilité] Logs d'erreur de sync sans aucun contexte
`lib/servant/connectors/worker.ex:114` et `:124`. `Logger.error("Connector sync error: #{inspect(reason)}")` ne contient ni user_id, ni config_id, ni type. Avec plusieurs workers concurrents, l'onglet erreurs de l'Audit affiche "Connector sync error: :timeout" sans savoir quel connecteur de quel user. Correction : inclure `id/config_id/user_id`, ou `Logger.metadata` posées dans `do_sync`.

#### 9. [MOYENNE, observabilité] Le backfill média est totalement muet
`lib/servant/media/backfill.ex:31-36` et `thumbnail.ex:115-123`. `backfill_missing/1` retourne des `{:ok, id}`/`{:error, id, reason}` que `run/1` jette : aucun log, aucun compteur. Une photo qui échoue (HEIC exotique, corrompu) échoue identiquement et silencieusement à chaque relance. Aussi : `running?/1` reste faux entre `start/1` et l'enregistrement Registry fait dans la task (affichage "en cours" ment juste après lancement). Correction : loguer un résumé `ok=N failed=M` + un warning par échec ; stocker le dernier résultat quelque part d'interrogeable.

#### 10. [MOYENNE] Préconditions PUT DAV évaluées sur une autre ressource que celle réellement écrite
`lib/servant_web/controllers/dav_controller.ex:292-336` et `caldav.ex:97-102`. `upsert/3` vérifie `If-None-Match`/`If-Match` contre `get_event(u.id, cal, name)` (scoped calendrier), mais `put_event` re-résout sa cible par filename puis par UID sur TOUS les calendriers (`resolve_target`) : les deux peuvent désigner des entrées différentes. Scénario : PUT "nouveau" (If-None-Match: *) dans le calendrier B avec un UID déjà présent dans A → précondition passe (rien dans B), mais `put_event` écrase l'événement de A et le déplace dans B, sans 412. Même asymétrie côté CardDAV (`carddav.ex:67-72`). Correction : résoudre la cible une fois dans le contrôleur et l'utiliser pour la précondition, ou restreindre le match UID au même calendrier sauf sans précondition.

### Sévérité basse

#### 11. [BASSE] Fichiers orphelins si la mise à jour de l'entrée échoue après rotation
`lib/servant/media/photo_edit.ex:36-43`. Si `Data.update_entry` échoue (changeset, SQLITE_BUSY), le nouvel original tourné + thumb/display restent sur disque sans référence. Correction : supprimer `absolute` et les dérivés dans la branche erreur.

#### 12. [BASSE] Matchs non exhaustifs sur `read_body` et sur le delete (DAV)
`dav_controller.ex:204`, `:229`, `:313`, `:361`. `{:ok, body, conn} = read_body(conn)` : un corps > 8 Mo retourne `{:more, ...}` → MatchError 500 au lieu de 413 (REPORT multiget massif, vCard avec photo). Ligne 361, `{:ok, _} = delete_fun.(entry)` : un échec DB devient un 500 brut. Le contrôleur DAV n'émettant aucun log applicatif, un client mobile qui boucle sur un 400/500 est indiagnosticable. Correction : gérer `{:more, _, conn}` (411/413), matcher l'échec du delete, loguer en warning les PUT rejetés.

#### 13. [BASSE] Ordre des remplacements dans `unescape/1` (vCard) corrompt les backslashes échappés
`lib/servant/connectors/vcard_connector.ex:221-227`. `unescape` remplace `\n` avant `\\` : la séquence `\\n` (backslash littéral + n) devient un saut de ligne. Le codec ICS le fait correctement avec un placeholder traité en premier. Ce parseur étant réutilisé par CardDAV (`carddav/vcard.ex:18`), la corruption touche les contacts synchronisés du téléphone (champ NOTE avec chemins Windows). Correction : aligner sur ICS (neutraliser `\\` en premier via placeholder).

#### 14. [BASSE] Anti-replay TOTP non atomique
`lib/servant/accounts.ex:140-152`. `verify_totp` lit `totp_last_used_at` sur la struct puis l'écrit après validation : deux requêtes concurrentes avec le même code lisent le même `since`, passent toutes deux `NimbleTOTP.valid?`, le code est accepté deux fois. Fenêtre 30 s, exploitable seulement si un code a fuité, mais la garantie annoncée n'est pas tenue sous concurrence. Correction : update conditionnel via `Repo.update_all ... WHERE totp_last_used_at IS NULL OR = ancienne_valeur` et vérifier le nombre de lignes.

#### 15. [BASSE, observabilité] Le canal d'erreurs client peut noyer le ring buffer d'audit et crashe sur un message non-string
`lib/servant_web/controllers/client_error_controller.ex:41-52`. Tout user authentifié peut appeler l'endpoint en boucle (aucun rate limit) : 500 requêtes évincent les vraies erreurs serveur du `LogBuffer` (cap 500), l'outil même de la page Audit. Et `truncate/1` fait `to_string(value)` : un JSON `{"message": {"a": 1}}` lève `Protocol.UndefinedError` (500). Correction : rate-limit par user (le Throttle existant convient), garde `is_binary/1` avec `inspect/1` en repli.

## Phase 3 : Tests et couverture

### État des lieux

- `mix test` : **473 tests, 0 échec**, 47,5 s (1,8 s async / 45,7 s sync), seed aléatoire, aucun warning de compilation. Seul bruit : un `Logger.error` attendu ("Connector sync error: :sync_failed") émis par un test du Worker.
- `mix test --cover` : **65,66 % de couverture totale**, sous le seuil par défaut de 90 % (aucun workflow CI dans le repo n'impose ce seuil).
- Répartition : 60 fichiers de test ; 322 tests de contextes (dont 187 sur les connecteurs, majoritairement des parseurs purs) et 151 tests web.
- Modules à 0 % : `Connectors.EVM.*`, `EVMConnector`, `Ethereum/ArbitrumConnector`, `HyperEVM.RPC/Explorer`, `Solana.RPC/TokenMetadata`, `Media.Exif`, `Release`, `ConnectorEnvironment`. Points bas : `UserSocket` 14 %, `ConnectorController` 30 %, `Thumbnail` 27 %, `StravaConnector` 17 %, `Scheduler` 62 %, `Connectors` (contexte) 60 %.

Points forts réels : l'isolation entre utilisateurs est testée systématiquement et en profondeur (entries, notes, fichiers, tokens, DAV, connecteurs) ; le flux auth complet (login, TOTP anti-rejeu, `token_version`, throttle 429, cookie HttpOnly) est couvert avec ses cas d'erreur ; les scopes API tokens sont testés endpoint par endpoint. SSRF, traversée de chemin, redaction des secrets et chiffrement au repos ont chacun leurs tests. Les règles AGENTS.md (`start_supervised!`, `:sys.get_state`, monitor + DOWN) sont presque partout respectées.

### Findings

#### 1. [HAUTE] L'authentification du socket n'est jamais exercée
`lib/servant_web/channels/user_socket.ex:9-19` (14 %). `connect/3` porte la propriété "a revoked token can't open a socket", mais `data_channel_test.exs:17-21` construit le socket via `Phoenix.ChannelTest.socket/3` en contournant `connect/3`. Une régression où `authenticate_token` deviendrait une simple vérification de signature (sans check `token_version`) passerait la CI : un token révoqué continuerait de recevoir les broadcasts. Test à écrire : `connect(UserSocket, %{"token" => token})` valide (succès), sans token (`:error`), puis après `bump_token_version/1` (`:error`).

#### 2. [HAUTE] Le cycle de vie des connecteurs via l'API est presque entièrement non testé
`lib/servant_web/controllers/connector_controller.ex:80-465` (30 %). Seuls `show`/`update` et deux cas de scoping sont couverts. `create`, `delete`, `sync`, `start`, `stop`, `eb_auth_url`/`eb_exchange`, `logs`, `schedules` n'ont aucun test HTTP. Bug qui passerait : un `delete` qui supprime la ligne sans stopper le Worker (sync fantôme continuant d'écrire), ou un `sync` qui renvoie 500 sur un connecteur arrêté. Test : cycle complet via l'API (POST crée+démarre, POST /sync, GET /logs, DELETE puis `sync_now == {:error, :not_running}`).

#### 3. [HAUTE] La planification périodique n'a aucun filet
`lib/servant/connectors/worker.ex:136-147` + `connector_config.ex:35-41`. Tous les tests Worker utilisent `schedule: "on_demand"` ; `arm_timer/1` pour "continuous" et intervalles, et `schedule_interval_ms/1` (20 %), ne sont jamais exécutés. Le catch-all `schedule_interval_ms(_), do: :timer.hours(1)` masquerait une typo de schedule. Surtout : si la branche erreur de `run_sync` (worker.ex:113-117) perdait son `schedule_sync`, un connecteur planifié s'arrêterait définitivement après son premier échec, CI verte. Tests : unitaires sur `schedule_interval_ms/1`, et un Worker "every_hour" dont `timer_ref` est ré-armé après sync réussi ET après sync en échec (`:sys.get_state`).

#### 4. [HAUTE] Redémarrage au boot et environnement partagé non testés
`lib/servant/connectors/scheduler.ex:26-49` + `connectors.ex:153-160, 340-392`. `start_all_enabled/0`, `get_env`/`put_env` (sessions partagées EnableBanking) et `cleanup_expired_env/0` (purge quotidienne) n'ont aucun test. Régression invisible : après un déploiement, aucun connecteur enabled ne redémarre, ou l'env partagé expiré n'est plus purgé (secrets périmés servis indéfiniment). Tests : deux configs (enabled/disabled), `start_all_enabled()`, seul l'enabled répond à `sync_now` ; `put_env` avec `expires_at` passé puis `cleanup_expired_env()` → `get_env` nil.

#### 5. [HAUTE] La précondition If-Match n'est jamais testée
`lib/servant_web/controllers/dav_controller.ex:369-377`. Les tests CalDAV couvrent `If-None-Match: *` mais aucun ne pose `If-Match` : les branches `["*"]` et `[tag]` de `etag_matches?/2` (PUT :319, DELETE :360) sont mortes en test. C'est la protection contre l'écrasement concurrent téléphone/app : si `etag_matches?` régressait en "toujours vrai", un client périmé écraserait silencieusement événements/contacts (perte de données). Test : PUT initial, récupérer l'ETag, PUT `If-Match: <etag>` (204), PUT et DELETE `If-Match: "stale"` (412, ressource intacte).

#### 6. [MOYENNE] Le pipeline photo n'a aucun test qui puisse échouer
`test/servant/media/thumbnail_test.exs:20-27` + `lib/servant/media/exif.ex` (0 %). Le seul test de génération accepte `:error` comme valide (`case ... :error -> IO.puts("Skipping...")`) : si libvips casse ou si `Thumbnail.generate` régresse en `:error` constant, le test reste vert. `Exif.extract` (upload_controller.ex:96, datation photos) n'est jamais exécuté. Régression invisible : toutes les photos uploadées sans vignette ni `occurred_at`. Test : uploader une vraie fixture JPEG avec EXIF `DateTimeOriginal`, asserter `thumb_path`/`display_path`/date ; tag `@tag :vips` exclu explicitement plutôt qu'un `case` silencieux.

#### 7. [MOYENNE] Le chemin git réel de l'installation d'apps n'est pas exercé
`lib/servant/apps.ex:170-182`. `install_from_dir` est bien testé, mais `git_clone` et `update_from_git` (au-delà de `:not_found`) n'ont aucun test : une régression dans `System.cmd("git", ...)` (args, suppression du `.git`, message tronqué) passerait. Suggestion : test taggé `:tmp_dir` clonant un bare repo local créé dans le test, plus un `update_from_git` de bout en bout.

#### 8. [MOYENNE] Les flux HTTP et le refresh de tokens des connecteurs OAuth sont sans filet
`strava_connector.ex` (17 %), `enable_banking_connector.ex` (39 %), `gitlab_connector.ex` (32 %), `github_connector.ex` (45 %). Les 187 tests connecteurs couvrent surtout les parseurs purs ; la rotation du refresh_token Strava, la pagination GitHub/GitLab et les erreurs d'API ne sont pas simulées. Régression invisible : un refresh_token rotationné non re-persisté rend le connecteur mort à l'expiration, sans échec de test. Suggestion : `Req.Test` (déjà dans le projet) pour simuler happy path + 401 de refresh sur au moins un connecteur OAuth.

#### 9. [MOYENNE] `update_avatar/2` n'a aucun test
`lib/servant/accounts.ex:50-68` (Accounts à 67 %). Ni le mapping content-type→extension, ni `Storage.store_account_avatar`, ni la mise à jour de l'URL ne sont couverts. Un content-type non listé retombe sur ".jpg" : un SVG uploadé serait stocké puis servi (vecteur XSS potentiel avec le serving `/files`) qu'aucun test ne surveille. Test : upload PNG (URL + fichier), upload d'un type exotique (vérifier rejet ou extension neutre).

#### 10. [BASSE] `Process.alive?/1` contrevient aux règles du projet
`test/servant/connectors/worker_test.exs:112`. AGENTS.md l'interdit ; le `:sys.get_state(pid)` de la ligne 110 prouve déjà la survie du worker. Assertion redondante à supprimer.

#### 11. [BASSE] bcrypt à plein coût en test (47 s pour 473 tests)
`config/test.exs`. Aucun `config :bcrypt_elixir, log_rounds: 1` : chaque `user_fixture` paie un hash complet (~100-300 ms), l'essentiel des 45,7 s sync. La ligne standard Phoenix diviserait la durée par un facteur important sans changer les assertions. Même esprit : le setup FILES_DIR (mkdir + put_env + on_exit) est copié-collé dans 6 fichiers, à extraire en helper `ConnCase`.

#### 12. [BASSE] Les tests TOTP dépendent de l'horloge réelle
`test/servant_web/controllers/auth_controller_test.exs:239-241, 260-263, 296-305`. Le code minté par `NimbleTOTP.verification_code(secret)` est vérifié quelques ms plus tard ; si la fenêtre de 30 s bascule entre les deux, flake (et `verify_totp` à `accounts.ex:143` n'accepte pas la période précédente, pas de grâce). Suggestion : `time:` explicite des deux côtés en test ; noter que l'absence de fenêtre de grâce est aussi un irritant produit (code saisi seconde 29 refusé).

### Synthèse des trous par flux critique

| Flux | Couverture | Verdict |
|---|---|---|
| Auth + TOTP + token_version | Profonde | OK, sauf socket (finding 1) |
| Scoping user des entries | Profonde | OK |
| Scopes API tokens | Profonde | OK |
| Sync worker / scheduler / curseurs | Happy path on_demand seulement | Findings 2, 3, 4 |
| Notes wikilinks / renommage | Excellente | OK |
| DAV protocole + préconditions | Bonne, sauf If-Match | Finding 5 |
| Upload + storage + thumbnails | Storage OK ; pipeline image non déterministe | Finding 6 |
| Install apps git | Validation OK ; clone réel non exercé | Finding 7 |
| Export | JSON + ICS échappé, scoping | OK |
| Audit / throttle | Couverts | OK |

## Phase 4 : Sécurité

### Verdict sur les correctifs de juin

| Problème de juin | Statut | Preuve dans le code actuel |
|---|---|---|
| `/files/` servi sans authentification (IDOR) | Corrigé | `/files` et `/uploads` passent par le pipeline `:file_auth` (`router.ex:138-143`) puis `FilesController.show` qui scope via `Storage.resolve_owned_path/2` (`files_controller.ex:13-17`, `storage.ex:134-159`). `Plug.Static` ne sert plus que `static_paths()` (`endpoint.ex:33-41`, `servant_web.ex:21`). Auth cookie OU token `srv_` avec scope `data:read-binary` (`file_auth.ex:16-51`). |
| `/export/database` exporte toute la base | Corrigé | Endpoint disparu. Reste `GET /export/entries` (JSON scopé `Data.all_entries(user_id)`, `export_controller.ex:26-27`) et `.ics`. Aucun `send_file` de la base SQLite dans `lib/`. |
| Canal temps réel cassé (UUID→int, événements, auth.user) | Corrigé | `data_channel.ex:9-17` compare les chaînes directement, émet `"entry_change"`. Socket réhydrate l'user via `authenticate_token` (`user_socket.ex:12`). |
| Secrets connecteurs en clair en base | Corrigé | Champ `config` chiffré AES-256-GCM (`connector_config.ex:16` → `Servant.Encrypted.Map`). |
| `config_json/1` renvoie les secrets à l'API | Corrigé | Passe par `Connectors.redact_config/1` (masque password/secret/token/…, `connector_controller.ex:476`, `connectors.ex:53-102`). |
| TLS désactivé globalement (`verify_none`) | Corrigé (partiel) | Défaut = `verify_peer` + CAStore (`http.ex:19-27`). `verify: false` limité à rss/ical/vcard (voir N3). |
| Identifiants invoice_scraper en arguments CLI | Corrigé | Secrets via `env:`, seul `--provider` sur la ligne de commande (`invoice_scraper_connector.ex:114-128`). |
| SSRF via URLs de connecteurs | Corrigé (partiel) | `ensure_public_url/1` bloque loopback/privé/link-local dont `169.254.169.254` (`http.ex:47-98`), appliqué à rss/ical/vcard. Angles morts : DNS rebinding (N2), git clone (N1). |
| `path_safe?` faible (juste `..`) | Corrigé | `Path.expand` + préfixe sous `files_root()` (`storage.ex:243-247`), double garde dans `resolve_owned_path` (`storage.ex:139-154`). |
| Pas de limitation de débit ni inscription restreinte | Corrigé (partiel) | Throttle ETS par IP/username sur login/totp/tokens (`throttle.ex`, `auth.ex:85-100`). `REGISTRATION_ENABLED`. Rate-limit global absent (backlog) + lockout par username (N5). |
| Salts/clé en dur (dev) | Corrigé (non urgent) | Prod lit `SECRET_KEY_BASE`/`CONNECTOR_ENCRYPTION_KEY` de l'env (`runtime.exs:28-59`). Salts dev committés = sans impact prod. |
| (Front) Pas de CSP + token en localStorage | Corrigé côté backend | CSP prod stricte sur l'HTML SPA (`spa_controller.ex:13-27`), token en cookie HttpOnly SameSite=Lax (`auth.ex:25-32`), HSTS + `Secure` via `force_ssl` (`prod.exs:6-13`). |

Bilan : tous les trous critiques et hauts de juin sont fermés. Les statuts "partiel" correspondent aux findings ci-dessous, de sévérité nettement moindre.

### Nouveaux findings

#### N1 [MOYENNE] SSRF non gardé sur `install_from_git` (git clone d'une URL utilisateur)
`lib/servant/apps.ex:160-183`, `:41-47`, `:170-180`. `validate_repo_url/1` vérifie seulement le schéma `https://`, sans appeler `Servant.HTTP.ensure_public_url/1` (contrairement à rss/ical/vcard désormais gardés). `git_clone/2` lance `git clone -- <url>` vers la cible et renvoie au client la sortie d'erreur tronquée à 500 caractères. Un utilisateur authentifié POST `/api/apps` avec `repo_url = https://10.0.0.5:8443/x` fait ouvrir une connexion HTTPS vers le réseau interne, et le message d'erreur (fragments de réponse, timeout vs refus) permet de cartographier les services internes. Correction : appeler `ensure_public_url` dans `validate_repo_url/1` avant le clone, et ne pas réfléchir la sortie brute de git.

#### N2 [MOYENNE] TOCTOU / DNS rebinding dans `ensure_public_url`
`lib/servant/http.ex:47-77`. La garde résout le hostname puis vérifie les IP, mais `Req.get` re-résout le DNS au moment de la requête. Un attaquant maîtrisant sa résolution DNS renvoie une IP publique à la validation et une IP privée (`169.254.169.254`, `127.0.0.1`) à la requête. En multi-user, un compte configure un connecteur RSS/iCal vers un domaine à TTL court sous son contrôle; au fetch, l'endpoint métadonnées cloud ou un service interne est ingéré comme entries. Limite documentée mais exploitable. Correction : résoudre l'hôte une fois et se connecter par IP (entête Host fixé), ou transport custom rejetant les IP privées à la connexion.

#### N3 [BASSE] TLS non vérifié pour les fetch de flux rss/ical/vcard
`rss_connector.ex:73`, `ical_connector.ex:104`, `vcard_connector.ex:69`. `req_options(verify: false)` désactive la vérification de certificat. Aucun secret transmis (GET de flux publics), donc un MITM ne peut que falsifier le contenu (empoisonnement de données, pas de vol de credential). Sévérité réduite vs juin (Strava/EB/RPC re-vérifient). Correction : limiter `verify: false` à une liste blanche d'hôtes touchés par le bug OTP 27, `verify_peer` par défaut ailleurs.

#### N4 [BASSE] L'allow-list d'upload ne rejette pas les types non listés
`upload_controller.ex:90-93`, `:149-155`, `:18-33`. Le moduledoc annonce une "type allow-list" mais `create/2` ne rejette jamais un `content_type` hors `@allowed_types` : la map ne sert qu'au mapping type→extension, `extension/2` retombe sur `Path.extname`. N'importe quel type est stocké. Le vecteur XSS (html/svg servi inline) est neutralisé par `X-Content-Type-Options: nosniff` + CSP `sandbox` de `FilesController` (`files_controller.ex:27-28`); reste le stockage de types arbitraires et un contrat trompeur. Correction : rejeter les `content_type` hors allow-list (422), ou aligner le moduledoc.

#### N5 [BASSE] Verrouillage de compte par le throttle de login (DoS)
`auth_controller.ex:148-176`, `auth/throttle.ex:13-14`. Le throttle de login est clé par `"login:" <> downcase(username)` seul : 10 échecs verrouillent le compte 15 min, sans limiteur par IP sur login ni rate-limit global sur `/auth/register`. Qui connaît un nom d'utilisateur peut le maintenir verrouillé en boucle. Sur un hub mono-user, gêne plus que prise de contrôle. Correction : coupler à un throttle par IP, ou backoff exponentiel ne privant pas l'utilisateur légitime.

#### N6 [BASSE] erl_crash.dump contient des secrets et n'est pas dans .dockerignore
`erl_crash.dump` (racine, 6,4 Mo), `.dockerignore`. Le dump contient `secret_key_base` (3 occurrences) et un `refresh_token` (grep confirmé). Il est gitignoré (`.gitignore:17`, non suivi), mais `.dockerignore` n'exclut que `*.db` : un `docker build` depuis la racine l'enverrait dans le contexte de build. Fuite locale de `secret_key_base` (qui dérive aussi la clé connecteurs si `CONNECTOR_ENCRYPTION_KEY` absente) et d'un token OAuth. Correction : supprimer le fichier; ajouter `erl_crash.dump` à `.dockerignore`.

#### N7 [BASSE] Les tokens API `srv_` survivent au changement de mot de passe / logout
`api_tokens.ex:1-63`, `accounts.ex:70-88`. Le `token_version` invalide les tokens de session, mais les tokens `srv_` sont volontairement indépendants et révoqués seulement individuellement (`delete_token/2`). Après compromission + rotation de mot de passe, les tokens API émis avant restent valides tant qu'ils ne sont pas supprimés un par un dans Settings. Comportement documenté comme intentionnel. Correction : proposer (ou forcer) la révocation de tous les tokens API au changement de mot de passe, ou au minimum le signaler dans l'UI.

#### N8 [INFORMATIF] Modèle de menace des apps custom (trade-off documenté, portée réelle à acter)
`apps.ex:115-118`, `app_controller.ex:94-129`. Le module d'entrée d'une app est importé par la SPA (`import(entry_url)`) et s'exécute dans l'origine de l'app avec la session complète de l'utilisateur. La CSP `sandbox` de `FilesController` ne s'applique qu'à une navigation directe, pas à un import ES module : l'app tourne avec tous les privilèges, y compris les endpoints `session_only` (créer des tokens API, changer le mot de passe). Apps par-utilisateur, donc pas d'accès aux données d'un autre user côté serveur. Trade-off accepté (warning à l'install), rappelé pour le rayon d'action exact. Correction optionnelle : exécuter les apps dans un iframe sandboxé sur origine séparée, API relayée par postMessage limitée par scopes.

### Points positifs confirmés

- Isolation multi-user solide : toutes les requêtes `Data.*`, `Notes.*`, `Connectors.*`, `Apps.*`, DAV et fichiers filtrent par `user_id` ou passent par `resolve_owned_path`. Pas d'IDOR trouvé (scoping systématique `Repo.get_by(id, user_id)`).
- Pas d'injection SQL : les fragments `json_extract`/`LIKE` (`data.ex:100-102,314`) sont entièrement paramétrés.
- Pas de XXE : DAV parse les hrefs par regex (`dav_controller.ex:253-259`); apple_health utilise Saxy (pas de DTD/entités externes).
- Pas d'injection de commande : `git clone` et `node` via `System.cmd` (pas de shell), avec `--` et garde provider `^[a-z0-9_]+$`.
- Mass assignment maîtrisé : `admin`, `token_version`, `hashed_password`, `totp_secret` jamais dans un `cast`.
- Auth soigné : anti-replay TOTP (`accounts.ex:140-152`), tickets TOTP signés courts, comparaison de tokens par hash SHA-256, `Bcrypt.no_user_verify`, cookie HttpOnly+SameSite+Secure, HSTS, pas de CORS permissif.

---

# PASSE FRONTEND

## Phase 1 : Architecture

### Carte du frontend

Structure `frontend/src/` : `apps/` (8 apps métier calendar/checklists/contacts/files/finance/notes/photos/trackers + registry.ts, types.ts contrat AppContext/AppModule, createContext.ts), `components/` (9 partagés : MediaViewer, VideoPlayer, ComboBox, AutocompleteInput, CommandPalette, ConfirmModal, DateInput, KindIcon), `composables/` (apiClient, useApi, useSocket, useFetchData, useConfirm, authConfig), `lib/` (datetime, theme, contact, uploadQueue, url, entryRoute, apiTokenScopes), `stores/` (auth, apps, index Pinia), `views/` (13 vues routées), `router/`, `types.ts`. 33 composants `.vue`, 64 modules `.ts` (dont ~15 `.test.ts`).

15 plus gros fichiers (wc -l) : PhotosApp.vue 1872, NotesApp.vue 1477, CalendarApp.vue 1380, FilesApp.vue 1185, ChecklistsApp.vue 1115, ConnectorDetailView.vue 1012, ContactDetailView.vue 978, FinanceApp.vue 929, ContactsApp.vue 882, SettingsView.vue 857, DashboardView.vue 819, DataBrowserView.vue 714, ProfileView.vue 648, ConnectorsView.vue 584, connectors.ts 567.

Système d'apps : `stores/apps.ts` fusionne builtins (`apps/registry.ts`, 8, filtrés par `user.enabled_apps`) et apps git installées (`GET /api/apps`). Contrat (`apps/types.ts`) : `AppModule { mount(el, ctx), unmount?(el) }`; `ctx: AppContext` fournit `navigate`, `confirm`, `viewer`, `api { entries, upload(), fetch() }`. `AppView.vue` monte l'app dans un div impératif. Les builtins sont 8 adaptateurs `index.ts` identiques (`createApp(Component, {ctx}).mount(el)`). Apps installées chargées par `import(entry_url?v=updated_at)` (même origine `/files/<user>/installed_apps/`, cookie, pas d'iframe/sandbox). Les 8 apps passent exclusivement par `ctx.api.*` (contrat respecté).

Couche API : client unique `composables/apiClient.ts` (`apiFetch` ajoute Bearer, gère params, `401 → logout`, parse `{error}` et `{errors:{champ:[...]}}`; `apiJson<T>` gère 204). `useApi()` ré-emballe en get/post/put/del (12 vues). `createContext.ts` bâtit l'EntriesAPI (pagination auto) + upload XHR (progression). Enveloppe `%{data: ...}` déballée systématiquement.

Temps réel : `composables/useSocket.ts` ouvre le Socket Phoenix, rejoint `data:<user_id>`, mappe `entry_change → onEntryChange` et `entries_changed → onBulkChange`. Reconnexion via lib Phoenix, pilotée par un watch sur `isAuthenticated && !!user`. Backend émet `entry_change` avec `type: created|updated|deleted` + `entry` (pour delete, `%{id}` seul).

État : `stores/auth.ts` (token en mémoire, flag `servant_logged_in` en localStorage, hydrate via `/auth/me`), `stores/apps.ts`. Routing : login/register eager, reste lazy, guard `beforeEach` sur `meta.auth`/`meta.guest`, `hydrate()` lancé sans await avant mount (guard correct grâce au flag synchrone).

### Findings

#### 1. [MOYENNE] Le temps réel ne couvre pas les 8 apps, seulement Dashboard et DataBrowser
`composables/useSocket.ts:6`, `views/DataBrowserView.vue:70-73`, `views/DashboardView.vue:33-39`. `useSocket` n'est consommé que par deux vues ; `AppContext` (`apps/types.ts:59-72`) n'expose aucune souscription temps réel. Photos, Finance, Calendar, Trackers ne se rafraîchissent pas quand un connecteur écrit des entries en arrière-plan (l'événement `entries_changed` est fait pour ça). L'utilisateur voit des données périmées jusqu'au rechargement. Correction : ajouter `onEntryChange`/`onBulkChange` debouncés à `AppContext.api`, ou faire souscrire `AppView.vue` et notifier l'app montée.

#### 2. [MOYENNE] Frontière floue entre une app et ses vues détail routées
`apps/contacts/ContactsApp.vue:402,408`, `apps/photos/PhotosApp.vue`, `views/ContactDetailView.vue`, `views/PhotoDetailView.vue`. ContactsApp navigue vers `/contacts/:id` et PhotosApp vers `/photos/:id`, vues routées top-level hors du sandbox `AppView`, qui contournent `ctx` et utilisent `useApi` + `fetch` brut (`ContactDetailView.vue:206`). Le périmètre d'une app fuit hors du contrat : une app installée externe ne pourrait pas reproduire ce pattern (elle n'a que `ctx.navigate`). Deux modèles d'accès données cohabitent. Correction : intégrer le détail dans l'app, ou documenter que les vues détail sont un privilège des builtins.

#### 3. [MOYENNE] `useFetchData` sous-utilisé : chaque app réimplémente loading/error/try-catch
`composables/useFetchData.ts` (importé seulement par ContactDetailView et PhotoDetailView). Les 8 apps roulent leur propre gestion : NotesApp 11 blocs `try`, PhotosApp 8, FinanceApp 6, TrackersApp 7, chacune avec ses ref d'état. Le composable qui factorise ce pattern existe mais n'est utilisé nulle part dans les apps. Duplication et gestion d'erreur incohérente (certaines affichent, d'autres avalent). Correction : adopter `useFetchData` (ou un helper exposé via `ctx`) dans les apps.

#### 4. [MOYENNE] Composants monolithiques
PhotosApp.vue (1872 l.), NotesApp.vue (1477), CalendarApp.vue (1380), FilesApp.vue (1185), ChecklistsApp.vue (1115). La logique pure est bien extraite en `.ts` testés (recurrence, markdown, faces, finance, trackers, render), mais les `.vue` restent énormes (script + template + style dans un seul fichier), contre l'esprit "un composant par fichier" d'AGENTS.md, et complique tests/revue. Correction : découper en sous-composants (barre d'outils, grille, détail, modales) comme finance (BalanceChart.vue) et trackers (TrackerCard.vue).

#### 5. [MOYENNE, voir sécurité] Apps installées chargées par `import()` same-origin, non sandboxées
`stores/apps.ts:34`, backend `apps.ex:116-118`. `import(entry_url)` depuis `/files/<user>/installed_apps/` : le JS d'une app installée s'exécute avec tous les privilèges same-origin (cookie, `/api`, DOM). Le contrat `ctx` est une convention, pas une barrière : rien n'empêche une app d'appeler `fetch('/api/...')` hors `ctx`. Choix d'architecture structurant (cf. finding sécurité N8). Correction / à trancher : documenter le modèle de confiance, ou iframe sandboxée + postMessage pour une vraie isolation.

#### 6. [BASSE] Les 8 adaptateurs `index.ts` sont 100 % dupliqués
`apps/{calendar,checklists,...}/index.ts`. Les 8 fichiers (19 lignes) sont identiques au nom du composant près. Pur boilerplate. Correction : un helper `defineVueApp(Component): AppModule` réduit chaque `index.ts` à une ligne.

#### 7. [BASSE] `apiFetch` force `Content-Type: application/json`, d'où des `fetch` bruts qui contournent le client
`composables/apiClient.ts:40-43`. `apiFetch` impose toujours le content-type JSON, inutilisable pour le multipart. Au moins 3 sites réimplémentent `fetch` + Bearer à la main et court-circuitent le `401 → logout` : `ProfileView.vue:198` (avatar), `ContactDetailView.vue:206` (upload), `SettingsView.vue:210` (download blob), plus l'upload XHR de `createContext.ts:97`. Trois implémentations d'upload. Correction : laisser `apiFetch` omettre le Content-Type quand `body` est un `FormData`, puis router ces appels par `apiFetch`.

#### 8. [BASSE] Le type du callback socket ment sur l'événement `deleted`, et le champ `type` est ignoré
`composables/useSocket.ts:11,14,41-45` vs `data_channel.ex:31`. Le backend envoie pour un delete `entry: %{id}` (partiel), mais `useSocket` type le callback `(entry: Entry)` (complet) et jette le champ `type`. Pas de bug runtime aujourd'hui (les consommateurs refetch), mais le type est faux et toute future logique de merge granulaire (finding 1) construirait une entry invalide. Correction : typer `{ type: 'created'|'updated'|'deleted'; entry: Partial<Entry> & { id: string } }` et exposer `type`.

#### 9. [BASSE] Erreur réseau de `appsStore.load()` avalée → message "App not found" trompeur
`views/AppView.vue:70`. `await appsStore.load().catch(() => {})` : si `GET /api/apps` échoue, `getDef` renvoie `undefined` et l'utilisateur voit `App "<id>" not found` au lieu d'une erreur de chargement. Correction : distinguer "liste non chargée" (réseau, retry) de "id inconnu".

#### 10. [BASSE] Deux styles d'accès HTTP en parallèle (`useApi` vs `apiJson`)
`composables/useApi.ts` vs `apiClient.ts`. `useApi()` n'est qu'un ré-emballage de `apiJson`. Les vues passent par `useApi`, tandis que `createContext`/`stores`/`lib` appellent `apiJson` directement. Deux conventions pour la même chose. Correction : trancher pour l'un ou l'autre.

#### 11. [BASSE] Formatage de date hors `lib/datetime` (tz utilisateur non appliquée)
`views/ConnectorDetailView.vue:469`. `new Date(ebValidUntil).toLocaleDateString()` formate en tz du navigateur, pas la préférence `user.timezone` de `lib/datetime.ts`. La lib est très bien adoptée ailleurs (18 fichiers), oubli isolé. Correction : utiliser `formatDate`.

### Seam front-back (bref)

- **Types** : `types.ts` `Entry` correspond exactement à `Entry.to_json` backend. `data`/`metadata` restent `Record<string, unknown>`, chaque app caste son payload : le typage s'arrête à la frontière de l'entry (choix assumé, validation reportée sur chaque app).
- **Enveloppes** : `%{data: ...}` déballée uniformément via `apiJson`; erreurs `{error}` et changeset parsées au même endroit (`apiErrorMessage`), y compris dans `stores/auth.ts`.
- **Événements socket** : noms émis (`entry_change`, `entries_changed`) alignés avec le front. Seule divergence : le front ignore `type` et le payload partiel du delete (finding 8).

## Phase 3 : Tests et couverture (frontend)

### État des lieux

Suite exécutée depuis `frontend/` (`npm run test` = `vitest run`, node_modules présent) : **21 fichiers, 138 tests, 0 échec, 2,59 s** (jsdom). Aucun outil de couverture installé (`@vitest/coverage-v8` absent, pas de script `test:coverage`) : la couverture est estimée par lecture, pas mesurée.

Cartographie : logique pure `.ts` bien couverte (`recurrence.ts`, `trackers.ts`, `finance.ts`, `datetime.ts`, `checklists/markdown.ts`, `notes/render.ts`, `lib/{theme,url,contact,entryRoute,apiTokenScopes}.ts`, `registry.ts`, `apiErrorMessage`), avec de bons edge cases et des tests de sécurité XSS/`javascript:` dans `render.test.ts` et `url.test.ts`. Composants `.vue` avec test réel (mount + interactions) : NotesApp, ChecklistsApp, TrackersApp, ComboBox, AutocompleteInput. Convention AGENTS.md (actual à gauche) respectée. Trous majeurs : 0/33 vues testées (dont login/register/TOTP), auth store, router guards, useSocket, useFetchData, useApi, useConfirm, createContext, lib/uploadQueue : aucun test.

### Findings

#### 1. [HAUTE] `apiClient` : le point de passage de toutes les requêtes n'est testé que sur sa fonction pure
`composables/apiClient.ts:44-70`. `apiClient.test.ts` ne couvre que `apiErrorMessage`. `apiFetch`/`apiJson` non testés : injection du Bearer, branche `401 → auth.logout()` (:48-50), parsing d'erreur non-401 (:52-54), `return undefined` sur 204 (:69). Régression qui passerait : un 401 qui ne déclenche plus le logout (session zombie), ou un 204 qui casse un `.json()` appelant. Suggestion : mocker `fetch` global, asserter Bearer posé, `logout()` appelé et erreur levée sur 401, `undefined` sur 204.

#### 2. [HAUTE] `createContext` : la pagination des apps n'a aucun test
`apps/createContext.ts:32-47`. `createAppContext` non testé. La boucle de pagination de `entries.list` (`do { } while (page <= totalPages)`), écrite pour corriger le cap silencieux à 10k, est critique : un off-by-one (`<` au lieu de `<=`, `page` à 0, `total_pages` mal lu) droppe la dernière page ou boucle à l'infini, et toutes les apps perdraient des entrées sans erreur visible. La gestion d'erreur XHR de `upload` (:115-131) non testée. Suggestion : mocker `apiJson` sur 3 pages, asserter la concaténation et l'arrêt à `total_pages`.

#### 3. [HAUTE] Le store d'auth n'a aucun test
`stores/auth.ts:39-123`. Non couverts : branche `data.requires_totp` de `login` (:55, distingue 2FA vs connexion directe), `verifyTotp`, `register`, persistance du flag `servant_logged_in`, et `hydrate` (:107-123, confirme via `/auth/me`, nettoie sur 401). Régression qui passerait : `login` qui poserait `setAuth` malgré `requires_totp` (2FA court-circuitée côté UI), ou `hydrate` qui ne nettoie plus sur cookie expiré (faux "connecté"). Suggestion : tester les deux branches de `login`, et `hydrate` avec 200/401/erreur réseau.

#### 4. [HAUTE] Les guards du router ne sont pas testés
`router/index.ts:96-106`. `beforeEach` non testé : redirection vers login si `meta.auth && !isAuthenticated`, vers dashboard si `meta.guest && isAuthenticated`. Régression qui passerait : une route `auth` accessible sans session, ou une boucle de redirection. Suggestion : router + pinia de test, `router.push('/settings')` non authentifié → `currentRoute.name === 'login'`.

#### 5. [HAUTE] `useSocket` n'a aucun test
`composables/useSocket.ts:26-92`. Non couverts : gating de `connect` (token ET user, :27), le `watch` qui (re)connecte après `hydrate` async au reload et déconnecte au logout (:68-78), `disconnect` sur `onUnmounted`, et `debounce` (:92). Régression qui passerait : socket qui ne se connecte jamais après un reload, ou canal qui fuit après logout. Suggestion : mocker `phoenix`, piloter `auth.user`/`auth.token`, asserter connect/disconnect ; tester `debounce` avec faux timers.

#### 6. [HAUTE] Le clustering de visages n'est testé qu'avec des embeddings jouets trop séparés
`apps/photos/faces.ts:66-114`. `faces.test.ts` teste avec `alice=[1,0,0]`/`bob=[0,1,0]` (distance ~1.41, très au-dessus du seuil `FACE_MATCH_DISTANCE=0.5`). Aucun test ne sonde le seuil de 0.5 ni la dérive du centroïde (running mean :90) qui peut, par chaînage, tirer le centroïde à travers le seuil et fusionner deux personnes. Régression qui passerait : `<` en `<=` ou modifier seuil/formule ne casse aucun test. Suggestion : paires à 0.49 (fusion) et 0.51 (séparation), et une chaîne A-B-C où A et C sont à >0.5 mais reliés par B, pour figer la dérive.

#### 7. [MOYENNE] Le moteur d'upload n'est pas testé sur son cas concurrent
`lib/uploadQueue.ts:55-115` (+ `apps/files/uploadQueue.test.ts:44`). `createUploadQueue` testé indirectement, jamais sur le concurrent : ajout d'items pendant qu'un batch tourne (rejoindre un batch en cours :55-61, croissance de `batchTotal`/`totalBytes` en vol, garde `if (!uploading.value)`). `files/uploadQueue.test.ts` n'a qu'un happy path, contrairement à `photos/uploadQueue.test.ts`. Régression qui passerait : un `enqueue` en cours de batch qui démarre un 2e worker (fichier perdu ou compteur faux). Suggestion : `enqueue` une 2e fois pendant `uploading`, vérifier chaque item traité une fois et `batchesDone` incrémenté une fois.

#### 8. [MOYENNE] `datetime.ts` : conversion tz non testée aux transitions DST
`lib/datetime.ts:67-104`. `zonedToUtcISO`/`tzOffsetMs` utilisent un "guess and subtract" à un passage, non testé aux bascules DST (heure inexistante du spring-forward, heure ambiguë du fall-back), motif classiquement faux d'une heure. Les tests couvrent Paris été / NY hiver mais pas le jour de bascule. Régression qui passerait : un événement créé le matin du changement d'heure décalé d'une heure. Suggestion : asserter `zonedToUtcISO('2026-03-29','02:30','Europe/Paris')` et le samedi de fall-back.

#### 9. [MOYENNE] `useFetchData`/`useApi`/`useConfirm` sans test
`composables/useFetchData.ts:35-56`. `useFetchData` (machine loading/error/refetch de la plupart des vues), `useApi`, `useConfirm` non testés. Régression qui passerait : `error` non réinitialisée au `refetch` (erreur transitoire persistante), ou `loading` jamais remis à false sur exception (spinner infini). Suggestion : fetcher qui échoue puis réussit, asserter la séquence loading/error/data.

#### 10. [MOYENNE] Aucun outillage de couverture
`package.json:8-9`. Pas de `@vitest/coverage-v8`, pas de script `test:coverage`, pas de seuil dans `vitest.config.ts`. Impossible de mesurer la couverture ou de détecter une régression en CI ; toute la zone non testée (auth, router, socket, createContext) reste un angle mort invisible. Suggestion : ajouter `@vitest/coverage-v8`, un script, un seuil minimal sur la logique pure.

#### 11. [BASSE] Composants réutilisables sans test de composant
`components/DateInput.vue`, `MediaViewer.vue`, `CommandPalette.vue`, `ConfirmModal.vue`. `DateInput` (wrapper flatpickr récent) le plus à risque : aucun test ne vérifie qu'il émet la bonne valeur `YYYY-MM-DD` ni le fuseau utilisateur (flatpickr construit ses dates en horloge locale). Régression qui passerait : `DateInput` qui émet une date décalée d'un jour. Suggestion : monter, simuler une sélection, asserter la valeur `v-model` ; monter `ConfirmModal` et vérifier resolve(true)/resolve(false).

#### 12. [BASSE] Tests tautologiques sur des constantes
`lib/theme.test.ts:20-25`, `apps/registry.test.ts:21-24`. "exposes five themes with night first" asserte la valeur littérale d'une constante : fragile (tout ajout/réordonnancement casse le test sans bug). Suggestion : réduire à l'invariant réel (`THEMES[0].id === 'night'` et `THEMES.length > 0`).

Note : `faceScan.ts` (chargement wasm de face-api) et la rotation photo ne sont pas testables en unitaire côté front (rotation = POST serveur, aucune logique pure ; faceScan dépend de WebGL/wasm indisponible en jsdom). Pas des trous à combler par du test unitaire.

## Phase 2 : Bugs de correction et observabilité (frontend)

### Sévérité haute

#### 1. [HAUTE, observabilité] Le report d'erreur client n'est câblé qu'aux uploads
`lib/uploadQueue.ts:98`, `main.ts:13-21`. Le backend expose `POST /api/client_errors` (`router.ex:67`) et l'AuditView a un onglet "Error log", mais le seul appelant du frontend est le worker d'upload. `main.ts` ne pose ni `app.config.errorHandler` ni `window.addEventListener('unhandledrejection')`. Tous les `catch {}` muets (TrackersApp reload/loadAggregates/setValue/createTracker, CalendarApp saveEvent/deleteEvent, les `uploadErrors.value.push` de PhotosApp scanFaces/rotateSelected/nameCluster) ne remontent jamais à l'Audit. Un utilisateur qui signale "le scan a planté" n'a aucune trace serveur (l'incident n'existe que dans sa console navigateur, jamais consultée). Correction : enregistrer `app.config.errorHandler` + listener `unhandledrejection` dans `main.ts` qui POST vers `/api/client_errors` (fire-and-forget), et router les erreurs PhotosApp vers cet endpoint.

#### 2. [HAUTE] PhotosApp : les éditions groupées échouent en silence et à moitié
`apps/photos/PhotosApp.vue:624`, `:652`, `:679`, `:697`, `:714`. `applyDate`, `tagWithContact`, `applyTag`, `removeTagFromSelected`, `removeTagAction` bouclent sur `entries.update` sans try/catch (contrairement à deletePhotos/rotateSelected/scanFaces/nameCluster). Si un update échoue au milieu, la boucle s'arrête : photos déjà traitées modifiées, suivantes non, le modal ne se ferme pas, `reload()` jamais appelé, sélection persistante, aucun message. Scénario : 40 photos sélectionnées, "Set date", réseau qui hoquette à la 12e → 11 modifiées, 29 non, modal ouvert, l'utilisateur croit que ça a marché. Correction : try/catch/finally, remonter l'erreur, fermer le modal et `reload()` dans `finally`, sur le modèle de `rotateSelected`.

### Sévérité moyenne

#### 3. [MOYENNE] TrackersApp : réponses d'agrégats arrivant dans le désordre
`apps/trackers/TrackersApp.vue:64-91`, watch `:120`, écriture `:90`. `loadAggregates` finit par `entryMaps.value = maps` sans garde de génération, alors qu'il est déclenché par watch, `reload()` et le ResizeObserver. Deux appels concurrents peuvent répondre dans le désordre. Scénario : clic rapide "plus ancien" puis "plus récent" (ou redimensionnement pendant un fetch) → la requête ancienne (plus lente) répond en dernier et écrase `entryMaps` avec des données périmées. Correction : token de requête capturé au début, n'affecter que si toujours le plus récent (ou AbortController).

#### 4. [MOYENNE] TrackersApp : double-clic → logs en double pour un même jour
`apps/trackers/TrackersApp.vue:146-175`, boutons `TrackerCard.vue:167-181`. `setValue` cherche le log du jour dans `logEntries.value` puis crée sinon, mais `logEntries.value` n'est mis à jour qu'après l'`await` : deux appels rapprochés prennent tous deux la branche "create". Les boutons +/−/toggle ne sont pas désactivés pendant l'écriture. Scénario : deux "+" rapides → deux entrées `tracker_log` pour le même tracker/jour, valeur affichée incohérente. Le commentaire de `trackers.ts` promet "one per tracker per day, upserted" mais le client passe par `entries.create`. Correction : désactiver les contrôles en vol, garde in-flight par (trackerId, date), ou upsert serveur.

#### 5. [MOYENNE] PhotosApp : les boucles longues ne sont pas annulées au démontage
`apps/photos/PhotosApp.vue:211-225` (rebuildPreviews), `:236-273` (rebuildVideoThumbs), `:297-324` (scanFaces). Aucun garde de montage ni AbortController. `scanFaces` importe face-api (CPU lourd) et traite chaque image ; `rebuildPreviews` boucle 15 fois avec `setTimeout(4000)` + `reload()` (~60 s). Rien ne s'arrête à `onUnmounted`. Scénario : "Scan faces" sur une grosse bibliothèque puis navigation ailleurs → le détecteur continue en fond, `entries.update` part sur un composant démonté, le polling continue une minute. Correction : flag `alive` mis à false dans `onUnmounted`, sortir des boucles sinon (idéalement AbortController).

#### 6. [MOYENNE] CalendarApp : flatpickr greffé sur des `<input type="date">` → double calendrier
`apps/calendar/CalendarApp.vue:850`, `:853`, watch `:555-584`. Les inputs date du modal sont `type="date"` et flatpickr y est attaché : sur navigateurs à picker natif, le natif ET flatpickr s'ouvrent. `DateInput.vue:42` utilise correctement `type="text"` : incohérence. Scénario : "New event", clic sur le champ date → deux calendriers superposés, le natif (non thématisé) par-dessus flatpickr. Correction : `type="text"`, ou mieux réutiliser `DateInput.vue`.

### Sévérité basse

#### 7. [BASSE] datetime.zonedToUtcISO : décalage DST possible d'une heure
`lib/datetime.ts:95-104`. L'offset est calculé à l'instant "wall-clock lu comme UTC" en une passe. Aux transitions DST (heure sautée/répétée), l'UTC stocké peut être décalé de 60 min. Scénario : événement créé près du changement d'heure → `occurred_at` faux d'une heure. Correction : double correction d'offset (recalculer à `guess - offset(guess)`, réitérer une fois). Recoupe le finding 8 de la phase 3 front.

#### 8. [BASSE] PhotosApp : deep-link `?photo=` filtré ouvre la mauvaise photo
`apps/photos/PhotosApp.vue:729-766` (openViewer), `:772-776` (onPopState). `idx = photos.findIndex(...)` sur `filtered.value` puis `viewer.open(items, Math.max(0, idx))` : si l'id n'est pas dans la liste filtrée, `idx = -1` → ouvre la première photo. Scénario : filtre actif, "précédent" navigateur vers une photo hors filtre → viewer sur une autre photo. Correction : si `idx === -1`, lever le filtre ou ignorer l'ouverture.

#### 9. [BASSE] useSocket : échec de `channel.join()` jamais remonté ni journalisé
`composables/useSocket.ts:26-52`. `channel.join()` n'a pas de `.receive('error')`/`.receive('timeout')`, et le Socket n'a ni `onError` ni `onClose`. Un join rejeté (token expiré en session) laisse un flux temps réel mort en silence. Scénario : token expire onglet ouvert → join échoue, plus d'événements, UI périmée sans indication, rien de loggé. Correction : `.receive('error'/'timeout')` + `socket.onError`/`onClose`, remonter un état "temps réel indisponible" (cf. finding 1).

#### 10. [BASSE] lib/uploadQueue : le démarrage d'un nouveau lot efface les erreurs affichées
`lib/uploadQueue.ts:65`. `run()` fait `uploadErrors.value = []` en début de lot : les erreurs d'un lot précédent disparaissent dès qu'un nouvel upload démarre, avant lecture. Correction : ne réinitialiser qu'au clic "Dismiss", ou accumuler.

#### 11. [BASSE] FaceChip : échec de chargement d'image → canvas vide silencieux
`apps/photos/FaceChip.vue:13-31`. `draw()` pose `img.onload` mais pas `img.onerror` : si `chipSrc` est cassé, le canvas 56px reste vide, sans placeholder. Correction : `img.onerror` qui dessine un placeholder.

#### 12. [BASSE] TrackersApp : `today` ne bascule pas à minuit
`apps/trackers/TrackersApp.vue:124`. `today = computed(() => todayInUserTz())` ne dépend que du fuseau, pas de l'écoulement du temps : figé à la valeur du montage. Scénario : onglet Trackers laissé ouvert, consulté après minuit → cellule "aujourd'hui" et streaks sur la veille, log écrit sur la mauvaise date jusqu'au rechargement. Correction : recalculer sur timer ou au `visibilitychange`.

Note positive : les `ObjectURL` sont tous révoqués (checklists, calendar export, settings, capture vidéo), aucun `console.*` ne traîne, timeouts/nettoyage corrects. Le point faible d'ensemble est l'observabilité (findings 1-2) : l'infra `client_errors` + Audit existe mais n'est branchée qu'à l'upload.

## Phase 4 : Sécurité (frontend)

La CSP de production (`script-src 'self' 'wasm-unsafe-eval'`) est servie sur l'HTML SPA (`spa_controller.ex`) ; les findings ci-dessous en tiennent compte mais ne peuvent pas vérifier `connect-src`/`img-src` depuis le front seul.

### Findings

#### 1. [HAUTE] Apps installées same-origin : compromission totale de session par design
`stores/apps.ts:34`, `views/AppView.vue:79`, `apps/createContext.ts:136`. Une app installée est chargée par `import(entry_url?v=...)` depuis `/files/<user>/installed_apps/` (même origine, cookie), et s'exécute avec tous les privilèges de la page. `createAppContext` expose `api.fetch = apiFetch`, client générique vers n'importe quel `/api` avec le Bearer/cookie. Scénario : une app malveillante (ou un repo légitime compromis via mise à jour) appelle `ctx.api.fetch('/api/tokens', {method:'POST', body: {scopes:['data:write','data:read-binary']}})` pour se forger un token `srv_` longue durée, lit toutes les entries, exfiltre par `window.location`. La CSP `script-src 'self'` ne protège pas (module same-origin, exfiltration par navigation top-level). Trade-off assumé et bien signalé par l'UI (cf. points positifs). Correction si des apps non fiables doivent être supportées : origine dédiée + `<iframe sandbox>` + pont postMessage, ou au minimum épingler un hash d'intégrité du module dans le manifest pour bloquer une mise à jour piégée. Recoupe le finding N8 de la sécurité backend.

#### 2. [HAUTE] URL de facture rendue en `:href`/`window.open` sans `safeUrl` (XSS stockée)
`apps/files/FilesApp.vue:790` (`:href="invoiceUrl(selected)!"`), `:222` (`invoiceUrl` = `field<string>(e,'url')` brut), `:229` (`window.open(field<string>(f,'url'),'_blank')`). Le helper `safeUrl` (`lib/url.ts`) filtre `javascript:`/`data:` et est correctement appliqué aux URLs de contacts (`ContactsApp.vue:91`, `ContactDetailView.vue:502`), mais PAS au champ `url` des factures, qui provient de `invoice["url"]` scrapé verbatim depuis les portails fournisseurs (`invoice_scraper_connector.ex:214`), sans validation de schéma backend. Scénario : un portail compromis (ou un MITM sur le scrape) renvoie `url = "javascript:fetch('/api/tokens',{method:'POST',...})"` ; l'entrée est stockée ; dans l'app Fichiers, "Open invoice" (`:href`) l'exécute au clic (Vue ne neutralise pas `javascript:` dans `:href`), et `window.open('javascript:...')` aussi. XSS stockée avec session complète. Correction : router l'URL de facture par `safeUrl(...)` avant tout `:href` et `window.open`, renvoyer null/désactiver si schéma non http(s) ; ajouter `'noopener'`.

#### 3. [MOYENNE] Token de session transmis en clair dans l'URL du WebSocket
`composables/useSocket.ts:33` (`params: { token: auth.token }`). Le token en mémoire (jusqu'à 30 jours) est passé en paramètre de connexion Phoenix, que la lib sérialise dans la query string `wss://.../socket?token=...`. Les query strings WS sont fréquemment journalisées par les proxies/LB, contrairement aux cookies HttpOnly. Scénario : un token capturé dans les logs d'un reverse-proxy permet de rejouer la session. Atténué par TLS et le token in-memory, mais la surface existe. Correction : token socket éphémère à usage unique et courte durée (Phoenix.Token dédié), distinct du bearer API ; ou authentifier le socket via le cookie ; à défaut, documenter le filtrage des query WS en prod.

#### 4. [BASSE] `window.open('_blank')` sans `noopener` sur une URL externe (reverse tabnabbing)
`apps/files/FilesApp.vue:229`. `window.open(url, '_blank')` sans `noopener` laisse `window.opener` accessible à la page ouverte. Les `<a target="_blank">` du fichier portent `rel="noopener"`, pas cet appel impératif. Scénario : une page de facture hostile fait `window.opener.location = 'https://phishing/login'`. Correction : `window.open(url, '_blank', 'noopener')` (et filtrer par `safeUrl` avant, cf. finding 2).

#### 5. [BASSE] `markdown-it` s'appuie sur `html:false` implicite plutôt qu'explicite
`apps/notes/render.ts:5` (`new MarkdownIt({ breaks: true, linkify: true })`). La protection XSS des notes repose sur le défaut `html: false` et le `validateLink` par défaut (bloque `javascript:`/`vbscript:`/`file:`). Correct aujourd'hui, mais le défaut n'est pas explicite : un futur refactor activant `html: true` supprimerait silencieusement la seule barrière. Correction : passer explicitement `html: false` + commentaire ; DOMPurify sur la sortie si du HTML doit un jour être autorisé.

#### 6. [BASSE] Le flag `servant_logged_in` en localStorage est falsifiable
`stores/auth.ts:18`. `isAuthenticated` dérive du flag localStorage OU de `user` : un utilisateur peut forcer `servant_logged_in=1` pour passer les routes `meta.auth` sans cookie valide. Scénario : shell d'app vide, toute requête `/api` renvoie 401 → `logout()`. Aucune donnée exposée (autorisation réelle côté serveur). Defense-in-depth correcte, mentionné pour complétude. Correction : aucune ; ne jamais faire dépendre l'accès données de ce flag (déjà le cas).

#### 7. [BASSE] Images `:src` depuis des données utilisateur (photo de vCard) : possible balise de traçage
`apps/contacts/ContactsApp.vue:240,263`, `views/ContactDetailView.vue:294,437`, `apps/photos/PhotosApp.vue:884`. Le champ `photo` d'un contact (vCard importé d'un tiers) est lié à `<img :src>`. Si `img-src` autorise les origines externes, ouvrir la fiche déclenche une requête vers l'URL du tiers (pixel espion, fuite d'IP). Pas un XSS. Correction : confirmer `img-src 'self' data:` dans la CSP ; sinon proxifier les photos vCard côté serveur.

### Points positifs confirmés

- Token jamais en localStorage (seul le flag booléen `servant_logged_in`) ; cookie HttpOnly + copie in-memory pour le socket, nettoyage du legacy `auth_token`. Aucun `token=` en query pour `/api` ou `/files`. Aucun `console.log` de secret.
- Rendu markdown robuste : `markdown-it` en `html:false`, `validateLink` par défaut neutralise `[x](javascript:...)`. Les passes wikilinks/mentions/tags opèrent sur les nœuds texte, échappent via `escapeHtml`, génèrent des ancres sans `href` (navigation par `data-target` + handler). Bien raisonné.
- `safeUrl` existant et appliqué aux vCard ; seul manque = la facture (finding 2).
- `escapeHtml` centralisé (une copie partagée).
- Aucune origine externe chargée : polices bundlées (pas de CDN), modèles face-api servis depuis `/models`, aucun script/CSS/image distant. Cohérent avec la CSP stricte.
- `wasm-unsafe-eval` justifié et minimal (backend WASM de face-api/tfjs, pas d'eval JS). heic-to importé via son build CSP-compatible (`import('heic-to/csp')`).
- Reconnaissance faciale 100 % locale (aucune image envoyée à un tiers).
- Tokens API affichés une fois, copiés au presse-papier, effacés du state au "Done" ; jamais persistés.
- `autocomplete` correct (`current-password`, `new-password`, `one-time-code`).
- Pas d'open-redirect (redirection en dur vers `/` après login).
- `v-html` restreint aux logos SVG statiques et à la preview de notes (analysée). Aucun `innerHTML`/`eval`/`new Function` dans `src/`.

---

# PHASES 5-8 (transverses)

## Phase 7 : Dépendances

### Backend (Elixir)

`mix hex.outdated` : 22 deps suivies, 6 en retard (castore, ecto_sqlite3, phoenix, req, saxy ; ecto_sql bloqué par les contraintes ecto). `mix hex.audit` : 1 paquet retiré (plug 1.20.1) et 9 advisories (phoenix, decimal, plug x2, mint x3, req x2). Toutes les deps de `mix.exs` sont utilisées : aucune dep morte.

#### 1. [HAUTE] plug 1.20.1 (retiré + CVE), transitive via bandit/phoenix
Version retirée par ses auteurs (breaking accidentel sur `Plug.Conn.upgrade`) + deux advisories : EEF-CVE-2026-56814 (MEDIUM, DoS par fichiers temporaires illimités en multipart, la limite `:length` ne compte pas les en-têtes de partie) et EEF-CVE-2026-56813 (LOW, injection d'attributs de cookie dans `Cookies.encode/2`). Reco : forcer `plug` vers 1.20.2+/1.21 (`mix deps.update plug`), la contrainte bandit `~> 1.18` l'autorise.

#### 2. [HAUTE] phoenix 1.8.8 → 1.8.9
EEF-CVE-2026-56811 (HIGH) : les transports ne limitent pas les joins de channel par connexion, DoS par épuisement de processus. L'app expose `UserSocket`/`DataChannel`, applicable. Corrigée en 1.8.9. Reco : mettre à jour vers 1.8.9.

#### 3. [HAUTE] req 0.5.17 → 0.6.3
EEF-CVE-2026-49755 (HIGH) : DoS par bombe de décompression sur les corps auto-décodés ; EEF-CVE-2026-49756 (LOW) : injection d'en-tête multipart. Req est le client HTTP de tous les connecteurs (données externes non maîtrisées), exposition réelle. Reco : mettre à jour vers 0.6.3 en testant (le saut 0.5 → 0.6 peut avoir des changements d'API mineurs), assouplir la contrainte `~> 0.5`.

#### 4. [MOYENNE-HAUTE] mint 1.9.1 (transitive via finch ← req)
Trois advisories : EEF-CVE-2026-58229 (HIGH, DoS mémoire par accumulation d'en-têtes HTTP/1), EEF-CVE-2026-59246 (MEDIUM, frames CONTINUATION HTTP/2 vides), EEF-CVE-2026-59249 (MEDIUM, smuggling via parseur de chunk tolérant au signe). Reco : bumper vers mint 1.10 en mettant à jour finch/req.

#### 5. [MOYENNE, mitigée] decimal 2.4.1 (transitive via ecto_sqlite3)
EEF-CVE-2026-32686 (MEDIUM, DoS par exposant non borné). Déjà consciemment ignorée dans l'alias `precommit` (`--ignore-advisory-ids GHSA-rhv4-8758-jx7v`) : le correctif n'existe qu'en decimal 3.0, que ecto n'autorise pas encore. Reco : surveiller la montée de ecto, garder l'ignore documenté.

#### 6. [BASSE] ecto_sqlite3 0.22.0 → 0.24.1 (exqlite 0.35.0)
Deux mineures de retard, pas de CVE. Déclaré `>= 0.0.0` dans `mix.exs`, seul pinning laxiste du fichier. Reco : mettre à jour et resserrer (`~> 0.24`).

#### 7. [BASSE] Correctifs mineurs sans CVE
castore 1.0.19 → 1.0.20, saxy 1.6.0 → 1.6.1. Reco : prochain `mix deps.update`.

### Frontend (Vue)

`npm audit` : **0 vulnérabilité**. `npm outdated` : 11 paquets en retard dont 3 majeurs (pinia, typescript, vitest). Arbre installé cohérent avec le manifest (résultats fiables). Toutes les deps déclarées sont importées : aucune dep morte.

#### 8. [BASSE] phoenix (JS) 1.8.8 → 1.8.9 (CVE non applicable)
EEF-CVE-2026-56812 (MEDIUM) vise le client Presence JS, non utilisé (aucune occurrence dans `src/`, seul `useSocket.ts` importe Socket/Channel). Reco : aligner sur 1.8.9 par cohérence, sans urgence.

#### 9. [MOYENNE] pinia 3.0.4 → 4.0.2
Un majeur de retard, pas de faille. Reco : planifier la migration (guide Pinia 4), dette qui s'accumule.

#### 10. [MOYENNE] typescript 6.0.3 → 7.0.2
Un majeur de retard, impacte `vue-tsc -b` du build. Reco : tester TS 7 avec vue-tsc (susceptible d'introduire des erreurs de typage) avant que l'écart grandisse.

#### 11. [BASSE] vitest 3.2.6 → 4.1.10
Un majeur de retard mais devDependency. Reco : migrer lors d'une passe outillage.

#### 12. [MOYENNE, performance] face-api / tfjs : poids
`@vladmandic/face-api` pèse 24 Mo dans node_modules (tfjs bundlé) ; les modèles servis font 12 Mo (`public/models`). Plus grosse dép, charge réseau/parse importante. Reco : confirmer le lazy-loading (import dynamique déjà en place) pour n'imposer ce coût qu'aux vues de reconnaissance faciale ; surveiller, ne pas retirer.

#### 13. [BASSE] Correctifs mineurs sans CVE
vue 3.5.39 → 3.5.40, vite 8.1.3 → 8.1.5, vue-router 5.1.0 → 5.2.0, prettier 3.8.4 → 3.9.5, @vitejs/plugin-vue 6.0.7 → 6.0.8, vue-tsc 3.3.6 → 3.3.7, @types/node 26.1.0 → 26.1.1. Reco : `npm update` de routine.

Synthèse deps : stacks globalement à jour et bien pinnées. Le risque réel est concentré côté backend sur trois deps exposées à des données externes (plug, phoenix, req/mint), toutes corrigeables par une montée de version. Frontend sans CVE ; sujet = dette de trois majeurs (pinia, typescript, vitest) + poids de face-api.

## Phase 8 : Documentation

### Sévérité haute

#### 1. [HAUTE] `README.md:16-20` : commande de démarrage et ports inexistants (onboarding cassé)
Le README indique `./bin/dev` démarrant "Phoenix (port 4000) et Vite (port 5173)". Or aucun `bin/` à la racine, et les ports réels sont Phoenix **4001** (`config/dev.exs:19`) et Vite **5001** (`frontend/vite.config.ts:25`). Un nouveau dev qui suit le README ne peut pas démarrer. Correction : supprimer `./bin/dev`, renvoyer vers l'approche deux-terminaux de `DEVELOPMENT.md`, corriger les ports en 4001/5001.

#### 2. [HAUTE] `docs/deployment.md:83` (+76-77, 128-129) : Dockerfile embarqué périmé, risque de perte de données
Le Dockerfile reproduit dans la doc utilise `elixir:1.18.3-erlang-27.3.4` alors que le vrai `Dockerfile:20` est en `1.20.2-erlang-29.0.3`. Surtout, le stage runtime de la doc (`:128`) ne fait que `mkdir -p /data` et ne pose que `ENV DATABASE_PATH`, tandis que le vrai `Dockerfile:68-71` crée `/data/files /data/tmp` et pose `FILES_DIR`/`TMP_DIR`. Un opérateur qui copie le Dockerfile de la doc verbatim se retrouve avec `FILES_DIR` par défaut sur `priv/files` DANS la release (effacé à chaque redéploiement). La doc se contredit (sa table d'env `:226-227` dit `FILES_DIR`/`TMP_DIR` "(set in image)" alors que son Dockerfile ne les pose pas). Correction : régénérer le bloc Dockerfile de `deployment.md` à l'identique du `Dockerfile` racine (versions, `/data/files` + `/data/tmp`, `ENV FILES_DIR`/`TMP_DIR`, stage frontend). NB : le bloc Invoice Collector ajouté récemment est présent dans les deux, mais la base était déjà désynchronisée.

#### 3. [HAUTE] `entry_controller.ex:405` : promesse OpenAPI non tenue sur la création de notes
La description `operation(:create)` affirme "Notes cannot be created here (use /api/notes)", mais `create/2` ne vérifie que le scope et appelle `Data.create_entry/2` sans garde sur `kind == "note"` (le garde `:notes_api_required` n'existe qu'en update). On peut donc créer une note via `POST /api/entries`, court-circuitant le parsing des `note_links` et laissant le graphe incohérent. Recoupe le finding 2 de la phase 2 backend. Correction : ajouter le garde `kind == "note"` dans `create` (symétrique à update), ou retirer la phrase.

### Sévérité moyenne

#### 4. [MOYENNE] `caldav.ex:6`, `carddav.ex:5`, `docs/dav.md:33-35` : "wholesale-replace" faux
Les trois textes justifient l'exclusion DAV des entrées connecteur par "their syncs wholesale-replace entries". Or `create_entries/2` fait `insert_all` avec `on_conflict: :nothing` : purement additif, jamais de remplacement (aucun `delete_all` dans les connecteurs). Recoupe le finding 1 de la phase 1 backend. Correction : reformuler avec la vraie raison (syncs additives + les apps ne round-trippent pas le payload ICS/vCard brut), sans affirmer un remplacement en masse.

#### 5. [MOYENNE] `README.md:28` et `:154` : "no admin/member hierarchy" obsolète
Le README affirme "All user accounts are equal; there is no admin/member hierarchy". Faux : `user.ex:25` (`field :admin`), `accounts.ex:12-16` (premier compte = operator/admin), plug `require_admin.ex` gardant la page Audit dont les données couvrent TOUS les utilisateurs. Correction : documenter le rôle operator (premier compte), la page Audit cross-user, nuancer "equal accounts".

#### 6. [MOYENNE] `DEVELOPMENT.md` : versions Erlang/Elixir périmées
La doc annonce "Erlang 27.2.1, Elixir 1.18.3" alors que `.tool-versions` épingle `erlang 29.0.3`, `elixir 1.20.2-otp-29` (Node OK). Correction : mettre à jour, idéalement renvoyer à `.tool-versions`.

#### 7. [MOYENNE] `DEVELOPMENT.md` (arbre "Project structure") : structure incomplète
L'arbre omet des sous-systèmes entiers de `lib/servant/` : `apps`, `api_tokens`, `audit`, `auth/throttle`, `caldav`/`carddav`/`dav`, `http`, `util` ; et côté web `schemas/`, `api_spec.ex`, la plupart des plugs. Un dev manque les apps custom, l'audit, le DAV, les API tokens. Correction : régénérer l'arbre ou le marquer explicitement "non exhaustif".

### Sévérité basse

#### 8. [BASSE] `README.md:7` et `:43` : prérequis sous-estimés
"Erlang 27+, Elixir 1.18+" reste techniquement vrai mais ne reflète plus le socle réel (29/1.20). Cosmétique, à aligner avec `.tool-versions`.

#### 9. [BASSE] `docs/deployment.md:226-227` : colonne "Required" discutable
`FILES_DIR`/`TMP_DIR` marqués "Required" alors que `storage.ex:15,19` fournit des défauts et que l'image pose des valeurs. À reclasser en "fourni par l'image / recommandé" (cohérent avec le finding 2).

### Ce qui est bien documenté

- `README.md:76-88` : table des variables d'env complète et exacte (aucune fantôme, aucune manquante).
- `docs/custom-apps.md` : contrat d'app fidèle au code (manifeste, `AppModule.mount/unmount`, `AppContext`, chemin d'install).
- `docs/dav.md` : hormis "wholesale-replace" (finding 4), description du subset protocolaire juste.
- `priv/scrapers/README.md` et `frontend/README.md` : exacts (allowlist provider, ports 4001/5001).
- OpenAPI : couverture solide, tous les controllers métier déclarent des `operation()` ; seuls dav/files/spa n'en ont pas (volontaire).

## Phase 5 : Performance (backend)

#### 1. [HAUTE] Index composite manquant `(user_id, kind, occurred_at)` sur le chemin de navigation le plus chaud
`priv/repo/migrations/20260314004217_create_entries.exs:18-21` (et `20260331000000_migrate_to_uuids.exs:262-265`) ; requête `data.ex:23-30` + tri `apply_sort/2:327`. Index existants : `(user_id, kind)`, `(user_id, source)`, `(user_id, occurred_at)`, unique `(user_id, source, external_id)`. `list_entries/2` filtre par `kind` et trie `desc: occurred_at, desc: inserted_at` : SQLite ne peut utiliser qu'un index, donc soit filtre + tri temporaire de toutes les lignes du kind, soit balayage d'index quasi complet. À 50k entries dont 20k d'un kind (photos, bank_tx), chaque page de timeline paie un tri de 20k lignes. Correction : `create index(:entries, [:user_id, :kind, :occurred_at])` (et `[:user_id, :source, :occurred_at]` si le filtre source devient chaud).

#### 2. [HAUTE] Recherche `q` en `LIKE '%terme%'` sur tout le blob JSON, non indexable
`data.ex:312-314`. Le filtre `q` (palette de commandes) fait `like(e.title, pattern) or fragment("? LIKE ?", e.data, pattern)` avec joker en tête : aucun index utilisable, SQLite balaye toutes les lignes et applique `LIKE` sur le JSON `data` complet de chacune. À 50k entries aux `data` volumineux, chaque frappe balaye des dizaines de Mo. Correction : table virtuelle FTS5 (`entries_fts` sur title + champs texte projetés, `MATCH`), ou a minima flag + debounce client sur le `LIKE data`. La vraie correction est FTS5.

#### 3. [MOYENNE] `daily_stats/2` filtre sur `inserted_at` non indexé
`data.ex:60-75`. `where(e.inserted_at >= ^cutoff)` puis `group_by date(inserted_at)` : l'index temporel est sur `occurred_at`, pas `inserted_at`, donc la fenêtre de 30 j balaye toutes les lignes et calcule `date()` par ligne. Les sparklines du dashboard le déclenchent à chaque ouverture. Correction : index `(user_id, inserted_at)`, ou porter la fenêtre sur `occurred_at` si la sémantique le permet.

#### 4. [MOYENNE] `resolve_mentions/2` charge tous les contacts et events à chaque sauvegarde de note
`notes.ex:404-417`. Sur chaque note contenant une `@[[mention]]`, la résolution charge TOUTES les entries `kind in ["contact","event"]` (avec `json_extract` par ligne) puis n'en garde que la poignée mentionnée. Un utilisateur qui synchronise un agenda (des milliers d'events) recharge tout à chaque enregistrement de note. Correction : filtrer en SQL sur les noms canoniques recherchés (ou restreindre aux contacts).

#### 5. [MOYENNE] Vignettes + JPEG d'affichage + EXIF synchrones sur le chemin de la requête d'upload
`upload_controller.ex:94-113` (via `Thumbnail.create_for_storage`/`create_display_for_storage`). Chaque upload photo bloque le process de requête sur deux passes libvips (400px + 1920px, décodage HEIC lourd) + EXIF avant de répondre. Un import massif du téléphone sérialise les uploads derrière le traitement d'image et tient la connexion ouverte. Correction : répondre immédiatement avec l'entry, générer vignette/affichage dans une `Task.Supervisor` et pousser les URLs via le canal quand prêtes (le pattern `Backfill` sert de modèle).

#### 6. [MOYENNE] `export_controller` charge toutes les entries en mémoire puis re-mappe et encode d'un bloc
`export_controller.ex:27-30`. `all_entries` matérialise tout, `Enum.map(&to_json/1)` construit une 2e liste, puis `json/2` encode le tout en mémoire. À 50k entries aux `data` volumineux, pic mémoire de plusieurs centaines de Mo ; deux exports concurrents peuvent faire tomber un petit serveur. Correction : `Repo.stream` en transaction + `send_chunked` encodé par lots.

#### 7. [MOYENNE] Pagination par OFFSET : pages profondes coûteuses
`data.ex:329-347`. `limit + offset ((page-1)*per_page)` : SQLite parcourt puis jette les lignes précédant l'offset ; combiné au tri non couvert par index (finding 1), la page 50 parcourt 2500 lignes triées pour en renvoyer 50. Correction : pagination keyset (curseur `(occurred_at, id)`) pour le défilement infini ; l'OFFSET reste acceptable pour un saut ponctuel.

#### 8. [BASSE] Boot : la config de chaque connecteur activé est lue 3 fois
`connectors.ex:153-160` (`start_all_enabled` charge déjà toutes les configs) → `start_connector/2:110-111` (2e SELECT par id) → `Worker.init/1` (3e `Repo.get`, `worker.ex:55`). Pour N connecteurs, 1 + 2N requêtes au boot. Le re-read du worker est justifié (opts périmés au restart superviseur), pas celui de `start_connector`. Correction : passer la config déjà chargée à `start_connector`.

#### 9. [BASSE] Appends de listes quadratiques dans Enable Banking
`enable_banking_connector.ex:101` (`acc ++ Enum.map(...)` dans le reduce) et `:252/:256` (`acc ++ transactions` dans la récursion de pagination). `acc ++ nouveau` recopie l'accumulateur à chaque itération : O(pages²) / O(comptes²). Correction : préfixer puis `Enum.reverse` une fois.

Note : `aggregate_entries/3` (`data.ex:112-123`) fait un décalage de fuseau par ligne en Elixir, marqué `ponytail:` avec plafond nommé (100k+ lignes) non atteint : conforme, pas compté comme dette.

## Phase 6 : Clean code (backend)

#### 1. [MOYENNE] `defp field/2` masque la macro importée `Ecto.Query.field/2`
`data.ex:210` (défini), utilisé `:198-206`, dans un module qui fait `import Ecto.Query` (`:6`). Définir un `defp field(attrs, key)` "lire une map par clé atom-ou-string" réutilise un nom très connoté Ecto pour une sémantique sans rapport. Compile (l'appel local prime) mais trompeur et fragile si une vraie expression `field/2` est ajoutée. Correction : renommer en `attr/2` ou `get_attr/2`.

#### 2. [BASSE] L'accès "clé atom-ou-string" est réimplémenté dans chaque contexte
`data.ex:210` (`field/2`) et `:321` (`stringify_keys/1`) ; `notes.ex:459-460` (`get/3`). Le même besoin (maps à clés atomes des callers internes/tests, clés strings des params controller) est résolu par un helper ad hoc dans Data et un autre dans Notes. Correction : normaliser une fois à la frontière (le controller stringifie déjà) et n'accepter qu'une forme en interne, ou un helper partagé.

#### 3. [BASSE] `apply_sort/2` et `apply_pagination/2` ne réutilisent pas `stringify_keys`
`data.ex:325-347`. `apply_filters/2` normalise les clés une fois, mais `apply_sort/2` duplique ses clauses string/atome et `apply_pagination/2` teste les deux formes manuellement. Incohérence dans un même module. Correction : `stringify_keys` en tête de `list_entries/2`, supprimer les clauses atomes redondantes.

#### 4. [BASSE] `parse_english_date` réimplémente ce que `date_time_parser` (autorisé) couvrirait
`invoice_scraper_connector.ex:235-276` (map `@months` de 25 entrées + regex + `Date.new`). AGENTS.md autorise `date_time_parser`. Le parseur maison est petit et sans dépendance, donc défendable, mais c'est une réinvention ; à réévaluer si d'autres formats de dates apparaissent.

#### 5. [BASSE, observation] La propagation de renommage des notes est à la limite haute de complexité (justifiée)
`notes.ex:311-399` (`propagate_rename/4`, `rewrite_source/4`, `resolve_targets/3`). La sémantique "à la Obsidian" est intrinsèquement complexe, bien découpée et remarquablement commentée : pas de la sur-ingénierie. Point de vigilance : premier endroit qui deviendra difficile à faire évoluer si une nouvelle forme de lien s'ajoute ; toute extension mérite des tests dédiés avant refactor.

Conformité idiomes (positif) : aucune violation AGENTS.md sur `lib/` (pas de `unless`+`else`, pas de `is_` hors guards, `true ->` en fin de cond, `@moduledoc` bien placé, alias alphabétiques). Les commentaires `ponytail:` portent tous un plafond chiffré non atteint. Code idiomatiquement propre.

## Phase 5 : Performance (frontend)

Positif (non re-signalé) : code-splitting bien fait (vues et 8 apps lazy via `import()`, face-api/tfjs et heic-to en import dynamique hors bundle initial), DataBrowser paginé serveur (50/page), Contacts virtualisé (`useVirtualList`), images de grille en `loading="lazy"`.

#### 1. [HAUTE] Grille Photos non virtualisée
`apps/photos/PhotosApp.vue:1020-1122`. La grille monte un `<div.ph-thumb>` par photo filtrée (v-for sur `g.photos`), chacun avec un bouton supprimer SVG inline. `loading="lazy"` (:1069) ne diffère que le téléchargement des octets, pas le montage du DOM. 2000 photos = 2000 cellules + 2000 SVG montés d'un coup alors que ~50 sont visibles : montage initial long, scroll saccadé, mémoire élevée. Contacts fait déjà bien avec `useVirtualList`. Correction : fenêtrer la grille (useVirtualList ou IntersectionObserver). Plus gros levier de la phase.

#### 2. [MOYENNE] Réactivité profonde sur les grands tableaux d'entries
`PhotosApp.vue:38-39`, `ContactsApp.vue:16`, `DataBrowserView.vue:17`. `allPhotos = ref<Entry[]>([])` : Vue proxifie récursivement chaque `Entry` et son `data` (+ `faces[]`, `people[]`). Aucun `shallowRef`/`markRaw` dans le code. Pour des milliers d'entries jamais mutées sur place, le coût de proxification/tracking est payé pour rien. Correction : `shallowRef` + `triggerRef` (ou `markRaw`) pour les listes en lecture ; muter par remplacement de référence (déjà le style ici).

#### 3. [MOYENNE] Helpers appelés par item et par rendu dans la grille Photos
`PhotosApp.vue:1064-1119`. `getThumbPath`, `hasGridImage`, `isVideo`, `getTags`, `getPeople` invoqués dans le v-for pour chaque photo à chaque re-rendu (sélection, filtre) ; `getTags`/`getPeople` recréent un tableau à chaque appel. Recalcul O(photos) à chaque interaction pour des valeurs stables. Correction : précalculer un view-model (thumb, isVideo, tags, people) dans le computed `groups`/`filtered`.

#### 4. [BASSE] flatpickr importé statiquement (JS + CSS)
`components/DateInput.vue:3-4`, `CalendarApp.vue:3-4`. ~45 Ko pour un champ date, importé par Photos/Trackers/Calendar. Comme ces apps sont lazy, flatpickr atterrit dans un chunk partagé (pas le bundle initial), impact modéré, mais dépendance lourde pour peu de valeur (cf. double-calendrier). Correction : natif `<input type="date">` déjà stylé, ou `import()` à l'ouverture du picker.

#### 5. [BASSE] Aucun debounce sur les filtres de recherche client
`FilesApp.vue:323`, `ContactsApp.vue:59`, `NotesApp.vue:144`, `ChecklistsApp.vue:81`. Chaque frappe déclenche un computed de filtrage O(n) sur la liste en mémoire. Un `debounce` existe (`useSocket.ts:92`) mais n'est utilisé que pour le refresh socket. Sur de grandes listes (Files non fenêtré) le filtre tourne à chaque touche. Correction : debouncer `searchQuery` (`useDebounce` de @vueuse, déjà présent).

#### 6. [BASSE] Double aller-retour après chaque mutation dans DataBrowser
`DataBrowserView.vue:172-173` et `192-193`. Après save/delete, `fetchEntries()` puis `fetchFilters()` awaités en séquence, là où kinds/sources changent rarement. Correction : `Promise.all`, ou ne rafraîchir les filtres que si un kind/source nouveau apparaît.

#### 7. [BASSE] Police VT323 chargée globalement au démarrage
`main.ts:7`. `@fontsource/vt323/index.css` importé dans l'entrée ; asset woff2 sur le chemin critique du premier rendu des titres. `font-display: swap` par défaut donc pas de blocage total. Acceptable (choix rétro) ; précharger si le FOUT gêne.

## Phase 6 : Clean code, accessibilité, i18n (frontend)

### Clean code

#### 1. [MOYENNE] Trois boucles de backfill quasi identiques dans PhotosApp
`apps/photos/PhotosApp.vue:211-225` (rebuildPreviews), `236-273` (rebuildVideoThumbs), `297-324` (scanFaces). Même structure "itérer sur des cibles, progresser `{done, total}`, pousser les erreurs, `reload()`", dupliquée trois fois avec des refs distinctes. PhotosApp cumule ~15 responsabilités dans un SFC de 1872 lignes. Correction : extraire un helper `runBatch(targets, fn, progressRef)` et sortir faces/backfill en composables `.ts` testables (comme `faces.ts`, `uploadQueue.ts`).

#### 2. [BASSE-MOYENNE] Expressions de template complexes non extraites en computed (violation Priority B)
`FilesApp.vue:737-744` (ternaire imbriqué triple du message d'état vide), `PhotosApp.vue:1146-1150`. Le style guide (Priority B) impose d'extraire les expressions complexes. Correction : `emptyMessage` computed, etc.

#### 3. [BASSE] Index de tableau utilisé comme `:key`
`PhotosApp.vue:1156` (`:key="i"` sur `faceRows`), `:1160` (`:key="j"`). Les v-for ont bien un `:key` (Priority A) mais avec l'index, non stable si réordonné/filtré : risque de corruption d'état des `FaceChip`. Ici `faceRows` reconstruit d'un bloc donc risque faible mais fragile. Correction : clé stable (`row.cluster.id` / `f.photoId`).

### Accessibilité

#### 4. [HAUTE, a11y] Divs `role="button"` `tabindex="0"` sans activation clavier
`DataBrowserView.vue:305-312` (entry-row), `ConnectorsView.vue:150` et `:209`, `DashboardView.vue:313/345/376`, `ContactDetailView.vue:523/543`. Ces éléments portent `role="button"` + `tabindex="0"` + `@click` mais aucun `@keydown.enter`/`@keydown.space` : focusables au clavier mais Entrée/Espace ne les activent pas (WCAG 2.1.1). Correction : de vrais `<button>`, ou ajouter `@keydown.enter`/`@keydown.space.prevent`.

#### 5. [HAUTE, a11y] Modales sans piège de focus, Escape incohérent
`DataBrowserView.vue:359` et `:427`, `PhotosApp.vue:1135` (modale Faces). Aucun focus-trap dans le code ; à l'ouverture le focus reste sur l'arrière-plan. Escape géré dans certaines modales (`ContactsApp.vue:166`, `ConfirmModal.vue:18`, MediaViewer) mais pas DataBrowser ni Faces. Un utilisateur clavier tabule hors de la modale vers le contenu masqué et ne peut pas toujours fermer au clavier (WCAG 2.4.3). Correction : focus dans la modale à l'ouverture, boucler Tab, restaurer le focus à la fermeture, Escape uniforme.

#### 6. [BASSE, a11y] Outline supprimé sur les champs au focus
`style.css:445-450`. `input/textarea/select:focus → outline: none`, remplacé seulement par `border-color: var(--primary)` (1px), ce qui écrase l'outline `:focus-visible` global (`:157`). Contraste possiblement < 3:1 selon le thème (WCAG 2.4.7 / 1.4.11). Correction : conserver un `box-shadow`/`outline` visible sur `:focus-visible` des champs.

### I18n

#### 7. [HAUTE, utilisateur FR] Aucun système d'i18n : chaînes user-facing en anglais codé en dur
`package.json` (pas de vue-i18n), grep `$t`/`useI18n`/`createI18n` vide. Labels, placeholders, boutons, messages figés en anglais ("Search notes...", "New Entry", `SCHEDULE_LABELS` dans `types.ts:42-49`, `'(unnamed)'`). Aucune extraction ni traduction, alors que l'app cible un utilisateur FR. Correction : introduire vue-i18n (ou un dictionnaire minimal) et externaliser les chaînes ; à défaut, assumer explicitement l'anglais-only comme décision produit.

#### 8. [MOYENNE] `relativeTime` codé en anglais, sans `Intl.RelativeTimeFormat`
`types.ts:103-117`. `'just now'`, `${m}m ago`, `${d}d ago` en dur, alors que les dates absolues passent par `toLocaleString(undefined)` (localisées). Incohérence. Correction : `Intl.RelativeTimeFormat(locale)` (localisation + pluralisation automatiques).

#### 9. [BASSE-MOYENNE] Pluralisation naïve en anglais
`DataBrowserView.vue:296` (`{{ meta.total }} entries` → "1 entries"), `TrackerCard.vue:142`. Pluriel figé, faux au singulier. Correction : `Intl.PluralRules` ou i18n.

#### 10. [BASSE] Monnaie formatée en suffixe, pas via Intl currency
`apps/finance/finance.ts:231-239`. `formatAmount` fait `toLocaleString(undefined)` (nombre localisé) puis concatène `" EUR"`/`" BTC"` au lieu de `style: 'currency'`. Choix délibéré pour gérer le crypto (BTC non supporté par Intl currency), acceptable ; conséquence : pas de symbole € ni placement localisé pour le fiat. Correction : `style: 'currency'` pour le fiat, garder le suffixe pour le crypto.
