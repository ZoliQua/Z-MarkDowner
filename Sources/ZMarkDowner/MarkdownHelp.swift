enum MarkdownHelp {
    static let text = """
    # Markdown gyorstalpaló

    Ez a dokumentum bemutatja a leggyakoribb Markdown elemeket. Nézd meg **osztott nézetben** (⌘2)!

    ## Szövegformázás

    - **Félkövér** – `**szöveg**` (⌘B)
    - *Dőlt* – `*szöveg*` (⌘I)
    - ~~Áthúzott~~ – `~~szöveg~~` (⇧⌘X)
    - `Kód` – `` `kód` `` (⌘`)
    - [Link](https://hu.wikipedia.org/wiki/Markdown) – `[szöveg](cím)` (⌘K)

    ## Címsorok

    `# Címsor 1` … `###### Címsor 6` (⌥⌘1 … ⌥⌘6)

    ## Listák

    1. Számozott lista (⇧⌘7)
    2. Második elem
        - Beágyazott elem (Tab-bal behúzható)

    - [x] Elvégzett feladat
    - [ ] Teendő (⇧⌘9)

    > Idézet (⇧⌘')

    ## Táblázat

    | Funkció | Billentyű |
    |:--------|:---------:|
    | Szerkesztő | ⌘1 |
    | Osztott nézet | ⌘2 |
    | Végleges nézet | ⌘3 |
    | Teljes képernyő | ⌃⌘F |

    ## Kódblokk

    ```swift
    print("Helló, világ!")
    ```

    ---

    **Export:** Fájl ▸ Exportálás PDF-be (⇧⌘E) vagy Word (DOCX) formátumba (⇧⌘D).
    **Import:** Fájl ▸ Megnyitás (⌘O) – DOCX, DOC, RTF, TXT és MD fájlok.
    """
}
