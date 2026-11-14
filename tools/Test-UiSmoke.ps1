#Requires -Version 5.1
<#
.SYNOPSIS
    Дымовой тест интерфейса Zapret Control через UI Automation.

.DESCRIPTION
    Запускает ZapretControl.ps1 в режиме -Preview (без прав администратора),
    дожидается окна, показывает его, выбирает страницу навигации и тему,
    разворачивает журнал и после каждого шага проверяет, что процесс жив.
    При заданном -ScreenshotDir сохраняет PNG текущей страницы.
    data\config.json восстанавливается байт-в-байт, процесс убивается в finally.

.PARAMETER Page
    Страница навигации: 0 = Обзор, 1 = Настройки, 2 = Инструменты, 3 = Тесты, 4 = Обновление.

.PARAMETER Theme
    Тема оформления: light, dark, neon. Если не задана — тема из config.json не меняется.

.PARAMETER Seconds
    Через сколько секунд приложение закроется само (-PreviewSeconds). Должно быть
    заметно больше времени выполнения шагов (по умолчанию 30).

.PARAMETER ScreenshotDir
    Каталог для PNG-снимка окна. Если не задан, снимок не делается.

.PARAMETER StaChild
    Служебный переключатель: признак перезапуска в STA-потоке. Не указывайте вручную.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Sta -File .\tools\Test-UiSmoke.ps1

.EXAMPLE
    .\tools\Test-UiSmoke.ps1 -Page 1 -Theme neon -Seconds 40 -ScreenshotDir .\artifacts\ui
#>
[CmdletBinding()]
param(
    [ValidateRange(0, 4)][int]$Page = 0,
    [string]$Theme = '',
    [ValidateRange(5, 600)][int]$Seconds = 30,
    [string]$ScreenshotDir = '',
    [switch]$StaChild
)

$ErrorActionPreference = 'Stop'
$toolName = 'Test-UiSmoke'

$script:Failures = New-Object System.Collections.Generic.List[string]

function Write-Info([string]$Text) { Write-Host ('[' + $toolName + '] ' + $Text) }
function Write-Fail([string]$Text) { Write-Host ('[' + $toolName + '] ' + $Text) -ForegroundColor Red }

function Write-Step([string]$Name, [bool]$Ok, [string]$Detail = '') {
    $suffix = ''
    if ($Detail) { $suffix = ' — ' + $Detail }
    if ($Ok) {
        Write-Host ('[' + $toolName + ']   PASS  ' + $Name + $suffix) -ForegroundColor Green
    } else {
        Write-Host ('[' + $toolName + ']   FAIL  ' + $Name + $suffix) -ForegroundColor Red
        $script:Failures.Add($Name)
    }
    return $Ok
}

# ---------------------------------------------------------------------------
#  Проверка параметров
# ---------------------------------------------------------------------------
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
    if ($ScreenshotDir) { $relaunch += @('-ScreenshotDir', $ScreenshotDir) }
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

if ($ScreenshotDir) {
    if (-not [IO.Path]::IsPathRooted($ScreenshotDir)) {
        $ScreenshotDir = [IO.Path]::GetFullPath((Join-Path (Get-Location).ProviderPath $ScreenshotDir))
    }
}

$tempDir = Join-Path $env:TEMP 'zapret-gui-tools'
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
$stdoutLog = Join-Path $tempDir 'ui-smoke.stdout.log'
$stderrLog = Join-Path $tempDir 'ui-smoke.stderr.log'

Write-Info ('Приложение: ' + $appPath)
Write-Info ('Страница: ' + $Page + ' (' + $navNames[$Page] + ')')
if ($Theme) { Write-Info ('Тема: ' + $Theme) } else { Write-Info 'Тема: не менять' }
Write-Info ('Лимит жизни процесса: ' + $Seconds + ' с')

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

function Get-RadioNames($Root) {
    $condition = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::RadioButton)
    $items = $Root.FindAll($TS::Descendants, $condition)
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($item in $items) {
        if ($item.Current.Name) { $names.Add($item.Current.Name) }
    }
    return ($names -join ', ')
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
    if (-not $radio) {
        Write-Info ('  Радиокнопка "' + $Name + '" не найдена. Доступны: ' + (Get-RadioNames $Root))
        return $false
    }
    $pattern = $radio.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
    $pattern.Select()
    Start-Sleep -Milliseconds 700
    return $true
}

function Save-WindowPng([IntPtr]$WindowHandle, [string]$OutPath) {
    $root = $AE::FromHandle($WindowHandle)
    if (-not $root) { throw 'Не удалось получить AutomationElement окна.' }
    $rect = $root.Current.BoundingRectangle
    $width = [int][Math]::Round($rect.Width)
    $height = [int][Math]::Round($rect.Height)
    if ($width -le 0 -or $height -le 0) { throw 'Пустой прямоугольник окна.' }

    $directory = Split-Path -Parent $OutPath
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $bitmap = New-Object System.Drawing.Bitmap($width, $height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen([int]$rect.X, [int]$rect.Y, 0, 0, (New-Object System.Drawing.Size($width, $height)))
    } finally {
        $graphics.Dispose()
    }
    try {
        $bitmap.Save($OutPath, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $bitmap.Dispose()
    }
    return $OutPath
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
$exitCode = 1
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

    # --- Шаг: окно ---------------------------------------------------------
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        $proc.Refresh()
        if ($proc.HasExited) { break }
        if ($proc.MainWindowHandle -ne [IntPtr]::Zero) {
            $windowHandle = $proc.MainWindowHandle
            break
        }
        $fallback = [ZapretUiNative]::FindTopLevelWindow($proc.Id)
        if ($fallback -ne [IntPtr]::Zero) {
            $windowHandle = $fallback
            break
        }
        Start-Sleep -Milliseconds 250
    }
    [void](Write-Step 'Ожидание окна (до 15 с)' ($windowHandle -ne [IntPtr]::Zero) $(if ($windowHandle -ne [IntPtr]::Zero) { 'handle ' + $windowHandle } else { 'окно не появилось' }))
    if ($windowHandle -eq [IntPtr]::Zero) {
        throw 'Главное окно приложения не появилось.'
    }

    # --- Шаг: показ окна ---------------------------------------------------
    [void][ZapretUiNative]::ShowWindow($windowHandle, 9)   # SW_RESTORE
    [void][ZapretUiNative]::SetForegroundWindow($windowHandle)
    Start-Sleep -Milliseconds 1500
    $proc.Refresh()
    [void](Write-Step 'Показ окна на переднем плане' (-not $proc.HasExited))
    if ($proc.HasExited) { throw 'Процесс завершился после показа окна.' }

    $root = $AE::FromHandle($windowHandle)
    if (-not $root) { throw 'UI Automation не видит окно приложения.' }

    # --- Шаги: тема (только на странице «Настройки») -----------------------
    if ($Theme) {
        [void](Write-Step 'Переход на страницу «Настройки» для смены темы' (Select-Radio $root $navNames[1]))
        if (-not (Wait-Element $root $CT::RadioButton $navNames[1] 2000)) { throw 'Страница настроек недоступна.' }
        $proc.Refresh()
        [void](Write-Step ('Выбор темы «' + $themeNames[$Theme] + '»') (Select-Radio $root $themeNames[$Theme]))
        $proc.Refresh()
        [void](Write-Step 'Процесс жив после смены темы' (-not $proc.HasExited))
        if ($proc.HasExited) { throw 'Процесс завершился после смены темы.' }
    }

    # --- Шаг: страница -----------------------------------------------------
    [void](Write-Step ('Выбор страницы «' + $navNames[$Page] + '»') (Select-Radio $root $navNames[$Page]))
    Start-Sleep -Milliseconds 900
    $proc.Refresh()
    [void](Write-Step 'Процесс жив после смены страницы' (-not $proc.HasExited))
    if ($proc.HasExited) { throw 'Процесс завершился после смены страницы.' }

    # --- Шаг: журнал -------------------------------------------------------
    $logButton = Wait-Element $root $CT::Button 'Развернуть' 3000
    if ($logButton) {
        $invoke = $logButton.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
        $invoke.Invoke()
        Start-Sleep -Milliseconds 900
        $expanded = $true
    } elseif (Wait-Element $root $CT::Button 'Свернуть' 1000) {
        Write-Info '  Журнал уже развёрнут — шаг пропущен.'
        $expanded = $true
    } else {
        $expanded = $false
    }
    [void](Write-Step 'Разворачивание журнала' $expanded)
    $proc.Refresh()
    [void](Write-Step 'Процесс жив после действий с журналом' (-not $proc.HasExited))
    if ($proc.HasExited) { throw 'Процесс завершился после действий с журналом.' }

    # --- Шаг: скриншот -----------------------------------------------------
    if ($ScreenshotDir) {
        $themeLabel = 'current'
        if ($Theme) { $themeLabel = $Theme }
        $outPath = Join-Path $ScreenshotDir ('smoke-page' + $Page + '-' + $themeLabel + '.png')
        [void][ZapretUiNative]::SetForegroundWindow($windowHandle)
        Start-Sleep -Milliseconds 500
        $saved = Save-WindowPng $windowHandle $outPath
        [void](Write-Step 'Скриншот страницы' (Test-Path -LiteralPath $saved) $saved)
    }

    [void](Write-Step 'Процесс жив после всех шагов' (-not $proc.HasExited))
    if ($script:Failures.Count -eq 0) { $exitCode = 0 }
} catch {
    Write-Fail ('Исключение: ' + $_.Exception.Message)
    $exitCode = 1
} finally {
    if ($proc) {
        if (-not $proc.HasExited) {
            try { $proc.Kill() } catch { }
            try { [void]$proc.WaitForExit(5000) } catch { }
        }
    }

    # --- Логи процесса -----------------------------------------------------
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

    # --- Восстановление config.json байт-в-байт ---------------------------
    try {
        if ($configExisted) {
            if ($null -ne $configBytes) { [IO.File]::WriteAllBytes($configPath, $configBytes) }
        } elseif (Test-Path -LiteralPath $configPath) {
            Remove-Item -LiteralPath $configPath -Force
        }
    } catch {
        Write-Fail ('Не удалось восстановить config.json: ' + $_.Exception.Message)
        $exitCode = 1
    }

    if ($exitCode -eq 0) {
        # Успешный прогон не оставляет диагностических файлов.
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

if ($script:Failures.Count -gt 0) {
    Write-Fail ('Провалено шагов: ' + $script:Failures.Count + ' — ' + ($script:Failures -join '; '))
    exit 1
}
Write-Host ('[' + $toolName + '] PASS: дымовой тест интерфейса пройден.') -ForegroundColor Green
exit 0
