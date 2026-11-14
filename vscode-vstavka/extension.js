// Диктовка ГигаАМ: запуск и вставка без клавиатуры (v1.2, 14.11.2026).
//
// 1) ЗАПУСК. На новом Маке разрешения «Мониторинг ввода», «Универсальный доступ» и микрофон выданы
//    VS Code, а не Терминалу. Процесс, порождённый расширением, наследует их (ответственный - VS Code),
//    поэтому при открытии VS Code расширение само поднимает супервайзер диктовки, если он не запущен.
//    Повторный запуск из второго окна безопасен: у супервайзера замок «один экземпляр».
//    Запуск и перезапуск - ТОЛЬКО если есть ~/.gigaam-dictation/zapusk.sh (так устроены Маки владельца).
//    В подарке его нет: там разрешения выданы Терминалу, и запуск из VS Code упал бы без «слуха»
//    и открыл бы окна настроек. Там расширение только вставляет текст (пункт 2).
//    Перезапуск: команда «Диктовка ГигаАМ: перезапустить» или адрес
//    vscode://novotels.gigaam-vstavka/perezapusk (его открывает ярлык на Рабочем столе).
// 2) ВСТАВКА. Движок кладёт текст в буфер и пишет "paste" в Unix-сокет этого окна. Окно в фокусе
//    выполняет штатную команду вставки VS Code - в редактор, веб-панель (чат Claude Code) и терминал,
//    без синтетического Cmd+V, поэтому Punto Switcher её не перехватывает. Сокет - файл 600 в папке 700,
//    в сеть ничего не слушается.
const vscode = require('vscode');
const net = require('net');
const fs = require('fs');
const os = require('os');
const path = require('path');
const cp = require('child_process');

const HOME = os.homedir();
const DEST = path.join(HOME, '.gigaam-dictation');
const CFG = path.join(HOME, '.config', 'whisper-skill');
const DIR = path.join(CFG, 'vscode');
const VPY = path.join(DEST, '.venv', 'bin', 'python');
const ZAPUSK = path.join(DEST, 'zapusk.sh');

function zhurnal(msg) {
  try {
    const t = new Date();
    const pad = (n) => String(n).padStart(2, '0');
    const ts = `${t.getFullYear()}-${pad(t.getMonth() + 1)}-${pad(t.getDate())} ${pad(t.getHours())}:${pad(t.getMinutes())}:${pad(t.getSeconds())}`;
    fs.appendFileSync(path.join(CFG, 'zapusk.log'), `${ts}  ${msg}\n`);
  } catch (e) { /* журнал не обязателен */ }
}

function chistoeOkruzhenie() {
  // Не тащим в диктовку переменные Electron/VS Code (ELECTRON_RUN_AS_NODE и т.п.).
  const env = { HOME, USER: os.userInfo().username, LANG: process.env.LANG || 'ru_RU.UTF-8',
    PATH: '/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin', HF_HUB_OFFLINE: '1' };
  return env;
}

function supervisorZhiv() {
  try {
    cp.execFileSync('/usr/bin/pgrep', ['-f', 'examples.supervisor'], { stdio: 'ignore' });
    return true;
  } catch (e) {
    return false; // pgrep: код 1 = не найден
  }
}

function zapustitEsliNet(otkuda) {
  if (!fs.existsSync(VPY)) { zhurnal(`vscode: нет ${VPY} - диктовка не установлена`); return; }
  if (!fs.existsSync(ZAPUSK)) return; // подарок: запуск через Терминал, расширение только вставляет
  if (fs.existsSync(path.join(CFG, 'vyklyucheno'))) return; // выключили ярлыком - не воскрешаем
  if (supervisorZhiv()) return;
  const child = cp.spawn(VPY, ['-m', 'examples.supervisor'], {
    cwd: DEST, env: chistoeOkruzhenie(), detached: true, stdio: 'ignore',
  });
  child.on('error', (e) => zhurnal(`vscode: не запустился супервайзер: ${e.message}`));
  child.unref();
  zhurnal(`запуск: VS Code (${otkuda}), pid=${child.pid}`);
}

function perezapustit(otkuda) {
  if (!fs.existsSync(ZAPUSK)) { zhurnal(`vscode: нет ${ZAPUSK}`); return; }
  const child = cp.spawn('/bin/bash', [ZAPUSK, `VS Code (${otkuda})`], {
    cwd: DEST, env: chistoeOkruzhenie(), detached: true, stdio: 'ignore',
  });
  child.on('error', (e) => zhurnal(`vscode: перезапуск не удался: ${e.message}`));
  child.unref();
  vscode.window.setStatusBarMessage('Диктовка ГигаАМ перезапускается…', 4000);
}

function slushatVstavku(context) {
  try { fs.mkdirSync(DIR, { recursive: true, mode: 0o700 }); } catch (e) { /* есть */ }
  const sockPath = path.join(DIR, `${process.pid}.sock`);
  try { fs.unlinkSync(sockPath); } catch (e) { /* не было */ }

  const server = net.createServer((conn) => {
    let buf = '';
    let done = false;
    conn.setEncoding('utf8');
    conn.setTimeout(3000, () => conn.destroy());
    conn.on('error', () => {});
    const reply = (s) => { if (!done) { done = true; conn.end(s + '\n'); } };
    conn.on('data', async (d) => {
      buf += d;
      if (done || buf.indexOf('\n') < 0) return;
      const cmd = buf.split('\n')[0].trim();
      const focused = vscode.window.state.focused;
      if (cmd === 'ping') return reply(focused ? 'focused' : 'background');
      if (cmd !== 'paste') return reply('unknown');
      if (!focused) return reply('notfocused');
      try {
        await vscode.commands.executeCommand('editor.action.clipboardPasteAction');
        reply('ok');
      } catch (e) {
        reply('error ' + String((e && e.message) || e).slice(0, 200));
      }
    });
  });
  server.on('error', () => {});
  server.listen(sockPath, () => { try { fs.chmodSync(sockPath, 0o600); } catch (e) { /* */ } });
  context.subscriptions.push({
    dispose: () => {
      try { server.close(); } catch (e) { /* */ }
      try { fs.unlinkSync(sockPath); } catch (e) { /* */ }
    },
  });
}

function activate(context) {
  slushatVstavku(context);
  context.subscriptions.push(
    vscode.commands.registerCommand('gigaamVstavka.perezapusk', () => perezapustit('команда')),
    vscode.window.registerUriHandler({
      handleUri(uri) {
        if (uri.path === '/perezapusk') perezapustit('ярлык');
        else if (uri.path === '/zapusk') zapustitEsliNet('ярлык');
      },
    }),
  );
  // Дать VS Code догрузиться, потом поднять диктовку, если её нет.
  const t = setTimeout(() => zapustitEsliNet('старт окна'), 3000);
  context.subscriptions.push({ dispose: () => clearTimeout(t) });
}

function deactivate() {}

module.exports = { activate, deactivate };
