---
title: Ghid Markdown
subtitle: Tot ce poate face Z-MarkDowner
---

Deschideți **vizualizarea divizată** (⌘2) pentru a vedea sursa și rezultatul unul lângă altul.

## Formatarea textului

- **Aldin** – `**text**` (⌘B)
- *Cursiv* – `*text*` (⌘I)
- ~~Tăiat~~ – `~~text~~` (⇧⌘X)
- `Cod` – `` `cod` `` (⌘`)
- [Link](https://ro.wikipedia.org/wiki/Markdown) – `[text](adresă)` (⌘K)

## Titluri

`# Titlu 1` … `###### Titlu 6` (⌥⌘1 … ⌥⌘6). **Bara laterală** (⌃⌘S) le afișează ca structură.

## Liste

1. Listă numerotată (⇧⌘7)
2. Al doilea element
    - Element imbricat (indentare cu Tab)

- [x] Gata
- [ ] De făcut (⇧⌘9)

> Citat (⇧⌘')

## Tabele

| Funcție | Scurtătură |
|:--------|:--------:|
| Editor | ⌘1 |
| Vizualizare divizată | ⌘2 |
| Vizualizare finală | ⌘3 |
| Ecran complet | ⌃⌘F |

Într-un tabel, **Tab** trece la celula următoare și aliniază coloanele; **Retur** adaugă un rând.

## Cod

```swift
func greet(_ name: String) -> String {
    return "Salut, \(name)!"   // evidențiere sintaxă
}
```

## Note de subsol

Markdown acceptă note de subsol[^1].

[^1]: Textul notei apare la sfârșitul documentului — și ca notă de subsol reală în Word.

## Formule și diagrame

În linie: $e^{i\pi} + 1 = 0$

$$
\int_0^1 x^2\,dx = \frac{1}{3}
$$

```mermaid
graph LR
    A[Markdown] --> B[PDF]
    A --> C[Word]
    A --> D[EPUB]
```

## Imagini

Lipiți o captură de ecran (⌘V) sau trageți o imagine în editor: aceasta este salvată într-un dosar `images` lângă document.

## Citări și referințe

Indicați un fișier BibTeX (`.bib`) sau CSL-JSON în front matter (sau setați unul implicit în Configurări ▸ Scriere), apoi citați cu `[@key]`:

```markdown
---
bibliography: references.bib
csl: vancouver        # sau apa
---

As shown earlier [@kovacs2020, p. 5; @who2019], … @kovacs2020 found …
```

Bibliografia este adăugată la sfârșit (sau acolo unde plasați `::: {#refs}` … `:::`). **Format ▸ Citări și referințe ▸ Inserează citare…** (⌃⌘C) caută în bibliografie și adaugă referințe noi după **DOI sau ID PubMed**. Tastarea `@` propune cheile.

## Figuri, tabele numerotate și referințe încrucișate

| Format | Rezultat |
|--------|----------|
| PDF    | cuprins cu numere de pagină |
| Word   | cuprins Word real, legende |

Table: Exporturi {#tbl:exports}

@tbl:exports enumeră formatele de ieșire. Etichetați figurile cu `![Caption](image.png){#fig:name}`, ecuațiile cu `$$ … $$ {#eq:name}`, titlurile cu `# Title {#sec:name}` și faceți trimitere la ele cu `@fig:name`, `@eq:name`, `@sec:name`. `[TOC]` (sau `toc: true` în front matter) inserează un cuprins; `numbersections: true` numerotează titlurile.

## Revizuire: modificări și comentarii

Modificările urmărite și comentariile din documentele Word sunt importate ca marcaje de revizuire – și exportate înapoi în Word ca modificări urmărite și comentarii: {++inserat++}, {--șters--}, {~~vechi~>nou~~}, {==evidențiat==}{>>Un comentariu<<}. Folosiți **Editare ▸ Revizuire** pentru a le accepta sau respinge.

## Formatare live și instrumente de scriere

**Afișare ▸ Formatare live** (⌥⌘L) ascunde marcajele Markdown, cu excepția rândului pe care îl editați. Faceți clic pe numărul de cuvinte din bara de stare pentru statistici, timp de citire și obiective de scriere. Fila **Căutare** din bara laterală caută și înlocuiește în toate fișierele Markdown și text dintr-un dosar (⌥⇧⌘F).

---

**Export:** Fișier ▸ Exportă ▸ PDF (⇧⌘E), Word (⇧⌘D), HTML sau EPUB.
**Import:** Fișier ▸ Deschide (⌘O) – fișiere DOCX, DOC, RTF, TXT și MD.
