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
HELPER_BUNDLE_SHA256='5137b5359174e82bfc80ccd62610d873d19bef4ea96f71e4b6c1b164d1f48272'
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
# DATA sD/bsDXbcacdjOJup1fvxI0IeOtoq9GJe1EYRc1GP95q1xv9Vq/ZiLeiHCzKNF6zcdudereIXNv1Thg1mv1+qw8L0oUxh0Gn0enH
# DATA 0ajVgM2EN6TC9gEO1uyNWvBzHDZbCGOrMxptBS4MXL10QPJ8HS4aRVQCu6HdATa2FYadVgxkC6y9UY/7DSCeVr3dDoedsDfaanY7
# DATA o3rcrPcREuDrrbCHN9Hlealtdq0Tdm1Y3UKm3kQhG8PAYdBthUGzBTTbjgJglb1uFG91YN92Qb63u+1gqwXCrgucL25GEbwUNjrr
# DATA ARmYeyzXoAaYQhHJbtUbqP70+41g2G7DUgG3bUSdBvyw1RmGDcAIkOiwD/yl0QuDcFTvhl1QQZrA35GK7wEpStHEXkcysEWLdlB7
# DATA q94BdMTDEOi3G4EYbjaCUQsYSQibuAto2+rWuwAdSOpuAxgfQh23G71mHfbRPUtlChiu47mteqdITWoApMDUR416Ow7aAVBND2Ub
# DATA cLY+/LcOXLYd9UagVMJOagRRGzTFYR+WMxwBvobB8B6QZvcIQ9Q5OoXyGP6vFXU6nV7Qhp3dD2JQmUBljTvdDhBzaxQ1hwBVs1OP
# DATA Wt1oWA/DCHTXIKhvAX2HXRecxXitMG73i7Z01NjqAVGAvAXZOmw0O0A2YRi2YEeDWOrVw1EfNEggkFE7asbBcGsrgpawp8Nht95r
# DATA 5ehlOboZXC6DebSO0wI5FKlpI5CvLdiynRA2UdAYdfqg8gRBtxE2QFEajbqjsB9tAVTNdgMUunALVOmw32nAvurU8zoJO4k2YS3W
# DATA 6wQd0MCLFmMLlhgWA8YKgxGwOuBu0ag56jS3AmAerW4AWGkOQ2DzoBgAHQ1jUNV6UQOEJKxYf0PffEDAbPDNTkiM9PWaL94lKqw1
# DATA a6AQbnh33vf+8O+D7H+jgP8b3P/dBe0sb/+DKvIH+//ftv7vZ1grIpj66tDFXBLepPwvlg5KJpMlaRxVPx2NqEYa05MfpniP4H11
# DATA f/l6TvUtns+nqfpy+bNkpj7jRTfjZKi+JunvXhz4arlIxro+cDBHP4X+Gk9m9ncuGYz5CSe7e2d460WRw6zkPT8+Pts/weSM0jfT
# DATA 7/sn+y+OdvdenZ4Nvtg/fLl/cjr4svENNNs/ekZtvu/Dp8G6VrtHe18cn9CN5uSqxRNi8+FG+dNJ5c+55eCzV0fPDvcHp1/sApvd
# DATA Kdm3gJR+sFHxnh8c7p9iOkopv8FLnOcpqip+s90Sead50W+OmmBfXlwyFhu+ow1Zuj1yrD7lZIluadneyoVvW17OQDk9dwXCmTXy
# DATA eh1w5alWxwgtBY4S/N2xjmlCloTmOy1XjBI9ITHgnO+WKYW/i58MP2qPVanivdj9yeBk9yssLd91i2jQI1xweNbMPcqdLIvKuNiq
# DATA riFW5gZzAuAoOxUxJDJEz9UVJ0O+3KRKBK7L1MltJVan8q5s25oc8aUGmFGtLsuV90V6D17H6rblbW9tUboS1ZpS/yl/ur1pnX7A
# DATA 7+e1zQv7p8rHlU9LKkZ67xkHub9AmJdApYszYb7+AG9IiNV1HpKoiWGfBV0dWS5tqkM0lHsxSviI2GI5g82LNcYxtIIRXim9iPWI
# DATA kgzQgfUcuXJMucF1iirefdUH1NlNA40q3Vkr6a6ddWQY8E6ahI+Oze1X8NZfxPUwTcdl0yn8as1El8oGUqFNJ+hkibBjExg/VqvI
# DATA OzTElKYy88iK/yO/cd9iPNM388lyjNJ0Ec/NGSXhtVh0ZOqE2ehrVdr7cp5cpiqD58secttaPI04ewfY8oM5xgfmdqYiCNVCkThM
# DATA pvLwfHsTT/Vg/xcMEj4vKqGMYJXxoZ1VhCLj2e7Zrl+SCor2xsCHe7t7X+z7thygDaK+t5p3tBew30rlMSfrX03jNzO+N8SZpS9X
# DATA FZn1wHmxyNKVcpgIKLPw3rV+IRcyGh1DxgqmISgQLj/i5Zzj5eGzMrMh/xPmR0KfCmKHRuXtHIQWKVfO67Ik5eFGaaNy3rjQbJGK
# DATA Q2l2pxNa7hkABAp0UyymNwjeegm4c7eNn2G4qr2rTJ3kQFVPmQRvkslysqOYvOGQDxbczB8tX8X/F4xtOu2AFcMwJ2U5DuZU08Gc
# DATA 8bcOnSM18gDpDNa9BMRX8YMMm8XBxIxFV+DtyM90CqEsM4E+Gw7tkHAAriDPHwEv1TpbpKk/xkwbl0rysk5ft8B1MsrzwLpkAYfH
# DATA H2D0VrPX7T8GV9LRyvgyY+ucG/asjzvHIiZxT7wtsRVLd2iLsKliFX8ThivpWh13dF0pvHqu3rp4cF+9mmbL2YyyUdWOUnCXKv/6
# DATA EpahUzO5+PaythgqR7tVoznI+qAhWWjRheNutRfumLHulOyxSk/RU1V5SvYbri0p3PpUIZdEUUc75RvS2P1g5uUKW1GliuemyikV
# DATA gE/lrKSNFSMRV8+cEN28gDWGn2a3fwkafuUvRen8S9Y4vwGVsyJHRx8hDh3sIlBUM2dF1lpY5GIVGomIMlJbZHPoHUDOJd4BD9MF
# DATA 9mCqx3wo3Cpn1oUbk5PK3DHDgjnZmZw7XCi46v4PfacR0oFi2B8IBxbKM7shW07c4R0dkAlA1e1AChMr4RF8jGlrHRfFrWDJIq4U
# DATA LwllwNaqUpZMyiY6cvAtrv42izA6Pa+rM/FpHV3kjM6WywGet8Vmj1w2JmmPq1V67DNADofX2/hOWRpyX11ZlESahF25SNi304uu
# DATA +MtWC0kKrFPkqhnEn7lFXkGg5kX86n4+4DpcEE8OQ/CjlIuo4T4oOSJGWM1HO1rgaEzcf555Vdvji8XXsB6n51UWpC+/tMUxteYj
# DATA K5WVevNy/yVC7tK7hdyVNsWVotaTvLqacYL3lQLurItO1xC/vm5vhWyAfZnzHDL1e4jMFI/WLxUk3650gJvIegU2gfJFVVljqVTt
# DATA DWo1pdEr+eIYUgrRwLCm/pk50i0riXv0449l5gqGbRzjbnX59TlEF3Tn+J2kTHN6PS122aIVtdaVfHtVBa6LoIrWPxnGUZTT+i2l
# DATA Omc3ypnxnO2Yr8B3jxFZBf0VbATbohNjGAeNyMFX4nsu0dw6721fFBiEjhFI22C9yecoR2oYUS7kKzL/7rriquuFjsJdgfT5WSIn
# DATA 8dlTWxt222IVyZBVTa5Wvi7ZB+jArX0O/8Hjy7Tv0+FPd5K09hmu88FxmfuuFFoOQFI5w0G5vvKGg2juj5B5++40sxWxp1RAObNM
# DATA sxDXMBs6BZPA4fl0wU5pvs1mkGRgG1gmiGFyBamKg0DF8mN5hQ3KA9IVWw9xtTOYA4ir2/wiZjlHBHdKIpK7L3Q58DMwG6XSr36x
# DATA JqV7tZfRPFGil7GHNUaelMw4NV155Jtv8j8/zgOB14yvkKjgsZQ/6YLCxRrhwkJ5/IZ89TQzblJhylI3dNwMtFm3I1rVLJ2VFZ+r
# DATA rOPu+jWHzaurmlafa5VqGsXzIpkSBiCk7Gp4D4mUdLmYLencgCHMygM0zO8o0r1ZQ7mFMkBOOD4kCvJereko5YNGBMxZMD+AX8qr
# DATA +hw2JHqr8keEUH3EiIW/42gLVR8EQbsNf4qO5WB2Py05vl+1EeRKF4tva07Hv5WJkaFVNo+zrMx4ww1MKjdWVCCoduq6orYIDRYU
# DATA umobLupD9tmDrjvq5UOtGnrJz9ljAuYnHIlizyEVRMHGNZm6cn1pF1v+TRFxRkzhjbyMyvME6PvNNv0XuXa9fqG6YfuFHuARqGB6
# DATA GaN33JZkVXzBrSdpSXPoSEGBQTSlp3H9co5yiZ1C7e29tM5brR3VyrQztyzoghXaQ/lEf6qhA4ELbLD+UtHshGJ3Yv84b5cKNDhF
# DATA JjkDRrtTUN/VPX25f3J6cHykBubKHjX2iT7G1Se9SiExjmao3wrMCi0Xc0adZc19kAnnYoLvDnqMEfcYVmi7ie2nikTwZm2qtKHO
# DATA MzlVQNcssEM4RIamrIqz6t81psjhJIiR9Xssmdj2rnZFYkKN8UZuq07zbsnttaauW/NYFxoWfLwtrXSgmbjYetsOb7+7VwA5rq/K
# DATA 3Z218crWbQ84ySq9gyFGda8Tsp/pYqepL3VXPE/KIa+4ANT6P9LFb7kLdM/a22/ZJHxq2zKArGf3s46K8xrBqW6EpNZqi7C/QGTH
# DATA gNkiSzHlszG8SnwLa/iTIm/L2FSdazQ9wvylG9m4zNG8bKCy7nijOPM3b+p1jnSZNmvqAD1SBJqTauriJN0vm8D3XP0lmhLYx52O
# DATA nO5TBq7pBhBnrbv3UGGclRPgpnFRSGdt/cVHo+Eynsbqshsvd+vqqs9BH6S+192gyk+6ngZ1BlCf+7MPAxacAeQSXC9BxYrn11xo
# DATA KwowIySygK75UinOp8SRDHbprVx1Q/Uwc71JkhLusKe+5DDQFQwAL+i6sFQjKqK5MDlMhkRqBeWL8mtdtn2C99ePE31vPSnEmGsU
# DATA EIehcmAqCQkpEz9jWH6UvNkp1cTA28QoSDLfsTZQZT1l/Y7OHF1z3MAp8shhQopvP+Y97cRpt932uqmp9q+23L2lE9JMn71XPRQX
# DATA 7RDaFNJEuyfGD4U3NdOTGmWmKafRW/pW29//ycEpbAn5BiJ8/8XLs6/v7imxsvLk+/7ulO5asoLfeH3TbDkcJ9kVbYMMZb3ZA+p+
# DATA 0askK+huNk9DsFLwMD6VD1nAlomXwBT4Sj9fBZdUYgcWf5A0vaLZ/y7M6H6GBJSijrsX8Cauh0K4L7og+l+XVRXWx8DJazpcXyDB
# DATA aZZHk3kit1eYe1Q+sjmJ9btCrn4T6dmpLGO2/6NxLj4U5d0D0kAWKpl2BZVgODmyNp8s5rG1mWxfg6t6rPVkCJHQhndedzy4dpoS
# DATA vaDD9WBaVn4vhQfSmaI1u3QAWgdUTw1jBKWq1rseKBiQr2Fwb2PC0qNbS/D30c2Rpj4MHl6Q1eYPlDZQ1Qw0IqlaBCHQkCVZW7ru
# DATA gKjR4+JXGefWu44xv9KJXfCASxYorZeaSpqQZaDpqgesr/IXSyNmkFgtrjxcCINp83+RMwb51NvvPv+/0eg0eyv5/43uH/L/v4t/
# DATA GxsbJzFWqPKz5YwurIkjqzIy53BLLesAnQKYEBpB4xCVjdFybN9Ne0+6P6Xrf0CS/nIo+oz+5VZ/RJ+r553svzw+PTg7PjmgTHc+
# DATA kCQlYNDfcHkVzmtJ+mScLhZg0j8xF9jqMjErP+WvbVrfx2plGae/gsf5vscpaGBFUOUfFNziwp1xmZv756oq4az+kh+Gfoee7zy+
# DATA cZGQauHzarGYZdtPnlyCLrIcoldcD3eSm8SdM1kD5qO6YDjuvIMXu59j/cHcOQjxI22f1ze3gs0RJ/9UvGf7u88OD44wB55iuCrQ
# DATA MkuzhKop6VsTTPZf6Y9LzrVyK9Fgc9m15Ev/cYmCv6oQer7VXJpt62YKDNhhwXiAJbnLvKUwnTxdUMbF6k0vuoSPda8RvYbg8vtW
# DATA OEGnaWMUCB9ywciDiG9qzMcdFF6t6IPpgtRQq0e+u4DhfOAmHOfG1bIFyAkswllwmZkKop+sPH9G1rRp4q3eo2i98cjrGdL5JQW+
# DATA zLUSNe5ELrK0ag/foPf0HKYgxdpG7n2DXOzRpiWqUWezoHO9iCsFWdHXLpc3OF04yj1vR56BufNRtqLVeeXCXlAAPF9s+fKSir7J
# DATA SAk7pfPAW7Okg1y8Gcw9i3c5fwrJCDQd0CwlqwlHoiuDrVn5wThLmdrJAs3EJQa/J0EWZ7Vcr7vXKdiDQfYae35GxQfRc8Md4Nkz
# DATA eg868n+KGcr8e4Qdx+OR21nxChbOjRPoXXzI0wLsXRQU11IVLK2Ng6n1eBImCRc1FHPobsYrnysV2zM21rE/RVnba24ALVz7ols/
# DATA 18Jzbr5cuNE0fkkd4SG0lz9GJbhKYnrAqnAutw+1Xr71oVVHODXDdW4l179ukpSuTVKYLsYJytYlOKqrH+749bwj94xLWyqXATE9
# DATA 0U5B0wgiSqIB5R6098jcJUOOjx1La6jNl9PyuRS0xCJ9OL2LKqeAiVM3DGYLvABapss/YqREfWRQdiag7rfqVQN4xclCUSNmiwha
# DATA Ux5O+/GJOEL1sCSwxvAMHVRxlOk5j5NJsnBzM60M8/zYAJK1grwkbhtZ9SHyfbCNOHdU3bzH923xJaNOaFaacWTWTOc2iccRH4XC
# DATA 2wjgzW1+n2O+MhbWIhyw1FImfULl64X0SqrOYsCFFXUhcydFSi01y6KVy+cu5+mS7k9QM4Mh7Cv/1Iv67mwZG0xHzHvMXyDz9m2N
# DATA aO8OE4s/ps5dcJwV0b27Fx6WrdKLXONTyuq+juOZAIeXHwAzVfuGfrN0mfwmQsw26yu4cFCsiNMa0rKtJaExc48qkN/ZesGJG96X
# DATA ya37Ywb4YH7CS7mPwKqqrrpATpKwj9C+LTa/cpz6qcqO2+nQGpb1l/i690jbaegopItUIzyox/rURLT8UsW6QF1zcgQA13X7Qcij
# DATA HNiaFNUAhiZ17y5npnS7ouOGBTJopfdx8W5TlU4XwDnD3N5zGZ41JB3mQ5v9Phan89TEmMS5D9PllCxNxxMpDRy9t2Bjm+EtLZgP
# DATA G+N9cyAI70Epb+a1+FQ6xo7kFI0cfbjq6ITTD1bsld84v6t/tKM3/XZRSc4TLTMFRcB4cPNE2+uFI3tid8BuRtYfz+eut3cI7V7f
# DATA G450zYACLv7gJejf97V4G8H7iLJNjEiwLRPF4xht2qfAU3wqwltV7HAGREipg1K73tX1VlZ3PqE6vHppKjmdjZf0kx2/8bggpaVH
# DATA nOqPRWFLWR5WU8yayKzDdDnm6/PQCT++VYptsli3ONzfqLSHiwogvxXY72zvjDaVhRie6urBdGu6YrA5SilVvo1r/YOL8Nom0YcU
# DATA 9GXZg3FNvoppR1mua9ojq7XK87ICbL2ubMgHfNlKUrtlccUlrO5qoy8ks//Xcw7rIg2/xzEeqP/S7DVarv+33uv0/lD/9bvy/34p
# DATA UVWdDyicQy7yYqer2P6osICFzgzuPn9vrm7Lve7fqv8S7LCXYHK/WeMNtny/Uq/Frj/BB51JbZWzXOx12MmXobASo/neNdJ07z/I
# DATA TIlJV8vpa/K9LYAnjoPJMAq2nSMKlrVXwRoZ+QgtQ6QUQerPPXLEzwsqZKiQN4eqFsEl8KMMbB+l/MjlzTQfEyWz0tktLZ8aPFGF
# DATA WfgykFVFfwyLW/ie5o+b7KRY34WVzSpXa3KSIVcEoBMEzmOhPH4Oc7xPnXz3X979kmt7q0Le/wB/fvv+5+//+t0/C2VuvvvNu7/H
# DATA K+zf/RMWAteVPAT+zDrol7uCWi7/tM/UmWdyPvURZebvHpwB1RqXGVDpcSxA/psHZkCJ06Sdvg3OS5TWfbHtB0SkARIokwbPiT+b
# DATA i4QCWQq6gpNvElrOcIFBOTBX9VlCUHKipxbiVtODZgk63pBmzhkf7j3lOAr/TM4IwZ3jw+SALcGmT4PThTLJ1M6CTud2S7zRIVlY
# DATA DeWHB88Cvvu/FF65njth/Tfv/4ZICiu5wycs//7+b6gm/Pv/BI//kcrP/zO89C98ZLCggL4QiwUiHUNASwCYm7pTlgkomETdNhJO
# DATA MJ/Ah7sHYf4vWHj+N0jk7/4eqAZh+Q2Xxcey9EApVmF6rHf/7p9hKj+H73+7Fl4iGYCwaiILBPt5Du6L4owwue5sZAWW3upR7jbf
# DATA wia+2wR7ZPlm8y12eFcDzl27/Fkpl441Uy6M0T1BLKvn7bcMpS78d6EG42FKK1aMCRvQxXm0BOpkkvWQjQnnfO9jsixtbgQLAcvw
# DATA q3f/8v7vCnbxL0qVonNXa+5cfyQ6/liiYSW+mj1/It5MT1+4yQ6MD50aM9pfvPtH+PLL93/t4x/8AGQGs7uXZz3+2IsLsakCgLel
# DATA FVcAULHAtZ3QRxUJ++BZw5b6O5/22q9ponw7BP8Mc//5u3+B//vFI9aaWDFd7kL8m2DjlEwla4xFiame/4O9t+2OI7nOBPUZvyJJ
# DATA zXFWsqsKAN9aKrKoQZPoblgkwAFAdbdAuCZRlQBKLFSVKqsIQhDOkS17PT7Wjj2z+2F2z5md9dn9uufIbcluS2rpnP0F5F+YX7Jx
# DATA XyLiRmRkVgFktzxraTxNVGZkvMe9N+7Lc/E8BKyl50TT965b+4U6AMvMPvPl3uh0CBR9GY/EcuEw4Oc0MweT0am6EnX0J53ZZMDk
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
# DATA hcIIhCRFHnIokw7Opv0uSjdqbNlkCjb+IzWEFPwvtGsb1NU9zrovUOWJph1Uezqd+e8/+d9yHitoedEvKO+OxqoelCfFmjX/P/be
# DATA dcmR49rvfZVyyNrsFgEMqnDv5ozO8CbRm6RoDiXGCVEfCkChURoABVYB3dOaPRG6eG/ZIceRwyfi7AhH2A5HnPOd0hbtsS5UhP0C
# DATA 3a+wn+Ss/1qZWVmFS6N7untuKZFsoFCVlfdcuTLz//PeQfl7vC7PiheUsFOkXIWFJxDVY7wimlJJjXSg7HGlth7G1BdNogrbgaCY
# DATA wFCWvJ3lMac2seDCpmfoDpMjHh8MUBVrfu/d5GQmZh4yUnaWDajGYMdaKWpST+WWDEY4RZVaOXq4QSQVfZxkUrTYU5iyif8wiuZ5
# DATA ow4HA9j+kwSNYTDg60cIKIZCIoSXODNp9EA4Wc37OOH7llxqdHuUcpEhL02LQqBzRHgc6U6Cqs9H6G3ihSSBgrabC+XYkio3V3PV
# DATA WnWrjB6RsYgknlBgJitGPHkpFOQHFGOzcSmDuAd24w2lg/FwvIRKKI31udJhiCjWvLfR+cjeAxRJinExor5FVVd6D85v8W9SpZS1
# DATA f+Vpzm6DzU4znB3N5Fsz9q9i61+DqV80msje/87jfvKIzJefAV/T51papStP8NBjsniSyaTaj2guHCfpQTaloMdPEO7jaZhSbTio
# DATA H2KF4yiF6+fgOEz3qtV5OI/S/cNBMqFH5BLZZfuH6L8O/M780R2/1m558gvC2j/ELnPq8k+qJ2k4P+hTDXxYpbQNn4SPJZh4Rg0k
# DATA XhxC27+6xNZRsvWiajIaUYIOakEQTZ+EB2OE85jvGYIFwo2kSpV/8HBGbfcgmD96IpWkEs/my0VF9m9V8ATGmsccRfUufWdN/j4e
# DATA xhkNw6f0M796NIkeHdJocTSr8pa/g0EETPThT6l1xqPTqmpf+jLNT8lowbh60GzOHx3OxTg4oJygPtPzaz7+HkoJHPjzR15GU5qh
# DATA Z+XfSkaj85gtijlN6dWXVWmm4TBeZupn+VKhGEh5VE8kTu1W/ZCmUhmFM0+Yd31YysYDTGBUntRME9O5k195bEWTuqlZJjumVqqD
# DATA CurHbKFiL3cWDe9i0fknj1cSysm3A5AqpoI4oJLBqDJ8nMzDAc0GD2qtlk6NmgNS5RiRgZBVyR6MMQKpR4sXuVKUrkkVKV3UFaZ8
# DATA 73JKzeK0ePUxNW3UmINGqVD5Lqr78rOuy1Q0TyQe1F/v/ZinSDyMU6v8yb51EUWZ/GR/pQ7zTPrAr9e/Xah0bap0G2oXXr+/ezvO
# DATA qy5qbq1jVVxd2Ro6EaX4V6yLEn8V3YCa5qGKKn+WSlxd7USo2VWzcUpfDupPCsGRrf6Txzpy9ScmQ6xc8Lt1CpsqW/yz6IAtJxqm
# DATA nvD8yLTvozQeHh5RN1RrcMoKzaRel7trnCTzzKbOgIPpIJRy+7dDbVKoI1AXqPwfby0jnTq/FrR0qJKBFK/oiEbxx3bAnXrdPFL3
# DATA ak165MnYr4yDyrhRmasuvLpI5vT42JfeT16H+RXMZAmoAtIyxrvpfC+oNfHqSrvWOj6ptGr4sk89er2pYqryZP9wQpYQVQm4XREB
# DATA +ZW6BCZrVKq1eqNFjx5Ow0cqDX57MD5Ukeon1D6nlNAGRzrYLXK+dKeVBkUt4IxH1PzuBVGjuAQtZGfx3fzmhryZXuKpXKcQG+UA
# DATA i09yy3iCDNZJa3cG4yfx9KiSHR+ZWsMktEOrvaoKEi4XyROZE1d4n4GM6KqpABfnB3WqyBVMmPbwpFf12ujTTURkkLJDurCulgcu
# DATA dpfT2L84iaIZ12S/1ipVZb/eMt2KybZ1NfdJjb0Xkpcdycum5GWwmpc614I6VYi14xDNJYoJ4n6BrQf8RxpeoIZW/vuE3SEX5kK5
# DATA nW56uxfKyKW8+ndhAv+kbHocGEvlsNQsn9TgDXoM8QS+cRQ/ioaHP6uyD4bSfYhGWfVRyocgblBOI6M3dNGmW0A6OWQZgh4jFDz5
# DATA pEYmTaI7x6owA9sou2KvR/8xe9bQ9y6ns+zAH6Ue/bupf+MGyuF7NbIc6DWcVu5itVmTF2mzRQ1B7h7FR8s0MoZkfnUQsjfUCqfW
# DATA DdK8fSJVtS6/Vk0lLq4L3dLzvrTRmjL4S1nTqufVmu9eX6fVw9whFaOwc2OyM5W675Xur2XHkl/kUWdYvIuyDiX3eIeyTKM5zQr3
# DATA GhWq51Qoe/UKlSx1G3mMntQGYTp8bI0s1qjT5qG+XAuzZTrCEe4L7Ivt5qi815sfYPZfHYzjyXA1mXxLDe7zSm26pEnpY9tA4CsU
# DATA EH63K09P8vAE2/Jta6C3tk2tN59b1Mk26d8G/duGaVUqJ66fhQJgn12xuWww1M0Ag0BKvaGk+WC2GEue7AWzfU+nZVNJBKtW25Oa
# DATA 8ZuW6zp1A5QsdBLmFk9ZA5KBZuDH0IpRHx8QInyV1iDX6aJt81XPHvw6dVyn9MSLXeooZabqcXT3UmglDLV5UoNvwVh7wU3WS7yJ
# DATA F3NWTUQ9ttTEfLtECwzWtkAOSzYDPi50VmLu2f28p+rcljqgUsbjR3PdjNJqCw3pjk7GfFgSvdUBTcq4F9UxOqCkLE5NGnkkrMm2
# DATA 9YKNXWtpq1k1v0C6Fe2LXGNpN+3U1Q9xV5UXcNRbcj/mJH68g7lRmqNQz0HzpngQPbazpDwf081RNw8Zd2tSKDS9PLKMKBP1+g7D
# DATA hDzrhZhu0Hxwh0pSqBue+RbgG2y61QZhjynF/tqr72agFWPpza2BWf2U0eA+O3pc8htQAwmPyt4RMW231E1TQIFMItNinem2VyeV
# DATA G5pmPyzZtrolrYytJbug3IWLQaCC9GRSiEcOfGue5Te5p5SmkGd02XkzDLNxVMzgH4/j4TCa/aTQgP6F4AHD2eIJNbfHxg/2iE13
# DATA e26E+UH+vuYFTd/Oyu6mhl1yu4Wz0xO4oZ9gbURKeRRO48npwTtkYiU0Lle+eOPDuK/3vn+UzJIv3qhM6Q+HW2zzlJdDGofjSWZl
# DATA U7B7fVS+lMclr1TZaVWy1/U7vcLslpuwmkRd1FwPi6MjxzhQE588xIY93K8zOncwAMtVvpvH0mp9Vh1oYXxVNxTcGjxT2c0/ST12
# DATA 7q0uzUQ3VIfaPJ5MqmlycrGVrWzqRTQ3pa670Wb+Ezpx0/6bqoNewIXH4ZVbwRP+SRccdZGTcJ6RVaI+2BNouwbywLwYVxZDmZZx
# DATA XhwgNoVxdKfKuNhmaz2pUQyix9yTSwd+4N+p+jw2Wj4iy2gQmyFZLubLBZ9IKGeWzKl4l34VyzZrrFkcTwsXSfpYD7vrbFmp0bqj
# DATA MxX6yf8xjYZxuGeZaG3q1vYfb3Q62J6GRht9r/IqFFuLsklWRyeuLHKKAtNdySa7zvD8dOP8s9QoG5i52llZnE8ap0uL+2qeG13K
# DATA GNPG6ub42C9fP4VsYLGhOEPcMVtWDIbN0/JgpH2MLctK0Q/es+dSdvUMSuazNmNX60WzwfWC87CirdyN8WG3jLheeFTv5YVTmFAE
# DATA 4qZTU83i8LB76ndOLncia+Y/3JFTVTLpnvOSZlZNo+FyEA2r04SLRb5S61i3JsaBf6fynQPZ9EEfwhHaTTiLp7nLKB/nD3lRJF7z
# DATA i46GnM7RbVGaYUUvRpUdHmIfc2kq88Ny+cpKndUrsBWg5oZ9mp8+NLON8k1PnhRWDPWuLewQpD/eo+lkxmuf2Jd3cOfOyclJ7aRR
# DATA S9KjO0G9Xr+jNnhhA9HbySPcWPfqXrtJ//CyL2q8JxsA6Ttf9KQjy7+n/Jwf4POIhiDeM9WoN4bNHjY+3nuL5Up4t9BHftvze+NG
# DATA cNz9ftA89utj+m/3+377Z4WHR8GoMWrIw4hicVU0oxEyevZEdmkiT5N5TkEyUfvb+MZ8MxZV3P4pfuF9c/nuOrX5yVy1F50P8h09
# DATA Zg9ANOS18FOzAc/Kkl7dazZbXqPX9IJWfdKoB57fbVQb9Y7nNxvFjBm2h/2ovpqrnYbX6DZ+5HfakyDwq72WF/j0eL17TH8/RNCt
# DATA elAMKhqNfM5jni485PR/q9lq1VtRfrFqir6x8lKE2vWPm4E/rVcDv4lXVns9joyKiOdLrbjiG4Kg7gVN/9gPGhPf971W90dBr/uz
# DATA j5qNntfwqfoE3Ylf71SbnR8F7W4xed1BLwrDlSA7LcqV3tgP6tNqu07/HONjky43mt2x79PlVov+OaaPpZj32/16c7Qu5s2NNVVt
# DATA X6SKeoCThY+VJ/hA1fBDnt8fqMZyqKe2B99qt9r9Bi4Y7xM9wv87NAbN6pXg4FuRH7WizqHysR18q9VrdzqtQ7EwDr7VHw26AzzB
# DATA bmf6edhuBMNDWd4/+OKNB9FREnk//ICmC5+FY7I9K/d5+1hGXWE1i9IYz+oubafb0T3VsNuSTKa8Sz8Qa9ILik7nrhgC5nYzGqn5
# DATA zfciatNxWJGgS0tzh2VHGIyzSqfWPD6pdMQRxgGrnXK7TO+3+rdoploMsewot808VTCrD2gfenGcKNw1L1iVYnLyDRh/BjF2Ej2+
# DATA xPJAvhYgHsCSWSROq/rljBsPLtryRoyiV6C+0ZgtpLaykrSLjDvl2VupY2w23KSl8mS1rf8UTf2LN7B7jzqJeLDgneQz3gDp/Uvo
# DATA i3l375ktkLUvl1F6+oD3BSTpXrZv3Wtuvp+m4WltlCbTvfXP3Z9M6FHrWbWX72+jU0gv6mfQwmvYDkix5bml96b3xRsHdgSn0RSn
# DATA swU79lE43+NADSuc5YwfRqcVbxROJqjc+95jHPin/0oAIpPPe8oeSCRApP6AsnrPitSb0CjbPzRUYaar0EuXk4n3XW9PYlEbhxle
# DATA tk+X1BUKSq4cWBE48HD0U7QIWGz/0HuCo8qDMcVKveEyIeLxJ3aq+VC9JFuhYh/rxzN5XP9wqPKikP5sQ/orEm/UktlRPDrV2CqT
# DATA LdhisyYtIxzuXo1keLqHyfO+KYoIArX/cu+LN74lnt8v3qCgITYUTYBoreFudTqDbsS3w1KQ4+RkY5hijF46zNlyuhcP9/PUfLyc
# DATA 9qN0j8P8AqJ/9GtN52bh0aHaRLoncm4IXPQs6E1fvIGvd6g5x7NDfcxFzri8kcd+mSL6P/z0w5rsuPwBHw+h71Bv896Ght6PEc5P
# DATA Kt5jBPwEhSGPhnZDkqffm0Ssl/HFGyFnQ1jD7j9o1qQTfNPxRWuiGOPSYBIPHlKbwtbTz+JplCwXe3v7aOOIVBodk1GRR4rCAfed
# DATA 7FeVFRIVrG/oUsBsAi+38ymZYUPz3miGhKNs8AAL4U0h9PHeMUX6Q6W1QmFky/40poKseNExF9s9eow/1qAaQ3/flY1Ze6qoOSCa
# DATA jtNU6Eegd8SL0719Cn+GG56oqP5LRO/HcuAiPI5+QpGs0YPvhYPxntr8yS+akNGchSJGx70LRQhfEZ8f/0S98V9IDxhn/HePb6A3
# DATA 6ud+/BNdSpT/2B0PXc59CV+un7KSJd9fo1FlshxGmYpG3iHSr/Q+s0lucV9L26OEra1viNoDbrR7p1DrNM8UKz/e+V2qmA8kOdTB
# DATA yGecN3pyqKO6lz++pmy4vuB9OjnXkVX68w7ZQQmQu8iopqnt3jFiAXbwXW/t7Qfej2s1/jysrLvDFBRZwBmSyfHg7tVKjES6kEXo
# DATA 3fJnTLaafejL+VBvJi9s4Ff5/rba9r5+j/uhPCNh8Zb2TG1nx5lQMiiOoxq38Cfyb7F6mwWvYh1PHuUVnG/JdLHRTyZTzMObi1Ae
# DATA pjI0oaAQEciKDfDFG+t28tnR4t8lYvxRIsDFIMHn9UF+1z2xfFtXRfnkjV1HlQmSa+Ra9su2aB+ouHwBCc8p2R5S20wUNtWcDfmp
# DATA I6Bqj/5K9t3siCaDMH08NuM98166WKplurVsqFeH5kDF+pqFapPXG1V3dP7AXDUjNH9TPbncQKM+za3YGONb9Pdydy9N8wPRMjXZ
# DATA z5nM+sQc8nclF72/+zuKNSoE9V/TPfqTfJicROk7lHl7JoupIWQsvqZfWXiarCQknOs1TkzQffVDz2oQyNRipaMLdtVg0UWI99B1
# DATA u9MsxiaviZyWfe9v/sbb01G7e1fHBJHigEwVMPl2965KCuovbpFlPXrzv+AoSHPjj/uSljfflIJSxg5WDnX285fc3MG3fbkjD1by
# DATA A71jPR+RlFKRlCFuMIHIb/vqntLwIWFxLeUYRhkPHFTyukTXNEZuR2iLVqVAckw5bm3AhYfoRYijqqaUyTqQ/WKNw43K4tjbv3uP
# DATA bcYv3njfHApDM3lzD2bfF29I06P0f0e+8xyQm/sieR/b6vaC/TeR4P/1+9oX9L/Zu3qWnCQLdrV64cLzacbypgTAh80oAHpo/XvI
# DATA eLpTvDV/l8/v+t//aD2oI7TDc4OpNG6ZAeYHMt3BbHcw+6KD2e5A9it9INsrbDdW56Bf6IPaxnPGPxdOAE6s49sP5qyWh5EtHgI2
# DATA ok9v57fztmI+J/dined+WU41XiTcYjtKOf7icb73FvW05WaoF8kQDbNS0ZX1LmsFTy6EE/5WPKheXrySJj1IkLnyptPZQEdD+bHv
# DATA /WBl7YvNVLIHSgf/rWf4C6eDM2B+j4v2gModejBUXrCH0sUpNhWb5+eiG5CNQz4Rq2uUpzZc0LSQjyMv+zSuefDqepiDUJhfcjx4
# DATA l1KcpDXvB/Noxud8R3x2nx5Sh/m5snoU1hi1juqkJ9sQGMOEu+nNYCxQQDOlG7Cj8o5X8nFrHQE+T8zRJmuBjOwjnEszMjx/i2PO
# DATA qHA43c1EB++TpXH3ejNcZvUjeUdMPy3nMBuymgdbin/M2KRKRnDyUIsZwlJTzYbM5YQlAEbLlKyI5aoawqt52NaE4Kw3Z71dZL0V
# DATA a5jT13H6Opc12zYaiDelu/MAW9gsOQi8Br5NCOcZBZ7np/G2bbjE7j7PlqsrWHK8/sH2BxZF1JYcfY0LG52Q2LHsE9CZrLyAe9P9
# DATA t8QnqhvgjNejUEgSmnnOdFf5FfaK8faPWos3EWkNa0o+b4jCxWnI+41aajNJNOfdRzXp2e9wHEtRFS+EqQ74tkNE9VMmnuaCiWaj
# DATA 1r7GaIpnhH7WXhq+8JY4WlWk9D0mUuahtxLu8PPIBXjzPf8gqL91J1FWYfmelrqnteUev65uog/5XXckWnlSlK2uc1OtgtGDeTNY
# DATA 2JJHZDbwE2xIpFN6L+8JVulUq6EYvXTVzC9JzxMf84vmNE4vJAfuSBCYP6ncknVaO5T8kt6hZq7cswzOEBMyqwOwpanYaJRmv6RU
# DATA QfjFGJQf0WBI/bMYjdprbbV/jLHRjFs+G4pmoI1TsSNr3v3h0OMzscosyPTwmduQ3odYQ1GqnpgImJF2Cdl0cfSyUSqGOPU4eCN2
# DATA YdDb5svJhH9cYhmWBvU41cb/D7NIlHdExEZ0f+J+TFksEvNaRErXeSzYZhwFMktgWLApjZ4I85o4w7SQkjSTzk+rXLG9PoHwvdXL
# DATA YQzsR6yXyZnGHbwUCZfGq2812wOgM5yd4XyR4VwykJzl7Czn7ebwC6BY+Rm9jRtHJpp54VC1htxsLmk2YnAxOm+siPgwWlCBzo5E
# DATA 2q4ovShMsGSEcStREpC5UqLoIZaN5JJ/FtsVpRTUlsW3xg3Wn9NCzrqxU4wb4jIzIpWwYLBPCXqLoUSXxbCT0QjbvyDTx31B5o2T
# DATA E/rZoxKS4ZLzuuYp4wKSlhS7Y4y76GeSEXcMnOeWfKX4rDg5xUFvEbI3836K4WpiRjqTIjtpH7JTLhyQjQMhzRPqsfKUYeSt8pRB
# DATA NkQz6jScZLxdDJYOknhEtlime7UhFd6YejMuJU6mnPKhEGYsKg43IplORzJ3EiNG+8uSKVmNC6UuGMIqeOhppZAt6Xw3POWeeHtC
# DATA UYbiqkQZ6zQ+UP7HURRRsobxiKX9aHYHQw0Ch9jDiH0IVK0WsgWD6cb0C5oifmET0PuMMTwe8wURIFtWzJSFY5Cqok6Isej6y1Op
# DATA 1KcL1GdsEt2SyE+jbE0CxawoVOFVQVVT1clKZb/lCVThUckmaII86qTROiMWRVrRdiQIb+Ewxtk7GejETlViklR7P4X+y5AykexC
# DATA tv2QfNh5SzIm+ImH4nHVLmWGlKF2T+WdYk/qqbSWOh3F6ZQXR9bNbTlRn1HeyHwcjN45jpGSmWTU1qkFGes5X/zOxH8t91N+cHUk
# DATA U0BNz8NMbGHunbyPtLgn9a4Me2BTWoG4jQ+ZGs9DNo8xNSDDl0o6XC5idBthyjpdU6U8yeqn0qGACyVuY7IQcF1NKTam9m9nyYnU
# DATA T7QSaiLoIyHYqhP8bsLhL7CvErktbZESNIcrgbtGHtvELrH8Cmj8VMrY0hBPDFwr5elCSsVN2Uc2EmWYpJCKHAeksSMjXFGQLXTD
# DATA PEWYnZbVZM18wpaVtex8sZlfQWv/yZOKYegsjgDnTU9tgs7/d/6rsz+cfXP238++Voycr8/+Qv//6vy33tk/gWlDP/yc/v3tKjrn
# DATA v9APT+mmp7if4Td/Of/N2dceffmdgej8kQKVy/wVoJ1fnv+m4p3/G3qOnsFtoOd8Q2/6E2N8/oF+EKbOn86env9aR+avdMsfBNQD
# DATA 2I5j6bwEsxl0yji+RB1On/4sCqLZR1FC4aTxQJtgNe+9R/OJjM8T7hEj6RuycTyn3mJieSN054hVxHmU+wzyuVAymajxiV6qZX63
# DATA QnWwnKjCUy3FoXWK8xvdg9w2WGddydwcXievOuZWmHT55fIDE9GbNnd/KN95RL9mwg6Pa2pYT9TmVgymDrCzY7FdP2IHa+8RW58o
# DATA nEruYmTjF7kHh0wWRQXDdEzjCecjy+1nC8xUS7uVNVITQZhDKfFiha9zcfXb7NBc07KeF2bn4mQ4zo6zBG7CEtDAnSsaAK+Jc/PW
# DATA Bv8bGft3GvovO/LfzsAv1XM1H3IGz4vXum4CxmPlAKN4iq9ek95VkAe9bjpXK4mq8CjPUrxUgW8iyZpM5U3FUxLYXjo+XYynHIoc
# DATA MOEM2hXBo4osX4ikjnjCeJklVmqhkr5Abi+Uf1aOyY3C4wSjgmLN6BjjBQI34eGUHtQWgzpXd5jbC0Isgu8HZsRJOFvYbrFBMneM
# DATA HcfYcYydm2Ts7Dqq7DTN2dVKvmWT/yoW/3UY/I6242g7jrbjaDuOtuNoO46242g7jrbjaDuOtuNoO46242g7jrbjaDuOtuNoO462
# DATA 42g7jrbjaDuOtuNoO46242g7jrbjaDsvEm0naIVXpe10Rq3R4CWi7ayuPe/E3OHcVbmHXZkev6vdLiiktZqlXG+2u0VuThR1Rwps
# DATA hMONFL0BB9poswzIgEMNJBiWyvCb7SLEp0EZvgaN1Gl6zaDugW7jt3oTv1v3gnaJ2tP2W61uf5WU02x4Tb/3I7/XHDe7x0HQmvod
# DATA 36v/yK83xs3OccMvRmEQDJv9/ppEtLr1PBF+0DOJaBQDCHrBsLVK7KGM9ZqdYKxy0aLnmAdW6DntK9BzuMZa9Byq/AV6TqvZDa9C
# DATA z2kNo5Gf03PaQdvvDA09Z9Dtj4a9nJ7Tbrf87s3Tc1Qdr3I1NuNCQwg6ergt3LTOUdXgcaTSOz6pdNmSKqwxtQbjw51JO+W3KQe3
# DATA 7doSE0PdhaMF14PbsUNcxe2oiWbXGKso40PeyTEOh8nJQd2Dd6Pu6ZIsAHq4Xa++QrvdjWnekfWTQq6XbiqslclwXoLhHG7YD7A6
# DATA WilK0jpPrazbbglZdTVqaNMNJa8ZTRO/i12pqs/YTPEplPYFNmIh8+zCVInRkxdYIY6y4yg7jrLjKDuOsuMoO46y4yg7jrLjKDuO
# DATA suMoO68XZSceif2GdQ/U+Mf2N6k7d9WIqQYu+a3CdXH/8ImF6Xks+YbMuMvB4NSRCeZNegL4nS/eeHP1HapSH+oBRb1k9cb8FnVA
# DATA g+5iO/dQQYI+xjEuaflsyk9O+XSOfms5SjXv/1Rn4K1DaXzwDGVNFcpEoapvoB++u23Ev6asMDazSSovTtUWjxZ5mql3/OKND62T
# DATA dyYZ1F2qFMhEt3TOxx1Bd0fQdz6CXjwQ5s6iu7Poq6cGN+ptvghn1Et1vNBabHEa9vyxAC0qc5arpSjh23gYhVkB3cInoqFsCXIR
# DATA jzQZdWdyTlgrqfBWutJp2V3PoHMSWJ8RYzmL8ylJUHoVXKhz0ePrs+wi4rfmMKjaZbWqX69sV1RB/qTU4JVwuP4x1zM3V3i7LeQ/
# DATA Iw7HRC/OrKzerPJuDGKWRpfPRY136w7TfdpPrSi0w6LE4U50aHIfi7tuEnRXXSqH9T31efPdcryeVe740+Y7uc9VMrODaPN90m9z
# DATA +vnTFlF5OWiq5dzFDrXV3DHEbNFyL9QE+M9tWdf8F3jruavT8wD5pPO8nGclsU1265teQKxqrnnpknPjn//xP5h0lCNu5f+cJUrR
# DATA 50zCea6/qpYSeU9auoREAmy0hKUYZlCCZy1qqJXGVAsZyhTO51QnWV+XOma0PprEzhZy/B96rAvoH2kdWtaq5sUPLTJ7QpVbHRZX
# DATA Pi+7ZeYnn3XTyA9WG8cZLqukmJzRRy/pAvuCuabQvRYIoKzaeqkiyivqZQvo7//b5gLSlV6K5wMUA1XkTBfQZycJtdGUOjZPn/LL
# DATA lAlCfdJyBk8kDUnzmvcBjfIwcqbJsQhSUBpYcADCBkcRd6soINk/rMop0uoWqrSevVRMCm6tXEy3cNli+ff/ZXOxqC5GSkXkQAdJ
# DATA SpMR03JmaiIsl3ma02dNV9ZVlk/ePETDGorpIAq+I+rDkxNVREU7kqXZ2SwujIPW5XgBI/rZS8lO0a0VVN4vX7qH++3mktJ9vBTV
# DATA 52E69Xh3V97FneCawHGGx9DCppI5ooLh9Qv0dZEM97OhSGlErB4LneloBgiOlICaDfQjJnfEC9HkwO5Y+2emTjx7+eTJuLXSeZYR
# DATA 6P/5p91HoHcwyEapDAmWDviU7WqKV/pQWdrcpMIJq5eH3nRJ488kTLFPbg75ZGS09yMxHtUAQyYSGAbSbFDiz14Shei+DE3lP+7a
# DATA VB4ko4XXR7UPUTp5t4Yxvk9ZNIWWDTRjBjTyYHLAitDh8Kch9ueoGp+hsFK2x+NpPMF5A+QUVCrIUv9yGYtaDVQQWVhFClArQl9D
# DATA Uykk40oFVDQCxaNpG4HmimT3vY8T7XvUmkI8+1A+wSQVKiMG6IQ7cV2wSvjnWdhBr4e4i4NzO1faFVxpznP2mnjOLsvrfiHUHQv7
# DATA L7dju2XOTQPpAls1yaI8YqfWRnL3C6oC+RKJpl2kDW3ve7wJivdqK7l2lvdaGdFNRO/VlKvbjDq2OF8wCap5vpHEZmdSRXxHogZ5
# DATA khjHRe5kUtQ+5RCeAsptZP7ygq54y0zwpZAFpGCwM0KSkJW1sNfUGqXPzXUy19O8khb4x/B0zY4ADRTAuOj2GClwS1lQg2+UZtaB
# DATA kROFWZ2LitpKoh77TMhiXUhpYd4D69vDRlzobR4X6oNsZpPM4u2q0ESd5Q1etAt1biGHa6+T8WgH4cxHZz7ubD7adc2tw7p12Ge0
# DATA GjcaqTezDvuRcD9tpeicePh8SBW3QQnnvT+oXnxssLDMqX7K8drq1pX1wnwhKV8e27S2aC9v2Ks1m+4vOdpLSwmbniq4fws+7U1P
# DATA lN2UZTfrpufK3rOyV3DjymmhFHiTFWKK6jSMh1wfZKHpu29p+UpVLOpe8Mtlz6mwxNU5U006Ly+C45C55u/ZFpWnuffUqds2lbjM
# DATA 9Kt3oIjzpoLpaaEBvbwIcSw0LZiEOkdPnylLNZnYb4nmejyRGSeb4JGeSRmIJLUfs1q1ZFOBQqNn8Ny7uiNB32IPz54SCOEJgDHZ
# DATA 1VOfwxKXvkfWHYfiWuZ95RQTCHdjgUY9cSdZLbh83rjeaZzXtXxvITieuo+iki6V8MUM8FfHSrbggCyFlEwLbMD/oCB+35z9hf79
# DATA 89lTYPieevjGWL5vwPr7y9nXgPKt0gH/29lfmfj3e3X307M/egwK/N3Zn87/r7M/nH11/kt69k8q0D8qhOAfz3+Fa/TbN+c/9+gL
# DATA iIQCAgSZEHGQ5wAsZG7gXx0M8GWw+gt99yg6IduBJ9HzENK1CgKAXn06gnxEH5JdGgNCHR9WZe8rrG7SZ+aB6p77utPSffZyzq9B
# DATA E+LwyMgYiP8kWiznWxGA9yF14Q2XGTa7UHt2AMCCva97idvm/60Wy83R/9jCYsJKfmuhvpV55nei02geR2Rt6PvfUxc8qAwBoZ2k
# DATA 14wBZPUwRkIvFzz+qzNa1MQcCXDXIrx+FCD1NVgEpzY/i0fodBgGzxBnbJdLk0fQ0In47LKY8jBYUQupcxsssIVhydL/8mOmNp/o
# DATA vSe6oolLlSxxZtxgGhcfzVawgLtXy822zkrDe15wwN0T4yCBzkK4PgtBowGvZBi8Hk7AWzMKbsAm2MkkuLRFcLsGgVTRcnYYM+CF
# DATA aVU3gQS0Uq2WvzZEUcPF2H3x8NQ7SsPhMlTQvyxffYCMYXGNjVGDxUWJU9n0iaX5Y3Y9Ya2NZRGzeTTAyG9MsZ3ggGZcZ2VuSnAm
# DATA ++goA0fAl3EFrCajKion97NUh2oeVGxxfDYUywE+OibgqTgothqSP0/pUsZrqaq0lfkmi4QcWb7RZF/N+zgCQE4uyKa9B0uYIWmy
# DATA PBp7yxkV00LOsPOLM4cRdBhBhxG8QYzgzsPQTpOkyxrUtzpHuMoU4TpnCI4q6KiCjiroqIKOKuiogo4q6KiCjiroqIKOKuiogo4q
# DATA 6KiCjiroqIKOKuiogo4q6KiCjiroqIKOKuiogo4q6KiCjiroqIIvDFUw6kTDkX9FqqDfDaJm+BJRBcsr0DsxBYvwvF7Tgud16gae
# DATA 1ynm63AQNYejNfS9dmDT95o5fa/d25i3ecFM/XrXC/yO5/tNr9vxeq2q3wo8v+lTedHVoON1uyUsX6fd6/a767B8hSjzPszV+NIL
# DATA LeSh3zHxbRUBk/WoPeiseT4Igvz5Rj1HJnZ3e74hr1T51Qry/Nrt+WbLin/Dyu8d39/qWsjHZqNz2ff7bbu8/Tz+jR3jb9cXKVt+
# DATA vLnb4+2OnXwb9rhj9ssjKvnt3mXfX8y9+g6vvwwkUhqJhkRKX2ZBIgedcNjxi5BI84iBRAb1Rr/VK0Aig36z027lkMhBfVgfjgwk
# DATA sjlod7vNHBI58oft7ujGIZEz9OfV7OFpvs4hRyiPo2tYdwgsV4e2udh+MK/VFmHB9JGX0WwG0/o1e1hUhtvB1KBdVLTvrVDsO7WV
# DATA sxuxshBRveihuIhSgvoelSWPd821WtuiGnp2tqjbPL2rpZg3etaKffIFR2sJ6Lhlh4LajyDpqGb0wzQ6gOjlZkqjyYdKKblbTL9y
# DATA IVe2lhc7U0yRiT24Uk3EfAp2ySkOwVEgHQXSUSAdBdJRIB0F0lEgHQXSUSAdBdJRIB0F8jWjQK5CHKfh0V2YetSr44wZJfmOfNUn
# DATA WZAJCrn4ka0ogFb1Jj1NdeF9bIjc8/ff/OKN//2PNSYe3l+rM8DP7En44VwOG+CNFMy+CSdAOP/rKwnnHbR4Pr40DWfLUcg6/XKq
# DATA S84jUnOey9E3HKoKBbkQPaIb+fAnmQMZDW0FQmLhjI47fe9O319w+n7NES53Ft+dxX+Ws/gb9Thv9Iy+KCImfBA5P+4tw8p3jT7n
# DATA 85ePuQ2tThntIKNqojDiA7LK6tybTvcVJVG30Bk7QHJBPx2E6dbMBaNo2WkVlSSn8UzWvepKdZJXgZTeJPbb8K+beYpmULarymXj
# DATA bQViom5fM7EPWusiH1hR7xYiXq+1NkfdjPd21PVFVY/2htFRGtFU/YIUWGGZFNjXTAraa7O/Yee+H2zJ/I0KnbqVoEZLB/GyqnNa
# DATA Iy7zEOnOVFqzPuJeMPswb1qsbzL0qhhH1vuneSO3b2CRfZHPl+KOsoV0JfKk4BlNlcjD4Jv7p4JyLPRLWneA9St0aNSPkBGoDETM
# DATA 9+ZiNgxjzP34MWgIs6TGSXgqA48UJ4/9mRbWOFqGNOIsooilwZWwxZfUwZH5haP1ShRkTYx2EPB89Q6sl0ZFZ1k7y/oCy7pkNDmr
# DATA 2lnVBat6M1vpRVK+KraC0OSXEb/6Ifh7Ru0Iq9i51hHrycAlXjH6TYIujqZxNmcJGu8zQ1dh4511cyJ45k4iJrNWPL1nA6NSNMcy
# DATA fkqPoP6ULeoiwXFF7MrcR0P/+7GSPhonafyzxEjeKAX/0MvCEfg6UUpGEUswmVLJ5kmukM4SRSwapWYRUZid8sg7TqYRRHl4NkF2
# DATA X0U4GSLFg3tptKaBNYYJwZ1VRrmFVQSlBo6tChumDAXbZhjpuH8IYZ5iB4itE0q1BzzIvEM0NtFyFrJhQ/Wq5r0dzxLUIXpGY3a1
# DATA ITCLHi3YkOQlFWSQ6keTDG4r1cMqE0iqwJRfZoFC1xkTa9P2tzYYYZIc6RR+ihPNUm5SrQpzthgLslD/iHOxIsNdEAmvyalSy+ce
# DATA P3soNS0fN/SmSJF/zVj/dQSpdk6EViRl6Cnjwjw+CwbcNrJ3kW1L1Cci5yWtIjpVklkYqedT7sIkjaIKJvKz/bw82AGYG6fhwgiG
# DATA 5eMR5QVVWEqjTDiVnhJlGXa5TrC/hKsyjtCkdoU+zeAb59g8ogAWZBzGQ9Bga967CTdJDH9GmQwicMpgHKHzS63YrBCQ2LK6UPfV
# DATA xKUfqsJeWgr6Zj3FMEnNFRkkTuWCFtlXk7Pi8/xjceqlF6cK06o6T4FUf5b3ZUwskJqbQ+2VzP4zvc835IlJeKrQ4UVTJaOe8Hrf
# DATA GfAQyrieYTyV/ud634Btivc+1mMH0jSPZoN4cr1v4T3c7+kWpJfQ7B70et/XEoDFKDJ7hqjhsS05o9ZWfNed5eTGGLSv3vzKkWjd
# DATA 1Gp3yWA3kXrlJ1KXRc++WBLCZk/vTTBMy5l97QTTNUrHF/NLJwWCgmgAsxuyqCu8Ba/7Yukov4wSojviFrzCxnJthOdyq5IvZrJR
# DATA W5kc59PeincEheZ8ToNZmBdiAoytVmYeOqApsK0fK6qtmDRli9KsNPcmlDwJ2v4WAd1CrSXr5Ti6WEgadXIazjXIYacyWFOin6QR
# DATA e9QLathZlGWaVfgamW454aofPozSAt7qv559DerU+c/P/qIYVH9gzNVX5/+WcVX/0zv/e2Cmzn63Crf6T6BVMZAKHKufn/977+z3
# DATA 5785++vZ1+e/pkCfVryz/0G3/Jm+/xLfvbNvTGigZm0GXv0SXCv6r2NavQwkW6rDeB7OBqpgLIEdMu5ZhgiytmIeCYZwTUCuXHVO
# DATA mJOJS2PGTgvul0YKzDOUSwn6ONlfK4w86jky9nRtRVi9jQ20aCcROgsHsLINUOkEbpteVS6Rm2NXQRJ6WHrvWmQVVzFz47tc4W4G
# DATA VkWj3lxt+kUtxSbhZBie8j5Cqh8PIwesuqjcrp1T9TaaAZfAPEpxVpQV63Ecb8SAbTl96ZHtDi0TtQpibcHT6/0Qyz9Ko2EcwRsN
# DATA RgH1qVEKb1e+nKL6xXhG5tBSctibLjPpz8QMOxWq9yCeRysUq11q6mZ7ptT0nhe9apdEOG6VswKubAVoTNUVBv/XwvN0SwP/tY/7
# DATA Ow37u476tzXoS2Uspt4M8s+rsdwEfaqYRG8cTeawTsjwAILZRC5PcDo+XYynWJGVpB/IUAuhd5xwWfAHoKWRLbI6Sh0maEYfkIEf
# DATA HtM4mensSEXajLceYE02XbKWIsV/Ghsu0Hb2lNodAQ9ThCXqiM90yUDMsd8wmIuLwzIIGE/EY0EmJkQV7X9YMC94H6DeRKFQQPwS
# DATA FlAAaor+wZ4K2Hl6jXy5SCAPNWBSlwNMOcCUA0zdHGDqonFkp7nM7qbuLVrtVzHar8dmdyQpR5JyJClHknIkKUeSciQpR5JyJClH
# DATA knIkKUeSciQpR5JyJClHknIkKUeSciQpR5JyJClHknIkKUeSciQpR5JyJClHknphSFLtRrMddK5IkhqNRq3h4CUiSRVXnnfiSNmZ
# DATA ErS9Rqf7ZbVZ9btdz281q0E9oL++59M/zZ5HX4s5NIi6/UZrlQfV63gBqE8Nz693p1U/oH+a6msJBEWZXB/014Gg/J4ETOmPaeDW
# DATA 6KOGhV5qtNpW0SsOkkCJiuCqqBlGrWglos2O7wVdSnbL8xvBtNGt+s2W+rYSz6jfH62NZ2O1ftVbXrPVGrfr/kd+M/CaXX/c0npx
# DATA FgOr1QyidUGu1th2k2La8H/Ua07rXtCq0j9+dxrQa6hYuvhcDbr0ZfWH0ku73XYjGGx56WVQR9JCNOpIGpuFOurXO34wLKKORvw/
# DATA G3VEX8NRvYA6GvnDUd/PUUedPmVVaFBHw3DQ6rVy1FG32ar7rRtHHfEOkyqbHjZLSEW2OPv0MRJ68l9q5vZkwGYaycxgG+SHR678
# DATA zTvQhwpOuLZxwsnS2yqgyAp71SHPI6xsm6OHooe7wom0pRGUA/AuMV5veWz74L0RQmSVoO0L9MSE3pyeUuF2UKodVbTF/NmcHEcS
# DATA ciQhRxJyJCFHEnIkIUcSciQhRxJyJCFHEnIkodeeJDRSHCE+ekUJrpzcHX1HLo1Ph7J6CNgPGTeVzPyUhWxR8tVTc/U0oh5ZXdb0
# DATA ofcRLhOERm9SDh0xH+hziqFcPCmCiNTvDyh4/jlb+/MHM4giwVig9/F9p2vv+yxZhBM538d3fRQuxjX2G+yN3jx5M3vzVN1sc4by
# DATA kyzuqLQ7Kl08Km2da3IHpt2B6c1Sfi/AQWqcSR3l1Tw89UL8XpA3X7DyidRnlICRCEe9qeBnyOZNJsnJ9rO+0/gRHz+ep0ky0ueP
# DATA oTNuGiqNv9iKskyj7Bm0zWlETE+RlAVlCdKnj1ve97LlHJ1qNFQtOs4M+YgsGwU2SmnAQ+2EnN4kXmARJ6HJQ8ZK2AIyGaTLaf8Q
# DATA 2jDxjM9jZ+ZQ9QjO3mM+v/s5XLgFBZOUNd1FQTsbJAk/MVjOIbMt55q3KWi/AxsiPZV9dB4PUXnSRhBZhwogguRSnUXRMNPdmaQ3
# DATA W6RiLlM5jpPJkM+6IuaUWJoDsxw4SmWE344oypNTFgo32WbKTpR1WCYdp9K1KjqnARO5SbJA0ulSPzmZeOEkS/hg8FaJ8PepenPT
# DATA kWPb9NYotQqPBZv7bG1ydumb40yfoj9BXUT3zOI+E5zvRT9e81hRPe/JB9iQEkEePZ7wyVycjc9q3jus1sx119OAGlQHijxCRWrD
# DATA ITYCcVjmGKJS9Q8XF4m6c85xnE9oIDG6gtiOivPvHo7S4GXUdMIpv44GOi4dJQk/WC6kcLGtZq5OA4tOvDnvjSuTWFG4UC1+Bpl6
# DATA huNkRtH8oYQn/hUOkUzDiZ0lsTnPHabTq+mavy1C1Mg6avyXFjZHI7xuZfNPkfkovBGc09I73YCgec62FMEjFAUbol6uR3ADmuZG
# DATA mZGNmplqe+hmMebdgMT5fe72ja2k1CRuTwn81TnInQfiZhRuRlGcUZSrlJtWuGnFztOHjdOPm5tWPEBW5DgciY6eUrzw2oC3gSgV
# DATA RxpdZs+Xt3d0ERZTP2A6LHMhp3PUrwIkrW/GeuauPbrl+/qLt/ftiyJrP2giXLiYUzy76+LcbFlR7u1KUGV/IxNKJosdYqluzxGv
# DATA 6nvBpFqJmp2ZjSIhdUvUxOlJPxe8kjtEUj9oYmku5HZtrXNRRINtEd0IQpX5K0Yrq6W9vDRUaWpxVhQ7Mpql71PfQq3DOzJz8YrX
# DATA 7n7bM/XWm5JJnXmNprrnBP5pmuXTRDo6StFR8lMamYXpt3Cz+Ebujvir0mGTmamBnMasVhsPTFeHN0aPZM1ETxmwDIZJPcIqSZmx
# DATA PJfVl2kB20xYZfK0rEJg0p9PSyR26vRBpFXQdqCcvjq2t6PvONt7uzffGdqvpKF9WcrOcxZC5R3A+QbZVQPUhtCw6GCoPdhGL1SS
# DATA sJlC81zlU18KWUH+7zUzjUpCr9dNNFqRyl3LM9pBvNbaR51L2OJbBOHKJBxVDEGHraxlNlYGVqmeYqe4lKzaLf7WuHHv/TTGug12
# DATA KbIXkS6BUR8/gg3D3n85z8W0w7ho7tAEErPAaN2yi1LVFCFT0SdVBxl4C5cyeYoGDE1LLY+qsVpMdO14P8CaFWJO9l0p5iK7axZV
# DATA KHa8fmHahGiM6mUZxSDFcTJsz7ZWi1g+lZeecBZxS4TR7HeMLR9rmyVM/+X4PsBKkFqg09PnqCiOGhYX9njJZGJW/SiOCj6JFQgs
# DATA gm2OKL1sXb6+NtqdFjmIDLcBODwWO+g/nn199qezb85/cfYU0J+zP5z/hqE+oAf9ghk+P6ffQBf67So8aOXhs7+c/wa4oV+c/fX8
# DATA 52dfnf2efvw1M4j+WPHo09dnf6zSE08RtMf3fEP30DsELbQRJkSh4y1f0RvoRgcUevEt6h9Cv4zXibk3UbSw04osCOKSdLRqd2oa
# DATA HYG/rOWcZeFf1VczuKcs2lygTFNvvJUh9M44FFUDSzLccYQs61p1CbdNElpXLjdHE+INAeNkbm78XF1YzxQaxXk3/X68MJ7ga6YJ
# DATA CdSY7QXxFVlEn9edI7RLiV07Tei+J+B1gMCri2U/MiUvHvwYe2innuwEr3kfJVQDZgaESIV4DL13SHpgjYA1PGCWhWqzS4jPE9n0
# DATA kcJ9OGUeozjr2PgSWCNEYsvwoO1VcrMRs6adPS900PYkOGiQG+kvM9JrTtAVB/jXw3V2W4P7jYztOw3tlxvZb35gl2q5mgP5Rtfb
# DATA ay03AQrKUwYRLQogW43zAh43bNbUm/90fJcm7XzIiXEiugBBgIn5d+abYAmMaStqSyi/ZRrOKHWZSbek1gQvmKHpnLqw2WInbBDs
# DATA qwUO8iMfKKRRSr1dPujHstyvF7YQDIvJMcTIEIDSSLLKIJFPBahcsUb6BJifZCToYryIKqL3YIFkx+zxiEcetaqHQkM5oY4CewbR
# DATA BnmDQYq80w5RRw9y9CBHD7pBetBuY8qOUPOLbd5bNt6vYrs/q+nu2EGOHeTYQY4d5NhBjh3k2EGOHeTYQY4d5NhBjh3k2EGOHeTY
# DATA QY4d5NhBjh3k2EGOHeTYQY4d5NhBjh3k2EGOHeTYQY4d9MKwg6L6qD4KrsgO8ruNQav+ErGDVtedd+IHHZkk8y7CImtm2IqGo/om
# DATA 1sy9twZxCvtfwD6BJESBfTos0sDyBr6vCEOF29v15gW3W5wfCtujezz6rer36G+d/u21vk/XJ36vTtfaXuA36Vq72ulVg2YwbvY+
# DATA CgAs6nTHnebUb7Sqzda4vS4mzWBTxBXA6M5RoQI1Ax+RoTdMq75XPxZEz5ZsjEb9Xns9Iqm+Uj0pzq2gPm436x8h1c1e67hZnzbr
# DATA zWqzTp/KCKJe2Om31wUdXJ4GJHVe04Ck+Vg0IErGoNMo0oD8TqPb7Nk0oKDe7LaGBRpQ0G012mFOA+qPhs3h0NCAWo1OvxvlNKDR
# DATA aDDqDm6aBqSMkvWOD53Wkq2lRiJsXKtut0I8uhnDTn5vGfxjJkrrJkXajYa5bqVZazL/J2D+z+p6VLsYKW3cWN202C6cEMrxMK0e
# DATA YWoMnkV9GB1VrLV3+7MX9OaPKt9q1Fuddp/dfvuVzSH1LhmUjnI2jwaXpRJpmxfewxWTylqR27w4rpbCxSdczeiHaXQwDNOHm9lD
# DATA eQ5X7KhvtjlKZq/UIbadHEnIkYQcSciRhBxJyJGEHEnIkYQcSciRhBxJyJGEXluSkCL9fGYd68rPcxfPcZUxPMINklPelEeaLoQd
# DATA AWhGoPMMpjWG+byTTFkAfeWQNx9vw1KSqFWFOKiSzNTxNS1IWzwoJm1UJnL6pIU74+zOOBeO2rijzu6o8xWPOm8UH7yZI9Dvx6x1
# DATA wWdp2QVZPj2rj0K/aHIbt6HHrQYXVB2qr0oyHKncG0wvkmg2z5oOK79iRJq7a7W5W7ZIs+/XizLNrS1S1zz4QdJF9V584S2xZY2K
# DATA styTC1zrh95KuDO1JaTbvNzzKfV9Ci/E9eStO4kSCVzzRJuzi8YW7463SKOHrBV54WMtfpFtBkxh0LB8cvHZO5KaHYSq39P1E1XW
# DATA Q5V9eVWqP4rCbAnRaBysHYRpLlD9YCGSfNSTJMlCbpBjzZD1CY8g9gx/1AmNWTXvhzy4TaJjqjToANGpTlXY3IwVnCZJjfBQmpA5
# DATA WfM+5QUAMY3kAdZbVMJ+NJycoqCpIOJFQb4aMK3CsX05R+qlS5zxxpHrEAfsoeFoxnPoB5LFRnWWCz+j2dkym0eif8iK2eFsOcJA
# DATA nGIuJQGCizSMRyNcWfZZTz3GOE2BMXZnna2nRAgoCYudBa5flXO+Tt7ama+W+ers1dfCXr2stvVzluzhde18AXa7tvV9Go3YaGQD
# DATA ku3YLJeiYI5CtkXj+rbFfl4KvYubkLVerdfXLm29VtPpqvLW+aK/NsfEolC2TwSyKNe5XNSazZ9TMmkEqMlLQfS6mve26AbRLEnE
# DATA aqJwBhPlc4gIidxLhsGNMaNCcOTqBjOKrK5YCz+TDZeQzUNG3UN6gyaGXK7i/EALsRhVJ+MOf70UTwo544whZwyV+lTnzXPevGLf
# DATA udGKes6ChswDBrg4mUxEZ78M7FbtJMxyCb+a975wutlKWifPV9Dym6fJIBqCxi1SdEn65TISX86z8LnvxwbqbGi8CxpBNRNwGi8E
# DATA NS0jqcdaLhyDJTfyo3B5RKPmpzQMa1pghQMQs0SWexTeAR1GOBrBKcauktzlacbpD2YY7xfCr10qWkQ07UdDiKANo35KI7JQkXkI
# DATA ZRFA7FDairKW0T+XZxQccEhVAX5Q1hRUpkGmrQsox8Ffk4qzVIlPkw0wnET9MK15H8J+QjSpklLmhgoENgzRwQCJ0J+I8NqYhfHW
# DATA CRnyx8xSLRSXbAbq9ZdU8PEIOm/TCGt/8WArjHzMqtZceWYLeHDYi2yS/DmgHMlo5B3RkKWTKPskvcmSMnUQQrGR6zHw6uFJeCqO
# DATA KR1PVYaZdutw9vE4QMGomFO+ZKLADf8Sq3AfKllDSGGmfLJAVVxTnQtgjQXqD/NGvD5FINrodVap5pFGxhbIhDMfPBeqhuCUaVlk
# DATA xiSU+BhkEpZ/iif0c0X7oTgBOWxnEKbpKSs33qc8C9lvpwISwrzA4zTH5zhkSb48kz6OYk6V+ImV+iVcckdJMrTc7fLWhBoajYYj
# DATA aWvFIrwa7Btt+ZRVH6mP+e6lYd+I23XDvsUuj6WBK/3CeAZwfDS8Aej322DeK7lQtXXkBhjfn5dUSG/kTQz3/hBNQ/oYGtdkW04m
# DATA xJzrfRufAvrcUBKxQjQP49R7CG9xuJq6mySKvxpTHQsuk4Tp8Ai+dRsv858VRuYbhrqADvO1d/b07J/Of37+m1WezH+l+/5w9jtB
# DATA vvBdTH4BFeabsz/Tx6+YJfO04hm+zNOzP519BVzNU/xU1U899ejrVzoouo1e+MvzXym4DMXj/O89Zsz8DmwaUGgcVOYlwDTONLNr
# DATA xRc3jxIgoNXIvRCB6Xf0fE38Hke8bRuDnIKGsXYvywvn5C4z8FH09FC4nA23Umbu8y35mx1jpjCbMz3DbVNmVsvl5hgznEBz1/cg
# DATA JE55PRmV7xtC+9kAvbDfd5GGp9eJlqE2kJGNnYqAOc00YI3xTAwF4eAy24vq2qkyphMaxmTG84k9MXXIfMVTELmPH3lcL7xPeXuA
# DATA uG2PsD9y3aZyYR9Co10rfaPMZtGCNc2x94PG8GyFIbOt5m22U1ba0PPix2yLvqPHuCH9mYZ0jZO50kj+evhkb28Uv4FBfKcxfMch
# DATA /KZHcKmL5WTn2yafY4u5CaRMOaE5WcZoTuQxp9yMQoWYgfuN5Qbg6ZpRkWayWotkGH6GDKtATxzHKeNiUFgaK0MpDzNcxJFxQxTG
# DATA aqgMrJeAyJzC2mLfroR4JNvMME2gj/2JeNyO0ojPA0i2661uyrdOoz+kEPj7hTySQ4z/nCWpZTMUMSNR6mAxDhbjYDE3CIu5YMzY
# DATA DQl/oWV7q+b5lTjVz2ScOz6M48M4Pozjwzg+jOPDOD6M48M4Pozjwzg+jOPDOD6M48M4Pozjwzg+jOPDOD6M48M4Pozjwzg+jOPD
# DATA OD6M48M4Pozjw7wwfJh2p9lv1q/IhxmNRsFw9BLxYcprzjvRYexsadQ9v9UZNzqN46DX/D59L+ZIv9PpNIer2dkKPL9bpwztHAfN
# DATA 9vfpe/E5qpvdvuKycFlKWUnBnQqHJSjoSjR7xTJuNksR6Ue9TjnAIGhcNcBhvRd02isBdoPrjWGj6V9vDJtSda4vhnahUFleQx5a
# DATA hXLJADeUslUo1xJDu1CuJYZ2oVxLDO1CaUjg19dSLhngxS3lWmJoF8q1xNAulGuJYaFQWs3rbSmXDPDilnItMSwUynXEsFAo1xHD
# DATA VmC15V6xlP1GKUR1IVW5Xx7821GjhOJq95phcy0sbR10rNVqWNAxCT81SDDLSNGhrvDTgtazBdDq9qwAWr3LB1BIQq/9jEnYLYDL
# DATA 8MzERtM8MzH3LJ5Z2Gw3G1GRZzbi/9k8M/rai0YFnlnUHYb9Yc4z6/Tb7Vbb8MyG7YEfdnOeWXfQDIMb55kpr4fa0GBmQuKMJ1uS
# DATA HRSW90IvUpv5WZdXKtcs+hdDLnPMvheRERuHFYlJaS/KmuBsRyQv8hRDV+u+F0fDTF/W75LTt9Pk+CjabamotcvitBVqedXZ9pno
# DATA OlJ0OwcykV9ZPfQb1iKxutcPil4YXV15j+U4HCYnvBCDFbe6p+uclbc9dljwrNjM5jbsp9OTWJXb9c0MNDtPL/BoWLlVqpM8WQ4c
# DATA CM2B0BwIzYHQHAjNgdAcCM2B0BwIzYHQHAjNgdBebxDaY1W7Yyq4uwplhs+U6AonSV3E0T1khNwuqpt3qWOjOrOHqhXfrR/Gb/ET
# DATA h/Gbb+4/xkW+7TAe7Z3EM7KuyA47nS+S78KI/xRQjOmPOJz9x7oFze8yaI1BIHvNoNfstTtBr32Ho7T/Hf6jotC/CxvwhzR7bwTS
# DATA 8fr7h8Pksbyj/Iq9/v7hE5bN3Ov/uP6Te3fpXfuHIvmGC9/moN/0D59EZKwrLTgrLsJ/4wD3VDz26W6lPjpf0qinur0nEj1Ujrvq
# DATA 558m8WyPeyvKQfDh0BjeVD/KAu3eXljpU3GEb/YrZD3mlrxK7SS+u9GancQomElsV8i70jyo3OhNkjaaOeK1bOPLjAAHyNHu59hK
# DATA MBvuTeL9Q8mj4u+8Kk0Td9UV3/Pr+8UbMASr+LyDe2tyepoq2xONrDNHP52yilNWWVVWMYeBnbqKU1e5pLrKRlHsG1Bd+RRyXFoB
# DATA ZJKw3gdrdhnhlecr5HUbdDo2BeiqeIK8ZMSJuQBLpx7KeyT1vaAmu0Kk8y0gXdvG0flbYHRsvqDq4wPmHyiKEoxO3ZPD6PRDK4y4
# DATA tgT1SEykzSw5HpPeg3f9ojt9UQMmC/SiG1lh97OTaEKd6AX3BnV174xM4NK9u6PruHqjlXOJvrTUur/VjAYZjzKyHqKhkdoz8jpk
# DATA ZBlZHDHfy1I7TJLbTbaHRWy8LFmmYPmOBKcC/W2xGqHhkPPpxGtBRuJMyfhQEk89dejeiMXQO1fUYsaNe7b+D6WpQQUz0YXCFpmd
# DATA m9ZGXVUCk51oc6+CYkg+ljij0xmdq0Znbl04q9NZndmF9uRz0/p7wKghjiS7uIEcRfU3RqcBkk3jQZpYEnhLtlCV/l1IrWs2AN1i
# DATA VfvODIp5i1KDoYaUsJTcIJlOo3QQ6zGQLdc0wkoLNi7srP3HKZvfeyDeqv4pfGYRdplgGDUAJWH/0mCKvRRr9LfUebdVE1W5Z1ET
# DATA +ZMyTpXNoX/MDSBzhQ8+A50WcTgqfrLcIIKDOvJrbU/j8wUnSH0uWp7WHaajtJ9aMezgNEVbAGtK7ou32YHaOH+XDbhNdw0SEDeo
# DATA uRzzze/kXzc/w5UId3+CD1usSxmYtYUnLlTbJMEgscW8K5Qw9nxIg1ZHO3OkA3VKht3BHmtZ3VF5aedFCQfEu2FMOxdnMNemdMm3
# DATA B//88/+7bVJRjrbKWWWKKalKqiDp4lSMMbLveGQCk0dbkjwI0bSvCrtryPNF7/5wCGk8elpYQAM0Nqr9PFFkfjLYK3iQzT8ZHZmI
# DATA oonJsE3pLTXv7XCWUwFnQ5mUyk/vgwiDlzTqNMgaSpA+dnKlfC3Vnitkb3Nz9hbqouQy7GWx4Skhi3Ci8/k+82RokJhXJNf0xJpz
# DATA LcQmgEU8jWwo23yy5NkzzS+XYtEzAUl59L378RR5NSJrLRsDVsWmNy75Ab7Ok4xN9Jr3HuCLeM0wzgbLDAXEIcmi5HXksmlvl83f
# DATA zXmrWq7OVfT41PUu8EHn6bvY2xN6jf/9jw2wkoaUJ1g8mIFnfgJ8ENWtJeUdlYVM8TPPpwLtwWkh6y+DiOYgNe8T6rJp6n1fKrZU
# DATA XxCgmJPE5xU9uDcOvbftO3CGUNwlPJNWm7xq3vfpa8QVmcr/2irylbN4ew9RyObPaaClSQYFkeo8NubsiBp+VfScchYYtAOpfqEy
# DATA zSUPZcUnk75A7kYlhZ8mVOhxTAjlwY+hXYqTgRnrloYmkHCmoVQVeRn9hiUUiRtn+lEskqfgkR3HCbUQ9XAoPc+L0Xm0L9V5/Otl
# DATA zCufevDWhSAZTPWXxjhUbK6AbANpw0imQ8h2L5vEc8pPbhzctwB0xtObPuubao8gFFQxqosSK3dN3lG0kKLjLMRCYpZMI1w4Wkbc
# DATA ceDpeCYTFeqXFtfSfdz84PcOj0tgIsWmaptuUdwai5NEOmTJWvTGmSA0RSg5ilMa3U4Qiq7HLGMbG4Vfmq6j6aeq5ZMtyKrOeCd1
# DATA TTitSL31sZrcUdh4YppgIZfnDugpGDsh3Qts1nLmFs0VWTa2zRVzRTLrHjUwtcCrhYRl/BZT0TJfqbmNueFJodQuYj29Ci6XfLbl
# DATA XC7O5bKGoOC8LK++l2WjA+WFIioUjgqsjpQTm7XgTeIFjjizEgojMUGxVKMJu2DyB/k8CWfs80YwvMha5Rfxk6yDH7IqyUdf7r1F
# DATA HWm5vemj74XjdV05y2edy5cL4US6wzJOYuVIurTfQYLaIW87nQ10VJTKY+53s8XsuTzWgDms5/gLp0etxIyDew/YJjdVBBDkcHZq
# DATA Vq2+n5wAh3yq6s53Pb6whHeKrKrveu/Q/RF1pjCGYITklvB3MQmLp1zhZtmJzB4W2Gjn8dIx6+/Hiuiq2VSA0YZkm4GPC+0yMrz6
# DATA yaNohRdVrC3vxwzMZAckZcdysKBESrG/DktONucyYR63Tbn8T4yl/O9ATp7/1gOR8uz3Z388+2qVcFm686858BL3V7zzX9C1p/Tf
# DATA b87+6J3/+vyXZ1/jCdz7FLf/SRCYdPs3Z78//3eAV3r04ed025/lVsexfAlMNi9jv3+qDiCavh6J5sk59wQ1T3bLe9lSJqyyIZ+5
# DATA tfIgN2CMGTyYsEdgJtOoESas3ODgJ8PSwpg3z2+hWL4tMmCCynAIy6IJJ43+tgGWpSK5OXol7IBjq7tXFY8p6PJT+QlVBc0Tn6oq
# DATA iSo4g0fsWoGWvFtiHGbsrwH6RznKlQXjoJa7luC14y3vwy49ElvFsKMr3G0O4WDTgCDTZ4mh/W48GsUDbMjHtmXZcRNpBri+dRZR
# DATA GPRzKu7+FaLlTnVws1lSbF3Pi2u5UyIc4NKN9c8w1mu85eWH+NfEQ3NLw/t1j+47De6XHttvbWiXalnIhhxz+dzazU1ALgtpxJQ8
# DATA LCYM20olAQh2Ol/IUDhP0fWAUzcO+zEv/C0yXWr0xNERFlgeUjXIZB5P9Vgtc2O6LSOzGYEnMVVILH8J4S+D4l+6K+IS2WiYgJg2
# DATA UPwn1NXjDBvWQBTaUceet72uYCVVTaoWjAVZEOJYskQKQkEeIgOw8plV51FaZauOSmA55V720DITcCOiXCWDbaPZ4BiYjoHpGJg3
# DATA wsDceYDZaSZzCXv49kz7q1j212TYOzimg2M6OKaDYzo4poNjOjimg2M6OKaDYzo4poNjOjimg2M6OKaDYzo4poNjOjimg2M6OKaD
# DATA Yzo4poNjOjimg2M6OKaDY74wcMyg3YiYuXVFOGYv6r1EcMzCyvNOZEwL9ea3cspio0gV65QyvCG/S44XkWXNbrveWZPhwG62g3Gz
# DATA Oa02m57fHQvqzAKPlWlkOXissQJ9q1txLSHVVuJab2+Ka7/f7rbClbgGAcW1276uuPasuHa6W+OqYHZr49rsd/nXYlwbft0LqP5e
# DATA T1wb3WupA51Btx36K3Ft1q+zDjQ711IHhp1w2F6tr83eddaBVvta6kCn3e13+itxbXWfvQ5YwVFozXZn3G7Uj/3297slPC51qIPW
# DATA 1SB21JdqiJ10yxbErtmmbqO7A8RuOGoVIXbNqDms5xC7Vqfd6rQMxG7QHUT9QQ6xa/Ra3U5w4xA77KGqyuqGHl2bFr/OotV12ebM
# DATA 778cl67sdG3kS61tcbpyyHxOZTdfanubL1XPCfNAV1dllK9ZTzMwUVBTrl5rhQ4HnxoWnOQ/Df7dcOHiGdUprytkOKkMzSKdTtWa
# DATA dZS9qxHjZMVALeKuLQLj2iv7CzbC5qwS2GKbrtYYx5dzfDnHl3N8OceXc3w5x5dzfDnHl3N8OceXc3w5x5czfDlWb1QoOfZ5UqK/
# DATA I1/58B59vaN/FdAcG5tfvPGeOv43NCchcViPSWbMZBtE8WSPQ2eymuhnZrUv6H+z+wvcJsGqHxSATX1jOIwOd0gTbo9P8KwJ/E45
# DATA FA7GejTjEcHgzpwOojtov/mgvTtg/wofsL+s+uELc/A+d2xtV0NkkTc+zTqjEYosCwgsj+n7Ni3E53tO/yU7sXqR+k7uqLwJbcSS
# DATA CsE1CyOWdRwuUEW8rwA9LIZAuUptKOPAjLTQJ0t4Y3gHg3e0BBSsHzEbLLRUv6F7QJN1jNPe+3Q1gci9Vj8UmShGNCh1Baq3iRZw
# DATA lhPlXNWVeAOyn8+U4xx6XyoEnkadix7NZVqhVKbLqodblZRKTQ7eaxt+warbDxIa6cbqtLpsftXi2x+HkFs0Mv1pdBKmOFCvBEVP
# DATA wokczQ9VBfUmSAhzEtiBHoepCFNI5IvnoRchi6T+YLlAkswh6LJG+WocdS4basNMSoIpNtxBYBOGhy/DKDRS6mHGKg1KWCtkPA2f
# DATA Vo8XW6L3Aag3l4gcehETMUtIQ1ckCGBmVPhhqgAGySRTPEZD0+Fg0ofeCXohji9O22+J5CfymjWZ+BqdWLdDcTays5HLNnKpVjlZ
# DATA KidLdRXreKM1fmNyVd+LuQ2wkRAqoSetYEM59tDSrrplTcTbgAOLc4chOLAe0wg5B5XK7Xhg/ZjpncyFnHDbrF+ECG7UxZDdgRIs
# DATA Xicge42DiS+xSwgvvyDC+nkTYXMhj3BrfYQljirKfjnK9c1xZteYXXVRtfb4xXfEM7V/YTYXKcz6ex7nYG2cW1eNsnaY0Q0frfe5
# DATA XRDjPAATaeuSlddro23FWlUfHelWIc4bgchvL+PJ0BrR0Fu8vFzkj2QYltE9nPPRG17A1nMpA07m3otPiSh1KEn+mB6KwOO6742i
# DATA E3Zps+N4YTyq0MFaIyR/lLJQnRn/Z9GxZl4ZCbAfqn5dd4UAroXAomP/LBvkNe//JEthyPMe6hmtbpbM/iF2BonqmmZkiitbOlJu
# DATA LJQieTObHpjS0TRDOHDxYtOU7RU2wu3R1RnhzghfcVSvWFvODnd2+Daz+sWRjVWDnW4G7ANDW7BV4IHbobHKtMLjfKhTEqWVXMWU
# DATA hxojcAq9TuytwqiDwOci2YnhVTkR0eZGAkTJlrFgZuQwyCbN1SvTk/OXcsOGBH4flULPImh0Hjp+8i785Bn7UPGEeFM33ynuZJlC
# DATA 4NMWcrJ2K1rOP1BsX3yCcp4bl8RIfrYZIanzVSCS9wuee7i0qcoASptGKKYSMDWNjijHjH+W/bCCxKL/jDB3VuqzVCMzvpFumy1i
# DATA mjDLCgTPlWveO2GankKUNZkV3eNpyMxGtloX6anyErMoK/ZAphIx+MyTmfaTq8mD3Ujz1R/dRPLVJbMHUkb5Lck3+atVFOkCb/bl
# DATA hhmCcWpmIs/ECs2r8iWL+b3NxawbhSpm4/TPl2RkrwX3GLqgP0QXCyMnFCZrSha7XuXILGS9aAGIUjQvvUjg2SQ5mZyKJHTKysbo
# DATA XDEWmaUeKnPewIcOcmx6xWcqwu1Ju7VCLPQylyzHT7fAjPP+SrdYQY8oieQ0AouVhpzZUImBc0lqEljeTodxSLPAKRuoo2hxSuPp
# DATA EnkcK+dVqFuywo2ZyTwvutDomvPRMrOEQ4PvI8xI2efGHjAsEMYCXHvmtrktobdWrlfugx/s3AdThV3QLULXjbwZs7ezh6cr/a9m
# DATA 20ixwqoRoWk2MsbRNM7mrH3tfcg9ZshegkmYHkFWGsqMs0xz6k+SVPpXaSvSuY5CIJLhFriWdrk+VS9+t/r9nbtVNXaRfQV5fSQ1
# DATA VAPVMNQEa9MkZd0b3WWijUWxQ+Ft4dNxEMdBUSq+dXw0g6tHJqLawoRjhaXBYXSm85T16qnXlWLmeFxH29shYS9F1/rupbpWLesO
# DATA w2SYhidoILw7YRKPrIVq5VzTdyjrIQqxLZQyB7L3Yu/Y9gxmNFxY2uQZLBc1j11+Zi1bbQ8YpOEcec5HQvV+Cu0he7Zy3ZrCK5Xo
# DATA 7QK8n8lD++r7FHME5iCi0T4eZEUE5tfnPz/76uzPZ0/Pf02ffwGeJbCVf6Y/vwDH8vzn+uI6LOY3Z3+i/3999sfzf2Dc5fm/YSjm
# DATA nwWJyUH/nq78mvmZf2Rypnf+q/O/B0Dz/FdMx6Swz/50/u8piF/R39/SOykE3PQL+uEP9DPd80/0kqdnfzn/jcNkvhSOUmxLQ3el
# DATA ukVV8zjo7EB8UTyE9Wl6UOHvR9jsDi/qAMg6BWo5DtlzFZopgvG5hh68cINxzXvv0XwC84U6UxQWYq0MmlwdeCs/850JjV/SEhE/
# DATA R9C0fai6z7htguZKodwcQ5MrpbkLWwt5TV15AFeIm1S148Tc/oC/ehDtWk4gEnadAM04k6jAeyg7GyOc+Q3BDzqNFo6euUvZ3QA5
# DATA k1dJebU8nmKqi9BMBVDd0yLiI2oD1GM+1u99FIXZUi3fUo4tAYViugJKjvpK43vOmDPkLeJJpFzWKfvLyUAaLierOM3dquRmS6fc
# DATA 1p4XUXO3dDikprMLbsIu0KzNq5gDr8Vy6q2ZAtdvCexkCFzKDrg9M0DqZSkXbNzmi9amboLDWUo+JxpuamYXmsiU4ZtaoTjPnGM4
# DATA MSaKx2kfpOHc4qVno/yXA/j025AZ4svR+MrsYbQYwO+9K44zH/Eti4Eil+XD/1TshCH25UE1Cgo1FF9PQuSTNQV7gBe+KW7JsKr8
# DATA +GjnWcb7yDzewyW2iHYq0qiE5Io/StE6eaMEu61Cs4zm0JsOvenQmzeC3txprNlpCnQZo/k2pwBXmQFc1wTAoTcdetOhNx1606E3
# DATA HXrToTcdetOhNx1606E3HXrToTcdetOhNx1606E3HXrToTcdetOhNx1606E3HXrToTcdetOhNx1684VBbzZazWE7uCp6sz3qjLov
# DATA EXqztPi8E3yTQo9pWPQGIjPW47wcnArdsJdnbNAUHSr+JWgX+YW94SjqruYymIBBY+wHrS+rXa/le4Hv+fUe/2m0qt2mR/Zxtdeo
# DATA tqqdXtUP2l7Qq3YCz+/Ql0axMNrdbqsXyTuKcQ6aQR5nel8e53aQR1nIolbFaDXa0SrKstPz/FZn3O1Oqn6dotf5skeRbTeqAf3Q
# DATA 7lZ9v1vtVFutqt/slWqLHw0iv8Q87LfDURisYx421yWlKbEfqBh3LAhj00pKsY4Pu4NBfw2R0e96jaD7ZbddbVJKGj2vTmnqen5Q
# DATA /7JKZdFoUgp9r4RWDKNOs702bq1uJ48bBWxlc8+qGfUiLdJvDprtK5AauelpUqO0YovUSHEZ9HYhNRaugNQYRN1oaJEaw/awM8xJ
# DATA jZ1hMAwtUqPfGnQbN05qxN726jaThgZcy8cltrF5SFsyNpQQqRz5pRlxs/ttD/+SqeGxuZEHocdba4lRfmVzckevf2DFb+1cgkOE
# DATA oLDt86/jbp6DaNP00DLAC65QVe6XAyuK+yuHQpbypEV5Qv825N/CalWzZbCRnda31xIexVikNMucL18utRaw1iMcN6IaL6wM2p5c
# DATA XwskUwK7+HYOp1Q0PIstTYYcB9JxIB0H0nEgHQfScSAdB9JxIB0H0nEgHQfScSAdB3IUonHf9avCU5RNx4A/kjWjkY8P9Hn3k0j5
# DATA Mxn3uKdwkbiAJyQoVNX3sdFvz2ck42Aq7MdCIGquaoUiVy4ORkRkIZ6sjtPLUXtvHkeDSJ9GxBk5+A/7KI8iBzI/eeNOh7vT4Tuf
# DATA Di8f0XIHxd1B8e262y/MAfIH8SNpQhUan2anWPKP5ZClDb4xRx4t0VQ0mYkc6sSzD1dPPeMoKPe86uz0CKHIycwsnESXlM82qpbi
# DATA euQmTjcnU7hG7XPeTjl7F+Vs3lHCVREfNt+H/hK3/Yj+btHMpkFxIfjDT+Tjy6CXbfLgkiKRb28WiVS5KQKRb+MU5wjHujEo5XqQ
# DATA 2CzjkeVOVQXnwXE6H1xWmvKcQsBzEo/kBHOyYApExkMTXFAIxhtFVI8mMIhowpLIwWNOiSaiPIt25lWz5J0ds+Q9rQlKY7LOkLfD
# DATA CXQFWKuXo0uNiS+YM9eyhMOyot4I3mV6GjnFCyQ8rwNzjoZm/KEmSNZfLCfzEdjsOjJGt4NL5suPNueLtChVU5ZDtkzyOjILU5qT
# DATA ejOa03roZxgMCulWLEhAZiCH/8Ci4SoVzYRQBkGCjDki9HmO/v74VBs3z7GO/Ksd68gnyZI1LH66PMrzQ6tNz7X6dDIdYdMIMA3U
# DATA CcwxvUKDYJqRwhgNydSgwWxAGTcZJ0uceKt5n2FCwNoKrJQgdt3RJPyZEep4RvXZvCu8ZP58skV7VneqkkM0v/bm+pLk0Cdpcow6
# DATA QGmm2c1RZNCxvEmOKk24HECF4/7MW86QXN3DQCCYgajAMk2gvA+paF5cfo7t5tMd2w1XaqXcYiFrWZFhmiyhPr6EUsVEjIeUz8jC
# DATA 3w8q1nCoexYoLcfSlbJZZgvxhlJdqL8u58ftStm+LgoNuZntJuFuEr7zJNzNuF/xGffGyfQLLdnG+1jMjhahsvKulntvUYMul7De
# DATA f4nkmm11XdlKaW0OlQvhhL+V5c9W9kVKhRkk2DkkLzudDXRM1Enjez9Y2VapJ/mr6nLWY/yFU1MY3ycFshfgE8x6YcWxIVVPmsBr
# DATA /0L+EB+d5uHmBdWte5nknHYUtvXMliqpvgXDwWyg2mKo/fM//kdtRvArx4FI2YkF6S2iyYSnLgo0IYpe34P9mXlHYmWFC6ZFDKHC
# DATA RjOW8XLa18UVeun4dDGeKmuWDVaeGxzF8rNYfixGhmkzRM0szS+P9zxCpEtJI1cot9IoF5wzaoB6BVowQzm64iRMVzR1iwXKUCNj
# DATA ODKx6jWU1bKCcVabs9p2ttpW6ptbO3FrJ1ew2DYahzcpvsuAppHS0Wcxd+Q1L8QXNHifvyD8NkMA5/w8e61lZelEbEW2LYeFa4U1
# DATA DVnqp8vvU//LZ7/5irc3mF4EutePmu7MXDArDHJApIyM94ugexsZX6/5m9df1IYCO7JyaZfYmodNdPMrJr6964yu2nhBv3+k9X8X
# DATA yaJQJfa+fVG0TSAm2vmVC7K5bsW7sTXaynw1C2ayK5VXuaTKR7zFwzSFzEJEoYbde0vOBKs4q+3JtlMtvyT9TyyoqjmN3cqIvSNB
# DATA PCP8SWwrRmnlXYCtSv3DzOwvQeMzxu1H4kw1Ss2MHD4Zx5Mo7ydiqNUusFcnZclbs9JBrTnKxZtZHlitcMLElY0rsvWNTN1SFdA7
# DATA rbyhQvWZ3kBrB6NLtfoeStVySvdje3AeDutJD8IZtIPnlIAY5xTDdM4Lvew5Booc7sqTcSQGfN5xIWUQmuZ+jRe2yOioeQpmhxQa
# DATA oelsOaeuR+kHF8Wl73C+vy7WswXh4jk6zyFsDtc/MoPr6/NfCu8K5Kxvzv5JobkA5wKL66tVAtd/pdueAtAlaK2z/2GFQ58YsPUn
# DATA ukdDtv5y/puz/2koXWdf0Y1P+V2/P/93TOjCSQfv7HdnX5/9D6o04cQBt14K+5+Ne2vrBlCBaQK86xT9BNc3Y8cwqTWDPDl1Saze
# DATA Rz3jTFS/T1g3XJYutOx2RXFDj9DYx2Ef/ZTM1kUNm+sMxM77EWYI22Bbn9NdJkIOtVUw/fOe4bZpW6VSuTnWltC+Df+Jt2Rbb7Xu
# DATA /GlGxa1vLFaw60RshQK20nAFtUAoiXF4rQuK69rRWp+EZHTiZ4p1q16p1+s8alAGUBdV8z6hAcRYPUyw4EnXOJxjLVjv/F+E/UNE
# DATA UnDUmYFQoLiiRzQQ4GxBmaF1YXXbbKYUG8/zgmddmADHzXLD+3UP75qZdflR/fVw5t3iiH7dA/pO4/nOw/mtjOZSGwtJt310L1Ib
# DATA uglGViHhjPjJFLPdTiZNusNMLZoNsWjWh2UeYidxhRIaA+lDjSamJExisKRmQ/3aURhP4K8chGAVMVuomCyMtqHJ6CkNcHqBOZ5l
# DATA cyQJLlJqIbvSsvKQWTMgk/dR/JnSxFvRx1Tn4F6hi3ymnE+bs39jhhU+nsMumRA1D8UBmwwZmSVmQWbOilOKHpyS8fYInrJ4GKqT
# DATA 7JEYhlGGfYhxNsY6ZgivxkC4K0hXPMIGxME4moYe73xnCtecxyKH0nIoLYfSukGU1oVj0E5TnR3N59ubBVxlEnANcwCHznLoLIfO
# DATA cugsh85y6CyHznLoLIfOcugsh85y6CyHznLoLIfOcugsh85y6CyHznLoLIfOcugsh85y6CyHznLoLIfOcuisFwadFTSb9daV0VnN
# DATA UWfUeYnQWYVV553AWZyxHJceZ5ygmep+QY6i7XeLGd7o9TbneL3Ra66CnHoBI6lUUBZcqlPv9nr9dXCphgQyiFOWoFIva1tsqQbH
# DATA kw/MdYs0qWGv0Wmve77V2un5Xr/X7q97vtvc5flu1O+EfjkTpkGz4QVBu0oVu9Xj6h1MG36r6ge+x9eqcq3q+42q3+xUOx3P7/p2
# DATA 0LxhtITn6g67w966HGRcWKnmd3pes+FThcervfq4Vy8FZ/JuJbjeFRBY3IQ0Aktao4XAarTb/U5wFQRWPepFoYXACiigTo7ACob1
# DATA YTNHYAXdtt/u3TwCi2ZCVfp9p0l7ENBYWfRbFUYaGfF0iB4fkDPcJ23DKeNTJ1gHkGrXyrpAvOXkccllYo0BK3eHJbPfmOJdZYrn
# DATA D+hRuzwPXDfn017CLnsJZXUQfsI1i23tYiKKCwEyR/TsiY8y5PInzDC4ZsWujOFa6/HRFbXoYdgE7TLOYxUd+I2t6Rd/vyCfii9q
# DATA IznsVyxsPdn8vBmnL3jNhincZqyXqeA74bi2Vd7N0/pSZV5XJ5eTCyeXHAXH+XKcL8f5cpwvx/lynC/H+XKcL8f5cpwvx/lynK/X
# DATA jPOFuqBOyEfDQ5v6tcCSKWcEUndX6nqyTAcRKgjXqsN4xEamapj3WnUYPIsxYAXvpWmCOL6rLC80LzJ5qI9Oj6RPNq+9WzKmrTkB
# DATA m7AVTC4qQv/CtkYuh31hjplA6Dt1FV+8wXaNmOfe+/nRf7KjT7M1fcH+4RO20R/nscFWy1E8o+xQVDOWEVW6D8dW8O+g86HmCpdq
# DATA BecYp6GcoeJSx1v72KNM80t+kRU/JahLXQ1OQn2cGPvUO8GZRWV90m8cQarWnPs4tVPVP9Iv391md3AZUvnk6bqbp2z/cSEyIkZl
# DATA 4qBFGtWbcBoQ8RCr//CJMea/eMMEXkPc6K3mwpvUV4HCRteotefHIO/IjTo3+OxROb0quaaybW0vnM51hbdbMDSZw+spILaXJc/2
# DATA xIYeLNIJTfn+7u/kKzYD0tf9v/kb+U6PUp5+8cZ7jHh4Y//xBstbGd3UFWaLB2yx70mhOol7p6ZwJTUFp6LwaqsoXFbd/rmqKxgH
# DATA rKRIxPosJfdFiOp272Mtw80p5YOsS0hbxpsT8q4+u58rD0gs8dC2Bx9wu+VtXlgU2vhUITvEWLDaXv7UHcRU6xDy0diNAveGxKSk
# DATA EKhVbxe3f+HEJl6Cw9X832smJxRFMa6bm1DWGllLTbisStbnaaxMt3jGrEay3WDMGJUsowPCymUZLOATCJlNl6LhcMp+6ooR0JfK
# DATA qCoPVxSMkpko2luaHtA4CNmiT0YLhiulEbvRmcClgFts6Hu8MMh647PoEft4lbLGhRyjV+OcvAnBGXfOuNvJuCsp5TjNLKeZdQmr
# DATA bqPpeFNaWh+IYBNVbDWXV04EruY52ee2FRtvQ+ReeRZ05uqkv6V3YmjFcX0bVNPFU4bL7CwrCKxTRk4m7NFmAALWinl0+xu4mA7R
# DATA p8mnA3VBWdTyrSJ/2C2ubvuxXwkqjZ/QoKhjtEFSXjnV6F0f8CeuskUEsbnF9K35QysE4ICRDSeJx1tJtoCHm2J4g3tYunMFFLxR
# DATA TN74sPKq8/LqyGPKI/JSykZaJ3G2NAJnc2k1FSVh9q/C4/CBdLFKzQyEFe0GRTNR+cB6byezohaaqGaFgLTYLjmlj0UDJkTPBJE0
# DATA OVWOUNPcoXAlAlz09AlOd/HQyZpTlvuv5pniwohINvJysFgqCtMknuIibzSCYBVE4ph2Ae2uTEelVBHyqYhtJudTCymtousUc0u9
# DATA wm9ch2rOZ2rOxbLzr4aFmg8zzkR1JupOJqptizgD1RmoWw3P5y32+nGhkcww0C3iaQ5leiDLpCyAWrEogJI67z0tgwiBRRzf4eyi
# DATA 39FUhgmP1dDlZLXQ8IjihS1ns1OjB7mjgitH18RGSFBUCyDoKAYBNVZq9xHrW6LzWOOtUyeO11iqskcBFYw/KTqQsmT0j7lxZa6w
# DATA 9ASQ8xGHo2Ine25Mt7SZVWQ2PjD0Rz4X7UrrDtMl2k+tmIzYOYDRER2j3BdvszDRIrUvefNdlo6tYBzN1y0hR1l8xGl/lz9tsV2L
# DATA bHDZSWAbLIpmvslsLJQxdldLY70CgF3nxiUB7I+fbCawS8YKgR2TuEgz0pXT/lST2D/DllFKebrMZLsX18AZa6cqIV3MgUDm1CvQ
# DATA MTZhhNhA4fWXZOgqxdR4UPPejVlgdclCu940znj2KHtdsF2JKaK8CUSucWvllWEhMQBBRK9LFZ/tmdH2pRp0yQz+53/40+YcLtRG
# DATA yWiWdE0jEf6FXzUexAuDvOdfcvoSa9+SUS1aqslcn7pfUG1LWccXh1cXsdjn90d8KJzmBtN+fLQE91G5fiu6uxNUlNAfQzL2WcI3
# DATA HvJvMmG/jhy9Yl2dZrvV1Y/DqVQFSFnnWSe1BVMcKNjKPl9RtYVO9SRaAIklu5vM0x5jPNB7MejjFGhZoXXNoAyIBkHWH0WHek8q
# DATA CrVBwTSQ51/9/vWlKp+wzjj2lIovl9Ey0vn3IWZwmLTRBDpXYj4JY3bm8AV13DwCAPpdaZC8JiEVJ8srKgeMrB/haAHnJ2XgDC4k
# DATA DmghTwHTG4GiSEMlCu1aqp7p2i+ZkR9sqXtqkJA8LK9Qeos0PKZx84TSoDPzU3WUYKwEskOplinZMNEwU0YB9XKzBYPjEBbsEpmf
# DATA UEOemZ5B9apT6jUynkvGkHi0llVzuNwiVnLuEc1/tQo3bL/nmq+f7ZqvnzGBz1quwvnGvHWr5bA0OsJ+cDkgQgnJ1JCB0SZXrzeS
# DATA 5xn7KnLLMBqNOIftfiDsZyxeTTM0du/IPao6ozcVqy9GZ/tT2c1aytCikSB7Fm0jwVyR7CG7Vu8u1BM7draoXX/UEQ3GCfSzQvhL
# DATA qSR1QbwWC282Ro9KIrIJev/p7Jvzf3P29dn/PPvL+W/BvTv/BZB49N9vzn53/htB4/3+7Kvzn589xd+zv5w9Pf/tKlHPDodZeb9g
# DATA Gh+e/eb813jq7I90kXl7gt6jv3/26Javz/+Bnvvr+S+B00MM+ml0UjXovT+e/4r+/hY/M3Hvzw6t9zJ4a6Sm2bx5mXI+jNFKZ7It
# DATA GMSGHxrfjCjfwxwji2EIpR+2FGR9A78/1NtJ0mgQz5XNlS3RH3FrnyYs1r+VpPeOxMtqQA6mZ3tpkDu3zdFbLZObQ+lJ1clXEj+V
# DATA qiSSJ+Wb0RNZa47RyY3QsnlH9VwduqCskAkj3jaNZkvH09uhzK4dqSdmPffl3PXAyyx+sz4ZELp3E3ueu7HP8m6JqmtyoqA+mnDO
# DATA OmuC/uVDByi0eDrFGR3AhKiwDYz4UvVvCwa43KieF2Lv4kQ4xp4b559xnNdIvSsN76/JAsytDO03MLLvNLBfZly/nWFdqmQ5Byy0
# DATA 3vNsOjdB0isnVS+KiEs1ZLnJ0oiY2UMi4r8yJlYEiiWLs7LGKkoWx9EimfMzUcYH2hMylxbjZJjtgsn7FHkoy1jlGFH2wkPAG3cp
# DATA +dMYG0wSssqwZ0sG+ry60DvDbJkCDBaywChlMvvzK9ptn0ZoP5yiUy4Z0cEREiAcK0yq05UhCyeC+xrAWa15Zo6G52h4joZ3gzS8
# DATA XUaPneYquxq7t2q3X8Vsvw6r3VHxHBXPUfEcFc9R8RwVz1HxHBXPUfEcFc9R8RwVz1HxHBXPUfEcFc9R8RwVz1HxHBXPUfEcFc9R
# DATA 8RwVz1HxHBXPUfEcFe+FoeK12kG/0bkqFW806kXDl4iKV1553gmMV6C+NXoWNa5Rbxjqm9/pFLlxo0G3p/KGIhjTyGqCaORBNJv1
# DATA vGwCoe3J4amgVwiv0wwGjcFKQQUt3wuCYBx06sd+s/llte31/KrfaHm9gP7Uq118qfaCNSW3iuZrBRRaqz5utr/sdLyOX21SPfCb
# DATA F1DnTGArmLigszYDuha5jyJvVc5GK8+ARuG932oOgnajvhLlRrvu+S3/yyqltUm1pdrxp60mxf3LatDTV66cAD+4AuiOW4UG3UkD
# DATA s0B3nWaj0WzuALobjtpF0F047A2aOeiu02712i0Duht2BvW+Bbrr+A2/2bkF0B2aVHW7veHx8GLdWubDfS+iXiAOKxJwaTFvBRXX
# DATA 4AWzfLmsGLSyW1acVDqHVhyRJX+/HdY6D/ylBlWPfW91NpzUM2oJbG3SjVt1NZLGLC8i5FTYgq5bv1WgTLRbxaytzRkz8OnVr/o2
# DATA GtwOteCmTBGHdnNoN4d2c2g3h3ZzaDeHdnNoN4d2c2g3h3ZzaLfXDO1mw9wk2Xxg666A1IY45fbG/nfkGy85MpZLIc+SRTiR+9Gi
# DATA 3vwoXIxrPJPc44v7b1IO4DgqvUc50ebQmFnO+fa9wjvuyDf6MeNeZJG8j+14e74dyudymMwKpPzOUjD87MqRM00QkymgOdLhDlG7
# DATA Q9TrDlGXjvm449TuOPVlj1NvEb69qWPW0grYDoZeu6yymmPWz1HI4zaoC0N1PFvVDHz19o72laStbnYzdmDkAvDqqbxvUt9zZkGR
# DATA xTCNWYCupbAN7PuXRSdsseC1qJq/WfhWxlNIMZthDcWAQ9WS/xdEVz9v4msumAj77XUR7loRDnaPLw+qoLRxPDiadOWCSKqHct1e
# DATA 9b3AgViJoW/FsGtHsBi9jbyHd1SLioxo0MuLe3iHrTwexhjghcmJPpD8wQgqm+hD+Bh+xgMd2l5GZsm8wj5NaqUTeP0npx6UNFHJ
# DATA YvDyxCgSb73QuaTW8blxaoYqxCEFQQHCzBnrAAcJjB4Vkj4OzvwJrslRtsC6O0+pWIJpyhaxJQKA0+CswMjLqEOcJPNk7ebQFgOA
# DATA yYbeL0umke6IPqTZyzFmSGMGYHD7HmB3sEoQop33NRcDGl6dg8UOEuss2e2WrLNbX3G79bJQ2OcuD8QL5tZC8KrRNylIAjL1J2PR
# DATA bcU/6PMxUpgiWxmqz11V6CVR4LgJbOqKAtJ1k1PXqEmth6fupoRYqn/IapumwCLSb6dIqxrWWbU9V5DmPT16IrTMBE6l+alsi0WY
# DATA Zw1PC5IuoYeNEsupss9QwehDFilDCYFJTSoaKAqd/D7fYIySsgQ3x/lTFnuVKEeUxTrGH5iJWsxzQIqq6Bkt4rTCyuwcG63KXrDQ
# DATA tOK9jQ9ggxRBkRWAIxhbov0JFua2x/oBoCsq1rxNKRrqiL+nJa6GNLtFbCgJnHsVnvJVvFNslhVVJ/QYi+QogopVzbOM6oSVRace
# DATA gwoU9WVTdPULV2P8GgnY2H2SszSdpbnO0iyMU85j6jymFxmoz1+YUmKQKWXFNEmmrFLHDSKXp5xMpKmsFUmsqXpeEWdFRQYj6M6h
# DATA GWF9mqlg7FnxZPVOtSteRrwcBex9thKUuqO0SbXcyGGi55szdhMu4HCCDQwikO2gYLtAwcTisk2rTXcaPzfTXfSXzfdrlU7OVfV5
# DATA 891axrNofrz4GLE8/y7JcfEP/PZmlIsuDEG5/GAWUWcyZ9diFUcWtWWI9Q2/5R3ZKxlBs04XlBvx80gRyGgKgq1yk9MK2e3Y+9un
# DATA ejHC1wXGS4SMPSQZ1jzkVEfGPQSMrZMwG4uWqrbQ6dJkkl0HB+dW8u+zk4Tzb0jj1LyYe416MfeaXSv3HvBCDZLNfa3KJCiWAui8
# DATA YDlKkcaUu8QvPImAL8JmXU8dwhWh0mvIrUIbvHyGtTZnmNWgJc++R30qxe79lKeyc5nA5PkWlGpdo9Oy8m0BU4qXydhwimfLBYYc
# DATA iJZOihMrHjEY1kM1j2ZXioJnJmHH2NE4eQHyrn2JvHsHVSAVWYl8fbCQfaVq1wjqpeyr8FSaTdQjKYqM5qmilApin7RG7EcfpuEJ
# DATA tvLqpQHWm82XBp4lz+w+/JJZ9tHm/MpHA4XwSx6G2rrWmfQ+cyqEGwF0n9ALj8nmMGY6WbgPqeFNFNppyKrD02TIJD9vjHVg71MR
# DATA CmamFa6Y5ROzKpPRQE+5zpq8aNHXkW32YHbpmhZszrh8YJSMM46BooGm8/ABriqvy8zzu1TDhjqvQq/R5j1DVFGxLZBdCDRdUo4Y
# DATA sd0YI891LfGOlrHiezE3Vnlv2GzkLecvKsLrVXFI5BivUbyAxKzN8fp/z56e//LsL2dfg7H11Dv7w9nvz56e/fezrxm99fUqsOs/
# DATA 00+/O/sGjK3zf4tbvP+fvbdrcuM48z3nWp+i7AlHd5sAiAJQeCHV1FIU9XJGknlI2tqzllZRAAqNEgEUhAK62ZYVIVkzZ2ZiHMcR
# DATA uxOxESfO7sTGXuzNXmjs0VqWLc3FfoHur3A+yT7/58nMysJbo1/ZJFM2SaBQlZXv+eSTmf+fILmO/v3oz/TTd8dfHv9TAeFQmBTW
# DATA 9/Tbn7zjv8dPRbrjW/r9N/ymb4++pzd/c/wF48GA7FIEsN/Q1z9RgPSTY3Y9Dy6VDOqHLnNo84CkD0lj+ECpSWpc4GTWmbL6vXQo
# DATA lGHRVOCL+5j+xUNxQUq7hQu1h9Pn4ABAoYSfAoeRN6Lyds+O0shPwsFajNd9rIx3w0MTU8fxsn0tqoO4apDXklK5PJKXqoXZktEj
# DATA VS0HMcVzcjh/v9RGffM7uUp6kTAvuAxVTEQLX3bmRzpeDui1WdFdONPrUZSBDjIWxASQVN1lGSoHl5yXorfBXiCREWaogjlFDM/P
# DATA Ib6WvLfjrp4dU+8m02txTqmULpC9Tq6Mq+2ZxVb2rNBeJ6fCob2cOXDx5oCmfZ3NCngpVluuygK4DANgo/H/lMP/1Yz+UjEXcsGC
# DATA fl2zRnUZHLCF5ANqirWhlDnv61NW4BoI1StOwnw635mqrRG8BYJFQuJwYt6kg+KUy4ITilO5DjYigz1mXy/8QdiAk8L1Fk3CQUFZ
# DATA cjSgxd0Zii/qcjHCWJtQDeE15G6GeeIIa1PA7BiBeUCBissDzilq43DNxKMiZTGD2D2yLqbxKNKOKl4+Q+hYhobZUhCbhV4sdogB
# DATA QTlKmKOEOUrY5VHCNhxyNpoDbWo6X+004CyzgIuYBDhSmCOFOVKYI4U5UpgjhTlSmCOFOVKYI4U5UpgjhTlSmCOFOVKYI4U5Upgj
# DATA hTlSmCOFOVKYI4U5UpgjhTlSmCOFOVKYI4VdG1JYrV3t8s9nIoU1ekGv/RyRwhaWnjdChdn54gde1W/2g3prjjZVp96xGS2jTVWb
# DATA kkNcRlIGNVakFFKW7+eUeubLruLbhVfP5b95Zy70oOVfYuitehZ4rZULXFKVBe5X6zYELBd4q9dst3vzgdeD1oWHngO91YTFJpAy
# DATA v56B3oJmLoAoCMNmdaFZ0OOe7zf3a8Gg0vT8xgkEstV1onEGABk3Ng0gk3abA5AFYau+AYAsdwUAsqDb6ZUzAFm9E0TNsgGQdXqd
# DATA SjeyAGRBrdNqXTqATDfQtfCpkh9oClnufjM66gWCYBPaWD4IzRvL+nGdUwuOTOvRNhZlljyz6bJAqa4skIrteKiUlqwJ+2wQ5d6c
# DATA 8yiIZYDneP5ivEl+QHYCTKolHsmK8UhKpswvsyxZ6AsWXlC5reda1Hv7mV0yF/0m23PLuGitVitPQ8Mq82pKWa7cCnNlscbayd84
# DATA 53sw7kOHIXMYMochcxgyhyFzGDKHIXMYMochcxgyhyFzGLKXDEOGukChdAdRIeJlou5uucBOd/40JrM7Snd/+VEBDtX9aJct2AI6
# DATA 2gf4aRdV8rap0Hy6DNbRZHvns7i3LQ/tfKaDphYKEyQcdaLSiCzUnaJ61W07+Nus6qwPbmxL9HZuoyv4cOtxdoytKzixz605DvYR
# DATA 6vdLKeLYx5r3Iv30FCWVlTxoYjzZVr0V9Ikl/ZSAUffG7ljt3k9/CsPuNqUPgb9Kv+18xk/vjm/zmQyKE/34I75G8ViamlyCTdbf
# DATA Nhl+W2odJvTc6LMaRnn+ptJ3prxXSDh98scoP3uPcUgqf/5yQtFnggflR5xI9oktf/vz1a9j0lsnigfb25TUItK8c5NNW0DeVJZQ
# DATA TCjJpl5QQ+LUl9iNu/NZVmGsyxJ3+z7KOJuLl9UgFUvkquSQGgt2PssyDEWH4owpG+NXFTmPJd2QzvjGDX1zaTwj0+QzFfNbcidO
# DATA 2dF9BY4ITaw/wKm7//7FP6szjcDmxTf8HepiKBILwRf9nTVh43ikHfZDHJfk5Y/F0D/P6sLnqo7wZFK3ycWqrB64nav9t6We7WIG
# DATA q6uedUOhEpTzLWoyG4mUsBD6uDpwK6MLr60zcLM2r56a4AzpSU9x+drdhVXzsxyY62fWNYmHUFnN2oNKFKKik2TmgEuixWdQ4gHN
# DATA h0yfqmugeUzGip1cpCnYg3hE08VlgWIljR6K5jLJMWOczsQZdSacvsSLry9xWpLMddCd4JWVnL9+PU7mPRyCB5ED4qv64HS4h1dN
# DATA k2EyoZnZWqbMdRSteH6OcF8GaWZRY+OiUTPLREzOyJrxcktEUqV5he2OX9bSwILZNHJi9DJ1CwQ8pZ5kIh+20PsTssoK4noSLXtE
# DATA 3ljespqXjDGLBFxPWA/92WTKUl+xeu+YRv6R6CckSurDiNivEfo4SXn0BTqin2s4zoRyJtSGJtRc/+pEu5xolzX8rjS+roOY1+uz
# DATA GEytvGyVkfJ6S3Sh7KaEkWccJWhoB/0kN0IJQkAPYCXvLkRsUHSsqRPKXFjBx6In1BzDQdyD4g1Et+F8EAmpURR1NWbstPwUE1EF
# DATA fFBy2pBWLyxR0nLwlE3gKcNEio717tXndUCUCbvRRAJfPq++G7t9hJt9jz+tvlObO4ovxJ+fB3SKnXunVMlvwnBcrZOflUWOZcFe
# DATA PS2Oz7OibGTD+DVJZnv9rDF8wrB3lvDQuKTZiIxH1qLKNkyjPe8nMWtbddg89PQJeliNMxabG7N8L4xNisNeNL0IysA58i84Xf69
# DATA EaVPPHa2W2gBaOMquJNJL0vGiSs8ZZ6hbTochIMnlFdaPpDDw22zATDdjGr0ohGXAYu34RSE151NtLguDVIXw7TImuFp4QyV9fmW
# DATA tWrJt9dpjJd9f8zUmcWm9inbiupcFK0UMsTq0QgsC8lLlqaTxYRU0buidFry/oaBGFGnP4o/nUVGQZEqKU3owEqY9jHt6IdcE5Gv
# DATA U1VxLyA3s27qtHl5Qh3UvZ7k5AdUd1gFUUs1GwypySRKI1chtlAVatQg4cnC7TyBFOScKatyL2TZRYX8G0RqksnZrjTkjKh3Lz8M
# DATA P6sWXD9dC349HLAdoaYKkc2igXHAGZLOxpiAUQLDSftQzQ06orMoO51LHq/UIHdZjnyi2G6Ua70ogogiplpkUUTpOOrETIQV9cvJ
# DATA IesZmkn4KDq4iBy0x77TVsDy+izMhlIFW0HlmpiLmoJL064hd23o7BWpx0zDOiGoPJRRB2Rgw1THDgqvTxYh6heyjFVAWfiQKjV0
# DATA IPexVUztsbm2UJUXyLWRBeH8Gs6vsaFfI1/TnFvDuTXOuCa00gVyaRrlqsrm6K8wxamaG+/GM2dlrPNuMJNxJceeN3rzMgd2f6uT
# DATA i/qamfTyrgZ75DRX9KyXcyk7H4mdIfQt6fXENAi7YhfkHBK8q4V+ZhvJ9DrbanvKjvKL6BY+4g39eIVESj1tekb93czzq3J8E8PA
# DATA hIx7Ml74zB0uDsOnckdZzslFYz6at9p3wptkOCVWmW4cVfW0iar+bqJaOTGqfnPjqMq2H0SWP50UN317FjtzxcSvtix6vhW9yprY
# DATA qVVB48+ScwE8/QNv7ybvUxySiS03svkxGd55VaQVsizEsRC7DmaXcnVuTIP7VI7j3pQgsopsfDNW+zCXVjhwxCSiyWDXMrVzCv//
# DATA iWzTjp6g0sS8h1HSgHRkynAQ0vAO2M6YHiUDDTMwRQXKZrEaSKnohGqyJZRUs/fXQlpiSE4GRYZZ8o4teksXPMxEaKLwohS8bvyr
# DATA X8UYUti9MpqlEORPD8n2TYZp5kW1Y9aPBuMTFo7nSjVbPLb9qtkysOS/7Nmixx/gQ1biZwpMtnJJo4ymVvURG5ZL7OWwyi3W4WxC
# DATA NjGZdDbt8L8xvPAb0AbzDMLj3+LvRdrhfz36mnmEfz764egP3vHfHn919P3Rd8f/mZ78gT4pbiEzDkEslMA5ZI+BiF8Do3j8Bd3w
# DATA ++N/pIe+w20/HP0bhaOf/MPRD8AlfssYRArSMQ+fhxmGqV7ZxIIrPIgnyFF6pqD8ldzhaCQGCycZurNEmCyiB1SKQiOAYWUIHtST
# DATA aqNnHEcdmo2vgxs+1NsYaABgtJpDG1qTCV1gVw03XCiVy0MbqjqibwNnQxN3+JeF+7F9xepwHyU9taflwtGGHIEc2DBOubI7rOFm
# DATA xXbhWMP7T8cD9DKhdoYMk+5sEIK8nkxZs6fkfYC+n/uubJ8XL35hYzw9a/Y/URxmQ+4pU9kGBRdKMg31WlY4EnTMAtDw5Cq42mqZ
# DATA b1nPCmd4chocztCN9OcY6TW38CwD/MvhKbyywf3ix/aNhvZTjuxXM7BLtZzLA4tZ+KxazmXACedSiRUAkIAU5y/uWInV5xznExSK
# DATA S1NB5UBb05uoUxQPb76WbcVaohtW0oi9ovP5tiGR0HhZs9il06TDK448HmtUHPPjuJZ0aa49Sk30o9kk8cIh4994yI/IbIg7MZbG
# DATA czZBzgKInuJgMQLvRvBGqR3Vaq2QrAcqzveiMEWE2LbrTOGKESORvTpCqZO1dVXU7dmh1C9HK3S0QkcrvCxa4YZDzUZTm00t46u0
# DATA 8c9i4l+Ehe9YhY5V6FiFjlXoWIWOVehYhY5V6FiFjlXoWIWOVehYhY5V6FiFjlXoWIWOVehYhY5V6FiFjlXoWIWOVehYhY5V6FiF
# DATA jlV4bViFgV+rBZ0zsgqjbs+PGs8Rq3Bu4fnUpMLA96p+eb/Yan3qN4rVhtcI6O9+Nah8Wmt5Fa9e8aqN/VYrl0sdv13t9OYxdhRW
# DATA fSnGrrZANpSTfgLwa+UBfkHVnyP41ZpZWcuxtYzgFzWjsLMITrT4gM0gF3yl2soH36quDN0kMxd6rRysCT04U+h2iTR9r1Zr7Nda
# DATA Q+pai7XWfq21cU77izDChu8FfqNfD4K5UDpBp93uLEVRnh47KO1GYwelCVrYwXo3aDa6J2IHw167V89hB7v0d7diYQe79aARGOxg
# DATA u9OptWsWdrAS1JrVS8cOmm1qEP7f22i+vobbJ/att2AXaXN87m1moFRTr7ci6m7isCDxWwowDNRKXGWB1oeFxYUXzLndbaNRF0h+
# DATA 3k3mnufDDvDq8scOk63TjXMo0KYTMkWM3HxQd8J5Q8XCBuYja28u0CO6WvYqL/P2ymJKPmkV+D75L/XHnnGvJw7OZWthPk/WmC1r
# DATA k8z2hAMOOuCgAw464KADDjrgoAMOOuCgAw464KADDjrg4EsGHLT5bpJs8WIIKY2PiiP6Oz9tlm9UygWaWaqfDrgId2TKpjFf9+WQ
# DATA DB90QyO7wb+CS9cZIuDI+//+N69VxrduFI1LH9J/I9DWKNw7u+XXPtz6gLXU+RwdL9QgEPpRgijxlIciLGGZwzeIi9c+xL1Mxwvb
# DATA KULcMU/hE7/rHfsom6TOi9Ip/MjRLe+//+b/QWQW0r5drZRvyFUW90TXgCA1yswhxNzZ7pPOdrsz3S/6me7TksKuw1nvORfbekzY
# DATA u2ga5omS9x6qva3tshQO9kxPhz8/RyMvgwI2f5j9ohlgi5IAZyWA5f21+qz+u0ztkoogr+lFRtfmDbgeQ6+b0A/pAZ/RfgAnJKoW
# DATA SwH1w3hS8h7FU3Y/acF3qYAiXD4by/FkVbi54/thJmU0hmhj0uOzyJlozpzCzUI5P4lgKodGbgc20dUr3TyjU7BWC3LGkDOG5o2h
# DATA hR7Vid440ZuTzKjrIYbzQOorEy26icFffJK0jSLOQ6PdQM0w3hsp8pfSUFP4yAkNCx2IW/RwsyhJpCHwq3CPajwOb8hn+Q7RoYEb
# DATA cmBrtyzRTNkY/PUYqjPwj2VKNjYPhn0XotrhcF+b4b4oKdAnUUmfcqtZDftit6PIQvPH1ffy9lzuWR7zp+cB3mXlxSm5K4/W8JN0
# DATA rgpx5R5aBZWu2FYCXHl8kIhYUzKDYEwIORaBrAzRUrREImp4yF4okWUS85DGtX14kX8FeZbJMK9eJCpFZPsl2XgXQhCGakcoGvU9
# DATA NpT1mVNpNGp2sFzYeVEA2iy8iU2SJdDkmJZywNiABWXOGHrAEoQ+H//qzCX3cOOSeygHzMVK10X3LmwRdIQhswGoOPaU+nfKpK9o
# DATA zOo4iiWUR4eh+FjSR9S+qQhkknpX8xnhMVT7org3HURTBRaYqLik42R6/iLLpezqyizrTU5ZZj9bRytT/ZKU2c8gQIR8bCcUIRsQ
# DATA xdJEeh1FC5rtCSOLcpc6cVxMemSNGJ5WLzoQzSk9uE1FEh53yuIOl/QB09+YuWIaHZd+e5Yenr+08ml6Dorr/Y2L6/0Q4HZezKC+
# DATA PuNRpX3R0jeNgXq9PfjDn0SHYu23Qyhoef1kKA0Lk4MRh8YadSOPCmoCWhhQOeBVsQO+Fz8VfBxDE7LCnBd+O3+h5VN2ZYWWjcKn
# DATA LLPHq8tMj+eqVxTlQFzLykv8EdiHj2GAmlAqrMCBOGJYHrmjxgn2xnl3uXx7jO+iTggiZBj3xPLEsSlvPOPDcyyeMALa5QL6vSzu
# DATA 179EKpuWyPuRUq7D8DFVPynCpZwPivQAI81JrA0R6ks8Pt6FFnAogoQCBlSthvs3nlkjAJjdPJTFqTZSULqif3cBbWYxIWcqpqsl
# DATA zJ0LY/Iy+NmsIJyjzTna5h1tdpVyPjbnYzvjYuNKn9wlCU7LlFxmehgBUblhYxoX2zOEGlwSeS7nydJ7T2Dv8yZrLD81ed8Mz4TV
# DATA 7yeAzrJQTHdlXcqocSehzuobctgOtLfMgLt4XqB27W13hicC7iSADHCnvluAu6XYOF8ua3BceWPInezmgbsQH4QxJhRkqBRzXs05
# DATA ENUDmfdQh7Dgs2uUGfuFbe3eARYyeX9Ro7zay+f7/Mjj6Cl6oq71FP2y5rEaP/Y23X1oP1Mrr3ETrkTUadMUu2nJUps+v5A623V3
# DATA 0KdQvE/I8hxFhyVb8lnpOksnAIfQQeL53NLCiYLF6Q1rY5omKdMdq87UWVCcML3igZuCNu54cWhw3yIee+Xu1+ra/GK17cxjwCUV
# DATA WLVS5npntXDqo2Yafqn25HbyNRV600qGnULRKuwFsvCfStc3ojgOZKrIqtnj2QSgd1nYTlLWT7UEsjeAyL0gxnOGkKNeJOpMwt7U
# DATA Qsi9p68Vj//u6IfjL49/A4jc0R8W0XH/shT/Rl++oae+Ov7i+Etc9uifb+ji7/nvrwGOoyvfHX19/PcGCfft0TdKIR0KX2Nop9KQ
# DATA 7TBx197UZ8s89Eyd8f5DuB9697uxnMUS0Xu1r4Rnv71JHI261IHwt4NkMuga6x+e79lYfKdwJYjrbHDIdN0ELm2hiLLTIFugUD0P
# DATA noqeUkPrrkXIvQ4BDdaa8Phv4Uk4jlw2IzCdwlVz5JYXzeXB5PoUHSYXZHBqrq/6+kkwuXuhSIJfBlCON1+R7Uj/0pggriuM5mgw
# DATA Dii3WdFdOFBO8ixkM2eEzk3mVWY6pQ0bNZkaSgdFlouuKLzAR8Mb+l22tvdmITWKaUR92xtx+qQA64eevvfg5146jhQpA8ffKW1K
# DATA FWbGNhBci9MNaHPL6+hqE2dpG7wu2LnliXHoOWc9XJL1oLF0ZzYaXgoX4tUZDJdkL2xkLpzSWrg6Y0Eq6bLMMIbC9Wxol0Gxs7IB
# DATA oDksEnejMThUZMqYgdrkEM/mV2RLJxkOZ+iusYD3DmYQHXZYsKRISvnSiewRfxKxg0K8f8iwVG22p5Geioyv9+IJn6JN040JdwBp
# DATA pco3q2FilCH7ZBFOxM+hfu3RXDnmAw68I+i95BMa0TxOXocyMOlNS95DHW85oKBgYfNO4AW7Rc4KaASZ0bRgkhnyA7o4kA7uUybH
# DATA HfEec9pH4q7hvZzRiDk6OCGP1gUQmaoSlKuOeeeYd455d4nMuw1HrzMd7Fpnll/5TOMiPKpnnWc4AJ4D4DkAngPgOQCeA+A5AJ4D
# DATA 4DkAngPgOQCeA+A5AJ4D4DkAngPgOQCeA+A5AJ4D4DkAngPgOQCeA+A5AJ4D4DkAngPgXRsAXsWvdquVswPwqs8VAG/ZCvRGFDyL
# DATA F1fJcHRyGi3L98acQmnQzGVXLWg1gmiOrFapUAHU1pDVrFe3zvzqZqVdqVfP/upK/cyvrjYb7Vr37K+uVs/86nqlVa01zv7qWvmZ
# DATA lXWt8czKOqg9s7Ku+8+srHPtutW8ygzPtevTvfq8GZ5r16d79XkzPNeuT/fqczeu8jMr61y7vtqyzrXrqy3rXLu+2rK223UlqF9l
# DATA htvt+pSvPm+G2+36lK8+b4bb7fqUrz534yo/s7K22/UVl7Xdrq+4rO12fcVlbbfrql+7UlOhdeZXnzfD7XZ9ylefN8Ptdn3KV5+7
# DATA cZWfWVnb7fqKy9pu11dc1na7vpKytl0PlbJXbVT6Qb283wjepq95p0OjXQ9qnaWP1WoNfqxaX3ysBkdH4zTmmJqAWHB5v54L0m9W
# DATA q5XFmATlwKsEQb9SHlYDr9yvlOdyox1EQbuxFMnePBNNvZrR1MWfY9HUm+UwCup5mrrfqvqVIEdTn+Org6bejlqdXkZTDyr1eq1t
# DATA aOphq90LyxlNveYHnUr50mnq7AwutnmTvvF0ymK7xqJn3tamOKztZ+aB6GYpbtmym96o0eANmtieyUz0xd2OdfhZ5TV8EGyzbRl1
# DATA a1vGSqC7Fep61roUl3JaBmbZRdcIPpbQD7vJwa0W/Yg/ZU+V4ucletUQLrAVS7CVheDW52EWoKe2mur9a7JsZX4dL9l9oNZ6dQ0z
# DATA ywBqL2jm6S7MnSjIL2+XV8PW7ZJa4w5fVtfYyc1+dQdVd1B1B1V3UHUHVXdQdQdVd1B1B1V3UHUHVXdQ9ZcMqp5ZjEq7YXvH2HeU
# DATA au+haH9kwh+3hVjFXTbbyoNDxpWLqEhxmHSjXUFX0EXZZotGnV0TkYkibJDdShDUA76KWZ7IpqW7mo3OU2OFOFe/oVFqQDoiBhfE
# DATA FMJsu00JPB4q2Ej2S11ekEy7CJkLE19QzbltlFIaqqPtcqFe24FxhIMq2zd/+aH679buX/8I/044mI9u7hWoXC1OO5ettwinh6rA
# DATA 7mf74SgeDMJblcJ4MKNpf3qrWoBk3K3g819yVHgaa+LykcbTP5rt7UWpjIssQOY9vPveLYON70TxYBtvuDGfPT8t+U2myb8Vvy7Q
# DATA +tdZ/ifT4Z0LRQIQARya5CMIzY8fxwKV90sVHSQ6Z8USwaggghfQ1BOhQ36hqjPQxJtCnm9K5rKuQaIkBMkWBaTnTMg0ZOnqa+vM
# DATA Kc7guLfCkv3MTDQgkTYnT0tPZ5V85zZGFjiu5jRyIPahEgAlF1vyhmMsA8GPC3mBDqdT53TqTqNTNyfm4hTrnGLdEs2f1SyL66Jk
# DATA 540naKesoZWPk5Gyu5uXdNubQRoXwkyrtNsU2GIE3mzciVXQmN+xGqsWq2Ia7bwkXR6ttSBHZ+7rV+48wNBEXYuOuHjDtdzUL2Tc
# DATA VoppGfkKNnDChHpgAIG6wTJOkVX0pyxQL8Gl0PL1ZMzXU93bEIuF1pRSmwNiy7OeZJwnlK0ozhG08SkpMYxrzSHkI39Jj6MTPQVE
# DATA TWS90FOZh2mkWqXUx+l+Q9lFLLeXKd2qoVGn/5ExpDxtSEGxDngfUSqm+bBQT1QOxaxjUfJ+gZFz4ZFOfwbdYq0/psyVkseThtxA
# DATA K3hgAaCKp7aQowpnFgUZl1Dok54bfSxjVmJEmEHF9CpzliBdlyN3VRcvOaJ6dW4sJjemyVixDbiuJBNWk4P6WTobY4TGlmPoOVNd
# DATA 60Rdq/+fhk8ErgCrkO0ZTL7Gh6pQ9eASHoSHmUUlA5DEHr5q73HEjkwdNwa7hpYpxiBie8jhuhVP1yWb34+3fZJQprUxGIZc52je
# DATA oBP+LjwonmXba1VApkHl9QKFhsqiXRQlLGyNueRYSi7sUhceG7KNEpTTCRAZOg1/0hOMTFBOs24Y0BlmrcyYaky106acygbqcwbJ
# DATA IXt95yFrogz24gucZaOOM1CdgXoaA9WZoy+PObrSzLzmwsr2Av8iwmyQs1OlxdDf0z4PSLBVlIWaPcJ6PQqFdV3ll58vNdGTgA7W
# DATA Vg7BzfEWmTuvUgc931L1cbTcJq9meW6TlzpqFg7427L2snhMTFp/J4FbSt54OOro6Cj1pTs/Wzhlxh58snlWCHlbz/IXTtccBExv
# DATA pNFa2a8rm7Gvlac5f7QxxgbbcvFmZZVpeWDmdczGli1pGJw02MMe1dMFg/nKG5h5c9Ry8M3hK+brwuuzGDV/UW9bKsUCsetEwsdI
# DATA vbhAEZlEZLqEbbK6FeBjrr3j9Ks0BU0A7lfvPBoK8Jty09CQubmxlm+oiMj7+VkLy4CD+j6OkvGAWugHvO6BvMjmH6xmpoiLIpOc
# DATA 0wnPG47TEBVXg96MtTiPlOYoq9LT0VWTP2PsY/agy1Mx02SGgZ0QMuNkLAlmKaqrUqW9JmIPJmREdqbrI3aP1xu8FBb/oY6euigz
# DATA abbAvRBVifMIOXkwYdXs5GBEUzb6KR5CDl1X1qWxuSeTvcXYvIQixY6b7Kz4s1rx81XO+Zmdn/ncBvzK6cLl+ZkNT3yex2GwatcS
# DATA 83UV/GW98ks/3H86ln07vApOpkyUzFLtaz2BZ5wFY/o965IB+DZPAjD7GwONjdH/AXeDiFgeYKxvyBjLZpowzxVWq+z4TTnuVzOI
# DATA 1Tq8TPP44+p7UepstrHffg2jeDFlvJZuUodvjJhQhvn2W/HrJyKmrWDyeaAvmnjWTiqW4BScaV71V9A/iqpcwJ4Qaq+UCesjbR63
# DATA sNP6SsabPim61U1jyxs5sg5sSB0D9R1zccTuHBs1Pu3mOePy3cTurpeSxaSXaeyobsCkvq9RydxBTCJes9Ce6ecXUG3WCqQDHoSz
# DATA Ec2HsCCQTvOMapP+LuA0bHbxGoFFGULPPgGZGQhp6WVK3l1c3o/J3rEXydgSip521GqGJ+sR6qhDT1EzscEjFIDNYYoNazzr4Bmb
# DATA GFG8VqEMpUkYK3oTWNLhWHrqufLMHCiqd8w2keQy1nKPGCTPIhc5K3bJozkc0xIOE6+wzYOYmGnVTSLBR6mZnwdO1AEqGWUGI0M7
# DATA U4X3MaPQyZzsF23WZAGzZ2ncgZcnTixk9tF/O/7q6I/H/wSq9dGfj3979P3R18e/88DOph/+7ejb498t0rP/+eiHo7/Qff9w9P3x
# DATA 7+juoz/Sw/9O9355/NuCR59+oCf/cPTD8W9A0UbQQtL+kv7+9uhb5mh/QY/8K90CkvafPLoLvO7fUrDfUrBf4+mj31O0/sRPUhC/
# DATA p7+/B5b7+AtH177+E0LqxJJhVARZThBZmjvFfVWHmilAeANeBubV8gdqhAi1TVsQJBg7p8iMGw8ixQtTtCvq/SYaas9ssMxoXUvR
# DATA foiHqA+KHDo7N9/LuoerhmdbJXJ5xGxVq1JrpscXuGKm83e3ozDrrl+nL1wZ2xGN9ReJyqZwmV0d65FMba1YmNS9pKzsDQrtwknZ
# DATA 9/oJdOpDQMxpTB1p+5UymN1OiijJvQmV28IecPH5ksVCndR+NLiNuPZ5mxTZd6ntpQpT6Q315pTT1L/VFkzWmp4V+/rEyDvstRvW
# DATA zzmsa7z16Ubzl8Nze4Uj+UUO5BuN46caxq9kFJeaaJKe7fZ9pk3lMgDVJo2yPXRV8rjzVh4fLueC7KSkNOyxVEY47UsaetgI2Zcl
# DATA W1l9pul5KGTaSf9w2h9mBWbthQx1bihkMYbiTYjU7yeeia6AdzVzmWMzSjxpNcvhvCXvLv/IAt2pkIlZ0VmWsFSvioDSaTIma6uv
# DATA KLjTsI0MkwN2Yj1kqTKAbMqvTpyKPoXO0g6cEY4v7fjSji99iXzpjYaUjeYrGxq+V2O7n8V0vwDL3YGkHUjagaQdSNqBpB1I2oGk
# DATA HUjagaQdSNqBpB1I2oGkHUjagaQdSNqBpB1I2oGkHUjagaQdSNqBpB1I2oGkHUjagaQdSPragKRrlWoYBGcESfeqvXIveI5A0mbF
# DATA eSN6tJ0fcLEGQb9eruxXq+W36fuv5vMxClpL8FZNz2/W+kGtvt8E3qqZf6zjdxtdf/6xoV8LvAo9Wi0X/YZXqdIHr9os1mpelf5P
# DATA vzWKTa9W9QDP8ovVJl+r4PbAq7a8qo+7cbnstbxas1jx7bfyTsg826raDcJ6eRnbakndCBCfxr5fmQe0tettv91ZFkptAcZnU9Kq
# DATA eWSwhGsBvOpZ9a3mSeZRGDTaCzGsVOrnj2HFr2YxDKoXHMNW6wJi2KxnMWzULzaG1Ubl/DGscpO4pFKuUSM5dwxr1crllXLgN88f
# DATA w6AcXF4pBy3/AmLYaF5wKZ8GpCeDkAbpyXhmgfRatcCvtvIgvXlsHl8J50F6vW4rCjKQXj0MokbTgPQ6jXaX5ugGpNci67javHSQ
# DATA Hm//LK6z7kvVOT7d59ZDiyy6nEvIb+ZnPToT2MaCy5byHpset4uVbrS3kwt5jtD3VkTjehwWJO7zzu8qu75lyZvhfPPr9ypknqxt
# DATA uqZW0uY7+3OrVtIRjKc3HuUsd+NYwBED7QvHxrDiKZeAassc0OyHs8JTXrBFPJ+qTfnSQGFYXokGlleWb4daeEUJsSab1Zrlk4mq
# DATA G4NdwmQVB53WauheVsIFu0zWzCIWa5tKrlWNlLN7feHwVAC1fuU0Kiuo081HHQTQQQAdBNBBAB0E0EEAHQTQQQAdBNBBAB0E0EEA
# DATA XzIIIOqCmijusnVaCHHoswAJ30mBZdjKtyU/+HTYrtSWuPs/7+LHImrLbQ5ExCN21fCmvlLcflkuVAq1Qp36yLg330Oq23Z29OPm
# DATA 7tv8OlMRt0eFGPy3ke72dtUTVq+3c3u0NpcAkNMjVhY/9R4ZJZ/u3nmq3yA9GV1Rdu5T1Z3Rf6DX2XOMMY6Obe98lsvJ23wIWNuK
# DATA nKE7c6ka7d6hBPHxSxijPG9H8+NzcEhCSU5+KswfBc29koLg7bA5l5+Gfrilzvuho8hq5S6NuiwhK6eMqT4KA++hHDpGEsbUwTLm
# DATA ziRsyhYvkHs/Um/fEct/edmckJJpsrc3yKWkEFM7Ry2SJHGgv8T3j0wRKKBissu1Utv+aQc6j0juTmEv99NbNImgip3QkBVRxow6
# DATA h1Jo/Bp6W/k1v1m+Va2Wb++V9uheGIu/wA132ajfxqmFggpQtqHj8o6+O3o6TkYQbAsHD8Ph+HGSf7bsLz57o1SuI0KUkBEV0fYe
# DATA AtNf5G4o6cUjXtnEneyB2pZPyXh7WYgNKiYpwAeSmSyYCLjjNj7c8JnZmPS8JhcpJ17/8pPmba6Lu9ZEBiVdqJaxAicASLhREq5r
# DATA n6s5CSvjawSjrg6fZXX/tqoan+s2wFPgKbYbcRHevbd7EI9oYlXiU+VcL59Of/1rdfEgaj+Jp/ZP0lvc25n2aZz27k8mXLvlSLo1
# DATA TiN9nEVSD379a8wH796jCIUHYUyzP84+9NNDjJNLKvMpW1EythqR9I/SUG5/zrN9O0+kjCTOefNi8fi6iB6JAg+kD+UUdzvyIpqm
# DATA 6bZJ/Y6Zyi7p6vh8XDygaV2u00ORmcdkyNuxYkmBqlJYEiTW+OkRE5T1HGfta9LqJRjxqZlDtU7LxmnZLNOyyR+0dqI2TtRmU1Gb
# DATA lQLklyV2cx/rLjy6Qm1iFNmyLVr45tkJqF2FyriYAnT5MT542yiO9OYwHs2m0Uk61vpZ0zmZC0ZyWamGz0tCy94QpQldWSdhrY/5
# DATA UrT5uC4U4w/RZXF+JyycQaXDC2h9WWni4qQA5P58xpj1JCsnzI9slvKSteQNT4HKfGc+I7QHJ8sKc2uWdH7Qn1O3Xv8uf/N3+fls
# DATA xoOVU72rsvm7Krl38YPVU72ruvm7qrl38YO1U72rtvm7agtS63eCU70r2PxdQe5d/GD9VO+qb/6ueu5d/GDjVO9qbP6uxoL++52m
# DATA eZfWVzFteKW6uj19fQHE1PVQIUgXrURkjTbU9z0RtBKOztBUTjowGSExewA2mSfpQ0gtTXJdnoTgF7xqwQt4OGqAohWNWEjVww4C
# DATA DlqAwkNDArMiRgPVcv+ph/6VYQaW7JfxtmeqUjRMYd6gFcEwCCJMsRpPrwe2gZT58y8m5KCtbuq0furkZkov5kzptCDWZy4Lypu7
# DATA sn1el4HwtOQ3L5jbaYuXLoV1rsTJsoYgnzw0LVW4KJAZX4OVvQbiqM+JWOCG8uZetnNQG1fitdTzZTmxQ7lDk2moaEIlyRhad5VC
# DATA azhhkSs4RskYwtNkVpF9xfxTXnsRsdaxTON5axd0GDFP511NBTygCipTbuQJPRVSPKB37GMnolCB9sAmY/lJejkzcqDLp8XQT5+L
# DATA MPtYM3JOO/YqJdOfjaWUq5bOWHLG0jJjKddVOTfzS+9mXmlkPXtNdV3zqTqHLCt9CA/AiO7jzUiZxvp4gqYJGeC5RrY3o/kxu5on
# DATA kdLAXpD3puZiFMAtZfBETfG5Ds05lnNWw6KIurmPxlXdjHlEotI1+soYNpNezwv3k7jLq5+jJE7ZJT7RmtrSHWTg8SxhWtGt5D2i
# DATA IdrrUWgiop7yOqkcJcbgO5C4pLx/EYEcGi1w6llm7ZQa/WwqhhvLyIH53dVEOMS45L2ndLa9YdyZJOM+O2AUPi4KO+yWx/OUA9Ct
# DATA Rve13BOfuXtCtjVGSg1eZ8qjaCpmRJpJPw8SbGSZguYrG/DGIUMNrW5PA/RK3l1kJgUdj8cKvI0g2CV328PCNq4yejuUu+wy93BG
# DATA An3xCLmj0e+Sbk6Vd0Bv45XxNcl7P4RdI9zivcSozuMqm1tUEjCLpYA1dp5KXSr5NBkmk0lyoPS9pfrzKrkuGq76nmTiCPs6k1kH
# DATA GjCMQRffVXaIN0ubMNwNNJ2KCgOfoiyvS8+bLM/PnjEs8CwAcgZk0fEUJIK1KBaoUoRPMEhNeQjrk8lgG5bUJjFpYFMvFdOQbu/h
# DATA hDqaghkHpToAhyiYALzoScTwedQ8ysahFBKTp8my3ENVHoBET5GZjTAwY00pGafziRR76iRS0OtSz3nlCvGRHJVcmM17hBFtHmxy
# DATA G2mtXreoHccY5lZ6ldc5kfMLJaYU1mRe5lfmV57ztb68ln6RZmUa38W+hpdLpNFkLCxhFnAjuti38YLJQy5ZU1mn6HSsThgt5WLf
# DATA yksn2Pe9umHmX3hzNjinL/7Fnf1kiEt6WzdJJqnNt/yXox+O/w5AyuN/Yu7kl0y4/OL4d0f/L4iSR98efbMIuPwXJlgCT/mFd/Qd
# DATA /mGY5XdH3x7/ncfoyy+O/4H+fCWESxUwvYixlt9T4N8c/UXTKxmMSbd9B8rlN8f/SL/9ySEsr/+87ZHMtCYJjCQ2hbFolMz2+lNm
# DATA 5IjMtBpeB/EU6hpyithMxGYjbbuQKYVRL2R4qwz4bMGkMnMDBgVmYchnUNfyKx/xjgvqC+OB9wlZjGxEOZJlNofTvcBVYyyXFszl
# DATA AS25XqbW/FFXU0Ee5W9GZTW3PlA1F8PbRdIsyVhlIQW1hil7TahJjB3JcoPSunCQ5V21tWpAzeOweBAOnmSkJjKrwdsB/kclC7Zu
# DATA J8RxIxplJ5BnU3idsIsRwkCjRlFERj4W4KleHvLcQFGQcH5+vECyPKHmrTZLljWnZ0W0PCERjmfpxvjzjPEaZnnWof2lcM1e2bB+
# DATA OaP6RoP6acb0KxjSpV4uyQEzoD/D9nMZhMslSfVoHkqfmD0XqmVSSS5iWeB1zhDZHncwziLFnNxlUeaNz+rhSSKgQOmb2lg35/iG
# DATA HLdRDrW3Cdwy5+hGlFQyjPYnu7ux1c87oDk21oBF+SAVKqD38zQzoWTkJ8sNu7x7FLMYhoCgCeMRry0Z2iWsnVheoDzDKDReyLpr
# DATA oSGVb7Ub0Rg5jMlsOOhHHIvQY9OEN9j1Ike7dLRLR7u8RNrlJkPMRlOajWziqzbvz2Ldn9u4d8hLh7x0yEuHvHTIS4e8dMhLh7x0
# DATA yEuHvHTIS4e8dMhLh7x0yEuHvHTIS4e8dMhLh7x0yEuHvHTIS4e8dMhLh7x0yEuHvLw2yMtKrRYG9bMiL5tRq917jpCXS1aeTwu/
# DATA rFW8Wr3uUb55frU88MuB5zfK79YaTa/RHFSaFa/anONa0r3tRRzm0G9VvQpldOAXm/R3y2vVi7Wg6PvFCoUf/Oq9mk9hN4NBvVr0
# DATA yw2v2fD8SqMY0C21YpVe3ypWgmK1MVcmQdRodxf5gFWKduNTPygXg7JXafpeeVqrNr3yfqP5dq2aD6PeaXYblcUwmjUvqJU/LVbK
# DATA jWKTIlWpFX3KC4pRgJgWm40TyJomcgscPb8pr+vEE8yWOlz8dY6E1+Gi9aXmTgRUmItvN2jWarUz0PK4/mpanjQFi5bXrgdR1d+A
# DATA llfvRjlaXtToBq12RssLenXY1oaWV23XmpWMltds1Hw/unRaHlf74nrDgL37c75pKiqcvfzcCkDbBjl2miR6Eeem8nXR/4c/1MJv
# DATA n7SGsNzYWQV/s2J5MoXPhuzJg6eD7NUWIXtZMKeA7GkH5Mo8snNaZajC2Kn6Z3uMKmynsTFgBrEV2wj02K0WuMqr2XdZvhbsrFpj
# DATA TpyQE4Zo5+BzDj7n4HMOPufgcw4+5+BzDj7n4HMOPufgcw4+9xLB5zhtOI1Q1DYPpfG1dQMaI4gkh1huaGl/6hn6GHqDwe6d7cEC
# DATA 30mleEd3ZK9RME8/kmnNLz182LkxyFcyrvk7pU+SeEQBfEj/gQ9125iXH27pY+dZXErTp8jXD7feWDiRrgK4gc+aFHXP7FDQoWrw
# DATA k2YrOYVwd7B6zcFqd6D6JTlQfVq98Gd70Jr9kpkrbRFHNMhpYe4lSRdniz32E5pjtkySQCBrdLaf9fns5+GMIv99wVrtyw6SX7Rq
# DATA +/Jz+Uv12zc4Jp/5aY1+eCQCdShtLTupKofRmHkcURTSZBhBCIaP1kpV4xPwyv3GRBbRDcyfL89Ojhcgg0y2ZtbYec4IPVN4gJNe
# DATA D45pfaBZdA8RuFQ1fsX84fPTiIgvVBM5kBtm1smzEat5FqdZzfPOoHIG1RI1uqxCOcEaJ1hzVjtqpb12OUI23KfrZkCWlGhXsAZG
# DATA P5kme5Nw3LdExZ+ZbtoFACxpXH5DydBYo9cpNYvFGEAgFyhYrMZ+PZgPwzFnjjXmL1O+vRDV4g9Y3lv6RqqNUEhBz3cJwsVvwlbn
# DATA F4286Cnlo5eOLlw+mEWL3xmls0E4FfXyQ5W8AyR0TJ14z6P+bjC4DNniGWsqTTV3ZsYa4HOt4WLfG4jyNCS+u56I0Otxjoa/i30X
# DATA 0x8fRJOUpZiwUsV8e5GFYbZRMYzJgJ+NqUFGF6xG3cg60TkLmoozBA9WGCBicF+wRPQcazKblkmQecckPaS1grzhoTE/pLcxOMoM
# DATA AGkrqpvloExRHpMDu/6oJnSYqU/JgCYnjtIV0lIdABa1rpSlSwVVIBaX8h5B4DsaeQxeGXWooLT8VE9RDyjvC0YhK1G9s5Y0xcLT
# DATA odZK4hnRZNZuQySfy4WZxKgmyYDxxTIOiMbRZAYhL09nmtHxUu7NSF5gFrtDpZu6GerxxZl+WAaFm4C4CcjCBCRvYbopiJuC5Kcg
# DATA KycWz1pLU/E6mGnRD8cMGw4xw7DFsdNI6e5pKcg5sUhG7Wh1SIU+imQyY+k8Tm0BSIyVgwPwk2aCC5mXeJQWO6OmTH0XlcJ+tETp
# DATA cVO1TU7t+M6bvLSZxbt9mM2OmLvcnsWDrtHiU5FhR+Oi21gdHrUA9Bq9Lav9DKzCJ2VhKQtI/5jBs80VVhHoMyuGezZZnJXdKzR0
# DATA W0nJQ8DVe80WAlil6vOrsjFCvdy6w/Ss9lOvJtzDZoYf1uAxxlKzUfexbZkoR+787TRBVYcZ3uJPq+/sDOJhmyOKD6vvo445waYs
# DATA uvO+fMzuvSlpuzOHKde2pqzG26YmRpQ1hmaudLEZWJq9OiOdWc7hpGump7z5QSaqKh/z+TAH5uKd1KY7kJ0FMrGd8e0178nQJGM+
# DATA 3iZToRxZvfMwZlZTN2KYELXWqngJhkk6HRwq+CV+gpVopNh5rUZ4XfFoKkNgJHKY2CWZ9hOlJxoK9FyLxzJQfGSkZqnl8rRYu7eV
# DATA FKYHy0xZh+qg1tVmYP0UGfgBzYkH7LuPJx2aLmZZiDkqdQxAcdkdnZrlwFNC3cInaosO9WT3eJWAbWPeWwmzfZi08Qj1fpHUaSqK
# DATA J6ksmikKGJfFRWSX1UpOmV+ttfllmpxk2M8g+UntYi8yWQVvAt+TzyOD4JKMLHkf0JhZ8FglLyYj7FD5nxREjLpzocTJbhVxh2nO
# DATA PA0bjHGLuheRVabjOWVGNdZmlOrFJJvehh9HzPl4ZNUqfjVViAOKZcqOmHAyUKun2jcDJwK2wYXQqpWVLp5m42d4//YOM39hhCVA
# DATA 7MkXci6AY9zncTuEpC6jK/imZ9omg1O0yXcBokOfRu2uSIkuCuTK1Db7MjU3odapjLRW3qIwPcTinibC0SNk84v0MOen2CIpMF7W
# DATA jPxZVjC/snkNezehIqYxchAdspsgq2MD+iWzcJR3Vxx+NLulJsieuMxYQ4ZQD88OK72IqhZFxdqCOjBO5CSqjpK1Ii4o0AgncWdp
# DATA vuUHYtlbZw/E5opkw533E70LTitPswmmdqfBKaJKUlGidX6XTmKIvSgOiIwlNo6mQPPaKLH/S0Bi3tEfj772GOsF+tdfjv/z0ddH
# DATA fzn6dhEj9n8ffXP0XfHozwCAHf8GALJ/By7s+Eu6/m9H39Pfv6e/fzj6w9EP3vFXEjqC/hbQsa+P/nz826Pvjr+if3+HN4FFRm+m
# DATA ML6mEL7WYLK/HH3taGLPAQV6JCs/2MfTUSr1GQV6HCVj5jcyYJ2Hdmp7YiB2Eyifs7cRA43lklZiuHwX+uhMWJ3fQD1ILBLy7Dxe
# DATA SxV7C+YSs9tHhw4nZvtQVEdw1TSxfIFcLkYsHllruPd1LdW/LLLERlMcAjR9LL7KSBdNLpInFk4FUdAPUxpOYcGSpZv0eg4ntmmp
# DATA XThT7F446GDVMZIFsMMMUB0Oeac9L4EMeJ3E62Eq4TEXjuX+zCoHSLrDYcSTX4wlvI4Y/ypi+obXjaPpEozYiZVutXWSa0vPjiF2
# DATA YgocR8yN7hcxumue2KkH9ZdiUeSqBvQLHs83Xgw51Wh+RYO51Eg7D7LtVs++6VwGSsxOqziG1Q6OfkLPYfEhn1CkwMRSFxYWidYk
# DATA /R0w2AfjVKhKnLRpmD5Re1UQgXiEk2M4xqeyZDOUGABGMlTvg9elYE3djOwk1UaG9Y62CQCfSrDRDjYB1rZiMhCW2AUz6C7E02X2
# DATA gLIGGHwEOwCrV+kTCszEI4ZznGsT1a8BdmljD9lsOomlzJJRJ5qMUscRcxwxxxG7ZI7YRiPNhicwNjSOr8zIP5vv8QJMfEcTczQx
# DATA RxNzNDFHE3M0MUcTczQxRxNzNDFHE3M0MUcTczQxRxNzNDFHE3M0MUcTczQxRxNzNDFHE3M0MUcTczQxRxNzNLHrQxPrBJVF0tWm
# DATA NLFerxY1nyOamL3sfFqMmB9UvWqr8WmxWi76lD+NatEP6oNiDVgt/1PfrxYDz69VPL9c8RqVYsPDXbjDbwIDls+6bq/VavQWCGMA
# DATA fNXKLa9C76g1vFqr2KILFa9ZR5CBFwDj5fkIu4XXVVv5YIN6s9vsLQFzVcsWmKvSCgyYyy/n60O71qhFSwIIalYAVYvs1VysErVl
# DATA ZLBK47TPW/lSrTa8KuVDJfCaRfrL94eVmk955CFzy5zFqxNilyLdWQuCftBozpHOzAMLpLP6GThl3DIMp4wbmcUpo3rUaIQbcMrC
# DATA XjXHKetVuo1O3eKUteq9RsYp6zY7tXYt45RVmvVqvXHpnLJxND2RUobxRd+3AebLcpRV2U1WavLyGIa0nUUSmAlZY85yM91a8BMv
# DATA oD+VgJ2OOTSX5KiEoCK8mVNNpco41ipmujv39kqNfYHsxpuzbcTztAbhpdNVyMVvzRCeu027wByyyyG7HLLLIbscssshuxyyyyG7
# DATA HLLLIbscssshu14yZJeyOCwOVzc8THffC6f9Um+Q0MQGZt+HWziMRan/KUyam+oan4/CRflK0ywYqtRq2Pr8cOvumCZ4T+GijAaH
# DATA lBs3EPQNypXeTOTC+HhYz9K5UmeteBUJpCwgtfRhrlAdzoIGGYKUYzchH9LGARVzBkv0/hxlyx07Pu2xY3fc+EU9bnwWvNY1OIbM
# DATA 7jvt71pP2RIBKxPvpUeVl/C1rsvh5efqDN9lALfyx60vmLQ1VxnOitiyHKnZIXKV0xkWBPKMIiCvVFc4u/rVO2/yBJ915bQOHVcf
# DATA CIWOlN6cHIQ11ecgpCfayQFOO0d7swHk+7Ts3BByokkPavjd2YQraDgZaul7dSae360jcJds65iMX942q6OgKWGUPT0skrZZi3MK
# DATA P5HHm1PEMsFS64DTBj07bgs4UdmO8OIu2WSzSdsIT74kRz2tMJxd5eyqNWJtduVyui5O1+W0BtUa3Nbl6L38zSg5QPcvigPtcE80
# DATA 1iC5oQY2/+rlxC6ArsUrEGoHiL6W04bniT5d/fkIeguRkmExbjFv+8nezhwJaMTrQBloRwVhuin9PYdDokRTlww9mWHM8rblEvps
# DATA 6llkS44YR9jLmf24Qs5e/BAA+tiCLWNscaXBfvvE+Orns35VX8ggXM3ysjjbMcZ2HTvKayLMnhKmNMFdnenYIKNOiKt61ERVf8/h
# DATA wtbG018TyzmCklpfQmtVThdRI+eqblGSUKnuvCp7TVU81RqjreWbXZLeJd6XFND4q5itNyWI81GgLGaT1b5t4SOlT68QLyGavdEH
# DATA vA/Xk92AuUGzVkr0NBYVFx7u0ONoF9SnM+qFoFWezvb2IvZAAxjBKxOqg0gmwFgAqsSq0hiFOdARABUDTeMSBhr7xlW7g4AKmfIz
# DATA 9sdT0UAPBgrB4Z5hxEKBCsZpKiN5N+6xdMpU9IdY2dlTW3kjEx+Ro4c0EUdjiTpRJknEssrwNCIyXjimOocBblO20wti7OZGMGfu
# DATA OnN3pbm7YNo4i9dZvKtN2GuicHiP1fegWdzDIBOPWMZsOd9J82UzKcBJNIwZ0VFYpbr3pjAFF4YbFjbbm8Vd4AyzgZFCo/banQFA
# DATA yMPbvAmchyYsCBya+2hcN0xT7Xviof7nzAnAeDZJaOgIp3rMZTt8SA18BhNK2QHh3iTS+MrFIVPpH1JIXRqqTXLgqloYOFkaEOIy
# DATA 7DmKWBPOC6eo0BTh2za1XZMho6e8PQrviAE1oFxfMSMQibdkn/c3KQan5ueONcMLGzkFFPI0mnRi7HfMQVAlw7lgWLTPEipUXrKS
# DATA 9xY4W9yNsjeNoV192Fx8FwNMQKyEu+7daMr9LCcDpk04nfO34eCaiazHhxvAPlmXxrtajtL09zqRH2DWptk7qu+HymRBNPc0mAiP
# DATA YP2RCnqQFpiOkRpqpza6xEx6H4GhpzyECaY2WvLIMuEhqQ1LO+rGnVBKUOEzkZULNd3CnEVPacwbHK5L5ft8pNiYX4wv0em8yzs9
# DATA 1SGR2aQATzIrjA918fP0UZFyYsBPlPk6ghKfEv+0GGmcpLxSZcl7FEVPmBICtyzzPJCXfKuqFlqxMseXYf+pcEOgtggHsXYUhylP
# DATA asO9UZLG6QKZgw2xk3S+HyfUMXF+Zl0Qt5pTk6LZp63HoAvhRFtubtUY4N5mJ/YlkKHfQ/XV+2CouYaouqL/rqcpl0CJvpdzlqPN
# DATA UnkLXfYSSNHvxlOelU2o24IQpEAhFbOGe04RmLwEWPSDgbwTHSSnNmtcPM3qXgIo+i51QLrFo5fqGn1dLlJ4iybdC2Ynv+jzN4uL
# DATA Q09NUxuL818BwTn6/ujr498cfX/8T0ffeMdfAFFDX7+hy98e/26RjPMvjLr5V4ba5O8++hNTcjz66cuj3x99c/yPKpT/Ai4OXfvh
# DATA +O/wBL3qd/TLX+iFf/KO/z5H2rFgOg6N8xyQhRnMZrRrhZEFzy+QHgXZhipc4B53WweAch8oi2ovYsXgJ3A4C054qlmJDBnlQRQM
# DATA wb3BegLOu1HY47c4/E1ujsnt/arpN1ZhXB76RpKWdYtcd3o8D5u/FSOHuZGnepP+4bQ/vEjcDW+ypWlPHzW+yzMCIPd4KyZud9ib
# DATA E0vswnk3mOQmbcwxuZ5pjzV2iqjpMPcvg3AyVEtT2eQzTsUVvbCHWvTT2baVuQSVFvVimNaR6QIH9wL+Zn39W218ZO3oWWFv1sfc
# DATA EW/coH2KQVuDbU43Vr8cvuCrGacvcpjeaJTefJC+/DFaqp9JtBmQr64tXAapxqRHCMnpfEL0/otsEwPbE/1kqGEwVpnITJcGNAx2
# DATA YZcTyhR0Q6RIFWO5k8wmwqbIxledcDnKTi9BXnHwm3Fr1BQ/NwaHxrmuR28zbqd0Y3c2iPSWSF7CglfRS8dRJ47Sgol/xi5WjtZB
# DATA LK7XiDrbsBdND3OuQJUOxukyJppRwB1JVD5BDlDjADUOUHPxgJqTB46N5hyb2K9XY3+fxfw+r/XtYDQORuNgNA5G42A0DkbjYDQO
# DATA RuNgNA5G42A0DkbjYDQORuNgNA5G42A0DkbjYDQORuNgNA5G42A0DkbjYDQORuNgNA5Gc31gNNVaVO2eFUbj94LnCkZjlptPS6Kp
# DATA VppetVbuM36mUvP8WvXtalDJZ0en1ywHi/yTGiWgWmv8wq9U5/kntaBTay7jn3Ap5YOptlpepVb5j36r4lUqZfrT8Fr+p37Q9Jqe
# DATA 36h4fuDTu6pepVX9tOLXi36VyhDEnFrRr9MtRfpGN9XoJp8eqP3HSoserXhVCqHa/NSHF7nm1eieaj2XrlrUbNXLi4AYiVCRTPii
# DATA 7zeHfo3yBS+ql4HnmUtrp9VthZ1laVXoGSrFmMwPxa6plYOMXVNrla0KXJMvh0tqc7cT1Tu9M7BjuCIbdgy3CYsdU6s0wqB6Ijum
# DATA 3ev26jl2DMWn2Wlb7JhqvcUBCTuGOolWGFnsmCBoV2uXzo4ZUCs4ER4Dp9Hn2a2G8mJxXFTqFh177Nyr0L/Nn9jmdoPNhyzIk5E0
# DATA Nm+GN9vJ3uJlsTCuq9KS9VOysDwsVXp1+ZMLzVMWjQHK8Chqev8cuUaKeC7FFCYsIy+QP8Y1Ksluwriy/Tm+tcajgmhQhvn0R/2r
# DATA LUy2XnlAXEmr2aAs81mXn2MvzYiVATmojYPaOKiNg9o4qI2D2jiojYPaOKiNg9o4qI2D2rxkUBttEGppn62d19aNZgy/0b0+n7pQ
# DATA jxXQBy7tWj2VMqtS7d6Jde+1yybxzm208w+37mVqXjisYsm5jCiHlaYLpq95Zo05+eDODbtzw9bJF3d62J0ePun08EqtyUs5Vfw6
# DATA ai6U5rLAzcniZ6o/cQF66dCaw5sPougJn3CUNntGrblsbLk4tbkoGihV7rasklCGaPVB5ei+BNk5fd5YgdvGVKrdCbTnPJojRYPD
# DATA S9Cce2eEQ81T6WFTpZQNe7mXCVRfgvjcY3Z9qTSSCaJ6c6oTNHYUoX7dvQTduYdylBg+QDLlVJINXOBSypW1597HWevQCNCh5ckI
# DATA B5OFzEvshZpNogtWn1MeGCMdn2ky5pQBssOtOiHm1CxlGLqAaa4HsSTqM1F4kYCHhOrcYX3ujUqZumZ3cqgzOkM1hIMDcAuHEUvI
# DATA 4xYsVJGhMRiUvHfjnmkOBeAeBottUamojhCVidenHycRFqwGh/Ikdy8HYSrR0UQhpVbLdVBU3tHY4M0V7WqaVGCJfV8FQK2Doin1
# DATA pQ/f4ESdiIdOJj3aoyFllWSAzhV93J+6yRFOvvM2AxpPWAqARup5iZ+5kephhOOA6hS3TFrlDhl3TpaNf85PHjvkpLPfM/vdWewv
# DATA nMV+WqTkM9QB4sV8sxC9niP5Zszy5wqOAtHzkcd7eddAJK9YPujay2lcBh8yEzm6aDikLQd1VjKktUlBT5se4liVqQ4y8WPhFCU8
# DATA VZkrSOxqkFJUuxtBbHx9Ig+DBoAtdBraeNcbzIbxKJnRFNHYRCOq5AlEbMbRYABpd4yhfaW4TvbXqOT9rC1y+2SYYNM1tJT6ZJIq
# DATA zAHzbPTb7Wi8BQON7+LE6Fi8D7uIgqDYUeWlWmOZXWzy8fmRiLchHKbQUg9TllCXFqI1noeQsJ6sez+7ob3cu9+SFpSSeZnyUnTJ
# DATA ey9Jp9r+E3EhZv/oWN9GBkn7AnsJyjfUX8M2gLA9dSNU1Vk2ZD4mL7pIjNUzOFvN2Wr2yOCcrS+vs3U1c/JZSji+x4uVuj4rATY+
# DATA em1BKSGtx3CEfWi3SfvJnDcFdiMwYJKdaNpxWPIeZGKAOIUjKm0G7cNlyE6D0NIPZJ8m+w56ccdLabrfMZ6VNm8lyzQDRXNxQw1I
# DATA TrE4PrLGL2t9iMkonEw0T4gPl+A98PosMRLVGcdF2qVa50Yl5U/KT6Y8WfrHDIhornCOAzsScTjytHI/JYOBlYKlBEizeM7VRD6/
# DATA KlsC1MutO0xHaT/1asIdZua+w+ozRszBQC+NxvCHJsqam7+d7AZuVcnB6nv22OxhZBZ/Wn1nm+001sieiJWi77wpqcryQcZj7S2U
# DATA FWjbz4ehYY2rcK3NaHk+w0nXOOF5wV/c8SoHrRyYA0nxzmDT+mUpnavQZMY5cdckYD7GkpdjNtjuQcQxnkDIFPU+M1thrxWVJmdB
# DATA JEaLmJlpDVIaxoZJN2I//hT2LAw/bcEJSsl2JsIBaaQ6IxYa0kb21PsVDbgl27+6oS/VM9vk2NLIJ8VkjZYwA+AVy93ciOgZy+k6
# DATA b8ueqniyynfKEnq0uoR0NZZCejRmH2y+hKgZc0ciHndgX6CV2Sf7R9ygoSd1XVn9FjvQrIHgeVkFEanVBOqjmHKgdLGDUVkp5y8b
# DATA OwXXv2AebFowD8LJgEVlw8FQF8yjpMcw1hGNaqyZeoBJHo2ge/m5Wcm7u5/EmBlT3hu3fsF2fXOpjKl/weSsq2aJmB6euzzsiF9Z
# DATA eWR97ynL4z+sLg/di0t5/AcyWBY6slmnMxuwmiwWAdVJQtU49GRVsfSol+KVBJzHpiGj5L1NreuwQEVIZkgSD0TleMi9WDIcivwz
# DATA GRdDYYnRTzFy0KwXn7+gshRd/2J6uGkxPZy12/P92essYq16s2j0SXKY9WBajKvkfRDTdLc7o45+T5aijHyyXhXKLDwwtSmvOuFM
# DATA 6HjnLgs72te/E3tz007s9XjS5R0DIziAqHGMrMbTF8Xr/mwYd4tYKGSJcVUePOqkbNhDWmgKy/yDUHOps3V+m7eHEja9HYVExpPa
# DATA NgEtZLiHzl1Oiwk6U2nl7T/Zxmjbf+aK5P2d9xO94VBrcIvJLxY3L/0z1DKkGQuyQ5eyWji9HCbac+3xylhoaT+Jcii0/+PoX4+/
# DATA Ovr98W/BKgPGjD5/efTN0b8dfU9//57xaH/yGHb27dGfj3+7CEb7r4xR+/roz/TsHzz6iwM8+rZAIR79kb4x+oz+98PRN+YlNkmN
# DATA bvrL0Tf4pDhq/wYqGt4v7/3h6N+P/8lR0Z4DKLfZ5sBbXpPpgcauGjI3xIuFvFrgmRFvs4pg4mkWAKChcCewjAx1AAJnQAc6Bt1A
# DATA EV2pHk+mvGcMz/VkCcs4BeDpWEtOg7I8moLY+Q6fZvv6uIu4anrafIFcHkKNRotwkOxliC/eYcgvn+dw3+zFWTf9Zjy18B0Xx1CD
# DATA Ka3ObaCGJjKCczY4fNrJpXXh/LT3BAPutcm4wI4umvf3adwx08uCNrLSBIehkJEwZJFMdHdqTyvmN4o0/hQqKVHWObHOV4FsKlmO
# DATA nETsWWTCrD4mMKQiErwGBqvpAlttfb1cbcTMtbJnBVhbH30HWHPj/wWP/xrCdoZh/6VY3ruaIf/CR/yNBvxTjPeXP9xLRcwn3Yzy
# DATA 16v5XAa3LZ9wHiQ5Qwx0zKS6fYiQCnKGcTKTV0lcpwJ0SochFr7M0psn/VI7SuHSiiZYmuRE00CdHVtQ0evGPcN2o2QfeopksiGz
# DATA baLMNd5WgyMrZFCwXyLqPMHYpNBkXMeEe8WnhnknkNDm4pT3UKVToXHx0myUTsVUQL5klsNtRTEDPWs6oxCG4WjWw+eJbSQozyv8
# DATA BGzTTA6Lycgh2xyyzSHbLhHZtsHostFEZxOT+Art+rOY9ee16h24zYHbHLjNgdscuM2B2xy4zYHbHLjNgdscuM2B2xy4zYHbHLjN
# DATA gdscuM2B2xy4zYHbHLjNgdscuM2B2xy4zYHbHLjNgduuDbjND6qdavms4LagV496zxG4Lb/mfFp6G9mqXrXW/LQeFKt1r1kt+tXK
# DATA gP6pVLxm4Pll+qXq+RX6VC9WqoN6ywvqXqvsVRqfVmt01asGXq3ytu+3Pi02i9WGV/GLwVyWRq1epdueg575jVq9WlsGPWstllyl
# DATA 7NXKQT9oVPar9bfpa/4FJqw8ha1CKajUA6/hF/3msFhreLWm1ygX/QZ9qXm1uldv0peNI+ZXF2IW+IDENT4tVqlQi8iL+nsUAGI7
# DATA qNKFHC2Od3LmXxb1GvUVmDtVgTvxhE/YPZVKX8nQb36DQXKsalDPtwATLAUAw8aTp8vIWk8ebjbz1b7X4++6/2U5VBZ/rTap3lAY
# DATA p8TGcTPS2DhpkRY2LgqatSDIY+PoplqlnsPGzYHkBBvX6rYybFytUw+CRoaN63Y67V6GjWt1q61ydOnYOLS/k7FxVW0UiEmgn1nB
# DATA j0My5/yLwU+8Gv2p0p968BM7iDle3DtDmkpMC9gKjPh677NiB321Y25Pk4Jy+fa8M0/cPYXm/kGBV8lWrIipaABeNf5s06WCUs3K
# DATA C686yQfj6f0UOYPEzJewq1q7+LSXM8+0U5lUoT9+oE1+9hXFU7KwOjmQnfZhU79cWcDPlVfz5UzuF+wcWGOKnJBAthIcR85x5BxH
# DATA znHkHEfOceQcR85x5BxHznHkHEfOceReMo6csjjyHUA8ovB3Ye99uCVtjhJ+Q75DEYazgU3MD7cehxOo0PIjntyM5nWDL1C1eBOb
# DATA 6bb9nRuUG51h6UP6b3TXOiV+/+f5Y3j88HvhtF/iGfo2h/NTvxQghOx435JD45nyLaS4TLevUXPZsRV3iNodot7kELV9tMmdpXZn
# DATA qdfoJT/bM9ZyNLigz/ouOWn90JwLlDpSyCurmUO9cmBVCbLwWWLY0QdKh1lO8kassp8dnhyHh5hMy+FJaK2MrJOTG2sgvymqx21h
# DATA RHVBoMKrQ9OhoyNwuseb6B53wnQWKtk0fFp9J7pUylrc+oF8XH0vdbDdJOGM/pl8fB4UkLO8OKUI4r3VIog6V0UEkYyyyWEXOkTh
# DATA aD9MMwVEnJyk5gUF8U7CbpPZeIxzz9hogMNo3kRkIVPgOeQwO3vBqKlFJY9adYyjw3M6OjwedieHBS8K00NuKOfXPZxLw5VJVFr1
# DATA 7+IUQ01NVjrVsB0mM5iRWdl0Zmmfam7EIrk4gy5HqEORq2YzJzMiYFXCLhEMAwqqD+4duohMmVrpOfDx8BnqB/ylbc08OZc6dZaA
# DATA 56BgPti4YB5SVS/CrXIIDXBLOZQPNheoRMYRtx5uNrqBMEgGBUf9ERqO1g3FOUIoVkExPBqzbYgMt9Q0RHAAa1syvsWDfjJj6dHz
# DATA 67vmknJlpXTmzu3dTTu392LsnIGGx2xiKSPTBIXmfNgVOE3Guun04skQ4qSzsacKJpmwBBv/KuolB5SoSdKW7m4S4Svrhs1GfTKq
# DATA oG5gy3icp0hyMb+yErEGyVMWyePVRWKGWymTx5MwHoheSkhmjSkU+j6FcQL7LZEc7tK0B0YeqqahYU5C1RyUZjVgwlppJlOSyMTe
# DATA RIRlcChqb+cumHz0r39bebRpW/lA5qQ0QY3HVIVNwaB2w3KmqbtsEYJhzcM4T0eh6jFOebzHNB88WmzMVcisVDTDlUj4lEWtUbrw
# DATA nJ67KOZi/PJqHb8IciL6cefdct6tTbxbdhVz3i3n3drYi7XSCXY53i0W3jIAvNDbSxIRxdO+rWurX7vO94UjDZ7tAVtwagndFBtG
# DATA 1D5kfS3nbVLLM4xmGmH/PU9U1ULpdme4o9xeumHKpBSlKKGa501Xll0xrp8K766doOdGLzaM2UCq8LbqYchbXvVG3mjMW69L/moH
# DATA Ga8goZYnqlzHRrUs7ydTN5qY6QcXXFO+IvTC7une8nyvM1ztx/JLATsQKLA4mtDdpSB3/4IvS1lYxlEom24oiPtavnCul7XMJJQf
# DATA RYEPF+lUye4r23TJLkkTj8U8G9N4OJUN6TcliHMaQGKkYDCy2putZvl4Iu5XIcaiH1hQiR6wXuNIe2kLMmNgG469IuFeGMuuK2yJ
# DATA F4wUzR5KnoHcZfW05HGhFXjws4AsLF6ZBQm9ylRbx3gdrKlxPBKMFcIki9hIEGJBkRXUcGgMko7tQ2meIswXQoHSXkVMZ3vg1/JO
# DATA gWwNU01bR1qCkvUqM9nJGVuoh57ZLqD3xI3ZhtF4WWT1C294ZkONMz2d6bmJ6elszRfX1lxpHV5DtWo+0WFOFyyaYQPLDH0LZifH
# DATA ChTySSTLhKm2QrOHWHaJO9/rp259/SVf+W85p3PnVepB5xuWPhaIcM0Rrqac8LPOLMqFcMDf5kW454/rSTPtJJgsyLsORx0xv43+
# DATA 1Z2fLZz24x18VIgL4ubWU/yF07KBsHh2bEXbY3Nw8IPwkKcv0HM2htk9XrKTydHILArCn7hHIY0PZXlR5k6gEY7DfZ67lLyHvJw1
# DATA 1RaUukfZZ6iVcBmLM44Nnvm1rhDr4WSlaVrHRpVgvjLdfzoeINQ0foqt67IMKdX7yuEeV248ZZgyqlD70WBvRt2FDSv7l+Ovjn/D
# DATA WDIQxL7lz38GuoyxYX8AUQy/HH+1SCn7X82PXx59d/QtUGT/zhf+cPzV0Z9xqeAd/fHoa0aR/QbfcQO/7vgf6A9AZL+n1wFk9i39
# DATA /DWjzL6jAL7Hb8dfUDDfAVZ2/IVHYXxNF/4BF4FGc+yy58I6RNp46gV/CMuV69p7C0TScPIEq3zhKCrA7UGz0gnPHcehTH8wyNAM
# DATA FUeleQ0JehnebMSBsTb5LB4wG5VadMi7OWliGU4Fkhphqz51ZmupZQKTjmSgdNAy21a0OoyrRpfNlcrlkcu6sZzDTM2db6grXFEX
# DATA 6GUY98ydVOmkJk4uGF7G8/w45Q0IaA68M0xH1RHMNiu1C6eY6c6mF/Nz4UCcSmmnH3Vnsk1kIOx4SH4wyJl7MY/VXj0/KA7jEWzt
# DATA cECVG/tIbmtPL6MzxAqbRBSwgBTiEbpgMQOVZSRtcmDwzZtWzdUmTr6pPSt82drIO3qZswAuzALQ3LLTD/wvhYPoKgf9ix7zNxry
# DATA TzniX/qAL/Uxl3ibXnYtms9lcMtyKfYimaOn4pFiCreX9PL79jgbpn2K5R6vm6DRxdinaSwjRhwNwzEnXF6LPkrODVDtBHUJSy0a
# DATA mST7NXnElXrvGXG2dENsGeecqhQeZccMr5MBH0AQcZcdaMOAiiBFLL0uDvzg5U9GyYGcjuiqzaXARo0jLup+MpuA/cUMqrgdD5BV
# DATA sO4YtELjEeOmYCyIBgLjucwZAgVyGiXL4VOOY+Y4Zo5jdokcsw1Hmo2mPBvYx1dn4p/Fwj+nge9AZg5k5kBmDmTmQGYOZOZAZg5k
# DATA 5kBmDmTmQGYOZOZAZg5k5kBmDmTmQGYOZOZAZg5k5kBmDmTmQGYOZOZAZg5k5kBmDmR2bUBmlWYtaFTOCjLr9cJe+TkCmeVWnE/L
# DATA MatTnpRr/Xq9uV9t1d6uzyPIKlG901vMybJPWVnrB80Gf64CMqY+1yhj+XOz6fmUw9Vaeeg3y0X6V3329ec5qBflfLdXWQb1qjQX
# DATA olAJKArlyqd+o+z5PhBsXsUvT324jZsn4cMaQdjoLH1TUF/AofmNAFwyr1optmqeX68BguYHlHF+lclvtdYJr+tU6+3ltDILolbE
# DATA dCCEQL/UaK+1BGRGcclAZhQpAzITHFvWAmrVXqOycf7Wl7yqUm5kr6r6/iW+qipENnlVpd64xFcFFTtVzfIlvqrOKDqdquoFZ+Cp
# DATA oHLcpWmonPSOFlSuVqlXm908VG4eIbcUKhf5UaMbZFC5oFuPmlUDlevUO1HHgspV6b3N+qVD5WR3YVGWGfQwV+UZhKdXp4zt0hTz
# DATA z35mHgr3VkSdeRwWFulvtWX0N/g/G/sHhbr4P1XIw3AzyFupsc6tqadnWaDzCyS2ea/LZ8GzqUomFw6LW6xwff11u0kdWDfv9Dqd
# DATA HeaxuxZLVavBcFZWrbHnFuKcnxZdonXoGHOOMecYc44x5xhzjjHnGHOOMecYc44x5xhzjjH3kjHmUBfiKc3wJyG02KmC3TbYud07
# DATA n5k5yTjd5XoivRSfX8bVj6yWLw1/945p9nFv+0f8qGq4O58pLp1WLoIYqpz5YsTRmLtqMS5vfy6v7s5k7XnXDuingrvDpQyBx1w6
# DATA WdKx7y36Oz/1gxt+gOjo0O5IAO0ZzRdRqCZmLDfLCrSjKOqm4N3pZwDJExmC1Ggv9aID6UDGcipPxL7oEp9gzCUHGY1TjLvarJ/g
# DATA xZJVsvi0zRO6nZIsPmxvh4X9QkyFEN5Qhvb+zk+3Y2oa5dfq5Vv+TqGMTV/c6rH+tDvcvbM9vLPr12rl1z7cep+qJB+x5FCRQcrw
# DATA 4XzqDRKasw5v1ss7P6nUdmgG1mU9q+1K4cOtMu7mx/Qzw5/QjYs33c5qjmQ5asB2yrFWVQfOo12O3zZSz6jB//7FPyNj09u4cmN3
# DATA WWFux6/mC/E1P7hV1rnJod7+fKf0SRKP6FkGF0qk1ccbS17Zi0dx2leiqH6gCxOnZcXhIgDEn4+gMiE4ADzP0MPtuQpT1LVix64W
# DATA 1Hi4Hpls2aFI3uYCp5Io6lkFPf/aOpORWx4aTxbOZxgHyRhSh461coYWt9Aha7airnRm3kWB6/PQpelT9DNWHCXsRzpM/RANuAjL
# DATA YBr1QTSnFOGUItYrRVjHFJ1ehNOLOLVexEqd0kvRkXgwm2YNgHdtaU1PGdmNqMR1lDG6Ch17MVZExn0iVsyccj0uZbr1+n7TeZkL
# DATA Rui93LqlFsyVcP0KPXo14LIi/RQny5mHZIS9t9XIe5KSvgnGRCm7kinp18rLpPSrtpR+o1K2tfT9YLWUvmXQIPoccZqY0KyKq1Ve
# DATA Tj93s5VvdhALavkcszvVsrY/Vuvq1zieteDkO+scZn1JmAva+/oAI6WbDyLeUUaxMIPQcuhW+UXlTMaEwqSB05QvN+34mM+EXDm9
# DATA l41nPBTKBOSOdXmuQC7mtQ8xbnKLt9+aXb2cl8rBR48G2gl1E7k353/K8J5ZuaykI0hPpjABzy8S4V3490TqRhkr2pK3lTOMxkyX
# DATA JnSW3Z/r5NkMgvBH7hYlwEtVmLVnIDnDehoMN2AxB80gWKVBkxedsalgi/yv5ZwwycDc/AEjoV6hYN+WHoJsCNiJfIPnX9wib2G4
# DATA eYmbl5wwL8nZn25q4qYmJ884nqnEHcZ4VHAdCWTOIFO5e9NMRAR4wJpPpq1R6YUpi1xBcIo1x4wIVUGU04ahOC6NEJoWa5ifXMyh
# DATA F7DNxsZ+C4/WNsCEr/mBCM9FQpiFqxTtmxJDFTo1UxpmdFH2pJ/OEM09/m2WHtKYO2KmFyVQOouCghDJ9EgPtAyk5+4ifaIDHfeT
# DATA abI3Ccc8VI8jGNJK3jeesPSYJDE/7E1Dxiq/l0xEWVeNdfNwU0EkW5afpFbMEQuHxh0Z+rYDhUHGNkHVsYnvHqtTB0CRQx/urvDT
# DATA BCvRD228KDzkIAyw1Bp8e+tiH3fZqlsb+XnjUVJgkAICEU4NQRgq/lMDeu6wIJzCX2hN4kxZT1i2ee09VSxtdNnCJ7B67VDq75o0
# DATA 3cUO+1ECcut8ssRMyHNjF1QVTUUms/AB3PvqzchXMtv6IPgqZINkAf8AYC8ij7XkDsu2wagpoBKNJClg3sF7m8xSlR8q4Jjy4e5+
# DATA EndZkppV2gBQkCylASphYuwQUmtjPunGu1OWT+k51n8jNBHlAJdJmY4zFtRzwtVJT2Zh0KEbDpOuNG4UHl82ZeXpw3NJrwefui47
# DATA rWEtZVjwxrM2WSjWc6w/x40w7MIC8iZch6Wy0tjF8GJ+pQcSOw06ZGmn1CbXJfER0OAK7jXFIGIlEYQyeSH1DDG0vai7o7SO6fne
# DATA bDA4VLwVFVN246RcUSXdwxypkJUFpU846CdKHZE6SOwEpSKe9NEOpcDQx88jasUwffHsaUcLc7b0xmrQznR+oU3n07LCnrE6tL3n
# DATA fz0s7DFGAg27ZKNK6vt6Wtj1UZN+LiRVTyJIZPv+NcvrIqFieYXsi2aKzSuOL0WKKfcbq3mjUHkXGhlBUiNSMWuSge0Ojca6E7vz
# DATA PmuXCFeMpiqsTyyTJnof/Y573owzyxm9BySzR7DLhUZG9Sa7V2YmsGlld3oCCy+GFNmhuulmMljVPMVehp2L6stTi3CZg3EtJgSu
# DATA WENyXtAfhwXGMsTjCWp0GplmJgrOoZmuyjYbMuyHuIvs3Jy3lWxuiBbbWuhsafMUUnJqxqLk2sBdWGdbsPVeNCsvw5odRG0lfm1T
# DATA zf6Xo2+O/rV4/HdHPzBl7Nuj74/+wHQx+nT8t8dfHH1tE8aOv8KVRcDZ/4nLR7+nh79hRNk3Hn35mi5+S5e/B5ns6Pce3/NHZpz9
# DATA o9x3/DsFMvsaJDV6wVf07+8UyIzj8zXidPz3YKAx7+wPRz/QD3T/nxzb7HmxZaWRo+Fp8XVesjLkTawD0RxO1MV58pZQcFO0esSR
# DATA WvnPobLIDHnxHiX77OUJJ5lXySIhonmsRZm9PR8NhzOzbdqso7hqmtmSgrk8opn4VNKFl6vr87fLDgJz98MopRGoIwM2F9IFo83E
# DATA vSR6/nCtyMIfUwsc2Gyjwrtwrtldz9I7z2YGpgbwojGEdGYDpnC0D/E3TlMo9xyoJxJBsXPuPfg53S+a5gXNqdD7XQzEhO2ffcCL
# DATA Pbo4WOCZbVgzV9s4i83uWdHNNkyK45w5a+Cs1oDGmp3NCHgpnFpXaABcxvi/0fB/utH/Cgd/qZ8LOWGhzp5JC7oMstlCIpluRlmV
# DATA LkYLjDNZVvaoeqKm3hLQU8F7+/HjB48K6mCpWhnmkuE9oxOyH3hlh5OBERpOiYymNFFlqT0POk/1mLsp3sxUBY/yGspgeQMAKYs7
# DATA wJxlRkAecDaeRF34RvJGgW0MFLiZorPwYGCMOso8YKsAHCoxDwU5xfFP6TUZ3YydKulhykcp1T1txzdzfDPHN7tUvtlmY81GE59T
# DATA GchXa/GfxeC/MHvfYc8c9sxhzxz2zGHPHPbMYc8c9sxhzxz2zGHPHPbMYc8c9sxhzxz2zGHPHPbMYc8c9sxhzxz2zGHPHPbMYc8c
# DATA 9sxhzxz27Ppgz1q1Vr1+VuxZtdfotZ8j7NnC+vNG6DPOXJV5TAkT2latkjss5tcr+VyvCstJsr2Zy7huMwqi3hy+qdoMAkF1zeOb
# DATA apLFVjzk3RIPYV9l8ajOH1qrZNGozWPrlvHC6hYvzG81DYMqR0j761q36TeqizWnWaOq0+xLnbOSF9bbrU64lJ+2LnkVIaVdUvIq
# DATA Fs1r4+TRQxeWvKowvi4peVX19KmSRw+dK3nVSuVaNJJqtXl5jaRa98/RSKrN8rkbiZ28C28kueSdupEgeedtJHbyLryR5JJ36kaC
# DATA 5J23kQR+81o0kqBau7xGQrE4RyMJGvVzNxI7eRfeSHLJO3UjQfLO20js5F14I8kl79SNBMk7WyOxga3lplcLgv1avV9t1faLtfqw
# DATA 6LfqXq2+Xz0JoLq6EZyFhsmWrqFhstFs0TCr7XqlGZyFhlmOwp5v0TCr9ahZMzTMdqfT7XYsGqYfyM+XS8NUm3lldmc5e9Sym+Fj
# DATA 8oSdTHTbqdbiNfYl2yZyoWL+unjP/FaFxSWzJi+ZlZrYKiOLZrlQ1YL52pDrvHqWf0zPApdvNszuptnk3iQc5tboTkquembJ8vzi
# DATA DXqlfiHPF+/OvIirdkjKi3wpInEFLASCpYZF1KeqdvnlglarBQ/M6eCd7DFakip2Gy74nhe3C63kfjpap6N1Olqno3U6WqejdTpa
# DATA p6N1Olqno3U6WqejdTpa5wXQOhfRnHtxWwEUsToH01PBMTWDiq7c9Mu1ZtCo387NWdRjfHgYj2nEIRnmszGu3PDxZKV2W7Ex76tj
# DATA 7NAPGE37g0PDuWJEIsWE6tWb2N+/XWEs4lvx64JUfBfnzOWU8ngwSz0INnvqRfysitKq5+96leAn5m2Z0I7MSykP9iNGdW5THH6K
# DATA Nf6dZSHZLEPrnKkThHGCMDlBmMVDx04dxqnDnF0dZqWS8mWqxujOGnIQ0l5QXKzkgI02vPPGkpC5PjpmVwE0lKGSQR8ykLEKB189
# DATA ASSon8x182kO2QY3wlKQoG9xBPmmsr7T4ARX0wTNcA6WoPqMsFmwZIxBUSfB2/6b+PWTgIhWcCYp9jWTmuDktFROkQyxNtADwCsq
# DATA JsH2eyfHVz9nImsuWDHdLNM3jKm2g7idQigRkiOZ3UJd1ziOTqouWSAZeDK7ZKLeOCnm9TWxXgn5M12AnjLxeKgK+bmH/i0j/RkL
# DATA MTK9H3omqmPC8uDm0TXyOrANuEjDIc8BeHmGBWHUXLNDkypWi2aoCfZG0vSm4B30qfKRcTjZi6zQVO72etTXtmcT+DbwHE2uJhEU
# DATA muKpFvhR/mqZeaQsy81KTFSlDsVAZh1Mu56VvHvJkN1i1PUVlFjPqGv0nzLRJTWZ68oT4UTpImW2TAaZHVK8ZhP2rSrxoQ2ogS+a
# DATA UoxjnriJwIqJgLP5Xwqb/7Skk+uiFGnvlFiPPHkr5hFT1BJ5PRoicSNW7aG2NYzWsk+enbzk86WudpK69Nwej8sAnywKaF40/GSZ
# DATA DulSAEqu7PSWGKnIywB/b8Ke1ybC0jtY1XPtHa+LaW0MjVPKfSvyH+MqYxYcBEhEND7DqZS5Mjc3wWE+yqbdGq/49uP33i149x49
# DATA KqhxWNoLDwtKyx0QS5kXidDiGCqhoVZSZaVGKgUj+xmn2bxBg+24gcdTDNtriIqPpDOQDW/rYZF3rUioSqxTdBdKoCMlj8qx4wRR
# DATA wroRaH7RqANF0FFE8VN6rAWqvVRd+3qZTeRZ86qsa9Gc+Q7khKhrwVmxpnW0FUyRDW51wDASf4bASGH2i/Y9G9CTQyWJqWJZ8h5o
# DATA Tg1izqtjuiMLvV4YD2aTdTTLhxIMFq5W8SxfIgvc7q+dDe5s8KU2uKokzhPvPPE5626l8X599Nu5TmOkznDOoSeeQuOBF19NnGLj
# DATA XsKDZF58XLvQ5+lnszFwgiXvF9gjfmgQLXRHd9aBiMwQY7GRNjb+diYas72zsZB7plsgzRNf77yqDb9HOObNDRv6FakCYMuMQ/UF
# DATA r940VuJUeu/pBB9FmBuv6oiznuyNSUJjMDXs/tIbfi5jeg/U5hW3fACTDakULW4Wm8atN/HOm/r9MhjNR0MZqsqAMxYPv6l75w21
# DATA OZFrcMHDsNKjvj+hMmPsJ1W1aZfvVGNEwZPBuKCltsG5A6Y47Uu4XRWtFfF4LxxRneratqCJzN1MAn/ud4mCbboZ+4tKdBJBvJsX
# DATA D7TldXJEfhFPpjMoqrOUuBUHVcBs5nFtZUl57lMmycBE5mdjVlQxN1Alj6askj7mwZMyaDDQVT214nNTFdRNVelWcOnXY78faTsv
# DATA y3sx+cLukAZ9PcvJ2D5aSVyR2tN+Mht0uV2KOTuC5YeN55haibq6FHDJY/uSLOBBcjjkIMg+B886hDi8JUMPFv0nSZsHTiUxPxsx
# DATA C1GFtA4IPkoOlF65Np3DaV9H/4MJy9lTvfdY3ESc3bzeov3G7HQma5yCCbW3Gb0UdXZ8D35gRmpm4wIJBciivp0nRiDVj+Bgp+E8
# DATA Gul7u4r1mK0NrkvMe+KKVukJRTwffnXj3leedURMr2dkXIV+NBir/kwWPK2+iGXwaaBMclCFcRQ+QQlLj4m6hzXLbjTEC+wZlgIr
# DATA UCgyH2QsPFqBPTVTdowNPjfrn6if8XBDhviLZdt//vlHn3842nrlr170/yjro8HH6DDi0QxQ1fHhhb8Da5f1Wu2v1Lrx3L9+OQgq
# DATA f1XO/vursu83yvW/8spXkQEztDl6/V+9nP/9+Mc/fjgTQkSHOpC4y+MMKsVWynuRi4z9yCqId+/dd6jX4GVOat/JoMtL+PRAicJ6
# DATA RaRSyLbd48M2+vsnZB/qz0n6Co9e6PQHcdtTlx/QV33LxDyYztrKP6Ov4EgWhgP9fUamyyuvfPDw7oMH9x9iA/XW1tYrfMbmFbXB
# DATA sif7qtnZtE2TyW50q5du7fBuRpwM2QKD7yb1ijdB9b3ZGcQ0g9m6/Ypste6lJeQD3HyPDkedbTxU8LZovt7csnagbrFTqIjQi1lu
# DATA be3saP9SKXoaT7f9nduvzO/7zEeNz5F9rB6iN1DveDDiN2cBRR3kVsH7pYrM8nd/VHjF87zPpnKK5JbP2x0Kw/Dp67Me9j769Wqz
# DATA VnhCVuajeG8UDm5tPXrnrb955913twrptBsnt365RddpeNgqbI3jMf5R3z/6fEdlj9qYGk0mNPT8+td6o2rKAdoXeLFcNr6uzhLZ
# DATA Q7ybO62ln+9iLJgm6liFyn8dDX7wNS6oQ34JDkbh9T+Sw0OlOH0U9qJ3yC7awyEF3F5Cft3DSvYO7py75r3qlZddvsOnbZamQV9R
# DATA cT2AIbOt4jv/Rro/O7U1H5T3+SuoxK+8QlNouCk/ZrrRdjxKxzQKfyyFzpP/nVsoYmQBr6DjEmwA/lBiayLFFGp7q7i1gx8G0Whb
# DATA HqSEBH4F1/DkJCphPwFvI96ebP3ybvF/Cou/KhdbH5du3vofih/d2Mq/EP9NQkzlfoGE3Ufxb2+9M9rHaR+rJ+Fntnb4GTUQ73JL
# DATA zyVmRydCbuHKsk01f/oxTupSTGveTz1s6FX/rI8Dh+tFTztk66YykVQxgL056aI3QH9U4t0P2+qdqDofY3/19s5OLk9Tiuk0HHVQ
# DATA FfnxgofTAyY71dUdqnaev1HuqKmuwphGExU7fX1Xx/OX5Y/kB30j9nzLTXwoceudLhXLlno8Gu3Hk2Q0VHvD7ftoOteL9+jezz7f
# DATA kSv3R/tyJMhO6nwlCIs9qgEffVavfU43m1js6EpjZY318rnssX7ZUY3nPJmE09BywIW/YrIunUY8snMge8ViMfL9BRy95UhukZ2H
# DATA pyUYvjCZv/C0XJ67tLul9qzItex9y5P181E6G2O4otmFFU2VKPzHpz0/ppRJT8E7BrfpNQXP35lPzPLW+vFHVrP96Kf0JE6tnhQz
# DATA neF29aHnrJhxlpdoeIxGXXUA1bTX2XAbhYxbSjTZoO6Nz/mh7LEOQdnDT6PkK0F9g+Z734rGsib811hbgmPDGyqO1xtJ5wlO1+Af
# DATA qnz04OSQp08FmS93uD7iJAMKDp2ywPTI9C+pILEDi/peRcuDLYM5LdP71CLRbaGfwSWlZ/7wQbNkKKaLaT/E/itprqb326XIjiK+
# DATA KI4sZbqUHkewXcLJ4RssLJhMDlnYLn66u0UvHoWdGQ6Um5EcnTdNVbv65iwDqdQ+VlYM96rmlh3vprdl1zTziPaZJ+hOkrQEQti2
# DATA DqeAKz/7+IOHP3v/3f/k/Vq+3Xt4/+5j/eX+/3jv3YJXToD0MGFy6ujnXpdDy15B3dOBRJ6aWxQO87VRrqmBEu2w9AkV3LaqMje4
# DATA aWYvmdoJ54xWPLVdy0osUYFt/zJ3G/7b6nItQXcpT+FTUdy7+GhyvZTl+i4Oe8G6LOGvGg1I/ehpYTHoYlFVCQ5d91e38LT5xm8z
# DATA 5rS8nKbZxe4kGe/ehcW1LNxUL9GQfbo7Sug9B0XMfGOAZFIJhUquiJLb4h7NFOTO0gARS6oieFLbvDoU3WrwHWaKHvDxM74oAzsf
# DATA 7EcFOAums0n0sWyh3H08mamD1/qjWJ+71XJB1k35+k6+IK0WowpVG1HwU42387dvNlzpMOd6wJUtdLNuki0xL2af2NTuJcW+UBb9
# DATA fH20qh8bZZLp4XQadvp2XD9aLLVl/22a5/7aTFcn8/IG9ub5/WH3M78QiGXANjTsztF0W31TdvKtU+StNcmUSC1kL8sBZC8xv/aw
# DATA 5WMw1z1QtE3GLkZjTRFNhlI+NIx1onzxeJJNu9bTb9z/xfs/f/fdE0uOnqRZ0rIns/IKdHG9CQGHHTUDwEi0raoxT4rQc+sZdunu
# DATA ZI+9+g/4F1V0chvO8n0cqt9pDlBURjelSe+9sCrGqmfYhF/6BN0GW0w9yP/g0VRFItdh87mN7Wwyg/tKKj4FT77xBENZs0+B4fTu
# DATA 8z8QYjUB/bUa8W++8brH086U0aCqq7Ud1iXvZxi0Q4/RPR52L43gpex4ND6FYzJq5gyRR+zcv49Z2Nb7CfZxZzWyY3zobb7eiyfD
# DATA qLuFMqKK9vHHMAc+Jvtt19v6+GOU2Mcfb0mkpfiuqStxglPsw+gy3H6b+f8qjXJtwf9XLvs15/+7iv/++kc3Z+nkZjse3STTwRsf
# DATA TvvJqPrKj3/8YxbuEF4tFl9kYQxrDFjxxXJFMo409FZv4HqozSiPZ1uDAXULa7yCWKao1/Q37GnSn/thCt+g/hpDH2xiOQHP7k+U
# DATA FUTztT+bxgPzjecQ5ls6WO2FpPwwDslwYvsj5/2T0/5EYHjmArW3nPOSYz+bDCjy0onqJNA1ngdSH8PrKJ5M5GeS7TJ6ZgOpGiEo
# DATA v+/afR2sa5r+eO1DLiJTMGy0Y0VlEn0SqaVA5I1MQFMuN/3en4/3JmE3+gWED/SLF+NihijKJhm5sKFsm6ZJaeY5kp52SUL0bepR
# DATA lvFBkernZPC3HDc84eE7LOcNT0KxQXSLN1Rt7ejwZJIxZrep8gBgw8+uzGTkHVMcjJnquRQHrWe68lMpTj9OD4fYL7Nt2ZWczK2j
# DATA //3oG+/oj0dfH/370bfHXx7/09Hv6fM3R3/xjv+WPvzp6M/e8d8ffXP8BV37o3f85dG3R3+hW344+jPdjh++PPru+Kvj/0I/8dN/
# DATA xtdbHuYRsOwlBmp4VNGRc4+lIYz6bfmSKhuQ57MfJ7blx0unu9pf0lvlE4nI9JB87s6G41T/Fo2wzvlxmHbiWOwTbDnDWLtb0ZM1
# DATA 8cl0Czw5ZnUnNeEdPkH3MTaz3FI2zSXTgmK/m0vREvthboqJl9DUEtHKFziW5g8wg9zl2eOqqSdC6vSpBmyrSSiiOUq2d6Ra7Kye
# DATA pyIXl/7cG8ygRLPwGmxTnn9LdleC5QUGkWnRKiln2+dD93CG/oiMC5qh5VNipvwf97rWjD6Xn2pa//ANe1r/xjsP7997/LOH/ykf
# DATA 5YVpdi4d9tvyzy21wdWzjIlf8uzCM5JYtLwSV+CUM2VnoexmI26D/KNq4LK2rBxUxi0O75RSZIMLqrrC4b392q3MefZR7lvxo8/K
# DATA hbr/ufX7zmsflnZuqAsffVYp/P/svXt3W8eVJ9p/81McO7l9AAkAX3oZCuxQEm2zLVEckrKTphgskDgkEYMAggNKYtPo5cSdTmbi
# DATA ldz0yrrrrl6ruydr7geQFautOLbzFaSvcD/Jrf2oql2PA4CynZ4705lpizinTj137dq1H799ZRnuQbJpwRb+x/PP1fb/d7XJfwYM
# DATA 4lO1479QLODL5PknyAme/1mxhK/Uy69UQeAGjyvqmXryoXr2OHn+DEp8pP5+ZtTYyApJUdgFOJSSngR1UBmPyCYcH3r3gspMTCVf
# DATA 6TzdJVe8k4LHaF6fnwfew/NqKoCtPt8adOZVW+lufJ4XLi8E0/B/Pv8UWJ/ico+B+SmGSMNTI1VzgixTjf8ZvAOG+EucjC9gvtTP
# DATA 518+/1KxxKdG162uqagHdrSlldTRZy8m32uwDhqLl+H30rT1gd48g9V5Bg1D+0+gm49n7b5l8XQWvPjNi58BWzeLxzoCocFG7Qtp
# DATA sLGjUr83Qowe/De4nKtx0gsmAsfiY9bQ2z1OlTvX6ruyOj1bp3SBl7ra2FK+9EL+UVztNdaPvyV3fjS/e7FcUptx3u69WvPvq+rp
# DATA hfL8GykrewP1OFUIbnw9AHU6RGWymt2ztAYX+1otHZMHsH2Fn+ws7WpKUrNWnjJ0f7x1Z2sT8WDkR9XSToLfwWZ+8dvnX1QsB9C7
# DATA HXf+Y1X4MVSkiinO8PwJ8ADmD6pyPdd/evGxorCvgDyBctXv34hZJSDD2E6msS7uwk7W45ZTCF92ekyokydhyl7ACfmT2lpqyRMc
# DATA 1Gcs7Kgev/hYSTmyx6yIYkMDIBtKbkdvY2yOhnU+TneurW+WdfJweSjAdUkFOIUTY2n4hfYsVQQ2IxImrwB8ZRgs0LIiS3iO5g9V
# DATA DP9tNEIOfaBfcuE8PJR+T8N48VFk1b588ZGaEyRjOJY+Rdr6mPZt/PzC0+m6806RsZqwpzSRUHVAsi8+TqgEPDSUwMuN3Y6ttrql
# DATA lkb997Oeu77FBmzFLu7XJv9WXEFW6Yv01POPgLOrka1srFXtZpyBIHhEpXRlY6O5cXdzu7G8sLhwv7e5emd95b2Vd1ebGyvrq7eb
# DATA 9zZvNziNDUrHD1sPsvoy4D70UmcXpvZL1Znm9t13VtfRWIGDIFF8bX17dXN95Xbzb97bbm6t3txc3cYifP+tYdHmUfaotAzSu1v/
# DATA /d725r2t7ebG5t0f/LCxeL93Z2Xzb2+srDdvr761cvOHzdtr6+80V9dXbtxevdVArFk01NBqwc3Vl8JiK4S6etYgw/2GoW21gIaH
# DATA N6gMWapQv65cvrx8OViifyPeaZkNkeaLXxGFKQpWdcFL+t5dFNuA7j05BKM6b5ZRsES4Y4gJhMWlCdKgoig4EFWXQUj4XBHOl6rf
# DATA T4HnfPHiNywM8pvHWtcSEfy4v8LEV7IW+rorapyNQ2O5KTzJRQBXY2fXkc/B9B03e6MJe9/A000yZNvu7aivdhHMDr8rZPnarbXJ
# DATA xraSsK0NsmyYqzvOg2w47Kg7fZpaXQihSKLqQ1tu++BZ3NmnwALErzA+s5qHJnsZOBCTFgSFFFAHN/xZA6fXcObWqZ07YEUzAilV
# DATA ACey+iZ1bzzcb9SumR+vhGWDk+szZLLqXFKUo3jOUyL53z7/HXJWeAS8Fljxp6CKUFtBCSBQaVWXfvFrh1U7xzEuAvUBn/L85eE8
# DATA 8Ii3shGY0PPIZORES0yJvJl0heG5nKDQ+CXKNX+EzoH04B0qX/KA4B/1m/0AQMyEfaQ2vJIv1AEHH6nq4LSCCXtqlyQ+7+zWUdy3
# DATA WWaej4LPVV9+TecGdyIYFp3A/gKwKK47UQbKWQwuaj3QeHUAddcUVHwsuMQbom4YjWIpzjd20lsr2ys3VrZW4TRKd8s1/a00ypTe
# DATA yU5RZ1dJAu2j156xrvKK61fRg1atFZDpn3DlgHUjM3xKAgjIaPDQytK0oEqyVKzzs8TpuJWtuB/6T3NdNhcPvEUKBgm8BNYfeYqz
# DATA TeGJ8bvCFfF2AT7mKugJBOJkcjdskjuJKtfJcUJAO+d5NZDNyRqltbEZLG1ZcVvranhi+8JYSKGkpGm07MOoSqL87Hu2XOsQkmdg
# DATA YMXpLdwxhUNC42G3g/A/avbxT700FIAFT7DDuvfUsxX6SB9MZU+NiZ+RGnMcawyMm6CKK/nThj5dabnWpSs23P90f9xDi+0Q1G9y
# DATA uBD9wzQBuioxHPUcB5OubaxQBXARfavb32t11zYeXNEPvV6rwRkaVp/rGWPp3jzWXQonnikcoMo5oJeVjJCUoFzG6dDkJRXLeIGB
# DATA IrWTnhK6Sxd0RWQbAB8vONJ4/6DCGItL3sU1oSKhWBlkd3H8sEIm+VNSjKl7wueoNH8WPR7wBZ0C17Uc9QRZ7Md4vZMcIiH9xFOh
# DATA VRMHgrPt9YzEDgmegZc/oaGDaip+C/Jr0elQwN3EOaC7JTktd/ulGa3bWVWOCphpewp3QXFw1ZLnv6OT9wl2/Zf44o881s94Vf+I
# DATA K4H3l5twwzDjWl/dfu/u5juevBSbYp2uo8/j5d85OleWuHgZfGdJcNwnEbopTzxPsGehOMfjKmjJyiyhwQQissrBFySgF36E/rH1
# DATA ucBr6GzscG+jFYyI2qFXK5Ym1hfyAV77f0rwHk7X06fGkCtdPx2VjblFoST1Id55nyXvrP6w8e7K7XurWk+iHnieOngTMPmv5aWA
# DATA 9JUQQ4/5deFiEHU2UjVMGEa051+ike1TFLa+Iq3ET/GiLi5XrJslbQ5cvP6YznApQVdXPRpid47bmHtfsT2dOMHeNVX9+d/42ofa
# DATA UppasV741BuA+vrn5uKtPepVz6ThVMdUWIPq3ES/aMd7my/frmu7uMmCkAvT+BmyuF9oHVHAx4gfw5i+oqGrQf0mcqu12xYsZc38
# DATA qLV0+YocTbtzCNGMDe0hUOMiZetlK+zCaAlLh3txOyBssv2jk977sMlQjO62jvfarbq26GEuBhF3UK4ke6mvT6ce1ShGuYT1OePi
# DATA 90fZI/rL2GooErUJA1FHqvXc5ct7vz8KvXrZatalZCXE8gYkt6LOFpyaYSRgD8YzegAma/hA/YQTbGAtiVtvr6iZ27p3Z8tyXdAy
# DATA Dhwr9wwRIqRBo5rLtjPYzZkUIEg01kiO1hMk9Ce0R4mg1EYwhzWZYmG483IcEA1BPsQO+ZQvpkmSXqQeXkSHf6+Xek0eIBpBk5bG
# DATA znuFTpEeGLtTio6bvkzoIK4FKXO/GPYfoigY9F16MZRJbYKO0FLqLjSVqHVoVQ/Q97WcJCVvdcrgvtd/WGwo0WYAFOOh21GJpnDl
# DATA NJP6SsgweFyw2vjFz+EE+UhxrS8Eu8WkjA2cwfmYHQKtwDFS1C+YrNXTgFkAgWs7R3Qs/+z3kiU06iUo+idRYZF6RYwOpxEFbD02
# DATA zRUY9Eqd99ZbvEZx2DVwu2Av4VHmP9Su3rl5wrKNU9BIK4ZkUe1EVCulDuoHdjHVCjB0+dBG1q5TCTofgErL39H3eu/3IFrfwL7y
# DATA F6kXXMTj/l7DJzFBXqhq14vhrgA80itAZ7mvNMFJ0ycd7a9wHsvx6cGRcYw+fIJ3QzGU4uGvI9wJvOIO0Dyk7nLr8yHVyeGrkDti
# DATA WOoQw+wg9wa0BoynwYp29PIiwly6Wy7HqxTD9SikbO9r0S/xKNCKAujBjgwZ4WkDOjvoqJ4N0YWXq96l6E9oFdm+dtewwXPcJR4D
# DATA d8tZCfNNEVVO+FawxF7ngEQCMRGzfOnPBug4djiLSEqGOExLg5cQamSHko7Q6Kk8jiFrp7sOd9UfEB0BcaAqaLNP+QN9GcIdNsbx
# DATA IglUh/yBR7uzbaj/hw9UZsn/oDjXH5RQrK7KL/7RcjFSVSpmjndlJZ2p6yiIpgEfRx5oOCSJzu4Va+Ccgq4JhLk9HpRuEJlk6a29
# DATA vN+FfGpigvhLU+88PJib6ZBQEnm/+wAzBeXNYdZtjToPsuaoL+OkQBBwyqJJNQy1ckT6qpFWJsjzv2KB2DoAkhD/BCysOLOoyADr
# DATA PV7Gn/8Bzh26tTzG+X4izIh6sHrTILMKj8PpHcaj6zeqbnVbxzv+T4GdFnfYFdPduZpjCuhlJ6NhC4AkiBK0RkLJtQZLBlCEYP6t
# DATA bQbQBA97EOJLeZS6rdNsmCeQyTVpHYwAx7zfwwSy6Cd6ncFaKAid0FZMQ8ZSE3OwsfxNn5j6u9pp67grj1L7gp5TWEi18LvC9+r1
# DATA bkjEFllnPjF6dX8jFC5xxPc0ql/l1tx9KRbCXgMFZaEuEVdoSu2BhyCvPoaCqI564duKP11z47dxXPY+ChvuLNXoSWk9ORtbTYi2
# DATA OdzdmmRycHuB3qn+zPLrQsn2MUq0z3B3glRr3Ny1zg+lDdgmP2dHkS9AzfDEGHnYQPGkgN+SpY2u75+izo3UlsiLnzqKCNcTxi5W
# DATA zC7KoEV65wX3SJbK4lcUcXhSuUkn55xzc+DzLXaEYyeT7ySMaku4TAw01OlV0dnVTC9je6n7/AMCUep32wa1Cclpzj9TpzlhRy8p
# DATA INSj2uEfQKH84me6A9XgbknR91qe0K2yC7XdvzyjWEhPXkTc3EnNnIM9zXJOHhW15pQCWRNkQ9uY6xVhUQeMPIL+EcvLs8+Gc+wU
# DATA z4VWNQheqmUirwe2aeNFX8h+SHKCx1JsskpCR7kWSlr1GaITNRkbcRv9TRDGwhHzipWlUxw1CqfMeClrJGqzt9yW/UHo8lFpRr6M
# DATA X3t1CbypUEv0xp+v81yCw0HOcPN119L0HLUbmH9JnQ2I452VdJCGCOTsWqwBNiEZ9bFeO1D9w3VIWpvO8AQ7YGGukjQBTEGrd8Y4
# DATA KVCsQCf1OzXiT9D0QUajx9pNNQnFpyehNkonBHWJ12zuGS4BGPVJVlpNLhDAX3gTkLvDfhslHfd1nHhsGZwpvbXDLkeVKRt2+OIa
# DATA rDtMwZI61gc/yQhom2C0T46lTkjOJLJW0TXXGK8LTmOds/eYfX4A4LClZu5IiZq2HtnJYee4hT7UxQKW6B4X926IuhK2JE6m35eY
# DATA dcA2bPWSE1bO6OMWma7rJaAZuuwz5e7xl9uNj6LNSM/k4IojpoDs3Mgl/sfevV5xZOS47vm+iB4SO8QAACyj/53bEOmmbftaC75+
# DATA 99Zqc2t7ZXvVxMOsrW7hjmUmivBAcMJyZ+y4UMlexFynLA/lbXJTAadWSxxwPm0ORXpw7NPGRuWbL0WcGIfLHHdyAKt2o8JI1ZfH
# DATA DYz8vbmQeHyDY5VgIj17DPdKg8KYaDxpBwmnjtT60cE3cAb+OlnoX7161d6IzSzLAPHNjFAkGDk4e9Dpn+TJ2p2Vt1YryUlOiRHA
# DATA H/BhJtJF90as+1ObZQBomKJGQrpLfnLSH7WSHyuSgIMdF/IhxoUPMzW1JxlGn3cQtQiyd7X5FothGScDG27OwYjEAirezkN3wl13
# DATA j+r7mVtSagfdycSb9Ow3QH2Q4ldqMblnRQuE5SrBnc340HZbvSYBS4JeucnSfImGVqFZhpj//aMOpoEXrpyMOcIMod0AktaKA/4h
# DATA VJRNqhJfSLUC3R5srgntQWVCXtU2BCoQrOZhB3DacE0ftoZtq08A22+xSpjU6hhswsOZVC4QPP4JXTCkwudPZB2lSLHH2siboJT2
# DATA VF0+PyLPGE9LhH4iVj3+6wKfQs/iy5OtkbAcCLkYUpziw5TsGZhw/gHAYn1w/7sRaDjpPe84l5BqEfr17PlnZMUGJZSSqNGQ9FFk
# DATA KvjCAhdvjCCJDe0BBSZjvnezVPywcPT83h1/zEv9YumN+v0a/Vk+W6xQsB99PcugtfsnOSP9FM0X8aGSmSkcn6atph2oS27BWIMv
# DATA 2N/QPSLCSfG/e8nZ8aspz2pQJDOPnCnX6TcifTN2CTqtkQGfPWYSxXOVtFsCjwZ1jx+UEBTMcUuvqSMJ4qB2FnaTC8ml8k79kiem
# DATA QcXBrMCeoDcTx/d79oqAa/ZjJGFebo43MiMDvdGnpE3igYPvxyQL5HXS2wOn+HfDMRRJ/Zw2k+OF/Ckr9p9RQDppfDVlWSzo3N0+
# DATA 8g0XVkdg0/vAJcPINzrLjl+Un6/ILypBC9aa5NOpKCR8VjD3gOwhczKnTsYmUu9c187eqd8KO0tO2AE2KNi1uQP8nvWHMK6aTje8
# DATA 9tHwp6bGKWRurv6n/sb1Z85OyjkGKfsaLIVflY+OSQsqFmP2tvhb43YE06CfmRkQhcIhCT/kgEpjLZ3DL8XxbqBY7X9EHeJPKTbT
# DATA 40+BAeepiSf0ORflVoD+YoIOZ/vBky0SrwCq2N08zkuyfbMkRk5rSiaigkZAQ+9uq0nt9PRs+btFvjOVquemlwWzHMznv6r5oSkw
# DATA 3q9/wsDCT4JIjq+QJX2E//3Z8ycs45x3LgcD9KrYoWQn7JveaNieo+NeYPNminAi2YH+qEJLfvzbELaguEJq42+CufnvakifYHDl
# DATA 4xe/fvFfmXnr+dEhDVGt258prkVVwFIDuE7/DCn2I1XT01CM+tzEvDDAS6Mgaoxd7Dc2OGBQgMuyoLC8pPXPVBWqnS8tvHZFz8r+
# DATA EdENtkP+dWR3u4/IavfRawXhVHfDWfknZ8QFRBHVZj/Dkw+dEfGBGEOR3p5dLCYo543uu/ASxd6RTlxd1HVjNwpLQMpI1NwvSc7H
# DATA LmlTdJb/IqJ0fRFbz8uXTGcfBnrMgHVpVabRbenMADx2eu4MHztWCW5HebYKTr4biCZZLhvrP8pnIIqB03QNQI/ez07z0s4Froeb
# DATA 2JWf1LJHI1AFz2Zf1r58Uv3uWS/MRRpqrwfuZjMb12c4OELVcTzQzvRU673PyDSCbqhk/QOPMFLm1yO+bkHnjYeyZvmQ6h0nwrE/
# DATA pzXFB1I7NzpVE4Xd+JdsoFD6qxw7W4yrketfa/cFlaZPNUopYVC7s6r9lUlOx+KktJzggU8jtm73M4E/n8fygwtqwHYLbbyI1RJd
# DATA 5AkuMKazuErS6isdXKxnDA3WWUmrzZGeWnHKd3cfNVr+dneC3QFKhoKgFusDXjRfjsfZt7UvFP9gV0zAnqu1s2wAf7CiSngKWoEK
# DATA Tva0ork8R4uDdviVRvCwyBWnwD/gN9pJ/ks0q8HhjsgUCcRKqTn7AzjjYLioDRF/8ZE+2iVGghAGI04wcalNb/6GnpUdu8F3cewW
# DATA tCK+tbh4EBTjBqBIUeULY5YoOu0dcbuIVrKDgwwVhKrzJa05nMauZhmRqXjSmIr1PfDjj3o8KOcZH9bC1bd3i8dFw0XQalhb0z0a
# DATA ID134qzDECQqFMQgOfXCWEuR6H2XoXNxDxHAmU4qQr3r9K3VpsZrAUbNjEJpU0nAVUhFmMaDTRsNvKIUMu9zXDtQRfIFRaQAsdlo
# DATA J45U45CbGKiHgBEO951mWC59RX2phpmi/w4IoEC83opy9gwdUcqL8X1cjJ2F3drQoBXhk+qiwS+q6zJyOURbiIakfo0OhwQkrv/+
# DATA CcOhtzv4WK0pJAMATHAlozxCR7lWu41PlECWHXTeT6PWyef/VrhzYbP/UlE/CKa/wFgttT6fUxSo1lAltIOewUbBLYIBaFAOwbQ+
# DATA RA/KX8s700diYXgddngCIZIL//IL1Ab9QSndO+l0IZEGGhGEzWf7qJMzCwGcEDAh9BGuDlycMDmAcfGA18NBv0smbjgxtawg6htC
# DATA PtSsB/RBwMRsg4K8Aj3VI4Dg7ELwjqqwh4kPTPwYwBWrA7EWjlBC/MM4zy5ciAU8+tKXTUABZ6i4LtX58mZACVPQ76ff/a6OTTYk
# DATA Kk+ZGNeV54fRdkCnhFlKdjGsGG/yu7E+cyoQVZZgrmQ97GRKn7lxs6gYp5NCqMNJLNC9i3035wbUCzk57HQYKq85V+HRG2UMxRM1
# DATA YS3DM8Ip/D/ZCWHWrnDOjclxiNxRl1xb39peWb+52tz+4cYqLCtwM7VDkJERTm+fwPb3j7L2STcbpmNfa0j/K+31+90ppMdcmCRh
# DATA Zz41f240kqIqDA8qF3RAzLyaD9aNQkvql9iEtAupLU34Zeew5XkCPcI3eOwaIcfG1j4mA95niFP3VImlzzg82PGemnz4EqwtbouL
# DATA SXo9tI2EWlcneJTMZMaZ9kmxGdX4rxtrsOuiFfKDush8gzJlhLt4NNw1R7ZDxFZ/JuRL+MLRlsGDmVVl0wXPr2KC59M4Jg2amT/n
# DATA GP0pwvUE1j2N/U9h5HQV2++26C7mtDiRNagZNd9Jho55YvlFbA+9gkA4cbFl8hw9cW4sGsxQRFGEtnlr2v0DrE0EuOK6JvAv+FaM
# DATA xsEvtdQDlj8C5jsnxXtUf+ZOYz1BfhM7/MduIIV7OcZbrsQyNfFTwOga2oEjNO81SBteSaRutLGDl3lS/ZV3zUurQmzIAiLzVETu
# DATA Fj7ICG8H6OqB4VF+uQ3F7qlSLBsUFtwgRk9IJ1bfWVCXv+ULvtgw0r1377S9n2p+x6jfa+Oq+fvSuHrJ/FhWL6691trbdZ7ovxfJ
# DATA T840FmczhOoxEeYzDIx4nJzvfHiK7P8xOUb8AvBQtCuAxVP/OIiQ2ClYABCE7bBk6MSZ8ZSoJ4sQvWPU/3XfbxRlCfLcZI0T06Cb
# DATA 6cUEdIITlPlbfUyaNVRMWVUWZYgCB6+61rPoaF/1hEYF3eJdC6X4z4p7Vm9Zz6voVhhrX6ypWnzUhGsoXQOJgj+DoI5CS4gA4sWL
# DATA ZswXX7ptEvrjtfE2/XFl/LfsoH9fxzZjt+CS6wGAm2Q8oT47Es6qw7L8gGk/6ise7FXwFL6l+NegeRvTGsAq2457kEjuke6AHX0F
# DATA J4rRZ6AjWMyQU1fngbo7f4LHgz4+cF+x/tViUlerMsAnhBIqXGHbffCVkbmV8ohC2p34IIAwtzgfDzjNSMxhEBwJLUnCL8/bCYFJ
# DATA MILTvMt9yLUZPfEKI2X+DM47YGUrPHLjWuzQ5AidnBYOVBIlaSi7RZ8EvtKuscHMyH4AUMlKbK8VV5ld+DICwDrLBH1FATTo1MXC
# DATA 0udSsz3BbC2d1HcuUMcs11UywwU7WOa6aFcKwy+F33oQfWSyrxYbEmz8RIgBBDuCq5gSgONiA2l/Bs8yQp4O7CLJZn6y/cOk6jP4
# DATA D5w34AmdwxMWgP3FnkBxyyScIESEqDcB3cedUdGWZPNH0wUZmryLX3ZLzBJrgXV4URba4BwJXAsIqD5z3GycdMhSHURrhkEe1Clh
# DATA 6ccH1tJPP2dnTdPM+08M9yKouULqcFB1rFs6TpTrkD7dhl7oPy4z8ISu47aEJS6PRZlocx3zSsTmyD8o9jGVSkxvdAunyNO+1r0e
# DATA t3pKAm8noPYQeePYaZ8aAddFSGYO/2o3cukaHpPcZ/QYPBcyuaYa/qUECEjefh4nNiFo06PzYJj/BXcua9w1YBkL3a4t1h5QmjoL
# DATA bK2CiZLr+RP0siUMNfI0nsAyJ88a7SpzP4EKQmc8IZjEpPcgB7d0ufPdzLwj2XG23XUEX13LObzTASgZHewZFwIucb4GbzqdxDoR
# DATA szHTsjk6Ivhs91sycEQA8xXfwb00jnE+7QCgMeEzqD5rQiBXk9iTDuQqcbALMKtzhd67SGP0jwMz1rPw4dCG2RC6PRc/hTeDH7VH
# DATA Mjf1hgLwuRobY1oEkRRueSozTYLVpazcvWvBk7SsPnvQZhBNZ0LocFYiMZs+AJWPEGSHPg0lSIAOfJsdDoJMZ2CdASKRulG5konL
# DATA R4NBR4Y7cXvqZZWux7tFwlVIiLOFjv7vGjZaTDMUNsrK7RbSQzcDS3H/YQ9SNvZag/yoPwqN3xLzOX3Q754c6+PGulONTgegYkr3
# DATA Or02msuo03WZbxAM/bRO9cQdGgttLxW6TvzWfgoS4Uvp4hLX07bush/jgIvlkCbrHolKjRz9MXbZRjQM3rsm+kHqNLxZGI3dyWXB
# DATA pQ2a6NfVlPsdieEK0q+yOLI0Jin90sdg84SygOogKO1LOcy6WSvPOGd1fW6q46UHLvt6cmkh0DSau3VPEe6ws28cQtUe7j/IKI+k
# DATA ImxS3HMXfDfQyZlnXhvbyDX8aaLXuM1yca90vBlFmJnYMv7QiS5zdV/w2cWktFApJxeS0qWkyhc/9bwcTDTaUkoyuHJqDKcfthkM
# DATA IWVPl4odjHFM0X4ygafRnOuq5GA7j1qHiEjKddSGAty5nnrCrcZQBo8mSmalPq+HQMpcWdBVSw3T13GuEDE1LaH1meu6qOoqqyqq
# DATA pQfB4/Ib+OKNeuu4feXSB63h8ZVL6iGeE4ceKJOdHY08akDyrb6oIrBWg5f++p8MCIi4ZCt3s+Ha5zL1Xyk9PNof1jp9m0dqnry6
# DATA zK+Q1vjYaDKAuvXmNOKUadoOFFEqGj7BxnwkLCQuLobpdujCNuf5zJxZjzPjg4Z/VAfD/qNT72eVLvVD6aAm3NtCVzfr4UZOb+OA
# DATA Gi2a2MxeNeBggdGoszlixB1whGe7gymDdUddN9Dw7SK2TvLvCMZHUCFgKbaSEqvLtd5ck5GRouAV/uuaxWSxSB9iHatEexst6TUF
# DATA 55SSaJxeOn0by00jr9Q0YsjQAX/QHZQyu/Ak8jZp5eCg55+AuQ9pQJKSjZ3m33w8CaCDvFEqO0mnmwKONjxp3Xplpo6mzedd/J1p
# DATA Xx/VFv3DSNyiA4wkYsVe0UiAMnKeUO7JDvBGiWB6YubZKnJNTyLv5BTGIRv4SBi+z+AY1q//UdXSK8+Sn7FKbFGqIvAKd1CFYS9S
# DATA udAOJSnM9wP0x67FdVmXMYCJq1MwMbEPTanUCCaWmw86vR7Yo6MkxazdTqvD2PmAn+HkKhgkx3ntxPAbdM92ZxmteTNbXKxcYz8W
# DATA XhUsjIeHzzTYsXxTCK1cKo7tle4h+mlZH4E8DHVdIczwoGKn153pJ3puQx9o7PKIH4daPGy5HnFYn4lgClstR6jo/JQ0ectQ//wo
# DATA qxkp54B82YhfOxkThUazDZ7g3UhGPM4K6LvaWg9a+pAK34775bK0JKUINdYauSPUtB4nd+LA415H2npb9t1DI/XZspGQpkRTho4Q
# DATA 96gjnsDMW1KfMM+YCururKwRaaiznCWsOnd9HAqlM8RXzESusQ44E3suuvT6gr3v4jaWa9AfHmKiEktfNbqFuaAuk0nd1N2JXNT1
# DATA y3Lo9u5vkXNtDwr5rFi0siNFQL0Ku8nrSzkwP2diSuEwKoEUEgpTqYOOQhlxGATlKbpUPlZyHykhXAGxFA6qEkg2obDmtud6J2DM
# DATA /ufYIspSRVGvNEMeXRhPg2kaFf43wOnSNfg+r/r56zyWMEhq2OqoFblHzb5LrSKWMru+ungy0kdbZ7OHrG3/lRyN63FX18f4HU2B
# DATA +rDCzkloXNJviVI8dwMNYSwNwMbLyLexGAQmM10Va6iJqaQmWmNixpH5b9w0AotlvzW6YGCqskrdRVtSCZ1HDt71+eB9CzHlWzps
# DATA Mq41jaIWsAc8wRZ8C6gEqefAcS70BepcgOUR9bMweEHdbslz7wm8HKbC6oN7ThDD+uLXEMmmk8lbjFl6I1CYrMGHia0ITcFzLKmf
# DATA C5NUmtIxucu36aeJKIwA00Cg3jpSjpLakbngJFfn1d5pkrWG3Q7KWMyLczqjs1ZbVNdHtMeBusO3Rozg2FGVd44z9dUxSMf5Uavd
# DATA f+jizdZCmAXXb3T+P9JrdH6Kz6jp8/+ULqMz0JwZADuN2kXwfEbnYx6jLiyphCZhF1J3N9R0gLBbVz0Cu+vCG8TctOoBdIO9VsiN
# DATA xD7J/Z66g3X9DA8x0nC0BfpDtz+2vuIe0fKH9SfEgBHFGw5qD1KJnFZErgMdl2KYMsSjcEDuvxs/QRFU/ZWTq+039Ox8VGHG99JI
# DATA L8zQI4ZuV2CIJIYSvosTAB70geg6xQZP4QwJkYRkUfnYFrYVxGr9SwJH8PEOh6BmgMUAYq5mgIbiuiFFUZ2IdL4SmDjF8CkTgCDc
# DATA CMCn7gB82a8ehYdwxLuoJwRy6IklPDwRcWG3N7iwqViiN7+xaBmvuZLdaUVKaQFbQTXFZGXbVz/xcwyjyXhGXcCdpzGaXip/yITc
# DATA IZ5HuXbim8DSriP4F+WNU+ffZ+rpH3X83Fckg3lAmvjIIuU6ST98j+FeO3tUMZJghqbBlkGongqbE8uG83py7QLkwMH/THAMt7BR
# DATA 6PL97MUvdQ7YT2is6oGbvhZdcMB4E0HJ0bkz6m4vK4lOR1FPwpQZnKEOJgFKHpNFZaF/ZWFhXDhwD7VD9UmrRBHF25sSCepdScib
# DATA ohE44JcjfsTRnBoVnZ6qONWEjHjBJTf6DVWTdJrQZDrdNeWAXU+4wvEkVwopiTb1uWQB6ehcEplAET9dibsNJ1XGVJ6nHbhiZg30
# DATA ohSWgLplCsJIUY858oG91MTP8V9ECk60WIE3pZXlVw1LVrczkObzBHhNAum9TvWtlNDIW0NQNmLOVEJzx0pFXTD7tWQVE4iBsKA+
# DATA yxH0HT3Bum2GtB4AYAc2whIFenSPanGY9VDemubdLvdCXA5lBO1v5Mbl37Z8WVUj/peDEiHU/+z++UaW+sb8k+Je/yLEmNN/reI/
# DATA itqctOlO4iu5w+LVuvtOMAJQiul7eG/kgQgJsUXCFKBGg2AM3GGRSqvdyfH2WxLY9kK3aRgKY9praReIWaLZG3tB3LwgYroiNgSW
# DATA J6ebEIzK33MDPZflwfAkapSVK1wmOOL/OcwQjhCnnhc6h4rx/KNHvgOp7YVBqVPxZzaxfZG8/GujdcGuNmEvlfgHnwD94fsEWu0q
# DATA C2c3n9S4CtDwWQSnqEaQSzrqQNMB7kE6nxb48ous9wnOHMEqPStM8lUoMVWr9pgrQECFB7vGzM0PWC6dcV7oMGjSmelDW1X8hmFr
# DATA lfRkzCcDMYV+pnHkvo7Kkh4LIGoKXCn7ir7JycqdKUZoXgds9mkiVIDTpziiSiFcjTgk72y5nHm8BXAZeiua1xIdN65T0oqgcLCy
# DATA akg5Yeu6HsjnEtoYLp0f4n7+lQic4QQQnjYUdZNOj6mF5jurP4xsg/8Rb/gpqZohty01qa6Rsh5HM3CGUEHHLYYFkGKQ4NqBHMiU
# DATA Sf7JxEPrmq14MAGemzJj3jquAPXEON3ZyyC5JdPfO+laWwlhbsXO/buutgzVsYtS/2jYEkgBO7vjCdmv6+4ZDzf7zkZ/SGE3A/WH
# DATA BWBC9/eNu5sIEb2k/pe6fq5YAZ+Eqgu9XO2zY+MsFT8S2ZHVcZGquOAGhDCSpsYTMQpQIsXNr3V+Mij7uU5B4W/C6CjF/iYeEnsY
# DATA LzUTpGEheDozo9S7dJA4bHwYY1BXMW8YvhaD9yH8PCvtzzaT5ekTV3eZXzkO8oX+GK4fxrgYmG0iHFspxk4J3isgN3gciMulCQ6g
# DATA 5ZcF3vJ4cQTEMOxd7ItJqIaBu9LLIlVGcdC+JZzK/yj/35eFHTWZWlwBN8y5TfrYz8HDwJgJf/v8d5WEMdaiak8H3ulbgA5k32Xc
# DATA 6K7TVhH+nr1y9Y1nZcH+KmHtM+L1CRdw47pedcrbx+JLcVdV3xt+V9gnhAB02eNkrD+37FwBqWgxnjD5bFfqL7EZpwKanmP7xw9/
# DATA gvmeSOnWb2WCrOooIob9kRKEyG9RbbK6rmJH/aCAZfUHmVyFZIYXDH7BH4yL694RwgjySLiMg7DCnxYLLOWY/ibEs45slig45tTI
# DATA 5R20fddEeEwjBdYHTjIN0CPYMRWU3I02KBGbIrWDOsssBF7VyAZ/gDt6REw23undcwxQ2+9g4fSAyC2D17livTRMf/TprFecJSFV
# DATA cUxxheZb/vKcc3924YJ6VEkuXDA1jMOU6hVnOzoIWurrkurroIt+/kfqCCGRA/5qAr25ompupVRdFmzDfdhZJf1EWz/z/CElHCf0
# DATA vbxG2GVH2aPS8lJ5ziRFQLkrhtfnfaFIfOPu1vZbm6tbzY2Vra337m7eQs0/NeRFT4jC97ZWNzGIQpyW5uWtG+4rvxYPXPBAnLP1
# DATA +Xn9o36muzH+vuXe7b365UvLS/PFtb+5eXd9u7m6fqt56+6dlTUI30+PRqNBruoGUrMrkm6srK/etsXMG7/KrXs3mhv3btxeu2kL
# DATA OxLWybCbl5xVtSsPW2vnWh1uWW+/t3ZL9Wzlxu1V1bvVN1fu3YalUeLHSRYO5M7q9ubaTTvXrfZxB51M9AtYsejKLl0qB7W9t3rj
# DATA 7bt332GCaL69unILq43SBWvq1UaFyEUmZiNCu1uUCC6Unget0Sgb9jAA70cw8cOshvDUGez8MkbNNWoXvpu6Ap3OG8mfV7AXYI2s
# DATA 3fHYKHcPPjnZs+U5sV+zngQMRld20G0d5g2sckJiW6z/YgMBVlUNIbu6iK8kc4BPmBkgAgTwAppgjPjcy7RnHv3Qt2V+5QZAYmIk
# DATA Df/q50qC36+m94f3e4D7+uq5/P0QsNQoPK6Dew+niWKlqD1hObuUhGQHoHb4g2yMLNI5Np1B6xQs2mpwYIaowd9g1cqzK5dqe1cu
# DATA sZVNT4vGg6JII8eDOpIVjuvGk/b9sgufw+923meBgT20Wjez4WgjO4ad8+OHo42TPcW332GoetUT8Rp+qjfwy0fSJXfYd2HdyQvW
# DATA MTqU7ItKsn06oD+DVZET+ymo/NgBEsGLde7Fx5hZgFSCFlnuMUDJAGTsT9HT+GfPn6GymvS2COH0LJ7wlCnz4FUj2DTOiN7G93u2
# DATA Q430jBFdFU2/yjT8sNUZEZQJMtCSjl3rHGf9k1FjacHGGosQAgyCV+zgDsKSUGyhWr12q6skyTSKOBKefKxYgrpu4RMN/uDuHFEM
# DATA miQlFDv7qHXtHMARnU3I5IUx96pkPg/Wtv0j1VJtoNbfaL9sLQHSBBDdQvI9p4xnw/9eI1lcXly4uhTdoJ+gtwG4FzyGS6GbASe6
# DATA 0o+Tt7e3N7aqFl/HRMJRbu+G0xtrHWYlV9Y6YJaps/NW4X83Vt9aW09urm5ur725dnNlexWf1i68gf+qszR4l4qk26q6LYd5QTPB
# DATA gH8fDicYDN9lhRpdK3ofDfT9wEsfnufd2sbqnSYMuznqq2N1E/8uQSfU0Vsu13QWcTtReHDAl5T9u8nwF01+WdpvoXkNbghiOstO
# DATA DTXG5cHDJPmA6nt3dXPtzR82f3B54TV1PKspW7ndvPm2khicL9U53jk+ORY5euHb7dtb7GcPfz5YbC6xC3mrrWgOiBg2Xu24r6YY
# DATA nOJKcIbyXiRb1BHYWIJC3zNVCJCVAHKtMzpKclC7jfSkqN72wPaubgildHHpam1B/b/F1JxklhGo8ZSWIF79Uam2WDHNVf2uQAbd
# DATA Vq546cNIvnDogJ6gh8PWoEm9KanSpK/Lhk3NJxpGuIL6FOM6GRYJ+ookfYqh4sCsBlk2RGLZU7f0oVrL/vCYDyJDNcDANPnVC69V
# DATA Fv2ewBc/BMc5BwYLDI8QJvILnbdEIlqqBa/Shkdc+5+m5YJbC3U9z4CddksH6Vur24qFwT6aX6wtgkDwtpqaenKmZ2gMz26apVQ3
# DATA 6y74EYDkoP4PErvhcVwuF83e0sICsLEOKoWoecU+H5QuLy5pBV55Z3EX6OzSwkLxDAl2L0/Ou1t8bMojdA08ifwzVF+BLBEDeeXd
# DATA LBuUanz7oWVw2YrMcMxr8CGCT/8pEbCYX1K2zBcfX9faNorp+VgnYMY1rUTZMmZU/3fKNgNGVBT+qqSD1GZ+/MUJ8kr2DpJ3wOlA
# DATA HVvSlj/1IogyjHqbpnj26jpMPDZe3g9SykwAOEHJAu7eBXWpwmNTf1EeA+u5fr8niu7U67uF5Rxx9yBNU9qZydnZnKjipNd5VJ9/
# DATA 0BrOq303b7Tb88OT3jxORA02N1SZoC62CXft/n6/e33ujAY31pd0tetxKixBXyfzSd5tyiM+0tqo653q0S+bINgXfD0Ydh6o1+63
# DATA uq95gmy6tsT/LlMREJWWkn7v+pwYAt6u8qR/cHCdjSPqmJw/yYfziikNM5qU+aPRcZfet05GfXSns59ksB2aiEB5aeFSMq/+UxMf
# DATA tNvq8tZqq6X4QfUmncxVkESrd+lCqmgy73UOlFTdfdg6zYOvNgFJZZgNqxt9Nf2nIFl39kfs4ld9eJT1qvvDfp7zE6eabp8UIcmP
# DATA /j6ZfwQTAG4085oo8OjrdiCKTx0Rzb1++5Sko4Xr5v3hcLDfJHGFDpVkeWEh994D25v0HrgD/qWu+pNIELuIJEgVjMfuMNQo7t+v
# DATA ld545WHW7VYR8GG+rEajTrbeKThAXw8+gcHCqUruCsl3T4Yd/M980lALheXV/1f7RbEDUjusbbx7pbm+uv3e3c13YCubLjY7gwdX
# DATA mhloN/JUFr55d/3NtbdAtYNtp21FnWj2TfeGnTbhYmS91l43gyouqRcY1eY8hfyHcMBVZBXN/gDx58+k8a2XjUApXaO6a4dqq6gV
# DATA Rz9MXVHaa43SMVdlQm/PXIsWlK3yaNQni/CBizmP42XOqC2/boJy6n+7oi3mklnOYNvloQhTq4Q802/dzNd+OnIuFCA50ImztvHg
# DATA Sp3SG5Cjkb7NPaM8ZZg8jmGUGQHU+DuQ6cczwqoeRMgETMDcEeG1Dv605IOkX+6E3+56IeP9gbbX6u/p9iYpIpL+qRQrDYTHJEj3
# DATA Pf6BpiCnvCRPE2NsYWXk/yZ8e8V+C7QcKfoIdEGtLo3AfYcZ2PBdrElvfNMNtpK8afCLaaxinu/Axj11m1Vom1Hd8NfXqN1MoWLE
# DATA +U9OMogGIPvniV46/DM6M9pfD5PWObOkUeK5wMUkbYKWLCRCwoufXizqbMR77BnC8dKMV3n/PNOO/4E3lbGgSmm7IKbkqXGSP08S
# DATA VJNgpAigFnbNt+EFMB1LwWmVSQEpy/cgQKMQstgiszVNvqwjwUwtTyGhIt1nQJKmCN6PtWlbCNIQS1zg+MWeKk91Ss2vXvycQ8Ax
# DATA SHyaEbs1GrXApuujbRm+Xi7IX6c/jBrpRK1kkUTBWlgidQGHPZqvBDKSrUlVNS5uJeUTKaW2xhPSzdqeF2abnX4ioZdeLNWXdaN1
# DATA py5KIvlpvj8Koc74cXCERIynVLLQUmobwFyCGCcSphLUqLJcOjBkgy7Zc6lX9HEf2fd9dDW9X6tdvK9u/bk9ZSoJWirQwj8aahRK
# DATA 4JILaeyeGxpHuDvaOlKetL1oB/FKMAa5GX3o34GZGvzUX8YbRMfkSszxYCuZ/mphQJB1aNARswlbAByOA84dv/4HWzYUQs7GGPSr
# DATA +yHvsbjs/CbmOtBRN5IRuBo5h6B+rhZxIfxKH7NFXx8+bE6uINyTujxEpI+Q7E3l30sWIrm7/D7YD4PeqQriM3uOvf5H259CL1h9
# DATA nMZkI5qeHTuxYC0Hld9ixdQ84TM5o+JLf6hhDZogyRXErNMEsrSMNDpn+lxwLgH6E3sHCNqPydQYRKeHVU8WlCwlB6qejOcct4SI
# DATA UM+uDLqdadleAzul2bHgzhMRpuYidBtvLEpRJElBujVFVo8xwBANVE9Rh/Yl0RBlLtSZlp+yCStkWbHUy+achunUHZsrOnNiqxcO
# DATA uuLdBoNbdFk4kE++aJG/E8yZOkKc6Yp/VyoQQljaQ6Yr3E9D8bFGFnXntDCjnrTGvLZOx20HNJ3RxbjuJcgjXzBPZHJcXsIrO0Ar
# DATA dzuHRyN9NajwcdUE9VaDw1HADW9ePZ9Xlc/Dd/PQA3CNarey4z6lKNCFs9H+PF1d5ukthzbzVEAH+iejwcmo1BoenoDTjgzFCKwa
# DATA 7AJIDrH8ozY86dmvAWJgoEaZNale1P6Tn4D+k40ci5fLxcprUf02lV99NICcfVNkM7urQPv8sSsx00aDK5LpLhi0XJAKHhOuFGjy
# DATA v8X2NDQ1t5mP2mqcNVAUDkrlObNARAMlvGcftCBGAaSoIHWSIJVkPjGl1d+quC/7uqg7E8YY93GntnBotiF1/6yxY0c4RhMcTNZT
# DATA d5QsT4YDTR3xUYuKHCGu2wUekba6BP3Cx045qlGKSISYgOXnZKt4/vS6HhlJfU4GG3uVfdgatkk/xD3Wrdt3esOrBUXnMeG5wftt
# DATA J+0M4Jvqj/G/qJfA4uiNe9R/KIejo/5NfTv4F04E/QWcj14iUPGJdh5oZwDUDpxLPMTsA6r6E4ACyRkW1fxyIrmo0kL1nJy8ImLh
# DATA QVBVQiHgdVzECZilbdC7HRzGrk/ExfmdavXvVwGRfPEygMqb+l7+YvfHBM/mn6Gt6h8oyXN0YFpTMCMpF3WogFLDTqhpn9ANseba
# DATA ykJJ20vpsKVm5jUiDUHTpHCjK1o4htY+8Omm+pYGsJQWz+jmShUzGX344peIu/UzX8HRy0jbh7fFWshLTGONJZmA+RYeZ6LPs21a
# DATA hLpTw6ok7C2A06C2IR2PqQiwh/1YBdN1C+TX9OystoVWpxq7E4zHEI9fWrpWAQF1oRw4B/oxK7IRDg4I2lNbfjiieivJ8jJcxCUT
# DATA E2j6mt5/9OCN0v32xfL9mvxH1cYchgccIrxSXYAx7eZQwOe1Q0U0A5CWwALNc1W0ylXM6Ea6Q395eZ1WwRSXJUvXLoJVV4dzL9WW
# DATA l2uLF61yXsgusXOJXruMVH4ijhY3STkJPaQRHFwZwQ7MSduNWvJi8uXum4+CHXk9WV/ZZpr7A2ZcfoybU+Ra1iIZCl0TyDPS2QMl
# DATA 7DxUx0pVI6wTj+4d8BDi+7Z4OPrDhOsLtI2f6SFQxnqpCHlqAATPtenY4h6N9Z6grDbfwjlnDku7gVimhj+7eWSvroNNewwokKjV
# DATA AseZXIR9sxYaG4jafGJHdbT1Ti8HL5aUUFfVES2DqUz4o6vZL8AbLjIesa15BsPRLTIcTTEXreLtDyjCtfhMNxaZL307U1h0baJB
# DATA 6DwYyPzjJarRy4TVFNDY/58NShMkmUKTgGPigbvKlwhgCLzqCy7OCeQ5IO4loM2uJ071XiZdVJhq4FmCitSpRGEm/ZwOMMVRj9h4
# DATA YmmYZjSk8MVcieUnoz7MHp2x/YODtMDQjKwQJL4v0FNEHaE9PQvqK3QuRm74Ecgh4GD8M4n6+CnEFsZ8hb1A3hi8F7vQOrndKsmF
# DATA yfD3kGHZwv/jmOFwgAHWw5vXbC4B7Nrgo+RF/dEjGov4dy/RD1ISxKvTaoKbEmc04u5m1AjGdbySvJOdkgMceDii748TmGwnsZfG
# DATA PNXDJktgwsioStcCk1GL4ScMJGfv1r9URPYJmhnMTF5PirEG4zuKsJWclNhKHMrJD/Zb6WMqISd7oxI3B0J7sqL2T30yIAUZmD27
# DATA 5Itf1dQmJTfhU1SGqC4GVBT3SSGWcqDY21EpBvVjTOkG68A4vqbG/7aRLi8sLJDZ/dFpw8Q+o78+uQ1iaT/YrAApwXuMLomqhUVs
# DATA AfeCYv1NjEFq8N7DluxT2gmU+RT8BhHFLc2z7gEA9HZT+Y6qv3RpWT/t9Pb6J702v7gGb2QiM1mn5ZeybhljEA+HAUJ8wkvMvvaW
# DATA jbo+6BgZk5bnpkXBuv1quJEORnEsViTo2O+IF/u2cwBajTjHW8jsTxHTnpMLfyPdtV0zIYQ76AQaQ8/mkCV/SSOLGUIVA8w2NUE4
# DATA 28tRZJl/YyfqXyUrG2sVZ30gfz1DzTxOfjBsndpomi8ZXRvNFL+gWBqBF9M58Gk5kgjLx8zR6KQIggxY5Eooa67curO27kZGzXbq
# DATA WoTTyAFs4aMC8PkgZ3YRIlVxaFm3f3hId4Yz4TsI9wcCGQKZY6DRYc7UGf+oCm6aUGh5AQOk4BEWVY8up+wDCff2vk4Ghsnl4PVJ
# DATA rwvSWz7qDwYZ5gzl5iE5B/0VxCgWuhBqBELGbGhLsJ1xUM1Jt3PcYYfGXp/7e5bm/QPo2eLCpWuXr15RHTpSV0P7YDwez4ahpM5/
# DATA 7YxAQ2cu3WBenfUeEDobYlLZJZ1PwNv+QVrejepfYLnyxs6BDbWo60CtOnL6+GecsLWxw/gUVQqbINdXcHa1sBWEe5fX59Uqz6tR
# DATA zPODgprbGWAM5M1+ryFhFdp77Cnaa2P4OCZe4zwtR4oXj45O07GDuEBwGdM/Gke7Qa8xb6rqx0hRGOATpTfv3Kpuvb16+zYqqU6G
# DATA 3aR6kG+h93V9fh78crtwaMLULc5THYhKiTo7NSfoi7qAF3K28CBR5wQWMRpSBtgrdLAMR81BNuz027QXcgkdEfKUALcBohAH6l2b
# DATA ovtTw0CEjrjdGrUgSDJOWiZEur54rXY1fWkiI8vr0TH6XzfSy4tLx3tUmw6CV3O8/bcwzHvbN2EdLX3pHlqvaoGPMqG5WRZwcNjs
# DATA 5KAUO02q95LvfvfMiTQfJ9W28/DWjXGwmMvT1nJpYSzlM0WTBXNNO4Y3Tv212mLtUrXVHXR62fcphKh++crVpdeyK9f22u3W4vJr
# DATA +3vt5YMr6s3ytSvXltv7y5eXlpeXLh/sX766uJi1FlvLV197bfnaweLe8tVrry0fgEw1674tmljWlorvUefLylm17eAv+kVgIaD6
# DATA pCBXeqp4+XF2rGimOkCPf3qXqS05MkpecKKnfsFvr2v8D/rR+8XVbsED4+rVq/QKuBv8tVA4oGIyseA71f0uQsFU8xn6M4DD5utR
# DATA icDoEixQlVJT6rA4ZIp6g0SZH/7raMRCMdzzrJPvSXwsBhko/hIDg3S4rP8icA6JfNrQIgU4LgSvAXTn2kIlURL7uBDziIU5R4oj
# DATA 4xU5p33O4pOJiI7JcPjQRGJR0LMjfz0jkTmNIuLkOxIDKHCm3Y3zgnCNQuolqaVxduECfbuj5RikvUK33mi+0sgROIHTy+811wfJ
# DATA 8IBQdp33sX0XEzmCFQbpYzG6beMCwssd9JN3P6WNVfs+hMlgme8gAyPTq3z82/FA3+e1yz/LAa+Wa6MjdREZNl7XvgzZo86oNKz1
# DATA 339job5YLtf20WZVKnsl1Ksi/uVwmcvTuMziUkSwWHIFCz4hdCpHQFf2ss9ohiMYpOXWRrgbew4jj8hJjvQF9YK9Qm8LdgW9rS/V
# DATA Fhdrr/HRGEgRb929tXrj3lswsOOT7qgDdq/R/qCxAFIFU156baF+DU5DUAXUSR2g/5w/aQ8miRVxKTjYIzehq4ShCgqfOroYYf/n
# DATA zav6EM9EfFqFSa3Pw3/tM/aZmqd/pbZQNK6hrs9ERYiJ7VXj42SbAKYzCqSwuKCJxNbWf8JaU4OArE5/CSdDAPLEu7tZwsiqk85s
# DATA Z1eYaxHAUuziSFodpxBuyZnvRDJwoJHCqfXyMizL0g1HjjZqInuz5zFWJhCHEh40WUQjBdNKEnyjLq+581H/cD4/GcDqINZcrMsh
# DATA 5wZ98TzMg5a+Yt1gtlfw9X5/mBkQw9jnmMDdKbUbF21QMwVrGKMjz40losrCs4DilMX7cngL0nS7q/HrgpEhFEfxkoy6OezVogNe
# DATA hF0XcS58W1+sLV2zfCtGnHPn4zIU1EyOjZbNUFQvuou059ntBQshw5nM2V5yas5b6/QdcM4KHz58qCuMhTdDHz32KViWXMCX5Y/j
# DATA bwKu2erdpgM2B4jNIXlEknuBqOZhOsMvv2ofsxkheCOAzTSJLCoxYk5dble/YtRZmIIGcaBA+8VGFobhfHRKc/HoNOwuAUHXE60g
# DATA TvsPe1lb9BStinqxyjPq3Ni+JoXTe8NuHmLdTkRiO9ftS2avOHNa3qAUxGTvcN/Q2AMZetImcirYBpyAeyedNtPhifqzBv+5VCqX
# DATA vcCEaFYtzVknXnZiOfOc8UoIp4ZrNiAVvwZbapCS2TEClKnIGhkBvFKOaaAcA1aUiOAGglFi0wJgQ8m6FPPnePMHgToHJJkSYdcD
# DATA vf7Ne9tNB54Qfmyu3lqjvxCTT6Lqwd8aLA+yq9uIvzMXuVCVu7W2uXpzW/8KkAcrMehAeGghTNUvB3HUBczVcfJ4L2oqdgxXiqYH
# DATA quoipec6KUp9Yqb6IBvb7JnMvxZS+tfMVv5NZiSPB/ZGg25MqsACtGSdRMmPAZ4InzwzSu4w+8kJxBL4oJ4VD0pzbNxOnFRMARs/
# DATA kwQ4niuOXtTAuNFQwM607Ukwzhqe18yg3U96XFSSWlXrZooSyl92Whg1aZLtWHe+33ASQPYO/AKdez6MxiI5SaspPw+GAphM0wMl
# DATA ujjLrHPktQ5GcLS1ut3+Q98szp3td9sgWD70VpdqKDt35RJWV5bwmjA7qgYvH+l0XiiKq88pYu4VgIV4OHUun//fxk9DzROjjs8w
# DATA i2Li8I6ouDvlBiQYzn11jilWn7VLO6Vj2g7g5ALhP/xzq38y3JcPbmXgnIf7UjzdfC/lRC7oCc05Be5gc2onoIuRnvkm9QIXoGl6
# DATA RH/YJeDfYvZh7w37kJu1lO51em2+e6Eltp/XeN65P6t31ldu3tvabm7evYt7Ec1qRnhWvbUmW5TfqXIYUopaa5vJS7/SSelFtlHs
# DATA DzMsOzK2WtNbjFXT45QhY/oZaCD7D7ISf0DVfye5C77QkCltdDTMMptTuTrotno9yJKMMjS3eNw6TfYyQAzK2rVkFdOvaXhzrhBL
# DATA YkBVa6/TxYhWxjsm5FL0QaC7ltr7qM8GUQnBIEZ93nGdXKditqmVaI2+bhaJaL4lPdW6MQS3CDfsxOQy6Menhg4rgdKtnfpwX5qS
# DATA YjV1BQDCjf6wQHv26fKu9H2NwK3Hwqt1UztLu5p+UNBQ4sX2apMEl7uba6tbM9aX4zbVfglU9aJ3kxtm3RanT6XidgfU9LvmqE8b
# DATA SmfEkXma4PzyP+zkzZm+xaPN8SozmMLcK1hbcEDRDxACPUdH9SUKOXIDdGSyPbyZ4oao7rSqB5hxb3kJonXc2iBgjutyHi/iMRxf
# DATA gR29ULvhWoS7GH8ZuhVURIw+4AMx9o7Jmj4mBxX0oC0O1XU1zuu0fe+wPh6E+xuKWCEvI/y+2RqstNv8161hHyPGNoadB+pmDG4b
# DATA u86J5p2fNrEAOneFdXmbSfEZedBouamenCFuZ2tQVteZQTZE4oOpA3/AziNV84q6GXCamBbm9Cp5oixgKAaMxmS3UGeNC2gBiwC9
# DATA oQOH+wX/2MMGf4mjJpIKQo+Y+aSuqGGqTz5QopvVeY5n5wSyCZzK4jaq525D1c/Je6fNnaJQwcmLC0YdwkL5xFZQN7IciG/xXWZx
# DATA 0wo0XXXUhsENi5VeaUQbC2DyQmsbLRjqXTFnrvgtENDUWUsQy8hcYpmvrC6qfk4nMY6fMu+dxIGiGr+eWqu3fxTBrw7zCEYhjL1s
# DATA gi8+Ynxxcn1DW6/rs8iGhdI5L5Tl2fNNyuxZxUnLp44X4kedlFomaxx59wXgRc/0Q5iBr9TtRLJWI5l645ZCLUdV73dbdAGM3DRF
# DATA Vi6tYJefiptDqW1F63LgeY/ZbWQJZBIQ6CweArFQTmsMyMO/pN5FFK0NKWgaMlLCFWse1202ex513VYlWuDWucID04tiCUfoNvjK
# DATA rYr6xyRX0kicbDDOXSQISjfzSh+Xp2gRtFwN5/SjUYlOcld8NCvter+zZI1gT7gq+ICDo7FtirfjfrggJkZy4/aZ8vna5VwxZQEM
# DATA uqYoPiIrjrLF7+px2bAk95YlRr1VqZy7exk7jl95hgED+u2m6KFPnGf6FjkpoUNRfVuRqSjF5uIV70O6yaJfDM2AgIqOkbpTJ4aA
# DATA slMWXfs0RpDThrr3UpBJHBSvUAVSENHwRxb6IlzJcDM6TZmW5oIrjqbRegGsWkCsdp9EyLZcjK8ilGSR3Yjpp1Bw1nXtxvf4xHkD
# DATA 56MXH6pj64mG5RZ5TBGz058oOhJMslDIJfwrmE+SpdX/0fR5XStb2N9GIm1DpTR+y4A6pPa/dpQ9YtdvRUWoCpyU+XOKSQs6ws/h
# DATA zzKaxgYdJ/enZa0VI5bHGWyoIMSM1nR534mwuQkHHhCT5sUNyefcxY8ePgWlwRFSn0CONVv3cgrfNuyNsUpgMsRICw5kiS7lnMva
# DATA RHNGbKWeaF2T5sm0LswRwY+IaKjOIxasHUhhR6/crq3YVKTXz9Yhqh479heoSwmlam/ngL7WzraADrdbw7XeQR9OOHDVqPFvgcfT
# DATA RINOpq6h2agFPi8lCMupJJBfQt1/JTxPf9QC5ZrqSGukusElVO+aFvxY19LcOx3hjC3A0kGVNfBZduEt+WHyerK4sHTpwoUlpAts
# DATA Rj26klzQz2MsAMbIOi7uSaIbx8i9rJ2jeixvHWQJhhSII4K/qBX2HNI1QEcsLg4AhwNG9aPCCcIBhfOpC/oCG3qdKM5gKzYlvUYP
# DATA eyfdfu/w22lYV17UeD5oDfOssG1OjYOFOBG3Ol0oCZK6v6PyGHWcdrmOO4dDLZPRNQrN3/sjcZNqckvgY5K1jitmK8DqNHE5G0uG
# DATA QJYrlOGOXywuqP9xH1999dUbMDEJAaWT7rXbP+zsKypDYqHbb/Jw2MGQ/E5v1EfCwQA/CDl8AJ1W3chqqrI5R9rEi5c8avUm2Ude
# DATA 2UgW5kx2DL0H+2qXl+Cv/t6PG3p45Lwy/CDFkXbUHm34mxhDSXlaPPVlhg6+oIPxXxOPg75cbCSLXjKGIV5fSCOIVdTwDk46rzCX
# DATA JNTyupxo2K7h1+qW2tpT99iTUUZX1bRWSzEbIFRbZMC418ON2gt3NQJOmRyG2I00iorHvejkdEnWgol5zKngzYSpR0zc5Qm9MkTc
# DATA izEcqCfsDddPOYQIPVI+el1QcVIlminqgWBzAVczGynBQC+3G86tT5+2P+53ejCfpQukPI1No7y4edrb6EVpIkumlHGKAyhSa0dv
# DATA Y+6U8eJFYUvFFE6C07zXM0K8ldR0VjOXE3EvI9ARchKO34c+4Q5d6F9dWICIWpBRc46ZRTyKZv99Sj0zm1aP+ITak2JQRctXo+a+
# DATA Tj/guD06GXW6gJD7fvMkbx1mejVrB2A/+p5DoReTK5eKjl+BZqB2x8FBZx9yQyRQMTJZJWYdE0yit6El34/eP/WpzMcB7lfqVTga
# DATA +oaRZs9BkDrTlvryWO1/C56m//edZPXRfvckx8KQSgk20GCYPYCZTton5HWg935O4fAgieoDhFxxYumZoMsVZ2XxLEgf7aXI3AkA
# DATA pj6RGPePFAGUcP3FnsCI4L9OFvqLi4tkSlnoX1mIAN+S4Y5E+yLSs8moTOn4ftvrQhoYYS1qqTtiByw0/FkluXL58vKV4uxEwG+w
# DATA lmmpmSIr+VDN2Gh40oPVaBdkXKIZrcHSZCVsKF7OTku1gUamgrJc34Gij6NS5HVeO8hPe/slXU5NYq9fcj2l8AQzbgqD05jUI/TH
# DATA mmwc3qv+JpdLgfQ1SIXeGZ0i4BLKGwWuTzWMwWDXzCi25gbSI1QOpnPAh2zIt2sbq/g8Gw795yz9dI4xdhlM0i0wKyGc5rC0CCFG
# DATA uvj7nW5XFK8ZsC0DDUTP8WaoEzUCVoQqYgyEDkRIABw6QZ504S8rjp5EgH6s4j+w9RWVAQmeDH11FHeJX8aAS3Gogkw86E1M5SVe
# DATA tzutw15fbfX9nICsdGHVFG2uxSvL1y6Va5yDMz0ZHVSvgSc+dCVX4mOmboGOKsyrxG/R+ObqcpAysiQSRNrgAeKVED9ws3/SJcnq
# DATA QF18SVQGZoEynhyD1Td6bxxUepxGNpAjariR26jJGeFR0putHl461KHTPcWNJc6e68bZQWwRxdQx6rKtQU2wL+FtyRA6aJ26meI2
# DATA G/SAd4p2fQT/WjFK1r1Bo11JrEjc+6Brk7Qh0GAHfaCa+NlWQFnyVbCGxGryXmuQH/XlpkAtqer/Sa/hAuwS/jIVahTwKInvMfJU
# DATA GdEsod9JVhLGE9Bkcdx6X90X6cAEIAPwNemS6IYp/ToZUdFPTpS4pOrazzoDcJ/h+vb7RxkqC/XYasmmmjsInUrez7IBicqRle+2
# DATA TtV/FRvunyD0No2EANZQwQwgw5K5WvA1PVCtu9vdrZB/Jwths+IR681lO+VgwZnOMLMwaG/sVyTUb2tthi/ze5ZId1DWlcNUS5Pc
# DATA 5kmvhzJQYDz7NwOBadAwMcleofr5K8dO+IwwWoU6FuHFWff6URFiBg1Cpnj1jKKsgxWFURm6a2yF8DPI9YoPWYy2bl2vSF0ua+9f
# DATA zokEqvds39MzOUsrqzfHjycp+FM7E5E7gbkFCGc0mWKjaKe6coaaYvhgR+siFZXjlNNDVy3uiuQTvZWs4hcmnxWyBW41VN9u1Jug
# DATA cFb/jHjAH88wfVaPE0yicPKFaWpzdjLBNJ19FshorpIaaihE+P4OI3+mub0y99oDdU3HGxVcKE46+RHywaS1lwO362aHLUzxp7O6
# DATA 28osOeOBRqLVPITzw2Gq/sRbGosseS1ZzyD7Y/4QfXmQW3YxEXvNv29NOPWNXR4HSpKGMKrFXhd6sf5LiHHuGOWfRRdX2HQ4/Sfg
# DATA Qn2J9jKGN8MkbQhB+OEUZNS4Bk/vIlRGgS+V1kdeYBoaHnb7e6X0Qlr2KBZ0eSBhAW5sl/JLB47YDEMbpKcu6TfG7cNFrC1PmsiJ
# DATA +NKIvvhnk64anCGehPP6LLZpJqgUjVYDBm2yaIsRsgqObqhFGkZU30pTgFD0Fg749xPMfEQRT1786sUvtZkwmrsbaAyJAp2lXYbs
# DATA TQAOyLuLB4ulZ2Hi7Rw8i4xPQYzHTuDeaLp12DQa/Kf5M5UrKFkKR+Uhid0l/EuHqHLyhhqeKI59UIfngawS/cbZMyTTwV0KNg6j
# DATA bQrESVCudPonOfRLPFacDNQqp8GOomzP4K9ga5Y+CfQ+riOmdzO63nFaac54QL+4y+oRGSZdpR0mnfbKEuhMpHQBrrwWLa5cGuOF
# DATA AqqcvNG9kxDhVzXfQ7hUwqWjRG2KvX5BXqNg+f6EGatGrVO751N4FHZVTgZGU2GAKCI1zat384+GLQShiTyu6sQCY7oT6lWj+aGM
# DATA dki4eye9dhfwwWZ2jZS9emU66c+DSoSmtHBG/8mblqd6Ur4inGoSZ5/pzIRPKDGHOKXAhQN9CWBCXTnv+WOErIVqfoHP9DLoDB50
# DATA /v0ZK3oCTmk2+SjD5D5xgbKdDsYJTO9QJiXBh9Wugb+anFrdLUfi8cSp+peZUpI4c/Nbg+6tBo1wv5B2m/gvH0aSCE3Gjn6OAjah
# DATA HsvcUHCtRH2cktNQIulAIjShmAZX5WTQfwj3vn6eQ4ASiFb7rSGZJXrZQ1EZXRKE02WyARmt8yMUeR4e9VUL+rqpTYet3mnCuheI
# DATA OqgJjQ7V0iE8RoEQCqIvAO8i4UrBAqV6K0wE54pwgZCfcZSOaBDztjTYvRqjs+qo2cQ/2XcedBeQFiAjk0Hdt0Bg3ClqudT0o24Q
# DATA 2qvAr7vNzVt312//MPmAfmnJ3TxYv/vm3du3777nkuQoxnyN2tQ26WW685Uo4kvSackvSd+BOt+muumr23OJDx1GcK0HN8mvFR7E
# DATA BvNBt396TBGBWCeH8k24yx63hu/jxT/d1BUn/++Hv0NBRCdCtT79sNe0uKY2mE7mrmE4dHyovfGJNFXFTrMmXZVrUjYJGWU2LN0U
# DATA OcK4q0Hxf3RrFGekDwQMr7VzGUpC8MBnWkStof8dncM4uYRqWoi2lNdabcKnoA1iN5EwTVN6Qrtu81jIIl2XnHcMahJLFxG2GvuS
# DATA UTwhQQD6VeHiK8p6/s/oegarTdDEPyMXtDAUFAr/d0UBgGP6C327EaeL/k6272cLQRAAzjbBXnR19ejCTprg1wFDkt3QIAm7u7Fa
# DATA 1XHgprN8BhmzP0f8dhtwOLkxYmNmQsu7Tnog81yEM+N8XgRbSCJDv+A+g5I7qaO+RLUVD7hq9tHT6x54Lx5EsF76lhhPSFxjK4po
# DATA HWYAP8QdzH6JgIArTrZaohGD8ZRUpb7ALEYfksJHo6k9DtsF1LWnioHnSbXbClA92NX9z6rgJyAlqMb5ExxLJbH+kgiJDZ1DYGwI
# DATA DkXoNQ4heoLk9CXlltVZZZ/VwgZTokW4RMFB/8R+gznSuVLKYfLYUjT5K8Ke0PhW5XAs/xfCkIPf/p/U7c2NP0AvWFVlWCEB+4S1
# DATA QSefEln6sQyKOMN6htmhuu7A/SE+aNqtUAX62u63o5tOPUxIfawjzpMBxlihrZF5PWytE7WiVYueEd/4u5FYLouMVYlAyRkEseqg
# DATA lecP+8N2bfQIgcUE1k1Fw9JUCEmmwrNY4csc/AGAMG7cl8vcyOcnvCKa3aHdGt1Q7YBJYj0i6IGELpY32GhfdiOqgaPrhun6WqhI
# DATA 8bL2ZKCJ6/QOG2xCKztuqMiYfd0KQc+jnkHdDmTWTNjgb67dXt2CGQ6EXTtccbhErCNodEcztTtkMtbybLjHimkU1kmJA+jdU8JJ
# DATA R3/Z+/oi3um1s0dTzpwXv6oA1/l5Yl3SDdtCVO4YI0/TXZnwimkYyZMQCzT4n2MRUteMtnXHtRsO3KltLQDv7ykTMBoUvhZXGG0t
# DATA tC/M4nuWQ2wmozgcVFzQJ96VCacKGLrTE1pFW4Uj1hXBw6i9rub5McJdPnZkN0sUKMwU1Ft2F7kw7xcep/osx5pJGHMg320bIqmJ
# DATA Ps8pAH/Xl8Om965YJgonFKbjX10qgiNt5plgUDlPDXeInt3e4CQ7vFPgdYQc5DCb1uPf0/GMNP+PEeDTOgsyh9lMNDGZLgTCqjcx
# DATA QQOzEodPIEETEVqhxjyJz+503sFWXAvOzvkAtEgdzTW+1OqcsDv15SX3ZJm6h8OYLFr/6HbmBSaKOOlpgIR2Oq1SQQDBOM6x3LPQ
# DATA e3xZidJjdc601e2oCze5GKIAG51H2VXKcH8mDZZ/VnzEWRw+RO0UDi3Bj57q/DHPn4Uyo27le2GNr8+TUYsxNqsX5lmMBjrFAB9X
# DATA tozmrHn+rALaKKO7o6+ePf+MNPt0a3oa1cqFnQVBiOfj32eQRwkflqlfX+InCZ6UnBERPcy0P6ZGYCo/4ZJ/MnGoTr6JUMz9vbhw
# DATA POUbzBPVt08xqQYMHDv0GV8h8CZiZ4kvhNqGr8R+rd2Mau+UmKDBB178vGZTuCIfALWhkVNEHieWYTSviEsvSJhWeiFVDmJT8q5F
# DATA h+0hOose4t+1Fc52vIFvjCZI7dhGs6lk8GazLL6EK3pTJ0gupf1BNtRhRvtHfdCLNBjIEMCIURYGZWGfwdlHw1YvhwSAiKUHMk6V
# DATA xW38Rv5NSHuQpxcCCXQyztYQxWp0GalywHpVQkwRGDAiKMHfhwQHTMwtxbQX+VGVthJn9ewcnIoHDssCPL3gIYORB8+589S1k8Gh
# DATA zgYHGJydUVWkEoVEIaBVF480mHFVpCwEY5XwmsAGWXXqPdauWNLHYsiuPKYmmm5oqModkJNV8Jo7H3+px0FvnckYAZSfWUsLimPX
# DATA XWfjIxWjdoaIUlm1quN1rxcV0AGVhQW0C9LEZuydUZKzJ4sXt2EPoomtGJy24s4eI1Bh4Xta+OL3TFiUrWZiXwCMPZ9Q05AdnCAI
# DATA cniYN0CpPnFsitImdYzCU+1qFJYUe7rqRGsXlLf7hq1ljXRKT5EK1WdVxF9RH7bQqtZIkaiblLlxYpOI19r/+nUAeGT1mFBlLNkV
# DATA 5ffaFUO0ZWZshTNRmAow1dj1id8xaGXwKaUpm9QscUp3SQrb8qvHrD+TmUKEVc+4+M6ntNtm66Ur0QZdXlyYuvXxULOrrBPXpTot
# DATA q7O+9Hb62p5rpiGxSvFbnee6LD3luSz+A6VFjl74VTNygIVbJAZf4PSAHxFSpxdLbFA+vGyj4jMdGsxWKXwIsIEQK4dJRMueSkh8
# DATA ZoxYPrguNrUGXQZU3TAJrQZK8sOdYylBGY+EWZJFbIl2S/hzlL1MjZRcnhN2SwGW7i6lFAFlTI7rVCBgyuEQejEayrVO+in4bGkg
# DATA 3PgiCiHOLiI4R5MzM74p+Ys5uUo+6uvuPGgjo19XJQnWfIYeC1GjHpJWUKOPCB8HmfG75q+3MGVBRmBQkQGew2xIXIj3ZUGnFCtY
# DATA uX3bRehyzIg6mxZeSAl/Q74eWMAxdIJ3MkbriYPtAlNG/bXJGrn/0bwYTky/0wkDu2xHEQWpp0xgbYDgwlRgMLpJo2wThhrjIsw2
# DATA m+DgEMswNiM3cBfRmTvek6eQzx0iL7gU7a5eP51MnPLeYaeXHjThZUbxEDWLVDGxPv9ycC5iZxCNIvgtls6aStqg7/lBmZmt18UZ
# DATA p1YU0d6f0IHJw4xdeMSZEgnKOCfTmHh1EtdvLiYjOXQxd9jnWUT3riiSLOaqsVGTXzT5SM5jh2DINfEHf2JPx+mpZGxNerkNu+AH
# DATA ROul8iyDit3NBY0WQnpPHKKlw/MdPN4VXO4VeNHkF86JPGFRi+Z4cif8W7+06dB1wenGefhA5Hru8xjt+VG0gSVLILEL0Ty4utko
# DATA D59wc8ajldERSWtd8axFls/Yz2zMjfspk2KYhsx2BG+z5QgD43tnM0ZAElDaYRmB0/qkoVWSaSPw3HDJFbnTG5yMHPQa9PupW5Mn
# DATA XP7IBbbueBviy7hMSXFplrlO4L4YiSGyOhWR2SQ1kZM7GUvNREEzbdmJzfHunY1c/SvHtG1aqNQK9y11wMl7gUVFN3AxKmILcr+m
# DATA WNUBQXDKRLkaTLEW+LxJz8/FUozCtj6JenSp0jRpQWSaibJRnVIAiHvKWAMt6eQecukml57U05CH4A/+ckq3rFbbl8IqkGcB0ZB0
# DATA kRhpnncGOa2Y32dzXONPfVhryg8yvkzkDdFbcuT2fj2eiAUuQGrg1+PubyD7GxueaFYiWu/OdlkuPBaNbWEiidDOVcVKk3amkXsp
# DATA lxD9IHD3cG5BETWFXkLFVd2/ZRiLTpjfJ96k08XyeTqg7Rkz9kHnYv2muzF1rZy2pi6ZYZ4z6AymNo1CPzRZ7OhMUZgmNYmRV0Sq
# DATA n4l94MRSdg2mCWydY8xAm59aPAD1d418uHpwfygtiAwOTeSvzabYYxzRWw7qNBmNXEzQecqXNsHBQATVzAKNDMHQn6MjJaazDWPl
# DATA TEdq7H6AP0qDis645xCb+cx2lUJTXWSf6+K9CUG7fNlnh6qM4+uHP5rEF0shO3CzQBlW7KaPIqq3qnwL2z+FRMgGGp4umi3j+9JM
# DATA x61JHyePkonsjXKdifE4BYtYQCR5cOSFbMbNI18hWFTTaK8v30UmN7oQ8qGTfcvX/36dE8qtYhWA1jYgBJkStE2pZoZT+PrLnYHa
# DATA Xu4IzEFan0D4mFks0UpEY/+qYn6UNFBjP/+99ZlGR0nOYg2Okc8m52EIQMUNf5h2U0nrgdaTU3fGmEdQVub6dD6IJvnUXwFp1Snb
# DATA uOX+YSnagiajYhO8d0vyVTmmsa0nnYGaYbAG1DoDI9UaDQ+QWmd/JJELiiYJ0VDn/OCTQM2tq94tADvGDyuY9iXM9VIUhuILF2p/
# DATA PCBt9wO4ZVNoyiQka6pBhLAUX+XQ6+McNigv76G2hdU9hU9KJsO64KHjcMnYdi7ReeqxHIZcbiWQoEUl06XhuTnVbhNJqdnE4Teb
# DATA QKTNJk+AEztGPkFzArIpBAUC7CbE9KlPEjr0Hv/XF79Um/cTir8ocDCbGo2AzSn+gomRQZwhwAMBuYQARlun+Sg7XqWk5HIQpXeB
# DATA KrD3leSd7JT/Aqhy/vPuFv+BaDF/s3V3/RbCQeHTsoyLXEPVDKZ+6vT2uydtjcaH+ZzyetJD9AccfzLMfkzgNxQPhqGhJ91uAg3U
# DATA vuXpqyXP/81Gjb74mKBjGMrDBK9UXDSZX1HUreDLFMfiJj178StAPTvXavzV/5L/U5tsrwsHp9pFtcHpt9IG4DZcuXQJ/1X/8/9d
# DATA uLK8bP7G54uLC4uX/ipZ+EtMwAmEeKjm/+p/z/+9+uqrsI8UcyTjsg4+xWBPnTuOdG4dgLUcZt2slQMQF8U4L9aWaq8t1ebmto/A
# DATA i1wWxDSQyehIHRMIeMghSghT2zmElBlHWXeAkVBHwD0ASlO97Z8cHs1hIXOfSLZvblQJ5/cgawGOFhp2IUrb9hGUpvD0qPUgU73L
# DATA ILYB7KjtmupbNsQA8LY6UffgJAUsuF7fGMf35RmBoMKPsv0TwqYAbDcQKAlncw6wnqedSAH7SLenjedInUmy0+lfiOE4EWL7P87/
# DATA A/b/1SuXF/39v7Sw/J/7/y/xv/Qkz1i+Tq/PzamNkI+Ss2Rj2MmPWze7Hbxv069kjCE1uK1L6fcH+HB+H8uk5ev87Y8fjmQxkEYe
# DATA ZntkYSibFrZu3t3A5F13MVEkYg3/XVbaocRbOe6cukas9z2S8zrAEirZlMMCdL6uICqD3+d19pYuLgCSvqpmF3p4cNIj8JhhdpLD
# DATA 6Vga9h+WOc2YTmvdf5j89V/DPzXOwuZE68uGMO4iVaWtGgc+yx4N1AStjPDTHohUH3yQOC9ex0yzt0BiL5eD7/N9dSfIa4qvHkL4
# DATA u6qE5lQ/+eADRySf6ZuLyaIeFRdlATF3Y6fqlOPF6RTXBKLjaQm/ThqvR6vC32U10+O5uRbgOyRmxtUt8UEHriIloq4KJkvRqUb1
# DATA GoDS7pX5H+0sVF9rVQ92z66Nq+bvS+PqJfNjWb249lprb9d5ov9eXBp/d742yvIRJmSH+YeMImLiIJNH/0AnOn2FlFyQWiSFwvRY
# DATA z933kuWlMiDcKsqAdWP40bUe3tv1OUUHjPqurTZNpwVZz65rvEdFN5xDeyIlyfLatxIuVeDCltC01VqDDuacz2uAynav1/nJibr2
# DATA JQ/hHKyr7Y3jHSdjbnx+PtnM8hPVNibyS1p4YFfxSqZR4SraVQSaQxo91ZnEIDcCDKcPaJrD7EF/n8/Rg2TYOTwa5TWzbKbDisxe
# DATA MftLPy3rFcbJ96eS3dIS5CXJ/lGrd5i1r2tjJUoDJieRE/JP3uI0VEqC01XLCbU37AyqBS2YQkT7hukDXlQXPSTahDWrJHrX1u2m
# DATA hf/Uev2HJYhbWVxILiTLVy6r/167cgnPOfD0xK1RT3ZqtRptIA4Zc9ZmG0SofredHA5bajh0PdvvD9XIB33I7QF5dgEH8ESJTWod
# DATA EPna4AXW1NqCSKFr61OC4BZQT2vfwAYiNrKzyCCDdZBOR7TUOEYWg2ILqv+eiXmIeaSVKJh9rbMg2j2DOR9XcCXOePbE5I3HzjIz
# DATA s1ZHUg0kztIZL5k684awbHVkvIC604WwuZWNNRFB1WmpxbwDVoeDbr8/RAZKpNBewXREgGGNSaAXcTHNh6o7BRz+jeQMMBdboMWu
# DATA A0h5Nk4UQamCQUv647ChcTkZV4R7JzChitrTre5hX23Yo2M1kre3wK8CaWgCk32zP1wjthRltxWbs11y3uCh3lD73VbnOL8u4bdV
# DATA t+gpoNiqVSDbva3CNnVmug/bgQewqwagtsI+QKCpquYvJCtJu3NwQOi+qFdHFFfFct5XFG/ZKiQjyhUbg72oSbiWXJhPxo7lh/um
# DATA SJf+QgMzneVAC/CCjwB+j3yzIc8BcQLi/vomTyXRqLNfLP+fuHMk69ecH+qqy9GYHSPnxRF8yiaVVHA4i3rMGW1rG4c7ccr5jtRK
# DATA HUDxsUYpRDFjWPtELY1i0hqOujU8fED5lxuAXq/nh+aFagcoQLVvlBhy5hJlZCb7JFkClvwJpD8okcz7Ro2qepc0pG/USNx9o5YP
# DATA unCvq6WAwJy88QYktHq9kVyFPR6ohpUUOxhBDmOgx5KRjRE7qjUYzKPqnYaYz2vBmj+qDg7Tco16s3FYLp1F/R3VIHoEnreFhFk3
# DATA 86QOwtqtle2VGytbq817m7cr6ob/qJ4sVabUs02A1Hc6XSUb1xXraS4AjHCn3c28V8v0KqhvDFwp3z/Kjls0ctV6qahb5VqeAdLt
# DATA RmvYUiRF4fr4rVpaNb0pxonuA09zWwIOCgmuFLUraSACo4FNy/tMiddakqrmMS4omS+B3GLHGyXwdIDNdP6OBB0QkUAUIfaWyHGl
# DATA 4YYol/jZJEYs58ka47fu3di6ubm2sb12d725ffed1fXmvXtrt9ziKxsbbLCvBID/E6rbXL2nuoyVWkVoDSSKEklcah95mQpIZ09v
# DATA OTRXfIpTqjcgbjPFXWsZTWURpO/zz+AR4gOCLd1gLPxCoKqgYe1zzFRsUQsCBIa49vi3z3+Htrk49qCPl1PDeCI9d486o5to7E4W
# DATA 1bEkRso4dDxWZsTfRUcy3E4luu3QDoejvU8pts4sCVRi1FDR9+Tx9bm/gP6naXf/N6oKnqz/Wbx85ZKv/11euvqf+p+/lP53A+Uo
# DATA u/ba2xWznICaVe1bvFEE6hPnlpW11Q0MU+GxNQg45ZVL+hcogvTf/XwOccjBp6fb2dPmI/Am0EWGmf4LzIDmb5OOQj8ZZccDuN9R
# DATA hSdDdSTtUTifrhVcN+CwnjNVk3c+gwiQaxV6taLnMWlwD9qzgFtqLEv7e/3G7bs33ynb7H6AYdmm1H5tiCznlE6U30/YHwkNHBEv
# DATA AQuc3nuJggTiHRSqbTXXtjZX3ypJPGkHYFpn0YT0MLF8KdaoWErX1t9dub12i08VQGFwEZY8oFUC1tINgVjMgO5nCzhV6gDP1NNS
# DATA eRxFvF64erU8rUe2J807cFrdWG1ubK69u7K96sCy49HEE2rT4Vz20+EYx7k5x6GbVh7/62RjwidMItHCTpoT4TqAb9FlAZeiaz4I
# DATA F2LKIuh8DkSutcBNkDutyZj8bghAVt/9ja9LYXdtSd1jCpfjXAM8Av0bBrG0cOkahqTev4+pfWRZCA7sD9ul/TLow5bhEf9UUvri
# DATA 0lWKipNflWeZDopaRWkKS7OHiEz8hIFr3BG4EWC8bOggoSeTkIF8eCK8UfroYjITC89m6ezCBXZS0NGUGNkQRsyOg51rq9N5wc+f
# DATA iiU+W4rzrNzWc7W+8u7K2u2VG8421oG7FAwqW12nN1vZCBQ4Mru7fmWiff3aDEg9sgcJRmiag6HDM2YRpfSon6NCfm/YaWOIetoD
# DATA t8Gyg0CPbZBC1O8tpYpP1abu0q6GJND+TOv+xTK4pDsr1b9tVf8OENXtn81adVfxL0Wo45QUe+eadI6oLph8S55JCkHG9XlEHTf4
# DATA hwZwkkkUna30D+nYZiaDFwjk/Y27m+ieS+ACxulSehiJ9s2fkMED+yH3MQV+Yhw091G/wrrUeaqq0KeqZQ16G6o3Nby5yfVWlSFI
# DATA DYZdGzYDRYEUcA7UM/itdXP6t8ap1L9/cpJRVh74cTBsHaLwYQqrI9e0ivjM1Bq+hMNf8YaFl2E57sBeaeixmAhjprZJdb+9vb2x
# DATA xTVvrv6Xe2ubq7dS59QxOtuhJeuKrlpx+o3NuzdWgY0pMYv0Fjp9sbpMrJyMjvpDvpPWk/SGulArNoPAZP71772Vd1ebKxtrdNKo
# DATA 6wU6QkdLmZlgMMz3AAzTUDApprgXO+kPqur28rA1bGdt+AvdvVK1n2oL6v8tptfjJTeGfcWtdxMzq3Bb8rSWQOoooEF7NPbWHq4o
# DATA 3tBX4O+bBJzVhSjqisk6mJMGFULx6YKG39Xwv1DuGmhV1Y1cq4ZYtYbK9Twz+rWDDBjHlDli8GLFPnmgAKVOnsr1FK++iihBF93q
# DATA 1qkb9IO0cGjY0g3X+u9rexLTD8V+tPahA6RXALUrCHmNBYDeOOm9nzd2duEFsGHqdomGg2/RIqOr3+u3T9VkwucXG/iaTVnXOwcl
# DATA ePr6pQuYXQX+Uz5zJu16pF+6YtWzMfWlNoB0mDdOQGFbA/m8hM/VZXhsphndyhroTUY5l7m4eruv5GCqqFwb9UmvhdKcEubsdJGP
# DATA 5wcfaE0t/n6l0Uj7aFlGSx0Vqpkl9UqbF+Kz6NSLIc6ZPetWoV6MNS59crbfVXtQEx/SI4x9PFdC4i6VG68bYtbG7gYtG3L2+dag
# DATA M0/G8HljDC9fVwMvcf/1U+3CCSNg1XQ5MgCDgXJdN8sG8LDVIlO5+FZVnzdWhsPWaa2T478caZ+X39CGdf63xv+qb1XnX3E/gnrK
# DATA se7KJtVnUG5nYfcN0ojP3OP59CKGIGb3Ntdu6iACXRlr1xXDKZfKRmWl1sXXVwldEvkyCtgSg5T9GIDxjHYKSn1JLosEff4pPY1q
# DATA pvBwqCSqDILtQbYPyjFEujDbAGKCS/RRTGXk6b7UlPlqq8bideAy6L+EVwZVYC8rcQSDvQfwBYYPHcVXKMS4oh2sWCQqvkGFlwxu
# DATA Q94w8NGkw3Jj5a3V5tod+G8oT+HVWl/9a9sZXOxbw9NbOiSkROAZkPpUZ+lDisAhV+kKftDvKgbtoPXr0CR6VeaQZ60Sg2gq22EW
# DATA zEgFimDqaeQ8aEjxiXSkkfMXSzlq1JjIXuKVcJIavYzgHiTbQFtYpPLiuwhd/30pm/8Uoj8V5LptXspYIh8kLptdcxeho7J9TE4M
# DATA kWxVBjVHd+reg7KhzB2oclfD2EFx+C+KSh7+SeBxT5AN/RxVCM5I1IVGLeywZAZibyvl2TrPyOnVKoFCVqsDdfvAq07GoJES3I16
# DATA UQxmUTQH+FwtKBJYaieBt1x0LrRPuXEZl87lIuPrlvnTdyIv2rJA9Ss3b65ubTXfVDsWxFvKOIj3dGI7oCe0iCyY96OI+XCLimVt
# DATA 0lmrvlf8OGuDjv0B3Oj1nJD28XqSH7WG5P2RUPITxYFORUZX4H7CYZ3SP8ENYs7mfYxDJXE+NRcaiZ3ilfAd2/xpXYwsjex7VQAH
# DATA PJ7TeUygLtspYDmYwyov6cgp6oZEBsZvedwEz6RxHaIV9UdHAPVeUI+bzYnv8pUEP7IJY+TE1KAmQNrXl/xXTIpQPVcO2AT2goHf
# DATA CJrjLMWlUpNxNh7rE4QGVPdScu6kEnYFLgxnFy5oVqzj7eVdmbMw6jQ15lPQNFy4QMs3jlyWxdRZ1DZZMUFRnKXoMKW6rgk6hbGr
# DATA 3/DPuJIEZFNhmrFHpX9vVM9kr/l9k9KhTd+C6rzUeog7ELp7b33r3gaoB8xdM9QEQQ4gCYJlAN4qDrobxsXFlD0VCzKtP5VkEQZW
# DATA UaIfOBpIeqaRglYHNYV6+yMUqz3AAa3U0fJAh6SeyRxKokX9cgfCvXTL9rCi504HXml4/GfG6b55d/3N22s3tyPTLGcXI9rO1Nk2
# DATA AkVHV9EKZYCm5uv6GzHvrdGoBdwL4BZCykAE71Sn0nNz74p50JXwFLgj0y/Dfo4nBayJjoEDbQlqxoue+jYv7VywbcIkl8vBbjZD
# DATA wLAwLu04jCCUC/GHXSeDFzL8Er6paB9AjhCsz7ncyxAnJWNiyhS8Ra0FJGdEe1Vt78olthzgdzspRTpAmi7PokDY9OR9iEoz/oB4
# DATA wm6BrEh9gjYr+gPc27tBdZwN9C/m/8/Rn994GNBk++/S0qWrlzz779Kl//T//4vZf7dOe/vq7t0DYyEEp5Cnjet53B92DjuYqLUl
# DATA M6aQC56FdUf5CgU+zFPzaCSsu/yEM25qY+zBfm/U1T8ALlB9oX+aqOBv1IYMF/6XsRa/s/pDUFBu3bvR3Lh3QzH65q27d1bW1tO5
# DATA la2ttbfW76yub2PkAwoikPZkmP6o9Ead3D12kvuj3YvlN4LP8cWFRu3CdyFhfFa7Axa9/W4rz5NbuB3pqLGnjgG8V/NCDLHXHx6D
# DATA MxJzrEJbHx++8hpOrJGtfPR18npyeXGJ/CrZKQvSz97P79//P974zv1HCwvV+48WD+4/unqwmzILC6x4suspDbTJqnU+Hj0zAvNo
# DATA YY+gJ6ExQsRHFyrlZ7QlMCgImQvgilJJLl1ajponzj9A+JJGaCqpkR6qlHbavVZqzpNyrQtpSNk07dzOncB4/rME1TnRwZY4BM4K
# DATA 0Ed4bM/ae1AJAE1gW2D1vYzW3LRmErvj+NQj+FcNrE1ZssAlEjLeYaZf+xca/LwsV6Ci7nZLXp5jtWMWHmlv2IsfwF9q36QAaTQc
# DATA lfkqMTQ9EI6YQe2IsxG2sMN2P9US/4lWvyuLY/2m/MZM7b0E1XOuSm2r2qlXF3c1GVPiMj2RaLlC6tfv9Lp0tasKLMulBVqWWqov
# DATA V/CbroA2B5Yz/nke+Er1b9Vga82/r+5eVI/m/WflCzTtkJ7s/CNlAQ6phIwiwuFGu9QMKGjEkdtkOk9sXHKzSLpOvlta5BFgBPBk
# DATA lj6r29HKm3Bl3347jWy/b8INiPcoALCs90dvAlKLt1XBu4Znoh5zYDVODmYs36p/Uen8DkYLS5eSC/SPeNsDKCVYjcUwQa8tdX7f
# DATA oaWl6MVstvXFTIKtUcv3GRJDuJgsluVmg+Jld5gvR1u8nlCf2gzf9yQi2Bxd0B+SZ4q7HbSvSs0EPANjfT+d4q323qYmypubqyvb
# DATA 0yi2ou8cRfTVulhAXxG3tEJiM6T09VYxUGOjLAkxNPvvc5sVfgZja67+QA1X/F6/EahEb8C3nd7h2l1vixb0797GrZXt1eaNe1s/
# DATA dDSd+pPTTtZtM9/j1ZZrq72SELIDXJLyEhLjRMckQ5qE6WITemF+FwIKJ10JQqjbQgW5zoqnff3udvPOyvrKW0Z1ZPSFE5JZS3Zt
# DATA 06UHPNu+chi3bcEpE4dmOw/FgPyFubBjsI60GogPJcq40Flzkj1KBRNUzFhBWupYTL7XQNaBL8vwa/FKkXji1cUCOhzeEcGFDmh0
# DATA VFqsLC5dM45KrucVNhtrUDTG4y3qOr/Gzl97SXrRCcjP7LLqPHZ1EgTCF0IsQFi78ZwFhsO6xjaTOXaRMg5iZ6X4i2xTVk9l/EPA
# DATA iCMTGItBnhcbFQ+FwKQiLSn3ep0YAM/kObx5987G3S1PbRvhLOHtLprLvRxV952zeSsOwXLuwGSBvg6PMXeK7Ev6PeebEgxxRjMx
# DATA RC0vOCIkcd9miScOlYsZFL30jU5GdnQLiqWwx32wsxtryvGa5XqiGGF+Szvmh1svTAqhgKD7XZDDXNYVoecSfrtDwNq7nroX32l1
# DATA N14j8Elo5aE11U3s6h2hHziCEOVeV5LQ8tLL8QMtAFnoRuaePJlMRdpSqPqAt33abEatgTu3k3vAY76wjFwT5x9101ZJg4GRaNxF
# DATA zxlPqVt2DjCupLgVDTHHBXfUfQ68SviW2FDcbLG8s7jrOJ9rDLmdOlz+wFPxVVXu1fRVQUc/OemjaEAFF2QmlrZ+jAMpYcmKFllJ
# DATA u97pmk+hvBJo66YL7CoN0YoLrF5JJVuBd99L8FpZwpr0NRJ+yITY6XfS8syMxb0cypmjbi7WVbu7EYWFLgbKKJxUdQ6iLu07WvmE
# DATA EY34rrFYxskXcy2dtJisdHKN0jQytJ4u2ANLjrRnwqNr113fkEa1IbTCNFxokhC5zPXlSHtUBTs47B9dWHTuV6d1PspsfTWyRwaI
# DATA t5MZNt0pIae4cKqPGWAn8HPhV+KaZsOWDhLQvqICGtqsR90k9DxQmR31xa71VJJJb5zzXX/lK1HnznmsMynqxkibiHoNlpwPM9QH
# DATA so67xtkOynNxuuAUyg55iNaoOg2OYHIqaAUjIE7spaCrxXxaXptIHjWqgviB5qgazpH4wl563Mlz9PdxNtNZioNVIhwPWl1UKHRR
# DATA PeKeHWWPdAM6GSeV77THeh9auwOHrRCmRwNDABhJC25CfNfAi5O9Ldg7anhpdu4qBbubwwrMlczmFSFks8Y5GIXknzSIcO+LCaQW
# DATA Ap2LFOawEmGuzrMRP8Rrkl4CdJIaIOTJpl6DcUzbQt/uhKV3oTrq0I5dx93ZJca3V9bfWo0xdrujdOPUZ8p65T0Lqc8Rd4/7bcCV
# DATA a1v5/6XZ6SRW6qXqY3F2rsgxZgJzfEmpVnRWfx0lpKmS7rmYtC8KT+LFMX6s744FInVx14tPyuKx1Ab9QUk174cKBVJz1NsvrA8P
# DATA Ci2HFJY3md58BySqJPiOfQrwwtg+OR7kxuUt6+XgTNTK9zsdUnxXMO96b9RY0hmuZ3Bb5AaQmcP876Vp4KAQO0hxD7zi3iRIejGC
# DATA nhCV2f4HjRUsYyH1cQdlZSd7GJSDtQVrT7veKw5kpqakYQx//PXcJEoyfOSlBsT9hn9MGA645PLSqH+CTsVWDdy4oApzIr9CN+aw
# DATA Uc3bzN3Z+c6/8evSsxwsJkOWVijSg3ye9YPqDhlLmVGFgYGZHJ3jL5XKcJo7HaF6XM0dPft6Kl2ul7IbgIq4sdC/CrAjlNEhJ41Q
# DATA gWONzVN13Op1DkAK4QxW1sNwx+leNCmVTjiED23eeU55hSkSpR4kem55frw20ZUniYmKylJkmqmRcSCwY28r5pjLeifHCHZa0kRj
# DATA p27Xy7A1QhdoofgIteu2gZI9dMvxhiIiqyCfmAkQVxboSIw7vkHPI4uIRgvms6CNOGWV4jTBwN5ce6BRmJtcu53M6V/yUumsaq7e
# DATA UhsxWnm2in9CHGCwhpo6huCGniu5mes871IRKpPgXPUiWcGb+ckHPdpyT3qk6p87/8Eem9uZF8caVwVTNdeAC8594X8NRHDH/++4
# DATA c8j4ft+oC+Bk/7/lxeWrl338l8Wly//p//eX+N93Xvn/2nv35kau6140f/NTtEbWaWAGAB/zkAwZkTkkNGI8QzIkR7ICIigQaJKw
# DATA QABBAzNDj3jLkpIbp+yy66TuH7dOVZLKvafO32NZskaSJX8F8hudvR772bsbDQ5HcXI0iUWgsXs/11577fX4rcVpPF486A0WIWhi
# DATA dDo5Hg5uQpTY1mhSFmyCc7VC6Gh7oOEyE7ikFnQkYHE6XoHsTtceH6G/3YLyChydkjceaDJg50pPPPmdAnl/DrfBF3YDTMDHQMYC
# DATA iSQDXn6z/QJNL8KFSyem8kLRdCOaUnGi6Rh/4nT99oFge0kkhDUGQNaqtPtY0or5Mq22VJGyGlcoYEneCmWalgp4ZYuFbIlXCWhB
# DATA ApbBr7mrMV7Vd+EZr8pQCf1qwpZs6qA5vt8YYg2C/i0wkuP2GPFIVhQeCT4xIUnEAzgTdToyeaWVQ7ZvuOn2AIXeYGbAsZLf8HBc
# DATA 2+5sPApuu5jeuDQ45VxkupGS1YnhNNhuUbKnXtmE2QAkvtFkShM2Pc+YFWn36RjKtJqhVuMu1VQSLx5sjf+WfDF3yjhfY3UcBlM9
# DATA FDuzBrvQvMEUJU6ODKdp93tCTIr1RnODzmKOqMTAy0uDpdBjFUsrwyleaDtLLSwmGEJdtfQfpWRDMtpB33WuF+RoGDGEBi+NnRAL
# DATA 5ZRY39wFkBWjSBIPJwuLpTR7ZO+wUyxnFdRQsnPwB3qrqW7/UrVMKdfIad1yirZuNVfhgpwKevLUAT05+25BT3I4EtKzgu56yXZW
# DATA ZqIqaVdpMAneunXTGXBN+13jVL2xVEy3nqiMRSncgtaP8tlNhpSBuID/NUgKFGaPxAwAo7Z3a4nDuLNxc0re37EV6jmHO9RsQrK3
# DATA iC/gE4lSsU4ZNJFiqdbGIY64qAVPrfZE5zA6jfY1B7vJMFsOPhAtvr2ztbnXqm+uy2ds4n2E/YT07WdujwbcZKJPykYGIl3LiBJE
# DATA +8Pl2eCCE3QYRzzfl+CogDYvJDMMyi9Y/aRmXg3WkWVITLSYfb/anfEwjgPMUKCCvVUI22SIgOcd9K3EHI1c2c8Ahh9+kq9wrC1h
# DATA EIjnFARzEIHgS76cXcJHb58c9I6mw2nMcbkcRRuzJzO8JTWU5mRAgDz+gOWNZzWmRwp491+OGZK/YMTiF4x65l6ztH/YP6SmBjkx
# DATA uAcrxxnLQ5VsJrpTnnXzWVlU4LHe8JKW1exmbKxDPyqB7XqtRsE81B0Jcx9/TGhC/a13mVguhXylGgHWBaBZj9Kxu7ysW21Ma4zs
# DATA WSrh1OMEp4wNVlkjmzTh/bcgDYDldy92y7Q/0UrAOCJgRdFNbaTW6HVkRuNWzER6gAuaQ7DZwEyDltT5YwTTVlUNHw/Q4IdVVsZc
# DATA qEouNUtNyvd43BlXesPF/nACftSLOlw4AQdjObkYk0CkDG3NWNlxJASQHt+j7E4tUqfKy8rzp2qPBTVp6nUlIiQ7aYU8J38+m019
# DATA UHn+8xPdxvQXV8+sl3gm3U+iE3BQ891hnQjyQgJ8QOIRyHujeqAC5ymQHNpIGoflL7CQ0AJPLxCw62YIqtNuFw9FZ5cB8Uu1KtRm
# DATA eTywNwaVwmjmWl/wn24bG67KEWV0v6i8wAkqBIKNhdgN+S5RGqkZuBviq7snxaNC47rxUpMMYTWKHe+0R5BFrDWcTkZT+XBCuFO1
# DATA 5TeWFNPkcdKwQBGqJ8hIMcox/iT+WncKaNqwtQENyxxMQTjCWyRjZMLHKcq/DIQST4b0FeFQJBgKQrycgd2FoVMMb1NKPIO+X9hr
# DATA ytKI8U4GEE/Ujgm4v2AnPAohv9u0cxwYNwZIDHnxi/NPAScpOP/24uOLjzCbJCSf/PTiE8gNGZx/KjNLhg7UPLjQfzAQrCI47Ldx
# DATA xIzg9BFm9GWpg1+W0E8IzPQZNvuH8+cA30StOAkpk21BphBwvxkC7MmgF3WxQQMeKjj/Qrz/J0xz+U8AYp6sY609YIhRADGSMg53
# DATA tNuOTtA8FvIDhLMy8ac+99XJPKLNrk6Gqgff/wpTIP8CE3B+DGhXYmb8eT/FD56JLjorq6gR7bJAjJShkOifDBlEAYIs6Sd1He4N
# DATA JBHJR0BoDMdlgm/JCXie1tXfBCbpnD8L3Vyh8kKRzDZbOAzP/wdlghbT8dn5M9la4anacmdFJpcvEOELOvZLzBj9DIDxS9Srz4Kn
# DATA ie17VoWHMP6zSmCmo5aZ6T8Vfz7FlwEZDBKfXnxsO+PqzSWYheZS6CQCDKdAGD2oYjFdsxKxIElIGcdZyxcUAobepAYP69Pl2oPO
# DATA sX1j5NmG1S3A9D7D7LGQYfv3s9HRUgjdUqE1XH+ZkdUlGfdsc0fSg2HQGs6FHUBSbJqzoIpKHZoMbYQfCkXLVJdQr9nD/3+t9Ldf
# DATA Kg70QhPB1KEgrUqBHA6jWdG+L7MKx6v3dE5Fh5UYlWiiIQW61sOK4w6ydeN0INCTnA6CuByjK2sjLB/ym/BbsdmUWCFsvaA4pRZZ
# DATA AxkaC5WF/IgMvC3yQlTZsDnXqe98Fo31o2hUI2Ru+KhRrMxNog0PviwLEEmnvy2kAlXr3vNGIlmLw5TMyh9IC56OV0qGaMEOS2xW
# DATA lJ64rFoxXVI9qloSn0vjmcFTmDqllmQuxYW0IBtbWiKCYQi08DqRpBQ+yuXBsIyqgRGmK1DPACIM+RDmc6XHh+CaiGcWe4jACoPY
# DATA 5RorHDFuwfHNs1yzndAbvOuk7tl/Fjv1d7w56ZC0d6snoUkegWXBxMRHLqrJvFihXAdwmtpo+LMg5i2vWLDYVbqC4uEDe7UVXZW5
# DATA B0CNPzatog3OON+UVyrrV3T1Cw+mvT4IP9rdT789JxyYrcFzAcFmQ7TphklLLdt0Ku5bSnuouTesqGudVGGXIduYqN9zCzxbsNy3
# DATA cCENHlVMem4hvCXopqXZFDMPSstpZTrp4JIfwpNC+Nr7r5281t177Z3XHry2+zfk2+b1+mpU32BF0xyuWYj4EEiPMHDIoihU3Gs0
# DATA j+xSQbNHAoYRxOqdk1JgQetX5SaEqGQzmLMaKFI7W0h6hGDnSqoHxYUsRzLqN5G+dCbL96Y0V9jv0jfmd1JrY82UemrMlt2GkTzP
# DATA 3HyP23FrTPCcokKtApO4nkauBHUxb2GogsNk6RZXLrfpglYu/920h+lz1XxLZukGNZn1asanO+Bh7BZipr45mjUZzNnUqNjjtRBG
# DATA U2FLOSCDrRODRwQipn3KjSQSuv/Kjb1bMlIeGLiwUshN7FI295v4lqw1aFUd52WzMybkbBIr0+yOg5aZ4heZQjC2G5WuNs164sGH
# DATA 9ZlAHIdVWauriPEy8Ia3xqYZS9AV0z3qtzuCiQFgUviDHzjefrnGntI1M/+VCY7smXPSpSpsZF5XQ0FTTVf1aEGD7DS08tWZbq3G
# DATA XDl8RVXiwTBJbLUZknxClZUip3uUeFoM10lCmzPlNslf5NQk5gFG0Ju0uNOSgxtLS1OUlNyLvpU14QOdeUPDhij1yCumlmyhHLtR
# DATA TFzyVEWvBruT4WiEKGlHEok2pkeVYDWQzAsTafVi0WfOLouWJXEXDxC0VrpTiRl8gibg9buVxNpSp5XGDeXebiQ5ufgiZSgPDPF1
# DATA QRnlLgUQm0wV9awNeh09buAClzwEzO1uvJ70O22hrgaCfgp3lor+gG3PqaSGdslzyWriSo8i98ijGXuaDL86jtp9jN7OPqXewWLm
# DATA Eygyjf3uzPlOPDIkcgdAXUt8K6Qnp649Ia3+NPMNOmyTyQfw4tKPjcSBoQVsrAO56mynXr48/YvSrMI1iHWrCK4PSo5vQLlH2q9v
# DATA +Y71Bar2cuWTnKEyCf22ygOxdT/wLZNc+5rYmwM56xiQl7l+cuVJxd4V9zZSlgs+1E1bNGeS/n3mdVLnJrj4JegaA1Mzev7VxSfB
# DATA +e/hzomPOBeBdwZQAVJYyYO27lFdfYxa46/PvwVtJSiO/wgq429RXf4ZD+C3c61MimYiB/v2n8GtfvsUMniQcubqdSrMOa5fl3cL
# DATA fUS/zYErviGd2UJNUnQwtV742fLLSYkTkFUwFK06dumQzX+kalReO2jHuW78B55Y5O1PikK4WhYU5NY4xsxB0lm5sjo+mgI728Zf
# DATA CtLIKcZea7XEsdFqFY03wcTYavMrhVBp+QnmH9QhNSCTuDPkRACxEFekxQz1lVKOIK1n1O+SlpPCtkh8YrMsfCOrH9nYWPNFWDdo
# DATA jpN2dmSxoQpwKsMVBb7KnDBoeUaxCe1zmIBlOu6bGj/v8MqoOMBeZkxCuYxhMxD9dzqKaiphGBoUa/Id/ANvxfpWCd8qhnFScFI1
# DATA d2kyM72D01Iy3SMsDoCFyOlLnOaOdIc/GtZv228CKVpeo/x95DU15HBaepcP4au0XJYshc9xzlSAJBsLlsD/1vj5R+iay9W73iOJ
# DATA g9M10NFB+Q0aqATbn4vPepXVNCDNbVTBVE01SEbU+4YeVjNraTn5osnTrNNGqv3NwlQ1XejwM9/k8LNlAMAn6i6B35QpQCn5NfW0
# DATA xC4B875YtBbaPVotpIBWC5hKqxV6XE+J3aR6SarMHD+JTmfn5QAzQuSgv47BzSg8/zc8yj+n0zunQciyQoJd+c3AYzJllXOJDKOc
# DATA owjTasOJ/u3Fb6ERqIwMqnDIfwm1Q/uVQFDiM+4NJEbCpj/Fdz9CSx7KcEImQJGuFIjXPqJES6Ar/0cjZzj27DnQLtqysE1AoIXb
# DATA Zg3CM8hpwCDFU0qJVFj+rxHAdZXxX3hRvXL49+z4r+Wl28u33fzfKysrr38f//UfG/+1o2HeMVFHNCYEDtLuJ+K/4jfF4SSY5UFv
# DATA Aqm4pJMDS3txvhiwJGq8zJ7YYv8EP1L85SPCMPvin3182FxmZOyjP65TY/Fr3ZZK7FYynPdMqalkecGzvNwDwIre5JQMuFUL8tmO
# DATA cS+E+0th5WdDcKCH6Gm4yHwgfdrJo91UK4aGQ5G0uxaLGtnIipNvVFduNRWudGc4BgRVDQOEQejao5XSuhlwCApfNWFtikMpftJL
# DATA mQCkZkYYxjXYqd/b2N3beT+08Z1MZCeq96g/PCiE1yW2q+WZLD1CPA3P07jhMWAJanbwuGwPkk2iVsezwHnS5t6D9te2dtaTCZmh
# DATA pkwoWrVmSUdMcpf3LJ0BjbugxgGPtCuNdLJXzz0T6hVljYiQJOauSTPbpAyTDc0G3U2M1JtRnFyBH7cfRWWvPZTgOqAgAO3zFvN2
# DATA 8KFgT5AnqIl2btj+7QHhdcFV5izPGLXA/kIDzb4KcG6IQe/vEELKwHpFCoZAAKjMkPSxqJm3yCZcslNYKJb0ih/G0qTpva0tgK98
# DATA H4l613aLojpk3C5fR20MMjxC290y+phrF+vhYUA+pKT3P0HbAHNvGYYiLnzRk3ZHUqxMWkds2AEEz9oIiuhbjnMZsiPzuY+3cZjh
# DATA mdF2+i6xwUKN0h7q0M3PhLBO6451mZK8gZX2sJeM6q0dlWjWdCkoGRsuLJ4l+Be+7I3OMJT+vW5sWC8so0KKBUPGPxTtAIWBoOSY
# DATA Um/ckeHMnjz27fIhBA0/XV4p3bl1FvodE6GmvCx8bWtzb3Vjs74DmJ31zb0t+yBRhDyPEeU6dIBc+MX0kJ5OX/DFfAwfE7abXoDF
# DATA FI6HwaC94WJmQZ9+XMWKzGhinpCSs2RULMobyKwsrmXEW6RYOfTpOEewjCcsBrz0aUINFYqMIzAIVeujjKXIFePjhQcyqqxAbjtB
# DATA DMm4pIaqrmnGcDqGA49CROpBijmAns155x4lzyNyLVMB46EPTc47RnZiTPF4XvDB2aCHCXsBwB8W8+MzL7Cg3rQelb/f8mOmTHFi
# DATA kz041skcKtloPJwaTxw2KguNd5QSjbRBBofr2A4PNSVa0etkTTOVMo5EKtFUA2biaFOQDphnB4BM4qyhp4rXKOM6wGVO28O4InOh
# DATA hgNTCZyEIMS8LCx5tyeFYhZWYt6UKQVfzhQz1pRmhnzv4XGi/PLS0lKxmA2fmD1BW++JI8SfK9nn/ZsjN3ExJ8g7MbuGLQc2LVdD
# DATA DtMVAgE6hJ25UgZVsTAzWXIu9axPhllYuF+/t7pGsiWlOd99yedf3iNQYiiwvQMDdVFMtYAUeCgp2eV0Ztccp1VyJiRA8HQ0wsvy
# DATA jE6k9ZS2QmoPbcDamT2dN9y0qLAojiJDWdMaR0Lsg7uCdI2oSndE6TSR7YFXTEr3Gi9A+YfNgChID/x3fMeUjRejvcCcjGdmVlva
# DATA tcOAQ8jIVJcjwlkpsFqmMY8wo6VEweHNGl7GDMMwPHXS0qLlQOBxUZlyCtIaTEcHOalUxXaoUzGZKMdTQB1peVRR7nH1oheUl3w5
# DATA uczF5KovJW4o/KH217GEeWOjkM+a6dOz0TUwrNKAnzxTJKrKgTFgk7P+9orTCz88j5YFkg46s7qn9gC13OuaeFz612K+SHUvj8/n
# DATA e3aJiHSTgzqKSTws7P2ZIuPDHDubMk9XZt04EreNOW4a+W8Zlp93I5mPZs7bR/LmAXNqfHX4GeUVoNuEH3D7MlcJwztcaRnHhZmX
# DATA C+femeNq8YLXiktdKfJeJ3JeJa7uGpF5ObiCO8b894sUvz9NHgs5byL5byEelBATSUJfOTD/haub1o5c4kfBStMEd/B9i7rxmhLH
# DATA UJU5Q648u1oIi5KaXtlljWpB8lnkimQq1jYZUkuCq+6+Ka1pzVQuuc/BGWH5RPpDYf7RLPECqenBxr2d1b2Nrc3W7tbDnbV6aAXa
# DATA Su8kDj8aEcSNZupibXV5euSul8ntR5Bmg2ChLKMlnm5Qudajc0nbLMgPE5T+Si0H106ZANxOKv3bg43dB6t7a+8kLYigW+f2BV9G
# DATA 4qYDRrpc0eoQImz+1XcflIylhzZqCUgWaEHeE9HVjq0vsm3Ugba0acbCOkpmdKOXzNToKYLQCkpBuEp5hFa61a7b9DRj1Ul5Gesc
# DATA Bu5YqgkZx7FAZdc5czdA4jYyItd36uthOm5pnkuTi4STZ9Z26zvvbqhd+CoKFHEgzn80e5UJGUpavug0jyEOTkxBcDAePo5ReT2a
# DATA TuLKQkKyaXgil677Nk4zkU7Sp2GdnZn6EiZ8VyBIOaukFkY8kDnzGKC5JWRyIALaEkmk1TQQD+OiqUeSE9lWZ9xr8H7CnrJgJb8T
# DATA ZIu5AThXwEJSUknDFTEmuebkjHVd6wE0j740zeOB+4ppnbMocvXB3Y17D7ce7tKS7K3u3KvvhfPlCDTGrhMFLslA+ATvcnJtoeBA
# DATA VYQYolf1hOgpTwBtReJHePc7Uz4yUxCEhSjA7Q2mJwdKnYEWa+QjAQOjMQYbtP6mghWRiOCjaAw4CjFiCiHiGG5KjGIDjZEyW4PH
# DATA EWbbViI59oDbzq2V+E+ijLAsgVehjTC2VcKuaDTGTD5XQBjMkAnKVhGyqgTUnnRGRilYtQPIlzk40rC922L5xP0b9xYsLvSIC0Gn
# DATA +GPM0MGWYU40VtIFwPtLdzoDnBJaNCFAObtIUwJ+9g4PI1TPbGzr2k8g4BLAOoM29rMSbOIJIcQ5oOP2wHBXhByhEcAVepmEI0M6
# DATA +1trXxLbeyYqnqGBSG9glvpACqTW7YK5CJ+RjtBh/IgenjVVMik66GJmD41XU3kYV/BU+TyyTkA5PDqbT9eaCHXCpHfJwLO0a/5M
# DATA QCqlA5it9Ti7GgH61WBP8Em1ILDByMlH8lW5fHBePYqQ9Y7j494IEGsHBHckL1pdxp9MWJZ8p4U5q94zQxfwnRw5sb6SxgNPhneI
# DATA o2hDPG9rMkRqMUghp5lAb4pLII0upOB4KtsPG3sqrvVHJX/3p6RPS2hfIz8t48lw7NgqVV9emdO+5FblyNkaETwdZDTFs7BYzOJ1
# DATA XkGUGaak7iJkF76Edx1RngdyfxYwPj+0YXaSmc3MrBJEwfTYjA6lRwX6Q9lRqVdmrmQ7JimPPzFA9iCfhrxR5O1r+ia+gLinRyHF
# DATA POkIZ7jummeUlESSa5kVZu/e41z0FwaapFYytm1OK8gLmdq40UtE+RPIDFvA6SplOnW6liHpYZ48XJOXnsQlPZGmVEqz8DyxhZJh
# DATA 5uRXa7i+GpeulD7QK76GtRgmnSNKaJL1+PLOOvKll6jhbJYwbmgoBotYbZQYrseLPWNIuImXULVmOHmmIytgal1dkB+Dh4jMfGyP
# DATA ns8cb49mnzwz/UlyeZHoUZZUh8LpoP2o3eu3DwhkJUzTR1/JdTJdTU39wuSJ1MGQg7PFo4PhsG/6p6srSUZ9FL1cpXE2quKC13T8
# DATA 17FW3U39U1a12v8nlezPPCCp6hbd7p4yJIwCWV6RmCYA1sA5d/GIOBkKfjcc9DqYlZvLE2TXMQBaJgr9SFXhA9Hyb5e5t4rt52/f
# DATA Dh3P/p0IDbz69+SGKWppY6xLAyHZyBWJ9zN2JtTmoJV4ofFThmTVk+yHve8zumEjd2SxY40FKqEwMtWrq+vvKx8hPlUtBbYKJ9c6
# DATA ax1hroU7xDkw4bUj45HkZv2huE7n11dvbdfJGmKrrfPp2TXag9Vj2duUHlHAcpZkAqgPtnDiSCRNu0EMwqf2JDIENooViMMexZvl
# DATA pSWFONEZ9odjT7Wmndgguay+ql4wWIVCt/D0US6Y1PkUk6JWcjZfqfGKm4KW5EqSqlTQhXlKG6q+ibixkKYPNHhydRW4KRptJxCK
# DATA AuiKvYkox+pAgKICE2I0Ao0PZi6Vyr5Z8sGfLQasDf2qMUx9qK6mUcVz5ZKFZ9pZ2MwB2oLdjc17Er4VNfdK32eSIqu7tjCOESxX
# DATA 3XYfjEQsfoJpEBElcZ04rCWuBFKrOzluTwy9Aiw914gxo0AFpJI4AlUY6hkmj4dlSRA6o6O0tbRlMhwkiQrjWna7pwjVnKorgLvS
# DATA mixGooroVYsgzmoAgil+C6W8SitgDYlC2dSl3A4uNEQAOm4ileE+Rn7+NGHZ5hZtVxl0b5K99IQTWr9pVQBtG0dsMq/UYj/RRqu5
# DATA l1BxNQye7g9oN2N2Xp6TxH2yenNpeWl/cGZmHT8ZikspJVeiwTZ4WE3qyiNB/ifW3OGGBMU9JygyfWVLmK2PXXmpAkBu4RMRdKxh
# DATA agIiLs8gNPgGgQLyhNm1IrlzvYvRpLOI5RY1gZCKDsiBhlg0U8QoqtGfwXWFhmUvoYY/xmBiwbtqMg0wNC7XRbNbVaNc8ishMk0J
# DATA vNOlcM4FNPIN2DHaOqWcZAyyPfJbJjKLoIa4RenOz4pOlix+07rMYG6k9on0hjIZlyd7dwoHe2d1t7Ve365vrtc39yQ/k9qcHJDR
# DATA aRnqKTe9ETVY9qMd+7PUz4FVrO6qc8AQu3DDTR2lisull6pqaH/rfIxCjrBpu8/oWHScAzak4N5DcecUF7g32WNJnpKBmCHTX/1V
# DATA O4NHwBJEcAKZyki5EsM1QDDy9iAwJhHPYa00VnwCet3EG+ChcppqGHmIzHWAWYdqmqnVSIEGagkHw3B+hGUN65P9Wv7ys+GYU9+0
# DATA AZltyDU6d1NDcvOpAS8R20sO/+1+izrgRuQa3SqSBUd9Vx6KTh4lVaMKtE8J8dXhvVnV6fvqU6CKqhmby/tMB+VCibOib/+csT8Y
# DATA oIZ2LVjr/3iI21QSyQ15q9kx5hJ0oE4KBnqRH9TLwcVN2R0ZpCxxczFpaKgyeEctdtRykfvUOqhYDfL86rYnUYIIvd3x+ZOZfFcD
# DATA HnKtCWNcYtG9Wuzk9PP9+HriKJyzHkpfhdcHDBlPVsgndw6KN9Oteai/mMvwuFN/sCXu7qhVWNvafHtj50HdAd+wN3fVcR2n/W6f
# DATA 0fYbjhL00C8H+bzDMVtlAimjaW1lJb9K2yanucyEoHB7pF5G8VsawuVTzp15FKX0kYzrOZsyOqdZQzEdANQoL1lOMTOxijN9CX/m
# DATA lK3hjZVVWWMtoQVAI537VCjk4nFbPSimxtVyjR5SSvYdsteCLIGEbVK48TMYhJJCbtM766D3yCLm5EGujyr2Ok3DSjXOyJLBlUzg
# DATA CgJLUQiaqOWW54DUF7N634OrCkE7xED93HwW3qp3L5ssZJ6pmLG/XflijlaseXTqcQGCU0QTTxNGqemALtqJ2A26zNjoBRxIlDB4
# DATA eSOpMkfJI+V8E2h1cGzU6T5X/kiMmYqt+aFxM0MyTNjcbMhcmEkXJtcMJdBUrywioEvs5nQ6lUe/wSmribRfijFW5ds2NFIaGIeW
# DATA iHNK47bXlCuXKxJ9QQQw0+c/KaoX7XZY0WTiyUuvd1mNEQfgQ9hRkFdWGVNpoeV10zWUskWZUcdpa1liTq0VytvtOGbHUUkQDBaI
# DATA F56O+A4zLb6jPgfxBDvSOBCLZdDZtJU6OcM/ORFTm/DIyeWXUZx3YV3XbJlti22uVnBHvl0h478D05VZdBuiv0M3FIQcxwaPNJ1Y
# DATA Rwz/Ys0DPKOIMIi/ins/j4K/DO7cvn3zzjze6PXNdw1ZSDulgidHDxTR/cI4/FtPGHitYIQGlJs39ivZ34s/oIwmWfo6iCWpPEgg
# DATA JimHzZrlsGkuk+OgaR9elDGN6FrmA1t7uLvX2n14d3dtZ2MbQ4R26g936zw2UIdQ1YJx7A+URe/FwmHI7umEwJjx7ByXZMnsdvGi
# DATA lorlo2R65/+0ZpocqkVaRn8uOq9dJcvGzhATGkjTvMBkTrS1O9FSYZjo3YDxoozhoguJDrVjb1/X54+CX18sijrfLTMlQC5lbpKI
# DATA HNyZhuxIs8EdaDoQlPZOsMKgciJpzBiJuCNv1td4I//1w40d97ac1oeE8wEsTTcPWIet7587ayG95s1ZmCnwacnv+lNx1aqqPuPF
# DATA y5NIy74xpqCHeHO4nJ1l5FRLXVRI5pxj4yScx+RkCYEjGk9azGtbzFjjZGQysYvSCyQbdK056ROfMA+4zOYs+XLySGgwATWNXDzK
# DATA Q8B1JpPz8ZAm4l2qDYnegw2fTFrteY83y/rWe5ti46/XW3fvb639pL4uZkucdCCsY63gPw+mY/yy4NK5L7en/j0tu2cKxSTpQqfV
# DATA k4e7+56naGYKPzoGdWE+CIrpGeLm8gREaczczTRBxZI7FNVNI8UcH7CXyRmYVrsvcyTdbHlQaD/Nl2gqjz3vz8iGl727c2zil2HV
# DATA uryVam57WJZV6yVlJXwVzmLKeBpHYhXFh/7pm3jpM8KJZDRMHEF8Nv067PehvYAcCioL/+ltPj6L1tXZEq/eOnhJ6+TV2BKt4//K
# DATA bV/Jo/f69cLT0DWFSaTsWacTssykUKOvXOCcMcuilj9b5eVtb5ewK2Rayl56Hi+vU+SsxJOmU+R89qv57WIvYq7JbbRIZtXLUL8n
# DATA QyqSBgTLXmb/lmWA48qVYQ3ryf96mrFwrglPMTEacPIvYDy7nBlJZgrkVpyMy5l5967CPnTZnHzf25YybEvfdcLCVEZn5iskupqO
# DATA bQ2jI+jr2L8UFE8qlYrfw+EX0jvE1VIW3OaKOv7QcDv32Q6SNxIEg1A6UnKJrZFTyvDJaS2UwCbhbOSSnHAljEvhw6RYuKo7Y66p
# DATA 55BIy5Bhw8jkiDoGRmzPQ6U96BwPx7OdONc3duprgGCBPiT1B9t77+s4yp6EB5jDlmFZZZRUJyEljMEIkR8B4ooGKCu28wJ9RlsJ
# DATA OO2qGBlFOsoHN18ozM7WT41KiSSN8HYZq+wPHLb7UtNe7XKkbn1pA916sLqRUFWi3To/gitp0nv9Cd2T+hA7XRMVVBhPWl48eRXR
# DATA qiFXVMb5okXNWCIGHk3ewsjPHLvTj6+6F5krJ9EXxMr9laCOVv2nG7t7u2FiK5LqhllNuuqF2J+ld+kdWsNPUrnp8buqY2rGEfPE
# DATA oD3uHPceRXyz5brQ7TYYDjrRmzIBvaFOezWYDhA4IdIt9iBrTHvAcRgRGFMocczBGLa9dvLl9tJUMqpjc7pYG1Xn0tEk2EI2SILz
# DATA BNieCR3hqeayyFouUgWeE3LSFuUVfmo5g+ny2UMvERxXa/iBMRP65c6xeLGA7xUzMMCtVG6iCB8dWn/vUdTXjieTUXVRA71Xby5R
# DATA qJuvMCyz3AaVsYYJ9umQkhbqktlvC5DmqR2/a0QnVsGzStB8XAa/zFFEwZlCTEX1STVoWO4gqqmio3gPR4gLJMofhssrr1eWxP8t
# DATA V5/C0zMMkXE19cR04I2nDlgEiVvl8bCf5l7i1jQ8OqLA5qdhd9zDdMRkpCxLHdBwJPWHT8OT9pMymN6h0PLSCekgn5R5vOHN8Mxt
# DATA gGJOO8dR5wOsYSLmDoYarj1YR+lSUB3yVPzvYQRICtd43fVkwCwsorFVyMqLVOe1YkVwn0FhXPtLGW6OKVHHleEHby1Vl4vFSgeB
# DATA GQpFp4T4iZETRIVCooGu30Ymz4HN+oHgbcClxIPlFQpGHU9ao2jcG4InXbiyFIdnZ2mHK8x4Qy6WuMbNBPaAqx19tC3UT2WQe8KJ
# DATA iJYluc4UHa+7xseB2zd+LIMlGIJBpc621CZkf7beeKreEL04U29BlyB7DiyW9jfkIXAFumuubJGmrLU2ko6rkmL25eLOiokBGgZ2
# DATA GXlmMQF6WF2pLC9XfihElFFvEIU5mIIyeMLs3Ntar999eA8Kn4jp68G9bdIZ1ZZCnEXJD8I3lqpvIMO7detmVfzP+Lg47Y6QimVE
# DATA nI/f6GlCn7CqLzKtOh4qmbIMYbDVRfivfkYzU11kPbDlvU5zJrtAM6VrkmRh1oPPzmbxZBKmylKYEpcFV73/ctzvHO5l+xdXEUyl
# DATA kKQUx4TtRgEk18UzvKIFWUEfzl4ApifVI9DUqGUqQ1P1/jk0qN3ZGgV5ObN1m15FVG6b2Jkb2UTIojakHKM9Y/LyKp/04xhBhWRS
# DATA 38rq+GgKu3UbfylI6DtQGLRaYvVaraLxZkXQd6vNrxRCFeEONEuoy7VGqPTpZQ0DTSAt6N4fEpTPhC89rMnQ9pfpOFJ8uTwd9/kX
# DATA vg2UAZgcTzAQq9TZrfwp8aoi6IXhI/AmWeagVWRe0zgqA9/R36gmko1czAN5FPowG5oZM1MuA/mK0hCFW9tGFZh0gDGkS9PJ3nYg
# DATA ClGiR+TA1IS71hTZ86FHLMfaO7HTkFJVT7BOtqrQ4MiAYoI9+AcIYqh2PRa/xGjSx7L4B0rHGnEKvlVsMAUvpbgoE+i11p2ejOKC
# DATA F2Ac6yUNB3408Mzxu8kno0EsyKvVjju9HkNMsyzfz+phFFqKXzS6Y2FSsokVQFcw/ZwcczF4+gq8nOS91DRi1QKnByVb2wW+mKi5
# DATA cvtTVGuhXnUseHrqJVD8rCnm+wJ+VhY6einVadIzqBlrgds6gzokAJjq7WUW3OUZGe254M3uLBn6NppvVo5colcG28rokIEX7PYF
# DATA Hl6+Yc0hTQATvwd6zlngbwZhZvZDcnd39FJ3PV+rxqZBJazbFcOXWamyjIkEjUeI91UP/bOQDkVC3TjhHBhq8ezhykPRyJzMCv/E
# DATA wqLTZjfvRsxuVh/AVUf0BdNFdtPzM6JZXbFO/ASIvnKGTulWMX2fkHslpbaHmDbLj9J72BbPLrF39PGcBE5K2CWSo1DTKU0UjaVm
# DATA doOGCJB2tzTIXfrNX8VqafHLHapGNUpbJ1mzaSmXCFvZJKcxt4SoKzrWQrNRq4VdarVgH7Za3CNY47h3NJgisGIBPrb7ld2Ne3v1
# DATA nQelQH9/5+G2mWientOfAlVQCjgVy/WWuImdal1L0v+FZO+FSzt/kriwexoLWq1DK9qVEzQsw0fRaBwd9p5k+H/aUL1Wml4Fapgr
# DATA Maane+IqHGNGdBftOV2qET06/+fg/E8Xvzj//PwP59+I/34ZXHx08bF48Ex8fX7xf59/HsDzi49FsfNvzz87/+r864vfXPyjKAq/
# DATA /zY4/wp+eYYvf33+vBKc//+izDNR3fOLj+HtZ+efQf0XH1nlAvh/aPj5+afnz0TJby5+BY3/vSjy5fnXwer2Rlk8/VbUBS09exP6
# DATA 9cnFP0FF4vmn4vNvxLdnogdOh59hh0X951+c/xFfxgoq7i2bdLira2v13d3W26sb93lC/k3U9a3o1Ofi71dQW65xc6N/wpe/FOWp
# DATA 0cCs7uLXOCPv7O1t75b1vJQCUfxbHMUnospv+POvxXN67SPR4G/8s/cMZi8wJ8qZjotfyQH8SXz9SJSCJfoXMXFUDDr7leq+NWcX
# DATA v0rMGbqst94Wc9V6ALE9d8FgtPHu6l4dp+5/piweDlD0+w/wVS77NzAD4iFQ3jMYL1lZcHDQCXxkDHLpztKS6Pr/J6uVM47fn4mO
# DATA ixEnOiwNkrrj2FGHRL89/93Fr8TaEg3OQ5YBdg8nDSfzj9yr3+F4Pxcfl+8EP+ndTe2Yjg/w9Ctt6/xOfPgC+vmJKPe8hL9i818D
# DATA YT6X35/xNCIBVgPQb8fVRfY5jJ60T0Z99AZMdA4plLtmMYv/h1oQvRKk+nsgHrtn2NjnYjY/wYY/EoWxLrFu/OrXvFxfX/waKN2t
# DATA AGn0TziSX59/Iar5EmeiPZ0MzV6epTNlyQbRhUpzaCE/nP+rqBmW6ZngEs8TjMOzU3gxv0AKhJ34y4xtLT7+9+D8D2JNfoG0/TWu
# DATA xFei1DeCfJ6f/x5/obZ/A+xM1PUVLq+kMsHVfiWqFF2AX8Vvgig/rsCh8Rff//vz+zfpCxno9OW2sST+3bl1C/+Kf87flZVby3fk
# DATA M37++vLKnb8Ilr6LCZiC6k00+X/o+l+7dm0tGk8oFDsK2EkJpHDOK6uN36RbjB4HO9ISJx29KEwCg7Z7J3ifldpg+Z0qIl2efAb3
# DATA J/l5GC9gHBFYc/q9g4Afw+VCFhmryrRIqZ6cqo+ChY7gfrFAFbJ0LCuku3TJMmy16GFcCvBGw0pucRUYxHG/cB0uBiUEOeWw3MN2
# DATA rw/3NmbStVBIIp8DjxS87hfIDyUv3K6LiwBwXsFzn1/8PXNbYNXMK1keA2EBD45voaA4GUlks2S458hsRRMfQ1Wi1Fd4tD8LXWR6
# DATA Q+AWgy80Qh4J+CHCWCCRI6RGq8GQxGWtPZrAaIbTCTwki6NCtb5tuL0gjjjZBTrDblYWOWeGPEjaFcK4ks6MmgJbo3ZvXDgexhOG
# DATA 89A/lSh5kLl0cS1U/oDkfSXfZHuLeBt803qPKEIIL6tGlUVW14iKDcR8vM9Zr9ox9uDE1kG8RHEyjyhqEr+H+4P98f5SOFNFSxcW
# DATA FHyASPiIlvKlECkCFOZAeARxmsVHIXvgfeH5xT8AMYCA+Sm+IqgkmWd6ZCBJwKiSEADLSyu3guv4Z2aH/z1JeywaMAWrzoMIIjsv
# DATA xlaWYidKcs9N0VLIHL8E4TJ40LurUv3tRO0uekIF8dBlR7D00d9NwT0GnMPBhXYaM2atRDEG2wfQUEURQIsIXawxfgIvTvGUVBMH
# DATA p6DwL6qFtp5SMAvzgfDJ7aUfojFuMAQ/B/iEvhnRAE0qb9y5hQ42yChUs3JUW6KW3d37MtokDrqYsQoxTXsxYhKAr9CEcfPfFNsE
# DATA 1ERiIQc/j8ZDmdWAgku4PO1YlbDqIOwOo5jwDcxtE0pHyJkjgb0jvunNZ48lZ7CxicqT4JReMgKJ8TNgi0BFjmz+e9gLQFt0o3uW
# DATA 7bp5FfUrPgDzgLvcc1YULC6k5wxtIdZvMmjXtvdc5Vq9+DrNsVb2HRjuQSDh0z0TrrqfwillzKjgBuLJM7wCPUvcTXJwyu+kF5xQ
# DATA imSJuE8kAOIDGAQt+YG/0xH5c2ngejWAdZIwDHFwMJwcBzu7q7hh62vru6tvigOKU+ScgIsg/noy7E77PcTMMdjVaHrQ73UA0ThB
# DATA BOInwcYsevDxG2ZmnppG8nXxk6SnURtSnZD5N46rsk7JL7XDsdG5V2pOI5m78t8Sugh9bsBxIJbhWyH7fIzCzsdSN4YKO5/Qc/GJ
# DATA 9MMEc613ovRuQct6l7wEnLmqdCMQZAqJVEairgoWg0VuTYatWBQcdOMCNiiTg9UoOdhyE1JPSsKoDIaPC5I2KtNJp1iBb6IXJ6PC
# DATA DN6F8t5XAerdvqRZ4Cu+T/CDu/o/wW39G1JvPrv4R1RJfHTxWzsLkucMVEEko9PZApdh+UqTvfSxejkxjpczAlOWxBBxgjoWQ6gj
# DATA VnhIRuHcCE7n/4OmDkWm32OnYkf2Qo6iZC9DyFKqHjHBHwka/hq1Il+Gia57fIJ9XsDGCwk/YJgzoOtCCDmyOsfixKmMohOyH/Ue
# DATA QcJO+MoCSr+r81GZ7h9Yi2E9oTyUstVF+NmCPZkrT/H5/0Jl1+d4uH5uCXogANryrCkSunMqXv8jXm7UrKKcaMizYoASIX1kyWfU
# DATA 62TUsMdsYuMDggApJujnYs/jJBFncMbcngxPeh1uy504VY9lC2HzR/5mxdDcsNOsVTIQC7GuOCVqbiQD2TiLlU166aGkiWGPnHG6
# DATA UWh2YfRJkuVlMiSZ+JRQBSEpEl/QxT4BfecI9ngNo+/IdR5hiA97T2phZdKPy6FnNREueRhXDrvA+QtmI+HjgxANS4KlR+0TN2sW
# DATA PGPDZWJgRonD/jQ+dsIAob34dNApyDJiDINhwYjmHsbKJ58WHYPcaV9CpGLfGAJyN5QYU9eKebSCzYsLJ9HkeNgtMQ6Cg8Bnpiin
# DATA AlZ0mcxEbtwI4UnyUnjn5hu3PD8DPwv+W7A0XHr99Sweu765a/a5KniBOMr/oIwdxtUPuOnG5oZiHAHaCKStBNnCHXGncjDHTFVS
# DATA hZBW2NVQQ4pJDDXzVWIdcNIPjgphozuIm/uD8AYO0/DOkOsV9TEjNSTBUG6r4h3loxeNT3oTCr0vPIVfWp3+cNo97LfBpD/qkdU7
# DATA RMAAWjfyQlCFOOEPvXvUGdJr/JZaupRXZQoI6iclnHA7EZ1wkiNP50AMNBJRmKMxqlXykNESSH6qtJFs+xG6o4gZBRbHX8b8ReXv
# DATA oEoqmHBiVn6J838G4lCGW6IicVxc/AMJ8F+joRfPn9+xAeQbvtAJGiwr9dkzsmRCkdBBhjPh/uRYGZ4nt0jxL0jSn59/IRoDi9VH
# DATA 2gD3CR54xmaw2md2d5kQIovtUm0Qolv52bA3KByGTz84A/v5I/DSJ1eUkjX9MrtHBWEVMfcu8xpwNjekNqSgUiDZTg5B0KeEs6kY
# DATA rGC28yO2YgSAGolBx6EBDVm5sV9u3vixflIxwSObT1dKkDgUa5stvqSpbGnTaJ5+LDgD+jeHHCBBvQ1v4N8bIcZCINXLgZhpYnG1
# DATA +7FGB7XPXF15orj8uPioPV7s9w50KuBF8XjRkgvTChmyoswTpLgoNX1DrtQNDAAJb4jXboTJOBA7jMzIO+RqO4yxiZpjUkfn1544
# DATA PmLBjRqylBvAxYi6sdpi3u6WZyZOMpyYzLuGGSQj3eJpj8BtbixT/YiNgLXrFH0eEtZ5VNqdk6jcIOJtNhTiKUAFcYWzeY1DtILr
# DATA oMvDH+Ge+DEyuz9azI77RGIBdTYZX6412lgiU6M9x2ZSPBCtz5/hFfV5sLr2oK7UvTEavcVhNoo64oIoFpF0Jk+izi4mtfm76RD8
# DATA GwPQmXTR17EzId1MfBz1+/J30p8IQbA9olMMB6JjJPf3gYb2xb/QiJy8Rg+vmc9eg2evvcY9NOiDklNxh/lvWFyUtHAjlEGEdoLU
# DATA sPFw0JsIWWPdiITYiWxD2t79XfOOvD9YPRSyTI0jvspDEBEj9rALOFyaW9sfvNeG08JbFnmT1RkOyRH92YNAAiEkxcdDUe7hg3b8
# DATA QW1JSHf7AzX7tWuC0dGc3giv7YOSiA+qO7duXWKCcPPkmh45McakiH0lJq3dhzE19qAm8dbWYK0t5PBue1y7Xhb/FyzdLC3fri4t
# DATA VYFPWUPfEYQlzs2fR931qN8+3Y06tZt3oNQ2KOVjuAzUJuKMxfo3yLLZpNmNundPa9j5WE2sMxee0JhLRcXkCoiRWBIUyTJClZ4p
# DATA ZyigA4y/AHwTUu9NjlWs5lhKsoavasMI5TC10uIr6w0tX1Y61TGQhTK9WWEiMUMFqqgx+IiDNnNdjJJRIDeUNS75o5RpOXiyJjMr
# DATA J0tanH86xklx3wKl1cgfWuK4o6oJN9yYXW1XuyKty+2Kpe9qV1Dj1bYjuaFPpg9swl15dGo5TUtV3exmTFf1+do0SMho2riBtitS
# DATA GBQ18y20XTFFaH/FTngqCZrmSFjUNOu/9DCIvKtWYl6YN3Voi490EvochRlM0oC2JhfnCsEqJu+KKSTD+86WRF8NfhJFI7RUSvyi
# DATA QB7FeOOGnN6DTn8KaOcBeGYcDCdhHPQBjYAvJHElmSW9EU76MoiUt2XVmExrN1OwJw/KNIZXtFBQ5C1vlYV9aZax02XSQcDTZIFQ
# DATA +pVNJOgaSZgn/diTz53lF/BTIsA2YyQou1i/Qp99GE9emYXMC99e/ANdHy/+Ozlm4AUTjfNwwRQns5MCiNzQRZMNqzPN4pvmT9CT
# DATA Zg438hne3X73aji6E57WlmLkUt7XYH3/GQGWYAJXVpGRSCZeftSD64rBD3TKQYlAEgX94VHFcdkPz//VcGwRM1oVFyjDrxEh+XTu
# DATA 0Yj6rkfOut3QdIlhh0V0sdnY3Chphwrx/2xuh4hdGEjNSKWW7nS5/H+ii+L08HHraNoed1+iF2C2/9/yyu07K7b/3/LSzeWl7/3/
# DATA viP/v70IbNvtca8PgA8xGFogbyjjED18+z0hxWI2XT6OSqR/7w0o6SxYIsaUYPo0ywXwsDOY9Ofw94uPp5OeeoHiZebzAOTvgF0k
# DATA FVzosEMRXjP85sjtz+8dJw5/x1Hu1u1sr4to8Kj29Pr1YSyTBIjz9f5aa/U+usyvGQrfmX52O+TRaJxj4CP2GVk1Lz6C27aOgHgu
# DATA bW4YjiH++1t4KF4Ry/pm4OGnh0Loegw4Veefgo8MxhN8cvGbcKYPn5izlnEcynwgEoLwuIdmSmOSt9F2Y6Fr2Ui/bL2GNyuP24JB
# DATA y8m+fWspD6AmvTkBZfUAelRMTyjgaWR5KQGzb3R+j0rVn4xstDpd2Qe9ft8FktStZJnTbEMa3TK1gknacVK100n6yNZPgykWra8f
# DATA ow4dyOFrFSAkyERbuF/AkieOGa8lD4xqZP4268cR57P2/dcy9o2jg+Fw0pLstCCmrcQqss5EXI/EJhMSzbAvJJkaq1wSqt8yzLWs
# DATA ASSg6aA3qaUqaBIvIj6sVmVpyqN2r4T2vrL8MHJSILefy73ipD3+ADXr9BKhvhBYRsiaxz1EyxPTXUYHr58ND8QGF4MGbL7R8LF4
# DATA qT+MY5i+fu+DSCoqxV1sMm4P4h4ce3ixdDWPYhZfXO3InACWrpSmIsOFwk3onN6iG2LWpA4R+qNUhaZCLIA8Fd0eZWWdHNfRj6Im
# DATA 03vQDBYprdX+IFVvaNdoag4BVI5nRVRyLeCcueIsbB/0I0PLuD2MJ7XFaTxePOgNFscnQfkwSHTDaiZNRYeIUOUpXIAMNZ2hrUSP
# DATA eGNDhZRCXZA9XPWlSixRiroc0l6qYJ5za52ol5A2AoUm2ar05+GjjIJ8q0ycM1gBCuVRVx6QpYCClkXXOAwhEtMn7uH87fFxr3Nc
# DATA I5mpgl9KUiozE4eJ1wlZELNPkTTERynWJn6UnwCE0T7TCSf48LEohC0UQvHFNjOIB4kTnCu0j3p2aK7RXCOfk0g5zaQ/Hv5QQVe+
# DATA GI4DSkQyjSGvOE25ZaHIaJf7mVGjpz4fb/t3n0jFjk/fcjTyZ+wjJXjam1J6NsLx/kSxwOff8BxKW4iaXn5QFnNkFRFE6RYSj+yV
# DATA kJWxhkSVmjEsjnB0uLZ0lP4Uh0WipXoIjptuYDHNhXL8SA6k24vb45MW8F/woGBSRaKzz8Ci7xBkyGqxGQPUtHmOPi92KbP+VcFj
# DATA ZP0ylRzIFqBzAxWGFIIrwWoAcpzgYBIldQyoq+jHC6qKftBjB3yDZXRdyNvOsN9ngKVyGU9j7Bvx9nJZsB+iuRriQmpGJ37DEwbS
# DATA iowE9ZzWVjud6bjdQdvFMmjLaOPobOSSUzWL3tQZcqcZL8BCGG/M2j8J2cbQaGJnxb3vRMzX4+NowGDzHDzW7vUNzaW/M3bvTZNq
# DATA BpfIuYvTSF5vW3QLZy/kX4jN+xzCXz+1afv88zcD8k9Cn+YvpQU2VYRBfsA/yIffQhVgJgWnaPSAtMBo1c4oFO35Mo8kxg7DPQAI
# DATA dcqm89Ix2nIikXnfZVoK4Q4hLtg11aOdOsBcr9d3coF/cTU0pLjCXxvL1abCopLPqstNULsCyn7YJD2i+bvJMmWtzDIpWIyrWWo6
# DATA ZvNZoq92ent2/jt0cAcqSlrGv1Ja/mLCjS9cFMvuCOjgQ1DpDzsfJO5l4AiPECYDvkGKb1uttZ366l7wIX3ZWX9vR37e3Hp76/79
# DATA rfcsSYXQ+4XYOJ6OAApH4pMcjuH24ji2Ila+A36ysblnYp9kY6Ek8VBkGgD9Rmvj3qartP1JdHowFOLRhuxpoZgNyTJXr/wILcas
# DATA sOF79rUUlsmYM1CAidumeFiA/5T4CQCrtOo/zdBMJ2RBDUj24haGxGRmgMWESohBAUf8D8NZ30znf98iGsLFP2DEDfFKvzYqtM0e
# DATA 5nYyDB/z2TMywG78JgezVWV0MG0XGMz7T6hW+1WqDs0zQClRhH9uNgZKVFNuH4Er4ksyAWTq/5eXbt+5ddPV/7++9H38/3fy79VX
# DATA 1MUbMpCPTifHw8HNhWvXrt3n1O2QCYioRDqpVWCfcKp3SuOOGQ4QDg7yGoyH06NjlAiV1JzbMHDcjsEgoL6etDtkKQDgF9RjwJFD
# DATA P4LeF5BZdiAmOJ68I1hj/yrgBYQIqT6Dq9WEmk03PgDPsKwN2Nh03BdtVcbUO9kmd7YEP8PBsaA6QLzHaEU7PCA2sfcXxjxfoOzk
# DATA aFBne30LXf2FJGfkSFhYu78BNyZc8z4sMKlcpIQRLqxtbe4JQay+A1hbeztb97G4LYaAMnU87IcLu/WddzfW6vYdjEHqkGKUGnHh
# DATA 4ebGXmtna2tPyzY+Z7GF7Yc7kMIDEpGm1Fl+tCxa3lu9V9/FECnUYnB2l+7w8QAVORgpRUkmGYaWsl6EnNrzlF8AZ47eQCwlg9b2
# DATA DuUvHUHOA/FCceHB6k9b97fute6+v4dNGmHzSm1LKaTGwyMx1zFnxxnLlRYEBRiKiGZfCqJHOjxG7IptCJ+Mj4MDMLGJfSTmYURl
# DATA 4hJn95ByqRSjY7wmtx8HTIYyEhz2GN3fiOJqoNRs9SDjIz5gZRRdue0EG1YeVfRwge2jELN5xRdZbWKkE2TtDLtwiPZkFnPZCal/
# DATA 0IXSFDZGfUeRDITmhRa14JzopD6cQ4tWnXDk4YoZdZOam4dIN8nsPvd26ru7ttjtDJhypMh1RZWCHJeTc3MwBLUYRoDCfwqe+7es
# DATA xpphbTVgyQeQzzeHk7eBHJxoMqOCpyHOEvrnUGYN/Ivq1Ki7Chjfokdwo0ZKAiR1BElnKJfYgJIX++RRb4i6ONlAg2tvKvQCeEkw
# DATA C7GlIkxDAzxIEGostSEAHEheTYJgwXyofaFg4z0W8mWskApoTStgQH5SwJYggtZ6KjtVTI6+YYyi2ZAFwfXppP2ksFTCpSi7Y9Ez
# DATA 0ywmqqwQZ6G+1HhG7ddqolZ6EbcxriE4pUGIwv6TpaXy/pPlw/0nrx+KDz88bHLKNCxbFHfQlaXmgj0IXhjod8Hz9EbQeBq29Tpi
# DATA TQCjT0yECorv+PesWWyUV25V3TY4C+EqZZkXFS34MvdhTkN+x+fTSrW43I38u6oOw0nyAtsxHsslNLX+VK/e/TJ7gzo8z9io9g1D
# DATA 3SlMDyvpTVVM76N/pyPZiucOFTv7SWkvRv2Io630hI2OESadvT+5SMgTDKc8JehWHbFZb5KrJqzckG0AfMMzWTwfsmJoornYzRyL
# DATA OgK5/eCQ5iqtTen67wFWKzF1wbn123hbl49p3ho4b9WmN02jngJ0Rynwdo+nJwVVaQMrbGbWLZhDYSaPKCZTjaJzhupELViqel0+
# DATA 3LXiTGB9NCmC5UX5zHV78ajfPg3aGFHXhtwMwbWlgMEGrlVc/4NskjW8AhOpbIWoapCyPjwSBCoPkg2YK8jbhGR9I1iWP6yJqQe+
# DATA 048GBZpXXwYPJN3dCWbUsMpy4jomf7xgYxNuWqdo3CH+try05HmHCIA6dx3LLJqtuF2KjWPR2DL6MaXfkMyy6mehTqVRvz2KIcUJ
# DATA rpZ4yaLKgtHOoSCH+JgaInnoMRChtyd4fBUTI4CI8BPoyI6kLqNd+cg87pNHyplg552+IAVLHjKcLKWyWBALMX6J8NEfHjHTZ08H
# DATA PnMhZyqkKvJk5JRcBVNeJHNC5o2u3Big471C8BLV6VpyJGObL/0ay4BmuhkVfn/Y9atX39vZ2rz/vtSpWsrW+k/X7mcqWxMIBUoU
# DATA Az6ZzJJZdRmrKg9BudB5uCVY0WfuUunFqxBckQy7VI+tBKPk96t/oeBxD+CALGMl0E1DRRAz0ulDCuPDrusHZXAprVo97HJcf5Iu
# DATA W0jdBboA8d0K4jwmOgiUL0ck7RTCBsgIlFdvMj7EEzx87f3yayfl17p7r71Tfe1B9bXdvwnJta9ydEJnPIoRTfRKoHsIpMyCb9QU
# DATA eUmEKqI2nE4Oy29ANCqMPK6F7OYhZRDuk/Q8Sg6L0ZiY0iJjf9pEk4sqV7e365vrLimmOlip6QaNKvW06jrAp8x/yBDUZBuSuOJK
# DATA OQ15tJRnB/1YzFuzuIFDmCQg7sGVKZvCDCZGeeckulWClcltkTrFODmpnJAZ4Hc7U7xB4CeLzzK/yp4aU5ylGZJKE2N06O6mLT5X
# DATA xNmtezhoVB5urr4rpmH17v16mMqCZV+SSzPL9LWzbu4CSff6+yZi2udzNBxLWBEMerJX+UTwAIZAQr9BwMygch6/QccJpbLb2tjd
# DATA qd8ryEok1kZqFEuOWdQ3gOmg06aLhlk/Q31Yii3bKEe9j6PoAynQJN4v2+87QwT1VE3WA7eNgl3aQ6OpBpzsEVMwML6oMBzkuM2a
# DATA oD/iv2BMnqDTW+EAeXZjhS4sqkSjCsXGQmrrchEQgKkQuH5zPQwels7qM3oTDbp8k4FJhmyzhXFYhn/AqAHRIGheZ1D64Cf19/Gn
# DATA kDzP9TwfREe9wSClorv1exubuasC9ALqExz5COihawflG/5InhZCLviR/lU+c+iVJyps7NTXV9f26uuB0YcmnsGiRIPrBWynIqsv
# DATA xPVH8KhYY1pZe55/lYBQyXusZdCi22uD8pjI6/e8CgB1fTJzL9eCp7JFytxZUpyR87LKr55UeyzmUBZCg6fKR/LSD1plaApzJ8of
# DATA K0f94UEhvC6VGo3qnVugL8JCqpS35VhIKIm3b65o6DBqEsRPbjxDm4AgLrYqAd9JsDrDzIrv0JXHEOPxWPfwO2O+wY2EzBpYRcN4
# DATA vVksXvlFGeZCn0GGNN6LsqbEeyD5EiZf6nh6kSMq7dRJPa8yjiHG55j0BtNowRPoYqSwTuf/OdmneTsitFSkzQowZ7gXCW73t/vx
# DATA 9cJb1egJGMf24xvFtwoMCdNqGugxzetFUbAGhSvXiz+ws1aDsabyoFj163w0ZyXu8yHQyWNB6h8iX/mQpbwPdWDkh4Cx9NYH0emH
# DATA cGSCkgxilj+M2/3Jh90YoQNgMI3lJra8kTLLcotR4ZWm4fGGKbr3r+2HYdH7qug4KESwhmLwl7XgVjU1QMnhqfSOu6cSgmRiw1A1
# DATA iCIyBG1G4Sn1H9Gf8BP8xNzdwxeIDeAB5HT9DDEja+JpSSK90I3e2It03sAf5VNPbZWMQ6gpY1D4GJcq/MJbvZNioT2dHIst/nNU
# DATA JQpCaVRrTSKuA0EA0fhDsZC9ThFobH8XMGnG4f6yUbd5qLothNyGqKxxTfCst/YPLOIUz3frazv1vQ+3V3d339vaWf8Q0718yMdm
# DATA 6y1xbn4oCqzXN/c2Vu9/uLq9Qc9WH+69s7Wz8TerkBap6FbKjanBFBt/uz/eHzRvhOF8A5gtVDT24/3d5vW3RKuzRJkPf1AMS6nC
# DATA QVY39g+i078yBmlCQKV9PwhtGsiqvwCwPOL1Jv8VddyolJvXq4uLMHXx4o+rzRtV+tS88ePEHP44u/dPlg/2G42l8lvN642gvCj+
# DATA ++Py/yWtRYn3JKRX57g9bncgwBqBedQ3sZ+wJChIzYcQHzEJQW4TTEq/jZvp5kpAPo7WD6/UguWV17NEViXQrfN1MeCcnTFFfbfj
# DATA CSG5V4K940gpbC3VHWkqwXOEsNrRraICMHwsD9paannzE1dh+ZEy905INwxvAOSI7Cw8kp/P+HLbB8TeSUs5orTYT6WgLfA7ZAQP
# DATA TqYT8D4O7uMriEFfgn4OBDuaYIfBe4KcBMTX9oSA54NJ+8gwvY+GcY+vyjrak0SenfqDzdU1SDm1U9/e2t3Y29p5n/ICTyYn7cGi
# DATA Qr0pq+669rNUbDRB54vOd6BN1Z18RvGd+v366m5dRXtKsx47rRS04imUiZjESVc5ElLJ9ABcahexxcWnuuGzRekZtEhr8ZZy62ih
# DATA 60btqeulf2Y4wRNOWVx7Gq524BwCtQg4cEBACuCjPhp0ufkbKNGWIHO7qLe8xgbCKgjk5Q48Cz0xuuFDQYXl1SPOi62XwLxHhGf0
# DATA puH4yd47BeXkYaTMACFsHMWj4SCOEjdQfk4y0crtO+xJAldMtdZw/IniYBXXJS61gDjzNpoJVGwSlXEMq9y6gHp5GYoRWwHHiNUw
# DATA qkf7CJVampILTquiBB/97CvikPmj/a7g6fI/wCfbR0605thusztuH4KtpRdjfZhaM1FoJE50mZraKnmZgXNeBxgLeKFbYV/8jBmS
# DATA LEniTTVlJUyByD8r1qSIIxf/Ft8S02PWPGMQ79Z3doXUoJRvY7x3T6aCdRdO2iNAVOX6JOg5ZPLSKEmD0wK8BHS6fOv1W2/cvHPr
# DATA dbJkwFNxEmGVl+kLzx116UZQWCoVxT4o3ArKuDuoXh02a7nTVDMtNv5rl9enGzXh4xRAYdb4cYAwbmfAzr1t7WLElZaourmmYXcP
# DATA EhEyVbH8b+xeC5HfTzT5N6/ZFk841sHTyp4Uc1EqKKWRnz98uLHOr6J4gR9z7qy/fljf3UvvVywejUw3lJaMmD8Rp478xkluFRRw
# DATA dYb3GztAeJzAFgzcbfHdNpGJMWfpnvIrxB9u7q6+XW9tr+69E1o9ymfXlIUTVs2kV5+eM0VJerIMaFZ6htpjFw1Ll08HxDKIRFVV
# DATA QjWVa8k0GlKfG0tNR+lHwaJoljPTg6s3isTXV7e3W3SVQrHah/EFns61gEbC8FmmPkkpaqyxGSEUoIewVa5/q1utwRXiEBA+n965
# DATA dSY1DaxhSA5JKgIQJpfyABkAssxGqDToXW+uZBLRg43d3Y3Ne3IC+FQGLQVgvp60O5VB9JirU/C/pYC9bkvS/boSH7eF5IHSWLd3
# DATA BKJf0eM7lk73JSG+k9K1Ss2fOSjesiKgqYK5cYuJPAa8QobUF5sIguxirJDBGxJwENwDMVRbrxw4ryDqGDuyC07CmICF8NGwPz2J
# DATA wBG4YbkIKu/IBr5Oqij8BMmbqMbeoVe5UjC2AJZk5kx5nOCBlJEQNBFdvxIO2MBi8tauFChJN27ZWXmQV8OikEpWmsWmoelR21Cs
# DATA 3ukILl7hQW9gQjwSIBwzm6IGfKwmm2T36hbECYjfgVWdLfi8F0wvAzgqGrIjTV/0pkXv3FTrwdbDzT1o+O37G2t7nmRoXL1juMPV
# DATA k3ov2aqP0u2jRSICGw3IKUG9u+klrfJTpCVQT3kRdhD79FVJLgWfdnQRFKvS6yIcATtZVtGcO2/eJ146ThguKwlC1MTy17Mk4CsA
# DATA 7kbdFh+keDB0pyejuCDt0cVUVAsO2C7MwHwFJYG44gNhQ67ioED8BfUG0q1Tolu4WLgOIEUS8DbugWLCxLhVATAc/BKU76Lp3Rga
# DATA RVf4xoWOIBQRiy+ZswM/oY4j0SkA74Cmh4MyeybsD/gZwtLacLz5sS58pKsjLxYDDtgocfC5u7SJ1JEaWyAJlVEi/AhDBMl+XWFo
# DATA hOXyYPhYfODezF3TmGYqtQZ5KUCAFCHBgk5+csoCoyG5GBogAMAFzLM+cKxTlfdU8EI81N6UdAcxne1uMAHsGDpWo7Y4snG6lQ4o
# DATA VcRUiQfSD86MNASWqCll0xcSMCW2JrXlYVQ6LkNLjybYa6ZgJp/xjItzIDLlxixxjTt2cyX4Uc0WgGrBraUf3lGY5cfapsC6UcIx
# DATA 3h8jxA7qg8A9P2wW/4zkJpmyISkjKR9N1EhVVUx2q9UTO7bVEl3oH5Jt2YxYFg8r6WSniugrjn7DvOeo5lDkwraSjvDGPcKs0z33
# DATA jMrajyLud0I1YU1LVn38rhOfoEPWSV/aTfYZDdo1t9euxZ3zyTve7j0Z2sXQsyAEgJc2RTix4T9QdnMqJVir7I0ffsIivM2tvdbG
# DATA priI3wdvMN20VBNRzY2Qv3tgOhIl9LSAQxcTjFRTghuAeR+eHS+mcOfAmd6XcUpeMHFiiXISPgCZMWJX4Okk7QOBXBapv3VDtsSU
# DATA hBmgxEn9xoiDgVIUcaG67K3cgvQjUDyf65Zf3eFOaupuK4TQFI4Pl8YNc/FPPk/Fy14Ap2PZq8B0bLkhqk1q+CJqukZfluRW10Ce
# DATA TuRspY+JI4xqi5bfNSTEIccCqMJxZHKdPOAfgMXlWxuouiHEdQzp8q8Qr5Ko044DwjBHMWfTCC9gMuCRLnhG/FFQ1u+agQRLoHh8
# DATA fWUpJU4F3uG4N2yxJuMn2RejJih0r76z83B7z+JMqss4MlELwY4LCaqq+gFI4WZiAZPwxFDMpAY8XHXvQHvYEahmQgdgfHaApL9r
# DATA KmDKMi6OODiF1vzMOK6S4dXMRDvH7UGSe6LOGAkAkT3IhAAK43aHMHG8HEb+iDpTg3GmBXNlyXXb6+AgcPfh7vsJ/89TXyAVeQ8n
# DATA h1kBxMtjIb71fh6ZO5DGXfQthq+WdfyT5tKZPhDD1Zl8OslH2dz0LXI2pOUgzqxoSR1y855sOlRVBRfL+4VEWTKuHEJmPxq3u1GO
# DATA sz2dwyPD8XIqMTRUQpjzTwMVEsXwcavbixG3zIJaSgwEQghlP5FdQINEWiftgaiuSzYvJNaZ49hevVdvPdi4t4MuJjicjR2LJ6Tu
# DATA AfiasgPop5dK/+xNnvvknL15DHWgL4Y7JT4nefbWMs5e78uaZeLBrb6me3XNLXI4DEK2P3tglziw7AqcU+tHGafWXOuf/8RQjmyu
# DATA /EUHBQTUUZi9XoeqyXqMxa1qYVvr6/SsmLGIxpy4ejd7T3oitp38GqkUm6JKISzGTKRC1qmVEeYNwAANAEMTmuPIkrL9WkjxngIx
# DATA 1KotqlD9wOhLD9pPQAkGNAAFXPUcvnQXlD+olEttj0Hq4FTRYl+JpVPIlBWNuX140OuGktGKRyA6qPPE0i5Zjh4+YitcEqvKIrwZ
# DATA gpm4Lu7stVQEEctLtWSo04Lf3VOdLDlFdU/BcVjmm0+5+fTmnbN9LuiL6pqDhFO2uDVgJ9BEBkMBQK0tLMAiW7LCJQWEK78RzsWa
# DATA L32IOYdysTrjgpk8xvLcHcnonwAxAP0IM700EdR6DO6BjlpKxrQVclJp0a2w1RlHHP2EEslsZknReYiEogP+jP0CuW3YDTHfhkhS
# DATA t90vYCl+FtBQ16AmozqJ70WPQJIaYYibRu7dmjl9+uRScN/GEhqiRtF/7bti0VXNvpZf5RzovjR9csiVSLwvJPle+T3ihcQ33+Gh
# DATA xLAX4cnkGOWJcFVp4wmwtbF2f0OPLZl+lU5cqapEXBvwCQ2bGauJ/hBcMa1lWr24J03lgvrc9J+Ejmx0nZK++GWCU3AogAnq9gY1
# DATA 4831+rubD+/fx19ALpD7j/JNqa8+EeL15aUlvwyesa3Xth5s36/v4clvb+189KChZaQ8oTOlzxlHdTkJp3doMkE/OXGAPMEEzJ4i
# DATA GS4vPksR5FKCFe73re0673evwMGcyQD1aHrwgHLsMcvaMk3oMzPV6n7sH89FKwVkBHWDd5bcxDWYD6BF2k0eJ6nr7f2TBF5P6NxZ
# DATA nLIrsaemjUkNazOMvb2Y0dHtywp0oal30u2ikTEJwXm8SjdoMUlwgM/TFWJQQLcCDdDTj9qihwBndjAePo4hOTFrLQB6BihgEvVP
# DATA K35umaYOSb3wp/+Yy8qSLrhZ5OGxxIjpMpa+mulGYu0ihq1n75QcWmTQ5sttUzMItZjdJg4ZrYj26ZTM4zQdjznyEN7RZsE5Q0SL
# DATA adV6dcnXr3POy7D9SAwe3Ryq6iV2LWfnGtUl7XbDBZMXWYVrJgq5IGyGjEWTcmaa/Try3gPJptxQOTIw309QG9mZMZFjq1XoDQaR
# DATA LygXn2OcKMMdkKu0dLR2bbiMA4qA5aUkCLkFmOOC5MCE3vDILV7R3UXY1v10cLZFawXElIK5IeHC+H3zbjFTK+YV2GUeMmhYiFob
# DATA WylaJnv+Mk83a5otqvN0Knm74bV8gj4DWFcpuN7yB7jqpubuMbd/H++X1oGmtPTS1yF596ZfWujKXzJu4jqWAh1NSqlX88trnVPU
# DATA LrPYq9+QPUuXa2koXkifeUlLe1YHUzs3C13wUgNQjk206uDOI1fbZdj5mgL3ic36e/Udp6FXg61BpDB1UdD42VAMtN0HfhxPDw97
# DATA nR46dkFcn4xRhBAt0DrArLTFBe64FyOoTSIU3QTqMjkeoysoPEoJs1DNz8OY2C2Yrga4QBkol8VqGZ9w7c3UEPAXR/bKRvjKeWdI
# DATA qTdD6a48X+nC5FOkS9dXrW13/VmZ9fjHdClFfKok8t2o39NU3QmVvN8BppSqhp+ps/9uVPOmVv7PRQWfS8a9SoX8DOclCDi3Cs2l
# DATA hs8k4KtSvht698to3F29ddqJ/sJ+Z7mwyTN01r3B4dCnmeew0iy4cB2JRAhAueuIj+fUc8PvpgnBp12fQXLFK1GcYy9Yez6bhK9Y
# DATA cd7y2+gNtSZR2VE1pzoONU1axc5TFnWJ+bJaHXtjn0roBgakXzNm2n9+U5SamzXaABHY2trjeByLi+oSLIj91dZd65w0cQgwiLm1
# DATA sfn2VuttscG5PqDsYmo8iaeC+ubezvtmDUjYjgOXs0x0psMi6RwOC3Pd/+39aedgMIhPj9zMFXH+bzpxD+X2+fTiV5iX6yP4ankw
# DATA pNyLZErAWgbMRC7FMym3hQAA/SvLsHRHV64qb2JEYQ2iCvOE/MzUWCMts7oaP/vO2h+mqao1yIA2JSL9pJRGz/SuhgloEC9QG8SP
# DATA hKTcoel1f+VgniNF6+G1d2ViGr1MT9XHsyontnkqKzxTIR7iFf7Nv4HP9gfXVAhAej98WaWNgykxoOBH+irkbbc4l6uP3JhwQdqp
# DATA r66/H87TlbmuZZe4nlkO9kwFanE0q3ylplfvko5OJkiDp3VkU4koGxAK1C+zbkaXbv7V4C5plaE9SrGLuPgn7VO4bmHGpXYwiAA3
# DATA fkRZYnSepcrCTO2somee0JqfrqSKRpaSZKCEXawunQ2+JO78z5oZWznWIKtcFXJ1Qp65z8+/vvh1QCep7DWlg8nHd/UN5qAtJKuS
# DATA cXQZVkwJ8OjnxqZx8Ltiy6n07G5X2EL+ZZ+LoBmbo/VgY/fB6t7aO+GLrDInVoJF/tfz3yWzpX6BmVIhnd4vKYVgOGNRZ17X8pg8
# DATA Z4l6jtk1W8jzV52q86F2PdlOkk4/2amIijOrd7PnOPkfjDQ6rsPm7HQ62f4FfsuAnWgEQuLMHEXeXp+liMuXMOxkaqNeqhH8VURJ
# DATA 46sHYchAEGGAGvZucHBKMaajYW8wqQTbYhIgkDjYRkXL4iCawCXbUysrGyA6dVjC+41oI+gMR5DXTCk6u7320WAYT3odUGFOhnS+
# DATA dGRa9EuZ7FPs8S0Twj6/GtTYDjNNX5fmRQnyJ99mbplwOPShlCu8PoWnfZPK2GTSsoWrpOcELaPimhYFA/B339/dqz9oba+u/QQy
# DATA pkjPJnER3H64F2aN1Js31dgDa3jybNvbYNAlAnCM9K/fzmoJ539WxlbjmJIJW/nW61VYXUq9xxPnBrw5idAv5x+SS4KC65RUvJ/0
# DATA YjEJRzb4T0KllFpa5YAZ9J7sIv5iwcxxWdk7ppSIRw96TzYGJSsBZgVfQl5Fr8r0AAgM0Jrgq7GpnAFtIFh7eMe5Li7iNBhQNHgp
# DATA aHe7vN/j6Uj0CiNB1ItFzzuA3sK308LthE3SU7eCjxJ9L2DMPfeFpoTzhxb8aUWLZt4BYocnok5RDas6E+ZVaxMSIsGofypjycQW
# DATA KCGGmPPWwbB7auNqYCF14/TYI6JBtyVxBQtQKq0QgSkWwjWC0CwDIIbMiCkBFT1KSk8FFsRiCSEWEW0hzNv0/WhwNJESNxizYNyu
# DATA vym+rt+OfaN/jIZpEjGwDmvKj3Hx0ujPDIzPJioTDkCLZ4TbkAd53meKRlgBEE3b46jFaAHYGx4t4yOYoMQEkSD+cxcBifHmgy0U
# DATA 0y27eO4h5d1augkCljRvhW9v7dzdWF+vb4ZnOVS88nYhs5GCj+a9+h552+IvpGaGfLEkR4TZ9nDdsRXANKN5Y184f4hsjvYpHUEM
# DATA gk8hXAQlN4X2L6b62Wb1RmmxoWqywjp1Nq+2p0dRakclOmNKf+jNpoR3WszGBSf8RLgdrry8CLL0OcXmEf2cPi1dfhqJ4Diad/7e
# DATA UCj5C7ZuuSNTFOylaN8TeZyzZ9tbuy/atT5yZEVhBhNqQQLHJOduNDNJjOsjbGkV5mnxtr1xexAfRuNyHQ43ihVk9Ru/LSij0osF
# DATA c+xNtGpuKfgR3FoKugyqLG2Q3CsjZsb5NBAQafXw3EHYT6cvxUx3DEOEhZolIhzOz4TxQl8BFwjEO8G4eMYl24ke9VC9cPZdb1kf
# DATA YWJPX5A4cfMttjsUT/lfkypXbt/5L0SUsGIeDAcdGvYyaFNzao7/hw41ZF+aJEZbsULyke5XMz/Zr1zqbEglchILvyfv/wzkbatx
# DATA vyPCNmk6YZu5CjpOl6mty8Et63IApru3tx5urruXg5eqFrU69EPy4FEKINhOpm8p6XtuiXMqS42kx3QJXZK7jsZcdIctIQ8CPJx1
# DATA xzR/B57gL0BqFemYQ8uU9JqHUgoR0HhFQfUhCRvP/ViAzss+a6f7O34tzA5bZkzB3a21n9RNKjfrszxG0ePGVD5NpAKKXHRKUg1D
# DATA mOtYqOqtVgJd3zEdE1hRhX9ah0NMFoQJVnvgD8/JNYGOWi2QYlqtUGY9HsfoyCH2H36urI6PpgBjuI2/qExbYCFtCRmo02oVjTch
# DATA P1mrza8UtIsjOm9uowacgYbxm7ifDUeTReWyKS033srMk7ZzPARk4xqBHKN4qJ0mHWQDhEmXQadiKsoSCRPLytCSZuYwZBxkZiFS
# DATA nhffTPu93z6I+hm/o5ktuwnwBk2vANWmGb8zem9GCcal5E5wMCuXxT9QWuqfIFQVD9No2mMb65KLLrmLbr71J3AX35lSvhtyK6G9
# DATA rWCrIVcI0IpOqiAaqtihsDoOaCHNvIFvkXkDP4oJ40+4OvwZV4I/46xLdHR/u0RBJs4kAO+7TXHwE37mmeZvPKvZjSSo04J0syFc
# DATA 3aZzNcA7QleL2Jq6rmIFHVbltGVXZu6xjBo1/gQ+xK+9rl4bHyo96aXdqooLf/H9v+//ff/v+3/f//v+31X/+9/toMZXAFAPAA==
# END_REMNACUST_HELPERS_V1
REMNACUST_INSTALLER_PAYLOAD_V1
if [[ $EUID == 0 ]]; then
    bash "$directory/installer.sh" "$@"
else
    sudo bash "$directory/installer.sh" "$@"
fi
