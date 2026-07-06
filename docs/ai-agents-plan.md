# Agents IA : Réflexion

## Concept

Lancer un agent IA à intervalle régulier (cron) pour analyser, enrichir ou résumer les données collectées par Servant.

## Ce qu'on a déjà

- **Scheduler + Worker** : GenServer par connecteur sur un schedule (every_5_minutes, every_hour, etc.) avec `Process.send_after`
- **Sync logs** : historique des exécutions avec statut/durée/erreur
- **Entries universelles** : toutes les données sont dans un format unifié (kind, source, data JSON)

## Ce qu'il faudrait ajouter

### 1. Nouveau type d'entité : "Agent"

Pas un connecteur : un agent IA a un **prompt**, pas juste une config de sync.

- Table `agents` : nom, prompt système, schedule, provider, modèle, enabled
- Historique d'exécutions avec input/output

### 2. Module `Servant.AI` : abstraction multi-provider

Un module unique qui route vers le bon backend :

```elixir
Servant.AI.chat(provider_config, messages)
# provider_config = %{provider: "ollama", model: "llama3.1:8b", base_url: "http://localhost:11434"}
# provider_config = %{provider: "anthropic", model: "claude-sonnet-4-6", api_key: "sk-..."}
```

Supporte deux providers :

| | Ollama (self-hosted) | Anthropic (cloud) |
|--|---------------------|-------------------|
| **API** | `POST http://localhost:11434/api/chat` | `POST https://api.anthropic.com/v1/messages` |
| **Auth** | Aucune | `x-api-key` header |
| **Modèles** | llama3.1:8b, phi-3:3.8b, qwen2.5:3b, mistral:7b | claude-sonnet, claude-haiku |
| **Coût** | Électricité | ~$0.003-0.015/requête |
| **Vie privée** | Tout reste en local | Données envoyées à Anthropic |
| **Qualité** | Correcte (résumé, catégorisation) | Excellente (raisonnement, analyse) |

### 3. Choix techno : Ollama pour le self-hosted

**Pourquoi Ollama :**
- Standard de facto pour l'inférence locale
- Installation triviale : `curl -fsSL https://ollama.com/install.sh | sh`
- API HTTP simple, quasi compatible OpenAI
- Tourne sur Raspberry Pi 5 (lent mais fonctionne)
- Gère le téléchargement des modèles : `ollama pull llama3.1:8b`

**Modèles recommandés par hardware :**

| Hardware | Modèle | RAM | Latence | Qualité |
|----------|--------|-----|---------|---------|
| Raspberry Pi 5 (8GB) | phi-3:3.8b, qwen2.5:3b | ~2-3GB | 30-120s | Basique |
| PC/NUC (16GB RAM) | llama3.1:8b, mistral:7b | ~5-8GB | 10-30s | Bonne |
| GPU consumer (RTX 3060+) | llama3.1:8b | ~5GB VRAM | 2-5s | Bonne |

**Sweet spot self-hosted :** `llama3.1:8b` sur un NUC ou mini-PC avec 16GB RAM.

### 4. Moteur d'exécution

- Un `AgentWorker` GenServer (similaire au `Connectors.Worker` actuel)
- À chaque tick : construit le prompt avec le contexte, appelle `Servant.AI.chat/2`, parse la réponse, crée des entries ou exécute des actions
- Timeout adaptatif : 60s pour Anthropic, 5min pour Ollama CPU
- Sérialisation des requêtes (un seul modèle à la fois sur GPU consumer)

### 5. Contraintes du local

- **Contexte limité** : 8K-32K tokens (vs 200K Claude). Il faut résumer/filtrer les entries avant de les passer au modèle
- **Pas de tool use fiable** : les petits modèles sont mauvais en function calling. Réservé au niveau "avancé" avec Anthropic uniquement
- **Concurrence** : les requêtes Ollama sont sérialisées. Un seul agent tourne à la fois

### 6. Questions de design ouvertes

**Quel contexte donner à l'agent ?** C'est la question clé. Quelques patterns :
- "Résume mes transactions de la semaine" → query les entries récentes, les passe au prompt
- "Catégorise mes nouvelles transactions" → prend les entries non-catégorisées, enrichit les metadata
- "Alerte-moi si dépense > X" → query + logique conditionnelle

**Que fait l'agent avec sa réponse ?** Créer des entries (kind: "ai_summary") ? Modifier des entries existantes (enrichissement) ? Envoyer une notification ?

**Outils / function calling ?** Si l'agent peut appeler des fonctions (query entries, créer entries, etc.), ça devient un vrai agent avec tool use. Sinon c'est juste un prompt → texte. Tool use = Anthropic only (les petits modèles locaux ne sont pas fiables pour ça).

## Niveaux d'implémentation

| Niveau | Scope | Compatible local | Effort |
|--------|-------|-----------------|--------|
| **Simple** | Cron qui envoie un prompt fixe + contexte, stocke la réponse comme entry | Oui | ~1 jour |
| **Moyen** | + sélection dynamique du contexte (query entries par kind/date), + templates de prompt | Oui | ~2-3 jours |
| **Avancé** | + tool use (l'agent peut query/créer/modifier des entries), + chaînes d'agents | Anthropic only | ~1 semaine+ |

## Recommandation

1. Implémenter le module `Servant.AI` avec Ollama comme provider par défaut et Anthropic en option
2. Commencer par le niveau "simple" : un cron qui résume les données de la semaine
3. Le `Worker` existant peut être réutilisé presque tel quel
4. Config dans Settings : URL Ollama, modèle par défaut, clé API Anthropic (optionnelle)
5. La vraie valeur arrive au niveau "moyen" quand l'agent a accès au contexte filtré des entries
