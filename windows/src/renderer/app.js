// Arayüz mantığı. Mac sürümündeki AppState + ContentView'un karşılığı.
const $ = (id) => document.getElementById(id);
const el = (tag, cls, text) => {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text != null) e.textContent = text;
  return e;
};

const store = {
  get: (k, d) => { try { return JSON.parse(localStorage.getItem(k)) ?? d; } catch { return d; } },
  set: (k, v) => { try { localStorage.setItem(k, JSON.stringify(v)); } catch {} },
};

const state = {
  info: null, fetchedURL: '', fetching: false, toolsReady: false,
  mode: 'video', height: null, container: 'mp4', audioFormat: 'mp3', audioQuality: 192, format: null,
  jobs: new Map(), downloadsDir: '', lastClipboard: '',
  clip: { enabled: false, start: 0, end: 0, stopAt: null, audio: 'none', local: 'none' },   // sadece seçilen aralığı indir
};

// --- Yardımcılar ------------------------------------------------------------------

const qualityLabel = (h) => (h >= 4320 ? '8K' : h >= 2160 ? '4K' : h >= 1440 ? '2K' : `${h}p`);
const lossless = (f) => ['wav', 'flac'].includes(f);
const formatBytes = (b) => {
  if (!b) return '—';
  const u = ['B', 'KB', 'MB', 'GB']; let i = 0;
  while (b >= 1000 && i < u.length - 1) { b /= 1000; i++; }
  return `${b.toFixed(i ? 1 : 0).replace('.', ',')} ${u[i]}`;
};
const formatDuration = (s) => {
  if (s == null) return '';
  s = Math.round(s);
  const h = Math.floor(s / 3600), m = Math.floor(s / 60) % 60, sec = String(s % 60).padStart(2, '0');
  return h ? `${h}:${String(m).padStart(2, '0')}:${sec}` : `${m}:${sec}`;
};
const isSupportedURL = (s) => {
  try {
    const host = new URL(s).hostname.toLowerCase();
    return ['youtube.com', 'youtu.be', 'youtube-nocookie.com', 'twitter.com', 'x.com', 'instagram.com']
      .some((d) => host === d || host.endsWith(`.${d}`));
  } catch { return false; }
};

function chip(title, subtitle, active, onClick) {
  const b = el('button', `chip${active ? ' active' : ''}`);
  b.append(el('b', null, title));
  if (subtitle) b.append(el('small', null, subtitle));
  b.onclick = onClick;
  return b;
}

// --- Bağlantı ---------------------------------------------------------------------

async function fetchInfo() {
  const url = $('url').value.trim();
  if (!url || state.fetching || !state.toolsReady) return;
  state.fetching = true;
  $('fetchError').classList.add('hidden');
  $('loginHint').classList.add('hidden');
  renderURLBar();
  try {
    state.info = await window.api.fetchInfo(url, $('cookies').value);
    state.fetchedURL = url;
    state.format = null;
    if (state.height && !state.info.heights.includes(state.height)) state.height = null;
    resetClip();
  } catch (e) {
    state.info = null;
    const msg = String(e.message || e).replace(/^Error invoking remote method '[^']+': (Error: )?/, '');
    $('fetchError').textContent = msg;
    $('fetchError').classList.remove('hidden');
    if (/login|log in|cookies|rate-limit|private|sign in|authentication/i.test(msg)) {
      $('loginHint').textContent = $('cookies').value
        ? 'Seçili tarayıcıda bu siteye giriş yapmış olduğundan emin ol, ya da başka bir tarayıcı seç.'
        : "Bu içerik giriş gerektiriyor olabilir (Instagram'da sık olur). Alttaki \"Oturum\" menüsünden hesabına giriş yaptığın tarayıcıyı seçip tekrar dene.";
      $('loginHint').classList.remove('hidden');
    }
  }
  state.fetching = false;
  render();
}

function clearURL() {
  $('url').value = '';
  state.info = null;
  state.fetchedURL = '';
  $('fetchError').classList.add('hidden');
  $('loginHint').classList.add('hidden');
  render();
  $('url').focus();
}

async function checkClipboard() {
  const s = (await window.api.readClipboard()).trim();
  if (s === state.lastClipboard) return;
  state.lastClipboard = s;
  if (!isSupportedURL(s) || s === state.fetchedURL || state.fetching) return;
  $('url').value = s;
  fetchInfo();
}

// --- İndirme -----------------------------------------------------------------------

function summary() {
  if (state.mode === 'video') return `${state.height ? qualityLabel(state.height) : 'En iyi'} · ${state.container.toUpperCase()}`;
  if (state.mode === 'audio') return state.audioFormat.toUpperCase() + (lossless(state.audioFormat) ? '' : ` · ${state.audioQuality} kbps`);
  return `Format ${state.format?.id}`;
}

function startDownload() {
  const info = state.info;
  if (!info || (state.mode === 'custom' && !state.format)) return;
  const clip = state.clip.enabled && clipAvailable() ? [state.clip.start, state.clip.end] : null;
  if (clip && clip[1] - clip[0] < 0.5) return;
  const id = crypto.randomUUID();
  const req = {
    url: state.fetchedURL, mode: state.mode, height: state.height, container: state.container,
    audioFormat: state.audioFormat, audioQuality: state.audioQuality, format: state.format,
    cookies: $('cookies').value, dir: state.downloadsDir, clip,
    localCut: !!clip && !!info.dashOnly,   // yalnızca DASH: kesit tam indirilip bilgisayarda kesilir
  };
  state.jobs.set(id, {
    id, title: info.title, thumbnail: info.thumbnail,
    summary: summary() + (info.videoCount > 1 ? ` · ${info.videoCount} video` : '')
      + (clip ? ` · ✂ ${clock(clip[0])}–${clock(clip[1])}` : ''),
    phase: 'starting', progress: 0, detail: 'Başlatılıyor…',
  });
  window.api.startDownload(id, req);
  renderJobs();
}

const isActive = (j) => ['starting', 'downloading', 'processing', 'converting'].includes(j.phase);

// --- Kesim ---------------------------------------------------------------------------

/** "1:23", "1:02:03", "83", "1:23,5" → saniye */
function parseClock(text) {
  const parts = text.trim().replace(/,/g, '.').split(':');
  if (parts.length < 1 || parts.length > 3) return null;
  let total = 0;
  for (const p of parts) {
    const v = Number(p);
    if (p === '' || Number.isNaN(v) || v < 0) return null;
    total = total * 60 + v;
  }
  return total;
}

/** Saniye → "1:23" / "1:02:03"; kesirliyse "1:23,5" */
function clock(s) {
  const whole = Math.floor(s), tenth = Math.round((s - whole) * 10);
  const base = formatDuration(whole);
  return tenth > 0 && tenth < 10 ? `${base},${tenth}` : base;
}

/** Kesim yalnızca süresi bilinen, tek videolu içeriklerde sunulur */
const clipAvailable = () => !!state.info && state.info.videoCount === 1 && (state.info.duration || 0) >= 2;
const video = () => $('clipVideo');

function resetClip() {
  state.clip = { enabled: false, start: 0, end: state.info?.duration || 0, stopAt: null, audio: 'none', local: 'none' };
  $('clipEnabled').checked = false;
  video().pause();
  video().removeAttribute('src');
  delete video().dataset.failed;
  video().load();
  audio().pause();
  audio().removeAttribute('src');
  audio().load();
  window.api.clearPreviewAudio();
}

// --- Yerel önizleme: doğrudan oynatılabilir akış yoksa (ör. yeni bitmiş canlı yayınlar, yalnızca DASH) ---
async function prepareLocalPreview() {
  if (state.clip.local !== 'none') return;
  const forURL = state.fetchedURL;
  state.clip.local = 'preparing';
  $('localPreviewBar').style.width = '0%';
  $('localPreviewText').textContent = 'Önizleme hazırlanıyor…';
  audio().removeAttribute('src');
  state.clip.audio = 'none';
  try {
    const src = await window.api.prepareLocalPreview(forURL, $('cookies').value);
    if (!src || state.fetchedURL !== forURL) return;   // bu arada başka bir video yüklendi
    delete video().dataset.failed;
    video().src = src;
    video().currentTime = state.clip.start;
    state.clip.local = 'ready';
  } catch {
    if (state.fetchedURL === forURL) state.clip.local = 'failed';
  }
  renderClip();
}
window.api.onPreviewProgress((p) => {
  if (state.clip.local !== 'preparing') return;
  $('localPreviewBar').style.width = `${Math.round(p * 100)}%`;
  $('localPreviewText').textContent = `Önizleme hazırlanıyor… %${Math.round(p * 100)}`;
});

// --- Önizleme sesi: akışta ses yoksa ayrıca hazırlanır ve görüntüyle eş zamanlı çalınır ---
const audio = () => $('clipAudio');

async function prepareAudio() {
  if (state.clip.audio !== 'none' || !state.info?.previewNeedsAudio) return;
  const forURL = state.fetchedURL;
  state.clip.audio = 'preparing';
  renderAudioBadge();
  try {
    const src = await window.api.preparePreviewAudio(forURL, $('cookies').value);
    if (!src || state.fetchedURL !== forURL) return;   // bu arada başka bir video yüklendi
    audio().src = src;
    state.clip.audio = 'ready';
    syncAudio(true);
  } catch {
    if (state.fetchedURL === forURL) state.clip.audio = 'failed';
  }
  renderAudioBadge();
}

function renderAudioBadge() {
  const badge = $('audioBadge');
  badge.classList.toggle('hidden', !['preparing', 'failed'].includes(state.clip.audio));
  badge.innerHTML = state.clip.audio === 'preparing' ? '<span class="spinner"></span> Ses hazırlanıyor…' : '🔇 Ses açılamadı';
}

/** Sesi görüntünün konumuna ve oynatma durumuna getirir; oynarken 0,25 sn'den fazla kayarsa yeniden hizalar */
function syncAudio(force = false) {
  if (state.clip.audio !== 'ready') return;
  if (force || Math.abs(audio().currentTime - video().currentTime) > 0.25) audio().currentTime = video().currentTime;
  if (video().paused) audio().pause(); else audio().play().catch(() => {});
}

function seekVideo(t) {
  if (video().src) video().currentTime = t;
  renderTimeline(t);
}

function setClip(start, end) {
  const d = state.info.duration;
  state.clip.start = Math.min(Math.max(0, start), d - 0.5);
  state.clip.end = Math.max(Math.min(d, end), state.clip.start + 0.5);
  renderClip();
}

function renderTimeline(current = video().currentTime || 0) {
  const d = state.info?.duration || 1;
  const pct = (t) => `${(t / d) * 100}%`;
  $('handleStart').style.left = pct(state.clip.start);
  $('handleEnd').style.left = pct(state.clip.end);
  $('clipRange').style.left = pct(state.clip.start);
  $('clipRange').style.width = pct(state.clip.end - state.clip.start);
  $('playhead').style.left = pct(current);
  $('clipNow').textContent = clock(current);
}

function renderClip() {
  const available = clipAvailable();
  $('clipCard').classList.toggle('hidden', !available);
  if (!available) return;
  const on = state.clip.enabled;
  $('clipBody').classList.toggle('hidden', !on);
  if (!on) return;

  // Önce doğrudan akış; yoksa ya da açılmazsa düşük kaliteli sesli bir kopya indirilip oynatılır
  const direct = state.info.preview;
  const directFailed = video().dataset.failed === '1' && state.clip.local === 'none';
  if (direct && !directFailed && state.clip.local === 'none') {
    if (video().getAttribute('src') !== direct) {
      video().src = direct;
      video().currentTime = state.clip.start;
      // Bazı akışlar ne açılır ne hata verir; 10 sn içinde yüklenmezse yerel kopyaya geç
      setTimeout(() => {
        if (video().getAttribute('src') === direct && video().readyState < 1) {
          video().dataset.failed = '1';
          renderClip();
        }
      }, 10000);
    }
    prepareAudio();
  } else if (state.clip.local === 'none') {
    prepareLocalPreview();
  }
  renderAudioBadge();

  const playing = state.clip.local === 'ready' || (direct && !directFailed && state.clip.local === 'none');
  $('player').classList.toggle('hidden', !playing);
  $('localPreviewBox').classList.toggle('hidden', state.clip.local !== 'preparing');
  $('noPreview').classList.toggle('hidden', state.clip.local !== 'failed');
  $('playRange').disabled = !playing;

  if (document.activeElement !== $('clipStart')) $('clipStart').value = clock(state.clip.start);
  if (document.activeElement !== $('clipEnd')) $('clipEnd').value = clock(state.clip.end);
  $('clipSummary').innerHTML = `Seçilen: <b>${clock(state.clip.end - state.clip.start)}</b>  (${clock(state.clip.start)} – ${clock(state.clip.end)})`;
  renderTimeline();
}

// Zaman çizelgesi: tutamaçları sürükle, boş yere tıklayınca oynatıcı oraya gider
function timeAt(clientX) {
  const r = $('timeline').getBoundingClientRect();
  return Math.min(Math.max((clientX - r.left) / r.width, 0), 1) * (state.info?.duration || 0);
}
function drag(target, onMove) {
  target.addEventListener('pointerdown', (e) => {
    e.preventDefault();
    e.stopPropagation();
    target.setPointerCapture(e.pointerId);
    video().pause();
    onMove(timeAt(e.clientX));
    const move = (ev) => onMove(timeAt(ev.clientX));
    const up = () => { target.removeEventListener('pointermove', move); target.removeEventListener('pointerup', up); };
    target.addEventListener('pointermove', move);
    target.addEventListener('pointerup', up);
  });
}
drag($('handleStart'), (t) => { setClip(Math.min(t, state.clip.end - 0.5), state.clip.end); seekVideo(state.clip.start); });
drag($('handleEnd'), (t) => { setClip(state.clip.start, Math.max(t, state.clip.start + 0.5)); seekVideo(state.clip.end); });
drag($('timeline').querySelector('.track'), (t) => seekVideo(t));

$('clipEnabled').onchange = () => { state.clip.enabled = $('clipEnabled').checked; if (!state.clip.enabled) video().pause(); renderClip(); };
for (const [id, which] of [['clipStart', 'start'], ['clipEnd', 'end']]) {
  const commit = () => {
    const v = parseClock($(id).value);
    if (v != null) {
      which === 'start' ? setClip(v, state.clip.end) : setClip(state.clip.start, v);
      seekVideo(state.clip[which]);
    }
    $(id).value = clock(state.clip[which]);
  };
  $(id).addEventListener('change', commit);
  $(id).addEventListener('keydown', (e) => { if (e.key === 'Enter') { commit(); $(id).blur(); } });
}
$('startNow').onclick = () => setClip(Math.min(video().currentTime || 0, state.clip.end - 0.5), state.clip.end);
$('endNow').onclick = () => setClip(state.clip.start, Math.max(video().currentTime || 0, state.clip.start + 0.5));
$('playRange').onclick = () => {
  if (!video().paused) { video().pause(); return; }
  video().currentTime = state.clip.start;
  state.clip.stopAt = state.clip.end;
  video().play();
};
video().addEventListener('timeupdate', () => {
  const t = video().currentTime;
  if (state.clip.stopAt != null && t >= state.clip.stopAt) { video().pause(); video().currentTime = state.clip.stopAt; }
  if (!video().paused) syncAudio();
  renderTimeline(t);
});
video().addEventListener('play', () => { $('playRange').textContent = '❚❚ Durdur'; syncAudio(true); });
video().addEventListener('pause', () => { $('playRange').textContent = '▶ Seçimi oynat'; state.clip.stopAt = null; syncAudio(); });
video().addEventListener('seeked', () => syncAudio(true));
video().addEventListener('waiting', () => audio().pause());
video().addEventListener('playing', () => syncAudio(true));
video().addEventListener('error', () => {
  if (!video().getAttribute('src')) return;
  if (state.clip.local === 'ready') state.clip.local = 'failed';   // yerel kopya da açılamadı
  else video().dataset.failed = '1';                               // doğrudan akış açılamadı → yerel kopyaya geç
  renderClip();
});
video().addEventListener('loadstart', () => { delete video().dataset.failed; });

// --- Çizim --------------------------------------------------------------------------

function renderURLBar() {
  const has = $('url').value.length > 0;
  $('clearBtn').classList.toggle('hidden', !has);
  $('pasteBtn').classList.toggle('hidden', has);
  $('fetchBtn').classList.toggle('hidden', !has);
  $('fetchBtn').disabled = state.fetching || !state.toolsReady;
  $('fetchBtn').innerHTML = state.fetching ? '<span class="spinner"></span>' : 'Getir';
}

function render() {
  renderURLBar();
  const info = state.info;
  $('empty').classList.toggle('hidden', !!info || state.fetching);
  $('details').classList.toggle('hidden', !info);
  if (!info) return;

  $('thumb').src = info.thumbnail || '';
  $('thumb').hidden = !info.thumbnail;
  $('duration').textContent = formatDuration(info.duration);
  $('title').textContent = info.title;
  $('uploader').textContent = info.uploader ? `👤 ${info.uploader}` : '';
  $('best').textContent = info.heights[0] ? `En yüksek kalite: ${qualityLabel(info.heights[0])}` : '';
  const tags = $('tags');
  tags.replaceChildren();
  if (info.platform) tags.append(el('span', 'tag', info.platform));
  if (info.videoCount > 1) tags.append(el('span', 'tag', `${info.videoCount} video · hepsi indirilir`));

  // Mod
  const modes = ['video', 'audio', 'custom'];
  document.querySelectorAll('#modes button').forEach((b) => b.classList.toggle('active', b.dataset.mode === state.mode));
  document.querySelector('.seg-bg').style.transform = `translateX(${modes.indexOf(state.mode) * 100}%)`;
  document.querySelectorAll('[data-panel]').forEach((p) => p.classList.toggle('hidden', p.dataset.panel !== state.mode));

  // Video
  $('heights').replaceChildren(
    chip('En iyi', null, state.height == null, () => { state.height = null; render(); }),
    ...info.heights.map((h) => chip(qualityLabel(h), h > 1080 ? `${h}p` : null, state.height === h, () => { state.height = h; render(); })),
  );
  $('containers').replaceChildren(...[['mp4', 'uyumlu'], ['mkv'], ['webm']].map(([c, sub]) =>
    chip(c.toUpperCase(), sub, state.container === c, () => { state.container = c; render(); })));
  const willConvert = state.container === 'mp4' && (state.height ?? info.heights[0] ?? 0) > 1080;
  $('videoHint').classList.toggle('hidden', !willConvert && state.container === 'mp4');
  $('videoHint').textContent = willConvert
    ? '1080p üstü kaliteler H.264 olarak sunulmuyor. İndirme sonrası H.264\'e çevrilecek (varsa ekran kartı kullanılır); Premiere ve Windows oynatıcıları doğrudan açar.'
    : 'MKV/WEBM dosyaları AV1 veya VP9 içerebilir; Premiere ve bazı oynatıcılar açamayabilir.';

  // Ses
  $('audioFormats').replaceChildren(...['mp3', 'm4a', 'wav', 'flac', 'opus'].map((f) =>
    chip(f.toUpperCase(), lossless(f) ? 'kayıpsız' : null, state.audioFormat === f, () => { state.audioFormat = f; render(); })));
  $('bitrateRow').classList.toggle('hidden', lossless(state.audioFormat));
  $('bitrates').replaceChildren(...[128, 192, 256, 320].map((q) =>
    chip(String(q), 'kbps', state.audioQuality === q, () => { state.audioQuality = q; render(); })));

  // Gelişmiş
  $('formatTable').replaceChildren(...[...info.formats].reverse().map((f) => {
    const row = el('div', `frow${state.format?.id === f.id ? ' active' : ''}`);
    const kind = f.vcodec && f.acodec ? 'Video+Ses' : f.vcodec ? 'Video' : 'Ses';
    const res = f.vcodec && f.height ? `${f.height}p${f.fps ? ` ${Math.round(f.fps)}fps` : ''}` : f.abr ? `${Math.round(f.abr)} kbps` : '—';
    const codecs = [f.vcodec, f.acodec].filter(Boolean).map((c) => c.split('.')[0]).join(' / ');
    row.append(el('span', 'id', f.id), el('span', null, kind), el('span', null, f.ext), el('span', null, res),
      el('span', null, codecs), el('span', null, formatBytes(f.size)));
    row.onclick = () => { state.format = f; render(); };
    return row;
  }));

  $('downloadBtn').disabled = (state.mode === 'custom' && !state.format)
    || (state.clip.enabled && clipAvailable() && state.clip.end - state.clip.start < 0.5);
  renderClip();
}

function renderJobs() {
  const jobs = [...state.jobs.values()].reverse();
  $('jobsSection').classList.toggle('hidden', !jobs.length);
  $('clearJobs').classList.toggle('hidden', !jobs.some((j) => !isActive(j)));
  $('jobs').replaceChildren(...jobs.map((j) => {
    const row = el('div', `job ${j.phase}`);
    const thumb = el('div', 'jthumb');
    if (j.thumbnail) { const img = el('img'); img.src = j.thumbnail; thumb.append(img); }
    const badges = { done: '✓', failed: '!', cancelled: '✕' };
    if (badges[j.phase]) thumb.append(el('span', `badge ${j.phase}`, badges[j.phase]));

    const body = el('div', 'body');
    const line = el('div', 'line');
    line.append(el('span', 'summary', j.summary), el('span', 'detail', j.detail));
    body.append(el('div', 'jtitle', j.title), line);
    if (isActive(j)) {
      const bar = el('div', `progress${j.phase === 'processing' || j.indeterminate ? ' indeterminate' : ''}`);
      const fill = el('div');
      fill.style.width = `${Math.max(2, j.progress * 100)}%`;
      bar.append(fill);
      body.append(bar);
    }

    const actions = el('div', 'actions');
    const btn = (text, title, fn) => { const b = el('button', 'round', text); b.title = title; b.onclick = fn; return b; };
    if (isActive(j)) {
      actions.append(btn('✕', 'İptal', () => window.api.cancel(j.id)));
    } else {
      if (j.phase === 'done' && j.file) {
        actions.append(btn('▶', 'Aç', () => window.api.openFile(j.file)),
                       btn('📂', 'Klasörde göster', () => window.api.reveal(j.file)));
      }
      actions.append(btn('🗑', 'Listeden kaldır', () => { state.jobs.delete(j.id); window.api.forget(j.id); renderJobs(); }));
    }
    row.append(thumb, body, actions);
    return row;
  }));
}

function renderFooter() {
  $('folderPath').textContent = state.downloadsDir;
  $('folderBtn').title = state.downloadsDir;
}

// --- Başlangıç ------------------------------------------------------------------------

async function init() {
  const { brand, platform, downloadsDir } = await window.api.init();
  document.title = brand.appName;
  $('appName').textContent = brand.appName;
  $('tagline').textContent = brand.tagline;
  $('helpFooter').textContent = brand.helpFooter;
  $('url').placeholder = brand.urlPlaceholder;
  document.querySelectorAll('.appName').forEach((n) => { n.textContent = brand.appName; });
  const root = document.documentElement.style;
  root.setProperty('--accent', `#${brand.accent}`);
  root.setProperty('--accent-dark', `#${brand.accentDark}`);
  root.setProperty('--title-width', `${brand.titleWidth}%`);
  document.body.classList.add(platform);

  state.downloadsDir = store.get('downloadsDir', downloadsDir);
  $('cookies').value = store.get('cookies', '');
  renderFooter();
  render();

  try {
    $('updateBtn').textContent = `⟳ yt-dlp ${await window.api.prepareTools()}`;
    state.toolsReady = true;
  } catch (e) {
    $('toolMsg').textContent = `Araçlar hazırlanamadı: ${e.message}`;
  }
  render();
  if (!new URLSearchParams(location.search).has('noclipboard')) checkClipboard();
}

$('urlForm').onsubmit = (e) => { e.preventDefault(); fetchInfo(); };
$('url').oninput = renderURLBar;
$('clearBtn').onclick = clearURL;
$('pasteBtn').onclick = async () => { $('url').value = (await window.api.readClipboard()).trim(); fetchInfo(); };
$('downloadBtn').onclick = startDownload;
document.querySelectorAll('#modes button').forEach((b) => { b.onclick = () => { state.mode = b.dataset.mode; render(); }; });
$('clearJobs').onclick = () => {
  for (const [id, j] of state.jobs) if (!isActive(j)) { state.jobs.delete(id); window.api.forget(id); }
  renderJobs();
};
$('folderBtn').onclick = () => window.api.openFolder(state.downloadsDir);
$('changeFolder').onclick = async () => {
  const dir = await window.api.chooseFolder(state.downloadsDir);
  if (dir) { state.downloadsDir = dir; store.set('downloadsDir', dir); renderFooter(); }
};
$('cookies').onchange = () => store.set('cookies', $('cookies').value);
$('updateBtn').onclick = async () => {
  if (!state.toolsReady) return;
  $('toolMsg').textContent = 'Güncelleniyor…';
  try {
    const before = $('updateBtn').textContent.replace('⟳ yt-dlp ', '');
    const v = await window.api.updateTools();
    $('updateBtn').textContent = `⟳ yt-dlp ${v}`;
    $('toolMsg').textContent = v === before ? 'yt-dlp zaten güncel' : `yt-dlp ${v} sürümüne güncellendi`;
  } catch (e) {
    $('toolMsg').textContent = String(e.message || e).replace(/^Error invoking remote method '[^']+': (Error: )?/, '');
  }
};
document.addEventListener('keydown', (e) => {
  if ((e.ctrlKey || e.metaKey) && e.key === 'Enter' && !$('details').classList.contains('hidden')) startDownload();
});

// Nasıl Kullanılır
const HELP_AUTO = ['YouTube', 'X (Twitter)', 'Instagram'];
const HELP_OTHER = ['TikTok', 'Facebook', 'Vimeo', 'Reddit', 'Twitch', 'Dailymotion', 'SoundCloud', 'Bandcamp',
  'Bluesky', 'LinkedIn', 'Pinterest', 'Tumblr', 'Streamable', 'Kick', 'Rumble', 'Bilibili'];
const SUPPORTED_SITES = 'https://github.com/yt-dlp/yt-dlp/blob/master/supportedsites.md';
$('autoPlatforms').replaceChildren(...HELP_AUTO.map((p) => el('span', 'ptag auto', p)));
$('otherPlatforms').replaceChildren(...HELP_OTHER.map((p) => el('span', 'ptag', p)));
$('sitesLink').onclick = (e) => { e.preventDefault(); window.api.openExternal(SUPPORTED_SITES); };
const showHelp = (show) => $('help').classList.toggle('hidden', !show);
$('helpBtn').onclick = () => showHelp(true);
$('helpClose').onclick = () => showHelp(false);
$('help').onclick = (e) => { if (e.target === $('help')) showHelp(false); };
document.addEventListener('keydown', (e) => {
  if (e.key === 'F1') { e.preventDefault(); showHelp(true); }
  if (e.key === 'Escape') showHelp(false);
});

// Sürükle-bırak
document.addEventListener('dragover', (e) => { e.preventDefault(); document.body.classList.add('dragging'); });
document.addEventListener('dragleave', (e) => { if (!e.relatedTarget) document.body.classList.remove('dragging'); });
document.addEventListener('drop', (e) => {
  e.preventDefault();
  document.body.classList.remove('dragging');
  const text = e.dataTransfer.getData('text/uri-list') || e.dataTransfer.getData('text/plain');
  if (text) { $('url').value = text.split('\n')[0].trim(); fetchInfo(); }
});

window.api.onJobUpdate((s) => {
  const job = state.jobs.get(s.id);
  if (!job) return;
  Object.assign(job, s);
  renderJobs();
});
window.api.onFocus(() => { if (!new URLSearchParams(location.search).has('noclipboard')) checkClipboard(); });

// Geliştirme: ekran görüntüsü için örnek veri (--demo)
window.__demo = () => {
  state.toolsReady = true;
  $('url').value = 'https://www.youtube.com/watch?v=örnek';
  state.fetchedURL = $('url').value;
  state.info = {
    title: 'Örnek video başlığı: arayüz önizlemesi', uploader: 'Örnek Kanal', duration: 754, thumbnail: '',
    platform: 'YouTube', videoCount: 1, heights: [2160, 1440, 1080, 720, 480, 360],
    formats: [{ id: '137', ext: 'mp4', height: 1080, fps: 30, vcodec: 'avc1.640028', size: 52_000_000 },
              { id: '140', ext: 'm4a', acodec: 'mp4a.40.2', abr: 129, size: 11_000_000 }],
  };
  state.height = 2160;
  state.jobs.set('a', { id: 'a', title: 'İndirilen örnek video', summary: '1080p · MP4', phase: 'downloading', progress: 0.62, detail: '%62 · 8,4 MB/sn · 0:12 kaldı' });
  state.jobs.set('b', { id: 'b', title: 'Tamamlanan örnek', summary: 'MP3 · 192 kbps', phase: 'done', progress: 1, detail: 'Tamamlandı · 7,2 MB', file: 'x' });
  render();
  renderJobs();
};

init();
