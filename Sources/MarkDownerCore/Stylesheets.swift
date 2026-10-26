import Foundation

public enum Stylesheets {

    /// Stylesheet for the on-screen preview (follows light/dark appearance).
    public static let preview = """
    :root {
      color-scheme: light dark;
      --fg: #1f2328; --muted: #59636e; --bg: #ffffff; --border: #d1d9e0;
      --code-bg: #f3f4f6; --quote: #59636e; --link: #0969da; --accent: #0969da;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --fg: #e6e8eb; --muted: #9198a1; --bg: #1e1f22; --border: #3d444d;
        --code-bg: #2b2d31; --quote: #9198a1; --link: #4493f8; --accent: #4493f8;
      }
    }
    html { background: var(--bg); }
    body {
      margin: 0; padding: 40px 48px 80px; background: var(--bg); color: var(--fg);
      font: 16px/1.65 -apple-system, "SF Pro Text", "Helvetica Neue", sans-serif;
      -webkit-font-smoothing: antialiased; word-wrap: break-word;
    }
    .markdown-body { max-width: 820px; margin: 0 auto; }
    h1, h2, h3, h4, h5, h6 { font-weight: 650; line-height: 1.25; margin: 1.6em 0 0.6em; }
    h1 { font-size: 2em; padding-bottom: .3em; border-bottom: 1px solid var(--border); }
    h2 { font-size: 1.5em; padding-bottom: .3em; border-bottom: 1px solid var(--border); }
    h3 { font-size: 1.25em; } h4 { font-size: 1em; } h5 { font-size: .875em; }
    h6 { font-size: .85em; color: var(--muted); }
    .markdown-body > :first-child { margin-top: 0; }
    p, ul, ol, blockquote, pre, table { margin: 0 0 1em; }
    a { color: var(--link); text-decoration: none; }
    a:hover { text-decoration: underline; }
    ul, ol { padding-left: 2em; }
    li + li { margin-top: .25em; }
    li > ul, li > ol { margin-bottom: 0; margin-top: .25em; }
    ul.task-list { list-style: none; padding-left: 1.2em; }
    .task-list-item input { margin: 0 .45em 0 -1.2em; vertical-align: middle; }
    blockquote { margin-left: 0; padding: 0 1em; color: var(--quote); border-left: .25em solid var(--border); }
    code, pre { font-family: "SF Mono", Menlo, Monaco, monospace; font-size: .875em; }
    code { background: var(--code-bg); padding: .2em .4em; border-radius: 6px; }
    pre { background: var(--code-bg); padding: 14px 16px; border-radius: 8px; overflow: auto; line-height: 1.45; }
    pre code { background: none; padding: 0; font-size: 1em; }
    table { border-collapse: collapse; display: block; overflow: auto; }
    th, td { border: 1px solid var(--border); padding: 6px 13px; }
    th { font-weight: 600; background: var(--code-bg); }
    hr { border: 0; height: 2px; background: var(--border); margin: 1.6em 0; }
    img { max-width: 100%; }
    del { color: var(--muted); }
    """

    /// Stylesheet used when converting to PDF (light, print oriented).
    /// Kept to CSS that the AppKit HTML importer understands.
    public static let print = """
    body { font-family: "Helvetica Neue", Helvetica, Arial, sans-serif; font-size: 11pt; line-height: 1.45; color: #111111; }
    h1 { font-size: 22pt; font-weight: bold; margin: 14pt 0 8pt 0; }
    h2 { font-size: 17pt; font-weight: bold; margin: 14pt 0 6pt 0; }
    h3 { font-size: 14pt; font-weight: bold; margin: 12pt 0 6pt 0; }
    h4 { font-size: 12pt; font-weight: bold; margin: 10pt 0 4pt 0; }
    h5, h6 { font-size: 11pt; font-weight: bold; margin: 10pt 0 4pt 0; }
    p { margin: 0 0 8pt 0; }
    ul, ol { margin: 0 0 8pt 0; }
    li { margin: 0 0 2pt 0; }
    a { color: #0a58ca; }
    blockquote { margin: 0 0 8pt 0; padding-left: 12pt; color: #555555; border-left: 3px solid #cccccc; }
    code { font-family: Menlo, Courier, monospace; font-size: 9.5pt; background-color: #f0f0f0; }
    pre { font-family: Menlo, Courier, monospace; font-size: 9.5pt; background-color: #f4f4f4; padding: 6pt; margin: 0 0 8pt 0; }
    pre code { background-color: #f4f4f4; }
    table { border-collapse: collapse; margin: 0 0 8pt 0; }
    th, td { border: 1px solid #999999; padding: 3pt 6pt; }
    th { background-color: #eeeeee; font-weight: bold; }
    hr { border: 0; border-top: 1px solid #aaaaaa; }
    del { color: #666666; }
    """
}
