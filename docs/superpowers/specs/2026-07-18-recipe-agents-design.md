# Agents recettes (scripts récurrents déterministes)

Date : 2026-07-18. Statut : validé par Frank (conversation du 18/07).
Prérequis : la base agents (ai_config, Servant.AI, agent_runs, table agents,
scheduler) et la section Agents livrées le 17/07.

## Contexte et objectif

Idée actée lors de la taxonomie : le LLM écrit l'automatisation, le serveur
l'exécute en code déterministe. LLM au moment de l'écriture, zéro token à
l'exécution. Usages cibles validés : agrégats chiffrés (somme des bank_tx
par catégorie chaque semaine), digests filtrés (events à venir, notes
taguées), alertes à seuil (rapport seulement si une condition est vraie).
Le nettoyage/maintenance est hors cible.

Décisions actées :

- **Recette déclarative, pas de code généré** : un JSON à forme fixe,
  validé strictement, interprété en Elixir. Aucun sandboxing nécessaire.
- **Autorat LLM puis éditable** : description en langage naturel, le modèle
  génère la recette, elle reste éditable à la main avant sauvegarde.
- **Sortie kind "report"** (nouveau), distinct d'ai_report : un run de
  recette est du calcul pur, l'étiquette "ai" serait mensongère (manifesto).
- **Même onglet Récurrents** : un agent gagne un mode "prompt" ou "recipe" ;
  même table, même scheduler, mêmes runs, même liste.
- **Moteur : interpréteur Elixir en mémoire** (pas de SQL dynamique) ;
  suffisant à l'échelle personnelle, simple et testable.

## Modèle de données

### Table `agents` (migration additive)

| Champ | Type | Contraintes |
|---|---|---|
| mode | string | "prompt" (défaut) ou "recipe" |
| recipe | map (JSON) | nullable ; requise et valide si mode recipe |

Validation croisée du changeset : mode prompt exige `prompt` ; mode recipe
exige `recipe` valide (le prompt devient optionnel). Les champs existants
(`name`, `kinds`, `lookback_days`, `schedule`, `enabled`, `last_run_at`)
servent aux deux modes.

### Rapport produit

Entry ordinaire : `kind: "report"`, `source: "agent"`,
`title: "{agent.name} - {date ISO}"`, `occurred_at: now`,
`data: %{"content" => markdown}`,
`metadata: %{"agent_id" => id, "run_id" => id}`. Pas de clé `model` :
rien d'un modèle n'y figure.

### Runs

Réutilisation d'`agent_runs` tel quel : type "recurrent", action "report",
`model`, `input_tokens`, `output_tokens` nil pour un run de recette.
Le draft LLM (voir Autorat) crée un run action "draft_recipe" avec tokens
et modèle renseignés.

## La recette (DSL à forme fixe)

Un objet JSON à champs connus ; toute clé inconnue est rejetée.

```json
{
  "where": [{"field": "data.category", "op": "eq", "value": "grocery"}],
  "group_by": "data.category",
  "aggregate": {"op": "sum", "field": "data.amount"},
  "emit_if": {"op": "lt", "value": 100}
}
```

- **Sélection** : les champs de l'agent (`kinds`, `lookback_days`) donnent
  la fenêtre, identique aux agents à prompt (bornée en arrière seulement ;
  les events futurs passent).
- **where** (optionnel) : liste de conditions en AND.
  `field` = chemin pointé whitelisté (`title`, `source`, `occurred_at`,
  `data.<...>`, `metadata.<...>`) ; `op` dans
  `eq, neq, contains, gt, gte, lt, lte, exists`. Les ops numériques exigent
  une valeur numérique ; `contains` une chaîne ; `exists` pas de valeur.
  Une entry dont le champ manque ne matche aucune condition ; `exists`
  teste la présence du champ.
- **group_by** (optionnel) : un chemin de champ, ou un bucket temporel
  `day | week | month` appliqué à `occurred_at`.
- **aggregate** (optionnel) : `{op, field}` avec op dans
  `sum, avg, count, min, max, last` ; `count` sans champ ; `last` = valeur
  du champ de l'entry la plus récente (cas "dernier solde"). Absent →
  mode digest : liste "date | titre", une ligne par entry.
- **emit_if** (optionnel) : `{op, value}` avec op dans
  `eq, neq, gt, gte, lt, lte`, appliqué à l'agrégat global uniquement ;
  incompatible avec `group_by` (rejeté à la validation). Si la condition
  est fausse : run ok, aucun rapport créé (alerte silencieuse).
- **Format de sortie déduit** : group_by + aggregate → tableau markdown ;
  aggregate seul → chiffre commenté d'une ligne ; sans aggregate → liste.
  Pas de champ format.

## Exécution

Nouveau module `Servant.Agents.Recipe` :

- `validate/1` : recette → `:ok | {:error, message}` ; whitelist stricte
  (clés, ops, chemins de champs, types des valeurs).
- `run/2` (agent, entries) : filtre, groupe, agrège, rend le markdown.
  Retourne `{:ok, content} | :skip` (emit_if faux).

Le chemin de run existant (`prepare_run` → exécution → store/complete)
branche sur `agent.mode` :

- **recipe** : chargement des entries de la fenêtre **sans plafond**
  (requête directe par kinds + from, pas le cap 200/20k des prompts : un
  agrégat tronqué est un chiffre faux et il n'y a aucun coût de tokens),
  interprétation, entry `report`, `complete_run` (tokens et model nil).
  `:skip` → `complete_run` sans entry créée.
- **prompt** : chemin actuel inchangé.

Scheduler inchangé (il ne connaît pas le mode). Gating inchangé : le
toggle global Settings > Agents gouverne les deux modes ; l'activation
exige toujours un modèle configuré (l'autorat est LLM-first de toute
façon).

## Autorat (LLM puis éditable)

`POST /api/agents/draft_recipe` avec `{description, kinds}` :

1. System prompt : doc du DSL, kinds choisis, et **les clés seulement**
   (jamais les valeurs) d'un échantillon d'entries récentes de ces kinds,
   pour que le modèle connaisse les champs disponibles (`data.amount`,
   `data.category`...). Aucune donnée personnelle n'est envoyée.
2. `Servant.AI.chat` ; la réponse doit être un JSON de recette (fence ou
   brut). Parse + `Recipe.validate/1` ; en cas d'échec, une relance de
   réparation avec le message d'erreur (usage cumulé), comme le builder.
   Deuxième échec → 422 avec le message.
3. Chaque draft crée un `agent_run` (type "recurrent", action
   "draft_recipe", agent_id nil, tokens + modèle renseignés) : l'appel
   d'écriture est tracé, l'exécution n'en fera aucun.
4. Réponse : `{data: %{recipe: ..., run_id: ...}}`. La recette part dans
   le textarea éditable côté client ; la sauvegarde repasse par la
   validation du changeset.

## API

- `POST /api/agents/draft_recipe` (session-only, plug RequireAgents,
  mêmes règles que le reste de la section).
- CRUD agents : `mode` et `recipe` castés et validés ; `recipe` acceptée
  en map JSON.
- Schémas OpenApiSpex mis à jour (Agent + requête/réponse draft_recipe).

## Frontend (onglet Récurrents)

- **Formulaire** : sélecteur de mode (ComboBox "Prompt" / "Recette").
  Mode prompt : formulaire actuel. Mode recette : textarea description +
  bouton "Generate recipe" (spinner pendant l'appel) → textarea JSON
  éditable pré-rempli (pretty-printed) ; sauvegarde envoie le JSON parsé
  (erreur de parse affichée côté client avant envoi).
- **Liste** : badge du mode par agent.
- **Rapports** : la liste fusionne `ai_report` et `report` (deux fetchs,
  tri par date) ; l'onglet Rendered existant s'applique tel quel aux
  tableaux markdown.
- **Runs** : colonne modèle affichée "-" quand model est nil (petit
  ajustement du template).
- Types : `Agent` gagne `mode` et `recipe`.

## Conformité manifesto

Zéro token à l'exécution ; l'unique appel LLM (draft) est tracé dans les
runs avec tokens et modèle ; la sortie déterministe n'est pas étiquetée
"ai" ; clés d'entries seulement dans le prompt de draft (pas de valeurs) ;
copy sobre ; une fonction, un seul endroit (même onglet).

## Hors scope v1

OR dans les filtres, multi-agrégats, emit_if par groupe, buckets sur un
autre champ qu'occurred_at, éditeur visuel de recette, notifications,
recettes multi-étapes, plafonds de volume (à revoir si un jour une fenêtre
dépasse la mémoire raisonnable).

## Tests

- `Recipe.validate/1` : clés inconnues, ops invalides, chemins hors
  whitelist, types de valeurs, emit_if + group_by rejeté.
- Interpréteur : chaque op de filtre (champ manquant inclus), buckets
  day/week/month, chaque agrégat (dont `last` et `count` sans champ),
  digest, formats déduits, emit_if vrai/faux (`:skip`).
- Exécution : branche recipe sans aucun appel AI (pas de stub touché),
  entry `report` avec metadata sans model, run complété tokens nil,
  `:skip` → run ok sans entry, pas de plafond (301 entries → 301 comptées).
- Draft : stub Req.Test (JSON valide, JSON invalide puis réparé, double
  échec → 422), run "draft_recipe" créé avec tokens.
- CRUD : mode/recipe validés, mode prompt inchangé.
- Frontend : build + vitest existants.

## Docs

- `DEVELOPMENT.md` : bullet Agents étendu (mode recette, kind report).
- `docs/superpowers/plans/` : plan d'implémentation séparé.

## Migration / déploiement

Une migration additive (mode + recipe sur agents). Pas de nouvelle
dépendance, pas de changement d'image Docker.
