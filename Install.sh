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
HELPER_BUNDLE_SHA256='b120adbea13575121df2ca092ad0ff77d2a1965d89f9af74acf71e7e4967af8e'
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
# DATA sg3yZEs63sa2v9FstlphI6xvBd1Rf6vR7uKFbI2o3mn3t1phvxXXW0G7GfSGjXjU6AbDfqM9jIfRVifqwJuNxgbmP26Q03hDXdSz
# DATA IfcpbpibezaomiL80Gr1e32VM7lh4Gj3thq9UQTUEAyjoB5Go24rGsb1rR4A1mzAW1thp9OCcUf1Xrs3bMW9etzoxsOg1R0FUWdD
# DATA 3X5D/eqrTotA6G21CgDoxnEjaAVBHA6j/rA37AdRvxdHw26zuRU2up1hI4raQaPRbTQaWMoqiJptQM0orIfdftSPXADsu/aKYOh3
# DATA ep0CIOLesNduB00Ypd8bbsWjTtDthltBM261Q5hw1G52WsPRcBQFYX+rX4+CLVijra2gPWy1G1vDHBAFBb+KgGn0YA8WoSTqd+qN
# DATA uNscjmBRWr32sBt1426r0261R3jJUlQPRvUm4Ky11QBENEeAqzhqNFqtXjwKQxcaZj+DIV2xuQ6SRqeQOrZaQBlb9VY7jrrNoNMZ
# DATA 9urtqN9oAZqa3aARNvutUa/Z7Q+73SBqdWLATLvZbUdbvV5jK4xaLiR0z91AhPAaSNpbnSKU1DuNFsy+WW/2g61+GMDeCbox7Jpu
# DATA D5akM4q3ttpdwE9z2ARQw3Y8rEdhN96qw3YCKhkWAJKtgWCrW0giURjXw2FzqzMKR0HY6gedsN7vAi30+sN6vdcdNhrxcBR2us2o
# DATA Xg/69T6Qaljv9YbDXm+rE+Y2CqjKAAIdFy2GAuba7RWA0WlGnXDUAsobbfU67WjY7zZbva12FDb63U5zFMadrWGrD+vTA5INgHsE
# DATA YTesR00g32anU8+DMf/ZMJiuo4p2o90sgAFAGLWGw2HQ7UDX9S3A/qjZ7sHgjfqo3R71O2HcC3r13tbWaDQabgVbza1ev91vwYrV
# DATA m92mCwPdvjcCLecG7Oh12Kg3G/UCSIZRI9yCZe71O3HUCTpbva1+t98a9mHYfgh/gHwbIdBIPxj1YAOFcatRb4QRkCtIwM5WASQZ
# DATA WF3roGgV79chTLrfD2DJgP57YRdm3Yu79WGn1WzFW/B7q9MfAgttNoaA0LAfwLJ1Ou1OM2xHsLd6a6AYhMDMxunlGmiA0rYKKbXR
# DATA HY62Rp1OXA+ieAh47/X7Q+CbUSusB91heytudDrAQ4ZRHUh1K+53e+16N+gMh40wiBs5EiGFfyBJmcnidt2+bXeKGEi0FTWAMYQN
# DATA +B/szzZszXbcaQejuNvp1TtxIwLeOtpqdOJeFEZRs9GPt9r1Rr/VazbirSgHizKN12zcNnDpQuYOsPXDcAv660U9IJAYOEgdGHsc
# DATA gygNgZcHzXocNKNGfQvkXg9YWTTcam31g34DNpgLA1cvHZA8X4eLRhGVwG5od4CNbYVhpxUD2QJrb9RjEOywM+rtdjjshL3RVrPb
# DATA GdXjZr0/avVj4OutsIc30eV5qW12rRN2bVjdQqbeRCEbw8Bh0G3B5FtAs+0oAFbZ60bxVgf2bRfke7vbDrZaIOy6wPniZhTBS2Gj
# DATA sx6QgbnHcg1qgCkULdFWvRHACvT7jWDYbjeafeC2jajTgB+2OsOwARgBEgUlqD5q9MIgHNW7YRdUkCbwd6Tie0CKUjSx15EMbNGi
# DATA HdTeqncAHfEwBPrtRiCGm41g1AJGEsIm7gLatrr1LkAHkrrbAMaHUMftRq9Zh310z1KZAobreG6r3ilSkxoAKTD1UaPejoM2EGa7
# DATA h7INOFsf/lsHLtuOeqMA1Ju41wiidh/EQB+WMxwBvobB8B6QZvcIQ9Q5ihhvM4hB0DaawNuGwzhud2Bluq1RY1gf1rvd+lYzaG/B
# DATA 5/4W8JV6t96KtkbDYWcLFIlGd6uTl8eL8Vph3O53i9hKY6sHRAHyFmTrsNHsANmEYdiKIxgGJE846oMGCQQyakfNOBjC1oeWLZDI
# DATA w26918rRy3J0M7hcBvNoHacFcihS00YgX1uwZTshbKKgMer0QeUJgm4jbICiNBp1R2E/2gKomu0GKHTAgMJO2O+Ast/u1PM4YCfR
# DATA JqzFep2gAxp4kXIEDGzYijowVhiMwqgRdIBjNEed5lYAzKPVDQArzWEIbB4UA6CjYQyqWi9qgJDsR7FicJ4As8E3OyEx0tdrvniX
# DATA qLDWrIFE3fDuvO/94d8H2f9GAf83uP+7C9pZ3v4HVeQP9v+/bf3fz7BWRDD11aGLuSS8SflfLB2UTCZL0jiqfjoaUY00pic/TPEe
# DATA wfvq/vL1nOpbPJ9PU/Xl8mfJTH3Gi27GyVB9TdLfvTjw1XKRjHV94GCOfgr9NZ7M7O9cMhjzE052987w1osih1nJe358fLZ/gskZ
# DATA pW+m3/dP9l8c7e69Oj0bfLF/+HL/5HTwZeMbaLZ/9IzafN+HT4N1rXaP9r44PqEbzclViyfE5sON8qeTyp9zy8Fnr46eHe4PTr/Y
# DATA BTa7U7JvASn9YKPiPT843D/FdJRSfoOXOM9TVFX8Zrsl8k7zot8cNcG+vLhkLDZ8RxuydHvkWH3KyRLd0rK9lQvftrycgXJ67gqE
# DATA M2vk9TrgylOtjhFaChwl+LtjHdOELAnNd1quGCV6QmLAOd8tUwp/Fz8ZftQeq1LFe7H7k8HJ7ldYWr7rFtGgR7jg8KyZe5Q7WRaV
# DATA cbFVXUOszB3FIcBRdipiSGSInqsrToZ8uUmVCFyXqZPbSqxO5V3ZtjU54ksNMKNaXZYr74v0HryO1W3L297aonQlqjWl/lP+dHvT
# DATA Ov2A389rmxf2T5WPK5+WVIz03jMOcn+BMC+BShdnwnz9Ad6QEKvrPCRRE8M+C7o6slzaVIdoKPdilPARscVyBpsXa4xjaAUjvFJ6
# DATA EesRJRmgA+s5cuWYcoPrFFW8+6oPqLObBhpVurNW0l0768gw4J00CR8dm9uv4K2/iOthmo7LplP41ZqJLpUNpEKbTtDJEmHHJjB+
# DATA rFaRd2iIKU1l5pEV/0d+477FeKZv5pPlGKXpIp6bM0rCa7HoyNQJs9HXqrT35Ty5TFUGz5c95La1eBpx9g6w5QdzjA/M7UxFEKqF
# DATA InGYTOXh+fYmnurB/i8YJHxeVEIZwSrjQzurCEXGs92zXb8kFRTtjYEP93b3vtj3bTlAG0R9bzXvaC9gv5XKY07Wv5rGb2Z8b4gz
# DATA S1+uKjLrgfNikaUr5TARUGbhvWv9Qi5kNDqGjBVMQ1AgXH7EyznHy8NnZWZD/ifMj4Q+FcQOjcrbOQgtUq6c12VJysON0kblvHGh
# DATA 2SIVh9LsTie03DMACBToplhMbxC89RJw524bP8NwVXtXmTrJgaqeMgneJJPlZEcxecMhHyy4mT9avor/LxjbdNoBK4ZhTspyHMyp
# DATA poM5428dOkdq5AHSGax7CYiv4gcZNouDiRmLrsDbkZ/pFEJZZgJ9NhzaIeEAXEGePwJeqnW2SFN/jJk2LpXkZZ2+boHrZJTngXXJ
# DATA Ag6PP8DorWav238MrqSjlfFlxtY5N+xZH3eORUzinnhbYiuW7tAWYVPFKv4mDFfStTru6LpSePVcvXXx4L56Nc2Wsxllo6odpeAu
# DATA Vf71JSxDp2Zy8e1lbTFUjnarRnOQ9UFDstCiC8fdai/cMWPdKdljlZ6ip6rylOw3XFtSuPWpQi6Joo52yjeksfvBzMsVtqJKFc9N
# DATA lVMqAJ/KWUkbK0Yirp45Ibp5AWsMP81u/xI0/MpfitL5l6xxfgMqZ0WOjj5CHDrYRaCoZs6KrLWwyMUqNBIRZaS2yObQO4CcS7wD
# DATA HqYL7MFUj/lQuFXOrAs3JieVuWOGBXOyMzl3uFBw1f0f+k4jpAPFsD8QDiyUZ3ZDtpy4wzs6IBOAqtuBFCZWwiP4GNPWOi6KW8GS
# DATA RVwpXhLKgK1VpSyZlE105OBbXP1tFmF0el5XZ+LTOrrIGZ0tlwM8b4vNHrlsTNIeV6v02GeAHA6vt/GdsjTkvrqyKIk0CbtykbBv
# DATA pxdd8ZetFpIUWKfIVTOIP3OLvIJAzYv41f18wHW4IJ4chuBHKRdRw31QckSMsJqPdrTA0Zi4/zzzqrbHF4uvYT1Oz6ssSF9+aYtj
# DATA as1HVior9ebl/kuE3KV3C7krbYorRa0neXU14wTvKwXcWRedriF+fd3eCtkA+zLnOWTq9xCZKR6tXypIvl3pADeR9QpsAuWLqrLG
# DATA UqnaG9RqSqNX8sUxpBSigWFN/TNzpFtWEvfoxx/LzBUM2zjG3ery63OILujO8TtJmeb0elrsskUraq0r+faqClwXQRWtfzKMoyin
# DATA 9VtKdc5ulDPjOdsxX4HvHiOyCvor2Ai2RSfGMA4akYOvxPdcorl13tu+KDAIHSOQtsF6k89RjtQwolzIV2T+3XXFVdcLHYW7Aunz
# DATA s0RO4rOntjbstsUqkiGrmlytfF2yD9CBW/sc/oPHl2nfp8Of7iRp7TNc54PjMvddKbQcgKRyhoNyfeUNB9HcHyHz9t1pZitiT6mA
# DATA cmaZZiGuYTZ0CiaBw/Ppgp3SfJvNIMnANrBMEMPkClIVB4GK5cfyChuUB6Qrth7iamcwBxBXt/lFzHKOCO6URCR3X+hy4GdgNkql
# DATA X/1iTUr3ai+jeaJEL2MPa4w8KZlxarryyDff5H9+nAcCrxlfIVHBYyl/0gWFizXChYXy+A356mlm3KTClKVu6LgZaLNuR7SqWTor
# DATA Kz5XWcfd9WsOm1dXNa0+1yrVNIrnRTIlDEBI2dXwHhIp6XIxW9K5AUOYlQdomN9RpHuzhnILZYCccHxIFOS9WtNRygeNCJizYH4A
# DATA v5RX9TlsSPRW5Y8IofqIEQt/x9EWqj4IgnYb/hQdy8HsflpyfL9qI8iVLhbf1pyOfysTI0OrbB5nWZnxhhuYVG6sqEBQ7dR1RW0R
# DATA GiwodNU2XNSH7LMHXXfUy4daNfSSn7PHBMxPOBLFnkMqiIKNazJ15frSLrb8myLijJjCG3kZlecJ0Pebbfovcu16/UJ1w/YLPcAj
# DATA UMH0MkbvuC3JqviCW0/SkubQkYICg2hKT+P65RzlEjuF2tt7aZ23WjuqlWlnblnQBSu0h/KJ/lRDBwIX2GD9paLZCcXuxP5x3i4V
# DATA aHCKTHIGjHanoL6re/py/+T04PhIDcyVPWrsE32Mq096lUJiHM1QvxWYFVou5ow6y5r7IBPOxQTfHfQYI+4xrNB2E9tPFYngzdpU
# DATA aUOdZ3KqgK5ZYIdwiAxNWRVn1b9rTJHDSRAj6/dYMrHtXe2KxIQa443cVp3m3ZLba01dt+axLjQs+HhbWulAM3Gx9bYd3n53rwBy
# DATA XF+Vuztr45Wt2x5wklV6B0OM6l4nZD/TxU5TX+queJ6UQ15xAaj1f6SL33IX6J61t9+ySfjUtmUAWc/uZx0V5zWCU90ISa3VFmF/
# DATA gciOAbNFlmLKZ2N4lfgW1vAnRd6Wsak612h6hPlLN7JxmaN52UBl3fFGceZv3tTrHOkybdbUAXqkCDQn1dTFSbpfNoHvufpLNCWw
# DATA jzsdOd2nDFzTDSDOWnfvocI4KyfATeOikM7a+ouPRsNlPI3VZTde7tbVVZ+DPkh9r7tBlZ90PQ3qDKA+92cfBiw4A8gluF6CihXP
# DATA r7nQVhRgRkhkAV3zpVKcT4kjGezSW7nqhuph5nqTJCXcYU99yWGgKxgAXtB1YalGVERzYXKYDInUCsoX5de6bPsE768fJ/reelKI
# DATA MdcoIA5D5cBUEhJSJn7GsPwoebNTqomBt4lRkGS+Y22gynrK+h2dObrmuIFT5JHDhBTffsx72onTbrvtdVNT7V9tuXtLJ6SZPnuv
# DATA eigu2iG0KaSJdk+MHwpvaqYnNcpMU06jt/Sttr//k4NT2BLyDUT4/ouXZ1/f3VNiZeXJ9/3dKd21ZAW/8fqm2XI4TrIr2gYZynqz
# DATA B9T9oldJVtDdbJ6GYKXgYXwqH7KALRMvgSnwlX6+Ci6pxA4s/iBpekWz/12Y0f0MCShFHXcv4E1cD4VwX3RB9L8uqyqsj4GT13S4
# DATA vkCC0yyPJvNEbq8w96h8ZHMS63eFXP0m0rNTWcZs/0fjXHwoyrsHpIEsVDLtCirBcHJkbT5ZzGNrM9m+Blf1WOvJECKhDe+87nhw
# DATA 7TQlekGH68G0rPxeCg+kM0VrdukAtA6onhrGCEpVrXc9UDAgX8Pg3saEpUe3luDvo5sjTX0YPLwgq80fKG2gqhloRFK1CEKgIUuy
# DATA tnTdAVGjx8WvMs6tdx1jfqUTu+ABlyxQWi81lTQhy0DTVQ9YX+UvlkbMILFaXHm4EAbT5v8iZwzyqbffff5/o9Fp9lby/xvdP+T/
# DATA fxf/NjY2TmKsUOVnyxldWBNHVmVkzuGWWtYBOgUwITSCxiEqG6Pl2L6b9p50f0rX/4Ak/eVQ9Bn9y63+iD5XzzvZf3l8enB2fHJA
# DATA me58IElKwKC/4fIqnNeS9Mk4XSzApH9iLrDVZWJWfspf27S+j9XKMk5/BY/zfY9T0MCKoMo/KLjFhTvjMjf3z1VVwln9JT8M/Q49
# DATA 33l84yIh1cLn1WIxy7afPLkEXWQ5RK+4Hu4kN4k7Z7IGzEd1wXDceQcvdj/H+oO5cxDiR9o+r29uBZsjTv6peM/2d58dHhxhDjzF
# DATA cFWgZZZmCVVT0rcmmOy/0h+XnGvlVqLB5rJryZf+4xIFf1Uh9HyruTTb1s0UGLDDgvEAS3KXeUthOnm6oIyL1ZtedAkf614jeg3B
# DATA 5fetcIJO08YoED7kgpEHEd/UmI87KLxa0QfTBamhVo98dwHD+cBNOM6Nq2ULkBNYhLPgMjMVRD9Zef6MrGnTxFu9R9F645HXM6Tz
# DATA Swp8mWslatyJXGRp1R6+Qe/pOUxBirWN3PsGudijTUtUo85mQed6EVcKsqKvXS5vcLpwlHvejjwDc+ejbEWr88qFvaAAeL7Y8uUl
# DATA FX2TkRJ2SueBt2ZJB7l4M5h7Fu9y/hSSEWg6oFlKVhOORFcGW7Pyg3GWMrWTBZqJSwx+T4Iszmq5XnevU7AHg+w19vyMig+i54Y7
# DATA wLNn9B505P8UM5T59wg7jscjt7PiFSycGyfQu/iQpwXYuygorqUqWFobB1Pr8SRMEi5qKObQ3YxXPlcqtmdsrGN/irK219wAWrj2
# DATA Rbd+roXn3Hy5cKNp/JI6wkNoL3+MSnCVxPSAVeFcbh9qvXzrQ6uOcGqG69xKrn/dJCldm6QwXYwTlK1LcFRXP9zx63lH7hmXtlQu
# DATA A2J6op2CphFElEQDyj1o75G5S4YcHzuW1lCbL6flcyloiUX6cHoXVU4BE6duGMwWeAG0TJd/xEiJ+sig7ExA3W/VqwbwipOFokbM
# DATA FhG0pjyc9uMTcYTqYUlgjeEZOqjiKNNzHieTZOHmZloZ5vmxASRrBXlJ3Day6kPk+2Abce6ounmP79viS0ad0Kw048ismc5tEo8j
# DATA PgqFtxHAm9v8Psd8ZSysRThgqaVM+oTK1wvplVSdxYALK+pC5k6KlFpqlkUrl89dztMl3Z+gZgZD2Ff+qRf13dkyNpiOmPeYv0Dm
# DATA 7dsa0d4dJhZ/TJ274Dgront3LzwsW6UXucanlNV9HcczAQ4vPwBmqvYN/WbpMvlNhJht1ldw4aBYEac1pGVbS0Jj5h5VIL+z9YIT
# DATA N7wvk1v3xwzwwfyEl3IfgVVVXXWBnCRhH6F9W2x+5Tj1U5Udt9OhNSzrL/F175G209BRSBepRnhQj/WpiWj5pYp1gbrm5AgAruv2
# DATA g5BHObA1KaoBDE3q3l3OTOl2RccNC2TQSu/j4t2mKp0ugHOGub3nMjxrSDrMhzb7fSxO56mJMYlzH6bLKVmajidSGjh6b8HGNsNb
# DATA WjAfNsb75kAQ3oNS3sxr8al0jB3JKRo5+nDV0QmnH6zYK79xflf/aEdv+u2ikpwnWmYKioDx4OaJttcLR/bE7oDdjKw/ns9db+8Q
# DATA 2r2+NxzpmgEFXPzBS9C/72vxNoL3EWWbGJFgWyaKxzHatE+Bp/hUhLeq2OEMiJBSB6V2vavrrazufEJ1ePXSVHI6Gy/pJzt+43FB
# DATA SkuPONUfi8KWsjysppg1kVmH6XLM1+ehE358qxTbZLFucbi/UWkPFxVAfiuw39neGW0qCzE81dWD6dZ0xWBzlFKqfBvX+gcX4bVN
# DATA og8p6MuyB+OafBXTjrJc17RHVmuV52UF2Hpd2ZAP+LKVpHbL4opLWN3VRl9IZv+v5xzWRRp+j2M8UP+l2Wu0XP9vvdfp/aH+63fl
# DATA //1Soqo6H1A4h1zkxU5Xsf1RYQELnRncff7eXN2We92/Vf8l2GEvweR+s8YbbPl+pV6LXX+CDzqT2ipnudjrsJMvQ2ElRvO9a6Tp
# DATA 3n+QmRKTrpbT1+R7WwBPHAeTYRRsO0cULGuvgjUy8hFahkgpgtSfe+SInxdUyFAhbw5VLYJL4EcZ2D5K+ZHLm2k+JkpmpbNbWj41
# DATA eKIKs/BlIKuK/hgWt/A9zR832Umxvgsrm1Wu1uQkQ64IQCcInMdCefwc5nifOvnuv7z7Jdf2VoW8/wH+/Pb9z9//9bt/FsrcfPeb
# DATA d3+PV9i/+ycsBK4reQj8mXXQL3cFtVz+aZ+pM8/kfOojyszfPTgDqjUuM6DS41iA/DcPzIASp0k7fRuclyit+2LbD4hIAyRQJg2e
# DATA E382FwkFshR0BSffJLSc4QKDcmCu6rOEoORETy3EraYHzRJ0vCHNnDM+3HvKcRT+mZwRgjvHh8kBW4JNnwanC2WSqZ0Fnc7tlnij
# DATA Q7KwGsoPD54FfPd/KbxyPXfC+m/e/w2RFFZyh09Y/v3931BN+Pf/CR7/I5Wf/2d46V/4yGBBAX0hFgtEOoaAlgAwN3WnLBNQMIm6
# DATA bSScYD6BD3cPwvxfsPD8b5DI3/09UA3C8hsui49l6YFSrML0WO/+3T/DVH4O3/92LbxEMgBh1UQWCPbzHNwXxRlhct3ZyAosvdWj
# DATA 3G2+hU18twn2yPLN5lvs8K4GnLt2+bNSLh1rplwYo3uCWFbP228ZSl3470INxsOUVqwYEzagi/NoCdTJJOshGxPO+d7HZFna3AgW
# DATA ApbhV+/+5f3fFeziX5QqReeu1ty5/kh0/LFEw0p8NXv+RLyZnr5wkx0YHzo1ZrS/ePeP8OWX7//axz/4AcgMZncvz3r8sRcXYlMF
# DATA AG9LK64AoGKBazuhjyoS9sGzhi31dz7ttV/TRPl2CP4Z5v7zd/8C//eLR6z1/2DvbbvjSK4zQX3Gr0hSc5yV7KoCwLeWiixq0CS6
# DATA GxYJcABQ3S0QrklUJYASC1WlyiqCEIRzZMtej4+1Y8/sfpjdc2ZnfXa/7jlyW7Lbklo6Z38B+Rfml2zcl4i4ERmZVQDZLc9aGk8T
# DATA lRkZ73HvjfvyXCTFmNwF6Tf2jVwyNa+xN0pw9cTzELCWnhNN37tu7RfqACwz+8yXe6PTIVD0ZTwSy4XDgJ/TzBxMRqfqStTRn3Rm
# DATA kwGTU+rCe+aUiK9IOqFyevaBwOA8lwVkL0aIkSP+ggnxT17/o/r7P73+MlIz/EtMP/ILzAICO/E3r7+IPupPP54d+AHc5XpKMQaK
# DATA cUVErkQiOGCRPXqNCA4aTO3GjVtXOi+8GWAAP6nYJCwCaoFEh6uoNe1Oi2Kfk9AHSF7S8iW+CplxSeS3Mk6tFfwoMMr/hgzxF7xI
# DATA lFOFc6BEaqHojKgzE2Gtih5GVKsbSqG7uydFr33fiEqsqV3CmfbgN6fA5QMGCd9qBXloT8tC+zh2LTmBcMIbF1nDvrMe5zdu4Esn
# DATA KoY7YqQSzMCKgod5pwURLx5G9l0VJtYbw6Fr6Z0XPJLQBG7JlrtBNbAFWrQ4O1SN/mEKyBtjgKZxyq2oXmrxqdqCbkIXxTfOCAiF
# DATA gSbPebHP+UHNZ6OcyQVKA3Hl3vrbogij6Ks8Mw6tINlMFQcpDvYjpfz5qcAmw1HNcQdwpE4ekyN3LlQL6N0K1RSl0sCo/zP2+k/V
# DATA QP4GxAcl3xVFT/Xoc0VWfop86AtvSkB8VV+9+UtxFOGhczVCemNgF/uHZx2Ok2WgMbln+oGrtRjVIigmOx+vNVShEN0TgvfnaiWJ
# DATA tCsiH5cFLlMH40lLyY/vOMwerRfoczE7qZ1QrLvJzCrKfauMF5Tv4tefBwevxg1r9R9QrvhNBJm2gGSqB799/c9CbgAalTt2zgUD
# DATA +lk0d3QqNREZX2SV4GjezzvpQT4azKbsjB43m+gehW8B6DIvieXXPLRmIAQwLEDgBGhQgcUFMHWhQSFS7Q41Xyx+/g63/8+i4MT+
# DATA Mg6OS48gX6hp4G2fAxOD/GPqKP0VZECj43SpxrFF0Fl7Me5gnyMnihA0QWx0El6eVhZn9NejSXGXFz7WsA1BP4TymVdEw6lojnCr
# DATA yzrm5Bp3tHjudOmiHigHEEbfXUwV2mOSQ9ez/f1LHD4kMEZOAWr4C2AOr/8BDpqgoIbmfgk3GjyWWoQpvdAQg0PqWIYzIQZm02kX
# DATA 1lRWFFzXknquvrx8n/lzNep/IAb75n9Sf38xZ6UtpJPoskTR0E6V4lbgqV91iJhUcwquou9q89f4v8Cywp1MLeufk2aGDu0VuA2O
# DATA TcpQQu9pQ5SJObrsk23KNf4X7L2Sh34zejhQElu/a42goMHO0YWO2mIme886Q/ScUkamZ/UwibqDweiUdID+xNX1VJrb/r7xSWXX
# DATA 1dX9C8eWr/tuT6R5hBsOvRX4osAtL+DOhFkZ/wFP2z/B6So7elpQA0+IttPyUmFdzn0Rmtwp1hzhU0kJo9y828pZQsdDo5/qM3QR
# DATA XtY8fZn1aqTcd1f0+vXrD6FHuDbqnM/SAVL6Ht9T2Et+qG0b0+MUNBYc3UaOi5a6gvHE5QkGfIpzvVo8oqIsgMdfOymUQ73oYTBK
# DATA 0Y8rsF6sVFF4/QepwrhPwbS/15bQSJVSh0bpwh/o52EFTiLg33pLJYPNRypP3T9iLlTQSKojt4CCqkxguQxAVCkrKvUPATORWHGw
# DATA FbhSTLEee1qsuFEB8+QnjndbtLjfMUtNEcdK09bca91EJUEtPhiMDigRAl19SjxgiEEuCDvlzcRlGWd7HuN0ZZUCOBZXuhQWMGHT
# DATA ajHOsAZ+cGlR7fcipvkCC93f/SEwM7B2SxMjT27NlYMol0MucxTnCCiXEE6+3gze5HvjRNFqzSOeFFRgklaRENscP7wY+ey7DK+d
# DATA pkfVPkPGILpYfVbHHv8+cpG76raqktoPbrFhoapz0cLaN/SqadB1wC99T9rmwCYRGmdaJNf/gKog03bQL1mrecWSEf4fhA6bZ4V8
# DATA 7NwrOCqmU60wOIqfQr2gVA8nYyeHPoFIxGr9iur8HO38W24H7ZDrtqeV5f7EafVkYN5Cbp/+zOjTW2QunhoRP4TdZShSgff6dRMN
# DATA KK2ZRXFykuwPmwczQG0pqT7PSuvRNzV/ZswVVk9MoepQPnsNYVOXgIbkHVoCKMLsFdvEE1XsKW0UQEXC75M53rvEjHbOcnWjWX+l
# DATA 7nerV/Q5dLIZ/T78/5S4+P4tz/9vdeX2H/K/f23+f7uTdJjToVQXWsqBpRgZxP/kHOMA2oRsom6wNthb0SmQnEezKZVFXBFVBHzG
# DATA 00G+eOq37mh89vZJ3fpHqvPm1zSdLh5JrlO9TQYgchPyjPsM3JjBMov94Wc4osiWQzVLHf6aDfFvN4UcHGTKyzJUjHIKgVVw2PEW
# DATA 3UFdmpK1LBoMw8YoUq2HSinbxKi8bGdAevAPM7YBT2A4d1tkpv9E0QAdq6C4N6yOkiW7oLyKnhjyQDKvpYNWJ7IW9frp0XCkBOsu
# DATA 6TyU7IywM9NRlB+PTs1GQSKHGwWl2Rn3hALIcMew7Vt9TJYnfFWPRmPanU5MIgM44hRSji95l9FJcFz1A33Ttu6fTco0ZF5Wosz5
# DATA s7GIVgG8Rf6UvUf+GQx5bqoTPTLKhjA3eU+xB/+3uiz8M2jYCg2hCRDcVFy3tmBaH51OSMMd2Zhltz9mmuCIIaJkp6DHuPl2va60
# DATA j1n7KLhVkD77S9/tQl3HXv/Oda6APhuoWHUDm3ZSBLCQXsN8IExePrnJbPK+DmzOmnUfrkc2toFxjsUEkWuG+hghzdNpc6ez8WTr
# DATA 0XqNkI6nHXhnfWah4B9FKyPFFsuh6cGpjb9WpAVu3iO822bq1yI75n/HW+rP1TyqKyndO3+FPja/BR3S78C+DMuirqG/VjNbuJP/
# DATA 5s1Pyf4Ot+9/Ij9ENNj/+s1/jF0gyA7PNV9VebYdJ4sYHsUtux8BDpRiQVoRwT/HqFfln9GPYXpWVzFB40t11wK1Ls+GeoBXTIKb
# DATA 0E/Vbz8JSLhfLatLVROad9UR6HOnUK4bTiEe3APInoFORbjKZuoJantrXD4Mhc1ZBWCPHI5Ara6JTs4kriA/YkOuApH3087jze+6
# DATA +8noTk2R7fWPikXM20cb2xVvd7YeevWXalwXJ5Cw7ZAq/Rw23a/kliQbudiUYUfCiv4R9ZKP6FS9/z4ZOEoPzyUG9ndqv5Ny5+9x
# DATA SL+M3vw5ETVwya0ekDpO6P39j+y/qycCPlKUDu3NoED6FXjwqkfk8lYTDdxdUQKE18oXEeTvME4e6Xg8OOu41I7+gbgsvMg77FRf
# DATA UrBIqyRvCMoRI9AhjXKyNFD5PTrH+3V4vtXZfrS1+fgzdVbxl9pe6w93t7bNg82tD7ceP976hMFU5SWUz4cqdoinw7bpWBlrzpkX
# DATA Rx01kaZTTCL265F+QtRh39nhRYKsLV6mIiZJoiIiSuE0U5eluV+QlyC6+vya3Q1gVwABZl8nIL1UXMgQjlstrmhYe1Ggd6FZhSkn
# DATA bD771g5XTwAhOGBb5NHvz8dSEFdRVd4dKOnSaZljeMyVgv0VheYDBNpOvydB3AvRBUW9mthNZFikdMCkesl63AzX7cykjfaGNtIh
# DATA unN5K8wYGgzPrC2ty6jvIytCXUvrZJ6oKppQSiUbTeGCkptPCoPMAQ66xmMAANqAz4gj0QVHQY5VTm+ZCXu9Uh0OdUuMZKlQtXpV
# DATA qFs9k5U7i6nPnKc6XUCi+c+KQv49SoDoOqjbhs+1wFjcJYmU7+yNwx8jzrPtpJ1ptsNCNA1MTWEOTQgRlKBNNRtqrNdebChQ5kUg
# DATA kTHF/FxEnlNCGVKJL8kaESnGBDaEX5MDtTWbIFdB1/1/QAdD9CVE0RtjSYoic516WAdnWP4rBpRmkrvwyV4M+oIdfmjcUhlzuXOs
# DATA roX6FmfiaYFUuFxHeGpzYTX3SUEGxnf4UN2zAfeC7930EVrRWsuUg4aeUNCR9qSHi497U1QVNKGLaH9U005drGiXv5mpWdBWavg9
# DATA Vpfl09GkZ36rm8T8lftbG0/xp1J54pq6kHF8CSuqxIE/Iw94YhA/QY7wmwgXUgkiHLcEovqbv0ST0z+XX0ANyJhVWdRq0HeM1dPL
# DATA VOfhwV6Av344ywDpFf48nKRHJzaNigMuVLYUjFekcdJUAfZK0VgxGCDZyYYva6CS5eTdEqDmRXbGT03Voai0dKo6D5Fpk/hPat9p
# DATA Za9gRfai59P995LvwD6woTaqRo6egdc32s0b/yaWZBTSZWeg5K5xrYQSBFJU84lHV+EFAdZBkgBTnkJGo04Lug80pG22oq7scJAe
# DATA 5W2sssKewPXDPzoTsk6EjNlV3is2wK8cqF31OU/4eDJ6dUbqb+qHc0jr0Yv+sNeOu2mvdxZbvYuZ29p37l8TaUWbjf3EnVyqjua3
# DATA 9p1CWbZwgq4RPJpQHmVZ09CQmp/AfTgaIlqa/nDJRcMCCWI2tMswDK0DD4+XwEz+hnQK073Sf6FjO9T8QCQccjG1eMvArFHo41F/
# DATA 6Pi860PHOwQm5ST5k9rz/Aai30/QfPs8fy+p7f3JPbVXa/eSAnSk8Iag8XAyQ/xHnSVcAJo6enQTMffo71v7tONCFiQliiE3XBEO
# DATA q0MJyOLnNsd9KJBiACQBfCoI76EIGEj2eMp0RyTgmw6iojh13BfVGbzNxecxRaJSJfCI/9Y1neuaitlw3OAqwPc4pCAr2RP6PuBw
# DATA MkT+zhNKVeB5O0c9Glblxnpjz98zHhZN3DTQQBI1/IcX3uUW51HjuWG29uLekdkFc0ebyDt1Puf5O2AqcLsEDvELFCB+CbICCglf
# DATA 4jXzF/Tkc5Amfoe+Cp8rieJv1NPfINOZZBAjkREFuScvMXiRgUsMhWqgQsm8efPXcTkYnUm3CYA69UioZQpyGrEkoxi2SjgggG2r
# DATA TzJHUj1mCRMqN7mFCinLC/l9ispRZGVGH4fdk1Xuqbb2ET3VaLIKmcUwF7hOM49NYPOFBFTwV/n559iiE9J4eYpZo/d4//33yxtA
# DATA IPYLuSKq9zqzZq+vI0DMejD1aMm5DqzaUnhWzD2RmZhuaPgSYcfAPo6CZN1m47CJ8GbsA4klSGqGDzmsF4FDq2TKIkSZqXOP/nJg
# DATA XffsXkNtr+0Q3AjwA6318GDFmKkQrhhOMnEwgt30ZBct+WiTCAo//cloiDdimlF1b5hSNu48IBGVhDnwPIGApz43E7+nBXhYEvQF
# DATA E7oXTez4MqNNQrJH/vTrF7FwK8ClRC1nYVmpLyCvQVdsVp59N8RlMSlPHG0A56Dus+4T2w1kbcBC+oRaud67Nge+/Ga0e5wpjptP
# DATA I73r4DSls+nxaNJXp67/MuPAw2F2Cp26x+IsZRMiu9cYAFmno1Ex58ahNk/1h2VdQE3KpH+E+Ktt93jhgggtugnso3WvC7rme4EE
# DATA xg+MFzux11jdJ8BULQSXCdQkeBopWrWouxqUlB3njSCdEXcBW9O5aqZF63bhAhPa5S/fopL8ud3hb/ac8vvolA7V6kMKNgHsFRB0
# DATA xg80D9086AJ9NOaDRCB7imH+QO36BgahWg0JP0YBkKEC+ZE6HF4wqa3EnqA6u7eLMwXNHcZ1Trale6kpDvh6wXHkSafB4J2eBwJj
# DATA jNqOYRg7lggnddffiI3JNSiqx8r+ZvGN2Lria7DBvpKFJuPRgL3B8JlagAbawWfsXugAc0rdi/aKD6Ae7nGCcK2WqEc3hK4FVOP9
# DATA LhqfGR/FfY+OuzuaTGKBfa9NJJ1F8isdwGmskt7uG5URouEZ9/4KKq6h3bQSU7syQXQyLpjQx8CnAk5At7OnPX4PRqNBTWLF8d80
# DATA 6J0prYIhHJxwS882bBUUapB4tyLdPH7WQjcOJc9kY/ijRttI2vJ0aLKx5rkf0Gt/n0+4Cy0zGDvgnEecXwhZAzoJxJAFaPhpsTo1
# DATA daW9wdv6Q18M9KQZ5P2FkwUygJVzFv6ESUKD226enQziYv9qFRVg2sfm9BUcBjJC47jRUdYvkRRyzlZ4OATGUbDWwnQavUEGLipF
# DATA lb3WprnK+zq4o3ROMsUr9QOwpqOMKn8DU+Hf/SGChMpH5KymOMUkO00HA3nLNEo8K72QJ1NNv7E5+c7GGJ4nqzKcAc4I8JAaZUJ1
# DATA CvGtU6uCr7UX11D/H+q+9SuwkL/5S7bz/NK5V5k7k2kLbmWot1OlQJXnYiuAcZ5uWBAH/9fWp8ROsyPqo0E00HXMVWU/MSp40JgC
# DATA udWSC9LuwWjWOxykCNMYH3XhXCcL+sj8gtCLUJkJADkG9eq3aAv7+2j38U7JoNT+H016RhPNJp0FrEZWA6932sJTYr8wMwKQ8/k0
# DATA S9EwAYJ+Lx2oL99uBn5CDhagwv1TuHTDrdwfv/YeMV1y7QbQ5x317ol2Mzf9TML2MhokjH7BAS42Prj+f87q6i+rRvd5USX98zd/
# DATA 4Y8aVfZ49sWJhp81QyfM0tIP/2IbmKOnlFDr9u1bzNNeTdKzYCOS+JBwKX/PaWqDCnNr37LNzVsLNGfamccXEIhz7k4AmV3ScR9b
# DATA AOHFzlbdjukCDUm35i/ffyNTwpu/jtaebtSdxQLYCcah+Hn0qaq54LpgkSfYdYEXMD9OJ6Q9nWOtZWeNkOUVCbEjzwSMZVArWQyx
# DATA JlFK5HzFaCmfofrltbgtSlsJ3FITHFjBxmwFMjuAFvqGkXwyGsBk1IzFyjFK2dET02K8KmuaWsDqbTwIg1O55PnKW9OZmABZ6bMJ
# DATA AoXvxWrseyv7l+tLoTU5y7BWj2iYxbp4JcluB8eDSyau16SaTJcZV8xJ1QAFcaMFcqdlr/jFvjMZ1Z0yPGX+GfwvFu8lrJSttNw2
# DATA o9d/h1T1L9HH5OdgHvwlFqdgOTKLa6si4AV+iZ/Sc+ZKP+eHvzIAOjQlnjylHqK+El7SMsV6FqwQ1jaz4QokhvM6PDkUaFecov8H
# DATA Y+v+TE4NeWAhWo51SSQrqCBFB2n3xWws/BfoAblQ8IlrODCJczL60vecOFrnhgaPLJlE2qpA8daEEjr5OSJMq9YKIBVrSfElVlOn
# DATA nqj/gpMjbf+WlatL0qxfYJIvEJXMT7oMtdT1Vf0YHwPAakv9QZI7YuLRQLhb9CO5EAiuFdKvy76CIpZMhUCg5B3Lr32uXs2tPUcK
# DATA R+hJCnyTFNvWXqju807LQrjQXrdzqugfhsZwre3V7QV/4dUMXn7Icxh7ZoFineKC7FZNy5IdHip2BJrGNrueOBT0WpgKcrKJIn/F
# DATA UZ6bTjssTO/MOJjqTjp9aGAFoW1xVSxqC3olBDqap21RZdncjGr1qrvwQyhG2n/PNrPHKBesswhqusxUJowZzZXrkIJimzrtyiso
# DATA g3uwQfbdashbGs08AZDqZWm8VGNvN5hBlahHHXGYDidZflzTQaem93VfnqlXWAX8tTIh3eRS1SGa1HYv1nq6w1Xi6GDzm24HXgtU
# DATA IQQVXryH9kuwqhK8c3/YzLMp5wOoxZxJgrR5LvAF2vQBfQI/boWzv+NLOkH0LE48sw+WcMw+9I1JCgh+LuQYE5vmHBZaSL+Ne2T5
# DATA ZTpZHvQPLALssmKq8eKuyv+XuVwZhknQrT8jT9S/p/AQE6dufE59jYW6pCtJ47/K2xsJFr/E2HYps3yunZDUf/+jBIzCOdb6ufMY
# DATA lDFAZA76mL4h5tR8xJHsmVSnvZtNIEGgKsPz3yqdGmSFaa8Dmc+1EC6A1UCZPOj/KOt1zHbZ401QvaDVdlhvMMRacAOINH/Lmury
# DATA hnTGXNgvK/tyuIHtdFHdpcD2rhojILGIvbkvsjCC/7CYKKfi4oSaobvnpWQ3K9rlIoLDnZebtOAT/MAgN+BkW09ts4N4Xk0QhP+d
# DATA Tv6Il0v7co8qRLwPXkB9oUJ2IEtyFeoe4ASYLegL/l99HwuMhfgLVAV+CS6b+grwq0qncT7S98jD4reMffkzkujJL7Bkrp3kWq/O
# DATA 7CmYR7/3DBXdD1axd5OARRxLgJm3xNtOHe3TEZhZB1Y9vEa8zp6TUYm5BM1WAtrUchpMKmU29l68wz1wt7hjKXmCg7XA+mKrP8pA
# DATA XUrp5Sv3Oyt9zIfcbFLwgyLcPOwlnYVLxd4YV2BUJv/M2Stw+wMWwD6k4e3l4x85K8f9kt5bqsfiuHAuOSOcqSktvi23R7AAjYXX
# DATA MM4ABWg3pkXW5UsivV7WewobFL8DPuCVIOuV2liuEAql9+ZYBOuRkFr6h5cW4EpWbVu6VTE0jOeApcGW/2dSJXv3dwStxNjJolbg
# DATA y0VY9xeMpuvC2pCu7xcY5wcY6L+1+uXAyEMD9t9oIQA/d0z5UJIttXYFvb1BtWkDoZAwvRdYT+F+4gXZFR1tL2N3xaY9HPfS7r29
# DATA ERaleN7S+Je9l+iDKQWnGjmhNsHCOuemIi5U864rtfAaucYToQso2iJLKkBtgvXyM6NysswAIdQ3HhydxkdCpUm1LuEKqgRvAPOC
# DATA MQrgmuqwbkIvfSfJn3ty8j04eRwIxqfzzX8yrv6gb3eKG4Xe50jdpQ5PK/Z8z01OmIO6xC9Q3pA4mNp7PTSz1q67qPYEZy3gZcyt
# DATA CM/zuetdJ22Y7UO8+MWbu+C7GJmGpDs0uRz1ikIMujOEzwRprAWZozr2HEU3nFVHZ+y4H57HH25vbe521jcfdR5tPVnb2IRbhDQQ
# DATA iJE/Xdtcf2yL6TdWrgEVNuXCFiE46qE3ieSNCHE0kDq12gjgZR2HFjxqrAdd1JezUt2Xa7CX19qLaufdOVNi2rMPOk+fffB446Ge
# DATA Ct0QeoAX40tcNLwqP8u9ITnkmHnZc7VZeIcfoq4NZbrT9GXWCKB7GVfNJYN/FNirgY0jzB7BfcMFdTYxScHaFDIvyV5bGgc982Tb
# DATA GAuTYjeKIpEjM5UKRpfm5LrB0ekw6zkNhjy7pFjmflEPL1dSd5R1+4lYkDkBn1c+SqGDsL90hdPydW7X88CpalWcqQt3qXlXFo7y
# DATA Ew05U7rw4dLgH1xyCnDtyNphoUNFMGpr6e3bmL9QXwWFdVmlab+sk+z9xXaf/T00L+GvBLcSfR9yUuNSS4W7kCYr5Gmre4AO0+yZ
# DATA LaJ0HxlztSBaHtghkXLhqM11XphUhWr/9TqCNhozcNkJJQZvvqB6yMjYjqQtibSBRpqmMtBBdHCqFh/S2XQU+17Sb29ukfWWOmzJ
# DATA zBY8LFvQGOg8py2sWI9tEectVIGVeqRww23d4yv7ARX8vD5384f98l4JKL2JIfLE5tjaVvVuRXmujf8VZo+2o0VWjIA9EOkflALB
# DATA HNL2jSNFcN9sAqmwFU3lTd6uOfROHoZkzrY15KGymR2xr/J2XOeYr1IqawlJYo23zqkq9ZOR1TylLHhslSj2UO3Ch7rKdqERdPPE
# DATA O2ybO+q5zWDT1WOQUbxI3comBamhPzEhUp14Feo+kjX2xg3+1CNbOBPSg0d6addiSEPXPQYr0ziD9ONq9/RfKgKHP5NSd+KASUP9
# DATA 5finLuzo43sikfdBpwxDIgTWQJ8U8QtMRRz9Zn5XBcGZkmTQTK1ao0Qc4HKoX8HY9+kZt13KrxOKTEEHT09jQ7GPHTMk9wrHgHoV
# DATA n1xRRphX0dXEhbLZC93IygQBuYz7No6Ze1nt+W2/9C9uC4z1WnuB/gfCc6lV61BHD1xdG7fqgU4EonZf4D3eM/2LJvSPZCkMmB6W
# DATA ualiV+rWfbqa2D0nuNNaF0PC+fzFqBTdvxk9xkB6QpCc5ZzlmwBU4jwazw7UiKJn248jgimj5CUcD0+wMGqGJ1meNxfTjlCcA2TV
# DATA m2QDSooxZBLAm5fco0qD/fizOSg9pSkHyvS6XK0HKjzsjRVvkfRR7ghdF5qVtL52/cnm2idr31vvkJ5GTR05c4b0H7gsupHEASJR
# DATA lGHBEZVtdR4RYreYvy/t2cNfVjv3FAvte+rwhY5UoBq4lIamtOUCzOg59Cmqn1wV+AZts0uCLIUQlgzLM5WWgC0FCaz5qEh/wrTc
# DATA frBf5NdebchIwPfJRLtzYJTt2DchlQEGBNoAxhwxHY6z/sSGmbJQTLgFr6aMD6I49xnTARvJauoBMwf5XIL5wTxuGOBRJ1YLk+JS
# DATA qFYSmmc91NOJogk2jtHzYJKZqigI0QvWlJHHMmhzbpwiYeBzMIrTFzPIGK8iDP4FfzthU6FiBiaJEPUZojjLeX/o6XcQ+hZYVead
# DATA cqzoq6tXk1y/jVKO0lOqM7cxRSFWfpf4keThsEffqqfNOyZml0T+cmOP0d8IHV3iwo2wGQ0Fb5wQBl0tZigK99EMgDWSvnmQNOs0
# DATA 1XAL57f7odQ+eYgs84YrBMqCE+7YhLB2s4Y6pJNMRrv2snFufhzM+oMeBwmr6wWqVcAcXIEAc6O2Fzd6jMvH00QukFQl+h6hDvQG
# DATA 5SBy4Uu9CSpw27LZCkpvxMTT3llVdKrObsyurdq7uIZK6FYRENLidzdVN2p7AKSdvcq6s2l6MMAg4404iKUN/lYUTI07y7TUHKud
# DATA l2BWXb0OqCFvjMlGiAQKOgNUAnKvoDd3HbHCR7Np+9bKCiuQKTeA6OCO+XPdTQJwGQ8NaaMnDw0ZChi9/lX08e7u052GDtN589Og
# DATA C5ANJPxCY7AQUC87F/0jqlnADenX6iAiUDhe5pguKWkPyJZExmVX9nKkO6JJ5Gi+T7dkOBKDjOYZ6sx6DaiW7svsh54EwUa5Pp2y
# DATA 2/pQr4Hw4X4W2E0B12sLYrkwk1zQgiEZnwjKZe96dFZ+ezZ4NdY2OaEtrtiMJESxaxORVGHQwxxBOA6fU3xAI6LoJAePlb9bNlgH
# DATA mGcmb9KU65ykAVxzyVU1N+QquNLE0b4IWBAX/6JwYTCuu9a8TBUEQIN4GIzqYsFO8wBUBNXbnA3RZemkn8O1qTN64VVX9ClxhQeq
# DATA pi6ggRgNyOuERQmq6/6dEIYtJeAJwPyKgyN9pxIL/Gu7OlcCcWNZ7Pluuyc6IB6RdZ3EISb7ahd2UEm7OGEptIojBnY0p0kRAOCc
# DATA NO2uVsLeuD1ysUmMsm0eHQgKAY48hWG1eArdJiReMw9AqDw59P1FdiZRcC9Jiy20qgj+MfO4SPw6B5Rptbz2I/8ndC4BrvMfHNX8
# DATA V39a7UW+gK3FB1RieLlQW1ygWpWpG7jW9snCom6+hXwMDs4zxvH9bB7SczOSSam1Xw97CQESv3Hcc8wiVz4wjux1GdriIg9jF9ja
# DATA hvpAsiF5hNTPPsUGhiYobDvjtK9ZZMH6gmzOPqwTXhQVdvBv5lkQPH0PSXQ2yUlJPqfyZbcJnFimonQyvk8+h24Noz3fIqHkdO/6
# DATA 3yQvkloSSO/I9v4pa5jP9ZS3vBWoR3IOOLoCObx4nDSFK7v6Qs2pLAkwqbLEReEmsfhh1ykv6e5uIL4Cs+xsVtGIufcHmaLuFcpU
# DATA dSPl2eQMDkNISq49Gqrumr5QhwlAUWwKin8sFmnhD7sWAOGimgqxpcmcqbHyFxn2pNxVdw38l63q7eow0qhbT0Fr4zrOOuLmPuM5
# DATA SnGwvGmfooVKUvWenFkYccUg6BXIwfT/FV9F/NbOJBtkivB6zCo0OK110UZIR4Z30YlaLqMPdjfxEY0ugghzrP00R7RIZlpluHCs
# DATA 4wxBK5Si+qH4JD90MBbcz4z5vRwojmryR2oUXt7E+uWC1VJCLFSgy36WWCzL5sbUgp4T/OMKU+V++naTpet6Z9M1/5xVidtliHIL
# DATA aiMD8oVxg29rX99W8LbMaHQQdoM3YH0ndtRvmJEHjQio/8Xq5B8yaynkfNX64eVs2l3GUsvWfR7LpL10PGX8P8+xPnw/XFDbUJqr
# DATA ylGGmoRVnHIAf9QEe5KRzUZ2YukqeVfzSOoFV9kAxaaxg2scuIEW1ruoCYqTefH2WldUiP5ZnG0sqlsqMDQrFRlpzye5QbkoJPII
# DATA //MFNVeFmjqD9Gw0wwAWh5MXec2CB7LAb0pZe/BCAsuytNhSsFj+gfp+Hf9UpFhcWR1VpXuTNSlmDC1fKMfMW0KOmdxmZQAf9ui1
# DATA gqCd3oKE8Ao9GBADE1JAEkoWcil6NyA9qBf0eqbuJk/0pWQRx0zyNawzssmTdCzvIPMwEROT6Y0S/6Jin8hJaxF9EF8XzbLtez6R
# DATA IX2Ro0dtFbd0qgRNpMa2M/LCl1Qovy2Lu2ZYnA5rDnbFydPg1amT+ITHSEsqUqs44Scud1APavFyOu4vA/jxMkFzxmQLhzZoXyxr
# DATA EKExQD6QX7tIptpEY1eH3ta8d8j3PlYzPlDvzjXQby9Le4xQjVN7MlITMRr2uzVQmK/eJLiW02NAZi4UuG8+b5Wnv6bkf9glym6G
# DATA Xlra8nMH8wAqdqVmLpRtWgS2+SvjCm/Gv6FE2BarVnA2UBMc/uhg1Dtz0Xh1T1ETVoPknJyjE2arHP/Zw06HegVAQOAt7T3dGhze
# DATA qtJ7tiTv2n7+eKSOzxo4GIFhp45BkhV40aR7sWoa1LaBkgwtWz83WXXIeVjnBv0p5Bv9LSFdQDzr7zBa7pegiQsI9t4aMA+SSYKb
# DATA YIerUhMRYjihIyjRd5IVs1Cha5VijKpUBDmF4jx69mzjUdOXCzkVK/pbKTpE7Xc59O72yu2kiiwsvvnCg65t7XDCc5kG3ZkKNQyZ
# DATA FdjahHMbyoJHMh9k2bh2kxllWHWK9s2IIxl/68UnUxizVpbyav7k9T+qv//T6y/ZFAq4kwRZEkqLWwyX/LXJTKHB+Mls+Rbmz2tC
# DATA zpmvX/9fbfj1L9/8FQR9+rkzYHRxQEdb5HTlcpexxn5tglc/HwNGQC2dHOU24xf8AvrK+Z/bWkcde6pn/KxJ9ij809H54hPQStqQ
# DATA oEDFupdxoOOm+uoqzLQ51h7aIAtWAYafBjFzYba21jBRDc0cQu2Z3CeTHDmoTqTeXJsczWD7PMU3NSHftjud3qjb6STiyyZ4Bqb8
# DATA SS02PYvBwWEEfh/tPW0ZMoYhDVsvrffadC9Ggwl3D0cGHSvUoLopAvhdHZGX208p56Di9EqM60nzYvhbK6k43XVyBNZDQm11l5QE
# DATA 1jBSp6130diZ6srhctg4oZ7ZussQdheoC31TkntlZRielotV1abu6voiG0N2T9wzMV3Ap2opPPudDvU6yhp9FM8tPins1tgzLLDV
# DATA wEnEFuwGCJU26AF2P3rkYln8B0rntcShGMORC0ZY8w4akFy9jYEfEsmoxOvmJjMiw870uAjciNMTQODm9iKxTyNqpILY6U5KgMQ+
# DATA +MMyqDp+QndMdwz8mxaBf/DVk3/ZKDF+YNAY5G8KBsbfEtm4iLCOGYG9uU/KSR2FoWnyIUmGJCWCfEhYCFJpHXaH04HDwhybsEdv
# DATA S9MSo8YIXcAoQ1ctVhxbdSXhDMUPt9fXdnU+4u1Hn2z7uYnrlBnJNqMTgx/2sAGZJDc+jfFqAC24AhCOpnkIL2rwnzo/ebz18Lud
# DATA 9U9dsdPlloFwUNolKOH3ZifjXBL+uZtGqyggWXkOnthp3u332+xPCeao4bR9MwEGpBa2g65znQ7u104H9lunE1s/1Lx/NJyd4ILD
# DATA n+mgubPx0e769pN6ZH9//Oyp9NKi5/RPjSowKfludNQ1H137+tOavpw4gg5xRCmX1KQ4amTU72ZnJIoGpHISv3bOFBU+WX/Vnwp7
# DATA rYeLllFlNS0gPWQHdtzn3JInxiU6bO7131lR1VxGjNxacJkIuu/NcdlDlJ6fYF51kH4/14Agv8I0618g5N43FvnfSTr50YE6KuOz
# DATA b3xl/4OE9Xdv38Z/1f+8f2/duv3+Xf2Mn7///t2734hWvvE1/G8GHrKqyW/86/zfN68tz/LJ8kF/uJwNX0bjM8U6hreWrl+/vp2l
# DATA PbXFcXuoa+na0w2CK0L/Zbys5tH0eDKaHR2HYoZU+aaqZYnJuhZd9W8wpcDBgkPam+qn6raKV0b+qW4ux+qOqX8C4dN/j/Il9K+A
# DATA u4cqorkHCJe6yMQ0pgiL/hPa1H/LG6z3zOmrq5wyT2f9HvWBaYTuA96lFGFTF0RFS7sDNaDImBDpwmduU0bCV4Pmq6dJA8y6f8Uo
# DATA T8aQWKXfUy9kzhPytkCex1E11j97SXo0VuczxlBSRXrzaa8/bPbzdDo9qxV9wtwRxE/I7zES8Tyq2kkfvLJJfBwNMb1TSnjFJ/r7
# DATA VuQKf9wlXvom/1ujYSNZppETce0Px7Opfmmmd3O0nZFW2Nckgi5Bv2OFIg+Nwi/oTYeL10BEx8uJYtRj0PCD3HSSH6npV8dBbfk6
# DATA JHdTbcydH2jY1K/++AHmnr8HBwePyyFF16BKByKa7GDWxn3bw06nP+xPOx3uGekjRy/URogdoBKrX6Ubogkvg746/syc31n7BJ6T
# DATA otfgBlwYTZKNRwNzk5vy2k14TVmh6U+dFTroJOfN0TP1LLVzgCLWaDaVqbDrkalb1xyHx9Nua1QH1NTb3puBrt58v7mi/t8qDBYz
# DATA CEMZ+NFqrcYXi/R4OzsZTZnW5foSSw75tLRpRKmJd3Y+jqazIYwMDgOUiGVEzeCwiWuJf+GC0gqarM7LIKriC/cr3ofo7fVp48PR
# DATA 5DSd9LJe4+lkBA52kV1O+Vb9Be/sDFzQ3NmkDgtMEMOFX7gdWki/Lw4oSJj2/MljZ1AZUEMAumJ2foX0b1pQZX9rJzAKE8aIeQGf
# DATA xDFGOIpIxWV23blxQ87jhYM0ahbD3Qtcdi9eo2SPP+LAcNCpfZCpG9sEaZr93M8p6/uWoq6+NBchf1TzDzS7t8LHSBdhWmhNxJUA
# DATA 3yZNLpuEx/GQkhA3dhlO1Z2oV43T01PMudcwrRKesW2xOLOOdRoSbisKDdtqAkGCtVsCsARO6kfru2xAXE0W8ApVG6W4w7bF7oH5
# DATA AUMVbh2YwDb8x5DttiHfDgJIUe2Ptzyxr+k2iQxBm4Fuz7MDudmuXSvMrZvaBiNMMWWWGMB+5YqS6EHkfzvPQOITLxDhdG8gB6m6
# DATA e02OshKnJmbLTnJH6knIZfZSdhHjM0USRNCgUWUYc4+TrNHbX17NQONu3/x2PbqzchP+cwv+c/sCi+kNez+6GW5aWi8UDdEfJKWr
# DATA XwjUnrcwuJmjw7Q/yHot5BiRdha1g0hkrFZgIWpBs0w92qXNGzLSVEze731W1CfDDJWUPDH3wFIGPgInqmg3erq1swu7Ar3r/CA2
# DATA 6Jy63Z2MKaTG2h+KuZprGDx+qDb61EnoplOu96ZNfWNBKDqv6joUgGc/Uq03Z9NuSHtTWlk/H1GCU6qsqXPNx98H1vveykprZcVz
# DATA sKe6mtMfgfI9HKZkmuOyulb6ph3ssJOTvZnmukTNL920fU5sf7mrqtPfF6a04ctsouTQHPxl8x/O0h7IdKNpSskfAR0j7Q9J1W7c
# DATA aOHm57B4zu0ItZDRWIujAl2B7zITNauzwQDBqWuTeG+t8f208aOVxrc7jf3zW/Vbdy9iSqY9V4Z/pkXe3igjZn3Yn6L03rM43xHN
# DATA g7cxJ5n6EINrRM7Xzkk6RgGF7kQgoKw93N343jpq1tXNS92dwE8mfrSxs/bB4/VHKIf1T9R9Eh8/3niysUtPs1djMJ/A0/VPn25s
# DATA 09PRsHNM2YNsFSafj5079tgw4Pm2d3NnZPhiODodar1ApGtaIiSKEwAkVO30MHEyLTp7Iylu3MECBDu2ktS9EvBZZzpJDw/7XV1G
# DATA LutKdL9NTcAf315ZeX/129++eef2+7dXvv3tVX1rwVLYg0CheaPbGKKXZ8S9UHt3BjfY3Cwi+NMenaFsFhhZB3bvtKOL0SDi4Yie
# DATA x0lzNh4rWdhCYun6zA1lc6uzvb6jqK9ay0drn8E/n6yvfxf+fbK1ufsx/PHZ+tq2vKyULVSuWhtNwCcZm49st8hNJp3AocOA+f1C
# DATA j4ALYEPSWmlGb/t5z9Sj0bzxs+gg644gGt8UlMeAcxfRjtuDmdzTW3J/X+5W+xg7ZHa31cn7jW9tdj7eevwI6j/LI30G7qGh6yUd
# DATA V+BrPVbkmhsc5GHKTi0dsQSKjMiGRlFORlhtCaXx/WwyUgw0HeYRhIXigWUsDUkqmtH6q+N0lqOjeLdLaRdO1O+IGoj4gDedCy5s
# DATA 5gdtv1Fz4NRsrvruIjzPuKcshdHk4yIcSIQLYwpV+ClTsw06Z879SW+Ra3KPeC5W/pJt67mlSY8wNbb++J5FjokOZ9MZLtUQzFB5
# DATA hH6mVq8kr9ehrWqNVtDtij30LAfHHEraogSa6Edqce8peXmqrvXUxZP0LFKtDokXpAMEPYjyMQj8mnakR+h9ueSw4nPLtlrsHKy3
# DATA uE5xbWj7GlxgrZxB54FexZR3wtIgfqwNEDcVsWus3mzcWt29eat159vq/75fwJCIuaePYTU/gDBJ1R6TcOfdjiYcLTOx4CSALGwD
# DATA 6OMwHewAX0csIBBXMWse+DHVkN8nSQHlKhaWK3A5NiNRpJCBKeMQ5yLtc6+TTuOCmLan366hU2Nh7sS3IpdXHzFDbAv8LJbZQmaC
# DATA mLbBI7zGpZKoodb05QAiIHHWRj8go3h+nPZGpxAhmYth2GouQ77HoNnpjgYtcRZY5EKtKyPykPZZphPn75TUhclF6jrGFuIOa7bX
# DATA ZNjHn8/UwoHeqSaGojV9doBP9RMsKYfqFc9zW9RFVdB906yP59OP3/DuC1rhzaX3dC3k5kajTPw8A4HIwmqNtumbVUO6KkeRm8vO
# DATA mtuC7ql7GugaIkNAuI/fQtlG3fapBPy6dXORPj/VfTX6WEdUlWIqB7CoP1FUnWScis0lnXyUaIhwigqmgsJShXu2OYqKW1hqdmX+
# DATA ECH1O8gv5VptK8sKv5+Oeq+JR9JEuEqhTtUweOrPvcbqvr9PKq8Nq3frd2/DvUE1lyyyMDLOmNS4Wt+XRvkxmIlgR5DOeJAdpd2z
# DATA gHMoT2BxeWKsAvcdBkfODorXt7rhbMalDLP18E0MbDPDXtbj0XwzemiWJlJCkdosU1RRaketKHupxnB6nFH9J6i5QQ6cAggUeAGB
# DATA BMMXcrw/EiXqZ4MeSpnOlc0enCJZcSkHUlM9Wssv6yEGVsa59g1RZAhq6pVDkviNnheyIuhtBm6GINXot4iH7d+3cfLx0mrAnYPs
# DATA G/gT1mZfm3plkYLZztatJqd/NER2dJ6rmaWd4Ko2cicXYU5uGwjZZQ5PkIkjOueF3FDA8WwPgx/tI9HS3bJxN5r8dKDRWjruO1dv
# DATA TSbVc63VraH2CQLrIMAAzczLB2cNvXcwHMGhCSCSmTip9DADw5g1E0igE2v6lD7oxkpazOsudElqWdQe7BCPoXGI5JoHcLR0iEmO
# DATA emaUF8G+g5YdSMFLtgyYS8ujR4eHeSbU5Cv1aJW8INxKNcDW3Ln6DtXY1ppD+omAQn+Ewp15Q9W7jA1l3DDoDb4i1My9GH+5Wdqc
# DATA F7i58YtiDAAUtCocRKWBNA+LUVWcfnY+0DCk6jKHhmhcoXukDdQP0wjR+yJ17+6PerEXQgdetQw/use92S+GZBZVTglhpvlmovJ+
# DATA P5qRsSRjUYyaxii+HHHMoA8mb5wXf5gNwX2yFupHco/mQt9d4EfiZ1LEEhhCjEvi9vlACcUvfFboTAh0U1TzIFRLmTpFe/3pYdMa
# DATA Wc4v6r1W6F640nWsgu+goPTOwDjFOg30Yncgttm/qUEt6/D9cx5cS59W3rgt6sOFQzGwiMZFmw09X3aMSyM3yNl0PJuW5bMrsyeT
# DATA N4zpMmoDYA0OwJas6jkYgTcN1BaXJCp2Gld0bTR4qQ1/pizjScj85PUIfZw1cFU98sEm+ofiezko9K0dntXEW8ULoP5kEZWqGpe6
# DATA wUdgJziDi4wzATpoLG92j1WHaoLIiq7xdmqDrwSNn550jLeDlHxFMYcjgf1duNsQ0OzDZzu7nbWnG53dre+ubwJx3daJG9EHiszD
# DATA kUnIplXEbaeqJ2vb3/9gbbPzbGd9e3PtCapftM407SnhSdVgXHpEMjojxoere7q2s/PJ1vYjWZ3+BPokJsc4FfBPwzJAQjM8A/uy
# DATA jEXNsWD1hP5T3ulaprULtsojfwWZAEK3O1QR8QW8+ucYN2sVYEHG1WdRokGfAJSFZc97cd+TNORlBLahlX/abe3TTF90sEIr+FD9
# DATA yXw1MH1O5e2NCs8L1NOTWT4t01djdcUEfe8Wmxj7h6y3k/d/JIDV6mSpzFlY2LMiq2ZT2EZF8OI4PQNDbV2qdl3rS2By+KHVd2pv
# DATA YX0nU3cLuJb5Vl+KjnBXl2Q88aCu+yRk//0CgLKpTMpfGnZNX1p0IVNlsjDvFZQAp5Jgv8jS3+sfHmYI80U3gnvY6EjNGfASJfF6
# DATA 3Bjdyk3yau4KHgue+1hPvnqo/5ThJK3gcAVOtbbjusNwQ++0i3M9AgeOUm9nrA43le2yd8B9gYIyZ2MKpWieb7TbQ6171DYUJtE0
# DATA rfFFKYOWyMmWLdOJiKn3MGn4h3qCGxVzNbb8nXuhlXpgVzpkQaEVnVsh4wKkw7R3ph6qGyzGVM72rusFuU4JjmYaVQGKa90upafo
# DATA KvGEPp3zGSjqFNue5tw8dT+5iGUXUXmDXoFMNigdhqqiZQz/NneN4clU1zwa9nSSqR4cHU+N3VxyRHVfJ+G5GW2j5SOyy+AGrvQm
# DATA Zx0l9PgxCPEjtXrquQmEI8M8kcHi0XFD201QyZkirDBmcuqMH0rXYjTmT4/VIYGufQd3eqQ+ADaH9oUzUFj73XoIG3RQPl6IoRKd
# DATA YekDFPOsHQYV9j4qRXnB9QOaRvxl08EgMgSvu7yoITEAGyjlFWIysX9Pm7EDZLGcrlukw2paa11qAyiGwUtdqbuVJ0GVCA90WC1F
# DATA LlTDtMzdm+HWvhmtWd8ksK8o+XcwUuyWdUyRwSIhD3R0JAacjmG3DzDQiJMdHSgBtTc4oztgM9iQE5L89lMcnmZ97dXci19XMa/y
# DATA o/yQx0vabAj37cP+nmRw/sbmnE9Hdj6C8eyw1Y0VxKZfLo4J1dKX6Lqu2p6ZyspDLnPzWbe+7Ss21M3ssJHsaH7twCuF9l4Jk9QD
# DATA 4DO+H2SXLAsH2KPg3gEGx8pQZnHUVCk33Pl47eaduzvPnuygXwultuIwiGZ+nKqXtbGHbHqcver1j+B4oponQuYxpryI6vfzYUzm
# DATA IJSAUR8vbm5Hg9FBLb7BpD9JXB5KFLnHXIyn6Tpvoev7wOokZ5SFzHMqpt3anDL0EApYruOvxVxGl05QZ03mr3uRmG7UK+XY9Ew9
# DATA Bus7i17Mp5TkR8d01MNDFQejr68UeF0M40V5CBxqYz/6+V6guCA7wW9KWnGvUgu1RJqDRRvAq0sDri46nhs959SkpWra26vqhh5q
# DATA BKW0YkS09P3SukNbmXhd1h0lnjQIjywUyhzqyRmaCUoDn4sf6JtQg29CVV/rQOZgDDPstFXUkrt3QHh0Z2VFyA86HtlOdita/e8/
# DATA +V/ugB8g3TeNTTFwpzOpSjiQdG5A57w4y0veRUQwJroP//HO1uYjhF8uvaoQwbnajcM8NUQG0zaQVInyJehtyEuvKcxcggBg80oa
# DATA BmRPVUWbw6FUs0l57OjqgiGW/6L/56fG+PrjP9+/tbJy043/XF1dvXXrD/Gfv9/4z63TYTQaKmF6iiBGvSw6mqWTXoT2invRiywb
# DATA Y5QTHDDFQxBFAP1SzqwP1Et1IKF4MBIUb3icVkqEcPITQiIwcZnqKA5H+kd/zEnn3j4y9HiQvbI/ZtP+wPyapibW0+Z4MXGk2ckY
# DATA SMXS0i64GEY6zR/oiQnuDWcrXtre2trVmnoCCzXlGogcZ+A4kqVH6x+uPXu829n6ZHN9u8Nfxsuj8dR+FC8929zwasyRKPX437IG
# DATA mhr5KVl6uLW5u731uPN0ewvA89zaZoenyzLDW7Pn1whLNBlBj3c2dtevWktOAvuTtU878Hnng89213fAm9FGuJiX8FzJvjj2zu76
# DATA pzgxcbz3bNif7i89EmKY1dbjnmU1FC7G0hrcJdvDbHo6mrwAxt5kV54eQNlP9AQtfYAeVe0TJYT00fLM5Zb2ODHe/hIwu7a66UFO
# DATA t6X1V1l3B/wF2+Yw8UGKqlZ8GXuliK6GQF0iX0jsJrCYthJWlvY2CMB1f+mTFJjUB2eBjqm50Gux/uHGpzA7e3YmNmEmMEhx/zlk
# DATA WR1AVgn9SHHBA1iK50MpzRK2QY8m0ZSArZ+3Y2EMuwEihpsoCaOvHDRNciJwEznRd8ijOVQLTj1X0U3H4OvZIdmUHlbkyaTW8b8y
# DATA T5OW5nnBnSgQ45JpaEmzP+44JTEVVL87lfYZG3oBN9D+q0GGiC4rEUJr44t+3sH16ab51H08w1yTeNPwbzUSy24t4mJdDo3deAr1
# DATA qPkbZlPpkhM7ZkpK/Q5tJSa5nFpSMPqpStRg8mMEeVGzfjDp99SFsR5hrCg+ba+YUHSCidRTgb9ZNoav0aKEl0jwZDCVJtGPo/Ob
# DATA Ny8c0y6/eRDdva1thnBlqI0TrfzuU/pMIxqP4T9379y5dcfeWamWqhnTOmdgR1jatTDzcKEjqze/pXtS7fPVbIHXV331Djh9HVBq
# DATA 3gPoja5skf48QrLCn2jPzPSkP0DP5P74LgZVxq2YvBAsdmZ/HLt2zsP4nD68iHLYr9E5Fr8AN3IIdWUxnlzL21Et7vcPUQFwjtoA
# DATA uF6RLkFGiopRiSXVA6QsVJFpAmVyfqnzgxs/J1hVu5lCy4uBGbaIWedF5pHolHAdYIKEEzPtjqMeVnluqze9RvwA26rsN5+bQ0U7
# DATA yQejD+frHPn5RXR+vgS+OqqeE4JuVU9wnFisw6ziXnQ4SNWdj4nOvejiYinCtOB8/YBq6DMlLYAm83g00lcTdesYTcDNrrG6oq6q
# DATA YOg/437fU1/pJbw+GF3nx+ppd2rwpGlyepPRWD0/p70CumkxI+fRuV37k3QMV6w6n6jkQvXWVmy/+rd2zObtOU/5hexChs4r/fw4
# DATA 69V1Ot+uNuZTeAWIg6aSk2yaRoPb6A2qCO/Lu41+90SdcfWfl3dpllSPh73GMOsfHR+MJo0cJgU80uXDtAc2TXw2UZOe6ScwHHWo
# DATA 1BSPyT3k5p07l23c0bsMJ1mqFhPzDI5TyHbTmI5GjYP+EbGZhvY/wVzSaq2gL6oB9cGJM7e0RnZvHFJgfsnu0G/n7I8FdsKVV+qc
# DATA acmF7Lz6P5AzDLRjF/SuRk3GzAGYwBJ7b+vQzQJESawodUcJoZvrD3c3tjYpho/9cx3SbStBB6bbBEFjHoIfr+Ksvf4RfCjUCdAZ
# DATA 9JoCtYJbPoQtBXQQkYXBEU8JJzHKcTkIcorDUUrOXejhtKc2HHUUyocTVDs8BU/U8957MSY6DibOdDoLhfRM7JneFpBYy7NOOh6D
# DATA bOvQZNvGeqFnBg6VZF/KNYosH4MOGc2ftiWGJ076arXbzMvg5Q+9CbEr15eutdJOJsGJS9vmlNwA1aAq0m14E0dZwXK2sdGm2uKs
# DATA TjJ0w/q54QxozT5/bmDum3wD4G40qXiTvf28DE7e//QwVpDZkMlvE216qGvjGWPWczBB7EMqtdGL9/daqzf1KmtJjpgxUWkjrRmh
# DATA jvJeI8tSszgwsohwysDJHR5OKX6UIDzwA5rfDB4gn9OSuyvi6pqa1CEMnsdELmXV5rFbkfjQ5+/bBJakbVvpkOQEXPJI1U3V6TOa
# DATA DvNU05DaYdzL0JuwyK6fE0x9qOMonjPfB5EGp8xoSPVwGl387yH+N+ZLjGg/KX5RUZYz+gEbPe0Pe6PTGsBI8N/G434NmUjPjFr1
# DATA kiJ6uoMRBMGhx70a1UPF2w5GKEmBLgYwWSI+8VF3kiqinjfN7eRqKx9csKrqFlrxq626OAlqkjZH0egUPN1J+9QHRy68D4MNVN0Y
# DATA yVNLX6lzxe/6AA8KGJSVk5LjVHhTEhvJJ15sftBbyC5tKCJAhIk+Gx9NUjxLEaVw4jGhAwE4imkAJDrk6CQ0zWnHRjptXFOCN5ft
# DATA xpqLQgnZZCJyNBci7qVF2+cC5YXqVWsBghf00K2bJNwKmVLWlRRPF510jHSnQzFnsWKUc7+F4AMXcZisBRdKNqpm6Wot8hzBn6t3
# DATA TqgPmgpIaG3WK7CnLcCLGj9ijFaqch2WF6Pt7HBG2CkRl9e3y14dVZOjSYoOwlpN2Tx5AarBMVh+29gUuQIj5MJh/1U7buJebIQg
# DATA xj3k08OeRTyFuj3EU2iNxkz6FvPW+PSaDtJMOCUMSoUtY+HFETNtcOacwFFOgV6czNN858sLuU7Ya0vopLSAiMvZLe1VEYH30Bh0
# DATA BaWmXdav+2aseggaGtRkN0+P+0oGjdUzFyFDPSjNuU2DLvh76+e0bQqvOTDQK4Iu4YGvgY7VQLDrzNQYruH1QElimfo1pzxG5P9R
# DATA tDJauXmzan6eDSEUKHr24SeRWC9drww9pIZ0KlhhBlXXRQbi0oWoGz75h6fNnc7Gzvb6RzX9le4rjkY+LBmw/11xjG8xTjriX7VO
# DATA GKVsCkW2U4aeKqDYpcS7/nSTx6MzvTADxiq+etPLzVtWR00HQbv+V+5dTH2Td1PQP+KEoDAY7600vg2avjsXy4pbPQdXAqorqaTA
# DATA MOPcE8zfMRue8OyQo1IeIqSOLsqDRSAuQTVqqsxOoJJ8vBfF3M/Ez/VVU8ea0PuBAc3GOltdaM3Lv4YkLAt8hT5idtLDQHa2WpF2
# DATA 3nL2RdviUH1cdSbii+SncDpY7Fzl6f8KRlA6irBXnLcheE++ozWXOTrYmGfyO5O1gC0FV+KBxjwIPkUno5eZg+R0VQ7FSOEtSwwu
# DATA Z6pgpWfBG0cYKtSvm1+LoQIpKE+Tb7H4/x8HNgN1uJLhFWY91Z2oo9e0iuL/S2PS/jtkXw+Ae12CfYcnaR5TFV5bisUh2JujfXzu
# DATA c/yH1Mxzl+lz4y67f4pLwSaoGvDJtHG41viw2Vrefy/RjL9mGWjtO626/ZV8J/E5qr8q2Mu5c1ScnEqO6+8kTR2wMdCoujh6QJ9I
# DATA hLAfXWszbYE7N1EQsJ2gpyNVc3Nfo0nUwWsWv/BO/+KjOcgGIwjXmo5UR0bTYwz3Qh2HDDFTNBdEuPB6xhZSV13FTeBZgPw6jONG
# DATA bS/A2PbFzKD4tQcZYi2zA/ea2KLKxNMR8sLhWWxYkfpvIlB+0btBHty5zBeHwbyIR+Gm1J7D3T1Oy3AAOtj1K2O8ZtzOOMzOCsuE
# DATA NL6CdDJPuipWXzJVc6UPFzsEPVHkDducC3T1KpyS1tKle+TN8WG8d65m7uKyRImN4OYOgpbuEmNnUHJecCHtZlwoL5re7p64FZhl
# DATA lsAGWTqcjTtjTM5MCMbaQd85u/BOe1k5qecoaJ8USOlBPhrM1PQSEE6zyd4FpPOZ5hVM+1AzJO4RftWCaZ4eXwhkqa7aCJgMG6Gk
# DATA bkwg9ibPKB0eSwxguICf+xUBq4hd2ra1NQce8+Z5hpS3m6Pph+BhGAghKsBEMQAe8vvHm9+tQTuG188h0IUpYCFLzYLp54WEg0IZ
# DATA ywTk25nB0wF6s4ldTNlD0ysWNlZCVian60bc0LGxtWJrGE0nu0ThdU4lZm6+t/tpkoSb9atwZKhHG9vunIYrIdwPr6JaQRpzaoLp
# DATA 0g+QSsHIVuVTFq5cr8EkufS6IueVixNaYT6uMLXeWUUwbzqrBKvidcg5sIUDHuAD4SxW2ADnqNrafPyZn6XK/t78AHJKOfSp4tz4
# DATA QNpVya0mByFdLx9e+AZPLXIW+M9wVEuq5e/SFRdHIQru/EV3RwArc7Ed4RE7gcZvJO8a+ZY4uO3srQBFk4Wbfyh3ooFj93rAC4VX
# DATA ix7GUKjb8vSw8S0LsMybq3vcH/QmvGl4/1VyFsuSJQcpimPcBfYc0M1YXwK9d3I8PhNqH2M8FP92kOKAd8BDBNoqvJVuH9xIAsCn
# DATA xge4LGzQmdVdNZHqYnDmLGseWFczGM1RsWdNN5lpYRLxCzmL9BVftQ9HICPri3nOzDvQ5iQzMAL421lsXcIXD5Qg4yOZo5aCQQNL
# DATA LAuEbXUZo4Lh/tas4OQNcruFRslaaMOBA3t4w/GZcogpursvE75bpsMlV+/e+tZtC0cDnxXEfZ+WQefGaX+SY7r4PATnLpxDGBSu
# DATA rjHAhuibUdyWDA9HVSywEwXmE1l5yREL8RB87SuB+gGknAO4WID0MxjKmZvom/ynRweQY6iDQ++AI1kb/3SOuISHm2IWXYSIW2RX
# DATA iFH4jsfqEW8KNNWT6F+DvycdyEho9yvay83zqmZJ0B+oYaidyB7PedRo4NeUUJahgk4p/Qxoyp3th4dadKJpJePCrrS4SYkzyd4m
# DATA XxLipWNsoE2L3kTY4jb2D5VI8LOwWV0XVK2iwFp0btv9xKDoTdPucYdxj8WIUD0La36V+d2m6rj2yhku7h1uFz3kk7CxJd4jT+r9
# DATA PYuiuVK/e/Mi9rtdve142Pobb9HfwYKTcqWLuAxU7TIZ+mP1B7dKewJFIogGhsIY2a261syP46I0Z3R2DomjGhyqxqLas2HfxEcW
# DATA QC30UnEHdEBqryV1YJScpRRzo0xXIkqhQ6PqMhWVTo4Q66VYVS4jg3UnSCe1eAd1h2rA57F6PCa3InbBzPdaNxE/cC/2YtMO0vz4
# DATA +ZB9d6JGNns+RHQ6h5bCRqRqQEWHGN4gnwBEdtaNYrNZTRkYF5UAzUASSMlLYwlOLIBSwK2mberbu9PS2LLOhkBkLLRIQMQZKw/5
# DATA c1u1ekW0jArBf3UhUGTk/VccIDOeDbvTGcFUdI/TSd6O7/3Rj+8/qCWxVxuYWKZZPgafQWxVVQ91eKWglQyTHWBklXNTBZepGhZj
# DATA mD4cCttJ/FPP3dgHh1csOc990kWZVB84y/ZNxvP9N6jFIEwz+P3vnd+L1g8dHk1A5kohLyEM6D6kVUKlhn5mKqb4CAbv5We5f9Ms
# DATA 3SbeVuGDbkncJXca+wASnzN0Sl0bBvkyv8STwn9b0k3dxlPVVqeK39eZfDkAC7Y54zKwF/shbehnthEj7a9pUjg7PO3oaDZEkTI5
# DATA 30136Sm4Zvk98HuKFjky0SMloL8vN18g/1AyOIzgb8BvBu3QfYZ/G3DdBRJOvVNHbFpaFL0ysawGx9WJC0LTSoMa9jKYRTEiujId
# DATA 99FhDt7ex7e8uVouHCvOBxbbhx1IgyKVDnz6Htgi5ef4Tn4GRXDd8dM9p0Yf6pTKt6ObFcpxM2Z9e3FqTMIVruoFrmCGsM7EeKod
# DATA hj1W42HAkjDjoIHqZsLcxHASYg/gcIGkF1XIZrAJ46g4GJTMnLfQOXXidov6oZ5jJLLJKH86gVmb4CppvogLU7jM44nRIrqU+NJx
# DATA nzxBWl+d8DudQKxLr2MrDwm35tQ6pYPWikKpolzso1yrBftoRkEwRpgwjQO6MzIckdTDVFwMog7jaENCFAJePwo2BADlLOgb4dgP
# DATA xdZIabwo5kaAx9Cfl+Ct9cpdSYeAGofRUYhvgZd13aGYbSdP0bVAp3jKvAAZvbR7bvECMr4U/MktBAGbNTCwifI0vhOOxmKckAu+
# DATA 5yahvxauGbB6tsJ5llSRrAnmOXLG4Kjm5PI4AJM1aopS3elCOiOF6SWqrAMFQVNZ0DvP2cJ6pSyoKBnug4MoG0Mo1xs2S7IhkyTa
# DATA SrwUADuphBt5hKDde7ZDI0JXi5eCddZClcaVxx+5R4lg5m5300cG/uGzLA4RdpNO/CXpzu9t3kq3gFxikwMT+QRdvPOukkm0omWp
# DATA 2Mvw1LmUCYE77oGtlskGOEwMR9728tSLZI3NNdcRXoc6ZP5k9BJgc4zml7C6xAMOynX4vISIqINTjL74jgn7su0qOAWzwR5AX4Hx
# DATA JomjeHGB+m1fjYamP81KN4VpG7YY9bkdSfgEzrrJxaTtuCAO4ZRoacgbbG2eg2CSVMpaHBnIeanY15udRsSOMsPRMgV8t6wz0Pb6
# DATA Akk3LqqwijOk/VO8hfRAQ8RaavGOvyv1WHC4jo69EzsSM094mMauE4+vIXPRJmkaOrb/tbjE/6nE0yCee5E8jC/hjTC3tqK3ghP7
# DATA l5T7+4IDjWFJZsDtwiSE0Bq9PVtY11rB1Yd9OUKePmUOSUmyEO6jt8cfeq5RYpdrVkCzvYzfVW5yozqn8Wrsxdyne4N0WErzNFGs
# DATA C1q3AMFc0pEwfnpFoTYuiILcUKFJx7BirHwg2LIxZTIa91G3BOg4TdCbINZbDX9qGMhmT6YGA7u0EnIKtXJd0sUy7FgIQeRnDccr
# DATA sAFegU2APo7J96Ppon9Kp7+IO2F8VOe5dIDvm/bgK/coYSgXH9aF/6z1xzZXbQNxEQjVQv1Aw8+YuEl/XHBBCaltynxPbG0oY+p+
# DATA gI8MxGZcgzB2MFmP4U/UMlAJkUi3ScF8ybxpwVVQo2Xb2SEvy3l/fNGEmLalYjpyh6Rj8Xp0e+Xbd+WQDWc+jA3i0fOhQTl6OsoZ
# DATA 6Qgj5FVDUeOwGunI7ZcktEU8FH/CFFW76+GiaKcsIPGTiijE2ndaGIj4Y4ZUSCIfRsUGhahVv4iKDGAiEUZu377F4YsRK0yj65Nu
# DATA o5uqKtRwvdoaqvh1h3KDQU7R5pfppJ/iatTmhlCqbcJd5Xm5iNz+VPGsw9ggQGDyKrbvUlrbypGolSp2H3P/duxeglOk70u83fVL
# DATA /6rlkI9YrUvModhAm5Lz1ToahnSKeb9JO2GBzUGgEEAh5h0np4fttrccTjIw2ax7CP1JcJTp/aCHEJ4vyZ2xI05FxSDKvAnRzYop
# DATA 7lEleISK2RMqehpgsOD0cpJOgI+CJzLRD+T2yBfMHmvBzvLVEPmxmuQuxW4fZAaKOr6EEHuoxAVoknhjlaGI+qO2oQ5sHPYL5AsY
# DATA nO8jQOWIFyJSnHA/wVnlnsD7ROSEhc+CgqsvogDkXOQLJ2WGuONsMHYMlY6rg9WY695z+bKLS43euxaSIILj8+FXAOEIxAAKF3bZ
# DATA 9WoQRNUZVF/T4IIVXAIm0aktCR0cXqqSaV7wtkWdXWCNg20KLxZHGi0V8paW/q2HfCmF1MGoa0LCGYHysDucDshwq1522NVQtw/P
# DATA 4qJLjilqsiQVnQ5NGfY8fLi9vrarHQ23H32yPc8JEdTkd7Wa3HV295wGbfu/b49B133zsq6DMGWAba5nTvqZ4To1D3EFpV8lPYf5
# DATA 6qx/aoufgYNQONodAujBBuVMW1iJ0yG3e+1in7seIvpp0PR3hfi8cogPjiLRB0dEzeYtbKkPgTyGyHhXlLqWikI9rozMvAEfSrlL
# DATA XTVM2ANNmaL4FGRTC9lX2pStMQCQeCkvG+3jWeVec2W7zVKFfltoc6R2zZiPlgqv/OvrZVygLqFyZbPZ5kg6lBXVrEUx4551yX/R
# DATA V8S26EXnoK106tWXd7j1+2ucFCet7Dz5Pjr3NMjeXmFoo6Ja2QwBdir1bT8J2rHx47pNVLO4gdDfrD3fgC5TUfjeBtW6Eev2G+JP
# DATA 8zZP9Qaq2CNVE1m5F95yEssnsnwyA70oY/3+riyZbzdsLrdhGUVKvTAC09XIM/cE1Utl0XvDWkxo1N3pAClzP9coVA0l0KFycT5O
# DATA tRDOBOhZHF/loEq9Fzi9NkG3+SI7y2uSQ4Y4RmnwYGCYqWp+2FD3Kkj45DZuA2FUD2rzdHV1r0PBPE02j8vkBNVoS4H0S4wZWJL7
# DATA RmYVayLKur7R1/BXc31za31ztx6ZX7vrT57ufmYerH+6sbNbldConFTSAfAsb7SAitxTJKxxniAULJOyQSf0cikoA68B+peOHpUs
# DATA vG7QDkhHTwzAnnwJW12BLqDmC+TsQgw+Sv8OMEmlBYCKF0LxUZj1XkmZdg4wCUmmNJd+WlWslVLB2myvXiJY49/5sj+a5Z2Au3nw
# DATA kiOj0lGpGi5lJgcVeucGKtQuCga6y8bLDEXC5MRfavcLrNt5ZZ1lcJ1L2rDeLQhIGmm3EvrGqR0UTQVZzfOjcdG2IbmYwUxd0hpM
# DATA hOF0cLrLMbrdlXlLmEcgcGidKNyS61EwFAMo1H7BgoDVuHHd5UBmC+xYgX0wwtCcc4pBxVp9NCEZr2SBgor90/56lK/HmgcLiCJ+
# DATA ZLazh3x9gV9bGEjFqcKPgA7MPW6qTgfmodNxT1XJx84qCXzvczaTtoz5Ls+P6fy09C4TNvZWJMHP3PPWcoehXtuj0hJn5KLQSVLR
# DATA GWXcVXhnsWQ21Jv8qiIE4aZKx9xAIHeB5XprLtht4a7uXmONVhyBH5sYYRSCG+ItV5mwcWHppNryKsLwZRd9CVZOmqY8jMhL0ig/
# DATA KgNc9dXVavh7SEnKB1gpPM5b8AClW3THlXwqsZKcvHCYAu5KyeHwvZdojKBjnexoKMbQoHHf8fgVB0GoAq2/iPk49hp03lEPAv6n
# DATA DfZKpe+Ax8R14fZsfqBSCeMq+lPRiMFx2q/odoMbrSyChKUxJk+eYtK4lcqP1V3M/xQSu4UL94eoxC58UNVAQSFTNlAnAkmneqOy
# DATA oXxvmJlNoxe3zRIUr+HI/SnrNhHqvZs3MQU45+IWEkBZeI8DVQQyZKs8b1m8zdKMl0ck0GW5rSSsOEnGMtgPvxSykCsRFFBC2IXf
# DATA itTFIfl98fa0jJx34uO8nph85hRytkBjcPVxTxcfOtc7v7i8WIh8RN0+OH7B9F2ljmye9mS+BuWdaFECOgy985uOLF0iQhc9sZO3
# DATA dAdz544xl/ZW9r10gY6XMkJMYkvIk1ZMhVYBHN4yup3iKVxwx3pk1OJ2VN6Mwsisvs0H0MMP+68g9ED1uEGLKqA2Xo4A4h/Ucsto
# DATA q5woNp5HaXcyyi2C9sTihhfus1/DHVM3e+kb8JX7BvMhLF2OsWxRa5dj3fJwM6CiMnBkaQdi2KOwBSiwk0gSCDtT7lHgOgibJoS9
# DATA FtrAzBs1DvGhLm6NBhBNaS9D5tChNkXyJ+88mDtrKRNAE/uc4xEmgZdSO/gE0iSaF9SqMljb3Or9kYirPQY5OHSI9WWVZKy1CGXV
# DATA Xo9XTscnK6u244lZgoISh7ccDdW74brOuPVwMEkFJlmwvHWYvNxtF58nc7YcCrjeRhPo36V0XrtfLEi4390mLtX82oPpr0LlIOaj
# DATA l5XNTblf/gKa35LzT7ead33w56ndSjQCJIYX9rQHIIuhAVjEKFP2k0So68rnqWJvoshZdjHzNpbMKlLgE6aKBbI+c6Lnb/zhf/+K
# DATA /4deWnDOv6Lcz3PzP6+urL6/esfL/7xy8/07f8j//HX8z0/KrH/n08vlZ+6CqiUPZms+TnNIxGx+Tk8Gl8zbXI+ezibZU8C/KEnj
# DATA nHWVOJUHUzefmcczdb1QZPHh2u7a462POk/Xdj/WopZVuFuTbGzORkeJXulgdEQ+hOAqpuvQOYtvcsJimbf4ydrmxofrO7s2sTE4
# DATA quIrMKE+XqOnd+kRRo7pVMd3bxfTIkMyBFE7ml03Nj8y36j37gv94d3bgc6ZUo/Wn+I0fGtpZ1f1qLO59gQdOZsmnQkx3KU/3nq2
# DATA vbn2OFCgIXJfcWG81ASqIrfE7fWH6xtPd00BW9NB2n0xG3MlW48fdXZ2n30AmDTx/Wu9EW4y3EAP7sN/o0E6PGpfz4bXH9zH9I4I
# DATA hZJN29cRIk89xSCvBxzDcH+Zft4f6ydw+bEerveXxw/uL2P1EKGw8Wh9c3fjw431bQp/6Y5Oxn2QFBDaSOMaIazR7fcvnn9fbY2P
# DATA 1z8NlD1ETOy7t6nM7tZ31zdLS926SaXWP91d39zZ2NrcQRCLJvQKI1a6eU4ZPemf/OUR/jt9NeXHKBjHzVdc/jQ7UEe1f6iErfhC
# DATA 7f7uIM3zaEdNNl2Y7d3Z6LVzHSLVKcKo+RBqc+HTqqHTWDlpehM/evb08cZD2Ih/vLO12fnu+meODScMlOaCpHHfYSYIkbEVtO0J
# DATA fRHhpx2cTQtuIAxUF4Rf9MK3FsBj6whANp3RUSI/8YUGRv4oE0+3s+4Mwx1onQKeHIV53Nj83trjjUc4i+pui5QVv9HTgyTOQxP0
# DATA gv1tFuzEyX0AMfqMOah+rX4L1TXx8+cY9oQvKjr2bHNn7cP1ztrOzvoukuA4cbCNJaGXGaTg+hWGOIZLO2FOXtNohxqZwIAeAzzB
# DATA HR8oaG4W6H2ZEBoP+rcxHzRUGYQ1ghcwCecUctJsxhcU6TaZCqCpZjilpNeN2ndaitX+eDwZ/jidvfrxcDb4saIXe6uqWz8ejKf4
# DATA R6IKPW82byTf4V7Bbbu5UbySHXIvXCjoxITh5bPDw/4rtX1P4ZqkNRqWCCVXWNEAZmSnN8Jbx6X3nbOsvPceRDfv3FrgCDzaerK2
# DATA sRnKx2OIGdbYnEC+9zGuj1otOuz93jBVP/XZT/Nuv69+80SVQbhd5oTq7skzKjHSOKc7DbcqeTnvWbUlJGu6u3qh3+AuUaxO2lzK
# DATA Q8dgsqGsJd065UEzTpLkshMfpNGgqi3g0jo+WO8A8FxvcrgDm5qaaqcdO8lyy/Y1hfTbbf0/OgA6TMeREpamimzCC7D7Tkn8hWf9
# DATA AzWVOWosQN3+6vbKyhyWjRO089mTxxub33U9RMP45NVY4nMak4uytvlQiddb226jtVFOjpSg8kDMPLK8lDcZdNSrRF6vQlRfZLY+
# DATA 2d5Av6ySIdh5a4t5E/6jOUYdvv1sYmc2t3Y76sP1h6ofn126I+gtcXVo94V7qOp79nhtG687pejsHbI7CQRspiCS0lhFdOEom4PM
# DATA MZc35IHeTwqpX+3JDSuBOyfpi8wi4FvAfkQSu3On/LQgobLVF6gV1o6DEnXakYWmxu0KDVBsEjRldWisFsObfnsOfpNSByWcL2H8
# DATA c/N7Fj2R1Fm1S4bHlrOjwn+QKXQOe21qkeopriSPz0fkL98AwsGHUty2PYh9TR5H4OlmLX9EFAuvP9jYXFMHB16GbIIdgeSPzSUC
# DATA U19JHFl6EsCNNSFyVGJBZH0N3SqOnH3kxr/Z5/Mw8/3TiFqJxxtPNnaLKPnc2zKc/PRwmk3mji6Epo/u1bbP/eGo7g1B/j6BUIfO
# DATA kKBla9iq+cr8oo/MT/NNhUiA43/48drmR+uPigD9JTGczplqeZvY5OF1zOKahV0zLKzlBgi6VlphSgxvaPxlaLxv0V6qzD/BtEdv
# DATA 3qIUHbpbQM44FL72VlsezqTG3LdtwLUFKzcHPhQXWhoB6dzX5SiwpZDAVRl/qtUDV+T/ZdDwlxEBaIlt5y4dDlqgOYGc0++E3ldk
# DATA LRHtJvMjWUro8+VslnO3R9EyKY+wO9/ijXMciEnROSu4hgTZFq8J6Ia0JrkWUkqN0zMoA9yKALeEotqJAy1ooKvTvixyGyXKxnU+
# DATA 2djZ2dj8qHgndbrLsFdt3W9fQWbxN55PCLfbxUIxWYl1s6Crgt8FFocNSdADncCXtQNcwIXypuR9+AIBT/gp8L85XE7fX505eaT+
# DATA ldjaqvgkHWCKUWhjT0D8GgRwRtMBRA200IJZhVxFa/w9n8s4e5kO4qQCeNNW0zwY9c7qWNXDEb4mKE5MBeIVa7qpQRS3fQdDB/7G
# DATA Y+FRdKD7fttensXxpAYfEsgnffYO+jJJTzHL/aup0dhI9WxYybpzNpymr4K6VcWH1TReXs0a6GNAn4PqnPQ0YbwB5wgvejal4MVC
# DATA F6m6oeIShRrpozHTB56KbMrC1TWwLeTd4+wk1f7fOakscTdBoT39ft/PMOO+9Q7WQjOlRajRac5K9j3uw37JSKCogJ91VNLwDjXS
# DATA joXtil0KmDlU/XhHVM24oCzFPnqTrZ7wXPd7GKMFZijy0zchAoi2B4GoOP8FrlVsYw8q23fVpNZkJVWDuiwWM7+sXi/UnlYyem2C
# DATA 6cXL+sFPm6Q8Nbi++jls9pP0Vf9kdlIG1C9R+T1Afp5wrskYm3SFoH2rmelcVbINoBe6s3rr7kqynyRXIDYyfpex/HD2aJmqYJI5
# DATA wNtsAnh9S+9TCjfWG9XafS/TQ/zAiS8e9BCxDbabG3ZM8oqIQCK8mmAMElmFXNg+PUL1sNlV8hc0BfF3Q90oj08MnxuzGyV+/mpl
# DATA BdWyuh+8S/inT7yTOYgsl58gjc13fk5a6YsLpztasMdRCksNml2TRWV6qrqjCM/D9Y+3Hj9a3+4AuOb6p7teT2jmIMKk5s2rq8qM
# DATA EUOfeqGNMrQVYVJvr9wOvwpSj/M4PRjNpsaSjL+WRQMXzT4mAMnQkM/bdCH93Pb6v3umLpePlKT60fqOFR8d/JWcd6cXlg+ecEPw
# DATA YgQdEMrLJmzTbF/3ib6PDD1jIW5brawjHbitE27SzXih0YC4rdbt8eMNMH0Vzc+Ggu4TQSg1b3iyvs6jd65IWMtQNU3UyAewgj8k
# DATA F5ILebcJEvTUed636jD0ZyRmhFa3ggUfJqylj4CV1sURqaOzhcY0pGrq0Q9noyn78yaGNBQOjY3CzgS2XgVdYldLSWI1leKMG7xX
# DATA jA1wPtlw3eLZjKXnivjz7KSqwurvryDHba9vAl2QYlxo79DyofeRmXc1F2qJplphS49B/mOrKi+zlKm8bWKw07kmTThcmSZgdPnu
# DATA 5tYnm0RZtWTldl7st3xPV79vtp4x+J0Nu1IRJnRd7YCuazEdRbX6ivbZZfRhQb1zUHOBiiQYUkjhEIwJrlLayHBcEtkLSptLaLM/
# DATA 2ZaDdcJa1j99+PgrV3Oz6gfCYUqU3az8pWHjhcR/dTiY5cdCnjHzXdAb8xTS+e05Dga8Q2siWIA9DLJhrjhIB436bQbsByrUAVgY
# DATA zrSVZ2oXpGqZ8nYtrgNRbsWJTgiTFG6d3A/1wUm/y9MhO1OycnBiRpMUc0jjrhVuiMLRDqeqAdCp4MvYhP/cVsT/OOO8QryFTG11
# DATA f0YC6tsKzdvix2+OmpDXTrMY0b9iutVwuHroaz7a4pTnk27HObvqIOXTTslxttSoKV8Vzi0TTGqzxNDHwfimnNkJ/CKo/Hcm/N3Z
# DATA 3wzQXaXdTXSMZy+stlQnDe5+Josnx3zSKChcspBJGB6XZxI2totJ1lX3PoGRPh1NUadGQZoAqMnptbghdZMT+bP4fcu9BU0gsHyM
# DATA ZJILNMejcS3xNrwu64YlOWzEsbHM4VSFFaT6Sw9MKc+i775SrsWZl6lRnbVZdAYy7YpffrINHllx6MGMzovlffbyP/PGMOmfPWdn
# DATA UD7hEj+Iir7MrVLfprBAtru9XjRn+mcKsNBx2NEyjQQXKDwEsjFRKUqNHswKHQ6bypTc1H+ZaTagf3emoxrjQUJYl9p7taRsAqsd
# DATA XXAx38b/p8xqEwYfsQPDFTVJJ2Ibmls3o07Kv9dHWX/PUhLuAjAxh78shz5ZwOZUYhAUgLGeq32D6Fer0rnuipvQUsf32k5XSkv3
# DATA +kdZDpSa4y+a+XF6887dWnn9X4UzRBB25i0cJEL/u4TTRMnavkNHimvu8qDfgn7QH47wCDp+DPIL9TNpzfXNXMQtofwc2qSVbs8r
# DATA PyOGaz6e38cDDrWXDiEn6o4KSejv1m1NyXxXVF4frLG1UKbXt5kge3SaszG4VdWw4fkf2ZltkJ53ge9ISWUmaPUrXvzF3G9KOvq1
# DATA e9+8y9EX2A/izFnOUxwO7wF1taK/ajKAN3i1LxWbLuGowBKyR7LNJU6ryFg8ShLZP6NjQbQYV8li/KUlOKXjRR0C/vDEdcfcKP3t
# DATA itFuiascwrwjqlfcN7rrc3dD70y/a1e0ZL7oD0mTypooVKaiKsra2eC1utsU7W1Xs33ax9g4PvThyhB/IJSy3Bvinu34IhY+/5NC
# DATA eInREGJBnoh9nDX3UcCYQwVYIWvnvjAEY99yPgjYuUrbwNXwxvvx+qfFgWK5hUIQyDd916orreaZ5aP+MHI6XDSMhYxiARs7VlfZ
# DATA eSxxKUOk7PkCjobAcBR5UFLxYHQGsGUhraF9q+4yJk7TkYAxQ8wEwy4DG7jxclUncHIVSVJ/SVUU/JLWkfx4MQzFuAjPnTeDBHlY
# DATA H25Z+vuyFkEYalwIrXiaTRBAkf0/SkCSw2zng2c7nxX9PJxbvZRtJaJQlVAd0NGFZkhqI4bTOAAmSVHPJ/nL7mRaeEuPMSBXySxO
# DATA Zgp+9VjtjA8eQzqP1UU0dAWIKudqsUgSDDUv4vfmB4XFqkayvswiXT3TRkf1BaGna4PsEOLt+kfHU5fR5md5EyixojUnTqoexWBn
# DATA r+IknASaAKr6B6wFpoD65sNHjx9znoJZnnUwsF5A6RzOhoz+YbYUV0GYj2qDpNObalthUJXupPmqMiu100AznRxhjzDZPfWt20EY
# DATA R/MLHDY6Y/FgzuuZer/vtgKYMBDj3XYqKepHYe7xfgh/dLSuV7+lNYHX+FcnoETVLdacClAwZpU+vKAMhnWnGrcUvtHFblKq69Ic
# DATA wwx23RPjU6tGi2qNc1gAgkgN4vrOZzsGbh1pmvm19XRza3fn2dOnFxVrSAeDD0+tiy6qoPlTfNQ8sSYUhM8np0ZQsORTdThgphzt
# DATA tX5vd6JmLqa8pxYWb0Ka4bA/xTqoV9Z2N7Y2SdeyI/LXLnzIAmdk7uEqPT1zT1BwNGu7W082Hna0AVjx286zzbXvrW08Bhdw6cfz
# DATA tRy3RY9c4djRspNiBv8sHD25YaCY+N0pMRyZo+hVKY8ZO/LyOStW6paWe40/WfVhUW3wZNVxLK7q3GNkAJ5KGTTaslCoDB2zpSKL
# DATA vdp+IvMWz5w0Cninke1J17Qrc9Nfp442cXufGJJBqB2IlCfES9fwadxOiFCI8P4gFCGZGmxlupfLUUyt5TH8bYRSuM459Ea31xaV
# DATA oP8jPQex3688Z8OCLm09Pvj9gsHCH6w9/O6zpwh4WhX8TNlnCsJ6WAUwAvBFsNQpcgfeYugwJb4tWKKDqoFJeqqv2SV3BOd2YBFh
# DATA PFePqpt/EZlf5Pq16TIMXL91WOpmStJyNlA66R6DXaBVpn/gAqqvElOmQiPxDnQKtoNGhVBnbLqvW5fAeDkFlQJf6m1HsYbijitD
# DATA xKgGY3CvtXyIHUepPXlRL6oj9ITglO0XcsXWgtoBLj1fPcAFk2RxDQGd2FhKMnZn2VPgXJIp9MDfhrJwyeEIlk4CiSzMhvVoAXj6
# DATA y9ON5C49LZJPFFuskocnZp7UxeTLVaoWmxD8wVPh2XiEkOaCQiIn4FaTOYddcJF6NB29yJQIORr06tEwO2VcxTqzKIkRodchRNqW
# DATA bNaBkq5T9LFo2hHzBIuwSMS97CXMqfjGfbnQrZTmGPVhn+3srj8RMqDeHk4TarPUBE4WuADhFAm3Bi/Am6vBSPOVFTcap2wlhRon
# DATA vKVNkEmwpEuDjdbaENFWtKrpaKuSntULwpckZq0AJdOUuIVbpvg57f1W9DZHSWY3IZlI8ye9z8hZxuGh8enpKYWdwSZUZCu8U6GA
# DATA enG52GNmiN784r5Qf/MRYnmJc7WA2CB3O+SOGPR42pQ8lZ2qv+HAOVMIZXbewQx6tepF4bMd0+GGB/jHhYybMrsJebN2vfUw9m5E
# DATA N+fNoPlCWtu1v56zchLwjhwygxBCJBMd9of9/LiMnjl6UL5BCC/X7AA2vy994c6RGRWPCkUc50AsEaIMImPUIhSl0HRQ++hSVOTb
# DATA tPt5NImT9IBe6Y6gmkTVEAgD5uR9VK6up8bXPy7WgTYkbzsVb3CGKho3qj2uok6zngSilelG5DIaGXHIi1y3+6+QYDDPgzlm5m0l
# DATA quYH6oQM0VeudM9KlSQXL5r/9IsrWwC5gnrJcXx7sZvImUvHmGoxwaoL+mQkcUtO3p1MvoDZDjvrCamI+Fi0YlHRJCy7i8Hua2R6
# DATA uQtCknvxEh2SphcU6MMYcr6ED6uwX4/MD1qEgMgfnC1YvAUEeixWeomgRV74FsHFTavBWCkPWs1SSYnTGetx6zovc+PY3V7b3Fl7
# DATA uGsjjDTwecggbi81KJWW3p7cqwNXRKrPRfiGuzGXLiOMBj4VbMeKiJazzOV62auxEmUxqlHsg0L+aWfRGZudLp5wbnQlb7kunUXU
# DATA I/MuIt3ZBHVY7beSodhO9FJzJ2jT4Xt1/m2XP9GGScj2BOWNPwkmTQhPZ+Eaqrtv7pP2vNvUNgPcLHbe8Q3OTFt3YK7an+bVFXUp
# DATA GaQgOktVgkiVLknuDkcMuISKgOvqmbk3ko1RsJYSJ6EHnvSPMIDLPVrup0uuUbw4Lqolqd70l7zt2zN2lDlynF5emHVKZsUTEbSD
# DATA mBsRj1TehsJ9vEI/rdjotlKP/APgi9LhYwL3DW+U/IG3q8vHbrdl4HqNXbWNBmRclG8DwqjoqQ8EVyqOFkz11L6p0924l+ikoED1
# DATA 4nmooEX14JHBMeO8y+02Z+LFElVoeC4zlMAAJAnEDi7GVdg283Dre+vbn0EY+IePNx7uxkkV3TLDnX+8isMqrmRxccjWWUKyzGk3
# DATA fcJMR/zxXGpZOeCvkzdygWuG4bgpfcu52EI4pwHeND8dn44Cs7JE5RFlbYQtzerPpFT4kcY6nF+/Jd0Dvq5JC6G/FHzpO+c7CCuN
# DATA NPsM7V2r34nio2yYTXBLqg/1OfH0PsZTsWUENuO7OEcYudC3ZHVJnvbTAUVI69PquOHww/I4NOOSEY76ukxsstE5XCY8WXfwHcV6
# DATA OWoaHWNx+fAuMn8YBsFh/uByFQrcOuxPMMhkCImYuITvL6Ht/Fi0PO2vtyj+lxYRUYJiwLWx2HS193XBQcYL3aLmFg3dCoWPvCXg
# DATA chEq9wHZBJ3IkmvkbquzZCQLDrSgzXMWHKQnMb+FwCjWbxmyWFFVKCRssR45huayjjljR6We/lVQxpne1ovgeMnbjiAULrxIHECV
# DATA jyEAqWWTlyFfXheCT+sMfKbq2haXSiaDlZRJsUIRosvMAN7MIBN8bDoHOjaSUcGAwPHzIrCPGEfAGvLu2IHPcPiZ4VySZXDWU8bU
# DATA EDcoH1+jHU8U0RydYHwIxpxrcABxUZMmyEokDogeB4UjV2Vo08FoNAi4wutOWLWYeUReANQ1c+MOBgQYpJCF9VEA4bO+Y4Dl7Jo5
# DATA DjuOwc2eDavKCbiY82XMll5UdW3DvwvaazUrIcW1E4JO023jXLg2+O1LBqZQlVQhCVPwfGIpeZVvl3tGFWxDhJEIPRainHMTWRL2
# DATA ar9VkkXK3P91ANTLjNU/ixirTKf0d/5lRUxykHovQDIIYaNAMczdKxjOJcmF6Z0bMOPSBFFIPN+XZEIU4Wf7F36sh9xQV95Ai22i
# DATA S6kdA3wgdM0IjCKsQi0XmxfvPGnrAvuXpCyaIngLyuFzp4Gy0Le9fdelrb7YVybSr0J4qPufmzdO+F9pByq3SuieD88YecmZjKtM
# DATA dQXQE6Ftj/pdciPu99SH/cN+NkFTjvjJCFC6+7X5m8TibYJkCk9Ede12kY8nVpGZZwOt168tyO89ekP8n5P+NWmINR4pQZIZltkW
# DATA LBO/0m+cm7vuURAO69KQWBIw0sHF0u0IXCwb2/8iAwnCx/Up2P8DHLbSC8CXYX03IVYSeekoLgscOU0n6oqD8d7QzeWoAI/BnIsK
# DATA Nn2MEglehCVMw75fqwXFun3b7S8DdFgkuXMe2w2J8cMQgoqsUsruo6w5ORqMDmrxjThJLuqAxdcepCcHvRSLtfxMYnWdJYQiBUKa
# DATA WB8hZZix2qvorFPhDOXEr7bMJrWRrC0tuYbDnjmisaWB/jwiVwa96Sjb5u+Di7LW2R1Lel44hNJx6jEzVOLZs4hqLujZ45ghjJbm
# DATA WsADZNHQcqnrvqwbY8exT4pHhWyCUnpiqteLhZQY5C1I4GK+5wSFrYBfXZnwVbb5HNkqMCYrVemZkkKVRjfE1N/FqxgVrBvFYce2
# DATA Vnr7CoKlF78u9zIIFF/43vTR+ub69powF3+lV6er3i6sFV/0iEolXtwEFxVRIbJRDfq8oH+ErgyDcC4VPREverEBz6LSe2TiXBmr
# DATA yoX9n6oAe4yfQOfp+uYjF+/WWjNKZODLKG6KhovAhsXxLegTwTUtNE67vwOkkM3RJOaUW9xDjog0L55fiDNeU1gbBIFv62fgLUst
# DATA 6oG9la2b6VGv461L0FOfr8XU+HwvHBuPJJvwF8l9LVdLj9m/HHg9dtqbK03aaKxFWRhvGmtnrHt9ML75zqGv5mv0/VsqBVyFgDeN
# DATA zsXCm7QSt2Ss0+FydshSZYBg0AXWhvo/JcK+dPNYKnlxgo5QlGe9uTY5msFkP8U3NQH03I43iIFHB7NhT7HxSJG/dBABkdXsIkfC
# DATA OJpNI5w30GtBTgToc940CXWhZsAY76TcWC1uNCTuGugl20+NmqDsC5I2K8sInBU1CamaGaNErfyOZq8xIafOxfrDEhCwly5NGAkT
# DATA U7VxqluDObrCZ7xtFu6gJs8NsYk0H0aANf4O/4Evc9wwSTBNNbxuQscL558OcPHKj64U+Bl3vOCUgy+dLI7W3K/ehNiLX0aLofo3
# DATA q8Ar7W48bIqWtfOqxvLDmepMHondiUQxOJV1s/fNVoBeePu0ME+OyOlOQN2ZrXrpJPCboKq0aMWfP892zhabL39y+PvUTmEvmg3V
# DATA 3QxmErYMVD3LFVUtmRPHIhKcE20awR/WNCG3QNWsjCd9dSQE8DI1vQjyclJgHSvzzFgBXJBCB85jLMFMBf+GS3+xP0ouhntuG3AG
# DATA 8qm6zk8KHVpVJN8cV5NwBlRtNsmKgOw3J3V/KWxFdaoAIH+4uCL6UKeDiqxOB1aj02EvBOiakm+nNeQ5asK+cfn/AVfB9de6w+b4
# DATA 7Bvv+H8r6n93b9/Gf9X/nH9vrq7eun3rff2Mnq+uvv/+nW9EK9/4Gv43A+wI1fw3/nX+z8+9dn6d1FPXW6v16yhqXG/tnV/v9663
# DATA rqNgN1X0QR2V6/XrmKVCPX79t29+8uYvXn/x5s9e//L1r9782ZufvvnJ659Hr7+IXv9O/fXbN3+qnqknr7+Ev15//vq36mMh8EAV
# DATA /6d6/U+v/14V/knJV/VI/fsXqoXfvPlrVeT1r+GValQVVVX+ClpT//cr9fTXb36muvFT9e/fqA+pRlX8t2/+Sr38xesvmqp5VGFd
# DATA b51f1zlUVCfuX+uNEAYCk148eP58eB/+iAZKwmo/f349G6r/PLh/nKW9B/dPsmmKGYrybAovUXuG7/ENHFp4/LKfnQIskvpTa9Dg
# DATA 8Wm/Nz1u95RU2c0a+KOuLQGNXAl7WXvV1nU8nY4bQN9fwqcPqZbGDuQt60/PGk9Hg373zGuAhbBGPulGz+M8Gxw+j+9FNOX+w+nZ
# DATA IPOe9U+OnCfoKte6F40OfqCWn18NFdOCwgdpnjVUX8QjAGVpkJhlnxZnR2wCr/9r0ct+PkOpd5odjEYvIkxXo6Tco2O4kxwrRnI8
# DATA GvRyZIXTYyUZp4otRvkJCM50mYCEyhFou9VzxZZOoizNwTwxHQFTbEY701nvDL8dTXr9IcAuMZKsEuhApD4BQEjsNW71B09BtQ3i
# DATA zSF4j0Q/jv7drJ9No5ejgRL97i9TofvorzPJBjCMfpdGprp7CL+X01ztl3wZnjfzl0fwDmVKKHuiql9WD997dTLAVmVNuEr5cZZN
# DATA Q/XBEjS7eX7Jz9DOpz+jpQAI/UKRH0AJEOyzyYP7y1RQ/YEnAY4JpPvDLYJKIPhckgqsXR2WgaoS+/SiP5a9+SawLyi0o17A6vA+
# DATA uL+c0mmDVsX3B3CxcIZjTXtQjbsqqo5h+lLJKP20MUgPaFqegNykHvePUt580EJJfVsvswmcY6xLlMrV/ulnuSm3M07hAEf83C8O
# DATA W9CU3Yb9eDqavMC1waLLqj88qTBgEg178Kmen/ucmslOxRhsPfAFUabVB7vHqVrCMcjEJqBNbXH1t5LVhk1V/eqD+2NVLIvgW3U8
# DATA zqLj9KX6Y/QStLuQ+e8YDwCkcsTXsBooZsJOHTUj9a26NqM7nJLE1WmbwhE7G81g6eBjrajSR1e1On5wv9d/aftNpCH3d8bBbDr1
# DATA Doy7FB8oIVM3c5Cpey/g7fJEe7WAeXA07KlT7dS3yKItq77CPqfZDkw7P6BJv/lgaxKN+6pjs7GaJEVaDmdqUkajAUz3TZjuh+mg
# DATA O0Nz5OFghNJ/lpJ/d4TUPupN0lOgOODXBzOs1stsjqg3ymgpe9kU0ArVDULJrjM4W6rjYPdF4BoEMuqOlIjeByU4zfpl9p8Z7zJs
# DATA uAf3D5UoDztx7J4otbvkVIDWl24JUK/NHaXqUwUf6LV3umITkcE3a0jZ/yg9Gd8Def1l2j2DDkX/7z9Fl+o/rZru9TIQJThPzMsV
# DATA 07fN/oHb/4Hbz+P2tC2vwOTfMY+/Goufz+H/B2Lw75i/L8TeL8fdvxbmTjtSDt8w9H85JwgJ/nzeqSj9KM80B13TbJPUeapF5O6a
# DATA f8ohg1yT2mGODjkAUo1dbStUq/AS8RR0+xNkvqjA8yYCpwdFGs2Cc1SnDbJ0glD+J4ppq501qCMDVoPon2S96GDWH0xhBEAfcxqy
# DATA 6umzHD5BaUv3T48AWrAcvavlgdwXCEgcGA0HZ81oY6pluC7k+QaODxOn2BZqmq1ZW4sCaQ84DKoXsYuwKA0UC+Cs5zniGEU7WfYi
# DATA +qHaK+CspY0Lx9lgjLoq6GSUHh7CKoFAkh5m0zMzws9Gs4nl0Tw0Jenk0WQ2NKLmATg7ZZNmtM6JhmBKYRyzMUgrIGfqXQh7PEcZ
# DATA RhWAFAojEJIUecihTDo4m/a7KN2osWWTKdj4j9QQUvC/0K5tUFf3OOu+QJUnmnZQ7el05r//5H/Leayg5UW/oP+PvXddcuS49ntf
# DATA pRyyNrtFAIMq3Ls5ozO8SfQmKZpDieEQ9aEAFBqlAVBgFdA9rdkToYv31nHIceTwiTg7whG2wxHnfKe0RXusCxVhv0D3K+wnOeu/
# DATA VmZWVuHS6J7unltKJBsoVGXlPVeuzPz/skEyp3DYnrTKrOa9g/L3eF2eFS8oYadIuQoLTyCqx3hFNKWSGulA2eNKbT2MqS+aRBW2
# DATA A0ExgaEseTvLY05tYsGFTc/QHSZHPD4YoCrW/N67yclMzDxkpOwsG1CNwY61UtSknsotGYxwiiq1cvRwg0gq+jjJpGixpzBlE/9h
# DATA FM3zRh0OBrD9Jwkaw2DA148QUAyFRAgvcWbS6IFwspr3ccL3LbnU6PYo5SJDXpoWhUDniPA40p0EVZ+P0NvEC0kCBW03F8qxJVVu
# DATA ruaqtepWGT0iYxFJPKHATFaMePJSKMgPKMZm41IGcQ/sxhtKB+PheAmVUBrrc6XDEFGseW+j85G9ByiSFONiRH2Lqq70Hpzf4t+k
# DATA Silr/8rTnN0Gm51mODuaybdm7F/F1r8GU79oNJG9/53H/eQRmS8/A76mz7W0Slee4KHHZPEkk0m1H9FcOE7Sg2xKQY+fINzH0zCl
# DATA 2nBQP8QKx1EK18/BcZjuVavzcB6l+4eDZEKPyCWyy/YP0X8d+J35ozt+rd3y5BeEtX+IXebU5Z9UT9JwftCnGviwSmkbPgkfSzDx
# DATA jBpIvDiEtn91ia2jZOtF1WQ0ogQd1IIgmj4JD8YI5zHfMwQLhBtJlSr/4OGM2u5BMH/0RCpJJZ7Nl4uK7N+q4AmMNY85iupd+s6a
# DATA /H08jDMahk/pZ371aBI9OqTR4mhW5S1/B4MImOjDn1LrjEenVdW+9GWan5LRgnH1oNmcPzqci3FwQDlBfabn13z8PZQSOPDnj7yM
# DATA pjRDz8q/lYxG5zFbFHOa0qsvq9JMw2G8zNTP8qVCMZDyqJ5InNqt+iFNpTIKZ54w7/qwlI0HmMCoPKmZJqZzJ7/y2IomdVOzTHZM
# DATA rVQHFdSP2ULFXu4sGt7FovNPHq8klJNvByBVTAVxQCWDUWX4OJmHA5oNHtRaLZ0aNQekyjEiAyGrkj0YYwRSjxYvcqUoXZMqUrqo
# DATA K0z53uWUmsVp8epjatqoMQeNUqHyXVT35Wddl6lonkg8qL/e+zFPkXgYp1b5k33rIooy+cn+Sh3mmfSBX69/u1Dp2lTpNtQuvH5/
# DATA 93acV13U3FrHqri6sjV0Ikrxr1gXJf4qugE1zUMVVf4slbi62olQs6tm45S+HNSfFIIjW/0nj3Xk6k9Mhli54HfrFDZVtvhn0QFb
# DATA TjRMPeH5kWnfR2k8PDyibqjW4JQVmkm9LnfXOEnmmU2dAQfTQSjl9m+H2qRQR6AuUPk/3lpGOnV+LWjpUCUDKV7REY3ij+2AO/W6
# DATA eaTu1Zr0yJOxXxkHlXGjMlddeHWRzOnxsS+9n7wO8yuYyRJQBaRljHfT+V5Qa+LVlXatdXxSadXwZZ969HpTxVTlyf7hhCwhqhJw
# DATA uyIC8it1CUzWqFRr9UaLHj2cho9UGvz2YHyoItVPqH1OKaENjnSwW+R86U4rDYpawBmPqPndC6JGcQlayM7iu/nNDXkzvcRTuU4h
# DATA NsoBFp/klvEEGayT1u4Mxk/i6VElOz4ytYZJaIdWe1UVJFwukicyJ67wPgMZ0VVTAS7OD+pUkSuYMO3hSa/qtdGnm4jIIGWHdGFd
# DATA LQ9c7C6nsX9xEkUzrsl+rVWqyn69ZboVk23rau6TGnsvJC87kpdNyctgNS91rgV1qhBrxyGaSxQTxP0CWw/4jzS8QA2t/PcJu0Mu
# DATA zIVyO930di+UkUt59e/CBP5J2fQ4MJbKYalZPqnBG/QY4gl84yh+FA0Pf1ZlHwyl+xCNsuqjlA9B3KCcRkZv6KJNt4B0csgyBD1G
# DATA KHjySY1MmkR3jlVhBrZRdsVej/5j9qyh711OZ9mBP0o9+ndT/8YNlMP3amQ50Gs4rdzFarMmL9JmixqC3D2Kj5ZpZAzJ/OogZG+o
# DATA FU6tG6R5+0Sqal1+rZpKXFwXuqXnfWmjNWXwl7KmVc+rNd+9vk6rh7lDKkZh58ZkZyp13yvdX8uOJb/Io86weBdlHUru8Q5lmUZz
# DATA mhXuNSpUz6lQ9uoVKlnqNvIYPakNwnT42BpZrFGnzUN9uRZmy3SEI9wX2BfbzVF5rzc/wOy/OhjHk+FqMvmWGtznldp0SZPSx7aB
# DATA wFcoIPxuV56e5OEJtuXb1kBvbZtabz63qJNt0r8N+rcN06pUTlw/CwXAPrtic9lgqJsBBoGUekNJ88FsMZY82Qtm+55Oy6aSCFat
# DATA tic14zct13XqBihZ6CTMLZ6yBiQDzcCPoRWjPj4gRPgqrUGu00Xb5quePfh16rhO6YkXu9RRykzV4+jupdBKGGrzpAbfgrH2gpus
# DATA l3gTL+asmoh6bKmJ+XaJFhisbYEclmwGfFzorMTcs/t5T9W5LXVApYzHj+a6GaXVFhrSHZ2M+bAkeqsDmpRxL6pjdEBJWZyaNPJI
# DATA WJNt6wUbu9bSVrNqfoF0K9oXucbSbtqpqx/iriov4Ki35H7MSfx4B3OjNEehnoPmTfEgemxnSXk+ppujbh4y7takUGh6eWQZUSbq
# DATA 9R2GCXnWCzHdoPngDpWkUDc88y3AN9h0qw3CHlOK/bVX381AK8bSm1sDs/opo8F9dvS45DegBhIelb0jYtpuqZumgAKZRKbFOtNt
# DATA r04qNzTNfliybXVLWhlbS3ZBuQsXg0AF6cmkEI8c+NY8y29yTylNIc/osvNmGGbjqJjBPx7Hw2E0+0mhAf0LwQOGs8UTam6PjR/s
# DATA EZvu9twI84P8fc0Lmr6dld1NDbvkdgtnpydwQz/B2oiU8iicxpPTg3fIxEpoXK588caHcV/vff8omSVfvFGZ0h8Ot9jmKS+HNA7H
# DATA k8zKpmD3+qh8KY9LXqmy06pkr+t3eoXZLTdhNYm6qLkeFkdHjnGgJj55iA17uF9ndO5gAJarfDePpdX6rDrQwviqbii4NXimspt/
# DATA knrs3FtdmoluqA61eTyZVNPk5GIrW9nUi2huSl13o838J3Tipv03VQe9gAuPwyu3gif8ky446iIn4Twjq0R9sCfQdg3kgXkxriyG
# DATA Mi3jvDhAbArj6E6VcbHN1npSoxhEj7knlw78wL9T9XlstHxEltEgNkOyXMyXCz6RUM4smVPxLv0qlm3WWLM4nhYukvSxHnbX2bJS
# DATA o3VHZyr0k/9jGg3jcM8y0drUre0/3uh0sD0NjTb6XuVVKLYWZZOsjk5cWeQUBaa7kk12neH56cb5Z6lRNjBztbOyOJ80TpcW99U8
# DATA N7qUMaaN1c3xsV++fgrZwGJDcYa4Y7asGAybp+XBSPsYW5aVoh+8Z8+l7OoZlMxnbcau1otmg+sF52FFW7kb48NuGXG98Kjeywun
# DATA MKEIxE2npprF4WH31O+cXO5E1sx/uCOnqmTSPeclzayaRsPlIBpWpwkXi3yl1rFuTYwD/07lOwey6YM+hCO0m3AWT3OXUT7OH/Ki
# DATA SLzmFx0NOZ2j26I0w4pejCo7PMQ+5tJU5ofl8pWVOqtXYCtAzQ37ND99aGYb5ZuePCmsGOpdW9ghSH+8R9PJjNc+sS/v4M6dk5OT
# DATA 2kmjlqRHd4J6vX5HbfDCBqK3k0e4se7VvXaT/uFlX9R4TzYA0ne+6ElHln9P+Tk/wOcRDUG8Z6pRbwybPWx8vPcWy5XwbqGP/Lbn
# DATA 98aN4Lj7/aB57NfH9N/u9/32zwoPj4JRY9SQhxHF4qpoRiNk9OyJ7NJEnibznIJkova38Y35ZiyquP1T/ML75vLddWrzk7lqLzof
# DATA 5Dt6zB6AaMhr4admA56VJb2612y2vEav6QWt+qRRDzy/26g26h3PbzaKGTNsD/tRfTVXOw2v0W38yO+0J0HgV3stL/Dp8Xr3mP5+
# DATA iKBb9aAYVDQa+ZzHPF14yOn/VrPVqrei/GLVFH1j5aUItesfNwN/Wq8GfhOvrPZ6HBkVEc+XWnHFNwRB3Qua/rEfNCa+73ut7o+C
# DATA XvdnHzUbPa/hU/UJuhO/3qk2Oz8K2t1i8rqDXhSGK0F2WpQrvbEf1KfVdp3+OcbHJl1uNLtj36fLrRb9c0wfSzHvt/v15mhdzJsb
# DATA a6ravkgV9QAnCx8rT/CBquGHPL8/UI3lUE9tD77VbrX7DVww3id6hP93aAya1SvBwbciP2pFnUPlYzv4VqvX7nRah2JhHHyrPxp0
# DATA B3iC3c7087DdCIaHsrx/8MUbD6KjJPJ++AFNFz4Lx2R7Vu7z9rGMusJqFqUxntVd2k63o3uqYbclmUx5l34g1qQXFJ3OXTEEzO1m
# DATA NFLzm+9F1KbjsCJBl5bmDsuOMBhnlU6teXxS6YgjjANWO+V2md5v9W/RTLUYYtlRbpt5qmBWH9A+9OI4UbhrXrAqxeTkGzD+DGLs
# DATA JHp8ieWBfC1APIAls0icVvXLGTceXLTljRhFr0B9ozFbSG1lJWkXGXfKs7dSx9hsuElL5clqW/8pmvoXb2D3HnUS8WDBO8lnvAHS
# DATA +5fQF/Pu3jNbIGtfLqP09AHvC0jSvWzfutfcfD9Nw9PaKE2me+ufuz+Z0KPWs2ov399Gp5Be1M+ghdewHZBiy3NL703vizcO7AhO
# DATA oylOZwt27KNwvseBGlY4yxk/jE4r3iicTFC5973HOPBP/5UARCaf95Q9kEiASP0BZfWeFak3oVG2f2iowkxXoZcuJxPvu96exKI2
# DATA DjO8bJ8uqSsUlFw5sCJw4OHop2gRsNj+ofcER5UHY4qVesNlQsTjT+xU86F6SbZCxT7Wj2fyuP7hUOVFIf3ZhvRXJN6oJbOjeHSq
# DATA sVUmW7DFZk1aRjjcvRrJ8HQPk+d9UxQRBGr/5d4Xb3xLPL9fvEFBQ2womgDRWsPd6nQG3Yhvh6Ugx8nJxjDFGL10mLPldC8e7uep
# DATA +Xg57UfpHof5BUT/6Neazs3Co0O1iXRP5NwQuOhZ0Ju+eANf71BzjmeH+piLnHF5I4/9MkX0f/jphzXZcfkDPh5C36He5r0NDb0f
# DATA I5yfVLzHCPgJCkMeDe2GJE+/N4lYL+OLN0LOhrCG3X/QrEkn+Kbji9ZEMcalwSQePKQ2ha2nn8XTKFku9vb20cYRqTQ6JqMijxSF
# DATA A+472a8qKyQqWN/QpYDZBF5u51Myw4bmvdEMCUfZ4AEWwptC6OO9Y4r0h0prhcLIlv1pTAVZ8aJjLrZ79Bh/rEE1hv6+Kxuz9lRR
# DATA c0A0Haep0I9A74gXp3v7FP4MNzxRUf2XiN6P5cBFeBz9hCJZowffCwfjPbX5k180IaM5C0WMjnsXihC+Ij4//ol647+QHjDO+O8e
# DATA 30Bv1M/9+Ce6lCj/sTseupz7Er5cP2UlS76/RqPKZDmMMhWNvEOkX+l9ZpPc4r6WtkcJW1vfELUH3Gj3TqHWaZ4pVn6887tUMR9I
# DATA cqiDkc84b/TkUEd1L398TdlwfcH7dHKuI6v05x2ygxIgd5FRTVPbvWPEAuzgu97a2w+8H9dq/HlYWXeHKSiygDMkk+PB3auVGIl0
# DATA IYvQu+XPmGw1+9CX86HeTF7YwK/y/W217X39HvdDeUbC4i3tmdrOjjOhZFAcRzVu4U/k32L1NgtexTqePMorON+S6WKjn0ymmIc3
# DATA F6E8TGVoQkEhIpAVG+CLN9bt5LOjxb9LxPijRICLQYLP64P8rnti+bauivLJG7uOKhMk18i17Jdt0T5QcfkCEp5Tsj2ktpkobKo5
# DATA G/JTR0DVHv2V7LvZEU0GYfp4bMZ75r10sVTLdGvZUK8OzYGK9TUL1SavN6ru6PyBuWpGaP6menK5gUZ9mluxMca36O/l7l6a5gei
# DATA ZWqynzOZ9Yk55O9KLnp/93cUa1QI6r+me/Qn+TA5idJ3KPP2TBZTQ8hYfE2/svA0WUlIONdrnJig++qHntUgkKnFSkcX7KrBoosQ
# DATA 76HrdqdZjE1eEzkt+97f/I23p6N2966OCSLFAZkqYPLt7l2VFNRf3CLLevTmf8FRkObGH/clLW++KQWljB2sHOrs5y+5uYNv+3JH
# DATA HqzkB3rHej4iKaUiKUPcYAKR3/bVPaXhQ8LiWsoxjDIeOKjkdYmuaYzcjtAWrUqB5Jhy3NqACw/RixBHVU0pk3Ug+8UahxuVxbG3
# DATA f/ce24xfvPG+ORSGZvLmHsy+L96Qpkfp/4585zkgN/dF8j621e0F+28iwf/r97Uv6H+zd/UsOUkW7Gr1woXn04zlTQmAD5tRAPTQ
# DATA +veQ8XSneGv+Lp/f9b//0XpQR2iH5wZTadwyA8wPZLqD2e5g9kUHs92B7Ff6QLZX2G6szkG/0Ae1jeeMfy6cAJxYx7cfzFktDyNb
# DATA PARsRJ/ezm/nbcV8Tu7FOs/9spxqvEi4xXaUcvzF43zvLeppy81QL5IhGmaloivrXdYKnlwIJ/yteFC9vHglTXqQIHPlTaezgY6G
# DATA 8mPf+8HK2hebqWQPlA7+W8/wF04HZ8D8HhftAZU79GCovGAPpYtTbCo2z89FNyAbh3wiVtcoT224oGkhH0de9mlc8+DV9TAHoTC/
# DATA 5HjwLqU4SWveD+bRjM/5jvjsPj2kDvNzZfUorDFqHdVJT7YhMIYJd9ObwViggGZKN2BH5R2v5OPWOgJ8npijTdYCGdlHOJdmZHj+
# DATA FsecUeFwupuJDt4nS+Pu9Wa4zOpH8o6YflrOYTZkNQ+2FP+YsUmVjODkoRYzhKWmmg2ZywlLAIyWKVkRy1U1hFfzsK0JwVlvznq7
# DATA yHor1jCnr+P0dS5rtm00EG9Kd+cBtrBZchB4DXybEM4zCjzPT+Nt23CJ3X2eLVdXsOR4/YPtDyyKqC05+hoXNjohsWPZJ6AzWXkB
# DATA 96b7b4lPVDfAGa9HoZAkNPOc6a7yK+wV4+0ftRZvItIa1pR83hCFi9OQ9xu11GaSaM67j2rSs9/hOJaiKl4IUx3wbYeI6qdMPM0F
# DATA E81GrX2N0RTPCP2svTR84S1xtKpI6XtMpMxDbyXc4eeRC/Dme/5BUH/rTqKswvI9LXVPa8s9fl3dRB/yu+5ItPKkKFtd56ZaBaMH
# DATA 82awsCWPyGzgJ9iQSKf0Xt4TrNKpVkMxeumqmV+Snic+5hfNaZxeSA7ckSAwf1K5Jeu0dij5Jb1DzVy5ZxmcISZkVgdgS1Ox0SjN
# DATA fkmpgvCLMSg/osGQ+mcxGrXX2mr/GGOjGbd8NhTNQBunYkfWvPvDocdnYpVZkOnhM7chvQ+xhqJUPTERMCPtErLp4uhlo1QMcepx
# DATA 8EbswqC3zZeTCf+4xDIsDepxqo3/H2aRKO+IiI3o/sT9mLJYJOa1iJSu81iwzTgKZJbAsGBTGj0R5jVxhmkhJWkmnZ9WuWJ7fQLh
# DATA e6uXwxjYj1gvkzONO3gpEi6NV99qtgdAZzg7w/kiw7lkIDnL2VnO283hF0Cx8jN6GzeOTDTzwqFqDbnZXNJsxOBidN5YEfFhtKAC
# DATA nR2JtF1RelGYYMkI41aiJCBzpUTRQywbySX/LLYrSimoLYtvjRusP6eFnHVjpxg3xGVmRCphwWCfEvQWQ4kui2EnoxG2f0Gmj/uC
# DATA zBsnJ/SzRyUkwyXndc1TxgUkLSl2xxh30c8kI+4YOM8t+UrxWXFyioPeImRv5v0Uw9XEjHQmRXbSPmSnXDggGwdCmifUY+Upw8hb
# DATA 5SmDbIhm1Gk4yXi7GCwdJPGIbLFM92pDKrwx9WZcSpxMOeVDIcxYVBxuRDKdjmTuJEaM9pclU7IaF0pdMIRV8NDTSiFb0vlueMo9
# DATA 8faEogzFVYky1ml8oPyPoyiiZA3jEUv70ewOhhoEDrGHEfsQqFotZAsG043pFzRF/MImoPcZY3g85gsiQLasmCkLxyBVRZ0QY9H1
# DATA l6dSqU8XqM/YJLolkZ9G2ZoEillRqMKrgqqmqpOVyn7LE6jCo5JN0AR51EmjdUYsirSi7UgQ3sJhjLN3MtCJnarEJKn2fgr9lyFl
# DATA ItmFbPsh+bDzlmRM8BMPxeOqXcoMKUPtnso7xZ7UU2ktdTqK0ykvjqyb23KiPqO8kfk4GL1zHCMlM8morVMLMtZzvvidif9a7qf8
# DATA 4OpIpoCanoeZ2MLcO3kfaXFP6l0Z9sCmtAJxGx8yNZ6HbB5jakCGL5V0uFzE6DbClHW6pkp5ktVPpUMBF0rcxmQh4LqaUmxM7d/O
# DATA khOpn2gl1ETQR0KwVSf43YTDX2BfJXJb2iIlaA5XAneNPLaJXWL5FdD4qZSxpSGeGLhWytOFlIqbso9sJMowSSEVOQ5IY0dGuKIg
# DATA W+iGeYowOy2ryZr5hC0ra9n5YjO/gtb+kycVw9BZHAHOm57aBJ3/7/xXZ384++bsv599rRg5X5/9hf7/1flvvbN/AtOGfvg5/fvb
# DATA VXTOf6EfntJNT3E/w2/+cv6bs689+vI7A9H5IwUql/krQDu/PP9NxTv/t/QcPYPbQM/5ht70J8b4/AP9IEydP509Pf+1jsxf6ZY/
# DATA CKgHsB3H0nkJZjPolHF8iTqcPv1ZFESzj6KEwknjgTbBat57j+YTGZ8n3CNG0jdk43hOvcXE8kbozhGriPMo9xnkc6FkMlHjE71U
# DATA y/xuhepgOVGFp1qKQ+sU5ze6B7ltsM66krk5vE5edcytMOnyy+UHJqI3be7+UL7ziH7NhB0e19SwnqjNrRhMHWBnx2K7fsQO1t4j
# DATA tj5ROJXcxcjGL3IPDpksigqG6ZjGE85HltvPFpiplnYra6QmgjCHUuLFCl/n4uq32aG5pmU9L8zOxclwnB1nCdyEJaCBO1c0AF4T
# DATA 5+atDf43MvbvNPRfduS/nYFfqudqPuQMnhevdd0EjMfKAUbxFF+9Jr2rIA963XSuVhJV4VGepXipAt9EkjWZypuKpySwvXR8uhhP
# DATA ORQ5YMIZtCuCRxVZvhBJHfGE8TJLrNRCJX2B3F4o/6wckxuFxwlGBcWa0THGCwRuwsMpPagtBnWu7jC3F4RYBN8PzIiTcLaw3WKD
# DATA ZO4YO46x4xg7N8nY2XVU2Wmas6uVfMsm/1Us/usw+B1tx9F2HG3H0XYcbcfRdhxtx9F2HG3H0XYcbcfRdhxtx9F2HG3H0XYcbcfR
# DATA dhxtx9F2HG3H0XYcbcfRdhxtx9F2HG3H0XZeJNpO0AqvStvpjFqjwUtE21lde96JucO5q3IPuzI9fle7XVBIazVLud5sd4vcnCjq
# DATA jhTYCIcbKXoDDrTRZhmQAYcaSDAsleE320WIT4MyfA0aqdP0mkHdA93Gb/UmfrfuBe0Staftt1rd/iopp9nwmn7vR36vOW52j4Og
# DATA NfU7vlf/kV9vjJud44ZfjMIgGDb7/TWJaHXreSL8oGcS0SgGEPSCYWuV2EMZ6zU7wVjlokXPMQ+s0HPaV6DncI216DlU+Qv0nFaz
# DATA G16FntMaRiM/p+e0g7bfGRp6zqDbHw17OT2n3W753Zun56g6XuVqbMaFhhB09HBbuGmdo6rB40ild3xS6bIlVVhjag3GhzuTdspv
# DATA Uw5u27UlJoa6C0cLrge3Y4e4ittRE82uMVZRxoe8k2McDpOTg7oH70bd0yVZAPRwu159hXa7G9O8I+snhVwv3VRYK5PhvATDOdyw
# DATA H2B1tFKUpHWeWlm33RKy6mrU0KYbSl4zmiZ+F7tSVZ+xmeJTKO0LbMRC5tmFqRKjJy+wQhxlx1F2HGXHUXYcZcdRdhxlx1F2HGXH
# DATA UXYcZcdRdl4vyk48EvsN6x6o8Y/tb1J37qoRUw1c8luF6+L+4RML0/NY8g2ZcZeDwakjE8yb9ATwO1+88ebqO1SlPtQDinrJ6o35
# DATA LeqABt3Fdu6hggR9jGNc0vLZlJ+c8ukc/dZylGrev1Fn4K1DaXzwDGVNFcpEoapvoB++u23Ev6asMDazSSovTtUWjxZ5mql3/OKN
# DATA D62TdyYZ1F2qFMhEt3TOxx1Bd0fQdz6CXjwQ5s6iu7Poq6cGN+ptvghn1Et1vNBabHEa9vyxAC0qc5arpSjh23gYhVkB3cInoqFs
# DATA CXIRjzQZdWdyTlgrqfBWutJp2V3PoHMSWJ8RYzmL8ylJUHoVXKhz0ePrs+wi4rfmMKjaZbWqX69sV1RB/qTU4JVwuP4x1zM3V3i7
# DATA LeQ/Iw7HRC/OrKzerPJuDGKWRpfPRY136w7TfdpPrSi0w6LE4U50aHIfi7tuEnRXXSqH9T31efPdcryeVe740+Y7uc9VMrODaPN9
# DATA 0m9z+vnTFlF5OWiq5dzFDrXV3DHEbNFyL9QE+M9tWdf8F3jruavT8wD5pPO8nGclsU1265teQKxqrnnpknPjn//xP5h0lCNu5f+c
# DATA JUrR50zCea6/qpYSeU9auoREAmy0hKUYZlCCZy1qqJXGVAsZyhTO51QnWV+XOma0PprEzhZy/B96rAvoH2kdWtaq5sUPLTJ7QpVb
# DATA HRZXPi+7ZeYnn3XTyA9WG8cZLqukmJzRRy/pAvuCuabQvRYIoKzaeqkiyivqZQvo7//b5gLSlV6K5wMUA1XkTBfQZycJtdGUOjZP
# DATA n/LLlAlCfdJyBk8kDUnzmvcBjfIwcqbJsQhSUBpYcADCBkcRd6soINk/rMop0uoWqrSevVRMCm6tXEy3cNli+ff/ZXOxqC5GSkXk
# DATA QAdJSpMR03JmaiIsl3ma02dNV9ZVlk/ePETDGorpIAq+I+rDkxNVREU7kqXZ2SwujIPW5XgBI/rZS8lO0a0VVN4vX7qH++3mktJ9
# DATA vBTV52E69Xh3V97FneCawHGGx9DCppI5ooLh9Qv0dZEM97OhSGlErB4LneloBgiOlICaDfQjJnfEC9HkwO5Y+2emTjx7+eTJuLXS
# DATA eZYR6P/5p91HoHcwyEapDAmWDviU7WqKV/pQWdrcpMIJq5eH3nRJ488kTLFPbg75ZGS09yMxHtUAQyYSGAbSbFDiz14Shei+DE3l
# DATA P+7aVB4ko4XXR7UPUTp5t4Yxvk9ZNIWWDTRjBjTyYHLAitDh8Kch9ueoGp+hsFK2x+NpPMF5A+QUVCrIUv9yGYtaDVQQWVhFClAr
# DATA Ql9DUykk40oFVDQCxaNpG4HmimT3vY8T7XvUmkI8+1A+wSQVKiMG6IQ7cV2wSvjnWdhBr4e4i4NzO1faFVxpznP2mnjOLsvrfiHU
# DATA HQv7L7dju2XOTQPpAls1yaI8YqfWRnL3C6oC+RKJpl2kDW3ve7wJivdqK7l2lvdaGdFNRO/VlKvbjDq2OF8wCap5vpHEZmdSRXxH
# DATA ogZ5khjHRe5kUtQ+5RCeAsptZP7ygq54y0zwpZAFpGCwM0KSkJW1sNfUGqXPzXUy19O8khb4x/B0zY4ADRTAuOj2GClwS1lQg2+U
# DATA ZtaBkROFWZ2LitpKoh77TMhiXUhpYd4D69vDRlzobR4X6oNsZpPM4u2q0ESd5Q1etAt1biGHa6+T8WgH4cxHZz7ubD7adc2tw7p1
# DATA 2Ge0GjcaqTezDvuRcD9tpeicePh8SBW3QQnnvT+oXnxssLDMqX7K8drq1pX1wnwhKV8e27S2aC9v2Ks1m+4vOdpLSwmbniq4fws+
# DATA 7U1PlN2UZTfrpufK3rOyV3DjymmhFHiTFWKK6jSMh1wfZKHpu29p+UpVLOpe8Mtlz6mwxNU5U006Ly+C45C55u/ZFpWnuffUqds2
# DATA lbjM9Kt3oIjzpoLpaaEBvbwIcSw0LZiEOkdPnylLNZnYb4nmejyRGSeb4JGeSRmIJLUfs1q1ZFOBQqNn8Ny7uiNB32IPz54SCOEJ
# DATA gDHZ1VOfwxKXvkfWHYfiWuZ95RQTCHdjgUY9cSdZLbh83rjeaZzXtXxvITieuo+iki6V8MUM8FfHSrbggCyFlEwLbMD/oCB+35z9
# DATA hf7989lTYPieevjGWL5vwPr7y9nXgPKt0gH/29lfmfj3e3X307M/egwK/N3Zn87/r7M/nH11/kt69k8q0D8qhOAfz3+Fa/TbN+c/
# DATA 9+gLiIQCAgSZEHGQ5wAsZG7gXx0M8GWw+gt99yg6IduBJ9HzENK1CgKAXn06gnxEH5JdGgNCHR9WZe8rrG7SZ+aB6p77utPSffZy
# DATA zq9BE+LwyMgYiP8kWiznWxGA9yF14Q2XGTa7UHt2AMCCva97idvm/60Wy83R/9jCYsJKfmuhvpV55nei02geR2Rt6PvfUxc8qAwB
# DATA oZ2k14wBZPUwRkIvFzz+qzNa1MQcCXDXIrx+FCD1NVgEpzY/i0fodBgGzxBnbJdLk0fQ0In47LKY8jBYUQupcxsssIVhydL/8mOm
# DATA Np/ovSe6oolLlSxxZtxgGhcfzVawgLtXy822zkrDe15wwN0T4yCBzkK4PgtBowGvZBi8Hk7AWzMKbsAm2MkkuLRFcLsGgVTRcnYY
# DATA M+CFaVU3gQS0Uq2WvzZEUcPF2H3x8NQ7SsPhMlTQvyxffYCMYXGNjVGDxUWJU9n0iaX5Y3Y9Ya2NZRGzeTTAyG9MsZ3ggGZcZ2Vu
# DATA SnAm++goA0fAl3EFrCajKion97NUh2oeVGxxfDYUywE+OibgqTgothqSP0/pUsZrqaq0lfkmi4QcWb7RZF/N+zgCQE4uyKa9B0uY
# DATA IWmyPBp7yxkV00LOsPOLM4cRdBhBhxG8QYzgzsPQTpOkyxrUtzpHuMoU4TpnCI4q6KiCjiroqIKOKuiogo4q6KiCjiroqIKOKuio
# DATA go4q6KiCjiroqIKOKuiogo4q6KiCjiroqIKOKuiogo4q6KiCjiroqIIvDFUw6kTDkX9FqqDfDaJm+BJRBcsr0DsxBYvwvF7Tgud1
# DATA 6gae1ynm63AQNYejNfS9dmDT95o5fa/d25i3ecFM/XrXC/yO5/tNr9vxeq2q3wo8v+lTedHVoON1uyUsX6fd6/a767B8hSjzPszV
# DATA +NILLeSh3zHxbRUBk/WoPeiseT4Igvz5Rj1HJnZ3e74hr1T51Qry/Nrt+WbLin/Dyu8d39/qWsjHZqNz2ff7bbu8/Tz+jR3jb9cX
# DATA KVt+vLnb4+2OnXwb9rhj9ssjKvnt3mXfX8y9+g6vvwwkUhqJhkRKX2ZBIgedcNjxi5BI84iBRAb1Rr/VK0Aig36z027lkMhBfVgf
# DATA jgwksjlod7vNHBI58oft7ujGIZEz9OfV7OFpvs4hRyiPo2tYdwgsV4e2udh+MK/VFmHB9JGX0WwG0/o1e1hUhtvB1KBdVLTvrVDs
# DATA O7WVsxuxshBRveihuIhSgvoelSWPd821WtuiGnp2tqjbPL2rpZg3etaKffIFR2sJ6Lhlh4LajyDpqGb0wzQ6gOjlZkqjyYdKKblb
# DATA TL9yIVe2lhc7U0yRiT24Uk3EfAp2ySkOwVEgHQXSUSAdBdJRIB0F0lEgHQXSUSAdBdJRIB0F8jWjQK5CHKfh0V2YetSr44wZJfmO
# DATA fNUnWZAJCrn4ka0ogFb1Jj1NdeF9bIjc8/ff/OKN//2PNSYe3l+rM8DP7En44VwOG+CNFMy+CSdAOP/rKwnnHbR4Pr40DWfLUcg6
# DATA /XKqS84jUnOey9E3HKoKBbkQPaIb+fAnmQMZDW0FQmLhjI47fe9O319w+n7NES53Ft+dxX+Ws/gb9Thv9Iy+KCImfBA5P+4tw8p3
# DATA jT7n85ePuQ2tThntIKNqojDiA7LK6tybTvcVJVG30Bk7QHJBPx2E6dbMBaNo2WkVlSSn8UzWvepKdZJXgZTeJPbb8K+beYpmULar
# DATA ymXjbQViom5fM7EPWusiH1hR7xYiXq+1NkfdjPd21PVFVY/2htFRGtFU/YIUWGGZFNjXTAraa7O/Yee+H2zJ/I0KnbqVoEZLB/Gy
# DATA qnNaIy7zEOnOVFqzPuJeMPswb1qsbzL0qhhH1vuneSO3b2CRfZHPl+KOsoV0JfKk4BlNlcjD4Jv7p4JyLPRLWneA9St0aNSPkBGo
# DATA DETM9+ZiNgxjzP34MWgIs6TGSXgqA48UJ4/9mRbWOFqGNOIsooilwZWwxZfUwZH5haP1ShRkTYx2EPB89Q6sl0ZFZ1k7y/oCy7pk
# DATA NDmr2lnVBat6M1vpRVK+KraC0OSXEb/6Ifh7Ru0Iq9i51hHrycAlXjH6TYIujqZxNmcJGu8zQ1dh4511cyJ45k4iJrNWPL1nA6NS
# DATA NMcyfkqPoP6ULeoiwXFF7MrcR0P/+7GSPhonafyzxEjeKAX/0MvCEfg6UUpGEUswmVLJ5kmukM4SRSwapWYRUZid8sg7TqYRRHl4
# DATA NkF2X0U4GSLFg3tptKaBNYYJwZ1VRrmFVQSlBo6tChumDAXbZhjpuH8IYZ5iB4itE0q1BzzIvEM0NtFyFrJhQ/Wq5r0dzxLUIXpG
# DATA Y3a1ITCLHi3YkOQlFWSQ6keTDG4r1cMqE0iqwJRfZoFC1xkTa9P2tzYYYZIc6RR+ihPNUm5SrQpzthgLslD/iHOxIsNdEAmvyalS
# DATA y+ceP3soNS0fN/SmSJF/zVj/dQSpdk6EViRl6Cnjwjw+CwbcNrJ3kW1L1Cci5yWtIjpVklkYqedT7sIkjaIKJvKz/bw82AGYG6fh
# DATA wgiG5eMR5QVVWEqjTDiVnhJlGXa5TrC/hKsyjtCkdoU+zeAb59g8ogAWZBzGQ9Bga967CTdJDH9GmQwicMpgHKHzS63YrBCQ2LK6
# DATA UPfVxKUfqsJeWgr6Zj3FMEnNFRkkTuWCFtlXk7Pi8/xjceqlF6cK06o6T4FUf5b3ZUwskJqbQ+2VzP4zvc835IlJeKrQ4UVTJaOe
# DATA 8HrfGfAQyrieYTyV/ud634Btivc+1mMH0jSPZoN4cr1v4T3c7+kWpJfQ7B70et/XEoDFKDJ7hqjhsS05o9ZWfNed5eTGGLSv3vzK
# DATA kWjd1Gp3yWA3kXrlJ1KXRc++WBLCZk/vTTBMy5l97QTTNUrHF/NLJwWCgmgAsxuyqCu8Ba/7Yukov4wSojviFrzCxnJthOdyq5Iv
# DATA ZrJRW5kc59PeincEheZ8ToNZmBdiAoytVmYeOqApsK0fK6qtmDRli9KsNPcmlDwJ2v4WAd1CrSXr5Ti6WEgadXIazjXIYacyWFOi
# DATA n6QRe9QLathZlGWaVfgamW454aofPozSAt7qv559DerU+c/P/qIYVH9gzNVX5/8n46r+p3f+98BMnf1uFW71n0CrYiAVOFY/P//3
# DATA 3tnvz39z9tezr89/TYE+rXhn/4Nu+TN9/yW+e2ffmNBAzdoMvPoluFb0X8e0ehlItlSH8TycDVTBWAI7ZNyzDBFkbcU8EgzhmoBc
# DATA ueqcMCcTl8aMnRbcL40UmGcolxL0cbK/Vhh51HNk7OnairB6Gxto0U4idBYOYGUboNIJ3Da9qlwiN8eugiT0sPTetcgqrmLmxne5
# DATA wt0MrIpGvbna9Itaik3CyTA85X2EVD8eRg5YdVG5XTun6m00Ay6BeZTirCgr1uM43ogB23L60iPbHVomahXE2oKn1/shln+URsM4
# DATA gjcajALqU6MU3q58OUX1i/GMzKGl5LA3XWbSn4kZdipU70E8j1YoVrvU1M32TKnpPS961S6JcNwqZwVc2QrQmKorDP6vhefplgb+
# DATA ax/3dxr2dx31b2vQl8pYTL0Z5J9XY7kJ+lQxid44msxhnZDhAQSziVye4HR8uhhPsSIrST+QoRZC7zjhsuAPQEsjW2R1lDpM0Iw+
# DATA IAM/PKZxMtPZkYq0GW89wJpsumQtRYr/NDZcoO3sKbU7Ah6mCEvUEZ/pkoGYY79hMBcXh2UQMJ6Ix4JMTIgq2v+wYF7wPkC9iUKh
# DATA gPglLKAA1BT9gz0VsPP0GvlykUAeasCkLgeYcoApB5i6OcDURePITnOZ3U3dW7Tar2K0X4/N7khSjiTlSFKOJOVIUo4k5UhSjiTl
# DATA SFKOJOVIUo4k5UhSjiTlSFKOJOVIUo4k5UhSjiTlSFKOJOVIUo4k5UhSjiTlSFKOJPXCkKTajWY76FyRJDUajVrDwUtEkiquPO/E
# DATA kbIzJWh7jU73y2qz6ne7nt9qVoN6QH99z6d/mj2PvhZzaBB1+43WKg+q1/ECUJ8anl/vTqt+QP801dcSCIoyuT7orwNB+T0JmNIf
# DATA 08Ct0UcNC73UaLWtolccJIESFcFVUTOMWtFKRJsd3wu6lOyW5zeCaaNb9Zst9W0lnlG/P1obz8Zq/aq3vGarNW7X/Y/8ZuA1u/64
# DATA pfXiLAZWqxlE64JcrbHtJsW04f+o15zWvaBVpX/87jSg11CxdPG5GnTpy+oPpZd2u+1GMNjy0sugjqSFaNSRNDYLddSvd/xgWEQd
# DATA jfh/NuqIvoajegF1NPKHo76fo446fcqq0KCOhuGg1WvlqKNus1X3WzeOOuIdJlU2PWyWkIpscfbpYyT05L/UzO3JgM00kpnBNsgP
# DATA j1z5m3egDxWccG3jhJOlt1VAkRX2qkOeR1jZNkcPRQ93hRNpSyMoB+BdYrze8tj2wXsjhMgqQdsX6IkJvTk9pcLtoFQ7qmiL+bM5
# DATA OY4k5EhCjiTkSEKOJORIQo4k5EhCjiTkSEKOJORIQq89SWikOEJ89IoSXDm5O/qOXBqfDmX1ELAfMm4qmfkpC9mi5Kun5uppRD2y
# DATA uqzpQ+8jXCYIjd6kHDpiPtDnFEO5eFIEEanfH1Dw/HO29ucPZhBFgrFA7+P7Ttfe91myCCdyvo/v+ihcjGvsN9gbvXnyZvbmqbrZ
# DATA 5gzlJ1ncUWl3VLp4VNo61+QOTLsD05ul/F6Ag9Q4kzrKq3l46oX4vSBvvmDlE6nPKAEjEY56U8HPkM2bTJKT7Wd9p/EjPn48T5Nk
# DATA pM8fQ2fcNFQaf7EVZZlG2TNom9OImJ4iKQvKEqRPH7e872XLOTrVaKhadJwZ8hFZNgpslNKAh9oJOb1JvMAiTkKTh4yVsAVkMkiX
# DATA 0/4htGHiGZ/Hzsyh6hGcvcd8fvdzuHALCiYpa7qLgnY2SBJ+YrCcQ2ZbzjVvU9B+BzZEeir76DweovKkjSCyDhVABMmlOouiYaa7
# DATA M0lvtkjFXKZyHCeTIZ91RcwpsTQHZjlwlMoIvx1RlCenLBRuss2UnSjrsEw6TqVrVXROAyZyk2SBpNOlfnIy8cJJlvDB4K0S4e9T
# DATA 9eamI8e26a1RahUeCzb32drk7NI3x5k+RX+CuojumcV9Jjjfi3685rGiet6TD7AhJYI8ejzhk7k4G5/VvHdYrZnrrqcBNagOFHmE
# DATA itSGQ2wE4rDMMUSl6h8uLhJ155zjOJ/QQGJ0BbEdFeffPRylwcuo6YRTfh0NdFw6ShJ+sFxI4WJbzVydBhadeHPeG1cmsaJwoVr8
# DATA DDL1DMfJjKL5QwlP/CscIpmGEztLYnOeO0ynV9M1f1uEqJF11PgvLWyORnjdyuafIvNReCM4p6V3ugFB85xtKYJHKAo2RL1cj+AG
# DATA NM2NMiMbNTPV9tDNYsy7AYnz+9ztG1tJqUncnhL4q3OQOw/EzSjcjKI4oyhXKTetcNOKnacPG6cfNzeteICsyHE4Eh09pXjhtQFv
# DATA A1EqjjS6zJ4vb+/oIiymfsB0WOZCTueoXwVIWt+M9cxde3TL9/UXb+/bF0XWftBEuHAxp3h218W52bKi3NuVoMr+RiaUTBY7xFLd
# DATA niNe1feCSbUSNTszG0VC6paoidOTfi54JXeIpH7QxNJcyO3aWueiiAbbIroRhCrzV4xWVkt7eWmo0tTirCh2ZDRL36e+hVqHd2Tm
# DATA 4hWv3f22Z+qtNyWTOvMaTXXPCfzTNMuniXR0lKKj5Kc0MgvTb+Fm8Y3cHfFXpcMmM1MDOY1ZrTYemK4Ob4weyZqJnjJgGQyTeoRV
# DATA kjJjeS6rL9MCtpmwyuRpWYXApD+flkjs1OmDSKug7UA5fXVsb0ffcbb3dm++M7RfSUP7spSd5yyEyjuA8w2yqwaoDaFh0cFQe7CN
# DATA XqgkYTOF5rnKp74UsoL832tmGpWEXq+baLQilbuWZ7SDeK21jzqXsMW3CMKVSTiqGIIOW1nLbKwMrFI9xU5xKVm1W/ytcePe+2mM
# DATA dRvsUmQvIl0Coz5+BBuGvf9ynotph3HR3KEJJGaB0bplF6WqKUKmok+qDjLwFi5l8hQNGJqWWh5VY7WY6NrxfoA1K8Sc7LtSzEV2
# DATA 1yyqUOx4/cK0CdEY1csyikGK42TYnm2tFrF8Ki894Szilgij2e8YWz7WNkuY/svxfYCVILVAp6fPUVEcNSwu7PGSycSs+lEcFXwS
# DATA KxBYBNscUXrZunx9bbQ7LXIQGW4DcHgsdtB/PPv67E9n35z/4uwpoD9nfzj/DUN9QA/6BTN8fk6/gS7021V40MrDZ385/w1wQ784
# DATA ++v5z8++Ovs9/fhrZhD9seLRp6/P/lilJ54iaI/v+YbuoXcIWmgjTIhCx1u+ojfQjQ4o9OJb1D+EfhmvE3NvomhhpxVZEMQl6WjV
# DATA 7tQ0OgJ/Wcs5y8K/qq9mcE9ZtLlAmabeeCtD6J1xKKoGlmS44whZ1rXqEm6bJLSuXG6OJsQbAsbJ3Nz4ubqwnik0ivNu+v14YTzB
# DATA 10wTEqgx2wviK7KIPq87R2iXErt2mtB9T8DrAIFXF8t+ZEpePPgx9tBOPdkJXvM+SqgGzAwIkQrxGHrvkPTAGgFreMAsC9VmlxCf
# DATA J7LpI4X7cMo8RnHWsfElsEaIxJbhQdur5GYjZk07e17ooO1JcNAgN9JfZqTXnKArDvCvh+vstgb3GxnbdxraLzey3/zALtVyNQfy
# DATA ja6311puAhSUpwwiWhRAthrnBTxu2KypN//p+C5N2vmQE+NEdAGCABPz78w3wRIY01bUllB+yzScUeoyk25JrQleMEPTOXVhs8VO
# DATA 2CDYVwsc5Ec+UEijlHq7fNCPZblfL2whGBaTY4iRIQClkWSVQSKfClC5Yo30CTA/yUjQxXgRVUTvwQLJjtnjEY88alUPhYZyQh0F
# DATA 9gyiDfIGgxR5px2ijh7k6EGOHnSD9KDdxpQdoeYX27y3bLxfxXZ/VtPdsYMcO8ixgxw7yLGDHDvIsYMcO8ixgxw7yLGDHDvIsYMc
# DATA O8ixgxw7yLGDHDvIsYMcO8ixgxw7yLGDHDvIsYMcO8ixgxw76IVhB0X1UX0UXJEd5Hcbg1b9JWIHra4778QPOjJJ5l2ERdbMsBUN
# DATA R/VNrJl7bw3iFPa/gH0CSYgC+3RYpIHlDXxfEYYKt7frzQtutzg/FLZH93j0W9Xv0d86/dtrfZ+uT/xena61vcBv0rV2tdOrBs1g
# DATA 3Ox9FABY1OmOO82p32hVm61xe11MmsGmiCuA0Z2jQgVqBj4iQ2+YVn2vfiyIni3ZGI36vfZ6RFJ9pXpSnFtBfdxu1j9Cqpu91nGz
# DATA Pm3Wm9VmnT6VEUS9sNNvrws6uDwNSOq8pgFJ87FoQJSMQadRpAH5nUa32bNpQEG92W0NCzSgoNtqtMOcBtQfDZvDoaEBtRqdfjfK
# DATA aUCj0WDUHdw0DUgZJesdHzqtJVtLjUTYuFbdboV4dDOGnfzeMvjHTJTWTYq0Gw1z3Uqz1mT+T8D8n9X1qHYxUtq4sbppsV04IZTj
# DATA YVo9wtQYPIv6MDqqWGvv9mcv6M0fVb7VqLc67T67/fYrm0PqXTIoHeVsHg0uSyXSNi+8hysmlbUit3lxXC2Fi0+4mtEP0+hgGKYP
# DATA N7OH8hyu2FHfbHOUzF6pQ2w7OZKQIwk5kpAjCTmSkCMJOZKQIwk5kpAjCTmSkCMJvbYkIUX6+cw61pWf5y6e4ypjeIQbJKe8KY80
# DATA XQg7AtCMQOcZTGsM83knmbIA+sohbz7ehqUkUasKcVAlmanja1qQtnhQTNqoTOT0SQt3xtmdcS4ctXFHnd1R5ysedd4oPngzR6Df
# DATA j1nrgs/SsguyfHpWH4V+0eQ2bkOPWw0uqDpUX5VkOFK5N5heJNFsnjUdVn7FiDR312pzt2yRZt+vF2WaW1ukrnnwg6SL6r34wlti
# DATA yxoVZbknF7jWD72VcGdqS0i3ebnnU+r7FF6I68lbdxIlErjmiTZnF40t3h1vkUYPWSvywsda/CLbDJjCoGH55OKzdyQ1OwhVv6fr
# DATA J6qshyr78qpUfxSF2RKi0ThYOwjTXKD6wUIk+agnSZKF3CDHmiHrEx5B7Bn+qBMas2reD3lwm0THVGnQAaJTnaqwuRkrOE2SGuGh
# DATA NCFzsuZ9ygsAYhrJA6y3qIT9aDg5RUFTQcSLgnw1YFqFY/tyjtRLlzjjjSPXIQ7YQ8PRjOfQDySLjeosF35Gs7NlNo9E/5AVs8PZ
# DATA coSBOMVcSgIEF2kYj0a4suyznnqMcZoCY+zOOltPiRBQEhY7C1y/Kud8nby1M18t89XZq6+FvXpZbevnLNnD69r5Aux2bev7NBqx
# DATA 0cgGJNuxWS5FwRyFbIvG9W2L/bwUehc3IWu9Wq+vXdp6rabTVeWt80V/bY6JRaFsnwhkUa5zuag1mz+nZNIIUJOXguh1Ne9t0Q2i
# DATA WZKI1UThDCbK5xARErmXDIMbY0aF4MjVDWYUWV2xFn4mGy4hm4eMuof0Bk0MuVzF+YEWYjGqTsYd/nopnhRyxhlDzhgq9anOm+e8
# DATA ecW+c6MV9ZwFDZkHDHBxMpmIzn4Z2K3aSZjlEn41733hdLOVtE6er6DlN0+TQTQEjVuk6JL0y2Ukvpxn4XPfjw3U2dB4FzSCaibg
# DATA NF4IalpGUo+1XDgGS27kR+HyiEbNT2kY1rTACgcgZoks9yi8AzqMcDSCU4xdJbnL04zTH8ww3i+EX7tUtIho2o+GEEEbRv2URmSh
# DATA IvMQyiKA2KG0FWUto38uzyg44JCqAvygrCmoTINMWxdQjoO/JhVnqRKfJhtgOIn6YVrzPoT9hGhSJaXMDRUIbBiigwESoT8R4bUx
# DATA C+OtEzLkj5mlWigu2QzU6y+p4OMRdN6mEdb+4sFWGPmYVa258swW8OCwF9kk+XNAOZLRyDuiIUsnUfZJepMlZeoghGIj12Pg1cOT
# DATA 8FQcUzqeqgwz7dbh7ONxgIJRMad8yUSBG/4lVuE+VLKGkMJM+WSBqrimOhfAGgvUH+aNeH2KQLTR66xSzSONjC2QCWc+eC5UDcEp
# DATA 07LIjEko8THIJCz/FE/o54r2Q3ECctjOIEzTU1ZuvE95FrLfTgUkhHmBx2mOz3HIknx5Jn0cxZwq8RMr9Uu45I6SZGi52+WtCTU0
# DATA Gg1H0taKRXg12Dfa8imrPlIf891Lw74Rt+uGfYtdHksDV/qF8Qzg+Gh4A9Dvt8G8V3KhauvIDTC+Py+pkN7Imxju/SGahvQxNK7J
# DATA tpxMiDnX+zY+BfS5oSRihWgexqn3EN7icDV1N0kUfzWmOhZcJgnT4RF86zZe5j8rjMw3DHUBHeZr7+zp2T+d//z8N6s8mf9K9/3h
# DATA 7HeCfOG7mPwCKsw3Z3+mj18xS+ZpxTN8madnfzr7Criap/ipqp966tHXr3RQdBu98Jfnv1JwGYrH+d97zJj5Hdg0oNA4qMxLgGmc
# DATA aWbXii9uHiVAQKuReyEC0+/o+Zr4PY542zYGOQUNY+1elhfOyV1m4KPo6aFwORtupczc51vyNzvGTGE2Z3qG26bMrJbLzTFmOIHm
# DATA ru9BSJzyejIq3zeE9rMBemG/7yINT68TLUNtICMbOxUBc5ppwBrjmRgKwsFlthfVtVNlTCc0jMmM5xN7YuqQ+YqnIHIfP/K4Xnif
# DATA 8vYAcdseYX/kuk3lwj6ERrtW+kaZzaIFa5pj7weN4dkKQ2Zbzdtsp6y0oefFj9kWfUePcUP6Mw3pGidzpZH89fDJ3t4ofgOD+E5j
# DATA +I5D+E2P4FIXy8nOt00+xxZzE0iZckJzsozRnMhjTrkZhQoxA/cbyw3A0zWjIs1ktRbJMPwMGVaBnjiOU8bFoLA0VoZSHma4iCPj
# DATA hiiM1VAZWC8BkTmFtcW+XQnxSLaZYZpAH/sT8bgdpRGfB5Bs11vdlG+dRn9IIfD3C3kkhxj/OUtSy2YoYkai1MFiHCzGwWJuEBZz
# DATA wZixGxL+Qsv2Vs3zK3Gqn8k4d3wYx4dxfBjHh3F8GMeHcXwYx4dxfBjHh3F8GMeHcXwYx4dxfBjHh3F8GMeHcXwYx4dxfBjHh3F8
# DATA GMeHcXwYx4dxfBjHh3lh+DDtTrPfrF+RDzMajYLh6CXiw5TXnHeiw9jZ0qh7fqszbnQax0Gv+X36XsyRfqfTaQ5Xs7MVeH63Thna
# DATA OQ6a7e/T9+JzVDe7fcVl4bKUspKCOxUOS1DQlWj2imXcbJYi0o96nXKAQdC4aoDDei/otFcC7AbXG8NG07/eGDal6lxfDO1CobK8
# DATA hjy0CuWSAW4oZatQriWGdqFcSwztQrmWGNqF0pDAr6+lXDLAi1vKtcTQLpRriaFdKNcSw0KhtJrX21IuGeDFLeVaYlgolOuIYaFQ
# DATA riOGrcBqy71iKfuNUojqQqpyvzz4t6NGCcXV7jXD5lpY2jroWKvVsKBjEn5qkGCWkaJDXeGnBa1nC6DV7VkBtHqXD6CQhF77GZOw
# DATA WwCX4ZmJjaZ5ZmLuWTyzsNluNqIiz2zE/7N5ZvS1F40KPLOoOwz7w5xn1um326224ZkN2wM/7OY8s+6gGQY3zjNTXg+1ocHMhMQZ
# DATA T7YkOygs74VepDbzsy6vVK5Z9C+GXOaYfS8iIzYOKxKT0l6UNcHZjkhe5CmGrtZ9L46Gmb6s3yWnb6fJ8VG021JRa5fFaSvU8qqz
# DATA 7TPRdaTodg5kIr+yeug3rEVida8fFL0wurryHstxOExOeCEGK251T9c5K2977LDgWbGZzW3YT6cnsSq365sZaHaeXuDRsHKrVCd5
# DATA shw4EJoDoTkQmgOhORCaA6E5EJoDoTkQmgOhORCaA6G93iC0x6p2x1RwdxXKDJ8p0RVOkrqIo3vICLldVDfvUsdGdWYPVSu+Wz+M
# DATA 3+InDuM339x/jIt822E82juJZ2RdkR12Ol8k34UR/ymgGNMfcTj7j3ULmt9l0BqDQPaaQa/Za3eCXvsOR2n/O/xHRaF/FzbgD2n2
# DATA 3gik4/X3D4fJY3lH+RV7/f3DJyybudf/cf0n9+7Su/YPRfINF77NQb/pHz6JyFhXWnBWXIT/xgHuqXjs091KfXS+pFFPdXtPJHqo
# DATA HHfVzz9N4tke91aUg+DDoTG8qX6UBdq9vbDSp+II3+xXyHrMLXmV2kl8d6M1O4lRMJPYrpB3pXlQudGbJG00c8Rr2caXGQEOkKPd
# DATA z7GVYDbcm8T7h5JHxd95VZom7qorvufX94s3YAhW8XkH99bk9DRVticaWWeOfjplFaessqqsYg4DO3UVp65ySXWVjaLYN6C68ink
# DATA uLQCyCRhvQ/W7DLCK89XyOs26HRsCtBV8QR5yYgTcwGWTj2U90jqe0FNdoVI51tAuraNo/O3wOjYfEHVxwfMP1AUJRiduieH0emH
# DATA VhhxbQnqkZhIm1lyPCa9B+/6RXf6ogZMFuhFN7LC7mcn0YQ60QvuDerq3hmZwKV7d0fXcfVGK+cSfWmpdX+rGQ0yHmVkPURDI7Vn
# DATA 5HXIyDKyOGK+l6V2mCS3m2wPi9h4WbJMwfIdCU4F+ttiNULDIefTideCjMSZkvGhJJ566tC9EYuhd66oxYwb92z9H0pTgwpmoguF
# DATA LTI7N62NuqoEJjvR5l4FxZB8LHFGpzM6V43O3LpwVqezOrML7cnnpvX3gFFDHEl2cQM5iupvjE4DJJvGgzSxJPCWbKEq/buQWtds
# DATA ALrFqvadGRTzFqUGQw0pYSm5QTKdRukg1mMgW65phJUWbFzYWfuPUza/90C8Vf1T+Mwi7DLBMGoASsL+pcEUeynW6G+p826rJqpy
# DATA z6Im8idlnCqbQ/+YG0DmCh98Bjot4nBU/GS5QQQHdeTX2p7G5wtOkPpctDytO0xHaT+1YtjBaYq2ANaU3BdvswO1cf4uG3Cb7hok
# DATA IG5Qcznmm9/Jv25+hisR7v4EH7ZYlzIwawtPXKi2SYJBYot5Vyhh7PmQBq2OduZIB+qUDLuDPdayuqPy0s6LEg6Id8OYdi7OYK5N
# DATA 6ZJvD/755/9326SiHG2Vs8oUU1KVVEHSxakYY2Tf8cgEJo+2JHkQomlfFXbXkOeL3v3hENJ49LSwgAZobFT7eaLI/GSwV/Agm38y
# DATA OjIRRROTYZvSW2re2+EspwLOhjIplZ/eBxEGL2nUaZA1lCB97ORK+VqqPVfI3ubm7C3URcll2Mtiw1NCFuFE5/N95snQIDGvSK7p
# DATA iTXnWohNAIt4GtlQtvlkybNnml8uxaJnApLy6Hv34ynyakTWWjYGrIpNb1zyA3ydJxmb6DXvPcAX8ZphnA2WGQqIQ5JFyevIZdPe
# DATA Lpu/m/NWtVydq+jxqetd4IPO03extyf0Gv/7HxtgJQ0pT7B4MAPP/AT4IKpbS8o7KguZ4meeTwXag9NC1l8GEc1Bat4n1GXT1Pu+
# DATA VGypviBAMSeJzyt6cG8cem/bd+AMobhLeCatNnnVvO/T14grMpX/tVXkK2fx9h6ikM2f00BLkwwKItV5bMzZETX8qug55SwwaAdS
# DATA /UJlmkseyopPJn2B3I1KCj9NqNDjmBDKgx9DuxQnAzPWLQ1NIOFMQ6kq8jL6DUsoEjfO9KNYJE/BIzuOE2oh6uFQep4Xo/NoX6rz
# DATA +NfLmFc+9eCtC0EymOovjXGo2FwB2QbShpFMh5DtXjaJ55Sf3Di4bwHojKc3fdY31R5BKKhiVBclVu6avKNoIUXHWYiFxCyZRrhw
# DATA tIy448DT8UwmKtQvLa6l+7j5we8dHpfARIpN1Tbdorg1FieJdMiSteiNM0FoilByFKc0up0gFF2PWcY2Ngq/NF1H009VyydbkFWd
# DATA 8U7qmnBakXrrYzW5o7DxxDTBQi7PHdBTMHZCuhfYrOXMLZorsmxsmyvmimTWPWpgaoFXCwnL+C2momW+UnMbc8OTQqldxHp6FVwu
# DATA +WzLuVycy2UNQcF5WV59L8tGB8oLRVQoHBVYHSknNmvBm8QLHHFmJRRGYoJiqUYTdsHkD/J5Es7Y541geJG1yi/iJ1kHP2RVko++
# DATA 3HuLOtJye9NH3wvH67pyls86ly8Xwol0h2WcxMqRdGm/gwS1Q952OhvoqCiVx9zvZovZc3msAXNYz/EXTo9aiRkH9x6wTW6qCCDI
# DATA 4ezUrFp9PzkBDvlU1Z3venxhCe8UWVXf9d6h+yPqTGEMwQjJLeHvYhIWT7nCzbITmT0ssNHO46Vj1t+PFdFVs6kAow3JNgMfF9pl
# DATA ZHj1k0fRCi+qWFvejxmYyQ5Iyo7lYEGJlGJ/HZacbM5lwjxum3L5nxhL+d+BnDz/rQci5dnvz/549tUq4bJ0519z4CXur3jnv6Br
# DATA T+m/35z90Tv/9fkvz77GE7j3KW7/kyAw6fZvzn5//u8Ar/Tow8/ptj/LrY5j+RKYbF7Gfv9UHUA0fT0SzZNz7glqnuyW97KlTFhl
# DATA Qz5za+VBbsAYM3gwYY/ATKZRI0xYucHBT4alhTFvnt9CsXxbZMAEleEQlkUTThr9bQMsS0Vyc/RK2AHHVnevKh5T0OWn8hOqCpon
# DATA PlVVElVwBo/YtQItebfEOMzYXwP0j3KUKwvGQS13LcFrx1veh116JLaKYUdXuNscwsGmAUGmzxJD+914NIoH2JCPbcuy4ybSDHB9
# DATA 6yyiMOjnVNz9K0TLnergZrOk2LqeF9dyp0Q4wKUb659hrNd4y8sP8a+Jh+aWhvfrHt13GtwvPbbf2tAu1bKQDTnm8rm1m5uAXBbS
# DATA iCl5WEwYtpVKAhDsdL6QoXCeousBp24c9mNe+FtkutToiaMjLLA8pGqQyTye6rFa5sZ0W0ZmMwJPYqqQWP4Swl8Gxb90V8QlstEw
# DATA ATFtoPhPqKvHGTasgSi0o449b3tdwUqqmlQtGAuyIMSxZIkUhII8RAZg5TOrzqO0ylYdlcByyr3soWUm4EZEuUoG20azwTEwHQPT
# DATA MTBvhIG58wCz00zmEvbw7Zn2V7Hsr8mwd3BMB8d0cEwHx3RwTAfHdHBMB8d0cEwHx3RwTAfHdHBMB8d0cEwHx3RwTAfHdHBMB8d0
# DATA cEwHx3RwTAfHdHBMB8d0cEwHx3xh4JhBuxExc+uKcMxe1HuJ4JiFleedyJgW6s1v5ZTFRpEq1illeEN+lxwvIsua3Xa9sybDgd1s
# DATA B+Nmc1ptNj2/OxbUmQUeK9PIcvBYYwX6VrfiWkKqrcS13t4U136/3W2FK3ENAoprt31dce1Zce10t8ZVwezWxrXZ7/Kvxbg2/LoX
# DATA UP29nrg2utdSBzqDbjv0V+LarF9nHWh2rqUODDvhsL1aX5u966wDrfa11IFOu9vv9Ffi2uo+ex2wgqPQmu3OuN2oH/vt73dLeFzq
# DATA UAetq0HsqC/VEDvpli2IXbNN3UZ3B4jdcNQqQuyaUXNYzyF2rU671WkZiN2gO4j6gxxi1+i1up3gxiF22ENVldUNPbo2LX6dRavr
# DATA ss2Z3385Ll3Z6drIl1rb4nTlkPmcym6+1PY2X6qeE+aBrq7KKF+znmZgoqCmXL3WCh0OPjUsOMl/Gvy74cLFM6pTXlfIcFIZmkU6
# DATA nao16yh7VyPGyYqBWsRdWwTGtVf2F2yEzVklsMU2Xa0xji/n+HKOL+f4co4v5/hyji/n+HKOL+f4co4v5/hyji9n+HKs3qhQcuzz
# DATA pER/R77y4T36ekf/KqA5Nja/eOM9dfxvaE5C4rAek8yYyTaI4skeh85kNdHPzGpf0P9m9xe4TYJVPygAm/rGcBgd7pAm3B6f4FkT
# DATA +J1yKByM9WjGI4LBnTkdRHfQfvNBe3fA/hU+YH9Z9cMX5uB97tjarobIIm98mnVGIxRZFhBYHtP3bVqIz/ec/kt2YvUi9Z3cUXkT
# DATA 2oglFYJrFkYs6zhcoIp4XwF6WAyBcpXaUMaBGWmhT5bwxvAOBu9oCShYP2I2WGipfkP3gCbrGKe99+lqApF7rX4oMlGMaFDqClRv
# DATA Ey3gLCfKuaor8QZkP58pxzn0vlQIPI06Fz2ay7RCqUyXVQ+3KimVmhy81zb8glW3HyQ00o3VaXXZ/KrFtz8OIbdoZPrT6CRMcaBe
# DATA CYqehBM5mh+qCupNkBDmJLADPQ5TEaaQyBfPQy9CFkn9wXKBJJlD0GWN8tU46lw21IaZlARTbLiDwCYMD1+GUWik1MOMVRqUsFbI
# DATA eBo+rR4vtkTvA1BvLhE59CImYpaQhq5IEMDMqPDDVAEMkkmmeIyGpsPBpA+9E/RCHF+ctt8SyU/kNWsy8TU6sW6H4mxkZyOXbeRS
# DATA rXKyVE6W6irW8UZr/Mbkqr4XcxtgIyFUQk9awYZy7KGlXXXLmoi3AQcW5w5DcGA9phFyDiqV2/HA+jHTO5kLOeG2Wb8IEdyoiyG7
# DATA AyVYvE5A9hoHE19ilxBefkGE9fMmwuZCHuHW+ghLHFWU/XKU65vjzK4xu+qiau3xi++IZ2r/wmwuUpj19zzOwdo4t64aZe0woxs+
# DATA Wu9zuyDGeQAm0tYlK6/XRtuKtao+OtKtQpw3ApHfXsaToTWiobd4ebnIH8kwLKN7OOejN7yAredSBpzMvRefElHqUJL8MT0Ugcd1
# DATA 3xtFJ+zSZsfxwnhUoYO1Rkj+KGWhOjP+z6JjzbwyEmA/VP267goBXAuBRcf+WTbIa96/IUthyPMe6hmtbpbM/iF2BonqmmZkiitb
# DATA OlJuLJQieTObHpjS0TRDOHDxYtOU7RU2wu3R1RnhzghfcVSvWFvODnd2+Daz+sWRjVWDnW4G7ANDW7BV4IHbobHKtMLjfKhTEqWV
# DATA XMWUhxojcAq9TuytwqiDwOci2YnhVTkR0eZGAkTJlrFgZuQwyCbN1SvTk/OXcsOGBH4flULPImh0Hjp+8i785Bn7UPGEeFM33ynu
# DATA ZJlC4NMWcrJ2K1rOP1BsX3yCcp4bl8RIfrYZIanzVSCS9wuee7i0qcoASptGKKYSMDWNjijHjH+W/bCCxKL/jDB3VuqzVCMzvpFu
# DATA my1imjDLCgTPlWveO2GankKUNZkV3eNpyMxGtloX6anyErMoK/ZAphIx+MyTmfaTq8mD3Ujz1R/dRPLVJbMHUkb5Lck3+atVFOkC
# DATA b/blhhmCcWpmIs/ECs2r8iWL+b3NxawbhSpm4/TPl2RkrwX3GLqgP0QXCyMnFCZrSha7XuXILGS9aAGIUjQvvUjg2SQ5mZyKJHTK
# DATA ysboXDEWmaUeKnPewIcOcmx6xWcqwu1Ju7VCLPQylyzHT7fAjPP+SrdYQY8oieQ0AouVhpzZUImBc0lqEljeTodxSLPAKRuoo2hx
# DATA SuPpEnkcK+dVqFuywo2ZyTwvutDomvPRMrOEQ4PvI8xI2efGHjAsEMYCXHvmtrktobdWrlfugx/s3AdThV3QLULXjbwZs7ezh6cr
# DATA /a9m20ixwqoRoWk2MsbRNM7mrH3tfcg9ZshegkmYHkFWGsqMs0xz6k+SVPpXaSvSuY5CIJLhFriWdrk+VS9+t/r9nbtVNXaRfQV5
# DATA fSQ1VAPVMNQEa9MkZd0b3WWijUWxQ+Ft4dNxEMdBUSq+dXw0g6tHJqLawoRjhaXBYXSm85T16qnXlWLmeFxH29shYS9F1/rupbpW
# DATA LesOw2SYhidoILw7YRKPrIVq5VzTdyjrIQqxLZQyB7L3Yu/Y9gxmNFxY2uQZLBc1j11+Zi1bbQ8YpOEcec5HQvV+Cu0he7Zy3ZrC
# DATA K5Xo7QK8n8lD++r7FHME5iCi0T4eZEUE5tfnPz/76uzPZ0/Pf02ffwGeJbCVf6Y/vwDH8vzn+uI6LOY3Z3+i/3999sfzf2Dc5fm/
# DATA ZSjmnwWJyUH/nq78mvmZf2Rypnf+q/O/B0Dz/FdMx6Swz/50/u8piF/R39/SOykE3PQL+uEP9DPd80/0kqdnfzn/jcNkvhSOUmxL
# DATA Q3elukVV8zjo7EB8UTyE9Wl6UOHvR9jsDi/qAMg6BWo5DtlzFZopgvG5hh68cINxzXvv0XwC84U6UxQWYq0MmlwdeCs/850JjV/S
# DATA EhE/R9C0fai6z7htguZKodwcQ5MrpbkLWwt5TV15AFeIm1S148Tc/oC/ehDtWk4gEnadAM04k6jAeyg7GyOc+Q3BDzqNFo6euUvZ
# DATA 3QA5k1dJebU8nmKqi9BMBVDd0yLiI2oD1GM+1u99FIXZUi3fUo4tAYViugJKjvpK43vOmDPkLeJJpFzWKfvLyUAaLierOM3dquRm
# DATA S6fc1p4XUXO3dDikprMLbsIu0KzNq5gDr8Vy6q2ZAtdvCexkCFzKDrg9M0DqZSkXbNzmi9amboLDWUo+JxpuamYXmsiU4ZtaoTjP
# DATA nGM4MSaKx2kfpOHc4qVno/yXA/j025AZ4svR+MrsYbQYwO+9K44zH/Eti4Eil+XD/1TshCH25UE1Cgo1FF9PQuSTNQV7gBe+KW7J
# DATA sKr8+GjnWcb7yDzewyW2iHYq0qiE5Io/StE6eaMEu61Cs4zm0JsOvenQmzeC3txprNlpCnQZo/k2pwBXmQFc1wTAoTcdetOhNx16
# DATA 06E3HXrToTcdetOhNx1606E3HXrToTcdetOhNx1606E3HXrToTcdetOhNx1606E3HXrToTcdetOhNx1684VBbzZazWE7uCp6sz3q
# DATA jLovEXqztPi8E3yTQo9pWPQGIjPW47wcnArdsJdnbNAUHSr+JWgX+YW94SjqruYymIBBY+wHrS+rXa/le4Hv+fUe/2m0qt2mR/Zx
# DATA tdeotqqdXtUP2l7Qq3YCz+/Ql0axMNrdbqsXyTuKcQ6aQR5nel8e53aQR1nIolbFaDXa0SrKstPz/FZn3O1Oqn6dotf5skeRbTeq
# DATA Af3Q7lZ9v1vtVFutqt/slWqLHw0iv8Q87LfDURisYx421yWlKbEfqBh3LAhj00pKsY4Pu4NBfw2R0e96jaD7ZbddbVJKGj2vTmnq
# DATA en5Q/7JKZdFoUgp9r4RWDKNOs702bq1uJ48bBWxlc8+qGfUiLdJvDprtK5AauelpUqO0YovUSHEZ9HYhNRaugNQYRN1oaJEaw/aw
# DATA M8xJjZ1hMAwtUqPfGnQbN05qxN726jaThgZcy8cltrF5SFsyNpQQqRz5pRlxs/ttD/+SqeGxuZEHocdba4lRfmVzckevf2DFb+1c
# DATA gkOEoLDt86/jbp6DaNP00DLAC65QVe6XAyuK+yuHQpbypEV5Qv825N/CalWzZbCRnda31xIexVikNMucL18utRaw1iMcN6IaL6wM
# DATA 2p5cXwskUwK7+HYOp1Q0PIstTYYcB9JxIB0H0nEgHQfScSAdB9JxIB0H0nEgHQfScSAdB3IUonHf9avCU5RNx4A/kjWjkY8P9Hn3
# DATA k0j5Mxn3uKdwkbiAJyQoVNX3sdFvz2ck42Aq7MdCIGquaoUiVy4ORkRkIZ6sjtPLUXtvHkeDSJ9GxBk5+A/7KI8iBzI/eeNOh7vT
# DATA 4TufDi8f0XIHxd1B8e262y/MAfIH8SNpQhUan2anWPKP5ZClDb4xRx4t0VQ0mYkc6sSzD1dPPeMoKPe86uz0CKHIycwsnESXlM82
# DATA qpbieuQmTjcnU7hG7XPeTjl7F+Vs3lHCVREfNt+H/hK3/Yj+btHMpkFxIfjDT+Tjy6CXbfLgkiKRb28WiVS5KQKRb+MU5wjHujEo
# DATA 5XqQ2CzjkeVOVQXnwXE6H1xWmvKcQsBzEo/kBHOyYApExkMTXFAIxhtFVI8mMIhowpLIwWNOiSaiPIt25lWz5J0ds+Q9rQlKY7LO
# DATA kLfDCXQFWKuXo0uNiS+YM9eyhMOyot4I3mV6GjnFCyQ8rwNzjoZm/KEmSNZfLCfzEdjsOjJGt4NL5suPNueLtChVU5ZDtkzyOjIL
# DATA U5qTejOa03roZxgMCulWLEhAZiCH/8Ci4SoVzYRQBkGCjDki9HmO/v74VBs3z7GO/Ksd68gnyZI1LH66PMrzQ6tNz7X6dDIdYdMI
# DATA MA3UCcwxvUKDYJqRwhgNydSgwWxAGTcZJ0uceKt5n2FCwNoKrJQgdt3RJPyZEep4RvXZvCu8ZP58skV7VneqkkM0v/bm+pLk0Cdp
# DATA cow6QGmm2c1RZNCxvEmOKk24HECF4/7MW86QXN3DQCCYgajAMk2gvA+paF5cfo7t5tMd2w1XaqXcYiFrWZFhmiyhPr6EUsVEjIeU
# DATA z8jC3w8q1nCoexYoLcfSlbJZZgvxhlJdqL8u58ftStm+LgoNuZntJuFuEr7zJNzNuF/xGffGyfQLLdnG+1jMjhahsvKulntvUYMu
# DATA l7Def4nkmm11XdlKaW0OlQvhhL+V5c9W9kVKhRkk2DkkLzudDXRM1Enjez9Y2VapJ/mr6nLWY/yFU1MY3ycFshfgE8x6YcWxIVVP
# DATA msBr/0L+EB+d5uHmBdWte5nknHYUtvXMliqpvgXDwWyg2mKo/fM//kdtRvArx4FI2YkF6S2iyYSnLgo0IYpe34P9mXlHYmWFC6ZF
# DATA DKHCRjOW8XLa18UVeun4dDGeKmuWDVaeGxzF8rNYfixGhmkzRM0szS+P9zxCpEtJI1cot9IoF5wzaoB6BVowQzm64iRMVzR1iwXK
# DATA UCNjODKx6jWU1bKCcVabs9p2ttpW6ptbO3FrJ1ew2DYahzcpvsuAppHS0Wcxd+Q1L8QXNHifvyD8NkMA5/w8e61lZelEbEW2LYeF
# DATA a4U1DVnqp8vvU//LZ7/5irc3mF4EutePmu7MXDArDHJApIyM94ugexsZX6/5m9df1IYCO7JyaZfYmodNdPMrJr6964yu2nhBv3+k
# DATA 9X8XyaJQJfa+fVG0TSAm2vmVC7K5bsW7sTXaynw1C2ayK5VXuaTKR7zFwzSFzEJEoYbde0vOBKs4q+3JtlMtvyT9TyyoqjmN3cqI
# DATA vSNBPCP8SWwrRmnlXYCtSv3DzOwvQeMzxu1H4kw1Ss2MHD4Zx5Mo7ydiqNUusFcnZclbs9JBrTnKxZtZHlitcMLElY0rsvWNTN1S
# DATA FdA7rbyhQvWZ3kBrB6NLtfoeStVySvdje3AeDutJD8IZtIPnlIAY5xTDdM4Lvew5Booc7sqTcSQGfN5xIWUQmuZ+jRe2yOioeQpm
# DATA hxQaoelsOaeuR+kHF8Wl73C+vy7WswXh4jk6zyFsDtc/MoPr6/NfCu8K5Kxvzv5JobkA5wKL66tVAtd/pdueAtAlaK2z/2GFQ58Y
# DATA sPUnukdDtv5y/puz/2koXWdf0Y1P+V2/P/93TOjCSQfv7HdnX5/9D6o04cQBt14K+5+Ne2vrBlCBaQK86xT9BNc3Y8cwqTWDPDl1
# DATA SazeRz3jTFS/T1g3XJYutOx2RXFDj9DYx2Ef/ZTM1kUNm+sMxM77EWYI22Bbn9NdJkIOtVUw/fOe4bZpW6VSuTnWltC+Df+Jt2Rb
# DATA b7Xu/GlGxa1vLFaw60RshQK20nAFtUAoiXF4rQuK69rRWp+EZHTiZ4p1q16p1+s8alAGUBdV8z6hAcRYPUyw4EnXOJxjLVjv/F+E
# DATA /UNEUnDUmYFQoLiiRzQQ4GxBmaF1YXXbbKYUG8/zgmddmADHzXLD+3UP75qZdflR/fVw5t3iiH7dA/pO4/nOw/mtjOZSGwtJt310
# DATA L1IbuglGViHhjPjJFLPdTiZNusNMLZoNsWjWh2UeYidxhRIaA+lDjSamJExisKRmQ/3aURhP4K8chGAVMVuomCyMtqHJ6CkNcHqB
# DATA OZ5lcyQJLlJqIbvSsvKQWTMgk/dR/JnSxFvRx1Tn4F6hi3ymnE+bs39jhhU+nsMumRA1D8UBmwwZmSVmQWbOilOKHpyS8fYInrJ4
# DATA GKqT7JEYhlGGfYhxNsY6ZgivxkC4K0hXPMIGxME4moYe73xnCtecxyKH0nIoLYfSukGU1oVj0E5TnR3N59ubBVxlEnANcwCHznLo
# DATA LIfOcugsh85y6CyHznLoLIfOcugsh85y6CyHznLoLIfOcugsh85y6CyHznLoLIfOcugsh85y6CyHznLoLIfOcuisFwadFTSb9daV
# DATA 0VnNUWfUeYnQWYVV553AWZyxHJceZ5ygmep+QY6i7XeLGd7o9TbneL3Ra66CnHoBI6lUUBZcqlPv9nr9dXCphgQyiFOWoFIva1ts
# DATA qQbHkw/MdYs0qWGv0Wmve77V2un5Xr/X7q97vtvc5flu1O+EfjkTpkGz4QVBu0oVu9Xj6h1MG36r6ge+x9eqcq3q+42q3+xUOx3P
# DATA 7/p20LxhtITn6g67w966HGRcWKnmd3pes+FThcervfq4Vy8FZ/JuJbjeFRBY3IQ0Aktao4XAarTb/U5wFQRWPepFoYXACiigTo7A
# DATA Cob1YTNHYAXdtt/u3TwCi2ZCVfp9p0l7ENBYWfRbFUYaGfF0iB4fkDPcJ23DKeNTJ1gHkGrXyrpAvOXkccllYo0BK3eHJbPfmOJd
# DATA ZYrnD+hRuzwPXDfn017CLnsJZXUQfsI1i23tYiKKCwEyR/TsiY8y5PInzDC4ZsWujOFa6/HRFbXoYdgE7TLOYxUd+I2t6Rd/vyCf
# DATA ii9qIznsVyxsPdn8vBmnL3jNhincZqyXqeA74bi2Vd7N0/pSZV5XJ5eTCyeXHAXH+XKcL8f5cpwvx/lynC/H+XKcL8f5cpwvx/ly
# DATA nK/XjPOFuqBOyEfDQ5v6tcCSKWcEUndX6nqyTAcRKgjXqsN4xEamapj3WnUYPIsxYAXvpWmCOL6rLC80LzJ5qI9Oj6RPNq+9WzKm
# DATA rTkBm7AVTC4qQv/CtkYuh31hjplA6Dt1FV+8wXaNmOfe+/nRf7KjT7M1fcH+4RO20R/nscFWy1E8o+xQVDOWEVW6D8dW8O+g86Hm
# DATA CpdqBecYp6GcoeJSx1v72KNM80t+kRU/JahLXQ1OQn2cGPvUO8GZRWV90m8cQarWnPs4tVPVP9Iv391md3AZUvnk6bqbp2z/cSEy
# DATA IkZl4qBFGtWbcBoQ8RCr//CJMea/eMMEXkPc6K3mwpvUV4HCRteotefHIO/IjTo3+OxROb0quaaybW0vnM51hbdbMDSZw+spILaX
# DATA Jc/2xIYeLNIJTfn+7u/kKzYD0tf9v/kb+U6PUp5+8cZ7jHh4Y//xBstbGd3UFWaLB2yx70mhOol7p6ZwJTUFp6LwaqsoXFbd/rmq
# DATA KxgHrKRIxPosJfdFiOp272Mtw80p5YOsS0hbxpsT8q4+u58rD0gs8dC2Bx9wu+VtXlgU2vhUITvEWLDaXv7UHcRU6xDy0diNAveG
# DATA xKSkEKhVbxe3f+HEJl6Cw9X832smJxRFMa6bm1DWGllLTbisStbnaaxMt3jGrEay3WDMGJUsowPCymUZLOATCJlNl6LhcMp+6ooR
# DATA 0JfKqCoPVxSMkpko2luaHtA4CNmiT0YLhiulEbvRmcClgFts6Hu8MMh647PoEft4lbLGhRyjV+OcvAnBGXfOuNvJuCsp5TjNLKeZ
# DATA dQmrbqPpeFNaWh+IYBNVbDWXV04EruY52ee2FRtvQ+ReeRZ05uqkv6V3YmjFcX0bVNPFU4bL7CwrCKxTRk4m7NFmAALWinl0+xu4
# DATA mA7Rp8mnA3VBWdTyrSJ/2C2ubvuxXwkqjZ/QoKhjtEFSXjnV6F0f8CeuskUEsbnF9K35QysE4ICRDSeJx1tJtoCHm2J4g3tYunMF
# DATA FLxRTN74sPKq8/LqyGPKI/JSykZaJ3G2NAJnc2k1FSVh9q/C4/CBdLFKzQyEFe0GRTNR+cB6byezohaaqGaFgLTYLjmlj0UDJkTP
# DATA BJE0OVWOUNPcoXAlAlz09AlOd/HQyZpTlvuv5pniwohINvJysFgqCtMknuIibzSCYBVE4ph2Ae2uTEelVBHyqYhtJudTCymtousU
# DATA c0u9wm9ch2rOZ2rOxbLzr4aFmg8zzkR1JupOJqptizgD1RmoWw3P5y32+nGhkcww0C3iaQ5leiDLpCyAWrEogJI67z0tgwiBRRzf
# DATA 4eyi39FUhgmP1dDlZLXQ8IjihS1ns1OjB7mjgitH18RGSFBUCyDoKAYBNVZq9xHrW6LzWOOtUyeO11iqskcBFYw/KTqQsmT0j7lx
# DATA Za6w9ASQ8xGHo2Ine25Mt7SZVWQ2PjD0Rz4X7UrrDtMl2k+tmIzYOYDRER2j3BdvszDRIrUvefNdlo6tYBzN1y0hR1l8xGl/lz9t
# DATA sV2LbHDZSWAbLIpmvslsLJQxdldLY70CgF3nxiUB7I+fbCawS8YKgR2TuEgz0pXT/lST2D/DllFKebrMZLsX18AZa6cqIV3MgUDm
# DATA 1CvQMTZhhNhA4fWXZOgqxdR4UPPejVlgdclCu940znj2KHtdsF2JKaK8CUSucWvllWEhMQBBRK9LFZ/tmdH2pRp0yQz+53/40+Yc
# DATA LtRGyWiWdE0jEf6FXzUexAuDvOdfcvoSa9+SUS1aqslcn7pfUG1LWccXh1cXsdjn90d8KJzmBtN+fLQE91G5fiu6uxNUlNAfQzL2
# DATA WcI3HvJvMmG/jhy9Yl2dZrvV1Y/DqVQFSFnnWSe1BVMcKNjKPl9RtYVO9SRaAIklu5vM0x5jPNB7MejjFGhZoXXNoAyIBkHWH0WH
# DATA ek8qCrVBwTSQ51/9/vWlKp+wzjj2lIovl9Ey0vn3IWZwmLTRBDpXYj4JY3bm8AV13DwCAPpdaZC8JiEVJ8srKgeMrB/haAHnJ2Xg
# DATA DC4kDmghTwHTG4GiSEMlCu1aqp7p2i+ZkR9sqXtqkJA8LK9Qeos0PKZx84TSoDPzU3WUYKwEskOplinZMNEwU0YB9XKzBYPjEBbs
# DATA EpmfUEOemZ5B9apT6jUynkvGkHi0llVzuNwiVnLuEc1/tQo3bL/nmq+f7ZqvnzGBz1quwvnGvHWr5bA0OsJ+cDkgQgnJ1JCB0SZX
# DATA rzeS5xn7KnLLMBqNOIftfiDsZyxeTTM0du/IPao6ozcVqy9GZ/tT2c1aytCikSB7Fm0jwVyR7CG7Vu8u1BM7draoXX/UEQ3GCfSz
# DATA QvhLqSR1QbwWC282Ro9KIrIJev/p7Jvzf3v29dn/PPvL+W/BvTv/BZB49N9vzn53/htB4/3+7Kvzn589xd+zv5w9Pf/tKlHPDodZ
# DATA eb9gGh+e/eb813jq7I90kXl7gt6jv3/26Javz/+Bnvvr+S+B00MM+ml0UjXovT+e/4r+/hY/M3Hvzw6t9zJ4a6Sm2bx5mXI+jNFK
# DATA Z7ItGMSGHxrfjCjfwxwji2EIpR+2FGR9A78/1NtJ0mgQz5XNlS3RH3FrnyYs1r+VpPeOxMtqQA6mZ3tpkDu3zdFbLZObQ+lJ1clX
# DATA Ej+VqiSSJ+Wb0RNZa47RyY3QsnlH9VwduqCskAkj3jaNZkvH09uhzK4dqSdmPffl3PXAyyx+sz4ZELp3E3ueu7HP8m6JqmtyoqA+
# DATA mnDOOmuC/uVDByi0eDrFGR3AhKiwDYz4UvVvCwa43KieF2Lv4kQ4xp4b559xnNdIvSsN76/JAsytDO03MLLvNLBfZly/nWFdqmQ5
# DATA Byy03vNsOjdB0isnVS+KiEs1ZLnJ0oiY2UMi4r8yJlYEiiWLs7LGKkoWx9EimfMzUcYH2hMylxbjZJjtgsn7FHkoy1jlGFH2wkPA
# DATA G3cp+dMYG0wSssqwZ0sG+ry60DvDbJkCDBaywChlMvvzK9ptn0ZoP5yiUy4Z0cEREiAcK0yq05UhCyeC+xrAWa15Zo6G52h4joZ3
# DATA gzS8XUaPneYquxq7t2q3X8Vsvw6r3VHxHBXPUfEcFc9R8RwVz1HxHBXPUfEcFc9R8RwVz1HxHBXPUfEcFc9R8RwVz1HxHBXPUfEc
# DATA Fc9R8RwVz1HxHBXPUfEcFe+FoeK12kG/0bkqFW806kXDl4iKV1553gmMV6C+NXoWNa5Rbxjqm9/pFLlxo0G3p/KGIhjTyGqCaORB
# DATA NJv1vGwCoe3J4amgVwiv0wwGjcFKQQUt3wuCYBx06sd+s/llte31/KrfaHm9gP7Uq118qfaCNSW3iuZrBRRaqz5utr/sdLyOX21S
# DATA PfCbF1DnTGArmLigszYDuha5jyJvVc5GK8+ARuG932oOgnajvhLlRrvu+S3/yyqltUm1pdrxp60mxf3LatDTV66cAD+4AuiOW4UG
# DATA 3UkDs0B3nWaj0WzuALobjtpF0F047A2aOeiu02712i0Duht2BvW+Bbrr+A2/2bkF0B2aVHW7veHx8GLdWubDfS+iXiAOKxJwaTFv
# DATA BRXX4AWzfLmsGLSyW1acVDqHVhyRJX+/HdY6D/ylBlWPfW91NpzUM2oJbG3SjVt1NZLGLC8i5FTYgq5bv1WgTLRbxaytzRkz8OnV
# DATA r/o2GtwOteCmTBGHdnNoN4d2c2g3h3ZzaDeHdnNoN4d2c2g3h3ZzaLfXDO1mw9wk2Xxg666A1IY45fbG/nfkGy85MpZLIc+SRTiR
# DATA +9Gi3vwoXIxrPJPc44v7b1IO4DgqvUc50ebQmFnO+fa9wjvuyDf6MeNeZJG8j+14e74dyudymMwKpPzOUjD87MqRM00QkymgOdLh
# DATA DlG7Q9TrDlGXjvm449TuOPVlj1NvEb69qWPW0grYDoZeu6yymmPWz1HI4zaoC0N1PFvVDHz19o72laStbnYzdmDkAvDqqbxvUt9z
# DATA ZkGRxTCNWYCupbAN7PuXRSdsseC1qJq/WfhWxlNIMZthDcWAQ9WS/xdEVz9v4msumAj77XUR7loRDnaPLw+qoLRxPDiadOWCSKqH
# DATA ct1e9b3AgViJoW/FsGtHsBi9jbyHd1SLioxo0MuLe3iHrTwexhjghcmJPpD8wQgqm+hD+Bh+xgMd2l5GZsm8wj5NaqUTeP0npx6U
# DATA NFHJYvDyxCgSb73QuaTW8blxaoYqxCEFQQHCzBnrAAcJjB4Vkj4OzvwJrslRtsC6O0+pWIJpyhaxJQKA0+CswMjLqEOcJPNk7ebQ
# DATA FgOAyYbeL0umke6IPqTZyzFmSGMGYHD7HmB3sEoQop33NRcDGl6dg8UOEuss2e2WrLNbX3G79bJQ2OcuD8QL5tZC8KrRNylIAjL1
# DATA J2PRbcU/6PMxUpgiWxmqz11V6CVR4LgJbOqKAtJ1k1PXqEmth6fupoRYqn/IapumwCLSb6dIqxrWWbU9V5DmPT16IrTMBE6l+als
# DATA i0WYZw1PC5IuoYeNEsupss9QwehDFilDCYFJTSoaKAqd/D7fYIySsgQ3x/lTFnuVKEeUxTrGH5iJWsxzQIqq6Bkt4rTCyuwcG63K
# DATA XrDQtOK9jQ9ggxRBkRWAIxhbov0JFua2x/oBoCsq1rxNKRrqiL+nJa6GNLtFbCgJnHsVnvJVvFNslhVVJ/QYi+QogopVzbOM6oSV
# DATA RacegwoU9WVTdPULV2P8GgnY2H2SszSdpbnO0iyMU85j6jymFxmoz1+YUmKQKWXFNEmmrFLHDSKXp5xMpKmsFUmsqXpeEWdFRQYj
# DATA 6M6hGWF9mqlg7FnxZPVOtSteRrwcBex9thKUuqO0SbXcyGGi55szdhMu4HCCDQwikO2gYLtAwcTisk2rTXcaPzfTXfSXzfdrlU7O
# DATA VfV5891axrNofrz4GLE8/y7JcfEP/PZmlIsuDEG5/GAWUWcyZ9diFUcWtWWI9Q2/5R3ZKxlBs04XlBvx80gRyGgKgq1yk9MK2e3Y
# DATA +9unejHC1wXGS4SMPSQZ1jzkVEfGPQSMrZMwG4uWqrbQ6dJkkl0HB+dW8u+zk4Tzb0jj1LyYe416MfeaXSv3HvBCDZLNfa3KJCiW
# DATA Aui8YDlKkcaUu8QvPImAL8JmXU8dwhWh0mvIrUIbvHyGtTZnmNWgJc++R30qxe79lKeyc5nA5PkWlGpdo9Oy8m0BU4qXydhwimfL
# DATA BYYciJZOihMrHjEY1kM1j2ZXioJnJmHH2NE4eQHyrn2JvHsHVSAVWYl8fbCQfaVq1wjqpeyr8FSaTdQjKYqM5qmilApin7RG7Ecf
# DATA puEJtvLqpQHWm82XBp4lz+w+/JJZ9tHm/MpHA4XwSx6G2rrWmfQ+cyqEGwF0n9ALj8nmMGY6WbgPqeFNFNppyKrD02TIJD9vjHVg
# DATA 71MRCmamFa6Y5ROzKpPRQE+5zpq8aNHXkW32YHbpmhZszrh8YJSMM46BooGm8/ABriqvy8zzu1TDhjqvQq/R5j1DVFGxLZBdCDRd
# DATA Uo4Ysd0YI891LfGOlrHiezE3Vnlv2GzkLecvKsLrVXFI5BivUbyAxKzN8fp/z56e//LsL2dfg7H11Dv7w9nvz56e/fezrxm99fUq
# DATA sOs/00//P3vv1uTGceZ9+lqfomyHo7tNAEThDFJNLUVRhxkd+JKUtbOWllEACo0SARSEArrZlhUhWTPvzIQdryN2J2IjJt7diY29
# DATA 2Ju90NijtSxZ8sV+AfRXmE+yz/95MrOycGr0kU0yZZMEClVZec4nn8z8//599gMYW0f/hFs8QXLN/jr7jn769uiLo9/mEA6FSWF9
# DATA T7/92Tv6R/yUpzu+od9/w2/6ZvY9vfnro88ZDwZklyKA/Ya+/pkCpJ8cs+tZcKmkUD90mQObByR9SBLBB0pNUuMCx9P2hNXvpUOh
# DATA DAsnAl/cx/QvGogLUtotXKhdnD4HBwAKJfwUOIy8EZW3e7aVRn4c9NdivO5iZbwTHJqYOo6X7WtRHcRlg7yWlMrFkbxULUyXjB6o
# DATA atmPKJ7jw/n7pTbqm9/KVNLzhHnBZahiIlr4sjM/1PFyQK/Niu7cmV4PwhR0kLIgxoCk6i7LUDm45LwEvQ32AomMMEMVzClieH4O
# DATA 8bXgvRl19OyYejeZXotzSqV0gex1fGVcbc8strKnhfY6PhUO7eXMgfM3BzTt63RWwAux2nJZFsBFGAAbjf8nHP4vZ/SXirmQCxb0
# DATA 64o1qovggC0kH1BTrA0lzHlfn7Ic10CoXnES5tP51kRtjeAtECwSEgVj8yYdFKdcFpxQnMp1sBEZ7CH7euEPwgacBK63cBz0c8qS
# DATA owEt6kxRfGGHixHG2phqCK8hd1LME0dYmwJmxwjMAwpUXB5wTlEbh2smGuYpixnE7pF1MYmGoXZU8fIZQscyNMyWnNgs9GKxQwwI
# DATA ylHCHCXMUcIujhK24ZCz0RxoU9P5cqcBp5kFnMckwJHCHCnMkcIcKcyRwhwpzJHCHCnMkcIcKcyRwhwpzJHCHCnMkcIcKcyRwhwp
# DATA zJHCHCnMkcIcKcyRwhwpzJHCHCnMkcIcKezKkMIqrXKHfz4VKazerXZbzxApbGHpeSNUmJ0vftUr+41etdaco03VqHdshMtoU+WG
# DATA 5BCXkZRBhRUphZTl+xmlnvmyK/l24dUy+W/emQm92vQvMPRmLQ280swELqlKA/fLNRsClgm82W20Wt35wGvV5rmHngG9VYTFJpAy
# DATA v5aC3qqNTABhNQga5YVmQY97vt/Yr1T7pYbn148hkK2uE/VTAMi4sWkAmbTbDICsGjRrGwDIMlcAIKt22t1iCiCrtatho2gAZO1u
# DATA u9QJLQBZtdJuNi8cQKYb6Fr4VMGvagpZ5n4zOuoFguomtLFsEJo3lvbjOqcWHJnWoy0syix5ZtNlgUJNWSAl2/FQKixZE/bZIMq8
# DATA OeNREMsAz/H8xXiT/CrZCTCplngkS8YjKZkyv8yyZKGvuvCC0k0916Le20/tkrnoN9ieW8ZFazabWRoaVplXU8oy5ZabK4s11k72
# DATA xjnfg3EfOgyZw5A5DJnDkDkMmcOQOQyZw5A5DJnDkDkMmcOQvWAYMtQFCqXTD3MhLxN1dos5drrzpxGZ3WGy+8uPcnCo7oe7bMHm
# DATA 0NHew0+7qJI3TYXm02WwjsbbO59G3W15aOdTHTS1UJggwbAdFoZkoe7k1atu2sHfZFVnfXBjW6K3cxNdwYdbD9NjbB3BiX1mzXGw
# DATA j1C/X0oRxz7WvBfpp6coqazkQRPj8bbqraBPLOmnBAw713ZHavd+8nMYdjcpfQj8Zfpt51N+end0k89kUJzoxx/zNYrH0tRkEmyy
# DATA /qbJ8JtS6zCh50af1jDK89eVvjPlvULC6ZM/RvnZe4hDUtnzl2OKPhM8KD+iWLJPbPmbn61+HZPe2mHU396mpOaR5p3rbNoC8qay
# DATA hGJCSTb1ghoSp77AbtydT9MKY12WuNv3UcbZXLy0BqlYIlclh9RYsPNpmmEoOhRnRNkYvazIeSzphnRG167pmwujKZkmn6qY35A7
# DATA ccqO7stxRGhi/QFO3f3n5/+izjQCmxdd83eoi6FILASf93fWhI3jkXbY93Fckpc/FkP/LK0Ln6k6wpNJ3SYXq7J64Gam9t+UeraL
# DATA GayuetYNuVK1mG1R4+lQpISF0MfVgVsZXXhlnYGbtnn11BhnSI97isvX7i6smp/mwFw/s65J3IfKatoeVKIQFZ0kMwdcEi0+gxL1
# DATA aT5k+lRdA81jMlbsZCJNwR5EQ5ouLgsUK2n0UDiXSY4Z43QmTqkz4fQlnn99iZOSZK6C7gSvrGT89etxMu/gEDyIHBBf1Qengz28
# DATA ahIP4jHNzNYyZa6iaMWzc4T7Ikgzixob542aWSZickrWjJdZIpIqzStst/yilgYWzKaRE6OXqVsg4Cn1JBX5sIXeH5NVlhPXk2jZ
# DATA I/LG8pbVvHiEWSTgesJ66E3HE5b6itR7RzTyD0U/IVZSH0bEfo3Qx3HKo8/REf1Mw3EmlDOhNjSh5vpXJ9rlRLus4Xel8XUVxLxe
# DATA nUZgamVlq4yU1xuiC2U3JYw8ozBGQzvoxZkRShACegAreLchYoOiY02dQObCCj4WPqbmGPSjLhRvILoN54NISA3DsKMxYyflp5iI
# DATA KuCDktOGtHpuiZKWg6dsAk8ZxFJ0rHevPq8DoozZjSYS+PJ59d3Y7SPc7Dv8afWd2txRfCH+/CygU+zcO6FKfgOG42qd/LQsMiwL
# DATA 9uppcXyeFaUjG8avcTzd66WN4WOGvbOEh8YlTYdkPLIWVbphGu15P45Y26rN5qGnT9DDapyy2NyI5XthbFIc9sLJeVAGzpB/1ZPl
# DATA 32th8thjZ7uFFoA2roI7mfSyZJy4whPmGdqmw0HQf0x5peUDOTzcNu0D082oRi8cchmweBtOQXid6ViL69IgdT5Mi7QZnhTOUFqf
# DATA b2mrlnx7lcZ42ffHTJ1pZGqfsq2ozoXhSiFDrB4NwbKQvGRpOllMSBS9K0wmBe9vGYgRtnvD6JNpaBQUqZLShA6shEkP045ewDUR
# DATA +TpRFfcccjPtpk6al8fUQd3rSU5+QHWHVRC1VLPBkJpMojRyFWILVaFGDRKeLNz2Y0hBzpmyKvcCll1UyL9+qCaZnO1KQ86Ienez
# DATA w/DTasG1k7XgV4M+2xFqqhDaLBoYB5whyXSECRglMBi3DtXcoC06i7LTueDxSg1yl+XIx4rtRrnWDUOIKGKqRRZFmIzCdsREWFG/
# DATA HB+ynqGZhA/Dg/PIQXvsO2kFLK7PwnQoVbAVVK6xuagpuDTtGnDXhs5ekXrMNKwdgMpDGXVABjZMdeyg8HpkEaJ+IctYBZSFD6lS
# DATA QwdyH1vF1B6bKwtVeY5cG2kQzq/h/Bob+jWyNc25NZxb45RrQitdIBemUa6qbIb+ClOcqrnxbjx1VsY67wYzGVdy7HmjNy9zYPe3
# DATA Ormor5lJL+9qsEdOc0XPejmX0vOR2BlC3+JuV0yDoCN2QcYhwbta6Ge2kUyvs622p+wov4hu4UPe0I9XSKTU06Zn1N/NPL8sxzcx
# DATA DIzJuCfjhc/c4eIgeCJ3FOWcXDjio3mrfSe8SYZTYpXpxlFVT5uo6u8mqqVjo+o3No6qbPtBZPnTcXHTt6exM1dM/CrLoudb0Sut
# DATA iZ1aFTT+LDkXwNM/8Pau8z7FAZnYciObH+PBrZdFWiHNQhwLsetgeilT50Y0uE/kOO51CSKtyMY3Y7UPc2mFA0dMIpoMdixTO6Pw
# DATA /3dkm7b1BJUm5l2MkgakI1OGg4CGd8B2RvQoGWiYgSkqUDqL1UBKRSdUky2hpJq9vxbSEkNy3M8zzJJ3bNFbOuBhxkIThRcl53Wi
# DATA X/0qwpDC7pXhNIEgf3JItm88SFIvqh2zXtgfHbNwPFeq6eKx7VdNl4El/2XPFj1+Dx/SEj9VYLKVSxplOLGqj9iwXGIvhlVusQ6n
# DATA Y7KJyaSzaYf/neGFX4M2mGUQHv0Ofy/SDv919hXzCL+b/TD7o3f090dfzr6ffXv0X+nJH+iT4hYy4xDEQgmcQ/YYiPgVMIpHn9MN
# DATA fzj6Z3roW9z2w+w/KBz95B9nPwCX+A1jEClIxzx8FmYYpnqlEwuu8CCeIEfpmZzyV3KHo5EYLJxk6M4SYbKI7lEpCo0AhpUheFBP
# DATA qo2eURS2aTa+Dm54X29joAGA0WoObWhNJnSBXTbccKFULg5tqOqIvg2cDU3c4V8W7sf2FavDfRB31Z6Wc0cbcgQyYMMo4crusIab
# DATA Fdu5Yw3vPhn10csE2hkyiDvTfgDyejxhzZ6C9wH6fu670n1evPiFjfH0rNn/RHGYDrinTGQbFFwo8STQa1nBUNAxC0DD46vgaqtl
# DATA vmU9LZzh8WlwOEM30p9hpNfcwtMM8C+Gp/DSBvfzH9s3GtpPOLJfzsAu1XIuDyxm4dNqORcBJ5xLJVYAQAJSnL+obSVWn3OcT1Ag
# DATA Lk0FlQNtTW+iTlA8vPlathVriW5YSUP2is7n24ZEQuNlTWOXTOI2rzjyeKxRccyP41rSobn2MDHRD6fj2AsGjH/jIT8ksyFqR1ga
# DATA z9gEGQsgfIKDxQi8E8IbpXZUq7VCsh6oON8JgwQRYtuuPYErRoxE9uoIpU7W1lVRt6aHUr8crdDRCh2t8KJohRsONRtNbTa1jC/T
# DATA xj+NiX8eFr5jFTpWoWMVOlahYxU6VqFjFTpWoWMVOlahYxU6VqFjFTpWoWMVOlahYxU6VqFjFTpWoWMVOlahYxU6VqFjFTpWoWMV
# DATA OlbhlWEVVv1Kpdo+Jasw7HT9sP4MsQrnFp5PTCqs+l7ZL+7nm81P/Hq+XPfqVfq7V66WPqk0vZJXK3nl+n6zmcmltt8qt7vzGDsK
# DATA q7YUY1dZIBvKST8B+DWzAL9q2Z8j+FUaaVnLsbWU4Bc2wqC9CE60+ICNaib4UrmZDb5ZXhm6SWYm9Eqxuib06qlCt0uk4XuVSn2/
# DATA 0hxQ15qvNPcrzY1z2l+EEdZ9r+rXe7VqdS6UdrXdarWXoihPjh2UdqOxg9IELexgrVNt1DvHYgeDbqtby2AHO/R3p2RhBzu1ar1q
# DATA sIOtdrvSqljYwVK10ihfOHbQbFOD8P/eRvP1Ndw+sW+9BbtIm+NzbzMDpZp6vRFSdxMFOYnfUoBhVa3ElRZofVhYXHjBnNvdNhp1
# DATA gWTn3WTueT7sAK8mf+ww2TrdOIeq2nRCpoiRmw3qVjBvqFjYwGxk7c0FekRXy17FZd5eWUzJJq0E3yf/pf7YM+71xMG5bM3N58ka
# DATA s2VtktmecMBBBxx0wEEHHHTAQQccdMBBBxx0wEEHHHTAQQccfMGAgzbfTZItXgwhpfFRcUR/5+eN4rVSMUczS/XTARfhjkzZNObr
# DATA rhyS4YNuaGTX+Fdw6doDBBx6/9//5jWL+NYJw1HhQ/pvCNoahXtrt/jKh1sfsJY6n6PjhRoEQj9KEAWe8lCEJSxz+AZx8VqHuJfp
# DATA eEErQYg75il84ne9ZR9lk9R5YTKBHzm84f3nb/4fRGYh7dvlUvGaXGVxT3QNCFKjzBxCzJ3tPu5stzvT/byf6T4pKewqnPWec7Gt
# DATA x4S9jaZhnih476Da29ouS+FgT/V0+LNzNPIiKGDzh9nPmwG2KAlwWgJY1l+rz+q/zdQuqQjymm5odG1eg+sx8Dox/ZAc8Bnte3BC
# DATA omqxFFAviMYF70E0YfeTFnyXCijC5dORHE9WhZs5vh+kUkYjiDbGXT6LnIrmzCncLJTz4xCmcmDkdmATXb7SzVM6BWu1IGcMOWNo
# DATA 3hha6FGd6I0TvTnOjLoaYjj3pL4y0aITG/zFx3HLKOLcN9oN1AyjvaEifykNNYWPHNOw0Ia4RRc3i5JEEgC/CveoxuPwhnyW7xAd
# DATA Grgh+7Z2yxLNlI3BXw+hOgP/WKpkY/Ng2Hchqh0O97UZ7ouSAn0SlfQJt5rVsC92O4osNH9cfS9vz+We5SF/ehbgXVZenJC78mAN
# DATA P0nnqhBX7qBVUOmKbSXAlYcHsYg1xVMIxgSQYxHIygAtRUskooYH7IUSWSYxD2lc24cX+VeQZxkPsupFolJEtl+cjncBBGGodgSi
# DATA Ud9lQ1mfOZVGo2YHy4WdFwWgzcKb2CRpAk2OaSkHjA1YUOaMoQcsQeiz8a9OXXL3Ny65+3LAXKx0XXRvwxZBRxgwG4CKY0+pfydM
# DATA +gpHrI6jWEJZdBiKjyV9RO2bikAmqbc1nxEeQ7UvinvTfjhRYIGxiksyiidnL7JMyi6vzNLe5IRl9t46Wpnql6TM3oMAEfKxFVOE
# DATA bEAUSxPpdRQtaLYnjCzKXerEcTHukjVieFrd8EA0p/TgNhFJeNwpiztc0gdMf2Pmiml0XPqtaXJ49tLKpukZKK53Ny6udwOA23kx
# DATA g/r6lEeV9ERL3zQG6vX24A9/HB6Ktd8KoKDl9eKBNCxMDoYcGmvUDT0qqDFoYUDlgFfFDvhu9ETwcQxNSAtzXvjt7IWWTdmlFVo6
# DATA Cp+wzB6uLjM9nqteUZQDcS0tL/FHYB8+hgFqQomwAvviiGF55LYaJ9gb593m8u0yvos6IYiQYdwTyxPHprzRlA/PsXjCEGiXc+j3
# DATA 0rhf/RIpbVoi74ZKuQ7Dx0T9pAiXcj4o1AOMNCexNkSoL/b4eBdawKEIEgoYULUa7t94Zo0AYHbzUBYl2khB6Yr+3Tm0mcWEnKqY
# DATA LpcwdyaMyYvgZ7OCcI4252ibd7TZVcr52JyP7ZSLjSt9chckOC1TcpnpYQRE5YaNaVxsTxFqcEHkuYwnS+89gb3Pm6yx/NTgfTM8
# DATA E1a/HwM6S0Mx3ZV1KaXGHYc6q23IYTvQ3jID7uJ5gdq1t90eHAu4kwBSwJ36bgHulmLjfLmswXHFjSF3spsH7kJ8EMaYUJChUsx5
# DATA NedAVA+k3kMdwoLPrl5k7Be2tXsHWMjk/UX14movn+/zIw/DJ+iJOtZT9Muaxyr82Jt096H9TKW4xk24ElGnTVPspiVLbfLsQups
# DATA 191Bj0LxPibLcxgeFmzJZ6XrLJ0AHEIHsedzSwvGChanN6yNaJqkTHesOlNnQXHC9IoHbgrauOPFocF9i3jslbtfq2vzi9W2M48B
# DATA l1Rg5VKR653VwqmPmmr4pdqT287WVOhNKxl2CkWrsOfIwn8iXd+Q4tiXqSKrZo+mY4DeZWE7Tlg/1RLI3gAi95wYzylCjnqRsD0O
# DATA uhMLIfeOvpY/+ofZD0dfHP0GELnZHxfRcf+2FP9GX76mp748+vzoC1z26J+v6eIf+O+vAI6jK9/Ovjr6R4OE+2b2tVJIh8LXCNqp
# DATA NGQ7TNyVN/XZMg88U2e8vwn2A+9uJ5KzWCJ6r/aV8Oy3O47CYYc6EP52EI/7HWP9w/M9HYnvFK4EcZ31D5muG8OlLRRRdhqkCxSq
# DATA 58FT4RNqaJ21CLlXIaDBWhMe/y08CceRS2cEplO4bI7c8qK5OJhcj6LD5IIUTs31VV8/DiZ3JxBJ8IsAyvHmK7Id6V8aE8R1hdEc
# DATA DcYB5TYrunMHykmeBWzmDNG5ybzKTKe0YaMmUwPpoMhy0RWFF/hoeEO/y9b23jSgRjEJqW97LUoe52D90NN37r3vJaNQkTJw/J3S
# DATA plRhpmwDwbU42YA2t7yOrjZxlrbBq4KdW54Yh55z1sMFWQ8aS3dqo+GFcCFensFwQfbCRubCCa2FyzMWpJIuywxjKFzNhnYRFDsr
# DATA GwCawyJxJxyBQ0WmjBmoTQ7xbH5FtrTjwWCK7hoLeG9hBtFmhwVLiiSUL+3QHvHHITsoxPuHDEvUZnsa6anI+Ho3GvMp2iTZmHAH
# DATA kFaifLMaJkYZsk8W4Vj8HOrXLs2VIz7gwDuC3ok/phHN4+S1KQPj7qTg3dfxlgMKChY27wResFvkrIBGkBlNCyaZIT+giwPp4B5l
# DATA ctQW7zGnfSjuGt7LGQ6Zo4MT8mhdAJGpKkG56ph3jnnnmHcXyLzbcPQ61cGudWb5pc80zsOjetp5hgPgOQCeA+A5AJ4D4DkAngPg
# DATA OQCeA+A5AJ4D4DkAngPgOQCeA+A5AJ4D4DkAngPgOQCeA+A5AJ4D4DkAngPgOQCeA+A5AN6VAeCV/HKnXDo9AK/8TAHwlq1Ab0TB
# DATA s3hxpRRHJ6fR0nyvzymUVhuZ7KpUm/VqOEdWK5WoACpryGrWq5unfnWj1CrVyqd/dal26leXG/VWpXP6V5fLp351rdQsV+qnf3Wl
# DATA +NTKulJ/amVdrTy1sq75T62sM+262bjMDM+065O9+qwZnmnXJ3v1WTM8065P9uozN67iUyvrTLu+3LLOtOvLLetMu77csrbbdala
# DATA u8wMt9v1CV991gy32/UJX33WDLfb9QlffebGVXxqZW2360sua7tdX3JZ2+36ksvabtdlv3KppkLz1K8+a4bb7fqErz5rhtvt+oSv
# DATA PnPjKj61srbb9SWXtd2uL7ms7XZ9KWVtux5KRa9cL/WqteJ+vfomfc06HeqtWrXSXvpYpVLnx8q1xccqcHTUT2KOqQmIBZf3a5kg
# DATA /Ua5XFqMSbVY9UrVaq9UHJSrXrFXKs7lRqsaVlv1pUj2xqlo6uWUpi7+HIum3igGYbWWpan7zbJfqmZo6nN8ddDUW2Gz3U1p6tVS
# DATA rVZpGZp60Gx1g2JKU6/41XapeOE0dXYG51u8Sd94OmWxXWPRU29rQxzW9jPzQHSzFLds2U1v1KjzBk1sz2Qm+uJuxxr8rPIaPgi2
# DATA 2baMmrUtYyXQ3Qp1PWtdiks5Latm2UXXCD6W0As68cGNJv2IP0VPleJnBXrVAC6wFUuwpYXg1udhGqCntprq/WuybGV+HS3ZfaDW
# DATA enUNM8sAai9o6unOzZ0oyC5vF1fD1u2SWuMOX1bX2MnNfnUHVXdQdQdVd1B1B1V3UHUHVXdQdQdVd1B1B1V3UPUXDKqeWoxKu2F7
# DATA x9h3lGrvvmh/pMIfN4VYxV0228r9Q8aVi6hIfhB3wl1BV9BF2WaLRp1eE5GJPGyQ3VK1WqvyVczyRDYt2dVsdJ4aK8S5+g2NUgPS
# DATA ETG4ICYQZtttSODRQMFG0l9q8oJ40kHIXJj4gmrObaOQ0FAdbhdztcoOjCMcVNm+/ssP1X83dn/6Y/w75mA+ur6Xo3K1OO1ctt4i
# DATA nB6qAruf7gfDqN8PbpRyo/6Upv3JjXIOknE3qp/9kqPC01gTl480nv7BdG8vTGRcZAEy7/7td24YbHw7jPrbeMO1+ez5ecFvME3+
# DATA jehVgda/yvI/qQ7vXCgSgAjg0CQfQWh+/CgSqLxfKOkg0TkrlghGBRG8gKaeCB3yC1WdgSbeBPJ8EzKXdQ0SJSFItiggPWdCqiFL
# DATA V19ZZ05xBkfdFZbsp2aiAYm0OXlaejqt5Ds3MbLAcTWnkQOxD5UAKLnYkjccYxkIfpLLCnQ4nTqnU3cSnbo5MRenWOcU65Zo/qxm
# DATA WVwVJTtvNEY7ZQ2tbJyMlN3trKTb3hTSuBBmWqXdpsAWQ/Bmo3akgsb8jtVYtVgV02jnJemyaK0FOTpzX6906x6GJupadMTFG67l
# DATA pn4h47ZSTEvJV7CBYybUAwMI1A2WcfKsoj9hgXoJLoGWrydjvp7q3oRYLLSmlNocEFue9STjPKFsRXEOoY1PSYlgXGsOIR/5i7sc
# DATA nfAJIGoi64WeyjxMI9UqpT5O92vKLmK5vVTpVg2NOv0PjCHlaUMKinXA+4hSMc2HhXqicihiHYuC9wuMnAuPtHtT6BZr/TFlrhQ8
# DATA njRkBlrBAwsAVTy1uQxVOLUoyLiEQp/03OhjGbMSIcIMKqZXmbMEybocua26eMkR1atzYzG5MYlHim3AdSUes5oc1M+S6QgjNLYc
# DATA Q8+Z6lo77Fj9/yR4LHAFWIVsz2DyNTpUhaoHl+AgOEwtKhmAJPbwVXsPQ3Zk6rgx2DWwTDEGEdtDDtetaLIu2fx+vO3jmDKthcEw
# DATA 4DpH8wad8LfhQfEs216rAjINKqsXKDRUFu2iKGFha8Qlx1JyQYe68MiQbZSgnE6AyNBp+JOeYKSCcpp1w4DOIG1lxlRjqp025VQ2
# DATA UJ/Tjw/Z6zsPWRNlsOdf4CwddZyB6gzUkxiozhx9cczRlWbmFRdWthf4FxFm/YydKi2G/p70eECCraIs1PQR1utRKKyrKr/8bKmJ
# DATA Hgd0sLZyCG6Ot8jcepk66PmWqo+jZTZ5NYpzm7zUUbOgz9+WtZfFY2LS+tsx3FLyxsNhW0dHqS/dem/hlBl78MnmWSHkbT3LXzhd
# DATA cxAwvZFGa2W/qmzGnlae5vzRxhgbbMvFm5VVpuWBmdcxHVm2pGFw0mAPe1RPFwzmK2tgZs1Ry8E3h6+YrwuvTiPU/EW9bakUC8Su
# DATA YwkfQ/XiHEVkHJLpErTI6laAj7n2jtOv0hQ0AbhXvvVgIMBvyk1DQ+bmxlq+gSIi72dnLSwDDur7KIxHfWqhH/C6B/IinX+wmpki
# DATA LopMckYnPGs4TgJUXA16M9biPFKao6xKT0dXTf6MsY/Zgy5PxUyTGQZ2QsiMk7EkmKWorkqV9pqI3RuTEdmerI/YHV5v8BJY/Ic6
# DATA euqizKTZAvcCVCXOI+TkwZhVs+ODIU3Z6KdoADl0XVmXxuaOTPYWY/MCihQ7brKz4k9rxc9XOedndn7mMxvwK6cLF+dnNjzxeR6H
# DATA wapdSczXZfCX9cov/XD3yUj27fAqOJkyYTxNtK/1GJ5xGozp96xLBuDbOA7A7G8MNDZG/wfcDSJiWYCxviFlLJtpwjxXWK2y4zfl
# DATA uF/NIFbr8DLN44+r70Wps9nGfvs1jOLFlPFaukkdvjFiQhnm229Erx6LmLaCyeaBvmjiWTmuWKon4Ezzqr+C/lFU5QL2hFB7pUxY
# DATA H2nzuIWd1ldS3vRx0S1vGlveyJF2YAPqGKjvmIsjdufYqPFJJ8sZl+8mdre9hCwmvUxjR3UDJvVdjUrmDmIc8pqF9kw/u4Bqs1Yg
# DATA HXA/mA5pPoQFgWSSZVSb9HcAp2Gzi9cILMoQevYxyMxASEsvU/Bu4/J+RPaOvUjGllD4pK1WMzxZj1BHHbqKmokNHoEAbA4TbFjj
# DATA WQfP2MSI4rUKZSiNg0jRm8CSDkbSU8+VZ+pAUb1juokkk7GWe8QgeRa5yGmxSx7N4ZiWcJh4hW0exMRMq04cCj5Kzfw8cKIOUMko
# DATA MxgZ2p4ovI8ZhY7nZD9vsyYLmD1Noja8PFFsIbNn//3oy9mfjn4LqvXsu6Pfzb6ffXX0ew/sbPrhP2bfHP1+kZ79L7MfZn+h+/5p
# DATA 9v3R7+nu2Z/o4b/SvV8c/S7n0acf6Mk/zn44+g0o2ghaSNpf0N/fzL5hjvbn9Mi/0y0gaf/Zo7vA6/4dBfsNBfsVnp79gaL1Z36S
# DATA gvgD/f09sNxHnzu69tWfEFInFg/CPMhygsjS3Cnuq9rUTAHC6/MyMK+W31MjRKBt2pwgwdg5RWbcqB8qXpiiXVHvN9ZQe2aDpUbr
# DATA Wor2fTxEfVDo0NmZ+V7aPVw2PNsqkYsjZqtalVgzPb7AFTOZv7sVBml3/Sp94crYCmmsP09UNoXL7OpIj2Rqa8XCpO4FZWVvUGjn
# DATA Tsq+04uhUx8AYk5j6lDbr5TB7HZSREnuTajcFvaAi8+XLBbqpPbD/k3EtcfbpMi+S2wvVZBIb6g3p5yk/q22YNLW9LTY18dG3mGv
# DATA 3bB+xmFd461PNpq/GJ7bSxzJz3Mg32gcP9EwfimjuNREk/R0t+9TbSoXAag2aZTtoauSx5238vhwOedkJyWlYY+lMoJJT9LQxUbI
# DATA nizZyuozTc8DIdOOe4eT3iAtMGsvZKBzQyGLMRRvQqR+N/ZMdAW8q5nLHJth7EmrWQ7nLXi3+UcW6E6ETMyKzrKEpXpVBJRM4hFZ
# DATA Wz1FwZ0ELWSYHLAT6yFNlQFkU361o0T0KXSWtuGMcHxpx5d2fOkL5EtvNKRsNF/Z0PC9HNv9NKb7OVjuDiTtQNIOJO1A0g4k7UDS
# DATA DiTtQNIOJO1A0g4k7UDSDiTtQNIOJO1A0g4k7UDSDiTtQNIOJO1A0g4k7UDSDiTtQNIOJO1A0lcGJF0plYNq9ZQg6W65W+xWnyGQ
# DATA tFlx3ogebecHXKzVaq9WLO2Xy8U36fuv5vMxrDaX4K0ant+o9KqV2n4DeKtG9rG236l3/PnHBn6l6pXo0XIx79e9Upk+eOVGvlLx
# DATA yvR/+q2eb3iVsgd4lp8vN/haCbdXvXLTK/u4G5eLXtOrNPIl334r74TMsq3KnWpQKy5jWy2pG1XEp77vl+YBba1ay2+1l4VSWYDx
# DATA 2ZS0chYZLOFaAK9aWn3LWZJ5GFTrrYUYlkq1s8ew5JfTGFbL5xzDZvMcYtiopTGs1843huV66ewxLHOTuKBSrlAjOXMMK+XSxZVy
# DATA 1W+cPYbVYvXiSrna9M8hhvXGOZfySUB6MghpkJ6MZxZIr1mp+uVmFqQ3j83jK8E8SK/baYbVFKRXC6phvWFAeu16q0NzdAPSa5J1
# DATA XG5cOEiPt3/m11n3hfIcn+4z66FFFl3GJeQ3srMenQlsY8FlS3mPTY/b+VIn3NvJhDxH6HsjpHE9CnIS93nnd5ld37LkzXC++fV7
# DATA FTJP1jZdUyto8539uWUr6QjG0xuPMpa7cSzgiIH2hWNjWP6ES0CVZQ5o9sNZ4Skv2CKeT9WmbGmgMCyvRB3LK8u3Qy28ooBYk81q
# DATA zfLJRNWNwS5hsoqr7eZq6F5awjm7TNbMIhZrm0quVY2Us3t94fBUALV+5TQqLaiTzUcdBNBBAB0E0EEAHQTQQQAdBNBBAB0E0EEA
# DATA HQTQQQBfMAgg6oKaKO6ydZoLcOgzBwnfcY5l2Io3JT/4dNiu1Jao8z/v4sc8astNDkTEI3bV8Ka+Utx+WcyVcpVcjfrIqDvfQ6rb
# DATA dnb04+bum/w6UxG3h7kI/Leh7vZ21RNWr7dzc7g2lwCQ0yNWGj/1Hhkln+zeeqLfID0ZXVF27hPVndF/oNfZc4wRjo5t73yaycmb
# DATA fAhY24qcoTtzqRru3qIE8fFLGKM8b0fz43NwSEJBTn4qzB8Fzb2SguDtsDmXnYZ+uKXO+6GjSGvlLo26LCErp4ypPgoD774cOkYS
# DATA RtTBMubOJGzCFi+Qez9Wb98Ry3952RyTkkm8t9fPpCQXUTtHLZIkcaC/xPePTBEooGK8y7VS2/5JGzqPSO5Obi/z0xs0iaCKHdOQ
# DATA FVLGDNuHUmj8Gnpb8RW/UbxRLhdv7hX26F4Yi7/ADbfZqN/GqYWcClC2oePyjr47fDKKhxBsC/r3g8HoYZx9tugvPnutUKwhQpSQ
# DATA IRXR9h4C01/kbijpRUNe2cSd7IHalk/xaHtZiHUqJinAe5KZLJgIuOM2PlzzmdkYd70GFyknXv/ys8ZNrou71kQGJZ0rF7ECJwBI
# DATA uFFirmufqTkJK+NrBKOuDp+mdf+mqhqf6TbAU+AJthtxEd6+s3sQDWliVeBT5Vwvn0x+/Wt18SBsPY4m9k/SW9zZmfRonPbujsdc
# DATA u+VIujVOI32cRVIPfv1rzAdv36EIBQdBRLM/zj700wOMk0sq8wlbUTyyGpH0j9JQbn7Gs307T6SMJM5Z82Lx+LqIHokCD6QP5RR3
# DATA K/RCmqbptkn9jpnKLunq+Hxc1KdpXabTQ5GZx2TI27FiSYGqUlgSJNb46RETlPUcZ+0r0uolGPGpmUO1TsvGadks07LJHrR2ojZO
# DATA 1GZTUZuVAuQXJXZzF+suPLpCbWIY2rItWvjm6QmoXYbKuJgCdPkhPnjbKI7k+iAaTifhcTrW+lnTOZkLRnJZqYbPS0LL3hClCV1a
# DATA J2Gtj/lStPm4LhTjD9FlcX7HLJxBpcMLaD1ZaeLipADk/mzGmPUkKyfMj2yW8pK15A1PgYp8ZzYjtAcnzQpza5p0ftCfU7de/y5/
# DATA 83f52WzGg6UTvau0+btKmXfxg+UTvau8+bvKmXfxg5UTvauy+bsqC1Lrt6oneld183dVM+/iB2sneldt83fVMu/iB+sneld983fV
# DATA F/TfbzXMu7S+imnDK9XV7enrcyCmrocKQbpoJSJrtKG+77GglXB0hqZy0oHJCInZA7DJPEkfQGppnOnyJAQ/55VzXpWHozooWuGQ
# DATA hVQ97CDgoAUoPDAkMCtiNFAt95966F8ZZmDJfhlve6oqRcMU5g1aEQyDIMIUq/HkemAbSJk/+2JCDtrqpk7rp05upvR8zpROCmJ9
# DATA 6rKgvLkr3ed1EQhPS37znLmdtnjpUljnSpwsawjyyUPTUoWLApnxNVjZKyCO+oyIBW4ob+6lOwe1cSVeSz1flhM7lDs0mYaKJlSS
# DATA jKF1Wym0BmMWuYJjlIwhPE1mFdlXzD/ltRcRax3JNJ63dkGHEfN03tWUwwOqoFLlRp7QUyFFfXrHPnYiChVoD2wylp+klzMjB7p8
# DATA Wgz95LkIs481I+e0Yy9TMv3pWEqZaumMJWcsLTOWMl2VczO/8G7mlUbW09dU1zWfqnPAstKH8AAM6T7ejJRqrI/GaJqQAZ5rZHtT
# DATA mh+zq3kcKg3sBXlvai5GAdxSBo/VFJ/r0JxjOWM1LIqom/toXNXNmEckKl2jr4xhM+52vWA/jjq8+jmMo4Rd4mOtqS3dQQoeTxOm
# DATA Fd0K3gMaor0uhSYi6gmvk8pRYgy+fYlLwvsXEcih0QKnnmXaSqjRTydiuLGMHJjfHU2EQ4wL3jtKZ9sbRO1xPOqxA0bh48KgzW55
# DATA PE85AN1qdF/LPfGpuydgW2Oo1OB1pjwIJ2JGJKn0cz/GRpYJaL6yAW8UMNTQ6vY0QK/g3UZmUtDRaKTA2wiCXXI3PSxs4yqjtwO5
# DATA yy5zD2ck0BcPkTsa/S7p5lR5B/Q2Xhlfk7x3A9g1wi3ei43qPK6yuUUlAbNYClhj56nUpZJP4kE8HscHSt9bqj+vkuui4arvSSYO
# DATA sa8znrahAcMYdPFdpYd407QJw91A06moMPApyvK69LzO8vzsGcMCzwIgp08WHU9BQliLYoEqRfgYg9SEh7AemQy2YUltEpMGNvUS
# DATA MQ3p9i5OqKMpmHFQqgNwiIIJwIsehwyfR82jbBxIITF5mizLPVTlPkj0FJnpEAMz1pTiUTKfSLGnjiMFvSr1nFeuEB/JUcmF6bxH
# DATA GNHmwSazkdbqdfPacYxhbqVXeZ0TObtQYkphTealfmV+5Rlf68tr6RdpVqbxne9reLlEGk3KwhJmATei830bL5jc55I1lXWCTsfq
# DATA hNFSzvetvHSCfd+rG2b2hden/TP64p/f2U+KuKS3deJ4nNh8y3+b/XD0DwBSHv2WuZNfMOHy86Pfz/5fECVn38y+XgRc/hsTLIGn
# DATA /NybfYt/GGb57eybo3/wGH35+dE/0Z8vhXCpAqYXMdbyewr869lfNL2SwZh027egXH599M/0258dwvLqz9seyExrHMNIYlMYi0bx
# DATA dK83YUaOyEyr4bUfTaCuIaeIzURsOtS2C5lSGPUChrfKgM8WTCIzN2BQYBYGfAZ1Lb/yAe+4oL4w6nsfk8XIRpQjWaZzON0LXDbG
# DATA cmnBXBzQkutlYs0fdTUV5FH2ZlRWc+s9VXMxvJ0nzZKMVRZSUGuYsteEmsTIkSw3KK1zB1neVlur+tQ8DvMHQf9xSmoisxq8HeB/
# DATA VLJg67YDHDeiUXYMeTaF1wk6GCEMNGoYhmTkYwGe6uUhzw0UBQnn50cLJMtjat5qs2RZc3paRMtjEuF4lm6MP8sYr2GWpx3aXwjX
# DATA 7KUN6xczqm80qJ9kTL+EIV3q5ZIcMAP6U2w/F0G4XJJUj+ah9InZc4FaJpXkIpY5XucMkO1RG+MsUszJXRZl3visHh7HAgqUvqmF
# DATA dXOOb8BxG2ZQe5vALTOObkRJJcNof7K7G1v9vAOaY2MNWJQPEqECeu8nqQklIz9Zbtjl3aWYRTAEBE0YDXltydAuYe1E8gLlGUah
# DATA 8ULWbQsNqXyrnZDGyEFEZsNBL+RYBB6bJrzBrhs62qWjXTra5QXSLjcZYjaa0mxkE1+2eX8a6/7Mxr1DXjrkpUNeOuSlQ1465KVD
# DATA XjrkpUNeOuSlQ1465KVDXjrkpUNeOuSlQ1465KVDXjrkpUNeOuSlQ1465KVDXjrkpUNeOuTllUFeliqVoFo7LfKyETZb3WcIeblk
# DATA 5fmk8MtKyavUah7lm+eXi32/WPX8evHtSr3h1Rv9UqPklRtzXEu6t7WIwxz4zbJXooyu+vkG/d30mrV8pZr3/XyJwq/+6p2KT2E3
# DATA qv1aOe8X616j7vmler5Kt1TyZXp9M1+q5sv1uTKphvVWZ5EPWKZo1z/xq8V8teiVGr5XnFTKDa+4X2+8WSlnw6i1G516aTGMRsWr
# DATA Voqf5EvFer5BkSpV8j7lBcWoipjmG/VjyJomcgscPb8hr2tHY8yW2lz8NY6E1+ai9aXmjgVUmIlvp9qoVCqnoOVx/dW0PGkKFi2v
# DATA VauGZX8DWl6tE2ZoeWG9U222UlpetVuDbW1oeeVWpVFKaXmNesX3wwun5XG1z683DNi7P+ebpqLC2cvPrAC0bZBhp0miF3FuKl8X
# DATA /X/4Qy385nFrCMuNnVXwNyuWx1P4bMiePHgyyF5lEbKXBnMCyJ52QK7MIzunVYYqjJ2qf7bHqMR2GhsDZhBbsY1Aj91qgau4mn2X
# DATA 5mvOzqo15sQxOWGIdg4+5+BzDj7n4HMOPufgcw4+5+BzDj7n4HMOPufgcy8QfI7ThtMIeW3zUBpfWTegMYJIcojlhpb2p56hj6E3
# DATA 6O/e2u4v8J1Uind0R/YKBfPkI5nW/NLDh51r/Wwl45q/U/g4joYUwIf0H/hQN415+eGWPnaexqUweYJ8/XDrtYUT6SqAa/isSVF3
# DATA zA4FHaoGP2m2klMIdwer1xysdgeqX5AD1SfVC3+6B63ZL5m60hZxRP2MFuZeHHdwtthjP6E5ZsskCQSyRmf7aZ/PfhbOKPLf56zV
# DATA vuwg+Xmrti8/l79Uv32DY/Kpn9boh4ciUIfS1rKTqnIYjZmHIUUhiQchhGD4aK1UNT4Br9xvTGQR3cDs+fL05HgOMshka6aNneeM
# DATA 0DOFBzjuduGY1geaRfcQgUtV41fMHz4/iYj4QjWRA7lBap08HbGap3Ga1TzvDCpnUC1Ro0srlBOscYI1p7WjVtprFyNkw326bgZk
# DATA SYl2BWtg9OJJvDcORj1LVPyp6aadA8CSxuXXlAyNNXqdULNYjAEEco6CxWrs14P5IBhx5lhj/jLl23NRLf6A5b2lb6TaCIUU9HwX
# DATA IFz8Omx1ftHQC59QPnrJ8Nzlg1m0+K1hMu0HE1EvP1TJO0BCR9SJdz3q7/r9i5AtnrKm0kRzZ6asAT7XGs73vVVRnobEd8cTEXo9
# DATA ztHwd77vYvrjvXCcsBQTVqqYby+yMMw2ygcRGfDTETXI8JzVqOtpJzpnQVNxBuDBCgNEDO5zloieY02m0zIJMuuYpIe0VpA3ODTm
# DATA h/Q2BkeZAiBtRXWzHJQqymNyYNcf1YQOU/UpGdDkxFGyQlqqDcCi1pWydKmgCsTiUt4DCHyHQ4/BK8M2FZSWn+oq6gHlfc4oZMWq
# DATA d9aSplh4OtRaSTwjGk9bLYjkc7kwkxjVJO4zvljGAdE4Gk8h5OXpTDM6Xsq9GcoLzGJ3oHRTN0M9Pj/TD8ugcBMQNwFZmIBkLUw3
# DATA BXFTkOwUZOXE4mlraSpeBzMtesGIYcMBZhi2OHYSKt09LQU5JxbJqB2tDqnQR6FMZiydx4ktAImxsn8AftJUcCHzEo/SYqfUlKnv
# DATA olLYD5coPW6qtsmpHd16nZc203i3DtPZEXOXW9Oo3zFafCoy7GhcdBurw6MWgF6jt2W1n4FV+KQsLGUB6R9TeLa5wioCPWbFcM8m
# DATA i7Oye4WGbispWQi4eq/ZQgCrVH1+WTZGqJdbd5ie1X7q5Zh72NTwwxo8xlhqNuo+ti1j5cidv50mqOowwxv8afWd7X40aHFE8WH1
# DATA fdQxx9iURXfelY/pvdclbbfmMOXa1pTVeNvUxIiyxtDMlC42A0uzV2ekU8s5GHfM9JQ3P8hEVeVjNh/mwFy8k9p0B7KzQCa2U769
# DATA 4j0emGTMx9tkKpQjy7fuR8xq6oQME6LWWhYvwSBOJv1DBb/ET7ASjRQ7r9UIrysaTmQIDEUOE7skk16s9EQDgZ5r8VgGig+N1Cy1
# DATA XJ4Wa/e2ksL0YJkp61Ad1LrcDKydIAM/oDlxn3330bhN08U0CzFHpY4BKC67o1OzHHhKqFv4WG3RoZ7sDq8SsG3Meythtg/iFh6h
# DATA 3i+UOk1F8TiRRTNFAeOyOI/sslrJCfOruTa/TJOTDHsPkp/ULvZCk1XwJvA92TwyCC7JyIL3AY2ZOY9V8iIywg6V/0lBxKg7F0qc
# DATA 7FYRd5jmzNOwwRi3sHMeWWU6nhNmVH1tRqleTLLpTfhxxJyPhlat4ldThTigWCbsiAnGfbV6qn0zcCJgG1wArVpZ6eJpNn6G92/v
# DATA MPUXhlgCxJ58IecCOMZ9HrdDSOoyuoJveqptsnqCNvk2QHTo06jd5SnReYFcmdpmX6bmJtQ6lZHWylsYJIdY3NNEOHqEbH6RHub8
# DATA FFskAcbLmpE/zQrmlzavYW/HVMQ0RvbDQ3YTpHWsT7+kFo7y7orDj2a31ATZE5caa8gQ6uHZYaUXUdWiqFhbUAfGiZxY1VGyVsQF
# DATA BRrhOGovzbfsQCx76+yB2FyRbLj1bqx3wWnlaTbB1O40OEVUSSpKtM7vwnEMsefFAZGyxEbhBGheGyX2fwlIzJv9afaVx1gv0L/+
# DATA cvRfZ1/N/jL7ZhEj9n/Pvp59m599BwDY0W8AIPsrcGFHX9D1/5h9T3//gf7+YfbH2Q/e0ZcSOoL+BtCxr2bfHf1u9u3Rl/Tv7/Em
# DATA sMjozRTGVxTCVxpM9pfZV44m9gxQoIey8oN9PG2lUp9SoEdhPGJ+IwPWeWinticGYieG8jl7GzHQWC5pJYbLd6GPToXV+Q3Ug0Qi
# DATA Ic/O47VUsTdgLjG7fXjocGK2D0V1BJdNE8sWyMVixKKhtYZ7V9dS/csiS2w4wSFA08fiq4x04fg8eWLBRBAFvSCh4RQWLFm6cbfr
# DATA cGKbltq5M8XuBP02Vh1DWQA7TAHVwYB32vMSSJ/XSbwuphIec+FY7s+scoCkOxiEPPnFWMLriNGvQqZveJ0onCzBiB1b6VZbJ5m2
# DATA 9PQYYsemwHHE3Oh+HqO75omdeFB/IRZFLmtAP+fxfOPFkBON5pc0mEuNtPMg3W719JvORaDE7LSKY1jt4OjF9BwWH7IJRQpMLHVh
# DATA YZFoTdLfAoO9P0qEqsRJmwTJY7VXBRGIhjg5hmN8Kks2Q4kBYCRD9T54XQrW1EnJTlJtZFhva5sA8KkYG+1gE2BtKyIDYYldMIXu
# DATA QjRZZg8oa4DBR7ADsHqVPKbATDwiOMe5NlH96mOXNvaQTSfjSMosHrbD8TBxHDHHEXMcsQvmiG000mx4AmND4/jSjPzT+R7PwcR3
# DATA NDFHE3M0MUcTczQxRxNzNDFHE3M0MUcTczQxRxNzNDFHE3M0MUcTczQxRxNzNDFHE3M0MUcTczQxRxNzNDFHE3M0MUcTuzo0sXa1
# DATA tEi62pQm1u1WwsYzRBOzl51PihHzq2Wv3Kx/ki8X8z7lT72c96u1fr4CrJb/ie+X81XPr5Q8v1jy6qV83cNduMNvAAOWzbpOt9ms
# DATA dxcIYwB8VYpNr0TvqNS9SjPfpAslr1FDkFWvCoyX5yPsJl5XbmaDrdYanUZ3CZirXLTAXKVm1YC5/GK2PrQq9Uq4JIBqxQqgbJG9
# DATA GotVorKMDFaqn/R5K1/K5bpXpnwoVb1Gnv7y/UGp4lMeecjcImfx6oTYpUh3VqrVXrXemCOdmQcWSGe1U3DKuGUYThk3MotTRvWo
# DATA Xg824JQF3XKGU9YtdertmsUpa9a69ZRT1mm0K61KyikrNWrlWv3COWWjcHIspQzji75vA8yX5Sgrs5us0ODlMQxpO4skMBOyxpxl
# DATA ZrqV6s+8Kv0pVdnpmEFzSY5KCCrCmznVVKqMY61kprtzby9V2BfIbrw520Y8T2sQXjpduUz81gzhmdu0C8whuxyyyyG7HLLLIbsc
# DATA ssshuxyyyyG7HLLLIbscsusFQ3Ypi8PicHWCw2T3nWDSK3T7MU1sYPZ9uIXDWJT6n8Okua6u8fkoXJSvNM2CoUqthq3PD7duj2iC
# DATA 9wQuyrB/SLlxDUFfo1zpTkUujI+HdS2dK3XWileRQMoCUksf5grU4SxokCFIOXYT8CFtHFAxZ7BE789Rttyx45MeO3bHjZ/X48an
# DATA wWtdgWPI7L7T/q71lC0RsDLxXnpUeQlf66ocXn6mzvBdBHAre9z6nElbc5XhtIgty5GaHiJXOZ1iQSDPKALySnWFs6tXvvU6T/BZ
# DATA V07r0HH1gVDoUOnNyUFYU30OAnqiFR/gtHO4N+1Dvk/Lzg0gJxp3oYbfmY65ggbjgZa+V2fi+d06ArfJto7I+OVtszoKmhJG2dPF
# DATA ImmLtTgn8BN5vDlFLBMstfY5bdCz47aAE5WtEC/ukE02HbeM8OQLctTTCsPZVc6uWiPWZlcup+vidF1OalCtwW1djN7L3w7jA3T/
# DATA ojjQCvZEYw2SG2pg8y9fTuwc6Fq8AqF2gOhrGW14nujT1feH0FsIlQyLcYt524/3duZIQENeB0pBOyoI003p7xkcEiWaumToyQwi
# DATA lrctFtBnU88iW3LEOMJezvTHFXL24ocA0McWbBlhiysN9tvHxlc/n/ar+kIK4WoUl8XZjjG269hRXhNh9pQwpQnu6lTHBhl1TFzV
# DATA oyaq+nsGF7Y2nv6aWM4RlNT6ElqrcrqIGjlXdYuShEp162XZa6riqdYYbS3f9JL0LtG+pIDGX8VsvS5BnI0CZTGbrPZtCx8pfXqF
# DATA eAnQ7I0+4F24nuwGzA2atVLCJ5GouPBwhx5Hu6A+mVIvBK3yZLq3F7IHGsAIXplQHUQ8BsYCUCVWlcYozIEOAajoaxqXMNDYN67a
# DATA HQRUyJSfsj+eigZ6MFAIDvYMIxYKVDBOExnJO1GXpVMmoj/Eys6e2sobmviIHD2kiTgaS9SJUkkillWGpxGR8YIR1TkMcJuynZ4T
# DATA Yzczgjlz15m7K83dBdPGWbzO4l1twl4RhcM7rL4HzeIuBployDJmy/lOmi+bSgGOw0HEiI7cKtW914UpuDDcsLDZ3jTqAGeYDowU
# DATA GrXXzhQAQh7e5k3gLDRhQeDQ3EfjumGaat8TD/XvMycA49k4pqEjmOgxl+3wATXwKUwoZQcEe+NQ4ysXh0ylf0ghdWioNsmBq2ph
# DATA 4GRpQIjLsOcoZE04L5igQlOEb9rUdk2GDJ/w9ii8IwLUgHJ9xYxAJN7ifd7fpBicmp870gwvbOQUUMiTcNyOsN8xA0GVDOeCYdE+
# DATA S6hQeckK3hvgbHE3yt40hnb1YHPxXQwwAbES7rq3wwn3s5wMmDbBZM7fhoNrJrIeH24A+2RdGm9rOUrT3+tEfoBZm2bvqL4fKpM5
# DATA 0dzTYCI8gvVHKuh+kmM6RmKondroEjPpXQSGnvIQJpjaaMkjy5iHpBYs7bATtQMpQYXPRFYu1HQLcxY+oTGvf7gule/ykWJjfjG+
# DATA RKfzNu/0VIdEpuMcPMmsMD7Qxc/TR0XKiQA/UebrEEp8SvzTYqRxkrJKlQXvQRg+ZkoI3LLM80Be8q2qWmjFygxfhv2nwg2B2iIc
# DATA xNpRHCQ8qQ32hnESJQtkDjbEjtP5fhhTx8T5mXZB3GpOTIpmn7Yeg86FE225uVVjgHubndgXQIZ+B9VX74Oh5hqg6or+u56mXAAl
# DATA +k7GWY42S+UtdNkLIEW/HU14VjambgtCkAKFVMwa7jlFYPICYNH3+vJOdJCc2rRx8TSrcwGg6NvUAekWj16qY/R1uUjhLRp3zpmd
# DATA /LzP3ywuDj01SWwszr8CgjP7fvbV0W9m3x/9dva1d/Q5EDX09Wu6/M3R7xfJOP/GqJt/Z6hN9u7Zn5mS49FPX8z+MPv66J9VKP8N
# DATA XBy69sPRP+AJetXv6Ze/0Av/7B39Y4a0Y8F0HBrnGSALM5jNaNcKIwueXyA9crINVbjAXe62DgDlPlAW1V7IisGP4XAWnPBEsxIZ
# DATA MsqDKBiCe/31BJy3w6DLb3H4m8wck9v7ZdNvrMK4OPSNJC3tFrnudHkeNn8rRg5zI0/1xr3DSW9wnrgb3mRL054eanyHZwRA7vFW
# DATA TNzusDfHlti5824wyY1bmGNyPdMea+wUUdNh7l/6wXiglqbSyWeUiCt6YQ+16KezbStzCSot6sUwrSPTBQ7uBfzN+vq32vhI29HT
# DATA wt6sj7kj3rhB+wSDtgbbnGysfjF8wZczTp/nML3RKL35IH3xY7RUP5NoMyBfXlu4CFKNSY8QkpP5hOj9F+kmBrYnevFAw2CsMpGZ
# DATA Lg1oGOyCDieUKeiGSJEoxnI7no6FTZGOrzrhcpSdXoK84uA349aoKX5mDA6Mc12P3mbcTujGzrQf6i2RvIQFr6KXjMJ2FCY5E/+U
# DATA Xawcrf1IXK8hdbZBN5wcZlyBKh2M02VMNKOA25KobIIcoMYBahyg5vwBNccPHBvNOTaxXy/H/j6N+X1W69vBaByMxsFoHIzGwWgc
# DATA jMbBaByMxsFoHIzGwWgcjMbBaByMxsFoHIzGwWgcjMbBaByMxsFoHIzGwWgcjMbBaByMxsFoHIzm6sBoypWw3DktjMbvVp8pGI1Z
# DATA bj4piaZcanjlSrHH+JlSxfMr5TfL1VI2O9rdRrG6yD+pUALKlfov/FJ5nn9SqbYrjWX8Ey6lbDDlZtMrVUr/xW+WvFKpSH/qXtP/
# DATA xK82vIbn10ueX/XpXWWv1Cx/UvJreb9MZQhiTiXv1+iWPH2jmyp0k08PVP5LqUmPlrwyhVBufOLDi1zxKnRPuZZJVyVsNGvFRUCM
# DATA RChPJnze9xsDv0L5ghfVisDzzKW13ew0g/aytCr0DJViROaHYtdUitWUXVNpFq0KXJEvh0tqc6cd1trdU7BjuCIbdgy3CYsdUynV
# DATA g2r5WHZMq9vp1jLsGIpPo92y2DHlWpMDEnYMdRLNILTYMdVqq1y5cHZMn1rBsfAYOI0+S281lBeL46JSt+jYY+deif5t/Mw2t+ts
# DATA PqRBHo+ksXkzvNlO9hYvi4VxXRWWrJ+SheVhqdKryZ9MaJ6yaAxQhkdR0/tnyDVSxHMppjBhGXlV+WNco5LsBowr25/jW2s8Kog6
# DATA ZZhPf9S/2sJk65UHxJW0mg3KMpt12Tn20oxYGZCD2jiojYPaOKiNg9o4qI2D2jiojYPaOKiNg9o4qM0LBrXRBqGW9tnaeWXdaMbw
# DATA G93r86kL9VgOfeDSrtVTKbMq1e6tSPdeu2wS79xEO/9w606q5oXDKpacy5ByWGm6YPqaZdaYkw/u3LA7N2ydfHGnh93p4eNOD6/U
# DATA mryQU8WvouZCaS4N3Jwsfqr6E+eglw6tObz5IAwf8wlHabOn1JpLx5bzU5sLw75S5W7JKglliFYfVI7uC5Cd0+eNFbhtRKXaGUN7
# DATA zqM5Utg/vADNubeGONQ8kR42UUrZsJe7qUD1BYjPPWTXl0ojmSCqN6c6QWNHHurXnQvQnbsvR4nhAyRTTiXZwAUupFxZe+5dnLUO
# DATA jAAdWp6McDBZyLzEXqjpODxn9TnlgTHS8akmY0YZID3cqhNiTs1ShqELmGR6EEuiPhWFFwl4SKjOHdbn3qiQqmt2xoc6o1NUQ9A/
# DATA ALdwELKEPG7BQhUZGv1+wXs76prmkAPuob/YFpWK6hBRGXs9+nEcYsGqfyhPcvdyECQSHU0UUmq1XAdF5R2NDd5c0a6mSQWW2PdV
# DATA ANQ6KJpSX3rwDY7ViXjoZNKjXRpSVkkG6FzRx/2pmxzi5DtvM6DxhKUAaKSel/iZG6nuhzgOqE5xy6RV7pBx53jZ+Gf85LFDTjr7
# DATA PbXfncX+3FnsJ0VKPkUdIF7MNwvR6zmSr0csf67gKBA9H3q8l3cNRPKS5YOuvJzGRfAhU5Gj84ZD2nJQpyVDWpsU9LTpPo5Vmeog
# DATA Ez8WTlHCU6W5gsSuBilFtbsRxMZXx/IwaADYQqehjbe9/nQQDeMpTRGNTTSkSh5DxGYU9vuQdscY2lOK62R/DQveey2R2yfDBJuu
# DATA oaXUI5NUYQ6YZ6PfbkfjDRhofBcnRsfiXdhFFATFjiov1RrL7GKTj8+PhLwN4TCBlnqQsIS6tBCt8TyAhPV43fvZDe1l3v2GtKCE
# DATA zMuEl6IL3jtxMtH2n4gLMftHx/omMkjaF9hLUL6h/hq2AYTtqRuhqs6yIfMxed5FYqyewdlqzlazRwbnbH1xna2rmZNPU8LxHV6s
# DATA 1PVZCbDx0WsLSglpPYYj7EO7TdpP6rzJsRuBAZPsRNOOw4J3LxUDxCkcUWkzaB8uQ3YaBJZ+IPs02XfQjdpeQtP9tvGstHgrWaoZ
# DATA KJqLG2pAcorF8ZE2flnrQ0yGwXiseUJ8uATvgddniZGozjgu0i7VOjcqKX9SfjLlydI/pkBEc4VzHNiRkMORp5X7Ke73rRQsJUCa
# DATA xXOuJvL5ZdkSoF5u3WE6Svupl2PuMFP3HVafMWL2+3ppNII/NFbW3PztZDdwq4oPVt+zx2YPI7P40+o7W2ynsUb2WKwUfed1SVWa
# DATA DzIea2+hrEDbfj4MDWtchWttRsvzGYw7xgnPC/7ijlc5aOXAHEiKdwab1i9L6VyFxlPOidsmAfMxlrwcscF2ByKO0RhCpqj3qdkK
# DATA ey2vNDlzIjGax8xMa5DSMDaIOyH78SewZ2H4aQtOUEq2MxEOSCPVGbLQkDayJ96vaMAt2P7VDX2pntkmx5ZGNikma7SEGQCvWO7m
# DATA RkTPWE7XeVv2RMWTVr4TltCD1SWkq7EU0oMR+2CzJUTNmDsS8bgD+wKtzB7ZP+IGDTyp68rqt9iBZg0Ez8sqiEitxlAfxZQDpYsd
# DATA jMpKOXvZ2Cm4+gVzb9OCuReM+ywqG/QHumAexF2GsQ5pVGPN1ANM8mgE3cvOzQre7f04wsyY8t649XO265tLZUT9CyZnHTVLxPTw
# DATA zOVhR/zSyiPte09YHn+zujx0Ly7l8TdksCx0ZNN2e9pnNVksAqqThKpx6MmqYulRL8UrCTiPTUNGwXuTWtdhjoqQzJA46ovK8YB7
# DATA sXgwEPlnMi4GwhKjnyLkoFkvPntBpSm6+sV0f9Niuj9tteb7s1dZxFr1ZuHw4/gw7cG0GFfB+yCi6W5nSh39nixFGflkvSqUWnhg
# DATA alNetYOp0PHOXBZ2tK9+J/b6pp3Yq9G4wzsGhnAAUeMYWo2nJ4rXvekg6uSxUMgS46o8eNRJ2LCHtNAElvkHgeZSp+v8Nm8PJWx6
# DATA OwqJjCe1bQJayHAPnbmcFhN0qtLK2n+yjdG2/8wVyftb78Z6w6HW4BaTXyxuXvpnqGVAMxZkhy5ltXB6MUy0Z9rjlbLQkl4cZlBo
# DATA /8fs34++nP3h6HdglQFjRp+/mH09+4/Z9/T3HxiP9mePYWffzL47+t0iGO1fGaP21ew7evaPHv3FAc6+yVGIsz/RN0af0f9+mH1t
# DATA XmKT1Oimv8y+xifFUfsPUNHwfnnvD7O/Hv3WUdGeASi32ebAW17jyYHGrhoyN8SLhbya45kRb7MKYeJpFgCgoXAnsIwMdQACZ0AH
# DATA OgLdQBFdqR6PJ7xnDM91ZQnLOAXg6VhLToOyPJqC2PkOn2b7+riLuGx62nyBXBxCjUaLoB/vpYgv3mHIL5/ncF/vRmk3/Xo0sfAd
# DATA 58dQgymtzm2ghsYygnM2OHza8aV17vy0dwQD7rXIuMCOLpr392jcMdPLnDaykhiHoZCRMGSRTHR3ak8r5jeKNP4EKilh2jmxzleO
# DATA bCpZjhyH7Flkwqw+JjCgIhK8BgaryQJbbX29XG3EzLWypwVYWx99B1hz4/85j/8awnaKYf+FWN67nCH/3Ef8jQb8E4z3Fz/cS0XM
# DATA Jt2M8ler+VwEty2bcB4kOUMMdMykunWIkHJyhnE8lVdJXCcCdEoGARa+zNKbJ/1SK0zg0grHWJrkRNNAnR5bUNHrRF3DdqNkH3qK
# DATA ZLIhs22szDXeVoMjK2RQsF8ibD/G2KTQZFzHhHvFp4Z5J5DQ5qKE91AlE6Fx8dJsmEzEVEC+pJbDTUUxAz1rMqUQBsFw2sXnsW0k
# DATA KM8r/ARs04wP8/HQIdscss0h2y4Q2bbB6LLRRGcTk/gS7frTmPVnteoduM2B2xy4zYHbHLjNgdscuM2B2xy4zYHbHLjNgdscuM2B
# DATA 2xy4zYHbHLjNgdscuM2B2xy4zYHbHLjNgdscuM2B2xy4zYHbrgy4za+W2+XiacFt1W4t7D5D4LbsmvNJ6W1kq3rlSuOTWjVfrnmN
# DATA ct4vl/r0T6nkNaqeX6Rfyp5fok+1fKncrzW9as1rFr1S/ZNyha565apXKb3p+81P8o18ue6V/Hx1LkvDZrfUac1Bz/x6pVauLIOe
# DATA NRdLrlT0KsVqr1ov7Zdrb9LX7AtMWFkKW4lSUKpVvbqf9xuDfKXuVRpevZj36/Sl4lVqXq1BXzaOmF9eiFnVBySu/km+TIWaR17U
# DATA 3qEAENt+mS5kaHG8kzP7srBbr63A3KkK3I7GfMLuiVT6Uop+8+sMkmNVg1q2BZhgKQAYNp48XUTWevJwo5Gt9t0uf9f9L8uhsvhr
# DATA uUH1hsI4ITaOm5HGxkmLtLBxYbVRqVaz2Di6qVKqZbBxcyA5wcY1O80UG1dp16rVeoqN67TbrW6KjWt2ys1ieOHYOLS/47FxZW0U
# DATA iEmgn1nBj0My5/yL1Z95FfpTpj+16s/sIOZ4cW8NaCoxyWErMOLrvcuKHfTVjrk9TaoWizfnnXni7sk19g9yvEq2YkVMRQPwqtGn
# DATA my4VFCpWXnjlcTYYT++nyBgkZr6EXdXaxae9nFmmncqkEv3xq9rkZ19RNCELq50B2WkfNvXLpQX8XHE1X87kfs7OgTWmyDEJZCvB
# DATA ceQcR85x5BxHznHkHEfOceQcR85x5BxHznHkHEfuBePIKYsj2wFEQwp/F/beh1vS5ijh1+Q7FGE4G9jE/HDrYTCGCi0/4snNaF7X
# DATA +AJVi9exmW7b37lGudEeFD6k/4a3rVPid9/PHsPjh98JJr0Cz9C3OZyf+4UqQkiP9y05NJ4q30KKy3T7GjWXHltxh6jdIepNDlHb
# DATA R5vcWWp3lnqNXvLTPWMtR4Nz+qzvkpPW9825QKkjuayymjnUKwdWlSALnyWGHX2gdJjlJG/IKvvp4clRcIjJtByehNbK0Do5ubEG
# DATA 8uuietwSRlQHBCq8OjAdOjoCp3u8ie5xO0imgZJNw6fVd6JLpazFrR/Ix9X3UgfbiWPO6Pfk47OggJzmxQlFEO+sFkHUuSoiiGSU
# DATA jQ870CEKhvtBkiog4uQkNS8oiLdjdptMRyOce8ZGAxxG88YiC5kAzyGH2dkLRk0tLHjUqiMcHZ7T0eHxsDM+zHlhkBxyQzm77uFc
# DATA Gi5NotKqf+enGGpqstKphu0wnsKMTMumPU16VHNDFsnFGXQ5Qh2IXDWbOakRAasSdolgGFBQPXDv0EWkytRKz4GPh09RP+AvbWnm
# DATA yZnUqdMEPAMF88HGBXOfqnoebpVDaIBbyqF8sDlHJTIKufVws9ENhEEyKDjqj9BwtG4ozhFCsQqK4eGIbUNkuKWmIYIDWNuS8S3q
# DATA 9+IpS4+eXd81k5RLK6VTd25vb9q5vRNh5ww0PKZjSxmZJig058OuwEk80k2nG40HECedjjxVMPGYJdj4V1EvOaBEjeOWdHfjEF9Z
# DATA N2w67JFRBXUDW8bjLEWSifmllYg1SJ6wSB6uLhIz3EqZPBwHUV/0UgIya0yh0PcJjBPYb7HkcIemPTDyUDUNDXMcqOagNKsBE9ZK
# DATA M6mSRCr2JiIs/UNReztzwWSjf/XbyoNN28oHMielCWo0oipsCga1G5YzTd1lixAMax7GeToKVY9RwuM9pvng0WJjrkJmJaIZrkTC
# DATA JyxqjdKF5/TMRTEX4xdX6/h5kBPRjzvvlvNubeLdsquY824579bGXqyVTrCL8W6x8JYB4AXeXhyLKJ72bV1Z/dp1vi8cafBsD9iC
# DATA U0voptgwovYh62sZb5NanmE00xD773miqhZKt9uDHeX20g1TJqUoRQnVPG+6svSKcf2UeHftGD03erFBxAZSibdVDwLe8qo38oYj
# DATA 3npd8Fc7yHgFCbU8VuU6MqplWT+ZutHETD+44JryFaEXdk/nhud77cFqP5ZfqLIDgQKLwjHdXahm7l/wZSkLyzgKZdMNBXFXyxfO
# DATA 9bKWmYTyoyjw4SKdKtl9ZZsu6SVp4pGYZyMaDyeyIf26BHFGA0iMFAxGVnuz1SwfjsX9KsRY9AMLKtF91mscai9tTmYMbMOxVyTY
# DATA CyLZdYUt8YKRotlDwTOQu7SeFjwutBwPfhaQhcUr0yChV5lo6xivgzU1ioaCsUKYZBEbCUIsKLKCGg6NQdKxdSjNU4T5AihQ2quI
# DATA yXQP/FreKZCuYapp61BLULJeZSo7OWUL9dAz2wX0nrgR2zAaL4usfu4Nz3SocaanMz03MT2drfn82porrcMrqFbNJzrM6YJFM6xv
# DATA maFvwOzkWIFCPg5lmTDRVmj6EMsuced79dStr77kK/8t53RuvUw96HzD0scCEa45wtWQE37WmUW5EPT527wI9/xxPWmm7RiTBXnX
# DATA 4bAt5rfRv7r13sJpP97BR4W4IG5uPcVfOC0bCIunx1a0PTYHBz8IDnn6Aj1nY5jd4SU7mRwNzaIg/Il7FNLoUJYXZe4EGuEo2Oe5
# DATA S8G7z8tZE21BqXuUfYZaCZexOOPY4Jlf6wqwHk5WmqZ1bFQJ5ivT3SejPkJNoifYui7LkFK9Lx3ucenGU4opowq1H/b3ptRd2LCy
# DATA fzv68ug3jCUDQewb/vwd0GWMDfsjiGL45ejLRUrZ/2p+/GL27ewboMj+yhf+ePTl7DtcynmzP82+YhTZb/AdN/Drjv6J/gBE9gd6
# DATA HUBm39DPXzHK7FsK4Hv8dvQ5BfMtYGVHn3sUxld04Z9wEWg0xy57JqxDpI2nXvCHsFy5rr03QCQNxo+xyhcMwxzcHjQrHfPccRTI
# DATA 9AeDDM1QcVSa15Cgl+FNhxwYa5NPoz6zUalFB7ybkyaWwUQgqSG26lNntpZaJjDpUAZKBy2zbUWrw7hsdNlcqVwcuawTyTnMxNz5
# DATA mrrCFXWBXoZxz9xJlU5q4vic4WU8z48S3oCA5sA7w3RUHcFss1I7d4qZ7my6ET8X9MWplLR7YWcq20T6wo6H5AeDnLkX81jt1fOr
# DATA +UE0hK0d9KlyYx/JTe3pZXSGWGHjkAIWkEI0RBcsZqCyjKRN9g2+edOqudrEyTa1p4UvWxt5Ry9zFsC5WQCaW3bygf+FcBBd5qB/
# DATA 3mP+RkP+CUf8Cx/wpT5mEm/Ty65E87kIblkmxV4oc/REPFJM4fbibnbfHmfDpEex3ON1EzS6CPs0jWXEiKNBMOKEy2vRR8m5Aaqd
# DATA oC5hqUUjk2S/Jo+4Uu89I86WbIgt45xTlcKj7JjidTLgAwgi7rIDbRhQESSIpdfBgR+8/PEwPpDTER21uRTYqFHIRd2Lp2Owv5hB
# DATA FbWiPrIK1h2DVmg8YtwUjAXRQGA8lzlDoEBOw3g5fMpxzBzHzHHMLpBjtuFIs9GUZwP7+PJM/NNY+Gc08B3IzIHMHMjMgcwcyMyB
# DATA zBzIzIHMHMjMgcwcyMyBzBzIzIHMHMjMgcwcyMyBzBzIzIHMHMjMgcwcyMyBzBzIzIHMHMjMgcyuDMis1KhU66XTgsy63aBbfIZA
# DATA ZpkV55NyzGqUJ8VKr1Zr7JeblTdr8wiyUlhrdxdzsuhTVlZ61UadP5cBGVOfK5Sx/LnR8HzK4XKlOPAbxTz9qz77+vMc1ItyvtMt
# DATA LYN6lRoLUShVKQrF0id+vej5PhBsXskvTny4jRvH4cPq1aDeXvqmam0Bh+bXq+CSeeVSvlnx/FoFEDS/Shnnl5n8Vmke87p2udZa
# DATA TiuzIGp5TAcCCPRLjfaaS0BmFJcUZEaRMiAzwbGlLaBS7tZLG+dvbcmrSsV6+qqy71/gq8pCZJNXlWr1C3xVtWSnqlG8wFfVGEWn
# DATA U1U+5ww8EVSOuzQNlZPe0YLKVUq1cqOThcrNI+SWQuVCP6x3qilUrtqphY2ygcq1a+2wbUHlyvTeRu3CoXKyuzAvywx6mCvzDMLT
# DATA q1PGdmmI+Wc/Mw+FeyOkzjwKcov0t8oy+hv8n/X9g1xN/J8q5EGwGeStUF/n1tTTszTQ+QUS27zX5bPg2VQlkwmHxS1WuL5+2mpQ
# DATA B9bJOr1OZod57K7FUtVqMJyVVWvsuYU4Z6dFF2gdOsacY8w5xpxjzDnGnGPMOcacY8w5xpxjzDnGnGPMvWCMOdSFaEIz/HEALXaq
# DATA YDcNdm731qdmTjJKdrmeSC/F55dx9SOr5UvD371lmn3U3f4xP6oa7s6nikunlYsghipnvhhxNOKuWozLm5/JqztTWXvetQP6ueDu
# DATA cClF4DGXTpZ07Hvz/s7P/eo1v4ro6NBuSQCtKc0XUagmZiw3ywq0wzDsJODd6WcAyRMZgsRoL3XDA+lARnIqT8S+6BKfYMwkBxmN
# DATA U4y72qwf48WSVbL4tM0Tup2CLD5sbwe5/VxEhRBcU4b2/s7PtyNqGsVXasUb/k6uiE1f3Oqx/rQ72L21Pbi161cqxVc+3HqXqiQf
# DATA seRQkUHK8OF86vZjmrMOrteKOz8rVXZoBtZhPavtUu7DrSLu5sf0M4Of0Y2LN91Ma45kOWrAdsKxVlUHzqNdjt82Us+owf/8/F+Q
# DATA sclNXLm2u6wwt6OXs4X4il+9UdS5yaHe/Gyn8HEcDelZBhdKpNXHa0te2Y2GUdJToqh+VRcmTsuKw0UAiO8PoTIhOAA8z9DD7bkK
# DATA k9e1YseuFtR4uB6ZbNmhSN7kAqeSyOtZBT3/yjqTkVseGk8azqcYB8kYUoeOtXKGFrfQIWu2oq50Zt5Fgevz0IXJE/QzVhwl7Ac6
# DATA TP0QDbgIy2Aa9UE0pxThlCLWK0VYxxSdXoTTizixXsRKndIL0ZG4N52kDYB3bWlNTxnZjajEVZQxugwdezFWRMZ9LFbMnHI9LqW6
# DATA 9fp+03mZC0bovdi8oRbMlXD9Cj16NeCyIv0EJ8uZh2SEvbfVyHuckr4JxkQpvZIq6VeKy6T0y7aUfr1UtLX0/epqKX3LoEH0OeI0
# DATA MaFZFVerrJx+5mYr3+wgFtTyOWa3ykVtf6zW1a9wPCvV4++scZi1JWEuaO/rA4yUbj6IeEsZxcIMQsuhW+UXlTMpEwqTBk5Ttty0
# DATA 42M+EzLl9E46nvFQKBOQW9bluQI5n9fex7jJLd5+a3r1Yl4qBx89GmjH1E1k3pz9KcV7puWyko4gPZnCBDy7SIS34d8TqRtlrGhL
# DATA 3lbOMBozHZrQWXZ/ppNnMwjCH5lblAAvVWHWnoHkDOtpMNyAxRw0g2CVBk1WdMamgi3yv5ZzwiQDM/MHjIR6hYJ9W3oIsiFgx/IN
# DATA nn1xi6yF4eYlbl5yzLwkY3+6qYmbmhw/43iqEncY41HBdSSQOf1U5e51MxER4AFrPpm2RqUXJCxyBcEp1hwzIlQ5UU4bBOK4NEJo
# DATA WqxhfnIxh17ANhsb+y08WtsAE77mByI8FwphFq5StG9KDFXoxExpmNFF2ZN8MkU09/i3aXJIY+6QmV6UQOkscgpCJNMjPdAykJ67
# DATA i+SxDnTUiyfx3jgY8VA9CmFIK3nfaMzSY5LE7LA3CRir/E48FmVdNdbNw00FkWxZfpJaMUcsHBp3ZOjbDhQGGdsEVccmvnusTh0A
# DATA RQ59uNvCTxOsRC+w8aLwkIMwwFJr8O2ti33UYatubeTnjUdJgUEKCEQ4MQRhqPhPDOi5zYJwCn+hNYlTZT1h2Wa191SxtNBlC5/A
# DATA 6rUDqb9r0nQbO+yHMcit88kSMyHLjV1QVTQVmczCe3DvqzcjX8ls64Hgq5ANkgX8A4C9iDzWktss2wajJodKNJSkgHkH7208TVR+
# DATA qIAjyofb+3HUYUlqVmkDQEGylAaomImxA0itjfikG+9OWT6l51j/rdBElANcJmU6zlhQzwhXx12ZhUGHbjCIO9K4UXh82ZSVpw/P
# DATA xd0ufOq67LSGtZRhzhtNW2ShWM+x/hw3wqADC8gbcx2WykpjF8OL+ZUeSOw06JClnVCbXJfEB0CDK7jXBIOIlUQQyuSF1DNE0Pai
# DATA 7o7SOqLnu9N+/1DxVlRM2Y2TcEWVdA8ypEJWFpQ+4aAXK3VE6iCxE5SKeNxDO5QCQx8/j6gVw/T5s6cdLczZ0hurQTvT+bk2nU/K
# DATA CnvK6tD2nv/1sLCHGAk07JKNKqnv62lhV0dN+pmQVD2OIJHu+9csr/OEimUVss+bKTavOL4UKabcb6zmjULlXWhkBEmNSMSsifu2
# DATA OzQc6U7s1rusXSJcMZqqsD6xTJroffQ77nk9Si1n9B6QzB7CLhcaGdWb9F6ZmcCmld3pMSy8CFJkh+qm63F/VfMUexl2LqovTy2C
# DATA ZQ7GtZgQuGINyXlBfxwWGMsQj8ao0UlompkoOAdmuirbbMiwH+AusnMz3layuSFabGuhs6XNU0jJqSmLkmsDd2GdbcHWe96svBRr
# DATA dhC2lPi1TTX7X2Zfz/49f/QPsx+YMvbN7PvZH5kuRp+O/v7o89lXNmHs6EtcWQSc/Z+4PPsDPfw1I8q+9ujLV3TxG7r8Pchksz94
# DATA fM+fmHH2z3Lf0e8VyOwrkNToBV/Sv79XIDOOz1eI09E/goHGvLM/zn6gH+j+Pzu22bNiy0ojR8PT4uu8ZGXIm1gHojmcqIvz5C2m
# DATA 4CZo9YgjtfL3obLIDHnxHsX77OUJxqlXySIhonmsRZm9OR8NhzOzbdq0o7hsmtmSgrk4opn4VJKFl6vr87fLDgJz9/0woRGoLQM2
# DATA F9I5o83EvSR6/nCtyMIfUwsc2Gyjwjt3rtltz9I7T2cGpgbwojGEdKZ9pnC0DvE3TlMo9xyoJxJBsXPu3Huf7hdN85zmVOj9LgZi
# DATA wvbPPuDFHl3sL/DMNqyZq22cxWb3tOhmGybFcc6cNXBaa0BjzU5nBLwQTq1LNAAuYvzfaPg/2eh/iYO/1M+FnLBQZ0+lBV0E2Wwh
# DATA kUw3o6xKFqMFxpksK3tUPVFTbwjoKee9+fDhvQc5dbBUrQxzyfCe0THZD7yyw8nACA2nREpTGquy1J4Hnad6zN0Ub2aqgkd5DWWw
# DATA rAGAlEVtYM5SIyALOBuNww58I1mjwDYGctxM0Vl4MDCGbWUesFUADpWYh4Kc4vgn9JqUbsZOleQw4aOU6p6W45s5vpnjm10o32yz
# DATA sWajic+JDOTLtfhPY/Cfm73vsGcOe+awZw575rBnDnvmsGcOe+awZw575rBnDnvmsGcOe+awZw575rBnDnvmsGcOe+awZw575rBn
# DATA DnvmsGcOe+awZw57dnWwZ81Ks1Y7Lfas3K13W88Q9mxh/Xkj9Blnrso8poQJbatSyhwW82ulbK6XheUk2d7IZFynEVbD7hy+qdyo
# DATA VgXVNY9vqkgWW/GQd0s8hH2VxqM8f2itlEajMo+tW8YLq1m8ML/ZMAyqDCHtp5VOw6+XF2tOo0JVp9GTOmclL6i1mu1gKT9tXfJK
# DATA Qkq7oOSVLJrXxsmjh84teWVhfF1Q8srq6RMljx46U/LKpdKVaCTlcuPiGkm55p+hkZQbxTM3Ejt5595IMsk7cSNB8s7aSOzknXsj
# DATA ySTvxI0EyTtrI6n6jSvRSKrlysU1EorFGRpJtV47cyOxk3fujSSTvBM3EiTvrI3ETt65N5JM8k7cSJC80zUSG9habHiVanW/UuuV
# DATA m5X9fKU2yPvNmlep7ZePA6iubgSnoWGypWtomGw0WzTMcqtWalRPQ8MshkHXt2iY5VrYqBgaZqvd7nTaFg3Tr8rPF0vDVJt5ZXZn
# DATA OXvUspvhY/KEnUx026nW5DX2JdsmMqFi/rp4z/xWhcUlswYvmRUa2Coji2aZUNWC+dqQa7x6ln1MzwKXbzZM76bZ5N44GGTW6I5L
# DATA rnpmyfL84g16pX4hzxfvTr2Iq3ZIyot8KSJxBSwEgqWGRdSnqnbZ5YJmswkPzMngnewxWpIqdhsu+J4Xtwut5H46WqejdTpap6N1
# DATA Olqno3U6WqejdTpap6N1Olqno3U6Wuc50DoX0Zx7UUsBFLE6B9NTwTE1g4quXPeLlUa1XruZmbOox/jwMB7TiEMyzKcjXLnm48lS
# DATA 5aZiY95Vx9ihHzCc9PqHhnPFiESKCdWr17G/f7vEWMQ3olcFqfg2zpnLKeVRf5p4EGz21Iv4WRWlVc/f9krVn5m3pUI7Mi+lPNgP
# DATA GdW5TXH4Odb4d5aFZLMMrXOmThDGCcJkBGEWDx07dRinDnN6dZiVSsoXqRqjO2vIQUh7QXGxkgM22vDOG0tC5uromF0G0FCGSgZ9
# DATA yEDGKhx89RiQoH4y080nGWQb3AhLQYK+xRHkm4r6ToMTXE0TNMM5WILqM8JmwZIRBkWdBG/7b6NXjwMiWsGZpNjXTGqqx6eldIJk
# DATA iLWBHgBeUTEJtt85Pr76ORNZc8GK6WaZvmFMtR3E7RRCiZAcSe0W6rpGUXhcdUkDScGT6SUT9fpxMa+tifVKyJ/pAvSUicdDVcjP
# DATA PPRvGenPWIih6f3QM1EdE5YHN4+OkdeBbcBFGgx4DsDLMywIo+aabZpUsVo0Q02wN5KmNznvoEeVj4zD8V5ohaZyt9ulvrY1HcO3
# DATA gedocjUOodAUTbTAj/JXy8wjYVluVmKiKnUoBjLrYNr1rODdiQfsFqOuL6fEeoYdo/+Uii6pyVxHngjGShcptWVSyOyA4jUds29V
# DATA iQ9tQA183pRiHPPETQRWTASczf9C2PwnJZ1cFaVIe6fEeuTJGxGPmKKWyOvREIkbsmoPta1BuJZ98vTkJZ8tdbXj1KXn9nhcBPhk
# DATA UUDzvOEny3RIlwJQMmWnt8RIRV4G+Hsd9rw2EZbewaqea+94VUxrY2icUO5bkf8YVxmx4CBAIqLxGUykzJW5uQkO80E67dZ4xTcf
# DATA vvN2zrvz4EFOjcPSXnhYUFrugFjKvEiEFkdQCQ20kiorNVIpGNnPKEnnDRpsxw08mmDYXkNUfCCdgWx4Ww+LvG1FQlVinaLbUAId
# DATA KnlUjh0niBLWCUHzC4dtKIIOQ4qf0mPNUe2l6trTy2wiz5pVZV2L5sx2IMdEXQvOijWto61gimxwqwOGofgzBEYKs1+079mAHh8q
# DATA SUwVy4J3T3NqEHNeHdMdWeB1g6g/Ha+jWd6XYLBwtYpn+QJZ4HZ/7WxwZ4MvtcFVJXGeeOeJz1h3K433q6PfznUaI3WKcw488RQa
# DATA D7z4aqIEG/diHiSz4uPahT5PP5uOgBMseL/AHvFDg2ihOzrTNkRkBhiLjbSx8bcz0ZjtnY2F3FPdAmme+HrrZW34PcAxb27Y0K9I
# DATA FABbZhyqL3j5urESJ9J7T8b4KMLceFVbnPVkb4xjGoOpYfeW3vC+jOldUJtX3PIBTDakUrS4WWwat17HO6/r98tgNB8NZagqA85Y
# DATA PPymzq3X1OZErsE5D8NKl/r+mMqMsZ9U1SYdvlONETlPBuOcltoG5w6Y4qQn4XZUtFbE451gSHWqY9uCJjK3Uwn8ud8lCrbpZuwv
# DATA KtFxCPFuXjzQltfxEflFNJ5MoajOUuJWHFQBs5nHtZUl5blPGcd9E5n3RqyoYm6gSh5OWCV9xIMnZVC/r6t6YsXnuiqo66rSreDS
# DATA r8d+P9B2Xpr3YvIFnQEN+nqWk7J9tJK4IrUnvXja73C7FHN2CMsPG88xtRJ1dSnggsf2JVnA/fhwwEGQfQ6edQBxeEuGHiz6j+MW
# DATA D5xKYn46ZBaiCmkdEHwYHyi9cm06B5Oejv4HY5azp3rvsbiJOLt5vUX7jdnpTNY4BRNobzN6Kers+B78wIzU1MYFEgqQRX07T4xA
# DATA qh/CwU7DeTjU93YU6zFdG1yXmHfEFa3SE4h4Pvzqxr2vPOuImF7PSLkKvbA/Uv2ZLHhafRHL4NNAGWegCqMweIwSlh4TdQ9rlp1w
# DATA gBfYMywFVqBQZD7IWHi0AntqpuwYG3xu1j9RP6PBhgzx58u2/+yzjz77cLj10o+e9/8o68P+I3QY0XAKqOro8NzfgbXLWqXyI7Vu
# DATA PPevX6xWSz8qpv/9qOj79WLtR17xMjJgijZHr//Ri/nfT37yk/tTIUS0qQOJOjzOoFJsJbwXOc/Yj7SCeHfefot6DV7mpPYd9zu8
# DATA hE8PFCisl0QqhWzbPT5so79/TPah/hwnL/HohU6/H7U8dfkefdW3jM2DybSl/DP6Co5kYTjQ36dkurz00gf3b9+7d/c+NlBvbW29
# DATA xGdsXlIbLLuyr5qdTds0meyEN7rJ1g7vZsTJkC0w+K5Tr3gdVN/r7X5EM5itmy/JVutuUkA+wM334HDY3sZDOW+L5uuNLWsH6hY7
# DATA hfIIPZ/m1tbOjvYvFcIn0WTb37n50vy+z2zU+BzZI/UQvYF6x4MhvzkNKGwjt3LeL1Vklr/7o9xLnud9OpFTJDd83u6QGwRPXp12
# DATA sffRr5UbldxjsjIfRHvDoH9j68Fbb/ztW2+/vZVLJp0ovvHLLbpOw8NWbmsUjfCP+v7RZzsqe9TG1HA8pqHn17/WG1UTDtC+wIvl
# DATA svF1dZbIHuLdzGkt/XwHY8EkVscqVP7raPCDr3BBHfJLcDAKr/+xHB4qRMmDoBu+RXbRHg4p4PYC8usOVrJ3cOfcNe9lr7js8i0+
# DATA bbM0DfqKiusBDJltFd/5N9L96amt+aC8z15CJX7pJZpCw035iOlG29EwGdEo/EgKnSf/OzdQxMgCXkHHJdgA/KHA1kSCKdT2Vn5r
# DATA Bz/0w+G2PEgJqfolXMOT47CA/QS8jXh7vPXL2/n/Kcj/qphvPipcv/E/5D+6tpV9If4bB5jK/QIJu4vi3956a7iP0z5WT8LPbO3w
# DATA M2og3uWWnknMjk6E3MKVZZtq/uQRTupSTCvezz1s6FX/rI8Dh+uFT9pk6yYykVQxgL057qA3QH9U4N0P2+qdqDqPsL96e2cnk6cJ
# DATA xXQSDNuoivx4zsPpAZOd6uoOVTvP3yh31FRXYUzDsYqdvr6r4/nL4kfyg74Re77lJj6UuPVWh4plSz0eDvejcTwcqL3h9n00netG
# DATA e3Tvp5/tyJW7w305EmQndb4SBPku1YCPPq1VPqObTSx2dKWxssZ6+Vz2WL/sqMZzlkzCaWg54MJfMVmXTiMa2jmQvmKxGPn+HI7e
# DATA ciS3yM7D0xIMXxjPX3hSLM5d2t1Se1bkWvq+5cl6f5hMRxiuaHZhRVMlCv/xac9HlDLpKXjH4Da9Juf5O/OJWd5aH31kNduPfk5P
# DATA 4tTqcTHTGW5XH3rOihlneYGGx3DYUQdQTXudDrZRyLilQJMN6t74nB/KHusQlD38NEq+VK1t0HzvWtFY1oR/irUlODa8geJ4vRa3
# DATA H+N0Df6hykcPjg95+pST+XKb6yNOMqDg0CkLTI9M/4IKEjuwqO9VtDzYMpjTMr1PLRLdFPoZXFJ65g8fNEuGYrqY9ALsv5Lmanq/
# DATA XYrsMOSL4shSpkvhYQjbJRgfvsbCgvH4kIXtoie7W/TiYdCe4kC5GcnRedNUtaNvTjOQSu2RsmK4VzW37HjXvS27pplHtM88RncS
# DATA JwUQwrZ1ODlcee/RB/ffe/ftv/N+Ld/u3L97+6H+cvd/vPN2zivGQHqYMDl19HO3w6Glr6Du6UAiT80tDAbZ2ijX1ECJdlj4mApu
# DATA W1WZa9w005dM7IRzRiue2q5lJRaowLZ/mbkN/211uJagu5Sn8Ckv7l18NLleSHN9F4e9YF0W8FeFBqRe+CS3GHQ+r6oEh677qxt4
# DATA 2nzjtxlzWl5O0+x8ZxyPdm/D4loWbqKXaMg+3R3G9J6DPGa+EUAyiYRCJZdHyW1xj2YKcmdpgIglVRE8qW1eHYpuNfgOM0UP+PgZ
# DATA X5SBnQ32oxycBZPpOHwkWyh3H46n6uC1/ijW5265mJN1U76+ky1Iq8WoQtVGFPxUo+3s7ZsNVzrMuR5wZQvdrJtkS8yL2Cc2sXtJ
# DATA sS+URT9fH63qx0aZZHowmQTtnh3XjxZLbdl/m+a5vzbT1cm8rIG9eX5/2PnUz1XFMmAbGnbncLKtvik7+cYJ8taaZEqkFrKX5QDS
# DATA l5hfu9jy0Z/rHijaJmMXo7GmiMYDKR8axtphtng8yaZd6+nX7v7i3ffffvvYkqMnaZa07Mm0vKq6uF6HgMOOmgFgJNpW1ZgnRei5
# DATA 9Qy7cHu8x179e/yLKjq5DWf5HgXqd5oD5JXRTWnSey+sirHqGTbhlz5Bt8EWUw/yP3g0UZHIdNh8bmM7nczgvoKKT86TbzzBUNbs
# DATA E2A4vbv8D4RYTUA/VSP+9dde9XjamTAaVHW1tsO64L2HQTvwGN3jYffSEF7KtkfjUzAio2bOEHnAzv27mIVtvRtjH3daI9vGh97i
# DATA 691oPAg7WygjqmiPHsEceET226639egRSuzRoy2JtBTfFXUljnGKfRBehNtvM/9fqV4sl/05/x+8gs7/dxn//fTH16fJ+HorGl4n
# DATA 08EbHU568bD80k9+8hMW7hBeLRZfZGEMawxY8cVyRTwKNfRWb+C6r80oj2db/T51C2u8glimqFX0N+xp0p97QQLfoP4aQR9sbDkB
# DATA T+9PlBVE87U3nUR9843nEOZb0l/thaT8MA7JYGz7I+f9k5PeWGB45gK1t4zzkmM/Hfcp8tKJ6iTQNZ4HUh/D6yieTOSnku0yeqYD
# DATA qRohKL9v230drGua/nitQy4iUzBstGNFZRx+HKqlQOSNTEATLjf93vdHe+OgE/4Cwgf6xYtxMUMUZZOMXNhQtk3TpCT1HElPuyQh
# DATA +jb1KMv4oEj1czL4W44bnvDwHZbzhieh2CC6xRuqtnZ0eDLJGLHbVHkAsOFnV2Yy8o4JDsZM9FyKg9YzXfmpECWPksMB9stsW3Yl
# DATA J3Nr9r/PvvZmf5p9Nfvr7JujL45+O/sDff569hfv6O/pw59n33lH/zj7+uhzuvYn7+iL2Tezv9AtP8y+o9vxwxezb4++PPpv9BM/
# DATA /R2+3vAwj4BlLzFQw6OKjpx7LAxg1G/Ll0TZgDyffRTblh8vne5qf0l3lU8kJNND8rkzHYwS/Vs4xDrnoyBpR5HYJ9hyhrF2t6Qn
# DATA a+KT6eR4cszqTmrCO3iM7mNkZrmFdJpLpgXFfjeToiX2w9wUEy+hqSWilS1wLM0fYAa5y7PHVVNPhNTuUQ3YVpNQRHMYb+9ItdhZ
# DATA PU9FLi79udufQolm4TXYpjz/lvSuGMsLDCLTolVSzrbPh+7hDP0xGRc0Q8umxEz5H3U71ow+k59qWn//NXta/9pb9+/eefje/b/L
# DATA Rnlhmp1Jh/227HNLbXD1LGPilzy78IwkFi2vwBU44UzZWSi76ZDbIP+oGrisLSsHlXGLwzulFNnggiqvcHhvv3IjdZ59lPmW/+jT
# DATA Yq7mf2b9vvPKh4X/n713b27ruvIF79/8FMdObh9AAsCHHlagwG5Kom22JYpDUnbSFIMCiUMSMQggOIAkNo0uJ+50cieuZNKVmprq
# DATA qu6+qTsfQFastuLYzleQvsJ8ktnrtd8HAGU7fWdu5962iHP22c+11157PX6rfJEf7J2tVK5egnuQ3bTFFv7H88/V9v93tcl/Bgzi
# DATA U7Xjv1As4Mvk+SfICZ7/WbGEr9TLr1RB4AaPK+qZevKhevY4ef4MSnyk/n6m1djICklR2AU4lJJMgjqotEdkE44P2b2gMrOmkq90
# DATA nu6SK95NwWM0ry8uAu/hedUVwFZfbA06i6qtdC8+z0tXloJp+D+efwqsT3G5x8D8FEOk4amRqjlBlqnG/wzeAUP8JU7GFzBf6ufz
# DATA L59/qVjiU63rVtdU1AM72tJK6uizl5PvN1gHjcXL8Htl1vpAb57B6jyDhqH9J9DNx/N237B4Ogte/ObFz4Ct68VjHYGlwUbtC2mw
# DATA saO2fm+EGD34b3A5V+OkF0wEjsVHr6G3e5wqd6/V9+zqZLZO6QJv62pjS/nSC/lH62ovWD/+ltz90eLexXJJbcZFs/dqzb+vqqcX
# DATA yotvpKzsDdTjVCG48fUA1OkIlclqds/SGlzsa7V0Qh7A5hV+sruyJ5SkZq08Y+j+eOvO1ibiwciPqqGdBL+Dzfzit8+/qBgOILsd
# DATA d/5jVfgxVKSKKc7w/AnwAOYPqnKZ6z+9+FhR2FdAnkC56vdvrFklIMPYTqaxLu/BTpZx21MIX3Z6TKjTJ2HGXsAJ+ZPaWmrJExzU
# DATA ZyzsqB6/+FhJOXaPWRHFhgZANrS5Hb2NsTka1vk43bm2vl7W6cPloQDXJRXgDE6MpeEX2rNUEdiMSJi8AvCVZrBAy4os4TmaP1Qx
# DATA /LfRCDn0obzkwnl4KP2ehvHio8iqffniIzUnSMZwLH2KtPUx7dv4+YWn03XnnSJjNWFPaSKh6oBkX3ycUAl4qCmBlxu7HVttdUst
# DATA jfrvZz13fYsN2Ipd3K9N/624gl2lL9JTzz8Czq5Gtrq5XjWbcQ6C4BGV0tXNzebm3a2dxqWl5aX7va21Oxur762+u9bcXN1Yu928
# DATA t3W7wWlsUDp+2HqQ1S8B7kMvdXZhar5UnWnu3H1nbQONFTgIEsXXN3bWtjZWbzf/5r2d5vbaza21HSzC998aFm0eZ49Kl0B6d+u/
# DATA 39vZure909zcuvuDHzaW7/furG797Y3VjebttbdWb/6weXt9453m2sbqjdtrtxqINYuGGlotuLn6UlhshVBXzxpkuN8wtK0IaHh4
# DATA g8qQpQr16+qVK5euBEv0b8Q7DbMh0nzxK6IwRcGqLnhJ37uLYhqQ3pNDMKrz5hkFS4S7mphAWFyZIg0qioIDUXUZhITPFeF8qfr9
# DATA FHjOFy9+w8Igv3ksupaI4Mf9tUx8JWOhr7uixtkkNJbrwtNcBHA1dvcc+RxM33GzN5qwDzQ83TRDtunervpqD8Hs8LtCli9urU02
# DATA tpUs29ogy4a5uuM8yIbDjrrTp6nRhRCKJKo+xHLbB8/izgEFFiB+hfaZFR6a7GfgQExaEBRSQB3c8GcNnF7Dmdugdu6AFU0LpFQB
# DATA nMjqm9S98XC/Ubumf7wSlg1Ors+QyapzSVGO4jlPieR/+/x3yFnhEfBaYMWfgipCbQUlgEClVSn94tcOq3aOY1wE6gM+5fnLw3ng
# DATA EW9nIzCh55HJyImWmBJ5M0mF4bmcoND4Jco1f4TOgfTgHSpf8oDgH/Wb/QBAzIR9pDa8ki/UAQcfqergtIIJe2qWJD7v7NZR3Ld5
# DATA Zp6Pgs9VX35N5wZ3IhgWncD+ArAoLp0oA+UsBxe1Hmi8OoC6qwsqPhZc4jVRN7RGsRTnG7vprdWd1Rur22twGqV75Zp8axtlSu9k
# DATA p6izqySB9tFrT1tXecXlVfSgVWsFZPonXDlg3cgMn5IAAjIaPDSyNC2okiwV6/wscTpuZCvuh/ypr8v64oG3SItBAi+B9Uee4mxT
# DATA eKL9rnBFvF2Aj7kKegKBOJm9G7bInUSV6+Q4IaCd87wayOZkjNJibAZLW1bc1oYanrV9YSykUFLSNFr2YVQlq/z8e7Zc6xCSZ2Bg
# DATA xekt3DGFQ0LjYbeD8D9q9vFPWRoKwIIn2GHpPfVslT6Sg6nsqTHxM1JjTmKNgXETVHElf9rQpyst17p0xYb7n/THPbTYDkH9JocL
# DATA q3+YJkCqsoajnuNg0vXNVaoALqJvdfv7re765oOr8tDrtRqcpmH1ucwYS/f6sXQpnHimcIAq54BeVjJCUoJyGadDyMtWLOMFBorU
# DATA xj0ldJcuSEVkGwAfLzjSeP+gwhiL27yLa0JFQrEyyOzi+GGFTPKnpBhT94TPUWn+LHo84As6Ba6LHPUEWezHeL2zOURC+omnllbN
# DATA OhCcbS8zEjskeAZe/oSGDqqp+C3Ir0WnQwF3s84B6ZbNabnbL81o3c6qclRAT9tTuAtaB1ctef47OnmfYNd/iS/+yGP9jFf1j7gS
# DATA eH+5CTcMPa6NtZ337m6948lLsSmWdB19Hi//ztG5ssTFy+A7S4LjAYnQTfvE8wR7FopzPK6ClozMEhpMICKrHHxBAnrhR+gfW18I
# DATA vIbOJg731lrBiKgderViaWJ9IR/gtf+nBO/hdD19qg25tuuno7LRtyiUpD7EO++z5J21HzbeXb19b030JOqB56mDNwGd/9q+FJC+
# DATA EmLoMb8uXAyizkaqhinDiPb8SzSyfYrC1leklfgpXtStyxXrZkmbAxevP6ZzXErQ1VVGQ+zOcRtz7yump1Mn2Lumqj//d772obaU
# DATA ptZaL3zqDUB9/XN98RaPetUz23AqMRXGoLow1S/a8d7my7fr2m7dZEHIhWn8DFncL0RHFPAx4scwpq9o6GpQv4ncas22BUtZMz9u
# DATA rVy5ao+m3TmCaMaGeAjUuEjZeNladmG0hKXD/bgdEDbZwfG49z5sMhSju62T/XarLhY9zMVgxR2UK8l+6uvTqUc1ilEuYX3OuPj9
# DATA cfaI/tK2GopEbcJA1JFqPHf58t7vj0KvXraadSlZCbG8AcmtqLMFp2YYCdiD8YwegMkaPlA/4QQbGEvi9turaua2793ZNlwXtIwD
# DATA x8o9R4QIadCo5rLpDHZzLgUIEo0xkqP1BAn9Ce1RIii1EfRhTaZYGO6iPQ6IhiAfYod8yhfTJEkvUg8vosO/10tZkweIRtCkpTHz
# DATA XqFTpAfG7pSi42YvEzqIiyCl7xfD/kMUBYO+214MZVKboCO0LXUXmkrUOrSqh+j7Wk6Skrc6ZXDf6z8sNpSIGQDFeOh2VKIpXDlh
# DATA Ul9ZMgweF6w2fvFzOEE+UlzrC4vdYlLGBs7gYswOgVbgGCnKCyZr9TRgFkDgYueIjuWf/V6yhEa9BEX/NCosUq9Yo8NpRAFbxiZc
# DATA gUGv1HlvvMVrFIddA7cL9hIeZf5DcfXO9ROWbZyCWlrRJItqJ6JaW+qgfmAXU1GAocuHGFm7TiXofAAqLX9H3+u934NofQ37yl+k
# DATA XnARj/v7DZ/ELPJCVbsshrsC8EhWgM5yX2mCkyYnHe2vcB7L8enBkXGMPnyCd0NrKMXD30C4E3jFHaB5SN3llvMhleTwVcgdMSx1
# DATA iGF2kHsDWgPG02BFu7K8iDCX7pXL8Sqt4XoUUjb3teiXeBSIogB6sGuHjPC0AZ0ddlTPhujCy1XvUfQntIpsX9w1TPAcd4nHwN1y
# DATA VkJ/U0SVU761WGKvc0gigTUR83zpzwboOHY5i0hKhjhMS4OXEGpkl5KO0OipPI4ha6d7DneVD4iOgDhQFbTVp/yBvgzhDhvjeJEE
# DATA qkP+wKPd+TbU/80HKrPkf1Cc6w9KKFZX5Rf/aLgYqSoVM8e7spLO1HUURNOAjyMP1BySRGf3ijVwTkHXBMLcHg9KN4jMZumt/bzf
# DATA hXxq1gTxl7reRXiwMNchoSTyfvcBZgrKm8Os2xp1HmTNUd+OkwJBwCmLJtUw1MoR6ataWpkiz/+KBWLjAEhC/BOwsOLMoiIDrPd4
# DATA GX/+Bzh36NbyGOf7iWVGlMHKpkFmFR6HszuMR9dvVN3qto53/J8COy3usCumu3O1wBTQy8ajYQuAJIgSRCOh5FqNJQMoQjD/xjYD
# DATA aIJHPQjxpTxK3dZpNswTyOSatA5HgGPe72ECWfQTvc5gLRSETmgruiFtqYk52Bj+JiemfFc7bZ107aPUvKDnFBZSLfyu8L16vRcS
# DATA sUHWWUy0Xt3fCIVLHPE9jepXuTV3X1oLYa6BFmWhLhFXaEbtgYcgrz6GgqiOeuHbij9dc+O3cVzmPgob7iwV9KS0npxNjCZEbA53
# DATA t6eZHNxeoHeqP7P8ulCyfYwS7TPcnSDVajd30fmhtAHb5OfsKPIFqBmeaCMPGyieFPBbsrTR9f1T1LmR2hJ58VNHEeF6wpjFitlF
# DATA GbRIdl5wj2SpLH5FsQ5PKjft5Fxwbg58vsWOcOxk8p2EUW0Jl4mBhjq9Kjq76ullbC91n39AIEr9blujNiE5Lfhn6iwn7OglBYR6
# DATA VDv8AyiUX/xMOlAN7pYUfS/yhLTKLtRm//KMYiGZvIi4uZvqOQd7muGcPCpqzSkFsibIhqYx1yvCoA5oeQT9Iy5dmn82nGOneC5E
# DATA 1WDxUpGJvB6YprUXfSH7IckJHttik1ESOsq1UNKqzxGdKGSsxW30N0EYC0fMK1aWznDUKJwy7aUsSNR6b7kt+4OQ8lFpxn4Zv/ZK
# DATA CbypUEv0xp+v81yCw0HOcfN111L3HLUbmH9JnQ2I452VJEjDCuTsGqwBNiFp9bGsHaj+4TpkW5vO8AQ7ZGGukjQBTEHUOxOcFChW
# DATA oJP6nRrxJ2j6IKPRY3FTTULx6UmojZKEoC7x6s09xyUAoz7JSivkAgH8hTcBe3eYb6Ok476OE48pgzMlWzvsclSZsmmGb12DpcMU
# DATA LCmxPvhJRkDbBKM9PrF1QvZMImu1uuYa46XgLNY5f4/Z5wcADltq5o6VqGnqsTs57Jy00Ie6WMCyusfFvRuiVMKWxOn0+xKzDtiG
# DATA rV4yZuWMHLfIdF0vAWHodp8pd4+/3G58FG1GemYPrjhiCsjOjVzif8zd6xVHRo7rnu9b0UPWDtEAAJfQ/85tiHTTpn3Rgm/cvbXW
# DATA 3N5Z3VnT8TDra9u4Y5mJIjwQnLDcGTMuVLIXMdcZy0N5m9xUwKnREgecT8yhSA+OfVrbqHzzpRUnxuEyJ50cwKrdqDBS9eVxAyN/
# DATA ry8kHt/gWCWYSM8ew70SUBgdjWfbQcKpI7V+dPANnIG/Spb6r732mrkR61m2A8S3MkKRYOTg7EGnP86T9Turb61VknFOiRHAH/Bh
# DATA ZqWL7o1Y96c2ywDQMK0aCeku+cm4P2olP1YkAQc7LuRDjAsfZmpqxxlGn3cQtQiyd7X5FothGeOBCTfnYERiARVv56E74Z67R+V+
# DATA 5pa0tYPuZOJNev4boByk+JVaTO5Z0QJhuUpwZ9M+tN1Wr0nAkqBXbrI0X6KhVWiWIeb/4LiDaeAtV07GHGGG0G4ASYvigH9YKsom
# DATA VYkvbLUC3R5MrgnxoNIhr2obAhVYrOZhB3DacE0ftoZto08A22+xSpjU6hhswsOZVi4QPP4JXTBshc+fyDpKkWKPxciboJT2VF0+
# DATA PyLPGE9LhH4iRj3+6wKfQs/iy5MtSFgOhFwMKU7xYUr2DEw4/wBgsT64/90INJztPe84l5BqEfr17PlnZMUGJZSSqNGQ9FFkKvjC
# DATA AhdvjCCJDe0BBSZjvne9VPywcPT83h1/zEv9YumN+v0a/Vk+W65QsB99Pc+gxf2TnJF+iuaL+FDJzBSOT2iraQbqklsw1uAL9jd0
# DATA j4hwUvzvXnJ2/GrK8xoUycxjz5Tr9BuRvhm7BJ3WyIDPHjOJ4rlK2i2BR4O6xw9KCArmuKXX1JEEcVC7S3vJheRyebd+2RPToOJg
# DATA VmBP0Jup4/s9e0XANfsxkjAvN8cb6ZGB3uhT0ibxwMH3Y5oF8jrp7YFT/LvmGIqkfk6byfFC/pQV+88oIJ00vkJZBgs6d7eP/YYL
# DATA qyOw6X3gkmHkG8my4xfl56v2F5WgBWNN8unUKmT5rGDuAbuHzMmcOhmbSL1zXTt7p34r7Cw5ZQeYoGDX5g7we8YfQrtqOt3w2kfD
# DATA n5oap5C+ufqf+hvXnzkzKecYpN3XYCn8qnx0TFpQazHmb4u/1W5HMA3yTM+AVSgckuWHHFBprKVz+KU43g0Uq/2PqEP8KcVmevwp
# DATA MOA81fGEPuei3ArQX0zQ4Ww/eLJN4hVAFbubx3lJtm+WxMhpTclEVFALaOjdbTSpnZ7Mlr9b7He6UvVc97JgloP5/Fc1PzQF2vv1
# DATA TxhY+EkQyfEVsqSP8L8/e/6EZZzzzuVggF4Vu5TshH3TGw3Tc3TcC2zeTBFOJDvQH1VoyI9/a8K2KK6Q2vibYG7+uxrSJxhc+fjF
# DATA r1/8N2beMj8S0hDVuv2Z4lpUBSw1gOv0z5BiP1I1PQ3FqM91zAsDvDQKosbYxX5zkwMGLXBZFhQurYj+mapCtfPlpe9dlVk5OCa6
# DATA wXbIv47sbvcRWe0+eq0gnOpeOCv/5Iy4gCii2uxnePKhMyI+sMZQpLdnF4spynmt+y68RLF3pBNXF3Xd2IvCEpAyEjX3KzbnY5e0
# DATA GTrLf7GidH0RW+blS6azDwM9ZsC6RJWpdVuSGYDHTs+d4WPHKsHtKM/WwMl3E9Eky2Vt/Uf5DEQxcJquAejR+9lpXtq9wPVwE3v2
# DATA J7Xs0QhUwfPZl8WXz1a/e9YLfZGG2uuBu9ncxvU5Do5QdRwPtNM9Fb33GZlG0A2VrH/gEUbK/HrE1y3ovPZQFpYPqd5xIhz7c1pT
# DATA fCA1cyOpmijsxr9kA4XSX+XY2aJdjVz/WrMvqDR9KiilhEHtzqr4K5OcjsVJaTnFA59GbNzu5wJ/Po/lBxdUg+0W2ngRqyW6yFNc
# DATA YHRncZVsq6/t4GI8Y2iwzkoabY7tqRWnfHf3UaPlb3cnmB2gZCgIajE+4EXz5XicfVv7QvEPdsUE7LlaO8sG8AcrqixPQSNQwcme
# DATA VoTLc7Q4aIdfaQQPi1xxCvwDfiNO8l+iWQ0Od0SmSCBWSs3ZH8AZB8NFTYj4i4/kaLcxEixhMOIEE5faZPM3ZFZ2zQbfw7Eb0Ir4
# DATA 1uLiQVCMG4BiiypfaLNE0WnviNtFtJIdHmaoIFSdL4nmcBa7mmdEuuJpYyrW98CPP8p4UM7TPqyFq2/uFo+Lhoug1bC2uns0QHru
# DATA xFmHIUhUKIhBcuqFsZYi0fsuQ+fiHiKAM51UhHrX6RurTY3XAoyaGYXSpjYBVyEVYRoPNm008IpSyLzPce1AFckXFJECxGainThS
# DATA jUNuYqAeFoxwuO+EYbn0FfWlGmaK/jsggALxeivK2TMkopQX469xMXaX9mpDjVaET6rLGr+oLmXs5bDaQjQk9Wt0NCQgcfn7JwyH
# DATA 3u7gY7WmkAwAMMGVjPIIHeVa7TY+UQJZdth5P41aJ5//W+HOhc3+S0X9IJj+AmO11Pp8TlGgoqFKaAc9g42CWwQD0KAcgml9iB6U
# DATA v7bvTB9ZC8PrsMsTCJFc+JdfoDboD0rp/rjThUQaaESwbD47x52cWQjghIAJoY9wdeDihMkBtIsHvB4O+l0yccOJKbKCVd8Q8qFm
# DATA PaAPAiZmGxTkFeipHgEEZxeCd1SFPUx8oOPHAK5YHYi1cIQ2xD+M8+zChVjAoy99mQQUcIZa16U6X940KGEK+v30u9+V2GRNovYp
# DATA E+O69vmhtR3QKcssZXcxrBhv8nuxPnMqEFWWYK7setjJlD5z42ZRMU4nhaUOJ7FAehf7bsENqLfk5LDTYai8cK7CozfKGIonaspa
# DATA hmeEU/h/shNCr13hnGuT4xC5o5Rc39jeWd24udbc+eHmGiwrcDO1Q5CREU5vn8D2D46z9ribDdOJrzWk/5X2+/3uDNJjLkySsDOf
# DATA wp8bjaSoCs2DygUdsGZezQfrRqEl9cvahLQLqS0h/LJz2PI8gR7hGzx2tZBjYmsfkwHvM8Spe6rE0mccHux4T00/fAnWFrfFxSS9
# DATA HtpGQq2rEzxKZjLtTPuk2Iyq/de1Ndh10Qr5Qd3KfIMyZYS7eDTc1Ue2Q8RGf2bJl/CFoy2DB3OrymYLnl/FBM+ncUwaNDN/zjH6
# DATA M4TrKax7FvufwcjpKnbQbdFdzGlxKmtQM6q/sxk65onlF7E99AoC4cTFlulz9MS5sQiYoRVFEdrmjWn3D7A2EeCK60LgX/CtGI2D
# DATA X4rUA5Y/AuY7J8V7VH/mTmM9QX4TO/wnbiCFeznGW66NZarjp4DRNcSBIzTvNUgbXkls3WhjFy/zpPor7+mXRoXYsAtYmacicrfl
# DATA g4zwdoCuHhge7S93oNg9VYplg8KCm8ToCenE6DsL6vK3fMEXm1q69+6dpvczze8Y9XttUtV/X55UL+sfl9SLa99r7e85T+TvZfKT
# DATA 043F2QyhekyF+QwDIx4n5zsfniL7f0yOEb8APBRxBTB46h8HERK7BQsAgrAZlh06caY9JerJMkTvaPV/3fcbRVmCPDdZ48Q06GZ6
# DATA 0QGd4ASl/1Yfk2YNFVNGlUUZosDBqy56Fon2VU9oVNAt3rVQiv+suGf1tvG8im6FifhizdTioyZcoHQ1JAr+DII6Ci0hFhAvXjRj
# DATA vvi22yahP16b7NAfVyd/yw769yW2GbsFl1wPAFwn4wn12ZFwVgnL8gOm/aiveLBXwVP4luJfg+ZNTGsAq2w67kEiuUe6A3b0FZwo
# DATA Wp+BjmAxQ05dnQfq7vwJHg9yfOC+Yv2rwaSuVu0AnxBKqHCFTffBV8bOrZRHFNLuxAcBhLnB+XjAaUZiDoPgSGhIEn553k4ITIIR
# DATA nPpd7kOuzemJVxgp82dw3gErW+GRG9dihyZH6OSscKCSVZKGslf0SeAr7Rob9IwcBACVrMT2WnGV2YUvIwCs80zQVxRAg05dLCx9
# DATA bmu2p5itbSf13QvUMcN1lcxwwQyWuS7alcLwS8tvPYg+0tlXiw0JJn4ixACCHcFVzAjAcbGBxJ/Bs4yQpwO7SLKZn2z/MKlyBv+B
# DATA 8wY8oXN4ygKwv9gTKG6YhBOEiBD1OqD7pDMq2pJs/mi6IEPTd/HLbol5Yi2wDi/KQgzOkcC1gIDqc8fNxkmHLNVBtGYY5EGdsiz9
# DATA +MBY+unn/Kxplnn/ieZeBDVXSB0Oqo5xS8eJch3SZ9vQC/3H7Qw8oeu4KWGIy2NROtpcYl6J2Bz5B8U+plIb0xvdwinytC+615NW
# DATA T0ng7QTUHlbeOHbap0bAdRGSmcO/4kZuu4bHJPc5PQbPhUwuVMO/lAABydvP48RmCdr06DwY5n/BncsadwEsY6HbtcWaA0qos8DW
# DATA ajFRcj1/gl62hKFGnsZTWOb0WaNdpe8nUEHojGcJJjHpPcjBbbvc+W5m3pHsONvuOYKv1HIO73QASkYHe8aFgEucr8GbTSexTsRs
# DATA zLRsjo4IPtv7lgwcEcB8xXdwL01inE8cAAQTPoPqsyYEcjWJPUkgV4mDXYBZnSv03kUao38cmLGegQ+HNvSGkPZc/BTeDH7UHsnc
# DATA 1BsKwOdqTIxpEURSuOWpzCwJVkoZuXvPgCeJrD5/0GYQTadD6HBWIjGbPgCVjxBkhj4LJcgCHfg2OxwEmc7BOgNEInWjciUTl48G
# DATA g44Md+r2lGW1XY/3ioSrkBDnCx39XzVstJhmKGyUldstpIduBpbi/sMepGzstQb5cX8UGr9tzOf0Qb87PpHjxrhTjU4HoGJK9zu9
# DATA NprLqNN1O98gGPppneqJOzQW2l4qdJ34rfkUJMKX0sUlrqdt3WU/2gEXyyFN1j0StTVy9MfEZRvRMHjvmugHqdPw5mE0ZieXLS6t
# DATA 0US/rqbc70gMV5B+la0jSzBJ6Zccg80xZQGVICjxpRxm3ayVZ5yzur4w0/HSA5d9Pbm8FGga9d26pwh32DnQDqFqD/cfZJRHUhE2
# DATA Ke65C74b6PTMM9+bmMg1/Kmj17jNcnGvJN6MIsx0bBl/6ESXubov+OxiUlqqlJMLSelyUuWLn3peDiYabSklO7hyZgynH7YZDCFl
# DATA T5eKGYx2TBE/mcDTaMF1VXKwnUetI0Qk5TpqQwvcuZ56wq1gKINHEyWzUp/XQyBlrizoqqGG2eu4UIiYmpbQ+sx1XVR1lVUV1dKD
# DATA 4HH5DXzxRr110r56+YPW8OTqZfUQz4kjD5TJzI4gj2qQfKMvqlhYq8FLf/3HAwIiLpnK3Wy45rmd+q+UHh0fDGudvskjtUheXfpX
# DATA SGt8bDQZQN14c2pxSjdtBoooFQ2fYGM+EgYSFxdDdzt0YVvwfGbOjMeZ9kHDP6qDYf/RqfezSpf6oe2gZrm3ha5uxsONnN4mATUa
# DATA NLG5vWrAwQKjUedzxIg74Fie7Q6mDNYddd1Aw7eL2DrNvyMYH0GFgKXYSEqsLhe9uZCRlqLgFf7rmsXsYpE+xDpWifY2WtJrCs4p
# DATA JdE4vXT6NrE3jX2lphFDhg74g+6glNmFJ5G3SSsHBz3/BMx9SAOSlEzsNP/m48kCOsgbpbKTdLppwdGGJ61br52po2nyeRd/p9uX
# DATA o9qgf2iJ2+oAI4kYsddqJEAZOU8o93QHeK1E0D3R82wUubonkXf2FMYhG/hIGL7P4BjGr/9R1dArz5KfscraolRF4BXuoArDXqRy
# DATA oR3KpjDfD9Afu4jrdl3aAGZdnYKJiX2oS6VaMDHcfNDp9cAeHSUpZu1mWh3Gzgf8HCdXwSA5zms3ht8gPdubZ7T6zXxxsfYa+7Hw
# DATA qmBhPDx8JmDH9ptCaOVScWyv7R4iT8tyBPIw1HWFMMODip1ed2af6LkJfaCx20f8JNTiYcv1iMP6XART2Go5QkXnp6TpW4b650dZ
# DATA zUk5h+TLRvzayZhoaTTb4AnejWTE46yAvqut8aClD6nw7bhfLktLthShxlojd4Sa6HFyJw487nUk1tuy7x4aqc+UjYQ0JUIZEiHu
# DATA UUc8gZm3pD5hnjEV1N1ZWSfSUGc5S1h17vokFErniK+Yi1xjHXAm9lx06fUFe9/FbWyvQX94hIlKDH3V6BbmgrpMJ3VddydyUZeX
# DATA 5dDt3d8i59oeFPJZMWhlx4qAehV2k5dLOTA/Z2JK4TAqgRQSClOpg45CGXEYBOUpulQ+VnIfKSFcAbEUDqoSSDahsOa253onYMz+
# DATA 59giylJFUa80Qx5daE+DWRoV/jfA6ZIafJ9Xef46jyUMkhq2OmpF7lGz71KriKXMrq8unoztoy3Z7CFr238jR+N63NX1MX5HU6A+
# DATA rLBzEhqX5C1RiuduIBDGtgFYexn5NhaNwKSnq2IMNTGV1FRrTMw4sviNm0Zgscy3WhcMTNWuUrpoSiqh89jBuz4fvG8hpnxLwibj
# DATA WtMoagF7wBNswbeASpB6DhznQl+gzgVYHlE/C40X1O2WPPeewMthJqw+uOcEMawvfg2RbJJM3mDM0hsLhckYfJjYitAUPMeS+rkw
# DATA SW1TOiZ3+Tb9NBGFEWAaCNRbIuUoqR2ZC8a5Oq/2T5OsNex2UMZiXpzTGZ212lZ1fUR7HKg7fGvECI4dVXnnJFNfnYB0nB+32v2H
# DATA Lt5sLYRZcP1GF/8jvUYXZ/iM6j7/T+kyOgfN6QGw06hZBM9ndDHmMerCktrQJOxC6u6GmgQIu3XVI7C7LrxBzE2rHkA3mGuFvZHY
# DATA J7nfU3ewrp/hIUYajrZAPnT7Y+or7hEtf1h/QgwYUbzhoPYglchpxcp1IHEpmilDPAoH5P679hO0gqq/cnK1/YaenY8q9PheGumF
# DATA GXrE0O0KDJHEUJbv4hSABzkQXafY4CmcISGSkF3UfmwKmwpitf4lgSP4eIdDUBhgMYCYqxmgobhuSFFUJyKdryxMnGL4lClAEG4E
# DATA 4FN3AL7sV4/CQzjiXdQTAjn01BIenoh1YTc3uLCpWKI3v7FoGa+5ktlpRUppC7aCaorJyqavfuLnGEaT9oy6gDtPMJpeKn/IlNwh
# DATA nke5OPFNYWnXEfyL8sap8+8z9fSPEj/3FclgHpAmPjJIuU7SD99juNfOHlW0JJihabClEapnwubEsuG8nly7ADlw8D9THMMNbBS6
# DATA fD978UvJAfsJjVU9cNPXogsOGG8iKDmSO6Pu9rKSSDqKehKmzOAMdTAJUPKELCpL/atLS5PCgXuoHapPohJFFG9vSmxQ70pC3hSN
# DATA wAG/HPEjjubUqEh6quJUE3bECy651m+ommynCSHT2a4ph+x6whVOprlS2JJoU84lA0hH55KVCRTx05W423BSZczkeeLAFTNroBel
# DATA ZQmoG6ZgGSnqMUc+sJfq+Dn+i0jBiRYr8KY0svyaZsnqdgbSfJ4Ar0kgvdep3EoJjbw1BGUj5kwlNHes1KoLZr+WrGECMRAW1Gc5
# DATA gr6jJ1i3zZDWAwDswEZYokCP7lEtDrMeyluzvNvtvRCXQxlB+xu5cfm3LV9WFcT/clAihPqf3z9fy1LfmH9S3OvfCjHm9F9r+I+i
# DATA NidtupP4yt5h8WrdfWcxAlCKyT28N/JAhCyxxYYpQI0GwRi4wyKVVruT4+23ZGHbW7pNzVAY016kXSBmG81e2wvi5gUrpitiQ2B5
# DATA crYJQav8PTfQc1keNE+iRlm5wmWCI/6fwwzhCHHqeaFzqBjPP3rkO5DaXhiUOhV/ZhLbF8nLv9ZaF+xqE/ZSiX/wCdAfvk+g1a6y
# DATA cH7zSY2rAA2fQXCKagS5pKMO1B3gHqSLaYEvv5X1PsGZI1ilZ4VJvgolpmrVHHMFCKjwYE+bufkBy6VzzgsdBk06M31oq4rfMGyt
# DATA kkzGYjKwptDPNI7c11FZ0mMLiJoCV8q+om96snJnihGa1wGbfZpYKsDZUxxRpRCuRhySd75czjzeArgM2Yr6tY2OG9cpiSIoHKxd
# DATA NaScMHVdD+RzG9oYLp0f4n7+lRU4wwkgPG0o6iadHlMLzXfWfhjZBv8j3vBTUjVDbltqUl0j7XoczcAZQgWdtBgWwBaDLK4dyIFM
# DATA meSfTDy0LmzFgwnw3JQZ89ZxBagn2unOXAbJLZn+3k3X20oIcyt27t91tWWojj2U+kfDloUUsLs3mZL9uu6e8XCz72z2hxR2M1B/
# DATA GAAmdH/fvLuFENEr6n+p6+eKFfBJqLrQy9U+O9HOUvEjkR1ZHRepigtuQAgjaao9EaMAJba4+bXOTwZlP9cpaPmbMDpKsb+Jh8Qe
# DATA xkvNBWlYCJ7OzCj1Lh0kDmsfxhjUVcwbhq/F4H0IP89KB/PNZHn2xNVd5leOg3yhP4brhzEpBmabCsdWirFTgvcKyA0eB+JyaYoD
# DATA aPllgbc8XhwBMQx7F/tiGqph4K70skiVURy0bwmn8j/K//dlYUd1phZXwA1zbpM+9nPwMNBmwt8+/10lYYy1qNrTgXf6FqAD2XcZ
# DATA N7rrtFWEv2euXH3tWVmwv0pY+5x4fZYLuHZdrzrlzWPrS+uuqr7X/K6wTwgB6LLH6Vh/btmFAlIRMZ4w+UxX6i+xGWcCmp5j+8cP
# DATA f4L5nkrpxm9liqzqKCKG/ZEShMhvUW2yulSxq35QwLL6g0yulmSGFwx+wR9MiuvetYQR5JFwGQdhhT8tFljKMf1NiGcd2SxRcMyZ
# DATA kcu7aPuuWeExjRRYHzjJNECPYMZUUHIv2qCN2BSpHdRZeiHwqkY2+EPc0SNisvFO751jgGK/g4WTAZFbBq9zxXhp6P7I6SwrzpKQ
# DATA qjimuELzLX95zrk/u3BBPaokFy7oGiZhSvWKsx0dBC31dUn1ddBFP/9jdYSQyAF/NYHeXFE1N1KqlAXbcB92VkmeiPUzzx9SwnFC
# DATA 38trhF12nD0qXVopL+ikCCh3xfD6vC8UiW/e3d55a2ttu7m5ur393t2tW6j5p4a86Amr8L3ttS0MorBOS/3y1g33lV+LBy54aJ2z
# DATA 9cVF+VE/k25M/tpw7/Z+/crlSyuLxbW/uXV3Y6e5tnGreevundV1CN9Pj0ejQa7qBlIzK5Jurm6s3TbF9Bu/yu17N5qb927cXr9p
# DATA CjsS1njYzUvOqpqVh621e60Ot6y331u/pXq2euP2murd2pur927D0ijxY5yFA7mztrO1ftPMdat90kEnE3kBKxZd2ZXL5aC299Zu
# DATA vH337jtMEM2311ZvYbVRumBNvdqoELnIxKxFaHeLEsGF0vOgNRplwx4G4P0IJn6Y1RCeOoOdX8aouUbtwndTV6CTvJH8eQV7AdbI
# DATA 2h2PjXL34JPxvinPif2a9SRgMFLZYbd1lDewyimJbbH+iw0EWFU1hOzqIr6ymQN8wswAESCAF9AEY8TnfiaeefRDbsv8yg2AxMRI
# DATA Av/q50qC36+m94f3e4D7+uq5/P0QsFQrPK6Dew+niWKlqDlhObuUDckOQO3wB9kYWaRzbDqD1ilYtNXgwAxRg7/BqpVnVy/X9q9e
# DATA ZiubTIvgQVGkkeNBHckKx3XjSft+2YXP4Xe777PAwB5arZvZcLSZncDO+fHD0eZ4X/HtdxiqXvXEeg0/1Rv45SPpkjvsu7Du5AXr
# DATA GB1K5kUl2Tkd0J/BqtgT+ymo/NgBEsGLJffiY8wsQCpBgyz3GKBkADL2p+hp/LPnz1BZTXpbhHB6Fk94ypR5+KoWbBpnRG+T+z3T
# DATA oUZ6xoiuiqZfZRp+2OqMCMoEGWhJYtc6J1l/PGqsLJlYYyuEAIPgFTu4g7AkFFuoVq/d6ipJMo0ijoQnHyuWoK5b+ETAH9ydYxWD
# DATA JkkJxc4+al07h3BEZ1MyeWHMvSqZL4K17eBYtVQbqPXX2i9TS4A0AUS3lHzfKePZ8L/fSJYvLS+9thLdoJ+gtwG4FzyGS6GbASe6
# DATA 0o+Tt3d2NrerBl9HR8JRbu+G0xtjHWYlV9Y6ZJYp2Xmr8L8ba2+tbyQ317Z21t9cv7m6s4ZPaxfewH/VWRq8S62k26q6bYd5QTPB
# DATA gH8fDicYDN9lLTW6KHofDeR+4KUPz/NubXPtThOG3Rz11bG6hX+XoBPq6C2Xa5JF3EwUHhzwJWX/bjL8RZNflg5aaF6DG4I1nWWn
# DATA hhrj8uBhknxA9b27trX+5g+bP7iy9D11PKspW73dvPm2khicL9U53jkZn1g5euHbndvb7GcPfz5Ybq6wC3mrrWgOiBg2Xu2kr6YY
# DATA nOJKcIbyXiRb1DHYWIJC39dVWCArAeRaZ3Sc5KB2G8mkqN72wPaubgildHnltdqS+n/LqT7JDCNQ4ymtQLz6o1JtuaKbq/pdgQy6
# DATA rVzx0oeRfOHQAZmgh8PWoEm9KanSpK/Lhk3hEw0tXEF9inGNh0WCviJJn2KoODCrQZYNkVj21S19qNayPzzhg0hTDTAwIb964bXK
# DATA oN8T+OKH4DjnwGCB4RHCRH4heUtsREu14FXa8Ihr/9O0XHBroa7nGbDTbukwfWttR7Ew2EeLy7VlEAjeVlNTT85khibw7KZeSnWz
# DATA 7oIfAUgO6v8gsRsex+Vy0eytLC0BG+ugUoiaV+zzQenK8ooo8Mq7y3tAZ5eXlopnyGL39sl5d5uPTfsIXQdPIv8MlSuQIWIgr7yb
# DATA ZYNSjW8/tAwuW7EzHPMafIjg039KLFjMLylb5ouPr4u2jWJ6PpYEzLimlShbxozq/07ZZsCIisJflXSQYubHX5wgr2TuIHkHnA7U
# DATA sWXb8mdeBFGGUW/TFM9eqUPHY+Pl/TClzASAE5Qs4e5dUpcqPDbli/IEWM/1+z2r6G69vldYzhF3D9M0pZ2ZnJ0tWFWMe51H9cUH
# DATA reGi2neLWru9OBz3FnEiarC5ocoEdbFNuGv3D/rd6wtnNLiJXNLVrsepMAR9ncwnebdpH/GR1kZd71SPftkEwb7g68Gw80C9dr+V
# DATA vuYJsunaCv97iYqAqLSS9HvXF6wh4O0qT/qHh9fZOKKOycVxPlxUTGmY0aQsHo9OuvS+NR710Z3OfJLBdmgiAuXlpcvJovpPzfqg
# DATA 3VaXt1ZbLcUPqjfpZK6CJFq9SxdSRZN5r3OopOruw9ZpHny1BUgqw2xY3eyr6T8FybpzMGIXv+rD46xXPRj285yfONV0+6QISX70
# DATA 98niI5gAcKNZFKLAo6/bgSg+dUQ09/vtU5KOlq7r90fDwUGTxBU6VJJLS0u59x7Y3rT3wB3wL3XVn0aC2EUkQapgMnGHoUZx/36t
# DATA 9MYrD7Nut4qAD4tlNRp1svVOwQH6evAJDBZOVXJXSL47HnbwP4tJQy0Ullf/X+0XxQ5I7bC++e7V5sbaznt3t96Bray72OwMHlxt
# DATA ZqDdyFO78M27G2+uvwWqHWw7bSvqRLNvuj/stAkXI+u19rsZVHFZvcCoNucp5D+EA65iV9HsDxB//sw2vvWyESila1R37UhtFbXi
# DATA 6IcpFaW91iidcFU69PbMtWhB2SqPRn2yDB+4mPM4XuaMYvl1E5RT/9sVsZjbzHIO2y4PxTK12pBn8tbNfO2nI+dCAZIDnTjrmw+u
# DATA 1im9ATkayW3uGeUpw+RxDKPMCKDa34FMP54RVvUgQiZgAuaOWF7r4E9LPkjycjf8ds8LGe8PxF4r39PtzaaISPqnUqw0EB6TIN33
# DATA +AeagpzyNnnqGGMDK2P/b8q3V823QMuRoo9AF9Tq0gjcd5iBDd/FmvTGN9tga5M3DX45jVXM8x3YuGduswptM6ob/voatespVIw4
# DATA /8k4g2gAsn+OZenwz+jMiL8eJq1zZklQ4rnAxSRtgpYsJELCi59dLOpsxHvsGcLx0oxXef88E8f/wJtKW1BtabsgpuSpdpI/TxJU
# DATA nWCkCKAWds234QUwG0vBaZVJASnL9yBAoxCy2CKzNU2+XUeCmVqeQkJFus+AJE0RvB+LadsSpCGWuMDxiz1VnkpKza9e/JxDwDFI
# DATA fJYRuzUatcCm66Ntab5eLshfJx9GjXRWrWSRRMHaskRKAYc96q8sZCRTk6pqUtxKyidSSm1NpqSbNT0vzDY7+0RCL71Yqi/jRutO
# DATA XZRE8tP8YBRCnfHj4AiJGE+pZKGl1DSAuQQxTiRMJSioslw6MGSDLtlzqVf0cR/Z9310Nb1fq128r279uTllKglaKtDCPxoKCiVw
# DATA yaU0ds8NjSPcHbGOlKdtL9pBvBKMQa5HH/p3YKYGP/WX9gaRmFwbczzYSrq/IgxYZB0adKzZhC0ADscB545f/4MtGwohZxMM+pV+
# DATA 2PdYXHZ+E3Md6KgbyQhcjZxDUJ6rRVwKv5Jjtujro4fN6RWEe1LKQ0T6CMleV/79ZCmSu8vvg/kw6J2qID6z59jrfzT9KfSCleM0
# DATA JhvR9OyaiQVrOaj8liu65imf2TNqfekPNaxBCJJcQfQ6TSFLw0ijcybngnMJkE/MHSBoPyZTYxCdDKueLClZyh6oejJZcNwSIkI9
# DATA uzJIO7OyvQZ2Sr1jwZ0nIkwtROg23liUokiSgnRriqweY4AhGqieog7tS6IhylwomZafsgkrZFmx1Mv6nIbplI4tFJ05sdULB13x
# DATA boPBLbpsOZBPv2iRvxPMmTpCnOmKf1cqEEJY2kOma7mfhuJjjSzqzmmhRz1tjXltnY6bDgid0cW47iXII18wT2RyXF7CKztAK3c7
# DATA R8cjuRpU+LhqgnqrweEo4Ia3qJ4vqsoX4btF6AG4RrVb2UmfUhRI4Wx0sEhXl0V6y6HNPBXQgf54NBiPSq3h0RicduxQjMCqwS6A
# DATA 5BDLP2rDcc98DRADAzXKrEn1ovaf/ATkTzZyLF8pFyuvrep3qPzaowHk7Jshm5ldBdrnj12JmTYaXJF0d8Gg5YJU8JhwpUCT/y22
# DATA J9DU3GY+aqtx1kBROCiVF/QCEQ2U8J592IIYBZCigtRJFqkki4kurf5WxX3Z10XdmTLGuI87tYVDMw2p+2eNHTvCMergYLKeuqNk
# DATA eTIcaOqIjyIqcoS4tAs8Im11CfqFj51yVKMUkQgxAcvPyVbx/Ol1GRlJfU4GG3OVfdgatkk/xD2W1s072fBqQdF5zPLc4P22m3YG
# DATA 8E31x/hf1EtgcfTGPe4/tIcjUf+6vl38CyeC/gLORy8RqHgszgPtDIDagXNZDzH7gKp+DFAgOcOi6l9OJBdVWqiesyeviFh4EFSV
# DATA pRDwOm7FCeilbdC7XRzGnk/ExfmdavW/rgIi+fIVAJXX9b38xe6PCZ7NP0Nb1T9QkufowERTMCcpF3WogFLDTqhpn9INa83FykJJ
# DATA 20vpsKVm5ntEGhZNk8KNrmjhGFoHwKeb6lsawEpaPKNbq1XMZPThi18i7tbPfAVHLyNtH94WayEv0Y01VuwEzLfwOLP6PN+mRag7
# DATA NaxKwt4COA1qG9LxmFoB9rAfq2C6boH8mp6d1bbR6lRjd4LJBOLxSyvXKiCgLpUD50A/ZsVuhIMDgvbUlh+OqN5KcukSXMRtJmah
# DATA 6Qu9/+jBG6X77Yvl+zX7H1UbcxgecIjwSnUBxrSbQwGf144U0QxAWgILNM9V0SpXMaMb6Q795eV1WgNTXJasXLsIVl0J516pXbpU
# DATA W75olPOW7BI7l+i1y0jtT6yjxU1STkIPaQQHV0ewA3PSdqOWvJh8ufv6o2BHXk82VneY5v6AGZcf4+a0ci2LSIZC1xTyjHT2UAk7
# DATA D9WxUhWEdeLRvUMeQnzfFg9HPky4vkDb+JkMgTLW24qQpxpA8Fybji3u0VjvKcpq/S2cc/qwNBuIZWr4s5tH9uoG2LQngAKJWi1w
# DATA nMmtsG/WQmMDUZtP7KiOtt7p5eDFkhLqqjqi7WAqHf7oavYL8IaLjEdsa57DcHSLDEczzEVrePsDinAtPrONRfpL384UFl2fahA6
# DATA DwYy/3iJamSZsJoCGvv/skFpiiRTaBJwTDxwV/kSAQyBV33BxTmBPAfEvQS02fXEqd7LpIsKUwGeJahISSUKM+nndIApjnrExhNL
# DATA wzSjIYUv5kosH4/6MHt0xvYPD9MCQzOyQpD4vkBPEXWE9mQW1FfoXIzc8COQQ8DB+Gc26uOnEFsY8xX2Anlj8F7sQuvkdqskF6bD
# DATA 30OGZQP/j2OGwwEGWA9vXvO5BLBrg4+SF/VHj2gs4t+9RD9ISRCvTtQEN22c0Yi7m1YjaNfxSvJOdkoOcODhiL4/TmCymcReGvNU
# DATA D5ssgQkjoypdC0xGLYafMJCcuVv/UhHZJ2hm0DN5PSnGGozvKMJWclJiK3EoJz/Yb6WPqQ052RuVuDkQ2pNVtX/q0wEpyMDs2SVf
# DATA /KqmNim5CZ+iMkR1MaCiuE8KsZRDxd6OSzGoH21K11gH2vE11f63jfTS0tISmd0fnTZ07DP665PbIJb2g80KkBK8x+iSqFpYxhZw
# DATA LyjW38QYpAbvPWzJPKWdQJlPwW8QUdzSPOseAkBvN7XfUfWXL1+Sp53efn/ca/OLa/DGTmRm12n4pV23HWMQD4cBQnzCS8y+9oaN
# DATA uj7oGBmTlhdmRcG6/Wq4kQ5acWytSNCx3xEv9m3nALQacY43kNmfIqY9Jxf+RrpruqZDCHfRCTSGns0hS/6SRhYzhCoGmG1qgnC2
# DATA L0WRZf6Nnah/laxurlec9YH89Qw18zj5wbB1aqJpvmR0bTRT/IJiaSy8mM6hT8uRRFg+Zo6gkyIIMmCRK6GsuXrrzvqGGxk136lr
# DATA EE4jB7CBjwrA54Oc2UWIVMWhZd3+0RHdGc4s30G4PxDIEMgcA0GHOVNn/KMquGlCoUtLGCAFj7CoenQlZR9IuLf3JRkYJpeD1+Ne
# DATA F6S3fNQfDDLMGcrNQ3IO+iuIUSx0IRQEQsZsaNtgO5OgmnG3c9Jhh8Zen/t7lub9Q+jZ8tLla1deu6o6dKyuhubBZDKZD0NJnf/i
# DATA jEBDZy7dYF6d9R4QOhtiUpklXUzA2/5BWt6L6l9gufLG7qEJtahLoFYdOX38M07Y2thlfIoqhU2Q6ys4uxrYCsK9y+uLapUX1SgW
# DATA +UFBze0MMAbyZr/XsGEV2vvsKdprY/g4Jl7jPC3HihePjk/TiYO4QHAZsz+aRLtBrzFvqurHSFEY4BOlN+/cqm6/vXb7NiqpxsNu
# DATA Uj3Mt9H7ur64CH65XTg0YeqWF6kORKVEnZ2aE/RFXcILOVt4kKhzAosYDSkD7FU6WIaj5iAbdvpt2gu5DR0R8pQAtwGiEAfqXZui
# DATA +1PNQCwdcbs1akGQZJy0dIh0fflaDa5wL0lkZHk9PkH/60Z6ZXnlZJ9qkyB4Ncc7fwvDvLdzE9bR0Jf00HhVW/goU5qbZwEHR81O
# DATA Dkqx06R6L/nud8+cSPNJUm07D2/dmASLeWnWWq4sTWz5TNFkwVzTjuGNU/9etdUddHrAHufda0WTwRpO63vU07JCVW0V+It+EcAH
# DATA qCspMJWeKv57kp2oda4O0Euf3mVqG420YhYc36lf8NvrGv+Dvu9+cUXhyORfe+01egUcCf5aKhxQ8dIawJzqQRfhW6r5HP0ZwAHx
# DATA 9VbWwtWy2JYqpabUYUvIyISoowwL/3W0WKHo7HnD2e9J5CsGBij+EoN5JMTVfxE4dEQ+bYgYAM4GwWsAyrm2VEmUlD0pxCliAcyR
# DATA vMjgRA5ln7PIo6OYY3IXPtTRUxSo7MhMz0jMTaMoNvmujdsTOMDuxfdvuEYh9ZKk0Ti7cIG+3RXZA2mv0BU3mmM0cmxN4c7298Kp
# DATA QZo7JGRc531s38XEhGCFQWJYjm7b+KH+cofz9N1PqV7Vvg+hLVhOO8zAMPQqH9lmPND3RXHT57P71XJtdKwuD8PG6+J/kD3qqKt8
# DATA rf/+G0v15XK5doB2plLZK6FeFfEvh8tcmcVlllciwsCKKwzwCSHpFwER2csYIwzHYpCGW2uBbOI5eTwixza649cL9gq9LdgV9La+
# DATA Yk4z99B/6+6ttRv33oIxnYy7ow6YqUYHg8YSCAFMdOm1pfo1UAjAzb1Ot3f5c3HcHkyTAuJCa7A9bkIvCfIU9DN19AjCri/qV/Uh
# DATA Hof4tArzWV+E/5pn7OK0SP/ayj2rcUGmPrMqQghrrxof1lrHG51R3IOB8UxsKGz5E5aZGgQgdPrL8gkE3E28auvViyw4qbh29yzr
# DATA KuJNWhs4kgXHKYS7ce4rjO3n30jhwHp5kZNF34Yj9mqtjrmI8xgrU4hDyQ1CFtHAvrSSBN+ou2bufNQ/WszHA1gdhIaLdTlk2qDe
# DATA XYR5EMEr1g3meAVfH/SHmcYcjH2O+dadUntxqQYVSbCGMTryvE4imic8Biis2HpfDi8tQrd7AjcXjAyRM4qXZNTNYa8Wne1WlHQR
# DATA 08K39eXayjXDt2LEuXA+LkMxyOSHaNgMBeGid0d7kb1UsBAynOmc7SWn5ry1zt4B56zw4cOHUmEsGhn66LFPi2XZC/iy/HHyTaAr
# DATA GzXZbHzlAGA5JI9ILi6Q0jwIZvjlV+1DLCNibgRfmSaRpSQGuKnb29WvGFUMuqAGCChQVrFNhFEzH53SXDw6DbtLuM31RPS5af9h
# DATA L2tbPUUjoCxWeU4VGZvDbLn03rCbh9C0U4HTznXxspNNnDktb1LGYDJPuG9o7IH4PG0TORXsQFj/vXGnzXQ4Vn/W4D+XS+WyF0cQ
# DATA TYIlnHXqPSeW4s4Zr4241HC1/KSRF2ykBumEHZ19mYqsk87eK+Vo8ssxHEQbwFsjJtpQsoCvUDIewPw5XvpBls4B+KVEUPNAr3/z
# DATA 3k7TQROEH1trt9bpL4TQs0Hw4G/BtoNk6CZA78wFGlTlbq1vrd3ckV8BUGAlhvQHDw3iqPrlAIS6+LYS1o5XoqZix3CbaHoYqC6w
# DATA eS45TOpTE8sHydPmTzz+tYDNv2Zy8W8ygXg8DjcaI6Mz+xWAG0vOIz9kdyra8dygtsPsJ2Nw/fcxOCse8uVEe4k4mZMCNn5mE+Bk
# DATA oTjYUHBso5F7nVnbk1CXBU1Xz6DZTzIuKkmtqnXTRQmULzstDHLUuXGM991vOGcfO/N9gb44H0ZDh5wc05ROBz33dWLogRJdnGWW
# DATA lHatwxEcba1ut//Qt2JzZ/vdNgiWD73VpRrKzl25hNWVbTRMmB1Vg5c+dDYvtIqrzynA7RVAcXg4cy6f/1/arULNE4OEzzGL1sTh
# DATA HVFxd0rlR6iZB+ocU6w+a5d2Sye0HcAnBaJ1+Od2fzw8sB/cysCXDvel9XTrvZTzrqDjMqcAuIPNqZ2AHkEy803qBS5AU/eI/jBL
# DATA wL+t2Ye9N+xDKtVSut/ptfnuhYbTfl7jeef+rN3ZWL15b3unuXX3Lu5FtIJp4Vn11lhYUX6nymFIKSqsTeIteSU55K3koNgfZlhm
# DATA ZGxkprcYWibjtCO85BkoH/sPshJ/QNV/J7kLrsuQ2Gx0PMwykwK5Oui2ej1IaowyNLd40jpN9jMA+MnatWQNs6UJGjlXiCUx/qm1
# DATA 3+liACrDExPQKLoM0F1L7X1UZYOohNgNoz7vuE4umZNNJiRao6+b9CGaHkmmWhpDLIpww07NBYNud2rosBIo3ZqpD/elLmmtplQA
# DATA mNnovgq0Z55e2rNdVSPo6LFoaGlqd2VP6AcFDSVe7Kw1SXC5u7W+tj1nfTluU3EjoKqXvZvcMOu2ONspFTc7oCbvmqM+bShJYGOn
# DATA VYLzy/+wkzfn+haPNscJTEMAc69gbcFfRB4gYnmOfuUrFCHkxtPYufHwZooborrbqh5igrxLKxBc49YG8W1cl/N4GY/h+ArsykLt
# DATA hWsR7mL8penWoiJi9AEfiLF3zK30MfmToMNrcWStq2zeoO17h1XxINzfUMQKaRTh983WYLXd5r9uDfsY4LU57DxQN2PwsthzTjTv
# DATA /DR5ANAXK6zL20yKz9gHjchN9eQMYTZbg7K6zgyyIRIfTB2473UeqZpX1c2As7q0MAVXyRNlAfIwYDQ6GYU6a1z8CVgE6A0dONwv
# DATA +MccNvjLOmoimRtkxMwnpaKGrj75QIluRuc5mZ8T2E3gVBa3UT13G6p+zrU7a+4UhVqcvLhg1H8rlE9MBXUty4H4Ft9lBuasQNNV
# DATA R20Y3LBY6ZVGtLGA/W5pbaMFQ70rpri1fluAZeqsJURkZC6xRFVGF1U/p08Xhzvp906eP6sav55aq3dwHIGbDtP+RRGHveR/Lz5i
# DATA OHDyVEMzr+tiyIaF0jkvlOX500Paya6Kc4zPHC+EezoZsHSSN3LGC7CGnslDmIGv1O3EZq1aMvXGbQu1HAR90G3RBTBy07SSaImC
# DATA 3f7UujmU2ka0LgeO8piMxi6BTALikq2HQCyUghrj5/AvW+9iFa0NKcYZEkjCFWsR120+ex513VRltcCtc4WHuhfFEo6l2+Artyrq
# DATA H5NcSSNxkrc4d5EghlzPK31cnqFFELkazulHoxKd5K74qFfadVZnyRqxmXBV8AHHMmPbFB7H/XAxR7Tkxu0z5fO1y7li2gUwRpqC
# DATA 7oisOCgWv6vHZcOSvbcMMcpWpXLu7mWoN37lGQY0RrebUYc+cZ7JLXJa/oWi+rYjU1GKzcUr3od0k0WXGJoBC9k5RupOnRixyf5Y
# DATA dO0TSB+nDXXvpZiQOIZdoQqkIADhjyz0RbiS5mZ0mjItLQRXHKHRegEKWkCsZp9EyLZcDIdiKckiuxGzRaHgLHXtxff41HkDv6MX
# DATA H6pj64mgaFtpRxFi058oOhJ0bk9I/fsrmE+SpdX/0fR5XSsblN5GYtuGSmn8lgF12Nr/2nH2iD21FRWhKnBaos4ZJi3oCD+HP8to
# DATA Ght0nFSdhrVWtFgeZ7ChghATUNPlfTfC5qYceEBMwosbNp9zFz96+BSUBh9IOYEca7b0cgbf1uyNoUVgMoJ098GBbINBOeeymGjO
# DATA iK3UE9E1CU+mdWGOCC5EREN1HrHF2oEUdmXl9kzFuiJZP1OHVfXEsb9AXUooVXs7B7C0drYNdLjTGq73DvtwwmG2e/5twec00aCT
# DATA qWtoNmqBz0sJomgqCaSDUPdfG02nP2qBck11pDVS3eASqndNg1UstTT3T0c4Y0uwdFBlDVyMXTRKfpi8niwvrVy+cGEF6QKbUY+u
# DATA JhfkeYwFwBhZx8U9SaRxDLTL2jmqx/LWYZZgBIB1RPAXtcKeQ3YF6IiBsQGcb4CUflQ4QTigcD6loC+wodeJ4gymYl3Sa/SoN+72
# DATA e0ffTsNSeVHj+aA1zLPCtjmTDRbivNnqdKGcRer+jspj1HGa5TrpHA1FJqNrFJq/D0bWTarJLYGPSdY6qeitAKvTxOVsrGgCuVSh
# DATA hHT8YnlJ/Y/7+Oqrr96AiUkI15x0r93+UedAURkSC91+k4fDDkbQd3qjPhIOxuNBhOAD6LTqRlZTlS040iZevOyjVjbJAfLKRrK0
# DATA oJNZyB7sq11egr/6+z9uyPDIeWX4QYoj7ag92vA3MUZ+8rR46ssMfXtBB+O/Jh4HfbnYSJa93AlDvL6QRhCrqOEdnHReYepHqOV1
# DATA e6Jhu4Zfq1tqa1/dY8ejjK6qaa2WYvI+qLbIgHGvhxu1F+5qxIfSKQexG2kUxI570cnpkiyCiX7Mmdv1hKlHTNzlKb3SRNyLMRyo
# DATA J+wN108pfwjs0X70ukXFSZVopqgHFpsLuJreSAnGZbndcG59ctr+uN/pwXyWLpDyNDaN9sXN095GL0pTWTJleFMcQJFaO3obc6eM
# DATA Fy+KMmpN4TT0y3s9LcQbSU2SkLmciHsZQXqwJ+HkfegT7tCl/mtLSxAACzJqziGuCB/R7L9PmWLm0+oRn1B70hpU0fLVqLmv0w84
# DATA bo/Ho04XAG3fb47z1lEmq1k7BPvR9x0KvZhcvVx0/FrgA2p3HB52DiCVQwIVI5NVYtYJoRp6G9rm+9H7p5zKfBzgfqVehaOhbxgY
# DATA 9hwEKYmx1Jcnav8brDP533eStUcH3XGOhSHzEWygwTB7ADOdtMfkdSB7P6fodZBE5QAhV5xYNiXocsVZWTwL0kf7KTJ3wmupTyXG
# DATA g2NFACVcf2tPYADvXyVL/eXlZTKlLPWvLkVwaslwR6J9EemZ3FG6dHy/7Xcha4tlLWqpO2IHLDT8WSW5euXKpavFyYSA32AtszIp
# DATA RVbyoZqx0XDcg9VoFyRIohmtwdJkJWwoXs5MS7WBRqaCslzfoaKP41LkdV47zE97ByUppyax1y+5nlJ4gmk3hcFpTOqx9MdCNg7v
# DATA VX+Ty6UFzDVILb0zOkXAJZQ3Clyfahh+wa6ZUSjMTaRHqBxM5wDn2LDfrm+u4fNsOPSfs/TTOcFQYzBJt8CshOiXw9IyRBdJ8fc7
# DATA 3a5VvKaxsTSSDz3Hm6HkVQRoB1VEGwgdRI8A53OKPOmiVVYcPYmF0bGG/8DWV1QGJDge+uoo7hK/jOGM4lAtMvGQMjHzlvW63Wkd
# DATA 9fpqqx/khDslhVVTtLmWr166drlc45SZ6Xh0WL0GnvjQlVyJj5m6BTqqMK8Sv0XtmyvlIMNjycrnaIIHiFdC/MDN/rhLktWhuviS
# DATA qAzMAmU8ewxG3+i9cUDkcRrZQI4g31puoybnRDNJb7Z6eOlQh073FDeWdfZc184O1hZRTB0DLtuCQYJ9CW9LmtBB69TNFLfZpAe8
# DATA U8T1EfxrrVGy7g0a7drEisR9ALo2mzYs8NZBH6gmfrYVUJb9KlhDYjV5rzXIj/v2pkAtqer/uNdw8XAJLpkKNQp4lA3HMfJUGdGk
# DATA nt9JVhMO/xeyOGm9r+6LdGAC7gD4mnRJdMMMfJ2MqOgnYyUuqboOss4A3Ge4voP+cYbKQhlbLdlScwdRU8n7WTYgUTmy8t3Wqfqv
# DATA YsP9MSJl00gIDw0VzIAJbDNXg5UmAxXd3d5ehfw7WQibFz5YNpfplAPdpjvDzEKDs7FfkaV+W28z2pjfs8R2B2VdOUy1bZLbGvd6
# DATA KAMFxrN/04iVGrwSc+IVqp+/cuyEzwhS1VLHIho4614/KgK4oEHYGVk9oyjrYK3CqAzd07ZC+BmkZsWHLEYbt65XbF0ua+9fzokE
# DATA qvds37MTL9tWVm+OH09T8KdmJiJ3An0LsJzR7IwYRTvVlTPUFMMHu6KLVFSOU04PXbW4K5JP9VYyil+YfFbIFrjVUH17UW+Cwln9
# DATA M8L3fjzH9Bk9TjCJlpMvTFObk4lZTNPZZ4GM5iqpoYZCQO7vMFBnmpsrc689UNd0vFHBhWLcyY+RDyat/Ry4XTc7amFGPknCbioz
# DATA 5IwHGolWixDJD4ep+hNvaSyy5LVkI4NkjflD9OVBbtnFvOk1/7415dTXdnkcKEkallEt9rrQi/VfQkhyxyj/LLq4lk2Hs3UCjNOX
# DATA aC9jNDLMqYaIgR/OADKNa/BkF6EyCnypRB95gWloeNTt75fSC2nZo1jQ5YGEBTCvXUoHHThiM2pskE26JG+024cLMFueNpFT4aAR
# DATA LPHPOrs0OEM8Cef1WWzTTFEpaq0GDFonvbZGyCo4uqEWaRhRfWubAixFb+GAfz/FzEcU8eTFr178UsyE0VTbQGNIFOgs7TJkbwJw
# DATA QN5dPFgsmYWpt3PwLNI+BTEeO4V7o+nWYdNo8J/lz1SuoGRpOSoPSewu4V8Sosq5Fmp4ojj2QQnPA1kl+o2zZ0img7sUbBwGx7QA
# DATA IkG50umPc+iX9VhxMlCrnAY7ipIzg7+Cqdn2SaD3cR0xvZvT9Y6zQHOCAvrFXVaPyDDpKu0wR7RXltJMR0oXwMCLaHH18gQvFFDl
# DATA 9I3unYSIlip8D9FNCUaO8qop9voFeY2C5fsTZqwCMqd2z6fwKOyqPRkYTYUBogistKjeLT4athB/JvK4KnkAJnQnlFWj+aEEdEi4
# DATA ++NeuwtwXnO7Rtq9emU26S+CSoSmtHBG/8mblqcyKV8RrDSJs88kkeATyqNhnVLgwoG+BDChrpz3/DEizEI1v8BnsgyScIPOvz9j
# DATA RU/AKc3kCmVU2ycurrXTwTiByQ5lUrL4sNo18FeTM6G75Ug8njpV/zJXBhFnbn6rwbjVoBGdF7JkE//lw8gmQp1go5+jgE0gxXYq
# DATA J7hWoj5OyWkokXQgb5mlmAZX5WTQfwj3vn6eQ4ASiFYHrSGZJXrZQ6syuiRYTpfJJiSgzo9R5Hl43FctyHVTTIet3mnCuheIOqhZ
# DATA Gh2qpUPwiRagJ4i+gJOLhGsLFijVG2EiOFcsFwj7M47SsRrENCsNdq/G6Kw6ajbxT/adB90FoPhnZDKo+xYIjDtFLZeaftQNQnsV
# DATA +HW3uXXr7sbtHyYf0C+R3PWDjbtv3r19++57LkmOYsxXq01Nk15iOl+JYn1JOi37S9J3oM63qW766vZc4kOHAVfrwU3ya4UHscF8
# DATA 0O2fnlBEINbJoXxT7rInreH7ePFPt6Ti5P/58HcoiEjeUuPTD3tNxDW1wST3usBwSHyoufFZWaWKnWZ1dinXpKzzJ9rJq6QpcoRx
# DATA V4Pi/+jWaJ2RPm4vvBbnMpSE4IHPtIhaQ/87OodxcgmEtBBoKa+12oRPQRvEbCLLNE3ZBM26LWIhA0xdct4xqEksu0PYauxLBt0E
# DATA PH/0q8LFV5T1/J/R9QxWm5CEf0YuaGEoKBT+74oCAHb0F3K7sU4X+c5u30/ugSAAnByCvejq6tGF3TTBrwOGZHdDQBL29mK1quPA
# DATA zT75DBJcf45w6ybgcHpjxMb0hJb3nGw++rkVzozzeRFsIYkd+gX3GZTcSR31JaqteMBVvY+eXvewdvEggvWSW2I8f3CNrShW6zAD
# DATA +CHuYPZLBMBa62SrJQLwi6ekKvUFJh36kBQ+AqT2OGwXANeeKgaeJ9VuK0D1YFf3P6uCn4CUoBrnT3AslcT4SyKCNXQOcawhOBRR
# DATA 1ziE6AmS05eUClaSwD6rhQ2mRItwiYKD/on5BlOac6WUcuSxoWjyV4Q9IdBW5XAs/yeihoPf/p/U7c2NP0AvWFVlWCEB+4S1QSef
# DATA Eln6sQyKOMN6htmRuu7A/SE+aNqtUAX62h60o5tOPUxIfSwR58kAY6zQ1si8HrbWWK1o1aBnxDf+XiSWyyBjVSIocho8rDpo5fnD
# DATA /rBdGz1CTDEL66YisDQVQpKp8CxW+DIHfwAgjBv35TI38vkJr4h6d4hboxuqHTBJrMcKeiChi+UNNtqX3Yhq4OjSMF1fCxUpXpKd
# DATA DDRxnd5Rg01oZccNFRmzr1shpHjUM6jbgZ3kEjb4m+u317ZhhgNh1wzXOlwi1hE0uqOZ2h0yGWt5NtxjRTcK66TEAfTuKeGko7/s
# DATA fbmId3rt7NGMM+fFryrAdX6eGJd0zbYQRDvGyNN0z85PxTSM5EmIBYL751iE1DWjbdxxzYYDd2pTC6Dxe8oEjAaFr60rjFgLzQu9
# DATA +J7lEJvJKA4HFRf0iXdlwqkChu70hFbRVOGIdUXwMGqvq3l+jEiXjx3ZzRAFCjMF9ZbdRS5M04XHqZzlWDMJYw5Cu2nDykEi5zkF
# DATA 4O/5ctjs3hXLROGEwnT8q0tFcKTNPRMMKuep4Y7Qs9sbnM0O7xR4HSEHOcpm9fj3dDwjzf9jBPO0zoLMUTYXTUynCwtc1ZuYoIF5
# DATA icMnkKCJCK1QY57EZ3Y672AjrgVn52IAWqSO5hpfaiWF62790op7sszcw2FMFq1/dDvzAhNFjHsCkNBOZ1VqEUAwjnMs9zz0Hl9W
# DATA ovRYnXNtdTPqwk1uDdHCGV1E2dWW4f5MGiz/rPiIky58iNopHFqCHz2VdC/Pn4Uyo7Ty/bDG1xfJqMUYm9ULiyxGA51igI8rW0ZT
# DATA zDx/VgFtlNbd0VfPnn9Gmn26NT2NauXCzoIgxPPx73PIowQNy9Qvl/hpgiflUkREDz3tj6kRmMpPuOSfdByqkx4iFHN/b104nvIN
# DATA 5onq26eYAwMGjh36jK8QeBMxs8QXQrHhK7FftJtR7Z0SEwR84MXPaybjKvIBUBtqOcVKu8QyjPCKuPSChGmkF1LlIDYl71p02B6i
# DATA s+gR/l1b5eTEm/hGa4LUjm00m0oGbzbL1pdwRW9KPuNS2h9kQwkzOjjug16kwUCGgEOMsjAoC/uMyz4atno55OtDLD2QcaosbuM3
# DATA 9t+EtAdpdSGQQHJntoYoVqPLSJUD1qs2xBThACOCEvx9REjAxNxSzFKRH1dpK3ESzs7hqfXAYVmApxc8ZBzy4Dl3nro2HhxJ8jbA
# DATA 4OyMqlbmT8jrAVp165HgGFetDINgrLK8JrBBVp16j8UVy/axGLIrj66JphsaqnIH7MkqeM2dj7+UcdBbZzJGAOWn19KA4ph1l+R5
# DATA pGIUZ4golVWrEq97vaiABFQWFhAXpKnNmDujTc6eLF7chjmIpraicdqKO3uCQIWF72nhi98zYVFymal9ARz2fEpNQ3ZwgiDI4VHe
# DATA AKX61LEpSpvWMQpPNatRWNLa01UnWrugvNk3bC1rpDN6ilSoPqsi/or6sIVWtUaKRN2kRItTm0S81v7XrwPAI6snhCpjyK4oHdee
# DATA NURTZs5WOAmFrgAzg12f+h2DVgafUlaxac0Sp3SXpLAtv3pM0jOdKURY9ZyL73xKu22+XroSbdDl5aWZWx8PNbPKkmculSyqzvrS
# DATA 29lre66ZhpwqxW8lLXXZ9pTnsvgPlLZS6sKvmpYDDNwiMfgCpwf8iJA6vVhijfLhJQe1PpPQYLZK4UOADYRYOcz5WfZUQtZn2ojl
# DATA g+tiU+vQZUDVDXPGClCSH+4cy+DJeCTMkgxiS7Rblj9H2UusSLngOb+2LcDS3aWUIqCMTkmdWgiY9nAIvRgN5aKTfgo+WwKEG19E
# DATA S4gziwjO0eTMjG9K/mJOr5KP+ro7D2Jk9OuqJMGaz9FjS9Soh6QV1OgjwsdBZvyu+ettmbIggS+oyADPYT4kLsT7MqBTihWs3r7t
# DATA InQ5ZkRJfoUXUsLfsF8PDOAYOsE7CZ5l4mC7wJRRf01uRe5/NCWGE9PvdELDLptRREHqKXFXGyC4MHMXjG7aKNuEoca4CPPNJjg4
# DATA xBKCzckN3EV05o735CmkX4fICy5Fu6vXT6cTp33vMNNLD5rwMqN4iJpBqphan385OBexM4hGEfwWS2dNJW3Q9/ygzMzW6+KcU2sV
# DATA Ee9P6MD0YcYuPNaZEgnKOCfTmHp1sq7fXMyO5JBi7rDPs4juXdHKiZirxkZNftHkIzmPHYIh18Qf/Ik5HWenkjE1yXJrdsEPiNZL
# DATA 5XkGFbubWzRaCOk9dYiGDs938HhXcHuvwIsmv3BO5CmLWjTH0zvh3/ptmw5dF5xunIcPRK7nPo8Rz4+iDWyzBBK7EM2Dq5uP8vAJ
# DATA N6c9WhkdkbTWFc9aZPiM+czE3LifMimGGchMR/A2W44wML53NmMEZANKOywjcFqfNrRKMmsEnhsuuSJ3eoPxyEGvQb+fujF5wuWP
# DATA XGDrjrchvozLlBSXZpjrFO6LkRhWVqciMpumJnJSHWOpuShori07tTnevfORq3/lmLVNC5Va4b6lDjh5L7Co1Q1cjIq1BblfM6zq
# DATA gCA4Y6JcDaa1Fvi8Sc/PxVK0wrY+jXqkVGmWtGBlmomyUUkpAMQ9Y6yBlnR6D7l0k0tP62nIQ/AHfzmjW0ar7UthFcizgGhIUiRG
# DATA muedQU4r5vdZH9f4Uw5rofwg48tU3hC9JUdu79fjiVjgAqQGfj3u/gayv7bhWc3aiNZ7812WC49FbVuYSiK0c1Wx0rSdqeVeyiVE
# DATA PwjcPZxbUETNoJdQcVX3bxnaohPm94k36XSxfJ4OiD1jzj5IGtZvuhsz18ppa+aSaeY5h85gZtMo9EOTxY7OFIWpU5NoecVK9TO1
# DATA D5xYyqzBLIGtc4LJZ/NTgweg/q6RD1cP7g+lJSuDQxP5a7Np7TGO6C0HdeqMRi4m6CLlS5viYGAF1cwDjQzB0J+jIyVmsg1j5XRH
# DATA JGc9/igNKpJxzyE2/ZnpKoWmusg+1633OgTtyhWfHaoyjq8f/mgSXyyF7MDNAqVZsZs+iqjeqPINbP8MEiEbaHi6CFvG96W5jlud
# DATA Ps4+SqayN8p1Zo3HKVjEAiJ5gyMv7GbctO8VgkXVjfb69rvI5EYXwn7oZN/y9b9f54Ryq1gDoLVNCEGmBG0zqpnjFL7+cmeg2Msd
# DATA gTlI6xMIH3OLJaJE1PavKuZHSQM19vPfG59pdJTkBNbgGPlseh6GAFRc84dZN5W0Hmg9OXVnjHkEZe1cn84H0SSf8hWQVp0SjRvu
# DATA H5aiLagzKjbBe7dkvyrHNLb1pDNQMwzWgFpnoKVareEBUuscjGzkgqJJQjTUBT/4JFBzS9V7BWDH+GEF076EuV6KwlB84ULtjwek
# DATA 7X4At2wKTZmGZE01WCEsxVc59Po4hw3Ky3sotrC6p/BJyWRYt3joJFwytp3b6Dz1WA5DLrcaSNBWJbOl4YUF1W4TSanZxOE3m0Ck
# DATA zSZPgBM7Rj5BCxZkUwgKBNhNiOlTnyZ0yB7/1xe/VJv3E4q/KHAwmxmNgM0p/oKJkUGcIcADC3IJAYy2T/NRdrJG+cjtQZTeBarA
# DATA 3leSd7JT/gugyvnPu9v8B6LF/M323Y1bCAeFT8t2XOQ6qmYw9VOnd9AdtwWND/M55fWkh+gPOP5kmP2YwG8oHgxDQ8fdbgIN1L7l
# DATA 6aslz//NRI2++JigYxjKQwevVFw0mV9R1K3FlymOxU169uJXgHp2rtX4L//5v3n+p3btfhdOYrUta4PTb6UNAIK4evky/qv+5/+7
# DATA dPXSJf03Pl9eXlq+/F+Spb/EBIwhZkQ1/7/o+r/66quwMRW3JWu1RLNi9KgkoyMlXgdwModZN2vlgOxFQdPLtZXa91ZqCws7x+CW
# DATA bhfEvJLJ6FidO4igyDFPiHvbOYIcHMdZd4ChVcfAjgCbU73tj4+OF7CQvqAkOzc3qwQcfJi1AJgLLcUQ9m36CFpYeHrcepCp3mUQ
# DATA LAGG2XZN9S0bYkR5Wx3R+3A0A7hcr6+t7Qf2oYMoxY+ygzGBXQBYHEioBNy5AODRs464gB+lO7PGc6wOObvT6V+IgzkhZwc/zv8D
# DATA 9v9rV68s+/t/ZenSf+7/v8T/0nGescCeXl9YUBshHyVnyeawk5+0bnY7eIGnX8kEY3RwW5fSvx7gw8UDLJOWr/O3P344souBePMw
# DATA 2yeTRVm3sH3z7iZmA7uLmScRvPjvstIuZfLKcefUBQLfd3HO64BzqIRdjjOQBGBBmAe/z+vsfl1cAK4Oqpo96OHhuEdoNMNsnMPp
# DATA WBr2H5Y5b5nkye4/TP7qr+CfGqd1c8L/7YYwkCNVpY1eCD7LHg3UBK2O8NMeyGgffJA4L17H1LW34ApQLgff5wfqkpHXFF89gnh6
# DATA VQnNqTz54ANHxp/rm4vJsoyKi7LEmbvBWHVKGuN0imsCWfS0hF8njdejVeHvsprpycJCCwAjEj3j6tr5oAN3mxJRVwWzr0juUlkD
# DATA 0AK+svij3aXq91rVw72za5Oq/vvypHpZ/7ikXlz7Xmt/z3kify+vTL67WBtl+QgzvMP8Q4oSa+IgNUj/UDKnvkJaM8hVkkJheixz
# DATA 9/3k0koZIHMVZcC6MZ7peg8VAXJO0QGjvmurTdNpQRq16wIgqeiGk3JPpSS7vDhrwi0NfOISmrZaa9DBJPZ5DWDe7vU6Pxmre2Ty
# DATA EM7ButreON5JMuHGFxeTrSwfq7YxM2DSwgO7inc8gZmriO8JNIc0eiqpySDZAgynD/Ccw+xB/4DP0cNk2Dk6HuU1vWy6w4rMXtH7
# DATA S56WZYVx8v2pZD+3BHlJcnDc6h1l7eti/URpQCc5cjAEyP2chkpZdbpqOaH2hplBtaAFU4jw4TB9wIvqVg+JNmHNKons2rrZtPCf
# DATA Wq//sASBMMtLyYXk0tUr6r/Xrl7Gcw5cR3Fr1JPdWq1GG4hj0Jy12QERqt9tJ0fDlhoO3fcO+kM18kEfkoVA4l4AFhwrsUmtA0Jp
# DATA awDCmlpbECmktj5lHG4B9bQONA4hgi07iwwyWAfpdERLjWNkMSi2oPL3XMzDmkdaiYLZFyUI0e4ZzPmkgitxxrNnTd5k4iwzM2t1
# DATA JNVA4iyd8ZKpM28Iy1ZHxgswPl2Iw1vdXLdCsjottZh3wIxx2O33h8hAiRTaq5jfCECxMav0Mi6m/lB1p4DDv5GcAYhjC9TidUA9
# DATA zyaJIihVMGhJPg4bmpSTScXyFwUmVFF7utU96qsNe3yiRvL2NjhqIA1NYbJv9ofrxJai7LZiksDbnDd4KBvqoNvqnOTXbTxv1S16
# DATA CrC4ahXIGcBUYZo6092H7cAD2FMDUFvhADDVVFWLF5LVpN05PCS4YFTUIyysYjnvK4o3bBWyG+WKjcFeFBKuJRcWk4ljSuK+KdKl
# DATA v9BiTWc50AK84COA3yPfbNjngHUC4v76Jk8lq1Fnvxj+P3Xn2KxfOD/UVbdHo3eMPS+O4FPWuamCw9mqR5/RprZJuBNnnO9IrdQB
# DATA FB9rlJMUU5C1x2ppFJMWfOvW8OgBJXRuABy+zA/NC9UO2IJq3ygx5MwlyshM9kmyBHD6MeRTKJHM+0aNqnqXVK5v1EjcfaOWD7pw
# DATA r6ulAOmcvPEGZMh6vZG8Bns80DUrKXYwgqTIQI8lLRsjGFVrMFhEXT4NMV8UwZo/qg6O0nKNerN5VC6dRR0o1SB6hMa3jYRZ1/Ok
# DATA DsLardWd1Rur22vNe1u3K+qG/6ierFRm1LNDCNd3Ol0lG9cV62kuAS5xp93NvFeX6FVQ3wS4Un5wnJ20aOSq9VJRt8q1PAPo3M3W
# DATA sKVIiuL/8Vu1tGp6Uww8PQCe5rYEHBQyZilqV9JABJcDm7bvMyVea5tUhce4KGe+BHKLPXmUwNMBNtP5OxJ0QEQCUYTYW2KPKw03
# DATA RLnEz6YxYnuejHV/+96N7Ztb65s763c3mjt331nbaN67t37LLb66uckeAJUgg8CU6rbW7qkuY6VGs1oDiaJEEpfaR17qAzIC0FuO
# DATA 9bU+xSmVDYjbTHHXWkZTWYQR/PwzeISAg2Cc16ANv7BgWtBS9zmmPjYwCAGkQ1wd/dvnv0NjXxzM0AfgqWGAkszdo87oJlrPk2V1
# DATA LFkjZWA7Hisz4u+iZxpupxLddmiHw9Hep5xdZ4YEKjFqqMg9eXJ94S+g/2ma3f+NqoKn63+Wr1y97Ot/L6289p/6n7+U/ncT5Siz
# DATA 9uI+i2lTQM2q9i3eKAL1iXPLytrqBoa59di8BJzy6mX5BYog+bufLyCwOTgJdTv7Yo8C9wQpMszkL7Ar6r91fgt5MspOBnC/owrH
# DATA Q3Uk7VN8oNQKviBwWC/oqsndn1EJyFcL3WTRlZk0uIftedAyBRzT/N64cfvuzXfKJl0ggGK2KVdgG0LVOUcUJQy0DJoEL44QmgAu
# DATA Tu+9zEMWhB4Uqm0317e31t4q2QDVDmK1pOWEfDOxBCzGSllK1zfeXb29fotPFYB1cCGbPORWQuqShkAsZoT4syWcKnWAZ+ppqTyJ
# DATA QmgvvfZaeVaPTE+ad+C0urHW3Nxaf3d1Z83BecejiSfU5Ne54ufX0Z54C46HOK08/tdJ74RPmESihZ28KZYvAr5FHwhciq7+IFyI
# DATA GYsgCSKIXGuB3yF3WsiYHHkIkVbu/tp5prC7pqT0mOLvOHkBj0B+wyBWli5fwxjX+/cxV5BdFqIN+8N26aAM+rBL8Ih/Kil9eeU1
# DATA CrOzvyrPMx0UBovSFJZmlxM7kxRGwnFH4EaAAbihx4VMJkEN+XhHeKP04crs1C48m6WzCxfY60HCMzFUIgzBnQQ711QnicbPn9sl
# DATA PluK86zelrnaWH13df326g1nG0skMEWX2q1u0JvtbAQKHDtdvLzS4cN+bRr1HtmDjW6om4OhwzNmEaX0uJ+jQn5/2GljzHvaAz/E
# DATA sgNpj22QQtTvLeWeT9Wm7tKuhqzS/kxL/2IpYdLd1erftqp/BxDt5s9mrbqn+Jci1ElKir1zTTqHaBdMviHPJIWo5foiwphrQEWN
# DATA YMkkit5b8sP2lNOTwQsE8v7m3S309yW0Au3FabssWe3rPyElCPbD3scUSYqB1dxHeYV1qfNUVSGnqmENsg3Vmxre3Oz1VpUh6g3G
# DATA cWs2A0WBFHAO1DP4Lbo5+S3Al/L7J+OM0vzAj8Nh6wiFD11YHbm6VQR8ptbwJRz+ijcsvQzLcQf2SkPGokOWmdqm1f32zs7mNte8
# DATA tfa/3VvfWruVOqeO1tkODVlXpGrF6Te37t5YAzamxCzSW0g+ZHWZWB2PjvtDvpPWk/SGulArNoNIZ/71773Vd9eaq5vrdNKo6wV6
# DATA VkdL6ZlgdM33AF1TUzApprgXu+kPqur28rA1bGdt+Av9x1K1n2pL6v8tp9fjJTeHfcWt9xI9q3Bb8rSWQOoooEF7NPbWPq4o3tBX
# DATA 4e+bhMTVhbDsik5jmJMGFWL76YKG39Xwv1DuGmhV1Y1cVEOsWkPlep5p/dphBoxjxhwxGrJinzxQwGYn1+d6ildfRZSgi25169QN
# DATA +kFaODRsScO1/vtiT2L6oWCS1gF0gPQKoHYFIa+xBFge4977eWN3D14AG6Zul2g4+BYtMlL9fr99qiYTPr/YwNdsyrreOSzB09cv
# DATA X8B0LfCf8pkzadcj/ZKKVc8m1JfaAPJr3hiDwrYG8nkJn6vL8ERPM/qpNdA9jZI4c3H19kDJwVRRuTbqk14LpTklzJnpIqfRDz4Q
# DATA TS3+fqXRSPtoWUZLHRWq6SX1SusX1mfRqbeGuKD3rFuFejERoPvk7KCr9qAQH9IjjH2yUELiLpUbr2tiFmN3g5YNOftia9BZJGP4
# DATA ojaGl6+rgZe4//JUfEJhBKyaLkcGoEFVrkuzbAAPWy0ylVvfqurzxupw2DqtdXL8l0P38/IbYljnf2v8r/pWdf4V9yOopxzrrt2k
# DATA +gzK7S7tvUEa8bl7vJhexJjG7N7W+k2JSpDKWLuuGE65VNYqK7Uuvr7K0iWRc6SFg6Khtx8D0p7WTkGpL8kHkrDUP6WnUc0UHg6V
# DATA RJVB9D5IH0JJi0gXZhpAkHEbzhRzI3m6LzVlvtqqsXwduAz6L+GVQRXYz0ocEmHuAXyB4UNH8RWKWa6IgxWLRMU3qPCSwW3YNwx8
# DATA NO2w3Fx9a625fgf+G8pTeLWWq39tJ4OLfWt4ektiTEqExgG5VCXtH1IEDrlKV/DDflcxaAf+X2Kd6FWZY6hFJQbhWabDLJiRChTR
# DATA 2dPIedCwxSfSkUbOXyzlqFFjInuJV8LJkvQygnuQvQNtYZHKi+8idP33pWz+0xL9qSDXbRJdxjIDIXGZdJ17iEWVHWC2YwiNqzJK
# DATA Ovpn9x6UNWXuQpV7gosHxeG/KCp5gCqBCz9hQPRzVCE4I1EXGrWww5IeiLmtlOfrPEOxV6uEMlmtDtTtA686GaNQ2mhx1ItidIyi
# DATA OcDnakGRwFIzCbzlonMhTuraB932VrdSyG7rP32v9KItC1S/evPm2vZ28021Y0G8pRSGeE8ntgN6QgPxgolEipgPt6hY1hadtep7
# DATA xY+zNujYH8CNXuaEtI/Xk/y4NSTvj4SyqSgOdGqliAXuZ3nAUz4puEEsmESScewlTtDmYi2xl70SvmObP61bI0sj+14VwAFPFiQx
# DATA CtRlOgUsB5Ni5SUJxaJu2FDD+C2Pm/CeBCgiWlF/dAzY8QX1uOmh+C5fSfAjk4HGnpga1ATQ/XLJf0XnHJW5ctArsBeMJEdYH2cp
# DATA LpWajLPJRE4QGlDdy/G5m9o4LnBhOLtwQVixBPDbd2VO6yh5b/SnoGm4cIGWbxK5LFtTZ2Dg7IoJ2+IsRYcp1XUh6BTGrn7DP5NK
# DATA EpBNhWnGHJX+vVE9s3vN75uUX232FlTnpegh7kAs8L2N7XuboB7Qd81QEwRJhWxULY0YV3Hg4jDQLqbsqRjUavnUJoswUosyB8HR
# DATA QNIzjRS0OqgplO2P2K7mAAf4U0fLAx2y9Uz6ULJalJe7ED8mLZvDip47HXil4fGfOaf75t2NN2+v39yJTLM9uxgid6bOthEoOrqK
# DATA ViilNDVfl2+seW+NRi3gXoDfEFIGQoKnkpvPTeZrzYNUwlPgjkxehv2cTIuAszoGDrQlqBkveurbvLR7wbQJk1wuB7tZDwHjzLi0
# DATA 4zCC2DDEH/aclGDI8Ev4piI+gBxyWF9wuZcmTsruxJRp8Ra1FpDtEe1Vtf2rl9lygN/tphTpAHm/PIsCgd2T9yEqzfgD4gl7BbIi
# DATA 9QnarMgHuLf3guo4vehfzP+fw0m/8TCg6fbflZXLr1327L8rl//T//8vZv/dPu0dqLt3D4yFEJxCnjau53F/2DnqYObXlp2ChVzw
# DATA DE48ylco8GHim0cjy7rLTziFpxhjDw96o678APxB9YX81GHG36gNGS78L2Mtfmfth6Cg3L53o7l574Zi9M1bd++srm+kC6vb2+tv
# DATA bdxZ29jByAcURCCPyjD9UemNOrl77Cb3R3sXy28En+OLC43ahe9CBvqsdgcsegfdVp4nt3A70lFjTh2NoK/mhRhirz88AWck5liF
# DATA tj4+fO1rOLFGtvLR18nryZXlFfKrZKcsyGd7P79//7++8Z37j5aWqvcfLR/ef/Ta4V7KLCyw4tldT2mgTVat8/HomRGYR1v2CHoS
# DATA GiOsgOtCpfyctgRGGSFzAVxRKsnly5ei5onzDxC+pBHqSmqkhyqlnXavlerzpFzrQl5TNk07t3Mn0p7/LEF1TrixIQ4LuAXoIzy2
# DATA 5+09qASAJrAtsPpeQWtuWtOZ4nF86hH8qwbWprRb4BIJKfQwdbD5Cw1+XtosUFF3uyUvcbLaMUuPxBv24gfwl9o3KWAkDUdlvkoM
# DATA dQ8sR8ygdgTuCFvYZbufaon/RKvf1eWJvCm/MVd7L0H1nPxSbFW79erynpAxZUKTiUTLFVK/vJN16YqrCizL5SValloqlyv4TVdA
# DATA k1TLGf8iD3y1+rdqsLXm31f3LqpHi/6z8gWadsh3dv6RsgCHVEJGEcvhRlxqBhQ04shtdn5QbNzmZpH8n3y3NFAmwAjgyTx9Vrej
# DATA 1Tfhyr7zdhrZft+EGxDvUUB02eiP3gToF2+rgncNz0Q95sCqnRz0WL5V/6LS+R2MllYuJxfoH+ttD7CZYDWWw4y/ptT5fYdWVqIX
# DATA s/nWF1MTtkYt32fIGsLFZLlsbzYoXnaH+XK0xesJ9anN8NeeRASbowv6Q/JMcbeD+KrUdMAzMNb30xneau9tCVHe3Fpb3ZlFsRW5
# DATA cxTRV+tiAX1F3NIKiU2T0tdbxUCNjbIkxNAcvM9tVvgZjK259gM1XOv3xo1AJXoDvu30jtbvelu0oH/3Nm+t7qw1b9zb/qGj6ZRP
# DATA TjtZt818j1fbXlvxSkIMEHBJyktIjFMdkzRpEkiMyRCGCWMIeZx0JYjJbgoVJE8rnvaNuzvNO6sbq29p1ZHWF07Jjm2za5N/PeDZ
# DATA 5pXDuE0LTpk41tt5KAbkL0yuHcOJpNVAwCmrjIvFtWCzR1vBBBUz+JBIHcvJ9xvIOvBlGX4tXy0ST7y6WECHwzsiuNABjY5Ky5Xl
# DATA lWvaUcn1vMJmYw1ajfF4i7rOr7Hz116SXiSj+ZlZVkmMVydBIHxhiQWIkzdZMEhzWNfEpEbHLlIKQ+ysLf4i27SrpzL+IaDFkSmM
# DATA RUPZWxsVD4XApGJbUu71OjFEn+lzePPunc27257aNsJZwttdNDl8OaruO2fzRhyC5dyFyQJ9HR5j7hSZl/R7wTclaOKMpnaIWl5w
# DATA REjivs0STxwqFzMoevkgnRTv6BZkpXmQF2Qr3d2LNeV4zXI9UdAxv6Vd/cOtFyaFUEDQ/S5Iim7XFaHnEn67S0jde566F9+Juhuv
# DATA EfgktPLQmkoTe7Ij5IEjCFEydyUJXVp5OX4gApDBgmTuyZPJVCSWQtUHvO3TZtNqDdy5ndxDMvOFZeSaOP+omzZKGgyMROMues54
# DATA St2yc4BxJcWtCGYdF9xV9znwKuFbYkNxs+Xy7vKe43wuoHS7dbj8gafiq6rcq+mrFh39ZNxH0YAKLtmpXdryGAdSwpIVEVlJu97p
# DATA 6k+hvBJo67oL7CoN0YpLrF5JbbYC776f4LWyhDXJNRJ+2Bm20++k5bkZi3s5tGeOurlcV+3uRRQWUgyUUTip6hxEXdp3RPmEEY34
# DATA rrFcxsm35tp20mKykmwdpVlkaDxdsAeGHGnPhEfXnru+IY2KIbTCNFxokrCSo8vlSDyqgh0c9o8uLJJM1mmdjzJTX43skQGE7nSG
# DATA TXdKSFJuOdXHDLBT+LnlV+KaZsOWDhPQvqICGtqsR90kZB6ozK76Ys94KtlZdJzzXb7ylagL5zzWmRSlMdImol6DJeejDPWBrOOu
# DATA cfqE8kKcLjgns0MeVmtUnYAj6CQNomAExIn9FHS1mKDLaxPJo0ZVED8Qjir4kMQX9tOTTp6jv4+zmc5SHKwS4XjQ6qJCoYvqEffs
# DATA OHskDUh2TyrfaU9kHxq7A4etEKZHA0MAGEkLbkJ818CLk7ktmDtqeGl27ioFu5vDCvSVzCQqIWSzxjkYhc0/aRDh3rcmkFoIdC62
# DATA MIeVWObqPBvxQ7wmyRKgk9QAIU+2ZA0mMW0Lfbsblt6D6qhDu2Yd9+aXGN9e3XhrLcbYzY6SxqnPlEbLexZSnyPunvTbgCvXNvL/
# DATA S7PTaazUy/3H4uxCkWPMFOb4klKt1Vn5OkpIMyXdczFpXxSexotj/FjujgUidXHXi0/K4rHUBv1BSTXvhwoFUnPU2y+sDw8KkUMK
# DATA y+vUcb4DElUSfMc+BXhhbI9PBrl2ect6OTgTtfKDTocU3xVM5N4bNVYkZfYcbovcADJzmP/9NA0cFGIHKe6BV9ybBEkvWtCzRGW2
# DATA /0FjBctYSH3cQbuy8T4G5WBtwdrTrveKA5mpKWlowx9/vTCNkjQfeakBcb/hHx2GAy65vDTqn6BTsVUDNy6oQp/Ir9CNOWxUeJu+
# DATA Ozvf+Td+KT3PwaJTbolCkR7ki6wfVHfIWA6OKgwMzOToHH+5VIbT3OkI1eNq7ujZ11Ppcr2ULgFUxI2l/msAO0IpInLSCBU41pjE
# DATA VyetXucQpBBOiWU8DHed7kWzXEkGI3xoEtlzDi3MuWjrQaLnlufHazJneZKYVVHZFpnmamQSCOzY24o+5rLe+ATBTktCNGbq9ryU
# DATA XSN0gbYUH6F23TRQModuOd5QRGS1yCdmAsSVBTqyxh3foOeRRaxGC+azoI04ZZXiNMFI4Vx7oFFYmF67mczZX/JSSZo2V28pRoxW
# DATA nq3hnxAHGKyhUMcQ3NBzJTdzneddKkJlsjhXvUhW8GZ++kGPttxxj1T9C+c/2GNzO/fiGOOqxVT1NeCCc1/4/wfEuOP/d9I5Yny/
# DATA b9QFcLr/36XlS69d8fFflleu/Kf/31/if995ZXGcDxf3O71FCJoYnI6O+71LECV2dzCqKjbByV8hdLTVM3CZAS6pAx0JWJyeVyC7
# DATA 07WGR+hvt6C9Agen5I0HmgzYueKJJ78pkPfv4Db4td0AA/gYSIEgSDLg5TfbL9D2Ilx46UxXUSiadkZTqk40E+NPnK7b2ldsL0RC
# DATA uPn/tvfuzY1c171o/uanaI2s08AMAD7mIRkyInNIaMR4hmRIjmQFRFAg0CRhgQCCBmaGHvGWJSU3Ttll10ndP26dqiSVe0+dv8ey
# DATA ZI0kS/4K5Dc6ez32s3c3GhyO4uRoEotAY/d+rr322uvxWwyArFVp97GkFfNlWm2pImU1rlDAkrwVyrwvFfDKFgvZEq8S0IIELINf
# DATA c1djvKrvwjNelaES+tWELdnUQXN8vzHEGgT9W2Akx+0x4pGsKDwSfGJCkogHcCbq/GbySiuHbN9w0+0BCr3BTKljZdPh4bi23dl4
# DATA FNx2Mb1xaXDKuch0IyWrE8NpsN2iZE+9sgmzAUh8o8mUJmx6njEr0u7TMZRpNUOtxl2qqaxgPNga/y35Yu6Ucb7G6jgMpnoodmYN
# DATA dqF5gylKnBwZTtPu94SYFOuN5gadxRxRiYGXlwZLoccqllaGU7zQdpZaWMxYhLpq6T9K2YtktIO+61wvyNEwYggNXho7IRbKKbG+
# DATA uQsgK0aRJB5OFhZLafbI3mGnWE5TqKFk5+AP9FZT3f6laplyuJHTuuUUbd1qrsIFORX05KkDenL23YKe5HAkpGcF3fWS7azMRFXS
# DATA rtJgErx166Yz4Jr2u8apemOpmG49USmQUrgFrR8lyJsMKaVxAf9rkBQozB6JGQBGbe/WEodxZ+PmlLy/YyvUcw53qNmEZG8RX8An
# DATA EqVinTJoIsVSrY1DHHFRC55a7YnOYXQa7WsOdpNhthx8IFp8e2drc69V31yXz9jE+wj7Cfngz9weDbjJRJ+UjQxEupYRJYj2h8uz
# DATA wQUn6DCOeL4vwVEBbV5IZhiUX7D6Sc28Gqwjy5CYaDH7frU742EcB5ihQAV7qxC2yRABzzvoW4lJH7mynwEMP/wkX+FYW8IgEM8p
# DATA COYgAsGXfDm7hI/ePjnoHU2H05jjcjmKNmZPZnhLaijNyYAAefwByxvPakyPFPDuvxwzJH/BiMUvGPXMvWZp/7B/SE0NcmJwD1aO
# DATA M5aHKtlMdKc86+azsqjAY73hJS2r2c3YWId+VALb9VqNgnmoOxLmPv6Y0IT6W+8ysVwK+Uo1AqwLQLMepWN3eVm32pjWGNmzVMKp
# DATA xwlOGRusskY2acL7b0EaAMvvXuyWaX+ilYBxRMCKopvaSK3R68iMxq2YmfkAFzSHYLOBqQstqfPHCKatqho+HqDBD6usjLlQlVxq
# DATA lpqUQPK4M670hov94QT8qBd1uHACDsZycjEmgUgZ2pqxsuNICCA9vkfZnVqkTpWXledP1R4LatLU60pESHbSCnlO/nw2m/qg8vzn
# DATA J7qN6S+unlkv8Uy6n0Qn4KDmu8M6EeSFBPiAxCOQ90b1QAXOUyA5tJE0DstfYCGhBZ5eIGDXzRBUp90uHorOLgPil2pVqM3yeGBv
# DATA DCqF0cy1vuA/3TY2XJUjyuh+UXmBE1QIBBsLsRsSaKI0UjNwN8RXd0+KR4XGdeOlJhnCahQ73mmPIItYazidjKby4YRwp2rLbywp
# DATA psnjpGGBIlRPkJGzlGP8Sfy17hTQtGFrAxqWOZiCcIS3SMbIhI9TlH8ZCCWeDOkrwqFIMBSEeDkDuwtDpxjeppR4Bn2/sNeU9hHj
# DATA nQwgnqgdE3B/wU54FEJ+t2nnODBuDJBp8uIX558CTlJw/u3FxxcfYXpKyGb56cUnkGwyOP9UpqoMHah5cKH/YCBYRXDYb+OIGcHp
# DATA I0wRzFIHvyyhnxCY6TNs9g/nzwG+iVpxMlwm24JMIeB+MwTYk0Ev6mKDBjxUcP6FeP9PmDfznwDEPFnHWnvAEKMAYiRlHO5otx2d
# DATA oHks5AcIZ2XiT33uq5N5RJtdnQxVD77/FeZU/gVm9PwY0K7EzPgTiYofPBNddFZWUSPaZYEYKUMh0T8ZMogCBFnST+o63BtIIpKP
# DATA gNAYjssE35IT8Dytq78JTNI5fxa6yUflhSKZvrZwGJ7/D0otLabjs/NnsrXCU7XlzopMLl8gwhd07JeYgvoZAOOXqFefBU8T2/es
# DATA Cg9h/GeVwMxvLVPdfyr+fIovAzIYZFK9+Nh2xtWbSzALzaXQSQQYToEwelDFYrpmJWJBkpAyjrOWLygEDL1JDR7Wp8u1B51j+8bI
# DATA sw2rW4DpfYbpaCFl9+9no6OlELqlQmu4/jIjq0sy7tnmjqQHw6A1nAs7gKTYNGdBFZU6NBnaCD8UipapLqFes4f//1r5dL9UHOiF
# DATA JoKpQ0FalQI5HEazon1fZhWOV+/pnIoOKzEq0URDCnSthxXHHaT/xulAoCc5HQRxOUZX1kZYPuQ34bdisymxQth6QXFKLbIGMjQW
# DATA Kgv5ERl4W+SFqNJrc65T3/ksGutH0ahGyNzwUaNYmZtEGx58WRYgkk5/W0gFqta9541EshaHKZmVP5AWPB2vlAzRgh2W2KwoPXFZ
# DATA tWK6pHpUtSQ+l8Yzg6cwdUotyVyKC2lBNra0RATDEGjhdSJJKXyUy4NhGVUDI0xXoJ4BRBjyIcznSo8PwTURzyz2EIEVBrHLNVY4
# DATA YtyC45tnuWY7oTd410nds/8sdurveHPSIWnvVk9CkzwCy4KJiY9cVJN5sUK5DuA0tdHwZ0HMW16xYLGrdAXFwwf2aiu6KnMPgBp/
# DATA bFpFG5zCvimvVNav6OoXHkx7fRB+tLuffntOODBbg+cCgs2GaNMNk5ZatulU3LeU9lBzb1hR1zqpwi5DtjFRv+cWeLZguW/hQho8
# DATA qpj03EJ4S9BNS7MpZh6UltPKdNLBJT+EJ4XwtfdfO3mtu/faO689eG33b8i3zev11ai+wYqmOVyzEPEhkB5h4JBFUai412ge2aWC
# DATA Zo8EDCOI1TsnpcCC1q/KTQhRyWYwZzVQpHa2kPQIwc6VVA+KC1mOZNRvIn3pTJbvTWmusN+lb8zvpNbGmin11Jgtuw0jeZ65+R63
# DATA 49aY4DlFhVoFJnE9jVwJ6mLewlAFh8nSLa5cbtMFrVz+u2kP0+eq+ZbM0g1qMuvVjE93wMPYLcRMfXM0azKYs6lRscdrIYymwpZy
# DATA QAZbJwaPCERM+5QbSSR0/5Ube7dkpDwwcGGlkJvYpWzuN/EtWWvQqjrOy2ZnTMjZJFam2R0HLTPFLzKFYGw3Kl1tmvXEgw/rM4E4
# DATA DquyVlcR42XgDW+NTTOWoCume9RvdwQTA8Ck8Ac/cLz9co09pWtm/isTHNkz56RLVdjIvK6GgqaarurRggbZaWjlqzPdWo25cviK
# DATA qsSDYZLYajMk+YQqK0VO9yjxtBiuk4Q2Z8ptkr/IqUnMA4ygN2lxpyUHN5aWpigpuRd9K2vCBzrzhoYNUeqRV0wt2UI5dqOYuOSp
# DATA il4NdifD0QhR0o4kEm1MjyrBaiCZFybS6sWiz5xdFi1L4i4eIGitdKcSM/gETcDrdyuJtaVOK40byr3dSHJy8UXKUB4Y4uuCMspd
# DATA CiA2mSrqWRv0OnrcwAUueQiY2914Pel32kJdDQT9FO4sFf0B255TSQ3tkueS1cSVHkXukUcz9jQZfnUctfsYvZ19Sr2DxcwnUGQa
# DATA +92Z8514ZEjkDoC6lvhWSE9OXXtCWv1p5ht02CaTD+DFpR8biQNDC9hYB3LV2U69fHn6F6VZhWsQ61YRXB+UHN+Aco+0X9/yHesL
# DATA VO3lyic5Q2US+m2VB2LrfuBbJrn2NbE3B3LWMSAvc/3kypOKvSvubaQsF3yom7ZoziT9+8zrpM5NcPFL0DUGpmb0/KuLT4Lz38Od
# DATA Ex9xLgLvDKACpLCSB23do7r6GLXGX59/C9pKUBz/EVTG36K6/DMewG/nWpkUzUQO9u0/g1v99ilk8CDlzNXrVJhzXL8u7xb6iH6b
# DATA A1d8QzqzhZqk6GBqvfCz5ZeTEicgq2AoWnXs0iGb/0jVqLx20I5z3fgPPLHI258UhXC1LCjIrXGMmYOks3JldXw0BXa2jb8UpJFT
# DATA jL3Waoljo9UqGm+CibHV5lcKodLyE8w/qENqQCZxZ8iJAGIhrkiLGeorpRxBWs+o3yUtJ4VtkfjEZln4RlY/srGx5ouwbtAcJ+3s
# DATA yGJDFeBUhisKfJU5YdDyjGIT2ucwAct03Dc1ft7hlVFxgL3MmIRyGcNmIPrvdBTVVMIwNCjW5Dv4B96K9a0SvlUM46TgpGru0mRm
# DATA egenpWS6R1gcAAuR05c4zR3pDn80rN+23wRStLxG+fvIa2rI4bT0Lh/CV2m5LFkKn+OcqQBJNhYsgf+t8fOP0DWXq3e9RxIHp2ug
# DATA o4PyGzRQCbY/F5/1KqtpQJrbqIKpmmqQjKj3DT2sZtbScvJFk6dZp41U+5uFqWq60OFnvsnhZ8sAgE/UXQK/KVOAUvJr6mmJXQLm
# DATA fbFoLbR7tFpIAa0WMJVWK/S4nhK7SfWSVJk5fhKdzs7LAWaEyEF/HYObUXj+b3iUf06nd06DkGWFBLvym4HHZMoq5xIZRjlHEabV
# DATA hhP924vfQiNQGRlU4ZD/EmqH9iuBoMRn3BtIjIRNf4rvfoSWPJThhEyAIl0pEK99RImWQFf+j0bOcOzZc6BdtGVhm4BAC7fNGoRn
# DATA kNOAQYqnlBKpsPxfI4DrKuO/8KJ65fDv2fFfy0u3l2/dcfHfV24ufx//9R8b/7WjYd4xUUc0JgQO0u4n4r/iN8XhJJjlQW8Cqbik
# DATA kwNLe3G+GLAkarzMnthi/wQ/UvzlI8Iw++KffXzYXGZk7KM/rlNj8WvdlkrsVjKc90ypqWR5wbO83APAit7klAy4VQvy2Y5xL4T7
# DATA S2HlZ0NwoIfoabjIfCB92smj3VQrhoZDkbS7Fosa2ciKk29UV241Fa50ZzgGBFUNA4RB6NqjldK6GXAICl81YW2KQyl+0kuZAKRm
# DATA RhjGNdip39vY3dt5P7TxnUxkJ6r3qD88KITXJbar5ZksPUI8Dc/TuOExYAlqdvC4bA+STaJWx7PAedLm3oP217Z21pMJmaGmTCha
# DATA tWZJR0xyl/csnQGNu6DGAY+0K410slfPPRPqFWWNiJAk5q5JM9ukDJMNzQbdTYzUm1GcXIEftx9FZa89lOA6oCAA7fMW83bwoWBP
# DATA kCeoiXZu2P7tAeF1wVXmLM8YtcD+QgPNvgpwbohB7+8QQsrAekUKhkAAqMyQ9LGombfIJlyyU1golvSKH8bSpOm9rS2Ar3wfiXrX
# DATA douiOmTcLl9HbQwyPELb3TL6mGsX6+FhQD6kpPc/QdsAc28ZhiIufNGTdkdSrExaR2zYAQTP2giK6FuOcxmyI/O5j7dxmOGZ0Xb6
# DATA LrHBQo3SHurQzc+EsE7rjnWZkryBlfawl4zqrR2VaNZ0KSgZGy4sniX4F77sjc4wlP69bmxYLyyjQooFQ8Y/FO0AhYGg5JhSb9yR
# DATA 4cyePPbt8iEEDT9dXinduXUW+h0Toaa8LHxta3NvdWOzvgOYnfXNvS37IFGEPI8R5Tp0gFz4xfSQnk5f8MV8DB8TtptegMUUjofB
# DATA oL3hYmZBn35cxYrMaGKekJKzZFQsyhvIrCyuZcRbpFg59Ok4R7CMJywGvPRpQg0ViowjMAhV66OMpcgV4+OFBzKqrEBuO0EMybik
# DATA hqquacZwOoYDj0JE6kGKOYCezXnnHiXPI3ItUwHjoQ9NzjtGdmJM8Xhe8MHZoIcJewHAHxbz4zMvsKDetB6Vv9/yY6ZMcWKTPTjW
# DATA yRwq2Wg8nBpPHDYqC413lBKNtEEGh+vYDg81JVrR62RNM5UyjkQq0VQDZuJoU5AOmGcHgEzirKGnitco4zrAZU7bw7gic6GGA1MJ
# DATA nIQgxLwsLHm3J4ViFlZi3pQpBV/OFDPWlGaGfO/hcaL88tLSUrGYDZ+YPUFb74kjxJ8r2ef9myM3cTEnyDsxu4YtBzYtV0MO0xUC
# DATA ATqEnblSBlWxMDNZci71rE+GWVi4X7+3ukayJaU5333J51/eI1BiKLC9AwN1UUy1gBR4KCnZ5XRm1xynVXImJEDwdDTCy/KMTqT1
# DATA lLZCag9twNqZPZ033LSosCiOIkNZ0xpHQuyDu4J0jahKd0TpNJHtgVdMSvcaL0D5h82AKEgP/Hd8x5SNF6O9wJyMZ2ZWW9q1w4BD
# DATA yMhUlyPCWSmwWqYxjzCjpUTB4c0aXsYMwzA8ddLSouVA4HFRmXIK0hpMRwc5qVTFdqhTMZkox1NAHWl5VFHucfWiF5SXfDm5zMXk
# DATA qi8lbij8ofbXsYR5Y6OQz5rp07PRNTCs0oCfPFMkqsqBMWCTs/72itMLPzyPlgWSDjqzuqf2ALXc65p4XPrXYr5IdS+Pz+d7domI
# DATA dJODOopJPCzs/Zki48McO5syT1dm3TgSt405bhr5bxmWn3cjmY9mzttH8uYBc2p8dfgZ5RWg24QfcPsyVwnDO1xpGceFmZcL596Z
# DATA 42rxgteKS10p8l4ncl4lru4akXk5uII7xvz3ixS/P00eCzlvIvlvIR6UEBNJQl85MP+Fq5vWjlziR8FK0wR38H2LuvGaEsdQlTlD
# DATA rjy7WgiLkppe2WWNakHyWeSKZCrWNhlSS4Kr7r4prWnNVC65z8EZYflE+kNh/tEs8QKp6cHGvZ3VvY2tzdbu1sOdtXpoBdpK7yQO
# DATA PxoRxI1m6mJtdXl65K6Xye1HkGaDYKEsoyWeblC51qNzSdssyA8TlP5KLQfXTpkA3E4q/duDjd0Hq3tr7yQtiKBb5/YFX0bipgNG
# DATA ulzR6hAibP7Vdx+UjKWHNmoJSBZoQd4T0dWOrS+ybdSBtrRpxsI6SmZ0o5fM1OgpgtAKSkG4SnmEVrrVrtv0NGPVSXkZ6xwG7liq
# DATA CRnHsUBl1zlzN0DiNjIi13fq62E6bmmeS5OLhJNn1nbrO+9uqF34KgoUcSDOfzR7lQkZSlq+6DSPIQ5OTEFwMB4+jlF5PZpO4spC
# DATA QrJpeCKXrvs2TjORTtKnYZ2dmfoSJnxXIEg5q6QWRjyQOfMYoLklZHIgAtoSSaTVNBAP46KpR5IT2VZn3GvwfsKesmAlvxNki7kB
# DATA OFfAQlJSScMVMSa55uSMdV3rATSPvjTN44H7immdsyhy9cHdjXsPtx7u0pLsre7cq++F8+UINMauEwUuyUD4BO9ycm2h4EBVhBii
# DATA V/WE6ClPAG1F4kd49ztTPjJTEISFKMDtDaYnB0qdgRZr5CMBA6MxBhu0/qaCFZGI4KNoDDgKMWIKIeIYbkqMYgONkTJbg8cRZttW
# DATA Ijn2gNvOrZX4T6KMsCyBV6GNMLZVwq5oNMZMPldAGMyQCcpWEbKqBNSedEZGKVi1A8iXOTjSsL3bYvnE/Rv3Fiwu9IgLQaf4Y8zQ
# DATA wZZhTjRW0gXA+0t3OgOcElo0IUA5u0hTAn72Dg8jVM9sbOvaTyDgEsA6gzb2sxJs4gkhxDmg4/bAcFeEHKERwBV6mYQjQzr7W2tf
# DATA Ett7JiqeoYFIb2CW+kAKpNbtgrkIn5GO0GH8iB6eNVUyKTroYmYPjVdTeRhX8FT5PLJOQDk8OptP15oIdcKkd8nAs7Rr/kxAKqUD
# DATA mK31OLsaAfrVYE/wSbUgsMHIyUfyVbl8cF49ipD1juPj3ggQawcEdyQvWl3Gn0xYlnynhTmr3jNDF/CdHDmxvpLGA0+Gd4ijaEM8
# DATA b2syRGoxSCGnmUBviksgjS6k4Hgq2w8beyqu9Uclf/enpE9LaF8jPy3jyXDs2CpVX16Z077kVuXI2RoRPB1kNMWzsFjM4nVeQZQZ
# DATA pqTuImQXvoR3HVGeB3J/FjA+P7RhdpKZzcysEkTB9NiMDqVHBfpD2VGpV2auZDsmKY8/MUD2IJ+GvFHk7Wv6Jr6AuKdHIcU86Qhn
# DATA uO6aZ5SURJJrmRVm797jXPQXBpqkVjK2bU4ryAuZ2rjRS0T5E8gMW8DpKmU6dbqWIelhnjxck5eexCU9kaZUSrPwPLGFkmHm5Fdr
# DATA uL4al66UPtArvoa1GCadI0pokvX48s468qWXqOFsljBuaCgGi1htlBiux4s9Y0i4iZdQtWY4eaYjK2BqXV2QH4OHiMx8bI+ezxxv
# DATA j2afPDP9SXJ5kehRllSHwumg/ajd67cPCGQlTNNHX8l1Ml1NTf3C5InUwZCDs8Wjg+Gwb/qnqytJRn0UvVylcTaq4oLXdPzXsVbd
# DATA Tf1TVrXa/yeV7M88IKnqFt3unjIkjAJZXpGYJgDWwDl38Yg4GQp+Nxz0OpiVm8sTZNcxAFomCv1IVeED0fJvl7m3iu3nb98OHc/+
# DATA nQgNvPr35IYpamljrEsDIdnIFYn3M3Ym1OaglXih8VOGZNWT7Ie97zO6YSN3ZLFjjQUqoTAy1aur6+8rHyE+VS0Ftgon1zprHWGu
# DATA hTvEOTDhtSPjkeRm/aG4TufXV29t18kaYqut8+nZNdqD1WPZ25QeUcBylmQCqA+2cOJIJE27QQzCp/YkMgQ2ihWIwx7Fm+WlJYU4
# DATA 0Rn2h2NPtaad2CC5rL6qXjBYhUK38PRRLpjU+RSTolZyNl+p8YqbgpbkSpKqVNCFeUobqr6JuLGQpg80eHJ1FbgpGm0nEIoC6Iq9
# DATA iSjH6kCAogITYjQCjQ9mLpXKvlnywZ8tBqwN/aoxTH2orqZRxXPlkoVn2lnYzAHagt2NzXsSvhU190rfZ5Iiq7u2MI4RLFfddh+M
# DATA RCx+gmkQESVxnTisJa4EUqs7OW5PDL0CLD3XiDGjQAWkkjgCVRjqGSaPh2VJEDqjo7S1tGUyHCSJCuNadrunCNWcqiuAu9KaLEai
# DATA iuhViyDOagCCKX4LpbxKK2ANiULZ1KXcDi40RAA6biKV4T5Gfv40YdnmFm1XGXRvkr30hBNav2lVAG0bR2wyr9RiP9FGq7mXUHE1
# DATA DJ7uD2g3Y3ZenpPEfbJ6c2l5aX9wZmYdPxmKSyklV6LBNnhYTerKI0H+J9bc4YYExT0nKDJ9ZUuYrY9deakCQG7hExF0rGFqAiIu
# DATA zyA0+AaBAvKE2bUiuXO9i9Gks4jlFjWBkIoOyIGGWDRTxCiq0Z/BdYWGZS+hhj/GYGLBu2oyDTA0LtdFs1tVo1zyKyEyTQm806Vw
# DATA zgU08g3YMdo6pZxkDLI98lsmMoughrhF6c7Pik6WLH7TusxgbqT2ifSGMhmXJ3t3Cgd7Z3W3tV7frm+u1zf3JD+T2pwckNFpGeop
# DATA N70RNVj2ox37s9TPgVWs7qpzwBC7cMNNHaWKy6WXqmpof+t8jEKOsGm7z+hYdJwDNqTg3kNx5xQXuDfZY0mekoGYIdNf/VU7g0fA
# DATA EkRwApnKSLkSwzVAMPL2IDAmEc9hrTRWfAJ63cQb4KFymmoYeYjMdYBZh2qaqdVIgQZqCQfDcH6EZQ3rk/1a/vKz4ZhT37QBmW3I
# DATA NTp3U0Ny86kBLxHbSw7/7X6LOuBG5BrdKpIFR31XHopOHiVVowq0Twnx1eG9WdXp++pToIqqGZvL+0wH5UKJs6Jv/5yxPxighnYt
# DATA WOv/eIjbVBLJDXmr2THmEnSgTgoGepEf1MvBxU3ZHRmkLHFzMWloqDJ4Ry121HKR+9Q6qFgN8vzqtidRggi93fH5k5l8VwMecq0J
# DATA Y1xi0b1a7OT08/34euIonLMeSl+F1wcMGU9WyCd3Doo30615qL+Yy/C4U3+wJe7uqFVY29p8e2PnQd0B37A3d9VxHaf9bp/R9huO
# DATA EvTQLwf5vMMxW2UCKaNpbWUlv0rbJqe5zISgcHukXkbxWxrC5VPOnXkUpfSRjOs5mzI6p1lDMR0A1CgvWU4xM7GKM30Jf+aUreGN
# DATA lVVZYy2hBUAjnftUKOTicVs9KKbG1XKNHlJK9h2y14IsgYRtUrjxMxiEkkJu0zvroPfIIubkQa6PKvY6TcNKNc7IksGVTOAKAktR
# DATA CJqo5ZbngNQXs3rfg6sKQTvEQP3cfBbeqncvmyxknqmYsb9d+WKOVqx5dOpxAYJTRBNPE0ap6YAu2onYDbrM2OgFHEiUMHh5I6ky
# DATA R8kj5XwTaHVwbNTpPlf+SIyZiq35oXEzQzJM2NxsyFyYSRcm1wwl0FSvLCKgS+zmdDqVR7/BKauJtF+KMVbl2zY0UhoYh5aIc0rj
# DATA tteUK5crEn1BBDDT5z8pqhftdljRZOLJS693WY0RB+BD2FGQV1YZU2mh5XXTNZSyRZlRx2lrWWJOrRXK2+04ZsdRSRAMFogXno74
# DATA DjMtvqM+B/EEO9I4EItl0Nm0lTo5wz85EVOb8MjJ5ZdRnHdhXddsmW2Lba5WcEe+XSHjvwPTlVl0G6K/QzcUhBzHBo80nVhHDP9i
# DATA zQM8o4gwiL+Kez+Pgr8M7ty+ffPOPN7o9c13DVlIO6WCJ0cPFNH9wjj8W08YeK1ghAaUmzf2K9nfiz+gjCZZ+jqIJak8SCAmKYfN
# DATA muWwaS6T46BpH16UMY3oWuYDW3u4u9fafXh3d21nYxtDhHbqD3frPDZQh1DVgnHsD5RF78XCYcju6YTAmPHsHJdkyex28aKWiuWj
# DATA ZHrn/7RmmhyqRVpGfy46r10ly8bOEBMaSNO8wGROtLU70VJhmOjdgPGijOGiC4kOtWNvX9fnj4JfXyyKOt8tMyVALmVukogc3JmG
# DATA 7EizwR1oOhCU9k6wwqByImnMGIm4I2/W13gj//XDjR33tpzWh4TzASxNNw9Yh63vnztrIb3mzVmYKfBpye/6U3HVqqo+48XLk0jL
# DATA vjGmoId4c7icnWXkVEtdVEjmnGPjJJzH5GQJgSMaT1rMa1vMWONkZDKxi9ILJBt0rTnpE58wD7jM5iz5cvJIaDABNY1cPMpDwHUm
# DATA k/PxkCbiXaoNid6DDZ9MWu15jzfL+tZ7m2Ljr9dbd+9vrf2kvi5mS5x0IKxjreA/D6Zj/LLg0rkvt6f+PS27ZwrFJOlCp9WTh7v7
# DATA nqdoZgo/OgZ1YT4IiukZ4ubyBERpzNzNNEHFkjsU1U0jxRwfsJfJGZhWuy9zJN1seVBoP82XaCqPPe/PyIaXvbtzbOKXYdW6vJVq
# DATA bntYllXrJWUlfBXOYsp4GkdiFcWH/umbeOkzwolkNEwcQXw2/Trs96G9gBwKKgv/6W0+PovW1dkSr946eEnr5NXYEq3j/8ptX8mj
# DATA 9/r1wtPQNYVJpOxZpxOyzKRQo69c4Jwxy6KWP1vl5W1vl7ArZFrKXnoeL69T5KzEk6ZT5Hz2q/ntYi9irslttEhm1ctQvydDKpIG
# DATA BMteZv+WZYDjypVhDevJ/3qasXCuCU8xMRpw8i9gPLucGUlmCuRWnIzLmXn3rsI+dNmcfN/bljJsS991wsJURmfmKyS6mo5tDaMj
# DATA 6OvYvxQUTyqVit/D4RfSO8TVUhbc5oo6/tBwO/fZDpI3EgSDUDpScomtkVPK8MlpLZTAJuFs5JKccCWMS+HDpFi4qjtjrqnnkEjL
# DATA kGHDyOSIOgZGbM9DpT3oHA/Hs5041zd26muAYIE+JPUH23vv6zjKnoQHmMOWYVlllFQnISWMwQiRHwHiigYoK7bzAn1GWwk47aoY
# DATA GUU6ygc3XyjMztZPjUqJJI3wdhmr7A8ctvtS017tcqRufWkD3XqwupFQVaLdOj+CK2nSe/0J3ZP6EDtdExVUGE9aXjx5FdGqIVdU
# DATA xvmiRc1YIgYeTd7CyM8cu9OPr7oXmSsn0RfEyv2VoI5W/acbu3u7YWIrkuqGWU266oXYn6V36R1aw09Suenxu6pjasYR88SgPe4c
# DATA 9x5FfLPlutDtNhgOOtGbMgG9oU57NZgOEDgh0i32IGtMe8BxGBEYUyhxzMEYtr128uX20lQyqmNzulgbVefS0STYQjZIgvME2J4J
# DATA HeGp5rLIWi5SBZ4TctIW5RV+ajmD6fLZQy8RHFdr+IExE/rlzrF4sYDvFTMwwK1UbqIIHx1af+9R1NeOJ5NRdVEDvVdvLlGom68w
# DATA LLPcBpWxhgn26ZCSFuqS2W8LkOapHb9rRCdWwbNK0HxcBr/MUUTBmUJMRfVJNWhY7iCqqaKjeA9HiAskyh+GyyuvV5bE/y1Xn8LT
# DATA MwyRcTX1xHTgjacOWASJW+XxsJ/mXuLWNDw6osDmp2F33MN0xGSkLEsd0HAk9YdPw5P2kzKY3qHQ8tIJ6SCflHm84c3wzG2AYk47
# DATA x1HnA6xhIuYOhhquPVhH6VJQHfJU/O9hBEgK13jd9WTALCyisVXIyotU57ViRXCfQWFc+0sZbo4pUceV4QdvLVWXi8VKB4EZCkWn
# DATA hPiJkRNEhUKiga7fRibPgc36geBtwKXEg+UVCkYdT1qjaNwbgidduLIUh2dnaYcrzHhDLpa4xs0E9oCrHX20LdRPZZB7womIliW5
# DATA zhQdr7vGx4HbN34sgyUYgkGlzrbUJmR/tt54qt4QvThTb0GXIHsOLJb2N+QhcAW6a65skaastTaSjquSYvbl4s6KiQEaBnYZeWYx
# DATA AXpYXRHSyag3iMIc/EDZOmFi7m2t1+8+vAeFT8TM9eDKNumMakshTqBkBeEbS9U3kNfdunWzKv5nfFycdkdIwDIYzsdq9AyhO1jV
# DATA F5RWHQ+VOFmGCNjqIvxXP6NJqS6yCthyXKfpkl2gSdI1SYow68FnZ7PYMclRZSlHiXuCq9l/OZ53DuOyXYuriKNSSBKJY712AwCS
# DATA 6+IZXtFCq6APZy+A0JPqDGgq0zL1oKkq/xzK0+5sZYK8l9lqTa8OKrc57MwNaiJQURtNjoGeMW95lQ/5cYx4QjKfb2V1fDSF3bqN
# DATA vxQk6h3oClotsXqtVtF4syLou9XmVwqhCm4HmiXA5VojVKr0skaAJnwW9OwPCcVnwvcdVmJo08t0HCmWXJ6O+/wLXwTKgEmOhxdI
# DATA VOrYVq6UeEsR9MLIEXiJLHO8KjKvaRyVge/ob1QTiUUu3IE8BX1wDc2MmSmXgXxFaQjArW2j9kv6vhiCpelfb/sOhSjMI2hgaq5d
# DATA a4rs+dAjlmPtndgZSKmqJ1gnG1RocGQ7MXEe/AMECVR7HYtfYrTmY1n8A6VjDTYF3yo2joKXUlyACXRY605PRnHBiy2O9ZJyAz8a
# DATA UOb43eST0SAW5NVqx51ej9GlWYzvZ/UwCi2dL9rbsTDp18QKoBeYfk4+uRg3fQUOTvJKatqvaoHTg5Kt6AI3TFRauf0pqrVQrzrG
# DATA Oz31EiN+1hTzVQE/K+McvZTqL+kZ1Iy1wG2dQR0S+0v19jIL7vKMjPZc3GZ3lgxVG80360Uu0SuDbWV0yIAKdvsCDy/fsOaQJnaJ
# DATA 3/k85yzwN4MwM/shubs7eqm2nq9VY9Og/tXtiuHGrLRYxkSCsiPEq6qH/lk+hyKhbpwgDgyNePZw5aFoJE1mXX9iYdFfs5t3I2Y3
# DATA qw/gqiP6gtUiu+n5GdGsrlgnfgI/X/lBp3SrmL5PyLOSstpDOJvlQuk9bItnl9g7+nhOYiYlTBLJUajplNaJxlIzu0FDBEi7Vhrk
# DATA Ll3mr2K1tPjlDlUDGqWtk6zZNJJLcK1sktNwW0LUFR1rocWo1cIutVqwD1st7hGscdw7GkwRU7EAH9v9yu7Gvb36zoNSoL+/83Db
# DATA zDFPz+lPgSooBZyF5XpL3MROtZol6fpCsvfCpf0+SVzYPY0FrdahFe3FCcqV4aNoNI4Oe08yXD9tlF4rQ6/CM8yVE9PTPXEVjjEZ
# DATA ugv0nC7ViB6d/3Nw/qeLX5x/fv6H82/Ef78MLj66+Fg8eCa+Pr/4v88/D+D5xcei2Pm355+df3X+9cVvLv5RFIXffxucfwW/PMOX
# DATA vz5/XgnO/39R5pmo7vnFx/D2s/PPoP6Lj6xyAfw/NPz8/NPzZ6LkNxe/gsb/XhT58vzrYHV7oyyefivqgpaevQn9+uTin6Ai8fxT
# DATA 8fk34tsz0QOnw8+ww6L+8y/O/4gvYwUV95ZN6tvVtbX67m7r7dWN+zwh/ybq+lZ06nPx9yuoLde4udE/4ctfivLUaGBWd/FrnJF3
# DATA 9va2d8t6XkqBKP4tjuITUeU3/PnX4jm99pFo8Df+2XsGsxeYE+VMx8Wv5AD+JL5+JErBEv2LmDgqBp39SnXfmrOLXyXmDL3VW2+L
# DATA uWo9gLCeu2Ar2nh3da+OU/c/UxYPByj6/Qf4Kpf9G5gB8RAo7xmMlwwsODjoBD4yBrl0Z2lJdP3/k9XKGcfvz0THxYgTHZa2SN1x
# DATA 7KhDot+e/+7iV2JtiQbnIcsAu4eThpP5R+7V73C8n4uPy3eCn/TupnZMhwZ4+pW2dX4nPnwB/fxElHtewl+x+a+BMJ/L7894GpEA
# DATA qwGotuPqIrsbRk/aJ6M+OgImOocUyl2zmMX/Qy2IXglS/T0Qj90zbOxzMZufYMMficJYl1g3fvVrXq6vL34NlO5WgDT6JxzJr8+/
# DATA ENV8iTPRnk6GZi/P0pmyZIPoPaU5tJAfzv9V1AzL9ExwiecJxuHZKbyYXyAFwk78Zca2Fh//e3D+B7Emv0Da/hpX4itR6htBPs/P
# DATA f4+/UNu/AXYm6voKl1dSmeBqvxJVii7Ar+I3QZQfV+DQ+Ivv//2Z/pv0hSB0+nLbWBL/7ty6hX/FP+fvysqt5TvyGT9/fXnlzl8E
# DATA S9/FBExB/yaa/D90/a9du7YWjScUih0F7KQEojjnldXGb1IwRo+DHWmJk45eFCaBQdu9E7zUSpWw/E4VkUJPPoNLlPw8jBcwjghM
# DATA Ov3eQcCP4YYhi4xVZVquVE9O1UfBR0dwyVigCllElhXShbpkGbZa9DAuBXitYU23uA8M4rhfuA63gxKCnHJY7mG714fLG3PqWijE
# DATA kc+BUQqG9wtkipIhbtfFbQDYr2C8zy/+nlku8GtmmCyUgcSAp8e3UFAcjyS3WYLcc+S4oomPoSpR6is835+FLjK9IXWLwRcaIY8E
# DATA /BBhLJDIEVKj1WBI4sbWHk1gNMPpBB6SxVGhWt823F4QR5yMA51hNyuLnDNDHiTtCmFcSWdGTYGtUbs3LhwP4wnDeeifSpQ8yFy6
# DATA uBYqf0DyvpJvstFFvA2+ab1HFCGEN1ajyiLrbETFBmI+XuqsV+0Ye3Bi6yBeojieRxQ1id/D/cH+eH8pnKmnpVsLSj9AJHxOSyFT
# DATA yBUBSnQgQYJMzTKkEEDw0vD84h+AGEDK/BRfEVSSzDM9MpAkYFRJCIDlpZVbwXX8M7PD/56kPZYPmIJV50EOkZ0XYytL2RPFueem
# DATA fCkEj1+ChBk86N1Vqf52onYXPaGCeOiyI1j66O+m4B4DzuHgQjuNGbNWohiDAQRoqKIIoEWELtYYP4EXp3hK+omDU9D6F9VCW08p
# DATA mIX5QPjk9tIP0SI3GIKfA3xC34xogHaVN+7cQgcbZBSqWTmqLVHL7u59GW0SB13MWIWYpr0YMQnAV2jCuPlvim0CuiKxkIOfR+Oh
# DATA zGpAwSVcnnasSlh1EHaHUUz4Bua2CaUj5MyRwN4R3/Tms8eSM9jYROVJcEovGYHY+BmwRaAiR0D/PewFoC261j3Ldt28ivoVH4B5
# DATA wF3uOSsKFhfSc4YGEes3GbRrG32ucq1efJ3mWCv7IgyXIRDz6bIJ991P4ZQyZlRwA/HkGd6DniUuKDk45XfSC04oRbJE3CcSAPEB
# DATA rIKW/MDf6Yj8ubRyvRrAOkkYhjg4GE6Og53dVdyw9bX13dU3xQHFKXJOwEUQfz0Zdqf9HmLmGOxqND3o9zqAaJwgAvGTYGMWPfj4
# DATA DTMzT00j+br4SdLTqA2pTsgGHMdVWafkl9rh2OjcKzWnkcxd+W8JhYQ+N+A4EMvwrZB9PkZh52OpIEOtnU/oufhE+mGCzdY7UXq3
# DATA oHm9S64CzlxVuhEIMoVEKiNRVwWLwSK3JsNWLAoOunEBG5TJwWqUHGy5CaknJWFUBsPHBUkblemkU6zAN9GLk1FhBu9Cee+rAJVv
# DATA X9Is8D3fJ/jBhf2f4Mr+Dek4n138I+olPrr4rZ0FyXMGqiCS0elsgcswf6XJXvpYvZwYx8sZgT1LYog4QR2LIdQRKzwko3BuBKfz
# DATA /0FThyLT77FTsSN7IUdRspchZCl9j5jgjwQNf42qkS/DRNc9PsE+L2DjhYQfMMwZ0HUhhBxZnWNx4lRG0QkZkXqPIGEnfGUBpd/V
# DATA +ahMHxCsxTChUB5K2eoi/GzBnsyVp/j8f6HG63M8XD+3BD0QAG151hQJ3TkVr/8RLzdqVlFONORZMUCJkD6y5DPqdTJq2GM7sfEB
# DATA QYAUE/RzsedxkogzOGNuT4YnvQ635U6cqscyiLANJH+zYmhu2GnWKhmIhVhXnBI1N5KBbJzFyia99FDSxLBHzjjdKDS7MDomyfIy
# DATA GZJMfEqogpAUiS/oYp+A0nMEe7yG0XfkOo8wxIe9J7WwMunH5dCzmgiXPIwrh13g/AWzkfDxQYjWJcHSo/aJmzULnrH1MjEwo8Rh
# DATA fxofO2GA0F58OugUZBkxhsGwYERzD2Plk0+LjkHutC8hUrFvDAG5G0qMqWvFPFrB5sWFk2hyPOyWGAfBQeAzU5RTASu6TGYiN26E
# DATA 8CR5Kbxz841bnp+BnwX/LVgaLr3+ehaPXd/cNftcFbxAHOV/UBYP4+oH3HRjc0MxjgANBdJggmzhjrhTOZhjpiqpQkgr7G+oIcUk
# DATA hpr5KrEOOOkHR4Ww0R3Ezf1BeAOHabhoyPWK+piRGpJgKN9V8Y5y1IvGJ70Jhd4XnsIvrU5/OO0e9ttg1x/1yPQdImAArRu5IqhC
# DATA nPCH3j3qDOk1fkstXcqrMgUE9ZMSTridiE44yZGncyAGGokozNEY1Sp5yGgJJD9V2ki2/Qh9UsSMAovjL2P+ovJ3UCUVTDgxK7/E
# DATA +T8DcSjrLVGROC4u/oEE+K/R2ovnz+/YCvINX+gEDZaV+uwZmTOhSOggw5lwf3KsDM+TW6T4FyTpz8+/EI2B2eojbYX7BA88YzNY
# DATA 7TO7u0wIkcV2qTYI0a38bNgbFA7Dpx+cgRH9EXjpkz9KyZp+md2jgrCKmHuXeQ14nBtSG1JQKZBsJ4cg6FPC2VQMpjDbAxJbMQJA
# DATA jcSg49CAhqzc2C83b/xYP6mY4JHNpyslSByKtc0WX9JUtrRpNE8/FpwBnZxDDpCg3oY38O+NEGMhkOrlQMw0sbja/Vijg9pnrq48
# DATA UVx+XHzUHi/2ewc6FfCieLxoyYVphQxZUeYJUlyUmr4hV+oGBoCEN8RrN8JkHIgdRmbkHXK1HcbYRM0xqaPza08cR7HgRg1Zyg3g
# DATA YkTdWG0xb3fLMxMnGZ5M5l3DDJKRvvG0R+A2N5apfsRGwNp1ij4PCes8Ku3OSVRuEPE2GwrxFKCCuMLZvMYhWsF10O/hj3BP/BiZ
# DATA 3R8tZsd9IrGAOpuML9cabSyRqdGeYzMpHogm6M/wivo8WF17UFfq3hgt3+IwG0UdcUEUi0g6kydRZxeT2vzddAhOjgHoTLro8NiZ
# DATA kG4mPo76ffk76U+EINge0SmGA9Exkvv7QEP74l9oRE5eo4fXzGevwbPXXuMeGvRByam4w/w3LC5KWrgRyiBCO0Fq2Hg46E2ErLFu
# DATA hEPsRLYhbe/+rnlH3h+sHgpZpsYRX+UhiIgRu9kFHC7Nre0P3mvDaeEti7zJ6gzH5Yj+7EE0gRCS4uOhKPfwQTv+oLYkpLv9gZr9
# DATA 2jXB6GhOb4TX9kFJxAfVnVu3LjFBuHlyTY+cGGNSxL4Sk9buw5gae1CTeGtrsNYWcni3Pa5dL4v/C5ZulpZvV5eWqsCnrKHvCMIS
# DATA 5+bPo+561G+f7kad2s07UGoblPIxXAZqE3HGYv0bZNls0uxG3bunNex8rCbWmQtPfMylQmNyRcVILAkKZxmhSs+UMxTQAQZhAL4J
# DATA qfcmxypWcywlWcNhtWHEc5haafGV9YaWQyud6hjNQpnerFiRmKECVegYfMRBm7kuRslQkBvKGpf8Ucq0HDxZk5mVkyUtzj8d46S4
# DATA b4HSauSPL3F8UtWEG77MrrarXZHW5XbF0ne1K6jxatuR3NAn0xE24bM8OrU8p6WqbnYzpr/6fG0aJGQ0bdxA2xUpDIqa+Rbarpgi
# DATA tL9iJzyVBE1zJCxqmvVfehhE3lUrMS/Mmzq0xUc6CX3ewgwmaUBbk59zhWAVk3fFFJLhfWdLoq8GP4miEVoqJX5RII9ivHFDTu9B
# DATA pz8FtPMAPDMOhpMwDvqARsAXkriSzJLeCCd9GUnK27JqTKa1mynikwdlGsMrWigo8pa3ysK+NMvY6TLpIOBpskAo/comEnSNJMyT
# DATA fuzJ587yC/gpEWCbMRKUXaxfoc8+jCevzELmhW8v/oGujxf/nRwz8IKJxnm4YIqT2UkBRL7oosmG1Zlm8U3zJ+hJM4cv+QwXb7+P
# DATA NRzdCXdrSzFyKRdssL7/jABLMIErq8hIJBMvP+rBdcXgBzrloEQgiYL+8Kji+O2H5/9qOLaIGa2KC5Th3IiQfDr3aER91yNn3W5o
# DATA usSw1yK62GxsbpS0Q4X4fza3Q9guDKRmpFJL97xc/j/RT3F6+Lh1NG2Puy/RCzDb/2955fadFdv/b3np5vLS9/5/35H/314Etu32
# DATA uNcHwIcYDC2QN5RxiB6+/Z6QYjGbLh9HJdK/9waUdBYsEWNKMH2a5QJ42BlM+nP4+8XH00lPvUBBM/N5APJ3wC6SCi502KEwrxl+
# DATA c+T25/eOE4e/4yh363a210U0eFR7ev36MJZJAsT5en+ttXof/ebXDIXvTD+7HfJoNM4x8BH7jKyaFx/BbVuHQTyXNjeMyRD//S08
# DATA FK+IZX0z8PDTQyF0PQacqvNPwUcGgwo+ufhNONOHT8xZyzgOZT4QCUF43EMzpTHJ22i7sdC1bKRftl7Dm5XHbcGg5WTfvrWUB1CT
# DATA 3pyAsnoAPSqmJxTwNLK8lIDZNzq/R6XqT0Y2Wp2u7INev+8CSepWssxptiGNbplawSTtOKna6SR9ZOunwRSL1tePUYcO5PC1ihIS
# DATA ZKIt3C9gyRPHjNeSB0Y1Mn+b9eOI81n7/msZ+8bRwXA4aUl2WhDTVmIVWWcirkdikwmJZtgXkkyNVS4J1W8Z5lrWABLQdNCb1FIV
# DATA NIkXER9Wq7I05VG7V0J7X1l+GDkpkNvP5V5x0h5/gJp1eomgXwgxI2TN4x6i5YnpLqOD18+GB2KDi0EDNt9o+Fi81B/GMUxfv/dB
# DATA JBWV4i42GbcHcQ+OPbxYuppHMYsvrnZkTgBLV0pTkeFC4SZ0Tm/RDTFrUocI/VGqQlMhFkCeim6PsrJOjuvoR1GT6T1oBouU1mp/
# DATA kKo3tGs0NYcAKsezIiq5FnDOXHEWtg/6kaFl3B7Gk9riNB4vHvQGi+OToHwYJLphNZOmokNYqPIULkCGms7QVqJHvLGhQkqhLsge
# DATA rvpSJZYoRV0OaS9VMM+5tU7US0gbgUKTbFX68/BRRpG+VSbOGawAhfKoKw/IUkCRy6JrHIYQiekT93D+9vi41zmukcxUwS8lKZWZ
# DATA icPE64QsiNmnSBrioxRrEz/KTwDCaJ/phBN8+FgUwhYKofhimxnEg8QJzhXaRz07NNdorpHPSbicZtIfD3+ooCtfDMcBJSKZxpBX
# DATA nKbcslBktMv9zKjRU5+Pt/27T6Rix6dvOST5M/aREjztTSk9GzF5f6KA4PNveA6lLURNLz8oizmyigiidAuJR/ZKyMpYQ6JKzRgW
# DATA hzk6XFs6Sn+KwyLRUj0Ex003upjmQjl+JAfS7cXt8UkL+C94UDCpItHZZ2DRdwgyZLXYjAFq2jxHnxe7lFn/quAxsn6ZSg5kC9C5
# DATA gQpDCsGVYDUAOU5wMImSOgbUVfTjBVVFP+ixA77BMrou5G1n2O8zylK5jKcx9o14e7ks2A/RXA1xITWjE7/hCQNpRUaCek5rq53O
# DATA dNzuoO1iGbRltHF0NnLJqZpFb+oMudOMF2AhjDdm7Z+EbGNoNLGz4t53Iubr8XE0YLB5Dh5r9/qG5tLfGbv3pkk1g0vk3MVpJK+3
# DATA LbqFsxfyL8TmfQ4xsJ/atH3++ZsB+SehT/OX0gKbKsIgP+Af5MNvoQowk4JTNHpAWmC0amcUivZ8mUcSA4jhHgCYOmXTeelAbTnh
# DATA yLzvMi2FcIcQF+ya6tFOHWCu1+s7uRDAuBoaUlzhr43lalMBUsln1eUmqF0BZT9skh7R/N1kmbJWZpkULMbVLDUds/ks0Vc7vT07
# DATA /x06uAMVJS3jXyktfzHhxhcuimV3BHTwIaj0h50PEvcycIRHHJMB3yDFt63W2k59dS/4kL7srL+3Iz9vbr29df/+1nuWpELo/UJs
# DATA HE9HgIcjQUoOx3B7cRxbESvfQUDZ2NwzAVCyAVGSoCgyDYB+o7Vxb9NV2v4kOj0YCvFoQ/a0UMzGZZmrV36YFmNW2PA9+1oKy2TM
# DATA GSjAxG1TPCzAf0r8BNBVWvWfZmimE7KgRiV7cQtDYjIzEGNCJcSggCP+h+Gsb6bzv28REuHiHzDihnilXxsV2mYPczsZho/57BkZ
# DATA iDd+k4PZqjI6mLYLDOb9J1Sr/SpVh+YZoJQowj83GwMlqim3j8AV8SWZADL1/8tLt+/cuunq/19f+j7+/zv59+or6uINGchHp5Pj
# DATA 4eDmwrVr1+5z6nbIBERUIp3UKrBPONU7pXHHDAeICQd5DcbD6dExSoRKas5tGDhux2AQUF9P2h2yFAD6C+ox4MihH0HvC/AsOxAT
# DATA HE/eEayxfxXwAkKEVJ/B1WpCzaYbH4BnWNYGbGw67ou2KmPqnWyTO1uCn+HgWFAdIN5jtKIdHhCg2PsLY54vUHZyNKizvb6Frv5C
# DATA kjNyJCys3d+AGxOueR8WmFQuUsIIF9a2NveEIFbfAcCtvZ2t+1jcFkNAmToe9sOF3frOuxtrdfsOxkh1SDFKjbjwcHNjr7WztbWn
# DATA ZRufs9jC9sMdSOEBiUhT6iw/WhYt763eq+9iiBRqMTi7S3f4eICKHIyUoiSTjEVLWS9CTu15yi+AM0dvIJaSkWt7h/KXjiDngXih
# DATA uPBg9aet+1v3Wnff38MmjbB5pbalFFLj4ZGY65iz44zlSguCAiBFRLMvBdEjHR4jdsU2hE/Gx8EBmNjEPhLzMKIycYmze0i5VIrR
# DATA MV6T248DJkMZCQ57jO5vRHE1UGq2epDxER+wMoqu3HaCDSuPKnq4wPZRsNm84ousNjHSCbJ2hl04RHsyi7nshNQ/6EJpChujvqNI
# DATA BkLzQotacE50Uh/OoUWrTmDycMWMuknNzUOkm2R2n3s79d1dW+x2Bkw5UuS6okpBjsvJuTkYgloMI0DhPwXP/VtWY82wthqw5APw
# DATA 55vDydtADk40mVHB0xBnCf1zKLMG/kV1atRdBaBv0SO4USMlAZw6IqUzlEts4MmLffKoN0RdnGygwbU3FXoBvCSYhdhSEaahAR4k
# DATA CDWW2hBADySvJkGwYD7UvlCw8R4L+TJWSAW0phUwID8pYEsQQWs9lZ0qJkffMEbRbMiC4Pp00n5SWCrhUpTdseiZaRYTVVaIs1Bf
# DATA ajyj9ms1USu9iNsY1xCc0iBEYf/J0lJ5/8ny4f6T1w/Fhx8eNjllGpYtijvoylJzwR4ELwz0u+B5eiNoPA3beh2xJsDSJyZCBcV3
# DATA /HvWLDbKK7eqbhuchXCVssyLihZ8mfswpyG/4/NppVpc7kb+XVWH4SR5ge0Yj+USmlp/qlfvfpm9QR2eZ2xU+4ah7hSmh5X0piqm
# DATA 99G/05FsxXOHip39pLQXo37E0VZ6wkbHiJXO3p9cJOQJhlOeEnSrjtisN8lVE1ZuSDkAvuGZLJ4PWTE00VzsZo5FHYHcfnBIc5XW
# DATA pnT99wCwlZi64Nz6bbyty8c0bw2ct2rTm6ZRTwG6oxR4u8fTk4KqtIEVNjPrFsyhMJNHFJOpRtE5Q3WiFixVvS4f7lpxJrA+mhTB
# DATA 8qJ85rq9eNRvnwZtjKhrQ4KG4NpSwGAD1yqu/0E2yRpegYlUtkJUNUhZHx4JApUHyQbMFeRtQrK+ESzLH9bE1APf6UeDAs2rL40H
# DATA ku7uBNNqWGU5cR2TP16wsQk3rVM07hB/W15a8rxDBECdu45lFs1W3C7FxrFobBn9mHJwSGZZ9bNQp9Ko3x7FkOcEV0u8ZFFlwWjn
# DATA UJBDfEwNkTz0GIjQ2xM8voqJEUBE+Al0ZEdSl9GufGQe98kj5Uyw805fkIIlDxlOllJZLIiFGL9E+OgPj5jps6cDn7mQMxVSFXky
# DATA ckqugnkvkjkh80ZXbgzQ8V4heInqdC05krHNl36NZUAz54wKvz/s+tWr7+1sbd5/X+pULWVr/adr9zOVrQmEAiWKAZ9MZsmsuoxV
# DATA lYegXOg83BKs6DN3qfTiVQiuSIZdqsdWglHy+9W/UPC4B3BAlrES6KahIogZ6fQhhfFh1/WDMriUVq0edjmuP0mXLaTuAl2A+G4F
# DATA cR4THQTKlyOSdgphA2QEyqs3GR/iCR6+9n75tZPya929196pvvag+tru34Tk2lc5OqEzHsWIJnol0D0EUmbBN2qKvCRCFVEbTieH
# DATA 5TcgGhVGHtdCdvOQMgj3SXoeJYfFaExMaZGxP22iyUWVq9vb9c11lxRTHazUdINGlXpadR3gU+Y/ZBxqsg1JcHGlnIZkWsqzg34s
# DATA 5q1Z3MAhTBIQ9+DKlE1hBhOjvHMS3SrByuS2SJ1inJxUTsgM8LudKd4g8JPFZ5lfZU+NKc7SDEmliTE6dHfTFp8r4uzWPRw0Kg83
# DATA V98V07B69349TGXBsi/JpZll+tpZN3eBpHv9fROB7fM5Go4lrAgGPdmrfCJ4AEMgod8gYGZQOY/foOOEUtltbezu1O8VZCUSayM1
# DATA iiXHLOobwHTQadNFw6yfoT4sxZZtlKPex1H0gRRoEu+X7fedIYJ6qibrgdtGwS7todFUA072iCkYGF9UGA5y3GZN0B/xXzAmT9Dp
# DATA rXCAPLuxQhcWVaJRhWJjIbV1uQgIwFQIXL+5HgYPS2f1Gb2JBl2+ycAkQ7bZwjgswz9g1IBoEDSvMzJ98JP6+/hTSJ7nep4PoqPe
# DATA YJBS0d36vY3N3FUBegH1CY58BPTQtYPyDX8kTwshF/xI/yqfOfTKExU2durrq2t79fXA6EMTz2BRosH1ArZTkdUX4vojeFSsMa2s
# DATA Pc+/SkCo5D3WMmjR7bVByUzk9XteBYC6Ppm5l2vBU9kiZe4sKc7IeVnlV0++PRZzKBWhwVPlI3npB60yNIUJFOWPlaP+8KAQXpdK
# DATA jUb1zi3QF2EhVcrbciwklMTbN1c0dBg1CeInN56hTUAQF1uVgO8kWJ1hZsV36MpjiPF4rHv4nTHf4EZCZg2somG83iwWr/yiDHOh
# DATA zyBDGu9FWVPiPZB8CZMvdTy9yBGVduqknlcZxxDjc0x6g2m04Al0MVJYp/P/nOzTvB0RWirSZgWYM9yLBLf72/34euGtavQEjGP7
# DATA 8Y3iWwWGhGk1DfSY5vWiKFiDwpXrxR/YWavBWFN5UKz6dT6asxL3+RDo5LEg9Q+Rr3zIUt6HOjDyQ8BYeuuD6PRDODJBSQYxyx/G
# DATA 7f7kw26M0AEwmMZyE1veSJllucWo8ErT8HjDFN371/bDsOh9VXQcFCJYQzH4y1pwq5oaoOTwVHrH3VMJQTKxYagaRBEZgjaj8JT6
# DATA j+hP+Al+Yu7u4QvEBvAAcrp+hpiRNfG0JJFe6EZv7EU6b+CP8qmntkrGIdSUMSh8jEsVfuGt3kmx0J5OjsUW/zmqEgWhNKq1JhHX
# DATA gSCAaPyhWMhepwg0tr8LmDTjcH/ZqNs8VN0WQm5DVNa4JnjWW/sHFnGK57v1tZ363ofbq7u7723trH+IOV8+5GOz9ZY4Nz8UBdbr
# DATA m3sbq/c/XN3eoGerD/fe2drZ+JtVyI1UdCvlxtRgio2/3R/vD5o3wnC+AcwWKhr78f5u8/pbotVZosyHPyiGpVThIKsb+wfR6V8Z
# DATA gzQhoNK+H4Q2DWTVXwBYHvF6k/+KOm5Uys3r1cVFmLp48cfV5o0qfWre+HFiDn+c3fsnywf7jcZS+a3m9UZQXhT//XH5/5LWosR7
# DATA EtKrc9wetzsQYI3APOqb2E9YEhSk5kOIj5iEILcJJqXfxs10cyUgH0frh1dqwfLK61kiqxLo1vm6GHDizpiivtvxhJDcK8HecaQU
# DATA tpbqjjSV4DlCWO3oVlEBGD6WB20ttbz5iauw/EjpeyekG4Y3AHJEdhYeyc9nfLntA2LvpKUcUVrsp1LQFvgdMoIHJ9MJeB8H9/EV
# DATA xKAvQT8Hgh1NsMPgPUFOAuJre0LA88GkfWSY3kfDuMdXZR3tSSLPTv3B5uoa5J3aqW9v7W7sbe28T8mBJ5OT9mBRod6UVXdd+1kq
# DATA Npqg80XnO9Cm6k4+o/hO/X59dbeuoj2lWY+dVgpa8RTKbEzipKscCalkegAutYvY4uJT3fDZovQMWqS1eEu5dbTQdaP21PXSPzOc
# DATA 4AmnLK49DVc7cA6BWgQcOCAgBfBRHw263PwNlGhLkL5d1FteYwNhFQTycgeehZ4Y3fChoMLy6hEnx9ZLYN4jwjN603D8ZO+dgnLy
# DATA MFJmgBA2juLRcBBHiRsoPyeZaOX2HfYkgSumWms4/kRxsIrrEpdaQJx5G80EKjaJyjiGVYJdQL28DMWIrYBjxGoY1aN9hEotTckF
# DATA p1VRgo9+9hVxyPzRflfwdPkf4JPtIydac2y32R23D8HW0ouxPsyvmSg0Eie6zE9tlbzMwDmvA4wFvNCtsC9+xgxJliTxppqyEqZA
# DATA 5J8Va1LEkYt/i2+J6TFrnjGId+s7u0JqUMq3Md67J1PBugsn7REgqnJ9EvQc0nlplKTBaQFeAjpdvvX6rTdu3rn1Olky4Kk4ibDK
# DATA y/SF5466dCMoLJWKYh8UbgVl3B1Urw6btdxpqpkWG/+1y+vTjZrwcQqgMGv8OEAYtzNg5962djHiSktU3VzTsLsH2QiZqlj+N3av
# DATA hcjvJ5r8m9dsiycc6+BpZU+KuSgVlNLIzx8+3FjnV1G8wI85d9ZfP6zv7qX3KxaPRqYbSktGzJ+IU0d+40y3Cgq4OsP7jR0gPE5g
# DATA Cwbutvhum8jEmLN0T/kV4g83d1ffrre2V/feCa0e5bNrysIJq2bSq0/PmaIkPVkGNCs9Q+2xi4aly6cDYhlEoqoqoZrKtWQaDanP
# DATA jaWmo/SjYFE0y5k5wtUbReLrq9vbLbpKoVjtw/gCT+daQCNh+CxTn6QUNdbYjBAK0EPYKte/1a3W4ApxCAifT+/cOpOaBtYwJIck
# DATA FQEIk0t5gAwAWWYjVBr0rjdXMonowcbu7sbmPTkBfCqDlgIwX0/ancogeszVKfjfUsBetyXpfl2Jj9tC8kBprNs7AtGv6PEdS6f7
# DATA khDfSelapebPHBRvWRHQVMHcuMVEHgNeIUPqi00EQXYxVsjgDQk4CO6BGKqtVw6cVxB1jB3ZBSdhTMBC+GjYn55E4AjcsFwElXdk
# DATA A18nVRR+guRNVGPv0KtcKRhbAEsyc6Y8TvBAykgImoiuXwkHbGAxeWtXCpSkG7fsrDzIq2FRSCUrzWLT0PSobShW73QEF6/woDcw
# DATA IR4JEI6ZTVEDPlaTTbJ7dQviBMTvwKrOFnzeC6aXARwVDdmRpi9606J3bqr1YOvh5h40/Pb9jbU9TzI0rt4x3OHqSb2XbNVH6fbR
# DATA IhGBjQbklKDe3fSSVvkp0rKop7wIO4h9+qokl4JPO7oIilXpdRGOgJ0sq2jOnTfvEy8dZw2XlQQhamL561kS8BUAd6Nuiw9SPBi6
# DATA 05NRXJD26GIqqgUHbBdmYL6CkkBc8YGwIWFxUCD+gnoD6dYp0S1cLFwHkCIJeBv3QDFhYtyqABgOfgnKd9H0bgyNoit840JHEIqI
# DATA xZfM2YGfUMeR6BSAd0DTw0GZPRP2B/wMYWltON78WBc+0tWRF4sBB2yUOPjcXdpE6kiNLZCEyigRfoQhgmS/rjA0wnJ5MHwsPnBv
# DATA 5q5pTDOVWoO8FCBAipBgQSc/OWWB0ZBcDA0QAOAC5lkfONapynsqeCEeam9KuoOYznY3mAB2DB2rUVsc2TjdSgeUKmKqxAPpB2dG
# DATA GgJL1JSy6QsJmBJbk9ryMCodl6GlRxPsNVMwk894xsU5EJlyY5a4xh27uRL8qGYLQLXg1tIP7yjM8mNtU2DdKOEY748RYgf1QeCe
# DATA HzaLf0Zyk0zZkJSRlI8maqSqKia71eqJHdtqiS70D8m2bEYsi4eVdLJTRfQVR79h3nNUcyhyYVtJR3jjHmHW6Z57RmXtRxH3O6Ga
# DATA sKYlqz5+14lP0CHrpC/tJvuMBu2a22vX4s5J5R1v954M7WLoWRACwEubIpzY8B8ouzmVEqxV9sYPP2ER3ubWXmtjU1zE74M3mG5a
# DATA qomo5kbI3z0wHYkSelrAoYsJRqopwQ3AvA/PjhdTuHPgTO/LOCUvmDixRDkJH4DMGLEr8HSS9oFALovU37ohW2JKwgxQ4qR+Y8TB
# DATA QCmKuFBd9lZuQfoRKJ7Pdcuv7nAnNXW3FUJoCseHS+OGufgnn6fiZS+A07HsVWA6ttwQ1SY1fBE1XaMvS3KrayBPJ3K20sfEEUa1
# DATA RcvvGhLikGMBVOE4MrlOHvAPwOLyrQ1U3RDiOoZ0+VeIV0nUaccBYZijmLNphBcwGfBIFzwj/igo63fNQIIlUDy+vrKUEqcC73Dc
# DATA G7ZYk/GT7ItRExS6V9/Zebi9Z3Em1WUcmaiFYMeFBFVV/QCkcDOxgEl4YihmUgMerrp3oD3sCFQzoQMwPjtA0t81FTBlGRdHHJxC
# DATA a35mHFfJ8Gpmop3j9iDJPVFnjASAyB5kQgCFcbtDmDheDiN/RJ2pwTjTgrmy5LrtdXAQuPtw9/2E/+epL5CKvIeTw6wA4uWxEN96
# DATA P4/MHUjjLvoWw1fLOv5Jc+lMH4jh6kw+neSjbG76Fjkb0nIQZ1a0pA65eU82Haqqgovl/UKiLBlXDiGzH43b3SjH2Z7O4ZHheDmV
# DATA GBoqIcz5p4EKiWL4uNXtxYhbZkEtJQYCIYSyn8guoEEirZP2QFTXJZsXEuvMcWyv3qu3Hmzc20EXExzOxo7FE1L3AHxN2QH000ul
# DATA f/Ymz31yzt48hjrQF8OdEp+TPHtrGWev92XNMvHgVl/TvbrmFjkcBiHbnz2wSxxYdgXOqfWjjFNrrvXPf2IoRzZX/qKDAgLqKMxe
# DATA r0PVZD3G4la1sK31dXpWzFhEY05cvZu9Jz0R205+jVSKTVGlEBZjJlIh69TKCPMGYIAGgKEJzXFkSdl+LaR4T4EYatUWVah+YPSl
# DATA B+0noAQDGoACrnoOX7oLyh9UyqW2xyB1cKposa/E0ilkyorG3D486HVDyWjFIxAd1HliaZcsRw8fsRUuiVVlEd4MwUxcF3f2WiqC
# DATA iOWlWjLUacHv7qlOlpyiuqfgOCzzzafcfHrzztk+F/RFdc1Bwilb3BqwE2gig6EAoNYWFmCRLVnhkgLCld8I52LNlz7EnEO5WJ1x
# DATA wUweY3nujmT0T4AYgH6EmV6aCGo9BvdARy0lY9oKOam06FbY6owjjn5CiWQ2s6ToPERC0QF/xn6B3DbshphvQySp2+4XsBQ/C2io
# DATA a1CTUZ3E96JHIEmNMMRNI/duzZw+fXIpuG9jCQ1Ro+i/9l2x6KpmX8uvcg50X5o+OeRKJN4Xknyv/B7xQuKb7/BQYtiL8GRyjPJE
# DATA uKq08QTY2li7v6HHlky/SieuVFUirg34hIbNjNVEfwiumNYyrV7ck6ZyQX1u+k9CRza6Tklf/DLBKTgUwAR1e4Oa8eZ6/d3Nh/fv
# DATA 4y8gF8j9R/mm1FefCPH68tKSXwbP2NZrWw+279f38OS3t3Y+etDQMlKe0JnS54yjupyE0zs0maCfnDhAnmACZk+RDJcXn6UIcinB
# DATA Cvf71nad97tX4GDOZIB6ND14QDn2mGVtmSb0mZlqdT/2j+eilQIygrrBO0tu4hrMB9Ai7SaPk9T19v5JAq8ndO4sTtmV2FPTxqSG
# DATA tRnG3l7M6Oj2ZQW60NQ76XbRyJiE4DxepRu0mCQ4wOfpCjEooFuBBujpR23RQ4AzOxgPH8eQnJi1FgA9AxQwifqnFT+3TFOHpF74
# DATA 03/MZWVJF9ws8vBYYsR0GUtfzXQjsXYRw9azd0oOLTJo8+W2qRmEWsxuE4eMVkT7dErmcZqOxxx5CO9os+CcIaLFtGq9uuTr1znn
# DATA Zdh+JAaPbg5V9RK7lrNzjeqSdrvhgsmLrMI1E4VcEDZDxqJJOTPNfh1574FkU26oHBmY7yeojezMmMix1Sr0BoPIF5SLzzFOlOEO
# DATA yFVaOlq7NlzGAUXA8lIShNwCzHFBcmBCb3jkFq/o7iJs6346ONuitQJiSsHckHBh/L55t5ipFfMK7DIPGTQsRK2NrRQtkz1/maeb
# DATA Nc0W1Xk6lbzd8Fo+QZ8BrKsUXG/5A1x1U3P3mNu/j/dL60BTWnrp65C8e9MvLXTlLxk3cR1LgY4mpdSr+eW1zilql1ns1W/InqXL
# DATA tTQUL6TPvKSlPauDqZ2bhS54qQEoxyZadXDnkavtMux8TYH7xGb9vfqO09CrwdYgUpi6KGj8bCgG2u4DP46nh4e9Tg8duyCuT8Yo
# DATA QogWaB1gVtriAnfcixHUJhGKbgJ1mRyP0RUUHqWEWajm52FM7BZMVwNcoAyUy2K1jE+49mZqCPiLI3tlI3zlvDOk1JuhdFeer3Rh
# DATA 8inSpeur1ra7/qzMevxjupQiPlUS+W7U72mq7oRK3u8AU0pVw8/U2X83qnlTK//nooLPJeNepUJ+hvMSBJxbheZSw2cS8FUp3w29
# DATA +2U07q7eOu1Ef2G/s1zY5Bk6697gcOjTzHNYaRZcuI5EIgSg3HXEx3PqueF304Tg067PILnilSjOsResPZ9NwlesOG/5bfSGWpOo
# DATA 7KiaUx2HmiatYucpi7rEfFmtjr2xTyV0AwPSrxkz7T+/KUrNzRptgAhsbe1xPI7FRXUJFsT+auuudU6aOAQYxNza2Hx7q/W22OBc
# DATA H1B2MTWexFNBfXNv532zBiRsx4HLWSY602GRdA6Hhbnu//b+tHMwGMSnR27mijj/N524h3L7fHrxK8zL9RF8tTwYUu5FMiVgLQNm
# DATA IpfimZTbQgCA/pVlWLqjK1eVNzGisAZRhXlCfmZqrJGWWV2Nn31n7Q/TVNUaZECbEpF+UkqjZ3pXwwQ0iBeoDeJHQlLu0PS6v3Iw
# DATA z5Gi9fDauzIxjV6mp+rjWZUT2zyVFZ6pEA/xCv/m38Bn+4NrKgQgvR++rNLGwZQYUPAjfRXytlucy9VHbky4IO3UV9ffD+fpylzX
# DATA sktczywHe6YCtTiaVb5S06t3SUcnE6TB0zqyqUSUDQgF6pdZN6NLN/9qcJe0ytAepdhFXPyT9ilctzDjUjsYRIAbP6IsMTrPUmVh
# DATA pnZW0TNPaM1PV1JFI0tJMlDCLlaXzgZfEnf+Z82MrRxrkFWuCrk6Ic/c5+dfX/w6oJNU9prSweTju/oGc9AWklXJOLoMK6YEePRz
# DATA Y9M4+F2x5VR6drcrbCH/ss9F0IzN0XqwsftgdW/tnfBFVpkTK8Ei/+v575LZUr/ATKmQTu+XlEIwnLGoM69reUyes0Q9x+yaLeT5
# DATA q07V+VC7nmwnSaef7FRExZnVu9lznPwPRhod12FzdjqdbP8Cv2XATjQCIXFmjiJvr89SxOVLGHYytVEv1Qj+KqKk8dWDMGQgiDBA
# DATA DXs3ODilGNPRsDeYVIJtMQkQSBxso6JlcRBN4JLtqZWVDRCdOizh/Ua0EXSGI8hrphSd3V77aDCMJ70OqDAnQzpfOjIt+qVM9in2
# DATA +JYJYZ9fDWpsh5mmr0vzogT5k28zt0w4HPpQyhVen8LTvkllbDJp2cJV0nOCllFxTYuCAfi77+/u1R+0tlfXfgIZU6Rnk7gIbj/c
# DATA C7NG6s2bauyBNTx5tu1tMOgSAThG+tdvZ7WE8z8rY6txTMmErXzr9SqsLqXe44lzA96cROiX8w/JJUHBdUoq3k96sZiEIxv8J6FS
# DATA Si2tcsAMek92EX+xYOa4rOwdU0rEowe9JxuDkpUAs4IvIa+iV2V6AAQGaE3w1dhUzoA2EKw9vONcFxdxGgwoGrwUtLtd3u/xdCR6
# DATA hZEg6sWi5x1Ab+HbaeF2wibpqVvBR4m+FzDmnvtCU8L5Qwv+tKJFM+8AscMTUaeohlWdCfOqtQkJkWDUP5WxZGILlBBDzHnrYNg9
# DATA tXE1sJC6cXrsEdGg25K4ggUolVaIwBQL4RpBaJYBEENmxJSAih4lpacCC2KxhBCLiLYQ5m36fjQ4mkiJG4xZMG7X3xRf12/HvtE/
# DATA RsM0iRhYhzXlx7h4afRnBsZnE5UJB6DFM8JtyIM87zNFI6wAiKbtcdRitADsDY+W8RFMUGKCSBD/uYuAxHjzwRaK6ZZdPPeQ8m4t
# DATA 3QQBS5q3wre3du5urK/XN8OzHCpeebuQ2UjBR/NefY+8bfEXUjNDvliSI8Jse7ju2ApgmtG8sS+cP0Q2R/uUjiAGwacQLoKSm0L7
# DATA F1P9bLN6o7TYUDVZYZ06m1fb06MotaMSnTGlP/RmU8I7LWbjghN+ItwOV15eBFn6nGLziH5On5YuP41EcBzNO39vKJT8BVu33JEp
# DATA CvZStO+JPM7Zs+2t3RftWh85sqIwgwm1IIFjknM3mpkkxvURtrQK87R42964PYgPo3G5DocbxQqy+o3fFpRR6cWCOfYmWjW3FPwI
# DATA bi0FXQZVljZI7pURM+N8GgiItHp47iDsp9OXYqY7hiHCQs0SEQ7nZ8J4oa+ACwTinWBcPOOS7USPeqheOPuut6yPMLGnL0icuPkW
# DATA 2x2Kp/yvSZUrt+/8FyJKWDEPhoMODXsZtKk5Ncf/Q4casi9NEqOtWCH5SPermZ/sVy51NqQSOYmF35P3fwbyttW43xFhmzSdsM1c
# DATA BR2ny9TW5eCWdTkA093bWw83193LwUtVi1od+iF58CgFEGwn07eU9D23xDmVpUbSY7qELsldR2MuusOWkAcBHs66Y5q/A0/wFyC1
# DATA inTMoWVKes1DKYUIaLyioPqQhI3nfixA52WftdP9Hb8WZoctM6bg7tbaT+omlZv1WR6j6HFjKp8mUgFFLjolqYYhzHUsVPVWK4Gu
# DATA 75iOCayowj+twyEmC8IEqz3wh+fkmkBHrRZIMa1WKLMej2N05BD7Dz9XVsdHU4Ax3MZfVKYtsJC2hAzUabWKxpuQn6zV5lcK2sUR
# DATA nTe3UQPOQMP4TdzPhqPJonLZlJYbb2XmSds5HgKycY1AjlE81E6TDrIBwqTLoFMxFWWJhIllZWhJM3MYMg4ysxApz4tvpv3ebx9E
# DATA /Yzf0cyW3QR4g6ZXgGrTjN8ZvTejBONScic4mJXL4h8oLfVPEKqKh2k07bGNdclFl9xFN9/6E7iL70wp3w25ldDeVrDVkCsEaEUn
# DATA VRANVexQWB0HtJBm3sC3yLyBH8WE8SdcHf6MK8GfcdYlOrq/XaIgE2cSgPfdpjj4CT/zTPM3ntXsRhLUaUG62RCubtO5GuAdoatF
# DATA bE1dV7GCDqty2rIrM/dYRo0afwIf4tdeV6+ND5We9NJuVcWFv/j+3/f/vv/3/b/v/33/76r//W9PUJ2DAFAPAA==
# END_REMNACUST_HELPERS_V1
REMNACUST_INSTALLER_PAYLOAD_V1
if [[ $EUID == 0 ]]; then
    bash "$directory/installer.sh" "$@"
else
    sudo bash "$directory/installer.sh" "$@"
fi
