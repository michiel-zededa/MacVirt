// SPDX-License-Identifier: GPL-2.0-or-later
// Small form building blocks shared by the hardware pages.

import SwiftUI

/// A picker over (value, label) pairs that keeps an unknown current value selectable.
struct Choice: View {
    let title: String
    @Binding var value: String
    let options: [(String, String)]

    init(_ title: String, _ value: Binding<String>, _ options: [(String, String)]) {
        self.title = title
        _value = value
        self.options = options
    }

    var body: some View {
        Picker(title, selection: $value) {
            ForEach(allOptions, id: \.0) { v, label in Text(label).tag(v) }
        }
    }

    private var allOptions: [(String, String)] {
        options.contains { $0.0 == value } ? options : options + [(value, value.isEmpty ? "Default" : value)]
    }
}

/// Text field that commits on every keystroke.
struct Field: View {
    let title: String
    @Binding var value: String
    var prompt: String = ""

    init(_ title: String, _ value: Binding<String>, prompt: String = "") {
        self.title = title
        _value = value
        self.prompt = prompt
    }

    var body: some View {
        TextField(title, text: $value, prompt: prompt.isEmpty ? nil : Text(prompt))
    }
}

struct ReadOnly: View {
    let title: String
    let value: String
    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }
    var body: some View {
        LabeledContent(title) { Text(value.isEmpty ? "—" : value).textSelection(.enabled) }
    }
}

/// Integer stepper backed by a string attribute.
struct NumberField: View {
    let title: String
    @Binding var value: Int
    var range: ClosedRange<Int>
    var unit: String = ""

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField("", value: $value, format: .number)
                    .frame(width: 90)
                    .multilineTextAlignment(.trailing)
                Stepper("", value: $value, in: range).labelsHidden()
                if !unit.isEmpty { Text(unit).foregroundStyle(.secondary) }
            }
        }
    }
}

/// Details / XML tab container used by every device page.
struct DevicePage<Content: View>: View {
    let editor: DomainEditor
    let title: String
    let element: XMLElement?
    @ViewBuilder var content: () -> Content
    @StateVar private var tab = 0
    @StateVar private var xmlText = ""
    @StateVar private var xmlError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.title3).bold()
                Spacer()
                if element != nil {
                    Picker("", selection: $tab) {
                        Text("Details").tag(0)
                        Text("XML").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 160)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            if tab == 0 || element == nil {
                Form { content() }
                    .formStyle(.grouped)
            } else {
                VStack(alignment: .leading) {
                    TextEditor(text: $xmlText)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(.background.secondary, in: .rect(cornerRadius: 8))
                    HStack {
                        if let xmlError { Label(xmlError, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                        Spacer()
                        Button("Use XML") {
                            guard let element else { return }
                            do {
                                try editor.replace(element, withXML: xmlText)
                                xmlError = nil
                            } catch { xmlError = error.localizedDescription }
                        }
                        .disabled(xmlText == currentXML)
                    }
                }
                .padding(20)
                .onAppear { xmlText = currentXML }
                .onChange(of: editor.revision) { xmlText = currentXML }
            }
        }
    }

    private var currentXML: String { element?.xmlString(options: [.nodePrettyPrint]) ?? "" }
}

/// Converts between libvirt memory elements (with unit attribute) and MiB.
enum MemoryUnits {
    static func mib(_ el: XMLElement?) -> Int {
        guard let el, let v = Double(el.stringValue ?? "") else { return 0 }
        let factor: Double
        switch (el.attr("unit") ?? "KiB").lowercased() {
        case "b", "bytes": factor = 1.0 / 1_048_576
        case "k", "kib": factor = 1.0 / 1024
        case "kb": factor = 1000.0 / 1_048_576
        case "m", "mib": factor = 1
        case "mb": factor = 1_000_000.0 / 1_048_576
        case "g", "gib": factor = 1024
        case "gb": factor = 1_000_000_000.0 / 1_048_576
        case "t", "tib": factor = 1_048_576
        default: factor = 1.0 / 1024
        }
        return Int((v * factor).rounded())
    }

    static func set(_ el: XMLElement, mib: Int) {
        el.stringValue = String(mib * 1024)
        el.setAttr("unit", "KiB")
    }
}
