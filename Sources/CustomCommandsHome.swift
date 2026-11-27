import SwiftUI

struct CustomCommandsSection: View {
    @ObservedObject var model: GateModel
    @State private var edit: Edit?

    private struct Edit: Identifiable {
        let id = UUID()
        let index: Int?
        let commands: [CustomScriptPhrases.Command]

        var command: CustomScriptPhrases.Command? { index.map { commands[$0] } }
    }

    var body: some View {
        Section("Custom Commands") {
            if let commands = model.customCommands {
                ForEach(commands.indices, id: \.self) { index in
                    let command = commands[index]
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(command.name)
                            Text(command.phrases.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            edit = Edit(index: index, commands: commands)
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Configure \(command.name)")
                    }
                }
                Button {
                    edit = Edit(index: nil, commands: commands)
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .accessibilityIdentifier("addCustomCommand")
            } else {
                Text(model.customScriptStatus).foregroundStyle(.secondary)
                Button("Reload Custom Phrases") { model.loadCustomScriptPhrases() }
            }
        }
        .sheet(item: $edit) { draft in
            CustomCommandEditor(command: draft.command) { command in
                try model.saveCustomCommand(command, at: draft.index, replacing: draft.commands)
            }
        }
    }
}

private struct CustomCommandEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var phrases: [String]
    @State private var executable: String
    @State private var arguments: [String]
    @State private var folder: String
    @State private var error: String?

    private let title: String
    private let save: (CustomScriptPhrases.Command) throws -> Void

    init(command: CustomScriptPhrases.Command?, save: @escaping (CustomScriptPhrases.Command) throws -> Void) {
        title = command == nil ? "Add Custom Command" : "Edit Custom Command"
        self.save = save
        _name = State(initialValue: command?.name ?? "")
        _phrases = State(initialValue: command?.phrases ?? [""])
        _executable = State(initialValue: command?.executable ?? "")
        _arguments = State(initialValue: command?.arguments ?? [])
        _folder = State(initialValue: command?.workingDirectory ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(title).font(.headline).padding(.top, 14)
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("Executable", text: $executable, prompt: Text("/full/path/to/script"))
                    TextField("Working folder", text: $folder, prompt: Text("Optional"))
                }
                Section("Spellings") {
                    rows($phrases, label: "Spelling", minimum: 1)
                }
                Section("Arguments") {
                    rows($arguments, label: "Argument", minimum: 0)
                }
            }
            .formStyle(.grouped)
            if let error {
                Text(error).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal).padding(.bottom, 8)
                    .accessibilityIdentifier("customCommandError")
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: saveDraft).keyboardShortcut(.defaultAction)
            }.padding()
        }
        .frame(minWidth: 420, idealWidth: 460, minHeight: 390, idealHeight: 500)
    }

    private func rows(_ values: Binding<[String]>, label: String, minimum: Int) -> some View {
        Group {
            ForEach(values.wrappedValue.indices, id: \.self) { index in
                HStack {
                    TextField("\(label) \(index + 1)", text: values[index])
                    if values.wrappedValue.count > minimum {
                        Button { values.wrappedValue.remove(at: index) } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(label.lowercased()) \(index + 1)")
                    }
                }
            }
            Button { values.wrappedValue.append("") } label: {
                Label("Add \(label.lowercased())", systemImage: "plus")
            }
        }
    }

    private func saveDraft() {
        let enteredFolder = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = CustomScriptPhrases.Command(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            phrases: phrases.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
            executable: executable.trimmingCharacters(in: .whitespacesAndNewlines),
            arguments: arguments.isEmpty ? nil : arguments,
            workingDirectory: enteredFolder.isEmpty ? nil : enteredFolder)
        do {
            try save(command)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
