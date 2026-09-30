// Ana süreç: pencere, yt-dlp / ffmpeg çalıştırma, indirme işleri.
// Mac sürümündeki (app/Sources) mantığın Windows karşılığı; geliştirme sırasında macOS'ta da çalışır.
const { app, BrowserWindow, ipcMain, shell, clipboard, dialog, Menu, nativeTheme, session } = require('electron');
const path = require('path');
const fs = require('fs');
const { spawn } = require('child_process');
const { pathToFileURL } = require('url');

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
  // Kesit indirirken ffmpeg siteye doğrudan bağlanır; gömülü ffmpeg güvenilir sertifika listesini
  // kendisi bulamayabiliyor ("certificate verify failed"). Windows'ta uygulamayla gelen liste,
  // macOS'ta (geliştirme) sistemin listesi kullanılır.
  SSL_CERT_FILE: isWin ? path.join(bundledBin, 'cacert.pem') : '/etc/ssl/cert.pem',
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
    // Önizleme akışında ses yoksa (YouTube'da sık) ses ayrıca hazırlanıp eş zamanlı çalınır
    previewNeedsAudio: !!previewFormat && !(previewFormat.acodec && previewFormat.acodec !== 'none'),
    // Yalnızca DASH parçalarıyla sunulan videolar (ör. yeni bitmiş canlı yayınlar): bölüm indirme boş dosya üretir;
    // kesit tam indirilip bilgisayarda kesilir
    dashOnly: formats.length > 0 && (primary.formats || []).filter((f) => f.ext !== 'mhtml' && f.format_note !== 'storyboard')
      .every((f) => f.protocol === 'http_dash_segments'),
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
  const base = [
    '--no-playlist', '--no-warnings', '--newline', '--progress', '--no-simulate', '--no-mtime',
    '--js-runtimes', `deno:${tools.deno}`, '--ffmpeg-location', tools.ffmpeg,
    '--progress-template', 'download:[P]%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s',
    '--progress-template', 'postprocess:[PP]%(progress.postprocessor)s',
    '--print', 'after_move:[F]%(filepath)s',
    '--print', 'after_move:[C]%(vcodec)s|%(acodec)s|%(duration)s',
  ];
  const h = req.height ? `[height<=${req.height}]` : '';
  if (req.mode === 'video') {
    base.push('-f', `bv*${h}+ba/b${h}/b`, '--merge-output-format', req.container);
    if (req.container === 'mp4') base.push('-S', 'res,vcodec:h264,acodec:aac');
    if (req.container === 'webm') base.push('-S', 'res,vcodec:vp9,acodec:opus');
  } else if (req.mode === 'audio') {
    base.push('-f', 'bestaudio/best', '-x', '--audio-format', req.audioFormat);
    if (!['wav', 'flac'].includes(req.audioFormat)) base.push('--audio-quality', `${req.audioQuality}K`);
  } else {
    const f = req.format;
    base.push('-f', f.vcodec && !f.acodec ? `${f.id}+bestaudio` : f.id);
  }
  const site = [...cookieArgs(req.cookies), req.url];

  let outputs;
  if (req.clip) {
    let section = 'fallback';
    if (!req.localCut) section = await downloadSection(job, base, site, req.clip, dir);
    if (job.cancelled) return update(job, { phase: 'cancelled', detail: 'İptal edildi' });
    if (section === 'failed') return;
    if (section === 'fallback') {
      outputs = await downloadAndCut(job, req, base, site, req.clip, dir);
      if (job.cancelled) return update(job, { phase: 'cancelled', detail: 'İptal edildi' });
      if (!outputs) return;
    } else {
      outputs = section;
    }
  } else {
    // Tweet metinleri uzun olabiliyor; dosya adı sınırını aşmasın
    const { r, outputs: out } = await runYtdlp(job, [...base, '-P', dir, '-o', '%(title).120B [%(id)s].%(ext)s', ...site], 0);
    if (job.cancelled) return update(job, { phase: 'cancelled', detail: 'İptal edildi' });
    if (!r) return;
    if (r.code !== 0 || !out.length) {
      return update(job, { phase: 'failed', detail: errorMessage(r.stderr, 'İndirme başarısız') });
    }
    outputs = out;
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

/** yt-dlp'yi çalıştırır, çıktı satırlarını işler. Başlatılamazsa işi başarısız sayar ve r: null döndürür. */
async function runYtdlp(job, args, clipLength) {
  const outputs = [];
  const names = { Merger: 'Video ve ses birleştiriliyor…', ExtractAudio: 'Ses dönüştürülüyor…' };
  try {
    const r = await run(tools.ytdlp, args, {
      onStart: (p) => { job.proc = p; },
      onLine: (line) => {
        if (line.startsWith('out_time_us=') && clipLength > 0) {
          // Kesit indirirken ffmpeg'in ilerlemesi (-progress pipe:1)
          const us = Number(line.slice(12));
          if (Number.isNaN(us)) return;
          const progress = Math.min(0.999, Math.max(0, us / 1e6 / clipLength));
          update(job, { phase: 'downloading', indeterminate: false, progress,
            detail: `Kesit indiriliyor… %${Math.round(progress * 100)}` });
        } else if (line.startsWith('[P]')) {
          const [done, total, estimate, speed, eta] = line.slice(3).split('|').map(Number);
          if (Number.isNaN(done)) return;
          const t = total || estimate;
          const progress = t ? Math.min(1, done / t) : job.state.progress;
          // Toplam boyut bilinmiyorsa ilerleme çubuğu belirsiz gösterilir
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
    return { r, outputs };
  } catch (e) {
    update(job, { phase: 'failed', detail: e.message });
    return { r: null, outputs: [] };
  }
}

/** Kesilen parçalarda aralık dosya adına eklenir: "Başlık [id] (1.23-2.45).mp4" */
const clipLabel = (clip) => clip.map((t) => clock(t).replace(/:/g, '.')).join('-');

/**
 * Sadece seçilen aralığı indirir (yt-dlp --download-sections; siteye ffmpeg bağlanır).
 * Dönüş: çıktı listesi, 'fallback' ("tam indir + bilgisayarda kes" yoluna geç) ya da 'failed' (hata gösterildi).
 */
async function downloadSection(job, base, site, clip, dir) {
  // Kesimler tam saniyeden olsun diye uçlar yeniden kodlanır. Bu indirmeyi ffmpeg yapar ve yt-dlp'ye
  // ilerleme bildirmez; ilerlemeyi ffmpeg'in kendisinden okuruz.
  const args = [...base, '-P', dir, '-o', `%(title).100B [%(id)s] (${clipLabel(clip)}).%(ext)s`,
    '--download-sections', `*${clip[0]}-${clip[1]}`, '--force-keyframes-at-cuts',
    '--downloader-args', 'ffmpeg:-progress pipe:1 -nostats', ...site];
  update(job, { indeterminate: true, detail: 'Kesit hazırlanıyor…' });

  // YouTube bazı istemcilerin adreslerinde ffmpeg'in bağlantısını zaman zaman reddediyor
  // (403 → "ffmpeg exited with code 8"). Her denemede yt-dlp yeni adresler aldığı için yeniden denenir.
  const attempts = 3;
  for (let attempt = 1; attempt <= attempts; attempt++) {
    const { r, outputs } = await runYtdlp(job, args, clip[1] - clip[0]);
    if (job.cancelled || !r) return 'failed';
    if (r.code === 0 && outputs.length) {
      // Bazı akış türlerinde (ör. yalnızca DASH parçaları) yt-dlp başarılı dönüp boş dosya üretiyor
      const size = (f) => { try { return fs.statSync(f).size; } catch { return 0; } };
      if (!outputs.some((o) => size(o.file) < 16384)) return outputs;
      outputs.forEach((o) => fs.rmSync(o.file, { force: true }));
      return 'fallback';
    }
    if (!/ffmpeg exited with code|403/.test(r.stderr)) {
      update(job, { phase: 'failed', detail: errorMessage(r.stderr, 'İndirme başarısız') });
      return 'failed';
    }
    if (attempt < attempts) {
      update(job, { phase: 'downloading', indeterminate: true, progress: 0,
        detail: `Bağlantı reddedildi, yeniden deneniyor (${attempt + 1}/${attempts})…` });
    }
  }
  return 'fallback';
}

/** Bilgisayarda kesimde kullanılacak kodlayıcılar (çıktı uzantısına göre); kesim tam saniyeden olsun diye yeniden kodlanır */
function cutCodecArgs(ext, quality) {
  const h264 = ['-c:v', 'libx264', '-preset', 'veryfast', '-crf', '18', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-b:a', '192k'];
  switch (ext) {
    case 'mp4': case 'm4v': case 'mov': return { ext, args: [...h264, '-movflags', '+faststart'] };
    case 'mkv': return { ext, args: h264 };
    case 'webm': return { ext, args: ['-c:v', 'libvpx-vp9', '-deadline', 'realtime', '-cpu-used', '8', '-b:v', '0', '-crf', '32',
      '-c:a', 'libopus', '-b:a', '128k'] };
    case 'mp3': return { ext, args: ['-vn', '-c:a', 'libmp3lame', '-b:a', `${quality}k`] };
    case 'm4a': case 'aac': return { ext, args: ['-vn', '-c:a', 'aac', '-b:a', `${quality}k`] };
    case 'wav': return { ext, args: ['-vn', '-c:a', 'pcm_s16le'] };
    case 'flac': return { ext, args: ['-vn', '-c:a', 'flac'] };
    case 'opus': case 'ogg': return { ext, args: ['-vn', '-c:a', 'libopus', '-b:a', `${quality}k`] };
    default: return { ext: 'mp4', args: [...h264, '-movflags', '+faststart'] };
  }
}

/**
 * Yedek yol: videoyu yt-dlp'nin kendi yöntemiyle tam indirir (geçici klasöre), aralığı bilgisayarda ffmpeg ile
 * keser ve tam dosyayı siler. Daha yavaş ama akış türünden ve bağlantı reddinden etkilenmez.
 */
async function downloadAndCut(job, req, base, site, clip, dir) {
  const tmp = fs.mkdtempSync(path.join(app.getPath('temp'), 'kesit-'));
  try {
    update(job, { phase: 'downloading', indeterminate: true, progress: 0, detail: 'Tam video indiriliyor (kesit için)…' });
    const { r, outputs: full } = await runYtdlp(job, [...base, '-P', tmp, '-o', '%(title).100B [%(id)s].%(ext)s', ...site], 0);
    if (job.cancelled || !r) return null;
    if (r.code !== 0 || !full.length) {
      update(job, { phase: 'failed', detail: errorMessage(r.stderr, 'İndirme başarısız') });
      return null;
    }
    const length = clip[1] - clip[0];
    const outputs = [];
    for (const src of full) {
      const parsed = path.parse(src.file);
      const codec = cutCodecArgs(parsed.ext.slice(1).toLowerCase(), req.mode === 'audio' ? req.audioQuality : 192);
      const dest = path.join(dir, `${parsed.name} (${clipLabel(clip)}).${codec.ext}`);
      update(job, { phase: 'converting', indeterminate: false, progress: 0, detail: 'Kesiliyor…' });
      const c = await run(tools.ffmpeg, ['-y', '-v', 'error', '-ss', String(clip[0]), '-i', src.file, '-t', String(length),
        '-map', '0:v:0?', '-map', '0:a:0?', ...codec.args, '-progress', 'pipe:1', '-nostats', dest], {
        onStart: (p) => { job.proc = p; },
        onLine: (line) => {
          if (!line.startsWith('out_time_us=')) return;
          const progress = Math.min(0.999, Math.max(0, Number(line.slice(12)) / 1e6 / length));
          if (!Number.isNaN(progress)) update(job, { progress, detail: `Kesiliyor… %${Math.round(progress * 100)}` });
        },
      });
      if (job.cancelled) { fs.rmSync(dest, { force: true }); return null; }
      if (c.code !== 0) {
        fs.rmSync(dest, { force: true });
        update(job, { phase: 'failed', detail: `Kesme başarısız: ${errorMessage(c.stderr, '')}` });
        return null;
      }
      update(job, { file: dest });
      outputs.push({ file: dest, video: src.video, audio: src.audio, duration: length });
    }
    return outputs;
  } catch (e) {
    update(job, { phase: 'failed', detail: e.message });
    return null;
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
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

// Kesit önizlemesi için sesi en düşük kalitede m4a olarak geçici bir klasöre indirir. YouTube'un ses akışlarına
// doğrudan bağlanılamıyor (tek istekte 403); bu yüzden gerçek indirmelerle aynı yol (yt-dlp) kullanılır.
let previewAudio = null;   // { proc, dir }
function clearPreviewAudio() {
  if (!previewAudio) return;
  previewAudio.proc?.kill();
  fs.rmSync(previewAudio.dir, { recursive: true, force: true });
  previewAudio = null;
}
ipcMain.handle('prepare-preview-audio', async (_e, url, cookies) => {
  clearPreviewAudio();
  const dir = fs.mkdtempSync(path.join(app.getPath('temp'), 'onizleme-'));
  const current = { proc: null, dir };
  previewAudio = current;
  const r = await run(tools.ytdlp, ['--no-warnings', '--quiet', '--no-playlist', '-f', 'wa[acodec^=mp4a]/wa',
    '-x', '--audio-format', 'm4a', '--js-runtimes', `deno:${tools.deno}`, '--ffmpeg-location', tools.ffmpeg,
    '-o', path.join(dir, 'ses.%(ext)s'), ...cookieArgs(cookies), url], { onStart: (p) => { current.proc = p; } });
  if (previewAudio !== current) return null;   // bu arada başka bir video yüklendi
  current.proc = null;
  const file = path.join(dir, 'ses.m4a');
  if (r.code !== 0 || !fs.existsSync(file)) throw new Error(errorMessage(r.stderr, 'Ses hazırlanamadı'));
  return pathToFileURL(file).href;
});
ipcMain.handle('clear-preview-audio', () => clearPreviewAudio());

// Doğrudan oynatılabilir akışı olmayan videolar (ör. yeni bitmiş canlı yayınlar, yalnızca DASH) için en düşük
// kaliteli, sesli bir kopyayı geçici klasöre indirir; ilerleme 'preview-progress' ile bildirilir.
ipcMain.handle('prepare-local-preview', async (_e, url, cookies) => {
  clearPreviewAudio();
  const dir = fs.mkdtempSync(path.join(app.getPath('temp'), 'onizleme-'));
  const current = { proc: null, dir };
  previewAudio = current;
  const r = await run(tools.ytdlp, ['--no-warnings', '--newline', '--progress', '--no-playlist',
    '-f', 'wv*[vcodec^=avc1]+wa[acodec^=mp4a]/wv*+wa/w', '--merge-output-format', 'mp4',
    '--progress-template', 'download:[P]%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s',
    '--js-runtimes', `deno:${tools.deno}`, '--ffmpeg-location', tools.ffmpeg,
    '-o', path.join(dir, 'onizleme.%(ext)s'), ...cookieArgs(cookies), url], {
    onStart: (p) => { current.proc = p; },
    onLine: (line) => {
      if (!line.startsWith('[P]') || previewAudio !== current) return;
      const [done, total, estimate] = line.slice(3).split('|').map(Number);
      const t = total || estimate;
      if (t && !Number.isNaN(done)) win?.webContents.send('preview-progress', Math.min(1, done / t));
    },
  });
  if (previewAudio !== current) return null;   // bu arada başka bir video yüklendi
  current.proc = null;
  const file = path.join(dir, 'onizleme.mp4');
  if (r.code !== 0 || !fs.existsSync(file)) throw new Error(errorMessage(r.stderr, 'Önizleme hazırlanamadı'));
  return pathToFileURL(file).href;
});
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
app.on('will-quit', () => { running.forEach((p) => p.kill()); clearPreviewAudio(); });
