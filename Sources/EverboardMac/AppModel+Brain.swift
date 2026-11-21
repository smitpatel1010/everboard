import AppKit
import EverboardCore
import Foundation

// Markdown "brain" folder: digests, 1:1 prep and agent runs written as notes (Settings → Brain).
extension AppModel {
    /// Nil when no folder is set. Demo mode never touches your disk.
    var brain: Brain? { DemoData.isDemo ? nil : Brain(settings: config.brain) }

    /// Runs one brain write if the folder is set; failures become a toast, never an error in the feature that triggered it.
    func writeToBrain(_ what: String, _ write: (Brain) throws -> Void) {
        guard let brain else { return }
        do {
            try write(brain)
        } catch {
            Log.info("brain: couldn't save \(what): \(error.localizedDescription)")
            ToastCenter.shared.show(.init(title: "Couldn't save \(what) to your notes", body: error.localizedDescription,
                                          actionTitle: nil, onClick: {}, onAction: nil))
        }
    }

    /// Your own notes about someone (their note and latest 1:1 notes), when Settings → Brain allows sending notes to AI.
    func brainContext(person: BrainPerson) -> String? {
        guard config.brain.readForAI else { return nil }
        return brain?.personContext(person)
    }

    func openInBrain(_ relative: String) {
        guard let brain, let url = try? brain.url(relative) else { return }
        NSWorkspace.shared.open(url)
    }

    func revealBrainFolder() {
        guard let brain else { return }
        NSWorkspace.shared.open(brain.root)
    }
}
