Source: code-audit-2026-07-16.md

> STATUT 2026-07-16 : 39/39 items implémentés et vérifiés.
> Backend `mix precommit` vert (474 tests, 0 warning, 0 vuln hors decimal ignoré).
> Frontend `npm run build` + `vitest` verts (138 tests), prettier appliqué.
> Non committé (à ta main). À surveiller après déploiement : req 0.5→0.6 (montée
> majeure, testée mais les connecteurs font du vrai HTTP non couvert en test).

# Checklist d'implémentation (curée)

Sélection des findings "vraiment utiles" de l'audit 2026-07-16. Écartés volontairement :
i18n (décision produit), sandbox des apps (trade-off acté), virtualisation grille Photos +
FTS5 + upload async + streaming export (gros refactors, à faire quand l'échelle l'exigera),
DNS rebinding / token WS (design sécurité à part), découpe des composants monolithiques,
révocation tokens srv_ au changement de mdp (décision produit).

Légende : ID = pass (BE/FE) + thème + n°. Sévérité 🔴 critique / 🟠 haute / 🟡 moyenne / ⚪ basse.
Effort : quick (≤15 min) · small (<1 h) · medium (qq h) · large.

## Batch A — Hygiène / quick wins

- [x] **A1** · 🟠 · `erl_crash.dump`, `.dockerignore` · quick
      Dump avec secret_key_base + refresh_token à la racine, pas dans .dockerignore.
      Fix: rm le fichier, ajouter `erl_crash.dump` à .dockerignore.
- [x] **A2** · ⚪ · `config/test.exs` · quick
      bcrypt à plein coût en test (~45 s de suite).
      Fix: `config :bcrypt_elixir, log_rounds: 1`.
- [x] **A3** · ⚪ · `lib/servant/connectors/hyperevm/*` · quick
      3 modules hyperevm morts (0 référence).
      Fix: supprimer les 3 fichiers.
- [x] **A4** · ⚪ · `test/servant/connectors/worker_test.exs:112` · quick
      `Process.alive?` interdit par AGENTS.md, redondant avec :sys.get_state.
      Fix: supprimer l'assertion.
- [x] **A5** · ⚪ · `lib/servant/data.ex:210` · quick
      `defp field/2` masque la macro Ecto.Query.field/2.
      Fix: renommer en get_attr/2.

## Batch B — Sécurité

- [x] **B1** · 🟠 · `frontend/src/apps/files/FilesApp.vue:790,229` · quick
      XSS stockée: URL de facture rendue sans safeUrl.
      Fix: router par safeUrl avant :href et window.open, +noopener.
- [x] **B2** · 🟠 · `mix.exs`/`mix.lock` · small
      CVE plug (retiré), phoenix, req/mint.
      Fix: mix deps.update plug phoenix (req testé, revert si casse).
- [x] **B3** · ⚪ · `lib/servant_web/controllers/client_error_controller.ex:41-52` · quick
      truncate/1 crashe sur message non-string (500).
      Fix: garde is_binary + inspect en repli.

## Batch C — Fiabilité backend

- [x] **C1** · 🟠 · `lib/servant/connectors/worker.ex:113-117` · small
      Refresh token (Strava) perdu quand le sync échoue ensuite.
      Fix: persister persisted_config aussi en branche erreur.
- [x] **C2** · 🟠 · `lib/servant/connectors/enable_banking_connector.ex:90-113` · small
      Erreurs par compte avalées si un autre compte renvoie des données.
      Fix: propager les erreurs partielles dans config.error / le sync_log.
- [x] **C3** · 🟠 · `lib/servant/connectors/invoice_scraper_connector.ex:135-157` · small
      Clause {:exit, _} non gérée → crash du worker.
      Fix: ajouter la clause {:exit, reason}.
- [x] **C4** · 🟠 · `lib/servant/connectors.ex:153-160`, `application.ex`, `scheduler.ex` · medium
      Échecs start silencieux + effondrement du DynamicSupervisor sans relance.
      Fix: loguer les échecs start_connector; superviser DynSup+Scheduler en rest_for_one.
- [x] **C5** · 🟡 · `lib/servant/connectors/worker.ex:98-119` · small
      sync_log figé "running" si sync/1 lève (pas de rescue).
      Fix: try/rescue autour de run_sync → fail_sync_log avant re-raise.
- [x] **C6** · 🟠 · `lib/servant/data.ex:142` · quick
      Note créable via POST /api/entries (garde manquante, contredit l'OpenAPI).
      Fix: refuser kind == "note" dans create_entry (miroir de update).
- [x] **C7** · 🟡 · `lib/servant/data.ex:260-266` · quick
      Suppression n'efface pas display_path (JPEG plein format survit).
      Fix: delete_public_path(display_path) dans delete_entry_file.
- [x] **C8** · ⚪ · `lib/servant/media/photo_edit.ex:36-43` · quick
      Fichiers orphelins si update_entry échoue après rotation.
      Fix: supprimer le nouvel original + dérivés en branche erreur.
- [x] **C9** · ⚪ · `lib/servant/connectors/vcard_connector.ex:221-227` · quick
      unescape corrompt les backslashes échappés (\\n).
      Fix: neutraliser \\ en premier via placeholder (comme ICS).
- [x] **C10** · 🟡 · `lib/servant/notes.ex:288-291` · small
      reconcile_inbound s'approprie les liens à titre ambigu.
      Fix: exclure la clé titre nu quand plusieurs notes la partagent.
- [x] **C11** · ⚪ · `lib/servant_web/controllers/dav_controller.ex:204,229,313,361` · small
      Matchs non exhaustifs sur read_body (>8 Mo → 500) et delete.
      Fix: gérer {:more,_} (413) et l'échec delete.

## Batch D — Perf backend (index)

- [x] **D1** · 🟠 · migration + `data.ex:23-30` · quick
      Index (user_id, kind, occurred_at) manquant (timeline).
      Fix: nouvelle migration create index.
- [x] **D2** · 🟡 · migration + `data.ex:60-75` · quick
      daily_stats filtre inserted_at non indexé (dashboard).
      Fix: index (user_id, inserted_at).

## Batch E — Bugs frontend

- [x] **E1** · 🟠 · `frontend/src/main.ts:13-21` · small
      Report d'erreur client câblé aux seuls uploads.
      Fix: app.config.errorHandler + unhandledrejection → POST /api/client_errors.
- [x] **E2** · 🟠 · `frontend/src/apps/photos/PhotosApp.vue:624,652,679,697,714` · small
      Éditions groupées échouent en silence et à moitié.
      Fix: try/catch/finally, remonter l'erreur, fermer le modal + reload dans finally.
- [x] **E3** · 🟡 · `frontend/src/apps/trackers/TrackersApp.vue:64-91` · small
      Agrégats arrivant dans le désordre écrasent entryMaps.
      Fix: token de requête, n'affecter que si le plus récent.
- [x] **E4** · 🟡 · `frontend/src/apps/trackers/TrackersApp.vue:146-175` · small
      Double-clic → logs de tracker en double.
      Fix: garde in-flight par (trackerId, date), désactiver les contrôles en vol.
- [x] **E5** · 🟡 · `frontend/src/apps/photos/PhotosApp.vue:211-324` · small
      Boucles longues non annulées au démontage.
      Fix: flag alive mis à false dans onUnmounted, sortir des boucles.
- [x] **E6** · 🟡 · `frontend/src/apps/calendar/CalendarApp.vue:850,853` · small
      flatpickr sur <input type=date> → double calendrier.
      Fix: réutiliser DateInput.vue (ou type=text).
- [x] **E7** · ⚪ · `frontend/src/lib/datetime.ts:95-104` · small
      zonedToUtcISO faux d'une heure aux transitions DST.
      Fix: double correction d'offset.
- [x] **E8** · ⚪ · `frontend/src/apps/photos/PhotosApp.vue:729-766` · quick
      Deep-link ?photo= filtré ouvre la mauvaise photo (idx -1 → 0).
      Fix: si idx === -1, lever le filtre ou ignorer.
- [x] **E9** · ⚪ · `frontend/src/composables/useSocket.ts:26-52` · small
      Échec de channel.join() jamais remonté ni loggé.
      Fix: .receive('error'/'timeout') + socket.onError/onClose.
- [x] **E10** · ⚪ · `frontend/src/apps/photos/FaceChip.vue:13-31` · quick
      Image cassée → canvas vide silencieux.
      Fix: img.onerror qui dessine un placeholder.

## Batch F — Accessibilité frontend

- [x] **F1** · ⚪ · `frontend/src/style.css:445-450` · quick
      Outline supprimé sur les champs au focus.
      Fix: box-shadow/outline visible sur :focus-visible.
- [x] **F2** · 🟠 · div role=button sans clavier (DataBrowser, Connectors, Dashboard, ContactDetail) · medium
      Entrée/Espace n'activent pas (WCAG 2.1.1).
      Fix: @keydown.enter/.space.prevent (ou <button>).

## Batch G — Cleanup frontend

- [x] **G1** · ⚪ · `frontend/src/apps/*/index.ts` · quick
      8 adaptateurs index.ts 100% dupliqués.
      Fix: helper defineVueApp(Component).

## Batch H — Documentation

- [x] **H1** · 🟠 · `README.md:16-20` · quick
      ./bin/dev inexistant, ports 4000/5173 faux.
      Fix: approche deux-terminaux, ports 4001/5001.
- [x] **H2** · 🟠 · `docs/deployment.md:83,128` · medium
      Dockerfile de la doc périmé (versions, FILES_DIR/TMP_DIR manquants).
      Fix: régénérer à l'identique du Dockerfile racine.
- [x] **H3** · 🟡 · `lib/servant/caldav.ex:6`, `carddav.ex:5`, `docs/dav.md:33` · quick
      "wholesale-replace entries" faux (upsert :nothing).
      Fix: reformuler avec la vraie raison.
- [x] **H4** · 🟡 · `README.md:28,154` · quick
      "no admin/member hierarchy" obsolète.
      Fix: documenter le rôle operator + page Audit cross-user.
- [x] **H5** · 🟡 · `DEVELOPMENT.md` · quick
      Versions Erlang/Elixir périmées + arbre de structure incomplet.
      Fix: 29.0.3 / 1.20.2-otp-29, compléter/marquer l'arbre non exhaustif.
