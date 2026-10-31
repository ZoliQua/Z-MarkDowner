# PDF import, PDF review comments and diff view — design

Status: draft for review · Target version: 2.2.0 · Date: 2026-10-31

## 1. Goals

1. **PDF import** — open any PDF as a new Markdown document with its structure rebuilt
   (paragraphs, headings, no line numbers / running headers / hyphenation), scanned pages
   recognised with OCR.
2. **Review from an annotated PDF** — a co-author returns the rendered manuscript as a PDF with
   highlights and notes. The user imports these comments *onto the source they edit* (Markdown,
   LaTeX or plain text), sees each comment anchored to the right place, applies concrete
   suggestions, marks the rest done or rejected, and exports a response letter.
3. **Diff view** — compare two versions of a text (TXT, MD, DOCX, PDF, or the open document
   against its saved / earlier version or the clipboard), side by side or inline at word level,
   and turn the result into review marks or a Word document with tracked changes.

## 2. The motivating document

A typical case is a LaTeX manuscript (pdfTeX output with `lineno` line numbers, split into
`\input` files) returned by a co-author as a PDF with a few hundred `Highlight` annotations, each
with a `Popup`, plus the hyperref `Link` annotations. Comment texts are instructions in natural
language:

- a minority follow fixed patterns: `Change "X" to "Y"`, `Add after this: "(ABC)"`,
  `… the journal uses British spelling: "colour"`, `delete`;
- most are free-form remarks.

Consequences: the extractor must read highlight quad points (the highlighted words), the popup
text, author and date; the anchoring must survive line numbers glued to line ends (`… word for1`),
ligatures, hyphenation and LaTeX markup in the source; most comments can only be *shown and tracked*,
some can be turned into an exact edit automatically, and an optional on-device model can propose
edits for the rest.

Real manuscripts are never copied into the repository; all tests use synthetic PDFs.

## 3. Functional requirements

### 3.1 PDF text extraction (`PDFTextExtractor`, Core)

- Reads lines with their bounds and font size via PDFKit (`PDFPage.selection(for:)` /
  `selectionsByLine()`, `attributedString`).
- **Line numbers:** when ≥ 50 % of a page's lines start or end with an integer that increases
  down the page (lineno style), those numbers are removed; lines that consist only of a number
  are dropped.
- **Running headers / footers:** a line in the top or bottom 8 % of the page whose text (digits
  replaced by `#`) repeats on ≥ 50 % of the pages (min. 3 pages) is removed; bare page numbers
  are removed.
- **Ligatures and characters:** ﬀ ﬁ ﬂ ﬃ ﬄ → ff fi fl ffi ffl; soft hyphens removed; NBSP → space.
- **Hyphenation:** a line ending in `-` followed by a line starting with a lowercase letter is
  joined without the hyphen.
- **Paragraphs:** a new paragraph starts when the vertical gap to the previous line exceeds
  1.5 × the page's median line gap, when the previous line ends with `.`, `:`, `?`, `!` and is
  shorter than 80 % of the median line width, or when the font size changes by more than 10 %.
- **Headings:** a short block (≤ 2 lines, ≤ 150 characters, not ending with `.`) whose font size
  is ≥ 1.15 × the body size (body = most frequent size by character count) becomes a heading;
  levels 1–3 by descending distinct size. Bold short lines at body size become level 3 only when
  followed by a paragraph.
- **Two columns:** when a page's line `minX` values cluster into two groups each holding ≥ 30 %
  of lines, the left column is read before the right one.
- **Lists:** lines starting with `•`, `–`, `-`, `▪` or `1.`/`a)` become Markdown list items.
- **Metadata:** PDF Title, Author, Subject, Keywords → front matter `title`, `author`, `subtitle`,
  `keywords` (only non-empty values; a Title equal to the file name is ignored).
- **OCR:** a page with fewer than 20 extractable characters but visible content is rendered at
  300 dpi and recognised with Vision (`VNRecognizeTextRequest`, `.accurate`, language correction on,
  languages: the app language, `en`, and `hu` when Vision supports them). OCR text goes through the
  same paragraph pipeline. A document-level flag reports how many pages were OCR'd.
- Tables and images are **not** reconstructed (images: out of scope; tables: plain lines).
- `DocumentImporter.markdown(fromFileAt:)` accepts `pdf`; PDF files open as new untitled Markdown
  documents (import-only type, like DOCX).

### 3.2 PDF annotations (`PDFReviewExtractor`, Core)

Extracts `ReviewComment`s from these annotation subtypes: Highlight, Underline, Squiggly,
StrikeOut, Caret, Text (sticky note), FreeText. Popups are folded into their parent; replies
(`/IRT`) become the comment's `replies`. Link, Widget and Popup-only annotations are ignored.

Per comment: page index, author (`T`), date (`M` or `CreationDate`), kind, `quotedText` (the
words under the quad points, cleaned like 3.1), `contextBefore` / `contextAfter` (up to 60
characters of page text around the quote, cleaned), `comment` (Contents), and a parsed
`suggestion` (3.3). Comments are ordered by page, then top-to-bottom, left-to-right.

### 3.3 Turning comments into edits (`ReviewInstructionParser`, Core)

A `Suggestion` is one of: `replace(target, with)`, `insert(text, after: target)`,
`insert(text, before: target)`, `delete(target)`. Recognised (case-insensitive, quotes `"…"`,
`“…”`, `'…'`, `‘…’`, `„…”`):

| Input | Suggestion |
|---|---|
| StrikeOut, empty contents | delete(quoted) |
| StrikeOut with contents | replace(quoted, contents) |
| Caret with contents | insert(contents, after: context word) |
| `change/replace "X" to/with/by "Y"` | replace(X, Y) — X must occur in the quoted text, else in its sentence |
| `change/replace to/with "Y"`, `should be "Y"`, `→ "Y"` | replace(quoted, Y) |
| `add/insert after (this): "Z"` / `add "Z" after` | insert(Z, after: quoted) |
| `add/insert before (this): "Z"` | insert(Z, before: quoted) |
| comment is only `delete`, `remove`, `delete this`, `omit`, `cut` (± punctuation) | delete(quoted) |
| exactly one quoted string Q similar to the quote (same first 4 letters or edit distance ≤ 3, e.g. spelling) | replace(quoted, Q) |

Anything else has no automatic suggestion.

**Optional on-device suggestions:** on macOS 26+ with Apple Intelligence available
(`FoundationModels`, `SystemLanguageModel.default.availability == .available`), the user can ask
for a suggestion for a single comment or all comments without one. The model receives the
comment, the quoted text and its sentence from the source and returns a structured
`{action: replace|insertAfter|insertBefore|delete|none, target, text}`; results are shown as
suggestions marked "AI", never applied without the user. The feature is hidden when unavailable;
the app still builds and runs on macOS 13.

### 3.4 Anchoring comments in the source (`ReviewAnchor`, Core)

- Source formats: Markdown, LaTeX, plain text.
- Both sides are normalised into comparable text with an index map back to the source:
  lowercase; whitespace runs → one space; curly quotes → straight; en/em dash → `-`; ligatures
  expanded; for **LaTeX**: `%` comments removed, `\command{arg}` → `arg` for text commands
  (`\textit`, `\textbf`, `\emph`, `\textsc`, `\texttt`, `\url`, `\href{url}{text}` → text),
  `\cite…{…}`, `\ref{}`, `\label{}`, `\footnote{` kept as content, other control words removed,
  `~` → space, `{`/`}` removed, `\%` → `%`, ` `` `/`''` → `"`; for **Markdown**: emphasis and code
  markers removed, `[text](url)` → text, heading/list/quote markers removed.
- Search order: (1) unique exact occurrence of the quote; (2) occurrence whose surrounding text
  best matches `contextBefore`/`contextAfter`; (3) fuzzy: best window by token overlap ≥ 0.75 of
  quote + context tokens. Quotes shorter than 3 characters are always matched with context.
- Result: source range of the quoted words, or *unanchored* (the comment stays in the list with
  its page reference).

### 3.5 Review panel (app)

- **File ▸ Import Review Comments from PDF…** (with a source document open). Opens a fourth
  sidebar tab **Comments** listing all comments: author, page, quoted text, comment, suggestion
  (with "AI" badge when generated), status (open / applied / done / rejected), anchor state.
- Selecting a comment selects its anchored range in the editor (and scrolls the preview).
- Actions per comment: **Apply suggestion** (edits the source; undoable), **Mark done**,
  **Reject**, **Reopen**, **Reply…** (free text for the response letter), **Suggest edit (AI)**.
- Bulk: **Apply All Suggestions** (confirmation with count), filter: open / all, by author.
- Markdown sources additionally offer **Insert as Review Marks**: every anchored comment becomes
  `{==quote==}{>>Author: comment<<}` and every suggestion `{~~old~>new~~}` / `{++…++}` / `{--…--}`,
  so the existing Edit ▸ Review commands work. Never offered for LaTeX.
- Review state persists in a sidecar `<source file name>.review.json` next to the source
  (PDF path, comments, statuses, replies, suggestion origin); it is reloaded when the source opens.
- **Export Response to Reviewers…** writes Markdown or DOCX: per comment number, page, author,
  quoted text, comment, status and reply.
- Applying a suggestion re-anchors the remaining comments (ranges after the edit shift).

### 3.6 LaTeX and plain text sources (app)

- `.tex` files open as editable text documents (saved back as `.tex`, never converted).
- A small LaTeX highlighter: `%` comments, `\commands`, braces, `$…$` math; spell checking skips
  commands and math. The Markdown preview is not used for LaTeX: those windows start in editor
  view and the preview shows the plain text.

### 3.7 Diff (`TextDiff` Core, `DiffWindowController` app)

- Algorithm: line diff (Myers) first, then word diff (Myers on tokens: words, whitespace runs,
  punctuation) inside changed regions; deterministic output.
- Options: ignore whitespace changes, ignore case, ignore formatting (compare the prose text of
  the parsed Markdown instead of the source).
- **Compare…** entry points: File ▸ Compare Documents… (two files of any importable type, PDF
  and DOCX through the importers), File ▸ Compare with ▸ Last Saved Version / Earlier Version…
  (`NSFileVersion`) / Clipboard.
- Window: **Side by side** (two synchronized, line-aligned text views; changed words highlighted)
  and **Inline** (one text, deletions red strikethrough, insertions green underline); counters
  (insertions / deletions / changed words); Next / Previous change (⌘↓ / ⌘↑ in the window).
- Outputs: **Open as Review Marks** (new Markdown document = new text with
  `{--old--}{++new++}` marks, ready for Accept/Reject), **Export as Word with Tracked Changes…**
  (the same marks through the DOCX exporter), **Copy summary**.
- Large inputs: up to 200 000 characters per side must diff in under 2 s.

## 4. Non-goals

PDF table reconstruction, PDF image extraction, three-way merge, writing annotations back into
the PDF, editing the PDF itself, network-based AI.

## 5. Quality requirements

- Everything offline; no new third-party dependencies; app size growth < 1 MB.
- All UI strings localized (12 languages), Help updated.
- Unit tests for every Core component with synthetic PDFs generated in the tests; the in-app self
  test covers import, review panel, applying suggestions, and the diff window.
