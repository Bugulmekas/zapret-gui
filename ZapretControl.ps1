#Requires -Version 5.1
<#
    Zapret Control - графический управлятор zapret-discord-youtube
    GUI / форк: Bugulmek
    Пакет zapret и источник обновлений: Flowseal
    https://github.com/Flowseal/zapret-discord-youtube

    Интерфейс: WPF + XAML.
    Запускать через ZapretControl.bat (сам запросит права администратора).
#>

param([switch]$SelfTest, [switch]$Preview, [int]$PreviewSeconds = 2)

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

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
    Theme               = 'dark'
}

if (Test-Path -LiteralPath $script:ConfigPath) {
    try {
        $loaded = Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($loaded.ZapretRoot) { $script:Config.ZapretRoot = [string]$loaded.ZapretRoot }
        if ($loaded.SelectedStrategy) { $script:Config.SelectedStrategy = [string]$loaded.SelectedStrategy }
        if ($loaded.LastStartedStrategy) { $script:Config.LastStartedStrategy = [string]$loaded.LastStartedStrategy }
        if ($null -ne $loaded.CheckUpdatesOnStart) { $script:Config.CheckUpdatesOnStart = [bool]$loaded.CheckUpdatesOnStart }
        if ($loaded.Theme) { $script:Config.Theme = [string]$loaded.Theme }
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
        [void][Windows.MessageBox]::Show(
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
    [void][Windows.MessageBox]::Show(
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
#  Состояние интерфейса
# ---------------------------------------------------------------------------
$script:Window          = $null
$script:Form            = $null
$script:StatusLabels    = @{}
$script:AdminPillShimmer = $false
$script:VpnWarningShown  = $false
$script:LstStrategies   = $null
$script:RtbLog          = $null
$script:StatusLabel     = $null
$script:AdminPill       = $null
$script:AdminPillText   = $null
$script:AdminPillDot    = $null
$script:VpnPill         = $null
$script:VpnPillText     = $null
$script:VpnStateChecked = [DateTime]::MinValue
$script:LatestRelease   = $null
$script:UpdateAvailable = $false
$script:SyncingUi       = $false
$script:SyncInputs      = $false
$script:StrategyFiles   = @()

$script:UiFont   = New-Object Windows.Media.FontFamily('Segoe UI Variable Text, Segoe UI')
$script:UiFontDisplay = New-Object Windows.Media.FontFamily('Segoe UI Variable Display, Segoe UI Variable Text, Segoe UI')
$script:UiFontMono = New-Object Windows.Media.FontFamily('Cascadia Mono, Consolas, Courier New')

$script:BrushCache = @{}
function Get-Brush {
    param([string]$Hex)
    if (-not $script:BrushCache.ContainsKey($Hex)) {
        $converter = New-Object Windows.Media.BrushConverter
        $script:BrushCache[$Hex] = $converter.ConvertFromString($Hex)
    }
    return $script:BrushCache[$Hex]
}

$script:Themes = @{
    light = @{
        Canvas = '#F5F5F7'; Surface = '#FFFFFF'; Ink = '#1D1D1F'; Body = '#3A3A3C'
        Muted = '#6E6E73'; Hairline = '#E5E5EA'; Field = '#F2F2F7'; FieldHover = '#E9E9EE'
        Accent = '#0071E3'; AccentText = '#FFFFFF'; Danger = '#D70015'; DangerSoft = '#FDECEB'
        WindowBorder = '#D6D6DB'; NavActive = '#FFFFFF'; CheckBorder = '#C7C7CC'; CheckHover = '#8E8E93'
        ListHover = '#F7F7F9'; FocusBorder = '#9CC7F2'; Selection = '#B3D7F7'; LogBg = '#FBFBFD'
        CardBorder = '#E5E5EA'; ListSelected = '#F2F2F7'; MenuItemHover = '#F2F2F7'; Thumb = '#C7C7CC'; NavActiveText = '#1D1D1F'
        Green = '#248A3D'; Red = '#D70015'; Orange = '#B25000'
        LogText = '#3A3A3C'; LogGray = '#8E8E93'; LogCyan = '#0A6E9E'; LogBlue = '#0A5BB5'
        PillOk = '#E8F6EC'; PillBad = '#FDECEB'; PillOkDot = '#34C759'; PillBadDot = '#FF3B30'
        PillWarn = '#FFF4E5'; PillWarnDot = '#FF9500'
    }
    dark = @{
        Canvas = '#111113'; Surface = '#1A1A1D'; Ink = '#F5F5F7'; Body = '#C7C7CC'
        Muted = '#8E8E93'; Hairline = '#2A2A2F'; Field = '#26262A'; FieldHover = '#303036'
        Accent = '#0A84FF'; AccentText = '#FFFFFF'; Danger = '#FF453A'; DangerSoft = '#33191A'
        WindowBorder = '#2A2A2F'; NavActive = '#303036'; CheckBorder = '#56565C'; CheckHover = '#8E8E93'
        ListHover = '#202024'; FocusBorder = '#0A84FF'; Selection = '#2F4C73'; LogBg = '#151517'
        CardBorder = '#2A2A2F'; ListSelected = '#303036'; MenuItemHover = '#303036'; Thumb = '#56565C'; NavActiveText = '#F5F5F7'
        Green = '#30D158'; Red = '#FF453A'; Orange = '#FF9F0A'
        LogText = '#C7C7CC'; LogGray = '#8E8E93'; LogCyan = '#64D2FF'; LogBlue = '#0A84FF'
        PillOk = '#17301F'; PillBad = '#331715'; PillOkDot = '#34C759'; PillBadDot = '#FF453A'
        PillWarn = '#33240F'; PillWarnDot = '#FFB340'
    }
    neon = @{
        Canvas = '#0D1117'; Surface = '#0E1626'; Ink = '#E7F2FF'; Body = '#A9BCD6'
        Muted = '#7C8DA6'; Hairline = '#1C2B45'; Field = '#111C2E'; FieldHover = '#16233A'
        Accent = '#00F5FF'; AccentText = '#04121A'; Danger = '#FF2BD6'; DangerSoft = '#2A0F2A'
        WindowBorder = '#1C2B45'; NavActive = '#16233A'; CheckBorder = '#2A3E5E'; CheckHover = '#00F5FF'
        ListHover = '#13203A'; FocusBorder = '#00F5FF'; Selection = '#193A55'; LogBg = '#0A101C'
        CardBorder = '#22406B'; ListSelected = '#16324F'; MenuItemHover = '#16324F'; Thumb = '#1E5C6B'; NavActiveText = '#00F5FF'
        Green = '#3DF5A5'; Red = '#FF5470'; Orange = '#FFC24B'
        LogText = '#A9BCD6'; LogGray = '#64748B'; LogCyan = '#00F5FF'; LogBlue = '#7A5CFF'
        PillOk = '#0C2A24'; PillBad = '#2A0F2A'; PillOkDot = '#3DF5A5'; PillBadDot = '#FF2BD6'
        PillWarn = '#2A1F0A'; PillWarnDot = '#FFC24B'
    }
}

$script:ThemeName = ''
$script:CurrentPalette = $script:Themes['dark']

function Set-ThemeBrushVars {
    param([hashtable]$Palette)
    $script:BrCanvas     = Get-Brush $Palette.Canvas
    $script:BrSurface    = Get-Brush $Palette.Surface
    $script:BrInk        = Get-Brush $Palette.Ink
    $script:BrBody       = Get-Brush $Palette.Body
    $script:BrMuted      = Get-Brush $Palette.Muted
    $script:BrGreen      = Get-Brush $Palette.Green
    $script:BrRed        = Get-Brush $Palette.Red
    $script:BrOrange     = Get-Brush $Palette.Orange
    $script:BrAccent     = Get-Brush $Palette.Accent
    $script:BrLogText    = Get-Brush $Palette.LogText
    $script:BrLogGray    = Get-Brush $Palette.LogGray
    $script:BrLogCyan    = Get-Brush $Palette.LogCyan
    $script:BrLogBlue    = Get-Brush $Palette.LogBlue
    $script:BrPillOk     = Get-Brush $Palette.PillOk
    $script:BrPillBad    = Get-Brush $Palette.PillBad
    $script:BrPillOkDot  = Get-Brush $Palette.PillOkDot
    $script:BrPillBadDot = Get-Brush $Palette.PillBadDot
    $script:BrPillWarn   = Get-Brush $Palette.PillWarn
    $script:BrPillWarnDot = Get-Brush $Palette.PillWarnDot
}

function New-NeonGradient {
    param([string[]]$Colors)
    $brush = New-Object Windows.Media.LinearGradientBrush
    $brush.StartPoint = New-Object Windows.Point(0, 0)
    $brush.EndPoint = New-Object Windows.Point(1, 0)
    for ($i = 0; $i -lt $Colors.Count; $i++) {
        $stop = New-Object Windows.Media.GradientStop
        $stop.Color = (Get-Brush $Colors[$i]).Color
        if ($Colors.Count -gt 1) { $stop.Offset = $i / ($Colors.Count - 1) }
        [void]$brush.GradientStops.Add($stop)
    }
    return [Windows.Media.Brush]$brush
}

function New-Glow {
    param([string]$Hex, [double]$Blur = 14, [double]$Opacity = 0.55)
    $effect = New-Object Windows.Media.Effects.DropShadowEffect
    $effect.Color = (Get-Brush $Hex).Color
    $effect.BlurRadius = $Blur
    $effect.ShadowDepth = 0
    $effect.Opacity = $Opacity
    return [Windows.Media.Effects.Effect]$effect
}

function New-ShimmerBrush {
    param([string[]]$Colors = @('#00F5FF', '#7A5CFF', '#FF2BD6', '#00F5FF'))

    $brush = New-Object Windows.Media.LinearGradientBrush
    $brush.StartPoint = New-Object Windows.Point(0, 0)
    $brush.EndPoint = New-Object Windows.Point(1, 0)

    for ($i = 0; $i -lt $Colors.Count; $i++) {
        $stop = New-Object Windows.Media.GradientStop
        $stop.Color = (Get-Brush $Colors[$i]).Color
        if ($Colors.Count -gt 1) { $stop.Offset = $i / ($Colors.Count - 1) }
        [void]$brush.GradientStops.Add($stop)

        $nextColor = (Get-Brush $Colors[($i + 1) % $Colors.Count]).Color
        $animation = New-Object Windows.Media.Animation.ColorAnimation
        $animation.From = $stop.Color
        $animation.To = $nextColor
        $animation.Duration = [Windows.Duration]([TimeSpan]::FromSeconds(2.6))
        $animation.AutoReverse = $true
        $animation.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
        $animation.BeginTime = [TimeSpan]::FromMilliseconds(($i * 320) % 960)
        $stop.BeginAnimation([Windows.Media.GradientStop]::ColorProperty, $animation)
    }

    return [Windows.Media.Brush]$brush
}

Set-ThemeBrushVars $script:CurrentPalette

function Apply-Theme {
    param([string]$Name, [switch]$Save)

    if (-not $Name -or -not $script:Themes.ContainsKey($Name)) { $Name = 'dark' }
    if ($Name -eq $script:ThemeName -and $script:Window) { return }

    $palette = $script:Themes[$Name]
    $oldPalette = $script:CurrentPalette

    if ($script:Window) {
        foreach ($key in $palette.Keys) {
            $script:Window.Resources[$key] = Get-Brush $palette[$key]
        }
        $resources = $script:Window.Resources
        if ($Name -eq 'neon') {
            $resources['TitleBrush'] = New-NeonGradient @('#00F5FF', '#7A5CFF', '#FF2BD6')
            $resources['HeaderLineBrush'] = New-NeonGradient @('#00F5FF', '#7A5CFF', '#FF2BD6')
            $resources['NavLineBrush'] = New-NeonGradient @('#00F5FF', '#7A5CFF')
            $resources['TitleGlow'] = [Windows.Media.Effects.Effect](New-Glow '#00F5FF' 16 0.55)
            $resources['PrimaryGlow'] = [Windows.Media.Effects.Effect](New-Glow '#00F5FF' 14 0.45)
            $resources['CheckGlow'] = [Windows.Media.Effects.Effect](New-Glow '#00F5FF' 9 0.65)
        } else {
            $resources['TitleBrush'] = Get-Brush $palette.Ink
            $resources['HeaderLineBrush'] = Get-Brush '#00FFFFFF'
            $resources['NavLineBrush'] = Get-Brush $palette.Hairline
            $resources['TitleGlow'] = [Windows.Media.Effects.Effect](New-Glow '#000000' 0 0)
            $resources['PrimaryGlow'] = [Windows.Media.Effects.Effect](New-Glow '#000000' 0 0)
            $resources['CheckGlow'] = [Windows.Media.Effects.Effect](New-Glow '#000000' 0 0)
        }
        $script:Window.Background = Get-Brush $palette.Canvas
    }

    $script:ThemeName = $Name
    $script:CurrentPalette = $palette
    Set-ThemeBrushVars $palette

    if ($script:Window) {
        $themeButtons = @{ light = 'ThemeLight'; dark = 'ThemeDark'; neon = 'ThemeNeon' }
        foreach ($key in $themeButtons.Keys) {
            $button = $script:Window.FindName($themeButtons[$key])
            if ($button) { $button.IsChecked = ($key -eq $Name) }
        }
        if (Get-Command -Name Update-LogTheme -ErrorAction SilentlyContinue) {
            Update-LogTheme $oldPalette
        }
        if (Get-Command -Name Set-AdminPill -ErrorAction SilentlyContinue) {
            Set-AdminPill ([bool](Test-IsAdmin))
        }
        if (Get-Command -Name Update-AllStatus -ErrorAction SilentlyContinue) {
            try { Update-AllStatus } catch { }
        }
    }

    if ($Save) {
        $script:Config.Theme = $Name
        Save-Config
    }
}

$windowXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:shell="clr-namespace:System.Windows.Shell;assembly=PresentationFramework"
        Title="Zapret Control — управление zapret-discord-youtube (форк Bugulmek)"
        Width="1280" Height="940" MinWidth="1080" MinHeight="760"
        WindowStartupLocation="CenterScreen" Background="#111113"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="14"
        TextOptions.TextFormattingMode="Display" UseLayoutRounding="True"
        SnapsToDevicePixels="True" WindowStyle="None" ResizeMode="CanResize">
  <shell:WindowChrome.WindowChrome>
    <shell:WindowChrome CaptionHeight="0" ResizeBorderThickness="6" GlassFrameThickness="0" CornerRadius="0" UseAeroCaptionButtons="False"/>
  </shell:WindowChrome.WindowChrome>

  <Window.Resources>
    <SolidColorBrush x:Key="Canvas" Color="#111113"/>
    <SolidColorBrush x:Key="Surface" Color="#1A1A1D"/>
    <SolidColorBrush x:Key="Ink" Color="#F5F5F7"/>
    <SolidColorBrush x:Key="Body" Color="#C7C7CC"/>
    <SolidColorBrush x:Key="Muted" Color="#8E8E93"/>
    <SolidColorBrush x:Key="Hairline" Color="#2A2A2F"/>
    <SolidColorBrush x:Key="Field" Color="#26262A"/>
    <SolidColorBrush x:Key="FieldHover" Color="#303036"/>
    <SolidColorBrush x:Key="Accent" Color="#0A84FF"/>
    <SolidColorBrush x:Key="AccentText" Color="#FFFFFF"/>
    <SolidColorBrush x:Key="Danger" Color="#FF453A"/>
    <SolidColorBrush x:Key="DangerSoft" Color="#33191A"/>
    <SolidColorBrush x:Key="WindowBorder" Color="#2A2A2F"/>
    <SolidColorBrush x:Key="NavActive" Color="#303036"/>
    <SolidColorBrush x:Key="CheckBorder" Color="#56565C"/>
    <SolidColorBrush x:Key="CheckHover" Color="#8E8E93"/>
    <SolidColorBrush x:Key="ListHover" Color="#202024"/>
    <SolidColorBrush x:Key="FocusBorder" Color="#0A84FF"/>
    <SolidColorBrush x:Key="Selection" Color="#2F4C73"/>
    <SolidColorBrush x:Key="LogBg" Color="#151517"/>
    <SolidColorBrush x:Key="Green" Color="#30D158"/>
    <SolidColorBrush x:Key="Red" Color="#FF453A"/>
    <SolidColorBrush x:Key="Orange" Color="#FF9F0A"/>
    <SolidColorBrush x:Key="PillOk" Color="#17301F"/>
    <SolidColorBrush x:Key="PillBad" Color="#331715"/>
    <SolidColorBrush x:Key="PillOkDot" Color="#34C759"/>
    <SolidColorBrush x:Key="PillBadDot" Color="#FF453A"/>
    <SolidColorBrush x:Key="PillWarn" Color="#33240F"/>
    <SolidColorBrush x:Key="PillWarnDot" Color="#FFB340"/>
    <SolidColorBrush x:Key="CardBorder" Color="#2A2A2F"/>
    <SolidColorBrush x:Key="TitleBrush" Color="#F5F5F7"/>
    <SolidColorBrush x:Key="NavActiveText" Color="#F5F5F7"/>
    <SolidColorBrush x:Key="Thumb" Color="#56565C"/>
    <SolidColorBrush x:Key="ListSelected" Color="#303036"/>
    <SolidColorBrush x:Key="MenuItemHover" Color="#303036"/>
    <SolidColorBrush x:Key="HeaderLineBrush" Color="Transparent"/>
    <SolidColorBrush x:Key="NavLineBrush" Color="#2A2A2F"/>
    <DropShadowEffect x:Key="TitleGlow" BlurRadius="0" ShadowDepth="0" Opacity="0"/>
    <DropShadowEffect x:Key="PrimaryGlow" BlurRadius="0" ShadowDepth="0" Opacity="0"/>
    <DropShadowEffect x:Key="CheckGlow" BlurRadius="0" ShadowDepth="0" Opacity="0"/>

    <Style x:Key="ZcFocus">
      <Setter Property="Control.Template">
        <Setter.Value>
          <ControlTemplate>
            <Border Margin="2" CornerRadius="10" BorderBrush="{DynamicResource FocusBorder}" BorderThickness="2"/>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="ZcCard" TargetType="Border">
      <Setter Property="Background" Value="{DynamicResource Surface}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource CardBorder}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="14"/>
      <Setter Property="Padding" Value="18"/>
      <Setter Property="Margin" Value="0,0,0,12"/>
    </Style>

    <Style x:Key="ZcCardTitle" TargetType="TextBlock">
      <Setter Property="FontSize" Value="14.5"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="{DynamicResource Ink}"/>
    </Style>

    <Style x:Key="ZcHint" TargetType="TextBlock">
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Foreground" Value="{DynamicResource Muted}"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="LineHeight" Value="18"/>
    </Style>

    <Style x:Key="ZcBody" TargetType="TextBlock">
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Foreground" Value="{DynamicResource Body}"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="LineHeight" Value="20"/>
    </Style>

    <Style x:Key="ZcFieldLabel" TargetType="TextBlock">
      <Setter Property="FontSize" Value="11.5"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="{DynamicResource Muted}"/>
      <Setter Property="Margin" Value="1,0,0,6"/>
    </Style>

    <Style x:Key="ZcPageTitle" TargetType="TextBlock">
      <Setter Property="FontSize" Value="19"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="{DynamicResource TitleBrush}"/>
    </Style>

    <Style x:Key="ZcButtonBase" TargetType="Button">
      <Setter Property="Height" Value="38"/>
      <Setter Property="Padding" Value="16,0"/>
      <Setter Property="FontSize" Value="13.5"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="FocusVisualStyle" Value="{StaticResource ZcFocus}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="9"
                    Padding="{TemplateBinding Padding}" Effect="{TemplateBinding Effect}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"
                                TextElement.Foreground="{TemplateBinding Foreground}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Opacity" Value="0.86"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Opacity" Value="0.7"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Opacity" Value="0.4"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="ZcPrimary" TargetType="Button" BasedOn="{StaticResource ZcButtonBase}">
      <Setter Property="Background" Value="{DynamicResource Accent}"/>
      <Setter Property="Foreground" Value="{DynamicResource AccentText}"/>
      <Setter Property="Effect" Value="{DynamicResource PrimaryGlow}"/>
    </Style>

    <Style x:Key="ZcSecondary" TargetType="Button" BasedOn="{StaticResource ZcButtonBase}">
      <Setter Property="Background" Value="{DynamicResource Field}"/>
      <Setter Property="Foreground" Value="{DynamicResource Ink}"/>
    </Style>

    <Style x:Key="ZcDangerText" TargetType="Button" BasedOn="{StaticResource ZcButtonBase}">
      <Setter Property="Background" Value="{DynamicResource DangerSoft}"/>
      <Setter Property="Foreground" Value="{DynamicResource Danger}"/>
    </Style>

    <Style x:Key="ZcGhost" TargetType="Button" BasedOn="{StaticResource ZcButtonBase}">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="{DynamicResource Accent}"/>
      <Setter Property="FontWeight" Value="Normal"/>
      <Setter Property="Height" Value="30"/>
      <Setter Property="Padding" Value="8,0"/>
      <Setter Property="FontSize" Value="12.5"/>
    </Style>

    <Style x:Key="ZcPrimarySmall" TargetType="Button" BasedOn="{StaticResource ZcPrimary}">
      <Setter Property="Height" Value="34"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Padding" Value="10,0"/>
    </Style>

    <Style x:Key="ZcSecondarySmall" TargetType="Button" BasedOn="{StaticResource ZcSecondary}">
      <Setter Property="Height" Value="34"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Padding" Value="10,0"/>
    </Style>

    <Style x:Key="ZcSmall" TargetType="Button" BasedOn="{StaticResource ZcSecondary}">
      <Setter Property="Height" Value="30"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="FontWeight" Value="Normal"/>
      <Setter Property="Padding" Value="12,0"/>
    </Style>

    <Style x:Key="ZcWindowButton" TargetType="Button">
      <Setter Property="Width" Value="40"/>
      <Setter Property="Height" Value="30"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="{DynamicResource Muted}"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="7">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"
                                TextElement.Foreground="{TemplateBinding Foreground}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{DynamicResource FieldHover}"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Opacity" Value="0.65"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="ZcNav" TargetType="RadioButton">
      <Setter Property="Foreground" Value="{DynamicResource Muted}"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{StaticResource ZcFocus}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="Bd" CornerRadius="8" Background="Transparent" Padding="14,7">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"
                                TextElement.Foreground="{TemplateBinding Foreground}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{DynamicResource FieldHover}"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{DynamicResource NavActive}"/>
                <Setter Property="Foreground" Value="{DynamicResource NavActiveText}"/>
                <Setter Property="FontWeight" Value="SemiBold"/>
                <Setter TargetName="Bd" Property="Effect">
                  <Setter.Value>
                    <DropShadowEffect BlurRadius="7" ShadowDepth="1" Direction="270"
                                      Opacity="0.12" Color="#000000"/>
                  </Setter.Value>
                </Setter>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="ZcTheme" TargetType="RadioButton">
      <Setter Property="Foreground" Value="{DynamicResource Muted}"/>
      <Setter Property="FontSize" Value="11.5"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="Bd" CornerRadius="7" Background="Transparent" Padding="10,4">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"
                                TextElement.Foreground="{TemplateBinding Foreground}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{DynamicResource FieldHover}"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{DynamicResource NavActive}"/>
                <Setter Property="Foreground" Value="{DynamicResource NavActiveText}"/>
                <Setter Property="FontWeight" Value="SemiBold"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="ZcCheck" TargetType="CheckBox">
      <Setter Property="Foreground" Value="{DynamicResource Body}"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{StaticResource ZcFocus}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Border x:Name="Box" Width="18" Height="18" CornerRadius="5"
                      Background="{DynamicResource Surface}" BorderBrush="{DynamicResource CheckBorder}" BorderThickness="1.5"
                      VerticalAlignment="Center">
                <Grid>
                  <Path x:Name="Check" Data="M 0 4.5 L 4 8.5 L 12 0"
                        Width="12" Height="9" Stretch="Uniform"
                        Stroke="{DynamicResource AccentText}" StrokeThickness="2" StrokeStartLineCap="Round"
                        StrokeEndLineCap="Round" StrokeLineJoin="Round"
                        Visibility="Collapsed" HorizontalAlignment="Center"
                        VerticalAlignment="Center"/>
                </Grid>
              </Border>
              <ContentPresenter Margin="9,0,0,0" VerticalAlignment="Center"
                                TextElement.Foreground="{TemplateBinding Foreground}"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Box" Property="BorderBrush" Value="{DynamicResource CheckHover}"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Box" Property="Background" Value="{DynamicResource Accent}"/>
                <Setter TargetName="Box" Property="BorderBrush" Value="{DynamicResource Accent}"/>
                <Setter TargetName="Box" Property="Effect" Value="{DynamicResource CheckGlow}"/>
                <Setter TargetName="Check" Property="Visibility" Value="Visible"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Box" Property="Opacity" Value="0.45"/>
                <Setter Property="Foreground" Value="{DynamicResource Muted}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="ZcListItem" TargetType="ListBoxItem">
      <Setter Property="Padding" Value="12,9"/>
      <Setter Property="Margin" Value="0,1"/>
      <Setter Property="Foreground" Value="{DynamicResource Ink}"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="Bd" Background="Transparent" CornerRadius="8"
                    Padding="{TemplateBinding Padding}">
              <Grid>
                <Border x:Name="Mark" Width="2" HorizontalAlignment="Left" Margin="-12,2,0,2"
                        CornerRadius="1" Background="{DynamicResource Accent}" Visibility="Collapsed"/>
                <ContentPresenter VerticalAlignment="Center"/>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{DynamicResource ListHover}"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{DynamicResource ListSelected}"/>
                <Setter TargetName="Mark" Property="Visibility" Value="Visible"/>
                <Setter Property="Foreground" Value="{DynamicResource NavActiveText}"/>
                <Setter Property="FontWeight" Value="SemiBold"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="ZcList" TargetType="ListBox">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="0"/>
      <Setter Property="ScrollViewer.HorizontalScrollBarVisibility" Value="Disabled"/>
      <Setter Property="ScrollViewer.VerticalScrollBarVisibility" Value="Auto"/>
      <Setter Property="ItemContainerStyle" Value="{StaticResource ZcListItem}"/>
    </Style>

    <Style x:Key="ZcTextInput" TargetType="TextBox">
      <Setter Property="Height" Value="36"/>
      <Setter Property="Padding" Value="0"/>
      <Setter Property="Background" Value="{DynamicResource Field}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource Hairline}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Foreground" Value="{DynamicResource Ink}"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="CaretBrush" Value="{DynamicResource Ink}"/>
      <Setter Property="SelectionBrush" Value="{DynamicResource Selection}"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="Bd" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="9">
              <ScrollViewer x:Name="PART_ContentHost" Margin="12,0,10,0"
                            VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocusWithin" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource FocusBorder}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="ZcTextArea" TargetType="TextBox" BasedOn="{StaticResource ZcTextInput}">
      <Setter Property="Height" Value="Auto"/>
      <Setter Property="Padding" Value="0"/>
      <Setter Property="AcceptsReturn" Value="True"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="VerticalScrollBarVisibility" Value="Auto"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="Bd" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="9">
              <ScrollViewer x:Name="PART_ContentHost" Margin="12,8,8,8"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocusWithin" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource FocusBorder}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="ZcComboItem" TargetType="ComboBoxItem">
      <Setter Property="Padding" Value="10,7"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Foreground" Value="{DynamicResource Ink}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="Bd" Background="Transparent" CornerRadius="7"
                    Padding="{TemplateBinding Padding}">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{DynamicResource MenuItemHover}"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{DynamicResource MenuItemHover}"/>
                <Setter Property="FontWeight" Value="SemiBold"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="ZcThumb" TargetType="Thumb">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Thumb">
            <Border Background="{DynamicResource Thumb}" CornerRadius="4" Margin="2"/>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ScrollBar">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Width" Value="10"/>
      <Setter Property="MinWidth" Value="10"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.Thumb>
                  <Thumb Style="{StaticResource ZcThumb}"/>
                </Track.Thumb>
                <Track.DecreaseRepeatButton>
                  <RepeatButton x:Name="PageUp" Command="{x:Static ScrollBar.PageUpCommand}"
                                Opacity="0" Focusable="False"/>
                </Track.DecreaseRepeatButton>
                <Track.IncreaseRepeatButton>
                  <RepeatButton x:Name="PageDown" Command="{x:Static ScrollBar.PageDownCommand}"
                                Opacity="0" Focusable="False"/>
                </Track.IncreaseRepeatButton>
              </Track>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="Orientation" Value="Horizontal">
                <Setter TargetName="PART_Track" Property="Orientation" Value="Horizontal"/>
                <Setter TargetName="PART_Track" Property="IsDirectionReversed" Value="False"/>
                <Setter TargetName="PageUp" Property="Command" Value="{x:Static ScrollBar.PageLeftCommand}"/>
                <Setter TargetName="PageDown" Property="Command" Value="{x:Static ScrollBar.PageRightCommand}"/>
                <Setter Property="Width" Value="Auto"/>
                <Setter Property="MinWidth" Value="0"/>
                <Setter Property="Height" Value="10"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="ZcCombo" TargetType="ComboBox">
      <Setter Property="Height" Value="36"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Foreground" Value="{DynamicResource Ink}"/>
      <Setter Property="Background" Value="{DynamicResource Field}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource Hairline}"/>
      <Setter Property="ItemContainerStyle" Value="{StaticResource ZcComboItem}"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <Border x:Name="Bd" Background="{TemplateBinding Background}"
                      BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1"
                      CornerRadius="9"/>
              <ContentPresenter Content="{TemplateBinding SelectionBoxItem}"
                                Margin="12,0,32,0" VerticalAlignment="Center"
                                IsHitTestVisible="False"/>
              <Path Data="M 0 0 L 4 4 L 8 0" Stroke="{DynamicResource Muted}"
                    StrokeThickness="1.6" HorizontalAlignment="Right"
                    VerticalAlignment="Center" Margin="0,0,13,0"
                    IsHitTestVisible="False"/>
              <ToggleButton Focusable="False" ClickMode="Press"
                            Background="Transparent" BorderThickness="0"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border Background="Transparent"/>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <Popup IsOpen="{TemplateBinding IsDropDownOpen}" Placement="Bottom"
                     AllowsTransparency="True" PopupAnimation="Fade" Focusable="False">
                <Border Background="{DynamicResource Surface}" BorderBrush="{DynamicResource Hairline}"
                        BorderThickness="1" CornerRadius="10" Margin="0,4,0,0"
                        MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}"
                        MaxHeight="280">
                  <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <ItemsPresenter Margin="4"/>
                  </ScrollViewer>
                </Border>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocusWithin" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource FocusBorder}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border BorderBrush="{DynamicResource WindowBorder}" BorderThickness="1" Background="{DynamicResource Canvas}">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="92"/>
        <RowDefinition Height="76"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="34"/>
      </Grid.RowDefinitions>

      <!-- Шапка -->
      <Grid x:Name="HeaderBar" Grid.Row="0" Background="{DynamicResource Canvas}">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0" Margin="30,18,0,0" VerticalAlignment="Center">
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="Zapret Control" FontSize="26" FontWeight="SemiBold"
                       Foreground="{DynamicResource TitleBrush}" Effect="{DynamicResource TitleGlow}"
                       VerticalAlignment="Center"/>
            <Border Background="{DynamicResource Surface}" BorderBrush="{DynamicResource Hairline}"
                    BorderThickness="1" CornerRadius="999" Padding="9,2" Margin="12,5,0,0"
                    VerticalAlignment="Center">
              <TextBlock x:Name="VersionChipText" Text="1.3.0" FontSize="11.5"
                         FontWeight="SemiBold" Foreground="{DynamicResource Muted}"/>
            </Border>
          </StackPanel>
          <TextBlock x:Name="HeaderSubtitle" Text="Управление zapret-discord-youtube"
                     FontSize="12.5" Foreground="{DynamicResource Muted}" Margin="1,5,0,0"/>
        </StackPanel>
        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center" Margin="0,0,14,0">
          <Border Background="{DynamicResource Field}" CornerRadius="9"
                  Padding="2" Margin="0,0,12,0" VerticalAlignment="Center">
            <StackPanel Orientation="Horizontal">
              <RadioButton x:Name="ThemeLight" Content="Светлая" GroupName="Theme"
                           Style="{StaticResource ZcTheme}" Tag="light"/>
              <RadioButton x:Name="ThemeDark" Content="Тёмная" GroupName="Theme"
                           Style="{StaticResource ZcTheme}" Tag="dark"/>
              <RadioButton x:Name="ThemeNeon" Content="Неон" GroupName="Theme"
                           Style="{StaticResource ZcTheme}" Tag="neon"/>
            </StackPanel>
          </Border>
          <Border x:Name="VpnPill" Background="{DynamicResource PillWarn}" CornerRadius="999"
                  Padding="12,6" Margin="0,0,12,0" VerticalAlignment="Center" Visibility="Collapsed"
                  ToolTip="VPN и zapret вместе обычно отключают интернет">
            <StackPanel Orientation="Horizontal">
              <Ellipse x:Name="VpnPillDot" Width="7" Height="7" Fill="{DynamicResource PillWarnDot}"
                       VerticalAlignment="Center"/>
              <TextBlock x:Name="VpnPillText" Text="VPN активен" FontSize="12"
                         FontWeight="SemiBold" Foreground="{DynamicResource Ink}"
                         Margin="7,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
          </Border>
          <Border x:Name="AdminPill" Background="{DynamicResource PillOk}" CornerRadius="999"
                  Padding="12,6" Margin="0,0,12,0" VerticalAlignment="Center">
            <StackPanel Orientation="Horizontal">
              <Ellipse x:Name="AdminPillDot" Width="7" Height="7" Fill="{DynamicResource PillOkDot}"
                       VerticalAlignment="Center"/>
              <TextBlock x:Name="AdminPillText" Text="администратор" FontSize="12"
                         FontWeight="SemiBold" Foreground="{DynamicResource Ink}"
                         Margin="7,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
          </Border>
          <Button x:Name="BtnMinimize" Content="–" Style="{StaticResource ZcWindowButton}" ToolTip="Свернуть"/>
          <Button x:Name="BtnClose" Content="✕" Style="{StaticResource ZcWindowButton}" ToolTip="Закрыть"/>
        </StackPanel>
      </Grid>

      <Border Grid.Row="0" Height="1" VerticalAlignment="Bottom"
              Background="{DynamicResource HeaderLineBrush}"/>

      <!-- Состояние -->
      <Border Grid.Row="1" Margin="30,4,30,0" Style="{StaticResource ZcCard}" Padding="0">
        <Grid Height="64">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>

          <Border Grid.Row="0" Grid.Column="0" BorderBrush="{DynamicResource Hairline}" BorderThickness="0,0,1,0" Padding="22,0">
            <StackPanel VerticalAlignment="Center">
              <TextBlock Text="Режим zapret" Style="{StaticResource ZcFieldLabel}" Margin="0,0,0,3"/>
              <TextBlock x:Name="StatusService" Text="—" FontSize="15" FontWeight="SemiBold"
                         Foreground="{DynamicResource Ink}" TextTrimming="CharacterEllipsis"/>
            </StackPanel>
          </Border>
          <Border Grid.Row="0" Grid.Column="1" BorderBrush="{DynamicResource Hairline}" BorderThickness="0,0,1,0" Padding="22,0">
            <StackPanel VerticalAlignment="Center">
              <TextBlock Text="winws.exe" Style="{StaticResource ZcFieldLabel}" Margin="0,0,0,3"/>
              <TextBlock x:Name="StatusWinws" Text="—" FontSize="15" FontWeight="SemiBold"
                         Foreground="{DynamicResource Ink}" TextTrimming="CharacterEllipsis"/>
            </StackPanel>
          </Border>
          <Border Grid.Row="0" Grid.Column="2" BorderBrush="{DynamicResource Hairline}" BorderThickness="0,0,1,0" Padding="22,0">
            <StackPanel VerticalAlignment="Center">
              <TextBlock Text="Стратегия службы" Style="{StaticResource ZcFieldLabel}" Margin="0,0,0,3"/>
              <TextBlock x:Name="StatusStrategy" Text="—" FontSize="15" FontWeight="SemiBold"
                         Foreground="{DynamicResource Ink}" TextTrimming="CharacterEllipsis"/>
            </StackPanel>
          </Border>
          <Border Grid.Row="0" Grid.Column="3" BorderBrush="{DynamicResource Hairline}" BorderThickness="0,0,1,0" Padding="22,0">
            <StackPanel VerticalAlignment="Center">
              <TextBlock Text="IPSet" Style="{StaticResource ZcFieldLabel}" Margin="0,0,0,3"/>
              <TextBlock x:Name="StatusIpset" Text="—" FontSize="15" FontWeight="SemiBold"
                         Foreground="{DynamicResource Ink}" TextTrimming="CharacterEllipsis"/>
            </StackPanel>
          </Border>
          <Border Grid.Row="0" Grid.Column="4" Padding="22,0">
            <StackPanel VerticalAlignment="Center">
              <TextBlock Text="WinDivert" Style="{StaticResource ZcFieldLabel}" Margin="0,0,0,3"/>
              <TextBlock x:Name="StatusWinDivert" Text="—" FontSize="15" FontWeight="SemiBold"
                         Foreground="{DynamicResource Ink}" TextTrimming="CharacterEllipsis"/>
            </StackPanel>
          </Border>
        </Grid>
      </Border>

      <!-- Тело -->
      <Grid Grid.Row="2" Margin="30,12,30,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="320"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <Border Grid.Column="0" Style="{StaticResource ZcCard}" Padding="0" Margin="0,0,16,0">
          <Grid>
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <TextBlock Grid.Row="0" Text="Стратегии" Style="{StaticResource ZcCardTitle}" Margin="18,16,18,0"/>
            <TextBlock Grid.Row="1" Text="Двойной клик — запуск" Style="{StaticResource ZcHint}" Margin="18,3,18,10"/>
            <ListBox x:Name="LstStrategies" Grid.Row="2" Style="{StaticResource ZcList}" Margin="10,0,10,8"/>
            <TextBlock x:Name="LblServiceUsing" Grid.Row="3" Text="Служба использует: —"
                       Style="{StaticResource ZcHint}" Margin="19,8,19,10" TextTrimming="CharacterEllipsis"/>
            <Grid Grid.Row="4" Margin="10,0,10,12">
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
              </Grid.RowDefinitions>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <Button x:Name="BtnStart" Grid.Row="0" Grid.Column="0" Content="Запустить"
                      Style="{StaticResource ZcPrimarySmall}" Margin="0,0,5,8"/>
              <Button x:Name="BtnStop" Grid.Row="0" Grid.Column="1" Content="Остановить"
                      Style="{StaticResource ZcSecondarySmall}" Margin="5,0,0,8"/>
              <Button x:Name="BtnInstall" Grid.Row="1" Grid.Column="0" Content="Установить службу"
                      Style="{StaticResource ZcSecondarySmall}" Margin="0,0,5,0"/>
              <Button x:Name="BtnRemove" Grid.Row="1" Grid.Column="1" Content="Удалить службу"
                      Style="{StaticResource ZcSecondarySmall}" Margin="5,0,0,0"
                      Foreground="{DynamicResource Danger}"/>
            </Grid>
          </Grid>
        </Border>

        <Border Grid.Column="1" Style="{StaticResource ZcCard}" Padding="0">
          <Grid>
            <Grid.RowDefinitions>
              <RowDefinition Height="52"/>
              <RowDefinition Height="1"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <Border Grid.Row="0" Margin="14,9,14,7" Background="{DynamicResource Field}"
                    CornerRadius="10" Padding="3" HorizontalAlignment="Left">
              <StackPanel Orientation="Horizontal">
                <RadioButton x:Name="NavService" Content="Служба" GroupName="Nav" IsChecked="True" Style="{StaticResource ZcNav}" Tag="0"/>
                <RadioButton x:Name="NavSettings" Content="Настройки" GroupName="Nav" Style="{StaticResource ZcNav}" Tag="1"/>
                <RadioButton x:Name="NavTools" Content="Инструменты" GroupName="Nav" Style="{StaticResource ZcNav}" Tag="2"/>
                <RadioButton x:Name="NavTests" Content="Тест" GroupName="Nav" Style="{StaticResource ZcNav}" Tag="3"/>
                <RadioButton x:Name="NavUpdate" Content="Обновление" GroupName="Nav" Style="{StaticResource ZcNav}" Tag="4"/>
              </StackPanel>
            </Border>
            <Border Grid.Row="1" Background="{DynamicResource NavLineBrush}"/>
            <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
              <Grid Margin="22,18,22,20">

                <!-- Раздел: Служба -->
                <StackPanel x:Name="PageService">
                  <TextBlock Text="Служба" Style="{StaticResource ZcPageTitle}"/>
                  <TextBlock Text="Запуск стратегий, установка и удаление службы Windows."
                             Style="{StaticResource ZcHint}" Margin="2,6,0,16"/>
                  <Border Style="{StaticResource ZcCard}">
                    <StackPanel>
                      <TextBlock Text="Служба Windows «zapret»" Style="{StaticResource ZcCardTitle}"/>
                      <TextBlock Text="Закрепляет стратегию в системе и запускает её при старте Windows."
                                 Style="{StaticResource ZcHint}" Margin="0,6,0,16"/>
                      <CheckBox x:Name="ChkAutostart" Content="Запускать службу автоматически при старте Windows"
                                Style="{StaticResource ZcCheck}"/>
                      <WrapPanel Margin="0,16,0,0">
                        <Button x:Name="BtnStartService" Content="Запустить службу" Width="172"
                                Style="{StaticResource ZcPrimary}" Margin="0,0,10,10"/>
                        <Button x:Name="BtnStopService" Content="Остановить службу" Width="172"
                                Style="{StaticResource ZcSecondary}" Margin="0,0,10,10"/>
                        <Button x:Name="BtnRestartService" Content="Перезапустить" Width="172"
                                Style="{StaticResource ZcSecondary}" Margin="0,0,10,10"/>
                        <Button x:Name="BtnRemoveService" Content="Удалить службу" Width="172"
                                Style="{StaticResource ZcSecondary}" Margin="0,0,10,10"
                                Foreground="{DynamicResource Danger}"/>
                        <Button x:Name="BtnServiceBat" Content="Меню service.bat" Width="172"
                                Style="{StaticResource ZcSecondary}" Margin="0,0,10,10"/>
                        <Button x:Name="BtnOpenRoot" Content="Папка zapret" Width="152"
                                Style="{StaticResource ZcSecondary}" Margin="0,0,0,10"/>
                      </WrapPanel>
                    </StackPanel>
                  </Border>
                </StackPanel>

                <!-- Раздел: Настройки -->
                <StackPanel x:Name="PageSettings" Visibility="Collapsed">
                  <TextBlock Text="Настройки" Style="{StaticResource ZcPageTitle}"/>
                  <TextBlock Text="Игровой фильтр, IPSet и пользовательские списки."
                             Style="{StaticResource ZcHint}" Margin="2,6,0,16"/>
                  <Border Style="{StaticResource ZcCard}">
                    <StackPanel>
                      <TextBlock Text="Игровой фильтр" Style="{StaticResource ZcCardTitle}"/>
                      <TextBlock Text="Сужает порты, к которым применяется обход."
                                 Style="{StaticResource ZcHint}" Margin="0,6,0,16"/>
                      <Grid>
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="190"/>
                          <ColumnDefinition Width="16"/>
                          <ColumnDefinition Width="150"/>
                          <ColumnDefinition Width="16"/>
                          <ColumnDefinition Width="150"/>
                          <ColumnDefinition Width="16"/>
                          <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <StackPanel Grid.Column="0">
                          <TextBlock Text="Режим" Style="{StaticResource ZcFieldLabel}"/>
                          <ComboBox x:Name="CbGameMode" Style="{StaticResource ZcCombo}" SelectedIndex="0">
                            <ComboBoxItem Content="Выключен"/>
                            <ComboBoxItem Content="TCP и UDP"/>
                            <ComboBoxItem Content="Только TCP"/>
                            <ComboBoxItem Content="Только UDP"/>
                          </ComboBox>
                        </StackPanel>
                        <StackPanel Grid.Column="2">
                          <TextBlock Text="TCP-порты" Style="{StaticResource ZcFieldLabel}"/>
                          <TextBox x:Name="TxtGameTcp" Text="1024-65535" Style="{StaticResource ZcTextInput}"/>
                        </StackPanel>
                        <StackPanel Grid.Column="4">
                          <TextBlock Text="UDP-порты" Style="{StaticResource ZcFieldLabel}"/>
                          <TextBox x:Name="TxtGameUdp" Text="1024-65535" Style="{StaticResource ZcTextInput}"/>
                        </StackPanel>
                        <Button x:Name="BtnApplyGame" Grid.Column="6" Content="Применить" Width="130"
                                Style="{StaticResource ZcPrimary}" VerticalAlignment="Bottom"/>
                      </Grid>
                      <TextBlock Text="Формат: 1024-65535 или 1024-1934,1936-65535. Нужен перезапуск zapret."
                                 Style="{StaticResource ZcHint}" Margin="0,14,0,0"/>
                    </StackPanel>
                  </Border>

                  <Border Style="{StaticResource ZcCard}">
                    <StackPanel>
                      <TextBlock Text="IPSet-фильтр" Style="{StaticResource ZcCardTitle}"/>
                      <TextBlock Text="loaded — по списку, none — только исключения, any — без списка."
                                 Style="{StaticResource ZcHint}" Margin="0,6,0,16"/>
                      <StackPanel Orientation="Horizontal">
                        <StackPanel Width="240">
                          <TextBlock Text="Режим" Style="{StaticResource ZcFieldLabel}"/>
                          <ComboBox x:Name="CbIpset" Style="{StaticResource ZcCombo}" SelectedIndex="0">
                            <ComboBoxItem Content="Любой (any)"/>
                            <ComboBoxItem Content="Отключён (none)"/>
                            <ComboBoxItem Content="Загружен (loaded)"/>
                          </ComboBox>
                        </StackPanel>
                        <Button x:Name="BtnApplyIpset" Content="Применить" Width="120"
                                Style="{StaticResource ZcPrimary}" Margin="16,20,10,0" VerticalAlignment="Top"/>
                        <Button x:Name="BtnUpdateIpset" Content="Обновить IPSet" Width="160"
                                Style="{StaticResource ZcSecondary}" Margin="0,20,0,0" VerticalAlignment="Top"/>
                      </StackPanel>
                      <TextBlock Text="Скачивает свежий список с GitHub в lists\ipset-all.txt."
                                 Style="{StaticResource ZcHint}" Margin="0,14,0,0"/>
                    </StackPanel>
                  </Border>

                  <Border Style="{StaticResource ZcCard}">
                    <StackPanel>
                      <TextBlock Text="Автопроверка обновлений пакета" Style="{StaticResource ZcCardTitle}"/>
                      <CheckBox x:Name="ChkBatUpdates" Style="{StaticResource ZcCheck}" Margin="0,12,0,0"
                                Content="Проверять обновления при запуске general*.bat"/>
                      <TextBlock Text="Встроенная проверка пакета (utils\check_updates.enabled)."
                                 Style="{StaticResource ZcHint}" Margin="0,8,0,0"/>
                    </StackPanel>
                  </Border>

                  <Border Style="{StaticResource ZcCard}" Margin="0">
                    <StackPanel>
                      <TextBlock Text="Пользовательские списки" Style="{StaticResource ZcCardTitle}"/>
                      <TextBlock Text="Файлы *-user.txt откроются в Блокноте."
                                 Style="{StaticResource ZcHint}" Margin="0,6,0,14"/>
                      <WrapPanel>
                        <Button x:Name="BtnListGeneral" Content="Общие домены" Width="168"
                                Style="{StaticResource ZcSecondary}" Margin="0,0,10,10"/>
                        <Button x:Name="BtnListExclude" Content="Исключения" Width="168"
                                Style="{StaticResource ZcSecondary}" Margin="0,0,10,10"/>
                        <Button x:Name="BtnListIpset" Content="IP-исключения" Width="168"
                                Style="{StaticResource ZcSecondary}" Margin="0,0,10,10"/>
                        <Button x:Name="BtnListFolder" Content="Папка lists" Width="152"
                                Style="{StaticResource ZcSecondary}" Margin="0,0,0,10"/>
                      </WrapPanel>
                    </StackPanel>
                  </Border>
                </StackPanel>

                <!-- Раздел: Инструменты -->
                <StackPanel x:Name="PageTools" Visibility="Collapsed">
                  <TextBlock Text="Сервисные действия" Style="{StaticResource ZcPageTitle}"/>
                  <TextBlock Text="Результат выполнения — в журнале внизу."
                             Style="{StaticResource ZcHint}" Margin="2,6,0,16"/>
                  <Border Style="{StaticResource ZcCard}" Margin="0">
                    <StackPanel>
                      <UniformGrid Columns="3">
                        <Button x:Name="BtnToolIpset" Content="Обновить IPSet" Height="44"
                                Style="{StaticResource ZcSecondary}" Margin="0,0,10,10"/>
                        <Button x:Name="BtnToolHosts" Content="Обновить hosts" Height="44"
                                Style="{StaticResource ZcSecondary}" Margin="0,0,10,10"/>
                        <Button x:Name="BtnToolDiag" Content="Диагностика" Height="44"
                                Style="{StaticResource ZcPrimary}" Margin="0,0,0,10"/>
                        <Button x:Name="BtnToolFakes" Content="Заменить active fake" Height="44"
                                Style="{StaticResource ZcSecondary}" Margin="0,0,10,10"/>
                        <Button x:Name="BtnToolDiscord" Content="Очистить кэш Discord" Height="44"
                                Style="{StaticResource ZcSecondary}" Margin="0,0,10,10"/>
                        <Button x:Name="BtnToolWinDivert" Content="Убрать конфликт WinDivert" Height="44"
                                Style="{StaticResource ZcSecondary}" Margin="0,0,0,10"/>
                        <Button x:Name="BtnToolOpenData" Content="Папка данных" Height="44"
                                Style="{StaticResource ZcSecondary}" Margin="0,0,10,0"/>
                        <Button x:Name="BtnToolServiceBat" Content="Меню service.bat" Height="44"
                                Style="{StaticResource ZcSecondary}" Margin="0,0,10,0"/>
                        <Button x:Name="BtnChooseFolder" Content="Выбрать папку zapret" Height="44"
                                Style="{StaticResource ZcSecondary}" Margin="0,0,0,0"/>
                      </UniformGrid>
                    </StackPanel>
                  </Border>
                </StackPanel>

                <!-- Раздел: Тест стратегий -->
                <StackPanel x:Name="PageTests" Visibility="Collapsed">
                  <TextBlock Text="Тест стратегий" Style="{StaticResource ZcPageTitle}"/>
                  <TextBlock Text="Штатный тест из utils\test zapret.ps1 — тот же, что пункт 12 меню service.bat."
                             Style="{StaticResource ZcHint}" Margin="2,6,0,16"/>
                  <Border Style="{StaticResource ZcCard}">
                    <StackPanel>
                      <TextBlock Text="Проверяет Discord, YouTube и другие цели по очереди. Занимает несколько минут; служба и winws.exe будут остановлены автоматически."
                                 Style="{StaticResource ZcHint}" Margin="0,0,0,16"/>
                      <WrapPanel>
                        <Button x:Name="BtnRunTests" Content="Запустить тест" Width="220" Height="44"
                                Style="{StaticResource ZcPrimary}" Margin="0,0,10,10"/>
                        <Button x:Name="BtnTestResults" Content="Папка результатов" Width="220" Height="44"
                                Style="{StaticResource ZcSecondary}" Margin="0,0,0,10"/>
                      </WrapPanel>
                    </StackPanel>
                  </Border>
                  <Border Style="{StaticResource ZcCard}" Margin="0">
                    <StackPanel>
                      <TextBlock Text="Быстрая проверка" Style="{StaticResource ZcCardTitle}"/>
                      <TextBlock Text="Discord, YouTube, Google и Cloudflare через curl."
                                 Style="{StaticResource ZcHint}" Margin="0,6,0,14"/>
                      <Button x:Name="BtnQuickCheck" Content="Проверить соединение" Width="220" Height="40"
                              Style="{StaticResource ZcSecondary}" HorizontalAlignment="Left"/>
                    </StackPanel>
                  </Border>
                </StackPanel>

                <!-- Раздел: Обновление -->
                <StackPanel x:Name="PageUpdate" Visibility="Collapsed">
                  <TextBlock Text="Обновление" Style="{StaticResource ZcPageTitle}"/>
                  <TextBlock Text="Источник: github.com/Flowseal/zapret-discord-youtube · GUI / форк: Bugulmek"
                             Style="{StaticResource ZcHint}" Margin="2,6,0,16"/>
                  <Border Style="{StaticResource ZcCard}">
                    <StackPanel>
                      <Border Background="{DynamicResource Field}" CornerRadius="10" Padding="14,12">
                        <StackPanel>
                          <TextBlock x:Name="LblUpdateLocal" Text="Установленная версия: —"
                                     FontSize="13.5" FontWeight="SemiBold" Foreground="{DynamicResource Ink}"/>
                          <TextBlock x:Name="LblUpdateLatest" Text="Последняя на GitHub: —"
                                     FontSize="12.5" Foreground="{DynamicResource Muted}" Margin="0,4,0,0"/>
                          <TextBlock x:Name="LblUpdateStatus" Text="Проверка ещё не выполнялась"
                                     FontSize="13" FontWeight="SemiBold" Foreground="{DynamicResource Muted}"
                                     Margin="0,10,0,0"/>
                        </StackPanel>
                      </Border>
                      <WrapPanel Margin="0,14,0,0">
                        <Button x:Name="BtnCheckUpdates" Content="Проверить обновления" Width="190"
                                Style="{StaticResource ZcSecondary}" Margin="0,0,10,10"/>
                        <Button x:Name="BtnInstallUpdate" Content="Скачать и установить" Width="190"
                                Style="{StaticResource ZcPrimary}" Margin="0,0,10,10" IsEnabled="False"/>
                        <Button x:Name="LinkReleases" Content="Страница релизов на GitHub"
                                Style="{StaticResource ZcGhost}" Margin="0,0,0,10"/>
                      </WrapPanel>
                      <CheckBox x:Name="ChkStartupUpdates" Style="{StaticResource ZcCheck}" Margin="0,6,0,0"
                                Content="Проверять обновления zapret и GUI при запуске"/>
                      <TextBlock Text="Новая версия zapret ставится рядом; списки и настройки переносятся."
                                 Style="{StaticResource ZcHint}" Margin="0,10,0,0"/>
                    </StackPanel>
                  </Border>
                  <Border Style="{StaticResource ZcCard}" Margin="0">
                    <StackPanel>
                      <TextBlock Text="Обновление Zapret Control" Style="{StaticResource ZcCardTitle}"/>
                      <TextBlock Text="Новая версия GUI скачивается с github.com/Bugulmekas/zapret-gui."
                                 Style="{StaticResource ZcHint}" Margin="0,6,0,14"/>
                      <Border Background="{DynamicResource Field}" CornerRadius="10" Padding="14,12">
                        <StackPanel>
                          <TextBlock x:Name="LblGuiLocal" Text="Установлено: —"
                                     FontSize="13.5" FontWeight="SemiBold" Foreground="{DynamicResource Ink}"/>
                          <TextBlock x:Name="LblGuiLatest" Text="Последняя на GitHub: —"
                                     FontSize="12.5" Foreground="{DynamicResource Muted}" Margin="0,4,0,0"/>
                          <TextBlock x:Name="LblGuiStatus" Text="Проверка ещё не выполнялась"
                                     FontSize="13" FontWeight="SemiBold" Foreground="{DynamicResource Muted}"
                                     Margin="0,10,0,0"/>
                        </StackPanel>
                      </Border>
                      <WrapPanel Margin="0,14,0,0">
                        <Button x:Name="BtnGuiCheck" Content="Проверить GUI" Width="150"
                                Style="{StaticResource ZcSecondary}" Margin="0,0,10,10"/>
                        <Button x:Name="BtnGuiUpdate" Content="Обновить GUI" Width="160"
                                Style="{StaticResource ZcPrimary}" Margin="0,0,10,10" IsEnabled="False"/>
                        <Button x:Name="LinkGuiReleases" Content="Релизы GUI на GitHub"
                                Style="{StaticResource ZcGhost}" Margin="0,0,0,10"/>
                      </WrapPanel>
                      <TextBlock Text="Скрипты заменяются на месте, настройки в data\config.json сохраняются, приложение перезапустится."
                                 Style="{StaticResource ZcHint}" Margin="0,10,0,0"/>
                    </StackPanel>
                  </Border>
                  <Border Style="{StaticResource ZcCard}" Margin="0">
                    <StackPanel>
                      <TextBlock Text="Описание релиза" Style="{StaticResource ZcCardTitle}"/>
                      <TextBox x:Name="TxtReleaseNotes" Style="{StaticResource ZcTextArea}" Height="230"
                               Margin="0,12,0,0" IsReadOnly="True" FontSize="12.5"
                               Text="Нажмите «Проверить обновления», чтобы получить информацию с GitHub."/>
                    </StackPanel>
                  </Border>
                </StackPanel>

              </Grid>
            </ScrollViewer>
          </Grid>
        </Border>
      </Grid>

      <!-- Журнал -->
      <Border Grid.Row="3" Margin="30,10,30,10" Style="{StaticResource ZcCard}" Padding="0">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="42"/>
            <RowDefinition Height="1"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <Grid Grid.Row="0" Margin="18,0,14,0">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock Grid.Column="0" Text="Журнал" Style="{StaticResource ZcCardTitle}"
                       VerticalAlignment="Center"/>
            <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
              <CheckBox x:Name="ChkAutoScroll" Content="Автопрокрутка" Style="{StaticResource ZcCheck}"
                        FontSize="12" Margin="0,0,14,0" IsChecked="True"/>
              <Button x:Name="BtnSaveLog" Content="Сохранить" Style="{StaticResource ZcSmall}" Margin="0,0,8,0"/>
              <Button x:Name="BtnClearLog" Content="Очистить" Style="{StaticResource ZcSmall}" Margin="0,0,8,0"/>
              <Button x:Name="BtnToggleLog" Content="Развернуть" Style="{StaticResource ZcSmall}"/>
            </StackPanel>
          </Grid>
          <Border Grid.Row="1" Background="{DynamicResource Hairline}"/>
          <RichTextBox x:Name="RtbLog" Grid.Row="2" Height="176" Visibility="Collapsed"
                       BorderThickness="0" Background="{DynamicResource LogBg}"
                       FontFamily="Cascadia Mono, Consolas, Courier New" FontSize="12"
                       Foreground="{DynamicResource Body}" IsReadOnly="True" IsUndoEnabled="False"
                       VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"
                       SelectionBrush="{DynamicResource Selection}">
            <FlowDocument PagePadding="0"/>
          </RichTextBox>
        </Grid>
      </Border>

      <!-- Статус-бар -->
      <Border Grid.Row="4" BorderBrush="{DynamicResource NavLineBrush}" BorderThickness="0,1,0,0"
              Background="{DynamicResource Canvas}">
        <Grid Margin="30,0">
          <TextBlock x:Name="StatusLabel" Text="Готово" FontSize="11.5"
                     Foreground="{DynamicResource Muted}" VerticalAlignment="Center"/>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
            <Button x:Name="BtnAboutFooter" Content="О программе" Style="{StaticResource ZcGhost}"
                    Height="24" Margin="0,0,8,0"/>
            <TextBlock x:Name="FooterVersion" Text="1.3.0 · MIT" FontSize="11.5"
                       Foreground="{DynamicResource Muted}" VerticalAlignment="Center"/>
          </StackPanel>
        </Grid>
      </Border>

    </Grid>
  </Border>
</Window>
'@

try {
    $script:Window = [Windows.Markup.XamlReader]::Parse($windowXaml)
} catch {
    [void][Windows.MessageBox]::Show(
        ("Не удалось загрузить интерфейс:`n" + $_.Exception.Message),
        'Zapret Control', 'OK', 'Error')
    exit 1
}

$script:Form = $script:Window

function Get-Ui {
    param([string]$Name)
    return $script:Window.FindName($Name)
}

$script:LstStrategies     = Get-Ui 'LstStrategies'
$script:RtbLog            = Get-Ui 'RtbLog'
$script:StatusLabel       = Get-Ui 'StatusLabel'
$script:AdminPill         = Get-Ui 'AdminPill'
$script:AdminPillText     = Get-Ui 'AdminPillText'
$script:AdminPillDot      = Get-Ui 'AdminPillDot'
$script:VpnPill           = Get-Ui 'VpnPill'
$script:VpnPillText       = Get-Ui 'VpnPillText'
$script:ChkAutostart      = Get-Ui 'ChkAutostart'
$script:ChkBatUpdates     = Get-Ui 'ChkBatUpdates'
$script:ChkAutoScroll     = Get-Ui 'ChkAutoScroll'
$script:ChkStartupUpdates = Get-Ui 'ChkStartupUpdates'
$script:CbGameMode        = Get-Ui 'CbGameMode'
$script:CbIpset           = Get-Ui 'CbIpset'
$script:TxtGameTcp        = Get-Ui 'TxtGameTcp'
$script:TxtGameUdp        = Get-Ui 'TxtGameUdp'
$script:LblServiceUsing   = Get-Ui 'LblServiceUsing'
$script:LblUpdateLocal    = Get-Ui 'LblUpdateLocal'
$script:LblUpdateLatest   = Get-Ui 'LblUpdateLatest'
$script:LblUpdateStatus   = Get-Ui 'LblUpdateStatus'
$script:LblGuiLocal       = Get-Ui 'LblGuiLocal'
$script:LblGuiLatest      = Get-Ui 'LblGuiLatest'
$script:LblGuiStatus      = Get-Ui 'LblGuiStatus'
$script:BtnGuiUpdate      = Get-Ui 'BtnGuiUpdate'
$script:LatestGuiRelease  = $null
$script:GuiUpdateAvailable = $false
$script:LblGuiLocal.Text  = 'Установлено: ' + $script:ZC_AppVersion
$script:TxtReleaseNotes   = Get-Ui 'TxtReleaseNotes'
$script:BtnRestartService = Get-Ui 'BtnRestartService'
$script:BtnRemoveService  = Get-Ui 'BtnRemoveService'
$script:BtnStartService   = Get-Ui 'BtnStartService'
$script:BtnStopService    = Get-Ui 'BtnStopService'
$script:BtnInstallUpdate  = Get-Ui 'BtnInstallUpdate'

$script:StatusLabels = @{
    Service  = Get-Ui 'StatusService'
    Winws    = Get-Ui 'StatusWinws'
    Strategy = Get-Ui 'StatusStrategy'
    Ipset    = Get-Ui 'StatusIpset'
    WinDivert = Get-Ui 'StatusWinDivert'
}
$script:HeaderSubtitle = Get-Ui 'HeaderSubtitle'

(Get-Ui 'VersionChipText').Text = $script:ZC_AppVersion
(Get-Ui 'FooterVersion').Text = $script:ZC_AppVersion + ' · MIT'

$script:RtbLog.Document.PagePadding = New-Object Windows.Thickness(18, 10, 12, 10)

# ---------------------------------------------------------------------------
#  Журнал / диалоги / статус
# ---------------------------------------------------------------------------
function Write-UiLog {
    param([string]$Text, [string]$Color = 'Text')

    if (-not $script:RtbLog) { return }

    $colorMap = @{
        'Text'   = $script:BrLogText
        'Gray'   = $script:BrLogGray
        'Green'  = $script:BrGreen
        'Red'    = $script:BrRed
        'Yellow' = $script:BrOrange
        'Cyan'   = $script:BrLogCyan
        'Blue'   = $script:BrLogBlue
    }
    $brush = $colorMap[$Color]
    if (-not $brush) { $brush = $script:BrLogText }

    $document = $script:RtbLog.Document
    if ($document.Blocks.Count -gt 2600) { $script:RtbLog.Clear() }

    $paragraph = New-Object Windows.Documents.Paragraph
    $paragraph.Margin = New-Object Windows.Thickness(0)
    $paragraph.LineHeight = 17
    $run = New-Object Windows.Documents.Run(('[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $Text))
    $run.Foreground = $brush
    [void]$paragraph.Inlines.Add($run)
    [void]$document.Blocks.Add($paragraph)

    if ($script:ChkAutoScroll -and $script:ChkAutoScroll.IsChecked -eq $true) {
        $script:RtbLog.ScrollToEnd()
    }
}

function Get-LogText {
    if (-not $script:RtbLog) { return '' }
    $range = New-Object Windows.Documents.TextRange($script:RtbLog.Document.ContentStart, $script:RtbLog.Document.ContentEnd)
    return $range.Text
}

function Update-LogTheme {
    param([hashtable]$OldPalette)

    if (-not $script:RtbLog -or -not $OldPalette) { return }
    $palette = $script:CurrentPalette
    if (-not $palette) { return }

    $keys = @('LogText', 'LogGray', 'Green', 'Red', 'Orange', 'LogCyan', 'LogBlue')
    $map = @{}
    foreach ($key in $keys) {
        $hex = ([string]$OldPalette[$key]).ToUpperInvariant()
        $map[$hex] = Get-Brush ([string]$palette[$key])
    }

    foreach ($block in $script:RtbLog.Document.Blocks) {
        $paragraph = $block -as [Windows.Documents.Paragraph]
        if (-not $paragraph) { continue }
        foreach ($inline in $paragraph.Inlines) {
            $run = $inline -as [Windows.Documents.Run]
            if (-not $run -or -not $run.Foreground) { continue }
            $color = $run.Foreground.Color
            $hex = '#{0:X2}{1:X2}{2:X2}' -f $color.R, $color.G, $color.B
            if ($map.ContainsKey($hex)) { $run.Foreground = $map[$hex] }
        }
    }
}

function Set-BusyStatus {
    param([string]$Text)
    if ($script:StatusLabel) {
        $script:StatusLabel.Text = $Text
        try {
            $script:Window.Dispatcher.Invoke([action]{}, [Windows.Threading.DispatcherPriority]::Render)
        } catch { }
    }
}

function New-ZcButton {
    param([string]$Text, [string]$StyleKey = 'ZcSecondary', [double]$Width = 0)
    $button = New-Object Windows.Controls.Button
    $button.Content = $Text
    $button.Style = $script:Window.Resources[$StyleKey]
    if ($Width -gt 0) { $button.Width = $Width }
    return $button
}

function Show-ZcDialog {
    param(
        [string]$Text,
        [string]$Title = 'Zapret Control',
        [ValidateSet('info', 'error', 'question')][string]$Kind = 'info',
        [switch]$Confirm,
        [string]$OkText = 'ОК',
        [string]$CancelText = 'Отмена'
    )

    if (-not $script:Window) {
        $buttons = if ($Confirm) { 'YesNo' } else { 'OK' }
        $icon = if ($Kind -eq 'error') { 'Error' } elseif ($Kind -eq 'question') { 'Question' } else { 'Information' }
        $result = [Windows.MessageBox]::Show($Text, $Title, $buttons, $icon)
        return ($result -eq [Windows.MessageBoxResult]::Yes)
    }

    $dialog = New-Object Windows.Window
    $dialog.Title = $Title
    $dialog.Width = 470
    $dialog.SizeToContent = [Windows.SizeToContent]::Height
    $dialog.ResizeMode = [Windows.ResizeMode]::NoResize
    $dialog.WindowStartupLocation = [Windows.WindowStartupLocation]::CenterOwner
    $dialog.Background = $script:BrSurface
    $dialog.FontFamily = $script:UiFont
    $dialog.FontSize = 13.5
    $dialog.Foreground = $script:BrInk
    $dialog.ShowInTaskbar = $false
    $dialog.Owner = $script:Window

    $panel = New-Object Windows.Controls.StackPanel
    $panel.Margin = New-Object Windows.Thickness(26, 24, 26, 20)

    $heading = New-Object Windows.Controls.TextBlock
    $heading.Text = $Title
    $heading.FontSize = 18
    $heading.FontWeight = [Windows.FontWeights]::SemiBold
    $heading.Foreground = $script:BrInk
    [void]$panel.Children.Add($heading)

    $message = New-Object Windows.Controls.TextBlock
    $message.Text = $Text
    $message.TextWrapping = [Windows.TextWrapping]::Wrap
    $message.FontSize = 13.5
    $message.LineHeight = 20
    $message.Foreground = $script:BrBody
    $message.Margin = New-Object Windows.Thickness(0, 10, 0, 20)
    [void]$panel.Children.Add($message)

    $row = New-Object Windows.Controls.StackPanel
    $row.Orientation = [Windows.Controls.Orientation]::Horizontal
    $row.HorizontalAlignment = [Windows.HorizontalAlignment]::Right

    if ($Confirm) {
        $cancel = New-ZcButton -Text $CancelText -StyleKey 'ZcSecondary' -Width 110
        $cancel.Margin = New-Object Windows.Thickness(0, 0, 10, 0)
        $cancel.IsCancel = $true
        $cancel.Add_Click({ $dialog.DialogResult = $false }.GetNewClosure())
        [void]$row.Children.Add($cancel)
    }

    $ok = New-ZcButton -Text $OkText -StyleKey 'ZcPrimary' -Width 110
    $ok.IsDefault = $true
    $ok.Add_Click({ $dialog.DialogResult = $true }.GetNewClosure())
    [void]$row.Children.Add($ok)

    [void]$panel.Children.Add($row)
    $dialog.Content = $panel

    $result = $dialog.ShowDialog()
    return ($result -eq $true)
}

function Show-UiInfo {
    param([string]$Text, [string]$Title = 'Zapret Control')
    [void](Show-ZcDialog -Text $Text -Title $Title -Kind 'info')
}

function Show-UiError {
    param([string]$Text, [string]$Title = 'Ошибка')
    [void](Show-ZcDialog -Text $Text -Title $Title -Kind 'error')
}

function Confirm-Ui {
    param([string]$Text, [string]$Title = 'Подтверждение')
    return [bool](Show-ZcDialog -Text $Text -Title $Title -Kind 'question' -Confirm)
}

function Confirm-VpnConflict {
    param([string]$Where = 'zapret')

    $vpn = @(Get-VpnConflicts)
    if ($vpn.Count -eq 0) { return $true }

    $list = ($vpn -join ', ')
    Write-UiLog ('Обнаружен VPN/прокси: ' + $list + '. Вместе с zapret интернет обычно перестаёт работать.') 'Yellow'
    if ($script:VpnWarningShown) { return $true }
    $script:VpnWarningShown = $true

    return (Confirm-Ui ("Обнаружен активный VPN/прокси: $list.`n`nVPN и zapret вместе обычно полностью отключают интернет.`nЕсли интернет пропадёт — выключите VPN.`n`nВсё равно запустить $Where?") 'VPN и zapret')
}

function Set-StatusValue {
    param([string]$Key, [string]$Text, [object]$Color)
    $label = $script:StatusLabels[$Key]
    if ($label) {
        $label.Text = $Text
        if ($Color) { $label.Foreground = $Color }
    }
}

function Set-AdminPill {
    param([bool]$IsAdmin)
    if (-not $script:AdminPillText) { return }

    $neon = ($script:ThemeName -eq 'neon')

    if ($IsAdmin) {
        if ($neon) {
            if (-not $script:AdminPillShimmer) {
                $script:AdminPill.Background = New-ShimmerBrush
                $script:AdminPill.Effect = [Windows.Media.Effects.Effect](New-Glow '#00F5FF' 14 0.5)
                $script:AdminPillText.Foreground = Get-Brush '#EAFBFF'
                $script:AdminPillDot.Fill = Get-Brush '#EAFBFF'
                $script:AdminPillShimmer = $true
            }
        } else {
            $script:AdminPillShimmer = $false
            $script:AdminPill.Effect = $null
            $script:AdminPill.Background = $script:BrPillOk
            $script:AdminPillText.Text = 'администратор'
            $script:AdminPillText.Foreground = $script:BrGreen
            $script:AdminPillDot.Fill = $script:BrPillOkDot
        }
    } else {
        $script:AdminPillShimmer = $false
        $script:AdminPill.Effect = $null
        $script:AdminPill.Background = $script:BrPillBad
        $script:AdminPillText.Text = 'нет прав'
        $script:AdminPillText.Foreground = $script:BrRed
        $script:AdminPillDot.Fill = $script:BrPillBadDot
    }
}

function Update-VpnPill {
    if (-not $script:VpnPill) { return }
    if (((Get-Date) - $script:VpnStateChecked).TotalSeconds -lt 10) { return }
    $script:VpnStateChecked = Get-Date

    $vpn = @(Get-VpnConflicts)
    if ($vpn.Count -gt 0) {
        try {
            $script:VpnPill.ToolTip = 'Обнаружен VPN/прокси: ' + ($vpn -join ', ') + '. Вместе с zapret интернет обычно не работает.'
            $script:VpnPill.Visibility = [Windows.Visibility]::Visible
        } catch { }
    } else {
        try { $script:VpnPill.Visibility = [Windows.Visibility]::Collapsed } catch { }
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

    $script:LstStrategies.Items.Clear()
    $script:StrategyFiles = @(Get-Strategies -Root $script:ZapretRoot)
    foreach ($strategy in $script:StrategyFiles) {
        [void]$script:LstStrategies.Items.Add($strategy.Name)
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
    try { $script:LstStrategies.ScrollIntoView($script:LstStrategies.SelectedItem) } catch { }
}

function Start-StrategyInternal {
    param([string]$Name, [switch]$NoConfirm)

    if (-not (Test-IsAdmin)) { Show-UiError 'Нужны права администратора.'; return $false }
    if (-not $Name) { Show-UiError 'Сначала выберите стратегию в списке.'; return $false }

    $batPath = Join-Path $script:ZapretRoot $Name
    if (-not (Test-Path -LiteralPath $batPath)) { Show-UiError ("Файл стратегии не найден:`n" + $batPath); return $false }

    if (-not $NoConfirm -and -not (Confirm-VpnConflict 'стратегию')) { return $false }

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
        if ($service) {
            Write-UiLog 'Служба не используется — zapret работает в ручном режиме.' 'Gray'
        }
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

    if (-not $NoConfirm -and -not (Confirm-VpnConflict 'службу')) { return $false }

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

    if (-not (Start-ZapretService)) {
        $message = 'Служба создана, но не запустилась.'
        if ($script:ZC_LastServiceError) { $message += ' ' + $script:ZC_LastServiceError }
        Write-UiLog $message 'Red'
    }
    Start-Sleep -Milliseconds 400

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

function Start-ServiceAction {
    $service = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
    if (-not $service) {
        Show-UiInfo 'Служба «zapret» не установлена. Установите её кнопкой «Установить службу».'
        return
    }

    if (-not (Confirm-VpnConflict 'службу')) { return }

    Set-BusyStatus 'Запуск службы...'
    Write-UiLog 'Запуск службы zapret...' 'Cyan'
    if (Start-ZapretService) {
        Write-UiLog 'Служба запущена, winws.exe работает.' 'Green'
        Set-BusyStatus 'Служба запущена'
    } else {
        $message = 'Не удалось запустить службу «zapret».'
        if ($script:ZC_LastServiceError) { $message += "`n`n" + $script:ZC_LastServiceError }
        $message += "`n`nПроверьте журнал и раздел «Инструменты» → «Диагностика»."
        Write-UiLog $message 'Red'
        Show-UiError $message 'Служба zapret'
        Set-BusyStatus 'Ошибка запуска службы'
    }
    Update-AllStatus
}

function Stop-ServiceAction {
    $service = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
    if (-not $service) { Show-UiInfo 'Служба «zapret» не установлена.'; return }

    Set-BusyStatus 'Остановка службы...'
    Write-UiLog 'Остановка службы zapret...' 'Cyan'
    Stop-ZapretService | Out-Null
    try { $service.Refresh() } catch { }

    if ($service.Status -eq 'Stopped') {
        Write-UiLog 'Служба и winws.exe остановлены, драйвер WinDivert освобождён.' 'Green'
        Set-BusyStatus 'Служба остановлена'
    } else {
        Write-UiLog ('Служба в состоянии: ' + $service.Status) 'Yellow'
        Set-BusyStatus 'Служба останавливается'
    }
    Update-AllStatus
}

function Restart-ServiceAction {
    $service = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
    if (-not $service) { Show-UiInfo 'Служба «zapret» не установлена.'; return }

    if (-not (Confirm-VpnConflict 'службу')) { return }

    Set-BusyStatus 'Перезапуск службы...'
    Write-UiLog 'Перезапуск службы zapret...' 'Cyan'

    Stop-ZapretService | Out-Null
    if (Start-ZapretService) {
        Write-UiLog 'Служба перезапущена.' 'Green'
        Set-BusyStatus 'Служба перезапущена'
    } else {
        $message = 'Не удалось перезапустить службу «zapret».'
        if ($script:ZC_LastServiceError) { $message += "`n`n" + $script:ZC_LastServiceError }
        Write-UiLog $message 'Red'
        Show-UiError $message 'Служба zapret'
        Set-BusyStatus 'Ошибка перезапуска службы'
    }
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

    if ($script:ChkAutostart.IsChecked -eq $true) { $startMode = 'auto' } else { $startMode = 'demand' }
    & sc.exe config zapret 'start=' $startMode 2>$null | Out-Null

    if ($script:ChkAutostart.IsChecked -eq $true) {
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

    # Режим работы: служба Windows или ручной запуск winws.exe
    $service = Get-ServiceInfo -Name 'zapret'
    $winws = @(Get-WinwsProcesses)
    if ($service.Status -eq 'Running') {
        Set-StatusValue 'Service' 'служба работает' $script:BrGreen
    } elseif ($winws.Count -gt 0) {
        if ($service.Installed) {
            Set-StatusValue 'Service' 'ручной запуск' $script:BrGreen
        } else {
            Set-StatusValue 'Service' 'вручную, без службы' $script:BrGreen
        }
    } elseif (-not $service.Installed) {
        Set-StatusValue 'Service' 'не установлена' $script:BrMuted
    } else {
        Set-StatusValue 'Service' ('остановлена' + $(if ($service.Status -ne 'Stopped') { " ($($service.Status))" } else { '' })) $script:BrOrange
    }

    # Процесс winws
    if ($winws.Count -gt 0) {
        Set-StatusValue 'Winws' ('работает · PID ' + (($winws | ForEach-Object { $_.Id }) -join ', ')) $script:BrGreen
    } else {
        Set-StatusValue 'Winws' 'не запущен' $script:BrMuted
    }

    # Драйвер WinDivert
    switch (Get-WinDivertState) {
        'running' { Set-StatusValue 'WinDivert' 'активен' $script:BrGreen }
        'stale'   { Set-StatusValue 'WinDivert' 'остался без winws' $script:BrOrange }
        'stopped' { Set-StatusValue 'WinDivert' 'остановлен' $script:BrMuted }
        default   { Set-StatusValue 'WinDivert' 'не активен' $script:BrMuted }
    }

    # Стратегия службы
    $serviceStrategy = Get-ServiceStrategy
    if ($serviceStrategy) {
        Set-StatusValue 'Strategy' $serviceStrategy $script:BrInk
    } else {
        Set-StatusValue 'Strategy' '—' $script:BrMuted
    }

    # Права (индикатор в шапке)
    Set-AdminPill ([bool](Test-IsAdmin))
    Update-VpnPill

    # IPSet
    $ipset = Get-IpsetState -Root $script:ZapretRoot
    switch ($ipset) {
        'loaded' { Set-StatusValue 'Ipset' 'загружен (loaded)' $script:BrGreen }
        'none'   { Set-StatusValue 'Ipset' 'отключён (none)' $script:BrOrange }
        default  { Set-StatusValue 'Ipset' 'любой (any)' $script:BrMuted }
    }

    # Версия пакета — в подзаголовке шапки
    $version = Get-LocalZapretVersion -Root $script:ZapretRoot
    if ($script:HeaderSubtitle) {
        if ($version) {
            $script:HeaderSubtitle.Text = 'Управление zapret-discord-youtube · пакет ' + $version
        } else {
            $script:HeaderSubtitle.Text = 'Управление zapret-discord-youtube'
        }
    }

    # Элементы управления, зависящие от службы
    if ($script:ChkAutostart -and $script:BtnRestartService -and $script:BtnRemoveService) {
        $script:SyncingUi = $true
        try {
            $script:ChkAutostart.IsEnabled = $service.Installed
            if ($service.Installed) {
                $script:ChkAutostart.IsChecked = ($service.StartType -eq 'Auto')
            } else {
                $script:ChkAutostart.IsChecked = $false
            }
            $script:BtnRestartService.IsEnabled = $service.Installed
            $script:BtnRemoveService.IsEnabled = $service.Installed
            if ($script:BtnStartService) {
                $script:BtnStartService.IsEnabled = ($service.Installed -and $service.Status -ne 'Running' -and $service.Status -ne 'StartPending')
            }
            if ($script:BtnStopService) {
                $script:BtnStopService.IsEnabled = ($service.Installed -and $service.Status -ne 'Stopped' -and $service.Status -ne 'StopPending')
            }
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

        $script:ChkBatUpdates.IsChecked = Test-Path -LiteralPath (Join-Path $script:ZapretRoot 'utils\check_updates.enabled')
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
        if ($script:ChkBatUpdates.IsChecked -eq $true) {
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

    # VPN / прокси
    $vpnConflicts = @(Get-VpnConflicts)
    if ($vpnConflicts.Count -gt 0) {
        Write-Check 'VPN / прокси' 'warn' ('активны: ' + ($vpnConflicts -join ', ') + ' — вместе с zapret интернет может пропасть')
        $warns++
    } else {
        Write-Check 'VPN / прокси' 'ok'
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

    # WinDivert
    $winws = @(Get-WinwsProcesses)
    $winDivertState = Get-WinDivertState
    if ($winDivertState -eq 'stale') {
        Write-Check 'WinDivert' 'warn' 'драйвер активен, хотя winws.exe не запущен'
        $warns++
        if (Confirm-Ui "Обнаружена активная служба WinDivert без запущенного winws.exe.`n`nПопытаться удалить её?" 'Диагностика') {
            Remove-WinDivertLeftovers
        }
    } elseif ($winDivertState -eq 'running') {
        Write-Check 'WinDivert' 'ok' 'активен и используется winws.exe'
    } elseif ($winDivertState -eq 'absent' -and $winws.Count -gt 0) {
        Write-Check 'WinDivert' 'warn' 'winws.exe запущен, но драйвер не зарегистрирован'
        $warns++
    } else {
        Write-Check 'WinDivert' 'ok' 'не активен'
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

    $dialog = New-Object Windows.Window
    $dialog.Title = 'Замена active fake'
    $dialog.Width = 640
    $dialog.Height = 640
    $dialog.ResizeMode = [Windows.ResizeMode]::NoResize
    $dialog.WindowStartupLocation = [Windows.WindowStartupLocation]::CenterOwner
    $dialog.Background = $script:BrSurface
    $dialog.FontFamily = $script:UiFont
    $dialog.FontSize = 13
    $dialog.Foreground = $script:BrInk
    $dialog.Owner = $script:Window
    $dialog.ShowInTaskbar = $false

    $panel = New-Object Windows.Controls.StackPanel
    $panel.Margin = New-Object Windows.Thickness(22, 20, 22, 18)

    $caption = New-Object Windows.Controls.TextBlock
    $caption.Text = 'Что заменяем'
    $caption.Style = $script:Window.Resources['ZcFieldLabel']
    [void]$panel.Children.Add($caption)

    $targetCombo = New-Object Windows.Controls.ComboBox
    $targetCombo.Style = $script:Window.Resources['ZcCombo']
    $targetCombo.Margin = New-Object Windows.Thickness(0, 0, 0, 12)
    [void]$targetCombo.Items.Add('Discord UDP  (ACTIVE_DISCORD_UDP.bin)')
    [void]$targetCombo.Items.Add('GameFilter UDP  (ACTIVE_GAME_UDP.bin)')
    $targetCombo.SelectedIndex = 0
    [void]$panel.Children.Add($targetCombo)

    $currentLabel = New-Object Windows.Controls.TextBlock
    $currentLabel.Text = 'Текущий fake: —'
    $currentLabel.FontSize = 12.5
    $currentLabel.Foreground = $script:BrMuted
    $currentLabel.Margin = New-Object Windows.Thickness(1, 0, 0, 14)
    [void]$panel.Children.Add($currentLabel)

    $listLabel = New-Object Windows.Controls.TextBlock
    $listLabel.Text = 'Доступные fake-файлы'
    $listLabel.Style = $script:Window.Resources['ZcFieldLabel']
    [void]$panel.Children.Add($listLabel)

    $listBox = New-Object Windows.Controls.ListBox
    $listBox.Style = $script:Window.Resources['ZcList']
    $listBox.Height = 300
    $listBox.Margin = New-Object Windows.Thickness(0, 0, 0, 12)
    $listBox.Background = $script:BrSurface
    foreach ($fake in $fakes) { [void]$listBox.Items.Add($fake.Name) }
    if ($listBox.Items.Count -gt 0) { $listBox.SelectedIndex = 0 }
    [void]$panel.Children.Add($listBox)

    $statusLabel = New-Object Windows.Controls.TextBlock
    $statusLabel.Text = ''
    $statusLabel.FontSize = 12
    $statusLabel.TextWrapping = [Windows.TextWrapping]::Wrap
    $statusLabel.Foreground = $script:BrGreen
    $statusLabel.MinHeight = 34
    $statusLabel.Margin = New-Object Windows.Thickness(1, 0, 0, 8)
    [void]$panel.Children.Add($statusLabel)

    $buttons = New-Object Windows.Controls.StackPanel
    $buttons.Orientation = [Windows.Controls.Orientation]::Horizontal
    $buttons.HorizontalAlignment = [Windows.HorizontalAlignment]::Right

    $btnReplace = New-ZcButton -Text 'Заменить' -StyleKey 'ZcPrimary' -Width 130
    $btnReplace.Margin = New-Object Windows.Thickness(0, 0, 10, 0)
    [void]$buttons.Children.Add($btnReplace)
    $btnClose = New-ZcButton -Text 'Закрыть' -StyleKey 'ZcSecondary' -Width 110
    [void]$buttons.Children.Add($btnClose)
    [void]$panel.Children.Add($buttons)

    $dialog.Content = $panel

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
    }.GetNewClosure()

    $targetCombo.Add_SelectionChanged($updateCurrent)
    & $updateCurrent

    $btnReplace.Add_Click({
        if ($listBox.SelectedIndex -lt 0) { return }
        $activeName = $activeNames[$targetCombo.SelectedIndex]
        $activePath = Join-Path $binDir $activeName
        $source = $fakes[$listBox.SelectedIndex].FullName
        try {
            Copy-Item -LiteralPath $source -Destination $activePath -Force -ErrorAction Stop
            $statusLabel.Foreground = $script:BrGreen
            $statusLabel.Text = 'Заменено: ' + $fakes[$listBox.SelectedIndex].Name + ". Перезапустите zapret."
            Write-UiLog ('Active fake заменён: ' + $activeName + ' → ' + $fakes[$listBox.SelectedIndex].Name) 'Green'
            & $updateCurrent
        } catch {
            $statusLabel.Foreground = $script:BrRed
            $statusLabel.Text = 'Ошибка: ' + $_.Exception.Message
            Write-UiLog ('Ошибка замены fake: ' + $_.Exception.Message) 'Red'
        }
    }.GetNewClosure())

    $btnClose.Add_Click({ $dialog.Close() }.GetNewClosure())

    [void]$dialog.ShowDialog()
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
            $script:LblUpdateStatus.Foreground = $script:BrRed
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
        if ($release.Body) { $script:TxtReleaseNotes.Text = ConvertFrom-MarkdownNotes $release.Body }
        else { $script:TxtReleaseNotes.Text = '(описание релиза пустое)' }
    }

    $available = ($local -and $remote -and $remote -gt $local)
    $script:UpdateAvailable = $available
    if ($script:BtnInstallUpdate) { $script:BtnInstallUpdate.IsEnabled = $available }

    if ($available) {
        if ($script:LblUpdateStatus) {
            $script:LblUpdateStatus.Text = 'Доступно обновление ' + $release.Tag
            $script:LblUpdateStatus.Foreground = $script:BrGreen
        }
        Write-UiLog ('Доступно обновление: ' + $release.Tag + ' (установлено ' + $local + ')') 'Green'

        if (-not $Silent) {
            if (Confirm-Ui ("Доступна новая версия zapret: $($release.Tag)`nУстановлена: $local`n`nСкачать и установить сейчас?") 'Обновление zapret') {
                Install-UpdateAction
            }
        }
    } else {
        if ($script:LblUpdateStatus) {
            $script:LblUpdateStatus.Text = 'Установлена последняя версия'
            $script:LblUpdateStatus.Foreground = $script:BrMuted
        }
        if (-not $Silent) { Write-UiLog 'Установлена последняя версия zapret.' 'Green' }
    }

    Set-BusyStatus 'Готово'
}

function Check-GuiUpdatesAction {
    param([switch]$Silent)

    if (-not $Silent) { Set-BusyStatus 'Проверка обновления GUI...' }
    $release = Get-LatestGuiRelease
    if (-not $release) {
        if ($script:LblGuiStatus) {
            $script:LblGuiStatus.Text = 'Ошибка проверки GitHub'
            $script:LblGuiStatus.Foreground = $script:BrRed
        }
        if (-not $Silent) { Write-UiLog 'Не удалось проверить обновление GUI.' 'Red' }
        return
    }

    $script:LatestGuiRelease = $release
    $local = ConvertTo-AppVersion $script:ZC_AppVersion
    $remote = ConvertTo-AppVersion $release.Tag
    if ($script:LblGuiLatest) { $script:LblGuiLatest.Text = 'Последняя на GitHub: ' + $release.Tag }

    $available = ($remote -and (-not $local -or $remote -gt $local))
    $script:GuiUpdateAvailable = $available
    if ($script:BtnGuiUpdate) { $script:BtnGuiUpdate.IsEnabled = $available }

    if ($available) {
        if ($script:LblGuiStatus) {
            $script:LblGuiStatus.Text = 'Доступно обновление ' + $release.Tag
            $script:LblGuiStatus.Foreground = $script:BrGreen
        }
        Write-UiLog ('Доступно обновление GUI: ' + $release.Tag + ' (установлено ' + $script:ZC_AppVersion + ')') 'Green'
        if (-not $Silent) {
            if (Confirm-Ui ("Доступна новая версия Zapret Control: $($release.Tag)`nУстановлена: $($script:ZC_AppVersion)`n`nОбновить сейчас? Приложение перезапустится.") 'Обновление GUI') {
                Install-GuiUpdateAction
            }
        }
    } else {
        if ($script:LblGuiStatus) {
            if ($local -and $remote -and $local -gt $remote) {
                $script:LblGuiStatus.Text = 'Локальная версия новее релиза'
            } else {
                $script:LblGuiStatus.Text = 'Установлена последняя версия'
            }
            $script:LblGuiStatus.Foreground = $script:BrMuted
        }
        if (-not $Silent) { Write-UiLog 'Установлена последняя версия GUI.' 'Green' }
    }
}

function Install-GuiUpdateAction {
    if (-not $script:GuiUpdateAvailable -or -not $script:LatestGuiRelease) { return }

    $release = $script:LatestGuiRelease
    if (-not $release.AssetUrl) {
        Show-UiError 'В релизе GUI нет zip-архива. Обновите со страницы релизов вручную.'
        return
    }

    if (-not (Confirm-Ui ("Скачать и установить Zapret Control $($release.Tag)?`n`nСкрипты будут заменены, настройки сохранятся.`nПосле установки приложение перезапустится.") 'Обновление GUI')) { return }

    $workDir = Join-Path $env:TEMP ('zapret-gui-update-' + [guid]::NewGuid().ToString('N'))

    try {
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null

        $zipPath = Join-Path $workDir $release.AssetName
        Set-BusyStatus 'Скачивание GUI...'
        Write-UiLog ('Скачивание GUI: ' + $release.AssetUrl) 'Cyan'
        if (-not (Invoke-CurlDownload -Url $release.AssetUrl -OutFile $zipPath -TimeoutSec 600)) {
            throw 'Не удалось скачать архив GUI.'
        }

        Set-BusyStatus 'Распаковка архива...'
        $extractDir = Join-Path $workDir 'extract'
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force

        $sourceScript = Get-ChildItem -LiteralPath $extractDir -Recurse -Filter 'ZapretControl.ps1' -File -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.DirectoryName 'ZapretCommon.ps1') } |
            Select-Object -First 1
        if (-not $sourceScript) { throw 'В архиве не найдены ZapretControl.ps1 и ZapretCommon.ps1.' }
        $sourceDir = $sourceScript.DirectoryName

        foreach ($name in @('ZapretControl.ps1', 'ZapretCommon.ps1')) {
            $errors = $null
            [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $sourceDir $name), [ref]$null, [ref]$errors)
            if ($errors.Count -gt 0) { throw ("Новый файл $name содержит ошибки синтаксиса.") }
        }

        $commonText = [IO.File]::ReadAllText((Join-Path $sourceDir 'ZapretCommon.ps1'))
        if ($commonText -notmatch "ZC_AppVersion\s*=\s*'([^']+)'") { throw 'В архиве не найдена версия GUI.' }
        if ($matches[1] -ne $release.Tag.TrimStart('v')) { throw "Архив содержит версию $($matches[1]) вместо $($release.Tag)." }

        $backupDir = Join-Path $script:DataDir ('backup-' + $script:ZC_AppVersion)
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

        $files = @('ZapretControl.ps1', 'ZapretCommon.ps1', 'ZapretControl.bat')
        foreach ($name in $files) {
            $current = Join-Path $script:AppDir $name
            if (Test-Path -LiteralPath $current) {
                Copy-Item -LiteralPath $current -Destination (Join-Path $backupDir $name) -Force
            }
        }

        Set-BusyStatus 'Установка GUI...'
        foreach ($name in $files) {
            $candidate = Join-Path $sourceDir $name
            if (Test-Path -LiteralPath $candidate) {
                Copy-Item -LiteralPath $candidate -Destination (Join-Path $script:AppDir $name) -Force
            }
        }

        Write-UiLog ('GUI обновлён до ' + $release.Tag + '. Перезапуск...') 'Green'
        Set-BusyStatus 'GUI обновлён, перезапуск'
        Show-UiInfo ("Zapret Control обновлён до $($release.Tag).`n`nПриложение сейчас перезапустится.") 'Обновление GUI'

        $launcher = Join-Path $script:AppDir 'ZapretControl.bat'
        if (Test-Path -LiteralPath $launcher) {
            Start-Process -FilePath $launcher -WorkingDirectory $script:AppDir | Out-Null
        } else {
            Start-Process -FilePath 'powershell.exe' -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -Sta -File "' + (Join-Path $script:AppDir 'ZapretControl.ps1') + '"') | Out-Null
        }

        $script:RestartTimer = New-Object Windows.Threading.DispatcherTimer
        $script:RestartTimer.Interval = [TimeSpan]::FromMilliseconds(500)
        $script:RestartTimer.Add_Tick({
            $script:RestartTimer.Stop()
            try { $script:Window.Close() } catch { }
        })
        $script:RestartTimer.Start()
    } catch {
        Write-UiLog ('Ошибка обновления GUI: ' + $_.Exception.Message) 'Red'
        Show-UiError $_.Exception.Message 'Обновление GUI'
        Set-BusyStatus 'Ошибка обновления GUI'
    } finally {
        if (Test-Path -LiteralPath $workDir) {
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
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
                    Write-UiLog 'Службу не удалось переустановить. Сделайте это вручную в разделе «Служба».' 'Red'
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
    if ($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { return }

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
    $script:LblUpdateStatus.Foreground = $script:BrMuted
    $script:LatestRelease = $null
    $script:UpdateAvailable = $false
    $script:BtnInstallUpdate.IsEnabled = $false
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
#  Навигация
# ---------------------------------------------------------------------------
$script:NavPages = @(
    (Get-Ui 'PageService'),
    (Get-Ui 'PageSettings'),
    (Get-Ui 'PageTools'),
    (Get-Ui 'PageTests'),
    (Get-Ui 'PageUpdate')
)
$script:NavButtons = @(
    (Get-Ui 'NavService'),
    (Get-Ui 'NavSettings'),
    (Get-Ui 'NavTools'),
    (Get-Ui 'NavTests'),
    (Get-Ui 'NavUpdate')
)

function Show-NavPage {
    param([int]$Index)
    for ($i = 0; $i -lt $script:NavPages.Count; $i++) {
        if ($i -eq $Index) {
            $script:NavPages[$i].Visibility = [Windows.Visibility]::Visible
        } else {
            $script:NavPages[$i].Visibility = [Windows.Visibility]::Collapsed
        }
    }
}

for ($i = 0; $i -lt $script:NavButtons.Count; $i++) {
    $navIndex = $i
    $script:NavButtons[$i].Add_Checked({ Show-NavPage $navIndex }.GetNewClosure())
}

# ---------------------------------------------------------------------------
#  События: окно
# ---------------------------------------------------------------------------
(Get-Ui 'BtnMinimize').Add_Click({
    $script:Window.WindowState = [Windows.WindowState]::Minimized
})
(Get-Ui 'BtnClose').Add_Click({
    $script:Window.Close()
})
(Get-Ui 'HeaderBar').Add_MouseLeftButtonDown({
    try { $script:Window.DragMove() } catch { }
})

$script:Window.Add_Loaded({
    if ($script:LstStrategies -and $script:LstStrategies.SelectedItem) {
        try { $script:LstStrategies.ScrollIntoView($script:LstStrategies.SelectedItem) } catch { }
    }
})

foreach ($themePair in @(@('ThemeLight', 'light'), @('ThemeDark', 'dark'), @('ThemeNeon', 'neon'))) {
    $themeButton = Get-Ui $themePair[0]
    $themeKey = $themePair[1]
    if ($themeButton) {
        $themeButton.Add_Checked({ Apply-Theme $themeKey -Save }.GetNewClosure())
    }
}

# ---------------------------------------------------------------------------
#  События: стратегии
# ---------------------------------------------------------------------------
(Get-Ui 'BtnStart').Add_Click({
    Invoke-UiSafe { Start-SelectedStrategyAction }
})
(Get-Ui 'BtnStop').Add_Click({
    Invoke-UiSafe { Stop-ZapretAction }
})
(Get-Ui 'BtnInstall').Add_Click({
    Invoke-UiSafe { Install-ServiceAction }
})
(Get-Ui 'BtnRemove').Add_Click({
    Invoke-UiSafe { Remove-ServiceAction }
})

$script:LstStrategies.Add_SelectionChanged({
    if ($script:LstStrategies.SelectedItem) {
        $script:Config.SelectedStrategy = [string]$script:LstStrategies.SelectedItem
        Save-Config
    }
})
$script:LstStrategies.Add_MouseDoubleClick({
    Invoke-UiSafe { Start-SelectedStrategyAction }
})

# ---------------------------------------------------------------------------
#  События: служба
# ---------------------------------------------------------------------------
$script:BtnStartService.Add_Click({
    Invoke-UiSafe { Start-ServiceAction }
})
$script:BtnStopService.Add_Click({
    Invoke-UiSafe { Stop-ServiceAction }
})
$script:BtnRestartService.Add_Click({
    Invoke-UiSafe { Restart-ServiceAction }
})
(Get-Ui 'BtnServiceBat').Add_Click({
    Invoke-UiSafe { Open-ServiceBatMenu }
})
(Get-Ui 'BtnOpenRoot').Add_Click({
    Invoke-UiSafe { Open-Folder $script:ZapretRoot }
})
$script:ChkAutostart.Add_Click({
    Invoke-UiSafe { Set-AutostartAction }
})

# ---------------------------------------------------------------------------
#  События: настройки
# ---------------------------------------------------------------------------
(Get-Ui 'BtnApplyGame').Add_Click({
    Invoke-UiSafe { Apply-GameFilterAction }
})
(Get-Ui 'BtnApplyIpset').Add_Click({
    Invoke-UiSafe { Apply-IpsetAction }
})
(Get-Ui 'BtnUpdateIpset').Add_Click({
    Invoke-UiSafe { Update-IpsetAction }
})
(Get-Ui 'ChkBatUpdates').Add_Click({
    Invoke-UiSafe { Set-BatUpdatesAction }
})
(Get-Ui 'BtnListGeneral').Add_Click({
    Invoke-UiSafe { Open-UserList 'list-general-user.txt' }
})
(Get-Ui 'BtnListExclude').Add_Click({
    Invoke-UiSafe { Open-UserList 'list-exclude-user.txt' }
})
(Get-Ui 'BtnListIpset').Add_Click({
    Invoke-UiSafe { Open-UserList 'ipset-exclude-user.txt' }
})
(Get-Ui 'BtnListFolder').Add_Click({
    Invoke-UiSafe { Open-Folder (Join-Path $script:ZapretRoot 'lists') }
})

# ---------------------------------------------------------------------------
#  События: инструменты
# ---------------------------------------------------------------------------
(Get-Ui 'BtnToolIpset').Add_Click({
    Invoke-UiSafe { Update-IpsetAction }
})
(Get-Ui 'BtnToolHosts').Add_Click({
    Invoke-UiSafe { Update-HostsAction }
})
(Get-Ui 'BtnToolDiag').Add_Click({
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
(Get-Ui 'BtnToolFakes').Add_Click({
    Invoke-UiSafe { Open-FakesDialog }
})
(Get-Ui 'BtnToolDiscord').Add_Click({
    Invoke-UiSafe {
        if (Confirm-Ui 'Очистить кэш Discord? Приложения Discord будут закрыты.' 'Очистка кэша Discord') {
            Clear-DiscordCacheInternal
        }
    }
})
(Get-Ui 'BtnToolWinDivert').Add_Click({
    Invoke-UiSafe {
        if (Confirm-Ui "Остановить и удалить службы WinDivert / WinDivert14?`n`nЭто помогает, если zapret не запускается из-за конфликта драйвера." 'WinDivert') {
            Remove-WinDivertLeftovers
            Start-Sleep -Milliseconds 400
        }
    }
})
(Get-Ui 'BtnToolOpenData').Add_Click({
    Invoke-UiSafe { Open-DataFolder }
})
(Get-Ui 'BtnToolServiceBat').Add_Click({
    Invoke-UiSafe { Open-ServiceBatMenu }
})
(Get-Ui 'BtnChooseFolder').Add_Click({
    Invoke-UiSafe { Choose-ZapretFolder }
})
(Get-Ui 'BtnAboutFooter').Add_Click({
    Invoke-UiSafe { Show-About }
})

# ---------------------------------------------------------------------------
#  События: тесты
# ---------------------------------------------------------------------------
(Get-Ui 'BtnRunTests').Add_Click({
    Invoke-UiSafe { Run-StrategyTestsAction }
})
(Get-Ui 'BtnTestResults').Add_Click({
    Invoke-UiSafe { Open-TestResultsFolder }
})
(Get-Ui 'BtnQuickCheck').Add_Click({
    Invoke-UiSafe { Quick-CheckAction }
})

# ---------------------------------------------------------------------------
#  События: обновление
# ---------------------------------------------------------------------------
(Get-Ui 'BtnCheckUpdates').Add_Click({
    Invoke-UiSafe { Check-UpdatesAction }
})
$script:BtnInstallUpdate.Add_Click({
    Invoke-UiSafe { Install-UpdateAction }
})
(Get-Ui 'BtnGuiCheck').Add_Click({
    Invoke-UiSafe { Check-GuiUpdatesAction }
})
$script:BtnGuiUpdate.Add_Click({
    Invoke-UiSafe { Install-GuiUpdateAction }
})
(Get-Ui 'LinkGuiReleases').Add_Click({
    try { Start-Process -FilePath $script:ZC_GuiReleasesPage | Out-Null } catch { }
})
$script:ChkStartupUpdates.Add_Click({
    $script:Config.CheckUpdatesOnStart = ($script:ChkStartupUpdates.IsChecked -eq $true)
    Save-Config
})
(Get-Ui 'LinkReleases').Add_Click({
    try { Start-Process -FilePath $script:ZC_ReleasesPage | Out-Null } catch { }
})

# ---------------------------------------------------------------------------
#  События: журнал
# ---------------------------------------------------------------------------
(Get-Ui 'BtnClearLog').Add_Click({
    $script:RtbLog.Document.Blocks.Clear()
})
(Get-Ui 'BtnSaveLog').Add_Click({
    try {
        $dialog = New-Object Microsoft.Win32.SaveFileDialog
        $dialog.Filter = 'Текстовый файл (*.txt)|*.txt|Все файлы (*.*)|*.*'
        $dialog.FileName = 'zapret-control-log.txt'
        if ($dialog.ShowDialog($script:Window)) {
            [IO.File]::WriteAllText($dialog.FileName, (Get-LogText), (New-Object Text.UTF8Encoding($true)))
            Write-UiLog ('Журнал сохранён: ' + $dialog.FileName) 'Green'
        }
    } catch { }
})
(Get-Ui 'BtnToggleLog').Add_Click({
    if ($script:RtbLog.Visibility -eq [Windows.Visibility]::Visible) {
        $script:RtbLog.Visibility = [Windows.Visibility]::Collapsed
        (Get-Ui 'BtnToggleLog').Content = 'Развернуть'
    } else {
        $script:RtbLog.Visibility = [Windows.Visibility]::Visible
        (Get-Ui 'BtnToggleLog').Content = 'Свернуть'
        $script:RtbLog.ScrollToEnd()
    }
})

# ---------------------------------------------------------------------------
#  Начальная инициализация
# ---------------------------------------------------------------------------
$script:ChkStartupUpdates.IsChecked = [bool]$script:Config.CheckUpdatesOnStart

Apply-Theme $script:Config.Theme

Refresh-StrategyList
Load-SettingsIntoUi
Update-AllStatus

Write-UiLog ('Zapret Control ' + $script:ZC_AppVersion + ' запущен') 'Cyan'
Write-UiLog ('Папка zapret: ' + $script:ZapretRoot) 'Gray'
Write-UiLog ('Версия пакета: ' + (Get-LocalZapretVersion -Root $script:ZapretRoot)) 'Gray'
if (Test-IsAdmin) {
    Write-UiLog 'Права администратора: да' 'Green'
} else {
    Write-UiLog 'Права администратора: нет' 'Yellow'
}
if (@(Get-WinwsProcesses).Count -gt 0) {
    Write-UiLog 'winws.exe уже запущен.' 'Green'
}
if (Get-Service -Name 'zapret' -ErrorAction SilentlyContinue) {
    Write-UiLog 'Служба zapret установлена.' 'Gray'
}

$script:App = New-Object Windows.Application
$script:App.ShutdownMode = [Windows.ShutdownMode]::OnMainWindowClose

# Главный таймер: статус + журнал winws
$script:MainTimer = New-Object Windows.Threading.DispatcherTimer
$script:MainTimer.Interval = [TimeSpan]::FromSeconds(2)
$script:MainTimer.Add_Tick({
    try { Update-AllStatus } catch { }
    try { Read-WinwsLog } catch { }
})
$script:MainTimer.Start()

# Проверка обновлений при запуске (один раз, после появления окна)
$script:StartupTimer = New-Object Windows.Threading.DispatcherTimer
$script:StartupTimer.Interval = [TimeSpan]::FromMilliseconds(900)
$script:StartupTimer.Add_Tick({
    $script:StartupTimer.Stop()
    try {
        if ($script:Config.CheckUpdatesOnStart -and -not $Preview) {
            Check-UpdatesAction -Silent
            Check-GuiUpdatesAction -Silent
        }
    } catch { }
})
$script:StartupTimer.Start()

$script:Window.Add_Closing({
    try { $script:MainTimer.Stop() } catch { }
    try { $script:StartupTimer.Stop() } catch { }
    Save-Config
})

if ($Preview) {
    $script:PreviewTimer = New-Object Windows.Threading.DispatcherTimer
    $script:PreviewTimer.Interval = [TimeSpan]::FromMilliseconds([Math]::Max(500, $PreviewSeconds * 1000))
    $script:PreviewTimer.Add_Tick({
        $script:PreviewTimer.Stop()
        $script:Window.Close()
    })
    $script:PreviewTimer.Start()
    Write-Output 'UI PREVIEW STARTED'
}

try {
    [void]$script:App.Run($script:Window)
} catch {
    Show-UiError ('Критическая ошибка интерфейса:' + "`n" + $_.Exception.Message)
} finally {
    Save-Config
}

if ($Preview) {
    Write-Output 'UI PREVIEW OK'
}
