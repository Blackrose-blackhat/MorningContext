import Testing
@testable import MorningContext

@Suite("String helpers")
struct StringHelpersTests {
    @Test func headTailKeepsShortStrings() {
        #expect("hello".headTail(10) == "hello")
    }

    @Test func headTailKeepsBeginningAndEnd() {
        let s = String(repeating: "a", count: 500) + String(repeating: "z", count: 500)
        let out = s.headTail(200, marker: "|")
        #expect(out.count <= 200)
        #expect(out.hasPrefix("aaa"))
        #expect(out.hasSuffix("zzz"))
        #expect(out.contains("|"))
    }

    @Test func truncated() {
        #expect("abcdef".truncated(10) == "abcdef")
        #expect("abcdef".truncated(3) == "abc …[truncated]")
    }

    @Test func collapsedWhitespace() {
        #expect("  a\n\n b\t c  ".collapsedWhitespace == "a b c")
    }
}

@Suite("Pronunciation")
struct PronunciationTests {
    @Test func parsesRulesLongestFirstAndSkipsComments() {
        let rules = Pronunciation.rules("""
        # comment = ignored
        atlas = at-lus
        atlas-web = at-lus web
        broken line
        """)
        #expect(rules.map(\.word) == ["atlas-web", "atlas"])
    }

    @Test func appliesRulesAsWholeWordsCaseInsensitively() {
        let rules = Pronunciation.rules("kubectl = cube control")
        #expect(Pronunciation.normalize("Run Kubectl now", rules: rules) == "Run cube control now")
        #expect(Pronunciation.normalize("kubectlx stays", rules: rules) == "kubectlx stays")
    }

    @Test func speaksSymbolsAndProductNames() {
        #expect(Pronunciation.normalize("Fix PR #42 — then ship", rules: []) == "Fix PR 42, then ship")
        #expect(Pronunciation.normalize("Open MorningContext", rules: []) == "Open Morning Context")
    }
}
