# Проверка установщика

Нужны Bash, Python 3, Node.js 24 и Docker Engine с Compose v2 для интеграционных проверок. Быстрые тесты не устанавливают приложение и не требуют рабочих ключей:

```bash
bash -n installer/installer.sh
bash tests/installer.test.sh
bash tests/database-repair.test.sh
python3 tests/package-release.test.py
```

Docker-сценарии находятся в `installer/tests`: они проверяют новую панель, ноду, обновление, перенос, состояние служб и конфигурацию proxy. Запускайте их на отдельном стенде; параметры описаны в самих скриптах.

Архив установщика объединяет отмеченные коммиты трёх других репозиториев. Это сохраняет совместимые версии и пути Docker-сборки. Порядок подготовки: [PUBLISHING.md](PUBLISHING.md).
