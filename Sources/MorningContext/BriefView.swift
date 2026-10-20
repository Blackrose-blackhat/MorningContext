import SwiftUI
import AppKit

/// Observable state shared between the AppDelegate and the brief window.
final class BriefModel: ObservableObject {
    @Published var phase: BriefEngine.Phase = .idle
    @Published var markdown: String = ""
    @Published var spokenScript: String = ""
    @Published var title: String = "Morning Context"
    @Published var sourcesLine: String = ""
    @Published var dayKey: String = ""
    var onRegenerate: () -> Void = {}
}

struct BriefView: View {
    @ObservedObject var model: BriefModel
    @ObservedObject private var speaker = Speaker.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 420)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: "sunrise.fill").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title).font(.title2.weight(.semibold))
                if !model.sourcesLine.isEmpty {
                    Text(model.sourcesLine).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .collecting, .gathering, .summarizing:
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
                Text(progressText).foregroundStyle(.secondary)
                if case .summarizing(let n) = model.phase {
                    Text("Sending \(n.formatted()) characters of context to Claude…").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            ScrollView {
                MarkdownBlocks(markdown: model.markdown)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24).padding(.vertical, 18)
                    .textSelection(.enabled)
            }
        }
    }

    private var isBusy: Bool {
        switch model.phase { case .collecting, .gathering, .summarizing: return true; default: return false }
    }

    private var progressText: String {
        switch model.phase {
        case .collecting: return "Reading yesterday's Claude Code sessions and Wispr Flow transcripts…"
        case .gathering(let names): return "Asking Claude about \(names)…"
        case .summarizing: return "Asking Claude to write your brief…"
        default: return ""
        }
    }

    private var footer: some View {
        HStack {
            if case .failed(let msg) = model.phase {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(msg).font(.caption).lineLimit(2).foregroundStyle(.secondary)
            }
            Spacer()
            if speaker.isSpeaking {
                Button(speaker.isPaused ? "Resume" : "Pause") { speaker.togglePause() }
                Button("Stop") { speaker.stop() }.keyboardShortcut(".", modifiers: .command)
            } else {
                Button {
                    speaker.speak(model.spokenScript)
                } label: { Label("Read aloud", systemImage: "speaker.wave.2.fill") }
                .disabled(model.spokenScript.isEmpty || isBusy)
                .keyboardShortcut("p", modifiers: .command)
            }
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.markdown, forType: .string)
            }.disabled(model.markdown.isEmpty)
            Button("Open file") {
                guard !model.dayKey.isEmpty else { return }
                NSWorkspace.shared.open(BriefStore.url(for: model.dayKey))
            }.disabled(model.dayKey.isEmpty)
            Button("Regenerate") { model.onRegenerate() }
                .disabled(isBusy)
                .keyboardShortcut("r", modifiers: .command)
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
    }
}

/// A deliberately small Markdown renderer: headings, bullets, numbered lists,
/// checkboxes, rules, code fences, and inline emphasis/code/links via AttributedString.
struct MarkdownBlocks: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                render(block)
            }
        }
    }

    private enum Block {
        case h1(String), h2(String), h3(String)
        case bullet(String, checked: Bool?)
        case numbered(String, String)
        case code(String)
        case rule
        case para(String)
        case blank
    }

    private var blocks: [Block] {
        var out: [Block] = []
        var inCode = false; var code: [String] = []
        for rawLine in markdown.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if inCode { out.append(.code(code.joined(separator: "\n"))); code = [] }
                inCode.toggle(); continue
            }
            if inCode { code.append(rawLine); continue }
            if line.isEmpty { out.append(.blank); continue }
            if line.hasPrefix("<!--") { continue }
            if line.hasPrefix("# ")   { out.append(.h1(String(line.dropFirst(2)))); continue }
            if line.hasPrefix("## ")  { out.append(.h2(String(line.dropFirst(3)))); continue }
            if line.hasPrefix("### ") || line.hasPrefix("#### ") {
                out.append(.h3(line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces))); continue
            }
            if line == "---" || line == "***" { out.append(.rule); continue }
            if line.hasPrefix("- [ ] ") { out.append(.bullet(String(line.dropFirst(6)), checked: false)); continue }
            if line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") { out.append(.bullet(String(line.dropFirst(6)), checked: true)); continue }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") { out.append(.bullet(String(line.dropFirst(2)), checked: nil)); continue }
            if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty, line[line.index(after: dot)...].hasPrefix(" ") {
                out.append(.numbered(String(line[..<dot]) + ".", String(line[line.index(dot, offsetBy: 2)...]))); continue
            }
            out.append(.para(line))
        }
        if inCode { out.append(.code(code.joined(separator: "\n"))) }
        return out
    }

    @ViewBuilder private func render(_ b: Block) -> some View {
        switch b {
        case .h1(let t): inline(t).font(.title.weight(.bold)).padding(.top, 6)
        case .h2(let t): inline(t).font(.title3.weight(.semibold)).padding(.top, 10)
        case .h3(let t): inline(t).font(.headline).padding(.top, 6)
        case .bullet(let t, let checked):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let checked {
                    Image(systemName: checked ? "checkmark.square" : "square").foregroundStyle(.secondary)
                } else {
                    Text("•").foregroundStyle(.secondary)
                }
                inline(t)
            }.padding(.leading, 6)
        case .numbered(let n, let t):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(n).foregroundStyle(.secondary).monospacedDigit()
                inline(t)
            }.padding(.leading, 6)
        case .code(let c):
            Text(c).font(.system(.body, design: .monospaced))
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        case .rule: Divider().padding(.vertical, 4)
        case .para(let t): inline(t)
        case .blank: Spacer().frame(height: 2)
        }
    }

    private func inline(_ s: String) -> Text {
        if let a = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(a)
        }
        return Text(s)
    }
}
