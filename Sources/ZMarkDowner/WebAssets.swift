import Foundation
import MarkDownerCore

/// Optional bundled JavaScript renderers (KaTeX for math, Mermaid for diagrams) in `Resources/Web`.
enum WebAssets {
    enum Context { case preview, export, standaloneHTML }

    static let directory: URL? = {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Web"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }()

    static var hasKaTeX: Bool { exists("katex/katex.min.js") }
    static var hasMermaid: Bool { exists("mermaid/mermaid.min.js") }

    private static func exists(_ path: String) -> Bool {
        guard let dir = directory else { return false }
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent(path).path)
    }

    /// `<head>` additions for a page. Standalone HTML files load the libraries from a CDN instead.
    static func headHTML(for context: Context) -> String {
        let math = Settings.shared.renderMath && (hasKaTeX || context == .standaloneHTML)
        let diagrams = Settings.shared.renderDiagrams && (hasMermaid || context == .standaloneHTML)
        var head = ""
        if math {
            let base = context == .standaloneHTML
                ? "https://cdn.jsdelivr.net/npm/katex@\(katexVersion)/dist" : "zmd-asset://katex"
            head += "<link rel=\"stylesheet\" href=\"\(base)/katex.min.css\">"
            head += "<script src=\"\(base)/katex.min.js\"></script>"
        }
        if diagrams {
            let src = context == .standaloneHTML
                ? "https://cdn.jsdelivr.net/npm/mermaid@\(mermaidVersion)/dist/mermaid.min.js" : "zmd-asset://mermaid/mermaid.min.js"
            head += "<script src=\"\(src)\"></script>"
        }
        return head + "<script>\(renderScript)</script>"
    }

    static let katexVersion = "0.16.22"
    static let mermaidVersion = "11.4.1"

    /// Renders math and diagrams; `window.__zmdReady` resolves when done (awaited by the PDF exporter).
    static let renderScript = """
    window.zmdRender = function () {
      const jobs = [];
      if (window.katex) {
        document.querySelectorAll('.math:not(.katex-rendered)').forEach(function (el) {
          try {
            katex.render(el.textContent, el, { displayMode: el.classList.contains('math-display'), throwOnError: false });
            el.classList.add('katex-rendered');
          } catch (e) {}
        });
      }
      if (window.mermaid) {
        const dark = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches;
        try {
          mermaid.initialize({ startOnLoad: false, theme: dark ? 'dark' : 'default', securityLevel: 'strict' });
          const nodes = document.querySelectorAll('pre.mermaid:not([data-processed])');
          if (nodes.length) { jobs.push(mermaid.run({ nodes: nodes, suppressErrors: true }).catch(function () {})); }
        } catch (e) {}
      }
      return Promise.all(jobs);
    };
    window.__zmdReady = new Promise(function (resolve) {
      const go = function () { window.zmdRender().then(resolve, resolve); };
      if (document.readyState === 'loading') { document.addEventListener('DOMContentLoaded', go); } else { go(); }
    });
    """
}
