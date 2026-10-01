#Requires -Version 5.1
<#
.SYNOPSIS
    Релиз LDManager одной командой: версия, заметки, коммит, тег, пуш.
    Публикацию выполняет GitHub Actions (.github/workflows/release.yml)
    автоматически при пуше тега — ручных кликов в UI не нужно.

.DESCRIPTION
    Что делает:
      1. Проверяет, что мы на main, ветка синхронна с origin и без незакоммиченных изменений.
      2. Поднимает версию в LDManager.core.ps1 (авто-патч или явная -Version X.Y.Z).
      3. Генерирует RELEASE_NOTES_v<X.Y.Z>.md из коммитов с прошлого тега.
      4. Коммитит (add + commit "Bump to X.Y.Z"), создаёт лёгкий тег vX.Y.Z, пушит main и тег.
      5. Ждёт завершения Release workflow и печатает ссылку на релиз.

    Опционально (-SyncTestCopy): переподписывает ядро вашим сертификатом
    и обновляет тестовую копию в C:\test.

.EXAMPLE
    .\scripts\New-Release.ps1                     # авто: 2.0.2 -> 2.0.3, с подтверждением
.EXAMPLE
    .\scripts\New-Release.ps1 -Version 2.1.0 -Yes # явно и без вопросов
.EXAMPLE
    .\scripts\New-Release.ps1 -DryRun             # показать всё, ничего не менять
#>
[CmdletBinding()]
param(
    # Новая версия X.Y.Z. Если не указана — авто-инкремент патча текущей.
    [string]$Version = '',
    # Не спрашивать подтверждение (для полностью автоматического запуска).
    [switch]$Yes,
    # Ничего не коммитить/пушить: показать план и заметки, откатить правки.
    [switch]$DryRun,
    # Не ждать завершения Release workflow после пуша.
    [switch]$NoWait,
    # После релиза переподписать ядро и обновить тестовую копию.
    [switch]$SyncTestCopy,
    # Отпечаток сертификата подписи (CurrentUser\My).
    [string]$CertThumbprint = '19C75C73A53D410489F8D23D0DA35427C44F9458',
    # Куда копировать обновлённые файлы при -SyncTestCopy.
    [string]$TestCopyDir = 'C:\test\ldplayer-Manager-CLI-Menu'
)

$ErrorActionPreference = 'Stop'
$Utf8Bom = [System.Text.UTF8Encoding]::new($true)
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $root

function Invoke-Git {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $out = & git @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ("git {0}`n{1}" -f ($Arguments -join ' '), ($out -join [Environment]::NewLine))
    }
    return [string[]]@($out | ForEach-Object { $_.ToString() })
}
function Write-Step { param([string]$Text) Write-Host "`n==> $Text" -ForegroundColor Cyan }
function Write-Info { param([string]$Text) Write-Host "    $Text" }

# git-команда, чей stderr мы игнорируем (PS 5.1 + EAP=Stop превращает stderr в ошибку)
function Test-GitSuccess {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $null = & git @Arguments 2>$null } finally { $ErrorActionPreference = $prevEap }
    return ($LASTEXITCODE -eq 0)
}

# --- 1. Проверки перед релизом ---------------------------------------------
Write-Step 'Проверки перед релизом'

$corePath = Join-Path $root 'LDManager.core.ps1'
$core = [System.IO.File]::ReadAllText($corePath)
if ($core -notmatch "\`$script:ScriptVersion\s*=\s*'(\d+\.\d+\.\d+)'") {
    throw 'Не найдена строка версии ($script:ScriptVersion) в LDManager.core.ps1'
}
$current = $Matches[1]
$owner = if ($core -match "\`$script:RepoOwner\s*=\s*'([^']+)'") { $Matches[1] } else { 'genrihx2' }
$repo  = if ($core -match "\`$script:RepoName\s*=\s*'([^']+)'") { $Matches[1] } else { 'ldplayer-Manager-CLI-Menu' }

$branch = @((Invoke-Git @('rev-parse', '--abbrev-ref', 'HEAD')))[0]
if ($branch -ne 'main') { throw "Релиз делается из ветки main, сейчас: $branch" }
Invoke-Git @('fetch', 'origin', '--quiet') | Out-Null
$behind = [int](@((Invoke-Git @('rev-list', '--count', 'HEAD..origin/main')))[0])
$ahead  = [int](@((Invoke-Git @('rev-list', '--count', 'origin/main..HEAD')))[0])
if ($behind) { throw "Локальная ветка отстаёт от origin/main на $behind коммитов — сначала git pull" }
if ($ahead)  { throw "Есть незапушенные коммиты ($ahead) — сначала git push" }

$status = @((Invoke-Git @('status', '--porcelain')))
$dirty = @($status | Where-Object { $_ -notmatch '^\?\?' })
if ($dirty.Count) { throw "Незакоммиченные изменения (закоммитьте или уберите):`n$($dirty -join "`n")" }
$untracked = @($status | Where-Object { $_ -match '^\?\?' })
if ($untracked.Count) { Write-Warning "Незатреканные файлы (релизу не мешают): $($untracked -join '; ')" }
Write-Info "Ветка main синхронна с origin, tracked-изменений нет. Текущая версия: $current"

# --- 2. Новая версия ---------------------------------------------------------
if (-not $Version) {
    $v = [version]$current
    $Version = '{0}.{1}.{2}' -f $v.Major, $v.Minor, ($v.Build + 1)
    Write-Info "Версия не указана — авто-инкремент патча: $current -> $Version"
}
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "Неверный формат версии '$Version' — нужен X.Y.Z" }
if ([version]$Version -le [version]$current) { throw "Новая версия $Version должна быть больше текущей $current" }
$tag = "v$Version"

if (Test-GitSuccess @('rev-parse', '-q', '--verify', "refs/tags/$tag")) { throw "Тег $tag уже существует локально" }
$remoteTag = @(& git ls-remote origin "refs/tags/$tag")
if ($remoteTag.Count) { throw "Тег $tag уже существует на origin" }

# --- 3. Заметки релиза из коммитов -------------------------------------------
Write-Step 'Заметки релиза из коммитов'
$prevTag = $null
if (Test-GitSuccess @('describe', '--tags', '--abbrev=0')) {
    $prevTag = @((Invoke-Git @('describe', '--tags', '--abbrev=0')))[0]
}

$logArgs = @('log', '--pretty=format:%s%x09%h', '--no-merges')
if ($prevTag) { $logArgs += "$prevTag..HEAD" } else { $logArgs += '-15' }
$commits = @(Invoke-Git $logArgs | Where-Object { $_ -and ($_ -notmatch '^Bump to ') })
$bullets = foreach ($c in $commits) {
    $parts = $c -split "`t", 2
    if ($parts.Count -eq 2) { '- {0} ({1})' -f $parts[0], $parts[1] }
}
if (-not $bullets) {
    Write-Warning "Коммитов с прошлого тега нет — будет техническая формулировка"
    $bullets = @('- Технический релиз: без изменений в коде с ' + $prevTag + '.')
}
$intro = if ($prevTag) { "Изменения с $prevTag." } else { 'Начало истории релизов.' }
$compareUrl = "https://github.com/$owner/$repo/compare/$prevTag...$tag"

$notes = @"
# LDManager $tag

$intro

## Изменения

$($bullets -join "`n")

## Обновление

Вариант 1 — в самом меню: [g] GitHub -> [3] Автообновление скрипта из GitHub.

Вариант 2 — вручную: скачайте ZIP релиза и замените LDManager.ps1, LDManager.core.ps1, LD.Sieve.ps1.

> После замены файлов, если включена строгая политика выполнения (AllSigned), подпишите скрипты заново через меню [s].

**Full Changelog:** $compareUrl
"@
$notesFile = Join-Path $root "RELEASE_NOTES_$tag.md"

# --- 4. Подъём версии (+ подпись при -SyncTestCopy) ---------------------------
Write-Step "Поднимаю версию: $current -> $Version"
$pattern = "(\`$script:ScriptVersion\s*=\s*')(\d+\.\d+\.\d+)(')"
$newCore = [regex]::Replace($core, $pattern, { param($m) $m.Groups[1].Value + $Version + $m.Groups[3].Value })
if ($newCore -eq $core) { throw 'Замена версии в ядре не сработала — проверьте файл' }
[System.IO.File]::WriteAllText($corePath, $newCore, $Utf8Bom)
[System.IO.File]::WriteAllText($notesFile, $notes, $Utf8Bom)
Write-Info ("Создан {0}" -f (Split-Path -Leaf $notesFile))

# --- DryRun: показать и откатить ---------------------------------------------
if ($DryRun) {
    Write-Host "`n----- DRY RUN: содержимое заметок -----" -ForegroundColor Yellow
    Write-Host $notes
    Write-Host "----- конец заметок -----" -ForegroundColor Yellow
    Write-Host "Версия в ядре: $current -> $Version (файл будет восстановлен)"
    Write-Host "Дальше без -DryRun: git add + commit 'Bump to $Version' + tag $tag + push origin main + push origin $tag"
    [System.IO.File]::WriteAllText($corePath, $core, $Utf8Bom)
    Remove-Item -LiteralPath $notesFile -Force
    Write-Host "`nDRY RUN завершён, рабочая копия восстановлена." -ForegroundColor Green
    return
}

# --- 5. Подтверждение и публикация --------------------------------------------
if (-not $Yes) {
    Write-Host "`nПлан: commit 'Bump to $Version' + тег $tag + push (main и тег) -> авто-публикация релиза на GitHub." -ForegroundColor Yellow
    $answer = Read-Host 'Продолжить? (y/N)'
    if ($answer -notmatch '^[Yy]([Dd][Aa])?$') {
        [System.IO.File]::WriteAllText($corePath, $core, $Utf8Bom)
        Remove-Item -LiteralPath $notesFile -Force
        throw 'Отменено пользователем, правки откачены'
    }
}

Write-Step 'Переподписываю ядро с новой версией'
$cert = Get-ChildItem "Cert:\CurrentUser\My\$CertThumbprint" -ErrorAction SilentlyContinue
if (-not $cert) { throw "Сертификат $CertThumbprint не найден в Cert:\CurrentUser\My" }
$sig = Set-AuthenticodeSignature -FilePath $corePath -Certificate $cert -TimestampServer 'http://timestamp.digicert.com'
if ($sig.Status -ne 'Valid') { throw "Подпись ядра: $($sig.Status)" }
Write-Info 'Ядро переподписано (Valid)'

Write-Step 'Коммит, тег, пуш'
$body = @($commits | ForEach-Object { ($_ -split "`t", 2)[0] }) -join "`n"
$msgFile = Join-Path $env:TEMP ('release-msg-{0}.txt' -f [guid]::NewGuid().ToString('N'))
[System.IO.File]::WriteAllText($msgFile, "Bump to $Version`n`n$body`n", $Utf8NoBom)
Invoke-Git @('add', 'LDManager.core.ps1', "RELEASE_NOTES_$tag.md") | Out-Null
Invoke-Git @('commit', '-F', $msgFile) | Out-Null
Remove-Item -LiteralPath $msgFile -Force
Invoke-Git @('tag', $tag) | Out-Null
Invoke-Git @('push', 'origin', 'main') | Out-Null
Invoke-Git @('push', 'origin', $tag) | Out-Null
Write-Info "Запушены main и тег $tag"

# --- 6. Ждём Release workflow ---------------------------------------------------
$releaseUrl = "https://github.com/$owner/$repo/releases/tag/$tag"
if (-not $NoWait) {
    Write-Step 'Жду завершения Release workflow (до 2 минут)'
    $head = @((Invoke-Git @('rev-parse', 'HEAD')))[0]
    $conclusion = $null
    for ($i = 0; $i -lt 12; $i++) {
        Start-Sleep -Seconds 10
        try {
            $api = "https://api.github.com/repos/$owner/$repo/actions/workflows/release.yml/runs?per_page=3"
            $runs = (Invoke-RestMethod -Uri $api -TimeoutSec 20 -Headers @{ 'User-Agent' = 'LDManager-Release-Script' }).workflow_runs
            $run = @($runs | Where-Object { $_.head_sha -eq $head }) | Select-Object -First 1
            if ($run -and $run.status -eq 'completed') { $conclusion = $run.conclusion; break }
            if ($run) { Write-Info ("Прогон #{0}: {1}..." -f $run.run_number, $run.status) }
        } catch {
            Write-Info ("API недоступен ({0}) — повторяю" -f $_.Exception.Message)
        }
    }
    if ($conclusion -eq 'success') {
        Write-Host '    Release workflow: success — релиз опубликован автоматически' -ForegroundColor Green
    } elseif ($conclusion) {
        Write-Warning "Release workflow завершился со статусом: $conclusion — загляните в Actions"
    } else {
        Write-Warning 'Не дождался статуса прогона — проверьте вкладку Actions вручную'
    }
}

# --- 7. Тестовая копия при -SyncTestCopy -----------------------------------------
if ($SyncTestCopy) {
    if (Test-Path -LiteralPath $TestCopyDir) {
        foreach ($f in @('LDManager.ps1', 'LDManager.core.ps1', 'LD.Sieve.ps1')) {
            Copy-Item -LiteralPath (Join-Path $root $f) -Destination (Join-Path $TestCopyDir $f) -Force
        }
        Write-Info "Тестовая копия обновлена: $TestCopyDir"
    } else {
        Write-Warning "Папка $TestCopyDir не найдена — тестовая копия не обновлялась"
    }
}

Write-Host "`nГотово. Релиз: $releaseUrl" -ForegroundColor Green
