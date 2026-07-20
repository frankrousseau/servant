# Tags et relations entre contacts

Date : 2026-07-20. Statut : validé par Frank (conversation du 20/07).
Contexte : la page Contacts vient d'être unifiée (création, vue complète et
édition dans la colonne de détail, commit 596f15c). Frank veut organiser ses
contacts (tags) et relier les fiches entre elles (parenté, amitié, travail).

## Décisions actées

- **Tags en chips cliquables** : rangée de tous les tags sous la recherche,
  clic = filtre ; les tags des fiches sont cliquables aussi ; la recherche
  texte matche les tags.
- **Relations réciproques automatiques** : ajouter une relation l'écrit sur
  les deux fiches (avec inversion parent/child) ; supprimer retire des deux
  côtés.
- **Liste fixe de types** : partner, parent, child, sibling, friend,
  colleague. Pas de texte libre.
- **Zéro backend** : tout vit dans `contact.data` (entries schemaless),
  aucune migration, aucun changement d'API ni de DAV.

## Modèle de données

Dans `contact.data` :

```json
{
  "tags": ["famille", "lyon"],
  "relations": [{ "contact_id": "<uuid>", "type": "friend" }]
}
```

- **tags** : chaînes libres normalisées (trim, minuscules, dédupliquées,
  vides rejetées). Absent = pas de tags.
- **relations** : liste de paires `{contact_id, type}` ; `type` est un slug
  de la liste fixe. Une seule relation par paire de contacts (ajouter une
  relation vers un contact déjà lié remplace le type, des deux côtés).
- **Inverses** : `parent` <-> `child` ; les quatre autres types sont
  symétriques (l'inverse est le type lui-même).

### Pourquoi `data` est sûr (vérifié dans le code)

- Le PUT CardDAV (`Servant.CardDAV.put_contact/3`) fait
  `entry.data |> Map.merge(parsed.data) |> Map.merge(carddav_data)` : les
  clés que le codec ne connaît pas (tags, relations) survivent aux éditions
  du téléphone.
- Le connecteur vCard insère avec `on_conflict: :nothing`
  (`Data.create_entries/2`) : il ne met jamais à jour un contact existant.
- Le formulaire d'édition de l'app étale `...selected.data` avant ses
  champs : il préserve déjà les clés inconnues.
- La génération vCard (`Servant.CardDAV.VCard.synthesize/1`) ignore les
  clés inconnues : tags et relations ne sont pas exportés vers le
  téléphone. Assumé (données d'organisation internes à Servant).

### Robustesse

- Affichage : une relation dont le `contact_id` n'est pas dans la liste
  chargée est ignorée (filtre au rendu, pas de nettoyage).
- Suppression d'un contact : après le delete, retirer (best effort, une
  update par fiche concernée) les relations pointant vers l'id supprimé
  chez les contacts chargés.
- Les deux updates d'une relation réciproque partent ensemble ; si la
  deuxième échoue, l'état local est rechargé du serveur au prochain
  chargement (pas de rollback, échelle personnelle assumée).

## Module pur `src/apps/contacts/relations.ts`

Fonctions sans effet de bord, testées vitest (même modèle que
`checklists/markdown.ts`) :

- `RELATION_TYPES` : `['partner', 'parent', 'child', 'sibling', 'friend',
  'colleague']` + libellés d'affichage capitalisés.
- `inverseType(type)` : parent -> child, child -> parent, sinon identité.
- `normalizeTags(raw: string[])` : trim, minuscules, dédup, vides rejetés.
- `tagsOf(entry)`, `relationsOf(entry)` : lecture défensive de `data`.
- `withRelation(relations, contactId, type)` : retire toute relation
  existante vers `contactId` puis ajoute `{contactId, type}`.
- `withoutRelation(relations, contactId)` : retire la relation vers
  `contactId`.

## UI, colonne de gauche (liste)

- Sous la barre de recherche, une rangée `ct-tag-bar` (repliée si aucun
  tag n'existe) : chips de tous les tags existants, tri alpha, wrap.
- Clic sur une chip : filtre actif (chip surlignée style
  `ct-card--active`) ; re-clic : désactive. Un seul tag actif à la fois.
- Le filtre tag se combine en ET avec la recherche texte.
- La recherche texte matche aussi les tags (ajout au `filtered` computed).
- Le compteur du header suit le résultat filtré (comportement actuel).

## UI, fiche contact (mode vue, sauvegarde immédiate)

Comme le toggle anniversaire : chaque action sauvegarde tout de suite via
`ctx.api.entries.update`, sans passer par le formulaire d'édition (qui ne
change pas).

- **Tags dans l'en-tête** : sous le nom/titre, chips du contact avec × au
  survol, plus un petit champ inline "+ tag" (datalist des tags existants,
  Entrée valide, vide = rien). Clic sur une chip : active le filtre de la
  colonne de gauche.
- **Carte Relations** : entre Parameters et Events, toujours visible (elle
  porte la rangée d'ajout). Chaque ligne :
  "Friend - Bob Martin" (libellé du type + nom du contact lié), cliquable
  (sélectionne la fiche liée), × au survol (retire des deux côtés).
  Rangée d'ajout : `<select>` des six types + champ nom avec datalist des
  autres contacts (résolution par nom exact dans la liste chargée ;
  aucune correspondance = rien). Un contact ne peut pas être lié à
  lui-même.

## Hors scope v1

Export vCard des tags (CATEGORIES) et relations (RELATED), multi-tags
actifs dans le filtre, renommage global d'un tag, types de relation
personnalisés, graphe de relations.

## Tests

- `relations.ts` : inverseType (paire directionnelle + symétriques),
  normalizeTags (trim/minuscule/dédup/vides), withRelation (ajout,
  remplacement du type existant), withoutRelation, lectures défensives
  (data sans clés, valeurs non-listes).
- Vitest existants + vue-tsc + build comme filet global (pas de tests de
  composant, conformément au reste de l'app).

## Docs

Rien : feature interne à l'app Contacts, pas de changement d'API.
