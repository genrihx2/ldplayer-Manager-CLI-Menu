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

# SIG # Begin signature block
# MIIb5gYJKoZIhvcNAQcCoIIb1zCCG9MCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUJ778uKTeX+4P67E8EB283oWs
# IymgghZQMIIDEjCCAfqgAwIBAgIQHb8OO1X7MrdClKYHA5HxWzANBgkqhkiG9w0B
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
# AQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMCMGCSqGSIb3DQEJBDEWBBQk/z4tITIO
# HQF9FmAsK9vwJ1ABMDANBgkqhkiG9w0BAQEFAASCAQA2SVKHAHx0lSiHSSn4zdPv
# M3jDQhxDpFsecSsvDs60nqcuZucgjphksaq1jRWcBytCYQZRq8MJBSF4zTf+cWX+
# 3XL6lLHAdoGivEuIni5+Obk1IWfcbH6JnfmELJjs72XFbL1c+6sffwg9Bi7LEt2S
# BTxA75n89VZ6EhmaBBAl9Fxb+GfyTDzbuqvOwJdprO6OGaBcK0ipp9alaJL4/VFP
# ZlAaRzd7FgaAw/dM7Pfnng/JQMeXTQJlYbSR4K6s4zzL3pCBV1DIT9m8SqNqBKbh
# 44hAquCbPSCCeKyJfdMK+5g2p9G2iM0myf4uc3KotxPzHqC2UaFBPHM4d1/ale5+
# oYIDJjCCAyIGCSqGSIb3DQEJBjGCAxMwggMPAgEBMH0waTELMAkGA1UEBhMCVVMx
# FzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVz
# dGVkIEc0IFRpbWVTdGFtcGluZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMQIQCE/c
# M09+RU7bww+P+ZIYNTANBglghkgBZQMEAgEFAKBpMBgGCSqGSIb3DQEJAzELBgkq
# hkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8XDTI2MDkzMDExNTkzN1owLwYJKoZIhvcN
# AQkEMSIEIH94vpfEzeIOeg9x2/vy32EoZ26NsOJhpHG/P6xacdLuMA0GCSqGSIb3
# DQEBAQUABIICALRg8tFRDxERCuP1/UltUrqQhkjK47TFrRpO0+Px3dJ9HsaFoHnH
# t3Csk1V2k7VgtSmemHE0dri0Tiil6jtmNPdkt2ERxOIeqKPc84bOYjKcciY3m3CQ
# 2nXKsmGXR1jKM0DIuUGEln7V9eX1TpxfejkeqIkHZaEY0TkRqjRBEJTivhx3ggIm
# hRy1rcFBaCVYM7piV9CzltEyeu8+Gri89SNlIvzuh2YA3NA5Yt+r/txtdhtYyCwg
# 9Vd0iQr0sURsLon6X4PLPVklVo/o22YVAWWJ9RN+k0QfRKNI8gy8J4gwXS2hlUIP
# 0KkvltUapmPks2fgAV0l0RRfTqKoQwzykuROOCFDAaFf7I8gB1U1OJDt1VbmR/2u
# t4aq1IkpyNjDDtAcQLG2iZkwUCYbahokmMTL+l1NeefGgesZGrozsgeqbS1Nuw4y
# k2a93S1E40wN8H4azsmIm4dh/6aOSHeZoR/O0FEVh/UcyVlpCeGowrphHyVjsCgs
# fCY6YJ4kMAoQrGQx97CgAL7t0txsdTcIZuR47Rp/0GDJpcqihN3/vRZFKTDCEJnp
# RpcAMC4wD6ryoZHONvyLcAb9QxNldXrCKgejzzceFtoIknNCqgCx6c5pInVaVDhk
# /wIBOxaEaTVi0uKFonBKkhMLpRfctfPaVor9O9FBp2ta+7RlKh54r7S1
# SIG # End signature block
