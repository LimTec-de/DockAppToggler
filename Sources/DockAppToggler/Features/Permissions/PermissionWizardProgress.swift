/// Tracks this process's permission checks; confirmations never survive a relaunch.
@MainActor
struct PermissionWizardProgress {
    enum Stage: Equatable {
        case permission(Int)
        case restart
        case complete
    }

    private(set) var steps: [PermissionStep]
    private var grantedTitles: Set<String>
    private var confirmedTitles: Set<String> = []
    private var needsRestart = false
    private(set) var requestingIndex: Int?

    mutating func beginRequest(at index: Int) -> Bool {
        guard requestingIndex == nil, refresh() == .permission(index),
              steps[index].requestAccess != nil else { return false }
        requestingIndex = index
        return true
    }

    mutating func finishRequest() {
        requestingIndex = nil
    }

    init(steps: [PermissionStep]) {
        self.steps = steps
        grantedTitles = Set(steps.filter { $0.isGranted() }.map(\.title))
    }

    mutating func include(steps additionalSteps: [PermissionStep]) {
        for step in additionalSteps where !steps.contains(where: { $0.title == step.title }) {
            steps.append(step)
            if step.isGranted() { grantedTitles.insert(step.title) }
        }
    }

    mutating func refresh() -> Stage {
        if let requestingIndex { return .permission(requestingIndex) }
        let granted = steps.map { $0.isGranted() }
        for (index, step) in steps.enumerated() {
            if granted[index] {
                if !grantedTitles.contains(step.title) && step.needsRestartToTakeEffect {
                    needsRestart = true
                }
                grantedTitles.insert(step.title)
            } else {
                grantedTitles.remove(step.title)
            }
        }

        if let index = steps.indices.first(where: {
            !granted[$0] && !confirmedTitles.contains(steps[$0].title)
        }) {
            return .permission(index)
        }
        return needsRestart ? .restart : .complete
    }

    /// The user enabled this switch, but macOS may report access only after relaunch.
    /// This advances setup, never treats the running process as authorized.
    mutating func confirmGrant(at index: Int) {
        guard steps.indices.contains(index), steps[index].needsRestartToTakeEffect else { return }
        confirmedTitles.insert(steps[index].title)
        needsRestart = true
    }
}
