---
title: Sprievodca Markdownom
subtitle: Všetko, čo Z-MarkDowner dokáže
---

Otvorte **rozdelené zobrazenie** (⌘2) a uvidíte zdrojový text aj výsledok vedľa seba.

## Formátovanie textu

- **Tučné** – `**text**` (⌘B)
- *Kurzíva* – `*text*` (⌘I)
- ~~Prečiarknuté~~ – `~~text~~` (⇧⌘X)
- `Kód` – `` `kód` `` (⌘`)
- [Odkaz](https://en.wikipedia.org/wiki/Markdown) – `[text](adresa)` (⌘K)

## Nadpisy

`# Nadpis 1` … `###### Nadpis 6` (⌥⌘1 … ⌥⌘6). **Bočný panel** (⌃⌘S) ich zobrazuje ako osnovu.

## Zoznamy

1. Číslovaný zoznam (⇧⌘7)
2. Druhá položka
    - Vnorená položka (odsadenie klávesom Tab)

- [x] Hotovo
- [ ] Treba urobiť (⇧⌘9)

> Citát (⇧⌘')

## Tabuľky

| Funkcia | Skratka |
|:--------|:--------:|
| Editor | ⌘1 |
| Rozdelené zobrazenie | ⌘2 |
| Konečné zobrazenie | ⌘3 |
| Celá obrazovka | ⌃⌘F |

V tabuľke **Tab** preskočí do ďalšej bunky a zarovná stĺpce; **Return** pridá riadok.

## Kód

```swift
func greet(_ name: String) -> String {
    return "Ahoj, \(name)!"   // zvýraznená syntax
}
```

## Poznámky pod čiarou

Markdown podporuje poznámky pod čiarou[^1].

[^1]: Text poznámky sa zobrazí na konci dokumentu – a vo Worde ako skutočná poznámka pod čiarou.

## Vzorce a diagramy

V riadku: $e^{i\pi} + 1 = 0$

$$
\int_0^1 x^2\,dx = \frac{1}{3}
$$

```mermaid
graph LR
    A[Markdown] --> B[PDF]
    A --> C[Word]
    A --> D[EPUB]
```

## Obrázky

Vložte snímku obrazovky (⌘V) alebo do editora presuňte obrázok: uloží sa do priečinka `images` vedľa dokumentu.

## Citácie a literatúra

Vo front matter uveďte súbor BibTeX (`.bib`) alebo CSL-JSON (alebo nastavte predvolený v Nastavenia ▸ Písanie) a citujte pomocou `[@key]`:

```markdown
---
bibliography: references.bib
csl: vancouver        # alebo apa
---

As shown earlier [@kovacs2020, p. 5; @who2019], … @kovacs2020 found …
```

Zoznam literatúry sa pridá na koniec (alebo tam, kde umiestnite `::: {#refs}` … `:::`). **Formát ▸ Citácie a odkazy ▸ Vložiť citáciu…** (⌃⌘C) prehľadáva zoznam literatúry a pridáva nové zdroje podľa **DOI alebo PubMed ID**. Pri písaní `@` sa ponúknu kľúče.

## Číslované obrázky, tabuľky a krížové odkazy

| Formát | Výstup |
|--------|--------|
| PDF    | obsah s číslami strán |
| Word   | skutočný obsah Wordu, popisy |

Table: Exporty {#tbl:exports}

@tbl:exports uvádza výstupné formáty. Obrázky označte pomocou `![Caption](image.png){#fig:name}`, rovnice pomocou `$$ … $$ {#eq:name}`, nadpisy pomocou `# Title {#sec:name}` a odkazujte na ne pomocou `@fig:name`, `@eq:name`, `@sec:name`. `[TOC]` (alebo `toc: true` vo front matter) vloží obsah; `numbersections: true` očísluje nadpisy.

## Revízia: zmeny a komentáre

Sledované zmeny a komentáre z dokumentov Wordu sa importujú ako revízne značky – a pri exporte sa do Wordu vrátia ako sledované zmeny a komentáre: {++vložené++}, {--vymazané--}, {~~staré~>nové~~}, {==zvýraznené==}{>>Komentár<<}. Prijať alebo odmietnuť ich môžete v ponuke **Upraviť ▸ Revízia**.

## Živé formátovanie a nástroje na písanie

**Zobraziť ▸ Živé formátovanie** (⌥⌘L) skryje značky Markdownu okrem riadka, ktorý práve upravujete. Kliknutím na počet slov v stavovej lište zobrazíte štatistiku, čas čítania a ciele písania. Karta **Hľadanie** v bočnom paneli vyhľadáva a nahrádza vo všetkých súboroch Markdown a textových súboroch priečinka (⌥⇧⌘F).

---

**Export:** Súbor ▸ Exportovať ▸ PDF (⇧⌘E), Word (⇧⌘D), HTML alebo EPUB.
**Import:** Súbor ▸ Otvoriť (⌘O) – súbory DOCX, DOC, RTF, TXT a MD.
