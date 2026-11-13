# ============================================================================
#  Zapret Control - общие функции
#  GUI / форк: Bugulmek
#  Пакет zapret: Flowseal
#  https://github.com/Flowseal/zapret-discord-youtube
# ============================================================================

$script:ZC_AppName      = 'Zapret Control'
$script:ZC_AppVersion   = '1.0.0'
$script:ZC_UpstreamRepo = 'Flowseal/zapret-discord-youtube'
$script:ZC_ReleasesApi  = 'https://api.github.com/repos/Flowseal/zapret-discord-youtube/releases/latest'
$script:ZC_ReleasesPage = 'https://github.com/Flowseal/zapret-discord-youtube/releases/latest'
$script:ZC_IpsetUrl     = 'https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/refs/heads/main/.service/ipset-service.txt'
$script:ZC_HostsUrl     = 'https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/refs/heads/main/.service/hosts'
$script:ZC_VersionCache = @{}

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

    $best = $null
    $bestVersion = $null
    foreach ($item in $candidates) {
        $leaf = Split-Path -Leaf $item
        $match = [regex]::Match($leaf, '(\d+(?:\.\d+){1,3})')
        $version = $null
        if ($match.Success) {
            try { $version = [version]$match.Groups[1].Value } catch { $version = $null }
        }
        if ($null -eq $bestVersion -or ($null -ne $version -and $version -gt $bestVersion)) {
            $best = $item
            if ($null -ne $version) { $bestVersion = $version }
        }
    }
    if (-not $best) { $best = $candidates[0] }
    return $best
}

# ---------------------------------------------------------------------------
#  Стратегии и аргументы winws.exe
# ---------------------------------------------------------------------------
function Get-Strategies {
    param([string]$Root)

    if (-not (Test-Path -LiteralPath $Root)) { return @() }

    $files = @(Get-ChildItem -LiteralPath $Root -Filter '*.bat' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike 'service*' } |
        Sort-Object { [regex]::Replace($_.Name, '(\d+)', { $args[0].Value.PadLeft(8, '0') }) })

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

    foreach ($line in [IO.File]::ReadAllLines($state.FilePath)) {
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
    $builder = New-Object System.Text.StringBuilder
    $capture = $false

    foreach ($line in $lines) {
        if (-not $capture) {
            if ($line -match 'winws\.exe') { $capture = $true } else { continue }
        }
        $trimmed = $line.TrimEnd()
        if ($trimmed.EndsWith('^')) {
            [void]$builder.Append($trimmed.Substring(0, $trimmed.Length - 1)).Append(' ')
        } else {
            [void]$builder.Append($trimmed)
            break
        }
    }

    if ($builder.Length -eq 0) { return $null }

    $text = $builder.ToString()
    $match = [regex]::Match($text, 'winws\.exe"?\s*(.*)$', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) { return $null }

    $argLine = $match.Groups[1].Value.Trim()
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

    $argLine = $argLine.Replace('%~dp0', $rootSlash)
    $argLine = $argLine.Replace('%BIN%', $binSlash)
    $argLine = $argLine.Replace('%LISTS%', $listsSlash)
    $argLine = $argLine.Replace('%GameFilterTCP%', $tcp)
    $argLine = $argLine.Replace('%GameFilterUDP%', $udp)
    $argLine = $argLine.Replace('%GameFilter%', $generic)

    return $argLine
}

# ---------------------------------------------------------------------------
#  IPSet
# ---------------------------------------------------------------------------
function Get-IpsetState {
    param([string]$Root)

    $file = Join-Path $Root 'lists\ipset-all.txt'
    if (-not (Test-Path -LiteralPath $file)) { return 'none' }

    $info = Get-Item -LiteralPath $file -ErrorAction SilentlyContinue
    if (-not $info -or $info.Length -eq 0) { return 'any' }

    $head = ''
    try {
        $stream = [IO.File]::Open($file, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $size = [int][Math]::Min(4096, $info.Length)
            $buffer = New-Object byte[] $size
            $read = $stream.Read($buffer, 0, $size)
            $head = [Text.Encoding]::ASCII.GetString($buffer, 0, $read)
        } finally {
            $stream.Dispose()
        }
    } catch {
        return 'loaded'
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
    $current = Get-IpsetState -Root $Root

    switch ($Mode) {
        'none' {
            if ($current -eq 'none') { return }
            if ($current -eq 'loaded') {
                if (Test-Path -LiteralPath $backupFile) { Remove-Item -LiteralPath $backupFile -Force }
                Move-Item -LiteralPath $listFile -Destination $backupFile -Force
            }
            Set-Content -LiteralPath $listFile -Value '203.0.113.113/32' -Encoding Ascii
        }
        'any' {
            if ($current -eq 'any') { return }
            if ($current -eq 'loaded') {
                if (Test-Path -LiteralPath $backupFile) { Remove-Item -LiteralPath $backupFile -Force }
                Copy-Item -LiteralPath $listFile -Destination $backupFile -Force
            }
            Set-Content -LiteralPath $listFile -Value '' -Encoding Ascii
        }
        'loaded' {
            if ($current -eq 'loaded') { return }
            if (-not (Test-Path -LiteralPath $backupFile)) {
                throw 'Нет резервной копии списка IPSet. Сначала обновите IPSet (кнопка «Обновить IPSet»).'
            }
            Remove-Item -LiteralPath $listFile -Force -ErrorAction SilentlyContinue
            Move-Item -LiteralPath $backupFile -Destination $listFile -Force
        }
        default { throw "Неизвестный режим IPSet: $Mode" }
    }
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
    param([string]$Name = 'zapret')

    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $service) { return $false }

    if ($service.Status -ne 'Stopped') {
        try { Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue } catch { }
        for ($i = 0; $i -lt 24; $i++) {
            try { $service.Refresh() } catch { }
            if ($service.Status -eq 'Stopped') { break }
            Start-Sleep -Milliseconds 250
        }
    }
    return $true
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
    $match = [regex]::Match([IO.File]::ReadAllText($file), 'LOCAL_VERSION\s*=\s*([0-9][0-9A-Za-z\.\-]*)')
    if ($match.Success) { $version = $match.Groups[1].Value.Trim() }

    $script:ZC_VersionCache[$file] = [pscustomobject]@{ Stamp = $stamp; Version = $version }
    return $version
}

function Invoke-CurlText {
    param(
        [string]$Url,
        [int]$TimeoutSec = 20
    )

    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        $output = & curl.exe -s -L --max-time $TimeoutSec -H 'User-Agent: ZapretControl' $Url 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        return (($output | Out-String).Trim())
    }

    try {
        $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec -Headers @{ 'User-Agent' = 'ZapretControl' }
        return $response.Content
    } catch {
        return $null
    }
}

function Invoke-CurlDownload {
    param(
        [string]$Url,
        [string]$OutFile,
        [int]$TimeoutSec = 300
    )

    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        & curl.exe -L -f -s --max-time $TimeoutSec -o $OutFile $Url 2>$null
        return ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $OutFile))
    }

    try {
        Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec -OutFile $OutFile
        return (Test-Path -LiteralPath $OutFile)
    } catch {
        return $false
    }
}

function Get-LatestZapretRelease {
    $raw = Invoke-CurlText -Url $script:ZC_ReleasesApi -TimeoutSec 20
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }

    try { $json = $raw | ConvertFrom-Json } catch { return $null }
    if (-not $json.tag_name) { return $null }

    $asset = @($json.assets) | Where-Object { $_.name -like '*.zip' } | Select-Object -First 1
    $assetName = $null
    $assetUrl = $null
    if ($asset) {
        $assetName = [string]$asset.name
        $assetUrl = [string]$asset.browser_download_url
    }

    return [pscustomobject]@{
        Tag         = [string]$json.tag_name
        Name        = [string]$json.name
        Body        = [string]$json.body
        HtmlUrl     = [string]$json.html_url
        AssetName   = $assetName
        AssetUrl    = $assetUrl
        PublishedAt = [string]$json.published_at
    }
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
