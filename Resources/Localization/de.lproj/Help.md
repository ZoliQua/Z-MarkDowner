---
title: Markdown-Anleitung
subtitle: Alles, was Z-MarkDowner kann
---

Öffne die **geteilte Ansicht** (⌘2), um Quelltext und Ergebnis nebeneinander zu sehen.

## Textformatierung

- **Fett** – `**Text**` (⌘B)
- *Kursiv* – `*Text*` (⌘I)
- ~~Durchgestrichen~~ – `~~Text~~` (⇧⌘X)
- `Code` – `` `code` `` (⌘`)
- [Link](https://de.wikipedia.org/wiki/Markdown) – `[Text](Adresse)` (⌘K)

## Überschriften

`# Überschrift 1` … `###### Überschrift 6` (⌥⌘1 … ⌥⌘6). Die **Seitenleiste** (⌃⌘S) zeigt sie als Gliederung an.

## Listen

1. Nummerierte Liste (⇧⌘7)
2. Zweiter Eintrag
    - Verschachtelter Eintrag (mit Tab einrücken)

- [x] Erledigt
- [ ] Zu erledigen (⇧⌘9)

> Zitat (⇧⌘')

## Tabellen

| Funktion | Kurzbefehl |
|:--------|:--------:|
| Editor | ⌘1 |
| Geteilte Ansicht | ⌘2 |
| Endansicht | ⌘3 |
| Vollbild | ⌃⌘F |

In einer Tabelle springt **Tab** zur nächsten Zelle und richtet die Spalten aus; **Return** fügt eine Zeile hinzu.

## Code

```swift
func greet(_ name: String) -> String {
    return "Hallo, \(name)!"   // Syntaxhervorhebung
}
```

## Fußnoten

Markdown unterstützt Fußnoten[^1].

[^1]: Der Fußnotentext erscheint am Ende des Dokuments – und in Word als echte Fußnote.

## Formeln und Diagramme

Inline: $e^{i\pi} + 1 = 0$

$$
\int_0^1 x^2\,dx = \frac{1}{3}
$$

```mermaid
graph LR
    A[Markdown] --> B[PDF]
    A --> C[Word]
    A --> D[EPUB]
```

## Bilder

Setze ein Bildschirmfoto ein (⌘V) oder ziehe ein Bild in den Editor: Es wird in einem Ordner `images` neben dem Dokument gespeichert.

## Zitate und Literatur

Gib im Front Matter eine BibTeX- (`.bib`) oder CSL-JSON-Datei an (oder lege in Einstellungen ▸ Schreiben eine Standarddatei fest) und zitiere dann mit `[@key]`:

```markdown
---
bibliography: references.bib
csl: vancouver        # oder apa
---

As shown earlier [@kovacs2020, p. 5; @who2019], … @kovacs2020 found …
```

Das Literaturverzeichnis wird am Ende eingefügt (oder dort, wo du `::: {#refs}` … `:::` platzierst). **Format ▸ Zitate & Literatur ▸ Zitat einfügen …** (⌃⌘C) durchsucht das Literaturverzeichnis und fügt neue Quellen per **DOI oder PubMed-ID** hinzu. Beim Tippen von `@` werden die Schlüssel vorgeschlagen.

## Nummerierte Abbildungen, Tabellen und Querverweise

| Format | Ergebnis |
|--------|----------|
| PDF    | Inhaltsverzeichnis mit Seitenzahlen |
| Word   | echtes Word-Inhaltsverzeichnis, Beschriftungen |

Table: Exporte {#tbl:exports}

@tbl:exports listet die Ausgabeformate auf. Kennzeichne Abbildungen mit `![Caption](image.png){#fig:name}`, Gleichungen mit `$$ … $$ {#eq:name}`, Überschriften mit `# Title {#sec:name}` und verweise auf sie mit `@fig:name`, `@eq:name`, `@sec:name`. `[TOC]` (oder `toc: true` im Front Matter) fügt ein Inhaltsverzeichnis ein; `numbersections: true` nummeriert die Überschriften.

## Überarbeitung: Änderungen und Kommentare

Nachverfolgte Änderungen und Kommentare aus Word-Dokumenten werden als Überarbeitungsmarkierungen importiert – und beim Export nach Word wieder als nachverfolgte Änderungen und Kommentare ausgegeben: {++eingefügt++}, {--gelöscht--}, {~~alt~>neu~~}, {==hervorgehoben==}{>>Ein Kommentar<<}. Unter **Bearbeiten ▸ Überarbeitung** kannst du sie annehmen oder ablehnen.

## Live-Formatierung und Schreibwerkzeuge

**Darstellung ▸ Live-Formatierung** (⌥⌘L) blendet die Markdown-Auszeichnungen aus – außer in der Zeile, die du gerade bearbeitest. Klicke in der Statusleiste auf die Wortzahl, um Statistik, Lesezeit und Schreibziele zu sehen. Der Tab **Suche** in der Seitenleiste sucht und ersetzt in allen Markdown- und Textdateien eines Ordners (⌥⇧⌘F).

## PDF-Import, Gutachterkommentare und Versionen vergleichen

**Ablage ▸ Öffnen** (⌘O) öffnet auch ein PDF als neues Markdown-Dokument: Absätze, Überschriften und Listen werden wiederhergestellt, Zeilennummern, Kopfzeilen und Seitenzahlen entfernt und gescannte Seiten per OCR gelesen. Kommentare und Markierungen im PDF werden zu Überarbeitungsmarkierungen. LaTeX-Quellen (`.tex`) werden unverändert zum Bearbeiten geöffnet.

**Ablage ▸ Gutachterkommentare aus PDF importieren …** liest die Kommentare eines begutachteten PDFs und findet jeden in der Quelle, die du bearbeitest – Markdown oder LaTeX, einschließlich der mit `\input` eingebundenen Dateien. Sichere zuerst die Quelldatei: Die Begutachtung wird daneben gespeichert (`<Datei>.review.json`). Der Tab **Kommentare** der Seitenleiste (**Darstellung ▸ Kommentare**) listet sie auf; ein Klick wählt den zugehörigen Text aus. Einfache Anweisungen wie `change "X" to "Y"`, `delete` oder `add after: "Z"` werden zu Vorschlägen, die du einzeln oder mit **Alle anwenden** übernehmen kannst (beides lässt sich widerrufen); die übrigen markierst du als erledigt, lehnst sie ab oder beantwortest sie. **Als Überarbeitungsmarkierungen einfügen** macht aus den Kommentaren einer Markdown-Quelle Überarbeitungsmarkierungen, und **Ablage ▸ Antwort an die Gutachter exportieren …** schreibt ein Antwortschreiben als Markdown oder Word. Unter macOS 26 mit Apple Intelligence schlägt **Änderung vorschlagen (KI)** direkt auf deinem Mac eine Änderung vor (abschaltbar unter Einstellungen ▸ Schreiben ▸ Begutachtung); ohne dich wird nichts übernommen.

**Ablage ▸ Dokumente vergleichen …** vergleicht zwei Dateien (Markdown, Text, Word, PDF …); **Ablage ▸ Vergleichen mit** vergleicht das geöffnete Dokument mit der **Zuletzt gesicherten Version** (dem letzten Mal, als du selbst gesichert hast), einer **früheren Version …** oder der **Zwischenablage**. Zeige die Änderungen **Nebeneinander** oder **Im Text**, ignoriere Leerraum, Groß-/Kleinschreibung oder Formatierung (die Formatierung betrifft nur den Vergleich auf dem Bildschirm) und springe mit ⌘↑ / ⌘↓ zwischen den Änderungen. **Mit Überarbeitungsmarkierungen öffnen** macht aus den Unterschieden Änderungen, die du annehmen oder ablehnen kannst; **Als Word mit Änderungsverfolgung exportieren …** sichert sie als Word-Dokument.

---

**Export:** Ablage ▸ Exportieren ▸ PDF (⇧⌘E), Word (⇧⌘D), HTML oder EPUB.
**Import:** Ablage ▸ Öffnen (⌘O) – DOCX-, DOC-, RTF-, PDF-, TXT- und MD-Dateien.
