# Тесты интеграции Sieve. HTTP-граница (Invoke-WebRequest / Invoke-SieveHttp)
# подменяется; проверяется реальная логика LD.Sieve.ps1 и ядра.
# Запуск:  Invoke-Pester -Path .\tests\Sieve.Tests.ps1

BeforeAll {
    $repo = Split-Path -Parent $PSScriptRoot
    . (Join-Path $repo 'LDManager.ps1') -LoadOnly
    $env:SIEVE_API_KEY = 'dc_sk_TEST'

    function New-SieveFakeResponse {
        param($Content, [int]$StatusCode = 200, [bool]$Ok = $true, [string]$RetryAfter = $null, [string]$ErrorText = $null)
        return [pscustomobject]@{ Ok = $Ok; StatusCode = $StatusCode; Content = $Content; Raw = $null; RetryAfter = $RetryAfter; Error = $Error }
    }
}

AfterAll {
    Remove-Item Env:\SIEVE_API_KEY -ErrorAction SilentlyContinue
}

Describe 'Sieve: построение запроса (HTTP-граница)' {
    It 'префиксует относительный путь базовым URL' {
        (Get-SieveAbsoluteUri -Path '/files/a.csv') | Should -Be 'https://scrape.usesieve.com/files/a.csv'
        (Get-SieveAbsoluteUri -Path 'files/a.csv')  | Should -Be 'https://scrape.usesieve.com/files/a.csv'
        (Get-SieveAbsoluteUri -Path 'https://x/y')  | Should -Be 'https://x/y'
    }

    It 'шлёт Bearer-токен, метод, JSON-тело и разбирает ответ' {
        $env:SIEVE_API_KEY = 'dc_sk_TEST'
        $script:captured = $null
        Mock Invoke-WebRequest {
            param($Uri, $Method, $Headers, $Body, $ContentType, $TimeoutSec, $UseBasicParsing, $OutFile)
            $script:captured = @{ Uri = $Uri; Method = $Method; Headers = $Headers; Body = $Body; ContentType = $ContentType }
            return [pscustomobject]@{ StatusCode = 202; Content = '{"status":"queued","session_id":"s1"}'; Headers = @{} }
        }

        $r = Invoke-SieveHttp -Method POST -Path '/api/scrapes' -Body @{ instruction = 'Extract'; compliance_mode = 'regular' }

        $r.Ok | Should -BeTrue
        $r.StatusCode | Should -Be 202
        $r.Content.status | Should -Be 'queued'
        $script:captured.Uri | Should -Be 'https://scrape.usesieve.com/api/scrapes'
        $script:captured.Method | Should -Be 'POST'
        $script:captured.Headers['Authorization'] | Should -Be 'Bearer dc_sk_TEST'
        $script:captured.ContentType | Should -Be 'application/json'
        ($script:captured.Body | ConvertFrom-Json).instruction | Should -Be 'Extract'
        # ключ не должен утекать в разобранный ответ
        $r.Raw | Should -Not -Match 'dc_sk_TEST'
    }
}

Describe 'Sieve: статусы запуска' {
    It 'распознаёт running / done / refused / неизвестный' {
        (Get-SieveSessionKind -Session ([pscustomobject]@{ status = 'running' })) | Should -Be 'running'
        (Get-SieveSessionKind -Session ([pscustomobject]@{ status = 'done' }))    | Should -Be 'done'
        (Get-SieveSessionKind -Session ([pscustomobject]@{ status = 'refused' })) | Should -Be 'refused'
        (Get-SieveSessionKind -Session ([pscustomobject]@{ status = 'weird' }))   | Should -Be 'unknown'
        (Get-SieveSessionKind -Session $null) | Should -Be 'unknown'
    }

    It 'running -> done: опрашивает до готовности' {
        $script:queue = @(
            (New-SieveFakeResponse -Content ([pscustomobject]@{ status = 'running'; turns = 0 })),
            (New-SieveFakeResponse -Content ([pscustomobject]@{ status = 'done'; turns = 1; summary = 'ok' }))
        )
        Mock Invoke-SieveHttp {
            $r = $script:queue[0]
            if ($script:queue.Count -gt 1) { $script:queue = @($script:queue[1..($script:queue.Count - 1)]) }
            return $r
        }
        $res = Wait-SieveSessionComplete -SessionId 's1' -Sleep { param($s) } -MaxPolls 10
        $res.Kind | Should -Be 'done'
        Should -Invoke Invoke-SieveHttp -Times 2 -Exactly
    }

    It 'refused: терминально, повторных опросов нет' {
        Mock Invoke-SieveHttp {
            New-SieveFakeResponse -Content ([pscustomobject]@{ status = 'refused'; refusal = [pscustomobject]@{ code = 'quota'; message = 'no credits' } })
        }
        $res = Wait-SieveSessionComplete -SessionId 's1' -Sleep { param($s) } -MaxPolls 10
        $res.Kind | Should -Be 'refused'
        $res.Error | Should -Match 'кредит'
        Should -Invoke Invoke-SieveHttp -Times 1 -Exactly
    }

    It 'неизвестный статус -> ошибка' {
        Mock Invoke-SieveHttp { New-SieveFakeResponse -Content ([pscustomobject]@{ status = 'boom' }) }
        $res = Wait-SieveSessionComplete -SessionId 's1' -Sleep { param($s) } -MaxPolls 10
        $res.Kind | Should -Be 'error'
    }
}

Describe 'Sieve: дозапрос (follow-up) и проверка хода' {
    It 'не останавливается, пока turns не превысит зафиксированное значение' {
        # 0: GET до отправки (turns=1)  -> targetTurn=2
        # 1: POST messages
        # 2: опрос: done turns=1 (мало, продолжаем)
        # 3: опрос: done turns=2 (готово)
        $script:queue = @(
            (New-SieveFakeResponse -Content ([pscustomobject]@{ status = 'running'; turns = 1 })),
            (New-SieveFakeResponse -Content ([pscustomobject]@{ status = 'running' })),
            (New-SieveFakeResponse -Content ([pscustomobject]@{ status = 'done'; turns = 1 })),
            (New-SieveFakeResponse -Content ([pscustomobject]@{ status = 'done'; turns = 2 }))
        )
        Mock Invoke-SieveHttp {
            $r = $script:queue[0]
            if ($script:queue.Count -gt 1) { $script:queue = @($script:queue[1..($script:queue.Count - 1)]) }
            return $r
        }
        Mock Update-SieveRunRecord { }

        $res = Send-SieveFollowUp -SessionId 's1' -Instruction 'add author' -Sleep { param($s) }
        $res.Kind | Should -Be 'done'
        $res.Session.turns | Should -Be 2
        Should -Invoke Invoke-SieveHttp -Times 4 -Exactly
    }

    It 'при 409 ждёт и повторяет тот же запрос' {
        $script:queue = @(
            (New-SieveFakeResponse -Content ([pscustomobject]@{ status = 'running'; turns = 0 })),
            (New-SieveFakeResponse -Ok $false -StatusCode 409 -ErrorText 'HTTP 409'),
            (New-SieveFakeResponse -Content ([pscustomobject]@{ status = 'running' })),
            (New-SieveFakeResponse -Content ([pscustomobject]@{ status = 'done'; turns = 1 }))
        )
        Mock Invoke-SieveHttp {
            $r = $script:queue[0]
            if ($script:queue.Count -gt 1) { $script:queue = @($script:queue[1..($script:queue.Count - 1)]) }
            return $r
        }
        Mock Update-SieveRunRecord { }
        $res = Send-SieveFollowUp -SessionId 's1' -Instruction 'more' -Sleep { param($s) }
        $res.Kind | Should -Be 'done'
        Should -Invoke Invoke-SieveHttp -Times 4 -Exactly
    }
}

Describe 'Sieve: маппинг ошибок' {
    It 'переводит коды в понятные сообщения' {
        (Get-SieveErrorMessage -StatusCode 400 -Body ([pscustomobject]@{ message = 'bad field' })) | Should -Match 'bad field'
        (Get-SieveErrorMessage -StatusCode 401 -Body $null) | Should -Match '401'
        (Get-SieveErrorMessage -StatusCode 402 -Body $null) | Should -Match 'кредит'
        (Get-SieveErrorMessage -StatusCode 404 -Body $null) | Should -Match '404'
        (Get-SieveErrorMessage -StatusCode 429 -Body $null) | Should -Match '429'
        (Get-SieveErrorMessage -StatusCode 503 -Body $null) | Should -Match 'недоступ'
        (Get-SieveErrorMessage -StatusCode 200 -Body ([pscustomobject]@{ refusal = [pscustomobject]@{ code = 'quota' } })) | Should -Match 'кредит'
    }
}

Describe 'Sieve: старт запуска и безопасные повторы' {
    It 'НЕ повторяет POST при таймауте/сетевой ошибке (запуск мог создаться)' {
        Mock Save-SieveRunRecord { }
        Mock Invoke-SieveHttp { New-SieveFakeResponse -Ok $false -StatusCode 0 -ErrorText 'timeout' }
        $r = Start-SieveScrapeRun -Instruction 'test' -Sleep { param($s) }
        $r | Should -BeNullOrEmpty
        Should -Invoke Invoke-SieveHttp -Times 1 -Exactly
    }

    It 'повторяет POST после 429 и сохраняет session_id до возврата' {
        $script:queue = @(
            (New-SieveFakeResponse -Ok $false -StatusCode 429 -RetryAfter '0' -ErrorText 'HTTP 429'),
            (New-SieveFakeResponse -StatusCode 202 -Content ([pscustomobject]@{ status = 'queued'; session_id = 'sess-1'; poll = '/api/scrapes/sess-1' }))
        )
        Mock Invoke-SieveHttp {
            $r = $script:queue[0]
            if ($script:queue.Count -gt 1) { $script:queue = @($script:queue[1..($script:queue.Count - 1)]) }
            return $r
        }
        $script:savedSession = $null
        Mock Save-SieveRunRecord { $script:savedSession = $SessionId }

        $r = Start-SieveScrapeRun -Instruction 'test' -Sleep { param($s) }
        $r.session_id | Should -Be 'sess-1'
        $script:savedSession | Should -Be 'sess-1'
        Should -Invoke Invoke-SieveHttp -Times 2 -Exactly
    }

    It 'не повторяет POST при 400/401/402 (исправляем запрос)' {
        Mock Invoke-SieveHttp { New-SieveFakeResponse -Ok $false -StatusCode 400 -ErrorText 'HTTP 400' }
        Mock Save-SieveRunRecord { }
        $r = Start-SieveScrapeRun -Instruction 'test' -Sleep { param($s) }
        $r | Should -BeNullOrEmpty
        Should -Invoke Invoke-SieveHttp -Times 1 -Exactly
    }
}

Describe 'Sieve: ключ не хранится в открытом виде' {
    It 'шифрует ключ (DPAPI) и не пишет плейнтекст' {
        $script:capturedEnc = 'UNSET'
        Mock Save-ManagerConfig { $script:capturedEnc = $SieveApiKeyEnc }

        Save-SieveApiKey -Plain 'dc_sk_SECRET123'

        $script:capturedEnc | Should -Not -BeNullOrEmpty
        $script:capturedEnc | Should -Not -Be 'dc_sk_SECRET123'
        (Unprotect-SieveSecret -Enc $script:capturedEnc) | Should -Be 'dc_sk_SECRET123'
    }

    It 'читает ключ из переменной окружения' {
        $env:SIEVE_API_KEY = 'dc_sk_FROM_ENV'
        (Get-StoredSieveApiKey) | Should -Be 'dc_sk_FROM_ENV'
    }
}

Describe 'Sieve: вход по коду устройства' {
    It 'authorization_pending -> успех единожды; ключ возвращается' {
        $script:queue = @(
            (New-SieveFakeResponse -Ok $false -StatusCode 400 -Content ([pscustomobject]@{ error = 'authorization_pending' })),
            (New-SieveFakeResponse -StatusCode 200 -Content ([pscustomobject]@{ api_key = 'dc_sk_NEW'; token_type = 'Bearer' }))
        )
        Mock Invoke-SieveHttp {
            $r = $script:queue[0]
            if ($script:queue.Count -gt 1) { $script:queue = @($script:queue[1..($script:queue.Count - 1)]) }
            return $r
        }
        $res = Wait-SieveDeviceToken -DeviceCode 'dev-1' -Interval 1 -ExpiresIn 600 -Sleep { param($s) }
        $res.Ok | Should -BeTrue
        $res.ApiKey | Should -Be 'dc_sk_NEW'
    }

    It 'access_denied -> останавливается' {
        Mock Invoke-SieveHttp { New-SieveFakeResponse -Ok $false -StatusCode 400 -Content ([pscustomobject]@{ error = 'access_denied' }) }
        $res = Wait-SieveDeviceToken -DeviceCode 'dev-1' -Interval 1 -Sleep { param($s) }
        $res.Ok | Should -BeFalse
        $res.Error | Should -Match 'отклон'
    }

    It 'slow_down -> увеличивает интервал и продолжает' {
        $script:queue = @(
            (New-SieveFakeResponse -Ok $false -StatusCode 400 -Content ([pscustomobject]@{ error = 'slow_down' })),
            (New-SieveFakeResponse -Ok $false -StatusCode 400 -Content ([pscustomobject]@{ error = 'authorization_pending' })),
            (New-SieveFakeResponse -StatusCode 200 -Content ([pscustomobject]@{ api_key = 'dc_sk_OK' }))
        )
        Mock Invoke-SieveHttp {
            $r = $script:queue[0]
            if ($script:queue.Count -gt 1) { $script:queue = @($script:queue[1..($script:queue.Count - 1)]) }
            return $r
        }
        $res = Wait-SieveDeviceToken -DeviceCode 'dev-1' -Interval 1 -ExpiresIn 600 -Sleep { param($s) }
        $res.Ok | Should -BeTrue
        Should -Invoke Invoke-SieveHttp -Times 3 -Exactly
    }
}

Describe 'GitHub: диагностика Test-GithubEndpoint' {
    It 'DNS не разрешился -> Ok=False и причина DNS' {
        Mock Resolve-GithubHost { return @{ Ok = $false; Error = 'DNS: не удалось разрешить badhost (boom)' } }
        $r = Test-GithubEndpoint -Url 'https://badhost/x'
        $r.Ok | Should -BeFalse
        $r.Detail | Should -Match 'DNS'
        $r.HttpCode | Should -BeNull
    }

    It 'TCP-подключение не удалось -> Ok=False и причина TCP' {
        Mock Resolve-GithubHost { return @{ Ok = $true; Addresses = @([net.ipaddress]'127.0.0.1') } }
        Mock Test-GithubTcpPort { return @{ Ok = $false; Error = 'TCP: не удалось подключиться к badhost:443 (refused)' } }
        $r = Test-GithubEndpoint -Url 'https://badhost/x'
        $r.Ok | Should -BeFalse
        $r.Detail | Should -Match 'TCP'
        $r.HttpCode | Should -BeNull
    }

    It 'HTTP 200 -> Ok=True, код и задержка заполнены' {
        Mock Resolve-GithubHost { return @{ Ok = $true; Addresses = @([net.ipaddress]'127.0.0.1') } }
        Mock Test-GithubTcpPort { return @{ Ok = $true; LatencyMs = 12 } }
        Mock Invoke-WebRequest { return [pscustomobject]@{ StatusCode = 200; Content = 'ok' } }
        $r = Test-GithubEndpoint -Url 'https://goodhost/x'
        $r.Ok | Should -BeTrue
        $r.HttpCode | Should -Be 200
        $r.LatencyMs | Should -Be 12
        $r.Detail | Should -BeNull
    }

    It 'HTTP 403/404 (хост доступен) -> Ok=True, код сохранён' {
        Mock Resolve-GithubHost { return @{ Ok = $true; Addresses = @([net.ipaddress]'127.0.0.1') } }
        Mock Test-GithubTcpPort { return @{ Ok = $true; LatencyMs = 5 } }
        foreach ($code in 403, 404) {
            Mock Invoke-WebRequest { throw 'boom' }
            Mock Get-HttpErrorStatusCode { return $code }
            $r = Test-GithubEndpoint -Url 'https://goodhost/x'
            $r.Ok | Should -BeTrue
            $r.HttpCode | Should -Be $code
        }
    }

    It 'Get-HttpErrorStatusCode достаёт код из синтетического исключения' {
        $err = [pscustomobject]@{ Exception = [pscustomobject]@{ Response = [pscustomobject]@{ StatusCode = [pscustomobject]@{ } } } }
        # StatusCode как enum-подобный объект: проверяем обычный путь через int
        $err2 = [pscustomobject]@{ Exception = [pscustomobject]@{ Response = [pscustomobject]@{ StatusCode = 404 } } }
        Get-HttpErrorStatusCode $err2 | Should -Be 404
        # без Response -> null
        Get-HttpErrorStatusCode ([pscustomobject]@{ Exception = [pscustomobject]@{ } }) | Should -BeNull
        Get-HttpErrorStatusCode $null | Should -BeNull
        # исключение без поля Response
        Get-HttpErrorStatusCode ([pscustomobject]@{ Exception = (New-Object System.Exception('x')) }) | Should -BeNull
    }

    It 'HTTPS-сбой без ответа (TLS) -> Ok=False и текст ошибки' {
        Mock Resolve-GithubHost { return @{ Ok = $true; Addresses = @([net.ipaddress]'127.0.0.1') } }
        Mock Test-GithubTcpPort { return @{ Ok = $true; LatencyMs = 5 } }
        Mock Invoke-WebRequest { throw (New-Object System.Net.WebException('TLS handshake failed')) }
        $r = Test-GithubEndpoint -Url 'https://goodhost/x'
        $r.Ok | Should -BeFalse
        $r.Detail | Should -Match 'HTTPS'
    }
}

Describe 'GitHub: причины ошибок проверки обновлений' {
    BeforeEach {
        $script:LastUpdateCheckError = $null
    }

    It 'HTTP 403 -> причина с подсказкой про лимит и токен' {
        Mock Invoke-WebRequest { throw 'boom' }
        Mock Get-HttpErrorStatusCode { return 403 }
        $u = Test-UpdateAvailable
        $u | Should -BeNull
        $script:LastUpdateCheckError | Should -Match '403'
        $script:LastUpdateCheckError | Should -Match 'лимит'
        $script:LastUpdateCheckError | Should -Match 'токен'
    }

    It 'HTTP 404 -> причина с подсказкой про ветку/репозиторий' {
        Mock Invoke-WebRequest { throw 'boom' }
        Mock Get-HttpErrorStatusCode { return 404 }
        $u = Test-UpdateAvailable
        $u | Should -BeNull
        $script:LastUpdateCheckError | Should -Match '404'
        $script:LastUpdateCheckError | Should -Match 'не найден'
    }

    It 'сетевая ошибка без HTTP-ответа -> текст исключения в причине' {
        Mock Invoke-WebRequest { throw (New-Object System.Net.WebException('connection refused')) }
        $u = Test-UpdateAvailable
        $u | Should -BeNull
        $script:LastUpdateCheckError | Should -Match 'сетевая ошибка'
        $script:LastUpdateCheckError | Should -Match 'connection refused'
    }

    It 'файл скачан, но без строки версии -> причина про отсутствие версии' {
        Mock Invoke-WebRequest { return [pscustomobject]@{ StatusCode = 200; Content = 'no version line here' } }
        $u = Test-UpdateAvailable
        $u | Should -BeNull
        $script:LastUpdateCheckError | Should -Match 'строки версии.*нет'
    }

    It 'версия получена -> причина сброса в null, результат сравнения корректен' {
        Mock Invoke-WebRequest { return [pscustomobject]@{ StatusCode = 200; Content = "`$script:ScriptVersion = '9.9.9'" } }
        $u = Test-UpdateAvailable
        $u | Should -BeTrue
        $script:LastUpdateCheckError | Should -BeNull
    }

    It 'локальная версия выше удалённой -> False без причины' {
        Mock Invoke-WebRequest { return [pscustomobject]@{ StatusCode = 200; Content = "`$script:ScriptVersion = '1.0.0'" } }
        $u = Test-UpdateAvailable
        $u | Should -BeFalse
        $script:LastUpdateCheckError | Should -BeNull
    }
}

Describe 'Релиз: Get-LatestReleaseInfo' {
    It 'объект из Invoke-RestMethod получает Tag и TagName, assets сохраняются' {
        # Реальный регресс: прямое присваивание $r.Tag = ... падало с «не
        # удалось найти свойство Tag», функция возвращала $null, и манифест
        # SHA256SUMS не загружался никогда.
        Mock Invoke-RestMethod {
            return [pscustomobject]@{ tag_name = 'v9.9.9'; assets = @([pscustomobject]@{ name = 'SHA256SUMS' }) }
        }
        $r = Get-LatestReleaseInfo
        $r | Should -Not -BeNull
        $r.Tag | Should -Be 'v9.9.9'
        $r.TagName | Should -Be 'v9.9.9'
        @($r.assets).Count | Should -Be 1
    }

    It 'ошибка запроса -> null, а не исключение' {
        Mock Invoke-RestMethod { throw 'boom' }
        Get-LatestReleaseInfo | Should -BeNull
    }
}

Describe 'Целостность: разбор манифеста SHA256SUMS' {
    BeforeEach {
        $script:LastChecksumError = $null
        $script:ChecksumReleaseTag = $null
    }

    It 'строки sha256sum разбираются в карту имя->хеш' {
        Mock Get-LatestReleaseInfo {
            return [pscustomobject]@{
                tag_name = 'v9.9.9'
                assets = @([pscustomobject]@{ name = 'SHA256SUMS'; browser_download_url = 'https://x/SHA256SUMS' })
            }
        }
        $hex = ('ab' * 32)
        Mock Invoke-WebRequest { return [pscustomobject]@{ Content = "$hex  LDManager.ps1`n" } }
        $m = Get-ReleaseChecksumManifest
        $m | Should -Not -BeNull
        $m['LDManager.ps1'] | Should -Be $hex
        $script:ChecksumReleaseTag | Should -Be 'v9.9.9'
    }

    It 'путь с каталогом и префиксом * распознаётся по имени файла' {
        Mock Get-LatestReleaseInfo {
            return [pscustomobject]@{
                tag_name = 'v9.9.9'
                assets = @([pscustomobject]@{ name = 'SHA256SUMS'; browser_download_url = 'https://x/SHA256SUMS' })
            }
        }
        $hex = ('cd' * 32)
        Mock Invoke-WebRequest { return [pscustomobject]@{ Content = "$hex *dist/LDManager.ps1`n" } }
        $m = Get-ReleaseChecksumManifest
        $m['LDManager.ps1'] | Should -Be $hex
    }

    It 'в релизе без SHA256SUMS -> null с внятной причиной' {
        Mock Get-LatestReleaseInfo { return [pscustomobject]@{ tag_name = 'v1.0.0'; assets = @() } }
        $m = Get-ReleaseChecksumManifest
        $m | Should -BeNull
        $script:LastChecksumError | Should -Match 'SHA256SUMS'
    }

    It 'нечитаемый манифест -> null, обновление продолжает работать без сверки' {
        Mock Get-LatestReleaseInfo {
            return [pscustomobject]@{
                tag_name = 'v1.0.0'
                assets = @([pscustomobject]@{ name = 'SHA256SUMS'; browser_download_url = 'https://x/SHA256SUMS' })
            }
        }
        Mock Invoke-WebRequest { throw 'boom' }
        Mock Get-HttpErrorStatusCode { return $null }
        $m = Get-ReleaseChecksumManifest
        $m | Should -BeNull
        $script:LastChecksumError | Should -Not -BeNullOrEmpty
    }

    It 'ассет как массив байт (octet-stream) разбирается так же, как строка' {
        # Реальный регресс: GitHub отдаёт SHA256SUMS как application/octet-stream,
        # Invoke-WebRequest возвращает в .Content byte[], и регулярное выражение
        # видело «97 100 98 ...» - манифест не распознавался.
        Mock Get-LatestReleaseInfo {
            return [pscustomobject]@{
                tag_name = 'v1.2.3'
                assets = @([pscustomobject]@{ name = 'SHA256SUMS'; browser_download_url = 'https://x/SHA256SUMS' })
            }
        }
        $hex = ('ef' * 32)
        # Тело Mock выполняется вне локальной области It, поэтому байты кладём
        # в script-скоуп — иначе $body было бы $null и тест падал бы вр��де.
        $script:manifestBytesBody = [System.Text.Encoding]::UTF8.GetBytes("$hex  LDManager.ps1`n")
        Mock Invoke-WebRequest { return [pscustomobject]@{ Content = $script:manifestBytesBody } }
        $m = Get-ReleaseChecksumManifest
        $m | Should -Not -BeNull
        $m['LDManager.ps1'] | Should -Be $hex
        $script:ChecksumReleaseTag | Should -Be 'v1.2.3'
    }

    It 'мусор вместо манифеста -> null, а не пустая карта' {
        Mock Get-LatestReleaseInfo {
            return [pscustomobject]@{
                tag_name = 'v1.0.0'
                assets = @([pscustomobject]@{ name = 'SHA256SUMS'; browser_download_url = 'https://x/SHA256SUMS' })
            }
        }
        Mock Invoke-WebRequest { return [pscustomobject]@{ Content = "ничего полезного`n" } }
        $m = Get-ReleaseChecksumManifest
        $m | Should -BeNull
        $script:LastChecksumError | Should -Match 'не распознан'
    }
}

Describe 'Целостность: выбор ref для скачивания' {
    BeforeEach {
        $script:ChecksumReleaseTag = $null
        $script:RepoBranch = 'main'
    }

    It 'манифест от релиза текущей версии -> качаем по тегу' {
        $script:ChecksumReleaseTag = "v$($script:ScriptVersion)"
        Get-UpdateDownloadRef | Should -Be "v$($script:ScriptVersion)"
    }

    It 'релиз старее локальной версии -> качаем ветку, а не откат на старую версию' {
        # Реальный случай: GitHub считал latest'ом v2.0.5, хотя локально уже 2.0.6.
        $script:ChecksumReleaseTag = 'v1.0.0'
        Get-UpdateDownloadRef | Should -Be 'main'
    }

    It 'манифеста нет -> качаем ветку' {
        Get-UpdateDownloadRef | Should -Be 'main'
    }
}

Describe 'Целостность: хеши и нормализация содержимого' {
    It 'Get-BytesHash совпадает с Get-FileHash для тех же байтов' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("ldm_t_" + [guid]::NewGuid().ToString('N') + '.bin')
        $bytes = [System.Text.Encoding]::UTF8.GetBytes('LDManager проверка целостности')
        [System.IO.File]::WriteAllBytes($tmp, $bytes)
        try {
            $expected = (Get-FileHash -Path $tmp -Algorithm SHA256).Hash.ToLower()
            Get-BytesHash -Bytes $bytes | Should -Be $expected
        } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }

    It 'Get-BytesHash возвращает 64 hex-символа в нижнем регистре' {
        $h = Get-BytesHash -Bytes ([System.Text.Encoding]::UTF8.GetBytes('x'))
        $h | Should -Match '^[0-9a-f]{64}$'
    }

    It 'BOM вырезается из нормализованного содержимого' {
        Get-PlainContent -Text ([char]0xFEFF + 'abc') | Should -BeExactly 'abc'
    }

    It 'CRLF приводится к LF' {
        Get-PlainContent -Text "a`r`nb" | Should -BeExactly "a`nb"
    }

    It 'блок подписи вырезается, содержимое сохраняется' {
        $signed = "код`r`n" + "# SIG # Begin signature block`r`nabc123`r`n# SIG # End signature block`r`n"
        Get-PlainContent -Text $signed | Should -BeExactly "код`n"
    }

    It 'подписанная CRLF-копия и LF-оригинал дают одинаковое содержимое' {
        # Ключевой инвариант сверки: у каждой копии своя подпись и свой таймстемп,
        # поэтому сравнивать байты нельзя - только содержимое без подписи.
        $orig = "строка 1`nстрока 2`n"
        $copy = ($orig -replace "`n", "`r`n") + "# SIG # Begin signature block`r`nDEADBEEF`r`n# SIG # End signature block`r`n"
        Get-PlainContent -Text $copy | Should -BeExactly $orig
    }
}
