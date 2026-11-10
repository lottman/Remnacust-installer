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
HELPER_BUNDLE_SHA256='9c725c318b943fec3bd48cdbdf1a4d4f5f68db4e842076b63e35ff5dd8675223'
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
# DATA H4sIAAAAAAAC/+y9a3cjyXUgqM/5K7IpHQPoBkG8QbBEtdksVjetKrJMsrrVZtOYRGaCTBWAhJEAWVSZ59jWzO6e4znrXzD7OPsH
# DATA ZI+11ngs6S9U/aO9r3glEiSrZbWP1ypbTQAZGXHjxo37jhvPD/cPjk4Pvvf7/FeHf912m/7CP/dvo95sNLvqN/m92+u0v+fXv/cd
# DATA /Ftmi2AOQ37vP+a/z49e+XvPnh2cHPufHxwdnOw991+++uz54b7/nCnD+zKeZ0k69VtVv+//STBdBvNbv1lvdjxvP53dzpPLq4Vf
# DATA 3q/Qb/5JPJkGN8F17P/warGYZTtbW5fJ4mo5rIXpZGuunv7IO7iO57fpNPaTzJ/F80myWMSRv0j9EDr1g2nkR0m2mCfD5SL2oe0w
# DATA WCQTfJjEmZeO/MUVvDhOwniaxX6UhstJPF1UfWjuh1fB9DKZXvrJAnufpgs/GI/TmziqeZ4v/17O42AyHMeed3YV+4SG0Siep/7n
# DATA 8TSeB2P/5XII3fvPZQjoKPBH8ziuEoTjeLTQw4/SuZelo8VNMI8J9HRxFc/918k0ynyA9Sadv86qfjaLw2SUhADMrR/FWXI55SlD
# DATA J8t57IVpCpiAeQK2bwBpMMcYBptMltNkcesnU/4hgBGh02m8wH79LJ4Denw1fo0nJKBlCJs/SbOFXwDgbB6EC4SHIfTxqYLLA7gW
# DATA wWtofhPc+rfpck6zj9IJQpxdqZ4I2TFBRp3UfP+zW4B6upgH2aLq4YvFKOXxkukinkaMh0ugrQC+x/nxvJXxAIdIFUiZhOIAJpNe
# DATA zoPJ5iZ0NEHAEadIAkB0QQKtsDuzTIgX7CRZZP4ScJgB4r66igHzMS5U8Bp7xVc04qr4CF+dx0AocyQwGEqArCKZebM5TA0wcPzA
# DATA pO3FN7AuroIFzty7wv2DGLUwbu0G3gQr8Pllwc/8kkkSepj4yQi7BHrKripVPQTMIYyTa3x5OQ+xywiIag7ENfUv4wXtHHrRu4EF
# DATA ga/Wq9jGWnU9PLwOiPQBtpChw06mQKc3HsEpCwQbAeHU3b2epje63yjFPjPsGfCLa/I0vo7HuC8yfgWHuI+mYJRFHC6Ygog5ZR5v
# DATA phsg20UMLMkvNyp+kMGiL2gvMwtLp850GMpyswIzgeX2EELiOYoh3Fwl4ZV/CUjMCPxxfAngECvLiGEKL6taS+dBn1u0IaNkdOuM
# DATA B1Pdg70MGydCBjuE6Y0AgYDGCMhtGiG5Ib0SrZY0ZSSMFi+ZwMSvY2SCGZBUhBsL2i/i+TRgBqq3Co4qa1HFVYbvt56ih5sEaHMG
# DATA vDHCkYCfAkQTIPvrIBkHwC5p3zD3iKyVSb1kGqbzWQrsCzfAi2B6azdYoVX831UczGHzwzYAtHgxdLCcB5fwdciomcfZcrzAiVuc
# DATA ETr/Alg5TKia44hmbwPkEa6nyyKzKi8gdwtIuvVHMCteJ5zjMF0ualocrJEDLKsQx69pSXgtExhQcEyTGccLApxwzR0EIWyLDDcF
# DATA tlFsG0kThvVxQgDZOA4yllyZZ2/NRWp1VfsAmaU5jSN8YL1Y5hDxECKzJVAzYpLQFJtp2WAwNWSGHDwBTEspWJ5DZLl/sUwAz/SM
# DATA lw7JBtl0TmwBJEi4SaSYicWORi4gCr/z5XQquJ0rzHi0LfgVYBLcOcByhm2AZIGSZRmWLD1X160K6+IF0gxwxOuVIM1zd1XZ7Ktr
# DATA Kkhg4L37gMddPvXTcQRTFxEN+gSsCcoCaH//eiJl0cjZFe8Sbg6CKcgcmQJwpZMZtvOzZAJLNfcv02CcEUaAKpIMZgqQwdvAMAwk
# DATA pCppRMscFEwvn7N6Jd+vgsxjgsUNjGx+/YvCLNXegddoRFzFJQh/FFVGmxPyBiYUJigJ4KWMRT/wxmRBbAy5EDJX6MHir2r3MdZD
# DATA 1qRGKep+2OnByYtTf+/oqb9/fPT08Ozw+OjU8+o1/ylw2il3DM02ziwuv8HCnpZYza6l5vfgBsTetI68Aew4A3EfBwC/Fjub4wTE
# DATA /zi4EfEWzGa0P3MqpKdUSNylsNhZPEkQHcsQN9YkyF4L6DEotsTabciRGesRiYvTFhR8R7wGxBw9BbnvHwQwlDRh9TeKYEvTamf+
# DATA Boi8DWi1IS/E2QahfgNXDVQAEEMbxGKHKImiBHb4EuaPSkI6vwymyc8ChfCz1N9ggQhdMGSMJGUMjOYg6FBdi4IZqfL4ZQayQy0E
# DATA vuOhvAOGnl0RjyAGxKJDCXgjmquCXcA4SxBh5sgXpl78BrRieo8ZiCWHCDhAhezYQAC3NviGwOSBbBsnyODxFQSeP20MAxZOGzSw
# DATA 3Yo0gI0QpPgcWuAvG4KIOBFwQbRN9Yiy0Fbn1Lcniow8FgQDk50FlyCcV3EcEYGQwsVmB4goFgsinDwbczfpchyx0opaTwRsPlwA
# DATA yQIUSntJ4Os4UdoCLMwIV4J0EyE1pHLYn9jCrA9sgqofvwljWOT4TRwuF2LD4a72kKGBBoXkI+oTi19Qua8DVopxvV7KPJEIQCUZ
# DATA L4Etak7hOZyiTJNNjQy22QboykrCa9VHRA3zftYPUXCi7gCqCxg8pJXTUqFddQ0sBWVlBnbDeCzrABi6jvOEjvsTdzrSzsyaAHGE
# DATA eIqDS8cekj32qgyHdK5VeTYLUPmKxa4i804ZkwGpjtDnPF1eXgH/1xgVkczrDTLAB9Ntmo1ikdisxIohzfADXliS6VGuY+6efhgF
# DATA IMMB17NxcAusYm+Gk5onuEzPSUs+SsHsBJah1If4zQKJg+ZLVoMsXMDjTZGfEL6ho0kyhW9AYtcJSWdvFAcLbT6haq9Hht0dWGMb
# DATA UpvS+FrF9xawQCzYBUfBQtQLmjbI1zkaprckdxTH8ctCrEIX9iTkhUTsPVFxImWBKbaaEYtknFIf1K9hx0qQMKRXYCihHEpA1PKy
# DATA +MoRYtj24QjtPmsdQI5mZBUEMGxGPJMmiSpbQNIF1nlGzNjIl8CD3bqsslnNGIeFQXOSmQv1NInjRcbjh3N4OmcFp1HzT1mN2wdN
# DATA SKT5hqXZbbDx7bAhFvhoVwNng8cTh7eTE4O3o71JaRskCxRDx8OfxsS1sXuzq6bpdFPUMtVpYDHb00WADCvyDxW6zMsWCnkfMhNO
# DATA 6BnYhEmYBGMvUz1EqESwVhbglkwvQcah+iwNMn+YRrCP0lW7RQ+UKS2dcYDYx+0eLlGBE5NtgkgYg/W9BFMJddZYDMCMbDfYF2T9
# DATA BJMU2lkWGE6a+KmwFdWFWp/T2wzX93kynAfIyDZYGgonNkqD7E0tMkSWelqWUiskIVD60nEsFF8OKog6eTtSKJjCogA/kLUB7ha+
# DATA Di6Zsb8Ifgoo2AcmlU61a4/1SOFFRgWAAai5ZzWnvT2ssPIOVD5lvYrZqTIDNMDibwNEroyLWx7IDPRpFmGBv0o2tFwMHGgQuq3I
# DATA oWxFiCgDguSHMXkQD0DNe95GDooNIRrcaikM+gbgEkKFjYFNUTMDhgPIDNVLXvk1mP/xGBn7NALmkdEaM2pAFQUpp3CgrEMx1nAF
# DATA uLFXTpAMbisohXmCzLBdqgCbLKuyJoLDJ+N4znTI9h3oqcZFyO1gD5kty3sNGMDCvId94uYW+txPgTVks5Q9IcxgHEaSuD0SSQmK
# DATA xmMvb1xO41g5HUl1X8SIYdis47GQzoihNDMl5lwhsMistQYjh1Zqu3V4okzuhE3gkLMFeUrIN5qOoVmKNp3WFBzPxgLUspjJXO04
# DATA 1W0p8/KblVDKExlvzpbzGfa8SFNWuOUB2rTGjYPOUOWRU5SrXCeWkglYBYpAZLLJ7YKMe9IzL7ubkqGFWT1D8nwT4Kao+kXr6GmB
# DATA b6kP2ijzR8mY9KgsDVGOR7xZZTX5obg7Be3sX4zzW4u91hEIL0Ebhxlup8GE/SLeOJm+Rp69HGrUKF1A6/5rvfji9Kh6SogO0We/
# DATA SCaoe0TBIlBeEjFMyYRlUhiBhQqW0uImjqeMZM+GwfLYA3YzB728PYqwSjTuUJBW85UndZ556HWdx2oT+MFykQLAMj22vFZHdobz
# DATA eLj7IHG3aZ7jaSdmFkz0rJo1/7MgA470UhsfaCzugfXHXl3/kmIFUYG6RMSoHiuVDf0IKGNWPL4vlS8U0UwhCZjBdcrmidLcmJ4W
# DATA SH6e5YfA5pN4ofwqavz4Ddo3CWqpAWgK6MAgf/RyOk4mCfbh+okVT1m17sQEBfMEdHVeD+X/QpvI2Ipklsp38p9a4JDsY0+v9MS+
# DATA rCn5GUmgoKCDD9kiWYBNwJq36Tw/PxDT0/QGTOBLdn7PPVkT9PMGCQcCtKMY98V1MGapnBmUDm9d6w+W92swKVElRtumSmgRrZ+N
# DATA VweozMQQwITF8Asr0tputR1GIO7GqBEFshIqdEcQ3qCfScJE6EcAkqEwjoJGFPTc4OKjyTSFZSkSDHNfDFFeBdfip5ywsebqrmA9
# DATA jJcZLMOY7QqAi/i48odS9AU5HfDDZMz8FtsZ/ycyY3EMWXSqwjToAbwlXHiK/rO8wYDbUZt05FpBbjVPWCcTucAY9sT8I4al140o
# DATA g6TN1VI7xR0gc4vmyVT9yTJDIYcrY2MCNgQt0DC+Csajquxu+ol9DQm6adkbiKBUaRvT3GjqgIirZEguDEA7bRhlyLMXjENnHvWo
# DATA pxFHZuJAOZn4oxPyyfN6XSUzFjzwZg1j3wpr4tKA3pncw2QeLieo96NG74S3kUJQQxefZ+xQKDEXmDd6K33/lBREcZK6Uewn6Gkh
# DATA EdKoe0hYFFUAhGPgLQvmtwBeq4YcBCNh+P4rDhqx8X3CW/UZomYP5NPmPgF8jeoj9PmcNuJR6iwbik4gjiHKZdBsIy3mUUMajWL2
# DATA AMBwV9N0nF6i+AALMqAQg8GP5faB7e6PlmOQ3mOiGJjspewLaY+GDyhdjYYSOl8dvjy2GMZiDnY/9BmB8crhnmbdfwoomAzh9Ua/
# DATA 38Xd5Cn/N7lYFXEoIo3RHcQoCh0kwJAoxdUcdHCYNxZxA5dDVjnKGiAacKoSDYTlIusBiH6YgOTID+JgzFej+a5bhEMz9qto7THa
# DATA mY2CkjoPEyIVYcQFQpGIF2Uzqq2gh+a3JgtAdupl4ThIJjQTCtAvRFCR+PJNmgIg2HG22yYV2YCsgcPP8RS5KhmMwMpR1bYVWtJF
# DATA qrzNiZsmc6Yx2K0lQabMTGNzZcm8YmzC2rVrvtmvX6pkkn12mBmpIyubyzZRkxKJXMocBYYFio6fJhxNQ8TBNkmWk2LWPM1mYNan
# DATA y2xMuS6e5aaCXyTGgzQdoxdeUmLudWY98V7H8QxXC73XuFn5d2YsWulz1SRUeKa3HnpJlEJyrSMukdjpGEyaK6VbGE/PBCqYjKJ7
# DATA ABD8BUOwUEOOvgF6lE/tCYFxSRsHDDUTP1jj44JWqfJUu35uvYycAoGDUEIGUtQ0lc8ofgxS7SVB1cFTWwD7ocA/7L7ZLEVmNzdu
# DATA QEky4PASqrajGPXfjk1mL5QmJzqw5FEV0JvtvV9RSkW3yLu9tFWdiFbovCTeFeXysulVMYbY0wqBWtR2Ea1K0CqWwMtI8jOM4Nrx
# DATA vKBCSir781Csh4CoW8t1WEiKhGZBkpeIxwbogN0/GFq8xtyTCDMKPG/4rcagDDATpiwyFXgP2JKYKZ/bCm68nlKBxcojT5BAn0m2
# DATA gnmARo5CKi7WxpqtsQETCyusZ+KclFZKzB/Y2lxbtJY/bTVaJzE+9AVCG59j9DAa0HyaZXGmgrKBiWpZL9+ADGZvNwbKeWNX7V2W
# DATA E92aB3iAKEIZMFsipqriBwSpLQzEuJJ8K7Ilq7Asl8E8GmMEHbVl9G5f4XZAhzk5AuMob3hwBH6a5uwnG2/KyjQK2U1wy95Dy6sC
# DATA aj6YJAkSF8tXq0NJmaIsrCwGYJkrC4uP2CkVVfxDS9hdBdk9wRDADPEc1nk5POGtDYs8QVyIH8gRPflRbM8xkTvbQWoEf+0ILGk5
# DATA 2qC9BGSikNZMWjl5yNmZp2W7q/MwdTCOFZ4kKhbFM8zqmy5U4Np1EnGCD2jXUw7dkKLjJCg5iglxZbcHAGxI/nYVsVROF1YPJhjt
# DATA QCmg/eZVNOzQJMUw8XU6Xk4kDyRbpJh1hM+c8KAS31a4d+ptBJeXSLYYR00UpAZFNPlF5mQuKTEtkHvKvcmqFAlGziIBABxFJ13p
# DATA vySpit4whs2OKBHflImwi3HKJgeGg6ZkWhUtH0XM4f/VjIzHMQyWnIJnNh5yGFvim2ikke+qI6Ccri0Jj0C9ECH4DJamUAK6rowC
# DATA V66WW8xqPCO3MuCxiPjOWvFlBdgmsA2BbjYxw424WaG/KjdYXgVhWprGRhwCixFBuK/Hyjm4SZSDcQIyg/QqCq5d3Wakq7I0X3hl
# DATA 4zG2nhbQZaUqST7BNNEZc16x8y15w3pF4EfLOXu1VM/cmRcCX0onHLkn+iRvqUqnIy7DGZ8siP/N5hh4N3O0pKesm1V94uGsg4H0
# DATA BCGP+wETDW/jYM6OU6tJ5lk+IKXezVjeECGD8U6YsNQ+du6wY4HAB6GPIRWMHIixp+SuCFuV9mZhRmKHlHfqGaX2Pm8py2R7ETj5
# DATA gKEQ7Waty69avN4eI9Z/9HpXVRySdGeQu5OUI+3ipYFtlKVTSeTg4LIaC+0YO3KQZJ7xNGmllCgGs2xNKp0o5uuoGZXdlTTCAPU/
# DATA UfxZpxIatTija83ZyyP5EdbCuHSGUNlZikWAKa1K5dySMZgplw27YNMwDDLSl9jsw/A0xgTQeMffSEvylLfWStOOikFmmac3g7bV
# DATA PHk6VKpad8gay5qNOxRbh7Ykr4OgmeMb5PUGjQLQX75Ey5+2ClMG47zCCh5jy/h73QTJ4gUVW4V9/8GtSlAxP/LAtMLeaDlnHxuv
# DATA NLtotQYjKrhv2ZAP0lPOmrTQQskUHKwlCCh0Nytge9kKPVbXkoknOXG8PXUGppBxmT0rvJ+JRyGKjTfktuJxfiszp8xGtSQ5Wd5i
# DATA Sx6ySYsGSDL1QmCUljcVZD7oX1qwWzPLAurxRiXajhIOrHlrNsCJo9DfmExcUGgzShUpfrUqtI4QKlegfTLGtuXcTHRg5Yqlm4hu
# DATA hhTKcdjMsctQ84jX7oIl+c9mcTzfXKSb+JcToXTqm8ImnQVIpmxdc3AsphQLxlNBbLgoXub6yuaYXM2ccUQMXZZDYrc64Zh2gTg4
# DATA xEK1tnkkpwhQFye+D0RiueUssFAjR7e97RpIJCaBU9Q+heJNgyTvBKGBd+ltONQB3ciNL6wwMZ2Igw5qtHJQtm0QIJbEpKy5bDlh
# DATA ZZ6aKINCZ/p4CzzzRXOGpSCTFG2fGPaMnTSC2Sa2zFONQc4FE5CGVS9FYoXnYMFGKpiTGSmlIqg68EuCc8y9mTMQ5KNFAxw2OWb/
# DATA YcIcKuPwHmqUyVT2FScLqmkxK8lPtupF6XK4GC3HnJ9vfPGwMOn4mrE8Cq45xZ40goCY47NcDpHWHrRYoWwlK8kIzYuqv+Egyskk
# DATA 9ha3M9LXUs4gA+LSqTRAnOE44M2vYPddI19FUZdyhi/OD+7zJGhjBHTmzSSd5Jp6YAQvFZS8RPEbdG6TdCJinrGHHACnwyxy8gUB
# DATA wywbrdIVoj0HuVosqw8yx3H7LQLKvPGMLEdhHC1Ro2VUoYdVD8DgLqfUNclw/AXGk1Q98syTFoA0Rm4/djbFkrxnneKhuXjexiHn
# DATA rrAZeki8iT6rFBl7g1n5cROYVBplVaSMMI7QXV7FHICrdC4Z2v7r+JaRy6wuMX0r1koIluQZMtU5Z2b19ENW4ENQ+WgOgMh9vIKj
# DATA NXSoLFuvf8UOeOht8bIlpurFeWEiwTew0ZfICpZT4qCimjonN5hheYpD4om2lFP3YLkw+MBMgF0xPC9OT6FQ3zAmY9qNkiDdDDHV
# DATA Aw9qweodjpzA0nSFSdqOS8XsxdrCwTjQZeeljOQwHptgNm5NdoyljYfhEq2lzNNhPRZ9gRrK2oWSOzGyfYvYpaFLz1lLTO6QfGJL
# DATA rmkVTTKMZvFiiYdclV7psdVKSRvlQkehC2FGKiF8Ay32Z5Jou0bj43m73mCFVHLQDWPb7vTkNNq6HYYHXpcLdbTM+IC1N4X8Jl6C
# DATA J3ZZqOFaT1MOiVq6Hby9oIOqHCxBJe7W3lk5ipRDUqw9Oxin1DWdcGW7KD2iOumQ5cbJ8YuKpO7Y0FsWz7qJr2aoBV6uC7XD7O6U
# DATA YY2aISVhq6gKkfNyhi5ZzhKQuAjtV7NlNBbm1kT0iUGhqqoQkreCHE3LyUOdoojQ5kvgKQ1fFPgoJqfEzVU8XQnQIJOKxyOdUqCC
# DATA fBHysZiTgkhOmeNxlpamBgJYrpN0jOjgyS3HnLKGzHqRhpjdNxIxbLLKgnCeZpndESUr3LMPmCOsXWWl9ZLTy44FFm4cPoVDL2sf
# DATA hTpS56lj+oA3Oqss0QU/ly+7PlnWy6eOid1JoyvrD9gz8UJUAUEbuUGAAU0gx4gillMMLlAgGp2Akgog1hPgqlfz90xc4yxmh+WG
# DATA 9ZsJFeChp3lsp58gdUue8Ir7UEdchrcqJ4VPEPCRNsq1m8Z8wGUeK2FnAlM1rxgIOTkmsRuJ0qgUAo4iqQACqY7ABTh7go9yYa4U
# DATA 29ugKvPRETtJ23YqOXkJnhKkHLJhP9vK+R7M6yJDOiiE3WOvssrOtrNHdTST3W/4RPYeqe8mMuMpRp6q87ncNwd9CrCgKgJcoiLC
# DATA SfveSqoEJpCx4FHTLp7BmtQQdiUVJYngJAI5oM4HL4BtTlJJHCkeRMV4g4Ucx0H2Ri4aDHIz0jxy+JfX0IigTvm1TL6qRGLSGwED
# DATA 3kOjDSwntMbZ4rhRE8xlONcqJkmOnCTeGvCRQwgzrEp8VTwcZCO50R4384zCcKo0AXlcC7MgzGiUvbTAJaSzFyr1S5W8SPHckOK2
# DATA NnHzIRNJAsOcDoCzADy9hpQZL6qyEUEGois65kvJZrRwqu/KvUzCTdehRxxYeCpJOWQ5qkQEjBlhHIkOhSRKadB+JZXCWxTuz/xG
# DATA h5hno5sf+wnqk+joP9HHKMk0mV9rQWUOqlguYA5f6bQPsNAIPUDt2rWfaYXf5NvNlQ9wJV7pSbxSRTQZzRziQt0iYEM6WTDEYQW3
# DATA uM7wAnrQNpUjYWHFLpOpNloNZUIn5uQoPysyYchm0/AP8fzo/DXxS8/Cxg0dQcssL592qjAAgS5hwuBHFVgAWUw5i8ZOChJ/uLDK
# DATA H0H1X4IJf+Dgdzq3MK5tbQUkDxBXMEFuzEjDAAYSUS5jbA4mCU6HM/TEjCB3/QRoCJ/yyFXTlM1D0ecIFxmPN7IpCIPCk6mTKmYg
# DATA p+wAG/Rg4RkE37rZDchjM2d6flmdCs0tFfDECu8krkhDHgM8SrCciNglMCxtO6dGosZA+XymjUg9ToIp7FMfigXFJqX8a4+FU+GE
# DATA Jaud+VMuFSufYUGSFh0JoJEhR9oQh7inUxlJKcEZy55CW19FXHTWqHFtK5HoprFFlMcmJoqSyQmniLONEsg2L0q3scTq2sytgE07
# DATA pSKCzrg6EcNqRT4y6mM6I4UaxUr9Jw2fpzv0rQ5JHygqQsBHMZx8Xlths+R2kUgwZOjO3ApV26c+rWpVbryaUrYKoEY7i7KvsyVs
# DATA sWtJWFkHv/EnELCsmqYFbpd1ujzN1iOVmmS6TifTKVn20ZsqpVAAAgj/4gBYIVu3tgFvBnmdDD0hJozWhURP3krQwVFuRSvfW0lA
# DATA svZOmt9NVaUESaq1hFTNwVAr2UfpSbo0BnK4hVKZjdr+xGNrHcnTjjTIZMXiB1EA0G7XyJxIpuw3MFkQdG5Kn3Ew9YFyaybHjWl8
# DATA FGsZqL6aglZT29B+RYUS5gGMyTrpwMa4Hs2T0bha2nWaiEVIeWHueaCFgB/b5ZXsEh5qp9sxfmIhC6vOyOrRnZj9IOh+CuDZ7Mph
# DATA Vw10UHxhpUSRqo0ZfVwGjIzkQpVuIXrr3NOl2jiuabmS8wqbT34c8gKwoVrxtNLIQVrx3JLTCwyLcaHe55wBApt9lExdFLoHUcx5
# DATA VaTXgI+4V02OkXTuSedYuIi2NW6ckcQKua1BBzAhKk5g6STk+cUyZXyotVv3I9JSRgtZBzpBIOT5AqzQlHDuHJl5FAo9C4XWjFYm
# DATA pN6geSRxZs3Ee3gmUtEpYW1glMwx/yOZxNpwMAJNOAx0vZZe1JlP1jArxuby8uCaVPlwKSE/06vGbsvGrif5EgDOTJu4DBS63wxf
# DATA wGcru8t1tmjHm9mPiC+9vdA5K3UiUGMiC0ojQqVB6AFomjiX1X3MctaGhvoin5keO5JUhoW90Nb6V60jWv5fgK5EFmSq61Zg5SCn
# DATA XKGK/BsN0MnFRf3F8/o18s7N6JgN5jWKqimBvS/47JWT4q9yB+2wRRByCYfcmSgQjJz2oYBEywBPo9lJItYZvb1pCNwy4IRkXb9j
# DATA NeWOPO2kDkt8IFChJ4BJZcc/EIj2LLAEHiwiRKxdU4Yy7gONI+t4MSoTFMV0yuDYabbIn3kvuom2RXKDs6dzhwVjOSfMFh8XgLF2
# DATA vTBxOVVWsAhu7S50mOmaL3xEjpG8cgySiU30CBFTBgcrO57L31CyK2rFe0raSQNRnJ+mN0DLWDAUiEyllsArVCJJ85s154LcaIcj
# DATA TxV3yixVdtVG1EZDVY6KVrV+wL5gWREuPEJjZksOEZCu5SDV3QfoEpYiKhgyUEd0+OxgQhgb3rqncSx90VS52pv6G+hjQ/PIRGU2
# DATA WLO34zQ6EsSj8GFCLrtkl4VidctEVnGjjMnGijnfFIxB1Ybyu1jRWO1jEs8vmWbsmlPE1dZtVM6K5gxelQc19VdnJyndHLohRIOg
# DATA sOeKrNdaYJtxcM4HpqbqBpgtg5vTcHGVS88xEA5/35bwEFsc0Uk/dpxQ4BGsBWDNERsCy3HkkafMqFcYqkzSJaXes4YFqvJ4iXDJ
# DATA abr8WYG14TN7CppY18CECoyXf05J7ItctVE5nKbFezwaYYJTTkkWexo5ToGhlKlomByH0/HI3IFxFPJ0Knud2uwULBDTz7PHN7sV
# DATA 6wHP09tgLPGr1EpP47NGBhbvwYPrRq/QM8YaCLi7MaWLqdVNoKVwzyYf1+PVp+xN+k7BGDz4uEQ3CAa1LpWp7llquTQ2jDoyEYoq
# DATA SyNgKZzFUjWZglT1OBjzRkTMzLXnyi5NhuOYNCQ6O9Fo1PyXNHamip5N2UOYzjdUEkxOQcTdpL2tlAdfdBDGFcxWaTSneol6DCPR
# DATA oSsWNp7stGVmKuOZ5H+VMCBgwj60odbl3+TUhNPOlGaxES6xI+Rrzs8eCJs4sqpDjG3nsu64atKHxhjHwoKVotbAuqDoZKVe/VpV
# DATA 8gHLt1GgzlprUq5BdZuiaquPK3urScWjPFmQ44/P8EqwKo+SqodeF1H/VKSYp7oWJAoHURmqnGqkdn3RodOCsXkve7bblCZkiotU
# DATA ZRnT8YYpO2bSHJST1JMlytSpbDpgRcV3EGnsksuoiU4lddwBFARwZOYBH0I0MFtKV0CeC30sHqvuzccR1nfS3GaTK7g4hrXF8F0S
# DATA XEOBqFB4XGqB8qNwJWWDc0Y47W7e2qYICVdLuEcN4dFl2uvIAt1U6pQi5kgz66A60UpEkW9pw50is4fprXKBeNA0Ft8Th8KTBfvW
# DATA 5AwVBupTMVS4wCllAlGJB7JiKZRZ1oXPpqrnFc2XaqWbd3i863ga8OFDKlO+FI89t7ArH1aQyaT+Bq3yhqRu5xwjnGjAGoUuzyj1
# DATA wTnTe81sV+alCMM+ak39rmYb5dRVLOwBMNN5tzHr29MVQPlE1tr0UFtFUKUL3LRdcud7ukI21YbG3EV1cjd68AiOzhMPPFOyVw+S
# DATA Ox6gBTNF/N3ivuxI8BY6xImOTyv9VB2GWjNXmAN6FFOTmGySRTFId8lGRox1KtkeodQQQZFV5ptOd7jkwMZwktm+Fl1Bq9zSI1Rt
# DATA XuQ9ghethvUppB8JndCWGNsmkrZ/TGo9Vt37cZ5YVPk87X+R6IguFyOVRVEkKFM/R1q+VOawkoa9Fde1FNxknUt5VhgwPiRXdI7Q
# DATA c99kuaONUzv1IsGjiyBgOImaNRUVuPSkA3PGTPwrqLsyOYyT+Do2SRG057AA9TxbBpwYxWoyTHIaOyU6UaiO3dQ2DEDxMjNfs06r
# DATA 26YwWWqYxblUthW0EJu3umIk01Friv4V8SBSB+z83DgTU7WopItWy3SxG5Vvq2FTosLTgQqcq6o5Z1tGK7bztIBGKAGfwUdp4Lio
# DATA mZDFuYPFosxZEHcIVvfI0U3xZH38nlTUvTxaYKANrIsxT0iYpPNbOgFaVKiNo29ccg7mZmXycGZ2VdchyfLmCuvSmSkxZSoCsEZg
# DATA DJtcqpDWWUw6kJsSut7qsCodmRKveYNYPDakshqjF0WSIU4d2rOSGiXC50kMaYh6oyRymiN/5A9T9y4wgCYBhATgLLidUM5RasIF
# DATA MoJTN0FKpigfqpSqu+XEeGEpuUpx9nj5vlknq6oi2ppNG+cqcxHlj1vZG8q5WqXjPjb55Jk9Vchc5QnuqTWHnelEVkmlKXMeWxLL
# DATA DRBinaeZqg1cYcGBQQaAg47/caLlNCoaWm9QyTPPROlQx5EzxQ8p5lqwfSVQgrDF5BGIuCqBEKhhap4+ZOniBOvaC91WjV+9ue2/
# DATA COawWs16vcfZPle6tKnl3NPnJKiw2XypY3diPFvJM2QOYxpiQvUBxZg0N12MtEvGqWYt6SPA17RiPIzd/EXtWLfjl2qaVGqp0az5
# DATA R6l/ugTtghrCWh9TZbGS/4yv+WCtLVd3jp0RkVTM8svKHqSyakuqWMKhCktnNIBWVDYZpjBESahT4tUQRcG0W1VpDZCIQhbH1T6g
# DATA 9e/qMAJ6fGwW4wr2LJUD/OoAV5ZMluNFMI25UA5nzK1UinIcAKqchzqXhT4Jmrp5TcTKiufddvQIgMDdAyrYkXcKKW6IqCVHnYly
# DATA q/NrFEUnDRcseCz7oSw3Unz0QUat51i7Fd4C1jKxRL2XS4iU8yFyNRP7/DTahilpfalzeYKDJW1yUyhhNMftyzmSKmPMPbRlauw0
# DATA WjW84yuF+R2Jjn1oKo0/wVxro3Wuv0bl2+boCd5NGqKnkULUsXJihNMYrKrhbN3qm3Q8XU7Dqn4/pwmOzVnU1WLplP1HQ8pInj6T
# DATA SbaaVX69Qic66CFf5GXFb9YV09QCTM2DlTvl6XauHSk8ZvrwMWljQZG6pwtZ60PwAcgoXb5LTpUGuqiFPsUt1xdJoZZCYJgR23Vs
# DATA 1597l+irfbBdX7zhWRdvrLkiRSUUWdcRRY7mzRkfyuOgfQ3fliC1oZMvSDN9LdISy5SsxMiUpuTcwyF5zIX3jKy74YfPGLLZ4Jmi
# DATA KKYMrl39IneThRyZKs5Rp+wP+/yGU/6DcsL0ucrVgi0q8drMVR+6oKIFungLaeh07tfOnVJ76hEoQJ7URp4EKwQvf+lcdOU43HCu
# DATA KE+B3KTQwTOw5CI5KxaYsmtz6Usu67JuthE/3mPuXmJ2jrFBRBn8pZqOgAK7O48QgP4DqVKIhaNmyTzRx7ElfdVcUoSYRWA5qxRf
# DATA iPDYEF5j5ckNLTQE0CxoGhPR2UC+zac6ZKkoDNDDZWBJN0W6WML8kTxUi+kSqynqdEFPnyOQ9F9lbOh8cX7BPbJXjDAvh7AN2f14
# DATA 4MX401lrEtVrYfYbQcPZ88SeLB/imiuDxKWjkvEUoJ4GdK4q0zkQ+M6FS4s8DXmGhlaTKrVlyOi6te5W4uGVQfEgOZkMxPAqVSEw
# DATA 1Re5OTWYXhGYFqmzLmmDubKYQDtvbvk+PngSqbvuRkss1uTl75J7eC9gT3Jso6qLqby5LWXiunMTCN1wvUGZnUZkRYKUmsV4od7V
# DATA G8rDZNSX57S0SsHXM0HEXop/zs65pZpQkr3t2Wc+rFLtIFDtNyz1NKek4yl1SYhPC3KmSB+Vu+mU9KdJqYsmicRBZ3bIE9lfp6YP
# DATA BzBJfSXHA5DpfXFwcuAfnvpHx/5Xeycne0dnX/vPjk98eOC/PDn+/GTvRdU/O6bvBz85Ozg6818enLw4PDs7eOp/9rW39/Ll88P9
# DATA vc+eH/jP977Ce6F+sn/w8sz/6ouDI/8Yu//q8PTAPz3bwxcOj/yvTg7PDo8+pw73j19+fXL4+Rdn3hfHz58enND1W1swOr3ov9w7
# DATA OTs8OEU4vjx8emDD5G/snQLYG/5Xh2dfHL8608B7x8+gk6/9Hx8ePa36B4fU0cFPXp4cnJ4CAND34QuA+AAeHh7tP3/1FGCp+p9B
# DATA D0fHZ/7zQ5gZNDs7riJqVFvVOwID/b84ONn/Ar7ufXb4/BDwhXeGPTs8O4IhCHd7DPn+q+d7J97LVycvj08PUJgiCqETQPjJ4emP
# DATA fZiBIPZPX+3pjgC70MeLvaP9AxzLmrMHy4TT9b8+foXSAub9/KmDFETUgf/04NnB/tnhlwdVbAnDnL56cSD4Pj2DTr2958/9o4N9
# DATA gHfv5Gv/9ODky8N9wsPJwcu9wxPE0v7xyQn2cnyEJNSt8dEDHVB7rvLdkV0cIfUcfIm08eroOWLh5OBPX8E8kUJ8l0Kw773PTw4I
# DATA yRY9eF8dAlC4cpoofCaKKr0CDwxRfA3kdey/OH56+AyXRIhm//joy4OvTz0bI4BjQ657nx0jUj4DQA4JHoAAMYRr9nTvxd7nB6cW
# DATA VeCYnlx6XPVPXx7sH+IHeA60CIv/nNF0dApzxWWFH6QTfw/WF3tAwuQ19F7BJkDiO1JEA2PjbzawZTP2KkH6z49Pkfq8p3tnez5B
# DATA DH8/O8DWJwdHgCjaX3v7+69OYK9hC3wDoDl9Bbvv8IhXA+dL2/vw5KmnNhjR7LO9w+evTvJEhyMfAwqxSyI+ayW4xWml6uHi+4fP
# DATA YKj9L2TZfGcbf+1/AUvx2QE023v65SFtRRkHgDwUnMDsqAfBI1Jer8YGJF7+oanvdOWIkpFakcPq9EkobDZ2SNgc2dCFWzhPW5wQ
# DATA w1i0n3GKBS348BJXVZbceOG8fECOE8w9VA7jG7aClmTukXHD2rH0FNyow0NYp3Sc8plfPNz0hm6DyDz0mw6zdIxVEqhoNCsfqHIn
# DATA 18nYgr3AL+eYvSoZ2TkTZg6juIgwx9qzXCEynRKBVR1AzLuFbYH8aDkLb1D8gq+l2iMMcObfmTp18DVKsSNQR6X/TIcf5WoiuTly
# DATA Zt/BwJW06cYpCa8JkJd0aDUDUZxK8G6Z5Q4JVyWsli24mBRmeF5ROEZnCktINVl47pW0rOTE6l5yvhjDunbZun1aByczcxbhTFIJ
# DATA q5hxH4gv2eil6lSc1utV6ughmURZMMKJIbz67Ym+WHQhR3Ao48w6fcGXzmC8UtVgH996pEyJM9wq/ujWW6aeqIvsipxBpFSrInpk
# DATA 42yE5urKMRuxeOXhLCXfBjupVMGj0VIXtcXZjFDbBJz8EBFJ76pyedbcSxmdJJNuh/MkHmHgLdC1oyS2UvtR7qL5H2Jxvx/5/g/p
# DATA 9VSdwvwRmnhJpronOOwF3tG3TDvLmix851ZmL1kUB58fo+kG2eMV8aoySVYMfpNvM/fK7lHhyqqFUludt5mevmnrCgNR6pCWMjth
# DATA +8DKsbmuFC3k/0rZemLfT8z9KCe5YTcjL68vAS7XqUu+UZdO4/hxxo/cYU/3pqOpq7ICbcrV6e1uouWDfXtO/TeDRTbmgKIxKyb2
# DATA f3i1WMyyna2tm5ub2uV0WUvnl1sqE2jrR3SELyNDwKlAg7VemDtSkISvJaeC/egSnqdTLOmFF5wEM0xqgrnp/AyrHmMYmIsWGVK+
# DATA 7fgeN6Wn73S8NYjiUt7udfPJQklHliG6dAzf6s3ZmarifbEXfG5THvQRD1Wog6kc75gx9zqxq1pVKA78DXWVF7nM+JxcHESZhoFj
# DATA jMDEr2NPR8EinSDOV/BwQfnbzPKGS3lPKTBHNz1pU44kLykYaicM48VCsp7MeV11AdMTogF9/KClDEsdYM0Xmfs6h3REI2EqBsSl
# DATA t5hZIp5sc1OCut8vnlcoqw5tP9iafP0aRSCxGhRXQ1Pc0OhCGyadwrra3boR5JnObXDpE4neuV6SNRn8QSxOvY/oBmjAhPfgbvje
# DATA H/79O/kHNsjh/kFtEv0ex6jDv267TX/hX/5vo91qqM/ye6/Z7n3Pr38XCFiicgVD/gdd/+/7ewvn8nR9FMvzTuLJNMBYkJzQ5qPO
# DATA XESU3aHjdLEA3ovZ3NN4LOfAIpTTlO1GPnDq5Ya0y2kkNa6Il2y2avVNDGM+MWddlJbMl+ZSyQlWYeTKDrnZskaBi5/MWVy91pWz
# DATA UFQtZ5Kq9gKGaNbq2tsnp9Swf34fxkbVFJTBBV0GZPpIb6Zgme8fHKGi8hkobJiDnY7Dk7N9pX4TSlSZ+/DWlORTQHMQDWA2OS1f
# DATA nT17+fyJBEEoKxIkPyBua6ruwLyciyv5DJNQNjkJRY+CZhvdJKGupqK7fBDTatFA9rxS82dAd3zFrC9Bc1gOa4DErblak61hEL6G
# DATA zqv3t4KFxITeh5pNqbBoQZOfnD0/3cLl2kR0SCwGz/fQrZjk3MUS/Ew2cujm3pHsdzfp3fJ2rV6rVxSqFYHVwL7KDH3Rou4fWOUX
# DATA HJJjGojRdPkPsv/xXkpMoKqFP83+bfh/s97p9Vz+36g3m50/8P/v4t/Wx/7JkkoCquLmYFVyCgWxJrD3qJbsMV9Aqet/XAVg4mZY
# DATA 9Bd9VyEe76IDBsBaP97ySuiX4XNZpSeUkLzwR5m/q/TkcglZxc4oK1XU43B+OwPtM9+EfzbN3vov50k2CfbHXJ+Fv/l39otbYCpv
# DATA gRpL/GgAVj0Wztv64xk13QrpTdNjNIR3y+WKv/sj/63nwz9M7uVP+I9byQ3p0PSIIndlHvjTGvcqYedPa9z7pzUwb5JFuVQrVc7r
# DATA F/6nn/r1iv+jXb/nf2p1jf+CKJiB5bFDbrDyI+cgL23OLkuVGkPy8rJSdnsW4MV1eLrAtLUdShEGm6AWT69r6GH+bO/0YPDq5DkW
# DATA x3iz4zer9/RxBpZGuly8wEv7sh2/UR/AdgVDA8Rj7lGLHzl93VVh9cCsiScBzxZGLa8Dp1LLYrT6XgZogNXAgCqX+N1SBdFZYndf
# DATA yb+rmFHu/B1i/3QT+xP9szg0p+SGNMRTljWtcMs7sLMXoGQYJKJZfUOvHczn6bxceirMUk7ljVWJXKzGgNcy0ta59e15lFTv3l2l
# DATA jDRHBZL3r+LwNXUq+coZD+G/vfO2tlg5USKLA+CRf/qnz01lPjDuqcBEwLmkdBSEcpy5Uo6ubQKdqRArqy3wUjoH/emYCu6RAxPM
# DATA eaxlnOBFOFTamfc2CURTX/4J9oWnYyK8v9aXK7X8SSIqC2dacRo02OVytY0ulFKT3WaGeaHexE3FSC81681uvd9oNOstIJ9BPA8G
# DATA wRjt+oHOqRxQKfnSjrVOAgshNVtOdvxSo19vRcFwuxmMWqNmo9tsNevt1nanV++1OvXmdnfU6zUa2+F2NxxuD1vRdiOuh81+J+hH
# DATA QVzvDUuGptTJWdU7EPe5Q9aldhj1mqNoFPeiuFOH14NO1I+7YRg0mtvNcLvZ3R6FQXcY9Pq99nZYHwJEnVY97vdaYdSJeiV3m5TC
# DATA UdDp9MLucNgfxe1oFPb7zShoRb3tRqMxavSCRj/qNqJRCyfTHG23Wp1eE2azPWoGzSDoWP1d8Me7qnen2F3Gt7bv4tGEZYxM709O
# DATA j49qGbEHoN4y/V71y4Oqf01McXE7i7Fshr+7u+uXhkiWixLwsevaImWuAsxzBxqrIZB+7AGYh9dC8t5/AQ9hK18FzU4XmBfXey0z
# DATA VDx2pVKLkss4gx1/Fb/BDaTKM6t79+LoeQxaYKZgnQULHPD8oqoC6EBRdxUhkWTkc0P/j/5IT4ZhwwlxNd0SPvxobw46ai3J6K9A
# DATA Qw+kAyppMQ2xB+AF8uyzJfqL4C3+oCbhECgCdZ5DNEJduQBQrwglAkfF8C306JQZpVi8FNOCqU0NS3LrYQpxcg5NABvntVoNh6n6
# DATA /J0B0QwvHmfxo4Djsfg14ab82hPvzlqdMagGCmsG9w7KP0KU8zAl/y//0v+Ifq5RhCP7ClT9cukNbPvGTgmmJkNREx6csTG8xfI5
# DATA u75gHs2FsvSDhlC5C2ZACRl1t63wadC4m6PHSRBqeqw64nHv5cvB6cH+ycGZplMCbhO6wQlsXjdKmladccJkho793FBPY/49uS6X
# DATA gjjbhBE3L8NJiVanyrOqgWUTEPWBYG00K6pbehFk4mIPrJaz4LKca91oVv3mdsVdI8EPpn8Fi/K5dCJTyXWAL1fVOFSsqFy5qJgt
# DATA XlouRtuIzTsvyG6noa6Z7mfTYJZdpYuyYpVq8RkXtLNxtcByw4jOsPaDv1jG89uT4ObVFMNe5Y3Tg+cH+2fcckBBnWcnxy9sT+WA
# DATA ZX9NOvuKslq4PT/ZVQrBhrMQXCRxl4T4KegQ/H5tEszKC+JtNTOoQp617WZ4lznQ7vl5KYgmyRSWiihgwN9wh5W0UTqA1cEcuky3
# DATA Knh0cWEzBtweBGINtlkZRwNtkbhK7tfGRaVi6SNGfyiXANLRWC4xxhh2eCsoN6qHwQc6DIy8xX/kZgeZVkoihBsWcr4YLJf8DR8i
# DATA JPh5MU9/GkwHqqQy/nSNoWfdGD7qhxdGBhGqcICiTtULA2Qz+MM8Hcf22zi75HIA25LKxYHiuMQzyquYlSc8Y5sELIlg/5xMhxiJ
# DATA g61k08cqCZyHwRTjNHRHSBKPo+zC4sQxnmsGpkt4dXg+vy0LsuvrXljoMP2AELXJCYQofy35n5gXnuS6VPLbUIhuCpqxNdCO1YTh
# DATA wOcCEaPriUOJH1HXMAn6loOY6KS0jggpMQ5rJ3KrJzpz+ImQn4HfnI65hyWUhCWEeFHj9H6ewG0KmcIPGpStYPb47g+a/vEJZq98
# DATA hmHKCPncYJZmlL5HBMlcpMrvVPLIV2Ptar3w05qhkItPNTAg2pha8JOeMjGekHSimjW1CjBcvDaMH30EW4VYdDQIFggTSw/6dlFT
# DATA RQrKYaXiLp8MXcN0funJDEw/BvhjYI9Maws9PbSuWskQDKB94VDpCqaSCNfXHX915kJbyBmQOPkT7gP4k+8xo6BpjP2iXqO27DnW
# DATA K4TvMv2LykX+RZjYvfLnPwmx/eCtGsKsU2mj9En4Cfy3UvtpCtpNqVqq3DEpbvzgLRHJ3cZ/Wpm9mFDIdBTb+Oz2MLK4UI7NIPKB
# DATA rSColZyHoGAz5rhiKf+K3tGuQgu91/jVT2vC/2A01MLME/2gBlbfJSiBayhDxqZqPtNUsdPM1l8LpinNZKr5IYumoacijUBgXyLI
# DATA Fv8mDmc9fpCaMci75Ah1rEGCF4uAp/GtsYIocsZafePOW//NQoVsJNQuimSrI00r1ganFK30poL/OeefUE9n5dv6LQcZU+S5aHPY
# DATA LokujIa/SvnU1UUl142h5aKuRCqiQn6gJONKx+dhgY/Jpe8CxQmVIgaJmqD0Ql8aunzyFpBA7gziTOQub5kZDo47VDhJVTs5edI7
# DATA 1uTvXNZbKAwqjhpBKj7bCkUKhOrBer/Gw1eK+IGsJlp1ZFJxx0X7R4iN8taQ/+j1sEVO8bYTz+c4esaSzAg9G0pGCswcgUEEXDxZ
# DATA v4l1Z9q4w3O5xS9IgxyiTA8sU8rnbOCS/XdBDgtjaVrUqqGD/+AbF0U7t+A32niMvYc5oshIDKpolOclJXwu7fBP0q0IFr+U32x3
# DATA OYq9KzbAc/YYhmjLtgGubNpgfnl93uT9A9DGYDZcXi1Kq1rrxHbNPaij6dYk0cGGFE8Z7pspZcINsOQHV7IaYMARvosIHbBDe2BG
# DATA 3CitClPjmkQnT6H8TPAqQixPpTsq2jbYquYCUjGqqrdK/KyjUO81d55PVjr/aOvPz4PNn+1t/ll9sz+4+OQHWzVMViUDj6UsdWMh
# DATA ZR0l4eFFzLBaWP7VvGwyI45guIu33fadGpCGUatQWT8I39hiPLihcaACdRLYRTgRb5sJUUhQwqB+S72PtG5+r2V/MS4V9aj8OaOs
# DATA Fr+Bxc5OgaDZBQU8Hn7Fsj3PQNuwfs8bMJbNNYKuqMtPV9wX0BPVNC9vfTP/Zrp1CZvumxXUKpYpDl/VG4ByTh+qMAT+z+pMuppj
# DATA Zxcs6rgE1iP9n9I65/nEWZ5fFKy7hs2YA/lFXycJsBLP1IhqECTHN9NykVu+yiQA0y56eo4PLwqXQYPJYyHlFwBMD2s53z3vE360
# DATA 4nn/kMm68Rub7pdTBsu+MUKTqCF9/5PCPslD/8RHfKAx5OwYByok/Sc6TOI2LGt0nDcucMYlUqVFPV0RA6tqJCl0elFqsyXQVMF+
# DATA vSvQeJida59dzoa0OlXCTkmPbBGly0UNC+MD7/8SeQcdrra48yoryXjCVrdG2CGG3M1XPJSOummRRfd6xZF5WVzZa4Wdmq4j6wpH
# DATA k0BEHks5YB8ajwOBBZJV12Hd5bDLLJhncTnP4eroJSN+ZSEnB5J2tj6EvpdaLSHnTFUu9CSXE6aJYwCRr4omW5JSY5TWrZMBVqbO
# DATA eysnSvRVduwnZkWkRmHVckzxTdQ1CRXpOK7RT/LAiqxYwdFPfbP6RFISamWqojdrE8xwvYzRabCmrYRldUTV+PWrFskyjd6qY8Pa
# DATA pyouYyzRYqU5YDUaLEtTQ2eXDhq8SRb7mMq16zeegDZZk6L/kl2AOhRm7HI8vYyL+2+f/xNjQjLGjgfj4BbJZnb73eb/tJudRieX
# DATA /9Ns1Ft/yP/5TvI/P9paZvOtYTLdiqfX/ux2cZVOW97GxsYLvpHO53K0hk74JH5mGTSkEKqDImTU4L55moavsXYS7MkadOepMqLz
# DATA S2J66jsms6vPo+kEeYX6+tMMb9Hmz2nGJU1wrHEyVEVJX8JX1WSu+8xuM/URKy+oz+hc9Dx4SDFR0CaAHy6Q2QIXLGNP5cEAeeBg
# DATA gHoiXa0N7AugRc2soofBOz8mUmHFzkM0Royv5zaZBJg1SYmrWTxA5uR5XhRjHd3ZLI5UBBusWsyluqnsKKstyRRLVG0ASnlsWYEI
# DATA Or4H7JADvyC2y/gj9Fip7FxgVyrY7avf6WpRK+6Ka6dfIp0dRBexeWq1HqQx8MxVmM5lbqgPWVPjK9LRTkskpnuxvmesSLXa81uQ
# DATA XTv+Pd2Tl8UZo4bfsnLFsZ15WrwQam2QJrIyeyRXFkQHkZBca1Ecz/CDtK7omJG6Ay1R5rkkLvHPGBh8C1KBRgeQzPSkwXkJ9iCR
# DATA YAkdUTLPgof2tAF95gkVEBEgaAHPLxxr+RpdW7HVigHknxG+8wsLrILVoYayPCQq+RfuBiP9QDmcJjKNSjsrSiu3Pi9xNpI9y/wT
# DATA a4rODEg3B/jL4gSnaGsWg2heZKUc7N/3TwUXdIM9VvmSM4ecbJFxQWDMKCLGkj2RzOooDsfB3CrjMIzH6U1txZWrskIcbLIXZAWR
# DATA 95M64bKk15Ae7RRaILzNS3kqcX7OI29E5aXT5ewxmHMmZpExdbCOgv81ZvdtZ2aI2t50hqaLIX6IsEtRjEvKAFtEHmGO+nyQzhbS
# DATA tzsRRcd2s4tz1VkBwa9pmJ+o4/UT1gV6N4gmUFrVvBLy0orYKUNnJIOxs9KMlntzE/RR/vAXyyQGg0gyVSuKFVMGX5StMvULGwwU
# DATA zbVxGkTIMQtGA7zi0QQY6WPoDIQnA6y3YVRmr63kE5NdwrmCGNTCvbl7lE5jmdZIiuFTSzkRL68ZOMcBbFKevjzk9donYhcyoF+e
# DATA U8sSicG3dzZBuCDwcRhqzC/CVGs8yZpIjZo0Za7nvr6TdyqRl9FYa8hw0KH5uBFqeFIQ9KpBlMxxAUuV1SiK//Ej+5L4IQcPqTOV
# DATA sFwt7vd8gkWPuV8+sMmvydHcJRU7z2P+Bf4uQuXiwsZzMJXsOqWVsE9vnVrCT0UvcdgTITG3A4VEz+aCbPn+DKw2JfPRlB4oqVxG
# DATA rayqbzXlRObdxnZd+o3ANKeDQrtcx2uSwh5B1beMMEl7anlzRWfy841+qLuwuI+zUxmCdXsUNhEB5+5VIiqqGYp6yYduSGJ/AENe
# DATA SYCfUYOUjomq8TuPz8dmxuNyKJSAlQbsnXWynE7Jg8VW9JpWX8TBeHFl/4JNlrgjUTwd0eU+pStqdSsrHhJ9CVSF6y0P82T2LYCg
# DATA lISpGv+h4YfzOHhtcsZx8bMxKIjlpjDuAMvCfokUK+6S/b2j46PD/b3ng+d7Xx+/OhscHZ8NTg72nn5dUoxSDjwPllMsmlWep+mi
# DATA ao6/2XzTYpFkh6EyAraHvFS7HKfDsn4R99Dmx6WKKwb5Lqga1nAg+6sMX+IsDGaxeRNJfV7a/CZ622jfwZ9PSpx2W2MfsYxeS7JB
# DATA djvBo9zlCl/AudAPgHHxj/dIgcoDTFPwgqc9YHb+FqZ5hq+Xs2wLqACvOdlkL0YJHmnw8m+LSVebvEaQJmkU79bTHp5k4AfZLvIO
# DATA FEhg3gzS1/S14hCWdMTRirweZIBU7ZCTUdSorH5R0ZFNdGShYVrD/7TB3ryK35zvbFvha5oHwGW9nicTUeiETqgAiI1VW5aCKb4n
# DATA 8LEfXBLCVJ1punmFbo4xhZKpJgoYe9eWIk02PdE3LgSvh7GaJdFOkd0uw6TlEv9M+mf+IF9JayLmdT5VAIorHUnC1/BUzJrXLc1l
# DATA ZecdHn259/zw6WD/+MXL46ODozMZzfJu7JJPoUzwAgelm5xBwypdaLhM40Jydx8T0d8H0quj071nB4OnBy+fH3/9Yg1IVp85FGOt
# DATA 0ijg8BnFtYs4gQ0SrCzBhBKgwL4ou4ygJJrDN7W5OgyMPGD77gz+2737M+QE39RQ+Dj8oMhwUSxC0r780n4QRbeogtSGdM3fJt3f
# DATA uXk9m5aKOtCXTK7wGa6gwb9if+XKha3NGhytKLW4LzxLWFAvuPSwD2HrZ8nPYv9H/rb/sd+oN9vqj41h0/m9q/z84PO9/a+B7o6e
# DATA HX4+ODs+BtZ/8vlBSW0UtVMx1myUet4F+lmSEcAss83vouRc4p0fc06PI+q90IIBaBhvejYEUVbck18D8q7U5iQqSh/zauZEBPfg
# DATA oD0nhNcR9snB54enZydfW2tqYK2hKQSqivjUSIEp81gVbh/w+WbMW1GKj+1GMl259is6LclSEC8RhebYF2NxjBcmuM62QG5SjqpJ
# DATA XVocLIufifpcaOoz4JQuxr5Fet/lKLACfFrC7Gqe4vf9fR7C3EmVTAUVOlCzSNOav8eMO+JaTlgpJltISZNgKn0p71DVR68Mq+tV
# DATA yazmC7zQB8DVT60rnrJFioaq9m14Jh/bUl1t1yZzzQqprgImMumPKYlVmWHwbJpuUkGYGV6ZG+vfAM5NQsRSZeNubnK2L35msiQg
# DATA dLWrvOJrvHGWw0faRMvJLCvrV0G8T7EMziDIwiTZJeuAX2UP1EDZZ29p9eRUC2wF6yvuB1XGrSweU4tvb1nu06KcSOM9yglHh7Tu
# DATA VoBSSQPOUMRWXQeZZrAkMS+T6Rsy/EqVSoHKaLp3Nr7LV9cz4RVP0KNY6eq2WeUjp8evTvYP1rFOw1P0en+yS6Fa0KtEcwqiwSJ+
# DATA syjD4xT1mV0Mrm5uSw8zvCB9TqlO54v0dSxlY+kTcRiM4kVo9cxLpdL5n3+TbZTe3j2pXnwCX6vWwOyK/ZgcRvw69FP6NPf93Hxn
# DATA Bk3bkUa/z8Ze4/54tP2NsFn9n6GntipuWstj64AEiDy3PV9ZHijL3a331b0eb69oFzzCJf07eaEvRJ8SBIjVsc7hyXNfIWck+jVu
# DATA yxUjxexXPFm+yhAqOSXOGka9tss7M53rciPs6xDTJSvYODmvx4rn4xHqovVY7WANqVLCWQrdo5/dZ93pRs5KrOnMaIsytNlq9wyP
# DATA apzEEWvyN0TRZI6K4m6vqHnjF0EucYG1ST8FpFLWEMKWqG1pjsO/aMdV5cPVUV5lsaosZj0XO0iM3pLlE7DoWb8tH7boTZerz4vM
# DATA l7L8rsxai93PbXvmsbrfZ3v7P371cvBy7+yLUiUHXoH1vcbelvbhFbQtU1NRDbWZredZLrE1u8mqQKFx7by8AoWIxoSPLJ6/LdFJ
# DATA tR17YVXy3o4KBdcoaMy/8pLnXaglHED1YoQi/ur/kQ8D93p3a3aiuN1lJM7pUTMHBR50sAQrhyob7K2lYO4QDRr+g4oZu3x3eIZ3
# DATA FWH312w2XKjyFy5v5G0c06V3ANvPklnZwFflrtYoAHkKW4sx/6NdHuFcoffiMcqBaAVYffLzg6eDp69ODo8+H+yd7H9x+GVeRSjw
# DATA o9heIrcx4USZJ4ZLsYff/ww4yoEqbbCKLGZWWJ4TWBz1VCkUKDR2wWa7V7ciK70IfjU3l6cSzpipYMZSufTu/37/N+9+8f6v3v/t
# DATA u1/67/753W/e/fbdr979ij/++v1/hi///f3P3/8VtPlf+MFv3/0Svv7y3a/h71/j3/d/ywlYSF7KI+VEqVS9Romwj+NgupwNjLGW
# DATA d2g6wZ6VvAr062S+zvJA65D5NOnNmaFcV/11nUUOf6QE5hUbGBmI8svVLHNjHUF/ewt4RbF2u+J5FRrHLFHs2aOW9vbjj9nOtZxr
# DATA O0Xesbuc9Uy4pNUwStrFvT4JHjqOpys2OdcdVuaMa0ZYFs5ySnoc5uCz2W25pyn3kD1vZiJ4wqVQzhUqX5r9+bsmr6fAm5c3uZVz
# DATA T79OCmk8fZxD+iEPbMVK9Yin5BXQIyln7hRN3THYSfndYZKCHnSJfivv53oPrjiO1uwVJ6xgbximhF2/yK3jrVKEWeqKs9S+IqoC
# DATA wrlvnnp+FFg5PDo923v+/OCpAEdh9QXegHWfs7eqpqyheXhXwKygc1Teufudb08lHxD/Wc0Ig14teMRkQMzSlNA7No4KXdffJgiE
# DATA fZH4MbP9vn/wBk9XJguqbjSfBuMtqYZolBHOq6HLcZIxX+rCMvfbI60IATiATFfHn3h1VjCAzYxuFsXXCmXur49w5psAn6X6Jk76
# DATA A1Ghnf0gNKjyCS6YNQqojo5g9cKPHWzc74bmeOPTQ7z64/jka9gcg1enBwbCovHobnGNsgcDGmbyZ+in4U2oR1ROF8mwANkVWgFW
# DATA y9eNx+4el8BReVxyRh7BLOaGtyoPAF19v/uQ0hkwKN+amAx6Z1OlQgHeQhpPy/KVOCB+N4DRmGjWrm7R0vne5p8Fmz/DE2Dm46C2
# DATA efG2Xm00e3elquS7zbXTRilI1gCPERovT47/BJYQKAbvgTErSfn2u36BG5gfU2inOEFBsh5+b75iJ6cJdRUbpz9k9YXhK3JaPRC1
# DATA Y60OL2XRqOF7dtRu4iDqbi6/lMer2lKIm0vJByvtkxnduobnrqv4gsM+c2EJKKuZMjcVZQKrK4lul+8Cz2rfvsR7HaifNSOc17Ut
# DATA ikkeOKDjdK4yrRskq9Rb0lweyhi5EM2BYw75vt2OaU1txxB3IjuafCOrGQIl9g9QegA5BtysiPWuAn7/gWyBSoGZLpBYapNEOpWx
# DATA bu2TdW+q1XNf5G/3v4nFAY1XAK0qcQhgkjfW80nluxAXFt+RxdhRGEVnB68ItaVP4jRQp2m4yIVXHNPIk9CqDSbA25uEZSN7Sj0T
# DATA PZbhzpVfDY8OBuiLHCxSznZH2i3nfP6V6n1OFxVtexqPArp3DWz2MV4joIsZ4i9zVRoVjxKaYw/sEKHrUGorARU1sWm8XMyD8UBN
# DATA UPWX8SzPSf+ciTtyLd7sAOPvExPraIlcPDka1HBUrAD0/HagOb5FFQorj4g77/yeTG5JN/RXrWndZApoGqh2BeczbC6sJIt55aPd
# DATA ogBBDi3Fa0b2Ny2aCRgqp5zlvJcyQGK1G7eHKMqwzsqqsbiAHBPcNMbNqpMvJ5Bxo7NEleRG/NKqY+6gJUFtNOTURhcF8tD1vClg
# DATA rR0O6re0yT9SuHCCG7Zo0LS4s+Lx85U1JjHSQjdlMeDaabicMvUZhcDZJ/eK3CorAjaV3QyKlCaRupWVVVEvPKgqSUa363chnp13
# DATA Yqx0vJxpzQpMtEx/GS6TccTfZkvOSqWKz7oBZeoiZchIzugiRR47eqTVuDAG5Y7p/YPh+lhGdf25JlPWzf01UBS+thp65X5WCUUq
# DATA RZR163NlRVwUWhDn91kPF95q9pQcXt219CA+g190ykTyfNYCczC9ZkgwuAqcS9qrUe5tbqPkvHSI9cHZR2felh+LD7AUevHpAsOT
# DATA Ad28eHj2tfLoF2SCAZ8YSHDY14CXJbvnCKM1IOnk69MYbzWWFB9JVrf5xZo4uRUj5zgyj1cADJLP7wrMQ1H7x0PDDh8N0Ee7NnyP
# DATA XYynx/s/hpX48vj5qxcHj1kQpYwbGxsPfp8qUi4e17IxZPZketiEFZXcs2tKYlbt00mOdFUGR6EUENVD9eK5y/hhkl/7c7gv+7yC
# DATA Vm1W76jItkoFEuaBeEdCJ84XtwWkBzDL3EhKmSRj9U7ZzKtSFNQoFme646qFl+Jl1yB8xDAUr3VOcVFxDf12YbroGslLQTjQiHYe
# DATA mMR6+N12DFPVX5G+TjM5G69ktCPT7w8JUtrNdV4CO9pXXjAWagUfrpZxHJvqD+zcV2/Nv1d9KVp2/fI9epMzSPEy2kpc1S+jkVLF
# DATA kixxxVHpijf1A5oY92l1ufKyq5Wi1VSQ4K+01PsT/XWrNerr78K8ctTq8rAVK9lJIXB33c7vQfFVm8fyYzxG71zVOZUW+YGa3gfr
# DATA nN+dvll0wmyloYnNG/U0H1QqjoJoRqTOJHmPihrZjSVaIj15Ht40OCD5MRiQmjEYoBwfDOQYN1VtmNOhFq7gUNubXy4xlPOSnpSj
# DATA WIuw3cEAeMlgULHexKDnIJBXyoBIBA8L7YJis/uS2LXcfhJZHrU179pnSMKrFJG8e/6Y4yEX93fLmQqbJr8qoJp6uyUq+DTAYoXK
# DATA vTunwtHSEf3BrlSSo8PhiaFcZjWVCCHd52h0NUuCXuJV5Pd1IM5bLwt1qQITT35EP3aCyP/17hfv/v7db97/r+9+9e5/YF7ILzBj
# DATA 5N3/fPebd/+dEz+kbObq8RgRhmWjUFb941P58OP4lj6teNZPb2HCk4M3eAD13f/z7rcw9l+9/7t3/ygw/AMM/mv4+0v//X+Gj/+D
# DATA IPkHH/NR/Hf/BL/8AyaovP/fKEXlNzX/3f/5/q+wBf36XwF2aPZb+Il6gq+/fv+3OK//l7Jcfo0ze+K/+9X7v8aB3/3P9//13T+9
# DATA /zn09S+UIaOGfP+3MiCmzvwX6utX8Onn7//393/z/q/f/10N6OLfYf2Xq3g8I5E/XeD1sqQhfsf3P3ZbzW6u/k+j1278of7Pd/EP
# DATA C5RtkCdb0vE2dvyNZrcXBtvNUdTqjfrtZqu13W1Gw3az1wriIBr2+hF83w67rVEQhc121G91++1GJ4r6jShuNvobmP+4QU7jDXVR
# DATA z4bcp7hhbu7ZoGqK8AMM0NtWOZMbBo52r9/ojSKghmAYBfUwGnVb0TCu93tBd9RswFv9sNNp9TvRqN5r94atuFePG914GLS6AFpn
# DATA Q91+Q/3qq06LQOj1WwUAdOO4EbSCIA6H0fawN9wOou1eHA27zWY/bHQ7w0YUtYNGo9toNLCUVRA1262gPQrrYXc72o5cAOy79opg
# DATA 2O70OgVAxL1hr90OmjDKdm/Yj0edoNsN+0EzbrVDmHDUbnZaw9FwFAXhdn+7HgX9cLvV7wftYavd6A9zQBQU/CoCptGDPViEkmi7
# DATA U2/E3eZwBIvS6rWH3agbd1uddqs9wkuWonowqjcBZ61+AxDRHAGu4qjRaLV68SgMXWiY/QyGdMXmOkganULq6LeAMvr1VjsGcgw6
# DATA nWGv3o62Gy1AU7MbNMLmdmvUa3a3h91uELU6MWCm3ewCtfZ6jX4YtVxI6J67gQjhNZC0e91ClGwP+41mhBdLhZ142Iz6ANJwO+r2
# DATA O73WsBPV681e0BuG9W6/Cau43emE/WYAjeJWJ+xFYQEg2RoI+t1CEonCuB4Om/3OKBwFYWs76IT17S7QQm97WK/3usNGIx6Owg5s
# DATA 23o92K5vA6mG9V5vOOz1+p0wt1FAVQYQ6LhoMRQtwGOvAIwOICEctYDyRv1epw046DZbvX47Chvb3U5zFMad/rC1DevTA5INGjEA
# DATA 2w3rURPIt9np1PNgzH82DKbrqKLdaDcLYAAQRq3hcBh0O9B1vT+K+6NmuweDN+qjdnu03QljWI16r98fjUbDftBv9nvb7e1WN27X
# DATA m92mCwPdvjcCLecG7Oh12KjDmhZAEvbjXm+7CwykiVQZBv1ed7vdbsfDfgT7ow2CrzuKt2ENmkEYBr3+aLsd92GX421fo6hfAEkG
# DATA Vtc6KFrF+3UIk97eDmDJgP57YRdm3Yu79WGn1WzFffi91dkeAgttNoaA0HA7gGXrdNqdZtiOYG/11kAxCIGZjdPLNdAApfULKbXR
# DATA HY76o04nrgdRPAS897a3h8A3o1ZYD7rDdj9udDrAQ4ZRHUi1H293e4CooDMcNsIgbuRIhBT+gSRlJovbdfu23SlaoKgfNYAxhA34
# DATA X7fTbndDWJxOOxjF3U6v3olBmEVAyY1ODJs0ipqN7bjfrje2W71mI+5HOViUaVwMwjaKq6ItM+pHnagBiO/HQQhrVQ9H240GMNdm
# DATA fUiE0mk3o1EjAo7eAgkEtNYFAReD6GkCR8sRCVcvHZA8X4eLRhGVwG5odzqNVj8MO6047HeBtTfq8XYDiKdVb7fDIXCqUb/Z7Yzq
# DATA cbO+PWptx8DXW2EPb6LL81Lb7Fon7NqwuoVMvYlCNoaBw6DbCoNmC2i2HQUg2XrdKO53YN92Qb63u+2g3wJh1wXOFzejCF4KG531
# DATA gAzMPZZrUANMoYhk+/VGUI+D7e1GMGy3G81t4LaNqNOAH/qdYdgAjACJDreBvzRAbwpH9W7YBRWkWW9vIxXfA1KUoom9jtfDFi3a
# DATA Qe1+vQPoiIch0G83AjHcbASjVheIFDYx8Jluv1vvAnQgqYGZjEKEOm43es067KN7lsoUMFzHc5vb/XYRSAHInSao8aOw14Zt0u7A
# DATA 9mh38a5DwB0IQ6DroA8LFrVGoEr1mq1gFIAMgTkEvUb3PpBm9wjDVnu7XkTMYdBuA7X0h8PR9ggEfrvXacHIUS8OYcCg0wPJ2B11
# DATA u6AigVYbBe2g1wah0a+Phg1gNLkFW4zXCuP2dreIrTT6PSAKkLcgW2GbdoBswjBsARpALPVwg4MGCQQyakfNOBj2+xG0bIFEHnbr
# DATA vVZu+OXoZnC5DObROk4L5FCkk4xAvqL63glhEwWNUWcbVJ4g6DbCBihKoxGs1XbUB6iaoLnXG2EfVOlwu9OAfdWpb+eURnYSbcJa
# DATA rNcJOqCBFwBS74fBsAU8DlgLkEnUCDrAMZqjTrMfAPNodQPASnMIhFMHxaAFFByDqtaLGqPh9nYUb2/omw8ImA2+2QmJkb5e88W7
# DATA RIW1Zq0Bg3p33vf+8O+D7H+jgP8b3P/dBe0sb/+DKvIH+//ftv7vZ1grIpj66tDFXBLepPwvlg5KJpMlaRxVPx2NqEYa05MfpniP
# DATA 4H11f/l6TvUtns+nqfpy+bNkpj7jRTfjZKi+JunvXhz4arlIxro+cDBHP4X+Gk9m9ncuGYz5CSd7+2d460WRw6zkPTs+Pjs4weSM
# DATA 0jfT7/snBy+O9vZfnZ4Nvjh4/vLg5HTwZeMbaHZw9JTafN+HT4N1rfaO9r84PqEbzclViyfE5sON8qeTyp9zy8Fnr46ePj8YnH6x
# DATA B2x2t2TfAlL6wUbFe3b4/OAU01FK+Q1e4jxPUVXxm+2WyDvNi35z1AT78uKSsdjwHW3I0u2RY/UpJ0t0S8v2Vi582/JyBsrpuSsQ
# DATA zqyR1+uAK0+1OkZoKXCU4O+OdUwTsiQ032m5YpToCYkB53y3TCn8Xfxk+FF7rEoV78XeTwYne19hafmuW0SDHuGCw7Nm7lHuZFlU
# DATA xsVWdQ2xMncUhwBH2amIIZEheq6uOBny5SZVInBdpk5uK7E6lXdl29bkiC81wIxqdVmuvC/Se/A6Vrct73hri9KVqNaU+k/5051N
# DATA 6/QDfj+vbV7YP1U+rnxaUjHSe884yP0FwrwEKl2cCfP1B3hDQqyu85BETQz7LOjqyHJpUx2iodyLUcJHxBbLGWxerDGOoRWM8Erp
# DATA RaxHlGSADqznyJVjyg2uU1Tx7qs+oM5uGmhU6c5aSXftrCPDgHfSJHx0bG6/grf+Iq6HaToum07hV2smulQ2kAptOkEnS4Rdm8D4
# DATA sVpF3qEhpjSVmUdW/B/5jfsW46m+mU+WY5Smi3huzigJr8WiI1MnzEZfq9Lel/PkMlUZPF/2kNvW4mnE2TvAlh/MMT40tzMVQagW
# DATA isRhMpWH5zubeKoH+79gkPB5UQllBKuMD+2sIhQZT/fO9vySVFC0NwY+3N/b/+LAt+UAbRD1vdW8o72A/VYqjzlZ/2oav5nxvSHO
# DATA LH25qsisB86LRZaulMNEQJmF9671C7mQ0egYMlYwDUGBcPkRL+ccLw+flZkN+Z8wPxL6VBA7NCpv5yC0SLlyXpclKQ83ShuV88aF
# DATA ZotUHEqzO53Qcs8AIFCgm2IxvUHw1kvAnbtt/AzDVe1dZeokB6p6yiR4k0yWk13F5A2HfLDgZv5o+Sr+v2Bs02kHrBiGOSnLcTCn
# DATA mg7mjL916BypkQdIZ7DuJSC+ih9k2CwOJmYsugJvV36mUwhlmQn02XBoh4QDcAV5/gh4qdbZIk39MWbauFSSl3X6ugWuk1GeB9Yl
# DATA Czg8/gCjt5q97vZjcCUdrYwvM7bOuWHP+rhzLGIS98TbEluxdIe2CJsqVvE3YbiSrtVxR9eVwqvn6q2LB/fVq2m2nM0oG1XtKAV3
# DATA qfKvL2EZOjWTi28va4uhcrRbNZqDrA8akoUWXTjuVnvhjhnrTskeq/QUPVWVp2S/4dqSwq1PFXJJFHW0U74hjd0PZl6usBVVqnhu
# DATA qpxSAfhUzkraWDEScfXMCdHNC1hj+Gl2+5eg4Vf+UpTOv2SN8xtQOStydPQR4tDBLgJFNXNWZK2FRS5WoZGIKCO1RTaH3gHkXOId
# DATA 8DBdYA+mesyHwq1yZl24MTmpzB0zLJiTncm5w4WCq+7/0HcaIR0ohv2BcGChPLMbsuXEHd7RAZkAVN0OpDCxEh7Bx5i21nFR3AqW
# DATA LOJK8ZJQBmytKmXJpGyiIwff4urvsAij0/O6OhOf1tFFzuhsuRzgeVts9shlY5L2uFqlxz4D5HB4vY3vlKUh99WVRUmkSdiVi4R9
# DATA O73oir9stZCkwDpFrppB/Jlb5BUEal7Er+7nA67DBfHkMAQ/SrmIGu6DkiNihNV8tKsFjsbE/eeZV7U9vlh8Detxel5lQfryS1sc
# DATA U2s+slJZqTcv918i5C69W8hdaVNcKWo9yaurGSd4XyngzrrodA3x6+v2VsgG2Jc5zyFTv4fITPFo/VJB8u1KB7iJrFdgEyhfVJU1
# DATA lkrV3qBWUxq9ki+OIaUQDQxr6p+ZI92ykrhHP/5YZq5g2MEx7laXX59DdEF3jt9JyjSn19Nily1aUWtdybdXVeC6CKpo/ZNhHEU5
# DATA rd9SqnN2o5wZz9mO+Qp89xiRVdBfwUawLToxhnHQiBx8Jb7nEs2t897ORYFB6BiBtA3Wm3yOcqSGEeVCviLz764rrrpe6CjcFUif
# DATA nyVyEp89tbVhty1WkQxZ1eRq5euSfYAO3Nrn8B88vkz7Ph3+dDdJa5/hOh8el7nvSqHlACSVMxyU6ytvOIjm/giZd+BOM1sRe0oF
# DATA lDPLNAtxDbOhUzAJHJ5PF+yW5jtsBkkGtoFlghgmV5CqOAhULD+WV9igPCBdsfUQVzuDOYC4us0vYpZzRHCnJCK5+0KXAz8Ds1Eq
# DATA /eoXa1K6V3sZzRMlehl7WGNkq2TGqenKI998k//5cR4IvGZ8hUQFj6X8SRcULtYIFxbK4zfkq6eZcZMKU5a6oeNmoM26XdGqZums
# DATA rPhcZR131685bF5d1bT6XKtU0yieF8mUMAAhZVfDe0ikpMvFbEnnBgxhVh6gYX5Hke7NGsotlAFywvEhUZD3ak1HKR80ImDOgvkh
# DATA /FJe1eewIdFblT8ihOojRiz8XUdbqPogCNpt+FN0LAez+2nJ8f2qjSBXulh8W3M6/q1MjAytsnmcZWXGG25gUrmxogJBtVvXFbVF
# DATA aLCg0FXbcFEfss8edN1RLx9q1dBLfs4eEzA/4UgUew6pIAo2rsnUletLu9jyb4qIM2IKb+RlVJ4nQN9vdui/yLXr9QvVDdsv9ACP
# DATA QAXTyxi947Ykq+ILbj1JS5pDRwoKDKIpPY3rl3OUS+wUam/vpXXeau2oVqaduWVBF6zQHsot/amGDgQusMH6S0WzE4rdif3jvF0q
# DATA 0OAUmeQMGO1OQX1X9/Tlwcnp4fGRGpgre9TYJ/oYV5/0KoXEOJqhfiswK7RczBl1ljX3QSaciwm+O+gxRtxjWKHtJrafKhLBm7Wp
# DATA 0oY6z+RUAV2zwA7hEBmasirOqn/XmCKHkyBG1u+xZGLbu9oViQk1xhu5ozrNuyV31pq6bs1jXWhY8PG2tNKBZuJi6+04vP3uXgHk
# DATA uL4qd3fWxitbtz3gJKv0DoYY1b1OyH6mi92mvtRd8Twph7ziAlDr/0gXv+Uu0D1rb79lk/CpbcsAsp7dzzoqzmsEp7oRklqrLcL+
# DATA ApEdA2aLLMWUz8bwKvEtrOFPirwtY1N1rtH0CPOXbmTjMkfzsoHKuuON4szfvKnXOdJl2qypA/RIEWhOqqmLk3S/bALfc/WXaEpg
# DATA H3c6crpPGbimG0Ccte7eQ4VxVk6Am8ZFIZ219RcfjYbLeBqry2683K2rqz4HfZD6XneDKj/pehrUGUB97s8+DFhwBpBLcL0EFSue
# DATA X3OhrSjAjJDIArrmS6U4nxJHMtilt3LVDdXDzPUmSUq4w574ksNAVzAAvKDrwlKNqIjmwuQwGRKpFZQvyq912fYJ3l8/TvS99aQQ
# DATA Y65RQByGyoGpJCSkTPyMYflR8ma3VBMDbxOjIMl819pAlfWU9Ts6c3TNcQOnyCOHCSm+/Zj3tBOn3Xbb66am2r/acveWTkgzffZe
# DATA 9VBctENoU0gT7Z4YPxTe1ExPapSZppxGb+lb7eDgJ4ensCXkG4jwgxcvz76+u6fEysqT7/t7U7pryQp+4/VNs+VwnGRXtA0ylPVm
# DATA D6j7Ra+SrKC72TwNwUrBw/hUPmQBWyZeAlPgK/18FVxSiR1Y/EHS9Ipm/7swo/sZElCKOu5ewJu4HgrhvuiC6H9dVlVYHwMnr+lw
# DATA fYEEp1keTeaJ3F5h7lH5yOYk1u8KufpNpGensozZ/o/GufhQlHcPSANZqGTaFVSC4eTI2nyymMfWZrJ9Da7qsdaTIURCG9553fHg
# DATA 2mlK9IIO14NpWfm9FB5IZ4rW7NIBaB1QPTWMEZSqWu96oGBAvobBvY0JS49uLcHfRzdHmvoweHhBVps/UNpAVTPQiKRqEYRAQ5Zk
# DATA bem6A6JGj4tfZZxb7zrG/EondsEDLlmgtF5qKmlCloGmqx6wvspfLI2YQWK1uPJwIQymzf+fnDHIp95+9/n/jUaz1VjJ/693/5D/
# DATA /13829jYOImxQpWfLWd0YU0cWZWROYdbalkH6BTAhNAIGoeobIyWY/tu2nvS/Sld/wOS9JdD0Wf0L7f6I/pcPe/k4OXx6eHZ8ckh
# DATA ZbrzgSQpAYP+hsurcF5L0q1xuliASb9lLrDVZWJWfspf27S+j9XKMk5/BTevcOdcmuZ++FT1mtwv0MOdx7ch0oStuV4tFrNsZ2vr
# DATA EvSE5RA91rrbk9wc75xJGnAe1QXDcecdvtj7HGsD5s4oiI9n57y+2Q82R5yYU/GeHuw9fX54hPnpFF9VQZBZmiVU6UjfaGAy80p/
# DATA XHKufFuJ1JqLqCWX+Y9LFJhVRcrzrebSbEc3U2AA9QfjAZbLLjO5Y6p3uqBsiNVbWHR5HevOIXoNweX3LVe/TqHGCA0+5GKOhxHf
# DATA opiPCSi8WpEB0wWpiFaPfK8Aw/nALTXObahlC5ATWISz4DIz1T0/WXn+lCxd08RU7L1Bn+M5dC4lzkbuLX1cItFeZarsZm/cc43e
# DATA iwsbGdB1vojw5SUVM5PuEna25ru34KADSkxI5v7Au5yfgHgfqsRobpE1gCPRVbgW6H4wzlKmFLKsMnH1wO9JkMVZLdfr3nUKdk6Q
# DATA vcaen1JRPfRIcAd4poreg478n2LmLf8eYcfxeOR2VozjwrlxYriLD3lagL2LgqJRqjKjRXSYMo4nPJJwUUP2jW5UvMq4UrE9PmMd
# DATA 01Jrv7PmNkyLth55yUY6v6TwpbkcpMadyHWk6+7QhGkLs7SIrOjezLUzPzdfLtx4FL+kDsHQApc/RjWySoJuwMpkLjsO9Ua+N6FV
# DATA Rzg1W3Tu9da/bpKcq01SQCx62svWNTKqqx/u+vW8K/SMi0Mqo5tYk+h3IKuDiNJQQD0G/Tcyt7GQ62DXkru1+XJaPpeSkFjmDqd3
# DATA UeUkKnGLhsFsgVcoy3T5R4w1qI8Myu4EFOZWvWoArzh5HGrEbBFBa8pkaT8+lUX2FywJrDE8QxdPHGV6zuNkkizc7EYrRzs/NoBk
# DATA rSAvidtGVn2I3BmsC86+VHfX8Y1VfE2nE9yUZhzbNNO5TeJxxIeJsJ4/vLnD73PUVMbCan4Dli3KKE6oALyQXklVKgy4NKEuBe4k
# DATA GamlZomxcn3b5Txd0g0EamYwhH1pnnpR3z4tY4PxhZmD+StY3r6tEe3dYWrux9S5C46zIrp398rAslW8kKtkSmHa13E8E+Dw+gBg
# DATA 22rf0G+WxpHfRIjZZn0FFw6KFXFaQ1rWqaQEZm6yP3lurRecyNt9udC6P2a1D0b4X0pFf6suueoCOUnCXjb7vtX8ynHypCrcbScU
# DATA a1jWX4Pr3sRsJ3JjSLlIgcGjbqz1TERPLlWsK8i1zEAAcF13HoQ8yoGtSVENYGhS9+5yZkpYKzqwVyDtVnofF+82VSt0AZwzzO09
# DATA l+FZQ9JxOLR672NxOtNLzDGc+zBdTslWc3x50sDRTgs2thne0lX5uC7e2AaC8B6U8mZei0+lzexKVs7I0Vqrjn44/WD1W3le87v6
# DATA R7t60+8UFbU80TJTUASMBzdPtLNeOLIvcxcsT2T98XzuqhpDaPf63oCeq6wXcPEHrxH/vq/F2wjeR5Rtok+fLY4oHsdoYT4BnuJT
# DATA GduqYoczIEJKvpPq765WubK68wlVsjV32ee0Q17ST3b9xuPCfJYecao/FgX+ZHlYTTFrIrMO0+WYL6BDN/b4VqnQyWLd4nB/o9I+
# DATA LiqA/FZgv7P9G9qgFWJ4ouvv0r3jisHmKKVU+TbO6Q8uY2ubRx9SEpdlD0YG+TKjXWVfrmmPrNYqcMsKsPW6svQe8AYrSe0WlhWn
# DATA qrrtjL6QzP4P5l799+H/zX5Pjt/H1X9p9hot1/9b73V6f6j/+l35f7+UqKrOBxS+Jxd5sdNVfCSobi1SYc/3+XtzdVvudf9W/Zdg
# DATA Rb5Ms+TNGm+w5fuVei12/Qk+6ExKt5zlYu/Mbr4MhZUYzfeukZ5+/0FmSky6Wk5fk39vARx9HEyGUbDjHFGwbNUK1sjIR2gZIqXG
# DATA Un/ukSN+XlAhQ4W8OVS1CC6Bm2ZguSnVTS5vpvmYKJmVzm7ZKNRgSxVm4ctAVs2UMSxu4Xuau2+yi2V9F1Y2q1ytyUmGXBGAThA4
# DATA j4Xy+DnM8T5l+N1/e/dLru2tCnn/A/z57fufv//rd/8slLn57jfv/h6vsH/3T1gIXFfyEPgz66Bf7gpqufzTPlNnnsn51EeUmb97
# DATA cAZUa1xmQKXHsQD5bx6YASVOk279NjgvUVr3xY4fEJEGSKBMGjwn/mwuEgpkKegKTr5JaDnDBQbVxlzVZ4lwyYmeWohbTQ+aJeig
# DATA RJo5Z3y495TjKPwzuVIEd46vlwO2BJs+DU4XyiRTOws6ndst8UaHZGE1lB8ePAv47v9QeOV67oT137z/GyIprOQOn7D8+/u/oZrw
# DATA 7/8LPP5HKj//z/DSv/CRwYIC+kIsFoh0DAHtGGBu6k5ZJqBgEnXbSDjBfAIf7h6E+b9h4fnfIJG/+3ugGoTlN1wWH8vSA6VYhemx
# DATA 3v27f4ap/By+/+1aeIlkAMKqiV4Q7Oc5uC+KM8LkurORFaR6q0e523wLm/huE6yp5ZvNt9jhXQ04d+3yZ6VcOtZMOWBG9wTErJ53
# DATA 3jKUuvDfhRqMhymt2GDG4UwX59ESqJNJ1kM2hZzzvY/JsrS5ESwELMOv3v3L+78r2MW/WPVU33Pn+iPR8ccScSvx1ez5E/FmevrC
# DATA TXa/fOjUmNH+4t0/wpdfvv9rH//gByAzmN29POvxx15ciE0VALwtrbgCgIo3ru2EPqpo2wfPGrbU3/m0135NE+XbIfhnmPvP3/0L
# DATA /N8vHrHWxIrpchfi3wQbp2QqWWPsYUz1pP1QEJF9yzz9fMPEeWADbIn4zLb+P/betjuO5DoT1Gf8iiQ1x1nJrioAfGupyKIGTaK7
# DATA YZEABwClboFwTaIqAZRYqCpVVhGEIJwjW/Z6fKwd27P7YXbPmZ312f2658httd2W1NI5+wvIvzC/ZOO+RMSNyMisAshueXak8TRR
# DATA mZHxHvfeuC/P7Y1Oh0DRl/FILBcOA35OM3MwGZ2qC11Hf9KZTQZMTqkL75lTIr4i6YTK6dkHAoPzXBaQvRghRo74SybEP339T+rv
# DATA v3v9ZaRm+HNMP/JLzAICO/E3r7+IPupPP54d+AHc5VpWMQaKcUVErkQiOGCRPXqNCA4aTO3GjVtXOi+8GWAAP63YJCwCaoFEh6uo
# DATA Ne1Oi2Kfk9AHSF7S8iW+CplxSeS3Mk6tFfwoMMr/igzxl7xIlFOFc6BEaqHojKgzE2Gtih5GVKsbSqG7uydFr31hqbPqTB2EXeBM
# DATA e/CbU+DyAYOEb7WCPLSnZaF9HLuWnEA44Y2LrGHfWY/zGzfwpRMVwx0xUglmYEXBw7zTgogXDyP7rgoT643h0LX0zgseSWgCt2TL
# DATA 3aAa2ALtcZwdqkb/MAXkjTFAoyrlVlQvtfhUbXs1oYviG2cEhMJAk+e82Of8oOazUc7kAqWBuHJv/W1RhFH0VZ4Zh1aQbKaKgxQH
# DATA +5FS/vxMYJPhqOYYkh2pk8fkyJ0L1QJaw0I1Rak0MOr/hL3+UzWQvwHxQcl3RdFTPfpMkZWfIR/6wpsSEF/VV2/+UhxFeOhcjZDe
# DATA GNjF/uFZh+NkGWhM7pl+4GotRrUIisnOx2sNVShE94Tg/ZlaSSLtisjHZYHL1MF40lLy4zsOs0fbC2IQzU5qJxTrbjKzinLfKuMF
# DATA 5bv49WfBwatxw1r9B5QrfhNBpi0gmerBb1//i5AbgEbljpV2wYB+Fs0dnUpNRMYXWSU4mvfzTnqQjwazKTujx80mumDhWwC6zEti
# DATA +TUPrRkIAQwLEDgBGlRgcQFMXWhQiFS7Q80Xi5+/w+3/8yg4sZ/HwXHpEeQLNQ287TNgYpB/TB2lv4IMaHScLtU4tggady/GHayL
# DATA 5AISgiaIjU7Cy9PK4oz+ejQp7vLCxxq2IehFUT7zimg4Fc0RbnVZxxhe444Wz50uXdQD5QDC6LukqUJ7THLoera/f4nDhwTGyClA
# DATA DX8JzOH1P8JBExTU0Nwv4UaDx1KLMKUXGmJwSB3LcCbEwGw67cKayoqC61pSz9WXl+8zf65G/Y/EYN/8T+rvL+astIV0El2WKBra
# DATA cVPcCjz1qw4Rk2pOwVX0XW3+Gv9nWFa4k6ll/XPSzNChvQK3wbFJGUroPW2IMjFHl32yRbzG/4K1WvLQb0YPB0pi63etCRc02Dm6
# DATA GlJbzGTvWVeOnlPKyPSsHiZRdzAYnZIO0J+4up5Kc9vfN36v7B67un/heCLovtsTaR7hhkNfC74ocMsLOGNhVsZ/xNP2z3C6yo6e
# DATA FtTAj6PttLxUWJdzX4QmZ5A1R/hUUsIoN++2cpbQ8dDop/oMXYSXNU9fZr0aKffdFb1+/fpD6BGujTrns3SAlL7H9xT2kh9q28b0
# DATA OAWNBUe3kYOnpa5gPHF5ggGf4lyvFo+oKAvg8dcuFuVQL3oYjFL0kwqsFytVFF7/Qaowzl8w7e+1JTRSpdShUbrwB3qpWIGTCPi3
# DATA 3lLJYPORylP3T5gLFTSS6sgtoKAqE1guAxBVyopKvVvATCRWHGwFrhRTrMeeFituVMA8+Ynj3RYt7nfMUlPEsdK0NfdaN1FJUIsP
# DATA BqMDSoRAV58S/x1ikAvCTnkzcVnG2Z7HOF1ZpQCOxZUuhQVM2LRajDOsgR9cWlT7vYhpvsBC93d/CMwMrN3SxMiTU3blIMrlkMsc
# DATA xTkCyiWEk683gzd5DjlRtFrziCcFFZikVSTENseLMEY++y7Da6fpUbXHkzGILlaf1bHHv49c5K66raqk9uJbbFio6ly0sPZsvWoa
# DATA dB3wS9+TtjmwSYTGmRbJ9T+gKsi0HfSq1mpesWSE/wehw+ZZIR879wqOiulUKwyO4qdQLyjVw8nYyR1RIBKxWr+iOj9HO/+W20G7
# DATA E7vtaWW5P3FaPRmYt5DTqj8z+vQWmYunRsQPYXcZilTgvX7dRANKa2ZRnFw8+8PmwQxQW0qqz7PSevRNzZ8Zc4XVE1OoOpTPXkPY
# DATA 1CWgIfm2lgCKMHvFNvFEFXtKGwVQkfD7ZI7vMTGjnbNc3WjWX6n73eoVPSadbEa/D/8/JS6+f8vz/1tduf2H/O9fm//f7iQd5nQo
# DATA 1YWWcmApRgbRSzlHaIA2IZuoG6wN9lZ0CiTn0WxKZRFXRBUBj/d0kC+e+q07Gp+9fVK3/pHqvPk1TaeLR5LrVG+TAYjchDzjPgMn
# DATA bLDMYn/4GY4osuVQzVKHv2ZD/NtNIQcHmfKyDBWjnEJYGBx2vEV3UJemZC2LBsOwMYpU66FSyjYxKi/bGZAe/MOMbcATGM7dFpnp
# DATA P1E0QEdaKO4Nq6NkyS4or6InhjyQzGvpoNWJrEW9fno0HCnBuks6DyU7I+zMdBTlx6NTs1GQyOFGQWl2xj2h8DfcMWz7Vh+T5Qlf
# DATA 1aPRmHanE1HJAI44hZTjS95ldBIcV/1A37St+2eTMg2Zl5Uoc/5sLKJVAG+RP2XvkX8BQ56b6kSPjLIhzE3eU+zB/60uC/8CGrZC
# DATA Q2gCBDcV160tmNZHpxPScEfYnVqxP2aa4IghomSnoMe4+Xa9rrSPWfsouFWQPvtL3+1CXcde/851roA+G6hYdQObdlIEsJBew3wg
# DATA TF4+ucls8r4ObM6adR+uRzYyg3GOxQSRa4b6GCHN02lzp7PxZOvReo2QjqcdeGd9ZqHgH0UrI8UWy6HpwamNv1akBW7eI7zbZurX
# DATA Ijvmf8db6i/UPKorKd07f4U+Nr8FHdLvwL4My6Kuob9WM1u4k//mzc/I/g63738mP0Q02P/6zX+MXSDIDs81X1V5th0nixgexS27
# DATA HwEOlCJZWhHBP8eoV+Wf0U9gelZXMUHjS3XXArUuz4Z6gFdMgrTQT9VvPwlIuF8tq0tVE5p31RHoc6dQrhtOIW7eA8iegU5FuMpm
# DATA 6glqe2tcPgyFzVkFYI8cjkCtrolOziSuID9iQ64CkffTzuPN77r7yehOTZHt9Y+KRczbRxvbFW93th569ZdqXBcnkLDtkCr9Ajbd
# DATA r+SWJBu52JRhR8KK/hH1ko/oVL3/Phk4Sg/PJQb292q/k3LnH3BIn0dv/pyIGrjkVg9IHSf0/v4n9t/VEwEfKUqH9mZQIP0KPHjV
# DATA I3J5q4kG7q4oAcJr5YsI8ncYJ490PB6cdVxqR/9AVBle5B12qi8pWKRVkjcE5YgR6JBGOVkaqPweneP9Ojzf6mw/2tp8/Kk6q/hL
# DATA ba/1h7tb2+bB5taHW48fb32fwVTlJZTPhyp2iKfDtulYGWvOmRdHHTWRplNMIvbrkX5C1GHf2eFFgqwtXqYiJkmiIiJK4TRTl6W5
# DATA X5CXILr6/JrdDWBXAAFmXycgvVRcyBCOWy2uaFh7UaB3oVmFKSdsPvvWDldPAOFPYFvk0e/Px1IQV1FV3h0o6dJpmWN4zJWC/RWF
# DATA 5gME2k6/J0HcC9EFRb2a2E1kWKR0wKR6yXrcDNftzKSNVYc20iG6c3krzAggDM+sLa3LqO8jK0JdS+tknqgqmlBKJRtN4YKSm08K
# DATA g8wBDrrGYwAA2oDPiCPRBUdBjlVOb5kJe71SHQ51S4xkqVC1elWoWz2TlTuLqc+cpzpdQKL5T4pC/gNKgOg6qNuGz7XAWNwliZTv
# DATA 7I3DHyPOs+2knWm2w0I0DUxNYQ5NCBGUoE01G2qs115sKFDmRSCRMcX8XESeU0IZUokvyRoRKcYENoRfkwO1NZsgV0HX/X9EB0P0
# DATA JUTRG2NJiiJznXpYB2dY/isGlGaSu/DJXgz6gh1+aNxSGXO5c6yuhfoWZ6KBgVS4XEd4anNhNfdJQQbGd/hQ3bMBtYPv3fQRWtFa
# DATA y5SDhp5Q0JH2pIeLj3tTVBU0oYtof1TTTl2saJe/malZ0FZq+D1Wl+XT0aRnfqubxPyV+1sbT/GnUnnimrqQcXwJK6rEgT8jD3hi
# DATA ED9FjvCbCBdSCSIctwSi+pu/RJPTv5RfQA2QmVVZ1GrQd4zV08tU5+HBXoC/fjTLAOkV/jycpEcnNo2KA41UthSMtqSx2FQB9krR
# DATA SDcYINnJhi9roJLl5N0SXudFdsZPTdWhqLR0qjoPkWmT+E9q32llr2BF9qLn0/33ku/APrChNqpGjp6B1zfazRv/JpZkFNJlZ6Dk
# DATA rnGthHEEUlTziUdX4QWB4kGSAFOeQkajTgu6DzSkbbairuxwkB7lbayywp7A9cM/OhOyToSM2VXeKzbArxyoXfU5T/h4Mnp1Rupv
# DATA 6odzSOvRi/6w1467aa93Flu9i5nb2nfuXxNpRZuN/cSdXKqO5rf2nUJZtnCCrhE8mlAeZVnT0JCan8B9OBoORghfTR8uuVheIEHM
# DATA hnYZhqF14OHxEpjJ35BOYbpX+i90bIeaH4iEQy4iGG8ZmDUKfTzqDx2fd33oeIfApJwkf1J7nt9A9PsJmm+f5+8ltb0/uaf2au1e
# DATA UoClFN4QNB5OZoj/qLOEC0BTR49uIq4f/X1rn3ZcyIKkRDHkhivCYXUo4WT83Oa4DwXODUA8gE8FoVUUQQnJHk+Z7ogEfNNBbRSn
# DATA jvuiOoO3ufg8pkhUqgQe8d+6pnNdUzEbjhtcBegkhxRkJXtC3wccTobI33lCqQo8b+eoR8Oq3Fhv7Pl7xsOiiZsGGkiihv/wwrvc
# DATA 4jxqNDrM1l7cOzK7YO5oE3mnzuc8fw9MBW6XwCF+iQLE5yAroJDwJV4zf0lPPgNp4nfoq/CZkij+Rj39DTKdSQYxEhlRkHvyEoMX
# DATA GbjEUKgGKpTMmzd/HZdD6Zl0mwAHVI+EWqYgpxFLMophq4QDAti2+iRzJNVjljChcpNbqJCyvJDfp6gcRVZm9HHYPVnlnmprHxFa
# DATA jSarkFkMc4HrNPPYBDZfSEAFf5Wff44tOiGNl6eYNXqP999/v7wBBGK/kCuieq8za/b6OgLErAdTj5ac68CqLYVnxdwTmYnphoYv
# DATA ETQN7OMoSNZtNg6bCG/GPpBYgqRm+JDDehGctEqmLAKsmTr36C8HOnbP7jXU9toOwY0AP9BaDw8UjZkKoaLhJBMHI3hST3bRko82
# DATA iaDw05+MhngjphlV94YpZePOAxJRSZgDzxMIeOpzM/F7WoCHJUFfMKF70cSOLzPaJCR75E+/fhELtwJcStRyFpaV+gLyGnTFZuXZ
# DATA d0NcFpPyxNEGcA7qPus+sd1A1gYspE+oleu9a3Pgy29Gu8eZ4rj5NNK7Dk5TOpsejyZ9der6LzMOPBxmp9CpeyzOUjYhsnuNAbh2
# DATA OhoVc24cavNUf1jWBdSkTPpHiFPbdo8XLojQopvAPlr3uqBrvhdIYPzAeLETe43VfQKW1UJwmUBNgqeRolWLuqtBSdlx3gjSGXEX
# DATA sDWdq2ZatG4XLqyiXf7yLSrJn4dQS9/sOeX30SkdqtWHFGwC2Csg6Ix+aB66edAFdmrMB4kgAhXD/KHa9Q0MQrUaEn6MAiADHfIj
# DATA dTi8YFJbiT1BdXZvF2cKmjuM65xsS/dSUxzw9YLjyJNOg8E7PQ8Exhi1HcMwdiwRTuquvxEbk2tQVI+V/c3iG7F1xddQiX0lC03G
# DATA owF7g+EztQANtIPP2L3QgRWVuhftFR/AbNzjBOFaLVGPbghdC6jG+100PjM+ivseHXd3NJnEAvtem0g6i+RXOoDTWCW93TcqI8Ty
# DATA M+79FVRcA9NpJaZ2ZYLoZFwwoY+BTwWcgG5nT3v8HoxGg5pEuuO/adA7U1oFQzg44ZaebdgqKNQg8W5Funn8rIVuHEqeycbwR422
# DATA kbTl6dBkY81zP6DX/j6fcBdaZjB2wDmPOL8QsgZ0EoghC9Dw0yKNaupKe4O39Ye+GOhJM8j7CycLZAAr5yz8CZOEBrfdPDsZxMX+
# DATA 1SoqwLSPzekrOAxkhMZxo6OsXyIp5Jyt8HAIjKNgrYXpNHqDDFxUiip7rU1zlfd1cEfpnGSKV+oHYE1HGVX+BqbCv/tDhDiVj8hZ
# DATA TXGKSXaaDgbylmmUeFZ6IU+mmn5jc/KdjTE8T1ZlOAOcEeAhNcqE6hTiW6dWBV9rL66h/j/UfetXYCF/85ds5/ncuVeZO5NpC25l
# DATA qLdTpUCV52IrgHGeblgQB//X1qfETrMj6qNBNNB1zFVlPzEqeNCYArnVkgvS7sFo1jscpAgyGR914VwnC/rI/JLQi1CZCQA5BvXq
# DATA t2gL+4do9/FOyaDU/h9NekYTzSadBaxGVgOvd9rCU2K/MDMC0Pz5NEvRMAGCfi8dqC/fbgZ+Sg4WoML9U7h0w63cH7/2HjFdcu0G
# DATA 0Ocd9e6JdjM3/UzC9jIaJIx+wQEuNj64/n/G6uovq0b3WVEl/Ys3f+GPGlX2ePbFiYafNUMnzNLSD/9iG5ijp5RQ6/btW8zTXk3S
# DATA s2AjkviQcCl/z2lqgwpza9+yzc1bCzRn2pnHFxCIc+5OAJld0nEfWwDhxc5W3Y7pAg1Jt+Yv338lU8Kbv47Wnm7UncUC2AnGofhF
# DATA 9ImqueC6YJEn2HWBFzA/TiekPZ1jrWVnjZDlFQmxI88EjGVQK1kMsSZRSuR8xWgpn6H65bW4LUpbCdxSExxYwcZsBTI7gBb6hpF8
# DATA MhrAZNSMxcoxStnRE9NivCprmlrA6m08CINTueT5ylvTmZgAWemzCcKc78Vq7Hsr+5frS6E1OcuwVo9omMW6eCXJbgfHg0smrtek
# DATA mkyXGVfMSdUABXGjBXKnZa/4xb4zGdWdMjxl/hn8zxbvJayUrbTcNqPXf49U9S/Rx+QXYB78HItTsByZxbVVEfACv8RP6TlzpV/w
# DATA w18ZAB2aEk+eUg9RXwkvaZliPQtWCGub2XAFEsN5HZ4cCrQrTtH/g7F1fyanhjywEC3HuiSSFVSQooO0+2I2Fv4L9IBcKPjENRyY
# DATA xDkZfel7Thytc0ODR5ZMIm1VoHhrQgmd/BwRplVrBZCKtaT4EqupU0/Uf8HJkbZ/y8rVJWnWLzBhGIhK5iddhlrq+qp+jI8BYLWl
# DATA /iDJHTHxaCDcLfqRXAgE1wrp12VfQRFLJnIgSPWO5dc+V6/m1p4jhSP0JAW+SYptay9U93mnZSFcaK/bOVX0D0NjuNb26vaCv/Bq
# DATA Bi8/5DmMPbNAsU5xQXarpmXJDg8VOwJNY5tdTxwKei1MBTlVRpG/4ijPTacdFqZ3ZhxMdSedPjSwgtC2uCoWtQW9EgIdzdO2qLJs
# DATA bka1etVd+CEUI+2/Z5vZY5QL1lkENV1mKhPGjObKdUhBsU2dNOYVlME92CD7bjXkLY1mngBI9bI0XqqxtxvMoErUo444TIeTLD+u
# DATA 6aBT0/u6L8/UK6wC/lqZkG5yqeoQTWq7F2s93eEqcXSw+U23A68FqhCCCi/eQ/slWFUJ3rk/bObZlLMZ1GLOg0HaPBf4Am36gD6B
# DATA H7fC2d/xJZ0gehYnntkHSzhmH/rGJB4EPxdyjIlNcw4LLaTfxj2y/DKdLA/6BxYBdlkx1XhxV+X/y1yuDMMk6NafkyfqP1B4iIlT
# DATA Nz6nvsZCXdKVpPFf5O2NBIvPMbZdyiyfaSck9d//KAGjcI61fu48BmUMEJmDPiafiDmpG3EkeybVae9mE0hCqMrw/LdKpwZZYdrr
# DATA QOZzLYQLYDVQJg/6P856HbNd9ngTVC9otR3WGwyxFtwAIof3sqa6vCGdMRf2y8q+HG5gO11UdymwvavGCEgsYm/ui4zM4D8sJsqp
# DATA uDihZujueSnZzYp2uYjgcOflJi34BD8wyA042dZT2+wgnlcTBOF/p9MG4uXSvtyjChHvgxdQX6iQHciSXIW6BzgBZgv6gv8X38cC
# DATA YyH+AlWBX4LLpr4C/KrSaZyP9D3ysPgtY1/+nCR68gssmWsnNdirM3sK5tHvPUNF94NV7N0kYBHHEmDmLfG2U0f7dARm1oFVD68R
# DATA r7PnZFRiLkGzlYA2tZwGU2KZjb0X73AP3C3uWEqe4GAtsL7Y6o8yUJdSevnK/c5KH/MhN5sU/KAINw97SWfhUrE3xhUYlck/d/YK
# DATA 3P6ABbAPaXh7+fhHzspxv6T3luqxOC6cCc8IZ2pKi2/L7REsQGPhNYwzQAHajWmRdfmSSK+X9Z7CBsXvgA94Jch6pTaWK4RC6b05
# DATA FsF6JKSW/uGlBbiSVduWblUMDeM5YGmw5f+ZVMne/R1BKzF2sqgV+HIR1v0Fo+m6sDak6/slxvkBBvpvrX45MPLQgP03WgjAzx1T
# DATA PpRkS61dQW9vUG3aQCgkTO8F1lO4n3hBdkVH28vYXbFpD8e9tHtvb4RFKZ63NP5l7yX6YErBqUZOqE2wsM65qYgL1bzrSi28Rq7x
# DATA ROgCirbIkgpQm2C9/MyonCwzQAj1jQdHp/GRUGlSrUu4girBG8C8YIwCuKY6rJvQS99J8heenHwPTh4HgvHpfPN3xtUf9O1OcaPQ
# DATA +wypu9ThacWe77nJCXNQl/gFyhsSB1N7r4dm1tp1F9We4KwFvIy5FeF5Pne966QNs32IF794cxd8FyPTkHSHJpejXlGIQXeG8Jkg
# DATA jbUgc1THnqPohrPq6Iwd98Pz+MPtrc3dzvrmo86jrSdrG5twi5AGAjHyp2ub649tMf3GyjWgwqac4SIERz30JpG8ESGOBhK/VhsB
# DATA 9hOHw0MLHjXWgy7qy1mp7ss12Mtr7UW18+6cKTHt2Qedp88+eLzxUE+Fbgg9wIvxJS4aXpWf5d6QHHLMvOy52iy8ww9R14Yy3Wn6
# DATA MmsE0L2Mq+aSwT8K7NXAxhFmj+C+4YI6m5ikYG0KmZdkry2Ng555sm2MhUmxG0WRyJGZSgWjS3Ny3eDodJj1nAZDnl1SLHO/qIeX
# DATA K6k7yrr9RCzInIDPKx+l0EHYX7rCafk6t+t54FS1Ks7UhbvUvCsLR/mJhpwpXfhwafAPLjkFuHZk7bDQoSIYtbX09m3MX6ivgsK6
# DATA rNK0X9ZJ9v5iu8/+HpqX8FeCW4m+Dzmpcamlwl1IkxXytNU9QIdp9swWUbqPjLlaEC0P7JBIuXDU5jovTKpCtf96HUEbjRm47IQS
# DATA gzdfUD1kZGxH0pZE2kAjTVMZ6CA6OFWLD+lsOop9L+m3N7fIeksdtmRmCx6WLWgMdJ7TFlasx7aI8xaqwEo9Urjhtu7xlf2ACn5e
# DATA n7n5wz6/VwJKb2KIPLE5trZVvVtRnmvjf4XZo+1okRUjYA9E+gelQDCHtH3jSBHcN5tAIm9FU3mTt2sOvZOHIZmzbQ15qGxmR+yr
# DATA vB3XOearlMpaQpJY461zqkr9ZGQ1TykLHlslij1Uu/ChrrJdaATdPPEO2+aOem4z2HT1GGQUL1K3sklBauhPTIhUJ16Fuo9kjb1x
# DATA gz/1yBbOhPTgkV7atRjS0HWPwco0ziB5uto9/ZeKwOHPpNSdOGDSUH85/qkLO/r4nkjkfdApw5AIgTXQJ0X8AlMRR7+Z31VBcKYk
# DATA GTRTq9YoEQe4HOpXMPZ9esZtl/LrhCJT0MHT09hQ7GPHDMm9wjGgXsUnV5QR5lV0NXGhbPZCN7IyQUAu476NY+ZeVnt+2y/9i9sC
# DATA Y73WXqD/gfBcatU61NEDV9fGrXqgE4Go3Rd4j/dM/6IJ/SNZCgOmh2VuqtiVunWfriZ2zwnutNbFkHA+fzEqRfdvRo8xkJ4QJGc5
# DATA Z/kmAJU4j8azAzWi6Nn244hgyih5CcfDEyyMmuFJlufNxbQjFOcAWfUm2YCSYgyZBPDmJfeo0mA//mwOSk9pyoEyvS5X64EKD3tj
# DATA xVskfZQ7QteFZiWtr11/srn2/bXvrXdIT6Omjpw5Q/oPXBbdSOIAkSjKsOCIyrY6jwixW8zfl/bs4S+rnXuKhfY9dfhCRypQDVxK
# DATA Q1PacgFm9Bz6FNVPrgp8g7bZJUGWQghLhuWZSkvAloIE1nxUpD9hWm4/2C/ya682ZCTg+2Si3Tkwynbsm5DKAAMCbQBjjpgOx1l/
# DATA YsNMWSgm3IJXU8YHUZz7jOmAjWQ19YCZg3wuwfxgHjcM8KgTq4VJcSlUKwnNsx7q6UTRBBvH6HkwyUxVFIToBWvKyGMZtDk3TpEw
# DATA 8DkYxemLGWSMVxEG/4K/nbCpUDEDk0SI+gxRnOW8P/T0Owh9C6wq8045VvTV1atJrt9GKUfpKdWZ25iiECu/S/xI8nDYo2/V0+Yd
# DATA E7NLIn+5scfob4SOLnHhRtiMhoI3TgiDrhYzFIX7aAbAGknfPEiadZpquIXz2/1Qap88RJZ5wxUCZcEJd2xCWLtZQx3SSSajXXvZ
# DATA ODc/Dmb9QY+DhNX1AtUqYA6uQIC5UduLGz3G5eNpIhdIqhJ9j1AHeoNyELnwpd4EFbht2WwFpTdi4mnvrCo6VWc3ZtdW7V1cQyV0
# DATA qwgIafG7m6obtT0A0s5eZd3ZND0YYJDxRhzE0gZ/Kwqmxp1lWmqO1c5LMKuuXgfUkDfGZCNEAgWdASoBuVfQm7uOWOGj2bR9a2WF
# DATA FciUG0B0cMf8ue4mAbiMh4a00ZOHhgwFjF7/Kvp4d/fpTkOH6bz5WdAFyAYSfqExWAiol52L/gnVLOCG9Gt1EBEoHC9zTJeUtAdk
# DATA SyLjsit7OdId0SRyNN+nWzIciUFG8wx1Zr0GVEv3ZfZDT4Jgo1yfTtltfajXQPhwPwvspoDrtQWxXJhJLmjBkIxPBOWydz06K789
# DATA G7waa5uc0BZXbEYSoti1iUiqMOhhjiAch88pPqARUXSSg8fK3y0brAPMM5M3acp1TtIArrnkqpobchVcaeJoXwQsiIt/UbgwGNdd
# DATA a16mCgKgQTwMRnWxYKd5ACqC6m3OhuiydNLP4drUGb3wqiv6lLjCA1VTF9BAjAbkdcKiBNV1/04Iw5YS8ARgfsXBkb5TiQX+tV2d
# DATA K4G4sSz2fLfdEx0Qj8i6TuIQk321CzuopF2csBRaxREDO5rTpAgAcE6adlcrYW/cHrnYJEbZNo8OBIUAR57CsFo8hW4TEq+ZByBU
# DATA nhz6/iI7kyi4l6TFFlpVBP+YeVwkfp0DyrRaXvuR/zM6lwDX+Q+Oav6rP632Il/A1uIDKjG8XKgtLlCtytQNXGv7ZGFRN99CPgYH
# DATA 5xnj+H4+D+m5Gcmk1Nqvh72EAInfOO45ZpErHxhH9roMbXGRh7ELbG1DfSDZkDxC6mefYgNDExS2nXHa1yyyYH1BNmcf1gkvigo7
# DATA +DfzLAievockOpvkpCSfU/my2wROLFNROhnfJ59Dt4bRnm+RUHK6d/1vkhdJLQmkd2R7/5Q1zOd6ylveCtQjOQccXYEcXjxOmsKV
# DATA XX2h5lSWBJhUWeKicJNY/LDrlJd0dzcQX4FZdjaraMTc+4NMUfcKZaq6kfJscgaHISQl1x4NVXdNX6jDBKAoNgXFPxaLtPCHXQuA
# DATA cFFNhdjSZM7UWPmLDHtS7qq7Bv7LVvV2dRhp1K2noLVxHWcdcXOf8RylOFjetE/RQiWpek/OLIy4YhD0CuRg+v+KryJ+a2eSDTJF
# DATA eD1mFRqc1rpoI6Qjw7voRC2X0Qe7m/iIRhdBhDnWfpojWiQzrTJcONZxhqAVSlH9UHySHzoYC+5nxvxeDhRHNfkjNQovb2L9csFq
# DATA KSEWKtBlP0sslmVzY2pBzwn+cYWpcj99u8nSdb2z6Zp/zqrE7TJEuQW1kQH5wrjBt7Wvbyt4W2Y0Ogi7wRuwvhM76jfMyINGBNT/
# DATA YnXyD5m1FHK+av3wcjbtLmOpZes+j2XSXjqeMv6f51gfvh8uqG0ozVXlKENNwipOOYA/aoI9ychmIzuxdJW8q3kk9YKrbIBi09jB
# DATA NQ7cQAvrXdQExcm8eHutKypE/yzONhbVLRUYmpWKjLTnk9ygXBQSeYT/+YKaq0JNnUF6NpphAIvDyYu8ZsEDWeA3paw9eCGBZVla
# DATA bClYLP9Afb+OfypSLK6sjqrSvcmaFDOGli+UY+YtIcdMbrMygA979FpB0E5vQUJ4hR4MiIEJKSAJJQu5FL0bkB7UC3o9U3eTJ/pS
# DATA sohjJvka1hnZ5Ek6lneQeZiIicn0Rol/UbFP5KS1iD6Ir4tm2fY9n8iQvsjRo7aKWzpVgiZSY9sZeeFLKpTflsVdMyxOhzUHu+Lk
# DATA afDq1El8wmOkJRWpVZzwE5c7qAe1eDkd95cB/HiZoDljsoVDG7QvljWI0BggH8ivXSRTbaKxq0Nva9475HsfqxkfqHfnGui3l6U9
# DATA RqjGqT0ZqYkYDfvdGijMV28SXMvpMSAzFwrcN5+3ytNfU/I/7BJlN0MvLW35uYN5ABW7UjMXyjYtAtv8lXGFN+PfUCJsi1UrOBuo
# DATA CQ5/dDDqnblovLqnqAmrQXJOztEJs1WO/+xhp0O9AiAg8Jb2nm4NDm9V6T1bkndtP388UsdnDRyMwLBTxyDJCrxo0r1YNQ1q20BJ
# DATA hpatX5isOuQ8rHOD/gzyjf6WkC4gnvV3GC33OWjiAoK9twbMg2SS4CbY4arURIQYTugISvSdZMUsVOhapRijKhVBTqE4j54923jU
# DATA 9OVCTsWK/laKDlH7XQ69u71yO6kiC4tvvvCga1s7nPBcpkF3pkINQ2YFtjbh3Iay4JHMB1k2rt1kRhlWnaJ9M+JIxt968ckUxqyV
# DATA pbyaP339T+rvv3v9JZtCAXeSIEtCaXGL4ZK/NpkpNBg/mS3fwvx5Tcg58/Xr/6sNv/78zV9B0KefOwNGFwd0tEVOVy53GWvs1yZ4
# DATA 9fMxYATU0slRbjN+wS+gr5z/ua111LGnesbPmmSPwj8dnS8+Aa2kDQkKVKx7GQc6bqqvrsJMm2PtoQ2yYBVg+GkQMxdma2sNE9XQ
# DATA zCHUnsl9MsmRg+pE6s21ydEMts9TfFMT8m270+mNup1OIr5sgmdgyp/UYtOzGBwcRuD30d7TliFjGNKw9dJ6r033YjSYcPdwZNCx
# DATA Qg2qmyKA39URebn9lHIOKk6vxLieNC+Gv7WSitNdJ0dgPSTUVndJSWANI3XaeheNnamuHC6HjRPqma27DGF3gbrQNyW5V1aG4Wm5
# DATA WFVt6q6uL7IxZPfEPRPTBXyqlsKz3+lQr6Os0Ufx3OKTwm6NPcMCWw2cRGzBboBQaYMeYPejRy6WxX+gdF5LHIoxHLlghDXvoAHJ
# DATA 1dsY+CGRjEq8bm4yIzLsTI+LwI04PQEEbm4vEvs0okYqiJ3upARI7IM/LIOq4yd0x3THwL9pEfgHXz35l40S4wcGjUH+pmBg/C2R
# DATA jYsI65gR2Jv7pJzUURiaJh+SZEhSIsiHhIUgldZhdzgdOCzMsQl79LY0LTFqjNAFjDJ01WLFsVVXEs5Q/HB7fW1X5yPefvT9bT83
# DATA cZ0yI9lmdGLwwx42IJPkxqcxXg2gBVcAwtE0D+FFDf5T5yePtx5+t7P+iSt2utwyEA5KuwQl/N7sZJxLwj9302gVBSQrz8ETO827
# DATA /X6b/SnBHDWctm8mwIDUwnbQda7Twf3a6cB+63Ri64ea94+GsxNccPgzHTR3Nj7aXd9+Uo/s74+fPZVeWvSc/qlRBSYl342Ouuaj
# DATA a19/WtOXE0fQIY4o5ZKaFEeNjPrd7IxE0YBUTuLXzpmiwifrr/pTYa/1cNEyqqymBaSH7MCO+5xb8sS4RIfNvf57K6qay4iRWwsu
# DATA E0H3vTkue4jS81PMqw7S72caEORXmGb9C4Tc+8Yi/ztJJz8+UEdlfPaNr+x/kLD+7u3b+K/6n/fvrVu337+rn/Hz99+/e/cb0co3
# DATA vob/zcBDVjX5jf8x//fNa8uzfLJ80B8uZ8OX0fhMsY7hraXr169vZ2lPbXHcHupauvZ0g+CK0H8ZL6t5ND2ejGZHx6GYIVW+qWpZ
# DATA YrKuRVf9G0wpcLDgkPam+qm6reKVkX+qm8uxumPqn0D49N+jfAn9K+DuoYpo7gHCpS4yMY0pwqL/hDb13/IG6z1z+uoqp8zTWb9H
# DATA fWAaofuAdylF2NQFUdHS7kANKDImRLrwmduUkfDVoPnqadIAs+5fMcqTMSRW6ffUC5nzhLwtkOdxVI31z16SHo3V+YwxlFSR3nza
# DATA 6w+b/TydTs9qRZ8wdwTxE/J7jEQ8j6p20gevbBIfR0NM75QSXvGJ/r4VucIfd4mXvsn/1mjYSJZp5ERc+8PxbKpfmundHG1npBX2
# DATA NYmgS9DvWKHIQ6PwC3rT4eI1ENHxcqIY9Rg0/CA3neRHavrVcVBbvg7J3VQbc+cHGjb1qz9+iLnn78HBweNySNE1qNKBiCY7mLVx
# DATA 3/aw0+kP+9NOh3tG+sjRC7URYgeoxOpX6YZowsugr44/M+d31j6B56ToNbgBF0aTZOPRwNzkprx2E15TVmj6U2eFDjrJeXP0TD1L
# DATA 7RygiDWaTWUq7Hpk6tY1x+HxtNsa1QE19bb3ZqCrN99vrqj/twqDxQzCUAZ+tFqr8cUiPd7OTkZTpnW5vsSSQz4tbRpRauKdnY+j
# DATA 6WwII4PDACViGVEzOGziWuJfuKC0giar8zKIqvjC/Yr3IXp7fdL4cDQ5TSe9rNd4OhmBg11kl1O+VX/BOzsDFzR3NqnDAhPEcOEX
# DATA bocW0u+LAwoSpj1/8tgZVAbUEICumJ1fIf2bFlTZ39oJjMKEMWJewCdxjBGOIlJxmV13btyQ83jhII2axXD3Apfdi9co2eOPOTAc
# DATA dGofZOrGNkGaZj/3c8r6vqWoqy/NRcgf1fwDze6t8DHSRZgWWhNxJcC3SZPLJuFxPKQkxI1dhlN1J+pV4/T0FHPuNUyrhGdsWyzO
# DATA rGOdhoTbikLDtppAkGDtlgAsgZP60fouGxBXkwW8QtVGKe6wbbF7YH7AUIVbByawDf8xZLttyLeDAFJU++MtT+xruk0iQ9BmoNvz
# DATA 7EButmvXCnPrprbBCFNMmSUGsF+5oiR6EPnfzjOQ+MQLRDjdG8hBqu5ek6OsxKmJ2bKT3JF6EnKZvZRdxPhMkQQRNGhUGcbc4yRr
# DATA 9PaXVzPQuNs3v12P7qzchP/cgv/cvsBiesPej26Gm5bWC0VD9AdJ6eoXArXnLQxu5ugw7Q+yXgs5RqSdRe0gEhmrFViIWtAsU492
# DATA afOGjDQVk/d7nxX1yTBDJSVPzD2wlIGPwIkq2o2ebu3swq5A7zo/iA06p253J2MKqbH2h2Ku5hoGjx+qjT51ErrplOu9aVPfWBCK
# DATA zqu6DgXg2Y9V683ZtBvS3pRW1s9HlOCUKmvqXPPxD4D1vrey0lpZ8Rzsqa7m9MegfA+HKZnmuKyulb5pBzvs5GRvprkuUfNLN22f
# DATA E9tf7qrq9A+EKW34MpsoOTQHf9n8R7O0BzLdaJpS8kdAx0j7Q1K1GzdauPk5LJ5zO0ItZDTW4qhAV+C7zETN6mwwQHDq2iTeW2v8
# DATA IG38eKXx7U5j//xW/dbdi5iSac+V4Z9pkbc3yohZH/anKL33LM53RPPgbcxJpj7E4BqR87Vzko5RQKE7EQgoaw93N763jpp1dfNS
# DATA dyfwk4kfbeysffB4/RHKYf0TdZ/Ex483nmzs0tPs1RjMJ/B0/ZOnG9v0dDTsHFP2IFuFyedj5449Ngx4vu3d3BkZvhiOTodaLxDp
# DATA mpYIieIEAAlVOz1MnEyLzt5Iiht3sADBjq0kda8EfNaZTtLDw35Xl5HLuhLdb1MT8Me3V1beX/32t2/euf3+7ZVvf3tV31qwFPYg
# DATA UGje6DaG6OUZcS/U3p3BDTY3iwj+tEdnKJsFRtaB3Tvt6GI0iHg4oudx0pyNx0oWtpBYuj5zQ9nc6myv7yjqq9by0dqn8M/319e/
# DATA C/8+2drc/Rj++HR9bVteVsoWKletjSbgk4zNR7Zb5CaTTuDQYcD8fqFHwAWwIWmtNKO3/bxn6tFo3vhZdJB1RxCNbwrKY8C5i2jH
# DATA 7cFM7uktub8vd6t9jB0yu9vq5P3GtzY7H289fgT1n+WRPgP30ND1ko4r8LUeK3LNDQ7yMGWnlo5YAkVGZEOjKCcjrLaE0vhBNhkp
# DATA BpoO8wjCQvHAMpaGJBXNaP3VcTrL0VG826W0Cyfqd0QNRHzAm84FFzbzg7bfqDlwajZXfXcRnmfcU5bCaPJxEQ4kwoUxhSr8lKnZ
# DATA Bp0z5/6kt8g1uUc8Fyt/ybb13NKkR5gaW398zyLHRIez6QyXaghmqDxCP1OrV5LX69BWtUYr6HbFHnqWg2MOJW1RAk30Y7W495S8
# DATA PFXXeuriSXoWqVaHxAvSAYIeRPkYBH5NO9Ij9L5ccljxuWVbLXYO1ltcp7g2tH0NLrBWzqDzQK9iyjthaRA/1gaIm4rYNVZvNm6t
# DATA 7t681brzbfV/PyhgSMTc08ewmh9AmKRqj0m4825HE46WmVhwEkAWtgH0cZgOdoCvIxYQiKuYNQ/8mGrI75OkgHIVC8sVuBybkShS
# DATA yMCUcYhzkfa510mncUFM29Nv19CpsTB34luRy6uPmCG2BX4Wy2whM0FM2+ARXuNSSdRQa/pyABGQOGujH5JRPD9Oe6NTiJDMxTBs
# DATA NZch32PQ7HRHg5Y4CyxyodaVEXlI+yzTifN3SurC5CJ1HWMLcYc122sy7OPPZ2rhQO9UE0PRmj47wKf6CZaUQ/WK57kt6qIq6L5p
# DATA 1sfz6cdvePcFrfDm0nu6FnJzo1Emfp6BQGRhtUbb9M2qIV2Vo8jNZWfNbUH31D0NdA2RISDcx2+hbKNu+1QCft26uUifn+q+Gn2s
# DATA I6pKMZUDWNSfKKpOMk7F5pJOPko0RDhFBVNBYanCPdscRcUtLDW7Mn+IkPod5JdyrbaVZYXfT0e918QjaSJcpVCnahg89edeY3Xf
# DATA 3yeV14bVu/W7t+HeoJpLFlkYGWdMalyt70uj/BjMRLAjSGc8yI7S7lnAOZQnsLg8MVaB+w6DI2cHxetb3XA241KG2Xr4Jga2mWEv
# DATA 6/Fovhk9NEsTKaFIbZYpqii1o1aUvVRjOD3OqP4T1NwgB04BBAq8gECC4Qs53h+JEvWzQQ+lTOfKZg9Okay4lAOpqR6t5Zf1EAMr
# DATA 41z7higyBDX1yiFJ/EbPC1kR9DYDN0OQavRbxMP279s4+XhpNeDOQfYN/Alrs69NvbJIwWxn61aT0z8aIjs6z9XM0k5wVRu5k4sw
# DATA J7cNhOwyhyfIxBGd80JuKOB4tofBj/aRaOlu2bgbTX460GgtHfedq7cmk+q51urWUPsEgXUQYIBm5uWDs4beOxiO4NAEEMlMnFR6
# DATA mIFhzJoJJNCJNX1KH3RjJS3mdRe6JLUsag92iMfQOERyzQM4WjrEJEc9M8qLYN9Byw6k4CVbBsyl5dGjw8M8E2rylXq0Sl4QbqUa
# DATA YGvuXH2HamxrzSH9REChP0Lhzryh6l3GhjJuGPQGXxFq5l6Mv9wsbc4L3Nz4RTEGAApaFQ6i0kCah8WoKk4/Ox9oGFJ1mUNDNK7Q
# DATA PdIG6odphOh9kbp390e92AuhA69ahh/d497sF0MyiyqnhDDTfDNReb8fzchYkrEoRk1jFF+OOGbQB5M3zos/zIbgPlkL9SO5R3Oh
# DATA 7y7wI/EzKWIJDCHGJXH7fKCE4hc+K3QmBLopqnkQqqVMnaK9/vSwaY0s5xf1Xit0L1zpOlbBd1BQemdgnGKdBnqxOxDb7N/UoJZ1
# DATA +P45D66lTytv3Bb14cKhGFhE46LNhp4vO8alkRvkbDqeTcvy2ZXZk8kbxnQZtQGwBgdgS1b1HIzAmwZqi0sSFTuNK7o2GrzUhj9T
# DATA lvEkZH7yeoQ+zhq4qh75YBP9Q/G9HBT61g7PauKt4gVQf7KISlWNS93gI7ATnMFFxpkAHTSWN7vHqkM1QWRF13g7tcFXgsZPTzrG
# DATA 20FKvqKYw5HA/i7cbQho9uGznd3O2tONzu7Wd9c3gbhu68SN6ANF5uHIJGTTKuK2U9WTte0ffLC22Xm2s769ufYE1S9aZ5r2lPCk
# DATA ajAuPSIZnRHjw9U9XdvZ+f7W9iNZnf4E+iQmxzgV8E/DMkBCMzwD+7KMRc2xYPWE/lPe6VqmtQu2yiN/BZkAQrc7VBHxBbz65xg3
# DATA axVgQcbVZ1GiQZ8AlIVlz3tx35M05GUEtqGVf9pt7dNMX3SwQiv4UP3JfDUwfU7l7Y0KzwvU05NZPi3TV2N1xQR97xabGPuHrLeT
# DATA 938sgNXqZKnMWVjYsyKrZlPYRkXw4jg9A0NtXap2XetLYHL4odV3am9hfSdTdwu4lvlWX4qOcFeXZDzxoK77JGT//QKAsqlMyl8a
# DATA dk1fWnQhU2WyMO8VlACnkmC/yNLf6x8eZgjzRTeCe9joSM0Z8BIl8XrcGN3KTfJq7goeC577WE++eqj/lOEkreBwBU61tuO6w3BD
# DATA 77SLcz0CB45Sb2esDjeV7bJ3wH2BgjJnYwqlaJ5vtNtDrXvUNhQm0TSt8UUpg5bIyZYt04mIqfcwafiHeoIbFXM1tvyde6GVemBX
# DATA OmRBoRWdWyHjAqTDtHemHqobLMZUzvau6wW5TgmOZhpVAYpr3S6lp+gq8YQ+nfMZKOoU257m3Dx1P7mIZRdReYNegUw2KB2GqqJl
# DATA DP82d43hyVTXPBr2dJKpHhwdT43dXHJEdV8n4bkZbaPlI7LL4Aau9CZnHSX0+DEI8SO1euq5CYQjwzyRweLRcUPbTVDJmSKsMGZy
# DATA 6owfStdiNOZPj9Uhga59B3d6pD4ANof2hTNQWPvdeggbdFA+XoihEp1h6QMU86wdBhX2PipFecH1A5pG/GXTwSAyBK+7vKghMQAb
# DATA KOUVYjKxf0+bsQNksZyuW6TDalprXWoDKIbBS12pu5UnQZUID3RYLUUuVMO0zN2b4da+Ga1Z3ySwryj5dzBS7JZ1TJHBIiEPdHQk
# DATA BpyOYbcPMNCIkx0dKAG1NzijO2Az2JATkvz2UxyeZn3t1dyLX1cxr/Kj/JDHS9psCPftw/6eZHD+xuacT0d2PoLx7LDVjRXEpl8u
# DATA jgnV0pfouq7anpnKykMuc/NZt77tKzbUzeywkexofu3AK4X2XgmT1APgM74fZJcsCwfYo+DeAQbHylBmcdRUKTfc+Xjt5p27O8+e
# DATA 7KBfC6W24jCIZn6cqpe1sYdsepy96vWP4HiimidC5jGmvIjq9/NhTOYglIBRHy9ubkeD0UEtvsGkP0lcHkoUucdcjKfpOm+h6/vA
# DATA 6iRnlIXMcyqm3dqcMvQQCliu46/FXEaXTlBnTeave5GYbtQr5dj0TD0G6zuLXsynlORHx3TUw0MVB6OvrxR4XQzjRXkIHGpjP/r5
# DATA XqC4IDvBb0paca9SC7VEmoNFG8CrSwOuLjqeGz3n1KSlatrbq+qGHmoEpbRiRLT0/dK6Q1uZeF3WHSWeNAiPLBTKHOrJGZoJSgOf
# DATA ix/om1CDb0JVX+tA5mAMM+y0VdSSu3dAeHRnZUXIDzoe2U52K1r9bz/9X+6AHyDdN41NMXCnM6lKOJB0bkDnvDjLS95FRDAmug//
# DATA 8c7W5iOEXy69qhDBudqNwzw1RAbTNpBUifIl6G3IS68pzFyCAGDzShoGZE9VRZvDoVSzSXns6OqCIZb/qv/np8b4+uM/37/5/q0V
# DATA N/5zdXX19s0/xH/+fuM/t06H0WiohOkpghj1suholk56Edor7kUvsmyMUU5wwBQPQRQB9Es5sz5QL9WBhOLBSFC84XFaKRHCyU8I
# DATA icDEZaqjOBzpH/0xJ517+8jQ40H2yv6YTfsD82uamlhPm+PFxJFmJ2MgFUtLu+BiGOk0f6AnJrg3nK14aXtra1dr6gks1JRrIHKc
# DATA geNIlp5tbnhlcyQ3Pf637NOmxnRKlh5ube5ubz3uPN3eAlg8t7bZ4emyzN3W7Pk1wuRPRtCXnY3d9avWkpMo/mTtkw583vng0931
# DATA HfBTtLEr5iU8V1Itjr2zu/4JTEAcx3vPhv3p/tIjIWBZPTzuRlYw4TQvrcEtsT3MpqejyQtg2U120ukBSP1ET9DSB+gr1T5R4kUf
# DATA bcpcbmmPU97tLwEba6s7HGRrW1p/lXV3wBOwbY4JH5Goai2XsVeKnGpw0yXycsRuAvNoKzFkaW+DoFn3l76fAvv54CzQMTUXei3W
# DATA P9z4BGZnz87EJswEhh/uP4f8qQPIF6EfKf52AEvxfCjlVEIt6NEkmhKwqfN2LMxcN0B4cFMgYVyVg5NJ7gFuiib6DrkvB2HBeeYq
# DATA uukYvDg7JHXSw4oMmNQ6/ldmYNJyOi+4E99hnC0NlWj2xx2nJCZ56nen0vJigyrgbtl/NcgQq2UlQtBsfNHPO7g+3TSfuo9nmEUS
# DATA 7xD+fUWi1K1FXKzLQa8bT6EeNX/DbCqdbWLHAElJ3aGtxKSNU0sK5jxViRpMfozwLWrWDyb9nroK1iOMAsWn7RUTZE4AkHoq8DdL
# DATA vfA12orwegg+CqbSJPpJdH7z5oVjtOU3D6K7t7U1EC4DtXGi1dp9SoxphN4x/OfunTu37tjbKNVSNWNamwyMBku7tmMeLnRk9ea3
# DATA dE+qvbmaLfDnqq/eAXeuA0q6ewC90ZUt0p9HSFb4E+1zmZ70B+hz3B/fxXDJuBWTf4FFxeyPY9eCeRif04cXUQ77NTrH4hfgIA5B
# DATA rCygk9N4O6rF/f4hXu3P8Z4PFyfSEsgYUDEqsaR6gJRfKjJNoLTNL3Xmb+PBBKtqN1NoeTHkwhYx67zIPBKdEk4BTJBwYqbdcdTD
# DATA Ks9t9abXiAxgW5X95nNzqGgneVf04XydI6e+iM7Pl8ALR9VzQqCs6gmOE4t1mFXciw4HqbrNMdG5F11cLEWY8JsvFlANfabkANBR
# DATA Ho9G+tKh7hOjCTjQNVZX1CUUTPhn3O976iu9hNcHo+v8WD3tTg1SNE1ObzIaq+fntFdA6yxm5Dw6t2t/ko7h8lTnE5VcqN7aiu1X
# DATA /9aO2bw95ym/kF3I0C2lnx9nvbpO1NvVZnoKnABBz1Rykk3TaHAb/TwV4X15t9Hvnqgzrv7z8i7NkurxsNcYZv2j44PRpJHDpICv
# DATA uXyY9sBaic8matIz/QSGow6VmuIxOX7cvHPnso07GpXhJEvVYmIGwXEKeWwa09GocdA/IjbT0J4lmCVarRX0RTWgPjhx5pbWyO6N
# DATA Qwq5L9kd+u2c/bHATrjySp0zLbmQnVf/B3KGAW3sgkbVKMCYOQATWGK/bB2UWQAfiRWl7ighdHP94e7G1iZF57HnrUO6bSXomnSb
# DATA wGXMQ/DQVZy11z+CD4WiADqD/lCgMHDLh1CjgA4iZjC42CnhJEY5LgdBTnE4Sra5Cz2c9tSGo45C+XDqaYen4Il63nsvxhTGwZSY
# DATA TmehkJ6JPdPbAsZqeT5JxxeQrRiabNsoLvS5wKGS7EtZRJHlYzgh4/TTtsTAw0lfrXabeRm8/JE3IXbl+tJpVlrAJOxwaducbBtA
# DATA GFRFug1v4ijfV87WM9pUW5yvSQZlWA82nAGts+fPDYB9k28A3I0mFW+yH5+Xm8n7nx7GCjIbMuZtorUOtWg8Y8x6DiaIakilNnrx
# DATA /l5r9aZeZS3JETMmKm2kNSPUUUZrZFlqFgdGFhHuFji5w8MpRYYSOAd+QPObwQPkc1pyd0VcXVOTOoRh8ZiipazaPHYrEh/6/H2b
# DATA YJC01SodkpyASx6puqk6fUbTYZ5qGlI7jHsZ+gkW2fVzAqAPdRzFc+b7INLglBndpx5Oo4v/PcT/xnyJEe0nxS8qynKuPmCjp/1h
# DATA b3RaA4AI/tv40q8hE+mZUateUqxOdzCC8Db0pVejeqh428EIJSnQsgDaSsQnPupOUkXU86a5nVxt5YMLVlXdQit+tVUXJ0FN0uYo
# DATA Gp2CDzvplfrgooX3YbBuqhsj+WDpK3Wu+F0fgD8BXbJyUnKcCm9KYiP5xIvND/oB2aUN+fqLANBn46NJimcpouRMPCZ0DQAXMA1t
# DATA RIcc3X+mOe3YSCeEa0pY5rLdWHPxJSFPTEQu5ELEvbRo+1zgt1C9ai1A8IIeunWThFshU8q6kuLpopOOMex0KOYsVoxy7rcQVuAi
# DATA DpO14ELJRtUsXa1FniP4c/XOCfVBUwEJms16BfahBeBQ4yGMcUhVTsHyYrSdHc4IFSXi8vp22auj0nE0SdH1VysgmycvQDU4Bptu
# DATA G5siJ18EUzjsv2rHTdyLjRB4uIdpetizWKZQt4dlCq3RmEnfYt4ab13TQZoJp4TBn7BlLHA4oqENzpwTOMophIvTdJrvfHkh16l4
# DATA bQmdbhawbjlvpb0qIqQemnmuoNS0y/p134xVD0FDgzrq5ulxX8mgsXrmYl+oB6XZtGnQBU9u/Zy2TeE1h/x5RdDZO/A10LEaCHad
# DATA mRrDNbweKEksU7/mlMdY+z+KVkYrN29Wzc+zIQT5RM8+/H4k1kvXK4MKqSGd5FUYONV1kSG2dCHqhk/+4Wlzp7Oxs73+UU1/pfuK
# DATA o5EPSwbsf1cc41uMk474V60TRimbgoztlKEPCih2KaWuP93ky+hML8yAsXev3vSy7pbVUdPhza5nlXsXU9/k3RT0jzghKAzGeyuN
# DATA b4Om787FsuJWz8FJgOpKKikwzDj3BDNzzIYnPDvkgpSHCKmji/IAD4hLUI2aKrN7pyQf70Ux9zPxs3jV1LEmXH5gQLOxzkMXWvPy
# DATA ryG9ygJfofeXnfQwRJ2tViSUt5x90bY4CB9XnYn4IpknnA4WO1d5+r+CEZSOIuzv5m0I3pPvaM1l9g025pnMzWQtYEvBlXigMQ+C
# DATA t9DJ6GXmYDRdlUMxBnjLEoPLmSpY6VnwsxGGCvXr5tdiqEAKytPkWyz+/8eBzUAdrmR4hVlPdSfq6DWtovj/2pi0/w7Z1wPgXpdg
# DATA 3+FJmsdUhT+WYnEI4+ZoH5/7HP8hNfPcZfrcuMvun+JSsAmqBnwybRyuNT5stpb330s0469ZBlr7TqtufyXfSXyO6q8K9nLuHBUn
# DATA p5Lj+jtJUwdsDDSqLkIe0CcSIexH19pMW+DOTRQEbCfow0jV3NzXOBF18IfFL7zTv/hoDrLBCAKxpiPVkdH0GAO5UMchg8cUzQUR
# DATA LryesQXLVVdxE1IWIL8O47hR2wswtn0xMyh+7UHuV8vswHEmtngx8XSEvHB4FhtWpP6bCPxe9G6QB3cu88VhMC/iUbjJsudwd4/T
# DATA cqC/DmP9yhivGbczDrOzwjIhja8gncyTrorVl0zVXOnDRQVBTxR5wzbnAp24CqektXTpHnlzfBjvnauZu7gsUWIjuLmDoKW7xNgZ
# DATA lJwXXEi7GRfKeKa3uyduBWaZJbBBlg5n484Y0y4TNrF2vXfOLrzTXlZOUjkKxycFUnqQjwYzNb0EcdNssncB6XymeQXTPtQMiXuE
# DATA X7VgmqfHFwIzyiS6R5CoGxOIqskzSnTHEgMYLuDnfkUoKqKStm1tzYHHvHmeIZnt5mj6IfgOBoKDCgBQDG2H/P7x5ndr0I7h9XMI
# DATA dGEKWMhSs2D6eSGBnlDGMqH2dmbwdIDebGIXU/bQ9IqFjZWQlcnpuhE3dNRrrdgaxsnJLlHgnFOJmZvv7X6SJOFm/SocGerRxrY7
# DATA p+FKCNHDq6hWkMacmmC69AOkUjCyVfmUhSvXazBJLr2uyHnl4oRWmI8rTK13VhGmm84qAaZ4HXIObOGAB/hAOD8VNsDZp7Y2H3/q
# DATA 55+yvzc/gGxRDn2qODc+RHZV2qrJQUjXy4cXvsFTi5wF/jMc1ZJq+bt0xcVRiII7f9HdEUDBXGxHeMRO4OwbybtGviUOIjt7K0DR
# DATA ZOHmH8qdaIDWvR7wQuHVoofREeq2PD1sfMtCJ/Pm6h73B70Jbxref5WcxbJkyUGK4hh3gT0HdDPWl0DvnRyPz4Tax+gNxb8dDDjg
# DATA HfAQIbQKb6XbBzeSAKSp8QEuCwh0ZnVXTaS6GJw5y5oH1tUMRnNU7FnTTVNamET8Qs4ifcVX7cMRyMj6Yp4z8w60OckMQAD+dhZb
# DATA l/DFAyXI+BjlqKVgOMASywKhVl3GqGC4vzUrOBmB3G6hUbIW2nDg1B7ecHymHGKKLvDLhNyW6UDI1bu3vnXbAs3AZwVx36dl0Llx
# DATA 2p/kmAg+DwG1C+cQhnura3SvIfpmFLclA79RFQvsRIHmRFZecsRCpANf+0pwfQAW50ApFsD6DDpy5qbwJv/p0QFkD+rg0DvgSNbG
# DATA P50jLoHfppgfF8HfFtkVYhS+47F6xJsCTfUk+tfg70kHcg3a/Yr2cvO8qlkS9AdqGGonssdzHjUa+DWlimUQoFNKLAOacmf74aEW
# DATA nWhaybiwKy0iUuJMsrfJl4R46RgbaNOiNxG2uI39QyUS/CxsVtcFVasosBadtXY/Mfh407R73GFEYzEiVM/Cml9lfrepOq69coaL
# DATA e4fbRQ/5JGxsiffIk3p/z+JjrtTv3ryI/W5Xbzsetv7GW/R3sOCkXOki4gJVu0yG/lj9wa3SnkCRCOJ8oTDGbKuuNfPjuCjNGZ2d
# DATA Q+KoBoeqsaj2bNg3kY8FuAq9VNwBHWraa0kdGKVdKUXTKNOViFLo0Ki6TEWlkyNEcSlWlcuYX90J0kkt3kHdoRrweawej8mtiF0w
# DATA 873WTUQG3Iu9qLODND9+PmTfnaiRzZ4PEXfOoaWwEakaUNEhOjfIJwB+nXWj2GxWUwbGRSVAM5AEku3SWIITC3ATcKtpm/r27rQ0
# DATA aqyzIRDzCi0SEEvGykP+3FatXhEto0LwX10IFBl5/xUHyIxnw+50RgAU3eN0krfje3/0k/sPakns1QYmlmmWj8FnEFtV1UMdXilo
# DATA JcM0BhhZ5dxUwWWqhsUYgA+HwnYS/9RzN/bB4RVLznOfdPEj1QfOsn2TkXr/DWoxCK0Mfv975/ei9UOHRxOQuVLIOAgDug8Jk1Cp
# DATA oZ+Ziik+gmF5+Vnu3zRLt4m3VfigWxJ3yZ3GPoDE5wydUteGQb7ML/Gk8N+WdFO38VS11ani93UmXw50gm3OuAzsxX5IG/qZbcRI
# DATA +2uaFM4OTzs6mg3xoUw2d9NdegquWX4P/J6iRY5M9EgJ6O/LzRfIP5TmDWPzG/Cb4Th0n+HfBlx3gYRT79QRm5YWRa9MLKthb3VK
# DATA gtC00qCGvQxmUYyIrkzHfXSYg7f38S1vrpYLtIrzgcX2YQfSoEilA5++B7ZI+Tm+k59BEVx3/HTPqdEHMaXy7ehmhXLcjFnfXpwa
# DATA k3CFq3qBK5ghrDMxnmqHYY/VeOiuJMw4OJ+6mTA3MZyE2AM4XCDpRRWyGWzCCCkOuiQz5y10Tp243aJ+qOcYY2xyxZ9OYNYmuEqa
# DATA L+LCFC7zeGK0iC4lvnTcJ0+Q1lcn/E4nEOvS69jKQ8KtObVO6aC1olCqKBf7+NVqwT6aURCMESZM44DbjAxHpOswFcfLo/HUuiTE
# DATA YXxsSHRCgOpHwWYAeJzFfCMaexUbBDReEnMfwEPoz0rwznrlrqRDQIPD2CjErcCruu5QzJaTp+hYoFM3ZV54jF7YPbd4AfFeiv3k
# DATA FIJAzBrw18R4Gs8JR18xTsgB33OS0F8LxwxYO1vhPDuqSMIE8xw5Y3AUc3J5HODIGjVFKex0IZ1pwvQSFdaBgqCnLGid52xgvVIW
# DATA LJTM9sFBlI0hlMMNmyXJkAkSbSVeCoCTVKKNPEDQ7j3boRGhpsVLwTproUrjysOPvKNELHO3u+kjA/rwSRaHCLtJ5/2SVOf3Nm+l
# DATA W0AuscltiVyCrt15V0kkWs2yVOxleOpcyoSAHPfAUstkA9wlhiNve3nKRbLF5prnCJ9DHTB/MnoJcDhG70sYXOIBh+Q6XF4CRNTB
# DATA JUZfe8eEadl21ZuC1WAPoK/AdpPEUbu4APy2r0Y/059mpZvCtA1bjPrcjiR4AmfT5GLSclwQhnBKtCzkDbY2zz0wSSolLY4L5HxT
# DATA 7OnNLiNiR5nhaIkCvlvWmWV7fYGQGxcVWMUZ0t4p3kJ6kCFiLbVwx9+V+is4XEdH3okdiRklPKxi14XH14+5KJI0DR3b/1pc4v1U
# DATA 4mcQz71GHsaX8EWYW1vRV8GJ/EvKvX3BfcawJDPgdmESQiiM3p4trGut4OjDnhwhP58yd6QkWQjP0dvjDz3HKLHLNSug2V7G7yo3
# DATA uVGc03g1pmLu071BOiyleZoo1gWtW4BgLuk4GD9tolAaF0RBbqjQpGNWMTY+MJawKWUyGvdRswTYOE3QmiCGWw1/anjHZk+m/AKr
# DATA tBJyCrVyXdLBMuxWCCHkZw3HJ7ABPoFNgDSOyfOj6aJ6Spe/iDthPFTnOXSA55v23yv3J2EgFx/Uhf+s9cc2B20DUREI00L9QLPP
# DATA mLhJf1xwQAkpbco8T2xtKGPqfoCHDERmXIMgdjBYj+FP1DFQCZEgt0mhfMm8acFVUKNly9khL8t5f3zRhIi2pWKacYekY/F6dHvl
# DATA 23flkA1nPowN3tHzocE4ejrKGecI4+NVQ1HjsBrnyO2XJLRFNBR/whRVu+uhomiXLCDxk4oYxNp3WhiG+BMGVEgiH0TFhoSoVb+I
# DATA igxgIvFFbt++xcGLEatLo+uTbqObqirUcL3aGqr4dYdygzlO0eaX6aSf4mrU5gZQqm3CXeV5uYjc/lTxrMPY4D9gUiq27lK62sqR
# DATA qJUqdh9z+nbsXoJTpO9LvN31S/+q5ZCPWK1LzIHYQJuS89U6moV06ni/STthgc1BkBBAIeYdJ6eH7ba3HE6SL9msewj9SXBU6f2g
# DATA fxCeL8mdsSNORcUQyrwJsc2KKe5RJXiEilkRKnoaYLDg8nKSToCPgh8y0Q/k9sgXzB5rwc7y1RD5sZrkLkVuH2QGYjq+hBB7qMQF
# DATA aJJ4Y5WZiPqjtqEOaxz2C+QLGJzvIUDliBciTpxwPsFZ5Z7A+0TkeoXPgoKrL6IA4FzkCydlZrjjbDB2zJSOo4PVl+vec/myi0uN
# DATA 3rv2kSAy4/PhVwDNCMQAChd22fVqcEPVGVRe0+CCFVwC/tCpLQkdHF6qkmle8LZFnV1gjYNtCh8WRxotFfKWlv6th2gphdTBqGsC
# DATA whlZ8rA7nA7IbKtedtjRULcPz+KiQ44parIfFV0OTRn2O3y4vb62q90Mtx99f3ueCyIoye9qJbnr6u65DNr2f9/+gq7z5mUdB2HK
# DATA ALNcz5z0MsN1ah7iCkqvSnoO89VZ/8QWPwP3oHCsO4TPgwXKmbawEqdDTvfawT53/UP006Dh7wrReeUAHxxDog+OiJnNW9hSH8J4
# DATA DJHxrih1LRWFelwZl3kDPpRyl7pqmKAHmjJF8SnEphayrrQpC2MAHvFSPjbaw7PKuebKVpulCv220OZI7ZoxHi0VXvnX18s4QF1C
# DATA 5cpGs82RdCcrqlmLYsY965D/oq+IbdGHzsFa6dSrL+9w6/fXOClOWtl58j107mmIvb3C0EZFtbIZAuxU6tt+ErRi48d1m4BmcfOg
# DATA v1l7vvlcppjwfQ2qdSPW6TfEn+ZtnuoNVLFHqiayci+85SSWT2T5ZAZ6Ucb6/V1ZMt9u0FxugzKKlHph/KWrkWfuCaqXymL3hrWY
# DATA sKi70wFS5n6uMagaSqBD5eJ8lGohnAnIszi+ykGVei9weW2CbvNFdpbXJIcMcYzS0MHAMFPV/LCh7lWQyMlt3IbBqB7U5unq6l6H
# DATA gvmXbH6WyQmq0ZYCaZUYMbAkp43MFtZE9HR9o6/hr+b65tb65m49Mr9215883f3UPFj/ZGNntypRUTmppAPgWd5oARW5pzhY4zpB
# DATA GFgmFYNO1OVSUIZdA+wvHTsqWXjdYB2Qjp4YgD35ErS6AltAzRfI2YUIfJT+HViSSgsAFS8E4qMw672SMu0cWBKSTGku/XSpWCul
# DATA eLVZXL0Er8a782V/NMs7AWfz4CVHxqSjUjVcykwOKvTODVCoXRQMc5eNlxmKhMmJv9TuF1i388q6yuA6l7RhfVsQjjTSTiX0jVM7
# DATA KJoKsprnReNibUPSMIOYuqQ1mAjC6aB0lyN0uyvzliCPQODQOlG4JdejYCAGUKj9ggUBq3GjusthzBbYsQL5YISBOecUgYq1+lhC
# DATA MlrJwgQV+6e99SgPjzUPFvBE/LhsZw/5+gK/tjCMilOFH/8cmHvcVJ0OzEOn456qko+dVRLo3udsJm0Z812eH9P5aeldJmzsrUhC
# DATA n7nnreUOQ722R6UlzshFoZOkojPKuKvwzmLJbKg3+VVFCEJNlW65gTDuAsv11lyw28Jd3b3GGq04wj42Mb4oBDbEW64yEePC0km1
# DATA 5VUE4csu+hKsnDRNeRiPl6RRflQGt+qrq9Xw95CSlA+wUnict+ABSrfojiv5VCIlOfneMLXblZK+4XsvgRgBxzpZz1CMoUHjvuPx
# DATA Kw6CQAVafxHzcew16LyjHgS8Txvsk0rfAY+J68Lp2fxApRJGVfSnohGD4rRf0e0GN1pZBAlLY0yePMVkcCuVH6u7mP8pJGwLF+4P
# DATA UYld+KCqgYJCpmygTvyRTuFGZUN53DDjmsYubpslKF7DkftTNm0i1Hs3b2Jqb86xLSSAsuAeB6gIZMhWeT6yeJulGS+LSKDLcltJ
# DATA UHGSjGWoH34pZCFXIihghLADvxWpi0Py++LtaRk370THeT0xecop4GyBxuDq454uPnSub35xebEQ+Yi6fXD8gum7Sh3ZPO3JfA3K
# DATA O9GiBHQYeuc3HVm6TIT23KWTt3QGc2eO8Zb2Vva9JICOjzLCS2JLyJFWTIVW/RveMLqd4hlccL96RNRidlTei8KorL7FB5DDD/uv
# DATA IOxA9bhBSypgNl6OAN4flHLLaKmcKCaeR2l3MsotevbEYoYXbrNfww1TN3vp+++V+wbzIexcjqlsUVuXY9vyMDOgojJgZGkFYsij
# DATA sP0nsJNIDgi7Uu5R0DqImiZ8vRbawMwZNQbxoS5uTQYQSWmvQubQoS5FcifvPJgbaykLQAP7nOMRJoCXUjr45NGkjxe0qjJQ29zp
# DATA /ZGIiz2GODh0iLVllWSstQhd1T6PV07FJyurtuKJWYKCEoO3HAnVu9+6rrj1cChJBR5ZsLx1l7zcXRefJ3O2HIq33kYTyN+ldF47
# DATA XyxIuN/dJi7V+9qD6a9C5SDmI5eVzU25V/4Cet+S8093mnd98Ocp3Ur0ASSEF/a0Bx6LgQFYxKhS9pNEKOvK56lib6LAWXYt8zaW
# DATA zChS4BOmigVyOXP65kvl/4Ud8RXl/p2b/3d1ZfX91Tte/t+Vm+/f+UP+36/jf35SXv07n14uP28XruR5MFsvJE1X35uf05PBJfP2
# DATA 1qOns0n2FFASStL4Zl3FePNg6t4z8xiSpqsD9HBtd+3x1kedp2u7H2umbBWz1nQXm7PRUUw6HYyOyNcMXIp0HTqz7U1Oayuz2z5Z
# DATA 29z4cH1n16a/BYdGfAWmtsdr9PQuPcIII50Q9+7tYvJcgMwXtaN5bmPzI/ONeu++0B/evR3onCn1aP0pTsO3lnZ2VY86m2tP0OGv
# DATA aZJeEGle+uOtZ9uba48DBRoiQxIXRvE3UBW5r22vP1zfeLprCtiaDtLui9mYK9l6/Kizs/vsA0Auie9f641wk+EGenAf/hsN0uFR
# DATA +3o2vP7gPiYBRMCMbNq+jkBq6ikGAz1gX/f7y/Tz/lg/ATHZekLeXx4/uL+M1YMn+8aj9c3djQ831rcpTKI7Ohn3gacgAI5Gv0Hw
# DATA m9vvXzz/gdoaH69/Eih7iMjJd29Tmd2t765vlpa6dZNKrX+yu765s7G1uYNQB03oFUY2dPOc8j7SP/nLI/x3+mrKj1GEipuvuPxp
# DATA dqCOav9QseX4Qu3+7iBVd8UdNdl0tbK3LKP/zHUoTacItuUDbc0F2aoG2GIllulN/OjZ08cbD2Ej/vHO1mbnu+ufOrr+MJyWC6XF
# DATA fYeZINy+VtAGJDQLhLJ1cDYtuAswnFkQpM8L81kAtasjYLt03j+JD8SiL4z8USaebmfdGbrF0zoFLP6FedzY/N7a441HOIvqFoSU
# DATA Fb/R04MkzsOc84LCba7kxEHIh1huRqZTv1a/hRf7+PlzDI/BFxUde7a5s/bhemdtZ2d9F0lwnDgIuJLQyzxDIKiHgXDhekfIhNc0
# DATA Jp6OYDfQuBDGfseHk5mbK3hfpg3Gg/5tzBoMVQbBb+AFTMI5hSY0m/EFRURNpgKOqBlOPOh1o/adlmK1PxlPhj9JZ69+MpwNfqLo
# DATA xd6q6tZPBuMp/pGoQs+bzRvJd7hXcC9rbhSF90PuhQsYnJhwrXx2eNh/pbbvKQjU+u5riVByhRUNIAt2eiOUTy+975xl5b33ILp5
# DATA 59YCR+DR1pO1jc1Q1hZDzLDG5gSygo9xfdRq0WHv94ap+qnPfpp3+331myeqDOjrMidUd0+eUYmkxZm/abhVKa55z6otIVnT3dUL
# DATA /QZ3iWJ1UjdfHmIEkw1lLenWwPjNOEmSy058kEaDUq+AXur46rwDWGy9yeG2ZGpqqp127KRULdvXFPptt/V/7zDZMB3qIptOFdmE
# DATA F2AfnJL4C8/6B2oqc7zbgmL21e2VlTksGydo59Mnjzc2v+t6EoZRrKsRp+c0JhdlbfOhEq+3tt1Ga6OcHO7gcozIaqSjL28y6NBV
# DATA ic9dhbu9yGx9f3sD/XdKhmDnrS3mTfgZ5hid9vaziZ3Z3NrtqA/XH6p+fHrpjqBV/eoA4Av3UNX37PHaNl53SjG8O2ShEDjJTEEk
# DATA pbEqy8JRNgeZY/NuyAO9nxQShNqTG1YXdk7SF5nFSbew7og3dedO+WlBQmWrL1ArrB0HJeq0IwtNjdsVGqDYJGj06NBYLdIz/fYc
# DATA wSaljiw4X8JM5GaBLHqsqLNqlwyPLefQhP8gU+gc9trUItVTXEken4/bXr4BhCMIJUJte0DsmjyOwCPK2oiIKBZef7CxuaYODrwM
# DATA WY86Au8dm0sE8rqSOLL0JIAuakKpqMSC+Osa4FMcOfvIjZOyz+chq/unEbUSjzeebOwWsdS5t2Vo6unhNJvMHV0Icx3dcG2f+8NR
# DATA 3RuC/H0CLvGdIQGQ1rBV85X5RR+Zn+abCpEAx//w47XNj9YfFWHcS2L9nDPV8jaxydbqGFA1C7tmWFjLDSRz7XnC6BTe0PjL0Hjf
# DATA 9rlUmaWAaY/evEUpOnS3gMxiKHztrbY8NEKNzG7bgGsLVm4OfCh+sDRSzrmvy1FgSyGBqzJOUasHrsj/ywDELyMC0BLbzl06bLBA
# DATA cwKZid8Jva/IbSHaTeZHPJTQ58tZt+Zuj6INSx5hd77FG+c4EJOic1ZwIgiyLV4T0A1pTXItpJQap2dQBrgVATMJRbUTL1jQQFcn
# DATA B1nkNkqUjet8srGzs7H5UfFO6nSX4ZHaut++gsziNDyfELqzi5lhctfqZkFXBb8LLA4bksHxOs0rawe4gAv4TCne8AUCY/BT4H9z
# DATA uJy+vzpz8kj9KxGYVfFJOsBElNDGngCCNTjRjLoCyAtoywOzCrkU1vh7Ppdx9jIdxEkFQKOtpnkw6p3VsaqHI3xNkI2YMMIr1nQT
# DATA SChu+w6GDvyNx8Kj6ED3/ba9bHzjSQ0+JDBI+uwd9GWSnmIu9FdTo7GR6tmwknXnbDhNXwV1q4oPq2m8vJo10MeAPgfVOelpwnHp
# DATA zhFe9GxKwYuFLlJ1Q8UlCjXSR2M+CDwV2ZSFq2tgW8i7x9lJqv2Ec1JZ4m6CQnv6/b6fh8R96x2shWZKi1Cj05yV7Hvch/2SkUBR
# DATA AVPqqKThHWqkHQvbFbsUMHOo+vGOqJpxwTuKffQmWz3hue73MJYHzFDkz21cyRGVDQIWcf4LXKvYxh5Utu+qSa3JSqoGdVksZn5Z
# DATA vV6oPa1k9NoE04uXG4KfNkl5avBf9XPY7Cfpq/7J7KQMzl1it3uw7TzhXJMxNukKQftWM9O5qmQbQLlzZ/XW3ZVkP0muQGxknCdj
# DATA vuHs0TJVwelyILDZBPD6lt6nFJaqN6q1+16mh/iBE4c66CGyF2w3NzyV5BURqUK4JsFYFbIKufBueoTqYbOr5C9oCuK0hrpRHp8Y
# DATA PjdmN0r8/NXKCqpldT94l/BPn3gnc5A7Lj9BGsPt/Jy00hcXTne0YI+jFJYaNLsmi8r0VHVHEZ6H6x9vPX60vt0BEMb1T3a9ntDM
# DATA QSRCzZtXV5UZI9I69UIbZWgrwqTeXrkdfhWkHudxejCaTY0lGX8tiwYumn1ME5GhIZ+36UL6ue31f/dMXS4fKUn1o/UdKz46OB05
# DATA 704vfBt8pobg7wY6IJSXTXif2b7uE30fGXrGQty2WllHOnBbJ9ykm/FCowFxW63b48cbYPoqmp8NBd0nglBq3vBkfZ1t7VyRsJah
# DATA apqokbdYBX9ILiQX8m4TJOip87xv1WHo+UbMCK1uBQs+TFhLHwErrYsjUkdnC419R9XUox/NRlP2/EwMaSgcGhutmwkMtgq6xE55
# DATA ksRqKsV5GXivGBvgfLLhOlCzGUvPFfHn2UlVhdXfX0GO217fBLogxbjQ3qHlQ+8jM+9qLtQSTbXClh6D/MdWVV5mKVN528RgbHNN
# DATA mnC4Mk3A6PLdza3vbxJl1ZKV23mx3/I9Xf2+2XrG4Hc27EpFmNB1tQO6rsV0FNXqK9pnl9GHBfXOQc0FKpJgSCGFQzB2tEppI8M2
# DATA SWQvKG0uoc3+/rYcrBMAsf7Jw8dfuZqbVT8QOFGi7GblLw0bLyT+q8PBLD8W8oyZ74LemKeQzm/PcTDgHVoTbuXsYZANc8VBOmjU
# DATA bzOwO1ChDsCHcD6mPFO7IFXLlLchJbwaTitOdNqQpHDr5H6oD076XZ4O2ZmSlYMTM5qkmGkYd61wQxSOdjhVDYDYBF/GJvzntiL+
# DATA xxlnn+EtZGqr+zMSUN9WaN4WP35z1IS8dprFiP4Vk3KGw5pDX/PRFqc8n3Q7ztlVBymfdkqOs6VGTfmqcG6ZYFKbJYY+Dto25cxO
# DATA 4BdB5b8z4e/O/lbIAh+0u4mO8eyF1ZbqpMHdz+R65NhAGgUF1hXyzcLj8nyzxnYxybrq3iewtKejKerUKJwPgBc5CRM3pG5yIssS
# DATA v2+5t6AJBCCPkUxygeZ4NK4l3obXZd0AFoeNODaWOZyqsIJUf+mBKeVZ9N1XyrU4Py81qnP7is5APlbxy0/KwCMrDj2Y93ex7MBe
# DATA lmDeGCZJsOfsDMonXOIHUdGXuVXq2xQWyHa314vmTP9MAWY2DjtappHgAoWHQDYmKkUJtIO5g8MBNpmSm/ovM80G9O/OdFRj3EAI
# DATA AFJ7r5aUTWC1owsu5tv4/5RZbcIgFXZguKImOUFsgzjrZtRJ+ff6KOvvWUrCXQAm5vCX5RAZC9icSgyCAljUc7VvEP1qVTrXXXET
# DATA Wur4XtvpSmnpXv8oy4FSc/xFMz9Ob965Wyuv/6twhgjCk7yFg0Tof5dwmihZ23foSHHNXR70W9AP+sMRHkHHj0F+oX4mrbm+mYu4
# DATA JZSfQ5va0O155WfEcM3H8/t4wEHZ0iHkRN1RIVX53bqtKZnvisrrgzW2FsoH+jYTZI9OczYGt6oaNjz/IzuzDdLzLvAdKanMBK1+
# DATA xYu/mPtNSUe/du+bdzn6AvtBPDLLeYrD4T2grlb0V02Gegav9qVi0yUcFVhC9ki2ucRpFRmLR0ki+2d0LIgq4ipZjL+0BDF0vKhD
# DATA EBGeuO6YG6W/XTHaLXGVQ5ifQvWK+0Z3fe5u6J3pd+2KlswX/SFpUlkThcpUVEVZOxu8Vnebor3tarZP+xgbx4c+rBVGqocSW3tD
# DATA 3LMdX8TC539SCC8xGkIsyBOxj7PmPgoYc6gAK2Tt3BeGYOxbzgcBO1dpG7ga3ng/Xv+kOFAst1AIAvmm71p1pdU8s3zUH0ZOh4uG
# DATA sZBRLGBjx+oqO48lLmWIlD1fwNEQGI4iD0oqHozOAN4qpDW0b9VdxsRpOhIwZhKZYNhlYAM3Xq7qRD+uIknqL6mKgl/SOpIfL4ah
# DATA GBfhufNmkEgN68MtS39f1iIIQ40LoRVPswkC7bH/RwmYbpjtfPBs59Oin4dzq5eyrcSeqRKqAzq60AxJbcRwGgdABynq+SR/2Z1M
# DATA C2/pMQbkKpnFyWDArx6rnfHBY0j7sLqIhq4AZuRcLRZJlqDmRfze/KCwWNWIx5dZpKtnZOioviBEcW2QHUK8Xf/oeOoy2vwsbwIl
# DATA VrTmxEnpohjs7FWchJMFE5RR/4C1wBRQ33z46PFjxrOf5VkHA+sF6MrhbMg4EWZLcRWEDag2SDq9qbYVBlXpTpqvKrMXOw0008kR
# DATA 9ghTolPfuh2E+zO/wGGjMxYP5ryeqff7biuAHgIx3m2nkqJ+FOYe74fwR0frevVbWhN4jX91AkpU3WLNqQAFY1bpwwvKdFd3qnFL
# DATA 4Rtd7CalRC7NRcugyD0xPrVqtKjWOIcFIIjUIHPvfLpjYLmRpplfW083t3Z3nj19elGxhnQw+PDUuuiiCpo/xUfNE2tCQZh1cmoE
# DATA BUs+VYcDZsrRXuv3didq5mLKe2ph8SakGQ77U6yDemVtd2Nrk3QtOyLP6cKHLHBG5h6u0tMz9wQFR7O2u/Vk42FHG4AVv+0821z7
# DATA 3trGY3ABl348X8txW/TIFY4dLTspZvDPwtGTGwaKid+dEsOROYpelfKYsSMvn7NipW5pudf4k1UfPtMGT1Ydx+Kqzj1GBgqolEGj
# DATA LQuFytAxWyqy2KvtJzJv8cxJo4B3GtmedE27Mjf9depoE7f3iSEZhNqBmGpCvHQNn8bthAiFCO8PgtaRqcFWpnu5HMXUWh7D30Yo
# DATA heucQ290e21RCfo/0nMQ+/3KczYs6NLW44PfLxgs/MHaw+8+e9oBfKuq4GfKUlIQ1sMqgBHA9IGlTpE78BZDhynxbcESHVQNTNJT
# DATA fc0uuSM4twOLCOO5elTd/IsI7iInrE2rYGDdrcNSN1OSlrOB0kn3GOwCrTL9AxdQfZWYMhUaiXegU7AdNCqEOqOYfd26BMbLKagU
# DATA +FJvO4o1FHdcGSJGNRiDe63lQ+w4Su3Ji3pRHaEnBKdsv5BTtBbUDnDp+eoBLpgki2sI6MTGUpKxO8ueAueSTKEH/jaUhUsOR7B0
# DATA Ekh4YDasRwvA01+ebiR36WmRfKLYYpU8PDHzpC4mX65StdiE4A+eCs/GI4Q0FxQSOQG3msw57IKL1KPp6EWmRMjRoFePhtkpI/DV
# DATA mUVJjAi9DiHStmTR6Uu6TtHHomlHzBMswmLW9rKXMKfiG/flQrdSmmPUh326s7v+RMiAens4TajNUhM4WeAChFMk3Bq8AG+uBiPN
# DATA V1bcaJyylRRqnPCWNkEmwZIuDTZaa0NEW9GqpqOtSnpWLwhfkpi1ApRMU+IWbpni57T3W9HbHCWZBYNkIs2f9D4jZxmHh8anp6cU
# DATA dgabUJGt8E6FAurF5WKPmSF684v7Qv3NR4jlJc7pAWKD3O2QY2DQ42lT8lR2qv6GA+dMIZTZeQcz6NWqF4XPdkyHGx7gHxcybsrs
# DATA JuTN2vXWw9i7Ed2cN4PmC2lt1/56zspJwDtyyAxCCJFMdNgf9vPjMnrm6EH5BiG8XLMD2Py+9IU7R2beOyoUcZwDsUSIMojMQotQ
# DATA lELTQe2jS1GRb9Pu59EkDjg+vdIdQTWJqiEQBsxJ3qhcXU+Nr39crANtSPJ1Kt7gDFU0blR7XEWdZj0JRCvTjchlNDLikBe5bvdf
# DATA IRFdngdzkczbSlTND9UJGaKvXOmelSpJLl40/+kXV7YAcgX1kuP49mI3kTOXjjHVYoJVF/TJSOKWnLw7mXwBsx121hNSEfGxaMWi
# DATA oklYdheD3dcY5nIXhCT34iU6JE0vKNCHMeR8CR9WYb8emR+0CAGRPzhbsHgLCPRYrPQSQYu88C2Ci5tWg7FSHrSapZISpzPW49Z1
# DATA XubGsbu9trmz9nDXRhhpiOyQQdxealAqLb09uVcHrohUn4vwDXdjLl1GGA18KtiOFREtZ5nL9bJXYyXKYlSj2AeFPMXOojOKN108
# DATA 4dzoSt5yXTqLqEfmXUS6swnqsNpvJUOxneil5k7QpsP36vzbLr9JCg9ZgaC88SdBeP3wdBauobr75j5pz7tNgjLAzWLnHd/gzLR1
# DATA B+aq/WleXVGXkgYKorNUJYhU6ZLk7nDEgEuoCLiunpl7I9kYBWspcRJ64En/CAO43KPlfrrkGsWL46JakupNf8nbvj1jR5kjx+nl
# DATA hVmnpEc8EUE7iLkR8UjlbSjcxyv004qNbiv1yD8AvigdPiZw3/BGyR94u7p87HZbBq7X2FXbaEDGRfk2IIyKnvpAcKXiaMFUT+2b
# DATA Ot2Ne4lOCgpUL56HClpUDx4ZHDPOu9xucyZeLFGFhucyQwkMQJJA7OBiXIVtMw+3vre+/SmEgX/4eOPhbpxU0S0z3PnHqzis4koW
# DATA F4dsnSUky5x20yfMicMfz6WWlQP+OnkjF7hmGI6b+rWciy2EcxrgTfPTtukoMCtLVB5R1kbY0qz+TEqFH2msw/n1W9I94OuatBD6
# DATA S8GXvnO+g7DSSLPP0N61+p0oPsqG2QS3pPpQnxNP72M8FVtGYDO+i3OEkQt9S1aX5Gk/HVCEtD6tjhsOPyyPQzMuGeGor8vEJhud
# DATA w2XCk3UH31Gsl6Om0TEWlw/vIvOHYRAc5g8uV6HArcP+BINMhpCyh0v4/hLazo9Fy9PDeovif2kRESUoBlwbi01Xe18XHGS80C1q
# DATA btHQrVD4yFsCLhehch+QTdCJLLlG7rY6S0ay4EAL2jxnwUF6EvNbCIxi/ZYhixVVhULCFuuRY2gu65gzdlTq6V8FZZzpbb0Ijpe8
# DATA 7QhC4cKLxAFU+RgCkFo2eRny5XUh+LTOwGeqrm1xqWQyWEmZFCsUIbrMDODNDDKGx6ZzoGMjGRUMCBw/LwL7iHEErCHvjh34DIef
# DATA Gc4lWQbnx2RMDXGD8vE12vFEEc3RCcaHYMy5BgcQFzVpgqxE4oDocVA4clWGNh2MRoOAK7zuhFWLmUfkBUBdMzfuYECAQQpZWB8F
# DATA ED7rOwZYzq6Z47DjGNzs2bCqnICLOV/GbOlFVdc2/LugvVazElJcOyHoNN02zoVrg9++ZGAKVUkVkjAFzyeWklf5drlnVME2RBiJ
# DATA 0GMhyjk3kSVhr/ZbJVmkzP1fB0C9zFj9s4ixynRKf+dfVsQkB6n3AiSDEDYKFMPcvYLhXJJcmN65ATMuTRCFxPN9SSZEEX62f+HH
# DATA esgNdeUNtNgmupTaMcAHQteMwCjCKtRysXnxzpO2LrB/ScqiKYK3oBw+dxooC33b23dd2uqLfWUi/SqEh7r/uXnjhP+VdqByq4Tu
# DATA +fCMkZecybjKVFcAPRHa9qjfJTfifk992D/sZxM05YifjAClu1+bv0ks3iZIpvBEVNduF/l4YhWZeTbQev3agvzeozfE/znpX5OG
# DATA WOOREiSZYZltwTLxK/3GubnrHgXhsC4NiSUBIx1cLN2OwMWysf0vMpAgfFyfgv0/wGErvQB8GdZ3E2IlkZeO4rLAkdN0oq44lPX9
# DATA CGT1AjwGcy4q2PQxSiR4EZYwDft+rRYU6/Ztt78M0GGR5M55bDckxg9DCCqySsmdj7Lm5GgwOqjFN+IkuagDFl97kJ4c9FIs1vIz
# DATA idV1lhCKFAhpYn2ElGHGaq+is06FM5QTv9oym9RGsra05BoOe+aIxpYG+vOIXBn0pqNsm78PLspaZ3cs6XnhEErHqcfMUIlnzyKq
# DATA uaBnj2OGMFqaawEPkEVDy6Wu+7JujB3HPikeFbIJSumJqV4vFlJikLcggYv5nhMUtgJ+dWXCV9nmc2SrwJisVKVnSgpVGt0Qk0QX
# DATA r2JUsG4Uhx3bWuntKwiWXvy63MsgUHzhe9NH65vr22vCXPyVXp2ueruwVnzRIyqVeHETXFREhchGNejzgv4RujIMwrlU9ES86MUG
# DATA PItK75GJc2WsKhf2f6oC7DF+Ap2n65uPXLxba80okYEvo7gpGi4CGxbHt6BPBNe00Djt/g6QQjZHk5hTbnEPOSLSvHh+Ic54TWFt
# DATA EAS+rZ+Btyy1qAf2VrZupke9jrcuQU99vhZT4/O9cGw8kmzCXyT3tVwtPWb/cuD12GlvrjRpo7EWZWG8aaydse71wfjmO4e+mq/R
# DATA 92+pFHAVAt40OhcLb9JK3JKxTofL2SFLlQGCQRdYG+r/lAj70s1jqeTFCTpCUZ715trkaAaT/RTf1ATQczveIAYeHcyGPcXGI0X+
# DATA 0kEERFazixwJ42g2jXDeQK8FORGgz3nTJNSFmgFjvJNyY7W40ZC4a6CXbD81aoKyL0jarCwjcFbUJKRqZowStfI7mr3GhJw6F+sP
# DATA S0DAXro0YSRMTNXGqW4N5ugKn/G2WbiDmjw3xCbSfBgB1vg7/Ae+zHHDJME01fC6CR0vnH86wMUrP7pS4Gfc8YJTDr50sjhac796
# DATA E2IvfhkthurfrAKvtLvxsCla1s6rGsuPZqozeSR2JxLF4FTWzd43WwF64e3Twjw5Iqc7AXVntuqlk8BvgqrSohV//jzbOVtsvvzJ
# DATA 4e9TO4W9aDZUdzOYSdgyUPUsV1S1ZE4ci0hwTrRpBH9Y04TcAlWzMp701ZEQwMvU9CLIy0mBdazMM2MFcEEKHTiPsQQzFfwbLv3F
# DATA /ii5GO65bcAZyKfqOj8pdGhVkXxzXE3CGVC12SQrArLfnNT9pbAV1akCgPzh4oroQ50OKrI6HViNToe9EKBrSr6d1pDnqAn7xuX/
# DATA B1wF11/rDpvjs2+84/+tqP/dvX0b/1X/c/69ubp66/at9/Uzer66+v77d74RrXzja/jfDLAjVPPf+B/zf37utfPrpJ663lqtX0dR
# DATA 43pr7/x6v3e9dR0Fu6miD+qoXK9fxywV6vHrv33z0zd/8fqLN3/2+vPXv3rzZ29+9uanr38Rvf4iev079ddv3/ypeqaevP4S/nr9
# DATA 2evfqo+FwANV/J/q9T+//gdV+KclX9Uj9e9fqBZ+8+avVZHXv4ZXqlFVVFX5K2hN/d+v1NNfv/m56sbP1L9/oz6kGlXx3775K/Xy
# DATA l6+/aKrmUYV1vXV+XedQUZ24f603QhgITHrx4Pnz4X34IxooCav9/Pn1bKj+8+D+cZb2Htw/yaYpZijKsym8RO0Zvsc3cGjh8ct+
# DATA dgqwSOpPrUGDx6f93vS43VNSZTdr4I+6tgQ0ciXsZe1VW9fxdDpuAH1/CZ8+pFoaO5C3rD89azwdDfrdM68BFsIa+aQbPY/zbHD4
# DATA PL4X0ZT7D6dng8x71j85cp6gq1zrXjQ6+KFafn41VEwLCh+kedZQfRGPAJSlQWKWfVqcHbEJvP6vRS/7+Qyl3ml2MBq9iDBdjZJy
# DATA j47hTnKsGMnxaNDLkRVOj5VknCq2GOUnIDjTZQISKkeg7VbPFVs6ibI0B/PEdARMsRntTGe9M/x2NOn1hwC7xEiySqADkfoEACGx
# DATA 17jVHzwF1TaIN4fgPRL9JPp3s342jV6OBkr0u79Mhe6jv84kG8Aw+l0ameruIfxeTnO1X/JleN7MXx7BO5QpoeyJqn5ZPXzv1ckA
# DATA W5U14Srlx1k2DdUHS9Ds5vklP0M7n/6MlgIg9AtFfgglQLDPJg/uL1NB9QeeBDgmkO4PtwgqgeBzSSqwdnVYBqpK7NOL/lj25pvA
# DATA vqDQjnoBq8P74P5ySqcNWhXfH8DFwhmONe1BNe6qqDqG6Uslo/TTxiA9oGl5AnKTetw/SnnzQQsl9W29zCZwjrEuUSpX+6ef5abc
# DATA zjiFAxzxc784bEFTdhv24+lo8gLXBosuq/7wpMKASTTswad6fu5zaiY7FWOw9cAXRJlWH+wep2oJxyATm4A2tcXV30pWGzZV9asP
# DATA 7o9VsSyCb9XxOIuO05fqj9FL0O5C5r9jPACQyhFfw2qgmAk7ddSM1Lfq2ozucEoSV6dtCkfsbDSDpYOPtaJKH13V6vjB/V7/pe03
# DATA kYbc3xkHs+nUOzDuUnyghEzdzEGm7r2At8sT7dUC5sHRsKdOtVPfIou2rPoK+5xmOzDt/IAm/eaDrUk07quOzcZqkhRpOZypSRmN
# DATA BjDdN2G6H6aD7gzNkYeDEUr/WUr+3RFS+6g3SU+B4oBfH8ywWi+zOaLeKKOl7GVTQCtUNwglu87gbKmOg90XgWsQyKg7UiJ6H5Tg
# DATA NOuX2X9mvMuw4R7cP1SiPOzEsXui1O6SUwFaX7olQL02d5SqTxV8oNfe6YpNRAbfrCFl/6P0ZHwP5PWXafcMOhT9v/8cXar/tGq6
# DATA 18tAlOA8MS9XTN82+wdu/wduP4/b07a8ApN/xzz+aix+Pof/74jBv2P+vhB7vxx3/1qYO+1IOXzD0P/1nCAk+PN5p6L0ozzTHHRN
# DATA s01S56kWkbtr/imHDHJNaoc5OuQASDV2ta1QrcJLxFPQ7U+Q+aICz5sInB4UaTQLzlGdNsjSCUL5nyimrXbWoI4MWA2if5L1ooNZ
# DATA fzCFEQB9zGnIqqfPcvgEpS3dPz0CaMFy9K6WB3JfICBxYDQcnDWjjamW4bqQ5xs4PkycYluoabZmbS0KpD3gMKhexC7CojRQLICz
# DATA nueIYxTtZNmL6Edqr4CzljYuHGeDMeqqoJNRengIqwQCSXqYTc/MCD8dzSaWR/PQlKSTR5PZ0IiaB+DslE2a0TonGoIphXHMxiCt
# DATA gJypdyHs8RxlGFUAUiiMQEhS5CGHMungbNrvonSjxpZNpmDjP1JDSMH/Qru2QV3d46z7AlWeaNpBtafTmf/20/8t57GClhf9gvLu
# DATA aKzqQXlSrFkzegjrH6FdHhEv1MDOYORcF3wBXX0JTWQnaqUOdaWocVVnPe0rWjTI6igHQhYTEJRpboe25+pMTHGx/z/23rbJkePK
# DATA 7/0q5ZC17BEBDKrw3M0Zefgk0UtSNIcSwyHqRQEoNEoDoMAqoHtasxNBSd6VHdq4cuyNuBvhCNvhiHvfU1rRnqVEKsL+At1fYT/J
# DATA Pf9zMrOyCg+N7unueUqJZAOFqqx8zpMnM/8/eobuMDni8cEAVbHmd99Ojmdi5iEjZWfZgGoMdqyVoib1VG7JYIRTVKmVo4cbRFLR
# DATA x0kmRYs9hSmb+A+iaJ436nAwgO0/SdAYBgO+foiAYigkQniJM5NGD4ST1bwPE75vyaVGt0cpFxny0rQoBDpHhMeR7iSo+nyA3iZe
# DATA SBIoaLu5UI4tqXJzNVetVbfK6CEZi0jiMQVmsmLEk5dCQb5HMTYblzKIe2A33lA6GA/HS6iE0lifKx2GiGLNexOdj+w9QJGkGBcj
# DATA 6ltUdaX34PwW/yZVSln7l57m7DbY7DTD2dFMvjFj/zK2/hWY+kWjiez97z3qJw/JfPkF8DV9rqVVuvIYDz0iiyeZTKr9iObCcZLu
# DATA Z1MKevwY4T6ahinVhv36AVY4DlO4fvaPwnSvWp2H8yi9dTBIJvSIXCK77NYB+q99vzN/eNuvtVue/IKwbh1glzl1+cfV4zSc7/ep
# DATA Bj6oUtqGj8NHEkw8owYSLw6g7V9dYuso2XpRNRmNKEH7tSCIpo/D/THCecT3DMEC4UZSpco/eDCjtrsfzB8+lkpSiWfz5aIi+7cq
# DATA eAJjzSOOonqXvrMmfx8N44yG4RP6mV89mkQPD2i0OJxVecvf/iACJvrg59Q649FJVbUvfZnmp2S0YFzdbzbnDw/mYhzsU05Qn+n5
# DATA NR9/D6QE9v35Qy+jKc3Qs/JvJaPRecwWxZym9OrLqjTTcBgvM/WzfKlQDKQ8qscSp3arfkBTqYzCmSfMuz4oZeM+JjAqT2qmienc
# DATA ya88sqJJ3dQskx1TK9VBBfVTtlCxlzuLhnew6PyzRysJ5eTbAUgVU0HsU8lgVBk+SubhgGaD+7VWS6dGzQGpcozIQMiqZA/GGIHU
# DATA o8WLXClK16SKlC7qClO+dzmlZnFSvPqImjZqzH6jVKh8F9V9+VnXZSqaxxIP6q/3fspTJB7GqVX+7JZ1EUWZ/OzWSh3mmfS+X69/
# DATA t1Dp2lTpNtQuvP7W7u04r7qoubWOVXF1ZWvoRJTiX7EuSvxVdANqmgcqqvxZKnF1tROhZlfNxil92a8/LgRHtvrPHunI1R+bDLFy
# DATA we/WKWyqbPEvon22nGiYeszzI9O+D9N4eHBI3VCtwSkrNJN6Xe6ucZLMM5s6Aw6mg1DK7d8OtUmhjkBdoPJ/tLWMdOr8WtDSoUoG
# DATA UryiQxrFH9kBd+p180jdqzXpkcdjvzIOKuNGZa668OoimdPjY196P3kd5lcwkyWgCkjLGO+m872g1sSrK+1a6+i40qrhyy3q0etN
# DATA FVOVJ7cOJmQJUZWA2xURkF+pS2CyRqVaqzda9OjBNHyo0uC3B+MDFal+Qu1zSgltcKSD3SLnS3daaVDUAs54RM3vnhM1ikvQQnYW
# DATA 381vbsib6SWeynUKsVEOsPgkt4zHyGCdtHZnMH4cTw8r2dGhqTVMQjuw2quqIOFykTyWOXGF9xnIiK6aCnBxflCnilzBhGkPT3pV
# DATA r40+3UREBik7pHPranngYnc5jf2L4yiacU32a61SVfbrLdOtmGxbV3Mf19h7IXnZkbxsSl4Gq3mpcy2oU4VYOw7RXKKYIO4X2HrA
# DATA f6ThBWpo5b+P2R1ybi6U2+mmt3uhjFzKq38HJvDPyqbHvrFUDkrN8nEN3qBHEE/gG0fxw2h48Isq+2Ao3QdolFUfpXwA4gblNDJ6
# DATA QxdtugWkk0OWIegRQsGTj2tk0iS6c6wKM7CNsiv2evQfs2cNfe9yOsv2/VHq0b+b+jduoBy+VyPLgV7DaeUuVps1eZE2W9QQ5O5R
# DATA fLhMI2NI5lcHIXtDrXBq3SDN2ydSVevya9VU4vy60C0970sbrSmDv5Q1rXperfnu9XVaPcwdUjEKOzcmO1Op+17p/lp2LPlFHnWG
# DATA xbso61Byj3YoyzSa06xwr1Ghek6FslevUMlSt5HH6HFtEKbDR9bIYo06bR7qy7UwW6YjHOE+x77Ybo7Ke735Pmb/1cE4ngxXk8m3
# DATA 1OA+r9SmS5qUPrINBL5CAeF3u/L0JA+PsS3ftgZ6a9vUevO5RZ1sk/5t0L9tmFalcuL6WSgA9tkVm8sGQ90MMAik1BtKmvdni7Hk
# DATA yV4wu+XptGwqiWDVantcM37Tcl2nboCShU7C3OIpa0Ay0Az8GFox6uMDQoSv0hrkOl20bb7q2YNfp47rlJ54sUsdpcxUPY7uXgqt
# DATA hKE2j2vwLRhrL7jOeok38WLOqomox5aamG8XaIHB2hbIYclmwEeFzkrMPbuf91Sd21IHVMp4/Gium1FabaEh3dHxmA9Lorfap0kZ
# DATA 96I6RvuUlMWJSSOPhDXZtl6wsWstbTWr5hdIt6J9kWss7aaduvoB7qryAo56S+7HnMSPdjA3SnMU6jlo3hQPokd2lpTnY7o56uYh
# DATA 425NCoWml4eWEWWiXt9hmJBnvRDTDZoP7lBJCnXDM98CfINNt9og7DGl2F979d0MtGIsvbk1MKufMhrcZ4ePSn4DaiDhYdk7Iqbt
# DATA lrppCiiQSWRarDPd9uqkckPT7Icl21a3pJWxtWQXlLtwMQhUkJ5MCvHIvm/Ns/wm95TSFPKMLjtvhmE2jooZ/NNxPBxGs58VGtC/
# DATA EjxgOFs8pub2yPjBHrLpbs+NMD/I39c8p+nbWdnd1LBLbrdwdnIMN/RjrI1IKY/CaTw52X+LTKyExuXKZ6+9H/f13vcPklny2WuV
# DATA Kf3hcIttnvJySONwPMmsbAp2r4/Kl/Ko5JUqO61K9rp+p1eY3XITVpOo85rrQXF05BgHauKTh9iwh/t1RucOBmC5ynfzWFqtz6oD
# DATA LYyv6oaCW4NnKrv5J6nHzr3VpZnohupQm8eTSTVNjs+3spVNvYjmptR1N9rMf0Inbtp/U3XQC7jwOLxyK3jMP+mCoy5yEs4zskrU
# DATA B3sCbddAHpgX48piKNMyzot9xKYwju5UGRfbbK3HNYpB9Ih7cunA9/3bVZ/HRstHZBkNYjMky8V8ueATCeXMkjkV79KvYtlmjTWL
# DATA 42nhIkkf6WF3nS0rNVp3dKZCP/4302gYh3uWidambu3Wo41OB9vT0Gij71VehWJrUTbJ6ujElUVOUWC6K9lk1xmen26cf5YaZQMz
# DATA Vzsri/NJ43RpcV/Nc6MLGWPaWN0cH/vl66eQDSw2FGeIO2bLisGweVoejLSPsWVZKfrBu/Zcyq6eQcl81mbsar1oNrhecB5WtJW7
# DATA MT7slhHXC4/qvbxwChOKQNx0aqpZHB52T/3OyeVOZM38hztyqkom3XNe0syqaTRcDqJhdZpwschXah3r1sQ48O9Vvrcvmz7oQzhC
# DATA uwln8TR3GeXj/AEvisRrftHRkNM5ui1KM6zoxaiyw0PsYy5NZX5YLl9ZqbN6BbYC1NywT/PTB2a2Ub7p8ePCiqHetYUdgvTHezid
# DATA zHjtE/vy9m/fPj4+rh03akl6eDuo1+u31QYvbCB6M3mIG+te3Ws36R9e9kWN92QDIH3ni550ZPn3lJ/zA3we0RDEe6Ya9caw2cPG
# DATA x7tvsFwJ7xb6wG97fm/cCI66PwyaR359TP/t/tBv/6Lw8CgYNUYNeRhRLK6KZjRCRk+fyC5N5GkyzylIJmp/G9+Yb8aiits/wS+8
# DATA by7fXac2P5mr9qLzfr6jx+wBiIa8Fn5iNuBZWdKre81my2v0ml7Qqk8a9cDzu41qo97x/GajmDHD9rAf1VdztdPwGt3GT/xOexIE
# DATA frXX8gKfHq93j+jv+wi6VQ+KQUWjkc95zNOFB5z+7zRbrXoryi9WTdE3Vl6KULv+UTPwp/Vq4Dfxymqvx5FREfF8qRWXfEMQ1L2g
# DATA 6R/5QWPi+77X6v4k6HV/8UGz0fMaPlWfoDvx651qs/OToN0tJq876EVhuBJkp0W50hv7QX1abdfpnyN8bNLlRrM79n263GrRP0f0
# DATA sRTzfrtfb47Wxby5saaq7YtUUfdxsvCR8gTvqxp+wPP7fdVYDvTUdv877Va738AF432iR/h/B8agWb0S7H8n8qNW1DlQPrb977R6
# DATA 7U6ndSAWxv53+qNBd4An2O1MPw/bjWB4IMv7+5+9dj86TCLvx+/RdOGTcEy2Z+Uebx/LqCusZlEa41ndpe10O7qnGnZbksmUd+n7
# DATA Yk16QdHp3BVDwNxuRiM1v/lBRG06DisSdGlp7qDsCINxVunUmkfHlY44wjhgtVNul+n9Vv8WzVSLIZYd5baZpwpm9QHtQy+OE4W7
# DATA 5gWrUkxOvgHjzyDGTqJHF1geyNcCxANYMovEaVW/mHHjwUVb3ohR9ArUNxqzhdRWVpJ2nnGnPHsrdYzNhuu0VB6vtvWfo6l/9hp2
# DATA 71EnEQ8WvJN8xhsgvX8NfTHvzl2zBbL2+TJKT+7zvoAk3ctuWfeam++laXhSG6XJdG/9c/cmE3rUelbt5fvr6ATSi/oZtPAatgNS
# DATA bHlu6b3uffbavh3BaTTF6WzBjn0Qzvc4UMMKZznjB9FJxRuFkwkq9y3vEQ78038lAJHJ5z1l9yUSIFK/R1m9Z0XqdWiU3TowVGGm
# DATA q9BLl5OJ931vT2JRG4cZXnaLLqkrFJRc2bcisO/h6KdoEbDY/oH3GEeVB2OKlXrDRULE44/tVPOhekm2QsU+0o9n8rj+4UDlRSH9
# DATA 2Yb0VyTeqCWzw3h0orFVJluwxWZNWkY43L0ayfBkD5PnW6YoIgjU/uu9z177jnh+P3uNgobYUDQBorWGu9XpDLoR3w5KQY6T441h
# DATA ijF64TBny+lePLyVp+bD5bQfpXsc5mcQ/aNfazo3C48O1SbSPZFzQ+CiZ0Fv+uw1fL1NzTmeHehjLnLG5bU89ssU0f/xx+/XZMfl
# DATA j/h4CH2Hepv3JjT0fopwflbxHiHgxygMeTS0G5I8/c4kYr2Mz14LORvCGnb/QbMmneCbji9aE8UYlwaTePCA2hS2nn4ST6Nkudjb
# DATA u4U2jkil0REZFXmkKBxw38l+VVkhUcH6hi4FzCbwcjufkhk2NO+NZkg4ygYPsBDeFEIf7xxRpN9XWisURrbsT2MqyIoXHXGx3aXH
# DATA +GMNqjH0923ZmLWnipoDouk4TYV+AnpHvDjZu0Xhz3DDYxXVf43o/VQOXIRH0c8okjV68J1wMN5Tmz/5RRMymrNQxOi4d6EI4Svi
# DATA 89OfqTf+K+kB44z/7vEN9Eb93E9/pkuJ8h+746HLeUvCl+snrGTJ99doVJksh1GmopF3iPQrvc9sklvc09L2KGFr6xuidp8b7d4J
# DATA 1DrNM8XKj3d+nyrmfUkOdTDyGeeNHh/oqO7lj68pG64veJ9OzlVklf68Q3ZQAuQuMqppart3hFiAHXzHW3v7vvfTWo0/Dyvr7jAF
# DATA RRZwhmRyPLh7tRIjkS5kEXq3/BmTrWYf+nI+1JvJCxv4Vb6/qba9r9/jfiDPSFi8pT1T29lxJpQMiqOoxi38sfxbrN5mwatYx5OH
# DATA eQXnWzJdbPSTyRTz8OYilIepDE0oKEQEsmIDfPbaup18drT4d4kYf5QIcDFI8Hl9kN91Tyzf1lVRPnlj11FlguQauZb9si3a+you
# DATA n0HCc0q2h9Q2E4VNNWdDfuoIqNqjv5J9NzukySBMH4/NeM+8ly6WapluLRvq1YE5ULG+ZqHa5PVG1R2dPzBXzQjN31RPLjfQqE9z
# DATA KzbG+Bb9vdzdS9N8T7RMTfZzJrM+MYf8fclF72/+hmKNCkH913SP/iTvJ8dR+hZl3p7JYmoIGYuv6VcWniYrCQnneo0TE3Rf/cCz
# DATA GgQytVjp6IJdNVh0EeI9dN3uNIuxyWsip+WW91d/5e3pqN25o2OCSHFApgqYfLtzRyUF9Re3yLIevflfcRSkufHHW5KW11+XglLG
# DATA DlYOdfbzl9zcwbdbckcerOQHesd6PiIppSIpQ9xgApHfbql7SsOHhMW1lGMYZTxwUMnrEl3TGLkdoS1alQLJMeW4tQEXHqIXIY6q
# DATA mlIm60BuFWscblQWx96tO3fZZvzstXfNoTA0k9f3YPZ99po0PUr/9+Q7zwG5uS+Sd7Gtbi+49ToS/L//UPuM/jd7W8+Sk2TBrlYv
# DATA XHg+zVhelwD4sBkFQA+tfw8ZT7eLt+bv8vld/+cfrQd1hHZ4bjCVxi0zwPxApjuY7Q5mn3cw2x3IfqkPZHuF7cbqHPRzfVDbeM74
# DATA 58IJwIl1fPv+nNXyMLLFQ8BG9Ont/HbeVszn5J6v89wvyqnG84RbbEcpx188znffoJ623Az1IhmiYVYqurLeZa3gyYVwwt+KB9XL
# DATA i1fSpAcJMlfedDIb6GgoP/bdH62sfbGZSvZA6eC/9Qx/4XRwBszvctHuU7lDD4bKC/ZQujjBpmLz/Fx0A7JxyCdidY3y1IYLmhby
# DATA ceRln8Y1D15dD3MQCvNzjgfvUoqTtOb9aB7N+JzviM/u00PqMD9XVo/CGqPWUZ30ZBsCY5hwN70ZjAUKaKZ0A3ZU3vFKPm6tI8Dn
# DATA iTnaZC2QkX2Ic2lGhuevccwZFQ6nu5no4H20NO5eb4bLrH4k74jpp+UcZkNW82BL8Y8Zm1TJCE4eajFDWGqq2ZC5nLAEwGiZkhWx
# DATA XFVDeDkP25oQnPXmrLfzrLdiDXP6Ok5f56Jm20YD8bp0d+5jC5slB4HXwLcJ4TyjwPPsNN62DZfY3efZcnUFS47XP9j+wKKI2pKj
# DATA r3FhoxMSO5Z9AjqTlRdwb3rrDfGJ6gY44/UoFJKEZp4z3VV+hb1ivP2j1uJNRFrDmpLPG6JwcRryfqOW2kwSzXn3UU169tscx1JU
# DATA xQthqgO+7RBR/ZSJp7lgotmota8wmuIZoZ+1l4YvvCGOVhUpfY+JlHnojYQ7/DxyAd58198P6m/cTpRVWL6npe5pbbnHr6ub6EN+
# DATA 122JVp4UZavr3FSrYPRg3gwWtuQRmQ38BBsS6ZTey3uCVTrVaihGL10180vS88RH/KI5jdMLyYHbEgTmTyq3ZJ3WDiW/pHeomSt3
# DATA LYMzxITM6gBsaSo2GqXZLylVEH4xBuUHNBhS/yxGo/ZaW+0fY2w045bPhqIZaONU7Miad2849PhMrDILMj185jak9z7WUJSqJyYC
# DATA ZqRdQjZdHL1slIohTj0O3ohdGPS2+XIy4R+XWIalQT1OtfH/4ywS5R0RsRHdn7gfUxaLxLwWkdJ1Hgu2GUeBzBIYFmxKoyfCvCbO
# DATA MC2kJM2k89MqV2yvTyB8b/VyGAP7EetlcqZxBy9FwqXx8lvN9gDoDGdnOJ9nOJcMJGc5O8t5uzn8HChWfkJv48aRiWZeOFStITeb
# DATA S5qNGFyMzhsrIj6IFlSgs0ORtitKLwoTLBlh3EqUBGSulCh6iGUjueSfxXZFKQW1ZfGNcYP157SQs27sFOOGuMyMSCUsGOxTgt5i
# DATA KNFlMexkNML2L8j0cV+QeePkmH72qIRkuOS8rnnKuICkJcXuCOMu+plkxB0D57klXyk+K05OcdBbhOzNvJdiuJqYkc6kyE7a++yU
# DATA Cwdk40BI85h6rDxlGHmrPGWQDdGMOg0nGW8Xg6WDJB6SLZbpXm1IhTem3oxLiZMpp3wohBmLisONSKbTocydxIjR/rJkSlbjQqkL
# DATA hrAKHnhaKWRLOt8OT7gn3p5QlKG4KlHGOo33lf9xFEWUrGE8Ymk/mt3BUIPAIfYwYh8CVauFbMFgujH9gqaIX9gE9D5hDI/HfEEE
# DATA yJYVM2XhGKSqqBNiLLr+8kQq9ckC9RmbRLck8uMoW5NAMSsKVXhVUNVUdbJS2W95DFV4VLIJmiCPOmm0zohFkVa0HQnCWziMcfZO
# DATA BjqxU5WYJNXej6H/MqRMJLuQbT8kH3bekowJfuKBeFy1S5khZajdU3mn2JN6Kq2lTkdxOuXFkXVzW07UJ5Q3Mh8Ho3eOY6RkJhm1
# DATA dWpBxnrOF78z8V/L/ZQfXB3JFFDT8zATW5h7J+8DLe5JvSvDHtiUViBu40OmxvOAzWNMDcjwpZIOl4sY3UaYsk7XVClPsvqpdCjg
# DATA QonbmCwEXFdTio2p/etZciz1E62Emgj6SAi26gS/nXD4C+yrRG5LW6QEzeFK4K6RxzaxSyy/Aho/lTK2NMQTA9dKebqQUnFT9pGN
# DATA RBkmKaQixwFp7MgIVxRkC90wTxFmJ2U1WTOfsGVlLTtfbOaX0Np//LhiGDqLQ8B50xOboPP/nf369I+n357+z9OvFCPnq9Nv6P9f
# DATA nv3OO/0nMG3ohy/o39+tonP+G/3whG56gvsZfvPN2W9Pv/Loy+8NROdrClQu81eAdn519tuKd/Yf6Dl6BreBnvMtvelPjPH5O/pB
# DATA mDp/On1y9hsdmb/QLX8UUA9gO46l8wLMZtAp4/gSdTh9+rMoiGYfRgmFk8YDbYLVvHcezicyPk+4R4ykb8jG8Zx6i4nljdCdI1YR
# DATA 51HuM8jnQslkosYneqmW+d0K1cFyogpPtRSH1inOb3QPctNgnXUlc314nbzqmFth0uWXyw9MRG/a3P2+fOcR/YoJOzyuqWE9UZtb
# DATA MZg6wM6OxXb1iB2svUdsfaJwKrmLkY1f5B4cMlkUFQzTMY0nnI8st58tMFMt7VbWSE0EYQ6lxIsVvs751W+zQ3NNy3pWmJ3zk+E4
# DATA O84SuA5LQAN3LmkAvCLOzRsb/K9l7N9p6L/oyH8zA79Uz9V8yBk8z1/rug4Yj5UDjOIpvnpNeldBHvS66VytJKrCozxL8VIFvokk
# DATA azKVNxVPSWB76fhkMZ5yKHLAhDNoVwSPKrJ8IZI64gnjZZZYqYVK+gK5vVD+WTkmNwqPEowKijWjY4wXCNyEh1N6UFsM6lzdQW4v
# DATA CLEIvh+YEcfhbGG7xQbJ3DF2HGPHMXauk7Gz66iy0zRnVyv5hk3+y1j8V2HwO9qOo+042o6j7TjajqPtONqOo+042o6j7TjajqPt
# DATA ONqOo+042o6j7TjajqPtONqOo+042o6j7TjajqPtONqOo+042o6j7TxPtJ2gFV6WttMZtUaDF4i2s7r2vBNzh3NX5R52ZXr8rna7
# DATA oJDWapZyvdnuFrk5UdQdKbARDjdS9AYcaKPNMiADDjWQYFgqw2+2ixCfBmX4GjRSp+k1g7oHuo3f6k38bt0L2iVqT9tvtbr9VVJO
# DATA s+E1/d5P/F5z3OweBUFr6nd8r/4Tv94YNztHDb8YhUEwbPb7axLR6tbzRPhBzySiUQwg6AXD1iqxhzLWa3aCscpFi55jHlih57Qv
# DATA Qc/hGmvRc6jyF+g5rWY3vAw9pzWMRn5Oz2kHbb8zNPScQbc/GvZyek673fK710/PUXW8ytXYjAsNIejo4bZw0zpHVYPHkUrv6LjS
# DATA ZUuqsMbUGowPdibtlN+mHNy2a0tMDHUXjhZcDW7HDnEVt6Mmml1jrKKMD3gnxzgcJsf7dQ/ejbqnS7IA6OF2vfoK7XY3pnlH1k8K
# DATA uV66qbBWJsN5CYZzsGE/wOpopShJ6zy1sm67JWTV1aihTTeUvGY0TfzOd6WqPmMzxadQ2ufYiIXMswtTJUZPXmCFOMqOo+w4yo6j
# DATA 7DjKjqPsOMqOo+w4yo6j7DjKjqPsvFqUnXgk9hvWPVDjH9nfpO7cUSOmGrjktwrXxVsHjy1MzyPJN2TGHQ4Gp45MMK/TE8DvfPba
# DATA 66vvUJX6QA8o6iWrN+a3qAMadBfbuQcKEvQhjnFJy2dTfnLCp3P0W8tRqnn/Xp2Btw6l8cEzlDVVKBOFqr6Bfvj+thH/irLC2Mwm
# DATA qbw4VVs8XORppt7xs9fet07emWRQd6lSIBPd0jkfdwTdHUHf+Qh68UCYO4vuzqKvnhrcqLf5PJxRL9XxQmuxxWnY88cCtKjMWa6W
# DATA ooRv42EUZgV0C5+IhrIlyEU80mTUnck5Ya2kwlvpSqdldz2DzklgfUaM5SzOpyRB6VVwoc5Fj6/PsouI35rDoGqX1ap+vbJdUQX5
# DATA k1KDV8Lh+sdcz9xc4e22kP+MOBwTvTizsnqzyrsxiFkaXT4XNd6tO0z3aT+1otAOixKHO9GhyX0s7rpJ0F11qRzWD9TnzXfL8XpW
# DATA ueNPm+/kPlfJzA6izfdJv83p509bROXloKmWcxc71FZzxxCzRcu9UBPgP7dlXfNf4K3nrk7PA+STzvNynpXENtmtb3oBsaq55qVL
# DATA zo1/+cf/bNJRjriV/3OWKEWfMwnnuf6qWkrkPWnpEhIJsNESlmKYQQmetaihVhpTLWQoUzifU51kfV3qmNH6aBI7W8jxf+ixLqB/
# DATA pHVoWauaFz+0yOwxVW51WFz5vOyWmZ981k0jP1htHGe4rJJickYfvaQL7AvmmkL3WiCAsmrrhYoor6gXLaC//R+bC0hXeime91AM
# DATA VJEzXUCfHCfURlPq2Dx9yi9TJgj1ScsZPJE0JM1r3ns0ysPImSZHIkhBaWDBAQgbHEbcraKAZP+wKqdIq1uo0nr6UjEpuLFyMd3C
# DATA RYvl7//b5mJRXYyUisiBDpKUJiOm5czURFgu8zSnz5qurKssn7x5iIY1FNNBFHxH1Icnx6qIinYkS7OzWVwYB63L8QJG9NOXkp2i
# DATA GyuovF++cA/3u80lpft4KapPw3Tq8e6uvIs7xjWB4wyPoIVNJXNIBcPrF+jrIhnuZ0OR0ohYPRY609EMEBwpATUb6EdM7ogXosmB
# DATA 3bH2z0ydePryyZNxY6XzNCPQ//NPu49Ab2GQjVIZEiwd8Cnb1RSv9IGytLlJhRNWLw+96ZLGn0mYYp/cHPLJyGjvJ2I8qgGGTCQw
# DATA DKTZoMSfviQK0X0Rmso/7NpU7iejhddHtQ9ROnm3hjG+T1k0hZYNNGMGNPJgcsCK0OHw5yH256gan6GwUrbH42k8wXkD5BRUKshS
# DATA /3wZi1oNVBBZWEUKUCtCX0FTKSTjUgVUNALFo2kbgeaKZPfdDxPte9SaQjz7UD7BJBUqIwbohDtxXbBK+Odp2EGvhriLg3M7V9ol
# DATA XGnOc/aKeM4uyut+LtQdC/svt2O7Zc5NA+kCWzXJojxkp9ZGcvdzqgL5AommnacNbe97vA6K92oruXKW91oZ0U1E79WUq9uMOrY4
# DATA XzAJqnm+kcRmZ1JFfEeiBnmcGMdF7mRS1D7lEJ4Cym1k/vKCrnjLTPClkAWkYLAzQpKQlbWw19Qapc/NdTLX07yUFviH8HTNDgEN
# DATA FMC46PYYKXBLWVCDb5Rm1r6RE4VZnYuK2kqiHvtMyGJdSGlh3gPr28NGXOhtHhXqg2xmk8zi7arQRJ3lDV60C3VuIYdrr5LxaAfh
# DATA zEdnPu5sPtp1za3DunXYp7QaNxqp17MO+4FwP22l6Jx4+GxIFTdBCee9P6hefGywsMypfsrx2urWlfXCfCEpXx7btLZoL2/YqzWb
# DATA 7i852ktLCZueKrh/Cz7tTU+U3ZRlN+um58res7JXcOPKaaEUeJMVYorqNIyHXB9koen7b2j5SlUs6l7wy2XPqbDE1TlTTTovL4Lj
# DATA kLnm79kWlae599Sp2zaVuMz0q3egiPOmgulJoQG9uAhxLDQtmIQ6R0+fKUs1mdhvieZ6PJEZJ5vgkZ5JGYgktR+zWrVkU4FCo2fw
# DATA 3Nu6I0HfYg/PnhII4QmAMdnVU5/CEpe+R9Ydh+Ja5n3lFBMId2OBRj1xO1ktuHzeuN5pnNe1fG8hOJ66j6KSLpXw+Qzwl8dKtuCA
# DATA LIWUTAtswP+sIH7fnn5D//759AkwfE88fGMs37dg/X1z+hWgfKt0wP9x+hcm/v1B3f3k9GuPQYG/P/3T2f91+sfTL89+Rc/+SQX6
# DATA tUIIfn32a1yj3749+8KjLyASCggQZELEQZ4DsJC5gX9xMMAXweov9N2j6JhsB55Ez0NI1yoIAHr16QjyEX1IdmkMCHV8WJW9p7C6
# DATA SZ+ZB6p77utOS/fZyzm/Bk2IwyMjYyD+k2ixnG9FAN6D1IU3XGbY7ELt2QEAC/a+7iVumv+3WizXR/9jC4sJK/mthfpW5pnfjk6i
# DATA eRyRtaHvf0dd8KAyBIR2kl4xBpDVwxgJvVzw+K/OaFETcyTAXYvw6lGA1NdgEZza/CweodNhGDxDnLFdLk0eQkMn4rPLYsrDYEUt
# DATA pM5tsMAWhiVL/8uPmdp8ovee6IomLlWyxJlxg2lcfDhbwQLuXi032zorDe9ZwQF3T4yDBDoL4eosBI0GvJRh8Go4AW/MKLgGm2An
# DATA k+DCFsHNGgRSRcvZYcyA56ZVXQcS0Eq1Wv7aEEUNF2P3xYMT7zANh8tQQf+yfPUBMobFNTZGDRYXJU5k0yeW5o/Y9YS1NpZFzObR
# DATA ACO/McV2ggOacZ2VuSnBmeyjowwcAV/GFbCajKqonNzPUh2qeVCxxfHZUCwH+OiYgKfioNhqSP48pUsZr6Wq0lbmmywScmT5RpN9
# DATA Ne/DCAA5uSCb9u4vYYakyfJw7C1nVEwLOcPOL84cRtBhBB1G8BoxgjsPQztNki5qUN/oHOEyU4SrnCE4qqCjCjqqoKMKOqqgowo6
# DATA qqCjCjqqoKMKOqqgowo6qqCjCjqqoKMKOqqgowo6qqCjCjqqoKMKOqqgowo6qqCjCjqqoKMKPjdUwagTDUf+JamCfjeImuELRBUs
# DATA r0DvxBQswvN6TQue16kbeF6nmK/DQdQcjtbQ99qBTd9r5vS9dm9j3uYFM/XrXS/wO57vN71ux+u1qn4r8PymT+VFV4OO1+2WsHyd
# DATA dq/b767D8hWizPswV+NLL7SQh37HxLdVBEzWo/ags+b5IAjy5xv1HJnY3e35hrxS5VcryPNrt+ebLSv+DSu/d3x/q2shH5uNzkXf
# DATA 77ft8vbz+Dd2jL9dX6Rs+fHmbo+3O3bybdjjjtkvj6jkt3sXfX8x9+o7vP4ikEhpJBoSKX2ZBYkcdMJhxy9CIs0jBhIZ1Bv9Vq8A
# DATA iQz6zU67lUMiB/VhfTgykMjmoN3tNnNI5Mgftruja4dEztCfV7MHJ/k6hxyhPIquYN0hsFwd2uZi+8G8VluEBdNHXkazGUzr1+xh
# DATA URluB1ODdlHRvrdCse/UVs5uxMpCRPWih+IiSgnqe1SWPNo112pti2ro2dmibvP0rpZi3uhZK/bJFxytJaDjlh0Kaj+CpKOa0Q/T
# DATA aB+il5spjSYfKqXkbjH9yoVc2Vpe7EwxRSb24Eo1EfMp2CWnOARHgXQUSEeBdBRIR4F0FEhHgXQUSEeBdBRIR4F0FMhXjAK5CnGc
# DATA hod3YOpRr44zZpTk2/JVn2RBJijk4ge2ogBa1ev0NNWFd7Ehcs+/9fpnr/2ff6wx8fDeWp0BfmZPwg/nctgAb6RgbplwAoTzv7+U
# DATA cN5Ci+fjS9NwthyFrNMvp7rkPCI157kcfcOhqlCQC9FDupEPf5I5kNHQViAkFs7ouNP37vT9Oafv1xzhcmfx3Vn8pzmLv1GP81rP
# DATA 6IsiYsIHkfPj3jKsfN/ocz57+Zib0OqU0Q4yqiYKIz4gq6zOven0lqIk6hY6YwdILuingzDdmrlgFC07raKS5DSeybpXXalO8iqQ
# DATA 0pvEfhv+dTNP0QzKdlW5aLytQEzU7Wsm9kFrXeQDK+rdQsTrtdbmqJvx3o66vqjq0d4wOkwjmqqfkwIrLJMC+5pJQXtt9jfs3PeD
# DATA LZm/UaFTtxLUaOkgXlR1TmvEZR4i3ZlKa9ZH3AtmH+ZNi/VNhl4V48h6/yRv5PYNLLIv8vlS3FG2kK5EnhQ8o6kSeRh8c/9EUI6F
# DATA fknrDrB+hQ6N+hEyApWBiPneXMyGYYy5Hz8GDWGW1DgOT2TgkeLksT/TwhqHy5BGnEUUsTS4Erb4nDo4Mr9wtF6JgqyJ0Q4Cni/f
# DATA gfXSqOgsa2dZn2NZl4wmZ1U7q7pgVW9mKz1PylfFVhCa/DLiVz8Gf8+oHWEVO9c6Yj0ZuMQrRr9J0MXRNM7mLEHjfWLoKmy8s25O
# DATA BM/cccRk1oqn92xgVIrmWMZP6RHUn7JFXSQ4rohdmfto6H83VtJH4ySNf5EYyRul4B96WTgCXydKyShiCSZTKtk8yRXSWaKIRaPU
# DATA LCIKsxMeecfJNIIoD88myO6rCCdDpHhwL43WNLDGMCG4s8oot7CKoNTAsVVhw5ShYNsMIx339yHMU+wAsXVCqfaAB5l3iMYmWs5C
# DATA NmyoXtW8N+NZgjpEz2jMrjYEZtHDBRuSvKSCDFL9aJLBbaV6WGUCSRWY8sssUOg6Y2Jt2v7aBiNMkkOdwo9xolnKTapVYc4WY0EW
# DATA 6h9xLlZkuAsi4TU5UWr53ONnD6Sm5eOG3hQp8q8Z67+OINXOidCKpAw9ZVyYx2fBgNtG9i6ybYn6SOS8pFVEJ0oyCyP1fMpdmKRR
# DATA VMFEfraflwc7AHPjNFwYwbB8PKK8oApLaZQJp9JToizDLtcJ9pdwVcYRmtSu0CcZfOMcm4cUwIKMw3gIGmzNezvhJonhzyiTQQRO
# DATA GYwjdH6pFZsVAhJbVufqvpq49ENV2EtLQd+spxgmqbkig8SJXNAi+2pyVnyefyxOvfTiVGFaVecpkOrP8r6MiQVSc3OovZLZf6r3
# DATA +YY8MQlPFDq8aKpk1BNe7TsDHkIZ1zOMp9L/XO0bsE3x7od67ECa5tFsEE+u9i28h/sd3YL0Eprdg17t+1oCsBhFZs8QNTy2JWfU
# DATA 2orvur2cXBuD9uWbXzkSrZta7S4Z7CZSL/1E6qLo2edLQtjs6b0Ohmk5s6+cYLpG6fh8fumkQFAQDWB2QxZ1hbfgdZ8vHeUXUUJ0
# DATA R9yCV9hYro3wXG5V8sVMNmork+N82lvxDqHQnM9pMAvzQkyAsdXKzEMHNAW29WNFtRWTpmxRmpXm3oSSJ0Hb3yKgW6i1ZL0cRecL
# DATA SaNOTsO5BjnsVAZrSvSjNGKPekENO4uyTLMKXyHTLSdc9cMHUVrAW/33069AnTr74vQbxaD6I2Ouvjz7j4yr+mfv7G+BmTr9/Src
# DATA 6r+AVsVAKnCsvjj7e+/0D2e/Pf3L6Vdnv6FAn1S80/9Ft/yZvv8K373Tb01ooGZtBl79Clwr+q9jWr0IJFuqw3gezgaqYCyBHTLu
# DATA WYYIsrZiHgmGcE1Arlx1TpiTiUtjxk4L7pdGCswzlEsJ+jjZXyuMPOo5MvZ0bUVYvYkNtGgnEToLB7CyDVDpBG6aXlUuketjV0ES
# DATA elh671pkFVcxc+PbXOGuB1ZFo95cbfpFLcUm4WQYnvA+QqofDyIHrDqv3K6cU/UmmgGXwDxKcVaUFetxHG/EgG05femR7Q4tE7UK
# DATA Ym3B0+v9EMs/TKNhHMEbDUYB9alRCm9Xvpyi+sV4RubQUnLYmy4z6c/EDDsRqvcgnkcrFKtdaupme6bU9J4VvWqXRDhulbMCLm0F
# DATA aEzVJQb/V8LzdEMD/5WP+zsN+7uO+jc16EtlLKbeDPLPqrFcB32qmERvHE3msE7I8ACC2UQuT3A6PlmMp1iRlaTvy1ALoXeccFnw
# DATA B6ClkS2yOkodJmhG75GBHx7ROJnp7EhF2oy3HmBNNl2yliLFfxobLtB29pTaHQEPU4Ql6ojPdMlAzLHfMJiLi8MyCBhPxGNBJiZE
# DATA Fe1/WDAveB+g3kShUED8EhZQAGqK/sGeCth5eo18uUggDzVgUpcDTDnAlANMXR9g6rxxZKe5zO6m7g1a7Zcx2q/GZnckKUeSciQp
# DATA R5JyJClHknIkKUeSciQpR5JyJClHknIkKUeSciQpR5JyJClHknIkKUeSciQpR5JyJClHknIkKUeSciQpR5J6bkhS7UazHXQuSZIa
# DATA jUat4eAFIkkVV5534kjZmRK0vUan+3m1WfW7Xc9vNatBPaC/vufTP82eR1+LOTSIuv1Ga5UH1et4AahPDc+vd6dVP6B/muprCQRF
# DATA mVwf9NeBoPyeBEzpj2ng1uijhoVearTaVtErDpJAiYrgqqgZRq1oJaLNju8FXUp2y/MbwbTRrfrNlvq2Es+o3x+tjWdjtX7VW16z
# DATA 1Rq36/4HfjPwml1/3NJ6cRYDq9UMonVBrtbYdpNi2vB/0mtO617QqtI/fnca0GuoWLr4XA269GX1h9JLu912IxhseelFUEfSQjTq
# DATA SBqbhTrq1zt+MCyijkb8Pxt1RF/DUb2AOhr5w1Hfz1FHnT5lVWhQR8Nw0Oq1ctRRt9mq+61rRx3xDpMqmx42S0hFtjj79DESevJf
# DATA aub2ZMBmGsnMYBvkh0eu/M070IcKTri2ccLJ0tsqoMgKe9UhzyOsbJujh6IHu8KJtKURlAPwLjBeb3ls++C9EUJklaDtC/TEhN6c
# DATA nlLhdlCqHVW0xfzZnBxHEnIkIUcSciQhRxJyJCFHEnIkIUcSciQhRxJyJKFXniQ0UhwhPnpFCa4c3xl9Ty6NT4ayegjYDxk3lcz8
# DATA lIVsUfLVE3P1JKIeWV3W9KF3ES4ThEavUw4dMh/oU4qhXDwugojU7/cpeP45W/vzezOIIsFYoPfxfSdr7/skWYQTOd/Hd30QLsY1
# DATA 9hvsjV4/fj17/UTdbHOG8pMs7qi0OypdPCptnWtyB6bdgenNUn7PwUFqnEkd5dU8PPFC/F6QN1+w8onUZ5SAkQhHvangZ8jmTSbJ
# DATA 8fazvtP4IR8/nqdJMtLnj6Ezbhoqjb/YirJMo+wptM1pRExPkJQFZQnSp49b3vOy5RydajRULTrODPmILBsFNkppwEPthJzeJF5g
# DATA ESehyUPGStgCMhmky2n/ANow8YzPY2fmUPUIzt4jPr/7KVy4BQWTlDXdRUE7GyQJPzFYziGzLeeatylovwUbIj2RfXQeD1F50kYQ
# DATA WYcKIILkUp1F0TDT3ZmkN1ukYi5TOY6TyZDPuiLmlFiaA7McOEplhN8OKcqTExYKN9lmyk6UdVgmHafStSo6pwETuUmyQNLpUj85
# DATA nnjhJEv4YPBWifB3qXpz05Fj2/TWKLUKjwWb+2xtcnbpm+NMn6I/Rl1E98ziPhOc70U/XvNYUT3vyQfYkBJBHj2e8MlcnI3Pat5b
# DATA rNbMddfTgBpUB4o8QkVqwyE2AnFY5hiiUvUPF+eJunPOcZyPaSAxuoLYjorz7x6O0uBl1HTCKb+OBjouHSUJP1gupHCxrWauTgOL
# DATA Trw5740rk1hRuFAtfgGZeobjZEbR/IGEJ/4VDpFMw4mdJbE5zx2m08vpmr8pQtTIOmr8FxY2RyO8amXzj5H5KLwRnNPSO12DoHnO
# DATA thTBIxQFG6JerkdwDZrmRpmRjZqZanvoZjHmXYPE+T3u9o2tpNQkbk4J/OU5yJ0H4mYUbkZRnFGUq5SbVrhpxc7Th43Tj+ubVtxH
# DATA VuQ4HImOnlI899qAN4EoFUcaXWbPl7d3eB4WUz9gOixzIadz1C8DJK1vxnrmrj265Yf6i7f33fMiaz9oIly4mFM8u+vi3GxZUe7t
# DATA SlBlfyMTSiaLHWKpbs8Rr+p7waRaiZqdmY0iIXVL1MTpST8XvJI7RFI/aGJpLuR2ba1zXkSDbRHdCEKV+StGK6ulvbg0VGlqcVYU
# DATA OzKape9S30Ktwzs0c/GK1+5+1zP11puSSZ15jaa65xj+aZrl00Q6OkzRUfJTGpmF6bdws/hG7o74q9Jhk5mpgZzGrFYbD0xXhzdG
# DATA D2XNRE8ZsAyGST3CKkmZsTyX1ZdpAdtMWGXytKxCYNKfT0skdur0QaRV0HagnL48trej7zjbe7s33xnaL6WhfVHKzjMWQuUdwPkG
# DATA 2VUD1IbQsOhgqD3YRi9UkrCZQvNM5VNfCFlB/u8VM41KQq9XTTRakcpdyzPaQbzW2kedS9jiWwThyiQcVQxBh62sZTZWBlapnmKn
# DATA uJSs2i3+xrhx9900xroNdimyF5EugVEfP4QNw95/Oc/FtMO4aO7QBBKzwGjdsotS1RQhU9EnVQcZeAuXMnmKBgxNSy2PqrFaTHTt
# DATA eN/HmhViTvZdKeYiu2sWVSh2vH5h2oRojOplGcUgxXEybM+2VotYPpWXnnAWcUuE0ex3jC0fa5slTP/l+N7HSpBaoNPT56gojhoW
# DATA F/Z4yWRiVv0ojgo+iRUILIJtjii9bF2+vjLanRY5iAy3ATg8FjvoH06/Ov3T6bdnvzx9AujP6R/PfstQH9CDfskMny/oN9CFfrcK
# DATA D1p5+PSbs98CN/TL07+cfXH65ekf6MffMIPo64pHn746/bpKTzxB0B7f8y3dQ+8QtNBGmBCFjrd8SW+gGx1Q6Pm3qH8M/TJeJ+be
# DATA RNHCTiqyIIhL0tGq3alpdAj+spZzloV/VV/N4J6yaHOBMk298VaG0FvjUFQNLMlwxxGyrGvVJdw0SWhduVwfTYg3BIyTubnxU3Vh
# DATA PVNoFOfd9LvxwniCr5gmJFBjthfEV2QRfV51jtAuJXblNKF7noDXAQKvLpb9yJS8ePBj7KGderITvOZ9kFANmBkQIhXiEfTeIemB
# DATA NQLW8IBZFqrNLiE+T2TTRwr34ZR5jOKsY+NLYI0QiS3Dg7ZXyc1GzJp29qzQQduT4KBBbqS/yEivOUGXHOBfDdfZTQ3u1zK27zS0
# DATA X2xkv/6BXarlag7kG11vrrVcBygoTxlEtCiAbDXOC3jcsFlTb/7T8V2atPMhJ8aJ6AIEASbm35lvgiUwpq2oLaH8lmk4o9RlJt2S
# DATA WhO8YIamc+rCZoudsEGwrxY4yI98oJBGKfV2+aAfy3K/XthCMCwmxxAjQwBKI8kqg0Q+EaByxRrpE2B+kpGgi/Eiqoje/QWSHbPH
# DATA Ix551KoeCA3lmDoK7BlEG+QNBinyTjtEHT3I0YMcPega6UG7jSk7Qs3Pt3lv2Hi/jO3+tKa7Ywc5dpBjBzl2kGMHOXaQYwc5dpBj
# DATA Bzl2kGMHOXaQYwc5dpBjBzl2kGMHOXaQYwc5dpBjBzl2kGMHOXaQYwc5dpBjBzl20HPDDorqo/oouCQ7yO82Bq36C8QOWl133okf
# DATA dGiSzLsIi6yZYSsajuqbWDN33xjEKex/AfsEkhAF9umwSAPLG/i+IgwVbm/Xm+fcbnF+KGyP7vHot6rfo791+rfX+iFdn/i9Ol1r
# DATA e4HfpGvtaqdXDZrBuNn7IACwqNMdd5pTv9GqNlvj9rqYNINNEVcAo9uHhQrUDHxEht4wrfpe/UgQPVuyMRr1e+31iKT6SvWkOLeC
# DATA +rjdrH+AVDd7raNmfdqsN6vNOn0qI4h6YaffXhd0cHEakNR5TQOS5mPRgCgZg06jSAPyO41us2fTgIJ6s9saFmhAQbfVaIc5Dag/
# DATA GjaHQ0MDajU6/W6U04BGo8GoO7huGpAyStY7PnRaS7aWGomwca263Qrx6GYMO/m9ZfCPmSitmxRpNxrmupVmrcn8n4D5P6vrUe1i
# DATA pLRxY3XTYrtwQijHw7R6iKkxeBb1YXRYsdbe7c9e0Js/rHynUW912n12+92qbA6pd8GgdJSzeTS4KJVI27zwHq6YVNaK3ObFcbUU
# DATA Lj7hakY/TKP9YZg+2MweynO4Ykd9s81RMnulDrHt5EhCjiTkSEKOJORIQo4k5EhCjiTkSEKOJORIQo4k9MqShBTp5xPrWFd+nrt4
# DATA jquM4RFukJzypjzSdCHsCEAzAp1nMK0xzOetZMoC6CuHvPl4G5aSRK0qxEGVZKaOr2lB2uJBMWmjMpHTJy3cGWd3xrlw1MYddXZH
# DATA nS951Hmj+OD1HIF+N2atCz5Lyy7I8ulZfRT6eZPbuAk9bjW4oOpQfVWS4Ujl3mB6nkSzedZ0WPkVI9LcXavN3bJFmn2/XpRpbm2R
# DATA uubBD5IuqvfiC2+ILWtUlOWeXOBaP/RGwp2pLSHd5uWej6nvU3ghridv3E6USOCaJ9qcXTS2eLe9RRo9YK3Icx9r8YtsM2AKg4bl
# DATA k4vP3pbU7CBU/Y6un6iyHqrsi6tS/UEUZkuIRuNg7SBMc4Hq+wuR5KOeJEkWcoMca4asT3gIsWf4o45pzKp5P+bBbRIdUaVBB4hO
# DATA darC5mas4DRJaoSH0oTMyZr3MS8AiGkkD7DeohL2o+HkBAVNBREvCvLVgGkVju3LOVIvXeKMN45chzhgDw1HM55DP5AsNqqzXPgZ
# DATA zc6W2TwS/UNWzA5nyxEG4hRzKQkQXKRhPBrhyrLPeuoxxmkKjLE762w9JUJASVjsLHD9spzzdfLWzny1zFdnr74S9upFta2fsWQP
# DATA r2vnC7Dbta3v0WjERiMbkGzHZrkUBXMUsi0a1zct9vNC6F1ch6z1ar2+cmnrtZpOl5W3zhf9tTkmFoWyfSKQRbnO5aLWbP6ckEkj
# DATA QE1eCqLX1bw3RTeIZkkiVhOFM5gon0JESOReMgxujBkVgiNXN5hRZHXFWviZbLiEbB4y6h7QGzQx5GIV50daiMWoOhl3+KuleFLI
# DATA GWcMOWOo1Kc6b57z5hX7zo1W1DMWNGQeMMDFyWQiOvtlYLdqJ2GWS/jVvHeF081W0jp5voKW3zxNBtEQNG6RokvSz5eR+HKehs99
# DATA LzZQZ0PjXdAIqpmA03ghqGkZST3WcuEYLLmRH4bLQxo1P6ZhWNMCKxyAmCWy3KPwDugwwtEITjF2leQuTzNOvzfDeL8Qfu1S0SKi
# DATA aT8aQgRtGPVTGpGFisxDKIsAYofSVpS1jP65PKPggEOqCvCDsqagMg0ybV1AOQ7+mlScpUp8mmyA4STqh2nNex/2E6JJlZQyN1Qg
# DATA sGGIDgZIhP5EhNfGLIy3TsiQP2aWaqG4ZDNQrz+ngo9H0HmbRlj7iwdbYeRjVrXmyjNbwIPDXmST5E8B5UhGI++QhiydRNkn6U2W
# DATA lKmDEIqNXI+BVw+PwxNxTOl4qjLMtFuHs4/HAQpGxZzyJRMFbviXWIX7QMkaQgoz5ZMFquKa6lwAayxQf5g34vUpAtFGr7NKNY80
# DATA MrZAJpz54LlQNQSnTMsiMyahxMcgk7D8UzyhnyvaD8UJyGE7gzBNT1i58R7lWch+OxWQEOYFHqc5PkchS/LlmfRhFHOqxE+s1C/h
# DATA kjtMkqHlbpe3JtTQaDQcSVsrFuHlYN9oyyes+kh9zPcvDPtG3K4a9i12eSwNXOkXxjOA46PhNUC/3wTzXsmFqq0j18D4/rSkQnot
# DATA b2K49/toGtLH0Lgm23IyIeZc7dv4FNCnhpKIFaJ5GKfeA3iLw9XUXSdR/OWY6lhwmSRMh4fwrdt4mf+qMDLfMtQFdJivvNMnp/90
# DATA 9sXZb1d5Mv+d7vvj6e8F+cJ3MfkFVJhvT/9MH79klsyTimf4Mk9O/3T6JXA1T/BTVT/1xKOvX+qg6DZ64a/Ofq3gMhSPs7/1mDHz
# DATA e7BpQKFxUJkXANM408yuFV/cPEqAgFYj90IEpt/S8zXxexzytm0Mcgoaxtq9LC+ck7vMwEfR00PhcjbcSpm5x7fkb3aMmcJszvQM
# DATA N02ZWS2X62PMcALNXT+AkDjl9WRUvm8I7WcD9MJ+30UanlwlWobaQEY2dioC5jTTgDXGMzEUhIPLbC+qK6fKmE5oGJMZzyf2xNQh
# DATA 8xVPQeQ+fuhxvfA+5u0B4rY9xP7IdZvKhX0IjXat9I0ym0UL1jTH3g8aw7MVhsy2mrfZTllpQ8+KH7Mt+o4e44b0pxrSNU7mUiP5
# DATA q+GTvblR/BoG8Z3G8B2H8OsewaUulpOdb5t8hi3mOpAy5YTmZBmjOZHHnHIzChViBu43lhuAp2tGRZrJai2SYfgZMqwCPXEUp4yL
# DATA QWFprAylPMxwEUfGDVEYq6EysF4AInMCa4t9uxLioWwzwzSBPvYn4nE7TCM+DyDZrre6Kd86jf6QQuDv5/JIDjD+c5akls1QxIxE
# DATA qYPFOFiMg8VcIyzmnDFjNyT8uZbtjZrnl+JUP5Vx7vgwjg/j+DCOD+P4MI4P4/gwjg/j+DCOD+P4MI4P4/gwjg/j+DCOD+P4MI4P
# DATA 4/gwjg/j+DCOD+P4MI4P4/gwjg/j+DCOD/Pc8GHanWa/Wb8kH2Y0GgXD0QvEhymvOe9Eh7GzpVH3/FZn3Og0joJe84f0vZgj/U6n
# DATA 0xyuZmcr8PxunTK0cxQ02z+k78XnqG52+4rLwmUpZSUFdyIclqCgK9HsFcu42SxFpB/1OuUAg6Bx2QCH9V7Qaa8E2A2uNoaNpn+1
# DATA MWxK1bm6GNqFQmV5BXloFcoFA9xQylahXEkM7UK5khjahXIlMbQLpSGBX11LuWCA57eUK4mhXShXEkO7UK4khoVCaTWvtqVcMMDz
# DATA W8qVxLBQKFcRw0KhXEUMW4HVlnvFUvYbpRDVhVTlfnnwb0eNEoqr3WuGzbWwtHXQsVarYUHHJPzUIMEsI0WHusJPC1pPF0Cr27MC
# DATA aPUuHkAhCb32UyZhtwAuwjMTG03zzMTcs3hmYbPdbERFntmI/2fzzOhrLxoVeGZRdxj2hznPrNNvt1ttwzMbtgd+2M15Zt1BMwyu
# DATA nWemvB5qQ4OZCYkznmxJdlBY3gu9SG3mZ11eqVyz6F8Mucwx+0FERmwcViQmpb0oa4KzHZG8yFMMXa37nh8NM31Zv0tO306T48No
# DATA t6Wi1i6L01ao5VVn22ei60jR7RzIRH5l9dBvWIvE6l4/KHphdHXlPZbjcJgc80IMVtzqnq5zVt722GHBs2Izm9uwn05PYlVu1zcz
# DATA 0Ow8PcejYeVWqU7yZDlwIDQHQnMgNAdCcyA0B0JzIDQHQnMgNAdCcyA0B0J7tUFoj1Ttjqng7iiUGT5ToiucJHURR/eQEXK7qG7e
# DATA oY6N6sweqlZ8p34Qv8FPHMSvv37rES7ybQfxaO84npF1RXbYyXyRfB9G/MeAYkx/wuHceqRb0PwOg9YYBLLXDHrNXrsT9Nq3OUq3
# DATA vsd/VBT6d2AD/phm741AOl7/1sEweSTvKL9ir3/r4DHLZu71f1r/2d079K5bByL5hgvf5aBf9w8eR2SsKy04Ky7Cf+MA91Q8btHd
# DATA Sn10vqRRT3V7jyV6qBx31M8/T+LZHvdWlIPgw6ExvK5+lAXavb2w0qfiCF/vV8h6zC15ldpJfGejNTuJUTCT2K6Qd6R5ULnRmyRt
# DATA NHPEa9nGlxkBDpCj3c+xlWA23JvEtw4kj4q/86o0TdxVV3zXr98q3oAhWMXnLdxbk9PTVNkea2SdOfrplFWcssqqsoo5DOzUVZy6
# DATA ygXVVTaKYl+D6srHkOPSCiCThPU+WLPLCK88WyGvm6DTsSlAV8UT5CUjTsw5WDr1UN4jqe8FNdkVIp1vAenaNo7O3wKjY/MFVR8f
# DATA MP9AUZRgdOqeHEanH1phxLUlqIdiIm1myfGY9A686+fd6YsaMFmg593ICrufHEcT6kTPuTeoq3tnZAKX7t0dXcfVG62cS/SFpdb9
# DATA tWY0yHiUkfUQDY3UnpHXISPLyOKI+V6W2mGS3G6yPSxi42XJMgXLdyQ4Fehvi9UIDYecTydeCzISZ0rGh5J44qlD90Ysht65ohYz
# DATA bty19X8oTQ0qmIkuFLbI7Ny0NuqqEpjsRJt7GRRD8rHEGZ3O6Fw1OnPrwlmdzurMzrUnn5nW331GDXEk2cUN5CiqvzE6DZBsGg/S
# DATA xJLAW7KFqvTvQmpdswHoFqvad2ZQzFuUGgw1pISl5AbJdBqlg1iPgWy5phFWWrBxYWftP07Z/O598Vb1T+Azi7DLBMOoASgJ+5cG
# DATA U+ylWKO/pc67rZqoyj2LmsiflHGqbA79Y24AmSt88BnotIjDUfGT5QYRHNSRX2t7Gp8vOEHqc9HytO4wHaX91IphB6cp2gJYU3Jf
# DATA vM0O1Mb522zAbbprkIC4Qc3liG9+K/+6+RmuRLj7I3zYYl3KwKwtPHGh2iYJBokt5l2hhLHnQxq0OtqZIx2oUzLsDvZYy+qOyks7
# DATA L0o4IN4NY9q5OIO5NqVLvj34ly/+77ZJRTnaKmeVKaakKqmCpIsTMcbIvuORCUwebUnyIETTvirsriHPF717wyGk8ehpYQEN0Nio
# DATA 9vNEkfnJYK/gQTb/ZHRkIoomJsM2pbfUvDfDWU4FnA1lUio/vQsiDF7SqNMgayhB+tjJpfK1VHsukb3NzdlbqIuSy7CXxYanhCzC
# DATA ic7ne8yToUFiXpFc0xNrzrUQmwAW8TSyoWzzyZJnzzS/XIpFzwQk5dH37sVT5NWIrLVsDFgVm9645Af4Ok8yNtFr3juAL+I1wzgb
# DATA LDMUEIcki5JXkcumvV00fzfnrWq5OlfR41PXu8AHnadvY29P6DX+zz82wEoaUp5g8WAGnvkx8EFUt5aUd1QWMsXPPJ8KtAenhay/
# DATA DCKag9S8j6jLpqn3PanYUn1BgGJOEp9X9ODeOPDetO/AGUJxl/BMWm3yqnk/pK8RV2Qq/yuryJfO4u09RCGbP6WBliYZFESq89iY
# DATA syNq+FXRc8pZYNAOpPqFyjSXPJQVn0z6ArkblRR+mlChxzEhlAc/hHYpTgZmrFsamkDCmYZSVeRl9BuWUCRunOmHsUiegkd2FCfU
# DATA QtTDofQ8z0fn0b5Q5/HvljGvfOrBWxeCZDDVXxrjULG5ArINpA0jmQ4h271sEs8pP7lxcN8C0BlPb/qsb6o9glBQxaguSqzcNXmH
# DATA 0UKKjrMQC4lZMo1w4XAZcceBp+OZTFSoX1pcSfdx/YPfWzwugYkUm6ptukVxayyOE+mQJWvRG2eC0BSh5ChOaXQ7Rii6HrOMbWwU
# DATA fmm6jqafqpZPtiCrOuOd1DXhtCL11kdqckdh44lpgoVcnjugp2DshHQvsFnLmVs0V2TZ2DZXzBXJrLvUwNQCrxYSlvFbTEXLfKXm
# DATA NuaGJ4VSO4/19DK4XPLZlnO5OJfLGoKC87K8/F6WjQ6U54qoUDgqsDpSTmzWgjeJFzjizEoojMQExVKNJuyCyR/k8yScsc8awfA8
# DATA a5Wfx0+yDn7IqiQffbn7BnWk5famj74Xjtd15SyfdS5fLoQT6Q7LOImVI+nSfgcJaoe87WQ20FFRKo+5380Ws+fyWAPmsJ7jL5we
# DATA tRIzDu7eZ5vcVBFAkMPZiVm1+mFyDBzyiao73/f4whLeKbKqvu+9RfdH1JnCGIIRklvC38ckLJ5yhZtlxzJ7WGCjncdLx6y/Hyui
# DATA q2ZTAUYbkm0GPi60y8jw6icPoxVeVLG2vBszMJMdkJQdy8GCEinF/iosOdmcy4R53Dbl8r8wlvJ/Ajl59jsPRMrTP5x+ffrlKuGy
# DATA dOdfcuAl7q94Z7+ka0/ov9+efu2d/ebsV6df4Qnc+wS3/0kQmHT7t6d/OPtPgFd69OELuu3PcqvjWL4AJpuXsd8/VQcQTV+PRPPk
# DATA nHuCmie75b1sKRNW2ZDP3Fp5kBswxgweTNgjMJNp1AgTVm5w8JNhaWHMm+e3UCzfFBkwQWU4hGXRhJNGf9MAy1KRXB+9EnbAkdXd
# DATA q4rHFHT5qfyEqoLmiY9VlUQVnMEjdqVAS94tMQ4z9tcA/aMc5cqCcVDLXUvwyvGW92CXHoqtYtjRFe42h3CwaUCQ6bPE0H47Ho3i
# DATA ATbkY9uy7LiJNANc3zqLKAz6ORV3/wrRcqc6uNksKbauZ8W13CkRDnDpxvqnGOs13vLiQ/wr4qG5oeH9qkf3nQb3C4/tNza0S7Us
# DATA ZEOOuXxm7eY6IJeFNGJKHhYThm2lkgAEO50vZCicp+h6wKkbh/2YF/4WmS41euLwEAssD6gaZDKPp3qslrkx3ZaR2YzAk5gqJJa/
# DATA hPCXQfEv3RVxiWw0TEBMGyj+E+rqcYYNayAK7ahjz9teV7CSqiZVC8aCLAhxLFkiBaEgD5EBWPnMqvMorbJVRyWwnHIve2CZCbgR
# DATA Ua6SwbbRbHAMTMfAdAzMa2Fg7jzA7DSTuYA9fHOm/WUs+ysy7B0c08ExHRzTwTEdHNPBMR0c08ExHRzTwTEdHNPBMR0c08ExHRzT
# DATA wTEdHNPBMR0c08ExHRzTwTEdHNPBMR0c08ExHRzTwTGfGzhm0G5EzNy6JByzF/VeIDhmYeV5JzKmhXrzWzllsVGkinVKGd6Q3yXH
# DATA i8iyZrdd76zJcGA328G42ZxWm03P744FdWaBx8o0shw81liBvtWtuJaQaitxrbc3xbXfb3db4Upcg4Di2m1fVVx7Vlw73a1xVTC7
# DATA tXFt9rv8azGuDb/uBVR/ryauje6V1IHOoNsO/ZW4NutXWQeanSupA8NOOGyv1tdm7yrrQKt9JXWg0+72O/2VuLa6T18HrOAotGa7
# DATA M2436kd++4fdEh6XOtRB63IQO+pLNcROumULYtdsU7fR3QFiNxy1ihC7ZtQc1nOIXavTbnVaBmI36A6i/iCH2DV6rW4nuHaIHfZQ
# DATA VWV1Q4+uTYtfZ9Hqumxz5vdfjEtXdro28qXWtjhdOWQ+p7KbL7W9zZeq54R5oKurMsrXrKcZmCioKVevtUKHg08NC07ynwb/brhw
# DATA 8YzqlNcVMpxUhmaRTqdqzTrK3uWIcbJioBZx1xaBce2V/QUbYXNWCWyxTVdrjOPLOb6c48s5vpzjyzm+nOPLOb6c48s5vpzjyzm+
# DATA nOPLGb4cqzcqlBz7PCnR35OvfHiPvt7Wvwpojo3Nz157Rx3/G5qTkDisxyQzZrINoniyx6EzWU30M7PaZ/S/2b0FbpNg1Q8KwKa+
# DATA MRxGhzukCbfHJ3jWBH67HAoHYz2a8YhgcGdOB9EdtN980N4dsH+JD9hfVP3wuTl4nzu2tqshssgbn2ad0QhFlgUElsf0fZsW4rM9
# DATA p/+CnVg9T30nd1RehzZiSYXgioURyzoO56gi3lOAHhZDoFylNpRxYEZa6KMlvDG8g8E7XAIK1o+YDRZaqt/QPaDJOsZp7126mkDk
# DATA XqsfikwUIxqUugLV20QLOMuJcq7qSrwB2c9nynEOvS8VAk+jzkUP5zKtUCrTZdXDrUpKpSYH77UNv2DV7fsJjXRjdVpdNr9q8e0P
# DATA Q8gtGpn+NDoOUxyoV4Kix+FEjuaHqoJ6EySEOQnsQI/DVIQpJPLF89CLkEVSf7RcIEnmEHRZo3w1jjqXDbVhJiXBFBvuILAJw8OX
# DATA YRQaKfUwY5UGJawVMp6GT6vHiy3Rew/UmwtEDr2IiZglpKErEgQwMyr8MFUAg2SSKR6joelwMOkD7xi9EMcXp+23RPIjec2aTHyF
# DATA TqzboTgb2dnIZRu5VKucLJWTpbqMdbzRGr82uaofxNwG2EgIldCTVrChHHtgaVfdsCbiTcCBxbnDEBxYj2mEnINK5XY8sH7M9E7m
# DATA Qk64bdbPQwQ36mLI7kAJFq8TkL3GwcSX2CWEl58TYf28ibC5kEe4tT7CEkcVZb8c5frmOLNrzK66qFp7/OLb4pm6dW42FynM+nse
# DATA 52BtnFuXjbJ2mNENH6z3uZ0T4zwAE2nrkpXXa6NtxVpVHx3pViHOG4HIby7jydAa0dBbvLhc5A9kGJbRPZzz0RtewNZzKQNO5t6L
# DATA T4kodShJ/pgeisDjuueNomN2abPjeGE8qtDBWiMkf5iyUJ0Z/2fRkWZeGQmwH6t+XXeFAK6FwKJj/ywb5DXv35OlMOR5D/WMVjdL
# DATA Zv8QO4NEdU0zMsWVLR0pNxZKkbyZTQ9M6WiaIRy4eLFpyvYSG+H26OqMcGeErziqV6wtZ4c7O3ybWf38yMaqwU43A/aBoS3YKvDA
# DATA 7dBYZVrhUT7UKYnSSq5iykONETiFXif2VmHUQeBzkezE8KqciGhzIwGiZMtYMDNyGGST5uql6cn5S7lhQwK/j0qhZxE0Og8dP3kX
# DATA fvKMfah4Qrypm+8Ud7JMIfBpCzlZuxUt5x8ots8/QTnPjQtiJD/ZjJDU+SoQyXsFzz1c2lRlAKVNIxRTCZiaRoeUY8Y/y35YQWLR
# DATA f0aYOyv1WaqRGd9It80WMU2YZQWC58o1760wTU8gyprMiu7xNGRmI1uti/REeYlZlBV7IFOJGHzmyUz7ydXkwW6k+eqPbiL56pLZ
# DATA Aymj/Jbkm/zVKop0gTf7csMMwTg1M5GnYoXmVfmCxfzO5mLWjUIVs3H650systeCewxd0O+ji4WREwqTNSWLXa9yZBayXrQARCma
# DATA l14k8GySHE9ORBI6ZWVjdK4Yi8xSD5U5b+BDBzk2veJTFeH2pN1YIRZ6mQuW48dbYMZ5f6VbrKBHlERyGoHFSkPObKjEwLkkNQks
# DATA b6fDOKRZ4JQN1FG0OKHxdIk8jpXzKtQtWeHGzGSeF11odM35aJlZwqHB9yFmpOxzYw8YFghjAa49ddvcltAbK9dL98H3d+6DqcIu
# DATA 6Bah60bejNnb2YOTlf5Xs22kWGHViNA0GxnjaBpnc9a+9t7nHjNkL8EkTA8hKw1lxlmmOfXHSSr9q7QV6VxHIRDJcAtcSbtcn6rn
# DATA v1v94c7dqhq7yL6CvD6SGqqBahhqgrVpkrLuje4y0cai2KHwtvDpOIjjoCgV3zo+nMHVIxNRbWHCscLS4DA603nKevXU60oxczyu
# DATA ou3tkLAXomt9+0Jdq5Z1h2EyTMNjNBDenTCJR9ZCtXKu6TuU9RCF2BZKmQPZe7F3bHsGMxouLG3yDJaLmscuP7OWrbYHDNJwjjzn
# DATA I6F6P4X2kD1duW5N4aVK9GYB3k/loX35fYo5AnMQ0WgfD7IiAvOrsy9Ovzz98+mTs9/Q51+CZwls5Z/pzy/BsTz7Ql9ch8X89vRP
# DATA 9P+vTr8++zvGXZ79B4Zi/lmQmBz0H+jKb5if+TWTM72zX5/9LQCaZ79mOiaFffqns7+nIH5Nf39H76QQcNMv6Yc/0s90zz/RS56c
# DATA fnP2W4fJfCEcpdiWhu5KdYuq5nHQ2b74ongI69P0oMLfD7HZHV7UAZB1CtRyFLLnKjRTBONzDT144QbjmvfOw/kE5gt1pigsxFoZ
# DATA NLk68FZ+5lsTGr+kJSJ+jqBp+1B1n3HTBM2VQrk+hiZXSnMXthbymrryAK4QN6lqx4m5/T5/9SDatZxAJOwqAZpxJlGB91B2NkY4
# DATA 8xuCH3QSLRw9c5eyuwZyJq+S8mp5PMVUF6GZCqC6p0XER9QGqMd8rN/7IAqzpVq+pRxbAgrFdAWUHPWVxvecMWfIW8STSLmsU/aX
# DATA k4E0XE5WcZq7VcnNlk65rT0rouZu6XBITWcXXIddoFmblzEHXonl1BszBa7eEtjJELiQHXBzZoDUy1Iu2LjN561NXQeHs5R8TjTc
# DATA 1MwuNJEpwze1QnGeOUdwYkwUj9M+SMO5xUvPRvkvB/DptyEzxJej8ZXZg2gxgN97VxxnPuJbFgNFLsuH/6nYCUPsy4NqFBRqKL6e
# DATA hMgnawr2AC98U9ySYVX58dHOs4z3kXm8h0tsEe1UpFEJyRV/lKJ18kYJdluFZhnNoTcdetOhN68FvbnTWLPTFOgiRvNNTgEuMwO4
# DATA qgmAQ2869KZDbzr0pkNvOvSmQ2869KZDbzr0pkNvOvSmQ2869KZDbzr0pkNvOvSmQ2869KZDbzr0pkNvOvSmQ2869KZDbzr05nOD
# DATA 3my0msN2cFn0ZnvUGXVfIPRmafF5J/gmhR7TsOgNRGasx3k5OBG6YS/P2KApOlT8S9Au8gt7w1HUXc1lMAGDxtgPWp9Xu17L9wLf
# DATA 8+s9/tNoVbtNj+zjaq9RbVU7vaoftL2gV+0Ent+hL41iYbS73VYvkncU4xw0gzzO9L48zu0gj7KQRa2K0Wq0o1WUZafn+a3OuNud
# DATA VP06Ra/zeY8i225UA/qh3a36frfaqbZaVb/ZK9UWPxpEfol52G+HozBYxzxsrktKU2I/UDHuWBDGppWUYh0fdgeD/hoio9/1GkH3
# DATA 82672qSUNHpendLU9fyg/nmVyqLRpBT6XgmtGEadZntt3FrdTh43CtjK5p5VM+pFWqTfHDTblyA1ctPTpEZpxRapkeIy6O1Caixc
# DATA AakxiLrR0CI1hu1hZ5iTGjvDYBhapEa/Neg2rp3UiL3t1W0mDQ24lo9LbGPzkLZkbCghUjnySzPiZve7Hv4lU8NjcyMPQo+31hKj
# DATA /Mrm5I5e/8CK39q5BIcIQWHb51/H3TwH0abpgWWAF1yhqtwvBlYU91cOhSzlSYvyhP5tyL+F1apmy2AjO63vriU8irFIaZY5X75c
# DATA ai1grUc4bkQ1nlsZtD25vhZIpgR28e0cTqloeBZbmgw5DqTjQDoOpONAOg6k40A6DqTjQDoOpONAOg6k40A6DuQoROO+41eFpyib
# DATA jgF/JGtGIx/v6/Pux5HyZzLucU/hInEBT0hQqKrvYqPfns9IxsFU2I+FQNRc1QpFrpwfjIjIQjxZHaeXo/bePI4GkT6NiDNy8B/2
# DATA UR5FDmR+8sadDnenw3c+HV4+ouUOiruD4tt1t5+bA+T344fShCo0Ps1OsOQfyyFLG3xjjjxaoqloMhM51IlnH6yeesZRUO551dnp
# DATA EUKRk5lZOIkuKJ9tVC3F9chNnG5OpnCN2ue8nXL2LsrZvKOEqyI+bL4P/SVu+wn93aKZTYPiQvCHH8nHF0Ev2+TBBUUi39wsEqly
# DATA UwQi38QpzhGOdWNQyvUgsVnGI8udqgrOg+N0PrisNOU5gYDnJB7JCeZkwRSIjIcmuKAQjDeKqB5NYBDRhCWRg8ecEk1EeRrtzMtm
# DATA yVs7Zsk7WhOUxmSdIW+GE+gKsFYvR5caE18wZ65lCYdlRb0RvMv0NHKKF0h4XgfmHA3N+ENNkKy/WE7mI7DZVWSMbgcXzJefbM4X
# DATA aVGqpiyHbJnkdWQWpjQn9WY0p/XQzzAYFNKtWJCAzEAO/4FFw1UqmgmhDIIEGXNE6PMc/f3RiTZunmEd+bc71pGPkiVrWPx8eZjn
# DATA h1abnmv16WQ6wqYRYBqoE5hjeoUGwTQjhTEakqlBg9mAMm4yTpY48VbzPsGEgLUVWClB7LrDSfgLI9TxlOqzeVd4wfz5aIv2rO5U
# DATA JYdofu3N9SXJoY/S5Ah1gNJMs5vDyKBjeZMcVZpwOYAKx72Zt5whubqHgUAwA1GBZZpAeR9S0by4/Azbzcc7thuu1Eq5xULWsiLD
# DATA NFlCfXwJpYqJGA8pn5GFvx9UrOFQ9yxQWo6lK2WzzBbiDaW6UH9dzo+blbJ9VRQacjPbTcLdJHznSbibcb/kM+6Nk+nnWrKN97GY
# DATA HS1CZeVdLXffoAZdLmG9/xLJNdvqurKV0tocKhfCCX8ry5+t7IuUCjNIsHNIXnYyG+iYqJPGd3+0sq1ST/JX1eWsx/gLp6Ywvk8K
# DATA ZC/AJ5j1wopjQ6qeNIHX/oX8IT46zcPNc6pb9yLJOe0obOuZLVVSfQuGg9lAtcVQ+5d//AdtRvArx4FI2YkF6S2iyYSnLgo0IYpe
# DATA P4D9mXmHYmWFC6ZFDKHCRjOW8XLa18UVeun4ZDGeKmuWDVaeGxzG8rNYfixGhmkzRM0szS+P9zxCpEtJI1cot9IoF5wzaoB6BVow
# DATA Qzm64jhMVzR1iwXKUCNjODKx6hWU1bKCcVabs9p2ttpW6ptbO3FrJ5ew2DYah9cpvsuAppHS0Wcxd+Q1L8QXNHifvSD8NkMA5/w8
# DATA e61lZelEbEW2LYeFa4U1DVnqp8vvUv/LZ7/5irc3mJ4HutePmu7MXDArDHJApIyM94ugexsZX6/5m9df1IYCO7JyaZfYmodNdPMr
# DATA Jr69q4yu2nhBv3+g9X8XyaJQJfa+e160TSAm2vmVc7K5bsW7sTXaynw1C2ayK5VXuaTKR7zFwzSFzEJEoYbdfUPOBKs4q+3JtlMt
# DATA vyT9TyyoqjmN3cqIvS1BPCX8SWwrRmnlXYCtSv3jzOwvQeMzxu0H4kw1Ss2MHD4ex5Mo7ydiqNUusFcnZclbs9JBrTnKxZtZHlit
# DATA cMLElY0rsvWNTN1SFdA7rbyhQvWZ3kBrB6NLtfoeStVySvdje3AeDutJD8IZtIPnlIAY5xTDdM4Lvew5Booc7srjcSQGfN5xIWUQ
# DATA muZ+jRe2yOioeQpmhxQaoelsOaeuR+kHF8Wlb3O+vyrWswXh4jk6zyFsDtc/MoPrq7NfCe8K5KxvT/9JobkA5wKL68tVAtd/p9ue
# DATA ANAlaK3T/2WFQ58YsPUnukdDtr45++3pPxtK1+mXdOMTftcfzv4TE7pw0sE7/f3pV6f/iypNOHHArRfC/mfj3tq6AVRgmgDvOkU/
# DATA wfXN2DFMas0gT05dEqv3Uc84E9XvY9YNl6ULLbtdUdzQQzT2cdhHPyWzdVHD5joDsfN+hBnCNtjWp3SXiZBDbRVM/7xnuGnaVqlU
# DATA ro+1JbRvw3/iLdnWW607f55RcesbixXsKhFboYCtNFxBLRBKYhxe65ziunK01kchGZ34mWLdqlfq9TqPGpQB1EXVvI9oADFWDxMs
# DATA eNI1DudYC9Y7/xdh/wCRFBx1ZiAUKK7oIQ0EOFtQZmidW902mynFxvOs4FnnJsBxs9zwftXDu2ZmXXxUfzWceTc4ol/1gL7TeL7z
# DATA cH4jo7nUxkLSbR/d89SGroORVUg4I34yxWy3k0mT7jBTi2ZDLJr1YZmH2ElcoYTGQPpQo4kpCZMYLKnZUL92FMYT+CsHIVhFzBYq
# DATA JgujbWgyekoDnF5gjmfZHEmCi5RayK60rDxk1gzI5H0Uf6Y08Vb0MdU5uFfoIp8p59Pm7N+YYYWP57BLJkTNQ3HAJkNGZolZkJmz
# DATA 4pSi+ydkvD2EpywehuokeySGYZRhH2KcjbGOGcKrMRDuCtIVj7ABcTCOpqHHO9+ZwjXnscihtBxKy6G0rhGlde4YtNNUZ0fz+eZm
# DATA AZeZBFzBHMChsxw6y6GzHDrLobMcOsuhsxw6y6GzHDrLobMcOsuhsxw6y6GzHDrLobMcOsuhsxw6y6GzHDrLobMcOsuhsxw6y6Gz
# DATA HDrruUFnBc1mvXVpdFZz1Bl1XiB0VmHVeSdwFmcsx6XHGSdoprpfkKNo+91ihjd6vc05Xm/0mqsgp17ASCoVlAWX6tS7vV5/HVyq
# DATA IYEM4pQlqNTL2hZbqsHx5ANz3SJNathrdNrrnm+1dnq+1++1++ue7zZ3eb4b9TuhX86EadBseEHQrlLFbvW4egfTht+q+oHv8bWq
# DATA XKv6fqPqNzvVTsfzu74dNG8YLeG5usPusLcuBxkXVqr5nZ7XbPhU4fFqrz7u1UvBmbxbCa53CQQWNyGNwJLWaCGwGu12vxNcBoFV
# DATA j3pRaCGwAgqokyOwgmF92MwRWEG37bd714/AoplQlX7fadIeBDRWFv1WhZFGRjwdoscH5Az3SdtwyvjUCdYBpNq1si4Qbzl5VHKZ
# DATA WGPAyt1hyew3pnhXmeL5A3rULs8D1835tJewy15CWR2En3DNYlu7mIjiQoDMET174qMMufwJMwyuWbErY7jWenx0RS16GDZBu4zz
# DATA WEUHfmNr+sXfz8mn4ovaSA77FQtbTzY/b8bpc16zYQq3GetlKvhOOK5tlXfztL5UmdfVyeXk3MklR8Fxvhzny3G+HOfLcb4c58tx
# DATA vhzny3G+HOfLcb4c5+sV43yhLqgT8tHwwKZ+LbBkyhmB1N2Rup4s00GECsK16iAesZGpGubdVh0Gz2IMWME7aZogjm8rywvNi0we
# DATA 6qPTQ+mTzWvvlIxpa07AJmwFk4uK0L+wrZHL4ZYwx0wg9J26is9eY7tGzHPv3fzoP9nRJ9mavuDWwWO20R/lscFWy1E8o+xQVDOW
# DATA EVW6D0dW8G+h86HmCpdqBecYp6GcoeJSx1v72KNM80t+kRU/JahLXQ1OQn2YGPvUO8aZRWV90m8cQarWnPs4tVPVP9Iv399md3AZ
# DATA Uvnk6bqTp+zWo0JkRIzKxEGLNKo34TQg4iFW/8FjY8x/9poJvIa40VvNhdeprwKFja5Ra8+PQd6WG3Vu8NmjcnpVck1l29peOJ3r
# DATA Cm+3YGgyh9dTQGwvS57tiQ09WKQTmvL9zd/IV2wGpK+3/uqv5Ds9Snn62WvvMOLhtVuPNljeyuimrjBb3GeLfU8K1UncOzWFS6kp
# DATA OBWFl1tF4aLq9s9UXcE4YCVFItZnKbkvQlS3ux9qGW5OKR9kXULaMt6ckLf12f1ceUBiiYe2PXif2y1v88Ki0ManCtkhxoLV9vKn
# DATA biOmWoeQj8ZuFLg3JCYlhUCteru4/XMnNvECHK7m/14xOaEoinHV3ISy1shaasJFVbI+TWNlusUzZjWS7QZjxqhkGR0QVi7LYAEf
# DATA Q8hsuhQNhxP2U1eMgL5URlV5uKJglMxE0d7S9IDGQcgWfTJaMFwpjdiNzgQuBdxiQ9/jhUHWG59FD9nHq5Q1zuUYvRzn5E0Izrhz
# DATA xt1Oxl1JKcdpZjnNrAtYdRtNx+vS0npPBJuoYqu5vHIicDXPyT43rdh4EyL3yrOgM1cn/Q29E0MrjuvboJounjJcZmdZQWCdMnIy
# DATA YY82AxCwVsyj21/BxXSAPk0+7asLyqKWbxX5w25xddtP/UpQafyMBkUdow2S8sqpRu96jz9xlS0iiM0tpm/NH1ohAAeMbDhOPN5K
# DATA sgU83BTDG9zD0p0roOCNYvLGh5VXnRdXRx5THpGXUjbSOomzpRE4m0urqSgJs38bHoX3pYtVamYgrGg3KJqJygfWezueFbXQRDUr
# DATA BKTFdskpfSwaMCF6JoikyYlyhJrmDoUrEeCip49xuouHTtacstx/Nc8UF0ZEspGXg8VSUZgm8RQXeaMRBKsgEse0C2h3ZToqpYqQ
# DATA T0VsMzmfWkhpFV2nmFvqFX7jOlRzPlNzzpedfzks1HyYcSaqM1F3MlFtW8QZqM5A3Wp4Pmux1w8LjWSGgW4RT3Mo031ZJmUB1IpF
# DATA AZTUee9oGUQILOL4DmcX/Y6mMkx4rIYuJ6uFhocUL2w5m50YPcgdFVw5uiY2QoKiWgBBRzEIqLFSu49Y3xKdxxpvnTpxvMZSlT0K
# DATA qGD8SdGBlCWjf8yNK3OFpSeAnI84HBU72XNjuqXNrCKz8YGhP/K5aFdad5gu0X5qxWTEzgGMjugY5b54m4WJFql9yZvvsnRsBeNo
# DATA vm4JOcriQ0772/xpi+1aZIPLTgLbYFE0801mY6GMsbtaGuslAOw6Ny4IYH/0eDOBXTJWCOyYxEWaka6c9ieaxP4JtoxSytNlJtu9
# DATA uAbOWDtVCeliDgQyp16BjrEJI8QGCq+/JENXKabGg5r3dswCq0sW2vWmccazR9nrgu1KTBHlTSByjVsrrwwLiQEIInpdqvhsT422
# DATA L9WgC2bwv/zdnzbncKE2SkazpGsaifAv/KrxIF4Y5D3/ktOXWPuWjGrRUk3m+tT9gmpbyjq+OLy6iMU+vzfiQ+E0N5j248MluI/K
# DATA 9VvR3Z2gooT+GJKxzxK+8ZB/kwn7VeToJevqNNutrn4YTqUqQMo6zzqpLZjiQMFW9vmKqi10qifRAkgs2d1knvYY44Hei0EfJ0DL
# DATA Cq1rBmVANAiy/ig61HtSUagNCqaBPPvq9+8uVPmEdcaxp1R8voyWkc6/9zGDw6SNJtC5EvNxGLMzhy+o4+YRANBvS4PkNQmpOFle
# DATA UTlgZP0IRws4PykDZ3AhcUALeQqY3ggURRoqUWhXUvVM137BjHxvS91Tg4TkYXmF0luk4RGNm8eUBp2ZH6ujBGMlkB1KtUzJhomG
# DATA mTIKqJebLRgch7Bgl8j8hBryzPQMqledUq+R8VwyhsSjtayaw+UWsZJzj2j+q1W4Yfs903z9ZNd8/YQJfNZyFc435q1bLYel0SH2
# DATA g8sBEUpIpoYMjDa5er2RPM/YV5FbhtFoxDls9wNhP2PxapqhsXtH7lHVGb2pWH0xOtufy27WUoYWjQTZs2gbCeaKZA/ZtXp3oZ7Y
# DATA sbNF7fqjjmgwTqCfFcJfSiWpC+KVWHizMXpUEpFN0Psvp9+e/YfTr07/+fSbs9+Be3f2SyDx6L/fnv7+7LeCxvvD6ZdnX5w+wd/T
# DATA b06fnP1ulahnh8OsvF8yjQ/Pfnv2Gzx1+jVdZN6eoPfo7589uuWrs7+j5/5y9ivg9BCDfhodVw167+uzX9Pf3+FnJu792aH1XgRv
# DATA jdQ0mzcvU84HMVrpTLYFg9jwY+ObEeV7mGNkMQyh9MOWgqxv4PcHejtJGg3iubK5siX6I27t04TF+reS9N6SeFkNyMH0bC8Ncuem
# DATA OXqrZXJ9KD2pOvlK4sdSlUTypHwzeiJrzTE6vhZaNu+onqtDF5QVMmHE26bRbOl4ejuU2ZUj9cSs576cux54mcVv1icDQvduYs9z
# DATA N/ZJ3i1RdU2OFdRHE85ZZ03Qv3zoAIUWT6c4owOYEBW2gRFfqP5twQCXG9WzQuydnwjH2HPj/FOO8xqpd6nh/RVZgLmRof0aRvad
# DATA BvaLjOs3M6xLlSzngIXWe5ZN5zpIeuWk6kURcamGLDdZGhEze0hE/FfGxIpAsWRxVtZYRcniKFokc34myvhAe0Lm0mKcDLNdMHkf
# DATA Iw9lGascI8peeAh44y4lfxpjg0lCVhn2bMlAn1cXemeYLVOAwUIWGKVMZn9+Rbvt0wjth1N0wiUjOjhCAoRjhUl1ujJk4URwXwM4
# DATA qzXPzNHwHA3P0fCukYa3y+ix01xlV2P3Ru32y5jtV2G1Oyqeo+I5Kp6j4jkqnqPiOSqeo+I5Kp6j4jkqnqPiOSqeo+I5Kp6j4jkq
# DATA nqPiOSqeo+I5Kp6j4jkqnqPiOSqeo+I5Kp6j4j03VLxWO+g3Opel4o1GvWj4AlHxyivPO4HxCtS3Rs+ixjXqDUN98zudIjduNOj2
# DATA VN5QBGMaWU0QjTyIZrOel00gtD05PBX0CuF1msGgMVgpqKDle0EQjINO/chvNj+vtr2eX/UbLa8X0J96tYsv1V6wpuRW0XytgEJr
# DATA 1cfN9uedjtfxq02qB37zHOqcCWwFExd01mZA1yL3UeStytlo5RnQKLz3O81B0G7UV6LcaNc9v+V/XqW0Nqm2VDv+tNWkuH9eDXr6
# DATA yqUT4AeXAN1xq9CgO2lgFuiu02w0ms0dQHfDUbsIuguHvUEzB9112q1eu2VAd8POoN63QHcdv+E3OzcAukOTqm63NzweXqxby3y4
# DATA H0TUC8RhRQIuLeatoOIavGCWL5cVg1Z2y4qTSufQiiOy5O+3w1rngb/QoOqx763OhpN6Ri2BrU26cauuRtKY5UWEnApb0HXrtwqU
# DATA iXarmLW1OWMGPr36Vd9Gg9uhFlyXKeLQbg7t5tBuDu3m0G4O7ebQbg7t5tBuDu3m0G4O7faKod1smJskmw9s3RGQ2hCn3F679T35
# DATA xkuOjOVSyLNkEU7kfrSo1z8IF+MazyT3+OKt1ykHcByV3qOcaHNozCznfPte4R235Rv9mHEvskjexXa8Pd8O5VM5TGYFUn5nKRh+
# DATA duXImSaIyRTQHOlwh6jdIep1h6hLx3zccWp3nPqix6m3CN9e1zFraQVsB0OvXVZZzTHrZyjkcRPUhaE6nq1qBr56e4e3lKStbnYz
# DATA dmDkAvDqqbxvUt9zZkGRxTCNWYCupbAN7PuXRSdsseC1qJq/WfhWxlNIMZthDcWAQ9WS/+dEVz9v4msumAj77XUR7loRDnaPLw+q
# DATA oLRxPDiadOWcSKqHct1e9b3AgViJoW/FsGtHsBi9jbyHt1SLioxo0IuLe3iLrTwexhjghcmJPpD83ggqm+hD+Bh+xgMd2l5GZsm8
# DATA wj5NaqUTeP0nJx6UNFHJYvDyxCgSb73QuaTW8blxaoYqxCEFQQHCzBnrAAcJjB4Vkj4OzvwJrslRtsC6O0+pWIJpyhaxJQKA0+Cs
# DATA wMjLqEOcJPNk7ebAFgOAyYbeL0umke6I3qfZyxFmSGMGYHD7HmB3sEoQop33NecDGl6eg8UOEuss2e2WrLNbX3K79aJQ2GcuD8QL
# DATA 5tZC8KrRNylIAjL1J2PRbcU/6PMxUpgiWxmqz1xV6AVR4LgObOqKAtJVk1PXqEmth6fupoRYqn/IapumwCLSb6ZIqxrWWbU9V5Dm
# DATA PT16IrTMBE6l+alsi0WYZw1PCpIuoYeNEsupss9QwehDFilDCYFJTSoaKAqd/C7fYIySsgQ3x/ljFnuVKEeUxTrG75mJWsxzQIqq
# DATA 6Bkt4rTCyuwcG63KXrDQtOK9jQ9ggxRBkRWAIxhbov0RFua2x/o+oCsq1rxNKRrqiL+jJa6GNLtFbCgJnHsVnvJVvBNslhVVJ/QY
# DATA i+QwgopVzbOM6oSVRacegwoU9WVTdPULV2P8CgnY2H2SszSdpbnO0iyMU85j6jym5xmoz16YUmKQKWXFNEmmrFLHDSKXp5xMpKms
# DATA FUmsqXpeEWdFRQYj6M6hGWF9mqlg7FnxZPVOtSteRrwYBexdthKUuqO0SbXcyGGi55szdhMu4HCCDQwikO2gYLtAwcTisk2rTXca
# DATA PzfTXfSXzfdrlU7OVfV5891axrNofjz/GLE8/y7IcfH3/fZmlIsuDEG5/GgWUWcyZ9diFUcWtWWI9Q2/5R3aKxlBs04XlBvx00gR
# DATA yGgKgq1yk5MK2e3Y+9unejHC1wXGS4SMPSQZ1jzkVEfGPQSMreMwG4uWqrbQ6dJkkl0FB+dG8u+T44Tzb0jj1LyYe416MfeaXSv3
# DATA 7vNCDZLNfa3KJCiWAui8YDlKkcaUu8QvPImAL8JmXU8dwhWh0ivIrUIbvHiGtTZnmNWgJc9+QH0qxe7dlKeyc5nA5PkWlGpdo9Oy
# DATA 8m0BU4qXydhwimfLBYYciJZOihMrHjEY1kM1j2ZXioJnJmFH2NE4eQ7yrn2BvHsLVSAVWYl8fbCQfaVq1wjqpeyr8FSaTdRDKYqM
# DATA 5qmilApin7RG7EcfpuExtvLqpQHWm82XBp4mz+w+/IJZ9sHm/MpHA4XwSx6E2rrWmfQucyqEGwF0n9ALj8jmMGY6WbgPqOFNFNpp
# DATA yKrD02TIJD9vjHVg72MRCmamFa6Y5ROzKpPRQE+5zpq8aNFXkW32YHbhmhZszrh8YJSMM46BooGm8/A+riqvy8zzu1TDhjqvQq/R
# DATA 5j1DVFGxLZBdCDRdUo4Ysd0YI891LfEOl7HiezE3Vnlv2GzkLefPK8LrZXFI5BivUbyAxKzN8fp/T5+c/er0m9OvwNh64p3+8fQP
# DATA p09O/+fpV4ze+moV2PVf6affn34LxtbZf8QtniC5Tv9y+if66euzX579toJwKEwK6xv67Z+9s9/gpyrd8YR+/xW/6cnpN/Tmr86+
# DATA YDzY/8/euza5cZz5nn6tT1G2w9HdJgCicAepppaiqMuMLjwkbe1ZS8soAIVGiQAKQgHdbMuKkKyZMzMxjuOI3YnYiImzO7FxXuyb
# DATA fcGxrWNZtuQX+wXQX2E+yT7/58nMysKt0Vc2yZRNEihUZeU9n3wy8/8DsksRwH5NX/9EAdJPjtn1PLhUUqgfusyBzQOSPiSJ4AOl
# DATA JqlxgeNpe8Lq99KhUIaFE4Ev7mP6Fw3EBSntFi7ULk6fgwMAhRJ+ChxG3ojK2z3bSiM/DvprMV53sTLeCQ5NTB3Hy/a1qA7iskFe
# DATA S0rl4kheqhamS0YPVLXsRxTP8eH8/VIb9c3vZCrpecK84DJUMREtfNmZH+p4OaDXZkV37kyvB2EKOkhZEGNAUnWXZagcXHJegt4G
# DATA e4FERpihCuYUMTw/h/ha8N6OOnp2TL2bTK/FOaVSukD2Or4yrrZnFlvZs0J7HZ8Kh/Zy5sD5mwOa9nU6K+ClWG25LAvgIgyAjcb/
# DATA Ew7/lzP6S8VcyAUL+nXFGtVFcMAWkg+oKdaGEua8r09ZjmsgVK84CfPpfGeitkbwFggWCYmCsXmTDopTLgtOKE7lOtiIDPaQfb3w
# DATA B2EDTgLXWzgO+jllydGAFnWmKL6ww8UIY21MNYTXkDsp5okjrE0Bs2ME5gEFKi4POKeojcM1Ew3zlMUMYvfIuphEw1A7qnj5DKFj
# DATA GRpmS05sFnqx2CEGBOUoYY4S5ihhF0cJ23DI2WgOtKnpfLnTgNPMAs5jEuBIYY4U5khhjhTmSGGOFOZIYY4U5khhjhTmSGGOFOZI
# DATA YY4U5khhjhTmSGGOFOZIYY4U5khhjhTmSGGOFOZIYY4U5khhjhR2ZUhhlVa5wz+fihRW71a7reeIFLaw9LwRKszOF7/qlf1Gr1pr
# DATA ztGmatQ7NsJltKlyQ3KIy0jKoMKKlELK8v2MUs982ZV8u/Bqmfw378yEXm36Fxh6s5YGXmlmApdUpYH75ZoNAcsE3uw2Wq3ufOC1
# DATA avPcQ8+A3irCYhNImV9LQW/VRiaAsBoEjfJCs6DHPd9v7Feq/VLD8+vHEMhW14n6KQBk3Ng0gEzabQZAVg2atQ0AZJkrAJBVO+1u
# DATA MQWQ1drVsFE0ALJ2t13qhBaArFppN5sXDiDTDXQtfKrgVzWFLHO/GR31AkF1E9pYNgjNG0v7cZ1TC45M69EWFmWWPLPpskChpiyQ
# DATA ku14KBWWrAn7bBBl3pzxKIhlgOd4/mK8SX6V7ASYVEs8kiXjkZRMmV9mWbLQV114QemmnmtR7+2ndslc9Btszy3jojWbzSwNDavM
# DATA qyllmXLLzZXFGmsne+Oc78G4Dx2GzGHIHIbMYcgchsxhyByGzGHIHIbMYcgchsxhyF4yDBnqAoXS6Ye5kJeJOrvFHDvd+dOIzO4w
# DATA 2f3Fxzk4VPfDXbZgc+ho7+GnXVTJm6ZC8+kyWEfj7Z3Pou62PLTzmQ6aWihMkGDYDgtDslB38upVN+3gb7Kqsz64sS3R27mJruCj
# DATA rYfpMbaO4MQ+t+Y42Eeo3y+liGMfa96L9NNTlFRW8qCJ8Xhb9VbQJ5b0UwKGnWu7I7V7P/kpDLublD4E/ir9tvMZP707uslnMihO
# DATA 9OMP+RrFY2lqMgk2WX/TZPhNqXWY0HOjT2sY5fmbSt+Z8l4h4fTJH6P87D3EIans+csxRZ8JHpQfUSzZJ7b8zc9Xv45Jb+0w6m9v
# DATA U1LzSPPOdTZtAXlTWUIxoSSbekENiVNfYDfuzmdphbEuS9zt+yjjbC5eWoNULJGrkkNqLNj5LM0wFB2KM6JsjF5V5DyWdEM6o2vX
# DATA 9M2F0ZRMk89UzG/InThlR/flOCI0sf4Qp+7+44t/UWcagc2Lrvk71MVQJBaCz/s7a8LG8Ug77Ps4LsnLH4uhf57Whc9VHeHJpG6T
# DATA i1VZPXAzU/tvSj3bxQxWVz3rhlypWsy2qPF0KFLCQujj6sCtjC68ts7ATdu8emqMM6THPcXla3cXVs1Pc2Cun1nXJO5DZTVtDypR
# DATA iIpOkpkDLokWn0GJ+jQfMn2qroHmMRkrdjKRpmAPoiFNF5cFipU0eiicyyTHjHE6E6fUmXD6Ei++vsRJSTJXQXeCV1Yy/vr1OJn3
# DATA cAgeRA6Ir+qD08EeXjWJB/GYZmZrmTJXUbTi+TnCfRGkmUWNjfNGzSwTMTkla8bLLBFJleYVtlt+UUsDC2bTyInRy9QtEPCUepKK
# DATA fNhC74/JKsuJ60m07BF5Y3nLal48wiwScD1hPfSm4wlLfUXqvSMa+YeinxArqQ8jYr9G6OM45dEX6Ih+puE4E8qZUBuaUHP9qxPt
# DATA cqJd1vC70vi6CmJer08jMLWyslVGyust0YWymxJGnlEYo6Ed9OLMCCUIAT2AFbzbELFB0bGmTiBzYQUfCx9Tcwz6UReKNxDdhvNB
# DATA JKSGYdjRmLGT8lNMRBXwQclpQ1o9t0RJy8FTNoGnDGIpOta7V5/XAVHG7EYTCXz5vPpu7PYRbvYd/rT6Tm3uKL4Qf34e0Cl27p1Q
# DATA Jb8Bw3G1Tn5aFhmWBXv1tDg+z4rSkQ3j1zie7vXSxvAJw95ZwkPjkqZDMh5ZiyrdMI32vB9HrG3VZvPQ0yfoYTVOWWxuxPK9MDYp
# DATA Dnvh5DwoA2fIv+rJ8u+NMHnssbPdQgtAG1fBnUx6WTJOXOEJ8wxt0+Eg6D+mvNLygRwebpv2gelmVKMXDrkMWLwNpyC8znSsxXVp
# DATA kDofpkXaDE8KZyitz7e0VUu+vU5jvOz7Y6bONDK1T9lWVOfCcKWQIVaPhmBZSF6yNJ0sJiSK3hUmk4L3twzECNu9YfTpNDQKilRJ
# DATA aUIHVsKkh2lHL+CaiHydqIp7DrmZdlMnzctj6qDu9SQnP6S6wyqIWqrZYEhNJlEauQqxhapQowYJTxZu+zGkIOdMWZV7AcsuKuRf
# DATA P1STTM52pSFnRL272WH4WbXg2sla8OtBn+0INVUIbRYNjAPOkGQ6wgSMEhiMW4dqbtAWnUXZ6VzweKUGucty5GPFdqNc64YhRBQx
# DATA 1SKLIkxGYTtiIqyoX44PWc/QTMKH4cF55KA99p20AhbXZ2E6lCrYCirX2FzUFFyadg24a0Nnr0g9ZhrWDkDloYw6IAMbpjp2UHg9
# DATA sghRv5BlrALKwodUqaEDuY+tYmqPzZWFqrxAro00COfXcH6NDf0a2Zrm3BrOrXHKNaGVLpAL0yhXVTZDf4UpTtXceDeeOStjnXeD
# DATA mYwrOfa80ZuXObD7W51c1NfMpJd3Ndgjp7miZ72cS+n5SOwMoW9xtyumQdARuyDjkOBdLfQz20im19lW21N2lF9Et/Ahb+jHKyRS
# DATA 6mnTM+rvZp5fluObGAbGZNyT8cJn7nBxEDyRO4pyTi4c8dG81b4T3iTDKbHKdOOoqqdNVPV3E9XSsVH1GxtHVbb9ILL86bi46dvT
# DATA 2JkrJn6VZdHzreiV1sROrQoaf5acC+DpH3h713mf4oBMbLmRzY/x4NarIq2QZiGOhdh1ML2UqXMjGtwnchz3ugSRVmTjm7Hah7m0
# DATA woEjJhFNBjuWqZ1R+P/PZJu29QSVJuZdjJIGpCNThoOAhnfAdkb0KBlomIEpKlA6i9VASkUnVJMtoaSavb8W0hJDctzPM8ySd2zR
# DATA WzrgYcZCE4UXJed1ol/+MsKQwu6V4TSBIH9ySLZvPEhSL6ods17YHx2zcDxXqunise1XTZeBJf9lzxY9fg8f0hI/VWCylUsaZTix
# DATA qo/YsFxiL4dVbrEOp2Oyicmks2mH/43hhV+DNphlEB79Bn8v0g7/dfaUeYR/nn0/+7139HdHX82+m3179F/oye/pk+IWMuMQxEIJ
# DATA nEP2GIj4FBjFoy/oht8d/RM99C1u+372BwpHP/n72ffAJX7DGEQK0jEPn4cZhqle6cSCKzyIJ8hReian/JXc4WgkBgsnGbqzRJgs
# DATA ontUikIjgGFlCB7Uk2qjZxSFbZqNr4Mb3tfbGGgAYLSaQxtakwldYJcNN1wolYtDG6o6om8DZ0MTd/iXhfuxfcXqcB/EXbWn5dzR
# DATA hhyBDNgwSriyO6zhZsV27ljDu09GffQygXaGDOLOtB+AvB5PWLOn4H2Ivp/7rnSfFy9+YWM8PWv2P1EcpgPuKRPZBgUXSjwJ9FpW
# DATA MBR0zALQ8PgquNpqmW9ZzwpneHwaHM7QjfRnGOk1t/A0A/zL4Sm8tMH9/Mf2jYb2E47slzOwS7WcywOLWfisWs5FwAnnUokVAJCA
# DATA FOcvaluJ1ecc5xMUiEtTQeVAW9ObqBMUD2++lm3FWqIbVtKQvaLz+bYhkdB4WdPYJZO4zSuOPB5rVBzz47iWdGiuPUxM9MPpOPaC
# DATA AePfeMgPyWyI2hGWxjM2QcYCCJ/gYDEC74TwRqkd1WqtkKwHKs73wiBBhNi2a0/gihEjkb06QqmTtXVV1K3podQvRyt0tEJHK7wo
# DATA WuGGQ81GU5tNLePLtPFPY+Kfh4XvWIWOVehYhY5V6FiFjlXoWIWOVehYhY5V6FiFjlXoWIWOVehYhY5V6FiFjlXoWIWOVehYhY5V
# DATA 6FiFjlXoWIWOVehYhY5VeGVYhVW/Uqm2T8kqDDtdP6w/R6zCuYXnE5MKq75X9ov7+WbzU7+eL9e9epX+7pWrpU8rTa/k1Upeub7f
# DATA bGZyqe23yu3uPMaOwqotxdhVFsiGctJPAH7NLMCvWvbnCH6VRlrWcmwtJfiFjTBoL4ITLT5go5oJvlRuZoNvlleGbpKZCb1SrK4J
# DATA vXqq0O0SafhepVLfrzQH1LXmK839SnPjnPYXYYR136v69V6tWp0LpV1tt1rtpSjKk2MHpd1o7KA0QQs7WOtUG/XOsdjBoNvq1jLY
# DATA wQ793SlZ2MFOrVqvGuxgq92utCoWdrBUrTTKF44dNNvUIPy/t9F8fQ23T+xbb8Eu0ub43NvMQKmmXm+F1N1EQU7itxRgWFUrcaUF
# DATA Wh8WFhdeMOd2t41GXSDZeTeZe54PO8CryR87TLZON86hqjadkCli5GaDuhXMGyoWNjAbWXtzgR7R1bJXcZm3VxZTskkrwffJf6k/
# DATA 9ox7PXFwLltz83myxmxZm2S2Jxxw0AEHHXDQAQcdcNABBx1w0AEHHXDQAQcdcNABB18y4KDNd5NkixdDSGl8VBzR3/lpo3itVMzR
# DATA zFL9dMBFuCNTNo35uiuHZPigGxrZNf4VXLr2AAGH3v/3f3jNIr51wnBU+Ij+G4K2RuHe2i2+9tHWh6ylzufoeKEGgdCPEkSBpzwU
# DATA YQnLHL5BXLzWIe5lOl7QShDijnkKn/hd79hH2SR1XphM4EcOb3j/8ev/F5FZSPt2uVS8JldZ3BNdA4LUKDOHEHNnu4872+3OdL/o
# DATA Z7pPSgq7Cme951xs6zFh76JpmCcK3nuo9ra2y1I42DM9Hf78HI28CArY/GH282aALUoCnJYAlvXX6rP67zK1SyqCvKYbGl2bN+B6
# DATA DLxOTD8kB3xG+x6ckKhaLAXUC6JxwXsQTdj9pAXfpQKKcPl0JMeTVeFmju8HqZTRCKKNcZfPIqeiOXMKNwvl/DiEqRwYuR3YRJev
# DATA dPOMTsFaLcgZQ84YmjeGFnpUJ3rjRG+OM6OuhhjOPamvTLToxAZ/8UncMoo49412AzXDaG+oyF9KQ03hI8c0LLQhbtHFzaIkkQTA
# DATA r8I9qvE4vCGf5TtEhwZuyL6t3bJEM2Vj8NdDqM7AP5Yq2dg8GPZdiGqHw31thvuipECfRCV9wq1mNeyL3Y4iC80fV9/L23O5Z3nI
# DATA n54HeJeVFyfkrjxYw0/SuSrElTtoFVS6YlsJcOXhQSxiTfEUgjEB5FgEsjJAS9ESiajhAXuhRJZJzEMa1/bhRf4l5FnGg6x6kagU
# DATA ke0Xp+NdAEEYqh2BaNR32VDWZ06l0ajZwXJh50UBaLPwJjZJmkCTY1rKAWMDFpQ5Y+gBSxD6bPyrU5fc/Y1L7r4cMBcrXRfdu7BF
# DATA 0BEGzAag4thT6t8Jk77CEavjKJZQFh2G4mNJH1H7piKQSeptzWeEx1Dti+LetB9OFFhgrOKSjOLJ2Yssk7LLK7O0NzlhmX2wjlam
# DATA +iUpsw8gQIR8bMUUIRsQxdJEeh1FC5rtCSOLcpc6cVyMu2SNGJ5WNzwQzSk9uE1EEh53yuIOl/QB09+YuWIaHZd+a5ocnr20sml6
# DATA Dorr/Y2L6/0A4HZezKC+PuVRJT3R0jeNgXq9PfjDH4eHYu23Aihoeb14IA0Lk4Mhh8YadUOPCmoMWhhQOeBVsQO+Gz0RfBxDE9LC
# DATA nBd+O3uhZVN2aYWWjsInLLOHq8tMj+eqVxTlQFxLy0v8EdiHj2GAmlAirMC+OGJYHrmtxgn2xnm3uXy7jO+iTggiZBj3xPLEsSlv
# DATA NOXDcyyeMATa5Rz6vTTuV79ESpuWyPuhUq7D8DFRPynCpZwPCvUAI81JrA0R6os9Pt6FFnAogoQCBlSthvs3nlkjAJjdPJRFiTZS
# DATA ULqif3cObWYxIacqpsslzJ0JY/Iy+NmsIJyjzTna5h1tdpVyPjbnYzvlYuNKn9wFCU7LlFxmehgBUblhYxoX2zOEGlwQeS7jydJ7
# DATA T2Dv8yZrLD81eN8Mz4TV78eAztJQTHdlXUqpccehzmobctgOtLfMgLt4XqB27W23B8cC7iSAFHCnvluAu6XYOF8ua3BccWPInezm
# DATA gbsQH4QxJhRkqBRzXs05ENUDqfdQh7Dgs6sXGfuFbe3eARYyeX9Rvbjay+f7/MjD8Al6oo71FP2y5rEKP/Y23X1oP1MprnETrkTU
# DATA adMUu2nJUps8v5A623V30KNQvE/I8hyGhwVb8lnpOksnAIfQQez53NKCsYLF6Q1rI5omKdMdq87UWVCcML3igZuCNu54cWhw3yIe
# DATA e+Xu1+ra/GK17cxjwCUVWLlU5HpntXDqo6Yafqn25LazNRV600qGnULRKuw5svCfSNc3pDj2ZarIqtmj6Rigd1nYjhPWT7UEsjeA
# DATA yL0gxnOKkKNeJGyPg+7EQsi9p6/lj/5+9v3Rl0e/BkRu9vtFdNy/LcW/0Zev6amvjr44+hKXPfrna7r4O/77KcBxdOXb2dOjfzBI
# DATA uG9mXyuFdCh8jaCdSkO2w8RdeVOfLfPAM3XG+5tgP/DudiI5iyWi92pfCc9+u+MoHHaoA+FvB/G43zHWPzzf05H4TuFKENdZ/5Dp
# DATA ujFc2kIRZadBukCheh48FT6hhtZZi5B7HQIarDXh8d/Ck3AcuXRGYDqFy+bILS+ai4PJ9Sg6TC5I4dRcX/X142BydwKRBL8IoBxv
# DATA viLbkf6lMUFcVxjN0WAcUG6zojt3oJzkWcBmzhCdm8yrzHRKGzZqMjWQDoosF11ReIGPhjf0u2xt700DahSTkPq2N6LkcQ7WDz19
# DATA 597PvGQUKlIGjr9T2pQqzJRtILgWJxvQ5pbX0dUmztI2eFWwc8sT49Bzznq4IOtBY+lObTS8FC7EyzMYLshe2MhcOKG1cHnGglTS
# DATA ZZlhDIWr2dAugmJnZQNAc1gk7oQjcKjIlDEDtckhns2vyJZ2PBhM0V1jAe8dzCDa7LBgSZGE8qUd2iP+OGQHhXj/kGGJ2mxPIz0V
# DATA GV/vRmM+RZskGxPuANJKlG9Ww8QoQ/bJIhyLn0P92qW5csQHHHhH0HvxJzSieZy8NmVg3J0UvPs63nJAQcHC5p3AC3aLnBXQCDKj
# DATA acEkM+QHdHEgHdyjTI7a4j3mtA/FXcN7OcMhc3RwQh6tCyAyVSUoVx3zzjHvHPPuApl3G45epzrYtc4sv/SZxnl4VE87z3AAPAfA
# DATA cwA8B8BzADwHwHMAPAfAcwA8B8BzADwHwHMAPAfAcwA8B8BzADwHwHMAPAfAcwA8B8BzADwHwHMAPAfAcwA8B8C7MgC8kl/ulEun
# DATA B+CVnysA3rIV6I0oeBYvrpTi6OQ0Wprv9TmF0mojk12VarNeDefIaqUSFUBlDVnNenXz1K9ulFqlWvn0ry7VTv3qcqPeqnRO/+py
# DATA +dSvrpWa5Ur99K+uFJ9ZWVfqz6ysq5VnVtY1/5mVdaZdNxuXmeGZdn2yV581wzPt+mSvPmuGZ9r1yV595sZVfGZlnWnXl1vWmXZ9
# DATA uWWdadeXW9Z2uy5Va5eZ4Xa7PuGrz5rhdrs+4avPmuF2uz7hq8/cuIrPrKztdn3JZW2360sua7tdX3JZ2+267Fcu1VRonvrVZ81w
# DATA u12f8NVnzXC7XZ/w1WduXMVnVtZ2u77ksrbb9SWXtd2uL6WsbddDqeiV66VetVbcr1ffpq9Zp0O9VatW2ksfq1Tq/Fi5tvhYBY6O
# DATA +knMMTUBseDyfi0TpN8ol0uLMakWq16pWu2VioNy1Sv2SsW53GhVw2qrvhTJ3jgVTb2c0tTFn2PR1BvFIKzWsjR1v1n2S9UMTX2O
# DATA rw6aeitstrspTb1aqtUqLUNTD5qtblBMaeoVv9ouFS+cps7O4HyLN+kbT6cstmsseuptbYjD2n5mHohuluKWLbvpjRp13qCJ7ZnM
# DATA RF/c7ViDn1VewwfBNtuWUbO2ZawEuluhrmetS3Epp2XVLLvoGsHHEnpBJz640aQf8afoqVL8vECvGsAFtmIJtrQQ3Po8TAP01FZT
# DATA vX9Nlq3Mr6Mluw/UWq+uYWYZQO0FTT3dubkTBdnl7eJq2LpdUmvc4cvqGju52a/uoOoOqu6g6g6q7qDqDqruoOoOqu6g6g6q7qDq
# DATA Dqr+kkHVU4tRaTds7xj7jlLt3Rftj1T446YQq7jLZlu5f8i4chEVyQ/iTrgr6Aq6KNts0ajTayIykYcNsluqVmtVvopZnsimJbua
# DATA jc5TY4U4V7+hUWpAOiIGF8QEwmy7DQk8GijYSPpLTV4QTzoImQsTX1DNuW0UEhqqw+1irlbZgXGEgyrb13/xkfrvxu6Pf4h/xxzM
# DATA x9f3clSuFqedy9ZbhNNDVWD3s/1gGPX7wY1SbtSf0rQ/uVHOQTLuRvXzX3BUeBpr4vKxxtM/mO7thYmMiyxA5t2//d4Ng41vh1F/
# DATA G2+4Np89Py34DabJvxW9LtD611n+J9XhnQtFAhABHJrkIwjNjx9FApX3CyUdJDpnxRLBqCCCF9DUE6FDfqGqM9DEm0Ceb0Lmsq5B
# DATA oiQEyRYFpOdMSDVk6epr68wpzuCou8KS/cxMNCCRNidPS0+nlXznJkYWOK7mNHIg9qESACUXW/KGYywDwY9yWYEOp1PndOpOolM3
# DATA J+biFOucYt0SzZ/VLIuromTnjcZop6yhlY2TkbK7nZV025tCGhfCTKu02xTYYgjebNSOVNCY37EaqxarYhrtvCRdFq21IEdn7uuV
# DATA bt3D0ERdi464eMO13NTPZdxWimkp+Qo2cMyEemAAgbrBMk6eVfQnLFAvwSXQ8vVkzNdT3ZsQi4XWlFKbA2LLs55knCeUrSjOIbTx
# DATA KSkRjGvNIeQjf3GXoxM+AURNZL3QU5mHaaRapdTH6X5D2UUst5cq3aqhUaf/gTGkPG1IQbEOeB9RKqb5sFBPVA5FrGNR8H6OkXPh
# DATA kXZvCt1irT+mzJWCx5OGzEAreGABoIqnNpehCqcWBRmXUOiTnht9LGNWIkSYQcX0KnOWIFmXI7dVFy85onp1biwmNybxSLENuK7E
# DATA Y1aTg/pZMh1hhMaWY+g5U11rhx2r/58EjwWuAKuQ7RlMvkaHqlD14BIcBIepRSUDkMQevmrvYciOTB03BrsGlinGIGJ7yOG6FU3W
# DATA JZvfj7d9ElOmtTAYBlznaN6gE/4uPCieZdtrVUCmQWX1AoWGyqJdFCUsbI245FhKLuhQFx4Zso0SlNMJEBk6DX/SE4xUUE6zbhjQ
# DATA GaStzJhqTLXTppzKBupz+vEhe33nIWuiDPbiC5ylo44zUJ2BehID1ZmjL485utLMvOLCyvYC/yLCrJ+xU6XF0N+THg9IsFWUhZo+
# DATA wno9CoV1VeWXny810eOADtZWDsHN8RaZW69SBz3fUvVxtMwmr0ZxbpOXOmoW9PnbsvayeExMWn87hltK3ng4bOvoKPWlWx8snDJj
# DATA Dz7ZPCuEvK1n+Qunaw4CpjfSaK3s15XN2NPK05w/2hhjg225eLOyyrQ8MPM6piPLljQMThrsYY/q6YLBfGUNzKw5ajn45vAV83Xh
# DATA 9WmEmr+oty2VYoHYdSzhY6henKOIjEMyXYIWWd0K8DHX3nH6VZqCJgD3yrceDAT4TblpaMjc3FjLN1BE5P3srIVlwEF9H4XxqE8t
# DATA 9ENe90BepPMPVjNTxEWRSc7ohGcNx0mAiqtBb8ZanEdKc5RV6enoqsmfMfYxe9DlqZhpMsPATgiZcTKWBLMU1VWp0l4TsXtjMiLb
# DATA k/URu8PrDV4Ci/9QR09dlJk0W+BegKrEeYScPBizanZ8MKQpG/0UDSCHrivr0tjckcneYmxeQpFix012Vvxprfj5Kuf8zM7PfGYD
# DATA fuV04eL8zIYnPs/jMFi1K4n5ugz+sl75pR/uPhnJvh1eBSdTJoynifa1HsMzToMx/Z51yQB8G8cBmP2NgcbG6P+Qu0FELAsw1jek
# DATA jGUzTZjnCqtVdvymHPerGcRqHV6mefxx9b0odTbb2G+/hlG8mDJeSzepwzdGTCjDfPut6PVjEdNWMNk80BdNPCvHFUv1BJxpXvVX
# DATA 0D+KqlzAnhBqr5QJ6yNtHrew0/pKyps+LrrlTWPLGznSDmxAHQP1HXNxxO4cGzU+6WQ54/LdxO62l5DFpJdp7KhuwKS+q1HJ3EGM
# DATA Q16z0J7p5xdQbdYKpAPuB9MhzYewIJBMsoxqk/4O4DRsdvEagUUZQs8+BpkZCGnpZQrebVzej8jesRfJ2BIKn7TVaoYn6xHqqENX
# DATA UTOxwSMQgM1hgg1rPOvgGZsYUbxWoQylcRApehNY0sFIeuq58kwdKKp3TDeRZDLWco8YJM8iFzktdsmjORzTEg4Tr7DNg5iYadWJ
# DATA Q8FHqZmfB07UASoZZQYjQ9sThfcxo9DxnOwXbdZkAbOnSdSGlyeKLWT27L8dfTX749E/g2o9+/PRb2bfzZ4e/dYDO5t++MPsm6Pf
# DATA LtKz/2X2/ewvdN8/zr47+i3dPfsjPfxXuvfLo9/kPPr0PT35+9n3R78GRRtBC0n7S/r7m9k3zNH+gh75d7oFJO0/eXQXeN2/oWC/
# DATA oWCf4unZ7yhaf+InKYjf0d/fAct99IWja1/9CSF1YvEgzIMsJ4gszZ3ivqpNzRQgvD4vA/Nq+T01QgTaps0JEoydU2TGjfqh4oUp
# DATA 2hX1fmMNtWc2WGq0rqVo38dD1AeFDp2dme+l3cNlw7OtErk4YraqVYk10+MLXDGT+btbYZB216/TF66MrZDG+vNEZVO4zK6O9Eim
# DATA tlYsTOpeUlb2BoV27qTsO70YOvUBIOY0pg61/UoZzG4nRZTk3oTKbWEPuPh8yWKhTmo/7N9EXHu8TYrsu8T2UgWJ9IZ6c8pJ6t9q
# DATA CyZtTc+KfX1s5B322g3rZxzWNd76ZKP5y+G5vcSR/DwH8o3G8RMN45cyiktNNElPd/s+06ZyEYBqk0bZHroqedx5K48Pl3NOdlJS
# DATA GvZYKiOY9CQNXWyE7MmSraw+0/Q8EDLtuHc46Q3SArP2QgY6NxSyGEPxJkTq92PPRFfAu5q5zLEZxp60muVw3oJ3m39kge5EyMSs
# DATA 6CxLWKpXRUDJJB6RtdVTFNxJ0EKGyQE7sR7SVBlANuVXO0pEn0JnaRvOCMeXdnxpx5e+QL70RkPKRvOVDQ3fy7HdT2O6n4Pl7kDS
# DATA DiTtQNIOJO1A0g4k7UDSDiTtQNIOJO1A0g4k7UDSDiTtQNIOJO1A0g4k7UDSDiTtQNIOJO1A0g4k7UDSDiTtQNIOJH1lQNKVUjmo
# DATA Vk8Jku6Wu8Vu9TkCSZsV543o0XZ+wMVarfZqxdJ+uVx8m77/cj4fw2pzCd6q4fmNSq9aqe03gLdqZB9r+516x59/bOBXql6JHi0X
# DATA 837dK5Xpg1du5CsVr0z/p9/q+YZXKXuAZ/n5coOvlXB71Ss3vbKPu3G56DW9SiNf8u238k7ILNuq3KkGteIyttWSulFFfOr7fmke
# DATA 0NaqtfxWe1kolQUYn01JK2eRwRKuBfCqpdW3nCWZh0G13lqIYalUO3sMS345jWG1fM4xbDbPIYaNWhrDeu18Y1iul84ewzI3iQsq
# DATA 5Qo1kjPHsFIuXVwpV/3G2WNYLVYvrpSrTf8cYlhvnHMpnwSkJ4OQBunJeGaB9JqVql9uZkF689g8vhLMg/S6nWZYTUF6taAa1hsG
# DATA pNeutzo0RzcgvSZZx+XGhYP0ePtnfp11XyjP8ek+tx5aZNFlXEJ+Izvr0ZnANhZctpT32PS4nS91wr2dTMhzhL63QhrXoyAncZ93
# DATA fpfZ9S1L3gznm1+/VyHzZG3TNbWCNt/Zn1u2ko5gPL3xKGO5G8cCjhhoXzg2huVPuARUWeaAZj+cFZ7ygi3i+VRtypYGCsPyStSx
# DATA vLJ8O9TCKwqINdms1iyfTFTdGOwSJqu42m6uhu6lJZyzy2TNLGKxtqnkWtVIObvXFw5PBVDrV06j0oI62XzUQQAdBNBBAB0E0EEA
# DATA HQTQQQAdBNBBAB0E0EEAHQTwJYMAoi6oieIuW6e5AIc+c5DwHedYhq14U/KDT4ftSm2JOv/rLn7Mo7bc5EBEPGJXDW/qK8XtF8Vc
# DATA KVfJ1aiPjLrzPaS6bWdHP27uvsmvMxVxe5iLwH8b6m5vVz1h9Xo7N4drcwkAOT1ipfFT75FR8snurSf6DdKT0RVl5z5R3Rn9B3qd
# DATA PccY4ejY9s5nmZy8yYeAta3IGbozl6rh7i1KEB+/hDHK83Y0Pz4HhyQU5OSnwvxR0NwrKQjeDptz2WnoR1vqvB86irRW7tKoyxKy
# DATA csqY6qMw8O7LoWMkYUQdLGPuTMImbPECufdD9fYdsfyXl80xKZnEe3v9TEpyEbVz1CJJEgf6C3z/2BSBAirGu1wrte2ftKHziOTu
# DATA 5PYyP71Fkwiq2DENWSFlzLB9KIXGr6G3FV/zG8Ub5XLx5l5hj+6Fsfhz3HCbjfptnFrIqQBlGzou7+i7wyejeAjBtqB/PxiMHsbZ
# DATA Z4v+4rPXCsUaIkQJGVIRbe8hMP1F7oaSXjTklU3cyR6obfkUj7aXhVinYpICvCeZyYKJgDtu48M1n5mNcddrcJFy4vUvP2nc5Lq4
# DATA a01kUNK5chErcAKAhBsl5rr2uZqTsDK+RjDq6vBZWvdvqqrxuW4DPAWeYLsRF+HtO7sH0ZAmVgU+Vc718snkV79SFw/C1uNoYv8k
# DATA vcWdnUmPxmnv7njMtVuOpFvjNNLHWST14Fe/wnzw9h2KUHAQRDT74+xDPz3AOLmkMp+wFcUjqxFJ/ygN5ebnPNu380TKSOKcNS8W
# DATA j6+L6JEo8ED6UE5xt0IvpGmabpvU75ip7JKujs/HRX2a1mU6PRSZeUyGvB0rlhSoKoUlQWKNnx4xQVnPcda+Jq1eghGfmjlU67Rs
# DATA nJbNMi2b7EFrJ2rjRG02FbVZKUB+UWI3d7HuwqMr1CaGoS3booVvnp2A2mWojIspQJcf4oO3jeJIrg+i4XQSHqdjrZ81nZO5YCSX
# DATA lWr4vCS07A1RmtCldRLW+pgvRZuP60Ix/hBdFud3zMIZVDq8gNaTlSYuTgpA7s9mjFlPsnLC/MhmKS9ZS97wFKjId2YzQntw0qww
# DATA t6ZJ5wf9OXXr9e/yN3+Xn81mPFg60btKm7+rlHkXP1g+0bvKm7+rnHkXP1g50bsqm7+rsiC1fqt6ondVN39XNfMufrB2onfVNn9X
# DATA LfMufrB+onfVN39XfUH//VbDvEvrq5g2vFJd3Z6+vgBi6nqoEKSLViKyRhvq+x4LWglHZ2gqJx2YjJCYPQCbzJP0AaSWxpkuT0Lw
# DATA c14551V5OKqDohUOWUjVww4CDlqAwgNDArMiRgPVcv+ph/6VYQaW7JfxtqeqUjRMYd6gFcEwCCJMsRpPrge2gZT58y8m5KCtbuq0
# DATA furkZkov5kzppCDWZy4Lypu70n1eF4HwtOQ3z5nbaYuXLoV1rsTJsoYgnzw0LVW4KJAZX4OVvQLiqM+JWOCG8uZeunNQG1fitdTz
# DATA ZTmxQ7lDk2moaEIlyRhat5VCazBmkSs4RskYwtNkVpF9xfxTXnsRsdaRTON5axd0GDFP511NOTygCipVbuQJPRVS1Kd37GMnolCB
# DATA 9sAmY/lJejkzcqDLp8XQT56LMPtYM3JOO/YyJdOfjaWUqZbOWHLG0jJjKdNVOTfzS+9mXmlkPXtNdV3zqToHLCt9CA/AkO7jzUip
# DATA xvpojKYJGeC5RrY3pfkxu5rHodLAXpD3puZiFMAtZfBYTfG5Ds05ljNWw6KIurmPxlXdjHlEotI1+soYNuNu1wv246jDq5/DOErY
# DATA JT7WmtrSHaTg8TRhWtGt4D2gIdrrUmgiop7wOqkcJcbg25e4JLx/EYEcGi1w6lmmrYQa/XQihhvLyIH53dFEOMS44L2ndLa9QdQe
# DATA x6MeO2AUPi4M2uyWx/OUA9CtRve13BOfunsCtjWGSg1eZ8qDcCJmRJJKP/djbGSZgOYrG/BGAUMNrW5PA/QK3m1kJgUdjUYKvI0g
# DATA 2CV308PCNq4yejuQu+wy93BGAn3xELmj0e+Sbk6Vd0Bv45XxNcl7P4BdI9zivdiozuMqm1tUEjCLpYA1dp5KXSr5JB7E43F8oPS9
# DATA pfrzKrkuGq76nmTiEPs642kbGjCMQRffVXqIN02bMNwNNJ2KCgOfoiyvS8+bLM/PnjEs8CwAcvpk0fEUJIS1KBaoUoSPMUhNeAjr
# DATA kclgG5bUJjFpYFMvEdOQbu/ihDqaghkHpToAhyiYALzoccjwedQ8ysaBFBKTp8my3ENV7oNET5GZDjEwY00pHiXziRR76jhS0OtS
# DATA z3nlCvGRHJVcmM57hBFtHmwyG2mtXjevHccY5lZ6ldc5kbMLJaYU1mRe6lfmV57xtb68ln6RZmUa3/m+hpdLpNGkLCxhFnAjOt+3
# DATA 8YLJfS5ZU1kn6HSsThgt5Xzfyksn2Pe9umFmX3h92j+jL/7Fnf2kiEt6WyeOx4nNt/y32fdHfw8g5dE/M3fySyZcfnH029n/AFFy
# DATA 9s3s60XA5b8xwRJ4yi+82bf4h2GW386+Ofp7j9GXXxz9I/35SgiXKmB6EWMtv6PAv579RdMrGYxJt30LyuXXR/9Ev/3JISyv/rzt
# DATA gcy0xjGMJDaFsWgUT/d6E2bkiMy0Gl770QTqGnKK2EzEpkNtu5AphVEvYHirDPhswSQycwMGBWZhwGdQ1/IrH/COC+oLo773CVmM
# DATA bEQ5kmU6h9O9wGVjLJcWzMUBLbleJtb8UVdTQR5lb0ZlNbfeUzUXw9t50izJWGUhBbWGKXtNqEmMHMlyg9I6d5DlbbW1qk/N4zB/
# DATA EPQfp6QmMqvB2wH+RyULtm47wHEjGmXHkGdTeJ2ggxHCQKOGYUhGPhbgqV4e8txAUZBwfn60QLI8puatNkuWNadnRbQ8JhGOZ+nG
# DATA +LOM8Rpmedqh/aVwzV7asH4xo/pGg/pJxvRLGNKlXi7JATOgP8P2cxGEyyVJ9WgeSp+YPReoZVJJLmKZ43XOANketTHOIsWc3GVR
# DATA 5o3P6uFxLKBA6ZtaWDfn+AYct2EGtbcJ3DLj6EaUVDKM9ie7u7HVzzugOTbWgEX5IBEqoPezJDWhZOQnyw27vLsUswiGgKAJoyGv
# DATA LRnaJaydSF6gPMMoNF7Ium2hIZVvtRPSGDmIyGw46IUci8Bj04Q32HVDR7t0tEtHu7xA2uUmQ8xGU5qNbOLLNu9PY92f2bh3yEuH
# DATA vHTIS4e8dMhLh7x0yEuHvHTIS4e8dMhLh7x0yEuHvHTIS4e8dMhLh7x0yEuHvHTIS4e8dMhLh7x0yEuHvHTIS4e8vDLIy1KlElRr
# DATA p0VeNsJmq/scIS+XrDyfFH5ZKXmVWs2jfPP8crHvF6ueXy++W6k3vHqjX2qUvHJjjmtJ97YWcZgDv1n2SpTRVT/foL+bXrOWr1Tz
# DATA vp8vUfjVX75X8SnsRrVfK+f9Yt1r1D2/VM9X6ZZKvkyvb+ZL1Xy5Plcm1bDe6izyAcsU7fqnfrWYrxa9UsP3ipNKueEV9+uNtyvl
# DATA bBi1dqNTLy2G0ah41Urx03ypWM83KFKlSt6nvKAYVRHTfKN+DFnTRG6Bo+c35HXtaIzZUpuLv8aR8NpctL7U3LGACjPx7VQblUrl
# DATA FLQ8rr+alidNwaLltWrVsOxvQMurdcIMLS+sd6rNVkrLq3ZrsK0NLa/cqjRKKS2vUa/4fnjhtDyu9vn1hgF79+d801RUOHv5uRWA
# DATA tg0y7DRJ9CLOTeXrov8Pf6iF3zxuDWG5sbMK/mbF8ngKnw3ZkwdPBtmrLEL20mBOANnTDsiVeWTntMpQhbFT9c/2GJXYTmNjwAxi
# DATA K7YR6LFbLXAVV7Pv0nzN2Vm1xpw4JicM0c7B5xx8zsHnHHzOweccfM7B5xx8zsHnHHzOweccfO4lgs9x2nAaIa9tHkrja+sGNEYQ
# DATA SQ6x3NDS/tQz9DH0Bv3dW9v9Bb6TSvGO7sheo2CefCzTml94+LBzrZ+tZFzzdwqfxNGQAviI/gMf6qYxLz/a0sfO07gUJk+Qrx9t
# DATA vbFwIl0FcA2fNSnqjtmhoEPV4CfNVnIK4e5g9ZqD1e5A9UtyoPqkeuHP9qA1+yVTV9oijqif0cLci+MOzhZ77Cc0x2yZJIFA1uhs
# DATA P+vz2c/DGUX++5y12pcdJD9v1fbl5/KX6rdvcEw+9dMa/fBQBOpQ2lp2UlUOozHzMKQoJPEghBAMH62VqsYn4JX7jYksohuYPV+e
# DATA nhzPQQaZbM20sfOcEXqm8ADH3S4c0/pAs+geInCpavyK+cPnJxERX6gmciA3SK2TZyNW8yxOs5rnnUHlDKolanRphXKCNU6w5rR2
# DATA 1Ep77WKEbLhP182ALCnRrmANjF48iffGwahniYo/M920cwBY0rj8hpKhsUavE2oWizGAQM5RsFiN/XowHwQjzhxrzF+mfHsuqsUf
# DATA sry39I1UG6GQgp7vAoSL34Stzi8aeuETykcvGZ67fDCLFr8zTKb9YCLq5YcqeQdI6Ig68a5H/V2/fxGyxVPWVJpo7syUNcDnWsP5
# DATA vrcqytOQ+O54IkKvxzka/s73XUx/vBeOE5ZiwkoV8+1FFobZRvkgIgN+OqIGGZ6zGnU97UTnLGgqzgA8WGGAiMF9zhLRc6zJdFom
# DATA QWYdk/SQ1gryBofG/JDexuAoUwCkrahuloNSRXlMDuz6o5rQYao+JQOanDhKVkhLtQFY1LpSli4VVIFYXMp7AIHvcOgxeGXYpoLS
# DATA 8lNdRT2gvM8ZhaxY9c5a0hQLT4daK4lnRONpqwWRfC4XZhKjmsR9xhfLOCAaR+MphLw8nWlGx0u5N0N5gVnsDpRu6maoxxdn+mEZ
# DATA FG4C4iYgCxOQrIXppiBuCpKdgqycWDxrLU3F62CmRS8YMWw4wAzDFsdOQqW7p6Ug58QiGbWj1SEV+iiUyYyl8zixBSAxVvYPwE+a
# DATA Ci5kXuJRWuyUmjL1XVQK++ESpcdN1TY5taNbb/LSZhrv1mE6O2Lucmsa9TtGi09Fhh2Ni25jdXjUAtBr9Las9jOwCp+UhaUsIP1j
# DATA Cs82V1hFoMesGO7ZZHFWdq/Q0G0lJQsBV+81WwhglarPr8rGCPVy6w7Ts9pPvRpzD5safliDxxhLzUbdx7ZlrBy587fTBFUdZniL
# DATA P62+s92PBi2OKD6svo865hibsujOu/Ixvfe6pO3WHKZc25qyGm+bmhhR1hiamdLFZmBp9uqMdGo5B+OOmZ7y5geZqKp8zObDHJiL
# DATA d1Kb7kB2FsjEdsq3V7zHA5OM+XibTIVyZPnW/YhZTZ2QYULUWsviJRjEyaR/qOCX+AlWopFi57Ua4XVFw4kMgaHIYWKXZNKLlZ5o
# DATA INBzLR7LQPGhkZqllsvTYu3eVlKYHiwzZR2qg1qXm4G1E2TghzQn7rPvPhq3abqYZiHmqNQxAMVld3RqlgNPCXULn6gtOtST3eFV
# DATA AraNeW8lzPZB3MIj1PuFUqepKB4nsmimKGBcFueRXVYrOWF+Ndfml2lykmEfQPKT2sVeaLIK3gS+J5tHBsElGVnwPqQxM+exSl5E
# DATA Rtih8j8piBh150KJk90q4g7TnHkaNhjjFnbOI6tMx3PCjKqvzSjVi0k2vQ0/jpjz0dCqVfxqqhAHFMuEHTHBuK9WT7VvBk4EbIML
# DATA oFUrK108zcbP8P7tHab+whBLgNiTL+RcAMe4z+N2CEldRlfwTc+0TVZP0CbfBYgOfRq1uzwlOi+QK1Pb7MvU3IRapzLSWnkLg+QQ
# DATA i3uaCEePkM0v0sOcn2KLJMB4WTPyZ1nB/NLmNezdmIqYxsh+eMhugrSO9emX1MJR3l1x+NHslpoge+JSYw0ZQj08O6z0IqpaFBVr
# DATA C+rAOJETqzpK1oq4oEAjHEftpfmWHYhlb509EJsrkg233o/1LjitPM0mmNqdBqeIKklFidb5XTiOIfaiOCBSltgonADNa6PE/ruA
# DATA xLzZH2dPPcZ6gf71l6P/Mns6+8vsm0WM2P8z+3r2bX72ZwDAjn4NANlfgQs7+pKu/2H2Hf39O/r7+9nvZ997R19J6Aj6G0DHns7+
# DATA fPSb2bdHX9G/v8WbwCKjN1MYTymEpxpM9pfZU0cTew4o0ENZ+cE+nrZSqU8p0KMwHjG/kQHrPLRT2xMDsRND+Zy9jRhoLJe0EsPl
# DATA u9BHp8Lq/AbqQSKRkGfn8Vqq2Fswl5jdPjx0ODHbh6I6gsumiWUL5GIxYtHQWsO9q2up/mWRJTac4BCg6WPxVUa6cHyePLFgIoiC
# DATA XpDQcAoLlizduNt1OLFNS+3cmWJ3gn4bq46hLIAdpoDqYMA77XkJpM/rJF4XUwmPuXAs92dWOUDSHQxCnvxiLOF1xOiXIdM3vE4U
# DATA TpZgxI6tdKutk0xbenYMsWNT4DhibnQ/j9Fd88ROPKi/FIsilzWgn/N4vvFiyIlG80sazKVG2nmQbrd69k3nIlBidlrFMax2cPRi
# DATA eg6LD9mEIgUmlrqwsEi0JunvgMHeHyVCVeKkTYLksdqrgghEQ5wcwzE+lSWbocQAMJKheh+8LgVr6qRkJ6k2Mqy3tU0A+FSMjXaw
# DATA CbC2FZGBsMQumEJ3IZossweUNcDgI9gBWL1KHlNgJh4RnONcm6h+9bFLG3vIppNxJGUWD9vheJg4jpjjiDmO2AVzxDYaaTY8gbGh
# DATA cXxpRv7pfI/nYOI7mpijiTmamKOJOZqYo4k5mpijiTmamKOJOZqYo4k5mpijiTmamKOJOZqYo4k5mpijiTmamKOJOZqYo4k5mpij
# DATA iTmamKOJXR2aWLtaWiRdbUoT63YrYeM5oonZy84nxYj51bJXbtY/zZeLeZ/yp17O+9VaP18BVsv/1PfL+arnV0qeXyx59VK+7uEu
# DATA 3OE3gAHLZl2n22zWuwuEMQC+KsWmV6J3VOpepZlv0oWS16ghyKpXBcbL8xF2E68rN7PBVmuNTqO7BMxVLlpgrlKzasBcfjFbH1qV
# DATA eiVcEkC1YgVQtshejcUqUVlGBivVT/q8lS/lct0rUz6Uql4jT3/5/qBU8SmPPGRukbN4dULsUqQ7K9Vqr1pvzJHOzAMLpLPaKThl
# DATA 3DIMp4wbmcUpo3pUrwcbcMqCbjnDKeuWOvV2zeKUNWvdesop6zTalVYl5ZSVGrVyrX7hnLJRODmWUobxRd+3AebLcpSV2U1WaPDy
# DATA GIa0nUUSmAlZY84yM91K9Sdelf6Uqux0zKC5JEclBBXhzZxqKlXGsVYy0925t5cq7AtkN96cbSOepzUIL52uXCZ+a4bwzG3aBeaQ
# DATA XQ7Z5ZBdDtnlkF0O2eWQXQ7Z5ZBdDtnlkF0O2fWSIbuUxWFxuDrBYbL7XjDpFbr9mCY2MPs+2sJhLEr9T2HSXFfX+HwULspXmmbB
# DATA UKVWw9bnR1u3RzTBewIXZdg/pNy4hqCvUa50pyIXxsfDupbOlTprxatIIGUBqaUPcwXqcBY0yBCkHLsJ+JA2DqiYM1ii9+coW+7Y
# DATA 8UmPHbvjxi/qcePT4LWuwDFkdt9pf9d6ypYIWJl4Lz2qvISvdVUOLz9XZ/guAriVPW59zqStucpwWsSW5UhND5GrnE6xIJBnFAF5
# DATA pbrC2dUr33qTJ/isK6d16Lj6QCh0qPTm5CCsqT4HAT3Rig9w2jncm/Yh36dl5waQE427UMPvTMdcQYPxQEvfqzPx/G4dgdtkW0dk
# DATA /PK2WR0FTQmj7OlikbTFWpwT+Ik83pwilgmWWvucNujZcVvAicpWiBd3yCabjltGePIlOeppheHsKmdXrRFrsyuX03Vxui4nNajW
# DATA 4LYuRu/lb4fxAbp/URxoBXuisQbJDTWw+ZcvJ3YOdC1egVA7QPS1jDY8T/Tp6s+G0FsIlQyLcYt524/3duZIQENeB0pBOyoI003p
# DATA 7xkcEiWaumToyQwilrctFtBnU88iW3LEOMJezvTHFXL24ocA0McWbBlhiysN9tvHxlc/n/ar+kIK4WoUl8XZjjG269hRXhNh9pQw
# DATA pQnu6lTHBhl1TFzVoyaq+nsGF7Y2nv6aWM4RlNT6ElqrcrqIGjlXdYuShEp161XZa6riqdYYbS3f9JL0LtG+pIDGX8VsvS5BnI0C
# DATA ZTGbrPZtCx8pfXqFeAnQ7I0+4F24nuwGzA2atVLCJ5GouPBwhx5Hu6A+nVIvBK3yZLq3F7IHGsAIXplQHUQ8BsYCUCVWlcYozIEO
# DATA AajoaxqXMNDYN67aHQRUyJSfsj+eigZ6MFAIDvYMIxYKVDBOExnJO1GXpVMmoj/Eys6e2sobmviIHD2kiTgaS9SJUkkillWGpxGR
# DATA 8YIR1TkMcJuynV4QYzczgjlz15m7K83dBdPGWbzO4l1twl4RhcM7rL4HzeIuBployDJmy/lOmi+bSgGOw0HEiI7cKtW9N4UpuDDc
# DATA sLDZ3jTqAGeYDowUGrXXzhQAQh7e5k3gLDRhQeDQ3EfjumGaat8TD/U/Y04AxrNxTENHMNFjLtvhA2rgU5hQyg4I9sahxlcuDplK
# DATA /5BC6tBQbZIDV9XCwMnSgBCXYc9RyJpwXjBBhaYI37Sp7ZoMGT7h7VF4RwSoAeX6ihmBSLzF+7y/STE4NT93pBle2MgpoJAn4bgd
# DATA Yb9jBoIqGc4Fw6J9llCh8pIVvLfA2eJulL1pDO3qwebiuxhgAmIl3HXvhhPuZzkZMG2CyZy/DQfXTGQ9PtwA9sm6NN7WcpSmv9eJ
# DATA /BCzNs3eUX0/VCZzormnwUR4BOuPVND9JMd0jMRQO7XRJWbS+wgMPeUhTDC10ZJHljEPSS1Y2mEnagdSggqfiaxcqOkW5ix8QmNe
# DATA /3BdKt/nI8XG/GJ8iU7nbd7pqQ6JTMc5eJJZYXygi5+nj4qUEwF+oszXIZT4lPinxUjjJGWVKgvegzB8zJQQuGWZ54G85FtVtdCK
# DATA lRm+DPtPhRsCtUU4iLWjOEh4UhvsDeMkShbIHGyIHafz/TCmjonzM+2CuNWcmBTNPm09Bp0LJ9pyc6vGAPc2O7EvgAz9Hqqv3gdD
# DATA zTVA1RX9dz1NuQBK9J2Msxxtlspb6LIXQIp+N5rwrGxM3RaEIAUKqZg13HOKwOQFwKLv9eWd6CA5tWnj4mlW5wJA0bepA9ItHr1U
# DATA x+jrcpHCWzTunDM7+UWfv1lcHHpqkthYnH8FBGf23ezp0a9n3x398+xr7+gLIGro69d0+Zuj3y6Scf6NUTf/zlCb7N2zPzElx6Of
# DATA vpz9bvb10T+pUP4ruDh07fujv8cT9Krf0i9/oRf+yTv6hwxpx4LpODTOc0AWZjCb0a4VRhY8v0B65GQbqnCBu9xtHQDKfaAsqr2Q
# DATA FYMfw+EsOOGJZiUyZJQHUTAE9/rrCTjvhkGX3+LwN5k5Jrf3y6bfWIVxcegbSVraLXLd6fI8bP5WjBzmRp7qjXuHk97gPHE3vMmW
# DATA pj091PgOzwiA3OOtmLjdYW+OLbFz591gkhu3MMfkeqY91tgpoqbD3L/0g/FALU2lk88oEVf0wh5q0U9n21bmElRa1IthWkemCxzc
# DATA C/ib9fVvtfGRtqNnhb1ZH3NHvHGD9gkGbQ22OdlY/XL4gi9nnD7PYXqjUXrzQfrix2ipfibRZkC+vLZwEaQakx4hJCfzCdH7L9JN
# DATA DGxP9OKBhsFYZSIzXRrQMNgFHU4oU9ANkSJRjOV2PB0LmyIdX3XC5Sg7vQR5xcFvxq1RU/zMGBwY57oevc24ndCNnWk/1FsieQkL
# DATA XkUvGYXtKExyJv4pu1g5WvuRuF5D6myDbjg5zLgCVToYp8uYaEYBtyVR2QQ5QI0D1DhAzfkDao4fODaac2xiv16O/X0a8/us1reD
# DATA 0TgYjYPROBiNg9E4GI2D0TgYjYPROBiNg9E4GI2D0TgYjYPROBiNg9E4GI2D0TgYjYPROBiNg9E4GI2D0TgYjYPROBjN1YHRlCth
# DATA uXNaGI3frT5XMBqz3HxSEk251PDKlWKP8TOliudXym+Xq6VsdrS7jWJ1kX9SoQSUK/Wf+6XyPP+kUm1XGsv4J1xK2WDKzaZXqpT+
# DATA k98seaVSkf7Uvab/qV9teA3Pr5c8v+rTu8peqVn+tOTX8n6ZyhDEnErer9EtefpGN1XoJp8eqPynUpMeLXllCqHc+NSHF7niVeie
# DATA ci2TrkrYaNaKi4AYiVCeTPi87zcGfoXyBS+qFYHnmUtru9lpBu1laVXoGSrFiMwPxa6pFKspu6bSLFoVuCJfDpfU5k47rLW7p2DH
# DATA cEU27BhuExY7plKqB9XyseyYVrfTrWXYMRSfRrtlsWPKtSYHJOwY6iSaQWixY6rVVrly4eyYPrWCY+ExcBp9nt5qKC8Wx0WlbtGx
# DATA x869Ev3b+IltbtfZfEiDPB5JY/NmeLOd7C1eFgvjuiosWT8lC8vDUqVXkz+Z0Dxl0RigDI+ipvfPkGukiOdSTGHCMvKq8se4RiXZ
# DATA DRhXtj/Ht9Z4VBB1yjCf/qh/tYXJ1isPiCtpNRuUZTbrsnPspRmxMiAHtXFQGwe1cVAbB7VxUBsHtXFQGwe1cVAbB7VxUJuXDGqj
# DATA DUIt7bO189q60YzhN7rX51MX6rEc+sClXaunUmZVqt1bke69dtkk3rmJdv7R1p1UzQuHVSw5lyHlsNJ0wfQ1y6wxJx/cuWF3btg6
# DATA +eJOD7vTw8edHl6pNXkhp4pfR82F0lwauDlZ/Ez1J85BLx1ac3jzQRg+5hOO0mZPqTWXji3npzYXhn2lyt2SVRLKEK0+qBzdFyA7
# DATA p88bK3DbiEq1M4b2nEdzpLB/eAGac+8Mcah5Ij1sopSyYS93U4HqCxCfe8iuL5VGMkFUb051gsaOPNSvOxegO3dfjhLDB0imnEqy
# DATA gQtcSLmy9tz7OGsdGAE6tDwZ4WCykHmJvVDTcXjO6nPKA2Ok41NNxowyQHq4VSfEnJqlDEMXMMn0IJZEfSoKLxLwkFCdO6zPvVEh
# DATA VdfsjA91RqeohqB/AG7hIGQJedyChSoyNPr9gvdu1DXNIQfcQ3+xLSoV1SGiMvZ69OM4xIJV/1Ce5O7lIEgkOpoopNRquQ6Kyjsa
# DATA G7y5ol1Nkwosse+rAKh1UDSlvvTgGxyrE/HQyaRHuzSkrJIM0Lmij/tTNznEyXfeZkDjCUsB0Eg9L/EzN1LdD3EcUJ3ilkmr3CHj
# DATA zvGy8c/5yWOHnHT2e2q/O4v9hbPYT4qUfIY6QLyYbxai13Mk34xY/lzBUSB6PvR4L+8aiOQlywddeTmNi+BDpiJH5w2HtOWgTkuG
# DATA tDYp6GnTfRyrMtVBJn4snKKEp0pzBYldDVKKancjiI2vj+Vh0ACwhU5DG297/ekgGsZTmiIam2hIlTyGiM0o7Pch7Y4xtKcU18n+
# DATA Gha8D1oit0+GCTZdQ0upRyapwhwwz0a/3Y7GWzDQ+C5OjI7F+7CLKAiKHVVeqjWW2cUmH58fCXkbwmECLfUgYQl1aSFa43kACevx
# DATA uvezG9rLvPstaUEJmZcJL0UXvPfiZKLtPxEXYvaPjvVNZJC0L7CXoHxD/TVsAwjbUzdCVZ1lQ+Zj8qKLxFg9g7PVnK1mjwzO2fry
# DATA OltXMyefpYTje7xYqeuzEmDjo9cWlBLSegxH2Id2m7Sf1HmTYzcCAybZiaYdhwXvXioGiFM4otJm0D5chuw0CCz9QPZpsu+gG7W9
# DATA hKb7beNZafFWslQzUDQXN9SA5BSL4yNt/LLWh5gMg/FY84T4cAneA6/PEiNRnXFcpF2qdW5UUv6k/GTKk6V/TIGI5grnOLAjIYcj
# DATA Tyv3U9zvWylYSoA0i+dcTeTzq7IlQL3cusN0lPZTr8bcYabuO6w+Y8Ts9/XSaAR/aKysufnbyW7gVhUfrL5nj80eRmbxp9V3tthO
# DATA Y43ssVgp+s7rkqo0H2Q81t5CWYG2/XwYGta4CtfajJbnMxh3jBOeF/zFHa9y0MqBOZAU7ww2rV+W0rkKjaecE7dNAuZjLHk5YoPt
# DATA DkQcozGETFHvU7MV9lpeaXLmRGI0j5mZ1iClYWwQd0L2409gz8Lw0xacoJRsZyIckEaqM2ShIW1kT7xf0oBbsP2rG/pSPbNNji2N
# DATA bFJM1mgJMwBesdzNjYiesZyu87bsiYonrXwnLKEHq0tIV2MppAcj9sFmS4iaMXck4nEH9gVamT2yf8QNGnhS15XVb7EDzRoInpdV
# DATA EJFajaE+iikHShc7GJWVcvaysVNw9Qvm3qYFcy8Y91lUNugPdME8iLsMYx3SqMaaqQeY5NEIupedmxW82/txhJkx5b1x6+ds1zeX
# DATA yoj6F0zOOmqWiOnhmcvDjvillUfa956wPP5mdXnoXlzK42/IYFnoyKbt9rTParJYBFQnCVXj0JNVxdKjXopXEnAem4aMgvc2ta7D
# DATA HBUhmSFx1BeV4wH3YvFgIPLPZFwMhCVGP0XIQbNefPaCSlN09Yvp/qbFdH/aas33Z6+ziLXqzcLhJ/Fh2oNpMa6C92FE093OlDr6
# DATA PVmKMvLJelUotfDA1Ka8agdToeOduSzsaF/9TuzNTTux16Nxh3cMDOEAosYxtBpPTxSve9NB1MljoZAlxlV58KiTsGEPaaEJLPMP
# DATA A82lTtf5bd4eStj0dhQSGU9q2wS0kOEeOnM5LSboVKWVtf9kG6Nt/5krkve33o/1hkOtwS0mv1jcvPTPUMuAZizIDl3KauH0Ypho
# DATA z7XHK2WhJb04zKDQ/q/Zvx99Nfvd0W/AKgPGjD5/Oft69ofZd/T37xiP9iePYWffzP589JtFMNq/Mkbt6ezP9OzvPfqLA5x9k6MQ
# DATA Z3+kb4w+o/99P/vavMQmqdFNf5l9jU+Ko/YHUNHwfnnv97O/Hv2zo6I9B1Bus82Bt7zGkwONXTVkbogXC3k1xzMj3mYVwsTTLABA
# DATA Q+FOYBkZ6gAEzoAOdAS6gSK6Uj0eT3jPGJ7ryhKWcQrA07GWnAZleTQFsfMdPs329XEXcdn0tPkCuTiEGo0WQT/eSxFfvMOQXz7P
# DATA 4b7ejdJu+s1oYuE7zo+hBlNandtADY1lBOdscPi040vr3Plp7wkG3GuRcYEdXTTv79G4Y6aXOW1kJTEOQyEjYcgimeju1J5WzG8U
# DATA afwJVFLCtHNina8c2VSyHDkO2bPIhFl9TGBARSR4DQxWkwW22vp6udqImWtlzwqwtj76DrDmxv9zHv81hO0Uw/5Lsbx3OUP+uY/4
# DATA Gw34JxjvL364l4qYTboZ5a9W87kIbls24TxIcoYY6JhJdesQIeXkDON4Kq+SuE4E6JQMAix8maU3T/qlVpjApRWOsTTJiaaBOj22
# DATA oKLXibqG7UbJPvQUyWRDZttYmWu8rQZHVsigYL9E2H6MsUmhybiOCfeKTw3zTiChzUUJ76FKJkLj4qXZMJmIqYB8SS2Hm4piBnrW
# DATA ZEohDILhtIvPY9tIUJ5X+AnYphkf5uOhQ7Y5ZJtDtl0gsm2D0WWjic4mJvEl2vWnMevPatU7cJsDtzlwmwO3OXCbA7c5cJsDtzlw
# DATA mwO3OXCbA7c5cJsDtzlwmwO3OXCbA7c5cJsDtzlwmwO3OXCbA7c5cJsDtzlwmwO3XRlwm18tt8vF04Lbqt1a2H2OwG3ZNeeT0tvI
# DATA VvXKlcantWq+XPMa5bxfLvXpn1LJa1Q9v0i/lD2/RJ9q+VK5X2t61ZrXLHql+qflCl31ylWvUnrb95uf5hv5ct0r+fnqXJaGzW6p
# DATA 05qDnvn1Sq1cWQY9ay6WXKnoVYrVXrVe2i/X3qav2ReYsLIUthKloFSrenU/7zcG+UrdqzS8ejHv1+lLxavUvFqDvmwcMb+8ELOq
# DATA D0hc/dN8mQo1j7yovUcBILb9Ml3I0OJ4J2f2ZWG3XluBuVMVuB2N+YTdE6n0pRT95tcZJMeqBrVsCzDBUgAwbDx5uois9eThRiNb
# DATA 7btd/q77X5ZDZfHXcoPqDYVxQmwcNyONjZMWaWHjwmqjUq1msXF0U6VUy2Dj5kBygo1rdpopNq7SrlWr9RQb12m3W90UG9fslJvF
# DATA 8MKxcWh/x2PjytooEJNAP7OCH4dkzvkXqz/xKvSnTH9q1Z/YQczx4t4Z0FRiksNWYMTXe58VO+irHXN7mlQtFm/OO/PE3ZNr7B/k
# DATA eJVsxYqYigbgVaPPNl0qKFSsvPDK42wwnt5PkTFIzHwJu6q1i097ObNMO5VJJfrjV7XJz76iaEIWVjsDstM+bOqXSwv4ueJqvpzJ
# DATA /ZydA2tMkWMSyFaC48g5jpzjyDmOnOPIOY6c48g5jpzjyDmOnOPIOY7cS8aRUxZHtgOIhhT+Luy9j7akzVHCr8l3KMJwNrCJ+dHW
# DATA w2AMFVp+xJOb0byu8QWqFm9iM922v3ONcqM9KHxE/w1vW6fE7/4sewyPH34vmPQKPEPf5nB+6heqCCE93rfk0HiqfAspLtPta9Rc
# DATA emzFHaJ2h6g3OURtH21yZ6ndWeo1esnP9oy1HA3O6bO+S05a3zfnAqWO5LLKauZQrxxYVYIsfJYYdvSB0mGWk7whq+ynhydHwSEm
# DATA 03J4ElorQ+vk5MYayG+K6nFLGFEdEKjw6sB06OgInO7xJrrH7SCZBko2DZ9W34kulbIWt34oH1ffSx1sJ445oz+Qj8+DAnKaFycU
# DATA QbyzWgRR56qIIJJRNj7sQIcoGO4HSaqAiJOT1LygIN6O2W0yHY1w7hkbDXAYzRuLLGQCPIccZmcvGDW1sOBRq45wdHhOR4fHw874
# DATA MOeFQXLIDeXsuodzabg0iUqr/p2fYqipyUqnGrbDeAozMi2b9jTpUc0NWSQXZ9DlCHUgctVs5qRGBKxK2CWCYUBB9cC9QxeRKlMr
# DATA PQc+Hj5F/YC/tKWZJ2dSp04T8BwUzIcbF8x9qup5uFUOoQFuKYfyweYclcgo5NbDzUY3EAbJoOCoP0LD0bqhOEcIxSoohocjtg2R
# DATA 4ZaahggOYG1Lxreo34unLD16dn3XTFIurZRO3bm9u2nn9l6EnTPQ8JiOLWVkmqDQnA+7AifxSDedbjQeQJx0OvJUwcRjlmDjX0W9
# DATA 5IASNY5b0t2NQ3xl3bDpsEdGFdQNbBmPsxRJJuaXViLWIHnCInm4ukjMcCtl8nAcRH3RSwnIrDGFQt8nME5gv8WSwx2a9sDIQ9U0
# DATA NMxxoJqD0qwGTFgrzaRKEqnYm4iw9A9F7e3MBZON/tVvKw82bSsfypyUJqjRiKqwKRjUbljONHWXLUIwrHkY5+koVD1GCY/3mOaD
# DATA R4uNuQqZlYhmuBIJn7CoNUoXntMzF8VcjF9ereMXQU5EP+68W867tYl3y65izrvlvFsbe7FWOsEuxrvFwlsGgBd4e3Esonjat3Vl
# DATA 9WvX+b5wpMGzPWALTi2hm2LDiNqHrK9lvE1qeYbRTEPsv+eJqloo3W4PdpTbSzdMmZSiFCVU87zpytIrxvVT4t21Y/Tc6MUGERtI
# DATA Jd5WPQh4y6veyBuOeOt1wV/tIOMVJNTyWJXryKiWZf1k6kYTM/3ggmvKV4Re2D2dG57vtQer/Vh+ocoOBAosCsd0d6GauX/Bl6Us
# DATA LOMolE03FMRdLV8418taZhLKj6LAh4t0qmT3lW26pJekiUdino1oPJzIhvTrEsQZDSAxUjAYWe3NVrN8OBb3qxBj0Q8sqET3Wa9x
# DATA qL20OZkxsA3HXpFgL4hk1xW2xAtGimYPBc9A7tJ6WvC40HI8+FlAFhavTIOEXmWirWO8DtbUKBoKxgphkkVsJAixoMgKajg0BknH
# DATA 1qE0TxHmC6BAaa8iJtM98Gt5p0C6hqmmrUMtQcl6lans5JQt1EPPbBfQe+JGbMNovCyy+oU3PNOhxpmezvTcxPR0tuaLa2uutA6v
# DATA oFo1n+gwpwsWzbC+ZYa+BbOTYwUK+TiUZcJEW6HpQyy7xJ3v1VO3vvqSr/y3nNO59Sr1oPMNSx8LRLjmCFdDTvhZZxblQtDnb/Mi
# DATA 3PPH9aSZtmNMFuRdh8O2mN9G/+rWBwun/XgHHxXigri59RR/4bRsICyeHlvR9tgcHPwgOOTpC/ScjWF2h5fsZHI0NIuC8CfuUUij
# DATA Q1lelLkTaISjYJ/nLgXvPi9nTbQFpe5R9hlqJVzG4oxjg2d+rSvAejhZaZrWsVElmK9Md5+M+gg1iZ5g67osQ0r1vnS4x6UbTymm
# DATA jCrUftjfm1J3YcPK/u3oq6NfM5YMBLFv+POfgS5jbNjvQRTDL0dfLVLK/nfz45ezb2ffAEX2V77w+6OvZn/GpZw3++PsKaPIfo3v
# DATA uIFfd/SP9Acgst/R6wAy+4Z+fsoos28pgO/w29EXFMy3gJUdfeFRGE/pwj/iItBojl32XFiHSBtPveAPYblyXXtvgEgajB9jlS8Y
# DATA hjm4PWhWOua54yiQ6Q8GGZqh4qg0ryFBL8ObDjkw1iafRn1mo1KLDng3J00sg4lAUkNs1afObC21TGDSoQyUDlpm24pWh3HZ6LK5
# DATA Urk4clknknOYibnzDXWFK+oCvQzjnrmTKp3UxPE5w8t4nh8lvAEBzYF3humoOoLZZqV27hQz3dl0I34u6ItTKWn3ws5Uton0hR0P
# DATA yQ8GOXMv5rHaq+dX84NoCFs76FPlxj6Sm9rTy+gMscLGIQUsIIVoiC5YzEBlGUmb7Bt886ZVc7WJk21qzwpftjbyjl7mLIBzswA0
# DATA t+zkA/9L4SC6zEH/vMf8jYb8E474Fz7gS33MJN6ml12J5nMR3LJMir1Q5uiJeKSYwu3F3ey+Pc6GSY9iucfrJmh0EfZpGsuIEUeD
# DATA YMQJl9eij5JzA1Q7QV3CUotGJsl+TR5xpd57Rpwt2RBbxjmnKoVH2THF62TABxBE3GUH2jCgIkgQS6+DAz94+eNhfCCnIzpqcymw
# DATA UaOQi7oXT8dgfzGDKmpFfWQVrDsGrdB4xLgpGAuigcB4LnOGQIGchvFy+JTjmDmOmeOYXSDHbMORZqMpzwb28eWZ+Kex8M9o4DuQ
# DATA mQOZOZCZA5k5kJkDmTmQmQOZOZCZA5k5kJkDmTmQmQOZOZCZA5k5kJkDmTmQmQOZOZCZA5k5kJkDmTmQmQOZOZCZA5ldGZBZqVGp
# DATA 1kunBZl1u0G3+ByBzDIrziflmNUoT4qVXq3W2C83K2/X5hFkpbDW7i7mZNGnrKz0qo06fy4DMqY+Vyhj+XOj4fmUw+VKceA3inn6
# DATA V3329ec5qBflfKdbWgb1KjUWolCqUhSKpU/9etHzfSDYvJJfnPhwGzeOw4fVq0G9vfRN1doCDs2vV8El88qlfLPi+bUKIGh+lTLO
# DATA LzP5rdI85nXtcq21nFZmQdTymA4EEOiXGu01l4DMKC4pyIwiZUBmgmNLW0Cl3K2XNs7f2pJXlYr19FVl37/AV5WFyCavKtXqF/iq
# DATA aslOVaN4ga+qMYpOp6p8zhl4Iqgcd2kaKie9owWVq5Rq5UYnC5WbR8gthcqFfljvVFOoXLVTCxtlA5Vr19ph24LKlem9jdqFQ+Vk
# DATA d2Felhn0MFfmGYSnV6eM7dIQ889+Zh4K91ZInXkU5Bbpb5Vl9Df4P+v7B7ma+D9VyINgM8hbob7OramnZ2mg8wsktnmvy2fBs6lK
# DATA JhMOi1uscH39uNWgDqyTdXqdzA7z2F2LparVYDgrq9bYcwtxzk6LLtA6dIw5x5hzjDnHmHOMOceYc4w5x5hzjDnHmHOMOceYe8kY
# DATA c6gL0YRm+OMAWuxUwW4a7Nzurc/MnGSU7HI9kV6Kzy/j6sdWy5eGv3vLNPuou/1DflQ13J3PFJdOKxdBDFXOfDHiaMRdtRiXNz+X
# DATA V3emsva8awf0U8Hd4VKKwGMunSzp2Pfm/Z2f+tVrfhXR0aHdkgBaU5ovolBNzFhulhVoh2HYScC7088AkicyBInRXuqGB9KBjORU
# DATA noh90SU+wZhJDjIapxh3tVk/xoslq2TxaZsndDsFWXzY3g5y+7mICiG4pgzt/Z2fbkfUNIqv1Yo3/J1cEZu+uNVj/Wl3sHtre3Br
# DATA 169Uiq99tPU+VUk+YsmhIoOU4cP51O3HNGcdXK8Vd35SquzQDKzDelbbpdxHW0XczY/pZwY/oRsXb7qZ1hzJctSA7YRjraoOnEe7
# DATA HL9tpJ5Rg//xxb8gY5ObuHJtd1lhbkevZgvxNb96o6hzk0O9+flO4ZM4GtKzDC6USKuP15a8shsNo6SnRFH9qi5MnJYVh4sAEH82
# DATA hMqE4ADwPEMPt+cqTF7Xih27WlDj4XpksmWHInmTC5xKIq9nFfT8a+tMRm55aDxpOJ9hHCRjSB061soZWtxCh6zZirrSmXkXBa7P
# DATA QxcmT9DPWHGUsB/oMPVDNOAiLINp1AfRnFKEU4pYrxRhHVN0ehFOL+LEehErdUovREfi3nSSNgDetaU1PWVkN6ISV1HG6DJ07MVY
# DATA ERn3sVgxc8r1uJTq1uv7TedlLhih92LzhlowV8L1K/To1YDLivQTnCxnHpIR9t5WI+9xSvomGBOl9EqqpF8pLpPSL9tS+vVS0dbS
# DATA 96urpfQtgwbR54jTxIRmVVytsnL6mZutfLODWFDL55jdKhe1/bFaV7/C8axUj7+zxmHWloS5oL2vDzBSuvkg4i1lFAszCC2HbpVf
# DATA VM6kTChMGjhN2XLTjo/5TMiU03vpeMZDoUxAblmX5wrkfF57H+Mmt3j7renVi3mpHHz0aKAdUzeReXP2pxTvmZbLSjqC9GQKE/D8
# DATA IhHehX9PpG6UsaIteVs5w2jMdGhCZ9n9mU6ezSAIf2RuUQK8VIVZewaSM6ynwXADFnPQDIJVGjRZ0RmbCrbI/1rOCZMMzMwfMBLq
# DATA FQr2bekhyIaAHcs3eP7FLbIWhpuXuHnJMfOSjP3ppiZuanL8jOOZStxhjEcF15FA5vRTlbs3zUREgAes+WTaGpVekLDIFQSnWHPM
# DATA iFDlRDltEIjj0gihabGG+cnFHHoB22xs7LfwaG0DTPiaH4rwXCiEWbhK0b4pMVShEzOlYUYXZU/y6RTR3OPfpskhjblDZnpRAqWz
# DATA yCkIkUyP9EDLQHruLpLHOtBRL57Ee+NgxEP1KIQhreR9ozFLj0kSs8PeJGCs8nvxWJR11Vg3DzcVRLJl+UlqxRyxcGjckaFvO1AY
# DATA ZGwTVB2b+O6xOnUAFDn04W4LP02wEr3AxovCQw7CAEutwbe3LvZRh626tZGfNx4lBQYpIBDhxBCEoeI/MaDnNgvCKfyF1iROlfWE
# DATA ZZvV3lPF0kKXLXwCq9cOpP6uSdNt7LAfxiC3zidLzIQsN3ZBVdFUZDIL78G9r96MfCWzrQeCr0I2SBbwDwD2IvJYS26zbBuMmhwq
# DATA 0VCSAuYdvLfxNFH5oQKOKB9u78dRhyWpWaUNAAXJUhqgYibGDiC1NuKTbrw7ZfmUnmP9t0ITUQ5wmZTpOGNBPSNcHXdlFgYdusEg
# DATA 7kjjRuHxZVNWnj48F3e78KnrstMa1lKGOW80bZGFYj3H+nPcCIMOLCBvzHVYKiuNXQwv5ld6ILHToEOWdkJtcl0SHwANruBeEwwi
# DATA VhJBKJMXUs8QQduLujtK64ie7077/UPFW1ExZTdOwhVV0j3IkApZWVD6hINerNQRqYPETlAq4nEP7VAKDH38PKJWDNMXz552tDBn
# DATA S2+sBu1M5xfadD4pK+wZq0Pbe/7Xw8IeYiTQsEs2qqS+r6eFXR016edCUvU4gkS671+zvM4TKpZVyD5vpti84vhSpJhyv7GaNwqV
# DATA d6GRESQ1IhGzJu7b7tBwpDuxW++zdolwxWiqwvrEMmmi99HvuOfNKLWc0XtAMnsIu1xoZFRv0ntlZgKbVnanx7DwIkiRHaqbrsf9
# DATA Vc1T7GXYuai+PLUIljkY12JC4Io1JOcF/XFYYCxDPBqjRiehaWai4ByY6apssyHDfoC7yM7NeFvJ5oZosa2FzpY2TyElp6YsSq4N
# DATA 3IV1tgVb70Wz8lKs2UHYUuLXNtXsf5t9Pfv3/NHfz75nytg3s+9mv2e6GH06+rujL2ZPbcLY0Ve4sgg4+79xefY7evhrRpR97dGX
# DATA p3TxG7r8Hchks995fM8fmXH2T3Lf0W8VyOwpSGr0gq/o398qkBnH5ynidPQPYKAx7+z3s+/pB7r/T45t9rzYstLI0fC0+DovWRny
# DATA JtaBaA4n6uI8eYspuAlaPeJIrfxnUFlkhrx4j+J99vIE49SrZJEQ0TzWoszeno+Gw5nZNm3aUVw2zWxJwVwc0Ux8KsnCy9X1+dtl
# DATA B4G5+36Y0AjUlgGbC+mc0WbiXhI9f7hWZOGPqQUObLZR4Z071+y2Z+mdpzMDUwN40RhCOtM+Uzhah/gbpymUew7UE4mg2Dl37v2M
# DATA 7hdN85zmVOj9LgZiwvbPPuDFHl3sL/DMNqyZq22cxWb3rOhmGybFcc6cNXBaa0BjzU5nBLwUTq1LNAAuYvzfaPg/2eh/iYO/1M+F
# DATA nLBQZ8+kBV0E2WwhkUw3o6xKFqMFxpksK3tUPVFTbwjoKee9/fDhvQc5dbBUrQxzyfCe0THZD7yyw8nACA2nREpTGquy1J4Hnad6
# DATA zN0Ub2aqgkd5DWWwrAGAlEVtYM5SIyALOBuNww58I1mjwDYGctxM0Vl4MDCGbWUesFUADpWYh4Kc4vgn9JqUbsZOleQw4aOU6p6W
# DATA 45s5vpnjm10o32yzsWajic+JDOTLtfhPY/Cfm73vsGcOe+awZw575rBnDnvmsGcOe+awZw575rBnDnvmsGcOe+awZw575rBnDnvm
# DATA sGcOe+awZw575rBnDnvmsGcOe+awZw57dnWwZ81Ks1Y7Lfas3K13W88R9mxh/Xkj9Blnrso8poQJbatSyhwW82ulbK6XheUk2d7I
# DATA ZFynEVbD7hy+qdyoVgXVNY9vqkgWW/GQd0s8hH2VxqM8f2itlEajMo+tW8YLq1m8ML/ZMAyqDCHtx5VOw6+XF2tOo0JVp9GTOmcl
# DATA L6i1mu1gKT9tXfJKQkq7oOSVLJrXxsmjh84teWVhfF1Q8srq6RMljx46U/LKpdKVaCTlcuPiGkm55p+hkZQbxTM3Ejt5595IMsk7
# DATA cSNB8s7aSOzknXsjySTvxI0EyTtrI6n6jSvRSKrlysU1EorFGRpJtV47cyOxk3fujSSTvBM3EiTvrI3ETt65N5JM8k7cSJC80zUS
# DATA G9habHiVanW/UuuVm5X9fKU2yPvNmlep7ZePA6iubgSnoWGypWtomGw0WzTMcqtWalRPQ8MshkHXt2iY5VrYqBgaZqvd7nTaFg3T
# DATA r8rPF0vDVJt5ZXZnOXvUspvhY/KEnUx026nW5DX2JdsmMqFi/rp4z/xWhcUlswYvmRUa2Coji2aZUNWC+dqQa7x6ln1MzwKXbzZM
# DATA 76bZ5N44GGTW6I5LrnpmyfL84g16pX4hzxfvTr2Iq3ZIyot8KSJxBSwEgqWGRdSnqnbZ5YJmswkPzMngnewxWpIqdhsu+J4Xtwut
# DATA 5H46WqejdTpap6N1Olqno3U6WqejdTpap6N1Olqno3U6Wuc50DoX0Zx7UUsBFLE6B9NTwTE1g4quXPeLlUa1XruZmbOox/jwMB7T
# DATA iEMyzKcjXLnm48lS5aZiY95Vx9ihHzCc9PqHhnPFiESKCdWrN7G/f7vEWMS3otcFqfguzpnLKeVRf5p4EGz21Iv4WRWlVc/f9krV
# DATA n5i3pUI7Mi+lPNgPGdW5TXH4Kdb4d5aFZLMMrXOmThDGCcJkBGEWDx07dRinDnN6dZiVSsoXqRqjO2vIQUh7QXGxkgM22vDOG0tC
# DATA 5uromF0G0FCGSgZ9yEDGKhx89RiQoH4y080nGWQb3AhLQYK+xRHkm4r6ToMTXE0TNMM5WILqM8JmwZIRBkWdBG/7b6PXjwMiWsGZ
# DATA pNjXTGqqx6eldIJkiLWBHgBeUTEJtt87Pr76ORNZc8GK6WaZvmFMtR3E7RRCiZAcSe0W6rpGUXhcdUkDScGT6SUT9fpxMa+tifVK
# DATA yJ/pAvSUicdDVcjPPfRvGenPWIih6f3QM1EdE5YHN4+OkdeBbcBFGgx4DsDLMywIo+aabZpUsVo0Q02wN5KmNznvoEeVj4zD8V5o
# DATA haZyt9ulvrY1HcO3gedocjUOodAUTbTAj/JXy8wjYVluVmKiKnUoBjLrYNr1rODdiQfsFqOuL6fEeoYdo/+Uii6pyVxHngjGShcp
# DATA tWVSyOyA4jUds29ViQ9tQA180ZRiHPPETQRWTASczf9S2PwnJZ1cFaVIe6fEeuTJWxGPmKKWyOvREIkbsmoPta1BuJZ98uzkJZ8v
# DATA dbXj1KXn9nhcBPhkUUDzvOEny3RIlwJQMmWnt8RIRV4G+HsT9rw2EZbewaqea+94XUxrY2icUO5bkf8YVxmx4CBAIqLxGUykzJW5
# DATA uQkO80E67dZ4xbcfvvduzrvz4EFOjcPSXnhYUFrugFjKvEiEFkdQCQ20kiorNVIpGNnPKEnnDRpsxw08mmDYXkNUfCCdgWx4Ww+L
# DATA vG1FQlVinaLbUAIdKnlUjh0niBLWCUHzC4dtKIIOQ4qf0mPNUe2l6trTy2wiz5pVZV2L5sx2IMdEXQvOijWto61gimxwqwOGofgz
# DATA BEYKs1+079mAHh8qSUwVy4J3T3NqEHNeHdMdWeB1g6g/Ha+jWd6XYLBwtYpn+RJZ4HZ/7WxwZ4MvtcFVJXGeeOeJz1h3K433q6Pf
# DATA znUaI3WKcw488RQaD7z4aqIEG/diHiSz4uPahT5PP5uOgBMseD/HHvFDg2ihOzrTNkRkBhiLjbSx8bcz0ZjtnY2F3FPdAmme+Hrr
# DATA VW34PcAxb27Y0K9IFABbZhyqL3j1urESJ9J7T8b4KMLceFVbnPVkb4xjGoOpYfeW3vAzGdO7oDavuOVDmGxIpWhxs9g0br2Od17X
# DATA 75fBaD4aylBVBpyxePhNnVtvqM2JXINzHoaVLvX9MZUZYz+pqk06fKcaI3KeDMY5LbUNzh0wxUlPwu2oaK2Ix3vBkOpUx7YFTWRu
# DATA pxL4c79LFGzTzdhfVKLjEOLdvHigLa/jI/LzaDyZQlGdpcStOKgCZjOPaytLynOfMo77JjIfjFhRxdxAlTycsEr6iAdPyqB+X1f1
# DATA xIrPdVVQ11WlW8GlX4/9fqDtvDTvxeQLOgMa9PUsJ2X7aCVxRWpPevG03+F2KebsEJYfNp5jaiXq6lLABY/tS7KA+/HhgIMg+xw8
# DATA 6wDi8JYMPVj0n8QtHjiVxPx0yCxEFdI6IPgwPlB65dp0DiY9Hf0PxyxnT/XeY3ETcXbzeov2G7PTmaxxCibQ3mb0UtTZ8T34gRmp
# DATA qY0LJBQgi/p2nhiBVD+Eg52G83Co7+0o1mO6NrguMe+JK1qlJxDxfPjVjXtfedYRMb2ekXIVemF/pPozWfC0+iKWwaeBMs5AFUZh
# DATA 8BglLD0m6h7WLDvhAC+wZ1gKrEChyHyQsfBoBfbUTNkxNvjcrH+ifkaDDRniL5Zt//nnH3/+0XDrlR+86P9R1of9R+gwouEUUNXR
# DATA 4bm/A2uXtUrlB2rdeO5fv1itln5QTP/7QdH368XaD7ziZWTAFG2OXv+Dl/O/H/3oR/enQohoUwcSdXicQaXYSngvcp6xH2kF8e68
# DATA +w71GrzMSe077nd4CZ8eKFBYr4hUCtm2e3zYRn//hOxD/TlOXuHRC51+P2p56vI9+qpvGZsHk2lL+Wf0FRzJwnCgv0/JdHnllQ/v
# DATA 37537+59bKDe2tp6hc/YvKI2WHZlXzU7m7ZpMtkJb3STrR3ezYiTIVtg8F2nXvE6qL7X2/2IZjBbN1+RrdbdpIB8gJvvweGwvY2H
# DATA ct4WzdcbW9YO1C12CuURej7Nra2dHe1fKoRPosm2v3Pzlfl9n9mo8TmyR+ohegP1jgdDfnMaUNhGbuW8X6jILH/3x7lXPM/7bCKn
# DATA SG74vN0hNwievD7tYu+jXys3KrnHZGU+iPaGQf/G1oN33vrbd959dyuXTDpRfOMXW3Sdhoet3NYoGuEf9f3jz3dU9qiNqeF4TEPP
# DATA r36lN6omHKB9gRfLZePr6iyRPcS7mdNa+vkOxoJJrI5VqPzX0eAHX+OCOuSX4GAUXv9DOTxUiJIHQTd8h+yiPRxSwO0F5NcdrGTv
# DATA 4M65a96rXnHZ5Vt82mZpGvQVFdcDGDLbKr7zb6T701Nb80F5n7+CSvzKKzSFhpvyEdONtqNhMqJR+JEUOk/+d26giJEFvIKOS7AB
# DATA +EOBrYkEU6jtrfzWDn7oh8NteZASUvVLuIYnx2EB+wl4G/H2eOsXt/P/S5D/ZTHffFS4fuN/yn98bSv7Qvw3DjCV+zkSdhfFv731
# DATA znAfp32snoSf2drhZ9RAvMstPZOYHZ0IuYUryzbV/MkjnNSlmFa8n3rY0Kv+WR8HDtcLn7TJ1k1kIqliAHtz3EFvgP6owLsfttU7
# DATA UXUeYX/19s5OJk8TiukkGLZRFfnxnIfTAyY71dUdqnaev1HuqKmuwpiGYxU7fX1Xx/MXxY/lB30j9nzLTXwoceudDhXLlno8HO5H
# DATA 43g4UHvD7ftoOteN9ujezz7fkSt3h/tyJMhO6nwlCPJdqgEff1arfE43m1js6EpjZY318rnssX7ZUY3nLJmE09BywIW/YrIunUY0
# DATA tHMgfcViMfL9ORy95UhukZ2HpyUYvjCev/CkWJy7tLul9qzItfR9y5P1s2EyHWG4otmFFU2VKPzHpz0fUcqkp+Adg9v0mpzn78wn
# DATA ZnlrffSx1Ww//ik9iVOrx8VMZ7hdfeg5K2ac5QUaHsNhRx1ANe11OthGIeOWAk02qHvjc34oe6xDUPbw0yj5UrW2QfO9a0VjWRP+
# DATA MdaW4NjwBorj9UbcfozTNfiHKh89OD7k6VNO5sttro84yYCCQ6csMD0y/QsqSOzAor5X0fJgy2BOy/Q+tUh0U+hncEnpmT980CwZ
# DATA iuli0guw/0qaq+n9dimyw5AviiNLmS6FhyFsl2B8+AYLC8bjQxa2i57sbtGLh0F7igPlZiRH501T1Y6+Oc1AKrVHyorhXtXcsuNd
# DATA 97bsmmYe0T7zGN1JnBRACNvW4eRw5YNHH97/4P13/7P3K/l25/7d2w/1l7v/8513c14xBtLDhMmpo5+7HQ4tfQV1TwcSeWpuYTDI
# DATA 1ka5pgZKtMPCJ1Rw26rKXOOmmb5kYiecM1rx1HYtK7FABbb9i8xt+G+rw7UE3aU8hU95ce/io8n1QprruzjsBeuygL8qNCD1wie5
# DATA xaDzeVUlOHTdX93A0+Ybv82Y0/JymmbnO+N4tHsbFteycBO9REP26e4wpvcc5DHzjQCSSSQUKrk8Sm6LezRTkDtLA0QsqYrgSW3z
# DATA 6lB0q8F3mCl6wMfP+KIM7GywH+fgLJhMx+Ej2UK5+3A8VQev9UexPnfLxZysm/L1nWxBWi1GFao2ouCnGm1nb99suNJhzvWAK1vo
# DATA Zt0kW2JexD6xid1Lin2hLPr5+mhVPzbKJNODySRo9+y4frxYasv+2zTP/bWZrk7mZQ3szfP7o85nfq4qlgHb0LA7h5Nt9U3ZyTdO
# DATA kLfWJFMitZC9LAeQvsT82sWWj/5c90DRNhm7GI01RTQeSPnQMNYOs8XjSTbtWk+/cffn7//s3XePLTl6kmZJy55My6uqi+tNCDjs
# DATA qBkARqJtVY15UoSeW8+wC7fHe+zVv8e/qKKT23CW71Ggfqc5QF4Z3ZQmvffCqhirnmETfukTdBtsMfUg/4NHExWJTIfN5za208kM
# DATA 7iuo+OQ8+cYTDGXNPgGG07vL/0CI1QT0YzXiX3/jdY+nnQmjQVVXazusC94HGLQDj9E9HnYvDeGlbHs0PgUjMmrmDJEH7Ny/i1nY
# DATA 1vsx9nGnNbJtfOgtvt6NxoOws4Uyoor26BHMgUdkv+16W48eocQePdqSSEvxXVFX4hin2AfhRbj9NvP/lSrFcnne/4cHnP/vMv77
# DATA 8Q+vT5Px9VY0vE6mgzc6nPTiYfmVH/3oRyzcIbxaLL7IwhjWGLDii+WKeBRq6K3ewHVfm1Eez7b6feoW1ngFsUxRq+hv2NOkP/eC
# DATA BL5B/TWCPtjYcgKe3p8oK4jma286ifrmG88hzLekv8YLGYxtJ+S8U3LSGwsBz1ygRpbxWHKUp+M+xVh6Th1vusaTP+pYePHEk9n7
# DATA VPJahsx09FTDAmXybbuDg0lNcx6vdcjlYkqDLXUso4zDT0K1/ocMkVlnwoUlgw72gm3TDCdJnT7SSS6Jjr5NPcoKPCgN/ZyM25bP
# DATA hecqfIfld+H5I/Z2bvFeqK0dHZ7MD0bs8VSTd+zV2ZVJiLxjgjMtEz0N4qD1JFV+KkTJo+RwgK0u25ZJyMncmv2fs6+92R9nT2d/
# DATA nX1z9OXRP89+R5+/nv3FO/o7+vCn2Z+9o3+YfX30BV37o3f05eyb2V/olu9nf6bb8cOXs2+Pvjr6r/QTP/1nfL3hYQoAo1xioEY2
# DATA FR05slgYwB7fli+JMt94Kvooto02XvXc1a6O7ip3RkhWg+RzZzoYJfq3cIglykdB0o4iMS2wWwzD5G5Jz7PEndLJ8byWhZnUXHXw
# DATA GC1/ZCaohXSGSlYBxX43k6IlQz8mhu0eFdk2wkfRrZw54gaaMSLK2cqAFfcDTAx3eVK40YwSmbaz7OdufwrNmMxPiAM2FG/reyjt
# DATA w1g7A9Ud45CRYVpeSorV9s7QPZx/PyQzgOZS2ciZyfmjbseae2eyT03A779hT8DfeOf+3TsPP7j/n7NRXpgQZ9Jhvy373FJrWT3L
# DATA QPclzy48I4lFQytwfU04U+YmW3THdMhNjn9U7VlWgZUryTiw4UdS2mlwFpVXuKa3X7uRurk+znzLf/xZMVfzP7d+33nto8LONXXh
# DATA 489KuVoZMxb71VYv8N9n31Jr/x/Upn+N/uAP1MD/Qi3+O2/279zwZ3+lHuB7+vF7uhGN/2mOrtGVL+jaU2/2De74ij5/YxzO3POJ
# DATA S68P4ZJtnQk0pJi9i4/+f/bevbmt68oTnb/5KY6dpA9AAeBDtKxAgd2URNtsSxRHpOwkFBoFEiCJCAQQHEASm0aXH5Pu9MQV36RS
# DATA t6a6qrsnde8HUBSrrTi28xWkrzCf5O712u8DgPKjp+50esYiztlnP9dee+31+C3g+bJZQbllTSVfvjwtI1e8l4JvZ1ZdWgJWw/Oq
# DATA K4Cdra74nSXVVlqPz/PyK8vBNPxfzz4FTqeY2iPgdYr/0fDUSNWcIIdU438K74D//RIn4wuYL/Xz2ZfPvlQc8InWSkPa+szXa5ZS
# DATA R/O8kvyoxtpiLF6E36uz1gd68xRW5yk0DO0/hm4+mrf7hqMT63/+yfMPgYvrxePbvKVrRj0J6Zqxo7YmboRoOvhvcI1W46QXTASO
# DATA bUavobd7nCr3LlfrdnUyW6d01ba1qrGlfOGF/JN1CRdUHn9L7v3tUv1CsaA245LZe5XG35fV08Xi0uspq2UDRTZVCA53PYBfOkK1
# DATA r5rds7QCV/BKJZ2Qr655hZ/srdaFktSsFWcM3R9v1dnaRDwYo1E2tJPgd7CZn//m2RclwwFkt+POf6QKP4KKVDHFGZ49Bh7A/EFV
# DATA LnP95+cfKwr7CsgTKFf9/sSaVYIcjO1kGutKHXayjNueQviy02NCnT4JM/YCTsif1dZSS57goD5j2Ub1+PnHSqixe8wqIzYJAAah
# DATA ze3obYzN0bDOx+nOtfX1sk4fLg8FuC4p62ZwYiwNv9DypIrAZkTC5BWArzSDBVpWZAnP0VChiuG/tVrIoQ/lJRfOwkPp9zSM5x9F
# DATA Vu3L5x+pOUEyhmPpU6Stj2nfxs8vPJ2uOO8UGasJe0ITCVUHJPv844RKwENNCbzc2O3Yaqv7ZGHUv9fuueubb2pW7OJuZfpvxRXs
# DATA Kn0Jnnr+EXB2NbL17c2y2YxzEASPqJCub283tm/d3q1dXF5Zvtu7vXFza/3d9Xc2GtvrWxs3Gndu36hxwhkUhh8077erFwGhoZc6
# DATA uzA1X6rONHZvvb2xhWYFHARJ3ptbuxu3t9ZvNP7m3d3Gzsa12xu7WIRvqhUs2jhuPyxcBGHdrf9ub/f2nZ3dxvbtWz/+SW3lbu/m
# DATA +u2fXl3fatzYeHP92k8aNza33m5sbK1fvbFxvYaosGhSodWC66YvhcVWCLXqrOuF6wyD0IqAhoc3KPdYqlC/Lr3yysVXgiX6N+Kd
# DATA htkQaT7/FVGYomBVF7yk791FMQ1I78l1FxVv84yCJcI9TUwgLK5OkQYVRcGBqLoMQsLninC+VP1+Ajzni+efsDDIbx6JViQi+HF/
# DATA LWNcwdjSq66ocTYJzdq68DRjPq7GXt2Rz8FIHTdQo7H5QAPJTTM5m+7tqa/qCDuH3+WyfHFAbbBZrGBZwQbt9jBTd5z77eGwo67w
# DATA aWoUGIT3iPoKsbH2wQe4c0AhAIg0ob1bhYcm+21w9SXVBQopoLit+bMG7qnhzG1ROzfB3qUFUqoATmT1TereeLjfqAfTP14KywYn
# DATA 12fIZNW5pChH8ZwnRPK/efY75KzwCHgtsOJPQfOgtoISQKDSspR+/muHVTvHMS4C9QGf8vxl4TzwiHfaIzB2Z5HJyIiWmBJ5M0mF
# DATA 4bmcoND4Jco1f4LOgfTgHSpf8oDgH/WbLfYgZsI+UhteyRfqgIOPVHVwWsGEPTFLEp93dsDI79s8M89HweeqL7+mc4M7EQyLTmB/
# DATA AVgUl04UgXJWgotaDxRcHcDH1QUVHwsu8Zqoa1oNWIjzjb30+vru+tX1nQ04jdJ6sSLf2uaTwtvtU1TRlZJAZei1p+2gvOLyKnrQ
# DATA qrUCMv0zrhywbmSGT0gAARkNHhpZmhZUSZaKdX6WOB03shX3Q/7U12V98cBbpMUggZfA+iNPcbYpPNEeUrgi3i7Ax1wFPYGQmba9
# DATA G26T44cq18lwQkAZ5/kfkHXImI/FLAw2sXZ+W1tqeNb2hbGQQklJ02iDh1EVrPLz79lipUOYm4EpFKc3d8fkDgnNfN0OAvWo2cc/
# DATA ZWkoVAqeYIel99SzdfpIDqaip7XEz0hrOYk1BmZIUMUV/GlD76u0WOnSFRvuf9If99BiiwH1m1wjrP4hoL9UZQ1HPcfBpJvb61QB
# DATA XETf7Pb3m93N7fuX5KHXazU4TcPqc5kxlu71Y+lSOPFM4QAqzqG3rGSE9AHFIk6HkJetR8YLDBSpjHtK6C4sSkWk0AdvLDjSeP+g
# DATA fhiL27yLa0JFQr4yyOzi+GGFTPIDUoype8LnqCN/Gj0e8AWdAldEjnqMLPZjvN7ZHCIh/cQTS6tmHQjOtpcZiR0SPAMvfkJDB9VU
# DATA /Abk17zTIYe7WeeAdMvmtNztF2a0bmdVOSqgp+0J3AWtg6uSPPsdnbyPseu/xBd/4rF+xqv6J1wJvL9cgxuGHtfWxu67t26/7clL
# DATA sSmWxBp9Hi//ztANssDFi+DlSoLjAYnQDfvE8wR7FoozPK6ClozMEtpHIHaqGHxBAnruR+jJWl0I/HvOJg731lrBiKgd+p9iaWJ9
# DATA IR/gtf9tgvdwup4+0SZX20nTUdnoWxRKUu/jnfdp8vbGT2rvrN+4syF6EvXA86nBm4DOVG1fCkhfCdHumAkXLgZRtyBVw5RhRHv+
# DATA JdrUPkVh6yvSSnyAF3XrcsW6WdLmwMXrT+kclxJ0SpXRELtzHLzc+4rp6dQJ9q6p6s//ztc+1JbS1FrrhU+9Aaivf6Ev3uL7rnpm
# DATA 20kl+sHYTxemejA7ftZ8+Xad0K2bLAi5MI2fIYv7R9ERBXyM+DGM6SsauhrUJ5Fbrdm2YClrZMfN1Vcu2aNpdY4g7rAmtvwKFyka
# DATA f1jLDIyWsHS4HzftwSY7OB737sEmQzG62zzZbzWrYtHDrAlWhECxlOynvj6delShaOIC1ueMi98ftx/SX9pWQzGjDRiIOlKNjy1f
# DATA 3vv9Ueh/y1azLqUVIZY3ILkVdbbgfgwjAfMvntEDsFDDB+onnGADY0nceWtdzdzOnZs7huuClnHgGLXniOUgDRrVXDSdwW7OpQBB
# DATA ojE2cbSeIKE/pj1KBKU2gj6syRQLw12yxwFxC+Tt65BP8UKaJOkF6uEFdM33eilrch9xAxq0NGbeS3SK9MC2nVIc2+xlQlduEaT0
# DATA /WLYf4CiYNB322mhSGoTdFm2pe5cU4lah2b5EL1Ui0lS8FanCI52/Qf5hhIxA6AYD92OSjS5KydM6itLhsHjgtXGz38BJ8hHimt9
# DATA YbFbTJ9Ywxlcitkh0AocI0V5wWStngbMAghc7BzRsfyz30uW0KiXoOifRoV56hVrdDiNKGDL2IQrMDyVOu+NX3eFIqYr4GXB/ryj
# DATA tv9QnLIz/YRlG6egllY0yaLaiajWljqoH9jFVBRg6OEhRtauUwk6H4BKy9/Rd3r3ehBXrwFa+YvUCwPicf+o5pOYRV6oapfFcFcA
# DATA HskK0FnuK01w0uSko/0VzmMxPj04Mo6mh0/wbmgNJX/4WwhMAq+4AzQPqbvccj6kksa9DFkehoUOMcwOcm/AVcDIF6xoT5YXseDS
# DATA erEYr9IarkchRXNfi36JR4EoCqAHe3ZwB08b0NlhR/VsiM62XHWd4jShVWT74q5hwty4SzwG7pazEvqbPKqc8q3FEnudQxIJrImY
# DATA 50t/NkDHscf5PlIyxGECGbyEUCN7lB6ERk/lcQztVlp3uKt8QHQExIGqoNt9yvTnyxDusDHiFkmgPOQPPNqdb0P9v3ygMkv+b4pz
# DATA /VEJxeqq/PwfDBcjVaVi5nhXVtKZuo6CaBrwceSBmkOS6OxesQbOKeiaQJjb40HphnvZLL25n/W7kPnMmiD+Ute7BA8W5joklETe
# DATA 797HnD5ZY9juNked++3GqG9HNIEg4JRFk2oYFOWI9GUtrUyR53/FArHx9yMh/jFYWHFmUZEB1nu8jD/7I5w7dGt5hPP92DIjymBl
# DATA 0yCzCo/D2R3Go+sTVbe6reMd/wNgp/kddsV0d64WmAJ67fFo2ATIB6IE0UgouVajvgDeD8y/sc0A7t9RD4JxKeNRt3naHmYJ5FxN
# DATA mocjQBzv9zDVK7qFXmFYFQoXJ1wU3ZC21MQcbAx/kxNTvqucNk+69lFqXtBzCuAo536X+169rodEbDBwlhKtV/c3Qu4SR1xNo/pV
# DATA bs3dl9ZCmGugRVmoS8QVmlF74CHIq49BG6qjXqC14k+X3UhrHJe5j8KGO0sF5yitJmcTowkRm8OtnWkmB7cX6Izqzyy/zpVsH6FE
# DATA +xR3J0i12iFddH4obcA2+QU7inwBaobH2sjDBorHOfyWLG10ff8UdW6ktkRe/MRRRLieMGaxYnZRhheSnRfcI1kqi19RrMOTyk07
# DATA ORecmwOfb7EjHDuZfC9h/FlCUGJIoE6vjM6uenoZhUvd5+8T3FG/29L4SkhOC/6ZOsvnOnpJAaEe1Q7/DRTKzz+UDpSDuyXFyYs8
# DATA Ia2yx7TZvzyjWEgmLyJu7qV6zsGeZjgnj4pac0qBrAmyoWnM9Yow+ABaHkH/iIsX558N59jJnwtRNVi8VGQirwemae00n8t+SHKC
# DATA x7bYZJSEjnItlLSqc8QRChlrcRv9TRBwwhHz8pWlMxw1cqdMeykLZrTeW27L/iCkfFSasV/Gr71SAm8q1BK98efrPJfgcJBz3Hzd
# DATA tdQ9R+0GZkpSZwMibrcLEpNhhVx2DSoAm5C0+ljWDlT/cB2yrU1neIIdsjBXShoAeyDqnQlOChTL0Un9To34D2j6IKPRI3FTTULx
# DATA 6XGojZLUnS7x6s09xyUA4zPJSivkAqH2uTcBe3eYb6Ok476OE48pgzMlWzvsclSZsm2Gb12DpcMU1iihPfhJmyCxCfB6fGLrhOyZ
# DATA RNZqdc01xkvBWaxz/h6zzw9AETbVzB0rUdPUY3dy2Dlpog91voBldY+LezdEqYQtidPp9wVmHVAIm71kzMoZOW6R6bpeAsLQ7T5T
# DATA lh1/ud1wKNqM9MweXH6AFJCdG6jE/5i710uOjBzXPd+1goWsHaJD9S+i/53bEOmmTfuiBd+6dX2jsbO7vruh42E2N3ZwxzITRSAf
# DATA OGG5M2ZcqGTPY64zlocyLLlJe1OjJQ44n5hDkR4c+7S2UfnmSyssjMNlTjoZwEq7QWCk6sviBkb+Xl9IPL7BsUowkZ49hnsl8C06
# DATA +M62g4RTR2r96OBrOAN/lSz3X331VXMj1rNsh3LfbhPeA2P8tu93+uMs2by5/uZGKRlnlMIA/AEftK3Ezr0R6/7UZhkAbqVVI2HS
# DATA JT8f90fN5GeKJOBgx4V8gBHcw7aa2nEb48Q7iC8EebZafIvFsIzxwASGc+whsYCSt/PQnbDu7lG5n7klbe2gO5l4k57/BigHKX6l
# DATA FpN7lrdAWK4U3Nm0D2232WsQBCTolRsszRdoaCWaZYjOPzjuYMJ2y5WT0UGYIbRqQNKiOOAfloqyQVXiC1utQLcHkxVCPKh0nKra
# DATA hkAFFqt50AFENVzTB81hy+gTwPabrxImtToGm/BwppULBI/foguGrfD5M1lHKVLskRh5E5TSnqjL50fkGeNpidBPxKjHf53jU+hZ
# DATA fHmyBbPKAXuLYbopPkxpmYEJZ+8BgNV7d78fAXGzvecd5xJSLUK/nj77jKzYoIRSEjUakj6KTAVfWODijREksaHdh23R72Fmdr1U
# DATA /DB39PzeHX/MS/1C4fXq3Qr9WTxbKVGwH309z6DF/ZOckT5A80V8qGRmCscntNUwA3XJLRhr8AX7G7pHRDgp/ncvODt+NcV5DYpk
# DATA 5rFnynX6jUjfjDKCTmtkwGePmUTxXCXtFsCjQd3jBwWE73Lc0ivqSII4qL3lerKYrBX3qmuemAYVB7MCe4LeTB3f79krAq7Zj5CE
# DATA ebk53kiPDPRGn5I2iQcOvh/TLJBXSG8PnOLfNcdQJPUL2kyOF/KnrNh/SvHnpPEVyjKozZm7few3XFgdgQ3vA5cMI99IPhy/KD9f
# DATA t78oBS0Ya5JPp1Yhy2cFswTYPWRO5tTJKELqneva2Tv1W2FnySk7wAQFuzZ3AMoz/hDaVdPphtc+Gv7U1DiF9M3V/9TfuP7MmUk5
# DATA xyDtvgZL4Vfl41jSglqLMX9b/K12O4JpkGd6BqxC4ZAsP+SASmMtncMvxfFuoFjtf0Ad4gcUm+nxp8CA80THE/qci7IgQH8xlYaz
# DATA /eDJDolXACrsbh7nJdm+WRIjpzUlE1FBLaChd7fRpHZ6Mlv+brHf6UrVc93LnFkO5vNf1fzQFGjv1z9jYOEfgkiOr5AlfYT//fDZ
# DATA Y5ZxzjuXgwF6VexRWhL2Ta/VTM/RcS+weTNFOJHsQH9UoSE//q0J26K4XGrjb4K5+Z9qSH/A4MpHz3/9/J+Yecv8SEhDVOv2F4pr
# DATA URWw1ACu0x8ixX6kanoSilGf65gXRmWp5USNsYv99jYHDFowsCwoXFwV/TNVhWrnteUfXpJZOTgmusF2yL+O7G53EQPtLnqtIPBp
# DATA PZyV3zojziGKqDb7KZ586IyID6wx5Ont2cViinJe675zL1HsHenE1UVdN+pRWAJSRqLmftXmfOySNkNn+S9WlK4vYsu8fMl09n6g
# DATA xwxYl6gytW5LMPx57PTcGT52rBTcjrL2Bjj5biPuY7Gorf8on4EoBk7TFUAqutc+zQp7i1wPN1G3P6m0H45AFTyffVl8+Wz1u2e9
# DATA 0BdpqL0auJvNbVyf4+AIVcfxQDvdU9F7n5FpBN1QyfoHHmGkzK9GfN2CzmsPZWH5kJQdJ8KxP6cVxQdSMzeSVInCbvxLNlAo/VWM
# DATA nS3a1cj1rzX7gkrTp4InSmjR7qyKvzLJ6ViclJZTPPBpxMbtfi6Y5vNYfnBBNSxuro0XsVqiizzFBUZ3FlfJtvraDi7GM4YG66yk
# DATA 0ebYnlpxynd3HzVa/HZ3gtkBSoaCoBbjA543X47H2be1LxT/YFdMQImrtNrtAfzBiirLU9AIVHCypyXh8hwtDtrhl2rBwzxXnBz/
# DATA gE/ESf5LNKvB4Y7IFAnESqk5+yM442C4qAkRf/6RHO02RoIlDEacYOJSm2z+mszKntngdRy7Aa2Iby0uHgTFuAEotqjyhTZL5J32
# DATA jridRyvtw8M2KghV5wuiOZzFruYZka542pjy9T3w408yHpTztA9r7uqbu8WjvOEivDSsre4eDZCeO3HWYQgSFQpikJx6YayFSPS+
# DATA y9C5uIcI4EwnFaHedfrGalPhtQCjZptCaVObgMuQNDCNB5vWanhFyWXe57h2oIrkC4pIAWIz0U4cqcYhNzFQDwvwN9x3wrBc+or6
# DATA Ug3biv47IIAC8XorynkuJKKUF+OvcTH2luuVoUYrwiflFY1fVJUy9nJYbSEakvo1OhoS5Lf8/XMGLm918LFaU4DtB/RuJaM8REe5
# DATA ZquFT5RA1j7s3Euj1sln/5a7c2Gz/1JRPwim/4ixWmp9PqcoUNFQJbSDnsJGwS2CAWhQDsG03kcPyl/bd6aPrIXhddjjCYRILvzL
# DATA L1AZ9AeFdH/c6ULKCzQiWDaf3eNOxiwEcELAhNBHuDpwcUIYf+3iAa+Hg36XTNxwYoqsYNU3hMyl7R7QB0EIsw0KMgD0VI8AN7ML
# DATA wTuqwh6mKNDxYwAsrA7ESjhCG4wfxnm2uBgLePSlL5MqAs5Q67pU5cubBiVMQb+ffv/7EpusSdQ+ZWJc1z4/tLYDOmWZpewuhhXj
# DATA Tb4e6zMn7VBlCebKroedTOkzN24WFeN0UljqcBILpHex7xbcgHpLTg47HYbKC+fKPXqjjCF/oqasZXhGOIX/Nzsh9Nrlzrk2OQ6R
# DATA O0rJza2d3fWtaxuN3Z9sb8CyAjdTOwQZGSHq9gkW/+C43Rp328N04msN6X+F/X6/O4P0mAuTJOzMp/DnWi3Jq0LzoGJOB6yZV/PB
# DATA ulFoSf2yNiHtQmpLCL/oHLY8T6BH+AaPXS3kmNjaR2TA+wxx6p4osfQphwc73lPTD19CscVtcSFJr4S2kVDr6gSPkplMO9M+zjej
# DATA av91bQ12XbRCflC1ctSgTBnhLh4Nd/WR7RCx0Z9Z8iV84WjL4MHcqrLZgudXMcHzSRyTBs3Mn3OM/gzhegrrnsX+ZzByuooddJt0
# DATA F3NanMoa1Izq72yGjhld+UVsD72EQDhxsWX6HD12biwCZmhFUYS2eWPa/SOsTQS44ooQ+Bd8K0bj4Jci9YDlj4D5zknxHtWfudNY
# DATA TZDfxA7/iRtI4V6O8ZZrY5nq+ClgdDVx4AjNezXShpcSWzda28PLPKn+inX90qgQa3YBK0dURO62fJAR3g4g0QPDo/3lLhS7o0qx
# DATA bJBbcJsYPSGdGH1nTl3+ls/5YltL99690/R+pvkdo34vT8r677VJeU3/uKheXP5hc7/uPJG/V8hPTjcWZzOE6jEV5jMMjHiUnO98
# DATA eILs/xE5Rvwj4KGIK4CBT/84iJDYy1kAEITNsOzQiTPtKVFNViB6R6v/q77fKMoS5LnJGiemQTcniw7oBCco/bf6mDRrqJgyqizK
# DATA 5QQOXlXRs0i0r3pCo4Ju8a6FUvxnyT2rd4znVXQrTMQXa6YWHzXhAqWrIVHwZxDUkWsJsYB48aIZ88W33TYJ/fHyZJf+uDT5KTvo
# DATA 35XYZuwWXHI9AHCdNifUZ0fCWSUsyw+Y9qO+4sFeOU/hW4p/DZo3Ma0BrLLpuAeJ5B7pDtjRV3CiaH0GOoLFDDlVdR6ou/Mf8HiQ
# DATA 4wP3FetfDSZ1uWwH+IRQQrkrbLoPvjJ2FqQsopB2Jz4IIMwMzsd9TggScxgER0JDkvDL83ZCYBKM4NTvMh9ybU5PvNxImb+A8w5Y
# DATA 2XKP3LgWOzQ5QidnhQMVrJI0lHreJ4GvtGts0DNyEABUshLba8VVZue+jACwzjNBX1EADTp1sbD0ua3ZnmK2tp3U9xapY4brKplh
# DATA 0QyWuS7alcLwS8tvPYg+0nlS8w0JJn4ixACCHcFVzAjAcbGBxJ/Bs4yQpwO7SLKZn2z/MKlyBv+R8wY8pnN4ygKwv9hjKG6YhBOE
# DATA iBD1OqD7pDPK25Js/mi4IEPTd/GLbol5Yi2wDi/KQgzOkcC1gICqc8fNxkmHLNVBtGYY5EGdsiz9+MBY+unn/Kxplnn/seZeBDWX
# DATA Sx0Oqo5xS8eJch3SZ9vQc/3H7YQ7oeu4KWGIy2NROtpcYl6J2Bz5B8U+plIb0xvdwinytC+615NmT0ngrQTUHlaGN3bap0bAdRHS
# DATA jsO/4kZuu4bHJPc5PQbPhUwuVMO/lAABadbP48RmCdr06DwY5t/hzmWNuwCWsdDt2mLNASXUmWNrtZgouZ4/Ri9bwlAjT+MpLHP6
# DATA rNGu0vcTqCB0xrMEk5j0HmTLtl3ufDcz70h2nG3rjuArtZzDOx2AktHBnnEh4BLna/Bm00msEzEbMy2boyOCz+rfkoEjApiv+A7u
# DATA pUmM84kDgGDCt6H6dgMCuRrEniSQq8DBLsCszhV67yKN0T8OzFjPwIdDG3pDSHsufgpvBj9qj2Ru6g0F4HM1JsY0DyIp3PJUZpYE
# DATA K6WM3F034Ekiq88ftBlE0+kQOpyVSMymD0DlIwSZoc9CCbJAB77NDgdBpnOwzgCRSN2oXMnE5aPBoCPDnbo9ZVlt1+N6nnAVEuJ8
# DATA oaP/p4aN5tMMhY2ycruJ9NBtg6W4/6AHeRZ7zUF23B+Fxm8b8zm93++OT+S4Me5Uo9MBqJjS/U6vheYy6nTVTi8Ihn5ap2riDo2F
# DATA thcKXSd+az4FifCFdHGJ62lbddmPdsDFckiTVY9EbY0c/TFx2UY0DN67JvpB6jS8eRiN2clFi0trNNGvqyn3OxLDFaRfRevIEkxS
# DATA +iXHYGM8OBo21QnI6hfxpRy2u+1m1ubs0tWFmY6XHrjsa8nacqBp1HfrniLcYedAO4SqPdy/36a0kYqwSXHPXfDdQKdnnvnhxESu
# DATA 4U8dvcZtFvN7JfFmFGGmY8v4Qye6zNV9wWcXksJyqZgsJoW1pMwXP/W8GEw02lIKdnDlzBhOP2wzGELKni4lMxjtmCJ+MoGn0YLr
# DATA quRgO4+aR4hIynVUhha4czX1hFvBUAaPJkpmpT6vhkDKXFnQVUMNs9dxIRcxNS2g9ZnruqDqKqoqyoX7wePi6/ji9WrzpHVp7b3m
# DATA 8OTSmnqI58SRB8pkZkeQRzVIvtEXlSys1eClv/7jAQERF0zlbvJb89xO/VdIj44PhpVO3+SRWiKvLv0rpDU+NhoMoG68ObU4pZs2
# DATA A0WUippPsDEfCQOJi4uhux26sC14PjNnxuNM+6DhH+XBsP/w1PtZpkv90HZQs9zbQlc34+FGTm+TgBoNmtjcXjXgYIHRqPM5YsQd
# DATA cCzPdgdTBuuOum6g4dtFbJ3m3xGMj6BCwFJsJCVWl4veXMhIS1HwCv91zWJ2sUgfYh0rRXsbLek1BeeUkmicXjp9m9ibxr5S04gh
# DATA Qwf8QXdQyuzCk8jbpJmBg55/AmY+pAFJSiZ2mn/z8WQBHWS1QtHJMd2w4GjDk9at187U0TBJuPO/0+3LUW3QP7TEbXWAkUSM2Gs1
# DATA EqCMnCeUe7oDvFYi6J7oeTaKXN2TyDt7CuOQDXwkDO8xOIbx639YNvTKs+RnrLK2KFUReIU7qMKwF6lcaIeyKcz3A/THLuK6XZc2
# DATA gFlXp2BiYh/qUqkWTAw3H3R6PbBHR0mKWbuZVoex8wE/x8mVM0iO89qL4TdIz+rzjFa/mS8u1l5jPxZeFcyNh4fPBOzYfpMLrVzI
# DATA j+213UPkaVGOQB6Guq4QZnhQsdPrzuwTPTOhDzR2+4ifhFo8bLkacVifi2ByWy1GqOj8lDR9y1D//CirOSnnkHzZiF87GRMtjWYL
# DATA PMG7kYx4nBXQd7U1HrT0IRW+EffLZWnJliLUWCvkjlARPU7mxIHHvY7Eelv03UMj9ZmykZCmRChDIsQ96ognMPOW1CfMM6aCqjsr
# DATA m0Qa6ixnCavKXZ+EQukc8RVzkWusA87Enosuvb5g77u4je016A+PMFGJoa8K3cJcUJfppK7r7kQu6vKyGLq9+1vkXNuDQj5LBq3s
# DATA WBFQr8Ru8nIpB+bnTEwhHEYpkEJCYSp10FEoIw6DoDxBl8pHSu4jJYQrIBbCQZUCySYU1tz2XO8EjNn/HFtEWSov6pVmyKML7Wkw
# DATA S6PC/wY4XVKD7/Mqz1/jseQGSf1bAB1ju2NL4npI0PZP5FNcjXu1PsLvaLTqwxL7IaEdSd4SUXieBYJWbNt6tUORb07RYEt6ZkrG
# DATA JhPTPk01vMTsIEvfuBUE1sV8q9W+wD/tKqWLpqSSL48daOvzIfnmwsc3JUIyriCNAhSwszshFHwLAASp56txLqAF6lwA2xF1qdDQ
# DATA QN1uwfPkCRwaZiLogydOEK76/NcQtCZ54w2cLL2xAJeMbYeJLQ84wfMhqZ4LftS2mmMel2/TJRMBFwGRgfC7JSiO8teRZWCcqaNp
# DATA /zRpN4fdDopTzHYzOo7bzZZVXR+BHQfqut4cMVhjR1XeOWmrr05AEM6Om63+AxdathIiKrguokv/kQ6iSzPcQ3Wf/7f0Dp2D5vQA
# DATA 2D/ULILnHroUcw51EUhtFBL2FnV3Q0Vigd26qhGEXRfJIOaRVQ1QGswNwt5I7H7c76nrVtdP5hAjDUcxIB+6/TH15feIlj+sPyEG
# DATA jIDdcFB76Enkn2KlNZAQFM2UIfSEY2//XbsEWvHTXzlp2T6hZ+ejCj2+FwZ1YYYesWm7AkMkB5TlpjgFy0EORNf/NXgKZ0gIGmQX
# DATA tR+bwqaCWK3fJUYEH+9wCAoDzMcKc5UANBTX4ygK4ESk85UFf5OPlDIF88EN9nviDsCX/apRJAhHvIs6PSCHnlrCgw6x7ubmshY2
# DATA Fcvp5jcWLeM1VzA7LU//bCFUUE0xWdn01c/xHINj0k5Qi7jzBI7phVKFTEkT4jmPi7/eFJZ2BXG+KEWcOv8+U0//JKFyX5EM5mFm
# DATA 4iMDiuvk9/Cdg3ut9sOSlgTbaAVsajDqmQg5scQ3ryWXFyHdDf5nig+4QYhC7+6nz38p6V7/QGNVD9xMtehtA3aaCCCOpMmour0s
# DATA JZJ5opqE2TE4GR1MApQ8IePJcv/S8vIkd+AeQIfqk2g/EbDbmxIbv7uUkONELfC1L0ZchqPpM0qSiSo/q4Qd3IJLrlUZqibbP0LI
# DATA dLYXyiF7mXCFk2leE7Yk2pBzyWDP0blkJf1EqHQl7tacrBgzeZ74asUsGOgwaSn9q4YpWPaIasxnD0yjOlSO/yJScALDchwnjSy/
# DATA oVmyup2BNJ8lwGsSyOR1KrdSAh5vDkGviOlRCbgdK7XqgtmvJBuYKwyEBfVZhvju6PTVbTF69QCwObARlijQeXtUiSOqh/LWLEd2
# DATA ey/E5VAGy/5Gblz+bcuXVQXcvxiUCFH953fF17LUN+aKFHfwt6KJOdPXBv6jqM3JkO7kuLJ3WLxad99ZjKDZYVs3xmN6eEGW2GIj
# DATA EqBGgxAL3GGRSqvVyfD2W7Bg7C01pmYoDF8v0i4Qsw1cr00DcUuCFb4VMRewPDnbWqC1+57H57mMDJonUaOsXOEywRH/z2EycEQz
# DATA 9RzOOSqM5x+d7x30bC/iSZ2KH5oc9nny8q+11gW72oC9VOAffAL0h/cIn9pVFs5vKalwFaDhM2BNUY0gl3TUgboD3IN0Kc1x27cS
# DATA 3Cc4c4Sg9DQ3n1euxFQum2MuB+wUHtS1RZsfsFw657zQYdCgM9NHsSr5DcPWKshkLCUDawr9pOLIfR2VJT22MKcpRqXoK/qm5yV3
# DATA phhReB1c2SeJpQKcPcURVQpBaMTRd+dL28zjzUHGkK2oX9tAuHGdkiiCwsHaVUN2CVPXlUA+t1GM4dL5Pu7nX1kxMpzrwdOGom7S
# DATA 6TG10Hh74yeRbfD/xBt+QqpmSGNLTaprpF2Poxk4Q1SgkyYjANhikMW1AzmQKZNckYmHVoWteIgAnkcyw9s6Vv9qov3rzGWQPJDp
# DATA 7710s6WEMLdi5/5dVVuG6qij1D8aNi1QgL36ZEqi66p7xsPNvrPdH1KEzUD9YbCW0NN9+9ZtRINeVf9LXZdWrIBPQtWFXqb22Yn2
# DATA i4ofieyz6nhDlVwcAwITSVPtdBjFIrHFza91fjL++rlOQcu1hIFQ8l1LPND1MDRqLvTCXJx0Zkapd+kgcVi7K8ZQrWKOL3wtBkdD
# DATA +HlWOJhvJouzJ67qMr9iHM8LXS9cl4tJPgbbVOS1QoydEpJXQG7wOBCXC1N8PYsvirHl8eIIXmHYu9gX0wAMA8+kFwWljEKefUuQ
# DATA lP9Rrr4vijCqk7K4Am6YXpv0sZ+DM4E2E/7m2e9KCcOpRdWeDpLTt4ASyG7KuNFd/6w8qD1z5eprJ8qc/VXA2ueE5rO8vbWXetkp
# DATA bx5bX1p3VfW95ncI6udywenofW7ZhRyKEGmdUPZMi9UX2HMzIUrPscvjZzwBd08laOOJMkUkdfQNw/5IyTvkiaj2UlWq2FM/KARZ
# DATA /UGWVUsAw3sEv+APJvl171kyB7JCuHODTMKf5sslxZiaJkSojuyJKNzlzFjkPTRxV6yAl1oKHA58YWqgLjBjyilZjzZoYzBFaget
# DATA lV4IvJGRqf0QN+6IeGm80/VzDFDMdLBwMiDyvuB1LhlnDN0fOYRlxVngURXH9FNopeUvzzn3Z4uL6lEpWVzUNUzCJOklZzs6mFjq
# DATA 64Lq66CLnvvH6qQgyQL+agC9uRJpZoRRKQsm4D7srII8ESNnlj2gFOKEp5dVCI3suP2wcHG1uKDTHKB4FUPg875QJL59a2f3zdsb
# DATA O43t9Z2dd2/dvo4KfmrIi4ewCt/Z2biNYRHWoahfXr/qvvJr8eACD63jtLq0JD+qZ9KNyV8bJt3ar76ydnF1Kb/2N27f2tptbGxd
# DATA b1y/dXN9EwLy0+PRaJCpuoHUzIqk2+tbGzdMMf3Gr3LnztXG9p2rNzavmcKOIDUedrOCs6pm5WFr7V2uwmXqrXc3r6uerV+9saF6
# DATA t/HG+p0bsDRKyhi3w4Hc3Ni9vXnNzHWzddJBXxJ5ASsWXdnVtWJQ27sbV9+6dettJojGWxvr17HaKF2wQl5tVIhFZGLWkrK7RYng
# DATA QiF50ByN2sMehtT9LUz8sF1BwOk27PwixsHVKovfT125TTJB8ucl7AUYHSs3PTbK3YNPxvumPKfqa1STgMFIZYfd5lFWwyqnpKrF
# DATA +i/UEDJV1RCyqwv4ymYO8AkzA8R0AF5AE4wxnPttccCjH3Ip5lduSCOmOhJAVz/7Efx+Ob07vNsDJNeXz+XWhxCkWq9xBbx4OPET
# DATA 6z7NCcv5omyQdYBehz/IlMiSm2O6GTRPwXCtBgfWhgr8DcarrH1prbJ/aY2NaTItgvBEsUOOT3QkzxvXjSftvaILiMPv9u6xwMCO
# DATA WM1r7eFou30CO+dnD0bb433Ft99m8HnVE+s1/FRv4JePjYsK/uQdWPeN4bA/LDi2hYJ5UUp2Twf0Z7Aq9sR+Cpo99nNEOGLJpvgI
# DATA cwWQ5s9gxT0CcBgAgf0AfYc/fPYUddKknkVQpqfxFKZMmYcva8Gmdkb0NrnbMx2qpWeM0apo+mWm4QfNzojASZCBFiQarXPS7o9H
# DATA tdVlEz1sBQVgWLtiBzcRaISiBdXqtZpdJUmmUQyR8ORj/RHUdR2fCJyDu3OsYtAk6ZrYp0eta+cQjuj2lNxcGEWvSmZLYFQ7OFYt
# DATA VQZq/bWSy9QSYEcA0S0nP3LKeKb6H9WSlYsry6+uRjfoH9CpALwIHsHdz81pE13pR8lbu7vbO2WDmKNj23qc3d7ujTECsy6r3Txk
# DATA lin5dsvwv6sbb25uJdc2bu9uvrF5bX13A59WFl/Hf9VZGrxLrTTaqrodh3lBM8GAfx8OJxgMX1ktbbnocx8O5H7gJQTPsm5le+Nm
# DATA A4bdGPXVsXob/y5AJ9TRWyxWJC+4mSg8OOBLyufdYECLBr8sHDTRigY3BGs6i04NFUbawcMkeY/qe2fj9uYbP2n8+JXlH6rjWU3Z
# DATA +o3GtbeUxOB8qc7xzsn4xMq6C9/u3th5hx7An/dXGqvsKd5sKZoDIoaNVznpqykG37cCnKG8F8nkdAymlKDQj3QVFmxKAKLWGR0n
# DATA GWjXRjIpqrc9MLGrG0IhXVl9tbKs/m8l1SeZYQRqPIVViEB/WKislHRzZb8rkBO3mSle+iCSARw6IBP0YNgcNKg3BVWa1HLtYUP4
# DATA RE0LV1CfYlzjYZ6gr0jSpxgqDsxq0G4PkVj21S19qNayPzzhg0hTDTAwIb9q7rXK4NkTnOL74B/nAFuBfRECP/5RMpHYGJVqwcu0
# DATA 4RGp/oO0mHNroa5nbWCn3cJh+ubGrmJhsI+WViorIBC8paammpzJDE3g2TW9lOpm3QV3AZAc1P+HVG14HBeLebO3urwMbKyDuh9q
# DATA XrHP+4VXVlZFT1fcW6kDna0tL+fPkMXu7ZPz1g4fm/YRugkOQ/4ZKlcgQ8RAXlm33R4UKnz7oWVw2Yqds5jX4H2Ek/5zYgFdfkn5
# DATA L59/fEWUahSl87GkVMY1LUXZMuZI/3fKHwO2UhT+yqRqFGs+/uKUdwVzB8k64Fugji3bZD/zIogyjHqbpnj2Sh06whov74cp5RoA
# DATA 5J9kGXfvsrpU4bEpXxQnwHqu3O1ZRfeq1XpuOUfcPUzTlHZmcna2YFUx7nUeVpfuN4dLat8taSX20nDcW8KJqMDmhioTVLk24K7d
# DATA P+h3ryyc0eAmcklXux6nwhD0FbKSZN2GfcRHWht1vVM9+mUDBPucrwfDzn312v1W+polyKYrq/zvRSoCotJq0u9dWbCGgLerLOkf
# DATA Hl5hG4g6JpfG2XBJMaVhmyZl6Xh00qX3zfGoj15z5pM2bIcGYkquLa8lS+o/FeuDVktd3pottRQ/Ll+jk7kMkmj5Fl1IFU1mvc6h
# DATA kqq7D5qnWfDVbcBGGbaH5e2+mv5TkKw7ByP25Cs/OG73ygfDfpbxE6eabp8UIcnf/n2y9BAmALxlloQo8OjrdiAuTx0Rjf1+65Sk
# DATA o+Ur+v3RcHDQIHGFDpXk4vJy5r0HtjftPXAH/Etd9aeRIHYRSZAqmEzcYahR3L1bKbz+0oN2t1tGCIelohqNOtl6p+DnfCX4BAYL
# DATA pyp5JSTfHw87+J+lpKYWCsur/6f2C7ODw2E7Oy7E3HlK2vor9kx96qX68K2lavjLaYm2T03bN1BYJ56BpX1NU4411HuM/Ei1sIIt
# DATA oFar1x41UAFBAXHcknkKhyY/RKaBnpqKOXQPIQinm9rvqPq1tYvytNPb74/V0tKLy/DGxiWy6xTFX8Gp275gxO/CANf5mM37LGi/
# DATA T07uz75IXAEUr8VpcWGWCtztV8295uj0ltaKBB2jFAh4BFGE28c6mCIiGZuwuE8xRJWxQr+R7pquaf3hHp4AsQg51lf4SxpZzDAc
# DATA CULpqAmKpbuYly0FJahfJevbmyVnfQCOmt1JHiU/HjZPzVX6S46gk/QpcJpbPiGdQ5+WI7g2OSjuv8VAJ4g33FL35fXrN9V1yc09
# DATA 9ynLDx8B9DXc6T+046k+pZU2UQwxYHftIhYEmAYQuHleZ/l6pW7/6Ij80c7SljrW0C0kBQ1NmTPmpv2BeICcpYpRl4FHQ6GLy6gd
# DATA gUdYVD16JWUGCHG3fcH2QawoeD3uKSaYlbNRHzKzwMfcPMTa01+BglIH45+5hm/tZcx22ZbtUDMJqhl3OyedEdXT63N/z9Ksfwg9
# DATA W1leu/zKq5dUh9Sx2zIPJpPJfH5SzcFA8pTR0JlLS34ayc9HrqxmSSUrcrFeiknIsFxZbe/Q3LOqoqWpIqePf8b4i7U9tkGX6c5E
# DATA 5x6cdMY0Tb6tWXVJrfKSGsUSP8ipudUGA2PW6Pdqtum0tY+zqcTYFtqOEEeJYReUINEdHZ+mE8eqSibx2R9Not2g1wiDqPoxUhQG
# DATA PkjptZvXyztvbdzAVFgHkOiqfJjtoOiljn44lLtwaMLUrSxRHeh5jvkU1ZxAD1aW0WrB4gQSdUYGYSX5oK/TJTpYhqPGQF31+y3a
# DATA C5ltHg55SmC0BRXkQL2j9DF7qWYgaT2WTSlCWto+Ul25XFlLX5jI6Ap5fILCVy1VF7iTfapNLGBqjnd/CsO8s3sN1tHQl/TQiFSW
# DATA D8SU5uZZwMFRo5OB7HealO8k3//+mWNmmiTllvPw+tVJsJgXZ63l6vLEDttQNJkz17RjeONUf1hudgedHrDHefda3mRAO+q8sb7H
# DATA qwF0s1zO1FbBtG74i6z7gCdPWml6qvjvSftErXN5gCI6vWurbYSbCsuA1Ev9gt9e1/gfFHz94orCkcm/+uqr9Ao4Evy1nDug/KU1
# DATA TjFlJfdjfdkc/YFUpF9zZS3fOYttqVJqSh22hIzMyoEUMiz81wlSCkXnan7OXhL58q2C+V/iTV702/6LwEMj8mlNxADwJglegzPM
# DATA 5eVSoqTsyTQgDxDApqfnsk0YMbmL0taJ6oSsFI7M9JTE3DTqwpLt2b45gatbPb5/wzUKqZckjRohvqtv90T2QNrLdbqLQgZGjq0p
# DATA 3Nn+Xjg1SHOHFP3ivI/tu5iYEKwwSAwr0W0bP9Rf7HCevvsJuVHt+9CuzXLaYRvil17mI9uMB/q+hAyg1+zy2f1ysTI6VpeHYe01
# DATA 9t2CWMFRYVjp33t9ubpSLFYOMByqUPRKqFd5/MvhMq/M4jIrqxFhYNUVBviEEDQ1iHryUCF0/jXDIA231gKZGxkJF3yKBMM7fjVn
# DATA r9DbnF1Bb6ur5jRzD/03b13fuHrnTRjTybg76oD6ZnQwqC2DEMBEl15erl4GhQDc3Kt0e5c/l8atwTQpIC60BtvjGvSSwhrAuF5d
# DATA UjSyhF1f0q+qw77OFl6G+awuwX/NM1KxVpfc/DJe4xJ9dmZVhGFqXjV+6Jr2Fz+jKH/jqp/Y4W7yJywzQ6RXpemJpQIfDZt41dar
# DATA F1lwUubuGWGRfcqtDRxBunAK4W6c+wqjRFnwRmQVDhxYLy5ysuhbc8RerdUxF3EeY2kKcSi5QcgiqtVLS0nwjbprZs5H/aOlbDyA
# DATA 1UH3z1iXQ6YNVuMlmAcRvGLdYI6X8/VBf9jWfsWxzxE+2SlVj0s1qEiCNYzRUd2N54lonvAYIJuC9b4YXlqEbuviaxqMDM3m+Usy
# DATA 6mawV/POdstEkse08G11pbJ62fCtGHEunI/LkAEC9rfNZkgDD08rrSW2B2MhZDjTOdsLTs15a529A85Z4YMHD6TCmCkC+uixT4tl
# DATA 2Qv4ovxx8k1EUBk12ewYqiCIKiSPCN4OSGlemBX88qv2w6gwKiYSQ0WTyFISe7dU7e3qV4wqBl1QWwdzlFXETFP2jH94SnPx8DTs
# DATA LsVmVRPR56aY/MPqKeJ46KRPc6rI2MvGlkvvDEG69sNPpnpNnuviZQeUn4W5kKsJmSfcNzT2QHyetoly8gITHUJO4Ar8Z61QLE6K
# DATA YQ99oBvhrFPvOTEYK2e8trtVzdXyk0ZeHKNqpBN2dPZFKrJJOnuvlKPJL8acoO0gPSAKxT+cYBHBjsHMdyWwnPUf+KYkttf0uy3g
# DATA 7g+8oAFOIuIIrAWsrmj7o4J4rWpwQrRQtWBnLwB/aNgVf/PubsNxWE4xldf1TfoLvXRtP1v4W9xnAUHZNOmlPlflKGuP/Ap8kUsx
# DATA Z2J4aIIa1C8nBsGNlAlji9SwKUripRrMH7lGtk+LuXf7/6HTfz599meOIsKc2hhMCxm1I0FDzz8hoAKomSIbFWkQ1g/52x6oTaDo
# DATA pN0q7BVOyBEQzM8QAsE/dyi/j3lwXV0aOz3cDdbT2++mHJiNiZ84RvAmNsf5V4tCMQ3qBRJOQ/eI/jCkw78tqgE/I3Wnhyg0SVIE
# DATA OxitLv2swrTG/YEcb9fu7Ow2bt+6hSuCKnR98qreWgmjlijuVlWOCMOo7TLIHPJK8GQt9DDsDxs3zcjYQkVvIc5Tj9Msr3nGSWwK
# DATA /AFV/73kliSmHB0P222DkViGjEWY7QkPYG7xpHma7LfBNaDdqiQbCKcicUxcIZYEDLZBc7/T7YxO6ZJYEhdltDeSoKZYBerBgM8i
# DATA qMOoz5yikwm0ooFKoDX6ulGhUfwEmWppDPoYYTRTg8WBJmHosBJ4NJqpLwb7Upe0VlMqgGgbsDYi7ZmnF+sCvQvnVSSuyg/Ts5uC
# DATA 1C9MP/EsYnPWR2m4xAZJVa94YuCw3W0yHBoVNzugIu8aoz5tKIlwt3EX4FD3P+xkjbm+DXMk6+AB7hWsLRib5UGF8iCBtLKKL18o
# DATA g5tbG7iWcl3O4xXM8xFfgT1ZqHq4FuEuxl+abi0qIkYf8IEYe0fwhY/JGP0FKnFDxh5Jsamu67R9b7IeDySDq4pYAWcJfl9rDtZb
# DATA Lf7r+rA/wELDzn0lVoOJtu6cxN65byII0ZEjrMsHPG8O7INGwgiryRk66DYHRSULqUs9Ep+dxevaujrwOey7iRgdBS+IH5wlA0aj
# DATA o1XVWePGE8IiQG/owOF+wT/msMFf1lETifmUETOflIpquvrkPSVZGIXJZH5OYDeBU5nfRvncbegknDPnTlGoxcnzC0adP0L5xFRQ
# DATA 1YDi4FcZ32Vwk8R605xrchWv0qDs5RtzGlHlQNSYpfKJFgyVNoiBZ/0uLUwkOBDyq5pErzEkCz/P6/wOIQIMLu9dXHBTjV/PNFRw
# DATA FxcoGqswEyPc909irWThnFAaxfnxo2w0jHwQ0pnjpaTEFkSGRoEhTx6I2Hn+C8ajZz5KD2EGvnr+icNa0duzlthqhkIaP3OAvO2L
# DATA ZOW4/dBJ1ns2FddlhnYEOsLP4c+inb5SkF0OdXqmkmbSOWlJg5g/xCsjUY7OOldm8pbdlulNwigMK4c3kUuClTHVutnllAZzOmq3
# DATA llLXD016GcI0qGWCIAYpUILrTo3PHWylinIFHeNOYxBnItcXzt2QewH7Z3fXBFRjURvZXDlmDzONx/zK1KsP3WsaJ1mdDvKgJT3y
# DATA RsbVDuAfrVS9hPLydfO/0g8n/yv9YalM3FSqpmJdkRCoqcOqeuLmxlR1KR580AXn4C1JubrbHG72DvsAw4roj/xbOC9kMETlR1tJ
# DATA Xe1RE+xDBfA4LSUQNwXZC6xgmv4IcbtVR5oj1Q0uoXrX0Htc10KgompWloE2ocoKuOM46i55CIjtgPO6uIqEj82oR5eSRXkeO0Bh
# DATA jHyl454k0jhGXbRbGd4Gs+ZhO0FvOUtJz19UcnsOYUjQkQUzUWBxbQzUvsmbIBxQOJ9S0E8ciBYaxfpMxbqk1+hRbwxZr7+dhqXy
# DATA vMYzJfBDqpGctjnkEwsxjhwBkY6gnQHqSvBKb5brpHM0ZE7HUgOqig9GdoZ4bqlAaYJMkhxYnQYuZ21VE8jFEiE38IuVZfU/7uPL
# DATA L798FSYmoQAAUjV0+0cIGo/EwhlNAAUTkU576u4OhIO+6wB0eR86rbrRrqjKFsJ03DYXkk1ygIdBLVle0FFfsgchWVEB/urv/6wm
# DATA wyNDz/A9SqHdUXu05m9iDALjafFu6230g4Erh/+aeBz05UItWfGCjCgJL12AsQoCS6UrXoiRMsbcONZEw3YNv1ZCWXNfiW3jUZsk
# DATA s7RSSQkrdjjK8o6LOz3cqL1wVyOYrMbmwG6kxeiZRr3oZCQTimu6fsxIhnrC1CMm7uKUXmki7sUYDtQT9obrp9jYZNlqkvmdoWJ1
# DATA QUGayeuBxeYCrqY3UoI+zG43WubYBmZG4sTP+p0eJhlYJF1BbBqtD31lBVP6HH2VGSIoBMUBFKm1bBknZ8p48aKIwdYUxuPvZM10
# DATA GK0RRSVa3+VE3MtIGKI9CSf3oE+4Q5f7ry4vQ7AIIOlkHA6CgN6N/j0rL+jMSyzxCbUnrUHlLV+Fmvs6/YDj9ng86nQrrU52rzHO
# DATA IFsbr2blENSlP3Io9EJyaS3v+DUzval2x+Fh5wBingDH9x4yWSVmnSBb8je0zfejqjg5lfk4wP1KvQpHQ98E+VRnEqREkKsvT9T+
# DATA B19Mt/LvAYRyd5xhYQgRhg3EKNmKhsdk2pK9byFlywFCZqtY2DF0ueSsLJ4F6cP9FJl7fzwajCNpx+wvDo4VARRw/a09odHhV1ZW
# DATA SHOI4PMhMZKemu4ueaRngqx16fh+2+9CeKOlHG22ChAkrT8rJZdeeeXipfyoW+A3WMuskOPISj5QMzYajnuwGq2cSGKa0QoD4UND
# DATA 8XJmWsqU+CqnLNd3qOjjOAIZ3s8qh9lp76Ag5dQk9voF16qIJ5i2Jg5OY1KPpS4RsnF4r/qb3BNIUYBuYYPUUrOguwNCbtNGgfth
# DATA BV0V2Y2B/QfJWC3OhNtIj1A5WIpaEPRuv93c3sDn7eHQf87ST+cEw3LAAtMELWplF54UVsATV4rf63S7VvFKq9mm2BpgW9ZzvPoK
# DATA AAlEhaoiWh/uRPYHYf5T5EnpBQ2vFFwhfRh12JdAguOhx2WkS/xywQNj00Mt2Al/7LYrGKJuvW51mke9vtrqB7AsVmHVFG2ulUsX
# DATA L6/5iRpK1JVMiY9tdQs8cBNPOZX4LWo/FikHUCgFC/jEONoRrwRfu2v9cbfFsNFKxEJRGZgFynj2GBAykPm088a+BdI0+qkYUW6j
# DATA JmMANdfsxGUEVJNea/bw0qEOne4pbizr7Lli8qqZLSJJIVqgPMekClBTeFvShA44sd224jbb9IB3irgJgC+KNUoB6FaNdm1iReI+
# DATA AJwfmzbIJRKbGfSBauJnWw5l2a+CNSRWk/Wag+y4b2+KAigNVP/HPXs7q58lYkxYqJbDo+zQ1ZGnyoii33wvWU84VE7I4qR5T90X
# DATA 6cCEGD0wrXZJdEOoik6bqOjnYyUuQdaQdmcA1mKu76B/3EYERhlbJbmt5g48jJN77fYgczPqmZWnhBmKDffHgIZZkdzoGn1FzUHB
# DATA Zq78DuKEeaCinKxD/gZ0DychTIm7asTtBp0A/BDQPuRPb3OZTjlAUrozzCyKVhI3T7+42SL4oaBniZ2CmS2+MNW2Bvr2uNdDGSiS
# DATA WojS2n0K6jn6E8EjMLVOTJv3laMW53xoNio6phMind9HecGgNIgpyUFZyWwVRm1vXavG4WeAYYQPWYw2Xgwv2cpqRjp6MZspVO+Z
# DATA es6XeNSb40fT9KWWuj1yJ9C3AMv3AlM0QdKjTi93p7pyBgCqYsIg1kUqKscpp4esjqy77mu0p6ca541mGyafFbI5VmSqr56XyzE+
# DATA q39BfO+P55g+o8cJJtHOGK2mqcXA6RbTdPZZIKO5WniooUJ8EI7tqnfbuE5MJjNX5l6Lsn6qGxVcKMYdyIuk+GDS3M+A23XbR02E
# DATA rhC0QlOZIWc80Ei0WoKoNzhM1Z94S2ORJaskW5BHKMkeoOkauWUXAQYr/n1ryqmvzVA4UJI0MCbLoQfnda7N4F8os8mntC/IqG/b
# DATA oJ5GF1eSmBHO318Y8uBLSe0RzZ+CUAmUVeE3Gn8rX4Pn5z3aE33kItPQ8Kjb3y+ki2nRo1jQ5XEmzkqXcNNi6ZKisGs62662crrp
# DATA d4vTJpKtKgK4BzksHwEoNsFCQFLLv2gYNrD9PQ7n9Wls00xRKWqtBgxao8NZI2QVHN1Q8zSMqL61TQGWojd3wL/PJQmhiMfPf/X8
# DATA l4JKFcWkAxpDokDfQJchexOAA/Lu4sFiySxMvZ0fUDrtHgCyFWI8dgr3RoBmh02jV8Qs833RhsHGiR+S2F3AvyScw0+r6Hnm6jyi
# DATA kW+cPUMyHdylYOMwuqKFpAjKlU5/nKVF5/GQsiKfBjuKUMwIW19qtg3o9D6uI6Z3c3qaMFwa7vka/+IuQ+JAtLy6SjsEU/PKEh5b
# DATA pDR3yZM4tGhxaW2CFwqocvpG905CTH0hfA8xvghyhTJiKPb6BTlJ2cnmBZBF7Z5P4VHYVWcygMgglgIxCJbUq6WHw+YpZ4aQRaHh
# DATA nxA+JnyyP+61uoBsMbejj93oS7MpG5GPacZyJ+y33qifyJgptS9Lq08l8wDlAbYPIchLoCaQswE7YhxmBPYSb/nJo/3EXVjVE53V
# DATA AFFqOfus38E4/cgGZEqx2KzaFHaGSLccSb9TpypyGtugcfZpLHNjJa//A+XZBbQ4D/LT0NiC9vvLKBcgLDKEwlhpC9cTVLcpMQwF
# DATA DnUt7th6Z3C8Swb9B3Ct62cZpEzGnHLNIVkdeu0HVmV0B7BciBJEys2OUaJ5cAxJF+Q2KZbBZu80YdUK+NBWLIUN1dIhJCEL2wok
# DATA WyUb4PntyA0otBtZITg2LBcO+zP2ObcadJw2EGqInDbwT/YEBdUEgG8y6nDVNzBgCAYqsdT0o+qP0/9llVuN29dvbd34SfIe/RLB
# DATA XD/YuvXGrRs3br3rkuQoxlu1VtQ06X4V6EisL0llZX/JoL2g0m2oi7y6HAtiL+czqgYXxa/l7M72cJ2sPB9l1/vmpMlJPtLbUnHy
# DATA v97/HcoZkvTMzleS2GnnBYNQIlJRU9sW4ZGOVZ3DJ98FrEIoVAXPv1vECT+lQ4NBkvZ8YGhCxaJLoXUEFr0UEfC6hFGOLOTBA59p
# DATA EbUuxLJxyuQSHlcu5kBWabYoVJM2iNlEluUZ23eSzFspciG3kZuAnuJ7DfesLuS3GvuS8afUlRCZAS2+oixM4PgFrjb60D3/UHJh
# DATA Iv24OWOf/c8peQlNDk07q64X7obROXillLRWkDlocS9N8OuAIdndkHjBej1WK6C+6sPpT+T3CDl53hfENvTLmt4YsTE9ocW6k4ZQ
# DATA PzdzT/N5AUwdiR3IANcVFMxNKqEvEj8h9LMnVzzYOTyIYL3kEuglH+SEQxU2klitwwzgh7iDP8Bx/wqw26yTrZII1h2ekqrUF5h0
# DATA 7H3S5wimyKOcpIeKgWdJudsMcySQ4+ZfVME/ECi9zpNYwSweOv33B04GQQx1QgASdoh/jORE+QnF3e7Z00rYYEq0aCcD528wGThX
# DATA ClOLFGook1U6GuUhzNDw7P82CLLqcuZ602IaRFVlWCHFuIe1QSefEFn6nrmKOMN6hu0jdZuB60F80LRboQp1dawmB63oplMPE9IO
# DATA S/aoZIARA2hKZF4PW2ucSSpLDCSNb/x6JDLBgESUIoAqGkejLNlDKqOHI53hi8K+SxKhXaKg6hLPYonvavAHxEa7UQwucyOXnnjK
# DATA ctwddo4mNDpG5kvqKWrXsgEJXSxvsE1+VpL4Qq6exOQyj6cCd9xokTH7qhPJZ/x7SFxM+QFJAMcN/sbmjY0dmOFA2LXyGof51z0s
# DATA aDtttAzZAB2r2XCPFd0orBNgWIPzTgEnvchJOfgsQwTd6WfO81+VgOv8wiRofmqnY40z8jQ1lGloGMmToqEFAscx+BxQ7p5gw4E7
# DATA uKlFDcDXFWBsE3xtXWHEGGhe6MX3DIPYTHuI2lrUS9An3pUJp+qCJOqVntAqmiocsS4vUlrtdfRxfh9xo2zZzRAFCjM59RbdRS7m
# DATA tYPHqZzliZtGSoOVmjZ0EIE5zymctO7LYbN7ly8ThRMK0/GvLhXBkTb3TDC+iqdlw4R0/uBsdngzx6kIOchRe1aPf0/HM9L8P0Tg
# DATA v6osyBy156KJ6XRh4Yx5ExM0MC9x+AQSNBGhFWrMk/jMTucdbMS14OxcCuL31dFc4Ust7+riXvXiqnuyzNzDgRaI1z+6nXmBiSLG
# DATA PQn3baWzKrUIIBjHOZZ7HnqPLytReqzOuba6GXXuJreGaEFuLaHsastwfyENln9WfMT4w++jdgqHluBHTyQz/LOnocworfworPG1
# DATA JbJZMdxUeXGJxWigUxCkPdkymo3+2dMSaKO07o6+gnxAVjb3J1GtXNhZEIR4Pv59DnmUUNKY+uUSP03wTEs6Ql5P+yNOmwAiBpf8
# DATA s46qcpCSQzH399aF4wnfYB6rvmG28QQGjh36jK8QeBMxs8QXQjHRSxZxbfPxtHdKTJBQ2ue/kLsQm9ZRbajlFCsdFsswwivi0gsS
# DATA ppFeSJWDME28a9Efe4i+oEf4d2V9eDSGprbxjdYEqR1bazSUDN5oFK0v4YreaPInhbQ/aA8lTOrguA96kRpj+mCupxRDyTI0NHAi
# DATA XErBjbAyIOOUWdzGb+y/dU5djBNIGcmnORTUO0z3BX8fEe4d8a8UMZmz4zLtFiyLCXasBw5XAvSY4CGjbgbPuX/oj1IeD9TJSHHN
# DATA gDjVGQnYD/UmG4Hi3HokqH1lxjTAKeg2e5bfAzbI2lHvsThT2V4SQ3bG0TXRjEJDZe6APVk5r7nz8ZcyDnrrTAYmo9DLZVAc8B6E
# DATA ekNxYIiSTrnMNrXilbwCbKLLLyBuQ1ObMRdBm0Y9ATu/DXO6TG1FEKOmdJYS+ua+p6XOf8+kRODpU/uCGZOn1DRkpySIzBweZTXQ
# DATA lE8dm6KtaR2jxLdmNXJLWgomvfrTGjY7hWMFa+mMniKZqs/KkuayiaayWopk3MAUmdObRDyy/tevA8CRyicEfGDILi/dRN0aoikz
# DATA ZysMsqwrwMwXV6Z+x6BMwaeUNWNas8Qb3SXJbcuvHkHopzOFCHOec/GdT2m3zddLV0wNuryyPHPr40llVlnniUf9CuNR6xrp7ey1
# DATA PddMA2Z4/ltOEceNsnc7l8V/oHRmYADgV0Uf7joHCB/qRirxUzviTQI/Rm5WFNixeJV8SlRdDY4Ynfy6Son1hEJ0p1fvn0tVLypZ
# DATA bj52jT5YJjoqBSHMftf2HFg/SxPQ7jX3u6gygSyk8+GMIJqJgdRQVLR+44aLP+KYlSQvAF5QUGXnvB4YOBX0edZRAPZSAxAZTBn1
# DATA 16Sd4f5H0YKdEG6nExqRzowiJ708fNYCgBFMagCjmzbKFiHEcJz/fLMJBu9YrgSjMLSWX5s43UgEvYjO3LFK81RRBKVDp1IEm9jr
# DATA p9OJ0xZSzfTSgwa8bJP7e8UgL0ytz5ckz0XsDAqRBy7CB3tDHVT0PT8olpJYF+ecWquIOPtBB6YPMyYdW35TER/8czKNqXK2dR3j
# DATA YrbjvhRzh32eRXQvFla6mCyDvKT8QhJ+ZuHYHB7JXBN/8Cclvd1no2ybmmS5NbvgB0TrhRkz6l2ObMKEFw1+YXWaexmfwbwBTe+E
# DATA fx+zFeok1jndOM+mi1yc/A0tZve83WLvP0oEg0gJXN18y4xPuDntLchAS6QyLHmqerOpzWcmnsH9lNc9zIRgOoK3jmKEW/D9oGG4
# DATA hvnIuhE0nP0ZOARPG1opmTUCz8WR3Dw7vcF45CCDoNNF1dibQEgn98Kq4+qFLydRXkYxP4aTTWF16OVuocvnkdm0C7yTcg1LzUVB
# DATA c23Zqc3x7p2PXC1KnWub5qobwn1LHXDwd7Go1Q1cjJK1BblfM0yaqrpZvM3VLVlrQUmd6fm5WIrWllWnUY+UKsw6mi3E6ygbZa6H
# DATA 9qcZYw30V9N7yKUbXHpaT0Megj/4yxndMipFX+QpAQQ9Is1IkRhpnncGOb2B32d9NuJPORmF8gPk6am8wZeUHHdwaytdiQNCw21D
# DATA DfxK3PcIBG1tQLGatcEx61E5znIsn3EsasXuVBKhnauKFabtTC1kEqY5/SCc2HBuQWEwg15CBUPVF+m1Oj3EGY836XSxeJ4OiKZ5
# DATA zj5IOqhvuhsz18ppa+aSaeY5xwV9ZtMoYUOT+V6mFOGGaLsUB2CRyTx9YIB7swazBLbOCSbByk5NrLX6u0IOND0Q1gvLFhh0A/lr
# DATA o2HtMY6WLAZ1amR1x2losER5G6ZYd62AhXlQFiHQ9HP0YsOMWmEcku6I5M7EH4VBSTJ/OMSmPzNdpbA/FzXlivVeh/e88orPDlUZ
# DATA x9HKSXsesgMXjV6z4hm5dTUC8AwSIQNUeLoIW6YkzHMdtzqNhX2UTGVvlHPBGo9TMI8FRPKXRV7YzbjpJ0uo/TGN9vr2u8jkRhfC
# DATA fuhkAfCTPHydE8qtYgNArLYhvJMSRcyoZo5T+MqLnYFirHQE5iCzQSB8zC2WiMZO2ynKCLXuYFOIy512WEUvtb/orMjgozYN0jnA
# DATA J9X8YdZNJa0GKkZOIRRjHkFZO+eQ80E02ZB8BaRVpYSHhvuHpWgLVt30x/arYkw9Wk06AzXDQ0Bw6Ay0VKvVKZzp3o4Kz5skRJpc
# DATA 8D3/A52yVO2AjlqxAPhhCRHkQ9j4vBgAX7hQ++M+5+WGWzbFBVhoLU7CEFODFT+Qf5VDe3x1phS7kJN/RWwWVU/hk5Jpp2rx0Em4
# DATA ZGzjtJFPqrFcKlxuPZCgrUpmS8MLC6rdBpJSo4HDbzSASBsNngAncIccMhYsOJwQcAVwcRAvpTpN6JA9/q/Pf6k27x/I+T3Hu2em
# DATA Kzg2p/gLJmgDcYaCyS04GwSH2TnNRu2TDcqLaA+i8A5QBfa+lLzdPuW/IH8H/3lrh/9AJI6/2bm1dR2hdvBp0Q5K20TVDGaR6PQO
# DATA uuOWIJ1haoismvQwsh7HnwzbPyNgEc46D3F54243gQYq3/L0VZJn/2ZC9p5/TLAcDJOgIwdKLlLHryjk0eLLFETg5k95/itAlDrX
# DATA avyX//zfHP9Tm3a/Cwex2pWVwem30gbE2F9aW8N/1f/8f5cvXbyo/8bnKyvLK2v/JVn+LiZgDP76qvn/Q9f/5Zdfhn2pmC1ZhiWS
# DATA ECP3JK0N6fA6AEE4bHfbzQxAkyhgdaWyWvnhamVhYfcYXILtgj8fK4k/GR2rYwfB6TjeBCFFO0eQJee43R1gWMsxcCOAPVRv++Oj
# DATA 4wUspO8nye617TJhsh62m4B5hFZZCLk1feRs4Mlx835b9a4NjupgBG1VVN/aQ4zmbakTeh9OZsDt6vW1ZfvAPnMQAPZh+2BMOAKA
# DATA wwUCKmEiLgAu76wTLmBH6e6s8RyrM87udPodMTAn3OfgZ9l/wP5/9dIrK/7+X12++J/7/7v4XzrO2iyvp1cWFtRGyEbJWbI97GQn
# DATA zWvdDt7f6VcywfgI3NaF9K8H+HDpAMukxSv87c8ejOxiIN08aO+TxaKoW9i5dmsb84rcwhxWiAv7d+3CHuUEyXDnVAVd3Pc9zaoA
# DATA IadkXUkpzKlEAhd7fp9V2S82vwDcHFQ1dejh4bhHQB/D9jiD07Ew7D8ocgYUSdfXf5D81V/BPxVOEOOEXtsNoRN9qkobtRB81n44
# DATA UBO0PsJPeyCivfde4rx4DZP3XYcbQLEYfJ8dqDtGVlF89QhRMmo8p/LkvfccEX+uby4kKzIqLsoCZ+YGwuB8Ft1OcU0gip4W8Ouk
# DATA 9lq0KvxdVDM9WVhoQrB+omdc3Trvd+BqUyDqKmHmDsmCJmsASsCXlv52b7n8w2b5sH52eVLWf69Nymv6x0X14vIPm/t154n8vbI6
# DATA +f5SBfKsY6JJmH9Ib2FNHGRd6B9KDraXSGkGaSxSKEyPZe5+lFxcLQIaqaIMWDeGitzsoR5Azik6YNR3LbVpOk1IyHJFsPkU3RAt
# DATA Tacku7z41MElDfzPEpq2SnPQwVyaWQUQtO70Oj8fq2tk8gDOwara3jjeSTLhxpeWktvtbKzaxhxDSRMP7DJe8QTBqyR+HtAc0ugp
# DATA HsKAWNHBAEPVw2YXYCD6B3yOHibDztHxKKvoZdMdVmT2kt5f8rQoK4yT708l+5QlyEuSg+Nm76jduiLGT5QGFP2M6Ppjx2+TlzAN
# DATA lTKydNVyQu01M4NqQXOmEJGZYfowN7rVQ6JNWLNSIru2ajYt/KfS6z8oQBDCynKymFy89Ir67+VLa3jOAQQRbo1qslepVGgDcfyP
# DATA sza7IEL1u63kaNhUw6Hr3kF/qEY+6EMeBkgBCJhtYyU2qXVAlGKN7VZRawsihdTWp9yFTaCe5oGGeEMcW2eRQQbrIJ2OaKlxjCwG
# DATA xRZU/p6LeVjzSCuRM/uiAyHaPYM5n5RwJc549qzJm0ycZWZmrY6kCkichTNeMnXmDWHZqsh4AUKlCzFQ69ubVjhMp6kW8yZYMQ67
# DATA /f4QGSiRQmsdc+MA3jDmp1zBxdQfqu7kcPjXkzPAx2uCVrwKgNLtSaIIShUMWpKPw4YmxWRSsnwzgQmV1J5udo/6asMen6iRvLUD
# DATA fhpIQ1OY7Bv94SaxpSi7BYDRXgt1mDbnDR7KhjroNjsn2RUbKll1i54C4qhaBfIFMFWYps5092E78ADqagBqKxwAXJWqamkxWU9a
# DATA ncNDQmJFPT0ibiqWc09RvGGrkDgmU2wM9qKQcCVZXEomjiWJ+6ZIl/5CgzWd5UAL8IKPAH6PfLNmnwPWCYj765s8laxGnf1i+P/U
# DATA nWOzfuH8UFfVHo3eMfa8OIJPUaf9CQ5nqx59RpvaJuFOnHG+I7VSB1B8rFB2M0xf1RqrpVFMWqCDm8Oj+5QasgZI4zI/NC9UO8C2
# DATA qX2jxJAzlygjM9knyRJwvzF1d4Fk3tcrVNU7pHF9vULi7uuVbNCFe10lBbTc5PXXIfnQa7XkVdjjgapZSbGDEaRXBHosaNkYgYCa
# DATA g8ESqvJpiNmSCNb8UXlwlBYr1Jvto2LhLOqsqAbRIyS0HSTMqp4ndRBW7JTKJcjHVU1WSzPq2SXw4JudrpKNq4r1NJYB8rXT6ra9
# DATA VxfpVVDfBLgS5Z+nkavWC3ndKlayNqCSbjeHTUVSFHtNueuLML0pBv0dAE9zWwIOCsmIFLUraSCCiYBN2/eZAq+1TarCY1yEKV8C
# DATA uc6OPErg6QCb6fwdCTogIoEoQuwtcTJYhxuiWOBn0xixPU/GuL9z5+rOtdub27ubt7Yau7fe3thq3Lmzed0tDkm5yQGgFICzT6nu
# DATA 9sYd1WWs1ChWKyBRFEjiUvvIQ5UnGwC95ThL61OcUtmAuM0Ud620aSrz4FeffQaPEOwNbPM6YP4fLYgMNNR9jkkUTQh6EE4f10b/
# DATA 5tnv0NYXB5LzwU8qGEcic/ewM7qGxvNkRR1L1kgZVIzHyoz4++iYhtupQLcd2uFwtPcpHdKZIYFSjBpKck+eXFn4DvQ/DbP7v1FV
# DATA 8HT9z8orl9Z8/e/F1Vf/U//zXel/t1GOMmsv3rOYkQLUrGrf4o0iUJ84t6x2S93AMG0ZW5eAU15ak1+gCJK/+9kCYkaDj1C3sy/m
# DATA KPBOkCLDtvwFZkX9t04dIE9G7ZMB3O+owvFQHUn7FMYltYIrCBzWC7pqylTLEeHkqoVesujJTBrcw9Y8SIUCTGh+b129ceva20WT
# DATA iQ0ACVuUhq0FMcScfodysVn2TEJuRvhCwG2m915SFwu+DApVdhqbO7c33izY2L8OGLBkPIRUHrHcFsZIWUg3t95Zv7F5nU8VCKl3
# DATA 4XI81ExCSZKGQCxm8O2zZZwqdYC31dNCcRJFJ15+9dXirB6ZnjRuwml1daOxfXvznfXdDQdCG48mnlCTuuQVP3WJdsRbcBzEaeXx
# DATA v07mHHzCJBIt7KSksFwR8C26QOBSdPUH4ULMWATB3idyrQRuh9xpIWPy4yE0ULn7a9+Z3O6aktJjinVjXHgegfyGQawur13GVHt3
# DATA 72IaFrssRPb1h63CQRH0YRfhEf9UUvrK6qsU0mZ/VZxnOrbXtzZukDS1QJnd0ePETtKDUWfcEbgRNMejfsThQiaTYF58rBm8UfpQ
# DATA UXbWDJ7NwtniIjs9SCgkRkqgF4UT/jgJdq6pjuf6BdJmxGdLcZ71GzJXW+vvrG/eWL/qbGOet4wiOe1WOTn9Tns04oT0un1+pVNH
# DATA +7VpQHFkDzaynG5O0qgziyhgHnBEixl2WhianPbADbHooIVjG6QQ9XvbPGmTcyvA3MOuhozE/kxL/2LZNtK99fJPm+W/A/Rr82ej
# DATA Uq4r/qUIdZKSYu9ck761sfvurdtv50y+Ic8khQjh6tKSZF43GbQAPZBJFJ235IftKKcngxcI5P3tW7fR3ZeCyrUTp+2xZLWv/4Rs
# DATA C9gPex9T1CYGMXMf5RXWpc5TVYWcqoY1yDZUbyp4c7PXW1WGcCQYM63ZDBQFUsA5UM/gt+jm5LeADsrvn4/blEEFfhwOm0cofOjC
# DATA 6sjVrSLYLrWGL+HwV7xh+UVYjjuwl2oyFh0ezNQ2re63dne3d7jm2xv/9c7m7Y3rqXPqaJ3t0JB1SapWnH779q2rG8DGlJhFegtJ
# DATA NasuE+vj0XF/yHfSapJeVRdqxWYQZcq//r27/s5GY317k04adb1Ax+poKT0TjGz4LiAbagomxRT3Yi/9cVndXh40h612C/5C97FU
# DATA 7afKsvq/lfRKvOT2sK+4dT3Rswq3JU9rCaSOAhq0R2Nv7uOK4g19Hf6+RihIXQiBLukMcRlpUCGOni5o+F0F/wvlLoNWVd3IRTXE
# DATA qjVUrmdtrV87bAPjmDFHjESr2CcPFHCxyfO5muLVVxEl6KKb3Sp1g36QFg4NW9JwpX9P7ElMPxRL0jyADpBeAdSuIOTVlgFyYdy7
# DATA l9X26vAC2DB1u0DDwbdokZHq9/utUzWZ8PmFGr5mU9aVzmEBnr62toiZMOA/xTNn0q5E+iUVq55NqC+VAaQuvDoGhW0F5PMCPleX
# DATA 4YmeZnRTq6F3GuXH5eLq7YGSg6miYmXUJ70WSnNKmDPTRT6j770nmlr8/VKtlvbRsoyWOipU0UvqldYvrM+iU28NcUHvWbcK9WIi
# DATA IOPJ2UFX7UEhPqRHGPtkoYDEXSjWXtPELMbuGi0bcval5qCzRMbwJW0ML15RAy9w/+WpuITCCFg1XYwMQGNfXJFm2QAetppnKre+
# DATA VdVntfXhsHla6WT4L4fJZ8XXxbDO/1b4X/Wt6vxL7kdQTzHWXbtJ9RmU21uuv04a8bl7vJRewJDG9p3bm9ckKEEqY+26YjjFQlGr
# DATA rNS6+PoqS5dEvpEWiJqGPX4EKGdaOwWlviQXSMKx/pSeRjVTeDiUElUGkdMgdQPlgyFdmGkAAZ5tKElMO+PpvtSU+Wqr2soV4DLo
# DATA v4RXBlVgv13giAhzD+ALDB86iq9QyHJJHKxYJMq/QYWXDG7DvmHgo2mH5fb6mxuNzZvw31CeoiTnfPWv7LbhYt8cnl6XEJMCIV9A
# DATA mkrJqIYUgUMu0xX8sN9VDNqBXpdQJ3pV5BBqUYlBdJbpMAtmpAJFZOw0ch7UbPGJdKSR8xdLOWrUmMhe4JVwEtC8iOAeZE5AW1ik
# DATA 8vy7CF3/fSmb/7REfyrIdZscgrGsLEhcJhNiHSGD2geYSBYi48qMUI3u2b37RU2Ze1BlXeDLoDj8F0UlD7wk8ODHlsFxsYdihDUS
# DATA daFRCzss6IGY20pxvs4zDHa5TAh/5fJA3T7wqtNmBEAb1It6kY9EkTcH+FwtKBJYaiaBt1x0LsRHXbug287qVnbOHf2n75Set2WB
# DATA 6tevXdvY2Wm8oXYsiLeUHQ7v6cR2QE9o4FQwiUMe8+EWFcu6TWet+l7x43YLdOz3MU89zwlpH68k2XFzSN4fCWWyUBzo1Mq+CdzP
# DATA coCnXD5wg1gwOfriOEec+8rFNWIneyV8xzZ/WrVGlkb2vSqAA54sSFIKqMt0ClgOJiTKChKJRd2wYV7xWx43YSsJTkS0ov7oGHC7
# DATA c+pxU/PwXb6U4Ecm+4c9MRWoCWDT5ZL/kk7nKHPlgFdgLxjwi6A+zlJcKjUZZ5PJgk4hDwOqeukT91LrIowXhrPFRWHFEr9v35U5
# DATA Y57kHNGfgqZhcZGWbxK5LFtTJ77BbsUEbXGWosOU6roQdApjV7/hn0kpCcimxDRjjkr/3qie2b3m9w3KbTV7C6rzUvQQNyEU+M7W
# DATA zp1tUA/ou2aoCYKELjaClbwl1q8/wji7mLKnZBCD5VObLMJALcraAkcDSc80UtDqoKZQtj+CbpoDHFAqHS0PdMjWM+lDyWpRXu5B
# DATA +Ji0bA4reu504KWax3/mnO5rt7beuLF5bTcyzfbsYoTcmTrbRqDo6CpaoWy91HxVvrHmvTkaNYF7AXxDSBkIx5xy7V6eVGsepBKe
# DATA Andk8jLs52RaAJzVMXCgLUDNeNFT32aFvUXTJkxysRjsZj0EDDPj0o7DCELDEH+oO+mYkOEX8E1JfAA54rC64HIvTZyUWYcp0+It
# DATA ai0gkR7aqyr7l9bYcoDf7aUU6QA5lzyLAgGNk/chKs34A+IJ9RxZkfoEbZbkA9zb9aA6ztz4nfn/czTpNx4GNN3+u7q69uqaZ/9d
# DATA XftP///vzP67c9o7UHfvHhgLITiFPG1cz2NKbA57qGmnvyAXPIPRjfIVCnyYdOThyLLu8hNOnyjG2MOD3qgrPwDrT30hP3WU8Tdq
# DATA Q4YL/4tYi9/e+AkoKHfuXG1s37mqGH3j+q2b65tb6cL6zs7mm1s3N7Z2MfIBBRHIYTFM/7bwepXcPfaSu6P6heLrwef4YrFWWfw+
# DATA JPduV26CRe+g28yy5DpuRzpqzKmj0cvVvBBD7PWHJ+CMxBwr19bHh699DSfWyFY++jp5LXllZZX8KtkpC1KF3s3u3v3B69+7+3B5
# DATA uXz34crh3YevHtZTZmGBFc/uekoDbbBqnY9Hz4zAPNqyR9CT0BhhxVvnKuXntCUwyAiZC+CKUkrW1i5GzRPnHyB8SSPUlVRID1VI
# DATA O61eM9XnSbHShZySbJp2budOoD3/WYDqnGhjQxwWbgvQR3hsz9t7UAkATWBbYPV9Ba25aUUn4cbxqUfwrxpYi1IegUskpC/DbK3m
# DATA LzT4eSmLQEXd7Ra8nLRqxyw/FG/YC+/BX2rfpACRNBwV+Sox1D2wHDGD2hG3I2xhj+1+qiX+E61+l1Ym8qb4+lztvQDVc+JBsVXt
# DATA VcsrdSFjykIlE4mWK6R+eSfr0hVXFViWtWValkoqlyv4TVdAk9DIGf8SD3y9/FM12Erj78v1C+rRkv+suEjTDrmmzj9SFuCQSsgo
# DATA YjnciEvNgIJGHLnNzs2IjdvcLJJ7UTKVayQTYATwZJ4+q9vR+htwZd99K41sv2/CDYj3KAC6bPVHbwDyi7dVwbuGZ6Iac2DVTg56
# DATA LN+qf1Hh/A5Gy6trnDfdftsDaCZYjZUw26opdX7fodXV6MVsvvXFtHDNUdP3GbKGcCFZKdqbDYoX3WG+GG3xekJ9ajP8tScRwebo
# DATA gv6QPFPc7SC+KhUd8AyM9V46w1vt3dtClNdub6zvzqLYkp0tPkZfzQs59BVxS8slNk1KX28VAzU2ypIQQ3Nwj9ss8TMYW2Pjx2q4
# DATA 1u+tq4FK9Cp82+kdbd7ytmhO/+5sX1/f3WhcvbPzE0fTKZ+cdtrdFvM9Xm17bcUrCSFAwCUpKyAxTnVM0qRp5a83eT0I5Zt0JYh/
# DATA bgrlJK7Kn/atW7uNm+tb629q1ZHWF07JTGyza5P7OuDZ5pXDuE0LTpk41Nt5KAbkL0xsHIOJpNVAvCmrjAvFtWCzR1vBBBUz9pBI
# DATA HSvJj2rIOvBlEX6tXMoTT7y6WECHwzsiuNABjY5KK6WV1cvaUcn1vMJmYw1ajfF487rOr7Hzl1+QXiSb9JlZVklKViVBIHxhiQUI
# DATA kzdZMEBzWNfEpKXGLlL6OOysLf4i27SrpzL+IaDFkSmMRcPGWxsVD4XApGJbUu70OjFAn+lzeO3Wze1bO57aNsJZwttdNDF3Maru
# DATA O2fzRhyC5dyDyQJ9HR5j7hSZl/R7wTclaOKMplGIWl5wREjivs0STxwqFzMoern4wgznsXzkuA/26rGmHK9ZrieKOea3tKd/uPXC
# DATA pBAKCLrfBQmp7boi9FzAb/cIqLvuqXvxnZMeHZ+EVh5aU2miLjtCHjiCECXSVpLQxdUX4wciABkoSOaePJlMRWIpVH3A2z5tNq3W
# DATA wJ3byTwgM19YRq6J84+6aaOkwcBINO6i54yn1C06BxhXkt+KQNZxwT11nwOvEr4l1hQ3WynurdQd53PBpNurwuUPPBVfVuVeTl+2
# DATA 6Ojn4z6KBlRw2U6j0pLHOJACliyJyEra9U5XfwrllUBb1V1gV2mIVlxm9UpqsxV496MEr5UFrEmukfDDzm6cfi8tzs1Y3MuhPXPU
# DATA zZWqarceUVhIMVBG4aSqcxB1ad8T5RNGNOK72koRJ9+aa9tJi8lKMmMUZpGh8XTBHhhypD0THl11d31DGhVDaIlpONckYSWmlsuR
# DATA eFQFOzjsH11YJJGn0zofZaa+CtkjAwTd6Qyb7pSQINpyqo8ZYKfwc8uvxDXNhi0dJqB9RQU0tFmNuknIPFCZPfVF3Xgq2RlrnPNd
# DATA vvKVqAvnPNaZFKUx0iaiXoMl56M26gNZx13h7AnFhThdcD5chzys1qg6AUfQORpEwQiIE/sp6GpBY1rw2kTyqFAVxA+Eowo8JPGF
# DATA /fSkk2Xo7+NsprMUB6tEOB60uqhQ6KJ6xD07bj+UBiTtIpXvtCayD43dgcNWCNOjhiEAjKQFNyG+a+DFydwWzB01vDQ7d5Wc3c1h
# DATA BfpKZvKUELJZ7RyMwuafNIhw71sTSC0EOhdbmMNKLHN11h7xQ7wmyRKgk9QAIU9uyxpMYtoW+nYvLF2H6qhDe2Yd6/NLjG+tb725
# DATA EWPsZkdJ49RnSlnlPQupzxF3T/otwJVrGfn/hdnpNFaqBX1HnF3Ic4yZwhxfUKq1OitfRwlppqR7Libti8LTeHGMH8vdMUekzu96
# DATA /kmZP5bKoD8oqOb9UKFAao56+4X14UEhckhueZ2mzXdAokqC79inAC+MrfHJINMub+1eBs5Ezeyg0yHFdwmTaPdGtVVJVzyH2yI3
# DATA gMwc5n8/TQMHhdhBinvgJfcmQdKLFvQsUZntf9BYzjLmUh930K5svI9BOVhbsPa0673iQGZqSmra8MdfL0yjJM1HXmhA3G/4R4fh
# DATA gEsuL436J+hUbNXAjQuq0CfyS3RjDhsV3qbvzs53/o1fSs9zsOiMW6JQlLzprB9Ud8hYCo4yDAzM5Ogcv1YowmnudITqcTV39Ozr
# DATA qXS5XsqWACri2nL/VYAdoQwRGWmEchxrTN6rk2avcwhSCGfEMh6Ge073okmuJIERPjRJxDmFFuY3tPUg0XPL8+M1ibM8ScyqqGiL
# DATA THM1MgkEduxtSR9z7d74BMFOC0I0ZurqXsauEbpAW4qPULtuGiiYQ7cYbygislrkEzMB4soCHVnjjm/Q88giVqM585nTRpyyCnGa
# DATA YKBwrj3QKCxMr91M5uwveakkS5urtxQjRjNrb+CfEAcYrKFQxxDc0DMlN3Od510qQmWyOFc1T1bwZn76QY+23HGPVP0L5z/YY3M7
# DATA 9+IY46rFVPU1YNG5L/z/A2Hc8f876Rwxvt836gI43f/v4srKxUs+/svK6vJ/+v99F//73ktL42y4tN/pLUHQxOB0dNzvXYQosVsD
# DATA SGOfcKJVCB1t9gxcZoBL6kBHAhan5xXI7nTN4RH62y1or8DBKXnjgSYDdq544slvCuT9O7gNfm03wAA+BjIgCJIMePnN9gu0vQgX
# DATA XjjRVRSKptWmKVUnmonxJ07Xbe4rthciIVxjAGSjSruBJZ2YL9tqSxVpq3GFApbkVihpXyrgla0WsqE+JaAFASyDt3NXY31q7sIz
# DATA PpVQCfNpYEu2ddAc328NsQZB/w4YyXFziHgkqxqPBJ/YkCTqAZyJJr2ZXGllyO4NN98eoNEb7Iw6TjIdHo5v252NR8FtF/MbF4PT
# DATA nItMN1KyOjGcBtstSu7Ua5swG4DUL5pMMWHT8ymzInafA0uZVrPUatylmk4KxoOt8b+lWMydNs7XWB2HwVR31M6swS60bzBFwcmR
# DATA cJpmt6PEpMxsND/oLOOISgy8fGGwFHqsY2klnOJrbWfRwmLCItRVi/8oJS+SaAdz11ksyGgYMYQGL8ZOiIXySlzf2gGQFatIiIcz
# DATA DYulNHtkb7FTLGcpNFCy5+AP9FVd3/5FtUwp3Mhp3XGKdm4134QLci7oyZkHejL5bkFP5nAkpGcF0/WS66zMRFUyrtJgElxbu+gN
# DATA uGb8rnGqLi8X860nOgNSDreg9aP8eKM+ZTQu4H8tkgKF2X01A8Co3d1a4jDu6bg5peh7bIV6zuEONZeQ3C0SC/hEotSsU4ImcizV
# DATA xjjEERe15MxpT3UOo9NoX3Owm4TZcvCBavGN27e2dhsbW9flGZt472M/IR38xO9Rj5sM+qRtZCDSNawoQbQ/vDgbXPCCDrM2z/cL
# DATA cFRAm1eSGQblF5x+UjPfS64jyxBMtIx9v5oHw36WJZihQAd76xC2UR8Bzw/QtxJzPnJlPwMYfngln3CsLWEQqOcUBLPfBsGXfDlb
# DATA hI/ePNnvHI3744zjcjmKNmNPZvhKNJT2ZECAPL7A8tazGtMjBbzHL8cMyV+wYvELVj3nXrO8/2H/kJr2yInBP1g5zlgOVbKZmE5F
# DATA 1i1mZdGBx2bDCy3r2Z2ysQ7jqASu67UeBfNQfyTMfeIxoYH62+wytVwa+Uo3AqwLQLPu52N3RVm33pjOGNmzVODUs4BTZharrJFN
# DATA mvD+G5AGwPG7V7tl3B0ZJWDWJmBF1U1jpDbodWRG41bsxHyACzqHYLOJmQsdqfOvEUxbV9V/0EODH1ZZGXKhKrnULNcpf+TxwbDS
# DATA 6S91+yPwo14y4cIBHIzj5GJNApEytDVjZYdtJYB0+B7ldmqJOlVe0Z4/VXcsqEnTn2sRIeykE/Icvp7Mpj6ofP7zE93GzA9fz2yW
# DATA eCbdj9on4KAWu8N6EeSFAHxA8Ajk3qgf6MB5CiSHNkLjsLyBhYQWeHqBgH03Q1Cdtlp4KHq7DIhf1KpQm+PxwN4YVAqjmWtdxX9a
# DATA TWy4KiOa0v2i9gInqBAINlZiN+TPRGmkZuFuqJ/+nlSPCnuL1kd1MoTVKHb8oDmALGKN/ng0GMvDEeFO1VYuL2umyeOkYYEi1EyQ
# DATA lbKUY/xJ/HXuFNC0ZWsDGpYcTEk6wFskY2TCn2OUfxkIJRv16SfCoQgYCkK8TMDuwtAplrcpJZ5B3y/sNWV9xHgnC4in3cwIuL/g
# DATA JjxKIb/b+OA4sW4MkGjy+fvPHgNOUvLsq+cfPv8As1NCMsvHzz+CXJPJs8eSqTL1oObBhf5eT7GK5LDbxBEzgtMHmCGYpQ7+WKCf
# DATA EJjpU2z23589BfgmasVLcBm2BZlCwP2mD7AnvU67hQ1a8FDJs8/U93/BtJn/BCDmYR3Xmj2GGAUQI5FxuKOtZvsEzWMpP0A4Kxt/
# DATA 6kmsTuYRTXZ1slQ9+P3nmFL5fUzo+SGgXamZiecRVS8iE130VlZTI9plgRgpQyHRPxkyiAIUWdIrfR3u9ISI5BEQGsNx2eBbMgFP
# DATA 87r668QmnWePUj/3qFwowuy1hcP02T9TZmk1HZ8+eyStFc70lpsUmVw+Q4Qv6NgvMQP1IwDGL1GvPk3Ogu07qcJDGP+kktjprSXT
# DATA /WP1z2P8GJDBIJHq8w9dZ1yzuRSzMFwKnUSA4RQIowdVLLZrVhALEkLKeM5asaAQMPSGGjysz5Rr9g6O3RsjzzasbgGm9xFmo4WM
# DATA 3X+cjY6WQ+iOCm3P95cZOF2SuGeXO5IeDIPWcC7cAJJi3Z4FXVR0aBLaCC8KRcdUF6jX3OH/Dyed7p80B/paE8HUoSGtSokMh9Gs
# DATA aN+XWYUT1Xt6p6LHSqxKDNGQAt3oYdVxB9m/cToQ6EmmgyAuh+jKupeWD/lLeFes1wUrhK0XFKfUIGsgQ2OhspAfkYG3QV6IOrs2
# DATA 5zqNnc+qsW67PagRMjf8aVCs7E1iDA+xLAsQSWd+LeQCVZve80YiWYvDlOzKb4oFz8QrhSFasMOCzYrSE5fVK2ZK6kdVR+LzaXxq
# DATA 8BSmTqmFzKW4kBdk40pLRDAMgZYuEkmK8FEu9/plVA0MMF2BfgYQYciHMJ8rPT4E10Q8s9hDBFYYxC7fWOGJcQueb57jmu2F3uBd
# DATA J3fP/lbt1D/w5qRD0t2tkYQm8wgsCzYmPnJRQ+bFCuU6gNPURcOfBTHveMWCxa7SUhQPf7BXW9FXmUcA1PjPulN0jzPY1+VK5bxF
# DATA V790f9zpgvBj3P3M1+eEA3M1eD4g2GyINtMwaamlTa/irqO0h5o7/Yq+1okKuwzZxlT9kVvgZMFx38KFtHhUMfTcQnhL0E2L2RQz
# DATA D4rltDIeHeCSH8KTQvqDn/zg5Aet3R+89YObP9j5Kfm2Rb2+9qqXWdF0DtcsRHxIxCMMHLIoChX3Gs0ju1TQ7JGAYQWxRueklDjQ
# DATA +lXZhBCVbAdzVhNNapOF0CMEO1fSPSguTHMko34T6Ysz2XxfirnC/ZZ+Mb8TrY0zU/qpNVtuG1byPHvzPWhmjSHBc6oKjQpMcD2t
# DATA XAn6Yt7AUAWPydItrlxu0gWtXP75uIPpc/V8C7P0g5rseg3jMx2IMHYHMdPcHO2aLOZsa1Tc8ToIo7mwpRyQwdaJ3n0CETM+5VYS
# DATA CdN/7cbeKlkpDyxcWBFyg13K5n4b35K1Bo2q57xsd8aGnA2xMu3ueGiZOX6ROQTjulGZavOsJxF82JgJxBL1pcbqQpheruKgD0cG
# DATA RcpKDT7ME2dpQKr5uhRzkpMhhKa2OtNv1Bqvt3F1JRGQkICWZ4jKga4oRxCOaMmMnGuycNZnCkaygWVqgnmAEXRGDe60sEiLbmiK
# DATA QtG4GFtZG5/Pmze0HKhS96NyYMmVerEbxeAWpSv6XrIz6g8GCEN2JFCvGT2qJOuJcAfMVNXJVJ85fSuabtRlN0FUWPFXUjP4EG2s
# DATA 169WgrWlTmuVFgqWrbawSvVDhJQIzu+iooxyiyJ0ba6Fisw9+hxdWuCGFHJZW81pfR46djZQGQJRNYVLy8V4RHSE7euhvSDjd5r4
# DATA Rnm9f6bQjJ2F8U3H7WYXw6OnHwNvYTH7CRQZZ3F/4fmOFLLUcQdAH0p8K6Unp77CPq/+PPsIekSTTQUA2fL5csCRjQSLdSBXne01
# DATA y7eTf9GqS7hnsPIS0etBi/AlaM9IvfQVX2I+Q93ZXAkbZ+gk0rgxcF9t3XuxZZK1r6m92ZNZx4i3qesnK0867Ja6GJE2WvGhVt6i
# DATA eZP0+5n3NQP+//yXoMxLbNXjs8+ff5Q8+yNc6vARg/1HZwA1DIXVeeDMI7qhD1Et++dnX4E6EDSzX4BO9ivUR3/KA/jkXCuTc/Wf
# DATA g33Hz+BGt3kKKTJI+/HNKy2YcywuivBujug3ODIkNqSJKzGFooOtVsK/HceXHEd8qYKxXvWxS4fs/Eeqgb11o2I8ef4/8MQid3rS
# DATA xMHdraAxrYYZpuYRb+DK+vBoDOxsG98UxIqoxl5rNNSx0WgUrS/Bhtdo8ieFVKvRCUcf9A01IJPsoM9I+5kSV8QkhQpBkSNIrdju
# DATA tkiNSHFRJD6x3RN+kVmNjFisWiIwGbR3iSEbWWyqI4jKcAeAn5J0BU27KDahAQwznIyHXVulFh1eGW/m2Mspk1AuY1wKhNedDto1
# DATA nZELLXY1+Qb/ga8yc22DXxXL+qc4qZ67PJmZvsFpKdn+Bw4HwELkVaVOc0+6w5eWedl1TECKlntKvI+8ppYcTkvv8yH8lJbLkaXw
# DATA Oc6ZjkBkbfwyOLhar3+Evq9cve+eERycvgWMDsov0QKk2P65+GxUG0wDMtxGF8xVBYNkRL3fM8OqT1tazm5o8zTntBG9ul2YqqYL
# DATA Hf7NNzn829Gw4xN9l8BfWteuteiGehpql4D9XC1aAw0LjQZSQKMBTKXRSCO+ncRuct0QdeqLt9unsxNfgJ6+7cGrDsGPJ332b3iU
# DATA P6HTe06Li2PmA8PtlSRik2Sdboksj5wECPNWw4n+1fNPoBGojCyWcMj/CWqH9iuJosRH3BvIPIRNP8ZvP0BT2f/X3rc+t3Vd9+Yz
# DATA /4pjub4HkADwoYcTKKhDkbDMRiJZkLLjgggGBA5JxCCA4oCSGIl3Yqe5bSeZdNq5n+5M2+m9d+5nxYkT2Y6df4H6j+5ej/08+xwc
# DATA UJSbpGIbCzjYZz/XXnvt9fgtlOGETIAiXSkQr31MmYxAGf33RlJu7NlzoF00FmGbAPEKt80axD+QVd4gxVPKOVRY/vOIkPrz/rNU
# DATA /niPvnT49+z4r+Wl62/fWnbx31eur7yO//rPjf9qaJh3TNQRTQiBg7T7ifiv+LY4OwUv3+9PIRWXdHJgYTTOFwOWRI2X2RPb7J/g
# DATA R4q/eEQYZl/8o48Pm8uMjH30x3VqLH6telOJ3UqG854p1JUsL3gW5/sAWNGfnpIBt2pBPtsx7oVwbyms/GgEDvQQPQ33rI+kTzt5
# DATA tJtaz9BwKJJ212JRIxtZcfLN6sqNlsKV7o4mgKCqYYAwCF17tFJaNwMOQeGrJqxNcSilY3opE4DUzAjDuAaN+t2Nnd3Gh6GN72Qi
# DATA O1G9h4PRfiG8KrFdLc9k6RHiaXiexg2PAUuOtIPHZXuQbBKVTp4FzpM29y60v7bVWE8mZIaaMqFo1ZolHTHJXd6zdAY07oIaBzzS
# DATA rjTSyV4990yoV9I2IkKSmLsmzWyTrk42NBt0NzFSb0ZxcgV+1HkYlb32UILrgIIAtM9bzNvBB4I9QZ6gFtq5Yft3hoTXBTetszxj
# DATA 1PeJlxpo9k2Fc0MM+3+LEFIG1itSMAQCQGXGRQSLmnmLbMIlM4qFYkmv+GEsTZre3doC+MoPkah3bLcoqkPG7fJt2cYgwyO00yuj
# DATA j7l2sR4dBORDSmaJYzRdMPeWYSjiPho97nQlxcqkdcSGHUDwrI2giL7tOJchOzKf+3gbhxmeGW2n7xIbLNQo7aEO3fxMCOu07lh3
# DATA Pckb2KYAe8mo3tpRiWZNl4KSseHC4lmCf+HL3ugMwybR78WGccWyeaQYWGT8Q9EOUBgKSo4p9cYtGc7syWPfKR9A0PCT5ZXSrRtn
# DATA od8xEWrKy8LXtjZ3Vzc26w3A7Kxv7m7ZB4ki5HlsPFehA+TCL6aH1Iha/yDmY/SIsN30AiymcDwMBu2PFjML+tT3KlZkRhPzhJSc
# DATA JaNiUd5AZmVxLSPeIsUIo0/HOYJlPGEx4KVPE2poeGQcgUGoWl1mLEWuGB8vPJBRZQVy2wliSMYlNVV1LTOG07FrePQ1Uk1TzAH0
# DATA bM479yh5HpFrmQoYD31oct4xshNjisfzgg/OBj1M2EkB/mExPz7zAgvqTeuxSPgNU2bKFCc22YNjncyhko3Gw6nxxGGjstB4RynR
# DATA SJtkD7mK7fBQU6IVvU7WNFMp40ikEk21ryaONgXpgHl2AMgkzhp6qniNMq4DXOa0PYorMhdqODR11EkIQszLwpJ3Z1ooZmEl5k2Z
# DATA UvDlTDFjTWlmyPceHifKLy8tLRWL2fCJ2RO09YE4Qvy5kn3evzlyExdzgrwTs2vacmDLcjXkMF0hEKBD2JkrZVAVCzOTJefSHvtk
# DATA mIWFe/W7q2skW1Ka851XfP7lPQIlhgKbYzBQF8VUC0iBh5KSXU5nds1xWiVnQgIEn4zHeFme0Ym0ntJWSO2hDVg7s6fzhpsWFRbF
# DATA YWQoa9qTSIh9cFeQnhtV6Y4ofTqyPfCKSele4wUo97UZEAXpgf+Oa5syQWO0F1i78czMakt7nhhwCBmZ6nJEOCsFVtu0NRJmtJQo
# DATA OLxZw8uYYRiGI1FaWrQcCDwuKlNOQVr7ROogJ5Wq2A51KiYT5XgKqCMtjyrKPa5e9oLyii8nF7mYXPalxA2FP9DuRJYwb2wUcqkz
# DATA XY42egaGVRrwk2eKRFU5MAZsctbf3nB64Yfn0bJA0n9oVvfUHqCW+z0Tj0v/WswXqe7l8flc4y4QkW5yUEcxiYeFvT9TZHyYY2dT
# DATA 5unKrBtH4rYxx00j/y3D8vNuJvPRzHn7SN48YE6Nrw4/o7wCdJvwA25f5CqhB6W1jJPCzMuFc+/McbV4yWvFha4Uea8TOa8Sl3eN
# DATA yLwcXMIdY/77RYpboiaPhZw3kfy3EA9KiIkkoa8cmP/C1U1rPzPxo2ClaYI7uOZFvXhNiWOoypwhV55dLoRFSU2v7LJGtSD5LHJF
# DATA MhVrmwypJcFVd9+U1rRmKpfc5+CMsHwi3bUw/2iWeIHUdH/jbmN1d2Nrs72z9aCxVg+tQFvpPMXhR2OCuNFMXaytLk+P3PUyuf0Y
# DATA 0mwQLJRltMTTDSrXenQuaZsF+WGC0t+o5eDaKROA20mlf7u/sXN/dXftvaQFEXTr3L7gy0jcdMBIjzBaHUKEzb/67oOSsfTQRi0B
# DATA yQItyHsiegKy9UW2jTrQtjbNWFhHyYxu9JKZGj1FEFpBKQhXKY/QSrfadZueZqw6KS9jncPAHUs1IeM4FqjsOmfuBkjcRkbkeqO+
# DATA Hqbjlua5NLlIOHlmbafeeH9D7cI3UaCIA3H+o9mrTMhQ0vJFp3kMcXBiCoL9yehRjMrr8ck0riwkJJumJ7Dqqm/jtBLpJH0a1tmZ
# DATA qS9gwncFgpSzSmphxAOZM48BmttCJgcioC2RRFpNA/EwLpp6JDmRbXXGvSbvJ+wpC1byO0G2mBuAcwUsJCWVNFwRY5JrTs5Y1/Mf
# DATA QPPoS8s8HrivmNY5iyJX79/ZuPtg68EOLcnuauNufTecL0egMXadKHBJBsIneJeTawsFB6oixAjCqieCUHkCaCsSP8K735nykTkB
# DATA QViIAtze8OR4X6kz0GKNfCRgYDTGYIPWbytYEYkIPo4mgKMQI6YQIo7hpsQgO9AYKbM1eBxhtm0lkmMPuO3cWok/EWWEZQm8DG2E
# DATA sa0SdkWjMWbyueLVYIZMULaKkFUloPa0OzZKwartQ77M4aGG7d0Wyyfu37i3YHGhR1wIOsUfY4YOtgxzorGSLgDeX7rTGeCU0KIJ
# DATA AcrZRVoS8LN/cBChemZjW9d+DPGgANYZdLCflWATTwghzgEdd4aGuyLkCI0ArtDLJBwZ0tnfWvuS2N4zUfEMDUR6A7PUB1IgtW4X
# DATA zEX4jHSEDuNH9PCsqZJJ0UEXM3tovJrKw7iCJ8rnkXUCyuHR2Xy61kQkFia9S8bFpV3zZwJSKR3AbK3H2eUI0G8Gu4JPqgWBDUZO
# DATA PpKvyuWD8+phhKx3Eh/1x4BYOyS4I3nR6jH+ZMKy5DstzFn1nhm6gO/kyIn1lTQeeDK8Q5hHB8KN29MRUotBCjnNBHpTXABpdCEF
# DATA x1PZftjYU3GtPyr5uz8lfVpC+xr5aRlPRhPHVqn68sac9iW3KkfO1ojg6SCjKZ6FxWIWr/MKoswwJXUXIbvwBbzriPI8kPuzgPH5
# DATA oQ2zk8xsZmaVIAqmx2bwKj0q0D+UHZV6ZeZKtkOm8vgTA2QP8mnIG0XevqZv4kuIe3oUUsyTjnCG6655RklJJLmWWSgA7j3ORX9h
# DATA oElqJWPb5rSCvJSpjRu9AAgBgcywBZyuUqZTp2sZkh7mycM1eelJXNITaUqlNAvPE1soGQVPfrWG66tx6UrpA73ia1iLYdI5ooQm
# DATA WY8v76wjX3qJGs5mCeOGRoqwiNWG6+V6vNgzhoSbeAlVa4aTZzrwA6bW1QX5MXiIyMzH9uj5zPH2aPbJM9OfJJcXiR5lSXUoPBl2
# DATA Hnb6g84+YcCEafroS7lOpqupqV+YPJE6GHLsuHi0PxoNTP90dSXJqI+Cq6s0zmZVXPBajv861qq7qX/Kqlb7/6SS/ZkHJFXdoju9
# DATA U0asUSDLKxJyBbAkOOcuHhHHI8HvRsN+F7Nyc3mC7DoCQMtEoe+qKnwgWv7tMvdWsf387duh49nfiNDAq39PbpiiljYmujQQkg2s
# DATA kXg/Y2dCbQ6YihcaP2VIVj3Jftj7PqMbNrBIFjvWWKASqSNTvbq6/qHyEeJT1VJgq2h3rbPWAfBauEMYBhNeOzIeSW42GInrdH59
# DATA 9dZ2nawhtto6n55dg1FYPZa9TekRxVNnSSYASmELJ45E0rIbRIwAak8CV2CjWIE47FG8WV5aUoAY3dFgNPFUa9qJDZLL6qvqBWNp
# DATA KPANTx/lgkmdTzEpaiVn840ar7gpaEmuJKlKBV2Yp7Sh6puKGwtp+kCDJ1dXgZui0XYKoSiArtifinKsDgSkLDAhRmPQ+GDmUqns
# DATA myUf/NFiwNrQrxrD1IfqahpVPFcuWXimnYXNHKAt2NnYvCvhW1Fzr/R9JimyumsL4xjBctXrDMBIxOInmAYRURLXicNa4kogtbrT
# DATA o87U0CvA0nONGDMKVEAqiUNQhaGeYfpoVJYEoTM6SltLRybDQZKoMK5lr3eKUM2pugK4K63JYiSqiF61CYGtBiCY4rdQyqu0AtaQ
# DATA KJRNXcrt4EJDBKDjJlIZ7mPk508Slm1u0XaVQfcm2UtPOKH1m1YF0LZxxCbzSi32E220mnsJFVfD4MnekHYzZuflOUncJ6vXl5aX
# DATA 9oZnZtbx45G4lFJyJRpsk4fVoq48FOR/bM0dbkhQ3HOCItNXtoTZ+tiVlyoAYBk+EUHHGqYmIOLyjJGDbxBmIU+YXSuSO9e7GE27
# DATA i1huURMIqeiAHGiIRTNFjKIa/RlcV2hY9hJq+GMMJha8qybTAEPjcl00u1U1yiW/FCLTlMA7XQrnXEAD84Ado6NTyknGINsjv2Ui
# DATA swhqiNuU7vys6GTJ4jetywzmRuocS28ok3F5snencLD3Vnfa6/Xt+uZ6fXNX8jOpzckBGZ2WoZ5y0xtRg2U/2rE/S/0cWMXqrjoH
# DATA DLELN9zSUaq4XHqpqob2t87HKOQIO+kMGLyLjnOArhTceyTunOICd5s9luQpGYgZMv3V37QzeAQsQQTHkKmMlCsxXAMEI+8MA2MS
# DATA 8RzWSmPFJ6DXLbwBHiinqaaRh8hcB5h1qKaVWo0UaKCWcDgK50dY1qhD2a/lLz8bjjn1TRuQ2UaEo3M3NSQ3nxrwArG95PDfGbSp
# DATA A25ErtGtIllw1HfloejkUVI1qkD7lBBfHd6bVZ2+rz4Bqqiasbm8z3RQLpQ4K/r2zxn7gwGoac+Ctf7PR+BNJZHciLyaHWMuQQfq
# DATA pGCAK/kxxxzY3pTdkUHKEtYXk4aGKoN31GZHLRdYUK2DitUgz69eZxoliNDbHZ8/mcl3NR4j15owxiUW3avFTk4/34+vJo7COeuh
# DATA 9FV4fcCQ8WSFfHLnoHgz3ZqH+ou5DI+N+v0tcXdHrcLa1ua7G437dQd8w97cVcd1nPa7fUbbbzhK0AO/HOTzDsdslQmkjJa1lZX8
# DATA Km2bnOYyE4LC7ZF6GcVvaQiXTzl35mGU0kcyrudsyuicZg3FdHxSo7xkOcXMxCrO9CX8mVO2hjdWVmWNtYQWwLR07lOhkIsnHfWg
# DATA mBpXyzV6SCnZd8heC7IEErZJ4cbPYBBKCrkt76yD3iOLmJMHuT6q2Os0DcrVOCNLBlcygSsILEUBfKKWW54DUl/M6n0P7CsE7RAD
# DATA 9XPzWXCw3r1sspB5pmLG/nblizlasebRqcfFL04RTTxNGKVOhnTRTsRu0GXGRi/gQKKEwcsbSZU5Sh4p55tAq4Njo073ufJHYsxU
# DATA bM2P3JsZkmGi+mYj+sJMuii+ZiiBpnplEQFdYi+n06k8+g1OWU2k/VKMsSrftqGR0sA4tEScUxq3vaZcuVyR6EsigJk+/0lRvWi3
# DATA w4omE+5eer3Laow4AB/CjoK8ssqYSgstr5uuoZQtyow6TlvLEnNqrVDe7sQxO45KgmCwQLzwdMV3mGnxHfU5iCfYlcaBWCyDzqat
# DATA 1MkZ/smJmNqER04uv4zivAvrumbLbFtsc7WCO/LtChn/HZiuzKLbEP0duqEg5Dg2fKjpxDpi+BdrHuAZRYRB/FXc/3EU/GVw6+bN
# DATA 67fm8Uavb75vyELaKRU8OfqgiB4UJuEPPWHgtYIRGlBuXdurZH8v/gUlXMnS10EsSeV+AjFJOWzWLIdNc5kcB0378KKMaUTXMh/Y
# DATA 2oOd3fbOgzs7a42NbQwRatQf7NR5bKAOoaoF49gbKovey4XDkN3TCYEx49k5LsmS2e3iRS0Vy0fJ9M5/smaaHKpFWkZ/LjqvXSXL
# DATA xs4QExpI07zAZE60tTvRUmGY6N2A8aKM4aILiQ61Y29f1+ePgl9fLoo63y0zJUAuZW6SiBzcmabsSKvJHWg5EJT2TrDCoHIiacwY
# DATA ibgjb9bXeCP/9YMNHeHkzwiW2iVIRZxj2SWHEadjNJm2mTG0mQvEdhgt0XXpJbLiuWYHv0iY0GG7O+LMfjHJs5o86S0jl40yYTsW
# DATA Dn+WR/17Wp7HlNlPzrFOsCbZvPuep2hmMjdiiLows4RieiqzuXzC8FzmwZPnKj0uuUNR3TRyoTGrvUj2uLTafTkE6Y7Dg0JLWr6M
# DATA SHksO39E1pzs7ZNjp7wK+8bF7RVzW0ay7BuvKH3em8CVKfdlHIlVFB8Gp7dR/DcCS2RcRBxBpC79OhoMoL2ATMuVhT957b/PtnF5
# DATA VqXLtxNd0E51OVYly+hz6VaQ5Bl39WrhSegaRSRm8qzTCVlmUkDQwjeY6WfZVvKnVby4FeYCGuZMm8krTzjldY+blSHRdI+bz5Ix
# DATA v4XkZRT3udXXyfRvGYrYpHN9UpVsWU7s37JMMVy5MrFgPflfTzMbzTXhKcYmA1j8JcwoFzMoyJR23IqTezczQdxlWAoumjzutZUh
# DATA w8rwTWfWS2V0ZmI9oquTia1rcgR9HQWWgudIpVKRXNgRX/oJuPqqgttcUUeiGQ7IPi1y8kaCsABKW0bOkTVyTxg9Pq2FEuIinI1h
# DATA kRO4ghEKfOgEC5d1Z8w19RwcZ6m0bUCRHPGnwIjteah0ht2j0WS2O9/6RqO+BlgG6E1Qv7+9+6GOqOvLQPE5tNqWfl5JdRJcwBiM
# DATA EPkRKqxowHNiOy/RZ9Sag/umipZQpKO8MfMFRTS2fmBUSiRpBDrLqFV/CKndl5r2b5YjdetLG+jW/dWNhNIKLZj5sTxJp9ofTOme
# DATA NIAo2pqooMLIwvLiyauI+m25ojLiE20rxhIxBGXyFkYex9idQXzZvchcORmHL1burwR1tOs/2NjZ3QkTW9HKQp+ueuFk9KbepX9g
# DATA DT9J5abv56qOrphEzBODzqR71H8Y8c2W60IHzGA07Ea3ZaZ0Q+f7ZnAyxBD6SLfYh/whnSF75EegVqcUIvsT2Pba3ZPbS1PJqI7N
# DATA 6WxrVJ1LR5NgC9nh8s4TYHsmiICnmotiLLmYBXhOyElblFf4E8stSJfPHnqJgJnao4+MmdAvd4/EiwV8r5iBBm0l9RJF+OgQfR0P
# DATA Ot3IC/hcO5pOx9VFDfldvb5EQU++wrDMchtUJhow1qdDStoqS2a/LWiSJ3YkpxGnVgUfG0HzcRk89MYRhekJMRXVJ9WgaTkGqKaK
# DATA jmY7HCNCjCh/EC6vvF1ZEv+3XH0CT88wWMJVhRPTgTeeOLABJG6VJ6NBmqOBW9Po8JBCXJ+EvUkf8+aSuaosdUCjsdQfPgmPO4/L
# DATA YISFQstLx6SDfFzm8YbXwzO3AYo+7B5F3Y+whqmYOxhquHZ/HaVLQXXIU/G/BxHE1F/hddeTAbOwiGY3ISsvUp1XihXBfYaFSe0v
# DATA ZeAx5u6cVEYfvbNUXS4WK10M0S8UnRLiJ46hFxUKiQa6fhOZPIe46geCtwGXEg+WVygscTJtj6NJfwQ+VeHKUiyGnHa4wow35WKJ
# DATA a9xMiAe42tFH21b5RIY7J9xJaFmS60xx0rprfBy4fePH0m2eg/FVjmdLbUKWSOuNJ+oN0Ysz9RZ0CfKowGJpzzMeAlegu+bKFmnK
# DATA Wmsj6QgbKWZfLAKpmBigYWqVMUgWE6CH1RUhnYz7wyjMwQ8kW8GJubu1Xr/z4C4UPhYz14cr27Q7ri2FOIGSFYTfXqp+G3ndjRvX
# DATA q+J/xsfFk94YCViGRflYjZ4hdAyq+sKTqpOREifLEAtZXYT/6mc0KdVFVgFbLsw0XbILNEm6JkkRZj347GwWOyY5qizlKHFPcDX7
# DATA r8YHy2FctpNpFRE1CkkicSL1XVfw5Lp4hle0cAvow9lLYLWkuoWZyrRMPWiqyj+H8rQ3W5kg72W2WtOrg8ptDjtzw1sIXtLGFWPI
# DATA X0ywXTUS0gc1ldm1ssp56bfxl4LEPwNdQbstVq/dzkhlr8KcgWYJerfWDJUqvayxgAmpA328Q8JzmfJ9h5UY2vRyMokUSy6fTAb8
# DATA C18EyoBOjYcXSFTq2FZOdXhLEfTCGAJ4iSxz5CIyr5M4KgPf0d+oJhKL3MB3eQr6AvdbGTNTLgP5itIQilnbRu2X9IIwBEvT09r2
# DATA IglRmEf4uNSsq9YU2fOhRyzH2j+2c1FSVY+xTjao0ODIdmJG/PsHCBKo9j+FJPBozcey+A+UjjXsEKaJtyPqvZTiQg2g61Lv5Hgc
# DATA F7wo05SVXqerN0Ct8bvJJ6NhLMir3Ym7/T7jDLMYP8jqYRRaOl+0tztZ78EfSD8n70yMoH1JVxcTetS0X9UCpwclW9EFDnmotHL7
# DATA U1RroV51jHd66iVa+Kwp5qsCflbGOXop1XPOM6gZa4HbOoM6JAqU6u1FFtzlGRntuQi+7iwZqjaab9aLXKBXBtvK6JABGuv2BR5e
# DATA vGHNIU0UC78bcs5Z4G8GYWb2Q3J3d/RSbT1fq8amQf2r2xXDoVVpsYyJBGVHiFdVD/2zfA5FQt04BbsbGvHs4cpD0Uify7r+xMKi
# DATA 514v70bMblYfwFVH9AWrRXbT8zOiWV2xTvwEkrryiE3pVjF9nzz5KDplByIMbLLCr7yHbfHsAntHH89J9JyESSI5CjWd0jrRXGpl
# DATA N2iIAGnXSoPcpfP0ZayWFr/coWpom7R1kjWbRnIJs5RNchp4SYi6omNttBi129ildhv2YbvNPYI1jvuHwxNE1yvAx86gsrNxd7fe
# DATA uF8K9Pf3Hmyb2cbpOf1ToApKAefjuNoWN7FTrWZJur6Q7L2QlixVQcvlSk8YdOIgsqFWxV00xrzULuZuulghrhPn/xKc/+HFT84/
# DATA O//t+Vfiv58HLz5+8Yl48Ex8ff7if5x/FsDzF5+IYudfn//m/IvzL1/88sXfi6Lw+z8F51/AL8/w5S/Pn1eC8/8jyjwT1T1/8Qm8
# DATA /ez8N1D/i4+tcgH8PzT8/PzT82ei5Fcvfg6N/50o8vn5l8Hq9kZZPP1a1AUtPbsN/frpi3+EisTzT8XnX4pvz0QPnA4/ww6L+s9/
# DATA d/57fBkrqLjXXNKfrq6t1Xd22u+ubtzjCfl3UdfXolOfiX+/gNpyjZsb/QO+/LkoT40GZnUvfoEz8t7u7vZOWc9LKRDFv8ZR/FRU
# DATA +RV//oV4Tq99LBr8pX/2nsHsBeZEOdPx4udyAH8QXz8WpWCJ/lVMHBWDzn6hum/N2YufJ+YMwyfa74q5at+HCIs7YKzZeH91t45T
# DATA 939TFg8HKPr9W/gql/0rmAHxECjvGYyXLBw4OOgEPjIGuXRraUl0/X/LauWM4/dnouNixIkOS2Og7jh21CHRr89/9eLnYm2JBuch
# DATA ywC7h5OGk/l77tWvcLyfiY/Lt4Lv9++kdkznePT0K23r/Ep8+B3086ei3PMS/orNfwmE+Vx+f8bTiARYDUC3HFcX2d8vetw5Hg/Q
# DATA Ey/ROaRQ7prFLP4ntSB6JUj110A8ds+wsc/EbP4UG/5YFMa6xLrxq1/ycn354hdA6W4FSKN/wJH84vx3oprPcSY6J9OR2cszx4q4
# DATA cxqLE7wOvFeyQXRfAh0UsknQ0pz/m6gZlumZ4BLPE4zDs1N4MX+HFAg78R8ytrX4+M/B+W/FmvwEaftLXIkvRKmvBPk8P/81/kJt
# DATA /xLYmajrC1xeSWWCq/1cVCm6AL+K3wRRflIB+fBb9t90II6/02+90r8l8Xfrxg38V/w5/66s3Fi+JZ/x87eXV259K1j61jfwdwJa
# DATA F9Hkt/5r/l25cmUtmkwpFDMK2DUFBDDOK6lNnqRWih4FDWl/ke495ByPQZv9Y7zKSEWg/E4VkRpHPgPRWX4exQsIQQeK/EF/P+DH
# DATA IFfKIhNVmRZm1JNT9VFs3jGIlgtUIcupskK6RpUsc0abHsalAIVZ1m8KKXAYx4PCVZAJSwhyyGF5B53+AER2Zg+1UJyBn8HuFLvs
# DATA J7gT5S7crgsZEPa82O3PX/wd73NgErxLWRKAYwpZ1tdQUPBkEhYs6eE5bnPRxCdQlSj1BR4qz0IXmdoQ9cTgC82QRwLeZzAWSOQG
# DATA qZFqMCQhp3fGUxjN6GQKD8nOpFBtbxrODogjTCrh7qiXlUXKmSEPkm6FMG6kC5umwPa4058UjkbxlMP59U8lSh5iLl1cC5UXGPnc
# DATA yDdZ1S7eBo+k/kOKC8F7ilFlkW/qomIDMRtFeetVO8YWXJe6iJcmzoQxARfh93BvuDfZWwpnaudIVMYjF4iEDwcp2YjDLEAxAsQW
# DATA EORYcBGnHkqqz1/8DIgBRJtP8RVBJck8s2MjkhxGlQwBXl5auRFcxX9mdvg/krTHhxJTsOo8HH6y82JsZSnwoAzx3BRqxGn3DyDW
# DATA BPf7d1Sqr4a4LKL/SxCPXHYESx/97Qk4RYBLMDhOnsSMWSlRTEHtDTRUUQTQJkIXa4yfwHdPPKVb6f4p6HqLaqGtpxTCwHwgfHxz
# DATA 6TtohxmOwLoNn9AiHw1Rm/7tWzfQrQIZhWpWjmpL1LKzc0/GGMRBDzPWIKZhP8aYZPAQmTJu9m2xTUBDIBZy+ONoMpKo5hRSwOVp
# DATA x6qENfthbxTFFN9sbptQur/NHAnsHfFNbz57LNnoEr6/JKf0khHIKr8BtghU5EiFv4a9ALRFd4ln2Q57l1G/4gMwD7jLPWdFweJC
# DATA es5QDW79JmMibVX/Za7Vy6/THGtl375AAgfZkm44cMn6FE4pY0YFNxBPnqHw/SwhFefglN9ILzihDMkS8YBIAMQHsAVZ8gN/pyPy
# DATA x9K28WYA6yTDsONgfzQ9Cho7q7hh62vrO6u3xQHFKTKOwTEMfz0e9U4GfcTMMNjV+GR/0O8CommCCMRPgo1Z9ODjN8zMPDWN5evi
# DATA J0lP4w6kOiDLXxxXZZ2SX2o3U6Nzb9ScRjJ35b8nbsH63IDjQCzD10L2+QSFnU+kVgZVRT6h58VPpfcdWOq8E6V3CxpVe2Qgduaq
# DATA 0otAkCkkUpmIuipYDBa5PR21Y1Fw2IsL2KBMDlSj5EDLLUg9JwmjMhw9KkjaqJxMu8UKfBO9OB4XZvAulPe+CFDj8znNAl8ufYIf
# DATA 3BL/Ee6JX5Fi7dmLv8fLsLgp21lQPGegCh0Yn84WuAyjR5rspY/Vi4lxvJwRWDEkhoDjyr8YQh2xwkMxCudGcDn/XzR1KDL9GjsV
# DATA O7IXchQlexlCllIyiAn+WNDwl3gf/zxMdN3jCerz/TReSHh/wpwBXRdCyJHTPRInTmUcHZPpoP8QEvbBVxZQBkYqd9Pyj7UYinPK
# DATA QydbXYSfLeiFufKUnv8/VLN8hofrZ5agBwKgLc+aIqE7p+L13+PlRs0qyomGPCsGKBGSx5Z8Rr1Oxop6NOY2PhgIkGKCfiz2PE4S
# DATA cQZnzJ3p6Ljf5bbciVP1WFp4Vrznb1YMzQ02zFolA7EM64pTYqXGMnyJs9jYpJceQJgY9tgZpxt7ZBdGdxRZXiZDkYkPCVUMkqLw
# DATA BV3sE9C0jWGP1zDmihymEYb0oP+4Flamg7gcelYT4VJHceWgB5y/YDYSPtoP0aQhWHrUOXaz5sAztlklBmaUOBicxEdO8Be0F58O
# DATA uwVZRoxhOCoYMbyjWHli06JjaDPtS4hPGxhDQO6GEmPqWjGPVrBZceE4mh6NeiWOfncQuMwUxVTAiimSmYiNGyE8SV4Kb13/9g3P
# DATA z8DPgv8WLI2W3n47i8eub+6Yfa4KXiCO8t8qNbtx9QNuurG5oRhHgNppqaVHtnBL3KkczCFTlVQhfA32MtOQQiqhvPEqsQ446YeH
# DATA hbDZG8atvWF4DYdpGOblekUDzEgLIPjKY1G8o9yzoslxf0oB14Un8Eu7Oxid9A4GHbDmjvtk8AwxTJzWjQzQqhAn/KB3D7sjeo3f
# DATA UkuX8qqEgKd+EuC824nomJOceDoHYqABRG+OxqhWyUNGSyD5qdJGst2H6IkgZhRYHH+Z8BeF30+VVChh94wQnvN/AeJQJkOiInFc
# DATA vPgZCfBfookRz59fser9K77QCRosK/XZM7KhQZHQQYYy4b7kWBmUJbdI8a9I0p+d/040BraSj7Xp56d44BmbwWqf2d1FAkcstku1
# DATA QWBm5Uej/rBwED756Awstw/BN5u8EErW9Et0/wrCqmHuTeY14GdsSG1IQaVAsp0cgqBPCWdTMdhfbL83bMUI+zMSA05CM6v8tb1y
# DATA 69r39JOKCR7XerJSgsSBWNts8SVNZUubRvP0I8EZ0LU1ZLd46m14Df+9FqIHPFK9HIiZJhJXexBrdED7zNWVJ4rLj4sPO5PFQX9f
# DATA pwJdFI8XLbkwrZAhK8o8IYqLUtPX5EpdQ7f/8Jp47VqY9P63g4eMvCOutsMYm6g5JnV0fu2J4x4UXKshS7kGXIyoG6st5u1ueWbi
# DATA FMN/xbxrmKER0iOa9gjc5iYy1YfYCFi7TtHlIWGdR6HTPY7KTSLeVlMhHgJADFc4m9c4RCu4Dhrbfw/3xE+Q2f3eYnbcJxILqLPJ
# DATA qGKt0cYSmRrtOTaT4oFo9/wNXlGfB6tr9+tK3RujuVUcZuOoKy6IkMgcdSaPo+4OJrX425MRuLYFoDPpoZtbd0q6mfgoGgzk76Q/
# DATA EYJgZ0ynGA5ER8bt7QEN7Ym/0IiXu0IPr5jP3oJnb73FPTTog5LTcIf537C4KGnhWihDx+wEiWHzwbA/FbLGuuEE34hsQ9ruvR3z
# DATA jrw3XD0QskyN43zKIxARI3auCjhIllvbG37QgdPCWxZ5k9UZjsYQ/dkFH3IhJMVHI1Huwf1O/FFtSUh3e0M1+7UrgtHRnF4Lr+yB
# DATA kogPqls3blxggnDz5JoeOTHGpIh9JSatM4AxNXehJvHW1nCtI+TwXmdSu1oW/xcsXS8t36wuLVWBT1lDbwjCEufmj6PeejTonO5E
# DATA 3dr1W1BqG5TykP59WpuKMxbr3yDLZotmN+rdOa1h52M1sc5ceKIiLhQQkSsWQiIIUBDDGFV6ppyhwtvR9R5QLUi9Nz1SEXoTKcka
# DATA bopNw4vf1EqLr6w3tNwY6VTHGAbK9GRFCMQMEKcChuAjDtrEuh8nAwCuKWtc8kcp03LIXE1mVk2WtDj/yQQnxX0LlFZjf1SB44mo
# DATA JtzwYHW1XZ2KtC53Kpa+q1NBjVfHjt+FPpnujwlP1fGp5S8rVXWzmzG9lOdr0yAho2njBtqpSGFQ1My30E7FFKH9FTtBiSRomiNh
# DATA UdOs/8LDIPKuWok5Yd7UoS0+0kno8xFlCEED2pa8WysEppe8K6aQDO87WxJ9M/h+FI3RUilRawJ5FOONG3L6DruDE0A7DsAzY380
# DATA DeNgADHofCGJK8ksyc1wOpDxg7wtq8ZkWruZ4vx4UKYxvKKFgiJveass7EuzjJ0ujw4CniYLetCvbCJB10jCOh3EnnzOLL+AnxLB
# DATA dBkjQdnF+hX67EP28cosZF74+sXP6Pr44p/JMQMvmGichwumOJmdFCDkgSyabFqdaRVvmz9BT1o5PIgv5NgLR3fCx9dSjFzI7xes
# DATA 7z8imApM4MgqMhLJxMsP+3BdMfiBTjkmcSeiYDA6rDje2uH5vxmOLWJGq+ICZXjUIRCbzj0YuYmxWbcbmi4x7CqHLjYbmxsl7VAh
# DATA /p/N7RCsCQOpGamU0t39lhPOcf8F/k4OHrUPTzqT3iv0Asz2/1teuXlrxfb/W166vrz02v/vG/L/243Att2Z9AcQ5h+DoQXyBjL6
# DATA zIN3PxBSLGbT5OOoRPr3/pCSToIlYkIJZk+zXAAPusPpYA5/v/joZNpXL1CoxHwegPwdEGukggsddii4Z4bfHLn9+b3jxOHvOMrd
# DATA uJntdRENH9aeXL06iisc1CbO13tr7dV76Ky9Zih8Z/rZNcij0TjHwEfsN2TVfPEx3La17/1zaXPDQADx33+Ch+IVsay3Aw8/PRBC
# DATA 1yNAJzr/FHxk0JP9py9+Gc704RNz1jaOQ5kPQALPHfXRTGlM8jbabixMJRvfla3X8GblUUcwaDnZN28s5YFRpDenoKweQo8MVHKz
# DATA HV3UamR5yRBeqB2j87tUqv54bGOU6co+6g8GLnygbiXLnGYb0uiWqRVM0o6Tqp1O0ke2fhpMsWh9/QR16EAOX6rQFEEm2sL9EpY8
# DATA ccx4LXlgVCPzt1k/jjifte/Py9g3ifZHo2lbstOCmLYSq8i6U3E9EptMSDQjSP9dY5VLQvVbhrmWNYAEdDLsT2upCprEi4gKqlVZ
# DATA mvKo3UuhvS8sP4ycFMjt53KvOO5MPkLNOr1EgB+EkxCy5nEXMdLEdJfRwetHo32xwcWgAZFtPHokXhqM4himb9D/KJKKSnEXm046
# DATA w7gPxx5eLF3No5jFl1c7MieApSulqchwoXATOqe36IaYNalDhP4oVaGVsxuyE/T6lJVxelRHPwpEAAPJnGawSGlt9oapekO7RlNz
# DATA CFBiPCuikisB58wUZ2FnfxAZWsbtUTytLZ7Ek8X9/nBxchyUD4JEN6xm0lR0CAZUPoELkKGmM7SV6BFvbKiQUigLsoervlSJJUpR
# DATA l0PaSxXMc2ytE/USkgWg0CRblf48fJRRfGeViXMGK0ChPOrJA7IUULyq6BqHIURi+sQ9nL89Oup3j2okM1XwS0lKZWbiIPE64clh
# DATA 9hmShvgoxdqCmvoE0Hv2mU7osAePRCFsoRCKL7aZQTxInOBcoX3Us0NzjeYa+ZwESWkl/fHwhwq68sVwHFD6iZMY8grTlFsWiox2
# DATA uZ8ZNXrq8/G2//CJVOz49DXHwf6GfaQET7stpWcjEOwPFIV6/hXPobSFqOnlB2UxR1YRQZRuIfHIXglZGWtIVKkZw+LYOodrS0fp
# DATA T3FYJFqqh+C46Ya00lwox4/kQHr9uDM5bgP/BQ8KJlUkOvsMLPoOQQYqFpsxQE2b5+jzIlYy618VPEbWL1NJgWwBOjdQYUghuBKs
# DATA BiDHCQ4msTEngLWJfrygqhgEfXbAN1hGzwU67Y4GA8bWKZfxNMa+EW8vlwX7IZqrIRqgZnTiNzxhIJnEWFDPaW212z2ZdLpou1gG
# DATA bRltHJ2NWHKqVtGbMEHuNOMFWAjjjVn7JyHbGBpN7Ky49x2L+Xp0FA2tFPfgX25oLv2dsXtvmlQzuETOXZxG8nrbols4eyH/RGze
# DATA 5xB4+alN2+ef3Q7IPwl9mj+XFthUEQb5Af8gH34NVYCZFJyi0QPSgiBVO6NQtOfLPJIYNgr3AICTKZvOK4fnyglC5X2XaSmEO4S4
# DATA YNdUjxp1ADderzdy4T5xNTSkuMJfm8vVloIhks+qyy1QuwK2etgiPaL5u8kyZa3MMilYjKtZajlm81mir3Z6e3b+K3RwBypKWsa/
# DATA UFr+YsKNL1wUy+4I6OBDUBmMuh8l7mXgCI/oFUO+QYpvW+21Rn11N3hKXxrrHzTk582td7fu3dv6wJJUCLNdiI2TkzGgoEhoioMJ
# DATA 3F4cx1ZESHdwLzY2d03Yi2wYjCQUhgR/12+0N+5uukrb70en+yMhHm3InhaK2Wgcc/XKD85hzAobvmdfS2GZjDkDBZi4bYqHBfhP
# DATA iZ/c21r7frv+gwzNdEIW1FhUL29hSExmNb0joRJiUMAR/8Nw1tvp/O9rjMN/8TOMuCFe6ddGhbbZw9xOhuFjPntGov+zTA5mq8ro
# DATA YNouMJj3H1Gt9vNUHZpngFKiCP/YbAyUnqTcOQRXxFdkAsjU/y8v3bx147qr/3976XX8/zfy9+Yb6uINGYjHp9Oj0fD6wpUrV+5x
# DATA 6mbI/0JUIp3UKrBPONUzpXFGXHtEAgM0+8no5PAIJUIlNec2DBx1YjAIqK/HnS5ZCgByBPUYcOTQj6D3BUyQBsQEx9P3BGscXAa8
# DATA gBAh1WdwtZpSs+nGB+AZlrUBGzuZDERblQn1TrbJnS3Bz3BwLKgOEO8xWtEODwhL6/2Fka4XKDsxGtTZXt9GV38hyRnI+Atr9zbg
# DATA xoRrjrm5SeUiJYxwYW1rc1cIYvUGoDztNrbuYXFbDAFl6mQ0CBd26o33N9bq9h2M8cmQYpQaceHB5sZuu7G1tatlG5+z2ML2gwYk
# DATA boD0kyl1lh8ui5Z3V+/WdzBECrUYnNOjN3o0REUORkpRakFGIKVcByEndDzlF8CZoz8US8l4pf0D+UtXkPNQvFBcuL/6g/a9rbvt
# DATA Ox/uYpNG2LxS21LioMnoUMx1zDlRJnKlBUEBfB5imJeC6KEOj4Gs6RA+GR8F+2BiE/tIzMOYysQlzukg5VIpRsd4Te48CpgMZSS4
# DATA TJouKa4GSs12H/L84QNWRtGV206rYGXPRA8X2D4KLJlXfJHVJkYSOdbOsAuHaE9mMZadkPoHXShNYWPUdxjJQGheaMhiDnOiU7lw
# DATA 5iRadYIQhytm1Etqbh4g3SRzutxt1Hd2bLHbGTBlxpDriioFOS4n0+JwBGoxjACF/xQ8929ZjTXD2mrAkg+AXm+Opu8COTjRZEYF
# DATA T0KcJfTPoXwK+C+qU6PeKsA7ix7BjRopCUC0ER+boVxiA0XcSFgvG2hy7S2FXgAvCWYhtlSEyUeABwlCjaU25Hj0MCKvJkGwYD7U
# DATA vlCw8R4J+TJWSAW0phUwID8uYEsQQWs9lZ0qJkffNEbRasqCLUzt/riwVMKlKLtj0TPTKiaqrBBnob7UeEbt12qiVk4FDtuY8t6L
# DATA WYAQhb3HS0vlvcfLB3uP3z4QH75z0OJEWVi2KO6gK5xuXveKFwb6XfA8vRY0n4QdvY5YEyCoExOhguI7/nvWKjbLKzeqbhucew4G
# DATA LZoRFS348rVhJjt+x+fTSrW43I38u6oOw0nyAtsxHsslNLX+BJ/e/TJ7gzo8z9io9g1D3SlMDyvpTVVM76N/pyPZiucOFTv7SWkv
# DATA xoOIo630hI2PECGbvT+5SMgTDKc8pWVWHbFZb5KrJqzcADQPvuGZLJ4PWTE00Vzs5gtFHYHcfnBIc5XWpnT99wCmk5i64Nz6bbyt
# DATA y8c0b02ct2rLm5xPTwG6oxR4u8cnxwVVaRMrbGXWLZhDYSaPKCYTTKJzhupELViqel0+3LXi/E8DNCmC5UX5zPX68XjQOQ06GFHX
# DATA AVj+4MpSwGADVyqu/0E2yRpegYkEpkJUNUhZHx4JApUHyQbMFWTrQbK+FizLH9bE1APfGUTDAs2rL3kDku7OFJMpWGU5XRmTP16w
# DATA sQk3mU806RJ/W15a8rxDBECdu4plFs1W3C7FxrFobBn9mDIvSGZZ9bNQp9Jo0BnHkN0CV0u8ZFFlwWjnQJBDfEQNkTz0CIjQ2xM8
# DATA voqJEUBE+DF0pCGpy2hXPjKP++SRcibYeXcgSMGShwwnS6ksFsRCjF8ifAxGh8z02dOBz1zIlAkJajx5GCVXwWwHyUyAeaMrN4bo
# DATA eK8QvER1upYcKbjmS7rFMqCZaUSF3x/0/OrVDxpbm/c+lDpVS9la/8HavUxlawKhQIliwCeTuRGrLmNV5SEoFzoPtwQr+sxdKr14
# DATA FYIrkmGX6rGVVpL8fvUvFDzuARyQZay0qWmoCGJGugNIXHvQc/2gDC6lVasHPY7rT9JlG6m7QBcgvltBnMdUB4Hy5YiknULYBBmB
# DATA sqlNJwd4godvfVh+67j8Vm/3rfeqb92vvrXzNyG59lUOj+mMRzGihV4JdA+BREnwjZoiL4lQRdSGJ9OD8rchGhVGHtdCdvOQMgj3
# DATA SXoeJYfFaExMaZGxP22iyUWVq9vb9c11lxRTHazUdINGlXpadR3gU+Y/ZPBjsg2xqrWilNOQQkl5dtCPxbw1ixs4hEkC4h5cmbIp
# DATA zGBilG1MolslWJncFqlTjJOTygmZAX6zM8UbBH6y+Czzq+ypMcVZmiGpNDFGh+5u2uJzSZzduoeDRuXB5ur7YhpW79yrh6ksWPYl
# DATA uTSzTF+NdXMXSLrX3zfvgOkln6PhRMKKYNCTvcrHggcwBBL6DQJmBpXz+A06TiiVnfbGTqN+tyArkVgbqVEsOWZR3wBOht0OXTTM
# DATA +hnqw1Js2UY56n0cRR9JgSbxftl+3xkiqKdqsh64bRTs0h4aTTXgZI+YgoHxRYXhIMdt1gT9Ef8FY/IUnd4K+8izmyt0YVElmlUo
# DATA NhFSW4+LgABMhcD1m+th8LB0Vp/Rm2jY45sMTDLkGC1MwjL8AaMGRIOgdZXh0IPv1z/En0LyPNfzvB8d9ofDlIru1O9ubOauCtAL
# DATA qE9w5COgh64dlG/4I3laCLngu/pX+cyhV56osNmor6+u7dbXA6MPLTyDRYkm1wvYTkVWX4jrj+BRsca0svY8/yoBoZL3WMugRbfX
# DATA JqWwkNfveRUA6vpkZtytBU9ki5SvsaQ4I2fjlF89WdZYzKEEdAZPlY/kpR+0ytAUps2TP1YOB6P9QnhVKjWa1Vs3QF+EhVQpb8ux
# DATA kFASb19f0dBh1CSIn9x4hjYBQVxsVQK+k2B1hpkV36ErjyHG47Hu4XfGfIMbCZk1sIqm8XqrWLz0i/KBlU/dkMb7UdaUeA8kX5rc
# DATA Cx1PL3NEpZ06qedVxjHE+BzT/vAkWvAEuhiJi9P5f072ad6OCC0VabMCzBnuRYLb/XAvvlp4pxo9BuPYXnyt+E6BIWHaLQM9pnW1
# DATA KArWoHDlavEv7FzFYKyp3C9W/TofzVmJ+zwFOnkkSP0p8pWnLOU91YGRTwFj6Z2PotOncGSCkgxilp/GncH0aS9G6AAYTHO5hS1v
# DATA pMyy3GJUeKVleLxhYua9K3thWPS+KjoOChGsoRj8ZS24UU0NUHJ4Kr3j7qmEIJnYMFQNooiMQJtReEL9R/Qn/AQ/MXf38AViA3gA
# DATA OV0/Q8zI2gBysjPSC93ojb1I5w38o3zqqa2ScQi1ZAwKH+NShV94p39cLHROpkdii/8YVYmCUJrVWouIa18QQDR5Khay3y0Cje3t
# DATA ACbNJNxbNuo2D1W3hZDbEJU1rwie9c7evkWc4vlOfa1R3326vbqz88FWY/0pJhp5ysdm+x1xbj4VBdbrm7sbq/eerm5v0LPVB7vv
# DATA bTU2/mYVEvIU3Uq5MTWYYvOHe5O9YetaGM43gNlCRXMv3ttpXX1HtDpLlHn6F8WwlCocZHVjbz86/StjkCYEVNr3/dCmgaz6CwDL
# DATA I15v8b+ijmuVcutqdXERpi5e/F61da1Kn1rXvpeYw+9l9/7x8v5es7lUfqd1tRmUF8V/v1f+79JalHhPQnp1jzqTThcCrBGYR30T
# DATA +wlLgoLUfAjxEdMQ5DbBpPTbuJmurwTk42j98EYtWF55O0tkVQLdOl8XA07XGFPUdyeeEpJ7Jdg9ipTC1lLdkaYSPEcIqx3dKioA
# DATA w8fyoK2lljc/cRWWHylp65R0w/AGQI7IzsIj+fmML7cDQOydtpUjSpv9VAraAt8gI3hwfDIF7+PgHr6CGPQl6OdQsKMpdhi8J8hJ
# DATA QHztTAl4Pph2Dg3T+3gU9/mqrKM9SeRp1O9vrq5BsqNGfXtrZ2N3q/EhpYSdTo87w0WFelNW3XXtZ6nYaILOF53vQJuqO/mM4o36
# DATA vfrqTl1Fe0qzHjutFLTiKZQpgMRJVzkUUsnJPrjULmKLi090w2eL0jNokdbiHeXW0UbXjdoT10v/zHCCJ5yyuPYkXO3COQRqEXDg
# DATA gIAUwEd9OOxx89dQoi1B0m5Rb3mNDYRVEMjLXXgWemJ0wweCCsurh5wSWS+BeY8Iz+hNw/GTvXcKysnDSJkBQtgkisejYRwlbqD8
# DATA nGSilZu32JMErphqreH4E8XBKq5LXGgBceZtNBOo2CQq4xhWaVUB9fIiFCO2Ao4Rq2FUj84hKrU0JRecVkUJPvrZV8Qh84d7PcHT
# DATA 5X+AT3YOnWjNid1mb9I5AFtLP8b6MKtiotBYnOgyK7FV8iID57wOMBbwQrfCvvgZMyRZksSbaspKmAKRf1asSRFHLv5bfEdMj1nz
# DATA jEG8X2/sCKlBKd8meO+engjWXTjujAFRleuToOeQQ0qjJA1PC/AS0OnyjbdvfPv6rRtvkyUDnoqTCKu8SF947qhL14LCUqko9kHh
# DATA RlDG3UH16rBZy52mmmmx8V+7vD7dqAmfpAAKs8aPA4RxOwN27k1rFyOutETVzTUNO7uQAo+piuV/Y/daiPx+osm/ec22eMKxDp5W
# DATA 9qSYi1JBKY38/MGDjXV+FcUL/JhzZ/31g/rObnq/YvFobLqhtGXE/LE4deQ3zm+qoICrM7zf2AHC4wS2YOBui++2iUyMOUv3lF8h
# DATA /mBzZ/Xdent7dfe90OpRPrumLJywaia9+vScKUrSk2VAs9Iz1B67aFi6fDoglkEkqqoSqqlcS6bRkPrcXGo5Sj8KFkWznJkZWr1R
# DATA JL6+ur3dpqsUitU+jC/wdK4FNBKGzzL1SUpRY43NCKEAPYStcv2hbrUGV4gDQPh8cuvGmdQ0sIYhOSSpCECYXMoDZADIMhuh0qB3
# DATA vb6SSUT3N3Z2NjbvygngUxm0FID5etzpVobRI65Owf+WAva6LUn360p81BGSB0pjvf4hiH5Fj+9YOt2XhPhOStcqNX/moHjLioCm
# DATA CubGLSbyGPAKGVJfbCIIsouxQgZvSsBBcA/EUG29cuC8gqhj7MguOAljAhbCh6PByXEEjsBNy0VQeUc28XVSReEnSN5ENfYPvMqV
# DATA grEFsCQzZ8rjBA+kjISgiej6lXDABhaTt3alQEm6ccvOyoO8GhaFVLLSKrYMTY/ahmL1Tsdw8Qr3+0MT4pEA4ZjZFDXgYzXZJLtX
# DATA tyFOQPwOrOpswee9YHoZwFHRlB1p+aI3LXrnptr3tx5s7kLD797bWNv1JEPj6h3DHa6e1HvJVn2Ubh8tEhHYaEBOCerdTS9plZ8i
# DATA LXd2youwg9inr0pyKfi0o4ugWJV+D+EI2MmyiubcefM+8dK9TwKprCQIURPLX8+SgK8AuBv12nyQGvnPpT26mIpqwQHbhRmYr6Ak
# DATA EFd8IGzIkhsUiL+g3kC6dUp0CxcL1wGkSALexn1QTJgYtyoAhoNfgvIdNL0bQ6PoCt+40BGEImLxJXN24CfUcSQ6BeAd0PRoWGbP
# DATA hL0hP0NYWhuONz/WhY90deTFYsABGyUOPneXNpE6UmMLJKEySoQfYYgg2a8rDI2wXB6OHokP3Ju5a5rQTKXWIC8FCJAiJFjQyU9P
# DATA WWA0JBdDAwQAuIB5NgCOdaryngpeiIfabUl3ENPZ6QVTwI6hYzXqiCMbp1vpgFJFTJV4IP3gzEhDYImaUjZ9KQFTYmtSWx5GpeMy
# DATA tPRogr1mCmbyGc+4OAciU27MEte4Y9dXgu/WbAGoFtxY+s4thVl+pG0KrBslHOO9CULsoD4I3PPDVvGPSG6SKRuSMpLy0USNVFXF
# DATA ZLfbfbFj223RhcEB2ZbNiGXxsJJOdqqIvuLoN8x7jmoORS5sK+kIb9wjzDrdc8+orPMw4n4nVBPWtGTVx+868Qk6ZJ30pb1kn9Gg
# DATA XXN77VrcOZO54+3el6FdDD0LQgB4aVOEExv+A2U3p1KCtcre+OEnLMLb3Nptb2yKi/g98AbTTUs1EdXcDPm7B6YjUUJPCzh0McFI
# DATA NSW4AZj34dnxYgp3DpzpfRmn5AUTJ5YoJ+EDkBkjdgmeTtI+EMhlkfpbN2RLTEmYAUqc1G+MORgoRREXqsveyg1IPwLF87lu+dUd
# DATA 7qSm7rZCCE3h+HBp3DAX/+TzVLzqBXA6lr0KTMeWG6LapIYvoqZr9GVJbnUN5OlEzlYGmDjCqLZo+V1DQhxyLIAqHEcm18kD/gAs
# DATA Lt/aQNVNIa5jSJd/hXiVRJ12HBCGOYo5O4nwAiYDHumCZ8QfBWX9rhlIsASKx7dXllLiVOAdjnvDFmsyfpJ9MWqCQnfrjcaD7V2L
# DATA M6ku48hELQQ7LiSoquoHIIWbiQVMwhNDMZMa8HDVvQPtYYegmgkdgPHZAZL+rqmAKcu4OObgFFrzM+O4SoZXMxPtHnWGSe6JOmMk
# DATA AET2IBMCKIw7XcLE8XIY+SPqTA3GmRbMlSXXba+Dg8CdBzsfJvw/T32BVOQ9nBxmBRAvj4T41v9xZO5AGnfRtxi+WtbxnzSXzvSB
# DATA GK7O5NNJPsrmpm+TsyEtB3FmRUvqkJv3ZNOhqiq4WN4vJMqSceUQMvvhpNOLcpzt6RweGY6XU4mhoRLCnH8aqJAoRo/avX6MuGUW
# DATA 1FJiIBBCKPuJ7AIaJNI67gxFdT2yeSGxzhzH9urdevv+xt0GupjgcDYaFk9I3QPwNWUH0E+vlP7Zmzz3yTl78xjqQF8Md0p8TvLs
# DATA rWWcvd6XNcvEg1t9TffqmlvkcBiEbH/2wC5wYNkVOKfWdzNOrbnWP/+JoRzZXPmLDgoIqKMwe70OVZP1GItb1cK21tfpWTFjEY05
# DATA cfVu9p70RGw7+TVSKTZFlUJYjJlIhaxTKyPMG4ABGgCGJjTHoSVl+7WQ4j0FYqhVW1Sh+oHRl+53HoMSDGgACrjqOXzpDih/UCmX
# DATA 2h6D1MGposW+EkunkCkrmnD78KDfCyWjFY9AdFDniaVdshw9fMRWuCBWlUV4MwQzcV1s7LZVBBHLS7VkqNOC391TnSw5RXVPwUlY
# DATA 5ptPufXk+q2zPS7oi+qag4RTtrg1YCfQRAZDAUCtLSzAIluywgUFhEu/Ec7Fmi98iDmHcrE644KZPMby3B3J6J8AMQD9CDO9NBHU
# DATA egzugY5aSsa0FXJSadGtsN2dRBz9hBLJbGZJ0XmIhKID/oz9Arlt2A0x34ZIUrfdL2ApfhbQVNegFqM6ie9Fj0CSGmGIm0bu3Zo5
# DATA ffrkUnDfxhIaokbRf+27ZNFVzb6WX+Uc6L60fHLIpUi8LyX5Xvo94qXEN9/hocSwl+HJ5BjliXBVaeMJsLW5dm9Djy2ZfpVOXKmq
# DATA RFwb8AkNWxmrif4QXDGtZVq9uCdN5YL63PKfhI5sdJWSvvhlglNwKIAJ6vWHNePN9fr7mw/u3cNfQC6Q+4/yTamvPhHi7eWlJb8M
# DATA nrGt17bub9+r7+LJb2/tfPSgoWWkPKEzpc8ZR3UxCad/YDJBPzlxgDzBBMyeIhkuLz5LEeRCghXu963tOu93r8DBnMkA9Wh58IBy
# DATA 7DHL2nKS0GdmqtX92D+ei1YKyAjqBm8tuYlrMB9Am7SbPE5S19v7Jwm8ntC5szhlV2JPTQeTGtZmGHv7MaOj25cV6EJL76SbRSNj
# DATA EoLzeJVu0GKS4ACfpyfEoIBuBRqgZxB1RA8Bzmx/MnoUQ3Ji1loA9AxQwDQanFb83DJNHZJ64U//MZeVJV1ws8jDY4kR02UsfTXT
# DATA jcTaRQxbz94pObTIoM2X26ZmEGoxu00cMloR7dMpmcfpZDLhyEN4R5sF5wwRLaZV69UlX73KOS/DzkMxeHRzqKqX2LWcnWtUl7Tb
# DATA DRdMXmQVrpko5IKwGTIWTcqZafbrynsPJJtyQ+XIwHwvQW1kZ8ZEju12oT8cRr6gXHyOcaIMd0Cu0tLR2rXhMg4oApaXkiDkFmCO
# DATA C5IDE3rNI7d4RXcXYVv308HZFq0VEFMK5oaEC+P3zTvFTK2YV2CXecigYSFqbWylaJns+cs83axptqjO06nk7YbX8jH6DGBdpeBq
# DATA 2x/gqpuau8fc/j28X1oHmtLSS1+H5N2bfmmjK3/JuInrWAp0NCmlXs0vrnVOUbvMYq9+Q/YsXa6loXgpfeYFLe1ZHUzt3Cx0wQsN
# DATA QDk20aqDO49cbZdh52sK3Cc26x/UG05DbwZbw0hh6qKg8aORGGhnAPw4Pjk46Hf76NgFcX0yRhFCtEDrALPSERe4o36MoDaJUHQT
# DATA qMvkeIyuoPAoJcxCNT8PY2K3YLqa4AJloFwWq2V8wrW3UkPAXx7ZKxvhK+edIaXeDKW78nylC5NPkS5dX7W23fVnZdbjH9OFFPGp
# DATA ksg3o35PU3UnVPJ+B5hSqhp+ps7+m1HNm1r5PxYVfC4Z9zIV8jOclyDg3Co0lxo+k4AvS/lu6N0vonF39dZpJ/pL+53lwibP0Fn3
# DATA hwcjn2aew0qz4MJ1JBIhAOWuIz6aU88Nv5smBJ92fQbJFS9FcY69YO35bBK+ZMV522+jN9SaRGWH1ZzqONQ0aRU7T1nUI+bLanXs
# DATA jX0qoRsYkH7NmGn/+U1Ram7WaANEYGtrl+NxLC6qS7Ag9ldbd6xz0sQhwCDm9sbmu1vtd8UG5/qAsoup8SSeCuqbu40PzRqQsB0H
# DATA LmeZ6EyHRdI5HBbmuv/b+9POwWAQnx65mSvi/N914h7K7fPpi59jXq6P4avlwZByL5IpAWsZMBO5FM+k3BYCAPSvLMPSHV25qryF
# DATA EYU1iCrME/IzU2ONtMzqavzsO2u/k6aq1iAD2pSI9JNSGj3TexomoEm8QG0QPxKScoem1/2Vg3mOFK0HV96XiWn0Mj1RH8+qnNjm
# DATA iazwTIV4iFf4N/8GPtsbXlEhAOn98GWVNg6mxICC7+qrkLfd4lyuPnJjwgWpUV9d/zCcpytzXcsucD2zHOyZCtTiaFb5Rk2v3gUd
# DATA nUyQBk/ryKYSUTYgFKhfZt2MLtz8m8Ed0ipDe5RiF3HxjzuncN3CjEudYBgBbvyYssToPEuVhZnaWUXPPKE1P11JFY0sJclACbtY
# DATA XTobfEXc+V80M7ZyrEFWuSrk6oQ8c5+df/niFwGdpLLXlA4mH9/VN5j9jpCsSsbRZVgxJcCjnxubxsFvii2n0rO7XWEL+Zd9LoJm
# DATA bI72/Y2d+6u7a++FL7PKnFgJFvnfzn+VzJb6O8yUCun0/oFSCIYzFnXmdS2PyXOWqOeYXbOFPH/VqTofateT7STp9JOdiqg4s3o3
# DATA e46T/8FIo+M6bM5Op5PtX+C3DNiJRiAkzsxR5O31WYq4fAHDTqY26pUawd9ElDS+ehCGDAQRBqhh7wX7pxRjOh71h9NKsC0mAQKJ
# DATA g21UtCwOoylcsj21srIBolNHJbzfiDaC7mgMec2UorPX7xwOR/G03wUV5nRE50tXpkW/kMk+xR7fNiHs86tBje0w0/R1YV6UIH/y
# DATA beaWCYdDH0q5wutTeNpXqYxNJi1buEx6TtAyKq5pUTAAf+fDnd36/fb26tr3IWOK9GwSF8HtB7th1ki9eVONPbCGJ8+2vQ2GPSIA
# DATA x0j/9s2slnD+Z2VsNY4pmbCVb71ehdWF1Hs8cW7Am5MI/WL+IbkkKLhOScX7cT8Wk3Bog/8kVEqppVUOmGH/8Q7iLxbMHJeV3SNK
# DATA iXh4v/94Y1iyEmBW8CXkVfSqTA+AwADtKb4am8oZ0AaCtYd3nOviIk6DIUWDl4JOr8f7PT4Zi15hJIh6seh5B9Bb+HZauJmwSXrq
# DATA VvBRou8FjLnnvtCUcP7Qgj+taNHMO0Ds8FjUKaphVWfCvGptQkIkGA9OZSyZ2AIlxBBz3tof9U5tXA0spG6cHntENOy1Ja5gAUql
# DATA FSIwxUK4RhCaZQDEkBkxJaCiR0npqcCCWCwhxCKiLYR5m74XDQ+nUuIGYxaM2/U3xdf127Fv9I/QME0iBtZhTfkRLl4a/ZmB8dlE
# DATA ZcIBaPGMcBvyIM/7TNEIKwCiaWcStRktAHvDo2V8BBOUmCASxH/uICAx3nywhWK6ZRfPPaS8G0vXQcCS5q3w3a3GnY319fpmeJZD
# DATA xStvFzIbKfho3q3vkrct/kJqZsgXS3JEmG0P1x1bAUwzmjf2hfOHyOZon9IRxCD4FMJFUHJTaP9iqp9tVm+UFhuqJiusU2frcnt6
# DATA GKV2VKIzpvSH3mxJeKfFbFxwwk+E2+HKq4sgS59TbB7Rz+nT0sWnkQiOo3nn7w2Fkr9k65Y7MkXBXoj2PZHHOXu2vbXzsl0bIEdW
# DATA FGYwoTYkcExy7mYrk8S4PsKWVmGeFm/bnXSG8UE0KdfhcKNYQVa/8duCMir9WDDH/lSr5paC78KtpaDLoMrSBsm9NGJmnE8DAZFW
# DATA D88dhP10+lLMdMcwRFioWSLC4fxMGS/0DXCBQLwTjItnXLJG9LCP6oWzb3rL+ggTe/qSxImbb7HTpXjKP0+qXLl568+IKGHFPBgO
# DATA OjTsVdCm5tQc/w8dasq+tEiMtmKF5CPdr1Z+sl+50NmQSuQkFr4m7z8F8rbVuN8QYZs0nbDNXAYdp8vU1uXghnU5ANPdu1sPNtfd
# DATA y8ErVYtaHfoOefAoBRBsJ9O3lPQ9N8Q5laVG0mO6gC7JXUdjLnqjtpAHAR7OumOavwNP8BcgtYp0zKFlSnrNQymFCGi8oqD6kISN
# DATA 534sQOdln7XT/R2/FmaHLTOm4M7W2vfrJpWb9Vkeo+hxYyqfplIBRS46JamGIcx1LFT1ViuBrm+ZjgmsqMJ/2gcjTBaECVb74A/P
# DATA yTWBjtptkGLa7VBmPZ7E6Mgh9h9+rqxODk8AxnAbf1GZtsBC2hYyULfdLhpvQn6ydodfKWgXR3Te3EYNOAMN4zdxPxuNp4vKZVNa
# DATA bryVmSdt92gEyMY1AjlG8VA7TTrIBgiTLoNOxVSUJRImlpWhJa3MYcg4yMxCpDwv3k77fdDZjwYZv6OZLbsJ8AZNrwDVphm/M3pv
# DATA RgnGpeROcDArl8V/oLTUP0GoKh6m0UmfbaxLLrrkDrr51h/DXbxxQvluyK2E9raCrYZcIUArOqmCaKhih8LqOKCFNPMGvkXmDfwo
# DATA Jow/4erwZ1wJ/oyzLtHR/e0SBZk4kwC87zbFwU/4mWeav/GsZjeSoE4L0s2GcHWbztUA7whdLWJr6rqKFXRYldOWXZm5xzJq1PgT
# DATA +BC/9nt6bXyo9KSXdqsqLnzr9d/rv9d/r/9e/73+e/33+u/13+u/13+v/17/vf57/ff67/Xf67/Xf6//LvL3/wEklutGACgPAA==
# END_REMNACUST_HELPERS_V1
REMNACUST_INSTALLER_PAYLOAD_V1
if [[ $EUID == 0 ]]; then
    bash "$directory/installer.sh" "$@"
else
    sudo bash "$directory/installer.sh" "$@"
fi
