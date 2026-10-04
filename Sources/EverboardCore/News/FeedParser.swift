import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct ParsedEntry: Sendable, Equatable {
    public var title: String
    public var link: String
    public var summary: String
    public var published: Date?
}

/// Minimal RSS 2.0 / RSS 1.0 (RDF) / Atom parser on Foundation's XMLParser.
public final class FeedParser: NSObject, XMLParserDelegate {
    private var entries: [ParsedEntry] = []
    private var current: [String: String]?
    private var atomLink: String?
    private var text = ""

    public static func parse(_ data: Data) -> [ParsedEntry] {
        let p = FeedParser()
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.shouldProcessNamespaces = false
        parser.parse()
        return p.entries
    }

    public func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                       qualifiedName qName: String?, attributes: [String: String] = [:]) {
        text = ""
        if name == "item" || name == "entry" {
            current = [:]
            atomLink = nil
        } else if current != nil, name == "link", let href = attributes["href"] {
            // Atom: prefer rel="alternate" (or no rel) over enclosures/replies.
            let rel = attributes["rel"] ?? "alternate"
            if rel == "alternate" || atomLink == nil { atomLink = href }
        }
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    public func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    public func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard current != nil else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "item", "entry":
            if let c = current {
                let link = (c["link"].flatMap { $0.isEmpty ? nil : $0 }) ?? atomLink ?? c["guid"] ?? ""
                let title = HTMLText.plain(c["title"] ?? "")
                let rawSummary = c["description"] ?? c["summary"] ?? c["content:encoded"] ?? c["content"] ?? ""
                let date = (c["pubDate"] ?? c["published"] ?? c["dc:date"] ?? c["updated"]).flatMap(Dates.parseFeedDate)
                if !title.isEmpty, link.hasPrefix("http") {
                    entries.append(ParsedEntry(title: title, link: link, summary: HTMLText.plain(rawSummary, limit: 400), published: date))
                }
            }
            current = nil
        case "title", "link", "guid", "description", "summary", "content", "content:encoded", "pubDate", "published", "updated", "dc:date":
            // Keep the first non-empty value (e.g. Atom has <updated> at feed and entry level).
            if current?[name] == nil || current?[name]?.isEmpty == true { current?[name] = value }
        default:
            break
        }
        text = ""
    }
}
