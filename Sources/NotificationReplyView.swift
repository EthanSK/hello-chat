// One shared Settings section and native, nonactivating feedback for the app-owned reply session. — GPT-6.1 Sol
import AppKit
import SwiftUI

extension NotificationReplyCoordinator.Readiness {
    var message: String {
        switch self {
        case .ready: return "Ready"
        case .disabled: return "Off"
        case .listeningOff: return "Turn on Listening on Home."
        case .listenerUnavailable: return "Waiting for H Chat listening."
        case .voiceActive: return "Available after Codex Voice ends."
        case .voiceUnknown: return "Checking Codex Voice…"
        case .desktopUnavailable: return "Available on your unlocked desktop."
        case .codexUnavailable: return "Open Codex to reply."
        }
    }
}

struct NotificationReplySettingsSection: View {
    @ObservedObject var settings: NotificationReplySettings
    @Binding var replySpellings: [String]?
    @Binding var endReplySpellings: [String]?
    @Binding var cancelReplySpellings: [String]?
    let similar: Bool
    let readiness: () -> NotificationReplyCoordinator.Readiness
    private enum Control: CaseIterable { case reply, end, cancel
        var phrase: String {
            switch self {
            case .reply: return NotificationReplyCore.Commands.replyPhrase
            case .end: return NotificationReplyCore.Commands.endReplyPhrase
            case .cancel: return NotificationReplyCore.Commands.cancelReplyPhrase
            }
        }
        var builtIn: [String] {
            switch self {
            case .reply: return NotificationReplyCore.Commands.defaultReplySpellings
            case .end: return NotificationReplyCore.Commands.defaultEndReplySpellings
            case .cancel: return NotificationReplyCore.Commands.defaultCancelReplySpellings
            }
        }
        var identifier: String {
            switch self {
            case .reply: return "notificationReplySpellings"
            case .end: return "notificationEndReplySpellings"
            case .cancel: return "notificationCancelReplySpellings"
            }
        }
    }
    @State private var editing: Control?
    var body: some View {
        Section("Notification Replies") {
            Toggle("Enabled", isOn: $settings.enabled).accessibilityIdentifier("notificationRepliesEnabled")
            Text("Say Reply within \(Int(settings.limits.commandSeconds)) seconds after a notification finishes, or when Say Reply appears if speech was skipped. \(NotificationReplyCore.Commands.finishHint) Pauses keep listening.")
                .foregroundStyle(.secondary)
            ForEach(Control.allCases, id: \.self) { spellingRow($0) }
            Text(readiness().message).foregroundStyle(.secondary).accessibilityIdentifier("notificationReplyReadiness")
        }
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            if let control = editing {
                PhraseDictionaryEditor(slot: nil, phrase: control.phrase, dictionary: dictionary(control),
                    builtIn: control.builtIn, similar: similar, validate: { spellingConflict($0, control: control) })
            }
        }
    }
    private func dictionary(_ control: Control) -> Binding<[String]?> {
        switch control { case .reply: return $replySpellings; case .end: return $endReplySpellings; case .cancel: return $cancelReplySpellings }
    }
    private func spellingRow(_ control: Control) -> some View {
        let listed = dictionary(control).wrappedValue ?? control.builtIn
        let forms = NotificationReplyCore.Commands(replySpellings: replySpellings, endReplySpellings: endReplySpellings,
            cancelReplySpellings: cancelReplySpellings, alternateSpellings: similar)
        let used: [[String]] = switch control { case .reply: forms.replyForms; case .end: forms.endReplyForms; case .cancel: forms.cancelReplyForms }
        let main = PhraseMatcher.words(control.phrase).joined(separator: " ")
        let recognized = Set(used.map { $0.joined(separator: " ") }).subtracting([main])
        let unused = similar ? listed.filter { !recognized.contains(PhraseMatcher.words($0).joined(separator: " ")) }.count : 0
        return HStack {
            Text(control.phrase)
            Spacer()
            SpellingCountButton(count: listed.count, unused: unused, identifier: control.identifier) { editing = control }
        }
    }
    private func spellingConflict(_ entries: [String], control: Control) -> String? {
        let forms = NotificationReplyCore.Commands(replySpellings: control == .reply ? entries : replySpellings,
            endReplySpellings: control == .end ? entries : endReplySpellings,
            cancelReplySpellings: control == .cancel ? entries : cancelReplySpellings)
        let starts = Set(forms.replyForms), ends = Set(forms.endReplyForms), cancels = Set(forms.cancelReplyForms)
        if !starts.isDisjoint(with: ends) || !starts.isDisjoint(with: cancels) || !ends.isDisjoint(with: cancels) {
            return "Reply, End reply and Cancel reply need different spellings."
        }
        let sorted = forms.replyForms.sorted { $0.lexicographicallyPrecedes($1) }
        if zip(sorted, sorted.dropFirst()).contains(where: { $1.starts(with: $0) }) {
            return "One Reply spelling can’t start with another."
        }
        return nil
    }
}

/// Native nonactivating panels accept a first-click drag/cancel, without taking keyboard focus. — GPT-6.1 Sol
@MainActor final class NotificationReplyHUD {
    final class Panel: NSPanel, NSWindowDelegate {
        let host: FirstMouseHost
        var moved: ((NSRect) -> Void)?
        var positioning = false
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
        init(content: AnyView) {
            host = FirstMouseHost(rootView: content)
            super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            isFloatingPanel = true; hidesOnDeactivate = false; isReleasedWhenClosed = false
            becomesKeyOnlyIfNeeded = true; level = .statusBar
            collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            ignoresMouseEvents = false; isOpaque = false; backgroundColor = .clear; hasShadow = true
            title = "Notification Reply"; delegate = self
            let material = NSVisualEffectView()
            material.material = .hudWindow; material.blendingMode = .behindWindow; material.state = .active
            material.wantsLayer = true; material.layer?.cornerRadius = 16; material.layer?.masksToBounds = true
            host.autoresizingMask = [.width, .height]; material.addSubview(host); contentView = material
        }
        func windowDidMove(_ notification: Notification) { if !positioning { moved?(frame) } }
    }
    final class FirstMouseHost: NSHostingView<AnyView> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
    private(set) var panels: [CGDirectDisplayID: Panel] = [:]
    private var presentation: NotificationReplyCoordinator.Presentation?
    private var dismissedEvent: UUID?
    private let isPreview: Bool, showsWindows: Bool
    private let defaults: UserDefaults
    private var positions: [String: [Double]]
    private var observers: [NSObjectProtocol] = []
    private var hideTask: Task<Void, Never>?
    var onDismiss: ((UUID) -> Void)?
    init(isPreview: Bool = false, defaults: UserDefaults = .standard, showsWindows: Bool = true) {
        self.isPreview = isPreview; self.defaults = defaults; self.showsWindows = showsWindows
        positions = defaults.dictionary(forKey: "notificationReplyHUDPositions") as? [String: [Double]] ?? [:]
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
    }
    deinit { hideTask?.cancel(); observers.forEach { NotificationCenter.default.removeObserver($0) } }
    func show(_ value: NotificationReplyCoordinator.Presentation?) {
        if let value, value.event == dismissedEvent { return }
        if let value, value.event != presentation?.event { dismissedEvent = nil }
        hideTask?.cancel(); hideTask = nil; presentation = value
        refresh()
        if let value, [.cancelled, .unavailable].contains(value.phase) {
            hideTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                guard let self, self.presentation?.event == value.event else { return }
                self.dismissedEvent = value.event; self.presentation = nil; self.refresh()
            }
        }
    }
    func dismissCurrent() {
        guard let event = presentation?.event else { return }
        dismissedEvent = event; presentation = nil; hideTask?.cancel(); hideTask = nil
        refresh(); onDismiss?(event)
    }
    private func refresh() {
        guard let presentation else { panels.values.forEach { $0.close() }; panels.removeAll(); return }
        var present: Set<CGDirectDisplayID> = []
        for screen in NSScreen.screens where !isPreview || screen.localizedName == "Built-in Retina Display" {
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { continue }
            present.insert(id)
            let area = screen.visibleFrame, width = min(480, area.width - 32)
            let cap = min(208, area.height * 0.3), key = WindowDisplay.identifier(screen)
            let textBudget = max(36, cap - 112)
            let referenceLimit = min(44, textBudget * 0.45)
            func textHeight(_ text: String, size: CGFloat, limit: CGFloat) -> CGFloat {
                let bounds = (text as NSString).boundingRect(with: NSSize(width: width - 36, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: size)])
                return min(limit, max(18, ceil(bounds.height)))
            }
            let view = AnyView(NotificationReplyHUDContent(presentation: presentation, isPreview: isPreview,
                referenceHeight: textHeight(presentation.spokenText, size: 13, limit: referenceLimit),
                replyHeight: textHeight(presentation.replyText, size: 14, limit: textBudget - referenceLimit), dismiss: { [weak self] in self?.dismissCurrent() })
                .padding(12).frame(width: width, alignment: .topLeading))
            let existing = panels[id]
            let panel = existing ?? Panel(content: view)
            panel.host.rootView = view
            let height = min(cap, max(88, panel.host.fittingSize.height))
            let saved = positions[key]
            let x = existing?.frame.minX ?? (saved?.count == 2 ? saved![0] : area.midX - width / 2)
            let top = existing?.frame.maxY ?? (saved?.count == 2 ? saved![1] : area.maxY - 20)
            panel.positioning = true
            panel.setFrame(NSRect(x: min(area.maxX - width - 8, max(area.minX + 8, x)),
                                  y: min(area.maxY - height - 8, max(area.minY + 8, top - height)),
                                  width: width, height: height), display: true)
            panel.host.frame = panel.contentView?.bounds ?? .zero
            panel.positioning = false
            panel.moved = { [weak self] frame in
                guard let self else { return }
                self.positions[key] = [frame.minX, frame.maxY]
                self.defaults.set(self.positions, forKey: "notificationReplyHUDPositions")
            }
            panels[id] = panel
            if showsWindows { panel.orderFrontRegardless() }
        }
        for id in Array(panels.keys) where !present.contains(id) { panels.removeValue(forKey: id)?.close() }
    }
}

/// The header has a real native drag target; it excludes the cancel button and scrollable reference. — GPT-6.1 Sol
private struct NotificationReplyDragArea: NSViewRepresentable {
    final class Area: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            if Bundle.main.object(forInfoDictionaryKey: "HChatNotificationReplySmoke") as? Bool == true {
                UserDefaults.standard.set(true, forKey: "HChatSmokeHeaderReceivedMouseDown")
            }
            window?.performDrag(with: event)
        }
    }
    func makeNSView(context: Context) -> Area { Area() }
    func updateNSView(_ view: Area, context: Context) {}
}

struct NotificationReplyHUDContent: View {
    let presentation: NotificationReplyCoordinator.Presentation
    var isPreview = false
    var referenceHeight: CGFloat = 148
    var replyHeight: CGFloat = 60
    var dismiss: (() -> Void)?
    private var title: String {
        presentation.confirmingReply ? "Confirming Reply…" : Self.statusTitle(presentation.phase, reason: presentation.reason)
    }
    static func statusTitle(_ phase: NotificationReplyCore.Phase, reason: String) -> String {
        switch phase {
        case .preparing: return "Preparing reply…"
        case .announcing: return "Notification playing…"
        case .waiting: return "Say Reply"
        case .composing: return "Listening to your reply"
        case .releasing: return "Finishing reply…"
        case .cancelled: return reason == "no-command" ? "No reply" : "Reply cancelled"
        case .unavailable:
            if reason == NotificationReplyOrigin.Failure.submissionUnknown.rawValue { return "Delivery unconfirmed" }
            if reason == NotificationReplyOrigin.Failure.duplicateDispatch.rawValue { return "Reply already reserved" }
            return "Reply unavailable"
        case .queued: return "Reply queued"
        case .delivered: return "Reply sent"
        }
    }
    private var detail: String {
        switch presentation.phase {
        case .preparing: return "Getting the original chat ready."
        case .announcing: return "Wait for the notification to finish."
        case .waiting: return presentation.confirmingReply ? "" : "Start within \(Int(presentation.commandSeconds)) seconds."
        case .composing: return ""
        case .releasing: return "Finishing notification cleanup."
        case .queued: return "Waiting for your reply to appear in the original chat."
        case .delivered: return "Saved in the original chat."
        case .cancelled, .unavailable:
            if presentation.reason == "end-command-unconfirmed" { return "End reply wasn't confirmed. Nothing sent." }
            if presentation.reason == NotificationReplyOrigin.Failure.submissionUnknown.rawValue {
                return "Delivery is unconfirmed. It won't be sent again."
            }
            if presentation.reason == NotificationReplyOrigin.Failure.duplicateDispatch.rawValue {
                return "This reply was already submitted or reserved. It won't be sent again."
            }
            if let readiness = NotificationReplyCoordinator.Readiness(rawValue: presentation.reason) { return readiness.message }
            return "Nothing sent."
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    if presentation.confirmingReply || [.preparing, .announcing, .releasing].contains(presentation.phase) { ProgressView().controlSize(.small) }
                    else { Image(systemName: presentation.phase == .composing ? "waveform" : "bubble.left") }
                    Text((isPreview ? "Preview · " : "") + title).font(.system(size: 15, weight: .semibold))
                    Spacer(minLength: 0)
                }.overlay(NotificationReplyDragArea())
                if let dismiss {
                    Button(action: dismiss) { Image(systemName: "xmark").frame(width: 20, height: 20) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(presentation.phase == .preparing || presentation.phase == .announcing || presentation.phase == .waiting || presentation.phase == .composing || presentation.phase == .releasing ? "Cancel reply" : "Close")
                        .accessibilityIdentifier("dismissNotificationReply")
                }
            }
            if !detail.isEmpty { Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if presentation.phase == .composing, !presentation.replyText.isEmpty {
                ScrollViewReader { reader in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(presentation.replyText).font(.system(size: 14))
                                .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                            Color.clear.frame(height: 1).id("reply-end")
                        }
                    }.frame(height: replyHeight).scrollIndicators(.visible)
                        .onChange(of: presentation.replyText) { _, _ in reader.scrollTo("reply-end", anchor: .bottom) }
                }.accessibilityIdentifier("notificationReplyLiveText")
            }
            if !presentation.spokenText.isEmpty {
                Divider()
                Text("Notification").font(.system(size: 11)).foregroundStyle(.secondary)
                ScrollView {
                    Text(presentation.spokenText).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true).padding(.trailing, 6)
                }.frame(height: referenceHeight).scrollIndicators(.visible)
            }
            if presentation.confirmingReply || presentation.phase == .composing {
                Text(NotificationReplyCore.Commands.finishHint).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("notificationReplyControlHint")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain).accessibilityIdentifier("notificationReplyHUD")
    }
}
