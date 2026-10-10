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
                    ForEach(SpokenLanguages.all) { language in
                        Toggle(isOn: binding(for: language.code)) {
                            Text(Self.menuTitle(for: language))
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
                 + "This list tells it which languages to expect, so an odd result can be double-checked. "
                 + "Chinese and English are tested; other languages may be less accurate.")
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

    static func menuTitle(for language: SpokenLanguage) -> String {
        language.isTested ? language.name : "\(language.name) — not tested"
    }

    private static func names(of codes: [String]) -> [String] {
        SpokenLanguages.all.filter { codes.contains($0.code) }.map(\.name)
    }

    /// Menu button title: up to two names, then a count of the rest.
    static func summary(of codes: [String]) -> String {
        let names = names(of: codes)
        guard names.count > 2 else { return names.joined(separator: ", ") }
        return names.prefix(2).joined(separator: ", ") + " +\(names.count - 2)"
    }

    /// Every selected language, for VoiceOver.
    static func spokenSummary(of codes: [String]) -> String {
        names(of: codes).joined(separator: ", ")
    }
}
