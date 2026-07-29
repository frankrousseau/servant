# Backlog

Ce qui reste à faire, extrait des specs des features déjà livrées (sections
"hors scope v1") et vérifié contre le code au 2026-07-29. Les plans et designs
des features livrées ont été supprimés : ils restent dans l'historique git
(`specs/plans/`, `specs/designs/`, `specs/PLAN.md`, `specs/ai-agents-plan.md`).

Rien ici n'est engagé : c'est une liste d'idées, pas une roadmap.

## Agents

- **Tool use / boucle agentique** : l'agent peut interroger et créer des entries
  lui-même au lieu de recevoir un contexte figé, puis chaînes d'agents. Demande
  un modèle fiable en function calling (les petits modèles locaux ne le sont pas).
- **Modèle par agent** : aujourd'hui un seul modèle pour toute la config IA
  (`users.ai_config`), pas de champ `model` sur `agents`.
- **Propose-puis-approuve** : un run produit une proposition que l'utilisateur
  valide avant écriture, au lieu d'écrire directement son entry.
- **Notifications** : rien dans le code n'envoie de notification (ni agents, ni
  connecteurs). Prérequis d'une alerte type "dépense > X".
- **Streaming** des réponses, **parallélisme des runs** (aujourd'hui séquentiel
  dans le Scheduler), heure fixe pour les schedules (only every_hour/day/week).
- **Rapports** : pagination et recherche dans l'historique, markdown riche.

## Recettes (agents déterministes)

- OR dans les filtres `where`, agrégats multiples, `emit_if` par groupe
  (aujourd'hui exclusif de `group_by`), buckets sur un champ autre que
  `occurred_at`.
- Recettes multi-étapes et éditeur visuel de recette (aujourd'hui : rédigée une
  fois par le modèle, puis JSON).

## Builder d'apps

- Apps multi-fichiers, git par app (une app générée n'a pas d'historique),
  choix de l'icône par le modèle, event channel dédié pour suivre un run.

## Contacts

- Export vCard des tags (`CATEGORIES`) et des relations (`RELATED`) : les deux
  vivent dans `data`, le codec CardDAV ne les sérialise pas, donc ils ne
  remontent pas sur le téléphone.
- Filtre multi-tags (un seul tag actif aujourd'hui), renommage global d'un tag,
  types de relation personnalisés.
- **Fiche contact : afficher les événements liés** (agenda) et un **aperçu des
  photos** où le contact apparaît, pour que la fiche agrège tout ce qui le
  concerne au lieu des seuls champs vCard.
- **Graphe de relations : les arêtes se chevauchent** et deviennent illisibles
  dès qu'un contact a plusieurs relations. Revoir le placement (répulsion des
  arêtes, courbure, ou layout radial).

## Notes

- **Ouvrir une note dans un nouvel onglet** : une note doit être un vrai lien
  (URL propre, clic milieu et "ouvrir dans un nouvel onglet" fonctionnels), pas
  seulement une sélection dans l'app.

## Files

- **Statistiques de dossier dans le panneau de droite** : nombre de fichiers,
  nombre de sous-dossiers, taille totale.

## Checklists

- Dossiers imbriqués, réordonnancement des items (le drag ne couvre que les
  listes et l'ordre des dossiers), dates d'échéance, reset automatique planifié.

## API

- Validation des requêtes à partir du spec OpenAPI (v1 = documentation seule).
- SwaggerUI charge son JS/CSS depuis un CDN : à embarquer si l'instance doit
  fonctionner hors ligne.
