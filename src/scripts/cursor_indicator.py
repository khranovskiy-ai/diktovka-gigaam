"""
Тонкий indicator у курсора мыши.

Два режима:
- "recording" — маленькая мигающая красная точка (caret-style blink).
- "transcribing" — вращающаяся янтарная катушка-бобина (как у старой
  кинокамеры): диск с тремя окошками на радиусе и центральной осью.

Используется так: пока пользователь держит PTT-хоткей, индикатор в
recording-режиме. Отпустил — переключаемся в transcribing, и показываем
бобину до тех пор, пока распознанный текст не вставился в активное поле.

Tk запускается в собственном daemon-thread'е (Tk не любит вызовы из чужих
потоков). Внешний код шлёт команды через queue.Queue, GUI вычитывает их
через Tk.after(). Зависимости: только stdlib.

⚠️ macOS: НЕ ПОДДЕРЖИВАЕТСЯ. macOS Tk требует чтобы Tk() был на main thread
(NSApplication привязан к main thread'у). Создание Tk в фоне даёт:
    NSInvalidArgumentException '-[NSApplication macOSVersion]: unrecognized selector'
с последующим крашем процесса. С KeepAlive=true в LaunchAgent — бесконечный
краш-цикл. Поэтому на macOS CursorIndicator.start() — no-op.
Пользователи Mac получают visual feedback через tray icon (TrayIcon).

Windows-only нюанс: позиция курсора берётся через GetCursorPos из user32.
На Linux fallback на pyautogui.position(), если pyautogui установлен.

Использование:
    from scripts.cursor_indicator import CursorIndicator

    ind = CursorIndicator()
    ind.start()
    # ... начали запись ...
    ind.show()                  # recording — мигающая точка
    # ... отпустили хоткей, идёт транскрибация и вставка ...
    ind.show_transcribing()     # transcribing — крутится катушка
    # ... текст вставлен ...
    ind.hide()
    # ... выход ...
    ind.stop()
"""

from __future__ import annotations

import logging
import math
import platform
import queue
import threading
import time
from typing import Optional, Tuple


# Окно одинакового размера в обоих режимах — позиция относительно курсора
# не "прыгает" при переключении точка↔катушка.
WIN_SIZE = 20
CENTER_OFFSET_X = 13           # где центр окна относительно курсора (X)
CENTER_OFFSET_Y = 10            # где центр окна относительно курсора (Y) — slightly lower
WIN_OFFSET_X = CENTER_OFFSET_X - WIN_SIZE // 2
WIN_OFFSET_Y = CENTER_OFFSET_Y - WIN_SIZE // 2

DOT_RADIUS = 1.5               # recording — крошечная точка
REEL_OUTER_R = 6.075           # transcribing — внешний радиус катушки
REEL_HOLE_R = 1.134            # окошки на катушке
REEL_HOLES_DIST = 3.726        # радиус, на котором сидят окошки
REEL_AXIS_R = 1.134            # центральная ось (отверстие посередине)
REEL_PERIOD_S = 0.8            # один полный оборот катушки

TRANSPARENT_BG = "#ff00ff"     # transparent-key colour (magenta) on Windows
DEFAULT_DOT_COLOR = "#ef4444"  # red-500 — recording
DEFAULT_REEL_COLOR = "#f4a261" # amber — transcribing (совпадает с цветом
                               # transcribing-state в tray icon)
BLINK_PERIOD_S = 0.6           # один цикл on/off для точки
TICK_MS = 33                   # ~30 fps
POLL_MS = 15


def _get_cursor_pos_win32() -> Optional[Tuple[int, int]]:
    """Return (x, y) of system cursor in screen coords, or None."""
    try:
        import ctypes
        from ctypes import wintypes

        class _POINT(ctypes.Structure):
            _fields_ = [("x", wintypes.LONG), ("y", wintypes.LONG)]

        pt = _POINT()
        ok = ctypes.windll.user32.GetCursorPos(ctypes.byref(pt))
        if not ok:
            return None
        return int(pt.x), int(pt.y)
    except Exception:
        return None


def _get_cursor_pos_fallback() -> Optional[Tuple[int, int]]:
    try:
        import pyautogui
        x, y = pyautogui.position()
        return int(x), int(y)
    except Exception:
        return None


def _get_cursor_pos() -> Optional[Tuple[int, int]]:
    if platform.system() == "Windows":
        pos = _get_cursor_pos_win32()
        if pos is not None:
            return pos
    return _get_cursor_pos_fallback()


class CursorIndicator:
    def __init__(
        self,
        color: str = DEFAULT_DOT_COLOR,
        reel_color: str = DEFAULT_REEL_COLOR,
    ):
        self.color = color
        self.reel_color = reel_color
        self._cmd_queue: "queue.Queue[Tuple[str, object]]" = queue.Queue()
        self._ready = threading.Event()
        self._stopped = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True, name="cursor-indicator")
        # macOS не поддерживает Tk в non-main thread (NSInvalidArgumentException).
        # Класс молча превращается в no-op чтобы caller-код можно было оставить
        # без условий — show()/hide()/stop() просто ничего не делают.
        self._disabled_on_mac = platform.system() == "Darwin"

    # ─── Public API ─────────────────────────────────────────────────────

    def start(self) -> None:
        if self._disabled_on_mac:
            logging.info(
                "cursor_indicator: skipped on macOS (Tk thread-safety issue). "
                "Visual feedback available via show_tray=true."
            )
            self._ready.set()
            return
        self._thread.start()
        self._ready.wait(timeout=2.0)

    def stop(self) -> None:
        if self._disabled_on_mac:
            return
        self._cmd_queue.put(("__quit__", None))
        self._stopped.wait(timeout=1.0)

    def show(self) -> None:
        """Recording mode — blinking red dot."""
        if self._disabled_on_mac:
            return
        self._cmd_queue.put(("mode", "recording"))

    def show_transcribing(self) -> None:
        """Transcribing mode — spinning amber film reel."""
        if self._disabled_on_mac:
            return
        self._cmd_queue.put(("mode", "transcribing"))

    def hide(self) -> None:
        if self._disabled_on_mac:
            return
        self._cmd_queue.put(("mode", "hidden"))

    # ─── Internals (Tk thread only) ─────────────────────────────────────

    def _run(self) -> None:
        try:
            import tkinter as tk
        except Exception as e:
            logging.error(f"cursor_indicator: tkinter unavailable: {e}")
            self._ready.set()
            return

        try:
            self._tk = tk.Tk()
        except Exception as e:
            logging.error(f"cursor_indicator: Tk() failed: {e}")
            self._ready.set()
            return

        self._tk.withdraw()  # hide root

        self._win = tk.Toplevel(self._tk)
        self._win.overrideredirect(True)
        self._win.wm_attributes("-topmost", True)
        try:
            # Magenta background becomes fully transparent on Windows.
            self._win.wm_attributes("-transparentcolor", TRANSPARENT_BG)
        except Exception:
            pass
        # Disable input — clicks pass through to whatever is below.
        try:
            self._win.wm_attributes("-disabled", True)
        except Exception:
            pass
        self._win.geometry(f"{WIN_SIZE}x{WIN_SIZE}+0+0")
        self._win.withdraw()

        self._canvas = tk.Canvas(
            self._win, width=WIN_SIZE, height=WIN_SIZE,
            bg=TRANSPARENT_BG, highlightthickness=0, bd=0,
        )
        self._canvas.pack()

        self._is_visible = False
        self._target_mode = "hidden"   # "hidden" | "recording" | "transcribing"
        self._anim_phase = 0.0

        self._tk.after(POLL_MS, self._poll_commands)
        self._tk.after(TICK_MS, self._tick)

        self._ready.set()

        try:
            self._tk.mainloop()
        except Exception as e:
            logging.error(f"cursor_indicator: mainloop crashed: {e}")
        finally:
            self._stopped.set()

    def _poll_commands(self) -> None:
        try:
            while True:
                cmd, arg = self._cmd_queue.get_nowait()
                if cmd == "__quit__":
                    self._tk.quit()
                    return
                elif cmd == "mode":
                    self._target_mode = arg  # type: ignore[assignment]
        except queue.Empty:
            pass
        try:
            self._tk.after(POLL_MS, self._poll_commands)
        except Exception:
            pass

    def _tick(self) -> None:
        should_be_visible = self._target_mode != "hidden"

        # Toggle visibility per current target mode
        if should_be_visible and not self._is_visible:
            self._win.deiconify()
            self._is_visible = True
        elif not should_be_visible and self._is_visible:
            self._win.withdraw()
            self._is_visible = False

        if self._is_visible:
            self._anim_phase += TICK_MS / 1000.0

            # Follow cursor
            pos = _get_cursor_pos()
            if pos is not None:
                cx, cy = pos
                self._win.geometry(
                    f"{WIN_SIZE}x{WIN_SIZE}+{cx + WIN_OFFSET_X}+{cy + WIN_OFFSET_Y}"
                )

            if self._target_mode == "recording":
                self._draw_dot()
            elif self._target_mode == "transcribing":
                self._draw_reel()

        try:
            self._tk.after(TICK_MS, self._tick)
        except Exception:
            pass

    def _draw_dot(self) -> None:
        c = self._canvas
        c.delete("all")

        # Binary blink: dot is visible during the first half of the period,
        # hidden during the second. Mimics a text-caret blink rather than a
        # smooth breath.
        phase = (self._anim_phase % BLINK_PERIOD_S) / BLINK_PERIOD_S
        if phase >= 0.5:
            return  # off — leave canvas empty (transparent)

        cx = WIN_SIZE / 2
        cy = WIN_SIZE / 2
        r = DOT_RADIUS
        c.create_oval(
            cx - r, cy - r, cx + r, cy + r,
            fill=self.color, outline="",
        )

    def _draw_reel(self) -> None:
        """Янтарный диск с тремя вращающимися окошками-отверстиями + ось."""
        c = self._canvas
        c.delete("all")

        cx = WIN_SIZE / 2
        cy = WIN_SIZE / 2
        angle = (self._anim_phase % REEL_PERIOD_S) / REEL_PERIOD_S * 2.0 * math.pi

        # Solid amber disk
        c.create_oval(
            cx - REEL_OUTER_R, cy - REEL_OUTER_R,
            cx + REEL_OUTER_R, cy + REEL_OUTER_R,
            fill=self.reel_color, outline="",
        )

        # Three "windows" on the reel — filled with the transparent-key color
        # so on Windows you literally see through them. They rotate together,
        # which makes the spin readable even at this tiny size.
        for i in range(3):
            a = angle + i * (2.0 * math.pi / 3.0)
            hx = cx + REEL_HOLES_DIST * math.cos(a)
            hy = cy + REEL_HOLES_DIST * math.sin(a)
            c.create_oval(
                hx - REEL_HOLE_R, hy - REEL_HOLE_R,
                hx + REEL_HOLE_R, hy + REEL_HOLE_R,
                fill=TRANSPARENT_BG, outline="",
            )

        # Central axis hole
        c.create_oval(
            cx - REEL_AXIS_R, cy - REEL_AXIS_R,
            cx + REEL_AXIS_R, cy + REEL_AXIS_R,
            fill=TRANSPARENT_BG, outline="",
        )
