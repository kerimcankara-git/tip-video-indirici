// Ana süreç: pencere, yt-dlp / ffmpeg çalıştırma, indirme işleri.
// Mac sürümündeki (app/Sources) mantığın Windows karşılığı; geliştirme sırasında macOS'ta da çalışır.
const { app, BrowserWindow, ipcMain, shell, clipboard, dialog, Menu, nativeTheme, session } = require('electron');
const path = require('path');
const fs = require('fs');
const { spawn } = require('child_process');

const brand = require('./brand.json');   // build_windows.sh tarafından brands/<ad>/brand.conf'tan üretilir
const isWin = process.platform === 'win32';
const exe = (name) => (isWin ? `${name}.exe` : name);

app.setName(brand.appName);
app.setPath('userData', path.join(app.getPath('appData'), brand.supportFolder));
if (isWin) app.setAppUserModelId(brand.appId);

// --- Araçlar -----------------------------------------------------------------
// Uygulamayla gelenler resources/bin'de; yt-dlp kendini güncelleyebilsin diye kullanıcı klasörüne kopyalanır.
const bundledBin = app.isPackaged
  ? path.join(process.resourcesPath, 'bin')
  : path.join(__dirname, '..', '..', isWin ? 'vendor-win' : 'vendor');
const supportBin = path.join(app.getPath('userData'), 'bin');
const tools = {
  ytdlp: path.join(supportBin, exe('yt-dlp')),
  ffmpeg: path.join(bundledBin, exe('ffmpeg')),
  deno: path.join(bundledBin, exe('deno')),
};
const versionFile = path.join(supportBin, 'yt-dlp.version');

const env = {
  ...process.env,
  PATH: [supportBin, bundledBin, process.env.PATH].join(path.delimiter),
  PYTHONUTF8: '1',              // Windows'ta Türkçe dosya adları bozulmasın
  PYTHONIOENCODING: 'utf-8',
};

function readText(file) {
  try { return fs.readFileSync(file, 'utf8').trim(); } catch { return ''; }
}

function prepareTools() {
  fs.mkdirSync(supportBin, { recursive: true });
  const bundledVersion = readText(path.join(bundledBin, 'yt-dlp.version'));
  const installedVersion = readText(versionFile);
  if (!fs.existsSync(tools.ytdlp) || bundledVersion > installedVersion) {
    fs.copyFileSync(path.join(bundledBin, exe('yt-dlp')), tools.ytdlp);
    fs.chmodSync(tools.ytdlp, 0o755);
    fs.writeFileSync(versionFile, bundledVersion);
  }
  return bundledVersion > installedVersion ? bundledVersion : installedVersion;
}

const running = new Set();

/** Süreci çalıştırır; stdout satırlarını onLine'a verir ya da toplayıp döndürür. */
function run(file, args, { onLine, onStart } = {}) {
  return new Promise((resolve, reject) => {
    const proc = spawn(file, args, { env, windowsHide: true });
    running.add(proc);
    onStart?.(proc);
    const out = [];
    let err = '';
    let partial = '';
    proc.stdout.on('data', (chunk) => {
      if (!onLine) return out.push(chunk);
      const lines = (partial + chunk.toString('utf8')).split(/\r?\n|\r/);
      partial = lines.pop();
      lines.forEach((l) => l && onLine(l));
    });
    proc.stderr.on('data', (chunk) => { err += chunk.toString('utf8'); });
    proc.on('error', (e) => { running.delete(proc); reject(e); });
    proc.on('close', (code) => {
      running.delete(proc);
      if (onLine && partial) onLine(partial);
      resolve({ code, stdout: Buffer.concat(out), stderr: err });
    });
  });
}

function errorMessage(stderr, fallback) {
  const lines = stderr.split(/\r?\n/).filter(Boolean);
  const line = lines.reverse().find((l) => l.startsWith('ERROR:')) ?? lines[0];
  return line ? line.replace(/^ERROR:\s*/, '') : fallback;
}

const cookieArgs = (browser) => (browser ? ['--cookies-from-browser', browser] : []);

// Önizleme akışının istediği başlıklar (ör. YouTube User-Agent'a bakar); video isteklerine eklenir
let previewHeaders = null;
function installPreviewHeaders() {
  session.defaultSession.webRequest.onBeforeSendHeaders((details, callback) => {
    const h = details.requestHeaders;
    if (previewHeaders && details.resourceType === 'media' && details.url.startsWith(previewHeaders.origin)) {
      for (const [k, v] of Object.entries(previewHeaders.headers)) h[k] = v;
    }
    callback({ requestHeaders: h });
  });
}

/** "1:23" / "1:02:03" (kesirli ise ",5") */
const clock = (s) => {
  const whole = Math.floor(s), tenth = Math.round((s - whole) * 10);
  const h = Math.floor(whole / 3600), m = Math.floor(whole / 60) % 60, sec = String(whole % 60).padStart(2, '0');
  const base = h ? `${h}:${String(m).padStart(2, '0')}:${sec}` : `${m}:${sec}`;
  return tenth > 0 && tenth < 10 ? `${base},${tenth}` : base;
};

/** ffmpeg ile dosyadaki video/ses codec'ini okur (kesilen parçalar yeniden kodlanmış olabilir) */
async function probe(file) {
  try {
    const r = await run(tools.ffmpeg, ['-hide_banner', '-i', file]);
    const find = (kind) => (r.stderr.match(new RegExp(`Stream #.*?: ${kind}: ([A-Za-z0-9_]+)`)) || [])[1];
    return { video: find('Video'), audio: find('Audio') };
  } catch { return {}; }
}

// --- Video bilgisi -------------------------------------------------------------

async function fetchInfo(url, cookies) {
  const r = await run(tools.ytdlp, ['-J', '--no-playlist', '--no-warnings',
    '--js-runtimes', `deno:${tools.deno}`, ...cookieArgs(cookies), url]);
  if (r.code !== 0) throw new Error(errorMessage(r.stderr, 'Video bilgileri alınamadı'));
  const info = JSON.parse(r.stdout.toString('utf8'));
  const primary = (info.entries || []).find((e) => e?.formats?.length) || info;
  const formats = (primary.formats || [])
    .filter((f) => f.ext !== 'mhtml' && f.format_note !== 'storyboard')
    .map((f) => ({
      id: f.format_id, ext: f.ext, height: f.height, fps: f.fps,
      vcodec: f.vcodec && f.vcodec !== 'none' ? f.vcodec : null,
      acodec: f.acodec && f.acodec !== 'none' ? f.acodec : null,
      abr: f.abr, size: f.filesize || f.filesize_approx,
    }))
    .filter((f) => f.vcodec || f.acodec);
  // Kesim önizlemesi: tercihen sesli MP4 (≤720p), yoksa sessiz H.264.
  // HTML5 video HLS oynatamadığı için yalnızca doğrudan (http/https) akışlar kullanılır.
  const direct = (primary.formats || []).filter((f) => f.url && /^https?$/.test(f.protocol || '')
    && f.ext === 'mp4' && f.vcodec && f.vcodec !== 'none');
  const pick = (list) => list.filter((f) => (f.height || 0) <= 720).sort((a, b) => (b.height || 0) - (a.height || 0))[0]
    || list.sort((a, b) => (a.height || 0) - (b.height || 0))[0];
  const previewFormat = pick(direct.filter((f) => f.acodec && f.acodec !== 'none'))
    || pick(direct.filter((f) => /^avc/.test(f.vcodec)));
  previewHeaders = previewFormat
    ? { origin: new URL(previewFormat.url).origin, headers: previewFormat.http_headers || {} }
    : null;

  const platforms = { Youtube: 'YouTube', Twitter: 'X (Twitter)', Instagram: 'Instagram' };
  const key = info.extractor_key || primary.extractor_key;
  return {
    title: info.title || primary.title || info.id,
    uploader: info.uploader || primary.uploader,
    duration: info.duration || primary.duration,
    thumbnail: info.thumbnail || primary.thumbnail,
    platform: platforms[key] || key,
    videoCount: info.entries?.length || 1,
    preview: previewFormat?.url || null,
    heights: [...new Set(formats.filter((f) => f.vcodec && f.height).map((f) => f.height))].sort((a, b) => b - a),
    formats,
  };
}

// --- İndirme ---------------------------------------------------------------------

const jobs = new Map();
let win;
let quitConfirmed = false;   // kullanıcı "Yine de Çık" dediyse ikinci kez sorulmaz
const isActive = (s) => ['starting', 'downloading', 'processing', 'converting'].includes(s.phase);

function update(job, patch) {
  Object.assign(job.state, patch);
  win?.webContents.send('job-update', job.state);
  updateTaskbar();
}

function updateTaskbar() {
  if (!win) return;
  const active = [...jobs.values()].filter((j) => isActive(j.state));
  if (!active.length) return win.setProgressBar(-1);
  win.setProgressBar(active.reduce((s, j) => s + (j.state.progress || 0), 0) / active.length);
}

const formatBytes = (b) => {
  if (!b) return '—';
  const u = ['B', 'KB', 'MB', 'GB']; let i = 0;
  while (b >= 1000 && i < u.length - 1) { b /= 1000; i++; }
  return `${b.toFixed(i ? 1 : 0).replace('.', ',')} ${u[i]}`;
};
const formatDuration = (s) => {
  s = Math.max(0, Math.round(s || 0));
  const h = Math.floor(s / 3600), m = Math.floor(s / 60) % 60, sec = String(s % 60).padStart(2, '0');
  return h ? `${h}:${String(m).padStart(2, '0')}:${sec}` : `${m}:${sec}`;
};

async function download(job, req) {
  const dir = req.dir;
  fs.mkdirSync(dir, { recursive: true });
  const args = [
    '--no-playlist', '--no-warnings', '--newline', '--progress', '--no-simulate', '--no-mtime',
    '--js-runtimes', `deno:${tools.deno}`, '--ffmpeg-location', tools.ffmpeg,
    // Kesilen parçalarda aralık dosya adına eklenir: "Başlık [id] (1.23-2.45).mp4"
    '-P', dir, '-o', req.clip
      ? `%(title).100B [%(id)s] (${req.clip.map((t) => clock(t).replace(/:/g, '.')).join('-')}).%(ext)s`
      : '%(title).120B [%(id)s].%(ext)s',
    '--progress-template', 'download:[P]%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s',
    '--progress-template', 'postprocess:[PP]%(progress.postprocessor)s',
    '--print', 'after_move:[F]%(filepath)s',
    '--print', 'after_move:[C]%(vcodec)s|%(acodec)s|%(duration)s',
  ];
  const h = req.height ? `[height<=${req.height}]` : '';
  if (req.mode === 'video') {
    args.push('-f', `bv*${h}+ba/b${h}/b`, '--merge-output-format', req.container);
    if (req.container === 'mp4') args.push('-S', 'res,vcodec:h264,acodec:aac');
    if (req.container === 'webm') args.push('-S', 'res,vcodec:vp9,acodec:opus');
  } else if (req.mode === 'audio') {
    args.push('-f', 'bestaudio/best', '-x', '--audio-format', req.audioFormat);
    if (!['wav', 'flac'].includes(req.audioFormat)) args.push('--audio-quality', `${req.audioQuality}K`);
  } else {
    const f = req.format;
    args.push('-f', f.vcodec && !f.acodec ? `${f.id}+bestaudio` : f.id);
  }
  if (req.clip) {
    // Sadece seçilen aralık indirilir; kesimler tam saniyeden olsun diye uçlar yeniden kodlanır
    args.push('--download-sections', `*${req.clip[0]}-${req.clip[1]}`, '--force-keyframes-at-cuts');
  }
  args.push(...cookieArgs(req.cookies), req.url);

  const outputs = [];
  const names = { Merger: 'Video ve ses birleştiriliyor…', ExtractAudio: 'Ses dönüştürülüyor…' };
  let r;
  try {
    r = await run(tools.ytdlp, args, {
      onStart: (p) => { job.proc = p; },
      onLine: (line) => {
        if (line.startsWith('[P]')) {
          const [done, total, estimate, speed, eta] = line.slice(3).split('|').map(Number);
          if (Number.isNaN(done)) return;
          const t = total || estimate;
          const progress = t ? Math.min(1, done / t) : job.state.progress;
          // Toplam boyut bilinmiyorsa (ör. bölüm indirirken) ilerleme çubuğu belirsiz gösterilir
          const parts = [t ? `%${Math.round(progress * 100)}` : formatBytes(done)];
          if (speed) parts.push(`${formatBytes(speed)}/sn`);
          if (!Number.isNaN(eta)) parts.push(`${formatDuration(eta)} kaldı`);
          update(job, { phase: 'downloading', progress, indeterminate: !t, detail: parts.join(' · ') });
        } else if (line.startsWith('[PP]')) {
          update(job, { phase: 'processing', indeterminate: false, detail: names[line.slice(4)] || 'İşleniyor…' });
        } else if (line.startsWith('[F]')) {
          outputs.push({ file: line.slice(3) });
          update(job, { file: line.slice(3) });
        } else if (line.startsWith('[C]') && outputs.length) {
          const [v, a, d] = line.slice(3).split('|');
          Object.assign(outputs[outputs.length - 1], { video: v, audio: a, duration: Number(d) || 0 });
        }
      },
    });
  } catch (e) {
    return update(job, { phase: 'failed', detail: e.message });
  }
  if (job.cancelled) return update(job, { phase: 'cancelled', detail: 'İptal edildi' });
  if (r.code !== 0 || !outputs.length) {
    return update(job, { phase: 'failed', detail: errorMessage(r.stderr, 'İndirme başarısız') });
  }

  // Premiere / Windows oynatıcılarının sorunsuz açtığı codec'ler; AV1/VP9 → H.264, Opus → AAC
  if (req.mode === 'video' && req.container === 'mp4') {
    for (const [i, out] of outputs.entries()) {
      // Dosyanın gerçek codec'ine bakılır (kesilen parçalar yeniden kodlanmış olabilir)
      const probed = await probe(out.file);
      const video = probed.video || out.video, audio = probed.audio || out.audio;
      const needsVideo = video && video !== 'none' && !/^(avc|h264|hev|hvc)/.test(video);
      const needsAudio = audio && audio !== 'none' && !/^(mp4a|aac|mp3)/.test(audio);
      if (!needsVideo && !needsAudio) continue;
      const label = outputs.length > 1 ? ` (${i + 1}/${outputs.length})` : '';
      const ok = await convert(job, out, needsVideo, needsAudio, label);
      if (!ok) return;
    }
  }

  const size = outputs.reduce((s, o) => { try { return s + fs.statSync(o.file).size; } catch { return s; } }, 0);
  update(job, {
    phase: 'done', progress: 1,
    detail: (outputs.length > 1 ? `${outputs.length} video · ` : 'Tamamlandı · ') + formatBytes(size),
  });
  if (!win?.isFocused()) win?.flashFrame(true);
}

// Donanım kodlayıcılar sırayla denenir; hiçbiri yoksa işlemciyle (libx264) kodlanır.
const encoders = isWin
  ? [['h264_nvenc', '-preset', 'p5', '-cq', '21'],
     ['h264_qsv', '-global_quality', '21'],
     ['h264_amf', '-quality', 'quality', '-rc', 'cqp', '-qp_i', '20', '-qp_p', '22'],
     ['libx264', '-preset', 'fast', '-crf', '20']]
  : [['h264_videotoolbox', '-q:v', '65'], ['libx264', '-preset', 'fast', '-crf', '20']];

async function convert(job, out, video, audio, label) {
  const src = out.file;
  const tmp = src.replace(/\.[^.]+$/, '.converting.mp4');
  for (const [name, ...opts] of video ? encoders : [[null]]) {
    update(job, { phase: 'converting', progress: 0, indeterminate: false, detail: `Uyumlu formata dönüştürülüyor${label}…` });
    const args = ['-y', '-v', 'error', '-i', src, '-map', '0:v:0?', '-map', '0:a:0?',
      ...(video ? ['-c:v', name, ...opts, '-pix_fmt', 'yuv420p'] : ['-c:v', 'copy']),
      ...(audio ? ['-c:a', 'aac', '-b:a', '192k'] : ['-c:a', 'copy']),
      '-movflags', '+faststart', '-progress', 'pipe:1', '-nostats', tmp];
    const r = await run(tools.ffmpeg, args, {
      onStart: (p) => { job.proc = p; },
      onLine: (line) => {
        if (!line.startsWith('out_time_us=') || !out.duration) return;
        const progress = Math.min(0.999, Number(line.slice(12)) / 1e6 / out.duration);
        if (!Number.isNaN(progress)) {
          update(job, { progress, detail: `Uyumlu formata dönüştürülüyor${label}… %${Math.round(progress * 100)}` });
        }
      },
    });
    if (job.cancelled) {
      fs.rmSync(tmp, { force: true });
      update(job, { phase: 'cancelled', detail: 'İptal edildi' });
      return false;
    }
    if (r.code === 0) {
      fs.renameSync(tmp, src);
      return true;
    }
    fs.rmSync(tmp, { force: true });
    // Bu kodlayıcı bu bilgisayarda yok; sıradakini dene
  }
  update(job, { phase: 'failed', detail: 'Dönüştürme başarısız' });
  return false;
}

// --- IPC ----------------------------------------------------------------------------

ipcMain.handle('init', () => ({
  brand,
  platform: process.platform,
  downloadsDir: path.join(app.getPath('downloads'), brand.appName),
}));
ipcMain.handle('prepare-tools', () => prepareTools());
ipcMain.handle('fetch-info', (_e, url, cookies) => fetchInfo(url, cookies));
ipcMain.handle('start-download', (_e, id, req) => {
  const job = { state: { id, phase: 'starting', progress: 0, detail: 'Başlatılıyor…' }, cancelled: false };
  jobs.set(id, job);
  download(job, req);
});
ipcMain.handle('cancel', (_e, id) => {
  const job = jobs.get(id);
  if (job) { job.cancelled = true; job.proc?.kill(); }
});
ipcMain.handle('forget', (_e, id) => { jobs.delete(id); updateTaskbar(); });
ipcMain.handle('reveal', (_e, file) => shell.showItemInFolder(file));
ipcMain.handle('open-file', (_e, file) => shell.openPath(file));
ipcMain.handle('open-folder', (_e, dir) => { fs.mkdirSync(dir, { recursive: true }); return shell.openPath(dir); });
ipcMain.handle('choose-folder', async (_e, current) => {
  const r = await dialog.showOpenDialog(win, { defaultPath: current, properties: ['openDirectory', 'createDirectory'] });
  return r.canceled ? null : r.filePaths[0];
});
ipcMain.handle('read-clipboard', () => clipboard.readText());
ipcMain.handle('open-external', (_e, url) => {
  // Sadece https bağlantıları varsayılan tarayıcıda açılır
  if (/^https:\/\//.test(url)) return shell.openExternal(url);
});
ipcMain.handle('update-tools', async () => {
  const r = await run(tools.ytdlp, ['-U']);
  const v = await run(tools.ytdlp, ['--version']);
  const version = v.stdout.toString().trim();
  if (r.code !== 0 || !version) throw new Error(errorMessage(r.stderr, 'Güncelleme başarısız'));
  fs.writeFileSync(versionFile, version);
  return version;
});

// --- Pencere --------------------------------------------------------------------------

function createWindow() {
  const dark = nativeTheme.shouldUseDarkColors;
  win = new BrowserWindow({
    width: 820, height: 900, minWidth: 720, minHeight: 680,
    title: brand.appName,
    backgroundColor: dark ? '#1c1c1e' : '#f5f5f7',
    icon: path.join(__dirname, 'renderer', 'icon.png'),
    titleBarStyle: 'hidden',
    ...(isWin ? { titleBarOverlay: { color: '#00000000', symbolColor: dark ? '#f5f5f7' : '#1d1d1f', height: 40 } }
              : { trafficLightPosition: { x: 16, y: 16 } }),
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, sandbox: true },
  });
  const shot = process.argv.find((a) => a.startsWith('--screenshot='));
  // Ekran görüntüsü modunda panodaki bağlantı otomatik getirilmez
  win.loadFile(path.join(__dirname, 'renderer', 'index.html'), shot ? { query: { noclipboard: '1' } } : {});
  win.on('focus', () => { win.flashFrame(false); win.webContents.send('focused'); });

  // İndirme sürerken kapatılırsa sor; varsayılan seçenek indirmeye devam etmek
  win.on('close', (e) => {
    const active = [...jobs.values()].filter((j) => isActive(j.state)).length;
    if (quitConfirmed || !active) return;
    e.preventDefault();
    const choice = dialog.showMessageBoxSync(win, {
      type: 'warning',
      title: brand.appName,
      message: 'İndirme sürüyor',
      detail: `${active === 1 ? 'Bir' : active} indirme devam ediyor. Uygulamadan çıkarsanız yarıda kesilecek.`,
      buttons: ['İndirmeye Devam Et', 'Yine de Çık'],
      defaultId: 0,
      cancelId: 0,
      noLink: true,
    });
    if (choice === 1) {
      quitConfirmed = true;
      win.close();
    }
  });

  // Geliştirme: --screenshot=dosya.png [--demo] ile arayüzün ekran görüntüsü alınır
  if (shot) {
    win.webContents.once('did-finish-load', async () => {
      if (process.argv.includes('--demo')) await win.webContents.executeJavaScript('window.__demo && window.__demo()');
      if (process.argv.includes('--help-screen')) await win.webContents.executeJavaScript("document.getElementById('helpBtn').click()");
      setTimeout(async () => {
        fs.writeFileSync(shot.split('=')[1], (await win.webContents.capturePage()).toPNG());
        app.quit();
      }, 1500);
    });
  }
}

if (!app.requestSingleInstanceLock()) app.quit();
app.on('second-instance', () => { if (win) { win.isMinimized() && win.restore(); win.focus(); } });
app.whenReady().then(() => {
  if (isWin) Menu.setApplicationMenu(null);
  installPreviewHeaders();
  createWindow();
});
app.on('window-all-closed', () => app.quit());
app.on('will-quit', () => running.forEach((p) => p.kill()));
