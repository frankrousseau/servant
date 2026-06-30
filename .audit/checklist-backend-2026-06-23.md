# Checklist d'audit — Servant · **BACKEND** (Phoenix / Elixir)

**Source :** `.audit/code-audit-2026-06-22.md` (passe Backend)
**Généré le :** 2026-06-23 · **Frontend :** voir `.audit/checklist-frontend-2026-06-23.md`

> **Comment sélectionner :** cochez les cases `- [x]` des items à traiter, **ou** indiquez-moi les **IDs** (`BE-SEC-1, BE-PERF-2`), **ou** un **lot** (« tous les critiques », « tous les quick wins », « toute la phase Sécurité »). Je n'implémente qu'après votre choix, un item à la fois, avec vérification.

### Légende

- **ID** = `BE` (Backend) + thème (`ARCH`, `BUG`, `TEST`, `SEC`, `PERF`, `CLEAN`, `DEP`, `DOC`) + numéro.
- **Sévérité** : 🔴 critical · 🟠 high · 🟡 medium · ⚪ low
- **Effort** : `quick` (≤15 min, mécanique) · `small` · `medium` · `large` (transversal / risqué)

### Résumé

| | 🔴 | 🟠 | 🟡 | ⚪ | Total |
|---|---|---|---|---|---|
| Backend | 5 | 12 | 13 | 9 | 39 |

### Progression (boucle `/loop`)

Traité section par section. ✅ = fait & vérifié · ⚠️ = bloqué/décision requise · ⏭️ = sauté (risqué/large, à arbitrer).

- **2026-06-27 — Critiques backend** : BE-BUG-1 ✅, BE-BUG-2 ✅, BE-TEST-1 ✅, BE-SEC-2 ✅ · BE-SEC-1 ⚠️ (décision requise, voir note).
- **2026-06-28 — Compilation débloquée** : `libvips-dev` installé → vix compile en mode système. `mix test test/servant_web/channels/data_channel_test.exs` = **4 tests, 0 failure**. BE-BUG-1/2 + BE-TEST-1 désormais **vérifiés par tests réels** (plus seulement `mix format`).
- **2026-06-28 — Section Architecture** : BE-ARCH-1 ✅, BE-ARCH-2 ✅, BE-ARCH-4 ✅, BE-ARCH-6 ✅ · BE-ARCH-3 ⏭️ (refactor large, à arbitrer), BE-ARCH-5 ⏭️ (sera repris avec BE-CLEAN-1). Effet de bord : **BE-BUG-6 ✅** (curseurs solana/evm + token strava) et **BE-PERF-3 ✅** (doublon) résolus par le même mécanisme. Vérif : `mix compile` OK + `mix test` (133 tests, 0 failure hors échec préexistant bank_csv).
- **2026-06-28 — Section Bugs/correctness** : BE-BUG-3 ✅, BE-BUG-4 ✅, BE-BUG-5 ✅, BE-BUG-7 ✅, BE-BUG-8 ✅, BE-BUG-9 ✅. Nouveau test `rss_connector_test.exs` (9 tests). Vérif : `mix test` = **148 tests, 1 failure** (= le préexistant bank_csv). BE-BUG-7 débloque **BE-DEP-2** (retrait `:inets`, à faire en section Dépendances).
- **2026-06-28 — Section Tests & couverture** : BE-TEST-2 ✅, BE-TEST-3 ✅, BE-TEST-5 ✅, BE-TEST-6 ✅, BE-TEST-7 ✅, BE-TEST-8 ✅ · BE-TEST-4 🔶 **partiel** (Entry + Auth couverts ; connector/upload/export/app/spa restants). Support ajouté : `test/support/fixtures.ex` (`user_fixture`/`entry_fixture`), `register_and_log_in_user` dans `ConnCase`, `test/support/fake_connector.ex`. **+40 tests** → `mix test` = **188 tests, 1 failure** (préexistant bank_csv).
- **2026-06-28 — Section Sécurité** : BE-SEC-3 ✅, BE-SEC-6 ✅, BE-SEC-7 ✅, BE-SEC-8 ✅ · BE-SEC-4 ⏭️ (Cloak, large/breaking — décision), BE-SEC-5 ⏭️ (TLS verify_none — risqué, décision), BE-SEC-9 ⚠️ (policy inscription/throttle — décision), BE-SEC-10 ⏭️ (secrets dev, « non urgent »). +11 tests (`http_test.exs` SSRF, `connector_controller_test.exs` masquage) — fait aussi avancer BE-TEST-4 (contrôleur Connector). `mix test` = **199 tests, 1 failure** (préexistant).
- **2026-06-28 — Section Performance** : BE-PERF-1 ✅ (`Data.create_entries/2` insert_all + 1 broadcast agrégé `entries_changed`, utilisé par worker **et** import), BE-PERF-2 ✅ (Strava param `after` + curseur persisté), BE-PERF-5 ✅ (migration index `connector_configs(user_id)`+`(enabled)`) · BE-PERF-4 ⏭️ (miniatures async — l'upload ne crée pas l'entrée, donc coordination front requise). +3 tests batch. `mix test` = **202 tests, 1 failure** (préexistant).
- **2026-06-30 — Commit** : `42e44b2` sur `main` (sections Architecture→Performance + tests). `mix.lock` (vix/nimble_csv, préexistant) laissé hors commit.
- **2026-06-30 — Section Clean code** : BE-CLEAN-1 ✅ (`Entry.to_json/1` unique, 3 sites), BE-CLEAN-2 ✅ (`config_value`), BE-CLEAN-3 ✅ (`Servant.Util` : `strip_bom`/`parse_int`), BE-CLEAN-4 ✅ (`formats: [:json]` + retrait Gettext), BE-CLEAN-6 ✅ (`format_units` entier) · BE-CLEAN-5 ⏭️ (liste apps codée en dur — low, « si la liste grandit »). `mix test` = **202 tests, 1 failure** (préexistant).
- **2026-06-30 — Section Dépendances** : BE-DEP-1 ✅ (`mix_audit` + `deps.audit` dans `precommit`), BE-DEP-2 ✅ (retrait `:inets`), BE-DEP-3 ✅ (bandit 1.10.3→1.12.0 — **CVE DoS high/moderate corrigée** — + phoenix 1.8.8, plug 1.20, jason, castore, …) · BE-DEP-4 ⏭️ (deps « inutilisées » : dns_cluster câblé/no-op, gettext transitif — retraits low/conditionnels). ⚠️ Advisory transitive restante : `decimal` < 3.0 (DoS modéré), patché seulement en 3.0 bloqué par ecto → ignorée explicitement dans `precommit`. `mix.lock` mis à jour. `mix compile --warnings-as-errors` OK, **219 tests, 1 failure** (préexistant).
- **2026-06-30 — Section Documentation** : BE-DOC-1 ✅ (FILES_DIR/TMP_DIR/UPLOADS_DIR documentés + avertissement persistance + systemd), BE-DOC-2 ✅ (résolu par le code BE-BUG-1/2 ; bout-en-bout dépend encore de FE-ARCH-2), BE-DOC-3 ✅ (note sécurité `/files/` + reformulation multi-user), BE-DOC-4 ✅ (« email » retiré des sources), BE-DOC-5 ✅ (Node.js runtime + libvips clarifiés). README only. **Toutes les sections backend traitées.**

> ⚠️ **Échec de test préexistant** (hors périmètre) : `BankCSV.ParserTest` « returns empty for empty CSV » échoue — le parser renvoie `{:error, "Empty CSV"}` mais le test attend `{:ok, []}` (depuis le commit e68539d, N26). À trancher : corriger le test ou le parser.

> ✅ **Environnement OK** : le backend compile et les tests tournent (`libvips-dev` 8.12.1 + `VIX_COMPILATION_MODE=PLATFORM_PROVIDED_LIBVIPS` pour recompiler vix au besoin). Vérification réelle possible pour tous les correctifs backend à venir.

---

## Architecture

- [x] **BE-ARCH-1** · 🟡 medium · `evm_connector.ex:66`, `worker.ex:85` · effort: medium
      Curseur `last_block` non persisté (mémoire seule) → re-scan complet de la chaîne au redémarrage.
      Fix : persister `last_block` dans `connector_config.config` après chaque sync réussie (idem Solana/Strava). *(lié à BE-BUG-6, BE-PERF-3)*
      ✅ *Fait (2026-06-28)* : nouveau callback optionnel `persisted_config/1` sur le behaviour `Connector` (défaut `%{}`), persisté par le worker via `Connectors.persist_connector_cursor/2` après chaque sync OK (merge dans `config`). Overrides : EVM `last_block`, Solana `last_signature`, Strava `refresh_token`. Tests : `test/servant/connectors_test.exs` (7 tests, 0 failure).
- [x] **BE-ARCH-2** · ⚪ low · `connectors/base_connector.ex` · effort: small
      `BaseConnector` = connecteur de la chaîne **Base**, mais le nom suggère un connecteur abstrait → confusion.
      Fix : renommer en `BaseChainConnector` ou documenter.
      ✅ *Fait (2026-06-28)* : documenté (pas renommé — les frères suivent le motif `<Chaîne>Connector` : Arbitrum/Ethereum/…). Le moduledoc précise que l'abstrait est `EVMConnector`.
- [ ] **BE-ARCH-3** · ⚪ low · `connectors.ex` (301 l.) · effort: large
      Contexte `Connectors` surchargé (CRUD + lifecycle + sync logs + env cache + import).
      Fix : découper en `Connectors.Lifecycle` / `.Imports` / `.Env`.
      ⏭️ *Sauté (2026-06-28)* : refactor structurel large/risqué (low severity) — à arbitrer explicitement avant de découper le contexte public.
- [x] **BE-ARCH-4** · 🟡 medium · `data.ex:128-168` · effort: small
      `apply_filters/2` duplique 8 clauses atome/chaîne → un filtre ajouté côté string seulement passerait inaperçu.
      Fix : normaliser les clés une fois (`stringify_keys`) puis une seule série de clauses.
      ✅ *Fait (2026-06-28)* : `stringify_keys/1` en amont + une seule série de 4 clauses. `mix compile` OK, suite verte.
- [ ] **BE-ARCH-5** · 🟡 medium · `connector_controller.ex:163`, `auth_controller.ex`, `entry_controller.ex`, `export_controller.ex` · effort: medium
      Sérialisation JSON dispersée et reconstruite à la main par contrôleur → dérive du contrat avec `frontend/src/types.ts`.
      Fix : extraire des modules/fonctions de sérialisation partagés (source unique). *(lié à BE-CLEAN-1)*
      ⏭️ *Reporté (2026-06-28)* : sera traité avec BE-CLEAN-1 (`entry_json` unique) lors de la section Clean code, puis étendu aux autres contrôleurs.
- [x] **BE-ARCH-6** · ⚪ low · `scheduler.ex:17` · effort: small
      Boot temporisé en dur (`Process.send_after(..., 1_000)`) → fragile au démarrage chargé.
      Fix : déclencher après confirmation Repo (ou `handle_continue`).
      ✅ *Fait (2026-06-28)* : `init` retourne `{:ok, %{}, {:continue, :start_connectors}}` (Repo + Migrator démarrent avant le Scheduler dans l'arbre de supervision). `mix compile` OK.

## Bugs / correctness

- [x] **BE-BUG-1** · 🔴 critical · `data_channel.ex:6` · effort: quick
      `String.to_integer` sur un UUID → `ArgumentError` à chaque join du canal (temps réel mort, cause 1/3).
      Fix : supprimer la conversion, comparer les chaînes directement.
      ✅ *Fait (2026-06-27)* : suppression de `String.to_integer`, comparaison `socket.assigns.user_id == user_id` directe. Fichier : `data_channel.ex`. Vérif : `mix format` OK ; tests à exécuter sur ta machine (vix ne compile pas ici).
- [x] **BE-BUG-2** · 🔴 critical · `data_channel.ex:18-29` vs `useSocket.ts:40` · effort: small
      Noms d'événements front/back divergents (`entry_created/updated/deleted` vs `entry_change`) → aucun callback (cause 2/3).
      Fix : aligner noms **et** forme du payload des deux côtés. *(paire avec FE-BUG-1)*
      ✅ *Fait (2026-06-27)* : back aligné sur le contrat front existant — un seul `push(socket, "entry_change", %{type: ..., entry: ...})` (created/updated/deleted). Aucun changement front nécessaire (`useSocket.ts` écoute déjà `entry_change`). ⚠️ Le temps réel ne fonctionnera complètement qu'avec FE-ARCH-2 (réhydratation de `auth.user`), non sélectionné.
- [x] **BE-BUG-3** · 🟠 high · `invoice_scraper_connector.ex:96` · effort: small
      `System.cmd(:timeout)` inexistant → `@cmd_timeout` ignoré, script Playwright bloqué = Worker bloqué à l'infini.
      Fix : `Task` + `Task.yield/2` + `Task.shutdown/2`, ou `Port` avec timeout.
      ✅ *Fait (2026-06-28)* : `System.cmd` lancé dans `Task.async`, timeout via `Task.yield(@cmd_timeout) || Task.shutdown`. Option `:timeout` bidon retirée. ⚠️ Note : le process `node` orphelin peut subsister après timeout (kill OS complet → passerait par un `Port`, hors périmètre small). `mix compile` OK.
- [x] **BE-BUG-4** · 🟠 high · `rss_connector.ex:41` · effort: small
      `occurred_at` = `utc_now()` pour tous les articles → tri chronologique faux.
      Fix : parser `pubDate`/`dc:date`.
      ✅ *Fait (2026-06-28)* : `parse_pub_date/1` parse RFC 822 (`pubDate`, conversion d'offset → UTC) + ISO 8601 (`dc:date`/Atom), repli `now()` si illisible. Tests `rss_connector_test.exs` (offsets, GMT, ISO, repli).
- [x] **BE-BUG-5** · 🟡 medium · `solana_connector.ex:80,140` · effort: medium
      `Process.sleep` dans le GenServer (~1 s/tx) → mailbox gelée jusqu'à ~1000 s.
      Fix : throttling hors du GenServer (Task dédiée) ou file de jobs ; sinon borner+documenter.
      ✅ *Fait (2026-06-28, option « borner+documenter »)* : `@max_tx_per_sync 50` — au plus 50 tx/sync (≈50 s), le curseur `last_signature` persisté (BE-ARCH-1) reprend au sync suivant. Le `Process.sleep(500)` inter-pages subsiste (borné par `@max_pages`). Sortir le throttling du GenServer (Task dédiée) reste possible plus tard si besoin.
- [x] **BE-BUG-6** · 🟡 medium · `solana_connector.ex:103`, `evm_connector.ex:108`, `strava_connector.ex` · effort: medium
      Curseurs (`last_signature`/`last_block`) non persistés → re-scan complet au redémarrage.
      Fix : `update_connector_config` avec le nouveau curseur après sync OK. *(lié à BE-ARCH-1)*
      ✅ *Fait (2026-06-28, via BE-ARCH-1)* : curseurs Solana (`last_signature`) et EVM (`last_block`) persistés après chaque sync, + `refresh_token` Strava (rotation auparavant perdue au redémarrage). ⚠️ La re-pagination des activités Strava depuis la page 1 reste à traiter sous **BE-PERF-2** (param `after`).
- [x] **BE-BUG-7** · 🟡 medium · `rss_connector.ex:58` · effort: small
      RSS utilise `:httpc` (interdit par AGENTS.md).
      Fix : passer à `Req`/`Servant.HTTP`. *(débloque BE-DEP-2)*
      ✅ *Fait (2026-06-28)* : `fetch_and_parse/1` utilise `Req.get(url, Servant.HTTP.req_options(decode_body: false))`. Plus aucun `:httpc` dans le code. `mix compile` OK.
- [x] **BE-BUG-8** · ⚪ low · `rss_connector.ex:39`, `entry.ex:25` · effort: small
      `external_id` nil (`link || title`) → contrainte d'unicité inopérante (NULL distincts en SQLite) → doublons.
      Fix : hash de contenu en repli, ou rejeter les items sans identifiant.
      ✅ *Fait (2026-06-28)* : `external_id/1` = `link || title || "sha256:"<>hash(contenu)` → jamais nil. Tests dédiés (repli hash stable).
- [x] **BE-BUG-9** · ⚪ low · `thumbnail.ex:74-80` · effort: medium
      `backfill_missing` charge toutes les photos de tous les users en mémoire (pas de scope/pagination).
      Fix : streamer par lots (`Repo.stream` en transaction).
      ✅ *Fait (2026-06-28)* : pagination keyset par `id` (`stream_in_batches/2`, lots de 100) au lieu de `Repo.all`. Choix keyset plutôt que `Repo.stream` car SQLite gère mal un `Repo.update` pendant un curseur de stream ouvert. Forme de retour (liste) préservée → `release.ex` inchangé. `mix compile` OK.

## Tests & couverture

- [x] **BE-TEST-1** · 🔴 critical · `data_channel.ex` / `user_socket.ex` (0 test) · effort: medium
      Canal temps réel non testé → c'est pourquoi BE-BUG-1/2 n'ont jamais été détectés.
      Fix : `ChannelCase` couvrant join + émission d'événements.
      ✅ *Fait (2026-06-27)* : ajout de `test/support/channel_case.ex` et `test/servant_web/channels/data_channel_test.exs` (4 tests : join OK sur topic UUID du propriétaire, rejet sur topic d'autrui, `entry_change`/created, `entry_change`/deleted). Vérif : `mix format` OK ; **à exécuter sur ta machine** (`mix test test/servant_web/channels/data_channel_test.exs`).
- [x] **BE-TEST-2** · 🟠 high · `data.ex` (0 test) · effort: medium
      Aucun test d'isolation par utilisateur (invariant de sécurité central).
      Fix : prouver que les requêtes du user A ne voient jamais les entries de B.
      ✅ *Fait (2026-06-28)* : `test/servant/data_test.exs` (8 tests) — list/count/stats/sources/kinds par user ; `get/update/delete` d'une entrée d'autrui lève `Ecto.NoResultsError` ; les filtres ne franchissent pas la frontière user.
- [x] **BE-TEST-3** · 🟠 high · `auth.ex`, `auth_controller.ex`, `accounts.ex` (0 test) · effort: medium
      Aucun test d'auth/autorisation (login, expiration, rejet sans token, mauvais mdp).
      Fix : couvrir le plug Bearer + le flux login.
      ✅ *Fait (2026-06-28)* : `accounts_test.exs` (`authenticate_user` ok/mauvais mdp/user inconnu, `change_password`) + plug Bearer testé via `auth_controller_test.exs` (sans token → 401, token malformé → 401, token valide → 200). ⚠️ L'expiration (`max_age`) n'est pas testée (nécessiterait de forger un vieux token).
- [ ] **BE-TEST-4** · 🟠 high · contrôleurs entry/connector/upload/export/app/spa (0 test) · effort: large
      Aucun test des contrôleurs web (statuts, formes JSON, validations).
      Fix : `ConnCase` par contrôleur.
      🔶 *Partiel (2026-06-28)* : **Entry** (`entry_controller_test.exs` — CRUD, pagination, validation 422, scoping 404 via `assert_error_sent`) et **Auth** (`auth_controller_test.exs`) couverts. **Restants** : connector / upload / export / app / spa. Helpers réutilisables en place (`register_and_log_in_user`, fixtures).
- [x] **BE-TEST-5** · 🟠 high · `storage.ex` (0 test) · effort: small
      `path_safe?`/`resolve_public_path` (sécurité traversée de répertoire) non testés.
      Fix : tests de sûreté des chemins. *(lié à BE-SEC-8)*
      ✅ *Fait (2026-06-28)* : `storage_test.exs` — rejet de `..` et de la traversée URL-encodée, `:error` sur chemin sûr inexistant, résolution OK d'un fichier réel sous `FILES_DIR`.
- [x] **BE-TEST-6** · 🟡 medium · `Connectors.import_file` (0 test contexte) · effort: medium
      Chemin sync_log + stockage + comptage d'insertions non vérifié (seuls les parsers le sont).
      Fix : test d'intégration du contexte d'import.
      ✅ *Fait (2026-06-28)* : `import_file_test.exs` — import vCard réel (entrées créées + sync_log « completed » + comptage), rejet `:unsupported`. `FILES_DIR`/`TMP_DIR` isolés en tmp.
- [x] **BE-TEST-7** · 🟡 medium · `worker.ex` / `scheduler.ex` (0 test) · effort: medium
      Planification, gestion d'erreur de sync, transitions d'état non couvertes.
      Fix : tests GenServer (avec mock du module connecteur).
      ✅ *Fait (2026-06-28)* : `worker_test.exs` + `FakeConnector` — sync crée les entrées **et persiste le curseur** (valide BE-ARCH-1 de bout en bout). Synchro via `:sys.get_state/1`. (Scheduler non testé séparément.)
- [x] **BE-TEST-8** · 🟡 medium · tests connecteurs (Solana/HyperEVM/invoice_scraper) · effort: small
      Vérifier qu'aucun ne dépend du réseau réel (sinon flaky/non exécutable hors ligne).
      Fix : mocker HTTP/`System.cmd`.
      ✅ *Fait (2026-06-28)* : vérifié par inspection — aucun `Req.*`/`RPC.*`/`:httpc`/`System.cmd` dans `test/servant/connectors/` (les `https://` sont des données parsées hors-ligne). Suite complète en ~14 s sans réseau.

## Sécurité

- [ ] **BE-SEC-1** · 🔴 critical · `endpoint.ex:34`, `plugs/files_static.ex`, `storage.ex` · effort: medium
      `/files/` servi **sans authentification ni contrôle de propriété** (plug avant routeur+Auth) → fuite de fichiers privés (photos, **relevés bancaires** importés).
      Fix : servir via un contrôleur authentifié vérifiant `entry.user_id == current_user.id` (ou URLs signées). *(risqué : change le contrat d'URL ; coordonner avec le front `/files/` + proxy Vite)*
      ⚠️ **BLOQUÉ — décision requise** : les fichiers sont chargés via `<img src="/files/...">` sans en-tête `Authorization`, donc un correctif backend seul est impossible. Trois options à arbitrer : (1) URLs signées (jeton court dans la query) ; (2) auth par cookie `HttpOnly`+`SameSite` (route protégée) ; (3) jeton en query-param + vérification de propriété par préfixe de chemin. Chacune nécessite une coordination front. Non implémenté dans cette boucle.
- [x] **BE-SEC-2** · 🔴 critical · `export_controller.ex:130-148` · effort: small
      `GET /api/export/database` renvoie le **fichier SQLite entier** → tout compte aspire hash de mdp + secrets de tous.
      Fix : supprimer l'endpoint, le réserver à un admin, ou n'exporter que les données du user courant (dump filtré).
      ✅ *Fait (2026-06-27)* : route `/export/database` retirée (`router.ex`), action `database/2` supprimée (`export_controller.ex`), bouton « Database (SQLite) » et son code retirés du front (`SettingsView.vue`). `/export/entries` (JSON, user-scoped) conservé. Vérif : `mix format` OK + `vue-tsc -b` OK (front compile).
- [x] **BE-SEC-3** · 🟠 high · `connector_controller.ex:163-176` · effort: quick
      `config_json/1` renvoie `config` complet (mots de passe/tokens) dans les réponses JSON. **(quick win)**
      Fix : masquer/omettre les champs sensibles à la sérialisation.
      ✅ *Fait (2026-06-28)* : `Connectors.redact_config/1` masque les clés sensibles (`password`/`secret`/`token`/`totp`/`api_key`/`private_key`) → `••••••` dans `config_json`. Garde anti-écrasement : `update_connector_config` restaure le secret stocké quand le client renvoie le masque. Tests `connector_controller_test.exs`.
- [ ] **BE-SEC-4** · 🟠 high · `connector_config.ex:14`, `credential.ex` · effort: large
      Secrets de connecteurs stockés en clair dans `config` (le schéma `Credential` chiffré est inutilisé).
      Fix : chiffrer les champs sensibles (Cloak/Ecto encrypted type). *(dépend de BE-SEC-3 pour la non-exposition API)*
      ⏭️ *Signalé — décision requise (2026-06-28)* : refactor large + migration chiffrante des données existantes (Cloak ou type Ecto chiffré). Choix de clé/rotation + migration des configs en place à arbitrer. Non appliqué à l'aveugle. BE-SEC-3 limite déjà l'exposition API en attendant.
- [ ] **BE-SEC-5** · 🟠 high · `http.ex:21` · effort: medium
      `verify: :verify_none` désactive TLS pour **tous** les connecteurs (dont OAuth Strava) → MITM possible.
      Fix : restreindre `verify_none` aux hôtes buggés (liste blanche), vérifier ailleurs ; ou bundle CA correct.
      ⚠️ *Signalé — risqué, décision requise (2026-06-28)* : `verify_none` est un contournement **délibéré** d'un bug OTP 27 (certs valides rejetés, ex. data.gouv.fr) documenté dans `http.ex`. Réactiver la vérif par défaut risque de casser des connecteurs. Options à arbitrer : (a) liste blanche d'hôtes en `verify_none`, vérif ailleurs ; (b) bundle CA + `verify_peer`. Nécessite de connaître les hôtes réellement buggés.
- [x] **BE-SEC-6** · 🟠 high · `invoice_scraper_connector.ex:78-92` · effort: small
      `email`/`password`/`totp_secret` passés en arguments CLI → visibles dans `ps`/`/proc`.
      Fix : passer via stdin ou `env:` de `System.cmd`. *(lié à BE-CLEAN-2 / BE-BUG-3)*
      ✅ *Fait (2026-06-28)* : secrets passés via `env:` de `System.cmd` (`SCRAPER_EMAIL`/`SCRAPER_PASSWORD`/`SCRAPER_TOTP_SECRET`), seul `--provider` reste en argv. `invoice_scraper.js` lit `process.env.*` (repli argv pour compat). Plus aucun secret dans `ps`.
- [x] **BE-SEC-7** · 🟡 medium · `rss_connector.ex`, `ical_connector.ex` · effort: medium
      SSRF : URLs utilisateur récupérées sans blocage des IP privées/métadonnées cloud (`169.254.169.254`).
      Fix : valider le schéma http(s), résoudre et rejeter IP privées/loopback.
      ✅ *Fait (2026-06-28)* : `Servant.HTTP.ensure_public_url/1` (schéma http(s) + résolution DNS + rejet loopback/privé/link-local/ULA, IPv4 & IPv6, y compris `::ffff:` mappé), appliquée avant fetch dans RSS et iCal. Tests `http_test.exs`. ⚠️ Résiduel documenté : pas de protection anti DNS-rebinding (TOCTOU).
- [x] **BE-SEC-8** · 🟡 medium · `storage.ex:184` · effort: small
      `path_safe?` se limite à `not contains?("..")` → fragile.
      Fix : `Path.expand` puis vérifier que le chemin reste sous `files_root()`. *(lié à BE-TEST-5)*
      ✅ *Fait (2026-06-28)* : `path_safe?` résout via `Path.expand(relative, root)` et exige que le résultat reste sous `files_root()` (bloque `..` **et** chemins absolus). Couvert par `storage_test.exs` (BE-TEST-5).
- [x] **BE-SEC-9** · 🟡 medium · `auth_controller.ex` (`register`/`login`) · effort: small
      Inscription ouverte + aucune limite de tentatives → un inconnu s'inscrit puis (avec BE-SEC-2) aspire tout.
      Fix : désactiver/whitelister l'inscription ; throttling sur `login`.
      ✅ *Fait en partie (2026-06-30)* : flag `REGISTRATION_ENABLED` (défaut `true` = comportement inchangé ; `false` → `register` renvoie 403). Config dans `config.exs` (défaut) + `runtime.exs` (env) ; documenté README ; test 403 ajouté. ⏭️ **Reste** : throttling `login` (anti-brute-force) — nécessite un rate-limiter (ex. dép `hammer`), à décider séparément.
- [ ] **BE-SEC-10** · ⚪ low · `dev.exs:23`, `endpoint.ex:11`, `config.exs:23` · effort: quick
      `secret_key_base`/`signing_salt` dev committés (prod via env = OK).
      Fix : non urgent ; éviter de committer le secret dev.
      ⏭️ *Sauté (2026-06-28)* : marqué « non urgent » par l'audit (prod via env = OK). Changer le secret dev invaliderait les tokens de dev existants pour un gain quasi nul. À faire seulement si tu veux nettoyer l'historique des secrets dev.

## Performance

- [x] **BE-PERF-1** · 🟠 high · `worker.ex:78`, `connectors.ex:208-211` · effort: medium
      Insertions une-par-une + 1 broadcast PubSub **par entry** → milliers d'INSERT + flood du canal (contention SQLite).
      Fix : `Repo.insert_all` par lots (`on_conflict: :nothing`) + un seul broadcast agrégé.
      ✅ *Fait (2026-06-28)* : `Data.create_entries/2` (`insert_all`, `on_conflict: :nothing` sur `(user_id, source, external_id)`) + **un seul** broadcast `{:entries_changed, %{count}}` ; `DataChannel` pousse l'évènement `entries_changed` (ignoré par le front actuel → pas de régression, prêt pour FE-BUG-1). Worker **et** import migrés. Tests : `data_test.exs` (batch + dedup), worker/import toujours verts.
- [x] **BE-PERF-2** · 🟠 high · `strava_connector.ex:137-153` · effort: medium
      `fetch_all_activities` repart toujours de la page 1 → re-pagination complète chaque heure (rate-limit).
      Fix : mémoriser/persister `after` (timestamp de la dernière activité). *(lié à BE-BUG-6)*
      ✅ *Fait (2026-06-28)* : param `&after=<epoch>` + curseur `last_activity_after` (avancé au max des `start_date`), persisté via `persisted_config` (BE-ARCH-1). ⚠️ Logique de fetch à vérifier en runtime (pas de mock réseau Strava).
- [x] **BE-PERF-3** · 🟡 medium · Solana/EVM (curseurs) · effort: medium
      Re-scan complet au redémarrage (curseurs non persistés) → re-fetch massif explorer/RPC.
      Fix : persister le curseur. *(doublon de BE-ARCH-1/BE-BUG-6)*
      ✅ *Fait (2026-06-28, via BE-ARCH-1)* : doublon résolu — curseurs Solana/EVM persistés.
- [ ] **BE-PERF-4** · 🟡 medium · `upload_controller.ex:53,128`, `thumbnail.ex` · effort: medium
      Génération de miniature synchrone dans la requête d'upload → réponse retardée sur grosses images.
      Fix : générer en `Task.Supervisor` et pousser `thumb_path` via le canal une fois prêt.
      ⏭️ *Signalé — coordination front (2026-06-28)* : `upload_controller` ne crée **pas** l'entrée (il renvoie `thumb_path` au front qui crée l'entrée ensuite). Générer en async impliquerait de créer l'entrée d'abord puis pousser le thumb via canal — donc un changement de flux côté front. À traiter avec le front (lié à FE-PERF-1/ARCH-1).
- [x] **BE-PERF-5** · ⚪ low · migrations `connector_configs` · effort: quick
      Pas d'index sur `connector_configs(user_id)` / `(enabled)`. **(quick win)**
      Fix : `create index(:connector_configs, [:user_id])`.
      ✅ *Fait (2026-06-28)* : migration `20260628155746_add_indexes_to_connector_configs` — index sur `[:user_id]` et `[:enabled]`. `mix ecto.migrate` OK.

## Clean code

- [x] **BE-CLEAN-1** · 🟡 medium · `entry_controller.ex:90`, `data_channel.ex:32`, `export_controller.ex:10` · effort: small
      `entry_json` dupliqué 3× (le canal omet déjà `inserted_at`/`updated_at`).
      Fix : fonction unique (`Servant.Data.Entry.to_json/1` ou module `EntryJSON`). *(lié à BE-ARCH-5)*
      ✅ *Fait (2026-06-30)* : `Servant.Data.Entry.to_json/1` (version complète) utilisée par entry_controller, export_controller et data_channel (le canal envoie désormais aussi les timestamps — toléré par le front). Couvre partiellement BE-ARCH-5 (reste : sérialisation bespoke des contrôleurs connector/auth).
- [x] **BE-CLEAN-2** · 🟡 medium · `strava_connector.ex:35-37`, `invoice_scraper_connector.ex:34-36` · effort: small
      Accès config incohérent : `Map.get` (chaîne seule) vs `config_value` (chaîne+atome) → init échoue silencieusement sur clés atomes.
      Fix : utiliser `config_value` partout.
      ✅ *Fait (2026-06-30)* : `config_value` partout dans les `init` de Strava (client_id/secret/refresh_token/last_activity_after) et invoice_scraper (provider/email/password/totp_secret).
- [x] **BE-CLEAN-3** · ⚪ low · `connectors.ex:198` & `bank_csv/parser.ex:198` ; `data.ex:195` & `entry_controller.ex:107` · effort: small
      Helpers dupliqués (`strip_bom/1`, `parse_int/2`).
      Fix : factoriser dans un module utilitaire partagé.
      ✅ *Fait (2026-06-30)* : `Servant.Util.strip_bom/1` + `parse_int/2` ; 4 sites redirigés (connectors, bank_csv/parser, data, entry_controller).
- [x] **BE-CLEAN-4** · ⚪ low · `servant_web.ex:40` · effort: quick
      `controller` déclare `formats: [:html, :json]` + `use Gettext` superflus (API-only). **(quick win)**
      Fix : `formats: [:json]`.
      ✅ *Fait (2026-06-30)* : `formats: [:json]` + `use Gettext` retiré (aucun usage gettext dans les contrôleurs). Compile + suite OK.
- [ ] **BE-CLEAN-5** · ⚪ low · `app_controller.ex:5-38` · effort: small
      Liste d'apps codée en dur, dupliquée probablement côté front (`apps/registry.ts`).
      Fix : dériver d'une config partagée si la liste grandit.
      ⏭️ *Sauté (2026-06-30)* : low + conditionnel (« si la liste grandit »). Partage front/back = coordination ; pas justifié pour la taille actuelle.
- [x] **BE-CLEAN-6** · ⚪ low · `tx_format.ex:44` · effort: small
      `format_units` en flottant (wei/18 déc.) → perte de précision possible à l'affichage.
      Fix : arithmétique entière/`Decimal` pour le rendu.
      ✅ *Fait (2026-06-30)* : réécrit en arithmétique entière (div/rem + padding/slice), gère le signe. Tests parsers (HyperEVM/Solana « 1.5 ») toujours verts.

## Dépendances

- [x] **BE-DEP-1** · 🟡 medium · `mix.exs` · effort: small
      Pas de scan CVE automatisé.
      Fix : `{:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}` + ajout à l'alias `precommit`.
      ✅ *Fait (2026-06-30)* : `mix_audit` ajouté (dev/test) + `deps.audit` dans `precommit`. A immédiatement détecté la CVE bandit (→ BE-DEP-3).
- [x] **BE-DEP-2** · 🟡 medium · `mix.exs:23`, `rss_connector.ex:58` · effort: small
      `:inets`/`:httpc` requis seulement à cause de RSS.
      Fix : migrer RSS vers `Req` (BE-BUG-7) puis retirer `:inets` de `extra_applications`.
      ✅ *Fait (2026-06-30)* : `:inets` retiré de `extra_applications` (RSS migré en BE-BUG-7 ; aucun `:httpc`/`:inets` restant). `:ssl` conservé.
- [x] **BE-DEP-3** · ⚪ low · `mix.exs` / `mix.lock` · effort: small
      Mises à jour patch alignées : `phoenix 1.8.5→1.8.8`, `bandit 1.10.3→1.12.0`, `jason`/`castore`. **(quick win)**
      Fix : `mix deps.update` ciblé (revoir contraintes `~>` pour `ecto_sqlite3`/`req`).
      ✅ *Fait (2026-06-30)* : `mix deps.update bandit phoenix jason castore` → bandit 1.12.0 (**CVE DoS résolue**), phoenix 1.8.8, plug 1.20.1, thousand_island 1.5, decimal 2.4.1, telemetry 1.4.2. Compile + suite OK. ⚠️ Reste `decimal` < 3.0 (advisory transitive, bloquée par ecto) — ignorée dans `precommit` avec note.
- [ ] **BE-DEP-4** · ⚪ low · `mix.exs` · effort: small
      Deps peu utilisées (`dns_cluster`, `gettext`) ; `date_time_parser` autorisé mais inutilisé.
      Fix : retirer les inutiles si on vise la minceur ; envisager `date_time_parser` pour simplifier le parsing de dates.
      ⏭️ *Sauté (2026-06-30)* : `dns_cluster` est câblé dans l'arbre de supervision (no-op avec `:ignore`), `gettext` reste tiré transitivement → retraits à faible valeur et conditionnels. `date_time_parser` n'est pas dans les deps (sous-point caduc) ; RSS parse déjà les dates en interne (BE-BUG-4).

## Documentation

- [x] **BE-DOC-1** · 🟠 high · `storage.ex:14-20`, `README.md` · effort: quick
      `FILES_DIR`/`TMP_DIR`/`UPLOADS_DIR` non documentés → fichiers atterrissent dans la release → **perdus au redéploiement**. **(quick win)**
      Fix : documenter ces variables dans README + unit systemd.
      ✅ *Fait (2026-06-30)* : 3 vars ajoutées au tableau des vars optionnelles + avertissement « persiste FILES_DIR/DATABASE_PATH hors release » + lignes `Environment=` dans l'unité systemd.
- [x] **BE-DOC-2** · 🟠 high · `README.md:10` · effort: quick
      « Real-time » annoncé fonctionnel alors que le canal est cassé.
      Fix : réparer (BE-BUG-1/2) ou retirer l'affirmation en attendant.
      ✅ *Fait (2026-06-30)* : résolu en **réparant le code** (BE-BUG-1/2) — le canal pousse bien les changements. Le bout-en-bout après rechargement de page dépend encore de FE-ARCH-2 (front).
- [x] **BE-DOC-3** · 🟠 high · `README.md:9` · effort: quick
      Confidentialité multi-utilisateur surévaluée (contredite par BE-SEC-1/2).
      Fix : corriger le code (prioritaire) ou documenter la limite.
      ✅ *Fait (2026-06-30)* : BE-SEC-2 corrigé (dump global supprimé) ; reformulation « requêtes scopées par user » + **note sécurité explicite** sur `/files/` non authentifié (BE-SEC-1, en attente de décision).
- [x] **BE-DOC-4** · 🟡 medium · `README.md:3` · effort: quick
      « email » listé comme source sans connecteur email.
      Fix : retirer ou marquer « à venir ».
      ✅ *Fait (2026-06-30)* : « email » retiré de la liste d'exemples (remplacé par banking/photos/health/calendar/contacts/blockchain).
- [x] **BE-DOC-5** · 🟡 medium · `README.md:18` · effort: quick
      Contradiction Node.js runtime (build-time only vs invoice_scraper exécute `node` au runtime).
      Fix : préciser que Invoice Collector requiert Node.js + `npm install` dans `priv/scrapers/`.
      ✅ *Fait (2026-06-30)* : précisé que Node.js est requis au runtime pour l'Invoice Collector (+ `npm install` dans `priv/scrapers/`) ; ajout de `libvips` (miniatures) aux prérequis runtime.
