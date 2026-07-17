# Agents : base commune + builder d'apps (v1)

Date : 2026-07-17. Statut : validé par Frank (conversation du 17/07).

## Contexte et objectif

Servant doit héberger trois types d'agents IA, distingués par niveau de confiance
et non par runtime : 1) exploration/analyse de données (conseille), 2) actions
récurrentes (agit, avec propose-puis-approuve), 3) builder (construit des apps).
Cette v1 livre la base commune (config, client IA, historique de runs) et le
type 3 uniquement : un agent qui génère et modifie des custom apps par
utilisateur, en réutilisant le rail d'installation existant (docs/custom-apps.md).

Contraintes actées :

- Neutralité de modèle : aucun vendeur imposé, modèle local proposé en premier.
- Conformité au Sustainable AI Manifesto (voir section dédiée).
- Désactivé par défaut, activation explicite dans Settings avec confirmation.
- Pas de harness agentique : la génération d'app est un appel chat one-shot,
  pas de tool-use, pas de subprocess.

## Décisions structurantes

1. **Un seul protocole** : client OpenAI chat completions (`POST
   {base_url}/chat/completions`). Couvre Ollama, LM Studio, vLLM, Mistral,
   OpenAI et Anthropic (endpoint de compatibilité). Défaut suggéré dans l'UI :
   `http://localhost:11434/v1` (Ollama local, sans clé).
2. **One-shot, un seul fichier** : le modèle rend un unique bloc ```js (le
   module d'entrée AppModule). Servant fabrique lui-même `servant-app.json`.
   Fiable avec des petits modèles locaux, rien de fragile à parser.
3. **Base commune agents** : la config IA et la table `agent_runs` (avec champ
   `type`) sont partagées par les trois types. La table `agents` (nom, prompt,
   schedule) n'existe pas encore : le builder est une action à la demande sans
   état persistant. Elle arrivera avec les types 1 et 2.

## Architecture

### Config utilisateur

Colonne `ai_config` sur `users`, type `Servant.Encrypted.Map` (même mécanisme
que les secrets de connecteurs). Contenu :

```json
{
  "enabled": false,
  "base_url": "http://localhost:11434/v1",
  "model": "qwen2.5-coder:14b",
  "api_key": null
}
```

- `enabled` : false par défaut ; toute la feature est inerte tant que false.
- `api_key` optionnelle (absente pour Ollama local).
- Lecture API : la clé est masquée (`"***"` si présente, null sinon).
- Pas de guard SSRF sur `base_url` : localhost est le cas nominal (config
  volontaire de l'utilisateur pour son propre serveur). Documenté.

### Client IA : `Servant.AI`

Un module, une fonction principale :

```elixir
Servant.AI.chat(config, messages)
# -> {:ok, %{content: binary, usage: %{input_tokens: n, output_tokens: n} | nil}}
# -> {:error, reason}
```

- Req, `receive_timeout` 300 000 ms (CPU local lent), pas de streaming en v1.
- Header `authorization: Bearer <key>` seulement si clé présente.
- `usage` extrait de la réponse quand le serveur le fournit (Ollama et les
  API cloud le renvoient), nil sinon.

### Flux builder : `Servant.Apps.Generator`

**Générer** (`generate(user, %{name, description})`) :

1. System prompt : contrat AppModule (default export `{mount(el, ctx),
   unmount(el)}`, `ctx.api` pour les entries, DOM pur sans imports, module
   auto-suffisant) + consignes de sobriété. User prompt : nom + description.
2. Extraction du dernier bloc ```js de la réponse. Validation minimale :
   non vide et contient `export default`. Échec -> un retry unique avec
   l'erreur en contexte, puis échec propre du run.
3. Manifest fabriqué par Servant : `id` = slug du nom saisi (validé contre
   les ids réservés existants), `entry` = `"index.js"`, `icon` = `"Puzzle"`.
4. Écriture directe dans le dossier d'install
   (`FILES_DIR/{user}/installed_apps/{id}/`) : `index.js` +
   `servant-app.json`. Ligne `UserApp` avec `repo_url` nil.

**Modifier** (`modify(user, app_id, instruction)`) : source actuelle envoyée
en contexte + instruction -> fichier complet réécrit. L'ancien `index.js`
devient `index.prev.js` avant écrasement.

**Restaurer** (`restore(user, app_id)`) : swap `index.js` et `index.prev.js`.
Une seule version de recul, pas de git par app.

`repo_url` devient nullable sur `user_apps` (retiré du `validate_required` ;
le chemin git le renseigne toujours). Le frontend distingue : `repo_url`
présent = app git (bouton mise à jour), nil = app générée (modifier /
restaurer). Modifier et restaurer refusent les apps git.

### Runs : table `agent_runs`

| Champ | Type | Note |
|---|---|---|
| id | binary_id | |
| user_id | binary_id | scopé comme tout le reste |
| type | string | `"builder"` en v1 ; `"explorer"`, `"recurrent"` plus tard |
| app_id | string | nullable, l'app concernée pour le builder |
| action | string | `"create"` ou `"modify"` |
| status | string | `"running"`, `"ok"`, `"error"` |
| model | string | modèle utilisé (manifesto : informer) |
| input_tokens / output_tokens | integer | nullable |
| duration_ms | integer | |
| prompt | string | la demande utilisateur |
| error | string | nullable, tronqué |

Exécution en `Task` supervisée (`Task.Supervisor` dédié) : le run est créé
`"running"`, la tâche fait l'appel IA + l'installation, puis met à jour le
run. Le frontend poll le run toutes les 2 s (pas de nouvel event channel).

### API

Toutes ces routes sont session-only (comme l'install git) et renvoient 403
si `enabled` est false (sauf la config elle-même) :

- `GET /api/ai_config` : config, clé masquée.
- `PUT /api/ai_config` : met à jour ; une clé `"***"` reçue = inchangée.
- `POST /api/apps/generate` `{name, description}` -> 202 `{run_id}`.
- `POST /api/apps/:app_id/modify` `{instruction}` -> 202 `{run_id}`.
- `POST /api/apps/:app_id/restore` -> 200.
- `GET /api/apps/runs/:id` -> statut, tokens, modèle, durée, erreur.
- `GET /api/apps/runs` -> historique (pour la carte Settings).

### Frontend

**Settings, nouvelle carte "Agents"** :

- Toggle off par défaut ; l'activation ouvre un dialog de confirmation qui
  dit ce que ça active, quel serveur sera contacté, et les limites (le code
  généré peut être incorrect, à vérifier avant de lui confier ses données).
- Champs : base URL (placeholder Ollama), modèle, clé API (optionnelle).
- Historique des runs : date, action, app, modèle, tokens, durée, statut.

**Settings, carte "Apps" existante** (visible seulement si agents activés) :

- Formulaire "Créer une app" : nom + description + bouton Générer, avec le
  modèle utilisé affiché à côté du bouton.
- Sur une app générée : bouton Modifier (textarea instruction), bouton
  Restaurer (si `index.prev.js` existe), Désinstaller (existant).
- Pendant un run : statut inline (en cours -> ok / erreur), via polling.

## Conformité Sustainable AI Manifesto

- Choix du modèle, local en premier : un protocole neutre, défaut Ollama.
- Tracking de la consommation : tokens in/out, durée et modèle par run,
  historique visible dans Settings. Carbone différé (facteurs par modèle
  trop spéculatifs aujourd'hui) ; en attendant, tokens + modèle affichés.
- Modèle utilisé affiché à côté de chaque point d'entrée de génération.
- Off par défaut, activation avec confirmation, désactivable à tout moment.
- Limites (hallucination, code à vérifier) annoncées dans le dialog et la carte.
- UX sobre : pas d'icône étincelle, pas de nom d'assistant, pas de métaphore
  magique ; les libellés disent ce que la fonction fait. La fonction
  n'apparaît qu'à un seul endroit (Settings > Apps). Pas d'onboarding pushy.

## Doctrine trust levels (pour les slices suivantes)

- **Builder** (cette v1) : ne voit que l'intention et le contrat d'app,
  jamais les données personnelles ; un modèle cloud est donc acceptable ici.
- **Explorer** (type 1) : lira les entries, donc local-first fortement
  recommandé ; nécessitera la table `agents` (prompt, schedule).
- **Récurrent** (type 2) : mode propose-puis-approuve obligatoire avant toute
  autonomie ; le builder pourra en écrire la logique comme code déterministe
  (LLM au moment de l'écriture, pas de l'exécution).

## Hors scope v1

Streaming, apps multi-fichiers, boucle agentique/tool-use, git par app,
event channel dédié, estimation carbone, choix d'icône par le modèle,
table `agents`, types explorer et récurrent.

## Tests

- `Servant.AI` : requête formée (URL, bearer conditionnel), parsing content
  + usage, erreurs HTTP (Req.Test).
- `Generator` : fence valide -> app installée ; pas de fence -> retry puis
  erreur ; `export default` manquant -> retry ; modify écrit `index.prev.js` ;
  restore swappe ; refus sur app git ; slug en collision avec ids réservés.
- Contrôleurs : 403 quand disabled, 202 + run pollable, clé masquée en GET,
  clé `"***"` non écrasée en PUT.

## Déploiement

Rien à ajouter à l'image Docker : le serveur de modèle (Ollama ou autre) est
fourni par l'utilisateur et configuré par URL. Une migration (`ai_config` +
`agent_runs` + `repo_url` nullable).
