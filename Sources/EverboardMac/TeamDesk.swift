import EverboardCore
import Foundation
import Observation

/// Team radar and 1:1 prep for managers. Everything here is a draft for you: nothing is sent to anyone.
@MainActor @Observable
final class TeamDesk {
    static let shared = TeamDesk()

    var radar: TeamRadar?
    var prep: [String: (text: String, at: Date?)] = [:]
    var prepRunning: Set<String> = []
    var prepError: [String: String] = [:]

    private var model: AppModel { .shared }

    var service: TeamService { TeamService(store: model.store, claude: model.claude, codeHosts: model.codeHosts) }

    /// Recomputes the radar from the store (no network, no AI).
    func refreshRadar() async {
        radar = try? await service.radar(reportees: model.config.reportees, agingDays: model.config.teamAgingDays)
    }

    func loadPreps() async {
        for r in model.config.reportees where prep[r.id] == nil {
            if let p = await service.latestPrep(r) { prep[r.id] = p }
        }
    }

    func digest(wikiLinks: Bool = false) -> String? { radar?.digestMarkdown(wikiLinks: wikiLinks) }

    func saveDigestToBrain() {
        guard let text = digest(wikiLinks: true) else { return }
        model.writeToBrain("team digest") { try $0.writeDailySection("team-digest", heading: "Team digest", markdown: text) }
        ToastCenter.shared.show(.init(title: "Team digest saved to today's note", body: "", actionTitle: nil, onClick: {}, onAction: nil), duration: 3)
    }

    func generatePrep(_ person: Reportee) {
        guard !prepRunning.contains(person.id) else { return }
        prepRunning.insert(person.id)
        prepError[person.id] = nil
        Task {
            defer { prepRunning.remove(person.id) }
            if radar == nil { await refreshRadar() }
            let name = person.name ?? person.username ?? person.email
            do {
                let text = try await service.oneOnOnePrep(person, load: radar?.people.first { $0.id == person.id },
                                                          notes: model.brainContext(person: name))
                prep[person.id] = (text, Date())
                if model.config.brain.writePeople {
                    model.writeToBrain("1:1 prep") { try $0.writePersonSection(name, block: "one-on-one-prep", heading: "1:1 prep", markdown: text) }
                }
            } catch {
                prepError[person.id] = error.localizedDescription
            }
        }
    }
}
