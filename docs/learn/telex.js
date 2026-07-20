/* telex.js — faithful JavaScript port of VietTelex's TelexCore engine.
 *
 * Ported 1:1 from TelexCore/Sources/TelexCore/{TelexEngine,Tables,SyllableValidator}.swift
 * so the practice site behaves EXACTLY like the macOS input method. The parse is a
 * pure left-to-right fold over the raw keystrokes, so this port re-parses the whole
 * raw buffer on every key (the Swift engine's `rebuildParseState`, which the file
 * itself documents as semantically identical to the incremental path).
 *
 * Defaults match the app's shipping defaults:
 *   freeMarking=false, modernTone=false, liveSpellCheck=true, simpleTelex=true, autoRestore=true
 */
(function (global) {
  'use strict';

  // ── Tables.swift ───────────────────────────────────────────────────────────

  // Each group: [base(toneless), acute, grave, hook, tilde, dot]. Lower + upper.
  const TONED_GROUPS = [
    'aáàảãạ', 'ăắằẳẵặ', 'âấầẩẫậ', 'eéèẻẽẹ', 'êếềểễệ', 'iíìỉĩị',
    'oóòỏõọ', 'ôốồổỗộ', 'ơớờởỡợ', 'uúùủũụ', 'ưứừửữự', 'yýỳỷỹỵ',
    'AÁÀẢÃẠ', 'ĂẮẰẲẴẶ', 'ÂẤẦẨẪẬ', 'EÉÈẺẼẸ', 'ÊẾỀỂỄỆ', 'IÍÌỈĨỊ',
    'OÓÒỎÕỌ', 'ÔỐỒỔỖỘ', 'ƠỚỜỞỠỢ', 'UÚÙỦŨỤ', 'ƯỨỪỬỮỰ', 'YÝỲỶỸỴ',
  ];

  // toneless (possibly marked) char -> [6 toned chars] indexed by tone.
  const TONED = {};       // char -> array
  const DETONE = {};      // toned char -> { base, tone }  (tone: 0..5)
  for (const group of TONED_GROUPS) {
    const chars = Array.from(group);
    TONED[chars[0]] = chars;
    chars.forEach((c, i) => { DETONE[c] = { base: chars[0], tone: i }; });
  }

  // Tone indices (match Swift Tone.rawValue).
  const T_NONE = 0, T_ACUTE = 1, T_GRAVE = 2, T_HOOK = 3, T_TILDE = 4, T_DOT = 5;

  function toneForKey(c) {
    switch (c) {
      case 's': return T_ACUTE;
      case 'f': return T_GRAVE;
      case 'r': return T_HOOK;
      case 'x': return T_TILDE;
      case 'j': return T_DOT;
      default:  return null;
    }
  }

  // base ascii + mark -> toneless composed char.  mark ∈ none|circumflex|breve|horn|bar
  const MARKED = {
    a: { circumflex: 'â', breve: 'ă' },
    e: { circumflex: 'ê' },
    o: { circumflex: 'ô', horn: 'ơ' },
    u: { horn: 'ư' },
    d: { bar: 'đ' },
  };
  function markedScalar(base, mark, upper) {
    if (mark === 'none') return upper ? base.toUpperCase() : base;
    const m = MARKED[base] && MARKED[base][mark];
    const ch = m || base;
    return upper ? ch.toUpperCase() : ch;
  }
  function applyTone(ch, tone) {
    if (tone === T_NONE) return ch;
    const forms = TONED[ch];
    return forms ? forms[tone] : ch;
  }

  function isVowelAscii(c) { return 'aeiouy'.indexOf(c) >= 0; }

  // ── SyllableValidator.swift ──────────────────────────────────────────────────

  const ONSETS = new Set([
    '', 'b', 'c', 'ch', 'd', 'đ', 'g', 'gh', 'gi', 'h', 'k', 'kh', 'l',
    'm', 'n', 'ng', 'ngh', 'nh', 'p', 'ph', 'qu', 'r', 's', 't', 'th',
    'tr', 'v', 'x', 'z', 'dz',
  ]);

  const RIMES = new Set((`
    a ac ach ai am an ang anh ao ap at au ay
    ă ăc ăm ăn ăng ăp ăt
    â âc âm ân âng âp ât âu ây
    e ec em en eng eo ep et
    ê êch êm ên êng ênh êp êt êu
    i ich im in inh ip it iu ia
    iê iêc iêm iên iêng iêp iêt iêu
    o oc oi om on ong op ot
    oa oac oach oai oam oan oang oanh oao oap oat oay
    oă oăc oăm oăn oăng oăt
    oe oem oen oeo oet
    oo oong ooc
    ô ôc ôi ôm ôn ông ôp ôt
    ơ ơi ơm ơn ơp ơt
    u uc ui um un ung up ut ua
    uâ uân uâng uât uây
    uê uêch uên uênh
    uô uôc uôi uôm uôn uông uôt uơ
    uy uya uych uyn uynh uyt uyu uyên uyêt
    ư ưa ưc ưi ưng ưt ưu
    ươ ươi ươm ươn ương ươp ươt ươu ươc
    y yê yêm yên yêng yêt yêu
  `).trim().split(/\s+/));

  function foldBase(c) {
    switch (c) {
      case 'ă': case 'â': return 'a';
      case 'ê': return 'e';
      case 'ô': case 'ơ': return 'o';
      case 'ư': return 'u';
      case 'đ': return 'd';
      default:  return c;
    }
  }
  const fold = (s) => Array.from(s).map(foldBase).join('');
  function prefixSet(words) {
    const set = new Set();
    for (const w of words) for (let i = 0; i <= w.length; i++) set.add(w.slice(0, i));
    return set;
  }
  const FOLDED_ONSET_COMPLETE = new Set(Array.from(ONSETS).map(fold));
  const FOLDED_RIME_PREFIX = prefixSet(Array.from(RIMES).map(fold));

  // Stop codas (-p -t -c -ch) only allow sắc (´) and nặng (.).
  function toneAllowed(rime, tone) {
    const stop = /(?:ch|[ptc])$/.test(rime);
    if (stop) return tone === T_ACUTE || tone === T_DOT;
    return true;
  }

  // Split onset/rime on a toneless syllable, with qu-/gi- glide handling.
  function splitOnset(toneless) {
    const n = toneless.length;
    let pos = 0;
    while (pos < n && !isVowelAscii(foldBase(toneless[pos]))) pos++;
    let onsetEnd = pos;
    if (pos >= 1 && toneless[0] === 'q' && pos < n && toneless[pos] === 'u' &&
        pos + 1 < n && isVowelAscii(foldBase(toneless[pos + 1]))) {
      onsetEnd = pos + 1;
    } else if (n >= 3 && toneless[0] === 'g' && toneless[1] === 'i' &&
               isVowelAscii(foldBase(toneless[2]))) {
      onsetEnd = 2;
    }
    return onsetEnd;
  }

  function isValidSyllable(word) {
    if (!word) return false;
    let toneless = '';
    let tone = T_NONE;
    for (const ch of word.toLowerCase()) {
      const d = DETONE[ch];
      if (d) {
        toneless += d.base;
        if (d.tone !== T_NONE) {
          if (tone !== T_NONE) return false; // two tones
          tone = d.tone;
        }
      } else {
        toneless += ch;
      }
    }
    // Every char must be a known Vietnamese letter class.
    for (const ch of toneless) {
      if (!/[a-z]/.test(ch) && 'âăêôơưđ'.indexOf(ch) < 0) return false;
    }
    const onsetEnd = splitOnset(toneless);
    const onset = toneless.slice(0, onsetEnd);
    const rime = toneless.slice(onsetEnd);
    return ONSETS.has(onset) && RIMES.has(rime) && toneAllowed(rime, tone);
  }

  // Permissive prefix check (live spell-check). `letters` = array of {base, mark}.
  function isValidPrefix(letters) {
    const n = letters.length;
    if (n === 0) return true;
    const bases = letters.map((l) => l.base);
    const marked = letters.map((l) => l.mark !== 'none');
    let pos = 0;
    while (pos < n && !isVowelAscii(bases[pos])) pos++;
    if (pos === n) { // no vowel yet: partial onset
      return FOLDED_ONSET_COMPLETE.has(bases.join('')) ||
             [...FOLDED_ONSET_COMPLETE].some((o) => o.startsWith(bases.join('')));
    }
    const quAlt = (bases[0] === 'q' && bases[pos] === 'u' && !marked[pos]) ? pos + 1 : -1;
    const giAlt = (bases[0] === 'g' && n >= 2 && bases[1] === 'i') ? 2 : -1;
    for (const start of [pos, quAlt, giAlt]) {
      if (start < 0 || start > n) continue;
      const onset = bases.slice(0, start).join('');
      if (!FOLDED_ONSET_COMPLETE.has(onset)) continue;
      const rime = bases.slice(start).join('');
      if (FOLDED_RIME_PREFIX.has(rime)) return true;
    }
    return false;
  }

  // ── TelexEngine.swift ────────────────────────────────────────────────────────

  class TelexEngine {
    constructor(opts) {
      opts = opts || {};
      this.freeMarking = !!opts.freeMarking;
      this.modernTone = !!opts.modernTone;
      this.liveSpellCheck = opts.liveSpellCheck !== undefined ? !!opts.liveSpellCheck : true;
      this.simpleTelex = opts.simpleTelex !== undefined ? !!opts.simpleTelex : true;
      this.autoRestore = opts.autoRestore !== undefined ? !!opts.autoRestore : true;
      this.reset();
    }

    reset() {
      this.raw = [];              // typed chars (case preserved)
      this.letters = [];          // [{ base, mark, upper }]
      this.tone = T_NONE;
      this.toneKeys = [];         // raw indices of deferred tone/z keys
      this.rawLetter = [];        // raw index -> letter index (or -1)
      this.cancelled = false;
      this.wWord = false;
      this.upperToneKey = false;
      this.disabledAtCount = Infinity;
      this.lastEffTone = T_NONE;
    }

    get isEmpty() { return this.raw.length === 0; }

    feed(ch) {
      if (!/[a-zA-Z]/.test(ch) || ch.length !== 1) return this.composed; // only ascii letters compose
      this.raw.push(ch);
      this._rebuild();
      // Uppercase tone/mark key in a MIXED-case word ("SaaS", "JavaScript") → freeze to raw now.
      if (this.disabledAtCount === Infinity && this.upperToneKey) {
        this.disabledAtCount = 0;
        this._rebuild();
      }
      // Live spell-check: once the word can no longer be Vietnamese, freeze from the NEXT key.
      if (this.liveSpellCheck && this.disabledAtCount === Infinity && !isValidPrefix(this.letters)) {
        this.disabledAtCount = this.raw.length;
      }
      return this.composed;
    }

    // Delete the whole last DISPLAYED character.
    backspace() {
      if (this.raw.length === 0) return null; // nothing of ours; caller deletes natively
      this.disabledAtCount = Infinity;
      this._rebuild();
      this._render(); // maps tone-key provenance onto the toned vowel (Swift parity)
      if (this.letters.length === 0) {
        this.raw.pop();
      } else {
        const last = this.letters.length - 1;
        this.raw = this.raw.filter((_, r) => this.rawLetter[r] !== last);
      }
      this._rebuild();
      return this.composed;
    }

    get composed() { return this._render(); }
    get rawKeystrokes() { return this.raw.join(''); }

    // Final text at a word boundary, auto-restore applied. Does NOT reset.
    commitText() {
      const composed = this.composed;
      if (this.autoRestore && !this.cancelled && composed.length > 0 &&
          (this.upperToneKey || !isValidSyllable(composed))) {
        if (this.rawKeystrokes !== composed) return this.rawKeystrokes;
      }
      return composed;
    }

    // ── parse (left-to-right fold) ──

    _rebuild() {
      this.letters = [];
      this.tone = T_NONE;
      this.toneKeys = [];
      this.cancelled = false;
      this.wWord = false;
      this.upperToneKey = false;
      this.rawLetter = new Array(this.raw.length).fill(-1);
      for (let i = 0; i < this.raw.length; i++) this._parseStep(i);
    }

    _append(base, mark, upper, at) {
      this.letters.push({ base, mark, upper });
      this.rawLetter[at] = this.letters.length - 1;
    }

    _hasVowel() { return this.letters.some((l) => isVowelAscii(l.base)); }
    _hasLowercaseBefore(at) {
      for (let i = 0; i < at; i++) if (this.raw[i] >= 'a' && this.raw[i] <= 'z') return true;
      return false;
    }

    _parseStep(at) {
      const key = this.raw[at];
      const lower = key.toLowerCase();
      const upper = key >= 'A' && key <= 'Z';
      const L = this.letters;

      // Word starting with 'w' is English → literal, no diacritics.
      if (at === 0 && lower === 'w') this.wWord = true;
      if (this.wWord) { this._append(lower, 'none', upper, at); return; }

      // Cancelled diacritic OR live spell-check froze the word → literal from here.
      if (this.cancelled || at >= this.disabledAtCount) {
        this._append(lower, 'none', upper, at); return;
      }

      // Tone keys: s f r x j
      const t = toneForKey(lower);
      if (t !== null) {
        if (this._hasVowel()) {
          if (this.tone === t) {
            this.tone = T_NONE; // double same tone -> cancel, literal
            this.cancelled = true;
            this._append(lower, 'none', upper, at);
          } else {
            this.tone = t;
            if (upper && this._hasLowercaseBefore(at)) this.upperToneKey = true;
            this.rawLetter[at] = -1;
            this.toneKeys.push(at);
          }
        } else {
          this._append(lower, 'none', upper, at);
        }
        return;
      }

      // z: clear tone if there is one; else literal.
      if (lower === 'z') {
        if (this.tone !== T_NONE) {
          this.cancelled = true;
          this.tone = T_NONE;
          if (upper && this._hasLowercaseBefore(at)) this.upperToneKey = true;
          this.rawLetter[at] = -1;
          this.toneKeys.push(at);
        } else {
          this._append('z', 'none', upper, at);
        }
        return;
      }

      // w: breve / horn modifier, or standalone ư.
      if (lower === 'w') {
        let tIdx = -1;
        let k = L.length - 1;
        while (k >= 0) {
          const b = L[k].base;
          if (b === 'a' || b === 'o' || b === 'u') { tIdx = k; break; }
          if (!this.freeMarking && !isVowelAscii(b)) break;
          k--;
        }
        // "ua" nucleus: w horns the u (→ ưa), not breve the a.
        if (tIdx >= 1 &&
            L[tIdx].base === 'a' && L[tIdx].mark === 'none' &&
            L[tIdx - 1].base === 'u' && L[tIdx - 1].mark === 'none' &&
            !(tIdx >= 2 && L[tIdx - 2].base === 'q')) {
          tIdx--;
        }
        if (tIdx >= 0) {
          const p = L[tIdx];
          if (p.mark === 'none' && p.base === 'a') { L[tIdx].mark = 'breve'; this.rawLetter[at] = tIdx; return; }
          if (p.mark === 'none' && (p.base === 'o' || p.base === 'u')) { L[tIdx].mark = 'horn'; this.rawLetter[at] = tIdx; return; }
          if (p.mark === 'breve' && p.base === 'a') {
            L[tIdx].mark = 'none'; this.cancelled = true;
            this._append('w', 'none', upper, at); return;
          }
          if (p.mark === 'horn' && (p.base === 'o' || p.base === 'u')) {
            L[tIdx].mark = 'none'; this.cancelled = true;
            this._append('w', 'none', upper, at); return;
          }
        }
        // Standalone w -> ư (only when the onset can begin a "ư" syllable). Disabled in Simple Telex.
        if (!this.simpleTelex && this._standaloneHornUAllowed()) {
          this._append('u', 'horn', upper, at);
        } else {
          this._append('w', 'none', upper, at);
        }
        return;
      }

      // circumflex doublers: a e o
      if (lower === 'a' || lower === 'e' || lower === 'o') {
        if (L.length > 0) {
          const pIdx = L.length - 1;
          const p = L[pIdx];
          if (p.base === lower && p.mark === 'none') { L[pIdx].mark = 'circumflex'; this.rawLetter[at] = pIdx; return; }
          if (p.base === lower && p.mark === 'circumflex') {
            L[pIdx].mark = 'none'; this.cancelled = true;
            this._append(lower, 'none', upper, at); return;
          }
        }
        // Free mode: reach back over a consonant coda to circumflex an earlier bare same-vowel.
        if (this.freeMarking) {
          let k = L.length - 1;
          while (k >= 0 && !isVowelAscii(L[k].base)) k--;
          if (k >= 0 && L[k].base === lower && L[k].mark === 'none') { L[k].mark = 'circumflex'; this.rawLetter[at] = k; return; }
        }
        this._append(lower, 'none', upper, at); return;
      }

      // d doubler -> đ
      if (lower === 'd') {
        if (L.length > 0) {
          const pIdx = L.length - 1;
          const p = L[pIdx];
          if (p.base === 'd' && p.mark === 'none') { L[pIdx].mark = 'bar'; this.rawLetter[at] = pIdx; return; }
          if (p.base === 'd' && p.mark === 'bar') {
            L[pIdx].mark = 'none'; this.cancelled = true;
            this._append('d', 'none', upper, at); return;
          }
        }
        // A trailing d converts a leading onset d to đ ("dand"->đan).
        if (L.length > 1 && L[0].base === 'd' && L[0].mark === 'none') { L[0].mark = 'bar'; this.rawLetter[at] = 0; return; }
        this._append('d', 'none', upper, at); return;
      }

      // ordinary letter
      this._append(lower, 'none', upper, at);
    }

    _standaloneHornUAllowed() {
      const skeleton = this.letters.map((l) => l.base).join('');
      return ONSETS.has(skeleton) && skeleton !== 'z' && skeleton !== 'dz';
    }

    // ── render (ươ propagation + tone placement) ──

    _render() {
      const count = this.letters.length;
      const R = this.letters.map((l) => ({ base: l.base, mark: l.mark, upper: l.upper }));

      // ươ propagation.
      for (let k = 1; k < count; k++) {
        if (R[k - 1].base !== 'u' || R[k].base !== 'o') continue;
        const prevHorn = R[k - 1].mark === 'horn';
        const curHorn = R[k].mark === 'horn';
        if (prevHorn === curHorn) continue; // exactly one horned
        const oIsLast = (k === count - 1);
        const isQuGlide = (k >= 2 && R[k - 2].base === 'q');
        if (!oIsLast && !isQuGlide) { R[k - 1].mark = 'horn'; R[k].mark = 'horn'; }
      }

      let effTone = this.tone;
      let toneIdx = this.tone === T_NONE ? -1 : this._toneVowelIndex(R, count);
      if (toneIdx >= 0 && (effTone === T_GRAVE || effTone === T_HOOK || effTone === T_TILDE) &&
          this._hasStopCoda(R, count)) {
        effTone = T_NONE; toneIdx = -1;
      }
      // Map deferred tone/z keys onto the toned vowel (or last letter) — Swift render
      // does this so backspace provenance groups the tone key with its vowel.
      const target = toneIdx >= 0 ? toneIdx : Math.max(0, count - 1);
      for (const tk of this.toneKeys) this.rawLetter[tk] = target;
      this.lastEffTone = effTone;

      let out = '';
      for (let k = 0; k < count; k++) {
        const u = R[k];
        let ch = markedScalar(u.base, u.mark, u.upper);
        if (k === toneIdx) ch = applyTone(ch, effTone);
        out += ch;
      }
      return out;
    }

    _hasStopCoda(R, count) {
      if (count === 0) return false;
      const last = R[count - 1].base;
      if (last === 'p' || last === 't' || last === 'c') return true;
      if (last === 'h' && count >= 2 && R[count - 2].base === 'c') return true;
      return false;
    }

    _toneVowelIndex(R, count) {
      let start = 0;
      if (count >= 2 && R[0].base === 'q' && R[1].base === 'u' && R[1].mark === 'none') {
        start = 2;
      } else if (count >= 3 && R[0].base === 'g' && R[1].base === 'i' && R[1].mark === 'none' &&
                 isVowelAscii(R[2].base)) {
        start = 2;
      }
      const vowelIdx = [];
      for (let k = start; k < count; k++) if (isVowelAscii(R[k].base)) vowelIdx.push(k);
      if (vowelIdx.length === 0) {
        for (let k = 0; k < count; k++) if (isVowelAscii(R[k].base)) return k;
        return count - 1;
      }
      // 1) marked vowel takes the tone (last one covers ươ -> ơ).
      let lastMarked = -1;
      for (const idx of vowelIdx) if (R[idx].mark !== 'none') lastMarked = idx;
      if (lastMarked >= 0) return lastMarked;
      // 2) no marked vowel.
      if (vowelIdx.length === 1) return vowelIdx[0];
      const hasCoda = vowelIdx[vowelIdx.length - 1] < (count - 1);
      if (vowelIdx.length === 2) {
        if (hasCoda) return vowelIdx[1];
        if (this.modernTone) {
          const a = R[vowelIdx[0]].base, b = R[vowelIdx[1]].base;
          const glideInitial = (a === 'o' && (b === 'a' || b === 'e')) || (a === 'u' && b === 'y');
          if (glideInitial) return vowelIdx[1];
        }
        return vowelIdx[0];
      }
      return vowelIdx[1]; // 3 vowels: middle
    }
  }

  // Convenience: compose a full raw string (word), auto-restore applied per word boundary
  // on spaces. Used by lessons/hints.
  function transliterate(input, opts) {
    const eng = new TelexEngine(opts);
    let out = '';
    for (const ch of input) {
      if (/[a-zA-Z]/.test(ch)) { eng.feed(ch); }
      else { out += eng.commitText(); eng.reset(); out += ch; }
    }
    out += eng.commitText();
    return out;
  }

  const api = { TelexEngine, transliterate, isValidSyllable, isValidPrefix };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.Telex = api;
})(typeof window !== 'undefined' ? window : globalThis);
