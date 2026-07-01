#!/usr/bin/env python3
"""Супервайзер диктовки ГигаАМ - последний рубеж надёжности.

Запускается ОДИН раз кнопкой «включить» (в контексте Терминала, поэтому
наследует разрешение Input Monitoring - «слух» клавиши Option). Порождает
движок диктовки как СВОЙ дочерний процесс - дочерний наследует тот же
TCC-контекст, поэтому тоже слышит Option - и следит за его здоровьем по
файлу health.json, который движок обновляет каждые 2 секунды:

  • процесс упал/вышел            → перезапустить (с нарастающей паузой);
  • пульс «застыл» дольше STALE   → Python заклинен (нативный дедлок CoreAudio
                                     держит GIL, либо зависание) → убить -9 и
                                     перезапустить начисто;
  • подряд FAIL_LIMIT неудач      → CoreAudio HAL застрял насовсем → перезапуск
    старта записи                  начисто (свежее соединение с CoreAudio).

Почему обычный процесс, а НЕ launchd-сервис: движку нужен «слух» Option
(Input Monitoring), а его на macOS даёт только запуск из доверенного
TCC-контекста (Терминал = клик владельца). launchd-запуск слух исторически НЕ
наследует. Поэтому супервайзер - долгоживущий «родитель», порождённый одним
кликом владельца; все рестарты движка идут его детьми и слух сохраняют.

Корень проблемы, ради которой это всё (30.06.2026): recorder.stop() вызывался
синхронно в потоке слушателя клавиатуры и намертво вис в CoreAudio HAL
(__psynch_mutexwait) → движок «глох», и НИ ОДИН из трёх внутренних сторожей
это не лечил (поток жив, is_recording=False). Внутри процесса теперь стоит
потолок PortAudio (бросаем зависший поток за ≤4с), а супервайзер - страховка
от того, что вылечить изнутри нельзя.
"""
from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

# ─── Пути и настройки ────────────────────────────────────────────────────────
DEST = Path.home() / ".gigaam-dictation"
VPY = DEST / ".venv" / "bin" / "python"
CFG_DIR = Path.home() / ".config" / "whisper-skill"
HEALTH = CFG_DIR / "health.json"
LOG = CFG_DIR / "supervisor.log"
LOCK = CFG_DIR / "supervisor.lock"

CHECK_INTERVAL = 3.0      # как часто проверять здоровье движка, сек
GRACE_SEC = 35.0          # сколько НЕ судить здоровье после запуска (движок грузит модель), сек
STALE_SEC = 30.0          # пульс старше этого = Python заклинен → перезапуск
FAIL_LIMIT = 3            # столько подряд неудач старта записи = HAL застрял → перезапуск
SLEEP_GAP_SEC = 15.0      # провал в часах супервайзера = Mac спал → дать движку очнуться
BACKOFF_BASE = 2.0        # стартовая пауза между перезапусками, сек
BACKOFF_MAX = 30.0        # потолок паузы, сек
STABLE_RESET_SEC = 90.0   # движок прожил столько без проблем → сбросить нарастающую паузу


def log(msg: str) -> None:
    line = f"{time.strftime('%Y-%m-%d %H:%M:%S')}  {msg}"
    try:
        CFG_DIR.mkdir(parents=True, exist_ok=True)
        with open(LOG, "a") as fh:
            fh.write(line + "\n")
    except Exception:
        pass
    print(line, flush=True)


def acquire_singleton_lock():
    """Не дать двум супервайзерам работать разом. Возвращает fd или None."""
    import fcntl
    try:
        CFG_DIR.mkdir(parents=True, exist_ok=True)
        fd = os.open(str(LOCK), os.O_CREAT | os.O_RDWR, 0o644)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        os.ftruncate(fd, 0)
        os.write(fd, str(os.getpid()).encode())
        return fd
    except Exception:
        return None


class Engine:
    """Дочерний процесс-движок: запуск, остановка, поднятие начисто."""

    def __init__(self):
        self.proc: subprocess.Popen | None = None
        self.started_at = 0.0

    def spawn(self):
        # Чистим прошлый пульс, чтобы не принять старый файл за свежий/протухший
        try:
            HEALTH.unlink()
        except FileNotFoundError:
            pass
        except Exception:
            pass
        env = dict(os.environ)
        env["HF_HUB_OFFLINE"] = "1"
        self.proc = subprocess.Popen(
            [str(VPY), "-m", "examples.voice_dictation"],
            cwd=str(DEST),
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        self.started_at = time.time()
        log(f"движок запущен, pid={self.proc.pid}")

    def alive(self) -> bool:
        return self.proc is not None and self.proc.poll() is None

    def exit_code(self):
        return None if self.proc is None else self.proc.poll()

    def kill(self):
        if self.proc is None:
            return
        pid = self.proc.pid
        # Сначала вежливо, потом -9: процесс, висящий в мьютексе CoreAudio
        # (__psynch_mutexwait), на SIGKILL умирает (это не uninterruptible I/O).
        for sig in (signal.SIGTERM, signal.SIGKILL):
            if self.proc.poll() is not None:
                break
            try:
                self.proc.send_signal(sig)
            except Exception:
                pass
            try:
                self.proc.wait(timeout=4.0)
                break
            except Exception:
                continue
        # Подчистить возможных «осиротевших» движков на всякий случай
        try:
            subprocess.run(["pkill", "-9", "-f", "examples.voice_dictation"],
                           capture_output=True, timeout=3)
        except Exception:
            pass
        log(f"движок остановлен, pid={pid}")
        self.proc = None


def read_health() -> dict | None:
    try:
        with open(HEALTH) as fh:
            return json.load(fh)
    except Exception:
        return None


def health_verdict(engine: Engine, now: float) -> tuple[str, str]:
    """Решение по здоровью живого движка. Возвращает (action, reason).
    action: 'ok' | 'restart'. Чистая логика - тестируется отдельно.
    """
    if now - engine.started_at < GRACE_SEC:
        return ("ok", "grace")  # ещё грузится - не судим
    h = read_health()
    if h is None:
        # Движок жив (alive() уже проверен), GRACE прошёл, а пульса нет -
        # heartbeat не пишется → процесс нездоров → перезапуск.
        return ("restart", "нет файла пульса после старта")
    age = now - float(h.get("ts", 0) or 0)
    if age > STALE_SEC:
        return ("restart", f"пульс застыл {age:.0f}s (Python заклинен/нативный дедлок)")
    if int(h.get("audio_fail_streak", 0) or 0) >= FAIL_LIMIT:
        return ("restart", f"CoreAudio HAL застрял (подряд неудач: {h.get('audio_fail_streak')})")
    return ("ok", "")


def main():
    lock_fd = acquire_singleton_lock()
    if lock_fd is None:
        log("другой супервайзер уже работает - выхожу")
        return

    engine = Engine()
    stop = {"flag": False}

    def _on_signal(signum, frame):
        stop["flag"] = True
        log(f"получен сигнал {signum} - останавливаю движок и выхожу")
        engine.kill()
        try:
            HEALTH.unlink()
        except Exception:
            pass
        os._exit(0)

    signal.signal(signal.SIGTERM, _on_signal)
    signal.signal(signal.SIGINT, _on_signal)

    log(f"=== супервайзер запущен, pid={os.getpid()} ===")
    backoff = BACKOFF_BASE
    engine.spawn()
    last_check = time.time()

    while not stop["flag"]:
        time.sleep(CHECK_INTERVAL)
        now = time.time()
        gap = now - last_check
        last_check = now
        try:
            # Mac спал → супервайзер сам был заморожен. Дать движку очнуться,
            # не судить здоровье этот цикл (иначе ложный перезапуск после сна).
            if gap > SLEEP_GAP_SEC:
                log(f"замечен сон Mac (провал {gap:.0f}s) - пропускаю проверку, даю движку очнуться")
                engine.started_at = now  # новая фора на восстановление пульса
                continue

            if not engine.alive():
                code = engine.exit_code()
                lived = now - engine.started_at
                log(f"движок вышел (код {code}, прожил {lived:.0f}s) - перезапуск через {backoff:.0f}s")
                time.sleep(backoff)
                backoff = min(backoff * 2, BACKOFF_MAX)
                engine.spawn()
                continue

            action, reason = health_verdict(engine, now)
            if action == "restart":
                log(f"движок нездоров: {reason} - перезапуск начисто")
                engine.kill()
                time.sleep(backoff)
                backoff = min(backoff * 2, BACKOFF_MAX)
                engine.spawn()
                continue

            # Здоров и стабилен дольше порога → сбросить нарастающую паузу
            if now - engine.started_at > STABLE_RESET_SEC and backoff != BACKOFF_BASE:
                backoff = BACKOFF_BASE
        except Exception as e:
            log(f"ошибка цикла супервайзера: {e}")
            time.sleep(CHECK_INTERVAL)

    engine.kill()


if __name__ == "__main__":
    main()
