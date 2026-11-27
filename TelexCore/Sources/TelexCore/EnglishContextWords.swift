// EnglishContextWords.swift — curated set of common English words used ONLY by the
// experimental context-based decision (engine.contextualEnglish). This is SEPARATE
// from EnglishCollisions (which force-restores Telex-colliding words regardless of
// context): this set answers "was the previous word English?" and "is this ambiguous
// word a plausible English word?" so that after an English word, an ambiguous next
// word (composed is valid Vietnamese but the raw keys spell an English word) is
// restored to English — "he is" → "he is" (not "he í"), while "sao í" stays Vietnamese.
//
// Deliberately weighted toward function words (pronouns, auxiliaries, articles,
// prepositions, conjunctions) plus the highest-frequency content words — enough to
// carry English context through a sentence. Curated by hand (not gen-english): most of
// these do NOT collide with Telex, so they never appear in EnglishCollisions, yet they
// are exactly the words that establish an English run. Lowercase, ascii.
//
// FORMAT: các bảng là literal nhiều dòng (từ cách nhau bởi space/newline), split lazily
// ở lần tra đầu tiên — thay cho ~450 phần tử literal, tiết kiệm hàng chục KB
// __TEXT/__DATA. Cùng kiểu với SyllableValidator.rimes. Sửa tay bình thường: chỉ cần
// thêm/bớt từ trong literal, dấu phẩy và dấu ngoặc kép không còn cần thiết.
enum EnglishContextWords {
    static let words: Set<String> = parse(wordList)

    /// RESTORE-ONLY: khôi phục khi ĐANG trong mạch tiếng Anh, nhưng KHÔNG bao giờ mở
    /// mạch. Thán từ / từ chat đứng chung với tiếng Việt rất thường xuyên ("ok cám ơn",
    /// "wow đẹp quá", "hi mọi người") nên nếu chúng seed context thì từ Việt kế tiếp bị
    /// lật sang tiếng Anh (lý do chúng bị gỡ khỏi `words` ngày 2026-07-25). Nhưng khi
    /// mạch tiếng Anh đã mở bởi từ khác thì chính chúng phải giữ nguyên dạng tiếng Anh:
    /// "that's great wow" → wow, không phải "wơ" (field report 2026-07-26, Simple Telex:
    /// `w` literal + `ow` → ơ, và "wơ" lại hợp lệ qua teencode w→qu = "quơ").
    static let restoreOnly: Set<String> = parse(restoreOnlyList)

    /// NEUTRAL loanwords: English words Vietnamese sentences borrow constantly ("gửi
    /// email", "cái app này", "bật wifi"). They must PRESERVE the current context —
    /// neither open an English run (or "email bans" would keep "bans" instead of
    /// composing "bán") nor end one ("the email is" keeps the run "the" opened).
    /// Consulted only for words the classifier would otherwise call English by
    /// STRUCTURE (not a possible VN syllable, not in any dictionary) — the fallback
    /// added for the 2026-08-14 field report ("position is" → "position í": every
    /// unrecognized non-VN word used to default to Vietnamese context).
    static let neutralLoanwords: Set<String> = parse("""
        app apps email mail wifi web blog file files link links game games chat
        team teams fan fans form font menu tab tabs click share live stream
        video videos photo photos camera laptop phone sim online offline admin
        mod spam virus download upload update comment comments post posts story
        feed group groups page pages shop sale size order ship voucher deal
        combo view views like likes sub vlog idol hot top vip pro logo banner
        code demo test server client account profile password login logout
        macos ios windows android linux mac macbook imac iphone ipad ipod
        airpods apple gmail youtube facebook messenger instagram
        tiktok telegram whatsapp viber zalo discord slack zoom chrome
        safari firefox edge excel powerpoint outlook onedrive dropbox
        notion figma canva netflix spotify shopee lazada tiki grab momo
        vnpay viettel vinaphone mobifone samsung xiaomi oppo huawei
        """)

    /// Longest word in the set — lets the caller skip words that can't possibly match.
    static let maxLength = 12

    /// RUN OPENERS — English FUNCTION words (field report 11/10/2026: "suggestion been
    /// treen" came out "suggestion been trên" — the lone English noun "suggestion"
    /// opened a run and "been" was restored, so "bên" was untypeable there).
    /// Vietnamese sentences borrow English CONTENT words all the time (suggestion,
    /// commit, deploy, review, bug, meeting, deadline, feedback…), so ONE content word
    /// must not open an English run. A run opens only when:
    ///   - the previous word is one of THESE function words (pronouns, be/auxiliaries/
    ///     modals, articles/determiners, prepositions, conjunctions, `not`, `there`), or
    ///   - two English words in a row were committed (content + content: "fix bug").
    /// Once open, the run carries through content words ("I fixed the bug in this
    /// file") and a Vietnamese word ends it; neutral loanwords preserve it.
    /// Every entry must ALSO be recognized English (in `words` or EnglishCollisions) —
    /// this set only says which recognized words may open a run on their own.
    /// Deliberately left out:
    ///   - `a` (restore-only, issue #93), `up out off` (Vietnamese verbs: "up ảnh",
    ///     "out nhóm", "off máy"), `done doing` (participles: "done rồi"), and every
    ///     adverb/adjective/noun of `words` (here now just very good time people…).
    static let functionWords: Set<String> = parse("""
        i you he she it we they me him her us them
        my your his its our their mine yours hers ours theirs
        this that these those who whom whose which what
        myself yourself himself herself itself ourselves themselves
        is am are was were be been being
        do does did have has had having
        will would shall should can could may might must
        an the some any every each all both few many much
        several such other another
        of to in on at by for with from into onto over under about
        after before between through during without within
        along across behind beyond upon
        and or but nor so yet if then than because while when where
        why how though although unless until whether since as
        not there
        """)

    /// PREDECESSOR GATES: a word listed here is restored to English inside a run ONLY
    /// when the word IMMEDIATELY before it is one of its predecessors. Otherwise the
    /// Vietnamese composition stands. "been" ⇔ "bên" is the motivating case: English
    /// "been" only ever follows a form of "have" ("has been", "I've been"), while
    /// "bên" is one of the most common Vietnamese words ("bên trên", "bên cạnh").
    /// Format: one rule per line, `word: predecessor predecessor …`. At most 8 rules
    /// (one bit each in the engine's predecessor mask).
    /// `ve` = the tail of "I've"/"we've" — the apostrophe is a word boundary, so the
    /// engine commits "ve" as a word of its own (see `contractionTails`).
    static let predecessorGates: [(word: String, predecessors: Set<String>)] = parseGates("""
        been: have has had having ve
        """)

    /// Contraction tails the apostrophe boundary leaves as words of their own ("I've" →
    /// "I" ' "ve", "you're" → "re", "we'll" → "ll"). "ve"/"re" are ALSO toneless Vietnamese
    /// syllables, which used to END the English run right before the word that needs it
    /// ("I've been"). Neutral: preserve the run, never open one.
    static let contractionTails: Set<String> = parse("""
        ve re ll
        """)

    /// RUN KEEPERS — English words whose Telex reading is a COMMON Vietnamese word (the
    /// suite's `never` rows: box→bõ, car→cả, six→sĩ, max→mã). They are never restored
    /// (that would make the Vietnamese word untypeable), but inside an open English run
    /// they must not END it, or the next function word flips too: "my car is here" came
    /// out "my cả í here", "a mix of both" → "a mĩ ò both". Neutral inside a run only.
    static let runKeepers: Set<String> = parse("""
        arms arts axis bar bars bee beef bees boom bow box burns burst bus car cars
        char charts chef cheers corps cow cows dawn gas keen lawn lee max mix moon
        nor own par parts per queen rams rats reef refer refers reset rest roof room
        roots row rows rust sets sex sir six sofa sorts suns surf tar tax tee teen
        terms texts town tree trust var verse virus war wars
        """)

    /// CODE ACRONYMS — an uppercase run that is one of these is NOT a name's initials
    /// (issue #138 guard): "MaxID", "TaxID", "PosID", "BoxURL" keep the whole-word path
    /// instead of splitting into "MãID"/"TãID". Stored lowercase; matched against the
    /// lowercased trailing run of exactly that length (2–4 letters).
    /// Vetted against Vietnamese name initials (surname + middle-name initials): left
    /// OUT on purpose because they read as real initials — DB (Đỗ/Đặng Bá), PK (Phạm
    /// Khắc/Kim), TS (Trần Sỹ), VM (Võ/Vũ Minh), KB (Kiều Bá), MB (Mai Bá), MS (Mai Sỹ),
    /// PX (Phạm/Phan Xuân), ML (Mai Lệ/Lan). Kept entries start with a letter no common
    /// surname starts with (I, U, J, F, X, E, Q…) or pair letters no name pairs.
    static let codeAcronyms: Set<String> = parse("""
        id ids url uri api ui ux ok ip io os fk sql json xml html css js pdf csv
        uuid guid dto dao gb en vi us uk ai qr nft faq
        """)

    /// CONTRACTION STEMS — the word right before an apostrophe in an English contraction
    /// ("does" n't, "is" n't, "wo" n't, "ca" n't, "there" 's, "I" 'll). When the host tells
    /// the engine the word ends at an apostrophe (`commitBoundary(…, boundary: "'")`), raw
    /// keys on this list — or on it once a final `n` (the n of n't) is dropped — are
    /// committed as typed: "doesn't" stays, never "doén't"; "won't" never "ươn't".
    /// CLOSED list on purpose: a Vietnamese word in single quotes ('tiếng', 'ông') must
    /// keep its diacritics, so only real contraction stems belong here.
    static let contractionStems: Set<String> = parse("""
        do does did is are was were has have had wo ca could should would might must
        need dare sha ai may there here where what who how why when that this it let
        i you we they he she
        """)

    /// ALL-CAPS ACRONYMS that Telex mangles ("ASAP" → ẤP, "WWDC" → WDC): typed in capitals
    /// as 3+ keys, they commit as typed even when the Telex reading is a common syllable
    /// or a cancel. CLOSED list, lowercase: only acronyms with no Vietnamese reading anyone
    /// types in capitals. Deliberately left OUT: "hdd" (HĐ = hợp đồng / hoạt động),
    /// "ddos" (ĐÓ), and every vowel-less đ-abbreviation (HĐND, VĐV, BĐS).
    static let capsAcronyms: Set<String> = parse("""
        asap isp ussr wwdc wwf aapl eeg eek ootd awe
        """)

    private static func parseGates(_ list: String) -> [(word: String, predecessors: Set<String>)] {
        var rules: [(word: String, predecessors: Set<String>)] = []
        for line in list.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let word = parts[0].split(separator: " ").first else { continue }
            let preds = Set(parts[1].split(separator: " ").map(String.init))
            guard !preds.isEmpty else { continue }
            rules.append((String(word), preds))
        }
        precondition(rules.count <= 8, "predecessorGates: at most 8 rules (UInt8 mask)")
        return rules
    }

    /// RETROACTIVE English correction (`TelexEngine.retroactiveEnglish`, EXPERIMENTAL):
    /// coarse English word classes for the plausibility check that decides whether the
    /// Vietnamese compositions right before an English run ("Hí cả í" before "very fast")
    /// read as English ("His car is very fast"). A word may sit in several classes; any
    /// unlisted word is OPEN class (noun/verb/adjective/adverb). Letters = bit order:
    ///   P subject pronoun (bit 0), O object pronoun (1), D determiner/possessive (2),
    ///   B be/auxiliary/modal/not (3), R preposition (4), C conjunction/wh-word (5),
    ///   X (6) = flag, not a class: the word's Vietnamese reading is a very common particle
    ///   ("did" → đi, right after English verbs: "merge đi"), so it is never rewritten
    ///   just because an English word sits on its left.
    /// Pair rules (RetroEnglish.pairAllowed): P → B|open, D → open, R → D|P|O|open,
    /// everything else → anything. Where a rewritten span may START: see RetroEnglish.plan.
    /// Format: one class per line, `X: word word …`. Lowercase ascii.
    static let retroClassList = """
        P: i you he she it we they there who this that these those
        O: me him her us them it you
        D: the a an my your his her its our their this that these those some any every each no all both
        B: is am are was were be been being has have had do does did will would shall should can could may might must not
        R: of in on at to for with from by about into onto over under after before between through during without within along across behind beyond upon as like
        C: and or but nor so yet if then than because while when where why how though although unless until whether since as what which who whom whose that
        X: did
        """

    /// Class bits of `retroClassList` (bit i = i-th line letter), parsed once.
    static let retroClasses: [String: UInt8] = {
        var map: [String: UInt8] = [:]
        for line in retroClassList.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let letter = parts[0].first(where: { $0 != " " }),
                  let bit = RetroEnglish.classLetters.firstIndex(of: letter) else { continue }
            for w in parts[1].split(separator: " ") {
                map[String(w), default: 0] |= UInt8(1) << UInt8(bit)
            }
        }
        return map
    }()

    /// Index of the gate rule for `w`, or nil when `w` is not gated.
    static func gateIndex(of w: String) -> Int? {
        for (i, r) in predecessorGates.enumerated() where r.word == w { return i }
        return nil
    }

    /// Bit i set ⇔ `w` satisfies gate rule i as the immediately preceding word.
    static func predecessorBits(of w: String) -> UInt8 {
        var bits: UInt8 = 0
        for (i, r) in predecessorGates.enumerated() where r.predecessors.contains(w) {
            bits |= UInt8(1) << UInt8(i)
        }
        return bits
    }

    private static func parse(_ list: String) -> Set<String> {
        var set = Set<String>(minimumCapacity: 512)
        for token in list.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
            set.insert(String(token))
        }
        return set
    }

    private static let wordList = [
        // pronouns
        """
        i you he she it we they
        me him her us them
        my your his its our their
        mine yours hers ours theirs
        this that these those
        who whom whose which what
        myself yourself himself herself itself ourselves themselves
        """,
        // be / auxiliaries / common verbs
        """
        is am are was were be been being
        do does did done doing
        have has had having
        will would shall should
        can could may might must
        get gets got go goes going
        make makes made take takes took
        see saw seen know knew want wants
        need needs like likes use uses used
        say says said come comes came
        think thinks look looks find found
        give gives tell work works call calls
        """,
        // articles / determiners / quantifiers
        """
        an the some any every each
        all both half few many much more most
        several enough such other another same
        """,
        // prepositions
        """
        of to in on at by for with from
        into onto up out off over under about
        after before between through during without
        within along across behind beyond upon
        """,
        // conjunctions
        """
        and or but nor so yet if then than
        because while when where why how though
        although unless until whether since as
        """,
        // common adverbs / adjectives / misc.
        // NOTE: interjections / greetings / politeness markers (ok, okay, hi, hello, hey,
        // yes, no, sorry, thanks, thank, please, well, really, maybe) are DELIBERATELY
        // NOT here — Vietnamese speakers open sentences with them ("ok cám ơn", "hi mọi
        // người", "sorry nha"), so seeding an English run from them flips the next
        // Vietnamese word ("ok cám ơn" → "ok cams ơn"). Left out, they fall through to
        // neutral/Vietnamese and never open an English run.
        // `default` — Deffault→Default: the mid-word tone-cancel escape (see shouldRestoreRaw)
        """
        not here there now just only also too very
        default
        back down new old good great big
        small little long high low right left
        next last first one two three
        again always never often still even much
        day time way man men people thing things
        """,
        // Hand-vetted ambiguous English words: each ALSO composes to a Vietnamese
        // syllable (runs→rún, songs→sóng, bans→bán, moms→móm, thus→thú), so they are
        // ONLY flipped to English inside an English run — after a Vietnamese/no-context
        // word they correctly stay Vietnamese. NOT bulk-imported: most collision words
        // hit COMMON Vietnamese (cos→có, sex→sẽ, max→mã) and would corrupt mixed text.
        """
        runs loans songs sons moms cams lens rays vans
        bans tins tans dams hams thus
        """,
        // Broad expansion (user opt-in): the `degrades_vn` rows from telex_test_suite —
        // English words whose Telex reading is a valid (mostly less-common) Vietnamese
        // syllable. Recognized as ambiguous so context can flip them after an English
        // word; alone they stay Vietnamese. The `never` rows (cos→có, sex→sẽ, max→mã,
        // this→thí…) are DELIBERATELY excluded — they collide with COMMON Vietnamese.
        """
        air ais ams ans arm asn asp bangs barn
        beer beest bens best bins bits bons boost boots born
        burn cans caps cast cats chair chans chaos charm
        chens chest chips choes choir chose cons corn cost
        cums cups cuts dans days deer deest dims dist
        docs doms dons dust ems ens eos est gaps gary
        gays hair hangs hans harm hats hays heer heest
        here hero hist hits hoest hongs horn host hungs inf
        ins ira ist its keeps kens kits langs lans laos
        last lats lays leer leest leos lets lips lisa
        list loes loest longs loops lose lost lots luis
        mais mans mary mats mays meest meets mens mere mias
        most must nams neer neest neos nest nons norm
        nuts oer oes oops owns past pest pets pics queens
        queest quest taxi teest term test thais thats theer
        theest there these tims tips tits toer toes toest
        toms tops towns turn ums ups uri urw usa usc
        vary vast vees veest vias visa vons was
        """,
    ].joined(separator: "\n")

    // "a" (issue #93, 25/09/2026): mạo từ tiếng Anh NHƯNG cũng là "a" = anh / "à" rất
    // thường trong chat tiếng Việt ("a còn ở đó không") — mở mạch tiếng Anh từ nó lật
    // từ Việt kế tiếp ("a conf" → "a conf"). Giữ ở lớp restore-only: trong mạch tiếng
    // Anh đã mở ("this is a test") vẫn đúng, nhưng không bao giờ tự mở mạch.
    private static let restoreOnlyList = """
        a
        wow ok okay oh ah aha hey hi hello yay yeah
        yep nope oops ouch hmm huh haha hehe lol omg
        wtf bye sorry thanks thank please welcome congrats
        cool wonderful awesome amazing
        """
}

/// API công khai (bàn phím iOS — gõ vuốt, giai đoạn 3): phân loại MỘT từ đã chốt theo
/// cùng bảng với `contextualEnglish`, để P(ngôn ngữ | từ trước) của decoder vuốt khớp
/// quyết định của engine. Chữ thường ASCII.
public enum EnglishContextLookup {
    /// Từ tiếng Anh thông dụng của bảng ngữ cảnh (the, is, you, people, good…) — nhận
    /// diện NGÔN NGỮ. Từ 11/10/2026 engine chỉ MỞ mạch bằng từ chức năng
    /// (`isFunctionWord`) hoặc hai từ Anh liền nhau; tên giữ nguyên cho caller cũ.
    public static func opensEnglishRun(_ w: String) -> Bool { EnglishContextWords.words.contains(w) }
    /// Từ chức năng tiếng Anh (đại từ, trợ động từ, mạo từ, giới từ, liên từ): một mình
    /// đủ mở mạch tiếng Anh trong engine.
    public static func isFunctionWord(_ w: String) -> Bool {
        EnglishContextWords.functionWords.contains(w)
    }
    /// Từ mượn trung tính (email, app, file…): giữ nguyên mạch hiện tại.
    public static func isNeutralLoanword(_ w: String) -> Bool {
        EnglishContextWords.neutralLoanwords.contains(w)
    }
}
