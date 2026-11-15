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
HELPER_BUNDLE_SHA256='ccfb4a715e214a2c89e71167f54b9cb8c9e5cddf2a60208585fe42656abcfb4e'
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
PANEL_IPV6_MODE=auto PANEL_IPV6_MODE_SET=false
NODE_NET_ADMIN=false
NODE_NET_ADMIN_ADDED=false
NODE_DOMAIN_CONFIRMED=''
NODE_SITE_MODE='' NODE_SITE_PORT='' NODE_INBOUND_PORT=''
NODE_MIGRATION_TLS=false
NODE_CORE_REQUIRED=false
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
  --panel-ipv6 MODE         IPv6 egress панели: auto (по умолчанию), on или off
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
            --panel-ipv6|--node-site-mode|--node-site-port|--node-inbound-port|--page-id|--page-operation|--panel-url|--panel-token-file|--version|--component|--directory|--compose-file|--container|--project-name|--domain|--subscription-urls|--subscription-port|--server-ip|--port|--proxy|--node-domain|--email|--tls-method|--cert-file|--key-file|--dns-credentials|--panel-ip|--backup|--source-url|--destination-url|--internal-squad|--quota-mode)
                (($#>=2)) && [[ -n $2 && $2 != --* ]] || die "Нужно значение после $1"
                case "$1" in
                    --panel-ipv6) PANEL_IPV6_MODE=$2; PANEL_IPV6_MODE_SET=true;;
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
    [[ $PANEL_IPV6_MODE == auto || $PANEL_IPV6_MODE == on || $PANEL_IPV6_MODE == off ]] || die 'IPv6: auto, on или off'
    [[ $PANEL_IPV6_MODE_SET == false || -z $ACTION || $ACTION == install-panel || $ACTION == upgrade-panel || $ACTION == migrate-remnawave-panel ]] || die '--panel-ipv6 доступен для установки, обновления и переноса панели'
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
operation_interrupted() {
    local signal=$1 result=$2
    operation_log_event INTERRUPTED "signal=$signal"
    if $CHANGED && [[ -n $BACKUP ]]; then recover "$result"; fi
    exit "$result"
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
    trap 'operation_interrupted INT 130' INT
    trap 'operation_interrupted TERM 143' TERM
    trap 'operation_interrupted HUP 129' HUP
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
start_selected_apps() {
    local service
    local -a stopped=()
    for service in "${APPS[@]}"; do
        [[ " ${START_APPS[*]} " == *" $service "* ]] || stopped+=("$service")
    done
    if ((${#stopped[@]})); then
        compose up --no-start --no-deps --no-build --pull never "${stopped[@]}" || return $?
    fi
    if ((${#START_APPS[@]})); then
        compose up -d --no-deps --no-build --pull never "${START_APPS[@]}" || return $?
    fi
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
node_application_ready() {
    local id=$1 service=$2
    [[ $COMPONENT == node && $service == "$(get mainService)" ]] || return 0
    docker exec "$id" /command/with-contenv node -e '
const fs=require("node:fs"),{execFileSync}=require("node:child_process");
function coreReady(){
 const selected="/var/lib/remnawave/core-manager/state.json";
 const selection=fs.existsSync(selected)?JSON.parse(fs.readFileSync(selected,"utf8")):{};
 if(selection.operation?.status==="running")throw Error();
 if(selection.paused===true)return;
 if(process.argv[1]!=="true"&&!fs.existsSync("/var/lib/remnacust/run/core-state/checkpoint.pb"))return;
 const service=process.env.XRAY_S6_SERVICE_DIR||"/run/service/xray";
 const status=()=>execFileSync("/command/s6-svstat",["-o","up,pid",service],{timeout:2000,maxBuffer:4096,encoding:"utf8"}).trim();
 const before=status();if(!/^true [1-9][0-9]*$/.test(before))throw Error();
 const socket=process.env.XTLS_API_SOCKET_PATH;if(!socket)throw Error();let server;
 if(process.env.REMNACUST_NODE_RUNTIME==="1"){
  if(!/^\/run\/remnacust-xray-[a-zA-Z0-9]{10}\/api\.sock$/.test(socket))throw Error();
  const parent=fs.lstatSync(require("node:path").dirname(socket)),info=fs.lstatSync(socket),uid=process.getuid();
  if(!parent.isDirectory()||!info.isSocket()||((parent.mode|info.mode)&0o077)||parent.uid!==uid||info.uid!==uid)throw Error();
  server="unix:"+socket;
 }else if(/^xtls-api-[a-zA-Z0-9]{10}$/.test(socket)){
  server="unix-abstract:"+socket;
 }else if(socket.startsWith("/")){
  server="unix:"+socket;
 }else{throw Error();
 }
 const binary=fs.existsSync("/usr/local/bin/rw-core")?"/usr/local/bin/rw-core":"/usr/local/bin/xray";
 const response=JSON.parse(execFileSync(binary,["api","statssys","--server="+server,"--timeout=2"],{timeout:3000,maxBuffer:8192,encoding:"utf8"}));
 if(!response||typeof response!=="object"||Array.isArray(response)||status()!==before)throw Error();
}
const s=require("node:net").connect(Number(process.env.NODE_PORT||2222),"127.0.0.1");
s.on("connect",()=>{s.destroy();try{coreReady();process.exit(0);}catch{process.exit(1);}});
s.on("error",()=>process.exit(1));setTimeout(()=>process.exit(1),10000);
' "$NODE_CORE_REQUIRED" >/dev/null 2>&1
}
wait_ready() {
    local service id state before attempt ready
    for service in "${START_APPS[@]}"; do
        id=$(compose ps --all --quiet "$service")
        [[ -n $id ]] || return 1
        ready=false
        for ((attempt=1; attempt<=90; attempt++)); do
            state=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$id")
            if [[ $state == healthy ]] && panel_processes_ready "$id" "$service" && node_application_ready "$id" "$service"; then ready=true; break; fi
            if [[ $state == unhealthy || $state == exited || $state == dead ]]; then return 1; fi
            if (( $(docker inspect --format '{{.RestartCount}}' "$id") >= 3 )); then return 1; fi
            if [[ $state == running ]]; then
                before=$(docker inspect --format '{{.State.Running}} {{.RestartCount}} {{.State.StartedAt}}' "$id")
                sleep 5
                if [[ $(docker inspect --format '{{.State.Running}} {{.RestartCount}} {{.State.StartedAt}}' "$id") == "$before" ]]; then
                    if node_application_ready "$id" "$service" && panel_processes_ready "$id" "$service"; then ready=true; break; fi
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
    panel_ipv6_candidate "$WORK/compose.after.json"
    mapfile -t APPS < <(get applications)
    capture_running_apps
    START_APPS=("${RUNNING_APPS[@]}")
    NODE_CORE_REQUIRED=false
    if [[ $COMPONENT == node && " ${START_APPS[*]} " == *" $(get mainService) "* ]] &&
        docker exec "$id" node -e 'try{const s=require("node:child_process").execFileSync("/command/s6-svstat",["-o","up,pid",process.env.XRAY_S6_SERVICE_DIR||"/run/service/xray"],{timeout:2000,maxBuffer:4096,encoding:"utf8"}).trim();process.exit(/^true [1-9][0-9]*$/.test(s)?0:1);}catch{process.exit(1)}' >/dev/null 2>&1; then
        NODE_CORE_REQUIRED=true
    fi
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
    local result=${1:-$?}; trap - ERR; trap '' INT TERM HUP; set +e
    operation_log_event ERROR "exit=$result line=${BASH_LINENO[0]} functions=${FUNCNAME[*]} rollback=$CHANGED database-changed=$DB_CHANGED"
    if $CHANGED && [[ -n $BACKUP ]]; then
        if [[ $COMPONENT == node ]] || ! $DB_CHANGED; then
            if [[ $COMPONENT == node ]] && ! compose stop "${APPS[@]}" >> "$LOG" 2>&1; then
                info 'Не удалось остановить новую ноду; автоматический откат не запускает второй экземпляр'
                exit "${result:-1}"
            fi
            helper restore-compose --directory "$BACKUP" >> "$LOG" 2>&1 || { info 'Не удалось восстановить Compose; приложения не запускаются'; exit "${result:-1}"; }
            STATE="$BACKUP/state.before.json"; load_state
            load_restore_apps >> "$LOG" 2>&1 || { info 'Не удалось прочитать исходное состояние запуска; приложения не запускаются'; exit "${result:-1}"; }
            local pending=false
            if [[ $COMPONENT == node && -f $WORK/node-state-plan.json ]]; then
                pending=$(python3 - "$WORK/node-state-plan.json" "$BACKUP/compose-files.before.json" <<'PY'
import json,sys
plan,manifest=[json.load(open(path)) for path in sys.argv[1:]]
print('true' if plan['copies'] and not manifest.get('nodeStateRollback') else 'false')
PY
                ) || { info 'Состояние snapshot не подтверждено; пересоздание исходной ноды запрещено'; exit "${result:-1}"; }
            fi
            if $pending; then
                local original primary
                original=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))[0]["Id"])' "$BACKUP/container.before.json")
                primary=$(get mainService)
                if [[ ! $original =~ ^[a-f0-9]{12,64}$ ]] || [[ $(docker inspect --format '{{.Id}}' "$original" 2>/dev/null) != "$original" ]]; then
                    info 'Исходный контейнер с PRIVATE state недоступен; пересоздание до завершённого snapshot запрещено'
                    exit "${result:-1}"
                fi
                if [[ " ${START_APPS[*]} " == *" $primary "* ]] && ! docker start "$original" >> "$LOG" 2>&1; then
                    info 'Исходную ноду не удалось запустить; её PRIVATE state сохранён в прежнем контейнере'
                    exit "${result:-1}"
                fi
            else
                if [[ $COMPONENT == node ]] && ! verify_node_image_policy >> "$LOG" 2>&1; then
                    info 'Предыдущий образ не поддерживает сохранённые квоты или состояние портов; нода оставлена остановленной. Установите совместимый выпуск, не обнуляя состояние.'
                    exit "${result:-1}"
                fi
                if ! start_selected_apps >> "$LOG" 2>&1; then
                    info 'Предыдущую версию не удалось запустить; сохранённое состояние не обнулялось'
                    exit "${result:-1}"
                fi
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
function selectedCore(){
 const saved=privateState("/var/lib/remnawave/core-manager/state.json",1024*1024);
 if(!saved)return {path:"/usr/local/bin/xray"};
 let state=JSON.parse(saved.toString());
 if(state.operation?.status==="running"){
  if(!state.recovery)throw Error("Missing core recovery selection");
  state=state.recovery;
 }
 if(!["profile","managed","bundled"].includes(state.mode)||typeof state.paused!=="boolean")throw Error("Invalid core selection");
 const binary=state.binary;
 if(state.mode==="bundled"&&["/usr/local/bin/xray","/usr/local/bin/xray-default"].includes(binary?.path))return {path:binary.path};
 if(!binary){if(state.mode==="managed")throw Error("Missing managed core");return {path:"/usr/local/bin/xray"};}
 if(!/^[a-f0-9]{64}$/.test(binary.sha256)||binary.path!=="/var/lib/remnawave/core-manager/"+binary.sha256)throw Error("Invalid managed core");
 return {path:binary.path,sha256:binary.sha256};
}
if(required.length){
 try{
  const selected=selectedCore(),details=fs.lstatSync(selected.path);if(!details.isFile()||details.isSymbolicLink()||details.size>192*1024*1024)process.exit(3);
  const binary=fs.readFileSync(selected.path);
  if(binary.length>192*1024*1024||(selected.sha256&&require("node:crypto").createHash("sha256").update(binary).digest("hex")!==selected.sha256))process.exit(3);
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
    if [[ $PROXY == caddy ]]; then port_free 80; port_free 443; docker pull caddy:2.11.9-alpine; fi
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
panel_ipv6_candidate() {
    [[ $COMPONENT == panel ]] || return 0
    case "$ACTION" in install-panel|upgrade-panel|migrate-remnawave-panel) ;; *) return 0;; esac
    helper panel-ipv6 --source "$1" --state "$STATE" --key "$PANEL_IPV6_MODE"
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
    panel_ipv6_candidate "$DEPLOY/docker-compose.yml"
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
    [[ $PANEL_IPV6_MODE_SET == false || $COMPONENT == panel ]] || die '--panel-ipv6 доступен только для панели'
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
        docker compose --project-name "$PROJECT" --project-directory "$DEPLOY" -f "$WORK/compose.after.json" \
            --profile '*' config --format json > "$WORK/compose.environment.json"
        helper check-runtime-environment --source "$WORK/compose.environment.json" --inspect "$WORK/project-containers.json" --state "$STATE"
        if [[ $COMPONENT == panel ]]; then
            database_environment; check_writers
            step 'Проверка истории миграций и исходных ключей' database_run preflight
        fi
        report_update_progress preparation 'Проверка текущей установки' done
        report_update_progress backup 'Резервная копия текущей установки' running
        backup_current
        START_APPS=("${RUNNING_APPS[@]}")
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
        step 'Запуск обновлённых приложений' start_selected_apps
    fi
    step 'Проверка готовности приложений' wait_ready
    if [[ $COMPONENT == node && " ${START_APPS[*]} " == *" $(get mainService) "* ]] && python3 -c 'import json,sys;sys.exit(json.load(open(sys.argv[1])).get("nodeSiteMode")!="standalone")' "$STATE"; then
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
        if [[ " ${START_APPS[*]} " == *" $(get mainService) "* ]]; then
            step 'Перенос и проверка страницы подписки' subscription_migration_apply
            helper_file_copy "$STATE" "$ROOT/registry/$COMPONENT.json"
        else
            info 'Панель сохранена остановленной. Перенос страницы подписки отложен: запустите панель и выполните migrate-remnawave-subscription-page.'
        fi
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
# DATA H4sIAAAAAAAC/+y9a3MjyXUgqs/1K2oohQHMgGi8AbJFjTls9gwtNtkm2TMac2hsoapAlhpAwSiAbKrNCNvavfdGeOP6F+x9xP0D
# DATA ste61not6S90/6M9r3wVCiR7ZI1j12pbQwCVlXny5MnzzpOHB3v7R6f73/t9/qvDv267TX/hn/u3UW82ml31m/ze7XXa3/Pr3/sO
# DATA /i2zRTCHIb/37/Pf50ev/N3nz/dPjv3P94/2T3YP/ZevPjs82PMPmTK8L+N5lqRTv1X1t/w/CabLYH7rN+vNjuftpbPbeXJ5tfDL
# DATA exX6zT+JJ9PgJriO/R9eLRazbPvJk8tkcbUc1sJ08mSunv7I27+O57fpNPaTzJ/F80myWMSRv0j9EDr1g2nkR0m2mCfD5SL2oe0w
# DATA WCQTfJjEmZeO/MUVvDhOwniaxX6UhstJPF1UfWjuh1fB9DKZXvrJAnufpgs/GI/TmziqeZ4v/17O42AyHMeed3YV+4SG0Siep/7n
# DATA 8TSeB2P/5XII3fuHMgR0FPijeRxXCcJxPFro4Ufp3MvS0eImmMcEerq4iuf+62QaZT7AepPOX2dVP5vFYTJKQgDm1o/iLLmc8pSh
# DATA k+U89sI0BUzAPAHbN4A0mGMMg00my2myuPWTKf8QwIjQ6TReYL9+Fs8BPb4av8YTEtAyhM2fpNnCLwBwNg/CBcLDEPr4VMHlAVyL
# DATA 4DU0vwlu/dt0OafZR+kEIc6uVE+E7Jggo05qvv/ZLUA9XcyDbFH18MVilPJ4yXQRTyPGwyXQVgDf4/x43sp4gEOkCqRMQnEAk0kv
# DATA 58FkcxM6miDgiFMkASC6IIFW2J1ZJsQLdpIsMn8JOMwAcV9dxYD5GBcqeI294isacVV8hK/OYyCUORIYDCVAVpHMvNkcpgYYOH5g
# DATA 0vbiG1gXV8ECZ+5d4f5BjFoYt3YDb4IV+Pyy4Gd+ySQJPUz8ZIRdAj1lV5WqHgLmEMbJNb68nIfYZQRENQfimvqX8YJ2Dr3o3cCC
# DATA wFfrVWxjrboeHl4HRPoAW8jQYSdToNMbj+CUBYKNgHDq7l5P0xvdb5Rinxn2DPjFNXkWX8dj3BcZv4JD3EdTMMoiDhdMQcScMo83
# DATA 0w2Q7SIGluSXGxU/yGDRF7SXmYWlU2c6DGW5WYGZwHJ7CCHxHMUQbq6S8Mq/BCRmBP44vgRwiJVlxDCFl1WtpfOgzye0IaNkdOuM
# DATA B1Pdhb0MGydCBjuE6Y0AgYDGCMhtGiG5Ib0SrZY0ZSSMFi+ZwMSvY2SCGZBUhBsL2i/i+TRgBqq3Co4qa1HFVYbvt56ih5sEaHMG
# DATA vDHCkYCfAkQTIPvrIBkHwC5p3zD3iKyVSb1kGqbzWQrsCzfAi2B6azdYoVX831UczGHzwzYAtHgxdLCcB5fwdciomcfZcrzAiVuc
# DATA ETr/Alg5TKia44hmbwPkEa6nyyKzKi8gdwtIuvVHMCteJ5zjMF0ualocrJEDLKsQx69pSXgtExhQcEyTGccLApxwzR0EIWyLDDcF
# DATA tlFsG0kThvVxQgDZOA4yllyZZ2/NRWp1VfsAmaU5jSN8YL1Y5hDxECKzJVAzYpLQFJtp2WAwNWSGHDwBTEspWJ4DZLl/sUwAz/SM
# DATA lw7JBtl0TmwBJEi4SaSYicWORi4gCr/z5XQquJ0rzHi0LfgVYBLcOcByhm2AZIGSZRmWLD1X160K6+IF0gxwxOuVIM1zd1XZ7Ktr
# DATA Kkhg4L37gMddPvXTcQRTFxEN+gSsCcoCaH//eiJl0cjZFe8Sbg6CKcgcmQJwpZMZtvOzZAJLNfcv02CcEUaAKpIMZgqQwdvAMAwk
# DATA pCppRMscFEwvD1m9ku9XQeYxweIGRja//kVhlmrvwGs0Iq7iEoQ/iiqjzQl5AxMKE5QE8FLGoh94Y7IgNoZcCJkr9GDxV7X7GOsh
# DATA a1KjFHU/7HT/5MWpv3v0zN87Pnp2cHZwfHTqefWa/ww47ZQ7hmYbZxaX32BhT0usZtdS83twA2JvWkfeAHacgbiPA4Bfi53NcQLi
# DATA fxzciHgLZjPanzkV0lMqJO5SWOwsniSIjmWIG2sSZK8F9BgUW2LtNuTIjPWIxMVpCwq+I14DYo6egtz39wMYSpqw+htFsKVptTN/
# DATA A0TeBrTakBfibINQv4GrBioAiKENYrFDlERRAjt8CfNHJSGdXwbT5GeBQvhZ6m+wQIQuGDJGkjIGRnMQdKiuRcGMVHn8MgPZoRYC
# DATA 3/FQ3gFDz66IRxADYtGhBLwRzVXBLmCcJYgwc+QLUy9+A1oxvccMxJJDBBygQnZsIIBbG3xDYPJAto0TZPD4CgLPnzaGAQunDRrY
# DATA bkUawEYIUnwOLfCXDUFEnAi4INqmekRZaKtz6tsTRUYeC4KByc6CSxDOqziOiEBI4WKzA0QUiwURTp6NuZt0OY5YaUWtJwI2Hy6A
# DATA ZAEKpb0k8HWcKG0BFmaEK0G6iZAaUjnsT2xh1gc2QdWP34QxLHL8Jg6XC7HhcFd7yNBAg0LyEfWJxS+o3NcBK8W4Xi9lnkgEoJKM
# DATA l8AWNafwHE5RpsmmRgbbbAN0ZSXhteojooZ5P+uHKDhRdwDVBQwe0sppqdCuugaWgrIyA7thPJZ1AAxdx3lCx/2JOx1pZ2ZNgDhC
# DATA PMXBpWMPyR57VYZDOteqPJsFqHzFYleReaeMyYBUR+hzni4vr4D/a4yKSOb1Bhngg+k2zUaxSGxWYsWQZvgBLyzJ9CjXMXdPP4wC
# DATA kOGA69k4uAVWsTvDSc0TXKZD0pKPUjA7gWUo9SF+s0DioPmS1SALF/B4U+QnhG/oaJJM4RuQ2HVC0tkbxcFCm0+o2uuRYXcH1tiG
# DATA 1KY0vlbxvQUsEAt2wVGwEPWCpg3ydY6G6S3JHcVx/LIQq9CFPQl5IRF7T1ScSFlgiq1mxCIZp9QH9WvYsRIkDOkVGEoohxIQtbws
# DATA vnKEGLZ9MEK7z1oHkKMZWQUBDJsRz6RJosoWkHSBdZ4RMzbyJfBgty6rbFYzxmFh0Jxk5kI9TeJ4kfH44RyezlnBadT8U1bj9kAT
# DATA Emm+YWl2G2x8O2yIBT7a1cDZ4PHE4e3kxODtaG9S2gbJAsXQ8fCnMXFt7N7sqmk63RS1THUaWMz2dBEgw4r8A4Uu87KFQt6HzIQT
# DATA egY2YRImwdjLVA8RKhGslQW4JdNLkHGoPkuDzB+mEeyjdNVu0QNlSktnHCD2cbuHS1TgxGSbIBLGYH0vwVRCnTUWAzAj2w32BVk/
# DATA wSSFdpYFhpMmfipsRXWh1uf0NsP1PUyG8wAZ2QZLQ+HERmmQvalFhshST8tSaoUkBEpfOo6F4stBBVEnb0cKBVNYFOAHsjbA3cLX
# DATA wSUz9hfBTwEFe8Ck0ql27bEeKbzIqAAwADX3rOa0t4cVVt6ByqesVzE7VWaABlj8bYDIlXFxywOZgT7NIizwV8mGlouBAw1CtxU5
# DATA lK0IEWVAkPwwJg/iAah519vIQbEhRINbLYVB3wBcQqiwMbApambAcACZoXrJK78G8z8eI2OfRsA8MlpjRg2ooiDlFA6UdSjGGq4A
# DATA N/bKCZLBbQWlME+QGbZLFWCTZVXWRHD4ZBzPmQ7ZvgM91bgIuR3sIbNlea8BA1iY97BP3NxCn3spsIZslrInhBmMw0gSt0ciKUHR
# DATA eOzljctpHCunI6nuixgxDJt1PBbSGTGUZqbEnCsEFpm11mDk0Epttw5PlMmdsAkccrYgTwn5RtMxNEvRptOaguPZWIBaFjOZqx2n
# DATA ui1lXn6zEkp5IuPN2XI+w54XacoKtzxAm9a4cdAZqjxyinKV68RSMgGrQBGITDa5XZBxT3rmZXdTMrQwq+dInm8C3BRVv2gdPS3w
# DATA LfVBG2X+KBmTHpWlIcrxiDerrCY/FHenoJ39i3F+a7HXOgLhJWjjMMPtNJiwX8QbJ9PXyLOXQ40apQto3X+tF1+cHlVPCdEh+uwX
# DATA yQR1jyhYBMpLIoYpmbBMCiOwUMFSWtzE8ZSR7NkwWB57wG7moJe3RxFWicYdCtJqvvKkzjMPva7zWG0CP1guUgBYpseW1+rIznAe
# DATA D3cfJO42zXM87cTMgomeVbPmfxZkwJFeauMDjcVdsP7Yq+tfUqwgKlCXiBjVY6WyoR8BZcyKx/el8oUimikkATO4Ttk8UZob09MC
# DATA yc+z/BDYfBIvlF9FjR+/QfsmQS01AE0BHRjkj15Ox8kkwT5cP7HiKavWnZigYJ6Ars7rofxfaBMZW5HMUvlO/lMLHJJ97OmVntiX
# DATA NSU/IwkUFHTwIVskC7AJWPM2nefnB2J6mt6ACXzJzu+5J2uCft4g4UCAdhTjvrgOxiyVM4PS4a1r/cHyfg0mJarEaNtUCS2i9bPx
# DATA 6gCVmRgCmLAYfmFFWtuttsMIxN0YNaJAVkKF7gjCG/QzSZgI/QhAMhTGUdCIgp4bXHw0maawLEWCYe6LIcqr4Fr8lBM21lzdFayH
# DATA 8TKDZRizXQFwER9X/lCKviCnA36YjJnfYjvj/0RmLI4hi05VmAY9gLeEC0/Rf5Y3GHA7apOOXCvIreYJ62QiFxjDnph/xLD0uhFl
# DATA kLS5WmqnuANkbtE8mao/WWYo5HBlbEzAhqAFGsZXwXhUld1NP7GvIUE3LXsDEZQqbWOaG00dEHGVDMmFAWinDaMMefaCcejMox71
# DATA NOLITBwoJxN/dEI+eV6vq2TGggferGHsW2FNXBrQO5N7mMzD5QT1ftTonfA2Ughq6OLzjB0KJeYC80Zvpe+fkoIoTlI3iv0UPS0k
# DATA Qhp1DwmLogqAcAy8ZcH8FsBr1ZCDYCQM33/FQSM2vk94qz5H1OyCfNrcI4CvUX2EPg9pIx6lzrKh6ATiGKJcBs020mIeNaTRKGYP
# DATA AAx3NU3H6SWKD7AgAwoxGPxYbh/Y7v5oOQbpPSaKgcleyr6Q9mj4gNLVaCih89XBy2OLYSzmYPdDnxEYrxzuadb9Z4CCyRBeb2xt
# DATA dXE3ecr/TS5WRRyKSGN0BzGKQgcJMCRKcTUHHRzmjUXcwOWQVY6yBogGnKpEA2G5yHoAoh8mIDnygzgY89VovusW4dCM/Spae4x2
# DATA ZqOgpM7DhEhFGHGBUCTiRdmMaivoofmtyQKQnXpZOA6SCc2EAvQLEVQkvnyTpgAIdpzttklFNiBr4PBzPEWuSgYjsHJUtW2FlnSR
# DATA Km9z4qbJnGkMdmtJkCkz09hcWTKvGJuwdu2ab/brlyqZZI8dZkbqyMrmsk3UpEQilzJHgWGBouOnCUfTEHGwTZLlpJg1T7MZmPXp
# DATA MhtTrotnuangF4nxIE3H6IWXlJh7nVlPvddxPMPVQu81blb+nRmLVvpcNQkVnumth14SpZBc64hLJHY6BpPmSukWxtMzgQomo+ge
# DATA AAR/wRAs1JCjb4Ae5VN7SmBc0sYBQ83ED9b4uKBVqjzVrp9bLyOnQOAglJCBFDVN5TOKH4NUe0lQdfDUFsB+KPAPu282S5HZzY0b
# DATA UJIMOLyEqu0oRv23Y5PZC6XJiQ4seVQF9GZ771eUUtEt8m4vbVUnohU6L4l3Rbm8bHpVjCH2tEKgFrVdRKsStIol8DKS/AwjuLY9
# DATA L6iQksr+PBTrISDq1nIdFpIioVmQ5CXisQE6YPcPhhavMfckwowCzxt+qzEoA8yEKYtMBd4DtiRmyue2ghuvp1RgsfLIEyTQZ5Kt
# DATA YB6gkaOQiou1sWZrbMDEwgrrmTgnpZUS8we2NtcWreVPW43WSYwPfYHQxucYPYwGNJ9mWZypoGxgolrWyzcgg9nbjYFy3thVe5fl
# DATA RLfmAR4gilAGzJaIqar4AUFqCwMxriTfimzJKizLZTCPxhhBR20ZvdtXuB3QYU6OwDjKGx4cgZ+mOfvJxpuyMo1CdhPcsvfQ8qqA
# DATA mg8mSYLExfLV6lBSpigLK4sBWObKwuIjdkpFFf/AEnZXQXZPMAQwQzyHdV4OT3hrwyJPERfiB3JET34U23NM5M52kBrBXzsCS1qO
# DATA NmgvAZkopDWTVk4ecnbmadnu6jxMHYxjhSeJikXxDLP6pgsVuHadRJzgA9r1lEM3pOg4CUqOYkJc2e0BABuSv11FLJXThdWDCUY7
# DATA UApov3kVDTs0STFMfJ2OlxPJA8kWKWYd4TMnPKjEtxXunXobweUlki3GURMFqUERTX6ROZlLSkwL5J5yb7IqRYKRs0gAAEfRSVf6
# DATA L0mqojeMYbMjSsQ3ZSLsYpyyyYHhoCmZVkXLRxFz+H81I+NxDIMlp+CZjYccxpb4Jhpp5LvqCCina0vCI1AvRAg+h6UplICuK6PA
# DATA lavlFrMaz8itDHgsIr6zVnxZAbYJbEOgm03McCNuVuivyg2WV0GYlqaxEYfAYkQQ7umxcg5uEuVgnIDMIL2KgmtXtxnpqizNF17Z
# DATA eIytpwV0WalKkk8wTXTGnFfsfEvesF4R+NFyzl4t1TN35oXAl9IJR+6JPslbqtLpiMtwxicL4n+zOQbezRwt6SnrZlWfeDjrYCA9
# DATA QcjjfsBEw9s4mLPj1GqSeZYPSKl3M5Y3RMhgvBMmLLWPnTvsWCDwQehjSAUjB2LsKbkrwlalvVmYkdgh5Z16Rqm9z1vKMtleBE4+
# DATA YChEu1nr8qsWr7fHiPUfvd5VFYck3Rnk7iTlSLt4aWAbZelUEjk4uKzGQjvGjhwkmWc8TVopJYrBLFuTSieK+TpqRmV3JY0wQP1P
# DATA FH/WqYRGLc7oWnP28kh+hLUwLp0hVHaWYhFgSqtSObdkDGbKZcMu2DQMg4z0JTb7MDyNMQE03vE30pI85a210rSjYpBZ5unNoG01
# DATA T54OlarWHbLGsmbjDsXWoS3J6yBo5vgGeb1BowD0ly/R8qetwpTBOK+wgsfYMv5eN0GyeEHFVmHff3CrElTMjzwwrbA3Ws7Zx8Yr
# DATA zS5arcGICu5bNuSD9JSzJi20UDIFB2sJAgrdzQrYXrZCj9W1ZOJJThxvT52BKWRcZs8K72fiUYhi4w25rXic38rMKbNRLUlOlrfY
# DATA kods0qIBkky9EBil5U0FmQ/6lxbs1syygHq8UYm2o4QDa96aDXDiKPQ3JhMXFNqMUkWKX60KrSOEyhVon4yxbTk3Ex1YuWLpJqKb
# DATA IYVyHDZz7DLUPOK1u2BJ/rNZHM83F+km/uVEKJ36prBJZwGSKVvXHByLKcWC8VQQGy6Kl7m+sjkmVzNnHBFDl+WQ2K1OOKZdIA4O
# DATA sVCtbR7JKQLUxYnvA5FYbjkLLNTI0W1vuwYSiUngFLVPoXjTIMk7QWjgXXobDnVAN3LjCytMTCfioIMarRyUbRsEiCUxKWsuW05Y
# DATA macmyqDQmT7eAs980ZxhKcgkRdsnhj1jJ41gtokt81RjkHPBBKRh1UuRWOE5WLCRCuZkRkqpCKoO/JLgHHNv5gwE+WjRAIdNjtl/
# DATA mDCHyji8hxplMpV9xcmCalrMSvKTrXpRuhwuRssx5+cbXzwsTDq+ZiyPgmtOsSeNICDm+DyXQ6S1By1WKFvJSjJC86LqbziIcjKJ
# DATA vcXtjPS1lDPIgLh0Kg0QZzgOePMr2H3XyFdR1KWc4Yvzg/s8CdoYAZ15M0knuaYeGMFLBSUvUfwGndsknYiYZ+whB8DpMIucfEHA
# DATA MMtGq3SFaM9BrhbL6oPMcdx+i4Aybzwjy1EYR0vUaBlV6GHVAzC4yyl1TTIcf4HxJFWPPPOkBSCNkduPnU2xJO9Zp3hoLp63ccC5
# DATA K2yGHhBvos8qRcbeYFZ+3AQmlUZZFSkjjCN0l1cxB+AqnUuGtv86vmXkMqtLTN+KtRKCJXmGTHXOmVk9/ZAV+BBUPpoDIHIfr+Bo
# DATA DR0qy9brX7EDHnpbvGyJqXpxXphI8A1s9CWyguWUOKiops7JDWZYnuKQeKIt5dQ9WC4MPjATYFcMz4vTUyjUN4zJmHajJEg3Q0z1
# DATA wINasHoHIyewNF1hkrbjUjF7sbZwMA502XkpIzmMxyaYjVuTHWNp42G4RGsp83RYj0VfoIaydqHkToxs3yJ2aejSc9YSkzskn9iS
# DATA a1pFkwyjWbxY4iFXpVd6bLVS0ka50FHoQpiRSgjfQIv9mSTartH4eN6uN1ghlRx0w9i2Oz05jbZuh+GB1+VCHS0zPmDtTSG/iZfg
# DATA iV0WarjW05RDopZuB28v6KAqB0tQibu1d1aOIuWQFGvPDsYpdU0nXNkuSo+oTjpkuXFy/KIiqTs29JbFs27iqxlqgZfrQu0wuztl
# DATA WKNmSEnYKqpC5LycoUuWswQkLkL71WwZjYW5NRF9YlCoqiqE5K0gR9Ny8lCnKCK0+RJ4SsMXBT6KySlxcxVPVwI0yKTi8UinFKgg
# DATA X4R8LOakIJJT5nicpaWpgQCW6yQdIzp4cssxp6whs16kIWb3jUQMm6yyIJynWWZ3RMkK9+wD5ghrV1lpveT0smOBhRuHT+HQy9pH
# DATA oY7UeeqYPuCNzipLdMHP5cuuT5b18qljYnfS6Mr6A/ZMvBBVQNBGbhBgQBPIMaKI5RSDCxSIRiegpAKI9QS46tX8XRPXOIvZYblh
# DATA /WZCBXjoaR7b6SdI3ZInvOI+1BGX4a3KSeETBHykjXLtpjEfcJnHStiZwFTNKwZCTo5J7EaiNCqFgKNIKoBAqiNwAc6e4KNcmCvF
# DATA 9jaoynx0xE7Stp1KTl6CpwQph2zYz7ZyvgfzusiQDgph99irrLKz7exRHc1k9xs+kb1H6ruJzHiKkafqfC73zUGfAiyoigCXqIhw
# DATA 0r63kiqBCWQseNS0i2ewJjWEXUlFSSI4iUAOqPPBC2Cbk1QSR4oHUTHeYCHHcZC9kYsGg9yMNI8c/uU1NCKoU34tk68qkZj0RsCA
# DATA 99BoA8sJrXG2OG7UBHMZzrWKSZIjJ4m3BnzkEMIMqxJfFQ8H2UhutMfNPKMwnCpNQB7XwiwIMxplLy1wCenshUr9UiUvUjw3pLit
# DATA Tdx8yESSwDCnA+AsAE+vIWXGi6psRJCB6IqO+VKyGS2c6rtyL5Nw03XoEQcWnklSDlmOKhEBY0YYR6JDIYlSGrRfSaXwFoX7M7/R
# DATA IebZ6ObHfor6JDr6T/QxSjJN5tdaUJmDKpYLmMNXOu0DLDRCD1C7du1nWuE3+XZz5QNciVd6Eq9UEU1GM4e4ULcI2JBOFgxxWMEt
# DATA rjO8gB60TeVIWFixy2SqjVZDmdCJOTnKz4pMGLLZNPxDPD86f0380rOwcUNH0DLLy6edKgxAoEuYMPhRBRZAFlPOorGTgsQfLqzy
# DATA R1D9l2DCHzj4nc4tjGtbWwHJA8QVTJAbM9IwgIFElMsYm4NJgtPhDD0xI8hdPwEawqc8ctU0ZfNQ9DnCRcbjjWwKwqDwZOqkihnI
# DATA KTvABj1YeAbBt252A/LYzJmeX1anQnNLBTyxwjuJK9KQxwCPEiwnInYJDEvbzqmRqDFQPp9pI1KPk2AK+9SHYkGxSSn/2mPhVDhh
# DATA yWpn/pRLxcpnWJCkRUcCaGTIkTbEIe7pVEZSSnDGsqfQ1lcRF501alzbSiS6aWwR5bGJiaJkcsIp4myjBLLNi9JtLLG6NnMrYNNO
# DATA qYigM65OxLBakY+M+pjOSKFGsVL/ScPn6Q59q0PSB4qKEPBRDCef11bYLLldJBIMGbozt0LV9qlPq1qVG6+mlK0CqNHOouzrbAlb
# DATA 7FoSVtbBb/wJBCyrpmmB22WdLk+z9UilJpmu08l0SpZ99KZKKRSAAMK/OABWyNatbcCbQV4nQ0+ICaN1IdGTtxJ0cJRb0cp3VxKQ
# DATA rL2T5ndTVSlBkmotIVVzMNRK9lF6ki6NgRxuoVRmo7Y/9dhaR/K0Iw0yWbH4QRQAtP0amRPJlP0GJguCzk3pMw6mPlBuzeS4MY2P
# DATA Yi0D1VdT0GpqG9qvqFDCPIAxWScd2BjXo3kyGldLu04TsQgpL8w9D7QQ8GO7vJJdwkPtdDvGTyxkYdUZWT26E7MfBN1PATybXTns
# DATA qoEOii+slChStTGjj8uAkZFcqNItRG+de7pUG8c1LVdyXmHzyY9DXgA2VCueVho5SCueW3J6gWExLtT7nDNAYLOPkqmLQvcgijmv
# DATA ivQa8BH3qskxks496RwLF9G2xo0zklghtzXoACZExQksnYQ8v1imjA+1dut+RFrKaCHrQCcIhDxfgBWaEs6dIzOPQqFnodCa0cqE
# DATA 1Bs0jyTOrJl4D89EKjolrA2MkjnmfySTWBsORqAJh4Gu19KLOvPJGmbF2FxeHlyTKh8uJeRnetXYbdnY9SRfAsCZaROXgUL3m+EL
# DATA +Gxld7nOFu14M/sR8aW3FzpnpU4EakxkQWlEqDQIPQBNE+eyuo9ZztrQUF/kM9NjR5LKsLAX2lr/qnVEy/8L0JXIgkx13QqsHOSU
# DATA K1SRf6MBOrm4qL943laNvHMzOmaDeY2iakpg7ws+e+Wk+KvcQTtsEYRcwiF3JgoEI6d9KCDRMsDTaHaSiHVGb3caArcMOCFZ1+9Y
# DATA TbkjTzupwxIfCFToCWBS2fEPBKI9CyyBB4sIEWvXlKGM+0DjyDpejMoERTGdMjh2mi3yZ96LbqJtkdzg7OncYcFYzgmzxccFYKxd
# DATA L0xcTpUVLIJbuwsdZrrmCx+RYySvHINkYhM9QsSUwcHKjufyN5TsilrxrpJ20kAU52fpDdAyFgwFIlOpJfAKlUjS/GbNuSA32uHI
# DATA U8WdMkuVXbURtdFQlaOiVa0fsC9YVoQLj9CY2ZJDBKRrOUh19wG6hKWICoYM1BEdPjuYEMaGt+5pHEtfNFWudqf+BvrY0DwyUZkN
# DATA 1uztOI2OBPEofJiQyy7ZZaFY3TKRVdwoY7KxYs43BWNQtaH8LlY0VvuYxPNLphm75hRxtXUblbOiOYNX5UFN/dXZSUo3h24I0SAo
# DATA 7Lki67UW2GYcnPOBqam6AWbL4OY0XFzl0nMMhMPftyU8xBZHdNKPHScUeARrAVhzxIbAchx55Ckz6hWGKpN0San3rGGBqjxeIlxy
# DATA mi5/VmBt+MyegibWNTChAuPln1MS+yJXbVQOp2nxHo9GmOCUU5LFnkaOU2AoZSoaJsfhdDwyd2AchTydyl6nNjsFC8T08+zxzW7F
# DATA esDz9DYYS/wqtdLT+KyRgcV78OC60Sv0jLEGAu5uTOlianUTaCncs8nH9Xj1KXuTvlMwBg8+LtENgkGtS2Wqe5ZaLo0No45MhKLK
# DATA 0ghYCmexVE2mIFU9Dsa8EREzc+25skuT4TgmDYnOTjQaNf8ljZ2pomdT9hCm8w2VBJNTEHE3aW8r5cEXHYRxBbNVGs2pXqIew0h0
# DATA 6IqFjSc7bZmZyngm+V8lDAiYsA9tqHX5Nzk14bQzpVlshEvsCPma87MHwiaOrOoQY9u5rDuumvShMcaxsGClqDWwLig6WalXv1aV
# DATA fMDybRSos9aalGtQ3aao2urjyt5qUvEoTxbk+OMzvBKsyqOk6qHXRdQ/FSnmqa4FicJBVIYqpxqpXV906LRgbN7Lnu02pQmZ4iJV
# DATA WcZ0vGHKjpk0B+Uk9WSJMnUqmw5YUfEdRBq75DJqolNJHXcABQEcmbnPhxANzJbSFZDnQh+Lx6p783GE9Z00t9nkCi6OYW0xfJcE
# DATA 11AgKhQel1qg/ChcSdngnBFOu5u3tilCwtUS7lFDeHSZ9jqyQDeVOqWIOdLMOqhOtBJR5FvacKfI7GF6q1wgHjSNxffEofBkwb41
# DATA OUOFgfpUDBUucEqZQFTigaxYCmWWdeGzqep5RfOlWunmHR7vOp4GfPiQypQvxWPPLezKhxVkMqm/Qau8IanbOccIJxqwRqHLM0p9
# DATA cM70XjPblXkpwrCPWlO/q9lGOXUVC3sAzHTebcz69nQFUD6RtTY91FYRVOkCN22X3PmerpBNtaExd1Gd3I0ePIKj88QDz5Ts1YPk
# DATA jgdowUwRf7e4LzsSvIUOcaLj00o/VYeh1swV5oAexdQkJptkUQzSXbKREWOdSrZHKDVEUGSV+abTHS45sDGcZLavRVfQKrf0CFWb
# DATA F3mP4EWrYX0K6UdCJ7QlxraJpO0fk1qPVfd+nCcWVT5P+18kOqLLxUhlURQJytTPkZYvlTmspGFvxXUtBTdZ51KeFQaMD8kVnSP0
# DATA 3DdZ7mjj1E69SPDoIggYTqJmTUUFLj3pwJwxE/8K6q5MDuMkvo5NUgTtOSxAPc+WASdGsZoMk5zGTolOFKpjN7UNA1C8zMzXrNPq
# DATA tilMlhpmcS6VbQUtxOatrhjJdNSaon9FPIjUATs/N87EVC0q6aLVMl3sRuXbatiUqPB0oALnqmrO2ZbRiu08LaARSsBn8FEaOC5q
# DATA JmRx7mCxKHMWxB2C1T1ydFM8WR+/JxV1N48WGGgD62LMExIm6fyWToAWFWrj6BuXnIO5WZk8nJld1XVIsry5wrp0ZkpMmYoArBEY
# DATA wyaXKqR1FpMO5KaErrc6rEpHpsRr3iAWjw2prMboRZFkiFOH9qykRonweRJDGqLeKImc5sgf+cPUvQsMoEkAIQE4C24nlHOUmnCB
# DATA jODUTZCSKcqHKqXqbjkxXlhKrlKcPV6+b9bJqqqItmbTxrnKXET541b2hnKuVum4j00+eWZPFTJXeYJ7as1hZzqRVVJpypzHlsRy
# DATA A4RY52mmagNXWHBgkAHgoON/nGg5jYqG1htU8swzUTrUceRM8UOKuRZsXwmUIGwxeQQirkogBGqYmqcPWbo4wbr2QrdV41dv9v0X
# DATA wRxWq1mv9zjb50qXNrWce/qcBBU2my917E6MZyt5hsxhTENMqD6gGJPmpouRdsk41awlfQT4mlaMh7Gbv6gd63b8Uk2TSi01mjX/
# DATA KPVPl6BdUENY62OqLFbyn/M1H6y15erOsTMikopZflnZg1RWbUkVSzhUYemMBtCKyibDFIYoCXVKvBqiKJh2qyqtARJRyOK42ge0
# DATA /l0dRkCPj81iXMGepXKAXx3gypLJcrwIpjEXyuGMuZVKUY4DQJXzUOey0CdBUzeviVhZ8bzbjh4BELh7QAU78k4hxQ0RteSoM1Fu
# DATA dX6Nouik4YIFj2U/lOVGio8+yKj1HGu3wlvAWiaWqPdyCZFyPkSuZmKfn0bbMCWtL3UuT3CwpE1uCiWM5rh9OUdSZYy5h7ZMjZ1G
# DATA q4Z3fKUwvyPRsQ9MpfGnmGtttM7116h82xw9wbtJQ/Q0Uog6Vk6McBqDVTWcrVt9k46ny2lY1e/nNMGxOYu6Wiydsv9oSBnJ02cy
# DATA yVazyq9X6EQHPeSLvKz4zbpimlqAqXmwcqc83c61I4XHTB8+Jm0sKFL3dCFrfQg+ABmly3fJqdJAF7XQp7jl+iIp1FIIDDNiu47t
# DATA +nPvEn21D7brizc86+KNNVekqIQi6zqiyNG8OeNDeRy0r+HbEqQ2dPIFaaavRVpimZKVGJnSlJx7OCSPufCekXU3/PAZQzYbPFMU
# DATA xZTBtatf5G6ykCNTxTnqlP1hn99wyn9QTpg+V7lasEUlXpu56kMXVLRAF28hDZ3O/dq5U2pPPQIFyJPayJNgheDlL52LrhyHG84V
# DATA 5SmQmxQ6eA6WXCRnxQJTdm0ufcllXdbNNuLHe8zdS8zOMTaIKIO/VNMRUGB35xEC0H8gVQqxcNQsmSf6OLakr5pLihCzCCxnleIL
# DATA ER4bwmusPLmhhYYAmgVNYyI6G8i3+VSHLBWFAXq4DCzppkgXS5g/kodqMV1iNUWdLujpcwSS/quMDZ0vzi+4R/aKEeblELYhux8P
# DATA vBh/OmtNonotzH4jaDh7ntiT5UNcc2WQuHRUMp4C1NOAzlVlOgcC37lwaZGnIc/Q0GpSpbYMGV231t1KPLwyKB4kJ5OBGF6lKgSm
# DATA +iI3pwbTKwLTInXWJW0wVxYTaOfNLd/HB08iddfdaInFmrz8XXIP7wXsSY5tVHUxlTe3pUxcd24CoRuuNyiz04isSJBSsxgv1Lt6
# DATA Q3mYjPpySEurFHw9E0Tspfjn7Jxbqgkl2duefebDKtUOAtV+w1JPc0o6nlKXhPi0IGeK9FG5m05Jf5qUumiSSBx0Zoc8kf11avpw
# DATA AJPUV3I8AJneF/sn+/7BqX907H+1e3Kye3T2tf/8+MSHB/7Lk+PPT3ZfVP2zY/q+/5Oz/aMz/+X+yYuDs7P9Z/5nX3u7L18eHuzt
# DATA fna47x/ufoX3Qv1kb//lmf/VF/tH/jF2/9XB6b5/eraLLxwc+V+dHJwdHH1OHe4dv/z65ODzL868L44Pn+2f0PVbT2B0etF/uXty
# DATA drB/inB8efBs34bJ39g9BbA3/K8Ozr44fnWmgfeOn0MnX/s/Pjh6VvX3D6ij/Z+8PNk/PQUAoO+DFwDxPjw8ONo7fPUMYKn6n0EP
# DATA R8dn/uEBzAyanR1XETWqreodgYH+X+yf7H0BX3c/Ozg8AHzhnWHPD86OYAjC3S5DvvfqcPfEe/nq5OXx6T4KU0QhdAIIPzk4/bEP
# DATA MxDE/umrXd0RYBf6eLF7tLePY1lz9mCZcLr+18evUFrAvA+fOUhBRO37z/af7++dHXy5X8WWMMzpqxf7gu/TM+jU2z089I/29wDe
# DATA 3ZOv/dP9ky8P9ggPJ/svdw9OEEt7xycn2MvxEZJQt8ZHD3RA7VDluyO7OELq2f8SaePV0SFi4WT/T1/BPJFCfJdCsO/dz0/2CckW
# DATA PXhfHQBQuHKaKHwmiiq9Ag8MUXwN5HXsvzh+dvAcl0SIZu/46Mv9r089GyOAY0Ouu58dI1I+A0AOCB6AADGEa/Zs98Xu5/unFlXg
# DATA mJ5celz1T1/u7x3gB3gOtAiLf8hoOjqFueKywg/Sib8L64s9IGHyGnqvYBMg8R0pooGx8Tcb2LIZe5Ug/cPjU6Q+79nu2a5PEMPf
# DATA z/ax9cn+ESCK9tfu3t6rE9hr2ALfAGhOX8HuOzji1cD50vY+OHnmqQ1GNPt89+Dw1Ume6HDkY0AhdknEZ60EtzitVD1cfP/gOQy1
# DATA 94Usm+9s46/9L2ApPtuHZrvPvjygrSjjAJAHghOYHfUgeETK69XYgMTLPzT1na4cUTJSK3JYnT4Jhc3GDgmbIxu6cAvnaYsTYhiL
# DATA 9jNOsaAFH17iqsqSGy+clw/IcYK5h8phfMNW0JLMPTJuWDuWnoIbdXgI65SOUz7zi4eb3tBtEJmHftNhlo6xSgIVjWblA1Xu5DoZ
# DATA W7AX+OUcs1clIztnwsxhFBcR5lh7litEplMisKoDiHm3sC2QHy1n4Q2KX/C1VLuEAc78O1OnDr5GKXYE6qj0n+nwo1xNJDdHzuw7
# DATA GLiSNt04JeE1AfKSDq1mIIpTCd4ts9wh4aqE1bIFF5PCDM8rCsfoTGEJqSYLz72SlpWcWN1LzhdjWNcuW7dP6+BkZs4inEkqYRUz
# DATA 7gPxJRu9VJ2K03q9Sh09IJMoC0Y4MYRXvz3RF4su5AgOZZxZpy/40hmMV6oa7ONbj5QpcYZbxR/desvUE3WRXZEziJRqVUSPbJyN
# DATA 0FxdOWYjFq88nKXk22AnlSp4NFrqorY4mxFqm4CTHyIi6V1VLs+aeymjk2TS7XCexCMMvAW6dpTEVmo/yl00/0Ms7vcj3/8hvZ6q
# DATA U5g/QhMvyVT3BIe9wNv6lmlnWZOF79zK7CWL4uDzYzTdIHu8Il5VJsmKwW/ybeZe2T0qXFm1UGqr8zbT0zdtXWEgSh3SUmYnbB9Y
# DATA OTbXlaKF/F8pW0/t+4m5H+UkN+xm5OX1JcDlOnXJN+rSaRw/zviRO+zp3nQ0dVVWoE25Or3dTbR8sG/Pqf9msMjGHFA0ZsXE/g+v
# DATA FotZtv3kyc3NTe1yuqyl88snKhPoyY/oCF9GhoBTgQZrvTB3pCAJX0tOBfvRJTxPp1jSCy84CWaY1ARz0/kZVj3GMDAXLTKkfNvx
# DATA PW5KT9/peGsQxaW83evmk4WSjixDdOkYvtWbszNVxftiL/jcpjzoIx6qUAdTOd4xY+51Yle1qlAc+BvqKi9ymfE5uTiIMg0DxxiB
# DATA iV/Hno6CRTpBnK/g4YLyt5nlDZfynlJgjm560qYcSV5SMNROGMaLhWQ9mfO66gKmp0QD+vhBSxmWOsCaLzL3dQ7piEbCVAyIS28x
# DATA s0Q82eamBHW/XzyvUFYd2n6wNfn6NYpAYjUoroamuKHRhTZMOoV1tbt1I8hzndvg0icSvXO9JGsy+INYnHof0Q3QgAnvwd3wvT/8
# DATA +5/kH9ggB3v7tUn0exyjDv+67Tb9hX/5v412q6E+y++9Zrv3Pb/+XSBgicoVDPnvdP2/7+8unMvT9VEszzuJJ9MAY0FyQpuPOnMR
# DATA UXaHjtPFAngvZnNP47GcA4tQTlO2G/nAqZcb0i6nkdS4Il6y2arVNzGM+dScdVFaMl+aSyUnWIWRKzvkZssaBS5+Mmdx9VpXzkJR
# DATA tZxJqtoLGKJZq2tvn5xSw/75fRgbVVNQBhd0GZDpI72ZgmW+t3+EispnoLBhDnY6Dk/O9pT6TShRZe7DW1OSTwHNQTSA2eS0fHX2
# DATA /OXhUwmCUFYkSH5A3JOpugPzci6u5DNMQtnkJBQ9CpptdJOEupqK7vJBTKtFA9nzSs2fAd32FbO+BM1hOawBEp/M1Zo8GQbha+i8
# DATA en8rWEhM6H2o2ZQKixY0+cnZ4ekTXK5NRIfEYvB8D92KSc5dLMHPZCOHbu4dyX53k94t92v1Wr2iUK0IrAb2VWboixZ1b98qv+CQ
# DATA HNNAjKbLv5P9j/dSYgJVLfxp9m/D/5v1Tq/n8v9Gvdns/IH/fxf/nnzsnyypJKAqbg5WJadQEGsCe49qyR7zBZS6/sdVACZuhkV/
# DATA 0XcV4vEuOmAArPXjJ14J/TJ8Lqv0lBKSF/4o83eUnlwuIavYHmWlinoczm9noH3mm/DPptlb/+U8ySbB3pjrs/A3/85+8QmYyk9A
# DATA jSV+NACrHgvnPfnjGTV9EtKbpsdoCO+WyxV/50f+W8+Hf5jcy5/wH7eSG9Kh6RFF7so88Kc17lXCzp/WuPdPa2DeJItyqVaqnNcv
# DATA /E8/9esV/0c7fs//1Ooa/wVRMAPLY5vcYOVHzkFe2pxdlio1huTlZaXs9izAi+vwdIFpa9uUIgw2QS2eXtfQw/zZ7un+4NXJIRbH
# DATA eLPtN6v39HEGlka6XLzAS/uybb9RH8B2BUMDxGPuUYsfOX3dVWH1wKyJJwHPFkYtrwOnUstitPpeBmiA1cCAKpf43VIF0Vlid1/J
# DATA v6uYUe78bWL/dBP7U/2zODSn5IY0xFOWNa1wyzuwsxegZBgkoll9Q6/tz+fpvFx6JsxSTuWNVYlcrMaA1zLS1rn17XmUVO/eXaWM
# DATA NEcFkveu4vA1dSr5yhkP4b+98548YeVEiSwOgEf+6Z8emsp8YNxTgYmAc0npKAjlOHOlHF3bBDpTIVZWW+CldA760zEV3CMHJpjz
# DATA WMs4wYtwqLQz720SiKa+/FPsC0/HRHh/rS9XavmTRFQWzrTiNGiwy+VqG10opSa7zQzzQr2Jm4qRXmrWm936VqPRrLeAfAbxPBgE
# DATA Y7TrBzqnckCl5Evb1joJLITUbDnZ9kuNrXorCob9ZjBqjZqNbrPVrLdb/U6v3mt16s1+d9TrNRr9sN8Nh/1hK+o34nrY3OoEW1EQ
# DATA 13vDkqEpdXJW9Q7Efe6QdakdRr3mKBrFvSju1OH1oBNtxd0wDBrNfjPsN7v9URh0h0Fvq9fuh/UhQNRp1eOtXiuMOlGv5G6TUjgK
# DATA Op1e2B0Ot0ZxOxqFW1vNKGhFvX6j0Rg1ekFjK+o2olELJ9Mc9VutTq8Js+mPmkEzCDpWfxf88a7q3Sl2l/Gt7Tt4NGEZI9P7k9Pj
# DATA o1pG7AGot0y/V/3yoOpfE1Nc3M5iLJvh7+zs+KUhkuWiBHzsurZImasA89yGxmoIpB97AObhtZC891/AQ9jKV0Gz0wXmxfVeywwV
# DATA j12p1KLkMs5gx1/Fb3ADqfLM6t69ODqMQQvMFKyzYIEDnl9UVQAdKOquIiSSjHxu6P/RH+nJMGw4Ia6mW8KHH+3OQUetJRn9FWjo
# DATA gXRAJS2mIfYAvECefbZEfxG8xR/UJBwCRaDOc4hGqCsXAOoVoUTgqBi+hR6dMqMUi5diWjC1qWFJbj1MIU7OoQlg47xWq+EwVZ+/
# DATA MyCa4cXjLH4UcDwWvybclF976t1ZqzMG1UBhzeDeQflHiHIepuT/5V/6H9HPNYpwZF+Bql8uvYFt39guwdRkKGrCgzM2hrdYPmfH
# DATA F8yjuVCWftAQKnfBDCgho+62FT4NGndy9DgJQk2PVUc87r58OTjd3zvZP9N0SsBtQjc4gc3rRknTqjNOmMzQsZ8b6lnMvyfX5VIQ
# DATA Z5sw4uZlOCnR6lR5VjWwbAKiPhCsjWZFdUsvgkxc7ILVchZclnOtG82q3+xX3DUS/GD6V7Aon0snMpVcB/hyVY1DxYrKlYuK2eKl
# DATA 5WLUR2zeeUF2Ow11zXQ/mwaz7CpdlBWrVIvPuKCdjasFlhtGdIa1H/zFMp7fngQ3r6YY9ipvnO4f7u+dccsBBXWenxy/sD2VA5b9
# DATA NensK8pq4fb8ZEcpBBvOQnCRxB0S4qegQ/D7tUkwKy+It9XMoAp51rab4V3mQLvn56UgmiRTWCqigAF/wx1W0kbpAFYHc+gy3arg
# DATA 0cWFzRhwexCINdhmZRwNtEXiKrlfGxeViqWPGP2hXAJIR2O5xBhj2OGtoNyoHgYf6DAw8hb/kZsdZFopiRBuWMj5YrBc8jd8iJDg
# DATA 58U8/WkwHaiSyvjTNYaedWP4qB9eGBlEqMIBijpVLwyQzeAP83Qc22/j7JLLAWxLKhcHiuMSzyivYlae8IxtErAkgv1zMh1iJA62
# DATA kk0fqyRwHgZTjNPQHSFJPI6yC4sTx3iuGZgu4dXh+fy2LMiOr3thocP0A0LUJicQovy15H9iXnia61LJb0MhuiloxtZA21YThgOf
# DATA C0SMrqcOJX5EXcMk6FsOYqKT0joipMQ4rJ3IrZ7qzOGnQn4GfnM65h6WUBKWEOJFjdP7eQK3KWQKP2hQtoLZ4zs/aPrHJ5i98hmG
# DATA KSPkc4NZmlH6HhEkc5Eqv1PJI1+NtaP1wk9rhkIuPtXAgGhjasFPesrEeELSiWrW1CrAcPHaMH70EWwVYtHRIFggTCw96NtFTRUp
# DATA KIeVirt8MnQN0/mlJzMw/Rjgj4E9Mq0t9PTQumolQzCA9oVDpSuYSiJcX3f81ZkLbSFnQOLkT7gP4E++x4yCpjH2i3qN2rLnWK8Q
# DATA vsv0LyoX+RdhYvfKn/8gxPaDt2oIs06ljdIn4Sfw30rtpyloN6VqqXLHpLjxg7dEJHcb/2Fl9mJCIdNRbOOz24PI4kI5NoPIB7aC
# DATA oFZyHoKCzZjjiqX8K3pHuwot9F7jVz+tCf+D0VALM0/0gxpYfZegBK6hDBmbqvlMU8VOM1t/LZimNJOp5ocsmoaeijQCgX2JIFv8
# DATA mzic9fhBasYg75Ij1LEGCV4sAp7Gt8YKosgZa/WNO2/9NwsVspFQuyiSrY40rVgbnFK00psK/uecf0I9nZVv67ccZEyR56LNYbsk
# DATA ujAa/irlU1cXlVw3hpaLuhKpiAr5vpKMKx2fhwU+Jpe+CxQnVIoYJGqC0gt9aejyyVtAArkziDORu7xlZjg47lDhJFXt5ORJb1uT
# DATA v3NZb6EwqDhqBKn4bCsUKRCqB+v9Gg9fKeIHsppo1ZFJxR0X7R8hNspbQ/6j18MWOcXbTjyf4+g5SzIj9GwoGSkwcwQGEXDxdP0m
# DATA 1p1p4w7P5Ra/IA1yiDI9sEwpn7OBS/bfBTksjKVpUauGDv6Db1wU7dyC32jjMfYe5ogiIzGoolGel5TwubTNP0m3Ilj8Un6z3eUo
# DATA 9q7YAM/ZYxiiLdsGuLJpg/nl9XmT9w9AG4PZcHm1KK1qrRPbNfegjqZbk0QHG1I8ZbhvppQJN8CSH1zJaoABR/guInTADu2BGXGj
# DATA tCpMjWsSnTyF8jPBqwixPJXuqGjbYKuaC0jFqKreKvGzjkK919x5Pl3p/KMnf34ebP5sd/PP6ptbg4tPfvCkhsmqZOCxlKVuLKSs
# DATA oyQ8vIgZVgvLv5qXTWbEEQx38bbbvlMD0jBqFSrrB+EbW4wHNzQOVKBOArsIJ+JtMyEKCUoY1D9R7yOtm99r2V+MS0U9Kn/OKKvF
# DATA b2Cxs1MgaHZBAY+HX7Fsz3PQNqzf8waMZXONoCvq8tMV9wX0RDXNy0++mX8zfXIJm+6bFdQqlikOX9UbgHJOH6owBP7P6ky6mmNn
# DATA FyzquATWI/2f0jrn+cRZnl8UrLuGzZgD+UVfJwmwEs/UiGoQJMc303KRW77KJADTLnp6jg8vCpdBg8ljIeUXAEwPaznfPe8TfrTi
# DATA ef+QybrxG5vul1MGy74xQpOoIX3/k8I+yUP/1Ed8oDHk7BgHKiT9pzpM4jYsa3ScNy5wxiVSpUU9XREDq2okKXR6UWqzJdBUwX69
# DATA K9B4mJ1rn13OhrQ6VcJOSY9sEaXLRQ0L4wPv/xJ5Bx2utrjzKivJeMJWt0bYIYbczVc8lI66aZFF93rFkXlZXNlrhZ2ariPrCkeT
# DATA QEQeSzlgHxqPA4EFklXXYd3hsMssmGdxOc/h6uglI35lIScHkna2PoS+l1otIedMVS70JJcTpoljAJGviiZbklJjlNatkwFWps57
# DATA KydK9FV27CdmRaRGYdVyTPFN1DUJFek4rtFP8sCKrFjB0U99s/pEUhJqZaqiN2sTzHC9jNFpsKathGV1RNX49asWyTKN3qpjw9qn
# DATA Ki5jLNFipTlgNRosS1NDZ5cOGrxJFnuYyrXjN56CNlmTov+SXYA6FGbscjy9jIv7b5//E2NCMsaOB+PgFslmdvvd5v+0m51GJ5f/
# DATA 02zUW3/I//lO8j8/erLM5k+GyfRJPL32Z7eLq3Ta8jY2Nl7wjXQ+l6M1dMIn8TPLoCGFUB0UIaMG982zNHyNtZNgT9agO0+VEZ1f
# DATA EtNT3zGZXX0eTSfIK9TXn2Z4izZ/TjMuaYJjjZOhKkr6Er6qJnPdZ3abqY9YeUF9Ruei58FDiomCNgH8cIHMFrhgGXsqDwbIAwcD
# DATA 1BPpam1gXwAtamYVPQze+TGRCit2HqIxYnw9t8kkwKxJSlzN4gEyJ8/zohjr6M5mcaQi2GDVYi7VTWVbWW1JpliiagNQymPLCkTQ
# DATA 8T1ghxz4BbFdxh+hx0pl+wK7UsFuX/1OV4tacVdcO/0S6ewguojNU6v1II2BZ67CdC5zQ33ImhpfkY52WiIx3Yv1PWNFqtWe34Ls
# DATA 2vbv6Z68LM4YNfyWlSuO7czT4oVQa4M0kZXZI7myIDqIhORai+J4hh+kdUXHjNQdaIkyzyVxiX/GwOBbkAo0OoBkpicNzkuwB4kE
# DATA S+iIknkWPLSnDegzT6iAiABBC3h+4VjL1+jaiq1WDCD/jPCdX1hgFawONZTlIVHJv3A3GOkHyuE0kWlU2l5RWrn1eYmzkexZ5p9Y
# DATA U3RmQLo5wF8WJzhFW7MYRPMiK+Vg/75/KrigG+yxypecOeRki4wLAmNGETGW7KlkVkdxOA7mVhmHYTxOb2orrlyVFeJgk70gK4i8
# DATA n9QJlyW9hvRou9AC4W1eylOJ83MeeSMqL50uZ4/BnDMxi4ypg3UU/K8xu287M0PU9qYzNF0M8UOEXYpiXFIG2CLyCHPU54N0tpC+
# DATA 3YkoOrabXZyrzgoIfk3D/EQdr5+wLtC7QTSB0qrmlZCXVsROGTojGYydlWa03JuboI/yh79YJjEYRJKpWlGsmDL4omyVqV/YYKBo
# DATA ro3TIEKOWTAa4BWPJsBIH0NnIDwZYL0NozJ7bSWfmOwSzhXEoBbuzZ2jdBrLtEZSDJ9ayol4ec3AOQ5gk/L05SGv1x4Ru5AB/XJI
# DATA LUskBt/e2QThgsDHYagxvwhTrfEkayI1atKUuZ77+nbeqUReRmOtIcNBh+bjRqjhSUHQqwZRMscFLFVWoyj+x4/sS+KHHDykzlTC
# DATA crW43/MJFj3mfvnAJr8mR3OXVOw8j/kX+LsIlYsLG8/BVLLrlFbCPr11agk/Fb3EYU+ExNwOFBI9mwuy5ftzsNqUzEdTeqCkchm1
# DATA sqq+1ZQTmXca/br0G4FpTgeFdriO1ySFPYKqbxlhkvbU8uaKzuTnG/1Qd2FxH2enMgTr9ihsIgLO3atEVFQzFPWSD92QxP4AhryS
# DATA AD+jBikdE1Xjdx6fj82Mx+VQKAErDdg762Q5nZIHi63oNa2+iIPx4sr+BZsscUeieDqiy31KV9TqVlY8JPoSqArXWx7myexbAEEp
# DATA CVM1/kPDD+dx8NrkjOPiZ2NQEMtNYdwBloX9EilW3CV7u0fHRwd7u4eDw92vj1+dDY6OzwYn+7vPvi4pRikHngfLKRbNKs/TdFE1
# DATA x99svmmxSLLDUBkB20Neql2O02FZv4h7aPPjUsUVg3wXVA1rOJD9VYYvcRYGs9i8iaQ+L21+E71ttO/gzyclTrutsY9YRq8l2SC7
# DATA neBR7nKFL+Bc6AfAuPjHe6RA5QGmKXjB0x4wO/8JpnmGr5ez7AlQAV5zsslejBI80uDl3xaTrjZ5jSBN0ijeqac9PMnAD7Id5B0o
# DATA kMC8GaSv6WvFISzpiKMVeT3IAKnaISejqFFZ/aKiI5voyELDtIb/aYO9eRW/Od/uW+FrmgfAZb2eJxNR6IROqACIjVVbloIpvivw
# DATA sR9cEsJUnWm6eYVujjGFkqkmChh715YiTTY90TcuBK+HsZol0U6R3Q7DpOUS/0z6Z/4gX0lrIuZ1PlUAiisdScLX8FTMmtctzWVl
# DATA 5x0cfbl7ePBssHf84uXx0f7RmYxmeTd2yKdQJniBg9JNzqBhlS40XKZxIbm7j4no7wPp1dHp7vP9wbP9l4fHX79YA5LVZw7FWKs0
# DATA Cjh8RnHtIk5ggwQrSzChBCiwL8ouIyiJ5vBNba4OAyMP6N+dwX+7d3+GnOCbGgofhx8UGS6KRUjal1/aC6LoFlWQ2pCu+duk+zs3
# DATA r2fTUlEH+pLJFT7DFTT4V+yvXLmwtVmDoxWlFveFZwkL6gWXHvYhbP0s+Vns/8jv+x/7jXqzrf7YGDad37vKh/uf7+59DXR39Pzg
# DATA 88HZ8TGw/pPP90tqo6idirFmo9TzLtDPkowAZpltfhcl5xLv/JhzehxR74UWDEDDeNOzIYiy4p78GpB3pTYnUVH6mFczJyK4Bwft
# DATA OSG8jrBP9j8/OD07+dpaUwNrDU0hUFXEp0YKTJnHqnD7gM83Y96KUnxsN5LpyrVf0WlJloJ4iSg0x74Yi2O8MMF1tgVyk3JUTerS
# DATA 4mBZ/FzU50JTnwGndDH2LdL7LkeBFeDTEmZX8xS/7+/xEOZOqmQqqNCBmkWa1vxdZtwR13LCSjHZQkqaBFPpS3mHqj56ZVhdr0pm
# DATA NV/ghT4Arn5qXfGULVI0VLVvwzP52Jbqars2mWtWSHUVMJFJf0xJrMoMg2fTdJMKwszwytxY/wZwbhIiliobd3OTs33xM5MlAaGr
# DATA XeUVX+ONsxw+0iZaTmZZWb8K4n2KZXAGQRYmyQ5ZB/wqe6AGyj57S6snp1pgK1hfcT+oMm5l8ZhafPuJ5T4tyok03qOccHRI624F
# DATA KJU04AxFbNV1kGkGSxLzMpm+IcOvVKkUqIyme2fju3x1PRNe8QQ9ipWubptVPnJ6/Opkb38d6zQ8Ra/3JzsUqgW9SjSnIBos4jeL
# DATA MjxOUZ/ZweDqZl96mOEF6XNKdTpfpK9jKRtLn4jDYBQvQqtnXiqVzv/8m2yj9PbuafXiE/hatQZmV+zH5DDi16Gf0qe57+fmOzNo
# DATA 2o40+n029hr3x6Ptb4TN6v8MPbVVcdNaHlsHJEDkue35yvJAWe5uva/u9Xh7RbvgES7p38kLfSH6lCBArI51Dk+e+wo5I9GvcVuu
# DATA GClmv+LJ8lWGUMkpcdYw6rUd3pnpXJcbYV+HmC5ZwcbJeT1WPB+PUBetx2oHa0iVEs5S6B797D7rTjdyVmJNZ0ZblKHNVrtneFTj
# DATA JI5Yk78hiiZzVBR3e0XNG78IcokLrE36KSCVsoYQtkTtieY4/It2XFU+XB3lVRarymLWc7GDxOgtWT4Bi5712/LhCb3pcvV5kflS
# DATA lt+VWWux+7ltzzxW9/tsd+/Hr14OXu6efVGq5MArsL7X2NvSPryCtmVqKqqhNrP1PMsltmY3WRUoNK6dl1egENGY8JHF87clOqm2
# DATA bS+sSt7bVqHgGgWN+Vde8rwLtYQDqF6MUMRf/T/yYeBe727NThS3u4zEOT1q5qDAgw6WYOVQZYO9tRTMbaJBw39QMWOX7zbP8K4i
# DATA 7P6azYYLVf7C5Y28jWO69A5g+1kyKxv4qtzVGgUgT2FrMeZ/tMMjnCv0XjxGORCtAKtPfr7/bPDs1cnB0eeD3ZO9Lw6+zKsIBX4U
# DATA 20vkNiacKPPEcCn28PufAUfZV6UNVpHFzArLcwKLo54qhQKFxi7YbPfqVmSlF8Gv5ubyVMIZMxXMWCqX3v2/7//m3S/e/9X7v333
# DATA S//dP7/7zbvfvvvVu1/xx1+//4/w5b++//n7v4I2/xs/+O27X8LXX777Nfz9a/z7/m85AQvJS3mknCiVqtcoEfZxHEyXs4Ex1vIO
# DATA TSfYs5JXgX6dzNdZHmgdMp8mvTkzlOuqv66zyOGPlMC8YgMjA1F+uZplbqwj6G9vAa8o1m5XPK9C45glij171NLefvwx27mWc227
# DATA yDt2l7OeCZe0GkZJu7jXJ8FDx/F0xSbnusPKnHHNCMvCWU5Jj8McfDa7Lfc05R6y581MBE+4FMq5QuVLsz9/x+T1FHjz8ia3cu7p
# DATA 10khjaePc0g/5IGtWKke8ZS8Anok5cydoqk7BjspvztMUtCDLtFv5f1c78EVx9GaveKEFewNw5Sw4xe5dbxVijBLXXGW2ldEVUA4
# DATA 981Tz48CKwdHp2e7h4f7zwQ4Cqsv8Aas+5y9VTVlDc3DuwJmBZ2j8s7db397KvmA+M9qRhj0asEjJgNilqaE3rFxVOi6/jZBIOyL
# DATA xI+Z7ff9/Td4ujJZUHWj+TQYP5FqiEYZ4bwauhwnGfOlLixzvz3SihCAA8h0dfyJV2cFA9jM6GZRfK1Q5v76CGe+CfBZqm/ipD8Q
# DATA FdrZD0KDKp/gglmjgOroCFYv/NjBxv1uaI43PjvAqz+OT76GzTF4dbpvICwaj+4W1yh7MKBhJn+GfhrehHpE5XSRDAuQXaEVYLV8
# DATA 3Xjs7nEJHJXHJWfkEcxibnir8gDQ1fe7DymdAYPyrYnJoHc2VSoU4C2k8bQsX4kD4ncDGI2JZu3qFi2d727+WbD5MzwBZj4OapsX
# DATA b+vVRrN3V6pKvttcO22UgmQN8Bih8fLk+E9gCYFi8B4Ys5KUb7/jF7iB+TGFdooTFCTr4ffmK3ZymlBXsXH6Q1ZfGL4ip9UDUTvW
# DATA 6vBSFo0avmdH7SYOou7k8kt5vKothbi5lHyw0j6Z0a1reO66ii847DMXloCymilzU1EmsLqS6Hb5LvCs9u1LvNeB+lkzwnld26KY
# DATA 5IEDOk7nKtO6QbJKvSXN5aGMkQvRHDjmkO/b7ZjW1HYMcSeyo8k3spohUGL/AKUHkGPAzYpY7yrg9x/IFqgUmOkCiaU2SaRTGevW
# DATA Pln3plo990X+dv+bWBzQeAXQqhKHACZ5Yz2fVL4LcWHxHVmMbYVRdHbwilBb+iROA3WahotceMUxjTwJrdpgAry9SVg2sqfUM9Fj
# DATA Ge5c+dXw6GCAvsjBIuVsd6Tdcs7nX6ne53RR0bZn8Sige9fAZh/jNQK6mCH+MlelUfEooTn2wA4Rug6lthJQURObxsvFPBgP1ARV
# DATA fxnP8pz0z5m4I9fizQ4w/j4xsY6WyMWTo0ENR8UKQM9vB5rjW1ShsPKIuPP278nklnRDf9Wa1k2mgKaBaldwPsPmwkqymFc+2ikK
# DATA EOTQUrxmZH/TopmAoXLKWc57KQMkVrtxe4iiDOusrBqLC8gxwU1j3Kw6+XICGTc6S1RJbsQvrTrmDloS1EZDTm10USAPXc+bAtba
# DATA 4aB+S5v8I4ULJ7hhiwZNi9srHj9fWWMSIy10UxYDrp2GyylTn1EInH1yr8itsiJgU9nNoEhpEqlbWVkV9cKDqpJkdLt+F+LZeSfG
# DATA SsfLmdaswETL9JfhMhlH/G225KxUqvisG1CmLlKGjOSMLlLksaNHWo0LY1DumN4/GK6PZVTXn2syZd3cXwNF4WuroVfuZ5VQpFJE
# DATA Wbc+V1bERaEFcX6f9XDhrWZPyeHVHUsP4jP4RadMJM9nLTD702uGBIOrwLmkvRrl3uY2Ss5LB1gfnH105m35sfgAS6EXny4wPBnQ
# DATA zYsHZ18rj35BJhjwiYEEh30NeFmye44wWgOSTr4+i/FWY0nxkWR1m1+siZNbMXKOI/N4BcAg+fyuwDwUtX88NOzw0QB9tGPD99jF
# DATA eHa892NYiS+PD1+92H/Mgihl3NjYePD7VJFy8biWjSGzJ9PDJqyo5J5dUxKzap9OcqSrMjgKpYCoHqoXz13GD5P82p/DfdnnFbRq
# DATA s3pHRfakVCBhHoh3JHTifHFbQHoAs8yNpJRJMlbvlM28KkVBjWJxpjuuWngpXnYNwkcMQ/Fa5xQXFdfQbxemi66RvBSEA41o+4FJ
# DATA rIffbccwVf0V6es0k7PxSkY7Mv3+kCCl3VznJbCjfeUFY6FW8OFqGcexqf7A9n311vx71ZeiZdcv36M3OYMUL6OtxFX9MhopVSzJ
# DATA Elccla54Uz+giXGfVpcrL7taKVpNBQn+Sku9P9Fft1qjvv4uzCtHrS4PW7GSnRQCd9dt/x4UX7V5LD/GY/TOVZ1TaZEfqOl9sM75
# DATA 3embRSfMVhqa2LxRT/NBpeIoiGZE6kyS96iokd1YoiXSk+fhTYMDkh+DAakZgwHK8cFAjnFT1YY5HWrhCg613fnlEkM5L+lJOYq1
# DATA CNsZDICXDAYV600Meg4CeaUMiETwsNAuKDY7L4ldy+0nkeVRW/OufYYkvEoRyTvnjzkecnF/t5ypsGnyqwKqqbdTooJPAyxWqNy7
# DATA cyocLR3RH+xKJTk6HJ4YymVWU4kQ0n2ORlezJOglXkV+XwfivPWyUJcqMPHkR/RjJ4j8P+9+8e7v3/3m/f/+7lfv/hvmhfwCM0be
# DATA /fd3v3n3XznxQ8pmrh6PEWFYNgpl1T8+lQ8/jm/p04pn/fQWJjzZf4MHUN/9f+9+C2P/1fu/e/ePAsM/wOC/hr+/9N//R/j43wiS
# DATA f/AxH8V/90/wyz9ggsr7/4NSVH5T89/93+//ClvQr/8ZYIdmv4WfqCf4+uv3f4vz+v8py+XXOLOn/rtfvf9rHPjdf3//n9/90/uf
# DATA Q1//Qhkyasj3fysDYurMf6K+fgWffv7+/3z/N+//+v3f1YAu/ies/3IVj2ck8qcLvF6WNMTv+P7HbqvZzdX/afTajT/U//ku/mGB
# DATA sg3yZEs63sY2fA86vVFja6sZhK3+MOzHraAeB6MoCketdm+rHfaH/ajdaY/qrVav097aCoJ2r9vvbMXDYbfZ6G5g/uMGOY031EU9
# DATA G3Kf4oa5uWeDqinCD61Wv9dXOZMbBg4Yq9EbRUANwTAK6mE06raiYVzf6gXdUbMBb22FnU5rqxON6r12b9iKe/W40Y2HQas7CqLO
# DATA hrr9hvrVV50WgdDbahUA0I3jRtAKgjgcRv1hb9gPon4vjmCSza2w0e0MG1HUDhqNbqPRwFJWQdRst4L2KKyH3X7Uj1wA7Lv2imDo
# DATA d3qdAiDi3rDXbgeA10a/N9yKR52g2w23gmbcaocw4ajd7LSGo+EoCsL+Vr8eBVthvwWL0h622o2tYQ6IgoJfRcA0erAHi1AS9Tv1
# DATA RtxtDkewKK1ee9iNunG31Wm3gB7arX5UD0b1JuCstdUARDRHgKs4ajSAVOJRGLrQMPsZDOmKzXWQNDqF1LHVAsrYqrfacdRtBp3O
# DATA sFdvR/1GC9DU7AaNsNlvjXrNbn/Y7QZRqxMDZtrNbjva6vUaW2HUciGhe+4GIoTXQNLe6hShpN5ptGD2zXqzH2z1w6AVNoJu3O42
# DATA uj1Yks4o3tpqdwE/zWETQA3b8bAehd14q96G5QK6KgAkWwPBVreQRKIwrofD5lZnFI5wzwadsN7vAi30+sN6vdcdNhrxcBR2us2o
# DATA Xg/69T6Qaljv9YbDXm+rE+Y2CqjKAAIdFy2GAuba7RWA0WlGHWARQHmjLeAL0bDfbbaAX0Rho9/tNEdh3NkatvqwPj0g2aARA7Dd
# DATA sB41gXybnU49D8b8Z8Nguo4q2o12swAGAGHUGg6HQbcDXde3APujZrsHgzfqo3Z71O+EcS/o1XtbW6PRaLgVbDW3ev12vwUrVm92
# DATA my4MdPveCLScG7Cj12Gj3mzUCyAZRo1wC5a51+/EUSfobPW2+t1+a9iHYfsh/AHybYRAI/1g1IMNFMatRr0RRkCuIAE7WwWQZGB1
# DATA rYOiVbxfhzDpfj+AJQP674VdmHUv7taHnVazFW/B761OfwgstNkYAkLDfgDL1um0O82wHcHe6q2BYhACMxunl2ugAUrbKqTURnc4
# DATA 2hp1OnE9iOIh4L3X7w+Bb0atsB50h+2tuNHpAA8ZRnUg1a243+21692gMxw2wiBu5EiEFP6BJGUmi9t1+7bdKWIg0VbUAMYQNuB/
# DATA sD/bsDXbcacdjOJup1fvxI0IeOtoq9GJe1EYRc1GP95q1xv9Vq/ZiLeiHCzKNF6zcdvAIYp4Rz+M+vEoCoOw2e5EsFFDoMYw3gLG
# DATA 1e3068N2HRh9vwnbudupj0AGx80OMPhhv9WEBey7MHD10gHJ83W4aBRRCeyGdgfY2FYYdloxkC2w9kY97jeAeFr1djscdsLeCIDq
# DATA jOoxADNq9WPg662whzfR5XmpbXatE3ZtWN1Cpt5EIRvDwGHQbYVBswU0244CYJW9bhRvdWDfdkG+t7vtYKsFwq4LnC9uRhG8FDY6
# DATA 6wEZmHss16AGmEIRyW7VG6j+9PuNYNhuN5p94LaNqNOAH7Y6w7ABGAESHfaBvzR6sI6jejfsggrSBP6OVHwPSFGKJvY6koEtWrSD
# DATA 2lv1DqAjHoZAv90IxHCzEYxawEhC2MRdQNtWt94F6EBSdxvA+BDquN3oNeuwj+5ZKlPAcB3PbdU7RWpSAyAFpj5q1Ntx0A6Aanoo
# DATA 24Cz9eG/deCy7ag3AqUSdlIjiNqgKQ77sJzhCPA1DIb3gDS7RxiiztEplMfwf62o0+n0gjbs7H4Qg8oEKmvcgT0EG3EUNYcAVbNT
# DATA j1rdaFgPwwh01yCobwF9h10XnMV4rTBu97tFbKWx1QOiAHkLsnXYgO06bIdh2IqjEYilXj0c9UGDBAIZtaNmHAy3tiJo2QKJPOzW
# DATA e60cvSxHN4PLZTCP1nFaIIciNW0E8rUFW7YTwiYKGqMOMBrQZLuNsAGK0mjUHYX9aAugarYboNCFW6BKh/1OA/ZVp57XSdhJtAlr
# DATA sV4n6IAGXrQYW7DEsBgwVhiMwqgRdIBjNEed5lYAzKPVDQArzWEIbB4UA6CjYQyqWi9qgJCEFVMMzhNgNvhmJyRG+nrNF+8SFdaa
# DATA NdBaN7w773t/+PdB9r9RwP8N7v/ugnaWt/9BFfmD/f9vW//3M6wVEUx9dehiLglvUv4XSwclk8mSNI6qn45GVCON6ckPU7xH8L66
# DATA v3w9p/oWz+fTVH25/FkyU5/xoptxMlRfk/R3Lw58tVwkY10fOJijn0J/jScz+zuXDMb8hJPdvTO89aLIYVbynh8fn+2fYHJG6Zvp
# DATA 9/2T/RdHu3uvTs8GX+wfvtw/OR182fgGmu0fPaM23/fh02Bdq92jvS+OT+hGc3LV4gmx+XCj/Omk8ufccvDZq6Nnh/uD0y92gc3u
# DATA lOxbQEo/2Kh4zw8O908xHaWU3+AlzvMUVRW/2W6JvNO86DdHTbAvLy4Ziw3f0YYs3R45Vp9yskS3tGxv5cK3LS9noJyeuwLhzBp5
# DATA vQ648lSrY4SWAkcJ/u5YxzQhS0LznZYrRomekBhwznfLlMLfxU+GH7XHqlTxXuz+ZHCy+xWWlu+6RTToES44PGvmHuVOlkVlXGxV
# DATA 1xArc0dxCHCUnYoYEhmi5+qKkyFfblIlAtdl6uS2EqtTeVe2bU2O+FIDzKhWl+XK+yK9B69jddvytre2KF2Jak2p/5Q/3d60Tj/g
# DATA 9/Pa5oX9U+XjyqclFSO994yD3F8gzEug0sWZMF9/gDckxOo6D0nUxLDPgq6OLJc21SEayr0YJXxEbLGcwebFGuMYWsEIr5RexHpE
# DATA SQbowHqOXDmm3OA6RRXvvuoD6uymgUaV7qyVdNfOOjIMeCdNwkfH5vYreOsv4nqYpuOy6RR+tWaiS2UDqdCmE3SyRNixCYwfq1Xk
# DATA HRpiSlOZeWTF/5HfuG8xnumb+WQ5Rmm6iOfmjJLwWiw6MnXCbPS1Ku19OU8uU5XB82UPuW0tnkacvQNs+cEc4wNzO1MRhGqhSBwm
# DATA U3l4vr2Jp3qw/wsGCZ8XlVBGsMr40M4qQpHxbPds1y9JBUV7Y+DDvd29L/Z9Ww7QBlHfW8072gvYb6XymJP1r6bxmxnfG+LM0per
# DATA isx64LxYZOlKOUwElFl471q/kAsZjY4hYwXTEBQIlx/xcs7x8vBZmdmQ/wnzI6FPBbFDo/J2DkKLlCvndVmS8nCjtFE5b1xotkjF
# DATA oTS70wkt9wwAAgW6KRbTGwRvvQTcudvGzzBc1d5Vpk5yoKqnTII3yWQ52VFM3nDIBwtu5o+Wr+L/C8Y2nXbAimGYk7IcB3Oq6WDO
# DATA +FuHzpEaeYB0ButeAuKr+EGGzeJgYsaiK/B25Gc6hVCWmUCfDYd2SDgAV5Dnj4CXap0t0tQfY6aNSyV5WaevW+A6GeV5YF2ygMPj
# DATA DzB6q9nr9h+DK+loZXyZsXXODXvWx51jEZO4J96W2IqlO7RF2FSxir8Jw5V0rY47uq4UXj1Xb108uK9eTbPlbEbZqGpHKbhLlX99
# DATA CcvQqZlcfHtZWwyVo92q0RxkfdCQLLTownG32gt3zFh3SvZYpafoqao8JfsN15YUbn2qkEuiqKOd8g1p7H4w83KFrahSxXNT5ZQK
# DATA wKdyVtLGipGIq2dOiG5ewBrDT7PbvwQNv/KXonT+JWuc34DKWZGjo48Qhw52ESiqmbMiay0scrEKjUREGaktsjn0DiDnEu+Ah+kC
# DATA ezDVYz4UbpUz68KNyUll7phhwZzsTM4dLhRcdf+HvtMI6UAx7A+EAwvlmd2QLSfu8I4OyASg6nYghYmV8Ag+xrS1joviVrBkEVeK
# DATA l4QyYGtVKUsmZRMdOfgWV3+bRRidntfVmfi0ji5yRmfL5QDP22KzRy4bk7TH1So99hkgh8PrbXynLA25r64sSiJNwq5cJOzb6UVX
# DATA /GWrhSQF1ily1Qziz9wiryBQ8yJ+dT8fcB0uiCeHIfhRykXUcB+UHBEjrOajHS1wNCbuP8+8qu3xxeJrWI/T8yoL0pdf2uKYWvOR
# DATA lcpKvXm5/xIhd+ndQu5Km+JKUetJXl3NOMH7SgF31kWna4hfX7e3QjbAvsx5Dpn6PURmikfrlwqSb1c6wE1kvQKbQPmiqqyxVKr2
# DATA BrWa0uiVfHEMKYVoYFhT/8wc6ZaVxD368ccycwXDNo5xt7r8+hyiC7pz/E5Spjm9nha7bNGKWutKvr2qAtdFUEXrnwzjKMpp/ZZS
# DATA nbMb5cx4znbMV+C7x4isgv4KNoJt0YkxjING5OAr8T2XaG6d97YvCgxCxwikbbDe5HOUIzWMKBfyFZl/d11x1fVCR+GuQPr8LJGT
# DATA +OyprQ27bbGKZMiqJlcrX5fsA3Tg1j6H/+DxZdr36fCnO0la+wzX+eC4zH1XCi0HIKmc4aBcX3nDQTT3R8i8fXea2YrYUyqgnFmm
# DATA WYhrmA2dgkng8Hy6YKc032YzSDKwDSwTxDC5glTFQaBi+bG8wgblAemKrYe42hnMAcTVbX4Rs5wjgjslEcndF7oc+BmYjVLpV79Y
# DATA k9K92stonijRy9jDGiNPSmacmq488s03+Z8f54HAa8ZXSFTwWMqfdEHhYo1wYaE8fkO+epoZN6kwZakbOm4G2qzbEa1qls7Kis9V
# DATA 1nF3/ZrD5tVVTavPtUo1jeJ5kUwJAxBSdjW8h0RKulzMlnRuwBBm5QEa5ncU6d6sodxCGSAnHB8SBXmv1nSU8kEjAuYsmB/AL+VV
# DATA fQ4bEr1V+SNCqD5ixMLfcbSFqg+CoN2GP0XHcjC7n5Yc36/aCHKli8W3Nafj38rEyNAqm8dZVma84QYmlRsrKhBUO3VdUVuEBgsK
# DATA XbUNF/Uh++xB1x318qFWDb3k5+wxAfMTjkSx55AKomDjmkxdub60iy3/pog4I6bwRl5G5XkC9P1mm/6LXLtev1DdsP1CD/AIVDC9
# DATA jNE7bkuyKr7g1pO0pDl0pKDAIJrS07h+OUe5xE6h9vZeWuet1o5qZdqZWxZ0wQrtoXyiP9XQgcAFNlh/qWh2QrE7sX+ct0sFGpwi
# DATA k5wBo90pqO/qnr7cPzk9OD5SA3Nljxr7RB/j6pNepZAYRzPUbwVmhZaLOaPOsuY+yIRzMcF3Bz3GiHsMK7TdxPZTRSJ4szZV2lDn
# DATA mZwqoGsW2CEcIkNTVsVZ9e8aU+RwEsTI+j2WTGx7V7siMaHGeCO3Vad5t+T2WlPXrXmsCw0LPt6WVjrQTFxsvW2Ht9/dK4Ac11fl
# DATA 7s7aeGXrtgecZJXewRCjutcJ2c90sdPUl7orniflkFdcAGr9H+nit9wFumft7bdsEj61bRlA1rP7WUfFeY3gVDdCUmu1RdhfILJj
# DATA wGyRpZjy2RheJb6FNfxJkbdlbKrONZoeYf7SjWxc5mheNlBZd7xRnPmbN/U6R7pMmzV1gB4pAs1JNXVxku6XTeB7rv4STQns405H
# DATA TvcpA9d0A4iz1t17qDDOyglw07gopLO2/uKj0XAZT2N12Y2Xu3V11eegD1Lf625Q5SddT4M6A6jP/dmHAQvOAHIJrpegYsXzay60
# DATA FQWYERJZQNd8qRTnU+JIBrv0Vq66oXqYud4kSQl32FNfchjoCgaAF3RdWKoRFdFcmBwmQyK1gvJF+bUu2z7B++vHib63nhRizDUK
# DATA iMNQOTCVhISUiZ8xLD9K3uyUamLgbWIUJJnvWBuosp6yfkdnjq45buAUeeQwIcW3H/OeduK022573dRU+1db7t7SCWmmz96rHoqL
# DATA dghtCmmi3RPjh8KbmulJjTLTlNPoLX2r7e//5OAUtoR8AxG+/+Ll2dd395RYWXnyfX93SnctWcFvvL5pthyOk+yKtkGGst7sAXW/
# DATA 6FWSFXQ3m6chWCl4GJ/Khyxgy8RLYAp8pZ+vgksqsQOLP0iaXtHsfxdmdD9DAkpRx90LeBPXQyHcF10Q/a/LqgrrY+DkNR2uL5Dg
# DATA NMujyTyR2yvMPSof2ZzE+l0hV7+J9OxUljHb/9E4Fx+K8u4BaSALlUy7gkownBxZm08W89jaTLavwVU91noyhEhowzuvOx5cO02J
# DATA XtDhejAtK7+XwgPpTNGaXToArQOqp4YxglJV610PFAzI1zC4tzFh6dGtJfj76OZIUx8GDy/IavMHShuoagYakVQtghBoyJKsLV13
# DATA QNTocfGrjHPrXceYX+nELnjAJQuU1ktNJU3IMtB01QPWV/mLpREzSKwWVx4uhMG0+b/IGYN86u13n//faHSavZX8/0b3D/n/38W/
# DATA jY2NkxgrVPnZckYX1sSRVRmZc7illnWATgFMCI2gcYjKxmg5tu+mvSfdn9L1PyBJfzkUfUb/cqs/os/V8072Xx6fHpwdnxxQpjsf
# DATA SJISMOhvuLwK57UkfTJOFwsw6Z+YC2x1mZiVn/LXNq3vY7WyjNNfweN83+MUNLAiqPIPCm5x4c64zM39c1WVcFZ/yQ9Dv0PPdx7f
# DATA uEhItfB5tVjMsu0nTy5BF1kO0SuuhzvJTeLOmawB81FdMBx33sGL3c+x/mDuHIT4kbbP65tbweaIk38q3rP93WeHB0eYA08xXBVo
# DATA maVZQtWU9K0JJvuv9Mcl51q5lWiwuexa8qX/uETBX1UIPd9qLs22dTMFBuywYDzAktxl3lKYTp4uKONi9aYXXcLHuteIXkNw+X0r
# DATA nKDTtDEKhA+5YORBxDc15uMOCq9W9MF0QWqo1SPfXcBwPnATjnPjatkC5AQW4Sy4zEwF0U9Wnj8ja9o08VbvUbTeeOT1DOn8kgJf
# DATA 5lqJGnciF1latYdv0Ht6DlOQYm0j975BLvZo0xLVqLNZ0LlexJWCrOhrl8sbnC4c5Z63I8/A3PkoW9HqvHJhLygAni+2fHlJRd9k
# DATA pISd0nngrVnSQS7eDOaexbucP4VkBJoOaJaS1YQj0ZXB1qz8YJylTO1kgWbiEoPfkyCLs1qu193rFOzBIHuNPT+j4oPoueEO8OwZ
# DATA vQcd+T/FDGX+PcKO4/HI7ax4BQvnxgn0Lj7kaQH2LgqKa6kKltbGwdR6PAmThIsaijl0N+OVz5WK7Rkb69ifoqztNTeAFq590a2f
# DATA a+E5N18u3Ggav6SO8BDayx+jElwlMT1gVTiX24daL9/60KojnJrhOreS6183SUrXJilMF+MEZesSHNXVD3f8et6Re8alLZXLgJie
# DATA aKegaQQRJdGAcg/ae2TukiHHx46lNdTmy2n5XApaYpE+nN5FlVPAxKkbBrMFXgAt0+UfMVKiPjIoOxNQ91v1qgG84mShqBGzRQSt
# DATA KQ+n/fhEHKF6WBJYY3iGDqo4yvScx8kkWbi5mVaGeX5sAMlaQV4St42s+hD5PthGnDuqbt7j+7b4klEnNCvNODJrpnObxOOIj0Lh
# DATA bQTw5ja/zzFfGQtrEQ5YaimTPqHy9UJ6JVVnMeDCirqQuZMipZaaZdHK5XOX83RJ9yeomcEQ9pV/6kV9d7aMDaYj5j3mL5B5+7ZG
# DATA tHeHicUfU+cuOM6K6N7dCw/LVulFrvEpZXVfx/FMgMPLD4CZqn1Dv1m6TH4TIWab9RVcOChWxGkNadnWktCYuUcVyO9sveDEDe/L
# DATA 5Nb9MQN8MD/hpdxHYFVVV10gJ0nYR2jfFptfOU79VGXH7XRoDcv6S3zde6TtNHQU0kWqER7UY31qIlp+qWJdoK45OQKA67r9IORR
# DATA DmxNimoAQ5O6d5czU7pd0XHDAhm00vu4eLepSqcL4Jxhbu+5DM8akg7zoc1+H4vTeWpiTOLch+lySpam44mUBo7eW7CxzfCWFsyH
# DATA jfG+ORCE96CUN/NafCodY0dyikaOPlx1dMLpByv2ym+c39U/2tGbfruoJOeJlpmCImA8uHmi7fXCkT2xO2A3I+uP53PX2zuEdq/v
# DATA DUe6ZkABF3/wEvTv+1q8jeB9RNkmRiTYlonicYw27VPgKT4V4a0qdjgDIqTUQald7+p6K6s7n1AdXr00lZzOxkv6yY7feFyQ0tIj
# DATA TvXHorClLA+rKWZNZNZhuhzz9XnohB/fKsU2WaxbHO5vVNrDRQWQ3wrsd7Z3RpvKQgxPdfVgujVdMdgcpZQq38a1/sFFeG2T6EMK
# DATA +rLswbgmX8W0oyzXNe2R1VrleVkBtl5XNuQDvmwlqd2yuOISVne10ReS2f/rOYd1kYbf4xgP1H9p9hot1/9b73V6f6j/+l35f7+U
# DATA qKrOBxTOIRd5sdNVbH9UWMBCZwZ3n783V7flXvdv1X8JdthLMLnfrPEGW75fqddi15/gg86ktspZLvY67OTLUFiJ0XzvGmm69x9k
# DATA psSkq+X0NfneFsATx8FkGAXbzhEFy9qrYI2MfISWIVKKIPXnHjni5wUVMlTIm0NVi+AS+FEGto9SfuTyZpqPiZJZ6eyWlk8NnqjC
# DATA LHwZyKqiP4bFLXxP88dNdlKs78LKZpWrNTnJkCsC0AkC57FQHj+HOd6nTr77L+9+ybW9VSHvf4A/v33/8/d//e6fhTI33/3m3d/j
# DATA Ffbv/gkLgetKHgJ/Zh30y11BLZd/2mfqzDM5n/qIMvN3D86Aao3LDKj0OBYg/80DM6DEadJO3wbnJUrrvtj2AyLSAAmUSYPnxJ/N
# DATA RUKBLAVdwck3CS1nuMCgHJir+iwhKDnRUwtxq+lBswQdb0gz54wP955yHIV/JmeE4M7xYXLAlmDTp8HpQplkamdBp3O7Jd7okCys
# DATA hvLDg2cB3/1fCq9cz52w/pv3f0MkhZXc4ROWf3//N1QT/v1/gsf/SOXn/xle+hc+MlhQQF+IxQKRjiGgJQDMTd0pywQUTKJuGwkn
# DATA mE/gw92DMP8XLDz/GyTyd38PVIOw/IbL4mNZeqAUqzA91rt/988wlZ/D979dCy+RDEBYNZEFgv08B/dFcUaYXHc2sgJLb/Uod5tv
# DATA YRPfbYI9snyz+RY7vKsB565d/qyUS8eaKRfG6J4gltXz9luGUhf+u1CD8TClFSvGhA3o4jxaAnUyyXrIxoRzvvcxWZY2N4KFgGX4
# DATA 1bt/ef93Bbv4F6VK0bmrNXeuPxIdfyzRsBJfzZ4/EW+mpy/cZAfGh06NGe0v3v0jfPnl+7/28Q9+ADKD2d3Lsx5/7MWF2FQBwNvS
# DATA iisAqFjg2k7oo4qEffCsYUv9nU977dc0Ub4dgn+Guf/83b/A//3iEWtNrJgudyH+TbBxSqaSNcaixFTP/8He23bHkVxngvqMX5Gk
# DATA 5jgr2VUFgG8tFVnUoEl0NywS4ACgulsgXJOoSgAlFqpKlVUEIQjnyJa9Hh9rx57Z/TC758zO+ux+3XPktmS3JbV0zv4C8i/ML9m4
# DATA LxFxIzIyqwCyW561NJ4mKjMy3uPeG/fluXgeAtbSc6Lpe9et/UIdgGVmn/lyb3Q6BIq+jEdiuXAY8HOamYPJ6FRdiTr6k85sMmBy
# DATA Sl14z5wS8RVJJ1ROzz4QGJznsoDsxQgxcsRfMCH+yet/VH//p9dfRmqGf4npR36BWUBgJ/7m9RfRR/3px7MDP4C7XE8pxkAxrojI
# DATA lUgEByyyR68RwUGDqd24cetK54U3AwzgJxWbhEVALZDocBW1pt1pUexzEvoAyUtavsRXITMuifxWxqm1gh8FRvnfkCH+gheJcqpw
# DATA DpRILRSdEXVmIqxV0cOIanVDKXR396Tote8bUYk1tUs40x785hS4fMAg4VutIA/taVloH8euJScQTnjjImvYd9bj/MYNfOlExXBH
# DATA jFSCGVhR8DDvtCDixcPIvqvCxHpjOHQtvfOCRxKawC3ZcjeoBrZAixZnh6rRP0wBeWMM0DROuRXVSy0+VVvQTeii+MYZAaEw0OQ5
# DATA L/Y5P6j5bJQzuUBpIK7cW39bFGEUfZVnxqEVJJup4iDFwX6klD8/FdhkOKo57gCO1MljcuTOhWoBvVuhmqJUGhj1f8Ze/6kayN+A
# DATA +KDku6LoqR59rsjKT5EPfeFNCYiv6qs3fymOIjx0rkZIbwzsYv/wrMNxsgw0JvdMP3C1FqNaBMVk5+O1hioUontC8P5crSSRdkXk
# DATA 47LAZepgPGkp+fEdh9mj9QJ9LmYntROKdTeZWUW5b5XxgvJd/Prz4ODVuGGt/gPKFb+JINMWkEz14Lev/1nIDUCjcsfOuWBAP4vm
# DATA jk6lJiLji6wSHM37eSc9yEeD2ZSd0eNmE92j8C0AXeYlsfyah9YMhACGBQicAA0qsLgApi40KESq3aHmi8XP3+H2/1kUnNhfxsFx
# DATA 6RHkCzUNvO1zYGKQf0wdpb+CDGh0nC7VOLYIOmsvxh3sc+REEYImiI1OwsvTyuKM/no0Ke7ywscatiHoh1A+84poOBXNEW51Wcec
# DATA XOOOFs+dLl3UA+UAwui7i6lCe0xy6Hq2v3+Jw4cExsgpQA1/Aczh9T/AQRMU1NDcL+FGg8dSizClFxpicEgdy3AmxMBsOu3CmsqK
# DATA gutaUs/Vl5fvM3+uRv0PxGDf/E/q7y/mrLSFdBJdliga2qlS3Ao89asOEZNqTsFV9F1t/hr/F1hWuJOpZf1z0szQob0Ct8GxSRlK
# DATA 6D1tiDIxR5d9sk25xv+CvVfy0G9GDwdKYut3rREUNNg5utBRW8xk71lniJ5Tysj0rB4mUXcwGJ2SDtCfuLqeSnPb3zc+qey6urp/
# DATA 4djydd/tiTSPcMOhtwJfFLjlBdyZMCvjP+Bp+yc4XWVHTwtq4AnRdlpeKqzLuS9CkzvFmiN8KilhlJt3WzlL6Hho9FN9hi7Cy5qn
# DATA L7NejZT77opev379IfQI10ad81k6QErf43sKe8kPtW1jepyCxoKj28hx0VJXMJ64PMGAT3GuV4tHVJQF8PhrJ4VyqBc9DEYp+nEF
# DATA 1ouVKgqv/yBVGPcpmPb32hIaqVLq0Chd+AP9PKzASQT8W2+pZLD5SOWp+0fMhQoaSXXkFlBQlQkslwGIKmVFpf4hYCYSKw62AleK
# DATA KdZjT4sVNypgnvzE8W6LFvc7Zqkp4lhp2pp7rZuoJKjFB4PRASVCoKtPiQcMMcgFYae8mbgs42zPY5yurFIAx+JKl8ICJmxaLcYZ
# DATA 1sAPLi2q/V7ENF9gofu7PwRmBtZuaWLkya25chDlcshljuIcAeUSwsnXm8GbfG+cKFqtecSTggpM0ioSYpvjhxcjn32X4bXT9Kja
# DATA Z8gYRBerz+rY499HLnJX3VZVUvvBLTYsVHUuWlj7hl41DboO+KXvSdsc2CRC40yL5PofUBVk2g76JWs1r1gywv+D0GHzrJCPnXsF
# DATA R8V0qhUGR/FTqBeU6uFk7OTQJxCJWK1fUZ2fo51/y+2gHXLd9rSy3J84rZ4MzFvI7dOfGX16i8zFUyPih7C7DEUq8F6/bqIBpTWz
# DATA KE5Okv1h82AGqC0l1edZaT36pubPjLnC6okpVB3KZ68hbOoS0JC8Q0sARZi9Ypt4ooo9pY0CqEj4fTLHe5eY0c5Zrm4066/U/W71
# DATA ij6HTjaj34f/nxIX37/l+f+trtz+Q/73r83/b3eSDnM6lOpCSzmwFCOD+J+cYxxAm5BN1A3WBnsrOgWS82g2pbKIK6KKgM94OsgX
# DATA T/3WHY3P3j6pW/9Idd78mqbTxSPJdaq3yQBEbkKecZ+BGzNYZrE//AxHFNlyqGapw1+zIf7tppCDg0x5WYaKUU4hsAoOO96iO6hL
# DATA U7KWRYNh2BhFqvVQKWWbGJWX7QxID/5hxjbgCQznbovM9J8oGqBjFRT3htVRsmQXlFfRE0MeSOa1dNDqRNaiXj89Go6UYN0lnYeS
# DATA nRF2ZjqK8uPRqdkoSORwo6A0O+OeUAAZ7hi2fauPyfKEr+rRaEy704lJZABHnELK8SXvMjoJjqt+oG/a1v2zSZmGzMtKlDl/NhbR
# DATA KoC3yJ+y98g/gyHPTXWiR0bZEOYm7yn24P9Wl4V/Bg1boSE0AYKbiuvWFkzro9MJabgjG7Ps9sdMExwxRJTsFPQYN9+u15X2MWsf
# DATA BbcK0md/6btdqOvY69+5zhXQZwMVq25g006KABbSa5gPhMnLJzeZTd7Xgc1Zs+7D9cjGNjDOsZggcs1QHyOkeTpt7nQ2nmw9Wq8R
# DATA 0vG0A++szywU/KNoZaTYYjk0PTi18deKtMDNe4R320z9WmTH/O94S/25mkd1JaV756/Qx+a3oEP6HdiXYVnUNfTXamYLd/LfvPkp
# DATA 2d/h9v1P5IeIBvtfv/mPsQsE2eG55qsqz7bjZBHDo7hl9yPAgVIsSCsi+OcY9ar8M/oxTM/qKiZofKnuWqDW5dlQD/CKSXAT+qn6
# DATA 7ScBCferZXWpakLzrjoCfe4UynXDKcSDewDZM9CpCFfZTD1BbW+Ny4ehsDmrAOyRwxGo1TXRyZnEFeRHbMhVIPJ+2nm8+V13Pxnd
# DATA qSmyvf5RsYh5+2hju+LtztZDr/5SjeviBBK2HVKln8Om+5XckmQjF5sy7EhY0T+iXvIRnar33ycDR+nhucTA/k7td1Lu/D0O6ZfR
# DATA mz8nogYuudUDUscJvb//kf139UTAR4rSob0ZFEi/Ag9e9Yhc3mqigbsrSoDwWvkigvwdxskjHY8HZx2X2tE/EJeFF3mHnepLChZp
# DATA leQNQTliBDqkUU6WBiq/R+d4vw7Ptzrbj7Y2H3+mzir+Uttr/eHu1rZ5sLn14dbjx1ufMJiqvITy+VDFDvF02DYdK2PNOfPiqKMm
# DATA 0nSKScR+PdJPiDrsOzu8SJC1xctUxCRJVEREKZxm6rI09wvyEkRXn1+zuwHsCiDA7OsEpJeKCxnCcavFFQ1rLwr0LjSrMOWEzWff
# DATA 2uHqCSAEB2yLPPr9+VgK4iqqyrsDJV06LXMMj7lSsL+i0HyAQNvp9ySIeyG6oKhXE7uJDIuUDphUL1mPm+G6nZm00d7QRjpEdy5v
# DATA hRlDg+GZtaV1GfV9ZEWoa2mdzBNVRRNKqWSjKVxQcvNJYZA5wEHXeAwAQBvwGXEkuuAoyLHK6S0zYa9XqsOhbomRLBWqVq8Kdatn
# DATA snJnMfWZ81SnC0g0/1lRyL9HCRBdB3Xb8LkWGIu7JJHynb1x+GPEebadtDPNdliIpoGpKcyhCSGCErSpZkON9dqLDQXKvAgkMqaY
# DATA n4vIc0ooQyrxJVkjIsWYwIbwa3KgtmYT5Crouv8P6GCIvoQoemMsSVFkrlMP6+AMy3/FgNJMchc+2YtBX7DDD41bKmMud47VtVDf
# DATA 4kw8LZAKl+sIT20urOY+KcjA+A4fqns24F7wvZs+Qitaa5ly0NATCjrSnvRw8XFviqqCJnQR7Y9q2qmLFe3yNzM1C9pKDb/H6rJ8
# DATA Opr0zG91k5i/cn9r4yn+VCpPXFMXMo4vYUWVOPBn5AFPDOInyBF+E+FCKkGE45ZAVH/zl2hy+ufyC6gBGbMqi1oN+o6xenqZ6jw8
# DATA 2Avw1w9nGSC9wp+Hk/ToxKZRccCFypaC8Yo0TpoqwF4pGisGAyQ72fBlDVSynLxbAtS8yM74qak6FJWWTlXnITJtEv9J7Tut7BWs
# DATA yF70fLr/XvId2Ac21EbVyNEz8PpGu3nj38SSjEK67AyU3DWulVCCQIpqPvHoKrwgwDpIEmDKU8ho1GlB94GGtM1W1JUdDtKjvI1V
# DATA VtgTuH74R2dC1omQMbvKe8UG+JUDtas+5wkfT0avzkj9Tf1wDmk9etEf9tpxN+31zmKrdzFzW/vO/WsirWizsZ+4k0vV0fzWvlMo
# DATA yxZO0DWCRxPKoyxrGhpS8xO4D0dDREvTHy65aFggQcyGdhmGoXXg4fESmMnfkE5hulf6L3Rsh5ofiIRDLqYWbxmYNQp9POoPHZ93
# DATA feh4h8CknCR/Unue30D0+wmab5/n7yW1vT+5p/Zq7V5SgI4U3hA0Hk5miP+os4QLQFNHj24i5h79fWufdlzIgqREMeSGK8JhdSgB
# DATA Wfzc5rgPBVIMgCSATwXhPRQBA8keT5nuiAR800FUFKeO+6I6g7e5+DymSFSqBB7x37qmc11TMRuOG1wF+B6HFGQle0LfBxxOhsjf
# DATA eUKpCjxv56hHw6rcWG/s+XvGw6KJmwYaSKKG//DCu9ziPGo8N8zWXtw7Mrtg7mgTeafO5zx/B0wFbpfAIX6BAsQvQVZAIeFLvGb+
# DATA gp58DtLE79BX4XMlUfyNevobZDqTDGIkMqIg9+QlBi8ycImhUA1UKJk3b/46LgejM+k2AVCnHgm1TEFOI5ZkFMNWCQcEsG31SeZI
# DATA qscsYULlJrdQIWV5Ib9PUTmKrMzo47B7sso91dY+oqcaTVYhsxjmAtdp5rEJbL6QgAr+Kj//HFt0QhovTzFr9B7vv/9+eQMIxH4h
# DATA V0T1XmfW7PV1BIhZD6YeLTnXgVVbCs+KuScyE9MNDV8i7BjYx1GQrNtsHDYR3ox9ILEESc3wIYf1InBolUxZhCgzde7RXw6s657d
# DATA a6jttR2CGwF+oLUeHqwYMxXCFcNJJg5GsJue7KIlH20SQeGnPxkN8UZMM6ruDVPKxp0HJKKSMAeeJxDw1Odm4ve0AA9Lgr5gQvei
# DATA iR1fZrRJSPbIn379IhZuBbiUqOUsLCv1BeQ16IrNyrPvhrgsJuWJow3gHNR91n1iu4GsDVhIn1Ar13vX5sCX34x2jzPFcfNppHcd
# DATA nKZ0Nj0eTfrq1PVfZhx4OMxOoVP3WJylbEJk9xoDIOt0NCrm3DjU5qn+sKwLqEmZ9I8Qf7XtHi9cEKFFN4F9tO51Qdd8L5DA+IHx
# DATA Yif2Gqv7BJiqheAygZoETyNFqxZ1V4OSsuO8EaQz4i5gazpXzbRo3S5cYEK7/OVbVJI/tzv8zZ5Tfh+d0qFafUjBJoC9AoLO+IHm
# DATA oZsHXaCPxnyQCGRPMcwfqF3fwCBUqyHhxygAMlQgP1KHwwsmtZXYE1Rn93ZxpqC5w7jOybZ0LzXFAV8vOI486TQYvNPzQGCMUdsx
# DATA DGPHEuGk7vobsTG5BkX1WNnfLL4RW1d8DTbYV7LQZDwasDcYPlML0EA7+IzdCx1gTql70V7xAdTDPU4QrtUS9eiG0LWAarzfReMz
# DATA 46O479Fxd0eTSSyw77WJpLNIfqUDOI1V0tt9ozJCNDzj3l9BxTW0m1ZialcmiE7GBRP6GPhUwAnodva0x+/BaDSoSaw4/psGvTOl
# DATA VTCEgxNu6dmGrYJCDRLvVqSbx89a6Mah5JlsDH/UaBtJW54OTTbWPPcDeu3v8wl3oWUGYwec84jzCyFrQCeBGLIADT8tVqemrrQ3
# DATA eFt/6IuBnjSDvL9wskAGsHLOwp8wSWhw282zk0Fc7F+togJM+9icvoLDQEZoHDc6yvolkkLO2QoPh8A4CtZamE6jN8jARaWostfa
# DATA NFd5Xwd3lM5JpnilfgDWdJRR5W9gKvy7P0SQUPmInNUUp5hkp+lgIG+ZRolnpRfyZKrpNzYn39kYw/NkVYYzwBkBHlKjTKhOIb51
# DATA alXwtfbiGur/Q923fgUW8jd/yXaeXzr3KnNnMm3BrQz1dqoUqPJcbAUwztMNC+Lg/9r6lNhpdkR9NIgGuo65quwnRgUPGlMgt1py
# DATA Qdo9GM16h4MUYRrjoy6c62RBH5lfEHoRKjMBIMegXv0WbWF/H+0+3ikZlNr/o0nPaKLZpLOA1chq4PVOW3hK7BdmRgByPp9mKRom
# DATA QNDvpQP15dvNwE/IwQJUuH8Kl264lfvj194jpkuu3QD6vKPePdFu5qafSdheRoOE0S84wMXGB9f/z1ld/WXV6D4vqqR//uYv/FGj
# DATA yh7PvjjR8LNm6IRZWvrhX2wDc/SUEmrdvn2LedqrSXoWbEQSHxIu5e85TW1QYW7tW7a5eWuB5kw78/gCAnHO3Qkgs0s67mMLILzY
# DATA 2arbMV2gIenW/OX7b2RKePPX0drTjbqzWAA7wTgUP48+VTUXXBcs8gS7LvAC5sfphLSnc6y17KwRsrwiIXbkmYCxDGoliyHWJEqJ
# DATA nK8YLeUzVL+8FrdFaSuBW2qCAyvYmK1AZgfQQt8wkk9GA5iMmrFYOUYpO3piWoxXZU1TC1i9jQdhcCqXPF95azoTEyArfTZBoPC9
# DATA WI19b2X/cn0ptCZnGdbqEQ2zWBevJNnt4HhwycT1mlST6TLjijmpGqAgbrRA7rTsFb/YdyajulOGp8w/g//F4r2ElbKVlttm9Prv
# DATA kKr+JfqY/BzMg7/E4hQsR2ZxbVUEvMAv8VN6zlzp5/zwVwZAh6bEk6fUQ9RXwktapljPghXC2mY2XIHEcF6HJ4cC7YpT9P9gbN2f
# DATA yakhDyxEy7EuiWQFFaToIO2+mI2F/wI9IBcKPnENByZxTkZf+p4TR+vc0OCRJZNIWxUo3ppQQic/R4Rp1VoBpGItKb7EaurUE/Vf
# DATA cHKk7d+ycnVJmvULTPIFopL5SZehlrq+qh/jYwBYbak/SHJHTDwaCHeLfiQXAsG1Qvp12VdQxJKpEAiUvGP5tc/Vq7m150jhCD1J
# DATA gW+SYtvaC9V93mlZCBfa63ZOFf3D0Biutb26veAvvJrByw95DmPPLFCsU1yQ3appWbLDQ8WOQNPYZtcTh4JeC1NBTjZR5K84ynPT
# DATA aYeF6Z0ZB1PdSacPDawgtC2uikVtQa+EQEfztC2qLJubUa1edRd+CMVI++/ZZvYY5YJ1FkFNl5nKhDGjuXIdUlBsU6ddeQVlcA82
# DATA yL5bDXlLo5knAFK9LI2XauztBjOoEvWoIw7T4STLj2s66NT0vu7LM/UKq4C/Viakm1yqOkST2u7FWk93uEocHWx+0+3Aa4EqhKDC
# DATA i/fQfglWVYJ37g+beTblfAC1mDNJkDbPBb5Amz6gT+DHrXD2d3xJJ4iexYln9sESjtmHvjFJAcHPhRxjYtOcw0IL6bdxjyy/TCfL
# DATA g/6BRYBdVkw1XtxV+f8ylyvDMAm69Wfkifr3FB5i4tSNz6mvsVCXdCVp/Fd5eyPB4pcY2y5lls+1E5L673+UgFE4x1o/dx6DMgaI
# DATA zEEf0zfEnJqPOJI9k+q0d7MJJAhUZXj+W6VTg6ww7XUg87kWwgWwGiiTB/0fZb2O2S57vAmqF7TaDusNhlgLbgCR5m9ZU13ekM6Y
# DATA C/tlZV8ON7CdLqq7FNjeVWMEJBaxN/dFFkbwHxYT5VRcnFAzdPe8lOxmRbtcRHC483KTFnyCHxjkBpxs66ltdhDPqwmC8L/TyR/x
# DATA cmlf7lGFiPfBC6gvVMgOZEmuQt0DnACzBX3B/6vvY4GxEH+BqsAvwWVTXwF+Vek0zkf6HnlY/JaxL39GEj35BZbMtZNc69WZPQXz
# DATA 6PeeoaL7wSr2bhKwiGMJMPOWeNupo306AjPrwKqH14jX2XMyKjGXoNlKQJtaToNJpczG3ot3uAfuFncsJU9wsBZYX2z1RxmoSym9
# DATA fOV+Z6WP+ZCbTQp+UISbh72ks3Cp2BvjCozK5J85ewVuf8AC2Ic0vL18/CNn5bhf0ntL9VgcF84lZ4QzNaXFt+X2CBagsfAaxhmg
# DATA AO3GtMi6fEmk18t6T2GD4nfAB7wSZL1SG8sVQqH03hyLYD0SUkv/8NICXMmqbUu3KoaG8RywNNjy/0yqZO/+jqCVGDtZ1Ap8uQjr
# DATA /oLRdF1YG9L1/QLj/AAD/bdWvxwYeWjA/hstBODnjikfSrKl1q6gtzeoNm0gFBKm9wLrKdxPvCC7oqPtZeyu2LSH417avbc3wqIU
# DATA z1sa/7L3En0wpeBUIyfUJlhY59xUxIVq3nWlFl4j13gidAFFW2RJBahNsF5+ZlROlhkghPrGg6PT+EioNKnWJVxBleANYF4wRgFc
# DATA Ux3WTeil7yT5c09OvgcnjwPB+HS++U/G1R/07U5xo9D7HKm71OFpxZ7vuckJc1CX+AXKGxIHU3uvh2bW2nUX1Z7grAW8jLkV4Xk+
# DATA d73rpA2zfYgXv3hzF3wXI9OQdIcml6NeUYhBd4bwmSCNtSBzVMeeo+iGs+rojB33w/P4w+2tzd3O+uajzqOtJ2sbm3CLkAYCMfKn
# DATA a5vrj20x/cbKNaDCplzYIgRHPfQmkbwRIY4GUqdWGwG8rOPQgkeN9aCL+nJWqvtyDfbyWntR7bw7Z0pMe/ZB5+mzDx5vPNRToRtC
# DATA D/BifImLhlflZ7k3JIccMy97rjYL7/BD1LWhTHeavswaAXQv46q5ZPCPAns1sHGE2SO4b7igziYmKVibQuYl2WtL46BnnmwbY2FS
# DATA 7EZRJHJkplLB6NKcXDc4Oh1mPafBkGeXFMvcL+rh5UrqjrJuPxELMifg88pHKXQQ9peucFq+zu16HjhVrYozdeEuNe/KwlF+oiFn
# DATA Shc+XBr8g0tOAa4dWTssdKgIRm0tvX0b8xfqq6CwLqs07Zd1kr2/2O6zv4fmJfyV4Fai70NOalxqqXAX0mSFPG11D9Bhmj2zRZTu
# DATA I2OuFkTLAzskUi4ctbnOC5OqUO2/XkfQRmMGLjuhxODNF1QPGRnbkbQlkTbQSNNUBjqIDk7V4kM6m45i30v67c0tst5Shy2Z2YKH
# DATA ZQsaA53ntIUV67Et4ryFKrBSjxRuuK17fGU/oIKf1+du/rBf3isBpTcxRJ7YHFvbqt6tKM+18b/C7NF2tMiKEbAHIv2DUiCYQ9q+
# DATA caQI7ptNIBW2oqm8yds1h97Jw5DM2baGPFQ2syP2Vd6O6xzzVUplLSFJrPHWOVWlfjKymqeUBY+tEsUeql34UFfZLjSCbp54h21z
# DATA Rz23GWy6egwyihepW9mkIDX0JyZEqhOvQt1HssbeuMGfemQLZ0J68Egv7VoMaei6x2BlGmeQflztnv5LReDwZ1LqThwwaai/HP/U
# DATA hR19fE8k8j7olGFIhMAa6JMifoGpiKPfzO+qIDhTkgyaqVVrlIgDXA71Kxj7Pj3jtkv5dUKRKejg6WlsKPaxY4bkXuEYUK/ikyvK
# DATA CPMqupq4UDZ7oRtZmSAgl3HfxjFzL6s9v+2X/sVtgbFeay/Q/0B4LrVqHerogatr41Y90IlA1O4LvMd7pn/RhP6RLIUB08MyN1Xs
# DATA St26T1cTu+cEd1rrYkg4n78YlaL7N6PHGEhPCJKznLN8E4BKnEfj2YEaUfRs+3FEMGWUvITj4QkWRs3wJMvz5mLaEYpzgKx6k2xA
# DATA STGGTAJ485J7VGmwH382B6WnNOVAmV6Xq/VAhYe9seItkj7KHaHrQrOS1teuP9lc+2Tte+sd0tOoqSNnzpD+A5dFN5I4QCSKMiw4
# DATA orKtziNC7Bbz96U9e/jLaueeYqF9Tx2+0JEKVAOX0tCUtlyAGT2HPkX1k6sC36BtdkmQpRDCkmF5ptISsKUggTUfFelPmJbbD/aL
# DATA /NqrDRkJ+D6ZaHcOjLId+yakMsCAQBvAmCOmw3HWn9gwUxaKCbfg1ZTxQRTnPmM6YCNZTT1g5iCfSzA/mMcNAzzqxGphUlwK1UpC
# DATA 86yHejpRNMHGMXoeTDJTFQUhesGaMvJYBm3OjVMkDHwORnH6YgYZ41WEwb/gbydsKlTMwCQRoj5DFGc57w89/Q5C3wKryrxTjhV9
# DATA dfVqkuu3UcpRekp15jamKMTK7xI/kjwc9uhb9bR5x8Tskshfbuwx+huho0tcuBE2o6HgjRPCoKvFDEXhPpoBsEbSNw+SZp2mGm7h
# DATA /HY/lNonD5Fl3nCFQFlwwh2bENZu1lCHdJLJaNdeNs7Nj4NZf9DjIGF1vUC1CpiDKxBgbtT24kaPcfl4msgFkqpE3yPUgd6gHEQu
# DATA fKk3QQVuWzZbQemNmHjaO6uKTtXZjdm1VXsX11AJ3SoCQlr87qbqRm0PgLSzV1l3Nk0PBhhkvBEHsbTB34qCqXFnmZaaY7XzEsyq
# DATA q9cBNeSNMdkIkUBBZ4BKQO4V9OauI1b4aDZt31pZYQUy5QYQHdwxf667SQAu46EhbfTkoSFDAaPXv4o+3t19utPQYTpvfhp0AbKB
# DATA hF9oDBYC6mXnon9ENQu4If1aHUQECsfLHNMlJe0B2ZLIuOzKXo50RzSJHM336ZYMR2KQ0TxDnVmvAdXSfZn90JMg2CjXp1N2Wx/q
# DATA NRA+3M8Cuyngem1BLBdmkgtaMCTjE0G57F2PzspvzwavxtomJ7TFFZuRhCh2bSKSKgx6mCMIx+Fzig9oRBSd5OCx8nfLBusA88zk
# DATA TZpynZM0gGsuuarmhlwFV5o42hcBC+LiXxQuDMZ115qXqYIAaBAPg1FdLNhpHoCKoHqbsyG6LJ30c7g2dUYvvOqKPiWu8EDV1AU0
# DATA EKMBeZ2wKEF13b8TwrClBDwBmF9xcKTvVGKBf21X50ogbiyLPd9t90QHxCOyrpM4xGRf7cIOKmkXJyyFVnHEwI7mNCkCAJyTpt3V
# DATA Stgbt0cuNolRts2jA0EhwJGnMKwWT6HbhMRr5gEIlSeHvr/IziQK7iVpsYVWFcE/Zh4XiV/ngDKtltd+5P+EziXAdf6Do5r/6k+r
# DATA vcgXsLX4gEoMLxdqiwtUqzJ1A9faPllY1M23kI/BwXnGOL6fzUN6bkYyKbX262EvIUDiN457jlnkygfGkb0uQ1tc5GHsAlvbUB9I
# DATA NiSPkPrZp9jA0ASFbWec9jWLLFhfkM3Zh3XCi6LCDv7NPAuCp+8hic4mOSnJ51S+7DaBE8tUlE7G98nn0K1htOdbJJSc7l3/m+RF
# DATA UksC6R3Z3j9lDfO5nvKWtwL1SM4BR1cghxePk6ZwZVdfqDmVJQEmVZa4KNwkFj/sOuUl3d0NxFdglp3NKhox9/4gU9S9QpmqbqQ8
# DATA m5zBYQhJybVHQ9Vd0xfqMAEoik1B8Y/FIi38YdcCIFxUUyG2NJkzNVb+IsOelLvqroH/slW9XR1GGnXrKWhtXMdZR9zcZzxHKQ6W
# DATA N+1TtFBJqt6TMwsjrhgEvQI5mP6/4quI39qZZINMEV6PWYUGp7Uu2gjpyPAuOlHLZfTB7iY+otFFEGGOtZ/miBbJTKsMF451nCFo
# DATA hVJUPxSf5IcOxoL7mTG/lwPFUU3+SI3Cy5tYv1ywWkqIhQp02c8Si2XZ3Jha0HOCf1xhqtxP326ydF3vbLrmn7MqcbsMUW5BbWRA
# DATA vjBu8G3t69sK3pYZjQ7CbvAGrO/EjvoNM/KgEQH1v1id/ENmLYWcr1o/vJxNu8tYatm6z2OZtJeOp4z/5znWh++HC2obSnNVOcpQ
# DATA k7CKUw7gj5pgTzKy2chOLF0l72oeSb3gKhug2DR2cI0DN9DCehc1QXEyL95e64oK0T+Ls41FdUsFhmalIiPt+SQ3KBeFRB7hf76g
# DATA 5qpQU2eQno1mGMDicPIir1nwQBb4TSlrD15IYFmWFlsKFss/UN+v45+KFIsrq6OqdG+yJsWMoeUL5Zh5S8gxk9usDODDHr1WELTT
# DATA W5AQXqEHA2JgQgpIQslCLkXvBqQH9YJez9Td5Im+lCzimEm+hnVGNnmSjuUdZB4mYmIyvVHiX1TsEzlpLaIP4uuiWbZ9zycypC9y
# DATA 9Kit4pZOlaCJ1Nh2Rl74kgrlt2Vx1wyL02HNwa44eRq8OnUSn/AYaUlFahUn/MTlDupBLV5Ox/1lAD9eJmjOmGzh0Abti2UNIjQG
# DATA yAfyaxfJVJto7OrQ25r3Dvnex2rGB+rduQb67WVpjxGqcWpPRmoiRsN+twYK89WbBNdyegzIzIUC983nrfL015T8D7tE2c3QS0tb
# DATA fu5gHkDFrtTMhbJNi8A2f2Vc4c34N5QI22LVCs4GaoLDHx2MemcuGq/uKWrCapCck3N0wmyV4z972OlQrwAICLylvadbg8NbVXrP
# DATA luRd288fj9TxWQMHIzDs1DFIsgIvmnQvVk2D2jZQkqFl6+cmqw45D+vcoD+FfKO/JaQLiGf9HUbL/RI0cQHB3lsD5kEySXAT7HBV
# DATA aiJCDCd0BCX6TrJiFip0rVKMUZWKIKdQnEfPnm08avpyIadiRX8rRYeo/S6H3t1euZ1UkYXFN1940LWtHU54LtOgO1OhhiGzAlub
# DATA cG5DWfBI5oMsG9duMqMMq07RvhlxJONvvfhkCmPWylJezZ+8/kf19396/SWbQgF3kiBLQmlxi+GSvzaZKTQYP5kt38L8eU3IOfP1
# DATA 6/+rDb/+5Zu/gqBPP3cGjC4O6GiLnK5c7jLW2K9N8OrnY8AIqKWTo9xm/IJfQF85/3Nb66hjT/WMnzXJHoV/OjpffAJaSRsSFKhY
# DATA 9zIOdNxUX12FmTbH2kMbZMEqwPDTIGYuzNbWGiaqoZlDqD2T+2SSIwfVidSba5OjGWyfp/imJuTbdqfTG3U7nUR82QTPwJQ/qcWm
# DATA ZzE4OIzA76O9py1DxjCkYeul9V6b7sVoMOHu4cigY4UaVDdFAL+rI/Jy+ynlHFScXolxPWleDH9rJRWnu06OwHpIqK3ukpLAGkbq
# DATA tPUuGjtTXTlcDhsn1DNbdxnC7gJ1oW9Kcq+sDMPTcrGq2tRdXV9kY8juiXsmpgv4VC2FZ7/ToV5HWaOP4rnFJ4XdGnuGBbYaOInY
# DATA gt0AodIGPcDuR49cLIv/QOm8ljgUYzhywQhr3kEDkqu3MfBDIhmVeN3cZEZk2JkeF4EbcXoCCNzcXiT2aUSNVBA73UkJkNgHf1gG
# DATA VcdP6I7pjoF/0yLwD7568i8bJcYPDBqD/E3BwPhbIhsXEdYxI7A390k5qaMwNE0+JMmQpESQDwkLQSqtw+5wOnBYmGMT9uhtaVpi
# DATA 1BihCxhl6KrFimOrriScofjh9vrars5HvP3ok20/N3GdMiPZZnRi8MMeNiCT5ManMV4NoAVXAMLRNA/hRQ3+U+cnj7cefrez/qkr
# DATA drrcMhAOSrsEJfze7GScS8I/d9NoFQUkK8/BEzvNu/1+m/0pwRw1nLZvJsCA1MJ20HWu08H92unAfut0YuuHmvePhrMTXHD4Mx00
# DATA dzY+2l3fflKP7O+Pnz2VXlr0nP6pUQUmJd+Njrrmo2tff1rTlxNH0CGOKOWSmhRHjYz63eyMRNGAVE7i186ZosIn66/6U2Gv9XDR
# DATA MqqspgWkh+zAjvucW/LEuESHzb3+OyuqmsuIkVsLLhNB9705LnuI0vMTzKsO0u/nGhDkV5hm/QuE3PvGIv87SSc/OlBHZXz2ja/s
# DATA f5Cw/u7t2/iv+p/3761bt9+/q5/x8/ffv3v3G9HKN76G/83AQ1Y1+Y1/nf/75rXlWT5ZPugPl7Phy2h8pljH8NbS9evXt7O0p7Y4
# DATA bg91LV17ukFwRei/jJfVPJoeT0azo+NQzJAq31S1LDFZ16Kr/g2mFDhYcEh7U/1U3Vbxysg/1c3lWN0x9U8gfPrvUb6E/hVw91BF
# DATA NPcA4VIXmZjGFGHRf0Kb+m95g/WeOX11lVPm6azfoz4wjdB9wLuUImzqgqhoaXegBhQZEyJd+Mxtykj4atB89TRpgFn3rxjlyRgS
# DATA q/R76oXMeULeFsjzOKrG+mcvSY/G6nzGGEqqSG8+7fWHzX6eTqdntaJPmDuC+An5PUYinkdVO+mDVzaJj6MhpndKCa/4RH/filzh
# DATA j7vES9/kf2s0bCTLNHIirv3heDbVL830bo62M9IK+5pE0CXod6xQ5KFR+AW96XDxGojoeDlRjHoMGn6Qm07yIzX96jioLV+H5G6q
# DATA jbnzAw2b+tUfP8Dc8/fg4OBxOaToGlTpQESTHczauG972On0h/1pp8M9I33k6IXaCLEDVGL1q3RDNOFl0FfHn5nzO2ufwHNS9Brc
# DATA gAujSbLxaGBuclNeuwmvKSs0/amzQged5Lw5eqaepXYOUMQazaYyFXY9MnXrmuPweNptjeqAmnrbezPQ1ZvvN1fU/1uFwWIGYSgD
# DATA P1qt1fhikR5vZyejKdO6XF9iySGfljaNKDXxzs7H0XQ2hJHBYYASsYyoGRw2cS3xL1xQWkGT1XkZRFV84X7F+xC9vT5tfDianKaT
# DATA XtZrPJ2MwMEusssp36q/4J2dgQuaO5vUYYEJYrjwC7dDC+n3xQEFCdOeP3nsDCoDaghAV8zOr5D+TQuq7G/tBEZhwhgxL+CTOMYI
# DATA RxGpuMyuOzduyHm8cJBGzWK4e4HL7sVrlOzxRxwYDjq1DzJ1Y5sgTbOf+zllfd9S1NWX5iLkj2r+gWb3VvgY6SJMC62JuBLg26TJ
# DATA ZZPwOB5SEuLGLsOpuhP1qnF6eoo59xqmVcIzti0WZ9axTkPCbUWhYVtNIEiwdksAlsBJ/Wh9lw2Iq8kCXqFqoxR32LbYPTA/YKjC
# DATA rQMT2Ib/GLLdNuTbQQApqv3xlif2Nd0mkSFoM9DteXYgN9u1a4W5dVPbYIQppswSA9ivXFESPYj8b+cZSHziBSKc7g3kIFV3r8lR
# DATA VuLUxGzZSe5IPQm5zF7KLmJ8pkiCCBo0qgxj7nGSNXr7y6sZaNztm9+uR3dWbsJ/bsF/bl9gMb1h70c3w01L64WiIfqDpHT1C4Ha
# DATA 8xYGN3N0mPYHWa+FHCPSzqJ2EImM1QosRC1olqlHu7R5Q0aaisn7vc+K+mSYoZKSJ+YeWMrAR+BEFe1GT7d2dmFXoHedH8QGnVO3
# DATA u5MxhdRY+0MxV3MNg8cP1UafOgnddMr13rSpbywIRedVXYcC8OxHqvXmbNoNaW9KK+vnI0pwSpU1da75+PvAet9bWWmtrHgO9lRX
# DATA c/ojUL6Hw5RMc1xW10rftIMddnKyN9Ncl6j5pZu2z4ntL3dVdfr7wpQ2fJlNlByag79s/sNZ2gOZbjRNKfkjoGOk/SGp2o0bLdz8
# DATA HBbPuR2hFjIaa3FUoCvwXWaiZnU2GCA4dW0S7601vp82frTS+HansX9+q37r7kVMybTnyvDPtMjbG2XErA/7U5TeexbnO6J58Dbm
# DATA JFMfYnCNyPnaOUnHKKDQnQgElLWHuxvfW0fNurp5qbsT+MnEjzZ21j54vP4I5bD+ibpP4uPHG082dulp9moM5hN4uv7p041tejoa
# DATA do4pe5CtwuTzsXPHHhsGPN/2bu6MDF8MR6dDrReIdE1LhERxAoCEqp0eJk6mRWdvJMWNO1iAYMdWkrpXAj7rTCfp4WG/q8vIZV2J
# DATA 7repCfjj2ysr769++9s379x+//bKt7+9qm8tWAp7ECg0b3QbQ/TyjLgXau/O4Aabm0UEf9qjM5TNAiPrwO6ddnQxGkQ8HNHzOGnO
# DATA xmMlC1tILF2fuaFsbnW213cU9VVr+WjtM/jnk/X178K/T7Y2dz+GPz5bX9uWl5WyhcpVa6MJ+CRj85HtFrnJpBM4dBgwv1/oEXAB
# DATA bEhaK83obT/vmXo0mjd+Fh1k3RFE45uC8hhw7iLacXswk3t6S+7vy91qH2OHzO62Onm/8a3Nzsdbjx9B/Wd5pM/APTR0vaTjCnyt
# DATA x4pcc4ODPEzZqaUjlkCREdnQKMrJCKstoTS+n01GioGmwzyCsFA8sIylIUlFM1p/dZzOcnQU73Yp7cKJ+h1RAxEf8KZzwYXN/KDt
# DATA N2oOnJrNVd9dhOcZ95SlMJp8XIQDiXBhTKEKP2VqtkHnzLk/6S1yTe4Rz8XKX7JtPbc06RGmxtYf37PIMdHhbDrDpRqCGSqP0M/U
# DATA 6pXk9Tq0Va3RCrpdsYee5eCYQ0lblEAT/Ugt7j0lL0/VtZ66eJKeRarVIfGCdICgB1E+BoFf0470CL0vlxxWfG7ZVoudg/UW1ymu
# DATA DW1fgwuslTPoPNCrmPJOWBrEj7UB4qYido3Vm41bq7s3b7XufFv93/cLGBIx9/QxrOYHECap2mMS7rzb0YSjZSYWnASQhW0AfRym
# DATA gx3g64gFBOIqZs0DP6Ya8vskKaBcxcJyBS7HZiSKFDIwZRziXKR97nXSaVwQ0/b02zV0aizMnfhW5PLqI2aIbYGfxTJbyEwQ0zZ4
# DATA hNe4VBI11Jq+HEAEJM7a6AdkFM+P097oFCIkczEMW81lyPcYNDvd0aAlzgKLXKh1ZUQe0j7LdOL8nZK6MLlIXcfYQtxhzfaaDPv4
# DATA 85laONA71cRQtKbPDvCpfoIl5VC94nlui7qoCrpvmvXxfPrxG959QSu8ufSeroXc3GiUiZ9nIBBZWK3RNn2zakhX5Shyc9lZc1vQ
# DATA PXVPA11DZAgI9/FbKNuo2z6VgF+3bi7S56e6r0Yf64iqUkzlABb1J4qqk4xTsbmkk48SDRFOUcFUUFiqcM82R1FxC0vNrswfIqR+
# DATA B/mlXKttZVnh99NR7zXxSJoIVynUqRoGT/2511jd9/dJ5bVh9W797m24N6jmkkUWRsYZkxpX6/vSKD8GMxHsCNIZD7KjtHsWcA7l
# DATA CSwuT4xV4L7D4MjZQfH6VjeczbiUYbYevomBbWbYy3o8mm9GD83SREooUptliipK7agVZS/VGE6PM6r/BDU3yIFTAIECLyCQYPhC
# DATA jvdHokT9bNBDKdO5stmDUyQrLuVAaqpHa/llPcTAyjjXviGKDEFNvXJIEr/R80JWBL3NwM0QpBr9FvGw/fs2Tj5eWg24c5B9A3/C
# DATA 2uxrU68sUjDb2brV5PSPhsiOznM1s7QTXNVG7uQizMltAyG7zOEJMnFE57yQGwo4nu1h8KN9JFq6WzbuRpOfDjRaS8d95+qtyaR6
# DATA rrW6NdQ+QWAdBBigmXn54Kyh9w6GIzg0AUQyEyeVHmZgGLNmAgl0Yk2f0gfdWEmLed2FLkkti9qDHeIxNA6RXPMAjpYOMclRz4zy
# DATA Ith30LIDKXjJlgFzaXn06PAwz4SafKUerZIXhFupBtiaO1ffoRrbWnNIPxFQ6I9QuDNvqHqXsaGMGwa9wVeEmrkX4y83S5vzAjc3
# DATA flGMAYCCVoWDqDSQ5mExqorTz84HGoZUXebQEI0rdI+0gfphGiF6X6Tu3f1RL/ZC6MCrluFH97g3+8WQzKLKKSHMNN9MVN7vRzMy
# DATA lmQsilHTGMWXI44Z9MHkjfPiD7MhuE/WQv1I7tFc6LsL/Ej8TIpYAkOIcUncPh8oofiFzwqdCYFuimoehGopU6dorz89bFojy/lF
# DATA vdcK3QtXuo5V8B0UlN4ZGKdYp4Fe7A7ENvs3NahlHb5/zoNr6dPKG7dFfbhwKAYW0bhos6Hny45xaeQGOZuOZ9OyfHZl9mTyhjFd
# DATA Rm0ArMEB2JJVPQcj8KaB2uKSRMVO44qujQYvteHPlGU8CZmfvB6hj7MGrqpHPthE/1B8LweFvrXDs5p4q3gB1J8solJV41I3+Ajs
# DATA BGdwkXEmQAeN5c3usepQTRBZ0TXeTm3wlaDx05OO8XaQkq8o5nAksL8LdxsCmn34bGe3s/Z0o7O79d31TSCu2zpxI/pAkXk4MgnZ
# DATA tIq47VT1ZG37+x+sbXae7axvb649QfWL1pmmPSU8qRqMS49IRmfE+HB1T9d2dj7Z2n4kq9OfQJ/E5BinAv5pWAZIaIZnYF+Wsag5
# DATA Fqye0H/KO13LtHbBVnnkryATQOh2hyoivoBX/xzjZq0CLMi4+ixKNOgTgLKw7Hkv7nuShryMwDa08k+7rX2a6YsOVmgFH6o/ma8G
# DATA ps+pvL1R4XmBenoyy6dl+mqsrpig791iE2P/kPV28v6PBLBanSyVOQsLe1Zk1WwK26gIXhynZ2CorUvVrmt9CUwOP7T6Tu0trO9k
# DATA 6m4B1zLf6kvREe7qkownHtR1n4Tsv18AUDaVSflLw67pS4suZKpMFua9ghLgVBLsF1n6e/3DwwxhvuhGcA8bHak5A16iJF6PG6Nb
# DATA uUlezV3BY8FzH+vJVw/1nzKcpBUcrsCp1nZcdxhu6J12ca5H4MBR6u2M1eGmsl32DrgvUFDmbEyhFM3zjXZ7qHWP2obCJJqmNb4o
# DATA ZdASOdmyZToRMfUeJg3/UE9wo2Kuxpa/cy+0Ug/sSocsKLSicytkXIB0mPbO1EN1g8WYytnedb0g1ynB0UyjKkBxrdul9BRdJZ7Q
# DATA p3M+A0WdYtvTnJun7icXsewiKm/QK5DJBqXDUFW0jOHf5q4xPJnqmkfDnk4y1YOj46mxm0uOqO7rJDw3o220fER2GdzAld7krKOE
# DATA Hj8GIX6kVk89N4FwZJgnMlg8Om5ouwkqOVOEFcZMTp3xQ+lajMb86bE6JNC17+BOj9QHwObQvnAGCmu/Ww9hgw7KxwsxVKIzLH2A
# DATA Yp61w6DC3kelKC+4fkDTiL9sOhhEhuB1lxc1JAZgA6W8Qkwm9u9pM3aALJbTdYt0WE1rrUttAMUweKkrdbfyJKgS4YEOq6XIhWqY
# DATA lrl7M9zaN6M165sE9hUl/w5Git2yjikyWCTkgY6OxIDTMez2AQYacbKjAyWg9gZndAdsBhtyQpLfforD06yvvZp78esq5lV+lB/y
# DATA eEmbDeG+fdjfkwzO39ic8+nIzkcwnh22urGC2PTLxTGhWvoSXddV2zNTWXnIZW4+69a3fcWGupkdNpIdza8deKXQ3ithknoAfMb3
# DATA g+ySZeEAexTcO8DgWBnKLI6aKuWGOx+v3bxzd+fZkx30a6HUVhwG0cyPU/WyNvaQTY+zV73+ERxPVPNEyDzGlBdR/X4+jMkchBIw
# DATA 6uPFze1oMDqoxTeY9CeJy0OJIveYi/E0XectdH0fWJ3kjLKQeU7FtFubU4YeQgHLdfy1mMvo0gnqrMn8dS8S0416pRybnqnHYH1n
# DATA 0Yv5lJL86JiOenio4mD09ZUCr4thvCgPgUNt7Ec/3wsUF2Qn+E1JK+5VaqGWSHOwaAN4dWnA1UXHc6PnnJq0VE17e1Xd0EONoJRW
# DATA jIiWvl9ad2grE6/LuqPEkwbhkYVCmUM9OUMzQWngc/EDfRNq8E2o6msdyByMYYadtopacvcOCI/urKwI+UHHI9vJbkWr//0n/8sd
# DATA 8AOk+6axKQbudCZVCQeSzg3onBdnecm7iAjGRPfhP97Z2nyE8MulVxUiOFe7cZinhshg2gaSKlG+BL0Neek1hZlLEABsXknDgOyp
# DATA qmhzOJRqNimPHV1dMMTyX/T//NQYX3/85/u3VlZuuvGfq6urt279If7z9xv/uXU6jEZDJUxPEcSol0VHs3TSi9BecS96kWVjjHKC
# DATA A6Z4CKIIoF/KmfWBeqkOJBQPRoLiDY/TSokQTn5CSAQmLlMdxeFI/+iPOenc20eGHg+yV/bHbNofmF/T1MR62hwvJo40OxkDqVha
# DATA 2gUXw0in+QM9McG94WzFS9tbW7taU09goaZcA5HjDBxHsvRo/cO1Z493O1ufbK5vd/jLeHk0ntqP4qVnmxtejTkSpR7/W9ZAUyM/
# DATA JUsPtzZ3t7ced55ubwF4nlvb7PB0WWZ4a/b8GmGJJiPo8c7G7vpVa8lJYH+y9mkHPu988Nnu+g54M9oIF/MSnivZF8fe2V3/FCcm
# DATA jveeDfvT/aVHQgyz2nrcs6yGwsVYWoO7ZHuYTU9HkxfA2JvsytMDKPuJnqClD9Cjqn2ihJA+Wp653NIeJ8bbXwJm11Y3PcjptrT+
# DATA KuvugL9g2xwmPkhR1YovY68U0dUQqEvkC4ndBBbTVsLK0t4GAbjuL32SApP64CzQMTUXei3WP9z4FGZnz87EJswEBinuP4csqwPI
# DATA KqEfKS54AEvxfCilWcI26NEkmhKw9fN2LIxhN0DEcBMlYfSVg6ZJTgRuIif6Dnk0h2rBqecquukYfD07JJvSw4o8mdQ6/lfmadLS
# DATA PC+4EwViXDINLWn2xx2nJKaC6nen0j5jQy/gBtp/NcgQ0WUlQmhtfNHPO7g+3TSfuo9nmGsSbxr+rUZi2a1FXKzLobEbT6EeNX/D
# DATA bCpdcmLHTEmp36GtxCSXU0sKRj9ViRpMfowgL2rWDyb9nrow1iOMFcWn7RUTik4wkXoq8DfLxvA1WpTwEgmeDKbSJPpxdH7z5oVj
# DATA 2uU3D6K7t7XNEK4MtXGild99Sp9pROMx/OfunTu37tg7K9VSNWNa5wzsCEu7FmYeLnRk9ea3dE+qfb6aLfD6qq/eAaevA0rNewC9
# DATA 0ZUt0p9HSFb4E+2ZmZ70B+iZ3B/fxaDKuBWTF4LFzuyPY9fOeRif04cXUQ77NTrH4hfgRg6hrizGk2t5O6rF/f4hKgDOURsA1yvS
# DATA JchIUTEqsaR6gJSFKjJNoEzOL3V+cOPnBKtqN1NoeTEwwxYx67zIPBKdEq4DTJBwYqbdcdTDKs9t9abXiB9gW5X95nNzqGgn+WD0
# DATA 4XydIz+/iM7Pl8BXR9VzQtCt6gmOE4t1mFXciw4HqbrzMdG5F11cLEWYFpyvH1ANfaakBdBkHo9G+mqibh2jCbjZNVZX1FUVDP1n
# DATA 3O976iu9hNcHo+v8WD3tTg2eNE1ObzIaq+fntFdANy1m5Dw6t2t/ko7hilXnE5VcqN7aiu1X/9aO2bw95ym/kF3I0Hmlnx9nvbpO
# DATA 59vVxnwKrwBx0FRykk3TaHAbvUEV4X15t9Hvnqgzrv7z8i7NkurxsNcYZv2j44PRpJHDpIBHunyY9sCmic8matIz/QSGow6VmuIx
# DATA uYfcvHPnso07epfhJEvVYmKewXEK2W4a09GocdA/IjbT0P4nmEtarRX0RTWgPjhx5pbWyO6NQwrML9kd+u2c/bHATrjySp0zLbmQ
# DATA nVf/B3KGgXbsgt7VqMmYOQATWGLvbR26WYAoiRWl7ighdHP94e7G1ibF8LF/rkO6bSXowHSbIGjMQ/DjVZy11z+CD4U6ATqDXlOg
# DATA VnDLh7ClgA4isjA44inhJEY5LgdBTnE4Ssm5Cz2c9tSGo45C+XCCaoen4Il63nsvxkTHwcSZTmehkJ6JPdPbAhJredZJx2OQbR2a
# DATA bNtYL/TMwKGS7Eu5RpHlY9Aho/nTtsTwxElfrXabeRm8/KE3IXbl+tK1VtrJJDhxaduckhugGlRFug1v4igrWM42NtpUW5zVSYZu
# DATA WD83nAGt2efPDcx9k28A3I0mFW+yt5+Xwcn7nx7GCjIbMvltok0PdW08Y8x6DiaIfUilNnrx/l5r9aZeZS3JETMmKm2kNSPUUd5r
# DATA ZFlqFgdGFhFOGTi5w8MpxY8ShAd+QPObwQPkc1pyd0VcXVOTOoTB85jIpazaPHYrEh/6/H2bwJK0bSsdkpyASx6puqk6fUbTYZ5q
# DATA GlI7jHsZehMW2fVzgqkPdRzFc+b7INLglBkNqR5Oo4v/PcT/xnyJEe0nxS8qynJGP2Cjp/1hb3RaAxgJ/tt43K8hE+mZUateUkRP
# DATA dzCCIDj0uFejeqh428EIJSnQxQAmS8QnPupOUkXU86a5nVxt5YMLVlXdQit+tVUXJ0FN0uYoGp2Cpztpn/rgyIX3YbCBqhsjeWrp
# DATA K3Wu+F0f4EEBg7JyUnKcCm9KYiP5xIvND3oL2aUNRQSIMNFn46NJimcpohROPCZ0IABHMQ2ARIccnYSmOe3YSKeNa0rw5rLdWHNR
# DATA KCGbTESO5kLEvbRo+1ygvFC9ai1A8IIeunWThFshU8q6kuLpopOOke50KOYsVoxy7rcQfOAiDpO14ELJRtUsXa1FniP4c/XOCfVB
# DATA UwEJrc16Bfa0BXhR40eM0UpVrsPyYrSdHc4IOyXi8vp22aujanI0SdFBWKspmycvQDU4BstvG5siV2CEXDjsv2rHTdyLjRDEuId8
# DATA etiziKdQt4d4Cq3RmEnfYt4an17TQZoJp4RBqbBlLLw4YqYNzpwTOMop0IuTeZrvfHkh1wl7bQmdlBYQcTm7pb0qIvAeGoOuoNS0
# DATA y/p134xVD0FDg5rs5ulxX8mgsXrmImSoB6U5t2nQBX9v/Zy2TeE1BwZ6RdAlPPA10LEaCHadmRrDNbweKEksU7/mlMeI/D+KVkYr
# DATA N29Wzc+zIYQCRc8+/CQS66XrlaGH1JBOBSvMoOq6yEBcuhB1wyf/8LS509nY2V7/qKa/0n3F0ciHJQP2vyuO8S3GSUf8q9YJo5RN
# DATA och2ytBTBRS7lHjXn27yeHSmF2bAWMVXb3q5ecvqqOkgaNf/yr2LqW/ybgr6R5wQFAbjvZXGt0HTd+diWXGr5+BKQHUllRQYZpx7
# DATA gvk7ZsMTnh1yVMpDhNTRRXmwCMQlqEZNldkJVJKP96KY+5n4ub5q6lgTej8woNlYZ6sLrXn515CEZYGv0EfMTnoYyM5WK9LOW86+
# DATA aFscqo+rzkR8kfwUTgeLnas8/V/BCEpHEfaK8zYE78l3tOYyRwcb80x+Z7IWsKXgSjzQmAfBp+hk9DJzkJyuyqEYKbxlicHlTBWs
# DATA 9Cx44whDhfp182sxVCAF5WnyLRb//+PAZqAOVzK8wqynuhN19JpWUfx/aUzaf4fs6wFwr0uw7/AkzWOqwmtLsTgEe3O0j899jv+Q
# DATA mnnuMn1u3GX3T3Ep2ARVAz6ZNg7XGh82W8v77yWa8dcsA619p1W3v5LvJD5H9VcFezl3joqTU8lx/Z2kqQM2BhpVF0cP6BOJEPaj
# DATA a22mLXDnJgoCthP0dKRqbu5rNIk6eM3iF97pX3w0B9lgBOFa05HqyGh6jOFeqOOQIWaK5oIIF17P2ELqqqu4CTwLkF+Hcdyo7QUY
# DATA 276YGRS/9iBDrGV24F4TW1SZeDpCXjg8iw0rUv9NBMovejfIgzuX+eIwmBfxKNyU2nO4u8dpGQ5AB7t+ZYzXjNsZh9lZYZmQxleQ
# DATA TuZJV8XqS6ZqrvThYoegJ4q8YZtzga5ehVPSWrp0j7w5Poz3ztXMXVyWKLER3NxB0NJdYuwMSs4LLqTdjAvlRdPb3RO3ArPMEtgg
# DATA S4ezcWeMyZkJwVg76DtnF95pLysn9RwF7ZMCKT3IR4OZml4Cwmk22buAdD7TvIJpH2qGxD3Cr1owzdPjC4Es1VUbAZNhI5TUjQnE
# DATA 3uQZpcNjiQEMF/BzvyJgFbFL27a25sBj3jzPkPJ2czT9EDwMAyFEBZgoBsBDfv9487s1aMfw+jkEujAFLGSpWTD9vJBwUChjmYB8
# DATA OzN4OkBvNrGLKXtoesXCxkrIyuR03YgbOja2VmwNo+lklyi8zqnEzM33dj9NknCzfhWODPVoY9ud03AlhPvhVVQrSGNOTTBd+gFS
# DATA KRjZqnzKwpXrNZgkl15X5LxycUIrzMcVptY7qwjmTWeVYFW8DjkHtnDAA3wgnMUKG+AcVVubjz/zs1TZ35sfQE4phz5VnBsfSLsq
# DATA udXkIKTr5cML3+CpRc4C/xmOakm1/F264uIoRMGdv+juCGBlLrYjPGIn0PiN5F0j3xIHt529FaBosnDzD+VONHDsXg94ofBq0cMY
# DATA CnVbnh42vmUBlnlzdY/7g96ENw3vv0rOYlmy5CBFcYy7wJ4DuhnrS6D3To7HZ0LtY4yH4t8OUhzwDniIQFuFt9LtgxtJAPjU+ACX
# DATA hQ06s7qrJlJdDM6cZc0D62oGozkq9qzpJjMtTCJ+IWeRvuKr9uEIZGR9Mc+ZeQfanGQGRgB/O4utS/jigRJkfCRz1FIwaGCJZYGw
# DATA rS5jVDDc35oVnLxBbrfQKFkLbThwYA9vOD5TDjFFd/dlwnfLdLjk6t1b37pt4Wjgs4K479My6Nw47U9yTBefh+DchXMIg8LVNQbY
# DATA EH0zituS4eGoigV2osB8IisvOWIhHoKvfSVQP4CUcwAXC5B+BkM5cxN9k//06AByDHVw6B1wJGvjn84Rl/BwU8yiixBxi+wKMQrf
# DATA 8Vg94k2BpnoS/Wvw96QDGQntfkV7uXle1SwJ+gM1DLUT2eM5jxoN/JoSyjJU0CmlnwFNubP98FCLTjStZFzYlRY3KXEm2dvkS0K8
# DATA dIwNtGnRmwhb3Mb+oRIJfhY2q+uCqlUUWIvObbufGBS9ado97jDusRgRqmdhza8yv9tUHddeOcPFvcPtood8Eja2xHvkSb2/Z1E0
# DATA V+p3b17Efrertx0PW3/jLfo7WHBSrnQRl4GqXSZDf6z+4FZpT6BIBNHAUBgju1XXmvlxXJTmjM7OIXFUg0PVWFR7Nuyb+MgCqIVe
# DATA Ku6ADkjttaQOjJKzlGJulOlKRCl0aFRdpqLSyRFivRSrymVksO4E6aQW76DuUA34PFaPx+RWxC6Y+V7rJuIH7sVebNpBmh8/H7Lv
# DATA TtTIZs+HiE7n0FLYiFQNqOgQwxvkE4DIzrpRbDarKQPjohKgGUgCKXlpLMGJBVAKuNW0TX17d1oaW9bZEIiMhRYJiDhj5SF/bqtW
# DATA r4iWUSH4ry4Eioy8/4oDZMazYXc6I5iK7nE6ydvxvT/68f0HtST2agMTyzTLx+AziK2q6qEOrxS0kmGyA4yscm6q4DJVw2IM04dD
# DATA YTuJf+q5G/vg8Iol57lPuiiT6gNn2b7JeL7/BrUYhGkGv/+983vR+qHDownIXCnkJYQB3Ye0SqjU0M9MxRQfweC9/Cz3b5ql28Tb
# DATA KnzQLYm75E5jH0Dic4ZOqWvDIF/ml3hS+G9LuqnbeKra6lTx+zqTLwdgwTZnXAb2Yj+kDf3MNmKk/TVNCmeHpx0dzYYoUibnu+ku
# DATA PQXXLL8Hfk/RIkcmeqQE9Pfl5gvkH0oGhxH8DfjNoB26z/BvA667QMKpd+qITUuLolcmltXguDpxQWhaaVDDXgazKEZEV6bjPjrM
# DATA wdv7+JY3V8uFY8X5wGL7sANpUKTSgU/fA1uk/Bzfyc+gCK47frrn1OhDnVL5dnSzQjluxqxvL06NSbjCVb3AFcwQ1pkYT7XDsMdq
# DATA PAxYEmYcNFDdTJibGE5C7AEcLpD0ogrZDDZhHBUHg5KZ8xY6p07cblE/1HOMRDYZ5U8nMGsTXCXNF3FhCpd5PDFaRJcSXzrukydI
# DATA 66sTfqcTiHXpdWzlIeHWnFqndNBaUShVlIt9lGu1YB/NKAjGCBOmcUB3RoYjknqYiotB1GEcbUiIQsDrR8GGAKCcBX0jHPuh2Bop
# DATA jRfF3AjwGPrzEry1Xrkr6RBQ4zA6CvEt8LKuOxSz7eQpuhboFE+ZFyCjl3bPLV5AxpeCP7mFIGCzBgY2UZ7Gd8LRWIwTcsH33CT0
# DATA 18I1A1bPVjjPkiqSNcE8R84YHNWcXB4HYLJGTVGqO11IZ6QwvUSVdaAgaCoLeuc5W1ivlAUVJcN9cBBlYwjlesNmSTZkkkRbiZcC
# DATA YCeVcCOPELR7z3ZoROhq8VKwzlqo0rjy+CP3KBHM3O1u+sjAP3yWxSHCbtKJvyTd+b3NW+kWkEtscmAin6CLd95VMolWtCwVexme
# DATA OpcyIXDHPbDVMtkAh4nhyNtennqRrLG55jrC61CHzJ+MXgJsjtH8ElaXeMBBuQ6flxARdXCK0RffMWFftl0Fp2A22APoKzDeJHEU
# DATA Ly5Qv+2r0dD0p1nppjBtwxajPrcjCZ/AWTe5mLQdF8QhnBItDXmDrc1zEEySSlmLIwM5LxX7erPTiNhRZjhapoDvlnUG2l5fIOnG
# DATA RRVWcYa0f4q3kB5oiFhLLd7xd6UeCw7X0bF3Ykdi5gkP09h14vE1ZC7aJE1Dx/a/Fpf4P5V4GsRzL5KH8SW8EebWVvRWcGL/knJ/
# DATA X3CgMSzJDLhdmIQQWqO3ZwvrWiu4+rAvR8jTp8whKUkWwn309vhDzzVK7HLNCmi2l/G7yk1uVOc0Xo29mPt0b5AOS2meJop1QesW
# DATA IJhLOhLGT68o1MYFUZAbKjTpGFaMlQ8EWzamTEbjPuqWAB2nCXoTxHqr4U8NA9nsydRgYJdWQk6hVq5LuliGHQshiPys4XgFNsAr
# DATA sAnQxzH5fjRd9E/p9BdxJ4yP6jyXDvB90x585R4lDOXiw7rwn7X+2OaqbSAuAqFaqB9o+BkTN+mPCy4oIbVNme+JrQ1lTN0P8JGB
# DATA 2IxrEMYOJusx/IlaBiohEuk2KZgvmTctuApqtGw7O+RlOe+PL5oQ07ZUTEfukHQsXo9ur3z7rhyy4cyHsUE8ej40KEdPRzkjHWGE
# DATA vGooahxWIx25/ZKEtoiH4k+Yomp3PVwU7ZQFJH5SEYVY+04LAxF/zJAKSeTDqNigELXqF1GRAUwkwsjt27c4fDFihWl0fdJtdFNV
# DATA hRquV1tDFb/uUG4wyCna/DKd9FNcjdrcEEq1TbirPC8XkdufKp51GBsECExexfZdSmtbORK1UsXuY+7fjt1LcIr0fYm3u37pX7Uc
# DATA 8hGrdYk5FBtoU3K+WkfDkE4x7zdpJyywOQgUAijEvOPk9LDd9pbDSQYmm3UPoT8JjjK9H/QQwvMluTN2xKmoGESZNyG6WTHFPaoE
# DATA j1Axe0JFTwMMFpxeTtIJ8FHwRCb6gdwe+YLZYy3YWb4aIj9Wk9yl2O2DzEBRx5cQYg+VuABNEm+sMhRRf9Q21IGNw36BfAGD830E
# DATA qBzxQkSKE+4nOKvcE3ifiJyw8FlQcPVFFICci3zhpMwQd5wNxo6h0nF1sBpz3XsuX3ZxqdF710ISRHB8PvwKIByBGEDhwi67Xg2C
# DATA qDqD6msaXLCCS8AkOrUloYPDS1UyzQvetqizC6xxsE3hxeJIo6VC3tLSv/WQL6WQOhh1TUg4I1AedofTARlu1csOuxrq9uFZXHTJ
# DATA MUVNlqSi06Epw56HD7fX13a1o+H2o0+25zkhgpr8rlaTu87untOgbf/37THoum9e1nUQpgywzfXMST8zXKfmIa6g9Kuk5zBfnfVP
# DATA bfEzcBAKR7tDAD3YoJxpCytxOuR2r13sc9dDRD8Nmv6uEJ9XDvHBUST64Iio2byFLfUhkMcQGe+KUtdSUajHlZGZN+BDKXepq4YJ
# DATA e6ApUxSfgmxqIftKm7I1BgASL+Vlo308q9xrrmy3WarQbwttjtSuGfPRUuGVf329jAvUJVSubDbbHEmHsqKatShm3LMu+S/6itgW
# DATA vegctJVOvfryDrd+f42T4qSVnSffR+eeBtnbKwxtVFQrmyHATqW+7SdBOzZ+XLeJahY3EPqbtecb0GUqCt/boFo3Yt1+Q/xp3uap
# DATA 3kAVe6RqIiv3wltOYvlElk9moBdlrN/flSXz7YbN5TYso0ipF0Zguhp55p6geqksem9YiwmNujsdIGXu5xqFqqEEOlQuzsepFsKZ
# DATA AD2L46scVKn3AqfXJug2X2RneU1yyBDHKA0eDAwzVc0PG+peBQmf3MZtIIzqQW2erq7udSiYp8nmcZmcoBptKZB+iTEDS3LfyKxi
# DATA TURZ1zf6Gv5qrm9urW/u1iPza3f9ydPdz8yD9U83dnarEhqVk0o6AJ7ljRZQkXuKhDXOE4SCZVI26IReLgVl4DVA/9LRo5KF1w3a
# DATA AenoiQHYky9hqyvQBdR8gZxdiMFH6d8BJqm0AFDxQig+CrPeKynTzgEmIcmU5tJPq4q1UipYm+3VSwRr/Dtf9kezvBNwNw9ecmRU
# DATA OipVw6XM5KBC79xAhdpFwUB32XiZoUiYnPhL7X6BdTuvrLMMrnNJG9a7BQFJI+1WQt84tYOiqSCreX40Lto2JBczmKlLWoOJMJwO
# DATA Tnc5Rre7Mm8J8wgEDq0ThVtyPQqGYgCF2i9YELAaN667HMhsgR0rsA9GGJpzTjGoWKuPJiTjlSxQULF/2l+P8vVY82ABUcSPzHb2
# DATA kK8v8GsLA6k4VfgR0IG5x03V6cA8dDruqSr52Fklge99zmbSljHf5fkxnZ+W3mXCxt6KJPiZe95a7jDUa3tUWuKMXBQ6SSo6o4y7
# DATA Cu8slsyGepNfVYQg3FTpmBsI5C6wXG/NBbst3NXda6zRiiPwYxMjjEJwQ7zlKhM2LiydVFteRRi+7KIvwcpJ05SHEXlJGuVHZYCr
# DATA vrpaDX8PKUn5ACuFx3kLHqB0i+64kk8lVpKTFw5TwF0pORy+9xKNEXSskx0NxRgaNO47Hr/iIAhVoPUXMR/HXoPOO+pBwP+0wV6p
# DATA 9B3wmLgu3J7ND1QqYVxFfyoaMThO+xXdbnCjlUWQsDTG5MlTTBq3Uvmxuov5n0Jit3Dh/hCV2IUPqhooKGTKBupEIOlUb1Q2lO8N
# DATA M7Np9OK2WYLiNRy5P2XdJkK9d/MmpgDnXNxCAigL73GgikCGbJXnLYu3WZrx8ogEuiy3lYQVJ8lYBvvhl0IWciWCAkoIu/Bbkbo4
# DATA JL8v3p6WkfNOfJzXE5PPnELOFmgMrj7u6eJD53rnF5cXC5GPqNsHxy+YvqvUkc3TnszXoLwTLUpAh6F3ftORpUtE6KIndvKW7mDu
# DATA 3DHm0t7Kvpcu0PFSRohJbAl50oqp0CqAw1tGt1M8hQvuWI+MWtyOyptRGJnVt/kAevhh/xWEHqgeN2hRBdTGyxFA/INabhltlRPF
# DATA xvMo7U5GuUXQnljc8MJ99mu4Y+pmL30DvnLfYD6Epcsxli1q7XKsWx5uBlRUBo4s7UAMexS2AAV2EkkCYWfKPQpcB2HThLDXQhuY
# DATA eaPGIT7Uxa3RAKIp7WXIHDrUpkj+5J0Hc2ctZQJoYp9zPMIk8FJqB59AmkTzglpVBmubW70/EnG1xyAHhw6xvqySjLUWoaza6/HK
# DATA 6fhkZdV2PDFLUFDi8JajoXo3XNcZtx4OJqnAJAuWtw6Tl7vt4vNkzpZDAdfbaAL9u5TOa/eLBQn3u9vEpZpfezD9VagcxHz0srK5
# DATA KffLX0DzW3L+6Vbzrg/+PLVbiUaAxPDCnvYAZDE0AIsYZcp+kgh1Xfk8VexNFDnLLmbexpJZRQp8wlSxQNZnTvT8jT/871/x/9BL
# DATA C875V5T7eW7+59WV1fdX73j5n1duvn/nD/mfv47/+UmZ9e98ern8zF1QteTBbM3HaQ6JmM3P6cngknmb69HT2SR7CvgXJWmcs64S
# DATA p/Jg6uYz83imrheKLD5c2117vPVR5+na7sda1LIKd2uSjc3Z6CjRKx2MjsiHEFzFdB06Z/FNTlgs8xY/Wdvc+HB9Z9cmNgZHVXwF
# DATA JtTHa/T0Lj3CyDGd6vju7WJaZEiGIGpHs+vG5kfmG/XefaE/vHs70DlT6tH6U5yGby3t7KoedTbXnqAjZ9OkMyGGu/THW8+2N9ce
# DATA Bwo0RO4rLoyXmkBV5Ja4vf5wfePprilgazpIuy9mY65k6/Gjzs7usw8Akya+f603wk2GG+jBffhvNEiHR+3r2fD6g/uY3hGhULJp
# DATA +zpC5KmnGOT1gGMY7i/Tz/tj/QQuP9bD9f7y+MH9ZaweIhQ2Hq1v7m58uLG+TeEv3dHJuA+SAkIbaVwjhDW6/f7F8++rrfHx+qeB
# DATA soeIiX33NpXZ3fru+mZpqVs3qdT6p7vrmzsbW5s7CGLRhF5hxEo3zymjJ/2TvzzCf6evpvwYBeO4+YrLn2YH6qj2D5WwFV+o3d8d
# DATA pHke7ajJpguzvTsbvXauQ6Q6RRg1H0JtLnxaNXQaKydNb+JHz54+3ngIG/GPd7Y2O99d/8yx4YSB0lyQNO47zAQhMraCtj2hLyL8
# DATA tIOzacENhIHqgvCLXvjWAnhsHQHIpjM6SuQnvtDAyB9l4ul21p1huAOtU8CTozCPG5vfW3u88QhnUd1tkbLiN3p6kMR5aIJesL/N
# DATA gp04uQ8gRp8xB9Wv1W+huiZ+/hzDnvBFRceebe6sfbjeWdvZWd9FEhwnDraxJPQygxRcv8IQx3BpJ8zJaxrtUCMTGNBjgCe44wMF
# DATA zc0CvS8TQuNB/zbmg4Yqg7BG8AIm4ZxCTprN+IIi3SZTATTVDKeU9LpR+05LsdofjyfDH6ezVz8ezgY/VvRib1V168eD8RT/SFSh
# DATA 583mjeQ73Cu4bTc3ileyQ+6FCwWdmDC8fHZ42H+ltu8pXJO0RsMSoeQKKxrAjOz0RnjruPS+c5aV996D6OadWwscgUdbT9Y2NkP5
# DATA eAwxwxqbE8j3Psb1UatFh73fG6bqpz77ad7t99VvnqgyCLfLnFDdPXlGJUYa53Sn4VYlL+c9q7aEZE13Vy/0G9wlitVJm0t56BhM
# DATA NpS1pFunPGjGSZJcduKDNBpUtQVcWscH6x0AnutNDndgU1NT7bRjJ1lu2b6mkH67rf9HB0CH6ThSwtJUkU14AXbfKYm/8Kx/oKYy
# DATA R40FqNtf3V5ZmcOycYJ2PnvyeGPzu66HaBifvBpLfE5jclHWNh8q8Xpr2220NsrJkRJUHoiZR5aX8iaDjnqVyOtViOqLzNYn2xvo
# DATA l1UyBDtvbTFvwn80x6jDt59N7Mzm1m5Hfbj+UPXjs0t3BL0lrg7tvnAPVX3PHq9t43WnFJ29Q3YngYDNFERSGquILhxlc5A55vKG
# DATA PND7SSH1qz25YSVw5yR9kVkEfAvYj0hid+6UnxYkVLb6ArXC2nFQok47stDUuF2hAYpNgqasDo3VYnjTb8/Bb1LqoITzJYx/bn7P
# DATA oieSOqt2yfDYcnZU+A8yhc5hr00tUj3FleTx+Yj85RtAOPhQitu2B7GvyeMIPN2s5Y+IYuH1Bxuba+rgwMuQTbAjkPyxuURg6iuJ
# DATA I0tPArixJkSOSiyIrK+hW8WRs4/c+Df7fB5mvn8aUSvxeOPJxm4RJZ97W4aTnx5Os8nc0YXQ9NG92va5PxzVvSHI3ycQ6tAZErRs
# DATA DVs1X5lf9JH5ab6pEAlw/A8/Xtv8aP1REaC/JIbTOVMtbxObPLyOWVyzsGuGhbXcAEHXSitMieENjb8Mjfct2kuV+SeY9ujNW5Si
# DATA Q3cLyBmHwtfeasvDmdSY+7YNuLZg5ebAh+JCSyMgnfu6HAW2FBK4KuNPtXrgivy/DBr+MiIALbHt3KXDQQs0J5Bz+p3Q+4qsJaLd
# DATA ZH4kSwl9vpzNcu72KFom5RF251u8cY4DMSk6ZwXXkCDb4jUB3ZDWJNdCSqlxegZlgFsR4JZQVDtxoAUNdHXal0Vuo0TZuM4nGzs7
# DATA G5sfFe+kTncZ9qqt++0ryCz+xvMJ4Xa7WCgmK7FuFnRV8LvA4rAhCXqgE/iydoALuFDelLwPXyDgCT8F/jeHy+n7qzMnj9S/Eltb
# DATA FZ+kA0wxCm3sCYhfgwDOaDqAqIEWWjCrkKtojb/ncxlnL9NBnFQAb9pqmgej3lkdq3o4wtcExYmpQLxiTTc1iOK272DowN94LDyK
# DATA DnTfb9vLszie1OBDAvmkz95BXybpKWa5fzU1Ghupng0rWXfOhtP0VVC3qviwmsbLq1kDfQzoc1Cdk54mjDfgHOFFz6YUvFjoIlU3
# DATA VFyiUCN9NGb6wFORTVm4uga2hbx7nJ2k2v87J5Ul7iYotKff7/sZZty33sFaaKa0CDU6zVnJvsd92C8ZCRQV8LOOShreoUbasbBd
# DATA sUsBM4eqH++IqhkXlKXYR2+y1ROe634PY7TADEV++iZEANH2IBAV57/AtYpt7EFl+66a1JqspGpQl8Vi5pfV64Xa00pGr00wvXhZ
# DATA P/hpk5SnBtdXP4fNfpK+6p/MTsqA+iUqvwfIzxPONRljk64QtG81M52rSrYB9EJ3Vm/dXUn2k+QKxEbG7zKWH84eLVMVTDIHeJtN
# DATA AK9v6X1K4cZ6o1q772V6iB848cWDHiK2wXZzw45JXhERSIRXE4xBIquQC9unR6geNrtK/oKmIP5uqBvl8Ynhc2N2o8TPX62soFpW
# DATA 94N3Cf/0iXcyB5Hl8hOksfnOz0krfXHhdEcL9jhKYalBs2uyqExPVXcU4Xm4/vHW40fr2x0A11z/dNfrCc0cRJjUvHl1VZkxYuhT
# DATA L7RRhrYiTOrtldvhV0HqcR6nB6PZ1FiS8deyaOCi2ccEIBka8nmbLqSf217/d8/U5fKRklQ/Wt+x4qODv5Lz7vTC8sETbghejKAD
# DATA QnnZhG2a7es+0feRoWcsxG2rlXWkA7d1wk26GS80GhC31bo9frwBpq+i+dlQ0H0iCKXmDU/W13n0zhUJaxmqpoka+QBW8IfkQnIh
# DATA 7zZBgp46z/tWHYb+jMSM0OpWsODDhLX0EbDSujgidXS20JiGVE09+uFsNGV/3sSQhsKhsVHYmcDWq6BL7GopSaymUpxxg/eKsQHO
# DATA JxuuWzybsfRcEX+enVRVWP39FeS47fVNoAtSjAvtHVo+9D4y867mQi3RVCts6THIf2xV5WWWMpW3TQx2OtekCYcr0wSMLt/d3Ppk
# DATA kyirlqzczov9lu/p6vfN1jMGv7NhVyrChK6rHdB1LaajqFZf0T67jD4sqHcOai5QkQRDCikcgjHBVUobGY5LIntBaXMJbfYn23Kw
# DATA TljL+qcPH3/lam5W/UA4TImym5W/NGy8kPivDgez/FjIM2a+C3pjnkI6vz3HwYB3aE0EC7CHQTbMFQfpoFG/zYD9QIU6AAvDmbby
# DATA TO2CVC1T3q7FdSDKrTjRCWGSwq2T+6E+OOl3eTpkZ0pWDk7MaJJiDmnctcINUTja4VQ1ADoVfBmb8J/bivgfZ5xXiLeQqa3uz0hA
# DATA fVuheVv8+M1RE/LaaRYj+ldMtxoOVw99zUdbnPJ80u04Z1cdpHzaKTnOlho15avCuWWCSW2WGPo4GN+UMzuBXwSV/86Evzv7mwG6
# DATA q7S7iY7x7IXVluqkwd3PZPHkmE8aBYVLFjIJw+PyTMLGdjHJuureJzDSp6Mp6tQoSBMANTm9FjekbnIifxa/b7m3oAkElo+RTHKB
# DATA 5ng0riXehtdl3bAkh404NpY5nKqwglR/6YEp5Vn03VfKtTjzMjWqszaLzkCmXfHLT7bBIysOPZjRebG8z17+Z94YJv2z5+wMyidc
# DATA 4gdR0Ze5VerbFBbIdrfXi+ZM/0wBFjoOO1qmkeAChYdANiYqRanRg1mhw2FTmZKb+i8zzQb07850VGM8SAjrUnuvlpRNYLWjCy7m
# DATA 2/j/lFltwuAjdmC4oibpRGxDc+tm1En59/oo6+9ZSsJdACbm8Jfl0CcL2JxKDIICMNZztW8Q/WpVOtddcRNa6vhe2+lKaele/yjL
# DATA gVJz/EUzP05v3rlbK6//q3CGCMLOvIWDROh/l3CaKFnbd+hIcc1dHvRb0A/6wxEeQcePQX6hfiatub6Zi7gllJ9Dm7TS7XnlZ8Rw
# DATA zcfz+3jAofbSIeRE3VEhCf3duq0pme+KyuuDNbYWyvT6NhNkj05zNga3qho2PP8jO7MN0vMu8B0pqcwErX7Fi7+Y+01JR79275t3
# DATA OfoC+0GcOct5isPhPaCuVvRXTQbwBq/2pWLTJRwVWEL2SLa5xGkVGYtHSSL7Z3QsiBbjKlmMv7QEp3S8qEPAH5647pgbpb9dMdot
# DATA cZVDmHdE9Yr7Rnd97m7onel37YqWzBf9IWlSWROFylRURVk7G7xWd5uive1qtk/7GBvHhz5cGeIPhFKWe0Pcsx1fxMLnf1IILzEa
# DATA QizIE7GPs+Y+ChhzqAArZO3cF4Zg7FvOBwE7V2kbuBreeD9e/7Q4UCy3UAgC+abvWnWl1TyzfNQfRk6Hi4axkFEsYGPH6io7jyUu
# DATA ZYiUPV/A0RAYjiIPSioejM4AtiykNbRv1V3GxGk6EjBmiJlg2GVgAzderuoETq4iSeovqYqCX9I6kh8vhqEYF+G582aQIA/rwy1L
# DATA f1/WIghDjQuhFU+zCQIosv9HCUhymO188Gzns6Kfh3Orl7KtRBSqEqoDOrrQDEltxHAaB8AkKer5JH/ZnUwLb+kxBuQqmcXJTMGv
# DATA Hqud8cFjSOexuoiGrgBR5VwtFkmCoeZF/N78oLBY1UjWl1mkq2fa6Ki+IPR0bZAdQrxd/+h46jLa/CxvAiVWtObESdWjGOzsVZyE
# DATA k0ATQFX/gLXAFFDffPjo8WPOUzDLsw4G1gsoncPZkNE/zJbiKgjzUW2QdHpTbSsMqtKdNF9VZqV2GmimkyPsESa7p751OwjjaH6B
# DATA w0ZnLB7MeT1T7/fdVgATBmK8204lRf0ozD3eD+GPjtb16re0JvAa/+oElKi6xZpTAQrGrNKHF5TBsO5U45bCN7rYTUp1XZpjmMGu
# DATA e2J8atVoUa1xDgtAEKlBXN/5bMfArSNNM7+2nm5u7e48e/r0omIN6WDw4al10UUVNH+Kj5on1oSC8Pnk1AgKlnyqDgfMlKO91u/t
# DATA TtTMxZT31MLiTUgzHPanWAf1ytruxtYm6Vp2RP7ahQ9Z4IzMPVylp2fuCQqOZm1368nGw442ACt+23m2ufa9tY3H4AIu/Xi+luO2
# DATA 6JErHDtadlLM4J+Foyc3DBQTvzslhiNzFL0q5TFjR14+Z8VK3dJyr/Enqz4sqg2erDqOxVWde4wMwFMpg0ZbFgqVoWO2VGSxV9tP
# DATA ZN7imZNGAe80sj3pmnZlbvrr1NEmbu8TQzIItQOR8oR46Ro+jdsJEQoR3h+EIiRTg61M93I5iqm1PIa/jVAK1zmH3uj22qIS9H+k
# DATA 5yD2+5XnbFjQpa3HB79fMFj4g7WH3332FAFPq4KfKftMQVgPqwBGAL4IljpF7sBbDB2mxLcFS3RQNTBJT/U1u+SO4NwOLCKM5+pR
# DATA dfMvIvOLXL82XYaB67cOS91MSVrOBkon3WOwC7TK9A9cQPVVYspUaCTegU7BdtCoEOqMTfd16xIYL6egUuBLve0o1lDccWWIGNVg
# DATA DO61lg+x4yi1Jy/qRXWEnhCcsv1CrthaUDvApeerB7hgkiyuIaATG0tJxu4sewqcSzKFHvjbUBYuORzB0kkgkYXZsB4tAE9/ebqR
# DATA 3KWnRfKJYotV8vDEzJO6mHy5StViE4I/eCo8G48Q0lxQSOQE3Goy57ALLlKPpqMXmRIhR4NePRpmp4yrWGcWJTEi9DqESNuSzTpQ
# DATA 0nWKPhZNO2KeYBEWibiXvYQ5Fd+4Lxe6ldIcoz7ss53d9SdCBtTbw2lCbZaawMkCFyCcIuHW4AV4czUYab6y4kbjlK2kUOOEt7QJ
# DATA MgmWdGmw0VobItqKVjUdbVXSs3pB+JLErBWgZJoSt3DLFD+nvd+K3uYoyewmJBNp/qT3GTnLODw0Pj09pbAz2ISKbIV3KhRQLy4X
# DATA e8wM0Ztf3Bfqbz5CLC9xrhYQG+Ruh9wRgx5Pm5KnslP1Nxw4ZwqhzM47mEGvVr0ofLZjOtzwAP+4kHFTZjchb9autx7G3o3o5rwZ
# DATA NF9Ia7v213NWTgLekUNmEEKIZKLD/rCfH5fRM0cPyjcI4eWaHcDm96Uv3Dkyo+JRoYjjHIglQpRBZIxahKIUmg5qH12Kinybdj+P
# DATA JnGSHtAr3RFUk6gaAmHAnLyPytX11Pj6x8U60IbkbafiDc5QReNGtcdV1GnWk0C0Mt2IXEYjIw55ket2/xUSDOZ5MMfMvK1E1fxA
# DATA nZAh+sqV7lmpkuTiRfOffnFlCyBXUC85jm8vdhM5c+kYUy0mWHVBn4wkbsnJu5PJFzDbYWc9IRURH4tWLCqahGV3Mdh9jUwvd0FI
# DATA ci9eokPS9IICfRhDzpfwYRX265H5QYsQEPmDswWLt4BAj8VKLxG0yAvfIri4aTUYK+VBq1kqKXE6Yz1uXedlbhy722ubO2sPd22E
# DATA kQY+DxnE7aUGpdLS25N7deCKSPW5CN9wN+bSZYTRwKeC7VgR0XKWuVwvezVWoixGNYp9UMg/7Sw6Y7PTxRPOja7kLdels4h6ZN5F
# DATA pDuboA6r/VYyFNuJXmruBG06fK/Ov+3yJ9owCdmeoLzxJ8GkCeHpLFxDdffNfdKed5vaZoCbxc47vsGZaesOzFX707y6oi4lgxRE
# DATA Z6lKEKnSJcnd4YgBl1ARcF09M/dGsjEK1lLiJPTAk/4RBnC5R8v9dMk1ihfHRbUk1Zv+krd9e8aOMkeO08sLs07JrHgignYQcyPi
# DATA kcrbULiPV+inFRvdVuqRfwB8UTp8TOC+4Y2SP/B2dfnY7bYMXK+xq7bRgIyL8m1AGBU99YHgSsXRgqme2jd1uhv3Ep0UFKhePA8V
# DATA tKgePDI4Zpx3ud3mTLxYogoNz2WGEhiAJIHYwcW4CttmHm59b337MwgD//DxxsPdOKmiW2a4849XcVjFlSwuDtk6S0iWOe2mT5jp
# DATA iD+eSy0rB/x18kYucM0wHDelbzkXWwjnNMCb5qfj01FgVpaoPKKsjbClWf2ZlAo/0liH8+u3pHvA1zVpIfSXgi9953wHYaWRZp+h
# DATA vWv1O1F8lA2zCW5J9aE+J57ex3gqtozAZnwX5wgjF/qWrC7J0346oAhpfVodNxx+WB6HZlwywlFfl4lNNjqHy4Qn6w6+o1gvR02j
# DATA YywuH95F5g/DIDjMH1yuQoFbh/0JBpkMIRETl/D9JbSdH4uWp/31FsX/0iIiSlAMuDYWm672vi44yHihW9TcoqFbofCRtwRcLkLl
# DATA PiCboBNZco3cbXWWjGTBgRa0ec6Cg/Qk5rcQGMX6LUMWK6oKhYQt1iPH0FzWMWfsqNTTvwrKONPbehEcL3nbEYTChReJA6jyMQQg
# DATA tWzyMuTL60LwaZ2Bz1Rd2+JSyWSwkjIpVihCdJkZwJsZZIKPTedAx0YyKhgQOH5eBPYR4whYQ94dO/AZDj8znEuyDM56ypga4gbl
# DATA 42u044kimqMTjA/BmHMNDiAuatIEWYnEAdHjoHDkqgxtOhiNBgFXeN0JqxYzj8gLgLpmbtzBgACDFLKwPgogfNZ3DLCcXTPHYccx
# DATA uNmzYVU5ARdzvozZ0ouqrm34d0F7rWYlpLh2QtBpum2cC9cGv33JwBSqkiokYQqeTywlr/Ltcs+ogm2IMBKhx0KUc24iS8Je7bdK
# DATA skiZ+78OgHqZsfpnEWOV6ZT+zr+siEkOUu8FSAYhbBQohrl7BcO5JLkwvXMDZlyaIAqJ5/uSTIgi/Gz/wo/1kBvqyhtosU10KbVj
# DATA gA+ErhmBUYRVqOVi8+KdJ21dYP+SlEVTBG9BOXzuNFAW+ra377q01Rf7ykT6VQgPdf9z88YJ/yvtQOVWCd3z4RkjLzmTcZWprgB6
# DATA IrTtUb9LbsT9nvqwf9jPJmjKET8ZAUp3vzZ/k1i8TZBM4Ymort0u8vHEKjLzbKD1+rUF+b1Hb4j/c9K/Jg2xxiMlSDLDMtuCZeJX
# DATA +o1zc9c9CsJhXRoSSwJGOrhYuh2Bi2Vj+19kIEH4uD4F+3+Aw1Z6AfgyrO8mxEoiLx3FZYEjp+lEXXEw3hu6uRwV4DGYc1HBpo9R
# DATA IsGLsIRp2PdrtaBYt2+7/WWADoskd85juyExfhhCUJFVStl9lDUnR4PRQS2+ESfJRR2w+NqD9OSgl2Kxlp9JrK6zhFCkQEgT6yOk
# DATA DDNWexWddSqcoZz41ZbZpDaStaUl13DYM0c0tjTQn0fkyqA3HWXb/H1wUdY6u2NJzwuHUDpOPWaGSjx7FlHNBT17HDOE0dJcC3iA
# DATA LBpaLnXdl3Vj7Dj2SfGokE1QSk9M9XqxkBKDvAUJXMz3nKCwFfCrKxO+yjafI1sFxmSlKj1TUqjS6IaY+rt4FaOCdaM47NjWSm9f
# DATA QbD04tflXgaB4gvfmz5a31zfXhPm4q/06nTV24W14oseUanEi5vgoiIqRDaqQZ8X9I/QlWEQzqWiJ+JFLzbgWVR6j0ycK2NVubD/
# DATA UxVgj/ET6Dxd33zk4t1aa0aJDHwZxU3RcBHYsDi+BX0iuKaFxmn3d4AUsjmaxJxyi3vIEZHmxfMLccZrCmuDIPBt/Qy8ZalFPbC3
# DATA snUzPep1vHUJeurztZgan++FY+ORZBP+Irmv5WrpMfuXA6/HTntzpUkbjbUoC+NNY+2Mda8PxjffOfTVfI2+f0ulgKsQ8KbRuVh4
# DATA k1bilox1OlzODlmqDBAMusDaUP+nRNiXbh5LJS9O0BGK8qw31yZHM5jsp/imJoCe2/EGMfDoYDbsKTYeKfKXDiIgsppd5EgYR7Np
# DATA hPMGei3IiQB9zpsmoS7UDBjjnZQbq8WNhsRdA71k+6lRE5R9QdJmZRmBs6ImIVUzY5Sold/R7DUm5NS5WH9YAgL20qUJI2FiqjZO
# DATA dWswR1f4jLfNwh3U5LkhNpHmwwiwxt/hP/BljhsmCaaphtdN6Hjh/NMBLl750ZUCP+OOF5xy8KWTxdGa+9WbEHvxy2gxVP9mFXil
# DATA 3Y2HTdGydl7VWH44U53JI7E7kSgGp7Ju9r7ZCtALb58W5skROd0JqDuzVS+dBH4TVJUWrfjz59nO2WLz5U8Of5/aKexFs6G6m8FM
# DATA wpaBqme5oqolc+JYRIJzok0j+MOaJuQWqJqV8aSvjoQAXqamF0FeTgqsY2WeGSuAC1LowHmMJZip4N9w6S/2R8nFcM9tA85APlXX
# DATA +UmhQ6uK5JvjahLOgKrNJlkRkP3mpO4vha2oThUA5A8XV0Qf6nRQkdXpwGp0OuyFAF1T8u20hjxHTdg3Lv8/4Cq4/lp32ByffeMd
# DATA /29F/e/u7dv4r/qf8+/N1dVbt2+9r5/R89XV99+/841o5Rtfw/9mgB2hmv/Gv87/+bnXzq+Teup6a7V+HUWN66298+v93vXWdRTs
# DATA poo+qKNyvX4ds1Sox6//9s1P3vzF6y/e/NnrX77+1Zs/e/PTNz95/fPo9RfR69+pv3775k/VM/Xk9Zfw1+vPX/9WfSwEHqji/1Sv
# DATA /+n136vCPyn5qh6pf/9CtfCbN3+tirz+NbxSjaqiqspfQWvq/36lnv76zc9UN36q/v0b9SHVqIr/9s1fqZe/eP1FUzWPKqzrrfPr
# DATA OoeK6sT9a70RwkBg0osHz58P78Mf0UBJWO3nz69nQ/WfB/ePs7T34P5JNk0xQ1GeTeElas/wPb6BQwuPX/azU4BFUn9qDRo8Pu33
# DATA psftnpIqu1kDf9S1JaCRK2Eva6/auo6n03ED6PtL+PQh1dLYgbxl/elZ4+lo0O+eeQ2wENbIJ93oeZxng8Pn8b2Iptx/OD0bZN6z
# DATA /smR8wRd5Vr3otHBD9Ty86uhYlpQ+CDNs4bqi3gEoCwNErPs0+LsiE3g9X8tetnPZyj1TrOD0ehFhOlqlJR7dAx3kmPFSI5Hg16O
# DATA rHB6rCTjVLHFKD8BwZkuE5BQOQJtt3qu2NJJlKU5mCemI2CKzWhnOuud4bejSa8/BNglRpJVAh2I1CcACIm9xq3+4CmotkG8OQTv
# DATA kejH0b+b9bNp9HI0UKLf/WUqdB/9dSbZAIbR79LIVHcP4fdymqv9ki/D82b+8gjeoUwJZU9U9cvq4XuvTgbYqqwJVyk/zrJpqD5Y
# DATA gmY3zy/5Gdr59Ge0FAChXyjyAygBgn02eXB/mQqqP/AkwDGBdH+4RVAJBJ9LUoG1q8MyUFVin170x7I33wT2BYV21AtYHd4H95dT
# DATA Om3Qqvj+AC4WznCsaQ+qcVdF1TFMXyoZpZ82BukBTcsTkJvU4/5RypsPWiipb+tlNoFzjHWJUrnaP/0sN+V2xikc4Iif+8VhC5qy
# DATA 27AfT0eTF7g2WHRZ9YcnFQZMomEPPtXzc59TM9mpGIOtB74gyrT6YPc4VUs4BpnYBLSpLa7+VrLasKmqX31wf6yKZRF8q47HWXSc
# DATA vlR/jF6Cdhcy/x3jAYBUjvgaVgPFTNipo2akvlXXZnSHU5K4Om1TOGJnoxksHXysFVX66KpWxw/u9/ovbb+JNOT+zjiYTafegXGX
# DATA 4gMlZOpmDjJ17wW8XZ5orxYwD46GPXWqnfoWWbRl1VfY5zTbgWnnBzTpNx9sTaJxX3VsNlaTpEjL4UxNymg0gOm+CdP9MB10Z2iO
# DATA PByMUPrPUvLvjpDaR71JegoUB/z6YIbVepnNEfVGGS1lL5sCWqG6QSjZdQZnS3Uc7L4IXINARt2REtH7oASnWb/M/jPjXYYN9+D+
# DATA oRLlYSeO3ROldpecCtD60i0B6rW5o1R9quADvfZOV2wiMvhmDSn7H6Un43sgr79Mu2fQoej//afoUv2nVdO9XgaiBOeJebli+rbZ
# DATA P3D7P3D7edyetuUVmPw75vFXY/HzOfz/QAz+HfP3hdj75bj718LcaUfK4RuG/i/nBCHBn887FaUf5ZnmoGuabZI6T7WI3F3zTzlk
# DATA kGtSO8zRIQdAqrGrbYVqFV4inoJuf4LMFxV43kTg9KBIo1lwjuq0QZZOEMr/RDFttbMGdWTAahD9k6wXHcz6gymMAOhjTkNWPX2W
# DATA wycoben+6RFAC5ajd7U8kPsCAYkDo+HgrBltTLUM14U838DxYeIU20JNszVra1Eg7QGHQfUidhEWpYFiAZz1PEcco2gny15EP1R7
# DATA BZy1tHHhOBuMUVcFnYzSw0NYJRBI0sNsemZG+NloNrE8moemJJ08msyGRtQ8AGenbNKM1jnREEwpjGM2BmkF5Ey9C2GP5yjDqAKQ
# DATA QmEEQpIiDzmUSQdn034XpRs1tmwyBRv/kRpCCv4X2rUN6uoeZ90XqPJE0w6qPZ3O/Pef/G85jxW0vOgXlHdHY1UPypNizZr/H3vv
# DATA uuTIce33vko5ZG12iwAGVbh3c0ZneJPoTVI0hxLjhKgPBaDQKA2AAquA7mnNnghdvLfskOPI4RNxdoQjbIcjzvlOaYv2WBcqwn6B
# DATA 7lfYT3LWf63MrKzCpdE93T23lEg2UKjKynuuXJn5/3nvoPw9XpdnxQtK2ClSrsLCE4jqMV4RTamkRjpQ9rhSWw9j6osmUYXtQFBM
# DATA YChL3s7ymFObWHBh0zN0h8kRjw8GqIo1v/ducjITMw8ZKTvLBlRjsGOtFDWpp3JLBiOcokqtHD3cIJKKPk4yKVrsKUzZxH8YRfO8
# DATA UYeDAWz/SYLGMBjw9SMEFEMhEcJLnJk0eiCcrOZ9nPB9Sy41uj1KuciQl6ZFIdA5IjyOdCdB1ecj9DbxQpJAQdvNhXJsSZWbq7lq
# DATA rbpVRo/IWEQSTygwkxUjnrwUCvIDirHZuJRB3AO78YbSwXg4XkIllMb6XOkwRBRr3tvofGTvAYokxbgYUd+iqiu9B+e3+DepUsra
# DATA v/I0Z7fBZqcZzo5m8q0Z+1ex9a/B1C8aTWTvf+dxP3lE5svPgK/pcy2t0pUneOgxWTzJZFLtRzQXjpP0IJtS0OMnCPfxNEypNhzU
# DATA D7HCcZTC9XNwHKZ71eo8nEfp/uEgmdAjconssv1D9F8Hfmf+6I5fa7c8+QVh7R9ilzl1+SfVkzScH/SpBj6sUtqGT8LHEkw8owYS
# DATA Lw6h7V9dYuso2XpRNRmNKEEHtSCIpk/CgzHCecz3DMEC4UZSpco/eDijtnsQzB89kUpSiWfz5aIi+7cqeAJjzWOOonqXvrMmfx8P
# DATA 44yG4VP6mV89mkSPDmm0OJpVecvfwSACJvrwp9Q649FpVbUvfZnmp2S0YFw9aDbnjw7nYhwcUE5Qn+n5NR9/D6UEDvz5Iy+jKc3Q
# DATA s/JvJaPRecwWxZym9OrLqjTTcBgvM/WzfKlQDKQ8qicSp3arfkhTqYzCmSfMuz4sZeMBJjAqT2qmiencya88tqJJ3dQskx1TK9VB
# DATA BfVjtlCxlzuLhnex6PyTxysJ5eTbAUgVU0EcUMlgVBk+TubhgGaDB7VWS6dGzQGpcozIQMiqZA/GGIHUo8WLXClK16SKlC7qClO+
# DATA dzmlZnFavPqYmjZqzEGjVKh8F9V9+VnXZSqaJxIP6q/3fsxTJB7GqVX+ZN+6iKJMfrK/Uod5Jn3g1+vfLlS6NlW6DbULr9/fvR3n
# DATA VRc1t9axKq6ubA2diFL8K9ZFib+KbkBN81BFlT9LJa6udiLU7KrZOKUvB/UnheDIVv/JYx25+hOTIVYu+N06hU2VLf5ZdMCWEw1T
# DATA T3h+ZNr3URoPD4+oG6o1OGWFZlKvy901TpJ5ZlNnwMF0EEq5/duhNinUEagLVP6Pt5aRTp1fC1o6VMlAild0RKP4YzvgTr1uHql7
# DATA tSY98mTsV8ZBZdyozFUXXl0kc3p87EvvJ6/D/ApmsgRUAWkZ4910vhfUmnh1pV1rHZ9UWjV82acevd5UMVV5sn84IUuIqgTcroiA
# DATA /EpdApM1KtVavdGiRw+n4SOVBr89GB+qSPUTap9TSmiDIx3sFjlfutNKg6IWcMYjan73gqhRXIIWsrP4bn5zQ95ML/FUrlOIjXKA
# DATA xSe5ZTxBBuuktTuD8ZN4elTJjo9MrWES2qHVXlUFCZeL5InMiSu8z0BGdNVUgIvzgzpV5AomTHt40qt6bfTpJiIySNkhXVhXywMX
# DATA u8tp7F+cRNGMa7Jfa5Wqsl9vmW7FZNu6mvukxt4LycuO5GVT8jJYzUuda0GdKsTacYjmEsUEcb/A1gP+Iw0vUEMr/33C7pALc6Hc
# DATA Tje93Qtl5FJe/bswgX9SNj0OjKVyWGqWT2rwBj2GeALfOIofRcPDn1XZB0PpPkSjrPoo5UMQNyinkdEbumjTLSCdHLIMQY8RCp58
# DATA UiOTJtGdY1WYgW2UXbHXo/+YPWvoe5fTWXbgj1KP/t3Uv3ED5fC9GlkO9BpOK3ex2qzJi7TZooYgd4/io2UaGUMyvzoI2RtqhVPr
# DATA BmnePpGqWpdfq6YSF9eFbul5X9poTRn8paxp1fNqzXevr9PqYe6QilHYuTHZmUrd90r317JjyS/yqDMs3kVZh5J7vENZptGcZoV7
# DATA jQrVcyqUvXqFSpa6jTxGT2qDMB0+tkYWa9Rp81BfroXZMh3hCPcF9sV2c1Te680PMPuvDsbxZLiaTL6lBvd5pTZd0qT0sW0g8BUK
# DATA CL/blacneXiCbfm2NdBb26bWm88t6mSb9G+D/m3DtCqVE9fPQgGwz67YXDYY6maAQSCl3lDSfDBbjCVP9oLZvqfTsqkkglWr7UnN
# DATA +E3LdZ26AUoWOglzi6esAclAM/BjaMWojw8IEb5Ka5DrdNG2+apnD36dOq5TeuLFLnWUMlP1OLp7KbQShto8qcG3YKy94CbrJd7E
# DATA izmrJqIeW2pivl2iBQZrWyCHJZsBHxc6KzH37H7eU3VuSx1QKePxo7luRmm1hYZ0RydjPiyJ3uqAJmXci+oYHVBSFqcmjTwS1mTb
# DATA esHGrrW01ayaXyDdivZFrrG0m3bq6oe4q8oLOOotuR9zEj/ewdwozVGo56B5UzyIHttZUp6P6eaom4eMuzUpFJpeHllGlIl6fYdh
# DATA Qp71Qkw3aD64QyUp1A3PfAvwDTbdaoOwx5Rif+3VdzPQirH05tbArH7KaHCfHT0u+Q2ogYRHZe+ImLZb6qYpoEAmkWmxznTbq5PK
# DATA DU2zH5ZsW92SVsbWkl1Q7sLFIFBBejIpxCMHvjXP8pvcU0pTyDO67LwZhtk4Kmbwj8fxcBjNflJoQP9C8IDhbPGEmttj4wd7xKa7
# DATA PTfC/CB/X/OCpm9nZXdTwy653cLZ6Qnc0E+wNiKlPAqn8eT04B0ysRIalytfvPFh3Nd73z9KZskXb1Sm9IfDLbZ5ysshjcPxJLOy
# DATA Kdi9PipfyuOSV6rstCrZ6/qdXmF2y01YTaIuaq6HxdGRYxyoiU8eYsMe7tcZnTsYgOUq381jabU+qw60ML6qGwpuDZ6p7OafpB47
# DATA 91aXZqIbqkNtHk8m1TQ5udjKVjb1IpqbUtfdaDP/CZ24af9N1UEv4MLj8Mqt4An/pAuOushJOM/IKlEf7Am0XQN5YF6MK4uhTMs4
# DATA Lw4Qm8I4ulNlXGyztZ7UKAbRY+7JpQM/8O9UfR4bLR+RZTSIzZAsF/Plgk8klDNL5lS8S7+KZZs11iyOp4WLJH2sh911tqzUaN3R
# DATA mQr95P+YRsM43LNMtDZ1a/uPNzodbE9Do42+V3kViq1F2SSroxNXFjlFgemuZJNdZ3h+unH+WWqUDcxc7awszieN06XFfTXPjS5l
# DATA jGljdXN87Jevn0I2sNhQnCHumC0rBsPmaXkw0j7GlmWl6Afv2XMpu3oGJfNZm7Gr9aLZ4HrBeVjRVu7G+LBbRlwvPKr38sIpTCgC
# DATA cdOpqWZxeNg99TsnlzuRNfMf7sipKpl0z3lJM6um0XA5iIbVacLFIl+pdaxbE+PAv1P5zoFs+qAP4QjtJpzF09xllI/zh7woEq/5
# DATA RUdDTufotijNsKIXo8oOD7GPuTSV+WG5fGWlzuoV2ApQc8M+zU8fmtlG+aYnTworhnrXFnYI0h/v0XQy47VP7Ms7uHPn5OSkdtKo
# DATA JenRnaBer99RG7ywgejt5BFurHt1r92kf3jZFzXekw2A9J0vetKR5d9Tfs4P8HlEQxDvmWrUG8NmDxsf773FciW8W+gjv+35vXEj
# DATA OO5+P2ge+/Ux/bf7fb/9s8LDo2DUGDXkYUSxuCqa0QgZPXsiuzSRp8k8pyCZqP1tfGO+GYsqbv8Uv/C+uXx3ndr8ZK7ai84H+Y4e
# DATA swcgGvJa+KnZgGdlSa/uNZstr9FrekGrPmnUA8/vNqqNesfzm41ixgzbw35UX83VTsNrdBs/8jvtSRD41V7LC3x6vN49pr8fIuhW
# DATA PSgGFY1GPucxTxcecvq/1Wy16q0ov1g1Rd9YeSlC7frHzcCf1quB38Qrq70eR0ZFxPOlVlzxDUFQ94Kmf+wHjYnv+16r+6Og1/3Z
# DATA R81Gz2v4VH2C7sSvd6rNzo+CdreYvO6gF4XhSpCdFuVKb+wH9Wm1Xad/jvGxSZcbze7Y9+lyq0X/HNPHUsz77X69OVoX8+bGmqq2
# DATA L1JFPcDJwsfKE3ygavghz+8PVGM51FPbg2+1W+1+AxeM94ke4f8dGoNm9Upw8K3Ij1pR51D52A6+1eq1O53WoVgYB9/qjwbdAZ5g
# DATA tzP9PGw3guGhLO8ffPHGg+goibwffkDThc/CMdmelfu8fSyjrrCaRWmMZ3WXttPt6J5q2G1JJlPepR+INekFRadzVwwBc7sZjdT8
# DATA 5nsRtek4rEjQpaW5w7IjDMZZpVNrHp9UOuII44DVTrldpvdb/Vs0Uy2GWHaU22aeKpjVB7QPvThOFO6aF6xKMTn5Bow/gxg7iR5f
# DATA YnkgXwsQD2DJLBKnVf1yxo0HF215I0bRK1DfaMwWUltZSdpFxp3y7K3UMTYbbtJSebLa1n+Kpv7FG9i9R51EPFjwTvIZb4D0/iX0
# DATA xby798wWyNqXyyg9fcD7ApJ0L9u37jU330/T8LQ2SpPp3vrn7k8m9Kj1rNrL97fRKaQX9TNo4TVsB6TY8tzSe9P74o0DO4LTaIrT
# DATA 2YId+yic73GghhXOcsYPo9OKNwonE1Tufe8xDvzTfyUAkcnnPWUPJBIgUn9AWb1nRepNaJTtHxqqMNNV6KXLycT7rrcnsaiNwwwv
# DATA 26dL6goFJVcOrAgceDj6KVoELLZ/6D3BUeXBmGKl3nCZEPH4EzvVfKhekq1QsY/145k8rn84VHlRSH+2If0ViTdqyewoHp1qbJXJ
# DATA FmyxWZOWEQ53r0YyPN3D5HnfFEUEgdp/uffFG98Sz+8Xb1DQEBuKJkC01nC3Op1BN+LbYSnIcXKyMUwxRi8d5mw53YuH+3lqPl5O
# DATA +1G6x2F+AdE/+rWmc7Pw6FBtIt0TOTcELnoW9KYv3sDXO9Sc49mhPuYiZ1zeyGO/TBH9H376YU12XP6Aj4fQd6i3eW9DQ+/HCOcn
# DATA Fe8xAn6CwpBHQ7shydPvTSLWy/jijZCzIaxh9x80a9IJvun4ojVRjHFpMIkHD6lNYevpZ/E0SpaLvb19tHFEKo2OyajII0XhgPtO
# DATA 9qvKCokK1jd0KWA2gZfb+ZTMsKF5bzRDwlE2eICF8KYQ+njvmCL9odJaoTCyZX8aU0FWvOiYi+0ePcYfa1CNob/vysasPVXUHBBN
# DATA x2kq9CPQO+LF6d4+hT/DDU9UVP8lovdjOXARHkc/oUjW6MH3wsF4T23+5BdNyGjOQhGj496FIoSviM+Pf6Le+C+kB4wz/rvHN9Ab
# DATA 9XM//okuJcp/7I6HLue+hC/XT1nJku+v0agyWQ6jTEUj7xDpV3qf2SS3uK+l7VHC1tY3RO0BN9q9U6h1mmeKlR/v/C5VzAeSHOpg
# DATA 5DPOGz051FHdyx9fUzZcX/A+nZzryCr9eYfsoATIXWRU09R27xixADv4rrf29gPvx7Uafx5W1t1hCoos4AzJ5Hhw92olRiJdyCL0
# DATA bvkzJlvNPvTlfKg3kxc28Kt8f1tte1+/x/1QnpGweEt7praz40woGRTHUY1b+BP5t1i9zYJXsY4nj/IKzrdkutjoJ5Mp5uHNRSgP
# DATA UxmaUFCICGTFBvjijXU7+exo8e8SMf4oEeBikODz+iC/655Yvq2ronzyxq6jygTJNXIt+2VbtA9UXL6AhOeUbA+pbSYKm2rOhvzU
# DATA EVC1R38l+252RJNBmD4em/GeeS9dLNUy3Vo21KtDc6Bifc1Ctcnrjao7On9grpoRmr+pnlxuoFGf5lZsjPEt+nu5u5em+YFomZrs
# DATA 50xmfWIO+buSi97f/R3FGhWC+q/pHv1JPkxOovQdyrw9k8XUEDIWX9OvLDxNVhISzvUaJybovvqhZzUIZGqx0tEFu2qw6CLEe+i6
# DATA 3WkWY5PXRE7Lvvc3f+Pt6ajdvatjgkhxQKYKmHy7e1clBfUXt8iyHr35X3AUpLnxx31Jy5tvSkEpYwcrhzr7+Utu7uDbvtyRByv5
# DATA gd6xno9ISqlIyhA3mEDkt311T2n4kLC4lnIMo4wHDip5XaJrGiO3I7RFq1IgOaYctzbgwkP0IsRRVVPKZB3IfrHG4UZlcezt373H
# DATA NuMXb7xvDoWhmby5B7Pvizek6VH6vyPfeQ7IzX2RvI9tdXvB/ptI8P/6fe0L+t/sXT1LTpIFu1q9cOH5NGN5UwLgw2YUAD20/j1k
# DATA PN0p3pq/y+d3/e9/tB7UEdrhucFUGrfMAPMDme5gtjuYfdHBbHcg+5U+kO0Vthurc9Av9EFt4znjnwsnACfW8e0Hc1bLw8gWDwEb
# DATA 0ae389t5WzGfk3uxznO/LKcaLxJusR2lHH/xON97i3racjPUi2SIhlmp6Mp6l7WCJxfCCX8rHlQvL15Jkx4kyFx50+lsoKOh/Nj3
# DATA frCy9sVmKtkDpYP/1jP8hdPBGTC/x0V7QOUOPRgqL9hD6eIUm4rN83PRDcjGIZ+I1TXKUxsuaFrIx5GXfRrXPHh1PcxBKMwvOR68
# DATA SylO0pr3g3k043O+Iz67Tw+pw/xcWT0Ka4xaR3XSk20IjGHC3fRmMBYooJnSDdhReccr+bi1jgCfJ+Zok7VARvYRzqUZGZ6/xTFn
# DATA VDic7maig/fJ0rh7vRkus/qRvCOmn5ZzmA1ZzYMtxT9mbFIlIzh5qMUMYampZkPmcsISAKNlSlbEclUN4dU8bGtCcNabs94ust6K
# DATA Nczp6zh9ncuabRsNxJvS3XmALWyWHAReA98mhPOMAs/z03jbNlxid59ny9UVLDle/2D7A4siakuOvsaFjU5I7Fj2CehMVl7Aven+
# DATA W+IT1Q1wxutRKCQJzTxnuqv8CnvFePtHrcWbiLSGNSWfN0Th4jTk/UYttZkkmvPuo5r07Hc4jqWoihfCVAd82yGi+ikTT3PBRLNR
# DATA a19jNMUzQj9rLw1feEscrSpS+h4TKfPQWwl3+HnkArz5nn8Q1N+6kyirsHxPS93T2nKPX1c30Yf8rjsSrTwpylbXualWwejBvBks
# DATA bMkjMhv4CTYk0im9l/cEq3Sq1VCMXrpq5pek54mP+UVzGqcXkgN3JAjMn1RuyTqtHUp+Se9QM1fuWQZniAmZ1QHY0lRsNEqzX1Kq
# DATA IPxiDMqPaDCk/lmMRu21tto/xthoxi2fDUUz0Map2JE17/5w6PGZWGUWZHr4zG1I70OsoShVT0wEzEi7hGy6OHrZKBVDnHocvBG7
# DATA MOht8+Vkwj8usQxLg3qcauP/h1kkyjsiYiO6P3E/piwWiXktIqXrPBZsM44CmSUwLNiURk+EeU2cYVpISZpJ56dVrthen0D43url
# DATA MAb2I9bL5EzjDl6KhEvj1bea7QHQGc7OcL7IcC4ZSM5ydpbzdnP4BVCs/Izexo0jE828cKhaQ242lzQbMbgYnTdWRHwYLahAZ0ci
# DATA bVeUXhQmWDLCuJUoCchcKVH0EMtGcsk/i+2KUgpqy+Jb4wbrz2khZ93YKcYNcZkZkUpYMNinBL3FUKLLYtjJaITtX5Dp474g88bJ
# DATA Cf3sUQnJcMl5XfOUcQFJS4rdMcZd9DPJiDsGznNLvlJ8Vpyc4qC3CNmbeT/FcDUxI51JkZ20D9kpFw7IxoGQ5gn1WHnKMPJWecog
# DATA G6IZdRpOMt4uBksHSTwiWyzTvdqQCm9MvRmXEidTTvlQCDMWFYcbkUynI5k7iRGj/WXJlKzGhVIXDGEVPPS0UsiWdL4bnnJPvD2h
# DATA KENxVaKMdRofKP/jKIooWcN4xNJ+NLuDoQaBQ+xhxD4EqlYL2YLBdGP6BU0Rv7AJ6H3GGB6P+YIIkC0rZsrCMUhVUSfEWHT95alU
# DATA 6tMF6jM2iW5J5KdRtiaBYlYUqvCqoKqp6mSlst/yBKrwqGQTNEEeddJonRGLIq1oOxKEt3AY4+ydDHRipyoxSaq9n0L/ZUiZSHYh
# DATA 235IPuy8JRkT/MRD8bhqlzJDylC7p/JOsSf1VFpLnY7idMqLI+vmtpyozyhvZD4ORu8cx0jJTDJq69SCjPWcL35n4r+W+yk/uDqS
# DATA KaCm52EmtjD3Tt5HWtyTeleGPbAprUDcxodMjechm8eYGpDhSyUdLhcxuo0wZZ2uqVKeZPVT6VDAhRK3MVkIuK6mFBtT+7ez5ETq
# DATA J1oJNRH0kRBs1Ql+N+HwF9hXidyWtkgJmsOVwF0jj21il1h+BTR+KmVsaYgnBq6V8nQhpeKm7CMbiTJMUkhFjgPS2JERrijIFrph
# DATA niLMTstqsmY+YcvKWna+2MyvoLX/5EnFMHQWR4Dzpqc2Qef/O//V2R/Ovjn772dfK0bO12d/of9/df5b7+yfwLShH35O//52FZ3z
# DATA X+iHp3TTU9zP8Ju/nP/m7GuPvvzOQHT+SIHKZf4K0M4vz39T8c7/DT1Hz+A20HO+oTf9iTE+/0A/CFPnT2dPz3+tI/NXuuUPAuoB
# DATA bMexdF6C2Qw6ZRxfog6nT38WBdHsoyihcNJ4oE2wmvfeo/lExucJ94iR9A3ZOJ5TbzGxvBG6c8Qq4jzKfQb5XCiZTNT4RC/VMr9b
# DATA oTpYTlThqZbi0DrF+Y3uQW4brLOuZG4Or5NXHXMrTLr8cvmBiehNm7s/lO88ol8zYYfHNTWsJ2pzKwZTB9jZsdiuH7GDtfeIrU8U
# DATA TiV3MbLxi9yDQyaLooJhOqbxhPOR5fazBWaqpd3KGqmJIMyhlHixwte5uPptdmiuaVnPC7NzcTIcZ8dZAjdhCWjgzhUNgNfEuXlr
# DATA g/+NjP07Df2XHflvZ+CX6rmaDzmD58VrXTcB47FygFE8xVevSe8qyINeN52rlURVeJRnKV6qwDeRZE2m8qbiKQlsLx2fLsZTDkUO
# DATA mHAG7YrgUUWWL0RSRzxhvMwSK7VQSV8gtxfKPyvH5EbhcYJRQbFmdIzxAoGb8HBKD2qLQZ2rO8ztBSEWwfcDM+IknC1st9ggmTvG
# DATA jmPsOMbOTTJ2dh1Vdprm7Gol37LJfxWL/zoMfkfbcbQdR9txtB1H23G0HUfbcbQdR9txtB1H23G0HUfbcbQdR9txtB1H23G0HUfb
# DATA cbQdR9txtB1H23G0HUfbcbQdR9txtJ0XibYTtMKr0nY6o9Zo8BLRdlbXnndi7nDuqtzDrkyP39VuFxTSWs1Srjfb3SI3J4q6IwU2
# DATA wuFGit6AA220WQZkwKEGEgxLZfjNdhHi06AMX4NG6jS9ZlD3QLfxW72J3617QbtE7Wn7rVa3v0rKaTa8pt/7kd9rjpvd4yBoTf2O
# DATA 79V/5Ncb42bnuOEXozAIhs1+f00iWt16ngg/6JlENIoBBL1g2Fol9lDGes1OMFa5aNFzzAMr9Jz2Feg5XGMteg5V/gI9p9Xshleh
# DATA 57SG0cjP6TntoO13hoaeM+j2R8NeTs9pt1t+9+bpOaqOV7kam3GhIQQdPdwWblrnqGrwOFLpHZ9UumxJFdaYWoPx4c6knfLblIPb
# DATA dm2JiaHuwtGC68Ht2CGu4nbURLNrjFWU8SHv5BiHw+TkoO7Bu1H3dEkWAD3crldfod3uxjTvyPpJIddLNxXWymQ4L8FwDjfsB1gd
# DATA rRQlaZ2nVtZtt4Ssuho1tOmGkteMponfxa5U1WdspvgUSvsCG7GQeXZhqsToyQusEEfZcZQdR9lxlB1H2XGUHUfZcZQdR9lxlB1H
# DATA 2XGUndeLshOPxH7Dugdq/GP7m9Sdu2rEVAOX/Fbhurh/+MTC9DyWfENm3OVgcOrIBPMmPQH8zhdvvLn6DlWpD/WAol6yemN+izqg
# DATA QXexnXuoIEEf4xiXtHw25SenfDpHv7UcpZr3f6oz8NahND54hrKmCmWiUNU30A/f3TbiX1NWGJvZJJUXp2qLR4s8zdQ7fvHGh9bJ
# DATA O5MM6i5VCmSiWzrn446guyPoOx9BLx4Ic2fR3Vn01VODG/U2X4Qz6qU6XmgttjgNe/5YgBaVOcvVUpTwbTyMwqyAbuET0VC2BLmI
# DATA R5qMujM5J6yVVHgrXem07K5n0DkJrM+IsZzF+ZQkKL0KLtS56PH1WXYR8VtzGFTtslrVr1e2K6ogf1Jq8Eo4XP+Y65mbK7zdFvKf
# DATA EYdjohdnVlZvVnk3BjFLo8vnosa7dYfpPu2nVhTaYVHicCc6NLmPxV03CbqrLpXD+p76vPluOV7PKnf8afOd3OcqmdlBtPk+6bc5
# DATA /fxpi6i8HDTVcu5ih9pq7hhitmi5F2oC/Oe2rGv+C7z13NXpeYB80nlezrOS2Ca79U0vIFY117x0ybnxz//4H0w6yhG38n/OEqXo
# DATA cybhPNdfVUuJvCctXUIiATZawlIMMyjBsxY11EpjqoUMZQrnc6qTrK9LHTNaH01iZws5/g891gX0j7QOLWtV8+KHFpk9ocqtDosr
# DATA n5fdMvOTz7pp5AerjeMMl1VSTM7oo5d0gX3BXFPoXgsEUFZtvVQR5RX1sgX09/9tcwHpSi/F8wGKgSpypgvos5OE2mhKHZunT/ll
# DATA ygShPmk5gyeShqR5zfuARnkYOdPkWAQpKA0sOABhg6OIu1UUkOwfVuUUaXULVVrPXiomBbdWLqZbuGyx/Pv/srlYVBcjpSJyoIMk
# DATA pcmIaTkzNRGWyzzN6bOmK+sqyydvHqJhDcV0EAXfEfXhyYkqoqIdydLsbBYXxkHrcryAEf3spWSn6NYKKu+XL93D/XZzSek+Xorq
# DATA 8zCdery7K+/iTnBN4DjDY2hhU8kcUcHw+gX6ukiG+9lQpDQiVo+FznQ0AwRHSkDNBvoRkzvihWhyYHes/TNTJ569fPJk3FrpPMsI
# DATA 9P/80+4j0DsYZKNUhgRLB3zKdjXFK32oLG1uUuGE1ctDb7qk8WcSptgnN4d8MjLa+5EYj2qAIRMJDANpNijxZy+JQnRfhqbyH3dt
# DATA Kg+S0cLro9qHKJ28W8MY36csmkLLBpoxAxp5MDlgRehw+NMQ+3NUjc9QWCnb4/E0nuC8AXIKKhVkqX+5jEWtBiqILKwiBagVoa+h
# DATA qRSScaUCKhqB4tG0jUBzRbL73seJ9j1qTSGefSifYJIKlREDdMKduC5YJfzzLOyg10PcxcG5nSvtCq405zl7TTxnl+V1vxDqjoX9
# DATA l9ux3TLnpoF0ga2aZFEesVNrI7n7BVWBfIlE0y7Shrb3Pd4ExXu1lVw7y3utjOgmovdqytVtRh1bnC+YBNU830hiszOpIr4jUYM8
# DATA SYzjIncyKWqfcghPAeU2Mn95QVe8ZSb4UsgCUjDYGSFJyMpa2GtqjdLn5jqZ62leSQv8Y3i6ZkeABgpgXHR7jBS4pSyowTdKM+vA
# DATA yInCrM5FRW0lUY99JmSxLqS0MO+B9e1hIy70No8L9UE2s0lm8XZVaKLO8gYv2oU6t5DDtdfJeLSDcOajMx93Nh/tuubWYd067DNa
# DATA jRuN1JtZh/1IuJ+2UnROPHw+pIrboITz3h9ULz42WFjmVD/leG1168p6Yb6QlC+PbVpbtJc37NWaTfeXHO2lpYRNTxXcvwWf9qYn
# DATA ym7Kspt103Nl71nZK7hx5bRQCrzJCjFFdRrGQ64PstD03be0fKUqFnUv+OWy51RY4uqcqSadlxfBcchc8/dsi8rT3Hvq1G2bSlxm
# DATA +tU7UMR5U8H0tNCAXl6EOBaaFkxCnaOnz5Slmkzst0RzPZ7IjJNN8EjPpAxEktqPWa1asqlAodEzeO5d3ZGgb7GHZ08JhPAEwJjs
# DATA 6qnPYYlL3yPrjkNxLfO+cooJhLuxQKOeuJOsFlw+b1zvNM7rWr63EBxP3UdRSZdK+GIG+KtjJVtwQJZCSqYFNuB/UBC/b87+Qv/+
# DATA +ewpMHxPPXxjLN83YP395exrQPlW6YD/7eyvTPz7vbr76dkfPQYF/u7sT+f/19kfzr46/yU9+ycV6B8VQvCP57/CNfrtm/Ofe/QF
# DATA REIBAYJMiDjIcwAWMjfwrw4G+DJY/YW+exSdkO3Ak+h5COlaBQFArz4dQT6iD8kujQGhjg+rsvcVVjfpM/NAdc993WnpPns559eg
# DATA CXF4ZGQMxH8SLZbzrQjA+5C68IbLDJtdqD07AGDB3te9xG3z/1aL5ebof2xhMWElv7VQ38o88zvRaTSPI7I29P3vqQseVIaA0E7S
# DATA a8YAsnoYI6GXCx7/1RktamKOBLhrEV4/CpD6GiyCU5ufxSN0OgyDZ4gztsulySNo6ER8dllMeRisqIXUuQ0W2MKwZOl/+TFTm0/0
# DATA 3hNd0cSlSpY4M24wjYuPZitYwN2r5WZbZ6XhPS844O6JcZBAZyFcn4Wg0YBXMgxeDyfgrRkFN2AT7GQSXNoiuF2DQKpoOTuMGfDC
# DATA tKqbQAJaqVbLXxuiqOFi7L54eOodpeFwGSroX5avPkDGsLjGxqjB4qLEqWz6xNL8MbuesNbGsojZPBpg5Dem2E5wQDOuszI3JTiT
# DATA fXSUgSPgy7gCVpNRFZWT+1mqQzUPKrY4PhuK5QAfHRPwVBwUWw3Jn6d0KeO1VFXaynyTRUKOLN9osq/mfRwBICcXZNPegyXMkDRZ
# DATA Ho295YyKaSFn2PnFmcMIOoygwwjeIEZw52Fop0nSZQ3qW50jXGWKcJ0zBEcVdFRBRxV0VEFHFXRUQUcVdFRBRxV0VEFHFXRUQUcV
# DATA dFRBRxV0VEFHFXRUQUcVdFRBRxV0VEFHFXRUQUcVdFRBRxV0VMEXhioYdaLhyL8iVdDvBlEzfImoguUV6J2YgkV4Xq9pwfM6dQPP
# DATA 6xTzdTiImsPRGvpeO7Dpe82cvtfubczbvGCmfr3rBX7H8/2m1+14vVbVbwWe3/SpvOhq0PG63RKWr9PudfvddVi+QpR5H+ZqfOmF
# DATA FvLQ75j4toqAyXrUHnTWPB8EQf58o54jE7u7Pd+QV6r8agV5fu32fLNlxb9h5feO7291LeRjs9G57Pv9tl3efh7/xo7xt+uLlC0/
# DATA 3tzt8XbHTr4Ne9wx++URlfx277LvL+ZefYfXXwYSKY1EQyKlL7MgkYNOOOz4RUikecRAIoN6o9/qFSCRQb/ZabdySOSgPqwPRwYS
# DATA 2Ry0u91mDokc+cN2d3TjkMgZ+vNq9vA0X+eQI5TH0TWsOwSWq0PbXGw/mNdqi7Bg+sjLaDaDaf2aPSwqw+1gatAuKtr3Vij2ndrK
# DATA 2Y1YWYioXvRQXEQpQX2PypLHu+ZarW1RDT07W9Rtnt7VUswbPWvFPvmCo7UEdNyyQ0HtR5B0VDP6YRodQPRyM6XR5EOllNwtpl+5
# DATA kCtby4udKabIxB5cqSZiPgW75BSH4CiQjgLpKJCOAukokI4C6SiQjgLpKJCOAukokI4C+ZpRIFchjtPw6C5MPerVccaMknxHvuqT
# DATA LMgEhVz8yFYUQKt6k56muvA+NkTu+ftvfvHG//7HGhMP76/VGeBn9iT8cC6HDfBGCmbfhBMgnP/1lYTzDlo8H1+ahrPlKGSdfjnV
# DATA JecRqTnP5egbDlWFglyIHtGNfPiTzIGMhrYCIbFwRsedvnen7y84fb/mCJc7i+/O4j/LWfyNepw3ekZfFBETPoicH/eWYeW7Rp/z
# DATA +cvH3IZWp4x2kFE1URjxAVllde5Np/uKkqhb6IwdILmgnw7CdGvmglG07LSKSpLTeCbrXnWlOsmrQEpvEvtt+NfNPEUzKNtV5bLx
# DATA tgIxUbevmdgHrXWRD6yodwsRr9dam6Nuxns76vqiqkd7w+gojWiqfkEKrLBMCuxrJgXttdnfsHPfD7Zk/kaFTt1KUKOlg3hZ1Tmt
# DATA EZd5iHRnKq1ZH3EvmH2YNy3WNxl6VYwj6/3TvJHbN7DIvsjnS3FH2UK6EnlS8IymSuRh8M39U0E5FvolrTvA+hU6NOpHyAhUBiLm
# DATA e3MxG4Yx5n78GDSEWVLjJDyVgUeKk8f+TAtrHC1DGnEWUcTS4ErY4kvq4Mj8wtF6JQqyJkY7CHi+egfWS6Ois6ydZX2BZV0ympxV
# DATA 7azqglW9ma30IilfFVtBaPLLiF/9EPw9o3aEVexc64j1ZOASrxj9JkEXR9M4m7MEjfeZoauw8c66ORE8cycRk1krnt6zgVEpmmMZ
# DATA P6VHUH/KFnWR4LgidmXuo6H//VhJH42TNP5ZYiRvlIJ/6GXhCHydKCWjiCWYTKlk8yRXSGeJIhaNUrOIKMxOeeQdJ9MIojw8myC7
# DATA ryKcDJHiwb00WtPAGsOE4M4qo9zCKoJSA8dWhQ1ThoJtM4x03D+EME+xA8TWCaXaAx5k3iEam2g5C9mwoXpV896OZwnqED2jMbva
# DATA EJhFjxZsSPKSCjJI9aNJBreV6mGVCSRVYMovs0Ch64yJtWn7WxuMMEmOdAo/xYlmKTepVoU5W4wFWah/xLlYkeEuiITX5FSp5XOP
# DATA nz2UmpaPG3pTpMi/Zqz/OoJUOydCK5Iy9JRxYR6fBQNuG9m7yLYl6hOR85JWEZ0qySyM1PMpd2GSRlEFE/nZfl4e7ADMjdNwYQTD
# DATA 8vGI8oIqLKVRJpxKT4myDLtcJ9hfwlUZR2hSu0KfZvCNc2weUQALMg7jIWiwNe/dhJskhj+jTAYROGUwjtD5pVZsVghIbFldqPtq
# DATA 4tIPVWEvLQV9s55imKTmigwSp3JBi+yryVnxef6xOPXSi1OFaVWdp0CqP8v7MiYWSM3NofZKZv+Z3ucb8sQkPFXo8KKpklFPeL3v
# DATA DHgIZVzPMJ5K/3O9b8A2xXsf67EDaZpHs0E8ud638B7u93QL0ktodg96ve9rCcBiFJk9Q9Tw2JacUWsrvuvOcnJjDNpXb37lSLRu
# DATA arW7ZLCbSL3yE6nLomdfLAlhs6f3Jhim5cy+doLpGqXji/mlkwJBQTSA2Q1Z1BXegtd9sXSUX0YJ0R1xC15hY7k2wnO5VckXM9mo
# DATA rUyO82lvxTuCQnM+p8EszAsxAcZWKzMPHdAU2NaPFdVWTJqyRWlWmnsTSp4EbX+LgG6h1pL1chxdLCSNOjkN5xrksFMZrCnRT9KI
# DATA PeoFNewsyjLNKnyNTLeccNUPH0ZpAW/1X8++BnXq/Odnf1EMqj8w5uqr83/LuKr/6Z3/PTBTZ79bhVv9J9CqGEgFjtXPz/+9d/b7
# DATA 89+c/fXs6/NfU6BPK97Z/6Bb/kzff4nv3tk3JjRQszYDr34JrhX91zGtXgaSLdVhPA9nA1UwlsAOGfcsQwRZWzGPBEO4JiBXrjon
# DATA zMnEpTFjpwX3SyMF5hnKpQR9nOyvFUYe9RwZe7q2IqzexgZatJMInYUDWNkGqHQCt02vKpfIzbGrIAk9LL13LbKKq5i58V2ucDcD
# DATA q6JRb642/aKWYpNwMgxPeR8h1Y+HkQNWXVRu186pehvNgEtgHqU4K8qK9TiON2LAtpy+9Mh2h5aJWgWxtuDp9X6I5R+l0TCO4I0G
# DATA o4D61CiFtytfTlH9Yjwjc2gpOexNl5n0Z2KGnQrVexDPoxWK1S41dbM9U2p6z4tetUsiHLfKWQFXtgI0puoKg/9r4Xm6pYH/2sf9
# DATA nYb9XUf92xr0pTIWU28G+efVWG6CPlVMojeOJnNYJ2R4AMFsIpcnOB2fLsZTrMhK0g9kqIXQO064LPgD0NLIFlkdpQ4TNKMPyMAP
# DATA j2mczHR2pCJtxlsPsCabLllLkeI/jQ0XaDt7Su2OgIcpwhJ1xGe6ZCDm2G8YzMXFYRkEjCfisSATE6KK9j8smBe8D1BvolAoIH4J
# DATA CygANUX/YE8F7Dy9Rr5cJJCHGjCpywGmHGDKAaZuDjB10Tiy01xmd1P3Fq32qxjt12OzO5KUI0k5kpQjSTmSlCNJOZKUI0k5kpQj
# DATA STmSlCNJOZKUI0k5kpQjSTmSlCNJOZKUI0k5kpQjSTmSlCNJOZKUI0k5kpQjSb0wJKl2o9kOOlckSY1Go9Zw8BKRpIorzztxpOxM
# DATA Cdpeo9P9stqs+t2u57ea1aAe0F/f8+mfZs+jr8UcGkTdfqO1yoPqdbwA1KeG59e706of0D9N9bUEgqJMrg/660BQfk8CpvTHNHBr
# DATA 9FHDQi81Wm2r6BUHSaBERXBV1AyjVrQS0WbH94IuJbvl+Y1g2uhW/WZLfVuJZ9Tvj9bGs7Fav+otr9lqjdt1/yO/GXjNrj9uab04
# DATA i4HVagbRuiBXa2y7STFt+D/qNad1L2hV6R+/Ow3oNVQsXXyuBl36svpD6aXdbrsRDLa89DKoI2khGnUkjc1CHfXrHT8YFlFHI/6f
# DATA jTqir+GoXkAdjfzhqO/nqKNOn7IqNKijYTho9Vo56qjbbNX91o2jjniHSZVND5slpCJbnH36GAk9+S81c3syYDONZGawDfLDI1f+
# DATA 5h3oQwUnXNs44WTpbRVQZIW96pDnEVa2zdFD0cNd4UTa0gjKAXiXGK+3PLZ98N4IIbJK0PYFemJCb05PqXA7KNWOKtpi/mxOjiMJ
# DATA OZKQIwk5kpAjCTmSkCMJOZKQIwk5kpAjCTmS0GtPEhopjhAfvaIEV07ujr4jl8anQ1k9BOyHjJtKZn7KQrYo+eqpuXoaUY+sLmv6
# DATA 0PsIlwlCozcph46YD/Q5xVAunhRBROr3BxQ8/5yt/fmDGUSRYCzQ+/i+07X3fZYswomc7+O7PgoX4xr7DfZGb568mb15qm62OUP5
# DATA SRZ3VNodlS4elbbONbkD0+7A9GYpvxfgIDXOpI7yah6eeiF+L8ibL1j5ROozSsBIhKPeVPAzZPMmk+Rk+1nfafyIjx/P0yQZ6fPH
# DATA 0Bk3DZXGX2xFWaZR9gza5jQipqdIyoKyBOnTxy3ve9lyjk41GqoWHWeGfESWjQIbpTTgoXZCTm8SL7CIk9DkIWMlbAGZDNLltH8I
# DATA bZh4xuexM3OoegRn7zGf3/0cLtyCgknKmu6ioJ0NkoSfGCznkNmWc83bFLTfgQ2Rnso+Oo+HqDxpI4isQwUQQXKpzqJomOnuTNKb
# DATA LVIxl6kcx8lkyGddEXNKLM2BWQ4cpTLCb0cU5ckpC4WbbDNlJ8o6LJOOU+laFZ3TgIncJFkg6XSpn5xMvHCSJXwweKtE+PtUvbnp
# DATA yLFtemuUWoXHgs19tjY5u/TNcaZP0Z+gLqJ7ZnGfCc73oh+veayonvfkA2xIiSCPHk/4ZC7Oxmc17x1Wa+a662lADaoDRR6hIrXh
# DATA EBuBOCxzDFGp+oeLi0TdOec4zic0kBhdQWxHxfl3D0dp8DJqOuGUX0cDHZeOkoQfLBdSuNhWM1engUUn3pz3xpVJrChcqBY/g0w9
# DATA w3Eyo2j+UMIT/wqHSKbhxM6S2JznDtPp1XTN3xYhamQdNf5LC5ujEV63svmnyHwU3gjOaemdbkDQPGdbiuARioINUS/XI7gBTXOj
# DATA zMhGzUy1PXSzGPNuQOL8Pnf7xlZSahK3pwT+6hzkzgNxMwo3oyjOKMpVyk0r3LRi5+nDxunHzU0rHiArchyOREdPKV54bcDbQJSK
# DATA I40us+fL2zu6CIupHzAdlrmQ0znqVwGS1jdjPXPXHt3yff3F2/v2RZG1HzQRLlzMKZ7ddXFutqwo93YlqLK/kQklk8UOsVS354hX
# DATA 9b1gUq1Ezc7MRpGQuiVq4vSknwteyR0iqR80sTQXcru21rkoosG2iG4Eocr8FaOV1dJeXhqqNLU4K4odGc3S96lvodbhHZm5eMVr
# DATA d7/tmXrrTcmkzrxGU91zAv80zfJpIh0dpego+SmNzML0W7hZfCN3R/xV6bDJzNRATmNWq40HpqvDG6NHsmaipwxYBsOkHmGVpMxY
# DATA nsvqy7SAbSasMnlaViEw6c+nJRI7dfog0ipoO1BOXx3b29F3nO293ZvvDO1X0tC+LGXnOQuh8g7gfIPsqgFqQ2hYdDDUHmyjFypJ
# DATA 2Eyhea7yqS+FrCD/95qZRiWh1+smGq1I5a7lGe0gXmvto84lbPEtgnBlEo4qhqDDVtYyGysDq1RPsVNcSlbtFn9r3Lj3fhpj3Qa7
# DATA FNmLSJfAqI8fwYZh77+c52LaYVw0d2gCiVlgtG7ZRalqipCp6JOqgwy8hUuZPEUDhqallkfVWC0muna8H2DNCjEn+64Uc5HdNYsq
# DATA FDtevzBtQjRG9bKMYpDiOBm2Z1urRSyfyktPOIu4JcJo9jvGlo+1zRKm/3J8H2AlSC3Q6elzVBRHDYsLe7xkMjGrfhRHBZ/ECgQW
# DATA wTZHlF62Ll9fG+1OixxEhtsAHB6LHfQfz74++9PZN+e/OHsK6M/ZH85/w1Af0IN+wQyfn9NvoAv9dhUetPLw2V/OfwPc0C/O/nr+
# DATA 87Ovzn5PP/6aGUR/rHj06euzP1bpiacI2uN7vqF76B2CFtoIE6LQ8Zav6A10owMKvfgW9Q+hX8brxNybKFrYaUUWBHFJOlq1OzWN
# DATA jsBf1nLOsvCv6qsZ3FMWbS5Qpqk33soQemcciqqBJRnuOEKWda26hNsmCa0rl5ujCfGGgHEyNzd+ri6sZwqN4rybfj9eGE/wNdOE
# DATA BGrM9oL4iiyiz+vOEdqlxK6dJnTfE/A6QODVxbIfmZIXD36MPbRTT3aC17yPEqoBMwNCpEI8ht47JD2wRsAaHjDLQrXZJcTniWz6
# DATA SOE+nDKPUZx1bHwJrBEisWV40PYqudmIWdPOnhc6aHsSHDTIjfSXGek1J+iKA/zr4Tq7rcH9Rsb2nYb2y43sNz+wS7VczYF8o+vt
# DATA tZabAAXlKYOIFgWQrcZ5AY8bNmvqzX86vkuTdj7kxDgRXYAgwMT8O/NNsATGtBW1JZTfMg1nlLrMpFtSa4IXzNB0Tl3YbLETNgj2
# DATA 1QIH+ZEPFNIopd4uH/RjWe7XC1sIhsXkGGJkCEBpJFllkMinAlSuWCN9AsxPMhJ0MV5EFdF7sECyY/Z4xCOPWtVDoaGcUEeBPYNo
# DATA g7zBIEXeaYeoowc5epCjB90gPWi3MWVHqPnFNu8tG+9Xsd2f1XR37CDHDnLsIMcOcuwgxw5y7CDHDnLsIMcOcuwgxw5y7CDHDnLs
# DATA IMcOcuwgxw5y7CDHDnLsIMcOcuwgxw5y7CDHDnLsIMcOemHYQVF9VB8FV2QH+d3GoFV/idhBq+vOO/GDjkySeRdhkTUzbEXDUX0T
# DATA a+beW4M4hf0vYJ9AEqLAPh0WaWB5A99XhKHC7e1684LbLc4Phe3RPR79VvV79LdO//Za36frE79Xp2ttL/CbdK1d7fSqQTMYN3sf
# DATA BQAWdbrjTnPqN1rVZmvcXheTZrAp4gpgdOeoUIGagY/I0BumVd+rHwuiZ0s2RqN+r70ekVRfqZ4U51ZQH7eb9Y+Q6mavddysT5v1
# DATA ZrVZp09lBFEv7PTb64IOLk8DkjqvaUDSfCwaECVj0GkUaUB+p9Ft9mwaUFBvdlvDAg0o6LYa7TCnAfVHw+ZwaGhArUan341yGtBo
# DATA NBh1BzdNA1JGyXrHh05rydZSIxE2rlW3WyEe3YxhJ7+3DP4xE6V1kyLtRsNct9KsNZn/EzD/Z3U9ql2MlDZurG5abBdOCOV4mFaP
# DATA MDUGz6I+jI4q1tq7/dkLevNHlW816q1Ou89uv/3K5pB6lwxKRzmbR4PLUom0zQvv4YpJZa3IbV4cV0vh4hOuZvTDNDoYhunDzeyh
# DATA PIcrdtQ32xwls1fqENtOjiTkSEKOJORIQo4k5EhCjiTkSEKOJORIQo4k5EhCry1JSJF+PrOOdeXnuYvnuMoYHuEGySlvyiNNF8KO
# DATA ADQj0HkG0xrDfN5JpiyAvnLIm4+3YSlJ1KpCHFRJZur4mhakLR4UkzYqEzl90sKdcXZnnAtHbdxRZ3fU+YpHnTeKD97MEej3Y9a6
# DATA 4LO07IIsn57VR6FfNLmN29DjVoMLqg7VVyUZjlTuDaYXSTSbZ02HlV8xIs3dtdrcLVuk2ffrRZnm1hapax78IOmiei++8JbYskZF
# DATA We7JBa71Q28l3JnaEtJtXu75lPo+hRfievLWnUSJBK55os3ZRWOLd8dbpNFD1oq88LEWv8g2A6YwaFg+ufjsHUnNDkLV7+n6iSrr
# DATA ocq+vCrVH0VhtoRoNA7WDsI0F6h+sBBJPupJkmQhN8ixZsj6hEcQe4Y/6oTGrJr3Qx7cJtExVRp0gOhUpypsbsYKTpOkRngoTcic
# DATA rHmf8gKAmEbyAOstKmE/Gk5OUdBUEPGiIF8NmFbh2L6cI/XSJc5448h1iAP20HA04zn0A8liozrLhZ/R7GyZzSPRP2TF7HC2HGEg
# DATA TjGXkgDBRRrGoxGuLPuspx5jnKbAGLuzztZTIgSUhMXOAtevyjlfJ2/tzFfLfHX26mthr15W2/o5S/bwuna+ALtd2/o+jUZsNLIB
# DATA yXZslktRMEch26JxfdtiPy+F3sVNyFqv1utrl7Zeq+l0VXnrfNFfm2NiUSjbJwJZlOtcLmrN5s8pmTQC1OSlIHpdzXtbdINoliRi
# DATA NVE4g4nyOUSERO4lw+DGmFEhOHJ1gxlFVleshZ/JhkvI5iGj7iG9QRNDLldxfqCFWIyqk3GHv16KJ4WcccaQM4ZKfarz5jlvXrHv
# DATA 3GhFPWdBQ+YBA1ycTCais18Gdqt2Ema5hF/Ne1843WwlrZPnK2j5zdNkEA1B4xYpuiT9chmJL+dZ+Nz3YwN1NjTeBY2gmgk4jReC
# DATA mpaR1GMtF47Bkhv5Ubg8olHzUxqGNS2wwgGIWSLLPQrvgA4jHI3gFGNXSe7yNOP0BzOM9wvh1y4VLSKa9qMhRNCGUT+lEVmoyDyE
# DATA sgggdihtRVnL6J/LMwoOOKSqAD8oawoq0yDT1gWU4+CvScVZqsSnyQYYTqJ+mNa8D2E/IZpUSSlzQwUCG4boYIBE6E9EeG3Mwnjr
# DATA hAz5Y2apFopLNgP1+ksq+HgEnbdphLW/eLAVRj5mVWuuPLMFPDjsRTZJ/hxQjmQ08o5oyNJJlH2S3mRJmToIodjI9Rh49fAkPBXH
# DATA lI6nKsNMu3U4+3gcoGBUzClfMlHghn+JVbgPlawhpDBTPlmgKq6pzgWwxgL1h3kjXp8iEG30OqtU80gjYwtkwpkPngtVQ3DKtCwy
# DATA YxJKfAwyCcs/xRP6uaL9UJyAHLYzCNP0lJUb71Oehey3UwEJYV7gcZrjcxyyJF+eSR9HMadK/MRK/RIuuaMkGVrudnlrQg2NRsOR
# DATA tLViEV4N9o22fMqqj9THfPfSsG/E7bph32KXx9LAlX5hPAM4PhreAPT7bTDvlVyo2jpyA4zvz0sqpDfyJoZ7f4imIX0MjWuyLScT
# DATA Ys71vo1PAX1uKIlYIZqHceo9hLc4XE3dTRLFX42pjgWXScJ0eATfuo2X+c8KI/MNQ11Ah/naO3t69k/nPz//zSpP5r/SfX84+50g
# DATA X/guJr+ACvPN2Z/p41fMknla8Qxf5unZn86+Aq7mKX6q6qeeevT1Kx0U3UYv/OX5rxRchuJx/vceM2Z+BzYNKDQOKvMSYBpnmtm1
# DATA 4oubRwkQ0GrkXojA9Dt6viZ+jyPeto1BTkHDWLuX5YVzcpcZ+Ch6eihczoZbKTP3+Zb8zY4xU5jNmZ7htikzq+Vyc4wZTqC563sQ
# DATA Eqe8nozK9w2h/WyAXtjvu0jD0+tEy1AbyMjGTkXAnGYasMZ4JoaCcHCZ7UV17VQZ0wkNYzLj+cSemDpkvuIpiNzHjzyuF96nvD1A
# DATA 3LZH2B+5blO5sA+h0a6VvlFms2jBmubY+0FjeLbCkNlW8zbbKStt6HnxY7ZF39Fj3JD+TEO6xslcaSR/PXyytzeK38AgvtMYvuMQ
# DATA ftMjuNTFcrLzbZPPscXcBFKmnNCcLGM0J/KYU25GoULMwP3GcgPwdM2oSDNZrUUyDD9DhlWgJ47jlHExKCyNlaGUhxku4si4IQpj
# DATA NVQG1ktAZE5hbbFvV0I8km1mmCbQx/5EPG5HacTnASTb9VY35Vun0R9SCPz9Qh7JIcZ/zpLUshmKmJEodbAYB4txsJgbhMVcMGbs
# DATA hoS/0LK9VfP8SpzqZzLOHR/G8WEcH8bxYRwfxvFhHB/G8WEcH8bxYRwfxvFhHB/G8WEcH8bxYRwfxvFhHB/G8WEcH8bxYRwfxvFh
# DATA HB/G8WEcH8bxYV4YPky70+w361fkw4xGo2A4eon4MOU1553oMHa2NOqe3+qMG53GcdBrfp++F3Ok3+l0msPV7GwFnt+tU4Z2joNm
# DATA +/v0vfgc1c1uX3FZuCylrKTgToXDEhR0JZq9Yhk3m6WI9KNepxxgEDSuGuCw3gs67ZUAu8H1xrDR9K83hk2pOtcXQ7tQqCyvIQ+t
# DATA QrlkgBtK2SqUa4mhXSjXEkO7UK4lhnahNCTw62splwzw4pZyLTG0C+VaYmgXyrXEsFAoreb1tpRLBnhxS7mWGBYK5TpiWCiU64hh
# DATA K7Dacq9Yyn6jFKK6kKrcLw/+7ahRQnG1e82wuRaWtg461mo1LOiYhJ8aJJhlpOhQV/hpQevZAmh1e1YArd7lAygkodd+xiTsFsBl
# DATA eGZio2memZh7Fs8sbLabjajIMxvx/2yeGX3tRaMCzyzqDsP+MOeZdfrtdqtteGbD9sAPuznPrDtohsGN88yU10NtaDAzIXHGky3J
# DATA DgrLe6EXqc38rMsrlWsW/Yshlzlm34vIiI3DisSktBdlTXC2I5IXeYqhq3Xfi6Nhpi/rd8np22lyfBTttlTU2mVx2gq1vOps+0x0
# DATA HSm6nQOZyK+sHvoNa5FY3esHRS+Mrq68x3IcDpMTXojBilvd03XOytseOyx4Vmxmcxv20+lJrMrt+mYGmp2nF3g0rNwq1UmeLAcO
# DATA hOZAaA6E5kBoDoTmQGgOhOZAaA6E5kBoDoTmQGivNwjtsardMRXcXYUyw2dKdIWTpC7i6B4yQm4X1c271LFRndlD1Yrv1g/jt/iJ
# DATA w/jNN/cf4yLfdhiP9k7iGVlXZIedzhfJd2HEfwooxvRHHM7+Y92C5ncZtMYgkL1m0Gv22p2g177DUdr/Dv9RUejfhQ34Q5q9NwLp
# DATA eP39w2HyWN5RfsVef//wCctm7vV/XP/Jvbv0rv1DkXzDhW9z0G/6h08iMtaVFpwVF+G/cYB7Kh77dLdSH50vadRT3d4TiR4qx131
# DATA 80+TeLbHvRXlIPhwaAxvqh9lgXZvL6z0qTjCN/sVsh5zS16ldhLf3WjNTmIUzCS2K+RdaR5UbvQmSRvNHPFatvFlRoAD5Gj3c2wl
# DATA mA33JvH+oeRR8XdelaaJu+qK7/n1/eINGIJVfN7BvTU5PU2V7YlG1pmjn05ZxSmrrCqrmMPATl3FqatcUl1loyj2DaiufAo5Lq0A
# DATA MklY74M1u4zwyvMV8roNOh2bAnRVPEFeMuLEXIClUw/lPZL6XlCTXSHS+RaQrm3j6PwtMDo2X1D18QHzDxRFCUan7slhdPqhFUZc
# DATA W4J6JCbSZpYcj0nvwbt+0Z2+qAGTBXrRjayw+9lJNKFO9IJ7g7q6d0YmcOne3dF1XL3RyrlEX1pq3d9qRoOMRxlZD9HQSO0ZeR0y
# DATA sowsjpjvZakdJsntJtvDIjZelixTsHxHglOB/rZYjdBwyPl04rUgI3GmZHwoiaeeOnRvxGLonStqMePGPVv/h9LUoIKZ6EJhi8zO
# DATA TWujriqByU60uVdBMSQfS5zR6YzOVaMzty6c1emszuxCe/K5af09YNQQR5Jd3ECOovobo9MAyabxIE0sCbwlW6hK/y6k1jUbgG6x
# DATA qn1nBsW8RanBUENKWEpukEynUTqI9RjIlmsaYaUFGxd21v7jlM3vPRBvVf8UPrMIu0wwjBqAkrB/aTDFXoo1+lvqvNuqiarcs6iJ
# DATA /EkZp8rm0D/mBpC5wgefgU6LOBwVP1luEMFBHfm1tqfx+YITpD4XLU/rDtNR2k+tGHZwmqItgDUl98Xb7EBtnL/LBtymuwYJiBvU
# DATA XI755nfyr5uf4UqEuz/Bhy3WpQzM2sITF6ptkmCQ2GLeFUoYez6kQaujnTnSgTolw+5gj7Ws7qi8tPOihAPi3TCmnYszmGtTuuTb
# DATA g3/++f/dNqkoR1vlrDLFlFQlVZB0cSrGGNl3PDKByaMtSR6EaNpXhd015Pmid384hDQePS0soAEaG9V+nigyPxnsFTzI5p+MjkxE
# DATA 0cRk2Kb0lpr3djjLqYCzoUxK5af3QYTBSxp1GmQNJUgfO7lSvpZqzxWyt7k5ewt1UXIZ9rLY8JSQRTjR+XyfeTI0SMwrkmt6Ys25
# DATA FmITwCKeRjaUbT5Z8uyZ5pdLseiZgKQ8+t79eIq8GpG1lo0Bq2LTG5f8AF/nScYmes17D/BFvGYYZ4NlhgLikGRR8jpy2bS3y+bv
# DATA 5rxVLVfnKnp86noX+KDz9F3s7Qm9xv/+xwZYSUPKEywezMAzPwE+iOrWkvKOykKm+JnnU4H24LSQ9ZdBRHOQmvcJddk09b4vFVuq
# DATA LwhQzEni84oe3BuH3tv2HThDKO4SnkmrTV417/v0NeKKTOV/bRX5ylm8vYcoZPPnNNDSJIOCSHUeG3N2RA2/KnpOOQsM2oFUv1CZ
# DATA 5pKHsuKTSV8gd6OSwk8TKvQ4JoTy4MfQLsXJwIx1S0MTSDjTUKqKvIx+wxKKxI0z/SgWyVPwyI7jhFqIejiUnufF6Dzal+o8/vUy
# DATA 5pVPPXjrQpAMpvpLYxwqNldAtoG0YSTTIWS7l03iOeUnNw7uWwA64+lNn/VNtUcQCqoY1UWJlbsm7yhaSNFxFmIhMUumES4cLSPu
# DATA OPB0PJOJCvVLi2vpPm5+8HuHxyUwkWJTtU23KG6NxUkiHbJkLXrjTBCaIpQcxSmNbicIRddjlrGNjcIvTdfR9FPV8skWZFVnvJO6
# DATA JpxWpN76WE3uKGw8MU2wkMtzB/QUjJ2Q7gU2azlzi+aKLBvb5oq5Ipl1jxqYWuDVQsIyfoupaJmv1NzG3PCkUGoXsZ5eBZdLPtty
# DATA LhfncllDUHBellffy7LRgfJCERUKRwVWR8qJzVrwJvECR5xZCYWRmKBYqtGEXTD5g3yehDP2eSMYXmSt8ov4SdbBD1mV5KMv996i
# DATA jrTc3vTR98Lxuq6c5bPO5cuFcCLdYRknsXIkXdrvIEHtkLedzgY6KkrlMfe72WL2XB5rwBzWc/yF06NWYsbBvQdsk5sqAghyODs1
# DATA q1bfT06AQz5Vdee7Hl9YwjtFVtV3vXfo/og6UxhDMEJyS/i7mITFU65ws+xEZg8LbLTzeOmY9fdjRXTVbCrAaEOyzcDHhXYZGV79
# DATA 5FG0wosq1pb3YwZmsgOSsmM5WFAipdhfhyUnm3OZMI/bplz+J8ZS/ncgJ89/64FIefb7sz+efbVKuCzd+dcceIn7K975L+jaU/rv
# DATA N2d/9M5/ff7Ls6/xBO59itv/JAhMuv2bs9+f/zvAKz368HO67c9yq+NYvgQmm5ex3z9VBxBNX49E8+Sce4KaJ7vlvWwpE1bZkM/c
# DATA WnmQGzDGDB5M2CMwk2nUCBNWbnDwk2FpYcyb57dQLN8WGTBBZTiEZdGEk0Z/2wDLUpHcHL0SdsCx1d2riscUdPmp/ISqguaJT1WV
# DATA RBWcwSN2rUBL3i0xDjP21wD9oxzlyoJxUMtdS/Da8Zb3YZceia1i2NEV7jaHcLBpQJDps8TQfjcejeIBNuRj27LsuIk0A1zfOoso
# DATA DPo5FXf/CtFypzq42Swptq7nxbXcKREOcOnG+mcY6zXe8vJD/Gviobml4f26R/edBvdLj+23NrRLtSxkQ465fG7t5iYgl4U0Ykoe
# DATA FhOGbaWSAAQ7nS9kKJyn6HrAqRuH/ZgX/haZLjV64ugICywPqRpkMo+neqyWuTHdlpHZjMCTmCoklr+E8JdB8S/dFXGJbDRMQEwb
# DATA KP4T6upxhg1rIArtqGPP215XsJKqJlULxoIsCHEsWSIFoSAPkQFY+cyq8yitslVHJbCcci97aJkJuBFRrpLBttFscAxMx8B0DMwb
# DATA YWDuPMDsNJO5hD18e6b9VSz7azLsHRzTwTEdHNPBMR0c08ExHRzTwTEdHNPBMR0c08ExHRzTwTEdHNPBMR0c08ExHRzTwTEdHNPB
# DATA MR0c08ExHRzTwTEdHNPBMV8YOGbQbkTM3LoiHLMX9V4iOGZh5XknMqaFevNbOWWxUaSKdUoZ3pDfJceLyLJmt13vrMlwYDfbwbjZ
# DATA nFabTc/vjgV1ZoHHyjSyHDzWWIG+1a24lpBqK3GttzfFtd9vd1vhSlyDgOLabV9XXHtWXDvdrXFVMLu1cW32u/xrMa4Nv+4FVH+v
# DATA J66N7rXUgc6g2w79lbg269dZB5qda6kDw044bK/W12bvOutAq30tdaDT7vY7/ZW4trrPXges4Ci0Zrszbjfqx377+90SHpc61EHr
# DATA ahA76ks1xE66ZQti12xTt9HdAWI3HLWKELtm1BzWc4hdq9NudVoGYjfoDqL+IIfYNXqtbie4cYgd9lBVZXVDj65Ni19n0eq6bHPm
# DATA 91+OS1d2ujbypda2OF05ZD6nspsvtb3Nl6rnhHmgq6syytespxmYKKgpV6+1QoeDTw0LTvKfBv9uuHDxjOqU1xUynFSGZpFOp2rN
# DATA Osre1YhxsmKgFnHXFoFx7ZX9BRthc1YJbLFNV2uM48s5vpzjyzm+nOPLOb6c48s5vpzjyzm+nOPLOb6c48sZvhyrNyqUHPs8KdHf
# DATA ka98eI++3tG/CmiOjc0v3nhPHf8bmpOQOKzHJDNmsg2ieLLHoTNZTfQzs9oX9L/Z/QVuk2DVDwrApr4xHEaHO6QJt8cneNYEfqcc
# DATA CgdjPZrxiGBwZ04H0R2033zQ3h2wf4UP2F9W/fCFOXifO7a2qyGyyBufZp3RCEWWBQSWx/R9mxbi8z2n/5KdWL1IfSd3VN6ENmJJ
# DATA heCahRHLOg4XqCLeV4AeFkOgXKU2lHFgRlrokyW8MbyDwTtaAgrWj5gNFlqq39A9oMk6xmnvfbqaQOReqx+KTBQjGpS6AtXbRAs4
# DATA y4lyrupKvAHZz2fKcQ69LxUCT6PORY/mMq1QKtNl1cOtSkqlJgfvtQ2/YNXtBwmNdGN1Wl02v2rx7Y9DyC0amf40OglTHKhXgqIn
# DATA 4USO5oeqgnoTJIQ5CexAj8NUhCkk8sXz0IuQRVJ/sFwgSeYQdFmjfDWOOpcNtWEmJcEUG+4gsAnDw5dhFBop9TBjlQYlrBUynoZP
# DATA q8eLLdH7ANSbS0QOvYiJmCWkoSsSBDAzKvwwVQCDZJIpHqOh6XAw6UPvBL0Qxxen7bdE8hN5zZpMfI1OrNuhOBvZ2chlG7lUq5ws
# DATA lZOluop1vNEavzG5qu/F3AbYSAiV0JNWsKEce2hpV92yJuJtwIHFucMQHFiPaYScg0rldjywfsz0TuZCTrht1i9CBDfqYsjuQAkW
# DATA rxOQvcbBxJfYJYSXXxBh/byJsLmQR7i1PsISRxVlvxzl+uY4s2vMrrqoWnv84jvimdq/MJuLFGb9PY9zsDbOratGWTvM6IaP1vvc
# DATA LohxHoCJtHXJyuu10bZiraqPjnSrEOeNQOS3l/FkaI1o6C1eXi7yRzIMy+gezvnoDS9g67mUASdz78WnRJQ6lCR/TA9F4HHd90bR
# DATA Cbu02XG8MB5V6GCtEZI/Slmozoz/s+hYM6+MBNgPVb+uu0IA10Jg0bF/lg3ymvd/kqUw5HkP9YxWN0tm/xA7g0R1TTMyxZUtHSk3
# DATA FkqRvJlND0zpaJohHLh4sWnK9gob4fbo6oxwZ4SvOKpXrC1nhzs7fJtZ/eLIxqrBTjcD9oGhLdgq8MDt0FhlWuFxPtQpidJKrmLK
# DATA Q40ROIVeJ/ZWYdRB4HOR7MTwqpyIaHMjAaJky1gwM3IYZJPm6pXpyflLuWFDAr+PSqFnETQ6Dx0/eRd+8ox9qHhCvKmb7xR3skwh
# DATA 8GkLOVm7FS3nHyi2Lz5BOc+NS2IkP9uMkNT5KhDJ+wXPPVzaVGUApU0jFFMJmJpGR5Rjxj/LflhBYtF/Rpg7K/VZqpEZ30i3zRYx
# DATA TZhlBYLnyjXvnTBNTyHKmsyK7vE0ZGYjW62L9FR5iVmUFXsgU4kYfObJTPvJ1eTBbqT56o9uIvnqktkDKaP8luSb/NUqinSBN/ty
# DATA wwzBODUzkWdiheZV+ZLF/N7mYtaNQhWzcfrnSzKy14J7DF3QH6KLhZETCpM1JYtdr3JkFrJetABEKZqXXiTwbJKcTE5FEjplZWN0
# DATA rhiLzFIPlTlv4EMHOTa94jMV4fak3VohFnqZS5bjp1tgxnl/pVusoEeURHIagcVKQ85sqMTAuSQ1CSxvp8M4pFnglA3UUbQ4pfF0
# DATA iTyOlfMq1C1Z4cbMZJ4XXWh0zflomVnCocH3EWak7HNjDxgWCGMBrj1z29yW0Fsr1yv3wQ927oOpwi7oFqHrRt6M2dvZw9OV/lez
# DATA baRYYdWI0DQbGeNoGmdz1r72PuQeM2QvwSRMjyArDWXGWaY59SdJKv2rtBXpXEchEMlwC1xLu1yfqhe/W/3+zt2qGrvIvoK8PpIa
# DATA qoFqGGqCtWmSsu6N7jLRxqLYofC28Ok4iOOgKBXfOj6awdUjE1FtYcKxwtLgMDrTecp69dTrSjFzPK6j7e2QsJeia333Ul2rlnWH
# DATA YTJMwxM0EN6dMIlH1kK1cq7pO5T1EIXYFkqZA9l7sXdsewYzGi4sbfIMlouaxy4/s5attgcM0nCOPOcjoXo/hfaQPVu5bk3hlUr0
# DATA dgHez+ShffV9ijkCcxDRaB8PsiIC8+vzn599dfbns6fnv6bPvwDPEtjKP9OfX4Bjef5zfXEdFvObsz/R/78+++P5PzDu8vzfMBTz
# DATA z4LE5KB/T1d+zfzMPzI50zv/1fnfA6B5/iumY1LYZ386//cUxK/o72/pnRQCbvoF/fAH+pnu+Sd6ydOzv5z/xmEyXwpHKbalobtS
# DATA 3aKqeRx0diC+KB7C+jQ9qPD3I2x2hxd1AGSdArUch+y5Cs0UwfhcQw9euMG45r33aD6B+UKdKQoLsVYGTa4OvJWf+c6Exi9piYif
# DATA I2jaPlTdZ9w2QXOlUG6OocmV0tyFrYW8pq48gCvETaracWJuf8BfPYh2LScQCbtOgGacSVTgPZSdjRHO/IbgB51GC0fP3KXsboCc
# DATA yaukvFoeTzHVRWimAqjuaRHxEbUB6jEf6/c+isJsqZZvKceWgEIxXQElR32l8T1nzBnyFvEkUi7rlP3lZCANl5NVnOZuVXKzpVNu
# DATA a8+LqLlbOhxS09kFN2EXaNbmVcyB12I59dZMgeu3BHYyBC5lB9yeGSD1spQLNm7zRWtTN8HhLCWfEw03NbMLTWTK8E2tUJxnzjGc
# DATA GBPF47QP0nBu8dKzUf7LAXz6bcgM8eVofGX2MFoM4PfeFceZj/iWxUCRy/Lhfyp2whD78qAaBYUaiq8nIfLJmoI9wAvfFLdkWFV+
# DATA fLTzLON9ZB7v4RJbRDsVaVRCcsUfpWidvFGC3VahWUZz6E2H3nTozRtBb+401uw0BbqM0XybU4CrzACuawLg0JsOvenQmw696dCb
# DATA Dr3p0JsOvenQmw696dCbDr3p0JsOvenQmw696dCbDr3p0JsOvenQmw696dCbDr3p0JsOvenQmw69+cKgNxut5rAdXBW92R51Rt2X
# DATA CL1ZWnzeCb5Jocc0LHoDkRnrcV4OToVu2MszNmiKDhX/ErSL/MLecBR1V3MZTMCgMfaD1pfVrtfyvcD3/HqP/zRa1W7TI/u42mtU
# DATA W9VOr+oHbS/oVTuB53foS6NYGO1ut9WL5B3FOAfNII8zvS+PczvIoyxkUatitBrtaBVl2el5fqsz7nYnVb9O0et82aPIthvVgH5o
# DATA d6u+3612qq1W1W/2SrXFjwaRX2Ie9tvhKAzWMQ+b65LSlNgPVIw7FoSxaSWlWMeH3cGgv4bI6He9RtD9stuuNikljZ5XpzR1PT+o
# DATA f1mlsmg0KYW+V0IrhlGn2V4bt1a3k8eNArayuWfVjHqRFuk3B832FUiN3PQ0qVFasUVqpLgMeruQGgtXQGoMom40tEiNYXvYGeak
# DATA xs4wGIYWqdFvDbqNGyc1Ym97dZtJQwOu5eMS29g8pC0ZG0qIVI780oy42f22h3/J1PDY3MiD0OOttcQov7I5uaPXP7Dit3YuwSFC
# DATA UNj2+ddxN89BtGl6aBngBVeoKvfLgRXF/ZVDIUt50qI8oX8b8m9htarZMtjITuvbawmPYixSmmXOly+XWgtY6xGOG1GNF1YGbU+u
# DATA rwWSKYFdfDuHUyoansWWJkOOA+k4kI4D6TiQjgPpOJCOA+k4kI4D6TiQjgPpOJCOAzkK0bjv+lXhKcqmY8AfyZrRyMcH+rz7SaT8
# DATA mYx73FO4SFzAExIUqur72Oi35zOScTAV9mMhEDVXtUKRKxcHIyKyEE9Wx+nlqL03j6NBpE8j4owc/Id9lEeRA5mfvHGnw93p8J1P
# DATA h5ePaLmD4u6g+Hbd7RfmAPmD+JE0oQqNT7NTLPnHcsjSBt+YI4+WaCqazEQOdeLZh6unnnEUlHtedXZ6hFDkZGYWTqJLymcbVUtx
# DATA PXITp5uTKVyj9jlvp5y9i3I27yjhqogPm+9Df4nbfkR/t2hm06C4EPzhJ/LxZdDLNnlwSZHItzeLRKrcFIHIt3GKc4Rj3RiUcj1I
# DATA bJbxyHKnqoLz4DidDy4rTXlOIeA5iUdygjlZMAUi46EJLigE440iqkcTGEQ0YUnk4DGnRBNRnkU786pZ8s6OWfKe1gSlMVlnyNvh
# DATA BLoCrNXL0aXGxBfMmWtZwmFZUW8E7zI9jZziBRKe14E5R0Mz/lATJOsvlpP5CGx2HRmj28El8+VHm/NFWpSqKcshWyZ5HZmFKc1J
# DATA vRnNaT30MwwGhXQrFiQgM5DDf2DRcJWKZkIogyBBxhwR+jxHf398qo2b51hH/tWOdeSTZMkaFj9dHuX5odWm51p9OpmOsGkEmAbq
# DATA BOaYXqFBMM1IYYyGZGrQYDagjJuMkyVOvNW8zzAhYG0FVkoQu+5oEv7MCHU8o/ps3hVeMn8+2aI9qztVySGaX3tzfUly6JM0OUYd
# DATA oDTT7OYoMuhY3iRHlSZcDqDCcX/mLWdIru5hIBDMQFRgmSZQ3odUNC8uP8d28+mO7YYrtVJusZC1rMgwTZZQH19CqWIixkPKZ2Th
# DATA 7wcVazjUPQuUlmPpStkss4V4Q6ku1F+X8+N2pWxfF4WG3Mx2k3A3Cd95Eu5m3K/4jHvjZPqFlmzjfSxmR4tQWXlXy723qEGXS1jv
# DATA v0Ryzba6rmyltDaHyoVwwt/K8mcr+yKlwgwS7BySl53OBjom6qTxvR+sbKvUk/xVdTnrMf7CqSmM75MC2QvwCWa9sOLYkKonTeC1
# DATA fyF/iI9O83DzgurWvUxyTjsK23pmS5VU34LhYDZQbTHU/vkf/6M2I/iV40Ck7MSC9BbRZMJTFwWaEEWv78H+zLwjsbLCBdMihlBh
# DATA oxnLeDnt6+IKvXR8uhhPlTXLBivPDY5i+VksPxYjw7QZomaW5pfHex4h0qWkkSuUW2mUC84ZNUC9Ai2YoRxdcRKmK5q6xQJlqJEx
# DATA HJlY9RrKalnBOKvNWW07W20r9c2tnbi1kytYbBuNw5sU32VA00jp6LOYO/KaF+ILGrzPXxB+myGAc36evdaysnQitiLblsPCtcKa
# DATA hiz10+X3qf/ls998xdsbTC8C3etHTXdmLpgVBjkgUkbG+0XQvY2Mr9f8zesvakOBHVm5tEtszcMmuvkVE9/edUZXbbyg3z/S+r+L
# DATA ZFGoEnvfvijaJhAT7fzKBdlct+Ld2BptZb6aBTPZlcqrXFLlI97iYZpCZiGiUMPuvSVnglWc1fZk26mWX5L+JxZU1ZzGbmXE3pEg
# DATA nhH+JLYVo7TyLsBWpf5hZvaXoPEZ4/YjcaYapWZGDp+M40mU9xMx1GoX2KuTsuStWemg1hzl4s0sD6xWOGHiysYV2fpGpm6pCuid
# DATA Vt5QofpMb6C1g9GlWn0PpWo5pfuxPTgPh/WkB+EM2sFzSkCMc4phOueFXvYcA0UOd+XJOBIDPu+4kDIITXO/xgtbZHTUPAWzQwqN
# DATA 0HS2nFPXo/SDi+LSdzjfXxfr2YJw8Ryd5xA2h+sfmcH19fkvhXcFctY3Z/+k0FyAc4HF9dUqgeu/0m1PAegStNbZ/7DCoU8M2PoT
# DATA 3aMhW385/83Z/zSUrrOv6Man/K7fn/87JnThpIN39ruzr8/+B1WacOKAWy+F/c/GvbV1A6jANAHedYp+guubsWOY1JpBnpy6JFbv
# DATA o55xJqrfJ6wbLksXWna7orihR2js47CPfkpm66KGzXUGYuf9CDOEbbCtz+kuEyGH2iqY/nnPcNu0rVKp3BxrS2jfhv/EW7Ktt1p3
# DATA /jSj4tY3FivYdSK2QgFbabiCWiCUxDi81gXFde1orU9CMjrxM8W6Va/U63UeNSgDqIuqeZ/QAGKsHiZY8KRrHM6xFqx3/i/C/iEi
# DATA KTjqzEAoUFzRIxoIcLagzNC6sLptNlOKjed5wbMuTIDjZrnh/bqHd83Muvyo/no4825xRL/uAX2n8Xzn4fxWRnOpjYWk2z66F6kN
# DATA 3QQjq5BwRvxkitluJ5Mm3WGmFs2GWDTrwzIPsZO4QgmNgfShRhNTEiYxWFKzoX7tKIwn8FcOQrCKmC1UTBZG29Bk9JQGOL3AHM+y
# DATA OZIEFym1kF1pWXnIrBmQyfso/kxp4q3oY6pzcK/QRT5TzqfN2b8xwwofz2GXTIiah+KATYaMzBKzIDNnxSlFD07JeHsET1k8DNVJ
# DATA 9kgMwyjDPsQ4G2MdM4RXYyDcFaQrHmED4mAcTUOPd74zhWvOY5FDaTmUlkNp3SBK68IxaKepzo7m8+3NAq4yCbiGOYBDZzl0lkNn
# DATA OXSWQ2c5dJZDZzl0lkNnOXSWQ2c5dJZDZzl0lkNnOXSWQ2c5dJZDZzl0lkNnOXSWQ2c5dJZDZzl0lkNnOXTWC4POCprNeuvK6Kzm
# DATA qDPqvETorMKq807gLM5YjkuPM07QTHW/IEfR9rvFDG/0eptzvN7oNVdBTr2AkVQqKAsu1al3e73+OrhUQwIZxClLUKmXtS22VIPj
# DATA yQfmukWa1LDX6LTXPd9q7fR8r99r99c9323u8nw36ndCv5wJ06DZ8IKgXaWK3epx9Q6mDb9V9QPf42tVuVb1/UbVb3aqnY7nd307
# DATA aN4wWsJzdYfdYW9dDjIurFTzOz2v2fCpwuPVXn3cq5eCM3m3ElzvCggsbkIagSWt0UJgNdrtfie4CgKrHvWi0EJgBRRQJ0dgBcP6
# DATA sJkjsIJu22/3bh6BRTOhKv2+06Q9CGisLPqtCiONjHg6RI8PyBnuk7bhlPGpE6wDSLVrZV0g3nLyuOQyscaAlbvDktlvTPGuMsXz
# DATA B/SoXZ4HrpvzaS9hl72EsjoIP+GaxbZ2MRHFhQCZI3r2xEcZcvkTZhhcs2JXxnCt9fjoilr0MGyCdhnnsYoO/MbW9Iu/X5BPxRe1
# DATA kRz2Kxa2nmx+3ozTF7xmwxRuM9bLVPCdcFzbKu/maX2pMq+rk8vJhZNLjoLjfDnOl+N8Oc6X43w5zpfjfDnOl+N8Oc6X43w5ztdr
# DATA xvlCXVAn5KPhoU39WmDJlDMCqbsrdT1ZpoMIFYRr1WE8YiNTNcx7rToMnsUYsIL30jRBHN9VlheaF5k81EenR9Inm9feLRnT1pyA
# DATA TdgKJhcVoX9hWyOXw74wx0wg9J26ii/eYLtGzHPv/fzoP9nRp9mavmD/8Anb6I/z2GCr5SieUXYoqhnLiCrdh2Mr+HfQ+VBzhUu1
# DATA gnOM01DOUHGp46197FGm+SW/yIqfEtSlrgYnoT5OjH3qneDMorI+6TeOIFVrzn2c2qnqH+mX726zO7gMqXzydN3NU7b/uBAZEaMy
# DATA cdAijepNOA2IeIjVf/jEGPNfvGECryFu9FZz4U3qq0Bho2vU2vNjkHfkRp0bfPaonF6VXFPZtrYXTue6wtstGJrM4fUUENvLkmd7
# DATA YkMPFumEpnx/93fyFZsB6ev+3/yNfKdHKU+/eOM9Rjy8sf94g+WtjG7qCrPFA7bY96RQncS9U1O4kpqCU1F4tVUULqtu/1zVFYwD
# DATA VlIkYn2WkvsiRHW797GW4eaU8kHWJaQt480JeVef3c+VBySWeGjbgw+43fI2LywKbXyqkB1iLFhtL3/qDmKqdQj5aOxGgXtDYlJS
# DATA CNSqt4vbv3BiEy/B4Wr+7zWTE4qiGNfNTShrjaylJlxWJevzNFamWzxjViPZbjBmjEqW0QFh5bIMFvAJhMymS9FwOGU/dcUI6Etl
# DATA VJWHKwpGyUwU7S1ND2gchGzRJ6MFw5XSiN3oTOBSwC029D1eGGS98Vn0iH28SlnjQo7Rq3FO3oTgjDtn3O1k3JWUcpxmltPMuoRV
# DATA t9F0vCktrQ9EsIkqtprLKycCV/Oc7HPbio23IXKvPAs6c3XS39I7MbTiuL4NquniKcNldpYVBNYpIycT9mgzAAFrxTy6/Q1cTIfo
# DATA 0+TTgbqgLGr5VpE/7BZXt/3YrwSVxk9oUNQx2iApr5xq9K4P+BNX2SKC2Nxi+tb8oRUCcMDIhpPE460kW8DDTTG8wT0s3bkCCt4o
# DATA Jm98WHnVeXl15DHlEXkpZSOtkzhbGoGzubSaipIw+1fhcfhAulilZgbCinaDopmofGC9t5NZUQtNVLNCQFpsl5zSx6IBE6Jngkia
# DATA nCpHqGnuULgSAS56+gSnu3joZM0py/1X80xxYUQkG3k5WCwVhWkST3GRNxpBsAoicUy7gHZXpqNSqgj5VMQ2k/OphZRW0XWKuaVe
# DATA 4TeuQzXnMzXnYtn5V8NCzYcZZ6I6E3UnE9W2RZyB6gzUrYbn8xZ7/bjQSGYY6BbxNIcyPZBlUhZArVgUQEmd956WQYTAIo7vcHbR
# DATA 72gqw4THauhyslpoeETxwpaz2anRg9xRwZWja2IjJCiqBRB0FIOAGiu1+4j1LdF5rPHWqRPHayxV2aOACsafFB1IWTL6x9y4MldY
# DATA egLI+YjDUbGTPTemW9rMKjIbHxj6I5+LdqV1h+kS7adWTEbsHMDoiI5R7ou3WZhokdqXvPkuS8dWMI7m65aQoyw+4rS/y5+22K5F
# DATA NrjsJLANFkUz32Q2FsoYu6ulsV4BwK5z45IA9sdPNhPYJWOFwI5JXKQZ6cppf6pJ7J9hyyilPF1mst2La+CMtVOVkC7mQCBz6hXo
# DATA GJswQmyg8PpLMnSVYmo8qHnvxiywumShXW8aZzx7lL0u2K7EFFHeBCLXuLXyyrCQGIAgotelis/2zGj7Ug26ZAb/8z/8aXMOF2qj
# DATA ZDRLuqaRCP/CrxoP4oVB3vMvOX2JtW/JqBYt1WSuT90vqLalrOOLw6uLWOzz+yM+FE5zg2k/PlqC+6hcvxXd3QkqSuiPIRn7LOEb
# DATA D/k3mbBfR45esa5Os93q6sfhVKoCpKzzrJPagikOFGxln6+o2kKnehItgMSS3U3maY8xHui9GPRxCrSs0LpmUAZEgyDrj6JDvScV
# DATA hdqgYBrI869+//pSlU9YZxx7SsWXy2gZ6fz7EDM4TNpoAp0rMZ+EMTtz+II6bh4BAP2uNEhek5CKk+UVlQNG1o9wtIDzkzJwBhcS
# DATA B7SQp4DpjUBRpKEShXYtVc907ZfMyA+21D01SEgellcovUUaHtO4eUJp0Jn5qTpKMFYC2aFUy5RsmGiYKaOAernZgsFxCAt2icxP
# DATA qCHPTM+getUp9RoZzyVjSDxay6o5XG4RKzn3iOa/WoUbtt9zzdfPds3Xz5jAZy1X4Xxj3rrVclgaHWE/uBwQoYRkasjAaJOr1xvJ
# DATA 84x9FbllGI1GnMN2PxD2Mxavphkau3fkHlWd0ZuK1Rejs/2p7GYtZWjRSJA9i7aRYK5I9pBdq3cX6okdO1vUrj/qiAbjBPpZIfyl
# DATA VJK6IF6LhTcbo0clEdkEvf909s35vzn7+ux/nv3l/Lfg3p3/Akg8+u83Z787/42g8X5/9tX5z8+e4u/ZX86env92lahnh8OsvF8w
# DATA jQ/PfnP+azx19ke6yLw9Qe/R3z97dMvX5/9Az/31/JfA6SEG/TQ6qRr03h/Pf0V/f4ufmbj3Z4fWexm8NVLTbN68TDkfxmilM9kW
# DATA DGLDD41vRpTvYY6RxTCE0g9bCrK+gd8f6u0kaTSI58rmypboj7i1TxMW699K0ntH4mU1IAfTs700yJ3b5uitlsnNofSk6uQriZ9K
# DATA VRLJk/LN6ImsNcfo5EZo2byjeq4OXVBWyIQRb5tGs6Xj6e1QZteO1BOznvty7nrgZRa/WZ8MCN27iT3P3dhnebdE1TU5UVAfTThn
# DATA nTVB//KhAxRaPJ3ijA5gQlTYBkZ8qfq3BQNcblTPC7F3cSIcY8+N8884zmuk3pWG99dkAeZWhvYbGNl3GtgvM67fzrAuVbKcAxZa
# DATA 73k2nZsg6ZWTqhdFxKUastxkaUTM7CER8V8ZEysCxZLFWVljFSWL42iRzPmZKOMD7QmZS4txMsx2weR9ijyUZaxyjCh74SHgjbuU
# DATA /GmMDSYJWWXYsyUDfV5d6J1htkwBBgtZYJQymf35Fe22TyO0H07RKZeM6OAICRCOFSbV6cqQhRPBfQ3grNY8M0fDczQ8R8O7QRre
# DATA LqPHTnOVXY3dW7Xbr2K2X4fV7qh4jornqHiOiueoeI6K56h4jornqHiOiueoeI6K56h4jornqHiOiueoeI6K56h4jornqHiOiueo
# DATA eI6K56h4jornqHiOivfCUPFa7aDf6FyVijca9aLhS0TFK6887wTGK1DfGj2LGteoNwz1ze90ity40aDbU3lDEYxpZDVBNPIgms16
# DATA XjaB0Pbk8FTQK4TXaQaDxmCloIKW7wVBMA469WO/2fyy2vZ6ftVvtLxeQH/q1S6+VHvBmpJbRfO1AgqtVR832192Ol7HrzapHvjN
# DATA C6hzJrAVTFzQWZsBXYvcR5G3KmejlWdAo/DebzUHQbtRX4lyo133/Jb/ZZXS2qTaUu3401aT4v5lNejpK1dOgB9cAXTHrUKD7qSB
# DATA WaC7TrPRaDZ3AN0NR+0i6C4c9gbNHHTXabd67ZYB3Q07g3rfAt11/Ibf7NwC6A5Nqrrd3vB4eLFuLfPhvhdRLxCHFQm4tJi3gopr
# DATA 8IJZvlxWDFrZLStOKp1DK47Ikr/fDmudB/5Sg6rHvrc6G07qGbUEtjbpxq26GkljlhcRcipsQdet3ypQJtqtYtbW5owZ+PTqV30b
# DATA DW6HWnBTpohDuzm0m0O7ObSbQ7s5tJtDuzm0m0O7ObSbQ7s5tNtrhnazYW6SbD6wdVdAakOccntj/zvyjZccGculkGfJIpzI/WhR
# DATA b34ULsY1nknu8cX9NykHcByV3qOcaHNozCznfPte4R135Bv9mHEvskjex3a8Pd8O5XM5TGYFUn5nKRh+duXImSaIyRTQHOlwh6jd
# DATA Iep1h6hLx3zccWp3nPqyx6m3CN/e1DFraQVsB0OvXVZZzTHr5yjkcRvUhaE6nq1qBr56e0f7StJWN7sZOzByAXj1VN43qe85s6DI
# DATA YpjGLEDXUtgG9v3LohO2WPBaVM3fLHwr4ymkmM2whmLAoWrJ/wuiq5838TUXTIT99roId60IB7vHlwdVUNo4HhxNunJBJNVDuW6v
# DATA +l7gQKzE0Ldi2LUjWIzeRt7DO6pFRUY06OXFPbzDVh4PYwzwwuREH0j+YASVTfQhfAw/44EObS8js2ReYZ8mtdIJvP6TUw9Kmqhk
# DATA MXh5YhSJt17oXFLr+Nw4NUMV4pCCoABh5ox1gIMERo8KSR8HZ/4E1+QoW2DdnadULME0ZYvYEgHAaXBWYORl1CFOknmydnNoiwHA
# DATA ZEPvlyXTSHdEH9Ls5RgzpDEDMLh9D7A7WCUI0c77mosBDa/OwWIHiXWW7HZL1tmtr7jdelko7HOXB+IFc2sheNXomxQkAZn6k7Ho
# DATA tuIf9PkYKUyRrQzV564q9JIocNwENnVFAem6yalr1KTWw1N3U0Is1T9ktU1TYBHpt1OkVQ3rrNqeK0jznh49EVpmAqfS/FS2xSLM
# DATA s4anBUmX0MNGieVU2WeoYPQhi5ShhMCkJhUNFIVOfp9vMEZJWYKb4/wpi71KlCPKYh3jD8xELeY5IEVV9IwWcVphZXaOjVZlL1ho
# DATA WvHexgewQYqgyArAEYwt0f4EC3PbY/0A0BUVa96mFA11xN/TEldDmt0iNpQEzr0KT/kq3ik2y4qqE3qMRXIUQcWq5llGdcLKolOP
# DATA QQWK+rIpuvqFqzF+jQRs7D7JWZrO0lxnaRbGKecxdR7TiwzU5y9MKTHIlLJimiRTVqnjBpHLU04m0lTWiiTWVD2viLOiIoMRdOfQ
# DATA jLA+zVQw9qx4snqn2hUvI16OAvY+WwlK3VHapFpu5DDR880ZuwkXcDjBBgYRyHZQsF2gYGJx2abVpjuNn5vpLvrL5vu1Sifnqvq8
# DATA +W4t41k0P158jFief5fkuPgHfnszykUXhqBcfjCLqDOZs2uxiiOL2jLE+obf8o7slYygWacLyo34eaQIZDQFwVa5yWmF7Hbs/e1T
# DATA vRjh6wLjJULGHpIMax5yqiPjHgLG1kmYjUVLVVvodGkyya6Dg3Mr+ffZScL5N6Rxal7MvUa9mHvNrpV7D3ihBsnmvlZlEhRLAXRe
# DATA sBylSGPKXeIXnkTAF2GzrqcO4YpQ6TXkVqENXj7DWpszzGrQkmffoz6VYvd+ylPZuUxg8nwLSrWu0WlZ+baAKcXLZGw4xbPlAkMO
# DATA REsnxYkVjxgM66GaR7MrRcEzk7Bj7GicvAB5175E3r2DKpCKrES+PljIvlK1awT1UvZVeCrNJuqRFEVG81RRSgWxT1oj9qMP0/AE
# DATA W3n10gDrzeZLA8+SZ3Yffsks+2hzfuWjgUL4JQ9DbV3rTHqfORXCjQC6T+iFx2RzGDOdLNyH1PAmCu00ZNXhaTJkkp83xjqw96kI
# DATA BTPTClfM8olZlclooKdcZ01etOjryDZ7MLt0TQs2Z1w+MErGGcdA0UDTefgAV5XXZeb5XaphQ51Xoddo854hqqjYFsguBJouKUeM
# DATA 2G6Mkee6lnhHy1jxvZgbq7w3bDbylvMXFeH1qjgkcozXKF5AYtbmeP2/Z0/Pf3n2l7Ovwdh66p394ez3Z0/P/vvZ14ze+noV2PWf
# DATA 6affnX0Dxtb5v8Ut3v/P3ts1uXGc+Z5zrU9R9oSju00ARAEovJBqaimKejkjyTwkbe1ZS6soAIVGiQAKQgHdbMuKkKyZMzMxjuOI
# DATA 3YnYiBNnd2JjL/ZmLzT2aC3LluZiv0D3VzifZJ//82RmZeGt0a9skimbJFCoysr3fPLJzP9PkFxH/370Z/rpu+Mvj/+pgHAoTArr
# DATA e/rtT97x3+OnIt3xLf3+G37Tt0ff05u/Of6C8WBAdikC2G/o658oQPrJMbueB5dKBvVDlzm0eUDSh6QxfKDUJDUucDLrTFn9XjoU
# DATA yrBoKvDFfUz/4qG4IKXdwoXaw+lzcACgUMJPgcPIG1F5u2dHaeQn4WAtxus+Vsa74aGJqeN42b4W1UFcNchrSalcHslL1cJsyeiR
# DATA qpaDmOI5OZy/X2qjvvmdXCW9SJgXXIYqJqKFLzvzIx0vB/TarOgunOn1KMpABxkLYgJIqu6yDJWDS85L0dtgL5DICDNUwZwihufn
# DATA EF9L3ttxV8+OqXeT6bU4p1RKF8heJ1fG1fbMYit7Vmivk1Ph0F7OHLh4c0DTvs5mBbwUqy1XZQFchgGw0fh/yuH/akZ/qZgLuWBB
# DATA v65Zo7oMDthC8gE1xdpQypz39SkrcA2E6hUnYT6d70zV1gjeAsEiIXE4MW/SQXHKZcEJxalcBxuRwR6zrxf+IGzASeF6iybhoKAs
# DATA ORrQ4u4MxRd1uRhhrE2ohvAacjfDPHGEtSlgdozAPKBAxeUB5xS1cbhm4lGRsphB7B5ZF9N4FGlHFS+fIXQsQ8NsKYjNQi8WO8SA
# DATA oBwlzFHCHCXs8ihhGw45G82BNjWdr3YacJZZwEVMAhwpzJHCHCnMkcIcKcyRwhwpzJHCHCnMkcIcKcyRwhwpzJHCHCnMkcIcKcyR
# DATA whwpzJHCHCnMkcIcKcyRwhwpzJHCHCnMkcKuDSms1q52+eczkcIavaDXfo5IYQtLzxuhwux88QOv6jf7Qb01R5uqU+/YjJbRpqpN
# DATA ySEuIymDGitSCinL93NKPfNlV/Htwqvn8t+8Mxd60PIvMfRWPQu81soFLqnKAverdRsClgu81Wu22735wOtB68JDz4HeasJiE0iZ
# DATA X89Ab0EzF0AUhGGzutAs6HHP95v7tWBQaXp+4wQC2eo60TgDgIwbmwaQSbvNAciCsFXfAECWuwIAWdDt9MoZgKzeCaJm2QDIOr1O
# DATA pRtZALKg1mm1Lh1AphvoWvhUyQ80hSx3vxkd9QJBsAltLB+E5o1l/bjOqQVHpvVoG4syS57ZdFmgVFcWSMV2PFRKS9aEfTaIcm/O
# DATA eRTEMsBzPH8x3iQ/IDsBJtUSj2TFeCQlU+aXWZYs9AULL6jc1nMt6r39zC6Zi36T7bllXLRWq5WnoWGVeTWlLFduhbmyWGPt5G+c
# DATA 8z0Y96HDkDkMmcOQOQyZw5A5DJnDkDkMmcOQOQyZw5A5DNlLhiFDXaBQuoOoEPEyUXe3XGCnO38ak9kdpbu//KgAh+p+tMsWbAEd
# DATA 7QP8tIsqedtUaD5dButosr3zWdzblod2PtNBUwuFCRKOOlFpRBbqTlG96rYd/G1WddYHN7Yleju30RV8uPU4O8bWFZzY59YcB/sI
# DATA 9fulFHHsY817kX56ipLKSh40MZ5sq94K+sSSfkrAqHtjd6x276c/hWF3m9KHwF+l33Y+46d3x7f5TAbFiX78EV+jeCxNTS7BJutv
# DATA mwy/LbUOE3pu9FkNozx/U+k7U94rJJw++WOUn73HOCSVP385oegzwYPyI04k+8SWv/356tcx6a0TxYPtbUpqEWneucmmLSBvKkso
# DATA JpRkUy+oIXHqS+zG3fksqzDWZYm7fR9lnM3Fy2qQiiVyVXJIjQU7n2UZhqJDccaUjfGripzHkm5IZ3zjhr65NJ6RafKZivktuROn
# DATA 7Oi+AkeEJtYf4NTdf//in9WZRmDz4hv+DnUxFImF4Iv+zpqwcTzSDvshjkvy8sdi6J9ndeFzVUd4Mqnb5GJVVg/cztX+21LPdjGD
# DATA 1VXPuqFQCcr5FjWZjURKWAh9XB24ldGF19YZuFmbV09NcIb0pKe4fO3uwqr5WQ7M9TPrmsRDqKxm7UElClHRSTJzwCXR4jMo8YDm
# DATA Q6ZP1TXQPCZjxU4u0hTsQTyi6eKyQLGSRg9Fc5nkmDFOZ+KMOhNOX+LF15c4LUnmOuhO8MpKzl+/HifzHg7Bg8gB8VV9cDrcw6um
# DATA yTCZ0MxsLVPmOopWPD9HuC+DNLOosXHRqJllIiZnZM14uSUiqdK8wnbHL2tpYMFsGjkxepm6BQKeUk8ykQ9b6P0JWWUFcT2Jlj0i
# DATA byxvWc1LxphFAq4nrIf+bDJlqa9YvXdMI/9I9BMSJfVhROzXCH2cpDz6Ah3RzzUcZ0I5E2pDE2quf3WiXU60yxp+Vxpf10HM6/VZ
# DATA DKZWXrbKSHm9JbpQdlPCyDOOEjS0g36SG6EEIaAHsJJ3FyI2KDrW1AllLqzgY9ETao7hIO5B8Qai23A+iITUKIq6GjN2Wn6KiagC
# DATA Pig5bUirF5YoaTl4yibwlGEiRcd69+rzOiDKhN1oIoEvn1ffjd0+ws2+x59W36nNHcUX4s/PAzrFzr1TquQ3YTiu1snPyiLHsmCv
# DATA nhbH51lRNrJh/Joks71+1hg+Ydg7S3hoXNJsRMYja1FlG6bRnveTmLWtOmweevoEPazGGYvNjVm+F8YmxWEvml4EZeAc+RecLv/e
# DATA iNInHjvbLbQAtHEV3MmklyXjxBWeMs/QNh0OwsETyistH8jh4bbZAJhuRjV60YjLgMXbcArC684mWlyXBqmLYVpkzfC0cIbK+nzL
# DATA WrXk2+s0xsu+P2bqzGJT+5RtRXUuilYKGWL1aASWheQlS9PJYkKq6F1ROi15f8NAjKjTH8WfziKjoEiVlCZ0YCVM+5h29EOuicjX
# DATA qaq4F5CbWTd12rw8oQ7qXk9y8gOqO6yCqKWaDYbUZBKlkasQW6gKNWqQ8GThdp5ACnLOlFW5F7LsokL+DSI1yeRsVxpyRtS7lx+G
# DATA n1ULrp+uBb8eDtiOUFOFyGbRwDjgDElnY0zAKIHhpH2o5gYd0VmUnc4lj1dqkLssRz5RbDfKtV4UQUQRUy2yKKJ0HHViJsKK+uXk
# DATA kPUMzSR8FB1cRA7aY99pK2B5fRZmQ6mCraByTcxFTcGladeQuzZ09orUY6ZhnRBUHsqoAzKwYapjB4XXJ4sQ9QtZxiqgLHxIlRo6
# DATA kPvYKqb22FxbqMoL5NrIgnB+DefX2NCvka9pzq3h3BpnXBNa6QK5NI1yVWVz9FeY4lTNjXfjmbMy1nk3mMm4kmPPG715mQO7v9XJ
# DATA RX3NTHp5V4M9cporetbLuZSdj8TOEPqW9HpiGoRdsQtyDgne1UI/s41kep1ttT1lR/lFdAsf8YZ+vEIipZ42PaP+bub5VTm+iWFg
# DATA QsY9GS985g4Xh+FTuaMs5+SiMR/NW+074U0ynBKrTDeOqnraRFV/N1GtnBhVv7lxVGXbDyLLn06Km749i525YuJXWxY934peZU3s
# DATA 1Kqg8WfJuQCe/oG3d5P3KQ7JxJYb2fyYDO+8KtIKWRbiWIhdB7NLuTo3psF9Ksdxb0oQWUU2vhmrfZhLKxw4YhLRZLBrmdo5hf//
# DATA RLZpR09QaWLewyhpQDoyZTgIaXgHbGdMj5KBhhmYogJls1gNpFR0QjXZEkqq2ftrIS0xJCeDIsMseccWvaULHmYiNFF4UQpeN/7V
# DATA r2IMKexeGc1SCPKnh2T7JsM086LaMetHg/EJC8dzpZotHtt+1WwZWPJf9mzR4w/wISvxMwUmW7mkUUZTq/qIDcsl9nJY5RbrcDYh
# DATA m5hMOpt2+N8YXvgNaIN5BuHxb/H3Iu3wvx59zTzCPx/9cPQH7/hvj786+v7ou+P/TE/+QJ8Ut5AZhyAWSuAcssdAxK+BUTz+gm74
# DATA /fE/0kPf4bYfjv6NwtFP/uHoB+ASv2UMIgXpmIfPwwzDVK9sYsEVHsQT5Cg9U1D+Su5wNBKDhZMM3VkiTBbRAypFoRHAsDIED+pJ
# DATA tdEzjqMOzcbXwQ0f6m0MNAAwWs2hDa3JhC6wq4YbLpTK5aENVR3Rt4GzoYk7/MvC/di+YnW4j5Ke2tNy4WhDjkAObBinXNkd1nCz
# DATA YrtwrOH9p+MBeplQO0OGSXc2CEFeT6as2VPyPkDfz31Xts+LF7+wMZ6eNfufKA6zIfeUqWyDggslmYZ6LSscCTpmAWh4chVcbbXM
# DATA t6xnhTM8OQ0OZ+hG+nOM9JpbeJYB/uXwFF7Z4H7xY/tGQ/spR/arGdilWs7lgcUsfFYt5zLghHOpxAoASECK8xd3rMTqc47zCQrF
# DATA pamgcqCt6U3UKYqHN1/LtmIt0Q0racRe0fl825BIaLysWezSadLhFUcejzUqjvlxXEu6NNcepSb60WySeOGQ8W885EdkNsSdGEvj
# DATA OZsgZwFET3GwGIF3I3ij1I5qtVZI1gMV53tRmCJCbNt1pnDFiJHIXh2h1Mnauirq9uxQ6pejFTpaoaMVXhatcMOhZqOpzaaW8VXa
# DATA +Gcx8S/CwnesQscqdKxCxyp0rELHKnSsQscqdKxCxyp0rELHKnSsQscqdKxCxyp0rELHKnSsQscqdKxCxyp0rELHKnSsQscqdKxC
# DATA xyq8NqzCwK/Vgs4ZWYVRt+dHjeeIVTi38HxqUmHge1W/vF9stT71G8Vqw2sE9He/GlQ+rbW8ileveNXGfquVy6WO3652evMYOwqr
# DATA vhRjV1sgG8pJPwH4tfIAv6DqzxH8as2srOXYWkbwi5pR2FkEJ1p8wGaQC75SbeWDb1VXhm6SmQu9Vg7WhB6cKXS7RJq+V6s19mut
# DATA IXWtxVprv9baOKf9RRhhw/cCv9GvB8FcKJ2g0253lqIoT48dlHajsYPSBC3sYL0bNBvdE7GDYa/dq+ewg136u1uxsIPdetAIDHaw
# DATA 3enU2jULO1gJas3qpWMHzTY1CP/vbTRfX8PtE/vWW7CLtDk+9zYzUKqp11sRdTdxWJD4LQUYBmolrrJA68PC4sIL5tzuttGoCyQ/
# DATA 7yZzz/NhB3h1+WOHydbpxjkUaNMJmSJGbj6oO+G8oWJhA/ORtTcX6BFdLXuVl3l7ZTEln7QKfJ/8l/pjz7jXEwfnsrUwnydrzJa1
# DATA SWZ7wgEHHXDQAQcdcNABBx1w0AEHHXDQAQcdcNABBx1w8CUDDtp8N0m2eDGElMZHxRH9nZ82yzcq5QLNLNVPB1yEOzJl05iv+3JI
# DATA hg+6oZHd4F/BpesMEXDk/X//m9cq41s3isalD+m/EWhrFO6d3fJrH259wFrqfI6OF2oQCP0oQZR4ykMRlrDM4RvExWsf4l6m44Xt
# DATA FCHumKfwid/1jn2UTVLnRekUfuTolvfff/P/IDILad+uVso35CqLe6JrQJAaZeYQYu5s90lnu92Z7hf9TPdpSWHX4az3nIttPSbs
# DATA XTQN80TJew/V3tZ2WQoHe6anw5+fo5GXQQGbP8x+0QywRUmAsxLA8v5afVb/XaZ2SUWQ1/Qio2vzBlyPoddN6If0gM9oP4ATElWL
# DATA pYD6YTwpeY/iKbuftOC7VEARLp+N5XiyKtzc8f0wkzIaQ7Qx6fFZ5Ew0Z07hZqGcn0QwlUMjtwOb6OqVbp7RKVirBTljyBlD88bQ
# DATA Qo/qRG+c6M1JZtT1EMN5IPWViRbdxOAvPknaRhHnodFuoGYY740U+UtpqCl85ISGhQ7ELXq4WZQk0hD4VbhHNR6HN+SzfIfo0MAN
# DATA ObC1W5ZopmwM/noM1Rn4xzIlG5sHw74LUe1wuK/NcF+UFOiTqKRPudWshn2x21Fkofnj6nt5ey73LI/50/MA77Ly4pTclUdr+Ek6
# DATA V4W4cg+tgkpXbCsBrjw+SESsKZlBMCaEHItAVoZoKVoiETU8ZC+UyDKJeUjj2j68yL+CPMtkmFcvEpUisv2SbLwLIQhDtSMUjfoe
# DATA G8r6zKk0GjU7WC7svCgAbRbexCbJEmhyTEs5YGzAgjJnDD1gCUKfj3915pJ7uHHJPZQD5mKl66J7F7YIOsKQ2QBUHHtK/Ttl0lc0
# DATA ZnUcxRLKo8NQfCzpI2rfVAQySb2r+YzwGKp9UdybDqKpAgtMVFzScTI9f5HlUnZ1ZZb1Jqcss5+to5WpfknK7GcQIEI+thOKkA2I
# DATA YmkivY6iBc32hJFFuUudOC4mPbJGDE+rFx2I5pQe3KYiCY87ZXGHS/qA6W/MXDGNjku/PUsPz19a+TQ9B8X1/sbF9X4IcDsvZlBf
# DATA n/Go0r5o6ZvGQL3eHvzhT6JDsfbbIRS0vH4ylIaFycGIQ2ONupFHBTUBLQyoHPCq2AHfi58KPo6hCVlhzgu/nb/Q8im7skLLRuFT
# DATA ltnj1WWmx3PVK4pyIK5l5SX+COzDxzBATSgVVuBAHDEsj9xR4wR747y7XL49xndRJwQRMox7Ynni2JQ3nvHhORZPGAHtcgH9Xhb3
# DATA 618ilU1L5P1IKddh+JiqnxThUs4HRXqAkeYk1oYI9SUeH+9CCzgUQUIBA6pWw/0bz6wRAMxuHsriVBspKF3Rv7uANrOYkDMV09US
# DATA 5s6FMXkZ/GxWEM7R5hxt8442u0o5H5vzsZ1xsXGlT+6SBKdlSi4zPYyAqNywMY2L7RlCDS6JPJfzZOm9J7D3eZM1lp+avG+GZ8Lq
# DATA 9xNAZ1kopruyLmXUuJNQZ/UNOWwH2ltmwF08L1C79rY7wxMBdxJABrhT3y3A3VJsnC+XNTiuvDHkTnbzwF2ID8IYEwoyVIo5r+Yc
# DATA iOqBzHuoQ1jw2TXKjP3CtnbvAAuZvL+oUV7t5fN9fuRx9BQ9Udd6in5Z81iNH3ub7j60n6mV17gJVyLqtGmK3bRkqU2fX0id7bo7
# DATA 6FMo3idkeY6iw5It+ax0naUTgEPoIPF8bmnhRMHi9Ia1MU2TlOmOVWfqLChOmF7xwE1BG3e8ODS4bxGPvXL3a3VtfrHaduYx4JIK
# DATA rFopc72zWjj1UTMNv1R7cjv5mgq9aSXDTqFoFfYCWfhPpesbURwHMlVk1ezxbALQuyxsJynrp1oC2RtA5F4Q4zlDyFEvEnUmYW9q
# DATA IeTe09eKx3939MPxl8e/AUTu6A+L6Lh/WYp/oy/f0FNfHX9x/CUue/TPN3Tx9/z31wDH0ZXvjr4+/nuDhPv26BulkA6FrzG0U2nI
# DATA dpi4a2/qs2UeeqbOeP8h3A+9+91YzmKJ6L3aV8Kz394kjkZd6kD420EyGXSN9Q/P92wsvlO4EsR1Njhkum4Cl7ZQRNlpkC1QqJ4H
# DATA T0VPqaF11yLkXoeABmtNePy38CQcRy6bEZhO4ao5csuL5vJgcn2KDpMLMjg111d9/SSY3L1QJMEvAyjHm6/IdqR/aUwQ1xVGczQY
# DATA B5TbrOguHCgneRaymTNC5ybzKjOd0oaNmkwNpYMiy0VXFF7go+EN/S5b23uzkBrFNKK+7Y04fVKA9UNP33vwcy8dR4qUgePvlDal
# DATA CjNjGwiuxekGtLnldXS1ibO0DV4X7NzyxDj0nLMeLsl60Fi6MxsNL4UL8eoMhkuyFzYyF05pLVydsSCVdFlmGEPheja0y6DYWdkA
# DATA 0BwWibvRGBwqMmXMQG1yiGfzK7KlkwyHM3TXWMB7BzOIDjssWFIkpXzpRPaIP4nYQSHeP2RYqjbb00hPRcbXe/GET9Gm6caEO4C0
# DATA UuWb1TAxypB9sggn4udQv/ZorhzzAQfeEfRe8gmNaB4nr0MZmPSmJe+hjrccUFCwsHkn8ILdImcFNILMaFowyQz5AV0cSAf3KZPj
# DATA jniPOe0jcdfwXs5oxBwdnJBH6wKITFUJylXHvHPMO8e8u0Tm3Yaj15kOdq0zy698pnERHtWzzjMcAM8B8BwAzwHwHADPAfAcAM8B
# DATA 8BwAzwHwHADPAfAcAM8B8BwAzwHwHADPAfAcAM8B8BwAzwHwHADPAfAcAM8B8BwAzwHwrg0Ar+JXu9XK2QF41ecKgLdsBXojCp7F
# DATA i6tkODo5jZble2NOoTRo5rKrFrQaQTRHVqtUqABqa8hq1qtbZ351s9Ku1Ktnf3WlfuZXV5uNdq179ldXq2d+db3SqtYaZ391rfzM
# DATA yrrWeGZlHdSeWVnX/WdW1rl23WpeZYbn2vXpXn3eDM+169O9+rwZnmvXp3v1uRtX+ZmVda5dX21Z59r11ZZ1rl1fbVnb7boS1K8y
# DATA w+12fcpXnzfD7XZ9ylefN8Ptdn3KV5+7cZWfWVnb7fqKy9pu11dc1na7vuKyttt11a9dqanQOvOrz5vhdrs+5avPm+F2uz7lq8/d
# DATA uMrPrKztdn3FZW236ysua7tdX0lZ266HStmrNir9oF7ebwRv09e806HRrge1ztLHarUGP1atLz5Wg6OjcRpzTE1ALLi8X88F6Ter
# DATA 1cpiTIJy4FWCoF8pD6uBV+5XynO50Q6ioN1YimRvnommXs1o6uLPsWjqzXIYBfU8Td1vVf1KkKOpz/HVQVNvR61OL6OpB5V6vdY2
# DATA NPWw1e6F5YymXvODTqV86TR1dgYX27xJ33g6ZbFdY9Ezb2tTHNb2M/NAdLMUt2zZTW/UaPAGTWzPZCb64m7HOvys8ho+CLbZtoy6
# DATA tS1jJdDdCnU9a12KSzktA7PsomsEH0voh93k4FaLfsSfsqdK8fMSvWoIF9iKJdjKQnDr8zAL0FNbTfX+NVm2Mr+Ol+w+UGu9uoaZ
# DATA ZQC1FzTzdBfmThTkl7fLq2HrdkmtcYcvq2vs5Ga/uoOqO6i6g6o7qLqDqjuouoOqO6i6g6o7qLqDqjuo+ksGVc8sRqXdsL1j7DtK
# DATA tfdQtD8y4Y/bQqziLptt5cEh48pFVKQ4TLrRrqAr6KJss0Wjzq6JyEQRNshuJQjqAV/FLE9k09JdzUbnqbFCnKvf0Cg1IB0Rgwti
# DATA CmG23aYEHg8VbCT7pS4vSKZdhMyFiS+o5tw2SikN1dF2uVCv7cA4wkGV7Zu//FD9d2v3r3+EfycczEc39wpUrhanncvWW4TTQ1Vg
# DATA 97P9cBQPBuGtSmE8mNG0P71VLUAy7lbw+S85KjyNNXH5SOPpH8329qJUxkUWIPMe3n3vlsHGd6J4sI033JjPnp+W/CbT5N+KXxdo
# DATA /ess/5Pp8M6FIgGIAA5N8hGE5sePY4HK+6WKDhKds2KJYFQQwQto6onQIb9Q1Rlo4k0hzzclc1nXIFESgmSLAtJzJmQasnT1tXXm
# DATA FGdw3FthyX5mJhqQSJuTp6Wns0q+cxsjCxxXcxo5EPtQCYCSiy15wzGWgeDHhbxAh9Opczp1p9GpmxNzcYp1TrFuiebPapbFdVGy
# DATA 88YTtFPW0MrHyUjZ3c1Luu3NII0LYaZV2m0KbDECbzbuxCpozO9YjVWLVTGNdl6SLo/WWpCjM/f1K3ceYGiirkVHXLzhWm7qFzJu
# DATA K8W0jHwFGzhhQj0wgEDdYBmnyCr6Uxaol+BSaPl6Mubrqe5tiMVCa0qpzQGx5VlPMs4TylYU5wja+JSUGMa15hDykb+kx9GJngKi
# DATA JrJe6KnMwzRSrVLq43S/oewiltvLlG7V0KjT/8gYUp42pKBYB7yPKBXTfFioJyqHYtaxKHm/wMi58EinP4NusdYfU+ZKyeNJQ26g
# DATA FTywAFDFU1vIUYUzi4KMSyj0Sc+NPpYxKzEizKBiepU5S5Cuy5G7qouXHFG9OjcWkxvTZKzYBlxXkgmryUH9LJ2NMUJjyzH0nKmu
# DATA daKu1f9PwycCV4BVyPYMJl/jQ1WoenAJD8LDzKKSAUhiD1+19zhiR6aOG4NdQ8sUYxCxPeRw3Yqn65LN78fbPkko09oYDEOuczRv
# DATA 0Al/Fx4Uz7LttSog06DyeoFCQ2XRLooSFrbGXHIsJRd2qQuPDdlGCcrpBIgMnYY/6QlGJiinWTcM6AyzVmZMNabaaVNOZQP1OYPk
# DATA kL2+85A1UQZ78QXOslHHGajOQD2NgerM0ZfHHF1pZl5zYWV7gX8RYTbI2anSYujvaZ8HJNgqykLNHmG9HoXCuq7yy8+XmuhJQAdr
# DATA K4fg5niLzJ1XqYOeb6n6OFpuk1ezPLfJSx01Cwf8bVl7WTwmJq2/k8AtJW88HHV0dJT60p2fLZwyYw8+2TwrhLytZ/kLp2sOAqY3
# DATA 0mit7NeVzdjXytOcP9oYY4NtuXizssq0PDDzOmZjy5Y0DE4a7GGP6umCwXzlDcy8OWo5+ObwFfN14fVZjJq/qLctlWKB2HUi4WOk
# DATA XlygiEwiMl3CNlndCvAx195x+lWagiYA96t3Hg0F+E25aWjI3NxYyzdUROT9/KyFZcBBfR9HyXhALfQDXvdAXmTzD1YzU8RFkUnO
# DATA 6YTnDcdpiIqrQW/GWpxHSnOUVenp6KrJnzH2MXvQ5amYaTLDwE4ImXEylgSzFNVVqdJeE7EHEzIiO9P1EbvH6w1eCov/UEdPXZSZ
# DATA NFvgXoiqxHmEnDyYsGp2cjCiKRv9FA8hh64r69LY3JPJ3mJsXkKRYsdNdlb8Wa34+Srn/MzOz3xuA37ldOHy/MyGJz7P4zBYtWuJ
# DATA +boK/rJe+aUf7j8dy74dXgUnUyZKZqn2tZ7AM86CMf2edckAfJsnAZj9jYHGxuj/gLtBRCwPMNY3ZIxlM02Y5wqrVXb8phz3qxnE
# DATA ah1epnn8cfW9KHU229hvv4ZRvJgyXks3qcM3Rkwow3z7rfj1ExHTVjD5PNAXTTxrJxVLcArONK/6K+gfRVUuYE8ItVfKhPWRNo9b
# DATA 2Gl9JeNNnxTd6qax5Y0cWQc2pI6B+o65OGJ3jo0an3bznHH5bmJ310vJYtLLNHZUN2BS39eoZO4gJhGvWWjP9PMLqDZrBdIBD8LZ
# DATA iOZDWBBIp3lGtUl/F3AaNrt4jcCiDKFnn4DMDIS09DIl7y4u78dk79iLZGwJRU87ajXDk/UIddShp6iZ2OARCsDmMMWGNZ518IxN
# DATA jCheq1CG0iSMFb0JLOlwLD31XHlmDhTVO2abSHIZa7lHDJJnkYucFbvk0RyOaQmHiVfY5kFMzLTqJpHgo9TMzwMn6gCVjDKDkaGd
# DATA qcL7mFHoZE72izZrsoDZszTuwMsTJxYy++i/HX919MfjfwLV+ujPx789+v7o6+PfeWBn0w//dvTt8e8W6dn/fPTD0V/ovn84+v74
# DATA d3T30R/p4X+ne788/m3Bo08/0JN/OPrh+DegaCNoIWl/SX9/e/Qtc7S/oEf+lW4BSftPHt0FXvdvKdhvKdiv8fTR7ylaf+InKYjf
# DATA 09/fA8t9/IWja1//CSF1YskwKoIsJ4gszZ3ivqpDzRQgvAEvA/Nq+QM1QoTapi0IEoydU2TGjQeR4oUp2hX1fhMNtWc2WGa0rqVo
# DATA P8RD1AdFDp2dm+9l3cNVw7OtErk8YraqVak10+MLXDHT+bvbUZh116/TF66M7YjG+otEZVO4zK6O9UimtlYsTOpeUlb2BoV24aTs
# DATA e/0EOvUhIOY0po60/UoZzG4nRZTk3oTKbWEPuPh8yWKhTmo/GtxGXPu8TYrsu9T2UoWp9IZ6c8pp6t9qCyZrTc+KfX1i5B322g3r
# DATA 5xzWNd76dKP5y+G5vcKR/CIH8o3G8VMN41cyiktNNEnPdvs+06ZyGYBqk0bZHroqedx5K48Pl3NBdlJSGvZYKiOc9iUNPWyE7MuS
# DATA raw+0/Q8FDLtpH847Q+zArP2QoY6NxSyGEPxJkTq9xPPRFfAu5q5zLEZJZ60muVw3pJ3l39kge5UyMSs6CxLWKpXRUDpNBmTtdVX
# DATA FNxp2EaGyQE7sR6yVBlANuVXJ05Fn0JnaQfOCMeXdnxpx5e+RL70RkPKRvOVDQ3fq7Hdz2K6X4Dl7kDSDiTtQNIOJO1A0g4k7UDS
# DATA DiTtQNIOJO1A0g4k7UDSDiTtQNIOJO1A0g4k7UDSDiTtQNIOJO1A0g4k7UDSDiTtQNIOJH1tQNK1SjUMgjOCpHvVXrkXPEcgabPi
# DATA vBE92s4PuFiDoF8vV/ar1fLb9P1X8/kYBa0leKum5zdr/aBW328Cb9XMP9bxu42uP//Y0K8FXoUerZaLfsOrVOmDV20WazWvSv+n
# DATA 3xrFplereoBn+cVqk69VcHvgVVte1cfduFz2Wl6tWaz49lt5J2SebVXtBmG9vIxttaRuBIhPY9+vzAPa2vW23+4sC6W2AOOzKWnV
# DATA PDJYwrUAXvWs+lbzJPMoDBrthRhWKvXzx7DiV7MYBtULjmGrdQExbNazGDbqFxvDaqNy/hhWuUlcUinXqJGcO4a1auXySjnwm+eP
# DATA YVAOLq+Ug5Z/ATFsNC+4lE8D0pNBSIP0ZDyzQHqtWuBXW3mQ3jw2j6+E8yC9XrcVBRlIrx4GUaNpQHqdRrtLc3QD0muRdVxtXjpI
# DATA j7d/FtdZ96XqHJ/uc+uhRRZdziXkN/OzHp0JbGPBZUt5j02P28VKN9rbyYU8R+h7K6JxPQ4LEvd553eVXd+y5M1wvvn1exUyT9Y2
# DATA XVMrafOd/blVK+kIxtMbj3KWu3Es4IiB9oVjY1jxlEtAtWUOaPbDWeEpL9gink/VpnxpoDAsr0QDyyvLt0MtvKKEWJPNas3yyUTV
# DATA jcEuYbKKg05rNXQvK+GCXSZrZhGLtU0l16pGytm9vnB4KoBav3IalRXU6eajDgLoIIAOAugggA4C6CCADgLoIIAOAugggA4C6CCA
# DATA LxkEEHVBTRR32TothDj0WYCE76TAMmzl25IffDpsV2pL3P2fd/FjEbXlNgci4hG7anhTXyluvywXKoVaoU59ZNyb7yHVbTs7+nFz
# DATA 921+namI26NCDP7bSHd7u+oJq9fbuT1am0sAyOkRK4ufeo+Mkk937zzVb5CejK4oO/ep6s7oP9Dr7DnGGEfHtnc+y+XkbT4ErG1F
# DATA ztCduVSNdu9Qgvj4JYxRnrej+fE5OCShJCc/FeaPguZeSUHwdticy09DP9xS5/3QUWS1cpdGXZaQlVPGVB+FgfdQDh0jCWPqYBlz
# DATA ZxI2ZYsXyL0fqbfviOW/vGxOSMk02dsb5FJSiKmdoxZJkjjQX+L7R6YIFFAx2eVaqW3/tAOdRyR3p7CX++ktmkRQxU5oyIooY0ad
# DATA Qyk0fg29rfya3yzfqlbLt/dKe3QvjMVf4Ia7bNRv49RCQQUo29BxeUffHT0dJyMItoWDh+Fw/DjJP1v2F5+9USrXESFKyIiKaHsP
# DATA gekvcjeU9OIRr2ziTvZAbcunZLy9LMQGFZMU4APJTBZMBNxxGx9u+MxsTHpek4uUE69/+UnzNtfFXWsig5IuVMtYgRMAJNwoCde1
# DATA z9WchJXxNYJRV4fPsrp/W1WNz3Ub4CnwFNuNuAjv3ts9iEc0sSrxqXKul0+nv/61ungQtZ/EU/sn6S3u7Uz7NE579ycTrt1yJN0a
# DATA p5E+ziKpB7/+NeaDd+9RhMKDMKbZH2cf+ukhxskllfmUrSgZW41I+kdpKLc/59m+nSdSRhLnvHmxeHxdRI9EgQfSh3KKux15EU3T
# DATA dNukfsdMZZd0dXw+Lh7QtC7X6aHIzGMy5O1YsaRAVSksCRJr/PSICcp6jrP2NWn1Eoz41MyhWqdl47RslmnZ5A9aO1EbJ2qzqajN
# DATA SgHyyxK7uY91Fx5doTYximzZFi188+wE1K5CZVxMAbr8GB+8bRRHenMYj2bT6CQda/2s6ZzMBSO5rFTD5yWhZW+I0oSurJOw1sd8
# DATA Kdp8XBeK8Yfosji/ExbOoNLhBbS+rDRxcVIAcn8+Y8x6kpUT5kc2S3nJWvKGp0BlvjOfEdqDk2WFuTVLOj/oz6lbr3+Xv/m7/Hw2
# DATA 48HKqd5V2fxdldy7+MHqqd5V3fxd1dy7+MHaqd5V2/xdtQWp9TvBqd4VbP6uIPcufrB+qnfVN39XPfcufrBxqnc1Nn9XY0H//U7T
# DATA vEvrq5g2vFJd3Z6+vgBi6nqoEKSLViKyRhvq+54IWglHZ2gqJx2YjJCYPQCbzJP0IaSWJrkuT0LwC1614AU8HDVA0YpGLKTqYQcB
# DATA By1A4aEhgVkRo4Fquf/UQ//KMANL9st42zNVKRqmMG/QimAYBBGmWI2n1wPbQMr8+RcTctBWN3VaP3VyM6UXc6Z0WhDrM5cF5c1d
# DATA 2T6vy0B4WvKbF8zttMVLl8I6V+JkWUOQTx6alipcFMiMr8HKXgNx1OdELHBDeXMv2zmojSvxWur5spzYodyhyTRUNKGSZAytu0qh
# DATA NZywyBUco2QM4Wkyq8i+Yv4pr72IWOtYpvG8tQs6jJin866mAh5QBZUpN/KEngopHtA79rETUahAe2CTsfwkvZwZOdDl02Lop89F
# DATA mH2sGTmnHXuVkunPxlLKVUtnLDljaZmxlOuqnJv5pXczrzSynr2muq75VJ1DlpU+hAdgRPfxZqRMY308QdOEDPBcI9ub0fyYXc2T
# DATA SGlgL8h7U3MxCuCWMniipvhch+YcyzmrYVFE3dxH46puxjwiUekafWUMm0mv54X7Sdzl1c9REqfsEp9oTW3pDjLweJYwrehW8h7R
# DATA EO31KDQRUU95nVSOEmPwHUhcUt6/iEAOjRY49SyzdkqNfjYVw41l5MD87moiHGJc8t5TOtveMO5MknGfHTAKHxeFHXbL43nKAehW
# DATA o/ta7onP3D0h2xojpQavM+VRNBUzIs2knwcJNrJMQfOVDXjjkKGGVrenAXol7y4yk4KOx2MF3kYQ7JK77WFhG1cZvR3KXXaZezgj
# DATA gb54hNzR6HdJN6fKO6C38cr4muS9H8KuEW7xXmJU53GVzS0qCZjFUsAaO0+lLpV8mgyTySQ5UPreUv15lVwXDVd9TzJxhH2dyawD
# DATA DRjGoIvvKjvEm6VNGO4Gmk5FhYFPUZbXpedNludnzxgWeBYAOQOy6HgKEsFaFAtUKcInGKSmPIT1yWSwDUtqk5g0sKmXimlIt/dw
# DATA Qh1NwYyDUh2AQxRMAF70JGL4PGoeZeNQConJ02RZ7qEqD0Cip8jMRhiYsaaUjNP5RIo9dRIp6HWp57xyhfhIjkouzOY9wog2Dza5
# DATA jbRWr1vUjmMMcyu9yuucyPmFElMKazIv8yvzK8/5Wl9eS79IszKN72Jfw8sl0mgyFpYwC7gRXezbeMHkIZesqaxTdDpWJ4yWcrFv
# DATA 5aUT7Pte3TDzL7w5G5zTF//izn4yxCW9rZskk9TmW/7L0Q/Hfwcg5fE/MXfySyZcfnH8u6P/F0TJo2+PvlkEXP4LEyyBp/zCO/oO
# DATA /zDM8rujb4//zmP05RfH/0B/vhLCpQqYXsRYy+8p8G+O/qLplQzGpNu+A+Xym+N/pN/+5BCW13/e9khmWpMERhKbwlg0SmZ7/Skz
# DATA ckRmWg2vg3gKdQ05RWwmYrORtl3IlMKoFzK8VQZ8tmBSmbkBgwKzMOQzqGv5lY94xwX1hfHA+4QsRjaiHMkym8PpXuCqMZZLC+by
# DATA gJZcL1Nr/qirqSCP8jejsppbH6iai+HtImmWZKyykIJaw5S9JtQkxo5kuUFpXTjI8q7aWjWg5nFYPAgHTzJSE5nV4O0A/6OSBVu3
# DATA E+K4EY2yE8izKbxO2MUIYaBRoygiIx8L8FQvD3luoChIOD8/XiBZnlDzVpsly5rTsyJanpAIx7N0Y/x5xngNszzr0P5SuGavbFi/
# DATA nFF9o0H9NGP6FQzpUi+X5IAZ0J9h+7kMwuWSpHo0D6VPzJ4L1TKpJBexLPA6Z4hsjzsYZ5FiTu6yKPPGZ/XwJBFQoPRNbaybc3xD
# DATA jtsoh9rbBG6Zc3QjSioZRvuT3d3Y6ucd0Bwba8CifJAKFdD7eZqZUDLyk+WGXd49ilkMQ0DQhPGI15YM7RLWTiwvUJ5hFBovZN21
# DATA 0JDKt9qNaIwcxmQ2HPQjjkXosWnCG+x6kaNdOtqlo11eIu1ykyFmoynNRjbxVZv3Z7Huz23cO+SlQ1465KVDXjrkpUNeOuSlQ146
# DATA 5KVDXjrkpUNeOuSlQ1465KVDXjrkpUNeOuSlQ1465KVDXjrkpUNeOuSlQ1465KVDXl4b5GWlVguD+lmRl82o1e49R8jLJSvPp4Vf
# DATA 1iperV73KN88v1oe+OXA8xvld2uNptdoDirNildtznEt6d72Ig5z6LeqXoUyOvCLTfq75bXqxVpQ9P1ihcIPfvVezaewm8GgXi36
# DATA 5YbXbHh+pVEM6JZasUqvbxUrQbHamCuTIGq0u4t8wCpFu/GpH5SLQdmrNH2vPK1Vm155v9F8u1bNh1HvNLuNymIYzZoX1MqfFivl
# DATA RrFJkarUij7lBcUoQEyLzcYJZE0TuQWOnt+U13XiCWZLHS7+OkfC63DR+lJzJwIqzMW3GzRrtdoZaHlcfzUtT5qCRctr14Oo6m9A
# DATA y6t3oxwtL2p0g1Y7o+UFvTpsa0PLq7ZrzUpGy2s2ar4fXTotj6t9cb1hwN79Od80FRXOXn5uBaBtgxw7TRK9iHNT+bro/8MfauG3
# DATA T1pDWG7srIK/WbE8mcJnQ/bkwdNB9mqLkL0smFNA9rQDcmUe2TmtMlRh7FT9sz1GFbbT2Bgwg9iKbQR67FYLXOXV7LssXwt2Vq0x
# DATA J07ICUO0c/A5B59z8DkHn3PwOQefc/A5B59z8DkHn3PwOQefe4ngc5w2nEYoapuH0vjaugGNEUSSQyw3tLQ/9Qx9DL3BYPfO9mCB
# DATA 76RSvKM7stcomKcfybTmlx4+7NwY5CsZ1/yd0idJPKIAPqT/wIe6bczLD7f0sfMsLqXpU+Trh1tvLJxIVwHcwGdNirpndijoUDX4
# DATA SbOVnEK4O1i95mC1O1D9khyoPq1e+LM9aM1+ycyVtogjGuS0MPeSpIuzxR77Cc0xWyZJIJA1OtvP+nz283BGkf++YK32ZQfJL1q1
# DATA ffm5/KX67Rsck8/8tEY/PBKBOpS2lp1UlcNozDyOKAppMowgBMNHa6Wq8Ql45X5jIovoBubPl2cnxwuQQSZbM2vsPGeEnik8wEmv
# DATA B8e0PtAsuocIXKoav2L+8PlpRMQXqokcyA0z6+TZiNU8i9Os5nlnUDmDaokaXVahnGCNE6w5qx210l67HCEb7tN1MyBLSrQrWAOj
# DATA n0yTvUk47lui4s9MN+0CAJY0Lr+hZGis0euUmsViDCCQCxQsVmO/HsyH4ZgzxxrzlynfXohq8Qcs7y19I9VGKKSg57sE4eI3Yavz
# DATA i0Ze9JTy0UtHFy4fzKLF74zS2SCcinr5oUreARI6pk6851F/NxhchmzxjDWVppo7M2MN8LnWcLHvDUR5GhLfXU9E6PU4R8Pfxb6L
# DATA 6Y8PoknKUkxYqWK+vcjCMNuoGMZkwM/G1CCjC1ajbmSd6JwFTcUZggcrDBAxuC9YInqONZlNyyTIvGOSHtJaQd7w0Jgf0tsYHGUG
# DATA gLQV1c1yUKYoj8mBXX9UEzrM1KdkQJMTR+kKaakOAItaV8rSpYIqEItLeY8g8B2NPAavjDpUUFp+qqeoB5T3BaOQlajeWUuaYuHp
# DATA UGsl8YxoMmu3IZLP5cJMYlSTZMD4YhkHRONoMoOQl6czzeh4KfdmJC8wi92h0k3dDPX44kw/LIPCTUDcBGRhApK3MN0UxE1B8lOQ
# DATA lROLZ62lqXgdzLToh2OGDYeYYdji2GmkdPe0FOScWCSjdrQ6pEIfRTKZsXQep7YAJMbKwQH4STPBhcxLPEqLnVFTpr6LSmE/WqL0
# DATA uKnaJqd2fOdNXtrM4t0+zGZHzF1uz+JB12jxqciwo3HRbawOj1oAeo3eltV+Blbhk7KwlAWkf8zg2eYKqwj0mRXDPZsszsruFRq6
# DATA raTkIeDqvWYLAaxS9flV2RihXm7dYXpW+6lXE+5hM8MPa/AYY6nZqPvYtkyUI3f+dpqgqsMMb/Gn1Xd2BvGwzRHFh9X3UcecYFMW
# DATA 3XlfPmb33pS03ZnDlGtbU1bjbVMTI8oaQzNXutgMLM1enZHOLOdw0jXTU978IBNVlY/5fJgDc/FOatMdyM4CmdjO+Paa92RokjEf
# DATA b5OpUI6s3nkYM6upGzFMiFprVbwEwySdDg4V/BI/wUo0Uuy8ViO8rng0lSEwEjlM7JJM+4nSEw0Feq7FYxkoPjJSs9RyeVqs3dtK
# DATA CtODZaasQ3VQ62ozsH6KDPyA5sQD9t3Hkw5NF7MsxByVOgaguOyOTs1y4CmhbuETtUWHerJ7vErAtjHvrYTZPkzaeIR6v0jqNBXF
# DATA k1QWzRQFjMviIrLLaiWnzK/W2vwyTU4y7GeQ/KR2sReZrII3ge/J55FBcElGlrwPaMwseKySF5MRdqj8TwoiRt25UOJkt4q4wzRn
# DATA noYNxrhF3YvIKtPxnDKjGmszSvVikk1vw48j5nw8smoVv5oqxAHFMmVHTDgZqNVT7ZuBEwHb4EJo1cpKF0+z8TO8f3uHmb8wwhIg
# DATA 9uQLORfAMe7zuB1CUpfRFXzTM22TwSna5LsA0aFPo3ZXpEQXBXJlapt9mZqbUOtURlorb1GYHmJxTxPh6BGy+UV6mPNTbJEUGC9r
# DATA Rv4sK5hf2byGvZtQEdMYOYgO2U2Q1bEB/ZJZOMq7Kw4/mt1SE2RPXGasIUOoh2eHlV5EVYuiYm1BHRgnchJVR8laERcUaISTuLM0
# DATA 3/IDseytswdic0Wy4c77id4Fp5Wn2QRTu9PgFFElqSjROr9LJzHEXhQHRMYSG0dToHltlNj/JSAx7+iPR197jPUC/esvx//56Ouj
# DATA vxx9u4gR+7+Pvjn6rnj0ZwDAjn8DANm/Axd2/CVd/7ej7+nv39PfPxz94egH7/grCR1Bfwvo2NdHfz7+7dF3x1/Rv7/Dm8AiozdT
# DATA GF9TCF9rMNlfjr52NLHngAI9kpUf7OPpKJX6jAI9jpIx8xsZsM5DO7U9MRC7CZTP2duIgcZySSsxXL4LfXQmrM5voB4kFgl5dh6v
# DATA pYq9BXOJ2e2jQ4cTs30oqiO4appYvkAuFyMWj6w13Pu6lupfFllioykOAZo+Fl9lpIsmF8kTC6eCKOiHKQ2nsGDJ0k16PYcT27TU
# DATA Lpwpdi8cdLDqGMkC2GEGqA6HvNOel0AGvE7i9TCV8JgLx3J/ZpUDJN3hMOLJL8YSXkeMfxUxfcPrxtF0CUbsxEq32jrJtaVnxxA7
# DATA MQWOI+ZG94sY3TVP7NSD+kuxKHJVA/oFj+cbL4acajS/osFcaqSdB9l2q2ffdC4DJWanVRzDagdHP6HnsPiQTyhSYGKpCwuLRGuS
# DATA /g4Y7INxKlQlTto0TJ+ovSqIQDzCyTEc41NZshlKDAAjGar3wetSsKZuRnaSaiPDekfbBIBPJdhoB5sAa1sxGQhL7IIZdBfi6TJ7
# DATA QFkDDD6CHYDVq/QJBWbiEcM5zrWJ6tcAu7Sxh2w2ncRSZsmoE01GqeOIOY6Y44hdMkdso5FmwxMYGxrHV2bkn833eAEmvqOJOZqY
# DATA o4k5mpijiTmamKOJOZqYo4k5mpijiTmamKOJOZqYo4k5mpijiTmamKOJOZqYo4k5mpijiTmamKOJOZqYo4k5mtj1oYl1gsoi6WpT
# DATA mlivV4uazxFNzF52Pi1GzA+qXrXV+LRYLRd9yp9GtegH9UGxBqyW/6nvV4uB59cqnl+ueI1KseHhLtzhN4EBy2ddt9dqNXoLhDEA
# DATA vmrlllehd9QaXq1VbNGFitesI8jAC4Dx8nyE3cLrqq18sEG92W32loC5qmULzFVpBQbM5Zfz9aFda9SiJQEENSuAqkX2ai5Widoy
# DATA MlilcdrnrXypVhtelfKhEnjNIv3l+8NKzac88pC5Zc7i1QmxS5HurAVBP2g050hn5oEF0ln9DJwybhmGU8aNzOKUUT1qNMINOGVh
# DATA r5rjlPUq3UanbnHKWvVeI+OUdZudWruWccoqzXq13rh0Ttk4mp5IKcP4ou/bAPNlOcqq7CYrNXl5DEPaziIJzISsMWe5mW4t+IkX
# DATA 0J9KwE7HHJpLclRCUBHezKmmUmUcaxUz3Z17e6XGvkB2483ZNuJ5WoPw0ukq5OK3ZgjP3aZdYA7Z5ZBdDtnlkF0O2eWQXQ7Z5ZBd
# DATA DtnlkF0O2eWQXS8ZsktZHBaHqxseprvvhdN+qTdIaGIDs+/DLRzGotT/FCbNTXWNz0fhonylaRYMVWo1bH1+uHV3TBO8p3BRRoND
# DATA yo0bCPoG5UpvJnJhfDysZ+lcqbNWvIoEUhaQWvowV6gOZ0GDDEHKsZuQD2njgIo5gyV6f46y5Y4dn/bYsTtu/KIeNz4LXusaHENm
# DATA 9532d62nbImAlYn30qPKS/ha1+Xw8nN1hu8ygFv549YXTNqaqwxnRWxZjtTsELnK6QwLAnlGEZBXqiucXf3qnTd5gs+6clqHjqsP
# DATA hEJHSm9ODsKa6nMQ0hPt5ACnnaO92QDyfVp2bgg50aQHNfzubMIVNJwMtfS9OhPP79YRuEu2dUzGL2+b1VHQlDDKnh4WSdusxTmF
# DATA n8jjzSlimWCpdcBpg54dtwWcqGxHeHGXbLLZpG2EJ1+So55WGM6ucnbVGrE2u3I5XRen63Jag2oNbuty9F7+ZpQcoPsXxYF2uCca
# DATA a5DcUAObf/VyYhdA1+IVCLUDRF/LacPzRJ+u/nwEvYVIybAYt5i3/WRvZ44ENOJ1oAy0o4Iw3ZT+nsMhUaKpS4aezDBmedtyCX02
# DATA 9SyyJUeMI+zlzH5cIWcvfggAfWzBljG2uNJgv31ifPXzWb+qL2QQrmZ5WZztGGO7jh3lNRFmTwlTmuCuznRskFEnxFU9aqKqv+dw
# DATA YWvj6a+J5RxBSa0vobUqp4uokXNVtyhJqFR3XpW9piqeao3R1vLNLknvEu9LCmj8VczWmxLE+ShQFrPJat+28JHSp1eIlxDN3ugD
# DATA 3ofryW7A3KBZKyV6GouKCw936HG0C+rTGfVC0CpPZ3t7EXugAYzglQnVQSQTYCwAVWJVaYzCHOgIgIqBpnEJA41946rdQUCFTPkZ
# DATA ++OpaKAHA4XgcM8wYqFABeM0lZG8G/dYOmUq+kOs7OyprbyRiY/I0UOaiKOxRJ0okyRiWWV4GhEZLxxTncMAtynb6QUxdnMjmDN3
# DATA nbm70txdMG2cxess3tUm7DVROLzH6nvQLO5hkIlHLGO2nO+k+bKZFOAkGsaM6CisUt17U5iCC8MNC5vtzeIucIbZwEihUXvtzgAg
# DATA 5OFt3gTOQxMWBA7NfTSuG6ap9j3xUP9z5gRgPJskNHSEUz3msh0+pAY+gwml7IBwbxJpfOXikKn0DymkLg3VJjlwVS0MnCwNCHEZ
# DATA 9hxFrAnnhVNUaIrwbZvarsmQ0VPeHoV3xIAaUK6vmBGIxFuyz/ubFINT83PHmuGFjZwCCnkaTTox9jvmIKiS4VwwLNpnCRUqL1nJ
# DATA ewucLe5G2ZvG0K4+bC6+iwEmIFbCXfduNOV+lpMB0yaczvnbcHDNRNbjww1gn6xL410tR2n6e53IDzBr0+wd1fdDZbIgmnsaTIRH
# DATA sP5IBT1IC0zHSA21UxtdYia9j8DQUx7CBFMbLXlkmfCQ1IalHXXjTiglqPCZyMqFmm5hzqKnNOYNDtel8n0+UmzML8aX6HTe5Z2e
# DATA 6pDIbFKAJ5kVxoe6+Hn6qEg5MeAnynwdQYlPiX9ajDROUl6psuQ9iqInTAmBW5Z5HshLvlVVC61YmePLsP9UuCFQW4SDWDuKw5Qn
# DATA teHeKEnjdIHMwYbYSTrfjxPqmDg/sy6IW82pSdHs09Zj0IVwoi03t2oMcG+zE/sSyNDvofrqfTDUXENUXdF/19OUS6BE38s5y9Fm
# DATA qbyFLnsJpOh34ynPyibUbUEIUqCQilnDPacITF4CLPrBQN6JDpJTmzUunmZ1LwEUfZc6IN3i0Ut1jb4uFym8RZPuBbOTX/T5m8XF
# DATA oaemqY3F+a+A4Bx9f/T18W+Ovj/+p6NvvOMvgKihr9/Q5W+Pf7dIxvkXRt38K0Nt8ncf/YkpOR799OXR74++Of5HFcp/AReHrv1w
# DATA /Hd4gl71O/rlL/TCP3nHf58j7VgwHYfGeQ7IwgxmM9q1wsiC5xdIj4JsQxUucI+7rQNAuQ+URbUXsWLwEzicBSc81axEhozyIAqG
# DATA 4N5gPQHn3Sjs8Vsc/iY3x+T2ftX0G6swLg99I0nLukWuOz2eh83fipHD3MhTvUn/cNofXiTuhjfZ0rSnjxrf5RkBkHu8FRO3O+zN
# DATA iSV24bwbTHKTNuaYXM+0xxo7RdR0mPuXQTgZqqWpbPIZp+KKXthDLfrpbNvKXIJKi3oxTOvIdIGDewF/s77+rTY+snb0rLA362Pu
# DATA iDdu0D7FoK3BNqcbq18OX/DVjNMXOUxvNEpvPkhf/hgt1c8k2gzIV9cWLoNUY9IjhOR0PiF6/0W2iYHtiX4y1DAYq0xkpksDGga7
# DATA sMsJZQq6IVKkirHcSWYTYVNk46tOuBxlp5cgrzj4zbg1aoqfG4ND41zXo7cZt1O6sTsbRHpLJC9hwavopeOoE0dpwcQ/YxcrR+sg
# DATA FtdrRJ1t2IumhzlXoEoH43QZE80o4I4kKp8gB6hxgBoHqLl4QM3JA8dGc45N7Nersb/PYn6f1/p2MBoHo3EwGgejcTAaB6NxMBoH
# DATA o3EwGgejcTAaB6NxMBoHo3EwGgejcTAaB6NxMBoHo3EwGgejcTAaB6NxMBoHo3EwGgejuT4wmmotqnbPCqPxe8FzBaMxy82nJdFU
# DATA K02vWiv3GT9TqXl+rfp2Najks6PTa5aDRf5JjRJQrTV+4Veq8/yTWtCpNZfxT7iU8sFUWy2vUqv8R79V8SqVMv1peC3/Uz9oek3P
# DATA b1Q8P/DpXVWv0qp+WvHrRb9KZQhiTq3o1+mWIn2jm2p0k08P1P5jpUWPVrwqhVBtfurDi1zzanRPtZ5LVy1qturlRUCMRKhIJnzR
# DATA 95tDv0b5ghfVy8DzzKW10+q2ws6ytCr0DJViTOaHYtfUykHGrqm1ylYFrsmXwyW1uduJ6p3eGdgxXJENO4bbhMWOqVUaYVA9kR3T
# DATA 7nV79Rw7huLT7LQtdky13uKAhB1DnUQrjCx2TBC0q7VLZ8cMqBWcCI+B0+jz7FZDebE4Lip1i449du5V6N/mT2xzu8HmQxbkyUga
# DATA mzfDm+1kb/GyWBjXVWnJ+ilZWB6WKr26/MmF5imLxgBleBQ1vX+OXCNFPJdiChOWkRfIH+MalWQ3YVzZ/hzfWuNRQTQow3z6o/7V
# DATA FiZbrzwgrqTVbFCW+azLz7GXZsTKgBzUxkFtHNTGQW0c1MZBbRzUxkFtHNTGQW0c1MZBbV4yqI02CLW0z9bOa+tGM4bf6F6fT12o
# DATA xwroA5d2rZ5KmVWpdu/EuvfaZZN45zba+Ydb9zI1LxxWseRcRpTDStMF09c8s8acfHDnht25Yevkizs97E4Pn3R6eKXW5KWcKn4d
# DATA NRdKc1ng5mTxM9WfuAC9dGjN4c0HUfSETzhKmz2j1lw2tlyc2lwUDZQqd1tWSShDtPqgcnRfguycPm+swG1jKtXuBNpzHs2RosHh
# DATA JWjOvTPCoeap9LCpUsqGvdzLBKovQXzuMbu+VBrJBFG9OdUJGjuKUL/uXoLu3EM5SgwfIJlyKskGLnAp5crac+/jrHVoBOjQ8mSE
# DATA g8lC5iX2Qs0m0QWrzykPjJGOzzQZc8oA2eFWnRBzapYyDF3ANNeDWBL1mSi8SMBDQnXusD73RqVMXbM7OdQZnaEawsEBuIXDiCXk
# DATA cQsWqsjQGAxK3rtxzzSHAnAPg8W2qFRUR4jKxOvTj5MIC1aDQ3mSu5eDMJXoaKKQUqvlOigq72hs8OaKdjVNKrDEvq8CoNZB0ZT6
# DATA 0odvcKJOxEMnkx7t0ZCySjJA54o+7k/d5Agn33mbAY0nLAVAI/W8xM/cSPUwwnFAdYpbJq1yh4w7J8vGP+cnjx1y0tnvmf3uLPYX
# DATA zmI/LVLyGeoA8WK+WYhez5F8M2b5cwVHgej5yOO9vGsgklcsH3Tt5TQugw+ZiRxdNBzSloM6KxnS2qSgp00PcazKVAeZ+LFwihKe
# DATA qswVJHY1SCmq3Y0gNr4+kYdBA8AWOg1tvOsNZsN4lMxoimhsohFV8gQiNuNoMIC0O8bQvlJcJ/trVPJ+1ha5fTJMsOkaWkp9MkkV
# DATA 5oB5NvrtdjTegoHGd3FidCzeh11EQVDsqPJSrbHMLjb5+PxIxNsQDlNoqYcpS6hLC9Eaz0NIWE/WvZ/d0F7u3W9JC0rJvEx5Kbrk
# DATA vZekU23/ibgQs390rG8jg6R9gb0E5Rvqr2EbQNieuhGq6iwbMh+TF10kxuoZnK3mbDV7ZHDO1pfX2bqaOfksJRzf48VKXZ+VABsf
# DATA vbaglJDWYzjCPrTbpP1kzpsCuxEYMMlONO04LHkPMjFAnMIRlTaD9uEyZKdBaOkHsk+TfQe9uOOlNN3vGM9Km7eSZZqBorm4oQYk
# DATA p1gcH1njl7U+xGQUTiaaJ8SHS/AeeH2WGInqjOMi7VKtc6OS8iflJ1OeLP1jBkQ0VzjHgR2JOBx5WrmfksHASsFSAqRZPOdqIp9f
# DATA lS0B6uXWHaajtJ96NeEOM3PfYfUZI+ZgoJdGY/hDE2XNzd9OdgO3quRg9T17bPYwMos/rb6zzXYaa2RPxErRd96UVGX5IOOx9hbK
# DATA CrTt58PQsMZVuNZmtDyf4aRrnPC84C/ueJWDVg7MgaR4Z7Bp/bKUzlVoMuOcuGsSMB9jycsxG2z3IOIYTyBkinqfma2w14pKk7Mg
# DATA EqNFzMy0BikNY8OkG7Effwp7FoaftuAEpWQ7E+GANFKdEQsNaSN76v2KBtyS7V/d0JfqmW1ybGnkk2KyRkuYAfCK5W5uRPSM5XSd
# DATA t2VPVTxZ5TtlCT1aXUK6GkshPRqzDzZfQtSMuSMRjzuwL9DK7JP9I27Q0JO6rqx+ix1o1kDwvKyCiNRqAvVRTDlQutjBqKyU85eN
# DATA nYLrXzAPNi2YB+FkwKKy4WCoC+ZR0mMY64hGNdZMPcAkj0bQvfzcrOTd3U9izIwp741bv2C7vrlUxtS/YHLWVbNETA/PXR52xK+s
# DATA PLK+95Tl8R9Wl4fuxaU8/gMZLAsd2azTmQ1YTRaLgOokoWocerKqWHrUS/FKAs5j05BR8t6m1nVYoCIkMySJB6JyPOReLBkORf6Z
# DATA jIuhsMTopxg5aNaLz19QWYqufzE93LSYHs7a7fn+7HUWsVa9WTT6JDnMejAtxlXyPohputudUUe/J0tRRj5ZrwplFh6Y2pRXnXAm
# DATA dLxzl4Ud7evfib25aSf2ejzp8o6BERxA1DhGVuPpi+J1fzaMu0UsFLLEuCoPHnVSNuwhLTSFZf5BqLnU2Tq/zdtDCZvejkIi40lt
# DATA m4AWMtxD5y6nxQSdqbTy9p9sY7TtP3NF8v7O+4necKg1uMXkF4ubl/4ZahnSjAXZoUtZLZxeDhPtufZ4ZSy0tJ9EORTa/3H0r8df
# DATA Hf3++LdglQFjRp+/PPrm6N+Ovqe/f894tD95DDv79ujPx79dBKP9V8aofX30Z3r2Dx79xQEefVugEI/+SN8YfUb/++HoG/MSm6RG
# DATA N/3l6Bt8Uhy1fwMVDe+X9/5w9O/H/+SoaM8BlNtsc+Atr8n0QGNXDZkb4sVCXi3wzIi3WUUw8TQLANBQuBNYRoY6AIEzoAMdg26g
# DATA iK5UjydT3jOG53qyhGWcAvB0rCWnQVkeTUHsfIdPs3193EVcNT1tvkAuD6FGo0U4SPYyxBfvMOSXz3O4b/birJt+M55a+I6LY6jB
# DATA lFbnNlBDExnBORscPu3k0rpwftp7ggH32mRcYEcXzfv7NO6Y6WVBG1lpgsNQyEgYskgmuju1pxXzG0UafwqVlCjrnFjnq0A2lSxH
# DATA TiL2LDJhVh8TGFIRCV4Dg9V0ga22vl6uNmLmWtmzAqytj74DrLnx/4LHfw1hO8Ow/1Is713NkH/hI/5GA/4pxvvLH+6lIuaTbkb5
# DATA 69V8LoPblk84D5KcIQY6ZlLdPkRIBTnDOJnJqySuUwE6pcMQC19m6c2TfqkdpXBpRRMsTXKiaaDOji2o6HXjnmG7UbIPPUUy2ZDZ
# DATA NlHmGm+rwZEVMijYLxF1nmBsUmgyrmPCveJTw7wTSGhzccp7qNKp0Lh4aTZKp2IqIF8yy+G2opiBnjWdUQjDcDTr4fPENhKU5xV+
# DATA ArZpJofFZOSQbQ7Z5pBtl4hs22B02Wiis4lJfIV2/VnM+vNa9Q7c5sBtDtzmwG0O3ObAbQ7c5sBtDtzmwG0O3ObAbQ7c5sBtDtzm
# DATA wG0O3ObAbQ7c5sBtDtzmwG0O3ObAbQ7c5sBtDtzmwG3XBtzmB9VOtXxWcFvQq0e95wjcll9zPi29jWxVr1prfloPitW616wW/Wpl
# DATA QP9UKl4z8Pwy/VL1/Ap9qhcr1UG95QV1r1X2Ko1PqzW66lUDr1Z52/dbnxabxWrDq/jFYC5Lo1av0m3PQc/8Rq1erS2DnrUWS65S
# DATA 9mrloB80KvvV+tv0Nf8CE1aewlahFFTqgdfwi35zWKw1vFrTa5SLfoO+1Lxa3as36cvGEfOrCzELfEDiGp8Wq1SoReRF/T0KALEd
# DATA VOlCjhbHOznzL4t6jfoKzJ2qwJ14wifsnkqlr2ToN7/BIDlWNajnW4AJlgKAYePJ02VkrScPN5v5at/r8Xfd/7IcKou/VptUbyiM
# DATA U2LjuBlpbJy0SAsbFwXNWhDksXF0U61Sz2Hj5kBygo1rdVsZNq7WqQdBI8PGdTuddi/DxrW61VY5unRsHNrfydi4qjYKxCTQz6zg
# DATA xyGZc/7F4Cdejf5U6U89+IkdxBwv7p0hTSWmBWwFRny991mxg77aMbenSUG5fHvemSfunkJz/6DAq2QrVsRUNACvGn+26VJBqWbl
# DATA hVed5IPx9H6KnEFi5kvYVa1dfNrLmWfaqUyq0B8/0CY/+4riKVlYnRzITvuwqV+uLODnyqv5cib3C3YOrDFFTkggWwmOI+c4co4j
# DATA 5zhyjiPnOHKOI+c4co4j5zhyjiPnOHIvGUdOWRz5DiAeUfi7sPc+3JI2Rwm/Id+hCMPZwCbmh1uPwwlUaPkRT25G87rBF6havInN
# DATA dNv+zg3Kjc6w9CH9N7prnRK///P8MTx++L1w2i/xDH2bw/mpXwoQQna8b8mh8Uz5FlJcptvXqLns2Io7RO0OUW9yiNo+2uTOUruz
# DATA 1Gv0kp/tGWs5GlzQZ32XnLR+aM4FSh0p5JXVzKFeObCqBFn4LDHs6AOlwywneSNW2c8OT47DQ0ym5fAktFZG1snJjTWQ3xTV47Yw
# DATA orogUOHVoenQ0RE43eNNdI87YToLlWwaPq2+E10qZS1u/UA+rr6XOthuknBG/0w+Pg8KyFlenFIE8d5qEUSdqyKCSEbZ5LALHaJw
# DATA tB+mmQIiTk5S84KCeCdht8lsPMa5Z2w0wGE0byKykCnwHHKYnb1g1NSikketOsbR4TkdHR4Pu5PDgheF6SE3lPPrHs6l4cokKq36
# DATA d3GKoaYmK51q2A6TGczIrGw6s7RPNTdikVycQZcj1KHIVbOZkxkRsCphlwiGAQXVB/cOXUSmTK30HPh4+Az1A/7StmaenEudOkvA
# DATA c1AwH2xcMA+pqhfhVjmEBrilHMoHmwtUIuOIWw83G91AGCSDgqP+CA1H64biHCEUq6AYHo3ZNkSGW2oaIjiAtS0Z3+JBP5mx9Oj5
# DATA 9V1zSbmyUjpz5/bupp3bezF2zkDDYzaxlJFpgkJzPuwKnCZj3XR68WQIcdLZ2FMFk0xYgo1/FfWSA0rUJGlLdzeJ8JV1w2ajPhlV
# DATA UDewZTzOUyS5mF9ZiViD5CmL5PHqIjHDrZTJ40kYD0QvJSSzxhQKfZ/COIH9lkgOd2naAyMPVdPQMCehag5KsxowYa00kylJZGJv
# DATA IsIyOBS1t3MXTD7617+tPNq0rXwgc1KaoMZjqsKmYFC7YTnT1F22CMGw5mGcp6NQ9RinPN5jmg8eLTbmKmRWKprhSiR8yqLWKF14
# DATA Ts9dFHMxfnm1jl8EORH9uPNuOe/WJt4tu4o575bzbm3sxVrpBLsc7xYLbxkAXujtJYmI4mnf1rXVr13n+8KRBs/2gC04tYRuig0j
# DATA ah+yvpbzNqnlGUYzjbD/nieqaqF0uzPcUW4v3TBlUopSlFDN86Yry64Y10+Fd9dO0HOjFxvGbCBVeFv1MOQtr3ojbzTmrdclf7WD
# DATA jFeQUMsTVa5jo1qW95OpG03M9IMLrilfEXph93Rveb7XGa72Y/mlgB0IFFgcTejuUpC7f8GXpSws4yiUTTcUxH0tXzjXy1pmEsqP
# DATA osCHi3SqZPeVbbpkl6SJx2KejWk8nMqG9JsSxDkNIDFSMBhZ7c1Ws3w8EferEGPRDyyoRA9Yr3GkvbQFmTGwDcdekXAvjGXXFbbE
# DATA C0aKZg8lz0Dusnpa8rjQCjz4WUAWFq/MgoReZaqtY7wO1tQ4HgnGCmGSRWwkCLGgyApqODQGScf2oTRPEeYLoUBpryKmsz3wa3mn
# DATA QLaGqaatIy1ByXqVmezkjC3UQ89sF9B74sZsw2i8LLL6hTc8s6HGmZ7O9NzE9HS25otra660Dq+hWjWf6DCnCxbNsIFlhr4Fs5Nj
# DATA BQr5JJJlwlRbodlDLLvEne/1U7e+/pKv/Lec07nzKvWg8w1LHwtEuOYIV1NO+FlnFuVCOOBv8yLc88f1pJl2EkwW5F2Ho46Y30b/
# DATA 6s7PFk778Q4+KsQFcXPrKf7CadlAWDw7tqLtsTk4+EF4yNMX6Dkbw+weL9nJ5GhkFgXhT9yjkMaHsrwocyfQCMfhPs9dSt5DXs6a
# DATA agtK3aPsM9RKuIzFGccGz/xaV4j1cLLSNK1jo0owX5nuPx0PEGoaP8XWdVmGlOp95XCPKzeeMkwZVaj9aLA3o+7ChpX9y/FXx79h
# DATA LBkIYt/y5z8DXcbYsD+AKIZfjr9apJT9r+bHL4++O/oWKLJ/5wt/OP7q6M+4VPCO/nj0NaPIfoPvuIFfd/wP9Acgst/T6wAy+5Z+
# DATA /ppRZt9RAN/jt+MvKJjvACs7/sKjML6mC/+Ai0CjOXbZc2EdIm089YI/hOXKde29BSJpOHmCVb5wFBXg9qBZ6YTnjuNQpj8YZGiG
# DATA iqPSvIYEvQxvNuLAWJt8Fg+YjUotOuTdnDSxDKcCSY2wVZ86s7XUMoFJRzJQOmiZbStaHcZVo8vmSuXyyGXdWM5hpubON9QVrqgL
# DATA 9DKMe+ZOqnRSEycXDC/jeX6c8gYENAfeGaaj6ghmm5XahVPMdGfTi/m5cCBOpbTTj7oz2SYyEHY8JD8Y5My9mMdqr54fFIfxCLZ2
# DATA OKDKjX0kt7Wnl9EZYoVNIgpYQArxCF2wmIHKMpI2OTD45k2r5moTJ9/UnhW+bG3kHb3MWQAXZgFobtnpB/6XwkF0lYP+RY/5Gw35
# DATA pxzxL33Al/qYS7xNL7sWzecyuGW5FHuRzNFT8UgxhdtLevl9e5wN0z7Fco/XTdDoYuzTNJYRI46G4ZgTLq9FHyXnBqh2grqEpRaN
# DATA TJL9mjziSr33jDhbuiG2jHNOVQqPsmOG18mADyCIuMsOtGFARZAill4XB37w8iej5EBOR3TV5lJgo8YRF3U/mU3A/mIGVdyOB8gq
# DATA WHcMWqHxiHFTMBZEA4HxXOYMgQI5jZLl8CnHMXMcM8cxu0SO2YYjzUZTng3s46sz8c9i4Z/TwHcgMwcycyAzBzJzIDMHMnMgMwcy
# DATA cyAzBzJzIDMHMnMgMwcycyAzBzJzIDMHMnMgMwcycyAzBzJzIDMHMnMgMwcycyAzBzK7NiCzSrMWNCpnBZn1emGv/ByBzHIrzqfl
# DATA mNUpT8q1fr3e3K+2am/X5xFklaje6S3mZNmnrKz1g2aDP1cBGVOfa5Sx/LnZ9HzK4WqtPPSb5SL9qz77+vMc1ItyvturLIN6VZoL
# DATA UagEFIVy5VO/UfZ8Hwg2r+KXpz7cxs2T8GGNIGx0lr4pqC/g0PxGAC6ZV60UWzXPr9cAQfMDyji/yuS3WuuE13Wq9fZyWpkFUSti
# DATA OhBCoF9qtNdaAjKjuGQgM4qUAZkJji1rAbVqr1HZOH/rS15VKTeyV1V9/xJfVRUim7yqUm9c4quCip2qZvkSX1VnFJ1OVfWCM/BU
# DATA UDnu0jRUTnpHCypXq9SrzW4eKjePkFsKlYv8qNENMqhc0K1HzaqBynXqnahjQeWq9N5m/dKhcrK7sCjLDHqYq/IMwtOrU8Z2aYr5
# DATA Zz8zD4V7K6LOPA4Li/S32jL6G/yfjf2DQl38nyrkYbgZ5K3UWOfW1NOzLND5BRLbvNfls+DZVCWTC4fFLVa4vv663aQOrJt3ep3O
# DATA DvPYXYulqtVgOCur1thzC3HOT4su0Tp0jDnHmHOMOceYc4w5x5hzjDnHmHOMOceYc4w5x5h7yRhzqAvxlGb4kxBa7FTBbhvs3O6d
# DATA z8ycZJzucj2RXorPL+PqR1bLl4a/e8c0+7i3/SN+VDXcnc8Ul04rF0EMVc58MeJozF21GJe3P5dXd2ey9rxrB/RTwd3hUobAYy6d
# DATA LOnY9xb9nZ/6wQ0/QHR0aHckgPaM5osoVBMzlptlBdpRFHVT8O70M4DkiQxBarSXetGBdCBjOZUnYl90iU8w5pKDjMYpxl1t1k/w
# DATA YskqWXza5gndTkkWH7a3w8J+IaZCCG8oQ3t/56fbMTWN8mv18i1/p1DGpi9u9Vh/2h3u3tke3tn1a7Xyax9uvU9Vko9YcqjIIGX4
# DATA cD71BgnNWYc36+Wdn1RqOzQD67Ke1Xal8OFWGXfzY/qZ4U/oxsWbbmc1R7IcNWA75VirqgPn0S7HbxupZ9Tgf//in5Gx6W1cubG7
# DATA rDC341fzhfiaH9wq69zkUG9/vlP6JIlH9CyDCyXS6uONJa/sxaM47StRVD/QhYnTsuJwEQDiz0dQmRAcAJ5n6OH2XIUp6lqxY1cL
# DATA ajxcj0y27FAkb3OBU0kU9ayCnn9tncnILQ+NJwvnM4yDZAypQ8daOUOLW+iQNVtRVzoz76LA9Xno0vQp+hkrjhL2Ix2mfogGXIRl
# DATA MI36IJpTinBKEeuVIqxjik4vwulFnFovYqVO6aXoSDyYTbMGwLu2tKanjOxGVOI6yhhdhY69GCsi4z4RK2ZOuR6XMt16fb/pvMwF
# DATA I/Rebt1SC+ZKuH6FHr0acFmRfoqT5cxDMsLe22rkPUlJ3wRjopRdyZT0a+VlUvpVW0q/USnbWvp+sFpK3zJoEH2OOE1MaFbF1Sov
# DATA p5+72co3O4gFtXyO2Z1qWdsfq3X1axzPWnDynXUOs74kzAXtfX2AkdLNBxHvKKNYmEFoOXSr/KJyJmNCYdLAacqXm3Z8zGdCrpze
# DATA y8YzHgplAnLHujxXIBfz2ocYN7nF22/Nrl7OS+Xgo0cD7YS6idyb8z9leM+sXFbSEaQnU5iA5xeJ8C78eyJ1o4wVbcnbyhlGY6ZL
# DATA EzrL7s918mwGQfgjd4sS4KUqzNozkJxhPQ2GG7CYg2YQrNKgyYvO2FSwRf7Xck6YZGBu/oCRUK9QsG9LD0E2BOxEvsHzL26RtzDc
# DATA vMTNS06Yl+TsTzc1cVOTk2ccz1TiDmM8KriOBDJnkKncvWkmIgI8YM0n09ao9MKURa4gOMWaY0aEqiDKacNQHJdGCE2LNcxPLubQ
# DATA C9hmY2O/hUdrG2DC1/xAhOciIczCVYr2TYmhCp2aKQ0zuih70k9niOYe/zZLD2nMHTHTixIonUVBQYhkeqQHWgbSc3eRPtGBjvvJ
# DATA NNmbhGMeqscRDGkl7xtPWHpMkpgf9qYhY5XfSyairKvGunm4qSCSLctPUivmiIVD444MfduBwiBjm6Dq2MR3j9WpA6DIoQ93V/hp
# DATA gpXohzZeFB5yEAZYag2+vXWxj7ts1a2N/LzxKCkwSAGBCKeGIAwV/6kBPXdYEE7hL7QmcaasJyzbvPaeKpY2umzhE1i9dij1d02a
# DATA 7mKH/SgBuXU+WWIm5LmxC6qKpiKTWfgA7n31ZuQrmW19EHwVskGygH8AsBeRx1pyh2XbYNQUUIlGkhQw7+C9TWapyg8VcEz5cHc/
# DATA ibssSc0qbQAoSJbSAJUwMXYIqbUxn3Tj3SnLp/Qc678RmohygMukTMcZC+o54eqkJ7Mw6NANh0lXGjcKjy+bsvL04bmk14NPXZed
# DATA 1rCWMix441mbLBTrOdaf40YYdmEBeROuw1JZaexieDG/0gOJnQYdsrRTapPrkvgIaHAF95piELGSCEKZvJB6hhjaXtTdUVrH9Hxv
# DATA NhgcKt6Kiim7cVKuqJLuYY5UyMqC0icc9BOljkgdJHaCUhFP+miHUmDo4+cRtWKYvnj2tKOFOVt6YzVoZzq/0KbzaVlhz1gd2t7z
# DATA vx4W9hgjgYZdslEl9X09Lez6qEk/F5KqJxEksn3/muV1kVCxvEL2RTPF5hXHlyLFlPuN1bxRqLwLjYwgqRGpmDXJwHaHRmPdid15
# DATA n7VLhCtGUxXWJ5ZJE72Pfsc9b8aZ5YzeA5LZI9jlQiOjepPdKzMT2LSyOz2BhRdDiuxQ3XQzGaxqnmIvw85F9eWpRbjMwbgWEwJX
# DATA rCE5L+iPwwJjGeLxBDU6jUwzEwXn0ExXZZsNGfZD3EV2bs7bSjY3RIttLXS2tHkKKTk1Y1FybeAurLMt2HovmpWXYc0OorYSv7ap
# DATA Zv/L0TdH/1o8/rujH5gy9u3R90d/YLoYfTr+2+Mvjr62CWPHX+HKIuDs/8Tlo9/Tw98wouwbj758TRe/pcvfg0x29HuP7/kjM87+
# DATA Ue47/p0CmX0Nkhq94Cv693cKZMbx+RpxOv57MNCYd/aHox/oB7r/T45t9rzYstLI0fC0+DovWRnyJtaBaA4n6uI8eUsouClaPeJI
# DATA rfznUFlkhrx4j5J99vKEk8yrZJEQ0TzWoszeno+Gw5nZNm3WUVw1zWxJwVwe0Ux8KunCy9X1+dtlB4G5+2GU0gjUkQGbC+mC0Wbi
# DATA XhI9f7hWZOGPqQUObLZR4V041+yuZ+mdZzMDUwN40RhCOrMBUzjah/gbpymUew7UE4mg2Dn3Hvyc7hdN84LmVOj9LgZiwvbPPuDF
# DATA Hl0cLPDMNqyZq22cxWb3rOhmGybFcc6cNXBWa0Bjzc5mBLwUTq0rNAAuY/zfaPg/3eh/hYO/1M+FnLBQZ8+kBV0G2WwhkUw3o6xK
# DATA F6MFxpksK3tUPVFTbwnoqeC9/fjxg0cFdbBUrQxzyfCe0QnZD7yyw8nACA2nREZTmqiy1J4Hnad6zN0Ub2aqgkd5DWWwvAGAlMUd
# DATA YM4yIyAPOBtPoi58I3mjwDYGCtxM0Vl4MDBGHWUesFUADpWYh4Kc4vin9JqMbsZOlfQw5aOU6p6245s5vpnjm10q32yzsWajic+p
# DATA DOSrtfjPYvBfmL3vsGcOe+awZw575rBnDnvmsGcOe+awZw575rBnDnvmsGcOe+awZw575rBnDnvmsGcOe+awZw575rBnDnvmsGcO
# DATA e+awZw57dn2wZ61aq14/K/as2mv02s8R9mxh/Xkj9Blnrso8poQJbatWyR0W8+uVfK5XheUk2d7MZVy3GQVRbw7fVG0GgaC65vFN
# DATA NcliKx7ybomHsK+yeFTnD61VsmjU5rF1y3hhdYsX5reahkGVI6T9da3b9BvVxZrTrFHVafalzlnJC+vtVidcyk9bl7yKkNIuKXkV
# DATA i+a1cfLooQtLXlUYX5eUvKp6+lTJo4fOlbxqpXItGkm12ry8RlKt++doJNVm+dyNxE7ehTeSXPJO3UiQvPM2Ejt5F95Icsk7dSNB
# DATA 8s7bSAK/eS0aSVCtXV4joVico5EEjfq5G4mdvAtvJLnknbqRIHnnbSR28i68keSSd+pGguSdrZHYwNZy06sFwX6t3q+2avvFWn1Y
# DATA 9Ft1r1bfr54EUF3dCM5Cw2RL19Aw2Wi2aJjVdr3SDM5CwyxHYc+3aJjVetSsGRpmu9PpdjsWDdMP5OfLpWGqzbwyu7OcPWrZzfAx
# DATA ecJOJrrtVGvxGvuSbRO5UDF/XbxnfqvC4pJZk5fMSk1slZFFs1yoasF8bch1Xj3LP6Zngcs3G2Z302xybxIOc2t0JyVXPbNkeX7x
# DATA Br1Sv5Dni3dnXsRVOyTlRb4UkbgCFgLBUsMi6lNVu/xyQavVggfmdPBO9hgtSRW7DRd8z4vbhVZyPx2t09E6Ha3T0TodrdPROh2t
# DATA 09E6Ha3T0TodrdPROh2t8wJonYtozr24rQCKWJ2D6angmJpBRVdu+uVaM2jUb+fmLOoxPjyMxzTikAzz2RhXbvh4slK7rdiY99Ux
# DATA dugHjKb9waHhXDEikWJC9epN7O/frjAW8a34dUEqvotz5nJKeTyYpR4Emz31In5WRWnV83e9SvAT87ZMaEfmpZQH+xGjOrcpDj/F
# DATA Gv/OspBslqF1ztQJwjhBmJwgzOKhY6cO49Rhzq4Os1JJ+TJVY3RnDTkIaS8oLlZywEYb3nljSchcHx2zqwAaylDJoA8ZyFiFg6+e
# DATA ABLUT+a6+TSHbIMbYSlI0Lc4gnxTWd9pcIKraYJmOAdLUH1G2CxYMsagqJPgbf9N/PpJQEQrOJMU+5pJTXByWiqnSIZYG+gB4BUV
# DATA k2D7vZPjq58zkTUXrJhulukbxlTbQdxOIZQIyZHMbqGuaxxHJ1WXLJAMPJldMlFvnBTz+ppYr4T8mS5AT5l4PFSF/NxD/5aR/oyF
# DATA GJneDz0T1TFheXDz6Bp5HdgGXKThkOcAvDzDgjBqrtmhSRWrRTPUBHsjaXpT8A76VPnIOJzsRVZoKnd7Pepr27MJfBt4jiZXkwgK
# DATA TfFUC/wof7XMPFKW5WYlJqpSh2Igsw6mXc9K3r1kyG4x6voKSqxn1DX6T5nokprMdeWJcKJ0kTJbJoPMDileswn7VpX40AbUwBdN
# DATA KcYxT9xEYMVEwNn8L4XNf1rSyXVRirR3SqxHnrwV84gpaom8Hg2RuBGr9lDbGkZr2SfPTl7y+VJXO0ldem6Px2WATxYFNC8afrJM
# DATA h3QpACVXdnpLjFTkZYC/N2HPaxNh6R2s6rn2jtfFtDaGxinlvhX5j3GVMQsOAiQiGp/hVMpcmZub4DAfZdNujVd8+/F77xa8e48e
# DATA FdQ4LO2FhwWl5Q6IpcyLRGhxDJXQUCupslIjlYKR/YzTbN6gwXbcwOMphu01RMVH0hnIhrf1sMi7ViRUJdYpugsl0JGSR+XYcYIo
# DATA Yd0INL9o1IEi6Cii+Ck91gLVXqqufb3MJvKseVXWtWjOfAdyQtS14KxY0zraCqbIBrc6YBiJP0NgpDD7RfueDejJoZLEVLEseQ80
# DATA pwYx59Ux3ZGFXi+MB7PJOprlQwkGC1ereJYvkQVu99fOBnc2+FIbXFUS54l3nvicdbfSeL8++u1cpzFSZzjn0BNPofHAi68mTrFx
# DATA L+FBMi8+rl3o8/Sz2Rg4wZL3C+wRPzSIFrqjO+tARGaIsdhIGxt/OxON2d7ZWMg90y2Q5omvd17Vht8jHPPmhg39ilQBsGXGofqC
# DATA V28aK3Eqvfd0go8izI1XdcRZT/bGJKExmBp2f+kNP5cxvQdq84pbPoDJhlSKFjeLTePWm3jnTf1+GYzmo6EMVWXAGYuH39S984ba
# DATA nMg1uOBhWOlR359QmTH2k6ratMt3qjGi4MlgXNBS2+DcAVOc9iXcrorWini8F46oTnVtW9BE5m4mgT/3u0TBNt2M/UUlOokg3s2L
# DATA B9ryOjkiv4gn0xkU1VlK3IqDKmA287i2sqQ89ymTZGAi87MxK6qYG6iSR1NWSR/z4EkZNBjoqp5a8bmpCuqmqnQruPTrsd+PtJ2X
# DATA 5b2YfGF3SIO+nuVkbB+tJK5I7Wk/mQ263C7FnB3B8sPGc0ytRF1dCrjksX1JFvAgORxyEGSfg2cdQhzekqEHi/6TpM0Dp5KYn42Y
# DATA hahCWgcEHyUHSq9cm87htK+j/8GE5eyp3nssbiLObl5v0X5jdjqTNU7BhNrbjF6KOju+Bz8wIzWzcYGEAmRR384TI5DqR3Cw03Ae
# DATA jfS9XcV6zNYG1yXmPXFFq/SEIp4Pv7px7yvPOiKm1zMyrkI/GoxVfyYLnlZfxDL4NFAmOajCOAqfoISlx0Tdw5plNxriBfYMS4EV
# DATA KBSZDzIWHq3AnpopO8YGn5v1T9TPeLghQ/zFsu0///yjzz8cbb3yVy/6f5T10eBjdBjxaAao6vjwwt+Btct6rfZXat147l+/HASV
# DATA vypn//1V2fcb5fpfeeWryIAZ2hy9/q9ezv9+/OMfP5wJIaJDHUjc5XEGlWIr5b3IRcZ+ZBXEu/fuO9Rr8DInte9k0OUlfHqgRGG9
# DATA IlIpZNvu8WEb/f0Tsg/15yR9hUcvdPqDuO2pyw/oq75lYh5MZ23ln9FXcCQLw4H+PiPT5ZVXPnh498GD+w+xgXpra+sVPmPzitpg
# DATA 2ZN91exs2qbJZDe61Uu3dng3I06GbIHBd5N6xZug+t7sDGKawWzdfkW2WvfSEvIBbr5Hh6PONh4qeFs0X29uWTtQt9gpVEToxSy3
# DATA tnZ2tH+pFD2Np9v+zu1X5vd95qPG58g+Vg/RG6h3PBjxm7OAog5yq+D9UkVm+bs/Krzied5nUzlFcsvn7Q6FYfj09VkPex/9erVZ
# DATA KzwhK/NRvDcKB7e2Hr3z1t+88+67W4V02o2TW7/cous0PGwVtsbxGP+o7x99vqOyR21MjSYTGnp+/Wu9UTXlAO0LvFguG19XZ4ns
# DATA Id7NndbSz3cxFkwTdaxC5b+OBj/4GhfUIb8EB6Pw+h/J4aFSnD4Ke9E7ZBft4ZACbi8hv+5hJXsHd85d8171yssu3+HTNkvToK+o
# DATA uB7AkNlW8Z1/I92fndqaD8r7/BVU4ldeoSk03JQfM91oOx6lYxqFP5ZC58n/zi0UMbKAV9BxCTYAfyixNZFiCrW9VdzawQ+DaLQt
# DATA D1JCAr+Ca3hyEpWwn4C3EW9Ptn55t/g/hcVflYutj0s3b/0PxY9ubOVfiP8mIaZyv0DC7qP4t7feGe3jtI/Vk/AzWzv8jBqId7ml
# DATA 5xKzoxMht3Bl2aaaP/0YJ3UppjXvpx429Kp/1seBw/Wipx2ydVOZSKoYwN6cdNEboD8q8e6HbfVOVJ2Psb96e2cnl6cpxXQajjqo
# DATA ivx4wcPpAZOd6uoOVTvP3yh31FRXYUyjiYqdvr6r4/nL8kfyg74Re77lJj6UuPVOl4plSz0ejfbjSTIaqr3h9n00nevFe3TvZ5/v
# DATA yJX7o305EmQndb4ShMUe1YCPPqvXPqebTSx2dKWxssZ6+Vz2WL/sqMZznkzCaWg54MJfMVmXTiMe2TmQvWKxGPn+Ao7eciS3yM7D
# DATA 0xIMX5jMX3haLs9d2t1Se1bkWva+5cn6+SidjTFc0ezCiqZKFP7j054fU8qkp+Adg9v0moLn78wnZnlr/fgjq9l+9FN6EqdWT4qZ
# DATA znC7+tBzVsw4y0s0PEajrjqAatrrbLiNQsYtJZpsUPfG5/xQ9liHoOzhp1HylaC+QfO9b0VjWRP+a6wtwbHhDRXH642k8wSna/AP
# DATA VT56cHLI06eCzJc7XB9xkgEFh05ZYHpk+pdUkNiBRX2vouXBlsGclul9apHottDP4JLSM3/4oFkyFNPFtB9i/5U0V9P77VJkRxFf
# DATA FEeWMl1KjyPYLuHk8A0WFkwmhyxsFz/d3aIXj8LODAfKzUiOzpumql19c5aBVGofKyuGe1Vzy45309uya5p5RPvME3QnSVoCIWxb
# DATA h1PAlZ99/MHDn73/7n/yfi3f7j28f/ex/nL/f7z3bsErJ0B6mDA5dfRzr8uhZa+g7ulAIk/NLQqH+doo19RAiXZY+oQKbltVmRvc
# DATA NLOXTO2Ec0YrntquZSWWqMC2f5m7Df9tdbmWoLuUp/CpKO5dfDS5XspyfReHvWBdlvBXjQakfvS0sBh0saiqBIeu+6tbeNp847cZ
# DATA c1peTtPsYneSjHfvwuJaFm6ql2jIPt0dJfSegyJmvjFAMqmEQiVXRMltcY9mCnJnaYCIJVURPKltXh2KbjX4DjNFD/j4GV+UgZ0P
# DATA 9qMCnAXT2ST6WLZQ7j6ezNTBa/1RrM/darkg66Z8fSdfkFaLUYWqjSj4qcbb+ds3G650mHM94MoWulk3yZaYF7NPbGr3kmJfKIt+
# DATA vj5a1Y+NMsn0cDoNO307rh8tltqy/zbNc39tpquTeXkDe/P8/rD7mV8IxDJgGxp252i6rb4pO/nWKfLWmmRKpBayl+UAspeYX3vY
# DATA 8jGY6x4o2iZjF6OxpogmQykfGsY6Ub54PMmmXevpN+7/4v2fv/vuiSVHT9IsadmTWXkFurjehIDDjpoBYCTaVtWYJ0XoufUMu3R3
# DATA ssde/Qf8iyo6uQ1n+T4O1e80Bygqo5vSpPdeWBVj1TNswi99gm6DLaYe5H/waKoikeuw+dzGdjaZwX0lFZ+CJ994gqGs2afAcHr3
# DATA +R8IsZqA/lqN+DffeN3jaWfKaFDV1doO65L3MwzaocfoHg+7l0bwUnY8Gp/CMRk1c4bII3bu38csbOv9BPu4sxrZMT70Nl/vxZNh
# DATA 1N1CGVFF+/hjmAMfk/226219/DFK7OOPtyTSUnzX1JU4wSn2YXQZbr/N/H+VRrlam/f/lct+xfn/ruK/v/7RzVk6udmORzfJdPDG
# DATA h9N+Mqq+8uMf/5iFO4RXi8UXWRjDGgNWfLFckYwjDb3VG7geajPK49nWYEDdwhqvIJYp6jX9DXua9Od+mMI3qL/G0AebWE7As/sT
# DATA ZQXRfO3PpvHAfOM5hPmWDlZ7ISk/jEMynNj+yHn/5LQ/ERieuUDtLee85NjPJgOKvHSiOgl0jeeB1MfwOoonE/mZZLuMntlAqkYI
# DATA yu+7dl8H65qmP177kIvIFAwb7VhRmUSfRGopEHkjE9CUy02/9+fjvUnYjX4B4QP94sW4mCGKsklGLmwo26ZpUpp5jqSnXZIQfZt6
# DATA lGV8UKT6ORn8LccNT3j4Dst5w5NQbBDd4g1VWzs6PJlkjNltqjwA2PCzKzMZeccUB2Omei7FQeuZrvxUitOP08Mh9stsW3YlJ3Pr
# DATA 6H8/+sY7+uPR10f/fvTt8ZfH/3T0e/r8zdFfvOO/pQ9/Ovqzd/z3R98cf0HX/ugdf3n07dFf6JYfjv5Mt+OHL4++O/7q+L/QT/z0
# DATA n/H1lod5BCx7iYEaHlV05NxjaQijflu+pMoG5Pnsx4lt+fHS6a72l/RW+UQiMj0kn7uz4TjVv0UjrHN+HKadOBb7BFvOMNbuVvRk
# DATA TXwy3QJPjlndSU14h0/QfYzNLLeUTXPJtKDY7+ZStMR+mJti4iU0tUS08gWOpfkDzCB3efa4auqJkDp9qgHbahKKaI6S7R2pFjur
# DATA 56nIxaU/9wYzKNEsvAbblOffkt2VYHmBQWRatErK2fb50D2coT8i44JmaPmUmCn/x72uNaPP5aea1j98w57Wv/HOw/v3Hv/s4X/K
# DATA R3lhmp1Lh/22/HNLbXD1LGPilzy78IwkFi2vxBU45UzZWSi72YjbIP+oGrisLSsHlXGLwzulFNnggqqucHhvv3Yrc559lPtW/Oiz
# DATA cqHuf279vvPah6WdG+rCR59V/n/23r25revKF7x/81McO7l9AAkAH3pYgQK7KYm22ZYoDknZSVMMCiQOScQggOAAktg0upy408md
# DATA uJJJV2pqqqu6+6bufABZsdqKYztfQfoK80lmr9d+HwCU7fSduZ172yLO2Wc/11577fX4rcrVS3APspu22ML/eP652v7/rjb5z4BB
# DATA fKp2/BeKBXyZPP8EOcHzPyuW8JV6+ZUqCNzgcUU9U08+VM8eJ8+fQYmP1N/PtBobWSEpCrsAh1KSSVAHlfaIbMLxIbsXVGbWVPKV
# DATA ztNdcsW7KXiM5vXFReA9PK+6Atjqi61BZ1G1le7F53npylIwDf/H80+B9Sku9xiYn2KINDw1UjUnyDLV+J/BO2CIv8TJ+ALmS/18
# DATA /uXzLxVLfKp13eqainpgR1taSR199nLy/QbroLF4GX6vzFof6M0zWJ1n0DC0/wS6+Xje7hsWT2fBi9+8+Bmwdb14rCOwNNiofSEN
# DATA NnbU1u+NEKMH/w0u52qc9IKJwLH46DX0do9T5e61+p5dnczWKV3gbV1tbClfeiH/aF3tBevH35K7P1rcu1guqc24aPZerfn3VfX0
# DATA QnnxjZSVvYF6nCoEN74egDodoTJZze5ZWoOLfa2WTsgD2LzCT3ZX9oSS1KyVZwzdH2/d2dpEPBj5UTW0k+B3sJlf/Pb5FxXDAWS3
# DATA 485/rAo/hopUMcUZnj8BHsD8QVUuc/2nFx8rCvsKyBMoV/3+jTWrBGQY28k01uU92MkybnsK4ctOjwl1+iTM2As4IX9SW0steYKD
# DATA +oyFHdXjFx8rKcfuMSui2NAAyIY2t6O3MTZHwzofpzvX1tfLOn24PBTguqQCnMGJsTT8QnuWKgKbEQmTVwC+0gwWaFmRJTxH84cq
# DATA hv82GiGHPpSXXDgPD6Xf0zBefBRZtS9ffKTmBMkYjqVPkbY+pn0bP7/wdLruvFNkrCbsKU0kVB2Q7IuPEyoBDzUl8HJjt2OrrW6p
# DATA pVH//aznrm+xAVuxi/u16b8VV7Cr9EV66vlHwNnVyFY316tmM85BEDyiUrq6udncvLu107i0tLx0v7e1dmdj9b3Vd9eam6sba7eb
# DATA 97ZuNziNDUrHD1sPsvolwH3opc4uTM2XqjPNnbvvrG2gsQIHQaL4+sbO2tbG6u3m37y309xeu7m1toNF+P5bw6LN4+xR6RJI7279
# DATA 93s7W/e2d5qbW3d/8MPG8v3endWtv72xutG8vfbW6s0fNm+vb7zTXNtYvXF77VYDsWbRUEOrBTdXXwqLrRDq6lmDDPcbhrYVAQ0P
# DATA b1AZslShfl29cuXSlWCJ/o14p2E2RJovfkUUpihY1QUv6Xt3UUwD0ntyCEZ13jyjYIlwVxMTCIsrU6RBRVFwIKoug5DwuSKcL1W/
# DATA nwLP+eLFb1gY5DePRdcSEfy4v5aJr2Qs9HVX1DibhMZyXXiaiwCuxu6eI5+D6Ttu9kYT9oGGp5tmyDbd21Vf7SGYHX5XyPLFrbXJ
# DATA xraSZVsbZNkwV3ecB9lw2FF3+jQ1uhBCkUTVh1hu++BZ3DmgwALEr9A+s8JDk/0MHIhJC4JCCqiDG/6sgdNrOHMb1M4dsKJpgZQq
# DATA gBNZfZO6Nx7uN2rX9I9XwrLByfUZMll1LinKUTznKZH8b5//DjkrPAJeC6z4U1BFqK2gBBCotCqlX/zaYdXOcYyLQH3Apzx/eTgP
# DATA POLtbAQm9DwyGTnRElMibyapMDyXExQav0S55o/QOZAevEPlSx4Q/KN+sx8AiJmwj9SGV/KFOuDgI1UdnFYwYU/NksTnnd06ivs2
# DATA z8zzUfC56suv6dzgTgTDohPYXwAWxaUTZaCc5eCi1gONVwdQd3VBxceCS7wm6obWKJbifGM3vbW6s3pjdXsNTqN0r1yTb22jTOmd
# DATA 7BR1dpUk0D567WnrKq+4vIoetGqtgEz/hCsHrBuZ4VMSQEBGg4dGlqYFVZKlYp2fJU7HjWzF/ZA/9XVZXzzwFmkxSOAlsP7IU5xt
# DATA Ck+03xWuiLcL8DFXQU8gECezd8MWuZOocp0cJwS0c55XA9mcjFFajM1gacuK29pQw7O2L4yFFEpKmkbLPoyqZJWff8+Wax1C8gwM
# DATA rDi9hTumcEhoPOx2EP5HzT7+KUtDAVjwBDssvaeerdJHcjCVPTUmfkZqzEmsMTBugiqu5E8b+nSl5VqXrthw/5P+uIcW2yGo3+Rw
# DATA YfUP0wRIVdZw1HMcTLq+uUoVwEX0rW5/v9Vd33xwVR56vVaD0zSsPpcZY+leP5YuhRPPFA5Q5RzQy0pGSEpQLuN0CHnZimW8wECR
# DATA 2rinhO7SBamIbAPg4wVHGu8fVBhjcZt3cU2oSChWBpldHD+skEn+lBRj6p7wOSrNn0WPB3xBp8B1kaOeIIv9GK93NodISD/x1NKq
# DATA WQeCs+1lRmKHBM/Ay5/Q0EE1Fb8F+bXodCjgbtY5IN2yOS13+6UZrdtZVY4K6Gl7CndB6+CqJc9/RyfvE+z6L/HFH3msn/Gq/hFX
# DATA Au8vN+GGoce1sbbz3t2tdzx5KTbFkq6jz+Pl3zk6V5a4eBl8Z0lwPCARummfeJ5gz0JxjsdV0JKRWUKDCURklYMvSEAv/Aj9Y+sL
# DATA gdfQ2cTh3lorGBG1Q69WLE2sL+QDvPb/lOA9nK6nT7Uh13b9dFQ2+haFktSHeOd9lryz9sPGu6u3762JnkQ98Dx18Cag81/blwLS
# DATA V0IMPebXhYtB1NlI1TBlGNGef4lGtk9R2PqKtBI/xYu6dbli3Sxpc+Di9cd0jksJurrKaIjdOW5j7n3F9HTqBHvXVPXn/87XPtSW
# DATA 0tRa64VPvQGor3+uL97iUa96ZhtOJabCGFQXpvpFO97bfPl2XdutmywIuTCNnyGL+4XoiAI+RvwYxvQVDV0N6jeRW63ZtmApa+bH
# DATA rZUrV+3RtDtHEM3YEA+BGhcpGy9byy6MlrB0uB+3A8ImOzge996HTYZidLd1st9u1cWih7kYrLiDciXZT319OvWoRjHKJazPGRe/
# DATA P84e0V/aVkORqE0YiDpSjecuX977/VHo1ctWsy4lKyGWNyC5FXW24NQMIwF7MJ7RAzBZwwfqJ5xgA2NJ3H57Vc3c9r0724brgpZx
# DATA 4Fi554gQIQ0a1Vw2ncFuzqUAQaIxRnK0niChP6E9SgSlNoI+rMkUC8NdtMcB0RDkQ+yQT/limiTpRerhRXT493opa/IA0QiatDRm
# DATA 3it0ivTA2J1SdNzsZUIHcRGk9P1i2H+IomDQd9uLoUxqE3SEtqXuQlOJWodW9RB9X8tJUvJWpwzue/2HxYYSMQOgGA/djko0hSsn
# DATA TOorS4bB44LVxi9+DifIR4prfWGxW0zK2MAZXIzZIdAKHCNFecFkrZ4GzAIIXOwc0bH8s99LltCol6Don0aFReoVa3Q4jShgy9iE
# DATA KzDolTrvjbd4jeKwa+B2wV7Co8x/KK7euX7Cso1TUEsrmmRR7URUa0sd1A/sYioKMHT5ECNr16kEnQ9ApeXv6Hu993sQra9hX/mL
# DATA 1Asu4nF/v+GTmEVeqGqXxXBXAB7JCtBZ7itNcNLkpKP9Fc5jOT49ODKO0YdP8G5oDaV4+BsIdwKvuAM0D6m73HI+pJIcvgq5I4al
# DATA DjHMDnJvQGvAeBqsaFeWFxHm0r1yOV6lNVyPQsrmvhb9Eo8CURRAD3btkBGeNqCzw47q2RBdeLnqPYr+hFaR7Yu7hgme4y7xGLhb
# DATA zkrob4qocsq3FkvsdQ5JJLAmYp4v/dkAHccuZxFJyRCHaWnwEkKN7FLSERo9lccxZO10z+Gu8gHRERAHqoK2+pQ/0Jch3GFjHC+S
# DATA QHXIH3i0O9+G+r/5QGWW/A+Kc/1BCcXqqvziHw0XI1WlYuZ4V1bSmbqOgmga8HHkgZpDkujsXrEGzinomkCY2+NB6QaR2Sy9tZ/3
# DATA u5BPzZog/lLXuwgPFuY6JJRE3u8+wExBeXOYdVujzoOsOerbcVIgCDhl0aQahlo5In1VSytT5PlfsUBsHABJiH8CFlacWVRkgPUe
# DATA L+PP/wDnDt1aHuN8P7HMiDJY2TTIrMLjcHaH8ej6japb3dbxjv9TYKfFHXbFdHeuFpgCetl4NGwBkARRgmgklFyrsWQARQjm39hm
# DATA AE3wqAchvpRHqds6zYZ5Aplck9bhCHDM+z1MIIt+otcZrIWC0AltRTekLTUxBxvD3+TElO9qp62Trn2Umhf0nMJCqoXfFb5Xr/dC
# DATA IjbIOouJ1qv7G6FwiSO+p1H9Krfm7ktrIcw10KIs1CXiCs2oPfAQ5NXHUBDVUS98W/Gna278No7L3Edhw52lgp6U1pOzidGEiM3h
# DATA 7vY0k4PbC/RO9WeWXxdKto9Ron2GuxOkWu3mLjo/lDZgm/ycHUW+ADXDE23kYQPFkwJ+S5Y2ur5/ijo3UlsiL37qKCJcTxizWDG7
# DATA KIMWyc4L7pEslcWvKNbhSeWmnZwLzs2Bz7fYEY6dTL6TMKot4TIx0FCnV0VnVz29jO2l7vMPCESp321r1CYkpwX/TJ3lhB29pIBQ
# DATA j2qHfwCF8oufSQeqwd2Sou9FnpBW2YXa7F+eUSwkkxcRN3dTPedgTzOck0dFrTmlQNYE2dA05npFGNQBLY+gf8SlS/PPhnPsFM+F
# DATA qBosXioykdcD07T2oi9kPyQ5wWNbbDJKQke5Fkpa9TmiE4WMtbiN/iYIY+GIecXK0hmOGoVTpr2UBYla7y23ZX8QUj4qzdgv49de
# DATA KYE3FWqJ3vjzdZ5LcDjIOW6+7lrqnqN2A/MvqbMBcbyzkgRpWIGcXYM1wCYkrT6WtQPVP1yHbGvTGZ5ghyzMVZImgCmIemeCkwLF
# DATA CnRSv1Mj/gRNH2Q0eixuqkkoPj0JtVGSENQlXr2557gEYNQnWWmFXCCAv/AmYO8O822UdNzXceIxZXCmZGuHXY4qUzbN8K1rsHSY
# DATA giUl1gc/yQhom2C0xye2TsieSWStVtdcY7wUnMU65+8x+/wAwGFLzdyxEjVNPXYnh52TFvpQFwtYVve4uHdDlErYkjidfl9i1gHb
# DATA sNVLxqyckeMWma7rJSAM3e4z5e7xl9uNj6LNSM/swRVHTAHZuZFL/I+5e73iyMhx3fN9K3rI2iEaAOAS+t+5DZFu2rQvWvCNu7fW
# DATA mts7qztrOh5mfW0bdywzUYQHghOWO2PGhUr2IuY6Y3kob5ObCjg1WuKA84k5FOnBsU9rG5VvvrTixDhc5qSTA1i1GxVGqr48bmDk
# DATA 7/WFxOMbHKsEE+nZY7hXAgqjo/FsO0g4daTWjw6+gTPwV8lS/7XXXjM3Yj3LdoD4VkYoEowcnD3o9Md5sn5n9a21SjLOKTEC+AM+
# DATA zKx00b0R6/7UZhkAGqZVIyHdJT8Z90et5MeKJOBgx4V8iHHhw0xN7TjD6PMOohZB9q4232IxLGM8MOHmHIxILKDi7Tx0J9xz96jc
# DATA z9yStnbQnUy8Sc9/A5SDFL9Si8k9K1ogLFcJ7mzah7bb6jUJWBL0yk2W5ks0tArNMsT8Hxx3MA285crJmCPMENoNIGlRHPAPS0XZ
# DATA pCrxha1WoNuDyTUhHlQ65FVtQ6ACi9U87ABOG67pw9awbfQJYPstVgmTWh2DTXg408oFgsc/oQuGrfD5E1lHKVLssRh5E5TSnqrL
# DATA 50fkGeNpidBPxKjHf13gU+hZfHmyBQnLgZCLIcUpPkzJnoEJ5x8ALNYH978bgYazvecd5xJSLUK/nj3/jKzYoIRSEjUakj6KTAVf
# DATA WODijREksaE9oMBkzPeul4ofFo6e37vjj3mpXyy9Ub9foz/LZ8sVCvajr+cZtLh/kjPST9F8ER8qmZnC8QltNc1AXXILxhp8wf6G
# DATA 7hERTor/3UvOjl9NeV6DIpl57JlynX4j0jdjl6DTGhnw2WMmUTxXSbsl8GhQ9/hBCUHBHLf0mjqSIA5qd2kvuZBcLu/WL3tiGlQc
# DATA zArsCXozdXy/Z68IuGY/RhLm5eZ4Iz0y0Bt9StokHjj4fkyzQF4nvT1win/XHEOR1M9pMzleyJ+yYv8ZBaSTxlcoy2BB5+72sd9w
# DATA YXUENr0PXDKMfCNZdvyi/HzV/qIStGCsST6dWoUsnxXMPWD3kDmZUydjE6l3rmtn79RvhZ0lp+wAExTs2twBfs/4Q2hXTacbXvto
# DATA +FNT4xTSN1f/U3/j+jNnJuUcg7T7GiyFX5WPjkkLai3G/G3xt9rtCKZBnukZsAqFQ7L8kAMqjbV0Dr8Ux7uBYrX/EXWIP6XYTI8/
# DATA BQacpzqe0OdclFsB+osJOpztB0+2SbwCqGJ38zgvyfbNkhg5rSmZiApqAQ29u40mtdOT2fJ3i/1OV6qe614WzHIwn/+q5oemQHu/
# DATA /gkDCz8JIjm+Qpb0Ef73Z8+fsIxz3rkcDNCrYpeSnbBveqNheo6Oe4HNmynCiWQH+qMKDfnxb03YFsUVUht/E8zNf1dD+gSDKx+/
# DATA +PWL/8bMW+ZHQhqiWrc/U1yLqoClBnCd/hlS7EeqpqehGPW5jnlhgJdGQdQYu9hvbnLAoAUuy4LCpRXRP1NVqHa+vPS9qzIrB8dE
# DATA N9gO+deR3e0+IqvdR68VhFPdC2fln5wRFxBFVJv9DE8+dEbEB9YYivT27GIxRTmvdd+Flyj2jnTi6qKuG3tRWAJSRqLmfsXmfOyS
# DATA NkNn+S9WlK4vYsu8fMl09mGgxwxYl6gytW5LMgPw2Om5M3zsWCW4HeXZGjj5biKaZLmsrf8on4EoBk7TNQA9ej87zUu7F7gebmLP
# DATA /qSWPRqBKng++7L48tnqd896oS/SUHs9cDeb27g+x8ERqo7jgXa6p6L3PiPTCLqhkvUPPMJImV+P+LoFndceysLyIdU7ToRjf05r
# DATA ig+kZm4kVROF3fiXbKBQ+qscO1u0q5HrX2v2BZWmTwWllDCo3VkVf2WS07E4KS2neODTiI3b/Vzgz+ex/OCCarDdQhsvYrVEF3mK
# DATA C4zuLK6SbfW1HVyMZwwN1llJo82xPbXilO/uPmq0/O3uBLMDlAwFQS3GB7xovhyPs29rXyj+wa6YgD1Xa2fZAP5gRZXlKWgEKjjZ
# DATA 04pweY4WB+3wK43gYZErToF/wG/ESf5LNKvB4Y7IFAnESqk5+wM442C4qAkRf/GRHO02RoIlDEacYOJSm2z+hszKrtngezh2A1oR
# DATA 31pcPAiKcQNQbFHlC22WKDrtHXG7iFayw8MMFYSq8yXRHM5iV/OMSFc8bUzF+h748UcZD8p52oe1cPXN3eJx0XARtBrWVnePBkjP
# DATA nTjrMASJCgUxSE69MNZSJHrfZehc3EMEcKaTilDvOn1jtanxWoBRM6NQ2tQm4CqkIkzjwaaNBl5RCpn3Oa4dqCL5giJSgNhMtBNH
# DATA qnHITQzUw4IRDvedMCyXvqK+VMNM0X8HBFAgXm9FOXuGRJTyYvw1Lsbu0l5tqNGK8El1WeMX1aWMvRxWW4iGpH6NjoYEJC5//4Th
# DATA 0NsdfKzWFJIBACa4klEeoaNcq93GJ0ogyw4776dR6+TzfyvcubDZf6moHwTTX2CsllqfzykKVDRUCe2gZ7BRcItgABqUQzCtD9GD
# DATA 8tf2nekja2F4HXZ5AiGSC//yC9QG/UEp3R93upBIA40Ils1n57iTMwsBnBAwIfQRrg5cnDA5gHbxgNfDQb9LJm44MUVWsOobQj7U
# DATA rAf0QcDEbIOCvAI91SOA4OxC8I6qsIeJD3T8GMAVqwOxFo7QhviHcZ5duBALePSlL5OAAs5Q67pU58ubBiVMQb+ffve7EpusSdQ+
# DATA ZWJc1z4/tLYDOmWZpewuhhXjTX4v1mdOBaLKEsyVXQ87mdJnbtwsKsbppLDU4SQWSO9i3y24AfWWnBx2OgyVF85VePRGGUPxRE1Z
# DATA y/CMcAr/T3ZC6LUrnHNtchwid5SS6xvbO6sbN9eaOz/cXINlBW6mdggyMsLp7RPY/sFx1h53s2E68bWG9L/Sfr/fnUF6zIVJEnbm
# DATA U/hzo5EUVaF5ULmgA9bMq/lg3Si0pH5Zm5B2IbUlhF92DlueJ9AjfIPHrhZyTGztYzLgfYY4dU+VWPqMw4Md76nphy/B2uK2uJik
# DATA 10PbSKh1dYJHyUymnWmfFJtRtf+6tga7LlohP6hbmW9QpoxwF4+Gu/rIdojY6M8s+RK+cLRl8GBuVdlswfOrmOD5NI5Jg2bmzzlG
# DATA f4ZwPYV1z2L/Mxg5XcUOui26izktTmUNakb1dzZDxzyx/CK2h15BIJy42DJ9jp44NxYBM7SiKELbvDHt/gHWJgJccV0I/Au+FaNx
# DATA 8EuResDyR8B856R4j+rP3GmsJ8hvYof/xA2kcC/HeMu1sUx1/BQwuoY4cITmvQZpwyuJrRtt7OJlnlR/5T390qgQG3YBK/NURO62
# DATA fJAR3g7Q1QPDo/3lDhS7p0qxbFBYcJMYPSGdGH1nQV3+li/4YlNL99690/R+pvkdo36vTar678uT6mX945J6ce17rf0954n8vUx+
# DATA crqxOJshVI+pMJ9hYMTj5Hznw1Nk/4/JMeIXgIcirgAGT/3jIEJit2ABQBA2w7JDJ860p0Q9WYboHa3+r/t+oyhLkOcma5yYBt1M
# DATA LzqgE5yg9N/qY9KsoWLKqLIoQxQ4eNVFzyLRvuoJjQq6xbsWSvGfFfes3jaeV9GtMBFfrJlafNSEC5SuhkTBn0FQR6ElxALixYtm
# DATA zBffdtsk9Mdrkx364+rkb9lB/77ENmO34JLrAYDrZDyhPjsSziphWX7AtB/1FQ/2KngK31L8a9C8iWkNYJVNxz1IJPdId8COvoIT
# DATA Resz0BEsZsipq/NA3Z0/weNBjg/cV6x/NZjU1aod4BNCCRWusOk++MrYuZXyiELanfgggDA3OB8POM1IzGEQHAkNScIvz9sJgUkw
# DATA glO/y33ItTk98QojZf4MzjtgZSs8cuNa7NDkCJ2cFQ5UskrSUPaKPgl8pV1jg56RgwCgkpXYXiuuMrvwZQSAdZ4J+ooCaNCpi4Wl
# DATA z23N9hSzte2kvnuBOma4rpIZLpjBMtdFu1IYfmn5rQfRRzr7arEhwcRPhBhAsCO4ihkBOC42kPgzeJYR8nRgF0k285PtHyZVzuA/
# DATA cN6AJ3QOT1kA9hd7AsUNk3CCEBGiXgd0n3RGRVuSzR9NF2Ro+i5+2S0xT6wF1uFFWYjBORK4FhBQfe642TjpkKU6iNYMgzyoU5al
# DATA Hx8YSz/9nJ81zTLvP9Hci6DmCqnDQdUxbuk4Ua5D+mwbeqH/uJ2BJ3QdNyUMcXksSkebS8wrEZsj/6DYx1RqY3qjWzhFnvZF93rS
# DATA 6ikJvJ2A2sPKG8dO+9QIuC5CMnP4V9zIbdfwmOQ+p8fguZDJhWr4lxIgIHn7eZzYLEGbHp0Hw/wvuHNZ4y6AZSx0u7ZYc0AJdRbY
# DATA Wi0mSq7nT9DLljDUyNN4CsucPmu0q/T9BCoInfEswSQmvQc5uG2XO9/NzDuSHWfbPUfwlVrO4Z0OQMnoYM+4EHCJ8zV4s+kk1omY
# DATA jZmWzdERwWd735KBIwKYr/gO7qVJjPOJA4BgwmdQfdaEQK4msScJ5CpxsAswq3OF3rtIY/SPAzPWM/Dh0IbeENKei5/Cm8GP2iOZ
# DATA m3pDAfhcjYkxLYJICrc8lZklwUopI3fvGfAkkdXnD9oMoul0CB3OSiRm0weg8hGCzNBnoQRZoAPfZoeDINM5WGeASKRuVK5k4vLR
# DATA YNCR4U7dnrKstuvxXpFwFRLifKGj/6uGjRbTDIWNsnK7hfTQzcBS3H/Yg5SNvdYgP+6PQuO3jfmcPuh3xydy3Bh3qtHpAFRM6X6n
# DATA 10ZzGXW6bucbBEM/rVM9cYfGQttLha4TvzWfgkT4Urq4xPW0rbvsRzvgYjmkybpHorZGjv6YuGwjGgbvXRP9IHUa3jyMxuzkssWl
# DATA NZro19WU+x2J4QrSr7J1ZAkmKf2SY7A5piygEgQlvpTDrJu18oxzVtcXZjpeeuCyryeXlwJNo75b9xThDjsH2iFU7eH+g4zySCrC
# DATA JsU9d8F3A52eeeZ7ExO5hj919Bq3WS7ulcSbUYSZji3jD53oMlf3BZ9dTEpLlXJyISldTqp88VPPy8FEoy2lZAdXzozh9MM2gyGk
# DATA 7OlSMYPRjiniJxN4Gi24rkoOtvOodYSIpFxHbWiBO9dTT7gVDGXwaKJkVurzegikzJUFXTXUMHsdFwoRU9MSWp+5rouqrrKqolp6
# DATA EDwuv4Ev3qi3TtpXL3/QGp5cvawe4jlx5IEymdkR5FENkm/0RRULazV46a//eEBAxCVTuZsN1zy3U/+V0qPjg2Gt0zd5pBbJq0v/
# DATA CmmNj40mA6gbb04tTummzUARpaLhE2zMR8JA4uJi6G6HLmwLns/MmfE40z5o+Ed1MOw/OvV+VulSP7Qd1Cz3ttDVzXi4kdPbJKBG
# DATA gyY2t1cNOFhgNOp8jhhxBxzLs93BlMG6o64baPh2EVun+XcE4yOoELAUG0mJ1eWiNxcy0lIUvMJ/XbOYXSzSh1jHKtHeRkt6TcE5
# DATA pSQap5dO3yb2prGv1DRiyNABf9AdlDK78CTyNmnl4KDnn4C5D2lAkpKJnebffDxZQAd5o1R2kk43LTja8KR167UzdTRNPu/i73T7
# DATA clQb9A8tcVsdYCQRI/ZajQQoI+cJ5Z7uAK+VCLonep6NIlf3JPLOnsI4ZAMfCcP3GRzD+PU/qhp65VnyM1ZZW5SqCLzCHVRh2ItU
# DATA LrRD2RTm+wH6Yxdx3a5LG8Csq1MwMbEPdalUCyaGmw86vR7Yo6MkxazdTKvD2PmAn+PkKhgkx3ntxvAbpGd784xWv5kvLtZeYz8W
# DATA XhUsjIeHzwTs2H5TCK1cKo7ttd1D5GlZjkAehrquEGZ4ULHT687sEz03oQ80dvuIn4RaPGy5HnFYn4tgClstR6jo/JQ0fctQ//wo
# DATA qzkp55B82YhfOxkTLY1mGzzBu5GMeJwV0He1NR609CEVvh33y2VpyZYi1Fhr5I5QEz1O7sSBx72OxHpb9t1DI/WZspGQpkQoQyLE
# DATA PeqIJzDzltQnzDOmgro7K+tEGuosZwmrzl2fhELpHPEVc5FrrAPOxJ6LLr2+YO+7uI3tNegPjzBRiaGvGt3CXFCX6aSu6+5ELury
# DATA shy6vftb5Fzbg0I+Kwat7FgRUK/CbvJyKQfm50xMKRxGJZBCQmEqddBRKCMOg6A8RZfKx0ruIyWEKyCWwkFVAskmFNbc9lzvBIzZ
# DATA /xxbRFmqKOqVZsijC+1pMEujwv8GOF1Sg+/zKs9f57GEQVLDVketyD1q9l1qFbGU2fXVxZOxfbQlmz1kbftv5Ghcj7u6PsbvaArU
# DATA hxV2TkLjkrwlSvHcDQTC2DYAay8j38aiEZj0dFWMoSamkppqjYkZRxa/cdMILJb5VuuCganaVUoXTUkldB47eNfng/ctxJRvSdhk
# DATA XGsaRS1gD3iCLfgWUAlSz4HjXOgL1LkAyyPqZ6HxgrrdkufeE3g5zITVB/ecIIb1xa8hkk2SyRuMWXpjoTAZgw8TWxGagudYUj8X
# DATA JqltSsfkLt+mnyaiMAJMA4F6S6QcJbUjc8E4V+fV/mmStYbdDspYzItzOqOzVtuqro9ojwN1h2+NGMGxoyrvnGTqqxOQjvPjVrv/
# DATA 0MWbrYUwC67f6OJ/pNfo4gyfUd3n/yldRuegOT0Adho1i+D5jC7GPEZdWFIbmoRdSN3dUJMAYbeuegR214U3iLlp1QPoBnOtsDcS
# DATA +yT3e+oO1vUzPMRIw9EWyIduf0x9xT2i5Q/rT4gBI4o3HNQepBI5rVi5DiQuRTNliEfhgNx/136CVlD1V06utt/Qs/NRhR7fSyO9
# DATA MEOPGLpdgSGSGMryXZwC8CAHousUGzyFMyREErKL2o9NYVNBrNa/JHAEH+9wCAoDLAYQczUDNBTXDSmK6kSk85WFiVMMnzIFCMKN
# DATA AHzqDsCX/epReAhHvIt6QiCHnlrCwxOxLuzmBhc2FUv05jcWLeM1VzI7rUgpbcFWUE0xWdn01U/8HMNo0p5RF3DnCUbTS+UPmZI7
# DATA xPMoFye+KSztOoJ/Ud44df59pp7+UeLnviIZzAPSxEcGKddJ+uF7DPfa2aOKlgQzNA22NEL1TNicWDac15NrFyAHDv5nimO4gY1C
# DATA l+9nL34pOWA/obGqB276WnTBAeNNBCVHcmfU3V5WEklHUU/ClBmcoQ4mAUqekEVlqX91aWlSOHAPtUP1SVSiiOLtTYkN6l1JyJui
# DATA ETjglyN+xNGcGhVJT1WcasKOeMEl1/oNVZPtNCFkOts15ZBdT7jCyTRXClsSbcq5ZADp6FyyMoEifroSdxtOqoyZPE8cuGJmDfSi
# DATA tCwBdcMULCNFPebIB/ZSHT/HfxEpONFiBd6URpZf0yxZ3c5Ams8T4DUJpPc6lVspoZG3hqBsxJyphOaOlVp1wezXkjVMIAbCgvos
# DATA R9B39ATrthnSegCAHdgISxTo0T2qxWHWQ3lrlne7vRficigjaH8jNy7/tuXLqoL4Xw5KhFD/8/vna1nqG/NPinv9WyHGnP5rDf9R
# DATA 1OakTXcSX9k7LF6tu+8sRgBKMbmH90YeiJAlttgwBajRIBgDd1ik0mp3crz9lixse0u3qRkKY9qLtAvEbKPZa3tB3LxgxXRFbAgs
# DATA T842IWiVv+cGei7Lg+ZJ1CgrV7hMcMT/c5ghHCFOPS90DhXj+UePfAdS2wuDUqfiz0xi+yJ5+dda64JdbcJeKvEPPgH6w/cJtNpV
# DATA Fs5vPqlxFaDhMwhOUY0gl3TUgboD3IN0MS3w5bey3ic4cwSr9KwwyVehxFStmmOuAAEVHuxpMzc/YLl0znmhw6BJZ6YPbVXxG4at
# DATA VZLJWEwG1hT6mcaR+zoqS3psAVFT4ErZV/RNT1buTDFC8zpgs08TSwU4e4ojqhTC1YhD8s6Xy5nHWwCXIVtRv7bRceM6JVEEhYO1
# DATA q4aUE6au64F8bkMbw6XzQ9zPv7ICZzgBhKcNRd2k02NqofnO2g8j2+B/xBt+SqpmyG1LTaprpF2Poxk4Q6igkxbDAthikMW1AzmQ
# DATA KZP8k4mH1oWteDABnpsyY946rgD1RDvdmcsguSXT37vpelsJYW7Fzv27rrYM1bGHUv9o2LKQAnb3JlOyX9fdMx5u9p3N/pDCbgbq
# DATA DwPAhO7vm3e3ECJ6Rf0vdf1csQI+CVUXernaZyfaWSp+JLIjq+MiVXHBDQhhJE21J2IUoMQWN7/W+cmg7Oc6BS1/E0ZHKfY38ZDY
# DATA w3ipuSANC8HTmRml3qWDxGHtwxiDuop5w/C1GLwP4edZ6WC+mSzPnri6y/zKcZAv9Mdw/TAmxcBsU+HYSjF2SvBeAbnB40BcLk1x
# DATA AC2/LPCWx4sjIIZh72JfTEM1DNyVXhapMoqD9i3hVP5H+f++LOyoztTiCrhhzm3Sx34OHgbaTPjb57+rJIyxFlV7OvBO3wJ0IPsu
# DATA 40Z3nbaK8PfMlauvPSsL9lcJa58Tr89yAdeu61WnvHlsfWndVdX3mt8V9gkhAF32OB3rzy27UEAqIsYTJp/pSv0lNuNMQNNzbP/4
# DATA 4U8w31Mp3fitTJFVHUXEsD9SghD5LapNVpcqdtUPClhWf5DJ1ZLM8ILBL/iDSXHdu5YwgjwSLuMgrPCnxQJLOaa/CfGsI5slCo45
# DATA M3J5F23fNSs8ppEC6wMnmQboEcyYCkruRRu0EZsitYM6Sy8EXtXIBn+IO3pETDbe6b1zDFDsd7BwMiByy+B1rhgvDd0fOZ1lxVkS
# DATA UhXHFFdovuUvzzn3ZxcuqEeV5MIFXcMkTKlecbajg6Clvi6pvg666Od/rI4QEjngrybQmyuq5kZKlbJgG+7DzirJE7F+5vlDSjhO
# DATA 6Ht5jbDLjrNHpUsr5QWdFAHlrhhen/eFIvHNu9s7b22tbTc3V7e337u7dQs1/9SQFz1hFb63vbaFQRTWaalf3rrhvvJr8cAFD61z
# DATA tr64KD/qZ9KNyV8b7t3er1+5fGllsbj2N7fubuw01zZuNW/dvbO6DuH76fFoNMhV3UBqZkXSzdWNtdummH7jV7l970Zz896N2+s3
# DATA TWFHwhoPu3nJWVWz8rC1dq/V4Zb19nvrt1TPVm/cXlO9W3tz9d5tWBolfoyzcCB31na21m+auW61TzroZCIvYMWiK7tyuRzU9t7a
# DATA jbfv3n2HCaL59trqLaw2ShesqVcbFSIXmZi1CO1uUSK4UHoetEajbNjDALwfwcQPsxrCU2ew88sYNdeoXfhu6gp0kjeSP69gL8Aa
# DATA WbvjsVHuHnwy3jflObFfs54EDEYqO+y2jvIGVjklsS3Wf7GBAKuqhpBdXcRXNnOAT5gZIAIE8AKaYIz43M/EM49+yG2ZX7kBkJgY
# DATA SeBf/VxJ8PvV9P7wfg9wX189l78fApZqhcd1cO/hNFGsFDUnLGeXsiHZAagd/iAbI4t0jk1n0DoFi7YaHJghavA3WLXy7Orl2v7V
# DATA y2xlk2kRPCiKNHI8qCNZ4bhuPGnfL7vwOfxu930WGNhDq3UzG442sxPYOT9+ONoc7yu+/Q5D1aueWK/hp3oDv3wkXXKHfRfWnbxg
# DATA HaNDybyoJDunA/ozWBV7Yj8FlR87QCJ4seRefIyZBUglaJDlHgOUDEDG/hQ9jX/2/Bkqq0lvixBOz+IJT5kyD1/Vgk3jjOhtcr9n
# DATA OtRIzxjRVdH0q0zDD1udEUGZIAMtSexa5yTrj0eNlSUTa2yFEGAQvGIHdxCWhGIL1eq1W10lSaZRxJHw5GPFEtR1C58I+IO7c6xi
# DATA 0CQpodjZR61r5xCO6GxKJi+MuVcl80Wwth0cq5ZqA7X+WvtlagmQJoDolpLvO2U8G/73G8nypeWl11aiG/QT9DYA94LHcCl0M+BE
# DATA V/px8vbOzuZ21eDr6Eg4yu3dcHpjrMOs5Mpah8wyJTtvFf53Y+2t9Y3k5trWzvqb6zdXd9bwae3CG/ivOkuDd6mVdFtVt+0wL2gm
# DATA GPDvw+EEg+G7rKVGF0Xvo4HcD7z04XnerW2u3WnCsJujvjpWt/DvEnRCHb3lck2yiJuJwoMDvqTs302Gv2jyy9JBC81rcEOwprPs
# DATA 1FBjXB48TJIPqL5317bW3/xh8wdXlr6njmc1Zau3mzffVhKD86U6xzsn4xMrRy98u3N7m/3s4c8Hy80VdiFvtRXNARHDxqud9NUU
# DATA g1NcCc5Q3otkizoGG0tQ6Pu6CgtkJYBc64yOkxzUbiOZFNXbHtje1Q2hlC6vvFZbUv9vOdUnmWEEajylFYhXf1SqLVd0c1W/K5BB
# DATA t5UrXvowki8cOiAT9HDYGjSpNyVVmvR12bApfKKhhSuoTzGu8bBI0Fck6VMMFQdmNciyIRLLvrqlD9Va9ocnfBBpqgEGJuRXL7xW
# DATA GfR7Al/8EBznHBgsMDxCmMgvJG+JjWipFrxKGx5x7X+algtuLdT1PAN22i0dpm+t7SgWBvtocbm2DALB22pq6smZzNAEnt3US6lu
# DATA 1l3wIwDJQf0fJHbD47hcLpq9laUlYGMdVApR84p9PihdWV4RBV55d3kP6Ozy0lLxDFns3j45727zsWkfoevgSeSfoXIFMkQM5JV3
# DATA s2xQqvHth5bBZSt2hmNegw8RfPpPiQWL+SVly3zx8XXRtlFMz8eSgBnXtBJly5hR/d8p2wwYUVH4q5IOUsz8+IsT5JXMHSTvgNOB
# DATA OrZsW/7MiyDKMOptmuLZK3XoeGy8vB+mlJkAcIKSJdy9S+pShcemfFGeAOu5fr9nFd2t1/cKyzni7mGaprQzk7OzBauKca/zqL74
# DATA oDVcVPtuUWu3F4fj3iJORA02N1SZoC62CXft/kG/e33hjAY3kUu62vU4FYagr5P5JO827SM+0tqo653q0S+bINgXfD0Ydh6o1+63
# DATA 0tc8QTZdW+F/L1EREJVWkn7v+oI1BLxd5Un/8PA6G0fUMbk4zoeLiikNM5qUxePRSZfet8ajPrrTmU8y2A5NRKC8vHQ5WVT/qVkf
# DATA tNvq8tZqq6X4QfUmncxVkESrd+lCqmgy73UOlVTdfdg6zYOvtgBJZZgNq5t9Nf2nIFl3Dkbs4ld9eJz1qgfDfp7zE6eabp8UIcmP
# DATA /j5ZfAQTAG40i0IUePR1OxDFp46I5n6/fUrS0dJ1/f5oODhokrhCh0pyaWkp994D25v2HrgD/qWu+tNIELuIJEgVTCbuMNQo7t+v
# DATA ld545WHW7VYR8GGxrEajTrbeKThAXw8+gcHCqUruCsl3x8MO/mcxaaiFwvLq/6v9otgBqR3WN9+92txY23nv7tY7sJV1F5udwYOr
# DATA zQy0G3lqF755d+PN9bdAtYNtp21FnWj2TfeHnTbhYmS91n43gyouqxcY1eY8hfyHcMBV7Cqa/QHiz5/ZxrdeNgKldI3qrh2praJW
# DATA HP0wpaK01xqlE65Kh96euRYtKFvl0ahPluEDF3Mex8ucUSy/boJy6n+7IhZzm1nOYdvloVimVhvyTN66ma/9dORcKEByoBNnffPB
# DATA 1TqlNyBHI7nNPaM8ZZg8jmGUGQFU+zuQ6cczwqoeRMgETMDcEctrHfxpyQdJXu6G3+55IeP9gdhr5Xu6vdkUEUn/VIqVBsJjEqT7
# DATA Hv9AU5BT3iZPHWNsYGXs/0359qr5Fmg5UvQR6IJaXRqB+w4zsOG7WJPe+GYbbG3ypsEvp7GKeb4DG/fMbVahbUZ1w19fo3Y9hYoR
# DATA 5z8ZZxANQPbPsSwd/hmdGfHXw6R1ziwJSjwXuJikTdCShURIePGzi0WdjXiPPUM4XprxKu+fZ+L4H3hTaQuqLW0XxJQ81U7y50mC
# DATA qhOMFAHUwq75NrwAZmMpOK0yKSBl+R4EaBRCFltktqbJt+tIMFPLU0ioSPcZkKQpgvdjMW1bgjTEEhc4frGnylNJqfnVi59zCDgG
# DATA ic8yYrdGoxbYdH20Lc3XywX56+TDqJHOqpUskihYW5ZIKeCwR/2VhYxkalJVTYpbSflESqmtyZR0s6bnhdlmZ59I6KUXS/Vl3Gjd
# DATA qYuSSH6aH4xCqDN+HBwhEeMplSy0lJoGMJcgxomEqQQFVZZLB4Zs0CV7LvWKPu4j+76Prqb3a7WL99WtPzenTCVBSwVa+EdDQaEE
# DATA LrmUxu65oXGEuyPWkfK07UU7iFeCMcj16EP/DszU4Kf+0t4gEpNrY44HW0n3V4QBi6xDg441m7AFwOE44Nzx63+wZUMh5GyCQb/S
# DATA D/sei8vOb2KuAx11IxmBq5FzCMpztYhL4VdyzBZ9ffSwOb2CcE9KeYhIHyHZ68q/nyxFcnf5fTAfBr1TFcRn9hx7/Y+mP4VesHKc
# DATA xmQjmp5dM7FgLQeV33JF1zzlM3tGrS/9oYY1CEGSK4hepylkaRhpdM7kXHAuAfKJuQME7cdkagyik2HVkyUlS9kDVU8mC45bQkSo
# DATA Z1cGaWdWttfATql3LLjzRISphQjdxhuLUhRJUpBuTZHVYwwwRAPVU9ShfUk0RJkLJdPyUzZhhSwrlnpZn9MwndKxhaIzJ7Z64aAr
# DATA 3m0wuEWXLQfy6Rct8neCOVNHiDNd8e9KBUIIS3vIdC3301B8rJFF3Tkt9KinrTGvrdNx0wGhM7oY170EeeQL5olMjstLeGUHaOVu
# DATA 5+h4JFeDCh9XTVBvNTgcBdzwFtXzRVX5Iny3CD0A16h2KzvpU4oCKZyNDhbp6rJIbzm0macCOtAfjwbjUak1PBqD044dihFYNdgF
# DATA kBxi+UdtOO6ZrwFiYKBGmTWpXtT+k5+A/MlGjuUr5WLltVX9DpVfezSAnH0zZDOzq0D7/LErMdNGgyuS7i4YtFyQCh4TrhRo8r/F
# DATA 9gSamtvMR201zhooCgel8oJeIKKBEt6zD1sQowBSVJA6ySKVZDHRpdXfqrgv+7qoO1PGGPdxp7ZwaKYhdf+ssWNHOEYdHEzWU3eU
# DATA LE+GA00d8VFERY4Ql3aBR6StLkG/8LFTjmqUIhIhJmD5Odkqnj+9LiMjqc/JYGOusg9bwzbph7jH0rp5JxteLSg6j1meG7zfdtPO
# DATA AL6p/hj/i3oJLI7euMf9h/ZwJOpf17eLf+FE0F/A+eglAhWPxXmgnQFQO3Au6yFmH1DVjwEKJGdYVP3LieSiSgvVc/bkFRELD4Kq
# DATA shQCXsetOAG9tA16t4vD2POJuDi/U63+11VAJF++AqDyur6Xv9j9McGz+Wdoq/oHSvIcHZhoCuYk5aIOFVBq2Ak17VO6Ya25WFko
# DATA aXspHbbUzHyPSMOiaVK40RUtHEPrAPh0U31LA1hJi2d0a7WKmYw+fPFLxN36ma/g6GWk7cPbYi3kJbqxxoqdgPkWHmdWn+fbtAh1
# DATA p4ZVSdhbAKdBbUM6HlMrwB72YxVM1y2QX9Ozs9o2Wp1q7E4wmUA8fmnlWgUE1KVy4Bzox6zYjXBwQNCe2vLDEdVbSS5dgou4zcQs
# DATA NH2h9x89eKN0v32xfL9m/6NqYw7DAw4RXqkuwJh2cyjg89qRIpoBSEtggea5KlrlKmZ0I92hv7y8TmtgisuSlWsXwaor4dwrtUuX
# DATA assXjXLekl1i5xK9dhmp/Yl1tLhJyknoIY3g4OoIdmBO2m7UkheTL3dffxTsyOvJxuoO09wfMOPyY9ycVq5lEclQ6JpCnpHOHiph
# DATA 56E6VqqCsE48unfIQ4jv2+LhyIcJ1xdoGz+TIVDGelsR8lQDCJ5r07HFPRrrPUVZrb+Fc04flmYDsUwNf3bzyF7dAJv2BFAgUasF
# DATA jjO5FfbNWmhsIGrziR3V0dY7vRy8WFJCXVVHtB1MpcMfXc1+Ad5wkfGIbc1zGI5ukeFohrloDW9/QBGuxWe2sUh/6duZwqLrUw1C
# DATA 58FA5h8vUY0sE1ZTQGP/XzYoTZFkCk0CjokH7ipfIoAh8KovuDgnkOeAuJeANrueONV7mXRRYSrAswQVKalEYSb9nA4wxVGP2Hhi
# DATA aZhmNKTwxVyJ5eNRH2aPztj+4WFaYGhGVggS3xfoKaKO0J7MgvoKnYuRG34Ecgg4GP/MRn38FGILY77CXiBvDN6LXWid3G6V5MJ0
# DATA +HvIsGzg/3HMcDjAAOvhzWs+lwB2bfBR8qL+6BGNRfy7l+gHKQni1Yma4KaNMxpxd9NqBO06XkneyU7JAQ48HNH3xwlMNpPYS2Oe
# DATA 6mGTJTBhZFSla4HJqMXwEwaSM3frXyoi+wTNDHomryfFWIPxHUXYSk5KbCUO5eQH+630MbUhJ3ujEjcHQnuyqvZPfTogBRmYPbvk
# DATA i1/V1CYlN+FTVIaoLgZUFPdJIZZyqNjbcSkG9aNN6RrrQDu+ptr/tpFeWlpaIrP7o9OGjn1Gf31yG8TSfrBZAVKC9xhdElULy9gC
# DATA 7gXF+psYg9TgvYctmae0EyjzKfgNIopbmmfdQwDo7ab2O6r+8uVL8rTT2++Pe21+cQ3e2InM7DoNv7TrtmMM4uEwQIhPeInZ196w
# DATA UdcHHSNj0vLCrChYt18NN9JBK46tFQk69jvixb7tHIBWI87xBjL7U8S05+TC30h3Tdd0COEuOoHG0LM5ZMlf0shihlDFALNNTRDO
# DATA 9qUossy/sRP1r5LVzfWKsz6Qv56hZh4nPxi2Tk00zZeMro1mil9QLI2FF9M59Gk5kgjLx8wRdFIEQQYsciWUNVdv3VnfcCOj5jt1
# DATA DcJp5AA28FEB+HyQM7sIkao4tKzbPzqiO8OZ5TsI9wcCGQKZYyDoMGfqjH9UBTdNKHRpCQOk4BEWVY+upOwDCff2viQDw+Ry8Hrc
# DATA 64L0lo/6g0GGOUO5eUjOQX8FMYqFLoSCQMiYDW0bbGcSVDPudk467NDY63N/z9K8fwg9W166fO3Ka1dVh47V1dA8mEwm82EoqfNf
# DATA nBFo6MylG8yrs94DQmdDTCqzpIsJeNs/SMt7Uf0LLFfe2D00oRZ1CdSqI6ePf8YJWxu7jE9RpbAJcn0FZ1cDW0G4d3l9Ua3yohrF
# DATA Ij8oqLmdAcZA3uz3GjasQnufPUV7bQwfx8RrnKflWPHi0fFpOnEQFwguY/ZHk2g36DXmTVX9GCkKA3yi9OadW9Xtt9du30Yl1XjY
# DATA TaqH+TZ6X9cXF8EvtwuHJkzd8iLVgaiUqLNTc4K+qEt4IWcLDxJ1TmARoyFlgL1KB8tw1Bxkw06/TXsht6EjQp4S4DZAFOJAvWtT
# DATA dH+qGYilI263Ri0IkoyTlg6Rri9fq72WvjSRkeX1+AT9rxvpleWVk32qTYLg1Rzv/C0M897OTVhHQ1/SQ+NVbeGjTGlungUcHDU7
# DATA OSjFTpPqveS73z1zIs0nSbXtPLx1YxIs5qVZa7myNLHlM0WTBXNNO4Y3Tv17teXapWqrO+j0gEXOu9+KJoS1nNb3qKtlparaLvAX
# DATA /SKQD1BZUnAqPVU8+CQ7UWtdHaCnPr3L1FYaaeUsOL9Tv+C31zX+B/3f/eKKypHRv/baa/QKuBL8tVQ4oOLlNaA51YMuQrhU8zn6
# DATA M4BD4uutroWtZbEuVUpNqcOakJkJYUeZFv7raLJC8dnziLPfk9hXDA5Q/CUG9EiYq/8icOqIfNoQUQAcDoLXAJZzbamSKEl7UohV
# DATA xEKYI32R0Ymcyj5nsUdHMsdkL3yoI6goWNmRm56RqJtGkWzyXRu7J3CC3Yvv4XCNQuolaaNxduECfbsr8gfSXqE7bjTPaOTomsKh
# DATA 7e+FW4NEd0jouM772L6LiQrBCoPUsBzdtvGD/eUO6Om7n9K9qn0fwluwrHaYgXHoVT62zXig74viqs/n96vl2uhYXSCGjdfFByF7
# DATA 1FHX+Vr//TeW6svlcu0AbU2lsldCvSriXw6XuTKLyyyvRASCFVcg4BNCUjACKrKXNUYYjsUgDbfWQtnEc/R4RM5tdM+vF+wVeluw
# DATA K+htfaW2vFz7njnS3NP/rbu31m7cewsGdjLujjpgrxodDBpLIA0w5aXXlurXQDMAV/g6XePlz8VxezBNHIhLr8EeuQldJexTUNTU
# DATA 0TUI+7+oX9WHeCbi0ypMan0R/muesa/TIv1ra/msxgWi+syqCLGsvWp8fGsdeHRGARAGzzOxMbHlT1hrahAQ0ekvyzkQADjxzq2X
# DATA MLLqpOva3bPMrAg8ae3iSDocpxBuybnvMrbDfyOFU+vlZU+WgRuO/KvVO+ZGzmOsTCEOJTwIWUQj/NJKEnyjLp2581H/aDEfD2B1
# DATA ECMu1uWQc4OedxHmQaSvWDeY7RV8fdAfZhp8MPY5Jl53Su3FRRvUKMEaxujIcz+JqKDwLKD4Yut9Oby9CN3uCe5cMDKE0CheklE3
# DATA h71adMBb4dJFnAvf1pdrK9cM34oR58L5uAwFI5NDomEzFI2Lbh7tRXZXwULIcKZztpecmvPWOnsHnLPChw8fSoWxsGToo8c+LZZl
# DATA L+DL8sfJNwGzbPRls4GWA6TlkDwiSblAVPOwmOGXX7WPtYzQuRGgZZpEFpUY6aZub1e/YtQ16IIaKaBAa8XGEYbPfHRKc/HoNOwu
# DATA ATjXE1Hspv2Hvaxt9RStgbJY5Tl1ZWwXs4XTe8NuHmLUTkVQO9fty846cea0vEmpg8lO4b6hsQcy9LRN5FSwA/H998adNtPhWP1Z
# DATA g/9cLpXLXkBBNBuWcNapl51YrjtnvDb0UsNV95NqXkCSGqQcdpT3ZSqyTsp7r5Sj0i/HABFtJG8NnWhjygLQQsm4AvPnePMHgToH
# DATA BJgSYc4Dvf7NeztNB1YQfmyt3VqnvxBLz0bDg78F5A6yoptIvTMXcVCVu7W+tXZzR34FiIGVGOQfPDTQo+qXgxTqAt1KfDvei5qK
# DATA HcOVoumBoboI57kkM6lPzTAfZFGbPwP510I4/5pZxr/JTOLxgNxosIxO8VeAcizJj/zY3amwx3Oj2w6zn4whBsAH46x4EJgT7S7i
# DATA pFAK2PiZTYCTheKoQwG0jYbwdWZtT4JfFlhdPYNmP8m4qCS1qtZNFyV0vuy0MNpRJ8kxbni/4eR97NX3BTrlfBiNIXKSTVNeHXTh
# DATA 1xmiB0p0cZZZctu1DkdwtLW63f5D35zNne132yBYPvRWl2ooO3flElZXtmExYXZUDV4e0dm80CquPqdIt1cAzuHhzLl8/n9p/wo1
# DATA T4wWPscsWhOHd0TF3SmnH8FnHqhzTLH6rF3aLZ3QdgDnFAjb4Z/b/fHwwH5wKwOnOtyX1tOt91JOwIIezJwL4A42p3YCugbJzDep
# DATA F7gATd0j+sMsAf+2Zh/23rAPOVVL6X6n1+a7F1pQ+3mN5537s3ZnY/Xmve2d5tbdu7gX0RymhWfVW2NqRfmdKochpai1Nhm45JUk
# DATA k7eyhGJ/mGGZkbG1md5ijJmM0w71kmeggew/yEr8AVX/neQu+DBDhrPR8TDLTC7k6qDb6vUguzHK0NziSes02c8A6Sdr15I1TJsm
# DATA sORcIZbEQKjWfqeLkaiMU0yIo+g7QHcttfdRnw2iEoI4jPq84zq5pFA2KZFojb5u9odoniSZamkMQSnCDTs1KQz636mhw0qgdGum
# DATA PtyXuqS1mlIBgGejHyvQnnl6ac/2WY3ApMfCoqWp3ZU9oR8UNJR4sbPWJMHl7tb62vac9eW4TcWfgKpe9m5yw6zb4rSnVNzsgJq8
# DATA a476tKEkk42dXwnOL//DTt6c61s82hxvMI0FzL2CtQXHEXmA0OU5OpivUKiQG1hjJ8nDmyluiOpuq3qImfIurUCUjVsbBLpxXc7j
# DATA ZTyG4yuwKwu1F65FuIvxl6Zbi4qI0Qd8IMbeMcnSx+RYgp6vxSG2rsZ5g7bvHdbHg3B/QxEr5FOE3zdbg9V2m/+6NexjpNfmsPNA
# DATA 3YzB3WLPOdG889MkBECnrLAubzMpPmMfNCI31ZMzxNtsDcrqOjPIhkh8MHXgx9d5pGpeVTcDTu/SwlxcJU+UBezDgNHorBTqrHGB
# DATA KGARoDd04HC/4B9z2OAv66iJpHCQETOflIoauvrkAyW6GZ3nZH5OYDeBU1ncRvXcbaj6OenurLlTFGpx8uKCUUeuUD4xFdS1LAfi
# DATA W3yXGbyzAk1XHbVhcMNipVca0cYCCLyltY0WDPWumOvW+m0hl6mzlqCRkbnEMlYZXVT9nM5dHPek3zsJ/6xq/Hpqrd7BcQR3Osz/
# DATA F4Ue9rIAvviIccHJZQ1tva6vIRsWSue8UJbnzxNpZ70qTjY+c7wQ9+mkwtLZ3sgrLwAdeiYPYQa+UrcTm7VqydQbty3UcjT0QbdF
# DATA F8DITdPKpiUKdvtT6+ZQahvRuhx4zGNWGrsEMgkIULYeArFQLmoMpMO/bL2LVbQ2pGBnyCQJV6xFXLf57HnUdVOV1QK3zhUe6l4U
# DATA SziWboOv3Kqof0xyJY3EyeLi3EWCYHI9r/RxeYYWQeRqOKcfjUp0krvio15p12udJWsEacJVwQcc1IxtU5wc98MFH9GSG7fPlM/X
# DATA LueKaRfAYGmKviOy4uhY/K4elw1L9t4yxChblcq5u5cx3/iVZxjQYN1uah36xHkmt8hpiRiK6tuOTEUpNheveB/STRb9YmgGLIjn
# DATA GKk7dWLoJjtl0bVPsH2cNtS9l4JD4mB2hSqQgkiEP7LQF+FKmpvRacq0tBBccYRG6wVwaAGxmn0SIdtyMS6KpSSL7EZMG4WCs9S1
# DATA F9/jU+cNnI9efKiOrScCp23lH0WsTX+i6EjQST4hB/CvYD5Jllb/R9Pnda1s4HobiW0bKqXxWwbUYWv/a8fZI3bZVlSEqsBpGTtn
# DATA mLSgI/wc/iyjaWzQcXJ2GtZa0WJ5nMGGCkLMRE2X990Im5ty4AExCS9u2HzOXfzo4VNQGhwh5QRyrNnSyxl8W7M3xhiByQjy3gcH
# DATA so0K5ZzLYqI5I7ZST0TXJDyZ1oU5IvgREQ3VecQWawdS2JWV2zMV64pk/UwdVtUTx/4CdSmhVO3tHFDT2tk20OFOa7jeO+zDCYdp
# DATA 7/m3haPTRINOpq6h2agFPi8lCKepJJAXQt1/bVid/qgFyjXVkdZIdYNLqN41DWix1NLcPx3hjC3B0kGVNfA1dmEp+WHyerK8tHL5
# DATA woUVpAtsRj26mlyQ5zEWAGNkHRf3JJHGMeIua+eoHstbh1mCoQDWEcFf1Ap7DmkWoCMGzwYAvwFb+lHhBOGAwvmUgr7Ahl4nijOY
# DATA inVJr9Gj3rjb7x19Ow1L5UWN54PWMM8K2+aUNliIE2ir04WSF6n7OyqPUcdpluukczQUmYyuUWj+PhhZN6kmtwQ+JlnrpKK3AqxO
# DATA E5ezsaIJ5FKFMtPxi+Ul9T/u46uvvnoDJiYhgHPSvXb7R50DRWVILHT7TR4OOxhK3+mN+kg4GJgHoYIPoNOqG1lNVbbgSJt48bKP
# DATA WtkkB8grG8nSgs5qIXuwr3Z5Cf7q7/+4IcMj55XhBymOtKP2aMPfxBgCytPiqS8zdPAFHYz/mngc9OViI1n2kigM8fpCGkGsooZ3
# DATA cNJ5hTkgoZbX7YmG7Rp+rW6prX11jx2PMrqqprVailn8oNoiA8a9Hm7UXrirEShK5x7EbqRRNDvuRSenS7IIJvoxp3DXE6YeMXGX
# DATA p/RKE3EvxnCgnrA3XD/l/iHUR/vR6xYVJ1WimaIeWGwu4Gp6IyUYoOV2w7n1yWn7436nB/NZukDK09g02hc3T3sbvShNZcmU6k1x
# DATA AEVq7ehtzJ0yXrwo3Kg1hdNgMO/1tBBvJDXJRuZyIu5lBPLBnoST96FPuEOX+q8tLUEkLMioOce6Io5Es/8+pYyZT6tHfELtSWtQ
# DATA RctXo+a+Tj/guD0ejzpdQLZ9vznOW0eZrGbtEOxH33co9GJy9XLR8WuhEKjdcXjYOYCcDglUjExWiVknBG/obWib70fvn3Iq83GA
# DATA +5V6FY6GvmGE2HMQpGTIUl+eqP1vQM/kf99J1h4ddMc5FoYUSLCBBsPsAcx00h6T14Hs/ZzC2EESlQOEXHFiaZWgyxVnZfEsSB/t
# DATA p8jcCbilPpUYD44VAZRw/a09gZG8f5Us9ZeXl8mUstS/uhQBrCXDHYn2RaRnkkjp0vH9tt+F9C2Wtail7ogdsNDwZ5Xk6pUrl64W
# DATA ZxUCfoO1zEqpFFnJh2rGRsNxD1ajXZApiWa0BkuTlbCheDkzLdUGGpkKynJ9h4o+jkuR13ntMD/tHZSknJrEXr/kekrhCabdFAan
# DATA ManH0h8L2Ti8V/1NLpcWQtcgtfTO6BQBl1DeKHB9qmEMBrtmRjExN5EeoXIwnQOuY8N+u765hs+z4dB/ztJP5wRjjsEk3QKzEsJg
# DATA DkvLEGIkxd/vdLtW8ZoGydKQPvQcb4aSYBEwHlQRbSB0oD0CwM8p8qQLW1lx9CQWWMca/gNbX1EZkOB46KujuEv8MgY4ikO1yMSD
# DATA zMQUXNbrdqd11OurrX6QEwCVFFZN0eZavnrp2uVyjXNnpuPRYfUaeOJDV3IlPmbqFuiowrxK/Ba1b66Ug1SPJSuxowkeIF4J8QM3
# DATA ++MuSVaH6uJLojIwC5Tx7DEYfaP3xkGTx2lkAzmifWu5jZqcE9Ykvdnq4aVDHTrdU9xY1tlzXTs7WFtEMXWMumwLGAn2JbwtaUIH
# DATA rVM3U9xmkx7wThHXR/CvtUbJujdotGsTKxL3AejabNqwUFwHfaCa+NlWQFn2q2ANidXkvdYgP+7bmwK1pKr/417DBcYl3GQq1Cjg
# DATA UTYux8hTZUSze34nWU0YB0DI4qT1vrov0oEJAATga9Il0Q1T8XUyoqKfjJW4pOo6yDoDcJ/h+g76xxkqC2VstWRLzR2ETiXvZ9mA
# DATA ROXIyndbp+q/ig33xwiZTSMhYDRUMAM4sM1cDWiaDFR0d3t7FfLvZCFsXhxh2VymUw6Gm+4MMwuN0sZ+RZb6bb3NsGN+zxLbHZR1
# DATA 5TDVtklua9zroQwUGM/+TUNXahRLTI5XqH7+yrETPiNsVUsdi7DgrHv9qAjpggZhp2b1jKKsg7UKozJ0T9sK4WeQoxUfshht3Lpe
# DATA sXW5rL1/OScSqN6zfc/OwGxbWb05fjxNwZ+amYjcCfQtwHJGs1NjFO1UV85QUwwf7IouUlE5Tjk9dNXirkg+1VvJKH5h8lkhW+BW
# DATA Q/XtRb0JCmf1z4jj+/Ec02f0OMEkWk6+ME1tzipmMU1nnwUymqukhhoKkbm/w4idaW6uzL32QF3T8UYFF4pxJz9GPpi09nPgdt3s
# DATA qIWp+SQbu6nMkDMeaCRaLUI4Pxym6k+8pbHIkteSjQyyNuYP0ZcHuWUXE6jX/PvWlFNf2+VxoCRpWEa12OtCL9Z/CbHJHaP8s+ji
# DATA WjYdTtsJeE5for2MYckwuRpCB344A9E0rsGTXYTKKPClEn3kBaah4VG3v19KL6Rlj2JBlwcSFuC9dikvdOCIzfCxQVrpkrzRbh8u
# DATA 0mx52kROxYVG1MQ/6zTT4AzxJJzXZ7FNM0WlqLUaMGid/doaIavg6IZapGFE9a1tCrAUvYUD/v0UMx9RxJMXv3rxSzETRnNuA40h
# DATA UaCztMuQvQnAAXl38WCxZBam3s7Bs0j7FMR47BTujaZbh02jwX+WP1O5gpKl5ag8JLG7hH9JiConXajhieLYByU8D2SV6DfOniGZ
# DATA Du5SsHEYJdNCigTlSqc/zqFf1mPFyUCtchrsKMrSDP4KpmbbJ4Hex3XE9G5O1ztOB82ZCugXd1k9IsOkq7TDZNFeWco3HSldgAcv
# DATA osXVyxO8UECV0ze6dxIibKrwPYQ5JTw5SrCm2OsX5DUKlu9PmLEK2pzaPZ/Co7Cr9mRgNBUGiCLC0qJ6t/ho2EIQmsjjqiQEmNCd
# DATA UFaN5ocy0SHh7o977S7ges3tGmn36pXZpL8IKhGa0sIZ/SdvWp7KpHxF+NIkzj6TjIJPKKGGdUqBCwf6EsCEunLe88cINQvV/AKf
# DATA yTJI5g06//6MFT0BpzSTNJThbZ+4ANdOB+MEJjuUScniw2rXwF9NTonuliPxeOpU/ctcqUScufmtRuVWg0aYXkiXTfyXDyObCHWm
# DATA jX6OAjahFds5neBaifo4JaehRNKBBGaWYhpclZNB/yHc+/p5DgFKIFodtIZkluhlD63K6JJgOV0mm5CJOj9GkefhcV+1INdNMR22
# DATA eqcJ614g6qBmaXSolg7hKFrIniD6AmAuEq4tWKBUb4SJ4FyxXCDszzhKx2oQ86002L0ao7PqqNnEP9l3HnQXAOefkcmg7lsgMO4U
# DATA tVxq+lE3CO1V4Nfd5tatuxu3f5h8QL9EctcPNu6+eff27bvvuSQ5ijFfrTY1TXoZ6nwlivUl6bTsL0nfgTrfprrpq9tziQ8dRl6t
# DATA BzfJrxUexAbzQbd/ekIRgVgnh/JNucuetIbv48U/3ZKKk//nw9+hICIJTI1PP+w1EdfUBpMk7ALDIfGh5sZnpZcqdprVaaZck7JO
# DATA pGhnsZKmyBHGXQ2K/6Nbo3VG+gC+8Fqcy1ASggc+0yJqDf3v6BzGySU00kK0pbzWahM+BW0Qs4ks0zSlFTTrtoiFDEJ1yXnHoCax
# DATA NA9hq7EvGX0TgP3RrwoXX1HW839G1zNYbYIU/hm5oIWhoFD4vysKAPzRX8jtxjpd5Du7fT/LB4IAcJYI9qKrq0cXdtMEvw4Ykt0N
# DATA AUnY24vVqo4DNw3lM8h0/TnirpuAw+mNERvTE1rec9L66OdWODPO50WwhSR26BfcZ1ByJ3XUl6i24gFX9T56et0D3cWDCNZLbonx
# DATA RMI1tqJYrcMM4Ie4g9kvEZBrrZOtlgjSL56SqtQXmH3oQ1L4CJra47BdQF17qhh4nlS7rQDVg13d/6wKfgJSgmqcP8GxVBLjL4lQ
# DATA 1tA5BLSG4FCEXuMQoidITl9STljJBvusFjaYEi3CJQoO+ifmG8xtzpVS7pHHhqLJXxH2hOBblcOx/J8IHw5++39Stzc3/gC9YFWV
# DATA YYUE7BPWBp18SmTpxzIo4gzrGWZH6roD94f4oGm3QhXoa3vQjm469TAh9bFEnCcDjLFCWyPzethaY7WiVYOeEd/4e5FYLoOMVYlA
# DATA yWkEseqglecP+8N2bfQIgcUsrJuKwNJUCEmmwrNY4csc/AGAMG7cl8vcyOcnvCLq3SFujW6odsAksR4r6IGELpY32GhfdiOqgaNL
# DATA w3R9LVSkeNl2MtDEdXpHDTahlR03VGTMvm6FIONRz6BuB3a2S9jgb67fXtuGGQ6EXTNc63CJWEfQ6I5manfIZKzl2XCPFd0orJMS
# DATA B9C7p4STjv6y9+Ui3um1s0czzpwXv6oA1/l5YlzSNdtCNO0YI0/TPTtRFdMwkichFgj4n2MRUteMtnHHNRsO3KlNLQDL7ykTMBoU
# DATA vrauMGItNC/04nuWQ2wmozgcVFzQJ96VCacKGLrTE1pFU4Uj1hXBw6i9rub5McJdPnZkN0MUKMwU1Ft2F7kwXxcep3KWY80kjDlQ
# DATA 7aYNKxmJnOcUgL/ny2Gze1csE4UTCtPxry4VwZE290wwqJynhjtCz25vcDY7vFPgdYQc5Cib1ePf0/GMNP+PEeDTOgsyR9lcNDGd
# DATA LiyEVW9iggbmJQ6fQIImIrRCjXkSn9npvIONuBacnYsBaJE6mmt8qZVcrrv1SyvuyTJzD4cxWbT+0e3MC0wUMe4JQEI7nVWpRQDB
# DATA OM6x3PPQe3xZidJjdc611c2oCze5NUQLbHQRZVdbhvszabD8s+Ijzr7wIWqncGgJfvRU8r48fxbKjNLK98MaX18koxZjbFYvLLIY
# DATA DXSKAT6ubBnNNfP8WQW0UVp3R189e/4Zafbp1vQ0qpULOwuCEM/Hv88hjxI+LFO/XOKnCZ6UVBERPfS0P6ZGYCo/4ZJ/0nGoTp6I
# DATA UMz9vXXheMo3mCeqb59iMgwYOHboM75C4E3EzBJfCMWGr8R+0W5GtXdKTBDwgRc/r5nUq8gHQG2o5RQr/xLLMMIr4tILEqaRXkiV
# DATA g9iUvGvRYXuIzqJH+HdtlbMUb+IbrQlSO7bRbCoZvNksW1/CFb0piY1LaX+QDSXM6OC4D3qRBgMZAhgxysKgLOwzOPto2OrlkLgP
# DATA sfRAxqmyuI3f2H8T0h7k14VAAkmi2RqiWI0uI1UOWK/aEFMEBowISvD3EcEBE3NLMV1FflylrcTZODuHp9YDh2UBnl7wkMHIg+fc
# DATA eeraeHAkWdwAg7MzqlopQCHBB2jVrUcCZly1Ug2CscrymsAGWXXqPRZXLNvHYsiuPLommm5oqModsCer4DV3Pv5SxkFvnckYAZSf
# DATA XksDimPWXbLokYpRnCGiVFatSrzu9aICElBZWEBckKY2Y+6MNjl7snhxG+YgmtqKxmkr7uwJAhUWvqeFL37PhEVZZqb2BcDY8yk1
# DATA DdnBCYIgh0d5A5TqU8emKG1axyg81axGYUlrT1edaO2C8mbfsLWskc7oKVKh+qyK+CvqwxZa1RopEnWTMi5ObRLxWvtfvw4Aj6ye
# DATA EKqMIbuivFx71hBNmTlb4UwUugJMEXZ96ncMWhl8SunFpjVLnNJdksK2/OoxW890phBh1XMuvvMp7bb5eulKtEGXl5dmbn081Mwq
# DATA S8K5VNKpOutLb2ev7blmGhKrFL+V/NRl21Oey+I/UNrKrQu/aloOMHCLxOALnB7wI0Lq9GKJNcqHlyXU+kxCg9kqhQ8BNhBi5TD5
# DATA Z9lTCVmfaSOWD66LTa1DlwFVN0weK0BJfrhzLJUn45EwSzKILdFuWf4cZS/DIiWF50TbtgBLd5dSioAyOjd1aiFg2sMh9GI0lItO
# DATA +in4bAkQbnwRLSHOLCI4R5MzM74p+Ys5vUo+6uvuPIiR0a+rkgRrPkePLVGjHpJWUKOPCB8HmfG75q+3ZcqCTL6gIgM8h/mQuBDv
# DATA y4BOKVawevu2i9DlmBElCxZeSAl/w349MIBj6ATvZHqWiYPtAlNG/TVJFrn/0bwYTky/0wkNu2xGEQWppwxebYDgwhReMLppo2wT
# DATA hhrjIsw3m+DgEMsMNic3cBfRmTvek6eQhx0iL7gU7a5eP51OnPa9w0wvPWjCy4ziIWoGqWJqff7l4FzEziAaRfBbLJ01lbRB3/OD
# DATA MjNbr4tzTq1VRLw/oQPThxm78FhnSiQo45xMY+rVybp+czE7kkOKucM+zyK6d0UrOWKuGhs1+UWTj+Q8dgiGXBN/8CfmdJydSsbU
# DATA JMut2QU/IFovlecZVOxubtFoIaT31CEaOjzfweNdwe29Ai+a/MI5kacsatEcT++Ef+u3bTp0XXC6cR4+ELme+zxGPD+KNrDNEkjs
# DATA QjQPrm4+ysMn3Jz2aGV0RNJaVzxrkeEz5jMTc+N+yqQYpiEzHcHbbDnCwPje2YwRkA0o7bCMwGl92tAqyawReG645Irc6Q3GIwe9
# DATA Bv1+6sbkCZc/coGtO96G+DIuU1JcmmGuU7gvRmJYWZ2KyGyamsjJeYyl5qKgubbs1OZ4985Hrv6VY9Y2LVRqhfuWOuDkvcCiVjdw
# DATA MSrWFuR+zbCqA4LgjIlyNZjWWuDzJj0/F0vRCtv6NOqRUqVZ0oKVaSbKRiWlABD3jLEGWtLpPeTSTS49rachD8Ef/OWMbhmtti+F
# DATA VSDPAqIhSZEYaZ53BjmtmN9nfVzjTzmshfKDjC9TeUP0lhy5vV+PJ2KBC5Aa+PW4+xvI/tqGZzVrI1rvzXdZLjwWtW1hKonQzlXF
# DATA StN2ppZ7KZcQ/SBw93BuQRE1g15CxVXdv2Voi06Y3yfepNPF8nk6IPaMOfsguVi/6W7MXCunrZlLppnnHDqDmU2j0A9NFjs6UxSm
# DATA Tk2i5RUr1c/UPnBiKbMGswS2zglmoM1PDR6A+rtGPlw9uD+UlqwMDk3kr82mtcc4orcc1KkzGrmYoIuUL22Kg4EVVDMPNDIEQ3+O
# DATA jpSYzjaMldMdkeT1+KM0qEjGPYfY9GemqxSa6iL7XLfe6xC0K1d8dqjKOL5++KNJfLEUsgM3C5RmxW76KKJ6o8o3sP0zSIRsoOHp
# DATA ImwZ35fmOm51+jj7KJnK3ijXmTUep2ARC4gkD468sJtx879XCBZVN9rr2+8ikxtdCPuhk33L1/9+nRPKrWINgNY2IQSZErTNqGaO
# DATA U/j6y52BYi93BOYgrU8gfMwtlogSUdu/qpgfJQ3U2M9/b3ym0VGSs1iDY+Sz6XkYAlBxzR9m3VTSeqD15NSdMeYRlLVzfTofRJN8
# DATA yldAWnXKNm64f1iKtqDOqNgE792S/aoc09jWk85AzTBYA2qdgZZqtYYHSK1zMLKRC4omCdFQF/zgk0DNLVXvFYAd44cVTPsS5nop
# DATA CkPxhQu1Px6QtvsB3LIpNGUakjXVYIWwFF/l0OvjHDYoL++h2MLqnsInJZNh3eKhk3DJ2HZuo/PUYzkMudxqIEFblcyWhhcWVLtN
# DATA JKVmE4ffbAKRNps8AU7sGPkELViQTSEoEGA3IaZPfZrQIXv8X1/8Um3eTyj+osDBbGY0Ajan+AsmRgZxhgAPLMglBDDaPs1H2cka
# DATA JSW3B1F6F6gCe19J3slO+S+AKuc/727zH4gW8zfbdzduIRwUPi3bcZHrqJrB1E+d3kF33BY0PsznlNeTHqI/4PiTYfZjAr+heDAM
# DATA DR13uwk0UPuWp6+WPP83EzX64mOCjmEoDx28UnHRZH5FUbcWX6Y4Fjfp2YtfAerZuVbjv/zn/6b8T23W/S4cwGo31gan30obgP9w
# DATA 9fJl/Ff9z/936eqlS/pvfL68vLR8+b8kS3+JCRhDqIhq/n/R9X/11VdhPyomS0ZqCWLFoFHJQUe6uw7AYw6zbtbKAdCLYqWXayu1
# DATA 763UFhZ2jsEb3S6I6SST0bE6bhA4kUOdEO62cwSpN46z7gAjqo6BCwEkp3rbHx8dL2AhfS9Jdm5uVgkv+DBrAR4XGogh2tv0EZSv
# DATA 8PS49SBTvcsgRgLsse2a6ls2xEDytjqZ9+FEBky5Xl8b2Q/sswbBiR9lB2PCuACMOBBMCa9zATCjZ51sARtKd2aN51idbXan078Q
# DATA 43IizQ5+nP8H7P/Xrl5Z9vf/ytKl/9z/f4n/peM8Yzk9vb6woDZCPkrOks1hJz9p3ex28N5Ov5IJhubgti6lfz3Ah4sHWCYtX+dv
# DATA f/xwZBcDqeZhtk+WirJuYfvm3U1MAnYXE04iZvHfZaVdSuCV486pC/K979mc1wHeUMm4HF4geb+C6A5+n9fZ67q4ANwYVDV70MPD
# DATA cY9AaIbZOIfTsTTsPyxzujJJj91/mPzVX8E/Nc7m5kT92w1h/EaqSht1EHyWPRqoCVod4ac9EM0++CBxXryOGWtvgeRfLgff5wfq
# DATA bpHXFF89gjB6VQnNqTz54ANHtJ/rm4vJsoyKi7KgmbsxWHXKFeN0imsCEfS0hF8njdejVeHvsprpycJCC3AiEj3j6rb5oANXmhJR
# DATA VwWTrkjKUlkDUP69svij3aXq91rVw72za5Oq/vvypHpZ/7ikXlz7Xmt/z3kify+vTL67WBtl+QgTu8P8Q2YSa+IgI0j/UBKmvkLK
# DATA MkhRkkJheixz9/3k0koZkHIVZcC6MYzpeg/v/3JO0QGjvmurTdNpQfa064IbqeiGc3FPpSS7vPhowuUMXOESmrZaa9DB3PV5DdDd
# DATA 7vU6Pxmr62PyEM7ButreON5JMuHGFxeTrSwfq7YxIWDSwgO7ilc7QZeriMsJNIc0eioZySDHAgynD6icw+xB/4DP0cNk2Dk6HuU1
# DATA vWy6w4rMXtH7S56WZYVx8v2pZPe2BHlJcnDc6h1l7eti9ERpQOc2cqADyOuchkrJdLpqOaH2hplBtaAFU4io4TB9wIvqVg+JNmHN
# DATA Kons2rrZtPCfWq//sATxL8tLyYXk0tUr6r/Xrl7Gcw48RnFr1JPdWq1GG4hDz5y12QERqt9tJ0fDlhoOXfMO+kM18kEfcoRAvl7A
# DATA ExwrsUmtAyJoa9zBmlpbECmktj4lGm4B9bQONPwgYiw7iwwyWAfpdERLjWNkMSi2oPL3XMzDmkdaiYLZF90H0e4ZzPmkgitxxrNn
# DATA Td5k4iwzM2t1JNVA4iyd8ZKpM28Iy1ZHxgvoPV0Iv1vdXLcisTottZh3wHpx2O33h8hAiRTaq5jWCLCwMZn0Mi6m/lB1p4DDv5Gc
# DATA AXZjC7ThdQA7zyaJIihVMGhJPg4bmpSTScVyEwUmVFF7utU96qsNe3yiRvL2NvhnIA1NYbJv9ofrxJai7LZicr/bnDd4KBvqoNvq
# DATA nOTXbRhv1S16Cmi4ahXIB8BUYZo6092H7cAD2FMDUFvhAKDUVFWLF5LVpN05PCSUYNTPIxqsYjnvK4o3bBWSGuWKjcFeFBKuJRcW
# DATA k4ljQeK+KdKlv9BQTWc50AK84COA3yPfbNjngHUC4v76Jk8lq1Fnvxj+P3Xn2KxfOD/UVbdHo3eMPS+O4FPWKamCw9mqR5/RprZJ
# DATA uBNnnO9IrdQBFB9rlIoUM4+1x2ppFJMWWOvW8OgB5XFuAAq+zA/NC9UOkIJq3ygx5MwlyshM9kmyBEz6MaRRKJHM+0aNqnqXNK1v
# DATA 1EjcfaOWD7pwr6ulgOScvPEGJMZ6vZG8Bns8UDErKXYwglzIQI8lLRsjBlVrMFhEFT4NMV8UwZo/qg6O0nKNerN5VC6dRf0m1SB6
# DATA BMK3jYRZ1/OkDsLardWd1Rur22vNe1u3K+qG/6ierFRm1LNDwNZ3Ol0lG9cV62kuARxxp93NvFeX6FVQ3wS4Un5wnJ20aOSq9VJR
# DATA t8q1PAPE3M3WsKVIisL+8Vu1tGp6U4w3PQCe5rYEHBQSZSlqV9JABI4Dm7bvMyVea5tUhce44Ga+BHKLHXiUwNMBNtP5OxJ0QEQC
# DATA UYTYW2KPKw03RLnEz6YxYnuejFF/+96N7Ztb65s763c3mjt331nbaN67t37LLb66ucmG/0qQOGBKdVtr91SXsVKjUK2BRFEiiUvt
# DATA Iy/jAen+6S2H+Fqf4pTKBsRtprhrLaOpLIIGfv4ZPEKcQbDJa6yGX1joLGig+xwzHhv0gwDJIa6F/u3z36GNL45h6OPu1DAuSebu
# DATA UWd0E43mybI6lqyRMp4dj5UZ8XfRIQ23U4luO7TD4WjvU6quM0MClRg1VOSePLm+8BfQ/zTN7v9GVcHT9T/LV65e9vW/l1Ze+0/9
# DATA z19K/7uJcpRZe/GaxWwpoGZV+xZvFIH6xLllZW11A8OUemxVAk559bL8AkWQ/N3PFxDPHHyDup19MUOBV4IUGWbyF5gT9d86rYU8
# DATA GWUnA7jfUYXjoTqS9iksUGoFFxA4rBd01eTlz2AE5KKF3rHowUwa3MP2PCCZgolpfm/cuH335jtlkyUQsDDblCKwDRHqnBqK8gRa
# DATA dkxCFUfkTMAUp/dewiELOQ8K1bab69tba2+VbFxqB6hasnFCmplY3hVjnCyl6xvvrt5ev8WnCqA5uEhNHmArAXRJQyAWMzD82RJO
# DATA lTrAM/W0VJ5EkbOXXnutPKtHpifNO3Ba3Vhrbm6tv7u6s+bAu+PRxBNq0upc8dPqaAe8BccxnFYe/+tkdcInTCLRwk66FMsFAd+i
# DATA 6wMuRVd/EC7EjEWQvBBErrXA3ZA7LWRM/jsERCt3f+0zU9hdU1J6TGF3nLOARyC/YRArS5evYWjr/fuYIsguC0GG/WG7dFAGfdgl
# DATA eMQ/lZS+vPIaRdfZX5XnmQ6KfkVpCkuzp4mdQAoD4LgjcCPAuNvQ0UImkxCGfJgjvFH6KGV2RheezdLZhQvs7CBRmRghEUbeToKd
# DATA a6qT/OLnT+kSny3FeVZvy1xtrL67un579YazjSUAmIJK7VY36M12NgIFjp0lXl7pqGG/Ng12j+zBBjXUzcHQ4RmziFJ63M9RIb8/
# DATA 7LQx1D3tgfth2UGyxzZIIer3llLOp2pTd2lXQzJpf6alf7FMMOnuavVvW9W/A2R282ezVt1T/EsR6iQlxd65Jp0jswsm35BnkkKw
# DATA cn0R0cs1jqIGrmQSRact+WE7yOnJ4AUCeX/z7ha6+RJIgXbetD2VrPb1n5AJBPth72MKIMV4au6jvMK61HmqqpBT1bAG2YbqTQ1v
# DATA bvZ6q8oQ7AbDtzWbgaJACjgH6hn8Ft2c/Ba8S/n9k3FG2X3gx+GwdYTChy6sjlzdKuI8U2v4Eg5/xRuWXobluAN7pSFj0ZHKTG3T
# DATA 6n57Z2dzm2veWvvf7q1vrd1KnVNH62yHhqwrUrXi9Jtbd2+sARtTYhbpLSQNsrpMrI5Hx/0h30nrSXpDXagVm0GAM//6997qu2vN
# DATA 1c11OmnU9QIdqqOl9EwwqOZ7AKqpKZgUU9yL3fQHVXV7edgatrM2/IVuY6naT7Ul9f+W0+vxkpvDvuLWe4meVbgteVpLIHUU0KA9
# DATA GntrH1cUb+ir8PdNAuDqQjR2RWcvzEmDCiH9dEHD72r4Xyh3DbSq6kYuqiFWraFyPc+0fu0wA8YxY44YBFmxTx4oQLKTx3M9xauv
# DATA IkrQRbe6deoG/SAtHBq2pOFa/32xJzH9UAxJ6wA6QHoFULuCkNdYAgiPce/9vLG7By+ADVO3SzQcfIsWGal+v98+VZMJn19s4Gs2
# DATA ZV3vHJbg6euXL2CWFvhP+cyZtOuRfknFqmcT6kttAGk1b4xBYVsD+byEz9VleKKnGd3TGuiVRrmbubh6e6DkYKqoXBv1Sa+F0pwS
# DATA 5sx0ka/oBx+IphZ/v9JopH20LKOljgrV9JJ6pfUL67Po1FtDXNB71q1CvZgIvn1ydtBVe1CID+kRxj5ZKCFxl8qN1zUxi7G7QcuG
# DATA nH2xNegskjF8URvDy9fVwEvcf3kqrqAwAlZNlyMD0Fgq16VZNoCHrRaZyq1vVfV5Y3U4bJ3WOjn+yxH7efkNMazzvzX+V32rOv+K
# DATA +xHUU451125SfQbldpf23iCN+Nw9XkwvYihjdm9r/aYEI0hlrF1XDKdcKmuVlVoXX19l6ZLIJ9KCP9GI248BYE9rp6DUl+T6SBDq
# DATA n9LTqGYKD4dKosogaB9kDaFcRaQLMw0gtriNYoopkTzdl5oyX23VWL4OXAb9l/DKoArsZyWOhDD3AL7A8KGj+AqFKlfEwYpFouIb
# DATA VHjJ4DbsGwY+mnZYbq6+tdZcvwP/DeUpvFrL1b+2k8HFvjU8vSWhJSUC4YAUqpLtDykCh1ylK/hhv6sYtIP6LyFO9KrModOiEoOo
# DATA LNNhFsxIBYqg7GnkPGjY4hPpSCPnL5Zy1Kgxkb3EK+EkR3oZwT1I2oG2sEjlxXcRuv77Ujb/aYn+VJDrNvktYwmBkLhMls49hKDK
# DATA DjDJMUTEVRkcHd2yew/KmjJ3oco9gcOD4vBfFJU8HJXAc5+gH/o5qhCckagLjVrYYUkPxNxWyvN1nhHYq1UCl6xWB+r2gVedjMEn
# DATA bZA46kUxKEbRHOBztaBIYKmZBN5y0bkQ33Ttem47qVuZY7f1n74zetGWBapfvXlzbXu7+abasSDeUuZCvKcT2wE9oUF2wfwhRcyH
# DATA W1Qsa4vOWvW94sdZG3TsD+BGL3NC2sfrSX7cGpL3R0JJVBQHOrUywwL3sxzfKY0U3CAWTP7IOOQS52VzIZbYuV4J37HNn9atkaWR
# DATA fa8K4IAnC5IPBeoynQKWg7mw8pJEYFE3bIRh/JbHTTBPgg8Rrag/OgbI+IJ63KxQfJevJPiRSTxjT0wNagLEfrnkv6JTjcpcOaAV
# DATA 2AsGkCOIj7MUl0pNxtlkIicIDajupfbcTW34FrgwnF24IKxY4vbtuzJnc5R0N/pT0DRcuEDLN4lclq2pM+hvdsUEaXGWosOU6roQ
# DATA dApjV7/hn0klCcimwjRjjkr/3qie2b3m901KqzZ7C6rzUvQQdyAE+N7G9r1NUA/ou2aoCYJcQjaYlgaKqzgocRhfF1P2VAxYtXxq
# DATA k0UYoEUJg+BoIOmZRgpaHdQUyvZHSFdzgAPqqaPlgQ7ZeiZ9KFktystdCBuTls1hRc+dDrzS8PjPnNN98+7Gm7fXb+5EptmeXYyM
# DATA O1Nn2wgUHV1FK5RJmpqvyzfWvLdGoxZwL4BtCCkDkcBTScnn5vC15kEq4SlwRyYvw35OpgW+WR0DB9oS1IwXPfVtXtq9YNqESS6X
# DATA g92sh4DhZVzacRhBSBjiD3tOJjBk+CV8UxEfQI40rC+43EsTJyV1Ysq0eItaC0jyiPaq2v7Vy2w5wO92U4p0gHRfnkWBMO7J+xCV
# DATA ZvwB8YS9AlmR+gRtVuQD3Nt7QXWcVfQv5v/PUaTfeBjQdPvvysrl1y579t+Vy//p//8Xs/9un/YO1N27B8ZCCE4hTxvX87g/7Bx1
# DATA MOFry868Qi54Bh4e5SsU+DDfzaORZd3lJ5y5U4yxhwe9UVd+AOyg+kJ+6ujib9SGDBf+l7EWv7P2Q1BQbt+70dy8d0Mx+uatu3dW
# DATA 1zfShdXt7fW3Nu6sbexg5AMKIpA+ZZj+qPRGndw9dpP7o72L5TeCz/HFhUbtwnch8XxWuwMWvYNuK8+TW7gd6agxp44GzlfzQgyx
# DATA 1x+egDMSc6xCWx8fvvY1nFgjW/no6+T15MryCvlVslMWpLG9n9+//1/f+M79R0tL1fuPlg/vP3rtcC9lFhZY8eyupzTQJqvW+Xj0
# DATA zAjMoy17BD0JjRFWnHWhUn5OWwKDi5C5AK4oleTy5UtR88T5Bwhf0gh1JTXSQ5XSTrvXSvV5Uq51IZ0pm6ad27kTYM9/lqA6J8rY
# DATA EIeF1wL0ER7b8/YeVAJAE9gWWH2voDU3rekE8Tg+9Qj+VQNrU7YtcImEzHmYMdj8hQY/L1sWqKi73ZKXL1ntmKVH4g178QP4S+2b
# DATA FKCRhqMyXyWGugeWI2ZQO+J1hC3sst1PtcR/otXv6vJE3pTfmKu9l6B6znkptqrdenV5T8iYEqDJRKLlCqlf3sm6dMVVBZbl8hIt
# DATA Sy2VyxX8piugyaXljH+RB75a/Vs12Frz76t7F9WjRf9Z+QJNO6Q5O/9IWYBDKiGjiOVwIy41AwoaceQ2Oy0oNm5zs0jaT75bGgQT
# DATA YATwZJ4+q9vR6ptwZd95O41sv2/CDYj3KAC5bPRHbwLii7dVwbuGZ6Iec2DVTg56LN+qf1Hp/A5GSyuXkwv0j/W2B5BMsBrLYaJf
# DATA U+r8vkMrK9GL2XzrixkJW6OW7zNkDeFisly2NxsUL7vDfDna4vWE+tRm+GtPIoLN0QX9IXmmuNtBfFVqOuAZGOv76Qxvtfe2hChv
# DATA bq2t7syi2IrcOYroq3WxgL4ibmmFxKZJ6eutYqDGRlkSYmgO3uc2K/wMxtZc+4EarvV740agEr0B33Z6R+t3vS1a0L97m7dWd9aa
# DATA N+5t/9DRdMonp52s22a+x6ttr614JSH0B7gk5SUkxqmOSZo0CRvGJAbDPDEEOE66EoRiN4UKcqYVT/vG3Z3mndWN1be06kjrC6ck
# DATA xbbZtUm7HvBs88ph3KYFp0wc4u08FAPyF+bUjsFD0mogzpRVxoXgWrDZo61ggooZc0ikjuXk+w1kHfiyDL+WrxaJJ15dLKDD4R0R
# DATA XOiARkel5cryyjXtqOR6XmGzsQatxni8RV3n19j5ay9JL5LI/Mwsq+TDq5MgEL6wxAKEx5ssGIA5rGtiMqJjFylzIXbWFn+RbdrV
# DATA Uxn/ENDiyBTGohHsrY2Kh0JgUrEtKfd6nRiQz/Q5vHn3zubdbU9tG+Es4e0umhO+HFX3nbN5Iw7Bcu7CZIG+Do8xd4rMS/q94JsS
# DATA NHFGMzpELS84IiRx32aJJw6VixkUvTSQTmZ3dAuysjvIC7KV7u7FmnK8ZrmeKNaY39Ku/uHWC5NCKCDofhfkQrfritBzCb/dJYDu
# DATA PU/di+9E3Y3XCHwSWnloTaWJPdkR8sARhCiHu5KELq28HD8QAchAQDL35MlkKhJLoeoD3vZps2m1Bu7cTu4BmPnCMnJNnH/UTRsl
# DATA DQZGonEXPWc8pW7ZOcC4kuJWBKqOC+6q+xx4lfAtsaG42XJ5d3nPcT4XLLrdOlz+wFPxVVXu1fRVi45+Mu6jaEAFl+yMLm15jAMp
# DATA YcmKiKykXe909adQXgm0dd0FdpWGaMUlVq+kNluBd99P8FpZwprkGgk/7MTa6XfS8tyMxb0c2jNH3Vyuq3b3IgoLKQbKKJxUdQ6i
# DATA Lu07onzCiEZ811gu4+Rbc207aTFZSZKO0iwyNJ4u2ANDjrRnwqNrz13fkEbFEFphGi40SVg50eVyJB5VwQ4O+0cXFskh67TOR5mp
# DATA r0b2yAA5dzrDpjsl5Ca3nOpjBtgp/NzyK3FNs2FLhwloX1EBDW3Wo24SMg9UZld9sWc8lezkOc75Ll/5StSFcx7rTIrSGGkTUa/B
# DATA kvNRhvpA1nHXOGtCeSFOF5yK2SEPqzWqTsARdG4GUTAC4sR+CrpazMvltYnkUaMqiB8IRxVYSOIL++lJJ8/R38fZTGcpDlaJcDxo
# DATA dVGh0EX1iHt2nD2SBiSpJ5XvtCeyD43dgcNWCNOjgSEAjKQFNyG+a+DFydwWzB01vDQ7d5WC3c1hBfpKZvKTELJZ4xyMwuafNIhw
# DATA 71sTSC0EOhdbmMNKLHN1no34IV6TZAnQSWqAkCdbsgaTmLaFvt0NS+9BddShXbOOe/NLjG+vbry1FmPsZkdJ49Rnyp7lPQupzxF3
# DATA T/ptwJVrG/n/pdnpNFbqpfxjcXahyDFmCnN8SanW6qx8HSWkmZLuuZi0LwpP48Uxfix3xwKRurjrxSdl8Vhqg/6gpJr3Q4UCqTnq
# DATA 7RfWhweFyCGF5XXGON8BiSoJvmOfArwwtscng1y7vGW9HJyJWvlBp0OK7wrmb++NGiuSKXsOt0VuAJk5zP9+mgYOCrGDFPfAK+5N
# DATA gqQXLehZojLb/6CxgmUspD7uoF3ZeB+DcrC2YO1p13vFgczUlDS04Y+/XphGSZqPvNSAuN/wjw7DAZdcXhr1T9Cp2KqBGxdUoU/k
# DATA V+jGHDYqvE3fnZ3v/Bu/lJ7nYNGZtkShSA/yRdYPqjtkLPVGFQYGZnJ0jr9cKsNp7nSE6nE1d/Ts66l0uV7KkgAq4sZS/zWAHaHM
# DATA EDlphAoca0y+q5NWr3MIUghnwjIehrtO96LJrSRxET40+es5dRamWrT1INFzy/PjNQmzPEnMqqhsi0xzNTIJBHbsbUUfc1lvfIJg
# DATA pyUhGjN1e16mrhG6QFuKj1C7bhoomUO3HG8oIrJa5BMzAeLKAh1Z445v0PPIIlajBfNZ0EacskpxmmCAcK490CgsTK/dTObsL3mp
# DATA JDubq7cUI0Yrz9bwT4gDDNZQqGMIbui5kpu5zvMuFaEyWZyrXiQreDM//aBHW+64R6r+hfMf7LG5nXtxjHHVYqr6GnDBuS/8/wNZ
# DATA 3PH/O+kcMb7fN+oCON3/79Lypdeu+PgvyytX/tP/7y/xv++8sjjOh4v7nd4iBE0MTkfH/d4liBK7OxhVFZvgnK8QOtrqGbjMAJfU
# DATA gY4ELE7PK5Dd6VrDI/S3W9BegYNT8sYDTQbsXPHEk98UyPt3cBv82m6AAXwMZD4QJBnw8pvtF2h7ES68dIKrKBRNO6MpVSeaifEn
# DATA Ttdt/b/tvXtzI9d1L5q/+SlaI+s0MAOAj3lIhozIHBIaMZ4hGZIjWQERFAg0SVgggKCBmaFHvGVJyY1Tdtl1UvePW6cqSeXeU+fv
# DATA sSxZI8mSvwL5jc5ej/3s3Y0Gh6M4OZrEItDYvZ9rr732evzWgWB7SSSENQZA1qq0+1jSivkyrbZUkbIaVyhgSd4KZbqXCnhli4Vs
# DATA iVcJaEEClsGvuasxXtV34RmvylAJ/WrClmzqoDm+3xhiDYL+LTCS4/YY8UhWFB4JPjEhScQDOBN1WjN5pZVDtm+46fYAhd5gZtKx
# DATA kujwcFzb7mw8Cm67mN64NDjlXGS6kZLVieE02G5Rsqde2YTZACS+0WRKEzY9z5gVaffpGMq0mqFW4y7VVDIwHmyN/5Z8MXfKOF9j
# DATA dRwGUz0UO7MGu9C8wRQlTo4Mp2n3e0JMivVGc4POYo6oxMDLS4Ol0GMVSyvDKV5oO0stLCYqQl219B+lpEUy2kHfda4X5GgYMYQG
# DATA L42dEAvllFjf3AWQFaNIEg8nC4ulNHtk77BTLGcn1FCyc/AHequpbv9StUyp28hp3XKKtm41V+GCnAp68tQBPTn7bkFPcjgS0rOC
# DATA 7nrJdlZmoippV2kwCd66ddMZcE37XeNUvbFUTLeeqMxHKdyC1o/y4k2GlMm4gP81SAoUZo/EDACjtndricO4s3FzSt7fsRXqOYc7
# DATA 1GxCsreIL+ATiVKxThk0kWKp1sYhjrioBU+t9kTnMDqN9jUHu8kwWw4+EC2+vbO1udeqb67LZ2zifYT9hDTwZ26PBtxkok/KRgYi
# DATA XcuIEkT7w+XZ4IITdBhHPN+X4KiANi8kMwzKL1j9pGZeDdaRZUhMtJh9v9qd8TCOA8xQoIK9VQjbZIiA5x30rcRcj1zZzwCGH36S
# DATA r3CsLWEQiOcUBHMQgeBLvpxdwkdvnxz0jqbDacxxuRxFG7MnM7wlNZTmZECAPP6A5Y1nNaZHCnj3X44Zkr9gxOIXjHrmXrO0f9g/
# DATA pKYGOTG4ByvHGctDlWwmulOedfNZWVTgsd7wkpbV7GZsrEM/KoHteq1GwTzUHQlzH39MaEL9rXeZWC6FfKUaAdYFoFmP0rG7vKxb
# DATA bUxrjOxZKuHU4wSnjA1WWSObNOH9tyANgOV3L3bLtD/RSsA4ImBF0U1tpNbodWRG41bMhHyAC5pDsNnAjIWW1PljBNNWVQ0fD9Dg
# DATA h1VWxlyoSi41S03KG3ncGVd6w8X+cAJ+1Is6XDgBB2M5uRiTQKQMbc1Y2XEkBJAe36PsTi1Sp8rLyvOnao8FNWnqdSUiJDtphTwn
# DATA fz6bTX1Qef7zE93G9BdXz6yXeCbdT6ITcFDz3WGdCPJCAnxA4hHIe6N6oALnKZAc2kgah+UvsJDQAk8vELDrZgiq024XD0VnlwHx
# DATA S7Uq1GZ5PLA3BpXCaOZaX/CfbhsbrsoRZXS/qLzACSoEgo2F2A15M1EaqRm4G+KruyfFo0LjuvFSkwxhNYod77RHkEWsNZxORlP5
# DATA cEK4U7XlN5YU0+Rx0rBAEaonyEhVyjH+JP5adwpo2rC1AQ3LHExBOMJbJGNkwscpyr8MhBJPhvQV4VAkGApCvJyB3YWhUwxvU0o8
# DATA g75f2GvK9ojxTgYQT9SOCbi/YCc8CiG/27RzHBg3BkgwefGL808BJyk4//bi44uPMCslJLH89OITyDEZnH8qM1SGDtQ8uNB/MBCs
# DATA Ijjst3HEjOD0EWYGZqmDX5bQTwjM9Bk2+4fz5wDfRK04iS2TbUGmEHC/GQLsyaAXdbFBAx4qOP9CvP8nTJf5TwBinqxjrT1giFEA
# DATA MZIyDne0245O0DwW8gOEszLxpz731ck8os2uToaqB9//ClMp/wITeX4MaFdiZvz5Q8UPnokuOiurqBHtskCMlKGQ6J8MGUQBgizp
# DATA J3Ud7g0kEclHQGgMx2WCb8kJeJ7W1d8EJumcPwvdnKPyQpHMWls4DM//B2WUFtPx2fkz2VrhqdpyZ0Umly8Q4Qs69kvMPP0MgPFL
# DATA 1KvPgqeJ7XtWhYcw/rNKYKa1lhnuPxV/PsWXARkMEqhefGw74+rNJZiF5lLoJAIMp0AYPahiMV2zErEgSUgZx1nLFxQCht6kBg/r
# DATA 0+Xag86xfWPk2YbVLcD0PsMstJCp+/ez0dFSCN1SoTVcf5mR1SUZ92xzR9KDYdAazoUdQFJsmrOgikodmgxthB8KRctUl1Cv2cP/
# DATA f600ul8qDvRCE8HUoSCtSoEcDqNZ0b4vswrHq/d0TkWHlRiVaKIhBbrWw4rjDrJ+43Qg0JOcDoK4HKMrayMsH/Kb8Fux2ZRYIWy9
# DATA oDilFlkDGRoLlYX8iAy8LfJCVFm1Odep73wWjfWjaFQjZG74qFGszE2iDQ++LAsQSae/LaQCVeve80YiWYvDlMzKH0gLno5XSoZo
# DATA wQ5LbFaUnrisWjFdUj2qWhKfS+OZwVOYOqWWZC7FhbQgG1taIoJhCLTwOpGkFD7K5cGwjKqBEaYrUM8AIgz5EOZzpceH4JqIZxZ7
# DATA iMAKg9jlGiscMW7B8c2zXLOd0Bu866Tu2X8WO/V3vDnpkLR3qyehSR6BZcHExEcuqsm8WKFcB3Ca2mj4syDmLa9YsNhVuoLi4QN7
# DATA tRVdlbkHQI0/Nq2iDc5c35RXKutXdPULD6a9Pgg/2t1Pvz0nHJitwXMBwWZDtOmGSUst23Qq7ltKe6i5N6yoa51UYZch25io33ML
# DATA PFuw3LdwIQ0eVUx6biG8JeimpdkUMw9Ky2llOungkh/Ck0L42vuvnbzW3XvtndcevLb7N+Tb5vX6alTfYEXTHK5ZiPgQSI8wcMii
# DATA KFTcazSP7FJBs0cChhHE6p2TUmBB61flJoSoZDOYsxooUjtbSHqEYOdKqgfFhSxHMuo3kb50Jsv3pjRX2O/SN+Z3UmtjzZR6asyW
# DATA 3YaRPM/cfI/bcWtM8JyiQq0Ck7ieRq4EdTFvYaiCw2TpFlcut+mCVi7/3bSH6XPVfEtm6QY1mfVqxqc74GHsFmKmvjmaNRnM2dSo
# DATA 2OO1EEZTYUs5IIOtE4NHBCKmfcqNJBK6/8qNvVsyUh4YuLBSyE3sUjb3m/iWrDVoVR3nZbMzJuRsEivT7I6DlpniF5lCMLYbla42
# DATA zXriwYf1mUAch1VZq6uI8TLwhrfGphlL0BXTPeq3O4KJAWBS+IMfON5+ucae0jUz/5UJjuyZc9KlKmxkXldDQVNNV/VoQYPsNLTy
# DATA 1ZlurcZcOXxFVeLBMElstRmSfEKVlSKne5R4WgzXSUKbM+U2yV/k1CTmAUbQm7S405KDG0tLU5SU3Iu+lTXhA515Q8OGKPXIK6aW
# DATA bKEcu1FMXPJURa8Gu5PhaIQoaUcSiTamR5VgNZDMCxNp9WLRZ84ui5YlcRcPELRWulOJGXyCJuD1u5XE2lKnlcYN5d5uJDm5+CJl
# DATA KA8M8XVBGeUuBRCbTBX1rA16HT1u4AKXPATM7W68nvQ7baGuBoJ+CneWiv6Abc+ppIZ2yXPJauJKjyL3yKMZe5oMvzqO2n2M3s4+
# DATA pd7BYuYTKDKN/e7M+U48MiRyB0BdS3wrpCenrj0hrf408w06bJPJB/Di0o+NxIGhBWysA7nqbKdevjz9i9KswjWIdasIrg9Kjm9A
# DATA uUfar2/5jvUFqvZy5ZOcoTIJ/bbKA7F1P/Atk1z7mtibAznrGJCXuX5y5UnF3hX3NlKWCz7UTVs0Z5L+feZ1UucmuPgl6BoDUzN6
# DATA /tXFJ8H57+HOiY84F4F3BlABUljJg7buUV19jFrjr8+/BW0lKI7/CCrjb1Fd/hkP4LdzrUyKZiIH+/afwa1++xQyeJBy5up1Ksw5
# DATA rl+Xdwt9RL/NgSu+IZ3ZQk1SdDC1XvjZ8stJiROQVTAUrTp26ZDNf6RqVF47aMe5bvwHnljk7U+KQrhaFhTk1jjGzEHSWbmyOj6a
# DATA Ajvbxl8K0sgpxl5rtcSx0WoVjTfBxNhq8yuFUGn5CeYf1CE1IJO4M+REALEQV6TFDPWVUo4grWfU75KWk8K2SHxisyx8I6sf2dhY
# DATA 80VYN2iOk3Z2ZLGhCnAqwxUFvsqcMGh5RrEJ7XOYgGU67psaP+/wyqg4wF5mTEK5jGEzEP13OopqKmEYGhRr8h38A2/F+lYJ3yqG
# DATA cVJwUjV3aTIzvYPTUjLdIywOgIXI6Uuc5o50hz8a1m/bbwIpWl6j/H3kNTXkcFp6lw/hq7RcliyFz3HOVIAkGwuWwP/W+PlH6JrL
# DATA 1bveI4mD0zXQ0UH5DRqoBNufi896ldU0IM1tVMFUTTVIRtT7hh5WM2tpOfmiydOs00aq/c3CVDVd6PAz3+Tws2UAwCfqLoHflClA
# DATA Kfk19bTELgHzvli0Fto9Wi2kgFYLmEqrFXpcT4ndpHpJqswcP4lOZ+flADNC5KC/jsHNKDz/NzzKP6fTO6dByLJCgl35zcBjMmWV
# DATA c4kMo5yjCNNqw4n+7cVvoRGojAyqcMh/CbVD+5VAUOIz7g0kRsKmP8V3P0JLHspwQiZAka4UiNc+okRLoCv/RyNnOPbsOdAu2rKw
# DATA TUCghdtmDcIzyGnAIMVTSolUWP6vEcB1lfFfeFG9cvj37Piv5aXby7fd/N8rKyuvfx//9R8b/7WjYd4xUUc0JgQO0u4n4r/iN8Xh
# DATA JJjlQW8CqbikkwNLe3G+GLAkarzMnthi/wQ/UvzlI8Iw++KffXzYXGZk7KM/rlNj8WvdlkrsVjKc90ypqWR5wbO83APAit7klAy4
# DATA VQvy2Y5xL4T7S2HlZ0NwoIfoabjIfCB92smj3VQrhoZDkbS7Fosa2ciKk29UV241Fa50ZzgGBFUNA4RB6NqjldK6GXAICl81YW2K
# DATA Qyl+0kuZAKRmRhjGNdip39vY3dt5P7TxnUxkJ6r3qD88KITXJbar5ZksPUI8Dc/TuOExYAlqdvC4bA+STaJWx7PAedLm3oP217Z2
# DATA 1pMJmaGmTChatWZJR0xyl/csnQGNu6DGAY+0K410slfPPRPqFWWNiJAk5q5JM9ukDJMNzQbdTYzUm1GcXIEftx9FZa89lOA6oCAA
# DATA 7fMW83bwoWBPkCeoiXZu2P7tAeF1wVXmLM8YtcD+QgPNvgpwbohB7+8QQsrAekUKhkAAqMyQ9LGombfIJlyyU1golvSKH8bSpOm9
# DATA rS2Ar3wfiXrXdouiOmTcLl9HbQwyPELb3TL6mGsX6+FhQD6kpPc/QdsAc28ZhiIufNGTdkdSrExaR2zYAQTP2giK6FuOcxmyI/O5
# DATA j7dxmOGZ0Xb6LrHBQo3SHurQzc+EsE7rjnWZkryBlfawl4zqrR2VaNZ0KSgZGy4sniX4F77sjc4wlP69bmxYLyyjQooFQ8Y/FO0A
# DATA hYGg5JhSb9yR4cyePPbt8iEEDT9dXinduXUW+h0Toaa8LHxta3NvdWOzvgOYnfXNvS37IFGEPI8R5Tp0gFz4xfSQnk5f8MV8DB8T
# DATA tptegMUUjofBoL3hYmZBn35cxYrMaGKekJKzZFQsyhvIrCyuZcRbpFg59Ok4R7CMJywGvPRpQg0ViowjMAhV66OMpcgV4+OFBzKq
# DATA rEBuO0EMybikhqquacZwOoYDj0JE6kGKOYCezXnnHiXPI3ItUwHjoQ9NzjtGdmJM8Xhe8MHZoIcJewHAHxbz4zMvsKDetB6Vv9/y
# DATA Y6ZMcWKTPTjWyRwq2Wg8nBpPHDYqC413lBKNtEEGh+vYDg81JVrR62RNM5UyjkQq0VQDZuJoU5AOmGcHgEzirKGnitco4zrAZU7b
# DATA w7gic6GGA1MJnIQgxLwsLHm3J4ViFlZi3pQpBV/OFDPWlGaGfO/hcaL88tLSUrGYDZ+YPUFb74kjxJ8r2ef9myM3cTEnyDsxu4Yt
# DATA BzYtV0MO0xUCATqEnblSBlWxMDNZci71rE+GWVi4X7+3ukayJaU5333J51/eI1BiKLC9AwN1UUy1gBR4KCnZ5XRm1xynVXImJEDw
# DATA dDTCy/KMTqT1lLZCag9twNqZPZ033LSosCiOIkNZ0xpHQuyDu4J0jahKd0TpNJHtgVdMSvcaL0D5h82AKEgP/Hd8x5SNF6O9wJyM
# DATA Z2ZWW9q1w4BDyMhUlyPCWSmwWqYxjzCjpUTB4c0aXsYMwzA8ddLSouVA4HFRmXIK0hpMRwc5qVTFdqhTMZkox1NAHWl5VFHucfWi
# DATA F5SXfDm5zMXkqi8lbij8ofbXsYR5Y6OQz5rp07PRNTCs0oCfPFMkqsqBMWCTs/72itMLPzyPlgWSDjqzuqf2ALXc65p4XPrXYr5I
# DATA dS+Pz+d7domIdJODOopJPCzs/Zki48McO5syT1dm3TgSt405bhr5bxmWn3cjmY9mzttH8uYBc2p8dfgZ5RWg24QfcPsyVwnDO1xp
# DATA GceFmZcL596Z42rxgteKS10p8l4ncl4lru4akXk5uII7xvz3ixS/P00eCzlvIvlvIR6UEBNJQl85MP+Fq5vWjlziR8FK0wR38H2L
# DATA uvGaEsdQlTlDrjy7WgiLkppe2WWNakHyWeSKZCrWNhlSS4Kr7r4prWnNVC65z8EZYflE+kNh/tEs8QKp6cHGvZ3VvY2tzdbu1sOd
# DATA tXpoBdpK7yQOPxoRxI1m6mJtdXl65K6Xye1HkGaDYKEsoyWeblC51qNzSdssyA8TlP5KLQfXTpkA3E4q/duDjd0Hq3tr7yQtiKBb
# DATA 5/YFX0bipgNGulzR6hAibP7Vdx+UjKWHNmoJSBZoQd4T0dWOrS+ybdSBtrRpxsI6SmZ0o5fM1OgpgtAKSkG4SnmEVrrVrtv0NGPV
# DATA SXkZ6xwG7liqCRnHsUBl1zlzN0DiNjIi13fq62E6bmmeS5OLhJNn1nbrO+9uqF34KgoUcSDOfzR7lQkZSlq+6DSPIQ5OTEFwMB4+
# DATA jlF5PZpO4spCQrJpeCKXrvs2TjORTtKnYZ2dmfoSJnxXIEg5q6QWRjyQOfMYoLklZHIgAtoSSaTVNBAP46KpR5IT2VZn3GvwfsKe
# DATA smAlvxNki7kBOFfAQlJSScMVMSa55uSMdV3rATSPvjTN44H7immdsyhy9cHdjXsPtx7u0pLsre7cq++F8+UINMauEwUuyUD4BO9y
# DATA cm2h4EBVhBiiV/WE6ClPAG1F4kd49ztTPjJTEISFKMDtDaYnB0qdgRZr5CMBA6MxBhu0/qaCFZGI4KNoDDgKMWIKIeIYbkqMYgON
# DATA kTJbg8cRZttWIjn2gNvOrZX4T6KMsCyBV6GNMLZVwq5oNMZMPldAGMyQCcpWEbKqBNSedEZGKVi1A8iXOTjSsL3bYvnE/Rv3Fiwu
# DATA 9IgLQaf4Y8zQwZZhTjRW0gXA+0t3OgOcElo0IUA5u0hTAn72Dg8jVM9sbOvaTyDgEsA6gzb2sxJs4gkhxDmg4/bAcFeEHKERwBV6
# DATA mYQjQzr7W2tfEtt7JiqeoYFIb2CW+kAKpNbtgrkIn5GO0GH8iB6eNVUyKTroYmYPjVdTeRhX8FT5PLJOQDk8OptP15oIdcKkd8nA
# DATA s7Rr/kxAKqUDmK31OLsaAfrVYE/wSbUgsMHIyUfyVbl8cF49ipD1juPj3ggQawcEdyQvWl3Gn0xYlnynhTmr3jNDF/CdHDmxvpLG
# DATA A0+Gd4ijaEM8b2syRGoxSCGnmUBviksgjS6k4Hgq2w8beyqu9Uclf/enpE9LaF8jPy3jyXDs2CpVX16Z077kVuXI2RoRPB1kNMWz
# DATA sFjM4nVeQZQZpqTuImQXvoR3HVGeB3J/FjA+P7RhdpKZzcysEkTB9NiMDqVHBfpD2VGpV2auZDsmKY8/MUD2IJ+GvFHk7Wv6Jr6A
# DATA uKdHIcU86QhnuO6aZ5SURJJrmRVm797jXPQXBpqkVjK2bU4ryAuZ2rjRS0T5E8gMW8DpKmU6dbqWIelhnjxck5eexCU9kaZUSrPw
# DATA PLGFkmHm5FdruL4al66UPtArvoa1GCadI0pokvX48s468qWXqOFsljBuaCgGi1htlBiux4s9Y0i4iZdQtWY4eaYjK2BqXV2QH4OH
# DATA iMx8bI+ezxxvj2afPDP9SXJ5kehRllSHwumg/ajd67cPCGQlTNNHX8l1Ml1NTf3C5InUwZCDs8Wjg+Gwb/qnqytJRn0UvVylcTaq
# DATA 4oLXdPzXsVbdTf1TVrXa/yeV7M88IKnqFt3unjIkjAJZXpGYJgDWwDl38Yg4GQp+Nxz0OpiVm8sTZNcxAFomCv1IVeED0fJvl7m3
# DATA iu3nb98OHc/+nQgNvPr35IYpamljrEsDIdnIFYn3M3Ym1OaglXih8VOGZNWT7Ie97zO6YSN3ZLFjjQUqoTAy1aur6+8rHyE+VS0F
# DATA tgon1zprHWGuhTvEOTDhtSPjkeRm/aG4TufXV29t18kaYqut8+nZNdqD1WPZ25QeUcBylmQCqA+2cOJIJE27QQzCp/YkMgQ2ihWI
# DATA wx7Fm+WlJYU40Rn2h2NPtaad2CC5rL6qXjBYhUK38PRRLpjU+RSTolZyNl+p8YqbgpbkSpKqVNCFeUobqr6JuLGQpg80eHJ1Fbgp
# DATA Gm0nEIoC6Iq9iSjH6kCAogITYjQCjQ9mLpXKvlnywZ8tBqwN/aoxTH2orqZRxXPlkoVn2lnYzAHagt2NzXsSvhU190rfZ5Iiq7u2
# DATA MI4RLFfddh+MRCx+gmkQESVxnTisJa4EUqs7OW5PDL0CLD3XiDGjQAWkkjgCVRjqGSaPh2VJEDqjo7S1tGUyHCSJCuNadrunCNWc
# DATA qiuAu9KaLEaiiuhViyDOagCCKX4LpbxKK2ANiULZ1KXcDi40RAA6biKV4T5Gfv40YdnmFm1XGXRvkr30hBNav2lVAG0bR2wyr9Ri
# DATA P9FGq7mXUHE1DJ7uD2g3Y3ZenpPEfbJ6c2l5aX9wZmYdPxmKSyklV6LBNnhYTerKI0H+J9bc4YYExT0nKDJ9ZUuYrY9deakCQG7h
# DATA ExF0rGFqAiIuzyA0+AaBAvKE2bUiuXO9i9Gks4jlFjWBkIoOyIGGWDRTxCiq0Z/BdYWGZS+hhj/GYGLBu2oyDTA0LtdFs1tVo1zy
# DATA KyEyTQm806VwzgU08g3YMdo6pZxkDLI98lsmMoughrhF6c7Pik6WLH7TusxgbqT2ifSGMhmXJ3t3Cgd7Z3W3tV7frm+u1zf3JD+T
# DATA 2pwckNFpGeopN70RNVj2ox37s9TPgVWs7qpzwBC7cMNNHaWKy6WXqmpof+t8jEKOsGm7z+hYdJwDNqTg3kNx5xQXuDfZY0mekoGY
# DATA IdNf/VU7g0fAEkRwApnKSLkSwzVAMPL2IDAmEc9hrTRWfAJ63cQb4KFymmoYeYjMdYBZh2qaqdVIgQZqCQfDcH6EZQ3rk/1a/vKz
# DATA 4ZhT37QBmW3INTp3U0Ny86kBLxHbSw7/7X6LOuBG5BrdKpIFR31XHopOHiVVowq0Twnx1eG9WdXp++pToIqqGZvL+0wH5UKJs6Jv
# DATA /5yxPxighnYtWOv/eIjbVBLJDXmr2THmEnSgTgoGepEf1MvBxU3ZHRmkLHFzMWloqDJ4Ry121HKR+9Q6qFgN8vzqtidRggi93fH5
# DATA k5l8VwMecq0JY1xi0b1a7OT08/34euIonLMeSl+F1wcMGU9WyCd3Doo30615qL+Yy/C4U3+wJe7uqFVY29p8e2PnQd0B37A3d9Vx
# DATA Haf9bp/R9huOEvTQLwf5vMMxW2UCKaNpbWUlv0rbJqe5zISgcHukXkbxWxrC5VPOnXkUpfSRjOs5mzI6p1lDMR0A1CgvWU4xM7GK
# DATA M30Jf+aUreGNlVVZYy2hBUAjnftUKOTicVs9KKbG1XKNHlJK9h2y14IsgYRtUrjxMxiEkkJu0zvroPfIIubkQa6PKvY6TcNKNc7I
# DATA ksGVTOAKAktRCJqo5ZbngNQXs3rfg6sKQTvEQP3cfBbeqncvmyxknqmYsb9d+WKOVqx5dOpxAYJTRBNPE0ap6YAu2onYDbrM2OgF
# DATA HEiUMHh5I6kyR8kj5XwTaHVwbNTpPlf+SIyZiq35oXEzQzJM2NxsyFyYSRcm1wwl0FSvLCKgS+zmdDqVR7/BKauJtF+KMVbl2zY0
# DATA UhoYh5aIc0rjtteUK5crEn1BBDDT5z8pqhftdljRZOLJS693WY0RB+BD2FGQV1YZU2mh5XXTNZSyRZlRx2lrWWJOrRXK2+04ZsdR
# DATA SRAMFogXno74DjMtvqM+B/EEO9I4EItl0Nm0lTo5wz85EVOb8MjJ5ZdRnHdhXddsmW2Lba5WcEe+XSHjvwPTlVl0G6K/QzcUhBzH
# DATA Bo80nVhHDP9izQM8o4gwiL+Kez+Pgr8M7ty+ffPOPN7o9c13DVlIO6WCJ0cPFNH9wjj8W08YeK1ghAaUmzf2K9nfiz+gjCZZ+jqI
# DATA Jak8SCAmKYfNmuWwaS6T46BpH16UMY3oWuYDW3u4u9fafXh3d21nYxtDhHbqD3frPDZQh1DVgnHsD5RF78XCYcju6YTAmPHsHJdk
# DATA yex28aKWiuWjZHrn/7RmmhyqRVpGfy46r10ly8bOEBMaSNO8wGROtLU70VJhmOjdgPGijOGiC4kOtWNvX9fnj4JfXyyKOt8tMyVA
# DATA LmVukogc3JmG7EizwR1oOhCU9k6wwqByImnMGIm4I2/W13gj//XDjR33tpzWh4TzASxNNw9Yh63vnztrIb3mzVmYKfBpye/6U3HV
# DATA qqo+48XLk0jLvjGmoId4c7icnWXkVEtdVEjmnGPjJJzH5GQJgSMaT1rMa1vMWONkZDKxi9ILJBt0rTnpE58wD7jM5iz5cvJIaDAB
# DATA NY1cPMpDwHUmk/PxkCbiXaoNid6DDZ9MWu15jzfL+tZ7m2Ljr9dbd+9vrf2kvi5mS5x0IKxjreA/D6Zj/LLg0rkvt6f+PS27ZwrF
# DATA JOlCp9WTh7v7nqdoZgo/OgZ1YT4IiukZ4ubyBERpzNzNNEHFkjsU1U0jxRwfsJfJGZhWuy9zJN1seVBoP82XaCqPPe/PyIaXvbtz
# DATA bOKXYdW6vJVqbntYllXrJWUlfBXOYsp4GkdiFcWH/umbeOkzwolkNEwcQXw2/Trs96G9gBwKKgv/6W0+PovW1dkSr946eEnr5NXY
# DATA Eq3j/8ptX8mj9/r1wtPQNYVJpOxZpxOyzKRQo69c4Jwxy6KWP1vl5W1vl7ArZFrKXnoeL69T5KzEk6ZT5Hz2q/ntYi9irslttEhm
# DATA 1ctQvydDKpIGBMteZv+WZYDjypVhDevJ/3qasXCuCU8xMRpw8i9gPLucGUlmCuRWnIzLmXn3rsI+dNmcfN/bljJsS991wsJURmfm
# DATA KyS6mo5tDaMj6OvYvxQUTyqVit/D4RfSO8TVUhbc5oo6/tBwO/fZDpI3EgSDUDpScomtkVPK8MlpLZTAJuFs5JKccCWMS+HDpFi4
# DATA qjtjrqnnkEjLkGHDyOSIOgZGbM9DpT3oHA/Hs5041zd26muAYIE+JPUH23vv6zjKnoQHmMOWYVlllFQnISWMwQiRHwHiigYoK7bz
# DATA An1GWwk47aoYGUU6ygc3XyjMztZPjUqJJI3wdhmr7A8ctvtS017tcqRufWkD3XqwupFQVaLdOj+CK2nSe/0J3ZP6EDtdExVUGE9a
# DATA Xjx5FdGqIVdUxvmiRc1YIgYeTd7CyM8cu9OPr7oXmSsn0RfEyv2VoI5W/acbu3u7YWIrkuqGWU266oXYn6V36R1aw09Suenxu6pj
# DATA asYR88SgPe4c9x5FfLPlutDtNhgOOtGbMgG9oU57NZgOEDgh0i32IGtMe8BxGBEYUyhxzMEYtr128uX20lQyqmNzulgbVefS0STY
# DATA QjZIgvME2J4JHeGp5rLIWi5SBZ4TctIW5RV+ajmD6fLZQy8RHFdr+IExE/rlzrF4sYDvFTMwwK1UbqIIHx1af+9R1NeOJ5NRdVED
# DATA vVdvLlGom68wLLPcBpWxhgn26ZCSFuqS2W8LkOapHb9rRCdWwbNK0HxcBr/MUUTBmUJMRfVJNWhY7iCqqaKjeA9HiAskyh+Gyyuv
# DATA V5bE/y1Xn8LTMwyRcTX1xHTgjacOWASJW+XxsJ/mXuLWNDw6osDmp2F33MN0xGSkLEsd0HAk9YdPw5P2kzKY3qHQ8tIJ6SCflHm8
# DATA 4c3wzG2AYk47x1HnA6xhIuYOhhquPVhH6VJQHfJU/O9hBEgK13jd9WTALCyisVXIyotU57ViRXCfQWFc+0sZbo4pUceV4QdvLVWX
# DATA i8VKB4EZCkWnhPiJkRNEhUKiga7fRibPgc36geBtwKXEg+UVCkYdT1qjaNwbgidduLIUh2dnaYcrzHhDLpa4xs0E9oCrHX20LdRP
# DATA ZZB7womIliW5zhQdr7vGx4HbN34sgyUYgkGlzrbUJmR/tt54qt4QvThTb0GXIHsOLJb2N+QhcAW6a65skaastTaSjquSYvbl4s6K
# DATA iQEaBnYZeWYxAXpYXaksL1d+KESUUW8QhTmYgjJ4wuzc21qv3314DwqfiOnrwb1t0hnVlkKcRckPwjeWqm8gw7t162ZV/M/4uDjt
# DATA jpCKZUScj9/oaUKfsKovMq06HiqZsgxhsNVF+K9+RjNTXWQ9sOW9TnMmu0AzpWuSZGHWg8/OZvFkEqbKUpgSlwVXvf9y3O8c7mX7
# DATA F1cRTKWQpBTHhO1GASTXxTO8ogVZQR/OXgCmJ9Uj0NSoZSpDU/X+OTSo3dkaBXk5s3WbXkVUbpvYmRvZRMiiNqQcoz1j8vIqn/Tj
# DATA GEGFZFLfyur4aAq7dRt/KUjoO1AYtFpi9VqtovFmRdB3q82vFEIV4Q40S6jLtUao9OllDQNNIC3o3h8SlM+ELz2sydD2l+k4Uny5
# DATA PB33+Re+DZQBmBxPMBCr1Nmt/CnxqiLoheEj8CZZ5qBVZF7TOCoD39HfqCaSjVzMA3kU+jAbmhkzUy4D+YrSEIVb20YVmHSAMaRL
# DATA 08nediAKUaJH5MDUhLvWFNnzoUcsx9o7sdOQUlVPsE62qtDgyIBigj34BwhiqHY9Fr/EaNLHsvgHSscacQq+VWwwBS+luCgT6LXW
# DATA nZ6M4oIXYBzrJQ0HfjTwzPG7ySejQSzIq9WOO70eQ0yzLN/P6mEUWopfNLpjYVKyiRVAVzD9nBxzMXj6Cryc5L3UNGLVAqcHJVvb
# DATA Bb6YqLly+1NUa6FedSx4euolUPysKeb7An5WFjp6KdVp0jOoGWuB2zqDOiQAmOrtZRbc5RkZ7bngze4sGfo2mm9WjlyiVwbbyuiQ
# DATA gRfs9gUeXr5hzSFNABO/B3rOWeBvBmFm9kNyd3f0Unc9X6vGpkElrNsVw5dZqbKMiQSNR4j3VQ/9s5AORULdOOEcGGrx7OHKQ9HI
# DATA nMwK/8TCotNmN+9GzG5WH8BVR/QF00V20/MzolldsU78BIi+coZO6VYxfZ+QeyWltoeYNsuP0nvYFs8usXf08ZwETkrYJZKjUNMp
# DATA TRSNpWZ2g4YIkHa3NMhd+s1fxWpp8csdqkY1SlsnWbNpKZcIW9kkpzG3hKgrOtZCs1GrhV1qtWAftlrcI1jjuHc0mCKwYgE+tvuV
# DATA 3Y17e/WdB6VAf3/n4baZaJ6e058CVVAKOBXL9Za4iZ1qXUvS/4Vk74VLO3+SuLB7GgtarUMr2pUTNCzDR9FoHB32nmT4f9pQvVaa
# DATA XgVqmCsxpqd74iocY0Z0F+05XaoRPTr/5+D8Txe/OP/8/A/n34j/fhlcfHTxsXjwTHx9fvF/n38ewPOLj0Wx82/PPzv/6vzri99c
# DATA /KMoCr//Njj/Cn55hi9/ff68Epz//6LMM1Hd84uP4e1n559B/RcfWeUC+H9o+Pn5p+fPRMlvLn4Fjf+9KPLl+dfB6vZGWTz9VtQF
# DATA LT17E/r1ycU/QUXi+afi82/Et2eiB06Hn2GHRf3nX5z/EV/GCiruLZt0uKtra/Xd3dbbqxv3eUL+TdT1rejU5+LvV1BbrnFzo3/C
# DATA l78U5anRwKzu4tc4I+/s7W3vlvW8lAJR/FscxSeiym/486/Fc3rtI9Hgb/yz9wxmLzAnypmOi1/JAfxJfP1IlIIl+hcxcVQMOvuV
# DATA 6r41Zxe/SswZuqy33hZz1XoAsT13wWC08e7qXh2n7n+mLB4OUPT7D/BVLvs3MAPiIVDeMxgvWVlwcNAJfGQMcunO0pLo+v8nq5Uz
# DATA jt+fiY6LESc6LA2SuuPYUYdEvz3/3cWvxNoSDc5DlgF2DycNJ/OP3Kvf4Xg/Fx+X7wQ/6d1N7ZiOD/D0K23r/E58+AL6+Yko97yE
# DATA v2LzXwNhPpffn/E0IgFWA9Bvx9VF9jmMnrRPRn30Bkx0DimUu2Yxi/+HWhC9EqT6eyAeu2fY2OdiNj/Bhj8ShbEusW786te8XF9f
# DATA /Boo3a0AafRPOJJfn38hqvkSZ6I9nQzNXp6lM2XJBtGFSnNoIT+c/6uoGZbpmeASzxOMw7NTeDG/QAqEnfjLjG0tPv734PwPYk1+
# DATA gbT9Na7EV6LUN4J8np//Hn+htn8D7EzU9RUur6QywdV+JaoUXYBfxW+CKD+uwKHxF9//+/P7N+kLGej05baxJP7duXUL/4p/zt+V
# DATA lVvLd+Qzfv768sqdvwiWvosJmILqTTT5f+j6X7t2bS0aTygUOwrYSQmkcM4rq43fpFuMHgc70hInHb0oTAKDtnsneJ+V2mD5nSoi
# DATA XZ58Bvcn+XkYL2AcEVhz+r2DgB/D5UIWGavKtEipnpyqj4KFjuB+sUAVsnQsK6S7dMkybLXoYVwK8EbDSm5xFRjEcb9wHS4GJQQ5
# DATA 5bDcw3avD/c2ZtK1UEginwOPFLzuF8gPJS/crouLAHBewXOfX/w9c1tg1cwrWR4DYQEPjm+hoDgZSWSzZLjnyGxFEx9DVaLUV3i0
# DATA PwtdZHpD4BaDLzRCHgn4IcJYIJEjpEarwZDEZa09msBohtMJPCSLo0K1vm24vSCOONkFOsNuVhY5Z4Y8SNoVwriSzoyaAlujdm9c
# DATA OB7GE4bz0D+VKHmQuXRxLVT+gOR9Jd9ke4t4G3zTeo8oQggvq0aVRVbXiIoNxHy8z1mv2jH24MTWQbxEcTKPKGoSv4f7g/3x/lI4
# DATA U0VLFxYUfIBI+IiW8qUQKQIU5kB4BHGaxUche+B94fnFPwAxgID5Kb4iqCSZZ3pkIEnAqJIQAMtLK7eC6/hnZof/PUl7LBowBavO
# DATA gwgiOy/GVpZiJ0pyz03RUsgcvwThMnjQu6tS/e1E7S56QgXx0GVHsPTR303BPQacw8GFdhozZq1EMQbbB9BQRRFAiwhdrDF+Ai9O
# DATA 8ZRUEwenoPAvqoW2nlIwC/OB8MntpR+iMW4wBD8H+IS+GdEATSpv3LmFDjbIKFSzclRbopbd3fsy2iQOupixCjFNezFiEoCv0IRx
# DATA 898U2wTURGIhBz+PxkOZ1YCCS7g87ViVsOog7A6jmPANzG0TSkfImSOBvSO+6c1njyVnsLGJypPglF4yAonxM2CLQEWObP572AtA
# DATA W3Sje5btunkV9Ss+APOAu9xzVhQsLqTnDG0h1m8yaNe291zlWr34Os2xVvYdGO5BIOHTPROuup/CKWXMqOAG4skzvAI9S9xNcnDK
# DATA 76QXnFCKZIm4TyQA4gMYBC35gb/TEflzaeB6NYB1kjAMcXAwnBwHO7uruGHra+u7q2+KA4pT5JyAiyD+ejLsTvs9xMwx2NVoetDv
# DATA dQDROEEE4ifBxix68PEbZmaemkbydfGTpKdRG1KdkPk3jquyTskvtcOx0blXak4jmbvy3xK6CH1uwHEgluFbIft8jMLOx1I3hgo7
# DATA n9Bz8Yn0wwRzrXei9G5By3qXvAScuap0IxBkColURqKuChaDRW5Nhq1YFBx04wI2KJOD1Sg52HITUk9KwqgMho8LkjYq00mnWIFv
# DATA ohcno8IM3oXy3lcB6t2+pFngK75P8IO7+j/Bbf0bUm8+u/hHVEl8dPFbOwuS5wxUQSSj09kCl2H5SpO99LF6OTGOlzMCU5bEEHGC
# DATA OhZDqCNWeEhG4dwITuf/g6YORabfY6diR/ZCjqJkL0PIUqoeMcEfCRr+GrUiX4aJrnt8gn1ewMYLCT9gmDOg60IIObI6x+LEqYyi
# DATA E7If9R5Bwk74ygJKv6vzUZnuH1iLYT2hPJSy1UX42YI9mStP8fn/QmXX53i4fm4JeiAA2vKsKRK6cype/yNebtSsopxoyLNigBIh
# DATA fWTJZ9TrZNSwx2xi4wOCACkm6Odiz+MkEWdwxtyeDE96HW7LnThVj2ULYfNH/mbF0Nyw06xVMhALsa44JWpuJAPZOIuVTXrpoaSJ
# DATA YY+ccbpRaHZh9EmS5WUyJJn4lFAFISkSX9DFPgF95wj2eA2j78h1HmGID3tPamFl0o/LoWc1ES55GFcOu8D5C2Yj4eODEA1LgqVH
# DATA 7RM3axY8Y8NlYmBGicP+ND52wgChvfh00CnIMmIMg2HBiOYexsonnxYdg9xpX0KkYt8YAnI3lBhT14p5tILNiwsn0eR42C0xDoKD
# DATA wGemKKcCVnSZzERu3AjhSfJSeOfmG7c8PwM/C/5bsDRcev31LB67vrlr9rkqeIE4yv+gjB3G1Q+46cbmhmIcAdoIpK0E2cIdcady
# DATA MMdMVVKFkFbY1VBDikkMNfNVYh1w0g+OCmGjO4ib+4PwBg7T8M6Q6xX1MSM1JMFQbqviHeWjF41PehMKvS88hV9anf5w2j3st8Gk
# DATA P+qR1TtEwABaN/JCUIU44Q+9e9QZ0mv8llq6lFdlCgjqJyWccDsRnXCSI0/nQAw0ElGYozGqVfKQ0RJIfqq0kWz7EbqjiBkFFsdf
# DATA xvxF5e+gSiqYcGJWfonzfwbiUIZboiJxXFz8AwnwX6OhF8+f37EB5Bu+0AkaLCv12TOyZEKR0EGGM+H+5FgZnie3SPEvSNKfn38h
# DATA GgOL1UfaAPcJHnjGZrDaZ3Z3mRAii+1SbRCiW/nZsDcoHIZPPzgD+/kj8NInV5SSNf0yu0cFYRUx9y7zGnA2N6Q2pKBSINlODkHQ
# DATA p4SzqRisYLbzI7ZiBIAaiUHHoQENWbmxX27e+LF+UjHBI5tPV0qQOBRrmy2+pKlsadNonn4sOAP6N4ccIEG9DW/g3xshxkIg1cuB
# DATA mGlicbX7sUYHtc9cXXmiuPy4+Kg9Xuz3DnQq4EXxeNGSC9MKGbKizBOkuCg1fUOu1A0MAAlviNduhMk4EDuMzMg75Go7jLGJmmNS
# DATA R+fXnjg+YsGNGrKUG8DFiLqx2mLe7pZnJk4ynJjMu4YZJCPd4mmPwG1uLFP9iI2AtesUfR4S1nlU2p2TqNwg4m02FOIpQAVxhbN5
# DATA jUO0guugy8Mf4Z74MTK7P1rMjvtEYgF1NhlfrjXaWCJToz3HZlI8EK3Pn+EV9XmwuvagrtS9MRq9xWE2ijrigigWkXQmT6LOLia1
# DATA +bvpEPwbA9CZdNHXsTMh3Ux8HPX78nfSnwhBsD2iUwwHomMk9/eBhvbFv9CInLxGD6+Zz16DZ6+9xj006IOSU3GH+W9YXJS0cCOU
# DATA QYR2gtSw8XDQmwhZY92IhNiJbEPa3v1d8468P1g9FLJMjSO+ykMQESP2sAs4XJpb2x+814bTwlsWeZPVGQ7JEf3Zg0ACISTFx0NR
# DATA 7uGDdvxBbUlId/sDNfu1a4LR0ZzeCK/tg5KID6o7t25dYoJw8+SaHjkxxqSIfSUmrd2HMTX2oCbx1tZgrS3k8G57XLteFv8XLN0s
# DATA Ld+uLi1VgU9ZQ98RhCXOzZ9H3fWo3z7djTq1m3eg1DYo5WO4DNQm4ozF+jfIstmk2Y26d09r2PlYTawzF57QmEtFxeQKiJFYEhTJ
# DATA MkKVnilnKKADjL8AfBNS702OVazmWEqyhq9qwwjlMLXS4ivrDS1fVjrVMZCFMr1ZYSIxQwWqqDH4iIM2c12MklEgN5Q1LvmjlGk5
# DATA eLImMysnS1qcfzrGSXHfAqXVyB9a4rijqgk33JhdbVe7Iq3L7Yql72pXUOPVtiO5oU+mD2zCXXl0ajlNS1Xd7GZMV/X52jRIyGja
# DATA uIG2K1IYFDXzLbRdMUVof8VOeCoJmuZIWNQ067/0MIi8q1ZiXpg3dWiLj3QS+hyFGUzSgLYmF+cKwSom74opJMP7zpZEXw1+EkUj
# DATA tFRK/KJAHsV444ac3oNOfwpo5wF4ZhwMJ2Ec9AGNgC8kcSWZJb0RTvoyiJS3ZdWYTGs3U7AnD8o0hle0UFDkLW+VhX1plrHTZdJB
# DATA wNNkgVD6lU0k6BpJmCf92JPPneUX8FMiwDZjJCi7WL9Cn30YT16ZhcwL3178A10fL/47OWbgBRON83DBFCezkwKI3NBFkw2rM83i
# DATA m+ZP0JNmDjfyGd7dfvdqOLoTntaWYuRS3tdgff8ZAZZgAldWkZFIJl5+1IPrisEPdMpBiUASBf3hUcVx2Q/P/9VwbBEzWhUXKMOv
# DATA ESH5dO7RiPquR8663dB0iWGHRXSx2djcKGmHCvH/bG6HiF0YSM1IpZbudLn8f6KL4vTwceto2h53X6IXYLb/3/LK7Tsrtv/f8tLN
# DATA 5aXv/f++I/+/vQhs2+1xrw+ADzEYWiBvKOMQPXz7PSHFYjZdPo5KpH/vDSjpLFgixpRg+jTLBfCwM5j05/D3i4+nk556geJl5vMA
# DATA 5O+AXSQVXOiwQxFeM/zmyO3P7x0nDn/HUe7W7Wyvi2jwqPb0+vVhLJMEiPP1/lpr9T66zK8ZCt+ZfnY75NFonGPgI/YZWTUvPoLb
# DATA to6AeC5tbhiOIf77W3goXhHL+mbg4aeHQuh6DDhV55+CjwzGE3xy8Ztwpg+fmLOWcRzKfCASgvC4h2ZKY5K30XZjoWvZSL9svYY3
# DATA K4/bgkHLyb59aykPoCa9OQFl9QB6VExPKOBpZHkpAbNvdH6PStWfjGy0Ol3ZB71+3wWS1K1kmdNsQxrdMrWCSdpxUrXTSfrI1k+D
# DATA KRatrx+jDh3I4WsVICTIRFu4X8CSJ44ZryUPjGpk/jbrxxHns/b91zL2jaOD4XDSkuy0IKatxCqyzkRcj8QmExLNsC8kmRqrXBKq
# DATA 3zLMtawBJKDpoDeppSpoEi8iPqxWZWnKo3avhPa+svwwclIgt5/LveKkPf4ANev0EqG+EFhGyJrHPUTLE9NdRgevnw0PxAYXgwZs
# DATA vtHwsXipP4xjmL5+74NIKirFXWwybg/iHhx7eLF0NY9iFl9c7cicAJaulKYiw4XCTeic3qIbYtakDhH6o1SFpkIsgDwV3R5lZZ0c
# DATA 19GPoibTe9AMFimt1f4gVW9o12hqDgFUjmdFVHIt4Jy54ixsH/QjQ8u4PYwntcVpPF486A0WxydB+TBIdMNqJk1Fh4hQ5SlcgAw1
# DATA naGtRI94Y0OFlEJdkD1c9aVKLFGKuhzSXqpgnnNrnaiXkDYChSbZqvTn4aOMgnyrTJwzWAEK5VFXHpClgIKWRdc4DCES0yfu4fzt
# DATA 8XGvc1wjmamCX0pSKjMTh4nXCVkQs0+RNMRHKdYmfpSfAITRPtMJJ/jwsSiELRRC8cU2M4gHiROcK7SPenZortFcI5+TSDnNpD8e
# DATA /lBBV74YjgNKRDKNIa84Tbllochol/uZUaOnPh9v+3efSMWOT99yNPJn7CMleNqbUno2wvH+RLHA59/wHEpbiJpeflAWc2QVEUTp
# DATA FhKP7JWQlbGGRJWaMSyOcHS4tnSU/hSHRaKlegiOm25gMc2FcvxIDqTbi9vjkxbwX/CgYFJForPPwKLvEGTIarEZA9S0eY4+L3Yp
# DATA s/5VwWNk/TKVHMgWoHMDFYYUgivBagBynOBgEiV1DKir6McLqop+0GMHfINldF3I286w32eApXIZT2PsG/H2clmwH6K5GuJCakYn
# DATA fsMTBtKKjAT1nNZWO53puN1B28UyaMto4+hs5JJTNYve1BlypxkvwEIYb8zaPwnZxtBoYmfFve9EzNfj42jAYPMcPNbu9Q3Npb8z
# DATA du9Nk2oGl8i5i9NIXm9bdAtnL+RfiM37HMJfP7Vp+/zzNwPyT0Kf5i+lBTZVhEF+wD/Ih99CFWAmBado9IC0wGjVzigU7fkyjyTG
# DATA DsM9AAh1yqbz0jHaciKRed9lWgrhDiEu2DXVo506wFyv13dygX9xNTSkuMJfG8vVpsKiks+qy01QuwLKftgkPaL5u8kyZa3MMilY
# DATA jKtZajpm81mir3Z6e3b+O3RwBypKWsa/Ulr+YsKNL1wUy+4I6OBDUOkPOx8k7mXgCI8QJgO+QYpvW621nfrqXvAhfdlZf29Hft7c
# DATA envr/v2t9yxJhdD7hdg4no4ACkfikxyO4fbiOLYiVr4DfrKxuWdin2RjoSTxUGQaAP1Ga+Pepqu0/Ul0ejAU4tGG7GmhmA3JMlev
# DATA /Agtxqyw4Xv2tRSWyZgzUICJ26Z4WID/lPgJAKu06j/N0EwnZEENSPbiFobEZGaAxYRKiEEBR/wPw1nfTOd/3yIawsU/YMQN8Uq/
# DATA Niq0zR7mdjIMH/PZMzLAbvwmB7NVZXQwbRcYzPtPqFb7VaoOzTNAKVGEf242BkpUU24fgSviSzIBZOr/l5du37l109X/v770ffz/
# DATA d/Lv1VfUxRsykI9OJ8fDwc2Fa9eu3efU7ZAJiKhEOqlVYJ9wqndK444ZDhAODvIajIfTo2OUCJXUnNswcNyOwSCgvp60O2QpAOAX
# DATA 1GPAkUM/gt4XkFl2ICY4nrwjWGP/KuAFhAipPoOr1YSaTTc+AM+wrA3Y2HTcF21VxtQ72SZ3tgQ/w8GxoDpAvMdoRTs8IDax9xfG
# DATA PF+g7ORoUGd7fQtd/YUkZ+RIWFi7vwE3JlzzPiwwqVykhBEurG1t7glBrL4DWFt7O1v3sbgthoAydTzshwu79Z13N9bq9h2MQeqQ
# DATA YpQaceHh5sZea2dra0/LNj5nsYXthzuQwgMSkabUWX60LFreW71X38UQKdRicHaX7vDxABU5GClFSSYZhpayXoSc2vOUXwBnjt5A
# DATA LCWD1vYO5S8dQc4D8UJx4cHqT1v3t+617r6/h00aYfNKbUsppMbDIzHXMWfHGcuVFgQFGIqIZl8Kokc6PEbsim0In4yPgwMwsYl9
# DATA JOZhRGXiEmf3kHKpFKNjvCa3HwdMhjISHPYY3d+I4mqg1Gz1IOMjPmBlFF257QQbVh5V9HCB7aMQs3nFF1ltYqQTZO0Mu3CI9mQW
# DATA c9kJqX/QhdIUNkZ9R5EMhOaFFrXgnOikPpxDi1adcOThihl1k5qbh0g3yew+93bqu7u22O0MmHKkyHVFlYIcl5NzczAEtRhGgMJ/
# DATA Cp77t6zGmmFtNWDJB5DPN4eTt4EcnGgyo4KnIc4S+udQZg38i+rUqLsKGN+iR3CjRkoCJHUESWcol9iAkhf75FFviLo42UCDa28q
# DATA 9AJ4STALsaUiTEMDPEgQaiy1IQAcSF5NgmDBfKh9oWDjPRbyZayQCmhNK2BAflLAliCC1noqO1VMjr5hjKLZkAXB9emk/aSwVMKl
# DATA KLtj0TPTLCaqrBBnob7UeEbt12qiVnoRtzGuITilQYjC/pOlpfL+k+XD/SevH4oPPzxscso0LFsUd9CVpeaCPQheGOh3wfP0RtB4
# DATA Grb1OmJNAKNPTIQKiu/496xZbJRXblXdNjgL4SplmRcVLfgy92FOQ37H59NKtbjcjfy7qg7DSfIC2zEeyyU0tf5Ur979MnuDOjzP
# DATA 2Kj2DUPdKUwPK+lNVUzvo3+nI9mK5w4VO/tJaS9G/YijrfSEjY4RJp29P7lIyBMMpzwl6FYdsVlvkqsmrNyQbQB8wzNZPB+yYmii
# DATA udjNHIs6Arn94JDmKq1N6frvAVYrMXXBufXbeFuXj2neGjhv1aY3TaOeAnRHKfB2j6cnBVVpAytsZtYtmENhJo8oJlONonOG6kQt
# DATA WKp6XT7cteJMYH00KYLlRfnMdXvxqN8+DdoYUdeG3AzBtaWAwQauVVz/g2ySNbwCE6lshahqkLI+PBIEKg+SDZgryNuEZH0jWJY/
# DATA rImpB77TjwYFmldfBg8k3d0JZtSwynLiOiZ/vGBjE25ap2jcIf62vLTkeYcIgDp3Hcssmq24XYqNY9HYMvoxpd+QzLLqZ6FOpVG/
# DATA PYohxQmulnjJosqC0c6hIIf4mBoieegxEKG3J3h8FRMjgIjwE+jIjqQuo135yDzuk0fKmWDnnb4gBUseMpwspbJYEAsxfonw0R8e
# DATA MdNnTwc+cyFnKqQq8mTklFwFU14kc0Lmja7cGKDjvULwEtXpWnIkY5sv/RrLgGa6GRV+f9j1q1ff29navP++1Klaytb6T9fuZypb
# DATA EwgFShQDPpnMkll1GasqD0G50Hm4JVjRZ+5S6cWrEFyRDLtUj60Eo+T3q3+h4HEP4IAsYyXQTUNFEDPS6UMK48Ou6wdlcCmtWj3s
# DATA clx/ki5bSN0FugDx3QriPCY6CJQvRyTtFMIGyAiUV28yPsQTPHzt/fJrJ+XXunuvvVN97UH1td2/Ccm1r3J0Qmc8ihFN9Eqgewik
# DATA zIJv1BR5SYQqojacTg7Lb0A0Kow8roXs5iFlEO6T9DxKDovRmJjSImN/2kSTiypXt7frm+suKaY6WKnpBo0q9bTqOsCnzH/IENRk
# DATA G5K44ko5DXm0lGcH/VjMW7O4gUOYJCDuwZUpm8IMJkZ55yS6VYKVyW2ROsU4OamckBngdztTvEHgJ4vPMr/KnhpTnKUZkkoTY3To
# DATA 7qYtPlfE2a17OGhUHm6uviumYfXu/XqYyoJlX5JLM8v0tbNu7gJJ9/r7JmLa53M0HEtYEQx6slf5RPAAhkBCv0HAzKByHr9Bxwml
# DATA stva2N2p3yvISiTWRmoUS45Z1DeA6aDTpouGWT9DfViKLdsoR72Po+gDKdAk3i/b7ztDBPVUTdYDt42CXdpDo6kGnOwRUzAwvqgw
# DATA HOS4zZqgP+K/YEyeoNNb4QB5dmOFLiyqRKMKxcZCautyERCAqRC4fnM9DB6WzuozehMNunyTgUmGbLOFcViGf8CoAdEgaF5nUPrg
# DATA J/X38aeQPM/1PB9ER73BIKWiu/V7G5u5qwL0AuoTHPkI6KFrB+Ub/kieFkIu+JH+VT5z6JUnKmzs1NdX1/bq64HRhyaewaJEg+sF
# DATA bKciqy/E9UfwqFhjWll7nn+VgFDJe6xl0KLba4PymMjr97wKAHV9MnMv14KnskXK3FlSnJHzssqvnlR7LOZQFkKDp8pH8tIPWmVo
# DATA CnMnyh8rR/3hQSG8LpUajeqdW6AvwkKqlLflWEgoibdvrmjoMGoSxE9uPEObgCAutioB30mwOsPMiu/QlccQ4/FY9/A7Y77BjYTM
# DATA GlhFw3i9WSxe+UUZ5kKfQYY03ouypsR7IPkSJl/qeHqRIyrt1Ek9rzKOIcbnmPQG02jBE+hipLBO5/852ad5OyK0VKTNCjBnuBcJ
# DATA bve3+/H1wlvV6AkYx/bjG8W3CgwJ02oa6DHN60VRsAaFK9eLP7CzVoOxpvKgWPXrfDRnJe7zIdDJY0HqHyJf+ZClvA91YOSHgLH0
# DATA 1gfR6YdwZIKSDGKWP4zb/cmH3RihA2AwjeUmtryRMstyi1Hhlabh8YYpuvev7Ydh0fuq6DgoRLCGYvCXteBWNTVAyeGp9I67pxKC
# DATA ZGLDUDWIIjIEbUbhKfUf0Z/wE/zE3N3DF4gN4AHkdP0MMSNr4mlJIr3Qjd7Yi3TewB/lU09tlYxDqCljUPgYlyr8wlu9k2KhPZ0c
# DATA iy3+c1QlCkJpVGtNIq4DQQDR+EOxkL1OEWhsfxcwacbh/rJRt3moui2E3IaorHFN8Ky39g8s4hTPd+trO/W9D7dXd3ff29pZ/xDT
# DATA vXzIx2brLXFufigKrNc39zZW73+4ur1Bz1Yf7r2ztbPxN6uQFqnoVsqNqcEUG3+7P94fNG+E4XwDmC1UNPbj/d3m9bdEq7NEmQ9/
# DATA UAxLqcJBVjf2D6LTvzIGaUJApX0/CG0ayKq/ALA84vUm/xV13KiUm9eri4swdfHij6vNG1X61Lzx48Qc/ji790+WD/YbjaXyW83r
# DATA jaC8KP774/L/Ja1FifckpFfnuD1udyDAGoF51Dexn7AkKEjNhxAfMQlBbhNMSr+Nm+nmSkA+jtYPr9SC5ZXXs0RWJdCt83Ux4Jyd
# DATA MUV9t+MJIblXgr3jSClsLdUdaSrBc4Sw2tGtogIwfCwP2lpqefMTV2H5kTL3Tkg3DG8A5IjsLDySn8/4ctsHxN5JSzmitNhPpaAt
# DATA 8DtkBA9OphPwPg7u4yuIQV+Cfg4EO5pgh8F7gpwExNf2hIDng0n7yDC9j4Zxj6/KOtqTRJ6d+oPN1TVIObVT397a3djb2nmf8gJP
# DATA JiftwaJCvSmr7rr2s1RsNEHni853oE3VnXxG8Z36/frqbl1Fe0qzHjutFLTiKZSJmMRJVzkSUsn0AFxqF7HFxae64bNF6Rm0SGvx
# DATA lnLraKHrRu2p66V/ZjjBE05ZXHsarnbgHAK1CDhwQEAK4KM+GnS5+Rso0ZYgc7uot7zGBsIqCOTlDjwLPTG64UNBheXVI86LrZfA
# DATA vEeEZ/Sm4fjJ3jsF5eRhpMwAIWwcxaPhII4SN1B+TjLRyu077EkCV0y11nD8ieJgFdclLrWAOPM2mglUbBKVcQyr3LqAenkZihFb
# DATA AceI1TCqR/sIlVqakgtOq6IEH/3sK+KQ+aP9ruDp8j/AJ9tHTrTm2G6zO24fgq2lF2N9mFozUWgkTnSZmtoqeZmBc14HGAt4oVth
# DATA X/yMGZIsSeJNNWUlTIHIPyvWpIgjF/8W3xLTY9Y8YxDv1nd2hdSglG9jvHdPpoJ1F07aI0BU5fok6Dlk8tIoSYPTArwEdLp86/Vb
# DATA b9y8c+t1smTAU3ESYZWX6QvPHXXpRlBYKhXFPijcCsq4O6heHTZrudNUMy02/muX16cbNeHjFEBh1vhxgDBuZ8DOvW3tYsSVlqi6
# DATA uaZhdw8SETJVsfxv7F4Lkd9PNPk3r9kWTzjWwdPKnhRzUSoopZGfP3y4sc6voniBH3PurL9+WN/dS+9XLB6NTDeUloyYPxGnjvzG
# DATA SW4VFHB1hvcbO0B4nMAWDNxt8d02kYkxZ+me8ivEH27urr5db22v7r0TWj3KZ9eUhRNWzaRXn54zRUl6sgxoVnqG2mMXDUuXTwfE
# DATA MohEVVVCNZVryTQaUp8bS01H6UfBomiWM9ODqzeKxNdXt7dbdJVCsdqH8QWezrWARsLwWaY+SSlqrLEZIRSgh7BVrn+rW63BFeIQ
# DATA ED6f3rl1JjUNrGFIDkkqAhAml/IAGQCyzEaoNOhdb65kEtGDjd3djc17cgL4VAYtBWC+nrQ7lUH0mKtT8L+lgL1uS9L9uhIft4Xk
# DATA gdJYt3cEol/R4zuWTvclIb6T0rVKzZ85KN6yIqCpgrlxi4k8BrxChtQXmwiC7GKskMEbEnAQ3AMxVFuvHDivIOoYO7ILTsKYgIXw
# DATA 0bA/PYnAEbhhuQgq78gGvk6qKPwEyZuoxt6hV7lSMLYAlmTmTHmc4IGUkRA0EV2/Eg7YwGLy1q4UKEk3btlZeZBXw6KQSlaaxaah
# DATA 6VHbUKze6QguXuFBb2BCPBIgHDObogZ8rCabZPfqFsQJiN+BVZ0t+LwXTC8DOCoasiNNX/SmRe/cVOvB1sPNPWj47fsba3ueZGhc
# DATA vWO4w9WTei/Zqo/S7aNFIgIbDcgpQb276SWt8lOkJVBPeRF2EPv0VUkuBZ92dBEUq9LrIhwBO1lW0Zw7b94nXjpOGC4rCULUxPLX
# DATA syTgKwDuRt0WH6R4MHSnJ6O4IO3RxVRUCw7YLszAfAUlgbjiA2FDruKgQPwF9QbSrVOiW7hYuA4gRRLwNu6BYsLEuFUBMBz8EpTv
# DATA oundGBpFV/jGhY4gFBGLL5mzAz+hjiPRKQDvgKaHgzJ7JuwP+BnC0tpwvPmxLnykqyMvFgMO2Chx8Lm7tInUkRpbIAmVUSL8CEME
# DATA yX5dYWiE5fJg+Fh84N7MXdOYZiq1BnkpQIAUIcGCTn5yygKjIbkYGiAAwAXMsz5wrFOV91TwQjzU3pR0BzGd7W4wAewYOlajtjiy
# DATA cbqVDihVxFSJB9IPzow0BJaoKWXTFxIwJbYmteVhVDouQ0uPJthrpmAmn/GMi3MgMuXGLHGNO3ZzJfhRzRaAasGtpR/eUZjlx9qm
# DATA wLpRwjHeHyPEDuqDwD0/bBb/jOQmmbIhKSMpH03USFVVTHar1RM7ttUSXegfkm3ZjFgWDyvpZKeK6CuOfsO856jmUOTCtpKO8MY9
# DATA wqzTPfeMytqPIu53QjVhTUtWffyuE5+gQ9ZJX9pN9hkN2jW3167FnfPJO97uPRnaxdCzIASAlzZFOLHhP1B2cyolWKvsjR9+wiK8
# DATA za291samuIjfB28w3bRUE1HNjZC/e2A6EiX0tIBDFxOMVFOCG4B5H54dL6Zw58CZ3pdxSl4wcWKJchI+AJkxYlfg6STtA4FcFqm/
# DATA dUO2xJSEGaDESf3GiIOBUhRxobrsrdyC9CNQPJ/rll/d4U5q6m4rhNAUjg+Xxg1z8U8+T8XLXgCnY9mrwHRsuSGqTWr4Imq6Rl+W
# DATA 5FbXQJ5O5Gylj4kjjGqLlt81JMQhxwKownFkcp084B+AxeVbG6i6IcR1DOnyrxCvkqjTjgPCMEcxZ9MIL2Ay4JEueEb8UVDW75qB
# DATA BEugeHx9ZSklTgXe4bg3bLEm4yfZF6MmKHSvvrPzcHvP4kyqyzgyUQvBjgsJqqr6AUjhZmIBk/DEUMykBjxcde9Ae9gRqGZCB2B8
# DATA doCkv2sqYMoyLo44OIXW/Mw4rpLh1cxEO8ftQZJ7os4YCQCRPciEAArjdocwcbwcRv6IOlODcaYFc2XJddvr4CBw9+Hu+wn/z1Nf
# DATA IBV5DyeHWQHEy2MhvvV+Hpk7kMZd9C2Gr5Z1/JPm0pk+EMPVmXw6yUfZ3PQtcjak5SDOrGhJHXLznmw6VFUFF8v7hURZMq4cQmY/
# DATA Gre7UY6zPZ3DI8PxcioxNFRCmPNPAxUSxfBxq9uLEbfMglpKDARCCGU/kV1Ag0RaJ+2BqK5LNi8k1pnj2F69V2892Li3gy4mOJyN
# DATA HYsnpO4B+JqyA+inl0r/7E2e++ScvXkMdaAvhjslPid59tYyzl7vy5pl4sGtvqZ7dc0tcjgMQrY/e2CXOLDsCpxT60cZp9Zc65//
# DATA xFCObK78RQcFBNRRmL1eh6rJeozFrWphW+vr9KyYsYjGnLh6N3tPeiK2nfwaqRSbokohLMZMpELWqZUR5g3AAA0AQxOa48iSsv1a
# DATA SPGeAjHUqi2qUP3A6EsP2k9ACQY0AAVc9Ry+dBeUP6iUS22PQergVNFiX4mlU8iUFY25fXjQ64aS0YpHIDqo88TSLlmOHj5iK1wS
# DATA q8oivBmCmbgu7uy1VAQRy0u1ZKjTgt/dU50sOUV1T8FxWOabT7n59Oads30u6IvqmoOEU7a4NWAn0EQGQwFArS0swCJbssIlBYQr
# DATA vxHOxZovfYg5h3KxOuOCmTzG8twdyeifADEA/QgzvTQR1HoM7oGOWkrGtBVyUmnRrbDVGUcc/YQSyWxmSdF5iISiA/6M/QK5bdgN
# DATA Md+GSFK33S9gKX4W0FDXoCajOonvRY9AkhphiJtG7t2aOX365FJw38YSGqJG0X/tu2LRVc2+ll/lHOi+NH1yyJVIvC8k+V75PeKF
# DATA xDff4aHEsBfhyeQY5YlwVWnjCbC1sXZ/Q48tmX6VTlypqkRcG/AJDZsZq4n+EFwxrWVavbgnTeWC+tz0n4SObHSdkr74ZYJTcCiA
# DATA Cer2BjXjzfX6u5sP79/HX0AukPuP8k2prz4R4vXlpSW/DJ6xrde2Hmzfr+/hyW9v7Xz0oKFlpDyhM6XPGUd1OQmnd2gyQT85cYA8
# DATA wQTMniIZLi8+SxHkUoIV7vet7Trvd6/AwZzJAPVoevCAcuwxy9oyTegzM9Xqfuwfz0UrBWQEdYN3ltzENZgPoEXaTR4nqevt/ZME
# DATA Xk/o3Fmcsiuxp6aNSQ1rM4y9vZjR0e3LCnShqXfS7aKRMQnBebxKN2gxSXCAz9MVYlBAtwIN0NOP2qKHAGd2MB4+jiE5MWstAHoG
# DATA KGAS9U8rfm6Zpg5JvfCn/5jLypIuuFnk4bHEiOkylr6a6UZi7SKGrWfvlBxaZNDmy21TMwi1mN0mDhmtiPbplMzjNB2POfIQ3tFm
# DATA wTlDRItp1Xp1ydevc87LsP1IDB7dHKrqJXYtZ+ca1SXtdsMFkxdZhWsmCrkgbIaMRZNyZpr9OvLeA8mm3FA5MjDfT1Ab2ZkxkWOr
# DATA VegNBpEvKBefY5wowx2Qq7R0tHZtuIwDioDlpSQIuQWY44LkwITe8MgtXtHdRdjW/XRwtkVrBcSUgrkh4cL4ffNuMVMr5hXYZR4y
# DATA aFiIWhtbKVome/4yTzdrmi2q83QqebvhtXyCPgNYVym43vIHuOqm5u4xt38f75fWgaa09NLXIXn3pl9a6MpfMm7iOpYCHU1KqVfz
# DATA y2udU9Qus9ir35A9S5draSheSJ95SUt7VgdTOzcLXfBSA1COTbTq4M4jV9tl2PmaAveJzfp79R2noVeDrUGkMHVR0PjZUAy03Qd+
# DATA HE8PD3udHjp2QVyfjFGEEC3QOsCstMUF7rgXI6hNIhTdBOoyOR6jKyg8SgmzUM3Pw5jYLZiuBrhAGSiXxWoZn3DtzdQQ8BdH9spG
# DATA +Mp5Z0ipN0Pprjxf6cLkU6RL11etbXf9WZn1+Md0KUV8qiTy3ajf01TdCZW83wGmlKqGn6mz/25U86ZW/s9FBZ9Lxr1KhfwM5yUI
# DATA OLcKzaWGzyTgq1K+G3r3y2jcXb112on+wn5nubDJM3TWvcHh0KeZ57DSLLhwHYlECEC564iP59Rzw++mCcGnXZ9BcsUrUZxjL1h7
# DATA PpuEr1hx3vLb6A21JlHZUTWnOg41TVrFzlMWdYn5slode2OfSugGBqRfM2baf35TlJqbNdoAEdja2uN4HIuL6hIsiP3V1l3rnDRx
# DATA CDCIubWx+fZW622xwbk+oOxiajyJp4L65t7O+2YNSNiOA5ezTHSmwyLpHA4Lc93/7f1p52AwiE+P3MwVcf5vOnEP5fb59OJXmJfr
# DATA I/hqeTCk3ItkSsBaBsxELsUzKbeFAAD9K8uwdEdXripvYkRhDaIK84T8zNRYIy2zuho/+87aH6apqjXIgDYlIv2klEbP9K6GCWgQ
# DATA L1AbxI+EpNyh6XV/5WCeI0Xr4bV3ZWIavUxP1cezKie2eSorPFMhHuIV/s2/gc/2B9dUCEB6P3xZpY2DKTGg4Ef6KuRttziXq4/c
# DATA mHBB2qmvrr8fztOVua5ll7ieWQ72TAVqcTSrfKWmV++Sjk4mSIOndWRTiSgbEArUL7NuRpdu/tXgLmmVoT1KsYu4+CftU7huYcal
# DATA djCIADd+RFlidJ6lysJM7ayiZ57Qmp+upIpGlpJkoIRdrC6dDb4k7vzPmhlbOdYgq1wVcnVCnrnPz7+++HVAJ6nsNaWDycd39Q3m
# DATA oC0kq5JxdBlWTAnw6OfGpnHwu2LLqfTsblfYQv5ln4ugGZuj9WBj98Hq3to74YusMidWgkX+1/PfJbOlfoGZUiGd3i8phWA4Y1Fn
# DATA XtfymDxniXqO2TVbyPNXnarzoXY92U6STj/ZqYiKM6t3s+c4+R+MNDquw+bsdDrZ/gV+y4CdaARC4swcRd5en6WIy5cw7GRqo16q
# DATA EfxVREnjqwdhyEAQYYAa9m5wcEoxpqNhbzCpBNtiEiCQONhGRcviIJrAJdtTKysbIDp1WML7jWgj6AxHkNdMKTq7vfbRYBhPeh1Q
# DATA YU6GdL50ZFr0S5nsU+zxLRPCPr8a1NgOM01fl+ZFCfIn32ZumXA49KGUK7w+had9k8rYZNKyhauk5wQto+KaFgUD8Hff392rP2ht
# DATA r679BDKmSM8mcRHcfrgXZo3UmzfV2ANrePJs29tg0CUCcIz0r9/Oagnnf1bGVuOYkglb+dbrVVhdSr3HE+cGvDmJ0C/nH5JLgoLr
# DATA lFS8n/RiMQlHNvhPQqWUWlrlgBn0nuwi/mLBzHFZ2TumlIhHD3pPNgYlKwFmBV9CXkWvyvQACAzQmuCrsamcAW0gWHt4x7kuLuI0
# DATA GFA0eClod7u83+PpSPQKI0HUi0XPO4DewrfTwu2ETdJTt4KPEn0vYMw994WmhPOHFvxpRYtm3gFihyeiTlENqzoT5lVrExIiwah/
# DATA KmPJxBYoIYaY89bBsHtq42pgIXXj9NgjokG3JXEFC1AqrRCBKRbCNYLQLAMghsyIKQEVPUpKTwUWxGIJIRYRbSHM2/T9aHA0kRI3
# DATA GLNg3K6/Kb6u3459o3+MhmkSMbAOa8qPcfHS6M8MjM8mKhMOQItnhNuQB3neZ4pGWAEQTdvjqMVoAdgbHi3jI5igxASRIP5zFwGJ
# DATA 8eaDLRTTLbt47iHl3Vq6CQKWNG+Fb2/t3N1YX69vhmc5VLzydiGzkYKP5r36Hnnb4i+kZoZ8sSRHhNn2cN2xFcA0o3ljXzh/iGyO
# DATA 9ikdQQyCTyFcBCU3hfYvpvrZZvVGabGharLCOnU2r7anR1FqRyU6Y0p/6M2mhHdazMYFJ/xEuB2uvLwIsvQ5xeYR/Zw+LV1+Gong
# DATA OJp3/t5QKPkLtm65I1MU7KVo3xN5nLNn21u7L9q1PnJkRWEGE2pBAsck5240M0mM6yNsaRXmafG2vXF7EB9G43IdDjeKFWT1G78t
# DATA KKPSiwVz7E20am4p+BHcWgq6DKosbZDcKyNmxvk0EBBp9fDcQdhPpy/FTHcMQ4SFmiUiHM7PhPFCXwEXCMQ7wbh4xiXbiR71UL1w
# DATA 9l1vWR9hYk9fkDhx8y22OxRP+V+TKldu3/kvRJSwYh4MBx0a9jJoU3Nqjv+HDjVkX5okRluxQvKR7lczP9mvXOpsSCVyEgu/J+//
# DATA DORtq3G/I8I2aTphm7kKOk6Xqa3LwS3rcgCmu7e3Hm6uu5eDl6oWtTr0Q/LgUQog2E6mbynpe26JcypLjaTHdAldkruOxlx0hy0h
# DATA DwI8nHXHNH8HnuAvQGoV6ZhDy5T0modSChHQeEVB9SEJG8/9WIDOyz5rp/s7fi3MDltmTMHdrbWf1E0qN+uzPEbR48ZUPk2kAopc
# DATA dEpSDUOY61io6q1WAl3fMR0TWFGFf1qHQ0wWhAlWe+APz8k1gY5aLZBiWq1QZj0ex+jIIfYffq6sjo+mAGO4jb+oTFtgIW0JGajT
# DATA ahWNNyE/WavNrxS0iyM6b26jBpyBhvGbuJ8NR5NF5bIpLTfeysyTtnM8BGTjGoEco3ionSYdZAOESZdBp2IqyhIJE8vK0JJm5jBk
# DATA HGRmIVKeF99M+73fPoj6Gb+jmS27CfAGTa8A1aYZvzN6b0YJxqXkTnAwK5fFP1Ba6p8gVBUP02jaYxvrkosuuYtuvvUncBffmVK+
# DATA G3Irob2tYKshVwjQik6qIBqq2KGwOg5oIc28gW+ReQM/ignjT7g6/BlXgj/jrEt0dH+7REEmziQA77tNcfATfuaZ5m88q9mNJKjT
# DATA gnSzIVzdpnM1wDtCV4vYmrquYgUdVuW0ZVdm7rGMGjX+BD7Er72uXhsfKj3ppd2qigt/8f2/7/99/+/7f9//+/7fVf/73+6PrL4A
# DATA UA8A
# END_REMNACUST_HELPERS_V1
REMNACUST_INSTALLER_PAYLOAD_V1
if [[ $EUID == 0 ]]; then
    bash "$directory/installer.sh" "$@"
else
    sudo bash "$directory/installer.sh" "$@"
fi
