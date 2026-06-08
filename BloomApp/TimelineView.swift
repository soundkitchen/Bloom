import AppKit

/// 下部のタイムライン帯。フレームの選択・追加/複製/削除、再生、オニオン、fps を持つ。
/// 状態はコールバックで CanvasView 経由エンジンへ。逆に reflect で追従する。
final class TimelineView: NSView {

    var onAddFrame: (() -> Void)?
    var onDuplicateFrame: (() -> Void)?
    var onDeleteFrame: (() -> Void)?
    var onSelectFrame: ((Int) -> Void)?
    var onPrev: (() -> Void)?
    var onNext: (() -> Void)?
    var onPlayToggle: (() -> Void)?
    var onOnionToggle: ((Bool) -> Void)?
    var onFpsChange: ((Double) -> Void)?

    private let playButton = NSButton(title: "▶", target: nil, action: nil)
    private let onionCheck = NSButton(checkboxWithTitle: "オニオン", target: nil, action: nil)
    private let fpsField = NSTextField(string: "12")
    private let counterLabel = NSTextField(labelWithString: "1/1")
    private let framesStack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill() // 上境界線
    }

    /// エンジン状態を反映
    func reflect(frameTotal: Int, current: Int, isPlaying: Bool, onion: Bool) {
        playButton.title = isPlaying ? "⏸" : "▶"
        onionCheck.state = onion ? .on : .off
        counterLabel.stringValue = "\(current + 1)/\(frameTotal)"
        framesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for f in 0..<frameTotal {
            let b = NSButton(title: "\(f + 1)", target: self, action: #selector(frameTapped(_:)))
            b.tag = f
            b.bezelStyle = .smallSquare
            b.setButtonType(.momentaryPushIn)
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 30).isActive = true
            if f == current {
                b.contentTintColor = .controlAccentColor
                b.font = .boldSystemFont(ofSize: 12)
            }
            framesStack.addArrangedSubview(b)
        }
    }

    private func build() {
        let bar = NSStackView()
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.alignment = .centerY
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        func btn(_ title: String, _ action: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .rounded
            return b
        }

        playButton.target = self
        playButton.action = #selector(playTapped)
        playButton.bezelStyle = .rounded
        bar.addArrangedSubview(playButton)
        bar.addArrangedSubview(btn("◀", #selector(prevTapped)))
        bar.addArrangedSubview(btn("▶", #selector(nextTapped)))
        bar.addArrangedSubview(counterLabel)

        // フレームの帯(横スクロール)
        framesStack.orientation = .horizontal
        framesStack.spacing = 3
        let scroll = NSScrollView()
        scroll.documentView = framesStack
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 30).isActive = true
        framesStack.translatesAutoresizingMaskIntoConstraints = false
        framesStack.heightAnchor.constraint(equalTo: scroll.heightAnchor).isActive = true
        bar.addArrangedSubview(scroll)
        scroll.setContentHuggingPriority(.defaultLow, for: .horizontal) // 中央を伸ばす

        bar.addArrangedSubview(btn("＋", #selector(addTapped)))
        bar.addArrangedSubview(btn("⧉", #selector(dupTapped)))
        bar.addArrangedSubview(btn("🗑", #selector(delTapped)))

        onionCheck.target = self
        onionCheck.action = #selector(onionTapped)
        bar.addArrangedSubview(onionCheck)

        bar.addArrangedSubview(NSTextField(labelWithString: "fps"))
        fpsField.target = self
        fpsField.action = #selector(fpsChanged)
        fpsField.alignment = .right
        fpsField.translatesAutoresizingMaskIntoConstraints = false
        fpsField.widthAnchor.constraint(equalToConstant: 40).isActive = true
        bar.addArrangedSubview(fpsField)
    }

    @objc private func frameTapped(_ s: NSButton) { onSelectFrame?(s.tag) }
    @objc private func playTapped() { onPlayToggle?() }
    @objc private func prevTapped() { onPrev?() }
    @objc private func nextTapped() { onNext?() }
    @objc private func addTapped() { onAddFrame?() }
    @objc private func dupTapped() { onDuplicateFrame?() }
    @objc private func delTapped() { onDeleteFrame?() }
    @objc private func onionTapped() { onOnionToggle?(onionCheck.state == .on) }
    @objc private func fpsChanged() { onFpsChange?(max(1, Double(fpsField.doubleValue))) }
}
