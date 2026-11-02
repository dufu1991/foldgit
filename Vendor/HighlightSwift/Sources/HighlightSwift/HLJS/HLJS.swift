import JavaScriptCore
import Foundation

final actor HLJS {
    private var hljs: JSValue?

    func languageAliases() throws -> Set<String> {
        let hljs = try load()
        guard let context = hljs.context,
              let names = context.evaluateScript("hljs.listLanguages().flatMap(name => [name].concat(hljs.getLanguage(name).aliases || []))")?.toArray() as? [String] else {
            throw HLJSError.valueNotFound
        }
        return Set(names)
    }

    func syntaxSpans(_ text: String, language: String) throws -> [SyntaxSpan] {
        try Task.checkCancellation()
        let hljs = try load()
        guard let context = hljs.context else { throw HLJSError.contextIsNil }
        if context.objectForKeyedSubscript("__foldgitSyntaxSpans").isUndefined {
            context.evaluateScript(Self.spanBridge)
        }
        context.exception = nil
        let result = context.objectForKeyedSubscript("__foldgitSyntaxSpans").call(withArguments: [text, language])
        try Task.checkCancellation()
        guard context.exception == nil, let rows = result?.toArray() as? [[Any]] else {
            throw HLJSError.valueNotFound
        }
        let length = text.utf16.count
        return try rows.map { row in
            guard row.count == 3, let location = row[0] as? Int, let count = row[1] as? Int,
                  let scopes = row[2] as? [String], location >= 0, count > 0,
                  location <= length, count <= length - location else {
                throw HLJSError.valueNotFound
            }
            return SyntaxSpan(range: NSRange(location: location, length: count), scopes: scopes)
        }
    }

    private static let spanBridge = #"""
    globalThis.__foldgitSyntaxSpans = (source, language) => {
        const result = hljs.highlight(source, { language, ignoreIllegals: true });
        const spans = [];
        const chunks = [];
        let offset = 0;
        const walk = (node, parents) => {
            if (typeof node === "string") {
                chunks.push(node);
                if (node.length && parents.length) spans.push([offset, node.length, parents]);
                offset += node.length;
                return;
            }
            const scopes = node.scope ? parents.concat(node.scope) : parents;
            node.children.forEach(child => walk(child, scopes));
        };
        walk(result._emitter.rootNode, []);
        if (chunks.join("") !== source || offset !== source.length) {
            throw new Error("Highlighting changed the source text");
        }
        return spans;
    };
    """#

    private func load() throws -> JSValue {
        if let hljs {
            return hljs
        }
        guard let context = JSContext() else {
            throw HLJSError.contextIsNil
        }
        let highlightPath = Bundle.module.path(forResource: "highlight.min", ofType: "js")
        guard let highlightPath else {
            throw HLJSError.fileNotFound
        }
        let highlightScript = try String(contentsOfFile: highlightPath)
        context.evaluateScript(highlightScript)
        guard let hljs = context.objectForKeyedSubscript("hljs") else {
            throw HLJSError.hljsNotFound
        }
        self.hljs = hljs
        return hljs
    }

    func highlight(_ text: String, mode: HighlightMode) throws -> HLJSResult {
        switch mode {
        case .automatic:
            return try highlightAuto(text)
        case .languageAlias(let alias):
            return try highlight(text, language: alias, ignoreIllegals: false)
        case .languageAliasIgnoreIllegal(let alias):
            return try highlight(text, language: alias, ignoreIllegals: true)
        case .language(let language):
            return try highlight(text, language: language.alias, ignoreIllegals: false)
        case .languageIgnoreIllegal(let language):
            return try highlight(text, language: language.alias, ignoreIllegals: true)
        }
    }

    private func highlightAuto(_ text: String) throws -> HLJSResult {
        let hljs = try load()
        let jsResult = hljs.invokeMethod(
            "highlightAuto",
            withArguments: [text]
        )
        return try highlightResult(jsResult)
    }

    private func highlight(_ text: String,
                           language: String,
                           ignoreIllegals: Bool) throws -> HLJSResult {
        var languageOptions: [String : Any] = [
            "language": language,
        ]
        if ignoreIllegals {
            languageOptions["ignoreIllegals"] = ignoreIllegals
        }
        let hljs = try load()
        let jsResult = hljs.invokeMethod(
            "highlight",
            withArguments: [text, languageOptions]
        )
        return try highlightResult(jsResult)
    }

    private func highlightResult(_ result: JSValue?) throws -> HLJSResult {
        guard let result else {
            throw HLJSError.valueNotFound
        }
        let illegal = result.objectForKeyedSubscript("illegal").toBool()
        let relevance = result.objectForKeyedSubscript("relevance").toInt32()
        guard
            let value = result.objectForKeyedSubscript("value").toString(),
            let language = result.objectForKeyedSubscript("language").toString()
        else {
            throw HLJSError.valueNotFound
        }
        return HLJSResult(value: value, illegal: illegal, language: language, relevance: relevance)
    }
}
