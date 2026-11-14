#Requires -Version 5.1
<#
.SYNOPSIS
    Регресс-гард против Zip Slip: проверяет, что Expand-Archive не выпускает файлы за пределы каталога.

.DESCRIPTION
    Во временном каталоге собирается zip с записью `..\..\evil.txt`
    (System.IO.Compression.ZipArchive), затем он распаковывается через Expand-Archive
    в изолированный подкаталог. Проверка PASS, если распаковка упала ИЛИ файл
    не появился за пределами целевого каталога. При выходе за пределы — FAIL и код 1.
    Временный каталог удаляется в finally.

.PARAMETER KeepArtifacts
    Не удалять временный каталог с zip и результатом распаковки (для разбора инцидента).

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-ZipSlip.ps1

.NOTES
    Скрипт ничего не запускает в приложении и не трогает службы — только файлы во %TEMP%.
#>
[CmdletBinding()]
param(
    [switch]$KeepArtifacts
)

$ErrorActionPreference = 'Stop'
$toolName = 'Test-ZipSlip'

function Write-Info([string]$Text) { Write-Host ('[' + $toolName + '] ' + $Text) }
function Write-Ok([string]$Text) { Write-Host ('[' + $toolName + '] ' + $Text) -ForegroundColor Green }
function Write-Fail([string]$Text) { Write-Host ('[' + $toolName + '] ' + $Text) -ForegroundColor Red }

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$entryName = '..\..\evil.txt'
$tempBase = [IO.Path]::GetTempPath().TrimEnd('\')
$sandbox = Join-Path $tempBase ('zapret-tools-zipslip-' + $PID)
$zipPath = Join-Path $sandbox 'payload.zip'
$workDir = Join-Path $sandbox 'a\b'          # сюда распаковываем
$escapePath = [IO.Path]::GetFullPath((Join-Path $workDir $entryName))  # sandbox\evil.txt
$workPrefix = $workDir.TrimEnd('\') + '\'

$exitCode = 1
try {
    if (Test-Path -LiteralPath $sandbox) {
        Remove-Item -LiteralPath $sandbox -Recurse -Force
    }
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null
    Write-Info ('Временный каталог: ' + $sandbox)

    # --- Сборка zip с path traversal --------------------------------------
    $fileStream = [IO.File]::Create($zipPath)
    try {
        $archive = New-Object System.IO.Compression.ZipArchive(
            $fileStream,
            [System.IO.Compression.ZipArchiveMode]::Create,
            $true
        )
        try {
            $entry = $archive.CreateEntry($entryName)
            $writer = New-Object IO.StreamWriter($entry.Open(), (New-Object Text.UTF8Encoding($false)))
            try { $writer.Write('zip-slip-probe') } finally { $writer.Dispose() }
        } finally {
            $archive.Dispose()
        }
    } finally {
        $fileStream.Dispose()
    }
    Write-Info ('Запись в архиве: ' + $entryName)

    # --- Контроль, что библиотека не «нормализовала» имя записи ------------
    $readArchive = [IO.Compression.ZipFile]::OpenRead($zipPath)
    try { $storedNames = @($readArchive.Entries | ForEach-Object { $_.FullName }) } finally { $readArchive.Dispose() }
    Write-Info ('Записи в zip: ' + ($storedNames -join ', '))
    if (-not ($storedNames -contains $entryName)) {
        Write-Fail 'Тест некорректен: имя записи с ".." не сохранилось в архиве.'
        exit 1
    }

    # --- Распаковка -------------------------------------------------------
    $extractError = $null
    try {
        Expand-Archive -LiteralPath $zipPath -DestinationPath $workDir -Force -ErrorAction Stop
        Write-Info 'Expand-Archive: завершился без ошибки.'
    } catch {
        $extractError = $_
        Write-Info ('Expand-Archive: упал — ' + $_.Exception.GetType().FullName + ': ' + $_.Exception.Message)
    }

    # --- Поиск файлов вне целевого каталога -------------------------------
    $stray = @()
    $allFiles = @(Get-ChildItem -LiteralPath $sandbox -Recurse -File -ErrorAction SilentlyContinue)
    foreach ($file in $allFiles) {
        if ($file.FullName -eq $zipPath) { continue }
        if (-not $file.FullName.StartsWith($workPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            $stray += $file.FullName
        }
    }

    $escapedTarget = Test-Path -LiteralPath $escapePath
    Write-Info ('Ожидаемая цель обхода: ' + $escapePath)
    Write-Info ('Файл существует: ' + $escapedTarget)
    Write-Info ('Файлов вне целевого каталога: ' + $stray.Count)

    if ($stray.Count -gt 0) {
        foreach ($path in $stray) { Write-Fail ('  Обнаружен файл вне каталога: ' + $path) }
        Write-Fail 'FAIL: Zip Slip возможен — распаковка выпустила файл за пределы каталога.'
        $exitCode = 1
    } else {
        if ($extractError) {
            Write-Ok 'PASS: Zip Slip заблокирован (распаковка отклонена).'
        } else {
            Write-Ok 'PASS: Zip Slip заблокирован (файл за пределы каталога не попал).'
        }
        $exitCode = 0
    }
} catch {
    Write-Fail ('FAIL: непредвиденная ошибка — ' + $_.Exception.Message)
    $exitCode = 1
} finally {
    if ($KeepArtifacts) {
        if (Test-Path -LiteralPath $sandbox) { Write-Info ('Артефакты сохранены: ' + $sandbox) }
    } else {
        try {
            if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force }
        } catch {
            Write-Fail ('Не удалось удалить временный каталог: ' + $_.Exception.Message)
        }
    }
}

exit $exitCode
