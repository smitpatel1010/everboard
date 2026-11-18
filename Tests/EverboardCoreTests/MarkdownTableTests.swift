import Foundation
import Testing
@testable import EverboardCore

@Suite struct MarkdownTableTests {
    let brief = """
    ## Your team
    | Who | MR | Nudge |
    |---|:---:|---|
    | **Asha** | acme/app!12 | Ask about `a|b` splitting |
    | Vik | acme/app!13 \\| !14 | Merge? |
    Done.
    """

    @Test func parsesHeaderRowsAndStops() throws {
        let lines = brief.components(separatedBy: .newlines)
        let t = try #require(MarkdownTable.read(lines, from: 1))
        #expect(t.header == ["Who", "MR", "Nudge"])
        #expect(t.rows == [["**Asha**", "acme/app!12", "Ask about `a|b` splitting"], ["Vik", "acme/app!13 | !14", "Merge?"]])
        #expect(lines[t.next] == "Done.")
        #expect(MarkdownTable.read(lines, from: 0) == nil)
    }

    @Test func rowsWithoutHeaderAndSeparators() {
        #expect(MarkdownTable.isSeparator(["---", ":--:", "-:"]))
        #expect(!MarkdownTable.isSeparator(["a", "---"]))
        #expect(MarkdownTable.cells("| a | b") == ["a", "b"])
        #expect(MarkdownTable.cells("not | a row") == nil)
        let t = MarkdownTable.read(["| a | b |", "| c | d |"], from: 0)
        #expect(t?.header == nil && t?.rows.count == 2)
    }

    @Test func copiesAsAnHTMLTable() {
        let html = MarkdownHTML.render(brief)
        #expect(html.contains("<table"))
        #expect(html.contains("<th style=") && html.contains(">Who</th>"))
        #expect(html.contains("<strong>Asha</strong>"))
        #expect(!html.contains("|---|"))
        #expect(html.contains("<p>Done.</p>"))
    }
}
