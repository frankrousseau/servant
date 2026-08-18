# Checklist d'audit — Servant — 2026-07-04

**Source :** `.audit/code-audit-2026-07-03.md` · **Commit de remédiation :** `e125cb8` (sur `main`).

**Élagué le 2026-07-29** : les items traités ont été retirés (les cases n'avaient
pas été recochées au fil des passes ; l'état a été revérifié dans le code, pas
d'après les cases). Retirés à ce titre : `BE2-ARCH-1/2/5/6/7/8`, `BE2-BUG-*`,
`BE2-SEC-1/2/5/8/9/10`, `BE2-PERF-2/3/6`, `BE2-DEP-*` (`gettext` et
`dns_cluster` ne sont plus dans `mix.exs`), `BE2-TEST-*` et `FE2-TEST-*` (suites
Vitest et ConnCase en place), `BE2-DOC-*`, `FE2-ARCH-*`, `FE2-CLEAN-1/2/3/5/6`,
`FE2-SEC-1` et `FE2-SEC-3` (plus aucun logo externe dans le front),
`FE2-PERF-1/2/3`, `FE2-DOC-*` (le framework `apps/` est documenté dans
`frontend/src/apps/README.md` et `docs/custom-apps.md`).

### Légende

- **ID** : `BE2`/`FE2` (backend/frontend) + thème + numéro (référence le rapport 2026-07-03).
- **Sévérité** : 🔴 critical · 🟠 high · 🟡 medium · ⚪ low
- **Effort** : `quick` (≤15 min) · `small` · `medium` · `large` (transversal/risqué)

---

## BACKEND

### Sécurité

- [ ] **BE2-SEC-6** · 🟡 medium · `lib/servant_web/endpoint.ex:12`, `config/config.exs:26`, `config/dev.exs:23` · effort: small
      Sels de session et de LiveView en dur, secret de dev committé (la prod prend `SECRET_KEY_BASE` par l'env).
      Les changer invalide les sessions au déploiement, d'où le report.
- [ ] **BE2-SEC-7** · 🟡 medium · `lib/servant_web/controllers/upload_controller.ex:83,153` · effort: medium
      Type de fichier fixé sur le `content_type` envoyé par le client, extension déduite d'une table indexée dessus : pas de lecture des magic bytes.

### Performance

- [ ] **BE2-PERF-1** · 🟡 medium · `lib/servant/notes.ex:204` · effort: medium
      `resolve_targets` scanne tout le vault en mémoire. Le snapshot par source (BE2-PERF-2) a coupé le O(N × vault) mais pas le scan ; la vraie correction est une clé canonique indexée.
- [ ] **BE2-PERF-4** · 🟡 medium · `upload_controller.ex:198`, `Servant.Media.Thumbnail` · effort: medium
      Miniature générée dans la requête d'upload. Passer en `Task.Supervisor` implique de créer l'entrée avant la vignette puis pousser `thumb_path` par le canal, donc un changement de flux côté front.
- [ ] **BE2-PERF-5** · 🟡 medium · `lib/servant_web/controllers/export_controller.ex` · effort: medium
      Export JSON construit entièrement en mémoire : ni `Repo.stream`, ni réponse chunkée.
- [ ] **BE2-PERF-7/8** · ⚪ low
      COUNT non borné sur les listes d'entries ; syncs blockchain séquentiels.

### Architecture / clean code

- [ ] **BE2-ARCH-3** · 🟡 medium · `lib/servant/connectors.ex` (407 l.) · effort: large
      Contexte surchargé : CRUD + lifecycle + sync logs + cache d'env + import. Fix : découper `Connectors.Lifecycle` / `.Imports`. Jamais arbitré (refactor large d'un contexte public).
- [ ] **BE2-ARCH-4** · 🟡 medium · `lib/servant/storage.ex:174-205` · effort: medium
      Chaîne de résolution legacy (`uploads/`) pour les fichiers d'avant `FILES_DIR`. Fix : migrer ces fichiers puis retirer le fallback.
- [ ] **BE2-CLEAN-1** · 🟡 medium · `connectors.ex:296` · effort: medium
      `run_import/10` : dix arguments positionnels. Fix : struct de contexte.
- [ ] **BE2-CLEAN-2** · 🟡 medium · `lib/servant/notes.ex` (521 l.) · effort: large
      Extraire `Notes.Links` (parsing wikilinks/mentions/tags, backlinks).
- [ ] **BE2-CLEAN-4/6** · ⚪ low
      Liste des apps intégrées codée en dur (`app_controller.ex:74`), dupliquée côté front (`apps/registry.ts`) ; `apply_sort` duplique les clés atome et chaîne (`lib/servant/data.ex:375`).

## FRONTEND

- [ ] **FE2-PERF-4** · 🟡 medium · `PhotosApp.vue`, `ContactsApp.vue`, `CalendarApp.vue` · effort: medium
      Listes non virtualisées : tout est monté d'un coup (`useVirtualList` absent).
- [ ] **FE2-CLEAN-4** · 🟡 medium · `PhotosApp.vue` (1947 l.), `ConnectorDetailView.vue` (1012 l.) · effort: large
      SFC surdimensionnées : extraire des sous-composants et des composables.
- [ ] **FE2-SEC-2** · ⚪ low · `stores/auth.ts` · effort: medium
      Copie du token en mémoire JS (nécessaire au socket) à côté du cookie HttpOnly. Fix : token socket à portée et durée réduites côté back.
- [ ] **FE2-CLEAN-7** · ⚪ low · effort: small
      Nombres et chaînes magiques dans les apps (un enum `KIND` partagé).

## Décisions en attente

- [ ] **BE2-SEC-4** · 🟡 medium · `auth_controller.ex`, `config/config.exs`
      Inscription ouverte par défaut. Le throttle login/register est en place (`Servant.Auth.Throttle`) et `REGISTRATION_ENABLED` permet de fermer : reste à trancher le défaut selon l'usage de l'instance.
- [ ] **BE2-BUG-14** · 🟡 medium · connecteur iCal
      TZID non résolus (pas de base tzdata embarquée) : les événements importés avec un fuseau autre que celui de l'utilisateur sont décalés.
