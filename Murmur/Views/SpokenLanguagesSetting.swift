import SwiftUI

/// Settings row for "Languages you speak".
///
/// A menu of checkable languages rather than a picker: the user may speak
/// several, and none of them is "the" recognition language — the speech model
/// works that out for each recording.
struct SpokenLanguagesSetting: View {
    @State private var selected: [String] = SpokenLanguages.current()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Languages you speak") {
                Menu {
                    Button("Select All") {
                        selected = SpokenLanguages.all.map(\.code)
                        SpokenLanguages.save(selected)
                    }
                    .disabled(selected.count == SpokenLanguages.all.count)
                    Divider()
                    ForEach(SpokenLanguages.all) { language in
                        Toggle(isOn: binding(for: language.code)) {
                            Text(language.name)
                        }
                    }
                } label: {
                    Text(Self.summary(of: selected))
                }
                .fixedSize()
                .accessibilityLabel("Languages you speak")
                .accessibilityValue(Self.spokenSummary(of: selected))
            }
            Text("Murmur recognises the language by itself — there is nothing to switch. "
                 + "If you turn off the languages you never speak, a result that comes back "
                 + "in one of them is double-checked before it is typed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func binding(for code: String) -> Binding<Bool> {
        Binding(
            get: { selected.contains(code) },
            set: { isOn in
                selected = Self.toggling(code, on: isOn, in: selected)
                SpokenLanguages.save(selected)
            }
        )
    }

    /// The selection after switching one language on or off. The last
    /// remaining language cannot be switched off: an empty list would mean
    /// nothing is expected.
    static func toggling(_ code: String, on: Bool, in selection: [String]) -> [String] {
        var codes = Set(selection)
        if on {
            codes.insert(code)
        } else if codes.count > 1 {
            codes.remove(code)
        }
        return SpokenLanguages.normalised(Array(codes))
    }

    private static func names(of codes: [String]) -> [String] {
        SpokenLanguages.all.filter { codes.contains($0.code) }.map(\.name)
    }

    /// Menu button title: "All languages", or up to two names and a count of
    /// the rest.
    static func summary(of codes: [String]) -> String {
        let names = names(of: codes)
        if names.count == SpokenLanguages.all.count { return "All languages" }
        guard names.count > 2 else { return names.joined(separator: ", ") }
        return names.prefix(2).joined(separator: ", ") + " +\(names.count - 2)"
    }

    /// Every selected language, for VoiceOver.
    static func spokenSummary(of codes: [String]) -> String {
        let names = names(of: codes)
        if names.count == SpokenLanguages.all.count { return "All languages" }
        return names.joined(separator: ", ")
    }
}
