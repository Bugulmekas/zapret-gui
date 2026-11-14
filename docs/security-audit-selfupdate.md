# Аудит безопасности: самообновление GUI/пакета, служба, запуск стратегий

**Объект:** `F:\zapret\GUI` (PowerShell 5.1 + WPF, запуск с правами администратора)
**Файлы:** `ZapretControl.ps1` (~3746 стр.), `ZapretCommon.ps1` (~700 стр.)
**Дата:** 2026-11-15
**Режим:** только чтение кода + безопасные эксперименты в `%TEMP%` (zip-slip, разбор аргументов `sc.exe`, чтение GitHub API). Приложение не запускалось, службы/драйверы/сеть не затрагивались, файлы `.ps1` не изменялись.

---

## 1. Резюме и оценка риска

**Общая оценка риска: СРЕДНИЙ–ВЫСОКИЙ.** Критичных (тривиально эксплуатируемых удалённо) находок не подтверждено. Подтверждено **3 находки уровня [Высоко]**, **6 [Средне]**, **6 [Низко]**.

Ключевая проблема класса: приложение **выполняет с правами администратора код, полученный из сети, без проверки целостности**, при этом параметр `-ExpectedSha256` в `Invoke-CurlDownload` реализован, но **не используется ни в одном вызове**. GitHub Releases API уже отдаёт `digest` для ассетов (проверено фактически: `digest=sha256:6196d44fd225fc53904e68ce7df4736f8f0824b8027850186f5ca9960b479f35` для `zapret-gui-1.3.0.zip`), то есть исправление реализуемо без изменения формата релиза.

Вторая по значимости проблема: `data\config.json` и путь `ZapretRoot` из него — **доверенные данные**, из которых следует путь к исполняемому файлу (`bin\winws.exe`), запускаемому с повышенными правами; каталог приложения обычно находится в пользовательской папке.

Что сделано хорошо и подтверждено: Zip Slip в PS 5.1 блокируется, синтаксис и версия нового архива проверяются перед установкой, `curl` вызывается с `-f` и `--`, ключевые разрушительные операции защищены проверкой прав администратора, секретов/ключей в логах нет.

---

## 2. Находки

### [Высоко] 1. Отсутствует проверка целостности скачиваемых архивов (SHA256 не проверяется)

**Где:**
- `ZapretCommon.ps1:737-809` — `Invoke-CurlDownload` реализует параметр `-ExpectedSha256` корректно (строки 789–806: считаем хеш, при несовпадении удаляем файл и возвращаем `false`).
- `ZapretControl.ps1:3089` — скачивание архива GUI: `Invoke-CurlDownload -Url $release.AssetUrl -OutFile $zipPath -TimeoutSec 600` — **`-ExpectedSha256` не передан**.
- `ZapretControl.ps1:3187` — скачивание архива пакета zapret — **то же**.
- `ZapretControl.ps1:2393` — скачивание IPSet — **то же**.
- `ZapretControl.ps1:3290` — скачивание hosts — **то же**.
- `ZapretCommon.ps1:818-824` и `844-850` — поле `digest` из ответа GitHub API **не читается** и не пробрасывается дальше.

**Сценарий:** атакующий, получивший контроль над репозиторием/аккаунтом релизов (или MITM с подменой сертификата, если TLS-канал скомпрометирован), публикует релиз `v1.4.0` с архивом, содержащим изменённый `ZapretControl.ps1`. Пользователь нажимает «Обновить GUI» → архив распаковывается в `data\..` → **не проверяется ни хеш, ни подпись** → изменённый скрипт копируется в каталог приложения (`:3125-3130`) и запускается с правами администратора при следующем старте; для пакета zapret — подменённый `bin\winws.exe` попадает в `ImagePath` службы, то есть исполняется как **SYSTEM**. HTTPS этого не предотвращает: он защищает канал, но не репозиторий.

**Исправление:**

`ZapretCommon.ps1` — в `Get-LatestZapretRelease` и `Get-LatestGuiRelease` пробрасываем digest:

```powershell
        $assetName = $null
        $assetUrl = $null
        $assetSha256 = $null
        if ($asset) {
            $assetName = [string]$asset.name
            $assetUrl  = [string]$asset.browser_download_url
            # GitHub отдаёт digest вида "sha256:<hex>" (проверено на api.github.com).
            if ($asset.digest -and ([string]$asset.digest) -match '^sha256:(?<hex>[0-9a-fA-F]{64})$') {
                $assetSha256 = $Matches['hex'].ToUpperInvariant()
            }
        }

        return [pscustomobject]@{
            Tag         = [string]$json.tag_name
            ...
            AssetSha256 = $assetSha256
        }
```

`ZapretControl.ps1:3086-3091` (и аналогично `:3184-3189`):

```powershell
        # Без хеша от GitHub обновление не выполняем: иначе целостность не проверяется.
        if ([string]::IsNullOrWhiteSpace($release.AssetSha256)) {
            throw 'GitHub не вернул SHA256 ассета — обновление отменено (нет проверки целостности).'
        }
        $zipPath = Join-Path $workDir (Get-SafeAssetName -Name $release.AssetName)
        Set-BusyStatus 'Скачивание GUI...'
        Write-UiLog ('Скачивание GUI: ' + $release.AssetUrl) 'Cyan'
        if (-not (Invoke-CurlDownload -Url $release.AssetUrl -OutFile $zipPath -TimeoutSec 600 `
                    -ExpectedSha256 $release.AssetSha256)) {
            throw ('Не удалось скачать или проверить архив GUI: ' + $script:ZC_LastDownloadError)
        }
```

> Для IPSet (`ZapretControl.ps1:2393`) и hosts (`:3290`) ожидаемый хеш нужно зафиксировать в коде (`$script:ZC_IpsetSha256`) либо проверять по подписи — сейчас эти файлы принимаются «как есть».

---

### [Высоко] 2. Путь для сохранения архива строится из имени ассета без санитизации (обход каталога)

**Где:**
- `ZapretControl.ps1:3086` — `$zipPath = Join-Path $workDir $release.AssetName`
- `ZapretControl.ps1:3184` — то же для пакета zapret
- `ZapretCommon.ps1:818` — фильтр ассета пакета: `-like '*.zip'`
- `ZapretCommon.ps1:844` — фильтр ассета GUI: `-like 'zapret-gui-*.zip'`

**Сценарий (подтверждено экспериментом):** имя ассета из JSON берётся как есть. `-like 'zapret-gui-*.zip'` пропускает `..\..\zapret-gui-evil.zip` ( wildcard `*` совпадает и с `..\..\`), а `-like '*.zip'` пропускает `..\..\evil.zip`. `Join-Path 'C:\workdir' '..\..\evil.zip'` даёт `C:\workdir\..\..\evil.zip` — путь **выходит за пределы** `$env:TEMP%\zapret-*-<guid>`. `curl -o $zipPath` (`ZapretCommon.ps1:765`) запишет файл по этому пути — произвольная запись `.zip` от имени администратора в место, выбранное атакующим (расширение ограничено `.zip`; имя целевого каталога ограничено `%TEMP%`-префиксом на 1–2 уровня вверх).

**Исправление** (новая функция в `ZapretCommon.ps1` + вызов в обоих местах):

```powershell
function Get-SafeAssetName {
    # Имя ассета из GitHub API — недоверенные данные: берём только базовое имя
    # без каталогов, точек-обходов и посторонних расширений.
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    $leaf = [IO.Path]::GetFileName($Name)
    if ([string]::IsNullOrWhiteSpace($leaf)) { return $null }
    if ($leaf -ne $Name) { return $null }                     # было '..\..\x.zip' или 'sub\x.zip'
    if ($leaf -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,120}\.zip$') { return $null }
    if ($leaf -match '^\.+$') { return $null }
    return $leaf
}
```

```powershell
        $safeName = Get-SafeAssetName -Name $release.AssetName
        if (-not $safeName) { throw ('Недопустимое имя ассета: ' + $release.AssetName) }
        $zipPath = Join-Path $workDir $safeName
```

> `Install-UpdateAction` уже использует `[IO.Path]::GetFileNameWithoutExtension()` для имени целевой папки (`:3203`) — там обход не проходит; проблема только в пути загрузки.

---

### [Высоко] 3. Замена файлов GUI неатомарна, откат не выполняется

**Где:** `ZapretControl.ps1:3113-3130` (резервная копия + перезапись), `ZapretControl.ps1:3150-3154` (обработка ошибки).

**Сценарий:** резервная копия создаётся (`:3113-3122`), но **нигде не используется**: в `catch` (`:3150`) только пишется лог и показывается окно. Файлы `ZapretControl.ps1`/`ZapretCommon.ps1` перезаписываются напрямую (`Copy-Item -Force`, `:3128`). Любой сбой на середине (диск заполнен, антивирус блокирует запись, питание отключается) оставляет **обрезанный .ps1** — приложение перестаёт запускаться, а ручной откат из `data\backup-<версия>` пользователю не предлагается. Для обновляемого приложения с правами администратора это отказ в обслуживании.

**Исправление** (атомарная подмена + откат):

```powershell
    $files = @('ZapretControl.ps1', 'ZapretCommon.ps1', 'ZapretControl.bat')
    $backupDir = Join-Path $script:DataDir ('backup-' + $script:ZC_AppVersion)
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    foreach ($name in $files) {
        $current = Join-Path $script:AppDir $name
        if (Test-Path -LiteralPath $current) {
            Copy-Item -LiteralPath $current -Destination (Join-Path $backupDir $name) -Force
        }
    }

    Set-BusyStatus 'Установка GUI...'
    foreach ($name in $files) {
        $candidate = Join-Path $sourceDir $name
        if (-not (Test-Path -LiteralPath $candidate)) { continue }
        $dest = Join-Path $script:AppDir $name
        $tmp  = Join-Path $script:AppDir ('.' + $name + '.new')
        Copy-Item -LiteralPath $candidate -Destination $tmp -Force
        Move-Item -LiteralPath $tmp -Destination $dest -Force   # замена в пределах тома
    }
```

и в `catch` — восстановление из резервной копии (переменные `$files`/`$backupDir` нужно вынести **до** `try`):

```powershell
    } catch {
        # Откат: возвращаем рабочие файлы из резервной копии.
        foreach ($name in $files) {
            $backup = Join-Path $backupDir $name
            if (Test-Path -LiteralPath $backup) {
                try { Copy-Item -LiteralPath $backup -Destination (Join-Path $script:AppDir $name) -Force } catch { }
            }
        }
        Write-UiLog ('Ошибка обновления GUI: ' + $_.Exception.Message + ' (выполнен откат)') 'Red'
        Show-UiError $_.Exception.Message 'Обновление GUI'
        Set-BusyStatus 'Ошибка обновления GUI'
    }
```

---

### [Средне] 4. Режим автозапуска службы теряется при переустановке и обновлении

**Где:**
- `ZapretControl.ps1:1968` — `New-Service ... -StartupType Automatic` — **всегда** Automatic, текущий `StartType` игнорируется.
- `ZapretControl.ps1:2157-2158` — `Set-AutostartAction` умеет переключать `auto`/`demand` (через `sc.exe config`).
- `ZapretControl.ps1:3255` — `Install-UpdateAction` переустанавливает службу → автозапуск возвращается.
- `ZapretControl.ps1:2312` — `Apply-RunningChanges` переустанавливает службу → то же.
- `ZapretControl.ps1:2051` — `Remove-ServiceInternal` удаляет службу → режим теряется безвозвратно.

**Сценарий:** пользователь снял галку «Автозапуск» (`demand`), затем применил изменение игрового фильтра или обновил пакет → служба пересоздана с `Automatic` и поднимается при каждой загрузке Windows, хотя пользователь этого не хотел. Функциональная/политическая регрессия, но заметная.

**Исправление:**

```powershell
    # Запоминаем режим автозапуска до удаления службы.
    $existing = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
    $startupType = 'Automatic'
    if ($existing) {
        switch ([string]$existing.StartType) {
            'Manual'    { $startupType = 'Manual' }
            'Disabled'  { $startupType = 'Disabled' }
            default     { $startupType = 'Automatic' }
        }
    }
    ...
    New-Service -Name 'zapret' -BinaryPathName $binaryPath -DisplayName 'zapret' `
        -StartupType $startupType -ErrorAction Stop | Out-Null
```

---

### [Средне] 5. Служба удаляется до создания новой; результат (ImagePath) не проверяется; отката нет

**Где:** `ZapretControl.ps1:1957-1961` (`sc.exe delete zapret` + ожидание исчезновения), `:1966-1985` (создание), `:1974-1979` (fallback `sc.exe`), `:1987-1995` (описание/реестр/старт).

**Сценарий:** `sc.exe delete zapret` выполняется **до** создания. Если `New-Service` и fallback `sc.exe` оба не сработали (`:1982-1985`), у пользователя не остаётся **ни одной** службы — прежняя конфигурация (binPath, стратегия, автозапуск) потеряна, отката нет. Кроме того, после создания проверяется только код возврата `sc.exe`; фактический `ImagePath` в реестре не сверяется, поэтому «успешное» создание с испорченной командной строкой остаётся незамеченным (см. находку 6).

**Исправление:**

```powershell
    $expectedPath = '"' + $exe + '" ' + $argLine
    ...
    # после успешного создания:
    $actualPath = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\zapret' `
        -Name 'ImagePath' -ErrorAction SilentlyContinue).ImagePath
    if ($actualPath -ne $expectedPath) {
        & sc.exe delete zapret 2>$null | Out-Null
        Write-UiLog ('Некорректный ImagePath службы, служба удалена. Ожидалось: ' + $expectedPath) 'Red'
        Show-UiError 'Служба создана с некорректным путём и была удалена.'
        return $false
    }
```

Плюс: сохранять `ImagePath`/`StartType` старой службы до `delete` (шаг 4) и восстанавливать старую службу, если новая не создалась.

---

### [Средне] 6. Fallback через `sc.exe` формирует некорректную командную строку

**Где:** `ZapretControl.ps1:1973-1974`

```powershell
$scArgs = 'create zapret binPath= "\"' + $exe + '\" ' + $argLine + '" DisplayName= "zapret" start= auto'
$scProcess = Start-Process -FilePath 'sc.exe' -ArgumentList $scArgs -Wait -PassThru -WindowStyle Hidden
```

**Подтверждённый факт (эксперимент):** в PowerShell 5.1 `'\"'` внутри single-quoted строки — это **буквальный** backslash + кавычка, а не escape. Фактическая строка:

```
create zapret binPath= "\"F:\...\bin\winws.exe\" --hostlist="F:\...\list-general.txt" --filter-udp=443" DisplayName= "zapret" start= auto
```

Два дефекта: (а) лишние обратные косые черты, которые `sc.exe` не трактует как escape (в отличие от `\"` в C-строке); (б) **внутренние кавычки** из `$argLine` разрывают значение `binPath=`. Внутренние кавычки — норма для стратегий zapret: `--hostlist="..."`, `--dpi-desync-fake="..."` (см. фактический `data\run-current.bat`). Итог: значение `binPath=` будет разобрано неверно → в реестр попадёт обрезанный/испорченный `ImagePath` → служба не стартует. Точный итоговый `ImagePath` зависит от парсера `sc.exe` — **требует проверки на реальной машине**, но сама команда построена неверно (это подтверждено).

**Исправление (рекомендуется):** отказаться от ручной сборки строки — `New-Service` вызывает SCM API и передаёт `BinaryPathName` без экранирования. Fallback оставить только для диагностики:

```powershell
    } catch {
        Write-UiLog ('New-Service не сработал: ' + $_.Exception.Message) 'Yellow'
        # sc.exe оставлен только как диагностика: ручная сборка binPath=
        # ломается на кавычках внутри аргументов winws.
        $scArgs = 'create zapret binPath= "' + $exe + ' ' + $argLine + '" DisplayName= "zapret" start= auto'
        $scProcess = Start-Process -FilePath 'sc.exe' -ArgumentList $scArgs -Wait -PassThru -WindowStyle Hidden
        if ($scProcess.ExitCode -ne 0) {
            Write-UiLog ('sc.exe create завершился с кодом ' + $scProcess.ExitCode) 'Red'
        }
        # В любом случае проверяем фактический ImagePath (см. находку 5).
    }
```

> Если fallback нужен функционально — значение `binPath=` следует передавать через переменную окружения/временный .bat, а не конкатенацией строк; в любом случае обязательна сверка `ImagePath` после создания.

---

### [Средне] 7. `Install-UpdateAction`: нет проверки прав администратора, нет отката, конфиг переключается до проверки результата

**Где:** `ZapretControl.ps1:3161-3277` (в отличие от `Install-ServiceInternal:1931`, здесь `Test-IsAdmin` **не вызывается**), `:3209-3210` (остановка службы/процессов), `:3216` (копирование), `:3235-3241` (переключение `ZapretRoot` + `Save-Config`).

**Сценарий:** запуск без прав администратора → `Stop-ZapretService`/`Stop-ZapretProcesses` молча ничего не делают, файлы копируются в новую папку, `$script:ZapretRoot` и `Config.ZapretRoot` переключаются на неё, `Save-Config` (`:3241`) фиксирует новое значение — **старая рабочая папка перестаёт использоваться**, а служба по-прежнему указывает на старую версию. Если копирование упало на середине (`:3216` — `Copy-Item` без проверок), в конфиг уже записан путь к неполной папке. Отката нет.

**Исправление:**

```powershell
function Install-UpdateAction {
    if (-not (Test-IsAdmin)) { Show-UiError 'Обновление пакета zapret требует прав администратора.'; return }
    ...
        # Порядок: сначала убеждаемся, что новая папка рабочая, и только потом переключаем конфиг.
        if (-not (Test-Path -LiteralPath (Join-Path $targetDir 'bin\winws.exe'))) {
            throw ('В новой папке нет bin\winws.exe: ' + $targetDir)
        }
        $script:ZapretRoot = $targetDir
        $script:Config.ZapretRoot = $targetDir
        ...
        Save-Config
```

и в `catch` — возврат `$script:ZapretRoot`/`$script:Config.ZapretRoot` к `$oldRoot` с повторным `Save-Config`.

---

### [Средне] 8. Ошибка `Expand-Archive` не обрабатывается → частичная распаковка принимается за успех

**Где:** `ZapretControl.ps1:3095` и `:3194` — `Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force` (без `-ErrorAction Stop`); в `ZapretControl.ps1`/`ZapretCommon.ps1` **нет** установки `$ErrorActionPreference` (проверено: она есть только в `tools\Test-*.ps1`).

**Подтверждено экспериментом (PS 5.1.22621):** архив с записью `..\..\evil.txt` → `Expand-Archive` пишет `WriteErrorException`, **но продолжает** распаковку остальных записей (`$? = True`), файл вне каталога не создаётся. То есть **Zip Slip заблокирован** (это хорошо, см. раздел 3), но «битый»/частично распакованный архив обрабатывается как корректный: приложение продолжит установку частичного пакета, а пользователь не увидит ошибки.

**Исправление:**

```powershell
        # Проверяем записи архива до распаковки: никаких '..' и абсолютных путей.
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [IO.Compression.ZipFile]::OpenRead($zipPath)
        try {
            foreach ($entry in $archive.Entries) {
                $n = $entry.FullName
                if ($n -match '(^|[\\/])\.\.([\\/]|$)' -or [IO.Path]::IsPathRooted($n)) {
                    throw ('Недопустимый путь в архиве: ' + $n)
                }
            }
        } finally { $archive.Dispose() }

        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force -ErrorAction Stop
```

---

### [Средне] 9. `config.json` и `ZapretRoot` — доверенные данные, ведущие к исполнению кода с правами администратора

**Где:**
- `ZapretControl.ps1:44-53` — `ZapretRoot`, `SelectedStrategy`, `LastStartedStrategy` читаются из `data\config.json` без проверок.
- `ZapretCommon.ps1:70-72` — `Resolve-ZapretRoot` доверяет подсказке, требуя лишь наличие `bin\winws.exe`.
- `ZapretControl.ps1:1828-1857` — `Start-StrategyInternal` (запуск от администратора) строит команду из `<ZapretRoot>\bin\winws.exe` и аргументов из `<ZapretRoot>\<стратегия>.bat`.
- `ZapretControl.ps1:1963-1964` — `binPath` службы = `<ZapretRoot>\bin\winws.exe`.
- `ZapretControl.ps1:2389-2407` — `Update-IpsetAction` пишет в `<ZapretRoot>\lists\ipset-all.txt`.
- Каталог приложения (куда распакован GUI) и `data\` лежат в пользовательской папке; `data\` создаётся без ограничения ACL (`ZapretControl.ps1:24-27`).

**Сценарий:** на машине с общим доступом (или при загрузке «съёмного» архива в `Downloads`) любой пользователь, пишущий в `data\config.json`, задаёт `ZapretRoot` на свою папку с `bin\winws.exe` → при запуске GUI администратором (`ZapretControl.ps1:85-89` — UAC-повышение) выполняется его исполняемый файл (SYSTEM-контекст при установке службы). Дополнительно: сам скрипт `ZapretControl.ps1`, который запускается с повышенными правами, лежит в **пользовательской** папке — между запросом UAC и стартом повышенного процесса файл можно подменить (TOCTOU).

**Исправление:**

```powershell
# 1) Ограничить каталог данных: только текущий пользователь и SYSTEM.
function Protect-DataDir {
    param([string]$Path)
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)          # не наследовать права родителя
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    foreach ($pair in @(@($sid, 'FullControl'), @('S-1-5-18', 'FullControl'))) {
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $pair[0], [Security.AccessControl.FileSystemRights]::FullControl,
            ([Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'),
            ([Security.AccessControl.PropagationFlags]::None),
            [Security.AccessControl.AccessControlType]::Allow)
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

# 2) Перед запуском winws.exe — сверить хеш с заведённым в приложении.
function Assert-TrustedWinws {
    param([string]$Root)
    $exe = Join-Path $Root 'bin\winws.exe'
    if (-not (Test-Path -LiteralPath $exe)) { return $false }
    $expected = $script:ZC_TrustedWinwsSha256   # обновляется при Install-UpdateAction
    if ([string]::IsNullOrWhiteSpace($expected)) { return $true }   # хеш ещё не зафиксирован
    $actual = (Get-FileHash -LiteralPath $exe -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
    return ($actual -eq $expected)
}
```

> Проверка цифровой подписи `winws.exe` (`Get-AuthenticodeSignature`) возможна, только если upstream подписывает бинарник — **требует проверки**; хеш-пиннинг реализуем сразу.

---

### [Низко] 10. UAC-перезапуск: относительный `powershell.exe`, пустой `$PSCommandPath`, «нулевые» коды выхода

**Где:** `ZapretControl.ps1:85-96`.

**Сценарий/факты:**
- `:87` — `Start-Process -FilePath 'powershell.exe' ... -Verb RunAs`: имя ищется через ShellExecute, в том числе в **текущем каталоге**. Лаунчер `ZapretControl.bat:15-16` специально использует абсолютный путь («no hijack by a rogue powershell.exe») — в скрипте это правило не применено.
- `:88` — `-File "' + $PSCommandPath + '"`: при запуске не через `-File` (например `powershell -Command "& 'C:\...\ZapretControl.ps1'"`, ISE, dot-sourcing) `$PSCommandPath` пуст → дочерний процесс падает с `-File ""`, приложение молча закрывается.
- `:95` — `exit` без кода: при отказе UAC (пользователь нажал «Нет») родитель возвращает **0**, и `ZapretControl.bat:24` (`if errorlevel 1`) ошибку не покажет.

**Исправление:**

```powershell
if (-not $Preview -and -not (Test-IsAdmin)) {
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $psExe) -or [string]::IsNullOrWhiteSpace($PSCommandPath)) {
        [void][Windows.MessageBox]::Show(
            "Не удалось определить путь к PowerShell или к скрипту.`nЗапуск отменён.",
            'Zapret Control', 'OK', 'Warning')
        exit 1
    }
    try {
        Start-Process -FilePath $psExe `
            -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File "' + $PSCommandPath + '"') `
            -Verb RunAs -ErrorAction Stop | Out-Null
        exit 0
    } catch {
        [void][Windows.MessageBox]::Show(
            "Для работы Zapret Control нужны права администратора.`n`nЗапуск отменён.",
            'Zapret Control', 'OK', 'Warning')
        exit 1
    }
}
```

---

### [Низко] 11. Скачанные списки IPSet/hosts принимаются без проверки содержимого

**Где:** `ZapretControl.ps1:2393-2407` (IPSet), `ZapretControl.ps1:3286-3319` (hosts).

**Сценарий:** для IPSet проверяется только размер (`> 100` байт, `:2400-2405`), после чего файл **подменяет** `lists\ipset-all.txt`, используемый winws как список IP. Подставленный мусор (например, не-IP строки) ломает обход или, при определённых условиях, меняет набор блокируемых адресов. Для hosts файл из сети открывается в блокноте и копируется пользователем вручную (`:3317`) — риск минимален, но также без сверки.

**Исправление:**

```powershell
    # После скачивания IPSet — проверяем, что это список IP/CIDR.
    $lines = @(Get-Content -LiteralPath $temp -ErrorAction SilentlyContinue |
               Where-Object { $_ -and -not $_.TrimStart().StartsWith('#') })
    $bad = @($lines | Where-Object { $_ -notmatch '^[0-9a-fA-F:.]+(\s*/\s*(8|16|24|32|48|64|96|128))?$' })
    if ($lines.Count -eq 0 -or $bad.Count -gt 0) {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        Show-UiError 'Скачанный IPSet не похож на список IP/CIDR — обновление отменено.'
        return
    }
```

---

### [Низко] 12. Генерация `run-current.bat`: аргументы стратегии попадают в `cmd` без экранирования

**Где:** `ZapretControl.ps1:1854-1862` (сборка .bat), `:1869` (запуск `cmd /c`), `ZapretCommon.ps1:193-262` (разбор аргументов из `.bat` стратегии).

**Сценарий:** `$argLine` берётся из пользовательского `.bat` стратегии и подставляется в `.bat` как есть. Спецсимволы `&`, `|`, `^`, `%`, кавычки в пути (`ZapretRoot` из `config.json`) не экранируются → возможна инъекция команд в `cmd.exe` и поломка запуска. Аналогично `:1869` — путь к `run-current.bat` в кавычках, но спецсимволы не экранированы.

**Исправление (рекомендуется — убрать .bat из цепочки запуска):**

```powershell
    # Запуск winws.exe напрямую: cmd и .bat не нужны, аргументы не интерпретируются.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = $argLine
    $psi.WorkingDirectory = $binDir
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $proc = [Diagnostics.Process]::Start($psi)
```

Если `.bat` нужен (совместимость), экранировать спецсимволы `cmd`:

```powershell
function ConvertTo-CmdSafe {
    param([string]$Value)
    $v = $Value -replace '%', '%%'
    $v = $v -replace '([&|<>^()!])', '^$1'
    return $v
}
```

---

### [Низко] 13. Диагностика удаляет сторонние службы

**Где:** `ZapretControl.ps1:2736-2748` — по подтверждению удаляются службы `GoodbyeDPI`, `discordfix_zapret`, `winws1`, `winws2` (`Stop-Service` + `sc.exe delete`). Список фиксирован и действие подтверждается диалогом, но это разрушительная операция с правами SYSTEM без проверки, что служба действительно «конфликтующая» (например, `winws1` может принадлежать другой установке).

**Исправление:** проверять `ImagePath` удаляемой службы (должен указывать на winws.exe/профиль известной программы) и показывать в диалоге путь к образу:

```powershell
                $img = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$conflictName" `
                          -Name 'ImagePath' -ErrorAction SilentlyContinue).ImagePath
                $conflictQuestion = "Найдены конфликтующие службы:`n" + ($conflicts -join "`n") +
                                    "`n`nИх образы:`n" + (($img -join "`n")) + "`n`nУдалить их?"
```

---

### [Низко] 14. Нет проверки источника загрузки (`browser_download_url`)

**Где:** `ZapretCommon.ps1:818-824`, `844-850` — URL ассета берётся из ответа API без проверки хоста.

**Сценарий:** при подмене ответа API (MITM/компрометация) загрузка пойдёт с чужого хоста; проверка SHA256 (находка 1) это закрывает, но дополнительно стоит проверять хост:

```powershell
    if ($assetUrl -and ([Uri]$assetUrl).Host -notmatch '^(github\.com|objects\.githubusercontent\.com|githubusercontent\.com)$') {
        $assetUrl = $null   # ассет с неизвестного хоста не принимаем
    }
```

---

### [Низко] 15. PII и метаданные трафика в `data\winws.log`

**Где:** `ZapretControl.ps1:29`, `1862-1863` — вывод winws пишется в `data\winws.log` (stdout/stderr winws может содержать домены/адреса трафика пользователя).

**Факт:** секретов, ключей, токенов в логах нет — проверено (`Write-UiLog`, `ZapretControl.ps1:1537-1568`, пишет только в UI, файлового лога нет). Остаётся риск утечки метаданных трафика при передаче лога; каталог `data\` создаётся с правами по умолчанию (см. находку 9).

**Исправление:** ограничить права на `data\` (находка 9) и не предлагать отправку логов без явного предупреждения о содержимом.

---

## 3. Что проверено — претензий нет

| Проверка | Результат |
|---|---|
| **Zip Slip в PS 5.1** | `Expand-Archive` отклоняет записи с `..\` — выход за пределы каталога не происходит. Подтверждено запуском `tools\Test-ZipSlip.ps1` (PASS) и независимым экспериментом: файл `..\..\evil.txt` не создан, остальные записи распакованы. Претензия только к обработке ошибки (находка 8). |
| **Проверка синтаксиса новых файлов** | `ZapretControl.ps1:3103-3107` — `[Parser]::ParseFile` для обоих .ps1 перед установкой. |
| **Защита от downgrade/подмены версии** | `ZapretControl.ps1:3109-3111` — версия в архиве должна совпадать с тегом релиза, иначе установка прерывается. |
| **Реализация `-ExpectedSha256`** | `ZapretCommon.ps1:789-806` — хеш считается, при несовпадении файл удаляется и возвращается `false`. Корректно (проблема только в том, что параметр не используется — находка 1). |
| **Обработка HTTP-ошибок curl** | `ZapretCommon.ps1:711, 765` — `-f` (4xx/5xx = ошибка) и `--` (URL отделяется от ключей curl). |
| **Чистота скачивания** | `ZapretCommon.ps1:749-787` — старый файл удаляется до загрузки, пустой файл не принимается за успех. |
| **Проверки прав администратора** | Перед разрушительными действиями: `Start-StrategyInternal:1825`, `Install-ServiceInternal:1931`, `Remove-ServiceInternal:2034`, `Set-AutostartAction:2148`, `Apply-GameFilterAction:2332`, `Run-StrategyTestsAction:2916` → `Remove-ServiceInternal`. |
| **Разбор аргументов winws** | `ZapretCommon.ps1:196-262` — служебные строки (`rem`, `echo`, `set`, `if`, `tasklist`…) отбрасываются, переносы `^` склеиваются, аргументы должны начинаться с `--`/`/`, неподставленные `%VAR%` приводят к отказу запуска (`:257-260`). |
| **Обработка кодов `sc.exe delete`** | `ZapretCommon.ps1:574-583` — код 1060 («службы нет») не считается ошибкой, для остальных пишется диагностика. |
| **Запуск лаунчером** | `ZapretControl.bat:16, 23` — абсолютный путь к `powershell.exe`, `-NoProfile -ExecutionPolicy Bypass -Sta`, проверка кода возврата. |
| **Секреты в логах** | Ключей/токенов/учётных данных в `Write-UiLog` (`ZapretControl.ps1:1537-1568`) и в `data\winws.log` нет; файлового лога UI-сообщений не создаётся. |
| **Фильтрация конфликтующих служб** | `ZapretControl.ps1:2736` — список фиксирован (`GoodbyeDPI`, `discordfix_zapret`, `winws1`, `winws2`), удаление только после подтверждения. |
| **Проверка пути установки zapret** | `ZapretCommon.ps1:70-72`, `ZapretControl.ps1:124` — `Resolve-Path` нормализует путь; `data\` в `.gitignore` (`GUI/.gitignore:1`), т.е. локальные пути/настройки в репозиторий не попадают. |

---

## 4. Рекомендуемый порядок работ

1. **Высоко:** включить проверку SHA256 через `digest` GitHub API (находка 1) + санитизация имени ассета (находка 2) — правки локальные, ~30 строк, снимают главный риск RCE.
2. **Высоко:** атомарная замена файлов GUI с откатом (находка 3).
3. **Средне:** проверка `ImagePath` после создания службы, сохранение/восстановление `StartType`, корректный fallback `sc.exe` (находки 4–6).
4. **Средне:** проверка прав + откат в `Install-UpdateAction`, `-ErrorAction Stop` и валидация записей архива (находки 7–8).
5. **Средне:** защита каталога `data\` (ACL) и хеш-пиннинг `winws.exe` (находка 9).
6. **Низко:** UAC-перезапуск (10), валидация IPSet (11), уход от `cmd`/`.bat` в запуске (12), прочее (13–15).
