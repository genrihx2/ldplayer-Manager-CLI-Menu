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
$script:ScriptVersion = '2.0.6'
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

    # Имена из runninglist. Формат зависит от версии: 'index,name,...' или просто
    # имя на строке (наблюдается в LDPlayer 14) — разбираем оба варианта.
    $runningNames = @()
    if ($runningRaw) {
        foreach ($l in ($runningRaw -split "\r?\n")) {
            $l = $l.Trim()
            if (-not $l) { continue }
            $f = $l.Split(',')
            if ($f.Count -ge 2) { $runningNames += $f[1].Trim() }
            else { $runningNames += $l }
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
            # Признак запуска: поле 4 из list2 (Android запущен) ИЛИ имя в runninglist.
            # Раньше поле list2 учитывалось только при ПУСТОМ runninglist: если тот
            # возвращал непустой, но неразбираемый вывод, запущенный инстанс считался
            # остановленным, и ADB-операции отказывали с «Инстанс не запущен».
            $r = 0
            $running = ([int]::TryParse($f[4].Trim(), [ref]$r) -and $r -eq 1)
            if (-not $running -and $runningNames -contains $name) { $running = $true }

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
        Write-Note 'Если только что запустили его — подождите полной загрузки Android и повторите.'
        Wait-Enter
        return $null
    }
    return $found
}

# ---------------------------------------------------------------------------
# Конфиг инстанса (vms\leidianN\config.ini) и команда modify
# ---------------------------------------------------------------------------
function Get-LDInstanceIdentity {
    # Текущие значения идентификации инстанса. Два формата хранения:
    #  - классика: vms\leidianN\config.ini (ключи imei=, imsi=, ...)
    #  - LDPlayer 14: vms\config\leidianN.config (JSON, ключи propertySettings.*)
    param([int]$Index)

    $base = Split-Path $script:LdPath -Parent

    # 1) Классический INI
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

    # 2) JSON-конфиг LDPlayer 14
    $jsonPath = Join-Path $base "vms\config\leidian$Index.config"
    if (Test-Path $jsonPath) {
        try {
            $j = Get-Content $jsonPath -Raw | ConvertFrom-Json
            return [pscustomobject]@{
                Ini          = $jsonPath
                Imei         = $j.'propertySettings.phoneIMEI'
                Imsi         = $j.'propertySettings.phoneIMSI'
                SimSerial    = $j.'propertySettings.phoneSimSerial'
                AndroidId    = $j.'propertySettings.phoneAndroidId'
                Mac          = $j.'propertySettings.macAddress'
                Manufacturer = $j.'propertySettings.phoneManufacturer'
                Model        = $j.'propertySettings.phoneModel'
                PhoneNumber  = $j.'propertySettings.phoneNumber'
            }
        } catch { }
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

function Get-AdbDebugState {
    # Признак включённой ADB-отладки инстанса из JSON-конфига LDPlayer 14
    # (basicSettings.adbDebug: 0/пусто = выкл, 1/2 = вкл). $null - конфиг не найден.
    param([int]$Index)
    if (-not $script:LdPath) { return $null }
    $base = Split-Path $script:LdPath -Parent
    $cfg = Join-Path $base "vms\config\leidian$Index.config"
    if (Test-Path $cfg) {
        try {
            $j = Get-Content $cfg -Raw | ConvertFrom-Json
            $prop = $j.PSObject.Properties['basicSettings.adbDebug']
            if ($prop -and $prop.Value) { return ([int]$prop.Value -ne 0) }
            return $false
        } catch { }
    }
    return $null
}

function Enable-LDAdb {
    # Включает ADB-отладку инстанса правкой JSON-конфига LDPlayer 14:
    # добавить/обновить basicSettings.adbDebug = 2. Если инстанс запущен -
    # предлагает остановить, поправить и запустить снова.
    param([object]$Instance)
    if (Get-AdbDebugState -Index $Instance.Index) {
        Write-Ok "ADB-отладка уже включена в конфиге инстанса $($Instance.Index)."
        return $true
    }
    $wasRunning = $Instance.Running
    if ($wasRunning) {
        if (-not (Confirm-Action "ADB-отладка выключена. Остановить инстанс, включить и запустить снова?")) {
            Write-Note 'Отменено.'
            return $false
        }
        [void](Invoke-LDConsole -Arguments @('quit','--index',[string]$Instance.Index))
        Start-Sleep -Seconds 10
    }
    $base = Split-Path $script:LdPath -Parent
    $cfg = Join-Path $base "vms\config\leidian$($Instance.Index).config"
    if (-not (Test-Path $cfg)) { Write-Fail "Конфиг не найден: $cfg"; return $false }
    try {
        $j = Get-Content $cfg -Raw | ConvertFrom-Json
        $j | Add-Member -Force -NotePropertyName 'basicSettings.adbDebug' -NotePropertyValue 2
        $j | ConvertTo-Json -Depth 10 | Set-Content $cfg -Encoding UTF8
        Write-Ok 'ADB-отладка включена в конфиге (basicSettings.adbDebug = 2).'
        if ($wasRunning) {
            [void](Invoke-LDConsole -Arguments @('launch','--index',[string]$Instance.Index))
            Write-Note 'Инстанс запускается заново - подождите полной загрузки Android.'
        } else {
            Write-Note 'Запустите инстанс - ADB-порт появится после загрузки Android.'
        }
        return $true
    } catch {
        Write-Fail "Не удалось изменить конфиг: $($_.Exception.Message)"
        return $false
    }
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

        # LDPlayer-инстансы adb часто саморегистрирует как emulator-<порт-1>
        # (5557 -> emulator-5556). Если такой serial в статусе device - он и есть
        # наш инстанс, считаем подключение успешным.
        $emu = 'emulator-' + ($Port - 1)
        $emuPattern = [regex]::Escape($emu) + '\s+device'
        if ($dev -and $dev -match $emuPattern) { return $target }

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

    # Если ADB-отладка выключена в конфиге инстанса - порты и не появятся:
    # предложим включить её прямо здесь (правка JSON-конфига + перезапуск).
    if ((Get-AdbDebugState -Index $Index) -eq $false) {
        Write-Note 'ADB-отладка выключена в настройках этого инстанса.'
        if (Confirm-Action 'Включить ADB-отладку сейчас (правка конфига + перезапуск инстанса)?') {
            $fakeInst = [pscustomobject]@{ Index = $Index; Name = $Name; Running = $false }
            if (Enable-LDAdb -Instance $fakeInst) {
                Write-Note 'Запустите инстанс и повторите ADB-операцию после загрузки Android.'
                Wait-Enter
                return $null
            }
        } else {
            Write-Note 'Включите «Отладка по ADB» в LDPlayer: Настройки -> Другие настройки.'
        }
    }

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

function Get-LDRootState {
    # Читает фактическое состояние root из конфига инстанса (vms\config\leidianN.config).
    # Возвращает $true/$false или $null, если конфиг не найден/не разобрался.
    param([int]$Index)
    if (-not $script:LdPath) { return $null }
    $base = Split-Path $script:LdPath -Parent
    $cfg = Join-Path $base "vms\config\leidian$Index.config"
    if (Test-Path $cfg) {
        try {
            $json = Get-Content $cfg -Raw | ConvertFrom-Json
            $prop = $json.PSObject.Properties['basicSettings.rootMode']
            if ($prop) { return [bool]$prop.Value }
        } catch { }
    }
    return $null
}

function Set-LDRoot {
    $inst = Select-LDInstance -Purpose 'root'
    if (-not $inst) { return }
    $on = Confirm-Action 'Включить root? (N = выключить)'
    Invoke-LDModify -Index $inst.Index -Props @{ root = $(if ($on) { '1' } else { '0' }) }

    # Читаем состояние обратно из конфига - подтверждаем реальный результат,
    # а не только «команда выполнена».
    $state = Get-LDRootState -Index $inst.Index
    if ($null -ne $state) {
        if ($state -eq $on) { Write-Ok ("Проверено в конфиге инстанса: root {0}" -f $(if ($state) { 'ВКЛЮЧЁН' } else { 'ВЫКЛЮЧЕН' })) }
        else { Write-Note 'Конфиг не отразил изменение - перезапустите окно LDPlayer и повторите.' }
    }
    Write-Note 'Переключатель в окне LDPlayer обновится после его закрытия/открытия; действует после запуска инстанса.'
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
    # LDPlayer 9: папка logs\ ; LDPlayer 14: log\ ; плюс папки инстансов vms\leidianN\
    $logDirs = @((Join-Path $base 'logs'), (Join-Path $base 'log'))
    $vmsRoot = Join-Path $base 'vms'
    if (Test-Path $vmsRoot) {
        $logDirs += @(Get-ChildItem $vmsRoot -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
    }
    $files = @()
    foreach ($d in $logDirs) {
        if (Test-Path $d) { $files += Get-ChildItem $d -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '^\.(log|txt)$' } }
    }
    $files = @($files | Sort-Object LastWriteTime -Descending)
    if ($files.Count -eq 0) { Write-Note 'Лог-файлы не найдены. Искал *.log/*.txt в logs\, log\ и подпапках vms\ внутри установки LDPlayer.'; Wait-Enter; return }

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
            # DPAPI текущего пользователя: конфиг с другой машины даёт $null —
            # возвращаем пусто вместо падения в вызывающем коде.
            $sec = ConvertTo-SecureString -String $cfg.githubTokenEnc -ErrorAction SilentlyContinue
            if (-not $sec) { return $null }
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
        $r.Tag = $r.tag_name
        $r.TagName = $r.tag_name
        return $r
    } catch {
        return $null
    }
}

function Get-ReleaseTag {
    #Тег последнего релиза (например v2.0.5). Обновление качает по этому
    #тегу, чтобы сверка SHA-256 не давала ложных расхождений при том, что
    #ветка main может опережать последний опубликованный релиз.
    $release = Get-LatestReleaseInfo
    if ($release) { return $release.Tag }
    return $script:RepoBranch
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

function Get-ScriptFileStamp {
    # Свежесть локальной копии: дата изменения самого «свежего» файла скрипта
    # и сколько дней прошло. Показывает, какая копия реально лежит на диске.
    $files = @('LDManager.ps1', 'LDManager.core.ps1', 'LD.Sieve.ps1')
    $newest = $null
    foreach ($f in $files) {
        $p = Join-Path $scriptRoot $f
        if (Test-Path $p) {
            $t = (Get-Item $p).LastWriteTime
            if (-not $newest -or $t -gt $newest) { $newest = $t }
        }
    }
    if (-not $newest) { return 'нет файлов' }
    $days = [int]((Get-Date) - $newest).TotalDays
    return ("{0:yyyy-MM-dd HH:mm} ({1} дн. назад)" -f $newest, $days)
}

function Get-ReleaseChecksumManifest {
    # Манифест SHA256SUMS последнего релиза: имя файла -> ожидаемый SHA-256.
    # Возвращает $null, если манифеста нет (старые релизы) или он не читается;
    # тогда сверка не выполняется, но само обновление продолжает работать.
    $script:LastChecksumError = $null
    $release = Get-LatestReleaseInfo
    if (-not $release) { $script:LastChecksumError = 'не удалось получить данные о последнем релизе'; return $null }

    $asset = @($release.assets) | Where-Object { $_.name -eq 'SHA256SUMS' } | Select-Object -First 1
    if (-not $asset) {
        $script:LastChecksumError = "в релизе $($release.tag_name) нет файла SHA256SUMS"
        return $null
    }

    try {
        $raw = (Invoke-WebRequest -Uri $asset.browser_download_url -Headers (Get-GithubHeaders) `
                    -TimeoutSec 30 -UseBasicParsing).Content
        # GitHub отдаёт SHA256SUMS как application/octet-stream, и Invoke-WebRequest
        # в этом случае возвращает в .Content МАССИВ БАЙТ, а не строку. Без
        # разбора байтов регулярное выражение видело «97 100 98 ...» и манифест
        # не распознавался. Проверено на реальном ассете v2.0.5.
        $text = if ($raw -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($raw) } else { [string]$raw }
    } catch {
        $code = Get-HttpErrorStatusCode $_
        $script:LastChecksumError = if ($code) { "HTTP $code при загрузке SHA256SUMS" } else { $_.Exception.Message }
        return $null
    }

    # Формат строки sha256sum: "<64 hex><пробелы><имя>".
    $map = @{}
    foreach ($line in ($text -split "`r?`n")) {
        if ($line -match '^\s*([0-9a-fA-F]{64})\s+\*?(.+?)\s*$') {
            $name = Split-Path $matches[2] -Leaf
            if ($name) { $map[$name] = $matches[1].ToLower() }
        }
    }
    if ($map.Count -eq 0) { $script:LastChecksumError = 'SHA256SUMS получен, но не распознан'; return $null }
    $script:ChecksumReleaseTag = $release.tag_name
    return $map
}

function Get-BytesHash {
    # SHA-256 массива байтов (строчные hex, как в sha256sum).
    param([byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return (([BitConverter]::ToString($sha.ComputeHash($Bytes))) -replace '-', '').ToLower()
    } finally { $sha.Dispose() }
}

function Get-PlainContent {
    # Содержимое скрипта в нормализованном виде: без BOM, без блока
    # подписи, с едиными LF. Именно так сравниваются копии между собой.
    #
    # ПОЧЕМУ НЕЛЬЗЯ СВЕРЯТЬ ХЕШ ЛОКАЛЬНОГО ФАЙЛА С МАНИФЕСТОМ:
    # в репозитории лежат ПОДПИСАННЫЕ скрипты, а блок подписи содержит
    # метку времени подписи. Переподписав файл у себя (что делает и
    # обновление, и пункт «Подпись»), вы получите другие байты при том же
    # самом коде — хеш перестанет совпадать с манифестом, хотя подмены
    # не было. Поэтому хеш сверяется у СКАЧАННОГО файла (байты из сети),
    # а локальная копия сравнивается по содержимому без подписи.
    param([string]$Text)
    if ($Text.Length -gt 0 -and $Text[0] -eq [char]0xFEFF) { $Text = $Text.Substring(1) }
    $Text = [regex]::Replace($Text, '(?s)# SIG # Begin signature block.*$', '')
    return ($Text -replace "`r`n", "`n")
}

function Get-RemoteScriptFile {
    # Скачивает файл из raw по указанной ветке/тегу во временный файл и
    # возвращает объект с путём и хешем байтов ИЗ СЕТИ.
    param(
        [string]$Name,
        [string]$Ref = $script:RepoBranch,
        [string]$TempDir
    )
    $url = "https://raw.githubusercontent.com/$script:RepoOwner/$script:RepoName/$Ref/$Name"
    $path = Join-Path $TempDir $Name
    Invoke-WebRequest -Uri $url -Headers (Get-GithubHeaders) -OutFile $path -TimeoutSec 60 -UseBasicParsing
    $bytes = [System.IO.File]::ReadAllBytes($path)
    return [pscustomobject]@{
        Name    = $Name
        Path    = $path
        Bytes   = $bytes
        Hash    = Get-BytesHash -Bytes $bytes
        Content = Get-PlainContent -Text ([System.Text.Encoding]::UTF8.GetString($bytes))
    }
}

function Test-FileIntegrity {
    # Проверка целостности: манифест последнего релиза против того, что
    # GitHub реально отдаёт, плюс сравнение с локальной копией по
    # содержимому (без подписи). Для каждого файла:
    #   ОК            — скачанное совпало с манифестом
    #   РАСХОЖДЕНИЕ   — хеш скачанного не равен заявленному в манифесте
    #   иначе         — файла нет в манифесте (старый релиз)
    # Сверка идёт по БАЙТАМ из сети, а не по локальному файлу: локальная
    # копия подписана своим таймстемпом и побайтово всегда отличается.
    [CmdletBinding()]
    param([hashtable]$Manifest)

    Write-Title 'Проверка целостности файлов (SHA-256)'
    if (-not $Manifest) {
        Write-Note 'Манифест SHA256SUMS недоступен — сверка не выполнена.'
        if ($script:LastChecksumError) { Write-Note ("Причина: " + $script:LastChecksumError) }
        Wait-Enter; return $false
    }
    if ($script:ChecksumReleaseTag) { Write-Host "  Манифест релиза    : $($script:ChecksumReleaseTag)" }
    Write-Host "  Ожидаемые хеши   : SHA256SUMS (ассет последнего релиза)"
    Write-Host ''

    $files = @('LDManager.ps1', 'LDManager.core.ps1', 'LD.Sieve.ps1')
    $bad = 0; $missed = 0; $differs = 0
    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ldm_verify_" + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        foreach ($f in $files) {
            $expected = $Manifest[$f]
            if (-not $expected) {
                Write-Host ("  {0,-20} нет в манифесте (старый релиз)" -f $f) -ForegroundColor Yellow
                $missed++; continue
            }
            try {
                $remote = Get-RemoteScriptFile -Name $f -Ref $script:ReleaseTag -TempDir $tmpDir
            } catch {
                $code = Get-HttpErrorStatusCode $_
                Write-Host ("  {0,-20} не скачан ({1})" -f $f, $(if ($code) { "HTTP $code" } else { $_.Exception.Message })) -ForegroundColor Red
                $bad++; continue
            }

            if ($remote.Hash -eq $expected) {
                Write-Host ("  {0,-20} ОК" -f $f) -ForegroundColor Green
            } else {
                Write-Host ("  {0,-20} РАСХОЖДЕНИЕ" -f $f) -ForegroundColor Red
                Write-Host ("      ожидался: {0}" -f $expected) -ForegroundColor DarkGray
                Write-Host ("      получен : {0}" -f $remote.Hash) -ForegroundColor DarkGray
                $bad++
            }

            # Локальная копия: сравниваем содержимое без подписи, потому что
            # подпись у каждой копии своя (проверено на реальном v2.0.5).
            $localPath = Join-Path $scriptRoot $f
            if (-not (Test-Path $localPath)) {
                Write-Host ("      локально: файл отсутствует" ) -ForegroundColor Red
                $bad++; continue
            }
            $localContent = Get-PlainContent -Text ([System.IO.File]::ReadAllText($localPath))
            if ($localContent -ceq $remote.Content) {
                Write-Host ("      локально: совпадает с репозиторием" ) -ForegroundColor DarkGray
            } else {
                Write-Host ("      локально: ОТЛИЧАЕТСЯ от репозитория" ) -ForegroundColor Yellow
                $differs++
            }
        }
    } finally {
        if (Test-Path $tmpDir) { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Write-Host ''
    if ($bad -eq 0) { Write-Ok "Скачанные файлы совпадают с манифестом (без манифеста: $missed)." }
    else { Write-Fail "Файлов с несовпадением манифеста: $bad из $($files.Count)." }
    if ($differs -gt 0) {
        Write-Note "Локальная копия отличается от репозитория: $differs файл(ов). Вы правки вносили вручную?"
        Write-Note 'Обновить копию: [u] Обновить LDManager.'
    }
    Wait-Enter
    return ($bad -eq 0)
}

function Update-LDManagerSelf {
    [CmdletBinding()]
    param([switch]$Force)

    # Самообновление: скачивает все файлы скрипта из репозитория и заменяет их.
    # -Force перекачивает файлы даже когда версия совпадает (лечит «битую» копию).
    Write-Title 'Автообновление из GitHub'
    Write-Host ("  Локальная копия  : " + (Get-ScriptFileStamp))

    $check = Test-UpdateAvailable
    if ($check -eq $null) {
        Write-Fail 'Не удалось получить версию из GitHub.'
        if ($script:LastUpdateCheckError) { Write-Note ("Причина: " + $script:LastUpdateCheckError) }
        Write-Note 'Подробнее: [g] GitHub -> [5] Диагностика доступа к GitHub.'
        Wait-Enter; return
    }
    if (-not $check) {
        Write-Ok "У вас актуальная версия ($script:ScriptVersion)."
        Write-Host ''
        if (-not $Force) {
            Write-Host '  [1] Перекачать файлы заново (лечение битой копии, подписи будут сняты)'
            Write-Host '  [0] Назад'
            $sub = (Read-Host 'Выбор').Trim()
            if ($sub -ne '1') { return }
        }
    } else {
        $remote = Get-RemoteScriptVersion
        Write-Host "  Доступна версия : $remote (у вас $script:ScriptVersion)"
    }

    if (-not (Confirm-Action 'Скачать и заменить файлы LDManager?')) { Write-Note 'Отменено.'; Wait-Enter; return }

    # Манифест последнего релиза — по нему проверяем скачанные байты.
    # Если манифеста нет (старый релиз), обновление всё равно выполняется,
    # просто без сверки — с явным предупреждением, а не молча.
    Write-Host ''
    Write-Host '  Проверка целостности по манифесту SHA256SUMS...'
    $manifest = Get-ReleaseChecksumManifest
    if ($manifest) {
        Write-Ok "Манифест загружен (релиз $($script:ChecksumReleaseTag))."
    } else {
        Write-Note 'Манифест SHA256SUMS недоступен — файлы будут записаны БЕЗ сверки.'
        if ($script:LastChecksumError) { Write-Note ("Причина: " + $script:LastChecksumError) }
    }

    $files   = @('LDManager.ps1', 'LDManager.core.ps1', 'LD.Sieve.ps1')
    $backupDir = Join-Path $scriptRoot ("LDManager.backup_{0}" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ldm_update_" + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        foreach ($f in $files) {
            $target = Join-Path $scriptRoot $f
            if (Test-Path $target) { Copy-Item $target (Join-Path $backupDir $f) -Force }
        }

        # Шаг 1: скачать всё во временную папку и сверить хеши с манифестом.
        # Шаг 2: записать на диск только те файлы, которые прошли сверку.
        Write-Host ''
        $staged = @{}
        $mismatch = @()
        foreach ($f in $files) {
            $remote = Get-RemoteScriptFile -Name $f -Ref $script:ReleaseTag -TempDir $tmpDir
            $expected = if ($manifest) { $manifest[$f] } else { $null }
            if (-not $expected) {
                Write-Host ("  {0,-20} {1}" -f $f, $(if ($manifest) { 'нет в манифесте - без сверки' } else { 'без сверки (нет манифеста)' }))
            } elseif ($remote.Hash -eq $expected) {
                Write-Host ("  {0,-20} хеш ОК" -f $f) -ForegroundColor Green
            } else {
                Write-Host ("  {0,-20} ХЕШ НЕ СОВПАЛ" -f $f) -ForegroundColor Red
                Write-Host ("      ожидался: {0}" -f $expected) -ForegroundColor DarkGray
                Write-Host ("      получен : {0}" -f $remote.Hash) -ForegroundColor DarkGray
                $mismatch += $f
            }
            $staged[$f] = $remote
        }

        if ($mismatch.Count -gt 0) {
            Write-Host ''
            Write-Fail "Сверка не пройдена: $($mismatch.Count) файл(ов). Запись отменена, файлы на диске не тронуты."
            Write-Note 'Манифест снят с последнего РЕЛИЗА, а обновление качает ветку main.'
            Write-Note 'Если main опережает последний релиз, расхождение законно — обновитесь с опубликованного релиза.'
            Write-Note 'Резервная копия: ' + $backupDir
            Wait-Enter; return
        }

        # Шаг 2: запись. Неизменённый по СОДЕРЖИМОМУ файл не переписываем —
        # это сохраняет его байты и подпись.
        Write-Host ''
        $changed = @()
        foreach ($f in $files) {
            $target = Join-Path $scriptRoot $f
            $content = [System.Text.Encoding]::UTF8.GetString($staged[$f].Bytes)
            if ((Test-Path $target) -and ([System.IO.File]::ReadAllText($target) -ceq $content)) {
                Write-Host ("  {0,-20} без изменений" -f $f)
                continue
            }
            [System.IO.File]::WriteAllText($target, $content, (New-Object System.Text.UTF8Encoding($true)))
            Write-Host ("  {0,-20} обновлён" -f $f) -ForegroundColor Green
            $changed += $f
        }

        # Контроль: версия в скачанном ядре должна совпасть с объявленной.
        $verified = $null
        try {
            $verified = [regex]::Match([System.IO.File]::ReadAllText((Join-Path $scriptRoot 'LDManager.core.ps1')), "\`$script:ScriptVersion\s*=\s*'([0-9\.]+)'").Groups[1].Value
        } catch { $verified = $null }
        if ($verified) {
            if ($verified -eq $script:ScriptVersion) { Write-Ok "Версия в файлах: $verified (совпадает)" }
            else { Write-Note "Внимание: в файлах версия $verified, а в памяти $($script:ScriptVersion). Требуется перезапуск." }
        }

        if ($changed.Count -eq 0) {
            Write-Ok "Файлы уже совпадают с репозиторием. Резервная копия: $backupDir"
        } else {
            Write-Ok "Обновлено (файлов: $($changed.Count)). Резервная копия: $backupDir"
        }
        Write-Host ''
        if (Confirm-Action 'Перезапустить LDManager сейчас?') {
            $entry = Join-Path $scriptRoot 'LDManager.ps1'
            if (Test-Path $entry) {
                try {
                    Start-Process (Get-Process -Id $PID).Path `
                        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$entry`"") -WorkingDirectory $scriptRoot
                    Write-Ok 'Запущен новый экземпляр. Текущий закрывается.'
                    exit 0
                } catch {
                    Write-Fail "Не удалось перезапустить автоматически: $($_.Exception.Message)"
                }
            }
            Write-Note 'Перезапустите скрипт вручную, чтобы изменения вступили в силу.'
        } else {
            Write-Note 'Перезапустите скрипт, чтобы изменения вступили в силу.'
        }
    } catch {
        Write-Fail "Ошибка обновления: $($_.Exception.Message)"
        if (Test-Path $backupDir) { Write-Note "Резервная копия: $backupDir" }
    } finally {
        # Временная папка со скачанными файлами всегда убирается, даже при ошибке.
        if ($tmpDir -and (Test-Path $tmpDir)) { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
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
# Цифровая подпись скрипта (self-signed CodeSigning)
# ===========================================================================
function Invoke-ScriptSigning {
    Write-Title 'Цифровая подпись скрипта'
    # $PSCommandPath пуст, когда ядро загружено через точку входа LDManager.ps1 —
    # путь точки входа строим от $scriptRoot (определён в обоих контекстах).
    if (-not $scriptRoot) { Write-Fail 'Не удалось определить путь скрипта.'; Wait-Enter; return }
    $entryPath = Join-Path $scriptRoot 'LDManager.ps1'

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
    $files = @($entryPath)
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
    Write-Host ("  Файлы обновлены    : " + (Get-ScriptFileStamp))
    Write-Host ("  Папка скрипта      : $scriptRoot")
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

    $entryPath = Join-Path $scriptRoot 'LDManager.ps1'
    $sig = if ($entryPath -and (Test-Path $entryPath)) { Get-AuthenticodeSignature -FilePath $entryPath -ErrorAction SilentlyContinue } else { $null }
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
        Write-Host '  [u] Обновить LDManager - проверка и загрузка свежей версии'
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
            'u' { Update-LDManagerSelf }
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
        Write-Host '  [1] Файлы логов LDPlayer (logs\, log\, vms\)'
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
        Write-Host '  [6] Проверка целостности файлов (SHA-256 по манифесту релиза)'
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
            '6' { # [void] обязателен: функция возвращает $true/$false, и без этого
                 # значение выводилось бы в меню как лишняя строка "True".
                 [void](Test-FileIntegrity -Manifest (Get-ReleaseChecksumManifest)) }
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
    Write-Fail ("Критическая ошибка [{0}]: {1}" -f $_.Exception.GetType().Name, $_.Exception.Message)
    if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
        Write-Host $_.InvocationInfo.PositionMessage -ForegroundColor DarkGray
    }
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray }
    Wait-Enter
}


# SIG # Begin signature block
# MIIFggYJKoZIhvcNAQcCoIIFczCCBW8CAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUlkxPG1rnzerpJkbmMmM1UFxY
# FE6gggMWMIIDEjCCAfqgAwIBAgIQHb8OO1X7MrdClKYHA5HxWzANBgkqhkiG9w0B
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
# KJ+xHVxvXhS9sdT8YTqqElgrAiHk3ZbM65N8uDGCAdYwggHSAgEBMDUwITEfMB0G
# A1UEAwwWTERNYW5hZ2VyIENvZGUgU2lnbmluZwIQHb8OO1X7MrdClKYHA5HxWzAJ
# BgUrDgMCGgUAoHgwGAYKKwYBBAGCNwIBDDEKMAigAoAAoQKAADAZBgkqhkiG9w0B
# CQMxDAYKKwYBBAGCNwIBBDAcBgorBgEEAYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAj
# BgkqhkiG9w0BCQQxFgQUX/cgYwnNbRGnkQEAwxTczRubCt0wDQYJKoZIhvcNAQEB
# BQAEggEAYY4I1+l125V9Dmb/uEbqOYA1SSTafyGjiCfcWhzRQfzET11iHx8FvfdW
# 1rmexqfzU2VjwsckA7V7D4lCpdt6ipqVZp035krtWy1j+As+X9yMqWoGz2emTnQL
# XO7bDfPss6EOOY3Cdp8ZkBqNGe9AyMXJdPWiS+KQPV7/Smz3ETK1yeQI6XDdqlOT
# aNyXHepcsyJw4Xdag+AHQMcr6zKXgneVWzJho/PMc3ZETCLpkRcV+q/PhC+0GfoS
# kGGwM/b53cOHWA8yQmvywKcDnCKv2/0YENsuEy0uViDKUjJoHzaqYxXHWRXyLYUa
# lpWuw65zZCH9P4vwpaunQiO5lVOSUw==
# SIG # End signature block
