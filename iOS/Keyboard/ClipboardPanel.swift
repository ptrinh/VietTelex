// Panel lịch sử clipboard — phủ vùng phím (dưới thanh gợi ý), mở từ nút 📋 trên
// strip. Chỉ vẽ + báo sự kiện; lưu trữ/ghi nhận ở ClipboardFeature + controller.
import UIKit

final class ClipboardPanel: UIView {
    var onPaste: ((String) -> Void)?
    var onTogglePin: ((String) -> Void)?
    var onDelete: ((String) -> Void)?
    var onClearAll: (() -> Void)?
    var onClose: (() -> Void)?

    /// Bảng tái dùng dòng: chỉ dựng các dòng đang thấy (lịch sử tới 100 mục — dựng hết một lượt
    /// như UIStackView cũ là ~500 view mỗi lần mở / ghim / xoá).
    private let table = UITableView(frame: .zero, style: .plain)
    private enum Row { case note(String, CGFloat), clip(ClipItem) }
    private var rows: [Row] = []
    private var ink: UIColor = .black
    private let header = UIStackView()
    private let titleLabel = UILabel()
    private let clearButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private var dark = false

    /// Ghi chú giới hạn iOS (hiện cuối danh sách / khi trống).
    static var limitNote: String { L("iOS chỉ cho bàn phím đọc clipboard khi bàn phím đang hiện, có Toàn quyền truy cập và đã chọn \"Cho phép dán\". Mục copy lúc bàn phím ẩn được ghi khi bạn mở lại bàn phím (hoặc khi chạm Dán). Lưu chỉ trên máy; mục không ghim tự xoá theo cài đặt Giữ lịch sử clipboard (mặc định 1 giờ).") }

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.text = "Clipboard"
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        clearButton.setTitle(L("Xoá hết"), for: .normal)
        clearButton.titleLabel?.font = .systemFont(ofSize: 15)
        clearButton.addAction(UIAction { [weak self] _ in self?.onClearAll?() }, for: .touchUpInside)
        closeButton.setImage(UIImage(systemName: "keyboard",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .regular)), for: .normal)
        closeButton.accessibilityLabel = L("Đóng clipboard")
        closeButton.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)
        let spacer = UIView()
        header.addArrangedSubview(titleLabel)
        header.addArrangedSubview(spacer)
        header.addArrangedSubview(clearButton)
        header.addArrangedSubview(closeButton)
        header.axis = .horizontal
        header.spacing = 16
        header.alignment = .center
        header.translatesAutoresizingMaskIntoConstraints = false
        closeButton.widthAnchor.constraint(equalToConstant: 36).isActive = true
        addSubview(header)

        table.translatesAutoresizingMaskIntoConstraints = false
        table.dataSource = self
        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.alwaysBounceVertical = true
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 46
        table.sectionHeaderTopPadding = 0
        table.contentInset.bottom = 8
        table.allowsSelection = false
        table.register(ClipCell.self, forCellReuseIdentifier: ClipCell.id)
        table.register(NoteCell.self, forCellReuseIdentifier: NoteCell.id)
        table.disableKeyboardEdgeEffects()
        addSubview(table)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            header.leftAnchor.constraint(equalTo: leftAnchor, constant: 12),
            header.rightAnchor.constraint(equalTo: rightAnchor, constant: -8),
            header.heightAnchor.constraint(equalToConstant: 32),
            table.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            table.leftAnchor.constraint(equalTo: leftAnchor, constant: 8),
            table.rightAnchor.constraint(equalTo: rightAnchor, constant: -8),
            table.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func reload(items: [ClipItem], dark: Bool, incognito: Bool, notice: String? = nil) {
        self.dark = dark
        let ink: UIColor = dark ? .white : .black
        backgroundColor = dark ? UIColor(white: 0.17, alpha: 1) : UIColor(red: 0.82, green: 0.83, blue: 0.86, alpha: 1)
        titleLabel.textColor = ink
        closeButton.tintColor = ink
        clearButton.tintColor = ink
        clearButton.isHidden = !items.contains { !$0.pinned }
        titleLabel.text = incognito ? L("Clipboard · ẩn danh (không lưu)") : "Clipboard"
        self.ink = ink
        var r: [Row] = []
        if let n = notice { r.append(.note(n, 1)) }
        if items.isEmpty { r.append(.note(L("Chưa có mục nào. Copy nội dung rồi mở bàn phím để ghi lại."), 1)) }
        r += items.map(Row.clip)
        r.append(.note(Self.limitNote, 0.55))
        rows = r
        table.reloadData()
        if notice != nil, !rows.isEmpty { table.setContentOffset(.zero, animated: false) }
    }

    #if DEBUG
    /// Test: số dòng của bảng / số ô đang được dựng (dựng theo lúc cuộn ⇒ nhỏ hơn nhiều so với số mục).
    var debugRowCount: Int { rows.count }
    var debugBuiltCellCount: Int { table.layoutIfNeeded(); return table.visibleCells.count }
    func debugClipCell(at row: Int) -> ClipCell? {
        table.layoutIfNeeded()
        return table.cellForRow(at: IndexPath(row: row, section: 0)) as? ClipCell
    }
    #endif
}

extension ClipboardPanel: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch rows[indexPath.row] {
        case let .note(text, alpha):
            let c = tableView.dequeueReusableCell(withIdentifier: NoteCell.id, for: indexPath) as! NoteCell
            c.label.text = text
            c.label.textColor = ink.withAlphaComponent(alpha)
            return c
        case let .clip(item):
            let c = tableView.dequeueReusableCell(withIdentifier: ClipCell.id, for: indexPath) as! ClipCell
            c.configure(item, ink: ink, dark: dark)
            c.onPaste = { [weak self] in self?.onPaste?(item.text) }
            c.onTogglePin = { [weak self] in self?.onTogglePin?(item.text) }
            c.onDelete = { [weak self] in self?.onDelete?(item.text) }
            return c
        }
    }
}

/// Dòng ghi chú (thông báo, "chưa có mục nào", ghi chú giới hạn iOS).
final class NoteCell: UITableViewCell {
    static let id = "note"
    let label = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        label.numberOfLines = 0
        label.font = .systemFont(ofSize: 12)
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -3),
            label.leftAnchor.constraint(equalTo: contentView.leftAnchor),
            label.rightAnchor.constraint(equalTo: contentView.rightAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Một mục clipboard: thẻ bo góc, chạm = dán, nút ghim + xoá. View dựng một lần, tái dùng khi cuộn.
final class ClipCell: UITableViewCell {
    static let id = "clip"
    var onPaste: (() -> Void)?
    var onTogglePin: (() -> Void)?
    var onDelete: (() -> Void)?

    private let card = UIView()
    private let body = UIButton(type: .custom)
    private let pin = UIButton(type: .system)
    private let del = UIButton(type: .system)
    private static let symbol = UIImage.SymbolConfiguration(pointSize: 14, weight: .regular)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        card.layer.cornerRadius = 8
        card.translatesAutoresizingMaskIntoConstraints = false
        body.contentHorizontalAlignment = .left
        body.titleLabel?.numberOfLines = 2
        body.titleLabel?.lineBreakMode = .byTruncatingTail
        body.titleLabel?.font = .systemFont(ofSize: 15)
        body.addAction(UIAction { [weak self] _ in self?.onPaste?() }, for: .touchUpInside)
        pin.addAction(UIAction { [weak self] _ in self?.onTogglePin?() }, for: .touchUpInside)
        del.setImage(UIImage(systemName: "xmark", withConfiguration: Self.symbol), for: .normal)
        del.accessibilityLabel = L("Xoá mục")
        del.addAction(UIAction { [weak self] _ in self?.onDelete?() }, for: .touchUpInside)
        for b in [pin, del] {
            b.widthAnchor.constraint(equalToConstant: 40).isActive = true
            b.heightAnchor.constraint(equalToConstant: 36).isActive = true
        }
        let h = UIStackView(arrangedSubviews: [body, pin, del])
        h.axis = .horizontal
        h.spacing = 4
        h.alignment = .center
        h.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(h)
        contentView.addSubview(card)
        // 999: không cãi với chiều cao tạm (0 / ước lượng) mà bảng đặt cho ô lúc đo.
        let minH = card.heightAnchor.constraint(greaterThanOrEqualToConstant: 40)
        let bottom = card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -3)
        minH.priority = .init(999); bottom.priority = .init(999)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 3),
            bottom,
            card.leftAnchor.constraint(equalTo: contentView.leftAnchor),
            card.rightAnchor.constraint(equalTo: contentView.rightAnchor),
            h.topAnchor.constraint(equalTo: card.topAnchor, constant: 4),
            h.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -4),
            h.leftAnchor.constraint(equalTo: card.leftAnchor, constant: 10),
            h.rightAnchor.constraint(equalTo: card.rightAnchor, constant: -2),
            minH,
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ item: ClipItem, ink: UIColor, dark: Bool) {
        card.backgroundColor = dark ? UIColor(white: 0.42, alpha: 1) : .white
        // Hiện tối đa 2 dòng ⇒ chỉ cần phần đầu (mục dài tới ClipboardHistory.maxTextLength).
        let shown = String(item.text.prefix(300)).replacingOccurrences(of: "\n", with: " ⏎ ")
        body.setTitle(item.sensitive ? String(repeating: "•", count: min(item.text.count, 12)) : shown, for: .normal)
        body.setTitleColor(ink, for: .normal)
        body.accessibilityLabel = item.sensitive ? L("Mục ẩn, chạm để dán") : L("Dán: %@", item.text.prefix(80))
        pin.setImage(UIImage(systemName: item.pinned ? "pin.fill" : "pin", withConfiguration: Self.symbol), for: .normal)
        pin.accessibilityLabel = item.pinned ? L("Bỏ ghim") : "Ghim"
        pin.tintColor = ink.withAlphaComponent(0.7)
        del.tintColor = ink.withAlphaComponent(0.7)
    }

    #if DEBUG
    var debugTitle: String? { body.title(for: .normal) }
    func debugTapPaste() { onPaste?() }
    #endif
}
