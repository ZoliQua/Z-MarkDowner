# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/).

## [2.1.0] - 2026-10-26

### Added
- Citations from BibTeX / CSL-JSON bibliographies (`[@key]`, `[see @key, p. 5; @other]`, `@key`, `[-@key]`) in Vancouver or APA 7 style, with an automatic reference list in the preview and all exports
- *Insert Citation* sheet: search the bibliography, add references by DOI (doi.org) or PubMed ID (NCBI); `@` autocompletes citation keys and cross-reference labels
- Numbered figures, tables and equations with captions and cross-references (`{#fig:…}`, `Table: … {#tbl:…}`, `$$ … $$ {#eq:…}`, `{#sec:…}`, `@fig:…`)
- Table of contents (`[TOC]`, `toc: true`) and numbered headings (`numbersections: true`); page numbers in PDF, a real TOC field in Word
- Clickable internal and external links in PDF exports
- Word templates (.dotx / .docx, setting or front matter `reference-doc`): styles matched by name (works with localized Word), page setup, headers, footers, theme and list definitions
- Word tracked changes and comments are imported as CriticMarkup and exported back to Word as tracked changes and comments; review commands (accept / reject change or all, next / previous change, comments)
- Live formatting: WYSIWYG-like editing that hides Markdown markup outside the edited line, with drawn bullets, clickable checkboxes, rules and quote bars
- Folder-wide search and replace in the sidebar (case, whole word, regular expressions)
- Document statistics (words, characters, sentences, paragraphs, reading and speaking time, selection) and per-document / daily word goals with progress in the status bar
- Settings ▸ Writing: citation style, default bibliography, heading numbering, Word template, handling of Word changes, daily goal

### Fixed
- Spaces stored in separate Word runs were lost when importing DOCX files
- YAML front matter was not recognised by the editor's syntax highlighting (a key line could look like a heading)
- Word export uses the document language (front matter `lang`) instead of always Hungarian, and the chosen paper size

## [2.0.0] - 2026-10-26

### Added
- PDF export and printing rendered with WebKit (identical to the preview), paginated at line and block boundaries, with page numbers and A4 / US Letter paper
- Synchronized scrolling between editor and preview (both directions)
- Sidebar with document outline and folder browser
- Paste and drag & drop of images (stored in an `images/` folder next to the document)
- Footnotes (`[^1]`) – rendered in the preview and exported as real Word footnotes; imported from DOCX
- YAML front matter (title, subtitle, author, date, keywords) used by the preview and all exports
- Math formulas with KaTeX and Mermaid diagrams (bundled, work offline)
- Syntax highlighting of code blocks for 20+ languages
- EPUB 3 export, self-contained HTML export, *Copy as Formatted Text*
- Batch conversion window and Finder Services (Convert to PDF / Word / Markdown, Open in Z-MarkDowner)
- Quick Look preview extension for Markdown files
- Table editing: Tab between cells with automatic column alignment, Return adds rows, insert/delete rows and columns, column alignment
- Auto-closing brackets and quotes, focus mode, typewriter scrolling
- Settings window: language, appearance, default view, editor font/size/line width, preview style (GitHub, Academic, Minimal), custom CSS, paper size, page numbers, rendering options
- User interface in 12 languages: English, Hungarian, German, Spanish, Italian, French, Portuguese, Russian, Slovak, Czech, Romanian, Turkish
- About panel with author information; Duplicate, Rename, Move To and Browse All Versions in the File menu
- Status bar with cursor position; spell checking skips code, URLs and formulas
- `build.sh` modes: `install`, `dmg`, `test`, `notarize`; end-to-end self test of the built app

### Changed
- Syntax highlighting updates only the edited lines in large documents
- Bundle identifier is now `io.github.zoliqua.zmarkdowner`

### Fixed
- Undo grouping of the *Insert Footnote* command
- Relative links in the preview could blank the preview page

## [1.0.0] - 2026-10-26

### Added
- Native AppKit Markdown editor with syntax highlighting, formatting toolbar and menus
- Editor, split and final (rendered) views, native full screen
- Import of DOCX (own reader honouring Word styles, numbering and hyperlinks), DOC, RTF, TXT (encoding detection) and MD
- Export to PDF, Word (DOCX with real Word styles) and HTML
- Unit tests and an in-app self test

[2.1.0]: https://github.com/ZoliQua/Z-MarkDowner/releases/tag/v2.1.0
[2.0.0]: https://github.com/ZoliQua/Z-MarkDowner/releases/tag/v2.0.0
[1.0.0]: https://github.com/ZoliQua/Z-MarkDowner/releases/tag/v1.0.0
