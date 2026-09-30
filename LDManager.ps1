#Requires -Version 5.1

<#
.SYNOPSIS
    LDManager v2.0 — точка входа.

.DESCRIPTION
    Загружает ядро (LDManager.core.ps1, все функции и меню) и модуль интеграции
    Sieve (LD.Sieve.ps1), добавляет в главное меню пункт [x] и запускает меню.

    Ядро вынесено в отдельный файл, чтобы интеграцию можно было держать рядом,
    не переписывая основной скрипт. Ничего в поведении ядра не меняется: без
    заданного SIEVE_API_KEY все функции Sieve бездействуют.
#>
[CmdletBinding()]
param(
    # Загрузить функции без запуска меню (используется тестами).
    [switch]$LoadOnly
)

$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$script:RunMenu = -not $LoadOnly

$corePath = Join-Path $scriptRoot 'LDManager.core.ps1'
if (-not (Test-Path $corePath)) {
    Write-Host ("[X]  Не найден файл ядра: " + $corePath) -ForegroundColor Red
    exit 1
}

# --- Загрузка ядра ----------------------------------------------------------
# Ядро — это библиотека функций. Отрезаем его авто-запуск (try { Initialize...
# Show-MainMenu }), чтобы здесь построить меню с интеграцией Sieve.
$coreSrc = Get-Content -LiteralPath $corePath -Raw -Encoding UTF8
# Убираем возможный BOM в начале строки — он мешает [scriptblock]::Create.
if ($coreSrc.Length -gt 0 -and [int]$coreSrc[0] -eq 0xFEFF) { $coreSrc = $coreSrc.Substring(1) }

$cut = $coreSrc.LastIndexOf('try {')
if ($cut -gt 0) { $coreSrc = $coreSrc.Substring(0, $cut) }

# Ядро вычисляет $scriptRoot от $PSScriptRoot, который внутри скриптблока пуст,
# поэтому оставляем значение, заданное здесь.
$coreSrc = $coreSrc.Replace('$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }', '')

# --- Пункт меню [x] (ядро ничего не знает про Sieve) ------------------------
$menuOld = "        Write-Host '  [s] Подпись скрипта (self-signed CodeSigning)'"
$menuNew = "        Write-Host '  [x] Скрейпинг сайтов (Sieve) - сбор данных, документы, кредиты'`n        Write-Host '  [s] Подпись скрипта (self-signed CodeSigning)'"
$coreSrc = $coreSrc.Replace($menuOld, $menuNew)

$caseOld = "            's' { Invoke-ScriptSigning }"
$caseNew = "            'x' { Show-SieveMenu }`n            's' { Invoke-ScriptSigning }"
$coreSrc = $coreSrc.Replace($caseOld, $caseNew)

. ([scriptblock]::Create($coreSrc))

# --- Интеграция Sieve (использует функции и помощники ядра) -----------------
$sievePath = Join-Path $scriptRoot 'LD.Sieve.ps1'
if (Test-Path $sievePath) { . $sievePath }

# --- Запуск ------------------------------------------------------------------
if ($script:RunMenu) {
    try {
        Initialize-LDManager
        Show-MainMenu
    } catch {
        Write-Host ''
        Write-Fail "Критическая ошибка: $($_.Exception.Message)"
        if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray }
        Wait-Enter
    }
}
