# Установщик Remnacust

`installer.sh` устанавливает, обновляет и обслуживает панель и ноду. Требуются Ubuntu 22.04, 24.04 или 26.04 LTS и root-доступ. Сервер скачивает готовые Docker-образы; сборка на сервере не нужна.

Чтобы скачать скрипт и открыть меню:

```bash
curl -fsSL --proto '=https' --proto-redir '=https' https://github.com/lottman/Remnacust-installer/releases/latest/download/installer.sh -o installer.sh && sudo bash installer.sh
```

Команду можно передать сразу:

```bash
sudo bash installer.sh install-panel
sudo bash installer.sh install-node --port 2222
sudo bash installer.sh upgrade-panel
sudo bash installer.sh upgrade-node
sudo bash installer.sh --help
```

API-порт новой ноды по умолчанию — `2222`. Укажите его вместе с адресом сервера в разделе «Ноды» панели. Скрипт проверяет диапазон и занятость порта. Обновление и миграция сохраняют фактический порт прежнего контейнера; `--port` доступен только при новой установке. SSH-порт не меняется.

`runtime.py` готовит Compose и проверяет состояние контейнеров. `database.cjs` проверяет совместимость БД и переносит её без изменения секретов. `marzban.py` готовит и выполняет перенос пользователей Marzban. `tests/` содержит проверки установщика.

Все команды, сертификаты, резервные копии, миграция и удаление описаны в [основном README](../README.md).
