import Foundation

enum MarkdownHelp {
    /// Localized guide (`<lang>.lproj/Help.md`), falling back to the English text below.
    static var text: String {
        if let url = Bundle.main.url(forResource: "Help", withExtension: "md"),
           let localized = try? String(contentsOf: url, encoding: .utf8) {
            return localized
        }
        return english
    }

    static let english = """
    ---
    title: Markdown Guide
    subtitle: Everything Z-MarkDowner can do
    ---

    Open the **split view** (⌘2) to see the source and the result side by side.

    ## Text formatting

    - **Bold** – `**text**` (⌘B)
    - *Italic* – `*text*` (⌘I)
    - ~~Strikethrough~~ – `~~text~~` (⇧⌘X)
    - `Code` – `` `code` `` (⌘`)
    - [Link](https://en.wikipedia.org/wiki/Markdown) – `[text](address)` (⌘K)

    ## Headings

    `# Heading 1` … `###### Heading 6` (⌥⌘1 … ⌥⌘6). The **sidebar** (⌃⌘S) lists them as an outline.

    ## Lists

    1. Numbered list (⇧⌘7)
    2. Second item
        - Nested item (indent with Tab)

    - [x] Done
    - [ ] To do (⇧⌘9)

    > Quote (⇧⌘')

    ## Tables

    | Feature | Shortcut |
    |:--------|:--------:|
    | Editor | ⌘1 |
    | Split view | ⌘2 |
    | Final view | ⌘3 |
    | Full screen | ⌃⌘F |

    Inside a table, **Tab** jumps to the next cell and aligns the columns; **Return** adds a row.

    ## Code

    ```swift
    func greet(_ name: String) -> String {
        return "Hello, \\(name)!"   // syntax highlighted
    }
    ```

    ## Footnotes

    Markdown supports footnotes[^1].

    [^1]: The footnote text appears at the end of the document — and as a real footnote in Word.

    ## Formulas and diagrams

    Inline: $e^{i\\pi} + 1 = 0$

    $$
    \\int_0^1 x^2\\,dx = \\frac{1}{3}
    $$

    ```mermaid
    graph LR
        A[Markdown] --> B[PDF]
        A --> C[Word]
        A --> D[EPUB]
    ```

    ## Images

    Paste a screenshot (⌘V) or drag an image into the editor: it is saved into an `images` folder next to the document.

    ---

    **Export:** File ▸ Export ▸ PDF (⇧⌘E), Word (⇧⌘D), HTML or EPUB.
    **Import:** File ▸ Open (⌘O) – DOCX, DOC, RTF, TXT and MD files.
    """
}
