# Checklist d'audit — Servant · **BACKEND** (Phoenix / Elixir)

**Source :** `.audit/code-audit-2026-06-22.md` (passe Backend)
**Généré le :** 2026-06-23 · **Frontend :** voir `.audit/checklist-frontend-2026-06-23.md`

**Élagué le 2026-07-29** : les 45 items traités ont été retirés. Retirés aussi
les items repris à l'identique par la checklist du 2026-07-04, où ils sont
suivis (`BE-ARCH-3` → `BE2-ARCH-3`, `BE-SEC-10` → `BE2-SEC-6`, `BE-PERF-4` →
`BE2-PERF-4`, `BE-CLEAN-5` → `BE2-CLEAN-4`). Vérifiés faits depuis et retirés :
`BE-TEST-4` (chaque contrôleur a son test), `BE-SEC-5` (`verify_peer` par
défaut, `verify: false` au cas par cas), `BE-DEP-4` (`gettext` et `dns_cluster`
ne sont plus dans `mix.exs`).

### Légende

- **Sévérité** : 🔴 critical · 🟠 high · 🟡 medium · ⚪ low
- **Effort** : `quick` (≤15 min, mécanique) · `small` · `medium` · `large` (transversal / risqué)

---

## Architecture

- [ ] **BE-ARCH-5** · 🟡 medium · `connector_controller.ex:163`, `entry_controller.ex`, `export_controller.ex` · effort: medium
      Sérialisation JSON dispersée et reconstruite à la main par contrôleur → dérive du contrat avec `frontend/src/types.ts`.
      Fix : extraire des modules/fonctions de sérialisation partagés (source unique). *(lié à BE-CLEAN-1)*
      État 2026-07-29 : seuls `agent_run_json.ex` et `error_json.ex` sont partagés ; entries, connecteurs et exports restent sérialisés à la main dans chaque contrôleur.
