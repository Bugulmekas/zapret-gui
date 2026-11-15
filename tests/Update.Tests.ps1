# ============================================================================
#  Тесты транзакционного самообновления GUI — issue #1 (Bugulmekas/zapret-gui)
#
#  Pester v5+. В Windows PowerShell 5.1 встроен Pester 3.4: без v5+ тесты
#  вежливо пропускаются (guard ниже), а не падают.
#
#  Тестируемый код:
#   - хелперы ZapretCommon.ps1 (staging, бэкап, подмена, откат, лимит бэкапов);
#   - оркестратор Install-GuiUpdateAction из ZapretControl.ps1 — извлекается
#     из исходника через AST (только тело функции), чтобы не поднимать WPF-GUI.
#
#  Шесть сценариев issue #1 идут E2E через оркестратор: скачивание и
#  распаковка мокируются (Invoke-CurlDownload, Expand-Archive), перезапуск
#  (Start-Process) мокируется и фиксируется, UI-функции заменены рекордерами.
#  Тесты не ходят в сеть и не трогают реальный каталог приложения: каждый It
#  строит каталог-двойник в %TEMP%\pester-<guid>\..., AfterAll чистит всё.
#
#  Примечание PS 5.1: @() над System.Collections.Generic.List[object] бросает
#  ArgumentException — в тестах оборачиваются только массивы/результаты
#  Get-ChildItem, свойства хелперов читаются напрямую (.Count, индексация).
# ============================================================================

# Pester 3.4 не поддерживает фазы v5 — без v5+ выходим с предупреждением.
if ((Get-Module Pester -ListAvailable | Where-Object Version -ge 5.0.0) -eq $null) {
    Write-Warning 'Pester v5+ не найден — tests\Update.Tests.ps1 пропущен. Установка: Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck'
    return
}

Describe 'Транзакционное самообновление GUI (issue #1)' {

    BeforeAll {
        # --- Окружение: подключение кода и извлечение оркестратора -----------
        # Файл теста: <repo>\GUI\tests\Update.Tests.ps1, продукт — в <repo>\GUI\.
        $script:RepoRoot   = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
        $script:CommonPath = Join-Path $script:RepoRoot 'ZapretCommon.ps1'
        . $script:CommonPath

        # Install-GuiUpdateAction живёт в ZapretControl.ps1 (WPF-скрипт, целиком
        # он в тестах не запускается): берём AST-узел только этой функции.
        $controlPath = Join-Path $script:RepoRoot 'ZapretControl.ps1'
        $tokens = $null
        $errors = $null
        $controlAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $controlPath, [ref]$tokens, [ref]$errors)
        if ($errors -and $errors.Count -gt 0) {
            throw ('ZapretControl.ps1 не парсится: ' + $errors[0].Message)
        }
        $installFn = $controlAst.Find({
                param($node)
                ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and
                    $node.Name -eq 'Install-GuiUpdateAction'
            }, $true)
        if (-not $installFn) {
            throw 'Функция Install-GuiUpdateAction не найдена в ZapretControl.ps1'
        }
        . ([scriptblock]::Create($installFn.Extent.Text))
        if (-not (Get-Command -Name Install-GuiUpdateAction -ErrorAction SilentlyContinue)) {
            throw 'Install-GuiUpdateAction не определилась после AST-извлечения'
        }

        # Успех оркестратора создаёт Windows.Threading.DispatcherTimer (WPF):
        # WindowsBase — сам DispatcherTimer, PresentationFramework — зависимости.
        Add-Type -AssemblyName WindowsBase -ErrorAction Stop
        Add-Type -AssemblyName PresentationFramework -ErrorAction Stop

        $script:SandboxRoot = Join-Path $env:TEMP ('pester-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:SandboxRoot -Force | Out-Null

        # Переменные сценария для мока Expand-Archive (что «в архиве»).
        $script:TestStagingVersion = '2.1.0'
        $script:TestStagingOmit = ''

        # --- Рекордеры UI-функций оркестратора (в тестах GUI нет) ------------
        function Reset-TestUiRecorder {
            $script:TestLog = @()
            $script:TestUiErrors = @()
            $script:TestUiInfos = @()
            $script:TestBusy = @()
            $script:TestConfirms = @()
            $script:TestStartProcesses = @()
        }

        function Write-UiLog {
            param([string]$Text, [string]$Color = 'Text')
            $script:TestLog += [pscustomobject]@{ Text = $Text; Color = $Color }
        }

        function Show-UiError {
            param([string]$Text, [string]$Title = 'Ошибка')
            $script:TestUiErrors += $Text
        }

        function Show-UiInfo {
            param([string]$Text, [string]$Title = 'Zapret Control')
            $script:TestUiInfos += $Text
        }

        function Set-BusyStatus {
            param([string]$Text)
            $script:TestBusy += $Text
        }

        function Confirm-Ui {
            param([string]$Text, [string]$Title = 'Подтверждение')
            $script:TestConfirms += $Text
            return $true
        }

        # Инициализация рекордеров — после определения всех функций выше.
        Reset-TestUiRecorder

        # --- Помощники Arrange -----------------------------------------------

        function Write-TestGuiFiles {
            # Файлы-двойники с валидным содержимым: .ps1 проходит парсер,
            # .bat — ASCII + CRLF без BOM (проверка Get-ZcBatchFileProblems).
            param(
                [string]$Dir,
                [string]$Version
            )
            New-Item -ItemType Directory -Path $Dir -Force | Out-Null
            $utf8 = New-Object Text.UTF8Encoding($false)
            [IO.File]::WriteAllText((Join-Path $Dir 'ZapretControl.ps1'),
                ("# Тестовый двойник ZapretControl.ps1`r`n'gui double $Version'`r`n"), $utf8)
            [IO.File]::WriteAllText((Join-Path $Dir 'ZapretCommon.ps1'),
                ("# Тестовый двойник ZapretCommon.ps1`r`n`$script:ZC_AppVersion = '$Version'`r`n"), $utf8)
            [IO.File]::WriteAllText((Join-Path $Dir 'ZapretControl.bat'),
                ("@echo off`r`nrem test double $Version`r`nexit /b 0`r`n"), [Text.Encoding]::ASCII)
        }

        function Get-TestFileHashes {
            param(
                [string]$Dir,
                [string[]]$Files = $script:ZC_GuiFiles
            )
            $result = @{}
            foreach ($name in $Files) {
                $path = Join-Path $Dir $name
                if (Test-Path -LiteralPath $path -PathType Leaf) {
                    $result[$name] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToUpperInvariant()
                }
            }
            return $result
        }

        function New-TestAppSandbox {
            # Двойник каталога приложения: три файла (v2.0.0) + data\config.json.
            $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
            $app    = Join-Path (Join-Path $script:SandboxRoot ('it-' + $id)) 'app'
            $data   = Join-Path $app 'data'
            New-Item -ItemType Directory -Path $data -Force | Out-Null
            Write-TestGuiFiles -Dir $app -Version '2.0.0'
            $config = Join-Path $data 'config.json'
            [IO.File]::WriteAllText($config,
                '{"Theme":"Dark","CheckUpdatesOnStart":true}',
                (New-Object Text.UTF8Encoding($false)))
            return [pscustomobject]@{
                Root       = Split-Path -Parent $app
                App        = $app
                DataDir    = $data
                ConfigPath = $config
            }
        }

        function Add-TestStaging {
            # Staging-двойник в data\ (как в issue: data\update-staging-<guid>).
            # -OmitFile убирает один файл — сценарий 4 (отсутствующий файл).
            param(
                $Sandbox,
                [string]$Version = '2.1.0',
                [string]$OmitFile = ''
            )
            $dir = Join-Path $Sandbox.DataDir ('update-staging-' + [guid]::NewGuid().ToString('N'))
            Write-TestGuiFiles -Dir $dir -Version $Version
            if (-not [string]::IsNullOrWhiteSpace($OmitFile)) {
                Remove-Item -LiteralPath (Join-Path $dir $OmitFile) -Force
            }
            return [pscustomobject]@{
                Dir    = $dir
                Hashes = (Get-TestFileHashes -Dir $dir)
            }
        }

        function New-TestBackupFixture {
            # Фикстура бэкапа по схеме issue §3: файлы + backup.json с SHA-256.
            param(
                $Sandbox,
                [string]$Version = '2.0.0',
                [string]$Stamp = '20260105-103000'
            )
            $dir = Join-Path $Sandbox.DataDir ('backup-' + $Version + '-' + $Stamp)
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $hashes = @{}
            foreach ($name in $script:ZC_GuiFiles) {
                Copy-Item -LiteralPath (Join-Path $Sandbox.App $name) -Destination (Join-Path $dir $name) -Force
                $hashes[$name] = (Get-FileHash -LiteralPath (Join-Path $dir $name) -Algorithm SHA256).Hash.ToUpperInvariant()
            }
            $manifest = [pscustomobject]@{
                Version   = $Version
                CreatedAt = '2026-01-05T10:30:00'
                Files     = $hashes
            }
            $manifestPath = Join-Path $dir 'backup.json'
            [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 4),
                (New-Object Text.UTF8Encoding($true)))
            return [pscustomobject]@{
                Dir          = $dir
                ManifestPath = $manifestPath
                Hashes       = $hashes
            }
        }

        function New-TestRelease {
            # Релиз-GitHub для оркестратора: URL/имя/хеш валидны, сеть не нужна —
            # Invoke-CurlDownload и Expand-Archive в сценариях замокированы.
            return [pscustomobject]@{
                AssetUrl    = 'https://example.invalid/assets/zapret-gui-2.1.0.zip'
                AssetName   = 'zapret-gui-2.1.0.zip'
                AssetSha256 = ('D' * 64)
                Tag         = 'v2.1.0'
            }
        }

        function Invoke-TestGuiUpdate {
            # Запуск оркестратора в песочнице: все его входные script-переменные.
            param(
                $Sandbox,
                $Release
            )
            $script:AppDir = $Sandbox.App
            $script:GuiUpdateAvailable = $true
            $script:LatestGuiRelease = $Release
            Install-GuiUpdateAction
        }

        function Get-TestUiLogText {
            return (($script:TestLog | ForEach-Object { $_.Text }) -join "`n")
        }

        function Get-TestBackupDirs {
            param($Sandbox)
            return @(Get-ChildItem -LiteralPath $Sandbox.DataDir -Directory -Filter 'backup-*' -ErrorAction SilentlyContinue)
        }
    }

    AfterAll {
        # Очистка мусора: песочница удаляется целиком.
        if ($script:SandboxRoot -and (Test-Path -LiteralPath $script:SandboxRoot)) {
            Remove-Item -LiteralPath $script:SandboxRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # =========================================================================
    #  Синтетические проверки — без продукт-контракта, активны всегда
    # =========================================================================
    Context 'Синтетика (без контракта)' {

        It 'ZapretCommon.ps1 подключается из репозитория, функции проверки доступны' {
            # Arrange: подключение выполнено в BeforeAll (. ZapretCommon.ps1)
            # Act: нечего — проверяем связность окружения
            # Assert: стабильные функции существующей логики (issue: «уже есть, не ломать»)
            Get-Command -Name Invoke-CurlDownload -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
            Get-Command -Name Get-AssetSha256 -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
            Get-Command -Name ConvertTo-AppVersion -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }

        It 'ZC_GuiFiles — ровно три файла самообновления GUI' {
            # Arrange/Act
            $files = @($script:ZC_GuiFiles)
            # Assert: состав из issue (ZapretControl.ps1, ZapretCommon.ps1, ZapretControl.bat)
            $files.Count | Should -Be 3
            ($files -join ';') | Should -Be 'ZapretControl.ps1;ZapretCommon.ps1;ZapretControl.bat'
        }

        It 'ZC_MaxGuiBackups = 3 — ограничение истории резервных копий из issue' {
            # Arrange/Act/Assert: issue §7 «хранить не более 3 последних»
            [int]$script:ZC_MaxGuiBackups | Should -Be 3
        }

        It 'Invoke-CurlDownload отклоняет архив с несовпадающим SHA-256 и удаляет файл' {
            # Arrange: локальный файл вместо сети (file://), заведомо неверный хеш
            $src = Join-Path $script:SandboxRoot 'payload-good.bin'
            [IO.File]::WriteAllText($src, 'hello world')
            $realHash = (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash
            $url = 'file:///' + (($src -replace '\\', '/') -replace ' ', '%20')
            $out = Join-Path $script:SandboxRoot 'payload-downloaded.bin'

            # Act
            $ok = Invoke-CurlDownload -Url $url -OutFile $out -ExpectedSha256 ('A' * 64)

            # Assert: отказ + файл не оставлен + причина в ZC_LastDownloadError
            $ok | Should -BeFalse
            Test-Path -LiteralPath $out | Should -BeFalse
            $script:ZC_LastDownloadError | Should -Match 'SHA256'

            # Контрольный прогон с корректным хешем (положительный путь)
            $out2 = Join-Path $script:SandboxRoot 'payload-downloaded-ok.bin'
            $ok2 = Invoke-CurlDownload -Url $url -OutFile $out2 -ExpectedSha256 $realHash
            $ok2 | Should -BeTrue
            Test-Path -LiteralPath $out2 | Should -BeTrue
        }

        It 'песочница строится в %TEMP%, а в каталоге приложения нет staging/update-old' {
            # Arrange
            $sb = New-TestAppSandbox
            # Act: структура двойника
            $tempFull = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')
            $structureOk = (Test-Path -LiteralPath (Join-Path $sb.App 'ZapretControl.ps1')) -and
                           (Test-Path -LiteralPath (Join-Path $sb.App 'ZapretCommon.ps1')) -and
                           (Test-Path -LiteralPath (Join-Path $sb.App 'ZapretControl.bat')) -and
                           (Test-Path -LiteralPath $sb.ConfigPath)
            # Assert: двойник в %TEMP% и структура полная
            Write-Host ("DIAG: sbRoot='{0}' | TEMP='{1}' | tempFull='{2}' | CWD='{3}' | RUNNER_TEMP='{4}'" -f $sb.Root, $env:TEMP, $tempFull, (Get-Location).Path, $env:RUNNER_TEMP)
            $sb.Root.ToLowerInvariant().StartsWith($tempFull.ToLowerInvariant()) | Should -BeTrue
            $structureOk | Should -BeTrue
            # Assert: тесты не оставляют staging/update-old в реальном репозитории
            $repoStaging = @(Get-ChildItem -LiteralPath $script:RepoRoot -Directory -Filter 'update-staging-*' -ErrorAction SilentlyContinue)
            $repoOld = @(Get-ChildItem -LiteralPath $script:RepoRoot -Directory -Filter 'update-old-*' -ErrorAction SilentlyContinue)
            $repoStaging.Count | Should -Be 0
            $repoOld.Count | Should -Be 0
        }
    }

    # =========================================================================
    #  Шесть сценариев issue #1 — E2E через оркестратор Install-GuiUpdateAction
    # =========================================================================
    Context 'Оркестратор: шесть сценариев issue' {

        It 'Сценарий 1: успех — три файла заменены, хеши совпали, staging/update-old удалены, бэкапов не более 3, перезапуск инициирован' {
            # Arrange: приложение v2.0.0; «архив» v2.1.0 готовится моком
            # распаковки; эталонные хеши снимаются с копии содержимого «архива».
            $sb = New-TestAppSandbox
            Reset-TestUiRecorder
            $configBefore = (Get-FileHash -LiteralPath $sb.ConfigPath -Algorithm SHA256).Hash
            $expectedDir = Join-Path $sb.Root 'expected'
            Write-TestGuiFiles -Dir $expectedDir -Version '2.1.0'
            $expectedHashes = Get-TestFileHashes -Dir $expectedDir
            $script:TestStagingVersion = '2.1.0'
            $script:TestStagingOmit = ''
            $release = New-TestRelease

            Mock Invoke-CurlDownload { $true }
            Mock Expand-Archive {
                Write-TestGuiFiles -Dir $DestinationPath -Version $script:TestStagingVersion
                if ($script:TestStagingOmit) {
                    Remove-Item -LiteralPath (Join-Path $DestinationPath $script:TestStagingOmit) -Force
                }
            }
            Mock Start-Process { $script:TestStartProcesses += $FilePath }

            # Act
            Invoke-TestGuiUpdate -Sandbox $sb -Release $release

            # Assert: все три файла заменены и побайтово равны содержимому «архива»
            $after = Get-TestFileHashes -Dir $sb.App
            foreach ($name in $script:ZC_GuiFiles) {
                $after[$name] | Should -Be $expectedHashes[$name]
            }
            # Assert: фазы прогона — скачивание, распаковка, ровно один перезапуск
            Should -Invoke Invoke-CurlDownload -Times 1 -Exactly
            Should -Invoke Expand-Archive -Times 1 -Exactly
            Should -Invoke Start-Process -Times 1 -Exactly
            $script:TestStartProcesses[0] | Should -Be (Join-Path $sb.App 'ZapretControl.bat')
            # Assert: мусор удален — staging и update-old отсутствуют в data\
            $stagingLeft = @(Get-ChildItem -LiteralPath $sb.DataDir -Directory -Filter 'update-staging-*')
            $oldLeft = @(Get-ChildItem -LiteralPath $sb.DataDir -Directory -Filter 'update-old-*')
            $stagingLeft.Count | Should -Be 0
            $oldLeft.Count | Should -Be 0
            # Assert: бэкап создан, история не длиннее 3, манифест хранит хеши исходных файлов
            $backupDirs = Get-TestBackupDirs -Sandbox $sb
            $backupDirs.Count | Should -Be 1
            ($backupDirs.Count -le 3) | Should -BeTrue
            # хеши в манифесте — от файлов до замены: сверяем с самим бэкапом
            $backupCheck = Test-GuiUpdateManifest -Directory $backupDirs[0].FullName
            $backupCheck.Ok | Should -BeTrue
            # Assert: лог обновления и отсутствие ошибок/откатов
            $logText = Get-TestUiLogText
            $logText | Should -Match 'GUI обновлён до v2\.1\.0'
            $logText | Should -Not -Match 'Откат'
            $script:TestUiErrors.Count | Should -Be 0
            $script:TestUiInfos.Count | Should -Be 1
            # Assert: data\config.json не тронут
            (Get-FileHash -LiteralPath $sb.ConfigPath -Algorithm SHA256).Hash | Should -Be $configBefore
        }

        It 'Сценарий 2: сбой между перемещением первого и второго файла — откат из update-old, хеши по backup.json, без перезапуска, в логе причина' {
            # Arrange: приложение v2.0.0, «архив» v2.1.0; Move-Item падает на
            # втором перемещении из staging (после первого установленного файла).
            $sb = New-TestAppSandbox
            Reset-TestUiRecorder
            $originalHashes = Get-TestFileHashes -Dir $sb.App
            $script:TestStagingVersion = '2.1.0'
            $script:TestStagingOmit = ''
            $release = New-TestRelease

            Mock Invoke-CurlDownload { $true }
            Mock Expand-Archive {
                Write-TestGuiFiles -Dir $DestinationPath -Version $script:TestStagingVersion
                if ($script:TestStagingOmit) {
                    Remove-Item -LiteralPath (Join-Path $DestinationPath $script:TestStagingOmit) -Force
                }
            }
            Mock Start-Process { $script:TestStartProcesses += $FilePath }
            # Реальное перемещение выполняется через [IO.File]::Move: в Pester 6
            # модуль-квалифицированный вызов Microsoft.PowerShell.Management\Move-Item
            # снова попадает в мок (рекурсия), поэтому так.
            $script:InstallMoveCount = 0
            Mock Move-Item {
                $isToOld = [string]$Destination -like '*update-old*'
                if (-not $isToOld) {
                    $script:InstallMoveCount++
                    if ($script:InstallMoveCount -ge 2) {
                        throw 'Имитация сбоя: питание пропало между первым и вторым файлом'
                    }
                }
                if (Test-Path -LiteralPath $Destination) { [System.IO.File]::Delete($Destination) }
                [System.IO.File]::Move($LiteralPath, $Destination)
            }

            # Act
            Invoke-TestGuiUpdate -Sandbox $sb -Release $release

            # Assert: все три файла восстановлены в исходное состояние
            $after = Get-TestFileHashes -Dir $sb.App
            foreach ($name in $script:ZC_GuiFiles) {
                $after[$name] | Should -Be $originalHashes[$name]
            }
            # Assert: приложение НЕ перезапущено
            Should -Invoke Start-Process -Times 0 -Exactly
            $script:TestStartProcesses.Count | Should -Be 0
            # Assert: в логе запись о сбое с причиной и об откате с результатом проверки
            $logText = Get-TestUiLogText
            $logText | Should -Match 'Сбой установки GUI'
            $logText | Should -Match 'Имитация сбоя'
            $logText | Should -Match 'Откат: источник update-old/backup'
            $logText | Should -Match 'проверка по манифесту: успешно'
            $logText | Should -Match 'Обновление отменено, восстановлена версия 2\.0\.0'
            # Assert: пользователю показано сообщение из issue: «Обновление
            # отменено, восстановлена версия X. Причина: <кратко>»
            $script:TestUiErrors.Count | Should -Be 1
            $script:TestUiErrors[0] | Should -Match 'Обновление отменено, восстановлена версия 2\.0\.0'
            $script:TestUiErrors[0] | Should -Match 'Причина:'
            $script:TestUiErrors[0] | Should -Match 'Имитация сбоя'
            # Assert: восстановленные файлы сходятся с манифестом свежего бэкапа
            $backupDirs = Get-TestBackupDirs -Sandbox $sb
            $backupDirs.Count | Should -Be 1
            $backupCheck = Test-GuiUpdateManifest -Directory $sb.App `
                -ManifestPath (Join-Path $backupDirs[0].FullName 'backup.json')
            $backupCheck.Ok | Should -BeTrue
            # Assert: мусор удален — staging и update-old (откат подтвержден) убраны
            $stagingLeft = @(Get-ChildItem -LiteralPath $sb.DataDir -Directory -Filter 'update-staging-*')
            $oldLeft = @(Get-ChildItem -LiteralPath $sb.DataDir -Directory -Filter 'update-old-*')
            $stagingLeft.Count | Should -Be 0
            $oldLeft.Count | Should -Be 0
        }

        It 'Сценарий 3: несовпадение SHA-256 архива — обновление не начинается, staging не создается, файлы не тронуты' {
            # Arrange: приложение v2.0.0; «скачивание» отказывает на проверке хеша
            $sb = New-TestAppSandbox
            Reset-TestUiRecorder
            $before = Get-TestFileHashes -Dir $sb.App
            $configBefore = (Get-FileHash -LiteralPath $sb.ConfigPath -Algorithm SHA256).Hash
            $release = New-TestRelease

            Mock Invoke-CurlDownload { $false }
            Mock Expand-Archive { throw 'Распаковка не должна выполняться при несовпадении SHA-256' }
            Mock Start-Process { $script:TestStartProcesses += $FilePath }

            # Act
            Invoke-TestGuiUpdate -Sandbox $sb -Release $release

            # Assert: распаковки не было, staging не создан, файлы побайтово прежние
            Should -Invoke Expand-Archive -Times 0 -Exactly
            $stagingLeft = @(Get-ChildItem -LiteralPath $sb.DataDir -Directory -Filter 'update-staging-*')
            $stagingLeft.Count | Should -Be 0
            $after = Get-TestFileHashes -Dir $sb.App
            foreach ($name in $script:ZC_GuiFiles) {
                $after[$name] | Should -Be $before[$name]
            }
            # Assert: бэкап не создавался, перезапуска нет, отката в логе нет
            (Get-TestBackupDirs -Sandbox $sb).Count | Should -Be 0
            Should -Invoke Start-Process -Times 0 -Exactly
            $logText = Get-TestUiLogText
            $logText | Should -Match 'Обновление GUI отменено'
            $logText | Should -Not -Match 'Откат'
            $script:TestUiErrors.Count | Should -Be 1
            # Assert: config.json не тронут
            (Get-FileHash -LiteralPath $sb.ConfigPath -Algorithm SHA256).Hash | Should -Be $configBefore
        }

        It 'Сценарий 4: в архиве нет ZapretControl.bat — прерывание ДО замены, файлы не тронуты' {
            # Arrange: staging из «архива» без одного из трёх файлов
            $sb = New-TestAppSandbox
            Reset-TestUiRecorder
            $before = Get-TestFileHashes -Dir $sb.App
            $script:TestStagingVersion = '2.1.0'
            $script:TestStagingOmit = 'ZapretControl.bat'
            $release = New-TestRelease

            Mock Invoke-CurlDownload { $true }
            Mock Expand-Archive {
                Write-TestGuiFiles -Dir $DestinationPath -Version $script:TestStagingVersion
                if ($script:TestStagingOmit) {
                    Remove-Item -LiteralPath (Join-Path $DestinationPath $script:TestStagingOmit) -Force
                }
            }
            Mock Start-Process { $script:TestStartProcesses += $FilePath }

            # Act
            Invoke-TestGuiUpdate -Sandbox $sb -Release $release

            # Assert: валидация отклонила staging, замены и бэкапа не было
            $after = Get-TestFileHashes -Dir $sb.App
            foreach ($name in $script:ZC_GuiFiles) {
                $after[$name] | Should -Be $before[$name]
            }
            (Get-TestBackupDirs -Sandbox $sb).Count | Should -Be 0
            Should -Invoke Start-Process -Times 0 -Exactly
            $logText = Get-TestUiLogText
            $logText | Should -Match 'не прошёл проверку'
            $logText | Should -Match 'ZapretControl\.bat'
            $script:TestUiErrors[0] | Should -Match 'не прошёл проверку'
            # Assert: неуспешный путь не оставляет staging
            $stagingLeft = @(Get-ChildItem -LiteralPath $sb.DataDir -Directory -Filter 'update-staging-*')
            $stagingLeft.Count | Should -Be 0
            # Assert: обновление отменено до подмены — update-old не создавался
            $oldLeft = @(Get-ChildItem -LiteralPath $sb.DataDir -Directory -Filter 'update-old-*')
            $oldLeft.Count | Should -Be 0
        }

        It 'Сценарий 5: версия в архиве не новее текущей (равная и старая) — отклонение с сообщением до любых замен' {
            # Arrange: два прогона — staging с равной (2.0.0) и старой (1.9.0) версией
            foreach ($stagingVersion in @('2.0.0', '1.9.0')) {
                $sb = New-TestAppSandbox
                Reset-TestUiRecorder
                $before = Get-TestFileHashes -Dir $sb.App
                $script:TestStagingVersion = $stagingVersion
                $script:TestStagingOmit = ''
                $release = New-TestRelease

                Mock Invoke-CurlDownload { $true }
                Mock Expand-Archive {
                    Write-TestGuiFiles -Dir $DestinationPath -Version $script:TestStagingVersion
                    if ($script:TestStagingOmit) {
                        Remove-Item -LiteralPath (Join-Path $DestinationPath $script:TestStagingOmit) -Force
                    }
                }
                Mock Start-Process { $script:TestStartProcesses += $FilePath }

                # Act
                Invoke-TestGuiUpdate -Sandbox $sb -Release $release

                # Assert: отказ «не новее», замены, бэкапа и перезапуска не было
                $logText = Get-TestUiLogText
                $logText | Should -Match 'Обновление GUI отменено'
                $logText | Should -Match ('Версия в staging \(' + $stagingVersion.Replace('.', '\.') + '\) не новее')
                $script:TestUiErrors[0] | Should -Match 'не новее установленной'
                $after = Get-TestFileHashes -Dir $sb.App
                foreach ($name in $script:ZC_GuiFiles) {
                    $after[$name] | Should -Be $before[$name]
                }
                (Get-TestBackupDirs -Sandbox $sb).Count | Should -Be 0
                Should -Invoke Start-Process -Times 0 -Exactly
                $stagingLeft = @(Get-ChildItem -LiteralPath $sb.DataDir -Directory -Filter 'update-staging-*')
                $stagingLeft.Count | Should -Be 0
            }
        }

        It 'Сценарий 3 (слой скачивания): архив с несовпадающим хешем отклоняется, файл не остается' {
            # Arrange: file:// вместо сети, хеш архива заведомо другой
            $src = Join-Path $script:SandboxRoot 'scenario3-archive.bin'
            [IO.File]::WriteAllText($src, 'archive payload')
            $url = 'file:///' + (($src -replace '\\', '/') -replace ' ', '%20')
            $out = Join-Path $script:SandboxRoot 'scenario3-downloaded.bin'

            # Act
            $ok = Invoke-CurlDownload -Url $url -OutFile $out -ExpectedSha256 ('B' * 64)

            # Assert: скачивание прервано — дальше (staging, замена) идти некуда
            $ok | Should -BeFalse
            Test-Path -LiteralPath $out | Should -BeFalse
            $script:ZC_LastDownloadError | Should -Match 'SHA256'
        }
    }

    # =========================================================================
    #  Хелперы: валидация staging (контракт issue §2)
    # =========================================================================
    Context 'Хелперы: валидация staging' {

        It 'Test-GuiUpdateStaging: отсутствующий файл — отказ с указанием файла, приложение не тронуто' {
            # Arrange: staging без ZapretCommon.ps1
            $sb = New-TestAppSandbox
            $staging = Add-TestStaging -Sandbox $sb -Version '2.1.0' -OmitFile 'ZapretCommon.ps1'
            $before = Get-TestFileHashes -Dir $sb.App

            # Act
            $validation = Test-GuiUpdateStaging -StagingDir $staging.Dir `
                -CurrentCommonPath (Join-Path $sb.App 'ZapretCommon.ps1')

            # Assert: отказ с указанием файла, замены не было
            $validation.Ok | Should -BeFalse
            ($validation.Reasons -join ' ') | Should -Match 'ZapretCommon\.ps1'
            $after = Get-TestFileHashes -Dir $sb.App
            foreach ($name in $script:ZC_GuiFiles) {
                $after[$name] | Should -Be $before[$name]
            }
        }

        It 'Test-GuiUpdateStaging: версия не новее (равная или старая) — отказ с сообщением, файлы прежние' {
            # Arrange: две песочницы — staging 2.0.0 (равна) и 1.9.0 (старше)
            $sbEqual = New-TestAppSandbox
            $stagingEqual = Add-TestStaging -Sandbox $sbEqual -Version '2.0.0'
            $sbOld = New-TestAppSandbox
            $stagingOld = Add-TestStaging -Sandbox $sbOld -Version '1.9.0'
            $before = Get-TestFileHashes -Dir $sbEqual.App

            # Act
            $resultEqual = Test-GuiUpdateStaging -StagingDir $stagingEqual.Dir `
                -CurrentCommonPath (Join-Path $sbEqual.App 'ZapretCommon.ps1')
            $resultOld = Test-GuiUpdateStaging -StagingDir $stagingOld.Dir `
                -CurrentCommonPath (Join-Path $sbOld.App 'ZapretCommon.ps1')

            # Assert: оба случая отклонены с сообщением о версии
            $resultEqual.Ok | Should -BeFalse
            ($resultEqual.Reasons -join ' ') | Should -Match 'не новее'
            $resultOld.Ok | Should -BeFalse
            ($resultOld.Reasons -join ' ') | Should -Match 'не новее'
            $resultEqual.StagingVersion | Should -Be '2.0.0'
            $resultEqual.CurrentVersion | Should -Be '2.0.0'
            # Assert: файлы не тронуты — замен не было
            $after = Get-TestFileHashes -Dir $sbEqual.App
            foreach ($name in $script:ZC_GuiFiles) {
                $after[$name] | Should -Be $before[$name]
            }
        }
    }

    # =========================================================================
    #  Хелперы: транзакционная подмена и откат (контракт issue §4–§6)
    # =========================================================================
    Context 'Хелперы: файловая последовательность и откат' {

        It 'Invoke-GuiUpdateFileSwap + Restore: сбой на втором файле, восстановление всех трёх из update-old с верификацией' {
            # Arrange: приложение v2.0.0, staging v2.1.0, бэкап-фикстура с манифестом
            $sb = New-TestAppSandbox
            $staging = Add-TestStaging -Sandbox $sb -Version '2.1.0'
            $oldDir = Join-Path $sb.DataDir 'update-old-3333'
            $fixture = New-TestBackupFixture -Sandbox $sb -Version '2.0.0' -Stamp '20260105-103000'
            $originals = Get-TestFileHashes -Dir $sb.App

            # Act: Move-Item подменен — исключение после первого успешного
            # перемещения из staging на место (вызовы 1-3 «в update-old» проходят)
            $script:InstallMoveCount = 0
            Mock Move-Item {
                $isToOld = [string]$Destination -like '*update-old*'
                if (-not $isToOld) {
                    $script:InstallMoveCount++
                    if ($script:InstallMoveCount -ge 2) {
                        throw 'Имитация сбоя: питание пропало между первым и вторым файлом'
                    }
                }
                if (Test-Path -LiteralPath $Destination) { [System.IO.File]::Delete($Destination) }
                [System.IO.File]::Move($LiteralPath, $Destination)
            }
            $swap = Invoke-GuiUpdateFileSwap -StagingDir $staging.Dir -OldDir $oldDir -TargetRoot $sb.App

            # Assert: замена прервалась на втором файле
            $swap.Ok | Should -BeFalse
            $swap.MovedToOld.Count | Should -Be 3
            $swap.Installed.Count | Should -Be 1
            ($swap.Errors -join ' ') | Should -Match 'Имитация сбоя'

            # Act: откат (issue §5 — без участия пользователя)
            $restore = Restore-GuiUpdateFiles -TargetRoot $sb.App -OldDir $oldDir `
                -BackupDir $fixture.Dir -ManifestPath $fixture.ManifestPath

            # Assert: все три файла восстановлены и проверены по backup.json
            $restore.Ok | Should -BeTrue
            $restore.Verified | Should -BeTrue
            $restore.Restored.Count | Should -Be 3
            foreach ($name in $script:ZC_GuiFiles) {
                $restore.Source[$name] | Should -Be 'update-old'
            }
            $after = Get-TestFileHashes -Dir $sb.App
            foreach ($name in $script:ZC_GuiFiles) {
                $after[$name] | Should -Be $originals[$name]
            }
            $manifestCheck = Test-GuiUpdateManifest -Directory $sb.App -ManifestPath $fixture.ManifestPath
            $manifestCheck.Ok | Should -BeTrue
        }

        It 'Сценарий 6: откат из backup-* при недоступном update-old + верификация по манифесту' {
            # Arrange: приложение уже «полуобновлено» (все три файла новые),
            # update-old отсутствует, бэкап-фикстура содержит старые файлы + манифест.
            # E2E у оркестратора эту ветку не воспроизвести (он всегда создаёт
            # update-old и хранит его до подтверждённого отката) — проверяем хелпер.
            $sb = New-TestAppSandbox
            $fixture = New-TestBackupFixture -Sandbox $sb -Version '2.0.0' -Stamp '20260105-103000'
            $originals = Get-TestFileHashes -Dir $sb.App
            $staging = Add-TestStaging -Sandbox $sb -Version '2.1.0'
            foreach ($name in $script:ZC_GuiFiles) {
                Copy-Item -LiteralPath (Join-Path $staging.Dir $name) -Destination (Join-Path $sb.App $name) -Force
            }
            $missingOldDir = Join-Path $sb.DataDir 'update-old-missing'

            # Act
            $restore = Restore-GuiUpdateFiles -TargetRoot $sb.App -OldDir $missingOldDir `
                -BackupDir $fixture.Dir -ManifestPath $fixture.ManifestPath

            # Assert: источник — бэкап, содержимое старое, манифест подтверждает
            $restore.Ok | Should -BeTrue
            $restore.Verified | Should -BeTrue
            foreach ($name in $script:ZC_GuiFiles) {
                $restore.Source[$name] | Should -Be 'backup'
            }
            $after = Get-TestFileHashes -Dir $sb.App
            foreach ($name in $script:ZC_GuiFiles) {
                $after[$name] | Should -Be $originals[$name]
            }
            $manifestCheck = Test-GuiUpdateManifest -Directory $sb.App -ManifestPath $fixture.ManifestPath
            $manifestCheck.Ok | Should -BeTrue
        }
    }

    # =========================================================================
    #  Бэкап и манифест (контракт issue §3, §5, §7)
    # =========================================================================
    Context 'Хелперы: бэкап и манифест' {

        It 'New-GuiUpdateBackup: backup-<версия>-<timestamp> со всеми тремя файлами и backup.json' {
            # Arrange: песочница v2.0.0, фиксированная метка времени
            $sb = New-TestAppSandbox
            $stamp = [datetime]::ParseExact('20260105-103000', 'yyyyMMdd-HHmmss',
                [Globalization.CultureInfo]::InvariantCulture)

            # Act
            $backup = New-GuiUpdateBackup -AppRoot $sb.App -CurrentVersion '2.0.0' -Timestamp $stamp

            # Assert: каталог создан по схеме issue §3
            $backup.Ok | Should -BeTrue
            $backup.BackupDir | Should -Be (Join-Path $sb.DataDir 'backup-2.0.0-20260105-103000')
            Test-Path -LiteralPath $backup.BackupDir -PathType Container | Should -BeTrue
            # Assert: все три файла скопированы
            foreach ($name in $script:ZC_GuiFiles) {
                Test-Path -LiteralPath (Join-Path $backup.BackupDir $name) -PathType Leaf | Should -BeTrue
            }
            $backup.Missing | Should -BeNullOrEmpty
            # Assert: манифест содержит версию и SHA-256 каждого файла,
            # хеши совпадают с файлами бэкапа и с рабочими файлами
            Test-Path -LiteralPath $backup.ManifestPath -PathType Leaf | Should -BeTrue
            $manifest = [IO.File]::ReadAllText($backup.ManifestPath) | ConvertFrom-Json
            $manifest.Version | Should -Be '2.0.0'
            $appHashes = Get-TestFileHashes -Dir $sb.App
            foreach ($name in $script:ZC_GuiFiles) {
                $entry = @($manifest.Files.PSObject.Properties | Where-Object { $_.Name -eq $name })
                $entry.Count | Should -Be 1
                $entry[0].Value | Should -Be $appHashes[$name]
                $backup.Hashes[$name] | Should -Be $appHashes[$name]
            }
        }

        It 'Test-GuiUpdateManifest: подделанный SHA-256 обнаруживается, файл называется' {
            # Arrange: бэкап-фикстура, затем портим один рабочий файл
            $sb = New-TestAppSandbox
            $fixture = New-TestBackupFixture -Sandbox $sb -Version '2.0.0' -Stamp '20260105-103000'
            [IO.File]::WriteAllText((Join-Path $sb.App 'ZapretCommon.ps1'), '# poddelannyj fajl')

            # Act
            $check = Test-GuiUpdateManifest -Directory $sb.App -ManifestPath $fixture.ManifestPath

            # Assert: отказ с именем файла и ожидаемым/фактическим хешем
            $check.Ok | Should -BeFalse
            $check.File | Should -Be 'ZapretCommon.ps1'
            $check.Reason | Should -Match 'не совпал'
            $check.Checked | Should -Be 3
        }

        It 'Remove-OldGuiUpdateBackups: остаются не более 3 новейших backup-*, legacy удаляется первым' {
            # Arrange: пять backup-* — legacy без timestamp + четыре с разными метками
            $sb = New-TestAppSandbox
            $names = @(
                'backup-1.0.0',
                'backup-1.0.1-20260101-090000',
                'backup-1.0.2-20260102-090000',
                'backup-2.0.0-20260103-090000',
                'backup-2.0.1-20260104-090000'
            )
            foreach ($name in $names) {
                New-Item -ItemType Directory -Path (Join-Path $sb.DataDir $name) -Force | Out-Null
            }

            # Act
            $result = Remove-OldGuiUpdateBackups -AppRoot $sb.App

            # Assert: остались ровно три новейших
            $result.Ok | Should -BeTrue
            $result.Keep | Should -Be 3
            $left = @(Get-ChildItem -LiteralPath $sb.DataDir -Directory -Filter 'backup-*' |
                ForEach-Object { $_.Name })
            $left.Count | Should -Be 3
            $result.Kept -contains 'backup-2.0.1-20260104-090000' | Should -BeTrue
            $result.Kept -contains 'backup-2.0.0-20260103-090000' | Should -BeTrue
            $result.Kept -contains 'backup-1.0.2-20260102-090000' | Should -BeTrue
            # Assert: legacy backup-<версия> без timestamp удаляется первым
            $result.Removed -contains 'backup-1.0.0' | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $sb.DataDir 'backup-1.0.0') | Should -BeFalse
        }
    }

    # =========================================================================
    #  Совместимость и очистка мусора (issue §7, «плюс» из задачи)
    # =========================================================================
    Context 'Совместимость и очистка' {

        It 'data\config.json не изменяется при транзакции' {
            # Arrange: полная последовательность транзакции хелперами
            $sb = New-TestAppSandbox
            $configBefore = (Get-FileHash -LiteralPath $sb.ConfigPath -Algorithm SHA256).Hash
            $contentBefore = [IO.File]::ReadAllText($sb.ConfigPath)
            $staging = Add-TestStaging -Sandbox $sb -Version '2.1.0'
            $oldDir = Join-Path $sb.DataDir 'update-old-4444'

            # Act: валидация -> бэкап -> замена -> очистка -> лимит бэкапов
            $validation = Test-GuiUpdateStaging -StagingDir $staging.Dir `
                -CurrentCommonPath (Join-Path $sb.App 'ZapretCommon.ps1')
            $validation.Ok | Should -BeTrue
            $backup = New-GuiUpdateBackup -AppRoot $sb.App -CurrentVersion '2.0.0'
            $backup.Ok | Should -BeTrue
            $swap = Invoke-GuiUpdateFileSwap -StagingDir $staging.Dir -OldDir $oldDir -TargetRoot $sb.App
            $swap.Ok | Should -BeTrue
            $cleanup = Remove-GuiUpdateLeftovers -StagingDir $staging.Dir -OldDir $oldDir
            $cleanup.Ok | Should -BeTrue
            $retention = Remove-OldGuiUpdateBackups -AppRoot $sb.App
            $retention.Ok | Should -BeTrue

            # Assert: конфиг не тронут — ни хеш, ни содержимое
            (Get-FileHash -LiteralPath $sb.ConfigPath -Algorithm SHA256).Hash | Should -Be $configBefore
            [IO.File]::ReadAllText($sb.ConfigPath) | Should -Be $contentBefore
        }

        It 'Remove-GuiUpdateLeftovers удаляет staging и update-old, рабочие файлы целы' {
            # Arrange: песочница с заполненными staging и update-old
            $sb = New-TestAppSandbox
            $staging = Add-TestStaging -Sandbox $sb -Version '2.1.0'
            $oldDir = Join-Path $sb.DataDir 'update-old-5555'
            New-Item -ItemType Directory -Path $oldDir -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $sb.App 'ZapretControl.ps1') -Destination (Join-Path $oldDir 'ZapretControl.ps1') -Force

            # Act
            $result = Remove-GuiUpdateLeftovers -StagingDir $staging.Dir -OldDir $oldDir

            # Assert: оба каталога удалены, рабочие файлы и config.json целы
            $result.Ok | Should -BeTrue
            $result.Removed.Count | Should -Be 2
            Test-Path -LiteralPath $staging.Dir | Should -BeFalse
            Test-Path -LiteralPath $oldDir | Should -BeFalse
            foreach ($name in $script:ZC_GuiFiles) {
                Test-Path -LiteralPath (Join-Path $sb.App $name) -PathType Leaf | Should -BeTrue
            }
            Test-Path -LiteralPath $sb.ConfigPath | Should -BeTrue
        }
    }
}
