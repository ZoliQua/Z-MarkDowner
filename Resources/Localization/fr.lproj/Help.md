---
title: Guide Markdown
subtitle: Tout ce que Z-MarkDowner sait faire
---

Ouvrez la **vue partagée** (⌘2) pour voir la source et le résultat côte à côte.

## Mise en forme du texte

- **Gras** – `**texte**` (⌘B)
- *Italique* – `*texte*` (⌘I)
- ~~Barré~~ – `~~texte~~` (⇧⌘X)
- `Code` – `` `code` `` (⌘`)
- [Lien](https://fr.wikipedia.org/wiki/Markdown) – `[texte](adresse)` (⌘K)

## Titres

`# Titre 1` … `###### Titre 6` (⌥⌘1 … ⌥⌘6). La **barre latérale** (⌃⌘S) les affiche sous forme de plan.

## Listes

1. Liste numérotée (⇧⌘7)
2. Deuxième élément
    - Élément imbriqué (indenter avec Tab)

- [x] Fait
- [ ] À faire (⇧⌘9)

> Citation (⇧⌘')

## Tableaux

| Fonction | Raccourci |
|:--------|:--------:|
| Éditeur | ⌘1 |
| Vue partagée | ⌘2 |
| Vue finale | ⌘3 |
| Plein écran | ⌃⌘F |

Dans un tableau, **Tab** passe à la cellule suivante et aligne les colonnes ; **Retour** ajoute une ligne.

## Code

```swift
func greet(_ name: String) -> String {
    return "Bonjour, \(name) !"   // coloration syntaxique
}
```

## Notes de bas de page

Markdown prend en charge les notes de bas de page[^1].

[^1]: Le texte de la note apparaît à la fin du document — et comme une véritable note de bas de page dans Word.

## Formules et diagrammes

En ligne : $e^{i\pi} + 1 = 0$

$$
\int_0^1 x^2\,dx = \frac{1}{3}
$$

```mermaid
graph LR
    A[Markdown] --> B[PDF]
    A --> C[Word]
    A --> D[EPUB]
```

## Images

Collez une capture d’écran (⌘V) ou faites glisser une image dans l’éditeur : elle est enregistrée dans un dossier `images` à côté du document.

## Citations et références

Indiquez un fichier BibTeX (`.bib`) ou CSL-JSON dans le front matter (ou définissez-en un par défaut dans Réglages ▸ Écriture), puis citez avec `[@key]` :

```markdown
---
bibliography: references.bib
csl: vancouver        # ou apa
---

As shown earlier [@kovacs2020, p. 5; @who2019], … @kovacs2020 found …
```

La bibliographie est ajoutée à la fin (ou à l’endroit où vous placez `::: {#refs}` … `:::`). **Format ▸ Citations et références ▸ Insérer une citation…** (⌃⌘C) recherche dans la bibliographie et ajoute de nouvelles références par **DOI ou identifiant PubMed**. La saisie de `@` propose les clés.

## Figures, tableaux numérotés et renvois

| Format | Résultat |
|--------|----------|
| PDF    | table des matières avec numéros de page |
| Word   | véritable table des matières Word, légendes |

Table: Exportations {#tbl:exports}

@tbl:exports liste les formats de sortie. Étiquetez les figures avec `![Caption](image.png){#fig:name}`, les équations avec `$$ … $$ {#eq:name}`, les titres avec `# Title {#sec:name}`, et faites-y référence avec `@fig:name`, `@eq:name`, `@sec:name`. `[TOC]` (ou `toc: true` dans le front matter) insère une table des matières ; `numbersections: true` numérote les titres.

## Révision : modifications et commentaires

Les modifications suivies et les commentaires des documents Word sont importés comme marques de révision – et réexportés vers Word comme modifications suivies et commentaires : {++inséré++}, {--supprimé--}, {~~ancien~>nouveau~~}, {==surligné==}{>>Un commentaire<<}. Utilisez **Édition ▸ Révision** pour les accepter ou les refuser.

## Mise en forme en direct et outils d’écriture

**Présentation ▸ Mise en forme en direct** (⌥⌘L) masque le balisage Markdown, sauf sur la ligne en cours de modification. Cliquez sur le nombre de mots dans la barre d’état pour afficher les statistiques, le temps de lecture et les objectifs d’écriture. L’onglet **Recherche** de la barre latérale recherche et remplace dans tous les fichiers Markdown et texte d’un dossier (⌥⇧⌘F).

## Import PDF, commentaires de relecture et comparaison de versions

**Fichier ▸ Ouvrir** (⌘O) ouvre aussi un PDF comme nouveau document Markdown : les paragraphes, titres et listes sont reconstitués, les numéros de ligne, en-têtes courants et numéros de page sont supprimés, et les pages numérisées sont lues par OCR. Les commentaires et annotations du PDF deviennent des marques de révision. Les sources LaTeX (`.tex`) s’ouvrent telles quelles pour être modifiées.

**Fichier ▸ Importer les commentaires de relecture depuis un PDF…** lit les commentaires d’un PDF relu et retrouve chacun d’eux dans la source que vous modifiez – Markdown ou LaTeX, y compris les fichiers inclus avec `\input`. Enregistrez d’abord le fichier source : la relecture est stockée à côté (`<fichier>.review.json`). L’onglet **Commentaires** de la barre latérale (**Présentation ▸ Commentaires**) les affiche ; cliquez sur l’un d’eux pour sélectionner son texte. Les instructions simples comme `change "X" to "Y"`, `delete` ou `add after: "Z"` deviennent des suggestions à appliquer une par une ou avec **Tout appliquer** (les deux peuvent être annulés) ; les autres peuvent être marqués comme traités, refusés ou recevoir une réponse. **Insérer comme marques de révision** transforme les commentaires d’une source Markdown en marques de révision, et **Fichier ▸ Exporter la réponse aux relecteurs…** rédige une lettre de réponse au format Markdown ou Word. Sous macOS 26 avec Apple Intelligence, **Suggérer une modification (IA)** propose une modification directement sur votre Mac (à activer dans Réglages ▸ Écriture) ; rien n’est appliqué sans vous.

**Fichier ▸ Comparer des documents…** compare deux fichiers (Markdown, texte, Word, PDF…) ; **Fichier ▸ Comparer avec** compare le document ouvert avec sa **Dernière version enregistrée** (la dernière fois que vous l’avez enregistré vous-même), une **Version antérieure…** ou le **Presse-papiers**. Affichez les modifications **Côte à côte** ou en mode **Intégré**, ignorez les espaces, la casse ou la mise en forme (la mise en forme n’affecte que la comparaison à l’écran) et passez d’une modification à l’autre avec ⌘↑ / ⌘↓. **Ouvrir avec les marques de révision** transforme les différences en modifications à accepter ou refuser ; **Exporter au format Word avec suivi des modifications…** les enregistre dans un document Word.

---

**Exporter :** Fichier ▸ Exporter ▸ PDF (⇧⌘E), Word (⇧⌘D), HTML ou EPUB.
**Importer :** Fichier ▸ Ouvrir (⌘O) – fichiers DOCX, DOC, RTF, PDF, TXT et MD.
