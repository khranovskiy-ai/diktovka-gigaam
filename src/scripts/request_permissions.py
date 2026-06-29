"""Попросить у macOS разрешения для диктовки через нативные системные вызовы.

Запускать ИЗ Терминала (через .command) - тогда Мак вешает разрешения на «Терминал»
и сам показывает окошко «Разрешить» (как для микрофона), плюс добавляет «Терминал»
в списки «Мониторинг ввода» и «Универсальный доступ», чтобы можно было включить галочку.

Безопасно: только запрашивает доступ, ничего не нажимает и не отправляет.
"""
import ctypes


def request_input_monitoring() -> bool:
    """Input Monitoring (слушать клавиши) через IOKit.IOHIDRequestAccess."""
    try:
        iokit = ctypes.cdll.LoadLibrary(
            "/System/Library/Frameworks/IOKit.framework/IOKit"
        )
        iokit.IOHIDRequestAccess.restype = ctypes.c_bool
        iokit.IOHIDRequestAccess.argtypes = [ctypes.c_uint32]
        # kIOHIDRequestTypeListenEvent = 1 (слушать ввод)
        return bool(iokit.IOHIDRequestAccess(1))
    except Exception as e:  # noqa: BLE001
        print(f"input-monitoring: запрос не удался ({e})")
        return False


def request_accessibility() -> bool:
    """Accessibility (вставлять текст) через AXIsProcessTrustedWithOptions с prompt."""
    try:
        AS = ctypes.cdll.LoadLibrary(
            "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"
        )
        CF = ctypes.cdll.LoadLibrary(
            "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
        )
        prompt_key = ctypes.c_void_p.in_dll(AS, "kAXTrustedCheckOptionPrompt")
        true_val = ctypes.c_void_p.in_dll(CF, "kCFBooleanTrue")
        key_cb = ctypes.addressof(ctypes.c_char.in_dll(CF, "kCFTypeDictionaryKeyCallBacks"))
        val_cb = ctypes.addressof(ctypes.c_char.in_dll(CF, "kCFTypeDictionaryValueCallBacks"))

        CF.CFDictionaryCreate.restype = ctypes.c_void_p
        CF.CFDictionaryCreate.argtypes = [
            ctypes.c_void_p,
            ctypes.POINTER(ctypes.c_void_p),
            ctypes.POINTER(ctypes.c_void_p),
            ctypes.c_long,
            ctypes.c_void_p,
            ctypes.c_void_p,
        ]
        keys = (ctypes.c_void_p * 1)(prompt_key)
        vals = (ctypes.c_void_p * 1)(true_val)
        opts = CF.CFDictionaryCreate(None, keys, vals, 1, key_cb, val_cb)

        AS.AXIsProcessTrustedWithOptions.restype = ctypes.c_bool
        AS.AXIsProcessTrustedWithOptions.argtypes = [ctypes.c_void_p]
        return bool(AS.AXIsProcessTrustedWithOptions(opts))
    except Exception as e:  # noqa: BLE001
        print(f"accessibility: запрос не удался ({e})")
        return False


if __name__ == "__main__":
    im = request_input_monitoring()
    ax = request_accessibility()
    print(f"Мониторинг ввода: {'да' if im else 'нет (включи «Диктовка ГигаАМ»)'}")
    print(f"Универсальный доступ: {'да' if ax else 'нет (включи «Диктовка ГигаАМ»)'}")
