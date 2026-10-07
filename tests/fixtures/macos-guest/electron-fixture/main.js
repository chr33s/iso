// Gate Q Electron fixture: logs renderer control events and reports element
// frames in screen pixels (top-left origin), like the native Q fixture.
const { app, BrowserWindow, ipcMain, screen } = require('electron');
const fs = require('fs');
const path = require('path');

const dir = path.join(app.getPath('home'), 'Library/Application Support/IsoQFixture');
fs.mkdirSync(dir, { recursive: true });
const events = path.join(dir, 'electron-events.jsonl');
const state = path.join(dir, 'electron-state.json');
fs.writeFileSync(events, '');
let seq = 0;

app.whenReady().then(() => {
  const win = new BrowserWindow({
    x: 640, y: 620, width: 520, height: 420, title: 'Electron Fixture',
    webPreferences: { preload: path.join(__dirname, 'preload.js') },
  });
  ipcMain.on('event', (_e, ev) => {
    seq += 1;
    fs.appendFileSync(events, JSON.stringify({ seq, fw: 'electron', ...ev }) + '\n');
  });
  ipcMain.on('layout', (_e, rects) => {
    const content = win.getContentBounds();
    const k = screen.getPrimaryDisplay().scaleFactor;
    const frames = {};
    for (const [id, [x, y, w, h]] of Object.entries(rects)) {
      frames[id] = { x: (content.x + x) * k, y: (content.y + y) * k, w: w * k, h: h * k };
    }
    fs.writeFileSync(state, JSON.stringify({ pid: process.pid, frames }));
  });
  win.loadFile('index.html');
});
