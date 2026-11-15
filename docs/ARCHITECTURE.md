# ARCHITECTURE.md

Карта файлов, стек и поток запуска Zapret Control. Состояние репозитория: ветка `main`, версия `ZC_AppVersion = 2.1.0`.

## Карта файлов

| Каталог / файл | Содержит | Назначение |
|---|---|---|
| `ZapretControl.ps1` | XAML-разметка окна (`$windowXaml`), стили (`Window.Resources`), три темы (`light`/`dark`/`neon`), пять страниц (`PageService`, `PageSettings`, `PageTools`, `PageTests`, `PageUpdate`), обработчики событий (`Add_Click`), функции действий (запуск стратегии, служба, IPSet, обновление, диагностика), таймеры | Главный скрипт GUI на WPF |
| `ZapretCommon.ps1` | Пути (`Resolve-ZapretRoot`, `Get-ZapretCandidates`), стратегии (`Get-Strategies`, `Get-WinwsArgs`), игровой фильтр, IPSet (`Get/Set-IpsetMode` с `.backup`/`.prev`), служба Windows (`Start/Stop/Remove-ZapretService`, проверка стабильности ~5 с, `Reset-WinDivertDriver`), конфликты VPN (`Get-VpnConflicts`), загрузки с GitHub (`Invoke-CurlText`/`Invoke-CurlDownload` через `curl` со временным UTF-8-файлом), версии (`Get-LocalZapretVersion` из `LOCAL_VERSION` в `service.bat`), самообновление GUI (`Test-GuiUpdateStaging`, `New-GuiUpdateBackup`, `Invoke-GuiUpdateFileSwap`, `Restore-GuiUpdateFiles`, `Remove-OldGuiUpdateBackups`) | Общая библиотека функций |
| `ZapretControl.bat` | Полный путь к `powershell.exe`, проверка наличия `.ps1` рядом, проброс `errorlevel` | Лаунчер |
| `tools\Test-Xaml.ps1` | Разбор XAML через `XamlReader` без запуска окна | Проверки |
| `tools\Test-UiSmoke.ps1` | Дымовый тест интерфейса через UI Automation (`-Preview`) | Проверки |
| `tools\Capture-UiPreview.ps1` | PNG-снимок окна (базовые скриншоты) | Проверки |
| `tools\Test-Contrast.ps1` | Контраст WCAG 2.1 для палитр всех тем | Проверки |
| `tools\Test-ZipSlip.ps1` | Защита от Zip Slip при распаковке архивов | Проверки |
| `tests\Update.Tests.ps1` | Pester v5: сценарии транзакционного самообновления (staging, бэкап, подмена, откат, лимит бэкапов) в песочнице `%TEMP%` | Тесты |
| `.github\workflows\update-tests.yml` | Прогон Pester-тестов самообновления и проверок `tools\` в Windows PowerShell 5.1 и PowerShell 7 | CI |
| `data\config.json` | Папка zapret, выбранная стратегия, тема, авто-проверка обновлений | Данные |
| `data\winws.log` | Вывод `winws.exe` при ручном запуске | Данные |
| `data\run-current.bat` | Временный файл запуска стратегии | Данные |
| `data\ipset-new.txt` | Временный файл обновления IPSet | Данные |
| `data\update-staging-<guid>\` | Распакованный архив обновления; проверяется до подмены, удаляется после установки | Данные |
| `data\update-old-<guid>\` | Прежние версии трёх файлов GUI; основной источник автоотката | Данные |
| `data\backup-<версия>-<yyyyMMdd-HHmmss>\` | Резервные копии трёх файлов GUI + манифест `backup.json` (SHA-256 каждого файла); хранятся три последних | Данные |

## Слои

```
Пользователь
    ↓ (клики по сайдбару/кнопкам)
ZapretControl.ps1  — страницы, обработчики, действия, таймеры (WPF окно)
    ↓ (WPF, PresentationFramework)
Экран / журнал / трей-подобная иконка отсутствует — одно окно
    ↓
ZapretCommon.ps1   — пути, стратегии, служба, IPSet, загрузки, версии
    ↓
Папка zapret (service.bat, bin\winws.exe, lists\, utils\)  — управление zapret-discord-youtube (Flowseal)
    ↓
GitHub API (релизы zapret и zapret-gui, ipset-service.txt, hosts)
```

## Поток запуска

```
Запуск ZapretControl.bat
    ↓
powershell.exe -Sta -File ZapretControl.ps1
    ↓
UAC: если не администратор и не -Preview — перезапуск с Verb RunAs
    ↓
Подгрузка ZapretCommon.ps1; загрузка data\config.json (папка, стратегия, тема)
    ↓
Поиск папки zapret (подсказка из config.json → кандидаты рядом с GUI)
    ↓
Разбор XAML → окно 1200×820 (min 1000×640); обрезка под рабочую область −40 px,
                                                     не меньше 940×620
    ↓
Применение темы из config.json (Apply-Theme: кисти Window.Resources)
    ↓
Инициализация: список стратегий, настройки в UI, первый статус (Update-AllStatus)
    ↓
Таймеры (DispatcherTimer, UI-поток):
  MainTimer, 2 с  — Update-AllStatus + чтение журнала winws (Read-WinwsLog)
  StartupTimer, 0.9 с — проверка обновлений пакета и GUI при старте
    ↓
[Application.Run — цикл сообщений WPF до закрытия окна]
```

При закрытии окна таймеры останавливаются и `data\config.json` сохраняется.

## Транзакционное самообновление GUI

Заменяются три файла: `ZapretControl.ps1`, `ZapretCommon.ps1`, `ZapretControl.bat`
(список — `$script:ZC_GuiFiles` в `ZapretCommon.ps1`). Оркестратор —
`Install-GuiUpdateAction` в `ZapretControl.ps1`, механика подмены и отката —
в `ZapretCommon.ps1`.

```
Проверка обновления (Check-GuiUpdatesAction) → Install-GuiUpdateAction
    ↓
Скачивание zip в %TEMP%\zapret-gui-update-<guid> + сверка SHA-256 с digest GitHub
    ↓
Распаковка в data\update-staging-<guid>
    ↓
Валидация staging (Test-GuiUpdateStaging):
  - три файла на месте, синтаксис .ps1 парсером, формат .bat (ASCII/CRLF, без BOM)
  - версия ZC_AppVersion строго новее установленной
    ↓
Резервная копия (New-GuiUpdateBackup):
  data\backup-<версия>-<yyyyMMdd-HHmmss> + backup.json (SHA-256 каждого файла)
    ↓
Подмена (Invoke-GuiUpdateFileSwap): текущие файлы → data\update-old-<guid>,
                                    файлы из staging → на места
    ↓
Сверка SHA-256 на местах с архивом
    ↓
Успех → удаление staging и update-old, лимит бэкапов — 3 последних, перезапуск GUI
Сбой  → откат (Restore-GuiUpdateFiles): update-old, иначе последний backup-*,
         сверка по backup.json; приложение не перезапускается
```

## Правила будущих правок

1. **Один писатель в XAML.** Разметка окна существует только в блоке `$windowXaml = @' ... '@` внутри `ZapretControl.ps1`. Внешние скрипты и инструменты не содержат альтернативной разметки — правки вносятся в одном месте.
2. **Цвета — через `DynamicResource`.** Стили ссылаются на `{DynamicResource Ink}` и т.д.; `Apply-Theme` заменяет кисти в `Window.Resources`, поэтому смена темы не пересоздаёт окно. Новые цвета добавляются в палитры `$script:Themes` (light/dark/neon) и в `Set-ThemeBrushVars`.
3. **Элементы — через `Get-Ui` / `x:Name`.** Каждый управляющий элемент имеет `x:Name` и извлекается `$script:Window.FindName($Name)` функцией `Get-Ui`. Обработчики вешаются на `$script:BtnXxx.Add_Click(...)` (или `Add_Checked`/`Add_SelectionChanged`) после парсинга XAML.
4. **Все `.ps1` — UTF-8 с BOM.** PowerShell 5.1 без BOM прочитает русский текст как ANSI. CI проверяет BOM и корректность UTF-8 (`.github/workflows/ci.yml`, job `validate`, шаг «Кодировка UTF-8 с BOM»).
5. **PowerShell 5.1 совместимость.** Каждый скрипт начинается с `#Requires -Version 5.1`; конструкции должны компилироваться парсером Windows PowerShell 5.1 (jobs `validate` на `pwsh` и `validate-51` на `powershell`).
6. **UI-поток не блокировать.** Долгие операции (скачивание, установка службы, диагностика) выполняются через `Invoke-UiSafe` с `Set-BusyStatus`; обновление статуса только по таймеру (2 с), никогда внутри обработчиков кликов.

## Связанные документы

- `README.md` — установка, возможности, разделы интерфейса, часто problèmes.
- `CHANGELOG.md` — история версий и секция `Unreleased`.
- `BUGS.md` — известные проблемы, подтверждённые кодом.
- `ROADMAP.md` — выполнено и бэклог.
