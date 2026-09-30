# Converts PSScriptAnalyzer findings to SARIF 2.1.0 so they show up in
# GitHub Code Scanning (CodeQL does not support PowerShell).
# Usage: pwsh -File scripts/Build-Sarif.ps1 -OutputPath results.sarif
param(
    [string]$OutputPath = 'results.sarif'
)

$ErrorActionPreference = 'Stop'

# Same exclusions as the CI workflow: interactive menu and DPAPI storage
# are deliberate project decisions, not defects.
$excludedRules = @(
    'PSAvoidUsingWriteHost',
    'PSUseShouldProcessForStateChangingFunctions',
    'PSAvoidUsingPlainTextForPassword',
    'PSAvoidUsingConvertToSecureStringWithPlainText'
)

$findings = Invoke-ScriptAnalyzer -Path . -Recurse |
    Where-Object { $excludedRules -notcontains $_.RuleName }

$severityMap = @{
    'Error'   = 'error'
    'Warning' = 'warning'
    'Info'    = 'note'
}

$rules = @{}
$results = New-Object System.Collections.Generic.List[object]
$uriBase = [Uri]"$((Get-Location).Path)/"

foreach ($f in $findings) {
    $ruleId = [string]$f.RuleName
    if (-not $rules.ContainsKey($ruleId)) {
        $rules[$ruleId] = [ordered]@{
            id               = $ruleId
            name             = $ruleId
            shortDescription = [ordered]@{ text = $ruleId }
            helpUri          = "https://github.com/PowerShell/PSScriptAnalyzer/tree/master/docs/RuleDocumentation/$ruleId.md"
            defaultConfiguration = [ordered]@{ level = $severityMap[[string]$f.Severity] }
        }
    }

    $rel = $uriBase.MakeRelativeUri([Uri]$f.ScriptPath).ToString()
    $results.Add([ordered]@{
        ruleId    = $ruleId
        level     = $severityMap[[string]$f.Severity]
        message   = [ordered]@{ text = [string]$f.Message }
        locations = @(
            [ordered]@{
                physicalLocation = [ordered]@{
                    artifactLocation = [ordered]@{ uri = $rel }
                    region = [ordered]@{
                        startLine   = [int]$f.Line
                        startColumn = [int]$f.Column
                    }
                }
            }
        )
    })
}

$sarif = [ordered]@{
    '$schema' = 'https://json.schemastore.org/sarif-2.1.0.json'
    version   = '2.1.0'
    runs      = @(
        [ordered]@{
            tool = [ordered]@{
                driver = [ordered]@{
                    name            = 'PSScriptAnalyzer'
                    informationUri  = 'https://github.com/PowerShell/PSScriptAnalyzer'
                    version         = (Get-Module PSScriptAnalyzer | Select-Object -First 1).Version.ToString()
                    rules           = @($rules.Values)
                }
            }
            results = $results
        }
    )
}

$sarif | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputPath -Encoding UTF8
Write-Host ("SARIF written to {0}: {1} finding(s), {2} rule(s)" -f $OutputPath, $results.Count, $rules.Count)
