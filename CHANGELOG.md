# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/).

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

[2.0.0]: https://github.com/ZoliQua/Z-MarkDowner/releases/tag/v2.0.0
[1.0.0]: https://github.com/ZoliQua/Z-MarkDowner/releases/tag/v1.0.0
