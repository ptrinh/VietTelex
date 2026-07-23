// EmojiPlane — bàn phím emoji render theo đúng cấu trúc bàn phím US stock
// (đối chiếu video 2026-07-24): thanh "Search Emoji" trên cùng, lưới emoji lớn
// cuộn NGANG column-major liên tục theo category, hàng dưới
// [ABC][icon 9 category][⌫] với category đang xem được highlight tròn.
// Recents (🕐) lưu App Group, tối đa 30. Search bar hiện là visual placeholder
// (search thật cần vòng riêng — extension phải tự làm ô nhập nội bộ).
import UIKit

final class EmojiPlane: UIView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {

    var onEmoji: ((String) -> Void)?
    var onABC: (() -> Void)?
    var onBackspace: (() -> Void)?

    private var dark = false
    private var sections: [(name: String, emoji: [String])] = []
    private var collection: UICollectionView!
    private var categoryButtons: [UIButton] = []
    private let searchBar = UIView()
    private var repeatTimer: Timer?

    private static let recentsKey = "emojiRecents"
    private static let categoryIcons: [String] = [
        "clock", "face.smiling", "hare", "fork.knife", "soccerball",
        "car.fill", "lightbulb", "heart", "flag",
    ]

    init(dark: Bool) {
        super.init(frame: .zero)
        self.dark = dark
        isMultipleTouchEnabled = true
        reloadSections()
        buildSearchBar()
        buildCollection()
        buildCategoryRow()
    }

    required init?(coder: NSCoder) { fatalError() }

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

    private func buildSearchBar() {
        searchBar.backgroundColor = dark ? UIColor(white: 1, alpha: 0.12)
                                         : UIColor(white: 0, alpha: 0.08)
        searchBar.layer.cornerRadius = 12
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        let icon = UIImageView(image: UIImage(systemName: "magnifyingglass"))
        icon.tintColor = dark ? UIColor(white: 1, alpha: 0.45) : UIColor(white: 0, alpha: 0.4)
        icon.translatesAutoresizingMaskIntoConstraints = false
        let label = UILabel()
        label.text = "Search Emoji"
        label.font = .systemFont(ofSize: 16)
        label.textColor = dark ? UIColor(white: 1, alpha: 0.45) : UIColor(white: 0, alpha: 0.4)
        label.translatesAutoresizingMaskIntoConstraints = false
        searchBar.addSubview(icon)
        searchBar.addSubview(label)
        addSubview(searchBar)
        NSLayoutConstraint.activate([
            searchBar.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            searchBar.leftAnchor.constraint(equalTo: leftAnchor, constant: 10),
            searchBar.rightAnchor.constraint(equalTo: rightAnchor, constant: -10),
            searchBar.heightAnchor.constraint(equalToConstant: 34),
            icon.leftAnchor.constraint(equalTo: searchBar.leftAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            label.leftAnchor.constraint(equalTo: icon.rightAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
        ])
    }

    private func buildCollection() {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal        // column-major như stock
        layout.minimumLineSpacing = 8
        layout.minimumInteritemSpacing = 4
        layout.sectionInset = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collection.backgroundColor = .clear
        collection.showsHorizontalScrollIndicator = false
        collection.dataSource = self
        collection.delegate = self
        collection.register(EmojiCell.self, forCellWithReuseIdentifier: "e")
        collection.translatesAutoresizingMaskIntoConstraints = false
        collection.isMultipleTouchEnabled = true
        addSubview(collection)
        NSLayoutConstraint.activate([
            collection.topAnchor.constraint(equalTo: searchBar.bottomAnchor, constant: 4),
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

    private func jumpToCategory(_ i: Int) {
        guard let s = sectionIndex(forIcon: i), collection.numberOfItems(inSection: s) > 0 else { return }
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
        highlightCategory(iconIndex(forSection: sectionOnScreen()))
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
        // 4 hàng lấp đầy chiều cao — cỡ emoji lớn như stock
        let rows: CGFloat = 4
        let h = (collectionView.bounds.height - 3 * 4) / rows
        return CGSize(width: max(h, 10), height: max(h, 10))
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let e = sections[indexPath.section].emoji[indexPath.item]
        KeyboardView.clickLetter()
        noteUsed(e)
        onEmoji?(e)
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
}
