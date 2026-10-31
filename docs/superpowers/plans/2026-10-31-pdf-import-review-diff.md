# PDF Import, PDF Review Comments and Diff View Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Import PDFs as structured Markdown, import a co-author's PDF comments onto the Markdown/LaTeX source and act on them, and compare any two text versions in a diff window.

**Architecture:** Pure logic lives in `MarkDownerCore` (testable with XCTest, synthetic PDFs built in the tests); AppKit UI in `ZMarkDowner`. Review state is a Codable model persisted next to the source. The diff produces CriticMarkup, so the existing review commands and the DOCX tracked-changes export are reused.

**Tech Stack:** Swift 5.9, AppKit, PDFKit, Vision, FoundationModels (optional, `#if canImport`), XCTest. Build: SwiftPM + `build.sh`.

**Spec:** `docs/superpowers/specs/2026-10-31-pdf-import-review-diff-design.md`

## Global Constraints

- Deployment target stays macOS 13 (`Package.swift` `.macOS(.v13)`); APIs newer than 13 behind `if #available` / `#if canImport`.
- No third-party dependencies, no network use in any new feature.
- Every user-visible string goes through `L("key", "English")` / `LF(...)`; after adding strings run `python3 scripts/extract_strings.py`. Translations of new keys are done in Task 12 only.
- Never read, copy or reference real (private) manuscript files in code, tests or fixtures; tests build synthetic PDFs.
- Code style: match surrounding code (doc comments `///` on types and non-obvious functions, no other comment noise, 4-space indent, `private` where possible).
- Verification commands: `swift build` (no errors), `swift test` (all pass), and for app tasks `./build.sh test` (ends with `RESULT: ALL CHECKS PASSED`; `SKIP` lines are acceptable).
- Work on branch `feature/pdf-review-diff`; one commit per task with message `feat(<area>): …` / `test: …`.

## Review Focus

1. PDF with no text layer and no Vision result (blank scan) → import yields an empty document with a warning, never a crash. Test in Task 3.
2. A highlight whose quote occurs many times in the source ("the", "data") → anchored via context to the right occurrence or reported unanchored, never silently on the first occurrence. Test in Task 5.
3. Applying a suggestion after the source was edited elsewhere → the target text is re-verified at the anchored range; if it no longer matches, the action fails with a message and nothing changes. Test in Task 7.
4. Diff of very different or very large texts (200 000 chars) finishes < 2 s and never hangs the UI (runs off the main thread). Test in Task 1 (performance) and Task 10 (async).
5. Sidecar `.review.json` that is corrupt or belongs to another PDF → ignored with a message, the source still opens. Test in Task 7.

---

### Task 1: Word/line diff engine

**Files:**
- Create: `Sources/MarkDownerCore/TextDiff.swift`
- Test: `Tests/MarkDownerCoreTests/TextDiffTests.swift`

**Interfaces:**
- Produces:
  - `public enum DiffKind: Equatable { case equal, insert, delete }`
  - `public struct DiffSegment: Equatable { public var kind: DiffKind; public var text: String }`
  - `public struct DiffOptions: Equatable { public var ignoreWhitespace = false; public var ignoreCase = false; public init(ignoreWhitespace: Bool = false, ignoreCase: Bool = false) }`
  - `public struct DiffRow: Equatable { public var old: [DiffSegment]?; public var new: [DiffSegment]?; public var oldLine: Int?; public var newLine: Int? }` — one aligned side-by-side row; `nil` side = padding; segments carry word-level kinds.
  - `public struct DiffResult { public var segments: [DiffSegment]; public var rows: [DiffRow]; public var insertedWords: Int; public var deletedWords: Int }`
  - `public enum TextDiff { public static func compare(_ old: String, _ new: String, options: DiffOptions = DiffOptions()) -> DiffResult; public static func criticMarkup(_ segments: [DiffSegment]) -> String; static func tokens(_ s: String) -> [String] }`

- [ ] **Step 1: Write failing tests** `testWordLevelChanges` (`compare("The quick brown fox", "The slow brown dog")` → segments `[equal "The ", delete "quick", insert "slow", equal " brown ", delete "fox", insert "dog"]`, insertedWords 2, deletedWords 2), `testCriticMarkup` (same input → `"The {--quick--}{++slow++} brown {--fox--}{++dog++}"`), `testRowsAlignInsertedLines` (old `"a\nb\nc"`, new `"a\nX\nb\nc"` → 4 rows, row 1 has `old == nil`, `newLine == 1`), `testIgnoreWhitespaceAndCase` (`"Hello  World"` vs `"hello world"` with both options → single `.equal` segment), `testIdenticalAndEmpty` (`compare("", "abc")` → one insert; identical → one equal), `testPerformance200k` (two 200 000-character texts of random words with 2 % word edits, `compare` completes in < 2.0 s measured with `Date()`).
- [ ] **Step 2: Run** `swift test --filter TextDiffTests` → FAIL (`TextDiff` undefined).
- [ ] **Step 3: Implement** Myers O(ND) on line arrays, then Myers on `tokens` (regex `\w+|\s+|[^\w\s]`) inside each replaced block; adjacent same-kind segments merged; criticMarkup escapes nothing and emits deletions before insertions.
- [ ] **Step 4: Run** `swift test --filter TextDiffTests` → PASS.
- [ ] **Step 5: Commit** `feat(core): word and line diff engine`.

### Task 2: PDF text extraction to Markdown

**Files:**
- Create: `Sources/MarkDownerCore/PDFTextExtractor.swift`
- Modify: `Sources/MarkDownerCore/DocumentImporter.swift` (route `pdf`; add `"pdf"` to `richTextExtensions`)
- Test: `Tests/MarkDownerCoreTests/PDFImportTests.swift` (+ helper `Tests/MarkDownerCoreTests/SyntheticPDF.swift`)

**Interfaces:**
- Produces:
  - `public struct PDFLine { public var text: String; public var bounds: CGRect; public var fontSize: CGFloat; public var isBold: Bool; public var page: Int }`
  - `public struct PDFExtraction { public var markdown: String; public var lines: [PDFLine]; public var ocrPages: [Int]; public var warnings: [String] }`
  - `public enum PDFTextExtractor { public static func extract(_ document: PDFDocument, ocr: Bool = true) -> PDFExtraction; public static func cleanLines(_ pages: [[PDFLine]]) -> [[PDFLine]]; public static func normalizeCharacters(_ s: String) -> String }` — `cleanLines` applies line-number, header/footer and ligature rules from spec 3.1; `normalizeCharacters` does ligatures/soft hyphen/NBSP.
  - Test helper (test target only): `enum SyntheticPDF { static func make(pages: [[(text: String, fontSize: CGFloat, bold: Bool)]], lineNumbers: Bool = false, header: String? = nil, twoColumns: Bool = false) -> PDFDocument }` drawing text with CoreText into a `CGContext(consumer:mediaBox:)` PDF.

- [ ] **Step 1: Write failing tests** `testParagraphsAndHeadings` (page with a 20 pt line "Introduction", then three 11 pt lines forming one paragraph ending with ".", gap, another paragraph → markdown starts with `"# Introduction\n\n"` and contains exactly two body paragraphs), `testLineNumbersRemoved` (lines drawn with trailing numbers `1…12` → no line in markdown ends with a digit; text still contains every word), `testHyphenationJoined` (`"visua-"` + `"lisation of data"` → `"visualisation of data"`), `testRunningHeaderRemoved` (3 pages with header `"Journal X — Preprint"` + page numbers → header and numbers absent), `testLigatures` (`normalizeCharacters("ﬁgure ﬂow")` == `"figure flow"`), `testMetadataFrontMatter` (document attribute Title `"Study"`, Author `"A. Author"` → markdown starts with `"---\ntitle: Study\nauthor: A. Author\n---\n"`), `testTwoColumnsReadingOrder` (left column words L1..L5, right R1..R5 → all L before R), `testImporterRoutesPDF` (write synthetic PDF to temp `x.pdf`, `DocumentImporter.markdown(fromFileAt:)` returns non-empty text).
- [ ] **Step 2: Run** `swift test --filter PDFImportTests` → FAIL.
- [ ] **Step 3: Implement** using `page.selection(for: page.bounds(for: .mediaBox))?.selectionsByLine()`; font size and bold from the first character of `selection.attributedString` (bold = font traits or name containing "Bold"/"Black"/"Semibold"); thresholds exactly as spec 3.1.
- [ ] **Step 4: Run** `swift test --filter PDFImportTests` and `swift test` → PASS.
- [ ] **Step 5: Commit** `feat(core): PDF text extraction with structure recovery`.

### Task 3: OCR for scanned pages

**Files:**
- Create: `Sources/MarkDownerCore/PDFOCR.swift`
- Modify: `Sources/MarkDownerCore/PDFTextExtractor.swift` (call OCR for pages with < 20 characters)
- Test: `Tests/MarkDownerCoreTests/PDFImportTests.swift`

**Interfaces:**
- Consumes: `PDFTextExtractor.extract`, `PDFLine` (Task 2).
- Produces: `enum PDFOCR { static func recognize(_ page: PDFPage, pageIndex: Int, languages: [String]) -> [PDFLine]; static var preferredLanguages: [String] }` — renders at 300 dpi, `VNRecognizeTextRequest` (.accurate, `usesLanguageCorrection = true`), languages filtered by `supportedRecognitionLanguages()`; observations become `PDFLine`s in page coordinates with `fontSize` = box height × 0.8.

- [ ] **Step 1: Write failing tests** `testScannedPageRecognized` (page whose content is a bitmap image of the text "Scanned sample text" at 40 pt → `extract(doc).markdown` contains `"Scanned sample text"` case-insensitively and `ocrPages == [0]`), `testBlankScanGivesWarning` (blank image page → markdown empty after trimming, `warnings` not empty, no crash), `testOCRDisabled` (`extract(doc, ocr: false)` on the scanned page → `ocrPages` empty).
- [ ] **Step 2: Run** `swift test --filter PDFImportTests` → the three new tests FAIL.
- [ ] **Step 3: Implement** `PDFOCR` (synchronous `VNImageRequestHandler.perform`), warning text `L("pdf.noText", "No text could be recognised on page %d.")` via `LF`.
- [ ] **Step 4: Run** `swift test` → PASS.
- [ ] **Step 5: Commit** `feat(core): OCR fallback for scanned PDF pages`.

### Task 4: PDF annotation extraction and instruction parsing

**Files:**
- Create: `Sources/MarkDownerCore/ReviewComment.swift`, `Sources/MarkDownerCore/PDFReviewExtractor.swift`, `Sources/MarkDownerCore/ReviewInstructionParser.swift`
- Test: `Tests/MarkDownerCoreTests/PDFReviewTests.swift`

**Interfaces:**
- Consumes: `PDFTextExtractor.normalizeCharacters`, line-number stripping from Task 2 (expose `static func stripLineNumbers(_ s: String) -> String` there if needed).
- Produces:
  - `public enum Suggestion: Codable, Equatable { case replace(target: String, with: String); case insertAfter(target: String, text: String); case insertBefore(target: String, text: String); case delete(target: String) }`
  - `public enum ReviewStatus: String, Codable { case open, applied, done, rejected }`
  - `public enum AnnotationKind: String, Codable { case highlight, underline, squiggly, strikeOut, caret, note, freeText }`
  - `public struct ReviewComment: Codable, Equatable, Identifiable { public var id: String; public var page: Int; public var author: String; public var date: Date?; public var kind: AnnotationKind; public var quotedText: String; public var contextBefore: String; public var contextAfter: String; public var comment: String; public var replies: [String]; public var suggestion: Suggestion?; public var suggestionIsAI: Bool; public var status: ReviewStatus; public var reply: String }` — `id` = `"p<page>-<index>"`.
  - `public enum PDFReviewExtractor { public static func comments(from document: PDFDocument) -> [ReviewComment] }`
  - `public enum ReviewInstructionParser { public static func suggestion(kind: AnnotationKind, quoted: String, comment: String, sentence: String) -> Suggestion? }`

- [ ] **Step 1: Write failing tests**
  - Extraction (`testExtractsHighlightNoteAndStrikeOut`): synthetic PDF with text "Results show bugs in current tools for visualization." and three annotations built with `PDFAnnotation(bounds:forType:withProperties:)` + quad points over "bugs" (highlight, contents `Change "bugs" to "regressions".`, userName "Reviewer"), over "current" (strikeOut, no contents), and a `.text` note; plus a Popup and a Link that must be ignored; save to Data and reload → 3 comments in reading order, `quotedText` `"bugs"` / `"current"`, author `"Reviewer"`, `contextBefore` ends with `"Results show "`, highlight suggestion `.replace(target: "bugs", with: "regressions")`, strikeOut suggestion `.delete(target: "current")`.
  - Parser table (`testInstructionPatterns`), each `XCTAssertEqual(ReviewInstructionParser.suggestion(kind: .highlight, quoted: q, comment: c, sentence: s), expected)`:
    - q `"tools"`, c `Add after this: "(SDT)" so readers know the abbreviation.` → `.insertAfter(target: "tools", text: " (SDT)")` (a leading space is added when the inserted text does not start with punctuation)
    - q `"visualization"`, c `This journal uses British spelling: "visualisation".` → `.replace(target: "visualization", with: "visualisation")`
    - q `"very"`, c `delete` → `.delete(target: "very")`
    - q `"color"`, c `should be “colour”` → `.replace(target: "color", with: "colour")`
    - q `"the method"`, c `Replace "method" with "approach"` → `.replace(target: "method", with: "approach")`
    - q `"Data"`, c `I think this paragraph could be shortened.` → `nil`
    - kind `.caret`, q `""`, c `", however,"`, sentence-based → `.insertAfter(target: <contextBefore last word>, text: ", however,")` (test with explicit contextBefore via the extractor path)
- [ ] **Step 2: Run** `swift test --filter PDFReviewTests` → FAIL.
- [ ] **Step 3: Implement**: quote text from `page.selection(for: quadRect)` per quad (union of quads on the line), cleaned with Task 2 helpers; parser regexes per spec 3.3 table, applied in table order, first match wins.
- [ ] **Step 4: Run** `swift test` → PASS.
- [ ] **Step 5: Commit** `feat(core): extract PDF review comments and parse edit instructions`.

### Task 5: Anchoring comments in Markdown / LaTeX / plain sources

**Files:**
- Create: `Sources/MarkDownerCore/ReviewAnchor.swift`
- Test: `Tests/MarkDownerCoreTests/ReviewAnchorTests.swift`

**Interfaces:**
- Consumes: `ReviewComment` (Task 4).
- Produces:
  - `public enum SourceFormat: String, Codable { case markdown, latex, plain; public init(fileExtension: String) }` (`tex`, `latex`, `ltx` → latex; Markdown extensions → markdown; else plain)
  - `public struct NormalizedText { public let text: String; public let map: [Int]; public init(source: String, format: SourceFormat) }` — `map[i]` = UTF-16 offset in the source of normalized character `i`; `map.count == text.utf16.count + 1`.
  - `public enum ReviewAnchor { public static func locate(_ comment: ReviewComment, in normalized: NormalizedText) -> NSRange?; public static func locate(quote: String, before: String, after: String, in normalized: NormalizedText) -> NSRange? }`

- [ ] **Step 1: Write failing tests** `testLatexNormalization` (source `"We present \\textit{SetDiagramTool}~\\cite{x} for vi\\-sual data % note\n"` → normalized text `"we present setdiagramtool for visual data "`… assert `contains("we present setdiagramtool for")` and that mapping the range of `"setdiagramtool"` back gives source substring `"SetDiagramTool"`), `testMarkdownNormalization` (`"See **bold** and [the link](http://x)"` → contains `"see bold and the link"`), `testUniqueExactMatch`, `testAmbiguousQuoteUsesContext` (source with `"the data"` three times; quote `"data"` with before `"filter the "` → range of the second occurrence), `testAmbiguousWithoutContextIsNil` (quote `"data"`, empty context, three occurrences → `nil`), `testFuzzyMatchAcrossLineNumbersAndHyphenation` (quote `"desktop-class editor for quick"` vs LaTeX source line break between `platform` and `for` → anchored), `testShortQuoteNeedsContext` (quote `"a"` with context found → range length 1).
- [ ] **Step 2: Run** `swift test --filter ReviewAnchorTests` → FAIL.
- [ ] **Step 3: Implement** per spec 3.4; fuzzy step = sliding window of the quote's token count over normalized tokens, score = shared tokens (quote+context) / total, accept ≥ 0.75, ties → `nil`.
- [ ] **Step 4: Run** `swift test` → PASS.
- [ ] **Step 5: Commit** `feat(core): anchor review comments in Markdown, LaTeX and plain text`.

### Task 6: PDF import with annotations as review marks

**Files:**
- Modify: `Sources/MarkDownerCore/PDFTextExtractor.swift` (append marks), `Sources/MarkDownerCore/DocumentImporter.swift`
- Test: `Tests/MarkDownerCoreTests/PDFReviewTests.swift`

**Interfaces:**
- Consumes: `PDFReviewExtractor.comments`, `ReviewAnchor.locate`, `NormalizedText(source:format: .markdown)`, `DocumentImporter.revisionMode`.
- Produces: `public static func extract(_ document: PDFDocument, ocr: Bool = true, includeAnnotations: Bool) -> PDFExtraction` (the 2-argument overload forwards with `includeAnnotations: DocumentImporter.revisionMode == .markup`).

- [ ] **Step 1: Write failing test** `testImportedPDFContainsReviewMarks` (synthetic PDF from Task 4 → markdown contains `{==bugs==}{>>Reviewer: Change "bugs" to "regressions".<<}` and `{--current--}`; with `includeAnnotations: false` none of `{==`, `{--`).
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement** (marks inserted from the end of the text backwards so ranges stay valid; unanchored comments appended in a final section `## Comments` (title via `L("pdf.commentsSection", "Comments")`) as list items `- p. N, Author: comment`).
- [ ] **Step 4: Run** `swift test` → PASS. **Step 5: Commit** `feat(core): PDF annotations become review marks on import`.

### Task 7: Review session model, applying suggestions, persistence, response letter

**Files:**
- Create: `Sources/MarkDownerCore/ReviewSession.swift`
- Test: `Tests/MarkDownerCoreTests/ReviewSessionTests.swift`

**Interfaces:**
- Consumes: Tasks 4–5 types.
- Produces:
  - `public struct ReviewSession: Codable { public var pdfPath: String; public var sourceFormat: SourceFormat; public var comments: [ReviewComment]; public var createdAt: Date }`
  - `public enum ReviewSessionError: LocalizedError { case targetChanged(String), unanchored, noSuggestion }`
  - `extension ReviewSession { public static func sidecarURL(for source: URL) -> URL` (= `source.deletingLastPathComponent()/(source.lastPathComponent + ".review.json")`), `public func save(for source: URL) throws`, `public static func load(for source: URL) -> ReviewSession?` (nil when missing or undecodable), `public static func edit(applying suggestion: Suggestion, at range: NSRange, in text: String) throws -> (text: String, range: NSRange, delta: Int)`, `public static func criticMarks(for suggestion: Suggestion) -> String`, `public func markdownMarks(source: String) -> String` (whole Markdown with `{==…==}{>>…<<}` and suggestion marks inserted for anchored comments), `public func responseLetter(title: String) -> String` (Markdown: heading, then per comment `### N. p. P — Author`, quote as blockquote, comment, `**Status:** …`, `**Reply:** …`) }`

- [ ] **Step 1: Write failing tests** `testApplyReplace` (`edit(.replace(target: "bugs", with: "regressions"), at: range of "bugs")` → text updated, delta 7), `testApplyInsertAfterAndDelete`, `testTargetChangedThrows` (range now holds "gapz" → throws `.targetChanged`, text unchanged), `testSidecarRoundTrip` (save/load equality, file name `paper.tex.review.json`), `testCorruptSidecarIgnored` (garbage file → `load` returns nil), `testMarkdownMarks` (source `"Results show bugs."` + comment with replace suggestion → `"Results show {==bugs==}{>>Reviewer: …<<}…"` contains `{~~bugs~>regressions~~}`), `testResponseLetter` (2 comments, one done with reply "Fixed." → contains `"**Reply:** Fixed."` and `"### 2."`). Status/labels in the letter use `L("review.status.done", "Done")` etc.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** `swift test` → PASS. **Step 5: Commit** `feat(core): review sessions, applying suggestions and response letters`.

### Task 8: LaTeX / plain text sources in the app

**Files:**
- Modify: `build.sh` (Info.plist: add a document type "LaTeX document" (role Editor, rank Alternate, `LSItemContentTypes` `org.tug`, class `MarkdownDocument`) and an imported type declaration `org.tug` with extensions `tex`, `latex`, `ltx` conforming to `public.plain-text`), `Sources/ZMarkDowner/MarkdownDocument.swift` (keep `.tex` as its own type; `var sourceFormat: SourceFormat` from the file extension; write back unchanged format), `Sources/ZMarkDowner/MarkdownHighlighter.swift` (a `format: SourceFormat` property; LaTeX branch), `Sources/ZMarkDowner/DocumentWindowController.swift` (LaTeX: start in `.editor` mode; preview shows `<pre>` plain text via `preview.update(document:)` with a single code block; skip Markdown-only processing)
- Test: `Sources/ZMarkDowner/SelfTest.swift` (new checks)

**Interfaces:**
- Consumes: `SourceFormat` (Task 5).
- Produces: `MarkdownDocument.sourceFormat: SourceFormat`; `MarkdownHighlighter.format: SourceFormat`.

- [ ] **Step 1: Add self-test checks** (in a new `private func latexSources() async` called from `run()` before `finish()`): write `dir/sample.tex` containing `\section{Intro}\nText with \textit{italic} % comment\n`, open it via `NSDocumentController`, check `doc.sourceFormat == .latex`, window mode `.editor`, the `%` comment range has `NSColor.secondaryLabelColor`-ish foreground (check attribute != base color), editing and `save` keep the extension `.tex` and exact content.
- [ ] **Step 2: Run** `./build.sh test` → those checks FAIL.
- [ ] **Step 3: Implement.** Verify the UTI with `mdls -name kMDItemContentType file.tex` (system reports `org.tug`).
- [ ] **Step 4: Run** `swift test && ./build.sh test` → PASS.
- [ ] **Step 5: Commit** `feat(app): edit LaTeX and plain text sources`.

### Task 9: Comments panel (review from PDF)

**Files:**
- Create: `Sources/ZMarkDowner/ReviewPanelView.swift` (sidebar tab view + row view), `Sources/ZMarkDowner/ReviewController.swift` (per-window review logic: import, anchors, actions, persistence)
- Modify: `Sources/ZMarkDowner/SidebarView.swift` (4th segment "Comments" `L("sidebar.comments", "Comments")`), `Sources/ZMarkDowner/DocumentWindowController.swift` (owns `let review = ReviewController()`; loads sidecar in `loadDocumentText`/`documentLocationChanged`), `Sources/ZMarkDowner/AppDelegate.swift` (File menu: "Import Review Comments from PDF…" `#selector(DocumentWindowController.importReviewComments(_:))`, "Export Response to Reviewers…"), `Sources/ZMarkDowner/SelfTest.swift`

**Interfaces:**
- Consumes: Tasks 4, 5, 7; `EditorTextView.replace(_:with:select:)`; `DocumentWindowController.reveal(range:)` (existing).
- Produces:
  - `final class ReviewController { weak var windowController: DocumentWindowController?; private(set) var session: ReviewSession?; private(set) var anchors: [String: NSRange]; var onChange: (() -> Void)?; func importPDF(_ url: URL) throws; func reanchor(); func select(_ id: String); func apply(_ id: String) throws; func applyAll() -> (applied: Int, failed: Int); func setStatus(_ id: String, _ status: ReviewStatus); func setReply(_ id: String, _ text: String); func insertMarks() /* Markdown only */; func exportResponse(to url: URL, asDOCX: Bool) throws; func loadSidecar(); func saveSidecar() }`
  - `DocumentWindowController`: `@objc func importReviewComments(_:)`, `@objc func exportResponseLetter(_:)`, `@objc func showComments(_:)`.
- Behaviour fixed by the spec 3.5: apply = `ReviewSession.edit`, then shift other anchors by `delta` (anchors after the edit) and set status `.applied`; every state change saves the sidecar; unanchored rows show `L("review.unanchored", "Not found in the source")`; filter popup Open / All.

- [ ] **Step 1: Add self-test checks** (`private func reviewFromPDF() async`): build a synthetic annotated PDF (reuse the Task 4 construction, moved to an app-side helper `SelfTest.annotatedPDF(text:)`), save a `paper.md` with the same sentence, open it, call `importReviewComments` programmatically via `wc.review.importPDF(url)`; check 3 comments, 2 anchored, `apply` on the replace suggestion changes the editor text to contain `regressions`, undo restores, sidecar file exists and reload restores statuses, `exportResponse(..., asDOCX: true)` writes a DOCX that reads back containing the comment text, `insertMarks()` adds `{==`.
- [ ] **Step 2: Run** `./build.sh test` → FAIL.
- [ ] **Step 3: Implement** the panel: `NSTableView` rows with author · page, quote (italic, 2 lines), comment (3 lines), suggestion pill, status icon; context menu + buttons for actions; double-click = select in source.
- [ ] **Step 4: Run** `swift test && ./build.sh test` → PASS.
- [ ] **Step 5: Commit** `feat(app): review comments panel for annotated PDFs`.

### Task 10: Diff window

**Files:**
- Create: `Sources/ZMarkDowner/DiffWindowController.swift`
- Modify: `Sources/ZMarkDowner/AppDelegate.swift` (File ▸ "Compare Documents…" `AppDelegate.compareDocuments(_:)`; submenu "Compare With" → "Last Saved Version", "Earlier Version…", "Clipboard" targeting `DocumentWindowController.compareWithSaved/compareWithVersion/compareWithClipboard`), `Sources/ZMarkDowner/DocumentWindowController.swift`, `Sources/ZMarkDowner/SelfTest.swift`

**Interfaces:**
- Consumes: `TextDiff.compare`, `TextDiff.criticMarkup`, `DocumentImporter.markdown(fromFileAt:)`, `TextStatistics.prose` → expose `public static func proseText(of markdown: String) -> String` in `TextStatistics.swift` for "ignore formatting", `DocxExporter.data(markdown:options:)`.
- Produces: `final class DiffWindowController: NSWindowController { init(oldTitle: String, old: String, newTitle: String, new: String); private(set) var result: DiffResult?; func recompute() async; enum Layout { case sideBySide, inline }; var layout: Layout; func selectNextChange(); func selectPreviousChange(); func openAsReviewMarks() -> MarkdownDocument; func exportWord(to url: URL) throws }`

- [ ] **Step 1: Add self-test checks** (`private func diffWindow() async`): open `DiffWindowController(oldTitle:"A", old:"The quick brown fox", newTitle:"B", new:"The slow brown dog")`, await `recompute()`, check `insertedWords == 2`, side-by-side has two text views whose strings contain both versions, switching to inline shows a strikethrough attribute on "quick", `openAsReviewMarks()` document text == `"The {--quick--}{++slow++} brown {--fox--}{++dog++}"`, `exportWord` file reads back with `{--quick--}`; compare a DOCX and a PDF (written by the existing exporters from the same Markdown) → `deletedWords + insertedWords` ≤ 3 with ignore formatting on; a 200 000-character comparison returns while the main thread keeps running (a timer fired during it).
- [ ] **Step 2: Run** `./build.sh test` → FAIL.
- [ ] **Step 3: Implement**: diff on a background task; side-by-side via two `NSTextView`s fed from `DiffRow`s (blank padded lines, line-number gutter optional), scroll sync through bounds notifications; inline single text view; toolbar: layout segmented control, three option checkboxes, stats label, ↑/↓ change navigation, "Open as Review Marks", "Export as Word…".
- [ ] **Step 4: Run** `swift test && ./build.sh test` → PASS.
- [ ] **Step 5: Commit** `feat(app): diff window for documents, versions and clipboard`.

### Task 11: On-device AI suggestions (optional)

**Files:**
- Create: `Sources/ZMarkDowner/AISuggester.swift`
- Modify: `Sources/ZMarkDowner/ReviewPanelView.swift`, `Sources/ZMarkDowner/ReviewController.swift`, `Sources/ZMarkDowner/SelfTest.swift`

**Interfaces:**
- Consumes: `ReviewComment`, `Suggestion`, `ReviewController`.
- Produces: `enum AISuggester { static var isAvailable: Bool; static func suggest(for comment: ReviewComment, sentence: String) async throws -> Suggestion? }` — `#if canImport(FoundationModels)` + `if #available(macOS 26, *)`, `SystemLanguageModel.default.availability == .available`; a `@Generable struct EditProposal { var action: String; var target: String; var text: String }` with instructions "You edit scientific manuscripts. Return the smallest edit that implements the reviewer comment, or action none."; `target` must occur in `sentence`, otherwise result `nil`. `ReviewController.suggestWithAI(_ id: String) async`, `suggestAllWithAI() async` set `suggestionIsAI = true`.

- [ ] **Step 1: Add self-test check**: when `AISuggester.isAvailable`, `suggest` for comment `"Use the British spelling."` on quote `"color"` in sentence `"The color scale is fixed."` returns `.replace` whose `with` contains `"colour"`; otherwise log `SKIP AI suggestions (model unavailable)`. Without availability the panel shows no AI buttons.
- [ ] **Step 2: Run** `./build.sh test` → FAIL (or SKIP when unavailable — then also run `swift build` with the availability branches compiled).
- [ ] **Step 3: Implement.** **Step 4: Run** `swift test && ./build.sh test` → PASS. **Step 5: Commit** `feat(app): on-device AI edit suggestions for review comments`.

### Task 12: Localization, help, docs, version

**Files:**
- Modify: `Resources/Localization/*/Localizable.strings` (all 12), `Resources/Localization/*/Help.md` (new section "PDF import, review comments and comparing versions"), `README.md` (English + Magyar feature lists and shortcuts), `CHANGELOG.md` (`## [2.2.0] - <date>`), `THIRD_PARTY_NOTICES.md` unchanged.

- [ ] **Step 1:** `python3 scripts/extract_strings.py`, then list the keys of `en.lproj/Localizable.strings` missing from each other language (parse with regex `^"([^"]+)"\s*=\s*"((?:[^"\\]|\\.)*)";`) and append translations under `/* 2.2 additions */` — every language complete, the multiset of `%@`/`%d`/`%%` placeholders identical to English.
- [ ] **Step 2:** `plutil -lint` every `Localizable.strings` → all OK; every `Help.md` has the same number of `## ` headings as `en.lproj/Help.md`.
- [ ] **Step 3:** Run `./build.sh test` and a Hungarian run (`ZMD_SELFTEST_IN=Tests/Fixtures ZMD_SELFTEST_OUT=build/selftest-hu build/Z-MarkDowner.app/Contents/MacOS/Z-MarkDowner -ApplePersistenceIgnoreState YES -AppleLanguages "(hu)"`) → both `ALL CHECKS PASSED`.
- [ ] **Step 4: Commit** `docs: localization and documentation for 2.2.0`.
