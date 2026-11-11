#Requires -Version 5.1
<#
    Zapret Control - графический управлятор zapret-discord-youtube
    GUI / форк: Bugulmek
    Пакет zapret и источник обновлений: Flowseal
    https://github.com/Flowseal/zapret-discord-youtube

    Запускать через ZapretControl.bat (сам запросит права администратора).
#>

param([switch]$SelfTest, [switch]$Preview)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$script:AppDir = $PSScriptRoot
. (Join-Path $PSScriptRoot 'ZapretCommon.ps1')

$script:DataDir = Join-Path $PSScriptRoot 'data'
if (-not (Test-Path -LiteralPath $script:DataDir)) {
    New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null
}
$script:ConfigPath = Join-Path $script:DataDir 'config.json'
$script:WinwsLogPath = Join-Path $script:DataDir 'winws.log'
$script:RunBatPath = Join-Path $script:DataDir 'run-current.bat'
$script:LogReadPos = 0

# ---------------------------------------------------------------------------
#  Конфигурация
# ---------------------------------------------------------------------------
$script:Config = [pscustomobject]@{
    ZapretRoot          = ''
    SelectedStrategy    = ''
    LastStartedStrategy = ''
    CheckUpdatesOnStart = $true
}

if (Test-Path -LiteralPath $script:ConfigPath) {
    try {
        $loaded = Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($loaded.ZapretRoot) { $script:Config.ZapretRoot = [string]$loaded.ZapretRoot }
        if ($loaded.SelectedStrategy) { $script:Config.SelectedStrategy = [string]$loaded.SelectedStrategy }
        if ($loaded.LastStartedStrategy) { $script:Config.LastStartedStrategy = [string]$loaded.LastStartedStrategy }
        if ($null -ne $loaded.CheckUpdatesOnStart) { $script:Config.CheckUpdatesOnStart = [bool]$loaded.CheckUpdatesOnStart }
    } catch { }
}

function Save-Config {
    try {
        $json = $script:Config | ConvertTo-Json -Depth 5
        [IO.File]::WriteAllText($script:ConfigPath, $json, (New-Object Text.UTF8Encoding($true)))
    } catch { }
}

# ---------------------------------------------------------------------------
#  Самопроверка без запуска интерфейса (для отладки)
# ---------------------------------------------------------------------------
if ($SelfTest) {
    $root = Resolve-ZapretRoot -Hint $script:Config.ZapretRoot -AppDir $PSScriptRoot
    if (-not $root) { Write-Output 'ROOT: NOT FOUND'; exit 1 }
    Write-Output ('ROOT: ' + $root)
    Write-Output ('VERSION: ' + (Get-LocalZapretVersion -Root $root))
    Write-Output ('IPSET: ' + (Get-IpsetState -Root $root))
    Write-Output ('GAMEFILTER: ' + ((Get-GameFilterState -Root $root) | ConvertTo-Json -Compress))
    $strategies = @(Get-Strategies -Root $root)
    Write-Output ('STRATEGIES: ' + $strategies.Count)
    foreach ($strategy in $strategies) {
        $argLine = Get-WinwsArgs -BatPath $strategy.FullName -Root $root
        if ($argLine) { $len = $argLine.Length } else { $len = 'NULL' }
        Write-Output ('  ' + $strategy.Name + ' | args=' + $len)
    }
    exit 0
}

# ---------------------------------------------------------------------------
#  Права администратора (перезапуск с UAC)
# ---------------------------------------------------------------------------
if (-not $Preview -and -not (Test-IsAdmin)) {
    try {
        Start-Process -FilePath 'powershell.exe' `
            -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File "' + $PSCommandPath + '"') `
            -Verb RunAs -ErrorAction Stop | Out-Null
    } catch {
        [void][Windows.Forms.MessageBox]::Show(
            "Для работы Zapret Control нужны права администратора.`n`nЗапуск отменён.",
            'Zapret Control', 'OK', 'Warning')
    }
    exit
}

$script:IsAdmin = Test-IsAdmin

# ---------------------------------------------------------------------------
#  Папка zapret
# ---------------------------------------------------------------------------
$script:ZapretRoot = Resolve-ZapretRoot -Hint $script:Config.ZapretRoot -AppDir $PSScriptRoot

if (-not $script:ZapretRoot) {
    $dialog = New-Object Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Укажите папку, в которой находится zapret (там должны быть service.bat и bin\winws.exe)'
    $dialog.ShowNewFolderButton = $false
    if ($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) {
        $foundRoots = @(Get-ZapretCandidates -BaseDir $dialog.SelectedPath)
        if ($foundRoots.Count -gt 0) {
            $script:ZapretRoot = $foundRoots[0]
        }
    }
}

if (-not $script:ZapretRoot) {
    [void][Windows.Forms.MessageBox]::Show(
        "Не удалось найти папку zapret.`n`nПоложите папку GUI рядом с папкой zapret-discord-youtube-* `nили запустите программу и укажите папку вручную.",
        'Zapret Control', 'OK', 'Error')
    exit 1
}

$script:ZapretRoot = (Resolve-Path -LiteralPath $script:ZapretRoot).Path
if ($script:Config.ZapretRoot -ne $script:ZapretRoot) {
    $script:Config.ZapretRoot = $script:ZapretRoot
    Save-Config
}

# ---------------------------------------------------------------------------
#  Внешний вид
# ---------------------------------------------------------------------------
$script:Form           = $null
$script:StatusLabels   = @{}
$script:LstStrategies  = $null
$script:RtbLog         = $null
$script:StatusLabel    = $null
$script:LatestRelease  = $null
$script:UpdateAvailable = $false
$script:SyncingUi      = $false
$script:SyncInputs     = $false
$script:StrategyFiles  = @()

$script:FontUi      = New-Object Drawing.Font('Segoe UI', 9)
$script:FontUiBold  = New-Object Drawing.Font('Segoe UI', 9, [Drawing.FontStyle]::Bold)
$script:FontSmall   = New-Object Drawing.Font('Segoe UI', 8)
$script:FontTitle   = New-Object Drawing.Font('Segoe UI', 15, [Drawing.FontStyle]::Bold)
$script:FontHeader  = New-Object Drawing.Font('Segoe UI', 10, [Drawing.FontStyle]::Bold)
$script:FontMono    = New-Object Drawing.Font('Consolas', 9)

$script:ClrBg       = [Drawing.ColorTranslator]::FromHtml('#F3F5F9')
$script:ClrCard     = [Drawing.Color]::White
$script:ClrText     = [Drawing.ColorTranslator]::FromHtml('#1F2937')
$script:ClrMuted    = [Drawing.ColorTranslator]::FromHtml('#6B7280')
$script:ClrGreen    = [Drawing.ColorTranslator]::FromHtml('#15803D')
$script:ClrRed      = [Drawing.ColorTranslator]::FromHtml('#B91C1C')
$script:ClrOrange   = [Drawing.ColorTranslator]::FromHtml('#B45309')
$script:ClrAccent   = [Drawing.ColorTranslator]::FromHtml('#2563EB')
$script:ClrAccentDk = [Drawing.ColorTranslator]::FromHtml('#1D4ED8')
$script:ClrLogBg    = [Drawing.ColorTranslator]::FromHtml('#0F172A')
$script:ClrLogText  = [Drawing.ColorTranslator]::FromHtml('#E5E7EB')
$script:ClrBorder   = [Drawing.ColorTranslator]::FromHtml('#D1D5DB')

function New-StyledButton {
    param(
        [string]$Text,
        [int]$Width = 150,
        [int]$Height = 34,
        [string]$Kind = 'secondary'
    )

    $button = New-Object Windows.Forms.Button
    $button.Text = $Text
    $button.Size = New-Object Drawing.Size($Width, $Height)
    $button.FlatStyle = 'Flat'
    $button.Font = $script:FontUiBold
    $button.Cursor = [Windows.Forms.Cursors]::Hand
    $button.UseVisualStyleBackColor = $false

    switch ($Kind) {
        'primary' {
            $button.BackColor = $script:ClrAccent
            $button.ForeColor = [Drawing.Color]::White
            $button.FlatAppearance.BorderSize = 0
            $button.FlatAppearance.MouseOverBackColor = $script:ClrAccentDk
        }
        'danger' {
            $button.BackColor = [Drawing.ColorTranslator]::FromHtml('#DC2626')
            $button.ForeColor = [Drawing.Color]::White
            $button.FlatAppearance.BorderSize = 0
            $button.FlatAppearance.MouseOverBackColor = [Drawing.ColorTranslator]::FromHtml('#B91C1C')
        }
        'success' {
            $button.BackColor = [Drawing.ColorTranslator]::FromHtml('#16A34A')
            $button.ForeColor = [Drawing.Color]::White
            $button.FlatAppearance.BorderSize = 0
            $button.FlatAppearance.MouseOverBackColor = [Drawing.ColorTranslator]::FromHtml('#15803D')
        }
        default {
            $button.BackColor = $script:ClrCard
            $button.ForeColor = $script:ClrText
            $button.FlatAppearance.BorderSize = 1
            $button.FlatAppearance.BorderColor = $script:ClrBorder
            $button.FlatAppearance.MouseOverBackColor = [Drawing.ColorTranslator]::FromHtml('#E5E7EB')
        }
    }
    return $button
}

function New-UiLabel {
    param(
        [string]$Text,
        [int]$X = 0,
        [int]$Y = 0,
        [int]$Width = 200,
        [int]$Height = 20,
        [object]$Font = $null,
        [object]$Color = $null
    )
    $label = New-Object Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object Drawing.Point($X, $Y)
    $label.Size = New-Object Drawing.Size($Width, $Height)
    if ($Font) { $label.Font = $Font } else { $label.Font = $script:FontUi }
    if ($Color) { $label.ForeColor = $Color } else { $label.ForeColor = $script:ClrText }
    $label.BackColor = [Drawing.Color]::Transparent
    return $label
}

function New-RowStyle {
    param([string]$Type, [int]$Value = 0)
    $style = New-Object Windows.Forms.RowStyle
    $style.SizeType = $Type
    if ($Value -gt 0) { $style.Height = $Value }
    return $style
}

function New-ColumnStyle {
    param([string]$Type, [int]$Value = 0)
    $style = New-Object Windows.Forms.ColumnStyle
    $style.SizeType = $Type
    if ($Value -gt 0) { $style.Width = $Value }
    return $style
}

# ---------------------------------------------------------------------------
#  Журнал / диалоги / статус
# ---------------------------------------------------------------------------
function Write-UiLog {
    param([string]$Text, [string]$Color = 'Text')

    if (-not $script:RtbLog) { return }

    $colorMap = @{
        'Text'   = $script:ClrLogText
        'Gray'   = [Drawing.ColorTranslator]::FromHtml('#94A3B8')
        'Green'  = [Drawing.ColorTranslator]::FromHtml('#4ADE80')
        'Red'    = [Drawing.ColorTranslator]::FromHtml('#F87171')
        'Yellow' = [Drawing.ColorTranslator]::FromHtml('#FACC15')
        'Cyan'   = [Drawing.ColorTranslator]::FromHtml('#67E8F9')
        'Blue'   = [Drawing.ColorTranslator]::FromHtml('#93C5FD')
    }
    $drawColor = $colorMap[$Color]
    if (-not $drawColor) { $drawColor = $script:ClrLogText }

    if ($script:RtbLog.TextLength -gt 250000) { $script:RtbLog.Clear() }

    $line = '[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $Text + "`r`n"
    $script:RtbLog.SelectionStart = $script:RtbLog.TextLength
    $script:RtbLog.SelectionLength = 0
    $script:RtbLog.SelectionColor = $drawColor
    $script:RtbLog.AppendText($line)
    if ($script:ChkAutoScroll -and $script:ChkAutoScroll.Checked) {
        $script:RtbLog.ScrollToCaret()
    }
}

function Set-BusyStatus {
    param([string]$Text)
    if ($script:StatusLabel) {
        $script:StatusLabel.Text = $Text
        [Windows.Forms.Application]::DoEvents()
    }
}

function Show-UiInfo {
    param([string]$Text, [string]$Title = 'Zapret Control')
    if ($script:Form) {
        [void][Windows.Forms.MessageBox]::Show($script:Form, $Text, $Title,
            [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Information)
    } else {
        [void][Windows.Forms.MessageBox]::Show($Text, $Title,
            [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Information)
    }
}

function Show-UiError {
    param([string]$Text, [string]$Title = 'Ошибка')
    if ($script:Form) {
        [void][Windows.Forms.MessageBox]::Show($script:Form, $Text, $Title,
            [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Error)
    } else {
        [void][Windows.Forms.MessageBox]::Show($Text, $Title,
            [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Error)
    }
}

function Confirm-Ui {
    param([string]$Text, [string]$Title = 'Подтверждение')
    $result = [Windows.Forms.MessageBox]::Show($script:Form, $Text, $Title,
        [Windows.Forms.MessageBoxButtons]::YesNo, [Windows.Forms.MessageBoxIcon]::Question)
    return ($result -eq [Windows.Forms.DialogResult]::Yes)
}

function Set-StatusValue {
    param([string]$Key, [string]$Text, [object]$Color)
    $label = $script:StatusLabels[$Key]
    if ($label) {
        $label.Text = $Text
        if ($Color) { $label.ForeColor = $Color }
    }
}
# ---------------------------------------------------------------------------
#  Список стратегий и запуск
# ---------------------------------------------------------------------------
function Get-SelectedStrategyName {
    if ($script:LstStrategies -and $script:LstStrategies.SelectedItem) {
        return [string]$script:LstStrategies.SelectedItem
    }
    return $null
}

function Refresh-StrategyList {
    if (-not $script:LstStrategies) { return }

    $script:LstStrategies.BeginUpdate()
    try {
        $script:LstStrategies.Items.Clear()
        $script:StrategyFiles = @(Get-Strategies -Root $script:ZapretRoot)
        foreach ($strategy in $script:StrategyFiles) {
            [void]$script:LstStrategies.Items.Add($strategy.Name)
        }
    } finally {
        $script:LstStrategies.EndUpdate()
    }

    if ($script:StrategyFiles.Count -eq 0) {
        Write-UiLog 'В папке zapret не найдены файлы стратегий general*.bat' 'Red'
        return
    }

    $index = -1
    if ($script:Config.SelectedStrategy) {
        $index = $script:LstStrategies.Items.IndexOf($script:Config.SelectedStrategy)
    }
    if ($index -lt 0) {
        $serviceStrategy = Get-ServiceStrategy
        if ($serviceStrategy) { $index = $script:LstStrategies.Items.IndexOf($serviceStrategy) }
    }
    if ($index -lt 0) {
        $index = $script:LstStrategies.Items.IndexOf('general.bat')
    }
    if ($index -lt 0) { $index = 0 }
    $script:LstStrategies.SelectedIndex = $index
}

function Start-StrategyInternal {
    param([string]$Name, [switch]$NoConfirm)

    if (-not (Test-IsAdmin)) { Show-UiError 'Нужны права администратора.'; return $false }
    if (-not $Name) { Show-UiError 'Сначала выберите стратегию в списке.'; return $false }

    $batPath = Join-Path $script:ZapretRoot $Name
    if (-not (Test-Path -LiteralPath $batPath)) { Show-UiError ("Файл стратегии не найден:`n" + $batPath); return $false }

    $service = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
    if ($service -and $service.Status -eq 'Running') {
        if (-not $NoConfirm) {
            if (-not (Confirm-Ui "Служба zapret сейчас запущена.`n`nОстановить службу и запустить стратегию «$Name» вручную?" 'Запуск стратегии')) {
                return $false
            }
        }
        Stop-ZapretService | Out-Null
        Start-Sleep -Milliseconds 400
    }

    $argLine = Get-WinwsArgs -BatPath $batPath -Root $script:ZapretRoot
    if (-not $argLine) { Show-UiError ("Не удалось прочитать команду winws из:`n" + $batPath); return $false }

    Stop-ZapretProcesses | Out-Null
    Initialize-UserLists -Root $script:ZapretRoot
    Enable-TcpTimestamps

    $binDir = Join-Path $script:ZapretRoot 'bin'
    $exe = Join-Path $binDir 'winws.exe'

    $batchLines = @(
        '@echo off',
        ('cd /d "' + $binDir + '"'),
        ('"' + $exe + '" ' + $argLine + ' >> "' + $script:WinwsLogPath + '" 2>&1')
    )
    $batchText = ($batchLines -join "`r`n") + "`r`n"

    $oemEncoding = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
    [IO.File]::WriteAllText($script:RunBatPath, $batchText, $oemEncoding)
    Set-Content -LiteralPath $script:WinwsLogPath -Value '' -Encoding Ascii
    $script:LogReadPos = 0

    Write-UiLog ("Запуск стратегии: " + $Name) 'Cyan'
    Set-BusyStatus 'Запуск zapret...'

    Start-Process -FilePath $env:ComSpec -ArgumentList ('/c "' + $script:RunBatPath + '"') -WindowStyle Hidden | Out-Null
    Start-Sleep -Milliseconds 1600

    $processes = @(Get-WinwsProcesses)
    if ($processes.Count -gt 0) {
        $pids = ($processes | ForEach-Object { $_.Id }) -join ', '
        Write-UiLog ('winws.exe запущен (PID: ' + $pids + ')') 'Green'
        $script:Config.LastStartedStrategy = $Name
        Save-Config
        Set-BusyStatus 'zapret запущен'
        Update-AllStatus
        return $true
    }

    Write-UiLog 'winws.exe не запустился. Вывод winws:' 'Red'
    Start-Sleep -Milliseconds 400
    Read-WinwsLog
    Show-UiError ("winws.exe не запустился.`n`nПроверьте журнал внизу окна. Частые причины:`n• другая программа уже использует WinDivert;`n• антивирус блокирует WinDivert;`n• повреждены файлы в папке bin.")
    return $false
}

function Start-SelectedStrategyAction {
    $name = Get-SelectedStrategyName
    if (-not $name) { Show-UiError 'Сначала выберите стратегию в списке.'; return }
    try {
        Start-StrategyInternal -Name $name | Out-Null
    } catch {
        Write-UiLog ('Ошибка запуска: ' + $_.Exception.Message) 'Red'
        Show-UiError $_.Exception.Message
    }
    Update-AllStatus
}

function Stop-ZapretAction {
    try {
        $service = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
        if ($service) {
            Write-UiLog 'Остановка службы zapret...' 'Yellow'
            Stop-ZapretService | Out-Null
        }
        $killed = Stop-ZapretProcesses
        if ($killed -gt 0) {
            Write-UiLog ('Остановлено процессов winws.exe: ' + $killed) 'Green'
        } elseif (-not $service) {
            Write-UiLog 'zapret уже остановлен.' 'Gray'
        }
        Set-BusyStatus 'zapret остановлен'
    } catch {
        Write-UiLog ('Ошибка остановки: ' + $_.Exception.Message) 'Red'
    }
    Update-AllStatus
}

# ---------------------------------------------------------------------------
#  Служба Windows
# ---------------------------------------------------------------------------
function Install-ServiceInternal {
    param([string]$StrategyName, [switch]$NoConfirm)

    if (-not (Test-IsAdmin)) { Show-UiError 'Нужны права администратора.'; return $false }
    if (-not $StrategyName) { Show-UiError 'Выберите стратегию в списке.'; return $false }

    $batPath = Join-Path $script:ZapretRoot $StrategyName
    if (-not (Test-Path -LiteralPath $batPath)) { Show-UiError ("Стратегия не найдена:`n" + $batPath); return $false }

    if (-not $NoConfirm) {
        $text = "Установить службу Windows «zapret» со стратегией:`n$StrategyName`n`nСлужба будет запускаться автоматически при старте Windows."
        if (Get-Service -Name 'zapret' -ErrorAction SilentlyContinue) {
            $text += "`n`nТекущая служба будет переустановлена."
        }
        if (-not (Confirm-Ui $text 'Установка службы')) { return $false }
    }

    $argLine = Get-WinwsArgs -BatPath $batPath -Root $script:ZapretRoot
    if (-not $argLine) { Show-UiError ("Не удалось извлечь аргументы winws из " + $StrategyName); return $false }

    Write-UiLog ("Установка службы со стратегией: " + $StrategyName) 'Cyan'
    Set-BusyStatus 'Установка службы...'

    Stop-ZapretService | Out-Null
    Stop-ZapretProcesses | Out-Null
    Enable-TcpTimestamps

    & sc.exe delete zapret 2>$null | Out-Null
    for ($i = 0; $i -lt 24; $i++) {
        if ($null -eq (Get-Service -Name 'zapret' -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Milliseconds 250
    }

    $exe = Join-Path $script:ZapretRoot 'bin\winws.exe'
    $binaryPath = '"' + $exe + '" ' + $argLine

    $serviceCreated = $false
    try {
        New-Service -Name 'zapret' -BinaryPathName $binaryPath -DisplayName 'zapret' `
            -StartupType Automatic -ErrorAction Stop | Out-Null
        $serviceCreated = $true
    } catch {
        Write-UiLog ('New-Service не сработал, пробую sc.exe: ' + $_.Exception.Message) 'Yellow'
        $scArgs = 'create zapret binPath= "\"' + $exe + '\" ' + $argLine + '" DisplayName= "zapret" start= auto'
        $scProcess = Start-Process -FilePath 'sc.exe' -ArgumentList $scArgs -Wait -PassThru -WindowStyle Hidden
        if ($scProcess.ExitCode -eq 0) {
            $serviceCreated = $true
        } else {
            Write-UiLog ('Ошибка создания службы (sc.exe, код ' + $scProcess.ExitCode + ').') 'Red'
        }
    }

    if (-not $serviceCreated) {
        Show-UiError ("Не удалось создать службу «zapret».`n`nПроверьте права администратора и папку bin\winws.exe.")
        return $false
    }

    & sc.exe description zapret 'Zapret DPI bypass software' 2>$null | Out-Null
    New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\zapret' `
        -Name 'zapret-discord-youtube' -Value $StrategyName -PropertyType String -Force | Out-Null

    try {
        Start-Service -Name 'zapret' -ErrorAction Stop
    } catch {
        Write-UiLog ('Не удалось запустить службу: ' + $_.Exception.Message) 'Red'
    }
    Start-Sleep -Seconds 1

    $service = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
    if ($service -and $service.Status -eq 'Running') {
        Write-UiLog 'Служба установлена и запущена.' 'Green'
    } elseif ($service) {
        Write-UiLog ('Служба создана, состояние: ' + $service.Status) 'Yellow'
    }

    $winws = @(Get-WinwsProcesses)
    if ($winws.Count -eq 0) {
        Write-UiLog 'winws.exe не обнаружен после запуска службы. Запустите «Диагностика».' 'Yellow'
    } else {
        Write-UiLog ('winws.exe работает (PID: ' + (($winws | ForEach-Object { $_.Id }) -join ', ') + ')') 'Green'
    }

    $script:Config.SelectedStrategy = $StrategyName
    Save-Config
    Set-BusyStatus 'Служба установлена'
    Update-AllStatus
    return $true
}

function Install-ServiceAction {
    $name = Get-SelectedStrategyName
    if (-not $name) { Show-UiError 'Сначала выберите стратегию в списке.'; return }
    try {
        Install-ServiceInternal -StrategyName $name | Out-Null
    } catch {
        Write-UiLog ('Ошибка установки службы: ' + $_.Exception.Message) 'Red'
        Show-UiError $_.Exception.Message
    }
    Update-AllStatus
}

function Remove-ServiceInternal {
    param([switch]$NoConfirm)

    if (-not (Test-IsAdmin)) { Show-UiError 'Нужны права администратора.'; return $false }

    $service = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
    if (-not $service) {
        if (-not $NoConfirm) { Show-UiInfo 'Служба «zapret» не установлена.' }
        return $false
    }

    if (-not $NoConfirm) {
        if (-not (Confirm-Ui "Удалить службу «zapret» и остановить winws.exe?" 'Удаление службы')) { return $false }
    }

    Write-UiLog 'Удаление службы zapret...' 'Cyan'
    Set-BusyStatus 'Удаление службы...'
    Stop-ZapretService | Out-Null
    Stop-ZapretProcesses | Out-Null

    & sc.exe delete zapret 2>$null | Out-Null
    foreach ($driverService in @('WinDivert', 'WinDivert14')) {
        $driver = Get-Service -Name $driverService -ErrorAction SilentlyContinue
        if ($driver) {
            try { Stop-Service -Name $driverService -Force -ErrorAction SilentlyContinue } catch { }
            & sc.exe delete $driverService 2>$null | Out-Null
        }
    }

    Start-Sleep -Milliseconds 600
    if (Get-Service -Name 'zapret' -ErrorAction SilentlyContinue) {
        Write-UiLog 'Служба всё ещё числится в системе (возможно, помечена к удалению).' 'Yellow'
    } else {
        Write-UiLog 'Служба удалена.' 'Green'
    }
    Set-BusyStatus 'Служба удалена'
    Update-AllStatus
    return $true
}

function Remove-ServiceAction {
    try { Remove-ServiceInternal | Out-Null } catch {
        Write-UiLog ('Ошибка удаления службы: ' + $_.Exception.Message) 'Red'
        Show-UiError $_.Exception.Message
    }
    Update-AllStatus
}

function Restart-ServiceAction {
    $service = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
    if (-not $service) { Show-UiInfo 'Служба «zapret» не установлена.'; return }

    Set-BusyStatus 'Перезапуск службы...'
    try {
        Restart-Service -Name 'zapret' -Force -ErrorAction Stop
        Write-UiLog 'Служба перезапущена.' 'Green'
    } catch {
        Write-UiLog ('Ошибка перезапуска службы: ' + $_.Exception.Message) 'Red'
        Show-UiError $_.Exception.Message
    }
    Start-Sleep -Milliseconds 800
    Update-AllStatus
}

function Set-AutostartAction {
    if ($script:SyncingUi) { return }
    if (-not (Test-IsAdmin)) {
        Show-UiError 'Нужны права администратора.'
        Update-AllStatus
        return
    }

    $service = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
    if (-not $service) { Update-AllStatus; return }

    if ($script:ChkAutostart.Checked) { $startMode = 'auto' } else { $startMode = 'demand' }
    & sc.exe config zapret 'start=' $startMode 2>$null | Out-Null

    if ($script:ChkAutostart.Checked) {
        Write-UiLog 'Автозапуск службы включён.' 'Green'
    } else {
        Write-UiLog 'Автозапуск службы выключен.' 'Yellow'
    }
    Update-AllStatus
}
# ---------------------------------------------------------------------------
#  Обновление статуса
# ---------------------------------------------------------------------------
function Update-AllStatus {
    if (-not $script:StatusLabels -or $script:StatusLabels.Count -eq 0) { return }

    # Служба
    $service = Get-ServiceInfo -Name 'zapret'
    if (-not $service.Installed) {
        Set-StatusValue 'Service' 'не установлена' $script:ClrMuted
    } elseif ($service.Status -eq 'Running') {
        Set-StatusValue 'Service' 'работает' $script:ClrGreen
    } else {
        Set-StatusValue 'Service' ('остановлена' + $(if ($service.Status -ne 'Stopped') { " ($($service.Status))" } else { '' })) $script:ClrOrange
    }

    # Процесс winws
    $winws = @(Get-WinwsProcesses)
    if ($winws.Count -gt 0) {
        Set-StatusValue 'Winws' ('работает · PID ' + (($winws | ForEach-Object { $_.Id }) -join ', ')) $script:ClrGreen
    } else {
        Set-StatusValue 'Winws' 'не запущен' $script:ClrMuted
    }

    # Стратегия службы
    $serviceStrategy = Get-ServiceStrategy
    if ($serviceStrategy) {
        Set-StatusValue 'Strategy' $serviceStrategy $script:ClrText
    } else {
        Set-StatusValue 'Strategy' '—' $script:ClrMuted
    }

    # Права
    if (Test-IsAdmin) {
        Set-StatusValue 'Admin' 'администратор' $script:ClrGreen
    } else {
        Set-StatusValue 'Admin' 'нет прав' $script:ClrRed
    }

    # IPSet
    $ipset = Get-IpsetState -Root $script:ZapretRoot
    switch ($ipset) {
        'loaded' { Set-StatusValue 'Ipset' 'загружен (loaded)' $script:ClrGreen }
        'none'   { Set-StatusValue 'Ipset' 'отключён (none)' $script:ClrOrange }
        default  { Set-StatusValue 'Ipset' 'любой (any)' $script:ClrMuted }
    }

    # Игровой фильтр
    $gameFilter = Get-GameFilterState -Root $script:ZapretRoot
    switch ($gameFilter.Mode) {
        'all' { Set-StatusValue 'Game' ('TCP+UDP · ' + $gameFilter.Tcp) $script:ClrGreen }
        'tcp' { Set-StatusValue 'Game' ('TCP · ' + $gameFilter.Tcp) $script:ClrGreen }
        'udp' { Set-StatusValue 'Game' ('UDP · ' + $gameFilter.Udp) $script:ClrGreen }
        default { Set-StatusValue 'Game' 'выключен' $script:ClrMuted }
    }

    # Встроенная проверка обновлений .bat
    if (Test-Path -LiteralPath (Join-Path $script:ZapretRoot 'utils\check_updates.enabled')) {
        Set-StatusValue 'Updates' 'включена' $script:ClrGreen
    } else {
        Set-StatusValue 'Updates' 'выключена' $script:ClrMuted
    }

    # Версия пакета
    $version = Get-LocalZapretVersion -Root $script:ZapretRoot
    if ($version) {
        Set-StatusValue 'Version' $version $script:ClrText
    } else {
        Set-StatusValue 'Version' '—' $script:ClrMuted
    }

    # Элементы управления, зависящие от службы
    if ($script:ChkAutostart -and $script:BtnRestartService -and $script:BtnRemoveService) {
        $script:SyncingUi = $true
        try {
            $script:ChkAutostart.Enabled = $service.Installed
            if ($service.Installed) {
                $script:ChkAutostart.Checked = ($service.StartType -eq 'Auto')
            } else {
                $script:ChkAutostart.Checked = $false
            }
            $script:BtnRestartService.Enabled = $service.Installed
            $script:BtnRemoveService.Enabled = $service.Installed
        } finally {
            $script:SyncingUi = $false
        }
    }

    if ($script:LblServiceUsing) {
        if ($serviceStrategy) {
            $script:LblServiceUsing.Text = 'Служба использует: ' + $serviceStrategy
        } else {
            $script:LblServiceUsing.Text = 'Служба использует: —'
        }
    }
}

# ---------------------------------------------------------------------------
#  Настройки: загрузка в интерфейс и применение
# ---------------------------------------------------------------------------
function Load-SettingsIntoUi {
    if (-not $script:CbGameMode) { return }

    $gameFilter = Get-GameFilterState -Root $script:ZapretRoot
    $ipset = Get-IpsetState -Root $script:ZapretRoot

    $script:SyncInputs = $true
    try {
        switch ($gameFilter.Mode) {
            'all' { $gameIndex = 1 }
            'tcp' { $gameIndex = 2 }
            'udp' { $gameIndex = 3 }
            default { $gameIndex = 0 }
        }
        $script:CbGameMode.SelectedIndex = $gameIndex
        $script:TxtGameTcp.Text = $gameFilter.Tcp
        $script:TxtGameUdp.Text = $gameFilter.Udp

        switch ($ipset) {
            'none' { $ipsetIndex = 1 }
            'loaded' { $ipsetIndex = 2 }
            default { $ipsetIndex = 0 }
        }
        $script:CbIpset.SelectedIndex = $ipsetIndex

        $script:ChkBatUpdates.Checked = Test-Path -LiteralPath (Join-Path $script:ZapretRoot 'utils\check_updates.enabled')
    } finally {
        $script:SyncInputs = $false
    }
}

function Apply-RunningChanges {
    param([string]$Reason)

    $service = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
    if ($service) {
        $reinstallQuestion = "Чтобы применить изменения $Reason, службу нужно переустановить.`n`nПереустановить её сейчас?"
        if (Confirm-Ui -Text $reinstallQuestion -Title 'Применение изменений') {
            $name = Get-ServiceStrategy
            if (-not $name) { $name = Get-SelectedStrategyName }
            if ($name) {
                Install-ServiceInternal -StrategyName $name -NoConfirm | Out-Null
            } else {
                Write-UiLog 'Не удалось определить стратегию службы.' 'Yellow'
            }
        }
        return
    }

    if (@(Get-WinwsProcesses).Count -gt 0) {
        if (Confirm-Ui "Перезапустить zapret, чтобы применить изменения $Reason?" 'Применение изменений') {
            $name = $script:Config.LastStartedStrategy
            if (-not $name -or -not (Test-Path -LiteralPath (Join-Path $script:ZapretRoot $name))) {
                $name = Get-SelectedStrategyName
            }
            if ($name) { Start-StrategyInternal -Name $name -NoConfirm | Out-Null }
        }
    }
}

function Apply-GameFilterAction {
    if (-not (Test-IsAdmin)) { Show-UiError 'Нужны права администратора.'; return }

    $modes = @('disabled', 'all', 'tcp', 'udp')
    $modeIndex = $script:CbGameMode.SelectedIndex
    if ($modeIndex -lt 0) { $modeIndex = 0 }
    $mode = $modes[$modeIndex]
    $tcp = $script:TxtGameTcp.Text.Trim()
    $udp = $script:TxtGameUdp.Text.Trim()

    if (-not (Test-PortRange -Value $tcp)) {
        Show-UiError "Некорректный диапазон TCP-портов.`n`nПример: 1024-65535 или 1024-1934,1936-65535"
        return
    }
    if (-not (Test-PortRange -Value $udp)) {
        Show-UiError "Некорректный диапазон UDP-портов.`n`nПример: 1024-65535 или 1024-1934,1936-65535"
        return
    }

    $file = Join-Path $script:ZapretRoot 'utils\game_filter.enabled'
    $content = "mode=$mode`r`ntcp=$tcp`r`nudp=$udp`r`n"
    try {
        [IO.File]::WriteAllText($file, $content, [Text.Encoding]::ASCII)
    } catch {
        Show-UiError $_.Exception.Message
        return
    }

    Write-UiLog ("Игровой фильтр сохранён: mode=$mode, TCP=$tcp, UDP=$udp") 'Green'
    Update-AllStatus
    Apply-RunningChanges -Reason 'игрового фильтра'
}

function Apply-IpsetAction {
    $modes = @('any', 'none', 'loaded')
    $index = $script:CbIpset.SelectedIndex
    if ($index -lt 0) { $index = 0 }
    $mode = $modes[$index]

    try {
        Set-IpsetMode -Root $script:ZapretRoot -Mode $mode
        Write-UiLog ("Режим IPSet установлен: " + $mode) 'Green'
        Load-SettingsIntoUi
        Update-AllStatus
        Apply-RunningChanges -Reason 'IPSet'
    } catch {
        Write-UiLog ('Ошибка IPSet: ' + $_.Exception.Message) 'Red'
        Show-UiError $_.Exception.Message
        Load-SettingsIntoUi
    }
}

function Update-IpsetAction {
    if (-not (Confirm-Ui "Скачать свежий список IPSet с GitHub и заменить lists\ipset-all.txt?" 'Обновление IPSet')) { return }

    Set-BusyStatus 'Загрузка IPSet...'
    Write-UiLog 'Загрузка списка IPSet с GitHub...' 'Cyan'

    $target = Join-Path $script:ZapretRoot 'lists\ipset-all.txt'
    $temp = Join-Path $script:DataDir 'ipset-new.txt'
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue

    if (-not (Invoke-CurlDownload -Url $script:ZC_IpsetUrl -OutFile $temp -TimeoutSec 180)) {
        Write-UiLog 'Не удалось скачать IPSet.' 'Red'
        Show-UiError 'Не удалось скачать список IPSet. Проверьте подключение к GitHub.'
        Set-BusyStatus 'Ошибка загрузки IPSet'
        return
    }

    $size = (Get-Item -LiteralPath $temp).Length
    if ($size -lt 100) {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        Show-UiError ("Скачанный файл слишком маленький ($size байт). Обновление отменено.")
        return
    }

    Move-Item -LiteralPath $temp -Destination $target -Force
    Write-UiLog ("IPSet обновлён (" + [Math]::Round($size / 1KB) + " КБ).") 'Green'
    Load-SettingsIntoUi
    Update-AllStatus
    Set-BusyStatus 'IPSet обновлён'
    Apply-RunningChanges -Reason 'списка IPSet'
}

function Set-BatUpdatesAction {
    if ($script:SyncInputs) { return }

    $file = Join-Path $script:ZapretRoot 'utils\check_updates.enabled'
    try {
        if ($script:ChkBatUpdates.Checked) {
            Set-Content -LiteralPath $file -Value 'ENABLED' -Encoding Ascii
            Write-UiLog 'Встроенная проверка обновлений .bat включена.' 'Green'
        } else {
            Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
            Write-UiLog 'Встроенная проверка обновлений .bat выключена.' 'Yellow'
        }
    } catch {
        Show-UiError $_.Exception.Message
    }
    Update-AllStatus
}

function Open-UserList {
    param([string]$Name)

    $path = Join-Path $script:ZapretRoot ('lists\' + $Name)
    if (-not (Test-Path -LiteralPath $path)) {
        Set-Content -LiteralPath $path -Value '# Список пользователя' -Encoding Ascii
    }
    Start-Process -FilePath 'notepad.exe' -ArgumentList ('"' + $path + '"') | Out-Null
}

function Open-Folder {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $Path + '"') | Out-Null
    }
}

# ---------------------------------------------------------------------------
#  Чтение журнала winws.exe
# ---------------------------------------------------------------------------
function Read-WinwsLog {
    if (-not $script:WinwsLogPath -or -not (Test-Path -LiteralPath $script:WinwsLogPath)) { return }

    try {
        $stream = [IO.File]::Open($script:WinwsLogPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    } catch {
        return
    }

    $text = ''
    try {
        if ($script:LogReadPos -gt $stream.Length) { $script:LogReadPos = 0 }
        $stream.Position = $script:LogReadPos
        $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::Default)
        $text = $reader.ReadToEnd()
        $script:LogReadPos = $stream.Position
        $reader.Dispose()
    } finally {
        $stream.Dispose()
    }

    if ([string]::IsNullOrWhiteSpace($text)) { return }

    foreach ($line in ($text -split "`r?`n")) {
        $clean = $line.Trim()
        if ($clean.Length -eq 0) { continue }
        $color = 'Gray'
        if ($clean -match '(?i)(error|failed|invalid|cannot|unable|denied)') { $color = 'Red' }
        elseif ($clean -match '(?i)(warning|warn)') { $color = 'Yellow' }
        elseif ($clean -match '(?i)(success|started|running|ok)') { $color = 'Green' }
        Write-UiLog ('winws: ' + $clean) $color
    }
}
# ---------------------------------------------------------------------------
#  Диагностика
# ---------------------------------------------------------------------------
function Write-Check {
    param([string]$Name, [string]$Level, [string]$Details = '')

    switch ($Level) {
        'ok'   { $prefix = '[ OK ]'; $color = 'Green' }
        'warn' { $prefix = '[WARN]'; $color = 'Yellow' }
        'fail' { $prefix = '[FAIL]'; $color = 'Red' }
        default { $prefix = '[INFO]'; $color = 'Gray' }
    }

    $line = $prefix + ' ' + $Name
    if ($Details) { $line += ' — ' + $Details }
    Write-UiLog $line $color
}

function Clear-DiscordCacheInternal {
    $variants = @(
        @{ Dir = (Join-Path $env:APPDATA 'discord');            Proc = 'Discord';            Name = 'Discord' },
        @{ Dir = (Join-Path $env:APPDATA 'discordptb');         Proc = 'DiscordPTB';         Name = 'Discord PTB' },
        @{ Dir = (Join-Path $env:APPDATA 'discordcanary');      Proc = 'DiscordCanary';      Name = 'Discord Canary' },
        @{ Dir = (Join-Path $env:APPDATA 'discorddevelopment'); Proc = 'DiscordDevelopment'; Name = 'Discord Development' }
    )

    $found = $false
    foreach ($variant in $variants) {
        if (-not (Test-Path -LiteralPath $variant.Dir)) { continue }
        $found = $true

        $processes = @(Get-Process -Name $variant.Proc -ErrorAction SilentlyContinue)
        foreach ($process in $processes) {
            try {
                Stop-Process -Id $process.Id -Force -ErrorAction Stop
                Write-UiLog ($variant.Name + ' закрыт.') 'Yellow'
            } catch {
                Write-UiLog ('Не удалось закрыть ' + $variant.Name + ': ' + $_.Exception.Message) 'Red'
            }
        }

        foreach ($sub in @('Cache', 'Code Cache', 'GPUCache')) {
            $dir = Join-Path $variant.Dir $sub
            if (Test-Path -LiteralPath $dir) {
                try {
                    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction Stop
                    Write-UiLog ('Удалено: ' + $dir) 'Green'
                } catch {
                    Write-UiLog ('Не удалось удалить: ' + $dir) 'Red'
                }
            }
        }
    }

    if (-not $found) { Write-UiLog 'Установки Discord не найдены.' 'Yellow' }
}

function Remove-WinDivertLeftovers {
    foreach ($driverService in @('WinDivert', 'WinDivert14')) {
        $driver = Get-Service -Name $driverService -ErrorAction SilentlyContinue
        if ($driver) {
            try { Stop-Service -Name $driverService -Force -ErrorAction SilentlyContinue } catch { }
            & sc.exe delete $driverService 2>$null | Out-Null
            Write-UiLog ('Служба ' + $driverService + ' удалена.') 'Green'
        }
    }
}

function Run-DiagnosticsAction {
    Write-UiLog '================= ДИАГНОСТИКА =================' 'Cyan'
    $fails = 0
    $warns = 0

    # Права
    if (Test-IsAdmin) {
        Write-Check 'Права администратора' 'ok'
    } else {
        Write-Check 'Права администратора' 'fail' 'запустите GUI от имени администратора'
        $fails++
    }

    Write-Check 'Папка zapret' 'ok' $script:ZapretRoot

    # Base Filtering Engine
    $bfe = Get-Service -Name 'BFE' -ErrorAction SilentlyContinue
    if ($bfe -and $bfe.Status -eq 'Running') {
        Write-Check 'Base Filtering Engine (BFE)' 'ok'
    } else {
        Write-Check 'Base Filtering Engine (BFE)' 'fail' 'служба не запущена, zapret не сможет работать'
        $fails++
    }

    # Прокси
    try {
        $proxy = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
        if ($proxy -and $proxy.ProxyEnable -eq 1) {
            $proxyServer = ''
            if ($proxy.ProxyServer) { $proxyServer = $proxy.ProxyServer }
            Write-Check 'Системный прокси' 'warn' ('включён: ' + $proxyServer)
            $warns++
        } else {
            Write-Check 'Системный прокси' 'ok'
        }
    } catch {
        Write-Check 'Системный прокси' 'warn' 'не удалось проверить'
        $warns++
    }

    # TCP timestamps
    try {
        & netsh.exe interface tcp set global timestamps=enabled 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Check 'TCP timestamps' 'ok' 'включены' }
        else { Write-Check 'TCP timestamps' 'warn' 'не удалось включить' ; $warns++ }
    } catch {
        Write-Check 'TCP timestamps' 'warn' 'не удалось проверить'
        $warns++
    }

    # Adguard
    if (@(Get-Process -Name 'AdguardSvc' -ErrorAction SilentlyContinue).Count -gt 0) {
        Write-Check 'Adguard' 'fail' 'Adguard может мешать Discord'
        $fails++
    } else {
        Write-Check 'Adguard' 'ok'
    }

    $allServices = @(Get-Service -ErrorAction SilentlyContinue)

    # Killer
    $killer = @($allServices | Where-Object { $_.Name -match 'Killer' -or $_.DisplayName -match 'Killer' })
    if ($killer.Count -gt 0) {
        Write-Check 'Killer' 'fail' ('найдены службы: ' + (($killer | ForEach-Object { $_.Name }) -join ', '))
        $fails++
    } else {
        Write-Check 'Killer' 'ok'
    }

    # Intel Connectivity
    $intel = @($allServices | Where-Object { ($_.Name -match 'Intel' -and $_.Name -match 'Connect') -or ($_.DisplayName -match 'Intel' -and $_.DisplayName -match 'Connectivity') })
    if ($intel.Count -gt 0) {
        Write-Check 'Intel Connectivity Network Service' 'fail' 'конфликтует с zapret'
        $fails++
    } else {
        Write-Check 'Intel Connectivity Network Service' 'ok'
    }

    # Check Point
    $checkPoint = @($allServices | Where-Object { $_.Name -match 'TracSrvWrapper' -or $_.Name -match 'EPWD' })
    if ($checkPoint.Count -gt 0) {
        Write-Check 'Check Point' 'fail' 'конфликтует с zapret'
        $fails++
    } else {
        Write-Check 'Check Point' 'ok'
    }

    # SmartByte
    $smartByte = @($allServices | Where-Object { $_.Name -match 'SmartByte' -or $_.DisplayName -match 'SmartByte' })
    if ($smartByte.Count -gt 0) {
        Write-Check 'SmartByte' 'fail' 'конфликтует с zapret'
        $fails++
    } else {
        Write-Check 'SmartByte' 'ok'
    }

    # Кириллица в пути
    if ($script:ZapretRoot -match '[А-Яа-яЁё]') {
        Write-Check 'Путь без кириллицы' 'warn' 'в пути есть русские буквы, возможны проблемы'
        $warns++
    } else {
        Write-Check 'Путь без кириллицы' 'ok'
    }

    # OneDrive
    if ($env:OneDrive -and $script:ZapretRoot.StartsWith($env:OneDrive, [StringComparison]::OrdinalIgnoreCase)) {
        Write-Check 'OneDrive' 'warn' 'zapret находится в папке OneDrive'
        $warns++
    } else {
        Write-Check 'OneDrive' 'ok'
    }

    # WinDivert64.sys
    $sysFiles = @(Get-ChildItem -LiteralPath (Join-Path $script:ZapretRoot 'bin') -Filter '*.sys' -File -ErrorAction SilentlyContinue)
    if ($sysFiles.Count -gt 0) {
        Write-Check 'WinDivert64.sys' 'ok'
    } else {
        Write-Check 'WinDivert64.sys' 'fail' 'файл не найден в папке bin'
        $fails++
    }

    # VPN
    $vpnServices = @($allServices | Where-Object { $_.Name -match 'VPN' -or $_.DisplayName -match 'VPN' })
    if ($vpnServices.Count -gt 0) {
        Write-Check 'VPN-службы' 'warn' ('найдены: ' + (($vpnServices | ForEach-Object { $_.Name }) -join ', '))
        $warns++
    } else {
        Write-Check 'VPN-службы' 'ok'
    }

    # Secure DNS
    try {
        $dohCount = 0
        $dohItems = @(Get-ChildItem -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\InterfaceSpecificParameters' -Recurse -ErrorAction SilentlyContinue |
            Get-ItemProperty -ErrorAction SilentlyContinue |
            Where-Object { $_.DohFlags -gt 0 })
        $dohCount = $dohItems.Count
        if ($dohCount -eq 0) {
            Write-Check 'Шифрованный DNS (DoH)' 'warn' 'включите secure DNS в браузере или Windows'
            $warns++
        } else {
            Write-Check 'Шифрованный DNS (DoH)' 'ok'
        }
    } catch {
        Write-Check 'Шифрованный DNS (DoH)' 'warn' 'не удалось проверить'
        $warns++
    }

    # hosts
    $hostsFile = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    if (Test-Path -LiteralPath $hostsFile) {
        $hostsText = ''
        try { $hostsText = [IO.File]::ReadAllText($hostsFile) } catch { }
        if ($hostsText -match '(?i)(youtube\.com|youtu\.be)') {
            Write-Check 'Файл hosts' 'warn' 'в hosts есть записи YouTube'
            $warns++
        } else {
            Write-Check 'Файл hosts' 'ok'
        }
    }

    # WinDivert без winws
    $winws = @(Get-WinwsProcesses)
    $winDivert = Get-Service -Name 'WinDivert' -ErrorAction SilentlyContinue
    if ($winws.Count -eq 0 -and $winDivert -and ($winDivert.Status -eq 'Running' -or $winDivert.Status -eq 'StopPending')) {
        Write-Check 'WinDivert' 'warn' 'служба активна, хотя winws.exe не запущен'
        $warns++
        if (Confirm-Ui "Обнаружена активная служба WinDivert без запущенного winws.exe.`n`nПопытаться удалить её?" 'Диагностика') {
            Remove-WinDivertLeftovers
        }
    } else {
        Write-Check 'WinDivert' 'ok'
    }

    # Конфликтующие обходы
    $conflicts = @()
    foreach ($conflictName in @('GoodbyeDPI', 'discordfix_zapret', 'winws1', 'winws2')) {
        if (Get-Service -Name $conflictName -ErrorAction SilentlyContinue) { $conflicts += $conflictName }
    }
    if ($conflicts.Count -gt 0) {
        Write-Check 'Конфликтующие службы' 'fail' ($conflicts -join ', ')
        $fails++
        $conflictQuestion = "Найдены конфликтующие службы:`n" + ($conflicts -join "`n") + "`n`nУдалить их?"
        if (Confirm-Ui -Text $conflictQuestion -Title 'Диагностика') {
            foreach ($conflictName in $conflicts) {
                try { Stop-Service -Name $conflictName -Force -ErrorAction SilentlyContinue } catch { }
                & sc.exe delete $conflictName 2>$null | Out-Null
                Write-UiLog ('Удалена служба: ' + $conflictName) 'Green'
            }
            Remove-WinDivertLeftovers
        }
    } else {
        Write-Check 'Конфликтующие службы' 'ok'
    }

    # Discord cache
    if (Confirm-Ui 'Очистить кэш Discord (Stable / PTB / Canary / Development)?' 'Диагностика') {
        Clear-DiscordCacheInternal
    }

    if ($fails -gt 0) {
        Write-UiLog ('=== Диагностика завершена: ошибок ' + $fails + ', предупреждений ' + $warns + ' ===') 'Red'
        Show-UiInfo ("Диагностика завершена.`nОшибок: $fails`nПредупреждений: $warns`n`nПодробности — в журнале внизу окна.") 'Диагностика'
    } elseif ($warns -gt 0) {
        Write-UiLog ('=== Диагностика завершена: предупреждений ' + $warns + ' ===') 'Yellow'
        Show-UiInfo ("Диагностика завершена.`nПредупреждений: $warns`n`nПодробности — в журнале внизу окна.") 'Диагностика'
    } else {
        Write-UiLog '=== Диагностика завершена: проблем не найдено ===' 'Green'
        Show-UiInfo 'Диагностика завершена. Проблем не найдено.' 'Диагностика'
    }
}

# ---------------------------------------------------------------------------
#  Замена active fake
# ---------------------------------------------------------------------------
function Get-FileHashText {
    param([string]$Path)
    try { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash } catch { return '' }
}

function Open-FakesDialog {
    $binDir = Join-Path $script:ZapretRoot 'bin'
    $fakes = @(Get-ChildItem -LiteralPath $binDir -Filter '*.bin' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.BaseName -notlike 'ACTIVE_*' } |
        Sort-Object Name)

    if ($fakes.Count -eq 0) { Show-UiError 'В папке bin не найдены fake-файлы *.bin.'; return }

    $dialog = New-Object Windows.Forms.Form
    $dialog.Text = 'Замена active fake'
    $dialog.Size = New-Object Drawing.Size(640, 520)
    $dialog.StartPosition = 'CenterParent'
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.BackColor = $script:ClrBg
    $dialog.Font = $script:FontUi

    $targetLabel = New-UiLabel -Text 'Что заменяем:' -X 16 -Y 14 -Width 560 -Height 20 -Font $script:FontUiBold
    $targetCombo = New-Object Windows.Forms.ComboBox
    $targetCombo.Location = New-Object Drawing.Point(16, 36)
    $targetCombo.Size = New-Object Drawing.Size(596, 24)
    $targetCombo.DropDownStyle = 'DropDownList'
    $targetCombo.Font = $script:FontUi
    [void]$targetCombo.Items.Add('Discord UDP  (ACTIVE_DISCORD_UDP.bin)')
    [void]$targetCombo.Items.Add('GameFilter UDP  (ACTIVE_GAME_UDP.bin)')
    $targetCombo.SelectedIndex = 0

    $currentLabel = New-UiLabel -Text 'Текущий fake: —' -X 16 -Y 70 -Width 596 -Height 20 -Font $script:FontUi -Color $script:ClrMuted
    $listLabel = New-UiLabel -Text 'Доступные fake-файлы:' -X 16 -Y 96 -Width 560 -Height 20 -Font $script:FontUiBold

    $listBox = New-Object Windows.Forms.ListBox
    $listBox.Location = New-Object Drawing.Point(16, 118)
    $listBox.Size = New-Object Drawing.Size(596, 290)
    $listBox.Font = New-Object Drawing.Font('Segoe UI', 10)
    $listBox.BorderStyle = 'FixedSingle'
    $listBox.IntegralHeight = $false
    foreach ($fake in $fakes) { [void]$listBox.Items.Add($fake.Name) }
    if ($listBox.Items.Count -gt 0) { $listBox.SelectedIndex = 0 }

    $statusLabel = New-UiLabel -Text '' -X 16 -Y 416 -Width 360 -Height 40 -Font $script:FontSmall -Color $script:ClrGreen

    $btnReplace = New-StyledButton -Text 'Заменить' -Width 120 -Height 34 -Kind 'primary'
    $btnReplace.Location = New-Object Drawing.Point(372, 430)
    $btnClose = New-StyledButton -Text 'Закрыть' -Width 100 -Height 34 -Kind 'secondary'
    $btnClose.Location = New-Object Drawing.Point(502, 430)

    $activeNames = @('ACTIVE_DISCORD_UDP.bin', 'ACTIVE_GAME_UDP.bin')

    $updateCurrent = {
        $activeName = $activeNames[$targetCombo.SelectedIndex]
        $activePath = Join-Path $binDir $activeName
        $activeHash = Get-FileHashText -Path $activePath
        $foundName = '(не найден)'
        if ($activeHash) {
            foreach ($fake in $fakes) {
                if ((Get-FileHashText -Path $fake.FullName) -eq $activeHash) { $foundName = $fake.Name; break }
            }
        }
        $currentLabel.Text = 'Текущий fake: ' + $foundName
    }

    $targetCombo.Add_SelectedIndexChanged($updateCurrent)
    & $updateCurrent

    $btnReplace.Add_Click({
        if ($listBox.SelectedIndex -lt 0) { return }
        $activeName = $activeNames[$targetCombo.SelectedIndex]
        $activePath = Join-Path $binDir $activeName
        $source = $fakes[$listBox.SelectedIndex].FullName
        try {
            Copy-Item -LiteralPath $source -Destination $activePath -Force -ErrorAction Stop
            $statusLabel.ForeColor = $script:ClrGreen
            $statusLabel.Text = 'Заменено: ' + $fakes[$listBox.SelectedIndex].Name + "`r`nПерезапустите zapret."
            Write-UiLog ('Active fake заменён: ' + $activeName + ' → ' + $fakes[$listBox.SelectedIndex].Name) 'Green'
            & $updateCurrent
        } catch {
            $statusLabel.ForeColor = $script:ClrRed
            $statusLabel.Text = 'Ошибка: ' + $_.Exception.Message
            Write-UiLog ('Ошибка замены fake: ' + $_.Exception.Message) 'Red'
        }
    })

    $btnClose.Add_Click({ $dialog.Close() })

    $dialog.Controls.AddRange(@($targetLabel, $targetCombo, $currentLabel, $listLabel, $listBox, $statusLabel, $btnReplace, $btnClose))
    [void]$dialog.ShowDialog($script:Form)
    $dialog.Dispose()
}

# ---------------------------------------------------------------------------
#  Тест стратегий и быстрая проверка
# ---------------------------------------------------------------------------
function Run-StrategyTestsAction {
    $tester = Join-Path $script:ZapretRoot 'utils\test zapret.ps1'
    if (-not (Test-Path -LiteralPath $tester)) {
        Show-UiError ("Не найден файл:`n" + $tester)
        return
    }

    $service = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
    if ($service) {
        if (-not (Confirm-Ui "Тест стратегий не работает, пока установлена служба zapret.`n`nУдалить службу и запустить тест?" 'Тест стратегий')) {
            return
        }
        Remove-ServiceInternal -NoConfirm | Out-Null
    } elseif (@(Get-WinwsProcesses).Count -gt 0) {
        if (-not (Confirm-Ui 'Перед тестом нужно остановить winws.exe. Продолжить?' 'Тест стратегий')) { return }
        Stop-ZapretProcesses | Out-Null
    }

    Write-UiLog 'Запуск штатного теста стратегий в отдельном окне...' 'Cyan'
    Write-UiLog 'Выберите режим в открывшемся окне. Тест может занять несколько минут.' 'Gray'

    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "' + $tester + '"'
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -WorkingDirectory $script:ZapretRoot | Out-Null
    } catch {
        Write-UiLog ('Не удалось запустить тест: ' + $_.Exception.Message) 'Red'
        Show-UiError $_.Exception.Message
    }
    Update-AllStatus
}

function Quick-CheckAction {
    $targets = @(
        @{ Name = 'Discord';          Url = 'https://discord.com' },
        @{ Name = 'Discord Gateway';  Url = 'https://gateway.discord.gg' },
        @{ Name = 'YouTube';          Url = 'https://www.youtube.com' },
        @{ Name = 'Google';           Url = 'https://www.google.com' },
        @{ Name = 'Cloudflare';       Url = 'https://www.cloudflare.com' }
    )

    Write-UiLog '=== Быстрая проверка соединения ===' 'Cyan'
    foreach ($target in $targets) {
        Set-BusyStatus ('Проверка: ' + $target.Name + '...')
        $result = Test-UrlAvailability -Url $target.Url -TimeoutSec 6
        if ($result.Ok) {
            Write-UiLog ('{0,-16} OK (HTTP {1})' -f $target.Name, $result.Code) 'Green'
        } else {
            Write-UiLog ('{0,-16} НЕДОСТУПЕН (HTTP {1})' -f $target.Name, $result.Code) 'Red'
        }
    }
    Set-BusyStatus 'Проверка завершена'
}
# ---------------------------------------------------------------------------
#  Обновление zapret с GitHub
# ---------------------------------------------------------------------------
function Check-UpdatesAction {
    param([switch]$Silent)

    if (-not $Silent) { Set-BusyStatus 'Проверка обновлений на GitHub...' }
    Write-UiLog 'Проверка обновлений на GitHub (Flowseal/zapret-discord-youtube)...' 'Cyan'

    $release = Get-LatestZapretRelease
    if (-not $release) {
        if ($script:LblUpdateStatus) {
            $script:LblUpdateStatus.Text = 'Ошибка проверки GitHub'
            $script:LblUpdateStatus.ForeColor = $script:ClrRed
        }
        if (-not $Silent) {
            Write-UiLog 'Не удалось получить данные с GitHub.' 'Red'
            Show-UiError "Не удалось получить данные с GitHub.`nПроверьте подключение к интернету."
        }
        Set-BusyStatus 'Ошибка проверки обновлений'
        return
    }

    $script:LatestRelease = $release
    $localText = Get-LocalZapretVersion -Root $script:ZapretRoot
    $local = ConvertTo-AppVersion $localText
    $remote = ConvertTo-AppVersion $release.Tag

    if ($script:LblUpdateLocal) {
        $script:LblUpdateLocal.Text = 'Установленная версия: ' + $(if ($local) { $local.ToString() } else { '—' })
    }
    if ($script:LblUpdateLatest) {
        $script:LblUpdateLatest.Text = 'Последняя на GitHub: ' + $release.Tag
    }
    if ($script:TxtReleaseNotes) {
        if ($release.Body) { $script:TxtReleaseNotes.Text = $release.Body }
        else { $script:TxtReleaseNotes.Text = '(описание релиза пустое)' }
    }

    $available = ($local -and $remote -and $remote -gt $local)
    $script:UpdateAvailable = $available
    if ($script:BtnInstallUpdate) { $script:BtnInstallUpdate.Enabled = $available }

    if ($available) {
        if ($script:LblUpdateStatus) {
            $script:LblUpdateStatus.Text = 'Доступно обновление ' + $release.Tag
            $script:LblUpdateStatus.ForeColor = $script:ClrGreen
        }
        Write-UiLog ('Доступно обновление: ' + $release.Tag + ' (установлено ' + $local + ')') 'Green'

        if (-not $Silent) {
            $answer = [Windows.Forms.MessageBox]::Show($script:Form,
                "Доступна новая версия zapret: $($release.Tag)`nУстановлена: $local`n`nСкачать и установить сейчас?",
                'Обновление zapret',
                [Windows.Forms.MessageBoxButtons]::YesNo,
                [Windows.Forms.MessageBoxIcon]::Question)
            if ($answer -eq [Windows.Forms.DialogResult]::Yes) { Install-UpdateAction }
        }
    } else {
        if ($script:LblUpdateStatus) {
            $script:LblUpdateStatus.Text = 'Установлена последняя версия'
            $script:LblUpdateStatus.ForeColor = $script:ClrMuted
        }
        if (-not $Silent) { Write-UiLog 'Установлена последняя версия zapret.' 'Green' }
    }

    Set-BusyStatus 'Готово'
}

function Install-UpdateAction {
    if (-not $script:UpdateAvailable -or -not $script:LatestRelease) { return }

    $release = $script:LatestRelease
    if (-not $release.AssetUrl) {
        Show-UiError 'В релизе на GitHub нет zip-архива. Обновите вручную со страницы релизов.'
        return
    }

    $question = "Скачать и установить zapret $($release.Tag)?`n`n" +
        "Текущий zapret будет остановлен.`n" +
        "Новая версия будет установлена в отдельную папку рядом,`n" +
        "пользовательские списки будут перенесены."
    if (-not (Confirm-Ui $question 'Обновление zapret')) { return }

    $oldRoot = $script:ZapretRoot
    $oldServiceStrategy = Get-ServiceStrategy
    $serviceWasInstalled = ($null -ne (Get-Service -Name 'zapret' -ErrorAction SilentlyContinue))
    $workDir = Join-Path $env:TEMP ('zapret-update-' + [guid]::NewGuid().ToString('N'))

    try {
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null

        $zipPath = Join-Path $workDir $release.AssetName
        Set-BusyStatus 'Скачивание обновления...'
        Write-UiLog ('Скачивание: ' + $release.AssetUrl) 'Cyan'
        if (-not (Invoke-CurlDownload -Url $release.AssetUrl -OutFile $zipPath -TimeoutSec 600)) {
            throw 'Не удалось скачать архив обновления.'
        }

        Set-BusyStatus 'Распаковка архива...'
        Write-UiLog 'Распаковка архива...' 'Gray'
        $extractDir = Join-Path $workDir 'extract'
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force

        $serviceBat = Get-ChildItem -LiteralPath $extractDir -Recurse -Filter 'service.bat' -File -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.DirectoryName 'bin\winws.exe') } |
            Select-Object -First 1
        if (-not $serviceBat) { throw 'В архиве не найдена папка zapret (service.bat + bin\winws.exe).' }
        $sourceRoot = $serviceBat.DirectoryName

        $parentDir = Split-Path -Parent $oldRoot
        $targetDir = Join-Path $parentDir ([IO.Path]::GetFileNameWithoutExtension($release.AssetName))
        if ($targetDir.TrimEnd('\') -ieq $oldRoot.TrimEnd('\')) {
            $targetDir = $oldRoot.TrimEnd('\') + '-update-' + $release.Tag
        }

        Write-UiLog 'Остановка zapret перед обновлением...' 'Yellow'
        Stop-ZapretService | Out-Null
        Stop-ZapretProcesses | Out-Null

        Set-BusyStatus 'Установка файлов...'
        if (-not (Test-Path -LiteralPath $targetDir)) {
            New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        }
        Get-ChildItem -LiteralPath $sourceRoot -Force | Copy-Item -Destination $targetDir -Recurse -Force

        # Перенос пользовательских данных
        $sourceLists = Join-Path $oldRoot 'lists'
        $targetLists = Join-Path $targetDir 'lists'
        foreach ($name in @('list-general-user.txt', 'list-exclude-user.txt', 'ipset-exclude-user.txt', 'ipset-all.txt', 'ipset-all.txt.backup')) {
            $sourceFile = Join-Path $sourceLists $name
            if (Test-Path -LiteralPath $sourceFile) {
                Copy-Item -LiteralPath $sourceFile -Destination (Join-Path $targetLists $name) -Force -ErrorAction SilentlyContinue
            }
        }
        foreach ($name in @('game_filter.enabled', 'check_updates.enabled')) {
            $sourceFile = Join-Path $oldRoot ('utils\' + $name)
            if (Test-Path -LiteralPath $sourceFile) {
                Copy-Item -LiteralPath $sourceFile -Destination (Join-Path $targetDir ('utils\' + $name)) -Force -ErrorAction SilentlyContinue
            }
        }

        # Переключаем GUI на новую папку
        $script:ZapretRoot = $targetDir
        $script:Config.ZapretRoot = $targetDir
        if (-not $script:Config.SelectedStrategy -or -not (Test-Path -LiteralPath (Join-Path $targetDir $script:Config.SelectedStrategy))) {
            $newStrategies = @(Get-Strategies -Root $targetDir)
            if ($newStrategies.Count -gt 0) { $script:Config.SelectedStrategy = $newStrategies[0].Name }
        }
        Save-Config

        Write-UiLog ('Обновление установлено в: ' + $targetDir) 'Green'
        Load-SettingsIntoUi
        Refresh-StrategyList
        Update-AllStatus

        if ($serviceWasInstalled) {
            $strategyForService = $oldServiceStrategy
            if (-not $strategyForService -or -not (Test-Path -LiteralPath (Join-Path $targetDir $strategyForService))) {
                $strategyForService = $script:Config.SelectedStrategy
            }
            if ($strategyForService) {
                Write-UiLog 'Переустановка службы на новую версию...' 'Cyan'
                $ok = Install-ServiceInternal -StrategyName $strategyForService -NoConfirm
                if (-not $ok) {
                    Write-UiLog 'Службу не удалось переустановить. Сделайте это вручную на вкладке «Служба».' 'Red'
                }
            }
        }

        Show-UiInfo ("Обновление " + $release.Tag + " установлено.`n`nНовая папка:`n" + $targetDir + "`n`nСтарую папку можно удалить вручную:`n" + $oldRoot) 'Обновление завершено'
        Write-UiLog ('Старую папку можно удалить: ' + $oldRoot) 'Yellow'

        Check-UpdatesAction -Silent
    } catch {
        Write-UiLog ('Ошибка обновления: ' + $_.Exception.Message) 'Red'
        Show-UiError ("Не удалось установить обновление.`n`n" + $_.Exception.Message)
    } finally {
        Set-BusyStatus 'Готово'
        try {
            if (Test-Path -LiteralPath $workDir) {
                Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        } catch { }
    }
}

# ---------------------------------------------------------------------------
#  hosts
# ---------------------------------------------------------------------------
function Update-HostsAction {
    Set-BusyStatus 'Проверка файла hosts...'
    Write-UiLog 'Скачивание файла hosts из репозитория...' 'Cyan'

    $tempFile = Join-Path $env:TEMP 'zapret_hosts.txt'
    $cacheBuster = (Get-Random).ToString() + (Get-Random).ToString()
    $url = $script:ZC_HostsUrl + '?t=' + $cacheBuster

    if (-not (Invoke-CurlDownload -Url $url -OutFile $tempFile -TimeoutSec 60)) {
        Write-UiLog 'Не удалось скачать hosts.' 'Red'
        Show-UiError ("Не удалось скачать файл hosts.`nСкопируйте вручную:`n" + $script:ZC_HostsUrl)
        return
    }

    $hostsFile = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    $lines = @(Get-Content -LiteralPath $tempFile -ErrorAction SilentlyContinue)
    $firstLine = $null
    $lastLine = $null
    if ($lines.Count -gt 0) {
        $firstLine = $lines[0]
        $lastLine = $lines[$lines.Count - 1]
    }

    $hostsText = ''
    if (Test-Path -LiteralPath $hostsFile) {
        try { $hostsText = [IO.File]::ReadAllText($hostsFile) } catch { }
    }

    $needsUpdate = $false
    if ($firstLine -and -not $hostsText.Contains($firstLine)) { $needsUpdate = $true }
    if ($lastLine -and -not $hostsText.Contains($lastLine)) { $needsUpdate = $true }

    if ($needsUpdate) {
        Write-UiLog 'Файл hosts требует обновления.' 'Yellow'
        Write-UiLog 'Скопируйте содержимое открытого файла в hosts (блокнот уже открыт).' 'Yellow'
        Start-Process -FilePath 'notepad.exe' -ArgumentList ('"' + $tempFile + '"') | Out-Null
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"' + $hostsFile + '"') | Out-Null
        Show-UiInfo "Файл hosts требует обновления.`n`nОткрыт скачанный файл и папка с hosts.`nСкопируйте содержимое в hosts."
    } else {
        Write-UiLog 'Файл hosts актуален.' 'Green'
        Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        Show-UiInfo 'Файл hosts уже актуален.'
    }
    Set-BusyStatus 'Готово'
}

# ---------------------------------------------------------------------------
#  О программе
# ---------------------------------------------------------------------------
function Show-About {
    $text = "Zapret Control " + $script:ZC_AppVersion + "`n" +
        "Графический управлятор zapret-discord-youtube`n`n" +
        "GUI / форк: Bugulmek`n" +
        "Пакет zapret: Flowseal`n" +
        "https://github.com/Flowseal/zapret-discord-youtube`n`n" +
        "Управление службой, игровым фильтром, IPSet,`n" +
        "тест стратегий и автообновление с GitHub.`n`n" +
        "Требуются права администратора."
    Show-UiInfo $text 'О программе'
}
# ---------------------------------------------------------------------------
#  ОКНО
# ---------------------------------------------------------------------------
$script:Form = New-Object Windows.Forms.Form
$form = $script:Form
$form.Text = 'Zapret Control — управление zapret-discord-youtube (форк Bugulmek)'
$form.StartPosition = 'CenterScreen'
$form.BackColor = $script:ClrBg
$form.Font = $script:FontUi
$form.MinimumSize = New-Object Drawing.Size(1000, 700)

$workArea = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$formWidth = [Math]::Min(1180, $workArea.Width - 40)
$formHeight = [Math]::Min(900, $workArea.Height - 40)
if ($formWidth -lt 1000) { $formWidth = 1000 }
if ($formHeight -lt 700) { $formHeight = 700 }
$form.Size = New-Object Drawing.Size($formWidth, $formHeight)

$rootLayout = New-Object Windows.Forms.TableLayoutPanel
$rootLayout.Dock = 'Fill'
$rootLayout.ColumnCount = 1
$rootLayout.RowCount = 6
$rootLayout.BackColor = $script:ClrBg
$rootLayout.ColumnStyles.Add((New-ColumnStyle 'Percent' 100))
$rootLayout.RowStyles.Add((New-RowStyle 'Absolute' 26))
$rootLayout.RowStyles.Add((New-RowStyle 'Absolute' 60))
$rootLayout.RowStyles.Add((New-RowStyle 'Absolute' 112))
$rootLayout.RowStyles.Add((New-RowStyle 'Percent' 100))
$rootLayout.RowStyles.Add((New-RowStyle 'Absolute' 180))
$rootLayout.RowStyles.Add((New-RowStyle 'Absolute' 24))
$form.Controls.Add($rootLayout)

# ---------------------------------------------------------------------------
#  Меню
# ---------------------------------------------------------------------------
$menu = New-Object Windows.Forms.MenuStrip
$menu.Dock = 'Fill'
$menu.BackColor = $script:ClrCard
$menu.Font = $script:FontUi

$menuFile = New-Object Windows.Forms.ToolStripMenuItem
$menuFile.Text = 'Файл'
$script:MiChooseFolder = New-Object Windows.Forms.ToolStripMenuItem
$script:MiChooseFolder.Text = 'Выбрать папку zapret…'
$script:MiOpenRoot = New-Object Windows.Forms.ToolStripMenuItem
$script:MiOpenRoot.Text = 'Открыть папку zapret'
$script:MiExit = New-Object Windows.Forms.ToolStripMenuItem
$script:MiExit.Text = 'Выход'
[void]$menuFile.DropDownItems.Add($script:MiChooseFolder)
[void]$menuFile.DropDownItems.Add($script:MiOpenRoot)
[void]$menuFile.DropDownItems.Add((New-Object Windows.Forms.ToolStripSeparator))
[void]$menuFile.DropDownItems.Add($script:MiExit)

$menuService = New-Object Windows.Forms.ToolStripMenuItem
$menuService.Text = 'Служба'
$script:MiInstallService = New-Object Windows.Forms.ToolStripMenuItem
$script:MiInstallService.Text = 'Установить службу'
$script:MiRemoveService = New-Object Windows.Forms.ToolStripMenuItem
$script:MiRemoveService.Text = 'Удалить службу'
$script:MiRestartService = New-Object Windows.Forms.ToolStripMenuItem
$script:MiRestartService.Text = 'Перезапустить службу'
$script:MiDiagnostics = New-Object Windows.Forms.ToolStripMenuItem
$script:MiDiagnostics.Text = 'Диагностика'
$script:MiTests = New-Object Windows.Forms.ToolStripMenuItem
$script:MiTests.Text = 'Тест стратегий'
[void]$menuService.DropDownItems.Add($script:MiInstallService)
[void]$menuService.DropDownItems.Add($script:MiRemoveService)
[void]$menuService.DropDownItems.Add($script:MiRestartService)
[void]$menuService.DropDownItems.Add((New-Object Windows.Forms.ToolStripSeparator))
[void]$menuService.DropDownItems.Add($script:MiDiagnostics)
[void]$menuService.DropDownItems.Add($script:MiTests)

$menuHelp = New-Object Windows.Forms.ToolStripMenuItem
$menuHelp.Text = 'Справка'
$script:MiAbout = New-Object Windows.Forms.ToolStripMenuItem
$script:MiAbout.Text = 'О программе'
$script:MiGithub = New-Object Windows.Forms.ToolStripMenuItem
$script:MiGithub.Text = 'GitHub Flowseal'
[void]$menuHelp.DropDownItems.Add($script:MiGithub)
[void]$menuHelp.DropDownItems.Add($script:MiAbout)

[void]$menu.Items.Add($menuFile)
[void]$menu.Items.Add($menuService)
[void]$menu.Items.Add($menuHelp)
$form.MainMenuStrip = $menu
$rootLayout.Controls.Add($menu, 0, 0)

# ---------------------------------------------------------------------------
#  Шапка
# ---------------------------------------------------------------------------
$header = New-Object Windows.Forms.Panel
$header.Dock = 'Fill'
$header.BackColor = $script:ClrCard
$header.Margin = New-Object Windows.Forms.Padding(8, 4, 8, 2)

$headerTitle = New-UiLabel -Text 'ZAPRET CONTROL' -X 14 -Y 6 -Width 340 -Height 28 -Font $script:FontTitle -Color $script:ClrAccent
$headerSubtitle = New-UiLabel -Text 'Управление zapret-discord-youtube · тест стратегий · автообновление с GitHub · форк Bugulmek' -X 16 -Y 34 -Width 760 -Height 18 -Font $script:FontSmall -Color $script:ClrMuted

$adminBadge = New-Object Windows.Forms.Label
$adminBadge.Text = '● администратор'
$adminBadge.AutoSize = $false
$adminBadge.Width = 220
$adminBadge.Dock = 'Right'
$adminBadge.TextAlign = 'MiddleRight'
$adminBadge.Font = $script:FontUiBold
$adminBadge.ForeColor = $script:ClrGreen
$adminBadge.Padding = New-Object Windows.Forms.Padding(0, 0, 14, 0)

$header.Controls.Add($adminBadge)
$header.Controls.Add($headerTitle)
$header.Controls.Add($headerSubtitle)
$rootLayout.Controls.Add($header, 0, 1)

# ---------------------------------------------------------------------------
#  Панель состояния
# ---------------------------------------------------------------------------
$statusGroup = New-Object Windows.Forms.GroupBox
$statusGroup.Text = ' Состояние '
$statusGroup.Dock = 'Fill'
$statusGroup.BackColor = $script:ClrCard
$statusGroup.ForeColor = $script:ClrText
$statusGroup.Font = $script:FontUiBold
$statusGroup.Margin = New-Object Windows.Forms.Padding(8, 2, 8, 2)
$statusGroup.Padding = New-Object Windows.Forms.Padding(10, 4, 10, 4)

$statusTable = New-Object Windows.Forms.TableLayoutPanel
$statusTable.Dock = 'Fill'
$statusTable.ColumnCount = 4
$statusTable.RowCount = 4
$statusTable.BackColor = $script:ClrCard
for ($i = 0; $i -lt 4; $i++) { $statusTable.ColumnStyles.Add((New-ColumnStyle 'Percent' 25)) }
$statusTable.RowStyles.Add((New-RowStyle 'Absolute' 18))
$statusTable.RowStyles.Add((New-RowStyle 'Absolute' 30))
$statusTable.RowStyles.Add((New-RowStyle 'Absolute' 18))
$statusTable.RowStyles.Add((New-RowStyle 'Absolute' 30))

$statusDefs = @(
    @{ Key = 'Service'; Caption = 'Служба zapret' },
    @{ Key = 'Winws'; Caption = 'winws.exe' },
    @{ Key = 'Strategy'; Caption = 'Стратегия службы' },
    @{ Key = 'Admin'; Caption = 'Права' },
    @{ Key = 'Ipset'; Caption = 'IPSet' },
    @{ Key = 'Game'; Caption = 'Игровой фильтр' },
    @{ Key = 'Updates'; Caption = 'Автообновление .bat' },
    @{ Key = 'Version'; Caption = 'Версия zapret' }
)

for ($i = 0; $i -lt $statusDefs.Count; $i++) {
    $def = $statusDefs[$i]
    $col = $i % 4
    $block = [int][Math]::Floor($i / 4)
    $captionRow = $block * 2
    $valueRow = $captionRow + 1

    $caption = New-Object Windows.Forms.Label
    $caption.Text = $def.Caption
    $caption.Dock = 'Fill'
    $caption.Font = $script:FontSmall
    $caption.ForeColor = $script:ClrMuted
    $caption.TextAlign = 'BottomLeft'
    $caption.Margin = New-Object Windows.Forms.Padding(4, 0, 4, 0)

    $value = New-Object Windows.Forms.Label
    $value.Text = '—'
    $value.Dock = 'Fill'
    $value.Font = $script:FontHeader
    $value.ForeColor = $script:ClrText
    $value.TextAlign = 'TopLeft'
    $value.AutoEllipsis = $true
    $value.Margin = New-Object Windows.Forms.Padding(4, 0, 4, 2)

    $statusTable.Controls.Add($caption, $col, $captionRow)
    $statusTable.Controls.Add($value, $col, $valueRow)
    $script:StatusLabels[$def.Key] = $value
}

$statusGroup.Controls.Add($statusTable)
$rootLayout.Controls.Add($statusGroup, 0, 2)

# ---------------------------------------------------------------------------
#  Тело: список стратегий + вкладки
# ---------------------------------------------------------------------------
$bodyLayout = New-Object Windows.Forms.TableLayoutPanel
$bodyLayout.Dock = 'Fill'
$bodyLayout.ColumnCount = 2
$bodyLayout.RowCount = 1
$bodyLayout.BackColor = $script:ClrBg
$bodyLayout.Margin = New-Object Windows.Forms.Padding(8, 2, 8, 2)
$bodyLayout.ColumnStyles.Add((New-ColumnStyle 'Absolute' 330))
$bodyLayout.ColumnStyles.Add((New-ColumnStyle 'Percent' 100))
$rootLayout.Controls.Add($bodyLayout, 0, 3)

$strategiesGroup = New-Object Windows.Forms.GroupBox
$strategiesGroup.Text = ' Стратегии (двойной клик — запуск) '
$strategiesGroup.Dock = 'Fill'
$strategiesGroup.BackColor = $script:ClrCard
$strategiesGroup.ForeColor = $script:ClrText
$strategiesGroup.Font = $script:FontUiBold
$strategiesGroup.Margin = New-Object Windows.Forms.Padding(0, 0, 4, 0)
$strategiesGroup.Padding = New-Object Windows.Forms.Padding(8, 4, 8, 6)

$leftTable = New-Object Windows.Forms.TableLayoutPanel
$leftTable.Dock = 'Fill'
$leftTable.ColumnCount = 1
$leftTable.RowCount = 3
$leftTable.BackColor = $script:ClrCard
$leftTable.ColumnStyles.Add((New-ColumnStyle 'Percent' 100))
$leftTable.RowStyles.Add((New-RowStyle 'Percent' 100))
$leftTable.RowStyles.Add((New-RowStyle 'Absolute' 22))
$leftTable.RowStyles.Add((New-RowStyle 'Absolute' 82))

$script:LstStrategies = New-Object Windows.Forms.ListBox
$script:LstStrategies.Dock = 'Fill'
$script:LstStrategies.Font = New-Object Drawing.Font('Segoe UI', 10)
$script:LstStrategies.BorderStyle = 'FixedSingle'
$script:LstStrategies.IntegralHeight = $false
$script:LstStrategies.HorizontalScrollbar = $true
$script:LstStrategies.Margin = New-Object Windows.Forms.Padding(0, 2, 0, 4)

$script:LblServiceUsing = New-Object Windows.Forms.Label
$script:LblServiceUsing.Text = 'Служба использует: —'
$script:LblServiceUsing.Dock = 'Fill'
$script:LblServiceUsing.Font = $script:FontSmall
$script:LblServiceUsing.ForeColor = $script:ClrMuted
$script:LblServiceUsing.TextAlign = 'MiddleLeft'
$script:LblServiceUsing.Margin = New-Object Windows.Forms.Padding(2, 0, 2, 4)

$leftButtons = New-Object Windows.Forms.TableLayoutPanel
$leftButtons.Dock = 'Fill'
$leftButtons.ColumnCount = 2
$leftButtons.RowCount = 2
$leftButtons.BackColor = $script:ClrCard
$leftButtons.ColumnStyles.Add((New-ColumnStyle 'Percent' 50))
$leftButtons.ColumnStyles.Add((New-ColumnStyle 'Percent' 50))
$leftButtons.RowStyles.Add((New-RowStyle 'Percent' 50))
$leftButtons.RowStyles.Add((New-RowStyle 'Percent' 50))

$script:BtnStart = New-StyledButton -Text '▶ Запустить' -Kind 'primary'
$script:BtnStop = New-StyledButton -Text '⏹ Остановить' -Kind 'danger'
$script:BtnInstall = New-StyledButton -Text 'Установить службу' -Kind 'secondary'
$script:BtnRemove = New-StyledButton -Text 'Удалить службу' -Kind 'secondary'

foreach ($button in @($script:BtnStart, $script:BtnStop, $script:BtnInstall, $script:BtnRemove)) {
    $button.Dock = 'Fill'
    $button.Margin = New-Object Windows.Forms.Padding(2)
}

$leftButtons.Controls.Add($script:BtnStart, 0, 0)
$leftButtons.Controls.Add($script:BtnStop, 1, 0)
$leftButtons.Controls.Add($script:BtnInstall, 0, 1)
$leftButtons.Controls.Add($script:BtnRemove, 1, 1)

$leftTable.Controls.Add($script:LstStrategies, 0, 0)
$leftTable.Controls.Add($script:LblServiceUsing, 0, 1)
$leftTable.Controls.Add($leftButtons, 0, 2)
$strategiesGroup.Controls.Add($leftTable)
$bodyLayout.Controls.Add($strategiesGroup, 0, 0)

# ---------------------------------------------------------------------------
#  Журнал
# ---------------------------------------------------------------------------
$logGroup = New-Object Windows.Forms.GroupBox
$logGroup.Text = ' Журнал '
$logGroup.Dock = 'Fill'
$logGroup.BackColor = $script:ClrCard
$logGroup.ForeColor = $script:ClrText
$logGroup.Font = $script:FontUiBold
$logGroup.Margin = New-Object Windows.Forms.Padding(8, 2, 8, 6)
$logGroup.Padding = New-Object Windows.Forms.Padding(8, 4, 8, 6)

$logTable = New-Object Windows.Forms.TableLayoutPanel
$logTable.Dock = 'Fill'
$logTable.ColumnCount = 1
$logTable.RowCount = 2
$logTable.BackColor = $script:ClrCard
$logTable.ColumnStyles.Add((New-ColumnStyle 'Percent' 100))
$logTable.RowStyles.Add((New-RowStyle 'Percent' 100))
$logTable.RowStyles.Add((New-RowStyle 'Absolute' 34))

$script:RtbLog = New-Object Windows.Forms.RichTextBox
$script:RtbLog.Dock = 'Fill'
$script:RtbLog.BackColor = $script:ClrLogBg
$script:RtbLog.ForeColor = $script:ClrLogText
$script:RtbLog.Font = $script:FontMono
$script:RtbLog.ReadOnly = $true
$script:RtbLog.BorderStyle = 'None'
$script:RtbLog.WordWrap = $false
$script:RtbLog.HideSelection = $false
$script:RtbLog.Margin = New-Object Windows.Forms.Padding(0, 2, 0, 4)

$logButtons = New-Object Windows.Forms.FlowLayoutPanel
$logButtons.Dock = 'Fill'
$logButtons.FlowDirection = 'RightToLeft'
$logButtons.WrapContents = $false
$logButtons.BackColor = $script:ClrCard
$logButtons.Margin = New-Object Windows.Forms.Padding(0)

$script:BtnOpenData = New-StyledButton -Text 'Папка данных' -Width 130 -Height 28
$script:BtnOpenData.Margin = New-Object Windows.Forms.Padding(4, 2, 0, 2)
$script:BtnSaveLog = New-StyledButton -Text 'Сохранить лог…' -Width 130 -Height 28
$script:BtnSaveLog.Margin = New-Object Windows.Forms.Padding(4, 2, 0, 2)
$script:BtnClearLog = New-StyledButton -Text 'Очистить' -Width 100 -Height 28
$script:BtnClearLog.Margin = New-Object Windows.Forms.Padding(4, 2, 0, 2)

$script:ChkAutoScroll = New-Object Windows.Forms.CheckBox
$script:ChkAutoScroll.Text = 'Автопрокрутка'
$script:ChkAutoScroll.AutoSize = $true
$script:ChkAutoScroll.Checked = $true
$script:ChkAutoScroll.Font = $script:FontUi
$script:ChkAutoScroll.ForeColor = $script:ClrText
$script:ChkAutoScroll.Margin = New-Object Windows.Forms.Padding(4, 6, 8, 2)

[void]$logButtons.Controls.Add($script:BtnOpenData)
[void]$logButtons.Controls.Add($script:BtnSaveLog)
[void]$logButtons.Controls.Add($script:BtnClearLog)
[void]$logButtons.Controls.Add($script:ChkAutoScroll)

$logTable.Controls.Add($script:RtbLog, 0, 0)
$logTable.Controls.Add($logButtons, 0, 1)
$logGroup.Controls.Add($logTable)
$rootLayout.Controls.Add($logGroup, 0, 4)

# ---------------------------------------------------------------------------
#  Строка состояния
# ---------------------------------------------------------------------------
$statusStrip = New-Object Windows.Forms.StatusStrip
$statusStrip.Dock = 'Fill'
$statusStrip.SizingGrip = $false
$statusStrip.BackColor = $script:ClrCard

$script:StatusLabel = New-Object Windows.Forms.ToolStripStatusLabel
$script:StatusLabel.Text = 'Готово'
$script:StatusLabel.Spring = $true
$script:StatusLabel.TextAlign = 'MiddleLeft'

$versionItem = New-Object Windows.Forms.ToolStripStatusLabel
$versionItem.Text = 'Zapret Control ' + $script:ZC_AppVersion + ' · форк Bugulmek'
$versionItem.ForeColor = $script:ClrMuted

[void]$statusStrip.Items.Add($script:StatusLabel)
[void]$statusStrip.Items.Add($versionItem)
$rootLayout.Controls.Add($statusStrip, 0, 5)
# ---------------------------------------------------------------------------
#  ВКЛАДКИ
# ---------------------------------------------------------------------------
function New-TabPage {
    param([string]$Title)
    $page = New-Object Windows.Forms.TabPage
    $page.Text = '  ' + $Title + '  '
    $page.BackColor = $script:ClrCard
    $page.Padding = New-Object Windows.Forms.Padding(12)
    $page.AutoScroll = $true
    $page.Font = $script:FontUi
    return $page
}

$tabs = New-Object Windows.Forms.TabControl
$tabs.Dock = 'Fill'
$tabs.Font = $script:FontUi
$tabs.Margin = New-Object Windows.Forms.Padding(4, 0, 0, 0)
$bodyLayout.Controls.Add($tabs, 1, 0)

# --- Вкладка: Служба -------------------------------------------------------
$pageService = New-TabPage 'Служба'
$tabs.TabPages.Add($pageService)

$grpService = New-Object Windows.Forms.GroupBox
$grpService.Text = ' Служба Windows «zapret» '
$grpService.Location = New-Object Drawing.Point(12, 12)
$grpService.Size = New-Object Drawing.Size(760, 164)
$grpService.Anchor = 'Top,Left,Right'
$grpService.BackColor = $script:ClrCard
$grpService.ForeColor = $script:ClrText
$grpService.Font = $script:FontUiBold

$lblServiceInfo = New-UiLabel -Text 'Служба устанавливает выбранную стратегию слева и запускает её автоматически при старте Windows (до входа в систему).' -X 14 -Y 24 -Width 720 -Height 32 -Font $script:FontUi -Color $script:ClrText

$script:ChkAutostart = New-Object Windows.Forms.CheckBox
$script:ChkAutostart.Text = 'Запускать службу автоматически при старте Windows'
$script:ChkAutostart.Location = New-Object Drawing.Point(14, 60)
$script:ChkAutostart.Size = New-Object Drawing.Size(520, 22)
$script:ChkAutostart.Font = $script:FontUi
$script:ChkAutostart.ForeColor = $script:ClrText

$script:BtnRestartService = New-StyledButton -Text 'Перезапустить' -Width 160 -Height 34
$script:BtnRestartService.Location = New-Object Drawing.Point(14, 100)
$script:BtnRemoveService = New-StyledButton -Text 'Удалить службу' -Width 160 -Height 34 -Kind 'danger'
$script:BtnRemoveService.Location = New-Object Drawing.Point(184, 100)
$script:BtnServiceBat = New-StyledButton -Text 'Меню service.bat' -Width 160 -Height 34
$script:BtnServiceBat.Location = New-Object Drawing.Point(354, 100)
$script:BtnOpenRoot = New-StyledButton -Text 'Папка zapret' -Width 160 -Height 34
$script:BtnOpenRoot.Location = New-Object Drawing.Point(524, 100)

$grpService.Controls.AddRange(@($lblServiceInfo, $script:ChkAutostart, $script:BtnRestartService,
    $script:BtnRemoveService, $script:BtnServiceBat, $script:BtnOpenRoot))

$grpHelp = New-Object Windows.Forms.GroupBox
$grpHelp.Text = ' Как это работает '
$grpHelp.Location = New-Object Drawing.Point(12, 186)
$grpHelp.Size = New-Object Drawing.Size(760, 250)
$grpHelp.Anchor = 'Top,Left,Right'
$grpHelp.BackColor = $script:ClrCard
$grpHelp.ForeColor = $script:ClrText
$grpHelp.Font = $script:FontUiBold

$helpText = New-Object Windows.Forms.TextBox
$helpText.Multiline = $true
$helpText.ReadOnly = $true
$helpText.BorderStyle = 'None'
$helpText.BackColor = $script:ClrCard
$helpText.ForeColor = $script:ClrText
$helpText.Font = $script:FontUi
$helpText.ScrollBars = 'Vertical'
$helpText.Dock = 'Fill'
$helpText.Text = @'
Запуск без службы
  Выберите стратегию слева и нажмите «Запустить». winws.exe будет запущен
  в фоне, настройки возьмутся из выбранного general*.bat.

Служба Windows
  «Установить службу» создаёт службу zapret с выбранной стратегией и
  автозапуском. Служба работает до входа в систему и переживает перезагрузку.
  Перед установкой службы запущенный вручную winws.exe останавливается.

Смена настроек
  Игровой фильтр и IPSet хранятся в файлах. Чтобы изменения применились,
  службу нужно переустановить, а ручной запуск — перезапустить.
  GUI предложит это сделать автоматически.

Важно
  Одновременно должен работать только один экземпляр zapret. Служба и ручной
  запуск конфликтуют между собой — это нормально, GUI предупредит.
'@

$grpHelp.Controls.Add($helpText)
$pageService.Controls.Add($grpService)
$pageService.Controls.Add($grpHelp)

# --- Вкладка: Настройки ----------------------------------------------------
$pageSettings = New-TabPage 'Настройки'
$tabs.TabPages.Add($pageSettings)

# Игровой фильтр
$grpGame = New-Object Windows.Forms.GroupBox
$grpGame.Text = ' Игровой фильтр (Game Filter) '
$grpGame.Location = New-Object Drawing.Point(12, 12)
$grpGame.Size = New-Object Drawing.Size(760, 146)
$grpGame.Anchor = 'Top,Left,Right'
$grpGame.BackColor = $script:ClrCard
$grpGame.ForeColor = $script:ClrText
$grpGame.Font = $script:FontUiBold

$lblGameMode = New-UiLabel -Text 'Режим:' -X 14 -Y 26 -Width 100 -Height 18 -Font $script:FontSmall -Color $script:ClrMuted
$script:CbGameMode = New-Object Windows.Forms.ComboBox
$script:CbGameMode.Location = New-Object Drawing.Point(14, 46)
$script:CbGameMode.Size = New-Object Drawing.Size(180, 24)
$script:CbGameMode.DropDownStyle = 'DropDownList'
$script:CbGameMode.Font = $script:FontUi
[void]$script:CbGameMode.Items.Add('Выключен')
[void]$script:CbGameMode.Items.Add('TCP и UDP')
[void]$script:CbGameMode.Items.Add('Только TCP')
[void]$script:CbGameMode.Items.Add('Только UDP')
$script:CbGameMode.SelectedIndex = 0

$lblGameTcp = New-UiLabel -Text 'TCP-порты:' -X 210 -Y 26 -Width 160 -Height 18 -Font $script:FontSmall -Color $script:ClrMuted
$script:TxtGameTcp = New-Object Windows.Forms.TextBox
$script:TxtGameTcp.Location = New-Object Drawing.Point(210, 46)
$script:TxtGameTcp.Size = New-Object Drawing.Size(160, 24)
$script:TxtGameTcp.Font = $script:FontUi
$script:TxtGameTcp.Text = '1024-65535'

$lblGameUdp = New-UiLabel -Text 'UDP-порты:' -X 386 -Y 26 -Width 160 -Height 18 -Font $script:FontSmall -Color $script:ClrMuted
$script:TxtGameUdp = New-Object Windows.Forms.TextBox
$script:TxtGameUdp.Location = New-Object Drawing.Point(386, 46)
$script:TxtGameUdp.Size = New-Object Drawing.Size(160, 24)
$script:TxtGameUdp.Font = $script:FontUi
$script:TxtGameUdp.Text = '1024-65535'

$script:BtnApplyGame = New-StyledButton -Text 'Применить' -Width 120 -Height 30 -Kind 'primary'
$script:BtnApplyGame.Location = New-Object Drawing.Point(560, 44)

$gameHint = New-UiLabel -Text 'Формат: 1024-65535 или 1024-1934,1936-65535. Изменения применяются после перезапуска/переустановки zapret.' -X 14 -Y 88 -Width 730 -Height 36 -Font $script:FontSmall -Color $script:ClrMuted

$grpGame.Controls.AddRange(@($lblGameMode, $script:CbGameMode, $lblGameTcp, $script:TxtGameTcp,
    $lblGameUdp, $script:TxtGameUdp, $script:BtnApplyGame, $gameHint))

# IPSet
$grpIpset = New-Object Windows.Forms.GroupBox
$grpIpset.Text = ' IPSet-фильтр '
$grpIpset.Location = New-Object Drawing.Point(12, 168)
$grpIpset.Size = New-Object Drawing.Size(760, 126)
$grpIpset.Anchor = 'Top,Left,Right'
$grpIpset.BackColor = $script:ClrCard
$grpIpset.ForeColor = $script:ClrText
$grpIpset.Font = $script:FontUiBold

$lblIpsetMode = New-UiLabel -Text 'Режим IPSet:' -X 14 -Y 26 -Width 160 -Height 18 -Font $script:FontSmall -Color $script:ClrMuted
$script:CbIpset = New-Object Windows.Forms.ComboBox
$script:CbIpset.Location = New-Object Drawing.Point(14, 46)
$script:CbIpset.Size = New-Object Drawing.Size(220, 24)
$script:CbIpset.DropDownStyle = 'DropDownList'
$script:CbIpset.Font = $script:FontUi
[void]$script:CbIpset.Items.Add('Любой (any)')
[void]$script:CbIpset.Items.Add('Отключён (none)')
[void]$script:CbIpset.Items.Add('Загружен (loaded)')
$script:CbIpset.SelectedIndex = 0

$script:BtnApplyIpset = New-StyledButton -Text 'Применить' -Width 110 -Height 30 -Kind 'primary'
$script:BtnApplyIpset.Location = New-Object Drawing.Point(246, 44)
$script:BtnUpdateIpset = New-StyledButton -Text 'Обновить IPSet' -Width 150 -Height 30
$script:BtnUpdateIpset.Location = New-Object Drawing.Point(366, 44)

$ipsetHint = New-UiLabel -Text 'loaded — фильтр по списку, none — только исключения, any — без списка IPSet. Обновление скачивает свежий список с GitHub.' -X 14 -Y 86 -Width 730 -Height 30 -Font $script:FontSmall -Color $script:ClrMuted

$grpIpset.Controls.AddRange(@($lblIpsetMode, $script:CbIpset, $script:BtnApplyIpset, $script:BtnUpdateIpset, $ipsetHint))

# Автопроверка .bat
$grpBatUpdates = New-Object Windows.Forms.GroupBox
$grpBatUpdates.Text = ' Автопроверка обновлений пакета '
$grpBatUpdates.Location = New-Object Drawing.Point(12, 304)
$grpBatUpdates.Size = New-Object Drawing.Size(760, 92)
$grpBatUpdates.Anchor = 'Top,Left,Right'
$grpBatUpdates.BackColor = $script:ClrCard
$grpBatUpdates.ForeColor = $script:ClrText
$grpBatUpdates.Font = $script:FontUiBold

$script:ChkBatUpdates = New-Object Windows.Forms.CheckBox
$script:ChkBatUpdates.Text = 'Проверять обновления при запуске general*.bat (utils\check_updates.enabled)'
$script:ChkBatUpdates.Location = New-Object Drawing.Point(14, 24)
$script:ChkBatUpdates.Size = New-Object Drawing.Size(700, 22)
$script:ChkBatUpdates.Font = $script:FontUi
$script:ChkBatUpdates.ForeColor = $script:ClrText

$batUpdatesHint = New-UiLabel -Text 'Это встроенная проверка пакета zapret. Автообновление самого zapret — на вкладке «Обновление».' -X 14 -Y 54 -Width 720 -Height 24 -Font $script:FontSmall -Color $script:ClrMuted

$grpBatUpdates.Controls.AddRange(@($script:ChkBatUpdates, $batUpdatesHint))

# Пользовательские списки
$grpUserLists = New-Object Windows.Forms.GroupBox
$grpUserLists.Text = ' Пользовательские списки '
$grpUserLists.Location = New-Object Drawing.Point(12, 406)
$grpUserLists.Size = New-Object Drawing.Size(760, 118)
$grpUserLists.Anchor = 'Top,Left,Right'
$grpUserLists.BackColor = $script:ClrCard
$grpUserLists.ForeColor = $script:ClrText
$grpUserLists.Font = $script:FontUiBold

$userListsHint = New-UiLabel -Text 'Добавляйте свои домены и IP в файлы *-user.txt. Файлы откроются в Блокноте.' -X 14 -Y 24 -Width 720 -Height 20 -Font $script:FontSmall -Color $script:ClrMuted

$script:BtnListGeneral = New-StyledButton -Text 'Общие домены' -Width 160 -Height 34
$script:BtnListGeneral.Location = New-Object Drawing.Point(14, 52)
$script:BtnListExclude = New-StyledButton -Text 'Исключения' -Width 160 -Height 34
$script:BtnListExclude.Location = New-Object Drawing.Point(184, 52)
$script:BtnListIpset = New-StyledButton -Text 'IP-исключения' -Width 160 -Height 34
$script:BtnListIpset.Location = New-Object Drawing.Point(354, 52)
$script:BtnListFolder = New-StyledButton -Text 'Папка lists' -Width 160 -Height 34
$script:BtnListFolder.Location = New-Object Drawing.Point(524, 52)

$grpUserLists.Controls.AddRange(@($userListsHint, $script:BtnListGeneral, $script:BtnListExclude, $script:BtnListIpset, $script:BtnListFolder))

$pageSettings.Controls.Add($grpGame)
$pageSettings.Controls.Add($grpIpset)
$pageSettings.Controls.Add($grpBatUpdates)
$pageSettings.Controls.Add($grpUserLists)

# --- Вкладка: Инструменты --------------------------------------------------
$pageTools = New-TabPage 'Инструменты'
$tabs.TabPages.Add($pageTools)

$toolsTitle = New-UiLabel -Text 'Сервисные действия' -X 12 -Y 8 -Width 400 -Height 26 -Font (New-Object Drawing.Font('Segoe UI', 12, [Drawing.FontStyle]::Bold)) -Color $script:ClrText
$toolsHint = New-UiLabel -Text 'Результат выполнения всех инструментов и диагностики выводится в журнал внизу окна.' -X 12 -Y 36 -Width 720 -Height 20 -Font $script:FontSmall -Color $script:ClrMuted

$script:BtnToolIpset = New-StyledButton -Text 'Обновить IPSet' -Width 200 -Height 44
$script:BtnToolIpset.Location = New-Object Drawing.Point(12, 70)
$script:BtnToolHosts = New-StyledButton -Text 'Обновить hosts' -Width 200 -Height 44
$script:BtnToolHosts.Location = New-Object Drawing.Point(224, 70)
$script:BtnToolDiag = New-StyledButton -Text 'Диагностика' -Width 200 -Height 44 -Kind 'primary'
$script:BtnToolDiag.Location = New-Object Drawing.Point(436, 70)
$script:BtnToolFakes = New-StyledButton -Text 'Заменить active fake' -Width 200 -Height 44
$script:BtnToolFakes.Location = New-Object Drawing.Point(12, 126)
$script:BtnToolDiscord = New-StyledButton -Text 'Очистить кэш Discord' -Width 200 -Height 44
$script:BtnToolDiscord.Location = New-Object Drawing.Point(224, 126)
$script:BtnToolWinDivert = New-StyledButton -Text 'Убрать конфликт WinDivert' -Width 200 -Height 44
$script:BtnToolWinDivert.Location = New-Object Drawing.Point(436, 126)
$script:BtnToolOpenRoot = New-StyledButton -Text 'Открыть папку zapret' -Width 200 -Height 44
$script:BtnToolOpenRoot.Location = New-Object Drawing.Point(12, 182)
$script:BtnToolOpenData = New-StyledButton -Text 'Открыть папку данных' -Width 200 -Height 44
$script:BtnToolOpenData.Location = New-Object Drawing.Point(224, 182)
$script:BtnToolServiceBat = New-StyledButton -Text 'Меню service.bat' -Width 200 -Height 44
$script:BtnToolServiceBat.Location = New-Object Drawing.Point(436, 182)

$toolNote = New-UiLabel -Text '«Меню service.bat» открывает штатное консольное меню пакета — на случай, если нужна функция, которой нет в GUI.' -X 12 -Y 246 -Width 720 -Height 40 -Font $script:FontSmall -Color $script:ClrMuted

$pageTools.Controls.AddRange(@($toolsTitle, $toolsHint, $script:BtnToolIpset, $script:BtnToolHosts,
    $script:BtnToolDiag, $script:BtnToolFakes, $script:BtnToolDiscord, $script:BtnToolWinDivert,
    $script:BtnToolOpenRoot, $script:BtnToolOpenData, $script:BtnToolServiceBat, $toolNote))

# --- Вкладка: Тест стратегий ----------------------------------------------
$pageTests = New-TabPage 'Тест стратегий'
$tabs.TabPages.Add($pageTests)

$testsTitle = New-UiLabel -Text 'Тест стратегий' -X 12 -Y 8 -Width 400 -Height 30 -Font (New-Object Drawing.Font('Segoe UI', 13, [Drawing.FontStyle]::Bold)) -Color $script:ClrText
$testsDescription = New-UiLabel -Text ("Запускает штатный тест из utils\test zapret.ps1 — тот же, что пункт 12 меню service.bat.`r`n`r`nТест по очереди запускает стратегии и проверяет доступность Discord, YouTube и других целей. Может занять несколько минут. Результаты сохраняются в папку utils\test results.`r`n`r`nПеред тестом служба zapret должна быть удалена, а winws.exe — остановлен. GUI предупредит и сделает это сам.") -X 12 -Y 46 -Width 720 -Height 120 -Font $script:FontUi -Color $script:ClrText

$script:BtnRunTests = New-StyledButton -Text '▶ Запустить тест стратегий' -Width 280 -Height 46 -Kind 'primary'
$script:BtnRunTests.Location = New-Object Drawing.Point(12, 180)
$script:BtnTestResults = New-StyledButton -Text 'Открыть папку результатов' -Width 240 -Height 46
$script:BtnTestResults.Location = New-Object Drawing.Point(304, 180)

$quickTitle = New-UiLabel -Text 'Быстрая проверка текущего соединения' -X 12 -Y 250 -Width 500 -Height 24 -Font $script:FontUiBold -Color $script:ClrText
$quickDescription = New-UiLabel -Text 'Проверяет Discord, YouTube, Google и Cloudflare через curl. Полезно, чтобы понять, работает ли уже запущенная стратегия.' -X 12 -Y 276 -Width 720 -Height 34 -Font $script:FontSmall -Color $script:ClrMuted
$script:BtnQuickCheck = New-StyledButton -Text 'Проверить соединение' -Width 240 -Height 40
$script:BtnQuickCheck.Location = New-Object Drawing.Point(12, 316)

$pageTests.Controls.AddRange(@($testsTitle, $testsDescription, $script:BtnRunTests, $script:BtnTestResults,
    $quickTitle, $quickDescription, $script:BtnQuickCheck))

# --- Вкладка: Обновление ---------------------------------------------------
$pageUpdate = New-TabPage 'Обновление'
$tabs.TabPages.Add($pageUpdate)

$updateTitle = New-UiLabel -Text 'Обновление zapret с GitHub' -X 12 -Y 8 -Width 500 -Height 30 -Font (New-Object Drawing.Font('Segoe UI', 13, [Drawing.FontStyle]::Bold)) -Color $script:ClrText
$updateSource = New-UiLabel -Text 'Источник: github.com/Flowseal/zapret-discord-youtube · GUI / форк: Bugulmek' -X 12 -Y 38 -Width 720 -Height 20 -Font $script:FontSmall -Color $script:ClrMuted

$script:LblUpdateLocal = New-UiLabel -Text 'Установленная версия: —' -X 14 -Y 68 -Width 720 -Height 20 -Font $script:FontUi -Color $script:ClrText
$script:LblUpdateLatest = New-UiLabel -Text 'Последняя на GitHub: —' -X 14 -Y 90 -Width 720 -Height 20 -Font $script:FontUi -Color $script:ClrText
$script:LblUpdateStatus = New-UiLabel -Text 'Проверка ещё не выполнялась' -X 14 -Y 116 -Width 720 -Height 24 -Font $script:FontUiBold -Color $script:ClrMuted

$script:BtnCheckUpdates = New-StyledButton -Text 'Проверить обновления' -Width 190 -Height 36 -Kind 'primary'
$script:BtnCheckUpdates.Location = New-Object Drawing.Point(14, 146)
$script:BtnInstallUpdate = New-StyledButton -Text 'Скачать и установить' -Width 190 -Height 36 -Kind 'success'
$script:BtnInstallUpdate.Location = New-Object Drawing.Point(214, 146)
$script:BtnInstallUpdate.Enabled = $false

$linkReleases = New-Object Windows.Forms.LinkLabel
$linkReleases.Text = 'Страница релизов на GitHub'
$linkReleases.Location = New-Object Drawing.Point(420, 154)
$linkReleases.Size = New-Object Drawing.Size(280, 20)
$linkReleases.Font = $script:FontUi
$linkReleases.LinkColor = $script:ClrAccent

$script:ChkStartupUpdates = New-Object Windows.Forms.CheckBox
$script:ChkStartupUpdates.Text = 'Проверять обновления при запуске GUI'
$script:ChkStartupUpdates.Location = New-Object Drawing.Point(14, 194)
$script:ChkStartupUpdates.Size = New-Object Drawing.Size(500, 22)
$script:ChkStartupUpdates.Font = $script:FontUi
$script:ChkStartupUpdates.ForeColor = $script:ClrText
$script:ChkStartupUpdates.Checked = $true

$notesLabel = New-UiLabel -Text 'Описание релиза:' -X 14 -Y 226 -Width 300 -Height 20 -Font $script:FontUiBold -Color $script:ClrText

$script:TxtReleaseNotes = New-Object Windows.Forms.TextBox
$script:TxtReleaseNotes.Location = New-Object Drawing.Point(14, 248)
$script:TxtReleaseNotes.Size = New-Object Drawing.Size(740, 270)
$script:TxtReleaseNotes.Anchor = 'Top,Left,Right'
$script:TxtReleaseNotes.Multiline = $true
$script:TxtReleaseNotes.ReadOnly = $true
$script:TxtReleaseNotes.ScrollBars = 'Vertical'
$script:TxtReleaseNotes.BackColor = [Drawing.Color]::White
$script:TxtReleaseNotes.ForeColor = $script:ClrText
$script:TxtReleaseNotes.Font = $script:FontUi
$script:TxtReleaseNotes.Text = 'Нажмите «Проверить обновления», чтобы получить информацию с GitHub.'

$pageUpdate.Controls.AddRange(@($updateTitle, $updateSource, $script:LblUpdateLocal, $script:LblUpdateLatest,
    $script:LblUpdateStatus, $script:BtnCheckUpdates, $script:BtnInstallUpdate, $linkReleases,
    $script:ChkStartupUpdates, $notesLabel, $script:TxtReleaseNotes))
# ---------------------------------------------------------------------------
#  Вспомогательные действия интерфейса
# ---------------------------------------------------------------------------
function Open-ServiceBatMenu {
    $bat = Join-Path $script:ZapretRoot 'service.bat'
    if (-not (Test-Path -LiteralPath $bat)) {
        Show-UiError 'service.bat не найден в папке zapret.'
        return
    }
    try {
        Start-Process -FilePath $bat -ArgumentList 'admin' -WorkingDirectory $script:ZapretRoot | Out-Null
    } catch {
        Show-UiError $_.Exception.Message
    }
}

function Open-DataFolder {
    Open-Folder $script:DataDir
}

function Open-TestResultsFolder {
    $dir = Join-Path $script:ZapretRoot 'utils\test results'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Open-Folder $dir
}

function Choose-ZapretFolder {
    $dialog = New-Object Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Укажите папку zapret (в ней должны быть service.bat и bin\winws.exe)'
    $dialog.ShowNewFolderButton = $false
    if ($dialog.ShowDialog($script:Form) -ne [Windows.Forms.DialogResult]::OK) { return }

    $candidate = $dialog.SelectedPath
    if (-not (Test-Path -LiteralPath (Join-Path $candidate 'bin\winws.exe'))) {
        Show-UiError 'В выбранной папке нет bin\winws.exe.'
        return
    }

    $script:ZapretRoot = (Resolve-Path -LiteralPath $candidate).Path
    $script:Config.ZapretRoot = $script:ZapretRoot
    $script:Config.SelectedStrategy = ''
    Save-Config

    Refresh-StrategyList
    Load-SettingsIntoUi
    Update-AllStatus
    $script:LblUpdateStatus.Text = 'Проверка ещё не выполнялась'
    $script:LblUpdateStatus.ForeColor = $script:ClrMuted
    $script:LatestRelease = $null
    $script:UpdateAvailable = $false
    $script:BtnInstallUpdate.Enabled = $false
    Write-UiLog ('Папка zapret изменена: ' + $script:ZapretRoot) 'Green'
}

function Invoke-UiSafe {
    param([scriptblock]$Action)
    try {
        & $Action
    } catch {
        Write-UiLog ('Ошибка: ' + $_.Exception.Message) 'Red'
        Show-UiError $_.Exception.Message
    } finally {
        Update-AllStatus
    }
}

# ---------------------------------------------------------------------------
#  События: стратегии
# ---------------------------------------------------------------------------
$script:BtnStart.Add_Click({
    Invoke-UiSafe { Start-SelectedStrategyAction }
})
$script:BtnStop.Add_Click({
    Invoke-UiSafe { Stop-ZapretAction }
})
$script:BtnInstall.Add_Click({
    Invoke-UiSafe { Install-ServiceAction }
})
$script:BtnRemove.Add_Click({
    Invoke-UiSafe { Remove-ServiceAction }
})

$script:LstStrategies.Add_SelectedIndexChanged({
    if ($script:LstStrategies.SelectedItem) {
        $script:Config.SelectedStrategy = [string]$script:LstStrategies.SelectedItem
        Save-Config
    }
})
$script:LstStrategies.Add_DoubleClick({
    Invoke-UiSafe { Start-SelectedStrategyAction }
})

# ---------------------------------------------------------------------------
#  События: служба
# ---------------------------------------------------------------------------
$script:BtnRestartService.Add_Click({
    Invoke-UiSafe { Restart-ServiceAction }
})
$script:BtnServiceBat.Add_Click({
    Invoke-UiSafe { Open-ServiceBatMenu }
})
$script:BtnOpenRoot.Add_Click({
    Invoke-UiSafe { Open-Folder $script:ZapretRoot }
})
$script:ChkAutostart.Add_CheckedChanged({
    Invoke-UiSafe { Set-AutostartAction }
})

# ---------------------------------------------------------------------------
#  События: настройки
# ---------------------------------------------------------------------------
$script:BtnApplyGame.Add_Click({
    Invoke-UiSafe { Apply-GameFilterAction }
})
$script:BtnApplyIpset.Add_Click({
    Invoke-UiSafe { Apply-IpsetAction }
})
$script:BtnUpdateIpset.Add_Click({
    Invoke-UiSafe { Update-IpsetAction }
})
$script:ChkBatUpdates.Add_CheckedChanged({
    Invoke-UiSafe { Set-BatUpdatesAction }
})
$script:BtnListGeneral.Add_Click({
    Invoke-UiSafe { Open-UserList 'list-general-user.txt' }
})
$script:BtnListExclude.Add_Click({
    Invoke-UiSafe { Open-UserList 'list-exclude-user.txt' }
})
$script:BtnListIpset.Add_Click({
    Invoke-UiSafe { Open-UserList 'ipset-exclude-user.txt' }
})
$script:BtnListFolder.Add_Click({
    Invoke-UiSafe { Open-Folder (Join-Path $script:ZapretRoot 'lists') }
})

# ---------------------------------------------------------------------------
#  События: инструменты
# ---------------------------------------------------------------------------
$script:BtnToolIpset.Add_Click({
    Invoke-UiSafe { Update-IpsetAction }
})
$script:BtnToolHosts.Add_Click({
    Invoke-UiSafe { Update-HostsAction }
})
$script:BtnToolDiag.Add_Click({
    try {
        Set-BusyStatus 'Диагностика...'
        Run-DiagnosticsAction
    } catch {
        Write-UiLog ('Ошибка диагностики: ' + $_.Exception.Message) 'Red'
        Show-UiError $_.Exception.Message
    } finally {
        Set-BusyStatus 'Готово'
        Update-AllStatus
    }
})
$script:BtnToolFakes.Add_Click({
    Invoke-UiSafe { Open-FakesDialog }
})
$script:BtnToolDiscord.Add_Click({
    Invoke-UiSafe {
        if (Confirm-Ui 'Очистить кэш Discord? Приложения Discord будут закрыты.' 'Очистка кэша Discord') {
            Clear-DiscordCacheInternal
        }
    }
})
$script:BtnToolWinDivert.Add_Click({
    Invoke-UiSafe {
        if (Confirm-Ui "Остановить и удалить службы WinDivert / WinDivert14?`n`nЭто помогает, если zapret не запускается из-за конфликта драйвера." 'WinDivert') {
            Remove-WinDivertLeftovers
            Start-Sleep -Milliseconds 400
        }
    }
})
$script:BtnToolOpenRoot.Add_Click({
    Invoke-UiSafe { Open-Folder $script:ZapretRoot }
})
$script:BtnToolOpenData.Add_Click({
    Invoke-UiSafe { Open-DataFolder }
})
$script:BtnToolServiceBat.Add_Click({
    Invoke-UiSafe { Open-ServiceBatMenu }
})

# ---------------------------------------------------------------------------
#  События: тесты
# ---------------------------------------------------------------------------
$script:BtnRunTests.Add_Click({
    Invoke-UiSafe { Run-StrategyTestsAction }
})
$script:BtnTestResults.Add_Click({
    Invoke-UiSafe { Open-TestResultsFolder }
})
$script:BtnQuickCheck.Add_Click({
    Invoke-UiSafe { Quick-CheckAction }
})

# ---------------------------------------------------------------------------
#  События: обновление
# ---------------------------------------------------------------------------
$script:BtnCheckUpdates.Add_Click({
    Invoke-UiSafe { Check-UpdatesAction }
})
$script:BtnInstallUpdate.Add_Click({
    Invoke-UiSafe { Install-UpdateAction }
})
$script:ChkStartupUpdates.Add_CheckedChanged({
    $script:Config.CheckUpdatesOnStart = [bool]$script:ChkStartupUpdates.Checked
    Save-Config
})
$linkReleases.Add_LinkClicked({
    try { Start-Process -FilePath $script:ZC_ReleasesPage | Out-Null } catch { }
})

# ---------------------------------------------------------------------------
#  События: журнал
# ---------------------------------------------------------------------------
$script:BtnClearLog.Add_Click({
    $script:RtbLog.Clear()
})
$script:BtnSaveLog.Add_Click({
    try {
        $dialog = New-Object Windows.Forms.SaveFileDialog
        $dialog.Filter = 'Текстовый файл (*.txt)|*.txt|Все файлы (*.*)|*.*'
        $dialog.FileName = 'zapret-control-log.txt'
        if ($dialog.ShowDialog($script:Form) -eq [Windows.Forms.DialogResult]::OK) {
            [IO.File]::WriteAllText($dialog.FileName, $script:RtbLog.Text, (New-Object Text.UTF8Encoding($true)))
            Write-UiLog ('Журнал сохранён: ' + $dialog.FileName) 'Green'
        }
    } catch { }
})
$script:BtnOpenData.Add_Click({
    Invoke-UiSafe { Open-DataFolder }
})

# ---------------------------------------------------------------------------
#  События: меню
# ---------------------------------------------------------------------------
$script:MiChooseFolder.Add_Click({
    Invoke-UiSafe { Choose-ZapretFolder }
})
$script:MiOpenRoot.Add_Click({
    Invoke-UiSafe { Open-Folder $script:ZapretRoot }
})
$script:MiExit.Add_Click({
    $script:Form.Close()
})
$script:MiInstallService.Add_Click({
    Invoke-UiSafe { Install-ServiceAction }
})
$script:MiRemoveService.Add_Click({
    Invoke-UiSafe { Remove-ServiceAction }
})
$script:MiRestartService.Add_Click({
    Invoke-UiSafe { Restart-ServiceAction }
})
$script:MiDiagnostics.Add_Click({
    Invoke-UiSafe { Run-DiagnosticsAction }
})
$script:MiTests.Add_Click({
    Invoke-UiSafe { Run-StrategyTestsAction }
})
$script:MiAbout.Add_Click({
    Invoke-UiSafe { Show-About }
})
$script:MiGithub.Add_Click({
    try { Start-Process -FilePath $script:ZC_ReleasesPage | Out-Null } catch { }
})

# ---------------------------------------------------------------------------
#  Начальная инициализация
# ---------------------------------------------------------------------------
$script:ChkStartupUpdates.Checked = [bool]$script:Config.CheckUpdatesOnStart

Refresh-StrategyList
Load-SettingsIntoUi
Update-AllStatus

Write-UiLog ('Zapret Control ' + $script:ZC_AppVersion + ' запущен') 'Cyan'
Write-UiLog ('Папка zapret: ' + $script:ZapretRoot) 'Gray'
Write-UiLog ('Версия пакета: ' + (Get-LocalZapretVersion -Root $script:ZapretRoot)) 'Gray'
Write-UiLog 'Права администратора: да' 'Green'
if (@(Get-WinwsProcesses).Count -gt 0) {
    Write-UiLog 'winws.exe уже запущен.' 'Green'
}
if (Get-Service -Name 'zapret' -ErrorAction SilentlyContinue) {
    Write-UiLog 'Служба zapret установлена.' 'Gray'
}

# Главный таймер: статус + журнал winws
$script:MainTimer = New-Object Windows.Forms.Timer
$script:MainTimer.Interval = 2000
$script:MainTimer.Add_Tick({
    try { Update-AllStatus } catch { }
    try { Read-WinwsLog } catch { }
})
$script:MainTimer.Start()

# Проверка обновлений при запуске (один раз, после появления окна)
$script:StartupTimer = New-Object Windows.Forms.Timer
$script:StartupTimer.Interval = 900
$script:StartupTimer.Add_Tick({
    $script:StartupTimer.Stop()
    try {
        if ($script:Config.CheckUpdatesOnStart -and -not $Preview) { Check-UpdatesAction -Silent }
    } catch { }
})
$script:StartupTimer.Start()

$script:Form.Add_FormClosing({
    try { $script:MainTimer.Stop() } catch { }
    Save-Config
})

if ($Preview) {
    $script:PreviewTimer = New-Object Windows.Forms.Timer
    $script:PreviewTimer.Interval = 1500
    $script:PreviewTimer.Add_Tick({
        $script:PreviewTimer.Stop()
        $script:Form.Close()
    })
    $script:PreviewTimer.Start()
    Write-Output 'UI PREVIEW STARTED'
}

try {
    [Windows.Forms.Application]::Run($script:Form)
} catch {
    Show-UiError ('Критическая ошибка интерфейса:' + "`n" + $_.Exception.Message)
} finally {
    Save-Config
}

if ($Preview) {
    Write-Output 'UI PREVIEW OK'
}
