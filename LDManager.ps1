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

# SIG # Begin signature block
# MIIb5gYJKoZIhvcNAQcCoIIb1zCCG9MCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUV5ylUKITSCP98aixkP1CWZi8
# Q4SgghZQMIIDEjCCAfqgAwIBAgIQHb8OO1X7MrdClKYHA5HxWzANBgkqhkiG9w0B
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
# AQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMCMGCSqGSIb3DQEJBDEWBBSUg3vEPQ40
# XT4alGydRzIwCkBoGTANBgkqhkiG9w0BAQEFAASCAQCEbPsIEjAV19A0p2S9fzjk
# IaQtA4kZe7piCWeDW1F/jAyDGMyYZp0zb8p0RGfzPesJW72zze/hYLAnp4rsYLjx
# XZaCZ/Emjirr2xf8OGGG7yexKYYI2WYRhk2o0GI1WeKPLfph9dFEBe+umFj8M/5U
# X9pDrnTtWMAGVtT5duE0hF1K/EjOEvT6jK66CimJoDt6ApdR60roSoaTlrnjjP18
# fTQTY012xx3SnWyM9La7ljAGMcX1gGkTXQJ+4tAkrlponcNQ3Z+7qjwUlT/XzFLc
# YVHkWDI3aogQNFk0Dw2U0KS0AEs/jVZmdZwYm+ykHONe5bWmM781yEjs/n4LKvh2
# oYIDJjCCAyIGCSqGSIb3DQEJBjGCAxMwggMPAgEBMH0waTELMAkGA1UEBhMCVVMx
# FzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVz
# dGVkIEc0IFRpbWVTdGFtcGluZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMQIQCE/c
# M09+RU7bww+P+ZIYNTANBglghkgBZQMEAgEFAKBpMBgGCSqGSIb3DQEJAzELBgkq
# hkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8XDTI2MDkzMDExNTkzNlowLwYJKoZIhvcN
# AQkEMSIEIOfc5EAH1QDJ7/9Hp9u1SloccPwNQKOUi+zvsron7rXcMA0GCSqGSIb3
# DQEBAQUABIICAIiuMPvHYgmYTY/OX+ERssUJDwt1OwLY00vmp1Lc3lbnV94jteQ4
# Rp232M62JvbXGxk6aiDqIWP/AI+8qLSdMZ4omrkK9h8yIZPM+r3VPIPGJwibuveY
# RwIvDcRMvjC+dilxQ6ebNo5/BNHTi1MB6hPyednyjQzRp/sDz6Kt4r3gqXhTCHuB
# wC2Mbo+2/vwu/0Nz9WR+JOX4bJtnavtpYhLUozmTLLVmSJH90PmJ0r64CT1ct9od
# N4rSFZ85oG5QIUulxgh6aVpBABTjm8ifRWB311PuaeZDZ9lZgOWMBuWrSKMnGUB3
# 7BYCwaXF7Jq4pH1PKnWfz7PDiNOnIQ24sYK5RgERXNICCGSBayLgYumy5t2v0vha
# tgav7rTr7NYXB0eAhmed6Rf2dGzsKJSfXAz7cbS6sJMRsxQacwMsnMbFES20tmH9
# FbqFX11gHuu8qtVgLfXovNfIYp4VfyTZYwvHKjVUuoxIT6D/YxPolY8ucLR0GIuo
# IJMMmoTwY+SFtGCyJcqOxf8d6y0VoWf27UhMKLaJ3PUny3EjzuJQbtvYG4FbZ1+1
# 0KUzIJs5h8+o5tAhrjJRpqr4oNJ2NszTYHIMswxzvlc7FTBQ2zvvvZw2qWRNOsES
# n7YwmWo0xDpATDhRlu0n8A1d99HHXDj/yfSwGS89WkuwUWblf+0LvXnr
# SIG # End signature block
