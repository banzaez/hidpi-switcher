import SwiftUI

/// Подменю со списком разрешений или частот (с нативной системной галочкой macOS).
struct ModeMenu: View {
    let title: String
    let modes: [DisplayMode]
    let currentID: Int?
    var labelProvider: (DisplayMode) -> String = \.menuTitle
    let onSelect: (DisplayMode) -> Void

    var body: some View {
        if !modes.isEmpty {
            Menu(title) {
                ForEach(modes) { mode in
                    Button {
                        onSelect(mode)
                    } label: {
                        if mode.id == currentID {
                            Text("✓ \(labelProvider(mode))")
                        } else {
                            Text(labelProvider(mode))
                        }
                    }
                }
            }
        }
    }
}
