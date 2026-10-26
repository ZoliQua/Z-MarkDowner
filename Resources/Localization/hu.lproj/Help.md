---
title: Markdown-útmutató
subtitle: Minden, amire a Z-MarkDowner képes
---

Nyissa meg az **osztott nézetet** (⌘2), hogy egymás mellett lássa a forrásszöveget és az eredményt.

## Szövegformázás

- **Félkövér** – `**szöveg**` (⌘B)
- *Dőlt* – `*szöveg*` (⌘I)
- ~~Áthúzott~~ – `~~szöveg~~` (⇧⌘X)
- `Kód` – `` `kód` `` (⌘`)
- [Hivatkozás](https://hu.wikipedia.org/wiki/Markdown) – `[szöveg](cím)` (⌘K)

## Címsorok

`# 1. címsor` … `###### 6. címsor` (⌥⌘1 … ⌥⌘6). Az **oldalsáv** (⌃⌘S) vázlatként listázza őket.

## Listák

1. Számozott lista (⇧⌘7)
2. Második elem
    - Beágyazott elem (behúzás Tab billentyűvel)

- [x] Kész
- [ ] Teendő (⇧⌘9)

> Idézet (⇧⌘')

## Táblázatok

| Funkció | Billentyűparancs |
|:--------|:--------:|
| Szerkesztő | ⌘1 |
| Osztott nézet | ⌘2 |
| Végleges nézet | ⌘3 |
| Teljes képernyő | ⌃⌘F |

Táblázaton belül a **Tab** a következő cellára ugrik, és igazítja az oszlopokat; a **Return** új sort ad hozzá.

## Kód

```swift
func greet(_ name: String) -> String {
    return "Szia, \(name)!"   // szintaxiskiemeléssel
}
```

## Lábjegyzetek

A Markdown támogatja a lábjegyzeteket[^1].

[^1]: A lábjegyzet szövege a dokumentum végén jelenik meg – Wordben pedig valódi lábjegyzetként.

## Képletek és diagramok

Szövegközi: $e^{i\pi} + 1 = 0$

$$
\int_0^1 x^2\,dx = \frac{1}{3}
$$

```mermaid
graph LR
    A[Markdown] --> B[PDF]
    A --> C[Word]
    A --> D[EPUB]
```

## Képek

Illesszen be egy képernyőképet (⌘V), vagy húzzon egy képet a szerkesztőbe: a kép a dokumentum melletti `images` mappába kerül.

---

**Exportálás:** Fájl ▸ Exportálás ▸ PDF (⇧⌘E), Word (⇧⌘D), HTML vagy EPUB.
**Importálás:** Fájl ▸ Megnyitás (⌘O) – DOCX, DOC, RTF, TXT és MD fájlok.
