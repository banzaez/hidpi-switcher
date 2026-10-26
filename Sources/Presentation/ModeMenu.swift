import SwiftUI

/// Подменю со списком разрешений или частот (с нативной системной галочкой macOS через `Picker`).
struct ModeMenu: View {
    let title: String
    let modes: [DisplayMode]
    let currentID: Int?
    var labelProvider: (DisplayMode) -> String = \.menuTitle
    let onSelect: (DisplayMode) -> Void

    private var selectionBinding: Binding<Int?> {
        Binding(
            get: { currentID },
            set: { newID in
                guard let newID, let selected = modes.first(where: { $0.id == newID }) else { return }
                onSelect(selected)
            }
        )
    }

    var body: some View {
        if !modes.isEmpty {
            Menu(title) {
                Picker(title, selection: selectionBinding) {
                    ForEach(modes) { mode in
                        Text(labelProvider(mode))
                            .tag(Optional(mode.id))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
    }
}
