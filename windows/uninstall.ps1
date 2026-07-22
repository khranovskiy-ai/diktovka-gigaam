# Кнопка «Диктовка ГигаАМ - удалить» (Windows).
$ErrorActionPreference = "SilentlyContinue"
. "$PSScriptRoot\common.ps1"

Write-Host "Удаление «Диктовки ГигаАМ» с этого компьютера."
$answer = Read-Host "Точно удалить? Напишите: да"
if ($answer.Trim().ToLower() -ne "да") {
    Write-Host "Отменено - ничего не удалял."
    Start-Sleep -Seconds 3
    exit 0
}

Stop-DictationProcesses

$desk = [Environment]::GetFolderPath("Desktop")
foreach ($n in @("включить", "выключить", "проверить", "удалить")) {
    Remove-Item (Join-Path $desk ("Диктовка ГигаАМ - " + $n + ".bat")) -Force -ErrorAction SilentlyContinue
}
Remove-Item $CFGDIR -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $DEST -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $env:USERPROFILE ".cache\huggingface\hub\models--istupakov--gigaam-v3-onnx") -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "Диктовка и модель распознавания удалены. Спасибо, что попробовали!" -ForegroundColor Green
Write-Host "(Python 3.11 и инструмент uv остались в вашем профиле - они общесистемные.)"
Start-Sleep -Seconds 4
exit 0
