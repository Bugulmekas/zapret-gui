# ============================================================================
#  Zapret Control - общие функции
#  GUI / форк: Bugulmek
#  Пакет zapret: Flowseal
#  https://github.com/Flowseal/zapret-discord-youtube
# ============================================================================

$script:ZC_AppName      = 'Zapret Control'
$script:ZC_AppVersion   = '2.1.0'
$script:ZC_GuiRepo      = 'Bugulmekas/zapret-gui'
$script:ZC_GuiReleasesApi  = 'https://api.github.com/repos/Bugulmekas/zapret-gui/releases/latest'
$script:ZC_GuiReleasesPage = 'https://github.com/Bugulmekas/zapret-gui/releases/latest'
$script:ZC_UpstreamRepo = 'Flowseal/zapret-discord-youtube'
$script:ZC_ReleasesApi  = 'https://api.github.com/repos/Flowseal/zapret-discord-youtube/releases/latest'
$script:ZC_ReleasesPage = 'https://github.com/Flowseal/zapret-discord-youtube/releases/latest'
$script:ZC_IpsetUrl     = 'https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/refs/heads/main/.service/ipset-service.txt'
$script:ZC_HostsUrl     = 'https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/refs/heads/main/.service/hosts'
$script:ZC_VersionCache = @{}
$script:ZC_AppRoot      = $PSScriptRoot
# Файлы, которые заменяет самообновление GUI, и лимит истории резервных копий.
$script:ZC_GuiFiles     = @('ZapretControl.ps1', 'ZapretCommon.ps1', 'ZapretControl.bat')
$script:ZC_MaxGuiBackups = 3

# ---------------------------------------------------------------------------
#  Права / пути
# ---------------------------------------------------------------------------
function Test-IsAdmin {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Get-ZapretCandidates {
    param([string]$BaseDir)

    $result = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($BaseDir) -or -not (Test-Path -LiteralPath $BaseDir)) {
        return $result
    }

    if (Test-Path -LiteralPath (Join-Path $BaseDir 'bin\winws.exe')) {
        $result.Add((Resolve-Path -LiteralPath $BaseDir).Path)
    }

    $level1 = @(Get-ChildItem -LiteralPath $BaseDir -Directory -ErrorAction SilentlyContinue)
    foreach ($dir in $level1) {
        if (Test-Path -LiteralPath (Join-Path $dir.FullName 'bin\winws.exe')) {
            $result.Add($dir.FullName)
        }
    }

    foreach ($dir in $level1) {
        $level2 = @(Get-ChildItem -LiteralPath $dir.FullName -Directory -ErrorAction SilentlyContinue)
        foreach ($sub in $level2) {
            if (Test-Path -LiteralPath (Join-Path $sub.FullName 'bin\winws.exe')) {
                $result.Add($sub.FullName)
            }
        }
    }

    return $result
}

function Resolve-ZapretRoot {
    param(
        [string]$Hint,
        [string]$AppDir
    )

    if ($Hint -and (Test-Path -LiteralPath (Join-Path $Hint 'bin\winws.exe'))) {
        return (Resolve-Path -LiteralPath $Hint).Path
    }

    $base = Split-Path -Parent $AppDir
    $candidates = @(Get-ZapretCandidates -BaseDir $base)
    if ($candidates.Count -eq 0) { return $null }
    if ($candidates.Count -eq 1) { return $candidates[0] }

    # Оцениваем каждый кандидат: версия из имени папки + время изменения bin\winws.exe.
    # Свежесть важнее номера в имени: вручную распакованный пакет без версии в имени
    # обычно новее, чем старая версионированная папка, оставшаяся от прошлых обновлений.
    $evaluated = @(foreach ($item in $candidates) {
        $leaf = Split-Path -Leaf $item
        $match = [regex]::Match($leaf, '(\d+(?:\.\d+){1,3})')
        $version = $null
        if ($match.Success) {
            try { $version = [version]$match.Groups[1].Value } catch { $version = $null }
        }

        $stamp = [long]0
        $info = Get-Item -LiteralPath (Join-Path $item 'bin\winws.exe') -ErrorAction SilentlyContinue
        if ($info) { $stamp = $info.LastWriteTimeUtc.Ticks }

        [pscustomobject]@{
            Path    = $item
            Version = $version
            Stamp   = $stamp
        }
    })

    if ($evaluated.Count -eq 0) { return $candidates[0] }

    $ordered = @($evaluated | Sort-Object -Property @(
        @{ Expression = { $_.Stamp }; Descending = $true },
        @{ Expression = { if ($null -ne $_.Version) { $_.Version } else { [version]'0.0' } }; Descending = $true },
        @{ Expression = { $_.Path }; Descending = $false }
    ))

    if ($ordered.Count -eq 0) { return $candidates[0] }
    return $ordered[0].Path
}

# ---------------------------------------------------------------------------
#  Стратегии и аргументы winws.exe
# ---------------------------------------------------------------------------
function Get-Strategies {
    param([string]$Root)

    if (-not (Test-Path -LiteralPath $Root)) { return @() }

    # general.bat — базовая стратегия, её ставим первой, остальные — в естественном порядке.
    $files = @(Get-ChildItem -LiteralPath $Root -Filter '*.bat' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike 'service*' } |
        Sort-Object -Property @(
            @{ Expression = { if ($_.Name -ieq 'general.bat') { 0 } else { 1 } } },
            @{ Expression = { [regex]::Replace($_.Name, '(\d+)', { param($m) $m.Value.PadLeft(8, '0') }) } }
        ))

    return $files
}

function Get-GameFilterState {
    param([string]$Root)

    $state = [pscustomobject]@{
        Mode     = 'disabled'
        Tcp      = '1024-65535'
        Udp      = '1024-65535'
        Enabled  = $false
        FilePath = (Join-Path $Root 'utils\game_filter.enabled')
    }

    if (-not (Test-Path -LiteralPath $state.FilePath)) { return $state }

    $lines = $null
    try {
        $lines = [IO.File]::ReadAllLines($state.FilePath)
    } catch {
        # Файл занят или недоступен: не роняем вызывающий код, работаем как с «выключено».
        $script:ZC_LastGameFilterError = $_.Exception.Message
        Write-Verbose ('game_filter.enabled не прочитан: ' + $_.Exception.Message)
        return $state
    }

    foreach ($line in $lines) {
        if ($line -match '^\s*mode\s*=\s*(\S+)\s*$') {
            $state.Mode = $Matches[1].ToLowerInvariant()
        } elseif ($line -match '^\s*tcp\s*=\s*(\S+)\s*$') {
            if (Test-PortRange -Value $Matches[1]) { $state.Tcp = $Matches[1] }
        } elseif ($line -match '^\s*udp\s*=\s*(\S+)\s*$') {
            if (Test-PortRange -Value $Matches[1]) { $state.Udp = $Matches[1] }
        }
    }

    if (@('all', 'tcp', 'udp') -notcontains $state.Mode) { $state.Mode = 'disabled' }
    $state.Enabled = ($state.Mode -ne 'disabled')
    return $state
}

function Test-PortRange {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    $clean = $Value -replace '\s', ''

    foreach ($part in $clean.Split(',')) {
        if ($part -notmatch '^([1-9]\d{0,4})(?:-([1-9]\d{0,4}))?$') { return $false }
        $start = [int]$Matches[1]
        if ($Matches[2]) { $end = [int]$Matches[2] } else { $end = $start }
        if ($start -gt 65535 -or $end -gt 65535 -or $start -gt $end) { return $false }
    }
    return $true
}

function Get-WinwsArgs {
    param(
        [string]$BatPath,
        [string]$Root
    )

    if (-not (Test-Path -LiteralPath $BatPath)) { return $null }

    $lines = [IO.File]::ReadAllLines($BatPath)
    $argLine = $null

    for ($index = 0; $index -lt $lines.Count; $index++) {
        $line = $lines[$index]
        if ($line -notmatch 'winws\.exe') { continue }

        # Служебные строки тоже содержат winws.exe (tasklist, findstr, "if not exist"),
        # но запуском не являются — их пропускаем.
        if ($line -match '^\s*(rem\b|::|echo\b|set\b|if\b|where\b|tasklist\b|findstr\b|find\b|sc\b|call\b|goto\b)') { continue }

        # Собираем строку запуска вместе с переносами «^» в конце строк.
        $builder = New-Object System.Text.StringBuilder
        for ($next = $index; $next -lt $lines.Count; $next++) {
            $trimmed = $lines[$next].TrimEnd()
            if ($trimmed.EndsWith('^')) {
                [void]$builder.Append($trimmed.Substring(0, $trimmed.Length - 1)).Append(' ')
            } else {
                [void]$builder.Append($trimmed)
                break
            }
        }

        if ($builder.Length -eq 0) { continue }

        $text = $builder.ToString()
        $match = [regex]::Match($text, 'winws\.exe"?\s*(.*)$', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if (-not $match.Success) { continue }

        $candidate = $match.Groups[1].Value.Trim()
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        # Аргументы winws.exe начинаются с «--» или «/»; иначе это не строка запуска.
        if ($candidate -notmatch '^(--|/)') { continue }

        $argLine = $candidate
        break
    }

    if ([string]::IsNullOrWhiteSpace($argLine)) { return $null }

    $gameFilter = Get-GameFilterState -Root $Root
    $tcp = '12'
    $udp = '12'
    $generic = '12'
    switch ($gameFilter.Mode) {
        'all' { $tcp = $gameFilter.Tcp; $udp = $gameFilter.Udp; $generic = $gameFilter.Tcp }
        'tcp' { $tcp = $gameFilter.Tcp; $generic = $gameFilter.Tcp }
        'udp' { $udp = $gameFilter.Udp; $generic = $gameFilter.Udp }
    }

    $rootSlash  = $Root.TrimEnd('\') + '\'
    $binSlash   = (Join-Path $Root 'bin').TrimEnd('\') + '\'
    $listsSlash = (Join-Path $Root 'lists').TrimEnd('\') + '\'

    # В cmd.exe подстановка переменных регистронезависима — повторяем это поведение.
    $argLine = Replace-ZcTextIgnoreCase -Text $argLine -Token '%~dp0' -Value $rootSlash
    $argLine = Replace-ZcTextIgnoreCase -Text $argLine -Token '%BIN%' -Value $binSlash
    $argLine = Replace-ZcTextIgnoreCase -Text $argLine -Token '%LISTS%' -Value $listsSlash
    $argLine = Replace-ZcTextIgnoreCase -Text $argLine -Token '%GameFilterTCP%' -Value $tcp
    $argLine = Replace-ZcTextIgnoreCase -Text $argLine -Token '%GameFilterUDP%' -Value $udp
    $argLine = Replace-ZcTextIgnoreCase -Text $argLine -Token '%GameFilter%' -Value $generic

    # Неизвестная переменная осталась неподставленной — winws.exe получит мусор,
    # поэтому лучше вернуть $null, чем запускать заведомо битую стратегию.
    if ($argLine -match '%[^%\s]+%') {
        Write-Verbose ('Get-WinwsArgs: не подставлены переменные в ' + $BatPath + ': ' + $Matches[0])
        return $null
    }

    return $argLine
}

function Replace-ZcTextIgnoreCase {
    # Замена подстроки без учёта регистра; $Value подставляется буквально.
    param(
        [string]$Text,
        [string]$Token,
        [string]$Value
    )

    if ([string]::IsNullOrEmpty($Text) -or [string]::IsNullOrEmpty($Token)) { return $Text }
    $replacement = [string]$Value
    if ($replacement.Contains('$')) { $replacement = $replacement.Replace('$', '$$') }
    return [regex]::Replace($Text, [regex]::Escape($Token), $replacement, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

# ---------------------------------------------------------------------------
#  IPSet
# ---------------------------------------------------------------------------
function Get-IpsetState {
    param([string]$Root)

    $kind = Get-IpsetListKind -Path (Join-Path $Root 'lists\ipset-all.txt')
    if ($kind -eq 'missing') { return 'none' }
    return $kind
}

function Get-IpsetListKind {
    # Возвращает 'missing' | 'any' | 'none' | 'loaded'.
    # Ключевое: пустой ИЛИ состоящий из пробелов/переводов строк файл — это «any».
    # Раньше файл из двух байт (\r\n) считался «loaded», из-за чего режим any
    # не определялся, а при переходе any -> none реальный список терялся.
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return 'missing' }
    if (-not (Test-Path -LiteralPath $Path)) { return 'missing' }

    $info = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $info) { return 'missing' }
    if ($info.Length -eq 0) { return 'any' }

    $head = ''
    $read = 0
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $size = [int][Math]::Min(4096, $info.Length)
            $buffer = New-Object byte[] $size
            $read = $stream.Read($buffer, 0, $size)
            $head = [Text.Encoding]::ASCII.GetString($buffer, 0, $read)
        } finally {
            $stream.Dispose()
        }
    } catch {
        # Не читается (нет прав / файл занят): считаем «loaded», чтобы не принять
        # реальный список за пустой и не перезаписать его.
        $script:ZC_LastIpsetError = $_.Exception.Message
        Write-Verbose ('ipset-all.txt не прочитан: ' + $_.Exception.Message)
        return 'loaded'
    }

    if ($read -ge [int][Math]::Min(4096, $info.Length) -and [string]::IsNullOrWhiteSpace($head)) {
        return 'any'
    }
    if ($head -match '203\.0\.113\.113/32') { return 'none' }
    return 'loaded'
}

function Set-IpsetMode {
    param(
        [string]$Root,
        [string]$Mode
    )

    $listFile = Join-Path $Root 'lists\ipset-all.txt'
    $backupFile = $listFile + '.backup'
    # Предыдущий реальный список, сохранённый, когда .backup уже был занят.
    $previousFile = $backupFile + '.prev'
    $current = Get-IpsetState -Root $Root

    switch ($Mode) {
        'none' {
            if ($current -eq 'loaded') {
                if (-not (Test-Path -LiteralPath $backupFile) -or (Get-IpsetListKind -Path $backupFile) -ne 'loaded') {
                    # Бэкапа нет (или в нём заглушка/пусто) — просто переносим список.
                    if (Test-Path -LiteralPath $backupFile) { Remove-Item -LiteralPath $backupFile -Force }
                    Move-Item -LiteralPath $listFile -Destination $backupFile -Force
                } else {
                    # В .backup лежит настоящий список — не уничтожаем его,
                    # а текущий список кладём рядом, чтобы ничего не потерять.
                    Move-Item -LiteralPath $listFile -Destination $previousFile -Force
                }
            }
            Set-IpsetFileContent -Path $listFile -Content '203.0.113.113/32'
        }
        'any' {
            if ($current -eq 'loaded') {
                if (Test-Path -LiteralPath $backupFile) { Remove-Item -LiteralPath $backupFile -Force }
                Copy-Item -LiteralPath $listFile -Destination $backupFile -Force
            }
            # Истинно пустой файл (0 байт): Set-Content -Value '' создавал 2 байта (\r\n),
            # из-за чего режим any не определялся ни GUI, ни service.bat.
            Set-IpsetFileContent -Path $listFile -Content ''
        }
        'loaded' {
            if ($current -eq 'loaded') { return }

            $source = $null
            foreach ($candidate in @($backupFile, $previousFile)) {
                if ((Get-IpsetListKind -Path $candidate) -eq 'loaded') {
                    if (-not $source) { $source = $candidate }
                    elseif ((Get-Item -LiteralPath $candidate).LastWriteTimeUtc -gt (Get-Item -LiteralPath $source).LastWriteTimeUtc) {
                        $source = $candidate
                    }
                }
            }

            if (-not $source) {
                throw 'Нет резервной копии списка IPSet. Сначала обновите IPSet (кнопка «Обновить IPSet»).'
            }
            Remove-Item -LiteralPath $listFile -Force -ErrorAction SilentlyContinue
            Move-Item -LiteralPath $source -Destination $listFile -Force
        }
        default { throw "Неизвестный режим IPSet: $Mode" }
    }
}

function Set-IpsetFileContent {
    # Пишет содержимое без завершающего перевода строки (в т.ч. истинно пустой файл).
    param(
        [string]$Path,
        [string]$Content
    )

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [IO.File]::WriteAllText($Path, [string]$Content, (New-Object Text.UTF8Encoding($false)))
}

# ---------------------------------------------------------------------------
#  Служба / процессы / список пользователя
# ---------------------------------------------------------------------------
function Get-ServiceInfo {
    param([string]$Name)

    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $service) {
        return [pscustomobject]@{ Installed = $false; Status = 'NotInstalled'; StartType = $null }
    }

    $startType = $null
    try {
        $start = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$Name" -Name 'Start' -ErrorAction Stop).Start
        switch ([int]$start) {
            2 { $startType = 'Auto' }
            3 { $startType = 'Manual' }
            4 { $startType = 'Disabled' }
            default { $startType = 'Unknown' }
        }
    } catch { }

    return [pscustomobject]@{
        Installed = $true
        Status    = $service.Status.ToString()
        StartType = $startType
    }
}

function Get-ServiceStrategy {
    param([string]$Name = 'zapret')

    try {
        $path = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
        $value = (Get-ItemProperty -Path $path -Name 'zapret-discord-youtube' -ErrorAction Stop).'zapret-discord-youtube'
        if ($value) { return [string]$value }
        return $null
    } catch {
        return $null
    }
}

function Initialize-UserLists {
    param([string]$Root)

    $lists = Join-Path $Root 'lists'
    if (-not (Test-Path -LiteralPath $lists)) { return }

    $ipsetUser = Join-Path $lists 'ipset-exclude-user.txt'
    if (-not (Test-Path -LiteralPath $ipsetUser)) {
        Set-Content -LiteralPath $ipsetUser -Value '203.0.113.113/32' -Encoding Ascii
    }

    $generalUser = Join-Path $lists 'list-general-user.txt'
    if (-not (Test-Path -LiteralPath $generalUser)) {
        Set-Content -LiteralPath $generalUser -Value @('# Never leave this file empty', 'domain.example.abc') -Encoding Ascii
    }

    $excludeUser = Join-Path $lists 'list-exclude-user.txt'
    if (-not (Test-Path -LiteralPath $excludeUser)) {
        Set-Content -LiteralPath $excludeUser -Value 'domain.example.abc' -Encoding Ascii
    }
}

function Enable-TcpTimestamps {
    try {
        & netsh.exe interface tcp set global timestamps=enabled 2>$null | Out-Null
    } catch { }
}

function Stop-ZapretService {
    param([string]$Name = 'zapret', [switch]$KeepProcesses)

    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $service) { return $false }

    if ($service.Status -ne 'Stopped') {
        try { Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue } catch { }
        for ($i = 0; $i -lt 40; $i++) {
            try { $service.Refresh() } catch { }
            if ($service.Status -eq 'Stopped') { break }
            Start-Sleep -Milliseconds 250
        }
    }

    # Служба может оставить дочерний winws.exe: он держит драйвер WinDivert
    # и не даёт службе запуститься снова.
    if (-not $KeepProcesses) {
        Stop-ZapretProcesses | Out-Null
        Reset-WinDivertDriver
    }

    # Возвращаем фактическое состояние, иначе GUI запустит новую стратегию
    # поверх ещё живой старой службы.
    try { $service.Refresh() } catch { }
    return ($service.Status -eq 'Stopped')
}

function Start-ZapretService {
    param([string]$Name = 'zapret', [int]$Attempts = 3)

    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $service) { return $false }
    try { $service.Refresh() } catch { }
    if ($service.Status -eq 'Running') { return $true }

    $script:ZC_LastServiceError = $null
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        if ($attempt -gt 1) { Start-Sleep -Milliseconds 900 }

        # Осиротевший winws.exe и служба драйвера WinDivert мешают старту.
        Stop-ZapretProcesses | Out-Null
        Reset-WinDivertDriver

        $startError = $null
        try {
            Start-Service -Name $Name -ErrorAction Stop
        } catch {
            $startError = $_.Exception.Message
            $script:ZC_LastServiceError = $startError
        }

        # winws может успеть перейти в Running и сразу упасть (код 1),
        # поэтому требуем стабильной работы несколько секунд.
        $stable = $false
        $sawRunning = $false
        $lastStatus = ''
        for ($i = 0; $i -lt 18; $i++) {
            Start-Sleep -Milliseconds 300
            try { $service.Refresh() } catch { }
            $lastStatus = $service.Status.ToString()
            if ($lastStatus -eq 'Running') { $sawRunning = $true }
            if ($lastStatus -ne 'Running') { break }
            if ($i -eq 17) { $stable = $true }
        }

        $winwsCount = @(Get-WinwsProcesses).Count
        if ($stable -and $winwsCount -gt 0) { return $true }

        # Сохраняем реальную причину: состояние службы + исходное исключение.
        $details = New-Object System.Collections.Generic.List[string]
        if ($startError) { $details.Add('Start-Service: ' + $startError) }
        if ($lastStatus) { $details.Add('состояние службы: ' + $lastStatus) }
        if ($winwsCount -eq 0) { $details.Add('процесс winws.exe не найден') }

        if ($details.Count -gt 0) {
            if ($sawRunning -and $lastStatus -ne 'Running') {
                $script:ZC_LastServiceError = 'Служба запустилась и сразу остановилась (' + ($details -join '; ') + ')'
            } else {
                $script:ZC_LastServiceError = 'Служба не запустилась (' + ($details -join '; ') + ')'
            }
        }
    }

    try { $service.Refresh() } catch { }
    if ($service.Status -eq 'Running' -and @(Get-WinwsProcesses).Count -gt 0) { return $true }
    return $false
}

function Reset-WinDivertDriver {
    # Удаляет осиротевшие службы драйвера, оставшиеся после аварийной остановки winws.
    if (@(Get-WinwsProcesses).Count -gt 0) { return }

    foreach ($name in @('WinDivert', 'WinDivert14')) {
        $service = Get-Service -Name $name -ErrorAction SilentlyContinue
        if (-not $service) { continue }
        try { Stop-Service -Name $name -Force -ErrorAction SilentlyContinue } catch { }

        & sc.exe delete $name 2>$null | Out-Null
        $code = $LASTEXITCODE
        if ($code -ne 0) {
            # 1060 — службы уже нет, это не ошибка; остальные коды логируем.
            if ($code -ne 1060) {
                $script:ZC_LastDivertError = "sc.exe delete $name завершился с кодом $code"
                Write-Verbose $script:ZC_LastDivertError
            }
            continue
        }

        # sc.exe удаляет службу асинхронно — ждём фактического исчезновения (до 5 с),
        # иначе следующий старт winws снова упрётся в занятый драйвер.
        for ($i = 0; $i -lt 20; $i++) {
            if (-not (Get-Service -Name $name -ErrorAction SilentlyContinue)) { break }
            Start-Sleep -Milliseconds 250
        }
    }
}

function Get-WinDivertState {
    $services = @()
    foreach ($name in @('WinDivert', 'WinDivert14')) {
        $service = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($service) { $services += $service }
    }

    if ($services.Count -eq 0) { return 'absent' }
    $active = @($services | Where-Object { $_.Status -ne 'Stopped' })
    if ($active.Count -eq 0) { return 'stopped' }
    if (@(Get-WinwsProcesses).Count -eq 0) { return 'stale' }
    return 'running'
}

function Get-VpnConflicts {
    # Активные VPN/прокси-клиенты конфликтуют с zapret: вместе они обычно роняют интернет.
    $names = @(
        'Happ', 'happd', 'sing-box', 'xray', 'v2ray', 'clash', 'mihomo',
        'openvpn', 'openvpn-gui', 'wireguard', 'tailscale', 'zerotier',
        'nordvpn', 'protonvpn', 'surfshark', 'windscribe', 'outline',
        'shadowsocks', 'amnezia', 'openconnect', 'softether', 'warp-svc'
    )

    $found = New-Object System.Collections.ArrayList
    foreach ($process in @(Get-Process -Name $names -ErrorAction SilentlyContinue)) {
        $key = [string]$process.ProcessName
        if ($key -and -not $found.Contains($key)) { [void]$found.Add($key) }
    }

    $servicePatterns = @(
        'HappService', 'OpenVPN*', 'WireGuard*', 'Tailscale', 'ZeroTierOneService',
        'NordVPN*', 'ProtonVPN*', 'Surfshark*', 'Amnezia*', 'Windscribe*', 'warp-svc'
    )

    # Get-Service сам раскрывает шаблоны — не перебираем весь список служб системы.
    foreach ($service in @(Get-Service -Name $servicePatterns -ErrorAction SilentlyContinue)) {
        if ($service.Status -ne 'Running') { continue }
        if (-not $found.Contains($service.Name)) { [void]$found.Add($service.Name) }
    }

    return @($found)
}

function Stop-ZapretProcesses {
    $processes = @(Get-Process -Name 'winws' -ErrorAction SilentlyContinue)
    foreach ($process in $processes) {
        try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch { }
    }
    if ($processes.Count -gt 0) { Start-Sleep -Milliseconds 600 }
    return $processes.Count
}

function Get-WinwsProcesses {
    return @(Get-Process -Name 'winws' -ErrorAction SilentlyContinue)
}

# ---------------------------------------------------------------------------
#  Версии и GitHub
# ---------------------------------------------------------------------------
function ConvertTo-AppVersion {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $match = [regex]::Match($Text, '^\s*[vV]?(\d+(?:\.\d+){0,3})')
    if (-not $match.Success) { return $null }
    try { return [version]$match.Groups[1].Value } catch { return $null }
}

function Get-LocalZapretVersion {
    param([string]$Root)

    $file = Join-Path $Root 'service.bat'
    if (-not (Test-Path -LiteralPath $file)) { return $null }

    $info = Get-Item -LiteralPath $file -ErrorAction SilentlyContinue
    $stamp = 0
    if ($info) { $stamp = $info.LastWriteTimeUtc.Ticks }

    $cached = $script:ZC_VersionCache[$file]
    if ($cached -and $cached.Stamp -eq $stamp) { return $cached.Version }

    $version = $null
    try {
        $match = [regex]::Match([IO.File]::ReadAllText($file), 'LOCAL_VERSION\s*=\s*([0-9][0-9A-Za-z\.\-]*)')
        if ($match.Success) { $version = $match.Groups[1].Value.Trim() }
    } catch {
        # Файл занят/недоступен — версия неизвестна, кэш не портим.
        Write-Verbose ('service.bat не прочитан: ' + $_.Exception.Message)
        return $null
    }

    $script:ZC_VersionCache[$file] = [pscustomobject]@{ Stamp = $stamp; Version = $version }
    return $version
}

function Enable-ZcTls12 {
    # PowerShell 5.1 не всегда включает TLS 1.2 для Invoke-WebRequest (GitHub без него не отвечает).
    try {
        $current = [Net.ServicePointManager]::SecurityProtocol
        $tls12 = [Net.SecurityProtocolType]::Tls12
        if (($current -band $tls12) -eq 0) {
            [Net.ServicePointManager]::SecurityProtocol = $current -bor $tls12
        }
    } catch { }
}

function Invoke-CurlText {
    param(
        [string]$Url,
        [int]$TimeoutSec = 20
    )

    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        $tempFile = Join-Path ([IO.Path]::GetTempPath()) ('zc-api-' + [Guid]::NewGuid().ToString('N') + '.json')
        try {
            # -f: HTTP-ошибки (404 и т.п.) считаем ошибкой, «--» отделяет URL от ключей.
            & curl.exe -s -L -f --max-time $TimeoutSec -H 'User-Agent: ZapretControl' -o $tempFile -- $Url 2>$null
            if ($LASTEXITCODE -ne 0) { return $null }
            if (-not (Test-Path -LiteralPath $tempFile)) { return $null }
            # curl отдаёт UTF-8, а PowerShell 5.1 декодирует stdout в OEM-кодировке,
            # поэтому читаем ответ из файла явно как UTF-8.
            $text = ([IO.File]::ReadAllText($tempFile, [Text.Encoding]::UTF8)).Trim()
            if ([string]::IsNullOrWhiteSpace($text)) { return $null }
            return $text
        } catch {
            Write-Verbose ('curl.exe: ' + $_.Exception.Message)
            return $null
        } finally {
            if (Test-Path -LiteralPath $tempFile) { Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue }
        }
    }

    try {
        Enable-ZcTls12
        $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec -Headers @{ 'User-Agent' = 'ZapretControl' }
        return $response.Content
    } catch {
        Write-Verbose ('Invoke-WebRequest: ' + $_.Exception.Message)
        return $null
    }
}

function Invoke-CurlDownload {
    param(
        [string]$Url,
        [string]$OutFile,
        [int]$TimeoutSec = 300,
        [string]$ExpectedSha256 = ''
    )

    if ([string]::IsNullOrWhiteSpace($Url) -or [string]::IsNullOrWhiteSpace($OutFile)) { return $false }

    $script:ZC_LastDownloadError = $null

    # Файл от предыдущей попытки нельзя принять за результат текущего скачивания.
    try {
        if (Test-Path -LiteralPath $OutFile) {
            Remove-Item -LiteralPath $OutFile -Force -ErrorAction Stop
        }
    } catch {
        $script:ZC_LastDownloadError = 'Не удалось удалить старый файл: ' + $_.Exception.Message
        Write-Verbose ('Invoke-CurlDownload: ' + $script:ZC_LastDownloadError)
        return $false
    }

    $downloaded = $false
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    try {
        if ($curl) {
            # -f: HTTP 4xx/5xx — ошибка; «--» отделяет URL от ключей curl.
            & curl.exe -L -f -s --max-time $TimeoutSec -o $OutFile -- $Url 2>$null
            $downloaded = ($LASTEXITCODE -eq 0)
            if (-not $downloaded) { $script:ZC_LastDownloadError = "curl.exe завершился с кодом $LASTEXITCODE" }
        } else {
            Enable-ZcTls12
            Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec -OutFile $OutFile -ErrorAction Stop
            $downloaded = $true
        }
    } catch {
        $downloaded = $false
        $script:ZC_LastDownloadError = $_.Exception.Message
    }

    $info = $null
    if ($downloaded) { $info = Get-Item -LiteralPath $OutFile -ErrorAction SilentlyContinue }

    # Пустой файл — не успех (частый случай при обрыве соединения).
    if (-not $downloaded -or -not $info -or $info.Length -le 0) {
        if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue }
        if (-not $script:ZC_LastDownloadError) { $script:ZC_LastDownloadError = 'Файл не скачан или пуст' }
        Write-Verbose ('Invoke-CurlDownload: ' + $script:ZC_LastDownloadError)
        return $false
    }

    if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256)) {
        $expected = ([string]$ExpectedSha256).Trim() -replace '^sha256:', ''
        $actual = $null
        try {
            $actual = (Get-FileHash -LiteralPath $OutFile -Algorithm SHA256 -ErrorAction Stop).Hash
        } catch {
            $script:ZC_LastDownloadError = 'Не удалось посчитать SHA256: ' + $_.Exception.Message
        }

        if (-not $actual -or $actual -ne $expected) {
            if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue }
            if (-not $script:ZC_LastDownloadError) {
                $script:ZC_LastDownloadError = "Не совпал SHA256: ожидался $expected, получен $actual"
            }
            Write-Verbose ('Invoke-CurlDownload: ' + $script:ZC_LastDownloadError)
            return $false
        }
    }

    return $true
}

function Get-SafeAssetName {
    # Имя ассета из GitHub API — недоверенные данные: берём только базовое имя
    # без каталогов, точек-обходов и посторонних расширений.
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    $leaf = [IO.Path]::GetFileName($Name)
    if ([string]::IsNullOrWhiteSpace($leaf)) { return $null }
    if ($leaf -ne $Name) { return $null }                        # было '..\..\x.zip' или 'sub\x.zip'
    if ($leaf.Length -gt 100) { return $null }
    if ($leaf -notmatch '^[A-Za-z0-9._-]+$') { return $null }
    if ($leaf -match '^\.+$') { return $null }
    if (-not $leaf.EndsWith('.zip', [StringComparison]::OrdinalIgnoreCase)) { return $null }
    return $leaf
}

function Get-AssetSha256 {
    # GitHub отдаёт digest вида "sha256:<hex>"; возвращаем bare-hex в верхнем регистре.
    param($Asset)

    if (-not $Asset) { return $null }
    $digest = [string]$Asset.digest
    if ([string]::IsNullOrWhiteSpace($digest)) { return $null }
    if ($digest -match '^sha256:(?<hex>[0-9a-fA-F]{64})$') { return $Matches['hex'].ToUpperInvariant() }
    return $null
}

# ---------------------------------------------------------------------------
#  Самообновление GUI: staging, бэкап, подмена, откат
# ---------------------------------------------------------------------------
function Get-ZcFileSha256 {
    # Единая точка хеширования файла: bare-hex в верхнем регистре, как у Get-AssetSha256.
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
    } catch {
        Write-Verbose ('Get-FileHash: ' + $_.Exception.Message)
        return $null
    }
}

function Get-ZcAppRootPath {
    # Корень приложения — каталог, где лежат ZapretControl.ps1/ZapretCommon.ps1.
    # Путь берётся из параметра, иначе из $script:ZC_AppRoot (каталог этого файла); cwd не используется.
    param([string]$AppRoot)

    if (-not [string]::IsNullOrWhiteSpace($AppRoot)) {
        try {
            return (Resolve-Path -LiteralPath $AppRoot -ErrorAction Stop).Path
        } catch {
            Write-Verbose ('AppRoot не найден: ' + $AppRoot)
            return $null
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($script:ZC_AppRoot)) { return $script:ZC_AppRoot }
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { return $PSScriptRoot }
    return $null
}

function Get-ZcScriptAppVersion {
    # Версия GUI из скрипта: $script:ZC_AppVersion = '2.0.0'.
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $text = [IO.File]::ReadAllText($Path)
    } catch {
        Write-Verbose ('Версия не прочитана: ' + $_.Exception.Message)
        return $null
    }
    $match = [regex]::Match($text, "ZC_AppVersion\s*=\s*['""]([^'""]+)['""]")
    if (-not $match.Success) { return $null }
    return $match.Groups[1].Value.Trim()
}

function Get-ZcBatchFileProblems {
    # .bat запускает cmd.exe: нужен ASCII без BOM и CRLF — иначе ломается первая строка/аргументы.
    param([string]$Path)

    $problems = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $problems.Add('файл не найден.')
        return $problems
    }

    try {
        $bytes = [IO.File]::ReadAllBytes($Path)
    } catch {
        $problems.Add('не прочитан: ' + $_.Exception.Message)
        return $problems
    }

    if ($bytes.Length -eq 0) {
        $problems.Add('файл пуст.')
        return $problems
    }

    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $problems.Add('в начале файла UTF-8 BOM (cmd.exe покажет мусор в первой строке).')
    }

    $nonAscii = 0
    $lf = 0
    $crlf = 0
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -gt 0x7F) { $nonAscii++ }
        if ($bytes[$i] -eq 0x0A) {
            $lf++
            if ($i -gt 0 -and $bytes[$i - 1] -eq 0x0D) { $crlf++ }
        }
    }

    if ($nonAscii -gt 0) { $problems.Add("не-ASCII байтов: $nonAscii.") }
    if ($lf -eq 0) {
        $problems.Add('нет переводов строк.')
    } elseif ($crlf -ne $lf) {
        $problems.Add("переводы строк не CRLF (LF=$lf, CRLF=$crlf).")
    }

    return $problems
}

function Get-ZcBackupSortKey {
    # Ключ сортировки каталогов backup-*: timestamp из имени; каталоги без него
    # (backup-<версия> от 2.0.0) считаются самыми старыми и удаляются первыми.
    param([string]$Name)

    $match = [regex]::Match([string]$Name, '-(\d{8}-\d{6})$')
    if (-not $match.Success) { return [long]0 }
    try {
        $stamp = [datetime]::ParseExact($match.Groups[1].Value, 'yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture)
        return [long]$stamp.Ticks
    } catch {
        return [long]0
    }
}

function Test-ZcSafeRemovalPath {
    # Защита от удаления корня диска, каталога data и корня приложения при ошибке в пути.
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try {
        $full = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    } catch {
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($full)) { return $false }
    if ($full -match '^[A-Za-z]:$') { return $false }

    if (-not [string]::IsNullOrWhiteSpace($script:ZC_AppRoot)) {
        try {
            $appRoot = [IO.Path]::GetFullPath($script:ZC_AppRoot).TrimEnd('\', '/')
            if ($full -eq $appRoot) { return $false }
            if ($full -eq [IO.Path]::GetDirectoryName($appRoot)) { return $false }
            if ($full -eq (Join-Path $appRoot 'data')) { return $false }
        } catch { }
    }

    return $true
}

function Test-GuiUpdateStaging {
    # Проверка распакованного staging ДО подмены: состав файлов, синтаксис PS 5.1,
    # формат .bat и версия строго новее установленной. Возвращает ok + список причин отказа.
    param(
        [string]$StagingDir,
        [string]$CurrentCommonPath,
        [string[]]$Files = $script:ZC_GuiFiles
    )

    $reasons = New-Object System.Collections.Generic.List[string]
    $result = [pscustomobject]@{
        Ok             = $false
        Reasons        = @()
        StagingVersion = $null
        CurrentVersion = $null
    }

    if ([string]::IsNullOrWhiteSpace($StagingDir) -or -not (Test-Path -LiteralPath $StagingDir -PathType Container)) {
        $reasons.Add('Каталог staging не найден: ' + [string]$StagingDir)
        $result.Reasons = @($reasons)
        return $result
    }

    if ([string]::IsNullOrWhiteSpace($CurrentCommonPath)) {
        $CurrentCommonPath = Join-Path $script:ZC_AppRoot 'ZapretCommon.ps1'
    }

    foreach ($name in @($Files)) {
        $file = Join-Path $StagingDir $name
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            $reasons.Add("В staging нет файла $name.")
            continue
        }

        $info = Get-Item -LiteralPath $file -ErrorAction SilentlyContinue
        if ($info -and $info.Length -le 0) {
            $reasons.Add("Файл $name в staging пуст.")
            continue
        }

        if ($name.EndsWith('.ps1', [StringComparison]::OrdinalIgnoreCase)) {
            $parseErrors = $null
            [void][Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$parseErrors)
            if ($parseErrors -and $parseErrors.Count -gt 0) {
                $details = (@($parseErrors | Select-Object -First 2 | ForEach-Object { $_.Message }) -join '; ')
                $reasons.Add("Синтаксические ошибки в $name ($($parseErrors.Count)): $details")
            }
        } elseif ($name.EndsWith('.bat', [StringComparison]::OrdinalIgnoreCase)) {
            foreach ($problem in @(Get-ZcBatchFileProblems -Path $file)) {
                $reasons.Add("${name}: $problem")
            }
        }
    }

    $stagingVersion = Get-ZcScriptAppVersion -Path (Join-Path $StagingDir 'ZapretCommon.ps1')
    $currentVersion = Get-ZcScriptAppVersion -Path $CurrentCommonPath
    $result.StagingVersion = $stagingVersion
    $result.CurrentVersion = $currentVersion

    $stagingParsed = ConvertTo-AppVersion -Text $stagingVersion
    $currentParsed = ConvertTo-AppVersion -Text $currentVersion

    if (-not $stagingVersion) {
        $reasons.Add('В staging ZapretCommon.ps1 не найдена версия ZC_AppVersion.')
    } elseif (-not $currentVersion) {
        $reasons.Add('Не удалось прочитать установленную версию ZC_AppVersion: ' + [string]$CurrentCommonPath)
    } elseif (-not $stagingParsed -or -not $currentParsed) {
        $reasons.Add("Не удалось сравнить версии: staging ($stagingVersion), установленная ($currentVersion).")
    } elseif ($stagingParsed -le $currentParsed) {
        $reasons.Add("Версия в staging ($stagingVersion) не новее установленной ($currentVersion).")
    }

    $result.Reasons = @($reasons)
    $result.Ok = ($reasons.Count -eq 0)
    return $result
}

function New-GuiUpdateBackup {
    # Копия рабочих файлов в data\backup-<версия>-<yyyyMMdd-HHmmss> + манифест backup.json
    # с SHA-256 каждого файла (по нему проверяется и откат).
    param(
        [string]$AppRoot,
        [string]$CurrentVersion = $script:ZC_AppVersion,
        [string[]]$Files = $script:ZC_GuiFiles,
        [datetime]$Timestamp = (Get-Date)
    )

    $result = [pscustomobject]@{
        Ok           = $false
        BackupDir    = $null
        ManifestPath = $null
        Hashes       = @{}
        Missing      = @()
        Error        = $null
    }

    $root = Get-ZcAppRootPath -AppRoot $AppRoot
    if (-not $root) {
        $result.Error = 'Не найден корень приложения.'
        return $result
    }

    $version = [string]$CurrentVersion
    if ([string]::IsNullOrWhiteSpace($version)) { $version = 'unknown' }
    $safeVersion = $version -replace '[^0-9A-Za-z._-]', '_'

    $dataDir = Join-Path $root 'data'
    $stamp = $Timestamp
    $backupDir = Join-Path $dataDir ('backup-' + $safeVersion + '-' + $stamp.ToString('yyyyMMdd-HHmmss'))
    # Одна и та же секунда не должна перезаписывать предыдущий бэкап — сдвигаем метку.
    $attempt = 0
    while ((Test-Path -LiteralPath $backupDir) -and $attempt -lt 60) {
        $attempt++
        $stamp = $stamp.AddSeconds(1)
        $backupDir = Join-Path $dataDir ('backup-' + $safeVersion + '-' + $stamp.ToString('yyyyMMdd-HHmmss'))
    }

    $manifestPath = Join-Path $backupDir 'backup.json'
    $hashes = @{}
    $missing = New-Object System.Collections.Generic.List[string]
    $created = $false

    try {
        New-Item -ItemType Directory -Path $backupDir -Force -ErrorAction Stop | Out-Null
        $created = $true

        foreach ($name in @($Files)) {
            $source = Join-Path $root $name
            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
                $missing.Add($name)
                continue
            }
            $dest = Join-Path $backupDir $name
            Copy-Item -LiteralPath $source -Destination $dest -Force -ErrorAction Stop
            $hash = Get-ZcFileSha256 -Path $dest
            if (-not $hash) { throw ("Не удалось посчитать SHA-256: $name") }
            $hashes[$name] = $hash
        }

        if ($hashes.Count -eq 0) { throw 'Не удалось скопировать ни одного рабочего файла.' }

        $manifest = [pscustomobject]@{
            Version   = $version
            CreatedAt = $stamp.ToString('yyyy-MM-ddTHH:mm:ss')
            Files     = $hashes
        }
        $json = $manifest | ConvertTo-Json -Depth 4
        [IO.File]::WriteAllText($manifestPath, $json, (New-Object Text.UTF8Encoding($true)))

        $result.Ok = $true
        $result.BackupDir = $backupDir
        $result.ManifestPath = $manifestPath
        $result.Hashes = $hashes
    } catch {
        $result.Error = $_.Exception.Message
        # Неполный каталог без манифеста не должен попадать в историю бэкапов.
        if ($created -and -not (Test-Path -LiteralPath $manifestPath)) {
            Remove-Item -LiteralPath $backupDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $result.Missing = @($missing)
    return $result
}

function Test-GuiUpdateManifest {
    # Сверка каталога с backup.json по SHA-256; при первом несовпадении — файл и оба хеша.
    param(
        [string]$Directory,
        [string]$ManifestPath
    )

    $result = [pscustomobject]@{
        Ok       = $false
        Reason   = $null
        File     = $null
        Expected = $null
        Actual   = $null
        Files    = @()
        Checked  = 0
    }

    if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
        if ([string]::IsNullOrWhiteSpace($Directory)) {
            $result.Reason = 'Не указан ни каталог, ни манифест.'
            return $result
        }
        $ManifestPath = Join-Path $Directory 'backup.json'
    }
    if ([string]::IsNullOrWhiteSpace($Directory)) {
        $Directory = Split-Path -Parent $ManifestPath
    }

    $manifest = $null
    try {
        $json = [IO.File]::ReadAllText($ManifestPath)
        $manifest = $json | ConvertFrom-Json -ErrorAction Stop
    } catch {
        $result.Reason = 'Манифест не прочитан (' + $ManifestPath + '): ' + $_.Exception.Message
        return $result
    }

    $entries = @()
    if ($manifest -and $manifest.Files) { $entries = @($manifest.Files.PSObject.Properties) }
    if ($entries.Count -eq 0) {
        $result.Reason = 'В манифесте нет списка файлов: ' + $ManifestPath
        return $result
    }

    $checks = New-Object System.Collections.Generic.List[object]
    $firstFailure = $null

    foreach ($property in $entries) {
        $name = [string]$property.Name
        $expected = ([string]$property.Value).Trim().ToUpperInvariant()
        $path = Join-Path $Directory $name
        $actual = Get-ZcFileSha256 -Path $path

        $ok = $false
        $reason = $null
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $reason = 'файл отсутствует'
        } elseif (-not $actual) {
            $reason = 'SHA-256 не посчитан'
        } elseif ($actual -ne $expected) {
            $reason = "SHA-256 не совпал: ожидался $expected, получен $actual"
        } else {
            $ok = $true
        }

        $check = [pscustomobject]@{
            Name     = $name
            Expected = $expected
            Actual   = $actual
            Ok       = $ok
            Reason   = $reason
        }
        $checks.Add($check)

        if (-not $ok -and -not $firstFailure) { $firstFailure = $check }
    }

    $result.Files = $checks.ToArray()
    $result.Checked = $checks.Count

    if ($firstFailure) {
        $result.File = $firstFailure.Name
        $result.Expected = $firstFailure.Expected
        $result.Actual = $firstFailure.Actual
        $result.Reason = "$($firstFailure.Name): $($firstFailure.Reason)"
        return $result
    }

    $result.Ok = $true
    return $result
}

function Invoke-GuiUpdateFileSwap {
    # Единственная точка фактической подмены файлов: текущие файлы уезжают в update-old,
    # затем файлы из staging встают на их место. Только операции и факты: ни UI, ни решения
    # об откате. Новый файл не ставится, если старый не удалось убрать (иначе он потерян).
    param(
        [string]$StagingDir,
        [string]$OldDir,
        [string]$TargetRoot,
        [string[]]$Files = $script:ZC_GuiFiles
    )

    $result = [pscustomobject]@{
        Ok         = $false
        Steps      = @()
        MovedToOld = @()
        Installed  = @()
        Errors     = @()
    }

    $steps = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[string]
    $moved = New-Object System.Collections.Generic.List[string]
    $installed = New-Object System.Collections.Generic.List[string]

    if ([string]::IsNullOrWhiteSpace($StagingDir) -or -not (Test-Path -LiteralPath $StagingDir -PathType Container)) {
        $errors.Add('Каталог staging не найден: ' + [string]$StagingDir)
    }
    if ([string]::IsNullOrWhiteSpace($OldDir)) {
        $errors.Add('Не указан каталог update-old.')
    }
    if ([string]::IsNullOrWhiteSpace($TargetRoot) -or -not (Test-Path -LiteralPath $TargetRoot -PathType Container)) {
        $errors.Add('Целевой каталог не найден: ' + [string]$TargetRoot)
    }

    if ($errors.Count -eq 0) {
        try {
            New-Item -ItemType Directory -Path $OldDir -Force -ErrorAction Stop | Out-Null
        } catch {
            $errors.Add('Не удалось создать каталог update-old: ' + $_.Exception.Message)
        }
    }

    if ($errors.Count -eq 0) {
        # Шаг 1: текущие файлы — в update-old (как есть, без изменений).
        foreach ($name in @($Files)) {
            $source = Join-Path $TargetRoot $name
            $dest = Join-Path $OldDir $name
            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
                $steps.Add([pscustomobject]@{
                    Name = $name; Action = 'to-old'; From = $source; To = $dest; Ok = $true
                    Skipped = 'нет файла в целевом каталоге'; Error = $null
                })
                continue
            }
            try {
                Move-Item -LiteralPath $source -Destination $dest -Force -ErrorAction Stop
                $moved.Add($name)
                $steps.Add([pscustomobject]@{
                    Name = $name; Action = 'to-old'; From = $source; To = $dest; Ok = $true
                    Skipped = $null; Error = $null
                })
            } catch {
                $message = $_.Exception.Message
                $errors.Add("Не удалось переместить $name в update-old: $message")
                $steps.Add([pscustomobject]@{
                    Name = $name; Action = 'to-old'; From = $source; To = $dest; Ok = $false
                    Skipped = $null; Error = $message
                })
            }
        }

        # Шаг 2: файлы из staging — на места убранных.
        foreach ($name in @($Files)) {
            $source = Join-Path $StagingDir $name
            $dest = Join-Path $TargetRoot $name
            $oldStep = @($steps | Where-Object { $_.Name -eq $name -and $_.Action -eq 'to-old' })[0]
            if (-not $oldStep -or -not $oldStep.Ok) { continue }

            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
                $message = "В staging нет файла $name."
                $errors.Add($message)
                $steps.Add([pscustomobject]@{
                    Name = $name; Action = 'to-target'; From = $source; To = $dest; Ok = $false
                    Skipped = $null; Error = $message
                })
                continue
            }
            try {
                Move-Item -LiteralPath $source -Destination $dest -Force -ErrorAction Stop
                $installed.Add($name)
                $steps.Add([pscustomobject]@{
                    Name = $name; Action = 'to-target'; From = $source; To = $dest; Ok = $true
                    Skipped = $null; Error = $null
                })
            } catch {
                $message = $_.Exception.Message
                $errors.Add("Не удалось поставить $name из staging: $message")
                $steps.Add([pscustomobject]@{
                    Name = $name; Action = 'to-target'; From = $source; To = $dest; Ok = $false
                    Skipped = $null; Error = $message
                })
            }
        }
    }

    $result.Steps = $steps.ToArray()
    $result.MovedToOld = @($moved)
    $result.Installed = @($installed)
    $result.Errors = @($errors)
    $result.Ok = ($errors.Count -eq 0)
    return $result
}

function Restore-GuiUpdateFiles {
    # Откат: убираем всё, что успело встать на места, возвращаем файлы из update-old,
    # недостающие — из последнего бэкапа; итог проверяем по backup.json.
    param(
        [string]$TargetRoot,
        [string]$OldDir,
        [string]$BackupDir,
        [string]$ManifestPath,
        [string[]]$Files = $script:ZC_GuiFiles
    )

    $result = [pscustomobject]@{
        Ok          = $false
        Restored    = @()
        NotRestored = @()
        Source      = @{}
        Reasons     = @()
        Verified    = $false
        Manifest    = $null
    }

    $reasons = New-Object System.Collections.Generic.List[string]
    $restored = New-Object System.Collections.Generic.List[string]
    $notRestored = New-Object System.Collections.Generic.List[string]
    $sources = @{}

    if ([string]::IsNullOrWhiteSpace($TargetRoot) -or -not (Test-Path -LiteralPath $TargetRoot -PathType Container)) {
        $result.Reasons = @('Целевой каталог не найден: ' + [string]$TargetRoot)
        return $result
    }

    if ([string]::IsNullOrWhiteSpace($ManifestPath) -and -not [string]::IsNullOrWhiteSpace($BackupDir)) {
        $ManifestPath = Join-Path $BackupDir 'backup.json'
    }
    $result.Manifest = $ManifestPath

    # Шаг 1: на местах может лежать недописанный/чужой файл из staging — убираем по списку имён.
    foreach ($name in @($Files)) {
        $dest = Join-Path $TargetRoot $name
        if (Test-Path -LiteralPath $dest -PathType Leaf) {
            try {
                Remove-Item -LiteralPath $dest -Force -ErrorAction Stop
            } catch {
                $reasons.Add("Не удалось удалить $name перед восстановлением: " + $_.Exception.Message)
            }
        }
    }

    # Шаг 2: update-old в приоритете, бэкап — запасной источник.
    foreach ($name in @($Files)) {
        $dest = Join-Path $TargetRoot $name
        $from = $null
        $fromLabel = $null
        foreach ($candidate in @(
                @{ Dir = $OldDir; Label = 'update-old' },
                @{ Dir = $BackupDir; Label = 'backup' })) {
            if ([string]::IsNullOrWhiteSpace($candidate.Dir)) { continue }
            $path = Join-Path $candidate.Dir $name
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                $from = $path
                $fromLabel = $candidate.Label
                break
            }
        }

        if (-not $from) {
            $notRestored.Add($name)
            $reasons.Add("Нет источника для ${name}: ни update-old, ни backup.")
            continue
        }

        try {
            Copy-Item -LiteralPath $from -Destination $dest -Force -ErrorAction Stop
            $restored.Add($name)
            $sources[$name] = $fromLabel
        } catch {
            $notRestored.Add($name)
            $reasons.Add("Не удалось восстановить $name из ${fromLabel}: " + $_.Exception.Message)
        }
    }

    # Шаг 3: проверка восстановленного по манифесту бэкапа.
    if ($restored.Count -gt 0) {
        if (-not [string]::IsNullOrWhiteSpace($ManifestPath) -and (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
            $check = Test-GuiUpdateManifest -Directory $TargetRoot -ManifestPath $ManifestPath
            $result.Verified = $check.Ok
            if (-not $check.Ok) { $reasons.Add('Проверка по манифесту не прошла: ' + $check.Reason) }
        } else {
            $reasons.Add('Манифест бэкапа не найден: ' + [string]$ManifestPath)
        }
    }

    $result.Restored = @($restored)
    $result.NotRestored = @($notRestored)
    $result.Source = $sources
    $result.Reasons = @($reasons)
    $result.Ok = ($notRestored.Count -eq 0 -and $restored.Count -gt 0)
    return $result
}

function Remove-GuiUpdateLeftovers {
    # Чистка staging и update-old только после подтверждённого успеха; отсутствие каталогов — норма.
    param(
        [string]$StagingDir,
        [string]$OldDir
    )

    $result = [pscustomobject]@{
        Ok      = $true
        Removed = @()
        Skipped = @()
        Errors  = @()
    }

    $removed = New-Object System.Collections.Generic.List[string]
    $skipped = New-Object System.Collections.Generic.List[string]
    $errors = New-Object System.Collections.Generic.List[string]

    foreach ($path in @($StagingDir, $OldDir)) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        if (-not (Test-Path -LiteralPath $path)) {
            $skipped.Add($path + ' (каталога нет)')
            continue
        }
        if (-not (Test-Path -LiteralPath $path -PathType Container)) {
            $skipped.Add($path + ' (не каталог)')
            continue
        }
        if (-not (Test-ZcSafeRemovalPath -Path $path)) {
            $skipped.Add($path + ' (защищённый путь)')
            continue
        }
        try {
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
            $removed.Add($path)
        } catch {
            $errors.Add('Не удалось удалить ' + $path + ': ' + $_.Exception.Message)
        }
    }

    $result.Removed = @($removed)
    $result.Skipped = @($skipped)
    $result.Errors = @($errors)
    $result.Ok = ($errors.Count -eq 0)
    return $result
}

function Remove-OldGuiUpdateBackups {
    # В data\ остаются только $Keep новейших backup-*; старые каталоги без timestamp
    # (backup-<версия> от 2.0.0) удаляются первыми.
    param(
        [string]$AppRoot,
        [int]$Keep = $script:ZC_MaxGuiBackups
    )

    $result = [pscustomobject]@{
        Ok      = $true
        Keep    = $Keep
        Kept    = @()
        Removed = @()
        Errors  = @()
    }

    $root = Get-ZcAppRootPath -AppRoot $AppRoot
    if (-not $root) {
        $result.Ok = $false
        $result.Errors = @('Не найден корень приложения.')
        return $result
    }
    if ($Keep -lt 0) { $Keep = 0 }
    $result.Keep = $Keep

    $dataDir = Join-Path $root 'data'
    if (-not (Test-Path -LiteralPath $dataDir -PathType Container)) { return $result }

    $backups = @(Get-ChildItem -LiteralPath $dataDir -Directory -Filter 'backup-*' -ErrorAction SilentlyContinue)
    if ($backups.Count -eq 0) { return $result }

    $ordered = @($backups | Sort-Object -Property @(
        @{ Expression = { Get-ZcBackupSortKey -Name $_.Name }; Descending = $true },
        @{ Expression = { $_.Name }; Descending = $true }
    ))

    $keepList = @($ordered | Select-Object -First $Keep)
    $removeList = @($ordered | Select-Object -Skip $Keep)

    $removed = New-Object System.Collections.Generic.List[string]
    $errors = New-Object System.Collections.Generic.List[string]

    foreach ($dir in $removeList) {
        try {
            Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction Stop
            $removed.Add($dir.Name)
        } catch {
            $errors.Add("Не удалось удалить $($dir.Name): " + $_.Exception.Message)
        }
    }

    $result.Kept = @($keepList | ForEach-Object { $_.Name })
    $result.Removed = @($removed)
    $result.Errors = @($errors)
    $result.Ok = ($errors.Count -eq 0)
    return $result
}

# ---------------------------------------------------------------------------
#  Версии и GitHub
# ---------------------------------------------------------------------------
function Get-LatestZapretRelease {
    $raw = Invoke-CurlText -Url $script:ZC_ReleasesApi -TimeoutSec 20
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }

    try { $json = $raw | ConvertFrom-Json } catch { return $null }
    if (-not $json.tag_name) { return $null }

    $asset = @($json.assets) | Where-Object { $_.name -like '*.zip' } | Select-Object -First 1
    $assetName = $null
    $assetUrl = $null
    $assetSha256 = $null
    if ($asset) {
        # Невалидное имя — релиз без ассета: качать по такому пути нельзя.
        $assetName = Get-SafeAssetName -Name ([string]$asset.name)
        if ($assetName) {
            $assetUrl = [string]$asset.browser_download_url
            $assetSha256 = Get-AssetSha256 -Asset $asset
        }
    }

    return [pscustomobject]@{
        Tag         = [string]$json.tag_name
        Name        = [string]$json.name
        Body        = [string]$json.body
        HtmlUrl     = [string]$json.html_url
        AssetName   = $assetName
        AssetUrl    = $assetUrl
        AssetSha256 = $assetSha256
        PublishedAt = [string]$json.published_at
    }
}

function Get-LatestGuiRelease {
    $raw = Invoke-CurlText -Url $script:ZC_GuiReleasesApi -TimeoutSec 20
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }

    try { $json = $raw | ConvertFrom-Json } catch { return $null }
    if (-not $json.tag_name) { return $null }

    $asset = @($json.assets) | Where-Object { $_.name -like 'zapret-gui-*.zip' } | Select-Object -First 1
    $assetName = $null
    $assetUrl = $null
    $assetSha256 = $null
    if ($asset) {
        # Невалидное имя — релиз без ассета: качать по такому пути нельзя.
        $assetName = Get-SafeAssetName -Name ([string]$asset.name)
        if ($assetName) {
            $assetUrl = [string]$asset.browser_download_url
            $assetSha256 = Get-AssetSha256 -Asset $asset
        }
    }

    return [pscustomobject]@{
        Tag         = [string]$json.tag_name
        Name        = [string]$json.name
        Body        = [string]$json.body
        HtmlUrl     = [string]$json.html_url
        AssetName   = $assetName
        AssetUrl    = $assetUrl
        AssetSha256 = $assetSha256
        PublishedAt = [string]$json.published_at
    }
}

function ConvertFrom-MarkdownNotes {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $result = $Text -replace "`r`n", "`n"
    $result = [regex]::Replace($result, '(?m)^\s{0,3}#{1,6}\s*', '')
    $result = [regex]::Replace($result, '\[([^\]]+)\]\((https?://[^)\s]+)\)', '$1 ($2)')
    $result = $result -replace '\*\*([^*]+)\*\*', '$1'
    $result = $result -replace '__([^_]+)__', '$1'
    $result = $result -replace '`([^`]+)`', '$1'
    return $result.Trim()
}

function Test-UrlAvailability {
    param(
        [string]$Url,
        [int]$TimeoutSec = 6
    )

    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        $output = & curl.exe -s -o NUL -w '%{http_code}' --max-time $TimeoutSec --connect-timeout 4 --noproxy '*' $Url 2>$null
        $code = (($output | Out-String).Trim())
        return [pscustomobject]@{
            Code = $code
            Ok   = ($code -match '^(2|3)\d\d$')
        }
    }

    try {
        $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec -MaximumRedirection 5
        $code = [int]$response.StatusCode
        return [pscustomobject]@{
            Code = [string]$code
            Ok   = ($code -ge 200 -and $code -lt 400)
        }
    } catch {
        return [pscustomobject]@{ Code = 'ERR'; Ok = $false }
    }
}
