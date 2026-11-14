#Requires -Version 5.1
<#
.SYNOPSIS
    Проверяет WCAG-контраст цветовых пар всех тем Zapret Control.

.DESCRIPTION
    Читает блок $script:Themes = @{ ... } из ZapretControl.ps1, извлекает палитры
    light/dark/neon и считает коэффициент контраста WCAG 2.1 для пар:
    Ink/Surface, Body/Surface, Muted/Surface, Muted/Canvas, Ink/Canvas,
    AccentText/Accent, Ink/Field.

    Порог: 4.5 для текста (Ink, Body), 3.0 для приглушённого текста и акцента
    (Muted, AccentText/Accent). При нарушении печатает FAIL и завершается с кодом 1.

.PARAMETER Path
    Путь к ZapretControl.ps1. По умолчанию — рядом с каталогом tools.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-Contrast.ps1

.EXAMPLE
    .\tools\Test-Contrast.ps1 -Path .\ZapretControl.ps1
#>
[CmdletBinding()]
param(
    [string]$Path = ''
)

$ErrorActionPreference = 'Stop'
$toolName = 'Test-Contrast'

function Write-Info([string]$Text) { Write-Host ('[' + $toolName + '] ' + $Text) }
function Write-Fail([string]$Text) { Write-Host ('[' + $toolName + '] ' + $Text) -ForegroundColor Red }

if (-not $Path) {
    $Path = Join-Path (Join-Path $PSScriptRoot '..') 'ZapretControl.ps1'
}
if (-not (Test-Path -LiteralPath $Path)) {
    Write-Fail ('Файл не найден: ' + $Path)
    exit 1
}
$Path = (Resolve-Path -LiteralPath $Path).ProviderPath
Write-Info ('Файл: ' + $Path)

# ---------------------------------------------------------------------------
#  Разбор палитр
# ---------------------------------------------------------------------------
$lines = [IO.File]::ReadAllLines($Path)
$startIdx = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^\s*\$script:Themes\s*=\s*@\{') { $startIdx = $i; break }
}
if ($startIdx -lt 0) {
    Write-Fail 'Не найден блок $script:Themes = @{...} в ZapretControl.ps1.'
    exit 1
}

$themes = [ordered]@{}
$current = $null
$pairRegex = '(?<key>[A-Za-z][A-Za-z0-9]*)\s*=\s*''(?<hex>#[0-9A-Fa-f]{6})'''

for ($i = $startIdx + 1; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]

    if ($line -match '^\s*(light|dark|neon)\s*=\s*@\{') {
        $current = $matches[1]
        if (-not $themes.Contains($current)) { $themes[$current] = @{} }
        continue
    }

    if ($line -match '^\s*\}\s*$') {
        if ($current) { $current = $null; continue }
        break
    }

    if (-not $current) { continue }

    foreach ($match in [regex]::Matches($line, $pairRegex)) {
        $key = $match.Groups['key'].Value
        $hex = $match.Groups['hex'].Value.ToUpperInvariant()
        $themes[$current][$key] = $hex
    }
}

$requiredThemes = @('light', 'dark', 'neon')
$missingThemes = @()
foreach ($name in $requiredThemes) {
    if (-not $themes.Contains($name)) { $missingThemes += $name }
}
if ($missingThemes.Count -gt 0) {
    Write-Fail ('Не найдены темы: ' + ($missingThemes -join ', ') + '. Проверьте формат блока $script:Themes.')
    exit 1
}

Write-Info ('Темы: ' + (($themes.Keys | ForEach-Object { $_ + ' (' + $themes[$_].Count + ' цветов)' }) -join ', '))

# ---------------------------------------------------------------------------
#  WCAG 2.1
# ---------------------------------------------------------------------------
function ConvertTo-Rgb([string]$Hex) {
    $value = $Hex.TrimStart('#')
    if ($value.Length -ne 6) { throw ('Некорректный цвет: ' + $Hex) }
    return @(
        [Convert]::ToInt32($value.Substring(0, 2), 16),
        [Convert]::ToInt32($value.Substring(2, 2), 16),
        [Convert]::ToInt32($value.Substring(4, 2), 16)
    )
}

function Get-Luminance([int[]]$Rgb) {
    $linear = New-Object double[] 3
    for ($i = 0; $i -lt 3; $i++) {
        $channel = $Rgb[$i] / 255.0
        if ($channel -le 0.03928) {
            $linear[$i] = $channel / 12.92
        } else {
            $linear[$i] = [Math]::Pow((($channel + 0.055) / 1.055), 2.4)
        }
    }
    return (0.2126 * $linear[0]) + (0.7152 * $linear[1]) + (0.0722 * $linear[2])
}

function Get-ContrastRatio([string]$Foreground, [string]$Background) {
    $fg = Get-Luminance (ConvertTo-Rgb $Foreground)
    $bg = Get-Luminance (ConvertTo-Rgb $Background)
    $lighter = $fg
    $darker = $bg
    if ($lighter -lt $darker) {
        $lighter = $bg
        $darker = $fg
    }
    return ($lighter + 0.05) / ($darker + 0.05)
}

$pairs = @(
    @{ Fg = 'Ink';        Bg = 'Surface'; Min = 4.5; Note = 'основной текст' },
    @{ Fg = 'Body';       Bg = 'Surface'; Min = 4.5; Note = 'обычный текст' },
    @{ Fg = 'Muted';      Bg = 'Surface'; Min = 3.0; Note = 'приглушённый текст' },
    @{ Fg = 'Muted';      Bg = 'Canvas';  Min = 3.0; Note = 'приглушённый на фоне' },
    @{ Fg = 'Ink';        Bg = 'Canvas';  Min = 4.5; Note = 'заголовки на фоне' },
    @{ Fg = 'AccentText'; Bg = 'Accent';  Min = 3.0; Note = 'текст на акценте' },
    @{ Fg = 'Ink';        Bg = 'Field';   Min = 4.5; Note = 'текст в поле' }
)

$headerFormat = '  {0,-7} {1,-18} {2,-9} {3,-9} {4,9}  {5,5}  {6}'
Write-Host ''
Write-Host ($headerFormat -f 'Тема', 'Пара', 'FG', 'BG', 'Контраст', 'Мин', 'Итог')
Write-Host ('  ' + ('-' * 72))

$failures = 0
$checks = 0

foreach ($themeName in $requiredThemes) {
    $palette = $themes[$themeName]
    foreach ($pair in $pairs) {
        $fgKey = $pair.Fg
        $bgKey = $pair.Bg
        $label = $fgKey + '/' + $bgKey
        $min = [double]$pair.Min

        if (-not $palette.ContainsKey($fgKey) -or -not $palette.ContainsKey($bgKey)) {
            Write-Host ($headerFormat -f $themeName, $label, '—', '—', '—', $min.ToString('0.0', [Globalization.CultureInfo]::InvariantCulture), 'FAIL (нет цвета)') -ForegroundColor Red
            $failures++
            continue
        }

        $checks++
        $foreground = $palette[$fgKey]
        $background = $palette[$bgKey]
        $ratio = Get-ContrastRatio $foreground $background
        $ratioText = $ratio.ToString('0.00', [Globalization.CultureInfo]::InvariantCulture)

        if ($ratio -lt $min) {
            $state = 'FAIL'
            $failures++
            Write-Host ($headerFormat -f $themeName, $label, $foreground, $background, $ratioText, $min.ToString('0.0', [Globalization.CultureInfo]::InvariantCulture), $state) -ForegroundColor Red
        } else {
            $state = 'OK'
            Write-Host ($headerFormat -f $themeName, $label, $foreground, $background, $ratioText, $min.ToString('0.0', [Globalization.CultureInfo]::InvariantCulture), $state) -ForegroundColor Green
        }
    }
}

Write-Host ''
if ($failures -gt 0) {
    Write-Fail ('FAIL: нарушено пар ' + $failures + ' из ' + $checks + ' (порог 4.5 для Ink/Body, 3.0 для Muted/Accent).')
    exit 1
}

Write-Host ('[' + $toolName + '] PASS: все ' + $checks + ' пар проходят пороги WCAG.') -ForegroundColor Green
exit 0
