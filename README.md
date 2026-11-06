# Remnacust Installer

[Русский](README.md) · [English](README.en.md)

Установка, обновление, перенос и обслуживание панели, ноды и сайта подписки Remnacust. Скрипт скачивает готовые Docker-образы: компиляция на VPS не требуется. Действия доступны через меню и именованные команды.

[Установка](#установка) · [Требования](#требования) · [Команды](#команды) · [Подробные параметры](installer/README.md)

## Где находятся файлы

| Компонент | Рабочий каталог |
| --- | --- |
| Панель | `/opt/remnacust/panel` |
| Нода | `/opt/remnacust/node` |
| Основной сайт подписки | `/opt/remnacust/subscription-page` |

Внутри находятся `.env` и `docker-compose.yml`. Для дополнительных сайтов используются отдельные постоянные каталоги и ID. Сначала выполните `cat /opt/remnacust/FILES.txt`: явно выбранный внешний путь может отличаться.

```bash
cd /opt/remnacust/panel
ls -la
nano .env
docker compose config --quiet
docker compose up -d --no-build --pull never
```

`restart` не перечитывает `.env`. Не создавайте новый пустой файл в `/opt/remnacust`; сохраняйте исходный `APP_SECRET`, реквизиты БД и ключ ноды. Копии находятся в `backups/`, журналы — в `logs/`.

Старую структуру можно привести к постоянным путям через `sudo remnacust normalize-layout --component panel` или `--component node`. `cleanup-backups` переносит распознанные старые копии конфигурации в каталог резервирования, а не удаляет все резервные копии БД.

## Стабильный комплект

Сверено **6 ноября 2026 года**:

| Компонент | Версия |
| --- | --- |
| [Установщик / Docker-комплект](https://github.com/lottman/Remnacust-installer/releases/tag/v1.2.138) | 1.2.138 |
| [Панель / сайт подписки](https://github.com/lottman/Remnacust-panel/releases/tag/v1.1.7.99) | 1.1.7.99 |
| [Node](https://github.com/lottman/Remnacust-node/releases/tag/v1.1.24) | 1.1.24 |
| [Core / редактор](https://github.com/lottman/Remnacust-core/releases/tag/v1.1.15) | 1.1.15, Xray v26.10.31 |

Номер установщика не является номером панели. Обновление одного компонента не заменяет остальные автоматически. Закреплённые исходники: [component-sources.json](component-sources.json). Обновление README не создаёт новую версию приложения.

## Требования

| Что | Минимум или ориентир |
| --- | --- |
| ОС установщика 1.2.138 | Ubuntu 22.04 / 24.04 / 26.04 LTS; Debian 12 / 13 |
| Архитектура | Linux amd64 или arm64 |
| Панель с БД и кешем | От 2 CPU, 2 GiB RAM, 20 GiB диска; рекомендуется 4 CPU / 4 GiB RAM и запас под копии |
| Нода | От 1 CPU / 1 GiB RAM с запасом под соединения и правила Xray |
| Отдельный сайт подписки | Начальный ориентир 1 CPU / 1 GiB RAM; точный минимум не измерялся |
| Права и сеть | Root, рабочий DNS, доступ к APT, GitHub и GHCR |
| Контейнеры | Docker Engine и актуальный Compose v2; старый `docker-compose` v1 не подходит |

Ресурсы — отправная точка, а не гарантия числа клиентов. При совместном размещении учитывайте все компоненты. [Требования Remnawave](https://docs.rw/install/requirements/).

При отсутствии Docker установщик добавляет официальный репозиторий своей ОС. Установленный daemon сохраняется. Отдельный минимальный номер Engine/Compose minor не проверен: используйте актуальные пакеты. Node.js и Go на VPS для готовых образов не нужны; для разработки используются Node.js 24 и Go 1.27.3 для Core.

В текущих исходниках панели проверены PostgreSQL 14–18. Это матрица следующего обновления, а не обещание проверки каждого прежнего выпуска. PostgreSQL 14 заканчивает поддержку 12 ноября 2026 года. Установщик сохраняет существующую major-версию БД; смена major требует отдельного переноса. [Совместимость БД](docs/DATABASE-COMPATIBILITY.md).

## Установка

Подготовьте домен и его DNS-записи. Для подписок нужен отдельный публичный адрес. Сохраните SSH-доступ; API, БД и кеш не должны быть открыты всему интернету.

```bash
curl -fsSL --proto '=https' --proto-redir '=https' \
  https://github.com/lottman/Remnacust-installer/releases/latest/download/installer.sh \
  -o installer.sh
sudo bash installer.sh
```

Либо сразу выберите действие:

```bash
sudo bash installer.sh install-panel --version 1.2.138
sudo bash installer.sh install-node --version 1.2.138
sudo bash installer.sh install-subscription-page --version 1.2.138
```

Панель отдельно спрашивает, устанавливать ли сайт подписки. Обязательные пустые поля запрашиваются повторно; после домена показывается подтверждение с default `y`. Для автоматизации указывайте все обязательные параметры, `--yes` и явный выбор `--subscription-page` / `--no-subscription-page`. Свой reverse proxy: `--proxy existing`.

Сайт может использовать локальную или удалённую панель. Её адрес задаётся через `--panel-url`, токен вводится скрыто или читается из файла `--panel-token-file` с правами `0600`. Выбирайте токен с правами страницы подписки, а не полным доступом. Адрес backend и токен не должны попадать в публичные ссылки клиента.

## Команды

После установки используйте `sudo remnacust КОМАНДА`.

| Задача | Команды |
| --- | --- |
| Установка | `install-panel`, `install-node`, `install-subscription-page` |
| Обновление | `upgrade-panel`, `upgrade-node`, `upgrade-subscription-page --page-id ID` |
| Меню управления | `manage-panel`, `manage-node`, `manage-subscription-page` |
| Сайт: адрес панели / токен | `configure-subscription-page --page-id ID --panel-url URL` |
| Домен / настройки | `change-domain --component COMPONENT`, `show-config --component COMPONENT` |
| Состояние / журналы | `status`, `logs` с `--component panel\|node\|subscription-page` |
| Запуск / остановка | `start`, `stop`, `restart` с `--component` |
| Резервные копии | `backup-panel`, `restore-panel --backup PATH` |
| Перенос | `migrate-remnawave-panel`, `migrate-remnawave-node`, `migrate-marzban-panel` |
| Удаление | `uninstall-panel`, `uninstall-node`, `uninstall-subscription-page --page-id ID` |
| Файлы / старые копии | `normalize-layout --component panel\|node`, `cleanup-backups` |
| Проверка / помощь | `--check-release`, `check-panel`, `--help` |

Удаление сохраняет данные, тома, настройки и копии. Страница удаляется по ID; другие компоненты не удаляются вместе с ней. Номера меню могут меняться — для автоматизации используйте названия команд.

## Системные пакеты и сертификаты

Действия CLI сначала обновляют список пакетов и выполняют `apt-get upgrade -y --with-new-pkgs`, кроме проверки выпуска `--check-release` и фонового обновления панели её службой. Подтверждение APT автоматическое; вопросы dpkg о конфигурации, раскладке или перезапуске служб остаются оператору. `--yes` не выбирает эти настройки. Меню, справка, выход и `--dry-run` пакеты не меняют.

Фоновое обновление панели не блокируется новыми системными пакетами: оно обновляет приложение, а обслуживание ОС откладывает до SSH с записью в журнале. Для остальных команд без терминала изменение пакетов по-прежнему требует SSH. Скрипт сам сервер не перезагружает, но пакеты могут перезапускать службы. Новое ядро Linux начинает работать после отдельной перезагрузки. Установленному старому агенту 1.2.137 потребуется разовое обновление установщика через SSH для получения этого исправления.

DNS, занятые порты и выбранный HTTPS-сценарий проверяются перед применением. Сторонние proxy и настройки CDN автоматически не переделываются. Обновление Docker-образа не исправляет ядро Linux хоста. До подтверждения исправлений дистрибутива не включайте MPTCP вручную. [Сопровождение](docs/INSTALLER.md).

## Обновление и перенос

```bash
sudo remnacust upgrade-panel
sudo remnacust upgrade-node
sudo remnacust upgrade-subscription-page --page-id ID
```

Перед заменой сохраняются конфигурация и согласованная копия БД. Сохраняйте прежний `APP_SECRET`, ключ ноды, подключения и постоянные каталоги. Для ноды проверяется совместимость нового образа с сохранённым состоянием. Обновление агента может сохранять ранее выбранное управляемое Core — проверяйте фактически запущенную версию.

Перенос старой страницы Remnawave предлагается отдельно; сайт, уже использующий Remnacust, не должен повторно предлагаться как сторонний. Перенос Marzban выполняется через API и не означает запуск его БД как БД Remnacust. Любой перенос сначала проверяйте на копии данных. [Перенос пользователей](https://github.com/lottman/Remnacust-panel/blob/main/docs/USER-MIGRATION.md).

## Где смотреть ошибку

CLI сохраняет `/opt/remnacust/logs/installer-panel.log`, `installer-node.log`, `installer-subscription-page.log`. Следующее действие того же компонента заменяет его журнал; диагностика использует `installer-diagnostics.log`. Параллельный запуск не затирает активный журнал. При ошибке выводятся путь и команда просмотра.

Обновление панели сохраняет `panel-update-<ID>.log`, управление сайтом — `page-<ID страницы>-<ID задачи>.log`, SSH-обслуживание ноды — `node-maintenance.log` на ноде. Каталог и журналы закрыты правами `0700`/`0600`. Не публикуйте их через proxy.

Для обновления из панели нужна локальная systemd-служба управления. Если её нет, используйте CLI. API-токен не заменяет право администратора на обновление. [Параметры и диагностика](installer/README.md).

## Копии и восстановление

```bash
sudo remnacust backup-panel
sudo remnacust restore-panel --backup /opt/remnacust/backups/panel-DATE-ID
```

Восстановление сохраняет установленную версию приложения и возвращает БД с её `APP_SECRET`. Старые PostgreSQL/Valkey/Compose из копии автоматически не запускаются. Приватное состояние нод также нужно сохранять. Встроенный ZIP панели содержит зашифрованный сжатый PostgreSQL dump; это не обычный SQL-текст. [Резервные копии](https://github.com/lottman/Remnacust-panel/blob/main/docs/BACKUPS.md).

## Документация и поддержка

[Параметры CLI](installer/README.md) · [Установка и обслуживание](docs/INSTALLER.md) · [Панель](https://github.com/lottman/Remnacust-panel) · [Нода](https://github.com/lottman/Remnacust-node) · [Core](https://github.com/lottman/Remnacust-core).

Поддержка Debian 12/13 доступна с установщика 1.2.137; используется официальный Docker-репозиторий своей ОС. [Изменения текущего выпуска](docs/releases/1.2.138.md) · [Разработка и публикация](docs/PUBLISHING.md). Изменения README не запускают обновление серверов.

Сохраняются лицензии и авторство компонентов. [LICENSE](LICENSE) · [NOTICE.md](NOTICE.md) · [Поддержка проекта](https://t.me/lottman).
