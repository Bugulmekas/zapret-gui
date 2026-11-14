<!-- neon:header:start -->
<p align="center">
  <img src="assets/neon-header.svg" alt="Zapret Control" width="100%">
</p>
<!-- neon:header:end -->

<p align="center">
  <a href="https://github.com/Bugulmekas/zapret-gui/releases/latest">
    <img src="https://img.shields.io/github/v/release/Bugulmekas/zapret-gui?style=for-the-badge&labelColor=0D1117&color=00F5FF&logo=github&logoColor=00F5FF" alt="Последний релиз">
  </a>
  <a href="https://github.com/Bugulmekas/zapret-gui/releases">
    <img src="https://img.shields.io/github/downloads/Bugulmekas/zapret-gui/total?style=for-the-badge&labelColor=0D1117&color=7A5CFF&logo=github&logoColor=7A5CFF" alt="Скачивания">
  </a>
  <a href="https://github.com/Bugulmekas/zapret-gui/actions/workflows/ci.yml">
    <img src="https://img.shields.io/github/actions/workflow/status/Bugulmekas/zapret-gui/ci.yml?style=for-the-badge&label=CI&labelColor=0D1117&color=00F5FF&logo=githubactions&logoColor=00F5FF" alt="CI">
  </a>
  <a href="LICENSE">
    <img src="https://img.shields.io/github/license/Bugulmekas/zapret-gui?style=for-the-badge&labelColor=0D1117&color=7A5CFF&logo=opensourceinitiative&logoColor=7A5CFF" alt="Лицензия">
  </a>
  <img src="https://img.shields.io/badge/Windows_10%2F11-0D1117?style=for-the-badge&logo=windows11&logoColor=00F5FF" alt="Платформа">
  <img src="https://img.shields.io/badge/PowerShell_5.1-0D1117?style=for-the-badge&logo=powershell&logoColor=00F5FF" alt="PowerShell 5.1">
</p>

<p align="center">
  <img src="docs/screenshot.png" alt="Zapret Control — главное окно" width="920">
</p>

<p align="center">
  <sub>Скриншот относится к версии 1.3.0: в актуальной сборке навигация вынесена в левый сайдбар, а журнал — нижняя раскрывающаяся панель.</sub>
</p>

**Zapret Control** — графический управлятор для пакета [zapret-discord-youtube](https://github.com/Flowseal/zapret-discord-youtube) от **Flowseal**.

Переносит в удобное окно всё управление из `service.bat`: установку и удаление службы, стратегии, игровой фильтр, IPSet, диагностику, обновление списков. Добавляет запуск стратегий без службы, тест стратегий, предупреждение о конфликте с VPN и автообновление пакета и самого GUI прямо с GitHub.

- **GUI / форк:** Bugulmek
- **Пакет zapret и источник обновлений:** Flowseal
- **Интерфейс:** WPF + XAML, сайдбар с пятью разделами; три темы (светлая, тёмная по умолчанию, «Неон») переключаются в «Настройки» → «Оформление»
- **Платформа:** Windows 10/11, PowerShell 5.1, .NET Framework 4.8 (входит в Windows)
- **Права:** требуются администратор (запрашиваются автоматически)

<p align="center">
  <a href="https://github.com/Bugulmekas/zapret-gui/releases/latest">
    <img src="https://img.shields.io/badge/%E2%AC%87_%D0%A1%D0%BA%D0%B0%D1%87%D0%B0%D1%82%D1%8C-1.3.0-FF2BD6?style=for-the-badge&labelColor=0D1117&logo=github&logoColor=white" alt="Скачать">
  </a>
</p>

---

## Возможности

Интерфейс — одно окно с сайдбаром из пяти разделов: **Обзор**, **Настройки**, **Инструменты**, **Тесты**, **Обновление**. Внизу окна всегда доступна панель журнала.

| Раздел | Что умеет |
|---|---|
| **Обзор** | Карточка состояния: режим zapret, кнопки **«Запустить»** и **«Остановить»**, стратегия службы, IPSet, WinDivert. Встроенный список стратегий (`general*.bat`, кроме `service.bat`), двойной клик — быстрый запуск. Карточка «Служба Windows»: установка, удаление, запуск, остановка, перезапуск, автозапуск при старте Windows |
| **Настройки** | Игровой фильтр (выключен / TCP и UDP / только TCP / только UDP, произвольные диапазоны портов), режимы IPSet `any` / `none` / `loaded` с обновлением списка, открытие пользовательских списков, встроенная автопроверка обновлений `.bat`, переключатель тем |
| **Инструменты** | Обновление IPSet и `hosts`, диагностика, замена active fake, очистка кэша Discord, удаление конфликтного WinDivert, папка данных, меню `service.bat`, выбор папки zapret |
| **Тесты** | Запуск штатного `utils\test zapret.ps1` — тот же тест, что пункт 12 `service.bat`; быстрая проверка соединения (Discord, YouTube, Google, Cloudflare) |
| **Обновление** | Проверка релизов пакета через GitHub API, скачивание, распаковка в новую папку, перенос списков и переустановка службы; отдельная карточка самообновления GUI; описание релиза с GitHub |
| **Журнал** | Нижняя раскрывающаяся панель: вывод `winws.exe` в реальном времени, автопрокрутка, сохранение в файл и очистка |

Диагностика в «Инструменты» → «Диагностика» проверяет BFE, прокси, Adguard, Killer, Intel Connectivity, Check Point, SmartByte, VPN и прокси-клиенты, DoH, WinDivert и конфликтующие службы.

## Установка

1. Скачайте последний архив со страницы **[Releases](https://github.com/Bugulmekas/zapret-gui/releases/latest)**.
2. Распакуйте его рядом с папкой zapret так, чтобы структура была такой:

```
F:\zapret\
├─ zapret-gui-1.3.0\              ← эта программа
│  ├─ ZapretControl.bat
│  ├─ ZapretControl.ps1
│  └─ ZapretCommon.ps1
└─ zapret-discord-youtube-1.10.x\
   ├─ service.bat
   ├─ bin\winws.exe
   └─ lists\ ...
```

3. Запустите **`ZapretControl.bat`** и разрешите запрос UAC.
4. В разделе **«Обзор»** выберите стратегию в списке и нажмите **«Запустить»** (без службы) или **«Установить службу»** в карточке «Служба Windows».

Если папка zapret лежит в другом месте, укажите её через **«Инструменты» → «Выбрать папку zapret»**.

> Папка GUI может называться как угодно — программа сама находит `zapret-discord-youtube-*` рядом с собой.

## Скриншоты

<p align="center">
  <img src="docs/screenshot.png" alt="Главное окно" width="900">
</p>

<p align="center">
  <sub>Скриншот относится к версии 1.3.0 — до переноса навигации в сайдбар.</sub>
</p>

## Как это работает

### Интерфейс

Окно собрано на WPF: собственный XAML, стили и контролы, без сторонних библиотек. Слева — сайдбар шириной 216 px с пятью разделами: **Обзор**, **Настройки**, **Инструменты**, **Тесты**, **Обновление**; внизу сайдбара — «О программе» и версия. Справа — содержимое выбранного раздела; страницы переключаются видимостью, без пересоздания окна.

«Обзор» — карточка состояния: режим zapret, кнопки **«Запустить»** и **«Остановить»**, три показателя (стратегия службы, IPSet, WinDivert), список стратегий с двойным кликом и карточка «Служба Windows». «Настройки» — игровой фильтр, IPSet, пользовательские списки, автопроверка `.bat` и переключатель тем. «Инструменты» — девять сервисных кнопок. «Тесты» — штатный тест стратегий и быстрая проверка соединения. «Обновление» — карточки пакета и GUI, а также описание релиза.

Журнал — нижняя раскрывающаяся панель с кнопкой «Развернуть»/«Свернуть», автопрокруткой, сохранением и очисткой. Строка состояния внизу показывает текущее действие.

Темы — **светлая**, **тёмная** (по умолчанию) и **«Неон»** — переключаются в «Настройки» → «Оформление», применяются на лету и сохраняются в `data\config.json`; журнал, плашки и индикаторы перекрашиваются вместе с интерфейсом.

Окно открывается в размере 1200×820, минимум — 1000×640. При старте размер ограничивается рабочей областью минус 40 px по каждой стороне (но не меньше 940×620), поэтому окно помещается на 1366×768 и при High-DPI.

Состояние обновляется каждые две секунды: режим zapret, `winws.exe`, стратегия службы, IPSet, драйвер WinDivert; версия пакета выводится в подзаголовке шапки.

Если запущен VPN или прокси-клиент (Happ, sing-box, xray, OpenVPN, WireGuard, Tailscale, NordVPN и другие), в шапке появляется оранжевая плашка **«VPN активен»**, а перед запуском стратегии или службы GUI предупреждает: VPN и zapret вместе обычно отключают интернет.

### Запуск без службы

Кнопка **«Запустить»** читает строку `winws.exe` из выбранного `general*.bat`, подставляет `%BIN%`, `%LISTS%`, `%GameFilterTCP%` и `%GameFilterUDP%`, создаёт временный `data\run-current.bat` и запускает `winws.exe` скрыто. Вывод пишется в журнал.

### Служба Windows

Кнопка **«Установить службу»** создаёт службу `zapret` с аргументами выбранной стратегии и автозапуском — так же, как это делает `service.bat`. Текущая стратегия записывается в реестр и показывается в статусе.

Кнопки **«Запустить службу»** и **«Остановить службу»** управляют уже установленной службой без переустановки. Перед запуском удаляются осиротевшие `winws.exe` и служба драйвера WinDivert, а успехом считается только стабильная работа около пяти секунд — так служба не «считается запущенной», если `winws.exe` сразу упал.

### Обновление пакета

GUI проверяет последний релиз через GitHub API, скачивает zip-архив и распаковывает его **в новую папку рядом**:

```
F:\zapret\zapret-discord-youtube-1.10.4\
```

Пользовательские данные переносятся:

- `lists\list-general-user.txt`
- `lists\list-exclude-user.txt`
- `lists\ipset-exclude-user.txt`
- `lists\ipset-all.txt` и `.backup`
- `utils\game_filter.enabled`
- `utils\check_updates.enabled`

После обновления GUI переключается на новую папку и при необходимости переустанавливает службу. Старую папку можно удалить вручную.

### Обновление GUI

На странице «Обновление» есть отдельная карточка самообновления. GUI проверяет последний релиз `Bugulmekas/zapret-gui`, скачивает zip-архив, проверяет синтаксис скриптов и совпадение версии, делает резервную копию в `data\backup-<версия>` и заменяет `ZapretControl.ps1`, `ZapretCommon.ps1` и `ZapretControl.bat`. Настройки в `data\config.json` сохраняются, после установки приложение перезапускается само. Проверка обновлений GUI выполняется и при старте, если включена авто-проверка.

## Данные программы

Служебные файлы лежат в `data\` и не попадают в git:

| Файл | Назначение |
|---|---|
| `config.json` | папка zapret, выбранная стратегия, последняя запущенная стратегия, тема, авто-проверка обновлений |
| `winws.log` | вывод `winws.exe` при ручном запуске |
| `run-current.bat` | временный файл запуска |
| `ipset-new.txt` | временный файл обновления IPSet |
| `backup-<версия>\` | резервная копия скриптов перед самообновлением GUI |

## Диагностика

```powershell
# Проверка без запуска окна: папка, версия, IPSet, игровой фильтр, стратегии, аргументы
powershell -NoProfile -ExecutionPolicy Bypass -File .\ZapretControl.ps1 -SelfTest

# Открыть окно на 5 секунд и закрыть (проверка сборки интерфейса)
powershell -NoProfile -ExecutionPolicy Bypass -File .\ZapretControl.ps1 -Preview -PreviewSeconds 5
```

## Частые проблемы

| Проблема | Решение |
|---|---|
| «Не удалось найти папку zapret» | Положите программу рядом с `zapret-discord-youtube-*` или укажите папку через «Инструменты» → «Выбрать папку zapret» |
| Интернет пропадает после запуска zapret | Выключите VPN или прокси-клиент: Happ, sing-box, xray, OpenVPN, WireGuard и подобные конфликтуют с zapret. В шапке при этом горит плашка «VPN активен» |
| `winws.exe` не запускается | «Инструменты» → «Диагностика», проверьте журнал. Частые причины: занят WinDivert, блокирует антивирус, повреждена папка `bin` |
| Служба не устанавливается | Запустите от имени администратора, проверьте `bin\winws.exe`, попробуйте «Меню service.bat» |
| Служба показывает «остановлена» | Если `winws.exe` завершили вручную (например, через диспетчер задач), служба остановится: это нормально. Запустите её кнопкой «Запустить службу» |
| После обновления не работает zapret | Убедитесь, что GUI переключился на новую папку, при необходимости переустановите службу |
| Тест стратегий не запускается | Удалите службу и остановите `winws.exe` — тест не работает одновременно со службой |
| Служба и ручной запуск конфликтуют | Это нормально: одновременно должен работать только один экземпляр zapret |

## Разработка

```
ZapretControl.ps1    основной скрипт: XAML-разметка, стили, темы, страницы, обработчики, таймеры
ZapretCommon.ps1     общие функции: пути, стратегии, служба, IPSet, загрузки с GitHub
ZapretControl.bat    запуск через powershell.exe -Sta
tools\               проверки интерфейса (Test-Xaml, Test-UiSmoke, Capture-UiPreview, Test-Contrast, Test-ZipSlip)
docs\                скриншоты и карта архитектуры
assets\              неоновые баннер и футер для README
```

Подробная карта файлов, слоёв и потока запуска — в [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

Интерфейс — WPF (`PresentationFramework`), поэтому запуск идёт через `powershell.exe -Sta`. Стили лежат в `Window.Resources`, страницы — обычные `StackPanel` (`PageService`, `PageSettings`, `PageTools`, `PageTests`, `PageUpdate`), видимость переключает `Show-NavPage` по тегу `RadioButton` из сайдбара. Диалоги свои, в том же стиле, вместо `MessageBox`.

Файлы `.ps1` должны быть в **UTF-8 с BOM** — иначе PowerShell 5.1 прочитает русский текст как ANSI.

Проверка синтаксиса, обязательных файлов и BOM выполняется в CI (`.github/workflows/ci.yml`) на каждый push и pull request. Автотестов (Pester) в CI пока нет; локальные проверки интерфейса — скрипты в `tools\`, их прогоны в CI ещё не подключены.

## Благодарности

- **[Flowseal](https://github.com/Flowseal/zapret-discord-youtube)** — пакет zapret-discord-youtube и скрипты управления. Проект собрал более 36 000 звёзд на GitHub.
- **Bugulmek** — графический интерфейс и автообновление.

Проект не связан с разработчиками zapret и Discord. Используйте на свой риск.

## Лицензия

[MIT](LICENSE) © 2026 Bugulmek

Пакет zapret-discord-youtube не входит в репозиторий и распространяется отдельно — подробности в [NOTICE.md](NOTICE.md).

<p align="center">
  Если программа оказалась полезной — поставьте ⭐ репозиторию.
</p>
<!-- neon:footer:start -->
<p align="center">
  <img src="assets/neon-footer.svg" alt="Bugulmek" width="100%">
</p>
<!-- neon:footer:end -->