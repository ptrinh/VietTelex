/* VietTelex Learn — lesson map, guided-typing player, on-screen keyboard,
 * gamification (stars/XP/streak/badges), two learning tracks, EN/VI UI and
 * Vietnamese TTS. Lesson data: lessons.json, generated from the REAL Swift
 * engine (TelexCore/Sources/GenLessons) so keys never drift from the IME. */
(function () {
'use strict';

// ── Progress store ──────────────────────────────────────────────────────────
var store = load();
function load() {
  var s;
  try { s = JSON.parse(localStorage.getItem('vtlearn') || 'null'); } catch (e) { s = null; }
  if (!s) {
    s = { stars: {}, xp: 0, streak: 0, lastDay: '', badges: [], sound: true, track: null, lang: null };
    var old = parseInt(localStorage.getItem('telex-learn-stars') || '0', 10) || 0;
    s.xp = old * 5; // migrate the v1 star counter
  }
  if (s.track === undefined) s.track = null;
  if (s.autoSpeak === undefined) s.autoSpeak = false;
  if (!s.langChosen) { s.lang = 'vi'; }
  if (!s.lang) s.lang = 'vi';
  return s;
}
function save() { localStorage.setItem('vtlearn', JSON.stringify(store)); }
function today() { return new Date().toISOString().slice(0, 10); }
function bumpStreak() {
  var t = today();
  if (store.lastDay === t) return;
  var y = new Date(Date.now() - 864e5).toISOString().slice(0, 10);
  store.streak = (store.lastDay === y) ? store.streak + 1 : 1;
  store.lastDay = t;
}

// ── i18n ────────────────────────────────────────────────────────────────────
var STR = {
  vi: {
    days: 'ngày', badges: '🏅', enterClass: '🎓 Vào lớp học', backHome: '← Trang chủ',
    map: '← Bản đồ', listen: '🔊 Nghe', dict: '🎧 Nghe rồi gõ', dictOn: '🎧 Đang nghe-gõ',
    fsOn: 'Toàn màn hình', fsOff: 'Thoát toàn màn hình',
    autoSpk: '🗣️ Tự đọc: Tắt', autoSpkOn: '🗣️ Tự đọc: Bật',
    retry: '↻ Làm lại', next: 'Bài tiếp theo →', close: 'Đóng',
    badgeTitle: '🏅 Bộ sưu tập huy hiệu',
    r3: 'Xuất sắc! 🎉', r2: 'Giỏi lắm! 👏', r1: 'Hoàn thành! ✅',
    acc: 'Chính xác', speed: 'Tốc độ',
    noVoice: 'Thiết bị chưa có giọng đọc tiếng Việt 😢',
    infoDone: '📖 +10 XP — đọc xong phần đặt tay, bài kế tiếp đã mở!',
    fingerTo: '→ phím', holdShift: '(giữ ⇧ Shift)', spaceKey: 'DẤU CÁCH', spaceCap: 'dấu cách',
    trackTitle: 'Bạn bắt đầu từ đâu?',
    trackNewT: 'Mình mới học bàn phím',
    trackNewD: 'Học từ tư thế đặt tay, gõ mười ngón, rồi mới đến Telex.',
    trackTypistT: 'Mình gõ được rồi,\nchỉ cần học Telex',
    trackTypistD: 'Vào thẳng chữ đặc biệt và thanh điệu. Hai chương đầu vẫn mở để ôn.',
    trackSwitch: 'Đổi lộ trình',
    optional: 'ôn tập',
    loadFail: 'Không tải được bài học — hãy mở trang qua',
    finger: { f1: 'Ngón út trái', f2: 'Ngón áp út trái', f3: 'Ngón giữa trái', f4: 'Ngón trỏ trái',
              f5: 'Ngón trỏ phải', f6: 'Ngón giữa phải', f7: 'Ngón áp út phải', f8: 'Ngón út phải', th: 'Ngón cái' },
    badgeDefs: {
      first:   ['🐣', 'Bước đầu tiên', 'Hoàn thành bài học đầu tiên'],
      perfect: ['💯', 'Hoàn hảo', 'Đạt 3 sao một bài'],
      tones:   ['🎵', 'Nhạc trưởng', 'Vượt bài "Đủ năm thanh"'],
      c2done:  ['✨', 'Phù thủy chữ', 'Xong chương Chữ đặc biệt'],
      streak3: ['🔥', 'Chăm chỉ', 'Học 3 ngày liên tiếp'],
      streak7: ['🌋', 'Kiên trì', 'Học 7 ngày liên tiếp'],
      xp500:   ['🚀', 'Phi hành gia', 'Đạt 500 XP'],
      boss:    ['🏆', 'Cao thủ Telex', 'Vượt Thử thách cuối']
    }
  },
  en: {
    days: 'day streak', badges: '🏅', enterClass: '🎓 Start learning', backHome: '← Home',
    map: '← Map', listen: '🔊 Listen', dict: '🎧 Listen & type', dictOn: '🎧 Dictation on',
    fsOn: 'Fullscreen', fsOff: 'Exit fullscreen',
    autoSpk: '🗣️ Auto-speak: Off', autoSpkOn: '🗣️ Auto-speak: On',
    retry: '↻ Retry', next: 'Next lesson →', close: 'Close',
    badgeTitle: '🏅 Badge collection',
    r3: 'Excellent! 🎉', r2: 'Great job! 👏', r1: 'Done! ✅',
    acc: 'Accuracy', speed: 'Speed',
    noVoice: 'No Vietnamese voice on this device 😢',
    infoDone: '📖 +10 XP — hand-position guide read, next lesson unlocked!',
    fingerTo: '→ key', holdShift: '(hold ⇧ Shift)', spaceKey: 'SPACE', spaceCap: 'space',
    trackTitle: 'Where do you want to start?',
    trackNewT: 'I’m new to the keyboard',
    trackNewD: 'Start with hand position and touch typing, then learn Telex.',
    trackTypistT: 'I can type —\njust teach me Telex',
    trackTypistD: 'Jump straight to special letters and tones. The first two chapters stay open for review.',
    trackSwitch: 'Switch track',
    optional: 'review',
    loadFail: 'Could not load lessons — open the page via',
    finger: { f1: 'Left pinky', f2: 'Left ring finger', f3: 'Left middle finger', f4: 'Left index finger',
              f5: 'Right index finger', f6: 'Right middle finger', f7: 'Right ring finger', f8: 'Right pinky', th: 'Thumb' },
    badgeDefs: {
      first:   ['🐣', 'First step', 'Finish your first lesson'],
      perfect: ['💯', 'Perfect', 'Get 3 stars on a lesson'],
      tones:   ['🎵', 'Tone master', 'Pass "All five tones"'],
      c2done:  ['✨', 'Letter wizard', 'Finish the Special letters chapter'],
      streak3: ['🔥', 'Dedicated', 'Learn 3 days in a row'],
      streak7: ['🌋', 'Persistent', 'Learn 7 days in a row'],
      xp500:   ['🚀', 'Astronaut', 'Reach 500 XP'],
      boss:    ['🏆', 'Telex master', 'Beat the Final boss']
    }
  }
};
function T() { return STR[store.lang] || STR.vi; }
function lessonTitle(l) { return (store.lang === 'en' && l.titleEN) ? l.titleEN : l.title; }
function lessonIntro(l) { return (store.lang === 'en' && l.introEN) ? l.introEN : l.intro; }
function chapterTitle(c) { return (store.lang === 'en' && c.titleEN) ? c.titleEN : c.title; }

// Static page translation: [selector, {vi, en}] — vi is the authored DOM text.
var STATIC_I18N = [
  ['.hero h1', null, { en: 'Learn Vietnamese <span class="accent">Telex</span> typing' }],
  ['.hero p.sub', null, { en: 'Type without diacritics, get full Vietnamese. Learn from easy to advanced with instant feedback — the exact rule set of the ViệtTelex input method.' }],
  ['#hands h2', null, { en: 'Hand position — touch typing' }],
  ['#hands .lead', null, { en: 'Before the lessons, place your hands right: each finger owns a few keys and returns to the <b>home row</b>. This is the foundation for everything below.' }],
  ['#hoc h2', null, { en: 'The Telex classroom 🎓' }],
  ['#hoc .lead', null, { en: '6 chapters, from meeting the keyboard to full paragraphs. Earn at least ⭐ on a lesson to unlock the next. On a tablet without a keyboard, tap the on-screen keys inside each lesson.' }]
];
var HANDS_EN = [
  ['1️⃣ Find the F and J bumps', 'Feel the keyboard: <b>F</b> and <b>J</b> have small ridges. Rest your index fingers there — no looking! The other fingers sit on <b>A S D</b> (left) and <b>K L ;</b> (right); thumbs hover over the space bar.'],
  ['2️⃣ One finger, one zone', 'The lesson keyboard is coloured by finger: each finger presses its own keys and <b>returns home</b>. Being slow at first is normal — your hands will remember.'],
  ['3️⃣ Eyes on the screen', 'Try not to look down. Lessons always <b>highlight the next key</b> and name the finger, so you never hunt for keys by sight.'],
  ['4️⃣ Sit straight, wrists relaxed', 'Straight back, elbows ~90°, wrists straight and not pressed onto the desk. Rest 5 minutes after every 20.']
];
var staticVi = null;
function applyStaticLang() {
  if (!staticVi) {
    staticVi = STATIC_I18N.map(function (e) { var el = document.querySelector(e[0]); return el ? el.innerHTML : null; });
    staticVi.hands = Array.prototype.map.call(document.querySelectorAll('#hands .hands-note'), function (n) { return n.innerHTML; });
  }
  STATIC_I18N.forEach(function (e, i) {
    var el = document.querySelector(e[0]);
    if (!el || staticVi[i] == null) return;
    el.innerHTML = store.lang === 'en' ? e[2].en : staticVi[i];
  });
  var notes = document.querySelectorAll('#hands .hands-note');
  Array.prototype.forEach.call(notes, function (n, i) {
    if (store.lang === 'en' && HANDS_EN[i]) n.innerHTML = '<h3>' + HANDS_EN[i][0] + '</h3><p>' + HANDS_EN[i][1] + '</p>';
    else if (staticVi.hands && staticVi.hands[i]) n.innerHTML = staticVi.hands[i];
  });
}

// ── Badges ──────────────────────────────────────────────────────────────────
var BADGE_IDS = ['first', 'perfect', 'tones', 'c2done', 'streak3', 'streak7', 'xp500', 'boss'];
function badgeDef(id) { var d = T().badgeDefs[id]; return { id: id, e: d[0], t: d[1], d: d[2] }; }
function award(id, list) {
  if (store.badges.indexOf(id) >= 0) return;
  store.badges.push(id);
  if (list) list.push(badgeDef(id));
}

// ── Sounds (WebAudio, no assets) ────────────────────────────────────────────
var actx = null;
function beep(freq, dur, type, gain) {
  if (!store.sound) return;
  try {
    actx = actx || new (window.AudioContext || window.webkitAudioContext)();
    var o = actx.createOscillator(), g = actx.createGain();
    o.type = type || 'sine'; o.frequency.value = freq;
    g.gain.value = gain || 0.06;
    g.gain.exponentialRampToValueAtTime(0.0001, actx.currentTime + dur);
    o.connect(g); g.connect(actx.destination);
    o.start(); o.stop(actx.currentTime + dur);
  } catch (e) {}
}
var sTick = function () { beep(880, 0.06); };
var sMiss = function () { beep(180, 0.12, 'square', 0.05); };
var sWord = function () { beep(1175, 0.09); };
var sWin  = function () { [523, 659, 784, 1047].forEach(function (f, i) { setTimeout(function () { beep(f, 0.18); }, i * 110); }); };

// ── TTS (Vietnamese voice) ──────────────────────────────────────────────────
var viVoice = null, ttsReady = false;
function pickVoice() {
  var vs = window.speechSynthesis ? speechSynthesis.getVoices() : [];
  viVoice = vs.filter(function (v) { return v.lang && v.lang.toLowerCase().indexOf('vi') === 0; })[0] || null;
  ttsReady = true;
}
if (window.speechSynthesis) { pickVoice(); speechSynthesis.onvoiceschanged = pickVoice; }
function speak(text, rate) {
  if (!window.speechSynthesis) return false;
  if (!ttsReady) pickVoice();
  speechSynthesis.cancel();
  var u = new SpeechSynthesisUtterance(text);
  if (viVoice) u.voice = viVoice;
  u.lang = 'vi-VN';
  u.rate = rate || 0.85;
  speechSynthesis.speak(u);
  return !!viVoice;
}

// ── Keyboard model ──────────────────────────────────────────────────────────
var KB_ROWS = [
  ['q','w','e','r','t','y','u','i','o','p'],
  ['a','s','d','f','g','h','j','k','l',';'],
  ['SHIFT','z','x','c','v','b','n','m',',','.']
];
var FINGER = {};
function fmap(keys, cls) { keys.forEach(function (k) { FINGER[k] = cls; }); }
fmap(['q','a','z'], 'f1'); fmap(['w','s','x'], 'f2'); fmap(['e','d','c'], 'f3');
fmap(['r','f','v','t','g','b'], 'f4'); fmap(['y','h','n','u','j','m'], 'f5');
fmap(['i','k',','], 'f6'); fmap(['o','l','.'], 'f7'); fmap(['p',';','/',"'",'[',']'], 'f8');
var HOME = { a:1, s:1, d:1, f:1, j:1, k:1, l:1, ';':1 };
function fingerName(ch) {
  if (ch === ' ') return T().finger.th;
  var cls = FINGER[ch.toLowerCase()];
  return cls ? T().finger[cls] : '';
}

function buildKeyboard(container, onKey) {
  container.innerHTML = '';
  var keyEls = {};
  var shiftOn = false, shiftEl = null;
  KB_ROWS.forEach(function (row) {
    var r = document.createElement('div'); r.className = 'row';
    row.forEach(function (k) {
      var d = document.createElement('div');
      if (k === 'SHIFT') {
        d.className = 'key wide shift'; d.textContent = '⇧ shift';
        d.addEventListener('pointerdown', function (e) {
          e.preventDefault();
          shiftOn = !shiftOn; d.classList.toggle('on', shiftOn); refreshCaps();
        });
        shiftEl = d; r.appendChild(d); return;
      }
      d.className = 'key ' + (FINGER[k] || '') + (HOME[k] ? ' home' : '');
      d.textContent = k;
      d.dataset.key = k;
      d.addEventListener('pointerdown', function (e) {
        e.preventDefault();
        var ch = shiftOn ? k.toUpperCase() : k;
        if (shiftOn) { shiftOn = false; shiftEl.classList.remove('on'); refreshCaps(); }
        onKey(ch);
      });
      keyEls[k] = d;
      r.appendChild(d);
    });
    container.appendChild(r);
  });
  var r = document.createElement('div'); r.className = 'row';
  var sp = document.createElement('div');
  sp.className = 'key space'; sp.textContent = T().spaceCap; sp.dataset.key = ' ';
  sp.addEventListener('pointerdown', function (e) { e.preventDefault(); onKey(' '); });
  keyEls[' '] = sp; r.appendChild(sp);
  container.appendChild(r);

  function refreshCaps() {
    Object.keys(keyEls).forEach(function (k) {
      if (k.length === 1 && /[a-z]/.test(k)) keyEls[k].textContent = shiftOn ? k.toUpperCase() : k;
    });
  }
  return {
    els: keyEls,
    highlight: function (ch) {
      Object.keys(keyEls).forEach(function (k) { keyEls[k].classList.remove('next'); });
      if (shiftEl) shiftEl.classList.remove('next');
      if (!ch) return;
      var el = keyEls[ch.toLowerCase()];
      if (el) el.classList.add('next');
      if (ch !== ch.toLowerCase() && shiftEl) shiftEl.classList.add('next');
    },
    flash: function (ch, cls) {
      var el = keyEls[(ch || '').toLowerCase()];
      if (!el) return;
      el.classList.add(cls);
      setTimeout(function () { el.classList.remove(cls); }, 180);
    }
  };
}

// ── DOM refs ────────────────────────────────────────────────────────────────
var mapEl = document.getElementById('map');
var playerEl = document.getElementById('player');
var gb = {
  streak: document.getElementById('gbStreak'),
  xp: document.getElementById('gbXp'),
  badges: document.getElementById('gbBadges'),
  sound: document.getElementById('gbSound'),
  lang: document.getElementById('langSel'),
  track: document.getElementById('gbTrack')
};
var DATA = null;
var cur = null;
var kb = null;

// ── Game bar ────────────────────────────────────────────────────────────────
function renderBar() {
  gb.streak.textContent = '🔥 ' + store.streak + ' ' + T().days;
  gb.xp.textContent = '⭐ ' + store.xp + ' XP';
  gb.badges.textContent = '🏅 ' + store.badges.length + '/' + BADGE_IDS.length;
  gb.sound.textContent = store.sound ? '🔊' : '🔇';
  gb.lang.value = store.lang;
  gb.track.textContent = (store.track === 'typist' ? '⚡' : '🐣') + ' ' + T().trackSwitch;
}
gb.sound.addEventListener('click', function () { store.sound = !store.sound; save(); renderBar(); });
gb.lang.addEventListener('change', function () {
  store.lang = gb.lang.value === 'en' ? 'en' : 'vi'; store.langChosen = true; save();
  renderBar(); applyStaticLang();
  if (DATA) renderMap();
  if (cur) { document.getElementById('pTitle').textContent = lessonTitle(cur.lesson);
             document.getElementById('pIntro').textContent = lessonIntro(cur.lesson); renderStep(false); }
});
gb.track.addEventListener('click', function () { showTrackModal(false); });
gb.badges.addEventListener('click', showBadges);

function showBadges() {
  var modal = document.getElementById('badgeModal');
  document.getElementById('badgeTitle').textContent = T().badgeTitle;
  document.getElementById('badgeClose').textContent = T().close;
  var list = document.getElementById('badgeList');
  list.innerHTML = '';
  BADGE_IDS.forEach(function (id) {
    var b = badgeDef(id);
    var got = store.badges.indexOf(id) >= 0;
    var row = document.createElement('div');
    row.className = 'badge-row' + (got ? '' : ' off');
    row.innerHTML = '<span class="be">' + b.e + '</span><span class="bt"><b>' + esc(b.t) + '</b><small>' + esc(b.d) + '</small></span>';
    list.appendChild(row);
  });
  modal.hidden = false;
}
document.getElementById('badgeClose').addEventListener('click', function () {
  document.getElementById('badgeModal').hidden = true;
});

// ── Track selection ─────────────────────────────────────────────────────────
function showTrackModal(firstTime) {
  var m = document.getElementById('trackModal');
  document.getElementById('trackTitle').textContent = T().trackTitle;
  document.getElementById('trackNewT').textContent = T().trackNewT;
  document.getElementById('trackNewD').textContent = T().trackNewD;
  document.getElementById('trackTypistT').textContent = T().trackTypistT;
  document.getElementById('trackTypistD').textContent = T().trackTypistD;
  m.hidden = false;
}
function chooseTrack(t) {
  store.track = t; save();
  document.getElementById('trackModal').hidden = true;
  renderBar(); renderMap();
}
document.getElementById('trackNew').addEventListener('click', function () { chooseTrack('new'); });
document.getElementById('trackTypist').addEventListener('click', function () { chooseTrack('typist'); });

// ── Map / unlock rules ──────────────────────────────────────────────────────
// Track 'new': strictly sequential. Track 'typist': c0+c1 are optional review
// (always open); the required chain starts at c2.
function isReviewChapter(ci) { return store.track === 'typist' && ci <= 1; }
function chapterDone(c) { return c.lessons.every(function (l) { return (store.stars[l.id] || 0) > 0; }); }
function chapterUnlocked(ci) {
  if (ci === 0) return true;
  if (isReviewChapter(ci)) return true;
  if (store.track === 'typist') {
    if (ci === 2) return true;
    return chapterDone(DATA.chapters[ci - 1]);
  }
  return chapterDone(DATA.chapters[ci - 1]);
}
function lessonUnlocked(ci, li) {
  if (!chapterUnlocked(ci)) return false;
  if (isReviewChapter(ci)) return true;   // review chapters: free roam
  if (li === 0) return true;
  var prev = DATA.chapters[ci].lessons[li - 1];
  return (store.stars[prev.id] || 0) > 0;
}
function starStr(n) {
  var out = '';
  for (var i = 1; i <= 3; i++) out += '<span class="' + (i <= n ? 'on' : 'off') + '">★</span>';
  return out;
}
function renderMap() {
  mapEl.innerHTML = '';
  DATA.chapters.forEach(function (ch, ci) {
    var unlocked = chapterUnlocked(ci);
    var doneCount = ch.lessons.filter(function (l) { return (store.stars[l.id] || 0) > 0; }).length;
    var el = document.createElement('div');
    el.className = 'chapter' + (unlocked ? '' : ' locked');
    var head = document.createElement('header');
    var badge = isReviewChapter(ci) ? ' <span class="count">(' + T().optional + ')</span>' : '';
    head.innerHTML = '<span class="icon">' + (unlocked ? ch.icon : '🔒') + '</span><h3>' + esc(chapterTitle(ch)) + badge +
      '</h3><span class="count">' + doneCount + '/' + ch.lessons.length + '</span><span class="chev">▶</span>';
    el.appendChild(head);
    var nodes = document.createElement('div'); nodes.className = 'nodes';
    ch.lessons.forEach(function (l, li) {
      var b = document.createElement('button');
      b.className = 'node' + (l.type === 'test' ? ' test' : '');
      b.disabled = !lessonUnlocked(ci, li);
      b.innerHTML = '<span class="t">' + (l.type === 'test' ? '👑 ' : '') + esc(lessonTitle(l)) + '</span>' +
        '<span class="stars">' + starStr(store.stars[l.id] || 0) + '</span>';
      b.addEventListener('click', function () { openLesson(ci, li); });
      nodes.appendChild(b);
    });
    el.appendChild(nodes);
    head.addEventListener('click', function () { if (unlocked) el.classList.toggle('open'); });
    // auto-open: for typists start at c2, otherwise the first unfinished chapter
    var autoOpen = unlocked && !chapterDone(ch) && !mapEl.querySelector('.chapter.open') &&
                   !(isReviewChapter(ci) && !chapterDone(ch) && ci < 2 && store.track === 'typist');
    if (store.track === 'typist' && ci < 2) autoOpen = false;
    if (autoOpen) el.classList.add('open');
    mapEl.appendChild(el);
  });
}

// ── Player ──────────────────────────────────────────────────────────────────
function openLesson(ci, li) {
  var lesson = DATA.chapters[ci].lessons[li];
  if (lesson.type === 'info') { openInfo(ci, li); return; }
  cur = { ci: ci, li: li, lesson: lesson, itemIdx: 0, keyIdx: 0, phase: 'keys', postIdx: 0,
          correct: 0, wrong: 0, t0: 0, done: false, dictation: false };
  mapEl.hidden = true;
  playerEl.hidden = false;
  document.getElementById('pTitle').textContent = lessonTitle(lesson);
  document.getElementById('pIntro').textContent = lessonIntro(lesson);
  document.getElementById('pBack').textContent = T().map;
  var speakable = lesson.type !== 'drill';   // c0 drills are not Vietnamese sounds
  var sb = document.getElementById('speakBtn');
  sb.style.display = speakable ? '' : 'none';
  sb.textContent = T().listen;
  var db = document.getElementById('dictBtn');
  db.style.display = (speakable && lesson.speak) ? '' : 'none';
  db.classList.remove('on');
  db.textContent = T().dict;
  var ab = document.getElementById('autoSpkBtn');
  ab.style.display = speakable ? '' : 'none';
  refreshAutoSpk();
  document.getElementById('resultBox').hidden = true;
  document.getElementById('playBox').hidden = false;
  kb = buildKeyboard(document.getElementById('kbArea'), handleKey);
  skipAutoPunct();
  renderStep(true);
  playerEl.scrollIntoView({ behavior: 'smooth', block: 'start' });
}

function openInfo(ci, li) {
  var lesson = DATA.chapters[ci].lessons[li];
  document.getElementById('hands').scrollIntoView({ behavior: 'smooth' });
  if (!(store.stars[lesson.id] > 0)) {
    store.stars[lesson.id] = 3;
    store.xp += 10;
    bumpStreak();
    award('first');
    save(); renderBar(); renderMap();
    toast(T().infoDone);
  }
}

function curItem() { return cur.lesson.items[cur.itemIdx]; }
// Punctuation in `post` is auto-inserted — learners only type letters + SPACE.
function skipAutoPunct() {
  var it = curItem();
  if (!it || cur.phase !== 'post') return;
  var post = it.post || '';
  while (cur.postIdx < post.length && post[cur.postIdx] !== ' ') cur.postIdx++;
  if (cur.postIdx >= post.length) advanceItem();
}
function expectedChar() {
  var it = curItem();
  if (!it) return null;
  if (cur.phase === 'keys') return it.k[cur.keyIdx];
  var post = it.post || '';
  return post[cur.postIdx] || null;
}

function renderStep(speakNew) {
  var it = curItem();
  var lesson = cur.lesson;
  document.getElementById('pProg').style.width = (cur.itemIdx / lesson.items.length * 100) + '%';
  var sl = document.getElementById('sentenceLine');
  if (lesson.items.length > 1 && lesson.speak) {
    sl.innerHTML = lesson.items.map(function (item, i) {
      var cls = i < cur.itemIdx ? 'done' : (i === cur.itemIdx ? 'cur' : 'todo');
      var txt = (cur.dictation && cls !== 'done') ? '•'.repeat(Math.max(2, item.d.length)) : item.d;
      return '<span class="' + cls + '">' + esc(txt) + esc((item.post || ' ').trim()) + '</span>';
    }).join(' ');
  } else { sl.innerHTML = ''; }
  var tgt = document.getElementById('pTarget');
  tgt.textContent = it ? (cur.dictation ? '🎧' : it.d) : '';
  var committed = '';
  for (var i = 0; i < cur.itemIdx; i++) committed += lesson.items[i].d + (lesson.items[i].post || '');
  var live = '';
  if (it && cur.phase === 'keys') live = cur.keyIdx > 0 ? it.s[cur.keyIdx - 1] : '';
  else if (it) live = it.d + (it.post || '').slice(0, cur.postIdx);
  document.getElementById('typedLine').innerHTML = esc(committed) + '<span class="cur">' + esc(live) + '</span><span class="caret"></span>';
  var ch = expectedChar();
  kb.highlight(ch);
  var fh = document.getElementById('fingerHint');
  if (ch) {
    var keyName = ch === ' ' ? T().spaceKey : ch;
    fh.innerHTML = esc(fingerName(ch)) + ' ' + T().fingerTo + ' <b>' + esc(keyName) + '</b>' +
      (ch !== ch.toLowerCase() ? ' ' + T().holdShift : '');
  } else fh.textContent = '';
  if (speakNew && it && (cur.dictation || (store.autoSpeak && cur.lesson.type !== 'drill'))) speak(it.d);
}

function handleKey(ch) {
  if (!cur || cur.done) return;
  var exp = expectedChar();
  if (exp == null) return;
  if (!cur.t0) cur.t0 = Date.now();
  if (ch === exp) {
    cur.correct++;
    kb.flash(ch, 'hit'); sTick();
    if (cur.phase === 'keys') {
      cur.keyIdx++;
      if (cur.keyIdx >= curItem().k.length) {
        if (curItem().post) { cur.phase = 'post'; cur.postIdx = 0; skipAutoPunct(); if (cur.done) return; if (cur.phase === 'keys') { renderStep(true); return; } }
        else return advanceAndRender();
      }
    } else {
      cur.postIdx++;
      skipAutoPunct(); if (cur.done) return;
      if (cur.phase === 'keys') { renderStep(true); return; }
      if (cur.postIdx >= (curItem().post || '').length) return advanceAndRender();
    }
    renderStep(false);
  } else {
    cur.wrong++;
    kb.flash(ch, 'miss'); sMiss();
    var tb = document.getElementById('typedLine');
    tb.classList.remove('err'); void tb.offsetWidth; tb.classList.add('err');
  }
}

function advanceItem() {
  cur.itemIdx++; cur.keyIdx = 0; cur.phase = 'keys'; cur.postIdx = 0;
  if (cur.itemIdx >= cur.lesson.items.length) { finishLesson(); return; }
}
function advanceAndRender() {
  sWord();
  advanceItem();
  if (!cur.done) renderStep(true);
}

function finishLesson() {
  if (cur.done) return;
  cur.done = true;
  cur.finishedAt = Date.now();
  var mins = Math.max((Date.now() - cur.t0) / 60000, 0.01);
  var wpm = Math.round(cur.correct / 5 / mins);
  var acc = Math.round(cur.correct / Math.max(cur.correct + cur.wrong, 1) * 100);
  var stars = acc >= 97 ? 3 : acc >= 85 ? 2 : 1;
  if (cur.lesson.type === 'test' && stars === 3 && wpm < 15) stars = 2;
  var prev = store.stars[cur.lesson.id] || 0;
  store.stars[cur.lesson.id] = Math.max(prev, stars);
  var gained = 10 + stars * 10 + (cur.lesson.type === 'test' ? 20 : 0);
  store.xp += gained;
  bumpStreak();
  var newBadges = [];
  award('first', newBadges);
  if (stars === 3) award('perfect', newBadges);
  if (cur.lesson.id === 'c3l7') award('tones', newBadges);
  if (cur.lesson.id === 'c5l3') award('boss', newBadges);
  if (store.xp >= 500) award('xp500', newBadges);
  if (store.streak >= 3) award('streak3', newBadges);
  if (store.streak >= 7) award('streak7', newBadges);
  var c2 = DATA.chapters.filter(function (c) { return c.id === 'c2'; })[0];
  if (c2 && chapterDone(c2)) award('c2done', newBadges);
  save(); renderBar();

  document.getElementById('playBox').hidden = true;
  var rb = document.getElementById('resultBox');
  rb.hidden = false;
  document.getElementById('rStars').innerHTML = starStr(stars);
  document.getElementById('rTitle').textContent = stars === 3 ? T().r3 : stars === 2 ? T().r2 : T().r1;
  document.getElementById('rMetrics').textContent = T().acc + ' ' + acc + '% · ' + T().speed + ' ' + wpm + ' WPM';
  document.getElementById('rGained').textContent = '+' + gained + ' XP';
  document.getElementById('rRetry').textContent = T().retry;
  document.getElementById('rNext').textContent = T().next;
  document.getElementById('rBadges').innerHTML = newBadges.map(function (b) {
    return '<span class="newbadge">' + b.e + ' ' + esc(b.t) + '</span>';
  }).join('');
  sWin();
  confettiBurst();
  document.getElementById('pProg').style.width = '100%';
}

document.getElementById('rRetry').addEventListener('click', function () { openLesson(cur.ci, cur.li); });
document.getElementById('rNext').addEventListener('click', function () {
  var ch = DATA.chapters[cur.ci];
  if (cur.li + 1 < ch.lessons.length) openLesson(cur.ci, cur.li + 1);
  else backToMap();
});
// ── Fullscreen / focus mode ────────────────────────────────────────────────
var fsBtn = document.getElementById('fsBtn');
function focusModeOn() { return document.body.classList.contains('vt-focus'); }
function setFocusMode(on) {
  document.body.classList.toggle('vt-focus', on);
  fsBtn.textContent = on ? '✕' : '⛶';
  fsBtn.title = on ? T().fsOff : T().fsOn;
  if (on) {
    var el = document.documentElement;
    if (el.requestFullscreen) el.requestFullscreen().catch(function () {});
    else if (el.webkitRequestFullscreen) el.webkitRequestFullscreen();
  } else if (document.fullscreenElement || document.webkitFullscreenElement) {
    (document.exitFullscreen || document.webkitExitFullscreen).call(document);
  }
}
fsBtn.addEventListener('click', function () { setFocusMode(!focusModeOn()); });
document.addEventListener('keydown', function (e) {
  if (e.key === 'Escape' && focusModeOn()) setFocusMode(false);
});
document.getElementById('pBack').addEventListener('click', backToMap);
function backToMap() {
  setFocusMode(false);
  playerEl.hidden = true; mapEl.hidden = false;
  cur = null; renderMap();
  mapEl.scrollIntoView({ behavior: 'smooth', block: 'start' });
}

document.getElementById('speakBtn').addEventListener('click', function () {
  if (!cur) return;
  var ok = cur.lesson.speak ? speak(cur.lesson.speak) : (curItem() ? speak(curItem().d) : false);
  if (!ok) toast(T().noVoice);
});
function refreshAutoSpk() {
  var ab = document.getElementById('autoSpkBtn');
  ab.textContent = store.autoSpeak ? T().autoSpkOn : T().autoSpk;
  ab.classList.toggle('on', store.autoSpeak);
}
document.getElementById('autoSpkBtn').addEventListener('click', function () {
  store.autoSpeak = !store.autoSpeak; save();
  refreshAutoSpk();
  if (store.autoSpeak && cur && curItem()) speak(curItem().d);
});
document.getElementById('dictBtn').addEventListener('click', function () {
  if (!cur) return;
  cur.dictation = !cur.dictation;
  this.classList.toggle('on', cur.dictation);
  this.textContent = cur.dictation ? T().dictOn : T().dict;
  renderStep(true);
});

// ── Physical keyboard input (works with iPad hardware keyboards too) ───────
document.addEventListener('keydown', function (e) {
  if (!cur || playerEl.hidden) return;
  if (e.metaKey || e.ctrlKey || e.altKey) return;
  if (cur.done) {
    // result screen: Space/Enter advances to the next lesson (300ms guard so
    // the keystroke that finished the lesson can't double-fire)
    if ((e.key === ' ' || e.key === 'Enter') && Date.now() - (cur.finishedAt || 0) > 300) {
      e.preventDefault();
      document.getElementById('rNext').click();
    }
    return;
  }
  if (e.key === 'Backspace') { e.preventDefault(); return; }
  if (e.key.length !== 1) return;
  e.preventDefault();
  handleKey(e.key);
});

// ── Load data ───────────────────────────────────────────────────────────────
fetch('lessons.json').then(function (r) { return r.json(); }).then(function (d) {
  DATA = d;
  renderBar();
  applyStaticLang();
  renderMap();
  if (!store.track) showTrackModal(true);
}).catch(function () {
  mapEl.innerHTML = '<p style="color:var(--ink-soft)">' + T().loadFail +
    ' <a href="https://ptrinh.github.io/viettelex/learn/">ptrinh.github.io/viettelex/learn</a>.</p>';
});

// ── misc ────────────────────────────────────────────────────────────────────
function esc(s) { return String(s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }
function confettiBurst() {
  if (window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;
  var box = document.getElementById('confetti');
  if (!box) return;
  var colors = ['#c22727', '#d4a94a', '#1f9d63', '#2f6fd0', '#e07b39'];
  for (var i = 0; i < 60; i++) {
    var pc = document.createElement('i');
    pc.style.left = Math.random() * 100 + 'vw';
    pc.style.background = colors[i % colors.length];
    pc.style.animationDelay = (Math.random() * 0.3) + 's';
    pc.style.animationDuration = (1.5 + Math.random() * 0.9) + 's';
    box.appendChild(pc);
    (function (node) { setTimeout(function () { node.remove(); }, 2600); })(pc);
  }
}
function toast(msg) {
  var t = document.createElement('div');
  t.textContent = msg;
  t.style.cssText = 'position:fixed;bottom:24px;left:50%;transform:translateX(-50%);background:var(--navy);color:#fff;padding:12px 22px;border-radius:12px;font-weight:600;z-index:70;box-shadow:0 8px 30px rgba(0,0,0,.25)';
  document.body.appendChild(t);
  setTimeout(function () { t.remove(); }, 2600);
}
})();
