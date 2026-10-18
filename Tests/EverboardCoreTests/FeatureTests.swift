import Foundation
import Testing
@testable import EverboardCore

@Suite struct FeatureTests {
    private func mr(_ iid: Int, author: String, hours: Double, files: Int?) -> ChangeRecord {
        let created = Date(timeIntervalSince1970: 1_000_000)
        return ChangeRecord(id: "gitlab.mr:1:\(iid)", ref: "acme/app!\(iid)", title: "MR \(iid)", url: "https://x/\(iid)", state: "merged",
                            createdAt: created, mergedAt: created.addingTimeInterval(hours * 3600), authorUsername: author,
                            authorName: author, comments: 0, filesChanged: files)
    }

    @Test func teamMetrics() {
        let now = Date()
        let open = [
            FeedItem(id: "a", source: "gitlab", kind: "mr.reportee", title: "old", createdAt: now.addingTimeInterval(-6 * 86400),
                     attrs: ["pipelineStatus": "failed"]),
            FeedItem(id: "b", source: "gitlab", kind: "mr.reportee", title: "new", createdAt: now.addingTimeInterval(-86400)),
        ]
        let merged = [mr(1, author: "asha", hours: 10, files: 4), mr(2, author: "asha", hours: 30, files: 1000),
                      mr(3, author: "asha", hours: 20, files: nil)]
        let reviewed = [mr(9, author: "vik", hours: 1, files: nil), mr(1, author: "asha", hours: 10, files: nil)]
        let m = TeamMath.metrics(username: "asha", name: "Asha", merged: merged, reviewed: reviewed, open: open, now: now)
        #expect(m.merged == 3)
        #expect(m.medianCycleHours == 20)
        #expect(m.medianSize == 502)          // median of [4, 1000]
        #expect(m.open == 2)
        #expect(m.openRed == 1)
        #expect((m.oldestOpenDays ?? 0) > 5.9)
        #expect(m.reviewsGiven == 1)          // own MR doesn't count as a review
        #expect(TeamMath.median([]) == nil)
    }

    @Test func followMatching() {
        let story = NewsText.tokens("Google DeepMind announces Gemini 4 Argon")
        #expect(FollowMatch.matches(story, NewsText.tokens("Gemini 4 Argon benchmarks leak ahead of API launch")))
        #expect(!FollowMatch.matches(story, NewsText.tokens("Apple releases macOS 26.7")))
    }

    @Test func followedStoryProducesOneEventPerArticle() async throws {
        let store = try Store.inMemory()
        let story = NewsBrief.Story(key: "story:1", title: "Google DeepMind announces Gemini 4 Argon", summary: "", whyItMatters: "",
                                    urls: [], sources: [], topics: ["gemini"], importance: 5)
        try await store.follow(story, now: Date().addingTimeInterval(-60))
        let update = Article(url: "https://v.com/g4", title: "Gemini 4 Argon tops coding benchmarks", source: "Verge", section: .ai,
                             snippet: "", publishedAt: Date())
        let other = Article(url: "https://v.com/x", title: "Apple ships new MacBook Air", source: "Verge", section: .tech,
                            snippet: "", publishedAt: Date())
        let events = try await store.matchFollowed([update, other])
        #expect(events.count == 1)
        #expect(events.first?.category == .newsFollow)
        #expect(try await store.matchFollowed([update]).isEmpty)
        #expect(try await store.updates(for: "story:1").count == 1)
        try await store.unfollow("story:1")
        #expect(try await store.followedStories().isEmpty)
    }

    @Test func urgentDefaults() {
        let c = AppConfig()
        #expect(c.isUrgent(.pipelineFailedMR))
        #expect(!c.isUrgent(.jiraFilterStatus))
        #expect(c.weeklyReportWeekday == 6)
    }
}
