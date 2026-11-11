#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
[[ ${1:-} != @ ]] || shift
[[ ${1:-} != install ]] || shift
directory=$(mktemp -d /tmp/remnacust-install.XXXXXXXX)
trap '[[ $directory == /tmp/remnacust-install.* ]] && rm -rf -- "$directory"' EXIT
cat > "$directory/installer.sh" <<'REMNACUST_INSTALLER_PAYLOAD_V1'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
export PYTHONDONTWRITEBYTECODE=1
HELPER_BUNDLE_SHA256='2420774d029c8d12d22a7b9e0de8ed1f87c39d9df5f05f86f04ac0897c20ff4f'
ENTRY_SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/${BASH_SOURCE[0]##*/}"
HELPER_ROOT='' HELPER_ENTRY='' INSTALLED_HELPER_ROOT=''

REPO=${REMNACUST_REPOSITORY:-lottman/Remnacust-installer}
ROOT=${REMNACUST_ROOT:-/opt/remnacust}
export REMNACUST_ROOT="$ROOT"
ACTION='' VERSION='' COMPONENT='' DIRECTORY='' COMPOSE_FILE='' CONTAINER=''
PAGE_ID='' PAGE_OPERATION='' PAGE_PANEL_URL='' PAGE_TOKEN_FILE=''
DOMAIN_PLAN=''
PROJECT='' DOMAIN=${REMNACUST_PANEL_DOMAIN:-} NODE_DOMAIN='' EMAIL='' PANEL_IP=''
SUBSCRIPTION_URLS=${REMNACUST_SUBSCRIPTION_URLS:-} SUBSCRIPTION_SET=false
SUBSCRIPTION_PAGE=false SUBSCRIPTION_PAGE_SET=false SUBSCRIPTION_PORT=3010 SUBSCRIPTION_IMAGE='' SUBSCRIPTION_IMAGE_VERSION=''
PANEL_NET_ADMIN=false PANEL_NET_ADMIN_SET=false
NODE_NET_ADMIN=false
NODE_NET_ADMIN_ADDED=false
NODE_DOMAIN_CONFIRMED=''
NODE_SITE_MODE='' NODE_SITE_PORT='' NODE_INBOUND_PORT=''
NODE_MIGRATION_TLS=false
ALLOW_DISRUPTION=false
PORT='' PROXY=caddy PROXY_SET=false TLS_METHOD='' CERT_FILE='' KEY_FILE='' DNS_CREDENTIALS='' ACME_ROOT='' CERTBOT='' YES=false WORK='' SOURCE='' HELPER='' LOG=''
STATE='' DEPLOY='' CHANGED=false BACKUP='' IMAGE='' TAG='' COMPONENT_VERSION=''
DB_CHANGED=false MARZBAN_URL='' DESTINATION_URL='' INTERNAL_SQUAD='' DRY_RUN=false
REINSTALL_RECORD=''
SERVER_IPS='' HTTPS_TIMEOUT=180
QUOTA_MODE=remaining PRESERVE_SUBHASH=false
declare -a FILES=() APPS=() START_APPS=() RUNNING_APPS=() EXTRAS=()
TEAL='' PURPLE='' ROSE='' DIM='' GRAY='' RESET=''
BOLD='' ACCENT=''
OPERATION_LOG_PID='' OPERATION_STDERR='' OPERATION_STARTED=0 OPERATION_LOG_ACTIVE=false
Y_LABEL=y N_LABEL=n
if [[ -t 1 && ${TERM:-dumb} != dumb && -z ${NO_COLOR:-} ]]; then
    TEAL=$'\033[38;2;25;190;160m'; PURPLE=$'\033[38;2;167;139;250m'
    ROSE=$'\033[38;2;239;128;153m'; DIM=$'\033[2m'; RESET=$'\033[0m'
    Y_LABEL=$'\033[1;32my\033[0m'; N_LABEL=$'\033[1;31mn\033[0m'
    BOLD=$'\033[1m'
    ACCENT=$'\033[38;2;231;111;122m'
    GRAY=$'\033[38;2;128;132;142m'
    PURPLE=$ACCENT
fi
info() { printf '%s  %s%s\n' "$TEAL" "$*" "$RESET"; operation_log_event INFO "$*"; }
die() { printf '%s  Ошибка: %s%s\n' "$ROSE" "$*" "$RESET" >&2; exit 1; }
ask() { local value display_default=${3:-${2:-}}; [[ -t 0 ]] || die "Задайте параметр: $1"; IFS= read -r -p "$1${2:+ [$display_default]}: " value || return 1; value=$(trim_answer "$value"); printf '%s' "${value:-${2:-}}"; }
ask_required() {
    local value
    while true; do
        value=$(ask "$1") || return $?
        if [[ -n $value ]]; then printf '%s' "$value"; return 0; fi
        printf '  ! пустой ответ, повторите ввод\n' >&2
    done
}
ask_node_secret() {
    [[ -t 0 ]] || die 'Задайте REMNACUST_NODE_SECRET или введите ключ интерактивно'
    REMNACUST_NODE_SECRET=$(ask_required 'SECRET_KEY из панели') || return 1
    export REMNACUST_NODE_SECRET
}
trim_answer() {
    local value=$1
    value=${value#"${value%%[![:space:]]*}"}; value=${value%"${value##*[![:space:]]}"}
    printf '%s' "$value"
}
discard_pending_input() {
    [[ -t 0 ]] || return 0
    if command -v python3 >/dev/null; then
        python3 -c 'import sys,termios; termios.tcflush(sys.stdin.fileno(),termios.TCIFLUSH)' 2>/dev/null || true
    else
        local discarded attempt
        for ((attempt=0; attempt<64; attempt++)); do IFS= read -r -t .01 -N 4096 discarded || break; done
    fi
}
ask_yes_no() {
    local answer default=${2:-n} display_default=$N_LABEL
    [[ $default == y || $default == n ]] || die 'Некорректный ответ по умолчанию'
    [[ $default != y ]] || display_default=$Y_LABEL
    while true; do
        answer=$(ask "$1 $Y_LABEL/$N_LABEL" "$default" "$display_default") || return $?
        answer=$(trim_answer "$answer")
        [[ -n $answer ]] || answer=$default
        # Literal Cyrillic alternatives also work with the byte-oriented C locale.
        case "${answer,,}" in
            y|yes|д|Д|да|Да|дА|ДА) printf yes; return 0;;
            n|no|н|Н|нет|Нет|нЕт|неТ|НЕт|НеТ|нЕТ|НЕТ) printf no; return 0;;
            *) printf '  Введите %s/%s.\n' "$Y_LABEL" "$N_LABEL" >&2; discard_pending_input;;
        esac
    done
}
ask_confirmed_domain() {
    local title=$1 value=${2:-} answer
    while true; do
        [[ -n $value ]] || value=$(ask_required "$title") || return $?
        value=$(trim_answer "$value")
        if ! helper validate --domain "$value" >/dev/null; then
            [[ -t 0 ]] && ! $YES || return 1
            value=''; continue
        fi
        if [[ -t 0 ]] && ! $YES; then
            answer=$(ask_yes_no "Использовать домен $value?" y) || return $?
            if [[ $answer != yes ]]; then value=''; continue; fi
        fi
        printf '%s' "${value,,}"; return 0
    done
}
ask_menu_choice() {
    local answer maximum=$1
    while true; do
        answer=$(ask 'Действие') || return $?
        answer=$(trim_answer "$answer")
        if [[ $answer =~ ^[0-9]{1,2}$ ]] && ((10#$answer<=maximum)); then printf '%s' "$((10#$answer))"; return 0; fi
        printf '  Выберите номер от 0 до %s.\n' "$maximum" >&2
        discard_pending_input
    done
}
valid_version() { [[ $1 == latest || $1 =~ ^v?[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9]+([.-][A-Za-z0-9]+)*)?$ ]]; }
download() { curl --fail --show-error --silent --location --retry 3 --connect-timeout 15 --max-time 600 --proto '=https' --proto-redir '=https' --tlsv1.2 "$1" -o "$2"; }
usage() {
    cat <<'HELP'
Remnacust · installer.sh
  sudo bash installer.sh
  sudo bash installer.sh COMMAND [--version latest|1.2.24] [--yes]

  install-panel             Установить панель: Docker, БД, кеш, HTTPS
  normalize-layout          Постоянный каталог панели/ноды (--component panel|node)
  cleanup-backups           Убрать старые копии конфигов в backups (все компоненты)
  install-subscription-page Установить страницу подписки
  upgrade-subscription-page Обновить выбранную страницу подписки
  manage-subscription-page  Список, запуск, остановка или перезапуск страниц
  configure-subscription-page Сменить панель и API-токен выбранной страницы
  manage-panel | manage-node Меню управления установленной панелью или нодой
  change-domain             Сменить домен --component panel|node|subscription-page
  show-config               Показать адреса и пути настроек без секретов
  install-node              Установить ноду и Xray; TLS/XHTTP по желанию
  upgrade-panel             Все процессы панели; БД и настройки сохраняются
  upgrade-node              Полное обновление ноды и встроенного Xray
  uninstall-panel           Удалить контейнеры панели; сохранить данные и копии
  uninstall-node            Удалить контейнеры ноды; сохранить конфигурацию
  uninstall-subscription-page Удалить выбранную страницу; сохранить настройки и данные
  migrate-remnawave-panel    Переход существующей панели на Remnacust
  migrate-remnawave-node     Переход существующей ноды на Remnacust
  migrate-remnawave-subscription-page Перенос страницы подписки с сохранением настроек
  migrate-marzban-panel      Перенос пользователей Marzban через API
  --check-release           Скачать и проверить выпуск без установки
  status                    Состояние установленных компонентов
  check-panel               Проверить DNS и HTTPS без изменения установки
  logs                      Журнал приложения, последние 100 строк
  start | stop | restart    Управление процессами приложения
  backup-panel              Копия БД и конфигурации панели
  restore-panel             Данные и ключи из копии; текущая версия сохраняется
  renew-node-certificate    Копирование обновлённого TLS и перезапуск ноды
  configure-node-site       Случайный новый сайт selfsteal; прежний сохраняется в копии
  renew-panel-certificate   Копирование обновлённого TLS и reload Caddy
  --help, -h                Эта справка

  --page-id ID              ID зарегистрированной страницы (из списка)
  --page-operation ACTION   list, status, logs, start, stop или restart
  --panel-url URL           HTTPS панели; auto для панели на этом сервере
  --panel-token-file FILE   Файл API-токена страницы с правами 0600
  --component COMPONENT    panel, node или subscription-page для управления
  --directory PATH          Каталог существующей установки
  --compose-file PATH       Основной Compose-файл при миграции
  --container NAME          Контейнер приложения при миграции
  --project-name NAME       Имя новой установки Compose
  --domain DOMAIN           Домен установки / новый домен для change-domain
  --net-admin               Добавить NET_ADMIN новой панели или устанавливаемой/обновляемой ноде
  --node-site-mode          standalone (отдельный HTTPS) или selfsteal (сокет за Xray)
  --node-site-port          Порт отдельного HTTPS-сайта (по умолчанию 443)
  --node-inbound-port       Порт входа Xray для настройки профиля панели (по умолчанию 8443)
  --no-net-admin            Новая панель/нода без NET_ADMIN; при обновлении включённое право сохраняется
  --subscription-urls URLS  Один или два адреса сайта подписки через запятую; первый — основной
  --subscription-page       Установить сайт подписки / перенести найденный при миграции
  --no-subscription-page    Не устанавливать / не переносить существующий сайт подписки
  --subscription-port PORT Порт сайта на loopback для вашего reverse proxy (3010)
  --server-ip IP[,IP]        Публичные IP сервера для проверки A/AAAA (NAT)
  --port PORT               Порт панели на loopback / API ноды
  --proxy caddy|existing    Новый Caddy (по умолчанию) / собственный proxy
  --node-domain DOMAIN      TLS и Nginx для XHTTP/self-steal при установке или переносе ноды
  --email EMAIL             Email для регистрации ACME (панель и нода)
  --tls-method METHOD       auto (Caddy), http (нода), cloudflare, gcore, existing
  --cert-file PATH          Готовый fullchain.pem для --tls-method existing
  --key-file PATH           Его приватный ключ privkey.pem
  --dns-credentials PATH    Закрытый INI-файл выбранного DNS-провайдера
  --panel-ip IP[/CIDR]      Все входящие порты и ping только от панели, кроме SSH
  --backup PATH             Каталог копии для restore-panel
  --yes                     Пропустить подтверждение выбранного действия
  --allow-disruption        upgrade-panel: пропустить диагностику автономности нод
  --source-url URL          Адрес Marzban для переноса
  --destination-url URL     Адрес уже установленной панели Remnacust
  --internal-squad UUID     Внутренний сквад для перенесённых пользователей
  --quota-mode remaining|total  Остаток квоты / полная квота (см. README)
  --dry-run                 Отчёт Marzban без записи пользователей
  --preserve-subhash        Перенос короткого токена подписки, если совместим

Версия запрашивается перед установкой/обновлением/миграцией; Enter = latest.
Подтверждение: y/n; Enter = n. Регистр и пробелы не важны.
Перед действиями CLI: apt update -y и apt upgrade -y (кроме проверки выпуска и фонового обновления панели).
Продолжение APT подтверждается автоматически. На вопросы настройки пакетов отвечайте в SSH-терминале.
Без терминала изменение пакетов требует SSH; --yes не выбирает настройки пакетов.
Справка, меню, выход и --dry-run пакеты не изменяют. Автоматической перезагрузки сервера нет.
После удаления доступна только новая установка через install-panel/install-node.
Установка и обновление: Ubuntu 22.04 / 24.04 / 26.04 LTS, Debian 12 / 13; amd64 / arm64.
SECRET_KEY виден при вводе или задаётся через REMNACUST_NODE_SECRET. В журналы он не записывается.
Существующие APP_SECRET, SECRET_KEY, БД, сети и тома не пересоздаются.
Если панель подключена к нескольким сетям Docker, сеть БД выбирается по DATABASE_URL и работающему контейнеру базы. Для внешней БД без Docker-алиаса укажите REMNACUST_DATABASE_NETWORK; сеть должна быть подключена к панели.
Новая панель: REMNACUST_BACKUP_PASSWORD задаёт пароль копий (16–256 ASCII без пробелов).
Без него установщик спрашивает пароль; Enter или запуск без терминала создаёт его.
Пароль сохраняется в закрытом backup-password.txt и показывается после установки.
HELP
}
show_menu() {
    local panel_note='' node_note='' panel_upgrade='Не установлена' node_upgrade='Не установлена' page_upgrade='Не установлена'
    local panel_available=false node_available=false page_available=false panel_install=true node_install=true service_available=false service_note='Компоненты не установлены'
    if component_installed panel; then panel_available=true; panel_install=false; panel_note='Уже установлена. Обновить: пункт 4; удалить: пункт 15.'; panel_upgrade=''; fi
    if component_installed node; then node_available=true; node_install=false; node_note='Уже установлена. Обновить: пункт 5; удалить: пункт 16.'; node_upgrade=''; fi
    if subscription_page_installed; then page_available=true; page_upgrade=''; fi
    if $panel_available || $node_available || $page_available; then service_available=true; service_note=''; fi
    terminal_banner
    terminal_server_card
    terminal_section 'Установка'
    terminal_action 1 'Установить панель' install-panel "$panel_note" "$panel_install"
    terminal_action 2 'Установить ноду и Xray' install-node "$node_note" "$node_install"
    terminal_action 3 'Установить страницу подписки' install-subscription-page
    terminal_section 'Обновление'
    terminal_action 4 'Обновить панель' upgrade-panel "$panel_upgrade" "$panel_available"
    terminal_action 5 'Обновить ноду и Xray' upgrade-node "$node_upgrade" "$node_available"
    terminal_action 6 'Обновить страницу подписки' upgrade-subscription-page "$page_upgrade" "$page_available"
    terminal_section 'Перенос'
    terminal_action 7 'Панель из Remnawave' migrate-remnawave-panel
    terminal_action 8 'Нода из Remnawave' migrate-remnawave-node
    terminal_action 9 'Пользователи из Marzban' migrate-marzban-panel
    terminal_action 10 'Страница подписки из Remnawave' migrate-remnawave-subscription-page
    terminal_section 'Обслуживание'
    terminal_action 11 'Проверить выпуск' --check-release
    terminal_action 12 'Состояние компонентов' status
    terminal_action 13 'Управление компонентами' ''
    terminal_action 14 'Логи, запуск и резервные копии' '' "$service_note" "$service_available"
    terminal_section 'Удаление'
    terminal_text 'Данные, тома, настройки и резервные копии сохраняются.' '      ' '      ' "$DIM"
    terminal_action 15 'Удалить панель' uninstall-panel "$panel_upgrade" "$panel_available"
    terminal_action 16 'Удалить ноду' uninstall-node "$node_upgrade" "$node_available"
    terminal_action 17 'Удалить страницу подписки' uninstall-subscription-page "$page_upgrade" "$page_available"
    terminal_rule
    terminal_action 0 Выход ''
    printf '\n'
}
terminal_width() {
    local width=${COLUMNS:-}
    [[ $width =~ ^[0-9]{1,3}$ ]] || width=$(tput cols 2>/dev/null || printf 80)
    [[ $width =~ ^[0-9]{1,3}$ ]] || width=80
    ((width < 24)) && width=24
    ((width > 88)) && width=88
    printf '%s' "$width"
}
terminal_rule() {
    local width; width=$(terminal_width)
    printf '  %s' "$DIM"
    printf '%*s' "$((width-4))" '' | tr ' ' '-'
    printf '%s\n' "$RESET"
}
terminal_section() {
    printf '\n'
    terminal_text "$1" '  ' '  ' "$BOLD"
    terminal_rule
}
terminal_banner() {
    printf '\n  %s▂▄▆█▆▄▂%s  %sREMNACUST%s\n' "$ACCENT" "$RESET" "$BOLD" "$RESET"
    terminal_text 'Установка и обслуживание' '  ' '  ' "$DIM"
}
terminal_text() {
    local LC_ALL=C.UTF-8
    local text prefix=${2:-'  '} continuation=${3:-${2:-'  '}} color=${4:-} width available line
    text=$(printf '%s' "$1" | LC_ALL=C tr -d '\000-\037\177')
    width=$(terminal_width)
    while [[ -n $text ]]; do
        available=$((width-${#prefix}))
        ((available > 0)) || available=1
        if ((${#text} > available)); then
            line=${text:0:available}
            if [[ $line == *' '* ]]; then line=${line% *}; fi
        else line=$text; fi
        printf '%s%s%s%s\n' "$prefix" "$color" "$line" "$RESET"
        text=${text:${#line}}
        text=${text#"${text%%[![:space:]]*}"}
        prefix=$continuation
    done
}
terminal_value() {
    local LC_ALL=C.UTF-8
    local padding prefix
    if (($(terminal_width) >= 64)); then
        padding=$((14-${#1})); ((padding > 0)) || padding=1
        printf -v prefix '  %s%*s' "$1" "$padding" ''
        terminal_text "$2" "$prefix" '                ' "$BOLD"
    else
        terminal_text "$1: $2" '  ' '    '
    fi
}
terminal_server_card() {
    local system='Linux' memory='—' available='—' panel='не установлена' node='не установлена'
    [[ ! -r /etc/os-release ]] || system=$(sed -n 's/^PRETTY_NAME="\(.*\)"$/\1/p' /etc/os-release)
    [[ ! -r /proc/meminfo ]] || read -r memory available < <(awk '/^MemTotal:/ {total=$2} /^MemAvailable:/ {available=$2} END {printf "%.1f %.1f\n",total/1048576,available/1048576}' /proc/meminfo)
    component_installed panel && panel='установлена'
    component_installed node && node='установлена'
    printf '\n'
    terminal_value 'Система' "$system"
    terminal_value 'Архитектура' "$(uname -m) · $(uname -r)"
    terminal_value 'Память' "$memory GiB · доступно $available GiB"
    terminal_value 'Панель' "$panel"
    terminal_value 'Нода' "$node"
}
terminal_action() {
    local LC_ALL=C.UTF-8
    local number=$1 title=$2 command=${3:-} note=${4:-} available=${5:-true} number_color=$ACCENT padding width first remaining command_prefix='      '
    [[ $available != false ]] || number_color=$GRAY
    width=$(terminal_width)
    if ((width >= 74)); then
        padding=$((30-${#title})); ((padding > 0)) || padding=1
        printf '  %s%2s%s  %s%s%s' "$number_color" "$number" "$RESET" "$BOLD" "$title" "$RESET"
        [[ -z $command ]] || printf '%*s%s%s%s' "$padding" '' "$DIM" "$command" "$RESET"
        printf '\n'
    else
        first=$title
        if ((${#title} > width-6)); then
            first=${title:0:width-6}
            [[ $first != *' '* ]] || first=${first% *}
        fi
        printf '  %s%2s%s  %s%s%s\n' "$number_color" "$number" "$RESET" "$BOLD" "$first" "$RESET"
        remaining=${title:${#first}}; remaining=${remaining#"${remaining%%[![:space:]]*}"}
        [[ -z $remaining ]] || terminal_text "$remaining" '      ' '      ' "$BOLD"
        ((width >= 32)) || command_prefix='  '
        [[ -z $command ]] || terminal_text "$command" "$command_prefix" "$command_prefix" "$DIM"
    fi
    [[ -z $note ]] || terminal_text "$note" '      ' '      ' "$DIM"
}
parse_args() {
    while (($#)); do
        case "$1" in
            manage-panel|manage-node|configure-node-site|change-domain|show-config|install-subscription-page|upgrade-subscription-page|uninstall-subscription-page|manage-subscription-page|configure-subscription-page|normalize-layout|cleanup-backups|install-panel|install-node|upgrade-panel|upgrade-node|uninstall-panel|uninstall-node|migrate-remnawave-panel|migrate-remnawave-node|migrate-remnawave-subscription-page|migrate-marzban-panel|--check-release|status|check-panel|logs|start|stop|restart|backup-panel|restore-panel|renew-node-certificate|renew-panel-certificate)
                [[ -z $ACTION ]] || die 'Укажите одно действие'; ACTION=$1 ;;
            --node-site-mode|--node-site-port|--node-inbound-port|--page-id|--page-operation|--panel-url|--panel-token-file|--version|--component|--directory|--compose-file|--container|--project-name|--domain|--subscription-urls|--subscription-port|--server-ip|--port|--proxy|--node-domain|--email|--tls-method|--cert-file|--key-file|--dns-credentials|--panel-ip|--backup|--source-url|--destination-url|--internal-squad|--quota-mode)
                (($#>=2)) && [[ -n $2 && $2 != --* ]] || die "Нужно значение после $1"
                case "$1" in
                    --node-site-mode) NODE_SITE_MODE=$2;; --node-site-port) NODE_SITE_PORT=$2;; --node-inbound-port) NODE_INBOUND_PORT=$2;;
                    --page-id) PAGE_ID=$2;; --page-operation) PAGE_OPERATION=$2;; --panel-url) PAGE_PANEL_URL=$2;; --panel-token-file) PAGE_TOKEN_FILE=$2;;
                    --version) VERSION=$2;; --component) COMPONENT=$2;; --directory) DIRECTORY=$2;; --compose-file) COMPOSE_FILE=$2;;
                    --container) CONTAINER=$2;; --project-name) PROJECT=$2;; --domain) DOMAIN=$2;; --port) PORT=$2;; --proxy) PROXY=$2; PROXY_SET=true;;
                    --subscription-urls) SUBSCRIPTION_URLS=$2; SUBSCRIPTION_SET=true;;
                    --subscription-port) SUBSCRIPTION_PORT=$2; SUBSCRIPTION_SET=true;;
                    --server-ip) SERVER_IPS=$2;;
                    --node-domain) NODE_DOMAIN=$2;; --email) EMAIL=$2;; --tls-method) TLS_METHOD=$2;; --cert-file) CERT_FILE=$2;; --key-file) KEY_FILE=$2;; --dns-credentials) DNS_CREDENTIALS=$2;; --panel-ip) PANEL_IP=$2;; --backup) BACKUP=$2;;
                    --source-url) MARZBAN_URL=$2;; --destination-url) DESTINATION_URL=$2;; --internal-squad) INTERNAL_SQUAD=$2;; --quota-mode) QUOTA_MODE=$2;;
                esac; shift ;;
            --subscription-page|--no-subscription-page)
                $SUBSCRIPTION_PAGE_SET && die 'Выберите один вариант установки сайта подписки'
                SUBSCRIPTION_PAGE_SET=true; [[ $1 != --subscription-page ]] || SUBSCRIPTION_PAGE=true;;
            --net-admin|--no-net-admin)
                $PANEL_NET_ADMIN_SET && die 'Выберите один вариант NET_ADMIN для панели'
                PANEL_NET_ADMIN_SET=true; [[ $1 != --net-admin ]] || PANEL_NET_ADMIN=true;;
            --allow-disruption) ALLOW_DISRUPTION=true;;
            --yes) YES=true;; --dry-run) DRY_RUN=true;; --preserve-subhash) PRESERVE_SUBHASH=true;;
            --help|-h) usage; return 10;; *) die "Неизвестная команда или параметр: $1";;
        esac; shift
    done
    [[ $REPO =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die 'Некорректный REMNACUST_REPOSITORY'
    [[ $ROOT == /* && $ROOT != / && $ROOT != /opt && $ROOT != /usr ]] || die 'Некорректный корневой каталог'
    [[ -z $VERSION ]] || valid_version "$VERSION" || die 'Версия: latest или SemVer'
    [[ -z $COMPONENT || $COMPONENT == panel || $COMPONENT == node || $COMPONENT == subscription-page ]] || die 'Компонент: panel, node или subscription-page'
    if [[ $COMPONENT == subscription-page ]]; then
        case "$ACTION" in status|logs|start|stop|restart|show-config|change-domain|cleanup-backups|*subscription-page) ;; *) die 'Этот компонент доступен только в командах управления страницами';; esac
    fi
    [[ $PROXY == caddy || $PROXY == existing ]] || die 'Proxy: caddy или existing'
    [[ -z $ACTION || $ACTION == install-panel || $ACTION == install-subscription-page || $SUBSCRIPTION_SET == false ]] || die '--subscription-urls доступен для новой панели; обновление сохраняет существующие адреса подписки'
    [[ -z $ACTION || $ACTION == install-panel || $ACTION == upgrade-panel || $ACTION == migrate-remnawave-panel || $SUBSCRIPTION_PAGE_SET == false ]] || die 'Установка сайта подписки доступна для новой панели или миграции Remnawave'
    [[ -z $ACTION || $ACTION == install-panel || $ACTION == install-node || $ACTION == upgrade-node || $ACTION == migrate-remnawave-node || $PANEL_NET_ADMIN_SET == false ]] || die '--net-admin/--no-net-admin доступны для новой панели, установки, переноса или обновления ноды'
    [[ -z $TLS_METHOD || $TLS_METHOD =~ ^(auto|http|cloudflare|gcore|existing)$ ]] || die 'Способ TLS: auto, http, cloudflare, gcore или existing'
    [[ -z $NODE_SITE_MODE || $NODE_SITE_MODE == selfsteal || $NODE_SITE_MODE == standalone ]] || die 'Режим сайта: selfsteal или standalone'
    local website_port
    for website_port in "${NODE_SITE_PORT:-443}" "${NODE_INBOUND_PORT:-8443}"; do
        [[ $website_port =~ ^[0-9]{1,5}$ ]] && ((10#$website_port >= 1 && 10#$website_port <= 65535)) || die 'Порт должен быть от 1 до 65535'
    done
    [[ -z $NODE_SITE_MODE$NODE_SITE_PORT$NODE_INBOUND_PORT || $ACTION == install-node || $ACTION == migrate-remnawave-node || ( $ACTION == change-domain && $COMPONENT == node ) ]] || die 'Параметры сайта ноды доступны при установке, переносе и смене домена ноды'
    [[ $ACTION == install-* || $ACTION == migrate-remnawave-node || $ACTION == change-domain || -z $TLS_METHOD$CERT_FILE$KEY_FILE$DNS_CREDENTIALS$EMAIL$NODE_DOMAIN ]] || die 'Параметры TLS доступны при установке, переносе ноды и смене домена; обновление сохраняет ваш proxy и сертификаты'
    [[ $QUOTA_MODE == remaining || $QUOTA_MODE == total ]] || die 'Quota: remaining или total'
    [[ $ALLOW_DISRUPTION == false || $ACTION == upgrade-panel ]] || die '--allow-disruption доступен только для upgrade-panel'
    if [[ $ACTION != migrate-marzban-panel ]] && { $DRY_RUN || $PRESERVE_SUBHASH || [[ -n $MARZBAN_URL$DESTINATION_URL$INTERNAL_SQUAD ]]; }; then die 'Параметры Marzban предназначены только для migrate-marzban-panel'; fi
}
subscription_page_installed() {
    if command -v python3 >/dev/null && python3 - "$ROOT" <<'PY'
import json,sys
from pathlib import Path
root=Path(sys.argv[1])
def load(path):
    try:
        if path.is_symlink() or not path.is_file() or path.stat().st_size>1024*1024:return {}
        value=json.loads(path.read_text())
        return value if isinstance(value,dict) else {}
    except (OSError,ValueError):return {}
def present(item):
    try:
        directory=Path(item.get('directory',''))
        files=item.get('composeFiles',[])
        return not item.get('uninstalled') and directory.is_absolute() and directory.is_dir() and not directory.is_symlink() and isinstance(files,list) and bool(files) and all(isinstance(value,str) and (path:=directory/value).is_file() and not path.is_symlink() for value in files)
    except (OSError,TypeError,ValueError):return False
try:
    folder=root/'registry/subscription-pages'
    if not folder.is_symlink():
        for path in folder.glob('*.json'):
            if present(load(path)):raise SystemExit(0)
    panel=load(root/'registry/panel.json')
    if not panel.get('uninstalled'):
        if panel.get('subscriptionPage') and present(panel):raise SystemExit(0)
        migrated=panel.get('subscriptionMigration')
        if isinstance(migrated,dict) and present(migrated):raise SystemExit(0)
except (OSError,TypeError,ValueError):pass
raise SystemExit(1)
PY
    then return 0; fi
    command -v docker >/dev/null || return 1
    local image rows
    rows=$(docker ps --all --format '{{.Image}}' 2>/dev/null) || return 1
    while IFS= read -r image; do
        case "${image%%@*}" in
            ghcr.io/lottman/remnacust-subscription-page|ghcr.io/lottman/remnacust-subscription-page:*|remnawave/subscription-page|remnawave/subscription-page:*|docker.io/remnawave/subscription-page|docker.io/remnawave/subscription-page:*|ghcr.io/remnawave/subscription-page|ghcr.io/remnawave/subscription-page:*) return 0;;
        esac
    done <<< "$rows"
    return 1
}
component_installed() {
    local component=$1 directory="$ROOT/$1" registry="$ROOT/registry/$1.json" file
    if [[ -f $registry && ! -L $registry ]] && command -v python3 >/dev/null; then
        directory=$(python3 - "$registry" "$component" <<'PY'
import json,sys
try:
    state=json.load(open(sys.argv[1]))
    if state.get('component')!=sys.argv[2] or state.get('uninstalled'): raise SystemExit(1)
    print(state['directory'])
except (OSError,ValueError,KeyError,TypeError): raise SystemExit(1)
PY
        ) || directory="$ROOT/$component"
    fi
    [[ -z $DIRECTORY || $COMPONENT != "$component" ]] || directory=$DIRECTORY
    if ! retired_installation "$component" && [[ ! -f $directory/.remnacust-uninstalled && -d $directory && ! -L $directory ]]; then
        for file in compose.json compose.yml compose.yaml docker-compose.yml docker-compose.yaml Dockerfile; do
            [[ ! -f $directory/$file || -L $directory/$file ]] || return 0
        done
    fi
    [[ -n $(component_containers "$component") || -n $(component_project_containers "$component") ]]
}
component_containers() {
    # Also find installations made before the registry existed, including stopped containers.
    command -v docker >/dev/null || return 0
    local component=$1 main=remnawave project="${PROJECT:-remnacust-$1}" rows id name image
    [[ $component != node ]] || main=remnanode
    rows=$(docker ps --all --filter "label=com.docker.compose.service=$main" --format '{{.ID}}|{{.Label "com.docker.compose.project"}}|{{.Image}}' 2>/dev/null) || return 0
    while IFS='|' read -r id name image; do
        [[ -n $id ]] || continue
        if [[ $name == "$project" || $image == *remnacust-"$component"* ]]; then printf '%s\n' "$id"; fi
    done <<< "$rows"
}
component_project_containers() {
    command -v docker >/dev/null || return 0
    docker ps --all --quiet --filter "label=com.docker.compose.project=${PROJECT:-remnacust-$1}" 2>/dev/null || true
    docker ps --all --quiet --filter "label=io.remnacust.installer-managed=$1" 2>/dev/null || true
}
assert_fresh_target() {
    local directory="${DIRECTORY:-$ROOT/$COMPONENT}" project="${PROJECT:-remnacust-$COMPONENT}" existing
    component_installed "$COMPONENT" && die "$COMPONENT уже установлен (в том числе остановленные контейнеры). Используйте upgrade-$COMPONENT; для старой установки укажите --directory или --container."
    if [[ -e $ROOT/registry/$COMPONENT.json || -L $ROOT/registry/$COMPONENT.json ]]; then
        retired_installation "$COMPONENT" || die 'Найдена запись установки, но её файлы недоступны. Проверьте каталог; новая установка поверх неё не выполняется.'
    fi
    [[ $directory == /* && $directory != / && ! -L $directory ]] || die 'Укажите безопасный абсолютный каталог'
    if [[ -d $directory && -n $(find "$directory" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
        if [[ -n $DIRECTORY ]] || ! retired_installation "$COMPONENT"; then
            die "Каталог $directory не пуст. Используйте upgrade/migrate или другой --directory."
        fi
    fi
    if command -v docker >/dev/null; then
        existing=$(docker ps --all --filter "label=com.docker.compose.project=$project" --format '{{.Names}} · {{.Label "com.docker.compose.project.working_dir"}}' 2>/dev/null) || die 'Не удалось проверить контейнеры: Docker daemon недоступен. Запустите Docker и повторите проверку.'
        [[ -z $existing ]] || die "Проект $project уже существует: $existing. Используйте upgrade/migrate с --directory."
    fi
}
retired_installation() {
    [[ -f $ROOT/registry/$1.json && ! -L $ROOT/registry/$1.json ]] || return 1
    command -v python3 >/dev/null || return 1
    python3 - "$ROOT/registry/$1.json" "$1" <<'PY'
import json,sys
try:
    s=json.load(open(sys.argv[1]))
    raise SystemExit(0 if isinstance(s,dict) and s.get('component')==sys.argv[2] and s.get('uninstalled') is True else 1)
except (OSError,ValueError,TypeError):raise SystemExit(1)
PY
}
assert_not_uninstalled() {
    case "$ACTION" in start|restart|restore-panel)
        if retired_installation "$COMPONENT" || [[ -n $DIRECTORY && -f $DIRECTORY/.remnacust-uninstalled || -n $DEPLOY && -f $DEPLOY/.remnacust-uninstalled ]]; then
            die "$COMPONENT удалён. Доступна только новая установка: remnacust install-$COMPONENT. Прежние данные сохраняются."
        fi;;
    esac
}
project_has_volumes() {
    docker volume ls --quiet > "$WORK/existing-volumes" || die 'Не удалось проверить тома: Docker недоступен'
    python3 - "$WORK/existing-volumes" "$1" <<'PY'
import sys
raise SystemExit(0 if any(n.startswith(sys.argv[2]+'_') for n in open(sys.argv[1]).read().splitlines()) else 1)
PY
}
select_fresh_target() {
    local stamp project="${PROJECT:-remnacust-$COMPONENT}" collision=false
    stamp="$(date -u +%Y%m%d%H%M%S)-$$"
    REINSTALL_RECORD=''
    if retired_installation "$COMPONENT"; then
        REINSTALL_RECORD="$WORK/retired-registry.json"
        install -m 0600 "$ROOT/registry/$COMPONENT.json" "$REINSTALL_RECORD"
        [[ -n $PROJECT ]] || project="remnacust-$COMPONENT-$stamp"
        [[ -n $DIRECTORY ]] || DIRECTORY="$ROOT/$COMPONENT"
        if [[ -d $DIRECTORY && -n $(find "$DIRECTORY" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
            python3 - "$DIRECTORY" <<'PY'
import json,subprocess,sys
directory=sys.argv[1]
ids=subprocess.run(['docker','ps','--all','--quiet'],capture_output=True,text=True,check=True).stdout.split()
containers=json.loads(subprocess.run(['docker','inspect',*ids],capture_output=True,text=True,check=True).stdout) if ids else []
for item in containers:
 labels=item.get('Config',{}).get('Labels') or {}
 paths=[labels.get('com.docker.compose.project.working_dir',''),*labels.get('com.docker.compose.project.config_files','').split(','),*[mount.get('Source','') for mount in item.get('Mounts',[])]]
 if any(path==directory or path.startswith(directory+'/') for path in paths):raise SystemExit('Каталог используется другим контейнером; новая установка остановлена без переноса файлов')
PY
            local retired_path="$ROOT/backups/reinstalled-$COMPONENT-$stamp"
            mkdir -p "$ROOT/backups"
            mv -- "$DIRECTORY" "$retired_path"
            info "Файлы удалённой установки сохранены: $retired_path"
        fi
        info 'Рабочий каталог постоянный; прежние данные находятся в backups и сохранённых томах.'
    fi
    if project_has_volumes "$project"; then collision=true; fi
    if $collision; then
        [[ -z $PROJECT ]] || die "Тома проекта $PROJECT уже существуют. Для новой установки укажите другое --project-name; прежние данные сохраняются."
        project="remnacust-$COMPONENT-$stamp"
        [[ -n $DIRECTORY ]] || DIRECTORY="$ROOT/$COMPONENT"
        info 'Прежние тома сохраняются; для новой установки выбран отдельный проект Docker.'
    fi
    PROJECT=$project
    info "Каталог: ${DIRECTORY:-$ROOT/$COMPONENT} · проект: $PROJECT"
}
archive_retired_registry() {
    [[ -n $REINSTALL_RECORD ]] || return 0
    local snapshot="$ROOT/backups/reinstall-$COMPONENT-$(date -u +%Y%m%dT%H%M%SZ)-$$"
    cmp -- "$REINSTALL_RECORD" "$ROOT/registry/$COMPONENT.json" >/dev/null || die 'Запись прежней установки изменилась; повторите установку'
    install -d -m 0700 "$snapshot"
    install -m 0600 "$REINSTALL_RECORD" "$snapshot/registry.json"
    info "Параметры прежней установки сохранены: $snapshot/registry.json"
}
confirm() {
    $YES && return 0
    local answer
    answer=$(ask_yes_no "$1. Продолжить?") || exit 1
    [[ $answer == yes ]] || { info 'Действие отменено'; exit 0; }
}
cleanup() {
    local result=0
    if [[ -n ${DOMAIN_PLAN:-} && -f $DOMAIN_PLAN && -n ${HELPER_ROOT:-} ]]; then
        python3 -I "$HELPER_ROOT/management.py" rollback --root "$ROOT" --plan "$DOMAIN_PLAN" || { result=$?; printf '  Не удалось завершить откат. План восстановления: %s\n' "$DOMAIN_PLAN" >&2; }
    fi
    if [[ -n $WORK && -f $WORK/.installer-owned ]]; then rm -rf -- "$WORK" || result=$?; fi
    return "$result"
}
operation_log_event() {
    $OPERATION_LOG_ACTIVE || return 0
    printf '[%s] %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "${2:-}" >> "$LOG"
}
operation_log_error() {
    local result=$1 line=$2 context=$3
    operation_log_event ERROR "exit=$result line=$line functions=$context"
    return "$result"
}
operation_log_finish() {
    local result=$1 cleanup_status=0
    trap - EXIT ERR INT TERM HUP
    set +e
    cleanup || cleanup_status=$?
    ((result != 0 || cleanup_status == 0)) || result=$cleanup_status
    if $OPERATION_LOG_ACTIVE; then
        operation_log_event FINISH "action=$ACTION exit=$result elapsed=$((SECONDS-OPERATION_STARTED))s"
        if [[ -n $OPERATION_STDERR ]]; then exec 2>&"$OPERATION_STDERR"; exec {OPERATION_STDERR}>&-; fi
        [[ -z $OPERATION_LOG_PID ]] || wait "$OPERATION_LOG_PID"
        if ((result)); then printf '\n  Действие не завершено (код %s). Подробный журнал: %s\n  Просмотр: sudo less -- %q\n' "$result" "$LOG" "$LOG" >&2
        else printf '  Подробный журнал: %s (будет заменён при следующем действии).\n' "$LOG"; fi
    fi
    exit "$result"
}
start_operation_log() {
    [[ $EUID == 0 && $(uname -s) == Linux ]] || die 'Нужен root на Linux'
    [[ ! -L $ROOT && ! -L $ROOT/logs ]] || die 'Каталог журнала не может быть символической ссылкой'
    install -d -m 0700 "$ROOT/logs"
    command -v flock >/dev/null || die 'Нужен util-linux (flock)'
    [[ ! -L $ROOT/logs/.operation.lock ]] || die 'Некорректный файл блокировки журнала'
    exec 8>"$ROOT/logs/.operation.lock"
    flock -n 8 || die 'Другое действие ещё выполняется; предыдущий журнал сохранён'
    local created kind=${COMPONENT:-maintenance}
    case "$ACTION" in
        *subscription-page) kind=subscription-page;;
        *panel|renew-panel-certificate) kind=panel;;
        *node|renew-node-certificate|configure-node-site) kind=node;;
    esac
    case "$ACTION" in status|logs|show-config|check-panel|--check-release) kind=diagnostics;; esac
    case "$kind" in panel|node|subscription-page|maintenance|diagnostics) ;; *) die 'Некорректный компонент журнала';; esac
    created=$(mktemp "$ROOT/logs/.installer-log.XXXXXXXX")
    chmod 0600 "$created"
    LOG="$ROOT/logs/installer-$kind.log"
    mv -fT -- "$created" "$LOG"
    OPERATION_LOG_ACTIVE=true; OPERATION_STARTED=$SECONDS
    trap 'operation_log_finish "$?"' EXIT
    trap 'operation_log_error "$?" "$LINENO" "${FUNCNAME[*]}"' ERR
    trap 'operation_log_event INTERRUPTED signal=INT; exit 130' INT
    trap 'operation_log_event INTERRUPTED signal=TERM; exit 143' TERM
    trap 'operation_log_event INTERRUPTED signal=HUP; exit 129' HUP
    operation_log_event START "action=$ACTION requested=${VERSION:-latest} architecture=$(uname -m) kernel=$(uname -r)"
    printf '  Подробный журнал: %s\n' "$LOG"
    exec {OPERATION_STDERR}>&2
    exec 2> >(tee -a -- "$LOG" >&"$OPERATION_STDERR")
    OPERATION_LOG_PID=$!
}
report_update_progress() {
    [[ -n ${REMNACUST_UPDATE_JOB:-} && -n ${HELPER_ROOT:-} ]] || return 0
    python3 "$HELPER_ROOT/update-agent.py" --root "$ROOT" progress --job "$REMNACUST_UPDATE_JOB" \
        --stage "$1" --label "$2" --event "$3" >> "$LOG" 2>&1 || true
}
step() {
    local title=$1 pid status=0 i=0 display width stage=preparation started=$SECONDS; shift
    case "$1" in
        fetch_source) stage=checking;;
        prepare_image|prepare_subscription_image) stage=download;;
        backup_panel_data) stage=backup;;
        wait_ready) stage=readiness;;
        verify_database) stage=verifying;;
        compose) stage=applying;;
    esac
    [[ -n $LOG ]] || die 'Не настроен журнал операции'
    operation_log_event STEP "started: $title"
    report_update_progress "$stage" "$title" running
    "$@" >> "$LOG" 2>&1 & pid=$!
    local LC_ALL=C.UTF-8
    if [[ -t 1 && -n $ACCENT ]]; then
        local -a frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
        while kill -0 "$pid" 2>/dev/null; do
            width=$(terminal_width); display=$title
            ((${#display} <= width-5)) || display="${display:0:width-6}…"
            printf '\r  %s%s%s %s' "$ACCENT" "${frames[i%10]}" "$RESET" "$display"
            i=$((i+1)); sleep .12
        done
        printf '\r\033[2K'
    else
        terminal_text "… $title" '  ' '    '
    fi
    wait "$pid" || status=$?
    operation_log_event STEP "finished: $title; exit=$status elapsed=$((SECONDS-started))s"
    if ((status)); then report_update_progress "$stage" "$title" failed
    else report_update_progress "$stage" "$title" done; fi
    if ((status)); then printf '%s  × %s · журнал: %s%s\n' "$ROSE" "$title" "$LOG" "$RESET" >&2; return "$status"; fi
    info "✓ $title"
}
package_step() {
    if [[ -n $OPERATION_STDERR ]] && [[ -t $OPERATION_STDERR ]]; then
        package_step_command "$@" 2>&"$OPERATION_STDERR"
    else package_step_command "$@"; fi
}
package_step_command() {
    local title=$1 operation=$2 status=0 plan='' stage=checking; shift 2
    [[ -z ${SOURCE:-} ]] || stage=preparation
    local -a apt_command=(apt-get -y -o DPkg::Lock::Timeout=120 -o APT::Get::Assume-No=false "$operation" "$@")
    command -v apt-get >/dev/null || die 'Нужен APT: системные пакеты обновляются на сервере Ubuntu/Debian'
    info "$title"
    [[ -z ${LOG:-} ]] || printf 'APT %s: started\n' "$operation" >> "$LOG"
    report_update_progress "$stage" "$title" running
    if [[ ! -t 0 || ! -t 1 || ! -t 2 ]]; then
        if [[ $operation != update ]]; then
            plan=$(mktemp "${WORK:-${TMPDIR:-/tmp}}/remnacust-apt-plan.XXXXXXXX") || return $?
            LC_ALL=C DEBIAN_FRONTEND=readline NEEDRESTART_MODE=l "${apt_command[@]}" --simulate > "$plan" 2>&1 || status=$?
            if ((status)); then
                cat -- "$plan" >&2; rm -f -- "$plan"
                report_update_progress "$stage" "$title" failed
                return "$status"
            fi
            if grep -Eq '^(Inst|Conf|Remv) ' "$plan" || ! grep -Eq '^0 upgraded, 0 newly installed, 0 to remove' "$plan"; then
                cat -- "$plan" >&2; rm -f -- "$plan"
                printf 'Системные пакеты требуют обновления в SSH-терминале для возможных вопросов настройки dpkg/debconf. Продолжение APT подтверждается автоматически (-y); --yes не выбирает настройки пакетов.\n' >&2
                report_update_progress "$stage" 'Обновите системные пакеты в SSH-терминале' failed
                return 75
            fi
            rm -f -- "$plan"
        fi
    fi
    if $OPERATION_LOG_ACTIVE && [[ -t 0 && -t 1 && -t 2 ]]; then
        command -v script >/dev/null || die 'Нужен util-linux (script) для интерактивного журнала APT'
        local package_command
        printf -v package_command '%q ' env DEBIAN_FRONTEND=readline NEEDRESTART_MODE=l "${apt_command[@]}"
        script --quiet --return --flush --append --echo never --log-out "$LOG" --command "$package_command" || status=$?
    elif $OPERATION_LOG_ACTIVE; then
        DEBIAN_FRONTEND=readline NEEDRESTART_MODE=l "${apt_command[@]}" 2>&1 | tee -a -- "$LOG" || status=$?
    else
        DEBIAN_FRONTEND=readline NEEDRESTART_MODE=l "${apt_command[@]}" || status=$?
    fi
    [[ -z ${LOG:-} ]] || printf 'APT %s: exit %s\n' "$operation" "$status" >> "$LOG"
    if ((status)); then
        report_update_progress "$stage" "$title" failed
        printf 'Обновление системных пакетов не завершено (код %s). Действие остановлено; исправьте ошибку APT/dpkg и повторите команду.\n' "$status" >&2
        return "$status"
    fi
    report_update_progress "$stage" "$title" done
    info "✓ $title"
}
update_system_packages() {
    [[ $ACTION != --check-release ]] || return 0
    if $DRY_RUN; then
        info 'Пробный запуск: системные пакеты не изменяются'
        return 0
    fi
    case "$ACTION" in install-*|upgrade-*|migrate-remnawave-*) supported_os_codename >/dev/null || return $?;; esac
    if [[ $ACTION == upgrade-panel && ${REMNACUST_UPDATE_JOB:-} =~ ^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ &&
          ${REMNACUST_RELEASE_ENTRY_FILE:-} == "$ROOT/control/release-${REMNACUST_UPDATE_JOB}.sh" &&
          ( ! -t 0 || ! -t 1 || ! -t 2 ) ]]; then
        info 'Обновление панели без APT. Обслуживание ОС отложено: выполните обновление системных пакетов отдельно в SSH-терминале.'
        report_update_progress checking 'Обслуживание ОС отложено до SSH; обновляется только панель' done
        return 0
    fi
    package_step 'Обновление списка системных пакетов' update -o APT::Update::Error-Mode=any || return $?
    package_step 'Обновление системных пакетов' upgrade --with-new-pkgs || return $?
    if [[ -f /var/run/reboot-required ]]; then
        info 'Системе нужна перезагрузка. Выполните её отдельно в удобное время; установщик сервер не перезагружает.'
    fi
}
helper() {
    if $OPERATION_LOG_ACTIVE; then python3 "$HELPER" "$@"
    elif [[ -n ${LOG:-} ]]; then python3 "$HELPER" "$@" 2> >(tee -a -- "$LOG" >&2)
    else python3 "$HELPER" "$@"; fi
}
get() { helper get --state "$STATE" --key "$1"; }
compose() {
    local -a args=(); local file
    for file in "${FILES[@]}"; do args+=(-f "$file"); done
    docker compose --project-name "$PROJECT" --project-directory "$DEPLOY" "${args[@]}" "$@"
}
load_state() {
    [[ -f $STATE ]] || die 'Установка не зарегистрирована; используйте migrate-remnawave-panel/node'
    DEPLOY=$(get directory); PROJECT=$(get project)
    mapfile -t FILES < <(get composeFiles); mapfile -t APPS < <(get applications); mapfile -t EXTRAS < <(get extraServices)
    ((${#FILES[@]}&&${#APPS[@]})) || die 'Неполные метаданные установки'
}
capture_running_apps() {
    local service id
    RUNNING_APPS=()
    for service in "${APPS[@]}"; do
        id=$(compose ps --all --quiet "$service")
        if [[ -n $id && $(docker inspect --format '{{.State.Running}}' "$id") == true ]]; then
            RUNNING_APPS+=("$service")
        fi
    done
}
load_restore_apps() {
    # An explicitly empty list means all applications were stopped in the backup.
    python3 - "$STATE" > "$WORK/restore-applications" <<'PY'
import json,sys
s=json.load(open(sys.argv[1]));apps=s.get('runningApplications',s['applications'])
if not isinstance(apps,list) or any(a not in s['applications'] for a in apps):raise SystemExit('Invalid application state')
if apps:print('\n'.join(apps))
PY
    local status=$?
    ((status==0)) || return "$status"
    mapfile -t START_APPS < "$WORK/restore-applications"
}
supported_os_codename() {
    local release=${1:-/etc/os-release} id version
    [[ -f $release ]] || die 'Не определена ОС: отсутствует /etc/os-release'
    # shellcheck disable=SC1090,SC1091
    id=$(unset ID; . "$release"; printf '%s' "${ID:-}")
    # shellcheck disable=SC1090,SC1091
    version=$(unset VERSION_ID; . "$release"; printf '%s' "${VERSION_ID:-}")
    case "$id:$version" in
        ubuntu:22.04) printf jammy;;
        ubuntu:24.04) printf noble;;
        ubuntu:26.04) printf resolute;;
        debian:12) printf bookworm;;
        debian:13) printf trixie;;
        *) die "Поддерживаются Ubuntu 22.04 LTS, Ubuntu 24.04 LTS, Ubuntu 26.04 LTS, Debian 12 и Debian 13. Обнаружено: ${id:-неизвестно} ${version:-неизвестно}";;
    esac
}
prepare_host() {
    local id codename
    codename=$(supported_os_codename) || return $?
    [[ $EUID == 0 && $(uname -s) == Linux ]] || die 'Для установки нужен root на Linux'
    case "$(uname -m)" in x86_64|aarch64) ;; *) die 'Нужна архитектура amd64 или arm64';; esac
    id=$(unset ID; . /etc/os-release; printf '%s' "${ID:-}")
    case "$id" in ubuntu|debian) ;; *) die 'Не определён репозиторий Docker для ОС';; esac
    if ! command -v python3 >/dev/null || ! command -v curl >/dev/null || ! command -v flock >/dev/null || ! command -v tar >/dev/null || ! command -v openssl >/dev/null; then
        package_step 'Подготовка системных пакетов' update -o APT::Update::Error-Mode=any || return $?
        package_step 'Python, curl, util-linux, OpenSSL' install ca-certificates curl python3 util-linux tar openssl || return $?
    fi
    installed_helper || return $?
    if ! command -v docker >/dev/null; then
        package_step 'Индекс пакетов' update -o APT::Update::Error-Mode=any || return $?
        package_step 'Ключи репозитория Docker' install ca-certificates curl || return $?
        install -d -m 0755 /etc/apt/keyrings
        download "https://download.docker.com/linux/$id/gpg" "$WORK/docker.asc"
        install -m 0644 "$WORK/docker.asc" /etc/apt/keyrings/remnacust-docker.asc
        printf 'deb [arch=%s signed-by=/etc/apt/keyrings/remnacust-docker.asc] https://download.docker.com/linux/%s %s stable\n' "$(dpkg --print-architecture)" "$id" "$codename" > /etc/apt/sources.list.d/remnacust-docker.list
        package_step 'Индекс Docker' update -o APT::Update::Error-Mode=any || return $?
        package_step 'Docker Engine и Compose' install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || return $?
        systemctl enable --now docker
    fi
    docker info >/dev/null 2>&1 || die 'Docker установлен, но daemon недоступен; текущая установка не изменена'
    if ! docker compose version >/dev/null 2>&1; then
        package_step 'Индекс Compose' update -o APT::Update::Error-Mode=any || return $?
        if apt-cache show docker-compose-plugin >/dev/null 2>&1; then package_step 'Docker Compose plugin' install docker-compose-plugin || return $?
        elif apt-cache show docker-compose-v2 >/dev/null 2>&1; then package_step 'Docker Compose v2' install docker-compose-v2 || return $?
        else die 'Нет пакета Compose v2 в настроенных репозиториях; Docker daemon не изменён'; fi
    fi
    docker compose version >/dev/null || die 'Нужен Docker Compose v2'
}
port_free() {
    python3 - "$1" <<'PY'
import socket,sys
port=int(sys.argv[1])
for family,address in [(socket.AF_INET,'0.0.0.0'),(socket.AF_INET6,'::')]:
    s=socket.socket(family,socket.SOCK_STREAM)
    try:
        if family==socket.AF_INET6:s.setsockopt(socket.IPPROTO_IPV6,socket.IPV6_V6ONLY,1)
        s.bind((address,port))
    except OSError as e:
        if e.errno not in (97,99):raise SystemExit('Порт занят: '+str(port))
    finally:s.close()
PY
}
choose_subscription_port() {
    local candidate=$1 reserved=${2:-}
    while true; do
        if [[ $candidate == 80 || $candidate == 443 || -n $reserved && $candidate == "$reserved" ]]; then
            printf '  Порт сайта подписки должен отличаться от портов панели и HTTPS.\n' >&2
        elif helper validate --port "$candidate" >/dev/null && port_free "$candidate"; then
            printf '%s' "$candidate"; return 0
        fi
        [[ -t 0 ]] && ! $YES || return 1
        printf '  Выберите другой свободный порт; работающие сервисы сохраняются.\n' >&2
        candidate=$(ask_required 'Свободный порт страницы подписки') || return $?
    done
}
panel_processes_ready() {
    local id=$1 service=$2
    [[ $COMPONENT == panel && " ${APPS[*]} " == *" $service "* ]] || return 0
    [[ $service != remnawave-subscription-page ]] || return 0
    docker exec "$id" node -e 'const fs=require("node:fs");if(!fs.existsSync("/opt/pm2/package.json"))process.exit(0);try{const {execFileSync}=require("node:child_process");const rows=JSON.parse(execFileSync("pm2",["jlist"],{timeout:5000,maxBuffer:16*1024*1024,encoding:"utf8"}));const names=new Set(["remnawave-api","remnawave-jobs","remnawave-scheduler"]);const apps=rows.filter(x=>names.has(x.name));process.exit(apps.length&&apps.every(x=>x.pm2_env.status==="online"&&x.pm2_env.restart_time===0)?0:1);}catch{process.exit(1)}' >/dev/null 2>&1
}
wait_ready() {
    local service id state before attempt ready
    for service in "${START_APPS[@]}"; do
        id=$(compose ps --all --quiet "$service")
        [[ -n $id ]] || return 1
        ready=false
        for ((attempt=1; attempt<=90; attempt++)); do
            state=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$id")
            if [[ $state == healthy ]] && panel_processes_ready "$id" "$service"; then ready=true; break; fi
            if [[ $state == unhealthy || $state == exited || $state == dead ]]; then return 1; fi
            if (( $(docker inspect --format '{{.RestartCount}}' "$id") >= 3 )); then return 1; fi
            if [[ $state == running ]]; then
                before=$(docker inspect --format '{{.State.Running}} {{.RestartCount}} {{.State.StartedAt}}' "$id")
                sleep 5
                if [[ $(docker inspect --format '{{.State.Running}} {{.RestartCount}} {{.State.StartedAt}}' "$id") == "$before" ]]; then
                    if { [[ $COMPONENT != node || $service != "$(get mainService)" ]] || docker exec "$id" node -e 'const s=require("net").connect(Number(process.env.NODE_PORT||2222),"127.0.0.1");s.on("connect",()=>{s.destroy();process.exit(0)});s.on("error",()=>process.exit(1));setTimeout(()=>process.exit(1),3000)' >/dev/null 2>&1; } && panel_processes_ready "$id" "$service"; then ready=true; break; fi
                fi
            fi
            sleep 2
        done
        $ready || return 1
    done
}
prepare_image() {
    [[ -f $SOURCE/images.json ]] || die 'В этом старом выпуске нет готовых Docker-образов. Выберите latest; сборка на сервере отключена.'
    if docker image inspect "$IMAGE" > "$WORK/image.inspect.json" 2>/dev/null; then
        verify_loaded_image
        return
    fi
    local docker_directory free_kb needed_kb
    docker_directory=$(docker info --format '{{.DockerRootDir}}')
    free_kb=$(df -Pk "$docker_directory" | awk 'NR==2 {print $4}')
    needed_kb=$(( $(image_field size) * 4 / 1024 + 512 * 1024 ))
    ((free_kb >= needed_kb)) || die 'Недостаточно места для скачивания и распаковки Docker-образа; текущая установка не изменена'
    if docker pull "$(image_field registry)"; then
        docker tag "$(image_field registry)" "$IMAGE"
        docker image inspect "$IMAGE" > "$WORK/image.inspect.json"
        verify_loaded_image
        return
    fi
    info 'GHCR недоступен; скачиваем тот же проверенный образ из GitHub Release'
    download "$(image_field url)" "$WORK/image.tar.gz"
    python3 "$HELPER_ROOT/images.py" archive --image "${IMAGE_METADATA:-$WORK/image.json}" --file "$WORK/image.tar.gz"
    docker load --input "$WORK/image.tar.gz"
    docker image inspect "$IMAGE" > "$WORK/image.inspect.json"
    verify_loaded_image
}
verify_loaded_image() {
    if python3 "$HELPER_ROOT/images.py" inspect --image "${IMAGE_METADATA:-$WORK/image.json}" --file "$WORK/image.inspect.json" --quiet; then return; fi
    # Import into containerd may regenerate the manifest. Verify its exact config,
    # including layer digests, without writing another image copy to the server.
    docker save "$IMAGE" | python3 "$HELPER_ROOT/images.py" saved --image "${IMAGE_METADATA:-$WORK/image.json}"
}
image_field() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])' "${IMAGE_METADATA:-$WORK/image.json}" "$1"; }
select_subscription_image() {
    python3 "$HELPER_ROOT/images.py" select --root "$SOURCE" --tag "$TAG" --assets "$WORK/release.json" \
        --repository "$REPO" --component subscription-page --architecture "$(dpkg --print-architecture)" > "$WORK/subscription-image.json"
    local IMAGE_METADATA="$WORK/subscription-image.json"
    SUBSCRIPTION_IMAGE=$(image_field image)
    SUBSCRIPTION_IMAGE_VERSION=$(image_field version)
}
prepare_subscription_image() {
    local IMAGE=$SUBSCRIPTION_IMAGE IMAGE_METADATA="$WORK/subscription-image.json"
    prepare_image
}
find_existing() {
    local main id
    main=remnawave; [[ $COMPONENT != node ]] || main=remnanode
    if [[ -n $CONTAINER ]]; then id=$CONTAINER
    elif [[ -n $DIRECTORY || -n $COMPOSE_FILE ]]; then
        DEPLOY=${DIRECTORY:-$(dirname "$COMPOSE_FILE")}; DEPLOY=$(realpath "$DEPLOY")
        if [[ -n $COMPOSE_FILE ]]; then FILES=("$(realpath "$COMPOSE_FILE")")
        else for id in compose.json compose.yml compose.yaml docker-compose.yml docker-compose.yaml; do [[ ! -f $DEPLOY/$id ]] || { FILES=("$DEPLOY/$id"); break; }; done; fi
        ((${#FILES[@]})) || die 'В каталоге нет Compose-файла'
        local -a args=(); for id in "${FILES[@]}"; do args+=(-f "$id"); done
        id=$(docker compose --project-directory "$DEPLOY" "${args[@]}" ps --all --quiet "$main")
        [[ -n $id ]] || die 'Не найден контейнер приложения; укажите --container'
    else
        local -a ids=(); mapfile -t ids < <(docker ps --all --filter "label=com.docker.compose.service=$main" --format '{{.ID}}')
        ((${#ids[@]}==1)) || die 'Укажите --directory или --container: контейнер не найден либо их несколько'
        id=${ids[0]}
    fi
    docker inspect "$id" > "$WORK/container.before.json"
    local -a discovery=(); [[ -z $DIRECTORY ]] || discovery=(--directory "$DIRECTORY")
    [[ -z $COMPOSE_FILE ]] || discovery+=(--compose-file "$(realpath "$COMPOSE_FILE")")
    helper discover --inspect "$WORK/container.before.json" --component "$COMPONENT" --target "$WORK/state.json" "${discovery[@]}"
    if [[ -f $ROOT/registry/$COMPONENT.json ]]; then
        python3 - "$WORK/state.json" "$ROOT/registry/$COMPONENT.json" <<'PY'
import json,sys
p=sys.argv[1];new=json.load(open(p));old=json.load(open(sys.argv[2]))
if new['project']==old['project'] and new['directory']==old['directory']:
 for key in ['nodeDomain','nodeSiteMode','nodeSitePort','nodeInboundPort','panelDomain','proxy','apiPort','extraServices','version','image','ownedServices','tls','subscriptionUrls','subscriptionPage','subscriptionPort','subscriptionTokenUuid','subscriptionMigration','composeEntryPoint']:
  if key in old and (key != 'apiPort' or key not in new) and (key != 'composeEntryPoint' or old[key] in new.get('composeFiles',[])):new[key]=old[key]
 json.dump(new,open(p,'w'),indent=2)
PY
    fi
    STATE="$WORK/state.json"; load_state
    cp "$STATE" "$WORK/state.before.json"
    compose --profile '*' config --no-interpolate --no-env-resolution --format json > "$WORK/compose.before.json"
    local -a project_ids=(); mapfile -t project_ids < <(docker ps --all --quiet --filter "label=com.docker.compose.project=$PROJECT")
    docker inspect "${project_ids[@]}" > "$WORK/project-containers.json"
    local -a subscription_options=()
    if [[ $COMPONENT == panel && $IMAGE != discovery-only ]]; then subscription_migration_wizard; fi
    if [[ $COMPONENT == panel && $IMAGE != discovery-only ]] && python3 -c 'import json,sys;s=json.load(open(sys.argv[1]));sys.exit(not (s.get("subscriptionPage") or s.get("subscriptionMigration")))' "$STATE"; then
        select_subscription_image
        step 'Готовый образ сайта подписки' prepare_subscription_image
        subscription_options=(--subscription-image "$SUBSCRIPTION_IMAGE")
    fi
    helper transform --source "$WORK/compose.before.json" --inspect "$WORK/container.before.json" --roles "$WORK/project-containers.json" --component "$COMPONENT" --image "$IMAGE" "${subscription_options[@]}" --target "$WORK/compose.after.json" --state "$STATE"
    mapfile -t APPS < <(get applications)
    capture_running_apps
    START_APPS=("${RUNNING_APPS[@]}")
    local primary; primary=$(get mainService)
    [[ " ${START_APPS[*]} " == *" $primary "* ]] || START_APPS+=("$primary")
    python3 - "$WORK/state.before.json" "${APPS[@]}" <<'PY'
import json,sys
p=sys.argv[1];s=json.load(open(p));s['applications']=sys.argv[2:];json.dump(s,open(p,'w'),indent=2)
PY
}
subscription_migration_wizard() {
    local script="$HELPER_ROOT/subscription_migration.py" count choice index
    [[ -f $script ]] || return 0
    if python3 -c 'import json,sys;s=json.load(open(sys.argv[1]));sys.exit(not (s.get("subscriptionMigration") or s.get("subscriptionPage")))' "$STATE"; then return 0; fi
    [[ $ACTION == migrate-remnawave-panel || $ACTION == upgrade-panel ]] || return 0
    local -a candidates=()
    mapfile -t candidates < <(docker ps --all --quiet)
    (("${#candidates[@]}")) || return 0
    docker inspect "${candidates[@]}" > "$WORK/subscription-containers.json"
    python3 -I "$script" discover --panel "$WORK/container.before.json" --containers "$WORK/subscription-containers.json" --output "$WORK/subscription-candidates.json"
    count=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))))' "$WORK/subscription-candidates.json")
    ((count > 0)) || return 0
    python3 - "$WORK/subscription-candidates.json" <<'PY'
import json,sys
for index,item in enumerate(json.load(open(sys.argv[1])),1):
 print(f"  {index}. Сайт подписки: {item['project']}/{item['service']} · {item['directory']}")
PY
    if $SUBSCRIPTION_PAGE_SET; then
        choice=no; if $SUBSCRIPTION_PAGE; then choice=yes; fi
    elif [[ -t 0 ]]; then
        choice=$(ask_yes_no 'Перенести установленную страницу подписки на Remnacust?') || return $?
    else choice=no; fi
    if [[ $choice != yes ]]; then info 'Страница подписки сохранена без изменений.'; return 0; fi
    index=1
    if ((count > 1)); then
        while true; do
            index=$(ask_required 'Номер страницы для переноса') || return $?
            if [[ $index =~ ^[0-9]{1,3}$ ]] && ((10#$index>=1 && 10#$index<=count)); then index=$((10#$index)); break; fi
            printf '  Выберите номер от 1 до %s.\n' "$count" >&2
        done
    fi
    python3 -I "$script" select --source "$WORK/subscription-candidates.json" --index "$((index-1))" --state "$STATE"
    if [[ -z $PAGE_PANEL_URL && -t 0 ]] && ! $YES; then
        choice=$(ask_yes_no 'Использовать эту панель для переносимой страницы подписки?' y) || return $?
        if [[ $choice != yes ]]; then PAGE_PANEL_URL=$(ask_required 'HTTPS адрес другой панели') || return $?; fi
    fi
}
subscription_migration_apply() {
    local script="$HELPER_ROOT/subscription_migration.py" token_uuid id
    [[ -n $SUBSCRIPTION_IMAGE && -f $script ]] || return 1
    token_uuid=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["subscriptionMigration"]["tokenUuid"])' "$STATE")
    id=$(compose ps --quiet "$(get mainService)")
    local -a connection_options=()
    if [[ -n $PAGE_PANEL_URL && $PAGE_PANEL_URL != auto ]]; then
        subscription_page_token "$PAGE_PANEL_URL" "$WORK/migration-subscription-token.txt" || return $?
        connection_options=(--panel-url "$PAGE_PANEL_URL")
    else
        docker exec -i --env "REMNACUST_SUBSCRIPTION_TOKEN_UUID=$token_uuid" "$id" node - < "$HELPER_ROOT/subscription.cjs" > "$WORK/migration-subscription-token.txt"
    fi
    chmod 600 "$WORK/migration-subscription-token.txt"
    local result=0
    python3 -I "$script" upgrade --state "$STATE" --image "$SUBSCRIPTION_IMAGE" --token "$WORK/migration-subscription-token.txt" --backup-root "$ROOT/backups" --version "${COMPONENT_VERSION:-${TAG#v}}" --release "$TAG" "${connection_options[@]}" || result=$?
    rm -f -- "$WORK/migration-subscription-token.txt"
    if ((result != 0)); then info 'Панель обновлена. Перенос сайта не завершён; предыдущая конфигурация сайта восстановлена.'; return "$result"; fi
}

backup_panel_data() {
    local id
    id=$(compose ps --all --quiet "$(get mainService)")
    [[ -n $id ]] || return 1
    local backup_image=${IMAGE:-$(docker inspect --format '{{.Config.Image}}' "$id")}
    docker run --rm -i --network "$(cat "$WORK/database.network")" --env-file "$WORK/database.env" --entrypoint node "$backup_image" - > "$BACKUP/database.dump" <<'JS'
const {spawnSync}=require('node:child_process');const u=new URL(process.env.DATABASE_URL);
const env={...process.env,PGHOST:u.hostname,PGPORT:u.port||'5432',PGUSER:decodeURIComponent(u.username),PGPASSWORD:decodeURIComponent(u.password),PGDATABASE:decodeURIComponent(u.pathname.slice(1))};
if(u.searchParams.has('sslmode'))env.PGSSLMODE=u.searchParams.get('sslmode');
const result=spawnSync('pg_dump',['--format=custom'],{env,stdio:'inherit'});process.exit(result.status??1);
JS
    [[ -s $BACKUP/database.dump ]] || return 1
    docker run --rm -i --entrypoint pg_restore "$backup_image" --list < "$BACKUP/database.dump" > "$BACKUP/database.toc"
    grep -q 'TABLE DATA public users ' "$BACKUP/database.toc"
}
backup_current() {
    capture_running_apps
    BACKUP="$ROOT/backups/$COMPONENT-$(date -u +%Y%m%dT%H%M%SZ)-$$"
    mkdir -p "$BACKUP"; chmod 700 "$BACKUP"
    if [[ -f $WORK/state.before.json ]]; then cp "$WORK/state.before.json" "$BACKUP/state.before.json"; else cp "$STATE" "$BACKUP/state.before.json"; fi
    compose --profile '*' config --no-interpolate --no-env-resolution --format json > "$BACKUP/compose.before.json"
    local i=0 file; for file in "${FILES[@]}"; do cp -p "$file" "$BACKUP/original-$i"; i=$((i+1)); done
    [[ ! -f $DEPLOY/.env ]] || cp -L -p "$DEPLOY/.env" "$BACKUP/environment.before"
    docker inspect "$(compose ps --all --quiet "$(get mainService)")" > "$BACKUP/container.before.json"
    python3 - "$BACKUP" "${RUNNING_APPS[@]}" <<'PY'
import json,pathlib,shutil,sys
p=pathlib.Path(sys.argv[1]);s=json.load(open(p/'state.before.json'));c=json.load(open(p/'container.before.json'))[0]
s['image']=c['Config']['Image'];s['runningApplications']=sys.argv[2:];(p/'state.before.json').write_text(json.dumps(s,indent=2))
config=json.load(open(p/'compose.before.json'));files={}
for service in config['services'].values():
 for item in service.get('env_file',[]):
  f=pathlib.Path(item.get('path') if isinstance(item,dict) else item)
  if f.is_file():files[str(f.resolve())]=None
for i,path in enumerate(files):
 name='env-file-'+str(i);shutil.copyfile(path,p/name);files[path]=name
(p/'env-files.json').write_text(json.dumps(files,indent=2))
PY
    if [[ $COMPONENT == panel ]]; then step 'Согласованная копия PostgreSQL' backup_panel_data; fi
    find "$BACKUP" -maxdepth 1 -type f -exec chmod 600 {} +
    backup_hashes
    info "Резервная копия: $BACKUP"
}
recover() {
    local result=$?; trap - ERR; set +e
    operation_log_event ERROR "exit=$result line=${BASH_LINENO[0]} functions=${FUNCNAME[*]} rollback=$CHANGED database-changed=$DB_CHANGED"
    if $CHANGED && [[ -n $BACKUP ]]; then
        if [[ $COMPONENT == node ]] || ! $DB_CHANGED; then
            if [[ $COMPONENT == node ]] && ! compose stop "${APPS[@]}" >> "$LOG" 2>&1; then
                info 'Не удалось остановить новую ноду; автоматический откат не запускает второй экземпляр'
                exit "${result:-1}"
            fi
            helper restore-compose --directory "$BACKUP" >> "$LOG" 2>&1 || { info 'Не удалось восстановить Compose; приложения не запускаются'; exit "${result:-1}"; }
            STATE="$BACKUP/state.before.json"; load_state
            if [[ $COMPONENT == node ]] && ! verify_node_image_policy >> "$LOG" 2>&1; then
                info 'Предыдущий образ не поддерживает сохранённые квоты или состояние портов; нода оставлена остановленной. Установите совместимый выпуск, не обнуляя состояние.'
                exit "${result:-1}"
            fi
            if ! compose up -d --no-deps --no-build --pull never "${START_APPS[@]}" >> "$LOG" 2>&1; then
                info 'Предыдущую версию не удалось запустить; сохранённое состояние не обнулялось'
                exit "${result:-1}"
            fi
            if ! wait_ready >> "$LOG" 2>&1; then
                info 'Готовность предыдущей версии не подтверждена; проверьте status и журнал'
                exit "${result:-1}"
            fi
            if ! helper_file_copy "$STATE" "$ROOT/registry/$COMPONENT.json" >> "$LOG" 2>&1; then
                info 'Предыдущая версия запущена, но реестр управления не обновился; сохраните журнал и проверьте status'
                exit "${result:-1}"
            fi
            info 'Возвращена предыдущая конфигурация приложения; проверьте status'
        else
            compose stop "${APPS[@]}" >> "$LOG" 2>&1
            printf '%s  Процессы панели остановлены. Копия: %s\n  Восстановление: remnacust restore-panel --backup %q%s\n' "$ROSE" "$BACKUP" "$BACKUP" "$RESET" >&2
        fi
    fi
    printf '%s  Операция не завершена; журнал: %s%s\n' "$ROSE" "$LOG" "$RESET" >&2
    exit "${result:-1}"
}
verify_node_image_policy() {
    # The probe has no public ports and starts no daemon. An old image must not
    # silently ignore reserves already issued to this persistent node state.
    compose run --rm --no-deps --pull never -T --entrypoint node "$(get mainService)" -e '
const fs=require("node:fs");let policy={};
try{policy=JSON.parse(fs.readFileSync("/var/lib/remnanode/host-policy.json","utf8"));}
catch(error){if(error.code!=="ENOENT")process.exit(2);}
const required=[];
const userQuota="remnacust-user-quota-reserves-v1";let userRequired=false;
function privateState(file,limit){
 let info;try{info=fs.lstatSync(file);}catch(error){if(error.code==="ENOENT")return null;throw error;}
 if(!info.isFile()||info.isSymbolicLink()||info.size>limit)throw Error("Invalid private quota state");
 const parent=fs.lstatSync(require("node:path").dirname(file)),uid=process.getuid?.();if(!parent.isDirectory()||parent.isSymbolicLink()||((info.mode|parent.mode)&0o077)||(uid!==undefined&&(info.uid!==uid||parent.uid!==uid)))throw Error("Quota state must remain private");
 const fd=fs.openSync(file,fs.constants.O_RDONLY|(fs.constants.O_NOFOLLOW||0)|(fs.constants.O_NONBLOCK||0));
 try{const opened=fs.fstatSync(fd);if(!opened.isFile()||opened.dev!==info.dev||opened.ino!==info.ino||opened.size>limit)throw Error("Private state changed");const data=Buffer.alloc(limit+1);let count=0;while(count<data.length){const n=fs.readSync(fd,data,count,data.length-count,count);if(n===0)break;count+=n;}if(count>limit)throw Error("Private state too large");return data.subarray(0,count);}finally{fs.closeSync(fd);}
}
try{
 const portPlan=privateState("/var/lib/remnanode/core/port-plan-state.json",1024);
 if(portPlan){
  const state=JSON.parse(portPlan.toString());
  const counter=value=>typeof value==="string"&&/^[1-9][0-9]{0,18}$/.test(value)&&BigInt(value)<=9223372036854775807n;
  if(!state||![1,2].includes(state.version)||!counter(state.revision)||typeof state.enabled!=="boolean"||typeof state.required!=="boolean"||
   (state.appliedRevision!==null&&(!counter(state.appliedRevision)||BigInt(state.appliedRevision)>BigInt(state.revision)))||
   (state.enabled&&!state.required)||(state.appliedRevision===state.revision&&state.required!==state.enabled))process.exit(4);
  if(state.version===2){
   const capability="remnacust-port-plan-delivery-v2",boot=require("/etc/s6-overlay/scripts/core-boot.cjs");
   if(boot.PORT_PLAN_DELIVERY_CAPABILITY!==capability||typeof boot.validateSavedPortPlan!=="function")process.exit(4);
   boot.validateSavedPortPlan(state);
   const file="/opt/app/dist/main.js",info=fs.lstatSync(file);
   if(!info.isFile()||info.isSymbolicLink()||info.size>64*1024*1024)process.exit(4);
   const fd=fs.openSync(file,fs.constants.O_RDONLY|(fs.constants.O_NOFOLLOW||0)|(fs.constants.O_NONBLOCK||0));
   try{
    const opened=fs.fstatSync(fd);if(!opened.isFile()||opened.dev!==info.dev||opened.ino!==info.ino||opened.size>64*1024*1024)process.exit(4);
    const data=Buffer.alloc(opened.size+1);let count=0;while(count<data.length){const n=fs.readSync(fd,data,count,data.length-count,count);if(n===0)break;count+=n;}
    if(count!==opened.size||!data.subarray(0,count).includes(Buffer.from(capability)))process.exit(4);
   }finally{fs.closeSync(fd);}
  }else if(state.delivery!==undefined||state.pluginDirty!==undefined||state.appliedInputsHash!==undefined||state.desiredPluginHash!==undefined)process.exit(4);
  if(state.required)required.push("remnacust-live-ports-v1");
 }
 const recoveryRequired=privateState("/var/lib/remnanode/quota/recovery-required.json",8192);
 let recovery;try{recovery=privateState("/var/lib/remnanode/quota/recovery.json",8192);}catch(error){if(!recoveryRequired)throw error;recovery=Buffer.from("{}");}
 if(recovery||recoveryRequired){
  const capability="remnacust-quota-recovery-fence-v1",boot=require("/etc/s6-overlay/scripts/core-boot.cjs");
  if(boot.QUOTA_RECOVERY_FENCE!==capability||typeof boot.verifyRecoveryState!=="function")process.exit(4);
  boot.verifyRecoveryState(recoveryRequired,recovery);required.push(capability);
  const file="/opt/app/dist/main.js",info=fs.lstatSync(file);
  if(!info.isFile()||info.isSymbolicLink()||info.size>64*1024*1024)process.exit(4);
  const fd=fs.openSync(file,fs.constants.O_RDONLY|(fs.constants.O_NOFOLLOW||0)|(fs.constants.O_NONBLOCK||0));
  try{
   const opened=fs.fstatSync(fd);if(!opened.isFile()||opened.dev!==info.dev||opened.ino!==info.ino||opened.size>64*1024*1024)process.exit(4);
   const data=Buffer.alloc(opened.size+1);let count=0;while(count<data.length){const n=fs.readSync(fd,data,count,data.length-count,count);if(n===0)break;count+=n;}
   if(count!==opened.size||!data.subarray(0,count).includes(Buffer.from(capability)))process.exit(4);
  }finally{fs.closeSync(fd);}
 }
 const marker=privateState("/var/lib/remnanode/quota/user-quota-required",128);
 const ledger=privateState("/var/lib/remnanode/quota/ledger.json",16*1024*1024);
 let registered=false,watermarked=false;
 if(ledger){
  const frames=ledger.toString().split("\n");if(frames.length>1&&frames.at(-1)!=="")process.exit(2);
  for(let i=0;i<frames.length;i++){
   const frame=frames[i];if(!frame&&i===frames.length-1&&i>0)break;
   const record=JSON.parse(frame),start=frame.indexOf("\"payload\":"),end=frame.lastIndexOf(",\"sha256\":");
   if(start<0||end<start||require("node:crypto").createHash("sha256").update(frame.slice(start+10,end)).digest("hex")!==record.sha256||
    !["remnacust-quota-reserves-v1","remnacust-quota-registrations-v1","remnacust-quota-watermarks-v1"].includes(record.payload?.version)||
    (registered&&record.payload.version==="remnacust-quota-reserves-v1")||
    (watermarked&&record.payload.version!=="remnacust-quota-watermarks-v1"))process.exit(2);
   registered=record.payload.version!=="remnacust-quota-reserves-v1";
   watermarked=record.payload.version==="remnacust-quota-watermarks-v1";
  }
 }
 if(registered||policy.quotaRegistrations){
  const capability="remnacust-quota-registrations-v1";
  if(policy.quotaRegistrations!==capability||policy.offlineReserves!=="remnacust-quota-reserves-v1")process.exit(2);
  const boot=require("/etc/s6-overlay/scripts/core-boot.cjs");
  if(boot.QUOTA_REGISTRATION_CAPABILITY!==capability||typeof boot.registeredQuotaJournal!=="function")process.exit(4);
  const bundlePath="/opt/app/dist/main.js",bundleInfo=fs.lstatSync(bundlePath);
  if(!bundleInfo.isFile()||bundleInfo.isSymbolicLink()||bundleInfo.size>64*1024*1024)process.exit(4);
  const bundle=fs.readFileSync(bundlePath);
  if(bundle.length>64*1024*1024||!bundle.includes(Buffer.from(capability)))process.exit(4);
  required.push(capability);
 }
 if(watermarked||policy.quotaCheckpoint){
  const capability="remnacust-quota-watermarks-v1",boot=require("/etc/s6-overlay/scripts/core-boot.cjs");
  if(boot.QUOTA_WATERMARK_CAPABILITY!==capability||typeof boot.quotaJournalCheckpoint!=="function"||typeof boot.verifyQuotaCheckpoint!=="function")process.exit(4);
  boot.verifyQuotaCheckpoint(policy,boot.quotaJournalCheckpoint(ledger));
  const file="/opt/app/dist/main.js",info=fs.lstatSync(file);
  if(!info.isFile()||info.isSymbolicLink()||info.size>64*1024*1024)process.exit(4);
  const bytes=fs.readFileSync(file);if(bytes.length>64*1024*1024||!bytes.includes(Buffer.from(capability)))process.exit(4);
  required.push(capability);
 }
 if(marker){if(marker.toString()!==userQuota+"\n")process.exit(2);userRequired=true;}
 const cached=privateState("/var/lib/remnacust/run/core-state/checkpoint.pb",16*1024*1024+128);
 if(cached){
  const global="REMNACUST-CORE-STATE-2-USER-QUOTA\n",legacy="REMNACUST-CORE-STATE-1\n";
  const header=cached.subarray(0,global.length).toString()===global?global:legacy;
  const checksum=cached.subarray(header.length,header.length+64).toString(),payload=cached.subarray(header.length+65);
  if(cached.subarray(0,header.length).toString()!==header||!/^[a-f0-9]{64}$/.test(checksum)||cached[header.length+64]!==10||payload.length>16*1024*1024||require("node:crypto").createHash("sha256").update(payload).digest("hex")!==checksum)process.exit(2);
  userRequired ||= header===global;
 }
}catch{process.exit(2);}
if(userRequired||policy.userQuota){if(policy.userQuota!==userQuota)process.exit(2);required.push(userQuota);}
try{fs.lstatSync("/var/lib/remnanode/usage");required.push("remnacust-usage-receipts-v1");}
catch(error){if(error.code!=="ENOENT")process.exit(2);}
if(policy.offlineReserves){
 if(policy.offlineReserves!=="remnacust-quota-reserves-v1")process.exit(3);
 required.push("remnacust-quota-reserves-v1");
}
if(Object.values(policy.groups??{}).some(group=>group?.fenceAll===true||Object.values(group?.fencedOwners??{}).includes(true)))required.push("remnacust-quota-fences-v1");
if(required.some(marker=>marker===userQuota||marker==="remnacust-usage-receipts-v1"||marker==="remnacust-quota-reserves-v1"))required.push("remnacust-unreserved-usage-v1");
if(required.length){
 try{
  const details=fs.statSync("/usr/local/bin/xray");if(!details.isFile()||details.size>192*1024*1024)process.exit(3);
  const binary=fs.readFileSync("/usr/local/bin/xray");
  if(required.some(marker=>!binary.includes(Buffer.from(marker))))process.exit(3);
 }catch{process.exit(3);}
}
'
}
install_cli() {
    local bin_directory=${1:-/usr/local/bin} cache_directory=${2:-/usr/local/lib/remnacust-installer/helpers} temporary
    prepare_helpers_install "$cache_directory"
    bash -n "$WORK/installer-entry.sh"
    install -d -m 0755 "$bin_directory"
    temporary=$(mktemp "$bin_directory/.remnacust.XXXXXXXX")
    if ! install -m 0755 "$WORK/installer-entry.sh" "$temporary"; then rm -f -- "$temporary"; return 1; fi
    mv -f -- "$temporary" "$bin_directory/remnacust"
    ln -sfn "$bin_directory/remnacust" "$bin_directory/remnacust-installer"
    ln -sfn "$bin_directory/remnacust" "$bin_directory/remnacust-setup"
}
configure_panel_updates() {
    [[ $COMPONENT == panel && -f $HELPER_ROOT/update-agent.py ]] || return 0
    if [[ ! -d /run/systemd/system ]]; then
        info 'Обновление из панели требует systemd; обновление через remnacust доступно'
        return 0
    fi
    prepare_helpers_install
    local target=$1
    local -a options=()
    [[ ! -f $WORK/container.before.json ]] || options+=(--inspect "$WORK/container.before.json")
    python3 -B "$INSTALLED_HELPER_ROOT/update-agent.py" --root "$ROOT" setup --state "$STATE" --compose "$target" "${options[@]}" >> "$LOG" 2>&1
}
management_menu() {
    local choice
    terminal_section 'Выберите компонент'
    terminal_action 1 'Панель' ''
    terminal_action 2 'Нода' ''
    terminal_action 3 'Страница подписки' ''
    terminal_action 0 'Назад' ''
    choice=$(ask_menu_choice 3) || return $?
    case "$choice" in
        1) COMPONENT=panel;; 2) COMPONENT=node;; 3) COMPONENT=subscription-page;; 0) ACTION=''; return 0;;
    esac
    component_menu
}
component_title() {
    case "$COMPONENT" in panel) printf 'Панель';; node) printf 'Нода';; subscription-page) printf 'Страница подписки';; esac
}
component_menu() {
    local choice maximum=7
    terminal_section "Управление · $(component_title)"
    terminal_action 1 'Состояние' status
    terminal_action 2 'Адреса и файлы настроек' show-config
    terminal_action 3 'Журнал приложения' logs
    terminal_action 4 'Запустить' start
    terminal_action 5 'Остановить' stop
    terminal_action 6 'Перезапустить' restart
    terminal_action 7 'Сменить домен и сертификат' change-domain
    if [[ $COMPONENT == panel ]]; then
        terminal_action 8 'Перечитать сертификат' renew-panel-certificate
        maximum=8
    elif [[ $COMPONENT == node ]]; then
        terminal_action 8 'Перечитать сертификат' renew-node-certificate
        terminal_action 9 'Выбрать другой случайный сайт' configure-node-site
        maximum=9
    elif [[ $COMPONENT == subscription-page ]]; then
        terminal_action 8 'Удалить страницу; сохранить настройки и данные' uninstall-subscription-page
        terminal_action 9 'Сменить панель и API-токен' configure-subscription-page
        maximum=9
    fi
    terminal_action 0 'Назад' ''
    choice=$(ask_menu_choice "$maximum") || return $?
    case "$choice" in
        1) ACTION=status;; 2) ACTION=show-config;; 3) ACTION=logs;; 4) ACTION=start;;
        5) ACTION=stop;; 6) ACTION=restart;; 7) ACTION=change-domain;;
        8) if [[ $COMPONENT == subscription-page ]]; then ACTION=uninstall-subscription-page; else ACTION=renew-$COMPONENT-certificate; fi;;
        9) if [[ $COMPONENT == node ]]; then ACTION=configure-node-site; else ACTION=configure-subscription-page; fi;; 0) ACTION='';;
    esac
}
service_menu() {
    local selected_component
    terminal_section 'Компонент для обслуживания'
    terminal_action 1 'Панель' ''; terminal_action 2 'Нода' ''; terminal_action 3 'Страница подписки' ''; terminal_action 0 'Назад' ''
    selected_component=$(ask_menu_choice 3) || return $?
    case "$selected_component" in
        1) COMPONENT=panel;; 2) COMPONENT=node;; 3) COMPONENT=subscription-page; component_menu; return;; 0) ACTION=''; return 0;;
    esac
    local panel_available=false node_available=false current_available=false
    local panel_note='Панель не установлена' node_note='Нода не установлена' current_note='Компонент не найден'
    if component_installed panel; then panel_available=true; panel_note=''; fi
    if component_installed node; then node_available=true; node_note=''; fi
    case "$COMPONENT" in
        panel) current_available=$panel_available; current_note=$panel_note;;
        node) current_available=$node_available; current_note=$node_note;;
    esac
    terminal_section "Обслуживание · $(component_title)"
    terminal_action 1 'Проверить состояние' status "$current_note" "$current_available"
    terminal_action 2 'Журнал приложения' logs "$current_note" "$current_available"
    terminal_action 3 'Запустить' start "$current_note" "$current_available"
    terminal_action 4 'Остановить' stop "$current_note" "$current_available"
    terminal_action 5 'Перезапустить' restart "$current_note" "$current_available"
    terminal_action 6 'Создать копию панели' backup-panel "$panel_note" "$panel_available"
    terminal_action 7 'Восстановить из копии' restore-panel "$panel_note" "$panel_available"
    terminal_action 8 'Сертификат ноды' renew-node-certificate "$node_note" "$node_available"
    terminal_action 9 'Проверить панель' check-panel "$panel_note" "$panel_available"
    terminal_action 10 'Сертификат панели' renew-panel-certificate "$panel_note" "$panel_available"
    terminal_action 0 'Назад' ''
    terminal_rule
    local choice
    choice=$(ask_menu_choice 10) || return $?
    case "$choice" in 1) ACTION=status;;2) ACTION=logs;;3) ACTION=start;;4) ACTION=stop;;5) ACTION=restart;;6) ACTION=backup-panel;;7) ACTION=restore-panel;;8) ACTION=renew-node-certificate; COMPONENT=node;;9) ACTION=check-panel; COMPONENT=panel;;10) ACTION=renew-panel-certificate; COMPONENT=panel;;0) ACTION='';;esac
}
select_managed_page() {
    [[ -z $PAGE_ID ]] || return 0
    local count choice
    python3 -I "$HELPER_ROOT/subscription_pages.py" list --root "$ROOT" > "$WORK/managed-pages.json"
    count=$(python3 - "$WORK/managed-pages.json" <<'PY'
import json,sys
print(len(json.load(open(sys.argv[1]))))
PY
    )
    ((count > 0)) || die 'Зарегистрированных страниц подписки нет'
    python3 - "$WORK/managed-pages.json" <<'PY'
import json,sys
states={'running':'работает','healthy':'работает, исправна','exited':'остановлена','created':'создана, не запущена','missing':'контейнер отсутствует, сохранены только настройки','unavailable':'состояние Docker недоступно','unhealthy':'неисправна','restarting':'перезапускается','starting':'запускается','dead':'аварийно остановлена','paused':'приостановлена'}
for number,item in enumerate(json.load(open(sys.argv[1])),1):
 print(f"  {number:2}  {item['name']} · {item['domain']} · {states.get(item['status'],item['status'])}")
print('   0  Назад')
PY
    choice=$(ask_menu_choice "$count") || return $?
    [[ $choice != 0 ]] || return 1
    PAGE_ID=$(python3 - "$WORK/managed-pages.json" "$choice" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))[int(sys.argv[2])-1]['id'])
PY
    )
}
domain_plan_value() {
    python3 - "$DOMAIN_PLAN" "$1" <<'PY'
import json,sys
value=json.load(open(sys.argv[1])).get(sys.argv[2],'')
print(value if isinstance(value,str) else json.dumps(value))
PY
}
manage_component_action() {
    local requested_component=${COMPONENT:-panel} requested_domain=${DOMAIN:-${NODE_DOMAIN:-}} method
    local -a options=()
    [[ $requested_component != subscription-page ]] || select_managed_page || return $?
    [[ -z $PAGE_ID ]] || options=(--page-id "$PAGE_ID")
    if [[ $ACTION == show-config ]]; then
        python3 -I "$HELPER_ROOT/management.py" info --root "$ROOT" --component "$requested_component" "${options[@]}"
        return
    fi
    if ! $NODE_MIGRATION_TLS; then
        requested_domain=$(ask_confirmed_domain 'Новый домен (без https:// и пути)' "$requested_domain") || return $?
        confirm "Сменить домен $requested_component на $requested_domain"
    elif [[ -n $TLS_METHOD ]]; then options+=(--tls-method "$TLS_METHOD"); fi
    if [[ $requested_component == node && -z $PANEL_IP ]] && ! $NODE_MIGRATION_TLS; then
        PANEL_IP=$(python3 -I "$HELPER_ROOT/node_firewall.py" owned-panel --owner-root "$ROOT") || return $?
    fi
    if [[ $requested_component == node && -z $PANEL_IP ]]; then options+=(--no-firewall); fi
    if [[ $requested_component == node && -n $NODE_SITE_MODE ]]; then
        options+=(--site-mode "$NODE_SITE_MODE" --site-port "${NODE_SITE_PORT:-443}" --inbound-port "${NODE_INBOUND_PORT:-8443}")
    fi
    DOMAIN_PLAN=$(python3 -I "$HELPER_ROOT/management.py" prepare --root "$ROOT" --component "$requested_component" --domain "$requested_domain" "${options[@]}") || return $?
    info "Копия настроек: ${DOMAIN_PLAN%/plan.json}"
    method=$(domain_plan_value method) || return $?
    [[ -z $TLS_METHOD || $TLS_METHOD == "$method" ]] || die 'При смене домена сохраняется способ TLS. Для другого способа сначала настройте сертификат отдельно.'
    TLS_METHOD=$method
    PROJECT=$(domain_plan_value project) || return $?; DEPLOY=$(domain_plan_value directory) || return $?
    COMPONENT=$(domain_plan_value tlsComponent) || return $?; DOMAIN=$(domain_plan_value certificateDomain) || return $?
    PROXY=caddy; NODE_DOMAIN=''; [[ $COMPONENT != node ]] || NODE_DOMAIN=$DOMAIN
    STATE="$WORK/domain-state.json"; domain_plan_value tlsState > "$STATE" || return $?
    SUBSCRIPTION_URLS=$(domain_plan_value certificateSubscriptions) || return $?
    SUBSCRIPTION_PAGE=false; [[ -z $SUBSCRIPTION_URLS ]] || SUBSCRIPTION_PAGE=true
    if [[ $TLS_METHOD == auto || $TLS_METHOD == http ]]; then check_dns "$requested_domain" || return 1; fi
    if [[ $TLS_METHOD == existing ]]; then
        [[ -n $CERT_FILE ]] || CERT_FILE=$(ask_required 'Сертификат для нового домена: путь к fullchain.pem') || return $?
        [[ -n $KEY_FILE ]] || KEY_FILE=$(ask_required 'Приватный ключ: путь к privkey.pem') || return $?
    elif [[ $TLS_METHOD != auto ]]; then
        if [[ -z $EMAIL ]]; then
            while true; do
                EMAIL=$(ask_required "Email для Let's Encrypt") || return $?
                [[ $EMAIL =~ ^[A-Za-z0-9_.+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] && break
                printf '  Некорректный email, повторите ввод.\n' >&2
            done
        fi
        [[ $EMAIL =~ ^[A-Za-z0-9_.+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die 'Некорректный email'
        if [[ $TLS_METHOD == cloudflare || $TLS_METHOD == gcore ]]; then
            DNS_CREDENTIALS=${DNS_CREDENTIALS:-$ROOT/acme/$PROJECT/dns.ini}
            [[ -f $DNS_CREDENTIALS ]] || DNS_CREDENTIALS=$(ask_required 'Путь к INI DNS-провайдера (права 600)') || return $?
        fi
        if [[ $TLS_METHOD == http ]]; then
            python3 -I "$HELPER_ROOT/management.py" stop-proxy --root "$ROOT" --plan "$DOMAIN_PLAN" || return $?
        fi
        obtain_certificate || return $?
    fi
    local -a certificate=()
    [[ $TLS_METHOD == auto ]] || certificate=(--certificate "$CERT_FILE" --key "$KEY_FILE")
    info 'Применяем адрес и проверяем готовность приложений.'
    python3 -I "$HELPER_ROOT/management.py" apply --root "$ROOT" --plan "$DOMAIN_PLAN" "${certificate[@]}" || return $?
    if [[ $TLS_METHOD != auto ]]; then
        STATE="$ROOT/registry/$COMPONENT.json"
        schedule_certificate_renewal || return $?
    fi
    info 'Проверяем новый HTTPS-адрес (до 2 минут для работающего Caddy).'
    python3 -I "$HELPER_ROOT/management.py" complete --root "$ROOT" --plan "$DOMAIN_PLAN" || return $?
    info "Новый домен: https://$requested_domain"
    [[ $requested_component != node ]] || info 'Обновите адрес и SNI этой ноды в хостах панели; существующие ссылки клиента сами домен не меняют.'
    DOMAIN_PLAN=''
}
node_migration_wizard() {
    local previous choice
    [[ $ACTION == migrate-remnawave-node ]] || return 0
    PORT=$(get apiPort)
    info "Сохраняем ключ панели, порт API $PORT, конфигурацию Xray и данные ноды."
    previous=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("nodeDomain", ""))' "$STATE")
    if [[ -n $previous && -z $NODE_DOMAIN$TLS_METHOD$CERT_FILE$KEY_FILE$DNS_CREDENTIALS$EMAIL$NODE_SITE_MODE$NODE_SITE_PORT$NODE_INBOUND_PORT ]]; then
        if [[ ! -t 0 ]] || $YES; then return 0; fi
        choice=$(ask_yes_no "TLS/XHTTP уже настроен для $previous. Изменить настройки?") || return $?
        [[ $choice == yes ]] || return 0
        NODE_DOMAIN=$(ask_confirmed_domain 'Домен ноды' "$previous") || return $?
        NODE_DOMAIN_CONFIRMED=$NODE_DOMAIN
    elif [[ -n $NODE_DOMAIN ]]; then
        NODE_DOMAIN=$(ask_confirmed_domain 'Домен ноды' "$NODE_DOMAIN") || return $?
        NODE_DOMAIN_CONFIRMED=$NODE_DOMAIN
    elif [[ -n $previous ]]; then
        NODE_DOMAIN=$(ask_confirmed_domain 'Домен ноды' "$previous") || return $?
        NODE_DOMAIN_CONFIRMED=$NODE_DOMAIN
    fi
    certificate_wizard || return $?
    if [[ -n $NODE_DOMAIN ]]; then
        NODE_MIGRATION_TLS=true
        certificate_preflight || return $?
        dns_preflight || return $?
    fi
}
node_migration_finish() {
    [[ $ACTION == migrate-remnawave-node ]] || return 0
    if [[ -z $PANEL_IP ]]; then
        node_acl_without_panel || return $?
        local renewal_project
        renewal_project=$(get project) || return $?
        if [[ -n $renewal_project ]]; then
            python3 -I "$HELPER_ROOT/node_firewall.py" detach-renewal --owner-root "$ROOT" --project "$renewal_project" || return $?
        fi
    fi
    if $NODE_MIGRATION_TLS; then
        local ACTION=change-domain DOMAIN=$NODE_DOMAIN
        info 'Нода перенесена. Настраиваем сайт и TLS/XHTTP с сохранением её данных.'
        if ! manage_component_action; then
            printf 'Перенос ноды завершён, но настройка TLS/XHTTP не завершена. Нода и исходные данные сохранены; подробности в журнале.\n' >&2
            return 1
        fi
        STATE="$ROOT/registry/node.json"; load_state
    fi
    node_acl
}
configure_node_site() {
    COMPONENT=node
    installed_helper; lock_operation
    STATE="$ROOT/registry/node.json"
    [[ -f $STATE && ! -L $STATE ]] || die 'Нода не зарегистрирована'
    load_state; assert_not_uninstalled
    if retired_installation node; then die 'Нода удалена. Сначала установите её заново; файлы сайта не изменены.'; fi
    local domain id status running=false
    domain=$(get nodeDomain)
    [[ -n $domain && " ${EXTRAS[*]} " == *' node-nginx '* ]] || die 'Сначала настройте домен и сайт selfsteal для ноды'
    confirm 'Заменить сайт случайным вариантом? Текущие файлы сохранятся в резервной копии'
    if ! id=$(compose ps --all --quiet node-nginx); then die 'Не удалось проверить состояние сайта. Файлы не изменены.'; fi
    if [[ -n $id ]]; then
        if ! status=$(docker inspect --format '{{.State.Running}}' "$id"); then die 'Не удалось проверить контейнер сайта. Файлы не изменены.'; fi
        case "$status" in true) running=true;; false) ;; *) die 'Неизвестное состояние контейнера сайта. Файлы не изменены.';; esac
    fi
    python3 -I "$HELPER_ROOT/node_site.py" --directory "$DEPLOY" --domain "$domain" --template random --replace --backup-root "$ROOT/backups/node-sites" > "$WORK/node-site-result.json"
    if $running; then
        if ! compose up -d --no-deps --no-build --pull never --force-recreate node-nginx || ! compose exec -T node-nginx nginx -t; then
            local -a rollback=()
            mapfile -t rollback < <(python3 - "$WORK/node-site-result.json" <<'PY'
import json,sys
result=json.load(open(sys.argv[1]))
if result.get('backup') and result.get('generation'):
    print(result['backup'])
    print(result['generation'])
PY
            )
            if ((${#rollback[@]} == 2)) && python3 -I "$HELPER_ROOT/node_site.py" --directory "$DEPLOY" --restore "${rollback[0]}" --expected-generation "${rollback[1]}" --backup-root "$ROOT/backups/node-sites" > "$WORK/node-site-rollback.json"; then
                if compose up -d --no-deps --no-build --pull never --force-recreate node-nginx && compose exec -T node-nginx nginx -t; then
                    info 'Новый сайт не запущен; предыдущий сайт восстановлен.'
                else info 'Предыдущие файлы восстановлены. Nginx не запущен; проверьте Docker и журнал.'; fi
            else info 'Не удалось перезапустить сайт. Проверьте журнал и сохранённую резервную копию.'; fi
            return 1
        fi
    fi
    python3 - "$WORK/node-site-result.json" <<'PY'
import json,sys
result=json.load(open(sys.argv[1]))
print('  Сайт обновлён. Файлы: '+result['directory'])
if result.get('backup'): print('  Предыдущий сайт: '+result['backup'])
PY
}
main() {
    local result
    parse_args "$@" || { result=$?; [[ $result == 10 ]] && return 0; return "$result"; }
    if [[ -z $ACTION ]]; then
        interactive_menu "$@"
        return
    fi
    case "$ACTION" in manage-panel) COMPONENT=panel; component_menu;; manage-node) COMPONENT=node; component_menu;; esac
    [[ -n $ACTION ]] || return 0
    run_action
}
interactive_menu() {
    local choice
    local -a selection=()
    WORK=$(mktemp -d -t remnacust-menu.XXXXXXXX)
    touch "$WORK/.installer-owned"; trap cleanup EXIT
    while true; do
        ACTION=''; COMPONENT=''
        show_menu
        choice=$(ask_menu_choice 17) || return $?
        case "$choice" in
            1) ACTION=install-panel;;
            2) ACTION=install-node;;
            3) ACTION=install-subscription-page;;
            4) ACTION=upgrade-panel;;
            5) ACTION=upgrade-node;;
            6) ACTION=upgrade-subscription-page;;
            7) ACTION=migrate-remnawave-panel;;
            8) ACTION=migrate-remnawave-node;;
            9) ACTION=migrate-marzban-panel;;
            10) ACTION=migrate-remnawave-subscription-page;;
            11) ACTION=--check-release;;
            12) ACTION=status;;
            13) management_menu || return $?;;
            14) service_menu || return $?;;
            15) ACTION=uninstall-panel;;
            16) ACTION=uninstall-node;;
            17) ACTION=uninstall-subscription-page;;
            0) return 0;;
        esac
        [[ -n $ACTION ]] || { discard_pending_input; continue; }
        selection=("$ACTION")
        [[ -z $COMPONENT ]] || selection+=(--component "$COMPONENT")
        # A separate shell preserves errexit and confines exit/traps/locks to one action.
        if REMNACUST_MENU_COMPLETION_FD=3 bash "${BASH_SOURCE[0]}" "${selection[@]}" "$@" 3> "$WORK/menu-completed"; then
            [[ ! -s $WORK/menu-completed ]] || return 0
            discard_pending_input
            info 'Возврат в меню'
        else
            discard_pending_input
            info 'Действие не завершено. Исправьте указанную причину и повторите его в меню.'
        fi
    done
}
cleanup_backups_action() {
    installed_helper; lock_operation
    local -a cleanup_options=()
    [[ -z $COMPONENT ]] || cleanup_options=(--component "$COMPONENT")
    python3 -I "$HELPER_ROOT/deployment_layout.py" --root "$ROOT" --cleanup-backups "${cleanup_options[@]}"
}
run_action() {
    local result
    WORK=$(mktemp -d -t remnacust-installer.XXXXXXXX); touch "$WORK/.installer-owned"; trap cleanup EXIT
    start_operation_log
    if [[ $ACTION == --check-release ]]; then
        for result in curl python3 tar; do command -v "$result" >/dev/null || die "Нужен $result"; done
        [[ -n $VERSION ]] || VERSION=latest
        installed_helper
        TAG=$(resolve_release); fetch_source
        if [[ -n ${REMNACUST_RELEASE_INFO_FILE:-} ]]; then
            python3 - "$WORK/source" "$TAG" "$REMNACUST_RELEASE_INFO_FILE" "$HELPER_ROOT" "$HELPER_ENTRY" <<'PY'
import json,sys,os,subprocess
from pathlib import Path
source=Path(sys.argv[1]);sys.path.insert(0,sys.argv[4])
import helper_bundle
lock=json.loads((source/'component-sources.json').read_text())
entry=os.environ.get('REMNACUST_RELEASE_ENTRY_FILE')
if entry:
    own=Path(sys.argv[5]).read_bytes();raw=helper_bundle.read(Path(sys.argv[4])/helper_bundle.CONTRACT,32768)
    files=helper_bundle.read_files(Path(sys.argv[4]),raw)
    if helper_bundle.version_key(sys.argv[2].removeprefix('v'))>helper_bundle.version_key(helper_bundle.manifest(raw)['version']):
        own,raw,files=helper_bundle.source_bundle(source)
    script=helper_bundle.render(own,raw,files)
    subprocess.run(['bash','-n'],input=script,check=True)
    Path(entry).write_bytes(script);Path(entry).chmod(0o600)
Path(sys.argv[3]).write_text(json.dumps({'installerVersion':sys.argv[2].removeprefix('v'),'panelVersion':lock['panel']['version']}))
PY
        fi
        info "Выпуск $TAG проверен"; return 0
    fi
    case "$ACTION" in configure-node-site) COMPONENT=node;; *subscription-page) COMPONENT=subscription-page;; *panel|renew-panel-certificate) COMPONENT=panel;; *node|renew-node-certificate) COMPONENT=node;; esac
    case "$ACTION" in
        *subscription-page) ;;
        upgrade-*)
            if ! component_installed "$COMPONENT" && [[ -z $CONTAINER ]]; then
                die "$COMPONENT не установлен. Сначала install-$COMPONENT; для существующего Remnawave используйте migrate-remnawave-$COMPONENT с --directory или --container."
            fi;;
        install-*) assert_fresh_target;;
    esac
    [[ $EUID == 0 && $(uname -s) == Linux ]] || die 'Нужен root на Linux'
    update_system_packages || return $?
    case "$ACTION" in
        change-domain|show-config) installed_helper; lock_operation; manage_component_action;;
        configure-node-site) configure_node_site;;
        status|logs|start|stop|restart)
            if [[ $COMPONENT == subscription-page ]]; then
                PAGE_OPERATION=$ACTION; ACTION=manage-subscription-page; subscription_page_action
            else service_action; fi;;
        normalize-layout) installed_helper; lock_operation; python3 -I "$HELPER_ROOT/deployment_layout.py" --root "$ROOT" --component "${COMPONENT:-panel}";;
        cleanup-backups) cleanup_backups_action;;
        install-subscription-page|upgrade-subscription-page|uninstall-subscription-page|manage-subscription-page|configure-subscription-page) subscription_page_action;;
        migrate-remnawave-subscription-page) migrate_subscription_page_action;;
        migrate-marzban-panel) migrate_marzban;;
        install-*|upgrade-*|migrate-*) deploy;;
        *) service_action;;
    esac
}

# Release validation and deployment functions are defined below.

resolve_release() {
    local endpoint
    if [[ $VERSION == latest ]]; then endpoint="latest?remnacust_check=$(python3 -c 'import uuid; print(uuid.uuid4().hex)')"
    else endpoint="tags/v${VERSION#v}"; fi
    download "https://api.github.com/repos/$REPO/releases/$endpoint" "$WORK/release.json" ||
        die "Релиз $VERSION недоступен в GitHub ($REPO). Проверьте публикацию релиза и сеть. Установка не изменена."
    python3 - "$WORK/release.json" "$REPO" "$VERSION" "$WORK/resolved.json" <<'PY'
import json, re, sys
release=json.load(open(sys.argv[1]))
repo, requested=sys.argv[2:4]
tag=release.get('tag_name','')
if not re.fullmatch(r'v\d+\.\d+\.\d+(?:-[A-Za-z0-9]+(?:[.-][A-Za-z0-9]+)*)?',tag):
    raise SystemExit('Неподдерживаемый тег: нужен vMAJOR.MINOR.PATCH')
if release.get('draft') or (requested=='latest' and release.get('prerelease')):
    raise SystemExit('latest должен быть опубликованным стабильным выпуском')
if requested!='latest' and tag!='v'+requested.removeprefix('v'):
    raise SystemExit('Версия ответа GitHub не совпадает с выбранной')
assets={a['name']:a for a in release.get('assets',[]) if a.get('state')=='uploaded'}
runtime=f'remnacust-runtime-{tag}.tar.gz'
name=runtime if runtime in assets else f'remnacust-source-{tag}.tar.gz'
expected=f'https://github.com/{repo}/releases/download/{tag}/'
result={'tag':tag,'archive':name,'kind':'runtime' if name==runtime else 'source'}
for key, asset_name in [('source',name),('checksums','SHA256SUMS')]:
    asset=assets.get(asset_name,{})
    url=asset.get('browser_download_url','')
    if url!=expected+asset_name: raise SystemExit('Отсутствует готовый файл релиза: '+asset_name)
    result[key]=url
    if key=='source': result['digest']=asset.get('digest')
json.dump(result,open(sys.argv[4],'w'))
print(tag)
PY
}
json_value() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$WORK/resolved.json" "$1"; }
fetch_source() {
    local archive
    archive=$(json_value archive)
    download "$(json_value checksums)" "$WORK/SHA256SUMS"
    download "$(json_value source)" "$WORK/$archive"
    python3 - "$WORK" "$archive" "$REPO" "$HELPER_ROOT/images.py" <<'PY'
import hashlib,json,pathlib,re,sys,tarfile
root=pathlib.Path(sys.argv[1]);name=sys.argv[2]
lines=(root/'SHA256SUMS').read_text().splitlines()
matches=[line for line in lines if line.endswith('  '+name)]
if len(matches)!=1 or not re.fullmatch(r'[a-f0-9]{64}  '+re.escape(name),matches[0]):
    raise SystemExit('Нет однозначной SHA-256 суммы исходников')
hasher=hashlib.sha256()
with (root/name).open('rb') as stream:
    for chunk in iter(lambda: stream.read(1024*1024), b''): hasher.update(chunk)
actual=hasher.hexdigest()
if actual!=matches[0].split()[0]: raise SystemExit('SHA-256 исходников не совпадает')
digest=json.load(open(root/'resolved.json')).get('digest')
if digest and digest!='sha256:'+actual: raise SystemExit('SHA-256 не совпадает с метаданными GitHub')
destination=root/'source';destination.mkdir()
with tarfile.open(root/name) as archive:
    members=archive.getmembers()
    if len(members)>50000 or sum(m.size for m in members)>1024**3: raise SystemExit('Архив исходников слишком большой')
    paths=set()
    for m in members:
        p=pathlib.PurePosixPath(m.name)
        if p.is_absolute() or '..' in p.parts or not (m.isdir() or m.isfile()):
            raise SystemExit('Небезопасный путь или тип файла в архиве: '+m.name)
        if p in paths: raise SystemExit('Повторяющийся путь в архиве')
        paths.add(p)
    archive.extractall(destination, members=members, filter='data') if sys.version_info >= (3,12) else archive.extractall(destination,members=members)
kind=json.load(open(root/'resolved.json'))['kind']
required_files=['installer/installer.sh','installer/runtime.py','installer/database.cjs','installer/marzban.py','panel/backend/.env.sample']
required_files+=['installer/images.py','images.json','component-sources.json'] if kind=='runtime' else ['panel/Dockerfile','node/docker/Dockerfile','xray/core/core.go']
for required in required_files:
    if not (destination/required).is_file(): raise SystemExit('Неполный архив: '+required)
version=json.load(open(root/'resolved.json'))['tag'][1:]
if (destination/'VERSION').read_text().strip()!=version:
    raise SystemExit('VERSION не совпадает с тегом')
lock_path=destination/'component-sources.json'
lock=json.loads(lock_path.read_text()) if lock_path.is_file() else {}
if lock_path.is_file() and (not isinstance(lock,dict) or set(lock)!={'panel','node','core'}):
    raise SystemExit('Неверный список компонентов выпуска')
versions={}
for kind in ['panel','node','core']:
    entry=lock.get(kind,{})
    if not isinstance(entry,dict): raise SystemExit('Неверный компонент: '+kind)
    expected=entry.get('version',version)
    version_pattern=r'\d+\.\d+\.\d+'+(r'(?:\.\d+)?' if kind=='panel' else '')+r'(?:-[A-Za-z0-9]+(?:[.-][A-Za-z0-9]+)*)?'
    if not isinstance(expected,str) or not re.fullmatch(version_pattern,expected):
        raise SystemExit('Неверная версия компонента: '+kind)
    versions[kind]=expected
if json.load(open(root/'resolved.json'))['kind']=='runtime':
    import subprocess
    subprocess.run([sys.executable,sys.argv[4],'validate','--root',str(destination),
        '--tag','v'+version,'--assets',str(root/'release.json'),'--repository',sys.argv[3]],check=True)
    (root/'source.sha256').write_text(actual+'\n')
    raise SystemExit(0)
for package in ['panel/frontend','panel/backend','node','subscription-page/frontend','subscription-page/backend']:
    actual_version=json.load(open(destination/package/'package.json'))['version']
    expected=versions['node' if package=='node' else 'panel']
    if actual_version!=expected:
        raise SystemExit('Версия исходников не совпадает с закреплённым компонентом: '+package)
core=(destination/'xray/core/core.go').read_text()
numbers=[re.search(rf'Version_{axis}\s+byte\s*=\s*(\d+)',core) for axis in 'xyz']
if not all(numbers) or '.'.join(m.group(1) for m in numbers)!=versions['core'].split('-')[0]:
    raise SystemExit('Версия Xray не совпадает с закреплённым компонентом')
(root/'source.sha256').write_text(actual+'\n')
PY
}

choose_version() {
    if [[ -z $VERSION ]]; then
        if [[ -t 0 ]] && ! $YES; then VERSION=$(ask 'Версия установки' latest); else VERSION=latest; fi
    fi
    valid_version "$VERSION" || die 'Версия: latest или SemVer'
}
release_source() {
    choose_version
    installed_helper
    if [[ $ACTION == install-panel ]]; then DOMAIN=$(ask_confirmed_domain 'Домен панели' "$DOMAIN") || return $?; fi
    if [[ $ACTION == install-node && -n $NODE_DOMAIN && $NODE_DOMAIN_CONFIRMED != "$NODE_DOMAIN" ]]; then
        NODE_DOMAIN=$(ask_confirmed_domain 'Домен ноды' "$NODE_DOMAIN") || return $?
        NODE_DOMAIN_CONFIRMED=$NODE_DOMAIN
    fi
    if [[ $ACTION == install-node && -z ${REMNACUST_NODE_SECRET:-} ]]; then
        ask_node_secret || return 1
    fi
    installed_helper
    prepare_helpers_install
    TAG=$(resolve_release)
    step "Проверка выпуска $TAG" fetch_source
    SOURCE="$WORK/source"
    bash -n "$SOURCE/installer/installer.sh"
    [[ -f $SOURCE/images.json ]] || die 'В этом старом выпуске нет готовых Docker-образов. Выберите latest; сборка на сервере отключена.'
    python3 "$HELPER_ROOT/images.py" select --root "$SOURCE" --tag "$TAG" --assets "$WORK/release.json" \
        --repository "$REPO" --component "$COMPONENT" --architecture "$(dpkg --print-architecture)" > "$WORK/image.json"
    IMAGE=$(image_field image)
    COMPONENT_VERSION=$(image_field version)
}
installed_helper() {
    [[ -z $HELPER_ROOT ]] || return 0
    HELPER_ROOT=$(python3 -I - "$ENTRY_SCRIPT_PATH" "$WORK" "$HELPER_BUNDLE_SHA256" <<'PY'
import base64,gzip,hashlib,io,json,pathlib,re,sys,tarfile
entry=pathlib.Path(sys.argv[1]).resolve();body=entry.read_bytes().replace(b'\r\n',b'\n');work=pathlib.Path(sys.argv[2]);expected=sys.argv[3]
destination=work/('helpers-'+expected);contract='helper-contract.json';footer=b'\n# REMNACUST_HELPERS_V1\n';cache=pathlib.Path('/usr/local/lib/remnacust-installer/helpers')
def read(path,limit):
    if path.is_symlink() or not path.is_file():raise ValueError('not a regular helper')
    with path.open('rb') as stream:data=stream.read(limit+1)
    if len(data)>limit:raise ValueError('helper too large')
    return data.replace(b'\r\n',b'\n')
def module(raw,code):
    if hashlib.sha256(raw).hexdigest()!=expected:raise ValueError('helper manifest mismatch')
    item=json.loads(raw)['files']['helper_bundle.py']
    if len(code)!=item['bytes'] or hashlib.sha256(code).hexdigest()!=item['sha256']:raise ValueError('helper verifier mismatch')
    namespace={'__name__':'verified_helper_bundle','__file__':'<verified helper_bundle.py>'}
    exec(compile(code,namespace['__file__'],'exec'),namespace)
    return namespace
def finish(raw,files,verified):
    verified['snapshot'](body,raw,files,destination)
    saved=work/('helper-entry-'+expected+'.sh');saved.write_bytes(body);saved.chmod(0o600)
    print(destination);raise SystemExit(0)
hints=re.findall(rb'(?m)^# CACHE ([a-f0-9]{64}(?:-[a-f0-9]{32})?)$',body)
locations=[entry.parent]+([cache/hints[0].decode()] if len(hints)==1 else [])+[cache/expected]
for location in locations:
    try:
        raw=read(location/contract,32768);verified=module(raw,read(location/'helper_bundle.py',2*1024*1024))
        finish(raw,verified['read_files'](location,raw,source=location==entry.parent and location.name=='installer'),verified)
    except (OSError,ValueError,KeyError,TypeError):pass
try:
    tail=body.split(footer)[1]
    encoded=b''.join(line[7:] for line in tail.splitlines() if line.startswith(b'# DATA '))
    if not encoded or len(encoded)>6*1024*1024:raise ValueError('invalid helper payload')
    with gzip.GzipFile(fileobj=io.BytesIO(base64.b64decode(encoded,validate=True))) as stream:data=stream.read(16*1024*1024+1)
    if len(data)>16*1024*1024:raise ValueError('helper payload too large')
    files={}
    with tarfile.open(fileobj=io.BytesIO(data),mode='r:') as archive:
        members=archive.getmembers()
        if len(members)>33:raise ValueError('too many helpers')
        for member in members:
            if not member.isfile() or member.size>2*1024*1024 or '/' in member.name or '\\' in member.name or member.name in files:raise ValueError('unsafe helper payload')
            files[member.name]=archive.extractfile(member).read()
    raw=files.pop(contract);verified=module(raw,files['helper_bundle.py']);finish(raw,files,verified)
except Exception:pass
raise SystemExit('Не найден проверенный комплект помощников этого скрипта. Используйте installer.sh из выпуска или полный каталог исходников; данные не изменены.')
PY
    ) || return $?
    HELPER="$HELPER_ROOT/runtime.py"
    HELPER_ENTRY="$WORK/helper-entry-$HELPER_BUNDLE_SHA256.sh"
}
prepare_helpers_install() {
    installed_helper
    [[ -z $INSTALLED_HELPER_ROOT ]] || return 0
    INSTALLED_HELPER_ROOT=$(python3 -I "$HELPER_ROOT/helper_bundle.py" install --entry "$HELPER_ENTRY" --cohort "$HELPER_ROOT" \
        --cache-root "${1:-/usr/local/lib/remnacust-installer/helpers}" --output "$WORK/installer-entry.sh")
}
lock_operation() {
    command -v flock >/dev/null || die 'Нужен util-linux (flock)'
    mkdir -p "$ROOT/registry"
    exec 9>"$ROOT/.installer.lock"
    flock -n 9 || die 'Другой установщик уже работает'
}
database_environment() {
    python3 - "$WORK/container.before.json" "$WORK/database.env" <<'PY'
import json,pathlib,sys
c=json.load(open(sys.argv[1]))[0];e=dict(x.split('=',1) for x in c['Config']['Env'] if '=' in x)
values={k:e[k] for k in ['DATABASE_URL','APP_SECRET'] if k in e}
if any('\n' in v or '\r' in v for v in values.values()):raise SystemExit('Unsupported database environment')
pathlib.Path(sys.argv[2]).write_text(''.join(k+'='+v+'\n' for k,v in values.items()))
PY
    python3 - "$WORK/container.before.json" "$WORK/database-networks.txt" <<'PY'
import json,pathlib,sys
c=json.load(open(sys.argv[1]))[0]
networks=c.get('NetworkSettings',{}).get('Networks') or {}
pathlib.Path(sys.argv[2]).write_text(''.join(name+'\n' for name in networks))
PY
    local network
    local -a ids=()
    : > "$WORK/database-peer-ids.txt"
    while IFS= read -r network; do
        docker ps --quiet --filter "network=$network" >> "$WORK/database-peer-ids.txt"
    done < "$WORK/database-networks.txt"
    mapfile -t ids < <(sort -u "$WORK/database-peer-ids.txt")
    if ((${#ids[@]})); then
        docker inspect "${ids[@]}" | python3 -c '
import json,sys
peers=json.load(sys.stdin)
json.dump([{"Id":c.get("Id"),"Name":c.get("Name"),
           "State":{"Running":c.get("State",{}).get("Running")},
           "NetworkSettings":{"Networks":c.get("NetworkSettings",{}).get("Networks") or {}}}
          for c in peers],sys.stdout)
' > "$WORK/network-containers.json"
    else printf '[]\n' > "$WORK/network-containers.json"; fi
    helper database-network --inspect "$WORK/container.before.json" --roles "$WORK/network-containers.json" \
        --network "${REMNACUST_DATABASE_NETWORK:-}" --target "$WORK/database.network"
}
database_run() {
    docker run --rm -i --network "$(cat "$WORK/database.network")" --env-file "$WORK/database.env" \
        --entrypoint node "$IMAGE" - "$@" < "$(dirname "$HELPER")/database.cjs"
}
verify_database() {
    # The verified helper script and the snapshot use separate input channels.
    docker run --rm -i --network "$(cat "$WORK/database.network")" --env-file "$WORK/database.env" \
        --mount "type=bind,src=$(dirname "$HELPER")/database.cjs,dst=/tmp/verify.cjs,readonly" \
        --entrypoint node "$IMAGE" /tmp/verify.cjs verify < "$BACKUP/fingerprints.json"
}
check_writers() {
    local -a ids=(); mapfile -t ids < <(docker ps --quiet)
    ((${#ids[@]})) || return 0
    docker inspect "${ids[@]}" > "$WORK/running-containers.json"
    python3 - "$WORK/running-containers.json" "$WORK/container.before.json" "$PROJECT" <<'PY'
import json,sys
env=lambda c:dict(s.split('=',1) for s in c['Config'].get('Env',[]) if '=' in s)
database=env(json.load(open(sys.argv[2]))[0]).get('DATABASE_URL')
for c in json.load(open(sys.argv[1])):
 if database and env(c).get('DATABASE_URL')==database and (c['Config'].get('Labels') or {}).get('com.docker.compose.project')!=sys.argv[3]:
  raise SystemExit('Found an external application using this database; stop it before migration')
PY
}
backup_hashes() {
    helper hash-backup --directory "$BACKUP"
}
validate_node_key() {
    python3 - "$WORK/node-check.env" <<'PY'
import os,pathlib,sys
pathlib.Path(sys.argv[1]).write_text('SECRET_KEY='+os.environ['REMNACUST_NODE_SECRET']+'\n')
PY
    docker run --rm -i --env-file "$WORK/node-check.env" --entrypoint node "$IMAGE" - <<'JS'
const crypto=require('node:crypto');
try {
 const p=JSON.parse(Buffer.from(process.env.SECRET_KEY,'base64').toString());
 const ca=new crypto.X509Certificate(p.caCertPem),cert=new crypto.X509Certificate(p.nodeCertPem);
 const key=crypto.createPrivateKey(p.nodeKeyPem);crypto.createPublicKey(p.jwtPublicKey);
 if (!ca.verify(ca.publicKey)||!cert.verify(ca.publicKey)||!cert.checkPrivateKey(key)||Date.parse(cert.validTo)<Date.now()||Date.parse(cert.validFrom)>Date.now()||Date.parse(ca.validTo)<Date.now())throw Error();
}catch{console.error('Invalid or expired node certificate package');process.exit(1)}
JS
}
backup_password_wizard() {
    local password=${REMNACUST_BACKUP_PASSWORD:-} repeated
    while true; do
        if [[ -z $password && -t 0 ]]; then
            printf '  Защита резервных копий · 16–256 символов без пробелов. Enter — создать пароль автоматически.\n' >&2
            IFS= read -r -s -p 'Пароль резервных копий: ' password || return 1
            printf '\n' >&2
            if [[ -n $password ]]; then
                IFS= read -r -s -p 'Повторите пароль: ' repeated || return 1
                printf '\n' >&2
                if [[ $password != "$repeated" ]]; then
                    printf '  Пароли не совпадают.\n' >&2; password=''; continue
                fi
            fi
        fi
        if [[ -z $password ]]; then password=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))'); fi
        if REMNACUST_BACKUP_PASSWORD="$password" python3 - "$WORK/backup-password.txt" <<'PY'
import os,re,sys
password=os.environ['REMNACUST_BACKUP_PASSWORD']
if not re.fullmatch(r'[\x21-\x7e]{16,256}',password): raise SystemExit(1)
fd=os.open(sys.argv[1],os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
with os.fdopen(fd,'w') as file: file.write(password)
PY
        then break; fi
        [[ -t 0 && -z ${REMNACUST_BACKUP_PASSWORD:-} ]] || die 'Пароль резервных копий должен содержать 16–256 символов ASCII без пробелов'
        printf '  Нужно 16–256 символов ASCII без пробелов.\n' >&2; password=''
    done
    unset REMNACUST_BACKUP_PASSWORD
}
initialize_panel_backups() {
    local encrypted
    # Fresh Compose has an image only, so run never builds it; refuse any pull here.
    compose run --rm --no-deps --pull never -T --entrypoint node \
        -v "$DEPLOY/backup-password.txt:/run/remnacust-backup-password:ro" "$(get mainService)" - \
        > "$WORK/backup-envelope" <<'JS'
const fs = require('node:fs');
const crypto = require('node:crypto');
const path = require('node:path');
try {
    const password = fs.readFileSync('/run/remnacust-backup-password');
    if (!/^[\x21-\x7e]{16,256}$/.test(password.toString()) || !process.env.APP_SECRET) throw Error();
    const directory = process.env.XERA_BACKUPS_DIR || '/opt/app/backups';
    if (!fs.lstatSync(directory).isDirectory()) throw Error();
    fs.chmodSync(directory, 0o700);
    const salt = crypto.randomBytes(16);
    const derived = crypto.scryptSync(password, salt, 32);
    fs.writeFileSync(path.join(directory, '.backup-key'), Buffer.concat([salt, derived]), {flag: 'wx', mode: 0o600});
    const key = crypto.createHmac('sha256', process.env.APP_SECRET).update('xera-keyring-v1').digest();
    const iv = crypto.randomBytes(12);
    const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
    const ciphertext = Buffer.concat([cipher.update(password), cipher.final()]);
    process.stdout.write('xera1:' + Buffer.concat([iv, cipher.getAuthTag(), ciphertext]).toString('base64'));
    password.fill(0); derived.fill(0); key.fill(0);
} catch {
    console.error('Не удалось подготовить защиту резервных копий. Проверьте доступ к тому backups.');
    process.exitCode = 1;
}
JS
    encrypted=$(cat "$WORK/backup-envelope")
    [[ $encrypted =~ ^xera1:[A-Za-z0-9+/=]+$ ]] || return 1
    # Override a sample value without putting the password in arguments or the log.
    sed -i '/^XERA_BACKUP_PASSWORD_ENC=/d' "$DEPLOY/.env"
    printf '\nXERA_BACKUP_PASSWORD_ENC=%s\n' "$encrypted" >> "$DEPLOY/.env"
}

panel_net_admin_wizard() {
    [[ $COMPONENT == panel ]] || return 0
    if [[ -t 0 ]] && ! $YES && ! $PANEL_NET_ADMIN_SET; then
        info 'NET_ADMIN разрешает управление сетью внутри контейнера панели.'
        info 'Для сетевых ограничений и закрытия соединений разрешите NET_ADMIN на нодах при их установке.'
        local choice
        choice=$(ask_yes_no 'Добавить NET_ADMIN контейнеру панели?') || return $?
        PANEL_NET_ADMIN=false; [[ $choice != yes ]] || PANEL_NET_ADMIN=true
        PANEL_NET_ADMIN_SET=true
    fi
    if $PANEL_NET_ADMIN && ! python3 "$HELPER" --help | grep -q -- '--panel-net-admin'; then
        die 'Этот выпуск не поддерживает выбор NET_ADMIN панели. Выберите latest.'
    fi
}

node_effective_net_admin() {
    local id=${1:-${CONTAINER:-}}
    if [[ -z ${1:-} && -n ${WORK:-} && -f $WORK/container.before.json ]]; then
        id=$(python3 -c 'import json,sys;v=json.load(open(sys.argv[1]));print((v[0] if isinstance(v,list) else v).get("Id",""))' "$WORK/container.before.json") || return 1
    fi
    [[ -n $id ]] || return 1
    # Read the effective capability of an actual process in this container.
    timeout 10 docker exec "$id" node -e 'const fs=require("node:fs");const m=fs.readFileSync("/proc/self/status","utf8").match(/^CapEff:\s*([a-f0-9]+)/mi);if(!m)process.exit(2);process.stdout.write((BigInt("0x"+m[1])&(1n<<12n))!==0n?"yes":"no")' 2>/dev/null
}
node_net_admin_wizard() {
    [[ $COMPONENT == node ]] || return 0
    local choice enabled=no effective=unknown
    if [[ -n ${1:-} ]]; then
        enabled=$(helper node-capability --source "$1" --state "$STATE")
        effective=$(node_effective_net_admin) || effective=unknown
        if [[ $effective == yes ]]; then
            if [[ $enabled != yes ]]; then
                helper node-capability --source "$1" --state "$STATE" --key enable >/dev/null
            fi
            info 'NET_ADMIN ноды включён; право сохранится после обновления.'
            NODE_NET_ADMIN=true
            return 0
        fi
        if [[ $enabled == yes ]]; then
            info 'NET_ADMIN указан в Compose, но фактическое право контейнера не подтверждено.'
        fi
        NODE_NET_ADMIN=false
    fi
    if $PANEL_NET_ADMIN_SET; then
        NODE_NET_ADMIN=$PANEL_NET_ADMIN
    elif [[ -t 0 ]] && ! $YES; then
        info 'NET_ADMIN нужен для сетевых ограничений и принудительного закрытия соединений. Без него эти возможности ограничены.'
        choice=$(ask_yes_no 'Добавить NET_ADMIN контейнеру ноды?') || return $?
        NODE_NET_ADMIN=false; [[ $choice != yes ]] || NODE_NET_ADMIN=true
    fi
    if [[ -n ${1:-} ]] && $NODE_NET_ADMIN; then
        helper node-capability --source "$1" --state "$STATE" --key enable >/dev/null
        NODE_NET_ADMIN_ADDED=true
    fi
}


subscription_panel_endpoint() {
    local endpoint=${PAGE_PANEL_URL:-} choice
    if [[ -z $endpoint && -f $ROOT/registry/panel.json ]]; then
        endpoint=auto
        if [[ -t 0 ]] && ! $YES; then
            choice=$(ask_yes_no 'Использовать локальную панель для страницы подписки?' y) || return $?
            [[ $choice == yes ]] || endpoint=''
        fi
    fi
    while true; do
        [[ -n $endpoint ]] || endpoint=$(ask_required 'HTTPS адрес панели') || return $?
        if [[ $endpoint == auto ]]; then printf auto; return; fi
        if ! endpoint=$(python3 -I "$HELPER_ROOT/subscription_pages.py" panel-url --root "$ROOT" --panel-url "$endpoint"); then
            [[ -t 0 ]] && ! $YES || return 1
            printf '  Укажите HTTPS адрес панели без пути, пароля и параметров.\n' >&2
            endpoint=''; continue
        fi
        if [[ -t 0 ]] && ! $YES; then
            choice=$(ask_yes_no "Использовать панель $endpoint?" y) || return $?
            if [[ $choice != yes ]]; then endpoint=''; continue; fi
        fi
        printf '%s' "$endpoint"; return
    done
}
subscription_page_token() {
    local endpoint=$1 token_file=$2
    if [[ -n $PAGE_TOKEN_FILE ]]; then
        python3 -I "$HELPER_ROOT/subscription_pages.py" token-file --root "$ROOT" --token-file "$PAGE_TOKEN_FILE" --target "$token_file" || return $?
    elif [[ -n ${REMNACUST_SUBSCRIPTION_TOKEN:-} ]]; then
        printf '%s' "$REMNACUST_SUBSCRIPTION_TOKEN" > "$token_file"
    elif [[ $endpoint == auto ]]; then
        local panel_id
        panel_id=$(python3 -I - "$ROOT/registry/panel.json" "$HELPER_ROOT" <<'PY'
import json,sys
sys.path.insert(0,sys.argv[2])
from subscription_pages import inspect
s=json.load(open(sys.argv[1]));c=inspect({**s,'service':s['mainService']})
if not c or not c.get('State',{}).get('Running'):raise SystemExit('Локальная панель не запущена')
print(c['Id'])
PY
        )
        local reuse_env="$WORK/subscription-reuse.env"
        python3 -I "$HELPER_ROOT/subscription_pages.py" reuse-token-env --root "$ROOT" --directory "$DEPLOY" --project "$PROJECT" --token-file "$reuse_env"
        docker exec -i --env-file "$reuse_env" --env "REMNACUST_SUBSCRIPTION_TOKEN_UUID=$(python3 -c 'import uuid;print(uuid.uuid4())')" "$panel_id" node - < "$HELPER_ROOT/subscription.cjs" > "$token_file"
        rm -f -- "$reuse_env"
    else
        if [[ -t 0 ]]; then
            local token
            while true; do
                read -r -s -p 'API-токен с правами страницы подписки: ' token || return 1
                printf '\n' >&2
                [[ -z $token ]] || break
                info 'Пустой токен: повторите ввод.'
            done
            printf '%s' "$token" > "$token_file"; unset token
        else die 'Нужен REMNACUST_SUBSCRIPTION_TOKEN или локальная панель (--panel-url auto)'; fi
    fi
    chmod 600 "$token_file"
}

migrate_subscription_page_action() {
    installed_helper
    local script="$HELPER_ROOT/subscription_pages.py" count index=1 selected_container needs_connection endpoint token_file result
    local -a selectors=() connection_options=()
    [[ -z $CONTAINER ]] || selectors+=(--container "$CONTAINER")
    [[ -z $DIRECTORY ]] || selectors+=(--directory "$DIRECTORY")
    [[ -z $COMPOSE_FILE$PROJECT ]] || die 'Выберите существующую страницу через --container или --directory; её Compose-проект сохраняется.'
    python3 -I "$script" migration-candidates --root "$ROOT" "${selectors[@]}" > "$WORK/page-migration-candidates.json" || return $?
    count=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))))' "$WORK/page-migration-candidates.json")
    if ((count == 0)); then
        [[ -z $CONTAINER$DIRECTORY ]] || die 'Указанный источник не распознан; его контейнеры и файлы не изменены. Проверьте --container/--directory либо выберите install-subscription-page для новой установки.'
        info 'Страница для переноса не найдена. Открываем мастер установки: укажите панель, API-токен, домен и порт. Существующие контейнеры и файлы не перезаписываются.'
        ACTION=install-subscription-page
        subscription_page_action
        return $?
    fi
    lock_operation
    python3 - "$WORK/page-migration-candidates.json" <<'PYMIGRATE'
import json,sys
for number,item in enumerate(json.load(open(sys.argv[1])),1):
    print(f"  {number}. {item['project']}/{item['service']} · {item['directory']}")
PYMIGRATE
    if ((count > 1)); then
        [[ -t 0 ]] || die 'Найдено несколько страниц; укажите точный --container или --directory.'
        while true; do
            index=$(ask_required 'Номер страницы для переноса') || return $?
            if [[ $index =~ ^[0-9]{1,3}$ ]] && ((10#$index >= 1 && 10#$index <= count)); then index=$((10#$index)); break; fi
            printf '  Выберите номер от 1 до %s.\n' "$count" >&2
        done
    fi
    selected_container=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))[int(sys.argv[2])-1]["container"])' "$WORK/page-migration-candidates.json" "$index")
    needs_connection=$(python3 -c 'import json,sys;print("yes" if json.load(open(sys.argv[1]))[int(sys.argv[2])-1].get("needsConnection") else "no")' "$WORK/page-migration-candidates.json" "$index")
    prepare_host; choose_version
    confirm "Перенести выбранную страницу подписки на Remnacust ($VERSION); подключение к панели и настройки сохраняются"
    release_source; select_subscription_image
    step 'Готовый образ сайта подписки' prepare_subscription_image
    if [[ $needs_connection == yes || -n $PAGE_PANEL_URL$PAGE_TOKEN_FILE ]]; then
        info 'Укажите подключение страницы к панели; изменения будут применены только после проверки адреса и API-токена.'
        endpoint=$(subscription_panel_endpoint) || return $?
        token_file="$WORK/page-migration-token.txt"
        subscription_page_token "$endpoint" "$token_file" || return $?
        connection_options=(--panel-url "$endpoint" --token-file "$token_file")
    fi
    result=0
    step 'Перенос страницы подписки' python3 -I "$script" migrate --root "$ROOT" --container "$selected_container" --image "$SUBSCRIPTION_IMAGE" --version "$SUBSCRIPTION_IMAGE_VERSION" --release "$TAG" "${connection_options[@]}" || result=$?
    [[ -z ${token_file:-} ]] || rm -f -- "$token_file"
    ((result == 0)) || return "$result"
    install_cli
    info 'Страница перенесена. Домен, API-токен, сети, тома и состояние запуска сохранены. Панель не обновлялась.'
    if [[ ${REMNACUST_MENU_COMPLETION_FD:-} == 3 ]]; then printf 'completed\n' >&3; fi
}

subscription_page_action() {
    local script choice token_file endpoint
    if [[ $ACTION == uninstall-subscription-page ]]; then
        command -v python3 >/dev/null || die 'Для удаления нужен python3'
        command -v docker >/dev/null || die 'Docker недоступен'
        lock_operation
        installed_helper
        select_managed_page || return $?
        info 'Удаляется только выбранная страница и её отдельный proxy, если он принадлежит этой странице. Панель, БД, настройки и тома сохраняются.'
        confirm "Удалить страницу подписки $PAGE_ID"
        local archive
        archive=$(python3 -I "$HELPER_ROOT/subscription_pages.py" uninstall --root "$ROOT" --page-id "$PAGE_ID") || return $?
        info "Страница подписки удалена. Настройки сохранены на месте; копия Compose: $archive"
        return
    fi
    if [[ $ACTION == configure-subscription-page ]]; then
        command -v python3 >/dev/null || die 'Для настройки нужен python3'
        command -v docker >/dev/null || die 'Docker недоступен'
        lock_operation; installed_helper
        select_managed_page || return $?
        local info_file="$WORK/page-connection-info.json"
        python3 -I "$HELPER_ROOT/subscription_pages.py" connection-info --root "$ROOT" --page-id "$PAGE_ID" > "$info_file" || return $?
        DEPLOY=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["directory"])' "$info_file")
        PROJECT=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["project"])' "$info_file")
        endpoint=$(subscription_panel_endpoint) || return $?
        confirm 'Сменить панель и API-токен страницы подписки; при ошибке сохранить прежнее подключение'
        token_file="$WORK/subscription-token.txt"
        subscription_page_token "$endpoint" "$token_file" || return $?
        python3 -I "$HELPER_ROOT/subscription_pages.py" configure --root "$ROOT" --page-id "$PAGE_ID" --panel-url "$endpoint" --token-file "$token_file" || return $?
        rm -f -- "$token_file"
        info 'Панель и токен страницы обновлены. Прежняя конфигурация сохранена в backups; состояние запуска страницы сохранено.'
        return
    fi
    if [[ $ACTION == manage-subscription-page ]]; then
        command -v python3 >/dev/null || die 'Для управления нужен python3'
        command -v docker >/dev/null || die 'Docker недоступен'
        lock_operation
        installed_helper
        script="$HELPER_ROOT/subscription_pages.py"
        [[ -f $script ]] || die 'Обновите установщик: управление страницами недоступно в старом выпуске'
        case "${PAGE_OPERATION:-list}" in list|status|logs|start|stop|restart) ;; *) die 'Действие страницы: list, status, logs, start, stop, restart';; esac
        if [[ ${PAGE_OPERATION:-list} == list ]]; then
            python3 -I "$script" list --root "$ROOT"
            [[ -t 0 ]] || return 0
            select_managed_page || return $?
            COMPONENT=subscription-page
            component_menu || return $?
            [[ -n $ACTION ]] || return 0
            if [[ $ACTION == change-domain || $ACTION == show-config ]]; then manage_component_action; return; fi
            if [[ $ACTION == uninstall-subscription-page || $ACTION == configure-subscription-page ]]; then subscription_page_action; return; fi
            PAGE_OPERATION=$ACTION
        fi
        if [[ -z $PAGE_ID ]]; then
            select_managed_page || return $?
        fi
        case "$PAGE_OPERATION" in status|logs) ;; *) confirm "$PAGE_OPERATION страницы $PAGE_ID";; esac
        python3 -I "$script" "$PAGE_OPERATION" --root "$ROOT" --page-id "$PAGE_ID"
        return
    fi
    if [[ $ACTION == install-subscription-page ]]; then
        installed_helper
        local target_project=${PROJECT:-remnacust-subscription-page} target_directory=${DIRECTORY:-$ROOT/subscription-page} existing
        if [[ -z $DIRECTORY && $target_project != remnacust-subscription-page ]]; then target_directory="$ROOT/subscription-pages/$target_project"; fi
        existing=$(python3 -I "$HELPER_ROOT/subscription_pages.py" existing-target --root "$ROOT" --directory "$target_directory" --project "$target_project") || return $?
        if [[ $existing != null ]]; then
            PAGE_ID=$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["id"])' "$existing")
            python3 -c 'import json,sys;v=json.loads(sys.argv[1]);print("  Страница уже установлена: "+v["name"]+" · "+v["domain"])' "$existing"
            [[ -t 0 ]] || die "Повторная установка не нужна. Используйте upgrade-subscription-page --page-id $PAGE_ID или manage-subscription-page --page-id $PAGE_ID."
            info 'Открываем управление существующей страницей; новая копия и новый токен не создаются.'
            ACTION=manage-subscription-page; PAGE_OPERATION=list
            subscription_page_action
            return
        fi
    fi
    prepare_host; lock_operation
    choose_version
    confirm "Выполнить $ACTION ($VERSION)"
    release_source
    script="$HELPER_ROOT/subscription_pages.py"
    select_subscription_image
    step 'Готовый образ сайта подписки' prepare_subscription_image
    if [[ $ACTION == install-subscription-page && -z $PROJECT && -z $DIRECTORY ]]; then
        local owner
        owner=$(python3 -I "$script" reuse-port --root "$ROOT" --port "${PORT:-$SUBSCRIPTION_PORT}") || return $?
        if [[ $owner != null ]]; then
            PAGE_ID=$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["id"])' "$owner")
            if [[ -n $DOMAIN ]]; then
                local current_domain
                current_domain=$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["domain"])' "$owner")
                [[ $DOMAIN == "$current_domain" ]] || die 'На этом порту уже работает ваша страница. Сначала обновите её без --domain; смена адреса доступна в управлении страницей.'
            fi
            info "Порт ${PORT:-$SUBSCRIPTION_PORT} занят нашей страницей: обновляем её на месте. Пересоздаётся только контейнер страницы; токен, настройки и остальные сервисы сохраняются."
            ACTION=upgrade-subscription-page
        fi
    fi
    if [[ $ACTION == upgrade-subscription-page ]]; then
        if [[ -z $PAGE_ID ]]; then
            python3 -I "$script" list --root "$ROOT"
            PAGE_ID=$(ask_required 'ID страницы для обновления') || return $?
        fi
        python3 -I "$script" upgrade --root "$ROOT" --page-id "$PAGE_ID" --image "$SUBSCRIPTION_IMAGE" --version "$SUBSCRIPTION_IMAGE_VERSION" --release "$TAG"
        python3 -I "$HELPER_ROOT/deployment_layout.py" --root "$ROOT" --cleanup-backups --component subscription-page
        info "Страница подписки обновлена до $SUBSCRIPTION_IMAGE_VERSION; состояние запуска сохранено."
        if [[ ${REMNACUST_MENU_COMPLETION_FD:-} == 3 ]]; then printf 'completed\n' >&3; fi
        return
    fi
    endpoint=$(subscription_panel_endpoint) || return $?
    DOMAIN=$(ask_confirmed_domain 'Домен страницы подписки' "$DOMAIN") || return $?
    PROJECT=${PROJECT:-remnacust-subscription-page}
    DEPLOY=${DIRECTORY:-$ROOT/subscription-page}
    if [[ -z $DIRECTORY && $PROJECT != remnacust-subscription-page ]]; then DEPLOY="$ROOT/subscription-pages/$PROJECT"; fi
    PORT=$(choose_subscription_port "${PORT:-$SUBSCRIPTION_PORT}") || return $?
    if ! $PROXY_SET; then
        PROXY=existing
        if [[ -t 0 ]] && ! $YES; then
            choice=$(ask_yes_no 'Установить отдельный Caddy для HTTPS? Только если порты 80/443 свободны') || return $?
            [[ $choice != yes ]] || PROXY=caddy
        fi
    fi
    if [[ $PROXY == caddy ]]; then port_free 80; port_free 443; docker pull caddy:2-alpine; fi
    token_file="$WORK/subscription-token.txt"
    subscription_page_token "$endpoint" "$token_file" || return $?
    chmod 600 "$token_file"
    PAGE_ID=$(python3 -I "$script" install --root "$ROOT" --directory "$DEPLOY" --project "$PROJECT" --panel-url "$endpoint" --token-file "$token_file" --port "$PORT" --image "$SUBSCRIPTION_IMAGE" --domain "$DOMAIN" --proxy "$PROXY")
    rm -f -- "$token_file"
    install_cli
    info "Страница установлена. ID: $PAGE_ID. Каталог: $DEPLOY"
    info "Версия страницы подписки: $SUBSCRIPTION_IMAGE_VERSION. Установка страницы не обновляет панель."
    [[ $PROXY != existing ]] || info "Направьте HTTPS домена $DOMAIN на 127.0.0.1:$PORT в вашем reverse proxy."
    if [[ ${REMNACUST_MENU_COMPLETION_FD:-} == 3 ]]; then printf 'completed\n' >&3; fi
}

subscription_wizard() {
    local normalized preset=false choice operation=subscription-urls
    [[ -z $SUBSCRIPTION_URLS && $SUBSCRIPTION_SET == false ]] || preset=true
    if ! python3 "$HELPER" --help | grep -q -- '--subscription-urls'; then
        if $preset || $SUBSCRIPTION_PAGE; then die 'Этот выпуск не поддерживает адреса сайта подписки. Выберите latest.'; fi
        return 0
    fi
    if [[ -t 0 ]] && ! $YES && ! $SUBSCRIPTION_PAGE_SET; then
        info 'Сайт подписки — отдельная страница для пользователей; нужен отдельный домен.'
        choice=$(ask_yes_no 'Установить сайт подписки?') || return $?
        [[ $choice != yes ]] || SUBSCRIPTION_PAGE=true
    fi
    if $SUBSCRIPTION_PAGE; then
        [[ -f ${HELPER%/*}/subscription.cjs ]] && python3 "$HELPER" --help | grep -q -- '--subscription-image' || die 'Для установки сайта подписки выберите latest.'
        operation=subscription-domains
    elif ! $preset; then
        SUBSCRIPTION_URLS="https://$DOMAIN/api/sub"
        info 'Сайт подписки не устанавливается; ссылки выдаёт панель. Позже: remnacust install-subscription-page.'
        return 0
    fi
    while true; do
        if [[ -t 0 ]] && ! $YES && ! $preset; then
            info 'Укажите один или два отдельных домена через запятую; первый — основной.'
            info "HTTPS сайта: тот же способ, что у панели ($PROXY / ${TLS_METHOD:-ваш proxy})."
            SUBSCRIPTION_URLS=$(ask_required 'Домены сайта подписки') || return $?
        fi
        if normalized=$(helper "$operation" --domain "$DOMAIN" --subscription-urls "$SUBSCRIPTION_URLS"); then
            if [[ -t 0 ]] && ! $YES; then
                choice=$(ask_yes_no "Использовать адреса сайта подписки: ${normalized//$'\n'/, }?" y) || return $?
                if [[ $choice != yes ]]; then preset=false; SUBSCRIPTION_URLS=''; continue; fi
            fi
            if $SUBSCRIPTION_PAGE; then
                SUBSCRIPTION_URLS="https://${normalized//$'\n'/,https://}"
            else SUBSCRIPTION_URLS=${normalized//$'\n'/,}; fi
            if $SUBSCRIPTION_PAGE; then info "Будет установлен сайт подписки: $SUBSCRIPTION_URLS"
            else info "Используем существующий сайт: $SUBSCRIPTION_URLS; новый контейнер сайта не создаётся."; fi
            return 0
        fi
        [[ -t 0 ]] && ! $YES && ! $preset || die 'Исправьте --subscription-urls: один или два адреса сайта подписки'
    done
}
fresh_files() {
    local -a subscription_options=()
    local -a capability_options=()
    if [[ $COMPONENT == panel ]] && $PANEL_NET_ADMIN; then capability_options=(--panel-net-admin); fi
    if [[ $COMPONENT == node ]] && ! $NODE_NET_ADMIN; then capability_options=(--node-no-net-admin); fi
    if [[ $COMPONENT == node ]]; then capability_options+=(--node-site-mode "${NODE_SITE_MODE:-selfsteal}" --node-site-port "${NODE_SITE_PORT:-443}" --node-inbound-port "${NODE_INBOUND_PORT:-8443}"); fi
    [[ $COMPONENT != panel || -z $SUBSCRIPTION_URLS ]] || subscription_options=(--subscription-urls "$SUBSCRIPTION_URLS")
    if [[ $COMPONENT == panel ]] && $SUBSCRIPTION_PAGE; then
        subscription_options+=(--subscription-image "$SUBSCRIPTION_IMAGE" --subscription-port "$SUBSCRIPTION_PORT")
    fi
    DEPLOY=${DIRECTORY:-$ROOT/$COMPONENT}; PROJECT=${PROJECT:-remnacust-$COMPONENT}
    [[ $DEPLOY == /* && $DEPLOY != / && ! -L $DEPLOY ]] || die 'Укажите безопасный абсолютный каталог'
    if [[ -d $DEPLOY ]] && [[ -n $(find "$DEPLOY" -mindepth 1 -maxdepth 1 -print -quit) ]]; then die 'Каталог не пуст: выберите upgrade или migrate'; fi
    if [[ -e $ROOT/registry/$COMPONENT.json || -L $ROOT/registry/$COMPONENT.json ]]; then
        [[ -n $REINSTALL_RECORD && ! -L $ROOT/registry/$COMPONENT.json ]] && cmp -- "$REINSTALL_RECORD" "$ROOT/registry/$COMPONENT.json" >/dev/null || die 'Компонент уже зарегистрирован'
    fi
    if [[ $COMPONENT == panel ]]; then
        [[ -z $NODE_DOMAIN$PANEL_IP ]] || die '--node-domain и --panel-ip предназначены для install-node'
        [[ -n $DOMAIN ]] || DOMAIN=$(ask_confirmed_domain 'Домен панели') || return $?
        PORT=${PORT:-3000}
    else
        PORT=${PORT:-2222}
        if [[ -z ${REMNACUST_NODE_SECRET:-} ]]; then
            ask_node_secret || return 1
        fi
        export REMNACUST_NODE_SECRET
    fi
    local -a validation=(--domain "$DOMAIN" --node-domain "$NODE_DOMAIN" --port "$PORT" --project "$PROJECT")
    [[ -z $PANEL_IP ]] || validation+=(--key "$PANEL_IP")
    helper validate "${validation[@]}"
    local project_containers
    project_containers=$(docker ps --all --quiet --filter "label=com.docker.compose.project=$PROJECT") || die 'Не удалось повторно проверить проект Compose: Docker недоступен'
    [[ -z $project_containers ]] || die 'Проект Compose уже существует; используйте upgrade или migrate'
    if project_has_volumes "$PROJECT"; then die 'Тома выбранного проекта уже существуют; для новой установки выберите другое --project-name'; fi
    port_free "$PORT"
    if [[ $COMPONENT == panel && $PROXY == caddy ]]; then port_free 80; port_free 443; fi
    if [[ $COMPONENT == node ]]; then step 'Проверка ключа ноды' validate_node_key; fi
    mkdir -p "$DEPLOY"; chmod 700 "$DEPLOY"
    if [[ $COMPONENT == panel ]]; then
        [[ -f $WORK/backup-password.txt && ! -L $WORK/backup-password.txt ]] || backup_password_wizard
        cp -- "$WORK/backup-password.txt" "$DEPLOY/backup-password.txt"; chmod 600 "$DEPLOY/backup-password.txt"
        helper panel-env --source "$SOURCE/panel/backend/.env.sample" --target "$DEPLOY/.env" --domain "$DOMAIN" --port "$PORT" "${subscription_options[@]}"
        if $SUBSCRIPTION_PAGE; then
            : > "$DEPLOY/subscription.env"; chmod 600 "$DEPLOY/subscription.env"
            tls_helper caddy --domain "$DOMAIN" --email "$EMAIL" --method "${TLS_METHOD:-auto}" --directory "$DEPLOY" --subscription-urls "$SUBSCRIPTION_URLS"
        elif [[ ${TLS_METHOD:-auto} == auto ]]; then
            { [[ -z $EMAIL ]] || printf '{\n    email %s\n}\n\n' "$EMAIL"; printf '%s {\n    reverse_proxy remnawave:3000\n}\n' "$DOMAIN"; } > "$DEPLOY/Caddyfile"
        else tls_helper caddy --domain "$DOMAIN" --email "$EMAIL" --method "$TLS_METHOD" --directory "$DEPLOY"; fi
    else
        helper node-env --target "$DEPLOY/.env" --port "$PORT"
        mkdir -p "$DEPLOY/run" "$DEPLOY/logs"
        install -d -m 0700 "$DEPLOY/state/host-policy" "$DEPLOY/state/core-manager"
    fi
    STATE="$WORK/state.json"
    helper fresh --component "$COMPONENT" --directory "$DEPLOY" --project "$PROJECT" --image "$IMAGE" --domain "$DOMAIN" \
        --port "$PORT" --proxy "$PROXY" --node-domain "$NODE_DOMAIN" "${subscription_options[@]}" "${capability_options[@]}" --target "$DEPLOY/docker-compose.yml" --state "$STATE"
    if [[ $COMPONENT == panel && $PROXY == caddy && ${TLS_METHOD:-auto} != auto ]]; then
        python3 - "$DEPLOY/docker-compose.yml" "$DEPLOY" <<'PY'
import json,sys
p=sys.argv[1];s=json.load(open(p));s['services']['caddy']['volumes'].append(sys.argv[2]+'/certs:/var/lib/remnacust/tls:ro')
json.dump(s,open(p,'w'),indent=2)
PY
    fi
    load_state; START_APPS=("${APPS[@]}" "${EXTRAS[@]}")
    if [[ $COMPONENT == panel ]] && $SUBSCRIPTION_PAGE; then START_APPS=(remnawave "${EXTRAS[@]}"); fi
}

managed_subscription_options() {
    local urls=''
    if [[ -n $STATE && -f $STATE ]]; then
        urls=$(python3 -c 'import json,sys;s=json.load(open(sys.argv[1]));print(",".join(s.get("subscriptionUrls",[])) if s.get("subscriptionPage") else "")' "$STATE")
    elif $SUBSCRIPTION_PAGE; then urls=$SUBSCRIPTION_URLS; fi
    [[ -z $urls ]] || printf '%s' "$urls"
}
initialize_subscription_page() {
    local urls script id token_uuid
    urls=$(managed_subscription_options); [[ -n $urls ]] || return 0
    [[ ! -L $DEPLOY/subscription.env ]] || die 'subscription.env не должен быть символической ссылкой'
    if [[ ! -s $DEPLOY/subscription.env ]]; then
        script="${HELPER%/*}/subscription.cjs"
        [[ -f $script ]] || die 'Не найден помощник настройки сайта подписки'
        id=$(compose ps --quiet "$(get mainService)"); token_uuid=$(get subscriptionTokenUuid)
        # stdout contains the credential: keep it out of the operation log.
        docker exec -i --env "REMNACUST_SUBSCRIPTION_TOKEN_UUID=$token_uuid" "$id" node - < "$script" > "$WORK/subscription-token.txt"
        chmod 600 "$WORK/subscription-token.txt"
        helper subscription-env --source "$WORK/subscription-token.txt" --target "$DEPLOY/subscription.env"
        rm -f -- "$WORK/subscription-token.txt"
    fi
    chmod 600 "$DEPLOY/subscription.env"
    compose up -d --no-build --pull never remnawave-subscription-page
    local -a START_APPS=(remnawave-subscription-page)
    wait_ready
}
tls_helper() {
    local script="${HELPER%/*}/tls.py"
    [[ -f $script ]] || die 'В выбранном выпуске нет настройки TLS. Используйте latest.'
    python3 "$script" "$@"
}
node_site_wizard() {
    [[ -n $NODE_DOMAIN ]] || return 0
    local choice
    if [[ -n $STATE && -f $STATE ]]; then
        [[ -n $NODE_SITE_PORT ]] || NODE_SITE_PORT=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("nodeSitePort",443))' "$STATE") || return $?
        [[ -n $NODE_INBOUND_PORT ]] || NODE_INBOUND_PORT=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("nodeInboundPort",8443))' "$STATE") || return $?
    fi
    if [[ -z $NODE_SITE_MODE && -t 0 && ( $ACTION == install-node || $ACTION == migrate-remnawave-node ) ]] && ! $YES; then
        printf '\n  Сайт ноды\n  1  Отдельный HTTPS-сайт\n  2  Selfsteal через Xray\n'
        choice=$(ask 'Режим сайта' 1) || return $?
        case "$choice" in 1) NODE_SITE_MODE=standalone;; 2) NODE_SITE_MODE=selfsteal;; *) die 'Выберите 1 или 2';; esac
    fi
    NODE_SITE_MODE=${NODE_SITE_MODE:-selfsteal}
    [[ $NODE_SITE_MODE == selfsteal || $NODE_SITE_MODE == standalone ]] || die 'Режим сайта: selfsteal или standalone'
    if [[ $NODE_SITE_MODE == standalone ]]; then
        helper validate --port "${PORT:-2222}" >/dev/null || return $?
        if [[ -t 0 ]] && ! $YES; then
            while true; do
                NODE_SITE_PORT=$(ask 'Порт HTTPS-сайта' "${NODE_SITE_PORT:-443}") || return $?
                NODE_INBOUND_PORT=$(ask 'Порт входа Xray в профиле панели' "${NODE_INBOUND_PORT:-8443}") || return $?
                if helper validate --port "$NODE_SITE_PORT" >/dev/null && helper validate --port "$NODE_INBOUND_PORT" >/dev/null &&
                   [[ $((10#$NODE_SITE_PORT)) != $((10#${PORT:-2222})) && $((10#$NODE_INBOUND_PORT)) != $((10#${PORT:-2222})) && $((10#$NODE_SITE_PORT)) != $((10#$NODE_INBOUND_PORT)) ]]; then break; fi
                printf '  Порты API, сайта и входа Xray должны быть разными числами от 1 до 65535.\n' >&2
            done
        fi
        NODE_SITE_PORT=${NODE_SITE_PORT:-443}; NODE_INBOUND_PORT=${NODE_INBOUND_PORT:-8443}
        helper validate --port "$NODE_SITE_PORT" >/dev/null || return $?
        helper validate --port "$NODE_INBOUND_PORT" >/dev/null || return $?
        NODE_SITE_PORT=$((10#$NODE_SITE_PORT)); NODE_INBOUND_PORT=$((10#$NODE_INBOUND_PORT))
        [[ $NODE_SITE_PORT != "$((10#${PORT:-2222}))" && $NODE_INBOUND_PORT != "$((10#${PORT:-2222}))" && $NODE_SITE_PORT != "$NODE_INBOUND_PORT" ]] || die 'Порты API, сайта и входа Xray должны отличаться'
    fi
}
certificate_wizard() {
    local choice domain suggested
    if [[ $COMPONENT == panel ]]; then
        [[ -n $DOMAIN ]] || DOMAIN=$(ask_confirmed_domain 'Домен панели') || return $?
        if [[ -t 0 ]] && ! $YES && ! $PROXY_SET; then
            printf '\n  HTTPS панели\n  1  Caddy в Docker (новая установка)\n  2  Свой существующий Nginx/Caddy\n'
            choice=$(ask 'Reverse proxy' 1)
            case "$choice" in 1) PROXY=caddy;;2) PROXY=existing;;*) die 'Выберите 1 или 2';;esac
        fi
        if [[ $PROXY == existing ]]; then
            [[ -z $TLS_METHOD$CERT_FILE$KEY_FILE$DNS_CREDENTIALS$EMAIL ]] || die 'При --proxy existing сертификат настраивается в вашем proxy; параметры TLS здесь не нужны'
            info 'Ваш proxy и сертификаты сохраняются. Backend будет доступен на 127.0.0.1.'
            return 0
        fi
        domain=$DOMAIN; suggested=auto
    else
        if [[ -t 0 ]] && ! $YES; then
            [[ -n $PORT ]] || PORT=$(ask 'Порт API ноды' 2222)
            [[ -n $PANEL_IP ]] || PANEL_IP=$(ask 'IP/CIDR главного сервера: все входящие порты кроме SSH только от него (Enter — свой firewall)')
        fi
        if [[ -t 0 && -z $NODE_DOMAIN ]] && ! $YES; then
            choice=$(ask_yes_no 'Настроить TLS/XHTTP на ноде?')
            case "$choice" in
                yes) NODE_DOMAIN=$(ask_confirmed_domain 'Домен ноды') || return $?; NODE_DOMAIN_CONFIRMED=$NODE_DOMAIN;;
                no) ;;
            esac
        fi
        if [[ -z $NODE_DOMAIN ]]; then
            [[ -z $TLS_METHOD$CERT_FILE$KEY_FILE$DNS_CREDENTIALS$EMAIL$NODE_SITE_PORT$NODE_INBOUND_PORT && $NODE_SITE_MODE != standalone ]] || die 'Для TLS и сайта ноды укажите --node-domain'
            return 0
        fi
        domain=$NODE_DOMAIN; suggested=http
        node_site_wizard || return $?
    fi
    if [[ -z $TLS_METHOD ]]; then
        if [[ -t 0 ]] && ! $YES; then
            printf '\n  Сертификат для %s\n  1  Автоматически · %s\n  2  Cloudflare DNS · API token\n  3  Gcore DNS · API token\n  4  Уже есть сертификат и приватный ключ\n' "$domain" "$suggested"
            case "$(ask 'Способ получения сертификата' 1)" in
                1) TLS_METHOD=$suggested;;2) TLS_METHOD=cloudflare;;3) TLS_METHOD=gcore;;4) TLS_METHOD=existing;;*) die 'Выберите 1–4';;
            esac
        else TLS_METHOD=$suggested; fi
    fi
    [[ $COMPONENT != node || $TLS_METHOD != auto ]] || die 'auto используется только Caddy панели; для ноды выберите http, DNS или existing'
    if [[ $COMPONENT == panel && $TLS_METHOD == http ]]; then TLS_METHOD=auto; fi
    if [[ $TLS_METHOD == existing ]]; then
        [[ -n $CERT_FILE ]] || CERT_FILE=$(ask 'Путь к fullchain.pem' "/etc/letsencrypt/live/$domain/fullchain.pem")
        [[ -n $KEY_FILE ]] || KEY_FILE=$(ask 'Путь к privkey.pem' "/etc/letsencrypt/live/$domain/privkey.pem")
        [[ -z $EMAIL$DNS_CREDENTIALS ]] || die 'Для готового сертификата email и DNS credentials не нужны'
    else
        [[ -z $CERT_FILE$KEY_FILE ]] || die 'Пути к сертификату доступны при --tls-method existing'
        if [[ -z $EMAIL ]]; then
            while true; do
                EMAIL=$(ask_required "Email для Let's Encrypt") || return $?
                [[ $EMAIL =~ ^[A-Za-z0-9_.+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] && break
                printf '  ! некорректный email, повторите ввод\n' >&2
            done
        else
            [[ $EMAIL =~ ^[A-Za-z0-9_.+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die 'Некорректный email'
        fi
        if [[ $TLS_METHOD == cloudflare || $TLS_METHOD == gcore ]]; then
            if [[ -z $DNS_CREDENTIALS ]]; then
                [[ -t 0 ]] || die 'Укажите --dns-credentials (INI, права 600)'
                local secret
                while true; do
                    IFS= read -r -s -p "API token $TLS_METHOD (ввод скрыт): " secret || return 1
                    printf '\n'
                    secret=$(trim_answer "$secret")
                    [[ $secret =~ ^[A-Za-z0-9_.=-]+$ ]] && break
                    printf '  ! введите API token без пробелов\n' >&2
                done
                DNS_CREDENTIALS="$WORK/dns.ini"
                if [[ $TLS_METHOD == cloudflare ]]; then printf 'dns_cloudflare_api_token = %s\n' "$secret" > "$DNS_CREDENTIALS"
                else printf 'dns_gcore_apitoken = %s\n' "$secret" > "$DNS_CREDENTIALS"; fi
                unset secret
            fi
        else
            [[ -z $DNS_CREDENTIALS ]] || die 'DNS credentials нужны только для Cloudflare/Gcore'
            info "A/AAAA $domain должны указывать на сервер; для HTTP-01 нужен доступ к TCP 80."
        fi
    fi
}
certificate_preflight() {
    if [[ $COMPONENT == node && $TLS_METHOD == http && ( $((10#${NODE_SITE_PORT:-443})) == 80 || $((10#${NODE_INBOUND_PORT:-8443})) == 80 ) ]]; then
        die 'HTTP-01 использует TCP 80. Выберите другой порт сайта/входа Xray или DNS-сертификат.'
    fi
    if [[ $COMPONENT == node && ${NODE_SITE_MODE:-selfsteal} == standalone ]]; then
        local current_site=''
        if [[ -n $STATE && -f $STATE ]]; then current_site=$(python3 -c 'import json,sys;s=json.load(open(sys.argv[1]));print(s.get("nodeSitePort",443) if s.get("nodeSiteMode")=="standalone" else "")' "$STATE"); fi
        [[ $current_site == "$NODE_SITE_PORT" ]] || port_free "$NODE_SITE_PORT" || return $?
    fi
    if [[ $COMPONENT == node && -n $PANEL_IP && $TLS_METHOD == http ]]; then
        info 'Для HTTP-01 TCP 80 временно открывается во время выпуска и продления сертификата; затем снова закрывается.'
    fi
    local domain=${NODE_DOMAIN:-$DOMAIN}
    local -a subscription_options=(); local subscriptions
    subscriptions=$(managed_subscription_options)
    [[ -z $subscriptions ]] || subscription_options=(--subscription-urls "$subscriptions")
    [[ $COMPONENT != panel || $PROXY == caddy ]] || return 0
    if [[ $COMPONENT == panel && ( $PORT == 80 || $PORT == 443 ) ]]; then die 'Порты 80/443 нужны Caddy. Выберите другой --port для backend панели (по умолчанию 3000).'; fi
    if [[ $COMPONENT == node && $TLS_METHOD == http && $PORT == 80 ]]; then die 'HTTP-01 и его продление используют порт 80. Выберите другой API-порт ноды или DNS/готовый сертификат.'; fi
    [[ -n $TLS_METHOD ]] || return 0
    if [[ $TLS_METHOD == existing ]]; then
        tls_helper validate --domain "$domain" --certificate "$CERT_FILE" --key "$KEY_FILE" "${subscription_options[@]}"
    elif [[ $TLS_METHOD == cloudflare || $TLS_METHOD == gcore ]]; then
        tls_helper credentials --method "$TLS_METHOD" --source "$DNS_CREDENTIALS" --target "$WORK/dns-validated.ini"
    elif [[ $TLS_METHOD == http ]]; then port_free 80; fi
}
dns_addresses() {
    # Query public DNS rather than /etc/hosts; bound even hostname resolution time.
    timeout 25 python3 - "$1" <<'PY'
import ipaddress,json,re,sys,urllib.request
host=sys.argv[1]
if not re.fullmatch(r'(?=.{1,253}\Z)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}',host):
    raise SystemExit('Некорректный домен; укажите имя без https://, порта и пути')
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,*args,**kwargs):return None
opener=urllib.request.build_opener(urllib.request.ProxyHandler({}),NoRedirect())
addresses=None
for endpoint in ['https://dns.google/resolve','https://cloudflare-dns.com/dns-query']:
    try:
        found=set()
        for kind in [1,28]:
            request=urllib.request.Request(endpoint+'?name='+host+'&type='+str(kind),headers={'Accept':'application/dns-json'})
            with opener.open(request,timeout=5) as response:body=response.read(131073)
            if len(body)>131072:raise ValueError()
            data=json.loads(body)
            if not isinstance(data,dict) or type(data.get('Status')) is not int or data['Status'] not in [0,3] or data.get('TC') is not False:raise ValueError()
            for row in data.get('Answer',[]):
                if row.get('type')==kind:
                    address=ipaddress.ip_address(row['data'])
                    if address.version!=(4 if kind==1 else 6):raise ValueError()
                    found.add(str(address))
        addresses=found;break
    except (OSError,ValueError,KeyError,TypeError,AttributeError):continue
if addresses is None:raise SystemExit('Публичный DNS недоступен или ответ A/AAAA неполный: '+host)
if not addresses:raise SystemExit('У домена нет A/AAAA: '+host)
print('\n'.join(sorted(addresses)))
PY
}
server_addresses() {
    local addresses='' external family endpoint
    if [[ -n $SERVER_IPS ]]; then
        addresses=${SERVER_IPS//,/$'\n'}
    else
        # Public interfaces cover multihomed servers; HTTPS discovery also covers NAT.
        addresses=$(python3 - <<'PY'
import ipaddress,json,subprocess
try:
    rows=json.loads(subprocess.run(['ip','-j','address','show','scope','global'],capture_output=True,text=True,check=True,timeout=5).stdout)
    print('\n'.join(a['local'] for row in rows for a in row.get('addr_info',[]) if ipaddress.ip_address(a['local']).is_global))
except (OSError,ValueError,KeyError,subprocess.SubprocessError):pass
PY
        )
        for family in 4 6; do
            endpoint=https://api.ipify.org
            [[ $family != 6 ]] || endpoint=https://api6.ipify.org
            if external=$(curl "-$family" --fail --silent --show-error --noproxy '*' --connect-timeout 3 --max-time 5 --max-filesize 128 --proto '=https' "$endpoint" 2>/dev/null); then
                addresses+=$'\n'"$external"
            fi
        done
    fi
    python3 - "$addresses" <<'PY'
import ipaddress,sys
try:
    addresses={ipaddress.ip_address(value.strip()) for value in sys.argv[1].splitlines() if value.strip()}
    if not addresses or any(not a.is_global for a in addresses):raise ValueError()
except ValueError:raise SystemExit('Не удалось определить публичные IP сервера. Укажите --server-ip IPv4[,IPv6].')
print('\n'.join(sorted(map(str,addresses))))
PY
}
check_dns() {
    local domain=$1 actual expected address mismatch=false
    if ! actual=$(dns_addresses "$domain"); then
        printf '  DNS %s не подтверждён. Проверьте записи A/AAAA и доступность DNS; повторите действие.\n' "$domain" >&2
        return 1
    fi
    expected=$(server_addresses) || return $?
    while IFS= read -r address; do
        if ! grep -Fxq -- "$address" <<< "$expected"; then mismatch=true; fi
    done <<< "$actual"
    if $mismatch; then
        info "DNS $domain: ${actual//$'\n'/, }"
        info "IP сервера: ${expected//$'\n'/, }"
        printf '  A/AAAA %s ведут на другой IP. Исправьте записи, включая IPv6, и дождитесь обновления DNS.\n  Для сервера за NAT укажите --server-ip IPv4[,IPv6].\n' "$domain" >&2
        return 1
    fi
    info "✓ A/AAAA $domain указывают на сервер"
}
dns_preflight() {
    # DNS-01 and an external proxy may legitimately use a different frontend IP.
    [[ $TLS_METHOD == auto || $TLS_METHOD == http ]] || return 0
    [[ $COMPONENT != panel || $PROXY == caddy ]] || return 0
    check_dns "${NODE_DOMAIN:-$DOMAIN}" || die 'DNS не соответствует серверу. Контейнеры установки не созданы; исправьте домен и повторите действие.'
    if [[ $COMPONENT == panel ]] && $SUBSCRIPTION_PAGE; then
        local host; local -a hosts=()
        local validated_hosts
        validated_hosts=$(helper subscription-domains --domain "$DOMAIN" --subscription-urls "$SUBSCRIPTION_URLS") || return 1
        mapfile -t hosts <<< "$validated_hosts"
        for host in "${hosts[@]}"; do check_dns "$host" || die 'DNS сайта подписки не соответствует серверу. Исправьте записи и повторите установку.'; done
    fi
}
valid_panel_response() {
    python3 - "$1" <<'PY'
import json,sys
try:
    data=json.load(open(sys.argv[1]));response=data.get('response') if isinstance(data,dict) else None
    if not isinstance(response,dict) or any(type(response.get(k)) is not bool for k in ['isLoginAllowed','isRegisterAllowed']):raise ValueError()
except (OSError,ValueError,TypeError):raise SystemExit('Адрес отвечает, но /api/auth/status не вернул ответ панели. Проверьте домен и reverse proxy.')
PY
}
wait_panel_https() {
    local deadline=$((SECONDS+HTTPS_TIMEOUT)) remaining limit
    while ((SECONDS<deadline)); do
        remaining=$((deadline-SECONDS)); limit=8
        ((remaining>=limit)) || limit=$remaining
        if curl --fail --silent --show-error --noproxy '*' --connect-timeout 3 --max-time "$limit" --max-filesize 1048576 --proto '=https' \
            "https://$DOMAIN/api/auth/status" -o "$WORK/https-status.json" 2> "$WORK/https-error.txt"; then
            if valid_panel_response "$WORK/https-status.json" 2> "$WORK/https-error.txt"; then return 0; fi
        fi
        ((SECONDS<deadline)) || break
        sleep 2
    done
    cat "$WORK/https-error.txt" >&2
    return 1
}
wait_subscription_https() {
    local urls host code deadline remaining limit
    local -a hosts=()
    urls=$(managed_subscription_options); [[ -n $urls ]] || return 0
    local validated_hosts
    validated_hosts=$(helper subscription-domains --domain "$DOMAIN" --subscription-urls "$urls") || return 1
    mapfile -t hosts <<< "$validated_hosts"
    for host in "${hosts[@]}"; do
        deadline=$((SECONDS+HTTPS_TIMEOUT))
        while ((SECONDS<deadline)); do
            remaining=$((deadline-SECONDS)); limit=8; ((remaining>=limit)) || limit=$remaining
            code=$(curl --silent --show-error --noproxy '*' --connect-timeout 3 --max-time "$limit" --max-filesize 1048576 --proto '=https' \
                "https://$host/" -o /dev/null -w '%{http_code}' 2> "$WORK/subscription-https-error.txt") || code=''
            # The page needs a user's short UUID; the bare domain normally returns 404.
            [[ $code != 200 && $code != 404 ]] || break
            sleep 2
        done
        if [[ $code != 200 && $code != 404 ]]; then
            printf '  HTTPS сайта %s не подтверждён; проверьте DNS и Caddy.\n' "$host" >&2
            return 1
        fi
    done
}
https_diagnostics() {
    printf '  HTTPS %s не подтверждён. Проверьте A/AAAA, доступ к TCP 80/443 и firewall сервера/провайдера.\n' "$DOMAIN" >&2
    if [[ -f $WORK/https-error.txt ]]; then head -c 600 "$WORK/https-error.txt" >&2; printf '\n' >&2; fi
    if [[ " ${EXTRAS[*]} " == *' caddy '* ]]; then compose logs --tail 30 --no-color caddy >> "$LOG" 2>&1 || true; fi
    printf '  Запущенная панель и данные сохранены. После исправления: sudo bash installer.sh check-panel\n  Журнал, включая Caddy: %s\n' "$LOG" >&2
}
obtain_certificate() {
    local domain=${NODE_DOMAIN:-$DOMAIN} lineage
    local -a domains=(--domain "$domain") hosts=(); local subscriptions host
    subscriptions=$(managed_subscription_options)
    if [[ -n $subscriptions ]]; then
        local validated_hosts
        validated_hosts=$(helper subscription-domains --domain "$domain" --subscription-urls "$subscriptions") || return 1
        mapfile -t hosts <<< "$validated_hosts"
        for host in "${hosts[@]}"; do domains+=(--domain "$host"); done
    fi
    [[ $COMPONENT != panel || $PROXY == caddy ]] || return 0
    [[ -n $TLS_METHOD && $TLS_METHOD != auto && $TLS_METHOD != existing ]] || return 0
        ACME_ROOT="$ROOT/acme/${PROJECT:-remnacust-$COMPONENT}"
        install -d -m 0700 "$ACME_ROOT"
        CERTBOT="$ROOT/tools/certbot/bin/certbot"
        if [[ ! -x $CERTBOT ]] || ! "$CERTBOT" plugins --authenticators --config-dir "$ACME_ROOT/config" --work-dir "$ACME_ROOT/work" --logs-dir "$ACME_ROOT/logs" 2>/dev/null | grep -q dns-gcore; then
            package_step 'Пакеты для ACME' update -o APT::Update::Error-Mode=any || return $?
            package_step 'Python venv и OpenSSL' install python3-venv openssl || return $?
            [[ -x $ROOT/tools/certbot/bin/python ]] || step 'Среда Certbot' python3 -m venv "$ROOT/tools/certbot"
            step 'Certbot и DNS-плагины' "$ROOT/tools/certbot/bin/pip" install --disable-pip-version-check --only-binary=:all: certbot==5.8.0 certbot-dns-cloudflare==5.8.0 certbot-dns-gcore==0.1.8
        fi
        local -a auth=(--standalone)
        if [[ $TLS_METHOD == cloudflare || $TLS_METHOD == gcore ]]; then
            tls_helper credentials --method "$TLS_METHOD" --source "$DNS_CREDENTIALS" --target "$ACME_ROOT/dns.ini"
            auth=(--authenticator "dns-$TLS_METHOD" "--dns-$TLS_METHOD-credentials" "$ACME_ROOT/dns.ini" "--dns-$TLS_METHOD-propagation-seconds" 90)
        else port_free 80; fi
        local acme_open=false cert_status=0
        if [[ $COMPONENT == node && $TLS_METHOD == http && -n $PANEL_IP ]] && command -v nft >/dev/null; then
            python3 -I "$HELPER_ROOT/node_firewall.py" acme-open
            acme_open=true
        fi
        step 'Сертификат Let’s Encrypt' acme_certbot "$CERTBOT" certonly --config-dir "$ACME_ROOT/config" --work-dir "$ACME_ROOT/work" --logs-dir "$ACME_ROOT/logs"             --non-interactive --agree-tos --email "$EMAIL" --cert-name "$domain" "${domains[@]}" "${auth[@]}" || cert_status=$?
        if $acme_open; then python3 -I "$HELPER_ROOT/node_firewall.py" acme-close || cert_status=1; fi
        if ((cert_status != 0)); then
            info "Подробности ACME: $ACME_ROOT/logs/letsencrypt.log"
            return "$cert_status"
        fi
        lineage="$ACME_ROOT/config/live/$domain"
        CERT_FILE="$lineage/fullchain.pem"; KEY_FILE="$lineage/privkey.pem"
}
acme_certbot() {
    if [[ $TLS_METHOD == http && ( $COMPONENT != node || -n $PANEL_IP ) ]]; then
        python3 -I "$HELPER_ROOT/ufw_guard.py" --root "$ROOT" -- "$@"
    else "$@"; fi
}
configure_certificate() {
    local domain=${NODE_DOMAIN:-$DOMAIN} hook service renew_cli
    local -a subscription_options=(); local subscriptions
    subscriptions=$(managed_subscription_options)
    [[ -z $subscriptions ]] || subscription_options=(--subscription-urls "$subscriptions")
    [[ $COMPONENT != panel || $PROXY == caddy ]] || return 0
    [[ -n $TLS_METHOD && $TLS_METHOD != auto ]] || return 0
    tls_helper copy --domain "$domain" --certificate "$CERT_FILE" --key "$KEY_FILE" --directory "$DEPLOY" "${subscription_options[@]}"
    tls_helper record --state "$STATE" --method "$TLS_METHOD" --certificate "$CERT_FILE" --key "$KEY_FILE"
    helper_file_copy "$STATE" "$ROOT/registry/$COMPONENT.json"
    if [[ $COMPONENT == node ]]; then
        helper node-proxy --directory "$DEPLOY" --domain "$domain" --node-site-mode "${NODE_SITE_MODE:-selfsteal}" --node-site-port "${NODE_SITE_PORT:-443}"
        step 'Проверка Nginx' compose run --rm --no-deps --entrypoint nginx node-nginx -t
    else step 'Проверка Caddy' compose run --rm --no-deps --entrypoint caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile; fi
    schedule_certificate_renewal
}
schedule_certificate_renewal() {
    local domain=${NODE_DOMAIN:-$DOMAIN} hook service renew_cli
    [[ $TLS_METHOD != auto ]] || return 0
    ACME_ROOT=${ACME_ROOT:-$ROOT/acme/$PROJECT}
    CERTBOT=${CERTBOT:-$ROOT/tools/certbot/bin/certbot}
    install -d -m 0700 "$ACME_ROOT"
    if [[ $TLS_METHOD != existing ]]; then
        hook="$ACME_ROOT/deploy-hook.sh"; renew_cli="$ACME_ROOT/renew.sh"
        printf '#!/usr/bin/env bash\nset -eu\nexport REMNACUST_ROOT=%q\nexec /usr/local/bin/remnacust renew-%s-certificate --yes\n' "$ROOT" "$COMPONENT" > "$hook"
        local -a renewal_hooks=()
        if [[ $COMPONENT == node && $TLS_METHOD == http && -n $PANEL_IP ]]; then
            printf '#!/usr/bin/env bash\nset -eu\nexec /usr/bin/python3 -I /etc/remnacust-node-firewall/guard.py acme-open\n' > "$ACME_ROOT/acme-open.sh"
            printf '#!/usr/bin/env bash\nset -eu\nexec /usr/bin/python3 -I /etc/remnacust-node-firewall/guard.py acme-close\n' > "$ACME_ROOT/acme-close.sh"
            chmod 0700 "$ACME_ROOT/acme-open.sh" "$ACME_ROOT/acme-close.sh"
            renewal_hooks=(--pre-hook "$ACME_ROOT/acme-open.sh" --post-hook "$ACME_ROOT/acme-close.sh")
        fi
        local -a renewal_command=("$CERTBOT")
        if [[ $COMPONENT != node || -n $PANEL_IP ]]; then
            install -m 0700 "${HELPER%/*}/ufw_guard.py" "$ACME_ROOT/ufw_guard.py"
            renewal_command=(/usr/bin/python3 -I "$ACME_ROOT/ufw_guard.py" --root "$ROOT" -- "$CERTBOT")
        fi
        { printf '#!/usr/bin/env bash\nset -eu\nexec '; printf '%q ' "${renewal_command[@]}"; printf 'renew --quiet --config-dir %q --work-dir %q --logs-dir %q --deploy-hook %q' "$ACME_ROOT/config" "$ACME_ROOT/work" "$ACME_ROOT/logs" "$hook"; if ((${#renewal_hooks[@]})); then printf ' %q' "${renewal_hooks[@]}"; fi; printf '\n'; } > "$renew_cli"
        chmod 0700 "$hook" "$renew_cli"
        service="remnacust-acme-$PROJECT"
        tls_helper timer --service "$service" --script "$renew_cli"
        systemctl daemon-reload
        systemctl enable --now "$service.timer"
    else info "Готовый сертификат подключён. После продления выполните remnacust renew-$COMPONENT-certificate."; fi
}
panel_continuity_preflight() {
    [[ $ACTION == upgrade-panel && $COMPONENT == panel ]] || return 0
    if $ALLOW_DISRUPTION; then
        info 'ВНИМАНИЕ: --allow-disruption: работа нод во время обновления панели не гарантируется.'
        return 0
    fi
    local id count
    # Discovery captured the current container before any Compose changes.
    if ! id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[0]["Id"])' "$WORK/container.before.json" 2>/dev/null) ||
       [[ ! $id =~ ^[a-f0-9]{12,64}$ ]]; then
        info 'ВНИМАНИЕ: проверить автономность нод не удалось. Обновление продолжается; у зависимых от панели нод возможен перерыв связи.'
        return 0
    fi
    # Inspect the entry without executing it: an old CLI may open an interactive menu.
    if ! timeout --kill-after=5s 10s docker exec "$id" node -e '
try {
    const fs = require("node:fs"), file = "/opt/app/dist/cli.js";
    const stat = fs.statSync(file);
    if (!stat.isFile() || stat.size > 16 * 1024 * 1024 ||
        !fs.readFileSync(file, "utf8").includes("check-node-continuity")) process.exit(1);
} catch { process.exit(1); }
' >/dev/null 2>&1; then
        # Use the already verified candidate image to check older panels without
        # executing their interactive CLI or stopping their applications.
        if ! count=$(python3 -I "$HELPER_ROOT/panel_continuity.py" --inspect "$WORK/container.before.json" --image "$IMAGE" 2>/dev/null) ||
           [[ ! $count =~ ^[0-9]{1,5}$ ]]; then
            info 'ВНИМАНИЕ: автономность нод не подтверждена. Обновление продолжается; у зависимых от панели нод возможен перерыв связи.'
            return 0
        fi
        info "Непрерывность работы нод подтверждена: $count."
        return 0
    fi
    # Bound both runtime and output inside the container. Only a validated count
    # crosses into installer output; CLI diagnostics may contain private details.
    if ! count=$(timeout --kill-after=5s 130s docker exec "$id" node -e '
try {
    const result = require("node:child_process").spawnSync(process.execPath,
        ["/opt/app/dist/cli.js", "check-node-continuity"],
        { timeout: 120000, maxBuffer: 16384, killSignal: "SIGKILL", stdio: ["ignore", "pipe", "ignore"] });
    if (result.error || result.signal || result.status !== 0) process.exit(1);
    const value = JSON.parse(result.stdout.toString("utf8"));
    if (value?.ready !== true || !Number.isSafeInteger(value.nodeCount) || value.nodeCount < 0) process.exit(1);
    process.stdout.write(String(value.nodeCount));
} catch { process.exit(1); }
' 2>/dev/null) || [[ ! $count =~ ^[0-9]{1,16}$ ]]; then
        info 'ВНИМАНИЕ: автономность нод не подтверждена. Обновление продолжается; у зависимых от панели нод возможен перерыв связи.'
        return 0
    fi
    info "Непрерывность работы нод подтверждена: $count."
}
node_firewall_cleanup() {
    local record=${1:-$STATE}
    local -a cleanup_options=(--owner-root "$ROOT")
    if [[ -n $record && -f $record ]]; then
        local previous_api previous_https
        previous_api=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("apiPort",0))' "$record") || return $?
        previous_https=$(python3 -c 'import json,sys;s=json.load(open(sys.argv[1]));print(s.get("nodeSitePort",443) if s.get("nodeSiteMode")=="standalone" else 0)' "$record") || return $?
        cleanup_options+=(--api-port "$previous_api" --https-port "$previous_https")
    fi
    python3 -I "$HELPER_ROOT/node_firewall.py" uninstall --owner-root "$ROOT" || return $?
    if ((${#cleanup_options[@]} > 2)); then
        python3 -I "$HELPER_ROOT/node_firewall.py" uninstall "${cleanup_options[@]}" || return $?
    fi
}
node_acl_without_panel() {
    [[ -z $PANEL_IP ]] || return 0
    node_firewall_cleanup
}
node_acl() {
    local https_port=0
    if [[ $PANEL_IP == managed ]]; then PANEL_IP=$(python3 -c 'import json;print(json.load(open("/etc/remnacust-node-firewall/state.json"))["panel"])') || return $?; fi
    if [[ -z $PANEL_IP ]]; then
        node_acl_without_panel || return $?
        info "IP панели не задан: правила доступа не добавляются. Доступ к TCP $PORT настройте в своём firewall."
        return 0
    fi
    if [[ -n $STATE && -f $STATE ]]; then
        https_port=$(python3 -c 'import json,sys;s=json.load(open(sys.argv[1]));print(s.get("nodeSitePort",443) if s.get("nodeSiteMode")=="standalone" else 0)' "$STATE") || return $?
    fi
    if [[ $https_port != 0 || ( -n $NODE_SITE_MODE && ( -f /etc/ufw/applications.d/remnacust-node-site || -f /etc/remnacust-node-firewall/state.json ) ) ]]; then
        python3 -I "$HELPER_ROOT/node_firewall.py" site --https-port "$https_port" || return $?
    fi
    command -v nft >/dev/null || package_step 'Сетевая защита ноды' install --no-install-recommends nftables || return $?
    local api_port inbound_port
    api_port=$(get apiPort)
    inbound_port=$(python3 -c 'import json,sys;s=json.load(open(sys.argv[1]));print(s.get("nodeInboundPort",8443) if s.get("nodeSiteMode")=="standalone" else "")' "$STATE") || return $?
    local -a control_options=(--api-port "$api_port")
    [[ -z $inbound_port ]] || control_options+=(--inbound-port "$inbound_port")
    python3 -I "$HELPER_ROOT/node_firewall.py" apply --panel "$PANEL_IP" --https-port "$https_port" --owner-root "$ROOT" "${control_options[@]}"
    if [[ $https_port == 0 ]]; then
        info "Все входящие порты и ping разрешены только от $PANEL_IP; SSH сохранён. Клиенты VPN должны идти через главный сервер."
    else
        info "HTTPS сайта TCP $https_port доступен посетителям; остальные порты и ping только от $PANEL_IP. SSH сохранён."
    fi
    info 'Отмена ограничения: python3 /etc/remnacust-node-firewall/guard.py remove'
}
deploy() {
    [[ $ACTION == install-panel || $ACTION == install-node || $ACTION == upgrade-node || $ACTION == migrate-remnawave-node || $PANEL_NET_ADMIN_SET == false ]] || die '--net-admin/--no-net-admin доступны для новой панели, установки, переноса или обновления ноды'
    [[ $ACTION == install-* || -z $PORT ]] || die '--port задаёт порт новой установки. Обновление и миграция сохраняют фактический порт существующего контейнера.'
    if [[ $ACTION == install-* ]]; then
        info "$ACTION · новая установка $COMPONENT"
    else info "$ACTION · настройки и данные будут сохранены"; fi
    choose_version
    confirm "Выполнить $ACTION ($VERSION)"
    prepare_host; lock_operation
    if [[ $ACTION == install-* ]]; then
        assert_fresh_target; select_fresh_target; certificate_wizard
    fi
    trap recover ERR
    release_source
    if [[ $ACTION == install-* ]]; then
        if [[ $COMPONENT == panel ]]; then panel_net_admin_wizard; else node_net_admin_wizard; fi
        if [[ $COMPONENT == panel ]]; then subscription_wizard; fi
        if [[ $COMPONENT == panel ]]; then PORT=${PORT:-3000}; else PORT=${PORT:-2222}; fi
        local -a installation_validation=(--domain "$DOMAIN" --node-domain "$NODE_DOMAIN" --port "$PORT" --project "${PROJECT:-remnacust-$COMPONENT}")
        [[ -z $PANEL_IP ]] || installation_validation+=(--key "$PANEL_IP")
        helper validate "${installation_validation[@]}"
        port_free "$PORT"
        if [[ $COMPONENT == panel ]] && $SUBSCRIPTION_PAGE; then
            SUBSCRIPTION_PORT=$(choose_subscription_port "$SUBSCRIPTION_PORT" "$PORT") || return $?
        fi
        if [[ $COMPONENT == panel && $PROXY == caddy ]]; then port_free 80; port_free 443; fi
        certificate_preflight
        dns_preflight
        if [[ $COMPONENT == panel ]]; then backup_password_wizard; fi
    fi
    step "Подготовка образа $COMPONENT" prepare_image
    if [[ $ACTION == install-panel ]] && $SUBSCRIPTION_PAGE; then
        select_subscription_image
        step 'Готовый образ сайта подписки' prepare_subscription_image
    fi
    if [[ $ACTION == install-* ]]; then
        if [[ $COMPONENT == node && -z $PANEL_IP ]]; then node_acl_without_panel || return $?; fi
        obtain_certificate
        fresh_files
        helper record --state "$STATE" --version "${COMPONENT_VERSION:-${TAG#v}}" --image "$IMAGE" --running "${START_APPS[@]}"
        archive_retired_registry
        helper_file_copy "$STATE" "$ROOT/registry/$COMPONENT.json"
        # Keep recovery commands available if first boot or certificate issuance fails.
        install_cli
        configure_panel_updates "$DEPLOY/docker-compose.yml"
        if [[ $COMPONENT == panel ]]; then step 'Защита резервных копий' initialize_panel_backups; fi
        configure_certificate
        if [[ $COMPONENT == node ]]; then node_acl; fi
        step 'Запуск установки' compose up -d --no-build
        # Compose may create its bridge only on first start. Refresh the owned
        # guard before readiness checks so container-originated traffic works.
        if [[ $COMPONENT == node && -n $PANEL_IP ]]; then node_acl; fi
    else
        if [[ $ACTION == upgrade-* && -z $DIRECTORY$CONTAINER$COMPOSE_FILE && -f $ROOT/registry/$COMPONENT.json ]]; then
            STATE="$ROOT/registry/$COMPONENT.json"; load_state
            CONTAINER=$(compose ps --all --quiet "$(get mainService)")
        fi
        if [[ -z $CONTAINER$DIRECTORY$COMPOSE_FILE ]]; then
            local -a detected=(); mapfile -t detected < <(component_containers "$COMPONENT")
            ((${#detected[@]} != 1)) || CONTAINER=${detected[0]}
        fi
        find_existing
        helper check-upgrade --source "$WORK/compose.before.json" --state "$STATE" --inspect "$WORK/project-containers.json" --version "${COMPONENT_VERSION:-${TAG#v}}" --key "$TAG" || return $?
        node_migration_wizard
        if [[ $COMPONENT == node ]]; then node_net_admin_wizard "$WORK/compose.after.json"; fi
        if [[ $COMPONENT == panel ]]; then
            database_environment; check_writers
            step 'Проверка истории миграций и исходных ключей' database_run preflight
        fi
        report_update_progress preparation 'Проверка текущей установки' done
        report_update_progress backup 'Резервная копия текущей установки' running
        backup_current
        report_update_progress backup 'Резервная копия текущей установки' done
        configure_panel_updates "$WORK/compose.after.json"
        if [[ $COMPONENT == node ]]; then
            helper plan-node-state --source "$WORK/compose.after.json" --inspect "$WORK/container.before.json" --directory "$DEPLOY" --target "$WORK/node-state-plan.json"
        fi
        # Validate the merged candidate while the original applications run.
        docker compose --project-name "$PROJECT" --project-directory "$DEPLOY" -f "$WORK/compose.after.json" \
            --profile '*' config --no-interpolate --no-env-resolution --format json > "$WORK/compose.validated.json"
        report_update_progress applying 'Обновление приложений' running
        panel_continuity_preflight
        CHANGED=true
        helper commit-compose --source "$WORK/compose.after.json" --state "$STATE" --directory "$BACKUP" \
            --version "${COMPONENT_VERSION:-${TAG#v}}" --key "$TAG"
        load_state
        compose --profile '*' config --no-interpolate --no-env-resolution --format json > "$WORK/compose.committed.json"
        python3 - "$WORK/compose.validated.json" "$WORK/compose.committed.json" <<'PY'
import json,sys
before,after=[json.load(open(path)) for path in sys.argv[1:]]
before.pop('x-remnacust-release',None);after.pop('x-remnacust-release',None)
if before!=after:raise SystemExit('Основной Compose отличается от проверенной конфигурации; обновление остановлено')
PY
        compose stop "${APPS[@]}"
        if [[ $COMPONENT == node ]]; then
            step 'Сохранение настроек и лимитов ноды' helper snapshot-node-state --source "$WORK/node-state-plan.json"
            helper preserve-node-state-rollback --source "$WORK/node-state-plan.json" --directory "$BACKUP"
            step 'Проверка совместимости обновления ноды' verify_node_image_policy
        fi
        if [[ $COMPONENT == panel ]]; then
            # Refresh the dump after all known writers have stopped. Infrastructure stays running.
            step 'Финальная копия PostgreSQL' backup_panel_data
            database_run snapshot > "$BACKUP/fingerprints.json"; backup_hashes
            DB_CHANGED=true
            step 'Совместимость старой базы' docker run --rm --network "$(cat "$WORK/database.network")" --env-file "$WORK/database.env" --entrypoint node "$IMAGE" dist/database-compatibility.js --apply
        fi
        step 'Запуск обновлённых приложений' compose up -d --no-deps --no-build --pull never "${START_APPS[@]}"
    fi
    step 'Проверка готовности приложений' wait_ready
    if [[ $COMPONENT == node ]] && python3 -c 'import json,sys;sys.exit(json.load(open(sys.argv[1])).get("nodeSiteMode")!="standalone")' "$STATE"; then
        step 'Проверка HTTPS-сайта' helper node-https --state "$STATE"
    fi
    if [[ $COMPONENT == node ]] && $NODE_NET_ADMIN; then
        local actual_capability
        actual_capability=$(node_effective_net_admin "$(compose ps --all --quiet "$(get mainService)")") || actual_capability=unknown
        if [[ $actual_capability != yes ]]; then
            info 'NET_ADMIN запрошен в Compose, но после запуска не подтверждён. Сетевые функции могут быть ограничены настройками хоста.'
        fi
    fi
    if [[ $ACTION == install-panel ]] && $SUBSCRIPTION_PAGE; then
        step 'Подключение сайта подписки' initialize_subscription_page
        START_APPS+=(remnawave-subscription-page)
    fi
    if [[ $ACTION == install-panel && $PROXY == caddy ]]; then
        if ! step 'Ожидание HTTPS панели (до 3 минут)' wait_panel_https; then https_diagnostics; return 1; fi
        if ! step 'Проверка HTTPS сайта подписки' wait_subscription_https; then https_diagnostics; return 1; fi
    fi
    if [[ $ACTION != install-* ]]; then
        docker inspect "$(compose ps --all --quiet "$(get mainService)")" > "$WORK/container.after.json"
        local -a compare_options=()
        if [[ $COMPONENT == node ]] && $NODE_NET_ADMIN_ADDED; then compare_options=(--key net-admin-added); fi
        helper compare --source "$WORK/container.before.json" --inspect "$WORK/container.after.json" "${compare_options[@]}"
        if [[ $COMPONENT == panel ]]; then step 'Проверка сохранности данных' verify_database; fi
    fi
    helper record --state "$STATE" --version "${COMPONENT_VERSION:-${TAG#v}}" --image "$IMAGE" --running "${START_APPS[@]}"
    helper_file_copy "$STATE" "$ROOT/registry/$COMPONENT.json"
    if [[ $ACTION != install-* ]]; then install_cli; fi
    CHANGED=false; trap - ERR
    node_migration_finish
    if [[ $COMPONENT == panel ]] && python3 -c 'import json,sys;sys.exit(not json.load(open(sys.argv[1])).get("subscriptionMigration"))' "$STATE"; then
        step 'Перенос и проверка страницы подписки' subscription_migration_apply
        helper_file_copy "$STATE" "$ROOT/registry/$COMPONENT.json"
    fi
    step 'Подготовка рабочего каталога' python3 -I "$HELPER_ROOT/deployment_layout.py" --root "$ROOT" --component "$COMPONENT"
    helper_file_copy "$ROOT/registry/$COMPONENT.json" "$STATE"
    load_state
    compose --profile '*' config --no-interpolate --no-env-resolution --format json > "$WORK/compose.layout.json"
    helper layout --state "$STATE" --source "$WORK/compose.layout.json"
    if ! python3 -I "$HELPER_ROOT/deployment_layout.py" --root "$ROOT" --cleanup-backups; then
        info 'Не все старые копии удалось архивировать. Рабочие файлы сохранены; повторите cleanup-backups после проверки журнала.'
    fi
    if [[ $ACTION == upgrade-* || $ACTION == migrate-remnawave-* ]]; then
        cleanup_old_images
    fi
    completion_summary
    if [[ ${REMNACUST_MENU_COMPLETION_FD:-} == 3 ]]; then printf 'completed\n' >&3; fi
}
cleanup_old_images() {
    report_update_progress cleanup 'Очистка старых образов' running
    local cleaner="$HELPER_ROOT/image_cleanup.py"
    [[ -f $cleaner ]] || return 0
    local -a options=(--component "$COMPONENT" --keep "$IMAGE")
    [[ ! -f $WORK/project-containers.json ]] || options+=(--before "$WORK/project-containers.json")
    [[ -z $SUBSCRIPTION_IMAGE ]] || options+=(--keep "$SUBSCRIPTION_IMAGE")
    if python3 "$cleaner" "${options[@]}" >> "$LOG" 2>&1; then
        report_update_progress cleanup 'Очистка старых образов' done
        info 'Старые образы очищены; текущая и предыдущая версии сохранены'
    else
        report_update_progress cleanup 'Очистка образов отложена; обновление завершено' done
        info 'Обновление готово; очистка образов отложена, подробности в журнале'
    fi
}

completion_row() {
    if (($(terminal_width) >= 64)); then
        printf '  %s %s%s%s\n' "$1" "$BOLD" "$2" "$RESET"
    else
        terminal_text "$1" '  ' '  ' "$DIM"
        printf '    %s%s%s\n' "$BOLD" "$2" "$RESET"
    fi
}
completion_summary() {
    local -a details=()
    python3 - "$STATE" "$DOMAIN" "$NODE_DOMAIN" "$PORT" "$PROXY" "$TLS_METHOD" "$CERT_FILE" "$KEY_FILE" > "$WORK/completion-details" <<'PY'
import json,sys
from pathlib import Path
s=json.load(open(sys.argv[1]));directory=s['directory'];env={}
p=Path(directory)/'.env'
if p.is_file():
 for line in p.read_text().splitlines():
  key,sep,value=line.partition('=')
  if sep and key in {'FRONT_END_DOMAIN','PANEL_DOMAIN','NODE_PORT','SUB_PUBLIC_DOMAIN'}:env[key]=value.strip().strip('"\'')
panel=sys.argv[2] or s.get('panelDomain') or env.get('FRONT_END_DOMAIN') or env.get('PANEL_DOMAIN','')
if panel and not panel.startswith(('http://','https://')):panel='https://'+panel
tls=s.get('tls',{})
subscriptions=s.get('subscriptionUrls',[])
primary=env.get('SUB_PUBLIC_DOMAIN','')
if primary:
 primary=primary if primary.startswith(('http://','https://')) else 'https://'+primary
 subscriptions=[primary]+[url for url in subscriptions[1:] if url!=primary]
for value in [directory,panel,sys.argv[3] or s.get('nodeDomain',''),s.get('apiPort') or s.get('nodePort') or s.get('port') or sys.argv[4] or env.get('NODE_PORT',''),s.get('proxy',sys.argv[5]),tls.get('method',sys.argv[6]),tls.get('certificate',sys.argv[7]),tls.get('key',sys.argv[8]),', '.join(s.get('composeFiles',[])),', '.join(subscriptions)]:
 print(str(value).replace('\n',' ').replace('\r',' '))
PY
    mapfile -t details < "$WORK/completion-details"
    local directory=${details[0]} url=${details[1]} node_domain=${details[2]} port=${details[3]} proxy=${details[4]} method=${details[5]} certificate=${details[6]} key=${details[7]}
    local heading='Установка завершена'
    case "$ACTION" in upgrade-*) heading='Обновление завершено';; migrate-*) heading='Перенос завершён';; esac
    terminal_section "$heading"
    completion_row 'Компонент:' "$COMPONENT v${COMPONENT_VERSION:-${TAG#v}} · установщик $TAG"
    if [[ $COMPONENT == panel ]]; then
        if [[ -n $url ]]; then completion_row 'Адрес входа:' "$url"
        else completion_row 'Адрес входа:' 'Ваш прежний домен панели'; fi
        if [[ -n ${details[9]} ]]; then
            local -a subscriptions=()
            IFS=',' read -r -a subscriptions <<< "${details[9]}"
            completion_row 'Сайт подписки:' "${subscriptions[0]}"
            if ((${#subscriptions[@]} > 1)); then completion_row 'Дополнительный адрес:' "${subscriptions[1]# }"; fi
        fi
        if [[ $ACTION == install-panel ]]; then
            completion_row 'Администратор:' 'Создайте аккаунт при первом входе'
            completion_row 'Пароль:' 'От 24 символов: A–Z, a–z и цифры'
            if [[ -f $directory/backup-password.txt && ! -L $directory/backup-password.txt ]]; then
                completion_row 'Пароль резервных копий:' "$(cat "$directory/backup-password.txt")"
                completion_row 'Сохранён в файле:' "$directory/backup-password.txt · доступ только root"
                completion_row 'Резервные копии:' 'Используйте этот пароль для открытия раздела и расшифровки копий; сохраните отдельно от сервера'
            fi
        else completion_row 'Авторизация:' 'Прежние имя пользователя и пароль'; fi
        if [[ $proxy == caddy ]]; then completion_row 'HTTPS:' 'Caddy в Docker'
        else
            completion_row 'HTTPS:' 'Ваш существующий Nginx/Caddy'
            completion_row 'Сертификат:' 'Путь указан в конфигурации вашего proxy; установщик его не меняет'
        fi
        if [[ -n $(managed_subscription_options) ]]; then
            completion_row 'Сайт подписки установлен:' 'Токен только для чтения подписок и оформления'
            completion_row 'Настройки сайта:' "$directory/subscription.env · доступ только root"
            if [[ $proxy == existing ]]; then
                completion_row 'Upstream сайта:' "http://127.0.0.1:$(get subscriptionPort) · для обоих доменов сайта"
                completion_row 'Пример Caddy:' "$directory/Caddyfile · внутри Docker; для системного proxy используйте loopback upstream"
            fi
        fi
    else
        local addresses address
        if addresses=$(server_addresses 2>/dev/null); then
            while IFS= read -r address; do
                completion_row 'Адрес в панели:' "$address"
            done <<< "$addresses"
        else completion_row 'Адрес в панели:' 'Публичный IP этого сервера (не IP панели)'; fi
        completion_row 'API ноды:' "Адрес этого сервера · TCP ${port:-2222}"
        completion_row 'Порт в панели:' "${port:-2222}"
        completion_row 'Подключение:' 'Ноды → создать/редактировать → адрес, порт ноды и профиль'
        completion_row 'SSH:' 'Отдельный порт доступа к серверу; установщик его не меняет'
        [[ -z $node_domain ]] || completion_row 'TLS/XHTTP домен:' "$node_domain"
        local site_mode site_port inbound_port
        site_mode=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("nodeSiteMode","selfsteal"))' "$STATE")
        if [[ $site_mode == standalone ]]; then
            site_port=$(get nodeSitePort); inbound_port=$(get nodeInboundPort)
            completion_row 'HTTPS-сайт:' "https://$node_domain:$site_port/"
            completion_row 'Вход Xray в панели:' "TCP $inbound_port — задайте этот порт в профиле"
            completion_row 'REALITY target:' "127.0.0.1:$site_port · xver: 0"
        fi
        if [[ $ACTION == install-node ]]; then completion_row 'Ключ ноды:' "$directory/.env · SECRET_KEY"
        else completion_row 'Ключ ноды:' 'Сохранён из прежнего контейнера · SECRET_KEY в Compose'; fi
    fi
    completion_row 'Карта файлов:' "$directory/FILES.txt (скрытые .env: ls -la)"
    completion_row 'Файл настроек:' "$directory/.env"
    [[ -z ${details[8]:-} ]] || completion_row 'Compose:' "${details[8]}"
    if [[ -n $certificate ]]; then
        completion_row 'Исходный сертификат:' "$certificate"
        completion_row 'Исходный ключ TLS:' "$key"
        completion_row 'Копия сертификата:' "$directory/certs/fullchain.pem"
        completion_row 'Копия ключа TLS:' "$directory/certs/privkey.pem"
        if [[ $COMPONENT == node ]]; then completion_row 'В Xray:' '/var/lib/remnacust/tls/fullchain.pem и /var/lib/remnacust/tls/privkey.pem'; fi
        if [[ $method == existing ]]; then completion_row 'После продления:' "remnacust renew-$COMPONENT-certificate"
        else completion_row 'Продление TLS:' "remnacust-acme-$(get project).timer"; fi
    elif [[ $COMPONENT == panel && $proxy == caddy ]]; then
        completion_row 'Сертификат:' 'Caddy получает и продлевает автоматически; хранилище /data в контейнере caddy'
    fi
    completion_row 'Состояние:' "remnacust status --component $COMPONENT"
    completion_row 'Журнал приложений:' "remnacust logs --component $COMPONENT"
    [[ -z $LOG ]] || completion_row 'Журнал установки:' "$LOG"
    printf '\n'
}
helper_file_copy() {
    python3 - "$HELPER" "$1" "$2" <<'PY'
import importlib.util,sys
spec=importlib.util.spec_from_file_location('installer_runtime',sys.argv[1]);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
m.write(sys.argv[3],m.load(sys.argv[2]))
PY
}
service_action() {
    if [[ $ACTION == uninstall-* ]]; then
        command -v python3 >/dev/null || die 'Для удаления нужен python3'
        command -v docker >/dev/null || die 'Docker недоступен'
        lock_operation; uninstall_component; return
    fi
    if [[ $ACTION != status || -n $COMPONENT ]]; then
        COMPONENT=${COMPONENT:-panel}; assert_not_uninstalled
    fi
    installed_helper; lock_operation
    if [[ $ACTION == status && -z $COMPONENT ]]; then
        local item found=false
        for item in panel node; do if [[ -f $ROOT/registry/$item.json ]]; then STATE="$ROOT/registry/$item.json"; load_state; compose ps --all; found=true; fi; done
        python3 -I "$HELPER_ROOT/subscription_pages.py" list --root "$ROOT" > "$WORK/managed-page-status.json"
        if [[ $(cat "$WORK/managed-page-status.json") != '[]' ]]; then cat "$WORK/managed-page-status.json"; found=true; fi
        $found || info 'Нет зарегистрированных установок'; return 0
    fi
    COMPONENT=${COMPONENT:-panel}; STATE="$ROOT/registry/$COMPONENT.json"
    if [[ ! -f $STATE ]]; then
        IMAGE=discovery-only
        find_existing
    else load_state; fi
    assert_not_uninstalled
    case "$ACTION" in
        status) compose ps --all;;
        check-panel)
            DOMAIN=${DOMAIN:-$(get panelDomain)}
            [[ -n $DOMAIN ]] || die 'Домен не записан в старой установке; укажите check-panel --domain DOMAIN'
            PROXY=$(get proxy)
            TLS_METHOD=$(python3 - "$STATE" <<'PY'
import json,sys
print(json.load(open(sys.argv[1])).get('tls',{}).get('method','auto'))
PY
            )
            if [[ $PROXY == caddy && $TLS_METHOD == auto ]]; then check_dns "$DOMAIN" || return 1; fi
            if [[ $PROXY == caddy && $TLS_METHOD == auto && -n $(managed_subscription_options) ]]; then
                local checked_hosts host; local -a subscription_hosts=()
                checked_hosts=$(helper subscription-domains --domain "$DOMAIN" --subscription-urls "$(managed_subscription_options)") || return 1
                mapfile -t subscription_hosts <<< "$checked_hosts"
                for host in "${subscription_hosts[@]}"; do check_dns "$host" || return 1; done
            fi
            if ! step 'Ожидание HTTPS панели (до 3 минут)' wait_panel_https; then https_diagnostics; return 1; fi
            if ! step 'Проверка HTTPS сайта подписки' wait_subscription_https; then https_diagnostics; return 1; fi
            info "✓ Панель отвечает по HTTPS: https://$DOMAIN";;
        logs) compose logs --tail 100 --no-color "${APPS[@]}" "${EXTRAS[@]}";;
        start)
            mapfile -t START_APPS < <(get runningApplications)
            ((${#START_APPS[@]})) || START_APPS=("${APPS[@]}")
            local extra
            for extra in "${EXTRAS[@]}"; do [[ " ${START_APPS[*]} " == *" $extra "* ]] || START_APPS+=("$extra"); done
            if [[ $COMPONENT == panel && -n $(managed_subscription_options) ]]; then
                [[ " ${START_APPS[*]} " == *' remnawave-subscription-page '* ]] || START_APPS+=(remnawave-subscription-page)
            fi
            if [[ $COMPONENT == panel && -n $(managed_subscription_options) && ! -s $DEPLOY/subscription.env ]]; then
                local -a bootstrap_apps=()
                for extra in "${START_APPS[@]}"; do [[ $extra == remnawave-subscription-page ]] || bootstrap_apps+=("$extra"); done
                local -a START_APPS=("${bootstrap_apps[@]}")
                compose up -d --no-build --pull never "${START_APPS[@]}"
                wait_ready
                step 'Подключение сайта подписки' initialize_subscription_page
            else compose up -d --no-build --pull never "${START_APPS[@]}"; fi
            ;;
        stop) confirm 'Остановить приложения'; compose stop "${APPS[@]}" "${EXTRAS[@]}";;
        restart) confirm 'Перезапустить приложения'; compose restart "${APPS[@]}" "${EXTRAS[@]}";;
        backup-panel)
            docker inspect "$(compose ps --all --quiet "$(get mainService)")" > "$WORK/container.before.json"
            IMAGE=$(get image); database_environment; backup_current;;
        restore-panel) restore_panel;;
        renew-node-certificate|renew-panel-certificate) renew_certificate;;
        uninstall-panel|uninstall-node) uninstall_component;;
        *) die 'Неизвестное действие обслуживания';;
    esac
}
uninstall_component() {
    local -a ids=() removed=()
    local snapshot="$ROOT/backups/uninstall-$COMPONENT-$(date -u +%Y%m%dT%H%M%SZ)-$$"
    if [[ $COMPONENT == node ]]; then installed_helper || return $?; fi
    docker ps --all --quiet --no-trunc > "$WORK/uninstall-inventory.ids" || die 'Не удалось проверить Docker; удаление не выполнялось'
    mapfile -t ids < "$WORK/uninstall-inventory.ids"
    if ((${#ids[@]})); then docker inspect "${ids[@]}" > "$WORK/uninstall-inventory.json" || die 'Не удалось прочитать контейнеры; повторите удаление'
    else printf '[]' > "$WORK/uninstall-inventory.json"; fi
    python3 - "$WORK/uninstall-inventory.json" "$ROOT/registry/$COMPONENT.json" "$COMPONENT" "$DIRECTORY" "$CONTAINER" "$PROJECT" "$COMPOSE_FILE" "$ROOT" "$WORK" <<'PY'
import json,re,sys
from pathlib import Path
inventory,registry,kind,directory,container,project,compose_file,root,work=sys.argv[1:]
all_containers=json.load(open(inventory));record={};registry_path=Path(registry)
if registry_path.is_symlink():raise SystemExit('Запись установки не должна быть символьной ссылкой')
if registry_path.is_file():
 try:record=json.loads(registry_path.read_text())
 except (ValueError,OSError):record={}
 if not isinstance(record,dict) or record.get('component')!=kind:record={}
def labels(c):return c.get('Config',{}).get('Labels') or {}
def group(c):return labels(c).get('com.docker.compose.project','')
def service(c):return labels(c).get('com.docker.compose.service','')
def image(c):return c.get('Config',{}).get('Image','')
def protected(c):return image(c).split('@')[0].rsplit('/',1)[-1].split(':')[0] in {'caddy','nginx','nginx-proxy','nginx-proxy-manager','traefik','postgres','postgresql','valkey','redis'}
def app(c):
 env=dict(v.split('=',1) for v in c.get('Config',{}).get('Env',[]) if '=' in v)
 return not protected(c) and (service(c)==('remnawave' if kind=='panel' else 'remnanode') or ('remnacust-'+kind) in image(c) or (kind=='panel' and env.get('INSTANCE_TYPE') in {'api','processor','scheduler'}))
def working(c):
 value=labels(c).get('com.docker.compose.project.working_dir','')
 return str(Path(value).resolve()) if value else ''
selector=directory or (str(Path(compose_file).resolve().parent) if compose_file else '')
if selector:selector=str(Path(selector).resolve())
expected='remnacust-'+kind
explicit=[]
if container:
 explicit=[c for c in all_containers if c['Id'].startswith(container) or c.get('Name','').lstrip('/')==container]
 if len(explicit)!=1:raise SystemExit('Контейнер не найден либо идентификатор неоднозначен')
 if not app(explicit[0]) and not (group(explicit[0])==expected or labels(explicit[0]).get('io.remnacust.installer-managed')==kind):raise SystemExit('Указанный контейнер не принадлежит выбранному компоненту')
 project=group(explicit[0]) or ''
 if selector and working(explicit[0])!=selector:raise SystemExit('Указанный каталог не совпадает с контейнером')
elif project:
 explicit=[c for c in all_containers if group(c)==project and (not selector or working(c)==selector)]
elif record.get('project') and (not selector or str(Path(record.get('directory','')).resolve())==selector):
 project=record['project']
 explicit=[c for c in all_containers if group(c)==project]
else:
 candidates=[c for c in all_containers if (not selector or working(c)==selector) and (group(c)==expected or labels(c).get('io.remnacust.installer-managed')==kind or (app(c) and 'remnacust-'+kind in image(c)))]
 projects={group(c) for c in candidates if group(c)}
 if len(projects)>1:raise SystemExit('Найдено несколько установок: укажите --container или --directory')
 project=next(iter(projects),'')
 explicit=candidates
if project:
 peers=[c for c in all_containers if group(c)==project]
 anchors=[c for c in explicit if app(c)]
 same_record=record.get('project')==project
 owned=record.get('ownedServices') if same_record else None
 if owned is not None and (not isinstance(owned,list) or any(not isinstance(v,str) or not v or v.startswith('-') for v in owned)):raise SystemExit('Неверный список собственных сервисов в записи установки')
 if owned is not None:
  selected=[c for c in peers if service(c) in owned or (kind=='node' and service(c)=='node-nginx' and service(c) in record.get('extraServices',[]) and labels(c).get('io.remnacust.installer-managed')=='node')]
 elif project==expected:selected=peers
 else:
  app_images={image(c) for c in anchors}
  selected=[c for c in peers if labels(c).get('io.remnacust.installer-managed')==kind or (app(c) and (image(c) in app_images or service(c) in record.get('applications',[])))]
else:selected=explicit
if not selected and not record and not selector:raise SystemExit('Не найдены контейнеры компонента; укажите --container или --directory')
if any(not re.fullmatch(r'[a-f0-9]{64}',c.get('Id','')) for c in selected):raise SystemExit('Некорректный идентификатор контейнера')
anchor=next((c for c in selected if app(c)),selected[0] if selected else {})
path=selector or (record.get('directory') if record.get('project')==project else '') or working(anchor) or str(Path(root)/kind)
path=str(Path(path).resolve())
if path in {'/','/opt','/usr','/etc','/root'}:raise SystemExit('Небезопасный каталог установки')
files=record.get('composeFiles',[]) if record.get('project')==project else []
if not files:
 files=[str((Path(path)/f).resolve()) for f in labels(anchor).get('com.docker.compose.project.config_files','').split(',') if f]
if compose_file:files=[str(Path(compose_file).resolve())]
state=record.copy() if record.get('project')==project else {}
proxies=[service(c) for c in selected if image(c).split('@')[0].rsplit('/',1)[-1].split(':')[0] in {'caddy','nginx'} and service(c)]
state.update({'schema':1,'component':kind,'directory':path,'project':project or expected,'composeFiles':files,'mainService':state.get('mainService') or service(anchor),'applications':state.get('applications') or list(dict.fromkeys(service(c) for c in selected if app(c) and service(c))),'extraServices':state.get('extraServices',proxies),'image':state.get('image') or image(anchor),'uninstalled':True,'recoverable':False,'reinstallOnly':True})
if 'runningApplications' not in state:state['runningApplications']=list(dict.fromkeys(service(c) for c in selected if c.get('State',{}).get('Running') and service(c) and (app(c) or service(c) in proxies)))
if not state.get('ownedServices'):state['ownedServices']=list(dict.fromkeys(service(c) for c in selected if service(c)))
p=Path(work)
(p/'uninstall-containers.json').write_text(json.dumps(selected,indent=2)+'\n')
(p/'uninstall-state.json').write_text(json.dumps(state,indent=2)+'\n')
(p/'uninstall-targets.ids').write_text(''.join(c['Id']+'\n' for c in selected))
PY
    mapfile -t removed < "$WORK/uninstall-targets.ids"
    info "Будут удалены контейнеры $COMPONENT (${#removed[@]}):"
    python3 - "$WORK/uninstall-containers.json" <<'PY'
import json,sys
for c in json.load(open(sys.argv[1])):print('    '+c.get('Name',c['Id']).lstrip('/'))
PY
    confirm "Удалить контейнеры $COMPONENT. Томы, БД, файлы и сертификаты сохраняются"
    install -d -m 0700 "$snapshot"
    install -m 0600 "$WORK/uninstall-containers.json" "$snapshot/containers.json"
    install -m 0600 "$WORK/uninstall-state.json" "$snapshot/state.json"
    [[ ! -f $ROOT/registry/$COMPONENT.json ]] || install -m 0600 "$ROOT/registry/$COMPONENT.json" "$snapshot/registry.before.json"
    if ((${#removed[@]})); then step 'Удаление найденных контейнеров' remove_container_ids "${removed[@]}"; fi
    python3 - "$WORK/uninstall-state.json" "$snapshot" "$ROOT/registry/$COMPONENT.json" <<'PY'
import json,os,sys
from pathlib import Path
p=Path(sys.argv[1]);s=json.loads(p.read_text());s['uninstallSnapshot']=sys.argv[2]
directory=Path(s['directory'])
if directory.is_dir() and not directory.is_symlink():(directory/'.remnacust-uninstalled').touch(mode=0o600)
target=Path(sys.argv[3]);pending=target.with_suffix('.json.pending')
pending.write_text(json.dumps(s,indent=2)+'\n');pending.chmod(0o600);os.replace(pending,target)
print('Данные и прежний каталог: '+s['directory'])
print('Повторная установка: remnacust install-'+s['component'])
PY
    if [[ $COMPONENT == node ]]; then
        local renewal_project
        node_firewall_cleanup "$WORK/uninstall-state.json" || return $?
        renewal_project=$(python3 -c 'import json,re,sys;p=json.load(open(sys.argv[1]))["project"];assert re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,62}",p);print(p)' "$WORK/uninstall-state.json") || return $?
        if [[ -f /etc/systemd/system/remnacust-acme-$renewal_project.timer && ! -L /etc/systemd/system/remnacust-acme-$renewal_project.timer ]]; then
            systemctl disable --now "remnacust-acme-$renewal_project.timer" || return $?
        fi
    fi
    info "$COMPONENT удалён. Копия описаний контейнеров: $snapshot"
}
remove_container_ids() {
    # IDs are immutable; never remove by a name that another process can reuse.
    docker stop --time 30 "$@" || true
    docker rm --force "$@" || true
    docker ps --all --quiet --no-trunc > "$WORK/uninstall-after.ids" || return 1
    python3 - "$WORK/uninstall-after.ids" "$@" <<'PY'
import sys
remaining=set(open(sys.argv[1]).read().splitlines()).intersection(sys.argv[2:])
if remaining:raise SystemExit('Docker не удалил все выбранные контейнеры; данные и запись установки сохранены')
PY
}
restore_panel() {
    [[ -n $BACKUP && -d $BACKUP && ! -L $BACKUP ]] || die 'Укажите --backup с каталогом копии'
    local requested; requested=$(realpath "$BACKUP")
    helper verify-backup --directory "$requested"
    docker inspect "$(compose ps --all --quiet "$(get mainService)")" > "$WORK/container.before.json"
    IMAGE=$(python3 - "$WORK/container.before.json" <<'PY'
import json,re,sys
image=json.load(open(sys.argv[1]))[0]['Image']
if not re.fullmatch(r'sha256:[a-f0-9]{64}',image):raise SystemExit('Не определён установленный образ панели')
print(image)
PY
    )
    helper_file_copy "$STATE" "$WORK/restore-current-state.json"
    compose --profile '*' config --no-interpolate --no-env-resolution --format json > "$WORK/restore-current-compose.json"
    compose --profile '*' config --no-env-resolution --format json > "$WORK/restore-environment-paths.json"
    compose --profile '*' config --format json > "$WORK/restore-current-effective.json"
    helper plan-panel-data-restore --source "$WORK/restore-current-compose.json" --state "$WORK/restore-current-state.json" \
        --roles "$WORK/restore-current-effective.json" --environment-source "$WORK/restore-environment-paths.json" \
        --current-inspect "$WORK/container.before.json" --directory "$requested" --image "$IMAGE" \
        --plan "$WORK/panel-restore-plan.json" --target "$WORK/panel-restore-compose.json"
    docker compose --project-name "$PROJECT" --project-directory "$DEPLOY" -f "$WORK/panel-restore-compose.json" --profile '*' config --quiet
    confirm "Восстановить данные и ключи из $requested; установленная версия и подключения сохранятся"
    database_environment; check_writers
    backup_current; info "Копия текущей БД перед восстановлением: $BACKUP"
    compose stop "${APPS[@]}"
    # Do not start an old panel against a partially restored database on failure.
    CHANGED=true; DB_CHANGED=true; trap recover ERR
    helper validate-panel-data-restore --source "$WORK/panel-restore-plan.json"
    python3 - "$WORK/panel-restore-plan.json" "$WORK/database.env" <<'PY'
import json,pathlib,sys
values=json.load(open(sys.argv[1]))['database']
if set(values)!={'DATABASE_URL','APP_SECRET'} or any('\n' in v or '\r' in v for v in values.values()):raise SystemExit('Некорректные данные восстановления')
pathlib.Path(sys.argv[2]).write_text(''.join(k+'='+v+'\n' for k,v in values.items()))
PY
    RESTORE_DUMP="$requested/database.dump"
    step 'Восстановление схемы и данных одной транзакцией' restore_dump
    # Persist the restored signing identity even if a later migration fails.
    # Creating the API container stopped makes the next backup/restore inspect
    # the correct key without publishing an API or starting dependent services.
    helper commit-panel-data-restore --source "$WORK/panel-restore-plan.json" --state "$WORK/panel-restored-state.json"
    STATE="$WORK/panel-restored-state.json"; load_state
    helper_file_copy "$STATE" "$ROOT/registry/panel.json"
    compose up --no-start --no-deps --no-build --pull never "$(get mainService)"
    refresh_restored_update_identity
    step 'Совместимость восстановленной базы' docker run --rm --network "$(cat "$WORK/database.network")" --env-file "$WORK/database.env" --entrypoint node "$IMAGE" dist/database-compatibility.js --apply
    step 'Защита резервов после восстановления' quarantine_restored_quotas
    refresh_restored_subscription_page
    load_restore_apps
    if ((${#START_APPS[@]})); then
        compose up -d --no-deps --no-build --pull never "${START_APPS[@]}"
        step 'Проверка восстановленной панели' wait_ready
    else
        info 'База восстановлена; приложения остаются остановленными'
    fi
    BACKUP=$requested
    if [[ -f $BACKUP/fingerprints.json ]]; then step 'Проверка данных восстановленной панели' verify_database; fi
    helper_file_copy "$STATE" "$ROOT/registry/panel.json"; CHANGED=false; trap - ERR
    info 'Копия восстановлена'
}


refresh_restored_update_identity() {
    [[ -e $ROOT/update-agent.json || -L $ROOT/update-agent.json ]] || return 0
    local script="${HELPER%/*}/update-agent.py"
    [[ -f $script ]] || die 'Не найден помощник обновления панели'
    docker inspect "$(compose ps --all --quiet "$(get mainService)")" > "$WORK/container.restored.json"
    python3 "$script" --root "$ROOT" restore-identity --inspect "$WORK/container.restored.json"
}

refresh_restored_subscription_page() {
    local count script token_uuid
    count=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1])).get("subscriptionServices",[])))' "$WORK/panel-restore-plan.json")
    [[ $count != 0 ]] || return 0
    script="${HELPER%/*}/subscription.cjs"
    [[ -f $script ]] || die 'Не найден помощник настройки сайта подписки'
    token_uuid=$(get subscriptionTokenUuid)
    # Credential stdout must never enter the operation log. Provisioning honors
    # token expiry/scope revocations and does not start the page or API.
    docker run --rm -i --network "$(cat "$WORK/database.network")" --env-file "$WORK/database.env" \
        --env "REMNACUST_SUBSCRIPTION_TOKEN_UUID=$token_uuid" --entrypoint node "$IMAGE" - \
        < "$script" > "$WORK/subscription-token.txt"
    chmod 600 "$WORK/subscription-token.txt"
    helper restore-panel-subscription-token --plan "$WORK/panel-restore-plan.json" --source "$WORK/subscription-token.txt"
    rm -f -- "$WORK/subscription-token.txt"
}

quarantine_restored_quotas() {
    # Called with all panel writers stopped, after migration and before start.
    # Existing node reserves keep working; restored SQL cannot mint fresh credit.
    docker run --rm -i --network "$(cat "$WORK/database.network")" --env-file "$WORK/database.env" --entrypoint node "$IMAGE" - <<'JS'
const {spawnSync}=require('node:child_process');const u=new URL(process.env.DATABASE_URL);
const env={...process.env,PGHOST:u.hostname,PGPORT:u.port||'5432',PGUSER:decodeURIComponent(u.username),PGPASSWORD:decodeURIComponent(u.password),PGDATABASE:decodeURIComponent(u.pathname.slice(1))};
if(u.searchParams.has('sslmode'))env.PGSSLMODE=u.searchParams.get('sslmode');
const sql="DO $$ BEGIN IF to_regprocedure('public.xera_quarantine_restored_quotas()') IS NOT NULL THEN PERFORM public.xera_quarantine_restored_quotas(); END IF; END $$";
const result=spawnSync('psql',['--quiet','--set','ON_ERROR_STOP=on','-c',sql],{env,stdio:'inherit'});process.exit(result.status??1);
JS
}
restore_dump() {
    docker run --rm -i --network "$(cat "$WORK/database.network")" --env-file "$WORK/database.env" \
        --mount "type=bind,src=$RESTORE_DUMP,dst=/tmp/database.dump,readonly" --entrypoint node "$IMAGE" - <<'JS'
const {spawnSync,spawn}=require('node:child_process'),fs=require('node:fs');const u=new URL(process.env.DATABASE_URL);
const env={...process.env,PGHOST:u.hostname,PGPORT:u.port||'5432',PGUSER:decodeURIComponent(u.username),PGPASSWORD:decodeURIComponent(u.password),PGDATABASE:decodeURIComponent(u.pathname.slice(1))};
if(u.searchParams.has('sslmode'))env.PGSSLMODE=u.searchParams.get('sslmode');
const schemas=spawnSync('psql',['-At','-c',"SELECT count(*) FROM pg_namespace WHERE nspname !~ '^pg_' AND nspname NOT IN ('public','information_schema')"],{env,encoding:'utf8'});
if(schemas.status!==0||schemas.stdout.trim()!=='0'){console.error('Automatic restore requires a dedicated database with only the public user schema');process.exit(1)}
const sql='/tmp/restore.sql';const generated=spawnSync('pg_restore',['--file',sql,'/tmp/database.dump'],{env,stdio:'inherit'});
if(generated.status!==0)process.exit(generated.status??1);
const fd=fs.openSync(sql,'r'),head=Buffer.alloc(65536),count=fs.readSync(fd,head,0,head.length,0);fs.closeSync(fd);const prefix=head.subarray(0,count).toString('utf8');
const create=/^CREATE SCHEMA (?:public|"public");$/m.test(prefix)?'':'CREATE SCHEMA public;\n';
const child=spawn('psql',['--quiet','--set','ON_ERROR_STOP=on'],{env,stdio:['pipe','inherit','inherit']});
child.on('error',()=>process.exit(1));child.stdin.on('error',()=>{});
child.stdin.write('BEGIN;\nDROP SCHEMA public CASCADE;\n'+create);
const input=fs.createReadStream(sql);input.on('error',()=>{child.stdin.destroy();process.exitCode=1});
input.pipe(child.stdin,{end:false});input.on('end',()=>child.stdin.end('\nCOMMIT;\n'));
child.on('close',code=>process.exit(code??1));
JS
}

renew_certificate() {
    local domain certificate key
    local -a subscription_options=(); local subscriptions
    subscriptions=$(managed_subscription_options)
    [[ -z $subscriptions ]] || subscription_options=(--subscription-urls "$subscriptions")
    local -a tls_paths=()
    domain=$(get nodeDomain); [[ $COMPONENT != panel ]] || domain=$(get panelDomain)
    [[ -n $domain ]] || die 'У этой установки нет управляемого сертификата'
    if [[ -n ${RENEWED_LINEAGE:-} ]]; then
        [[ $(python3 - "$STATE" <<'PY'
import json,sys
print(json.load(open(sys.argv[1])).get('uninstalled',False))
PY
        ) != True ]] || return 0
    fi
    if ! tls_helper paths --state "$STATE" > "$WORK/tls-paths"; then
        # Compatibility with node certificates installed before TLS metadata was introduced.
        [[ $COMPONENT == node ]] || die 'Caddy панели сам продлевает автоматический сертификат'
        certificate="/etc/letsencrypt/live/$domain/fullchain.pem"; key="/etc/letsencrypt/live/$domain/privkey.pem"
    else
        mapfile -t tls_paths < "$WORK/tls-paths"; certificate=${tls_paths[0]}; key=${tls_paths[1]}
    fi
    if [[ -n ${RENEWED_LINEAGE:-} && $(realpath -m "$RENEWED_LINEAGE") != $(realpath -m "$(dirname "$certificate")") ]]; then return 0; fi
    tls_helper copy --domain "$domain" --certificate "$certificate" --key "$key" --directory "$DEPLOY" "${subscription_options[@]}"
    if [[ $COMPONENT == panel ]]; then
        compose exec -T caddy caddy reload --force --config /etc/caddy/Caddyfile --adapter caddyfile
        info 'Сертификат обновлён; Caddy перечитал конфигурацию'
    else compose restart "${EXTRAS[@]}" "${APPS[@]}"; info 'Сертификат обновлён; Nginx и нода перезапущены'; fi
}
migrate_marzban() {
    prepare_host; lock_operation; release_source
    [[ -n $MARZBAN_URL ]] || MARZBAN_URL=$(ask_required 'URL Marzban (https://...)')
    [[ -n $DESTINATION_URL ]] || DESTINATION_URL=$(ask_required 'URL установленной Remnacust (https://...)')
    [[ -n $INTERNAL_SQUAD ]] || INTERNAL_SQUAD=$(ask_required 'UUID внутреннего сквада в Remnacust')
    local output; output="$ROOT/backups/marzban-$(date -u +%Y%m%dT%H%M%SZ)-$$"
    local -a args=(--source-url "$MARZBAN_URL" --destination-url "$DESTINATION_URL" --internal-squad "$INTERNAL_SQUAD" --quota-mode "$QUOTA_MODE" --output "$output")
    $YES && args+=(--yes); $DRY_RUN && args+=(--dry-run); $PRESERVE_SUBHASH && args+=(--preserve-subhash)
    python3 "$HELPER_ROOT/marzban.py" "${args[@]}"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi

# REMNACUST_HELPERS_V1
# DATA H4sIAAAAAAAC/+y9a3MjyXUgqs/1K2oohQHMgGi8QbJFjTls9gwtNtkm2TMac2huoapAlhpAwVUA2VSbEba1e++N8Mb1L9j7iPsH
# DATA ZK91rfVa0l/o/kd7XvkqFEj2yBrHrtW2hgAqK/PkyZPnnScP9nf3Dk/2vvf7/NeEf/1ul/7CP/dvq9lutfvqN/m9P+h1v+c3v/cd
# DATA /Fvk8yCDIb/37/Pf54ev/J3nz/eOj/zP9w73jncO/JevPjvY3/UPmDK8L+MsT9Kp36n7m/6fBNNFkN367Wa753m76ew2Sy6v5n51
# DATA t0a/+cfxZBrcBNex/8Or+XyWbz15cpnMrxbDRphOnmTq6Y+8ves4u02nsZ/k/izOJsl8Hkf+PPVD6NQPppEfJfk8S4aLeexD22Ew
# DATA Tyb4MIlzLx358yt4cZyE8TSP/SgNF5N4Oq/70NwPr4LpZTK99JM59j5N534wHqc3cdTwPF/+vcziYDIcx553ehX7hIbRKM5S//N4
# DATA GmfB2H+5GEL3/oEMAR0F/iiL4zpBOI5Hcz38KM28PB3Nb4IsJtDT+VWc+a+TaZT7AOtNmr3O634+i8NklIQAzK0fxXlyOeUpQyeL
# DATA LPbCNAVMwDwB2zeANJhjDINNJotpMr/1kyn/EMCI0Ok0nmO/fh5ngB5fjd/gCQloOcLmT9J87pcAOMuCcI7wMIQ+PlVweQDXPHgN
# DATA zW+CW/82XWQ0+yidIMT5leqJkB0TZNRJw/c/uwWop/MsyOd1D18sRymPl0zn8TRiPFwCbQXwPS6O5y2NBzhEqkDKJBQHMJn0Mgsm
# DATA 6+vQ0QQBR5wiCQDRBQm0wu7MMiFesJNknvsLwGEOiPvqKgbMx7hQwWvsFV/RiKvjI3w1i4FQMiQwGEqArCOZebMMpgYYOHpg0vbi
# DATA G1jnV8EcZ+5d4f5BjFoYt3YDb4Il+Pyq4Ce7ZJKEHiZ+MsIugZ7yq1pdDwFzCOPkGl9eZCF2GQFRZUBcU/8yntPOoRe9G1gQ+Gq9
# DATA im2sVdfDw+uASB9gCxk67GQKdHrjEZyyQLAREE7d3etpeqP7jVLsM8eeAb+4Js/i63iM+yLnV3CI+2gKRpnH4ZwpiJhT7vFmugGy
# DATA ncfAkvxqq+YHOSz6nPYys7B06kyHoay2azATWG4PISSeoxjCzVUSXvmXgMScwB/HlwAOsbKcGKbwsrq1dB70+YQ2ZJSMbp3xYKo7
# DATA sJdh40TIYIcwvREgENAYAblNIyQ3pFei1YqmjITR4iUTmPh1jEwwB5KKcGNB+3mcTQNmoHqr4KiyFnVcZfh+6yl6uEmANmfAGyMc
# DATA CfgpQDQBsr8OknEA7JL2DXOPyFqZ1EumYZrNUmBfuAFeBNNbu8ESreL/ruIgg80P2wDQ4sXQwSILLuHrkFGTxfliPMeJW5wROv8C
# DATA WDlMqF7giGZvA+QRrqfLIvM6LyB3C0i69UcwK14nnOMwXcwbWhyskAMsqxDHr2lJeC0TGFBwTJMZx3MCnHDNHQQhbIscNwW2UWwb
# DATA SROG9XFCANk4DnKWXLlnb815anXV+ACZpTmNI3xgvVjmEPEQIvMFUDNiktAUm2nZYDA15IYcPAFMSylYnn1kuX+xSADP9IyXDskG
# DATA 2XRBbAEkSLhJpJiJxY5GLiAKv9liOhXcZgozHm0LfgWYBHcOsJxiGyBZoGRZhgVLz+V1q8O6eIE0AxzxeiVI89xdXTb78poKEhh4
# DATA 7z7gcZdP/XQcwdRFRIM+AWuCsgDa37+eSFk0cn7Fu4Sbg2AKckemAFzpZIbt/DyZwFJl/mUajHPCCFBFksNMATJ4GxiGgYRUJY1o
# DATA mYOC6eUBq1fy/SrIPSZY3MDI5le/KMxS7R14jUbEVVyA8EdRZbQ5IW9gQmGCkgBeyln0A29M5sTGkAshc4UeLP6qdh9jPWRNapSi
# DATA 7oed7h2/OPF3Dp/5u0eHz/ZP948OTzyv2fCfAaedcsfQbO3U4vJrLOxpidXsOmp+D25A7E3ryGvAjnMQ93EA8Guxsz5OQPyPgxsR
# DATA b8FsRvuzoEJ6SoXEXQqLnceTBNGxCHFjTYL8tYAeg2JLrN2GHJmxHpG4OG1BwXfEa0DM0VOQ+/5eAENJE1Z/owi2NK127q+ByFuD
# DATA VmvyQpyvEerXcNVABQAxtEYsdoiSKEpghy9g/qgkpNllME1+FiiEn6b+GgtE6IIhYyQpY2CUgaBDdS0KZqTK45cZyA61EPiOh/IO
# DATA GHp+RTyCGBCLDiXgjWiuC3YB4yxBhJkjX5h68RvQiuk9ZiCWHCLgABWyYwMB3NrgawKTB7JtnCCDx1cQeP60NgxYOK3RwHYr0gDW
# DATA QpDiGbTAX9YEEXEi4IJom+oRZaGtzqlvTxQZeSwIBiY7Cy5BOC/jOCICIYWLzQ4QUSwWRDh5NuZu0sU4YqUVtZ4I2Hw4B5IFKJT2
# DATA ksDXcaK0BViYEa4E6SZCakjlsD+xhVkf2AR1P34TxrDI8Zs4XMzFhsNd7SFDAw0KyUfUJxa/oHJfB6wU43q9lHkiEYBKMl4AW9Sc
# DATA wnM4RZUmmxoZbLMN0JWVhNeqj4ga5v2sH6LgRN0BVBcweEgrp6VCu+oaWArKyhzshvFY1gEwdB0XCR33J+50pJ2ZNQHiCPEUB5eO
# DATA PSR77FUZDmmmVXk2C1D5isWuIvNOGZMBqY7QZ5YuLq+A/2uMikjm9QYZ4IPpNs1HsUhsVmLFkGb4AS8syfQo1zF3Tz+MApDhgOvZ
# DATA OLgFVrEzw0llCS7TAWnJhymYncAylPoQv5kjcdB8yWqQhQt4vCnyE8I3dDRJpvANSOw6IensjeJgrs0nVO31yLC7A2tsQ2pTGl+r
# DATA +N4cFogFu+AomIt6QdMG+ZqhYXpLckdxHL8qxCp0YU9CXkjE3hMVJ1IWmGKrObFIxin1Qf0adqwECUN6BYYSyqEERC0vi68cIYZt
# DATA 74/Q7rPWAeRoTlZBAMPmxDNpkqiyBSRdYJ1nxIyNfAk82K2LOpvVjHFYGDQnmblQT5M4nuc8fpjB04wVnFbDP2E1bhc0IZHma5Zm
# DATA t8bGt8OGWOCjXQ2cDR5PHN5OTgzejvYmpW2QzFEMHQ1/GhPXxu7Nrpqm03VRy1SngcVsT+YBMqzI31foMi9bKOR9yEw4oWdgEyZh
# DATA Eoy9XPUQoRLBWlmAWzK9BBmH6rM0yP1hGsE+SpftFj1QrrR0xgFiH7d7uEAFTky2CSJhDNb3Akwl1FljMQBzst1gX5D1E0xSaGdZ
# DATA YDhp4qfCVlQXan1ObnNc34NkmAXIyNZYGgonNkqD7E0tMkSWelqWUiskIVD60nEsFF8Naog6eTtSKJjCogA/kLUB7ha+Di6Zsb8I
# DATA fgoo2AUmlU61a4/1SOFFRgWAAai5ZzWnvT2ssfIOVD5lvYrZqTIDNMDibwNELo2LWx7IDPRpFmGBv0w2tFwMHGgQuq3IoXxJiCgD
# DATA guSHMXkQD0DNO95aAYo1IRrcaikM+gbgEkKFjYFNUTMDhgPIDNVLXvU1mP/xGBn7NALmkdMaM2pAFQUpp3CgrEMx1nAFuLFXTZAM
# DATA bmsohXmCzLBdqgCbLK+zJoLDJ+M4Yzpk+w70VOMi5Hawh8yW5b0GDGBu3sM+cXMLfe6mwBryWcqeEGYwDiNJ3B6JpARF47FXNC6n
# DATA caycjqS6z2PEMGzW8VhIZ8RQmpkSc64RWGTWWoORQyu13To8USZ3wiZwyNmcPCXkG03H0CxFm05rCo5nYw5qWcxkrnac6raSe8XN
# DATA SijliYzXZ4tshj3P05QVbnmANq1x46AzVHnkFOUq14mlZAJWgSIQmWxyuyDjnvTMy+6mZGhhVs+RPN8EuCnqftk6elrgW+qDNsr8
# DATA UTImPSpPQ5TjEW9WWU1+KO5OQTv7F+Pi1mKvdQTCS9DGYYbbaTBhv4g3TqavkWcvhho1ShfQuv9KL744PeqeEqJD9NnPkwnqHlEw
# DATA D5SXRAxTMmGZFEZgoYKlNL+J4ykj2bNhsDz2gN3cQS9vjzKsEo07FKTVfOVJzXIPva5ZrDaBHyzmKQAs02PLa3lkZziPh7sPEneb
# DATA FjmedmLmwUTPqt3wPwty4EgvtfGBxuIOWH/s1fUvKVYQlahLRIzqsVLZ0I+AMmbJ4/tS+UIRzRSSgBlcp2yeKM2N6WmO5OdZfghs
# DATA Ponnyq+ixo/foH2ToJYagKaADgzyRy+m42SSYB+un1jxlGXrTkxQME9AV+f1UP4vtImMrUhmqXwn/6kFDsk+9vRKT+zLmpKfkQQK
# DATA Cjr4kM+TOdgErHmbzovzAzE9TW/ABL5k53fmyZqgnzdIOBCgHcW4L66DMUvl3KB0eOtaf7C8X4NJiSox2jZ1Qoto/Wy8OkDlJoYA
# DATA JiyGX1iR1nar7TACcTdGjSiQlVChO4LwBv1MEiZCPwKQDIVxFDSioBcGFx9NriksT5FgmPtiiPIquBY/5YSNNVd3BethvMhhGcZs
# DATA VwBcxMeVP5SiL8jpgB8mY+a32M74P5EZi2PIolMVpkEP4C3hwlP0nxcNBtyO2qQj1wpyqyxhnUzkAmPYE/OPGJZeN6IMkjZXC+0U
# DATA d4AsLJonU/UnixyFHK6MjQnYELRAw/gqGI/qsrvpJ/Y1JOimZW8gglKnbUxzo6kDIq6SIbkwAO20YZQhz14wDp151KOeRhyZiQPl
# DATA 5OKPTsgnz+t1lcxY8MCbDYx9K6yJSwN6Z3IPkyxcTFDvR43eCW8jhaCGLj7P2KFQYi4wb/RW+v4JKYjiJHWj2E/R00IipNX0kLAo
# DATA qgAIx8BbHmS3AF6ngRwEI2H4/isOGrHxfcxb9TmiZgfk0/ouAXyN6iP0eUAb8TB1lg1FJxDHEOUyaLaRFvOoIY1GMXsAYLiraTpO
# DATA L1F8gAUZUIjB4Mdy+8B290eLMUjvMVEMTPZS9oW0R8MHlK5WSwmdr/ZfHlkMY56B3Q99RmC8crin3fSfAQomQ3i9tbnZx93kKf83
# DATA uVgVcSgijdEdxCgKHSTAkCjF1Rx0cJg3FnEDl0PWOcoaIBpwqhINhOUi6wGIfpiA5CgO4mDMV6P5rluEQzP2q2jtMdqZjYKSmoUJ
# DATA kYow4hKhSMSLshnVVtBDi1uTBSA79fJwHCQTmgkF6OciqEh8+SZNARDsONttk4psQNbA4ed4ilyVDEZg5ahq2wot6SJ13ubETZOM
# DATA aQx2a0WQKTPT2FxaMq8cm7B23YZv9uuXKplklx1mRurIyhayTdSkRCJXckeBYYGi46cJR9MQcbBNksWknDVP8xmY9ekiH1Oui2e5
# DATA qeAXifEgTcfohZeUmHudWU+913E8w9VC7zVuVv6dGYtW+lw1CRWe6a2HXhKlkFzriEskdjoGkzKldAvjGZhABZNRdA8Agr9gCBZq
# DATA yNE3QI/yqT0lMC5p44ChZuIHK3xc0CpVnmrXz62XkVMgcBBKyECKmqbyGcWPQaq9JKg6eGoLYD8U+IfdN5ulyOwy4waUJAMOL6Fq
# DATA O4pR/+3ZZPZCaXKiA0seVQm92d77JaVUdIui20tb1Ylohc5L4l1RLi+bXhVjiD2tEKhF7ZbRqgStYgm8jCQ/wwiuLc8LaqSksj8P
# DATA xXoIiLq1XIelpEhoFiR5iXhsgA7Y/YOhxWvMPYkwo8Dzht9qDMoAM2HKMlOB94AtiZnyua3gxhsoFVisPPIECfS5ZCuYB2jkKKTi
# DATA Yq2t2BprMLGwxnomzklppcT8ga1l2qK1/GnL0TqJ8aEvENr4HKOH0YDm0zyPcxWUDUxUy3r5BmQwe7sxUM4bu27vsoLo1jzAA0QR
# DATA yoDZEjHVFT8gSG1hIMaV5FuRLVmHZbkMsmiMEXTUltG7fYXbAR3m5AiMo6LhwRH4aVqwn2y8KSvTKGQ3wS17Dy2vCqj5YJIkSFws
# DATA X60OJWWKsrDyGIBlriwsPmKnVFTz9y1hdxXk9wRDADPEc1jn5fCEtzIs8hRxIX4gR/QUR7E9x0TubAepEfyVI7Ck5WiD9hKQiUJa
# DATA M2nl5CFnZ56W7a7Ow9TBOFZ4kqhYFM8wq286V4Fr10nECT6gXU85dEOKjpOg5CgmxJXdHgCwIfnbVcRSOV1YPZhgtAOlgPab19Gw
# DATA Q5MUw8TX6XgxkTyQfJ5i1hE+c8KDSnxb4d6ptxZcXiLZYhw1UZAaFNHk57mTuaTEtEDuKfcmq1IkGDmLBABwFJ10qf+KpCp6wxg2
# DATA O6JEfFMmwi7GKZscGA6akmlVtnwUMYf/VzMyHscwWHAKntl4yGFsiW+ikUa+q46Acvq2JDwE9UKE4HNYmlIJ6LoySly5Wm4xq/GM
# DATA 3MqBxyLieyvFlxVgm8A2BLpZxww34mal/qrCYEUVhGlpGhtxCCxGBOGuHqvg4CZRDsYJyAzSqyi4dnWbk67K0nzuVY3H2HpaQpe1
# DATA uiT5BNNEZ8x55c635A3rFYEfLTL2aqmeuTMvBL6UTjhyT/RJ3lKVTkdchjM+WRD/m80x8G4ytKSnrJvVfeLhrIOB9AQhj/sBEw1v
# DATA 4yBjx6nVJPcsH5BS72Ysb4iQwXgnTFhqHzt32LFA4IPQx5AKRg7E2FNyV4StSnuzMCOxQ8o79YxSe5+3lGWyvQicfMBQiHaz0uVX
# DATA L19vjxHrP3q96yoOSbozyN1JypF28dLANsrTqSRycHBZjYV2jB05SHLPeJq0UkoUg1m2JpVOFPNV1IzK7lIaYYD6nyj+rFMJjVqc
# DATA 0bXm7OWR/AhrYVw6Q6jsLMUywJRWpXJuyRjMlcuGXbBpGAY56Uts9mF4GmMCaLzjb6Qlecpba6VpR+Ugs8zTm0Hbap48HSpVrT9k
# DATA jWXFxh2KrUNbktdB0MzxDfJ6g0YB6K9eouVPW4Upg3FeYwWPsWX8vW6CZPmCiq3Cvv/gViWomB95YFphb7TI2MfGK80uWq3BiAru
# DATA Wzbkg/RUsCYttFAyBQdrCQIK3c1K2F6+RI/1lWTiSU4cb0+dgSlkXGXPCu9n4lGIYuMNua15nN/KzCm3US1JTpa32JKHbNKiAZJM
# DATA vRAYpeVNBZkP+pcW7NbM8oB6vFGJtqOEA2veig1w7Cj0NyYTFxTanFJFyl+tC60jhMoVaJ+MsW05NxMdWLli6SaimyOFchw2d+wy
# DATA 1DzilbtgQf6zWRxn6/N0Hf9yIpROfVPYpLMAyZStaw6OxZRiwXgqiQ2XxctcX1mGydXMGUfE0GU5JHarE45pF4iDQyxUa5tHcooA
# DATA dXHi+0AkllvOAgs1cnTb266BRGISOEXtUyjfNEjyThAaeJfehkMd0I3c+MISE9OJOOigRisHZdsaAWJJTMqayxcTVuapiTIodKaP
# DATA N8czXzRnWAoySdH2iWHP2EkjmG1iyzzVGORcMAFpWPdSJFZ4DhZspII5uZFSKoKqA78kOMfcmzkDQT5aNMBhk2P2HybMoTIO76FG
# DATA mUxlX3GyoJoWs5LiZOtelC6G89FizPn5xhcPC5OOrxnLo+CaU+xJIwiIOT4v5BBp7UGLFcpWspKM0Lyo+2sOopxMYm9+OyN9LeUM
# DATA MiAunUoDxBmOA978CnbfNfJVFHUhZ/ji4uA+T4I2RkBn3kzSSaGpB0bwQkHJSxS/Qec2SSci5hl7yAFwOswiJ18QMMyy0SpdKdoL
# DATA kKvFsvogcxy33zygzBvPyHIUxtECNVpGFXpY9QAM7mJKXZMMx19gPEnVI888aQFIY+T2Y2dTLMl71ikemovnre1z7gqbofvEm+iz
# DATA SpGxN5iVHzeBSaVRXkfKCOMI3eV1zAG4SjPJ0PZfx7eMXGZ1ielbsVZCsCTPkKnOOTPLpx/yEh+CykdzAETu45UcraFDZflq/St2
# DATA wENvi5cvMFUvLgoTCb6Bjb5AVrCYEgcV1dQ5ucEMy1McEk+0pZy6B8uFwQdmAuyK4XlxegqF+oYxGdNulATpZoipHnhQC1Zvf+QE
# DATA lqZLTNJ2XCpmL9YWDsaBLjsvZSSH8dgEs3FrsmMsbTwMF2gt5Z4O67HoC9RQ1i6U3ImR7VvELg1des5aYnKH5BNbck2raJJhNIvn
# DATA CzzkqvRKj61WStqoljoKXQhzUgnhG2ixP5NE2xUaH8/b9QYrpJKDbhjbdqcnp9FW7TA88LqYq6NlxgesvSnkN/ESPLHLQg3Xeppy
# DATA SNTS7eDtOR1U5WAJKnG39s4qUKQckmLt2cE4pa7phCvbRekR1UmHLDeOj17UJHXHht6yeFZNfDlDLfAKXagdZnenDGvUDCkJW0VV
# DATA iJwXM3TJcpaAxEVov5oto7GQWRPRJwaFqupCSN4ScjQtJw91iiJCmy+BpzR8UeCjmJwSN1fxdClAg0wqHo90SoEK8kXIx2JOCiI5
# DATA ZY7HWVqaGghguU7SMaKDJ7cYc8oaMut5GmJ230jEsMkqC8IszXO7I0pWuGcfMEdYucpK6yWnlx0LLN04fAqHXtY+CnWkzlPH9AFv
# DATA dFZZogt+IV92dbKsV0wdE7uTRlfWH7Bn4oWoAoI2coMAA5pAjhFFLKYYXKBANDoBJRVArCfA1aDh75i4xmnMDss16zcTKsBDT1ls
# DATA p58gdUue8JL7UEdchrcqJ4VPEPCRNsq1m8Z8wCWLlbAzgamGVw6EnByT2I1EaVQKAUeRVACBVEfgApw9wUe5MFeK7W1QlfnoiJ2k
# DATA bTuVnLwETwlSDtmwn23pfA/mdZEhHZTC7rFXWWVn29mjOprJ7jd8InuP1HcTmfEUI0/V+Vzum4M+JVhQFQEuURHhpH1vKVUCE8hY
# DATA 8Khpl89gRWoIu5LKkkRwEoEcUOeDF8A2J6kkjpQPomK8wVyO4yB7IxcNBrkZaR45/KsraERQp/xaJl9VIjHpjYAB76HRBpYTWuNs
# DATA cdyoCRYynBs1kyRHThJvBfjIIYQZ1iW+Kh4OspHcaI+beUZhOFWagDyupVkQZjTKXprjEtLZC5X6pUpepHhuSHFbm7j5kIkkgWFO
# DATA B8BZAp5eQ8qMF1XZiCAD0RUd86VkM1o41XftXibhpuvQIw4sPJOkHLIcVSICxowwjkSHQhKlNGi/kkrhLQv3536rR8yz1S+O/RT1
# DATA SXT0H+tjlGSaZNdaUJmDKpYLmMNXOu0DLDRCD1C7du3nWuE3+XaZ8gEuxSs9iVeqiCajmUNcqFsEbEgnc4Y4rOEW1xleQA/apnIk
# DATA LKzYZTLVRquhTOjEnBzlZ2UmDNlsGv4hnh/NXhO/9Cxs3NARtNzy8mmnCgMQ6BImDH5UgwWQxZSzaOykIPGHC6v8EVT/JZjwBw5+
# DATA p5mFcW1rKyB5gLiGCXJjRhoGMJCIChljGZgkOB3O0BMzgtz1E6AhfMoj101TNg9FnyNc5DzeyKYgDApPpk6qmIGcsgNs0IO5ZxB8
# DATA 62Y3II/Nnen5VXUqtLBUwBNrvJO4Ig15DPAowWIiYpfAsLTtghqJGgPl85k2IvU4Caa0T30oFhSblPKvPRZOpROWrHbmT4VUrGKG
# DATA BUladCSARoYcaU0c4p5OZSSlBGcsewptfRVx0VmjxrWtRKKbxhZRHpuYKEomJ5wizjZKINu8LN3GEqsrM7cCNu2Uigg64/JEDKsV
# DATA +cioj+mMFGoUS/WfNHye7tC3OiR9oKwIAR/FcPJ5bYXNkttlIsGQoTtzK1Rtn/q0qlW58WpK2SqBGu0syr7OF7DFriVhZRX8xp9A
# DATA wLJqmpa4XVbp8jRbj1Rqkuk6nUynZNlHb+qUQgEIIPyLA2CJbN3aBrwZ5HUy9ISYMFoXEj15S0EHR7kVrXxnKQHJ2jtpcTfVlRIk
# DATA qdYSUjUHQ61kH6Un6dIYyOHmSmU2avtTj611JE870iCTFYsfRAFAu9EgcyKZst/AZEHQuSl9xsHUByqsmRw3pvFRrOWg+moKWk5t
# DATA Q/sVFUqYBzAm66QDG+N6NE9G42pp12kiFiHlhbnngeYCfmyXV7JLeKidbsf4iYXMrTojy0d3YvaDoPspgGezK4ddtdBB8YWVEkWq
# DATA Nmb0cRkwMpJLVbq56K2Zp0u1cVzTciUXFTaf/DjkBWBDteZppZGDtOK5JacXGBbjUr3POQMENvsomboodA+imPOqSK8BH3Gvmxwj
# DATA 6dyTzrFwEW1r3DgjiRVyW4MOYEJUnMDSScjzi2XK+FBrv+lHpKWM5rIOdIJAyPMFWKEp4dw5MvMoFHoWCq0ZLU1IvUHzSOLcmon3
# DATA 8EykolPC2sAoyTD/I5nE2nAwAk04DHS9kl7UmU/WMGvG5vKK4JpU+XAhIT/Tq8Zux8auJ/kSAM5Mm7gMFLrfDF/AZ0u7y3W2aMeb
# DATA 2Y+IL7290DkrdSJQYyILSiNCpUHoAWiaOJflfcxy1oaG+iKfmR47klSGub3Q1vrXrSNa/l+ArkQWZKrrVmDlIKdcoYr8Gw3QycVF
# DATA /cXzNhvknZvRMRvMaxRVUwJ7X/DZKyfFX+UO2mGLIOQSDoUzUSAYOe1DAYmWAZ5Gs5NErDN6O9MQuGXACcm6fsdyyh152kkdlvhA
# DATA oEJPAJPKjn8gEO1ZYAk8WESIWLumDGXcBxpH1vFiVCYoiumUwbHTbJE/8150E23L5AZnTxcOC8ZyTpgtPi4AY+16YeJyqqxkEdza
# DATA Xegw0zVf+IgcI3npGCQTm+gRIqYMDpZ2PJe/oWRX1Ip3lLSTBqI4P0tvgJaxYCgQmUotgVeoRJLmNyvOBbnRDkeeKu6UW6rsso2o
# DATA jYa6HBWta/2AfcGyIlx4hMbMFxwiIF3LQaq7D9AlLEVUMGSgjujw2cGEMDa8dU/jWPqiqXK1M/XX0MeG5pGJyqyxZm/HaXQkiEfh
# DATA w4RcdskuC8Xqloms4kYZk40Vc74pGIOqDeV3saKx3Mckzi6ZZuyaU8TVVm1UzormDF6VBzX1l2cnKd0cuiFEg6Cw54qs11pgm3Fw
# DATA zgempuoGmC2Dm9NwcZVLzzEQDn/fVvAQWxzRST92nFDgEawFYM0RGwKLceSRp8yoVxiqTNIFpd6zhgWq8niBcMlpuuJZgZXhM3sK
# DATA mlhXwIQKjFd8Tkns80K1UTmcpsV7PBphglNBSRZ7GjlOiaGUq2iYHIfT8cjCgXEU8nQqe5Xa7BQsENPPs8c3uxXrAWfpbTCW+FVq
# DATA pafxWSMDi/fgwXWjV+gZYw0E3N2Y0sXU6ibQUrhnnY/r8epT9iZ9p2AMHnxcoBsEg1qXylT3LLVcGhtGHZkIRZ2lEbAUzmKpm0xB
# DATA qnocjHkjImYy7bmyS5PhOCYNic5OtFoN/yWNnauiZ1P2EKbZmkqCKSiIuJu0t5Xy4MsOwriC2SqN5lQvUY9hJDp0xcLGk522yE1l
# DATA PJP8rxIGBEzYhzbUuvybnJpw2pnSLDbCJXaEfM352QNhE0dWdYix7VzWHddN+tAY41hYsFLUGlgXFJ2s1Ktf60o+YPk2CtRZa03K
# DATA NahuU1Rt9XFlbzmpeFQkC3L88RleCVYVUVL30Osi6p+KFPNUV4JE4SAqQ1VQjdSuLzt0WjI272XPdpvShExxkbosYzpeM2XHTJqD
# DATA cpJ6skS5OpVNB6yo+A4ijV1yOTXRqaSOO4CCAI7M3ONDiAZmS+kKyHOhj8Vj1b1sHGF9J81t1rmCi2NYWwzfJcEVFIgKhcelFig/
# DATA CldSNjhnhNPu5q1tipBwtYR71BAeXaa9iizQTaVOKWKONLMOqhOtRBT5ltbcKTJ7mN4qF4gHTWPxPXEoPJmzb03OUGGgPhVDhQuc
# DATA UiYQlXggK5ZCmVVd+Gyqel7SfKlWunmHx7uOpwEfPqQy5Qvx2HMLu/JhDZlM6q/RKq9J6nbBMcKJBqxR6PKMUh+cM71XzHZpXoow
# DATA 7KPW1O9ytlFBXcXCHgAznXcbs749XQKUT2StTA+1VQRVusBN2yV3vqcrZFNtaMxdVCd3oweP4Og88cAzJXv1IIXjAVowU8TfLe7L
# DATA jgRvrkOc6Pi00k/VYagVc4U5oEcxNYnJJlkUg3SXbGTEWKeS7RFKDREUWWW+6XSHSw5sDCe57WvRFbSqHT1C3eZF3iN40XJYn0L6
# DATA kdAJbYmxbSJp+8ek1mPVvR8XiUWVz9P+F4mO6HIxUlkURYIy9Quk5UtlDitp2FtyXUvBTda5lGeFAeNDcmXnCD33TZY72ji1Uy8S
# DATA PLoIAoaTqFlTUYFLTzowZ8zEv4K6K5PDOImvY5MUQXsOC1Bn+SLgxChWk2GS09gp0YlCdeymtmEAipeZ+Zp1Wt02hclSwyzOhbKt
# DATA oIXYvPUlI5mOWlP0r4wHkTpg5+fGuZiqZSVdtFqmi92ofFsNmxIVng5U4FxVzTnbMlqynaclNEIJ+Aw+SgPHRc2ELM4dLBZlzoK4
# DATA Q7C6R45uiifr4/ekou4U0QIDrWFdjCwhYZJmt3QCtKxQG0ffuOQczM3K5OHM7LquQ5IXzRXWpXNTYspUBGCNwBg2hVQhrbOYdCA3
# DATA JXS11WFVOjIlXosGsXhsSGU1Ri+KJEOcOrRnJTVKhM+TGNIQ9UZJ5DRH/sgfpu5dYABNAggJwFlwO6Gco9SEC2QEp26ClExRPlQp
# DATA VXfLifHCUgqV4uzxin2zTlZXRbQ1mzbOVeYiyh+3tDeUc7VOx31s8ikye6qQucwT3FNrDjvTiaySSlPlPLYklhsgxDpPc1UbuMaC
# DATA A4MMAAcd/+NEy2lUNrTeoJJnnovSoY4j54ofUsy1ZPtKoARhi8kjEHFVAiFQw9Q8fcjSxQnWtRe6rRu/envDfxFksFrtZnPA2T5X
# DATA urSp5dzT5ySosFm20LE7MZ6t5BkyhzENMaH6gGJMmpsuRtol41SzlvQR4GtaMR7Gbv6idqzb8Us1TSq11Go3/MPUP1mAdkENYa2P
# DATA qLJYxX/O13yw1laoO8fOiEgqZvlVZQ9SWbUFVSzhUIWlMxpAayqbDFMYoiTUKfFqiLJg2q2qtAZIRCGL42of0Op3dRgBPT42i3EF
# DATA e57KAX51gCtPJovxPJjGXCiHM+aWKkU5DgBVzkOdy0KfBE3dvCZiZcnzbjt6BEDg7gEV7Cg6hRQ3RNSSo85EudX5NYqik4YLFjyW
# DATA /VCWGyk++iCj1nOs3QpvAWuZWKLeKyREyvkQuZqJfX4abcOUtL7UuTzBwZI2uSmUMMpw+3KOpMoYcw9tmRo7rU4D7/hKYX6HomPv
# DATA m0rjTzHX2midq69R+bY5eoJ3k4boaaQQdSydGOE0BqtqOFu3+iYdT5fTsKrfZzTBsTmLulwsnbL/aEgZydNnMslWs8qv1+hEBz3k
# DATA i7ys+M2qYppagKl5sHKnPN3OtSOlx0wfPiZtLChS93Qha30IPgAZpct3yanSQBe10Ke45foiKdRSCgwzYruO7epz7xJ9tQ+264s3
# DATA POvijRVXpKiEIus6osjRvDnjQ3kctK/h2xKkNnSKBWmmr0VaYpmSpRiZ0pScezgkj7n0npFVN/zwGUM2GzxTFMWUwbWrXxRuspAj
# DATA U+U56pT9YZ/fcMp/UE6YPle5XLBFJV6buepDF1S0QBdvIQ2dzv3auVNqTz0CBciTusiTYIXg5S+di64chxvOFeUpkJsUOngOllwk
# DATA Z8UCU3Ytk77ksi7rZhvx4z3m7iVm5xgbRJTBX6rpCCiwu/MIAeg/kCqFWDhqlmSJPo4t6avmkiLELALLWaX4QoTHhvAaK09uaKEh
# DATA gGZB05iIzgbyLZvqkKWiMEAPl4El3RTpYgHzR/JQLaYLrKao0wU9fY5A0n+VsaHzxfkF98heOcK8AsLWZPfjgRfjT2etSVSvudlv
# DATA BA1nzxN7snyIK64MEpeOSsZTgHoa0ExVpnMg8J0Ll+ZFGvIMDS0nVWrLkNF1a92txMMrg+JBcjIZiOFVqkJgqi9yc2owvTIwLVJn
# DATA XdIGc2kxgXbe3PJ9fPAkUnfdjRZYrMkr3iX38F7AnuTYRl0XU3lzW8nFdecmELrheoMyO43IigQpNYvxQr2rN5SHyagvB7S0SsHX
# DATA M0HEXop/zs65pZpQkr3t2Wc+rFLtIFDtNyz1tKCk4yl1SYhPS3KmSB+Vu+mU9KdJqYsmicRBZ3bIE9lfr6EPBzBJfSXHA5DpfbF3
# DATA vOfvn/iHR/5XO8fHO4enX/vPj459eOC/PD76/HjnRd0/PaLvez853Ts89V/uHb/YPz3de+Z/9rW38/Llwf7uzmcHe/7Bzld4L9RP
# DATA dvdenvpffbF36B9h91/tn+z5J6c7+ML+of/V8f7p/uHn1OHu0cuvj/c//+LU++Lo4NneMV2/9QRGpxf9lzvHp/t7JwjHl/vP9myY
# DATA /LWdEwB7zf9q//SLo1enGnjv6Dl08rX/4/3DZ3V/b5862vvJy+O9kxMAAPrefwEQ78HD/cPdg1fPAJa6/xn0cHh06h/sw8yg2elR
# DATA HVGj2qreERjo/8Xe8e4X8HXns/2DfcAX3hn2fP/0EIYg3O0w5LuvDnaOvZevjl8eneyhMEUUQieA8OP9kx/7MANB7J++2tEdAXah
# DATA jxc7h7t7OJY1Zw+WCafrf330CqUFzPvgmYMURNSe/2zv+d7u6f6Xe3VsCcOcvHqxJ/g+OYVOvZ2DA/9wbxfg3Tn+2j/ZO/5yf5fw
# DATA cLz3cmf/GLG0e3R8jL0cHSIJ9Rt89EAH1A5Uvjuyi0Oknr0vkTZeHR4gFo73/vQVzBMpxHcpBPve+fx4j5Bs0YP31T4AhSunicJn
# DATA oqjTK/DAEMXXQF5H/oujZ/vPcUmEaHaPDr/c+/rEszECODbkuvPZESLlMwBkn+ABCBBDuGbPdl7sfL53YlEFjunJpcd1/+Tl3u4+
# DATA foDnQIuw+AeMpsMTmCsuK/wgnfg7sL7YAxImr6H3CjYBEt+hIhoYG3+zga2asZcJ0j84OkHq857tnO74BDH8/WwPWx/vHQKiaH/t
# DATA 7O6+Ooa9hi3wDYDm5BXsvv1DXg2cL23v/eNnntpgRLPPd/YPXh0XiQ5HPgIUYpdEfNZKcIuTWt3Dxff3n8NQu1/IsvnONv7a/wKW
# DATA 4rM9aLbz7Mt92ooyDgC5LziB2VEPgkekvEGDDUi8/ENT38nSESUjtSKH1emTUNhs7JCwObKhC7dwnrY4IYaxaD/jFAta8OElrqos
# DATA ufHCefmAHCeYe6gcxjdsBS3I3CPjhrVj6Sm4UYeHsE7pOOUzv3i46Q3dBpF76Dcd5ukYqyRQ0WhWPlDlTq6TsQV7iV/OMXtVMrJz
# DATA JswcRnERYY6154VCZDolAqs6gJh3C9sC+dFylt6g+AVfS7VDGODMv1N16uBrlGKHoI5K/7kOP8rVRHJz5My+g4EradONUxJeEyAv
# DATA 6dBqDqI4leDdIi8cEq5LWC2fczEpzPC8onCMzhSWkGoy99wraVnJidW95HwxhnXtsnX7tA5O5uYswqmkEtYx4z4QX7LRS9WpOK3X
# DATA q9TRfTKJ8mCEE0N49dsTfbHoXI7gUMaZdfqCL53BeKWqwT6+9UiZEme4VfzRrbdMPVEX+RU5g0ipVkX0yMZZC83VlWM2YvHKw1lK
# DATA vg12UqmCR6OFLmqLsxmhtgk4+SEikt5V5fKsuVdyOkkm3Q6zJB5h4C3QtaMkttL4UeGi+R9icb8f+f4P6fVUncL8EZp4Sa66Jzjs
# DATA Bd7St0w7y5rMfedWZi+ZlwefH6PpBvnjFfG6MkmWDH6Tb5N5VfeocG3ZQmksz9tMT9+0dYWBKHVIS5mdsH1g5dhcV4oW8n+lbD21
# DATA 7yfmfpST3LCbkVfUlwCXq9Ql36hLJ3H8OONH7rCne9PR1FVZgTbl6vR2N9Hywb49p/6bwSIbc0DRmBUT+z+8ms9n+daTJzc3N43L
# DATA 6aKRZpdPVCbQkx/REb6cDAGnAg3WemHuSEESvpacCvajSzhLp1jSCy84CWaY1ARz0/kZVj3GMDAXLTKkfNvxPW5KT9/peGsQxaW8
# DATA 3evmk7mSjixDdOkYvtWbszNVxftyL3hmUx70EQ9VqIOpHO+YMfc6sataVSgO/DV1lRe5zPicXBxEuYaBY4zAxK9jT0fBIp0gzlfw
# DATA cEH529zyhkt5TykwRzc9aVOOJC8pGGonDOP5XLKezHlddQHTU6IBffygowxLHWAtFpn7uoB0RCNhKgbEpbeYWSKebHNTgrrfL85q
# DATA lFWHth9sTb5+jSKQWA2Kq6Epbmh0oTWTTmFd7W7dCPJc5za49IlE71wvyZoM/iAWp95HdAM0YMJ7cDd87w///if5BzbI/u5eYxL9
# DATA Hsdowr9+t0t/4V/xb6vbaanP8vug3R18z29+FwhYoHIFQ/47Xf/v+ztz5/J0fRTL847jyTTAWJCc0OajzlxElN2h43Q+B96L2dzT
# DATA eCznwCKU05TtRj5w6uWGtMtpJDWuiJesdxrNdQxjPjVnXZSWzJfmUskJVmHkyg652bJBgYufZCyuXuvKWSiqFjNJVXsBQ7QbTe3t
# DATA k1Nq2D+/D2OjagrK4JwuAzJ9pDdTsMx39w5RUfkMFDbMwU7H4fHprlK/CSWqzH14a0ryKaA5iAYwm5yWr06fvzx4KkEQyooEyQ+I
# DATA ezJVd2BeZuJKPsUklHVOQtGjoNlGN0moq6noLh/EtFo0kD2v1PwZ0C1fMetL0BwWwwYg8Umm1uTJMAhfQ+f1+1vBQmJC70PNplRY
# DATA tKTJT04PTp7gcq0jOiQWg+d76FZMcu5iCX4mGzl0c+9I9rvr9G51o9FsNGsK1YrAGmBf5Ya+aFF396zyCw7JMQ3EaLr8O9n/eC8l
# DATA JlA1wp/m/zb8v93sDQYu/2812+3eH/j/d/Hvycf+8YJKAqri5mBVcgoFsSaw96iW7BFfQKnrf1wFYOLmWPQXfVchHu+iAwbAWj9+
# DATA 4lXQL8PnsipPKSF57o9yf1vpydUKsoqtUV6pqcdhdjsD7bPYhH82zd76L7MknwS7Y67Pwt/8O/vFJ2AqPwE1lvjRBVj1WDjvyR/P
# DATA qOmTkN40PUZDeLdarfnbP/Lfej78w+Re/oT/uJXckA5NDylyV+WBP21wrxJ2/rTBvX/aAPMmmVcrjUrtrHnuf/qp36z5P9r2B/6n
# DATA Vtf4L4iCGVgeW+QGqz5yDvLS+uyyUmswJC8va1W3ZwFeXIcnc0xb26IUYbAJGvH0uoEe5s92TvYuXh0fYHGMN1t+u35PH6dgaaSL
# DATA +Qu8tC/f8lvNC9iuYGiAeCw86vAjp6+7OqwemDXxJODZwqjVVeDUGnmMVt/LAA2wBhhQ1Qq/W6khOivs7qv4dzUzyp2/ReyfbmJ/
# DATA qn8Wh+aU3JCGeKqypjVueQd29hyUDINENKtv6LW9LEuzauWZMEs5lTdWJXKxGgNey0hb59a351FRvXt3tSrSHBVI3r2Kw9fUqeQr
# DATA 5zyE//bOe/KElRMlsjgAHvknf3pgKvOBcU8FJgLOJaWjIJTjzJVydG0T6EyFWFltgZfSDPSnIyq4Rw5MMOexlnGCF+FQaWfe2yQQ
# DATA TX35p9gXno6J8P5aX67U8ieJqCycacVp0GCXy9U2ulBKQ3abGeaFehM3FSO90m62+83NVqvd7AD5XMRZcBGM0a6/0DmVF1RKvrJl
# DATA rZPAQkjNF5Mtv9LabHaiYLjRDkadUbvVb3fazW5nozdoDjq9ZnujPxoMWq2NcKMfDjeGnWijFTfD9mYv2IyCuDkYVgxNqZOzqncg
# DATA 7jOHrCvdMBq0R9EoHkRxrwmvB71oM+6HYdBqb7TDjXZ/YxQG/WEw2Bx0N8LmECDqdZrx5qATRr1oUHG3SSUcBb3eIOwPh5ujuBuN
# DATA ws3NdhR0osFGq9UatQZBazPqt6JRByfTHm10Or1BG2azMWoH7SDoWf2d88e7unen2F3Ot7Zv49GERYxM709Ojg4bObEHoN4q/V73
# DATA qxd1/5qY4vx2FmPZDH97e9uvDJEs5xXgY9eNecpcBZjnFjRWQyD92AMwD2+E5L3/Ah7CVr4K2r0+MC+u91plqHjsWq0RJZdxDjv+
# DATA Kn6DG0iVZ1b37sXRQQxaYK5gnQVzHPDsvK4C6EBRdzUhkWTkc0P/j/5IT4ZhwwlxNd0KPvxoJwMdtZHk9FegoQfSAZW0mIbYA/AC
# DATA efbZAv1F8BZ/UJNwCBSBOisgGqGunQOoV4QSgaNm+BZ6dKqMUixeimnB1KaBJbn1MKU4OYMmgI2zRqOBw9R9/s6AaIYXj/P4UcDx
# DATA WPyacFN+7al3Z63OGFQDhTWDewflHyHKeZiK/5d/6X9EPzcowpF/Bap+tfIGtn1rqwJTk6GoCQ/O2BjeYvmcbV8wj+ZCVfpBQ6ja
# DATA BzOggoy631X4NGjcLtDjJAg1PdYd8bjz8uXFyd7u8d6pplMCbh26wQmsX7cqmladccJkho79wlDPYv49ua5WgjhfhxHXL8NJhVan
# DATA zrNqgGUTEPWBYG21a6pbehFk4nwHrJbT4LJaaN1q1/32Rs1dI8EPpn8F8+qZdCJTKXSAL9fVOFSsqFo7r5ktXlnMRxuIzTsvyG+n
# DATA oa6Z7ufTYJZfpfOqYpVq8RkXtLNxtcByw4jOsPGDv1jE2e1xcPNqimGv6trJ3sHe7im3vKCgzvPjoxe2p/KCZX9DOvuKslq4PT/Z
# DATA VgrBmrMQXCRxm4T4CegQ/H5jEsyqc+JtDTOoQp617WZ4lznQ7tlZJYgmyRSWiijggr/hDqtoo/QCVgdz6HLdquTR+bnNGHB7EIgN
# DATA 2GZVHA20ReIqhV9b57WapY8Y/aFaAUhHY7nEGGPY4a2g3KgeBh/oMDDyFv+Rmx1kWiWJEG5YyGx+sVjwN3yIkODneZb+NJheqJLK
# DATA +NM1hp51Y/ioH54bGUSowgHKOlUvXCCbwR+ydBzbb+PskssL2JZULg4UxwWeUV7GrDzhGdskYEkE++dkOsRIHGwlmz6WSeAsDKYY
# DATA p6E7QpJ4HOXnFieO8VwzMF3Cq8Pz+W1ZkG1f98JCh+kHhKhNTiBE+WvF/8S88LTQpZLfhkJ0U9CMrYG2rCYMBz4XiBhdTx1K/Ii6
# DATA hknQtwLERCeVVURIiXFYO5FbPdWZw0+F/Az85nTMPSyhIiwhxIsap/fzBG5TyhR+0KJsBbPHt3/Q9o+OMXvlMwxTRsjnLmZpTul7
# DATA RJDMRer8Tq2IfDXWttYLP20YCjn/VAMDoo2pBT/pKRPjCUknalhTqwHDxWvD+NFHsFWIRUcXwRxhYulB384bqkhBNazV3OWToRuY
# DATA zi89mYHpxwB/DOyRaW2hp4fWVSsZggG0LxwqXcJUEuH6uuMvz1xoCzkDEid/wn0Af4o95hQ0jbFf1GvUlj3DeoXwXaZ/XjsvvggT
# DATA u1f+/Achth+8VUOYdaqsVT4JP4H/1ho/TUG7qdQrtTsmxbUfvCUiuVv7D0uzFxMKmY5iG5/d7kcWFyqwGUQ+sBUEtVbwEJRsxgJX
# DATA rBRf0TvaVWih9wa/+mlD+B+MhlqYeaIfNMDquwQlcAVlyNhUzWeaKnaa2/pryTSlmUy1OGTZNPRUpBEI7EsE2eLfxOGsxw9SMwZ5
# DATA FxyhjjVI8GIZ8DS+NVYQRc5Yy2/ceau/WaiQjYTaRZlsdaRpzdrglKKV3tTwP2f8E+rprHxbvxUgY4o8E20O2yXRudHwlymfujqv
# DATA FboxtFzWlUhFVMj3lGRc6vgsLPExufRdojihUsQgUROUXuhLQ5dP0QISyJ1BnIncFS0zw8FxhwonqWsnJ096y5r8nct6S4VBzVEj
# DATA SMVnW6FMgVA9WO83ePhaGT+Q1USrjkwq7rhs/wixUd4a8h+9HrbIKd924vkcR89ZkhmhZ0PJSIGZIzCIgPOnqzex7kwbd3gut/wF
# DATA aVBAlOmBZUr1jA1csv/OyWFhLE2LWjV08B9847xs55b8RhuPsfcwRxQZiUEVjfKipITPlS3+SboVweJXipvtrkCxd+UGeMEewxBt
# DATA 1TbAlU0bZJfXZ23ePwBtDGbD5dW8sqy1TmzX3IM6mm5NEh1sSPGU4b6ZUibcBZb84EpWFxhwhO8iQi/YoX1hRlyrLAtT45pEJ0+p
# DATA /EzwKkIsT6U7Kts22KrhAlIzqqq3TPyso1DvDXeeT5c6/+jJn58F6z/bWf+z5vrmxfknP3jSwGRVMvBYylI3FlJWURIeXsQMq7nl
# DATA Xy3KJjPiCIY7f9vv3qkBaRi1CrXVg/CNLcaDGxoHKlAngV2GE/G2mRCFBCUM6p+o95HWze+N/C/GlbIelT9nlDfiN7DY+QkQNLug
# DATA gMfDr1i25zloG9bvRQPGsrlG0BV1+emS+wJ6oprm1SffZN9Mn1zCpvtmCbWKZYrDV/UGoJzRhzoMgf+zOpOuMuzsnEUdl8B6pP9T
# DATA Whc8nzjLs/OSddewGXOguOirJAFW4pkaUQ2C5OhmWi1zy9eZBGDaZU/P8OF56TJoMHkspPwSgOlho+C7533Cj5Y87x8yWTd+Y9P9
# DATA Yspg2TdGaBI1pO9/Utoneeif+ogPNIacHeNAhaT/VIdJ3IZVjY6z1jnOuEKqtKinS2JgWY0khU4vSmO2AJoq2a93JRoPs3PtsyvY
# DATA kFanStgp6ZHPo3Qxb2BhfOD9XyLvoMPVFndeZiU5T9jq1gg7xJC7+cqH0lE3LbLoXq84Mi+LK3ulsFPTdWRd6WgSiChiqQDsQ+Nx
# DATA ILBEsuo6rNscdpkFWR5XixyuiV4y4lcWcgogaWfrQ+h7qdUScs7U5UJPcjlhmjgGEPmqaLIlKTVGad06GWBp6ry3CqJEX2XHfmJW
# DATA RBoUVq3GFN9EXZNQkY7jBv0kD6zIihUc/dQ3q08kJaFWpip6szHBDNfLGJ0GK9pKWFZHVI1fv26RLNPorTo2rH2q4jLGEi1WmgNW
# DATA o8GyNA10dumgwZtkvoupXNt+6ylokw0p+i/ZBahDYcYux9OruLj/9vk/MSYkY+z4YhzcItnMbr/b/J9uu9fqFfJ/2q1m5w/5P99J
# DATA /udHTxZ59mSYTJ/E02t/dju/Sqcdb21t7QXfSOdzOVpDJ3wSP7cMGlII1UERMmpw3zxLw9dYOwn2ZAO681QZ0eySmJ76jsns6vNo
# DATA OkFeob7+NMdbtPlzmnNJExxrnAxVUdKX8FU1yXSf+W2uPmLlBfUZnYueBw8pJgraBPDDOTJb4IJV7Kl6cYE88OIC9US6WhvYF0CL
# DATA mllND4N3fkykwoqdh2iMGF/PbTIJMGuSElfz+AKZk+d5UYx1dGezOFIRbLBqMZfqpralrLYkVyxRtQEo5bFlBSLo+B6wQw78gtiu
# DATA 4o/QY622dY5dqWC3r36nq0WtuCuunX6JdHYQXcTmqdVqkMbAM5dhOpO5oT5kTY2vSEc7LZGY7vnqnrEi1XLPb0F2bfn3dE9eFmeM
# DATA Bn7LqzXHduZp8UKotUGayKvskVxaEB1EQnJtRHE8ww/SuqZjRuoOtESZ55K4xD9jYPAtSAUaHUAy05MGZxXYg0SCFXREyTxLHtrT
# DATA BvSZJ1RARICgBTw7d6zla3RtxVYrBpB/RvjOzi2wSlaHGsrykKjkX7gbjPQD5XCayDSqbC0prdz6rMLZSPYsi0+sKTozIN0c4K+K
# DATA E5yirXkMonmeVwqwf98/EVzQDfZY5UvOHHKyRc4FgTGjiBhL/lQyq6M4HAeZVcZhGI/Tm8aSK1dlhTjYZC/IEiLvJ3XCZUWvIT3a
# DATA KrVAeJtXilTi/FxE3ojKS6eL2WMw50zMImPqYBUF/2vM7tvOzBC1vekMTZdD/BBhV6IYl5QBtog8whz17CKdzaVvdyKKju1m52eq
# DATA sxKCX9GwOFHH6yesC/RuEE2gtKp5JeSlFbFThc5IBmNnlRkt9/o66KP84S8WSQwGkWSq1hQrpgy+KF9m6uc2GCiaG+M0iJBjlowG
# DATA eMWjCTDSx9AZCE8GWG/DqMpeW8knJruEcwUxqIV7c/swncYyrZEUw6eWciJeXjNwjgPYpDx9ecjrtUvELmRAvxxQywqJwbd3NkG4
# DATA IPBxGGrML8JUGzzJhkiNhjRlrue+vlV0KpGX0VhryHDQofm4ERp4UhD0qosoyXABK7XlKIr/8SP7kvghBw+pM5WwXC/v92yCRY+5
# DATA Xz6wya/J0dwFFTsvYv4F/i5C5fzcxnMwlew6pZWwT2+VWsJPRS9x2BMhsbADhURPM0G2fH8OVpuS+WhKXyipXEWtrK5vNeVE5u3W
# DATA RlP6jcA0p4NC21zHa5LCHkHVt4owSXtqeXNFZ/KLjX6ou7C4j7NTGYJVexQ2EQHn7lUiKqoZinrJh25IYn8AQ1FJgJ9Rg5SOiarx
# DATA O4/Px2bG42oolICVBuyddbyYTsmDxVb0ilZfxMF4fmX/gk0WuCNRPB3S5T6VK2p1KyseEn0JVKXrLQ+LZPYtgKCUhKka/6Hhh1kc
# DATA vDY547j4+RgUxGpbGHeAZWG/RIoVd8nuzuHR4f7uzsHFwc7XR69OLw6PTi+O93aefV1RjFIOPF8splg0q5ql6bxujr/ZfNNikWSH
# DATA oTICtoe81Lgcp8OqfhH30PrHlZorBvkuqAbWcCD7qwpf4jwMZrF5E0k9q6x/E71tde/gzycVTrttsI9YRm8k+UV+O8Gj3NUaX8A5
# DATA 1w+AcfGP90iB2gNMU/CCpz1gdv4TTPMMXy9m+ROgArzmZJ29GBV4pMErvi0mXWPyGkGapFG83UwHeJKBH+TbyDtQIIF5c5G+pq81
# DATA h7CkI45WFPUgA6Rqh5yMokZV9YuKjqyjIwsN0wb+pwv25lX85mxrwwpf0zwALuv1IpmIQid0QgVAbKzashRM8R2Bj/3gkhCm6kzT
# DATA zSt0c4wplEw1UcDYu7YUabLpib5xIXg9jNUsiXaK7LYZJi2X+GfSP4sH+SpaEzGv86kCUFzpSBK+hqdiVrxuaS5LO2//8Mudg/1n
# DATA F7tHL14eHe4dnspolndjm3wKVYIXOCjd5AwaVuVcw2Ual5K7+5iI/j6QXh2e7Dzfu3i29/Lg6OsXK0Cy+iygGGuVRgGHzyiuXcYJ
# DATA bJBgZQkmlAAl9kXVZQQV0Ry+aWTqMDDygI27U/hv/+7PkBN800Dh4/CDMsNFsQhJ+/Iru0EU3aIK0hjSNX/rdH/n+vVsWinrQF8y
# DATA ucRnuIIG/4r9VWvntjZrcLSk1OK+8CxhQb3g0sM+hK2fJz+L/R/5G/7HfqvZ7qo/NoZN5/eu8sHe5zu7XwPdHT7f//zi9OgIWP/x
# DATA 53sVtVHUTsVYs1HqeRfoZ0lOALPMNr+LknOJd35knB5H1HuuBQPQMN70bAiiqrgnvwbkXWtkJCoqH/NqFkQE9+CgvSCEVxH28d7n
# DATA +yenx19ba2pgbaApBKqK+NRIganyWDVuH/D5ZsxbUYqP7UYyXbn2KzotyVIQLxGF5tgXY3GMFya4zrZAYVKOqkldWhwsj5+L+lxq
# DATA 6jPglC7GvkV63+UosAJ8WsLsap7i9/1dHsLcSZVMBRU6UDNP04a/w4w74lpOWCkmn0tJk2AqfSnvUN1Hrwyr63XJrOYLvNAHwNVP
# DATA rSue8nmKhqr2bXgmH9tSXW3XJnPNGqmuAiYy6Y8piVWZYfBsmq5TQZgZXpkb698AznVCxEJl466vc7YvfmayJCB0taui4mu8cZbD
# DATA R9pEi8ksr+pXQbxPsQzORZCHSbJN1gG/yh6oC2WfvaXVk1MtsBWsr7gfVBm3qnhMLb79xHKfluVEGu9RQTg6pHW3BJRKGnCGIrbq
# DATA Osg0gyWJeZlM35DhV6nVSlRG072z8V2+upoJL3mCHsVKl7fNMh85OXp1vLu3inUanqLX+5NtCtWCXiWaUxBdzOM38yo8TlGf2cbg
# DATA 6vqG9DDDC9IzSnU6m6evYykbS5+Iw2AUL0KrJ6tUKmd//k2+Vnl797R+/gl8rVsDsyv2Y3IY8evQT+XTwvcz850ZNG1HGv0+G3uF
# DATA ++PR9jfCZvV/ip7aurhpLY+tAxIg8sz2fOVFoCx3t95X93q8vbJd8AiX9O/khT4XfUoQIFbHKocnz32JnJHoV7gtl4wUs1/xZPky
# DATA Q6gVlDhrGPXaNu/MNNPlRtjXIaZLXrJxCl6PJc/HI9RF67HawRpSpYSzFLpHP7vPutONnJVY0ZnRFmVos9XuGR7VOIkjNuRviKLJ
# DATA HBXF3V5T88YvglziAiuTfkpIpaohhC3ReKI5Dv+iHVe1D1dHeZXFqrKYdSZ2kBi9FcsnYNGzfls+PKE3Xa6elZkvVfldmbUWu89s
# DATA e+axut9nO7s/fvXy4uXO6ReVWgG8Eut7hb0t7cMraFulpqIaajNbz7NaYWt2nVWBUuPaeXkJChGNCR9ZPHtboZNqW/bCquS9LRUK
# DATA blDQmH/lJS+6UCs4gOrFCEX81f8jHwYeDO5W7ERxu8tInNOjZg4KPOhgCVYOVTbYW0vB3CIaNPwHFTN2+W7xDO9qwu6v2Ww4V+Uv
# DATA XN7I2zimS+8Atp8ls6qBr85drVAAihS2EmP+R9s8wplC7/ljlAPRCrD65Od7zy6evTreP/z8Yud494v9L4sqQokfxfYSuY0JJ8o8
# DATA MVyKPfz+Z8BR9lRpg2VkMbPC8pzA4qinWqlAobFLNtu9uhVZ6WXwq7m5PJVwxkwFM5aqlXf/7/u/efeL93/1/m/f/dJ/98/vfvPu
# DATA t+9+9e5X/PHX7/8jfPmv73/+/q+gzf/GD3777pfw9Zfvfg1//xr/vv9bTsBC8lIeKSdKpeo1SoR9HAfTxezCGGtFh6YT7FnKq0C/
# DATA Tu7rLA+0DplPk96cG8p11V/XWeTwR0pgXrKBkYEov1zDMjdWEfS3t4CXFGu3K55XqXHMEsWePWppbz/+mO1cy7m2VeYduytYz4RL
# DATA Wg2jpJ3f65PgoeN4umSTc91hZc64ZoRl4SympMdhDj6b3ZZ7mnIP2fNmJoInXErlXKnypdmfv23yekq8eUWTWzn39OukkMbTxzmk
# DATA H/LA1qxUj3hKXgE9knLmTtHUHYOdVNwdJinoQZfot/J+rvbgiuNoxV5xwgr2hmFK2PbL3DreMkWYpa45S+0roiohnPvmqedHgZX9
# DATA w5PTnYODvWcCHIXV53gD1n3O3rqasobm4V0Bs4LOUXnn7re+PZV8QPxnOSMMerXgEZMBMUtTQu/YOCp1XX+bIBD2ReLHzPb7/t4b
# DATA PF2ZzKm6UTYNxk+kGqJRRjivhi7HScZ8qQvL3G+PtDIE4AAyXR1/4tVZwgA2M7pZFF8rlLm/PsKZbwJ8luqbOOkPRIV29oPQoMon
# DATA OGfWKKA6OoLVCz92sHG/G5rjjc/28eqPo+OvYXNcvDrZMxCWjUd3i2uUPRjQMJM/RT8Nb0I9onK6SIYFyK7QCrBavm48dve4BI7a
# DATA 45IzighmMTe8VXkA6Or73YeUzoBB+dbEZNA7myoVCvAW0nhala/EAfG7AYzGRLN2eYtWznbW/yxY/xmeADMfLxrr52+b9VZ7cFep
# DATA S75bpp02SkGyBniM0Hh5fPQnsIRAMXgPjFlJyrff9kvcwPyYQjvlCQqS9fB78xU7OU2oq9g4/SGrLwxfmdPqgagda3V4KYtGDd+z
# DATA o3YTB1G3C/mlPF7dlkLcXEo+WGmfzOhWNTxzXcXnHPbJhCWgrGbKXFeUCayuIrpdsQs8q337Eu91oH5WjHDW1LYoJnnggI7Tuc60
# DATA bpCsUm9Jc3koY+RcNAeOORT7djumNbUdQ9yJ7GjyjSxnCFTYP0DpAeQYcLMiVrsK+P0HsgVqJWa6QGKpTRLpVMa6tU9WvalWz32R
# DATA v93/JhYHNF4BtKrEIYBJ3ljPJ5XvQlxYfEcWY0thFJ0dvCLUlj6J00CdpuEiF155TKNIQss2mABvbxKWjewp9Uz0WIY7U341PDoY
# DATA oC/yYp5ytjvSbrXg86/V73O6qGjbs3gU0L1rYLOP8RoBXcwQf8lUaVQ8SmiOPbBDhK5DaSwFVNTEpvFingXjCzVB1V/Oszwj/XMm
# DATA 7siVeLMDjL9PTKyiJXLxFGhQw1GzAtDZ7YXm+BZVKKw8Iu689XsyuSXd0F+2pnWTKaDpQrUrOZ9hc2ElWcwrH22XBQgKaClfM7K/
# DATA adFMwFA55SznvZQBEqvduD1EUYZ1VlaNxQXkmOC6MW6WnXwFgYwbnSWqJDfil04TcwctCWqjoaA2uiiQh67nTQFr7XBQv6VN8ZHC
# DATA hRPcsEWDpsWtJY+fr6wxiZGWuinLAddOw8WUqc8oBM4+uVfk1lkRsKns5qJMaRKpW1taFfXCg6qSZHS7fhfi2UUnxlLHi5nWrMBE
# DATA y/WX4SIZR/xttuCsVKr4rBtQpi5ShozkjC5S5LGjR1qNC2NQ7pjePxiuj2VU159rMmXd3F8DRelry6FX7meZUKRSRFW3PlNWxHmp
# DATA BXF2n/Vw7i1nT8nh1W1LD+Iz+GWnTCTPZyUwe9NrhgSDq8C5pL0a5d7mNkrOKvtYH5x9dOZt+bH8AEupF58uMDy+oJsX90+/Vh79
# DATA kkww4BMXEhz2NeBVye45xGgNSDr5+izGW40lxUeS1W1+sSJObsXIOY7M45UAg+TzuwLzUNT+8dCww0cD9NG2Dd9jF+PZ0e6PYSW+
# DATA PDp49WLvMQuilHFjY+PB7xNFyuXjWjaGzJ5MD5uwoop7dk1JzLp9OsmRrsrgKJUConqoXjx3GT9M8mt/Dvdln1fQqs3yHRX5k0qJ
# DATA hHkg3pHQifP5bQnpAcwyN5JSJslYvVM186qVBTXKxZnuuG7hpXzZNQgfMQzla11QXFRcQ79dmi66QvJSEA40oq0HJrEafrcdw1T3
# DATA l6Sv00zOxisZ7cj0+0OClHZzXZTAjvZVFIylWsGHq2Ucx6b6A1v31Vvz71VfypZdv3yP3uQMUr6MthJX96topNSxJEtcc1S68k39
# DATA gCbGfVpdLr3saqVoNZUk+Cst9f5Ef91qhfr6uzCvArW6PGzJSnZSCNxdt/V7UHzV5rH8GI/RO5d1TqVFfqCm98E653enb5adMFtq
# DATA aGLzRj0tBpXKoyCaEakzSd6jokZ2Y4mWSE+ehzcNXpD8uLggNePiAuX4xYUc46aqDRkdauEKDo2d7HKBoZyX9KQaxVqEbV9cAC+5
# DATA uKhZb2LQ8yKQV6qASAQPC+2CYrP9kti13H4SWR61Fe/aZ0jCqxSRvH32mOMh5/d3y5kK6ya/KqCaetsVKvh0gcUKlXs3o8LR0hH9
# DATA wa5UkqPD4YmhXOYNlQgh3RdodDlLgl7iVeT3dSDOWy0LdakCE09+RD92gsj/8+4X7/7+3W/e/+/vfvXuv2FeyC8wY+Tdf3/3m3f/
# DATA lRM/pGzm8vEYEYZVo1DW/aMT+fDj+JY+LXnWT25hwpO9N3gA9d3/9+63MPZfvf+7d/8oMPwDDP5r+PtL//1/hI//jSD5Bx/zUfx3
# DATA /wS//AMmqLz/PyhF5TcN/93//f6vsAX9+p8Bdmj2W/iJeoKvv37/tziv/5+yXH6NM3vqv/vV+7/Ggd/99/f/+d0/vf859PUvlCGj
# DATA hnz/tzIgps78J+rrV/Dp5+//z/d/8/6v3/9dA+jif8L6L1fxeEYifzrH62VJQ/yO73/sd9r9Qv2f1qDb+kP9n+/iHxYoWyNPtqTj
# DATA rW35a+3+IAw22qOoMxhtdtudzka/HQ277UEniINoONiM4PtG2O+Mgihsd6PNTn+z2+pF0WYritutzTXMf1wjp/GauqhnTe5TXDM3
# DATA 96xRNUX4AQYYbKicyTUDR3ew2RqMIqCGYBgFzTAa9TvRMG5uDoL+qN2CtzbDXq+z2YtGzUF3MOzEg2bc6sfDoNMH0Hpr6vYb6ldf
# DATA dVoGwmCzUwJAP45bQScI4nAYbQwHw40g2hjE0bDfbm+GrX5v2IqibtBq9VutFpayCqJ2txN0R2Ez7G9EG5ELgH3XXhkMG71BrwSI
# DATA eDAcdLtBG0bZGAw341Ev6PfDzaAdd7ohTDjqtnud4Wg4ioJwY3OjGQWb4UZnczPoDjvd1uawAERJwa8yYFoD2INlKIk2es1W3G8P
# DATA R7AonUF32I/6cb/T63a6I7xkKWoGo2YbcNbZbAEi2iPAVRy1Wp3OIB6FoQsNs5+LIV2xuQqSVq+UOjY7QBmbzU43BnIMer3hoNmN
# DATA NlodQFO7H7TC9kZnNGj3N4b9fhB1ejFgptvuA7UOBq3NMOq4kNA9dxcihFdA0t3slaGk2Wt1YPbtZnsj2NwIg07YCvpxt9/qD2BJ
# DATA eqN4c7PbB/y0h20ANezGw2YU9uPNZheWC+iqBJB8BQSb/VISicK4GQ7bm71ROArCzkbQC5sbfaCFwcaw2Rz0h61WPByFPdi2zWaw
# DATA 0dwAUg2bg8FwOBhs9sLCRgFVGUCg46LlUMBc+4MSMHrtqBeOOkB5o81BrxsNgW90BpvdKGxt9HvtURj3NoedDVifAZBs0IoB2H7Y
# DATA jNpAvu1er1kEI/vZMJiuoopuq9sugQFAGHWGw2HQ70HXzU3A/qjdHcDgreao2x1t9MJ4EAyag83N0Wg03Aw225uDje5GB1as2e63
# DATA XRjo9r0RaDk3YEevwkaz3WqWQDKMWuEmLPNgoxdHvaC3Odjc6G90hhsw7EYIf4B8WyHQyEYwGsAGCuNOq9kKIyBXkIC9zRJIcrC6
# DATA VkHRKd+vQ5j0xkYASwb0Pwj7MOtB3G8Oe512J96E3zu9jSGw0HZrCAgNNwJYtl6v22uH3Qj21mAFFBchMLNxerkCGqC0zVJKbfWH
# DATA o81Rrxc3gygeAt4HGxtD4JtRJ2wG/WF3M271esBDhlETSHUz3ugPus1+0BsOW2EQtwokQgr/hSRlJvPbVfu22ytjINFm1ALGELbg
# DATA f7A/u7A1u3GvG4zifm/Q7MUgzCKg5FYvHkRhFLVbG/Fmt9na6AzarXgzKsCiTONyEDba7VbZlmkDa2gPNzeBW8UgQWK88w34etDf
# DATA iFubm9FoMOwH3bg1iDojWKkmMP/NsDMAtr+5QVfCuTBw9dILkuercNEqoxLYDd0esLHNMOx1YiBbYO2tZrzRAuLpNLvdcNgLQRdo
# DATA 93ujZtxubow6GzHw9U44wJvoirzUNrtWCbsurG4pU2+jkI1h4DDod8Kg3QGa7UYBsMpBP4o3e7Bv+yDfu/1usNkBYdcHzhe3owhe
# DATA Clu91YBcmHssV6AGmEIZyW42W0EzDjY2WsGw2221N4DbtqJeC37Y7A3DFmAESHS4AfylBXpTOGr2wz6oIG3g70jF94AUpWhir+L1
# DATA sEXLdlB3s9kDdMTDEOi3H4EYbreCUQcYSQibuA9o2+w3+wAdSOp+CxgfQh13W4N2E/bRPUtlChiu4rntjc1uGUgByJ02qPGjcNCF
# DATA bdLtwfbo9vGuQ8AdyGfgQcEmLBhQMahSg3YnGAUgQ2AOwaDVvw+k2T3CsNNrNcv29QbQZbfTCYHVB71uE9aj2RuBpOvgXgZdIopR
# DATA CYg7oMOCxtDpgJo0bPY2QtBS4K12ywVnPl4pjLsb/TK20tocAFGAvAXZOmy1e0A2YRh2AA0glgbNcLQBGiQQyKgbteMANn8ELWHP
# DATA h8N+c9Ap0MtidHNxuQiyaBWnBXIoU9NGIF9Rfe+FsImC1gjmF4Em22+FLVCURiNYq40IeEncBs0dxA6woB5grAX7qtcs6iTsJFqH
# DATA tVitE/RAAy9TjjbDYNiJejBWCGQStYIecIz2qNfeDIB5dPoBYKU9BMJpgmLQAQqOQVUbRC0QkrBSisF5Aswa3+yExEhfr/niXaLC
# DATA RrvR6nfXvDvve3/490H2v1HA/w3u/+6Ddla0/0EV+YP9/29b//czrBURTH116CKThDcp/4ulg5LJZEEaR91PRyOqkcb05Icp3iN4
# DATA X91fvp5TfYuzbJqqL5c/S2bqM150M06G6muS/u7Fga8W82Ss6wMHGfop9Nd4MrO/c8lgzE843tk9xVsvyhxmFe/50dHp3jEmZ1S+
# DATA mX7fP957cbiz++rk9OKLvYOXe8cnF1+2voFme4fPqM33ffh0sarVzuHuF0fHdKM5uWrxhFg2XKt+Oqn9Obe8+OzV4bODvYuTL3aA
# DATA zW5X7FtAKj9Yq3nP9w/2TjAdpVLc4BXO8xRVFb/Zbomi07zsN0dNsC8vrhiLDd/RhizdHjlWnwqyRLe0bG/lwrctL2eggp67BOHM
# DATA Gnm1Drj0VKtjhJYSRwn+7ljHNCFLQvOdlktGiZ6QGHDOd8uUwt/FT4YftceqUvNe7Pzk4njnKywt33eLaNAjXHB41i48Kpwsi6q4
# DATA 2KquIVbmjuIQ4Kg6FTEkMkTP1RUnQ77cpE4ErsvUyW0lVqfyrmzbhhzxpQaYUa0uy5X3RXpfvI7Vbctb3sqidBWqNaX+U/10a906
# DATA /YDfzxrr5/ZPtY9rn1ZUjPTeMw5yf4EwL4FKF2fCfP0LvCEhVtd5SKImhn3mdHVktbKuDtFQ7sUo4SNi88UMNi/WGMfQCkZ4pfQi
# DATA 1iNKckAH1nPkyjHVFtcpqnn3VR9QZzcNNKp0Z6Oiu3bWkWHAO2kSPjqW2a/grb+I62GajqumU/jVmokulQ2kQptO0MkSYdsmMH6s
# DATA VpF3aIgpTVXmkTX/R37rvsV4pm/mk+UYpek8zswZJeG1WHRk6oTZ6Gtd2vtynlymKoMXyx5y20Y8jTh7B9jygznG++Z2pjII1UKR
# DATA OEym8vBsax1P9WD/5wwSPi8roYxgVfGhnVWEIuPZzumOX5EKivbGwIe7O7tf7Pm2HKANor532ne0F7DfWu0xJ+tfTeM3M743xJml
# DATA L1cVmfXAebHI0pVymAgos/DetX4hFzIaHUPGCqYhKBAuP+LlzPDy8FmV2ZD/CfMjoU8FsUOj8nYBQouUa2dNWZLqcK2yVjtrnWu2
# DATA SMWhNLvTCS33DAACBbopF9NrBG+zAty538XPMFzd3lWmTnKgqqdMgjfJZDHZVkzecMgHC24Wj5Yv4/8LxjaddsCKYZiTshgHGdV0
# DATA MGf8rUPnSI08QDqDda8A8dX8IMdmcTAxY9EVeNvyM51CqMpMoM+WQzskHIAryPNHwEu1zuZp6o8x08alkqKs09ctcJ2MahZYlyzg
# DATA 8PgDjN5pD/obj8GVdLQ0vszYOueGPevjzrGISdwTbytsxdId2iJs6ljF34ThKrpWxx1dVwqvnqm3zh/cV6+m+WI2o2xUtaMU3JXa
# DATA v76EZejUTM6/vawth8rRbtVoDrI+aEgWWnThuFvthTtmrDsle6zSU/RUVZ6S/YZrSwq3PlXIJVHU0U75hjR2P5hFucJWVKXmualy
# DATA SgXgUzlLaWPlSMTVMydE189hjeGn2e1fgoZf+0tROv+SNc5vQOWsydHRR4hDB7sIFNXMWZK1Fha5WIVGIqKM1BbZHHoHkHOJd8DD
# DATA dIE9mOoxHwq3ypl14cbkpCp3zLBgTnYu5w7nCq6m/0PfaYR0oBj2B8KBhfLMbsgXE3d4RwdkAlB1O5DCxEp4BB9j2lrFRXErWLKI
# DATA K8VLQhmwtbqUJZOyiY4cfIurv8UijE7P6+pMfFpHFzmjs+VygOdtudkjl41J2uNylR77DJDD4fU2vlOWhtxXVxUlkSZhVy4S9u30
# DATA oiv+stVCkgLrFLlqBvFnblFUEKh5Gb+6nw+4DhfEk8MQ/CjlImq4DyqOiBFW89G2FjgaE/efZ17W9vhi8RWsx+l5mQXpyy9tcUyt
# DATA +chKbanevNx/iZC79G4hd6lNeaWo1SSvrmac4H2lgDvrotMVxK+v21siG2Bf5jyHTP0eIjPFo/VLJcm3Sx3gJrJegU2gfFF11lhq
# DATA dXuDWk1p9FqxOIaUQjQwrKh/Zo50y0riHv34Y5m5gmELx7hbXn59DtEF3Tl+JynTnF5Pi121aEWtda3YXlWB6yOoovVPhnEUFbR+
# DATA S6ku2I1yZrxgOxYr8N1jRNZBfwUbwbboxBjGQSNy8FX4nks0t84GW+clBqFjBNI2WG3yOcqRGkaUC/mKzL+/qrjqaqGjcFcifX6W
# DATA yEl89tQ2hv2uWEUyZF2Tq5WvS/YBOnAbn8N/8Pgy7ft0+NPtJG18huu8f1TlvmullgOQVMFwUK6vouEgmvsjZN6eO818SewpFVDO
# DATA LNMsxDXMhk7JJHB4Pl2wXcm22AySDGwDywQxTK4gVXEQqFh+rC6xQXlAumLnIa52CnMAcXVbXMS84IjgTklEcvelLgd+BmajVPrV
# DATA LzakdK/2MponSvQy9rDGyJOKGaehK498803x58d5IPCa8SUSFTxWiiddULhYI5xbKI/fkK+eZsZNakxZ6oaOmwtt1m2LVjVLZ1XF
# DATA 52qruLt+zWHz6qqm5edapZpGcVYmU8IAhJRdDe8hkZIu5rMFnRswhFl7gIb5HUW6Nysot1QGyAnHh0RB0as1HaV80IiAOQ2yffil
# DATA uqzPYUOitzp/RAjVR4xY+NuOtlD3QRB0u/Cn7FgOZvfTkuP7dRtBrnSx+LbmdPxblRgZWmVZnOdVxhtuYFK5saICQbXd1BW1RWiw
# DATA oNBV23BRH7LPHnTdUS8fatXQS37BHhMwP+FIFHsOqSAKNm7I1JXrS7vYim+KiDNiCm/kZVSeJUDfb7bov8i1m81z1Q3bL/QAj0AF
# DATA 08sYveO2JKvjC249SUuaQ0cKCgyiKT2N65dzlEvsFGpv76VV3mrtqFamnbllQRes0B7KJ/pTAx0IXGCD9ZeaZicUuxP7x3m7UqLB
# DATA KTIpGDDanYL6ru7py73jk/2jQzUwV/ZosE/0Ma4+6VUKiXE0Q/1WYlZouVgw6ixr7oNMOBcTfHfQY4y4x7BC201sP1UkgjdrU6UN
# DATA dZ7JqQK6YoEdwiEyNGVVnFX/rjFFDidBjKzfY8nEtne1KxITaow3ckt1WnRLbq00dd2ax7rQsODjbWWpA83Exdbbcnj73b0CyHF9
# DATA 1e7urI1XtW57wEnW6R0MMap7nZD9TOfbbX2pu+J5Ug55yQWg1v+RLn7LXaB71t5+yybhU9uWAWQ9u5911JzXCE51IyS1VluE/QUi
# DATA Oy6YLbIUUz4bw6vEt7CCPynytoxN1blG0yPMX7qRjcscZVUDlXXHG8WZv3nTbHKky7RZUQfokSLQnFRTFyfpftkEvufqL9GUwD7u
# DATA 9eR0nzJwTTeAOGvdvYcK4yydADeNy0I6K+svPhoNl/E0VpfdeIVbV5d9Dvog9b3uBlV+0vU0qDOA+tyffRiw5Awgl+B6CSpWnF1z
# DATA oa0owIyQyAK64UulOJ8SR3LYpbdy1Q3Vwyz0JklKuMOe+pLDQFcwALyg68JSjaiI5tzkMBkSaZSULyquddX2Cd5fP070vdWkEGOu
# DATA UUAchsqBqSQkpEz8jGH5UfJmu9IQA28doyBJtm1toNpqyvodnTm65riBU+SRw4QU337Me9qJ0+267XVTU+1fbbl7SyekuT57r3oo
# DATA L9ohtCmkiXZPjB9Kb2qmJw3KTFNOo7f0rbG395P9E9gS8g1E+N6Ll6df391TYmXpyff9nSndtWQFv/H6ptliOE7yK9oGOcp6swfU
# DATA /aJXSV7S3SxLQ7BS8DA+lQ+Zw5aJF8AU+Eo/XwWXVGIHFn+QNL2y2f8uzOh+hgSUoo67l/AmrodCuC+7IPpfl1WV1sfAyWs6XF0g
# DATA wWlWRJN5IrdXmHtUPrI5ifW7Qq5+E+nZqSxjtv+jcS4+FOXdA9JAFiqZdiWVYDg5spFN5llsbSbb1+CqHis9GUIktOGd1x0Prp2m
# DATA RC/ocD2YlrXfS+GBdKZozS4dgNYB1VPDGEGlrvWuBwoGFGsY3NuYsPTo1hL8fXRzpKkPg4cXZLn5A6UNVDUDjUiqFkEINGRJ1pau
# DATA OyBq9Lj8Vca59a5jzC91Yhc84JIFSuulppImZBlouuoB66v8xdKIGSRWi2sPF8Jg2vxf5IxBMfX2u8//b7V67cFS/n+r/4f8/+/i
# DATA 39ra2nGMFar8fDGjC2viyKqMzDncUss6QKcAJoRG0DhEZWO0GNt3096T7k/p+h+QpL8Yij6jf7nVH9Hn6nnHey+PTvZPj473KdOd
# DATA DyRJCRj0N1xehVkjSZ+M0/kcTPon5gJbXSZm6afitU2r+1iuLOP0V/K42Pc4BQ2sDKrig5JbXLgzLnNz/1xVJZzlX4rD0O/Q853H
# DATA Ny4SUi18Xs3ns3zryZNL0EUWQ/SK6+GOC5O4cyZrwHxUFwzHnbf/YudzrD9YOAchfqSts+b6ZrA+4uSfmvdsb+fZwf4h5sBTDFcF
# DATA WmZpnlA1JX1rgsn+q/xxxblWbikabC67lnzpP65Q8FcVQi+2yqTZlm6mwIAdFowvsCR3lbcUppOnc8q4WL7pRZfwse41otcQXH7f
# DATA CifoNG2MAuFDLhi5H/FNjcW4g8KrFX0wXZAaavXIdxcwnA/chOPcuFq1ADmGRTgNLnNTQfSTpefPyJo2TbzlexStNx55PUOaXVLg
# DATA y1wr0eBO5CJLq/bwDXpPz2AKUqxt5N43yMUebVqiGnU2CzrTi7hUkBV97XJ5g9OFo9zzduQZmDsfZStandfO7QUFwIvFli8vqeib
# DATA jJSwU7oIvDVLOsjFm8Hcs3hX8KeQjEDTAc1SsppwJLoy2JqVH4zzlKmdLNBcXGLwexLkcd4o9LpznYI9GOSvsednVHwQPTfcAZ49
# DATA o/egI/+nmKHMv0fYcTweuZ2Vr2Dp3DiB3sWHPC3B3nlJcS1VwdLaOJhajydhknDeQDGH7ma88rlWsz1jYx37U5S1teIG0NK1L7v1
# DATA cyU8Z+bLuRtN45fUER5Ce/VjVILrJKYvWBUu5Pah1su3PnSaCKdmuM6t5PrXdZLSjUkK08U4QdW6BEd19cNtv1l05J5yaUvlMiCm
# DATA J9opaBpBREk0oNyD9h6Zu2TI8bFtaQ2NbDGtnklBSyzSh9M7r3MKmDh1w2A2xwugZbr8I0ZK1EcGZXsC6n6nWTeA15wsFDViPo+g
# DATA NeXhdB+fiCNUD0sCawzP0EEVR7me8ziZJHM3N9PKMC+ODSBZK8hL4raRVR8i3wfbiHNH1c17fN8WXzLqhGalGUdmzXRuk3gc8VEo
# DATA vI0A3tzi9znmK2NhLcILllrKpE+ofL2QXkXVWQy4sKIuZO6kSKmlZlm0dPncZZYu6P4ENTMYwr7yT72o786WscF0xLzH4gUyb982
# DATA iPbuMLH4Y+rcBcdZEd27e+Fh1Sq9yDU+pazu6zieCXB4+QEwU7Vv6DdLlyluIsRsu7mECwfFijitIS3bWhIac/eoAvmdrRecuOF9
# DATA mdy6P2aAD+YnvJT7CKyq6qoL5CQJ+wjt22KLK8epn6rsuJ0OrWFZfYmve4+0nYaOQrpMNcKDeqxPTUTLr9SsC9Q1J0cAcF23HoQ8
# DATA KoCtSVENYGhS9+5yZkq3KztuWCKDlnofl+82Vel0DpwzLOw9l+FZQ9JhPrTZ72NxOk9NjEmc+zBdTMnSdDyR0sDRe0s2thne0oL5
# DATA sDHeNweC8B6U8mZeiU+lY2xLTtHI0Yfrjk44/WDFXvmNi7v6R9t602+VleQ81jJTUASMBzdPtLVaOLIndhvsZmT9cZa53t4htHt9
# DATA bzjSNQNKuPiDl6B/39fibQTvI8rWMSLBtkwUj2O0aZ8CT/GpCG9dscMZECGlDkrtelfXW1rdbEJ1ePXS1Ao6Gy/pJ9t+63FBSkuP
# DATA ONEfy8KWsjysppg1kVmH6WLM1+ehE358qxTbZL5qcbi/UWUXFxVAfiuw39neGW0qCzE81dWD6dZ0xWALlFKpfRvX+gcX4bVNog8p
# DATA 6MuyB+OafBXTtrJcV7RHVmuV52UF2Hpd2ZAP+LKVpHbL4opLWN3VRl9IZv+v5xzWRRp+j2M8UP+lPWh1XP9vc9Ab/KH+63fl//1S
# DATA oqo6H1A4h1zkxU5Xsf1RYQELnRncff7eQt2We92/df8l2GEvweR+s8IbbPl+pV6LXX+CDzqT2ipnudjrsF0sQ2ElRvO9a6Tp3n+Q
# DATA mRKTrhbT1+R7mwNPHAeTYRRsOUcULGuvhjUyihFahkgpgtSfe+SIn5dUyFAhbw5VzYNL4Ec52D5K+ZHLm2k+JkpmpbNbWj41eKIK
# DATA s/BlIMuK/hgWt/Q9zR/X2Umxugsrm1Wu1uQkQ64IQCcInMdCefwc5nifOvnuv7z7Jdf2VoW8/wH+/Pb9z9//9bt/Fspcf/ebd3+P
# DATA V9i/+ycsBK4reQj8uXXQr3AFtVz+aZ+pM8/kfOojyszfPTgDqjUuM6DS41iA/DcPzIASp0k7fRucVSit+3zLD4hIAyRQJg2eE382
# DATA FwkFshR0BSffJLSY4QKDcmCu6rOEoORETy3ELacHzRJ0vCHNnDE+3HvKcRT+mZwRgjvHh8kBW4JNnwanC2WSqZ0FnWZ2S7zRIZlb
# DATA DeWHB88Cvvu/FF65njth/Tfv/4ZICiu5wycs//7+b6gm/Pv/BI//kcrP/zO89C98ZLCkgL4QiwUiHUNASwCYm7pTlgkomET9LhJO
# DATA kE3gw92DMP8XLDz/GyTyd38PVIOw/IbL4mNZeqAUqzA91rt/988wlZ/D979dCS+RDEBYN5EFgv2sAPd5eUaYXHc2sgJLb/Uod+tv
# DATA YRPfrYM9sniz/hY7vGsA525c/qxSSMeaKRfG6J4gltXz1luGUhf+O1eD8TCVJSvGhA3o4jxaAnUyyXrIxoRzvvcxWZY2N4KFgGX4
# DATA 1bt/ef93Jbv4F5Va2bmrFXeuPxIdfyzRsApfzV48EW+mpy/cZAfGh06NGe0v3v0jfPnl+7/28Q9+ADKD2d3Lsx5/7MWF2FQBwNvS
# DATA yisAqFjgyk7oo4qEffCsYUv9nU977dc0Ub4dgn+Guf/83b/A//3iEWtNrJgudyH+TbBxSqaSNcaixFRP2g8l0dK3zNPP1kz8AjbA
# DATA k//B3tt2x5FcZ4L6jF+RpOY4K9lVBYBvLRVZ1KBJdDcsEuAAoLpbIFyTqEoAJRaqSpVVBCEI58iWvR4fa8ee2f0wu+fMzvrsft1z
# DATA 5LZktyW1dM7+AvIvzC/ZuC8RcSMyMqsAsluetTSeJiozMt7j3hv35bnMPvPl3uh0CBR9GY/EcuEw4Oc0MweT0am6EnX0J53ZZMDk
# DATA lLrwnjkl4iuSTqicnn0gMDjPZQHZixFi5Ii/YEL8k9f/qP7+T6+/jNQM/xLTj/wCs4DATvzN6y+ij/rTj2cHfgB3uZ5SjIFiXBGR
# DATA K5EIDlhkj14jgoMGU7tx49aVzgtvBhjATyo2CYuAWiDR4SpqTbvTotjnJPQBkpe0fImvQmZcEvmtjFNrBT8KjPK/IUP8BS8S5VTh
# DATA HCiRWig6I+rMRFiroocR1eqGUuju7knRa983ohJrapdwpj34zSlw+YBBwrdaQR7a07LQPo5dS04gnPDGRdaw76zH+Y0b+NKJiuGO
# DATA GKkEM7Ci4GHeaUHEi4eRfVeFifXGcOhaeucFjyQ0gVuy5W5QDWyBFi3ODlWjf5gC8sYYoGmcciuql1p8qragm9BF8Y0zAkJhoMlz
# DATA XuxzflDz2ShncoHSQFy5t/62KMIo+irPjEMrSDZTxUGKg/1IKX9+KrDJcFRz3AEcqZPH5MidC9UCerdCNUWpNDDq/4y9/lM1kL8B
# DATA 8UHJd0XRUz36XJGVnyIf+sKbEhBf1Vdv/lIcRXjoXI2Q3hjYxf7hWYfjZBloTO6ZfuBqLUa1CIrJzsdrDVUoRPeE4P25Wkki7YrI
# DATA x2WBy9TBeNJS8uM7DrNH6wX6XMxOaicU624ys4py3yrjBeW7+PXnwcGrccNa/QeUK34TQaYtIJnqwW9f/7OQG4BG5Y6dc8GAfhbN
# DATA HZ1KTUTGF1klOJr38056kI8Gsyk7o8fNJrpH4VsAusxLYvk1D60ZCAEMCxA4ARpUYHEBTF1oUIhUu0PNF4ufv8Pt/7MoOLG/jIPj
# DATA 0iPIF2oaeNvnwMQg/5g6Sn8FGdDoOF2qcWwRdNZejDvY58iJIgRNEBudhJenlcUZ/fVoUtzlhY81bEPQD6F85hXRcCqaI9zqso45
# DATA ucYdLZ47XbqoB8oBhNF3F1OF9pjk0PVsf/8Shw8JjJFTgBr+ApjD63+AgyYoqKG5X8KNBo+lFmFKLzTE4JA6luFMiIHZdNqFNZUV
# DATA Bde1pJ6rLy/fZ/5cjfofiMG++Z/U31/MWWkL6SS6LFE0tFOluBV46lcdIibVnIKr6Lva/DX+L7CscCdTy/rnpJmhQ3sFboNjkzKU
# DATA 0HvaEGViji77ZJtyjf8Fe6/kod+MHg6UxNbvWiMoaLBzdKGjtpjJ3rPOED2nlJHpWT1Mou5gMDolHaA/cXU9lea2v298Utl1dXX/
# DATA wrHl677bE2ke4YZDbwW+KHDLC7gzYVbGf8DT9k9wusqOnhbUwBOi7bS8VFiXc1+EJneKNUf4VFLCKDfvtnKW0PHQ6Kf6DF2ElzVP
# DATA X2a9Gin33RW9fv36Q+gRro0657N0gJS+x/cU9pIfatvG9DgFjQVHt5HjoqWuYDxxeYIBn+JcrxaPqCgL4PHXTgrlUC96GIxS9OMK
# DATA rBcrVRRe/0GqMO5TMO3vtSU0UqXUoVG68Af6eViBkwj4t95SyWDzkcpT94+YCxU0kurILaCgKhNYLgMQVcqKSv1DwEwkVhxsBa4U
# DATA U6zHnhYrblTAPPmJ490WLe53zFJTxLHStDX3WjdRSVCLDwajA0qEQFefEg8YYpALwk55M3FZxtmexzhdWaUAjsWVLoUFTNi0Wowz
# DATA rIEfXFpU+72Iab7AQvd3fwjMDKzd0sTIk1tz5SDK5ZDLHMU5AsolhJOvN4M3+d44UbRa84gnBRWYpFUkxDbHDy9GPvsuw2un6VG1
# DATA z5AxiC5Wn9Wxx7+PXOSuuq2qpPaDW2xYqOpctLD2Db1qGnQd8Evfk7Y5sEmExpkWyfU/oCrItB30S9ZqXrFkhP8HocPmWSEfO/cK
# DATA jorpVCsMjuKnUC8o1cPJ2MmhTyASsVq/ojo/Rzv/lttBO+S67WlluT9xWj0ZmLeQ26c/M/r0FpmLp0bED2F3GYpU4L1+3UQDSmtm
# DATA UZycJPvD5sEMUFtKqs+z0nr0Tc2fGXOF1RNTqDqUz15D2NQloCF5h5YAijB7xTbxRBV7ShsFUJHw+2SO9y4xo52zXN1o1l+p+93q
# DATA FX0OnWxGvw//PyUuvn/L8/9bXbn9h/zvX5v/3+4kHeZ0KNWFlnJgKUYG8T85xziANiGbqBusDfZWdAok59FsSmURV0QVAZ/xdJAv
# DATA nvqtOxqfvX1St/6R6rz5NU2ni0eS61RvkwGI3IQ84z4DN2awzGJ/+BmOKLLlUM1Sh79mQ/zbTSEHB5nysgwVo5xCYBUcdrxFd1CX
# DATA pmQtiwbDsDGKVOuhUso2MSov2xmQHvzDjG3AExjO3RaZ6T9RNEDHKijuDaujZMkuKK+iJ4Y8kMxr6aDViaxFvX56NBwpwbpLOg8l
# DATA OyPszHQU5cejU7NRkMjhRkFpdsY9oQAy3DFs+1Yfk+UJX9Wj0Zh2pxOTyACOOIWU40veZXQSHFf9QN+0rftnkzINmZeVKHP+bCyi
# DATA VQBvkT9l75F/BkOem+pEj4yyIcxN3lPswf+tLgv/DBq2QkNoAgQ3FdetLZjWR6cT0nBHNmbZ7Y+ZJjhiiCjZKegxbr5dryvtY9Y+
# DATA Cm4VpM/+0ne7UNex179znSugzwYqVt3App0UASyk1zAfCJOXT24ym7yvA5uzZt2H65GNbWCcYzFB5JqhPkZI83Ta3OlsPNl6tF4j
# DATA pONpB95Zn1ko+EfRykixxXJoenBq468VaYGb9wjvtpn6tciO+d/xlvpzNY/qSkr3zl+hj81vQYf0O7Avw7Koa+iv1cwW7uS/efNT
# DATA sr/D7fufyA8RDfa/fvMfYxcIssNzzVdVnm3HySKGR3HL7keAA6VYkFZE8M8x6lX5Z/RjmJ7VVUzQ+FLdtUCty7OhHuAVk+Am9FP1
# DATA 208CEu5Xy+pS1YTmXXUE+twplOuGU4gH9wCyZ6BTEa6ymXqC2t4alw9DYXNWAdgjhyNQq2uikzOJK8iP2JCrQOT9tPN487vufjK6
# DATA U1Nke/2jYhHz9tHGdsXbna2HXv2lGtfFCSRsO6RKP4dN9yu5JclGLjZl2JGwon9EveQjOlXvv08GjtLDc4mB/Z3a76Tc+Xsc0i+j
# DATA N39ORA1ccqsHpI4Ten//I/vv6omAjxSlQ3szKJB+BR686hG5vNVEA3dXlADhtfJFBPk7jJNHOh4PzjoutaN/IC4LL/IOO9WXFCzS
# DATA KskbgnLECHRIo5wsDVR+j87xfh2eb3W2H21tPv5MnVX8pbbX+sPdrW3zYHPrw63Hj7c+YTBVeQnl86GKHeLpsG06Vsaac+bFUUdN
# DATA pOkUk4j9eqSfEHXYd3Z4kSBri5epiEmSqIiIUjjN1GVp7hfkJYiuPr9mdwPYFUCA2dcJSC8VFzKE41aLKxrWXhToXWhWYcoJm8++
# DATA tcPVE0AIDtgWefT787EUxFVUlXcHSrp0WuYYHnOlYH9FofkAgbbT70kQ90J0QVGvJnYTGRYpHTCpXrIeN8N1OzNpo72hjXSI7lze
# DATA CjOGBsMza0vrMur7yIpQ19I6mSeqiiaUUslGU7ig5OaTwiBzgIOu8RgAgDbgM+JIdMFRkGOV01tmwl6vVIdD3RIjWSpUrV4V6lbP
# DATA ZOXOYuoz56lOF5Bo/rOikH+PEiC6Duq24XMtMBZ3SSLlO3vj8MeI82w7aWea7bAQTQNTU5hDE0IEJWhTzYYa67UXGwqUeRFIZEwx
# DATA PxeR55RQhlTiS7JGRIoxgQ3h1+RAbc0myFXQdf8f0MEQfQlR9MZYkqLIXKce1sEZlv+KAaWZ5C58sheDvmCHHxq3VMZc7hyra6G+
# DATA xZl4WiAVLtcRntpcWM19UpCB8R0+VPdswL3gezd9hFa01jLloKEnFHSkPenh4uPeFFUFTegi2h/VtFMXK9rlb2ZqFrSVGn6P1WX5
# DATA dDTpmd/qJjF/5f7WxlP8qVSeuKYuZBxfwooqceDPyAOeGMRPkCP8JsKFVIIIxy2BqP7mL9Hk9M/lF1ADMmZVFrUa9B1j9fQy1Xl4
# DATA sBfgrx/OMkB6hT8PJ+nRiU2j4oALlS0F4xVpnDRVgL1SNFYMBkh2suHLGqhkOXm3BKh5kZ3xU1N1KCotnarOQ2TaJP6T2nda2StY
# DATA kb3o+XT/veQ7sA9sqI2qkaNn4PWNdvPGv4klGYV02RkouWtcK6EEgRTVfOLRVXhBgHWQJMCUp5DRqNOC7gMNaZutqCs7HKRHeRur
# DATA rLAncP3wj86ErBMhY3aV94oN8CsHald9zhM+noxenZH6m/rhHNJ69KI/7LXjbtrrncVW72Lmtvad+9dEWtFmYz9xJ5eqo/mtfadQ
# DATA li2coGsEjyaUR1nWNDSk5idwH46GiJamP1xy0bBAgpgN7TIMQ+vAw+MlMJO/IZ3CdK/0X+jYDjU/EAmHXEwt3jIwaxT6eNQfOj7v
# DATA +tDxDoFJOUn+pPY8v4Ho9xM03z7P30tqe39yT+3V2r2kAB0pvCFoPJzMEP9RZwkXgKaOHt1EzD36+9Y+7biQBUmJYsgNV4TD6lAC
# DATA svi5zXEfCqQYAEkAnwrCeygCBpI9njLdEQn4poOoKE4d90V1Bm9z8XlMkahUCTziv3VN57qmYjYcN7gK8D0OKchK9oS+DzicDJG/
# DATA 84RSFXjezlGPhlW5sd7Y8/eMh0UTNw00kEQN/+GFd7nFedR4bpitvbh3ZHbB3NEm8k6dz3n+DpgK3C6BQ/wCBYhfgqyAQsKXeM38
# DATA BT35HKSJ36GvwudKovgb9fQ3yHQmGcRIZERB7slLDF5k4BJDoRqoUDJv3vx1XA5GZ9JtAqBOPRJqmYKcRizJKIatEg4IYNvqk8yR
# DATA VI9ZwoTKTW6hQsryQn6fonIUWZnRx2H3ZJV7qq19RE81mqxCZjHMBa7TzGMT2HwhARX8VX7+ObbohDRenmLW6D3ef//98gYQiP1C
# DATA rojqvc6s2evrCBCzHkw9WnKuA6u2FJ4Vc09kJqYbGr5E2DGwj6MgWbfZOGwivBn7QGIJkprhQw7rReDQKpmyCFFm6tyjvxxY1z27
# DATA 11DbazsENwL8QGs9PFgxZiqEK4aTTByMYDc92UVLPtokgsJPfzIa4o2YZlTdG6aUjTsPSEQlYQ48TyDgqc/NxO9pAR6WBH3BhO5F
# DATA Ezu+zGiTkOyRP/36RSzcCnApUctZWFbqC8hr0BWblWffDXFZTMoTRxvAOaj7rPvEdgNZG7CQPqFWrveuzYEvvxntHmeK4+bTSO86
# DATA OE3pbHo8mvTVqeu/zDjwcJidQqfusThL2YTI7jUGQNbpaFTMuXGozVP9YVkXUJMy6R8h/mrbPV64IEKLbgL7aN3rgq75XiCB8QPj
# DATA xU7sNVb3CTBVC8FlAjUJnkaKVi3qrgYlZcd5I0hnxF3A1nSummnRul24wIR2+cu3qCR/bnf4mz2n/D46pUO1+pCCTQB7BQSd8QPN
# DATA QzcPukAfjfkgEcieYpg/ULu+gUGoVkPCj1EAZKhAfqQOhxdMaiuxJ6jO7u3iTEFzh3Gdk23pXmqKA75ecBx50mkweKfngcAYo7Zj
# DATA GMaOJcJJ3fU3YmNyDYrqsbK/WXwjtq74Gmywr2ShyXg0YG8wfKYWoIF28Bm7FzrAnFL3or3iA6iHe5wgXKsl6tENoWsB1Xi/i8Zn
# DATA xkdx36Pj7o4mk1hg32sTSWeR/EoHcBqrpLf7RmWEaHjGvb+CimtoN63E1K5MEJ2MCyb0MfCpgBPQ7expj9+D0WhQk1hx/DcNemdK
# DATA q2AIByfc0rMNWwWFGiTerUg3j5+10I1DyTPZGP6o0TaStjwdmmysee4H9Nrf5xPuQssMxg445xHnF0LWgE4CMWQBGn5arE5NXWlv
# DATA 8Lb+0BcDPWkGeX/hZIEMYOWchT9hktDgtptnJ4O42L9aRQWY9rE5fQWHgYzQOG50lPVLJIWcsxUeDoFxFKy1MJ1Gb5CBi0pRZa+1
# DATA aa7yvg7uKJ2TTPFK/QCs6Sijyt/AVPh3f4ggofIROaspTjHJTtPBQN4yjRLPSi/kyVTTb2xOvrMxhufJqgxngDMCPKRGmVCdQnzr
# DATA 1Krga+3FNdT/h7pv/Qos5G/+ku08v3TuVebOZNqCWxnq7VQpUOW52ApgnKcbFsTB/7X1KbHT7Ij6aBANdB1zVdlPjAoeNKZAbrXk
# DATA grR7MJr1DgcpwjTGR10418mCPjK/IPQiVGYCQI5Bvfot2sL+Ptp9vFMyKLX/R5Oe0USzSWcBq5HVwOudtvCU2C/MjADkfD7NUjRM
# DATA gKDfSwfqy7ebgZ+QgwWocP8ULt1wK/fHr71HTJdcuwH0eUe9e6LdzE0/k7C9jAYJo19wgIuND67/n7O6+suq0X1eVEn//M1f+KNG
# DATA lT2efXGi4WfN0AmztPTDv9gG5ugpJdS6ffsW87RXk/Qs2IgkPiRcyt9zmtqgwtzat2xz89YCzZl25vEFBOKcuxNAZpd03McWQHix
# DATA s1W3Y7pAQ9Kt+cv338iU8Oavo7WnG3VnsQB2gnEofh59qmouuC5Y5Al2XeAFzI/TCWlP51hr2VkjZHlFQuzIMwFjGdRKFkOsSZQS
# DATA OV8xWspnqH55LW6L0lYCt9QEB1awMVuBzA6ghb5hJJ+MBjAZNWOxcoxSdvTEtBivypqmFrB6Gw/C4FQueb7y1nQmJkBW+myCQOF7
# DATA sRr73sr+5fpSaE3OMqzVIxpmsS5eSbLbwfHgkonrNakm02XGFXNSNUBB3GiB3GnZK36x70xGdacMT5l/Bv+LxXsJK2UrLbfN6PXf
# DATA IVX9S/Qx+TmYB3+JxSlYjszi2qoIeIFf4qf0nLnSz/nhrwyADk2JJ0+ph6ivhJe0TLGeBSuEtc1suAKJ4bwOTw4F2hWn6P/B2Lo/
# DATA k1NDHliIlmNdEskKKkjRQdp9MRsL/wV6QC4UfOIaDkzinIy+9D0njta5ocEjSyaRtipQvDWhhE5+jgjTqrUCSMVaUnyJ1dSpJ+q/
# DATA 4ORI279l5eqSNOsXmOQLRCXzky5DLXV9VT/GxwCw2lJ/kOSOmHg0EO4W/UguBIJrhfTrsq+giCVTIRAoecfya5+rV3Nrz5HCEXqS
# DATA At8kxba1F6r7vNOyEC601+2cKvqHoTFca3t1e8FfeDWDlx/yHMaeWaBYp7ggu1XTsmSHh4odgaaxza4nDgW9FqaCnGyiyF9xlOem
# DATA 0w4L0zszDqa6k04fGlhBaFtcFYvagl4JgY7maVtUWTY3o1q96i78EIqR9t+zzewxygXrLIKaLjOVCWNGc+U6pKDYpk678grK4B5s
# DATA kH23GvKWRjNPAKR6WRov1djbDWZQJepRRxymw0mWH9d00Knpfd2XZ+oVVgF/rUxIN7lUdYgmtd2LtZ7ucJU4Otj8ptuB1wJVCEGF
# DATA F++h/RKsqgTv3B8282zK+QBqMWeSIG2eC3yBNn1An8CPW+Hs7/iSThA9ixPP7IMlHLMPfWOSAoKfCznGxKY5h4UW0m/jHll+mU6W
# DATA B/0DiwC7rJhqvLir8v9lLleGYRJ068/IE/XvKTzExKkbn1NfY6Eu6UrS+K/y9kaCxS8xtl3KLJ9rJyT13/8oAaNwjrV+7jwGZQwQ
# DATA mYM+pm+IOTUfcSR7JtVp72YTSBCoyvD8t0qnBllh2utA5nMthAtgNVAmD/o/ynods132eBNUL2i1HdYbDLEW3AAizd+yprq8IZ0x
# DATA F/bLyr4cbmA7XVR3KbC9q8YISCxib+6LLIzgPywmyqm4OKFm6O55KdnNina5iOBw5+UmLfgEPzDIDTjZ1lPb7CCeVxME4X+nkz/i
# DATA 5dK+3KMKEe+DF1BfqJAdyJJchboHOAFmC/qC/1ffxwJjIf4CVYFfgsumvgL8qtJpnI/0PfKw+C1jX/6MJHryCyyZaye51qszewrm
# DATA 0e89Q0X3g1Xs3SRgEccSYOYt8bZTR/t0BGbWgVUPrxGvs+dkVGIuQbOVgDa1nAaTSpmNvRfvcA/cLe5YSp7gYC2wvtjqjzJQl1J6
# DATA +cr9zkof8yE3mxT8oAg3D3tJZ+FSsTfGFRiVyT9z9grc/oAFsA9peHv5+EfOynG/pPeW6rE4LpxLzghnakqLb8vtESxAY+E1jDNA
# DATA AdqNaZF1+ZJIr5f1nsIGxe+AD3glyHqlNpYrhELpvTkWwXokpJb+4aUFuJJV25ZuVQwN4zlgabDl/5lUyd79HUErMXayqBX4chHW
# DATA /QWj6bqwNqTr+wXG+QEG+m+tfjkw8tCA/TdaCMDPHVM+lGRLrV1Bb29QbdpAKCRM7wXWU7ifeEF2RUfby9hdsWkPx720e29vhEUp
# DATA nrc0/mXvJfpgSsGpRk6oTbCwzrmpiAvVvOtKLbxGrvFE6AKKtsiSClCbYL38zKicLDNACPWNB0en8ZFQaVKtS7iCKsEbwLxgjAK4
# DATA pjqsm9BL30ny556cfA9OHgeC8el885+Mqz/o253iRqH3OVJ3qcPTij3fc5MT5qAu8QuUNyQOpvZeD82stesuqj3BWQt4GXMrwvN8
# DATA 7nrXSRtm+xAvfvHmLvguRqYh6Q5NLke9ohCD7gzhM0Eaa0HmqI49R9ENZ9XRGTvuh+fxh9tbm7ud9c1HnUdbT9Y2NuEWIQ0EYuRP
# DATA 1zbXH9ti+o2Va0CFTbmwRQiOeuhNInkjQhwNpE6tNgJ4WcehBY8a60EX9eWsVPflGuzltfai2nl3zpSY9uyDztNnHzzeeKinQjeE
# DATA HuDF+BIXDa/Kz3JvSA45Zl72XG0W3uGHqGtDme40fZk1AuhexlVzyeAfBfZqYOMIs0dw33BBnU1MUrA2hcxLsteWxkHPPNk2xsKk
# DATA 2I2iSOTITKWC0aU5uW5wdDrMek6DIc8uKZa5X9TDy5XUHWXdfiIWZE7A55WPUugg7C9d4bR8ndv1PHCqWhVn6sJdat6VhaP8REPO
# DATA lC58uDT4B5ecAlw7snZY6FARjNpaevs25i/UV0FhXVZp2i/rJHt/sd1nfw/NS/grwa1E34ec1LjUUuEupMkKedrqHqDDNHtmiyjd
# DATA R8ZcLYiWB3ZIpFw4anOdFyZVodp/vY6gjcYMXHZCicGbL6geMjK2I2lLIm2gkaapDHQQHZyqxYd0Nh3Fvpf025tbZL2lDlsyswUP
# DATA yxY0BjrPaQsr1mNbxHkLVWClHinccFv3+Mp+QAU/r8/d/GG/vFcCSm9iiDyxOba2Vb1bUZ5r43+F2aPtaJEVI2APRPoHpUAwh7R9
# DATA 40gR3DebQCpsRVN5k7drDr2ThyGZs20NeahsZkfsq7wd1znmq5TKWkKSWOOtc6pK/WRkNU8pCx5bJYo9VLvwoa6yXWgE3TzxDtvm
# DATA jnpuM9h09RhkFC9St7JJQWroT0yIVCdehbqPZI29cYM/9cgWzoT04JFe2rUY0tB1j8HKNM4g/bjaPf2XisDhz6TUnThg0lB/Of6p
# DATA Czv6+J5I5H3QKcOQCIE10CdF/AJTEUe/md9VQXCmJBk0U6vWKBEHuBzqVzD2fXrGbZfy64QiU9DB09PYUOxjxwzJvcIxoF7FJ1eU
# DATA EeZVdDVxoWz2QjeyMkFALuO+jWPmXlZ7ftsv/YvbAmO91l6g/4HwXGrVOtTRA1fXxq16oBOBqN0XeI/3TP+iCf0jWQoDpodlbqrY
# DATA lbp1n64mds8J7rTWxZBwPn8xKkX3b0aPMZCeECRnOWf5JgCVOI/GswM1oujZ9uOIYMooeQnHwxMsjJrhSZbnzcW0IxTnAFn1JtmA
# DATA kmIMmQTw5iX3qNJgP/5sDkpPacqBMr0uV+uBCg97Y8VbJH2UO0LXhWYlra9df7K59sna99Y7pKdRU0fOnCH9By6LbiRxgEgUZVhw
# DATA RGVbnUeE2C3m70t79vCX1c49xUL7njp8oSMVqAYupaEpbbkAM3oOfYrqJ1cFvkHb7JIgSyGEJcPyTKUlYEtBAms+KtKfMC23H+wX
# DATA +bVXGzIS8H0y0e4cGGU79k1IZYABgTaAMUdMh+OsP7FhpiwUE27BqynjgyjOfcZ0wEaymnrAzEE+l2B+MI8bBnjUidXCpLgUqpWE
# DATA 5lkP9XSiaIKNY/Q8mGSmKgpC9II1ZeSxDNqcG6dIGPgcjOL0xQwyxqsIg3/B307YVKiYgUkiRH2GKM5y3h96+h2EvgVWlXmnHCv6
# DATA 6urVJNdvo5Sj9JTqzG1MUYiV3yV+JHk47NG36mnzjonZJZG/3Nhj9DdCR5e4cCNsRkPBGyeEQVeLGYrCfTQDYI2kbx4kzTpNNdzC
# DATA +e1+KLVPHiLLvOEKgbLghDs2IazdrKEO6SST0a69bJybHwez/qDHQcLqeoFqFTAHVyDA3KjtxY0e4/LxNJELJFWJvkeoA71BOYhc
# DATA +FJvggrctmy2gtIbMfG0d1YVnaqzG7Nrq/YurqESulUEhLT43U3VjdoeAGlnr7LubJoeDDDIeCMOYmmDvxUFU+POMi01x2rnJZhV
# DATA V68DasgbY7IRIoGCzgCVgNwr6M1dR6zw0WzavrWywgpkyg0gOrhj/lx3kwBcxkND2ujJQ0OGAkavfxV9vLv7dKehw3Te/DToAmQD
# DATA Cb/QGCwE1MvORf+IahZwQ/q1OogIFI6XOaZLStoDsiWRcdmVvRzpjmgSOZrv0y0ZjsQgo3mGOrNeA6ql+zL7oSdBsFGuT6fstj7U
# DATA ayB8uJ8FdlPA9dqCWC7MJBe0YEjGJ4Jy2bsenZXfng1ejbVNTmiLKzYjCVHs2kQkVRj0MEcQjsPnFB/QiCg6ycFj5e+WDdYB5pnJ
# DATA mzTlOidpANdcclXNDbkKrjRxtC8CFsTFvyhcGIzrrjUvUwUB0CAeBqO6WLDTPAAVQfU2Z0N0WTrp53Bt6oxeeNUVfUpc4YGqqQto
# DATA IEYD8jphUYLqun8nhGFLCXgCML/i4EjfqcQC/9quzpVA3FgWe77b7okOiEdkXSdxiMm+2oUdVNIuTlgKreKIgR3NaVIEADgnTbur
# DATA lbA3bo9cbBKjbJtHB4JCgCNPYVgtnkK3CYnXzAMQKk8OfX+RnUkU3EvSYgutKoJ/zDwuEr/OAWVaLa/9yP8JnUuA6/wHRzX/1Z9W
# DATA e5EvYGvxAZUYXi7UFheoVmXqBq61fbKwqJtvIR+Dg/OMcXw/m4f03IxkUmrt18NeQoDEbxz3HLPIlQ+MI3tdhra4yMPYBba2oT6Q
# DATA bEgeIfWzT7GBoQkK28447WsWWbC+IJuzD+uEF0WFHfybeRYET99DEp1NclKSz6l82W0CJ5apKJ2M75PPoVvDaM+3SCg53bv+N8mL
# DATA pJYE0juyvX/KGuZzPeUtbwXqkZwDjq5ADi8eJ03hyq6+UHMqSwJMqixxUbhJLH7YdcpLursbiK/ALDubVTRi7v1Bpqh7hTJV3Uh5
# DATA NjmDwxCSkmuPhqq7pi/UYQJQFJuC4h+LRVr4w64FQLiopkJsaTJnaqz8RYY9KXfVXQP/Zat6uzqMNOrWU9DauI6zjri5z3iOUhws
# DATA b9qnaKGSVL0nZxZGXDEIegVyMP1/xVcRv7UzyQaZIrweswoNTmtdtBHSkeFddKKWy+iD3U18RKOLIMIcaz/NES2SmVYZLhzrOEPQ
# DATA CqWofig+yQ8djAX3M2N+LweKo5r8kRqFlzexfrlgtZQQCxXosp8lFsuyuTG1oOcE/7jCVLmfvt1k6bre2XTNP2dV4nYZotyC2siA
# DATA fGHc4Nva17cVvC0zGh2E3eANWN+JHfUbZuRBIwLqf7E6+YfMWgo5X7V+eDmbdpex1LJ1n8cyaS8dTxn/z3OsD98PF9Q2lOaqcpSh
# DATA JmEVpxzAHzXBnmRks5GdWLpK3tU8knrBVTZAsWns4BoHbqCF9S5qguJkXry91hUVon8WZxuL6pYKDM1KRUba80luUC4KiTzC/3xB
# DATA zVWhps4gPRvNMIDF4eRFXrPggSzwm1LWHryQwLIsLbYULJZ/oL5fxz8VKRZXVkdV6d5kTYoZQ8sXyjHzlpBjJrdZGcCHPXqtIGin
# DATA tyAhvEIPBsTAhBSQhJKFXIreDUgP6gW9nqm7yRN9KVnEMZN8DeuMbPIkHcs7yDxMxMRkeqPEv6jYJ3LSWkQfxNdFs2z7nk9kSF/k
# DATA 6FFbxS2dKkETqbHtjLzwJRXKb8virhkWp8Oag11x8jR4deokPuEx0pKK1CpO+InLHdSDWrycjvvLAH68TNCcMdnCoQ3aF8saRGgM
# DATA kA/k1y6SqTbR2NWhtzXvHfK9j9WMD9S7cw3028vSHiNU49SejNREjIb9bg0U5qs3Ca7l9BiQmQsF7pvPW+Xpryn5H3aJspuhl5a2
# DATA /NzBPICKXamZC2WbFoFt/sq4wpvxbygRtsWqFZwN1ASHPzoY9c5cNF7dU9SE1SA5J+fohNkqx3/2sNOhXgEQEHhLe0+3Boe3qvSe
# DATA Lcm7tp8/HqnjswYORmDYqWOQZAVeNOlerJoGtW2gJEPL1s9NVh1yHta5QX8K+UZ/S0gXEM/6O4yW+yVo4gKCvbcGzINkkuAm2OGq
# DATA 1ESEGE7oCEr0nWTFLFToWqUYoyoVQU6hOI+ePdt41PTlQk7Fiv5Wig5R+10Ovbu9cjupIguLb77woGtbO5zwXKZBd6ZCDUNmBbY2
# DATA 4dyGsuCRzAdZNq7dZEYZVp2ifTPiSMbfevHJFMaslaW8mj95/Y/q7//0+ks2hQLuJEGWhNLiFsMlf20yU2gwfjJbvoX585qQc+br
# DATA 1/9XG379yzd/BUGffu4MGF0c0NEWOV253GWssV+b4NXPx4ARUEsnR7nN+AW/gL5y/ue21lHHnuoZP2uSPQr/dHS++AS0kjYkKFCx
# DATA 7mUc6LipvroKM22OtYc2yIJVgOGnQcxcmK2tNUxUQzOHUHsm98kkRw6qE6k31yZHM9g+T/FNTci37U6nN+p2Oon4sgmegSl/UotN
# DATA z2JwcBiB30d7T1uGjGFIw9ZL67023YvRYMLdw5FBxwo1qG6KAH5XR+Tl9lPKOag4vRLjetK8GP7WSipOd50cgfWQUFvdJSWBNYzU
# DATA aetdNHamunK4HDZOqGe27jKE3QXqQt+U5F5ZGYan5WJVtam7ur7IxpDdE/dMTBfwqVoKz36nQ72OskYfxXOLTwq7NfYMC2w1cBKx
# DATA BbsBQqUNeoDdjx65WBb/gdJ5LXEoxnDkghHWvIMGJFdvY+CHRDIq8bq5yYzIsDM9LgI34vQEELi5vUjs04gaqSB2upMSILEP/rAM
# DATA qo6f0B3THQP/pkXgH3z15F82SowfGDQG+ZuCgfG3RDYuIqxjRmBv7pNyUkdhaJp8SJIhSYkgHxIWglRah93hdOCwMMcm7NHb0rTE
# DATA qDFCFzDK0FWLFcdWXUk4Q/HD7fW1XZ2PePvRJ9t+buI6ZUayzejE4Ic9bEAmyY1PY7waQAuuAISjaR7Cixr8p85PHm89/G5n/VNX
# DATA 7HS5ZSAclHYJSvi92ck4l4R/7qbRKgpIVp6DJ3aad/v9NvtTgjlqOG3fTIABqYXtoOtcp4P7tdOB/dbpxNYPNe8fDWcnuODwZzpo
# DATA 7mx8tLu+/aQe2d8fP3sqvbToOf1TowpMSr4bHXXNR9e+/rSmLyeOoEMcUcolNSmOGhn1u9kZiaIBqZzEr50zRYVP1l/1p8Je6+Gi
# DATA ZVRZTQtID9mBHfc5t+SJcYkOm3v9d1ZUNZcRI7cWXCaC7ntzXPYQpecnmFcdpN/PNSDIrzDN+hcIufeNRf53kk5+dKCOyvjsG1/Z
# DATA /yBh/d3bt/Ff9T/v31u3br9/Vz/j5++/f/fuN6KVb3wN/5uBh6xq8hv/Ov/3zWvLs3yyfNAfLmfDl9H4TLGO4a2l69evb2dpT21x
# DATA 3B7qWrr2dIPgitB/GS+reTQ9noxmR8ehmCFVvqlqWWKyrkVX/RtMKXCw4JD2pvqpuq3ilZF/qpvLsbpj6p9A+PTfo3wJ/Svg7qGK
# DATA aO4BwqUuMjGNKcKi/4Q29d/yBus9c/rqKqfM01m/R31gGqH7gHcpRdjUBVHR0u5ADSgyJkS68JnblJHw1aD56mnSALPuXzHKkzEk
# DATA Vun31AuZ84S8LZDncVSN9c9ekh6N1fmMMZRUkd582usPm/08nU7PakWfMHcE8RPye4xEPI+qdtIHr2wSH0dDTO+UEl7xif6+FbnC
# DATA H3eJl77J/9Zo2EiWaeREXPvD8WyqX5rp3RxtZ6QV9jWJoEvQ71ihyEOj8At60+HiNRDR8XKiGPUYNPwgN53kR2r61XFQW74Oyd1U
# DATA G3PnBxo29as/foC55+/BwcHjckjRNajSgYgmO5i1cd/2sNPpD/vTTod7RvrI0Qu1EWIHqMTqV+mGaMLLoK+OPzPnd9Y+geek6DW4
# DATA ARdGk2Tj0cDc5Ka8dhNeU1Zo+lNnhQ46yXlz9Ew9S+0coIg1mk1lKux6ZOrWNcfh8bTbGtUBNfW292agqzffb66o/7cKg8UMwlAG
# DATA frRaq/HFIj3ezk5GU6Z1ub7EkkM+LW0aUWrinZ2Po+lsCCODwwAlYhlRMzhs4lriX7igtIImq/MyiKr4wv2K9yF6e33a+HA0OU0n
# DATA vazXeDoZgYNdZJdTvlV/wTs7Axc0dzapwwITxHDhF26HFtLviwMKEqY9f/LYGVQG1BCArpidXyH9mxZU2d/aCYzChDFiXsAncYwR
# DATA jiJScZldd27ckPN44SCNmsVw9wKX3YvXKNnjjzgwHHRqH2TqxjZBmmY/93PK+r6lqKsvzUXIH9X8A83urfAx0kWYFloTcSXAt0mT
# DATA yybhcTykJMSNXYZTdSfqVeP09BRz7jVMq4RnbFsszqxjnYaE24pCw7aaQJBg7ZYALIGT+tH6LhsQV5MFvELVRinusG2xe2B+wFCF
# DATA WwcmsA3/MWS7bci3gwBSVPvjLU/sa7pNIkPQZqDb8+xAbrZr1wpz66a2wQhTTJklBrBfuaIkehD5384zkPjEC0Q43RvIQaruXpOj
# DATA rMSpidmyk9yRehJymb2UXcT4TJEEETRoVBnG3OMka/T2l1cz0LjbN79dj+6s3IT/3IL/3L7AYnrD3o9uhpuW1gtFQ/QHSenqFwK1
# DATA 5y0MbuboMO0Psl4LOUaknUXtIBIZqxVYiFrQLFOPdmnzhow0FZP3e58V9ckwQyUlT8w9sJSBj8CJKtqNnm7t7MKuQO86P4gNOqdu
# DATA dydjCqmx9odiruYaBo8fqo0+dRK66ZTrvWlT31gQis6rug4F4NmPVOvN2bQb0t6UVtbPR5TglCpr6lzz8feB9b63stJaWfEc7Kmu
# DATA 5vRHoHwPhymZ5risrpW+aQc77ORkb6a5LlHzSzdtnxPbX+6q6vT3hSlt+DKbKDk0B3/Z/IeztAcy3WiaUvJHQMdI+0NStRs3Wrj5
# DATA OSyecztCLWQ01uKoQFfgu8xEzepsMEBw6tok3ltrfD9t/Gil8e1OY//8Vv3W3YuYkmnPleGfaZG3N8qIWR/2pyi99yzOd0Tz4G3M
# DATA SaY+xOAakfO1c5KOUUChOxEIKGsPdze+t46adXXzUncn8JOJH23srH3weP0RymH9E3WfxMePN55s7NLT7NUYzCfwdP3Tpxvb9HQ0
# DATA 7BxT9iBbhcnnY+eOPTYMeL7t3dwZGb4Yjk6HWi8Q6ZqWCIniBAAJVTs9TJxMi87eSIobd7AAwY6tJHWvBHzWmU7Sw8N+V5eRy7oS
# DATA 3W9TE/DHt1dW3l/99rdv3rn9/u2Vb397Vd9asBT2IFBo3ug2hujlGXEv1N6dwQ02N4sI/rRHZyibBUbWgd077ehiNIh4OKLncdKc
# DATA jcdKFraQWLo+c0PZ3Opsr+8o6qvW8tHaZ/DPJ+vr34V/n2xt7n4Mf3y2vrYtLytlC5Wr1kYT8EnG5iPbLXKTSSdw6DBgfr/QI+AC
# DATA 2JC0VprR237eM/VoNG/8LDrIuiOIxjcF5THg3EW04/ZgJvf0ltzfl7vVPsYOmd1tdfJ+41ubnY+3Hj+C+s/ySJ+Be2joeknHFfha
# DATA jxW55gYHeZiyU0tHLIEiI7KhUZSTEVZbQml8P5uMFANNh3kEYaF4YBlLQ5KKZrT+6jid5ego3u1S2oUT9TuiBiI+4E3nggub+UHb
# DATA b9QcODWbq767CM8z7ilLYTT5uAgHEuHCmEIVfsrUbIPOmXN/0lvkmtwjnouVv2Tbem5p0iNMja0/vmeRY6LD2XSGSzUEM1QeoZ+p
# DATA 1SvJ63Voq1qjFXS7Yg89y8Exh5K2KIEm+pFa3HtKXp6qaz118SQ9i1SrQ+IF6QBBD6J8DAK/ph3pEXpfLjms+NyyrRY7B+strlNc
# DATA G9q+BhdYK2fQeaBXMeWdsDSIH2sDxE1F7BqrNxu3Vndv3mrd+bb6v+8XMCRi7uljWM0PIExStcck3Hm3owlHy0wsOAkgC9sA+jhM
# DATA BzvA1xELCMRVzJoHfkw15PdJUkC5ioXlClyOzUgUKWRgyjjEuUj73Ouk07ggpu3pt2vo1FiYO/GtyOXVR8wQ2wI/i2W2kJkgpm3w
# DATA CK9xqSRqqDV9OYAISJy10Q/IKJ4fp73RKURI5mIYtprLkO8xaHa6o0FLnAUWuVDryog8pH2W6cT5OyV1YXKRuo6xhbjDmu01Gfbx
# DATA 5zO1cKB3qomhaE2fHeBT/QRLyqF6xfPcFnVRFXTfNOvj+fTjN7z7glZ4c+k9XQu5udEoEz/PQCCysFqjbfpm1ZCuylHk5rKz5rag
# DATA e+qeBrqGyBAQ7uO3ULZRt30qAb9u3Vykz091X40+1hFVpZjKASzqTxRVJxmnYnNJJx8lGiKcooKpoLBU4Z5tjqLiFpaaXZk/REj9
# DATA DvJLuVbbyrLC76ej3mvikTQRrlKoUzUMnvpzr7G67++TymvD6t363dtwb1DNJYssjIwzJjWu1velUX4MZiLYEaQzHmRHafcs4BzK
# DATA E1hcnhirwH2HwZGzg+L1rW44m3Epw2w9fBMD28ywl/V4NN+MHpqliZRQpDbLFFWU2lEryl6qMZweZ1T/CWpukAOnAAIFXkAgwfCF
# DATA HO+PRIn62aCHUqZzZbMHp0hWXMqB1FSP1vLLeoiBlXGufUMUGYKaeuWQJH6j54WsCHqbgZshSDX6LeJh+/dtnHy8tBpw5yD7Bv6E
# DATA tdnXpl5ZpGC2s3WryekfDZEdnedqZmknuKqN3MlFmJPbBkJ2mcMTZOKIznkhNxRwPNvD4Ef7SLR0t2zcjSY/HWi0lo77ztVbk0n1
# DATA XGt1a6h9gsA6CDBAM/PywVlD7x0MR3BoAohkJk4qPczAMGbNBBLoxJo+pQ+6sZIW87oLXZJaFrUHO8RjaBwiueYBHC0dYpKjnhnl
# DATA RbDvoGUHUvCSLQPm0vLo0eFhngk1+Uo9WiUvCLdSDbA1d66+QzW2teaQfiKg0B+hcGfeUPUuY0MZNwx6g68INXMvxl9uljbnBW5u
# DATA /KIYAwAFrQoHUWkgzcNiVBWnn50PNAypusyhIRpX6B5pA/XDNEL0vkjdu/ujXuyF0IFXLcOP7nFv9oshmUWVU0KYab6ZqLzfj2Zk
# DATA LMlYFKOmMYovRxwz6IPJG+fFH2ZDcJ+shfqR3KO50HcX+JH4mRSxBIYQ45K4fT5QQvELnxU6EwLdFNU8CNVSpk7RXn962LRGlvOL
# DATA eq8VuheudB2r4DsoKL0zME6xTgO92B2IbfZvalDLOnz/nAfX0qeVN26L+nDhUAwsonHRZkPPlx3j0sgNcjYdz6Zl+ezK7MnkDWO6
# DATA jNoAWIMDsCWreg5G4E0DtcUliYqdxhVdGw1easOfKct4EjI/eT1CH2cNXFWPfLCJ/qH4Xg4KfWuHZzXxVvECqD9ZRKWqxqVu8BHY
# DATA Cc7gIuNMgA4ay5vdY9WhmiCyomu8ndrgK0Hjpycd4+0gJV9RzOFIYH8X7jYENPvw2c5uZ+3pRmd367vrm0Bct3XiRvSBIvNwZBKy
# DATA aRVx26nqydr29z9Y2+w821nf3lx7guoXrTNNe0p4UjUYlx6RjM6I8eHqnq7t7Hyytf1IVqc/gT6JyTFOBfzTsAyQ0AzPwL4sY1Fz
# DATA LFg9of+Ud7qWae2CrfLIX0EmgNDtDlVEfAGv/jnGzVoFWJBx9VmUaNAnAGVh2fNe3PckDXkZgW1o5Z92W/s00xcdrNAKPlR/Ml8N
# DATA TJ9TeXujwvMC9fRklk/L9NVYXTFB37vFJsb+Ievt5P0fCWC1OlkqcxYW9qzIqtkUtlERvDhOz8BQW5eqXdf6Epgcfmj1ndpbWN/J
# DATA 1N0CrmW+1ZeiI9zVJRlPPKjrPgnZf78AoGwqk/KXhl3TlxZdyFSZLMx7BSXAqSTYL7L09/qHhxnCfNGN4B42OlJzBrxESbweN0a3
# DATA cpO8mruCx4LnPtaTrx7qP2U4SSs4XIFTre247jDc0Dvt4lyPwIGj1NsZq8NNZbvsHXBfoKDM2ZhCKZrnG+32UOsetQ2FSTRNa3xR
# DATA yqAlcrJly3QiYuo9TBr+oZ7gRsVcjS1/515opR7YlQ5ZUGhF51bIuADpMO2dqYfqBosxlbO963pBrlOCo5lGVYDiWrdL6Sm6Sjyh
# DATA T+d8Boo6xbanOTdP3U8uYtlFVN6gVyCTDUqHoapoGcO/zV1jeDLVNY+GPZ1kqgdHx1NjN5ccUd3XSXhuRtto+YjsMriBK73JWUcJ
# DATA PX4MQvxIrZ56bgLhyDBPZLB4dNzQdhNUcqYIK4yZnDrjh9K1GI3502N1SKBr38GdHqkPgM2hfeEMFNZ+tx7CBh2UjxdiqERnWPoA
# DATA xTxrh0GFvY9KUV5w/YCmEX/ZdDCIDMHrLi9qSAzABkp5hZhM7N/TZuwAWSyn6xbpsJrWWpfaAIph8FJX6m7lSVAlwgMdVkuRC9Uw
# DATA LXP3Zri1b0Zr1jcJ7CtK/h2MFLtlHVNksEjIAx0diQGnY9jtAww04mRHB0pA7Q3O6A7YDDbkhCS//RSHp1lfezX34tdVzKv8KD/k
# DATA 8ZI2G8J9+7C/Jxmcv7E559ORnY9gPDtsdWMFsemXi2NCtfQluq6rtmemsvKQy9x81q1v+4oNdTM7bCQ7ml878EqhvVfCJPUA+Izv
# DATA B9kly8IB9ii4d4DBsTKUWRw1VcoNdz5eu3nn7s6zJzvo10KprTgMopkfp+plbewhmx5nr3r9IzieqOaJkHmMKS+i+v18GJM5CCVg
# DATA 1MeLm9vRYHRQi28w6U8Sl4cSRe4xF+Npus5b6Po+sDrJGWUh85yKabc2pww9hAKW6/hrMZfRpRPUWZP5614kphv1Sjk2PVOPwfrO
# DATA ohfzKSX50TEd9fBQxcHo6ysFXhfDeFEeAofa2I9+vhcoLshO8JuSVtyr1EItkeZg0Qbw6tKAq4uO50bPOTVpqZr29qq6oYcaQSmt
# DATA GBEtfb+07tBWJl6XdUeJJw3CIwuFMod6coZmgtLA5+IH+ibU4JtQ1dc6kDkYwww7bRW15O4dEB7dWVkR8oOOR7aT3YpW//tP/pc7
# DATA 4AdI901jUwzc6UyqEg4knRvQOS/O8pJ3ERGMie7Df7yztfkI4ZdLrypEcK524zBPDZHBtA0kVaJ8CXob8tJrCjOXIADYvJKGAdlT
# DATA VdHmcCjVbFIeO7q6YIjlv+j/+akxvv74z/dvrazcdOM/V1dXb936Q/zn7zf+c+t0GI2GSpieIohRL4uOZumkF6G94l70IsvGGOUE
# DATA B0zxEEQRQL+UM+sD9VIdSCgejATFGx6nlRIhnPyEkAhMXKY6isOR/tEfc9K5t48MPR5kr+yP2bQ/ML+mqYn1tDleTBxpdjIGUrG0
# DATA tAsuhpFO8wd6YoJ7w9mKl7a3tna1pp7AQk25BiLHGTiOZOnR+odrzx7vdrY+2Vzf7vCX8fJoPLUfxUvPNje8GnMkSj3+t6yBpkZ+
# DATA SpYebm3ubm897jzd3gLwPLe22eHpsszw1uz5NcISTUbQ452N3fWr1pKTwP5k7dMOfN754LPd9R3wZrQRLuYlPFeyL469s7v+KU5M
# DATA HO89G/an+0uPhBhmtfW4Z1kNhYuxtAZ3yfYwm56OJi+AsTfZlacHUPYTPUFLH6BHVftECSF9tDxzuaU9Toy3vwTMrq1uepDTbWn9
# DATA VdbdAX/BtjlMfJCiqhVfxl4poqshUJfIFxK7CSymrYSVpb0NAnDdX/okBSb1wVmgY2ou9Fqsf7jxKczOnp2JTZgJDFLcfw5ZVgeQ
# DATA VUI/UlzwAJbi+VBKs4Rt0KNJNCVg6+ftWBjDboCI4SZKwugrB02TnAjcRE70HfJoDtWCU89VdNMx+Hp2SDalhxV5Mql1/K/M06Sl
# DATA eV5wJwrEuGQaWtLsjztOSUwF1e9OpX3Ghl7ADbT/apAhostKhNDa+KKfd3B9umk+dR/PMNck3jT8W43EsluLuFiXQ2M3nkI9av6G
# DATA 2VS65MSOmZJSv0NbiUkup5YUjH6qEjWY/BhBXtSsH0z6PXVhrEcYK4pP2ysmFJ1gIvVU4G+WjeFrtCjhJRI8GUylSfTj6PzmzQvH
# DATA tMtvHkR3b2ubIVwZauNEK7/7lD7TiMZj+M/dO3du3bF3Vqqlasa0zhnYEZZ2Lcw8XOjI6s1v6Z5U+3w1W+D1VV+9A05fB5Sa9wB6
# DATA oytbpD+PkKzwJ9ozMz3pD9AzuT++i0GVcSsmLwSLndkfx66d8zA+pw8vohz2a3SOxS/AjRxCXVmMJ9fydlSL+/1DVACcozYArlek
# DATA S5CRomJUYkn1ACkLVWSaQJmcX+r84MbPCVbVbqbQ8mJghi1i1nmReSQ6JVwHmCDhxEy746iHVZ7b6k2vET/Atir7zefmUNFO8sHo
# DATA w/k6R35+EZ2fL4GvjqrnhKBb1RMcJxbrMKu4Fx0OUnXnY6JzL7q4WIowLThfP6Aa+kxJC6DJPB6N9NVE3TpGE3Cza6yuqKsqGPrP
# DATA uN/31Fd6Ca8PRtf5sXranRo8aZqc3mQ0Vs/Paa+AblrMyHl0btf+JB3DFavOJyq5UL21Fduv/q0ds3l7zlN+IbuQofNKPz/OenWd
# DATA zrerjfkUXgHioKnkJJum0eA2eoMqwvvybqPfPVFnXP3n5V2aJdXjYa8xzPpHxwejSSOHSQGPdPkw7YFNE59N1KRn+gkMRx0qNcVj
# DATA cg+5eefOZRt39C7DSZaqxcQ8g+MUst00pqNR46B/RGymof1PMJe0Wivoi2pAfXDizC2tkd0bhxSYX7I79Ns5+2OBnXDllTpnWnIh
# DATA O6/+D+QMA+3YBb2rUZMxcwAmsMTe2zp0swBREitK3VFC6Ob6w92NrU2K4WP/XId020rQgek2QdCYh+DHqzhrr38EHwp1AnQGvaZA
# DATA reCWD2FLAR1EZGFwxFPCSYxyXA6CnOJwlJJzF3o47akNRx2F8uEE1Q5PwRP1vPdejImOg4kznc5CIT0Te6a3BSTW8qyTjscg2zo0
# DATA 2baxXuiZgUMl2ZdyjSLLx6BDRvOnbYnhiZO+Wu028zJ4+UNvQuzK9aVrrbSTSXDi0rY5JTdANaiKdBvexFFWsJxtbLSptjirkwzd
# DATA sH5uOANas8+fG5j7Jt8AuBtNKt5kbz8vg5P3Pz2MFWQ2ZPLbRJse6tp4xpj1HEwQ+5BKbfTi/b3W6k29ylqSI2ZMVNpIa0aoo7zX
# DATA yLLULA6MLCKcMnByh4dTih8lCA/8gOY3gwfI57Tk7oq4uqYmdQiD5zGRS1m1eexWJD70+fs2gSVp21Y6JDkBlzxSdVN1+oymwzzV
# DATA NKR2GPcy9CYssuvnBFMf6jiK58z3QaTBKTMaUj2cRhf/e4j/jfkSI9pPil9UlOWMfsBGT/vD3ui0BjAS/LfxuF9DJtIzo1a9pIie
# DATA 7mAEQXDoca9G9VDxtoMRSlKgiwFMlohPfNSdpIqo501zO7naygcXrKq6hVb8aqsuToKapM1RNDoFT3fSPvXBkQvvw2ADVTdG8tTS
# DATA V+pc8bs+wIMCBmXlpOQ4Fd6UxEbyiRebH/QWsksbiggQYaLPxkeTFM9SRCmceEzoQACOYhoAiQ45OglNc9qxkU4b15TgzWW7seai
# DATA UEI2mYgczYWIe2nR9rlAeaF61VqA4AU9dOsmCbdCppR1JcXTRScdI93pUMxZrBjl3G8h+MBFHCZrwYWSjapZulqLPEfw5+qdE+qD
# DATA pgISWpv1CuxpC/Cixo8Yo5WqXIflxWg7O5wRdkrE5fXtsldH1eRokqKDsFZTNk9egGpwDJbfNjZFrsAIuXDYf9WOm7gXGyGIcQ/5
# DATA 9LBnEU+hbg/xFFqjMZO+xbw1Pr2mgzQTTgmDUmHLWHhxxEwbnDkncJRToBcn8zTf+fJCrhP22hI6KS0g4nJ2S3tVROA9NAZdQalp
# DATA l/XrvhmrHoKGBjXZzdPjvpJBY/XMRchQD0pzbtOgC/7e+jltm8JrDgz0iqBLeOBroGM1EOw6MzWGa3g9UJJYpn7NKY8R+X8UrYxW
# DATA bt6smp9nQwgFip59+Ekk1kvXK0MPqSGdClaYQdV1kYG4dCHqhk/+4Wlzp7Oxs73+UU1/pfuKo5EPSwbsf1cc41uMk474V60TRimb
# DATA QpHtlKGnCih2KfGuP93k8ehML8yAsYqv3vRy85bVUdNB0K7/lXsXU9/k3RT0jzghKAzGeyuNb4Om787FsuJWz8GVgOpKKikwzDj3
# DATA BPN3zIYnPDvkqJSHCKmji/JgEYhLUI2aKrMTqCQf70Ux9zPxc33V1LEm9H5gQLOxzlYXWvPyryEJywJfoY+YnfQwkJ2tVqSdt5x9
# DATA 0bY4VB9XnYn4IvkpnA4WO1d5+r+CEZSOIuwV520I3pPvaM1ljg425pn8zmQtYEvBlXigMQ+CT9HJ6GXmIDldlUMxUnjLEoPLmSpY
# DATA 6VnwxhGGCvXr5tdiqEAKytPkWyz+/8eBzUAdrmR4hVlPdSfq6DWtovj/0pi0/w7Z1wPgXpdg3+FJmsdUhdeWYnEI9uZoH5/7HP8h
# DATA NfPcZfrcuMvun+JSsAmqBnwybRyuNT5stpb330s0469ZBlr7TqtufyXfSXyO6q8K9nLuHBUnp5Lj+jtJUwdsDDSqLo4e0CcSIexH
# DATA 19pMW+DOTRQEbCfo6UjV3NzXaBJ18JrFL7zTv/hoDrLBCMK1piPVkdH0GMO9UMchQ8wUzQURLryesYXUVVdxE3gWIL8O47hR2wsw
# DATA tn0xMyh+7UGGWMvswL0mtqgy8XSEvHB4FhtWpP6bCJRf9G6QB3cu88VhMC/iUbgptedwd4/TMhyADnb9yhivGbczDrOzwjIhja8g
# DATA ncyTrorVl0zVXOnDxQ5BTxR5wzbnAl29CqektXTpHnlzfBjvnauZu7gsUWIjuLmDoKW7xNgZlJwXXEi7GRfKi6a3uyduBWaZJbBB
# DATA lg5n484YkzMTgrF20HfOLrzTXlZO6jkK2icFUnqQjwYzNb0EhNNssncB6XymeQXTPtQMiXuEX7VgmqfHFwJZqqs2AibDRiipGxOI
# DATA vckzSofHEgMYLuDnfkXAKmKXtm1tzYHHvHmeIeXt5mj6IXgYBkKICjBRDICH/P7x5ndr0I7h9XMIdGEKWMhSs2D6eSHhoFDGMgH5
# DATA dmbwdIDebGIXU/bQ9IqFjZWQlcnpuhE3dGxsrdgaRtPJLlF4nVOJmZvv7X6aJOFm/SocGerRxrY7p+FKCPfDq6hWkMacmmC69AOk
# DATA UjCyVfmUhSvXazBJLr2uyHnl4oRWmI8rTK13VhHMm84qwap4HXIObOGAB/hAOIsVNsA5qrY2H3/mZ6myvzc/gJxSDn2qODc+kHZV
# DATA cqvJQUjXy4cXvsFTi5wF/jMc1ZJq+bt0xcVRiII7f9HdEcDKXGxHeMROoPEbybtGviUObjt7K0DRZOHmH8qdaODYvR7wQuHVoocx
# DATA FOq2PD1sfMsCLPPm6h73B70Jbxref5WcxbJkyUGK4hh3gT0HdDPWl0DvnRyPz4TaxxgPxb8dpDjgHfAQgbYKb6XbBzeSAPCp8QEu
# DATA Cxt0ZnVXTaS6GJw5y5oH1tUMRnNU7FnTTWZamET8Qs4ifcVX7cMRyMj6Yp4z8w60OckMjAD+dhZbl/DFAyXI+EjmqKVg0MASywJh
# DATA W13GqGC4vzUrOHmD3G6hUbIW2nDgwB7ecHymHGKK7u7LhO+W6XDJ1bu3vnXbwtHAZwVx36dl0Llx2p/kmC4+D8G5C+cQBoWrawyw
# DATA IfpmFLclw8NRFQvsRIH5RFZecsRCPARf+0qgfgAp5wAuFiD9DIZy5ib6Jv/p0QHkGOrg0DvgSNbGP50jLuHhpphFFyHiFtkVYhS+
# DATA 47F6xJsCTfUk+tfg70kHMhLa/Yr2cvO8qlkS9AdqGGonssdzHjUa+DUllGWooFNKPwOacmf74aEWnWhaybiwKy1uUuJMsrfJl4R4
# DATA 6RgbaNOiNxG2uI39QyUS/CxsVtcFVasosBad23Y/MSh607R73GHcYzEiVM/Cml9lfrepOq69coaLe4fbRQ/5JGxsiffIk3p/z6Jo
# DATA rtTv3ryI/W5Xbzsetv7GW/R3sOCkXOkiLgNVu0yG/lj9wa3SnkCRCKKBoTBGdquuNfPjuCjNGZ2dQ+KoBoeqsaj2bNg38ZEFUAu9
# DATA VNwBHZDaa0kdGCVnKcXcKNOViFLo0Ki6TEWlkyPEeilWlcvIYN0J0kkt3kHdoRrweawej8mtiF0w873WTcQP3Iu92LSDND9+PmTf
# DATA naiRzZ4PEZ3OoaWwEakaUNEhhjfIJwCRnXWj2GxWUwbGRSVAM5AEUvLSWIITC6AUcKtpm/r27rQ0tqyzIRAZCy0SEHHGykP+3Fat
# DATA XhEto0LwX10IFBl5/xUHyIxnw+50RjAV3eN0krfje3/04/sPakns1QYmlmmWj8FnEFtV1UMdXiloJcNkBxhZ5dxUwWWqhsUYpg+H
# DATA wnYS/9RzN/bB4RVLznOfdFEm1QfOsn2T8Xz/DWoxCNMMfv975/ei9UOHRxOQuVLISwgDug9plVCpoZ+Ziik+gsF7+Vnu3zRLt4m3
# DATA VfigWxJ3yZ3GPoDE5wydUteGQb7ML/Gk8N+WdFO38VS11ani93UmXw7Agm3OuAzsxX5IG/qZbcRI+2uaFM4OTzs6mg1RpEzOd9Nd
# DATA egquWX4P/J6iRY5M9EgJ6O/LzRfIP5QMDiP4G/CbQTt0n+HfBlx3gYRT79QRm5YWRa9MLKvBcXXigtC00qCGvQxmUYyIrkzHfXSY
# DATA g7f38S1vrpYLx4rzgcX2YQfSoEilA5++B7ZI+Tm+k59BEVx3/HTPqdGHOqXy7ehmhXLcjFnfXpwak3CFq3qBK5ghrDMxnmqHYY/V
# DATA eBiwJMw4aKC6mTA3MZyE2AM4XCDpRRWyGWzCOCoOBiUz5y10Tp243aJ+qOcYiWwyyp9OYNYmuEqaL+LCFC7zeGK0iC4lvnTcJ0+Q
# DATA 1lcn/E4nEOvS69jKQ8KtObVO6aC1olCqKBf7KNdqwT6aURCMESZM44DujAxHJPUwFReDqMM42pAQhYDXj4INAUA5C/pGOPZDsTVS
# DATA Gi+KuRHgMfTnJXhrvXJX0iGgxmF0FOJb4GVddyhm28lTdC3QKZ4yL0BGL+2eW7yAjC8Ff3ILQcBmDQxsojyN74SjsRgn5ILvuUno
# DATA r4VrBqyerXCeJVUka4J5jpwxOKo5uTwOwGSNmqJUd7qQzkhheokq60BB0FQW9M5ztrBeKQsqSob74CDKxhDK9YbNkmzIJIm2Ei8F
# DATA wE4q4UYeIWj3nu3QiNDV4qVgnbVQpXHl8UfuUSKYudvd9JGBf/gsi0OE3aQTf0m683ubt9ItIJfY5MBEPkEX77yrZBKtaFkq9jI8
# DATA dS5lQuCOe2CrZbIBDhPDkbe9PPUiWWNzzXWE16EOmT8ZvQTYHKP5Jawu8YCDch0+LyEi6uAUoy++Y8K+bLsKTsFssAfQV2C8SeIo
# DATA XlygfttXo6HpT7PSTWHahi1GfW5HEj6Bs25yMWk7LohDOCVaGvIGW5vnIJgklbIWRwZyXir29WanEbGjzHC0TAHfLesMtL2+QNKN
# DATA iyqs4gxp/xRvIT3QELGWWrzj70o9Fhyuo2PvxI7EzBMeprHrxONryFy0SZqGju1/LS7xfyrxNIjnXiQP40t4I8ytreit4MT+JeX+
# DATA vuBAY1iSGXC7MAkhtEZvzxbWtVZw9WFfjpCnT5lDUpIshPvo7fGHnmuU2OWaFdBsL+N3lZvcqM5pvBp7Mffp3iAdltI8TRTrgtYt
# DATA QDCXdCSMn15RqI0LoiA3VGjSMawYKx8ItmxMmYzGfdQtATpOE/QmiPVWw58aBrLZk6nBwC6thJxCrVyXdLEMOxZCEPlZw/EKbIBX
# DATA YBOgj2Py/Wi66J/S6S/iThgf1XkuHeD7pj34yj1KGMrFh3XhP2v9sc1V20BcBEK1UD/Q8DMmbtIfF1xQQmqbMt8TWxvKmLof4CMD
# DATA sRnXIIwdTNZj+BO1DFRCJNJtUjBfMm9acBXUaNl2dsjLct4fXzQhpm2pmI7cIelYvB7dXvn2XTlkw5kPY4N49HxoUI6ejnJGOsII
# DATA edVQ1DisRjpy+yUJbREPxZ8wRdXuergo2ikLSPykIgqx9p0WBiL+mCEVksiHUbFBIWrVL6IiA5hIhJHbt29x+GLECtPo+qTb6Kaq
# DATA CjVcr7aGKn7dodxgkFO0+WU66ae4GrW5IZRqm3BXeV4uIrc/VTzrMDYIEJi8iu27lNa2ciRqpYrdx9y/HbuX4BTp+xJvd/3Sv2o5
# DATA 5CNW6xJzKDbQpuR8tY6GIZ1i3m/STlhgcxAoBFCIecfJ6WG77S2HkwxMNuseQn8SHGV6P+ghhOdLcmfsiFNRMYgyb0J0s2KKe1QJ
# DATA HqFi9oSKngYYLDi9nKQT4KPgiUz0A7k98gWzx1qws3w1RH6sJrlLsdsHmYGiji8hxB4qcQGaJN5YZSii/qhtqAMbh/0C+QIG5/sI
# DATA UDnihYgUJ9xPcFa5J/A+ETlh4bOg4OqLKAA5F/nCSZkh7jgbjB1DpePqYDXmuvdcvuziUqP3roUkiOD4fPgVQDgCMYDChV12vRoE
# DATA UXUG1dc0uGAFl4BJdGpLQgeHl6pkmhe8bVFnF1jjYJvCi8WRRkuFvKWlf+shX0ohdTDqmpBwRqA87A6nAzLcqpcddjXU7cOzuOiS
# DATA Y4qaLElFp0NThj0PH26vr+1qR8PtR59sz3NCBDX5Xa0md53dPadB2/7v22PQdd+8rOsgTBlgm+uZk35muE7NQ1xB6VdJz2G+Ouuf
# DATA 2uJn4CAUjnaHAHqwQTnTFlbidMjtXrvY566HiH4aNP1dIT6vHOKDo0j0wRFRs3kLW+pDII8hMt4Vpa6lolCPKyMzb8CHUu5SVw0T
# DATA 9kBTpig+BdnUQvaVNmVrDAAkXsrLRvt4VrnXXNlus1Sh3xbaHKldM+ajpcIr//p6GReoS6hc2Wy2OZIOZUU1a1HMuGdd8l/0FbEt
# DATA etE5aCudevXlHW79/honxUkrO0++j849DbK3VxjaqKhWNkOAnUp920+Cdmz8uG4T1SxuIPQ3a883oMtUFL63QbVuxLr9hvjTvM1T
# DATA vYEq9kjVRFbuhbecxPKJLJ/MQC/KWL+/K0vm2w2by21YRpFSL4zAdDXyzD1B9VJZ9N6wFhMadXc6QMrczzUKVUMJdKhcnI9TLYQz
# DATA AXoWx1c5qFLvBU6vTdBtvsjO8prkkCGOURo8GBhmqpofNtS9ChI+uY3bQBjVg9o8XV3d61AwT5PN4zI5QTXaUiD9EmMGluS+kVnF
# DATA moiyrm/0NfzVXN/cWt/crUfm1+76k6e7n5kH659u7OxWJTQqJ5V0ADzLGy2gIvcUCWucJwgFy6Rs0Am9XArKwGuA/qWjRyULrxu0
# DATA A9LREwOwJ1/CVlegC6j5Ajm7EIOP0r8DTFJpAaDihVB8FGa9V1KmnQNMQpIpzaWfVhVrpVSwNturlwjW+He+7I9meSfgbh685Mio
# DATA dFSqhkuZyUGF3rmBCrWLgoHusvEyQ5EwOfGX2v0C63ZeWWcZXOeSNqx3CwKSRtqthL5xagdFU0FW8/xoXLRtSC5mMFOXtAYTYTgd
# DATA nO5yjG53Zd4S5hEIHFonCrfkehQMxQAKtV+wIGA1blx3OZDZAjtWYB+MMDTnnGJQsVYfTUjGK1mgoGL/tL8e5eux5sECoogfme3s
# DATA IV9f4NcWBlJxqvAjoANzj5uq04F56HTcU1XysbNKAt/7nM2kLWO+y/NjOj8tvcuEjb0VSfAz97y13GGo1/aotMQZuSh0klR0Rhl3
# DATA Fd5ZLJkN9Sa/qghBuKnSMTcQyF1gud6aC3ZbuKu711ijFUfgxyZGGIXghnjLVSZsXFg6qba8ijB82UVfgpWTpikPI/KSNMqPygBX
# DATA fXW1Gv4eUpLyAVYKj/MWPEDpFt1xJZ9KrCQnLxymgLtScjh87yUaI+hYJzsaijE0aNx3PH7FQRCqQOsvYj6OvQadd9SDgP9pg71S
# DATA 6TvgMXFduD2bH6hUwriK/lQ0YnCc9iu63eBGK4sgYWmMyZOnmDRupfJjdRfzP4XEbuHC/SEqsQsfVDVQUMiUDdSJQNKp3qhsKN8b
# DATA ZmbT6MVtswTFazhyf8q6TYR67+ZNTAHOubiFBFAW3uNAFYEM2SrPWxZvszTj5REJdFluKwkrTpKxDPbDL4Us5EoEBZQQduG3InVx
# DATA SH5fvD0tI+ed+DivJyafOYWcLdAYXH3c08WHzvXOLy4vFiIfUbcPjl8wfVepI5unPZmvQXknWpSADkPv/KYjS5eI0EVP7OQt3cHc
# DATA uWPMpb2VfS9doOOljBCT2BLypBVToVUAh7eMbqd4ChfcsR4ZtbgdlTejMDKrb/MB9PDD/isIPVA9btCiCqiNlyOA+Ae13DLaKieK
# DATA jedR2p2McougPbG44YX77Ndwx9TNXvoGfOW+wXwIS5djLFvU2uVYtzzcDKioDBxZ2oEY9ihsAQrsJJIEws6UexS4DsKmCWGvhTYw
# DATA 80aNQ3yoi1ujAURT2suQOXSoTZH8yTsP5s5aygTQxD7neIRJ4KXUDj6BNInmBbWqDNY2t3p/JOJqj0EODh1ifVklGWstQlm11+OV
# DATA 0/HJyqrteGKWoKDE4S1HQ/VuuK4zbj0cTFKBSRYsbx0mL3fbxefJnC2HAq630QT6dymd1+4XCxLud7eJSzW/9mD6q1A5iPnoZWVz
# DATA U+6Xv4Dmt+T8063mXR/8eWq3Eo0AieGFPe0ByGJoABYxypT9JBHquvJ5qtibKHKWXcy8jSWzihT4hKligazPnOj5G3/437/i/6GX
# DATA Fpzzryj389z8z6srq++v3vHyP6/cfP/OH/I/fx3/85My69/59HL5mbugasmD2ZqP0xwSMZuf05PBJfM216Ons0n2FPAvStI4Z10l
# DATA TuXB1M1n5vFMXS8UWXy4trv2eOujztO13Y+1qGUV7tYkG5uz0VGiVzoYHZEPIbiK6Tp0zuKbnLBY5i1+sra58eH6zq5NbAyOqvgK
# DATA TKiP1+jpXXqEkWM61fHd28W0yJAMQdSOZteNzY/MN+q9+0J/ePd2oHOm1KP1pzgN31ra2VU96myuPUFHzqZJZ0IMd+mPt55tb649
# DATA DhRoiNxXXBgvNYGqyC1xe/3h+sbTXVPA1nSQdl/MxlzJ1uNHnZ3dZx8AJk18/1pvhJsMN9CD+/DfaJAOj9rXs+H1B/cxvSNCoWTT
# DATA 9nWEyFNPMcjrAccw3F+mn/fH+glcfqyH6/3l8YP7y1g9RChsPFrf3N34cGN9m8JfuqOTcR8kBYQ20rhGCGt0+/2L599XW+Pj9U8D
# DATA ZQ8RE/vubSqzu/Xd9c3SUrduUqn1T3fXN3c2tjZ3EMSiCb3CiJVunlNGT/onf3mE/05fTfkxCsZx8xWXP80O1FHtHyphK75Qu787
# DATA SPM82lGTTRdme3c2eu1ch0h1ijBqPoTaXPi0aug0Vk6a3sSPnj19vPEQNuIf72xtdr67/pljwwkDpbkgadx3mAlCZGwFbXtCX0T4
# DATA aQdn04IbCAPVBeEXvfCtBfDYOgKQTWd0lMhPfKGBkT/KxNPtrDvDcAdap4AnR2EeNza/t/Z44xHOorrbImXFb/T0IInz0AS9YH+b
# DATA BTtxch9AjD5jDqpfq99CdU38/DmGPeGLio4929xZ+3C9s7azs76LJDhOHGxjSehlBim4foUhjuHSTpiT1zTaoUYmMKDHAE9wxwcK
# DATA mpsFel8mhMaD/m3MBw1VBmGN4AVMwjmFnDSb8QVFuk2mAmiqGU4p6XWj9p2WYrU/Hk+GP05nr348nA1+rOjF3qrq1o8H4yn+kahC
# DATA z5vNG8l3uFdw225uFK9kh9wLFwo6MWF4+ezwsP9Kbd9TuCZpjYYlQskVVjSAGdnpjfDWcel95ywr770H0c07txY4Ao+2nqxtbIby
# DATA 8RhihjU2J5DvfYzro1aLDnu/N0zVT33207zb76vfPFFlEG6XOaG6e/KMSow0zulOw61KXs57Vm0JyZrurl7oN7hLFKuTNpfy0DGY
# DATA bChrSbdOedCMkyS57MQHaTSoagu4tI4P1jsAPNebHO7Apqam2mnHTrLcsn1NIf12W/+PDoAO03GkhKWpIpvwAuy+UxJ/4Vn/QE1l
# DATA jhoLULe/ur2yModl4wTtfPbk8cbmd10P0TA+eTWW+JzG5KKsbT5U4vXWtttobZSTIyWoPBAzjywv5U0GHfUqkderENUXma1PtjfQ
# DATA L6tkCHbe2mLehP9ojlGHbz+b2JnNrd2O+nD9oerHZ5fuCHpLXB3afeEeqvqePV7bxutOKTp7h+xOAgGbKYikNFYRXTjK5iBzzOUN
# DATA eaD3k0LqV3tyw0rgzkn6IrMI+BawH5HE7twpPy1IqGz1BWqFteOgRJ12ZKGpcbtCAxSbBE1ZHRqrxfCm356D36TUQQnnSxj/3Pye
# DATA RU8kdVbtkuGx5eyo8B9kCp3DXptapHqKK8nj8xH5yzeAcPChFLdtD2Jfk8cReLpZyx8RxcLrDzY219TBgZchm2BHIPljc4nA1FcS
# DATA R5aeBHBjTYgclVgQWV9Dt4ojZx+58W/2+TzMfP80olbi8caTjd0iSj73tgwnPz2cZpO5owuh6aN7te1zfziqe0OQv08g1KEzJGjZ
# DATA GrZqvjK/6CPz03xTIRLg+B9+vLb50fqjIkB/SQync6Za3iY2eXgds7hmYdcMC2u5AYKulVaYEsMbGn8ZGu9btJcq808w7dGbtyhF
# DATA h+4WkDMOha+91ZaHM6kx920bcG3Bys2BD8WFlkZAOvd1OQpsKSRwVcafavXAFfl/GTT8ZUQAWmLbuUuHgxZoTiDn9Duh9xVZS0S7
# DATA yfxIlhL6fDmb5dztUbRMyiPszrd44xwHYlJ0zgquIUG2xWsCuiGtSa6FlFLj9AzKALciwC2hqHbiQAsa6Oq0L4vcRomycZ1PNnZ2
# DATA NjY/Kt5Jne4y7FVb99tXkFn8jecTwu12sVBMVmLdLOiq4HeBxWFDEvRAJ/Bl7QAXcKG8KXkfvkDAE34K/G8Ol9P3V2dOHql/Jba2
# DATA Kj5JB5hiFNrYExC/BgGc0XQAUQMttGBWIVfRGn/P5zLOXqaDOKkA3rTVNA9GvbM6VvVwhK8JihNTgXjFmm5qEMVt38HQgb/xWHgU
# DATA Hei+37aXZ3E8qcGHBPJJn72DvkzSU8xy/2pqNDZSPRtWsu6cDafpq6BuVfFhNY2XV7MG+hjQ56A6Jz1NGG/AOcKLnk0peLHQRapu
# DATA qLhEoUb6aMz0gacim7JwdQ1sC3n3ODtJtf93TipL3E1QaE+/3/czzLhvvYO10ExpEWp0mrOSfY/7sF8yEigq4GcdlTS8Q420Y2G7
# DATA YpcCZg5VP94RVTMuKEuxj95kqyc81/0exmiBGYr89E2IAKLtQSAqzn+BaxXb2IPK9l01qTVZSdWgLovFzC+r1wu1p5WMXptgevGy
# DATA fvDTJilPDa6vfg6b/SR91T+ZnZQB9UtUfg+QnyecazLGJl0haN9qZjpXlWwD6IXurN66u5LsJ8kViI2M32UsP5w9WqYqmGQO8Dab
# DATA AF7f0vuUwo31RrV238v0ED9w4osHPURsg+3mhh2TvCIikAivJhiDRFYhF7ZPj1A9bHaV/AVNQfzdUDfK4xPD58bsRomfv1pZQbWs
# DATA 7gfvEv7pE+9kDiLL5SdIY/Odn5NW+uLC6Y4W7HGUwlKDZtdkUZmequ4owvNw/eOtx4/WtzsArrn+6a7XE5o5iDCpefPqqjJjxNCn
# DATA XmijDG1FmNTbK7fDr4LU4zxOD0azqbEk469l0cBFs48JQDI05PM2XUg/t73+756py+UjJal+tL5jxUcHfyXn3emF5YMn3BC8GEEH
# DATA hPKyCds029d9ou8jQ89YiNtWK+tIB27rhJt0M15oNCBuq3V7/HgDTF9F87OhoPtEEErNG56sr/PonSsS1jJUTRM18gGs4A/JheRC
# DATA 3m2CBD11nvetOgz9GYkZodWtYMGHCWvpI2CldXFE6uhsoTENqZp69MPZaMr+vIkhDYVDY6OwM4GtV0GX2NVSklhNpTjjBu8VYwOc
# DATA TzZct3g2Y+m5Iv48O6mqsPr7K8hx2+ubQBekGBfaO7R86H1k5l3NhVqiqVbY0mOQ/9iqysssZSpvmxjsdK5JEw5XpgkYXb67ufXJ
# DATA JlFWLVm5nRf7Ld/T1e+brWcMfmfDrlSECV1XO6DrWkxHUa2+on12GX1YUO8c1FygIgmGFFI4BGOCq5Q2MhyXRPaC0uYS2uxPtuVg
# DATA nbCW9U8fPv7K1dys+oFwmBJlNyt/adh4IfFfHQ5m+bGQZ8x8F/TGPIV0fnuOgwHv0JoIFmAPg2yYKw7SQaN+mwH7gQp1ABaGM23l
# DATA mdoFqVqmvF2L60CUW3GiE8IkhVsn90N9cNLv8nTIzpSsHJyY0STFHNK4a4UbonC0w6lqAHQq+DI24T+3FfE/zjivEG8hU1vdn5GA
# DATA +rZC87b48ZujJuS10yxG9K+YbjUcrh76mo+2OOX5pNtxzq46SPm0U3KcLTVqyleFc8sEk9osMfRxML4pZ3YCvwgq/50Jf3f2NwN0
# DATA V2l3Ex3j2QurLdVJg7ufyeLJMZ80CgqXLGQShsflmYSN7WKSddW9T2CkT0dT1KlRkCYAanJ6LW5I3eRE/ix+33JvQRMILB8jmeQC
# DATA zfFoXEu8Da/LumFJDhtxbCxzOFVhBan+0gNTyrPou6+Ua3HmZWpUZ20WnYFMu+KXn2yDR1YcejCj82J5n738z7wxTPpnz9kZlE+4
# DATA xA+ioi9zq9S3KSyQ7W6vF82Z/pkCLHQcdrRMI8EFCg+BbExUilKjB7NCh8OmMiU39V9mmg3o353pqMZ4kBDWpfZeLSmbwGpHF1zM
# DATA t/H/KbPahMFH7MBwRU3SidiG5tbNqJPy7/VR1t+zlIS7AEzM4S/LoU8WsDmVGAQFYKznat8g+tWqdK674ia01PG9ttOV0tK9/lGW
# DATA A6Xm+ItmfpzevHO3Vl7/V+EMEYSdeQsHidD/LuE0UbK279CR4pq7POi3oB/0hyM8go4fg/xC/Uxac30zF3FLKD+HNmml2/PKz4jh
# DATA mo/n9/GAQ+2lQ8iJuqNCEvq7dVtTMt8VldcHa2wtlOn1bSbIHp3mbAxuVTVseP5HdmYbpOdd4DtSUpkJWv2KF38x95uSjn7t3jfv
# DATA cvQF9oM4c5bzFIfDe0BdreivmgzgDV7tS8WmSzgqsITskWxzidMqMhaPkkT2z+hYEC3GVbIYf2kJTul4UYeAPzxx3TE3Sn+7YrRb
# DATA 4iqHMO+I6hX3je763N3QO9Pv2hUtmS/6Q9KksiYKlamoirJ2Nnit7jZFe9vVbJ/2MTaOD324MsQfCKUs94a4Zzu+iIXP/6QQXmI0
# DATA hFiQJ2IfZ819FDDmUAFWyNq5LwzB2LecDwJ2rtI2cDW88X68/mlxoFhuoRAE8k3ftepKq3lm+ag/jJwOFw1jIaNYwMaO1VV2Hktc
# DATA yhApe76AoyEwHEUelFQ8GJ0BbFlIa2jfqruMidN0JGDMEDPBsMvABm68XNUJnFxFktRfUhUFv6R1JD9eDEMxLsJz580gQR7Wh1uW
# DATA /r6sRRCGGhdCK55mEwRQZP+PEpDkMNv54NnOZ0U/D+dWL2VbiShUJVQHdHShGZLaiOE0DoBJUtTzSf6yO5kW3tJjDMhVMouTmYJf
# DATA PVY744PHkM5jdRENXQGiyrlaLJIEQ82L+L35QWGxqpGsL7NIV8+00VF9Qejp2iA7hHi7/tHx1GW0+VneBEqsaM2Jk6pHMdjZqzgJ
# DATA J4EmgKr+AWuBKaC++fDR48ecp2CWZx0MrBdQOoezIaN/mC3FVRDmo9og6fSm2lYYVKU7ab6qzErtNNBMJ0fYI0x2T33rdhDG0fwC
# DATA h43OWDyY83qm3u+7rQAmDMR4t51KivpRmHu8H8IfHa3r1W9pTeA1/tUJKFF1izWnAhSMWaUPLyiDYd2pxi2Fb3Sxm5TqujTHMINd
# DATA 98T41KrRolrjHBaAIFKDuL7z2Y6BW0eaZn5tPd3c2t159vTpRcUa0sHgw1ProosqaP4UHzVPrAkF4fPJqREULPlUHQ6YKUd7rd/b
# DATA naiZiynvqYXFm5BmOOxPsQ7qlbXdja1N0rXsiPy1Cx+ywBmZe7hKT8/cExQczdru1pONhx1tAFb8tvNsc+17axuPwQVc+vF8Lcdt
# DATA 0SNXOHa07KSYwT8LR09uGCgmfndKDEfmKHpVymPGjrx8zoqVuqXlXuNPVn1YVBs8WXUci6s69xgZgKdSBo22LBQqQ8dsqchir7af
# DATA yLzFMyeNAt5pZHvSNe3K3PTXqaNN3N4nhmQQagci5Qnx0jV8GrcTIhQivD8IRUimBluZ7uVyFFNreQx/G6EUrnMOvdHttUUl6P9I
# DATA z0Hs9yvP2bCgS1uPD36/YLDwB2sPv/vsKQKeVgU/U/aZgrAeVgGMAHwRLHWK3IG3GDpMiW8LluigamCSnuprdskdwbkdWEQYz9Wj
# DATA 6uZfROYXuX5tugwD128dlrqZkrScDZROusdgF2iV6R+4gOqrxJSp0Ei8A52C7aBRIdQZm+7r1iUwXk5BpcCXettRrKG448oQMarB
# DATA GNxrLR9ix1FqT17Ui+oIPSE4ZfuFXLG1oHaAS89XD3DBJFlcQ0AnNpaSjN1Z9hQ4l2QKPfC3oSxccjiCpZNAIguzYT1aAJ7+8nQj
# DATA uUtPi+QTxRar5OGJmSd1MflylarFJgR/8FR4Nh4hpLmgkMgJuNVkzmEXXKQeTUcvMiVCjga9ejTMThlXsc4sSmJE6HUIkbYlm3Wg
# DATA pOsUfSyadsQ8wSIsEnEvewlzKr5xXy50K6U5Rn3YZzu760+EDKi3h9OE2iw1gZMFLkA4RcKtwQvw5mow0nxlxY3GKVtJocYJb2kT
# DATA ZBIs6dJgo7U2RLQVrWo62qqkZ/WC8CWJWStAyTQlbuGWKX5Oe78Vvc1RktlNSCbS/EnvM3KWcXhofHp6SmFnsAkV2QrvVCigXlwu
# DATA 9pgZoje/uC/U33yEWF7iXC0gNsjdDrkjBj2eNiVPZafqbzhwzhRCmZ13MINerXpR+GzHdLjhAf5xIeOmzG5C3qxdbz2MvRvRzXkz
# DATA aL6Q1nbtr+esnAS8I4fMIIQQyUSH/WE/Py6jZ44elG8Qwss1O4DN70tfuHNkRsWjQhHHORBLhCiDyBi1CEUpNB3UProUFfk27X4e
# DATA TeIkPaBXuiOoJlE1BMKAOXkflavrqfH1j4t1oA3J207FG5yhisaNao+rqNOsJ4FoZboRuYxGRhzyItft/iskGMzzYI6ZeVuJqvmB
# DATA OiFD9JUr3bNSJcnFi+Y//eLKFkCuoF5yHN9e7CZy5tIxplpMsOqCPhlJ3JKTdyeTL2C2w856QioiPhatWFQ0CcvuYrD7Gple7oKQ
# DATA 5F68RIek6QUF+jCGnC/hwyrs1yPzgxYhIPIHZwsWbwGBHouVXiJokRe+RXBx02owVsqDVrNUUuJ0xnrcus7L3Dh2t9c2d9Ye7toI
# DATA Iw18HjKI20sNSqWltyf36sAVkepzEb7hbsylywijgU8F27EiouUsc7le9mqsRFmMahT7oJB/2ll0xmaniyecG13JW65LZxH1yLyL
# DATA SHc2QR1W+61kKLYTvdTcCdp0+F6df9vlT7RhErI9QXnjT4JJE8LTWbiG6u6b+6Q97za1zQA3i513fIMz09YdmKv2p3l1RV1KBimI
# DATA zlKVIFKlS5K7wxEDLqEi4Lp6Zu6NZGMUrKXESeiBJ/0jDOByj5b76ZJrFC+Oi2pJqjf9JW/79owdZY4cp5cXZp2SWfFEBO0g5kbE
# DATA I5W3oXAfr9BPKza6rdQj/wD4onT4mMB9wxslf+Dt6vKx220ZuF5jV22jARkX5duAMCp66gPBlYqjBVM9tW/qdDfuJTopKFC9eB4q
# DATA aFE9eGRwzDjvcrvNmXixRBUanssMJTAASQKxg4txFbbNPNz63vr2ZxAG/uHjjYe7cVJFt8xw5x+v4rCKK1lcHLJ1lpAsc9pNnzDT
# DATA EX88l1pWDvjr5I1c4JphOG5K33IuthDOaYA3zU/Hp6PArCxReURZG2FLs/ozKRV+pLEO59dvSfeAr2vSQugvBV/6zvkOwkojzT5D
# DATA e9fqd6L4KBtmE9yS6kN9Tjy9j/FUbBmBzfguzhFGLvQtWV2Sp/10QBHS+rQ6bjj8sDwOzbhkhKO+LhObbHQOlwlP1h18R7FejppG
# DATA x1hcPryLzB+GQXCYP7hchQK3DvsTDDIZQiImLuH7S2g7PxYtT/vrLYr/pUVElKAYcG0sNl3tfV1wkPFCt6i5RUO3QuEjbwm4XITK
# DATA fUA2QSey5Bq52+osGcmCAy1o85wFB+lJzG8hMIr1W4YsVlQVCglbrEeOobmsY87YUamnfxWUcaa39SI4XvK2IwiFCy8SB1DlYwhA
# DATA atnkZciX14Xg0zoDn6m6tsWlkslgJWVSrFCE6DIzgDczyAQfm86Bjo1kVDAgcPy8COwjxhGwhrw7duAzHH5mOJdkGZz1lDE1xA3K
# DATA x9doxxNFNEcnGB+CMecaHEBc1KQJshKJA6LHQeHIVRnadDAaDQKu8LoTVi1mHpEXAHXN3LiDAQEGKWRhfRRA+KzvGGA5u2aOw45j
# DATA cLNnw6pyAi7mfBmzpRdVXdvw74L2Ws1KSHHthKDTdNs4F64NfvuSgSlUJVVIwhQ8n1hKXuXb5Z5RBdsQYSRCj4Uo59xEloS92m+V
# DATA ZJEy938dAPUyY/XPIsYq0yn9nX9ZEZMcpN4LkAxC2ChQDHP3CoZzSXJheucGzLg0QRQSz/clmRBF+Nn+hR/rITfUlTfQYpvoUmrH
# DATA AB8IXTMCowirUMvF5sU7T9q6wP4lKYumCN6CcvjcaaAs9G1v33Vpqy/2lYn0qxAe6v7n5o0T/lfagcqtErrnwzNGXnIm4ypTXQH0
# DATA RGjbo36X3Ij7PfVh/7CfTdCUI34yApTufm3+JrF4myCZwhNRXbtd5OOJVWTm2UDr9WsL8nuP3hD/56R/TRpijUdKkGSGZbYFy8Sv
# DATA 9Bvn5q57FITDujQklgSMdHCxdDsCF8vG9r/IQILwcX0K9v8Ah630AvBlWN9NiJVEXjqKywJHTtOJuuJgvDd0czkqwGMw56KCTR+j
# DATA RIIXYQnTsO/XakGxbt92+8sAHRZJ7pzHdkNi/DCEoCKrlLL7KGtOjgajg1p8I06Sizpg8bUH6clBL8ViLT+TWF1nCaFIgZAm1kdI
# DATA GWas9io661Q4Qznxqy2zSW0ka0tLruGwZ45obGmgP4/IlUFvOsq2+fvgoqx1dseSnhcOoXSceswMlXj2LKKaC3r2OGYIo6W5FvAA
# DATA WTS0XOq6L+vG2HHsk+JRIZuglJ6Y6vViISUGeQsSuJjvOUFhK+BXVyZ8lW0+R7YKjMlKVXqmpFCl0Q0x9XfxKkYF60Zx2LGtld6+
# DATA gmDpxa/LvQwCxRe+N320vrm+vSbMxV/p1emqtwtrxRc9olKJFzfBRUVUiGxUgz4v6B+hK8MgnEtFT8SLXmzAs6j0Hpk4V8aqcmH/
# DATA pyrAHuMn0Hm6vvnIxbu11owSGfgyipui4SKwYXF8C/pEcE0LjdPu7wApZHM0iTnlFveQIyLNi+cX4ozXFNYGQeDb+hl4y1KLemBv
# DATA ZetmetTreOsS9NTnazE1Pt8Lx8YjySb8RXJfy9XSY/YvB16PnfbmSpM2GmtRFsabxtoZ614fjG++c+ir+Rp9/5ZKAVch4E2jc7Hw
# DATA Jq3ELRnrdLicHbJUGSAYdIG1of5PibAv3TyWSl6coCMU5Vlvrk2OZjDZT/FNTQA9t+MNYuDRwWzYU2w8UuQvHURAZDW7yJEwjmbT
# DATA COcN9FqQEwH6nDdNQl2oGTDGOyk3VosbDYm7BnrJ9lOjJij7gqTNyjICZ0VNQqpmxihRK7+j2WtMyKlzsf6wBATspUsTRsLEVG2c
# DATA 6tZgjq7wGW+bhTuoyXNDbCLNhxFgjb/Df+DLHDdMEkxTDa+b0PHC+acDXLzyoysFfsYdLzjl4Esni6M196s3Ifbil9FiqP7NKvBK
# DATA uxsPm6Jl7byqsfxwpjqTR2J3IlEMTmXd7H2zFaAX3j4tzJMjcroTUHdmq146CfwmqCotWvHnz7Ods8Xmy58c/j61U9iLZkN1N4OZ
# DATA hC0DVc9yRVVL5sSxiATnRJtG8Ic1TcgtUDUr40lfHQkBvExNL4K8nBRYx8o8M1YAF6TQgfMYSzBTwb/h0l/sj5KL4Z7bBpyBfKqu
# DATA 85NCh1YVyTfH1SScAVWbTbIiIPvNSd1fCltRnSoAyB8urog+1OmgIqvTgdXodNgLAbqm5NtpDXmOmrBvXP5/wFVw/bXusDk++8Y7
# DATA /t+K+t/d27fxX/U/59+bq6u3bt96Xz+j56ur779/5xvRyje+hv/NADtCNf+Nf53/83OvnV8n9dT11mr9Oooa11t759f7veut6yjY
# DATA TRV9UEflev06ZqlQj1//7ZufvPmL11+8+bPXv3z9qzd/9uanb37y+ufR6y+i179Tf/32zZ+qZ+rJ6y/hr9efv/6t+lgIPFDF/6le
# DATA /9Prv1eFf1LyVT1S//6FauE3b/5aFXn9a3ilGlVFVZW/gtbU//1KPf31m5+pbvxU/fs36kOqURX/7Zu/Ui9/8fqLpmoeVVjXW+fX
# DATA dQ4V1Yn713ojhIHApBcPnj8f3oc/ooGSsNrPn1/Phuo/D+4fZ2nvwf2TbJpihqI8m8JL1J7he3wDhxYev+xnpwCLpP7UGjR4fNrv
# DATA TY/bPSVVdrMG/qhrS0AjV8Je1l61dR1Pp+MG0PeX8OlDqqWxA3nL+tOzxtPRoN898xpgIayRT7rR8zjPBofP43sRTbn/cHo2yLxn
# DATA /ZMj5wm6yrXuRaODH6jl51dDxbSg8EGaZw3VF/EIQFkaJGbZp8XZEZvA6/9a9LKfz1DqnWYHo9GLCNPVKCn36BjuJMeKkRyPBr0c
# DATA WeH0WEnGqWKLUX4CgjNdJiChcgTabvVcsaWTKEtzME9MR8AUm9HOdNY7w29Hk15/CLBLjCSrBDoQqU8AEBJ7jVv9wVNQbYN4cwje
# DATA I9GPo38362fT6OVooES/+8tU6D7660yyAQyj36WRqe4ewu/lNFf7JV+G58385RG8Q5kSyp6o6pfVw/denQywVVkTrlJ+nGXTUH2w
# DATA BM1unl/yM7Tz6c9oKQBCv1DkB1ACBPts8uD+MhVUf+BJgGMC6f5wi6ASCD6XpAJrV4dloKrEPr3oj2VvvgnsCwrtqBewOrwP7i+n
# DATA dNqgVfH9AVwsnOFY0x5U466KqmOYvlQySj9tDNIDmpYnIDepx/2jlDcftFBS39bLbALnGOsSpXK1f/pZbsrtjFM4wBE/94vDFjRl
# DATA t2E/no4mL3BtsOiy6g9PKgyYRMMefKrn5z6nZrJTMQZbD3xBlGn1we5xqpZwDDKxCWhTW1z9rWS1YVNVv/rg/lgVyyL4Vh2Ps+g4
# DATA fan+GL0E7S5k/jvGAwCpHPE1rAaKmbBTR81IfauuzegOpyRxddqmcMTORjNYOvhYK6r00VWtjh/c7/Vf2n4Tacj9nXEwm069A+Mu
# DATA xQdKyNTNHGTq3gt4uzzRXi1gHhwNe+pUO/UtsmjLqq+wz2m2A9POD2jSbz7YmkTjvurYbKwmSZGWw5malNFoANN9E6b7YTroztAc
# DATA eTgYofSfpeTfHSG1j3qT9BQoDvj1wQyr9TKbI+qNMlrKXjYFtEJ1g1Cy6wzOluo42H0RuAaBjLojJaL3QQlOs36Z/WfGuwwb7sH9
# DATA QyXKw04cuydK7S45FaD1pVsC1GtzR6n6VMEHeu2drthEZPDNGlL2P0pPxvdAXn+Zds+gQ9H/+0/RpfpPq6Z7vQxECc4T83LF9G2z
# DATA f+D2f+D287g9bcsrMPl3zOOvxuLnc/j/gRj8O+bvC7H3y3H3r4W5046UwzcM/V/OCUKCP593Kko/yjPNQdc02yR1nmoRubvmn3LI
# DATA INekdpijQw6AVGNX2wrVKrxEPAXd/gSZLyrwvInA6UGRRrPgHNVpgyydIJT/iWLaamcN6siA1SD6J1kvOpj1B1MYAdDHnIasevos
# DATA h09Q2tL90yOAFixH72p5IPcFAhIHRsPBWTPamGoZrgt5voHjw8QptoWaZmvW1qJA2gMOg+pF7CIsSgPFAjjreY44RtFOlr2Ifqj2
# DATA CjhraePCcTYYo64KOhmlh4ewSiCQpIfZ9MyM8LPRbGJ5NA9NSTp5NJkNjah5AM5O2aQZrXOiIZhSGMdsDNIKyJl6F8Iez1GGUQUg
# DATA hcIIhCRFHnIokw7Opv0uSjdqbNlkCjb+IzWEFPwvtGsb1NU9zrovUOWJph1Uezqd+e8/+d9yHitoedEvKO+OxqoelCfFmjWjh7D+
# DATA EdrlEfFCDewMRv7/sfeuTY4cZ37vVymHVstuEcCgCvduzsjDm0QvSdEcSgyHqBcFoNAoDYACq4Duac1OhC67Kzu0ceTwiTgb4Qjb
# DATA 4Yhz3lNa0aYpiYqwv0D3V9hPcp7/82RmZRUuje7p7rmlRLKBQlVW3vPJJzP/PxUWnkBUj/GKaEolNdKBsseV2noYU180iSpsB4Ji
# DATA AkNZ8naWx5zaxIILm56hO0yOeHwwQFWs+b23k5OZmHnISNlZNqAagx1rpahJPZVbMhjhFFVq5ejhBpFU9HGSSdFiT2HKJv7DKJrn
# DATA jTocDGD7TxI0hsGArx8hoBgKiRBe4syk0QPhZDXvw4TvW3Kp0e1RykWGvDQtCoHOEeFxpDsJqj4foLeJF5IECtpuLpRjS6rcXM1V
# DATA a9WtMnpExiKSeEKBmawY8eSlUJDvUYzNxqUM4h7YjTeUDsbD8RIqoTTW50qHIaJY895E5yN7D1AkKcbFiPoWVV3pPTi/xb9JlVLW
# DATA /pWnObsNNjvNcHY0k2/N2L+KrX8Npn7RaCJ7/zuP+8kjMl9+BnxNn2tpla48wUOPyeJJJpNqP6K5cJykB9mUgh4/QbiPp2FKteGg
# DATA fogVjqMUrp+D4zDdq1bn4TxK9w8HyYQekUtkl+0fov868DvzR3f8WrvlyS8Ia/8Qu8ypyz+pnqTh/KBPNfBhldI2fBI+lmDiGTWQ
# DATA eHEIbf/qEltHydaLqsloRAk6qAVBNH0SHowRzmO+ZwgWCDeSKlX+wcMZtd2DYP7oiVSSSjybLxcV2b9VwRMYax5zFNW79J01+ft4
# DATA GGc0DJ/Sz/zq0SR6dEijxdGsylv+DgYRMNGHP6XWGY9Oq6p96cs0PyWjBePqQbM5f3Q4F+PggHKC+kzPr/n4eyglcODPH3kZTWmG
# DATA npV/KxmNzmO2KOY0pVdfVqWZhsN4mamf5UuFYiDlUT2ROLVb9UOaSmUUzjxh3vVhKRsPMIFReVIzTUznTn7lsRVN6qZmmeyYWqkO
# DATA Kqgfs4WKvdxZNLyLReefPF5JKCffDkCqmArigEoGo8rwcTIPBzQbPKi1Wjo1ag5IlWNEBkJWJXswxgikHi1e5EpRuiZVpHRRV5jy
# DATA vcspNYvT4tXH1LRRYw4apULlu6juy8+6LlPRPJF4UH+992OeIvEwTq3yJ/vWRRRl8pP9lTrMM+kDv17/dqHStanSbahdeP3+7u04
# DATA r7qoubWOVXF1ZWvoRJTiX7EuSvxVdANqmocqqvxZKnF1tROhZlfNxil9Oag/KQRHtvpPHuvI1Z+YDLFywe/WKWyqbPHPogO2nGiY
# DATA esLzI9O+j9J4eHhE3VCtwSkrNJN6Xe6ucZLMM5s6Aw6mg1DK7d8OtUmhjkBdoPJ/vLWMdOr8WtDSoUoGUryiIxrFH9sBd+p180jd
# DATA qzXpkSdjvzIOKuNGZa668OoimdPjY196P3kd5lcwkyWgCkjLGO+m872g1sSrK+1a6/ik0qrhyz716PWmiqnKk/3DCVlCVCXgdkUE
# DATA 5FfqEpisUanW6o0WPXo4DR+pNPjtwfhQRaqfUPucUkIbHOlgt8j50p1WGhS1gDMeUfO7F0SN4hK0kJ3Fd/ObG/Jmeomncp1CbJQD
# DATA LD7JLeMJMlgnrd0ZjJ/E06NKdnxkag2T0A6t9qoqSLhcJE9kTlzhfQYyoqumAlycH9SpIlcwYdrDk17Va6NPNxGRQcoO6cK6Wh64
# DATA 2F1OY//iJIpmXJP9WqtUlf16y3QrJtvW1dwnNfZeSF52JC+bkpfBal7qXAvqVCHWjkM0lygmiPsFth7wH2l4gRpa+e8TdodcmAvl
# DATA drrp7V4oI5fy6t+FCfyTsulxYCyVw1KzfFKDN+gxxBP4xlH8KBoe/qzKPhhK9yEaZdVHKR+CuEE5jYze0EWbbgHp5JBlCHqMUPDk
# DATA kxqZNInuHKvCDGyj7Iq9Hv3H7FlD37uczrIDf5R69O+m/o0bKIfv1chyoNdwWrmL1WZNXqTNFjUEuXsUHy3TyBiS+dVByN5QK5xa
# DATA N0jz9olU1br8WjWVuLgudEvP+9JGa8rgL2VNq55Xa757fZ1WD3OHVIzCzo3JzlTqvle6v5YdS36RR51h8S7KOpTc4x3KMo3mNCvc
# DATA a1SonlOh7NUrVLLUbeQxelIbhOnwsTWyWKNOm4f6ci3MlukIR7gvsC+2m6PyXm9+gNl/dTCOJ8PVZPItNbjPK7Xpkialj20Dga9Q
# DATA QPjdrjw9ycMTbMu3rYHe2ja13nxuUSfbpH8b9G8bplWpnLh+FgqAfXbF5rLBUDcDDAIp9YaS5oPZYix5shfM9j2dlk0lEaxabU9q
# DATA xm9aruvUDVCy0EmYWzxlDUgGmoEfQytGfXxAiPBVWoNcp4u2zVc9e/Dr1HGd0hMvdqmjlJmqx9HdS6GVMNTmSQ2+BWPtBTdZL/Em
# DATA XsxZNRH12FIT8+0SLTBY2wI5LNkM+LjQWYm5Z/fznqpzW+qAShmPH811M0qrLTSkOzoZ82FJ9FYHNCnjXlTH6ICSsjg1aeSRsCbb
# DATA 1gs2dq2lrWbV/ALpVrQvco2l3bRTVz/EXVVewFFvyf2Yk/jxDuZGaY5CPQfNm+JB9NjOkvJ8TDdH3Txk3K1JodD08sgyokzU6zsM
# DATA E/KsF2K6QfPBHSpJoW545luAb7DpVhuEPaYU+2uvvpuBVoylN7cGZvVTRoP77OhxyW9ADSQ8KntHxLTdUjdNAQUyiUyLdabbXp1U
# DATA bmia/bBk2+qWtDK2luyCchcuBoEK0pNJIR458K15lt/knlKaQp7RZefNMMzGUTGDfzyOh8No9pNCA/pXggcMZ4sn1NweGz/YIzbd
# DATA 7bkR5gf5+5oXNH07K7ubGnbJ7RbOTk/ghn6CtREp5VE4jSenB2+RiZXQuFz57LX3477e+/5BMks+e60ypT8cbrHNU14OaRyOJ5mV
# DATA TcHu9VH5Uh6XvFJlp1XJXtfv9AqzW27CahJ1UXM9LI6OHONATXzyEBv2cL/O6NzBACxX+W4eS6v1WXWghfFV3VBwa/BMZTf/JPXY
# DATA ube6NBPdUB1q83gyqabJycVWtrKpF9HclLruRpv5T+jETftvqg56ARceh1duBU/4J11w1EVOwnlGVon6YE+g7RrIA/NiXFkMZVrG
# DATA eXGA2BTG0Z0q42KbrfWkRjGIHnNPLh34gX+n6vPYaPmILKNBbIZkuZgvF3wioZxZMqfiXfpVLNussWZxPC1cJOljPeyus2WlRuuO
# DATA zlToJ/96Gg3jcM8y0drUre0/3uh0sD0NjTb6XuVVKLYWZZOsjk5cWeQUBaa7kk12neH56cb5Z6lRNjBztbOyOJ80TpcW99U8N7qU
# DATA MaaN1c3xsV++fgrZwGJDcYa4Y7asGAybp+XBSPsYW5aVoh+8Z8+l7OoZlMxnbcau1otmg+sF52FFW7kb48NuGXG98KjeywunMKEI
# DATA xE2npprF4WH31O+cXO5E1sx/uCOnqmTSPeclzayaRsPlIBpWpwkXi3yl1rFuTYwD/07lOwey6YM+hCO0m3AWT3OXUT7OH/KiSLzm
# DATA Fx0NOZ2j26I0w4pejCo7PMQ+5tJU5ofl8pWVOqtXYCtAzQ37ND99aGYb5ZuePCmsGOpdW9ghSH+8R9PJjNc+sS/v4M6dk5OT2kmj
# DATA lqRHd4J6vX5HbfDCBqI3k0e4se7VvXaT/uFlX9R4TzYA0ne+6ElHln9P+Tk/wOcRDUG8Z6pRbwybPWx8vPcGy5XwbqEP/Lbn98aN
# DATA 4Lj7/aB57NfH9N/u9/32zwoPj4JRY9SQhxHF4qpoRiNk9PSJ7NJEnibznIJkova38Y35ZiyquP1T/ML75vLddWrzk7lqLzof5Dt6
# DATA zB6AaMhr4admA56VJb2612y2vEav6QWt+qRRDzy/26g26h3PbzaKGTNsD/tRfTVXOw2v0W38yO+0J0HgV3stL/Dp8Xr3mP6+j6Bb
# DATA 9aAYVDQa+ZzHPF14yOn/VrPVqrei/GLVFH1j5aUItesfNwN/Wq8GfhOvrPZ6HBkVEc+XWnHFNwRB3Qua/rEfNCa+73ut7o+CXvdn
# DATA HzQbPa/hU/UJuhO/3qk2Oz8K2t1i8rqDXhSGK0F2WpQrvbEf1KfVdp3+OcbHJl1uNLtj36fLrRb9c0wfSzHvt/v15mhdzJsba6ra
# DATA vkgV9QAnCx8rT/CBquGHPL8/UI3lUE9tD77VbrX7DVww3id6hP93aAya1SvBwbciP2pFnUPlYzv4VqvX7nRah2JhHHyrPxp0B3iC
# DATA 3c7087DdCIaHsrx/8NlrD6KjJPJ++B5NFz4Jx2R7Vu7z9rGMusJqFqUxntVd2k63o3uqYbclmUx5l34g1qQXFJ3OXTEEzO1mNFLz
# DATA m+9F1KbjsCJBl5bmDsuOMBhnlU6teXxS6YgjjANWO+V2md5v9W/RTLUYYtlRbpt5qmBWH9A+9OI4UbhrXrAqxeTkGzD+DGLsJHp8
# DATA ieWBfC1APIAls0icVvXLGTceXLTljRhFr0B9ozFbSG1lJWkXGXfKs7dSx9hsuElL5clqW/8pmvpnr2H3HnUS8WDBO8lnvAHS+yvo
# DATA i3l375ktkLXPl1F6+oD3BSTpXrZv3Wtuvp+m4WltlCbTvfXP3Z9M6FHrWbWX72+iU0gv6mfQwmvYDkix5bml97r32WsHdgSn0RSn
# DATA swU79kE43+NADSuc5YwfRqcVbxROJqjc+95jHPin/0oAIpPPe8oeSCRApH6PsnrPitTr0CjbPzRUYaar0EuXk4n3XW9PYlEbhxle
# DATA tk+X1BUKSq4cWBE48HD0U7QIWGz/0HuCo8qDMcVKveEyIeLxJ3aq+VC9JFuhYh/rxzN5XP9wqPKikP5sQ/orEm/UktlRPDrV2CqT
# DATA LdhisyYtIxzuXo1keLqHyfO+KYoIArV/tffZa98Sz+9nr1HQEBuKJkC01nC3Op1BN+LbYSnIcXKyMUwxRi8d5mw53YuH+3lqPlxO
# DATA +1G6x2F+BtE/+rWmc7Pw6FBtIt0TOTcELnoW9KbPXsPXO9Sc49mhPuYiZ1xey2O/TBH9H378fk12XP6Aj4fQd6i3eW9CQ+/HCOcn
# DATA Fe8xAn6CwpBHQ7shydPvTCLWy/jstZCzIaxh9x80a9IJvun4ojVRjHFpMIkHD6lNYevpJ/E0SpaLvb19tHFEKo2OyajII0XhgPtO
# DATA 9qvKCokK1jd0KWA2gZfb+ZTMsKF5bzRDwlE2eICF8KYQ+njnmCL9vtJaoTCyZX8aU0FWvOiYi+0ePcYfa1CNob9vy8asPVXUHBBN
# DATA x2kq9CPQO+LF6d4+hT/DDU9UVP8K0fuxHLgIj6OfUCRr9OA74WC8pzZ/8osmZDRnoYjRce9CEcJXxOfHP1Fv/FfSA8YZ/93jG+iN
# DATA +rkf/0SXEuU/dsdDl3Nfwpfrp6xkyffXaFSZLIdRpqKRd4j0K73PbJJb3NfS9ihha+sbovaAG+3eKdQ6zTPFyo93fpcq5gNJDnUw
# DATA 8hnnjZ4c6qju5Y+vKRuuL3ifTs51ZJX+vEN2UALkLjKqaWq7d4xYgB1811t7+4H341qNPw8r6+4wBUUWcIZkcjy4e7USI5EuZBF6
# DATA t/wZk61mH/pyPtSbyQsb+FW+v6m2va/f434oz0hYvKU9U9vZcSaUDIrjqMYt/In8W6zeZsGrWMeTR3kF51syXWz0k8kU8/DmIpSH
# DATA qQxNKChEBLJiA3z22rqdfHa0+HeJGH+UCHAxSPB5fZDfdU8s39ZVUT55Y9dRZYLkGrmW/bIt2gcqLp9BwnNKtofUNhOFTTVnQ37q
# DATA CKjao7+SfTc7oskgTB+PzXjPvJculmqZbi0b6tWhOVCxvmah2uT1RtUdnT8wV80Izd9UTy430KhPcys2xvgW/b3c3UvTfE+0TE32
# DATA cyazPjGH/F3JRe9v/5ZijQpB/dd0j/4k7ycnUfoWZd6eyWJqCBmLr+lXFp4mKwkJ53qNExN0X/3QsxoEMrVY6eiCXTVYdBHiPXTd
# DATA 7jSLsclrIqdl3/vrv/b2dNTu3tUxQaQ4IFMFTL7dvauSgvqLW2RZj978rzgK0tz4476k5fXXpaCUsYOVQ539/CU3d/BtX+7Ig5X8
# DATA QO9Yz0ckpVQkZYgbTCDy2766pzR8SFhcSzmGUcYDB5W8LtE1jZHbEdqiVSmQHFOOWxtw4SF6EeKoqillsg5kv1jjcKOyOPb2795j
# DATA m/Gz1941h8LQTF7fg9n32WvS9Cj935HvPAfk5r5I3sW2ur1g/3Uk+H//vvYZ/W/2tp4lJ8mCXa1euPB8mrG8LgHwYTMKgB5a/x4y
# DATA nu4Ub83f5fO7/s8/WQ/qCO3w3GAqjVtmgPmBTHcw2x3MvuhgtjuQ/VIfyPYK243VOejn+qC28Zzxz4UTgBPr+PaDOavlYWSLh4CN
# DATA 6NPb+e28rZjPyT1f57lflFONFwm32I5Sjr94nO+9QT1tuRnqRTJEw6xUdGW9y1rBkwvhhL8VD6qXF6+kSQ8SZK686XQ20NFQfux7
# DATA P1hZ+2IzleyB0sF/6xn+wungDJjf46I9oHKHHgyVF+yhdHGKTcXm+bnoBmTjkE/E6hrlqQ0XNC3k48jLPo1rHry6HuYgFObnHA/e
# DATA pRQnac37wTya8TnfEZ/dp4fUYX6urB6FNUatozrpyTYExjDhbnozGAsU0EzpBuyovOOVfNxaR4DPE3O0yVogI/sI59KMDM/f4Jgz
# DATA KhxOdzPRwftoady93gyXWf1I3hHTT8s5zIas5sGW4h8zNqmSEZw81GKGsNRUsyFzOWEJgNEyJStiuaqG8HIetjUhOOvNWW8XWW/F
# DATA Gub0dZy+zmXNto0G4k3p7jzAFjZLDgKvgW8TwnlGgefZabxtGy6xu8+z5eoKlhyvf7D9gUURtSVHX+PCRickdiz7BHQmKy/g3nT/
# DATA DfGJ6gY44/UoFJKEZp4z3VV+hb1ivP2j1uJNRFrDmpLPG6JwcRryfqOW2kwSzXn3UU169jscx1JUxQthqgO+7RBR/ZSJp7lgotmo
# DATA ta8xmuIZoZ+1l4YvvCGOVhUpfY+JlHnojYQ7/DxyAd58zz8I6m/cSZRVWL6npe5pbbnHr6ub6EN+1x2JVp4UZavr3FSrYPRg3gwW
# DATA tuQRmQ38BBsS6ZTey3uCVTrVaihGL10180vS88TH/KI5jdMLyYE7EgTmTyq3ZJ3WDiW/pHeomSv3LIMzxITM6gBsaSo2GqXZLylV
# DATA EH4xBuUHNBhS/yxGo/ZaW+0fY2w045bPhqIZaONU7Miad3849PhMrDILMj185jak9z7WUJSqJyYCZqRdQjZdHL1slIohTj0O3ohd
# DATA GPS2+XIy4R+XWIalQT1OtfH/wywS5R0RsRHdn7gfUxaLxLwWkdJ1Hgu2GUeBzBIYFmxKoyfCvCbOMC2kJM2k89MqV2yvTyB8b/Vy
# DATA GAP7EetlcqZxBy9FwqXx8lvN9gDoDGdnOF9kOJcMJGc5O8t5uzn8HChWfkJv48aRiWZeOFStITebS5qNGFyMzhsrIj6MFlSgsyOR
# DATA titKLwoTLBlh3EqUBGSulCh6iGUjueSfxXZFKQW1ZfGNcYP157SQs27sFOOGuMyMSCUsGOxTgt5iKNFlMexkNML2L8j0cV+QeePk
# DATA hH72qIRkuOS8rnnKuICkJcXuGOMu+plkxB0D57klXyk+K05OcdBbhOzNvJ9iuJqYkc6kyE7a++yUCwdk40BI84R6rDxlGHmrPGWQ
# DATA DdGMOg0nGW8Xg6WDJB6RLZbpXm1IhTem3oxLiZMpp3wohBmLisONSKbTkcydxIjR/rJkSlbjQqkLhrAKHnpaKWRLOt8OT7kn3p5Q
# DATA lKG4KlHGOo0PlP9xFEWUrGE8Ymk/mt3BUIPAIfYwYh8CVauFbMFgujH9gqaIX9gE9D5hDI/HfEEEyJYVM2XhGKSqqBNiLLr+8lQq
# DATA 9ekC9RmbRLck8uMoW5NAMSsKVXhVUNVUdbJS2W95AlV4VLIJmiCPOmm0zohFkVa0HQnCWziMcfZOBjqxU5WYJNXej6H/MqRMJLuQ
# DATA bT8kH3bekowJfuKheFy1S5khZajdU3mn2JN6Kq2lTkdxOuXFkXVzW07UJ5Q3Mh8Ho3eOY6RkJhm1dWpBxnrOF78z8V/L/ZQfXB3J
# DATA FFDT8zATW5h7J+8DLe5JvSvDHtiUViBu40OmxvOQzWNMDcjwpZIOl4sY3UaYsk7XVClPsvqpdCjgQonbmCwEXFdTio2p/ZtZciL1
# DATA E62Emgj6SAi26gS/nXD4C+yrRG5LW6QEzeFK4K6RxzaxSyy/Aho/lTK2NMQTA9dKebqQUnFT9pGNRBkmKaQixwFp7MgIVxRkC90w
# DATA TxFmp2U1WTOfsGVlLTtfbOaX0Np/8qRiGDqLI8B501OboPP/nf/q7A9n35z9j7MvFSPny7M/0/+/OP+td/bPYNrQDz+nf3+7is75
# DATA r/TDV3TTV7if4Td/Pv/N2Zceffmdgeh8TYHKZf4K0M4vz39T8c7/jp6jZ3Ab6Dnf0Jv+yBiff6AfhKnzx7Ovzn+tI/MXuuUPAuoB
# DATA bMexdF6A2Qw6ZRxfog6nT38WBdHsoyihcNJ4oE2wmvfOo/lExucJ94iR9A3ZOJ5TbzGxvBG6c8Qq4jzKfQb5XCiZTNT4RC/VMr9b
# DATA oTpYTlThqZbi0DrF+Y3uQW4brLOuZG4Or5NXHXMrTLr8cvmBiehNm7vfl+88ol8zYYfHNTWsJ2pzKwZTB9jZsdiuH7GDtfeIrU8U
# DATA TiV3MbLxi9yDQyaLooJhOqbxhPOR5fazBWaqpd3KGqmJIMyhlHixwte5uPptdmiuaVnPCrNzcTIcZ8dZAjdhCWjgzhUNgFfEuXlr
# DATA g/+NjP07Df2XHflvZ+CX6rmaDzmD5/lrXTcB47FygFE8xVevSe8qyINeN52rlURVeJRnKV6qwDeRZE2m8qbiKQlsLx2fLsZTDkUO
# DATA mHAG7YrgUUWWL0RSRzxhvMwSK7VQSV8gtxfKPyvH5EbhcYJRQbFmdIzxAoGb8HBKD2qLQZ2rO8ztBSEWwfcDM+IknC1st9ggmTvG
# DATA jmPsOMbOTTJ2dh1Vdprm7Gol37LJfxWL/zoMfkfbcbQdR9txtB1H23G0HUfbcbQdR9txtB1H23G0HUfbcbQdR9txtB1H23G0HUfb
# DATA cbQdR9txtB1H23G0HUfbcbQdR9txtJ3nibYTtMKr0nY6o9Zo8ALRdlbXnndi7nDuqtzDrkyP39VuFxTSWs1Srjfb3SI3J4q6IwU2
# DATA wuFGit6AA220WQZkwKEGEgxLZfjNdhHi06AMX4NG6jS9ZlD3QLfxW72J3617QbtE7Wn7rVa3v0rKaTa8pt/7kd9rjpvd4yBoTf2O
# DATA 79V/5Ncb42bnuOEXozAIhs1+f00iWt16ngg/6JlENIoBBL1g2Fol9lDGes1OMFa5aNFzzAMr9Jz2Feg5XGMteg5V/gI9p9Xshleh
# DATA 57SG0cjP6TntoO13hoaeM+j2R8NeTs9pt1t+9+bpOaqOV7kam3GhIQQdPdwWblrnqGrwOFLpHZ9UumxJFdaYWoPx4c6knfLblIPb
# DATA dm2JiaHuwtGC68Ht2CGu4nbURLNrjFWU8SHv5BiHw+TkoO7Bu1H3dEkWAD3crldfod3uxjTvyPpJIddLNxXWymQ4L8FwDjfsB1gd
# DATA rRQlaZ2nVtZtt4Ssuho1tOmGkteMponfxa5U1WdspvgUSvsCG7GQeXZhqsToyQusEEfZcZQdR9lxlB1H2XGUHUfZcZQdR9lxlB1H
# DATA 2XGUnVeLshOPxH7Dugdq/GP7m9Sdu2rEVAOX/Fbhurh/+MTC9DyWfENm3OVgcOrIBPM6PQH8zmevvb76DlWpD/WAol6yemN+izqg
# DATA QXexnXuoIEEf4hiXtHw25SenfDpHv7UcpZr379QZeOtQGh88Q1lThTJRqOob6IfvbhvxrykrjM1sksqLU7XFo0WeZuodP3vtfevk
# DATA nUkGdZcqBTLRLZ3zcUfQ3RH0nY+gFw+EubPo7iz66qnBjXqbz8MZ9VIdL7QWW5yGPX8sQIvKnOVqKUr4Nh5GYVZAt/CJaChbglzE
# DATA I01G3ZmcE9ZKKryVrnRadtcz6JwE1mfEWM7ifEoSlF4FF+pc9Pj6LLuI+K05DKp2Wa3q1yvbFVWQPyk1eCUcrn/M9czNFd5uC/nP
# DATA iMMx0YszK6s3q7wbg5il0eVzUePdusN0n/ZTKwrtsChxuBMdmtzH4q6bBN1Vl8phfU993ny3HK9nlTv+tPlO7nOVzOwg2nyf9Nuc
# DATA fv60RVReDppqOXexQ201dwwxW7TcCzUB/nNb1jX/Bd567ur0PEA+6Twv51lJbJPd+qYXEKuaa1665Nz4l3/6jyYd5Yhb+T9niVL0
# DATA OZNwnuuvqqVE3pOWLiGRABstYSmGGZTgWYsaaqUx1UKGMoXzOdVJ1teljhmtjyaxs4Uc/4ce6wL6R1qHlrWqefFDi8yeUOVWh8WV
# DATA z8tumfnJZ9008oPVxnGGyyopJmf00Uu6wL5gril0rwUCKKu2XqqI8op62QL6+/++uYB0pZfieQ/FQBU50wX0yUlCbTSljs3Tp/wy
# DATA ZYJQn7ScwRNJQ9K85r1HozyMnGlyLIIUlAYWHICwwVHE3SoKSPYPq3KKtLqFKq2nLxWTglsrF9MtXLZY/vG/bi4W1cVIqYgc6CBJ
# DATA aTJiWs5MTYTlMk9z+qzpyrrK8smbh2hYQzEdRMF3RH14cqKKqGhHsjQ7m8WFcdC6HC9gRD99KdkpurWCyvvlS/dwv91cUrqPl6L6
# DATA NEynHu/uyru4E1wTOM7wGFrYVDJHVDC8foG+LpLhfjYUKY2I1WOhMx3NAMGRElCzgX7E5I54IZoc2B1r/8zUiacvnzwZt1Y6TzMC
# DATA /T//vPsI9BYG2SiVIcHSAZ+yXU3xSh8qS5ubVDhh9fLQmy5p/JmEKfbJzSGfjIz2fiTGoxpgyEQCw0CaDUr86UuiEN0Xoan8p12b
# DATA yoNktPD6qPYhSifv1jDG9ymLptCygWbMgEYeTA5YEToc/jTE/hxV4zMUVsr2eDyNJzhvgJyCSgVZ6p8vY1GrgQoiC6tIAWpF6Gto
# DATA KoVkXKmAikageDRtI9Bckey+92GifY9aU4hnH8onmKRCZcQAnXAnrgtWCf88DTvo1RB3cXBu50q7givNec5eEc/ZZXndz4W6Y2H/
# DATA 5XZst8y5aSBdYKsmWZRH7NTaSO5+TlUgXyDRtIu0oe19jzdB8V5tJdfO8l4rI7qJ6L2acnWbUccW5wsmQTXPN5LY7EyqiO9I1CBP
# DATA EuO4yJ1MitqnHMJTQLmNzF9e0BVvmQm+FLKAFAx2RkgSsrIW9ppao/S5uU7meppX0gL/EJ6u2RGggQIYF90eIwVuKQtq8I3SzDow
# DATA cqIwq3NRUVtJ1GOfCVmsCyktzHtgfXvYiAu9zeNCfZDNbJJZvF0VmqizvMGLdqHOLeRw7VUyHu0gnPnozMedzUe7rrl1WLcO+5RW
# DATA 40Yj9WbWYT8Q7qetFJ0TD58NqeI2KOG89wfVi48NFpY51U85XlvdurJemC8k5ctjm9YW7eUNe7Vm0/0lR3tpKWHTUwX3b8GnvemJ
# DATA spuy7Gbd9FzZe1b2Cm5cOS2UAm+yQkxRnYbxkOuDLDR99w0tX6mKRd0LfrnsORWWuDpnqknn5UVwHDLX/D3bovI09546ddumEpeZ
# DATA fvUOFHHeVDA9LTSgFxchjoWmBZNQ5+jpM2WpJhP7LdFcjycy42QTPNIzKQORpPZjVquWbCpQaPQMnntbdyToW+zh2VMCITwBMCa7
# DATA eupTWOLS98i641Bcy7yvnGIC4W4s0Kgn7iSrBZfPG9c7jfO6lu8tBMdT91FU0qUSvpgB/vJYyRYckKWQkmmBDfgfFcTvm7M/079/
# DATA OvsKGL6vPHxjLN83YP39+exLQPlW6YD//ewvTPz7vbr7q7OvPQYF/u7sj+f/19kfzr44/yU9+0cV6NcKIfj1+a9wjX775vznHn0B
# DATA kVBAgCATIg7yHICFzA38i4MBvghWf6HvHkUnZDvwJHoeQrpWQQDQq09HkI/oQ7JLY0Co48Oq7H2F1U36zDxQ3XNfd1q6z17O+TVo
# DATA QhweGRkD8Z9Ei+V8KwLwPqQuvOEyw2YXas8OAFiw93Uvcdv8v9ViuTn6H1tYTFjJby3UtzLP/E50Gs3jiKwNff876oIHlSEgtJP0
# DATA mjGArB7GSOjlgsd/dUaLmpgjAe5ahNePAqS+Bovg1OZn8QidDsPgGeKM7XJp8ggaOhGfXRZTHgYraiF1boMFtjAsWfpffszU5hO9
# DATA 90RXNHGpkiXOjBtM4+Kj2QoWcPdqudnWWWl4zwoOuHtiHCTQWQjXZyFoNOCVDINXwwl4a0bBDdgEO5kEl7YIbtcgkCpazg5jBjw3
# DATA reomkIBWqtXy14YoargYuy8ennpHaThchgr6l+WrD5AxLK6xMWqwuChxKps+sTR/zK4nrLWxLGI2jwYY+Y0pthMc0IzrrMxNCc5k
# DATA Hx1l4Aj4Mq6A1WRUReXkfpbqUM2Dii2Oz4ZiOcBHxwQ8FQfFVkPy5yldyngtVZW2Mt9kkZAjyzea7Kt5H0YAyMkF2bT3YAkzJE2W
# DATA R2NvOaNiWsgZdn5x5jCCDiPoMII3iBHceRjaaZJ0WYP6VucIV5kiXOcMwVEFHVXQUQUdVdBRBR1V0FEFHVXQUQUdVdBRBR1V0FEF
# DATA HVXQUQUdVdBRBR1V0FEFHVXQUQUdVdBRBR1V0FEFHVXQUQUdVfC5oQpGnWg48q9IFfS7QdQMXyCqYHkFeiemYBGe12ta8LxO3cDz
# DATA OsV8HQ6i5nC0hr7XDmz6XjOn77V7G/M2L5ipX+96gd/xfL/pdTter1X1W4HnN30qL7oadLxut4Tl67R73X53HZavEGXeh7kaX3qh
# DATA hTz0Oya+rSJgsh61B501zwdBkD/fqOfIxO5uzzfklSq/WkGeX7s932xZ8W9Y+b3j+1tdC/nYbHQu+36/bZe3n8e/sWP87foiZcuP
# DATA N3d7vN2xk2/DHnfMfnlEJb/du+z7i7lX3+H1l4FESiPRkEjpyyxI5KATDjt+ERJpHjGQyKDe6Ld6BUhk0G922q0cEjmoD+vDkYFE
# DATA NgftbreZQyJH/rDdHd04JHKG/ryaPTzN1znkCOVxdA3rDoHl6tA2F9sP5rXaIiyYPvIyms1gWr9mD4vKcDuYGrSLiva9FYp9p7Zy
# DATA diNWFiKqFz0UF1FKUN+jsuTxrrlWa1tUQ8/OFnWbp3e1FPNGz1qxT77gaC0BHbfsUFD7ESQd1Yx+mEYHEL3cTGk0+VApJXeL6Vcu
# DATA 5MrW8mJniikysQdXqomYT8EuOcUhOAqko0A6CqSjQDoKpKNAOgqko0A6CqSjQDoKpKNAvmIUyFWI4zQ8ugtTj3p1nDGjJN+Rr/ok
# DATA CzJBIRc/sBUF0Kpep6epLryLDZF7/v7rn732f/6pxsTD+2t1BviZPQk/nMthA7yRgtk34QQI539/IeG8hRbPx5em4Ww5ClmnX051
# DATA yXlEas5zOfqGQ1WhIBeiR3QjH/4kcyCjoa1ASCyc0XGn793p+wtO3685wuXO4ruz+E9zFn+jHueNntEXRcSEDyLnx71lWPmu0ed8
# DATA 9vIxt6HVKaMdZFRNFEZ8QFZZnXvT6b6iJOoWOmMHSC7op4Mw3Zq5YBQtO62ikuQ0nsm6V12pTvIqkNKbxH4b/nUzT9EMynZVuWy8
# DATA rUBM1O1rJvZBa13kAyvq3ULE67XW5qib8d6Our6o6tHeMDpKI5qqX5ACKyyTAvuaSUF7bfY37Nz3gy2Zv1GhU7cS1GjpIF5UdU5r
# DATA xGUeIt2ZSmvWR9wLZh/mTYv1TYZeFePIev80b+T2DSyyL/L5UtxRtpCuRJ4UPKOpEnkYfHP/VFCOhX5J6w6wfoUOjfoRMgKVgYj5
# DATA 3lzMhmGMuR8/Bg1hltQ4CU9l4JHi5LE/08IaR8uQRpxFFLE0uBK2+Jw6ODK/cLReiYKsidEOAp4v34H10qjoLGtnWV9gWZeMJmdV
# DATA O6u6YFVvZis9T8pXxVYQmvwy4lc/BH/PqB1hFTvXOmI9GbjEK0a/SdDF0TTO5ixB431i6CpsvLNuTgTP3EnEZNaKp/dsYFSK5ljG
# DATA T+kR1J+yRV0kOK6IXZn7aOh/N1bSR+MkjX+WGMkbpeAfelk4Al8nSskoYgkmUyrZPMkV0lmiiEWj1CwiCrNTHnnHyTSCKA/PJsju
# DATA qwgnQ6R4cC+N1jSwxjAhuLPKKLewiqDUwLFVYcOUoWDbDCMd9/chzFPsALF1Qqn2gAeZd4jGJlrOQjZsqF7VvDfjWYI6RM9ozK42
# DATA BGbRowUbkrykggxS/WiSwW2lelhlAkkVmPLLLFDoOmNibdr+xgYjTJIjncKPcaJZyk2qVWHOFmNBFuofcS5WZLgLIuE1OVVq+dzj
# DATA Zw+lpuXjht4UKfKvGeu/jiDVzonQiqQMPWVcmMdnwYDbRvYusm2J+kjkvKRVRKdKMgsj9XzKXZikUVTBRH62n5cHOwBz4zRcGMGw
# DATA fDyivKAKS2mUCafSU6Iswy7XCfaXcFXGEZrUrtCnGXzjHJtHFMCCjMN4CBpszXs74SaJ4c8ok0EEThmMI3R+qRWbFQISW1YX6r6a
# DATA uPRDVdhLS0HfrKcYJqm5IoPEqVzQIvtqclZ8nn8sTr304lRhWlXnKZDqz/K+jIkFUnNzqL2S2X+q9/mGPDEJTxU6vGiqZNQTXu87
# DATA Ax5CGdczjKfS/1zvG7BN8d6HeuxAmubRbBBPrvctvIf7Hd2C9BKa3YNe7/taArAYRWbPEDU8tiVn1NqK77qznNwYg/blm185Eq2b
# DATA Wu0uGewmUi/9ROqy6NnnS0LY7Om9CYZpObOvnWC6Run4Yn7ppEBQEA1gdkMWdYW34HWfLx3lF1FCdEfcglfYWK6N8FxuVfLFTDZq
# DATA K5PjfNpb8Y6g0JzPaTAL80JMgLHVysxDBzQFtvVjRbUVk6ZsUZqV5t6EkidB298ioFuotWS9HEcXC0mjTk7DuQY57FQGa0r0ozRi
# DATA j3pBDTuLskyzCl8h0y0nXPXDh1FawFv9t7MvQZ06//nZnxWD6g+Mufri/N8zrup/eed/D8zU2e9W4Vb/GbQqBlKBY/Xz83/0zn5/
# DATA /puzv5x9ef5rCvSrinf2P+mWP9H3X+K7d/aNCQ3UrM3Aq1+Ca0X/dUyrF4FkS3UYz8PZQBWMJbBDxj3LEEHWVswjwRCuCciVq84J
# DATA czJxaczYacH90kiBeYZyKUEfJ/trhZFHPUfGnq6tCKs3sYEW7SRCZ+EAVrYBKp3AbdOryiVyc+wqSEIPS+9di6ziKmZufJsr3M3A
# DATA qmjUm6tNv6il2CScDMNT3kdI9eNh5IBVF5XbtXOq3kQz4BKYRynOirJiPY7jjRiwLacvPbLdoWWiVkGsLXh6vR9i+UdpNIwjeKPB
# DATA KKA+NUrh7cqXU1S/GM/IHFpKDnvTZSb9mZhhp0L1HsTzaIVitUtN3WzPlJres6JX7ZIIx61yVsCVrQCNqbrC4P9KeJ5uaeC/9nF/
# DATA p2F/11H/tgZ9qYzF1JtB/lk1lpugTxWT6I2jyRzWCRkeQDCbyOUJTseni/EUK7KS9AMZaiH0jhMuC/4AtDSyRVZHqcMEzeg9MvDD
# DATA YxonM50dqUib8dYDrMmmS9ZSpPhPY8MF2s6eUrsj4GGKsEQd8ZkuGYg59hsGc3FxWAYB44l4LMjEhKii/Q8L5gXvA9SbKBQKiF/C
# DATA AgpATdE/2FMBO0+vkS8XCeShBkzqcoApB5hygKmbA0xdNI7sNJfZ3dS9Rav9Kkb79djsjiTlSFKOJOVIUo4k5UhSjiTlSFKOJOVI
# DATA Uo4k5UhSjiTlSFKOJOVIUo4k5UhSjiTlSFKOJOVIUo4k5UhSjiTlSFKOJOVIUs8NSardaLaDzhVJUqPRqDUcvEAkqeLK804cKTtT
# DATA grbX6HQ/rzarfrfr+a1mNagH9Nf3fPqn2fPoazGHBlG332it8qB6HS8A9anh+fXutOoH9E9TfS2BoCiT64P+OhCU35OAKf0xDdwa
# DATA fdSw0EuNVtsqesVBEihREVwVNcOoFa1EtNnxvaBLyW55fiOYNrpVv9lS31biGfX7o7XxbKzWr3rLa7Za43bd/8BvBl6z649bWi/O
# DATA YmC1mkG0LsjVGttuUkwb/o96zWndC1pV+sfvTgN6DRVLF5+rQZe+rP5Qemm3224Egy0vvQzqSFqIRh1JY7NQR/16xw+GRdTRiP9n
# DATA o47oaziqF1BHI3846vs56qjTp6wKDepoGA5avVaOOuo2W3W/deOoI95hUmXTw2YJqcgWZ58+RkJP/kvN3J4M2EwjmRlsg/zwyJW/
# DATA eQf6UMEJ1zZOOFl6WwUUWWGvOuR5hJVtc/RQ9HBXOJG2NIJyAN4lxustj20fvDdCiKwStH2BnpjQm9NTKtwOSrWjiraYP5uT40hC
# DATA jiTkSEKOJORIQo4k5EhCjiTkSEKOJORIQo4k9MqThEaKI8RHryjBlZO7o+/IpfHpUFYPAfsh46aSmZ+ykC1Kvnpqrp5G1COry5o+
# DATA 9C7CZYLQ6HXKoSPmA31KMZSLJ0UQkfr9AQXPP2drf35vBlEkGAv0Pr7vdO19nySLcCLn+/iuD8LFuMZ+g73R6yevZ6+fqpttzlB+
# DATA ksUdlXZHpYtHpa1zTe7AtDswvVnK7zk4SI0zqaO8moenXojfC/LmC1Y+kfqMEjAS4ag3FfwM2bzJJDnZftZ3Gj/i48fzNElG+vwx
# DATA dMZNQ6XxF1tRlmmUPYW2OY2I6SmSsqAsQfr0ccv7Xraco1ONhqpFx5khH5Flo8BGKQ14qJ2Q05vECyziJDR5yFgJW0Amg3Q57R9C
# DATA Gyae8XnszByqHsHZe8zndz+FC7egYJKyprsoaGeDJOEnBss5ZLblXPM2Be23YEOkp7KPzuMhKk/aCCLrUAFEkFyqsygaZro7k/Rm
# DATA i1TMZSrHcTIZ8llXxJwSS3NglgNHqYzw2xFFeXLKQuEm20zZibIOy6TjVLpWRec0YCI3SRZIOl3qJycTL5xkCR8M3ioR/i5Vb246
# DATA cmyb3hqlVuGxYHOfrU3OLn1znOlT9Ceoi+ieWdxngvO96MdrHiuq5z35ABtSIsijxxM+mYuz8VnNe4vVmrnuehpQg+pAkUeoSG04
# DATA xEYgDsscQ1Sq/uHiIlF3zjmO8wkNJEZXENtRcf7dw1EavIyaTjjl19FAx6WjJOEHy4UULrbVzNVpYNGJN+e9cWUSKwoXqsXPIFPP
# DATA cJzMKJo/lPDEv8Ihkmk4sbMkNue5w3R6NV3zN0WIGllHjf/SwuZohNetbP4xMh+FN4JzWnqnGxA0z9mWIniEomBD1Mv1CG5A09wo
# DATA M7JRM1NtD90sxrwbkDi/z92+sZWUmsTtKYG/PAe580DcjMLNKIozinKVctMKN63Yefqwcfpxc9OKB8iKHIcj0dFTiudeG/A2EKXi
# DATA SKPL7Pny9o4uwmLqB0yHZS7kdI76VYCk9c1Yz9y1R7d8X3/x9r59UWTtB02ECxdzimd3XZybLSvKvV0JquxvZELJZLFDLNXtOeJV
# DATA fS+YVCtRszOzUSSkbomaOD3p54JXcodI6gdNLM2F3K6tdS6KaLAtohtBqDJ/xWhltbQXl4YqTS3OimJHRrP0XepbqHV4R2YuXvHa
# DATA 3W97pt56UzKpM6/RVPecwD9Ns3yaSEdHKTpKfkojszD9Fm4W38jdEX9VOmwyMzWQ05jVauOB6erwxuiRrJnoKQOWwTCpR1glKTOW
# DATA 57L6Mi1gmwmrTJ6WVQhM+vNpicROnT6ItAraDpTTl8f2dvQdZ3tv9+Y7Q/ulNLQvS9l5xkKovAM43yC7aoDaEBoWHQy1B9vohUoS
# DATA NlNonql86gshK8j/vWamUUno9bqJRitSuWt5RjuI11r7qHMJW3yLIFyZhKOKIeiwlbXMxsrAKtVT7BSXklW7xd8YN+69m8ZYt8Eu
# DATA RfYi0iUw6uNHsGHY+y/nuZh2GBfNHZpAYhYYrVt2UaqaImQq+qTqIANv4VImT9GAoWmp5VE1VouJrh3vB1izQszJvivFXGR3zaIK
# DATA xY7XL0ybEI1RvSyjGKQ4Tobt2dZqEcun8tITziJuiTCa/Y6x5WNts4TpvxzfB1gJUgt0evocFcVRw+LCHi+ZTMyqH8VRwSexAoFF
# DATA sM0RpZety9dXRrvTIgeR4TYAh8diB/2nsy/P/nj2zfkvzr4C9OfsD+e/YagP6EG/YIbPz+k30IV+uwoPWnn47M/nvwFu6Bdnfzn/
# DATA +dkXZ7+nH3/NDKKvKx59+vLs6yo98RWC9vieb+geeoeghTbChCh0vOULegPd6IBCz79F/UPol/E6MfcmihZ2WpEFQVySjlbtTk2j
# DATA I/CXtZyzLPyr+moG95RFmwuUaeqNtzKE3hqHompgSYY7jpBlXasu4bZJQuvK5eZoQrwhYJzMzY2fqgvrmUKjOO+m340XxhN8zTQh
# DATA gRqzvSC+Iovo86pzhHYpsWunCd33BLwOEHh1sexHpuTFgx9jD+3Uk53gNe+DhGrAzIAQqRCPofcOSQ+sEbCGB8yyUG12CfF5Ips+
# DATA UrgPp8xjFGcdG18Ca4RIbBketL1KbjZi1rSzZ4UO2p4EBw1yI/1lRnrNCbriAP9quM5ua3C/kbF9p6H9ciP7zQ/sUi1XcyDf6Hp7
# DATA reUmQEF5yiCiRQFkq3FewOOGzZp685+O79KknQ85MU5EFyAIMDH/znwTLIExbUVtCeW3TMMZpS4z6ZbUmuAFMzSdUxc2W+yEDYJ9
# DATA tcBBfuQDhTRKqbfLB/1Ylvv1whaCYTE5hhgZAlAaSVYZJPKpAJUr1kifAPOTjARdjBdRRfQeLJDsmD0e8cijVvVQaCgn1FFgzyDa
# DATA IG8wSJF32iHq6EGOHuToQTdID9ptTNkRan6xzXvLxvtVbPenNd0dO8ixgxw7yLGDHDvIsYMcO8ixgxw7yLGDHDvIsYMcO8ixgxw7
# DATA yLGDHDvIsYMcO8ixgxw7yLGDHDvIsYMcO8ixgxw7yLGDnht2UFQf1UfBFdlBfrcxaNVfIHbQ6rrzTvygI5Nk3kVYZM0MW9FwVN/E
# DATA mrn3xiBOYf8L2CeQhCiwT4dFGljewPcVYahwe7vevOB2i/NDYXt0j0e/Vf0e/a3Tv73W9+n6xO/V6VrbC/wmXWtXO71q0AzGzd4H
# DATA AYBFne6405z6jVa12Rq318WkGWyKuAIY3TkqVKBm4CMy9IZp1ffqx4Lo2ZKN0ajfa69HJNVXqifFuRXUx+1m/QOkutlrHTfr02a9
# DATA WW3W6VMZQdQLO/32uqCDy9OApM5rGpA0H4sGRMkYdBpFGpDfaXSbPZsGFNSb3dawQAMKuq1GO8xpQP3RsDkcGhpQq9Hpd6OcBjQa
# DATA DUbdwU3TgJRRst7xodNasrXUSISNa9XtVohHN2PYye8tg3/MRGndpEi70TDXrTRrTeb/BMz/WV2PahcjpY0bq5sW24UTQjkeptUj
# DATA TI3Bs6gPo6OKtfZuf/aC3vxR5VuNeqvT7rPbb7+yOaTeJYPSUc7m0eCyVCJt88J7uGJSWStymxfH1VK4+ISrGf0wjQ6GYfpwM3so
# DATA z+GKHfXNNkfJ7JU6xLaTIwk5kpAjCTmSkCMJOZKQIwk5kpAjCTmSkCMJOZLQK0sSUqSfT6xjXfl57uI5rjKGR7hBcsqb8kjThbAj
# DATA AM0IdJ7BtMYwn7eSKQugrxzy5uNtWEoStaoQB1WSmTq+pgVpiwfFpI3KRE6ftHBnnN0Z58JRG3fU2R11vuJR543igzdzBPrdmLUu
# DATA +CwtuyDLp2f1UejnTW7jNvS41eCCqkP1VUmGI5V7g+lFEs3mWdNh5VeMSHN3rTZ3yxZp9v16Uaa5tUXqmgc/SLqo3osvvCG2rFFR
# DATA lntygWv90BsJd6a2hHSbl3s+pr5P4YW4nrxxJ1EigWueaHN20dji3fEWafSQtSIvfKzFL7LNgCkMGpZPLj57R1Kzg1D1O7p+osp6
# DATA qLIvrkr1B1GYLSEajYO1gzDNBaofLESSj3qSJFnIDXKsGbI+4RHEnuGPOqExq+b9kAe3SXRMlQYdIDrVqQqbm7GC0ySpER5KEzIn
# DATA a97HvAAgppE8wHqLStiPhpNTFDQVRLwoyFcDplU4ti/nSL10iTPeOHId4oA9NBzNeA79QLLYqM5y4Wc0O1tm80j0D1kxO5wtRxiI
# DATA U8ylJEBwkYbxaIQryz7rqccYpykwxu6ss/WUCAElYbGzwPXLcs7XyVs789UyX529+krYq5fVtn7Gkj28rp0vwG7Xtr5PoxEbjWxA
# DATA sh2b5VIUzFHItmhc37bYzwuhd3ETstar9frapa3XajpdVd46X/TX5phYFMr2iUAW5TqXi1qz+XNKJo0ANXkpiF5X894U3SCaJYlY
# DATA TRTOYKJ8ChEhkXvJMLgxZlQIjlzdYEaR1RVr4Wey4RKyecioe0hv0MSQy1WcH2ghFqPqZNzhr5biSSFnnDHkjKFSn+q8ec6bV+w7
# DATA N1pRz1jQkHnAABcnk4no7JeB3aqdhFku4Vfz3hVON1tJ6+T5Clp+8zQZREPQuEWKLkk/X0biy3kaPvf92ECdDY13QSOoZgJO44Wg
# DATA pmUk9VjLhWOw5EZ+FC6PaNT8mIZhTQuscABilshyj8I7oMMIRyM4xdhVkrs8zTj93gzj/UL4tUtFi4im/WgIEbRh1E9pRBYqMg+h
# DATA LAKIHUpbUdYy+ufyjIIDDqkqwA/KmoLKNMi0dQHlOPhrUnGWKvFpsgGGk6gfpjXvfdhPiCZVUsrcUIHAhiE6GCAR+hMRXhuzMN46
# DATA IUP+mFmqheKSzUC9/pwKPh5B520aYe0vHmyFkY9Z1Zorz2wBDw57kU2SPwWUIxmNvCMasnQSZZ+kN1lSpg5CKDZyPQZePTwJT8Ux
# DATA peOpyjDTbh3OPh4HKBgVc8qXTBS44V9iFe5DJWsIKcyUTxaoimuqcwGssUD9Yd6I16cIRBu9zirVPNLI2AKZcOaD50LVEJwyLYvM
# DATA mIQSH4NMwvJP8YR+rmg/FCcgh+0MwjQ9ZeXG+5RnIfvtVEBCmBd4nOb4HIcsyZdn0odRzKkSP7FSv4RL7ihJhpa7Xd6aUEOj0XAk
# DATA ba1YhFeDfaMtn7LqI/Ux37007Btxu27Yt9jlsTRwpV8YzwCOj4Y3AP1+E8x7JReqto7cAOP705IK6Y28ieHe76NpSB9D45psy8mE
# DATA mHO9b+NTQJ8aSiJWiOZhnHoP4S0OV1N3k0Txl2OqY8FlkjAdHsG3buNl/ovCyHzDUBfQYb70zr46++fzn5//ZpUn89/ovj+c/U6Q
# DATA L3wXk19Ahfnm7E/08QtmyXxV8Qxf5quzP559AVzNV/ipqp/6yqOvX+ig6DZ64S/Pf6XgMhSP87/3mDHzO7BpQKFxUJkXANM408yu
# DATA FV/cPEqAgFYj90IEpt/S8zXxexzxtm0Mcgoaxtq9LC+ck7vMwEfR00PhcjbcSpm5z7fkb3aMmcJszvQMt02ZWS2Xm2PMcALNXd+D
# DATA kDjl9WRUvm8I7WcD9MJ+30Uanl4nWobaQEY2dioC5jTTgDXGMzEUhIPLbC+qa6fKmE5oGJMZzyf2xNQh8xVPQeQ+fuRxvfA+5u0B
# DATA 4rY9wv7IdZvKhX0IjXat9I0ym0UL1jTH3g8aw7MVhsy2mrfZTllpQ8+KH7Mt+o4e44b0pxrSNU7mSiP5q+GTvb1R/AYG8Z3G8B2H
# DATA 8JsewaUulpOdb5t8hi3mJpAy5YTmZBmjOZHHnHIzChViBu43lhuAp2tGRZrJai2SYfgZMqwCPXEcp4yLQWFprAylPMxwEUfGDVEY
# DATA q6EysF4CInMKa4t9uxLikWwzwzSBPvYn4nE7SiM+DyDZrre6Kd86jf6QQuDvF/JIDjH+c5akls1QxIxEqYPFOFiMg8XcICzmgjFj
# DATA NyT8hZbtrZrnV+JUP5Vx7vgwjg/j+DCOD+P4MI4P4/gwjg/j+DCOD+P4MI4P4/gwjg/j+DCOD+P4MI4P4/gwjg/j+DCOD+P4MI4P
# DATA 4/gwjg/j+DCOD/Pc8GHanWa/Wb8iH2Y0GgXD0QvEhymvOe9Eh7GzpVH3/FZn3Og0joNe8/v0vZgj/U6n0xyuZmcr8PxunTK0cxw0
# DATA 29+n78XnqG52+4rLwmUpZSUFdyoclqCgK9HsFcu42SxFpB/1OuUAg6Bx1QCH9V7Qaa8E2A2uN4aNpn+9MWxK1bm+GNqFQmV5DXlo
# DATA FcolA9xQylahXEsM7UK5lhjahXItMbQLpSGBX19LuWSAF7eUa4mhXSjXEkO7UK4lhoVCaTWvt6VcMsCLW8q1xLBQKNcRw0KhXEcM
# DATA W4HVlnvFUvYbpRDVhVTlfnnwb0eNEoqr3WuGzbWwtHXQsVarYUHHJPzUIMEsI0WHusJPC1pPF0Cr27MCaPUuH0AhCb32UyZhtwAu
# DATA wzMTG03zzMTcs3hmYbPdbERFntmI/2fzzOhrLxoVeGZRdxj2hznPrNNvt1ttwzMbtgd+2M15Zt1BMwxunGemvB5qQ4OZCYkznmxJ
# DATA dlBY3gu9SG3mZ11eqVyz6F8Mucwx+15ERmwcViQmpb0oa4KzHZG8yFMMXa37XhwNM31Zv0tO306T46Not6Wi1i6L01ao5VVn22ei
# DATA 60jR7RzIRH5l9dBvWIvE6l4/KHphdHXlPZbjcJic8EIMVtzqnq5zVt722GHBs2Izm9uwn05PYlVu1zcz0Ow8vcCjYeVWqU7yZDlw
# DATA IDQHQnMgNAdCcyA0B0JzIDQHQnMgNAdCcyA0B0J7tUFoj1Xtjqng7iqUGT5ToiucJHURR/eQEXK7qG7epY6N6sweqlZ8t34Yv8FP
# DATA HMavv77/GBf5tsN4tHcSz8i6IjvsdL5Ivgsj/mNAMaY/4nD2H+sWNL/LoDUGgew1g16z1+4EvfYdjtL+d/iPikL/LmzAH9LsvRFI
# DATA x+vvHw6Tx/KO8iv2+vuHT1g2c6//4/pP7t2ld+0fiuQbLnybg37dP3wSkbGutOCsuAj/jQPcU/HYp7uV+uh8SaOe6vaeSPRQOe6q
# DATA n3+axLM97q0oB8GHQ2N4Xf0oC7R7e2GlT8URvt6vkPWYW/IqtZP47kZrdhKjYCaxXSHvSvOgcqM3Sdpo5ojXso0vMwIcIEe7n2Mr
# DATA wWy4N4n3DyWPir/zqjRN3FVXfM+v7xdvwBCs4vMW7q3J6WmqbE80ss4c/XTKKk5ZZVVZxRwGduoqTl3lkuoqG0Wxb0B15WPIcWkF
# DATA kEnCeh+s2WWEV56tkNdt0OnYFKCr4gnykhEn5gIsnXoo75HU94Ka7AqRzreAdG0bR+dvgdGx+YKqjw+Yf6AoSjA6dU8Oo9MPrTDi
# DATA 2hLUIzGRNrPkeEx6B971i+70RQ2YLNCLbmSF3U9Oogl1ohfcG9TVvTMygUv37o6u4+qNVs4l+sJS6/5GMxpkPMrIeoiGRmrPyOuQ
# DATA kWVkccR8L0vtMEluN9keFrHxsmSZguU7EpwK9LfFaoSGQ86nE68FGYkzJeNDSTz11KF7IxZD71xRixk37tn6P5SmBhXMRBcKW2R2
# DATA blobdVUJTHaizb0MiiH5WOKMTmd0rhqduXXhrE5ndWYX2pPPTOvvAaOGOJLs4gZyFNXfGJ0GSDaNB2liSeAt2UJV+nchta7ZAHSL
# DATA Ve07MyjmLUoNhhpSwlJyg2Q6jdJBrMdAtlzTCCst2Liws/Yfp2x+74F4q/qn8JlF2GWCYdQAlIT9S4Mp9lKs0d9S591WTVTlnkVN
# DATA 5E/KOFU2h/4xN4DMFT74DHRaxOGo+MlygwgO6sivtT2NzxecIPW5aHlad5iO0n5qxbCD0xRtAawpuS/eZgdq4/xtNuA23TVIQNyg
# DATA 5nLMN7+Vf938DFci3P0RPmyxLmVg1haeuFBtkwSDxBbzrlDC2PMhDVod7cyRDtQpGXYHe6xldUflpZ0XJRwQ74Yx7VycwVyb0iXf
# DATA HvzLz//vtklFOdoqZ5UppqQqqYKki1Mxxsi+45EJTB5tSfIgRNO+KuyuIc8XvfvDIaTx6GlhAQ3Q2Kj280SR+clgr+BBNv9kdGQi
# DATA iiYmwzalt9S8N8NZTgWcDWVSKj+9CyIMXtKo0yBrKEH62MmV8rVUe66Qvc3N2Vuoi5LLsJfFhqeELMKJzuf7zJOhQWJekVzTE2vO
# DATA tRCbABbxNLKhbPPJkmfPNL9cikXPBCTl0ffux1Pk1YistWwMWBWb3rjkB/g6TzI20WveO4Av4jXDOBssMxQQhySLkteRy6a9XTZ/
# DATA N+etark6V9HjU9e7wAedp29jb0/oNf7PPzXAShpSnmDxYAae+QnwQVS3lpR3VBYyxc88nwq0B6eFrL8MIpqD1LyPqMumqfd9qdhS
# DATA fUGAYk4Sn1f04N449N6078AZQnGX8ExabfKqed+nrxFXZCr/a6vIV87i7T1EIZs/pYGWJhkURKrz2JizI2r4VdFzyllg0A6k+oXK
# DATA NJc8lBWfTPoCuRuVFH6aUKHHMSGUBz+EdilOBmasWxqaQMKZhlJV5GX0G5ZQJG6c6UexSJ6CR3YcJ9RC1MOh9DzPR+fRvlTn8W+X
# DATA Ma986sFbF4JkMNVfGuNQsbkCsg2kDSOZDiHbvWwSzyk/uXFw3wLQGU9v+qxvqj2CUFDFqC5KrNw1eUfRQoqOsxALiVkyjXDhaBlx
# DATA x4Gn45lMVKhfWlxL93Hzg99bPC6BiRSbqm26RXFrLE4S6ZAla9EbZ4LQFKHkKE5pdDtBKLoes4xtbBR+abqOpp+qlk+2IKs6453U
# DATA NeG0IvXWx2pyR2HjiWmChVyeO6CnYOyEdC+wWcuZWzRXZNnYNlfMFcmse9TA1AKvFhKW8VtMRct8peY25oYnhVK7iPX0Mrhc8tmW
# DATA c7k4l8sagoLzsrz8XpaNDpTniqhQOCqwOlJObNaCN4kXOOLMSiiMxATFUo0m7ILJH+TzJJyxzxrB8DxrlV/ET7IOfsiqJB99ufcG
# DATA daTl9qaPvheO13XlLJ91Ll8uhBPpDss4iZUj6dJ+Bwlqh7ztdDbQUVEqj7nfzRaz5/JYA+awnuMvnB61EjMO7j1gm9xUEUCQw9mp
# DATA WbX6fnICHPKpqjvf9fjCEt4psqq+671F90fUmcIYghGSW8LfxSQsnnKFm2UnMntYYKOdx0vHrL8fK6KrZlMBRhuSbQY+LrTLyPDq
# DATA J4+iFV5Usba8GzMwkx2QlB3LwYISKcX+Kiw52ZzLhHncNuXyPzOW8n8AOXn+Ww9EyrPfn3199sUq4bJ0519y4CXur3jnv6BrX9F/
# DATA vzn72jv/9fkvz77EE7j3K9z+R0Fg0u3fnP3+/D8AXunRh5/TbX+SWx3H8gUw2byM/f6pOoBo+nokmifn3BPUPNkt72VLmbDKhnzm
# DATA 1sqD3IAxZvBgwh6BmUyjRpiwcoODnwxLC2PePL+FYvmmyIAJKsMhLIsmnDT62wZYlork5uiVsAOOre5eVTymoMtP5SdUFTRPfKyq
# DATA JKrgDB6xawVa8m6JcZixvwboH+UoVxaMg1ruWoLXjre8D7v0SGwVw46ucLc5hINNA4JMnyWG9tvxaBQPsCEf25Zlx02kGeD61llE
# DATA YdDPqbj7V4iWO9XBzWZJsXU9K67lTolwgEs31j/FWK/xlpcf4l8RD80tDe/XPbrvNLhfemy/taFdqmUhG3LM5TNrNzcBuSykEVPy
# DATA sJgwbCuVBCDY6XwhQ+E8RdcDTt047Me88LfIdKnRE0dHWGB5SNUgk3k81WO1zI3ptozMZgSexFQhsfwlhL8Min/prohLZKNhAmLa
# DATA QPGfUFePM2xYA1FoRx173va6gpVUNalaMBZkQYhjyRIpCAV5iAzAymdWnUdpla06KoHllHvZQ8tMwI2IcpUMto1mg2NgOgamY2De
# DATA CANz5wFmp5nMJezh2zPtr2LZX5Nh7+CYDo7p4JgOjungmA6O6eCYDo7p4JgOjungmA6O6eCYDo7p4JgOjungmA6O6eCYDo7p4JgO
# DATA jungmA6O6eCYDo7p4JgOjvncwDGDdiNi5tYV4Zi9qPcCwTELK887kTEt1JvfyimLjSJVrFPK8Ib8LjleRJY1u+16Z02GA7vZDsbN
# DATA 5rTabHp+dyyoMws8VqaR5eCxxgr0rW7FtYRUW4lrvb0prv1+u9sKV+IaBBTXbvu64tqz4trpbo2rgtmtjWuz3+Vfi3Ft+HUvoPp7
# DATA PXFtdK+lDnQG3Xbor8S1Wb/OOtDsXEsdGHbCYXu1vjZ711kHWu1rqQOddrff6a/EtdV9+jpgBUehNdudcbtRP/bb3++W8LjUoQ5a
# DATA V4PYUV+qIXbSLVsQu2abuo3uDhC74ahVhNg1o+awnkPsWp12q9MyELtBdxD1BznErtFrdTvBjUPssIeqKqsbenRtWvw6i1bXZZsz
# DATA v/9yXLqy07WRL7W2xenKIfM5ld18qe1tvlQ9J8wDXV2VUb5mPc3AREFNuXqtFTocfGpYcJL/NPh3w4WLZ1SnvK6Q4aQyNIt0OlVr
# DATA 1lH2rkaMkxUDtYi7tgiMa6/sL9gIm7NKYIttulpjHF/O8eUcX87x5RxfzvHlHF/O8eUcX87x5RxfzvHlHF/O8OVYvVGh5NjnSYn+
# DATA jnzlw3v09Y7+VUBzbGx+9to76vjf0JyExGE9Jpkxk20QxZM9Dp3JaqKfmdU+o//N7i9wmwSrflAANvWN4TA63CFNuD0+wbMm8Dvl
# DATA UDgY69GMRwSDO3M6iO6g/eaD9u6A/Ut8wP6y6ofPzcH73LG1XQ2RRd74NOuMRiiyLCCwPKbv27QQn+05/RfsxOpF6ju5o/ImtBFL
# DATA KgTXLIxY1nG4QBXxvgL0sBgC5Sq1oYwDM9JCHy3hjeEdDN7RElCwfsRssNBS/YbuAU3WMU5779LVBCL3Wv1QZKIY0aDUFajeJlrA
# DATA WU6Uc1VX4g3Ifj5TjnPofakQeBp1Lno0l2mFUpkuqx5uVVIqNTl4r234BatuP0hopBur0+qy+VWLb38YQm7RyPSn0UmY4kC9EhQ9
# DATA CSdyND9UFdSbICHMSWAHehymIkwhkS+eh16ELJL6g+UCSTKHoMsa5atx1LlsqA0zKQmm2HAHgU0YHr4Mo9BIqYcZqzQoYa2Q8TR8
# DATA Wj1ebInee6DeXCJy6EVMxCwhDV2RIICZUeGHqQIYJJNM8RgNTYeDSR96J+iFOL44bb8lkh/Ja9Zk4it0Yt0OxdnIzkYu28ilWuVk
# DATA qZws1VWs443W+I3JVX0v5jbARkKohJ60gg3l2ENLu+qWNRFvAw4szh2G4MB6TCPkHFQqt+OB9WOmdzIXcsJts34RIrhRF0N2B0qw
# DATA eJ2A7DUOJr7ELiG8/III6+dNhM2FPMKt9RGWOKoo++Uo1zfHmV1jdtVF1drjF98Rz9T+hdlcpDDr73mcg7Vxbl01ytphRjd8sN7n
# DATA dkGM8wBMpK1LVl6vjbYVa1V9dKRbhThvBCK/uYwnQ2tEQ2/x4nKRP5BhWEb3cM5Hb3gBW8+lDDiZey8+JaLUoST5Y3ooAo/rvjeK
# DATA TtilzY7jhfGoQgdrjZD8UcpCdWb8n0XHmnllJMB+qPp13RUCuBYCi479s2yQ17x/R5bCkOc91DNa3SyZ/UPsDBLVNc3IFFe2dKTc
# DATA WChF8mY2PTClo2mGcODixaYp20tshNujqzPCnRG+4qhesbacHe7s8G1m9fMjG6sGO90M2AeGtmCrwAO3Q2OVaYXH+VCnJEoruYop
# DATA DzVG4BR6ndhbhVEHgc9FshPDq3Iios2NBIiSLWPBzMhhkE2aq1emJ+cv5YYNCfw+KoWeRdDoPHT85F34yTP2oeIJ8aZuvlPcyTKF
# DATA wKct5GTtVrScf6DYPv8E5Tw3LomR/GQzQlLnq0Ak7xc893BpU5UBlDaNUEwlYGoaHVGOGf8s+2EFiUX/GWHurNRnqUZmfCPdNlvE
# DATA NGGWFQieK9e8t8I0PYUoazIrusfTkJmNbLUu0lPlJWZRVuyBTCVi8JknM+0nV5MHu5Hmqz+6ieSrS2YPpIzyW5Jv8lerKNIF3uzL
# DATA DTME49TMRJ6KFZpX5UsW8zubi1k3ClXMxumfL8nIXgvuMXRBv48uFkZOKEzWlCx2vcqRWch60QIQpWheepHAs0lyMjkVSeiUlY3R
# DATA uWIsMks9VOa8gQ8d5Nj0ik9VhNuTdmuFWOhlLlmOH2+BGef9lW6xgh5REslpBBYrDTmzoRID55LUJLC8nQ7jkGaBUzZQR9HilMbT
# DATA JfI4Vs6rULdkhRszk3ledKHRNeejZWYJhwbfR5iRss+NPWBYIIwFuPbUbXNbQm+tXK/cBz/YuQ+mCrugW4SuG3kzZm9nD09X+l/N
# DATA tpFihVUjQtNsZIyjaZzNWfvae597zJC9BJMwPYKsNJQZZ5nm1J8kqfSv0lakcx2FQCTDLXAt7XJ9qp7/bvX7O3erauwi+wry+khq
# DATA qAaqYagJ1qZJyro3ustEG4tih8LbwqfjII6DolR86/hoBlePTES1hQnHCkuDw+hM5ynr1VOvK8XM8biOtrdDwl6IrvXtS3WtWtYd
# DATA hskwDU/QQHh3wiQeWQvVyrmm71DWQxRiWyhlDmTvxd6x7RnMaLiwtMkzWC5qHrv8zFq22h4wSMM58pyPhOr9FNpD9nTlujWFVyrR
# DATA 2wV4P5WH9uX3KeYIzEFEo308yIoIzC/Pf372xdmfzr46/zV9/gV4lsBW/on+/AIcy/Of64vrsJjfnP2R/v/l2dfn/8C4y/O/Yyjm
# DATA nwSJyUH/nq78mvmZXzM50zv/1fnfA6B5/iumY1LYZ388/0cK4lf097f0TgoBN/2CfvgD/Uz3/DO95KuzP5//xmEyXwhHKbalobtS
# DATA 3aKqeRx0diC+KB7C+jQ9qPD3I2x2hxd1AGSdArUch+y5Cs0UwfhcQw9euMG45r3zaD6B+UKdKQoLsVYGTa4OvJWf+daExi9piYif
# DATA I2jaPlTdZ9w2QXOlUG6OocmV0tyFrYW8pq48gCvETaracWJuf8BfPYh2LScQCbtOgGacSVTgPZSdjRHO/IbgB51GC0fP3KXsboCc
# DATA yaukvFoeTzHVRWimAqjuaRHxEbUB6jEf6/c+iMJsqZZvKceWgEIxXQElR32l8T1nzBnyFvEkUi7rlP3lZCANl5NVnOZuVXKzpVNu
# DATA a8+KqLlbOhxS09kFN2EXaNbmVcyBV2I59dZMgeu3BHYyBC5lB9yeGSD1spQLNm7zeWtTN8HhLCWfEw03NbMLTWTK8E2tUJxnzjGc
# DATA GBPF47QP0nBu8dKzUf7LAXz6bcgM8eVofGX2MFoM4PfeFceZj/iWxUCRy/Lhfyp2whD78qAaBYUaiq8nIfLJmoI9wAvfFLdkWFV+
# DATA fLTzLON9ZB7v4RJbRDsVaVRCcsUfpWidvFGC3VahWUZz6E2H3nTozRtBb+401uw0BbqM0XybU4CrzACuawLg0JsOvenQmw696dCb
# DATA Dr3p0JsOvenQmw696dCbDr3p0JsOvenQmw696dCbDr3p0JsOvenQmw696dCbDr3p0JsOvenQmw69+dygNxut5rAdXBW92R51Rt0X
# DATA CL1ZWnzeCb5Jocc0LHoDkRnrcV4OToVu2MszNmiKDhX/ErSL/MLecBR1V3MZTMCgMfaD1ufVrtfyvcD3/HqP/zRa1W7TI/u42mtU
# DATA W9VOr+oHbS/oVTuB53foS6NYGO1ut9WL5B3FOAfNII8zvS+PczvIoyxkUatitBrtaBVl2el5fqsz7nYnVb9O0et83qPIthvVgH5o
# DATA d6u+3612qq1W1W/2SrXFjwaRX2Ie9tvhKAzWMQ+b65LSlNgPVIw7FoSxaSWlWMeH3cGgv4bI6He9RtD9vNuuNikljZ5XpzR1PT+o
# DATA f16lsmg0KYW+V0IrhlGn2V4bt1a3k8eNArayuWfVjHqRFuk3B832FUiN3PQ0qVFasUVqpLgMeruQGgtXQGoMom40tEiNYXvYGeak
# DATA xs4wGIYWqdFvDbqNGyc1Ym97dZtJQwOu5eMS29g8pC0ZG0qIVI780oy42f22h3/J1PDY3MiD0OOttcQov7I5uaPXP7Dit3YuwSFC
# DATA UNj2+ddxN89BtGl6aBngBVeoKvfLgRXF/ZVDIUt50qI8oX8b8m9htarZMtjITuvbawmPYixSmmXOly+XWgtY6xGOG1GNF1YGbU+u
# DATA rwWSKYFdfDuHUyoansWWJkOOA+k4kI4D6TiQjgPpOJCOA+k4kI4D6TiQjgPpOJCOAzkK0bjv+lXhKcqmY8AfyZrRyMcH+rz7SaT8
# DATA mYx73FO4SFzAExIUquq72Oi35zOScTAV9mMhEDVXtUKRKxcHIyKyEE9Wx+nlqL03j6NBpE8j4owc/Id9lEeRA5mfvHGnw93p8J1P
# DATA h5ePaLmD4u6g+Hbd7efmAPmD+JE0oQqNT7NTLPnHcsjSBt+YI4+WaCqazEQOdeLZh6unnnEUlHtedXZ6hFDkZGYWTqJLymcbVUtx
# DATA PXITp5uTKVyj9jlvp5y9i3I27yjhqogPm+9Df4nbfkR/t2hm06C4EPzhR/LxRdDLNnlwSZHINzeLRKrcFIHIN3GKc4Rj3RiUcj1I
# DATA bJbxyHKnqoLz4DidDy4rTXlOIeA5iUdygjlZMAUi46EJLigE440iqkcTGEQ0YUnk4DGnRBNRnkY786pZ8taOWfKO1gSlMVlnyJvh
# DATA BLoCrNXL0aXGxBfMmWtZwmFZUW8E7zI9jZziBRKe14E5R0Mz/lATJOsvlpP5CGx2HRmj28El8+VHm/NFWpSqKcshWyZ5HZmFKc1J
# DATA vRnNaT30MwwGhXQrFiQgM5DDf2DRcJWKZkIogyBBxhwR+jxHf398qo2bZ1hH/s2OdeSjZMkaFj9dHuX5odWm51p9OpmOsGkEmAbq
# DATA BOaYXqFBMM1IYYyGZGrQYDagjJuMkyVOvNW8TzAhYG0FVkoQu+5oEv7MCHU8pfps3hVeMn8+2qI9qztVySGaX3tzfUly6KM0OUYd
# DATA oDTT7OYoMuhY3iRHlSZcDqDCcX/mLWdIru5hIBDMQFRgmSZQ3odUNC8uP8N28/GO7YYrtVJusZC1rMgwTZZQH19CqWIixkPKZ2Th
# DATA 7wcVazjUPQuUlmPpStkss4V4Q6ku1F+X8+N2pWxfFYWG3Mx2k3A3Cd95Eu5m3C/5jHvjZPq5lmzjfSxmR4tQWXlXy703qEGXS1jv
# DATA v0Ryzba6rmyltDaHyoVwwt/K8mcr+yKlwgwS7BySl53OBjom6qTxvR+sbKvUk/xVdTnrMf7CqSmM75MC2QvwCWa9sOLYkKonTeC1
# DATA fyF/iI9O83DznOrWvUhyTjsK23pmS5VU34LhYDZQbTHU/uWf/pM2I/iV40Ck7MSC9BbRZMJTFwWaEEWv78H+zLwjsbLCBdMihlBh
# DATA oxnLeDnt6+IKvXR8uhhPlTXLBivPDY5i+VksPxYjw7QZomaW5pfHex4h0qWkkSuUW2mUC84ZNUC9Ai2YoRxdcRKmK5q6xQJlqJEx
# DATA HJlY9QrKalnBOKvNWW07W20r9c2tnbi1kytYbBuNw5sU32VA00jp6LOYO/KaF+ILGrzPXhB+myGAc36evdaysnQitiLblsPCtcKa
# DATA hiz10+V3qf/ls998xdsbTC8C3etHTXdmLpgVBjkgUkbG+0XQvY2Mr9f8zesvakOBHVm5tEtszcMmuvkVE9/edUZXbbyg3z/Q+r+L
# DATA ZFGoEnvfvijaJhAT7fzKBdlct+Ld2BptZb6aBTPZlcqrXFLlI97iYZpCZiGiUMPuvSFnglWc1fZk26mWX5L+JxZU1ZzGbmXE3pEg
# DATA nhL+JLYVo7TyLsBWpf5hZvaXoPEZ4/YDcaYapWZGDp+M40mU9xMx1GoX2KuTsuStWemg1hzl4s0sD6xWOGHiysYV2fpGpm6pCuid
# DATA Vt5QofpMb6C1g9GlWn0PpWo5pfuxPTgPh/WkB+EM2sFzSkCMc4phOueFXvYcA0UOd+XJOBIDPu+4kDIITXO/xgtbZHTUPAWzQwqN
# DATA 0HS2nFPXo/SDi+LSdzjfXxXr2YJw8Ryd5xA2h+ufmMH15fkvhXcFctY3Z/+s0FyAc4HF9cUqgeu/0W1fAdAlaK2z/2mFQ58YsPVH
# DATA ukdDtv58/puz/2UoXWdf0I1f8bt+f/4fmNCFkw7e2e/Ovjz7n1RpwokDbr0Q9j8b99bWDaAC0wR41yn6Ca5vxo5hUmsGeXLqkli9
# DATA j3rGmah+n7BuuCxdaNntiuKGHqGxj8M++imZrYsaNtcZiJ33I8wQtsG2PqW7TIQcaqtg+uc9w23TtkqlcnOsLaF9G/4Tb8m23mrd
# DATA +dOMilvfWKxg14nYCgVspeEKaoFQEuPwWhcU17WjtT4KyejEzxTrVr1Sr9d51KAMoC6q5n1EA4ixephgwZOucTjHWrDe+b8I+4eI
# DATA pOCoMwOhQHFFj2ggwNmCMkPrwuq22UwpNp5nBc+6MAGOm+WG9+se3jUz6/Kj+qvhzLvFEf26B/SdxvOdh/NbGc2lNhaSbvvonqc2
# DATA dBOMrELCGfGTKWa7nUyadIeZWjQbYtGsD8s8xE7iCiU0BtKHGk1MSZjEYEnNhvq1ozCewF85CMEqYrZQMVkYbUOT0VMa4PQCczzL
# DATA 5kgSXKTUQnalZeUhs2ZAJu+j+DOlibeij6nOwb1CF/lMOZ82Z//GDCt8PIddMiFqHooDNhkyMkvMgsycFacUPTgl4+0RPGXxMFQn
# DATA 2SMxDKMM+xDjbIx1zBBejYFwV5CueIQNiINxNA093vnOFK45j0UOpeVQWg6ldYMorQvHoJ2mOjuaz7c3C7jKJOAa5gAOneXQWQ6d
# DATA 5dBZDp3l0FkOneXQWQ6d5dBZDp3l0FkOneXQWQ6d5dBZDp3l0FkOneXQWQ6d5dBZDp3l0FkOneXQWQ6d5dBZzw06K2g2660ro7Oa
# DATA o86o8wKhswqrzjuBszhjOS49zjhBM9X9ghxF2+8WM7zR623O8Xqj11wFOfUCRlKpoCy4VKfe7fX66+BSDQlkEKcsQaVe1rbYUg2O
# DATA Jx+Y6xZpUsNeo9Ne93yrtdPzvX6v3V/3fLe5y/PdqN8J/XImTINmwwuCdpUqdqvH1TuYNvxW1Q98j69V5VrV9xtVv9mpdjqe3/Xt
# DATA oHnDaAnP1R12h711Oci4sFLN7/S8ZsOnCo9Xe/Vxr14KzuTdSnC9KyCwuAlpBJa0RguB1Wi3+53gKgisetSLQguBFVBAnRyBFQzr
# DATA w2aOwAq6bb/du3kEFs2EqvT7TpP2IKCxsui3Kow0MuLpED0+IGe4T9qGU8anTrAOINWulXWBeMvJ45LLxBoDVu4OS2a/McW7yhTP
# DATA H9CjdnkeuG7Op72EXfYSyuog/IRrFtvaxUQUFwJkjujZEx9lyOVPmGFwzYpdGcO11uOjK2rRw7AJ2mWcxyo68Btb0y/+fkE+FV/U
# DATA RnLYr1jYerL5eTNOX/CaDVO4zVgvU8F3wnFtq7ybp/WlyryuTi4nF04uOQqO8+U4X47z5ThfjvPlOF+O8+U4X47z5ThfjvPlOF+v
# DATA GOcLdUGdkI+Ghzb1a4ElU84IpO6u1PVkmQ4iVBCuVYfxiI1M1TDvteoweBZjwAreSdMEcXxbWV5oXmTyUB+dHkmfbF57t2RMW3MC
# DATA NmErmFxUhP6FbY1cDvvCHDOB0HfqKj57je0aMc+9d/Oj/2RHn2Zr+oL9wydsoz/OY4OtlqN4RtmhqGYsI6p0H46t4N9C50PNFS7V
# DATA Cs4xTkM5Q8Wljrf2sUeZ5pf8Iit+SlCXuhqchPowMfapd4Izi8r6pN84glStOfdxaqeqf6RfvrvN7uAypPLJ03U3T9n+40JkRIzK
# DATA xEGLNKo34TQg4iFW/+ETY8x/9poJvIa40VvNhdeprwKFja5Ra8+PQd6RG3Vu8NmjcnpVck1l29peOJ3rCm+3YGgyh9dTQGwvS57t
# DATA iQ09WKQTmvL97d/KV2wGpK/7f/3X8p0epTz97LV3GPHw2v7jDZa3MrqpK8wWD9hi35NCdRL3Tk3hSmoKTkXh5VZRuKy6/TNVVzAO
# DATA WEmRiPVZSu6LENXt3odahptTygdZl5C2jDcn5G19dj9XHpBY4qFtDz7gdsvbvLAotPGpQnaIsWC1vfypO4ip1iHko7EbBe4NiUlJ
# DATA IVCr3i5u/9yJTbwAh6v5v9dMTiiKYlw3N6GsNbKWmnBZlaxP01iZbvGMWY1ku8GYMSpZRgeElcsyWMAnEDKbLkXD4ZT91BUjoC+V
# DATA UVUerigYJTNRtLc0PaBxELJFn4wWDFdKI3ajM4FLAbfY0Pd4YZD1xmfRI/bxKmWNCzlGL8c5eROCM+6ccbeTcVdSynGaWU4z6xJW
# DATA 3UbT8aa0tN4TwSaq2Gour5wIXM1zss9tKzbehsi98izozNVJf0PvxNCK4/o2qKaLpwyX2VlWEFinjJxM2KPNAASsFfPo9tdwMR2i
# DATA T5NPB+qCsqjlW0X+sFtc3fZjvxJUGj+hQVHHaIOkvHKq0bve409cZYsIYnOL6Vvzh1YIwAEjG04Sj7eSbAEPN8XwBvewdOcKKHij
# DATA mLzxYeVV58XVkceUR+SllI20TuJsaQTO5tJqKkrC7N+Ex+ED6WKVmhkIK9oNimai8oH13k5mRS00Uc0KAWmxXXJKH4sGTIieCSJp
# DATA cqocoaa5Q+FKBLjo6ROc7uKhkzWnLPdfzTPFhRGRbOTlYLFUFKZJPMVF3mgEwSqIxDHtAtpdmY5KqSLkUxHbTM6nFlJaRdcp5pZ6
# DATA hd+4DtWcz9Sci2XnXw4LNR9mnInqTNSdTFTbFnEGqjNQtxqez1rs9cNCI5lhoFvE0xzK9ECWSVkAtWJRACV13jtaBhECizi+w9lF
# DATA v6OpDBMeq6HLyWqh4RHFC1vOZqdGD3JHBVeOromNkKCoFkDQUQwCaqzU7iPWt0TnscZbp04cr7FUZY8CKhh/UnQgZcnoH3Pjylxh
# DATA 6Qkg5yMOR8VO9tyYbmkzq8hsfGDoj3wu2pXWHaZLtJ9aMRmxcwCjIzpGuS/eZmGiRWpf8ua7LB1bwTiar1tCjrL4iNP+Nn/aYrsW
# DATA 2eCyk8A2WBTNfJPZWChj7K6WxnoFALvOjUsC2B8/2Uxgl4wVAjsmcZFmpCun/akmsX+CLaOU8nSZyXYvroEz1k5VQrqYA4HMqVeg
# DATA Y2zCCLGBwusvydBViqnxoOa9HbPA6pKFdr1pnPHsUfa6YLsSU0R5E4hc49bKK8NCYgCCiF6XKj7bU6PtSzXokhn8L//wx805XKiN
# DATA ktEs6ZpGIvwLv2o8iBcGec+/5PQl1r4lo1q0VJO5PnW/oNqWso4vDq8uYrHP74/4UDjNDab9+GgJ7qNy/VZ0dyeoKKE/hmTss4Rv
# DATA POTfZMJ+HTl6xbo6zXarqx+GU6kKkLLOs05qC6Y4ULCVfb6iagud6km0ABJLdjeZpz3GeKD3YtDHKdCyQuuaQRkQDYKsP4oO9Z5U
# DATA FGqDgmkgz776/dtLVT5hnXHsKRWfL6NlpPPvfczgMGmjCXSuxHwSxuzM4QvquHkEAPTb0iB5TUIqTpZXVA4YWT/C0QLOT8rAGVxI
# DATA HNBCngKmNwJFkYZKFNq1VD3TtV8yI9/bUvfUICF5WF6h9BZpeEzj5gmlQWfmx+oowVgJZIdSLVOyYaJhpowC6uVmCwbHISzYJTI/
# DATA oYY8Mz2D6lWn1GtkPJeMIfFoLavmcLlFrOTcI5r/ahVu2H7PNF8/2TVfP2ECn7VchfONeetWy2FpdIT94HJAhBKSqSEDo02uXm8k
# DATA zzP2VeSWYTQacQ7b/UDYz1i8mmZo7N6Re1R1Rm8qVl+Mzvanspu1lKFFI0H2LNpGgrki2UN2rd5dqCd27GxRu/6oIxqME+hnhfCX
# DATA UknqgnglFt5sjB6VRGQT9P7z2Tfnf3f25dn/Ovvz+W/BvTv/BZB49N9vzn53/htB4/3+7Ivzn599hb9nfz776vy3q0Q9Oxxm5f2C
# DATA aXx49pvzX+Ops6/pIvP2BL1Hf//k0S1fnv8DPfeX818Cp4cY9NPopGrQe1+f/4r+/hY/M3HvTw6t9yJ4a6Sm2bx5mXI+jNFKZ7It
# DATA GMSGHxrfjCjfwxwji2EIpR+2FGR9A78/1NtJ0mgQz5XNlS3RH3FrnyYs1r+VpPeWxMtqQA6mZ3tpkDu3zdFbLZObQ+lJ1clXEj+W
# DATA qiSSJ+Wb0RNZa47RyY3QsnlH9VwduqCskAkj3jaNZkvH09uhzK4dqSdmPffl3PXAyyx+sz4ZELp3E3ueu7FP8m6JqmtyoqA+mnDO
# DATA OmuC/uVDByi0eDrFGR3AhKiwDYz4UvVvCwa43KieFWLv4kQ4xp4b559ynNdIvSsN76/IAsytDO03MLLvNLBfZly/nWFdqmQ5Byy0
# DATA 3rNsOjdB0isnVS+KiEs1ZLnJ0oiY2UMi4r8yJlYEiiWLs7LGKkoWx9EimfMzUcYH2hMylxbjZJjtgsn7GHkoy1jlGFH2wkPAG3cp
# DATA +dMYG0wSssqwZ0sG+ry60DvDbJkCDBaywChlMvvzK9ptn0ZoP5yiUy4Z0cEREiAcK0yq05UhCyeC+xrAWa15Zo6G52h4joZ3gzS8
# DATA XUaPneYquxq7t2q3X8Vsvw6r3VHxHBXPUfEcFc9R8RwVz1HxHBXPUfEcFc9R8RwVz1HxHBXPUfEcFc9R8RwVz1HxHBXPUfEcFc9R
# DATA 8RwVz1HxHBXPUfEcFe+5oeK12kG/0bkqFW806kXDF4iKV1553gmMV6C+NXoWNa5Rbxjqm9/pFLlxo0G3p/KGIhjTyGqCaORBNJv1
# DATA vGwCoe3J4amgVwiv0wwGjcFKQQUt3wuCYBx06sd+s/l5te31/KrfaHm9gP7Uq118qfaCNSW3iuZrBRRaqz5utj/vdLyOX21SPfCb
# DATA F1DnTGArmLigszYDuha5jyJvVc5GK8+ARuG932oOgnajvhLlRrvu+S3/8yqltUm1pdrxp60mxf3zatDTV66cAD+4AuiOW4UG3UkD
# DATA s0B3nWaj0WzuALobjtpF0F047A2aOeiu02712i0Duht2BvW+Bbrr+A2/2bkF0B2aVHW7veHx8GLdWubDfS+iXiAOKxJwaTFvBRXX
# DATA 4AWzfLmsGLSyW1acVDqHVhyRJX+/HdY6D/ylBlWPfW91NpzUM2oJbG3SjVt1NZLGLC8i5FTYgq5bv1WgTLRbxaytzRkz8OnVr/o2
# DATA GtwOteCmTBGHdnNoN4d2c2g3h3ZzaDeHdnNoN4d2c2g3h3ZzaLdXDO1mw9wk2Xxg666A1IY45fba/nfkGy85MpZLIc+SRTiR+9Gi
# DATA Xv8gXIxrPJPc44v7r1MO4DgqvUc50ebQmFnO+fa9wjvuyDf6MeNeZJG8i+14e74dyqdymMwKpPzOUjD87MqRM00QkymgOdLhDlG7
# DATA Q9TrDlGXjvm449TuOPVlj1NvEb69qWPW0grYDoZeu6yymmPWz1DI4zaoC0N1PFvVDHz19o72laStbnYzdmDkAvDqqbxvUt9zZkGR
# DATA xTCNWYCupbAN7PuXRSdsseC1qJq/WfhWxlNIMZthDcWAQ9WS/xdEVz9v4msumAj77XUR7loRDnaPLw+qoLRxPDiadOWCSKqHct1e
# DATA 9b3AgViJoW/FsGtHsBi9jbyHt1SLioxo0IuLe3iLrTwexhjghcmJPpD83ggqm+hD+Bh+xgMd2l5GZsm8wj5NaqUTeP0npx6UNFHJ
# DATA YvDyxCgSb73QuaTW8blxaoYqxCEFQQHCzBnrAAcJjB4Vkj4OzvwJrslRtsC6O0+pWIJpyhaxJQKA0+CswMjLqEOcJPNk7ebQFgOA
# DATA yYbeL0umke6I3qfZyzFmSGMGYHD7HmB3sEoQop33NRcDGl6eg8UOEuss2e2WrLNbX3K79bJQ2GcuD8QL5tZC8KrRNylIAjL1J2PR
# DATA bcU/6PMxUpgiWxmqz1xV6AVR4LgJbOqKAtJ1k1PXqEmth6fupoRYqn/IapumwCLSb6ZIqxrWWbU9V5DmPT16IrTMBE6l+alsi0WY
# DATA Zw1PC5IuoYeNEsupss9QwehDFilDCYFJTSoaKAqd/C7fYIySsgQ3x/ljFnuVKEeUxTrG75mJWsxzQIqq6Bkt4rTCyuwcG63KXrDQ
# DATA tOK9jQ9ggxRBkRWAIxhbov0RFua2x/oBoCsq1rxNKRrqiL+jJa6GNLtFbCgJnHsVnvJVvFNslhVVJ/QYi+QogopVzbOM6oSVRace
# DATA gwoU9WVTdPULV2P8CgnY2H2SszSdpbnO0iyMU85j6jymFxmoz16YUmKQKWXFNEmmrFLHDSKXp5xMpKmsFUmsqXpeEWdFRQYj6M6h
# DATA GWF9mqlg7FnxZPVOtSteRrwcBexdthKUuqO0SbXcyGGi55szdhMu4HCCDQwikO2gYLtAwcTisk2rTXcaPzfTXfSXzfdrlU7OVfV5
# DATA 891axrNofjz/GLE8/y7JcfEP/PZmlIsuDEG5/GAWUWcyZ9diFUcWtWWI9Q2/5R3ZKxlBs04XlBvx00gRyGgKgq1yk9MK2e3Y+9un
# DATA ejHC1wXGS4SMPSQZ1jzkVEfGPQSMrZMwG4uWqrbQ6dJkkl0HB+dW8u+Tk4Tzb0jj1LyYe416MfeaXSv3HvBCDZLNfa3KJCiWAui8
# DATA YDlKkcaUu8QvPImAL8JmXU8dwhWh0mvIrUIbvHyGtTZnmNWgJc++R30qxe7dlKeyc5nA5PkWlGpdo9Oy8m0BU4qXydhwimfLBYYc
# DATA iJZOihMrHjEY1kM1j2ZXioJnJmHH2NE4eQ7yrn2JvHsLVSAVWYl8fbCQfaVq1wjqpeyr8FSaTdQjKYqM5qmilApin7RG7EcfpuEJ
# DATA tvLqpQHWm82XBp4mz+w+/JJZ9sHm/MpHA4XwSx6G2rrWmfQucyqEGwF0n9ALj8nmMGY6WbgPqeFNFNppyKrD02TIJD9vjHVg72MR
# DATA CmamFa6Y5ROzKpPRQE+5zpq8aNHXkW32YHbpmhZszrh8YJSMM46BooGm8/ABriqvy8zzu1TDhjqvQq/R5j1DVFGxLZBdCDRdUo4Y
# DATA sd0YI891LfGOlrHiezE3Vnlv2GzkLefPK8LrZXFI5BivUbyAxKzN8fp/z746/+XZn8++BGPrK+/sD2e/P/vq7H+cfcnorS9XgV3/
# DATA hX763dk3YGyd/3vc4gmS6+wvZ3+kn74+/8X/z97bNblxnPmec61PUfaEo7tNAEThHaSaWoqiXmYkmYekrT1raRUFoNAoEUBBVUA3
# DATA 27IiZGvmzEyM4zhidyI2YuLsTmyci73ZC409OpZlS3OxX6D7K8wn2ef/PJlZWXhr9CubZMomCRSqsvI9n3wy8/87/scCwqEwKazv
# DATA 6Lc/esd/h5+KdMc39Puv+U3fHH1Hb/76+AvGgwHZpQhgv6avf6QA6SfH7HoeXCoZ1A9d5sjmAUkfkkbwgVKT1LjAZNadsvq9dCiU
# DATA YeFU4Iv7mP5FI3FBSruFC7WP0+fgAEChhJ8Ch5E3ovJ2z67SyI+D4VqM132sjPeCQxNTx/GyfS2qg7hqkNeSUrk8kpeqhdmS0SNV
# DATA LYcRxTM5nL9faqO++Z1cJb1ImBdchiomooUvO/NDHS8H9Nqs6C6c6fUozEAHGQsiASRVd1mGysEl56XobbAXSGSEGapgThHD83OI
# DATA ryXv7ainZ8fUu8n0WpxTKqULZK+TK+Nqe2axlT0rtNfJqXBoL2cOXLw5oGlfZ7MCXorVlquyAC7DANho/D/l8H81o79UzIVcsKBf
# DATA 16xRXQYHbCH5gJpibShlzvv6lBW4BkL1ipMwn853pmprBG+BYJGQKEjMm3RQnHJZcEJxKtfBRmSwx+zrhT8IG3BSuN7CJBgWlCVH
# DATA A1rUm6H4wh4XI4y1hGoIryH3MswTR1ibAmbHCMwDClRcHnBOURuHayYaFymLGcTukXUxjcahdlTx8hlCxzI0zJaC2Cz0YrFDDAjK
# DATA UcIcJcxRwi6PErbhkLPRHGhT0/lqpwFnmQVcxCTAkcIcKcyRwhwpzJHCHCnMkcIcKcyRwhwpzJHCHCnMkcIcKcyRwhwpzJHCHCnM
# DATA kcIcKcyRwhwpzJHCHCnMkcIcKcyRwhwp7NqQwmqdao9/PhMprNmv9zvPESlsYel5I1SYnS9+3av6rUG90Z6jTTWod2yFy2hT1Zbk
# DATA EJeRlEGNFSmFlOX7OaWe+bKr+HbhNXL5b96ZC73e9i8x9HYjC7zWzgUuqcoC96sNGwKWC7zdb3U6/fnAG/X2hYeeA73VhMUmkDK/
# DATA kYHe6q1cAGE9CFrVhWZBj3u+39qv1YeVluc3TyCQra4TzTMAyLixaQCZtNscgKwetBsbAMhyVwAgq/e6/XIGIGt062GrbABk3X63
# DATA 0gstAFm91m23Lx1AphvoWvhUya9rClnufjM66gWC+ia0sXwQmjeW9eM6pxYcmdajHSzKLHlm02WBUkNZIBXb8VApLVkT9tkgyr05
# DATA 51EQywDP8fzFeJP8OtkJMKmWeCQrxiMpmTK/zLJkoa++8ILKbT3Xot7bz+ySuei32J5bxkVrt9t5GhpWmVdTynLlVpgrizXWTv7G
# DATA Od+DcR86DJnDkDkMmcOQOQyZw5A5DJnDkDkMmcOQOQyZw5C9ZBgy1AUKpTcMCyEvE/V2ywV2uvOnCZndYbr7848KcKjuh7tswRbQ
# DATA 0T7AT7uokrdNhebTZbCOku2dz6L+tjy085kOmlooTJBg3A1LY7JQd4rqVbft4G+zqrM+uLEt0du5ja7gw63H2TG2nuDEPrfmONhH
# DATA qN8vpYhjH2vei/TTU5RUVvKgiXGyrXor6BNL+ikB496N3YnavZ/+GIbdbUofAn+Vftv5jJ/endzmMxkUJ/rxB3yN4rE0NbkEm6y/
# DATA bTL8ttQ6TOi50Wc1jPL8TaXvTHmvkHD65I9RfvYe45BU/vxlQtFnggflRxRL9oktf/vz1a9j0ls3jIbb25TUItK8c5NNW0DeVJZQ
# DATA TCjJpl5QQ+LUl9iNu/NZVmGsyxJ3+z7KOJuLl9UgFUvkquSQGgt2PssyDEWH4owoG6NXFTmPJd2QzujGDX1zaTIj0+QzFfNbcidO
# DATA 2dF9BY4ITaw/wKm7//jin9SZRmDzohv+DnUxFImF4Iv+zpqwcTzSDvshjkvy8sdi6J9ndeFzVUd4Mqnb5GJVVg/cztX+21LPdjGD
# DATA 1VXPuqFQqZfzLSqZjUVKWAh9XB24ldGF19YZuFmbV08lOEN60lNcvnZ3YdX8LAfm+pl1TeIhVFaz9qAShajoJJk54JJo8RmUaEjz
# DATA IdOn6hpoHpOxYicXaQr2IBrTdHFZoFhJo4fCuUxyzBinM3FGnQmnL/Hi60ucliRzHXQneGUl569fj5N5D4fgQeSA+Ko+OB3s4VXT
# DATA eBQnNDNby5S5jqIVz88R7ssgzSxqbFw0amaZiMkZWTNebolIqjSvsN3xy1oaWDCbRk6MXqZugYCn1JNM5MMWen9CVllBXE+iZY/I
# DATA G8tbVvPiCWaRgOsJ62EwS6Ys9RWp905o5B+LfkKspD6MiP0aoY+TlEdfoCP6uYbjTChnQm1oQs31r060y4l2WcPvSuPrOoh5vT6L
# DATA wNTKy1YZKa+3RBfKbkoYeSZhjIZ2MIhzI5QgBPQAVvLuQsQGRceaOoHMhRV8LHxCzTEYRn0o3kB0G84HkZAah2FPY8ZOy08xEVXA
# DATA ByWnDWn1whIlLQdP2QSeMoql6FjvXn1eB0RJ2I0mEvjyefXd2O0j3Ox7/Gn1ndrcUXwh/vw8oFPs3DulSn4LhuNqnfysLHIsC/bq
# DATA aXF8nhVlIxvGrySe7Q2yxvAJw95ZwkPjkmZjMh5ZiyrbMI32vB9HrG3VZfPQ0yfoYTXOWGxuwvK9MDYpDnvh9CIoA+fIv/rp8u+N
# DATA MH3isbPdQgtAG1fBnUx6WTJOXOEp8wxt0+EgGD6hvNLygRwebpsNgelmVKMXjrkMWLwNpyC83izR4ro0SF0M0yJrhqeFM1TW51vW
# DATA qiXfXqcxXvb9MVNnFpnap2wrqnNhuFLIEKtHY7AsJC9Zmk4WE1JF7wrTacn7awZihN3BOPp0FhoFRaqkNKEDK2E6wLRjEHBNRL5O
# DATA VcW9gNzMuqnT5uUJdVD3epKTH1DdYRVELdVsMKQmkyiNXIXYQlWoUYOEJwu3+wRSkHOmrMq9gGUXFfJvGKpJJme70pAzot79/DD8
# DATA rFpw43Qt+PVgyHaEmiqENosGxgFnSDqbYAJGCQySzqGaG3RFZ1F2Opc8XqlB7rIceaLYbpRr/TCEiCKmWmRRhOkk7EZMhBX1y+SQ
# DATA 9QzNJHwcHlxEDtpj32krYHl9FmZDqYKtoHIl5qKm4NK0a8RdGzp7Reox07BuACoPZdQBGdgw1bGDwhuQRYj6hSxjFVAWPqRKDR3I
# DATA fWwVU3tsri1U5QVybWRBOL+G82ts6NfI1zTn1nBujTOuCa10gVyaRrmqsjn6K0xxqubGu/HMWRnrvBvMZFzJseeN3rzMgd3f6uSi
# DATA vmYmvbyrwR45zRU96+Vcys5HYmcIfYv7fTENgp7YBTmHBO9qoZ/ZRjK9zrbanrKj/CK6hY95Qz9eIZFST5ueUX838/yqHN/EMJCQ
# DATA cU/GC5+5w8VR8FTuKMs5uXDCR/NW+054kwynxCrTjaOqnjZR1d9NVCsnRtVvbRxV2faDyPKnk+Kmb89iZ66Y+NWWRc+3oldZEzu1
# DATA Kmj8WXIugKd/4O3d5H2KIzKx5UY2P5LRnVdFWiHLQhwLsetgdilX5yY0uE/lOO5NCSKryMY3Y7UPc2mFA0dMIpoM9ixTO6fw/5/J
# DATA Nu3qCSpNzPsYJQ1IR6YMBwEN74DtTOhRMtAwA1NUoGwWq4GUik6oJltCSTV7fy2kJYbkeFhkmCXv2KK39MDDjIUmCi9KwetFv/hF
# DATA hCGF3SvjWQpB/vSQbN94lGZeVDtmg3A4OWHheK5Us8Vj26+aLQNL/sueLXr8AT5kJX6mwGQrlzTKcGpVH7FhucReDqvcYh3OErKJ
# DATA yaSzaYf/jeGFX4M2mGcQHv8Gfy/SDv/56CvmEf7p6Puj33vHf3P85dF3R98e/xd68nv6pLiFzDgEsVAC55A9BiJ+BYzi8Rd0w++O
# DATA /4Ee+ha3fX/0bxSOfvL3R98Dl/gNYxApSMc8fB5mGKZ6ZRMLrvAgniBH6ZmC8ldyh6ORGCycZOjOEmGyiB5QKQqNAIaVIXhQT6qN
# DATA nkkUdmk2vg5u+FBvY6ABgNFqDm1oTSZ0gV013HChVC4PbajqiL4NnA1N3OFfFu7H9hWrw30U99WelgtHG3IEcmDDKOXK7rCGmxXb
# DATA hWMN7z+dDNHLBNoZMop7s2EA8no8Zc2ekvcB+n7uu7J9Xrz4hY3x9KzZ/0RxmI24p0xlGxRcKPE00GtZwVjQMQtAw5Or4GqrZb5l
# DATA PSuc4clpcDhDN9KfY6TX3MKzDPAvh6fwygb3ix/bNxraTzmyX83ALtVyLg8sZuGzajmXASecSyVWAEACUpy/qGslVp9znE9QIC5N
# DATA BZUDbU1vok5RPLz5WrYVa4luWElj9orO59uGRELjZc1il07jLq848nisUXHMj+Na0qO59jg10Q9nSewFI8a/8ZAfktkQdSMsjeds
# DATA gpwFED7FwWIE3gvhjVI7qtVaIVkPVJzvhUGKCLFt153CFSNGInt1hFIna+uqqDuzQ6lfjlboaIWOVnhZtMINh5qNpjabWsZXaeOf
# DATA xcS/CAvfsQodq9CxCh2r0LEKHavQsQodq9CxCh2r0LEKHavQsQodq9CxCh2r0LEKHavQsQodq9CxCh2r0LEKHavQsQodq9CxCh2r
# DATA 8NqwCut+rVbvnpFVGPb6fth8jliFcwvPpyYV1n2v6pf3i+32p36zWG16zTr9PajWK5/W2l7Fa1S8anO/3c7lUtfvVLv9eYwdhdVY
# DATA irGrLZAN5aSfAPzaeYBfverPEfxqrays5dhaRvALW2HQXQQnWnzAVj0XfKXazgffrq4M3SQzF3qtXF8Tev1Modsl0vK9Wq25X2uP
# DATA qGst1tr7tfbGOe0vwgibvlf3m4NGvT4XSrfe7XS6S1GUp8cOSrvR2EFpghZ2sNGrt5q9E7GDQb/Tb+Swgz36u1exsIO9Rr1ZN9jB
# DATA Trdb69Qs7GClXmtVLx07aLapQfh/b6P5+hpun9i33oJdpM3xubeZgVJNvd4KqbuJgoLEbynAsK5W4ioLtD4sLC68YM7tbhuNukDy
# DATA 824y9zwfdoDXkD92mGydbpxDdW06IVPEyM0HdSeYN1QsbGA+svbmAj2iq2Wv8jJvryym5JNWge+T/1J/7Bn3euLgXLYW5vNkjdmy
# DATA NslsTzjgoAMOOuCgAw464KADDjrgoAMOOuCgAw464KADDr5kwEGb7ybJFi+GkNL4qDiiv/PjVvlGpVygmaX66YCLcEembBrzdV8O
# DATA yfBBNzSyG/wruHTdEQIOvf/v//DaZXzrheGk9CH9NwZtjcK9s1t+7cOtD1hLnc/R8UINAqEfJYgST3kowhKWOXyDuHidQ9zLdLyg
# DATA kyLEHfMUPvG73rGPsknqvDCdwo8c3vL+49f/LyKzkPbtaqV8Q66yuCe6BgSpUWYOIebOdp90ttud6X7Rz3SflhR2Hc56z7nY1mPC
# DATA 3kXTME+UvPdQ7W1tl6VwsGd6Ovz5ORp5GRSw+cPsF80AW5QEOCsBLO+v1Wf132Vql1QEeU0/NLo2b8D1GHi9mH5ID/iM9gM4IVG1
# DATA WApoEERJyXsUTdn9pAXfpQKKcPlsIseTVeHmju8HmZTRBKKNcZ/PImeiOXMKNwvl/CSEqRwYuR3YRFevdPOMTsFaLcgZQ84YmjeG
# DATA FnpUJ3rjRG9OMqOuhxjOA6mvTLToxQZ/8UncMYo4D412AzXDaG+syF9KQ03hIxMaFroQt+jjZlGSSAPgV+Ee1Xgc3pDP8h2iQwM3
# DATA 5NDWblmimbIx+OsxVGfgH8uUbGweDPsuRLXD4b42w31RUqBPopI+5VazGvbFbkeRheaPq+/l7bncszzmT88DvMvKi1NyVx6t4Sfp
# DATA XBXiyj20Cipdsa0EuPL4IBaxpngGwZgAciwCWRmhpWiJRNTwgL1QIssk5iGNa/vwIv8C8izJKK9eJCpFZPvF2XgXQBCGakcgGvV9
# DATA NpT1mVNpNGp2sFzYeVEA2iy8iU2SJdDkmJZywNiABWXOGHrAEoQ+H//qzCX3cOOSeygHzMVK10X3LmwRdIQBswGoOPaU+nfKpK9w
# DATA wuo4iiWUR4eh+FjSR9S+qQhkknpX8xnhMVT7org3HYZTBRZIVFzSSTw9f5HlUnZ1ZZb1Jqcss5+so5WpfknK7CcQIEI+dmKKkA2I
# DATA YmkivY6iBc32hJFFuUudOC7GfbJGDE+rHx6I5pQe3KYiCY87ZXGHS/qA6W/MXDGNjku/M0sPz19a+TQ9B8X1/sbF9X4AcDsvZlBf
# DATA n/Go0oFo6ZvGQL3eHvzhT8JDsfY7ARS0vEE8koaFycGYQ2ONurFHBZWAFgZUDnhV7IDvR08FH8fQhKww54Xfzl9o+ZRdWaFlo/Ap
# DATA y+zx6jLT47nqFUU5ENey8hJ/BPbhYxigJpQKK3AojhiWR+6qcYK9cd5dLt8+47uoE4IIGcY9sTxxbMqbzPjwHIsnjIF2uYB+L4v7
# DATA 9S+RyqYl8n6olOswfEzVT4pwKeeDQj3ASHMSa0OE+mKPj3ehBRyKIKGAAVWr4f6NZ9YIAGY3D2VRqo0UlK7o311Am1lMyJmK6WoJ
# DATA c+fCmLwMfjYrCOdoc462eUebXaWcj8352M642LjSJ3dJgtMyJZeZHkZAVG7YmMbF9gyhBpdEnst5svTeE9j7vMkay08t3jfDM2H1
# DATA +wmgsywU011ZlzJq3Emos8aGHLYD7S0z4C6eF6hde9vd0YmAOwkgA9yp7xbgbik2zpfLGhxX3hhyJ7t54C7EB2GMCQUZKsWcV3MO
# DATA RPVA5j3UISz47Jplxn5hW7t3gIVM3l/ULK/28vk+P/I4fIqeqGc9Rb+seazGj71Ndx/az9TKa9yEKxF12jTFblqy1KbPL6TOdt0d
# DATA DCgU7xOyPMfhYcmWfFa6ztIJwCF0EHs+t7QgUbA4vWFtQtMkZbpj1Zk6C4oTplc8cFPQxh0vDg3uW8Rjr9z9Wl2bX6y2nXkMuKQC
# DATA q1bKXO+sFk591EzDL9We3G6+pkJvWsmwUyhahb1AFv5T6frGFMehTBVZNXsySwB6l4XtOGX9VEsgewOI3AtiPGcIOepFwm4S9KcW
# DATA Qu49fa14/LdH3x//6vjXgMgd/X4RHfcvS/Fv9OVreurL4y+Of4XLHv3zNV38Hf/9FcBxdOXbo6+O/84g4b45+loppEPhawLtVBqy
# DATA HSbu2pv6bJkHnqkz3l8F+4F3vxfJWSwRvVf7Snj220+icNyjDoS/HcTJsGesf3i+ZxPxncKVIK6z4SHTdWO4tIUiyk6DbIFC9Tx4
# DATA KnxKDa23FiH3OgQ0WGvC47+FJ+E4ctmMwHQKV82RW140lweTG1B0mFyQwam5vurrJ8Hk7gUiCX4ZQDnefEW2I/1LY4K4rjCao8E4
# DATA oNxmRXfhQDnJs4DNnDE6N5lXmemUNmzUZGokHRRZLrqi8AIfDW/od9na3psF1CimIfVtb0TpkwKsH3r63oOfeukkVKQMHH+ntClV
# DATA mBnbQHAtTjegzS2vo6tNnKVt8Lpg55YnxqHnnPVwSdaDxtKd2Wh4KVyIV2cwXJK9sJG5cEpr4eqMBamkyzLDGArXs6FdBsXOygaA
# DATA 5rBI3Asn4FCRKWMGapNDPJtfkS3deDSaobvGAt47mEF02WHBkiIp5Us3tEf8JGQHhXj/kGGp2mxPIz0VGV/vRwmfok3TjQl3AGml
# DATA yjerYWKUIftkESbi51C/9mmuHPEBB94R9F78CY1oHievSxkY96cl76GOtxxQULCweSfwgt0iZwU0gsxoWjDJDPkBXRxIBw8ok6Ou
# DATA eI857WNx1/BeznDMHB2ckEfrAohMVQnKVce8c8w7x7y7RObdhqPXmQ52rTPLr3ymcREe1bPOMxwAzwHwHADPAfAcAM8B8BwAzwHw
# DATA HADPAfAcAM8B8BwAzwHwHADPAfAcAM8B8BwAzwHwHADPAfAcAM8B8BwAzwHwHADPAfCuDQCv4ld71crZAXjV5wqAt2wFeiMKnsWL
# DATA q2Q4OjmNluV7c06htN7KZVet3m7WwzmyWqVCBVBbQ1azXt0+86tblU6lUT37qyuNM7+62mp2ar2zv7paPfOrG5V2tdY8+6tr5WdW
# DATA 1rXmMyvreu2ZlXXDf2ZlnWvX7dZVZniuXZ/u1efN8Fy7Pt2rz5vhuXZ9ulefu3GVn1lZ59r11ZZ1rl1fbVnn2vXVlrXdriv1xlVm
# DATA uN2uT/nq82a43a5P+erzZrjdrk/56nM3rvIzK2u7XV9xWdvt+orL2m7XV1zWdruu+rUrNRXaZ371eTPcbtenfPV5M9xu16d89bkb
# DATA V/mZlbXdrq+4rO12fcVlbbfrKylr2/VQKXvVZmVQb5T3m/W36Wve6dDsNOq17tLHarUmP1ZtLD5Wg6OjeRpzTE1ALLi838gF6beq
# DATA 1cpiTOrlulep1weV8qha98qDSnkuNzr1sN5pLkWyt85EU69mNHXx51g09VY5COuNPE3db1f9Sj1HU5/jq4Om3gnb3X5GU69XGo1a
# DATA x9DUg3anH5QzmnrNr3cr5UunqbMzuNjhTfrG0ymL7RqLnnlbW+Kwtp+ZB6Kbpbhly256o0aTN2hieyYz0Rd3OzbgZ5XX8EGwzbZl
# DATA NKxtGSuB7lao61nrUlzKaVk3yy66RvCxhEHQiw9utelH/Cl7qhQ/L9GrRnCBrViCrSwEtz4PswA9tdVU71+TZSvz62TJ7gO11qtr
# DATA mFkGUHtBM093Ye5EQX55u7watm6X1Bp3+LK6xk5u9qs7qLqDqjuouoOqO6i6g6o7qLqDqjuouoOqO6i6g6q/ZFD1zGJU2g3bO8a+
# DATA o1R7D0X7IxP+uC3EKu6y2VYeHjKuXERFiqO4F+4KuoIuyjZbNOrsmohMFGGD7Fbq9Uadr2KWJ7Jp6a5mo/PUWCHO1W9olBqQjojB
# DATA BTGFMNtuSwKPRgo2kv3SkBfE0x5C5sLEF1RzbhullIbqcLtcaNR2YBzhoMr2zZ9/qP67tfuXP8C/CQfz0c29ApWrxWnnsvUW4fRQ
# DATA Fdj9bD8YR8NhcKtSmAxnNO1Pb1ULkIy7Vf/85xwVnsaauHyk8fSPZnt7YSrjIguQeQ/vvnfLYOO7YTTcxhtuzGfPj0t+i2nyb0Wv
# DATA C7T+dZb/yXR450KRAEQAhyb5CELz4yeRQOX9UkUHic5ZsUQwKojgBTT1ROiQX6jqDDTxppDnm5K5rGuQKAlBskUB6TkTMg1Zuvra
# DATA OnOKMzjqr7BkPzMTDUikzcnT0tNZJd+5jZEFjqs5jRyIfagEQMnFlrzhGMtA8MNCXqDD6dQ5nbrT6NTNibk4xTqnWLdE82c1y+K6
# DATA KNl5kwTtlDW08nEyUnZ385JuezNI40KYaZV2mwJbjMGbjbqRChrzO1Zj1WJVTKOdl6TLo7UW5OjMfYPKnQcYmqhr0REXb7iWm/qZ
# DATA jNtKMS0jX8EGjplQDwwgUDdYximyiv6UBeoluBRavp6M+XqqextisdCaUmpzQGx51pOM84SyFcU5hDY+JSWCca05hHzkL+5zdMKn
# DATA gKiJrBd6KvMwjVSrlPo43W8ou4jl9jKlWzU06vQ/MoaUpw0pKNYB7yNKxTQfFuqJyqGIdSxK3s8wci480h3MoFus9ceUuVLyeNKQ
# DATA G2gFDywAVPHUFnJU4cyiIOMSCn3Sc6OPZcxKhAgzqJheZc4SpOty5K7q4iVHVK/OjcXkxjSeKLYB15U4YTU5qJ+lswlGaGw5hp4z
# DATA 1bVu2LP6/2nwROAKsArZnsHka3KoClUPLsFBcJhZVDIASezhq/Yeh+zI1HFjsGtgmWIMIraHHK5b0XRdsvn9eNsnMWVaB4NhwHWO
# DATA 5g064e/Cg+JZtr1WBWQaVF4vUGioLNpFUcLC1oRLjqXkgh514ZEh2yhBOZ0AkaHT8Cc9wcgE5TTrhgGdQdbKjKnGVDttyqlsoD5n
# DATA GB+y13cesibKYC++wFk26jgD1RmopzFQnTn68pijK83May6sbC/wLyLMhjk7VVoM/T0d8IAEW0VZqNkjrNejUFjXVX75+VITPQno
# DATA YG3lENwcb5G58yp10PMtVR9Hy23yapXnNnmpo2bBkL8tay+Lx8Sk9XdjuKXkjYfjro6OUl+685OFU2bswSebZ4WQt/Usf+F0zUHA
# DATA 9EYarZX9urIZB1p5mvNHG2NssC0Xb1ZWmZYHZl7HbGLZkobBSYM97FE9XTCYr7yBmTdHLQffHL5ivi68PotQ8xf1tqVSLBC7TiR8
# DATA jNWLCxSRJCTTJeiQ1a0AH3PtHadfpSloAvCgeufRSIDflJuGhszNjbV8A0VE3s/PWlgGHNT3SRhPhtRCP+B1D+RFNv9gNTNFXBSZ
# DATA 5JxOeN5wnAaouBr0ZqzFeaQ0R1mVno6umvwZYx+zB12eipkmMwzshJAZJ2NJMEtRXZUq7TURe5CQEdmdro/YPV5v8FJY/Ic6euqi
# DATA zKTZAvcCVCXOI+TkQcKq2fHBmKZs9FM0ghy6rqxLY3NPJnuLsXkJRYodN9lZ8We14uernPMzOz/zuQ34ldOFy/MzG574PI/DYNWu
# DATA JebrKvjLeuWXfrj/dCL7dngVnEyZMJ6l2td6As84C8b0e9YlA/BtnQRg9jcGGhuj/wPuBhGxPMBY35Axls00YZ4rrFbZ8Zty3K9m
# DATA EKt1eJnm8cfV96LU2Wxjv/0aRvFiyngt3aQO3xgxoQzz7bei109ETFvB5PNAXzTxrJ1ULPVTcKZ51V9B/yiqcgF7Qqi9Uiasj7R5
# DATA 3MJO6ysZb/qk6FY3jS1v5Mg6sBF1DNR3zMURu3Ns1Pi0l+eMy3cTu7teShaTXqaxo7oBk/q+RiVzB5GEvGahPdPPL6DarBVIBzwM
# DATA ZmOaD2FBIJ3mGdUm/T3Aadjs4jUCizKEnj0BmRkIaellSt5dXN6PyN6xF8nYEgqfdtVqhifrEeqoQ19RM7HBIxCAzWGKDWs86+AZ
# DATA mxhRvFahDKUkiBS9CSzpYCI99Vx5Zg4U1Ttmm0hyGWu5RwySZ5GLnBW75NEcjmkJh4lX2OZBTMy06sWh4KPUzM8DJ+oAlYwyg5Gh
# DATA 3anC+5hR6GRO9os2a7KA2bM06sLLE8UWMvvovx1/efSH438E1froT8e/Ofru6Kvj33pgZ9MP/3b0zfFvF+nZ/3T0/dGf6b6/P/ru
# DATA +Ld099Ef6OF/p3t/dfybgkefvqcnf3/0/fGvQdFG0ELS/hX9/c3RN8zR/oIe+Ve6BSTtP3p0F3jdv6Fgv6Fgv8LTR7+jaP2Rn6Qg
# DATA fkd/fwcs9/EXjq59/SeE1InFo7AIspwgsjR3ivuqLjVTgPCGvAzMq+UP1AgRaJu2IEgwdk6RGTcZhooXpmhX1PslGmrPbLDMaF1L
# DATA 0X6Ih6gPCh06Ozffy7qHq4ZnWyVyecRsVatSa6bHF7hipvN3d8Ig665fpy9cGTshjfUXicqmcJldHemRTG2tWJjUvaSs7A0K7cJJ
# DATA 2fcGMXTqA0DMaUwda/uVMpjdToooyb0JldvCHnDx+ZLFQp3Ufji8jbgOeJsU2Xep7aUKUukN9eaU09S/1RZM1pqeFfv6xMg77LUb
# DATA 1s85rGu89elG85fDc3uFI/lFDuQbjeOnGsavZBSXmmiSnu32faZN5TIA1SaNsj10VfK481YeHy7nguykpDTssVRGMB1IGvrYCDmQ
# DATA JVtZfabpeSBk2mRwOB2MsgKz9kIGOjcUshhD8SZE6vdjz0RXwLuaucyxGceetJrlcN6Sd5d/ZIHuVMjErOgsS1iqV0VA6TSekLU1
# DATA UBTcadBBhskBO7EeslQZQDblVzdKRZ9CZ2kXzgjHl3Z8aceXvkS+9EZDykbzlQ0N36ux3c9iul+A5e5A0g4k7UDSDiTtQNIOJO1A
# DATA 0g4k7UDSDiTtQNIOJO1A0g4k7UDSDiTtQNIOJO1A0g4k7UDSDiTtQNIOJO1A0g4k7UDSDiR9bUDStUo1qNfPCJLuV/vlfv05Akmb
# DATA FeeN6NF2fsDFWq8PGuXKfrVafpu+/2I+H8N6ewnequX5rdqgXmvst4C3auUf6/q9Zs+ff2zk1+pehR6tlot+06tU6YNXbRVrNa9K
# DATA /6ffmsWWV6t6gGf5xWqLr1Vwe92rtr2qj7txuey1vVqrWPHtt/JOyDzbqtqrB43yMrbVkrpRR3ya+35lHtDWaXT8TndZKLUFGJ9N
# DATA SavmkcESrgXwamTVt5onmYdBvdlZiGGl0jh/DCt+NYthvXrBMWy3LyCGrUYWw2bjYmNYbVbOH8MqN4lLKuUaNZJzx7BWrVxeKdf9
# DATA 1vljWC/XL6+U623/AmLYbF1wKZ8GpCeDkAbpyXhmgfTatbpfbedBevPYPL4SzIP0+r12WM9Aeo2gHjZbBqTXbXZ6NEc3IL02WcfV
# DATA 1qWD9Hj7Z3GddV+qzvHpPrceWmTR5VxCfis/69GZwDYWXLaU99j0uF2s9MK9nVzIc4S+t0Ia16OgIHGfd35X2fUtS94M55tfv1ch
# DATA 82Rt0zW1kjbf2Z9btZKOYDy98ShnuRvHAo4YaF84NoYVT7kEVFvmgGY/nBWe8oIt4vlUbcqXBgrD8ko0sbyyfDvUwitKiDXZrNYs
# DATA n0xU3RjsEiaruN5tr4buZSVcsMtkzSxisbap5FrVSDm71xcOTwVQ61dOo7KCOt181EEAHQTQQQAdBNBBAB0E0EEAHQTQQQAdBNBB
# DATA AB0E8CWDAKIuqIniLlunhQCHPguQ8E0KLMNWvi35wafDdqW2RL3/dRc/FlFbbnMgIh6xq4Y39ZXi9vNyoVKoFRrUR0b9+R5S3baz
# DATA ox83d9/m15mKuD0uROC/jXW3t6uesHq9ndvjtbkEgJwesbL4qffIKPl0985T/QbpyeiKsnOfqu6M/gO9zp5jTHB0bHvns1xO3uZD
# DATA wNpW5AzdmUvVePcOJYiPX8IY5Xk7mh+fg0MSSnLyU2H+KGjulRQEb4fNufw09MMtdd4PHUVWK3dp1GUJWTllTPVRGHgP5dAxkjCh
# DATA DpYxdyZhU7Z4gdz7gXr7jlj+y8vmhJRM4729YS4lhYjaOWqRJIkD/Tm+f2SKQAEV412uldr2T7vQeURydwp7uZ/eokkEVeyYhqyQ
# DATA MmbcPZRC49fQ28qv+a3yrWq1fHuvtEf3wlj8GW64y0b9Nk4tFFSAsg0dl3f03eHTSTyGYFswfBiMJo/j/LNlf/HZG6VyAxGihIyp
# DATA iLb3EJj+IndDSS8a88om7mQP1LZ8iifby0JsUjFJAT6QzGTBRMAdt/Hhhs/MxrjvtbhIOfH6lx+1bnNd3LUmMijpQrWMFTgBQMKN
# DATA EnNd+1zNSVgZXyMYdXX4LKv7t1XV+Fy3AZ4CT7HdiIvw7r3dg2hME6sSnyrnevl0+stfqosHYedJNLV/kt7i3s50QOO0dz9JuHbL
# DATA kXRrnEb6OIukHvzyl5gP3r1HEQoOgohmf5x96KdHGCeXVOZTtqJ4YjUi6R+lodz+nGf7dp5IGUmc8+bF4vF1ET0SBR5IH8op7k7o
# DATA hTRN022T+h0zlV3S1fH5uGhI07pcp4ciM4/JkLdjxZICVaWwJEis8dMjJijrOc7a16TVSzDiUzOHap2WjdOyWaZlkz9o7URtnKjN
# DATA pqI2KwXIL0vs5j7WXXh0hdrEOLRlW7TwzbMTULsKlXExBejyY3zwtlEc6c1RNJ5Nw5N0rPWzpnMyF4zkslINn5eElr0hShO6sk7C
# DATA Wh/zpWjzcV0oxh+iy+L8jlk4g0qHF9AGstLExUkByP35jDHrSVZOmB/ZLOUla8kbngKV+c58RmgPTpYV5tYs6fygP6duvf5d/ubv
# DATA 8vPZjAcrp3pXZfN3VXLv4gerp3pXdfN3VXPv4gdrp3pXbfN31Rak1u/UT/Wu+ubvqufexQ82TvWuxubvauTexQ82T/Wu5ubvai7o
# DATA v99pmXdpfRXThleqq9vT1xdATF0PFYJ00UpE1mhDfd8TQSvh6AxN5aQDkxESswdgk3mSPoLUUpLr8iQEv+BVC16dh6MmKFrhmIVU
# DATA Pewg4KAFKDwyJDArYjRQLfefeuhfGWZgyX4Zb3umKkXDFOYNWhEMgyDCFKvx9HpgG0iZP/9iQg7a6qZO66dObqb0Ys6UTgtifeay
# DATA oLy5K9vndRkIT0t+84K5nbZ46VJY50qcLGsI8slD01KFiwKZ8TVY2WsgjvqciAVuKG/uZTsHtXElXks9X5YTO5Q7NJmGiiZUkoyh
# DATA dVcptAYJi1zBMUrGEJ4ms4rsK+af8tqLiLVOZBrPW7ugw4h5Ou9qKuABVVCZciNP6KmQoiG9Yx87EYUKtAc2GctP0suZkQNdPi2G
# DATA fvpchNnHmpFz2rFXKZn+bCylXLV0xpIzlpYZS7muyrmZX3o380oj69lrquuaT9U5YFnpQ3gAxnQfb0bKNNYnCZomZIDnGtnejObH
# DATA 7GpOQqWBvSDvTc3FKIBbyuCxmuJzHZpzLOeshkURdXMfjau6GfOIRKVr9JUxbMb9vhfsx1GPVz/HcZSySzzRmtrSHWTg8SxhWtGt
# DATA 5D2iIdrrU2giop7yOqkcJcbgO5S4pLx/EYEcGi1w6llmnZQa/WwqhhvLyIH53dNEOMS45L2ndLa9UdRN4smAHTAKHxcGXXbL43nK
# DATA AehWo/ta7onP3D0B2xpjpQavM+VROBUzIs2kn4cxNrJMQfOVDXiTgKGGVrenAXol7y4yk4KOJhMF3kYQ7JK77WFhG1cZvR3IXXaZ
# DATA ezgjgb54jNzR6HdJN6fKO6C38cr4muS9H8CuEW7xXmxU53GVzS0qCZjFUsAaO0+lLpV8Go/iJIkPlL63VH9eJddFw1Xfk0wcY19n
# DATA POtCA4Yx6OK7yg7xZmkThruBplNRYeBTlOV16XmT5fnZM4YFngVAzpAsOp6ChLAWxQJVivAxBqkpD2EDMhlsw5LaJCYNbOqlYhrS
# DATA 7X2cUEdTMOOgVAfgEAUTgBc9CRk+j5pH2TiSQmLyNFmWe6jKQ5DoKTKzMQZmrCnFk3Q+kWJPnUQKel3qOa9cIT6So5ILs3mPMKLN
# DATA g01uI63V6xa14xjD3Eqv8joncn6hxJTCmszL/Mr8ynO+1pfX0i/SrEzju9jX8HKJNJqMhSXMAm5EF/s2XjB5yCVrKusUnY7VCaOl
# DATA XOxbeekE+75XN8z8C2/Ohuf0xb+4s58McUlv68Vxktp8y385+v74bwGkPP5H5k7+igmXXxz/9uh/gCh59M3R14uAy39hgiXwlF94
# DATA R9/iH4ZZfnv0zfHfeoy+/OL47+nPl0K4VAHTixhr+R0F/vXRnzW9ksGYdNu3oFx+ffwP9NsfHcLy+s/bHslMK4lhJLEpjEWjeLY3
# DATA mDIjR2Sm1fA6jKZQ15BTxGYiNhtr24VMKYx6AcNbZcBnCyaVmRswKDALAz6DupZf+Yh3XFBfGA29T8hiZCPKkSyzOZzuBa4aY7m0
# DATA YC4PaMn1MrXmj7qaCvIofzMqq7n1gaq5GN4ukmZJxioLKag1TNlrQk1i4kiWG5TWhYMs76qtVUNqHofFg2D4JCM1kVkN3g7wPypZ
# DATA sHW7AY4b0SibQJ5N4XWCHkYIA40ahyEZ+ViAp3p5yHMDRUHC+fnJAsnyhJq32ixZ1pyeFdHyhEQ4nqUb488zxmuY5VmH9pfCNXtl
# DATA w/rljOobDeqnGdOvYEiXerkkB8yA/gzbz2UQLpck1aN5KH1i9lyglkkluYhlgdc5A2R71MU4ixRzcpdFmTc+q4eTWECB0jd1sG7O
# DATA 8Q04buMcam8TuGXO0Y0oqWQY7U92d2Orn3dAc2ysAYvyQSpUQO+naWZCychPlht2efcpZhEMAUETRmNeWzK0S1g7kbxAeYZRaLyQ
# DATA dddCQyrfai+kMXIUkdlwMAg5FoHHpglvsOuHjnbpaJeOdnmJtMtNhpiNpjQb2cRXbd6fxbo/t3HvkJcOeemQlw556ZCXDnnpkJcO
# DATA eemQlw556ZCXDnnpkJcOeemQlw556ZCXDnnpkJcOeemQlw556ZCXDnnpkJcOeemQlw55eW2Ql5VaLag3zoq8bIXtTv85Ql4uWXk+
# DATA LfyyVvFqjYZH+eb51fLQL9c9v1l+t9Zsec3WsNKqeNXWHNeS7u0s4jBHfrvqVSij636xRX+3vXajWKsXfb9YofDrv3iv5lPYrfqw
# DATA US365abXanp+pVms0y21YpVe3y5W6sVqc65M6mGz01vkA1Yp2s1P/Xq5WC97lZbvlae1assr7zdbb9eq+TAa3VavWVkMo1Xz6rXy
# DATA p8VKuVlsUaQqtaJPeUExqiOmxVbzBLKmidwCR89vyeu6UYLZUpeLv8GR8LpctL7U3ERAhbn49uqtWq12Bloe119Ny5OmYNHyOo16
# DATA WPU3oOU1emGOlhc2e/V2J6Pl1fsN2NaGllft1FqVjJbXatZ8P7x0Wh5X++J6w4C9+3O+aSoqnL383ApA2wY5dpokehHnpvJ10f+H
# DATA P9TCb5+0hrDc2FkFf7NieTKFz4bsyYOng+zVFiF7WTCngOxpB+TKPLJzWmWowtip+md7jCpsp7ExYAaxFdsI9NitFrjKq9l3Wb4W
# DATA 7KxaY06ckBOGaOfgcw4+5+BzDj7n4HMOPufgcw4+5+BzDj7n4HMOPvcSwec4bTiNUNQ2D6XxtXUDGiOIJIdYbmhpf+oZ+hh6g+Hu
# DATA ne3hAt9JpXhHd2SvUTBPP5Jpzc89fNi5McxXMq75O6VP4mhMAXxI/4EPdduYlx9u6WPnWVxK06fI1w+33lg4ka4CuIHPmhR1z+xQ
# DATA 0KFq8JNmKzmFcHewes3Baneg+iU5UH1avfBne9Ca/ZKZK20RRzTMaWHuxXEPZ4s99hOaY7ZMkkAga3S2n/X57OfhjCL/fcFa7csO
# DATA kl+0avvyc/lL9ds3OCaf+WmNfngoAnUobS07qSqH0Zh5HFIU0ngUQgiGj9ZKVeMT8Mr9xkQW0Q3Mny/PTo4XIINMtmbW2HnOCD1T
# DATA eIDjfh+OaX2gWXQPEbhUNX7F/OHz04iIL1QTOZAbZNbJsxGreRanWc3zzqByBtUSNbqsQjnBGidYc1Y7aqW9djlCNtyn62ZAlpRo
# DATA V7AGxiCexntJMBlYouLPTDftAgCWNC6/oWRorNHrlJrFYgwgkAsULFZjvx7MR8GEM8ca85cp316IavEHLO8tfSPVRiikoOe7BOHi
# DATA N2Gr84vGXviU8tFLxxcuH8yixe+M09kwmIp6+aFK3gESOqFOvO9RfzccXoZs8Yw1laaaOzNjDfC51nCx762L8jQkvnueiNDrcY6G
# DATA v4t9F9MfH4RJylJMWKlivr3IwjDbqBhEZMDPJtQgwwtWo25mneicBU3FGYAHKwwQMbgvWCJ6jjWZTcskyLxjkh7SWkHe6NCYH9Lb
# DATA GBxlBoC0FdXNclCmKI/JgV1/VBM6zNSnZECTE0fpCmmpLgCLWlfK0qWCKhCLS3mPIPAdjj0Gr4y7VFBafqqvqAeU9wWjkBWr3llL
# DATA mmLh6VBrJfGMKJl1OhDJ53JhJjGqSTxkfLGMA6JxlMwg5OXpTDM6Xsq9GcoLzGJ3oHRTN0M9vjjTD8ugcBMQNwFZmIDkLUw3BXFT
# DATA kPwUZOXE4llraSpeBzMtBsGEYcMBZhi2OHYaKt09LQU5JxbJqB2tDqnQR6FMZiydx6ktAImxcngAftJMcCHzEo/SYmfUlKnvolLY
# DATA D5coPW6qtsmpndx5k5c2s3h3DrPZEXOXO7No2DNafCoy7GhcdBurw6MWgF6jt2W1n4FV+KQsLGUB6R8zeLa5wioCA2bFcM8mi7Oy
# DATA e4WGbispeQi4eq/ZQgCrVH1+VTZGqJdbd5ie1X7q1Zh72Mzwwxo8xlhqNuo+ti1j5cidv50mqOoww1v8afWd3WE06nBE8WH1fdQx
# DATA x9iURXfel4/ZvTclbXfmMOXa1pTVeNvUxIiyxtDMlS42A0uzV2ekM8s5SHpmesqbH2SiqvIxnw9zYC7eSW26A9lZIBPbGd9e856M
# DATA TDLm420yFcqR1TsPI2Y19UKGCVFrrYqXYBSn0+Ghgl/iJ1iJRoqd12qE1xWNpzIEhiKHiV2S6SBWeqKBQM+1eCwDxcdGapZaLk+L
# DATA tXtbSWF6sMyUdagOal1tBjZOkYEf0Jx4yL77KOnSdDHLQsxRqWMAisvu6NQsB54S6hY+UVt0qCe7x6sEbBvz3kqY7aO4g0eo9wul
# DATA TlNRPEll0UxRwLgsLiK7rFZyyvxqr80v0+Qkw34CyU9qF3uhySp4E/iefB4ZBJdkZMn7gMbMgscqeREZYYfK/6QgYtSdCyVOdquI
# DATA O0xz5mnYYIxb2LuIrDIdzykzqrk2o1QvJtn0Nvw4Ys5HY6tW8aupQhxQLFN2xATJUK2eat8MnAjYBhdAq1ZWuniajZ/h/ds7zPyF
# DATA IZYAsSdfyLkAjnGfx+0QkrqMruCbnmmbrJ+iTb4LEB36NGp3RUp0USBXprbZl6m5CbVOZaS18hYG6SEW9zQRjh4hm1+khzk/xRZJ
# DATA gfGyZuTPsoL5lc1r2LsxFTGNkcPwkN0EWR0b0i+ZhaO8u+Lwo9ktNUH2xGXGGjKEenh2WOlFVLUoKtYW1IFxIidWdZSsFXFBgUaY
# DATA RN2l+ZYfiGVvnT0QmyuSDXfej/UuOK08zSaY2p0Gp4gqSUWJ1vldOokh9qI4IDKW2CScAs1ro8T+u4DEvKM/HH3lMdYL9K8/H/+X
# DATA o6+O/nz0zSJG7P85+vro2+LRnwAAO/41AGT/DlzY8a/o+r8dfUd//47+/v7o90ffe8dfSugI+htAx746+tPxb46+Pf6S/v0t3gQW
# DATA Gb2ZwviKQvhKg8n+fPSVo4k9BxTosaz8YB9PV6nUZxToSRhPmN/IgHUe2qntiYHYi6F8zt5GDDSWS1qJ4fJd6KMzYXV+A/UgkUjI
# DATA s/N4LVXsLZhLzG4fHzqcmO1DUR3BVdPE8gVyuRixaGyt4d7XtVT/ssgSG09xCND0sfgqI12YXCRPLJgKomAQpDScwoIlSzfu9x1O
# DATA bNNSu3Cm2L1g2MWqYygLYIcZoDoY8U57XgIZ8jqJ18dUwmMuHMv9mVUOkHRHo5AnvxhLeB0x+kXI9A2vF4XTJRixEyvdausk15ae
# DATA HUPsxBQ4jpgb3S9idNc8sVMP6i/FoshVDegXPJ5vvBhyqtH8igZzqZF2HmTbrZ5907kMlJidVnEMqx0cg5iew+JDPqFIgYmlLiws
# DATA Eq1J+jtgsA8nqVCVOGnTIH2i9qogAtEYJ8dwjE9lyWYoMQCMZKjeB69LwZp6GdlJqo0M611tEwA+FWOjHWwCrG1FZCAssQtm0F2I
# DATA psvsAWUNMPgIdgBWr9InFJiJRwTnONcmql9D7NLGHrLZNImkzOJxN0zGqeOIOY6Y44hdMkdso5FmwxMYGxrHV2bkn833eAEmvqOJ
# DATA OZqYo4k5mpijiTmamKOJOZqYo4k5mpijiTmamKOJOZqYo4k5mpijiTmamKOJOZqYo4k5mpijiTmamKOJOZqYo4k5mtj1oYl165VF
# DATA 0tWmNLF+vxa2niOamL3sfFqMmF+vetV289NitVz0KX+a1aJfbwyLNWC1/E99v1qse36t4vnlitesFJse7sIdfgsYsHzW9frtdrO/
# DATA QBgD4KtWbnsVeket6dXaxTZdqHitBoKse3VgvDwfYbfxumo7H2y90eq1+kvAXNWyBeaqtOsGzOWX8/WhU2vWwiUB1GtWAFWL7NVa
# DATA rBK1ZWSwSvO0z1v5Uq02vSrlQ6XutYr0l++PKjWf8shD5pY5i1cnxC5FurNWrw/qzdYc6cw8sEA6a5yBU8Ytw3DKuJFZnDKqR81m
# DATA sAGnLOhXc5yyfqXX7DYsTlm70W9mnLJeq1vr1DJOWaXVqDaal84pm4TTEyllGF/0fRtgvixHWZXdZKUWL49hSNtZJIGZkDXmLDfT
# DATA rdV/5NXpT6XOTsccmktyVEJQEd7MqaZSZRxrFTPdnXt7pca+QHbjzdk24nlag/DS6Srk4rdmCM/dpl1gDtnlkF0O2eWQXQ7Z5ZBd
# DATA DtnlkF0O2eWQXQ7Z5ZBdLxmyS1kcFoerFxymu+8F00GpP4xpYgOz78MtHMai1P8YJs1NdY3PR+GifKVpFgxVajVsfX64dXdCE7yn
# DATA cFGGw0PKjRsI+gblSn8mcmF8PKxv6Vyps1a8igRSFpBa+jBXoA5nQYMMQcqxm4APaeOAijmDJXp/jrLljh2f9tixO278oh43Pgte
# DATA 6xocQ2b3nfZ3radsiYCViffSo8pL+FrX5fDyc3WG7zKAW/nj1hdM2pqrDGdFbFmO1OwQucrpDAsCeUYRkFeqK5xdg+qdN3mCz7py
# DATA WoeOqw+EQsdKb04OwprqcxDQE534AKedw73ZEPJ9WnZuBDnRuA81/N4s4QoaJCMtfa/OxPO7dQTukm0dkfHL22Z1FDQljLKnj0XS
# DATA DmtxTuEn8nhzilgmWGodctqgZ8dtAScqOyFe3CObbJZ0jPDkS3LU0wrD2VXOrloj1mZXLqfr4nRdTmtQrcFtXY7ey1+P4wN0/6I4
# DATA 0An2RGMNkhtqYPOvXk7sAuhavAKhdoDoazlteJ7o09WfjqG3ECoZFuMW87af7O3MkYDGvA6UgXZUEKab0t9zOCRKNHXJ0JMZRSxv
# DATA Wy6hz6aeRbbkiHGEvZzZjyvk7MUPAaCPLdgywRZXGuy3T4yvfj7rV/WFDMLVKi+Lsx1jbNexo7wmwuwpYUoT3NWZjg0y6oS4qkdN
# DATA VPX3HC5sbTz9NbGcIyip9SW0VuV0ETVyruoWJQmV6s6rstdUxVOtMdpavtkl6V2ifUkBjb+K2XpTgjgfBcpiNlnt2xY+Uvr0CvES
# DATA oNkbfcD7cD3ZDZgbNGulhE8jUXHh4Q49jnZBfTqjXgha5elsby9kDzSAEbwyoTqIOAHGAlAlVpXGKMyBjgGoGGoalzDQ2Deu2h0E
# DATA VMiUn7E/nooGejBQCA72DCMWClQwTlMZyXtRn6VTpqI/xMrOntrKG5r4iBw9pIk4GkvUiTJJIpZVhqcRkfGCCdU5DHCbsp1eEGM3
# DATA N4I5c9eZuyvN3QXTxlm8zuJdbcJeE4XDe6y+B83iPgaZaMwyZsv5Tpovm0kBJuEoYkRHYZXq3pvCFFwYbljYbG8W9YAzzAZGCo3a
# DATA a28GACEPb/MmcB6asCBwaO6jcd0wTbXviYf6nzInAONZEtPQEUz1mMt2+Iga+AwmlLIDgr0k1PjKxSFT6R9SSD0aqk1y4KpaGDhZ
# DATA GhDiMuw5ClkTzgumqNAU4ds2tV2TIcOnvD0K74gANaBcXzEjEIm3eJ/3NykGp+bnTjTDCxs5BRTyNEy6EfY75iCokuFcMCzaZwkV
# DATA Ki9ZyXsLnC3uRtmbxtCuAWwuvosBJiBWwl33bjjlfpaTAdMmmM7523BwzUTW48MNYJ+sS+NdLUdp+nudyA8wa9PsHdX3Q2WyIJp7
# DATA GkyER7D+SAU9TAtMx0gNtVMbXWImvY/A0FMewgRTGy15ZEl4SOrA0g57UTeQElT4TGTlQk23MGfhUxrzhofrUvk+Hyk25hfjS3Q6
# DATA 7/JOT3VIZJYU4ElmhfGRLn6ePipSTgT4iTJfx1DiU+KfFiONk5RXqix5j8LwCVNC4JZlngfykm9V1UIrVub4Muw/FW4I1BbhINaO
# DATA 4iDlSW2wN47TKF0gc7AhdpLO9+OYOibOz6wL4lZzalI0+7T1GHQhnGjLza0aA9zb7MS+BDL0e6i+eh8MNdcAVVf03/U05RIo0fdy
# DATA znK0WSpvocteAin63WjKs7KEui0IQQoUUjFruOcUgclLgEU/GMo70UFyarPGxdOs3iWAou9SB6RbPHqpntHX5SKFtyjpXTA7+UWf
# DATA v1lcHHpqmtpYnH8GBOfou6Ovjn999N3xPx597R1/AUQNff2aLn9z/NtFMs6/MOrmXxlqk7/76I9MyfHop18d/e7o6+N/UKH8V3Bx
# DATA 6Nr3x3+LJ+hVv6Vf/kwv/KN3/Hc50o4F03FonOeALMxgNqNdK4wseH6B9CjINlThAve52zoAlPtAWVR7ISsGP4HDWXDCU81KZMgo
# DATA D6JgCO4N1xNw3g2DPr/F4W9yc0xu71dNv7EK4/LQN5K0rFvkutPnedj8rRg5zI081UsGh9PB6CJxN7zJlqY9A9T4Hs8IgNzjrZi4
# DATA 3WFvTiyxC+fdYJIbdzDH5HqmPdbYKaKmw9y/DINkpJamsslnlIoremEPteins20rcwkqLerFMK0j0wUO7gX8zfr6t9r4yNrRs8Le
# DATA rI+5I964QfsUg7YG25xurH45fMFXM05f5DC90Si9+SB9+WO0VD+TaDMgX11buAxSjUmPEJLT+YTo/RfZJga2JwbxSMNgrDKRmS4N
# DATA aBjsgh4nlCnohkiRKsZyN54lwqbIxledcDnKTi9BXnHwm3Fr1BQ/NwYHxrmuR28zbqd0Y282DPWWSF7CglfRSydhNwrTgol/xi5W
# DATA jtZhJK7XkDrboB9OD3OuQJUOxukyJppRwF1JVD5BDlDjADUOUHPxgJqTB46N5hyb2K9XY3+fxfw+r/XtYDQORuNgNA5G42A0Dkbj
# DATA YDQORuNgNA5G42A0DkbjYDQORuNgNA5G42A0DkbjYDQORuNgNA5G42A0DkbjYDQORuNgNA5Gc31gNNVaWO2dFUbj9+vPFYzGLDef
# DATA lkRTrbS8aq08YPxMpeb5terb1Xolnx3dfqtcX+Sf1CgB1VrzZ36lOs8/qdW7tdYy/gmXUj6YarvtVWqV/+S3K16lUqY/Ta/tf+rX
# DATA W17L85sVz6/79K6qV2lXP634jaJfpTIEMadW9Bt0S5G+0U01usmnB2r/qdKmRytelUKotj714UWueTW6p9rIpasWttqN8iIgRiJU
# DATA JBO+6PutkV+jfMGLGmXgeebS2m332kF3WVoVeoZKMSLzQ7FrauV6xq6ptctWBa7Jl8MltbnXDRvd/hnYMVyRDTuG24TFjqlVmkG9
# DATA eiI7ptPv9Rs5dgzFp9XtWOyYaqPNAQk7hjqJdhBa7Jh6vVOtXTo7Zkit4ER4DJxGn2e3GsqLxXFRqVt07LFzr0L/tn5km9tNNh+y
# DATA IE9G0ti8Gd5sJ3uLl8XCuK5KS9ZPycLysFTpNeRPLjRPWTQGKMOjqOn9c+QaKeK5FFOYsIy8uvwxrlFJdgvGle3P8a01HhVEkzLM
# DATA pz/qX21hsvXKA+JKWs0GZZnPuvwce2lGrAzIQW0c1MZBbRzUxkFtHNTGQW0c1MZBbRzUxkFtHNTmJYPaaINQS/ts7by2bjRj+I3u
# DATA 9fnUhXqsgD5wadfqqZRZlWr3TqR7r102iXduo51/uHUvU/PCYRVLzmVMOaw0XTB9zTNrzMkHd27YnRu2Tr6408Pu9PBJp4dXak1e
# DATA yqni11FzoTSXBW5OFj9T/YkL0EuH1hzefBCGT/iEo7TZM2rNZWPLxanNheFQqXJ3ZJWEMkSrDypH9yXIzunzxgrcNqFS7SXQnvNo
# DATA jhQODy9Bc+6dMQ41T6WHTZVSNuzlfiZQfQnic4/Z9aXSSCaI6s2pTtDYUYT6de8SdOceylFi+ADJlFNJNnCBSylX1p57H2etAyNA
# DATA h5YnIxxMFjIvsRdqloQXrD6nPDBGOj7TZMwpA2SHW3VCzKlZyjB0AdNcD2JJ1Gei8CIBDwnVucP63BuVMnXNXnKoMzpDNQTDA3AL
# DATA RyFLyOMWLFSRoTEclrx3o75pDgXgHoaLbVGpqI4RlcQb0I9JiAWr4aE8yd3LQZBKdDRRSKnVch0UlXc0NnhzRbuaJhVYYt9XAVDr
# DATA oGhKfRnAN5ioE/HQyaRH+zSkrJIM0Lmij/tTNznGyXfeZkDjCUsB0Eg9L/EzN1I9DHEcUJ3ilkmr3CHjzsmy8c/5yWOHnHT2e2a/
# DATA O4v9hbPYT4uUfIY6QLyYbxai13Mk34xY/lzBUSB6PvZ4L+8aiOQVywddezmNy+BDZiJHFw2HtOWgzkqGtDYp6GnTQxyrMtVBJn4s
# DATA nKKEpypzBYldDVKKancjiI2vJ/IwaADYQqehjXe94WwUjeMZTRGNTTSmSh5DxGYSDoeQdscYOlCK62R/jUveTzoit0+GCTZdQ0tp
# DATA QCapwhwwz0a/3Y7GWzDQ+C5OjI7F+7CLKAiKHVVeqjWW2cUmH58fCXkbwmEKLfUgZQl1aSFa43kECetk3fvZDe3l3v2WtKCUzMuU
# DATA l6JL3ntxOtX2n4gLMftHx/o2MkjaF9hLUL6h/hq2AYTtqRuhqs6yIfMxedFFYqyewdlqzlazRwbnbH15na2rmZPPUsLxPV6s1PVZ
# DATA CbDx0WsLSglpPYYj7EO7TdpP5rwpsBuBAZPsRNOOw5L3IBMDxCkcUWkzaB8uQ3YaBJZ+IPs02XfQj7peStP9rvGsdHgrWaYZKJqL
# DATA G2pAcorF8ZE1flnrQ0zGQZJonhAfLsF74PVZYiSqM46LtEu1zo1Kyp+Un0x5svSPGRDRXOEcB3Yk5HDkaeV+iodDKwVLCZBm8Zyr
# DATA iXx+VbYEqJdbd5iO0n7q1Zg7zMx9h9VnjJjDoV4ajeAPjZU1N3872Q3cquKD1ffssdnDyCz+tPrODttprJGdiJWi77wpqcryQcZj
# DATA 7S2UFWjbz4ehYY2rcK3NaHk+g6RnnPC84C/ueJWDVg7MgaR4Z7Bp/bKUzlUomXFO3DUJmI+x5OWEDbZ7EHGMEgiZot5nZivstaLS
# DATA 5CyIxGgRMzOtQUrD2CjuhezHn8KeheGnLThBKdnORDggjVRnyEJD2sieer+gAbdk+1c39KV6ZpscWxr5pJis0RJmALxiuZsbET1j
# DATA OV3nbdlTFU9W+U5ZQo9Wl5CuxlJIjybsg82XEDVj7kjE4w7sC7QyB2T/iBs08KSuK6vfYgeaNRA8L6sgIrUaQ30UUw6ULnYwKivl
# DATA /GVjp+D6F8yDTQvmQZAMWVQ2GI50wTyK+wxjHdOoxpqpB5jk0Qi6l5+blby7+3GEmTHlvXHrF2zXN5fKhPoXTM56apaI6eG5y8OO
# DATA +JWVR9b3nrI8/mp1eeheXMrjr8hgWejIZt3ubMhqslgEVCcJVePQk1XF0qNeilcScB6bhoyS9za1rsMCFSGZIXE0FJXjEfdi8Wgk
# DATA 8s9kXIyEJUY/RchBs158/oLKUnT9i+nhpsX0cNbpzPdnr7OIterNwvEn8WHWg2kxrpL3QUTT3d6MOvo9WYoy8sl6VSiz8MDUprzq
# DATA BjOh4527LOxoX/9O7M1NO7HXo6THOwbGcABR4xhbjWcgiteD2SjqFbFQyBLjqjx41EnZsIe00BSW+QeB5lJn6/w2bw8lbHo7ComM
# DATA J7VtAlrIcA+du5wWE3Sm0srbf7KN0bb/zBXJ+zvvx3rDodbgFpNfLG5e+meoZUAzFmSHLmW1cHo5TLTn2uOVsdDSQRzmUGj/19G/
# DATA Hn959Lvj34BVBowZff7V0ddH/3b0Hf39O8aj/dFj2Nk3R386/s0iGO2fGaP21dGf6Nnfe/QXB3j0TYFCPPoDfWP0Gf3v+6OvzUts
# DATA khrd9Oejr/FJcdT+DVQ0vF/e+/3Rvx//o6OiPQdQbrPNgbe8xtMDjV01ZG6IFwt5tcAzI95mFcLE0ywAQEPhTmAZGeoABM6ADnQC
# DATA uoEiulI9Tqa8ZwzP9WUJyzgF4OlYS06Dsjyagtj5Dp9m+/q4i7hqetp8gVweQo1Gi2AY72WIL95hyC+f53Df7EdZN/1mNLXwHRfH
# DATA UIMprc5toIbGMoJzNjh82smldeH8tPcEA+51yLjAji6a9w9o3DHTy4I2stIYh6GQkTBkkUx0d2pPK+Y3ijT+FCopYdY5sc5XgWwq
# DATA WY5MQvYsMmFWHxMYUREJXgOD1XSBrba+Xq42YuZa2bMCrK2PvgOsufH/gsd/DWE7w7D/UizvXc2Qf+Ej/kYD/inG+8sf7qUi5pNu
# DATA Rvnr1Xwug9uWTzgPkpwhBjpmUt05REgFOcOYzORVEtepAJ3SUYCFL7P05km/1AlTuLTCBEuTnGgaqLNjCyp6vahv2G6U7ENPkUw2
# DATA ZLYlylzjbTU4skIGBfslwu4TjE0KTcZ1TLhXfGqYdwIJbS5KeQ9VOhUaFy/NhulUTAXkS2Y53FYUM9CzpjMKYRSMZ318TmwjQXle
# DATA 4SdgmyY5LMZjh2xzyDaHbLtEZNsGo8tGE51NTOIrtOvPYtaf16p34DYHbnPgNgduc+A2B25z4DYHbnPgNgduc+A2B25z4DYHbnPg
# DATA Ngduc+A2B25z4DYHbnPgNgduc+A2B25z4DYHbnPgNgduuzbgNr9e7VbLZwW31fuNsP8cgdvya86npbeRrepVa61PG/ViteG1qkW/
# DATA WhnSP5WK16p7fpl+qXp+hT41ipXqsNH26g2vXfYqzU+rNbrqVeterfK277c/LbaK1aZX8Yv1uSwN2/1KrzMHPfObtUa1tgx61l4s
# DATA uUrZq5Xrg3qzsl9tvE1f8y8wYeUpbBVKQaVR95p+0W+NirWmV2t5zXLRb9KXmldreI0Wfdk4Yn51IWZ1H5C45qfFKhVqEXnReI8C
# DATA QGyHVbqQo8XxTs78y8J+s7ECc6cqcDdK+ITdU6n0lQz95jcZJMeqBo18CzDBUgAwbDx5uoys9eThVitf7ft9/q77X5ZDZfHXaovq
# DATA DYVxSmwcNyONjZMWaWHjwnqrVq/nsXF0U63SyGHj5kBygo1r99oZNq7WbdTrzQwb1+t2O/0MG9fuVdvl8NKxcWh/J2PjqtooEJNA
# DATA P7OCH4dkzvkX6z/yavSnSn8a9R/ZQczx4t4Z0VRiWsBWYMTXe58VO+irHXN7mlQvl2/PO/PE3VNo7R8UeJVsxYqYigbgVZPPNl0q
# DATA KNWsvPCqST4YT++nyBkkZr6EXdXaxae9nHmmncqkCv3x69rkZ19RNCULq5sD2WkfNvXLlQX8XHk1X87kfsHOgTWmyAkJZCvBceQc
# DATA R85x5BxHznHkHEfOceQcR85x5BxHznHkHEfuJePIKYsj3wFEYwp/F/beh1vS5ijhN+Q7FGE4G9jE/HDrcZBAhZYf8eRmNK8bfIGq
# DATA xZvYTLft79yg3OiOSh/Sf+O71inx+z/NH8Pjh98LpoMSz9C3OZwf+6U6QsiO9y05NJ4p30KKy3T7GjWXHVtxh6jdIepNDlHbR5vc
# DATA WWp3lnqNXvKzPWMtR4ML+qzvkpPWD825QKkjhbyymjnUKwdWlSALnyWGHX2gdJjlJG/IKvvZ4clJcIjJtByehNbK2Do5ubEG8pui
# DATA etwRRlQPBCq8OjAdOjoCp3u8ie5xN0hngZJNw6fVd6JLpazFrR/Ix9X3Ugfbi2PO6J/Ix+dBATnLi1OKIN5bLYKoc1VEEMkoSw57
# DATA 0CEKxvtBmikg4uQkNS8oiHdjdpvMJhOce8ZGAxxG8xKRhUyB55DD7OwFo6YWljxq1RGODs/p6PB42EsOC14YpIfcUM6veziXhiuT
# DATA qLTq38UphpqarHSqYTskM5iRWdl0Z+mAam7IIrk4gy5HqAORq2YzJzMiYFXCLhEMAwpqAO4duohMmVrpOfDx8BnqB/ylHc08OZc6
# DATA dZaA56BgPti4YB5SVS/CrXIIDXBLOZQPNheoRCYhtx5uNrqBMEgGBUf9ERqO1g3FOUIoVkExPJywbYgMt9Q0RHAAa1syvkXDQTxj
# DATA 6dHz67vmknJlpXTmzu3dTTu39yLsnIGGxyyxlJFpgkJzPuwKnMYT3XT6UTKCOOls4qmCiROWYONfRb3kgBKVxB3p7pIQX1k3bDYe
# DATA kFEFdQNbxuM8RZKL+ZWViDVInrJIHq8uEjPcSpk8ToJoKHopAZk1plDo+xTGCey3WHK4R9MeGHmomoaGmQSqOSjNasCEtdJMpiSR
# DATA ib2JCMvwUNTezl0w+ehf/7byaNO28oHMSWmCGk2oCpuCQe2G5UxTd9kiBMOah3GejkLVY5LyeI9pPni02JirkFmpaIYrkfApi1qj
# DATA dOE5PXdRzMX45dU6fhHkRPTjzrvlvFubeLfsKua8W867tbEXa6UT7HK8Wyy8ZQB4gbcXxyKKp31b11a/dp3vC0caPNsDtuDUErop
# DATA Noyofcj6Ws7bpJZnGM00xv57nqiqhdLt7mhHub10w5RJKUpRQjXPm64su2JcPxXeXZug50YvNorYQKrwtupRwFte9UbecMJbr0v+
# DATA agcZryChlseqXCdGtSzvJ1M3mpjpBxdcU74i9MLu6d3yfK87Wu3H8kt1diBQYFGY0N2leu7+BV+WsrCMo1A23VAQ97V84Vwva5lJ
# DATA KD+KAh8u0qmS3Ve26ZJdkiYeiXk2ofFwKhvSb0oQ5zSAxEjBYGS1N1vN8nEi7lchxqIfWFCJHrJe41h7aQsyY2Abjr0iwV4Qya4r
# DATA bIkXjBTNHkqegdxl9bTkcaEVePCzgCwsXpkFCb3KVFvHeB2sqUk0FowVwiSL2EgQYkGRFdRwaAySjp1DaZ4izBdAgdJeRUxne+DX
# DATA 8k6BbA1TTVvHWoKS9Soz2ckZW6iHntkuoPfETdiG0XhZZPULb3hmQ40zPZ3puYnp6WzNF9fWXGkdXkO1aj7RYU4XLJphQ8sMfQtm
# DATA J8cKFPIklGXCVFuh2UMsu8Sd7/VTt77+kq/8t5zTufMq9aDzDUsfC0S45ghXS074WWcW5UIw5G/zItzzx/WkmXZjTBbkXYfjrpjf
# DATA Rv/qzk8WTvvxDj4qxAVxc+sp/sJp2UBYPDu2ou2xOTj4QXDI0xfoORvD7B4v2cnkaGwWBeFP3KOQJoeyvChzJ9AIJ8E+z11K3kNe
# DATA zppqC0rdo+wz1Eq4jMUZxwbP/FpXgPVwstI0rWOjSjBfme4/nQwRaho9xdZ1WYaU6n3lcI8rN54yTBlVqP1wuDej7sKGlf3L8ZfH
# DATA v2YsGQhi3/DnPwFdxtiw34Mohl+Ov1yklP3v5sdfHX179A1QZP/OF35//OXRn3Cp4B394egrRpH9Gt9xA7/u+O/pD0Bkv6PXAWT2
# DATA Df38FaPMvqUAvsNvx19QMN8CVnb8hUdhfEUX/h4XgUZz7LLnwjpE2njqBX8Iy5Xr2nsLRNIgeYJVvmAcFuD2oFlpwnPHSSDTHwwy
# DATA NEPFUWleQ4Jehjcbc2CsTT6LhsxGpRYd8G5OmlgGU4GkhtiqT53ZWmqZwKRDGSgdtMy2Fa0O46rRZXOlcnnksl4k5zBTc+cb6gpX
# DATA 1AV6GcY9cydVOqmJyQXDy3ieH6W8AQHNgXeG6ag6gtlmpXbhFDPd2fQjfi4YilMp7Q7C3ky2iQyFHQ/JDwY5cy/msdqr59eLo2gM
# DATA WzsYUuXGPpLb2tPL6AyxwpKQAhaQQjRGFyxmoLKMpE0ODb5506q52sTJN7VnhS9bG3lHL3MWwIVZAJpbdvqB/6VwEF3loH/RY/5G
# DATA Q/4pR/xLH/ClPuYSb9PLrkXzuQxuWS7FXihz9FQ8Ukzh9uJ+ft8eZ8N0QLHc43UTNLoI+zSNZcSIo1Ew4YTLa9FHybkBqp2gLmGp
# DATA RSOTZL8mj7hS7z0jzpZuiC3jnFOVwqPsmOF1MuADCCLusgNtGFARpIil18OBH7z8yTg+kNMRPbW5FNioSchFPYhnCdhfzKCKOtEQ
# DATA WQXrjkErNB4xbgrGgmggMJ7LnCFQIKdxvBw+5ThmjmPmOGaXyDHbcKTZaMqzgX18dSb+WSz8cxr4DmTmQGYOZOZAZg5k5kBmDmTm
# DATA QGYOZOZAZg5k5kBmDmTmQGYOZOZAZg5k5kBmDmTmQGYOZOZAZg5k5kBmDmTmQGYOZOZAZtcGZFZp1erNyllBZv1+0C8/RyCz3Irz
# DATA aTlmDcqTcm3QaLT2q+3a2415BFklbHT7izlZ9ikra4N6q8mfq4CMqc81ylj+3Gp5PuVwtVYe+a1ykf5Vn339eQ7qRTnf61eWQb0q
# DATA rYUoVOoUhXLlU79Z9nwfCDav4penPtzGrZPwYc160OwufVO9sYBD85t1cMm8aqXYrnl+owYIml+njPOrTH6rtU94Xbfa6CynlVkQ
# DATA tSKmAwEE+qVGe+0lIDOKSwYyo0gZkJng2LIWUKv2m5WN87ex5FWVcjN7VdX3L/FVVSGyyasqjeYlvqpesVPVKl/iqxqMotOpql5w
# DATA Bp4KKsddmobKSe9oQeVqlUa11ctD5eYRckuhcqEfNnv1DCpX7zXCVtVA5bqNbti1oHJVem+rcelQOdldWJRlBj3MVXkG4enVKWO7
# DATA tMT8s5+Zh8K9FVJnHgWFRfpbbRn9Df7P5v5BoSH+TxXyKNgM8lZqrnNr6ulZFuj8Aolt3uvyWfBsqpLJhcPiFitcX3/ZaVEH1ss7
# DATA vU5nh3nsrsVS1WownJVVa+y5hTjnp0WXaB06xpxjzDnGnGPMOcacY8w5xpxjzDnGnGPMOcacY8y9ZIw51IVoSjP8JIAWO1Ww2wY7
# DATA t3vnMzMnmaS7XE+kl+Lzy7j6kdXypeHv3jHNPupv/4AfVQ135zPFpdPKRRBDlTNfjDiacFctxuXtz+XVvZmsPe/aAf1YcHe4lCHw
# DATA mEsnSzr2vUV/58d+/YZfR3R0aHckgM6M5osoVBMzlptlBdpxGPZS8O70M4DkiQxBarSX+uGBdCATOZUnYl90iU8w5pKDjMYpxl1t
# DATA 1id4sWSVLD5t84RupySLD9vbQWG/EFEhBDeUob2/8+PtiJpG+bVG+Za/Uyhj0xe3eqw/7Y5272yP7uz6tVr5tQ+33qcqyUcsOVRk
# DATA kDJ8OJ/6w5jmrKObjfLOjyq1HZqB9VjPartS+HCrjLv5Mf3M6Ed04+JNt7OaI1mOGrCdcqxV1YHzaJfjt43UM2rwP774J2RsehtX
# DATA buwuK8zt6NV8Ib7m12+VdW5yqLc/3yl9EkdjepbBhRJp9fHGklf2o3GUDpQoql/XhYnTsuJwEQDiT8dQmRAcAJ5n6OH2XIUp6lqx
# DATA Y1cLajxcj0y27FAkb3OBU0kU9ayCnn9tncnILQ+NJwvnM4yDZAypQ8daOUOLW+iQNVtRVzoz76LA9Xno0vQp+hkrjhL2Ix2mfogG
# DATA XIRlMI36IJpTinBKEeuVIqxjik4vwulFnFovYqVO6aXoSDyYTbMGwLu2tKanjOxGVOI6yhhdhY69GCsi456IFTOnXI9LmW69vt90
# DATA XuaCEXovt2+pBXMlXL9Cj14NuKxIP8XJcuYhGWHvbTXynqSkb4IxUcquZEr6tfIyKf2qLaXfrJRtLX2/vlpK3zJoEH2OOE1MaFbF
# DATA 1Sovp5+72co3O4gFtXyO2Z1qWdsfq3X1axzPWv3kOxscZmNJmAva+/oAI6WbDyLeUUaxMIPQcuhW+UXlTMaEwqSB05QvN+34mM+E
# DATA XDm9l41nPBTKBOSOdXmuQC7mtQ8xbnKLt9+aXb2cl8rBR48G2oS6idyb8z9leM+sXFbSEaQnU5iA5xeJ8C78eyJ1o4wVbcnbyhlG
# DATA Y6ZHEzrL7s918mwGQfgjd4sS4KUqzNozkJxhPQ2GG7CYg2YQrNKgyYvO2FSwRf7Xck6YZGBu/oCRUK9QsG9LD0E2BOxEvsHzL26R
# DATA tzDcvMTNS06Yl+TsTzc1cVOTk2ccz1TiDmM8KriOBDJnmKncvWkmIgI8YM0n09ao9IKURa4gOMWaY0aEqiDKaaNAHJdGCE2LNcxP
# DATA LubQC9hmY2O/hUdrG2DC1/xAhOdCIczCVYr2TYmhCp2aKQ0zuih70k9niOYe/zZLD2nMHTPTixIonUVBQYhkeqQHWgbSc3eRPtGB
# DATA TgbxNN5LggkP1ZMQhrSS940Slh6TJOaHvWnAWOX34kSUddVYNw83FUSyZflJasUcsXBo3JGhbztQGGRsE1Qdm/jusTp1ABQ59OHu
# DATA Cj9NsBKDwMaLwkMOwgBLrcG3ty72UY+turWRnzceJQUGKSAQ4dQQhKHiPzWg5y4Lwin8hdYkzpT1hGWb195TxdJBly18AqvXDqT+
# DATA rknTXeywH8cgt84nS8yEPDd2QVXRVGQyCx/Ava/ejHwls20Agq9CNkgW8A8A9iLyWEvusmwbjJoCKtFYkgLmHby38SxV+aECjigf
# DATA 7u7HUY8lqVmlDQAFyVIaoGImxo4gtTbhk268O2X5lJ5j/ddCE1EOcJmU6ThjQT0nXB33ZRYGHbrRKO5J40bh8WVTVp4+PBf3+/Cp
# DATA 67LTGtZShgVvMuuQhWI9x/pz3AiDHiwgL+E6LJWVxi6GF/MrPZDYadAhSzulNrkuiY+ABldwrykGESuJIJTJC6lniKDtRd0dpXVC
# DATA z/dnw+Gh4q2omLIbJ+WKKuke5UiFrCwofcLBIFbqiNRBYicoFXEyQDuUAkMfP4+oFcP0xbOnHS3M2dIbq0E70/mFNp1Pywp7xurQ
# DATA 9p7/9bCwxxgJNOySjSqp7+tpYddHTfq5kFQ9iSCR7fvXLK+LhIrlFbIvmik2rzi+FCmm3G+s5o1C5V1oZARJjUjFrImHtjs0nOhO
# DATA 7M77rF0iXDGaqrA+sUya6H30O+55M8osZ/QekMwewy4XGhnVm+xemZnAppXd6TEsvAhSZIfqppvxcFXzFHsZdi6qL08tgmUOxrWY
# DATA ELhiDcl5QX8cFhjLEE8S1Og0NM1MFJwDM12VbTZk2I9wF9m5OW8r2dwQLba10NnS5imk5NSMRcm1gbuwzrZg671oVl6GNTsIO0r8
# DATA 2qaa/W9HXx/9a/H4b4++Z8rYN0ffHf2e6WL06fhvjr84+somjB1/iSuLgLP/G5ePfkcPf82Isq89+vIVXfyGLn8HMtnR7zy+5w/M
# DATA OPsHue/4twpk9hVIavSCL+nf3yqQGcfnK8Tp+O/AQGPe2e+Pvqcf6P4/OrbZ82LLSiNHw9Pi67xkZcibWAeiOZyoi/PkLabgpmj1
# DATA iCO18p9CZZEZ8uI9ivfZyxMkmVfJIiGieaxFmb09Hw2HM7Nt2qyjuGqa2ZKCuTyimfhU0oWXq+vzt8sOAnP3wzClEagrAzYX0gWj
# DATA zcS9JHr+cK3Iwh9TCxzYbKPCu3Cu2V3P0jvPZgamBvCiMYR0ZkOmcHQO8TdOUyj3HKgnEkGxc+49+CndL5rmBc2p0PtdDMSE7Z99
# DATA wIs9ujhc4JltWDNX2ziLze5Z0c02TIrjnDlr4KzWgMaanc0IeCmcWldoAFzG+L/R8H+60f8KB3+pnws5YaHOnkkLugyy2UIimW5G
# DATA WZUuRguMM1lW9qh6oqbeEtBTwXv78eMHjwrqYKlaGeaS4T2jCdkPvLLDycAIDadERlNKVFlqz4POUz3mboo3M1XBo7yGMljeAEDK
# DATA oi4wZ5kRkAecTZKwB99I3iiwjYECN1N0Fh4MjHFXmQdsFYBDJeahIKc4/im9JqObsVMlPUz5KKW6p+P4Zo5v5vhml8o322ys2Wji
# DATA cyoD+Wot/rMY/Bdm7zvsmcOeOeyZw5457JnDnjnsmcOeOeyZw5457JnDnjnsmcOeOeyZw5457JnDnjnsmcOeOeyZw5457JnDnjns
# DATA mcOeOeyZw55dH+xZu9ZuNM6KPav2m/3Oc4Q9W1h/3gh9xpmrMo8pYULbqlVyh8X8RiWf61VhOUm2t3IZ12uF9bA/h2+qtup1QXXN
# DATA 45tqksVWPOTdEg9hX2XxqM4fWqtk0ajNY+uW8cIaFi/Mb7cMgypHSPvLWq/lN6uLNadVo6rTGkids5IXNDrtbrCUn7YueRUhpV1S
# DATA 8ioWzWvj5NFDF5a8qjC+Lil5VfX0qZJHD50redVK5Vo0kmq1dXmNpNrwz9FIqq3yuRuJnbwLbyS55J26kSB5520kdvIuvJHkknfq
# DATA RoLknbeR1P3WtWgk9Wrt8hoJxeIcjaTebJy7kdjJu/BGkkveqRsJknfeRmIn78IbSS55p24kSN7ZGokNbC23vFq9vl9rDKrt2n6x
# DATA 1hgV/XbDqzX2qycBVFc3grPQMNnSNTRMNpotGma106i06mehYZbDoO9bNMxqI2zVDA2z0+32el2LhunX5efLpWGqzbwyu7OcPWrZ
# DATA zfAxecJOJrrtVGvzGvuSbRO5UDF/XbxnfqvC4pJZi5fMSi1slZFFs1yoasF8bcgNXj3LP6Zngcs3G2Z302xyLwlGuTW6k5Krnlmy
# DATA PL94g16pX8jzxbszL+KqHZLyIl+KSFwBC4FgqWER9amqXX65oN1uwwNzOngne4yWpIrdhgu+58XtQiu5n47W6WidjtbpaJ2O1ulo
# DATA nY7W6WidjtbpaJ2O1ulonY7WeQG0zkU0517UUQBFrM7B9FRwTM2gois3/XKtVW82bufmLOoxPjyMxzTikAzz2QRXbvh4slK7rdiY
# DATA 99UxdugHjKeD4aHhXDEikWJC9epN7O/frjAW8a3odUEqvotz5nJKeTKcpR4Emz31In5WRWnV83e9Sv1H5m2Z0I7MSykP9kNGdW5T
# DATA HH6MNf6dZSHZLEPrnKkThHGCMDlBmMVDx04dxqnDnF0dZqWS8mWqxujOGnIQ0l5QXKzkgI02vPPGkpC5PjpmVwE0lKGSQR8ykLEK
# DATA B189ASSon8x182kO2QY3wlKQoG9xBPmmsr7T4ARX0wTNcA6WoPqMsFmwZIJBUSfB2/7r6PWTgIhWcCYp9jWTmvrJaamcIhlibaAH
# DATA gFdUTILt906Or37ORNZcsGK6WaZvGFNtB3E7hVAiJEcyu4W6rkkUnlRdskAy8GR2yUS9eVLMG2tivRLyZ7oAPWXi8VAV8nMP/VtG
# DATA +jMWYmh6P/RMVMeE5cHNo2fkdWAbcJEGI54D8PIMC8KouWaXJlWsFs1QE+yNpOlNwTsYUOUj4zDZC63QVO72+9TXdmYJfBt4jiZX
# DATA SQiFpmiqBX6Uv1pmHinLcrMSE1WpQzGQWQfTrmcl7148YrcYdX0FJdYz7hn9p0x0SU3mevJEkChdpMyWySCzI4rXLGHfqhIf2oAa
# DATA +KIpxTjmiZsIrJgIOJv/pbD5T0s6uS5KkfZOifXIk7ciHjFFLZHXoyESN2bVHmpbo3At++TZyUs+X+pqJ6lLz+3xuAzwyaKA5kXD
# DATA T5bpkC4FoOTKTm+JkYq8DPD3Jux5bSIsvYNVPdfe8bqY1sbQOKXctyL/Ma4yYsFBgERE4zOYSpkrc3MTHOajbNqt8YpvP37v3YJ3
# DATA 79GjghqHpb3wsKC03AGxlHmRCC1OoBIaaCVVVmqkUjCyn1GazRs02I4beDTFsL2GqPhIOgPZ8LYeFnnXioSqxDpFd6EEOlbyqBw7
# DATA ThAlrBeC5heOu1AEHYcUP6XHWqDaS9V1oJfZRJ41r8q6Fs2Z70BOiLoWnBVrWkdbwRTZ4FYHDEPxZwiMFGa/aN+zAZ0cKklMFcuS
# DATA 90BzahBzXh3THVng9YNoOEvW0SwfSjBYuFrFs3yJLHC7v3Y2uLPBl9rgqpI4T7zzxOesu5XG+/XRb+c6jZE6wzkHnngKjQdefDVR
# DATA io17MQ+SefFx7UKfp5/NJsAJlryfYY/4oUG00B29WRciMiOMxUba2PjbmWjM9s7GQu6ZboE0T3y986o2/B7hmDc3bOhXpAqALTMO
# DATA 1Re8etNYiVPpvacJPoowN17VFWc92RtJTGMwNezB0ht+KmN6H9TmFbd8AJMNqRQtbhabxq038c6b+v0yGM1HQxmqyoAzFg+/qXfn
# DATA DbU5kWtwwcOw0qe+P6YyY+wnVbVpj+9UY0TBk8G4oKW2wbkDpjgdSLg9Fa0V8XgvGFOd6tm2oInM3UwCf+53iYJtuhn7i0o0CSHe
# DATA zYsH2vI6OSI/i5LpDIrqLCVuxUEVMJt5XFtZUp77lCQemsj8ZMKKKuYGquThlFXSJzx4UgYNh7qqp1Z8bqqCuqkq3Qou/Xrs9yNt
# DATA 52V5LyZf0BvRoK9nORnbRyuJK1J7Oohnwx63SzFnx7D8sPEcUytRV5cCLnlsX5IFPIwPRxwE2efgWQcQh7dk6MGi/yTu8MCpJOZn
# DATA Y2YhqpDWAcHH8YHSK9emczAd6Oh/kLCcPdV7j8VNxNnN6y3ab8xOZ7LGKZhAe5vRS1Fnx/fgB2akZjYukFCALOrbeWIEUv0YDnYa
# DATA zsOxvrenWI/Z2uC6xLwnrmiVnkDE8+FXN+595VlHxPR6RsZVGITDierPZMHT6otYBp8GyjgHVZiEwROUsPSYqHtYs+yFI7zAnmEp
# DATA sAKFIvNBxsKjFdhTM2XH2OBzs/6J+hmNNmSIv1i2/eeff/T5h+OtV/7iRf+Psj4cfowOIxrPAFWdHF74O7B22ajV/kKtG8/965fr
# DATA 9cpflLP//qLs+81y4y+88lVkwAxtjl7/Fy/nfz/84Q8fzoQQ0aUOJOrxOINKsZXyXuQiYz+yCuLde/cd6jV4mZPadzzs8RI+PVCi
# DATA sF4RqRSybff4sI3+/gnZh/pznL7Coxc6/WHU8dTlB/RV35KYB9NZR/ln9BUcycJwoL/PyHR55ZUPHt598OD+Q2yg3traeoXP2Lyi
# DATA Nlj2ZV81O5u2aTLZC2/1060d3s2IkyFbYPDdpF7xJqi+N7vDiGYwW7dfka3W/bSEfICb79HhuLuNhwreFs3XW1vWDtQtdgoVEXox
# DATA y62tnR3tXyqFT6Pptr9z+5X5fZ/5qPE5so/VQ/QG6h0PxvzmLKCwi9wqeD9XkVn+7o8Kr3ie99lUTpHc8nm7Q2EUPH191sfeR79R
# DATA bdUKT8jKfBTtjYPhra1H77z11++8++5WIZ32ovjWz7foOg0PW4WtSTTBP+r7R5/vqOxRG1PDJKGh55e/1BtVUw7QvsCL5bLxdXWW
# DATA yB7i3dxpLf18D2PBNFbHKlT+62jwg69xQR3yS3AwCq//gRweKkXpo6AfvkN20R4OKeD2EvLrHlayd3Dn3DXvVa+87PIdPm2zNA36
# DATA iorrAQyZbRXf+TfS/dmprfmgvM9fQSV+5RWaQsNN+THTjbajcTqhUfhjKXSe/O/cQhEjC3gFHZdgA/CHElsTKaZQ21vFrR38MAzH
# DATA 2/IgJaTuV3ANTyZhCfsJeBvxdrL187vF/yUo/qJcbH9cunnrfyp+dGMr/0L8lwSYyv0MCbuP4t/eeme8j9M+Vk/Cz2zt8DNqIN7l
# DATA lp5LzI5OhNzClWWbav70Y5zUpZjWvB972NCr/lkfBw7XC592ydZNZSKpYgB7M+mhN0B/VOLdD9vqnag6H2N/9fbOTi5PU4rpNBh3
# DATA URX58YKH0wMmO9XVHap2nr9R7qiprsKYhomKnb6+q+P58/JH8oO+EXu+5SY+lLj1To+KZUs9Ho73oyQej9TecPs+ms71oz2697PP
# DATA d+TK/fG+HAmykzpfCYJin2rAR581ap/TzSYWO7rSWFljvXwue6xfdlTjOU8m4TS0HHDhr5isS6cRje0cyF6xWIx8fwFHbzmSW2Tn
# DATA 4WkJhi8k8xeelstzl3a31J4VuZa9b3myfjpOZxMMVzS7sKKpEoX/+LTnx5Qy6Sl4x+A2vabg+TvziVneWj/+yGq2H/2YnsSp1ZNi
# DATA pjPcrj70nBUzzvISDY/huKcOoJr2Ohtto5BxS4kmG9S98Tk/lD3WISh7+GmUfKXe2KD53reisawJ/yXWluDY8EaK4/VG3H2C0zX4
# DATA hyofPZgc8vSpIPPlLtdHnGRAwaFTFpgemf4lFSR2YFHfq2h5sGUwp2V6n1okui30M7ik9MwfPmiWDMV0MR0E2H8lzdX0frsU2XHI
# DATA F8WRpUyX0uMQtkuQHL7BwoJxcsjCdtHT3S168TjoznCg3Izk6LxpqtrTN2cZSKX2sbJiuFc1t+x4N70tu6aZR7TPPEZ3EqclEMK2
# DATA dTgFXPnJxx88/Mn77/5n75fy7d7D+3cf6y/3/+d77xa8cgykhwmTU0c/93scWvYK6p4OJPLU3MJglK+Nck0NlGiHpU+o4LZVlbnB
# DATA TTN7ydROOGe04qntWlZiiQps++e52/DfVo9rCbpLeQqfiuLexUeT66Us13dx2AvWZQl/1WhAGoRPC4tBF4uqSnDour+6hafNN36b
# DATA Mafl5TTNLvaSeLJ7FxbXsnBTvURD9unuOKb3HBQx840AkkklFCq5Ikpui3s0U5A7SwNELKmK4Elt8+pQdKvBd5gpesDHz/iiDOx8
# DATA sB8V4CyYzpLwY9lCufs4mamD1/qjWJ+71XJB1k35+k6+IK0WowpVG1HwU02287dvNlzpMOd6wJUtdLNuki0xL2Kf2NTuJcW+UBb9
# DATA fH20qh8bZZLpwXQadAd2XD9aLLVl/22a5/7aTFcn8/IG9ub5/WHvM79QF8uAbWjYnePptvqm7ORbp8hba5IpkVrIXpYDyF5ifu1j
# DATA y8dwrnugaJuMXYzGmiJKRlI+NIx1w3zxeJJNu9bTb9z/2fs/fffdE0uOnqRZ0rIns/Kq6+J6EwIOO2oGgJFoW1VjnhSh59Yz7NLd
# DATA ZI+9+g/4F1V0chvO8n0cqN9pDlBURjelSe+9sCrGqmfYhF/6BN0GW0w9yP/g0VRFItdh87mN7Wwyg/tKKj4FT77xBENZs0+B4fTu
# DATA 8z8QYjUB/aUa8W++8brH086U0aCqq7Ud1iXvJxi0A4/RPR52L43hpex6ND4FEzJq5gyRR+zcv49Z2Nb7MfZxZzWya3zoHb7ej5JR
# DATA 2NtCGVFF+/hjmAMfk/226219/DFK7OOPtyTSUnzX1JWY4BT7KLwMt99m/r9KrVyr+3P+P3gFnf/vKv77yx/cnKXJzU40vkmmgzc5
# DATA nA7icfWVH/7whyzcIbxaLL7IwhjWGLDii+WKeBJq6K3ewPVQm1Eez7aGQ+oW1ngFsUzRqOlv2NOkPw+CFL5B/TWCPlhiOQHP7k+U
# DATA FUTzdTCbRkPzjecQ5ls6XOOFDBLbCTnvlJwOEiHgmQvUyHIeS47yLBlSjKXn1PGmazz5o46FF088mb3PJK9lyMxGTzUsUCbftTs4
# DATA mNQ05/E6h1wupjTYUscyShJ+Eqr1P2SIzDpTLiz93p9O9pKgF/4Magf6xYtxMeMS5Y0MV9hFtk1zozRzF0n3uiQh+jb1KGv3oBz1
# DATA czLiW94anuXwHZbHhmee2BW6xbuotnZ0eDKzmLCvVE37sctnV6Yv8o4pTsNM9QSKg9bTW/mpFKUfp4cjbJLZtoxJTubW0f959LV3
# DATA 9Iejr47+/eib418d/+PR7+jz10d/9o7/hj788ehP3vHfHX19/AVd+4N3/Kujb47+TLd8f/Qnuh0//Oro2+Mvj/8r/cRP/wlfb3mY
# DATA PMCclxioMVFFRw47lkaw5LflS6oMP57Efhzb5h6vl+5qJ0l/lSMkJHtD8rk3G01S/Vs4xuLmx0HajSIxSrDPDAPsbkXP0MQR0yvw
# DATA jJglndQsd/QEfcbETG1L2dyW7AmK/W4uRUuMBkwpuwMqsm2Ej6JbOefEDTTXRJTzlQFr9QeYUu7ydHKjuSgybWfZz/3hDGozuZ8Q
# DATA B2xF3tb3UNrHsXYjqjuSkGFjWphKitX269A9nH8/IAOCZmH5yJlp/cf9njVrz2Wfmro/fMOeur/xzsP79x7/5OF/zkd5YSqdS4f9
# DATA tvxzS+1s9Syj4Jc8u/CMJBYNrcT1NeVMmZum0R2zMTc5/lG1Z1k/Vk4o4/qGB0qprsHNVF3h1N5+7VbmIPso96340WflQsP/3Pp9
# DATA 57UPSzs31IWPPqsUGlXMdexXW73Afz/6llr7/6A2/ev/n713b27ruvJE+29+imMn6QNQAPgQLSuQYTcl0TbbEsUrUnYSCo0CCZBE
# DATA BAIIDiCJTaPLj0l3+saV3KRSt6a6qrsnde8HUBSrrTi28xWkr3A/yd3rtd8HAOVHT810esYiztlnP9dee+31+C3gB5+qDf6F2vFf
# DATA Js/+gBv/2V8UB/hKvfxKFYTN/6iknqknH6hnj5JnT6HEx+rvp1pVjZyPlIFdgDwpyCSow0h7PTbgtJDNCmoxayr52ubpJ7nivRS8
# DATA QrPq0hKwGp5XXQHs7KXmoLOk2krr8XlefmU5mIb/69mnwOkUU3sEvE7xPxqeGqmaE+SQavxP4R3wv1/gZHwB86V+Pvvy2ZeKAz7R
# DATA +mxIeJ/5GtFS6uisV5LXaqxnxuJF+L06a32gN09hdZ5Cw9D+Y+jmo3m7bzg6sf7nv37+EXBxvXisB7C01KhhIS01dtTW4Y0Qhwf/
# DATA DS7gapz0gonAseroNfR2j1Pl3uVq3a5OZuuULum2Pja2lC+8kH+yru+C5+Nvyb2/W6pfKBbUZlwye6/S+IeyerpYXHojZYVuoAKn
# DATA CsFVrwfATUeoMFaze5ZW4PJeqaQT8vI1r/CTvdW6UJKateKMofvjrTpbm4gHozvKhnYS/A428/PfPPuiZDiA7Hbc+Y9U4UdQkSqm
# DATA OMOzx8ADmD+oymWu//z8E0VhXwF5AuWq37+2ZpXACmM7mca6UoedLOO2pxC+7PSYUKdPwoy9gBPyZ7W11JInOKjPWLZRPX7+iRJq
# DATA 7B6zsomNCYBeaHM7ehtjczSs83G6c219vazTh8tDAa5Lar4ZnBhLwy+0WakisBmRMHkF4CvNYIGWFVnCczRxqGL4b60WcuhDecmF
# DATA s/BQ+j0N4/nHkVX78vnHak6QjOFY+hRp6xPat/HzC0+nK847RcZqwp7QRELVAck+/yShEvBQUwIvN3Y7ttrqJloY9e+1e+765hup
# DATA Fbu4W5n+W3EFu0pfgqeefwycXY1sfXuzbDbjHATBIyqk69vbje1bt3drF5dXlu/2bm/c3Fp/b/3djcb2+tbGjcad2zdqnKoGheEH
# DATA zfvt6kXAduilzi5MzZeqM43dW+9sbKFBAgdBkvfm1u7G7a31G42/fW+3sbNx7fbGLhbhO24FizaO2w8LF0FYd+u/29u9fWdnt7F9
# DATA +9aPflxbudu7uX77J1fXtxo3Nt5av/bjxo3NrXcaG1vrV29sXK8hniwaY2i14KLqS2GxFUJ9PGuJ4TrD8LUioOHhDWpBlirUr0uv
# DATA vHLxlWCJ/p14p2E2RJrPf0kUpihY1QUv6Xt3UUwD0nty+kWV3TyjYIlwTxMTCIurU6RBRVFwIKoug5DwuSKcL1W/nwDP+eL5r1kY
# DATA 5DePRJ8SEfy4v5YZr2Cs8FVX1DibhAZxXXiaGwCuxl7dkc/BvB03baOZ+kBD0E0zVpvu7amv6ghYh9/lsnxxXW2wQa1g2c8G7fYw
# DATA U3ec++3hsKOu8GlqVB+EFImaDrHO9sF7uHNAwQOIUaH9YoWHJvttcBImpQcKKaDyrfmzBo6t4cxtUTs3wVKmBVKqAE5k9U3q3ni4
# DATA 36hB0z9eCssGJ9dnyGTVuaQoR/GcJ0Tyv3n2O+Ss8Ah4LbDiT0HzoLaCEkCg0rKUfv4rh1U7xzEuAvUBn/L8ZeE88Ih32iMwk2eR
# DATA yciIlpgSeTNJheG5nKDQ+CXKNX+CzoH04B0qX/KA4B/1m239IGbCPlIbXskX6oCDj1R1cFrBhD0xSxKfd3bdyO/bPDPPR8Hnqi+/
# DATA onODOxEMi05gfwFYFJdOFIFyVoKLWg8UXB1A1tUFFR8LLvGaqGtagViI84299Pr67vrV9Z0NOI3SerEi39qGl8I77VNU0ZWSQNno
# DATA tactqLzi8ip60Kq1AjL9M64csG5khk9IAAEZDR4aWZoWVEmWinV+ljgdN7IV90P+1NdlffHAW6TFIIGXwPojT3G2KTzRvlW4It4u
# DATA wMdcBT2BYJu2vRtuk8uIKtfJcEJAGed5LpBdyRiexaAM1rR2fltbanjW9oWxkEJJSdNovYdRFazy8+/ZYqVDaJ2BERWnN3fH5A4J
# DATA DYTdDkL8qNnHP2VpKMgKnmCHpffUs3X6SA6moqe1xM9IazmJNQYGTFDFFfxpQ7+ttFjp0hUb7n/SH/fQYlsD9ZucKqz+YSoAqcoa
# DATA jnqOg0k3t9epAriIvtXt7ze7m9v3L8lDr9dqcJqG1ecyYyzd68fSpXDimcIBjpyDdlnJCIkHikWcDiEvW4+MFxgoUhn3lNBdWJSK
# DATA yBQAflxwpPH+Qf0wFrd5F9eEioR8ZZDZxfHDCpnkh6QYU/eEz1FH/jR6POALOgWuiBz1GFnsJ3i9szlEQvqJJ5ZWzToQnG0vMxI7
# DATA JHgGXvyEhg6qqfgNyK95p0MOd7POAemWzWm52y/MaN3OqnJUQE/bE7gLWgdXJXn2Ozp5H2PXf4Ev/sRj/YxX9U+4Enh/uQY3DD2u
# DATA rY3d927dfseTl2JTLCk5+jxe/p2hA2WBixfBP5YExwMSoRv2iecJ9iwUZ3hcBS0ZmSW0j0DUVTH4ggT03I/QB7a6EHgGnU0c7q21
# DATA ghFRO/RcxdLE+kI+wGv/2wTv4XQ9faKNtbZ7p6Oy0bcolKQ+wDvv0+SdjR/X3l2/cWdD9CTqgeeNgzcBnePavhSQvhLi5DGHLlwM
# DATA og5FqoYpw4j2/Eu0qX2KwtZXpJX4EC/q1uWKdbOkzYGL15/SOS4l6M4qoyF257iGufcV09OpE+xdU9Wf/ydf+1BbSlNrrRc+9Qag
# DATA vv65vniL17zqmW0nlbgJYz9dmOr77Hho8+XbdV+3brIg5MI0foYs7p9ERxTwMeLHMKavaOhqUL+O3GrNtgVLWSM7bq6+cskeTatz
# DATA BBGLNfECqHCRovGktczAaAlLh/tx0x5ssoPjce8ebDIUo7vNk/1WsyoWPcy3YMUWFEvJfurr06lHFYpDLmB9zrj4/XH7If2lbTUU
# DATA bdqAgagj1Xjn8uW93x+FnrtsNetSQhJieQOSW1FnC47LMBIw/+IZPQALNXygfsIJNjCWxJ2319XM7dy5uWO4LmgZB45Re44oENKg
# DATA Uc1F0xns5lwKECQaYxNH6wkS+mPao0RQaiPow5pMsTDcJXscEPFAfsIO+RQvpEmSXqAeXkCnfq+Xsib3EXGgQUtj5r1Ep0gPbNsp
# DATA RcDNXiZ0AhdBSt8vhv0HKAoGfbedFoqkNkFnZ1vqzjWVqHVolg/Rv7WYJAVvdYrgotd/kG8oETMAivHQ7ahEk7tywqS+smQYPC5Y
# DATA bfz853CCfKy41hcWu8XEizWcwaWYHQKtwDFSlBdM1uppwCyAwMXOER3Lv/i9ZAmNegmK/mlUmKdesUaH04gCtoxNuAIDW6nz3niE
# DATA VyjWugJeFuwJPGr7D8WdO9NPWLZxCmppRZMsqp2Iam2pg/qBXUxFAYYeHmJk7TqVoPMBqLT8HX2nd68HEfka2pW/SL0AIh73azWf
# DATA xCzyQlW7LIa7AvBIVoDOcl9pgpMmJx3tr3Aei/HpwZFxHD58gndDayj5w99CSBN4xR2geUjd5ZbzIZUE8GXIDzEsdIhhdpB7AyID
# DATA xsxgRXuyvIgil9aLxXiV1nA9Cima+1r0SzwKRFEAPdizw0J42oDODjuqZ0N00+Wq6xThCa0i2xd3DRMgx13iMXC3nJXQ3+RR5ZRv
# DATA LZbY6xySSGBNxDxf+rMBOo49zhSSkiEOU8/gJYQa2aPEIjR6Ko9jaLfSusNd5QOiIyAOVAXd7lOOQF+GcIeNsbpIAuUhf+DR7nwb
# DATA 6v/lA5VZ8n9TnOuPSihWV+Xn/2i4GKkqFTPHu7KSztR1FETTgI8jD9QckkRn94o1cE5B1wTC3B4PSjdQzGbpzf2s34WcadYE8Ze6
# DATA 3iV4sDDXIaEk8n73PmYDyhrDdrc56txvN0Z9OxYKBAGnLJpUw3AqR6Qva2llijz/SxaIjb8fCfGPwcKKM4uKDLDe42X82R/h3KFb
# DATA yyOc78eWGVEGK5sGmVV4HM7uMB5dv1Z1q9s63vE/BHaa32FXTHfnaoEpoNcej4ZNAIsgShCNhJJrNV4MIAXB/BvbDCAGHvUgjJdy
# DATA JXWbp+1hlkC21qR5OAKs8n4Pk8SiW+gVBmShQHNCVNENaUtNzMHG8Dc5MeW7ymnzpGsfpeYFPafQj3Lud7nv1et6SMQGPWcp0Xp1
# DATA fyPkLnHE1TSqX+XW3H1pLYS5BlqUhbpEXKEZtQcegrz6GO6hOuqFaCv+dNmN0cZxmfsobLizVBCS0mpyNjGaELE53NqZZnJwe4HO
# DATA qP7M8utcyfYRSrRPcXeCVKtd2UXnh9IGbJOfs6PIF6BmeKyNPGygeJzDb8nSRtf3T1HnRmpL5MVPHEWE6wljFitmF2VgItl5wT2S
# DATA pbL4FcU6PKnctJNzwbk58PkWO8Kxk8n3EkauJewlBhPq9Mro7Kqnl/G71H3+PgEl9bstjcyE5LTgn6mzfK6jlxQQ6lHt8N9Aofz8
# DATA I+lAObhbUoS9yBPSKntMm/3LM4qFZPIi4uZequcc7GmGc/KoqDWnFMiaIBuaxlyvCIMsoOUR9I+4eHH+2XCOnfy5EFWDxUtFJvJ6
# DATA YJrWTvO57IckJ3hsi01GSego10JJqzpHBKKQsRa30d8EoSocMS9fWTrDUSN3yrSXsqBN673ltuwPQspHpRn7ZfzaKyXwpkIt0Rt/
# DATA vs5zCQ4HOcfN111L3XPUbmCOJXU2IFZ3uyAxGVawZtfgCbAJSauPZe1A9Q/XIdvadIYn2CELc6WkAYAJot6Z4KRAsRyd1O/UiP+A
# DATA pg8yGj0SN9UkFJ8eh9ooSfrpEq/e3HNcAjCyk6y0Qi4QpJ97E7B3h/k2Sjru6zjxmDI4U7K1wy5HlSnbZvjWNVg6TAGREtqDn7QJ
# DATA TJugsscntk7InklkrVbXXGO8FJzFOufvMfv8AIhhU83csRI1TT12J4edkyb6UOcLWFb3uLh3Q5RK2JI4nX5fYNYBv7DZS8asnJHj
# DATA Fpmu6yUgDN3uM+Xn8ZfbDYeizUjP7MHlB0gB2bmBSvyPuXu95MjIcd3zXStYyNohOsj/IvrfuQ2Rbtq0L1rwrVvXNxo7u+u7Gzoe
# DATA ZnNjB3csM1GEAIITljtjxoVK9jzmOmN5KDeTm+43NVrigPOJORTpwbFPaxuVb760wsI4XOakkwEgtRsERqq+LG5g5O/1hcTjGxyr
# DATA BBPp2WO4VwL8ooPvbDtIOHWk1o8OvoYz8NfJcv/VV181N2I9y3YQ+O02IUUwOnD7fqc/zpLNm+tvbZSScUbJD8Af8EHbSgndG7Hu
# DATA T22WASBeWjUSml3ys3F/1Ex+qkgCDnZcyAcY+z1sq6kdtzHCvIPIRJChq8W3WAzLGA9MSDnHHhILKHk7D90J6+4elfuZW9LWDrqT
# DATA iTfp+W+AcpDiV2oxuWd5C4TlSsGdTfvQdpu9BoFHgl65wdJ8gYZWolmGuP6D4w6merdcORlXhBlCqwYkLYoD/mGpKBtUJb6w1Qp0
# DATA ezD5JMSDSke4qm0IVGCxmgcdwGLDNX3QHLaMPgFsv/kqYVKrY7AJD2dauUDw+C26YNgKnz+TdZQixR6JkTdBKe2Junx+TJ4xnpYI
# DATA /USMevxXOT6FnsWXJ1vQrhyYuBganOLDlNAZmHD2PkBfvX/3+xH4N9t73nEuIdUi9Ovps8/Iig1KKCVRoyHp48hU8IUFLt4YQRIb
# DATA 2n2KQ8ac7nqp+GHu6Pm9O/6Yl/qFwhvVuxX6s3i2UqJgP/p6nkGL+yc5I32I5ov4UMnMFI5PaKthBuqSWzDW4Av2N3SPiHBS/O9e
# DATA cHb8aorzGhTJzGPPlOv0G5G+GZ8EndbIgM8eM4niuUraLYBHg7rHDwoI/OW4pVfUkQRxUHvL9WQxWSvuVdc8MQ0qDmYF9gS9mTq+
# DATA 37NXBFyzHyEJ83JzvJEeGeiNPiVtEg8cfD+mWSCvkN4eOMV/aI6hSOrntJkcL+RPWbH/lOLPSeMrlGXwnjN3+9hvuLA6AhveBy4Z
# DATA Rr6RTDp+UX6+bn9RClow1iSfTq1Cls8K5hewe8iczKmT8YfUO9e1s3fqt8LOklN2gAkKdm3uALFn/CG0q6bTDa99NPypqXEK6Zur
# DATA /6m/cf2ZM5NyjkHafQ2Wwq/KR8CkBbUWY/62+FvtdgTTIM/0DFiFwiFZfsgBlcZaOodfiuPdQLHa/4g6xA8pNtPjT4EB54mOJ/Q5
# DATA F+VPgP5iEg5n+8GTHRKvAI7Y3TzOS7J9syRGTmtKJqKCWkBD726jSe30ZLb83WK/05Wq57qXObMczOe/qfmhKdDer3/GwMI/BJEc
# DATA XyFL+hj/+9GzxyzjnHcuBwP0qtijhCbsm16rmZ6j415g82aKcCLZgf6oQkN+/FsTtkVxudTG3wRz8z/UkP6AwZWPnv/q+T8z85b5
# DATA kZCGqNbtLxTXoipgqQFcpz9Civ1Y1fQkFKM+1zEvjOdSy4kaYxf77W0OGLQAZFlQuLgq+meqCtXOa8s/vCSzcnBMdIPtkH8d2d3u
# DATA InraXfRaQcjUejgrv3VGnEMUUW32Uzz50BkRH1hjyNPbs4vFFOW81n3nXqLYO9KJq4u6btSjsASkjETN/arN+dglbYbO8l+tKF1f
# DATA xJZ5+ZLp7INAjxmwLlFlat2WoP/z2Om5M3zsWCm4HWXtDXDy3UbEyGJRW/9RPgNRDJymK4BxdK99mhX2FrkebqJuf1JpPxyBKng+
# DATA +7L48tnqd896oS/SUHs1cDeb27g+x8ERqo7jgXa6p6L3PiPTCLqhkvUPPMJImV+N+LoFndceysLyIZ07ToRjf04rig+kZm4kHROF
# DATA 3fiXbKBQ+qsYO1u0q5HrX2v2BZWmTwWJlHCm3VkVf2WS07E4KS2neODTiI3b/VwAz+ex/OCCakDdXBsvYrVEF3mKC4zuLK6SbfW1
# DATA HVyMZwwN1llJo82xPbXilO/uPmq0+O3uBLMDlAwFQS3GBzxvvhyPs29rXyj+wa6YgC9XabXbA/iDFVWWp6ARqOBkT0vC5TlaHLTD
# DATA L9WCh3muODn+Ab8WJ/kv0awGhzsiUyQQK6Xm7I/gjIPhoiZE/PnHcrTbGAmWMBhxgolLbbL5azIre2aD13HsBrQivrW4eBAU4wag
# DATA 2KLKF9oskXfaO+J2Hq20Dw/bqCBUnS+I5nAWu5pnRLriaWPK1/fAjz/JeFDO0z6suatv7haP8oaLwNSwtrp7NEB67sRZhyFIVCiI
# DATA QXLqhbEWItH7LkPn4h4igDOdVIR61+kbq02F1wKMmm0KpU1tAi5DusE0Hmxaq+EVJZd5n+PagSqSLygiBYjNRDtxpBqH3MRAPSyo
# DATA 4HDfCcNy6SvqSzVsK/rvgAAKxOutKGfIkIhSXoy/wcXYW65XhhqtCJ+UVzR+UVXK2MthtYVoSOrX6GhIYOHy988Y8rzVwcdqTQHw
# DATA H3C/lYzyEB3lmq0WPlECWfuwcy+NWief/XvuzoXN/gtF/SCY/hPGaqn1+ZyiQEVDldAOegobBbcIBqBBOQTT+gA9KH9l35k+thaG
# DATA 12GPJxAiufAvv0Bl0B8U0v1xpwvJMtCIYNl8do87GbMQwAkBE0If4erAxQkTAGgXD3g9HPS7ZOKGE1NkBau+IeQ8bfeAPgh8mG1Q
# DATA kDugp3oEiJtdCN5RFfYwuYGOHwNIYnUgVsIR2jD+MM6zxcVYwKMvfZkkE3CGWtelKl/eNChhCvr99Pvfl9hkTaL2KRPjuvb5obUd
# DATA 0CnLLGV3MawYb/L1WJ853YcqSzBXdj3sZEqfuXGzqBink8JSh5NYIL2LfbfgBtRbcnLY6TBUXjhX7tEbZQz5EzVlLcMzwin8P9kJ
# DATA odcud861yXGI3FFKbm7t7K5vXdto7P54ewOWFbiZ2iHIyAiLt0+A+gfH7da42x6mE19rSP8r7Pf73Rmkx1yYJGFnPoU/12pJXhWa
# DATA BxVzOmDNvJoP1o1CS+qXtQlpF1JbQvhF57DleQI9wjd47Gohx8TWPiID3meIU/dEiaVPOTzY8Z6afvgSii1uiwtJeiW0jYRaVyd4
# DATA lMxk2pn2cb4ZVfuva2uw66IV8oOqld0GZcoId/FouKuPbIeIjf7Mki/hC0dbBg/mVpXNFjy/igmeT+KYNGhm/pxj9GcI11NY9yz2
# DATA P4OR01XsoNuku5jT4lTWoGZUf2czdMwFyy9ie+glBMKJiy3T5+ixc2MRMEMriiK0zRvT7h9hbSLAFVeEwL/gWzEaB78UqQcsfwTM
# DATA d06K96j+zJ3GaoL8Jnb4T9xACvdyjLdcG8tUx08Bo6uJA0do3quRNryU2LrR2h5e5kn1V6zrl0aFWLMLWNmlInK35YOM8HYAph4Y
# DATA Hu0vd6HYHVWKZYPcgtvE6AnpxOg7c+ryt3zOF9tauvfunab3M83vGPV7eVLWf69Nymv6x0X14vIPm/t154n8vUJ+crqxOJshVI+p
# DATA MJ9hYMSj5HznwxNk/4/IMeKfAA9FXAEMfPonQYTEXs4CgCBshmWHTpxpT4lqsgLRO1r9X/X9RlGWIM9N1jgxDbrZXHRAJzhB6b/V
# DATA x6RZQ8WUUWVRFihw8KqKnkWifdUTGhV0i3ctlOI/S+5ZvWM8r6JbYSK+WDO1+KgJFyhdDYmCP4OgjlxLiAXEixfNmC++7bZJ6I+X
# DATA J7v0x6XJT9hB/67ENmO34JLrAYDrhDuhPjsSziphWX7AtB/1FQ/2ynkK31L8a9C8iWkNYJVNxz1IJPdId8COvoITResz0BEsZsip
# DATA qvNA3Z3/gMeDHB+4r1j/ajCpy2U7wCeEEspdYdN98JWx8ydlEYW0O/FBAGFmcD7ucyqRmMMgOBIakoRfnrcTApNgBKd+l/mQa3N6
# DATA 4uVGyvwFnHfAypZ75Ma12KHJETo5KxyoYJWkodTzPgl8pV1jg56RgwCgkpXYXiuuMjv3ZQSAdZ4J+ooCaNCpi4Wlz23N9hSzte2k
# DATA vrdIHTNcV8kMi2awzHXRrhSGX1p+60H0kc6wmm9IMPETIQYQ7AiuYkYAjosNJP4MnmWEPB3YRZLN/GT7h0mVM/iPnDfgMZ3DUxaA
# DATA /cUeQ3HDJJwgRISo1wHdJ51R3pZk80fDBRmavotfdEvME2uBdXhRFmJwjgSuBQRUnTtuNk46ZKkOojXDIA/qlGXpxwfG0k8/52dN
# DATA s8z7jzX3Iqi5XOpwUHWMWzpOlOuQPtuGnus/bifcCV3HTQlDXB6L0tHmEvNKxObIPyj2MZXamN7oFk6Rp33RvZ40e0oCbyWg9rBy
# DATA w7HTPjUCrouQsBz+FTdy2zU8JrnP6TF4LmRyoRr+pQQISNB+Hic2S9CmR+fBMP8Ody5r3AWwjIVu1xZrDiihzhxbq8VEyfX8MXrZ
# DATA EoYaeRpPYZnTZ412lb6fQAWhM54lmMSk9yDPtu1y57uZeUey42xbdwRfqeUc3ukAlIwO9owLAZc4X4M3m05inYjZmGnZHB0RfFb/
# DATA lgwcEcB8xXdwL01inE8cAAQTvg3VtxsQyNUg9iSBXAUOdgFmda7QexdpjP5xYMZ6Bj4c2tAbQtpz8VN4M/hReyRzU28oAJ+rMTGm
# DATA eRBJ4ZanMrMkWCll5O66AU8SWX3+oM0gmk6H0OGsRGI2fQAqHyHIDH0WSpAFOvBtdjgIMp2DdQaIROpG5UomLh8NBh0Z7tTtKctq
# DATA ux7X84SrkBDnCx393zVsNJ9mKGyUldtNpIduGyzF/Qc9yNDYaw6y4/4oNH7bmM/p/X53fCLHjXGnGp0OQMWU7nd6LTSXUaerdnpB
# DATA MPTTOlUTd2gstL1Q6DrxW/MpSIQvpItLXE/bqst+tAMulkOarHokamvk6I+JyzaiYfDeNdEPUqfhzcNozE4uWlxao4l+XU2535EY
# DATA riD9KlpHlmCS0i85BhtjSvopQVDiSzlsd9vNrM15qasLMx0vPXDZ15O15UDTqO/WPUW4w86BdghVe7h/v01pIxVhk+Keu+C7gU7P
# DATA PPPDiYlcw586eo3bLOb3SuLNKMJMx5bxh050mav7gs8uJIXlUjFZTAprSZkvfup5MZhotKUU7ODKmTGcfthmMISUPV1KZjDaMUX8
# DATA ZAJPowXXVcnBdh41jxCRlOuoDC1w52rqCbeCoQweTZTMSn1eDYGUubKgq4YaZq/jQi5ialpA6zPXdUHVVVRVlAv3g8fFN/DFG9Xm
# DATA SevS2vvN4cmlNfUQz4kjD5TJzI4gj2qQfKMvKllYq8FLf/3HAwIiLpjK3eS35rmd+q+QHh0fDCudvskjtUReXfpXSGt8bDQYQN14
# DATA c2pxSjdtBoooFTWfYGM+EgYSFxdDdzt0YVvwfGbOjMeZ9kHDP8qDYf/hqfezTJf6oe2gZrm3ha5uxsONnN4mATUaNLG5vWrAwQKj
# DATA UedzxIg74Fie7Q6mDNYddd1Aw7eL2DrNvyMYH0GFgKXYSEqsLhe9uZCRlqLgFf7rmsXsYpE+xDpWivY2WtJrCs4pJdE4vXT6NrE3
# DATA jX2lphFDhg74g+6glNmFJ5G3STMDBz3/BMx8SAOSlEzsNP/m48kCOshqhaKTY7phwdGGJ61br52po2HSd+d/p9uXo9qgf2iJ2+oA
# DATA I4kYsddqJEAZOU8o93QHeK1E0D3R82wUubonkXf2FMYhG/hIGN5jcAzj1/+wbOiVZ8nPWGVtUaoi8Ap3UIVhL1K50A5lU5jvB+iP
# DATA XcR1uy5tALOuTsHExD7UpVItmBhuPuj0emCPjpIUs3YzrQ5j5wN+jpMrZ5Ac57UXw2+QntXnGa1+M19crL3Gfiy8KpgbDw+fCdix
# DATA /SYXWrmQH9tru4fI06IcgTwMdV0hzPCgYqfXndknemZCH2js9hE/CbV42HI14rA+F8HktlqMUNH5KWn6lqH++VFWc1LOIfmyEb92
# DATA MiZaGs0WeIJ3IxnxOCug72prPGjpQyp8I+6Xy9KSLUWosVbIHaEiepzMiQOPex2J9bbou4dG6jNlIyFNiVCGRIh71BFPYOYtqU+Y
# DATA Z0wFVXdWNok01FnOElaVuz4JhdI54ivmItdYB5yJPRdden3B3ndxG9tr0B8eYaISQ18VuoW5oC7TSV3X3Ylc1OVlMXR797fIubYH
# DATA hXyWDFrZsSKgXond5OVSDszPmZhCOIxSIIWEwlTqoKNQRhwGQXmCLpWPlNxHSghXQCyEgyoFkk0orLntud4JGLP/ObaIslRe1CvN
# DATA kEcX2tNglkaF/w1wuqQG3+dVnr/OYwmDpIbNjlqRO9Tsu9QqYimz66uLJ2P7aEs2e8ja9s/kaFyNu7o+wu9oCtSHJXZOQuOSvCVK
# DATA 8dwNBMLYNgBrLyPfxqIRmPR0lYyhJqaSmmqNiRlHlr5x0wgslvlW64KBqdpVShdNSSV0Hjt41+eD983FlG9K2GRcaxpFLWAPeIIt
# DATA +BZQCVLPgeNc6AvUuQDLI+pnofGCut2C594TeDnMhNUH95wghvX5ryCSTZLJG4xZemOhMBmDDxNbHpqC51hSPRcmqW1Kx+Qu36af
# DATA JqIwAkwDgXpLpBwltSNzwThT59X+adJuDrsdlLGYF2d0RrebLau6PqI9DtQdvjliBMeOqrxz0lZfnYB0nB03W/0HLt5sJYRZcP1G
# DATA l/4zvUaXZviM6j7/T+kyOgfN6QGw06hZBM9ndCnmMerCktrQJOxC6u6GigQIu3VVI7C7LrxBzE2rGkA3mGuFvZHYJ7nfU3ewrp/h
# DATA IUYajrZAPnT7Y+rL7xEtf1h/QgwYUbzhoPYglchpxcp1IHEpmilDPAoH5P6H9hO0gqq/cnK1/ZqenY8q9PheGOmFGXrE0O0KDJHE
# DATA UJbv4hSABzkQXafY4CmcISGSkF3UfmwKmwpitX6XwBF8vMMhKAwwH0DM1QzQUFw3pCiqE5HOVxYmTj58yhQgCDcC8Ik7AF/2q0bh
# DATA IRzxLuoJgRx6agkPT8S6sJsbXNhULNGb31i0jNdcwey0PKW0BVtBNcVkZdNXP/FzDKNJe0Yt4s4TjKYXyh8yJXeI51EuTnxTWNoV
# DATA BP+ivHHq/PtMPf2TxM99RTKYB6SJjwxSrpP0w/cY7rXaD0taEmyjabCpEapnwubEsuG8nlxehBw4+J8pjuEGNgpdvp8+/4XkgP0D
# DATA jVU9cNPXogsOGG8iKDmSO6Pq9rKUSDqKahKmzOAMdTAJUPKELCrL/UvLy5PcgXuoHapPohJFFG9vSmxQ71JC3hS1wAG/GPEjjubU
# DATA KEl6qvxUE3bECy651m+ommynCSHT2a4ph+x6whVOprlS2JJoQ84lA0hH55KVCRTx05W4W3NSZczkeeLAFTNroBelZQmoGqZgGSmq
# DATA MUc+sJfq+Dn+i0jBiRbL8aY0svyGZsnqdgbSfJYAr0kgvdep3EoJjbw5BGUj5kwlNHes1KoLZr+SbGACMRAW1GcZgr6jJ1i3xZDW
# DATA AwDswEZYokCP7lElDrMeyluzvNvtvRCXQxlB+xu5cfm3LV9WFcT/YlAihPqf3z9fy1LfmH9S3OvfCjHm9F8b+I+iNidtupP4yt5h
# DATA 8WrdfWcxAlCKyT28N/JAhCyxxYYpQI0GwRi4wyKVVquT4e23YGHbW7pNzVAY016kXSBmG81e2wvi5gUrpitiQ2B5crYJQav8PTfQ
# DATA c1keNE+iRlm5wmWCI/5fwgzhCHHqeaFzqBjPP3rkO5DaXhiUOhU/Mont8+TlX2mtC3a1AXupwD/4BOgP7xFotassnN98UuEqQMNn
# DATA EJyiGkEu6agDdQe4B+lSmuPLb2W9T3DmCFbpaW6Sr1yJqVw2x1wOAio8qGszNz9guXTOeaHDoEFnpg9tVfIbhq1VkMlYSgbWFPqZ
# DATA xpH7OipLemwBUVPgStFX9E1PVu5MMULzOmCzTxJLBTh7iiOqFMLViEPyzpfLmcebA5chW1G/ttFx4zolUQSFg7WrhpQTpq4rgXxu
# DATA QxvDpfMD3M+/tAJnOAGEpw1F3aTTY2qh8c7GjyPb4P+JN/yEVM2Q25aaVNdIux5HM3CGUEEnTYYFsMUgi2sHciBTJvknEw+tClvx
# DATA YAI8N2XGvHVcAaqJdrozl0FyS6a/99LNlhLC3Iqd+3dVbRmqo45S/2jYtJAC9uqTKdmvq+4ZDzf7znZ/SGE3A/WHAWBC9/ftW7cR
# DATA InpV/S91/VyxAj4JVRd6mdpnJ9pZKn4ksiOr4yJVcsENCGEkTbUnYhSgxBY3v9b5yaDs5zoFLX8TRkfJ9zfxkNjDeKm5IA1zwdOZ
# DATA GaXepYPEYe3DGIO6innD8LUYvA/h51nhYL6ZLM6euKrL/IpxkC/0x3D9MCb5wGxT4dgKMXZK8F4BucHjQFwuTHEALb4o8JbHiyMg
# DATA hmHvYl9MQzUM3JVeFKkyioP2LeFU/mf5/74o7KjO1OIKuGHObdLHfg4eBtpM+JtnvysljLEWVXs68E7fAnQg+y7jRnedtvLw98yV
# DATA q689K3P2VwFrnxOvz3IB167rZae8eWx9ad1V1fea3yHSn8sFp0P6uWUXcihCpHWC3jMtVl9gz83ELT3HLo+f8YTmPZWgjXvKFJHU
# DATA 0TcM+yMl75B7otpLValiT/2guGT1B1lWLQEM7xH8gj+Y5Ne9Z8kcyArhzg0yCX+aL5cUY2qaELY6sieiGJgzA5T30MRdsaJgailw
# DATA OPCFqYG6wIwpp2Q92qANzBSpHbRWeiHwRkam9kPcuCPipfFO188xQDHTwcLJgMj7gte5ZJwxdH/kEJYVZ4FHVRzTT6GVlr8859yf
# DATA LS6qR6VkcVHXMAkzp5ec7egAZamvC6qvgy668x+rk4IkC/irAfTmSqSZEUalLJiA+7CzCvJEjJxZ9oDyihPIXlYhiLLj9sPCxdXi
# DATA gs59gOJVDJbP+0KR+Patnd23bm/sNLbXd3beu3X7Oir4qSEvSMIqfGdn4zbGSliHon55/ar7yq/FwxA8tI7T6tKS/KieSTcmf2OY
# DATA dGu/+sraxdWl/NrfvH1ra7exsXW9cf3WzfVNiNJPj0ejQabqBlIzK5Jur29t3DDF9Bu/yp07Vxvbd67e2LxmCjuC1HjYzQrOqpqV
# DATA h621d7kKl6m339u8rnq2fvXGhurdxpvrd27A0igpY9wOB3JzY/f25jUz183WSQd9SeQFrFh0ZVfXikFt721cffvWrXeYIBpvb6xf
# DATA x2qjdMEKebVRIUCRiVlLyu4WJYILheRBczRqD3sYZ/d3MPHDdgVRqNuw84sYHFerLH4/deU2SQ/Jn5ewF2B0rNz02Ch3Dz4Z75vy
# DATA nL+vUU0CBiOVHXabR1kNq5ySvxbrv1BDHFVVQ8iuLuArmznAJ8wMEOgBeAFNMAZ27rfFAY9+yKWYX7lxjpj/SFBe/ZRI8Pvl9O7w
# DATA bg/gXV8+l1sf4pJqvcYV8OLhbFCs+zQnLCeRspHXAY8d/iBTIktujulm0DwFw7UaHFgbKvA3GK+y9qW1yv6lNTamybQI7BMFFDmO
# DATA 0pHkb1w3nrT3ii5KDr/bu8cCAztiNa+1h6Pt9gnsnJ8+GG2P9xXffocR6VVPrNfwU72BXz5gLnm9vgvrTs6ujm2hYF6Ukt3TAf0Z
# DATA rIo9sZ+CZo/9HBGjWFIsPsIEAqT5MwByjwAxBpBhP0SH4o+ePUWdNKlnEanpaTyvKVPm4ctasKmdEb1N7vZMh2rpGQO3Kpp+mWn4
# DATA QbMzIsQSZKAFCVHrnLT741FtddmEFFuRAhjrrtjBTUQfoRBCtXqtZldJkmkUWCQ8+Vh/BHVdxyeC8eDuHKsYNEm6JvbpUevaOYQj
# DATA uj0lYReG1quS2RIY1Q6OVUuVgVp/reQytQSAEkB0y8lrThnPVP9aLVm5uLL86mp0g/4BnQrAi+AR3P3cRDfRlX6UvL27u71TNjA6
# DATA OuCtxynv7d4YIzDrstrNQ2aZkoS3DP+7uvHW5lZybeP27uabm9fWdzfwaWXxDfxXnaXBu9TKra2q23GYFzQTDPj34XCCwfCV1dKW
# DATA iz734UDuB16W8CzrVrY3bjZg2I1RXx2rt/HvAnRCHb3FYkWShZuJwoMDvqQk3w1GuWjwy8JBE61ocEOwprPo1FBh+B08TJL3qb53
# DATA N25vvvnjxo9eWf6hOp7VlK3faFx7W0kMzpfqHO+cjE+sVLzw7e6NHXanhz/vrzRW2VO82VI0B0QMG69y0ldTDL5vBThDeS+SyekY
# DATA TClBodd0FRaWSoCs1hkdJxlo10YyKaq3PTCxqxtCIV1ZfbWyrP5vJdUnmWEEajyFVQhLf1iorJR0c2W/K5Aot5kpXvogkhYcOiAT
# DATA 9GDYHDSoNwVVmtRy7WFD+ERNC1dQn2Jc42GeoK9I0qcYKg7MatBuD5FY9tUtfajWsj884YNIUw0wMCG/au61yoDcE8biB+Af56Bd
# DATA gX0RokH+SdKT2MCVasHLtOERvv7DtJhza6GuZ21gp93CYfrWxq5iYbCPllYqKyAQvK2mppqcyQxN4Nk1vZTqZt0FdwGQHNT/h/xt
# DATA eBwXi3mzt7q8DGysg7ofal6xz/uFV1ZWRU9X3FupA52tLS/nz5DF7u2T89YOH5v2EboJDkP+GSpXIEPEQF5Zt90eFCp8+6FlcNmK
# DATA nciY1+ADxJj+c2KhX35JSTGff3JFlGoUuvOJ5FnGNS1F2TImTv8PSioDtlIU/sqkahRrPv7iPHgFcwfJOuBboI4t22Q/8yKIMox6
# DATA m6Z49kodOuwaL++HKSUgADigZBl377K6VOGxKV8UJ8B6rtztWUX3qtV6bjlH3D1M05R2ZnJ2tmBVMe51HlaX7jeHS2rfLWkl9tJw
# DATA 3FvCiajA5oYqE1S5NuCu3T/od68snNHgJnJJV7sep8IQ9BWykmTdhn3ER1obdb1TPfplAwT7nK8Hw8599dr9VvqaJcimK6v870Uq
# DATA AqLSatLvXVmwhoC3qyzpHx5eYRuIOiaXxtlwSTGlYZsmZel4dNKl983xqI9ec+aTNmyHBgJNri2vJUvqPxXrg1ZLXd6aLbUUPypf
# DATA o5O5DJJo+RZdSBVNZr3OoZKquw+ap1nw1W0ATBm2h+Xtvpr+U5CsOwcj9uQrPzhu98oHw36W8ROnmm6fFCHJ3/1DsvQQJgC8ZZaE
# DATA KPDo63YgWE8dEY39fuuUpKPlK/r90XBw0CBxhQ6V5OLycua9B7Y37T1wB/xLXfWnkSB2EUmQKphM3GGoUdy9Wym88dKDdrdbRlyH
# DATA paIajTrZeqfg53wl+AQGC6cqeSUk3x8PO/ifpaSmFgrLq/+n9guzg8NhOzsuxNx5Str6K/ZMfeql+vCtpWr4y2mJtk9N2zdQWCee
# DATA gaV9TVOONdR7jPxItbCCLaBWq9ceNVABQQFx3JJ5CocmP0SmgZ6aijl0DyEIp5va76j6tbWL8rTT2++P1dLSi8vwxgYrsusUxV/B
# DATA qdu+YMTvwoDh+ZjN+yxof0BO7s++SFwBFK/FaXFhlgrc7VfNvebonJfWigQdo7wIeARRhNsnOpgiIhmbsLhPMW6VAUS/ke6armn9
# DATA 4R6eALEIOdZX+EsaWcwwHAlC6agJiqW7mJdCBSWoXybr25slZ30Ao5rdSR4lPxo2T81V+kuOoJOcKnCaWz4hnUOfliNgNznQ7r/F
# DATA QCeIN9xS9+X16zfVdclNSPcpyw8fAx423Ok/suOpPqWVNlEMMbR37SIWBJgGuLh5Xmf5eqVu/+iI/NHO0pY61tAtJAUNTZnT6Kb9
# DATA gXiAnKWKUZeBR0Ohi8uoHYFHWFQ9eiVlBghxt30B/EEAKXg97ikmmJWzUR/StcDH3DwE4NNfgYJSR+ifuYZv7WXMdtmW7VAzCaoZ
# DATA dzsnnRHV0+tzf8/SrH8IPVtZXrv8yquXVIfUsdsyDyaTyXx+Us3BQJKX0dCZS0vSGknaR66sZkklVXKxXopJyLBcWW3v0NyzqqKl
# DATA qSKnj3/GoIy1PbZBl+nOROcenHTGNE2+rVl1Sa3ykhrFEj/IqbnVBgNj1uj3arbptLWPs6nE2BbajhBcibEYlCDRHR2fphPHqkom
# DATA 8dkfTaLdoNeIjaj6MVIUBj5I6bWb18s7b2/cwPxYB5D9qnyY7aDopY5+OJS7cGjC1K0sUR3oeY5JFtWcQA9WltFqweIEEnVGBmEl
# DATA +aCv0yU6WIajxkBd9fst2guZbR4OeUpgtAUV5EC9o5wye6lmIGk9lmIpQlraPlJduVxZS1+YyOgKeXyCwlctVRe4k32qTSxgao53
# DATA fwLDvLN7DdbR0Jf00IhUlg/ElObmWcDBUaOTgex3mpTvJN///pljZpok5Zbz8PrVSbCYF2et5eryxA7bUDSZM9e0Y3jjVH9YbnYH
# DATA nR6wx3n3Wt5kQDvqvLG+x6sBdLNcztRWwVxv+Ius+wAyT1ppeqr470n7RK1zeYAiOr1rq22EmwrLgNRL/YLfXtf4HxR8/eKKwpHJ
# DATA v/rqq/QKOBL8tZw7oPylNU4xZSX3Y33ZHP2B/KRfc2Ut3zmLbalSakodtoSMzEqMFDIs/NcJUgpF52p+Il8S+fKtgvlf4k1e9Nv+
# DATA i8BDI/JpTcQA8CYJXoMzzOXlUqKk7EmuLxILYNNzdtkmjJjcRbnsRHVCVgpHZnpKYm4adWHJ9mzfnMDVrR7fv+EahdRLkkaNYODV
# DATA t3sieyDt5TrdRXEEI8fWFO5sfy+cGqS5Q4p+cd7H9l1MTAhWGCSGlei2jR/qL3Y4T9/9BOeo9n1o12Y57bAN8Usv85FtxgN9X0IG
# DATA 0Gt2+ex+uVgZHavLw7D2OvtuQazgqDCs9O+9sVxdKRYrBxgOVSh6JdSrPP7lcJlXZnGZldWIMLDqCgN8QgjEGkQ9eagQOimbYZCG
# DATA W2uBzI2MhAs+RYLhHb+as1fobc6uoLfVVXOauYf+W7eub1y98xaM6WTcHXVAfTM6GNSWQQhgoksvL1cvg0IAbu5Vur3Ln0vj1mCa
# DATA FBAXWoPtcQ16SWENYFyvLikaWcKuL+lX1WFfpxAvw3xWl+C/5hmpWKtLbtIZr3GJPjuzKsIwNa8aP3RN+4ufUZS/cdVP7HA3+ROW
# DATA mXHTq9L0xFKBj4ZNvGrr1YssOClz94ywyD7l1gaOIF04hXA3zn2FUaIseCOyCgcOrBcXOVn0rTlir9bqmIs4j7E0hTiU3CBkEdXq
# DATA paUk+EbdNTPno/7RUjYewOqg+2esyyHTBqvxEsyDCF6xbjDHy/n6oD9sa7/i2OeIqeyUqselGlQkwRrG6KjuxvNENE94DJBNwXpf
# DATA DC8tQrd18TUNRoZm8/wlGXUz2Kt5Z7tlIsljWvi2ulJZvWz4Vow4F87HZcgAAfvbZjOkgYenldYS24OxEDKc6ZztBafmvLXO3gHn
# DATA rPDBgwdSYcwUAX302KfFsuwFfFH+OPkmIqiMmmx2DFUQRBWSRwRvB6Q0L8wKfvlV+2FUGBUTiaGiSWQpib1bqvZ29StGFYMuqK2D
# DATA OcoqYqYpe8Y/PKW5eHgadpdis6qJ6HNTzAhi9RRxPHQmqDlVZOxlY8uld4YgXfvhJ1O9Js918bIDys/CBMnVhMwT7hsaeyA+T9tE
# DATA OcmCiQ4hUXAF/rNWKBYnxbCHPtCNcNap95wYjJUzXtvdquZq+UkjL45RNdIJOzr7IhXZJJ29V8rR5BdjTtB2kB4QheIfTrCIYMdg
# DATA OrwSWM76D3xTEttr+t0WcPcHXtAAZxZxBNYCVle0/VFBvFY1OCFaqFqwUxqAPzTsir99b7fhOCynmN/r+ib9hV66tp8t/C3uswCr
# DATA bJr08qGrcpTKR34FvsilmDMxPDRBDeqXE4PgRsqEsUVq2BQl8VIN5o9cI9unxdy7/X/XOUGfPvszRxFhom0MpoU025Ggoee/JqAC
# DATA qJkiGxVpENYP+dseqE2g6KTdKuwVTsgREMzPEALBP3co6Y95cF1dGjs93A3W09vvpRyYjdmgOEbwJjbHSVmLQjEN6gUSTkP3iP4w
# DATA pMO/LaoBPyN1p4coNMlcBDsYrS79rMK0xv2BxG/X7uzsNm7fuoUrgip0ffKq3lpZpJYo7lZVjrDDqO0yyBzySkBmLfQw7A8bN83I
# DATA 2EJFbyHOU4/TLK95xpltCvwBVf+95JZkqxwdD9ttg5FYhjRGmAIKD2Bu8aR5muy3wTWg3aokGwinInFMXCGWBAy2QXO/0+2MTumS
# DATA WBIXZbQ3kqCmWAXqwYDPIqjDqM+copMJtKKBSqA1+rpRoVH8BJlqaQz6GGE0U4PFgSZh6LASeDSaqS8G+1KXtFZTKoBoG7A2Iu2Z
# DATA pxfrgscL51UkrsoP07ObgnwwTD/x1GJz1ke5ucQGSVWveGLgsN1tMhwaFTc7oCLvGqM+bSiJcLdxF+BQ9z/sZI25vg0TJ+vgAe4V
# DATA rC0Ym+VBhZIjgbSyii9fKK2bWxu4lnJdzuMVTP4RX4E9Wah6uBbhLsZfmm4tKiJGH/CBGHtH8IVPyBj9BSpxQ8Yeybupruu0fW+y
# DATA Hg8kg6uKWAFnCX5faw7WWy3+6/qwP8BCw859JVaDibbunMTeuW8iCNGRI6zLR0FvDuyDRsIIq8kZOug2B0UlC6lLPRKfndrr2ro6
# DATA 8Dnsu4kYHQUviB+cJQNGo6NV1VnjxhPCIkBv6MDhfsE/5rDBX9ZRE4n5lBEzn5SKarr65H0lWRiFyWR+TmA3gVOZ30b53G3ozJwz
# DATA 505RqMXJ8wtGnT9C+cRUUNWA4uBXGd9lcJPEetOca3IVr9Kg7OUbcxpR5UDUmKXyiRYMlTaIgWf9Li1MJDgQkq6a7K8xJAs/+ev8
# DATA DiECDC7vXVxwU41fzzRUcBcXKBqrMBMj3PdPYq1k4ZxQGsX58aNsNIx8ENKZ46VMxRZEhkaBIU8eiNh5/nPGo2c+Sg9hBr56/muH
# DATA taK3Zy2x1QyFNH7mAHnbF8nKcfuhk8H3bCquywztCHSEn8OfRTunpSC7HOqcTSXNpHNylQYxf4hXRqIcnXWuzOQtuy3TmyxSGFYO
# DATA byKXBCuNqnWzyykN5nTUbi2lrh+a9DKEaVDLBEEMUqAE150anzvYShXlCjrGncYgzkSuL5zQIfcC9i/urgmoxqI2srlyzB6mH4/5
# DATA lalXH7nXNM68Oh3kQUt65I2Mqx3AP1r5ewnl5esmhaUfTlJY+sNSmbj5VU3FuiIhUFOHVfXETZip6lI8+KALzsFbkod1tznc7B32
# DATA AYYV0R/5t3BeSGuIyo+2krraoybYhwrgcVpKIG4KshdYwTT9EeJ2q440R6obXEL1rqH3uK6FQEXVrCwDbUKVFXDHcdRd8hAQ2wHn
# DATA dXEVCR+bUY8uJYvyPHaAwhj5Ssc9SaRxjLpotzK8DWbNw3aC3nKWkp6/qOT2HMKQoCMLZqLA4toYqH2TN0E4oHA+paCfTRAtNIr1
# DATA mYp1Sa/Ro94YUmF/Ow1L5XmNZ0rgh1QjOW1zyCcWYhw5AiIdQTsD1JXgld4s10nnaMicjqUGVBUfjOy08dxSgXIHmcw5sDoNXM7a
# DATA qiaQiyVCbuAXK8vqf9zHl19++SpMTEIBAKRq6PaPEDQeiYUzmgAKJiKd9tTdHQgHfdcB6PI+dFp1o11RlS2EObptLiSb5AAPg1qy
# DATA vKCjvmQPQgajAvzV3/9pTYZHhp7h+5RXu6P2aM3fxBgExtPi3dbb6AcDVw7/NfE46MuFWrLiBRlRZl66AGMVBJZKV7wQI2WMCXOs
# DATA iYbtGn6thLLmvhLbxqM2SWZppZISVuxwlOUdF3d6uFF74a5GMFmNzYHdSIvRM4160clIJhTXdP2YkQz1hKlHTNzFKb3SRNyLMRyo
# DATA J+wN10+xscmy1STzO0PF6oKCNJPXA4vNBVxNb6QEfZjdbrTMsQ3MjMSJn/Y7PUwysEi6gtg0Wh/6ygqm9Dn6KjNEUAiKAyhSa9ky
# DATA Ts6U8eJFEYOtKYzH38ma6TBaI4pKtL7LibiXkTBEexJO7kGfcIcu919dXoZgEUDSyTgcBAG9G/17VrLQmZdY4hNqT1qDylu+CjX3
# DATA dfoBx+3xeNTpVlqd7F5jnEEKN17NyiGoS19zKPRCcmkt7/g1M72pdsfhYecAYp4Ax/ceMlklZp0gW/I3tM33o6o4OZX5OMD9Sr0K
# DATA R0PfBElWZxKkRJCrL0/U/gdfTLfy7wGEcnecYWEIEYYNxCjZiobHZNqSvW8hZcsBQmarWNgxdLnkrCyeBenD/RSZe388Gowjucjs
# DATA Lw6OFQEUcP2tPaHR4VdWVkhziODzITGSnpruLnmkZ4Ksden4ftvvQnijpRxttgoQJK0/KyWXXnnl4qX8qFvgN1jLrJDjyEo+UDM2
# DATA Go57sBqtnEhimtEKA+FDQ/FyZlrKlPgqpyzXd6jo4zgCGd7PKofZae+gIOXUJPb6BdeqiCeYtiYOTmNSj6UuEbJxeK/6m9wTSFGA
# DATA bmGD1FKzoLsDQm7TRoH7YQVdFdmNgf0HyVgtzoTbSI9QOViKWhD0br/d3N7A5+3h0H/O0k/nBMNywALTBC1qZReeFFbAE1eK3+t0
# DATA u1bxSqvZptgaYFvWc7z6CgAJRIWqIlof7kT2B2H+U+RJ6QUNrxRcIX0YddiXQILjocdlpEv8csEDY9NDLdgJf+y2Kxiibr1udZpH
# DATA vb7a6gewLFZh1RRtrpVLFy+v+YkaStSVTImPbXULPHATTzmV+C1qPxYpB1AoBQv4xDjaEa8EX7tr/XG3xbDRSsRCURmYBcp49hgQ
# DATA MpD5tPPGvgXSNPr5GVFuoyZjADXX7MRlnJXxWrOHlw516HRPcWNZZ88Vk1fNbBFJCtEC5TkmVYCawtuSJnTAie22FbfZpge8U8RN
# DATA AHxRrFEKQLdqtGsTKxL3AeD82LRBLpHYzKAPVBM/23Ioy34VrCGxmqzXHGTHfXtTFEBpoPo/7tnbWf0sEWPCQrUcHmWHro48VUYU
# DATA /eZ7yXrCoXJCFifNe+q+SAcmxOiBabVLohtCVXTaREU/GytxCbKGtDsDsBZzfQf94zYiMMrYKsltNXfgYZzca7cHmZtRz6w8JcxQ
# DATA bLg/BjTMiiRM1+grag4KNnPldxAnzAMV5WQd8jegezgJYUrcVSNuN+gE4IeA9iF/epvLdMoBktKdYWZRtJK4efrFzRbBDwU9S+y8
# DATA zGzxham2NdC3x70eykCR1EKU1u5TUM/Rnwgegal1Ytq8rxy1OOdDs1HRMZ0Q6fw+zgsGpUFMSQ7KSmarMGp761o1Dj8DDCN8yGK0
# DATA 8WJ4yVZWM9LRi9lMoXrP1HO+xKPeHD+api+11O2RO4G+BVi+F5iiCZIedXq5O9WVMwBQFRMGsS5SUTlOOT1kdWTddV+jPT3VOG80
# DATA 2zD5rJDNsSJTffW8XI7xWf0L4nt/Msf0GT1OMIl2Gmk1TS0GTreYprPPAhnN1cJDDRXig3BsV73bxnViMpm5MvdalPVT3ajgQjHu
# DATA QF4kxQeT5n4G3K7bPmoidIWgFZrKDDnjgUai1RJEvcFhqv7EWxqLLFkl2YI8Qkn2AE3XyC27CDBY8e9bU059bYbCgZKkgTFZDj04
# DATA r3NtBv9KmU0+pX1BRn3bBvU0uriSxIxw/v7CkAdfSmqPaP4UhEqgrAq/0fhb+Ro8P+/RnugjF5mGhkfd/n4hXUyLHsWCLo8zcVa6
# DATA hJsWS5cUhV3T2Xa1ldNNv1ucNpFsVRHAPchh+QhAsQkWApJa/kXDsIHt73E4r09jm2aKSlFrNWDQGh3OGiGr4OiGmqdhRPWtbQqw
# DATA FL25A/59LkkIRTx+/svnvxBUqigmHdAYEgX6BroM2ZsAHJB3Fw8WS2Zh6u38gNJp9wCQrRDjsVO4NwI0O2wavSJmme+LNgw2TvyQ
# DATA xO4C/iXhHH5aRc8zV+cRjXzj7BmS6eAuBRuH0RUtJEVQrnT64ywtOo+HlBX5NNhRhGJG2PpSs21Ap/dxHTG9m9PThOHScM/X+Bd3
# DATA GRIHouXVVdohmJpXlvDYIqW5S57EoUWLS2sTvFBAldM3uncSYuoL4XuI8UWQK5QRQ7HXL8hJyk42L4Asavd8Co/CrjqTAUQGsRSI
# DATA QbCkXi09HDZPOTOELAoN/4TwMeGT/XGv1QVki7kdfexGX5pN2Yh8TDOWO2G/9Ub9RMZMqX1ZWn0qmQcoD7B9CEFeAjWBnA3YEeMw
# DATA I7CXeMtPHu0n7sKqnuisBohSy9ln/Q7G6Uc2IFOKxWbVprAzRLrlSPqdOlWR09gGjbNPY5kbK3n9HyjPLqDFeZCfhsYWtN9fRrkA
# DATA YZEhFMZKW7ieoLpNiWEocKhrccfWO4PjXTLoP4BrXT/LIGUy5pRrDsnq0Gs/sCqjO4DlQpQgUm52jBLNg2NIuiC3SbEMNnunCatW
# DATA wIe2YilsqJYOIQlZ2FYg2SrZAM9vR25Aod3ICsGxYblw2J+xz7nVoOO0gVBD5LSBf7InKKgmAHyTUYervoEBQzBQiaWmH1V/nP4v
# DATA q9xq3L5+a+vGj5P36ZcI5vrB1q03b924ces9lyRHMd6qtaKmSferQEdifUkqK/tLBu0FlW5DXeTV5VgQezmfUTW4KH4tZ3e2h+tk
# DATA 5fkou943J01O8pHeloqT/++D36GcIUnP7HwliZ12XjAIJSIVNbVtER7pWNU5fPJdwCqEQlXw/LtFnPBTOjQYJGnPB4YmVCy6FFpH
# DATA YNFLEQGvSxjlyEIePPCZFlHrQiwbp0wu4XHlYg5klWaLQjVpg5hNZFmesX0nybyVIhdyG7kJ6Cm+13DP6kJ+q7EvGX9KXQmRGdDi
# DATA K8rCBI5f4GqjD93zjyQXJtKPmzP22f+YkpfQ5NC0s+p64W4YnYNXSklrBZmDFvfSBL8OGJLdDYkXrNdjtQLqqz6c/kR+j5CT5wNB
# DATA bEO/rOmNERvTE1qsO2kI9XMz9zSfF8DUkdiBDHBdQcHcpBL6IvETQj97csWDncODCNZLLoFe8kFOOFRhI4nVOswAfog7+EMc9y8B
# DATA u8062SqJYN3hKalKfYFJxz4gfY5gijzKSXqoGHiWlLvNMEcCOW7+RRX8A4HS6zyJFcziodN/f+hkEMRQJwQgYYf4x0hOlJ9Q3O2e
# DATA Pa2EDaZEi3YycP4Gk4FzpTC1SKGGMlmlo1EewgwNz/5vgyCrLmeuNy2mQVRVhhVSjHtYG3TyCZGl75mriDOsZ9g+UrcZuB7EB027
# DATA FapQV8dqctCKbjr1MCHtsGSPSgYYMYCmROb1sLXGmaSyxEDS+MavRyITDEhEKQKoonE0ypI9pDJ6ONIZvijsuyQR2iUKqi7xLJb4
# DATA rgZ/QGy0G8XgMjdy6YmnLMfdYedoQqNjZL6knqJ2LRuQ0MXyBtvkZyWJL+TqSUwu83gqcMeNFhmzrzqRfMa/h8TFlB+QBHDc4G9u
# DATA 3tjYgRkOhF0rr3GYf93DgrbTRsuQDdCxmg33WNGNwjoBhjU47xRw0ouclIPPMkTQnX7mPP9lCbjOz02C5qd2OtY4I09TQ5mGhpE8
# DATA KRpaIHAcg88B5e4JNhy4g5ta1AB8XQHGNsHX1hVGjIHmhV58zzCIzbSHqK1FvQR94l2ZcKouSKJe6QmtoqnCEevyIqXVXkcf5w8Q
# DATA N8qW3QxRoDCTU2/RXeRiXjt4nMpZnrhppDRYqWlDBxGY85zCSeu+HDa7d/kyUTihMB3/5lIRHGlzzwTjq3haNkxI5w/OZoc3c5yK
# DATA kIMctWf1+Pd0PCPN/2ME/qvKgsxRey6amE4XFs6YNzFBA/MSh08gQRMRWqHGPInP7HTewUZcC87OpSB+Xx3NFb7U8q4u7lUvrron
# DATA y8w9HGiBeP2j25kXmChi3JNw31Y6q1KLAIJxnGO556H3+LISpcfqnGurm1HnbnJriBbk1hLKrrYM9xfSYPlnxceMP/wBaqdwaAl+
# DATA 9EQywz97GsqM0sprYY2vL5HNiuGmyotLLEYDnYIg7cmW0Wz0z56WQBuldXf0FeQDsrK5P4lq5cLOgiDE8/Efc8ijhJLG1C+X+GmC
# DATA Z1rSEfJ62h9x2gQQMbjkn3VUlYOUHIq5v7cuHE/4BvNY9Q2zjScwcOzQZ3yFwJuImSW+EIqJXrKIa5uPp71TYoKE0j7/udyF2LSO
# DATA akMtp1jpsFiGEV4Rl16QMI30QqochGniXYv+2EP0BT3Cvyvrw6MxNLWNb7QmSO3YWqOhZPBGo2h9CVf0RpM/KaT9QXsoYVIHx33Q
# DATA i9QY0wdzPaUYSpahoYET4VIKboSVARmnzOI2fmP/rXPqYpxAykg+zaGg3mG6L/j7iHDviH+liMmcHZdpt2BZTLBjPXC4EqDHBA8Z
# DATA dTN4zv1Df5TyeKBORoprBsSpzkjAfqg32QgU59YjQe0rM6YBTkG32bP8HrBB1o56j8WZyvaSGLIzjq6JZhQaKnMH7MnKec2dj7+U
# DATA cdBbZzIwGYVeLoPigPcg1BuKA0OUdMpltqkVr+QVYBNdfgFxG5rajLkI2jTqCdj5bZjTZWorghg1pbOU0Df3PS11/nsmJQJPn9oX
# DATA zJg8paYhOyVBZObwKKuBpnzq2BRtTesYJb41q5Fb0lIw6dWf1rDZKRwrWEtn9BTJVH1WljSXTTSV1VIk4wamyJzeJOKR9b9+HQCO
# DATA VD4h4ANDdnnpJurWEE2ZOVthkGVdAWa+uDL1OwZlCj6lrBnTmiXe6C5Jblt+9QhCP50pRJjznIvvfEq7bb5eumJq0OWV5ZlbH08q
# DATA s8o6TzzqVxiPWtdIb2ev7blmGjDD899yijhulL3buSz+A6UzAwMAvyr6cNc5QPhQN1KJn9oRbxL4MXKzosCOxavkU6LqanDE6OTX
# DATA VUqsJxSiO716/1yqelHJcvOxa/TBMtFRKQhh9ru258D6WZqAdq+530WVCWQhnQ9nBNFMDKSGoqL1Gzdc/BHHrCR5AfCCgio75/XA
# DATA wKmgz7OOArCXGoDIYMqovybtDPc/ihbshHA7ndCIdGYUOenl4bMWAIxgUgMY3bRRtgghhuP855tNMHjHciUYhaG1/NrE6UYi6EV0
# DATA 5o5VmqeKIigdOpUi2MReP51OnLaQaqaXHjTgZZvc3ysGeWFqfb4keS5iZ1CIPHARPtgb6qCi7/lBsZTEujjn1FpFxNkPOjB9mDHp
# DATA 2PKbivjgn5NpTJWzresYF7Md96WYO+zzLKJ7sbDSxWQZ5CXlF5LwMwvH5vBI5pr4gz8p6e0+G2Xb1CTLrdkFPyBaL8yYUe9yZBMm
# DATA vGjwC6vT3Mv4DOYNaHon/PuYrVAnsc7pxnk2XeTi5G9oMbvn7RZ7/1EiGERK4OrmW2Z8ws1pb0EGWiKVYclT1ZtNbT4z8Qzup7zu
# DATA YSYE0xG8dRQj3ILvBw3DNcxH1o2g4ezPwCF42tBKyawReC6O5ObZ6Q3GIwcZBJ0uqsbeBEI6uRdWHVcvfDmJ8jKK+TGcbAqrQy93
# DATA C10+j8ymXeCdlGtYai4KmmvLTm2Od+985GpR6lzbNFfdEO5b6oCDv4tFrW7gYpSsLcj9mmHSVNXN4m2ubslaC0rqTM/PxVK0tqw6
# DATA jXqkVGHW0WwhXkfZKHM9tD/NGGugv5reQy7d4NLTehryEPzBX87ollEp+iJPCSDoEWlGisRI87wzyOkN/D7rsxF/yskolB8gT0/l
# DATA Db6k5LiDW1vpShwQGm4bauBX4r5HIGhrA4rVrA2OWY/KcZZj+YxjUSt2p5II7VxVrDBtZ2ohkzDN6QfhxIZzCwqDGfQSKhiqvkiv
# DATA 1ekhzni8SaeLxfN0QDTNc/ZB0kF9092YuVZOWzOXTDPPOS7oM5tGCRuazPcypQg3RNulOACLTObpAwPcmzWYJbB1TjAJVnZqYq3V
# DATA 3xVyoOmBsF5YtsCgG8hfGw1rj3G0ZDGoUyOrO05DgyXK2zDFumsFLMyDsgiBpp+jFxtm1ArjkHRHJHcm/igMSpL5wyE2/ZnpKoX9
# DATA uagpV6z3OrznlVd8dqjKOI5WTtrzkB24aPSaFc/IrasRgGeQCBmgwtNF2DIlYZ7ruNVpLOyjZCp7o5wL1nicgnksIJK/LPLCbsZN
# DATA P1lC7Y9ptNe330UmN7oQ9kMnC4Cf5OHrnFBuFRsAYrUN4Z2UKGJGNXOcwlde7AwUY6UjMAeZDQLhY26xRDR22k5RRqh1B5tCXO60
# DATA wyp6qf1FZ0UGH7VpkM4BPqnmD7NuKmk1UDFyCqEY8wjK2jmHnA+iyYbkKyCtKiU8NNw/LEVbsOqmP7ZfFWPq0WrSGagZHgKCQ2eg
# DATA pVqtTuFM93ZUeN4kIdLkgu/5H+iUpWoHdNSKBcAPS4ggH8LG58UA+MKF2h/3OS833LIpLsBCa3EShpgarPiB/Ksc2uOrM6XYhZz8
# DATA K2KzqHoKn5RMO1WLh07CJWMbp418Uo3lUuFy64EEbVUyWxpeWFDtNpCUGg0cfqMBRNpo8AQ4gTvkkLFgweGEgCuAi4N4KdVpQofs
# DATA 8X97/gu1ef9Azu853j0zXcGxOcVfMEEbiDMUTG7B2SA4zM5pNmqfbFBeRHsQhXeBKrD3peSd9in/Bfk7+M9bO/wHInH87c6tresI
# DATA tYNPi3ZQ2iaqZjCLRKd30B23BOkMU0Nk1aSHkfU4/mTY/ikBi3DWeYjLG3e7CTRQ+Zanr5I8+3cTsvf8E4LlYJgEHTlQcpE6fkkh
# DATA jxZfpiACN3/K818CotS5VuOv/tf8n9pl+104OdU2qgxOv5U2ICj+0toa/qv+5/+7fOniRf03Pl9ZWV5Z+6tk+buYgDE42Kvm/+p/
# DATA z/+9/PLLsJEUdyRTroT+Yaid5KEhpVsHMAOH7W67mQHKEUWYrlRWKz9crSws7B6DD69d8GdjJaIno2N1TiCaHAeIIAZo5wjS2hy3
# DATA uwOMQzkG9gE4heptf3x0vICF9IUi2b22XSYQ1cN2E0CK0IwKMbKmj5y+Ozlu3m+r3rXBsxyslq2K6lt7iOG3LXWk7sNRCkBbvb42
# DATA RR/YhwQitj5sH4wp8B+As0CiJBDDBQDSnXUkBfwj3Z01nmN1KNmdTr8jjuPE5xz8NPtP2P+vXnplxd//q8sX/2v/fxf/S8dZmwXs
# DATA 9MrCgtoI2Sg5S7aHneykea3bwQs3/UomGNCA27qQ/s0AHy4dYJm0eIW//emDkV0MxJEH7X0yMRR1CzvXbm1jIpBbmHQKgVz/vl3Y
# DATA oyQeGe6cqsCB+86iWRUw35RwKjmAOfdH4BPP77MqO7LmFwBRX1VThx4ejnuEzDFsjzM4HQvD/oMipyyR/Hr9B8lf/zX8U+GMLk6s
# DATA tN0Qer2nqrTR48Bn7YcDNUHrI/y0BzLV++8nzovXMdvedRDZi8Xg++xAXQqyiuKrRwhrUeM5lSfvv+/I5HN9cyFZkVFxUZYQMzdy
# DATA Beez6HaKawLZ8bSAXye116NV4e+imunJwkITousTPePqmni/A3eRAlFXCVNtSNoyWQPQ2r209Hd7y+UfNsuH9bPLk7L+e21SXtM/
# DATA LqoXl3/Y3K87T+TvldXJ95cqkBgdM0PC/EM+CmviIE1C/1CSpr1EWi7IO5FCYXosc/dacnG1CPChijJg3RjbcbOHF3c5p+iAUd+1
# DATA 1KbpNCGDyhUB01N0Q7Q0nZLs8uIEB7cqcBhLaNoqzUEHk19mFYC8utPr/Gys7n3JAzgHq2p743gnyYQbX1pKbrezsWobkwIlTTyw
# DATA y3gnE8itkjhmQHNIo6d4CAPERAcjAlUPm13Abegf8Dl6mAw7R8ejrKKXTXdYkdlLen/J06KsME6+P5XsBJYgL0kOjpu9o3brilgr
# DATA URpQ9DOi+4odcE1uvTRUSqHSVcsJtdfMDKoFzZlChFKG6cNk5lYPiTZhzUqJ7Nqq2bTwn0qv/6AAUQMry8licvHSK+q/ly+t4TkH
# DATA mEG4NarJXqVSoQ3EATvO2uyCCNXvtpKjYVMNh+5nB/2hGvmgD4kTIGcfgKyNldik1gFhhTUYW0WtLYgUUlufkg02gXqaBxqTDYFn
# DATA nUUGGayDdDqipcYxshgUW1D5ey7mYc0jrUTO7IvSgmj3DOZ8UsKVOOPZsyZvMnGWmZm1OpIqIHEWznjJ1Jk3hGWrIuMFzJMuBC2t
# DATA b29a8SudplrMm2B2OOz2+0NkoEQKrXVMZgMAwZhQcgUXU3+oupPD4d9IzgDQrglq7CogQLcniSIoVTBoST4OG5oUk0nJcqYEJlRS
# DATA e7rZPeqrDXt8okby9g44ViANTWGyb/aHm8SWouwWEEF7LVQ62pw3eCgb6qDb7JxkV2xsY9UtegoQoWoVyHhvqjBNnenuw3bgAdTV
# DATA ANRWOAB8KVXV0mKynrQ6h4cEnYqKdYTIVCznnqJ4w1Yh00um2BjsRSHhSrK4lEwc0w/3TZEu/YUWZjrLgRbgBR8B/B75Zs0+B6wT
# DATA EPfXN3kqWY06+8Xw/6k7x2b9wvmhrqo9Gr1j7HlxBJ+iztMTHM5WPfqMNrVNwp0443xHaqUOoPhYoXRkmG+qNVZLo5i0YP02h0f3
# DATA KZdjDaDBZX5oXqh2wFlT+0aJIWcuUUZmsk+SJQB1Y67tAsm8b1SoqndJRfpGhcTdNyrZoAv3ukoK8LbJG29AtqDXa8mrsMcD3bCS
# DATA YgcjyIcI9FjQsjEi9zQHgyXUvdMQsyURrPmj8uAoLVaoN9tHxcJZ1LtQDaJH0GU7SJhVPU/qIKzYOZBLkECrmqyWZtSzS2i/Nztd
# DATA JRtXFetpLANGa6fVbXuvLtKroL4JcCVKGE8jV60X8rpVrGRtgBHdbg6biqQoWJqSzRdhelOM0jsAnua2BBwUsgcpalfSQATEAJu2
# DATA 7zMFXmubVIXHuJBQvgRynT1vlMDTATbT+XsSdEBEAlGE2FvipJwON0SxwM+mMWJ7now1fufO1Z1rtze3dzdvbTV2b72zsdW4c2fz
# DATA ulscsmiTxb4UoKlPqe72xh3VZazUaEIrIFEUSOJS+8iDgSelPb3lwEjrU5xS2YC4zRR3rbRpKvPwUp99Bo8QnQ2M6TrC/Z8sTAu0
# DATA rH2OWQ9NzHgQ/x5XH//m2e/QOBdHfvPRSioY+CFz97AzuobW7mRFHUvWSBkFjMfKjPj76EmG26lAtx3a4XC09yl/0ZkhgVKMGkpy
# DATA T55cWfgO9D8Ns/u/UVXwdP3PyiuX1nz978XVV/9L//Nd6X+3UY4yay/urphCAtSsat/ijSJQnzi3rHZL3cAwzxibg4BTXlqTX6AI
# DATA kr/72QKCPINTT7ezL/YjcCeQIsO2/AV2QP23xvqXJ6P2yQDud1TheKiOpH2Ku5JawXcDDusFXTWlluUQbvKtQrdWdD0mDe5hax5o
# DATA QUESNL+3rt64de2dokmdBgiCLcqb1oKgX86XQ8nTLAMkQS0j3iAALdN7LwuLhTcGhSo7jc2d2xtvFWywXge9V1IUQu6NWDIKY1Us
# DATA pJtb767f2LzOpwrEwLv4Nh7MJcEaSUMgFjNa9tkyTpU6wNvqaaE4icIJL7/6anFWj0xPGjfhtLq60di+vfnu+u6Gg3mNRxNPqMk1
# DATA 8oqfa0R7zi04Ht208vhfJ9UNPmESiRZ2ckhYvgP4Fn0WcCm6+oNwIWYsgoDlE7lWAj9B7rSQMTneEHyn3P21s0tud01J6TEFpzGQ
# DATA O49AfsMgVpfXLmNuvLt3MW+KXRZC8frDVuGgCPqwi/CIfyopfWX1VYpBs78qzjMd2+tbGzdImlqgVOzoImJn1cEwMe4I3Aia41E/
# DATA 4iEhk0m4LD44DN4ofWwnO80Fz2bhbHGRvRQkdhFDG9DtwYlXnAQ711THc/0CeS7is6U4z/oNmaut9XfXN2+sX3W2Mc9bRqGXdquc
# DATA TX6nPRpxBnndPr/SuZ792jQCOLIHGwpONyd5z5lFFDBxN8K7DDstjCVOe+A3WHTgvbENUoj6vW2etMkbFXDpYVdDCmF/pqV/sfQY
# DATA 6d56+SfN8t8DXLX5s1Ep1xX/UoQ6SUmxd65J39rYfe/W7XdyJt+QZ5JCSG91aUlSpZuUVwD3xySK3lbyw/Zs05PBCwTy/vat2+if
# DATA S1Hg2uvSdjGy2td/QnoE7Ie9jynMEqOOuY/yCutS56mqQk5VwxpkG6o3Fby52eutKkP8EAxy1mwGigIp4ByoZ/BbdHPyW1AC5ffP
# DATA xm1KeQI/DofNIxQ+dGF15OpWER2XWsOXcPgr3rD8IizHHdhLNRmLjudlaptW99u7u9s7XPPtjf/jzubtjeupc+pone3QkHVJqlac
# DATA fvv2rasbwMaUmEV6C8kNqy4T6+PRcX/Id9Jqkl5VF2rFZhAWyr/+vbf+7kZjfXuTThp1vUBP6GgpPRMMRfgeQBFqCibFFPdiL/1R
# DATA Wd1eHjSHrXYL/kJ/r1Ttp8qy+r+V9Eq85Pawr7h1PdGzCrclT2sJpI4CGrRHY2/u44riDX0d/r5GsEVdiFku6ZRuGWlQIfCdLmj4
# DATA XQX/C+Uug1ZV3chFNcSqNVSuZ22tXztsA+OYMUcMHavYJw8UgKzJVbma4tVXESXoopvdKnWDfpAWDg1b0nClf0/sSUw/FPzRPIAO
# DATA kF4B1K4g5NWWASNh3LuX1fbq8ALYMHW7QMPBt2iRker3+61TNZnw+YUavmZT1pXOYQGevr62iKkr4D/FM2fSrkT6JRWrnk2oL5UB
# DATA 5Bq8OgaFbQXk8wI+V5fhiZ5m9CuroTsZJbTl4urtgZKDqaJiZdQnvRZKc0qYM9NFTp7vvy+aWvz9Uq2W9tGyjJY6KlTRS+qV1i+s
# DATA z6JTbw1xQe9Ztwr1YiKo4MnZQVftQSE+pEcY+2ShgMRdKNZe18Qsxu4aLRty9qXmoLNExvAlbQwvXlEDL3D/5an4cMIIWDVdjAxA
# DATA g1VckWbZAB62mmcqt75V1We19eGweVrpZPgvx7VnxTfEsM7/Vvhf9a3q/EvuR1BPMdZdu0n1GZTbW66/QRrxuXu8lF7AGMT2ndub
# DATA 1ySKQCpj7bpiOMVCUaus1Lr4+ipLl0TOjBbqmcYpfgSwZFo7BaW+JJ9FAp7+lJ5GNVN4OJQSVQahziDXAiVwIV2YaQARmW3sR8wT
# DATA 4+m+1JT5aqvayhXgMui/hFcGVWC/XeAQBnMP4AsMHzqKr1CMcUkcrFgkyr9BhZcMbsO+YeCjaYfl9vpbG43Nm/DfUJ6irOR89a/s
# DATA tuFi3xyeXpeYkAJBVUBeSUmBhhSBQy7TFfyw31UM2sFKl9gkelXkmGdRiUE4lekwC2akAkUo6zRyHtRs8Yl0pJHzF0s5atSYyF7g
# DATA lXAyxryI4B6kOkBbWKTy/LsIXf99KZv/tER/Ksh1m6R/sTQqSFwmdWEdMX7aB5j5FULZygwpjf7UvftFTZl7UGVd8MagOPwXRSUP
# DATA bSRwuceWwXGxh2KENRJ1oVELOyzogZjbSnG+zjNudblMkHzl8kDdPvCq02bIPhuFi3qRDx2RNwf4XC0oElhqJoG3XHQuxKlc+4zb
# DATA 3uVWOs0d/afvRZ63ZYHq169d29jZabypdiyIt5TODe/pxHZAT2jwTzDrQh7z4RYVy7pNZ636XvHjdgt07PcxsTzPCWkfryTZcXNI
# DATA 3h8JpZ5QHOjUSpcJ3M/yWKfkO3CDWDBJ9eLARJysygUiYq94JXzHNn9atUaWRva9KoADnixIFgmoy3QKWA5mEMoKEjpF3bBxWfFb
# DATA HjeBIQmwQ7Si/ugYgLZz6nFz6fBdvpTgRyZdhz0xFagJcM7lkv+Szr8oc+WgTWAvGKGLsDnOUlwqNRlnk8mCzvkOA6p6+Q73Uusi
# DATA jBeGs8VFYcUScG/flTnFnSQJ0Z+CpmFxkZZvErksW1MnvsFuxYRFcZaiw5TquhB0CmNXv+GfSSkJyKbENGOOSv/eqJ7Zveb3DUpG
# DATA NXsLqvNS9BA3IXb3ztbOnW1QD+i7ZqgJggwsNuSUvCXWrz/CwLiYsqdkIH7lU5sswsgqSrMCRwNJzzRS0OqgplC2P6JkmgMcYCUd
# DATA LQ90yNYz6UPJalFe7kG8l7RsDit67nTgpZrHf+ac7mu3tt68sXltNzLN9uxiSNuZOttGoOjoKlqh9LrUfFW+sea9ORo1gXsB3kJI
# DATA GYifnHLtXmJTax6kEp4Cd2TyMuznZFrEmtUxcKAtQM140VPfZoW9RdMmTHKxGOxmPQSMC+PSjsMIYrkQf6g7+ZOQ4RfwTUl8ADlE
# DATA sLrgci9NnJQKhynT4i1qLSDzHdqrKvuX1thygN/tpRTpAEmSPIsCIYOT9yEqzfgD4gn1HFmR+gRtluQD3Nv1oDpOtfid+f9z+Oc3
# DATA HgY03f67urr26ppn/11d+y///+/M/rtz2jtQd+8eGAshOIU8bVzPY8pEDnuoaeerIBc8A6qN8hUKfJgl5OHIsu7yE853KMbYw4Pe
# DATA qCs/AJxPfSE/dVjwN2pDhgv/i1iL39n4MSgod+5cbWzfuaoYfeP6rZvrm1vpwvrOzuZbWzc3tnYx8gEFEUg6MUz/rvBGldw99pK7
# DATA o/qF4hvB5/hisVZZ/D5k425XboJF76DbzLLkOm5HOmrMqaPhxtW8EEPs9Ycn4IzEHCvX1seHr30NJ9bIVj76Onk9eWVllfwq2SkL
# DATA cnveze7e/cEb37v7cHm5fPfhyuHdh68e1lNmYYEVz+56SgNtsGqdj0fPjMA82rJH0JPQGGEFSOcq5ee0JTAqCJkL4IpSStbWLkbN
# DATA E+cfIHxJI9SVVEgPVUg7rV4z1edJsdKFJJBsmnZu505kPP9ZgOqc8GBDHBbQCtBHeGzP23tQCQBNYFtg9X0FrblpRWfNxvGpR/Cv
# DATA GliLchSBSyTkG8P0quYvNPh5OYZARd3tFrwksmrHLD8Ub9gL78Nfat+kgGk0HBX5KjHUPbAcMYPaEWgjbGGP7X6qJf4TrX6XViby
# DATA pvjGXO29ANVzpkCxVe1Vyyt1IWNKGyUTiZYrpH55J+vSFVcVWJa1ZVqWSiqXK/hNV0CTgcgZ/xIPfL38EzXYSuMfyvUL6tGS/6y4
# DATA SNMOyaHOP1IW4JBKyChiOdyIS82AgkYcuc1OpoiN29wskixRUotr6BFgBPBknj6r29H6m3Bl3307jWy/b8INiPcoILBs9UdvAlSL
# DATA t1XBu4ZnohpzYNVODnos36p/UeH8DkbLq2uc6Nx+2wMsJViNlTA9qil1ft+h1dXoxWy+9cU8bs1R0/cZsoZwIVkp2psNihfdYb4Y
# DATA bfF6Qn1qM/yNJxHB5uiC/pA8U9ztIL4qFR3wDIz1XjrDW+2920KU125vrO/OotiSnd49Rl/NCzn0FXFLyyU2TUpfbxUDNTbKkhBD
# DATA c3CP2yzxMxhbY+NHarjW762rgUr0Knzb6R1t3vK2aE7/7mxfX9/daFy9s/NjR9Mpn5x22t0W8z1ebXttxSsJMTvAJSkrIDFOdUzS
# DATA pGklnDeJOAiWm3QlCFhuCuVkmsqf9q1bu42b61vrb2nVkdYXTkklbLNrk6w64NnmlcO4TQtOmTg223koBuQvzEQcw3Wk1UCAKKuM
# DATA i521YLNHW8EEFTNYkEgdK8lrNWQd+LIIv1Yu5YknXl0soMPhHRFc6IBGR6WV0srqZe2o5HpeYbOxBq3GeLx5XefX2PnLL0gvkv75
# DATA zCyrZBGrkiAQvrDEAsS1mywYZDisa2LySGMXKd8bdtYWf5Ft2tVTGf8Q0OLIFMaicd6tjYqHQmBSsS0pd3qdGALP9Dm8duvm9q0d
# DATA T20b4Szh7S6aSbsYVfeds3kjDsFy7sFkgb4OjzF3isxL+r3gmxI0cUbzHkQtLzgiJHHfZoknDpWLGRS95HlhSvJYAnHcB3v1WFOO
# DATA 1yzXEwUJ81va0z/cemFSCAUE3e+CDNJ2XRF6LuC3e4SsXffUvfjOyWeOT0IrD62pNFGXHSEPHEGIMl8rSeji6ovxAxGADHYjc0+e
# DATA TKYisRSqPuBtnzabVmvgzu1kHvKYLywj18T5R920UdJgYCQad9FzxlPqFp0DjCvJb0Uw5rjgnrrPgVcJ3xJriputFPdW6o7zuYDI
# DATA 7VXh8geeii+rci+nL1t09LNxH0UDKrhs5z1pyWMcSAFLlkRkJe16p6s/hfJKoK3qLrCrNEQrLrN6JbXZCrx7LcFrZQFrkmsk/LDT
# DATA EaffS4tzMxb3cmjPHHVzpararUcUFlIMlFE4qeocRF3a90T5hBGN+K62UsTJt+badtJispJUFoVZZGg8XbAHhhxpz4RHV91d35BG
# DATA xRBaYhrONUlYmaTlciQeVcEODvtHFxbJvOm0zkeZqa9C9sgA8nY6w6Y7JWR0tpzqYwbYKfzc8itxTbNhS4cJaF9RAQ1tVqNuEjIP
# DATA VGZPfVE3nkp2ihnnfJevfCXqwjmPdSZFaYy0iajXYMn5qI36QNZxVzjdQXEhThecwNYhD6s1qk7AEXRSBVEwAuLEfgq6WtCYFrw2
# DATA kTwqVAXxA+GogudIfGE/PelkGfr7OJvpLMXBKhGOB60uKhS6qB5xz47bD6UByZNI5TutiexDY3fgsBXC9KhhCAAjacFNiO8aeHEy
# DATA twVzRw0vzc5dJWd3c1iBvpKZxCKEbFY7B6Ow+ScNItz71gRSC4HOxRbmsBLLXJ21R/wQr0myBOgkNUDIk9uyBpOYtoW+3QtL16E6
# DATA 6tCeWcf6/BLj2+tbb23EGLvZUdI49ZlyTHnPQupzxN2Tfgtw5VpG/n9hdjqNlWpB3xFnF/IcY6YwxxeUaq3OytdRQpop6Z6LSfui
# DATA 8DReHOPHcnfMEanzu55/UuaPpTLoDwqqeT9UKJCao95+YX14UIgcklte51XzHZCokuA79inAC2NrfDLItMtbu5eBM1EzO+h0SPFd
# DATA wqzXvVFtVfILz+G2yA0gM4f530/TwEEhdpDiHnjJvUmQ9KIFPUtUZvsfNJazjLnUxx20KxvvY1AO1hasPe16rziQmZqSmjb88dcL
# DATA 0yhJ85EXGhD3G/7RYTjgkstLo/4JOhVbNXDjgir0ifwS3ZjDRoW36buz851/45fS8xwsOkWWKBQl0TnrB9UdMpYzowwDAzM5Osev
# DATA FYpwmjsdoXpczR09+3oqXa6X0huAiri23H8VYEcopUNGGqEcxxqTqOqk2escghTCKayMh+Ge071oVirJOIQPTdZvznmFCQltPUj0
# DATA 3PL8eE2mK08Ssyoq2iLTXI1MAoEde1vSx1y7Nz5BsNOCEI2ZurqXYmuELtCW4iPUrpsGCubQLcYbioisFvnETIC4skBH1rjjG/Q8
# DATA sojVaM585rQRp6xCnCYY2ZtrDzQKC9NrN5M5+0teKkmr5uotxYjRzNob+CfEAQZrKNQxBDf0TMnNXOd5l4pQmSzOVc2TFbyZn37Q
# DATA oy133CNV/8L5D/bY3M69OMa4ajFVfQ1YdO4L/2tAgjv+fyedI8b3+0ZdAKf7/11cWbl4ycd/WVld/i//v+/if997aWmcDZf2O70l
# DATA CJoYnI6O+72LECV2awB55xPOjAqho82egcsMcEkd6EjA4vS8Atmdrjk8Qn+7Be0VODglbzzQZMDOFU88+U2BvH8Pt8Gv7QYYwMdA
# DATA ygJBkgEvv9l+gbYX4cILZ6aKQtG02jSl6kQzMf7E6brNfcX2QiSEawyAbFRpN7CkE/NlW22pIm01rlDAktwKJU9LBbyy1UI21KcE
# DATA tCCAZfB27mqsT81deManEiphPg1sybYOmuP7rSHWIOjfASM5bg4Rj2RV45HgExuSRD2AM9HkI5MrrQzZveHm2wM0eoOdAsfJfsPD
# DATA 8W27s/EouO1ifuNicJpzkelGSlYnhtNgu0XJnXptE2YDkPpFkykmbHo+ZVbE7nNgKdNqllqNu1TTWbx4sDX+txSLudPG+Rqr4zCY
# DATA 6o7amTXYhfYNpig4ORJO0+x2lJiUmY3mB51lHFGJgZcvDJZCj3UsrYRTfK3tLFpYzDCEumrxH6VsQxLtYO46iwUZDSOG0ODF2Amx
# DATA UF6J61s7ALJiFQnxcKZhsZRmj+xtdorltIIGSvYc/IG+quvbv6iWKecaOa07TtHOreabcEHOBT0580BPJt8t6MkcjoT0rGC6XnKd
# DATA lZmoSsZVGkyCa2sXvQHXjN81TtXl5WK+9USnLMrhFrR+lNBu1KcUxAX8r0VSoDC7r2YAGLW7W0scxj0dN6cUfY+tUM853KHmEpK7
# DATA RWIBn0iUmnVK0ESOpdoYhzjiopacOe2pzmF0Gu1rDnaTMFsOPlAtvnn71tZuY2PrujxjE+997Cfkb5/4Pepxk0GftI0MRLqGFSWI
# DATA 9ocXZ4MLXtBh1ub5fgGOCmjzSjLDoPyC009q5nvJdWQZgomWse9X82DYz7IEMxToYG8dwjbqI+D5AfpWYpJGruynAMMPr+QTjrUl
# DATA DAL1nIJg9tsg+JIvZ4vw0Zsn+52jcX+ccVwuR9Fm7MkMX4mG0p4MCJDHF1jeelZjeqSA9/jlmCH5C1YsfsGq59xrlvc/7B9S0x45
# DATA MfgHK8cZy6FKNhPTqci6xawsOvDYbHihZT27UzbWYRyVwHW91qNgHuqPhLlPPCY0UH+bXaaWSyNf6UaAdQFo1v187K4o69Yb0xkj
# DATA e5YKnHoWcMrMYpU1skkT3n8D0gA4fvdqt4y7I6MEzNoErKi6aYzUBr2OzGjcip1JD3BB5xBsNjHVoCN1/g2Caeuq+g96aPDDKitD
# DATA LlQll5rlOiV8PD4YVjr9pW5/BH7USyZcOICDcZxcrEkgUoa2ZqzssK0EkA7fo9xOLVGnyiva86fqjgU1afpzLSKEnXRCnsPXk9nU
# DATA B5XPf36i25j54euZzRLPpPtR+wQc1GJ3WC+CvBCADwgegdwb9QMdOE+B5NBGaByWN7CQ0AJPLxCw72YIqtNWCw9Fb5cB8YtaFWpz
# DATA PB7YG4NKYTRzrav4T6uJDVdlRFO6X9Re4AQVAsHGSuyGhJcojdQs3A3109+T6lFhb9H6qE6GsBrFjh80B5BFrNEfjwZjeTgi3Kna
# DATA yuVlzTR5nDQsUISaCbJyjHKMP4m/zp0CmrZsbUDDkoMpSQd4i2SMTPhzjPIvA6Fkoz79RDgUAUNBiJcJ2F0YOsXyNqXEM+j7hb2m
# DATA NI0Y72QB8bSbGQH3F9yERynkdxsfHCfWjQEyQz7/4NljwElKnn31/KPnH2I6Scg++fj5x5AcMnn2WFJLph7UPLjQ3+spVpEcdps4
# DATA YkZw+hBT+rLUwR8L9BMCM32Kzf7Hs6cA30SteBkpw7YgUwi43/QB9qTXabewQQseKnn2mfr+L5jn8p8BxDys41qzxxCjAGIkMg53
# DATA tNVsn6B5LOUHCGdl4089idXJPKLJrk6Wqge//xxzIH+AGTg/ArQrNTPxxJ/qRWSii97KampEuywQI2UoJPonQwZRgCJLeqWvw52e
# DATA EJE8AkJjOC4bfEsm4GleV3+V2KTz7FHqJwuVC0WYbrZwmD77F0oFrabj02ePpLXCmd5ykyKTy2eI8AUd+wWmjH4EwPgl6tWnyVmw
# DATA fSdVeAjjn1QSOx+1pKZ/rP55jB8DMhhkPn3+keuMazaXYhaGS6GTCDCcAmH0oIrFds0KYkFCSBnPWSsWFAKG3lCDh/WZcs3ewbF7
# DATA Y+TZhtUtwPQ+wvSxkGL7j7PR0XII3VGh7fn+MgOnSxL37HJH0oNh0BrOhRtAUqzbs6CLig5NQhvhRaHomOoC9Zo7/P/u5L/9k+ZA
# DATA X2simDo0pFUpkeEwmhXt+zKrcKJ6T+9U9FiJVYkhGlKgGz2sOu4gXTdOBwI9yXQQxOUQXVn30vIhfwnvivW6YIWw9YLilBpkDWRo
# DATA LFQW8iMy8DbIC1Gnw+Zcp7HzWTXWbbcHNULmhj8NipW9SYzhIZZlASLpzK+FXKBq03veSCRrcZiSXflNseCZeKUwRAt2WLBZUXri
# DATA snrFTEn9qOpIfD6NTw2ewtQptZC5FBfygmxcaYkIhiHQ0kUiSRE+yuVev4yqgQGmK9DPACIM+RDmc6XHh+CaiGcWe4jACoPY5Rsr
# DATA PDFuwfPNc1yzvdAbvOvk7tnfqp36B96cdEi6uzWS0GQegWXBxsRHLmrIvFihXAdwmrpo+LMg5h2vWLDYVVqK4uEP9mor+irzCIAa
# DATA /1l3iu5xyvm6XKmct+jql+6PO10Qfoy7n/n6nHBgrgbPBwSbDdFmGiYttbTpVdx1lPZQc6df0dc6UWGXIduYqj9yC5wsOO5buJAW
# DATA jyqGnlsIbwm6aTGbYuZBsZxWxqMDXPJDeFJIf/DjH5z8oLX7g7d/cPMHOz8h37ao19de9TIrms7hmoWID4l4hIFDFkWh4l6jeWSX
# DATA Cpo9EjCsINbonJQSB1q/KpsQopLtYM5qokltshB6hGDnSroHxYVpjmTUbyJ9cSab70sxV7jf0i/md6K1cWZKP7Vmy23DSp5nb74H
# DATA zawxJHhOVaFRgQmup5UrQV/MGxiq4DFZusWVy026oJXLPxt3MH2unm9hln5Qk12vYXymAxHG7iBmmpujXZPFnG2NijteB2E0F7aU
# DATA AzLYOtG7TyBixqfcSiJh+q/d2FslK+WBhQsrQm6wS9ncb+NbstagUfWcl+3O2JCzIVam3R0PLTPHLzKHYFw3KlNtnvUkgg8bM4FY
# DATA or7UWF0I08tVHPThyKBIWanBh3niLA1INV+XYk5yMoTQ1FZn+o1a4/U2rq4kAhIS0PIMUTnQFeUIwhEtmZFzTRbO+kzBSDawTE0w
# DATA DzCCzqjBnRYWadENTVEoGhdjK2vj83nzhpYDVep+VA4suVIvdqMY3KJ0Rd9Ldkb9wQBhyI4E6jWjR5VkPRHugJmqOpnqM6dvRdON
# DATA uuwmiAor/kpqBh+ijfX61UqwttRprdJCwbLVFlapfoiQEsH5XVSUUW5RhK7NtVCRuUefo0sL3JBCLmurOa3PQ8fOBipDIKqmcGm5
# DATA GI+IjrB9PbQXZPxOE98or/fPFJqxszC+6bjd7GJ49PRj4G0sZj+BIuMs7i8835FCljruAOhDiW+l9OTUV9jn1Z9nH0GPaLKpACBb
# DATA Pl8OOLKRYLEO5KqzvWb5dvKvWnUJ9wxWXiJ6PWgRvgTtGamXvuJLzGeoO5srYeMMnUQaNwbuq617L7ZMsvY1tTd7MusY8TZ1/WTl
# DATA SYfdUhcj0kYrPtTKWzRvkn4/875mwP+f/wKUeYmtenz2+fOPk2d/hEsdPmKw/+gMoIahsDoPnHlEN/QRqmX//OwrUAeCZvYL0Ml+
# DATA hfroT3kAvz7XyuRc/edg3/EzuNFtnkKKDNJ+fPNKC+Yci4sivJsj+k2ODIkNaeJKTKHoYKuV8G/H8SXHEV+qYKxXfezSITv/kWpg
# DATA b92oGE+e/088scidnjRxcHcraEyrYYapecQbuLI+PBoDO9vGNwWxIqqx1xoNdWw0GkXrS7DhNZr8SSHVanTC0Qd9Qw3IJDvoM9J+
# DATA psQVMUmhQlDkCFIrtrstUiNSXBSJT2z3hF9kViMjFquWCEwG7V1iyEYWm+oIojLcAeCnJF1B0y6KTWgAwwwn42HXVqlFh1fGmzn2
# DATA csoklMsYlwLhdaeDdk1n5EKLXU2+wX/gq8xc2+BXxbL+KU6q5y5PZqZvcFpKtv+BwwGwEHlVqdPck+7wpWVedh0TkKLlnhLvI6+p
# DATA JYfT0vt8CD+l5XJkKXyOc6YjEFkbvwwOrtbr19D3lav33TOCg9O3gNFB+SVagBTbPxefjWqDaUCG2+iCuapgkIyo93tmWPVpS8vZ
# DATA DW2e5pw2ole3C1PVdKHDv/kmh387GnZ8ou8S+Evr2rUW3VBPQ+0SsJ+rRWugYaHRQApoNICpNBppxLeT2E2uG6JOffFO+3R24gvQ
# DATA 07c9eNUh+PH8/+1963Mb15VnPvOvaMvjbUACwIcoOYGCcSgSljmRSA5I2fGCCAoEmiRiEMCgQUmMxK3YmezMVFKZmqn9tFUzqdnd
# DATA 2s+KEyeyHTv/AvUf7T2P++zbjeZDniQrzsQCGrfv89xzzz2P3wnPfoVH+Wd0eue0uFhmPjDc3gk8NknW6ZbI8shJgDBvNZzoX7/8
# DATA Z2gEKiOLJRzyn0Pt0H4lEJT4nHsDmYew6U/x3Y/RVIYynJAJUKQrBeK1jymTESij/8FIyo09ewG0i8YibBMgXuG2WYP4B7LKG6R4
# DATA QjmHCot/GRFSf9l/lsof79FXDv+eHf+1uLC8vJzAf1+6ufg6/us/N/6roWHeMVFHNCEEDtLuJ+K/4jvi7BS8fK8/hVRc0smBhdE4
# DATA XwxYEjVeZk9ss3+CHyn+4hFhmH3xTz4+7FxmZOyjP65TY/Fr1ZtK7FYynPdMoa5kecGzON8HwIr+9IQMuFUL8tmOcS+Euwth5Ucj
# DATA cKCH6Gm4Z30kfdrJo93UeoaGQ5G0uxaLGtnIipNvVpeWWwpXujuaAIKqhgHCIHTt0Upp3Qw4BIWvmrA2xaGUjumlTABSMyMM4xo0
# DATA 6vfWt3caH4Y2vpOJ7ET1HgxGe4XwusR2tTyTpUeIp+HzNG54DFhypB08LtuDZJOodPIscJ60ufeg/dXNxloyITPUlAlFq9Ys6YhJ
# DATA 7vKepTOgcefUOOCRdqWRTvbquWdCvZK2ERGSxNw1aWaLdHWyodmgu4mRejOKkyvw486jqOy1hxJcBxQEoH3eYt4OPhTsCfIEtdDO
# DATA Ddu/MyS8LrhpneYZo75PXGqg2TcVzg0x7P8dQkgZWK9IwRAIAJUZFxEsauYtsgmXzCgWiiW94oexNGl6Z3MT4Cs/RKLett2iqA4Z
# DATA t8u3ZRuDDI/QTq+MPubaxXq0H5APKZkljtB0wdxbhqGI+2j0pNOVFCuT1hEbdgDBszaCIvq241yG7Mh87uNtHGZ4arSdvktssFCj
# DATA tIc6dPMzIazTumPd9SRvYJsC7CWjemtHJZo1XQpKxoYLi6cJ/oUve6MzDJtEvxcbxhXL5pFiYJHxD0U7QGEoKDmm1Bu3ZTizJ499
# DATA p7wPQcNPF5dKt5dPQ79jItSUl4Wvbm7srKxv1BuA2Vnf2Nm0DxJFyOex8VyHDpALv5geUiNq/YOYj9FjwnbTCzCfwvEwGLQ/ms8s
# DATA 6FPfq1iRGU2cJ6TkNBkVi/IGMiuLaxnxFilGGH06niNYxhMWA176NKGGhkfGERiEqtVlxlLkivHxwgMZVVYgt50ghmRcUlNV1zJj
# DATA OB27hkdfI9U0xRxAz+a8c4+S5xG5lqmA8dCHJucdIzsxpng8z/ngbNDDhJ0U4B8W8+NTL7Cg3rQei4TfMGWmTHFikz041skcKtlo
# DATA PJwaTxw2KguNd5QSjbRJ9pDr2A4PNSVa0etkTTOVMo5EKtFU+2riaFOQDphnB4BM4qyhp4rXKOM6wGVO26O4InOhhkNTR52EIMS8
# DATA LCx5d6aFYhZWYt6UKQVfzhQz1pRmhnzv4XGi/OLCwkKxmA2fmD1Bmx+II8SfK9nn/ZsjN3ExJ8g7MbumLQe2LFdDDtMVAgE6hJ26
# DATA UgZVMTczWXIu7bFPhpmbu1+/t7JKsiWlOd9+xedf3iNQYiiwOQYDdVFMtYAUeCgp2eV0Ztccp1VyJiRA8PF4jJflGZ1I6ylthdQe
# DATA 2oC1M3t63nDTosKiOIgMZU17EgmxD+4K0nOjKt0RpU9HtgdeMSnda7wA5b42A6IgPfDfcW1TJmiM9gJrN56ZWW1pzxMDDiEjU12O
# DATA CGelwGqbtkbCjJYSBYc3a3gZMwzDcCRKS4uWA4HHRWXKKUhrn0gd5KRSFduhTsVkohxPAXWk5VFFucfVZS8or/hycpGLyVVfStxQ
# DATA +H3tTmQJ88ZGIZc60+VovWdgWKUBP3mmSFSVA2PAJmf97Q2nF354Hi0LJP2HZnVP7QFqud8z8bj0r8V8kepeHp/PNe4CEekmB3UU
# DATA k3hY2PszRcaHOXY2ZZ6uzLpxJG4b57hp5L9lWH7ezWQ+mnPePpI3D5hT46vDzyivAN0m/IDbF7lK6EFpLeOkMPNy4dw7c1wtLnmt
# DATA uNCVIu91IudV4uquEZmXgyu4Y5z/fpHilqjJYy7nTST/LcSDEmIiSegrB+a/cHXT2s9M/ChYaZrgDq55US9eVeIYqjJnyJWnVwth
# DATA UVLTK7usUS1IPotckUzF2iZDaklw1d03pTWtmcol9zk4IyyfSHctzD+aJV4gNT1Yv9dY2Vnf3Ghvbz5srNZDK9BWOk9x+NGYIG40
# DATA Uxdrq8vTI3e9TG4/hjQbBAtlGS3xdIPKtR6dS9pmQX6YoPQ3ajm4dsoE4HZS6d8erG8/WNlZfS9pQQTdOrcv+DISNx0w0iOMVocQ
# DATA YfOvvvugZCw9tFFLQLJAC/KeiJ6AbH2RbaMOtK1NMxbWUTKjG71kpkZPEYSWUArCVcojtNKtds2mpxmrTsrLWOcwcMdSTcg4jgUq
# DATA u86ZuwESt5ERud6or4XpuKV5Lk0uEk6eWduuN95fV7vwTRQo4kCc/2j2KhMylLR80WkeQxycmIJgbzJ6HKPyenw8jStzCcmm6Qms
# DATA uu7bOK1EOkmfhnV2ZuoLmPBdgSDlrJJaGPFA5sxjgOa2kMmBCGhLJJFW00A8jIumHklOZFudca/J+wl7yoKV/E6QLeYG4FwBc0lJ
# DATA JQ1XxJjkmpMz1vX8B9A8+tIyjwfuK6Z1zqLIlQd31+893Hy4TUuys9K4V98Jz5cj0Bi7ThS4IAPhE7zLybWFggNVEWIEYdUTQag8
# DATA AbQViR/h3e9U+cgcgyAsRAFub3h8tKfUGWixRj4SMDAaY7BB63cUrIhEBB9HE8BRiBFTCBHHcFNikB1ojJTZGjyOMNu2EsmxB9x2
# DATA bq3En4kywrIEXoU2wthWCbui0Rgz+VzxajBDJihbRciqElB72h0bpWDV9iBf5vBAw/ZuieUT92/cW7C40CMuBJ3ijzFDB1uGOdFY
# DATA SRcA7y/d6QxwSmjRhADl7CItCfjZ39+PUD2zvqVrP4J4UADrDDrYz0qwgSeEEOeAjjtDw10RcoRGAFfoZRKODOnsb619SWzvmah4
# DATA hgYivYFZ6gMpkFq3C+YifEY6QofxI3p41lTJpOigi5k9NF5N5WFcwVPl88g6AeXw6Gw+XWsiEguT3iXj4tKu+TMBqZQOYLbW4/Rq
# DATA BOg3gx3BJ9WCwAYjJx/JV+XywXn1KELWO4kP+2NArB0S3JG8aPUYfzJhWfKdFuases8MXcB3cuTE+koaDzwZ3iHMowPhxu3pCKnF
# DATA IIWcZgK9KS6ANDqXguOpbD9s7Km41h+V/N2fkj4toX2N/LSMJ6OJY6tUfXnjnPYltypHztaI4OkgoymehcViFq/zCqLMMCV1FyG7
# DATA 8AW864jyPJD7s4Dx+aENs5PMbGZmlSAKpsdm8Co9KtA/lB2VemXmSrZDpvL4EwNkD/JpyBtF3r6mb+IlxD09CinmSUc4w3XXPKOk
# DATA JJJcyywUAPce56K/MNAktZKxbXNaQS5lauNGLwBCQCAzbAGnq5Tp1OlahqSHefJwTV56Epf0RJpSKc3C88QWSkbBk1+t4fpqXLpS
# DATA +kCv+BrWYph0jiihSdbjyzvryJdeooazWcK4oZEiLGK14Xq5Hi/2jCHhJl5C1Zrh5JkO/ICpdXVBfgweIjLzsT16PnO8PZp98sz0
# DATA J8nlRaJHWVIdCo+HnUed/qCzRxgwYZo++kquk+lqauoXJk+kDoYcOy4e7Y1GA9M/XV1JMuqj4OoqjbNZFRe8luO/jrXqbuqfsqrV
# DATA /j+pZH/qAUlVt+hO74QRaxTI8pKEXAEsCc65i0fE0Ujwu9Gw38Ws3FyeILsOAdAyUei7qgofiJZ/u5x7q9h+/vbt0PHsb0Ro4NW/
# DATA JzdMUUsbE10aCMkG1ki8n7EzoTYHTMULjZ8yJKueZD/sfZ/RDRtYJIsdayxQidSRqV5dWftQ+QjxqWopsFW0u9ZZ6wB4LdwhDIMJ
# DATA rx0ZjyQ3G4zEdTq/vnpzq07WEFttnU/PrsEorB7L3qb0iOKpsyQTAKWwhRNHImnZDSJGALUngSuwUaxAHPYo3iwuLChAjO5oMJp4
# DATA qjXtxAbJZfVV9YKxNBT4hqePcsGkzqeYFLWSs/lGjVfcFLQkV5JUpYIuzFPaUPVNxY2FNH2gwZOrq8BN0Wg7hVAUQFfsT0U5VgcC
# DATA UhaYEKMxaHwwc6lU9s2SD/5kMWBt6FeNYepDdTWNKp4rlyw8087CZg7QFmyvb9yT8K2ouVf6PpMUWd21iXGMYLnqdQZgJGLxE0yD
# DATA iCiJ68RhLXElkFrd6WFnaugVYOm5RowZBSoglcQBqMJQzzB9PCpLgtAZHaWtpSOT4SBJVBjXstc7QajmVF0B3JVWZTESVUSv2oTA
# DATA VgMQTPFbKOVVWgFrSBTKpi7ldnChIQLQcROpDPcx8vOnCcs2t2i7yqB7k+ylJ5zQ+k2rAmjbOGKTeaUW+4k2Ws29hIqrYfB0d0i7
# DATA GbPz8pwk7pPVmwuLC7vDUzPr+NFIXEopuRINtsnDalFXHgnyP7LmDjckKO45QZHpK1vCbH3syksVALAMn4igYw1TExBxecbIwTcI
# DATA s5AnzK4VyZ3rnY+m3XksN68JhFR0QA40xKKZIkZRjf4Mris0LHsJNfwxBhML3lWTaYChcbkumt2qGuWSXwmRaUrgnS6Fcy6ggXnA
# DATA jtHRKeUkY5Dtkd8ykVkENcRtSnd+WnSyZPGb1mUGcyN1jqQ3lMm4PNm7UzjYeyvb7bX6Vn1jrb6xI/mZ1ObkgIxOy1BPuemNqMGy
# DATA H+3Yn6X+HFjF6q56DhhiF264paNUcbn0UlUN7W+dj1HIEXbcGTB4Fx3nAF0puPdI3DnFBe4OeyzJUzIQM2T6q79pZ/AIWIIIjiBT
# DATA GSlXYrgGCEbeGQbGJOI5rJXGik9Ar1t4A9xXTlNNIw+RuQ4w61BNK7UaKdBALeFwFJ4fYVmjDmW/lr/8bDjm1DdtQGYbEY7O3dSQ
# DATA 3HxqwAvE9pLDf2fQpg64EblGt4pkwVHflYeik0dJ1agC7VNCfHV4b1Z1+r76FKiiasbm8j7TQblQ4rTo2z+n7A8GoKY9C9b6Px+B
# DATA N5VEciPyanaMuQQdqJOCAa7kxxxzYHtTdkcGKUtYX0waGqoM3lGbHbVcYEG1DipWgzy/ep1plCBCb3d8/mQm39V4jFxrwhiXWHSv
# DATA Fjs5/Xw/vp44Cs9ZD6WvwusDhownK+STOwfFm+nWPNRfzGV4bNQfbIq7O2oVVjc33l1vPKg74Bv25q46ruO03+0z2n7DUYLu++Ug
# DATA n3c4ZqtMIGW0rK2s5Fdp2+Q0l5kQFG6P1MsofktDuHzKuTMPopQ+knE9Z1NG5zRrKKbjkxrlJcspZiZWcaYv4c+csjW8sbIqa6wl
# DATA tACmpXOfCoVcPOmoB8XUuFqu0UNKyb5D9lqQJZCwTQo3fgaDUFLIbXlnHfQeWcScPMj1UcVep2lQrsYZWTK4kglcQWApCuATtdzy
# DATA HJD6Ylbve2BfIWiHGKifm8+Cg/XuZZOFnGcqZuxvV744RyvWPDr1uPjFKaKJpwmj1PGQLtqJ2A26zNjoBRxIlDB4eSOpMkfJI+V8
# DATA E2h1cGzU6T5X/kiMmYqt8yP3ZoZkmKi+2Yi+MJMuiq8ZSqCpXllEQJfYy+l0Ko9+g1NWE2m/FGOsyrdtaKQ0MA4tEeeUxm2vKVcu
# DATA VyR6SQQw0+c/KaoX7XZY0WTC3Uuvd1mNEQfgQ9hRkFdWGVNpoeV10zWUskWZUcdpa1liTq0VyludOGbHUUkQDBaIF56u+A4zLb6j
# DATA PgfxBLvSOBCLZdDZtJU6OcM/ORFTm/DIyeWXUTzvwrqu2TLbFttcreCOfLtCxn8Hpiuz6DZEf4duKAg5jg0faTqxjhj+xZoHeEYR
# DATA YRB/Ffd/HAV/Hdy+devm7fN4o9c33jdkIe2UCp4cfVBEDwqT8IeeMPBawQgNKLdu7Fayvxf/ihKuZOnrIJak8iCBmKQcNmuWw6a5
# DATA TI6Dpn14UcY0omuZD2z14fZOe/vh3e3VxvoWhgg16g+36zw2UIdQ1YJx7A6VRe9y4TBk93RCYMx4do5LsmR2u3hRS8XyUTK985+t
# DATA mSaHapGW0Z+LzmtXybKxM8SEBtI0LzCZE23tTrRUGCZ6N2C8KGO46EKiQ+3Y29f1+aPg18tFUee7ZaYEyKXMTRKRgzvTlB1pNbkD
# DATA LQeC0t4JVhhUTiSNGSMRd+SN+ipv5L99uK4jnPwZwVK7BKmIcyx7wvVJshxxXEaTaZs5RZvZQpyMqyViL10iVZ5ri0iXExPKbXer
# DATA nCZfTjK0Jq9Iy0h0o+zbriuUnI+HNBHvU224ZB7g9WTKZc97vNRrmx9sCLJdq7fv3t9c/X59TcyW4NMgamKt4P0Nhk/84lhl/Jkp
# DATA 9e9puSlTKCZJFzopnDya3Pc8RTMT0BET14WZjRXT06+dy48NZQkePHnb0uOSOxTVTSN/Gx8PF8l4l1a7L+8h3ct4UGj9y5fFKY81
# DATA 6k/IApW9u3Ns4ldhk7m4jeXc1pwsm8wrSvn3JpwklK8zjsQqig+Dkzt4ZTGCYWQsRxxBdDH9OhoMoL2AzOGVuT97i4XPHnN1lrCr
# DATA t21d0LZ2NZYw6/i/cstN8ui9fr3wNHQNORLnedbphCwzKdToCwO4FsyyB+VPBXlxy9EFtOKZdp5XniTL69I3K6uj6dJ3PuvL+a06
# DATA lzE25Fa5J1PWZSiPkwEBSfW3Ze2xf8syH3HlyiyE9eR/Pc3Uda4JTzGQGWDolzD9XMwIItPwcStOvuDMpHZXYd24aMK715aRDMvI
# DATA N50NMJXRmckAia6OJ7Z+zBH0deRaCgYllUpFn+HgAenb4OrYCm5zRR09ZzhN+zTfyRsJQhkoDR85dNbIpWL05KQWSliOcDbuRk6w
# DATA DUZV8CEqzF3VnTHX1HNAn6WGt0FQcsTMAiO256HSGXYPR5PZLohr6436KuAvoAdE/cHWzoc6CrAvg9vPoYm3bApKqpOACMZghMiP
# DATA 8GZFA1IU27lEn1HTDy6nKsJDkY7yIM0XyNHY/IFRKZGkEZwtI239Ya92X2raJ1uO1K0vbaCbD1bWE4o2tLrmxx8lPXB/MKV70gAi
# DATA f2uiggqjIcuLJ68i6uTlisooVbQHGUvEsJnJWxh5SWN3BvFV9yJz5SR2gFi5vxHU0a7/YH17ZztMbEVS3TCrSVe9EPuz9C79fWv4
# DATA SSo3/VVXdETIJGKeGHQm3cP+o4hvtlwXOo0Go2E3uiOzuxvqtDeD4yGG/Ue6xT7kPOkMOYogAlMApT3Zm8C21y6q3F6aSkZ17JwO
# DATA wkbVuXQ0CbaQHeLvPAG2ZwIfeKq5KC6Ui7OA54SctHl5hT+2XJl0+eyhlwhMqj36yJgJ/XL3ULxYwPeKGQjWViIyUYSPDtHX8aDT
# DATA jbwg1bXD6XRcndcw5dWbCxSo5SsMyyy3QWWiQW59OqSkfbVk9tuCU3lqR58asXVV8AsSNB+XwatwHFFooRBTUX1SDZqWM4Nqqugo
# DATA 3sMxotqI8vvh4tLblQXxf4vVp/D0FAM8XE09MR1446kDdUDiVnkyGqQ5R7g1jQ4OKCz3adib9DHXL5nYylIHNBpL/eHT8KjzpAyG
# DATA Yyi0uHBEOsgnZR5veDM8dRugiMnuYdT9CGuYirmDoYarD9ZQuhRUhzwV/7sfAQ7ANV53PRkwC/NoKhSy8jzVea1YEdxnWJjU/loG
# DATA S2O+0Ull9NE7C9XFYrHSRViBQtEpIX7iuH9RoZBooOu3kMlzWK5+IHgbcCnxYHGJQikn0/Y4mvRH4AcWLi3EYshphyvMeFMulrjG
# DATA zYSlgKsdfbTtq09liHbCBYaWJbnOFNutu8bHgds3fixd/RlAQOWlttQmZD213niq3hC9OFVvQZcg9wsslvaW4yFwBbprrmyRpqy1
# DATA NpKOCpJi9sWipoqJARrmYRk3ZTEBelhdEtLJuD+Mwhz8QLIVnJh7m2v1uw/vQeEjMXN9uLJNu+PaQogTKFlB+O2F6reR1y0v36yK
# DATA /xkf5497YyRgGcrlYzV6htCZqeoLqapORkqcLEP8ZnUe/quf0aRU51kFbLld03TJLtAk6ZokRZj14LPTWeyY5KiylKPEPcHV7L8a
# DATA vzGHcdmOsVVEASkkicRBF3Dd15Pr4hle0cJaoA+nl8CXSXVlM5VpmXrQVJV/DuVpb7YyQd7LbLWmVweV2xx26obkECSmjYXGMMWY
# DATA FLzKh/wkRjQcmY22sjI5OIbduoW/FCRmG+gK2m2xeu120XizIui73eFXCqEKzQaaJbjgWjNUqvSyxi8mdBH0Sw8Jg2bK9x1WYmjT
# DATA y/EkUiy5fDwZ8C98ESgDojYeXiBRqWNbOQLiLUXQC+Me4CWyzNGWyLyO46gMfEd/o5pILHKD9eUp6AMbaGXMTLkM5CtKQ/hobQu1
# DATA X9JzwxAsTe9w2/MlRGEeIe9SM8VaU2TPhx6xHGv/yM6fSVU9wTrZoEKDI9uJiVLgHyBIoNpnFhLXozUfy+I/UDrWUEmY2t5GAfBS
# DATA iguPgO5WveOjcVzwImNjvaTcwI8GEDd+N/lkNIwFebU7cbffZ2xkFuMHWT2MQkvni/Z2LEz6NbEC6MOkn5NHKUb9XtI9x4RLNe1X
# DATA tcDpQclWdIETISqt3P4U1VqoVx3jnZ56iXA+a4r5qoCflXGOXkr19vMMasZa4LbOoA6JXKV6e5EFd3lGRnsu6rA7S4aqjeab9SIX
# DATA 6JXBtjI6ZADdun2BhxdvWHNIE3nD7zqdcxb4m0GYmf2Q3N0dvVRbn69VY9Og/tXtiuGEq7RYxkSCsiPEq6qH/lk+hyKhbpwC9A2N
# DATA ePZw5aFopPxlXX9iYdHbsJd3I2Y3qw/gqiP6gtUiu+nzM6JZXbFO/AT6u/LiTelWMX2fPP0oOmEHIgzGskLGvIdt8fQCe0cfz0nE
# DATA n4RJIjkKNZ3SOtFcaGU3aIgAaddKg9ylw/dVrJYWv9yhajietHWSNZtGcgkNlU1yGixKiLqiY220GLXb2KV2G/Zhu809gjWO+wfD
# DATA Y0QELMDHzqCyvX5vp954UAr09/cebpkZ0uk5/VOgCkoB5xC53hY3sROtZkm6vpDsPXdhv08SF7ZPID99HVrRXpygXBk9isaTaL//
# DATA JMP108aYtfLLKjS+XBkdPd0TV+EYU3m7MMXpUo3o0dm/Bmd/fPmTs8/Ofnf2lfjv58HLj19+Ih48F19fvPzvZ58F8PzlJ6LY2ddn
# DATA vz374uzLl798+Q+iKPz+z8HZF/DLc3z5y7MXleDsf4syz0V1L15+Am8/P/st1P/yY6tcAP8PDb84+/TsuSj51cufQ+N/L4p8fvZl
# DATA sLK1XhZPvxZ1QUvP70C/fvryn6Ai8fxT8fmX4ttz0QOnw8+xw6L+s9+f/QFfxgoq7i2b1Lcrq6v17e32uyvr93lCfiXq+lp06jPx
# DATA 7xdQW65xc6N/xJc/F+Wp0cCs7uUvcEbe29nZ2i7reSkFovjXOIqfiiq/4s+/EM/ptY9Fg7/0z95zmL3AnChnOl7+XA7gj+Lrx6IU
# DATA LNG/iYmjYtDZL1T3rTl7+fPEnGHESftdMVftBxCUchdsRevvr+zUcer+T8ri4QBFv38HX+WyfwUzIB4C5T2H8ZKBBQcHncBHxiAX
# DATA bi8siK7/L1mtnHH8/lx0XIw40WFpi9Qdx446JPr12a9f/lysLdHgecgywO7hpOFk/oF79Wsc72fi4+Lt4Pv9u6kd02kxPf1K2zq/
# DATA Fh9+D/38qSj3ooS/YvNfAmG+kN+f8zQiAVYDUG3H1Xl2N4yedI7GA3QETHQOKZS7ZjGL/0EtiF4JUv0NEI/dM2zsMzGbP8WGPxaF
# DATA sS6xbvzql7xcX778BVC6WwHS6B9xJL84+72o5nOcic7xdGT28jSdKUs2iN5TmkML+eHs30XNsEzPBZd4kWAcnp3Ci/l7pEDYif+Y
# DATA sa3Fx38Jzn4n1uQnSNtf4kp8IUp9Jcjnxdlv8Bdq+5fAzkRdX+DySioTXO3nokrRBfhV/CaI8pMKHBrf+gv+mw6EKHHyattYEH+3
# DATA l5fxX/Hn/Lu0tLx4Wz7j528vLt3+VrDwTUzAMWiwRJPf+v/z79q1a6vRZEqhuFHAbj4gzHJeUW0+JhVd9DhoSFuWdJWiQAMM2u0f
# DATA 4bVQKlXld6qIVGLyGVxD5OdRPIeROGAUGfT3An4MMrosMlGVaclMPTlRHwUnGoOYPkcVspApK6QrackyDbXpYVwK8GLAumIhUQ/j
# DATA eFC4DvJ1CUEuOSxzv9MfwPWHeV0tFAf6Z8BqBMv4CbIVyVK26kKeBgYmWNeLl3/PTAs4HrMcFmvgzEX++zUUFAcMST6WKPQCeZZo
# DATA 4hOoSpT6Ak/I56GLTG7IrWLwhWbIIwFPPhgLJPKD1Fg1GJK483TGUxjN6HgKD8lmp1CNbxmOI4gjTer17qiXlUXMmSEPknKFMI6k
# DATA O6CmwPa4058UDkfxlOEc9E8lSh5jLl1cC5VHHfkvyTfZbCHeBu+u/iOKscE7n1FlkbUeomIDMR2vRdardow1uIF1ES9PHHBjAq7C
# DATA 7+HucHeyuxDO1HSS3I/yAxAJn3RSTBMnc4AyEchgIJWyFCaOcBS7X7z8GRADyGmf4iuCSpJ5hscGkgCMKhkCvriwtBxcx39mdvg/
# DATA krTHJyxTsOo8nOSy82JsZSm9oUD0wpTQxNH9jyCjBQ/6d1Wqt4a4eKMvURCPXHYESx/93TE4mIB7NTihHseMWSpRbMGEADRUUQTQ
# DATA JkIXa4yfwA9SPKUb/t4J6M2LaqGtpxQOwnwgfHJr4Tto0xqOwFMAPqF3QzREy8S3by+jiwoyCtWsHNWmqGV7+76M14iDHmYsQkzL
# DATA fowx6eBtM2Xc9Dtim4C2RSzk8MfRZCRR7Sk8g8vTjlUJi/bC3iiKKb7d3DahdCWcORLYO+Kb3nz2WLLRRXx/SU7pJSMQvH4LbBGo
# DATA yBFxfwN7AWiLLkbPs50fr6J+xQdgHnCXe86KgsWF9JyhScH6TYa92maTq1yry6/TOdbKvkrCdQIEZbquwY3xUziljBkV3EA8eY43
# DATA iecJET8Hp/xGesEJhUiWiAdEAiA+gF3Nkh/4Ox2RP5Z2ojcDWCcZhh8He6PpYdDYXsENW19d2165Iw4oTpFyBE52+OvRqHc86CNm
# DATA isGuxsd7g34XEG0TRCB+EmzMogcfv2Fm5qlpLF8XP0l6Gncg1QVZUeO4KuuU/FK77Bqde6PmNJK5K3+VuNLrcwOOA7EMXwvZ5xMU
# DATA dj6RKibUe/mEnpc/lZ6MYPX0TpTeLWig7pGx3ZmrSi8CQaaQSGUj6qpgMVjk9nTUjkXBYS8uYIMyOVSNkkMttiD1oCSMynD0uCBp
# DATA o3I87RYr8E304mhcmMG7UN77IkD11ec0C3xT9gl+cOX9J7j0fkVawucv/wFv9uLab2fB8ZyBKgxjfDJb4DIMSGmylz5WLybG8XJG
# DATA YBGSGBJOWMR8CHXECg/HKJwbwefsf9LUocj0G+xU7MheyFGU7GUIWUpjIib4Y0HDX6Jy4fMw0XWPV63Pj9Z4IeFJC3MGdF0IIUdS
# DATA 91CcOJVxdERmmP4jSNgIX1lAGfR0PiLTiwJrMYwQlIdQtjoPP1vQG+fKU3v2f1Fn9Bkerp9Zgh4IgLY8a4qE7pyK1/+Alxs1qygn
# DATA GvKsGKBEyB5b8hn1Ohl367E+2PhwIECKCfqx2PM4ScQZnDF3pqOjfpfbcidO1WOZFNiKkL9ZMTQ3cDNrlQzEOqwrTok7G8tQMM5i
# DATA ZJNeejBmYthjZ5xuHJddGF17ZHmZDEcmviRUOUiKwxd0sU9AbTiGPV7D+DVyPkcY2v3+k1pYmQ7icuhZTYTLHcWV/R5w/oLZSPh4
# DATA L0T7jGDpUefIzZoEz9j+lxiYUWJ/cBwfOoF00F58MuwWZBkxhuGoYMRDj2Ll1U6LjmHitC8h1m9gDAG5G0qMqWvFPFrBpsWFo2h6
# DATA OOqVGEnAQWAzU1RTASs+S2aiNm6E8CR5Kbx989vLnp+BnwX/JVgYLbz9dhaPXdvYNvtcFbxAHOW/UzYD4+oH3HR9Y10xjgBV7dLk
# DATA gGzhtrhTOZhTpiqpQlgl7LGnIaUkhpb5KrEOOOmHB4Ww2RvGrd1heAOHaTg5yPWKBpiRGJIgKO9P8Y5ydYsmR/0pBa8XnsIv7e5g
# DATA dNzbH3TAMj7uk/E4xJB7Wjcy5qtCnPCF3j3ojug1fkstXcqrMgUA9ZMSDridiI44yY2ncyAGGokIzNEY1Sp5yGgJJD9V2ki2/Ai9
# DATA OsSMAovjLxP+ovI3UCUVStg+Ixzq7F+BOJT9k6hIHBcvf0YC/JdoL8Xz59dsR/iKL3SCBstKffacDIJQJHSQwUy4NzlWBrjJLVL8
# DATA G5L0Z2e/F42B4edjbcf6KR54xmaw2md2d5EgHIvtUm0Q5Fr50ag/LOyHTz86BTP0I/BzJ4+OkjX9MrtDBWH1MPcq8xrw2TakNqSg
# DATA UiDZTg5B0KeEs6kYjEm2DyG2YoRQGokhJ6EBDVi5sVtu3fieflIxwQNbT5dKkDgSa5stvqSpbGnTaJ5+KDgDugmHHGJAvQ1v4L83
# DATA QowmQKqXAzHThOJqD2KNDmmfubryRHH5cf5RZzI/6O/pVLDz4vG8JRemFTJkRZknRnFRavqGXKkbGEIR3hCv3QiTkRR2IJaRd8bV
# DATA dhhjEzXHpI7Orz1xXK2CGzVkKTeAixF1Y7XFvN0tz0ycY/gCmXcNM8xEepfTHoHb3ESmehEbAWvXKdo8JKzzaHS6R1G5ScTbairE
# DATA SwDb4Qpn8xqHaAXXQc+BP8A98RNkdn+wmB33icQC6mwyQltrtLFEpkb7HJtJ8UA04v4Wr6gvgpXVB3Wl7o3RdiwOs3HUFRdESGSP
# DATA OpMnUXcbk5r83fEI3AQD0Jn00GWwOyXdTHwYDQbyd9KfCEGwM6ZTDAeiowx3d4GGdsVfaMQeXqOH18xnb8Gzt97iHhr0QcmJuMP8
# DATA b1icl7RwI5RheHaCzLD5cNifClljzQgoaES2IW3n/rZ5R94druwLWabGMVPlEYiIETuqBRxwzK3tDj/owGnhLYu8yeoMR7aI/uyA
# DATA P74QkuLDkSj38EEn/qi2IKS73aGa/do1wehoTm+E13ZBScQH1e3l5QtMEG6eXNMjJ8aYFLGvxKR1BjCm5g7UJN7aHK52hBze60xq
# DATA 18vi/4KFm6XFW9WFhSrwKWvoDUFY4tz8cdRbiwadk+2oW7t5G0ptgVI+hstAbSrOWKx/nSybLZrdqHf3pIadj9XEOnPhiTC5UHBJ
# DATA rrgSicZAASFjVOmZcoaCCsAwBkAIIfXe9FBFO06kJGu4fDaNiAhTKy2+st7QcgmlUx3jQSjTlxVtETPYngq+go84aDPXwTgZTHFD
# DATA WeOSP0qZlsMPazKzbrKkxfmPJzgp7lugtBr7IzQcr0414YY3sKvt6lSkdblTsfRdnQpqvDp2LDT0yXQlTXj9jk8s32OpqpvdjOnx
# DATA fb42DRIymjZuoJ2KFAZFzXwL7VRMEdpfsRPgSYKmORIWNc36LzwMIu+qlZgV5k0d2uIjnYQ+f1uGYzSgjclTuELAhMm7YgrJ8L6z
# DATA JdE3g+9H0RgtlRIBKJBHMd64IafzsDs4BrTrADwz9kbTMA4GEM/PF5K4ksyS3QynAxmLyduyakymtZspZpIHZRrDK1ooKPKWt8rC
# DATA vjTL2OkS6SDgabJgHP3KJhJ0jSS800HsyefN8gv4KRHkmTESlF2sX6HPPpQkr8xC5oWvX/6Mro8v/4UcM/CCicZ5uGCKk9lJAUPe
# DATA 3KLJptWZVvGO+RP0pJXDG3uGk7TfSxmO7oTDsqUYuZATM1jff0SQH5jAk1VkJJKJlx/14bpi8AOdck5ieETBYHRQcTzfw7N/Nxxb
# DATA xIxWxQXKcA9EUDudezJyE6Ozbjc0XWLY7w9dbNY31kvaoUL8P5vbIfAVBlIzUmml+y4u/mV7+qW4v+0/bh8cdya9V+gFmO3/t7h0
# DATA 6/aS7f+3uHBzceG1/9835P+3E4FtuzPpDwAyIQZDC+SNZCSfh+9+IKRYzKbKx1GJ9O/9ISUdBUvEhBIMn2S5AO53h9PBOfz94sPj
# DATA aV+9QGEn5/MA5O+A/iMVXOiwQ4FSM/zmyO3P7x0nDn/HUW75VrbXRTR8VHt6/foornCAoDhf76+2V+6j5/mqofCd6WfXII9G4xwD
# DATA H7HfklXz5cdw29aBBC+kzQ2jGsR//xkeilfEst4JPPx0XwhdjwHp6exT8JFBt/yfvvxlONOHT8xZ2zgOZT4ICeJ32EczpTHJW2i7
# DATA sfCpbKxctl7Dm5XHHcGg5WTfWl7IA0lJb05BWT2EHhXTIfk9jSwuJIDqjc7vUKn6k7GN96Yr+6g/GLhQjLqVLHOabUijW6ZWMEk7
# DATA Tqp2Okkf2fppMMWi9fUT1KEDOXyp4mwEmWgL9yUseeKY8VrywKhG5m+zfhxxPmvfX5axbxLtjUbTtmSnBTFtJVaRdafieiQ2mZBo
# DATA RpD+vcYql4TqtwxzLWsACeh42J/WUhU0iRcRYVWrsjTlUbtXQntfWH4YOSmQ28/lXnHUmXyEmnV6icBTCHMiZM3jDuLNiekuo4PX
# DATA j0Z7YoOLQQO63Xj0WLw0GMUxTN+g/1EkFZXiLjaddIZxH449vFi6mkcxi5dXOzIngKUrpanIcKFwEzqnt+iGmDWpQ4T+KFWhlbMd
# DATA Mj30+pSVc3pYRz+KmkyQQTNYpLRGu8NUvaFdo6k5BFg2nhVRybWAc6aKs7CzN4gMLePWKJ7W5o/jyfxefzg/OQrK+0GiG1YzaSo6
# DATA BFYqH8MFyFDTGdpK9Ig3NlRIKbQF2cNVX6rEEqWoyyHtpQrmubbWiXoJiRdQaJKtSn8ePsooVrbKxDmDFaBQHvXkAVkKKPZXdI3D
# DATA ECIxfeIezt8eH/a7hzWSmSr4pSSlMjNxlHidsPkw+xBJQ3yUYm3iR/kJYAztM52Qdvcfi0LYQiEUX2wzg3iQOMG5QvuoZ4fmGs01
# DATA 8jkJONNK+uPhDxV05YvhOKBUHscx5JWmKbcsFBntcj8zavTU5+Nt/+ETqdjx6WsO6v0t+0gJnnZHSs9GVNsfKaT27CueQ2kLUdPL
# DATA D8pijqwigijdQuKRvRKyMtaQqFIzhsWBgg7Xlo7Sn+KwSLRUD8Fx043PpblQjh/JgfT6cWdy1Ab+Cx4UTKpIdPYZWPQdggz6LDZj
# DATA gJo2z9HnRf9k1r8ieIysX6YSA9kCdG6gwpBCcCVYCUCOExxM4oxOALcU/XhBVTEI+uyAb7CMngsa2x0NBoxTVC7jaYx9I95eLgv2
# DATA QzRXQ2RFzejEb3jCQGKOsaCek9pKt3s86XTRdrEI2jLaODobteRUraI3+YTcacYLsBDGG7P2T0K2MTSa2Flx7zsS8/X4MBoyXDsH
# DATA j3X6A0Nz6e+M3XvTpJrBJXLu4jSS19sW3cLZC/knYvO+gCjST23aPvvsTkD+SejT/Lm0wKaKMMgP+Af58GuoAsyk4BSNHpAWnKva
# DATA GYWiPV/mkcQQXLgHAOhN2XReOdRZTkAv77tMSyHcIcQFu6Z61KgDUPRavZELQ4uroSHFFf7aXKy2FKSTfFZdbIHaFXDqwxbpEc3f
# DATA TZYpa2WWScFiXM1CyzGbzxJ9tdPb87Nfo4M7UFHSMv6F0vIXE2584bxYdkdABx+CymDU/ShxLwNHeEQCGfINUnzbbK826is7wTP6
# DATA 0lj7oCE/b2y+u3n//uYHlqRC+PdCbJwcjwFRRsJ87E/g9uI4tiLavIMhsr6xY0KIZEOKJGFFJJC+fqO9fm/DVdp+PzrZGwnxaF32
# DATA tFDMRjY5V6/8QCfGrLDhe/a1FJbJmDNQgInbpnhYgP+U+Angk7TrP8jQTCdkQY3rdXkLQ2IyMzBXQiXEoIAj/ofhrHfS+d/XCCrw
# DATA 8mcYcUO80q+NCm2zh7mdDMPH+ewZGZgxfpOD2aoyOpi2Cwzm/SdUq/08VYfmGaCUKMI/NRsDpXopdw7AFfEVmQAy9f+LC7duL990
# DATA 9f9vL7yO//9G/t58Q128IQP1+GR6OBrenLt27dp9Tt0NuXSISqSTWgX2Caf6pjTemCMAUdUgM8BkdHxwiBKhkppzGwYOOzEYBNTX
# DATA o06XLAWAn4J6DDhy6EfQ+wLASQNiguPpe4I1Dq4CXkCIkOozuFpNqdl04wPwDMvagI0dTwaircqEeifb5M6W4Gc4OOZUB4j3GK1o
# DATA hweE+PX+wqjhc5SdGg3qbK9vo6u/kOSMLANzq/fX4caEa4652UnlIiWMcG51c2NHCGL1BkBW7TQ272NxWwwBZepkNAjntuuN99dX
# DATA 6/YdjLHekGKUGnHu4cb6TruxubmjZRufs9jc1sMGJMGAVJ4pdZYfLYqWd1bu1bcxRAq1GJwfpTd6PERFDkZKUZpGRnOlvBEhJ8c8
# DATA 4RfAmaM/FEvJ2K/9fflLV5DzULxQnHuw8oP2/c177bsf7mCTRti8UttSEqbJ6EDMdcz5ZSZypQVBARQh4sGXguiRDo8Ru2ILwifj
# DATA w2APTGxiH4l5GFOZuMT5MaRcKsXoGK/JnccBk6GMBIc9Rvc3orgaKDXbfciZiA9YGUVXbjtFhZWJFD1cYPso4Gle8XlWmxgJ+Vg7
# DATA wy4coj2ZxVp2QuofdKE0hY1R30EkA6F5oSGLPcyJTovDWaho1QmOHa6YUS+puXmIdJPMj3OvUd/etsVuZ8CUZUSuK6oU5LicrJXD
# DATA EajFMAIU/lPw3L9lNdYMa6sBSz4AIL4xmr4L5OBEkxkVPA1xltA/h3JT4L+oTo16KwCVLXoEN2qkJAAkR6xxhnKJDUR2sU8e9Ueo
# DATA i5MNNLn2lkIvgJcEsxBbKsJELsCDBKHGUhsC+Hvk1SQIFsyH2hcKNt5jIV/GCqmA1rQCBuQnBWwJImitp7JTxeTom8YoWk1ZEFyf
# DATA jjpPCgslXIqyOxY9M61iosoKcRbqS41n1H6tJmrlVPCwjXENwSkNQhR2nywslHefLO7vPnl7X3z4zn6Lk45h2aK4gy4ttObsQfDC
# DATA QL8Lnqc3gubTsKPXEWsCNHpiIlRQfMd/T1vFZnlpueq2wXn8YNCiGVHRnC/3HWYF5Hd8Pq1Ui8vdyL+r6jCcJC+wHeOxXEJT60+W
# DATA 6t0vszeow/OMjWrfMNSdwvSwkt5UxfQ++nc6kq147lCxs5+U9mI8iDjaSk/Y+BDRxtn7k4uEPMFwylOKa9URm/UmuWrCyg2g/eAb
# DATA nsni+ZAVQxPNxW7uVdQRyO0HhzRXaW1K138PIE+JqQvOrd/G27p8TPPWxHmrtryJDvUUoDtKgbd7fHxUUJU2scJWZt2CORRm8ohi
# DATA MlknOmeoTtSCharX5cNdK86lNUCTIlhelM9crx+PB52ToIMRdR1IcRBcWwgYbOBaxfU/yCZZwyswkQxWiKoGKevDI0Gg8iBZh7mC
# DATA zEdI1jeCRfnDqph64DuDaFigefUlwkDS3Z5iYgqrLKd+Y/LHCzY24SZGiiZd4m+LCwued4gAqHPXscy82Yrbpdg4Fo0tox9TFgvJ
# DATA LKt+FupUGg064xgyheBqiZcsqiwY7ewLcogPqSGShx4DEXp7gsdXMTECiAg/go40JHUZ7cpH5nGfPFJOBTvvDgQpWPKQ4WQplcWC
# DATA WIjxS4SPweiAmT57OvCZC1lHIdmPJ6el5CqYOSKZVTFvdOX6EB3vFYKXqE7XkiOd2fkSmLEMaGZtUeH3+z2/evWDxubG/Q+lTtVS
# DATA ttZ/sHo/U9maQChQohjwyWSeyarLWFV5CMqFzsMtwYo+c5dKL16F4Ipk2KV6bKXoJL9f/QsFj3sAB2QZKwVtGiqCmJHuAJIA7/dc
# DATA PyiDS2nV6n6P4/qTdNlG6i7QBYjvVhDnMdVBoHw5ImmnEDZBRqDMdNPJPp7g4Vsflt86Kr/V23nrvepbD6pvbf/XkFz7KgdHdMaj
# DATA GNFCrwS6h0DSKfhGTZGXRKgiasPj6X752xCNCiOPayG7eUgZhPskPY+Sw2I0Jqa0yNifNtHkosqVra36xppLiqkOVmq6QaNKPa26
# DATA DvAp8x8ykjPZhiQ8t1JOQzoq5dlBPxbz1ixu4BAmCYh7cGXKpjCDiVHmNolulWBlclukTjFOTionZAb4zc4UbxD4yeKzzK+yp8YU
# DATA Z2mGpNLEGB26u2mLzxVxduseDhqVhxsr74tpWLl7vx6msmDZl+TSzDJ9NdbMXSDpXn/fQGj4fI6GEwkrgkFP9iofCR7AEEjoNwiY
# DATA GVTO4zfoOKFUttvr2436vYKsRGJtpEax5JhFfQM4HnY7dNEw62eoD0uxZRvlqPdxFH0kBZrE+2X7fWeIoJ6qyXrgtlGwS3toNNWA
# DATA kz1iCgbGFxWGgxy3WRP0R/wXjMlTdHor7CHPbi7RhUWVaFah2ERIbT0uAgIwFQLXb66HwcPSWX1Gb6Jhj28yMMmQr7UwCcvwB4wa
# DATA EA2C1nXGdg++X/8QfwrJ81zP81500B8OUyq6W7+3vpG7KkAvoD7BkY+AHrp2UL7hj+RpIeSC7+pf5TOHXnmiwmajvrayulNfC4w+
# DATA tPAMFiWaXC9gOxVZfSGuP4JHxRrTytrz/KsEhEreYy2DFt1em5QORF6/z6sAUNcnM3txLXgqW6TclyXFGTmzqfzqyVjHYg4l8zN4
# DATA qnwkL/2gVYamMAWh/LFyMBjtFcLrUqnRrN5eBn0RFlKlvC3HQkJJvH1zSUOHUZMgfnLjGdoEBHGxVQn4ToLVGWZWfIeuPIYYj8e6
# DATA h98Z8w1uJGTWwCqaxuutYvHKL8r7Vm56QxrvR1lT4j2QfCmHL3Q8XeaISjt1Us+rjGOI8Tmm/eFxNOcJdDGSQKfz/5zs07wdEVoq
# DATA 0mYFmDPciwS3++FufL3wTjV6Asax3fhG8Z0CQ8K0WwZ6TOt6URSsQeHK9eJf2XmfwVhTeVCs+nU+mrMS93kGdPJYkPoz5CvPWMp7
# DATA pgMjnwHG0jsfRSfP4MgEJRnELD+LO4Pps16M0AEwmOZiC1teT5llucWo8FLL8HjDJNe713bDsOh9VXQcFCJYQzH461qwXE0NUHJ4
# DATA Kr3j7qmEIJnYMFQNooiMQJtReEr9R/Qn/AQ/MXf38AViA3gAOV0/RczI2gDy2zPSC93ojb1I5w38o3zqqa2ScQi1ZAwKH+NShV94
# DATA p39ULHSOp4dii/8YVYmCUJrVWouIa08QQDR5Jhay3y0Cje1uAybNJNxdNOo2D1W3hZDbEJU1rwme9c7unkWc4vl2fbVR33m2tbK9
# DATA /cFmY+0ZZk15xsdm+x1xbj4TBdbqGzvrK/efrWyt07OVhzvvbTbW/+sKZBcqupVyY2owxeYPdye7w9aNMDzfAGYLFc3deHe7df0d
# DATA 0eosUebZXxXDUqpwkNWN3b3o5G+MQZoQUGnf90KbBrLqLwAsj3i9xf+KOm5Uyq3r1fl5mLp4/nvV1o0qfWrd+F5iDr+X3fsni3u7
# DATA zeZC+Z3W9WZQnhf//V75v0lrUeI9CenVPexMOl0IsEZgHvVN7CcsCQpS8yHER0xDkNsEk9Jv42a6uRSQj6P1wxu1YHHp7SyRVQl0
# DATA a3xdDDj1ZUxR3514SkjulWDnMFIKW0t1R5pK8BwhrHZ0q6gADB/Lg7aWWt78xFVYfqQEuFPSDcMbADkiOwuP5OdTvtwOALF32laO
# DATA KG32UyloC3yDjODB0fEUvI+D+/gKYtCXoJ9DwY6m2GHwniAnAfG1MyXg+WDaOTBM7+NR3Oerso72JJGnUX+wsbIKmZsa9a3N7fWd
# DATA zcaHlF53Oj3qDOcV6k1Zdde1n6Viowk6n3e+A22q7uQzijfq9+sr23UV7SnNeuy0UtCKp1DmMxInXeVASCXHe+BSO48tzj/VDZ/O
# DATA S8+geVqLd5RbRxtdN2pPXS/9U8MJnnDK4trTcKUL5xCoRcCBAwJSAB/10bDHzd9AibYECdBFveVVNhBWQSAvd+FZ6InRDR8KKiyv
# DATA HHB6ab0E5j0iPKU3DcdP9t4pKCcPI2UGCGGTKB6PhnGUuIHyc5KJlm7dZk8SuGKqtYbjTxQHq7gucaEFxJm30UygYpOojGNYpagF
# DATA 1MuLUIzYCjhGrIZRPToHqNTSlFxwWhUl+OhnXxGHzB/t9gRPl/8BPtk5cKI1J3abvUlnH2wt/RjrwwyViUJjcaLLDM9WyYsMnPM6
# DATA wFjAC90K++JnzJBkSRJvqikrYQpE/lmxJkUcufhv8R0xPWbNMwbxfr2xLaQGpXyb4L17eixYd+GoMwZEVa5Pgp5DQiyNkjQ8KcBL
# DATA QKeLy28vf/vm7eW3yZIBT8VJhFVepC88d9SlG0FhoVQU+6CwHJRxd1C9OmzWcqepZlps/Ncur083asInKYDCrPHjAGHczoCde8va
# DATA xYgrLVF1c03D9g7k82OqYvnf2L0WIr+faPJvXrMtnnCsg6eVPSnORamglEZ+/vDh+hq/iuIFfsy5s/72YX17J71fsXg0Nt1Q2jJi
# DATA /kicOvIb54pVUMDVGd5v7ADhcQKbM3C3xXfbRCbGnKV7yq8Qf7ixvfJuvb21svNeaPUon11TFk5YNZNefXrOFCXpyTKgWekZao9d
# DATA NCxdPh0QyyASVVUJ1VSuJdNoSH1uLrQcpR8Fi6JZzsyyrd4oEl9f2dpq01UKxWofxhd4OtcCGgnDZ5n6JKWoscZmhFCAHsJWuf5Q
# DATA t1qDK8Q+IHw+vb18KjUNrGFIDkkqAhAml/IAGQCyzEaoNOhdby5lEtGD9e3t9Y17cgL4VAYtBWC+HnW6lWH0mKtT8L+lgL1uS9L9
# DATA uhIfdoTkgdJYr38Aol/R4zuWTvclIb6T0rVKzZ86KN6yIqCpgrlxi4k8BrxChtQXmwiC7GKskMGbEnAQ3AMxVFuvHDivIOoYO7IL
# DATA TsKYgIXw0WhwfBSBI3DTchFU3pFNfJ1UUfgJkjdRjf19r3KlYGwBLMnMmfI4wQMpIyFoIrp+JRywgcXkrV0pUJJu3LKz8iCvhkUh
# DATA lSy1ii1D06O2oVi9kzFcvMK9/tCEeCRAOGY2RQ34WE02ye7VbYgTEL8Dqzqd83kvmF4GcFQ0ZUdavuhNi965qfaDzYcbO9Dwu/fX
# DATA V3c8ydC4esdwh6sn9V6yVR+l20eLRAQ2GpBTgnp300ta5adIy0Oe8iLsIPbpq5JcCj7t6CIoVqXfQzgCdrKsojn3vHmfeOk477as
# DATA JAhRE8tfT5OArwC4G/XafJAaueSlPbqYimrBAduFGZivoCQQV3wgbEj5GxSIv6DeQLp1SnQLFwvXAaRIAt7GfVBMmBi3KgCGg1+C
# DATA 8l00vRtDo+gK37jQEYQiYvElc3bgJ9RxJDoF4B3Q9GhYZs+E3SE/Q1haG443P9aFj3R15MV8wAEbJQ4+d5c2kTpSYwskoTJKhB9h
# DATA iCDZrysMjbBcHo4eiw/cm3PXNKGZSq1BXgoQIEVIsKCTn56wwGhILoYGCABwAfNsABzrROU9FbwQD7U7ku4gprPTC6aAHUPHatQR
# DATA RzZOt9IBpYqYKvFA+sGZkYbAEjWlbHopAVNia1JbHkal4zK09GiCvWYKZvIZz7g4ByJTbswS17hjN5eC79ZsAagWLC9857bCLD/U
# DATA NgXWjRKO8e4EIXZQHwTu+WGr+CckN8mUDUkZSflookaqqmKy2+2+2LHttujCYJ9sy2bEsnhYSSc7VURfcfQb5j1HNYciF7aVdIQ3
# DATA 7hFmne65Z1TWeRRxvxOqCWtasurjd534BB2yTvrSXrLPaNCuub12Le6clt3xdu/L0C6GngUhALy0KcKJDf+BsptTKcFaZW/88BMW
# DATA 4W1s7rTXN8RF/D54g+mmpZqIam6G/N0D05EooacFHLqYYKSaEtwAzPvw7HgxhTsHzvS+jFPygokTS5ST8AHIjBG7Ak8naR8I5LJI
# DATA /a0bsiWmJMwAJU7qN8YcDJSiiAvVZW9pGdKPQPF8rlt+dYc7qam7rRBCUzg+XBo3zMU/+TwVr3oBnI5lrwLTseWGqDap4Yuo6Rp9
# DATA WZJbXQN5OpGzlQEmjjCqLVp+15AQhxwLoArHkcl18oA/AIvLtzZQdVOI6xjS5V8hXiVRpx0HhGGOYs6OI7yAyYBHuuAZ8UdBWb9r
# DATA BhIsgOLx7aWFlDgVeIfj3rDFmoyfZF+MmqDQnXqj8XBrx+JMqss4MlELwY4LCaqq+gFI4WZiAZPwxFDMpAY8XHXvQHvYAahmQgdg
# DATA fHaApL9rKmDKMi6OOTiF1vzUOK6S4dXMRLuHnWGSe6LOGAkAkT3IhAAK406XMHG8HEb+iDpTg3GmBXNlyXVba+AgcPfh9ocJ/88T
# DATA XyAVeQ8nh1kBxMtDIb71fxyZO5DGXfQthq+WNfwnzaUzfSCGqzP5dJKPsrnp2+RsSMtBnFnRkjrkznuy6VBVFVws7xcSZcm4cgiZ
# DATA /WDS6UU5zvZ0Do8Mx8upxNBQCWHOPw1USBSjx+1eP0bcMgtqKTEQCCGU/UR2AQ0SaR11hqK6Htm8kFhnjmNr5V69/WD9XgNdTHA4
# DATA 6w2LJ6TuAfiasgPop1dK/+xNnvvknL15DHWgL4Y7JT4nefbWMs5e78uaZeLBrb6me3WdW+RwGIRsf/bALnBg2RU4p9Z3M06tc61/
# DATA /hNDObK58hcdFBBQR2H2eh2qJusxFreqhW2tr9OzYsYiGnPi6t3sPemJ2Hbya6RSbIoqhbAYM5EKWadWRpg3AAM0AAxNaI4DS8r2
# DATA ayHFewrEUKu2qEL1A6MvPeg8ASUY0AAUcNVz+NJdUP6gUi61PQapg1NFi30llk4hU1Y04fbhQb8XSkYrHoHooM4TS7tkOXr4iK1w
# DATA Qawqi/BmCGbiutjYaasIIpaXaslQpzm/u6c6WXKK6p6Ck7DMN59y6+nN26e7XNAX1XUOEk7Z4taAnUATGQwFALW2sACLbMkKFxQQ
# DATA rvxGeC7WfOFDzDmUi9UZF8zkMZbn7khG/wSIAehHmOmliaDWY3APdNRSMqatkJNKi26F7e4k4ugnlEhmM0uKzkMkFB3wZ+wXyG3D
# DATA boj5NkSSuu1+AUvxs4Cmuga1GNVJfC96BJLUCEPcNHLv1szp0yeXgvs2ltAQNYr+a98Vi65q9rX8KudA96Xlk0OuROK9lOR75feI
# DATA S4lvvsNDiWGX4cnkGOWJcFVp4wmwtbl6f12PLZl+lU5cqapEXBvwCQ1bGauJ/hBcMa1lWr24J03lgvrc8p+Ejmx0nZK++GWCE3Ao
# DATA gAnq9Yc14821+vsbD+/fx19ALpD7j/JNqa8+EeLtxYUFvwyesa1XNx9s3a/v4Mlvb+189KChZaQ8oTOlnzOO6mISTn/fZIJ+cuIA
# DATA eYIJmD1FMlxefJYiyIUEK9zvm1t13u9egYM5kwHq0fLgAeXYY5a15Tihz8xUq/uxfzwXrRSQEdQN3l5wE9dgPoA2aTd5nKSut/dP
# DATA Eng9oXNnccquxJ6aDiY1rM0w9vZjRke3LyvQhZbeSbeKRsYkBOfxKt2gxSTBAT5PT4hBAd0KNEDPIOqIHgKc2d5k9DiG5MSstQDo
# DATA GaCAaTQ4qfi5ZZo6JPXCn/5jLitLuuBmkYfHEiOmy1j6aqYbibWLGLaevVNyaJFBmy+3Tc0g1GJ2mzhktCLap1Myj9PxZMKRh/CO
# DATA NgueM0S0mFatV5d8/TrnvAw7j8Tg0c2hql5i13J2rlFd0m43XDB5kVW4ZqKQC8JmyFg0Kaem2a8r7z2QbMoNlSMD8/0EtZGdGRM5
# DATA ttuF/nAY+YJy8TnGiTLcAblKS0dr14bLOKAIWF5KgpBbgDkuSA5M6A2P3OIV3V2Ebd1PB2dbtFZATCmYGxIujN837hYztWJegV3m
# DATA IYOGhai1vpmiZbLnL/N0s6bZojpPp5K3G17LJ+gzgHWVguttf4CrburcPeb27+P90jrQlJZe+jok7970Sxtd+UvGTVzHUqCjSSn1
# DATA an5xrXOK2mUWe/Ubsmfpci0NxaX0mRe0tGd1MLVzs9AFLzQA5dhEqw7uPHK1XYadrylwn9iof1BvOA29GWwOI4Wpi4LGj0ZioJ0B
# DATA 8OP4eH+/3+2jYxfE9ckYRQjRAq0DzEpHXOAO+zGC2iRC0U2gLpPjMbqCwqOUMAvV/DyMid2C6WqCC5SBclmslvEJ195KDQG/PLJX
# DATA NsJXzjtDSr0ZSnfl+UoXJp8iXbq+am2768/KrMc/pgsp4lMlkW9G/Z6m6k6o5P0OMKVUNfxMnf03o5o3tfJ/Kir4XDLuVSrkZzgv
# DATA QcC5VehcavhMAr4q5buhd7+Ixt3VW6ed6Jf2O8uFTZ6hs+4P90c+zTyHlWbBhetIJEIAyl1HfHhOPTf8bpoQfNr1GSRXvBLFOfaC
# DATA teezSfiKFedtv43eUGsSlR1Uc6rjUNOkVew8ZVGPmC+r1bE39qmEbmBA+jVjpv3nN0WpuVmjDRCBzc0djsexuKguwYLY32zetc5J
# DATA E4cAg5jb6xvvbrbfFRuc6wPKLqbGk3gqqG/sND40a0DCdhy4nGWiMx0WSedwmDvX/d/en3YOBoP49MjNXBFnv9KJeyi3z6cvf455
# DATA uT6Gr5YHQ8q9SKYErGXATORSPJNyWwgA0L+yDEt3dOWq8hZGFNYgqjBPyM9MjTXSMqur8bPvrP1OmqpagwxoUyLST0pp9EzvaZiA
# DATA JvECtUH8SEjKHZpe91cO5jlStO5fe18mptHL9FR9PK1yYpunssJTFeIhXuHf/Bv4dHd4TYUApPfDl1XaOJgSAwq+q69C3naL53L1
# DATA kRsTLkiN+srah+F5unKua9kFrmeWgz1TgVoczSrfqOnVu6CjkwnS4Gkd2VQiygaEAvXLrJvRhZt/M7hLWmVoj1LsIi7+UecErluY
# DATA cakTDCPAjR9TlhidZ6kyN1M7q+iZJ7TmpyupopGlJBkoYRerS2eDr4g7/6tmxlaONcgqV4VcnZBn7rOzL1/+IqCTVPaa0sHk47v6
# DATA BrPXEZJVyTi6DCumBHj0c2PTOPhNseVUena3K2wh/7Kfi6AZm6P9YH37wcrO6nvhZVaZEyvBIv/72a+T2VJ/j5lSIZ3eP1IKwXDG
# DATA os68ruUxec4S9Ryza7aQ5686VedD7XqynSSdfrJTERVnVu9mz3HyPxhpdFyHzdnpdLL9C/yWATvRCITEmTmKvL0+TRGXL2DYydRG
# DATA vVIj+JuIksZXD8KQgSDCADXsvWDvhGJMx6P+cFoJtsQkQCBxsIWKlvlhNIVLtqdWVjZAdOqohPcb0UbQHY0hr5lSdPb6nYPhKJ72
# DATA u6DCnI7ofOnKtOgXMtmn2OPbJoR9fjWosR1mmr4uzIsS5E++zdwy4XDoQylXeH0KT/sqlbHJpGVzV0nPCVpGxTUtCgbgb3+4vVN/
# DATA 0N5aWf0+ZEyRnk3iIrj1cCfMGqk3b6qxB1bx5Nmyt8GwRwTgGOnfvpXVEs7/rIytxjElE7byrdersLqQeo8nzg14cxKhX8w/JJcE
# DATA BdcpqXg/6sdiEg5s8J+ESim1tMoBM+w/2Ub8xYKZ47Kyc0gpEQ8e9J+sD0tWAswKvoS8il6V6QEQGKA9xVdjUzkD2kCw9vCOc11c
# DATA xGkwpGjwUtDp9Xi/x8dj0SuMBFEvFj3vAHoL304LtxI2SU/dCj5K9L2AMffcF5oSzh9a8KcVLZp5B4gdHok6RTWs6kyYV61NSIgE
# DATA 48GJjCUTW6CEGGLOW3uj3omNq4GF1I3TY4+Ihr22xBUsQKm0QgSmWAhXCUKzDIAYMiOmBFT0KCk9FVgQiyWEWES0hTBv0/ej4cFU
# DATA StxgzIJxu/6m+Lp+O/aN/jEapknEwDqsKT/ExUujPzMwPpuoTDgALZ4RbkMe5HmfKRphBUA07UyiNqMFYG94tIyPYIISE0SC+M9d
# DATA BCTGmw+2UEy37OK5h5S3vHATBCxp3grf3WzcXV9bq2+EpzlUvPJ2IbORgo/mvfoOedviL6RmhnyxJEeE2fZw3bElwDSjeWNfOH+I
# DATA bI72KR1BDIJPIZwHJTeF9s+n+tlm9UZpsaFqssI6dbautqcHUWpHJTpjSn/ozZaEd5rPxgUn/ES4HS69ugiy9DnF5hH9nD4tXHwa
# DATA ieA4mvf8vaFQ8ku2brkjUxTshWjfE3mcs2dbm9uX7doAObKiMIMJtSGBY5JzN1uZJMb1Eba0CvO0eNvOpDOM96NJuQ6HG8UKsvqN
# DATA 3xaUUenHgjn2p1o1txB8F24tBV0GVZY2SO6VETPjfBoIiLR6eO4g7KfTl2KmO4YhwkLNEhEO52fKeKFvgAsE4p1gXDzjkjWiR31U
# DATA L5x+01vWR5jY00sSJ26++U6X4in/Mqly6dbtvyCihBXzYDjo0LBXQZuaU3P8P3SoKfvSIjHaihWSj3S/WvnJfulCZ0MqkZNY+Jq8
# DATA /xzI21bjfkOEbdJ0wjZzFXScLlNbl4Nl63IAprt3Nx9urLmXg1eqFrU69B3y4FEKINhOpm8p6XuWxTmVpUbSY7qALsldR2MueqO2
# DATA kAcBHs66Y5q/A0/wFyC1inTMoWVKes1DKYUIaLyioPqQhI3nfixA52WftdP9Hb8WZoctM6bg9ubq9+smlZv1WR6j6HFjKp+mUgFF
# DATA LjolqYYhzHUsVPVWK4Gub5uOCayown/a+yNMFoQJVvvgD8/JNYGO2m2QYtrtUGY9nsToyCH2H36urEwOjgHGcAt/UZm2wELaFjJQ
# DATA t90uGm9CfrJ2h18paBdHdN7cQg04Aw3jN3E/G42n88plU1puvJWZJ233cATIxjUCOUbxUDtNOsgGCJMug07FVJQlEiaWlaElrcxh
# DATA yDjIzEKkPC/eSft90NmLBhm/o5ktuwnwBk2vANWmGb8zem9GCcal5E5wMCuXxX+gtNQ/QagqHqbRcZ9trAsuuuQ2uvnWn8BdvHFM
# DATA +W7IrYT2toKthlwhQCs6qYJoqGKHwuo4oLk08wa+ReYN/CgmjD/h6vBnXAn+jLMu0dH97RIFmTiTALzvNsXBT/iZZ5q/8axmN5Kg
# DATA TgvSzYZwdZvO1QDvCF0tYmvquooVdFiV05ZdmbnHMmrU+BP4EL/2e3ptfKj0pJd2qyrOfev13+u/13+v/17/vf57/ff67/Xf67/X
# DATA f6//Xv+9/nv99/rvMn//DxGzHFMAKA8A
# END_REMNACUST_HELPERS_V1
REMNACUST_INSTALLER_PAYLOAD_V1
if [[ $EUID == 0 ]]; then
    bash "$directory/installer.sh" "$@"
else
    sudo bash "$directory/installer.sh" "$@"
fi
