// EmojiPlane — bàn phím emoji render theo đúng cấu trúc bàn phím US stock
// (đối chiếu video 2026-07-24): lưới emoji lớn
// cuộn NGANG column-major liên tục theo category, hàng dưới
// [ABC][icon 9 category][⌫] với category đang xem được highlight tròn.
// Recents (🕐) lưu App Group, tối đa 30. (Search bar đã bỏ — user 2026-07-24.)
import UIKit

final class EmojiPlane: UIView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {

    var onEmoji: ((String) -> Void)?
    var onABC: (() -> Void)?
    var onBackspace: (() -> Void)?

    private var dark = false
    private var sections: [(name: String, emoji: [String])] = []
    private var collection: UICollectionView!
    private var categoryButtons: [UIButton] = []
    private var repeatTimer: Timer?

    private static let recentsKey = "emojiRecents"
    private static let categoryIcons: [String] = [
        "clock", "face.smiling", "hare", "fork.knife", "soccerball",
        "car.fill", "lightbulb", "heart", "flag",
    ]
    // Tiêu đề section nhỏ màu xám phía trên cột đầu của category (như stock).
    private static let headerBand: CGFloat = 14
    private static let displayNames: [String: String] = [
        "recents": "THƯỜNG DÙNG", "smileys": "MẶT CƯỜI & NGƯỜI",
        "animals": "ĐỘNG VẬT & THIÊN NHIÊN", "food": "ĐỒ ĂN & ĐỒ UỐNG",
        "activity": "HOẠT ĐỘNG", "travel": "DU LỊCH & ĐỊA ĐIỂM",
        "objects": "ĐỒ VẬT", "symbols": "BIỂU TƯỢNG", "flags": "CỜ",
    ]

    init(dark: Bool) {
        super.init(frame: .zero)
        self.dark = dark
        isMultipleTouchEnabled = true
        reloadSections()
        buildCollection()
        buildCategoryRow()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { repeatTimer?.invalidate() }

    private var recents: [String] {
        UserDefaultsProvider.shared?.stringArray(forKey: Self.recentsKey) ?? []
    }

    private func reloadSections() {
        var s: [(String, [String])] = []
        let r = recents
        if !r.isEmpty { s.append(("recents", r)) }
        s.append(contentsOf: EmojiData.categories.map { ($0.name, $0.emoji) })
        sections = s
    }

    private func noteUsed(_ e: String) {
        var r = recents.filter { $0 != e }
        r.insert(e, at: 0)
        if r.count > 30 { r.removeLast(r.count - 30) }
        UserDefaultsProvider.shared?.set(r, forKey: Self.recentsKey)
    }

    // MARK: UI

    private func buildCollection() {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal        // column-major như stock
        layout.minimumLineSpacing = 8
        layout.minimumInteritemSpacing = 4
        // dải trống phía trên nhường chỗ cho tiêu đề section
        layout.sectionInset = UIEdgeInsets(top: Self.headerBand, left: 6, bottom: 0, right: 6)
        collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collection.backgroundColor = .clear
        collection.showsHorizontalScrollIndicator = false
        collection.dataSource = self
        collection.delegate = self
        collection.register(EmojiCell.self, forCellWithReuseIdentifier: "e")
        collection.register(HeaderView.self,
                            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
                            withReuseIdentifier: "h")
        collection.translatesAutoresizingMaskIntoConstraints = false
        collection.isMultipleTouchEnabled = true
        addSubview(collection)
        NSLayoutConstraint.activate([
            collection.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            collection.leftAnchor.constraint(equalTo: leftAnchor),
            collection.rightAnchor.constraint(equalTo: rightAnchor),
        ])
    }

    private func buildCategoryRow() {
        let row = UIStackView()
        row.axis = .horizontal
        row.distribution = .fill
        row.alignment = .center
        row.spacing = 2
        row.isLayoutMarginsRelativeArrangement = true
        row.layoutMargins = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false

        let ink: UIColor = dark ? .white : .black
        let abc = UIButton(type: .custom)
        abc.setTitle("ABC", for: .normal)
        abc.setTitleColor(ink, for: .normal)
        abc.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        abc.addAction(UIAction { [weak self] _ in
            KeyboardView.clickModifier()
            self?.onABC?()
        }, for: .touchDown)
        row.addArrangedSubview(abc)
        abc.widthAnchor.constraint(equalToConstant: 44).isActive = true

        let iconsStack = UIStackView()
        iconsStack.axis = .horizontal
        iconsStack.distribution = .fillEqually
        for (i, name) in Self.categoryIcons.enumerated() {
            let b = UIButton(type: .custom)
            b.setImage(UIImage(systemName: name,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)), for: .normal)
            b.tintColor = ink.withAlphaComponent(0.55)
            b.layer.cornerRadius = 13
            b.addAction(UIAction { [weak self] _ in self?.jumpToCategory(i) }, for: .touchUpInside)
            categoryButtons.append(b)
            iconsStack.addArrangedSubview(b)
        }
        row.addArrangedSubview(iconsStack)

        let del = UIButton(type: .custom)
        del.setImage(UIImage(systemName: "delete.left",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 17)), for: .normal)
        del.tintColor = ink
        del.addAction(UIAction { [weak self] _ in
            KeyboardView.clickDelete()
            self?.onBackspace?()
        }, for: .touchDown)
        let long = UILongPressGestureRecognizer(target: self, action: #selector(backspaceHold(_:)))
        long.minimumPressDuration = 0.5
        del.addGestureRecognizer(long)
        row.addArrangedSubview(del)
        del.widthAnchor.constraint(equalToConstant: 44).isActive = true

        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: collection.bottomAnchor, constant: 2),
            row.leftAnchor.constraint(equalTo: leftAnchor),
            row.rightAnchor.constraint(equalTo: rightAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            row.heightAnchor.constraint(equalToConstant: 32),
        ])
        highlightCategory(sectionOnScreen())
    }

    @objc private func backspaceHold(_ g: UILongPressGestureRecognizer) {
        switch g.state {
        case .began:
            repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { [weak self] _ in
                self?.onBackspace?()
            }
        case .ended, .cancelled, .failed:
            repeatTimer?.invalidate(); repeatTimer = nil
        default: break
        }
    }

    // MARK: category nav

    /// Map icon index (0 = recents) → section index thực (recents có thể vắng).
    private func sectionIndex(forIcon i: Int) -> Int? {
        let hasRecents = sections.first?.name == "recents"
        if i == 0 { return hasRecents ? 0 : nil }
        let idx = i - 1 + (hasRecents ? 1 : 0)
        return idx < sections.count ? idx : nil
    }

    private func iconIndex(forSection s: Int) -> Int {
        let hasRecents = sections.first?.name == "recents"
        if hasRecents { return s == 0 ? 0 : s }
        return s + 1
    }

    private var pendingIcon: Int?

    private func jumpToCategory(_ i: Int) {
        guard let s = sectionIndex(forIcon: i), collection.numberOfItems(inSection: s) > 0 else { return }
        // Giữ highlight ở icon vừa bấm: các section cuối (tim, cờ) không thể
        // cuộn tới mép trái (clamp contentSize) nên leftmost-visible sẽ báo
        // section trước đó — scroll callback không được đè trong lúc animate.
        pendingIcon = i
        collection.scrollToItem(at: IndexPath(item: 0, section: s), at: .left, animated: true)
        highlightCategory(i)
    }

    private func sectionOnScreen() -> Int {
        let visible = collection.indexPathsForVisibleItems.sorted()
        return visible.first?.section ?? 0
    }

    private func highlightCategory(_ icon: Int) {
        let ink: UIColor = dark ? .white : .black
        for (i, b) in categoryButtons.enumerated() {
            let on = i == icon
            b.backgroundColor = on ? ink.withAlphaComponent(0.18) : .clear
            b.tintColor = on ? ink : ink.withAlphaComponent(0.55)
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard pendingIcon == nil else { return }
        highlightCategory(iconIndex(forSection: sectionOnScreen()))
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        pendingIcon = nil          // user cuộn tay tiếp thì highlight lại bám theo
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        pendingIcon = nil
    }

    // MARK: collection

    func numberOfSections(in collectionView: UICollectionView) -> Int { sections.count }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        sections[section].emoji.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "e", for: indexPath) as! EmojiCell
        cell.label.text = sections[indexPath.section].emoji[indexPath.item]
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        // 5 hàng như stock; trừ dải tiêu đề section phía trên
        let rows: CGFloat = 5
        let h = (collectionView.bounds.height - Self.headerBand - (rows - 1) * 4) / rows
        return CGSize(width: max(h, 10), height: max(h, 10))
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
                        referenceSizeForHeaderInSection section: Int) -> CGSize {
        // strip dọc mảnh; label không clip nên nổi ngang qua dải headerBand
        CGSize(width: 8, height: 0)
    }

    func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String,
                        at indexPath: IndexPath) -> UICollectionReusableView {
        let v = collectionView.dequeueReusableSupplementaryView(
            ofKind: kind, withReuseIdentifier: "h", for: indexPath) as! HeaderView
        let name = sections[indexPath.section].name
        v.label.text = Self.displayNames[name] ?? name.uppercased()
        v.label.textColor = (dark ? UIColor.white : .black).withAlphaComponent(0.5)
        return v
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let e = sections[indexPath.section].emoji[indexPath.item]
        KeyboardView.clickLetter()
        let hadRecents = sections.first?.name == "recents"
        noteUsed(e)
        onEmoji?(e)
        if !hadRecents {
            // lần dùng đầu tiên trong phiên: section 🕐 xuất hiện ngay,
            // không phải đợi mở lại plane
            reloadSections()
            collection.reloadData()
        }
    }

    private final class EmojiCell: UICollectionViewCell {
        let label = UILabel()
        override init(frame: CGRect) {
            super.init(frame: frame)
            label.font = .systemFont(ofSize: 30)
            label.textAlignment = .center
            label.adjustsFontSizeToFitWidth = true
            label.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(label)
            NSLayoutConstraint.activate([
                label.leftAnchor.constraint(equalTo: contentView.leftAnchor),
                label.rightAnchor.constraint(equalTo: contentView.rightAnchor),
                label.topAnchor.constraint(equalTo: contentView.topAnchor),
                label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            ])
        }
        required init?(coder: NSCoder) { fatalError() }
    }

    private final class HeaderView: UICollectionReusableView {
        let label = UILabel()
        override init(frame: CGRect) {
            super.init(frame: frame)
            clipsToBounds = false          // label rộng hơn strip 8pt — cố ý
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.leftAnchor.constraint(equalTo: leftAnchor, constant: 2),
                label.topAnchor.constraint(equalTo: topAnchor),
            ])
        }
        required init?(coder: NSCoder) { fatalError() }
    }
}
