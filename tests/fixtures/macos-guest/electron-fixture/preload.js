const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('iso', {
  event: (control, event, value) => ipcRenderer.send('event', { control, event, value }),
  layout: (rects) => ipcRenderer.send('layout', rects),
});
