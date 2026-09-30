// Arayüzün ana süreçle konuşabildiği tek kanal (Node API'leri doğrudan açılmaz).
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('api', {
  init: () => ipcRenderer.invoke('init'),
  prepareTools: () => ipcRenderer.invoke('prepare-tools'),
  fetchInfo: (url, cookies) => ipcRenderer.invoke('fetch-info', url, cookies),
  startDownload: (id, req) => ipcRenderer.invoke('start-download', id, req),
  cancel: (id) => ipcRenderer.invoke('cancel', id),
  forget: (id) => ipcRenderer.invoke('forget', id),
  reveal: (file) => ipcRenderer.invoke('reveal', file),
  openFile: (file) => ipcRenderer.invoke('open-file', file),
  openFolder: (dir) => ipcRenderer.invoke('open-folder', dir),
  chooseFolder: (current) => ipcRenderer.invoke('choose-folder', current),
  readClipboard: () => ipcRenderer.invoke('read-clipboard'),
  updateTools: () => ipcRenderer.invoke('update-tools'),
  openExternal: (url) => ipcRenderer.invoke('open-external', url),
  preparePreviewAudio: (url, cookies) => ipcRenderer.invoke('prepare-preview-audio', url, cookies),
  clearPreviewAudio: () => ipcRenderer.invoke('clear-preview-audio'),
  prepareLocalPreview: (url, cookies) => ipcRenderer.invoke('prepare-local-preview', url, cookies),
  onPreviewProgress: (fn) => ipcRenderer.on('preview-progress', (_e, p) => fn(p)),
  onJobUpdate: (fn) => ipcRenderer.on('job-update', (_e, state) => fn(state)),
  onFocus: (fn) => ipcRenderer.on('focused', () => fn()),
});
