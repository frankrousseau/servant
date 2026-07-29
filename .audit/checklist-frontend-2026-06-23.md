# Checklist d'audit — Servant · **FRONTEND** (Vue 3 SPA)

**Source :** `.audit/code-audit-2026-06-22.md` (passe Frontend)
**Généré le :** 2026-06-23 · **Backend :** voir `.audit/checklist-backend-2026-06-23.md`

**Élagué le 2026-07-29** : les 22 items traités ont été retirés, ainsi que
`FE-TEST-1` (Vitest est en place, ~20 fichiers de test dont les apps) et
`FE-CLEAN-2` (les apps sont des SFC ; le découpage restant est suivi par
`FE2-CLEAN-4` dans la checklist du 2026-07-04).

### Légende

- **Sévérité** : 🔴 critical · 🟠 high · 🟡 medium · ⚪ low
- **Effort** : `quick` (≤15 min, mécanique) · `small` · `medium` · `large` (transversal / risqué)

---

## Tests & couverture

- [ ] **FE-TEST-2** · ⚪ low · `stores/auth.ts`, gardes de route · effort: small
      Flux auth non testé (login/logout, 401, redirection des gardes).
      État 2026-07-29 : `composables/apiClient.test.ts` couvre le client HTTP ; il reste le store `auth` et les gardes du routeur.
