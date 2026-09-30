# ===========================================================================
# Sieve scrape API (https://scrape.usesieve.com) — интеграция веб-скрейпинга.
# ---------------------------------------------------------------------------
# Этот файл загружается (dot-source) из LDManager.ps1 и только ОПРЕДЕЛЯЕТ
# функции. Сам по себе ничего не запускает.
#
# Безопасность ключа. Ключ SIEVE_API_KEY хранится так же, как GitHub-токен:
# зашифрован Windows DPAPI (CurrentUser) в LDManager.config.json. Если задана
# переменная окружения SIEVE_API_KEY, она имеет приоритет. Ключ никогда не
# печатается и не пишется в логи. Весь код ниже бездействует, пока ключ не задан,
# поэтому поведение скрипта без настроенного Sieve не меняется.
# ===========================================================================

$script:SieveBaseUrl = 'https://scrape.usesieve.com'

# ---------------------------------------------------------------------------
# Секрет: DPAPI-шифрование в LDManager.config.json + переменная окружения
# ---------------------------------------------------------------------------
function Protect-SieveSecret {
    param([Parameter(Mandatory = $true)][string]$Plain)
    $sec = ConvertTo-SecureString $Plain -AsPlainText -Force
    return (ConvertFrom-SecureString -SecureString $sec)   # DPAPI, CurrentUser
}

function Unprotect-SieveSecret {
    param([Parameter(Mandatory = $true)][string]$Enc)
    $sec = ConvertTo-SecureString -String $Enc
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Get-StoredSieveApiKey {
    if ($env:SIEVE_API_KEY) { return $env:SIEVE_API_KEY }
    $cfg = Get-AppConfig
    if ($cfg -and $cfg.sieveApiKeyEnc) {
        try { return (Unprotect-SieveSecret -Enc $cfg.sieveApiKeyEnc) } catch { return $null }
    }
    return $null
}

function Save-SieveApiKey {
    param([Parameter(Mandatory = $true)][string]$Plain)
    $enc = Protect-SieveSecret -Plain $Plain
    Save-ManagerConfig -SieveApiKeyEnc $enc
}

function Remove-SieveApiKey {
    Save-ManagerConfig -SieveApiKeyEnc ''
}

function Test-SieveConfigured {
    return [bool](Get-StoredSieveApiKey)
}

# ---------------------------------------------------------------------------
# HTTP-граница. Единственное место, где делается сетевой запрос.
# Возвращает структурный результат (не бросает исключений), чтобы вызывающий
# код мог осмысленно решать, что делать (в т.ч. НЕ повторять POST).
# ---------------------------------------------------------------------------
function Get-SieveAbsoluteUri {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ($Path -match '^https?://') { return $Path }
    $p = $Path
    if (-not $p.StartsWith('/')) { $p = '/' + $p }
    return ($script:SieveBaseUrl.TrimEnd('/') + $p)
}

function Invoke-SieveSleep {
    param([scriptblock]$Sleep, [int]$Seconds)
    if ($Sleep) { & $Sleep $Seconds } else { Start-Sleep -Seconds $Seconds }
}

function Invoke-SieveHttp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('GET','POST','PUT','DELETE','PATCH')][string]$Method,
        [Parameter(Mandatory = $true)][string]$Path,
        $Body,
        [byte[]]$RawBody,
        [string]$ContentType,
        [string]$OutFile,
        [int]$TimeoutSec = 60
    )

    $result = [pscustomobject]@{
        Ok = $false; StatusCode = 0; Content = $null; Raw = $null; RetryAfter = $null; Error = $null
    }

    $key = Get-StoredSieveApiKey
    if (-not $key) { $result.Error = 'SIEVE_API_KEY не задан.'; return $result }

    $uri = Get-SieveAbsoluteUri -Path $Path
    $headers = @{ 'Authorization' = "Bearer $key"; 'User-Agent' = "LDManager/$script:ScriptVersion" }

    $params = @{ Uri = $uri; Method = $Method; Headers = $headers; TimeoutSec = $TimeoutSec; UseBasicParsing = $true }
    if ($OutFile) { $params['OutFile'] = $OutFile }
    if ($RawBody) {
        $params['Body'] = $RawBody
        if ($ContentType) { $params['ContentType'] = $ContentType }
    } elseif ($null -ne $Body) {
        $params['Body'] = ($Body | ConvertTo-Json -Depth 12 -Compress)
        $params['ContentType'] = 'application/json'
    }

    try {
        $resp = Invoke-WebRequest @params
        $result.Ok = $true
        try { $result.StatusCode = [int]$resp.StatusCode } catch { $result.StatusCode = 200 }
        if (-not $OutFile) { $result.Raw = [string]$resp.Content }
        try {
            if ($resp.Headers -and $resp.Headers['Retry-After']) { $result.RetryAfter = [string]$resp.Headers['Retry-After'] }
        } catch { }
        if ($result.Raw) { try { $result.Content = $result.Raw | ConvertFrom-Json } catch { $result.Content = $null } }
        return $result
    } catch {
        $status = 0
        $bodyText = $null
        $retryAfter = $null
        $exception = $_.Exception
        try { if ($exception.Response) { $status = [int]$exception.Response.StatusCode } } catch { }
        if ($status -eq 0) { try { if ($exception.Response) { $status = [int]$exception.Response.StatusCode.value__ } } catch { } }
        # Windows PowerShell 5.1: тело в потоке ответа; PowerShell 7: ErrorDetails
        try { if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $bodyText = [string]$_.ErrorDetails.Message } } catch { }
        if (-not $bodyText) {
            try {
                if ($exception.Response) {
                    $stream = $exception.Response.GetResponseStream()
                    if ($stream) {
                        $reader = New-Object System.IO.StreamReader($stream)
                        $bodyText = $reader.ReadToEnd()
                        $reader.Dispose()
                    }
                }
            } catch { }
        }
        try {
            if ($exception.Response -and $exception.Response.Headers -and $exception.Response.Headers['Retry-After']) {
                $retryAfter = [string]$exception.Response.Headers['Retry-After']
            }
        } catch { }
        $result.StatusCode = $status
        $result.Raw = $bodyText
        $result.RetryAfter = $retryAfter
        if ($bodyText) { try { $result.Content = $bodyText | ConvertFrom-Json } catch { $result.Content = $null } }
        if ($status -gt 0) { $result.Error = "HTTP $status" } else { $result.Error = $exception.Message }
        return $result
    }
}

# ---------------------------------------------------------------------------
# Сборка multipart/form-data для загрузки документа (поле "file").
# ---------------------------------------------------------------------------
function New-SieveMultipartBody {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [hashtable]$Fields
    )
    $boundary = [guid]::NewGuid().ToString('N')
    $enc = [System.Text.Encoding]::UTF8
    $ms = New-Object System.IO.MemoryStream
    try {
        if ($Fields) {
            foreach ($k in $Fields.Keys) {
                $part = "--$boundary`r`nContent-Disposition: form-data; name=`"$k`"`r`n`r`n$($Fields[$k])`r`n"
                $b = $enc.GetBytes($part)
                $ms.Write($b, 0, $b.Length)
            }
        }
        $fileName = [System.IO.Path]::GetFileName($FilePath)
        $header = "--$boundary`r`nContent-Disposition: form-data; name=`"file`"; filename=`"$fileName`"`r`nContent-Type: application/octet-stream`r`n`r`n"
        $hb = $enc.GetBytes($header)
        $ms.Write($hb, 0, $hb.Length)
        $fileBytes = [System.IO.File]::ReadAllBytes($FilePath)
        $ms.Write($fileBytes, 0, $fileBytes.Length)
        $footer = "`r`n--$boundary--`r`n"
        $fb = $enc.GetBytes($footer)
        $ms.Write($fb, 0, $fb.Length)
        $bytes = $ms.ToArray()
        return [pscustomobject]@{ ContentType = "multipart/form-data; boundary=$boundary"; Bytes = $bytes }
    } finally {
        $ms.Dispose()
    }
}

# ---------------------------------------------------------------------------
# Ошибки и статусы
# ---------------------------------------------------------------------------
function Get-SieveErrorMessage {
    param([int]$StatusCode, $Body)

    $obj = $Body
    if ($obj -is [string]) { try { $obj = $obj | ConvertFrom-Json } catch { $obj = $null } }

    $code = $null; $msg = $null
    if ($obj) {
        if ($obj.PSObject.Properties['message'] -and $obj.message) { $msg = [string]$obj.message }
        elseif ($obj.PSObject.Properties['detail'] -and $obj.detail) { $msg = [string]$obj.detail }
        if ($obj.PSObject.Properties['error'] -and $obj.error) { $code = [string]$obj.error }
        if ($obj.PSObject.Properties['refusal'] -and $obj.refusal) {
            if ($obj.refusal.PSObject.Properties['code'] -and $obj.refusal.code) { $code = [string]$obj.refusal.code }
            if ($obj.refusal.PSObject.Properties['message'] -and $obj.refusal.message) { $msg = [string]$obj.refusal.message }
        }
    }

    switch ($StatusCode) {
        400 { if ($msg) { return ("Некорректный запрос (400): $msg") } return 'Некорректный запрос (400). Исправьте параметры.' }
        401 { return 'SIEVE_API_KEY отсутствует или отозван (401). Задайте ключ заново.' }
        402 { return 'Закончились кредиты (402). Баланс: GET /api/me/credits.' }
        404 { return 'Запуск не найден или принадлежит другому аккаунту (404).' }
        429 { return 'Слишком много запросов (429). Повторите позже (Retry-After).' }
    }
    if ($StatusCode -ge 500) { return "Сервис Sieve временно недоступен ($StatusCode)." }

    if ($code) {
        if ($code -eq 'quota' -or $code -eq 'credit_limit' -or $code -eq 'insufficient_credits') {
            return "Запуск отклонён: недостаточно кредитов ($code). Баланс: GET /api/me/credits."
        }
        if ($msg) { return "Запуск отклонён: $code - $msg" }
        return "Запуск отклонён: $code"
    }
    if ($msg) { return [string]$msg }
    return "Неизвестная ошибка Sieve (HTTP $StatusCode)."
}

function Get-SieveSessionKind {
    param($Session)
    if (-not $Session) { return 'unknown' }
    $status = $null
    if ($Session.PSObject.Properties['status'] -and $Session.status) { $status = ([string]$Session.status).ToLowerInvariant() }
    switch ($status) {
        'running' { return 'running' }
        'done'    { return 'done' }
        'refused' { return 'refused' }
        default   { return 'unknown' }
    }
}

# ---------------------------------------------------------------------------
# Запуск и опрос
# ---------------------------------------------------------------------------
function Start-SieveScrapeRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Instruction,
        [string[]]$TargetUrls,
        [string[]]$Fields,
        $Schema,
        $OutputSchema,
        [ValidateSet('long','wide')][string]$TableShape,
        [ValidateSet('conservative','regular','yolo')][string]$ComplianceMode = 'regular',
        [string]$FilePath,
        [int]$MaxAttempts = 3,
        [scriptblock]$Sleep = $null
    )

    $body = [ordered]@{ instruction = $Instruction; compliance_mode = $ComplianceMode }
    if ($TargetUrls)   { $body['target_urls'] = @($TargetUrls) }
    if ($Fields)       { $body['fields'] = @($Fields) }
    if ($Schema)       { $body['schema'] = $Schema }
    if ($OutputSchema) { $body['output_schema'] = $OutputSchema }
    if ($TableShape)   { $body['table_shape'] = $TableShape }

    $rawBody = $null; $contentType = $null
    if ($FilePath) {
        if (-not (Test-Path $FilePath)) { return $null }
        $mp = New-SieveMultipartBody -FilePath $FilePath -Fields $body
        $rawBody = $mp.Bytes
        $contentType = $mp.ContentType
    }

    $attempt = 0
    while ($attempt -lt $MaxAttempts) {
        $attempt++
        if ($rawBody) {
            $r = Invoke-SieveHttp -Method POST -Path '/api/scrapes' -RawBody $rawBody -ContentType $contentType
        } else {
            $r = Invoke-SieveHttp -Method POST -Path '/api/scrapes' -Body $body
        }

        if ($r.Ok) {
            $session = $r.Content
            $sid = $null
            if ($session -and $session.PSObject.Properties['session_id'] -and $session.session_id) { $sid = [string]$session.session_id }
            if ($sid) {
                # Ключевой инвариант: session_id сохраняется НАДЁЖНО до всего
                # остального, чтобы после сбоя продолжить опрос, а не создать дубль.
                Save-SieveRunRecord -SessionId $sid -Instruction $Instruction -Status 'queued' `
                    -PollPath ([string]$session.poll) -Turns 0 -CreatedAt (Get-Date).ToString('o')
                return $session
            }
            return $null
        }

        # Сетевая ошибка/таймаут: POST мог создаться запуск. НИКОГДА не повторяем.
        if ($r.StatusCode -eq 0) { return $null }

        # 429 / 5xx: запуск не создан, повтор безопасен.
        if ($r.StatusCode -eq 429 -or $r.StatusCode -ge 500) {
            if ($attempt -ge $MaxAttempts) { return $null }
            $wait = 5 * $attempt
            if ($r.RetryAfter) { try { $wait = [int]$r.RetryAfter } catch { } }
            Invoke-SieveSleep -Sleep $Sleep -Seconds $wait
            continue
        }

        # 400/401/402/404: исправляем запрос, не повторяем.
        return $null
    }
    return $null
}

function Get-SieveSession {
    param([Parameter(Mandatory = $true)][string]$SessionId)
    return (Invoke-SieveHttp -Method GET -Path ("/api/scrapes/" + $SessionId))
}

function Wait-SieveSessionComplete {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SessionId,
        [int]$MinTurns = 0,
        [int]$StartDelay = 5,
        [int]$MaxDelay = 30,
        [int]$TimeoutSec = 3600,
        [int]$MaxPolls = 1000,
        [int]$MaxConsecutiveErrors = 5,
        [scriptblock]$Sleep = $null
    )

    $delay = $StartDelay
    $elapsed = 0
    $polls = 0
    $consecutiveErrors = 0

    while ($true) {
        Invoke-SieveSleep -Sleep $Sleep -Seconds $delay
        $elapsed += $delay
        $polls++

        if ($elapsed -gt $TimeoutSec -or $polls -gt $MaxPolls) {
            return [pscustomobject]@{ Kind = 'error'; Session = $null; Error = 'Превышено время ожидания выполнения запуска.' }
        }

        $r = Invoke-SieveHttp -Method GET -Path ("/api/scrapes/" + $SessionId)

        if (-not $r.Ok) {
            if ($r.StatusCode -eq 429) {
                if ($r.RetryAfter) { try { $delay = [int]$r.RetryAfter } catch { } }
                if ($delay -lt $StartDelay) { $delay = $StartDelay }
                continue
            }
            if ($r.StatusCode -eq 0 -or $r.StatusCode -ge 500) {
                $consecutiveErrors++
                if ($consecutiveErrors -gt $MaxConsecutiveErrors) {
                    return [pscustomobject]@{ Kind = 'error'; Session = $null; Error = $r.Error }
                }
                $delay = [Math]::Min($MaxDelay * 2, [Math]::Max($delay, $StartDelay) * 2)
                continue
            }
            return [pscustomobject]@{ Kind = 'error'; Session = $null; Error = (Get-SieveErrorMessage -StatusCode $r.StatusCode -Body $r.Content) }
        }

        $consecutiveErrors = 0
        $session = $r.Content
        $kind = Get-SieveSessionKind -Session $session

        if ($kind -eq 'done') {
            $turns = 0
            if ($session.PSObject.Properties['turns']) { $turns = [int]$session.turns }
            if ($turns -ge $MinTurns) {
                return [pscustomobject]@{ Kind = 'done'; Session = $session; Error = $null }
            }
            # done, но новый ход ещё не учтён: продолжаем опрос.
        } elseif ($kind -eq 'refused') {
            return [pscustomobject]@{ Kind = 'refused'; Session = $session; Error = (Get-SieveErrorMessage -StatusCode 200 -Body $session) }
        } elseif ($kind -eq 'unknown') {
            return [pscustomobject]@{ Kind = 'error'; Session = $session; Error = 'Неизвестный статус запуска Sieve.' }
        }

        if ($delay -lt $MaxDelay) { $delay = [Math]::Min($MaxDelay, $delay + 5) }
    }
}

function Send-SieveFollowUp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][string]$Instruction,
        [string[]]$TargetUrls,
        [string[]]$Fields,
        [scriptblock]$Sleep = $null
    )

    # Сначала фиксируем число ходов ДО отправки: ждать нужно, пока turns его превысит,
    # иначе прочитаем предыдущий ответ.
    $turnsBefore = 0
    $pre = Invoke-SieveHttp -Method GET -Path ("/api/scrapes/" + $SessionId)
    if ($pre.Ok -and $pre.Content -and $pre.Content.PSObject.Properties['turns']) {
        $turnsBefore = [int]$pre.Content.turns
    }
    $targetTurn = $turnsBefore + 1

    $body = [ordered]@{ instruction = $Instruction; compliance_mode = 'regular' }
    if ($TargetUrls) { $body['target_urls'] = @($TargetUrls) }
    if ($Fields)     { $body['fields'] = @($Fields) }

    $posted = $false
    $attempts = 0
    while (-not $posted -and $attempts -lt 20) {
        $attempts++
        $r = Invoke-SieveHttp -Method POST -Path ("/api/scrapes/$SessionId/messages") -Body $body
        if ($r.Ok) { $posted = $true; break }
        if ($r.StatusCode -eq 409) {
            # ход уже выполняется: ждём и повторяем тот же запрос
            Invoke-SieveSleep -Sleep $Sleep -Seconds 10
            continue
        }
        return [pscustomobject]@{ Kind = 'error'; Session = $null; Error = (Get-SieveErrorMessage -StatusCode $r.StatusCode -Body $r.Content) }
    }
    if (-not $posted) { return [pscustomobject]@{ Kind = 'error'; Session = $null; Error = 'Не удалось отправить запрос (занято).' } }

    $final = Wait-SieveSessionComplete -SessionId $SessionId -MinTurns $targetTurn -Sleep $Sleep
    if ($final.Kind -eq 'done') {
        $turns = 0
        if ($final.Session.PSObject.Properties['turns']) { $turns = [int]$final.Session.turns }
        Update-SieveRunRecord -SessionId $SessionId -Status 'done' -Turns $turns
    }
    return $final
}

function Get-SieveCredits {
    return (Invoke-SieveHttp -Method GET -Path '/api/me/credits')
}

function Receive-SieveRunFiles {
    [CmdletBinding()]
    param(
        $Session,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    $saved = @()
    if (-not $Session -or -not $Session.PSObject.Properties['files'] -or -not $Session.files) { return $saved }
    if (-not (Test-Path $Destination)) { New-Item -ItemType Directory -Path $Destination -Force | Out-Null }
    foreach ($f in @($Session.files)) {
        if (-not $f) { continue }
        $rel = $null
        if ($f.PSObject.Properties['url'] -and $f.url) { $rel = [string]$f.url }
        if (-not $rel) { continue }
        $label = Split-Path $rel -Leaf
        if ($f.PSObject.Properties['name'] -and $f.name) { $label = [string]$f.name }
        $target = Join-Path $Destination $label
        $r = Invoke-SieveHttp -Method GET -Path $rel -OutFile $target
        if ($r.Ok) { $saved += $target }
    }
    return $saved
}

# ---------------------------------------------------------------------------
# Учёт запусков (durable): сохраняются в LDManager.config.json рядом с ключом.
# ---------------------------------------------------------------------------
function Get-SieveRuns {
    $cfg = Get-AppConfig
    if ($cfg -and $cfg.sieveRuns) { return @($cfg.sieveRuns) }
    return @()
}

function Save-SieveRunRecord {
    param(
        [Parameter(Mandatory = $true)][string]$SessionId,
        [string]$Instruction,
        [string]$Status = 'queued',
        [string]$PollPath,
        [int]$Turns = 0,
        [string]$CreatedAt
    )
    if (-not $CreatedAt) { $CreatedAt = (Get-Date).ToString('o') }
    $runs = @(Get-SieveRuns | Where-Object { $_.sessionId -ne $SessionId })
    $runs += [pscustomobject]@{
        sessionId = $SessionId
        instruction = $Instruction
        status = $Status
        poll = $PollPath
        turns = $Turns
        createdAt = $CreatedAt
    }
    Save-ManagerConfig -SieveRuns $runs
}

function Update-SieveRunRecord {
    param(
        [Parameter(Mandatory = $true)][string]$SessionId,
        [string]$Status,
        [int]$Turns
    )
    $runs = @(Get-SieveRuns)
    foreach ($r in $runs) {
        if ($r.sessionId -eq $SessionId) {
            if ($PSBoundParameters.ContainsKey('Status')) { $r.status = $Status }
            if ($PSBoundParameters.ContainsKey('Turns'))  { $r.turns = $Turns }
        }
    }
    Save-ManagerConfig -SieveRuns $runs
}

function Remove-SieveRunRecord {
    param([Parameter(Mandatory = $true)][string]$SessionId)
    $runs = @(Get-SieveRuns | Where-Object { $_.sessionId -ne $SessionId })
    Save-ManagerConfig -SieveRuns $runs
}

# ---------------------------------------------------------------------------
# Вход по коду устройства (device login)
# ---------------------------------------------------------------------------
function New-SieveDeviceCode {
    param([string]$ClientName = 'LDManager')
    $r = Invoke-SieveHttp -Method POST -Path '/api/auth/device/code' -Body @{ client_name = $ClientName }
    if ($r.Ok) { return $r.Content }
    return $null
}

function Wait-SieveDeviceToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$DeviceCode,
        [int]$Interval = 5,
        [int]$ExpiresIn = 600,
        [int]$MaxPolls = 200,
        [scriptblock]$Sleep = $null
    )
    $elapsed = 0
    $polls = 0
    while ($elapsed -lt $ExpiresIn -and $polls -lt $MaxPolls) {
        Invoke-SieveSleep -Sleep $Sleep -Seconds $Interval
        $elapsed += $Interval
        $polls++
        $r = Invoke-SieveHttp -Method POST -Path '/api/auth/device/token' -Body @{ device_code = $DeviceCode }
        if ($r.Ok -and $r.Content -and $r.Content.api_key) {
            return [pscustomobject]@{ Ok = $true; ApiKey = [string]$r.Content.api_key; Error = $null }
        }
        $err = $null
        if ($r.Content -and $r.Content.PSObject.Properties['error'] -and $r.Content.error) { $err = [string]$r.Content.error }
        switch ($err) {
            'authorization_pending' { continue }
            'slow_down'             { $Interval += 5; continue }
            'access_denied'         { return [pscustomobject]@{ Ok = $false; ApiKey = $null; Error = 'Доступ отклонён пользователем.' } }
            'expired_token'         { return [pscustomobject]@{ Ok = $false; ApiKey = $null; Error = 'Код истёк. Начните заново.' } }
        }
        if ($r.StatusCode -eq 0) { return [pscustomobject]@{ Ok = $false; ApiKey = $null; Error = $r.Error } }
        if (-not $err) { return [pscustomobject]@{ Ok = $false; ApiKey = $null; Error = (Get-SieveErrorMessage -StatusCode $r.StatusCode -Body $r.Content) } }
    }
    return [pscustomobject]@{ Ok = $false; ApiKey = $null; Error = 'Истекло время ожидания подтверждения.' }
}

# ---------------------------------------------------------------------------
# Меню Sieve
# ---------------------------------------------------------------------------
function Invoke-SieveDeviceLogin {
    Write-Title 'Sieve: подключение ключа (вход по коду устройства)'
    $dc = New-SieveDeviceCode -ClientName 'LDManager'
    if (-not $dc) { Write-Fail 'Не удалось получить код устройства (проверьте сеть).'; Wait-Enter; return $false }

    $link = [string]$dc.verification_uri_complete
    $code = [string]$dc.user_code
    Write-Host ''
    Write-Host '  1. Откройте в браузере ссылку:' -ForegroundColor White
    Write-Host ("     " + $link) -ForegroundColor Cyan
    Write-Host ("  2. Убедитесь, что код на странице совпадает: " + $code) -ForegroundColor Yellow
    Write-Host ''
    Write-Note 'Одобряйте только тот код, который вы запросили сами.'
    Write-Note 'Имя инструмента указано им самим (self-reported): LDManager.'
    Write-Host '  3. Войдите (Google или e-mail) и нажмите Approve в браузере.' -ForegroundColor White
    Write-Host ''
    Write-Host '  Ожидание подтверждения...' -ForegroundColor DarkGray

    $interval = 5
    if ($dc.PSObject.Properties['interval'] -and $dc.interval) { $interval = [int]$dc.interval }
    $expires = 600
    if ($dc.PSObject.Properties['expires_in'] -and $dc.expires_in) { $expires = [int]$dc.expires_in }

    $res = Wait-SieveDeviceToken -DeviceCode ([string]$dc.device_code) -Interval $interval -ExpiresIn $expires
    if ($res.Ok) {
        Save-SieveApiKey -Plain $res.ApiKey
        Write-Ok 'Ключ сохранён в защищённом хранилище (DPAPI).'
        return $true
    }
    Write-Fail ("Не удалось получить ключ: " + $res.Error)
    return $false
}

function Show-SieveCredits {
    $c = Get-SieveCredits
    if (-not $c.Ok) { Write-Fail (Get-SieveErrorMessage -StatusCode $c.StatusCode -Body $c.Content); Wait-Enter; return }
    $o = $c.Content
    $parts = @()
    foreach ($name in @('plan','limit','used','remaining')) {
        if ($o -and $o.PSObject.Properties[$name] -and $null -ne $o.$name) { $parts += "$name=$($o.$name)" }
    }
    if ($parts.Count -gt 0) { Write-Ok ('Кредиты: ' + ($parts -join ', ')) }
    else { Write-Ok 'Ключ действителен (ответ /api/me/credits получен).' }
    Wait-Enter
}

function Show-SieveKeyMenu {
    while ($true) {
        Show-Banner
        Write-Title 'Sieve: ключ доступа'
        Write-Host ('  Ключ: ' + $(if (Test-SieveConfigured) { 'задан' } else { 'не задан (или задан через переменную окружения)' }))
        Write-Host ''
        Write-Host '  [1] Подключить ключ (вход по коду устройства)'
        Write-Host '  [2] Проверить ключ и кредиты (GET /api/me/credits)'
        Write-Host '  [3] Удалить сохранённый ключ'
        Write-Host '  [4] Вставить ключ вручную (Создайте его на сайте: Settings → API keys)'
        Write-Host ''
        Write-Host '  [0] Назад'
        $c = (Read-Host 'Выбор').Trim()
        switch ($c) {
            '1' { [void](Invoke-SieveDeviceLogin); Wait-Enter }
            '2' { Show-SieveCredits }
            '3' {
                if (Confirm-Action 'Удалить сохранённый SIEVE_API_KEY?') {
                    Remove-SieveApiKey
                    Write-Ok 'Ключ удалён из конфига.'
                } else { Write-Note 'Отменено.' }
                Wait-Enter
            }
            '4' {
                Write-Host '  Ключ можно создать в браузере: https://scrape.usesieve.com → Settings → API keys.'
                $k = Read-Host 'Вставьте ключ dc_sk_... (ввод скрыт, Enter - отмена)'
                if (-not $k) { Write-Note 'Отменено.' }
                elseif ($k -notmatch '^dc_sk_[A-Za-z0-9_-]+$') { Write-Fail 'Формат не распознан (ожидается dc_sk_...). Ничего не сохранено.' }
                else { Save-SieveApiKey -Plain $k; Write-Ok 'Ключ сохранён (зашифрован DPAPI для текущего пользователя Windows).' }
                Wait-Enter
            }
            '0' { return }
            'q' { return }
            default { Write-Fail 'Неизвестный пункт меню.'; Start-Sleep -Milliseconds 500 }
        }
    }
}

function Show-SieveSessionSummary {
    param($Result)
    if (-not $Result) { Write-Fail 'Нет результата.'; return }
    switch ($Result.Kind) {
        'done' {
            Write-Ok 'Запуск завершён.'
            $s = $Result.Session
            if ($s.PSObject.Properties['summary'] -and $s.summary) { Write-Host ("  summary: " + $s.summary) }
            if ($s.PSObject.Properties['turns'] -and $null -ne $s.turns) { Write-Host ("  turns: " + $s.turns) }
            if ($s.PSObject.Properties['schema_conformance'] -and $s.schema_conformance) {
                $sc = $s.schema_conformance
                $status = 'unknown'
                if ($sc.PSObject.Properties['status'] -and $sc.status) { $status = [string]$sc.status }
                switch ($status) {
                    'pass'     { Write-Ok 'schema_conformance: pass' }
                    'partial'  { Write-Note 'schema_conformance: partial — нарушений нет, но объявленные колонки отсутствуют.' }
                    'fail'     { Write-Fail 'schema_conformance: fail — данные НЕ соответствуют схеме; не используйте как чистые.' }
                    'not_checkable' { Write-Note 'schema_conformance: not_checkable — нечего проверять.' }
                    'no_artifact'   { Write-Note 'schema_conformance: no_artifact — артефакт отсутствует.' }
                    default    { Write-Note ("schema_conformance: " + $status) }
                }
            }
            if ($s.PSObject.Properties['files'] -and $s.files) {
                foreach ($f in @($s.files)) {
                    if (-not $f) { continue }
                    $name = '?'; $size = ''
                    if ($f.PSObject.Properties['name'] -and $f.name) { $name = [string]$f.name }
                    if ($f.PSObject.Properties['size'] -and $null -ne $f.size) { $size = [string]$f.size }
                    Write-Host ("  файл: " + $name + " (" + $size + ")")
                }
            }
            if ($s.PSObject.Properties['result'] -and $null -ne $s.result) {
                Write-Host '  result (inline):' -ForegroundColor DarkGray
                try { Write-Host ($s.result | ConvertTo-Json -Depth 8) } catch { Write-Host ([string]$s.result) }
            }
        }
        'refused' { Write-Fail ('Запуск отклонён, запуск не состоялся: ' + $Result.Error) }
        default   { Write-Fail ('Ошибка Sieve: ' + $Result.Error) }
    }
}

function Download-SieveOutput {
    param($Session, [string]$SessionId)
    $dest = (Read-Host "Куда сохранить файлы (Enter - подпапка sieve-$SessionId)").Trim('"').Trim()
    if (-not $dest) { $dest = Join-Path $scriptRoot ("sieve-$SessionId") }
    $saved = Receive-SieveRunFiles -Session $Session -Destination $dest
    if ($saved.Count -gt 0) { Write-Ok ("Сохранено файлов: " + $saved.Count + " в " + $dest) }
    else { Write-Note 'Файлов для скачивания нет.' }
}

function Invoke-SieveNewRunInteractive {
    if (-not (Test-SieveConfigured)) {
        Write-Note 'Sieve не настроен: нет SIEVE_API_KEY.'
        if (Confirm-Action 'Подключить ключ сейчас (вход по коду устройства)?') {
            if (-not (Invoke-SieveDeviceLogin)) { Wait-Enter; return }
        } else { return }
    }

    Write-Title 'Sieve: новый сбор'
    $instruction = (Read-Host 'Что извлечь (обычный текст, обязательно)').Trim()
    if (-not $instruction) { Write-Note 'Отменено.'; Wait-Enter; return }

    $urlsRaw = (Read-Host 'URL страниц через запятую (Enter - без URL; будет предложен документ)').Trim()
    $targetUrls = $null
    $filePath = $null
    if ($urlsRaw) {
        $targetUrls = @($urlsRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    } else {
        $f = (Read-Host 'Путь к локальному документу (Enter - пропустить)').Trim('"').Trim()
        if ($f) { $filePath = $f }
    }

    $fieldsRaw = (Read-Host 'Ожидаемые колонки через запятую (Enter - пропустить)').Trim()
    $fields = $null
    if ($fieldsRaw) { $fields = @($fieldsRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }

    $mode = 'regular'
    Write-Host '  Режим доступа: [1] regular (по умолчанию)  [2] conservative  [3] yolo'
    $mc = (Read-Host 'Выбор').Trim()
    if ($mc -eq '2') { $mode = 'conservative' } elseif ($mc -eq '3') { $mode = 'yolo' }
    if ($mode -eq 'yolo') { Write-Note 'yolo ослабляет политику доступа к сайтам. Используйте осознанно.' }

    Write-Host '  Отправка запуска...' -ForegroundColor DarkGray
    $session = Start-SieveScrapeRun -Instruction $instruction -TargetUrls $targetUrls -Fields $fields -ComplianceMode $mode -FilePath $filePath
    if (-not $session) {
        Write-Fail 'Не удалось создать запуск. POST не повторялся автоматически, чтобы не потратить кредиты дважды.'
        Wait-Enter
        return
    }
    $sid = [string]$session.session_id
    Write-Ok ("Запуск создан. session_id: " + $sid)
    Write-Note 'session_id сохранён в конфиг — опрос можно продолжить позже (пункт «Мои запуски»).'
    if (Confirm-Action 'Опросить результат сейчас?') {
        Write-Host '  Опрос... (запуски идут минутами)' -ForegroundColor DarkGray
        $final = Wait-SieveSessionComplete -SessionId $sid
        Show-SieveSessionSummary -Result $final
        if ($final.Kind -eq 'done') {
            $turns = 0
            if ($final.Session.PSObject.Properties['turns']) { $turns = [int]$final.Session.turns }
            Update-SieveRunRecord -SessionId $sid -Status 'done' -Turns $turns
            if (Confirm-Action 'Скачать файлы результата?') { Download-SieveOutput -Session $final.Session -SessionId $sid }
        }
    }
    Wait-Enter
}

function Show-SieveRuns {
    if (-not (Test-SieveConfigured)) { Write-Note 'Sieve не настроен.'; Wait-Enter; return }
    while ($true) {
        Show-Banner
        Write-Title 'Sieve: мои запуски'
        $runs = @(Get-SieveRuns)
        if ($runs.Count -eq 0) { Write-Note 'Сохранённых запусков нет.'; Wait-Enter; return }
        for ($i = 0; $i -lt $runs.Count; $i++) {
            $r = $runs[$i]
            Write-Host ("  [{0}] {1}  turns={2}  {3}" -f ($i + 1), $r.status, $r.turns, $r.sessionId)
            if ($r.instruction) { Write-Host ("       " + $r.instruction) -ForegroundColor DarkGray }
        }
        Write-Host ''
        Write-Host '  [номер] Обновить статус (опрос до завершения)'
        Write-Host '  [d]     Скачать файлы готового запуска'
        Write-Host '  [f]     Дозапрос (follow-up) к выбранному запуску'
        Write-Host '  [r]     Удалить запись о запуске из списка'
        Write-Host ''
        Write-Host '  [0] Назад'
        $c = (Read-Host 'Выбор').Trim()
        if ($c -eq '0' -or $c -eq 'q') { return }

        if ($c -eq 'd' -or $c -eq 'f') {
            $n = (Read-Host 'Номер запуска').Trim()
            $idx = 0
            if (-not ([int]::TryParse($n, [ref]$idx)) -or $idx -lt 1 -or $idx -gt $runs.Count) { Write-Fail 'Неверный номер.'; Wait-Enter; continue }
            $rec = $runs[$idx - 1]
            if ($c -eq 'd') {
                $s = Get-SieveSession -SessionId $rec.sessionId
                if ($s.Ok) { Download-SieveOutput -Session $s.Content -SessionId $rec.sessionId }
                else { Write-Fail (Get-SieveErrorMessage -StatusCode $s.StatusCode -Body $s.Content) }
            } else {
                $instr = (Read-Host 'Что дополнительно извлечь').Trim()
                if ($instr) {
                    Write-Host '  Отправка дозапроса...' -ForegroundColor DarkGray
                    $final = Send-SieveFollowUp -SessionId $rec.sessionId -Instruction $instr
                    Show-SieveSessionSummary -Result $final
                }
            }
            Wait-Enter
            continue
        }

        if ($c -eq 'r') {
            $n = (Read-Host 'Номер запуска для удаления записи').Trim()
            $idx = 0
            if ([int]::TryParse($n, [ref]$idx) -and $idx -ge 1 -and $idx -le $runs.Count) {
                Remove-SieveRunRecord -SessionId $runs[$idx - 1].sessionId
                Write-Ok 'Запись удалена (сам запуск на сервере не удаляется).'
            } else { Write-Fail 'Неверный номер.' }
            Wait-Enter
            continue
        }

        $idx = 0
        if ([int]::TryParse($c, [ref]$idx) -and $idx -ge 1 -and $idx -le $runs.Count) {
            $rec = $runs[$idx - 1]
            Write-Host '  Опрос... (запуски идут минутами)' -ForegroundColor DarkGray
            $final = Wait-SieveSessionComplete -SessionId $rec.sessionId
            Show-SieveSessionSummary -Result $final
            if ($final.Kind -eq 'done') {
                $turns = 0
                if ($final.Session.PSObject.Properties['turns']) { $turns = [int]$final.Session.turns }
                Update-SieveRunRecord -SessionId $rec.sessionId -Status 'done' -Turns $turns
                if (Confirm-Action 'Скачать файлы результата?') { Download-SieveOutput -Session $final.Session -SessionId $rec.sessionId }
            }
            Wait-Enter
        } else {
            Write-Fail 'Неизвестный пункт меню.'
            Start-Sleep -Milliseconds 500
        }
    }
}

function Show-SieveMenu {
    while ($true) {
        Show-Banner
        Write-Title 'Sieve — веб-скрейпинг'
        Write-Host (  '  Статус    : ' + $(if (Test-SieveConfigured) { 'ключ задан' } else { 'ключ не задан' }))
        Write-Host (  '  Ключ      : SIEVE_API_KEY (DPAPI в LDManager.config.json)')
        Write-Host ''
        Write-Host '  [1] Новый сбор (инструкция + URL или документ)'
        Write-Host '  [2] Мои запуски (статус, файлы, дозапросы)'
        Write-Host '  [3] Ключ / кредиты'
        Write-Host ''
        Write-Host '  [0] Назад'
        $c = (Read-Host 'Выбор').Trim()
        switch ($c) {
            '1' { Invoke-SieveNewRunInteractive }
            '2' { Show-SieveRuns }
            '3' { Show-SieveKeyMenu }
            '0' { return }
            'q' { return }
            default { Write-Fail 'Неизвестный пункт меню.'; Start-Sleep -Milliseconds 500 }
        }
    }
}
