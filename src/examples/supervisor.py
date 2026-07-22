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
IS_WIN = os.name == "nt"

DEST = Path.home() / ".gigaam-dictation"
if IS_WIN:
    # pythonw.exe = без консольного окна (фон); python.exe - запасной.
    VPY = DEST / ".venv" / "Scripts" / "pythonw.exe"
    if not VPY.exists():
        VPY = DEST / ".venv" / "Scripts" / "python.exe"
else:
    VPY = DEST / ".venv" / "bin" / "python"
CFG_DIR = Path.home() / ".config" / "whisper-skill"
HEALTH = CFG_DIR / "health.json"
LOG = CFG_DIR / "supervisor.log"
LOCK = CFG_DIR / "supervisor.lock"

CREATE_NO_WINDOW = 0x08000000  # Windows: дочерний процесс без мигающего окна

CHECK_INTERVAL = 3.0      # как часто проверять здоровье движка, сек
# Сколько НЕ судить здоровье после запуска (движок грузит модель), сек.
# Windows - 90: Defender при первом старте сканирует свежий venv и DLL
# onnxruntime, загрузка легко переваливает за 35с - иначе супервайзер
# убивал бы движок посреди первой загрузки (находка совета).
GRACE_SEC = 90.0 if IS_WIN else 35.0
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
        # encoding явно: без него Windows откроет файл в cp1251 и лог станет кашей
        with open(LOG, "a", encoding="utf-8", errors="replace") as fh:
            fh.write(line + "\n")
    except Exception:
        pass
    # под pythonw print - тихий no-op (sys.stdout=None), это безопасно
    print(line, flush=True)


def acquire_singleton_lock() -> bool:
    """Не дать двум супервайзерам работать разом.

    Переиспользует единственную реализацию замка из движка (named mutex на
    Windows / fcntl-файл на Unix) со СВОИМ именем - имена движка и
    супервайзера обязаны различаться, иначе они подерутся за один замок."""
    try:
        from examples.voice_dictation import acquire_single_instance_lock
        return acquire_single_instance_lock(
            timeout_seconds=0.5,
            mutex_name="GigaamDictationSupervisor_SingleInstance",
            lock_filename="supervisor.lock",
        )
    except Exception as e:
        log(f"singleton lock недоступен ({e!r}) - продолжаю без замка")
        return True


def _notify_user_broken(text: str) -> None:
    """Показать получателю окно «диктовка не запускается» - иначе отказ невидим
    (супервайзер без окна). Best-effort, не роняет супервайзер."""
    try:
        if IS_WIN:
            import ctypes
            MB_OK, MB_ICONWARNING, MB_SYSTEMMODAL = 0x0, 0x30, 0x1000
            ctypes.windll.user32.MessageBoxW(
                None, text, "Диктовка ГигаАМ", MB_OK | MB_ICONWARNING | MB_SYSTEMMODAL
            )
        else:
            subprocess.run(
                ["osascript", "-e",
                 f'display notification "{text}" with title "Диктовка ГигаАМ"'],
                capture_output=True, timeout=5,
            )
    except Exception:
        pass


def _sweep_orphan_engines() -> None:
    """Подчистить осиротевшие движки. На Windows - ТОЛЬКО python/pythonw с
    examples.voice_dictation в командной строке (не трогаем чужой Python
    получателя и не совпадаем с самим PowerShell-фильтром)."""
    try:
        if IS_WIN:
            ps = (
                "Get-CimInstance Win32_Process -Filter \"Name='python.exe' OR Name='pythonw.exe'\" | "
                "Where-Object { $_.CommandLine -like '*examples.voice_dictation*' } | "
                "ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"
            )
            subprocess.run(
                ["powershell", "-NoProfile", "-Command", ps],
                capture_output=True, timeout=15, creationflags=CREATE_NO_WINDOW,
            )
        else:
            subprocess.run(["pkill", "-9", "-f", "examples.voice_dictation"],
                           capture_output=True, timeout=3)
    except Exception:
        pass


# ─── Windows Job Object: движок умирает ВМЕСТЕ с супервайзером ───────────────
# Если супервайзер убьют любым способом (Диспетчер задач, краш, taskkill) -
# закрытие хэндла Job с флагом KILL_ON_JOB_CLOSE гарантированно убивает движок.
# Иначе движок-сирота держит микрофон, а перезапустить его больше некому.
_job_handle = None  # держим ссылку: закрытие хэндла = смерть процессов в Job


def _win_assign_to_job(pid: int) -> bool:
    global _job_handle
    if not IS_WIN:
        return False
    try:
        import ctypes
        from ctypes import wintypes

        kernel32 = ctypes.windll.kernel32

        class IO_COUNTERS(ctypes.Structure):
            _fields_ = [(n, ctypes.c_ulonglong) for n in (
                "ReadOperationCount", "WriteOperationCount", "OtherOperationCount",
                "ReadTransferCount", "WriteTransferCount", "OtherTransferCount")]

        class JOBOBJECT_BASIC_LIMIT_INFORMATION(ctypes.Structure):
            _fields_ = [
                ("PerProcessUserTimeLimit", ctypes.c_longlong),
                ("PerJobUserTimeLimit", ctypes.c_longlong),
                ("LimitFlags", wintypes.DWORD),
                ("MinimumWorkingSetSize", ctypes.c_size_t),
                ("MaximumWorkingSetSize", ctypes.c_size_t),
                ("ActiveProcessLimit", wintypes.DWORD),
                ("Affinity", ctypes.c_size_t),
                ("PriorityClass", wintypes.DWORD),
                ("SchedulingClass", wintypes.DWORD),
            ]

        class JOBOBJECT_EXTENDED_LIMIT_INFORMATION(ctypes.Structure):
            _fields_ = [
                ("BasicLimitInformation", JOBOBJECT_BASIC_LIMIT_INFORMATION),
                ("IoInfo", IO_COUNTERS),
                ("ProcessMemoryLimit", ctypes.c_size_t),
                ("JobMemoryLimit", ctypes.c_size_t),
                ("PeakProcessMemoryUsed", ctypes.c_size_t),
                ("PeakJobMemoryUsed", ctypes.c_size_t),
            ]

        JobObjectExtendedLimitInformation = 9
        JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000
        PROCESS_SET_QUOTA = 0x0100
        PROCESS_TERMINATE = 0x0001

        if _job_handle is None:
            h_job = kernel32.CreateJobObjectW(None, None)
            if not h_job:
                return False
            info = JOBOBJECT_EXTENDED_LIMIT_INFORMATION()
            info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
            if not kernel32.SetInformationJobObject(
                h_job, JobObjectExtendedLimitInformation,
                ctypes.byref(info), ctypes.sizeof(info),
            ):
                kernel32.CloseHandle(h_job)
                return False
            _job_handle = h_job

        h_proc = kernel32.OpenProcess(PROCESS_SET_QUOTA | PROCESS_TERMINATE, False, pid)
        if not h_proc:
            return False
        ok = bool(kernel32.AssignProcessToJobObject(_job_handle, h_proc))
        kernel32.CloseHandle(h_proc)
        return ok
    except Exception as e:
        log(f"Job Object не назначен ({e!r}) - движок без страховки от сироты")
        return False


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
        kwargs = {}
        if IS_WIN:
            kwargs["creationflags"] = CREATE_NO_WINDOW
        self.proc = subprocess.Popen(
            [str(VPY), "-m", "examples.voice_dictation"],
            cwd=str(DEST),
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            **kwargs,
        )
        self.started_at = time.time()
        if IS_WIN and not _win_assign_to_job(self.proc.pid):
            # отказ без исключения (OpenProcess/Assign вернули 0) тоже должен быть виден
            log("Job Object не назначен - движок без страховки от сироты")
        log(f"движок запущен, pid={self.proc.pid}")

    def alive(self) -> bool:
        return self.proc is not None and self.proc.poll() is None

    def exit_code(self):
        return None if self.proc is None else self.proc.poll()

    def kill(self):
        if self.proc is None:
            return
        pid = self.proc.pid
        if IS_WIN:
            # Windows: сигналов нет (SIGKILL отсутствует, SIGTERM не доставляется) -
            # terminate() и kill() оба зовут TerminateProcess, этого достаточно.
            for meth in (self.proc.terminate, self.proc.kill):
                if self.proc.poll() is not None:
                    break
                try:
                    meth()
                except Exception:
                    pass
                try:
                    self.proc.wait(timeout=4.0)
                    break
                except Exception:
                    continue
        else:
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
        _sweep_orphan_engines()
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
    if not acquire_singleton_lock():
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
    fast_deaths = 0  # подряд мгновенных смертей движка (битая установка)
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
                # Стоп-кран вечного цикла (находка совета): битая установка =
                # движок умирает мгновенно снова и снова, супервайзер без окна
                # крутил бы это НЕВИДИМО для получателя годами. 5 подряд смертей
                # моложе 10с → сказать человеку и остановиться.
                if lived < 10.0:
                    fast_deaths += 1
                else:
                    fast_deaths = 0
                if fast_deaths >= 5:
                    log("движок умирает мгновенно 5 раз подряд - установка битая, останавливаюсь")
                    _notify_user_broken(
                        "Диктовка не запускается. Нажмите кнопку "
                        "'Диктовка ГигаАМ - проверить' и напишите автору."
                    )
                    break
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
    try:
        main()
    except Exception as e:
        # Последний рубеж видимости: любой краш супервайзера - в лог,
        # иначе под pythonw он умер бы молча и бесследно.
        log(f"ФАТАЛЬНО: супервайзер упал: {e!r}")
        raise
