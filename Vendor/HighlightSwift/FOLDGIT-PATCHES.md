# FoldGit integration

Upstream: https://github.com/appstefan/HighlightSwift

Pinned upstream revision: `99c431b38a1444a5fd6a4978307fbbefe3a7af53`.

This local Swift package preserves the upstream languages, themes, public APIs and licenses. FoldGit adds a small syntax-span API that reads highlight.js's emitter tree and returns UTF-16 ranges without converting source through HTML. This preserves original whitespace, line endings and Unicode text. The adapter validates the reconstructed source before returning any ranges.

Local changes:

- `Highlight.syntaxSpans` and `Highlight.languageAliases` expose the span and language APIs.
- `HLJS` walks the pinned highlight.js emitter tree with cancellation checks before and after the synchronous JavaScript call.
- The package omits the upstream test target; FoldGit exercises the adapter in its macOS tests.

The emitter tree is an internal highlight.js API. Any upstream update must pass the Unicode, whitespace, nested-language, range and language coverage tests before this revision is changed.
