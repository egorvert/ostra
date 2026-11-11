import Testing
@testable import OstraCore

@Suite struct FuzzyTests {
    @Test func prefersPrefixThenWordStartThenSubstring() throws {
        let prefix = try #require(Fuzzy.score("set", in: "Settings"))
        let wordStart = try #require(Fuzzy.score("set", in: "Open settings"))
        let inside = try #require(Fuzzy.score("set", in: "Reset the camera"))
        #expect(prefix > wordStart)
        #expect(wordStart > inside)
    }

    @Test func matchesLettersInOrderAcrossCamelCase() throws {
        #expect(Fuzzy.score("wsp", in: "WorkspacePanel.swift") != nil)
        #expect(Fuzzy.score("pws", in: "WorkspacePanel.swift") == nil)
        // A run of letters at word starts beats the same letters scattered.
        let tidy = try #require(Fuzzy.score("ap", in: "AppPanel"))
        let scattered = try #require(Fuzzy.score("ap", in: "xaxxxp"))
        #expect(tidy > scattered)
    }

    @Test func everyWordOfTheQueryMustMatch() {
        #expect(Fuzzy.score("zoom fit", in: "Zoom to fit") != nil)
        #expect(Fuzzy.score("zoom banana", in: "Zoom to fit") == nil)
    }

    @Test func ignoresCase() {
        #expect(Fuzzy.score("README", in: "readme.md") != nil)
        #expect(Fuzzy.score("readme", in: "README.md") != nil)
    }

    @Test func snippetShowsTheTextAroundTheMatch() throws {
        let text = String(repeating: "filler ", count: 30) + "the redirect loses the return URL" + String(repeating: " filler", count: 30)
        let snippet = try #require(Fuzzy.snippet(of: text, around: "REDIRECT"))
        #expect(snippet.contains("redirect"))
        #expect(snippet.hasPrefix("…"))
        #expect(snippet.hasSuffix("…"))
        #expect(snippet.count < 220)
        #expect(Fuzzy.snippet(of: text, around: "absent") == nil)
    }
}
