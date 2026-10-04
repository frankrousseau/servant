# Audit de code - Servant

**Date :** 2026-07-16, élagué le 2026-08-18, addendum CardDAV le 2026-10-04 (voir en fin de fichier)
**Périmètre :** dépôt complet `servant` (backend Phoenix/Elixir + frontend Vue 3 SPA)
**Contexte :** second audit complet; le précédent (2026-06-22) et l'intermédiaire (2026-07-03)
ont été supprimés du dossier après remédiation (l'historique reste dans git). Les items encore
ouverts de leurs checklists sont repris dans `checklist-2026-08-18.md`.

> Audit en lecture seule. Ce fichier est le livrable, élagué : le 2026-08-18, chaque finding a
> été revérifié dans le code (HEAD `1087a25`). Les findings corrigés ont été retirés; les
> partiels portent une ligne "Reste :". La checklist de suivi est `checklist-2026-08-18.md`.
>
> Retirés comme corrigés lors de l'élagage : backend, modules hyperevm/ morts supprimés,
> curseur persisté aussi en branche erreur (refresh token Strava), WorkerSupervisor en
> rest_for_one + log des échecs de boot, delete_entry_file supprime display_path,
> claimable_keys sur les liens ambigus, sync_context dans les logs du worker, cleanup de la
> rotation photo en branche erreur, with_body gère {:more,...} en 413 et le delete DAV est
> matché, unescape vCard ordonné (placeholder d'abord), garde kind "note" dans create_entry,
> Process.alive? retiré des tests, log_rounds: 1 en test, index (user_id, kind, occurred_at) et
> (user_id, inserted_at), field/2 renommé get_attr/2, montées plug 1.20.3 / phoenix 1.8.9 /
> req 0.6.3 / castore 1.0.20, toute la phase documentation (README, deploy.md, development.md,
> moduledocs "wholesale-replace"); frontend, defineVueApp partagé, report d'erreur global
> (errorHandler + unhandledrejection), try/catch/finally sur les éditions groupées Photos,
> gardes de séquence et in-flight des Trackers, flag alive des boucles longues, flatpickr sur
> type="text", double passe DST de zonedToUtcISO, deep-link photo hors filtre ignoré, erreurs
> de join socket remontées, onerror FaceChip, safeUrl + noopener sur les URLs de facture (XSS
> fermée), avatars vCard locaux + CSP img-src 'self' data:, VT323 retirée, modales en <dialog>
> natif, focus-visible restauré sur les champs.

---

# Synthèse (état au 2026-08-18)

## Résumé exécutif

La passe de remédiation de l'été a fermé l'essentiel de ce qui était exploitable ou perdait des
données : la XSS stockée des factures, les CVE backend, les curseurs et l'effondrement possible
du superviseur de connecteurs, les MatchError DAV, la totalité de la dette documentaire, et
l'accessibilité structurelle (modales natives, activation clavier, focus visible). Trois blocs
restent entiers :

1. **Les tests.** Le refactor front (stores/, api/) a déplacé du code non testé sans le couvrir;
   côté backend, cycle de vie des connecteurs, planification, socket et préconditions If-Match
   restent sans filet. C'est le plus gros écart entre l'état du code et ce que la CI garantit.
2. **La performance.** Recherche LIKE sur le blob JSON, grille Photos non virtualisée, pipeline
   d'upload synchrone, export en mémoire : rien de bloquant à l'échelle actuelle, tout croît
   avec l'historique.
3. **Les décisions d'architecture.** Apps installées same-origin (confiance totale), i18n
   anglais-only, syncs insert-only qui ne répercutent jamais une modification amont : trois
   trade-offs à trancher explicitement plutôt qu'à laisser en l'état par défaut.

## Top priorités restantes

| # | Sévérité | Constat | Réf |
|---|---|---|---|
| 1 | Haute | SSRF via `git clone` d'une URL d'app + sortie git réfléchie | N1 |
| 2 | Haute | Zombies node/Chromium du scraper après timeout (RAM du conteneur) | B2-2 |
| 3 | Haute | Recherche `LIKE` sur tout le JSON, non indexable (FTS5 à introduire) | P2 |
| 4 | Haute | Trous de tests : socket, lifecycle connecteurs, If-Match, store auth, guards, pagination apps | T1-T5, FT1-FT5 |
| 5 | Haute | Grille Photos non virtualisée (2000 cellules montées d'un coup) | FP1 |
| 6 | Moyenne | Syncs insert-only : les modifications amont ne se propagent jamais | B1-1 |
| 7 | Moyenne | Apps installées same-origin : compromission de session par design (à trancher) | N8/FS1 |

## Quick wins restants

- **`rm erl_crash.dump`** : le dump du 03-07 est toujours sur disque avec `secret_key_base` et
  un `refresh_token` (le `.dockerignore` l'exclut désormais, mais le fichier existe encore);
  supprimer et faire tourner les secrets concernés (N6).
- **Garde `kind == "note"` dans `create_entries`** : le chemin bulk accepte encore ce que
  `create_entry` refuse (B1-2).
- **`html: false` explicite** dans les deux constructeurs MarkdownIt (FS5).
- **`Promise.all`** sur `fetchEntries`/`fetchFilters` du DataBrowser (FP6).
- **`noopener`** sur le `window.open` restant de FilesApp (FS4).
- Resserrer `{:ecto_sqlite3, ">= 0.0.0"}` et aligner `{:req, "~> 0.5"}` sur la version réelle
  (DEP).

---

# PASSE BACKEND

## Phase 1 : Architecture

#### B1-1 [HAUTE, partiel] Les syncs connecteurs sont insert-only : les modifications amont ne se propagent jamais
`lib/servant/data.ex:203` : `create_entries/2` insère avec `on_conflict: :nothing`, et rien ne
supprime ni ne remplace les entries d'une source lors d'un re-sync. Un événement déplacé dans un
flux iCal, un contact corrigé dans une source vCard ou un commit amendé gardent pour toujours
leur première version (même `external_id`, données ignorées). Correction : pour les connecteurs
à contenu mutable (ical, vcard au minimum), `on_conflict: {:replace, [...]}` par connecteur
(ex. callback `upsert_strategy/0`).
Reste : les moduledocs CalDAV/CardDAV mensongers ont été corrigés; la stratégie d'upsert par
connecteur n'existe toujours pas.

#### B1-2 [BASSE, partiel] Le contournement du context Notes est bloqué partout sauf en bulk
`lib/servant/data.ex:156-162` garde désormais `create_entry` (miroir de l'update), mais
`create_entries`/`entry_row` (`data.ex:194-229`) accepte encore `kind: "note"` sans garde : une
note créée en bulk échappe à `Servant.Notes` (pas de note_links, pas de slug).
Reste : couvrir le chemin bulk.

#### B1-3 [BASSE] TLS non vérifié pour les fetch de flux rss/ical/vcard
`rss_connector.ex:73`, `ical_connector.ex:104`, `vcard_connector.ex:81` : `verify: false` en dur
pour toutes les requêtes de ces trois connecteurs, alors que `Servant.HTTP` vérifie par défaut.
Aucun secret transmis (empoisonnement de contenu possible, pas de vol de credential).
Correction : limiter `verify: false` à une allow-list d'hôtes touchés par la régression OTP 27,
ou retomber en `verify: false` seulement sur échec `key_usage_mismatch`.

#### B1-4 [MOYENNE] Modifier une config connecteur n'a aucun effet sur un worker en cours
`lib/servant/connectors.ex:58-64` écrit en DB seulement; le worker fige config et schedule à
l'init et ne relit rien. Changer une URL, un token, le schedule ou `enabled: false` via l'API
répond 200 sans effet jusqu'à un stop/start manuel; seul le flux Enable Banking redémarre
explicitement le worker (`connector_controller.ex:316-318`). Correction : dans
`update_connector_config`, si un worker tourne (`Registry.lookup`), le redémarrer (et
démarrer/arrêter selon la nouvelle valeur d'`enabled`).

#### B1-5 [MOYENNE] DAV : collections rechargées entières en mémoire, avec N+1 par requête
`lib/servant/caldav.ex:32-53` : `events/2` et `get_event/3` rechargent tous les événements du
user à chaque appel. Un PROPFIND Depth:1 recharge une fois par calendrier, un REPORT multiget de
N hrefs fait N rechargements complets (`dav_controller.ex:295`). Les clients DAV pollent le ctag
en continu : coût O(calendriers x événements) par poll. Correction : charger une fois par
requête et passer la liste, ou pousser le filtre en SQL (`json_extract`). Même schéma CardDAV.

#### B1-6 [MOYENNE] Trois implémentations iCal qui divergent sur la sémantique des fuseaux
`lib/servant/caldav/ics.ex` (parse + génération, TZID rigoureux),
`ical_connector.ex:113-215` (parser maison), `export_controller.ex:69-146` (génération).
Divergence réelle : une heure flottante est ancrée dans le fuseau utilisateur côté CalDAV
(`ics.ex:132-148`) mais traitée comme UTC côté connecteur (`ical_connector.ex:215`). Le
connecteur jette aussi les paramètres DTSTART, donc les TZID (la base tz est pourtant
disponible depuis l'ajout de `{:tz, "~> 0.28"}`). Correction : extraire un module
`Servant.ICal` utilisé par les trois, aligner la règle des heures flottantes, résoudre les TZID.

#### B1-7 [MOYENNE] Le format d'erreur JSON réel ne correspond pas au schéma OpenAPI déclaré
`schemas/error.ex:22` déclare `required: [:error]`, mais trois formes coexistent :
`%{error: ...}`, `%{errors: %{detail: ...}}` (error_json.ex:19-21, fallbacks auth), et
`%{errors: %{champ: [...]}}` (422 changeset). Correction : documenter les variantes (schémas
`Error` vs `ValidationError`) ou normaliser ErrorJSON et les fallbacks d'auth.

#### B1-8 [MOYENNE, partiel] Sync GitHub non bornée : un arrêt en plein backfill perd la progression
`github_connector.ex:117-138` déroule tout l'historique en une sync; le curseur n'atteint la DB
qu'en fin de sync complète. Atténuation en place : sur erreur mi-backfill avec `acc != []`, les
entries acquises sont écrites, mais le curseur ne progresse pas (refetch complet au sync
suivant). Correction : persister le curseur à chaque fenêtre ou borner les fenêtres par sync
comme Solana (`@max_tx_per_sync`).

#### B1-10 [BASSE] Le behaviour Connector impose trois callbacks que rien ne consomme
`connector.ex:13-15` : `name/0`, `kind/0`, `required_credentials/0` implémentés par les 15
connecteurs, aucun appelant runtime. Contrat mort qui laisse croire à une validation
inexistante. Correction : supprimer ou brancher réellement.

#### B1-11 [BASSE] Payload JSON utilisateur dupliqué quatre fois dans AuthController
`auth_controller.ex:61-70` (register), `:198-207` (issue_session), `:447-462` (me),
`:538-552` (update_profile) : quatre maps à la main, ensembles de champs divergents.
Correction : un helper `user_json(user, :session | :full)` unique. Recoupe le chantier plus
large de sérialisation partagée (BE-ARCH-5 dans la checklist).

#### B1-12 [BASSE] Accès config incohérent : `Map.get` direct au lieu de `config_value/2`
`ical_connector.ex:27`, `vcard_connector.ex:34`, `solana_connector.ex:59-61` mélangent les deux
styles dans un même `init/2`. Correction : uniformiser sur `config_value`.

## Phase 2 : Bugs et observabilité

#### B2-2 [HAUTE, partiel] Timeout du scraper = processus node/Chromium zombie
`invoice_scraper_connector.ex:140-150`. `Task.shutdown` tue le process Elixir propriétaire du
port mais pas le processus OS : un Playwright suspendu survit au timeout avec tout son Chromium
(centaines de Mo); chaque sync `every_day` peut laisser un couple node+Chromium orphelin.
La clause `{:exit, reason}` manquante a été ajoutée (`:163-164`), le crash du worker est réglé.
Reste : superviser le process OS (MuonTrap/erlexec) ou wrapper shell qui tue son fils sur EOF
stdin.

#### B2-3 [HAUTE, partiel] Enable Banking : les échecs par compte ne remontent pas à l'UI
`enable_banking_connector.ex:111-128`. Les erreurs par compte sont désormais loguées, mais dès
qu'un compte renvoie des données le sync retourne `{:ok, ...}` : sync_log "completed",
`config.error` remis à nil. Un consentement partiellement révoqué ampute le suivi en silence
côté interface. Reste : propager les erreurs partielles (statut "completed_with_errors" ou
`config.error` renseigné).

#### B2-7 [MOYENNE, partiel] Table `sync_logs` jamais purgée
Le rescue autour de `run_sync` existe désormais (`worker.ex:119-127`, sync_log marqué failed).
Reste : aucune rétention sur `sync_logs` (la purge quotidienne du Scheduler ne concerne que
`connector_environments`); un schedule "continuous" crée ~17 000 lignes/jour.

#### B2-9 [MOYENNE, observabilité] Le backfill média est totalement muet
`media/backfill.ex:31-36` : `run/1` jette les `{:ok, id}`/`{:error, id, reason}` de
`backfill_missing/1` (aucun log, aucun compteur); une photo qui échoue échoue identiquement et
silencieusement à chaque relance. `running?/1` reste faux entre `start/1` et l'enregistrement
Registry fait dans la task. Correction : résumé `ok=N failed=M` + warning par échec; corriger
la fenêtre de `running?`.

#### B2-10 [MOYENNE] Préconditions PUT DAV évaluées sur une autre ressource que celle écrite
`dav_controller.ex:426` vérifie If-None-Match/If-Match contre `get_event(u.id, cal, name)`
(scopé calendrier), mais `resolve_target` (`caldav.ex:100-105`) re-résout par filename puis par
UID sur TOUS les calendriers : `If-None-Match: *` peut passer puis écraser l'événement d'un
autre calendrier sans 412. Correction : résoudre la cible une fois dans le contrôleur et
l'utiliser pour la précondition.
Même schéma côté CardDAV depuis le 2026-10-04 : la précondition est évaluée sur
`get_contact(u.id, name)` (par nom de fichier) alors que `resolve_target` (`carddav.ex`)
rapproche aussi par UID sur tous les contacts exposés; un `If-None-Match: *` passe puis met à
jour le contact trouvé par UID. Comportement voulu pour un client qui re-pousse sa carte, mais
la correction ci-dessus (résoudre une fois, tester la précondition sur la cible) vaut pour les
deux arbres.

#### B2-14 [BASSE] Anti-replay TOTP non atomique
`accounts.ex:200-212` : lecture de `totp_last_used_at` puis écriture après validation; deux
requêtes concurrentes avec le même code peuvent passer toutes deux. Correction : update
conditionnel via `Repo.update_all ... WHERE totp_last_used_at = ancienne valeur` et vérifier le
nombre de lignes.

#### B2-15 [BASSE, partiel] Le canal d'erreurs client peut noyer le ring buffer d'audit
`client_error_controller.ex` : le crash sur message non-string est corrigé (`is_binary` +
`inspect`), mais toujours aucun rate-limit : 500 requêtes évincent les vraies erreurs serveur
du `LogBuffer` (cap 500). Reste : throttle par user (le `Servant.Auth.Throttle` existant
convient).

## Phase 3 : Tests et couverture

Repères actuels : 638 tests backend verts, `log_rounds: 1` en place. Les trous ci-dessous
restent ouverts.

#### T1 [HAUTE] L'authentification du socket n'est jamais exercée
`user_socket.ex:9` : `connect/3` porte "a revoked token can't open a socket", mais
`data_channel_test.exs:16-18` contourne `connect/3` via `Phoenix.ChannelTest.socket/3`. Test à
écrire : `connect(UserSocket, %{"token" => token})` valide, sans token, puis après
`bump_token_version/1`.

#### T2 [HAUTE] Le cycle de vie des connecteurs via l'API est presque entièrement non testé
`connector_controller_test.exs` (5 tests : redaction + scoping). `create`, `delete`, `sync`,
`start`, `stop`, `eb_auth_url`/`eb_exchange`, `logs`, `schedules`, `import_file` sans test
HTTP. Test : cycle complet via l'API (POST crée+démarre, POST /sync, GET /logs, DELETE puis
`sync_now == {:error, :not_running}`).

#### T3 [HAUTE] La planification périodique n'a aucun filet
Tous les tests worker sont en `"on_demand"`; `arm_timer/1` et `schedule_interval_ms/1` jamais
exécutés. Si la branche erreur de `run_sync` perdait son `schedule_sync`, un connecteur
planifié s'arrêterait après son premier échec, CI verte. Tests : unitaires sur
`schedule_interval_ms/1`, worker "every_hour" ré-armé après succès ET après échec.

#### T4 [HAUTE] Redémarrage au boot et environnement partagé non testés
`start_all_enabled/0`, `get_env`/`put_env`, `cleanup_expired_env/0` : aucune occurrence dans
`test/`. Tests : deux configs (enabled/disabled) puis `start_all_enabled()`; `put_env` expiré
puis `cleanup_expired_env()` renvoie nil.

#### T5 [HAUTE] La précondition If-Match n'est jamais testée
Aucun `If-Match` dans `test/` (grep 0 hit). C'est la protection contre l'écrasement concurrent
téléphone/app. Test : PUT initial, PUT `If-Match: <etag>` (204), PUT et DELETE
`If-Match: "stale"` (412, ressource intacte).

#### T6 [MOYENNE, partiel] Le test de génération de vignettes accepte `:error` comme succès
`thumbnail_test.exs:24-26` garde son `case ... :error -> IO.puts("Skipping...")` : si libvips
casse, le test reste vert. `Exif.extract` est désormais couvert (`exif_test.exs`). Reste :
`@tag :vips` exclu explicitement plutôt qu'un case silencieux.

#### T7 [MOYENNE] Le chemin git réel de l'installation d'apps n'est pas exercé
`git_clone` et `update_from_git` sans test au-delà du rejet non-https / `:not_found`.
Suggestion : test `:tmp_dir` clonant un bare repo local créé dans le test.

#### T8 [MOYENNE] Les flux HTTP des connecteurs OAuth sont sans filet
Aucun `Req.Test` sous `test/servant/connectors/` (il est pourtant utilisé ailleurs : ai_test,
agents_test). Rotation du refresh_token Strava, pagination GitHub/GitLab, erreurs d'API non
simulées. Suggestion : happy path + 401 de refresh sur au moins un connecteur OAuth.

#### T9 [MOYENNE] `update_avatar/2` n'a aucun test
`accounts.ex:110`. Ni le mapping content-type/extension, ni le stockage, ni le cas type
exotique (fallback ".jpg") ne sont couverts.

#### T12 [BASSE] Les tests TOTP dépendent de l'horloge réelle
`auth_controller_test.exs:239,266,316,325` : `NimbleTOTP.verification_code(secret)` sans
`time:` explicite; flake possible au basculement de fenêtre 30 s.

## Phase 4 : Sécurité

Les correctifs de juin restent tous en place (tableau de preuves retiré à l'élagage, voir git).

#### N1 [MOYENNE] SSRF non gardé sur `install_from_git`
`apps.ex:208-216` : `validate_repo_url/1` vérifie seulement le schéma `https://`, sans
`Servant.HTTP.ensure_public_url/1`; `git_clone/2` renvoie au client la sortie d'erreur tronquée
à 500 caractères (`:227`). Un utilisateur authentifié peut faire ouvrir une connexion vers le
réseau interne et cartographier les services via les messages d'erreur. Correction :
`ensure_public_url` dans `validate_repo_url/1`, ne pas réfléchir la sortie brute de git.

#### N2 [MOYENNE] TOCTOU / DNS rebinding dans `ensure_public_url`
`http.ex:43-76` : la garde résout le hostname puis vérifie les IP, mais Req re-résout au moment
de la requête. Limite désormais documentée dans le moduledoc, mais exploitable (TTL court).
Correction : résoudre une fois et se connecter par IP (Host fixé), ou transport custom rejetant
les IP privées à la connexion.

#### N4 [BASSE] L'allow-list d'upload ne rejette pas les types non listés
`upload_controller.ex:18-30, 151-154` : le moduledoc annonce une "type allow-list" mais
`@allowed_types` ne sert qu'au mapping type/extension; un content_type inconnu retombe sur
`Path.extname` et est accepté. Pas de lecture des magic bytes non plus (le type de fichier est
celui déclaré par le client). Correction : rejeter hors allow-list (422) ou aligner le
moduledoc; idéalement sniffer les magic bytes.

#### N5 [BASSE] Verrouillage de compte par le throttle de login (DoS)
`auth_controller.ex:150` : clé `"login:" <> downcase(username)` seule, sans limiteur par IP sur
login. Qui connaît un nom d'utilisateur peut le maintenir verrouillé en boucle. Correction :
coupler à un throttle par IP ou backoff exponentiel.

#### N6 [BASSE, partiel] erl_crash.dump contient des secrets
Le fichier (6,4 Mo, daté du 03-07) est toujours à la racine avec `secret_key_base`
(6 occurrences) et un `refresh_token`. `.dockerignore` et `.gitignore` l'excluent désormais.
Reste : supprimer le fichier et faire tourner les secrets concernés.

#### N7 [INFORMATIF] Les tokens API `srv_` survivent au changement de mot de passe
Comportement documenté comme intentionnel (indépendants du `token_version`). Aucun signalement
UI n'a été ajouté. Décision : proposer (ou signaler) la révocation des tokens API au changement
de mot de passe.

#### N8 [INFORMATIF, décision] Modèle de menace des apps custom
Le module d'entrée d'une app installée est importé same-origin par la SPA
(`stores/apps.ts:31`) et s'exécute avec la session complète, y compris les endpoints
`session_only`. Trade-off accepté (warning à l'install). Correction optionnelle si des apps non
fiables doivent être supportées : iframe sandboxée sur origine séparée + pont postMessage, ou
hash d'intégrité du module épinglé dans le manifest. Recoupe FS1 côté front.

## Phase 5 : Performance (backend)

Les index `(user_id, kind, occurred_at)` et `(user_id, inserted_at)` ont été ajoutés
(migrations du 2026-07-16); les findings restants :

#### P2 [HAUTE] Recherche `q` en `LIKE '%terme%'` sur tout le blob JSON, non indexable
`data.ex:360-364`. Chaque frappe de la palette balaye toutes les lignes et applique `LIKE` sur
le JSON `data` complet. Correction : table virtuelle FTS5 (`entries_fts` sur title + champs
texte projetés, `MATCH`); a minima debounce client sur le `LIKE data`.

#### P4 [MOYENNE] `resolve_mentions/2` charge tous les contacts et events à chaque sauvegarde de note
`notes.ex:442-453` : `Repo.all` sur toutes les entries `kind in ["contact","event"]` puis
`Map.take` en mémoire (le select est désormais limité à 3 colonnes, seule amélioration).
Correction : filtrer en SQL sur les noms canoniques recherchés.

#### P5 [MOYENNE] Vignettes + display JPEG + EXIF synchrones dans la requête d'upload
`upload_controller.ex:94-115`. Chaque upload photo bloque la requête sur deux passes libvips +
EXIF. Correction : répondre immédiatement, générer en `Task.Supervisor`, pousser les URLs par
le canal (pattern `Backfill`). Implique un changement de flux côté front.

#### P6 [MOYENNE] Export chargé entièrement en mémoire
`export_controller.ex:28-39, 55-66` : `all_entries` + `Enum.map` + `json/2` (iCal idem).
Correction : `Repo.stream` en transaction + `send_chunked`.

#### P7 [MOYENNE] Pagination par OFFSET : pages profondes coûteuses
`data.ex:379-397` (seul ajout : `clamp_per_page`, max 1000). Correction : pagination keyset
(curseur `(occurred_at, id)`) pour le défilement infini.

#### P8 [BASSE] Boot : la config de chaque connecteur activé est lue 3 fois
`connectors.ex:157` puis `:112` puis `worker.ex:55` (le re-read du worker est justifié et
commenté, pas celui de `start_connector`). Correction : passer la config déjà chargée.

#### P9 [BASSE] Appends de listes quadratiques dans Enable Banking
`enable_banking_connector.ex:103` et `:267` : `acc ++ ...` dans le reduce et la pagination.
Correction : préfixer puis `Enum.reverse` une fois.

## Phase 6 : Clean code (backend)

#### C2 [BASSE] L'accès "clé atom-ou-string" est réimplémenté dans chaque contexte
`data.ex:231` (`get_attr/2`), `:371-373` (`stringify_keys/1`); `notes.ex:495-496` (`get/3`).
Correction : normaliser une fois à la frontière ou helper partagé dans `Servant.Util`.

#### C3 [BASSE] `apply_sort/2` et `apply_pagination/2` dupliquent les clauses string/atome
`data.ex:375-392`. Correction : `stringify_keys` en tête de `list_entries/2`, supprimer les
clauses atomes redondantes.

#### C4 [BASSE] `parse_english_date` réimplémente ce que `date_time_parser` couvrirait
`invoice_scraper_connector.ex:279-308`. Défendable (petit, sans dépendance); à réévaluer si
d'autres formats apparaissent.

## Phase 7 : Dépendances (état au 2026-08-18)

Backend : plug 1.20.3, phoenix 1.8.9, req 0.6.3, castore 1.0.20 : les CVE de juillet sont
fermées. Restent :

- **mint 1.9.3** (au lieu du 1.10 visé) : vérifier que les correctifs CVE HTTP/1 et HTTP/2 sont
  backportés en 1.9.3, sinon monter finch/req.
- **ecto_sqlite3 0.22.0**, déclaré `{:ecto_sqlite3, ">= 0.0.0"}` dans mix.exs : monter (~> 0.24)
  et resserrer le pinning.
- **`{:req, "~> 0.5"}`** : contrainte plus lâche que la 0.6.3 verrouillée, à aligner.
- **decimal 2.4.1** : ignore documenté (GHSA-rhv4-8758-jx7v), bloqué par ecto ~> 2.0. Surveiller.

Frontend : 0 vulnérabilité npm. Restent :

- **phoenix (js) 1.8.8** derrière le serveur 1.8.9 (désynchronisé, CVE Presence non applicable).
- **Majeurs en retard** : pinia 3 -> 4, typescript 6 -> 7, vitest 3 -> 4.
- **Pas d'outillage de couverture** : `@vitest/coverage-v8` absent, aucun script
  `test:coverage` (recoupe FT10).
- **face-api / tfjs** : 24 Mo node_modules + 12 Mo de modèles; lazy-loading en place, surveiller.

## Phase 8 : Documentation

Entièrement soldée (README, docs/deploy.md, docs/development.md, moduledocs, garde OpenAPI des
notes). Section retirée à l'élagage.

---

# PASSE FRONTEND

## Phase 1 : Architecture

#### FA1 [MOYENNE, partiel] Le temps réel ne couvre pas les 8 apps
`useSocket.ts:103` expose `onEntryChange`/`onBulkChange` (avec gestion d'erreurs), consommés
seulement par Dashboard et DataBrowser; `AppContext` (`apps/types.ts:62-78`) n'expose toujours
aucune souscription. Photos, Finance, Calendar, Trackers ne se rafraîchissent pas quand un
connecteur écrit en arrière-plan. Correction : `onEntryChange`/`onBulkChange` debouncés dans
`AppContext.api`, ou souscription dans `AppView.vue`.

#### FA2 [MOYENNE, partiel] Frontière apps / vues détail routées
`/contacts/:id` est devenu une redirection vers `/apps/contacts?selected=...` (corrigé), mais
`/photos/:id` reste une vue routée top-level (`views/PhotoDetailView.vue`) qui contourne `ctx`.
Correction : intégrer le détail photo dans l'app, ou documenter le privilège builtin.

#### FA3 [BASSE] `useFetchData` n'a qu'un seul consommateur
Seul `PhotoDetailView.vue` l'importe; les apps réimplémentent loading/error/try-catch à la
main. Correction : adopter ou supprimer.

#### FA4 [MOYENNE, partiel] Composants monolithiques
Tailles actuelles : ContactsApp 2030 (a absorbé l'ex-ContactDetailView), PhotosApp 1982,
FinanceApp 1802, NotesApp 1655, CalendarApp 1531, FilesApp 1318, ChecklistsApp 1264;
ConnectorDetailView 1015. Le découpage réel n'a eu lieu que pour finance et trackers.
Correction : extraire des sous-composants (toolbar, grille, modales) sur ce modèle.

#### FA7 [BASSE, partiel] `apiFetch` force `Content-Type: application/json`
Les trois `fetch` bruts subsistent, déplacés dans les modules `api/` (avatar `api/auth.ts:124`,
import `api/connectors.ts:105`, blob `SettingsView.vue:353`) : mieux rangés mais toujours hors
du `401 -> logout` centralisé. Correction : laisser `apiFetch` omettre le Content-Type quand
`body` est un `FormData`, router ces appels par lui.

#### FA8 [BASSE] Le type du callback socket ment sur l'événement `deleted`
`useSocket.ts:60` : le backend envoie `%{type: "deleted", entry: %{id}}` mais le callback est
typé `(entry: Entry)` complet et le champ `type` est jeté. Correction : typer
`{ type: 'created'|'updated'|'deleted'; entry: Partial<Entry> & { id: string } }`.

#### FA9 [BASSE] Erreur réseau de `appsStore.load()` avalée
`AppView.vue:79` : `.catch(() => {})` puis message "App not found" trompeur. Correction :
distinguer "liste non chargée" (retry) de "id inconnu".

#### FA10 [BASSE, partiel] Deux styles d'accès HTTP
`useApi` ne subsiste que dans 3 vues (Agents, Audit, Settings); le reste passe par les modules
`api/`. Divergence réduite à une question de goût : trancher et finir la migration.

#### FA11 [BASSE] Formatage de date hors `lib/datetime`
`ConnectorDetailView.vue:472` : `new Date(ebValidUntil).toLocaleDateString()` alors que
`formatDate` est déjà importé dans le fichier. Correction : utiliser `formatDate`.

## Phase 2 : Bugs et observabilité

#### FB10 [BASSE] Le démarrage d'un nouveau lot d'upload efface les erreurs affichées
`lib/uploadQueue.ts:63-65` : `run()` fait `uploadErrors.value = []` en tête de lot.
Correction : ne réinitialiser qu'au "Dismiss", ou accumuler.

#### FB12 [BASSE] `today` des Trackers ne bascule pas à minuit
`TrackersApp.vue:232` : `computed(() => todayInUserTz())` sans dépendance réactive, figé au
montage. Un onglet ouvert après minuit écrit sur la veille. Correction : recalcul sur timer ou
`visibilitychange`.

## Phase 3 : Tests et couverture (frontend)

34 fichiers de test, mais l'infra reste sans filet; le refactor `stores/` + `api/` a déplacé du
code non testé sans le couvrir.

#### FT1 [HAUTE] `apiClient` testé seulement sur sa fonction pure
`apiClient.test.ts` ne couvre que `apiErrorMessage`. Bearer, `401 -> logout`
(`apiClient.ts:47-50`), `204 -> undefined` (`:67`) sans test.

#### FT2 [HAUTE] La pagination des apps n'a aucun test
Déplacée de `createContext` vers `api/entries.ts:34-47` (boucle `do/while page <= totalPages`);
toujours zéro test. Un off-by-one droppe la dernière page pour toutes les apps sans erreur
visible.

#### FT3 [HAUTE] Le store d'auth n'a aucun test
`stores/auth.ts` : branche `requires_totp` de `login`, `verifyTotp`, `register`, `hydrate`
(200/401/réseau) non couverts. `stores/apps.ts` non plus.

#### FT4 [HAUTE] Les guards du router ne sont pas testés
`router/index.ts:105` : redirections `meta.auth`/`meta.guest` sans aucun test.

#### FT5 [HAUTE] `useSocket` n'a aucun test
Gating connect (token ET user), watch reconnexion/déconnexion, `debounce` exporté : rien.

#### FT6 [HAUTE] Le clustering de visages n'est testé qu'avec des embeddings trop séparés
`faces.test.ts:12-13` : distance ~1.41 contre un seuil de 0.5. Tests à écrire : paires à
0.49/0.51, chaîne A-B-C pour figer la dérive du centroïde.

#### FT7 [MOYENNE] Le moteur d'upload n'est pas testé sur son cas concurrent
Les 4 tests sont mono-batch; `enqueue` pendant un batch en cours (`uploadQueue.ts:55-62`)
jamais exercé.

#### FT8 [MOYENNE] `datetime.ts` : conversions non testées aux transitions DST
La double passe a été implémentée mais aucun test spring-forward/fall-back ne la verrouille.

#### FT9 [MOYENNE] `useFetchData`/`useApi`/`useConfirm` sans test
Inchangé.

#### FT10 [MOYENNE] Aucun outillage de couverture
`@vitest/coverage-v8` absent, pas de script, pas de seuil.

#### FT11 [BASSE] Composants réutilisables sans test de composant
`DateInput`, `MediaViewer`, `CommandPalette`, `ConfirmModal` : rien, alors que `test-setup.ts`
polyfille déjà `showModal`.

#### FT12 [BASSE, partiel] Test tautologique sur les thèmes
`theme.test.ts:19-27` asserte toujours la liste littérale (passée à 6 thèmes);
`registry.test.ts` est devenu comportemental. Correction : réduire à l'invariant réel.

## Phase 4 : Sécurité (frontend)

#### FS1 [HAUTE, décision] Apps installées same-origin : compromission de session par design
`stores/apps.ts:25-31` + `createContext.ts:85` (`fetch: apiFetch`). Aucun sandbox, aucune
intégrité. Recoupe N8; à trancher (iframe + postMessage, hash d'intégrité, ou trade-off assumé
et documenté).

#### FS3 [MOYENNE] Token de session transmis dans l'URL du WebSocket
`useSocket.ts:35-36` : `params: { token: auth.token }` sérialisé en query string
`wss://...?token=...`, journalisable par les proxies. Le token complet vit aussi en mémoire JS
(`stores/auth.ts`) et sert de Bearer. Correction : token socket éphémère dédié (Phoenix.Token
court), distinct du bearer API, ou authentifier le socket via le cookie.

#### FS4 [BASSE, partiel] `window.open` sans `noopener`
Il reste un seul appel (`FilesApp.vue:239`), sur un chemin same-origin `/files/...` (impact
faible); l'appel externe a été corrigé. Correction : ajouter `'noopener'` par cohérence.

#### FS5 [BASSE, partiel] `markdown-it` s'appuie sur `html:false` implicite
`render.ts:5` et `lib/markdown.ts:7` : le défaut est désormais documenté en commentaire, mais
pas explicité en option. Une ligne par constructeur rend l'invariant non-régressable.

## Phase 5 : Performance (frontend)

#### FP1 [HAUTE] Grille Photos non virtualisée
`PhotosApp.vue:1129-1137` : un noeud par photo filtrée, `loading="lazy"` seul. 2000 photos =
2000 cellules montées pour ~50 visibles. Contacts fait déjà bien (`useVirtualList`); Calendar
reste non virtualisé aussi (grille bornée à 42 cellules, agenda non). Correction : fenêtrer
(useVirtualList ou IntersectionObserver).

#### FP2 [MOYENNE] Réactivité profonde sur les grands tableaux d'entries
`PhotosApp.vue:41-42`, `ContactsApp.vue:45`, `DataBrowserView.vue:28` : `ref<Entry[]>`;
zéro `shallowRef` dans le repo. Correction : `shallowRef`/`markRaw` pour les listes en lecture.

#### FP3 [MOYENNE] Helpers appelés par item et par rendu dans la grille Photos
`getThumbPath`, `getTags` (2 fois par photo dans le même bloc), aussi rappelés dans les
computeds. Correction : view-model précalculé dans le computed `groups`/`filtered`.

#### FP4 [MOYENNE, aggravé] flatpickr importé statiquement, propagé à 8 modules
La centralisation dans `DateInput.vue` (import statique JS + CSS) tire flatpickr dans presque
tous les chunks (FinanceApp, ContactsApp, TrackerCard, SettingsView, CalendarApp,
ChecklistsApp, PhotosApp, DataBrowserView). Correction : `import()` dynamique à l'ouverture du
picker, ou natif stylé.

#### FP5 [BASSE] Aucun debounce sur les filtres de recherche client
`FilesApp.vue:272,400` etc. : chaque frappe déclenche le filtrage O(n). Les debounce existants
concernent la sauvegarde, pas les filtres. Correction : debouncer `searchQuery`.

#### FP6 [BASSE] Double aller-retour séquentiel après mutation dans DataBrowser
`DataBrowserView.vue:180-181, 216-217, 232-233` : `await fetchEntries()` puis
`await fetchFilters()`. Correction : `Promise.all`.

## Phase 6 : Clean code, accessibilité, i18n (frontend)

#### FC1 [MOYENNE, partiel] Boucles de backfill jumelles dans PhotosApp
`rebuildPreviews` a été refondu (appel serveur + polling); `rebuildVideoThumbs:255-289` et
`scanFaces:321-345` partagent encore exactement le même squelette. Correction : helper
`runBatch(targets, fn, progressRef)`.

#### FC2 [BASSE] Expression de template complexe non extraite
`FilesApp.vue:846-854` : ternaire triple imbriqué du message d'état vide. Correction :
computed `emptyMessage`.

#### FC3 [BASSE] Index de tableau comme `:key`
`PhotosApp.vue:1264-1265, 1271-1272` (faceRows, deux niveaux), `:1117-1118` (uploadErrors).
Correction : clés stables (`row.cluster.id`, `f.photoId`).

#### FA-A11Y [BASSE, partiel] Quatre `role="button"` sans activation Espace
La directive `v-click-key` couvre désormais les vues; restent `ContactsApp.vue:1188, 1258,
1309` et `RelationsGraph.vue:290` avec `@keydown.enter` seul (Espace inactif). Correction :
appliquer `v-click-key`.

#### FI7 [HAUTE, décision] Aucun système d'i18n : chaînes anglaises en dur
Pas de vue-i18n; libellés figés en anglais pour un utilisateur FR. Décision : introduire
vue-i18n (ou dictionnaire minimal), ou assumer explicitement l'anglais-only comme choix
produit.

#### FI8 [MOYENNE] `relativeTime` codé en anglais, sans `Intl.RelativeTimeFormat`
`lib/datetime.ts:259-274` (`'just now'`, `` `${d}d ago` ``), consommé par 5 vues; le reste du
fichier est bien internationalisé via `Intl.DateTimeFormat`. Correction :
`Intl.RelativeTimeFormat`.

#### FI9 [BASSE] Pluralisation naïve
`DataBrowserView.vue:343` ("1 entries"), `TrackerCard.vue:162-163`. Correction :
`Intl.PluralRules` ou i18n.

#### FI10 [BASSE] Monnaie formatée en suffixe pour le fiat
`finance.ts:487-491` : nombre localisé + `" EUR"`. Choix partagé fiat/crypto; la vraie
correction est un split (`style: 'currency'` pour le fiat, suffixe pour le crypto).

---

# Addendum 2026-10-04 : audit CardDAV (sync iPhone)

**Déclencheur :** contacts "disparus" de l'iPhone, contacts Servant ignorés par le téléphone,
doublon à chaque création suivi d'une disparition après fusion. Audit ciblé de
`lib/servant/carddav.ex`, `lib/servant/carddav/vcard.ex`, `lib/servant/contacts.ex`,
`lib/servant_web/controllers/dav_controller.ex` (partie addressbooks) et
`frontend/src/apps/contacts/duplicates.ts`. Tests CardDAV et fusion verts au départ (21), mais
aucun des défauts ci-dessous n'était couvert.

Constat préalable : rien n'avait été supprimé. Les contacts vivaient dans un autre compte iOS
(iCloud ou local) et sont réapparus en retirant Servant comme compte par défaut. iOS ne déplace
pas un contact entre comptes; le chemin de migration reste export .vcf puis Import (source
`manual`).

#### CD-1 [HAUTE, corrigé 58c270e] La fusion supprimait la copie connue du téléphone
`Contacts.merge/3` supprimait les doublons et gardait le survivant tel quel. Le survivant
proposé par défaut (`suggestedSurvivor`) est le plus riche puis le plus ancien, donc presque
toujours l'ancien contact Servant : la ressource `carddav_filename` du téléphone disparaissait
du carnet et iOS retirait le contact. Correction : quand le survivant n'a pas d'identité CardDAV,
il reprend le nom de ressource et l'UID du doublon (`carddav_filename`, `carddav_uid`), les
payloads bruts sont purgés pour forcer la resynthèse. Le téléphone voit une mise à jour.

#### CD-2 [MOYENNE, corrigé f122edb] Rapprochement par UID limité à la source `carddav`
`resolve_target/3` ne cherchait l'UID que parmi les entrées `source == "carddav"`. Un PUT dont
l'UID correspond à un contact `manual` (un import garde l'UID d'origine en `external_id`) ou à
la forme synthétisée `<id>@servant` créait une seconde entrée : deux ressources de même UID dans
un carnet, interdit par RFC 6352. Correction : rapprochement sur tous les contacts exposés via
`VCard.uid/1` (qui préfère désormais `carddav_uid`).

#### CD-3 [DÉCISION] Les contacts d'un flux vCard ne sont jamais exposés au téléphone
`@exposed_sources ~w(manual carddav)` : voulu et documenté (`docs/dav.md`), un flux pollé
annulerait les éditions du téléphone. Mais si le carnet historique est venu par un connecteur
vCard URL (source `vcard`), le téléphone ne le verra jamais et chaque contact recréé fera un
doublon. À trancher après diagnostic (répartition des contacts par source en prod) : exposer
`vcard` en lecture, ou réimporter en `manual` et retirer le flux.

#### CD-4 [BASSE] `CardDAV.contacts/1` recharge le carnet entier deux fois par requête
`addressbook_props/1` (ctag) puis la liste Depth:1 appellent chacun `contacts/1`, qui charge
toutes les entrées `contact` avec leurs vCards brutes (photos base64 incluses) et filtre en
Elixir. Même schéma que B1-5, qui le mentionnait déjà pour CalDAV; à traiter ensemble.

#### CD-5 [AMÉLIORATION, livré fa38184] Détection de doublons trop stricte sur le nom
`findDuplicateGroups` n'appariait que des noms normalisés identiques. Ajout d'une passe par
paires : même mots dans un autre ordre, une faute de frappe (distance d'édition 1 dès 5
caractères, 2 dès 10), et un prénom seul rapproché du seul contact qui le porte (plusieurs
porteurs : rien, pour ne pas suggérer la fusion de deux personnes).
