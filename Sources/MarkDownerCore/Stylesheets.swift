import Foundation

public enum PreviewTheme: String, CaseIterable {
    case github, academic, minimal
}

public enum Stylesheets {

    /// Default on-screen stylesheet.
    public static var preview: String { css(theme: .github) }

    /// Full stylesheet for a theme. `forExport` removes screen padding/width limits (PDF, EPUB, print);
    /// `custom` is appended last so it can override anything.
    public static func css(theme: PreviewTheme, forExport: Bool = false, custom: String = "") -> String {
        var parts = [base, themeCSS(theme), highlight, extras]
        if forExport { parts.append(export) }
        if !custom.isEmpty { parts.append("/* custom */\n" + custom) }
        return parts.joined(separator: "\n")
    }

    private static func themeCSS(_ theme: PreviewTheme) -> String {
        switch theme {
        case .github: return github
        case .academic: return academic
        case .minimal: return minimal
        }
    }

    private static let base = """
    :root {
      color-scheme: light dark;
      --fg: #1f2328; --muted: #59636e; --bg: #ffffff; --border: #d1d9e0;
      --code-bg: #f3f4f6; --quote: #59636e; --link: #0969da; --accent: #0969da; --mark: #fff8c5;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --fg: #e6e8eb; --muted: #9198a1; --bg: #1e1f22; --border: #3d444d;
        --code-bg: #2b2d31; --quote: #9198a1; --link: #4493f8; --accent: #4493f8; --mark: #4d3e00;
      }
    }
    html { background: var(--bg); }
    body {
      margin: 0; padding: 40px 48px 80px; background: var(--bg); color: var(--fg);
      -webkit-font-smoothing: antialiased; word-wrap: break-word;
    }
    .markdown-body { max-width: 820px; margin: 0 auto; }
    .markdown-body > :first-child { margin-top: 0; }
    a { color: var(--link); text-decoration: none; }
    a:hover { text-decoration: underline; }
    p, ul, ol, blockquote, pre, table, .math-display { margin: 0 0 1em; }
    ul, ol { padding-left: 2em; }
    li + li { margin-top: .25em; }
    li > ul, li > ol { margin-bottom: 0; margin-top: .25em; }
    ul.task-list { list-style: none; padding-left: 1.2em; }
    .task-list-item input { margin: 0 .45em 0 -1.2em; vertical-align: middle; }
    code, pre, .math { font-family: "SF Mono", Menlo, Monaco, monospace; }
    code { font-size: .875em; background: var(--code-bg); padding: .2em .4em; border-radius: 6px; }
    pre { font-size: .875em; background: var(--code-bg); padding: 14px 16px; border-radius: 8px; overflow: auto; line-height: 1.45; }
    pre code { background: none; padding: 0; font-size: 1em; }
    table { border-collapse: collapse; display: block; overflow: auto; }
    th, td { border: 1px solid var(--border); padding: 6px 13px; }
    th { font-weight: 600; background: var(--code-bg); }
    hr { border: 0; height: 2px; background: var(--border); margin: 1.6em 0; }
    img { max-width: 100%; }
    del { color: var(--muted); }
    blockquote { margin-left: 0; padding: 0 1em; color: var(--quote); border-left: .25em solid var(--border); }
    """

    private static let github = """
    body { font: 16px/1.65 -apple-system, "SF Pro Text", "Helvetica Neue", sans-serif; }
    h1, h2, h3, h4, h5, h6 { font-weight: 650; line-height: 1.25; margin: 1.6em 0 0.6em; }
    h1 { font-size: 2em; padding-bottom: .3em; border-bottom: 1px solid var(--border); }
    h2 { font-size: 1.5em; padding-bottom: .3em; border-bottom: 1px solid var(--border); }
    h3 { font-size: 1.25em; } h4 { font-size: 1em; } h5 { font-size: .875em; }
    h6 { font-size: .85em; color: var(--muted); }
    """

    private static let academic = """
    body { font: 17px/1.6 "Iowan Old Style", "Palatino", "Georgia", "Times New Roman", serif; }
    .markdown-body { max-width: 720px; text-align: justify; hyphens: auto; -webkit-hyphens: auto; }
    h1, h2, h3, h4, h5, h6 { font-weight: 600; line-height: 1.25; margin: 1.5em 0 0.5em; text-align: left; }
    h1 { font-size: 1.9em; text-align: center; font-variant: small-caps; letter-spacing: .02em; }
    h2 { font-size: 1.4em; } h3 { font-size: 1.2em; font-style: italic; } h4, h5, h6 { font-size: 1em; }
    p + p { text-indent: 1.5em; margin-top: -0.6em; }
    blockquote { border-left: none; font-style: italic; padding: 0 2em; }
    th { background: none; border-bottom: 2px solid var(--fg); }
    th, td { border-left: none; border-right: none; }
    .front-matter { text-align: center; }
    """

    private static let minimal = """
    body { font: 17px/1.75 -apple-system, "SF Pro Text", "Helvetica Neue", sans-serif; }
    .markdown-body { max-width: 680px; }
    h1, h2, h3, h4, h5, h6 { font-weight: 600; line-height: 1.3; margin: 2em 0 0.7em; letter-spacing: -0.01em; }
    h1 { font-size: 2.1em; font-weight: 700; } h2 { font-size: 1.45em; } h3 { font-size: 1.2em; }
    h4, h5, h6 { font-size: 1em; color: var(--muted); }
    pre, code, th { background: transparent; }
    pre { border: 1px solid var(--border); }
    blockquote { border-left-width: 2px; }
    hr { height: 1px; width: 30%; margin: 2.5em auto; }
    """

    private static let highlight = """
    .hl-kw { color: #cf222e; } .hl-str { color: #0a3069; } .hl-com { color: #6e7781; font-style: italic; }
    .hl-num { color: #0550ae; } .hl-type { color: #953800; } .hl-fn { color: #8250df; } .hl-attr { color: #116329; }
    @media (prefers-color-scheme: dark) {
      .hl-kw { color: #ff7b72; } .hl-str { color: #a5d6ff; } .hl-com { color: #8b949e; }
      .hl-num { color: #79c0ff; } .hl-type { color: #ffa657; } .hl-fn { color: #d2a8ff; } .hl-attr { color: #7ee787; }
    }
    """

    private static let extras = """
    .front-matter { margin-bottom: 2em; padding-bottom: 1em; border-bottom: 1px solid var(--border); }
    .front-matter .doc-title { border: none; margin: 0 0 .2em; padding: 0; font-size: 2.2em; }
    .front-matter .doc-subtitle { font-size: 1.25em; color: var(--muted); margin: 0 0 .4em; }
    .front-matter .doc-meta { color: var(--muted); margin: 0; font-size: .95em; }
    .footnotes { font-size: .9em; color: var(--muted); margin-top: 2.5em; }
    .footnotes hr { height: 1px; width: 35%; margin: 0 0 1em; }
    .footnote-ref a { text-decoration: none; padding: 0 .1em; }
    .footnote-back { text-decoration: none; margin-left: .3em; }
    .math-inline { font-size: .95em; }
    .math-display { text-align: center; overflow-x: auto; overflow-y: hidden; padding: .3em 0; }
    pre.mermaid { background: transparent; text-align: center; font-family: inherit; }
    .math:not(.katex-rendered) { color: var(--muted); }
    figure { margin: 1.2em 0; text-align: center; }
    figure img { display: block; margin: 0 auto; }
    figcaption { font-size: .92em; color: var(--muted); margin: .5em auto 0; max-width: 90%; }
    .caption-label { font-weight: 600; color: var(--fg); }
    .table-figure figcaption { margin: 0 auto .5em; }
    .table-figure table { margin-left: auto; margin-right: auto; text-align: left; }
    .equation { display: flex; align-items: center; margin: 0 0 1em; }
    .equation .math-display { flex: 1; margin: 0; }
    .eq-number { flex: none; padding-left: 1em; }
    nav.toc { margin: 0 0 2em; padding: .8em 1.2em; border: 1px solid var(--border); border-radius: 8px; }
    .toc-title { font-weight: 650; font-size: 1.15em; margin: 0 0 .5em; }
    nav.toc ul { list-style: none; padding: 0; margin: 0; }
    nav.toc li { margin: .15em 0; }
    nav.toc a { display: flex; color: var(--fg); }
    nav.toc .toc-text { flex: 0 1 auto; }
    nav.toc .toc-page { flex: 1 0 auto; text-align: right; color: var(--muted); }
    nav.toc .toc-page:not(:empty)::before { content: ""; }
    .toc-level-1 { font-weight: 600; } .toc-level-2 { padding-left: 1.2em; } .toc-level-3 { padding-left: 2.4em; }
    .toc-level-4 { padding-left: 3.6em; } .toc-level-5, .toc-level-6 { padding-left: 4.8em; }
    .references { margin-top: .5em; }
    .csl-entry { margin: 0 0 .6em; }
    .csl-entry.hanging { padding-left: 2em; text-indent: -2em; }
    .csl-entry.numbered { display: flex; gap: .5em; }
    .csl-label { flex: none; min-width: 1.8em; }
    ins.critic { background: rgba(46, 160, 67, .18); text-decoration: none; border-bottom: 1px solid rgba(46, 160, 67, .7); }
    del.critic { background: rgba(248, 81, 73, .15); color: inherit; }
    mark.critic, mark { background: var(--mark); color: inherit; }
    .critic-comment { font-size: .8em; background: rgba(9, 105, 218, .1); border: 1px solid rgba(9, 105, 218, .35);
      border-radius: 4px; padding: 0 .35em; margin: 0 .2em; color: var(--muted); }
    .critic-comment::before { content: "💬 "; }
    """

    private static let export = """
    body { padding: 0; background: #fff; }
    .markdown-body { max-width: none; }
    pre { white-space: pre-wrap; word-wrap: break-word; overflow: visible; }
    table { display: table; }
    .math-display { overflow: visible; }
    nav.toc { border: none; padding: 0; }
    nav.toc .toc-text { flex: 0 1 auto; }
    nav.toc .toc-page::before { content: none; }
    """
}
