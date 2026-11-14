#Requires -Version 5.1
<#
.SYNOPSIS
    Делает качественный PNG-снимок окна Zapret Control для baseline/скриншотов.

.DESCRIPTION
    Запускает ZapretControl.ps1 в режиме -Preview, выбирает страницу и тему через
    UI Automation, при необходимости разворачивает журнал, дожидается отрисовки
    (пауза + повторный CopyFromScreen) и сохраняет один PNG окна.
    data\config.json восстанавливается байт-в-байт, процесс убивается в finally.

.PARAMETER OutFile
    Путь к PNG. По умолчанию docs\ui-baseline\page<N>-<theme|current>.png рядом с tools.

.PARAMETER Theme
    Тема: light, dark, neon. Если не задана — используется тема из config.json.

.PARAMETER Page
    Страница: 0 = Обзор, 1 = Настройки, 2 = Инструменты, 3 = Тесты, 4 = Обновление.

.PARAMETER LogExpanded
    Развернуть журнал перед снимком.

.PARAMETER Seconds
    Лимит жизни процесса -PreviewSeconds. По умолчанию 30.

.PARAMETER StaChild
    Служебный переключатель: признак перезапуска в STA-потоке. Не указывайте вручную.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Sta -File .\tools\Capture-UiPreview.ps1 -Page 0 -Theme dark

.EXAMPLE
    .\tools\Capture-UiPreview.ps1 -Page 3 -Theme neon -LogExpanded -OutFile .\docs\ui-baseline\page3-neon-log.png
#>
[CmdletBinding()]
param(
    [string]$OutFile = '',
    [string]$Theme = '',
    [ValidateRange(0, 4)][int]$Page = 0,
    [switch]$LogExpanded,
    [ValidateRange(5, 600)][int]$Seconds = 30,
    [switch]$StaChild
)

$ErrorActionPreference = 'Stop'
$toolName = 'Capture-UiPreview'

function Write-Info([string]$Text) { Write-Host ('[' + $toolName + '] ' + $Text) }
function Write-Fail([string]$Text) { Write-Host ('[' + $toolName + '] ' + $Text) -ForegroundColor Red }

$navNames = @('Обзор', 'Настройки', 'Инструменты', 'Тесты', 'Обновление')
$themeNames = @{ light = 'Светлая'; dark = 'Тёмная'; neon = 'Неон' }
$validThemes = @('light', 'dark', 'neon')

if ($Theme -and -not ($validThemes -contains $Theme)) {
    Write-Fail ('Неизвестная тема: "' + $Theme + '". Допустимо: ' + ($validThemes -join ', '))
    exit 1
}
if ($Seconds -lt 15) {
    Write-Info ('Внимание: -Seconds ' + $Seconds + ' может не хватить на все шаги; рекомендуется 30.')
}

# ---------------------------------------------------------------------------
#  UI Automation требует STA. При необходимости перезапускаем себя.
# ---------------------------------------------------------------------------
$apartment = [Threading.Thread]::CurrentThread.GetApartmentState()
if ($apartment -ne [Threading.ApartmentState]::STA) {
    if ($StaChild) {
        Write-Fail 'Не удалось получить STA-поток даже после перезапуска.'
        exit 1
    }
    Write-Info ('Текущий поток: ' + $apartment + '. Перезапуск в STA...')
    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $relaunch = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Sta', '-File', $PSCommandPath, '-StaChild',
        '-Page', [string]$Page, '-Seconds', [string]$Seconds
    )
    if ($Theme) { $relaunch += @('-Theme', $Theme) }
    if ($OutFile) { $relaunch += @('-OutFile', $OutFile) }
    if ($LogExpanded) { $relaunch += '-LogExpanded' }
    & $exe @relaunch
    exit $LASTEXITCODE
}

# ---------------------------------------------------------------------------
#  Пути
# ---------------------------------------------------------------------------
$appPath = Join-Path (Join-Path $PSScriptRoot '..') 'ZapretControl.ps1'
if (-not (Test-Path -LiteralPath $appPath)) {
    Write-Fail ('Не найден ZapretControl.ps1: ' + $appPath)
    exit 1
}
$appPath = (Resolve-Path -LiteralPath $appPath).ProviderPath
$appDir = Split-Path -Parent $appPath
$configPath = Join-Path (Join-Path $appDir 'data') 'config.json'

$themeLabel = 'current'
if ($Theme) { $themeLabel = $Theme }

if (-not $OutFile) {
    $OutFile = Join-Path (Join-Path (Join-Path $PSScriptRoot '..') 'docs\ui-baseline') ('page' + $Page + '-' + $themeLabel + '.png')
}
if (-not [IO.Path]::IsPathRooted($OutFile)) {
    $OutFile = [IO.Path]::GetFullPath((Join-Path (Get-Location).ProviderPath $OutFile))
}
$outDirectory = Split-Path -Parent $OutFile
if ($outDirectory -and -not (Test-Path -LiteralPath $outDirectory)) {
    New-Item -ItemType Directory -Path $outDirectory -Force | Out-Null
}

$tempDir = Join-Path $env:TEMP 'zapret-gui-tools'
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
$stdoutLog = Join-Path $tempDir 'ui-capture.stdout.log'
$stderrLog = Join-Path $tempDir 'ui-capture.stderr.log'

Write-Info ('Приложение: ' + $appPath)
Write-Info ('Страница: ' + $Page + ' (' + $navNames[$Page] + '), тема: ' + $themeLabel)
Write-Info ('PNG: ' + $OutFile)

# ---------------------------------------------------------------------------
#  Win32 / UIAutomation
# ---------------------------------------------------------------------------
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

if (-not ('ZapretUiNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class ZapretUiNative {
    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll")]
    private static extern int GetWindowTextLength(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern IntPtr GetWindow(IntPtr hWnd, uint command);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);

    // Ищет окно процесса без опоры на Process.MainWindowHandle (он видит только видимые окна).
    // Сначала предпочитает видимое окно с заголовком, иначе возвращает скрытое.
    public static IntPtr FindTopLevelWindow(int processId) {
        IntPtr visible = IntPtr.Zero;
        IntPtr hidden = IntPtr.Zero;
        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam) {
            uint windowProcessId;
            GetWindowThreadProcessId(hWnd, out windowProcessId);
            if (windowProcessId != (uint)processId) { return true; }
            if (GetWindow(hWnd, 4) != IntPtr.Zero) { return true; }   // GW_OWNER
            if (GetWindowTextLength(hWnd) == 0) { return true; }
            if (IsWindowVisible(hWnd)) {
                visible = hWnd;
                return false;
            }
            if (hidden == IntPtr.Zero) { hidden = hWnd; }
            return true;
        }, IntPtr.Zero);
        if (visible != IntPtr.Zero) { return visible; }
        return hidden;
    }
}
'@
}

# Процесс заранее делаем DPI-aware, чтобы координаты UIA и CopyFromScreen совпадали.
try { [void][ZapretUiNative]::SetProcessDPIAware() } catch { }

$AE = [System.Windows.Automation.AutomationElement]
$CT = [System.Windows.Automation.ControlType]
$TS = [System.Windows.Automation.TreeScope]

function Find-Element($Root, $ControlType, [string]$Name) {
    $condition = New-Object System.Windows.Automation.AndCondition(
        (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $ControlType)),
        (New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, $Name))
    )
    return $Root.FindFirst($TS::Descendants, $condition)
}

function Wait-Element($Root, $ControlType, [string]$Name, [int]$TimeoutMs = 5000) {
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    do {
        $element = Find-Element $Root $ControlType $Name
        if ($element) { return $element }
        Start-Sleep -Milliseconds 150
    } while ((Get-Date) -lt $deadline)
    return $null
}

function Wait-Radio($Root, [string]$Name, [int]$TimeoutMs = 5000) {
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    do {
        $radio = Find-Element $Root $CT::RadioButton $Name
        if ($radio) { return $radio }
        # Запасной путь: сравнение без учёта регистра и лишних пробелов.
        $condition = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::RadioButton)
        $items = $Root.FindAll($TS::Descendants, $condition)
        foreach ($item in $items) {
            $current = $item.Current.Name
            if ($current -and $current.Trim() -eq $Name) { return $item }
        }
        Start-Sleep -Milliseconds 150
    } while ((Get-Date) -lt $deadline)
    return $null
}

function Select-Radio($Root, [string]$Name, [int]$TimeoutMs = 5000) {
    $radio = Wait-Radio $Root $Name $TimeoutMs
    if (-not $radio) { return $false }
    $pattern = $radio.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
    $pattern.Select()
    Start-Sleep -Milliseconds 700
    return $true
}

function Copy-WindowBitmap([IntPtr]$WindowHandle) {
    $root = $AE::FromHandle($WindowHandle)
    if (-not $root) { throw 'Не удалось получить AutomationElement окна.' }
    $rect = $root.Current.BoundingRectangle
    $width = [int][Math]::Round($rect.Width)
    $height = [int][Math]::Round($rect.Height)
    if ($width -le 0 -or $height -le 0) { throw 'Пустой прямоугольник окна.' }

    $bitmap = New-Object System.Drawing.Bitmap($width, $height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen([int]$rect.X, [int]$rect.Y, 0, 0, (New-Object System.Drawing.Size($width, $height)))
    } finally {
        $graphics.Dispose()
    }
    return $bitmap
}

function Test-BitmapHasContent($Bitmap) {
    # Быстрая проверка, что снимок не залит одним цветом (окно успело отрисоваться).
    $first = $Bitmap.GetPixel(0, 0).ToArgb()
    $stepX = [Math]::Max(1, [int]($Bitmap.Width / 24))
    $stepY = [Math]::Max(1, [int]($Bitmap.Height / 24))
    for ($x = 0; $x -lt $Bitmap.Width; $x += $stepX) {
        for ($y = 0; $y -lt $Bitmap.Height; $y += $stepY) {
            if ($Bitmap.GetPixel($x, $y).ToArgb() -ne $first) { return $true }
        }
    }
    return $false
}

# ---------------------------------------------------------------------------
#  Запуск приложения
# ---------------------------------------------------------------------------
$configExisted = Test-Path -LiteralPath $configPath
$configBytes = $null
if ($configExisted) { $configBytes = [IO.File]::ReadAllBytes($configPath) }

$proc = $null
$stdoutTask = $null
$stderrTask = $null
$savedPath = ''
$windowHandle = [IntPtr]::Zero

Write-Info 'Запуск приложения...'
try {
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $startInfo.Arguments = '-NoProfile -ExecutionPolicy Bypass -Sta -File "' + $appPath + '" -Preview -PreviewSeconds ' + $Seconds
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden

    $proc = [System.Diagnostics.Process]::Start($startInfo)
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()

    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        $proc.Refresh()
        if ($proc.HasExited) { break }
        if ($proc.MainWindowHandle -ne [IntPtr]::Zero) {
            $windowHandle = $proc.MainWindowHandle
            break
        }
        Start-Sleep -Milliseconds 250
    }
    if ($windowHandle -eq [IntPtr]::Zero) {
        throw 'Главное окно приложения не появилось за 15 с.'
    }
    Write-Info ('Окно найдено: handle ' + $windowHandle)

    [void][ZapretUiNative]::ShowWindow($windowHandle, 9)   # SW_RESTORE
    [void][ZapretUiNative]::SetForegroundWindow($windowHandle)
    Start-Sleep -Milliseconds 1500
    $proc.Refresh()
    if ($proc.HasExited) { throw 'Процесс завершился после показа окна.' }

    $root = $AE::FromHandle($windowHandle)
    if (-not $root) { throw 'UI Automation не видит окно приложения.' }

    if ($Theme) {
        if (-not (Select-Radio $root $navNames[1])) { throw 'Не удалось открыть страницу «Настройки».' }
        if (-not (Select-Radio $root $themeNames[$Theme])) { throw ('Не удалось выбрать тему «' + $themeNames[$Theme] + '».') }
        $proc.Refresh()
        if ($proc.HasExited) { throw 'Процесс завершился после смены темы.' }
        Write-Info ('Тема применена: ' + $Theme)
    }

    if (-not (Select-Radio $root $navNames[$Page])) {
        throw ('Не удалось выбрать страницу «' + $navNames[$Page] + '».')
    }
    Start-Sleep -Milliseconds 900
    $proc.Refresh()
    if ($proc.HasExited) { throw 'Процесс завершился после смены страницы.' }

    if ($LogExpanded) {
        $logButton = Wait-Element $root $CT::Button 'Развернуть' 3000
        if ($logButton) {
            $invoke = $logButton.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
            $invoke.Invoke()
            Start-Sleep -Milliseconds 1000
            Write-Info 'Журнал развёрнут.'
        } else {
            Write-Info 'Кнопка «Развернуть» не найдена — журнал уже развёрнут или скрыт.'
        }
        $proc.Refresh()
        if ($proc.HasExited) { throw 'Процесс завершился после действий с журналом.' }
    }

    # --- Ожидание отрисовки и снимок --------------------------------------
    [void][ZapretUiNative]::SetForegroundWindow($windowHandle)
    Start-Sleep -Milliseconds 1500

    $bitmap = Copy-WindowBitmap $windowHandle
    try {
        $hasContent = Test-BitmapHasContent $bitmap
        if (-not $hasContent) { Write-Info 'Снимок выглядит однотонным, повтор после паузы.' }
    } finally {
        $bitmap.Dispose()
    }

    Start-Sleep -Milliseconds 300
    [void][ZapretUiNative]::SetForegroundWindow($windowHandle)

    $bitmap = Copy-WindowBitmap $windowHandle
    try {
        if (-not (Test-BitmapHasContent $bitmap)) {
            Start-Sleep -Milliseconds 600
            Write-Info 'Повторный снимок всё ещё однотонный — сохраняю как есть.'
        }
        $bitmap.Save($OutFile, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $bitmap.Dispose()
    }

    $proc.Refresh()
    if ($proc.HasExited) { throw 'Процесс завершился до сохранения снимка.' }

    if (-not (Test-Path -LiteralPath $OutFile)) { throw 'PNG не создан.' }
    $fileLength = (Get-Item -LiteralPath $OutFile).Length
    if ($fileLength -le 0) { throw 'PNG пустой.' }
    $savedPath = $OutFile
    Write-Host ('[' + $toolName + '] PASS: сохранено ' + $savedPath + ' (' + $fileLength + ' байт).') -ForegroundColor Green
} catch {
    Write-Fail ('FAIL: ' + $_.Exception.Message)
} finally {
    if ($proc) {
        if (-not $proc.HasExited) {
            try { $proc.Kill() } catch { }
            try { [void]$proc.WaitForExit(5000) } catch { }
        }
    }

    $stdoutText = ''
    $stderrText = ''
    try {
        if ($stdoutTask) { [void]$stdoutTask.Wait(3000); if ($stdoutTask.IsCompleted) { $stdoutText = $stdoutTask.Result } }
        if ($stderrTask) { [void]$stderrTask.Wait(3000); if ($stderrTask.IsCompleted) { $stderrText = $stderrTask.Result } }
    } catch { }
    try {
        [IO.File]::WriteAllText($stdoutLog, [string]$stdoutText, (New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText($stderrLog, [string]$stderrText, (New-Object Text.UTF8Encoding($false)))
    } catch { }

    try {
        if ($configExisted) {
            if ($null -ne $configBytes) { [IO.File]::WriteAllBytes($configPath, $configBytes) }
        } elseif (Test-Path -LiteralPath $configPath) {
            Remove-Item -LiteralPath $configPath -Force
        }
    } catch {
        Write-Fail ('Не удалось восстановить config.json: ' + $_.Exception.Message)
        $savedPath = ''
    }

    if ($savedPath) {
        foreach ($logFile in @($stdoutLog, $stderrLog)) {
            if (Test-Path -LiteralPath $logFile) { Remove-Item -LiteralPath $logFile -Force -ErrorAction SilentlyContinue }
        }
    } else {
        Write-Info ('Stdout приложения: ' + $stdoutLog)
        Write-Info ('Stderr приложения: ' + $stderrLog)
        if ($stderrText) {
            $tail = ($stderrText -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 5) -join [Environment]::NewLine
            if ($tail) { Write-Fail ('Stderr (хвост):' + [Environment]::NewLine + $tail) }
        }
    }
}

if (-not $savedPath) { exit 1 }
Write-Output $savedPath
exit 0
