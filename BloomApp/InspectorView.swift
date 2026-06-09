import AppKit
import simd
import BloomCore

/// 右側のインスペクタ。ブラシ設定とレイヤー(NSTableView, D&D 並べ替え可)を持つ。
/// 値の変更はコールバックで CanvasView に伝える。逆に reflect 系で追従する。
final class InspectorView: NSView, NSTableViewDataSource, NSTableViewDelegate {

    var onSelectBrush: ((SimulationEngine.Brush) -> Void)?
    var onSizeChange: ((Float) -> Void)?
    var onWaterChange: ((Float) -> Void)?
    var onStabilizeChange: ((Float) -> Void)? // 手ブレ補正の強さ(グローバル入力設定)
    var onColorChange: ((SIMD3<Float>) -> Void)?
    var onClear: (() -> Void)?

    var onAddLayer: (() -> Void)?
    var onDeleteLayer: ((Int) -> Void)?
    var onSelectLayer: ((Int) -> Void)?
    var onToggleLayer: ((Int) -> Void)?
    var onMoveLayer: ((Int, Int) -> Void)?           // (fromRow, toRow)
    var onSetLayerOpacity: ((Int, Float) -> Void)?   // (row, opacity)

    private static let layerDragType = NSPasteboard.PasteboardType("co.bloom.layer.row")

    private let brushSegmented = NSSegmentedControl(
        labels: ["水彩(藍)", "墨(かすれ)"], trackingMode: .selectOne, target: nil, action: nil
    )
    private let sizeSlider = NSSlider(value: 22, minValue: 4, maxValue: 80, target: nil, action: nil)
    private let waterSlider = NSSlider(value: 0.9, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let stabilizeSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let sizeLabel = InspectorView.makeValueLabel()
    private let waterLabel = InspectorView.makeValueLabel()
    private let stabilizeLabel = InspectorView.makeValueLabel()
    private let colorWell = NSColorWell()

    private let layerTable = NSTableView()
    private let opacitySlider = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let opacityLabel = InspectorView.makeValueLabel()

    private let presets: [SimulationEngine.Brush] = [.watercolor, .sumi]

    // レイヤー状態(表示用キャッシュ)。row 0 = 手前。
    private var layerData: [SimulationEngine.LayerInfo] = []
    private var activeRow = 0
    private var isReflecting = false // プログラム選択時の selectionDidChange ループ抑止

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        build()
        reflect(brush: .watercolor)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - 反映(CanvasView → UI)

    func reflect(brush: SimulationEngine.Brush) {
        brushSegmented.selectedSegment = (brush.name == SimulationEngine.Brush.sumi.name) ? 1 : 0
        sizeSlider.floatValue = brush.baseRadius
        waterSlider.floatValue = brush.water
        sizeLabel.stringValue = "\(Int(brush.baseRadius))"
        waterLabel.stringValue = String(format: "%.2f", brush.water)
        colorWell.color = NSColor(
            srgbRed: CGFloat(brush.color.x), green: CGFloat(brush.color.y),
            blue: CGFloat(brush.color.z), alpha: 1
        )
    }

    func reflectLayers(_ infos: [SimulationEngine.LayerInfo], activeRow: Int) {
        layerData = infos
        self.activeRow = activeRow
        isReflecting = true
        layerTable.reloadData()
        if layerData.indices.contains(activeRow) {
            layerTable.selectRowIndexes([activeRow], byExtendingSelection: false)
            let op = layerData[activeRow].opacity
            opacitySlider.floatValue = op
            opacityLabel.stringValue = String(format: "%.2f", op)
        }
        isReflecting = false
    }

    // MARK: - 組み立て

    private func build() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        // --- ブラシ ---
        stack.addArrangedSubview(Self.makeHeader("ブラシ"))
        brushSegmented.target = self
        brushSegmented.action = #selector(brushChanged)
        brushSegmented.selectedSegment = 0
        stack.addArrangedSubview(brushSegmented)

        let colorRow = NSStackView()
        colorRow.orientation = .horizontal
        colorRow.spacing = 6
        colorWell.target = self
        colorWell.action = #selector(colorChanged)
        colorWell.translatesAutoresizingMaskIntoConstraints = false
        colorWell.widthAnchor.constraint(equalToConstant: 44).isActive = true
        colorWell.heightAnchor.constraint(equalToConstant: 22).isActive = true
        colorRow.addArrangedSubview(Self.makeFieldLabel("色"))
        colorRow.addArrangedSubview(colorWell)
        stack.addArrangedSubview(colorRow)

        stack.addArrangedSubview(Self.makeSliderRow("サイズ", sizeSlider, sizeLabel,
                                                    self, #selector(sizeChanged)))
        stack.addArrangedSubview(Self.makeSliderRow("水量", waterSlider, waterLabel,
                                                    self, #selector(waterChanged)))
        // 手ブレ補正(ブラシ非依存のグローバル入力設定)
        stack.addArrangedSubview(Self.makeSliderRow("手ブレ", stabilizeSlider, stabilizeLabel,
                                                    self, #selector(stabilizeChanged)))
        stabilizeLabel.stringValue = String(format: "%.2f", stabilizeSlider.floatValue)
        stack.addArrangedSubview(Self.makeSeparator())

        // --- レイヤー ---
        let layerHeader = NSStackView()
        layerHeader.orientation = .horizontal
        layerHeader.spacing = 6
        layerHeader.addArrangedSubview(Self.makeHeader("レイヤー"))
        let addButton = NSButton(title: "＋", target: self, action: #selector(addLayerTapped))
        let delButton = NSButton(title: "🗑", target: self, action: #selector(deleteLayerTapped))
        for b in [addButton, delButton] { b.bezelStyle = .rounded; b.controlSize = .small }
        layerHeader.addArrangedSubview(addButton)
        layerHeader.addArrangedSubview(delButton)
        stack.addArrangedSubview(layerHeader)

        stack.addArrangedSubview(makeLayerTable())
        stack.addArrangedSubview(Self.makeSliderRow("不透明", opacitySlider, opacityLabel,
                                                    self, #selector(opacityChanged)))

        stack.addArrangedSubview(Self.makeSeparator())
        let clearButton = NSButton(title: "クリア", target: self, action: #selector(clearTapped))
        clearButton.bezelStyle = .rounded
        stack.addArrangedSubview(clearButton)
    }

    private func makeLayerTable() -> NSView {
        let column = NSTableColumn(identifier: .init("layer"))
        column.width = 190
        layerTable.addTableColumn(column)
        layerTable.headerView = nil
        layerTable.rowHeight = 22
        layerTable.dataSource = self
        layerTable.delegate = self
        layerTable.allowsMultipleSelection = false
        layerTable.style = .plain
        layerTable.registerForDraggedTypes([Self.layerDragType]) // 行の D&D 並べ替え

        let scroll = NSScrollView()
        scroll.documentView = layerTable
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 212).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 108).isActive = true
        return scroll
    }

    // MARK: - NSTableView データ

    func numberOfRows(in tableView: NSTableView) -> Int { layerData.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard layerData.indices.contains(row) else { return nil }
        let info = layerData[row]
        let eye = NSButton(title: info.visible ? "👁" : "✕", target: self, action: #selector(eyeTapped(_:)))
        eye.tag = row
        eye.isBordered = false
        eye.toolTip = "表示/非表示"
        let name = NSTextField(labelWithString: info.name)
        name.font = .systemFont(ofSize: 11, weight: row == activeRow ? .bold : .regular)
        name.textColor = info.visible ? .labelColor : .tertiaryLabelColor
        let rowView = NSStackView(views: [eye, name])
        rowView.orientation = .horizontal
        rowView.spacing = 4
        rowView.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 2)
        return rowView
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isReflecting else { return }
        let row = layerTable.selectedRow
        if row >= 0 { onSelectLayer?(row) }
    }

    // 行の D&D 並べ替え
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString("\(row)", forType: Self.layerDragType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        if op == .on { tableView.setDropRow(row, dropOperation: .above) } // 行間にのみドロップ
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation op: NSTableView.DropOperation) -> Bool {
        guard let item = info.draggingPasteboard.pasteboardItems?.first,
              let str = item.string(forType: Self.layerDragType), let from = Int(str) else { return false }
        onMoveLayer?(from, row)
        return true
    }

    // MARK: - アクション

    @objc private func brushChanged() {
        let brush = presets[brushSegmented.selectedSegment]
        reflect(brush: brush)
        onSelectBrush?(brush)
    }

    @objc private func colorChanged() {
        guard let c = colorWell.color.usingColorSpace(.sRGB) else { return }
        onColorChange?(SIMD3(Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent)))
    }

    @objc private func sizeChanged() {
        sizeLabel.stringValue = "\(Int(sizeSlider.floatValue))"
        onSizeChange?(sizeSlider.floatValue)
    }

    @objc private func waterChanged() {
        waterLabel.stringValue = String(format: "%.2f", waterSlider.floatValue)
        onWaterChange?(waterSlider.floatValue)
    }

    @objc private func stabilizeChanged() {
        stabilizeLabel.stringValue = String(format: "%.2f", stabilizeSlider.floatValue)
        onStabilizeChange?(stabilizeSlider.floatValue)
    }

    @objc private func opacityChanged() {
        opacityLabel.stringValue = String(format: "%.2f", opacitySlider.floatValue)
        onSetLayerOpacity?(activeRow, opacitySlider.floatValue)
    }

    @objc private func addLayerTapped() { onAddLayer?() }
    @objc private func deleteLayerTapped() { onDeleteLayer?(activeRow) }
    @objc private func eyeTapped(_ sender: NSButton) { onToggleLayer?(sender.tag) }
    @objc private func clearTapped() { onClear?() }

    // MARK: - 部品ファクトリ

    private static func makeHeader(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .boldSystemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        return label
    }

    private static func makeFieldLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        return label
    }

    private static func makeValueLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 36).isActive = true
        return label
    }

    private static func makeSliderRow(
        _ title: String, _ slider: NSSlider, _ value: NSTextField,
        _ target: AnyObject, _ action: Selector
    ) -> NSView {
        slider.target = target
        slider.action = action
        slider.controlSize = .small
        let titleLabel = makeFieldLabel(title)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.widthAnchor.constraint(equalToConstant: 36).isActive = true
        let row = NSStackView(views: [titleLabel, slider, value])
        row.orientation = .horizontal
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 212).isActive = true
        return row
    }

    private static func makeSeparator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 212).isActive = true
        return box
    }
}
