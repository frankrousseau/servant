# Checklist d'audit — Servant · **FRONTEND** (Vue 3 SPA)

**Source :** `.audit/code-audit-2026-06-22.md` (passe Frontend)
**Généré le :** 2026-06-23 · **Backend :** voir `.audit/checklist-backend-2026-06-23.md`

> **Comment sélectionner :** cochez les cases `- [x]` des items à traiter, **ou** indiquez-moi les **IDs** (`FE-SEC-1, FE-PERF-3`), **ou** un **lot** (« tous les quick wins », « toute la phase Sécurité »). Je n'implémente qu'après votre choix, un item à la fois, avec vérification.

### Légende

- **ID** = `FE` (Frontend) + thème (`ARCH`, `BUG`, `TEST`, `SEC`, `PERF`, `CLEAN`, `DEP`, `DOC`) + numéro.
- **Sévérité** : 🔴 critical · 🟠 high · 🟡 medium · ⚪ low
- **Effort** : `quick` (≤15 min, mécanique) · `small` · `medium` · `large` (transversal / risqué)

### Résumé

| | 🔴 | 🟠 | 🟡 | ⚪ | Total |
|---|---|---|---|---|---|
| Frontend | 0 | 8 | 11 | 5 | 24 |

### Progression (boucle `/loop`)

Traité section par section. ✅ = fait & vérifié · ⚠️ = bloqué/décision requise · ⏭️ = sauté (risqué/large, à arbitrer).

- **2026-07-03 — Section Architecture** : FE-ARCH-2 ✅ (réhydratation `auth.user` au boot → **débloque le temps réel de bout en bout** avec BE-BUG-1/2), FE-ARCH-4 ✅ (bloc `theme.colors` mort supprimé — il dupliquait `style.css` sans être consommé) · FE-ARCH-1 ⏭️ (réécriture des 4 apps en Vue, large — à arbitrer), FE-ARCH-3 ⏭️ (unification des 3 clients HTTP — sera traité avec FE-CLEAN-3). Bonus : suivi front de **BE-SEC-1** (`logout` appelle `POST /api/auth/logout`). `vue-tsc` OK.
- **2026-07-03 — Quick wins (Deps/Sécurité/Bugs/Perf)** : FE-DEP-1 ✅ + FE-DEP-2 ✅ (`npm audit fix` → 0 vulnérabilité, vite 8.1.3, build OK), FE-SEC-1 ✅ (validation schéma `href` vCard, bloque `javascript:`), FE-SEC-5 ✅ (handler `onerror` inline retiré, re-câblé en JS — plus aucun handler inline dans les apps), FE-BUG-3 ✅ (fuite listener `keydown`), FE-PERF-2 ✅ (`loading="lazy"` avatars), **FE-BUG-1 ✅** (temps réel — résolu par FE-ARCH-2 + BE-BUG-1/2 ; le câblage `onEntryChange` était déjà bon). `vue-tsc` + `npm run build` OK.
- **2026-07-03 — Sécurité + Clean/Doc** : FE-SEC-2 ✅ (CSP + en-têtes sécurité sur la réponse SPA, `script-src 'self'` strict ; test ; ⚠️ à vérifier en navigateur prod), FE-CLEAN-1 ✅ (`escapeHtml` factorisé dans `apps/escapeHtml.ts` — 4 apps hors-notes ; les 2 copies notes appartiennent à l'agent en cours), FE-DOC-1 ✅ (README front réécrit). Note : coordination avec un autre agent actif sur l'app **notes** → je ne touche pas `notes/*` ni `createContext.ts`. `vue-tsc` + build OK.
- **2026-07-03 — Bugs + Deps + Doc (agent notes terminé)** : FE-BUG-2 ✅ (erreurs affichées : validation JSON + `formError`/`pageError`), FE-DEP-3 ✅ (`npm update` mineurs, 0 vuln, build OK), FE-DOC-2 ✅ (`apps/README.md` : contrat AppModule/AppContext) · signalés low/optionnels : FE-PERF-3 ⏭️ (13 logos SVG inline — conditionnel « si le catalogue grandit »), FE-PERF-4 ⏭️ (chunking vite — « non bloquant »), FE-DOC-3 ⏭️ (JSDoc — faible valeur), FE-DEP-4 ⏭️ (majeures : vue-router 5, TS 6 — à planifier avec changelogs).
- **2026-07-03 — Client HTTP unifié** : FE-ARCH-3 ✅ + FE-CLEAN-3 ✅ (`composables/apiClient.ts` partagé). **17 items frontend faits** cette session.
- **2026-07-03 — Reste à faire (larges / décisions)** : FE-ARCH-1 ⏭️ (réécriture des 4 apps impératives en Vue — **racine** de FE-BUG-5, FE-SEC-4, FE-PERF-1, FE-CLEAN-2, tous doublons à traiter avec) ; FE-BUG-4 ⏭️ (`entries.list` charge 10 000 entrées côté client — pagination/filtrage serveur, lié à la réécriture des apps) ; FE-SEC-3 ⚠️ **décision** (token en `localStorage` → cookie `HttpOnly` : l'infra cookie existe déjà pour `/files`, l'étendre à toute l'API est un choix transversal) ; FE-TEST-1/2 ⚠️ **décision** (monter Vitest + `@vue/test-utils` + happy-dom — nouvelle infra de tests, 0 test actuellement).

---

## Architecture

- [ ] **FE-ARCH-1** · 🟠 high · `apps/{contacts,calendar,files,photos}/index.ts` (~2500 LOC) · effort: large
      Deux paradigmes : Vue réactif (SFC) vs DOM impératif (`innerHTML` + listeners manuels) → surface XSS, fuites, perte focus/scroll.
      Fix : réécrire les apps en composants Vue (le contrat `AppContext` peut rester). *(racine de FE-SEC-1/4, FE-BUG-3/5, FE-CLEAN-1/2)*
      ⏭️ *Signalé — refactor large (2026-07-03)* : réécriture des 4 apps impératives (~2500 LOC) en composants Vue. Gros chantier structurel à planifier ; racine de plusieurs items (FE-SEC-1/4, FE-BUG-3/5, FE-CLEAN-1/2). À faire par app, séparément.
- [x] **FE-ARCH-2** · 🟠 high · `auth.ts:7`, `main.ts`/`App.vue` · effort: small
      `auth.user` non réhydraté au rechargement → `useSocket.connect()` sort (temps réel jamais connecté après refresh, cause 3/3).
      Fix : au boot, si `token` présent, charger `/auth/me` et peupler `user`. *(complète BE-BUG-1/2)*
      ✅ *Fait (2026-07-03)* : `auth.hydrate()` charge `/api/auth/me` au boot (`main.ts`) si token présent (clear si 401) ; `useSocket` se connecte désormais quand `token` **et** `user` sont là (watch mis à jour). Complète BE-BUG-1/2 → temps réel fonctionnel après rechargement. `vue-tsc` OK.
- [x] **FE-ARCH-3** · 🟡 medium · `useApi.ts`, `createContext.ts`, `auth.ts` · effort: medium
      Trois implémentations du client HTTP (Bearer/401/parse d'erreur dupliqués).
      Fix : un seul client partagé. *(lié à FE-CLEAN-3)*
      ✅ *Fait (2026-07-03, avec FE-CLEAN-3)* : client unique `composables/apiClient.ts` (`apiFetch`/`apiJson`/`apiErrorMessage`). `useApi` et `createContext` délèguent (messages d'erreur enrichis partout — format changeset). `upload` multipart reste séparé (Content-Type boundary) ; `auth.ts` login/register/hydrate restent (bootstrap du token). `vue-tsc` + build OK.
- [x] **FE-ARCH-4** · 🟡 medium · `createContext.ts:90-101` · effort: small
      Jetons de thème (couleurs hex) dupliqués vs `style.css`.
      Fix : exposer les variables CSS aux apps. *(lié à FE-CLEAN-3)*
      ✅ *Fait (2026-07-03)* : le bloc `theme.colors` dupliquait `style.css` **et n'était consommé par aucune app** → supprimé du contrat (`types.ts`) et de `createContext.ts` (dédup par suppression du code mort). `style.css` reste la source unique. `vue-tsc` OK.

## Bugs / correctness

- [x] **FE-BUG-1** · 🟠 high · `DataBrowserView.vue:42-45` · effort: small
      Rafraîchissement temps réel inopérant (`onEntryChange` jamais déclenché).
      Fix : dépend de BE-BUG-1/2 + FE-ARCH-2. *(paire avec BE-BUG-2)*
      ✅ *Fait (2026-07-03)* : résolu par FE-ARCH-2 + BE-BUG-1/2 — le câblage `onEntryChange(() => fetchEntries())` était déjà correct, il ne se déclenchait jamais faute de socket connecté. Aucun changement de code nécessaire ici.
- [x] **FE-BUG-2** · 🟠 high · `DataBrowserView.vue:78,127,145` (19 `catch {}`) · effort: medium
      Erreurs avalées en silence (ex. `JSON.parse` invalide dans `saveEntry` → modale figée sans message).
      Fix : afficher les erreurs (toast/inline) ; valider le JSON du formulaire avant envoi.
      ✅ *Fait (2026-07-03)* : `saveEntry` valide le JSON avant envoi (message inline si invalide) ; erreurs API save affichées dans la modale (`formError`) ; erreurs list/delete affichées en bannière page (`pageError`, dismissible). `vue-tsc` + build OK.
- [x] **FE-BUG-3** · 🟡 medium · `contacts/index.ts:134-140` · effort: quick
      Fuite d'écouteur `keydown` (retiré seulement sur Échap, pas sur Annuler/overlay/unmount). **(quick win)**
      Fix : retirer `onKey` dans `closeCreateModal` et `unmount`.
      ✅ *Fait (2026-07-03)* : `onKey` hissé dans le scope de `mount` et retiré dans `closeCreateModal` (appelé sur Échap/overlay/Annuler) → nettoyage sur tous les chemins de fermeture.
- [ ] **FE-BUG-4** · 🟡 medium · `createContext.ts:48` · effort: medium
      `entries.list` charge jusqu'à 10 000 entrées côté client.
      Fix : pagination/chargement incrémental, ou filtrage côté serveur. *(lié à FE-PERF-1)*
- [ ] **FE-BUG-5** · ⚪ low · apps impératives · effort: large
      Ré-render `innerHTML` complet détruit focus/scroll/sélection (contourné ponctuellement).
      Fix : migration en composants Vue. *(doublon de FE-ARCH-1)*

## Tests & couverture

- [ ] **FE-TEST-1** · 🟠 high · frontend (0 test) · effort: large
      Aucun test (pas de Vitest/Jest/Playwright). Les 4 apps impératives (~2500 LOC, lieu des XSS/fuites) ne sont pas testées.
      Fix : Vitest + `@vue/test-utils` + `happy-dom` ; helper anti-régression XSS ; script `"test": "vitest"`.
- [ ] **FE-TEST-2** · 🟡 medium · `stores/auth.ts`, `useApi.ts`, gardes de route · effort: medium
      Flux auth + client API non testés (401/logout/guard).
      Fix : tests du store auth + `useApi`.

## Sécurité

- [x] **FE-SEC-1** · 🟠 high · `contacts/index.ts:396-397` · effort: small
      XSS stocké : schéma d'`href` non validé (vCard `URL:javascript:…`) → vol de token au clic.
      Fix : n'autoriser que `http:`/`https:`/`mailto:`/`tel:` pour tout `href` issu de données utilisateur.
      ✅ *Fait (2026-07-03)* : helper `safeUrl/1` (via `new URL`) → n'autorise que `http/https/mailto/tel` ; sinon l'URL est rendue en **texte** (pas de lien). `vue-tsc` OK.
- [x] **FE-SEC-2** · 🟠 high · backend `SpaController`/endpoint · effort: small
      Aucune CSP ni en-tête de sécurité → toute XSS s'exécute librement.
      Fix : CSP stricte (`default-src 'self'`, `script-src 'self'`) sur la réponse HTML du SPA. ⚠️ retirer d'abord les handlers inline (FE-SEC-5).
      ✅ *Fait (2026-07-03)* : CSP + en-têtes (`X-Content-Type-Options: nosniff`, `Referrer-Policy`, `X-Frame-Options: DENY`) posés dans `SpaController`. `script-src 'self'` strict (aucun script inline — HTML buildé n'a qu'un `<script src=...>` externe, FE-SEC-5 a retiré le dernier handler). `style-src 'self' 'unsafe-inline'` conservé (styles inline des apps/Vue). Ne s'applique qu'en **prod** (Vite sert l'index en dev). Test `spa_controller_test.exs`. ⚠️ **À vérifier en navigateur (prod)** : temps réel `/socket` (ws via `connect-src 'self'`), images `/files`, upload — je ne peux pas tester le rendu navigateur ici.
- [ ] **FE-SEC-3** · 🟡 medium · `auth.ts:6,14` · effort: medium
      Token en `localStorage` → volable par XSS.
      Fix (défense en profondeur) : cookie `HttpOnly`+`SameSite`, ou a minima réduire la surface XSS + CSP.
- [ ] **FE-SEC-4** · 🟡 medium · apps (`innerHTML` ~17×) · effort: large
      Surface XSS large par conception (échappement manuel partout — pas d'oubli trouvé, mais régression facile).
      Fix : migration en composants Vue. *(doublon de FE-ARCH-1)*
- [x] **FE-SEC-5** · 🟡 medium · `photos/index.ts:217` · effort: quick
      Handler inline `onerror=` dans `innerHTML` (bloque une CSP sans `unsafe-inline`). **(quick win)**
      Fix : retirer le handler inline (prérequis de FE-SEC-2).
      ✅ *Fait (2026-07-03)* : `onerror` inline retiré ; fallback image cassée re-câblé via `addEventListener("error")` après rendu (classe `ph-thumb-img`). Vérifié : **aucun** handler inline restant dans `apps/` (prérequis CSP FE-SEC-2 levé).

## Performance

- [ ] **FE-PERF-1** · 🟠 high · `createContext.ts:48` + ré-render `innerHTML` · effort: large
      Chargement de toutes les entrées + reconstruction DOM complète à chaque interaction → payload lourd + jank.
      Fix : pagination/scroll infini côté serveur + rendu réactif granulaire. *(lié à FE-BUG-4, FE-ARCH-1)*
- [x] **FE-PERF-2** · 🟡 medium · `contacts/index.ts:221,334`, `photos/index.ts:112` · effort: quick
      Avatars non lazy-loadés (1 seule occurrence de `loading="lazy"` dans tout le front). **(quick win)**
      Fix : ajouter `loading="lazy"` aux `<img>` de listes.
      ✅ *Fait (2026-07-03)* : `loading="lazy"` ajouté aux 2 avatars contacts (liste + détail). Les vignettes photos l'avaient déjà.
- [ ] **FE-PERF-3** · ⚪ low · `connectors.ts` (13 logos SVG inline) · effort: small
      Logos SVG embarqués dans le chunk principal.
      Fix : externaliser en `.svg` ou charger à la demande si le catalogue grandit.
- [ ] **FE-PERF-4** · ⚪ low · `vite.config.ts` · effort: small
      Pas de configuration de chunking (non bloquant).
      Fix : optionnel, surveiller la taille du chunk vendor.

## Clean code

- [x] **FE-CLEAN-1** · 🟡 medium · `apps/{contacts,photos,files,calendar}` · effort: small
      `escapeHtml` redéfini 4× → risque qu'une copie diverge.
      Fix : factoriser dans un module partagé. *(lié à FE-ARCH-1)*
      ✅ *Fait (2026-07-03)* : `apps/escapeHtml.ts` partagé, importé par contacts/photos/files/calendar (4 copies supprimées). Les 2 copies des fichiers notes (`notes/index.ts`, `notes/render.ts`) restent — fichiers de l'agent en cours. `vue-tsc` + build OK.
- [ ] **FE-CLEAN-2** · 🟡 medium · `photos/index.ts` (934 l.), `ConnectorDetailView.vue` (860), etc. · effort: large
      Fichiers volumineux mêlant rendu/logique/état/HTML.
      Fix : découper en sous-composants ; la migration Vue réduirait mécaniquement la taille. *(lié à FE-ARCH-1)*
- [x] **FE-CLEAN-3** · 🟡 medium · `useApi.ts`, `createContext.ts`, `auth.ts` + couleurs hard-codées · effort: medium
      Trois clients HTTP / jetons de thème dupliqués.
      Fix : centraliser. *(doublon de FE-ARCH-3/4)*
      ✅ *Fait (2026-07-03)* : clients HTTP centralisés (voir FE-ARCH-3) ; jetons de thème dupliqués déjà supprimés (FE-ARCH-4).

## Dépendances

- [x] **FE-DEP-1** · 🟠 high · `frontend/package.json` (`vite` 8.0.0) · effort: quick
      2 advisories **HIGH** (path traversal / lecture de fichier via dev server). **(quick win)**
      Fix : `npm audit fix` → `vite 8.0.16` (patch, sans rupture).
      ✅ *Fait (2026-07-03)* : `npm audit fix` → **vite 8.1.3** (advisories HIGH path-traversal / arbitrary-file-read corrigées). `npm run build` OK. Seul `package-lock.json` modifié (bump dans les ranges `^`).
- [x] **FE-DEP-2** · 🟡 medium · transitives (`postcss`, `launch-editor`) · effort: quick
      1 advisory modéré + 1 dev/Windows ; corrigés par le même `npm audit fix`. **(quick win)**
      Fix : `npm audit fix`.
      ✅ *Fait (2026-07-03)* : même `npm audit fix` → `postcss` + `picomatch` corrigés. `npm audit` = **0 vulnérabilité**.
- [x] **FE-DEP-3** · 🟡 medium · `package.json` · effort: small
      Mises à jour mineures sûres (`vue 3.5.30→3.5.38`, `vue-tsc`, `@vueuse/core`, `phoenix 1.8.5→1.8.8`).
      Fix : `npm update` (dans les contraintes `^`).
      ✅ *Fait (2026-07-03)* : `npm update` (32 paquets), `npm audit` = 0 vuln, `vue-tsc` + build OK.
- [ ] **FE-DEP-4** · ⚪ low · `package.json` · effort: medium
      Majeures à planifier (`vue-router 4→5`, `typescript 5.9→6`, `@types/node 24→26`).
      Fix : traiter séparément avec relecture des changelogs.

## Documentation

- [x] **FE-DOC-1** · 🟡 medium · `frontend/README.md` · effort: quick
      README = boilerplate Vite par défaut. **(quick win)**
      Fix : court guide (scripts, proxy Vite, lien DEVELOPMENT.md) ou suppression.
      ✅ *Fait (2026-07-03)* : README réécrit (setup, dev/build, scripts, proxy Vite, structure, liens `DEVELOPMENT.md`/`apps/types.ts`).
- [x] **FE-DOC-2** · 🟡 medium · `apps/types.ts` (contrat non documenté) · effort: small
      Système d'« apps » pluggables (`AppModule`/`AppContext`) non documenté.
      Fix : `apps/README.md` ou section DEVELOPMENT.md (« comment ajouter une app »).
      ✅ *Fait (2026-07-03)* : `frontend/src/apps/README.md` (comment ajouter une app, contrat `AppContext`, conventions escapeHtml/cleanup/fichiers).
- [ ] **FE-DOC-3** · ⚪ low · frontend (JSDoc rare) · effort: small
      Seul `useFetchData.ts` est commenté.
      Fix : quelques commentaires d'intention sur les apps impératives.
