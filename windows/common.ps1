# Общие функции кнопок «Диктовки ГигаАМ» на Windows.
# Подключение из соседних скриптов: . "$PSScriptRoot\common.ps1"

$script:DEST   = Join-Path $env:USERPROFILE ".gigaam-dictation"
$script:CFGDIR = Join-Path $env:USERPROFILE ".config\whisper-skill"

function Get-DictationProcess([string]$pattern) {
    Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='pythonw.exe'" |
        Where-Object { $_.CommandLine -like $pattern }
}

function Stop-DictationProcesses {
    # Порядок важен: сначала супервайзер (иначе он воскресит движок), потом движок.
    # Убиваем ТОЛЬКО python/pythonw с нашими модулями в командной строке -
    # чужой Python на компьютере получателя не трогаем.
    foreach ($pattern in @("*examples.supervisor*", "*examples.voice_dictation*")) {
        Get-DictationProcess $pattern |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Milliseconds 300
    }
}

function Get-DictationHotkeyName {
    # Человекочитаемое имя клавиши из конфига (дефолт Windows - ПРАВЫЙ Ctrl).
    $cfgFile = Join-Path $script:CFGDIR "voice_dictation.json"
    $hk = "<ctrl_r>"
    try {
        if (Test-Path $cfgFile) {
            $cfg = Get-Content $cfgFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($cfg.hotkey) { $hk = $cfg.hotkey }
        }
    } catch {}
    switch ($hk) {
        "<ctrl_r>" { "ПРАВЫЙ Ctrl (справа от пробела и правого Alt)" }
        "<ctrl>"   { "Ctrl (любой)" }
        "<alt>"    { "Alt (любой)" }
        "<alt_r>"  { "правый Alt" }
        default    { $hk }
    }
}
