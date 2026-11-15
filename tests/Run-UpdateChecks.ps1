#Requires -Version 5.1
<#
.SYNOPSIS
    CI-раннер для транзакционного самообновления: Pester-тесты + проверки tools.
.DESCRIPTION
    Выполняется тем интерпретатором, который выбрала матрица update-tests.yml
    (Windows PowerShell 5.1 или PowerShell 7): шаг workflow запускает
    "powershell"/"pwsh" как дочерний процесс, здесь $PSVersionTable подтверждает
    фактическую версию. Устанавливает Pester v5+ в CurrentUser, гоняет
    tests\Update.Tests.ps1 с NUnitXml-отчётом и три проверки из tools\.
    Код возврата: 0 - всё зелёное; 1 - любой провал.
#>

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

Write-Host ("Interpreter: PS {0} ({1})" -f $PSVersionTable.PSVersion.ToString(), $PSVersionTable.PSEdition)

# --- Pester v5+ -------------------------------------------------------------
$pester = Get-Module -ListAvailable -Name Pester |
    Sort-Object Version -Descending | Select-Object -First 1
if ($null -eq $pester -or $pester.Version.Major -lt 5) {
    Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck -MinimumVersion 5.0.0
}
Import-Module Pester -MinimumVersion 5.0.0 -Force
$pesterVersion = (Get-Module Pester).Version
Write-Host "Pester: $pesterVersion"
if ($pesterVersion.Major -lt 5) {
    Write-Host "::error::Ожидался Pester v5+, получен $pesterVersion"
    exit 1
}

$repoRoot = Split-Path -Parent $PSScriptRoot

# --- Pester: tests\Update.Tests.ps1 ------------------------------------------
$runnerTemp = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }
$reportPath = Join-Path $runnerTemp 'update-tests-nunit.xml'
$cfg = New-PesterConfiguration
$cfg.Run.Path = Join-Path $repoRoot 'tests\Update.Tests.ps1'
$cfg.Run.PassThru = $true
$cfg.Output.Verbosity = 'Detailed'
$cfg.TestResult.Enabled = $true
$cfg.TestResult.OutputFormat = 'NUnitXml'
$cfg.TestResult.OutputPath = $reportPath
$result = Invoke-Pester -Configuration $cfg

if (-not (Test-Path -LiteralPath $reportPath)) {
    Write-Host '::error::NUnitXml-отчёт не создан'
    exit 1
}
if ($result.FailedCount -gt 0) {
    Write-Host ("::error::Pester: провалено тестов {0} из {1}" -f $result.FailedCount, $result.TotalCount)
    exit 1
}
Write-Host ("Pester OK: {0} из {1} тестов, отчёт: {2}" -f $result.PassedCount, $result.TotalCount, $reportPath)

# --- Проверки tools ----------------------------------------------------------
foreach ($tool in @('Test-Xaml.ps1', 'Test-Contrast.ps1', 'Test-ZipSlip.ps1')) {
    $toolPath = Join-Path (Join-Path $repoRoot 'tools') $tool
    & $toolPath
    if ($LASTEXITCODE -ne 0) {
        Write-Host ("::error::{0} завершился с кодом {1}" -f $tool, $LASTEXITCODE)
        exit 1
    }
}

Write-Host 'ALL CHECKS PASSED'
