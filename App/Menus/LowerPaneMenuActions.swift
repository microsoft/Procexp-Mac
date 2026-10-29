import SwiftUI

struct LowerPaneMenuActions {
    var properties: (() -> Void)?
    var searchOnline: (() -> Void)?
    var checkVirusTotal: (() -> Void)?
    var revealInFinder: (() -> Void)?
}

private struct LowerPaneActionsKey: FocusedValueKey {
    typealias Value = LowerPaneMenuActions
}

extension FocusedValues {
    var lowerPaneActions: LowerPaneMenuActions? {
        get { self[LowerPaneActionsKey.self] }
        set { self[LowerPaneActionsKey.self] = newValue }
    }
}

struct LowerPaneMenu: View {
    @FocusedValue(\.lowerPaneActions) private var actions

    var body: some View {
        Button("Properties…") { actions?.properties?() }
            .disabled(actions?.properties == nil)
        Button("Search Online") { actions?.searchOnline?() }
            .disabled(actions?.searchOnline == nil)
        Button("Check VirusTotal") { actions?.checkVirusTotal?() }
            .disabled(actions?.checkVirusTotal == nil)
        Button("Reveal in Finder") { actions?.revealInFinder?() }
            .disabled(actions?.revealInFinder == nil)
    }
}
