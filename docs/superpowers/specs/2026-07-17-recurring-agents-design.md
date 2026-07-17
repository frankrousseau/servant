# Agents récurrents + section Agents (v1 "rapports seulement")

Date : 2026-07-17. Statut : validé par Frank (conversation du 17/07, après la
livraison du builder). Prérequis : la base agents du matin (ai_config,
Servant.AI, agent_runs, builder).

## Contexte et objectif

Deuxième type d'agent (taxonomie : analyse / récurrent / builder) et la
section Agents dans la sidebar. Décisions actées :

- **Rapports seulement** : un agent récurrent lit des entries et produit un
  rapport (nouvelle entry), rien d'autre. Additif donc sans approbation ;
  la machinerie propose-puis-approuve arrivera avec les vraies actions.
- **Section /agents à onglets** : Récurrents + Builder (Analyse viendra en
  troisième). L'outillage builder déménage de Settings vers l'onglet Builder
  (une fonction, un seul endroit, manifesto). Settings garde la config IA
  (carte Agents réduite) et les apps git/built-ins (carte Apps réduite).
- Doctrine local-first : les récurrents lisent les données personnelles ;
  l'UI affiche le serveur/modèle utilisé et avertit explicitement quand la
  base URL n'est pas locale.

## Modèle de données

### Table `agents`

| Champ | Type | Contraintes |
|---|---|---|
| id | binary_id | |
| user_id | binary_id | FK users, delete_all |
| name | string | requis, <= 60 |
| prompt | string (:text) | requis, <= 4000 |
| kinds | {:array, :string} | requis, non vide, slugs comme enabled_apps |
| lookback_days | integer | 1..365, défaut 7 |
| schedule | string | every_hour / every_day / every_week, défaut every_day |
| enabled | boolean | défaut true |
| last_run_at | utc_datetime | nil au départ |

### `agent_runs`

- Nouvelle colonne `agent_id` (binary_id, FK agents on_delete: :nilify_all,
  nullable ; les runs builder restent agent_id nil).
- `Agents.list_runs(user_id, opts)` gagne des filtres `type:` et `agent_id:`
  (et garde limit). Le sweep lazy des runs "running" > 30 min reste.

### Rapports

Le rapport est une entry ordinaire :

- `kind: "ai_report"`, `source: "agent"`, `title: "{agent.name} - {date ISO}"`,
  `occurred_at: now`.
- `data: %{"content" => markdown}` ; `metadata: %{"agent_id" => id,
  "run_id" => id, "model" => model}`.
- Listés dans l'onglet via GET /api/entries?kind=ai_report (filtre client
  par metadata.agent_id ; à l'échelle personnelle c'est suffisant).

## Exécution

`Servant.Agents.run_agent(user, agent, ai_opts \\ [])`, synchrone :

1. Crée le run (`type: "recurrent"`, `action: "report"`, `agent_id`,
   model de la config).
2. Contexte : `Data.all_entries(user_id, %{"kind" => kind, "from" => now -
   lookback_days})` pour chaque kind, fusionnés triés par occurred_at desc,
   **plafonds : 200 entries et 20 000 caractères** (tronqué, et le prompt le
   dit au modèle). Rendu compact une ligne par entry : date | titre | data
   JSON compacté.
3. System prompt sobre : rédige un rapport markdown à partir des données
   fournies, n'invente rien, signale si les données sont vides/tronquées.
   User message : le prompt de l'agent + le contexte.
4. `Servant.AI.chat` (config globale de l'utilisateur). Réponse -> entry
   ai_report + `complete_run` (tokens, durée). Échec -> `fail_run`.
   try/rescue comme le builder : fail_run puis reraise.
5. `last_run_at` est mis à jour au début du run (succès OU échec), pour
   qu'un agent en erreur ne retente qu'au prochain intervalle.

Gating : run_agent refuse si `Accounts.ai_enabled?(user)` est false ou si
l'agent est disabled (le scheduler saute silencieusement ces cas).

## Scheduler

`Servant.Agents.Scheduler` (GenServer, après le Task.Supervisor dans
l'arbre) :

- Tick toutes les 60 s (`Process.send_after`). Au tick : si une exécution
  précédente tourne encore (ref monitorée en state), skip ; sinon spawn une
  Task supervisée qui appelle `Agents.run_due(now)`.
- `run_due/1` : sélectionne les agents enabled dont `last_run_at` est nil ou
  échu (`+ 3600 / 86400 / 604800 s` selon schedule), charge chaque user, et
  exécute **séquentiellement** (ponytail : sérialisation globale, un seul
  modèle local de toute façon ; per-user si multi-user actif un jour).
  Chaque agent est rescué individuellement.
- Test env : `config :servant, Servant.Agents.Scheduler, tick: false` (pas
  de timer armé) ; `run_due` est testé en direct.
- "Run now" (UI) passe par l'API et exécute en Task supervisée (mêmes
  chemins), sans attendre le schedule.

## API

Routes session-only, gated par un plug partagé `ServantWeb.Plugs.RequireAgents`
(extrait du plug privé actuel d'AppController, réutilisé par les deux
contrôleurs) :

- `GET/POST /api/agents`, `GET/PUT/DELETE /api/agents/:id` (CRUD, scoping
  user_id, 404 cross-user).
- `POST /api/agents/:id/run` -> 202 `{data: run}` (Task supervisée).
- `GET /api/agents/runs?type=&agent_id=` et `GET /api/agents/runs/:id`
  **remplacent** `/api/apps/runs*` (supprimés ; committés ce matin, jamais
  déployés, zéro consommateur externe). Déclarées avant le resources pour
  que "runs" ne soit pas capturé comme :id.
- AppController garde generate/modify/restore (ils agissent sur des apps) ;
  son plug require_agents devient le plug partagé ; `run_json/1` (qui gagne
  `agent_id`) part dans un helper partagé `ServantWeb.AgentRunJSON`,
  importé par les deux contrôleurs.
- `"agents"` rejoint les `@reserved_ids` d'Apps (la route SPA /agents existe
  désormais).

## Frontend

### Section Agents (`/agents`, sidebar après Connectors, icône Wrench)

`AgentsView.vue`, onglets via `?tab=recurrents|builder` (défaut recurrents).
Bandeau commun : modèle/serveur configurés ; si la base URL n'est pas
locale (host hors localhost/127.0.0.1/[::1]), hint explicite "these agents
send your data to {host}". Si les agents sont désactivés : message + lien
vers Settings (pas de formulaire).

**Onglet Récurrents** :
- Liste des agents : nom, schedule, kinds, toggle enabled, dernier run
  (statut + date), boutons Run now / Edit / Delete (confirm).
- Formulaire création/édition : name, prompt (textarea), kinds (input texte,
  liste séparée par virgules, hint vers les kinds existants), lookback_days
  (number), schedule (ComboBox 3 valeurs).
- Run now : 202 + poll du run (2 s, comme le builder) ; à la fin, refresh
  de la liste des rapports.
- Rapports : derniers ai_report de l'agent (fetch kind=ai_report, filtre
  client metadata.agent_id), dépliables sur place, contenu rendu en texte
  préformaté (ponytail : markdown riche plus tard ; réutiliser le renderer
  des notes si trivialement importable).
- Runs récents (table compacte : date, statut, modèle, tokens, durée).

**Onglet Builder** (déménagement depuis Settings, sans changement
fonctionnel) : formulaire generate, liste des apps générées (modify /
restore / uninstall), runs builder (`type=builder`). Le poll passe par
`/api/agents/runs/:id`.

### Settings (slim-down)

- Carte Agents : config seule (toggle + base URL + modèle + clé). La table
  des runs part dans la section.
- Carte Apps : built-ins + apps git seulement (les apps générées et leurs
  actions vivent dans l'onglet Builder ; uninstall des générées incluse).

### Store / types

- `types.ts` : interface `Agent` ; `AgentRun` gagne `agent_id: string | null`.
- Pas de nouveau store Pinia (appels api locaux à la vue, comme
  ConnectorsView) ; `stores/apps.ts` inchangé sauf rien (le poll est dans
  les vues).

## Conformité manifesto

Tokens/modèle/durée par run (déjà), modèle affiché dans la section, hint
serveur non-local (doctrine local-first), off par défaut via le toggle
global existant, copy sobre, une fonction un seul endroit (déménagement,
pas duplication), limites annoncées (le rapport peut être faux ou
incomplet ; mention dans l'onglet).

## Hors scope v1

Propose-puis-approuve, onglet Analyse, heure fixe des schedules, modèle par
agent, notifications, pagination/recherche des rapports, markdown riche,
parallélisme des runs.

## Tests

- Contexte : CRUD scoping ; due (nil, échu, pas échu, disabled, ai off) ;
  run_agent stubé (entry créée avec metadata, run ok tokens, contexte
  plafonné, échec AI -> run error, raise -> fail_run + reraise,
  last_run_at posé dans tous les cas) ; list_runs filtres type/agent_id.
- Scheduler : run_due direct (séquence, rescue par agent) ; pas de test de
  timer.
- Contrôleurs : gating 403, CRUD + 404 cross-user, run manuel 202 pollable
  (monitor/DOWN comme le builder), runs déplacés (ancien /api/apps/runs
  404), filtre type.
- Frontend : build + vitest existants ; pas de nouveau test UI.

## Docs

- `docs/custom-apps.md` : les références "Settings > Apps" du builder
  pointent vers "Agents > Builder".
- `DEVELOPMENT.md` : bullet Agents étendu (récurrents + section).
- `docs/ai-agents-plan.md` : bandeau en tête "partiellement implémenté,
  voir DEVELOPMENT.md" (le document reste comme notes historiques).

## Migration / déploiement

Deux migrations (create_agents, add_agent_id_to_agent_runs). Rien d'autre :
pas de nouvelle dépendance, pas de changement d'image Docker.
