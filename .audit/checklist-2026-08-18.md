# Checklist d'audit - Servant - 2026-08-18

**Source :** `.audit/code-audit-2026-07-16.md` (élagué le même jour) pour les IDs de la forme
`B*`/`T*`/`N*`/`P*`/`C*`/`F*`, plus le reliquat des checklists de juin/juillet (IDs `BE2-*`,
`FE2-*`, `BE-*`, `FE-*`), dont les fichiers ont été supprimés après consolidation.

**Consolidation du 2026-08-18 :** chaque item a été revérifié dans le code (HEAD `1087a25`);
les items corrigés ont été retirés, les partiels décrivent ce qui reste. Remplace
`checklist-2026-07-04.md`, `checklist-backend-2026-06-23.md`,
`checklist-frontend-2026-06-23.md`.

### Légende

- **Sévérité** : 🔴 critical · 🟠 high · 🟡 medium · ⚪ low
- **Effort** : `quick` (≤15 min) · `small` · `medium` · `large` (transversal/risqué)

---

## BACKEND

### Sécurité

- [ ] **N1** · 🟠 high · `lib/servant/apps.ex:208-227` · effort: small
      SSRF via `git clone` d'une URL d'app : `validate_repo_url` sans `ensure_public_url`,
      sortie d'erreur git réfléchie au client (cartographie du réseau interne).
- [ ] **N2** · 🟡 medium · `lib/servant/http.ex:43-76` · effort: medium
      TOCTOU/DNS rebinding sur `ensure_public_url` (Req re-résout) : connexion par IP épinglée
      ou transport custom.
- [ ] **N4 + BE2-SEC-7** · 🟡 medium · `lib/servant_web/controllers/upload_controller.ex` · effort: medium
      L'allow-list d'upload ne rejette rien (fallback `Path.extname`), type fixé sur le
      content_type client, pas de lecture des magic bytes.
- [ ] **N5** · ⚪ low · `lib/servant_web/controllers/auth_controller.ex:150` · effort: small
      Throttle de login clé par username seul : un tiers peut verrouiller un compte en boucle.
      Coupler IP ou backoff.
- [ ] **N6** · ⚪ low · `erl_crash.dump` (racine) · effort: quick
      Le dump du 03-07 est toujours sur disque avec `secret_key_base` + un `refresh_token`
      (dockerignore/gitignore faits) : supprimer et faire tourner les secrets.
- [ ] **B2-14** · ⚪ low · `lib/servant/accounts.ex:200-212` · effort: small
      Anti-replay TOTP non atomique : update conditionnel `Repo.update_all` sur
      `totp_last_used_at`.
- [ ] **B2-15** · ⚪ low · `lib/servant_web/controllers/client_error_controller.ex` · effort: small
      Pas de rate-limit sur `/api/client_errors` : noyage possible du ring buffer d'audit
      (le crash sur non-string est corrigé).
- [ ] **B1-3** · ⚪ low · `rss_connector.ex:73`, `ical_connector.ex:104`, `vcard_connector.ex:81` · effort: small
      `verify: false` en dur sur les fetch de flux : allow-list d'hôtes OTP 27 ou retry ciblé.
- [ ] **BE2-SEC-6** · 🟡 medium · `endpoint.ex:12`, `config/config.exs:31`, `config/dev.exs:23` · effort: small
      Sels de session/LiveView en dur, secret de dev committé (la prod prend l'env). Les
      changer invalide les sessions au déploiement, d'où le report.

### Bugs / robustesse

- [ ] **B2-2** · 🟠 high · `invoice_scraper_connector.ex:140-150` · effort: medium
      Timeout du scraper = node/Chromium zombie (le `Task.shutdown` ne tue pas le process OS);
      la clause `{:exit,_}` est corrigée. Superviser le process OS ou wrapper qui tue sur EOF.
- [ ] **B2-3** · 🟡 medium · `enable_banking_connector.ex:111-128` · effort: small
      Erreurs par compte loguées mais pas propagées : sync "completed", `config.error` nil,
      suivi amputé en silence côté UI.
- [ ] **B1-1** · 🟡 medium · `lib/servant/data.ex:203` · effort: medium
      Syncs insert-only (`on_conflict: :nothing`) : une modification amont (iCal, vCard,
      commit amendé) n'est jamais répercutée. Stratégie d'upsert par connecteur.
- [ ] **B1-2** · ⚪ low · `lib/servant/data.ex:194-229` · effort: quick
      `create_entries` (bulk) accepte encore `kind: "note"` (le chemin unitaire est gardé).
- [ ] **B1-4** · 🟡 medium · `lib/servant/connectors.ex:58-64` · effort: small
      Modifier une config connecteur n'affecte pas un worker en cours : redémarrer via
      `Registry.lookup` (démarrer/arrêter selon `enabled`).
- [ ] **B1-8** · 🟡 medium · `github_connector.ex:117-138` · effort: small
      Backfill GitHub non borné, curseur persisté seulement en fin de sync complète :
      persister par fenêtre ou borner comme Solana.
- [ ] **B2-7** · 🟡 medium · `lib/servant/connectors/scheduler.ex:41-48` · effort: small
      `sync_logs` jamais purgés (~17 000 lignes/jour en "continuous"); le rescue et le
      fail_sync_log sont en place.
- [ ] **B2-9** · 🟡 medium · `lib/servant/media/backfill.ex:31-36` · effort: small
      Backfill média muet (résultats jetés, échecs invisibles); `running?/1` faux entre start
      et enregistrement Registry.
- [ ] **B2-10** · 🟡 medium · `dav_controller.ex:426`, `caldav.ex:100-105` · effort: medium
      Préconditions PUT DAV évaluées sur une autre ressource que celle écrite (résolution UID
      cross-calendriers) : écrasement possible sans 412.
- [ ] **BE2-BUG-14** · 🟡 medium · `ical_connector.ex:155-156, 193-195` · effort: small
      TZID non résolus : la base tz est là (`{:tz, "~> 0.28"}` + config) mais le parser jette
      les paramètres DTSTART et force UTC. Lié à B1-6.

### Performance

- [ ] **P2** · 🟠 high · `lib/servant/data.ex:360-364` · effort: large
      Recherche `LIKE '%q%'` sur title + blob JSON, non indexable : FTS5 (`entries_fts`).
      (Les index composites de juillet sont posés.)
- [ ] **P4** · 🟡 medium · `lib/servant/notes.ex:442-453` · effort: small
      `resolve_mentions` charge tous les contacts+events à chaque sauvegarde de note :
      filtrer en SQL sur les noms recherchés.
- [ ] **P5 + BE2-PERF-4** · 🟡 medium · `upload_controller.ex:94-115` · effort: medium
      Vignettes + display + EXIF synchrones dans la requête d'upload : Task.Supervisor +
      push canal (changement de flux côté front).
- [ ] **P6 + BE2-PERF-5** · 🟡 medium · `export_controller.ex:28-66` · effort: medium
      Export JSON/iCal entièrement en mémoire : `Repo.stream` + `send_chunked`.
- [ ] **P7** · ⚪ low · `lib/servant/data.ex:379-397` · effort: medium
      Pagination OFFSET : keyset `(occurred_at, id)` pour les pages profondes.
- [ ] **P8** · ⚪ low · `connectors.ex:112,157` · effort: quick
      Config de chaque connecteur lue 3 fois au boot : passer la struct déjà chargée.
- [ ] **P9** · ⚪ low · `enable_banking_connector.ex:103,267` · effort: quick
      Appends quadratiques (`acc ++ ...`) : préfixer puis `Enum.reverse`.
- [ ] **BE2-PERF-1** · 🟡 medium · `lib/servant/notes.ex:369,415` · effort: medium
      `resolve_targets` scanne tout le vault en mémoire (le snapshot par source est fait);
      la vraie correction est une clé canonique indexée.
- [ ] **BE2-PERF-7** · ⚪ low · `data.ex:54-59`, `entry_controller.ex:65` · effort: small
      COUNT complet non borné exécuté à chaque page de la liste d'entries.
- [ ] **BE2-PERF-8** · ⚪ low · `evm_connector.ex:105-115` · effort: small
      Syncs blockchain séquentiels (transactions puis token transfers, connecteurs en série).

### Tests

- [ ] **T1** · 🟠 high · `user_socket.ex:9` · effort: small
      `connect/3` jamais exercé : token valide / absent / après `bump_token_version`.
- [ ] **T2** · 🟠 high · `connector_controller_test.exs` · effort: medium
      Cycle de vie connecteurs via l'API sans test HTTP (create, delete, sync, start, stop,
      eb_*, logs, schedules, import_file).
- [ ] **T3** · 🟠 high · `worker.ex:158-171` · effort: small
      Planification périodique sans filet : `schedule_interval_ms/1`, timer ré-armé après
      succès ET après échec.
- [ ] **T4** · 🟠 high · `connectors.ex:154,363-405`, `scheduler.ex` · effort: small
      `start_all_enabled`, `get_env`/`put_env`, `cleanup_expired_env` sans test.
- [ ] **T5** · 🟠 high · `dav_controller.ex` · effort: small
      `If-Match` jamais testé (protection anti-écrasement concurrent) : 204 sur bon ETag,
      412 sur ETag périmé, ressource intacte.
- [ ] **T6** · 🟡 medium · `thumbnail_test.exs:24-26` · effort: quick
      Le test de vignette accepte `:error` comme succès : `@tag :vips` exclu explicitement.
      (`Exif.extract` est couvert depuis.)
- [ ] **T7** · 🟡 medium · `apps_test.exs` · effort: small
      `git_clone`/`update_from_git` non exercés : bare repo local en `:tmp_dir`.
- [ ] **T8** · 🟡 medium · `test/servant/connectors/` · effort: medium
      Flux HTTP OAuth sans `Req.Test` (rotation refresh Strava, pagination, erreurs API).
- [ ] **T9** · 🟡 medium · `accounts.ex:110` · effort: small
      `update_avatar/2` sans test (mapping extension, type exotique).
- [ ] **T12** · ⚪ low · `auth_controller_test.exs:239-325` · effort: quick
      Tests TOTP dépendants de l'horloge : `time:` explicite des deux côtés.

### Architecture / clean code

- [ ] **B1-5** · 🟡 medium · `caldav.ex:32-53`, `dav_controller.ex:295` · effort: medium
      DAV recharge toutes les entries par appel, N+1 sur multiget : charger une fois par
      requête ou filtrer en SQL.
- [ ] **B1-6** · 🟡 medium · `caldav/ics.ex`, `ical_connector.ex`, `export_controller.ex` · effort: large
      Trois implémentations iCal divergentes (heures flottantes user-tz vs UTC) : extraire
      `Servant.ICal`, aligner la sémantique, résoudre les TZID (recoupe BE2-BUG-14).
- [ ] **B1-7** · 🟡 medium · `error_json.ex`, `schemas/error.ex:22`, fallbacks auth · effort: small
      Triple format d'erreur JSON, deux violent le schéma OpenAPI : normaliser ou documenter
      les variantes.
- [ ] **B1-11 + BE-ARCH-5** · 🟡 medium · `auth_controller.ex` (x4), `entry/export/app_controller` · effort: medium
      Sérialisation JSON à la main et divergente : `user_json/2` + modules `*_json.ex`
      partagés (source unique du contrat avec `frontend/src/types.ts`).
- [ ] **B1-10** · ⚪ low · `connector.ex:13-15` · effort: quick
      Callbacks `name/0`, `kind/0`, `required_credentials/0` sans consommateur : supprimer ou
      brancher.
- [ ] **B1-12** · ⚪ low · `ical/vcard/solana_connector` · effort: quick
      `Map.get` direct au lieu de `config_value/2` (mélange dans un même `init/2`).
- [ ] **BE2-ARCH-3** · 🟡 medium · `lib/servant/connectors.ex` (412 l.) · effort: large
      Contexte surchargé : CRUD + lifecycle + sync logs + cache env + import. Découper
      `Connectors.Lifecycle` / `.Imports`.
- [ ] **BE2-ARCH-4** · 🟡 medium · `lib/servant/storage.ex:174-213` · effort: medium
      Chaîne de résolution legacy `uploads/` : migrer les fichiers puis retirer le fallback.
- [ ] **BE2-CLEAN-1** · 🟡 medium · `connectors.ex:301-312` · effort: medium
      `run_import/10` : dix arguments positionnels, struct de contexte à introduire.
- [ ] **BE2-CLEAN-2** · 🟡 medium · `lib/servant/notes.ex` (521 l.) · effort: large
      Extraire `Notes.Links` (parsing wikilinks/mentions/tags, backlinks).
- [ ] **BE2-CLEAN-4** · 🟡 medium · `app_controller.ex:49-97` vs `apps/registry.ts` · effort: small
      Double liste d'apps intégrées, désormais divergente (5 côté back, 8 côté front).
- [ ] **C2** · ⚪ low · `data.ex:231,371`, `notes.ex:495` · effort: small
      Accès "clé atom-ou-string" réimplémenté par contexte : normaliser à la frontière.
- [ ] **C3 + BE2-CLEAN-6** · ⚪ low · `data.ex:375-392` · effort: quick
      `apply_sort`/`apply_pagination` dupliquent les clauses string/atome : `stringify_keys`
      en tête de `list_entries/2`.
- [ ] **C4** · ⚪ low · `invoice_scraper_connector.ex:279-308` · effort: quick
      `parse_english_date` maison; réévaluer si d'autres formats apparaissent.

### Dépendances

- [ ] **DEP-1** · 🟡 medium · `mix.lock` · effort: quick
      mint bloqué en 1.9.3 (cible 1.10) : vérifier le backport des CVE HTTP/1 et HTTP/2, sinon
      monter finch/req.
- [ ] **DEP-2** · ⚪ low · `mix.exs:46` · effort: quick
      `{:ecto_sqlite3, ">= 0.0.0"}` : monter (~> 0.24) et resserrer le pinning.
- [ ] **DEP-3** · ⚪ low · `mix.exs:54` · effort: quick
      `{:req, "~> 0.5"}` alors que 0.6.3 est verrouillé : aligner la contrainte.
- [ ] **DEP-4** · ⚪ low · `frontend/package.json` · effort: quick
      phoenix (js) 1.8.8 derrière le serveur 1.8.9.
- [ ] **DEP-5** · 🟡 medium · `frontend/package.json` · effort: medium
      Majeurs en retard : pinia 3->4, typescript 6->7, vitest 3->4 (dette qui s'accumule).

## FRONTEND

### Sécurité

- [ ] **FS3 + FE2-SEC-2** · 🟡 medium · `useSocket.ts:35`, `stores/auth.ts` · effort: medium
      Token de session complet en mémoire JS, en Bearer ET en query string du WebSocket
      (journalisable) : token socket éphémère dédié, ou socket authentifié par cookie.
- [ ] **FS4** · ⚪ low · `FilesApp.vue:239` · effort: quick
      Dernier `window.open` sans `'noopener'` (chemin same-origin, impact faible).
- [ ] **FS5** · ⚪ low · `render.ts:5`, `lib/markdown.ts:7` · effort: quick
      `html: false` explicite dans les deux constructeurs MarkdownIt (le défaut est documenté
      mais régressable).

### Bugs

- [ ] **FB10** · ⚪ low · `lib/uploadQueue.ts:63-65` · effort: quick
      Le démarrage d'un lot efface les erreurs du lot précédent avant lecture.
- [ ] **FB12** · 🟡 medium · `TrackersApp.vue:232` · effort: small
      `today` figé au montage : un onglet ouvert après minuit loggue sur la veille (timer ou
      `visibilitychange`).
- [ ] **FA8** · ⚪ low · `useSocket.ts:60` · effort: quick
      Typage socket mensonger : payload delete partiel typé `Entry` complet, champ `type`
      jeté.
- [ ] **FA9** · ⚪ low · `AppView.vue:79` · effort: quick
      Erreur réseau de `appsStore.load()` avalée : "App not found" trompeur.
- [ ] **FA11** · ⚪ low · `ConnectorDetailView.vue:472` · effort: quick
      `toLocaleDateString()` brut alors que `formatDate` est importé dans le fichier.

### Performance

- [ ] **FP1 + FE2-PERF-4** · 🟠 high · `PhotosApp.vue:1129-1137` · effort: medium
      Grille Photos non virtualisée (Calendar/agenda non plus; Contacts est fait) :
      `useVirtualList` ou IntersectionObserver.
- [ ] **FP2** · 🟡 medium · `PhotosApp.vue:41`, `ContactsApp.vue:45`, `DataBrowserView.vue:28` · effort: small
      Réactivité profonde sur les grands tableaux d'entries : `shallowRef`/`markRaw`.
- [ ] **FP3** · 🟡 medium · `PhotosApp.vue:1175-1216` · effort: small
      Helpers appelés par item et par rendu dans la grille : view-model précalculé.
- [ ] **FP4** · 🟡 medium · `components/DateInput.vue:3-4` · effort: small
      flatpickr statique propagé à 8 modules via DateInput (aggravé depuis juillet) :
      `import()` à l'ouverture du picker.
- [ ] **FP5** · ⚪ low · `FilesApp.vue:272,400` et autres apps · effort: quick
      Pas de debounce sur les filtres de recherche client.
- [ ] **FP6** · ⚪ low · `DataBrowserView.vue:180-233` · effort: quick
      `fetchEntries` puis `fetchFilters` awaités en séquence : `Promise.all`.

### Tests

- [ ] **FT1** · 🟠 high · `composables/apiClient.ts` · effort: small
      `apiFetch`/`apiJson` sans test : Bearer, `401 -> logout`, `204 -> undefined`.
- [ ] **FT2** · 🟠 high · `api/entries.ts:34-47` · effort: small
      Boucle de pagination des apps (déplacée de createContext, toujours pas testée) : un
      off-by-one droppe la dernière page pour toutes les apps.
- [ ] **FT3 + FE-TEST-2** · 🟠 high · `stores/auth.ts` · effort: small
      Store auth sans test : `requires_totp`, `verifyTotp`, `register`, `hydrate` 200/401.
- [ ] **FT4** · 🟠 high · `router/index.ts:105` · effort: small
      Guards `meta.auth`/`meta.guest` sans test.
- [ ] **FT5** · 🟠 high · `composables/useSocket.ts` · effort: medium
      useSocket sans test (gating, reconnexion au watch, disconnect, debounce).
- [ ] **FT6** · 🟠 high · `apps/photos/faces.test.ts` · effort: small
      Clustering testé loin du seuil : paires 0.49/0.51 et chaîne A-B-C (dérive du centroïde).
- [ ] **FT7** · 🟡 medium · `lib/uploadQueue.ts:55-62` · effort: small
      Cas concurrent non testé : `enqueue` pendant un batch en cours.
- [ ] **FT8** · 🟡 medium · `lib/datetime.test.ts` · effort: small
      Transitions DST non testées (la double passe existe, rien ne la verrouille).
- [ ] **FT9** · 🟡 medium · `composables/` · effort: small
      `useFetchData`/`useApi`/`useConfirm` sans test.
- [ ] **FT10** · 🟡 medium · `frontend/package.json` · effort: quick
      `@vitest/coverage-v8` + script `test:coverage` + seuil minimal.
- [ ] **FT11** · ⚪ low · `components/` · effort: small
      `DateInput`, `MediaViewer`, `CommandPalette`, `ConfirmModal` sans test de composant
      (le polyfill `showModal` est déjà dans test-setup).
- [ ] **FT12** · ⚪ low · `lib/theme.test.ts:19-27` · effort: quick
      Test tautologique sur la liste littérale des thèmes : réduire à l'invariant.

### Architecture / clean code / a11y / i18n

- [ ] **FA1** · 🟡 medium · `apps/types.ts`, `createContext.ts` · effort: medium
      Temps réel absent du contrat d'app : exposer `onEntryChange`/`onBulkChange` debouncés
      aux 8 apps (les données restent périmées pendant les syncs).
- [ ] **FA2** · ⚪ low · `views/PhotoDetailView.vue` · effort: medium
      `/photos/:id` reste une vue routée hors `ctx` (le cas contacts a été recollé).
- [ ] **FA3** · ⚪ low · `composables/useFetchData.ts` · effort: small
      Un seul consommateur : adopter dans les apps ou supprimer.
- [ ] **FA4 + FE2-CLEAN-4** · 🟡 medium · `apps/*.vue` · effort: large
      Monolithes : ContactsApp 2030, PhotosApp 1982, FinanceApp 1802, NotesApp 1655,
      CalendarApp 1531, FilesApp 1318, ChecklistsApp 1264, ConnectorDetailView 1015. Découper
      sur le modèle finance/trackers.
- [ ] **FA7** · ⚪ low · `apiClient.ts:40-43`, `api/auth.ts:124`, `api/connectors.ts:105`, `SettingsView.vue:353` · effort: small
      `apiFetch` force le JSON : trois fetch bruts hors du `401 -> logout` centralisé
      (omettre le Content-Type sur FormData).
- [ ] **FA10** · ⚪ low · `composables/useApi.ts` · effort: quick
      Finir la migration vers les modules `api/` (3 vues restantes) et supprimer `useApi`.
- [ ] **FC1** · ⚪ low · `PhotosApp.vue:255-345` · effort: small
      `rebuildVideoThumbs` et `scanFaces` : même squelette dupliqué, extraire `runBatch`.
- [ ] **FC2** · ⚪ low · `FilesApp.vue:846-854` · effort: quick
      Ternaire triple du message d'état vide : computed `emptyMessage`.
- [ ] **FC3** · ⚪ low · `PhotosApp.vue:1117,1264-1272` · effort: quick
      `:key` par index (faceRows, uploadErrors) : clés stables.
- [ ] **FA-A11Y** · ⚪ low · `ContactsApp.vue:1188,1258,1309`, `RelationsGraph.vue:290` · effort: quick
      Quatre `role="button"` avec Enter seul (Espace inactif) : appliquer `v-click-key`.
- [ ] **FI8** · 🟡 medium · `lib/datetime.ts:259-274` · effort: quick
      `relativeTime` anglais en dur : `Intl.RelativeTimeFormat`.
- [ ] **FI9** · ⚪ low · `DataBrowserView.vue:343`, `TrackerCard.vue:162` · effort: quick
      Pluralisation naïve ("1 entries") : `Intl.PluralRules`.
- [ ] **FI10** · ⚪ low · `finance.ts:487-491` · effort: quick
      Fiat formaté en suffixe : `style: 'currency'` pour le fiat, suffixe pour le crypto.
- [ ] **FE2-CLEAN-7** · ⚪ low · `frontend/src/apps/` · effort: small
      Kinds en littéraux (~131 occurrences); `lib/kind.ts` n'est que visuel : const partagée
      des noms de kinds.

## Décisions en attente

- [ ] **BE2-SEC-4** · 🟡 medium · `config/config.exs:13-15`
      Inscription ouverte par défaut (`registration_enabled: true`, fermable par env) :
      trancher le défaut selon l'usage de l'instance.
- [ ] **N7** · ⚪ low · `api_tokens.ex`, Settings
      Les tokens `srv_` survivent au changement de mot de passe (intentionnel) : proposer ou
      signaler leur révocation dans l'UI.
- [ ] **N8 / FS1** · 🟠 high · `stores/apps.ts:25-31`, `apps.ex`
      Apps installées same-origin avec session complète : iframe sandboxée + postMessage,
      hash d'intégrité dans le manifest, ou trade-off assumé et documenté.
- [ ] **FI7** · 🟡 medium · frontend entier
      Aucun i18n, UI anglaise pour un utilisateur FR : introduire vue-i18n ou assumer
      explicitement l'anglais-only.
