#Requires -Version 5.1
<#
.SYNOPSIS
    Проверяет, что XAML-разметка интерфейса из ZapretControl.ps1 корректно разбирается WPF.

.DESCRIPTION
    Извлекает here-string `$windowXaml = @' ... '@` из основного скрипта приложения,
    разбирает его как XML и загружает через Windows.Markup.XamlReader.
    Печатает длину XAML и Title окна. При ошибке выводит всю цепочку InnerException
    и завершается с кодом 1. Приложение при этом не запускается.

.PARAMETER Path
    Путь к ZapretControl.ps1. По умолчанию — ZapretControl.ps1 рядом с каталогом tools.

.PARAMETER StaChild
    Служебный переключатель: признак перезапуска в STA-потоке. Не указывайте вручную.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Sta -File .\tools\Test-Xaml.ps1

.EXAMPLE
    .\tools\Test-Xaml.ps1 -Path .\ZapretControl.ps1
#>
[CmdletBinding()]
param(
    [string]$Path = '',
    [switch]$StaChild
)

$ErrorActionPreference = 'Stop'
$toolName = 'Test-Xaml'

function Write-Info([string]$Text) { Write-Host ('[' + $toolName + '] ' + $Text) }
function Write-Ok([string]$Text) { Write-Host ('[' + $toolName + '] ' + $Text) -ForegroundColor Green }
function Write-Fail([string]$Text) { Write-Host ('[' + $toolName + '] ' + $Text) -ForegroundColor Red }

function Write-ExceptionChain($ErrorRecord) {
    $index = 0
    $ex = $ErrorRecord.Exception
    while ($ex) {
        Write-Host ('[' + $toolName + ']   [' + $index + '] ' + $ex.GetType().FullName + ': ' + $ex.Message) -ForegroundColor Red
        $ex = $ex.InnerException
        $index++
    }
    if ($ErrorRecord.InvocationInfo -and $ErrorRecord.InvocationInfo.PositionMessage) {
        Write-Host ('[' + $toolName + ']   Позиция: ' + $ErrorRecord.InvocationInfo.PositionMessage.Trim()) -ForegroundColor DarkGray
    }
}

# ---------------------------------------------------------------------------
#  XamlReader требует STA. При необходимости перезапускаем себя в STA-потоке.
# ---------------------------------------------------------------------------
$apartment = [Threading.Thread]::CurrentThread.GetApartmentState()
if ($apartment -ne [Threading.ApartmentState]::STA) {
    if ($StaChild) {
        Write-Fail 'Не удалось получить STA-поток даже после перезапуска.'
        exit 1
    }
    Write-Info ('Текущий поток: ' + $apartment + '. Перезапуск в STA...')
    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $relaunch = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Sta', '-File', $PSCommandPath, '-StaChild')
    & $exe @relaunch
    exit $LASTEXITCODE
}

# ---------------------------------------------------------------------------
#  Пути
# ---------------------------------------------------------------------------
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
#  Извлечение here-string с XAML
# ---------------------------------------------------------------------------
$raw = [IO.File]::ReadAllText($Path)
$marker = '$windowXaml = @'''
$startIdx = $raw.IndexOf($marker, [StringComparison]::Ordinal)
if ($startIdx -lt 0) {
    Write-Fail ('Не найден маркер ' + $marker + ' в ' + $Path)
    exit 1
}

$bodyStart = $raw.IndexOf("`n", $startIdx)
if ($bodyStart -lt 0) {
    Write-Fail 'Не удалось найти начало XAML-блока (перевод строки после маркера).'
    exit 1
}
$bodyStart++

$endIdx = $raw.IndexOf("`n'@", $bodyStart, [StringComparison]::Ordinal)
if ($endIdx -lt 0) {
    Write-Fail 'Не удалось найти закрывающий here-string ''@'' после маркера $windowXaml.'
    exit 1
}

$xaml = $raw.Substring($bodyStart, $endIdx - $bodyStart)
Write-Info ('Длина XAML: ' + $xaml.Length + ' символов')
if ($xaml.Length -lt 100) {
    Write-Fail 'XAML-блок подозрительно короткий — вероятно, разметка извлечена неверно.'
    exit 1
}

# ---------------------------------------------------------------------------
#  Загрузка через XamlReader
# ---------------------------------------------------------------------------
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml

$window = $null
try {
    [xml]$xmlDoc = $xaml
    Write-Info ('XML корень: ' + $xmlDoc.DocumentElement.Name)
} catch {
    Write-Fail 'XAML не является корректным XML.'
    Write-ExceptionChain $_
    exit 1
}

try {
    $xmlReader = New-Object System.Xml.XmlNodeReader($xmlDoc)
    $window = [Windows.Markup.XamlReader]::Load($xmlReader)
    Write-Ok ('PASS: XAML загружен. Title = "' + $window.Title + '"')
    Write-Info ('Корневой тип: ' + $window.GetType().FullName)
    exit 0
} catch {
    Write-Fail 'FAIL: XamlReader не смог загрузить разметку.'
    Write-ExceptionChain $_
    exit 1
} finally {
    if ($window) {
        try { $window.Close() } catch { }
        $window = $null
    }
}
