import SwiftUI
import AppKit
import Combine

// MARK: - Model

struct StickerData: Codable, Identifiable, Equatable {
    var id: UUID
    var text: String
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat
    var pinned: Bool = false

    enum CodingKeys: String, CodingKey { case id, text, x, y, width, height, pinned }

    init(id: UUID, text: String, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, pinned: Bool = false) {
        self.id = id; self.text = text; self.x = x; self.y = y
        self.width = width; self.height = height; self.pinned = pinned
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        x = try c.decode(CGFloat.self, forKey: .x)
        y = try c.decode(CGFloat.self, forKey: .y)
        width = try c.decode(CGFloat.self, forKey: .width)
        height = try c.decode(CGFloat.self, forKey: .height)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
    }
}

final class Store {
    static let shared = Store()
    let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StickyNotes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("stickers.json")
    }()

    func load() -> [StickerData] {
        guard let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([StickerData].self, from: data) else {
            return []
        }
        return items
    }

    func save(_ items: [StickerData]) {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Shared app state (drives both dashboard and stickers)

final class AppState: ObservableObject {
    @Published var stickers: [StickerData] = []
    @Published var glassVariant: Int = UserDefaults.standard.integer(forKey: "glassVariant") {
        didSet { UserDefaults.standard.set(glassVariant, forKey: "glassVariant") }
    }
    @Published var regularBgOpacity: CGFloat = {
        let v = UserDefaults.standard.object(forKey: "regularBgOpacity") as? Double
        return CGFloat(v ?? 0.5)
    }() {
        didSet { UserDefaults.standard.set(Double(regularBgOpacity), forKey: "regularBgOpacity") }
    }
    @Published var fontSize: CGFloat = {
        let v = UserDefaults.standard.object(forKey: "fontSize") as? Double
        return CGFloat(v ?? 14)
    }() {
        didSet { UserDefaults.standard.set(Double(fontSize), forKey: "fontSize") }
    }
    @Published var fontColor: Color = AppState.loadColor("fontColor", default: .white) {
        didSet { AppState.saveColor(fontColor, "fontColor") }
    }
    @Published var bgColor: Color = AppState.loadColor("bgColor", default: Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 0)) {
        didSet { AppState.saveColor(bgColor, "bgColor") }
    }

    static func loadColor(_ key: String, default def: Color) -> Color {
        guard let arr = UserDefaults.standard.array(forKey: key) as? [Double], arr.count == 4 else { return def }
        return Color(.sRGB, red: arr[0], green: arr[1], blue: arr[2], opacity: arr[3])
    }
    static func saveColor(_ c: Color, _ key: String) {
        let ns = NSColor(c).usingColorSpace(.sRGB) ?? NSColor.white
        UserDefaults.standard.set(
            [Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent), Double(ns.alphaComponent)],
            forKey: key
        )
    }

    func upsert(_ s: StickerData) {
        if let i = stickers.firstIndex(where: { $0.id == s.id }) {
            stickers[i] = s
        } else {
            stickers.append(s)
        }
        Store.shared.save(stickers)
    }

    func remove(_ id: UUID) {
        stickers.removeAll { $0.id == id }
        Store.shared.save(stickers)
    }

    func sticker(_ id: UUID) -> StickerData? {
        stickers.first { $0.id == id }
    }
}

// MARK: - Liquid Glass background

struct FrostedBackground: View {
    @ObservedObject var state: AppState
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let glass: Glass = (state.glassVariant == 1) ? .clear : .regular
        return ZStack {
            Color.clear.glassEffect(glass, in: shape)
            if state.glassVariant == 0 {
                state.bgColor.opacity(state.regularBgOpacity).clipShape(shape)
            }
        }
    }
}

// MARK: - Markdown

/// One rendered block of a note. Notes are always stored as raw Markdown;
/// blocks are derived on the fly for the preview and never persisted.
struct MDBlock: Identifiable {
    enum ListMarker {
        case bullet
        case ordered(String)
        /// `line` is the source line index, so the checkbox can be toggled in place.
        case task(checked: Bool, line: Int)

        var isChecked: Bool {
            if case .task(true, _) = self { return true }
            return false
        }
    }

    enum ColumnAlignment {
        case leading, center, trailing

        var frame: Alignment {
            switch self {
            case .leading: return .leading
            case .center: return .center
            case .trailing: return .trailing
            }
        }

        var text: TextAlignment {
            switch self {
            case .leading: return .leading
            case .center: return .center
            case .trailing: return .trailing
            }
        }
    }

    enum Kind {
        case heading(level: Int, text: String)
        case paragraph(String)
        case listItem(indent: Int, marker: ListMarker, text: String)
        case quote(String)
        case code(String)
        case table(header: [String], alignments: [ColumnAlignment], rows: [[String]])
        case rule
    }

    let id: Int
    let kind: Kind

    var isListItem: Bool {
        if case .listItem = kind { return true }
        return false
    }
}

/// Small line-based GFM block parser. Inline formatting (bold, italic,
/// ~~strikethrough~~, `code`, links) is delegated to Foundation's built-in
/// Markdown support, which keeps the app dependency-free.
enum MarkdownParser {
    struct ListItem {
        let indent: Int
        let ordered: String?
        /// Character offset of the space / `x` inside `[ ]`, for task items.
        let checkboxOffset: Int?
        let checked: Bool
        let content: String
    }

    static func parse(_ text: String) -> [MDBlock] {
        let lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        var blocks: [MDBlock] = []
        func add(_ kind: MDBlock.Kind) { blocks.append(MDBlock(id: blocks.count, kind: kind)) }

        func isTableStart(_ j: Int) -> Bool {
            lines[j].contains("|") && j + 1 < lines.count && tableAlignments(lines[j + 1]) != nil
        }
        func startsBlock(_ j: Int) -> Bool {
            let t = lines[j].trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("```") || t.hasPrefix("~~~") || heading(t) != nil || isRule(t)
                || t.hasPrefix(">") || listItem(lines[j]) != nil || isTableStart(j)
        }

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { i += 1; continue }

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fence = String(trimmed.prefix(3))
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i])
                    i += 1
                }
                i += 1 // closing fence (an unclosed fence runs to the end)
                add(.code(code.joined(separator: "\n")))
                continue
            }

            if let h = heading(trimmed) {
                add(.heading(level: h.level, text: h.text))
                i += 1
                continue
            }

            if isRule(trimmed) {
                add(.rule)
                i += 1
                continue
            }

            if isTableStart(i), let alignments = tableAlignments(lines[i + 1]) {
                let header = tableCells(trimmed)
                if header.count == alignments.count {
                    var rows: [[String]] = []
                    i += 2
                    while i < lines.count {
                        let t = lines[i].trimmingCharacters(in: .whitespaces)
                        guard !t.isEmpty, t.contains("|") else { break }
                        var cells = tableCells(t)
                        if cells.count < header.count {
                            cells += Array(repeating: "", count: header.count - cells.count)
                        }
                        rows.append(Array(cells.prefix(header.count)))
                        i += 1
                    }
                    add(.table(header: header, alignments: alignments, rows: rows))
                    continue
                }
            }

            if trimmed.hasPrefix(">") {
                var quote: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    var rest = t.dropFirst()
                    if rest.hasPrefix(" ") { rest = rest.dropFirst() }
                    quote.append(String(rest))
                    i += 1
                }
                add(.quote(quote.joined(separator: "\n")))
                continue
            }

            if let item = listItem(line) {
                let marker: MDBlock.ListMarker
                if item.checkboxOffset != nil {
                    marker = .task(checked: item.checked, line: i)
                } else if let label = item.ordered {
                    marker = .ordered(label)
                } else {
                    marker = .bullet
                }
                add(.listItem(indent: item.indent, marker: marker, text: item.content))
                i += 1
                continue
            }

            // Paragraph: line breaks are kept as typed, which suits short notes
            // better than CommonMark's soft-wrap joining.
            var para = [trimmed]
            i += 1
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.isEmpty || startsBlock(i) { break }
                para.append(t)
                i += 1
            }
            add(.paragraph(para.joined(separator: "\n")))
        }
        return blocks
    }

    /// Flips `[ ]` ↔ `[x]` on the given source line, leaving everything else untouched.
    static func toggleTask(in text: String, line: Int) -> String {
        var lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(line) else { return text }
        var raw = lines[line]
        let hadCR = raw.hasSuffix("\r")
        if hadCR { raw.removeLast() } // match parse(), which strips CRLF endings
        guard let item = listItem(raw), let offset = item.checkboxOffset else { return text }
        var chars = Array(raw)
        chars[offset] = item.checked ? " " : "x"
        lines[line] = String(chars) + (hadCR ? "\r" : "")
        return lines.joined(separator: "\n")
    }

    static func inline(_ s: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
    }

    static func listItem(_ line: String) -> ListItem? {
        let chars = Array(line)
        var i = 0
        var indent = 0
        while i < chars.count, chars[i] == " " || chars[i] == "\t" {
            indent += chars[i] == "\t" ? 4 : 1
            i += 1
        }
        guard i < chars.count else { return nil }

        var ordered: String? = nil
        if "-*+".contains(chars[i]) {
            i += 1
        } else if chars[i].isASCII, chars[i].isNumber {
            var j = i
            while j < chars.count, chars[j].isASCII, chars[j].isNumber { j += 1 }
            guard j < chars.count, j - i <= 9, chars[j] == "." || chars[j] == ")" else { return nil }
            ordered = String(chars[i...j])
            i = j + 1
        } else {
            return nil
        }

        // The marker must be followed by whitespace (or end the line).
        if i < chars.count {
            guard chars[i] == " " || chars[i] == "\t" else { return nil }
            while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
        }

        var checkboxOffset: Int? = nil
        var checked = false
        if i + 2 < chars.count, chars[i] == "[", chars[i + 2] == "]", " xX".contains(chars[i + 1]),
           i + 3 == chars.count || chars[i + 3] == " " {
            checkboxOffset = i + 1
            checked = chars[i + 1] != " "
            i += 3
        }

        let content = String(chars[min(i, chars.count)...]).trimmingCharacters(in: .whitespaces)
        return ListItem(indent: indent, ordered: ordered, checkboxOffset: checkboxOffset, checked: checked, content: content)
    }

    static func heading(_ t: String) -> (level: Int, text: String)? {
        let level = t.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level) else { return nil }
        let rest = t.dropFirst(level)
        guard rest.isEmpty || rest.first == " " else { return nil }
        return (level, rest.trimmingCharacters(in: .whitespaces))
    }

    static func isRule(_ t: String) -> Bool {
        let s = t.replacingOccurrences(of: " ", with: "")
        guard let first = s.first, "-*_".contains(first), s.count >= 3 else { return false }
        return s.allSatisfy { $0 == first }
    }

    static func tableAlignments(_ line: String) -> [MDBlock.ColumnAlignment]? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("|"), t.contains("-") else { return nil }
        var result: [MDBlock.ColumnAlignment] = []
        for cell in tableCells(t) {
            let left = cell.hasPrefix(":"), right = cell.hasSuffix(":")
            let dashes = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            result.append(left && right ? .center : right ? .trailing : .leading)
        }
        return result
    }

    /// Splits a table row on unescaped pipes, dropping the optional outer pipes.
    static func tableCells(_ t: String) -> [String] {
        var s = Substring(t)
        if s.hasPrefix("|") { s = s.dropFirst() }
        if s.hasSuffix("|") && !s.hasSuffix("\\|") { s = s.dropLast() }
        var cells: [String] = []
        var current = ""
        var previous: Character? = nil
        for ch in s {
            if ch == "|" && previous != "\\" {
                cells.append(current)
                current = ""
            } else if ch == "|" {
                current.removeLast() // drop the escaping backslash
                current.append(ch)
            } else {
                current.append(ch)
            }
            previous = ch
        }
        cells.append(current)
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

struct MarkdownView: View {
    let text: String
    let fontSize: CGFloat
    let fontColor: Color
    let onToggleTask: (Int) -> Void

    var body: some View {
        let blocks = MarkdownParser.parse(text)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(blocks) { block in
                blockView(block.kind)
                    .padding(.top, topSpacing(blocks, block.id))
            }
        }
        .font(.system(size: fontSize, design: .rounded))
        .foregroundColor(fontColor)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Consecutive list items sit tight together; everything else gets a paragraph gap.
    private func topSpacing(_ blocks: [MDBlock], _ i: Int) -> CGFloat {
        guard i > 0 else { return 0 }
        return blocks[i].isListItem && blocks[i - 1].isListItem ? fontSize * 0.25 : fontSize * 0.6
    }

    private func inline(_ s: String) -> Text {
        Text(MarkdownParser.inline(s))
    }

    private static func headingScale(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 1.6
        case 2: return 1.35
        case 3: return 1.15
        default: return 1.0
        }
    }

    @ViewBuilder
    private func blockView(_ kind: MDBlock.Kind) -> some View {
        switch kind {
        case .heading(let level, let text):
            inline(text)
                .font(.system(size: fontSize * Self.headingScale(level), weight: level <= 2 ? .bold : .semibold, design: .rounded))
        case .paragraph(let text):
            inline(text)
        case .listItem(let indent, let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                switch marker {
                case .bullet:
                    Text("•")
                case .ordered(let label):
                    Text(label).monospacedDigit()
                case .task(let checked, let line):
                    Button { onToggleTask(line) } label: {
                        Image(systemName: checked ? "checkmark.square.fill" : "square")
                            .font(.system(size: fontSize))
                    }
                    .buttonStyle(.plain)
                }
                inline(text)
                    .opacity(marker.isChecked ? 0.55 : 1)
            }
            .padding(.leading, CGFloat(indent) * fontSize * 0.5)
        case .quote(let text):
            inline(text)
                .opacity(0.8)
                .padding(.leading, 11)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(fontColor.opacity(0.4))
                        .frame(width: 3)
                }
        case .code(let code):
            Text(code)
                .font(.system(size: fontSize * 0.9, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(fontColor.opacity(0.12))
                )
        case .table(let header, let alignments, let rows):
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(header.indices, id: \.self) { col in
                        tableCell(header[col], alignments[col], isHeader: true)
                    }
                }
                ForEach(rows.indices, id: \.self) { r in
                    GridRow {
                        ForEach(rows[r].indices, id: \.self) { col in
                            tableCell(rows[r][col], alignments[col], isHeader: false)
                        }
                    }
                }
            }
            .overlay(Rectangle().stroke(fontColor.opacity(0.3), lineWidth: 1))
        case .rule:
            Rectangle()
                .fill(fontColor.opacity(0.3))
                .frame(height: 1)
        }
    }

    private func tableCell(_ text: String, _ align: MDBlock.ColumnAlignment, isHeader: Bool) -> some View {
        inline(text)
            .fontWeight(isHeader ? .semibold : nil)
            .multilineTextAlignment(align.text)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: align.frame)
            .background(isHeader ? fontColor.opacity(0.12) : Color.clear)
            .overlay(Rectangle().stroke(fontColor.opacity(0.2), lineWidth: 0.5))
    }
}

// MARK: - Sticker view

/// Per-window UI state shared between the AppKit window and its SwiftUI body.
final class StickerUIState: ObservableObject {
    @Published var editing: Bool
    init(editing: Bool) { self.editing = editing }
}

struct StickerView: View {
    let id: UUID
    @ObservedObject var state: AppState
    @ObservedObject var ui: StickerUIState
    let onClose: () -> Void
    let onDrag: () -> Void
    let onTogglePin: () -> Void
    @State private var hovering = false
    @FocusState private var editorFocused: Bool

    private var text: Binding<String> {
        Binding(
            get: { state.sticker(id)?.text ?? "" },
            set: { new in
                guard var s = state.sticker(id) else { return }
                s.text = new
                state.upsert(s)
            }
        )
    }

    private var isPinned: Bool { state.sticker(id)?.pinned ?? false }

    private func toggleTask(_ line: Int) {
        guard var s = state.sticker(id) else { return }
        s.text = MarkdownParser.toggleTask(in: s.text, line: line)
        state.upsert(s)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title bar — drag handle
            ZStack {
                Color.black.opacity(0.55)
                HStack {
                    Button(action: onClose) {
                        Circle()
                            .fill(Color.white.opacity(hovering ? 1 : 0.7))
                            .frame(width: 11, height: 11)
                            .overlay(
                                Image(systemName: "xmark")
                                    .font(.system(size: 7, weight: .bold, design: .rounded))
                                    .foregroundColor(.black)
                                    .opacity(hovering ? 1 : 0)
                            )
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button(action: { ui.editing.toggle() }) {
                        Image(systemName: ui.editing ? "eye" : "pencil")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white.opacity(hovering ? 0.9 : 0.6))
                            .help(ui.editing ? "Preview" : "Edit")
                    }
                    .buttonStyle(.plain)
                    Button(action: onTogglePin) {
                        Image(systemName: isPinned ? "pin.fill" : "pin")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white.opacity(isPinned ? 1 : (hovering ? 0.9 : 0.6)))
                            .rotationEffect(.degrees(isPinned ? 0 : 45))
                            .help(isPinned ? "Unpin" : "Keep on top")
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
            }
            .frame(height: 24)
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { _ in onDrag() }
            )

            // Body — raw Markdown while editing, rendered preview otherwise.
            Group {
                if ui.editing {
                    TextEditor(text: text)
                        .font(.system(size: state.fontSize, design: .rounded))
                        .scrollContentBackground(.hidden)
                        .foregroundColor(state.fontColor)
                        .focused($editorFocused)
                        .onAppear { DispatchQueue.main.async { editorFocused = true } }
                        .onChange(of: editorFocused) { _, focused in
                            if !focused { ui.editing = false }
                        }
                        .onExitCommand { ui.editing = false }
                } else {
                    ScrollView {
                        let markdown = text.wrappedValue
                        if markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("Click to write…")
                                .font(.system(size: state.fontSize, design: .rounded))
                                .foregroundColor(state.fontColor.opacity(0.45))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            MarkdownView(
                                text: markdown,
                                fontSize: state.fontSize,
                                fontColor: state.fontColor,
                                onToggleTask: toggleTask
                            )
                        }
                    }
                    // Line up with TextEditor's built-in text inset so toggling doesn't jump.
                    .padding(.horizontal, 5)
                    .contentShape(Rectangle())
                    .onTapGesture { ui.editing = true }
                }
            }
            .padding(10)
        }
        .background(FrostedBackground(state: state, cornerRadius: 14))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.25), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 3, x: 0, y: 1)
        .overlay(alignment: .bottomTrailing) {
            Path { p in
                p.move(to: CGPoint(x: 0, y: 12))
                p.addQuadCurve(to: CGPoint(x: 12, y: 0), control: CGPoint(x: 12, y: 12))
            }
            .stroke(Color.primary.opacity(0.35), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
            .frame(width: 12, height: 12)
            .padding(6)
            .allowsHitTesting(false)
        }
        .onHover { hovering = $0 }
    }
}

// MARK: - Sticker window

final class StickerWindow: NSWindow {
    let stickerID: UUID
    let ui: StickerUIState

    init(data: StickerData, state: AppState, onClose: @escaping (UUID) -> Void, onTogglePin: @escaping (UUID) -> Void) {
        self.stickerID = data.id
        // Empty notes open straight into the editor; others show the rendered preview.
        self.ui = StickerUIState(editing: data.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        super.init(
            contentRect: NSRect(x: data.x, y: data.y, width: data.width, height: data.height),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Hide native chrome but keep titled-window resize behavior (edge/corner
        // hit testing + system cursors). The SwiftUI body draws the visible UI.
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.standardWindowButton(.closeButton)?.isHidden = true
        self.standardWindowButton(.miniaturizeButton)?.isHidden = true
        self.standardWindowButton(.zoomButton)?.isHidden = true

        self.isReleasedWhenClosed = false
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false // SwiftUI provides shadow
        self.minSize = NSSize(width: 160, height: 140)
        applyPinned(data.pinned)

        let id = data.id
        let view = StickerView(
            id: id,
            state: state,
            ui: ui,
            onClose: { onClose(id) },
            onDrag: { [weak self] in
                guard let self, let event = NSApp.currentEvent else { return }
                self.performDrag(with: event)
            },
            onTogglePin: { onTogglePin(id) }
        )
        self.contentView = FirstMouseHostingView(rootView: view)
        installActiveBlurFix(on: self)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    // Keep Liquid Glass `.clear` from desaturating when another app takes
    // focus. Glass reads `isMainWindow` to decide active vs. inactive look.
    override var isMainWindow: Bool { true }

    // Clicking away from a note (another note, the dashboard, another app)
    // drops it back to the rendered Markdown preview.
    override func resignKey() {
        super.resignKey()
        ui.editing = false
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    func applyPinned(_ pinned: Bool) {
        let wasVisible = self.isVisible
        if pinned {
            self.level = .floating
            self.collectionBehavior = [.stationary, .canJoinAllSpaces]
            if wasVisible { self.orderFrontRegardless() }
        } else {
            // Pull the window off whatever space it's currently joining (e.g. a
            // fullscreen app's space) and drop it behind other windows on its
            // home desktop space.
            self.level = .normal
            self.orderOut(nil)
            self.collectionBehavior = [.stationary]
            if wasVisible {
                self.orderBack(nil)
                self.resignKey()
            }
        }
    }

    /// Put a normal sticker behind the other windows on the desktop when the
    /// Stick app loses focus. Pinned stickers intentionally stay floating.
    func moveBehindOtherWindows() {
        guard !isPinnedWindow else { return }
        orderBack(nil)
        resignKey()
    }

    private var isPinnedWindow: Bool {
        level == .floating
    }
}

// NSHostingView subclass that lets clicks reach the SwiftUI gestures even
// when the window is not key — so dragging a sticker by its title bar works
// on the very first mousedown instead of requiring an activation click first.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func layout() {
        super.layout()
        forceActiveVisualEffects(in: self)
        disableSmartSubstitutions(in: self)
    }
}

// Smart dashes/quotes would turn `---` and `|---|` into em dashes and break
// Markdown rules and tables, so the note editor keeps exactly what was typed.
func disableSmartSubstitutions(in view: NSView) {
    if let tv = view as? NSTextView {
        if tv.isAutomaticDashSubstitutionEnabled { tv.isAutomaticDashSubstitutionEnabled = false }
        if tv.isAutomaticQuoteSubstitutionEnabled { tv.isAutomaticQuoteSubstitutionEnabled = false }
    }
    for sub in view.subviews { disableSmartSubstitutions(in: sub) }
}

// Walk subview tree and force every NSVisualEffectView (including those the
// SwiftUI `.glassEffect` hosts) to stay active when the window loses focus.
func forceActiveVisualEffects(in view: NSView) {
    if let ve = view as? NSVisualEffectView {
        ve.state = .active
    }
    for sub in view.subviews { forceActiveVisualEffects(in: sub) }
}

// Window mixin: re-force active state whenever key/main status changes.
func installActiveBlurFix(on window: NSWindow) {
    let nc = NotificationCenter.default
    let apply: (Notification) -> Void = { _ in
        guard let v = window.contentView else { return }
        DispatchQueue.main.async { forceActiveVisualEffects(in: v) }
    }
    for name in [NSWindow.didResignKeyNotification, NSWindow.didResignMainNotification,
                 NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
        nc.addObserver(forName: name, object: window, queue: .main, using: apply)
    }
}

// MARK: - Dashboard

struct DashboardView: View {
    @ObservedObject var state: AppState
    let onNew: () -> Void
    let onFocus: (UUID) -> Void
    let onDelete: (UUID) -> Void
    let onHide: () -> Void
    @State private var hoveredID: UUID? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Stick")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(state.fontColor)
                Spacer()
                Button(action: onHide) {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(state.fontColor.opacity(0.7))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help("Hide dashboard")
                Button(action: onNew) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                        Text("New")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(Color.accentColor)
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().background(Color.primary.opacity(0.15))

            if state.stickers.isEmpty {
                VStack {
                    Spacer()
                    Text("No notes yet.\nTap + New to add one.")
                        .multilineTextAlignment(.center)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundColor(state.fontColor.opacity(0.65))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(state.stickers.enumerated()), id: \.element.id) { idx, s in
                            StickerRow(
                                s: s,
                                state: state,
                                onFocus: { onFocus(s.id) },
                                onDelete: { onDelete(s.id) },
                                onHover: { isHover in
                                    withAnimation(.easeInOut(duration: 0.18)) {
                                        hoveredID = isHover ? s.id : (hoveredID == s.id ? nil : hoveredID)
                                    }
                                }
                            )
                            if idx < state.stickers.count - 1 {
                                let next = state.stickers[idx + 1].id
                                let hidden = hoveredID == s.id || hoveredID == next
                                Rectangle()
                                    .fill(Color.primary.opacity(hidden ? 0 : 0.08))
                                    .frame(height: 0.5)
                                    .padding(.horizontal, 14)
                            }
                        }
                    }
                    .padding(10)
                }
            }

            Divider().background(Color.primary.opacity(0.15))

            SettingsPanel(state: state)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)

            Divider().background(Color.primary.opacity(0.15))

            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                    .foregroundColor(state.fontColor.opacity(0.65))
                Text(Store.shared.url.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(state.fontColor.opacity(0.65))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(Store.shared.url.path)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture {
                NSWorkspace.shared.activateFileViewerSelecting([Store.shared.url])
            }
        }
        .background(FrostedBackground(state: state, cornerRadius: 16))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.25), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 3, x: 0, y: 1)
        .padding(10)
    }
}

struct StickerRow: View {
    let s: StickerData
    @ObservedObject var state: AppState
    let onFocus: () -> Void
    let onDelete: () -> Void
    var onHover: (Bool) -> Void = { _ in }
    @State private var hover = false

    private var preview: String {
        let trimmed = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "(empty)" : trimmed
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color.primary.opacity(0.7)).frame(width: 6, height: 6)
            Text(preview)
                .lineLimit(1)
                .font(.system(size: 12, design: .rounded))
                .foregroundColor(state.fontColor)
            Spacer()
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .foregroundColor(state.fontColor)
                    .padding(4)
            }
            .buttonStyle(.plain)
            .opacity(hover ? 1 : 0)
            .allowsHitTesting(hover)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(hover ? 0.12 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onFocus)
        .onHover { h in
            withAnimation(.easeInOut(duration: 0.18)) { hover = h }
            onHover(h)
        }
    }
}

struct SettingsPanel: View {
    @ObservedObject var state: AppState
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }) {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Appearance")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                    Spacer()
                }
                .foregroundColor(state.fontColor.opacity(0.7))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Group {
                    sectionLabel("Text")
                    sliderRow("textformat.size", Binding(
                        get: { (state.fontSize - 10) / 14 },
                        set: { state.fontSize = 10 + $0 * 14 }
                    ))
                    colorRow(icon: "paintpalette", label: "Font color", selection: $state.fontColor)

                    Divider().padding(.vertical, 4)

                    sectionLabel("Background")
                    Picker("", selection: $state.glassVariant) {
                        Text("Regular").tag(0)
                        Text("Clear").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)

                    if state.glassVariant == 0 {
                        colorRow(icon: "paintbrush", label: "Background color", selection: $state.bgColor)
                        sliderRow("circle.lefthalf.filled", $state.regularBgOpacity)
                    }
                }
                .transition(.opacity)
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundColor(state.fontColor.opacity(0.55))
            .tracking(0.5)
            .padding(.top, 2)
    }

    private func colorRow(icon: String, label: String, selection: Binding<Color>) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(state.fontColor.opacity(0.6))
                .frame(width: 12)
            ColorPicker(label, selection: selection, supportsOpacity: true)
                .labelsHidden()
            Text(label)
                .font(.system(size: 10, design: .rounded))
                .foregroundColor(state.fontColor.opacity(0.65))
            Spacer()
        }
    }

    private func sliderRow(_ icon: String, _ binding: Binding<CGFloat>) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(state.fontColor.opacity(0.6))
                .frame(width: 12)
            Slider(value: Binding(
                get: { Double(binding.wrappedValue) },
                set: { binding.wrappedValue = CGFloat($0) }
            ), in: 0...1)
            .controlSize(.mini)
        }
    }
}

final class DashboardWindow: NSWindow {
    init(rootView: NSView) {
        super.init(
            contentRect: NSRect(x: 100, y: 100, width: 280, height: 360),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        self.isReleasedWhenClosed = false
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.level = .normal
        self.isMovableByWindowBackground = true
        self.collectionBehavior = []
        self.minSize = NSSize(width: 240, height: 240)
        self.contentView = rootView
        installActiveBlurFix(on: self)
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var isMainWindow: Bool { true }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    private var stickerWindows: [UUID: StickerWindow] = [:]
    private var dashboard: DashboardWindow?
    private var statusItem: NSStatusItem!
    private var observers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        installEditMenu()

        // Menu bar
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.image = NSImage(systemSymbolName: "paperclip", accessibilityDescription: "Stick")
            b.image?.isTemplate = true
        }
        let menu = NSMenu()
        let mNew = NSMenuItem(title: "New Note", action: #selector(menuNew), keyEquivalent: "n")
        mNew.target = self
        menu.addItem(mNew)
        let mDash = NSMenuItem(title: "Show / Hide Dashboard", action: #selector(toggleDashboard), keyEquivalent: "d")
        mDash.target = self
        menu.addItem(mDash)
        menu.addItem(.separator())
        let mQuit = NSMenuItem(title: "Quit Stick", action: #selector(menuQuit), keyEquivalent: "q")
        mQuit.target = self
        menu.addItem(mQuit)
        statusItem.menu = menu

        // Load
        state.stickers = Store.shared.load()
        for s in state.stickers { spawnWindow(for: s) }

        // Dashboard
        showDashboard()

        // Keep window frames in sync
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSWindow.didMoveNotification, object: nil, queue: .main) { [weak self] n in
            self?.syncFrame(n)
        })
        observers.append(nc.addObserver(forName: NSWindow.didResizeNotification, object: nil, queue: .main) { [weak self] n in
            self?.syncFrame(n)
        })
        // Reposition color panel next to dashboard whenever it appears.
        observers.append(nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] n in
            guard let panel = n.object as? NSColorPanel, let dash = self?.dashboard else { return }
            let d = dash.frame
            let p = panel.frame
            var x = d.minX - p.width - 8
            if x < 8 { x = d.maxX + 8 }
            let y = max(8, d.maxY - p.height)
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        })
        observers.append(nc.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
            self?.sendStickersToBack()
        })
    }

    func applicationWillTerminate(_ notification: Notification) {
        Store.shared.save(state.stickers)
    }

    @objc func menuNew() { newSticker() }
    @objc func menuQuit() { NSApp.terminate(nil) }

    /// The accessory app has no default application menu. Without an Edit
    /// menu, AppKit does not route the standard Command-X/C/V actions from a
    /// TextEditor through the responder chain.
    private func installEditMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem(title: "Stick", action: nil, keyEquivalent: "")
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Stick", action: #selector(menuQuit), keyEquivalent: "q").target = self
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        NSApp.mainMenu = mainMenu
    }

    @objc func toggleDashboard() {
        if let d = dashboard, d.isVisible {
            d.orderOut(nil)
        } else {
            showDashboard()
        }
    }

    private func showDashboard() {
        if dashboard == nil {
            let host = NSHostingView(rootView: DashboardView(
                state: state,
                onNew: { [weak self] in self?.newSticker() },
                onFocus: { [weak self] id in self?.focusSticker(id) },
                onDelete: { [weak self] id in self?.deleteSticker(id) },
                onHide: { [weak self] in self?.dashboard?.orderOut(nil) }
            ))
            host.frame = NSRect(x: 0, y: 0, width: 280, height: 360)
            host.autoresizingMask = [.width, .height]
            dashboard = DashboardWindow(rootView: host)
            if let screen = NSScreen.main {
                let f = screen.visibleFrame
                dashboard?.setFrameOrigin(NSPoint(x: f.maxX - 300, y: f.maxY - 380))
            }
        }
        dashboard?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    func newSticker() {
        let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 200, y: 200, width: 240, height: 200)
        let s = StickerData(
            id: UUID(),
            text: "",
            x: frame.midX - 120 + CGFloat.random(in: -80...80),
            y: frame.midY - 100 + CGFloat.random(in: -80...80),
            width: 240, height: 200
        )
        state.upsert(s)
        spawnWindow(for: s)
    }

    private func spawnWindow(for s: StickerData) {
        let w = StickerWindow(
            data: s,
            state: state,
            onClose: { [weak self] id in self?.closeStickerWindow(id) },
            onTogglePin: { [weak self] id in self?.togglePin(id) }
        )
        stickerWindows[s.id] = w
        w.orderFrontRegardless()
    }

    private func togglePin(_ id: UUID) {
        guard var s = state.sticker(id) else { return }
        s.pinned.toggle()
        state.upsert(s)
        stickerWindows[id]?.applyPinned(s.pinned)
    }

    private func closeStickerWindow(_ id: UUID) {
        // Respect an explicitly hidden dashboard. Closing a note should not
        // unexpectedly bring the menu window back after the user clicked the
        // eye button.
        let dashboardWasVisible = dashboard?.isVisible == true
        if let w = stickerWindows.removeValue(forKey: id) {
            w.orderOut(nil)
        }
        if dashboardWasVisible {
            showDashboard()
        }
    }

    private func focusSticker(_ id: UUID) {
        if let w = stickerWindows[id] {
            w.orderFrontRegardless()
            w.makeKey()
            return
        }
        guard let s = state.sticker(id) else { return }
        spawnWindow(for: s)
        stickerWindows[id]?.makeKey()
    }

    private func sendStickersToBack() {
        for window in stickerWindows.values {
            window.moveBehindOtherWindows()
        }
    }

    private func deleteSticker(_ id: UUID) {
        if let w = stickerWindows.removeValue(forKey: id) {
            w.orderOut(nil)
            w.close()
        }
        state.remove(id)
    }

    private func syncFrame(_ note: Notification) {
        guard let w = note.object as? StickerWindow else { return }
        guard var s = state.sticker(w.stickerID) else { return }
        let f = w.frame
        s.x = f.origin.x; s.y = f.origin.y
        s.width = f.size.width; s.height = f.size.height
        state.upsert(s)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
