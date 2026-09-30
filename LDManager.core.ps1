#Requires -Version 5.1

<#
.SYNOPSIS
    LDManager v2.0 — интерактивное PowerShell-меню для управления LDPlayer Emulator.

.DESCRIPTION
    Управляет ЛОКАЛЬНЫМИ инстансами эмулятора LDPlayer на вашем компьютере через
    официальный консольный интерфейс ldconsole.exe (и adb.exe для отладки).

    Возможности: запуск/остановка/перезагрузка, клонирование, удаление,
    переименование инстансов; установка/удаление APK, очистка данных приложения,
    force stop; ADB (shell, push/pull, произвольные команды); скриншоты и запись
    экрана; подмена модели устройства; смена оператора/SIM-страны (MCC/MNC,
    45+ пресетов + кастом); генерация случайных IMEI (контрольная сумма Луна) /
    Android ID / MAC; управление окнами; массовые операции; просмотр логов
    (файлы + adb logcat); менеджер GitHub-токена (DPAPI); автообновление из
    GitHub; загрузка репозитория (clone / ZIP / файл); цифровая подпись скрипта
    (self-signed CodeSigning); информация о версиях.

    ВАЖНО / ДИСКЛЕЙМЕР:
      * Скрипт предназначен ИСКЛЮЧИТЕЛЬНО для управления эмулятором LDPlayer,
        установленным на ВАШЕМ компьютере, и для работы с ВАШИМИ собственными
        инстансами (виртуальными машинами Android).
      * Функции подмены идентификаторов (IMEI / IMSI / SIM / Android ID / MAC /
        модель) и смены SIM-страны предназначены для приватности и тестирования
        приложений на собственных инстансах. Они меняют параметры ВИРТУАЛЬНОЙ
        машины внутри эмулятора и не затрагивают реальное оборудование.
      * Сетевые запросы выполняются ТОЛЬКО при явном выборе пунктов
        обновления/загрузки из GitHub (raw.githubusercontent.com /
        api.github.com). Токен хранится локально, зашифрованный DPAPI.
      * Используйте ответственно и в соответствии с законодательством и
        правилами сервисов, с которыми работаете.

.NOTES
    Полное объяснение назначения — в README.md, раздел
    «Примечание для AV-аналитиков» (Note for AV analysts).
#>

[CmdletBinding()]
param(
    # Загрузить только функции (используется тестами: не запускает меню).
    [switch]$LoadOnly
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Версия и репозиторий
# ---------------------------------------------------------------------------
$script:ScriptVersion = '2.0.1'
$script:RepoOwner   = 'genrihx2'
$script:RepoName    = 'ldplayer-Manager-CLI-Menu'
$script:RepoBranch  = 'main'
$script:UpdateNotice = $null

$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$script:ConfigPath = Join-Path $scriptRoot 'LDManager.config.json'
$script:LdPath  = $null
$script:AdbPath = $null

# ---------------------------------------------------------------------------
# Пул правдоподобных пар "производитель/модель"
# ---------------------------------------------------------------------------
$script:DevicePool = @(
    @{ Manufacturer = 'samsung'; Model = 'SM-G991B' },
    @{ Manufacturer = 'samsung'; Model = 'SM-A525F' },
    @{ Manufacturer = 'samsung'; Model = 'SM-G975F' },
    @{ Manufacturer = 'Xiaomi';  Model = 'M2101K6G' },
    @{ Manufacturer = 'Xiaomi';  Model = 'Redmi Note 8' },
    @{ Manufacturer = 'HUAWEI';  Model = 'ELE-L29' },
    @{ Manufacturer = 'HUAWEI';  Model = 'PRA-LX1' },
    @{ Manufacturer = 'Google';  Model = 'Pixel 4' },
    @{ Manufacturer = 'Google';  Model = 'Pixel 6' },
    @{ Manufacturer = 'OnePlus'; Model = 'GM1913' }
)

# ---------------------------------------------------------------------------
# Пресеты SIM-стран: ISO, страна, MCC, MNC, оператор, телефонный код
# Применяются ТОЛЬКО к локальным виртуальным инстансам (через IMSI/номер).
# ---------------------------------------------------------------------------
$script:SimPresets = @(
    [pscustomobject]@{ Iso='RU'; Country='Россия';          Mcc='250'; Mnc='01';  Operator='MTS';          Dial='7' },
    [pscustomobject]@{ Iso='UA'; Country='Украина';         Mcc='255'; Mnc='03';  Operator='Kyivstar';     Dial='380' },
    [pscustomobject]@{ Iso='BY'; Country='Беларусь';        Mcc='257'; Mnc='01';  Operator='A1';           Dial='375' },
    [pscustomobject]@{ Iso='KZ'; Country='Казахстан';       Mcc='401'; Mnc='01';  Operator='Kcell';        Dial='7' },
    [pscustomobject]@{ Iso='UZ'; Country='Узбекистан';      Mcc='434'; Mnc='01';  Operator='Ucell';        Dial='998' },
    [pscustomobject]@{ Iso='GE'; Country='Грузия';          Mcc='282'; Mnc='05';  Operator='Magti';        Dial='995' },
    [pscustomobject]@{ Iso='AM'; Country='Армения';         Mcc='283'; Mnc='01';  Operator='Viva-MTS';     Dial='374' },
    [pscustomobject]@{ Iso='AZ'; Country='Азербайджан';     Mcc='400'; Mnc='01';  Operator='Azercell';     Dial='994' },
    [pscustomobject]@{ Iso='US'; Country='США';             Mcc='310'; Mnc='260'; Operator='T-Mobile';     Dial='1' },
    [pscustomobject]@{ Iso='GB'; Country='Великобритания';  Mcc='234'; Mnc='30';  Operator='EE';           Dial='44' },
    [pscustomobject]@{ Iso='DE'; Country='Германия';        Mcc='262'; Mnc='01';  Operator='Telekom';      Dial='49' },
    [pscustomobject]@{ Iso='FR'; Country='Франция';         Mcc='208'; Mnc='01';  Operator='Orange';       Dial='33' },
    [pscustomobject]@{ Iso='ES'; Country='Испания';         Mcc='214'; Mnc='01';  Operator='Vodafone';     Dial='34' },
    [pscustomobject]@{ Iso='IT'; Country='Италия';          Mcc='222'; Mnc='01';  Operator='TIM';          Dial='39' },
    [pscustomobject]@{ Iso='PL'; Country='Польша';          Mcc='260'; Mnc='02';  Operator='Orange';       Dial='48' },
    [pscustomobject]@{ Iso='PT'; Country='Португалия';      Mcc='268'; Mnc='01';  Operator='Vodafone';     Dial='351' },
    [pscustomobject]@{ Iso='NL'; Country='Нидерланды';      Mcc='204'; Mnc='04';  Operator='Vodafone';     Dial='31' },
    [pscustomobject]@{ Iso='BE'; Country='Бельгия';         Mcc='206'; Mnc='01';  Operator='Proximus';     Dial='32' },
    [pscustomobject]@{ Iso='AT'; Country='Австрия';         Mcc='232'; Mnc='01';  Operator='A1';           Dial='43' },
    [pscustomobject]@{ Iso='CH'; Country='Швейцария';       Mcc='228'; Mnc='01';  Operator='Swisscom';     Dial='41' },
    [pscustomobject]@{ Iso='CZ'; Country='Чехия';           Mcc='230'; Mnc='02';  Operator='O2';           Dial='420' },
    [pscustomobject]@{ Iso='SK'; Country='Словакия';        Mcc='231'; Mnc='01';  Operator='Orange SK';    Dial='421' },
    [pscustomobject]@{ Iso='HU'; Country='Венгрия';         Mcc='216'; Mnc='01';  Operator='Magyar Telekom'; Dial='36' },
    [pscustomobject]@{ Iso='RO'; Country='Румыния';         Mcc='226'; Mnc='01';  Operator='Orange';       Dial='40' },
    [pscustomobject]@{ Iso='BG'; Country='Болгария';        Mcc='284'; Mnc='05';  Operator='Vivacom';      Dial='359' },
    [pscustomobject]@{ Iso='GR'; Country='Греция';          Mcc='202'; Mnc='05';  Operator='Vodafone';     Dial='30' },
    [pscustomobject]@{ Iso='SE'; Country='Швеция';          Mcc='240'; Mnc='01';  Operator='Telia';        Dial='46' },
    [pscustomobject]@{ Iso='NO'; Country='Норвегия';        Mcc='242'; Mnc='01';  Operator='Telenor';      Dial='47' },
    [pscustomobject]@{ Iso='FI'; Country='Финляндия';       Mcc='244'; Mnc='05';  Operator='Elisa';        Dial='358' },
    [pscustomobject]@{ Iso='DK'; Country='Дания';           Mcc='238'; Mnc='01';  Operator='TDC';          Dial='45' },
    [pscustomobject]@{ Iso='LT'; Country='Литва';           Mcc='246'; Mnc='02';  Operator='Bite';         Dial='370' },
    [pscustomobject]@{ Iso='LV'; Country='Латвия';          Mcc='247'; Mnc='01';  Operator='LMT';          Dial='371' },
    [pscustomobject]@{ Iso='EE'; Country='Эстония';         Mcc='248'; Mnc='02';  Operator='Telia';        Dial='372' },
    [pscustomobject]@{ Iso='TR'; Country='Турция';          Mcc='286'; Mnc='01';  Operator='Turkcell';     Dial='90' },
    [pscustomobject]@{ Iso='IL'; Country='Израиль';         Mcc='425'; Mnc='01';  Operator='Partner';      Dial='972' },
    [pscustomobject]@{ Iso='AE'; Country='ОАЭ';             Mcc='424'; Mnc='02';  Operator='Etisalat';     Dial='971' },
    [pscustomobject]@{ Iso='SA'; Country='Саудовская Арабия'; Mcc='420'; Mnc='01'; Operator='STC';        Dial='966' },
    [pscustomobject]@{ Iso='EG'; Country='Египет';          Mcc='602'; Mnc='02';  Operator='Vodafone';     Dial='20' },
    [pscustomobject]@{ Iso='IN'; Country='Индия';           Mcc='404'; Mnc='45';  Operator='Airtel';       Dial='91' },
    [pscustomobject]@{ Iso='ID'; Country='Индонезия';       Mcc='510'; Mnc='10';  Operator='Telkomsel';    Dial='62' },
    [pscustomobject]@{ Iso='TH'; Country='Таиланд';         Mcc='520'; Mnc='01';  Operator='AIS';          Dial='66' },
    [pscustomobject]@{ Iso='VN'; Country='Вьетнам';         Mcc='452'; Mnc='04';  Operator='Viettel';      Dial='84' },
    [pscustomobject]@{ Iso='PH'; Country='Филиппины';       Mcc='515'; Mnc='03';  Operator='Smart';        Dial='63' },
    [pscustomobject]@{ Iso='MY'; Country='Малайзия';        Mcc='502'; Mnc='12';  Operator='Maxis';        Dial='60' },
    [pscustomobject]@{ Iso='SG'; Country='Сингапур';        Mcc='525'; Mnc='01';  Operator='Singtel';      Dial='65' },
    [pscustomobject]@{ Iso='JP'; Country='Япония';          Mcc='440'; Mnc='10';  Operator='NTT Docomo';   Dial='81' },
    [pscustomobject]@{ Iso='KR'; Country='Корея';           Mcc='450'; Mnc='05';  Operator='SK Telecom';   Dial='82' },
    [pscustomobject]@{ Iso='CN'; Country='Китай';           Mcc='460'; Mnc='00';  Operator='China Mobile'; Dial='86' },
    [pscustomobject]@{ Iso='BR'; Country='Бразилия';        Mcc='724'; Mnc='06';  Operator='Vivo';         Dial='55' },
    [pscustomobject]@{ Iso='MX'; Country='Мексика';         Mcc='334'; Mnc='020'; Operator='Telcel';       Dial='52' },
    [pscustomobject]@{ Iso='AR'; Country='Аргентина';       Mcc='722'; Mnc='310'; Operator='Claro';        Dial='54' },
    [pscustomobject]@{ Iso='CA'; Country='Канада';          Mcc='302'; Mnc='720'; Operator='Rogers';       Dial='1' },
    [pscustomobject]@{ Iso='AU'; Country='Австралия';       Mcc='505'; Mnc='01';  Operator='Telstra';      Dial='61' }
)

# ---------------------------------------------------------------------------
# Вспомогательные функции вывода
# ---------------------------------------------------------------------------
function Write-Ok   { param([string]$Text) Write-Host "[OK] $Text" -ForegroundColor Green }
function Write-Note { param([string]$Text) Write-Host "[!!] $Text" -ForegroundColor Yellow }
function Write-Fail { param([string]$Text) Write-Host "[X]  $Text" -ForegroundColor Red }

function Wait-Enter {
    Write-Host ''
    [void](Read-Host 'Нажмите Enter для продолжения')
}

function Confirm-Action {
    param([string]$Question = 'Продолжить?')
    $a = (Read-Host "$Question (y/д = да)").Trim().ToLower()
    return ($a -eq 'y' -or $a -eq 'yes' -or $a -eq 'д' -or $a -eq 'да')
}

function Show-Banner {
    Clear-Host
    Write-Host ''
    Write-Host '  +==========================================================+' -ForegroundColor Cyan
    Write-Host '  |   LDManager v2.0 - меню управления LDPlayer (ldconsole)   |' -ForegroundColor Cyan
    Write-Host '  |   Только для локальных инстансов на вашем компьютере      |' -ForegroundColor DarkCyan
    Write-Host '  +==========================================================+' -ForegroundColor Cyan
    Write-Host ''
}

function Write-Title {
    param([string]$Text)
    Write-Host ''
    Write-Host "===== $Text =====" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# Конфигурация (JSON рядом со скриптом)
# ---------------------------------------------------------------------------
function Get-AppConfig {
    if (Test-Path $script:ConfigPath) {
        try { return Get-Content $script:ConfigPath -Raw | ConvertFrom-Json } catch { return $null }
    }
    return $null
}

function Save-ManagerConfig {
    param(
        [string]$LdConsolePath,
        [string]$AdbPath,
        [string]$GithubTokenEnc,
        [string]$SieveApiKeyEnc,
        [object]$SieveRuns
    )

    $cfg = Get-AppConfig
    if ($null -eq $cfg) { $cfg = New-Object PSObject }

    if ($LdConsolePath)  { $cfg | Add-Member -Force -NotePropertyName 'ldconsolePath'  -NotePropertyValue $LdConsolePath }
    if ($AdbPath)        { $cfg | Add-Member -Force -NotePropertyName 'adbPath'         -NotePropertyValue $AdbPath }
    if ($PSBoundParameters.ContainsKey('GithubTokenEnc')) {
        $cfg | Add-Member -Force -NotePropertyName 'githubTokenEnc' -NotePropertyValue $GithubTokenEnc
    }
    if ($PSBoundParameters.ContainsKey('SieveApiKeyEnc')) {
        $cfg | Add-Member -Force -NotePropertyName 'sieveApiKeyEnc' -NotePropertyValue $SieveApiKeyEnc
    }
    if ($PSBoundParameters.ContainsKey('SieveRuns')) {
        $cfg | Add-Member -Force -NotePropertyName 'sieveRuns' -NotePropertyValue $SieveRuns
    }
    try {
        $cfg | ConvertTo-Json -Depth 10 | Set-Content -Path $script:ConfigPath -Encoding UTF8
    } catch {
        Write-Note "Не удалось сохранить конфиг: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# Поиск ldconsole.exe / adb.exe
# ---------------------------------------------------------------------------
function Resolve-LDConsolePath {
    $cfg = Get-AppConfig
    if ($cfg -and $cfg.ldconsolePath -and (Test-Path $cfg.ldconsolePath)) {
        # В старых конфигах мог сохраниться неверный путь (например, dnplayer.exe
        # вместо ldconsole.exe) — проверяем имя файла, иначе берём ldconsole.exe
        # из той же папки, а при неудаче ищем заново.
        if ((Split-Path $cfg.ldconsolePath -Leaf) -ieq 'ldconsole.exe') { return $cfg.ldconsolePath }
        $sibling = Join-Path (Split-Path $cfg.ldconsolePath -Parent) 'ldconsole.exe'
        if (Test-Path $sibling) { return $sibling }
    }

    $candidates = New-Object System.Collections.Generic.List[string]

    # 1) путь из запущенного процесса эмулятора
    try {
        $proc = Get-Process -Name 'dnplayer','LdVBoxHeadless','Ld9BoxHeadless','LdBoxHeadless' -ErrorAction SilentlyContinue |
                Where-Object { $_.Path } | Select-Object -First 1
        if ($proc) {
            $dir = Split-Path $proc.Path -Parent
            $candidates.Add((Join-Path $dir 'ldconsole.exe'))
            $candidates.Add((Join-Path (Split-Path $dir -Parent) 'ldconsole.exe'))
        }
    } catch { }

    # 2) реестр (установленные программы)
    try {
        $regPaths = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )
        $apps = Get-ItemProperty $regPaths -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -like '*LDPlayer*' -or $_.DisplayName -like '*Leidian*' }
        foreach ($a in $apps) {
            if ($a.InstallLocation) { $candidates.Add((Join-Path $a.InstallLocation 'ldconsole.exe')) }
            if ($a.DisplayIcon) {
                $icon = ($a.DisplayIcon -replace ',\d+$','')
                if ($icon -and (Test-Path $icon)) {
                    # DisplayIcon часто указывает на dnplayer.exe (GUI), а не на ldconsole.exe:
                    # ищем ldconsole.exe в той же папке.
                    if ((Split-Path $icon -Leaf) -ieq 'ldconsole.exe') {
                        $candidates.Add($icon)
                    } else {
                        $candidates.Add((Join-Path (Split-Path $icon -Parent) 'ldconsole.exe'))
                    }
                }
            }
        }
    } catch { }

    # 3) типичные пути установки (включая C:\LDPlayer\LDPlayer14)
    foreach ($drive in @('C','D','E','F','G')) {
        foreach ($sub in @(
            'LDPlayer\LDPlayer14','LDPlayer\LDPlayer9','LDPlayer\LDPlayer4',
            'LDPlayer\LDPlayer64','LDPlayer\dnplayer2',
            'Program Files\LDPlayer\LDPlayer14','Program Files\LDPlayer\LDPlayer9',
            'Program Files (x86)\LDPlayer\LDPlayer9','Program Files\LDPlayer'
        )) {
            $candidates.Add("${drive}:\$sub\ldconsole.exe")
        }
    }

    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { return $c }
    }
    return $null
}

function Get-AdbExePath {
    if ($script:AdbPath -and (Test-Path $script:AdbPath)) { return $script:AdbPath }

    $candidates = New-Object System.Collections.Generic.List[string]
    if ($script:LdPath) {
        $ldDir = Split-Path $script:LdPath -Parent
        $candidates.Add((Join-Path $ldDir 'adb.exe'))
    }
    # известные пути (включая C:\LDPlayer\LDPlayer14\adb.exe)
    foreach ($drive in @('C','D','E','F','G')) {
        foreach ($sub in @(
            'LDPlayer\LDPlayer14\adb.exe','LDPlayer\LDPlayer9\adb.exe','LDPlayer\LDPlayer4\adb.exe'
        )) {
            $candidates.Add("${drive}:\$sub")
        }
    }
    $sdkAdb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
    $candidates.Add($sdkAdb)

    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { $script:AdbPath = $c; return $c }
    }

    $cmd = Get-Command 'adb.exe' -ErrorAction SilentlyContinue
    if ($cmd) { $script:AdbPath = $cmd.Source; return $script:AdbPath }
    return $null
}

# ---------------------------------------------------------------------------
# Обёртка над ldconsole.exe
# ---------------------------------------------------------------------------
function Invoke-LDConsole {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    if (-not $script:LdPath -or -not (Test-Path $script:LdPath)) {
        throw 'ldconsole.exe не найден. Укажите путь в меню «Настройки».'
    }
    try {
        $output = & $script:LdPath @Arguments 2>&1
    } catch {
        Write-Fail "Ошибка запуска ldconsole: $($_.Exception.Message)"
        return $null
    }
    return ($output | Out-String).Trim()
}

function Get-LDInstances {
    if (-not $script:LdPath) { return @() }

    $raw = Invoke-LDConsole -Arguments @('list2')
    $runningRaw = Invoke-LDConsole -Arguments @('runninglist')

    $runningNames = @()
    if ($runningRaw) {
        foreach ($l in ($runningRaw -split "\r?\n")) {
            $l = $l.Trim()
            if (-not $l) { continue }
            $f = $l.Split(',')
            if ($f.Count -ge 2) { $runningNames += $f[1].Trim() }
        }
    }

    $result = @()
    if ($raw) {
        foreach ($line in ($raw -split "\r?\n")) {
            $line = $line.Trim()
            if (-not $line) { continue }
            $f = $line.Split(',')
            if ($f.Count -lt 5) { continue }

            $idx = 0
            if (-not [int]::TryParse($f[0].Trim(), [ref]$idx)) { continue }

            $name = $f[1].Trim()
            $running = $false
            if ($runningNames -contains $name) {
                $running = $true
            } elseif ($runningNames.Count -eq 0) {
                $r = 0
                if ([int]::TryParse($f[4].Trim(), [ref]$r)) { $running = ($r -eq 1) }
            }

            $pidI = 0
            if ($f.Count -gt 5) { [void][int]::TryParse($f[5].Trim(), [ref]$pidI) }

            $w = 0; $h = 0; $dpi = 0
            if ($f.Count -gt 7) { [void][int]::TryParse($f[7].Trim(), [ref]$w) }
            if ($f.Count -gt 8) { [void][int]::TryParse($f[8].Trim(), [ref]$h) }
            if ($f.Count -gt 9) { [void][int]::TryParse($f[9].Trim(), [ref]$dpi) }
            $res = if ($w -gt 0) { '{0}x{1}@{2}' -f $w, $h, $dpi } else { '-' }

            $result += [pscustomobject]@{
                Index      = $idx
                Name       = $name
                Running    = $running
                Pid        = $pidI
                Resolution = $res
            }
        }
    }
    return $result
}

function Show-InstanceTable {
    param([object[]]$Instances)

    if (-not $Instances -or $Instances.Count -eq 0) {
        Write-Note 'Инстансы не найдены. Проверьте установку LDPlayer и путь к ldconsole.exe (меню Настройки).'
        return
    }

    $hdr = "  {0,-6}{1,-28}{2,-8}{3,-16}{4}" -f 'Index', 'Имя', 'Статус', 'Разрешение', 'PID'
    Write-Host $hdr -ForegroundColor White
    Write-Host ("  " + ("-" * ($hdr.Length + 10))) -ForegroundColor DarkGray

    foreach ($i in $Instances) {
        $status = if ($i.Running) { '[RUN]' } else { '[OFF]' }
        $color  = if ($i.Running) { 'Green' } else { 'DarkGray' }
        $line   = "  {0,-6}{1,-28}{2,-8}{3,-16}{4}" -f $i.Index, $i.Name, $status, $i.Resolution, $i.Pid
        Write-Host $line -ForegroundColor $color
    }
}

function Select-LDInstance {
    param(
        [switch]$RequireStopped,
        [switch]$RequireRunning,
        [string]$Purpose = 'выберите инстанс'
    )

    $instances = Get-LDInstances
    if (-not $instances -or $instances.Count -eq 0) {
        Write-Note 'Инстансы не найдены.'
        Wait-Enter
        return $null
    }

    Write-Title "Инстансы ($Purpose)"
    Show-InstanceTable -Instances $instances
    Write-Host ''

    $raw = (Read-Host 'Введите Index инстанса (Enter - отмена)').Trim()
    if (-not $raw) { return $null }

    $idx = 0
    if (-not [int]::TryParse($raw, [ref]$idx)) {
        Write-Fail 'Введите число.'
        Wait-Enter
        return $null
    }

    $found = $instances | Where-Object { $_.Index -eq $idx } | Select-Object -First 1
    if (-not $found) {
        Write-Fail "Инстанс с Index $idx не найден."
        Wait-Enter
        return $null
    }
    if ($RequireStopped -and $found.Running) {
        Write-Note 'Инстанс запущен. Эта операция требует остановленного инстанса.'
        Wait-Enter
        return $null
    }
    if ($RequireRunning -and -not $found.Running) {
        Write-Note 'Инстанс не запущен. Эта операция требует запущенного инстанса.'
        Wait-Enter
        return $null
    }
    return $found
}

# ---------------------------------------------------------------------------
# Конфиг инстанса (vms\leidianN\config.ini) и команда modify
# ---------------------------------------------------------------------------
function Get-LDInstanceIdentity {
    param([int]$Index)

    $base = Split-Path $script:LdPath -Parent
    $iniCandidates = @(
        (Join-Path $base "vms\leidian$Index\config.ini"),
        (Join-Path $base "vms\dnplayer$Index\config.ini")
    )

    foreach ($ini in $iniCandidates) {
        if (Test-Path $ini) {
            $map = @{}
            foreach ($line in (Get-Content $ini)) {
                if ($line -match '^\s*([^=;]+?)\s*=\s*(.*?)\s*$') {
                    $map[$matches[1].ToLower()] = $matches[2]
                }
            }
            return [pscustomobject]@{
                Ini          = $ini
                Imei         = $map['imei']
                Imsi         = $map['imsi']
                SimSerial    = $map['simserial']
                AndroidId    = $map['androidid']
                Mac          = $map['mac']
                Manufacturer = $map['manufacturer']
                Model        = $map['model']
                PhoneNumber  = $map['pnumber']
            }
        }
    }
    return $null
}

function Invoke-LDModify {
    param([int]$Index, [hashtable]$Props, [switch]$Quiet)

    $ldArgs = @('modify','--index',[string]$Index)
    foreach ($key in $Props.Keys) {
        $ldArgs += ('--' + $key)
        $ldArgs += [string]$Props[$key]
    }
    $out = Invoke-LDConsole -Arguments $ldArgs
    if (-not $Quiet) {
        if ($out) { Write-Host $out }
        Write-Ok 'Команда modify выполнена.'
    }
}

function Offer-Restart {
    param([object]$Instance)
    if ($Instance.Running) {
        if (Confirm-Action "Перезапустить инстанс '$($Instance.Name)' сейчас, чтобы применить изменения?") {
            [void](Invoke-LDConsole -Arguments @('quit','--index',[string]$Instance.Index))
            Start-Sleep -Seconds 2
            [void](Invoke-LDConsole -Arguments @('launch','--index',[string]$Instance.Index))
            Write-Ok 'Инстанс перезапущен.'
        } else {
            Write-Note 'Изменения применятся при следующем запуске инстанса.'
        }
    } else {
        Write-Note 'Инстанс не запущен — изменения применятся при следующем запуске.'
    }
}

# ---------------------------------------------------------------------------
# ADB-ядро
# ---------------------------------------------------------------------------
function Get-AdbTargetPort {
    param([int]$Index)
    # Классическая формула LDPlayer: adb-порт = 5555 + index * 2
    return 5555 + (2 * $Index)
}

$script:AdbPortCache = @{}

function Test-TcpPortOpen {
    param([int]$Port)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(150, $false)) { return $false }
        $client.EndConnect($iar)
        return $true
    } catch {
        return $false
    } finally {
        try { $client.Close() } catch { }
    }
}

function Get-AdbPortFromConfig {
    param([int]$Index)
    if (-not $script:LdPath) { return $null }
    $base = Split-Path $script:LdPath -Parent
    foreach ($vm in @("vms\leidian$Index", "vms\dnplayer$Index")) {
        $ini = Join-Path $base ("$vm\config.ini")
        if (Test-Path $ini) {
            foreach ($line in (Get-Content $ini)) {
                if ($line -match '^\s*adb[_\.]?port\s*=\s*(\d+)') { return [int]$matches[1] }
            }
        }
    }
    return $null
}

function Connect-AdbTarget {
    # Пробует adb connect и подтверждает результат через 'adb devices'.
    # Если инстанс виден как offline (ADB-рукопожатие не завершилось) — перезапускает
    # adb-сервер и пробует снова.
    param([int]$Port, [int]$Retries = 2)
    $target = "127.0.0.1:$Port"

    for ($attempt = 0; $attempt -le $Retries; $attempt++) {
        $out = Invoke-Adb -Arguments @('connect', $target)
        if ($out) { Write-Host $out -ForegroundColor DarkGray }

        $pattern = [regex]::Escape($target) + '\s+device'
        $dev = Invoke-Adb -Arguments @('devices')
        if ($dev -and $dev -match $pattern) { return $target }

        if ($dev -match [regex]::Escape($target) + '\s+offline') {
            Write-Note 'Инстанс виден как offline — перезапускаю adb-сервер и пробую снова...'
            [void](Invoke-Adb -Arguments @('kill-server'))
            Start-Sleep -Seconds 1
            [void](Invoke-Adb -Arguments @('start-server'))
            Start-Sleep -Seconds 2
            continue
        }

        # Первая попытка не удалась, но не offline: короткая пауза (ADB мог не успеть) и повтор
        if ($attempt -lt $Retries) { Start-Sleep -Seconds 2 }
    }
    return $null
}

function Invoke-Adb {
    param([string[]]$Arguments)
    $adb = Get-AdbExePath
    if (-not $adb) {
        Write-Fail 'adb.exe не найден (ни в папке LDPlayer, ни в PATH).'
        return $null
    }
    try {
        $out = & $adb @Arguments 2>&1
    } catch {
        Write-Fail "Ошибка adb: $($_.Exception.Message)"
        return $null
    }
    return ($out | Out-String).Trim()
}

function Select-AdbTarget {
    # Выбирает ЗАПУЩЕННЫЙ инстанс и возвращает "127.0.0.1:<порт>" после adb connect
    $inst = Select-LDInstance -RequireRunning -Purpose 'ADB (нужен запущенный инстанс)'
    if (-not $inst) { return $null }
    return Resolve-AdbTarget -Index $inst.Index -Name $inst.Name
}

function Resolve-AdbTarget {
    # Возвращает "127.0.0.1:<порт>" работающего инстанса:
    # кэш -> config.ini -> формулы -> скан 5555-5585 -> ручной ввод
    param([int]$Index, [string]$Name)

    # 1) кэш предыдущего успешного подключения
    if ($script:AdbPortCache.ContainsKey($Index)) {
        $t = Connect-AdbTarget -Port $script:AdbPortCache[$Index]
        if ($t) { return $t }
        $script:AdbPortCache.Remove($Index)
    }

    # 2) порт из config.ini инстанса и известные формулы
    $candidates = New-Object System.Collections.Generic.List[int]
    $cfgPort = Get-AdbPortFromConfig -Index $Index
    if ($cfgPort) { $candidates.Add($cfgPort) }
    $candidates.Add(5555 + (2 * $Index))   # формула 5555 + index*2
    $candidates.Add(5554 + (2 * $Index))   # вариант 5554 + index*2

    foreach ($p in $candidates) {
        if (-not (Test-TcpPortOpen -Port $p)) { continue }
        $t = Connect-AdbTarget -Port $p
        if ($t) { $script:AdbPortCache[$Index] = $p; return $t }
    }

    # 3) скан диапазона портов
    Write-Note 'Известные порты не ответили. Сканирую 5555-5585...'
    for ($p = 5555; $p -le 5585; $p++) {
        if (-not (Test-TcpPortOpen -Port $p)) { continue }
        $t = Connect-AdbTarget -Port $p
        if ($t) {
            Write-Ok "ADB-порт найден: $p"
            $script:AdbPortCache[$Index] = $p
            return $t
        }
    }

    # 4) не получилось — подсказки и ручной ввод
    Write-Fail "Не удалось автоматически подключиться к инстансу [$Index] $Name."
    Write-Host '  1) В LDPlayer: Настройки -> Другие настройки -> «Отладка по ADB» должна быть ВКЛЮЧЕНА.'
    Write-Host '  2) Убедитесь, что инстанс полностью загрузился (не на экране логотипа).'
    Write-Host '  3) Можно указать порт вручную (виден в LDPlayer: Настройки -> Другие настройки).'
    $manual = (Read-Host 'Порт вручную (Enter - отмена)').Trim()
    if ($manual -match '^\d{4,5}$') {
        $t = Connect-AdbTarget -Port ([int]$manual)
        if ($t) {
            $script:AdbPortCache[$Index] = [int]$manual
            Write-Ok "Подключено: $t"
            return $t
        }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Генераторы случайных идентификаторов и валидаторы
# (используются ТОЛЬКО для локальных виртуальных инстансов — см. дисклеймер)
# ---------------------------------------------------------------------------
function New-RandomDigits {
    param([int]$Count)
    return (-join (1..$Count | ForEach-Object { Get-Random -Minimum 0 -Maximum 10 }))
}

function Get-LuhnCheckDigit {
    param([string]$Digits14)
    $sum = 0
    $double = $true
    for ($i = $Digits14.Length - 1; $i -ge 0; $i--) {
        $d = [int][char]$Digits14[$i] - 48
        if ($double) { $d *= 2; if ($d -gt 9) { $d -= 9 } }
        $sum += $d
        $double = -not $double
    }
    return ((10 - ($sum % 10)) % 10)
}

function Test-Luhn {
    param([string]$Digits)
    if ($Digits -notmatch '^\d{15}$') { return $false }
    $sum = 0
    for ($i = 0; $i -lt 15; $i++) {
        $d = [int][char]$Digits[$i] - 48
        if ((15 - $i) % 2 -eq 0) { $d *= 2; if ($d -gt 9) { $d -= 9 } }
        $sum += $d
    }
    return ($sum % 10 -eq 0)
}

function New-RandomImei {
    # 14 случайных цифр (префикс 35) + контрольная цифра по алгоритму Луна
    $body = '35' + (New-RandomDigits -Count 12)
    return $body + [string](Get-LuhnCheckDigit -Digits14 $body)
}

function New-RandomImsi {
    $mcc = @('250','255','257','310','425','404','460','204','262','222') | Get-Random
    return $mcc + (New-RandomDigits -Count 12)
}

function New-RandomImsiForMccMnc {
    param([string]$Mcc, [string]$Mnc)
    $rest = 15 - $Mcc.Length - $Mnc.Length
    if ($rest -lt 7) { $rest = 7 }
    return $Mcc + $Mnc + (New-RandomDigits -Count $rest)
}

function New-RandomIccid {
    return '89' + (New-RandomDigits -Count 18)
}

function New-RandomAndroidId {
    return ('{0:x4}{1:x4}{2:x4}{3:x4}' -f `
        (Get-Random -Minimum 0 -Maximum 65536),
        (Get-Random -Minimum 0 -Maximum 65536),
        (Get-Random -Minimum 0 -Maximum 65536),
        (Get-Random -Minimum 0 -Maximum 65536))
}

function New-RandomMac {
    # Первый октет: unicast + locally administered (младшие биты 0b10)
    $first = ((Get-Random -Minimum 0 -Maximum 64) * 4) + 2
    $octets = @($first)
    foreach ($n in 1..5) { $octets += (Get-Random -Minimum 0 -Maximum 256) }
    return (($octets | ForEach-Object { '{0:x2}' -f $_ }) -join '')
}

function New-RandomPhone {
    return '7' + (New-RandomDigits -Count 10)
}

function New-RandomPhoneForDial {
    param([string]$Dial)
    $digits = if ($Dial.Length -ge 2) { Get-Random -Minimum 7 -Maximum 9 } else { 10 }
    return $Dial + (New-RandomDigits -Count $digits)
}

function New-RandomDeviceModel {
    return ($script:DevicePool | Get-Random)
}

function Test-ImeiInput {
    param([string]$s)
    if ($s -match '^\d{15}$') { return (Test-Luhn -Digits $s) }
    if ($s -match '^\d{14}$') { return $true }  # контрольная цифра будет добавлена
    return $false
}

function Normalize-ImeiInput {
    param([string]$s)
    if ($s.Length -eq 14) { return $s + [string](Get-LuhnCheckDigit -Digits14 $s) }
    return $s
}

function Read-Validated {
    param([string]$Prompt, [scriptblock]$Validator, [string]$FailText)
    while ($true) {
        $v = (Read-Host $Prompt).Trim()
        if (-not $v) { return $null }   # пустой ввод = отмена
        if (& $Validator $v) { return $v }
        Write-Fail $FailText
    }
}

# ---------------------------------------------------------------------------
# Пресеты SIM: отображение и поиск по IMSI
# ---------------------------------------------------------------------------
function Get-SimPresetByImsiPrefix {
    param([string]$Imsi)
    if ([string]::IsNullOrWhiteSpace($Imsi)) { return $null }
    foreach ($p in $script:SimPresets) {
        if ($Imsi.StartsWith($p.Mcc + $p.Mnc)) { return $p }
    }
    return $null
}

function Show-SimPresetTable {
    Write-Title ("SIM-пресеты ({0} стран)" -f $script:SimPresets.Count)
    $hdr = "  {0,-4}{1,-5}{2,-20}{3,-10}{4,-16}{5}" -f '#', 'ISO', 'Страна', 'MCC+MNC', 'Оператор', 'Тел.код'
    Write-Host $hdr -ForegroundColor White
    Write-Host ("  " + ("-" * 70)) -ForegroundColor DarkGray
    $n = 0
    foreach ($p in $script:SimPresets) {
        $n++
        $line = "  {0,-4}{1,-5}{2,-20}{3,-10}{4,-16}{5}" -f $n, $p.Iso, $p.Country, ($p.Mcc + $p.Mnc), $p.Operator, ('+' + $p.Dial)
        Write-Host $line
    }
}

# ---------------------------------------------------------------------------
# Win32: управление окнами эмулятора (показать/скрыть)
# ---------------------------------------------------------------------------
if (-not ('LDM.Win32' -as [type])) {
    Add-Type -Namespace LDM -Name Win32 -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
'@ -ErrorAction SilentlyContinue
}

function Get-EmulatorWindows {
    $res = @()
    foreach ($p in (Get-Process -Name 'dnplayer' -ErrorAction SilentlyContinue)) {
        if ($p.MainWindowHandle -ne [IntPtr]::Zero) {
            $vis = $false
            try { $vis = [LDM.Win32]::IsWindowVisible($p.MainWindowHandle) } catch { }
            $res += [pscustomobject]@{
                Pid     = $p.Id
                Title   = $p.MainWindowTitle
                Handle  = $p.MainWindowHandle
                Visible = $vis
            }
        }
    }
    return $res
}

# ===========================================================================
# ДЕЙСТВИЯ: инстансы
# ===========================================================================
function Start-LDInstance {
    $inst = Select-LDInstance -Purpose 'запуск'
    if (-not $inst) { return }
    if ($inst.Running) { Write-Note 'Инстанс уже запущен.'; Wait-Enter; return }
    Write-Host "Запуск инстанса [$($inst.Index)] $($inst.Name)..."
    [void](Invoke-LDConsole -Arguments @('launch','--index',[string]$inst.Index))
    Write-Ok 'Команда запуска отправлена.'
    Wait-Enter
}

function Stop-LDInstance {
    $inst = Select-LDInstance -Purpose 'остановка'
    if (-not $inst) { return }
    [void](Invoke-LDConsole -Arguments @('quit','--index',[string]$inst.Index))
    Write-Ok "Инстанс [$($inst.Index)] $($inst.Name): команда остановки отправлена."
    Wait-Enter
}

function Restart-LDInstance {
    $inst = Select-LDInstance -Purpose 'перезапуск'
    if (-not $inst) { return }
    [void](Invoke-LDConsole -Arguments @('reboot','--index',[string]$inst.Index))
    Write-Ok "Инстанс [$($inst.Index)] $($inst.Name): команда перезапуска отправлена."
    Wait-Enter
}

function Stop-AllLDInstances {
    if (-not (Confirm-Action 'Закрыть ВСЕ запущенные инстансы?')) { return }
    [void](Invoke-LDConsole -Arguments @('quitall'))
    Write-Ok 'Команда quitall отправлена.'
    Wait-Enter
}

function New-LDInstance {
    $name = (Read-Host 'Имя нового инстанса (Enter - автоматически)').Trim()
    if ($name) {
        [void](Invoke-LDConsole -Arguments @('add','--name',$name))
        Write-Ok "Создан инстанс '$name'."
    } else {
        [void](Invoke-LDConsole -Arguments @('add'))
        Write-Ok 'Создан инстанс (имя назначено автоматически).'
    }
    Wait-Enter
}

function Copy-LDInstance {
    $src = Select-LDInstance -Purpose 'клонирование (источник)'
    if (-not $src) { return }
    $newName = (Read-Host "Имя клона (Enter - автоматически)").Trim()
    if ($newName) {
        [void](Invoke-LDConsole -Arguments @('copy','--name',$newName,'--from',[string]$src.Index))
        Write-Ok "Создан клон '$newName' из '$($src.Name)'."
    } else {
        [void](Invoke-LDConsole -Arguments @('copy','--from',[string]$src.Index))
        Write-Ok "Создан клон из '$($src.Name)' (имя назначено автоматически)."
    }
    Wait-Enter
}

function Rename-LDInstance {
    $inst = Select-LDInstance -Purpose 'переименование'
    if (-not $inst) { return }
    $title = (Read-Host "Новое имя для '$($inst.Name)'").Trim()
    if (-not $title) { Write-Note 'Отменено.'; Wait-Enter; return }
    [void](Invoke-LDConsole -Arguments @('rename','--index',[string]$inst.Index,'--title',$title))
    Write-Ok "Переименовано: '$($inst.Name)' -> '$title'."
    Wait-Enter
}

function Remove-LDInstance {
    $inst = Select-LDInstance -Purpose 'УДАЛЕНИЕ'
    if (-not $inst) { return }
    Write-Fail "ВНИМАНИЕ: удаление инстанса '$($inst.Name)' НЕОБРАТИМО и стирает все его данные!"
    if (-not (Confirm-Action 'Точно удалить?')) { Write-Note 'Отменено.'; Wait-Enter; return }
    $typed = (Read-Host "Для подтверждения введите Index инстанса ($($inst.Index))").Trim()
    if ($typed -ne [string]$inst.Index) { Write-Note 'Подтверждение не совпало — отменено.'; Wait-Enter; return }
    if ($inst.Running) {
        if (Confirm-Action 'Инстанс запущен. Остановить его перед удалением?') {
            [void](Invoke-LDConsole -Arguments @('quit','--index',[string]$inst.Index))
            Start-Sleep -Seconds 2
        } else {
            Write-Note 'Отменено (нельзя удалить запущенный инстанс).'
            Wait-Enter
            return
        }
    }
    [void](Invoke-LDConsole -Arguments @('remove','--index',[string]$inst.Index))
    Write-Ok "Инстанс '$($inst.Name)' удалён."
    Wait-Enter
}

function Sort-LDWindows {
    [void](Invoke-LDConsole -Arguments @('sortWnd'))
    Write-Ok 'Окна расставлены (sortWnd).'
    Wait-Enter
}

# ===========================================================================
# ДЕЙСТВИЯ: приложения
# ===========================================================================
function Install-LDApp {
    $inst = Select-LDInstance -Purpose 'установка APK'
    if (-not $inst) { return }
    $apk = (Read-Host 'Полный путь к .apk файлу').Trim('"').Trim()
    if (-not $apk) { Write-Note 'Отменено.'; Wait-Enter; return }
    if (-not (Test-Path $apk)) { Write-Fail "Файл не найден: $apk"; Wait-Enter; return }
    $out = Invoke-LDConsole -Arguments @('installapp','--index',[string]$inst.Index,'--filename',$apk)
    if ($out) { Write-Host $out }
    Write-Ok 'Команда installapp выполнена.'
    Wait-Enter
}

function Invoke-LDAppCommand {
    param([ValidateSet('runapp','killapp','uninstallapp')][string]$Command, [string]$Title)
    $inst = Select-LDInstance -Purpose $Title
    if (-not $inst) { return }
    $pkg = (Read-Host 'Имя пакета (например com.example.app)').Trim()
    if (-not $pkg -or $pkg -notmatch '^[\w.]+$') { Write-Fail 'Некорректное имя пакета.'; Wait-Enter; return }
    $out = Invoke-LDConsole -Arguments @($Command,'--index',[string]$inst.Index,'--packagename',$pkg)
    if ($out) { Write-Host $out }
    Write-Ok "Команда $Command выполнена."
    Wait-Enter
}

function Clear-LDAppData {
    # Очистка данных приложения через adb: pm clear
    $target = Select-AdbTarget
    if (-not $target) { return }
    $pkg = (Read-Host 'Имя пакета для очистки данных (pm clear)').Trim()
    if (-not $pkg -or $pkg -notmatch '^[\w.]+$') { Write-Fail 'Некорректное имя пакета.'; Wait-Enter; return }
    Write-Fail "ВНИМАНИЕ: все данные приложения $pkg будут удалены (включая настройки и вход)."
    if (-not (Confirm-Action 'Продолжить?')) { Write-Note 'Отменено.'; Wait-Enter; return }
    $out = Invoke-Adb -Arguments @('-s',$target,'shell','pm','clear',$pkg)
    if ($out) { Write-Host $out }
    Write-Ok 'Данные приложения очищены.'
    Wait-Enter
}

function Force-StopApp {
    $target = Select-AdbTarget
    if (-not $target) { return }
    $pkg = (Read-Host 'Имя пакета для force-stop').Trim()
    if (-not $pkg -or $pkg -notmatch '^[\w.]+$') { Write-Fail 'Некорректное имя пакета.'; Wait-Enter; return }
    $out = Invoke-Adb -Arguments @('-s',$target,'shell','am','force-stop',$pkg)
    if ($out) { Write-Host $out }
    Write-Ok "Force-stop выполнен: $pkg"
    Wait-Enter
}

# ===========================================================================
# ДЕЙСТВИЯ: конфигурация
# ===========================================================================
function Set-LDResolution {
    $inst = Select-LDInstance -RequireStopped -Purpose 'разрешение'
    if (-not $inst) { return }
    Write-Host ''
    Write-Host '  [1] 960x540@240    (низкое)'
    Write-Host '  [2] 1280x720@240   (HD)'
    Write-Host '  [3] 1600x900@280'
    Write-Host '  [4] 1920x1080@480  (FullHD)'
    Write-Host '  [5] Своё значение (w,h,dpi)'
    $c = (Read-Host 'Выбор').Trim()
    switch ($c) {
        '1' { $res = '960,540,240' }
        '2' { $res = '1280,720,240' }
        '3' { $res = '1600,900,280' }
        '4' { $res = '1920,1080,480' }
        '5' {
            $res = (Read-Host 'Введите w,h,dpi (например 1080,1920,480)').Trim()
            if ($res -notmatch '^\d{2,5},\d{2,5},\d{2,3}$') {
                Write-Fail 'Неверный формат. Пример: 1080,1920,480'
                Wait-Enter
                return
            }
        }
        default { Write-Note 'Отменено.'; Wait-Enter; return }
    }
    Invoke-LDModify -Index $inst.Index -Props @{ resolution = $res }
    Offer-Restart -Instance $inst
}

function Set-LDCpuRam {
    $inst = Select-LDInstance -RequireStopped -Purpose 'CPU/RAM'
    if (-not $inst) { return }
    $cpu = (Read-Host 'Ядер CPU (1-4, Enter - не менять)').Trim()
    Write-Host '  Доступные объёмы RAM (MB): 256, 512, 768, 1024, 1536, 2048, 4096, 8192'
    $ram = (Read-Host 'Объём RAM в MB (Enter - не менять)').Trim()
    $props = @{}
    if ($cpu) {
        if ($cpu -notmatch '^[1-4]$') { Write-Fail 'CPU: введите число 1-4.'; Wait-Enter; return }
        $props['cpu'] = $cpu
    }
    if ($ram) {
        if ($ram -notmatch '^(256|512|768|1024|1536|2048|4096|8192)$') {
            Write-Fail 'RAM: допустимы только значения из списка.'
            Wait-Enter
            return
        }
        $props['memory'] = $ram
    }
    if ($props.Count -eq 0) { Write-Note 'Ничего не изменено.'; Wait-Enter; return }
    Invoke-LDModify -Index $inst.Index -Props $props
    Offer-Restart -Instance $inst
}

function Set-LDRoot {
    $inst = Select-LDInstance -Purpose 'root'
    if (-not $inst) { return }
    $on = Confirm-Action 'Включить root? (N = выключить)'
    Invoke-LDModify -Index $inst.Index -Props @{ root = $(if ($on) { '1' } else { '0' }) }
    Offer-Restart -Instance $inst
}

# ===========================================================================
# ДЕЙСТВИЯ: идентификация устройства (приватность / тестирование)
# Применяется ТОЛЬКО к локальным виртуальным инстансам LDPlayer.
# ===========================================================================
function New-RandomIdentityProps {
    $dev = New-RandomDeviceModel
    return @{
        imei         = New-RandomImei
        imsi         = New-RandomImsi
        simserial    = New-RandomIccid
        androidid    = New-RandomAndroidId
        mac          = New-RandomMac
        manufacturer = $dev.Manufacturer
        model        = $dev.Model
        pnumber      = New-RandomPhone
    }
}

function Read-ManualIdentityValue {
    param([ValidateSet('imei','imsi','simserial','androidid','mac','pnumber')][string]$Kind, [string]$Title)
    Write-Host ''
    Write-Host "  [1] Сгенерировать случайное значение (рекомендуется)"
    Write-Host "  [2] Ввести $Title вручную"
    $c = (Read-Host 'Выбор').Trim()
    switch ($c) {
        '1' {
            switch ($Kind) {
                'imei'      { return New-RandomImei }
                'imsi'      { return New-RandomImsi }
                'simserial' { return New-RandomIccid }
                'androidid' { return New-RandomAndroidId }
                'mac'       { return New-RandomMac }
                'pnumber'   { return New-RandomPhone }
            }
        }
        '2' {
            switch ($Kind) {
                'imei' {
                    $v = Read-Validated -Prompt 'IMEI (14 цифр - добавится контрольная, или готовые 15)' `
                        -Validator { param($s) Test-ImeiInput $s } `
                        -FailText 'IMEI должен быть 14 или 15 цифр; 15 цифр должны проходить проверку Луна.'
                    if ($v) { return (Normalize-ImeiInput $v) }
                    return $null
                }
                'imsi' {
                    return Read-Validated -Prompt 'IMSI (15 цифр)' `
                        -Validator { param($s) $s -match '^\d{15}$' } `
                        -FailText 'IMSI должен состоять ровно из 15 цифр.'
                }
                'simserial' {
                    return Read-Validated -Prompt 'SIM serial / ICCID (19-20 цифр)' `
                        -Validator { param($s) $s -match '^\d{19,20}$' } `
                        -FailText 'SIM serial должен состоять из 19-20 цифр.'
                }
                'androidid' {
                    return Read-Validated -Prompt 'Android ID (16 hex-символов)' `
                        -Validator { param($s) $s -match '^[0-9a-fA-F]{16}$' } `
                        -FailText 'Android ID должен состоять из 16 hex-символов (0-9, a-f).'
                }
                'mac' {
                    return Read-Validated -Prompt 'MAC (12 hex-символов, без двоеточий)' `
                        -Validator { param($s) $s -match '^[0-9a-fA-F]{12}$' } `
                        -FailText 'MAC должен состоять из 12 hex-символов.'
                }
                'pnumber' {
                    return Read-Validated -Prompt 'Номер телефона (цифры, 7-15 символов)' `
                        -Validator { param($s) $s -match '^\d{7,15}$' } `
                        -FailText 'Номер должен состоять из 7-15 цифр.'
                }
            }
        }
        default { return $null }
    }
    return $null
}

function Edit-LDSingleIdentity {
    param([object]$Instance, [string]$Kind, [string]$Title)
    $v = Read-ManualIdentityValue -Kind $Kind -Title $Title
    if (-not $v) { Write-Note 'Отменено.'; Wait-Enter; return }
    Write-Host ''
    Write-Host "  Новое значение $Title : $v" -ForegroundColor White
    if (-not (Confirm-Action 'Применить?')) { Write-Note 'Отменено.'; Wait-Enter; return }
    Invoke-LDModify -Index $Instance.Index -Props @{ $Kind = $v }
    Offer-Restart -Instance $Instance
}

function Edit-LDDeviceModel {
    param([object]$Instance)
    $dev = New-RandomDeviceModel
    Write-Host ''
    Write-Host "  Случайная модель: $($dev.Manufacturer) $($dev.Model)" -ForegroundColor White
    $m = (Read-Host 'Производитель/brand (Enter - оставить)').Trim()
    if ($m) { $dev.Manufacturer = $m }
    $mo = (Read-Host 'Модель/model (Enter - оставить)').Trim()
    if ($mo) { $dev.Model = $mo }
    $code = (Read-Host 'Код модели (например SM-G991B, Enter - как model)').Trim()
    if (-not $code) { $code = $dev.Model }
    if (-not (Confirm-Action 'Применить?')) { Write-Note 'Отменено.'; Wait-Enter; return }
    Invoke-LDModify -Index $Instance.Index -Props @{ manufacturer = $dev.Manufacturer; model = $dev.Model }
    Write-Note "Код модели задан как '$code' — ldconsole не имеет отдельного поля; при необходимости поправьте model в config.ini вручную."
    Offer-Restart -Instance $Instance
}

function Set-LDSimCountry {
    param([object]$Instance)
    Show-SimPresetTable
    Write-Host ''
    Write-Host '  [C] Кастом: ввести MCC/MNC/ISO вручную'
    $raw = (Read-Host "Номер пресета (1-$($script:SimPresets.Count)), C - кастом, Enter - отмена").Trim()
    if (-not $raw) { Write-Note 'Отменено.'; Wait-Enter; return }

    $p = $null
    if ($raw -ieq 'c') {
        $mcc = Read-Validated -Prompt 'MCC (3 цифры)' -Validator { param($s) $s -match '^\d{3}$' } -FailText 'MCC — ровно 3 цифры.'
        if (-not $mcc) { Write-Note 'Отменено.'; Wait-Enter; return }
        $mnc = Read-Validated -Prompt 'MNC (2-3 цифры)' -Validator { param($s) $s -match '^\d{2,3}$' } -FailText 'MNC — 2 или 3 цифры.'
        if (-not $mnc) { Write-Note 'Отменено.'; Wait-Enter; return }
        $iso = (Read-Host 'ISO-код страны (например US, Enter - не менять)').Trim().ToUpper()
        $p = [pscustomobject]@{ Iso=$iso; Country='(кастом)'; Mcc=$mcc; Mnc=$mnc; Operator='(кастом)'; Dial='' }
    } else {
        $n = 0
        if (-not [int]::TryParse($raw, [ref]$n) -or $n -lt 1 -or $n -gt $script:SimPresets.Count) {
            Write-Fail 'Неверный номер пресета.'; Wait-Enter; return
        }
        $p = $script:SimPresets[$n - 1]
    }

    Write-Host ''
    Write-Host ("  Выбрано: {0} ({1}), оператор {2}, MCC+MNC = {3}{4}" -f $p.Country, $p.Iso, $p.Operator, $p.Mcc, $p.Mnc) -ForegroundColor White
    $imsi = New-RandomImsiForMccMnc -Mcc $p.Mcc -Mnc $p.Mnc
    $iccid = New-RandomIccid
    $phone = if ($p.Dial) { New-RandomPhoneForDial -Dial $p.Dial } else { $null }
    $setLine = "  Будет установлен: IMSI=$imsi  SIMserial=$iccid" + $(if ($phone) { "  Телефон=$phone" })
    Write-Host $setLine
    if (-not (Confirm-Action 'Применить?')) { Write-Note 'Отменено.'; Wait-Enter; return }

    $props = @{ imsi = $imsi; simserial = $iccid }
    if ($phone) { $props['pnumber'] = $phone }
    Invoke-LDModify -Index $Instance.Index -Props $props
    Write-Ok "SIM-идентификация установлена: $($p.Iso) / $($p.Operator) (MCC $($p.Mcc), MNC $($p.Mnc))."
    Write-Note 'Для полного эффекта (где поддерживается системой Android) также применяется точка доступа вручную; LDPlayer меняет IMSI/номер через modify.'
    Offer-Restart -Instance $Instance
}

function Reset-LDIdentityAuto {
    param([object]$Instance)
    if (-not (Confirm-Action "Сбросить ВСЕ идентификаторы в режим 'auto' (случайные при каждом запуске LDPlayer)?")) {
        Write-Note 'Отменено.'
        Wait-Enter
        return
    }
    Invoke-LDModify -Index $Instance.Index -Props @{
        imei      = 'auto'
        imsi      = 'auto'
        simserial = 'auto'
        androidid = 'auto'
        mac       = 'auto'
    }
    Write-Note 'Производитель/модель/телефон не сбрасываются — при необходимости задайте их вручную.'
    Offer-Restart -Instance $Instance
}

function Format-IdValue {
    param($v)
    if ([string]::IsNullOrWhiteSpace([string]$v)) { return '(не задано)' }
    return [string]$v
}

function Show-IdentityValues {
    param([object]$Instance)
    $id = Get-LDInstanceIdentity -Index $Instance.Index
    Write-Title "Текущая идентификация: $($Instance.Name) (index $($Instance.Index))"
    if ($null -eq $id) {
        Write-Note "Не удалось найти vms\leidian$($Instance.Index)\config.ini — текущие значения недоступны."
        return
    }
    Write-Host ("  Файл конфига   : " + $id.Ini) -ForegroundColor DarkGray
    Write-Host ("  IMEI           : " + (Format-IdValue $id.Imei))
    Write-Host ("  IMSI           : " + (Format-IdValue $id.Imsi))
    $p = Get-SimPresetByImsiPrefix -Imsi ([string]$id.Imsi)
    $simInfo = if ($p) { "  -> $($p.Iso) $($p.Country) / $($p.Operator)" } else { '' }
    Write-Host ("  SIM serial     : " + (Format-IdValue $id.SimSerial))
    Write-Host ("  Android ID     : " + (Format-IdValue $id.AndroidId))
    Write-Host ("  MAC            : " + (Format-IdValue $id.Mac))
    Write-Host ("  Производитель  : " + (Format-IdValue $id.Manufacturer))
    Write-Host ("  Модель         : " + (Format-IdValue $id.Model))
    Write-Host ("  Телефон        : " + (Format-IdValue $id.PhoneNumber))
    if ($simInfo) { Write-Host $simInfo -ForegroundColor Cyan }
}

function Show-IdentityMenu {
    $inst = Select-LDInstance -Purpose 'идентификация устройства'
    if (-not $inst) { return }

    while ($true) {
        Show-Banner
        Write-Title "Идентификация устройства — $($inst.Name) (index $($inst.Index))"
        Write-Host '  Все изменения касаются ТОЛЬКО этого локального виртуального инстанса.' -ForegroundColor DarkGray
        Write-Host '  Изменения применяются после перезапуска инстанса.' -ForegroundColor DarkGray
        Write-Host ''
        Show-IdentityValues -Instance $inst
        Write-Host ''
        Write-Host '  [1] СЛУЧАЙНАЯ подмена ВСЕГО набора (IMEI+IMSI+SIM+AndroidID+MAC+модель+телефон)'
        Write-Host '  [2] IMEI'
        Write-Host '  [3] IMSI'
        Write-Host '  [4] SIM serial (ICCID)'
        Write-Host '  [5] Android ID'
        Write-Host '  [6] MAC-адрес'
        Write-Host '  [7] Модель устройства (brand / model / код модели)'
        Write-Host '  [8] Номер телефона'
        Write-Host "  [9] Смена оператора/SIM-страны (MCC/MNC, $($script:SimPresets.Count) пресетов + кастом)"
        Write-Host "  [a] Сбросить всё в 'auto' (случайные значения средствами LDPlayer)"
        Write-Host '  [r] Обновить отображение'
        Write-Host ''
        Write-Host '  [0] Назад'

        $c = (Read-Host 'Выбор').Trim()
        switch ($c) {
            '1' {
                $props = New-RandomIdentityProps
                Write-Host ''
                Write-Host '  Будет применён следующий набор:' -ForegroundColor White
                foreach ($k in $props.Keys) { Write-Host ("    {0,-14}: {1}" -f $k, $props[$k]) }
                if (Confirm-Action 'Применить?') {
                    Invoke-LDModify -Index $inst.Index -Props $props
                    Offer-Restart -Instance $inst
                } else { Write-Note 'Отменено.'; Wait-Enter }
            }
            '2' { Edit-LDSingleIdentity -Instance $inst -Kind 'imei'      -Title 'IMEI' }
            '3' { Edit-LDSingleIdentity -Instance $inst -Kind 'imsi'      -Title 'IMSI' }
            '4' { Edit-LDSingleIdentity -Instance $inst -Kind 'simserial' -Title 'SIM serial' }
            '5' { Edit-LDSingleIdentity -Instance $inst -Kind 'androidid' -Title 'Android ID' }
            '6' { Edit-LDSingleIdentity -Instance $inst -Kind 'mac'       -Title 'MAC' }
            '7' { Edit-LDDeviceModel -Instance $inst }
            '8' { Edit-LDSingleIdentity -Instance $inst -Kind 'pnumber'   -Title 'телефон' }
            '9' { Set-LDSimCountry -Instance $inst }
            'a' { Reset-LDIdentityAuto -Instance $inst }
            'r' { }
            '0' { return }
            'q' { return }
            default { Write-Fail 'Неизвестный пункт меню.'; Start-Sleep -Milliseconds 500 }
        }
    }
}

# ===========================================================================
# ДЕЙСТВИЯ: скриншоты / запись экрана / файлы / shell / команды
# ===========================================================================
function Save-EmulatorScreenshot {
    $target = Select-AdbTarget
    if (-not $target) { return }
    $default = Join-Path ([Environment]::GetFolderPath('Desktop')) ("LD_screenshot_{0}.png" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $local = (Read-Host "Куда сохранить PNG (Enter - $default)").Trim('"').Trim()
    if (-not $local) { $local = $default }
    $remote = '/sdcard/ldmanager_screen.png'
    Write-Host 'Снимок экрана...'
    [void](Invoke-Adb -Arguments @('-s',$target,'shell','screencap','-p',$remote))
    $out = Invoke-Adb -Arguments @('-s',$target,'pull',$remote,$local)
    if ($out) { Write-Host $out -ForegroundColor DarkGray }
    [void](Invoke-Adb -Arguments @('-s',$target,'shell','rm',$remote))
    if (Test-Path $local) { Write-Ok "Скриншот сохранён: $local" }
    else { Write-Fail 'Не удалось получить скриншот.' }
    Wait-Enter
}

function Start-EmulatorScreenRecord {
    $target = Select-AdbTarget
    if (-not $target) { return }
    Write-Host 'Запись экрана: до 180 секунд (ограничение screenrecord). Запись идёт на инстансе.'
    $secs = (Read-Host 'Длительность в секундах (5-180, Enter - 30)').Trim()
    if (-not $secs) { $secs = '30' }
    if ($secs -notmatch '^\d{1,3}$' -or [int]$secs -lt 5 -or [int]$secs -gt 180) {
        Write-Fail 'Длительность: число от 5 до 180.'; Wait-Enter; return
    }
    $default = Join-Path ([Environment]::GetFolderPath('Desktop')) ("LD_record_{0}.mp4" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $local = (Read-Host "Куда сохранить MP4 (Enter - $default)").Trim('"').Trim()
    if (-not $local) { $local = $default }
    $remote = '/sdcard/ldmanager_record.mp4'

    Write-Note "Идёт запись $secs сек... Не закрывайте окно."
    $adb = Get-AdbExePath
    $p = Start-Process -FilePath $adb -ArgumentList @('-s',$target,'shell','screenrecord','--time-limit',$secs,$remote) -PassThru -WindowStyle Hidden
    if (-not $p) { Write-Fail 'Не удалось запустить screenrecord.'; Wait-Enter; return }

    for ($left = [int]$secs; $left -gt 0; $left -= 5) {
        Write-Host ("  осталось ~{0} сек..." -f $left)
        Start-Sleep -Seconds 5
        if ($p.HasExited) { break }
    }
    if (-not $p.HasExited) {
        Write-Host 'Останавливаю запись...'
        # Ctrl-C в stdin screenrecord не пробросить через Start-Process; ждём завершения по time-limit
        try { $p.WaitForExit(30000) | Out-Null } catch { }
        if (-not $p.HasExited) { try { $p.Kill() } catch { } }
    }
    Start-Sleep -Seconds 2
    $out = Invoke-Adb -Arguments @('-s',$target,'pull',$remote,$local)
    if ($out) { Write-Host $out -ForegroundColor DarkGray }
    [void](Invoke-Adb -Arguments @('-s',$target,'shell','rm',$remote))
    if (Test-Path $local) { Write-Ok "Запись сохранена: $local" }
    else { Write-Fail 'Не удалось получить запись.' }
    Wait-Enter
}

function Push-FileToEmulator {
    $target = Select-AdbTarget
    if (-not $target) { return }
    $local = (Read-Host 'Локальный путь к файлу').Trim('"').Trim()
    $remote = (Read-Host 'Путь на инстансе (например /sdcard/Download/)').Trim()
    if ($local -and (Test-Path $local) -and $remote) {
        $out = Invoke-Adb -Arguments @('-s',$target,'push',$local,$remote)
        if ($out) { Write-Host $out }
        Write-Ok 'push выполнен.'
    } else { Write-Fail 'Проверьте пути.' }
    Wait-Enter
}

function Pull-FileFromEmulator {
    $target = Select-AdbTarget
    if (-not $target) { return }
    $remote = (Read-Host 'Путь файла на инстансе').Trim()
    $local = (Read-Host 'Куда сохранить локально').Trim('"').Trim()
    if ($remote -and $local) {
        $out = Invoke-Adb -Arguments @('-s',$target,'pull',$remote,$local)
        if ($out) { Write-Host $out }
        Write-Ok 'pull выполнен.'
    } else { Write-Fail 'Проверьте пути.' }
    Wait-Enter
}

function Open-InteractiveAdbShell {
    $inst = Select-LDInstance -RequireRunning -Purpose 'adb shell'
    if (-not $inst) { return }
    $adb = Get-AdbExePath
    if (-not $adb) { Write-Fail 'adb.exe не найден.'; Wait-Enter; return }
    $target = Resolve-AdbTarget -Index $inst.Index -Name $inst.Name
    if (-not $target) { Wait-Enter; return }
    Write-Note "Интерактивная ADB-сессия с $($inst.Name). Выход: команда exit"
    & $adb -s $target shell
    Write-Ok 'ADB-сессия завершена.'
    Wait-Enter
}

function Invoke-CustomAdbCommand {
    $target = Select-AdbTarget
    if (-not $target) { return }
    Write-Host 'Введите adb shell команду (например: dumpsys battery | getprop ro.product.model)'
    $cmdline = Read-Host 'shell>'
    if (-not $cmdline) { Write-Note 'Отменено.'; Wait-Enter; return }
    $out = Invoke-Adb -Arguments (@('-s',$target,'shell') + ($cmdline -split ' '))
    if ($out) { Write-Host $out }
    else { Write-Note '(пустой вывод)' }
    Wait-Enter
}

function Show-AdbMenu {
    while ($true) {
        Show-Banner
        Write-Title 'ADB / файлы / экран'
        $adb = Get-AdbExePath
        if ($adb) { Write-Host "  adb.exe: $adb" -ForegroundColor DarkGray }
        else      { Write-Host '  adb.exe НЕ НАЙДЕН — установите platform-tools или проверьте папку LDPlayer.' -ForegroundColor Yellow }
        Write-Host ''
        Write-Host '  [1] Список устройств (adb devices)'
        Write-Host '  [2] Интерактивная ADB-сессия (прямой shell)'
        Write-Host '  [3] Выполнить произвольную shell-команду'
        Write-Host '  [4] Установить APK через adb'
        Write-Host '  [5] Передача файлов: НА инстанс (push)'
        Write-Host '  [6] Передача файлов: С инстанса (pull)'
        Write-Host '  [7] Скриншот инстанса (PNG)'
        Write-Host '  [8] Запись экрана (screenrecord, до 180 c)'
        Write-Host '  [9] Очистить данные приложения (pm clear)'
        Write-Host '  [f] Force-stop приложения'
        Write-Host '  [k] Перезапустить ADB-сервер'
        Write-Host ''
        Write-Host '  [0] Назад'

        $c = (Read-Host 'Выбор').Trim()
        switch ($c) {
            '1' { $out = Invoke-Adb -Arguments @('devices','-l'); if ($out) { Write-Host $out }; Wait-Enter }
            '2' { Open-InteractiveAdbShell }
            '3' { Invoke-CustomAdbCommand }
            '4' {
                $target = Select-AdbTarget
                if ($target) {
                    $apk = (Read-Host 'Путь к .apk файлу').Trim('"').Trim()
                    if ($apk -and (Test-Path $apk)) {
                        $out = Invoke-Adb -Arguments @('-s',$target,'install','-r',$apk)
                        if ($out) { Write-Host $out }
                    } else { Write-Fail 'Файл не найден.' }
                    Wait-Enter
                }
            }
            '5' { Push-FileToEmulator }
            '6' { Pull-FileFromEmulator }
            '7' { Save-EmulatorScreenshot }
            '8' { Start-EmulatorScreenRecord }
            '9' { Clear-LDAppData }
            'f' { Force-StopApp }
            'k' {
                [void](Invoke-Adb -Arguments @('kill-server'))
                [void](Invoke-Adb -Arguments @('start-server'))
                $out = Invoke-Adb -Arguments @('devices')
                if ($out) { Write-Host $out }
                Write-Ok 'ADB-сервер перезапущен.'
                Wait-Enter
            }
            '0' { return }
            'q' { return }
            default { Write-Fail 'Неизвестный пункт меню.'; Start-Sleep -Milliseconds 500 }
        }
    }
}

# ===========================================================================
# ДЕЙСТВИЯ: окна
# ===========================================================================
function Show-WindowsMenu {
    while ($true) {
        Show-Banner
        Write-Title 'Управление окнами эмулятора'
        $wins = Get-EmulatorWindows
        if ($wins.Count -eq 0) {
            Write-Note 'Запущенных окон эмулятора (dnplayer.exe) не найдено.'
        } else {
            $hdr = "  {0,-8}{1,-10}{2}" -f 'PID', 'Видимость', 'Заголовок'
            Write-Host $hdr -ForegroundColor White
            foreach ($w in $wins) {
                $vis = if ($w.Visible) { 'видимо' } else { 'скрыто' }
                Write-Host ("  {0,-8}{1,-10}{2}" -f $w.Pid, $vis, $w.Title)
            }
        }
        Write-Host ''
        Write-Host '  [1] Показать все окна эмулятора'
        Write-Host '  [2] Скрыть все окна эмулятора'
        Write-Host '  [3] Расставить окна (ldconsole sortWnd)'
        Write-Host '  [r] Обновить список'
        Write-Host ''
        Write-Host '  [0] Назад'

        $c = (Read-Host 'Выбор').Trim()
        switch ($c) {
            '1' {
                foreach ($w in $wins) { [void][LDM.Win32]::ShowWindow($w.Handle, 5) }  # SW_SHOW
                Write-Ok 'Окна показаны.'
                Wait-Enter
            }
            '2' {
                foreach ($w in $wins) { [void][LDM.Win32]::ShowWindow($w.Handle, 0) }  # SW_HIDE
                Write-Ok 'Окна скрыты (процессы продолжают работать).'
                Wait-Enter
            }
            '3' { Sort-LDWindows }
            'r' { }
            '0' { return }
            'q' { return }
            default { Write-Fail 'Неизвестный пункт меню.'; Start-Sleep -Milliseconds 500 }
        }
    }
}

# ===========================================================================
# ДЕЙСТВИЯ: массовые операции (все инстансы)
# ===========================================================================
function Invoke-BulkOperation {
    param([string]$Kind)

    $instances = Get-LDInstances
    if (-not $instances -or $instances.Count -eq 0) {
        Write-Note 'Инстансы не найдены.'
        Wait-Enter
        return
    }

    switch ($Kind) {
        'randomIdentity' {
            Write-Fail "ВНИМАНИЕ: случайная идентификация будет применена ко ВСЕМ остановленным инстансам ($($instances.Count) шт.)!"
            if (-not (Confirm-Action 'Продолжить?')) { Write-Note 'Отменено.'; Wait-Enter; return }
            $changed = 0
            foreach ($i in $instances) {
                if ($i.Running) { continue }
                $props = New-RandomIdentityProps
                Invoke-LDModify -Index $i.Index -Props $props -Quiet
                Write-Ok ("[{0}] {1}: IMEI={2} MAC={3} модель={4} {5}" -f $i.Index, $i.Name, $props['imei'], $props['mac'], $props['manufacturer'], $props['model'])
                $changed++
            }
            Write-Ok "Готово. Обновлено инстансов: $changed (запущенные пропущены)."
        }
        'launchAll' {
            if (-not (Confirm-Action "Запустить ВСЕ инстансы ($($instances.Count) шт.)?")) { Write-Note 'Отменено.'; Wait-Enter; return }
            foreach ($i in $instances) {
                if (-not $i.Running) {
                    [void](Invoke-LDConsole -Arguments @('launch','--index',[string]$i.Index))
                    Write-Ok ("[{0}] {1}: запуск" -f $i.Index, $i.Name)
                    Start-Sleep -Seconds 2
                }
            }
        }
        'quitAll' {
            if (-not (Confirm-Action 'Остановить ВСЕ запущенные инстансы?')) { Write-Note 'Отменено.'; Wait-Enter; return }
            [void](Invoke-LDConsole -Arguments @('quitall'))
            Write-Ok 'quitall отправлен.'
        }
        'rebootAll' {
            $run = $instances | Where-Object { $_.Running }
            if ($run.Count -eq 0) { Write-Note 'Нет запущенных инстансов.'; Wait-Enter; return }
            if (-not (Confirm-Action "Перезапустить все запущенные ($($run.Count) шт.)?")) { Write-Note 'Отменено.'; Wait-Enter; return }
            foreach ($i in $run) {
                [void](Invoke-LDConsole -Arguments @('reboot','--index',[string]$i.Index))
                Write-Ok ("[{0}] {1}: перезапуск" -f $i.Index, $i.Name)
            }
        }
    }
    Wait-Enter
}

function Show-BulkMenu {
    while ($true) {
        Show-Banner
        Write-Title 'Массовые операции (все инстансы)'
        Write-Host '  [1] Запустить ВСЕ инстансы'
        Write-Host '  [2] Остановить ВСЕ инстансы'
        Write-Host '  [3] Перезапустить ВСЕ запущенные'
        Write-Host '  [4] Случайная идентификация для ВСЕХ остановленных'
        Write-Host ''
        Write-Host '  [0] Назад'
        $c = (Read-Host 'Выбор').Trim()
        switch ($c) {
            '1' { Invoke-BulkOperation -Kind 'launchAll' }
            '2' { Invoke-BulkOperation -Kind 'quitAll' }
            '3' { Invoke-BulkOperation -Kind 'rebootAll' }
            '4' { Invoke-BulkOperation -Kind 'randomIdentity' }
            '0' { return }
            'q' { return }
            default { Write-Fail 'Неизвестный пункт меню.'; Start-Sleep -Milliseconds 500 }
        }
    }
}

# ===========================================================================
# ДЕЙСТВИЯ: логи (файлы + adb logcat)
# ===========================================================================
function Show-LdLogFiles {
    if (-not $script:LdPath) { Write-Fail 'ldconsole не найден.'; Wait-Enter; return }
    $base = Split-Path $script:LdPath -Parent
    $logDirs = @((Join-Path $base 'logs'), (Join-Path $base 'vms\leidian0'))
    $files = @()
    foreach ($d in $logDirs) {
        if (Test-Path $d) { $files += Get-ChildItem $d -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '^\.(log|txt)$' } }
    }
    if ($files.Count -eq 0) { Write-Note 'Лог-файлы не найдены в папке установки LDPlayer.'; Wait-Enter; return }

    for ($i = 0; $i -lt $files.Count; $i++) {
        Write-Host ("  [{0}] {1} ({2} KB, {3})" -f ($i+1), $files[$i].FullName, [int]($files[$i].Length/1KB), $files[$i].LastWriteTime)
    }
    $raw = (Read-Host 'Номер файла (Enter - отмена)').Trim()
    if (-not $raw) { return }
    $n = 0
    if (-not [int]::TryParse($raw, [ref]$n) -or $n -lt 1 -or $n -gt $files.Count) { Write-Fail 'Неверный номер.'; Wait-Enter; return }
    $f = $files[$n-1]
    $tail = (Read-Host 'Сколько последних строк показать (Enter - 50)').Trim()
    if (-not $tail) { $tail = '50' }
    Write-Title ("Хвост файла: " + $f.Name)
    Get-Content $f.FullName -Tail ([int]$tail) | ForEach-Object { Write-Host $_ }
    Wait-Enter
}

function Get-LogcatLevelFilter {
    Write-Host '  Уровни: [1] Verbose [2] Debug [3] Info [4] Warn [5] Error [6] Fatal (Enter - все)'
    $c = (Read-Host 'Уровень').Trim()
    switch ($c) {
        '1' { return 'V' } '2' { return 'D' } '3' { return 'I' }
        '4' { return 'W' } '5' { return 'E' } '6' { return 'F' }
        default { return $null }
    }
}

function Show-LogcatMenu {
    $target = Select-AdbTarget
    if (-not $target) { return }

    while ($true) {
        Show-Banner
        Write-Title "logcat ($target)"
        Write-Host '  [1] Снапшот: последние N строк'
        Write-Host '  [2] Снапшот с фильтром по уровню'
        Write-Host '  [3] Live-стрим (Ctrl+C для выхода)'
        Write-Host '  [4] Live-стрим с фильтром по тегу'
        Write-Host '  [5] Очистить буфер logcat'
        Write-Host ''
        Write-Host '  [0] Назад'
        $c = (Read-Host 'Выбор').Trim()
        switch ($c) {
            '1' {
                $n = (Read-Host 'Сколько строк (Enter - 200)').Trim(); if (-not $n) { $n = '200' }
                $out = Invoke-Adb -Arguments @('-s',$target,'logcat','-d','-t',$n)
                if ($out) { $out -split "`n" | Select-Object -Last ([int]$n) | ForEach-Object { Write-Host $_ } }
                Wait-Enter
            }
            '2' {
                $lvl = Get-LogcatLevelFilter
                if (-not $lvl) { Write-Note 'Фильтр не выбран.'; Wait-Enter; return }
                $out = Invoke-Adb -Arguments @('-s',$target,'logcat','-d',"*:$lvl")
                if ($out) { $out -split "`n" | Select-Object -Last 300 | ForEach-Object { Write-Host $_ } }
                Wait-Enter
            }
            '3' {
                Write-Note 'Live-стрим logcat. Для выхода нажмите Ctrl+C.'
                $adb = Get-AdbExePath
                & $adb -s $target logcat
                Wait-Enter
            }
            '4' {
                $tag = (Read-Host 'Тег (например ActivityManager)').Trim()
                if (-not $tag) { Write-Note 'Отменено.'; Wait-Enter; return }
                Write-Note "Live-стрим тега '$tag'. Для выхода нажмите Ctrl+C."
                $adb = Get-AdbExePath
                & $adb -s $target logcat -s $tag
                Wait-Enter
            }
            '5' {
                [void](Invoke-Adb -Arguments @('-s',$target,'logcat','-c'))
                Write-Ok 'Буфер logcat очищен.'
                Wait-Enter
            }
            '0' { return }
            'q' { return }
            default { Write-Fail 'Неизвестный пункт меню.'; Start-Sleep -Milliseconds 500 }
        }
    }
}

# ===========================================================================
# ДЕЙСТВИЯ: GPS / клавиши / сеть
# ===========================================================================
function Show-ActionMenu {
    $inst = Select-LDInstance -RequireRunning -Purpose 'действия'
    if (-not $inst) { return }

    while ($true) {
        Show-Banner
        Write-Title "Действия — $($inst.Name) (index $($inst.Index))"
        Write-Host '  [1] Задать геолокацию (GPS)'
        Write-Host '  [2] Виртуальная клавиша (home/back/menu/volumeup/volumedown)'
        Write-Host '  [3] Ввести текст в активное поле'
        Write-Host '  [4] Сеть: включить / выключить'
        Write-Host '  [5] Встряхнуть устройство'
        Write-Host ''
        Write-Host '  [0] Назад'
        $c = (Read-Host 'Выбор').Trim()
        switch ($c) {
            '1' {
                $ll = (Read-Host 'Долгота,широта (пример: 37.617698,55.755864)').Trim()
                if ($ll -match '^-?\d+(\.\d+)?,-?\d+(\.\d+)?$') {
                    $out = Invoke-LDConsole -Arguments @('locate','--index',[string]$inst.Index,'--LLI',$ll)
                    if ($out) { Write-Host $out }
                    Write-Ok 'Геолокация задана.'
                } else { Write-Fail 'Неверный формат.' }
                Wait-Enter
            }
            '2' {
                Write-Host '  [1] home [2] back [3] menu [4] volumeup [5] volumedown'
                $k = (Read-Host 'Выбор').Trim()
                $keyMap = @{ '1' = 'home'; '2' = 'back'; '3' = 'menu'; '4' = 'volumeup'; '5' = 'volumedown' }
                if ($keyMap.ContainsKey($k)) {
                    $out = Invoke-LDConsole -Arguments @('action','--index',[string]$inst.Index,'--key','call.keyboard','--value',$keyMap[$k])
                    Write-Ok "Отправлена клавиша: $($keyMap[$k])"
                } else { Write-Note 'Отменено.' }
                Wait-Enter
            }
            '3' {
                $text = Read-Host 'Текст для ввода'
                if ($text) {
                    $out = Invoke-LDConsole -Arguments @('action','--index',[string]$inst.Index,'--key','call.input','--value',$text)
                    Write-Ok 'Текст отправлен.'
                }
                Wait-Enter
            }
            '4' {
                $on = Confirm-Action 'Включить сеть? (N = выключить)'
                $val = if ($on) { 'connect' } else { 'offline' }
                $out = Invoke-LDConsole -Arguments @('action','--index',[string]$inst.Index,'--key','call.network','--value',$val)
                Write-Ok "Сеть: $val"
                Wait-Enter
            }
            '5' {
                $out = Invoke-LDConsole -Arguments @('rock','--index',[string]$inst.Index)
                Write-Ok 'Встряска выполнена.'
                Wait-Enter
            }
            '0' { return }
            'q' { return }
            default { Write-Fail 'Неизвестный пункт меню.'; Start-Sleep -Milliseconds 500 }
        }
    }
}

# ===========================================================================
# ДЕЙСТВИЯ: резервные копии
# ===========================================================================
function Backup-LDInstance {
    $inst = Select-LDInstance -RequireStopped -Purpose 'резервное копирование'
    if (-not $inst) { return }
    $safeName = ($inst.Name -replace '[^\w\-]+', '_')
    $default = Join-Path ([Environment]::GetFolderPath('Desktop')) ("LD_{0}_{1}.ldbk" -f $safeName, (Get-Date -Format 'yyyyMMdd_HHmm'))
    $path = (Read-Host "Путь для копии (Enter - $default)").Trim('"').Trim()
    if (-not $path) { $path = $default }
    if ($path -notmatch '\.ldbk$') { $path = $path + '.ldbk' }
    Write-Note 'Копирование может занять длительное время для больших инстансов...'
    $out = Invoke-LDConsole -Arguments @('backup','--index',[string]$inst.Index,'--file',$path)
    if ($out) { Write-Host $out }
    if (Test-Path $path) { Write-Ok "Копия сохранена: $path" }
    else { Write-Fail 'Не удалось создать копию.' }
    Wait-Enter
}

function Restore-LDInstance {
    $inst = Select-LDInstance -RequireStopped -Purpose 'восстановление'
    if (-not $inst) { return }
    $path = (Read-Host 'Путь к файлу .ldbk').Trim('"').Trim()
    if (-not $path -or -not (Test-Path $path)) { Write-Fail 'Файл не найден.'; Wait-Enter; return }
    Write-Fail "ВНИМАНИЕ: данные инстанса '$($inst.Name)' будут ПЕРЕЗАПИСАНЫ содержимым резервной копии!"
    if (-not (Confirm-Action 'Продолжить восстановление?')) { Write-Note 'Отменено.'; Wait-Enter; return }
    $out = Invoke-LDConsole -Arguments @('restore','--index',[string]$inst.Index,'--file',$path)
    if ($out) { Write-Host $out }
    Write-Ok 'Команда restore выполнена.'
    Wait-Enter
}

function Show-BackupMenu {
    while ($true) {
        Show-Banner
        Write-Title 'Резервные копии (.ldbk)'
        Write-Host '  Операции требуют остановленного инстанса и могут занимать много времени.'
        Write-Host ''
        Write-Host '  [1] Создать резервную копию инстанса'
        Write-Host '  [2] Восстановить инстанс из копии'
        Write-Host ''
        Write-Host '  [0] Назад'
        $c = (Read-Host 'Выбор').Trim()
        switch ($c) {
            '1' { Backup-LDInstance }
            '2' { Restore-LDInstance }
            '0' { return }
            'q' { return }
            default { Write-Fail 'Неизвестный пункт меню.'; Start-Sleep -Milliseconds 500 }
        }
    }
}

# ===========================================================================
# Настройки (пути)
# ===========================================================================
function Show-SettingsMenu {
    while ($true) {
        Show-Banner
        Write-Title 'Настройки'
        if ($script:LdPath -and ((Split-Path $script:LdPath -Leaf) -ine 'ldconsole.exe')) {
            Write-Host ("  ldconsole : " + $script:LdPath) -ForegroundColor Yellow
            Write-Host '  [!!] Это не ldconsole.exe — команды работать не будут. Задайте путь заново.' -ForegroundColor Yellow
        } else {
            Write-Host ("  ldconsole : " + $(if ($script:LdPath) { $script:LdPath } else { '(не задан)' }))
        }
        Write-Host ("  adb       : " + $(if ($script:AdbPath -and (Test-Path $script:AdbPath)) { $script:AdbPath } else { '(не задан, будет искаться автоматически)' }))
        Write-Host ("  конфиг    : " + $script:ConfigPath)
        Write-Host ''
        Write-Host '  [1] Указать путь к ldconsole.exe вручную'
        Write-Host '  [2] Повторить автопоиск ldconsole.exe'
        Write-Host '  [3] Указать путь к adb.exe вручную'
        Write-Host '  [4] Сбросить конфигурацию'
        Write-Host ''
        Write-Host '  [0] Назад'
        $c = (Read-Host 'Выбор').Trim()
        switch ($c) {
            '1' {
                $p = (Read-Host 'Полный путь к ldconsole.exe').Trim('"').Trim()
                if ($p -and (Test-Path $p) -and ((Split-Path $p -Leaf) -ieq 'ldconsole.exe')) {
                    $script:LdPath = $p
                    Save-ManagerConfig -LdConsolePath $p
                    Write-Ok "Путь сохранён: $p"
                } else { Write-Fail 'Файл ldconsole.exe по указанному пути не найден.' }
                Wait-Enter
            }
            '2' {
                $found = Resolve-LDConsolePath
                if ($found) {
                    $script:LdPath = $found
                    Save-ManagerConfig -LdConsolePath $found
                    Write-Ok "Найден: $found"
                } else { Write-Fail 'ldconsole.exe не найден. Установите LDPlayer или укажите путь вручную.' }
                Wait-Enter
            }
            '3' {
                $p = (Read-Host 'Полный путь к adb.exe (Enter - сбросить)').Trim('"').Trim()
                if ($p -and (Test-Path $p)) {
                    $script:AdbPath = $p
                    Save-ManagerConfig -AdbPath $p
                    Write-Ok "Путь сохранён: $p"
                } elseif (-not $p) {
                    $script:AdbPath = $null
                    [void](Get-AdbExePath)
                    Write-Ok 'Путь к adb сброшен (вернётся автопоиск).'
                } else { Write-Fail 'Файл не найден.' }
                Wait-Enter
            }
            '4' {
                if (Confirm-Action 'Удалить файл конфигурации?') {
                    if (Test-Path $script:ConfigPath) { Remove-Item $script:ConfigPath -Force }
                    $script:LdPath = $null
                    $script:AdbPath = $null
                    Write-Ok 'Конфигурация сброшена.'
                }
                Wait-Enter
            }
            '0' { return }
            'q' { return }
            default { Write-Fail 'Неизвестный пункт меню.'; Start-Sleep -Milliseconds 500 }
        }
    }
}

# ===========================================================================
# GitHub-токен: DPAPI-шифрование (CurrentUser)
# ===========================================================================
function Get-StoredGithubToken {
    $cfg = Get-AppConfig
    if ($cfg -and $cfg.githubTokenEnc) {
        try {
            $sec = ConvertTo-SecureString -String $cfg.githubTokenEnc
            $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
            try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        } catch { return $null }
    }
    return $null
}

function Save-GithubToken {
    $plain = Read-Host 'Вставьте GitHub Personal Access Token (ввод скрыт, Enter - отмена)'
    if (-not $plain) { Write-Note 'Отменено.'; Wait-Enter; return }
    $sec = ConvertTo-SecureString $plain -AsPlainText -Force
    $enc = ConvertFrom-SecureString -SecureString $sec   # DPAPI, CurrentUser
    Save-ManagerConfig -GithubTokenEnc $enc
    Write-Ok 'Токен сохранён (зашифрован DPAPI для текущего пользователя Windows).'
    Write-Note 'Токен нужен ТОЛЬКО для приватных репозиториев и больших запросов к api.github.com.'
    Wait-Enter
}

function Test-GithubToken {
    $t = Get-StoredGithubToken
    if (-not $t) { Write-Note 'Токен не сохранён.'; Wait-Enter; return }
    $h = @{ Uri = 'https://api.github.com/user'; Headers = @{ 'User-Agent' = 'LDManager'; 'Authorization' = "token $t" } }
    try {
        $r = Invoke-RestMethod @h -TimeoutSec 15
        Write-Ok ("Токен действителен. Пользователь GitHub: {0}" -f $r.login)
    } catch {
        Write-Fail "Токен не принят GitHub: $($_.Exception.Message)"
    }
    Wait-Enter
}

function Remove-GithubToken {
    if (-not (Confirm-Action 'Удалить сохранённый GitHub-токен?')) { Write-Note 'Отменено.'; Wait-Enter; return }
    Save-ManagerConfig -GithubTokenEnc ''
    Write-Ok 'Токен удалён из конфига.'
    Wait-Enter
}

function Show-GithubTokenMenu {
    while ($true) {
        Show-Banner
        Write-Title 'Менеджер GitHub-токена (DPAPI)'
        $t = Get-StoredGithubToken
        if ($t) { Write-Host '  Статус: токен сохранён' -ForegroundColor Green }
        else    { Write-Host '  Статус: токен не задан' -ForegroundColor Yellow }
        Write-Host '  Токен хранится локально в LDManager.config.json в виде, зашифрованном'
        Write-Host '  через Windows DPAPI (CurrentUser) — расшифровать может только ваш пользователь.'
        Write-Host ''
        Write-Host '  [1] Сохранить / заменить токен'
        Write-Host '  [2] Проверить токен (GET api.github.com/user)'
        Write-Host '  [3] Удалить токен'
        Write-Host ''
        Write-Host '  [0] Назад'
        $c = (Read-Host 'Выбор').Trim()
        switch ($c) {
            '1' { Save-GithubToken }
            '2' { Test-GithubToken }
            '3' { Remove-GithubToken }
            '0' { return }
            'q' { return }
            default { Write-Fail 'Неизвестный пункт меню.'; Start-Sleep -Milliseconds 500 }
        }
    }
}

# ===========================================================================
# GitHub: HTTP-помощники
# ===========================================================================
function Get-GithubHeaders {
    $h = @{ 'User-Agent' = "LDManager/$script:ScriptVersion" }
    $t = Get-StoredGithubToken
    if ($t) { $h['Authorization'] = "token $t" }
    return $h
}

# ---------------------------------------------------------------------------
# Диагностика доступа к GitHub: по каждому хосту — точная причина сбоя
# (DNS / TCP / TLS / HTTP-статус), а не общее «нет сети».
# DNS и TCP вынесены в отдельные функции, чтобы Pester мог их подменять.
# ---------------------------------------------------------------------------
function Resolve-GithubHost {
    param([string]$HostName)
    try {
        $addrs = [System.Net.Dns]::GetHostAddresses($HostName)
        if ($addrs -and $addrs.Count -gt 0) { return @{ Ok = $true; Addresses = $addrs } }
        return @{ Ok = $false; Error = "DNS: хост ${HostName} не резолвится" }
    } catch {
        return @{ Ok = $false; Error = "DNS: не удалось разрешить ${HostName} ($($_.Exception.Message))" }
    }
}

function Test-GithubTcpPort {
    param([string]$HostName, [int]$Port = 443, [int]$TimeoutMs = 5000)
    $tcp = New-Object System.Net.Sockets.TcpClient
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $t = $tcp.BeginConnect($HostName, $Port, $null, $null)
        if (-not $t.AsyncWaitHandle.WaitOne($TimeoutMs)) {
            return @{ Ok = $false; Error = "TCP: таймаут подключения к ${HostName}:${Port} (${TimeoutMs} мс)" }
        }
        $tcp.EndConnect($t)
        $sw.Stop()
        return @{ Ok = $true; LatencyMs = [int]$sw.ElapsedMilliseconds }
    } catch {
        return @{ Ok = $false; Error = "TCP: не удалось подключиться к ${HostName}:${Port} ($($_.Exception.Message))" }
    } finally { try { $tcp.Close() } catch { } }
}

# Достаёт HTTP-статус из записи об ошибке (Exception.Response.StatusCode).
# Отдельная функция, чтобы можно было протестировать на синтетических объектах.
function Get-HttpErrorStatusCode {
    param($ErrorRecord)
    if ($ErrorRecord -and $ErrorRecord.Exception) {
        $resp = $ErrorRecord.Exception.Response
        if ($resp -and $resp.PSObject.Properties['StatusCode']) {
            try { return [int]$resp.StatusCode } catch { return $null }
        }
    }
    return $null
}

function Test-GithubEndpoint {
    param([Parameter(Mandatory = $true)][string]$Url)

    $uri  = [Uri]$Url
    $hostName = $uri.Host
    $res = @{ Url = $Url; Ok = $false; Detail = $null; HttpCode = $null; LatencyMs = $null }

    # 1) DNS
    $dns = Resolve-GithubHost -HostName $hostName
    if (-not $dns.Ok) { $res.Detail = $dns.Error; return $res }

    # 2) TCP 443
    $tcpRes = Test-GithubTcpPort -HostName $hostName
    if (-not $tcpRes.Ok) { $res.Detail = $tcpRes.Error; return $res }
    $res.LatencyMs = $tcpRes.LatencyMs

    # 3) HTTPS-запрос (TLS + HTTP-статус)
    try {
        $r = Invoke-WebRequest -Uri $Url -Headers (Get-GithubHeaders) -TimeoutSec 20 -UseBasicParsing
        $res.Ok = $true; $res.HttpCode = [int]$r.StatusCode
        return $res
    } catch {
        $code = Get-HttpErrorStatusCode $_
        if ($code) {
            $res.HttpCode = $code
            if ($code -ge 400) { $res.Ok = $true; return $res }  # хост доступен, код — уже вопрос API
            $res.Detail = "HTTP $code ($($_.Exception.Message))"
        } else {
            $res.Detail = "HTTPS: $($_.Exception.Message)"
        }
        return $res
    }
}

function Show-GithubDiagnostics {
    Write-Title 'Диагностика доступа к GitHub'
    $endpoints = @(
        @{ Name = 'api.github.com (API: релизы, проверка обновлений)'; Url = "https://api.github.com/repos/$script:RepoOwner/$script:RepoName/releases/latest" },
        @{ Name = 'raw.githubusercontent.com (сырые файлы: версии, самообновление)'; Url = "https://raw.githubusercontent.com/$script:RepoOwner/$script:RepoName/$script:RepoBranch/LDManager.core.ps1" }
    )
    foreach ($ep in $endpoints) {
        Write-Host ""
        Write-Host "  $($ep.Name)"
        $r = Test-GithubEndpoint -Url $ep.Url
        if ($r.Ok) {
            $lat = if ($r.LatencyMs) { " ({0} мс)" -f $r.LatencyMs } else { '' }
            Write-Ok ("доступен: HTTP {0}{1}" -f $r.HttpCode, $lat)
        } else {
            Write-Fail $r.Detail
        }
    }
    Write-Host ''
    Write-Note 'Коды 403 (rate limit) и 404 (нет релизов) НЕ означают проблему сети.'
    Write-Note '403 без токена: исчерпан лимит запросов GitHub — сохраните токен в [1].'
    Write-Host ''
    Wait-Enter
}

function Get-LatestReleaseInfo {
    try {
        $r = Invoke-RestMethod -Uri "https://api.github.com/repos/$script:RepoOwner/$script:RepoName/releases/latest" -Headers (Get-GithubHeaders) -TimeoutSec 20
        return $r
    } catch {
        return $null
    }
}

function Get-RemoteScriptVersion {
    # Версия задаётся в LDManager.core.ps1 (строка $script:ScriptVersion = 'X.Y.Z'),
    # поэтому читаем именно ядро, а не точку входа LDManager.ps1.
    # Запасной вариант: старые копии репозитория держали версию в точке входа.
    # При неудаче в $script:LastUpdateCheckError кладётся точная причина сбоя.
    $script:LastUpdateCheckError = $null
    $base = "https://raw.githubusercontent.com/$script:RepoOwner/$script:RepoName/$script:RepoBranch/"
    $lastErr = $null
    foreach ($f in @('LDManager.core.ps1', 'LDManager.ps1')) {
        try {
            $resp = Invoke-WebRequest -Uri ($base + $f) -Headers (Get-GithubHeaders) -TimeoutSec 20 -UseBasicParsing
            if ($resp.Content -match "\`$script:ScriptVersion\s*=\s*'([0-9\.]+)'") { return $matches[1] }
            $lastErr = "файл $f скачан (HTTP $($resp.StatusCode)), но строки версии в нём нет"
        } catch {
            $code = Get-HttpErrorStatusCode $_
            if ($code) {
                $hint = switch ($code) {
                    403 { ' (превышен лимит запросов GitHub - сохраните токен в меню [1])' }
                    404 { ' (файл не найден - проверьте ветку и имя репозитория)' }
                    default { '' }
                }
                $lastErr = "HTTP $code при загрузке $f$hint"
            } else {
                $lastErr = "сетевая ошибка при загрузке ${f}: $($_.Exception.Message)"
            }
        }
    }
    $script:LastUpdateCheckError = $lastErr
    return $null
}

function Test-UpdateAvailable {
    $remote = Get-RemoteScriptVersion
    if (-not $remote) {
        if (-not $script:LastUpdateCheckError) { $script:LastUpdateCheckError = 'не удалось получить версию (причина неизвестна)' }
        return $null
    }
    try {
        $vL = [version]$script:ScriptVersion
        $vR = [version]$remote
        return ($vR -gt $vL)
    } catch {
        $script:LastUpdateCheckError = "не удалось разобрать версию: локальная '$script:ScriptVersion', удалённая '$remote'"
        return $null
    }
}

function Update-LDManagerSelf {
    # Самообновление: скачивает все файлы скрипта из репозитория и заменяет их
    Write-Title 'Автообновление из GitHub'
    $check = Test-UpdateAvailable
    if ($check -eq $null) {
        Write-Fail 'Не удалось получить версию из GitHub.'
        if ($script:LastUpdateCheckError) { Write-Note ("Причина: " + $script:LastUpdateCheckError) }
        Wait-Enter; return
    }
    if (-not $check) { Write-Ok "У вас актуальная версия ($script:ScriptVersion)."; Wait-Enter; return }

    $remote = Get-RemoteScriptVersion
    Write-Host "  Доступна версия: $remote (у вас $script:ScriptVersion)"
    if (-not (Confirm-Action 'Скачать и заменить LDManager.ps1?')) { Write-Note 'Отменено.'; Wait-Enter; return }

    $baseUrl = "https://raw.githubusercontent.com/$script:RepoOwner/$script:RepoName/$script:RepoBranch/"
    $files   = @('LDManager.ps1', 'LDManager.core.ps1', 'LD.Sieve.ps1')
    $backupDir = Join-Path $scriptRoot ("LDManager.backup_{0}" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    try {
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        foreach ($f in $files) {
            $target = Join-Path $scriptRoot $f
            if (Test-Path $target) { Copy-Item $target (Join-Path $backupDir $f) -Force }
        }
        foreach ($f in $files) {
            $target = Join-Path $scriptRoot $f
            $content = (Invoke-WebRequest -Uri ($baseUrl + $f) -Headers (Get-GithubHeaders) -TimeoutSec 60 -UseBasicParsing).Content
            # Неизменённый файл не переписываем: сохраняем байты и подпись.
            if ((Test-Path $target) -and ([System.IO.File]::ReadAllText($target) -ceq $content)) { continue }
            [System.IO.File]::WriteAllText($target, $content, (New-Object System.Text.UTF8Encoding($true)))
        }
        Write-Ok "Обновлено до $remote. Резервная копия: $backupDir"
        Write-Note 'Перезапустите скрипт, чтобы изменения вступили в силу.'
    } catch {
        Write-Fail "Ошибка обновления: $($_.Exception.Message)"
        if (Test-Path $backupDir) { Write-Note "Резервная копия: $backupDir" }
    }
    Wait-Enter
}

# ===========================================================================
# Загрузка репозитория (git clone / ZIP / отдельный файл)
# ===========================================================================
function Get-RepoZip {
    $dest = (Read-Host "Куда распаковать ZIP (Enter - подпапка в $scriptRoot)").Trim('"').Trim()
    if (-not $dest) { $dest = Join-Path $scriptRoot ("{0}-{1}" -f $script:RepoName, (Get-Date -Format 'yyyyMMdd_HHmmss')) }
    $zip = Join-Path $env:TEMP ("{0}.zip" -f [guid]::NewGuid().ToString('N'))
    $url = "https://github.com/$script:RepoOwner/$script:RepoName/archive/refs/heads/$script:RepoBranch.zip"
    try {
        Write-Host 'Скачивание ZIP...'
        Invoke-WebRequest -Uri $url -Headers (Get-GithubHeaders) -OutFile $zip -TimeoutSec 120 -UseBasicParsing
        if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
        Expand-Archive -Path $zip -DestinationPath $dest -Force
        Write-Ok "Распаковано: $dest"
    } catch {
        Write-Fail "Ошибка: $($_.Exception.Message)"
    } finally {
        if (Test-Path $zip) { Remove-Item $zip -Force -ErrorAction SilentlyContinue }
    }
    Wait-Enter
}

function Invoke-RepoClone {
    $git = Get-Command 'git.exe' -ErrorAction SilentlyContinue
    if (-not $git) { Write-Fail 'git.exe не найден в PATH. Установите Git для Windows.'; Wait-Enter; return }
    $dest = (Read-Host "Путь для клонирования (Enter - подпапка в $scriptRoot)").Trim('"').Trim()
    if (-not $dest) { $dest = Join-Path $scriptRoot ("{0}-clone" -f $script:RepoName) }
    if (Test-Path $dest) { Write-Fail "Папка уже существует: $dest"; Wait-Enter; return }
    $url = "https://github.com/$script:RepoOwner/$script:RepoName.git"
    Write-Host "git clone $url -> $dest"
    & $git clone $url $dest
    if ($LASTEXITCODE -eq 0) { Write-Ok "Клонировано: $dest" }
    else { Write-Fail 'git clone завершился с ошибкой.' }
    Wait-Enter
}

function Get-RepoSingleFile {
    $pathInRepo = (Read-Host 'Путь файла в репозитории (например LDManager.ps1)').Trim()
    if (-not $pathInRepo) { Write-Note 'Отменено.'; Wait-Enter; return }
    $dest = (Read-Host "Куда сохранить (Enter - рядом со скриптом)").Trim('"').Trim()
    if (-not $dest) { $dest = Join-Path $scriptRoot (Split-Path $pathInRepo -Leaf) }
    $url = "https://raw.githubusercontent.com/$script:RepoOwner/$script:RepoName/$script:RepoBranch/" + ($pathInRepo -replace '^/','')
    try {
        Invoke-WebRequest -Uri $url -Headers (Get-GithubHeaders) -OutFile $dest -TimeoutSec 60 -UseBasicParsing
        Write-Ok "Сохранено: $dest"
    } catch {
        Write-Fail "Ошибка: $($_.Exception.Message)"
    }
    Wait-Enter
}

function Show-RepoMenu {
    while ($true) {
        Show-Banner
        Write-Title "Загрузка репозитория ($script:RepoOwner/$script:RepoName)"
        Write-Host '  [1] git clone репозитория'
        Write-Host '  [2] Скачать и распаковать ZIP'
        Write-Host '  [3] Скачать отдельный файл'
        Write-Host ''
        Write-Host '  [0] Назад'
        $c = (Read-Host 'Выбор').Trim()
        switch ($c) {
            '1' { Invoke-RepoClone }
            '2' { Get-RepoZip }
            '3' { Get-RepoSingleFile }
            '0' { return }
            'q' { return }
            default { Write-Fail 'Неизвестный пункт меню.'; Start-Sleep -Milliseconds 500 }
        }
    }
}

# ===========================================================================
# Меню GitHub (токен / автообновление / загрузка репозитория)
# ===========================================================================
function Show-GithubMenu {
    while ($true) {
        Show-Banner
        Write-Title 'GitHub'
        Write-Host ("  Репозиторий: https://github.com/$script:RepoOwner/$script:RepoName")
        $t = Get-StoredGithubToken
        Write-Host ("  Токен      : " + $(if ($t) { 'сохранён (DPAPI)' } else { 'не задан' }))
        Write-Host ''
        Write-Host '  [1] Менеджер GitHub-токена (DPAPI)'
        Write-Host '  [2] Проверить обновления'
        Write-Host '  [3] Автообновление скрипта из GitHub'
        Write-Host '  [4] Загрузка репозитория (clone / ZIP / файл)'
        Write-Host '  [5] Диагностика доступа к GitHub'
        Write-Host ''
        Write-Host '  [0] Назад'
        $c = (Read-Host 'Выбор').Trim()
        switch ($c) {
            '1' { Show-GithubTokenMenu }
            '2' {
                $upd = Test-UpdateAvailable
                if ($upd -eq $null) {
                    Write-Fail 'Не удалось проверить обновления.'
                    if ($script:LastUpdateCheckError) { Write-Note ("Причина: " + $script:LastUpdateCheckError) }
                    Write-Note 'Подробнее: [5] Диагностика доступа к GitHub.'
                }
                elseif ($upd)       { Write-Note 'Доступна новая версия! Используйте «Автообновление».' }
                else                { Write-Ok "У вас актуальная версия ($script:ScriptVersion)." }
                Wait-Enter
            }
            '3' { Update-LDManagerSelf }
            '4' { Show-RepoMenu }
            '5' { Show-GithubDiagnostics }
            '0' { return }
            'q' { return }
            default { Write-Fail 'Неизвестный пункт меню.'; Start-Sleep -Milliseconds 500 }
        }
    }
}

# ===========================================================================
# Цифровая подпись скрипта (self-signed CodeSigning)
# ===========================================================================
function Invoke-ScriptSigning {
    Write-Title 'Цифровая подпись скрипта'
    if (-not $PSCommandPath) { Write-Fail 'Не удалось определить путь скрипта.'; Wait-Enter; return }

    $cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert -ErrorAction SilentlyContinue |
            Where-Object { $_.Subject -like '*LDManager*' } | Select-Object -First 1

    if ($cert) {
        Write-Ok ("Найден существующий сертификат: {0} (до {1:yyyy-MM-dd})" -f $cert.Subject, $cert.NotAfter)
    } else {
        Write-Host '  Сертификат подписи не найден. Будет создан self-signed CodeSigning сертификат.'
        Write-Note 'Сертификат будет доверенным только на этом компьютере (CurrentUser).'
        if (-not (Confirm-Action 'Создать сертификат?')) { Write-Note 'Отменено.'; Wait-Enter; return }
        try {
            $cert = New-SelfSignedCertificate -Subject 'CN=LDManager Code Signing' -Type CodeSigningCert `
                -KeyUsage DigitalSignature -KeyExportPolicy Exportable -NotAfter (Get-Date).AddYears(3) `
                -CertStoreLocation Cert:\CurrentUser\My
        } catch {
            Write-Fail "Не удалось создать сертификат: $($_.Exception.Message)"
            Write-Note 'Возможно, требуется запуск от имени администратора или обновление Windows.'
            Wait-Enter
            return
        }
        # Сертификат должен находиться в доверенных корнях (Root) и издателях
        # (TrustedPublisher) ТЕКУЩЕГО ПОЛЬЗОВАТЕЛЯ — иначе цепочка не строится и
        # подпись даёт UnknownError («...прервана на корневом сертификате, у
        # которого отсутствует отношение доверия»). TrustedPeople недостаточно.
        try {
            $cerPath = Join-Path $env:TEMP ("LDManager_{0}.cer" -f $cert.Thumbprint)
            [System.IO.File]::WriteAllBytes($cerPath, $cert.Export('Cert'))
            foreach ($storeName in @('Root', 'TrustedPublisher')) {
                try {
                    Import-Certificate -FilePath $cerPath -CertStoreLocation ("Cert:\CurrentUser\$storeName") | Out-Null
                } catch { }
            }
            Remove-Item $cerPath -Force -ErrorAction SilentlyContinue
        } catch { }
        Write-Ok ("Сертификат создан: {0}" -f $cert.Thumbprint)
    }

    # Подписываем ВСЕ файлы скрипта: при AllSigned каждая загружаемая единица
    # (точка входа, ядро, Sieve) должна иметь валидную подпись.
    $files = @($PSCommandPath)
    foreach ($f in @((Join-Path $scriptRoot 'LDManager.core.ps1'), (Join-Path $scriptRoot 'LD.Sieve.ps1'))) {
        if ((Test-Path $f) -and ($files -notcontains $f)) { $files += $f }
    }

    $failed = $false
    foreach ($f in $files) {
        # Метка времени, чтобы подпись не «умерла» вместе с сертификатом; без сети — без метки.
        $res = Set-AuthenticodeSignature -FilePath $f -Certificate $cert -TimestampServer 'http://timestamp.digicert.com'
        if ($res.Status -ne 'Valid') { $res = Set-AuthenticodeSignature -FilePath $f -Certificate $cert }
        $name = Split-Path $f -Leaf
        if ($res.Status -eq 'Valid') { Write-Ok "Подписан: $name" }
        else { $failed = $true; Write-Note ("Статус подписи {0}: {1} ({2})" -f $name, $res.Status, $res.StatusMessage) }
    }
    if ($failed) {
        Write-Note 'Если статус UnknownError/NotTrusted: перезапустите скрипт — доверие к новому корню применяется к новой сессии.'
    }
    Wait-Enter
}

# ===========================================================================
# Информация о версиях
# ===========================================================================
function Show-VersionInfo {
    Show-Banner
    Write-Title 'Информация о версиях'
    Write-Host ("  LDManager          : v$script:ScriptVersion")
    Write-Host ("  Репозиторий        : https://github.com/$script:RepoOwner/$script:RepoName")

    $ldVer = $null
    if ($script:LdPath) {
        $v = (Get-Item $script:LdPath).VersionInfo.ProductVersion
        if ($v) { $ldVer = $v }
    }
    Write-Host ("  ldconsole.exe      : " + $(if ($script:LdPath) { "$script:LdPath" + $(if ($ldVer) { " (v$ldVer)" }) } else { '(не найден)' }))
    Write-Host ("  adb.exe            : " + $(if ($script:AdbPath -and (Test-Path $script:AdbPath)) { $script:AdbPath } else { '(не найден)' }))
    if ($script:AdbPath -and (Test-Path $script:AdbPath)) {
        $a = Invoke-Adb -Arguments @('version') | Select-Object -First 1
        if ($a) { Write-Host "  adb version        : $a" }
    }
    try {
        $psv = $PSVersionTable.PSVersion.ToString()
    } catch { $psv = '?' }
    Write-Host "  PowerShell         : $psv"
    Write-Host ("  Windows            : $([Environment]::OSVersion.VersionString)")

    $sig = Get-AuthenticodeSignature -FilePath $PSCommandPath -ErrorAction SilentlyContinue
    $sigStatus = if ($sig) { "$($sig.Status)" } else { 'нет' }
    Write-Host "  Подпись скрипта    : $sigStatus"

    Write-Host ''
    Write-Host '  Проверка обновлений...'
    $upd = Test-UpdateAvailable
    if ($upd -eq $null) {
        Write-Note 'Не удалось проверить обновления.'
        if ($script:LastUpdateCheckError) { Write-Note ("  Причина: " + $script:LastUpdateCheckError) }
    }
    elseif ($upd)            { Write-Note 'Доступна новая версия! См. пункт «Автообновление».' }
    else                     { Write-Ok 'У вас актуальная версия.' }
    Wait-Enter
}

# ===========================================================================
# Подменю: инстансы / приложения / конфигурация
# ===========================================================================
function Show-InstanceMenu {
    while ($true) {
        Show-Banner
        Write-Title 'Инстансы'
        Show-InstanceTable -Instances (Get-LDInstances)
        Write-Host ''
        Write-Host '  [1] Запустить инстанс'
        Write-Host '  [2] Остановить инстанс'
        Write-Host '  [3] Перезапустить инстанс'
        Write-Host '  [4] Остановить ВСЕ инстансы'
        Write-Host '  [5] Создать новый инстанс'
        Write-Host '  [6] Клонировать инстанс'
        Write-Host '  [7] Переименовать инстанс'
        Write-Host '  [8] УДАЛИТЬ инстанс (необратимо!)'
        Write-Host '  [9] Расставить окна (sortWnd)'
        Write-Host '  [r] Обновить список'
        Write-Host ''
        Write-Host '  [0] Назад'
        $c = (Read-Host 'Выбор').Trim()
        switch ($c) {
            '1' { Start-LDInstance }
            '2' { Stop-LDInstance }
            '3' { Restart-LDInstance }
            '4' { Stop-AllLDInstances }
            '5' { New-LDInstance }
            '6' { Copy-LDInstance }
            '7' { Rename-LDInstance }
            '8' { Remove-LDInstance }
            '9' { Sort-LDWindows }
            'r' { }
            '0' { return }
            'q' { return }
            default { Write-Fail 'Неизвестный пункт меню.'; Start-Sleep -Milliseconds 500 }
        }
    }
}

function Show-AppMenu {
    while ($true) {
        Show-Banner
        Write-Title 'Приложения'
        Write-Host '  [1] Установить APK (ldconsole installapp)'
        Write-Host '  [2] Запустить приложение (по имени пакета)'
        Write-Host '  [3] Остановить приложение (force stop)'
        Write-Host '  [4] Удалить приложение'
        Write-Host '  [5] Очистить данные приложения (pm clear)'
        Write-Host ''
        Write-Host '  [0] Назад'
        $c = (Read-Host 'Выбор').Trim()
        switch ($c) {
            '1' { Install-LDApp }
            '2' { Invoke-LDAppCommand -Command 'runapp'       -Title 'запуск приложения' }
            '3' { Force-StopApp }
            '4' { Invoke-LDAppCommand -Command 'uninstallapp' -Title 'удаление приложения' }
            '5' { Clear-LDAppData }
            '0' { return }
            'q' { return }
            default { Write-Fail 'Неизвестный пункт меню.'; Start-Sleep -Milliseconds 500 }
        }
    }
}

function Show-ConfigMenu {
    while ($true) {
        Show-Banner
        Write-Title 'Конфигурация инстанса'
        Write-Host '  Изменения применяются после перезапуска инстанса.' -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '  [1] Разрешение экрана и DPI'
        Write-Host '  [2] CPU и RAM'
        Write-Host '  [3] Root вкл/выкл'
        Write-Host ''
        Write-Host '  [0] Назад'
        $c = (Read-Host 'Выбор').Trim()
        switch ($c) {
            '1' { Set-LDResolution }
            '2' { Set-LDCpuRam }
            '3' { Set-LDRoot }
            '0' { return }
            'q' { return }
            default { Write-Fail 'Неизвестный пункт меню.'; Start-Sleep -Milliseconds 500 }
        }
    }
}

# ===========================================================================
# Главное меню
# ===========================================================================
function Show-MainMenu {
    while ($true) {
        Show-Banner
        Write-Title 'Главное меню'
        # Самодиагностика: путь должен указывать именно на ldconsole.exe,
        # а не на dnplayer.exe (GUI) — иначе команды меню молча не работают.
        if ($script:LdPath) {
            $ldLeaf = Split-Path $script:LdPath -Leaf
            if ($ldLeaf -ine 'ldconsole.exe') {
                Write-Host ("  ldconsole : " + $script:LdPath) -ForegroundColor Yellow
                Write-Host '  [!!] ВНИМАНИЕ: указанный файл — не ldconsole.exe, команды меню работать не будут.' -ForegroundColor Yellow
                Write-Host '       Задайте верный путь в [S] Настройки.' -ForegroundColor Yellow
            } else {
                Write-Host ("  ldconsole : " + $script:LdPath)
            }
        } else {
            Write-Host '  ldconsole : (НЕ НАЙДЕН — см. [S] Настройки)'
        }
        Write-Host ''
        Write-Host '  [1] Инстансы - список, запуск, остановка, создание, клонирование, удаление'
        Write-Host '  [2] Приложения - APK, запуск/остановка/удаление, очистка данных'
        Write-Host '  [3] Конфигурация - CPU, RAM, разрешение, root'
        Write-Host '  [4] Идентификация устройства - IMEI/AndroidID/MAC, модель, SIM-страна'
        Write-Host '  [5] ADB - shell, команды, APK, файлы, скриншот, запись экрана'
        Write-Host '  [6] Действия - GPS, клавиши, сеть'
        Write-Host '  [7] Логи - файлы LDPlayer + adb logcat'
        Write-Host '  [8] Окна - показать/скрыть/расставить'
        Write-Host '  [9] Массовые операции - все инстансы'
        Write-Host '  [b] Резервные копии - backup/restore (.ldbk)'
        Write-Host '  [g] GitHub - токен (DPAPI), автообновление, загрузка репозитория'
        Write-Host '  [s] Подпись скрипта (self-signed CodeSigning)'
        Write-Host '  [v] Информация о версиях'
        Write-Host '  [S] Настройки - пути к ldconsole.exe / adb.exe'
        Write-Host ''
        Write-Host '  [0] Выход'

        $c = (Read-Host 'Выбор').Trim()
        switch ($c) {
            '1' { Show-InstanceMenu }
            '2' { Show-AppMenu }
            '3' { Show-ConfigMenu }
            '4' { Show-IdentityMenu }
            '5' { Show-AdbMenu }
            '6' { Show-ActionMenu }
            '7' { Show-LogsMenu }
            '8' { Show-WindowsMenu }
            '9' { Show-BulkMenu }
            'b' { Show-BackupMenu }
            'g' { Show-GithubMenu }
            's' { Invoke-ScriptSigning }
            'v' { Show-VersionInfo }
            'S' { Show-SettingsMenu }
            '0' { return }
            'q' { return }
            default { Write-Fail 'Неизвестный пункт меню.'; Start-Sleep -Milliseconds 500 }
        }
    }
}

# ===========================================================================
# Меню логов (создаётся здесь, т.к. использует Show-LdLogFiles/Show-LogcatMenu)
# ===========================================================================
function Show-LogsMenu {
    while ($true) {
        Show-Banner
        Write-Title 'Логи'
        Write-Host '  [1] Файлы логов LDPlayer (logs\*.log)'
        Write-Host '  [2] adb logcat (снапшот / live / фильтры)'
        Write-Host ''
        Write-Host '  [0] Назад'
        $c = (Read-Host 'Выбор').Trim()
        switch ($c) {
            '1' { Show-LdLogFiles }
            '2' { Show-LogcatMenu }
            '0' { return }
            'q' { return }
            default { Write-Fail 'Неизвестный пункт меню.'; Start-Sleep -Milliseconds 500 }
        }
    }
}

# ===========================================================================
# Меню GitHub (токен / автообновление / загрузка репозитория)
# ===========================================================================
function Show-GithubMenu {
    while ($true) {
        Show-Banner
        Write-Title 'GitHub'
        Write-Host ("  Репозиторий: https://github.com/$script:RepoOwner/$script:RepoName")
        $t = Get-StoredGithubToken
        Write-Host ("  Токен      : " + $(if ($t) { 'сохранён (DPAPI)' } else { 'не задан' }))
        Write-Host ''
        Write-Host '  [1] Менеджер GitHub-токена (DPAPI)'
        Write-Host '  [2] Проверить обновления'
        Write-Host '  [3] Автообновление скрипта из GitHub'
        Write-Host '  [4] Загрузка репозитория (clone / ZIP / файл)'
        Write-Host '  [5] Диагностика доступа к GitHub'
        Write-Host ''
        Write-Host '  [0] Назад'
        $c = (Read-Host 'Выбор').Trim()
        switch ($c) {
            '1' { Show-GithubTokenMenu }
            '2' {
                $upd = Test-UpdateAvailable
                if ($upd -eq $null) {
                    Write-Fail 'Не удалось проверить обновления.'
                    if ($script:LastUpdateCheckError) { Write-Note ("Причина: " + $script:LastUpdateCheckError) }
                    Write-Note 'Подробнее: [5] Диагностика доступа к GitHub.'
                }
                elseif ($upd)       { Write-Note 'Доступна новая версия! Используйте «Автообновление».' }
                else                { Write-Ok "У вас актуальная версия ($script:ScriptVersion)." }
                Wait-Enter
            }
            '3' { Update-LDManagerSelf }
            '4' { Show-RepoMenu }
            '5' { Show-GithubDiagnostics }
            '0' { return }
            'q' { return }
            default { Write-Fail 'Неизвестный пункт меню.'; Start-Sleep -Milliseconds 500 }
        }
    }
}

# ===========================================================================
# Точка входа
# ===========================================================================
function Initialize-LDManager {
    # UTF-8 для корректного отображения вывода adb/ldconsole (иначе кракозябры)
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $global:OutputEncoding = [System.Text.Encoding]::UTF8
    } catch { }

    $found = Resolve-LDConsolePath
    if ($found) {
        $script:LdPath = $found
        Save-ManagerConfig -LdConsolePath $found
    } else {
        Show-Banner
        Write-Note 'ldconsole.exe не найден автоматически.'
        Write-Note 'Убедитесь, что LDPlayer установлен, или укажите путь вручную (Настройки).'
        Wait-Enter
        Show-SettingsMenu
    }
    [void](Get-AdbExePath)
}

try {
    Initialize-LDManager
    Show-MainMenu
} catch {
    Write-Host ''
    Write-Fail "Критическая ошибка: $($_.Exception.Message)"
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray }
    Wait-Enter
}



# SIG # Begin signature block
# MIIb5gYJKoZIhvcNAQcCoIIb1zCCG9MCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUKJyerdGpancBfImX/cmygHEi
# iImgghZQMIIDEjCCAfqgAwIBAgIQHb8OO1X7MrdClKYHA5HxWzANBgkqhkiG9w0B
# AQsFADAhMR8wHQYDVQQDDBZMRE1hbmFnZXIgQ29kZSBTaWduaW5nMB4XDTI2MDkz
# MDExNDMzNFoXDTI5MDkzMDExNTMzNFowITEfMB0GA1UEAwwWTERNYW5hZ2VyIENv
# ZGUgU2lnbmluZzCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAKaLCNs9
# rBsbGIPghRS3TY4uvmEDKa8H+lYeEv84MJKEp1YXGLGd+X8C9jMvwO82p0fCAoGD
# fS8kWxVX39kjlDI4/drWnj6OwYgq2gYxCSRvSB9vVKKAhmH3pB1T/jFXXYzf8EvG
# m26Rx4b7FwmNE2sVPsK8MM4MbtH0L88oOzp7xYnTakT46yhEmD3zxEyA8RCDOSiT
# ZQ6dKLqQI6IjZxhQXRl2YcrngyBRc4+2u48W6yBCcbAbypsUfTbU1nKjoMO3xW35
# /NhrUO6C/4akcVeZz0taubqfCN++HIijCT4QdtlUOMjgJNi/n/0NNK2z8MOs8D/p
# DKe13YiA0GBZnV0CAwEAAaNGMEQwDgYDVR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoG
# CCsGAQUFBwMDMB0GA1UdDgQWBBTj+hFv2ccL1E8WD9d5eFkJmZVFpDANBgkqhkiG
# 9w0BAQsFAAOCAQEAGe1131HmYJjz9N/Uvfvm+DeNAFqLUlX5U5UokyQxTf5+ivTc
# AZiUCNQ0jl+qUVleT+a97cvI+UBoa3yl+uYoT+OP9hh27UHIvovPQl+KTkL//gVZ
# KzMfuSW2ONV6CsB60CR1/10GTYmRbKV4ZLOzO3ZliCHp4v0od+2qdVMRMcpa4FJJ
# G9NgOA8qfBXrj4aajsGfpAa5xhi0JFy8ecBIekrNtmBq9Rzq6IAkUktHzxQd/eFw
# WJjbiJbZdGEvLSSGSDtdgcXTfBehHscJrJdnYkhlOeOXnWHCUR6/2S4ML+S4j4dt
# KJ+xHVxvXhS9sdT8YTqqElgrAiHk3ZbM65N8uDCCBY0wggR1oAMCAQICEA6bGI75
# 0C3n79tQ4ghAGFowDQYJKoZIhvcNAQEMBQAwZTELMAkGA1UEBhMCVVMxFTATBgNV
# BAoTDERpZ2lDZXJ0IEluYzEZMBcGA1UECxMQd3d3LmRpZ2ljZXJ0LmNvbTEkMCIG
# A1UEAxMbRGlnaUNlcnQgQXNzdXJlZCBJRCBSb290IENBMB4XDTIyMDgwMTAwMDAw
# MFoXDTMxMTEwOTIzNTk1OVowYjELMAkGA1UEBhMCVVMxFTATBgNVBAoTDERpZ2lD
# ZXJ0IEluYzEZMBcGA1UECxMQd3d3LmRpZ2ljZXJ0LmNvbTEhMB8GA1UEAxMYRGln
# aUNlcnQgVHJ1c3RlZCBSb290IEc0MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIIC
# CgKCAgEAv+aQc2jeu+RdSjwwIjBpM+zCpyUuySE98orYWcLhKac9WKt2ms2uexuE
# DcQwH/MbpDgW61bGl20dq7J58soR0uRf1gU8Ug9SH8aeFaV+vp+pVxZZVXKvaJNw
# wrK6dZlqczKU0RBEEC7fgvMHhOZ0O21x4i0MG+4g1ckgHWMpLc7sXk7Ik/ghYZs0
# 6wXGXuxbGrzryc/NrDRAX7F6Zu53yEioZldXn1RYjgwrt0+nMNlW7sp7XeOtyU9e
# 5TXnMcvak17cjo+A2raRmECQecN4x7axxLVqGDgDEI3Y1DekLgV9iPWCPhCRcKtV
# gkEy19sEcypukQF8IUzUvK4bA3VdeGbZOjFEmjNAvwjXWkmkwuapoGfdpCe8oU85
# tRFYF/ckXEaPZPfBaYh2mHY9WV1CdoeJl2l6SPDgohIbZpp0yt5LHucOY67m1O+S
# kjqePdwA5EUlibaaRBkrfsCUtNJhbesz2cXfSwQAzH0clcOP9yGyshG3u3/y1Yxw
# LEFgqrFjGESVGnZifvaAsPvoZKYz0YkH4b235kOkGLimdwHhD5QMIR2yVCkliWzl
# DlJRR3S+Jqy2QXXeeqxfjT/JvNNBERJb5RBQ6zHFynIWIgnffEx1P2PsIV/EIFFr
# b7GrhotPwtZFX50g/KEexcCPorF+CiaZ9eRpL5gdLfXZqbId5RsCAwEAAaOCATow
# ggE2MA8GA1UdEwEB/wQFMAMBAf8wHQYDVR0OBBYEFOzX44LScV1kTN8uZz/nupiu
# HA9PMB8GA1UdIwQYMBaAFEXroq/0ksuCMS1Ri6enIZ3zbcgPMA4GA1UdDwEB/wQE
# AwIBhjB5BggrBgEFBQcBAQRtMGswJAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRp
# Z2ljZXJ0LmNvbTBDBggrBgEFBQcwAoY3aHR0cDovL2NhY2VydHMuZGlnaWNlcnQu
# Y29tL0RpZ2lDZXJ0QXNzdXJlZElEUm9vdENBLmNydDBFBgNVHR8EPjA8MDqgOKA2
# hjRodHRwOi8vY3JsMy5kaWdpY2VydC5jb20vRGlnaUNlcnRBc3N1cmVkSURSb290
# Q0EuY3JsMBEGA1UdIAQKMAgwBgYEVR0gADANBgkqhkiG9w0BAQwFAAOCAQEAcKC/
# Q1xV5zhfoKN0Gz22Ftf3v1cHvZqsoYcs7IVeqRq7IviHGmlUIu2kiHdtvRoU9BNK
# ei8ttzjv9P+Aufih9/Jy3iS8UgPITtAq3votVs/59PesMHqai7Je1M/RQ0SbQyHr
# lnKhSLSZy51PpwYDE3cnRNTnf+hZqPC/Lwum6fI0POz3A8eHqNJMQBk1RmppVLC4
# oVaO7KTVPeix3P0c2PR3WlxUjG/voVA9/HYJaISfb8rbII01YBwCA8sgsKxYoA5A
# Y8WYIsGyWfVVa88nq2x2zm8jLfR+cWojayL/ErhULSd+2DrZ8LaHlv1b0VysGMNN
# n3O3AamfV6peKOK5lDCCBrQwggScoAMCAQICEA3HrFcF/yGZLkBDIgw6SYYwDQYJ
# KoZIhvcNAQELBQAwYjELMAkGA1UEBhMCVVMxFTATBgNVBAoTDERpZ2lDZXJ0IElu
# YzEZMBcGA1UECxMQd3d3LmRpZ2ljZXJ0LmNvbTEhMB8GA1UEAxMYRGlnaUNlcnQg
# VHJ1c3RlZCBSb290IEc0MB4XDTI1MDUwNzAwMDAwMFoXDTM4MDExNDIzNTk1OVow
# aTELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMUEwPwYDVQQD
# EzhEaWdpQ2VydCBUcnVzdGVkIEc0IFRpbWVTdGFtcGluZyBSU0E0MDk2IFNIQTI1
# NiAyMDI1IENBMTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALR4MdMK
# mEFyvjxGwBysddujRmh0tFEXnU2tjQ2UtZmWgyxU7UNqEY81FzJsQqr5G7A6c+Gh
# /qm8Xi4aPCOo2N8S9SLrC6Kbltqn7SWCWgzbNfiR+2fkHUiljNOqnIVD/gG3SYDE
# Ad4dg2dDGpeZGKe+42DFUF0mR/vtLa4+gKPsYfwEu7EEbkC9+0F2w4QJLVSTEG8y
# AR2CQWIM1iI5PHg62IVwxKSpO0XaF9DPfNBKS7Zazch8NF5vp7eaZ2CVNxpqumzT
# CNSOxm+SAWSuIr21Qomb+zzQWKhxKTVVgtmUPAW35xUUFREmDrMxSNlr/NsJyUXz
# dtFUUt4aS4CEeIY8y9IaaGBpPNXKFifinT7zL2gdFpBP9qh8SdLnEut/GcalNeJQ
# 55IuwnKCgs+nrpuQNfVmUB5KlCX3ZA4x5HHKS+rqBvKWxdCyQEEGcbLe1b8Aw4wJ
# khU1JrPsFfxW1gaou30yZ46t4Y9F20HHfIY4/6vHespYMQmUiote8ladjS/nJ0+k
# 6MvqzfpzPDOy5y6gqztiT96Fv/9bH7mQyogxG9QEPHrPV6/7umw052AkyiLA6tQb
# Zl1KhBtTasySkuJDpsZGKdlsjg4u70EwgWbVRSX1Wd4+zoFpp4Ra+MlKM2baoD6x
# 0VR4RjSpWM8o5a6D8bpfm4CLKczsG7ZrIGNTAgMBAAGjggFdMIIBWTASBgNVHRMB
# Af8ECDAGAQH/AgEAMB0GA1UdDgQWBBTvb1NK6eQGfHrK4pBW9i/USezLTjAfBgNV
# HSMEGDAWgBTs1+OC0nFdZEzfLmc/57qYrhwPTzAOBgNVHQ8BAf8EBAMCAYYwEwYD
# VR0lBAwwCgYIKwYBBQUHAwgwdwYIKwYBBQUHAQEEazBpMCQGCCsGAQUFBzABhhho
# dHRwOi8vb2NzcC5kaWdpY2VydC5jb20wQQYIKwYBBQUHMAKGNWh0dHA6Ly9jYWNl
# cnRzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRSb290RzQuY3J0MEMGA1Ud
# HwQ8MDowOKA2oDSGMmh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydFRy
# dXN0ZWRSb290RzQuY3JsMCAGA1UdIAQZMBcwCAYGZ4EMAQQCMAsGCWCGSAGG/WwH
# ATANBgkqhkiG9w0BAQsFAAOCAgEAF877FoAc/gc9EXZxML2+C8i1NKZ/zdCHxYga
# MH9Pw5tcBnPw6O6FTGNpoV2V4wzSUGvI9NAzaoQk97frPBtIj+ZLzdp+yXdhOP4h
# CFATuNT+ReOPK0mCefSG+tXqGpYZ3essBS3q8nL2UwM+NMvEuBd/2vmdYxDCvwzJ
# v2sRUoKEfJ+nN57mQfQXwcAEGCvRR2qKtntujB71WPYAgwPyWLKu6RnaID/B0ba2
# H3LUiwDRAXx1Neq9ydOal95CHfmTnM4I+ZI2rVQfjXQA1WSjjf4J2a7jLzWGNqNX
# +DF0SQzHU0pTi4dBwp9nEC8EAqoxW6q17r0z0noDjs6+BFo+z7bKSBwZXTRNivYu
# ve3L2oiKNqetRHdqfMTCW/NmKLJ9M+MtucVGyOxiDf06VXxyKkOirv6o02OoXN4b
# FzK0vlNMsvhlqgF2puE6FndlENSmE+9JGYxOGLS/D284NHNboDGcmWXfwXRy4kbu
# 4QFhOm0xJuF2EZAOk5eCkhSxZON3rGlHqhpB/8MluDezooIs8CVnrpHMiD2wL40m
# m53+/j7tFaxYKIqL0Q4ssd8xHZnIn/7GELH3IdvG2XlM9q7WP/UwgOkw/HQtyRN6
# 2JK4S1C8uw3PdBunvAZapsiI5YKdvlarEvf8EA+8hcpSM9LHJmyrxaFtoza2zNaQ
# 9k+5t1wwggbtMIIE1aADAgECAhAIT9wzT35FTtvDD4/5khg1MA0GCSqGSIb3DQEB
# CwUAMGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8G
# A1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBT
# SEEyNTYgMjAyNSBDQTEwHhcNMjYwODA1MDAwMDAwWhcNMzcxMTA0MjM1OTU5WjBj
# MQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xOzA5BgNVBAMT
# MkRpZ2lDZXJ0IFNIQTI1NiBSU0E0MDk2IFRpbWVzdGFtcCBSZXNwb25kZXIgMjAy
# NiAxMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAtnum8sn+zUr41JtM
# ZbP9OMYw+HwJDpG5xkIu/lqcfNYmMX81YmsUiHLbh9ykpeWBGKTLhYBrAN9Tdg/Q
# EzG32XcObmgIblnr0CoQ3WSAeDZ6nH6X6VkFyYkJw3QBJREwvm4UhLzSxmwPA7cF
# KRTEOMsmEEj6qJk/dqLEAL+oQYuOwE2UuiX1Vnul8YReIyWd4kgLn9gq6LNXM0Up
# lkR6jL/QHxmb6fMoGBJYbnaUI7XD6cKDpekK2SVMld4iDbzeHDtOaaxldH5IxuNu
# sQ69nd8/ZXEiB5Hbxj3RlK13cX1W4DlFXKdv/CEhM8Cj1vvlmvhNroyPdRGbbpBl
# gyf8Wdu5N6ByhFwURn0U6ozlPoxN22v+fviUhP+6DR547OZnpBMWDfei1f5sVGwi
# iW/KQTWOK97g+4RJpPzPNV4VYMAwO2jM2Aty2QYPVmOQTJm0msuXnJrSbl2gf9Jy
# lpkJlWXqk1Q4LJsxz+TELoQCZIljbgvTJgoPU2R12ydv8i1UqL/adelA0y7U9Pmm
# tbze9Xx3rtajC5SzQd1jgfwAwsa90v9YcSPdmeoyoBBA/27cCL237l5DTYYPDLQ4
# ON3OLTGWnvRb6jDrf/T75gMRfUzSLCBQfBusm9+mSWRlC/Df6S/e9Q8i13CuhzOT
# 2Jx+V/nlbXM4QoBwlUAhelwwJT0CAwEAAaOCAZUwggGRMAwGA1UdEwEB/wQCMAAw
# HQYDVR0OBBYEFBTJY4owLtRK+26U8+bjQH717M3iMB8GA1UdIwQYMBaAFO9vU0rp
# 5AZ8esrikFb2L9RJ7MtOMA4GA1UdDwEB/wQEAwIHgDAWBgNVHSUBAf8EDDAKBggr
# BgEFBQcDCDCBlQYIKwYBBQUHAQEEgYgwgYUwJAYIKwYBBQUHMAGGGGh0dHA6Ly9v
# Y3NwLmRpZ2ljZXJ0LmNvbTBdBggrBgEFBQcwAoZRaHR0cDovL2NhY2VydHMuZGln
# aWNlcnQuY29tL0RpZ2lDZXJ0VHJ1c3RlZEc0VGltZVN0YW1waW5nUlNBNDA5NlNI
# QTI1NjIwMjVDQTEuY3J0MF8GA1UdHwRYMFYwVKBSoFCGTmh0dHA6Ly9jcmwzLmRp
# Z2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRHNFRpbWVTdGFtcGluZ1JTQTQwOTZT
# SEEyNTYyMDI1Q0ExLmNybDAgBgNVHSAEGTAXMAgGBmeBDAEEAjALBglghkgBhv1s
# BwEwDQYJKoZIhvcNAQELBQADggIBAI3FOmEenVIK35msCYB+fShAsWvSYvLBItoN
# dAgQ2jIqrGsVsluXMJU/+mRebBc52s6lbKAvOVPXaizmKkMLLflEEKDZQx4CkS2t
# 8aHPjkXha3hYZ010htFa3dhNgmalH5vuWvh3tTCf4frTS7gPtGc4Z/xaPhQ2AB1m
# R8eEe/WbH0RWHvVIl6VwQ3+g5FKNfN2N/DWJkf13w2H+2GfqEfbd35Ww8CvoYBjL
# NIDTadcPWdgsjsiOaK/7EsKJgLjUNIVgvcaFOLLQ/GlrA+0ZHJoFUbOr5SJN8zyk
# PspXIXlpDJY/gqFUZRROeab9GVgmhbdOJcD/63RhxPahFUGbckRONqMe6DYAv6/m
# OG0pWd3cPStsdcS7buj5DyniwRY8yooMH6ptx5vpP/pZzBPBeZD2U4IsthyxB5Ja
# a8qrOkB5z160TXiM5ADMspZ0TfD9MJoq0tFpFPssKRFhWeEDYPvcUuN7U7lvcdHl
# 4ezQ3NT/7Ffs1sR1yh/LRbdZ3B3Vc6q2WmD8mDC0p9kzl2o73iVtS946IkEj7FkR
# sZGww1teYxERROC745xrtjvcw9ZyyUjHZWGRIpJeMNsPquCDf0fkyHtB+J4AiNZq
# CQk23rxh+KbpyMTNVKItJ5l92Svl20U9NbqMBOVYl1h54NEYLJq1/xHWFKPNK903
# zJZA9P2DMYIFADCCBPwCAQEwNTAhMR8wHQYDVQQDDBZMRE1hbmFnZXIgQ29kZSBT
# aWduaW5nAhAdvw47Vfsyt0KUpgcDkfFbMAkGBSsOAwIaBQCgeDAYBgorBgEEAYI3
# AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisG
# AQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMCMGCSqGSIb3DQEJBDEWBBTwWfm3JhLq
# dEGluMMQfAClNKQqxDANBgkqhkiG9w0BAQEFAASCAQArSvGq1CN/rFUaKE605Mxw
# MnTdliBT/PrbBUlXBsJdBpb6MPzth9hzKXzCgagzP8vkCHh8cpA82EPga6R9Y68r
# uf5DP41ZOMwMPiVMQgLwNb9NBIpVG4hRPfYawL3mugxTGJwkXCfDmaDDUNsCDBpx
# HjGlC7NX2wAhxkg9H/0B3iTfpLWeZiS9ePzrutoxBKkq+meFSKtwwDvOuoESFdwj
# OE1zaRp3SZIKRoRzaR3Wr6zDJO2Zz5EM2FLCompJpdq1M+oBf5Bkyo0wy/zAMA9F
# DtSlJ3p3adHNcFBa2te2ABLomifdTrJLOukeNdwL38ytNkctDD1lW7DWmGhZF8cK
# oYIDJjCCAyIGCSqGSIb3DQEJBjGCAxMwggMPAgEBMH0waTELMAkGA1UEBhMCVVMx
# FzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVz
# dGVkIEc0IFRpbWVTdGFtcGluZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMQIQCE/c
# M09+RU7bww+P+ZIYNTANBglghkgBZQMEAgEFAKBpMBgGCSqGSIb3DQEJAzELBgkq
# hkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8XDTI2MDkzMDEyMzUzM1owLwYJKoZIhvcN
# AQkEMSIEIL5vrB2WqfuEkD9/BEZmv+3ED9XbrSEbjyjKF3pixluzMA0GCSqGSIb3
# DQEBAQUABIICAALDhE9TpOMNWMiRNdTS8cytEbmtLwR0oMy/8gH2ypqWIGRXVJYO
# IEyJNB+k49gAvlym8K6Y2f56dkD0KXVifQhV3qPyriXkk02stJwaoM2Xy5wxueDt
# jTJpIJMuu4hNxwGfKF4LE8Yg1+V+cXDx9l7tFF6C0gjNhnCJU2i7+stFQXfXpQlq
# kWucBkazpkMowc7QKLe/Zz+wB4/3zg0Uq05IkjJDeHM+sKpFYYFgEHfOuVX+DzcZ
# P/rANtj+UVL9rf0U/kjRec6hYQvQLOI2rTEZkpdpylQFrRUZ6hyhR+bXQIqvzMLi
# zBw2wirFUZYenubAOuMhI9s00wgFrgXGwAvSJKoBaIQwam+VT7EwRDolPm+wYCir
# Nycf0Zne7gY1tWrg4Rxqt8M0MZJNQ3Wz5geOy+m0px71O7zoA/QaJ+QPdKKEqoqu
# Tk4/HL1OwSPOgp+yTby3xLo2UtEpWay5HGbIW5cbvDpodoFVmWFU3R2lFMU2nniA
# cXuKsLHVxUi0TuvIJiftKaRic3xiO7euGLbnJt56KkeNzaeEuWEOkB/eOpj07UzO
# S8HXsOGXDG6p/WQfr8KNkQDW5Zzrw6Yx7WCiDsnVXFpboCoJH8jqqZiYf8XSjKmP
# +w0UvR+PmYQek3GlRkyNV5HrsUVfqs2nkzfPsRNYsJCoBwS/3liBrjZI
# SIG # End signature block
