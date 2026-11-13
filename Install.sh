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
HELPER_BUNDLE_SHA256='21b3ed0fce6bc2d90848d0b1b4d7b34c9c940f248dc4efcd701c4d17e7ade712'
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
    panel_ipv6_candidate "$WORK/compose.after.json"
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
# DATA H4sIAAAAAAAC/+y9a3MjyXUgqs/1K2oohQHMgGi8QbBFjTls9gwtNtkm2TMac2hsoapAlhpAwSiAbKrNCNvavfdGeOP6F+x9xP0D
# DATA ste61not6S90/6M9r3wVCiR7ZI1j12pbQwCVlXny5MnzzpOHB3v7R6f73/t9/qvDv267TX/hn/u3UW82ml31m/ze7XXa3/Pr3/sO
# DATA /i2zRTCHIb/37/Pf50ev/N3nz/dPjv3P94/2T3YP/ZevPjs82PMPmTK8L+N5lqRTv1X1+/6fBNNlML/1m/Vmx/P20tntPLm8Wvjl
# DATA vQr95p/Ek2lwE1zH/g+vFotZtv3kyWWyuFoOa2E6eTJXT3/k7V/H89t0GvtJ5s/i+SRZLOLIX6R+CJ36wTTyoyRbzJPhchH70HYY
# DATA LJIJPkzizEtH/uIKXhwnYTzNYj9Kw+Ukni6qPjT3w6tgeplML/1kgb1P04UfjMfpTRzVPM+Xfy/ncTAZjmPPO7uKfULDaBTPU//z
# DATA eBrPg7H/cjmE7v1DGQI6CvzRPI6rBOE4Hi308KN07mXpaHETzGMCPV1cxXP/dTKNMh9gvUnnr7Oqn83iMBklIQBz60dxllxOecrQ
# DATA yXIee2GaAiZgnoDtG0AazDGGwSaT5TRZ3PrJlH8IYETodBovsF8/i+eAHl+NX+MJCWgZwuZP0mzhFwA4mwfhAuFhCH18quDyAK5F
# DATA 8Bqa3wS3/m26nNPso3SCEGdXqidCdkyQUSc13//sFqCeLuZBtqh6+GIxSnm8ZLqIpxHj4RJoK4DvcX48b2U8wCFSBVImoTiAyaSX
# DATA 82CyuQkdTRBwxCmSABBdkEAr7M4sE+IFO0kWmb8EHGaAuK+uYsB8jAsVvMZe8RWNuCo+wlfnMRDKHAkMhhIgq0hm3mwOUwMMHD8w
# DATA aXvxDayLq2CBM/eucP8gRi2MW7uBN8EKfH5Z8DO/ZJKEHiZ+MsIugZ6yq0pVDwFzCOPkGl9ezkPsMgKimgNxTf3LeEE7h170bmBB
# DATA 4Kv1KraxVl0PD68DIn2ALWTosJMp0OmNR3DKAsFGQDh1d6+n6Y3uN0qxzwx7BvzimjyLr+Mx7ouMX8Eh7qMpGGURhwumIGJOmceb
# DATA 6QbIdhEDS/LLjYofZLDoC9rLzMLSqTMdhrLcrMBMYLk9hJB4jmIIN1dJeOVfAhIzAn8cXwI4xMoyYpjCy6rW0nnQ5xPakFEyunXG
# DATA g6nuwl6GjRMhgx3C9EaAQEBjBOQ2jZDckF6JVkuaMhJGi5dMYOLXMTLBDEgqwo0F7RfxfBowA9VbBUeVtajiKsP3W0/Rw00CtDkD
# DATA 3hjhSMBPAaIJkP11kIwDYJe0b5h7RNbKpF4yDdP5LAX2hRvgRTC9tRus0Cr+7yoO5rD5YRsAWrwYOljOg0v4OmTUzONsOV7gxC3O
# DATA CJ1/AawcJlTNcUSztwHyCNfTZZFZlReQuwUk3fojmBWvE85xmC4XNS0O1sgBllWI49e0JLyWCQwoOKbJjOMFAU645g6CELZFhpsC
# DATA 2yi2jaQJw/o4IYBsHAcZS67Ms7fmIrW6qn2AzNKcxhE+sF4sc4h4CJHZEqgZMUlois20bDCYGjJDDp4ApqUULM8Bsty/WCaAZ3rG
# DATA S4dkg2w6J7YAEiTcJFLMxGJHIxcQhd/5cjoV3M4VZjzaFvwKMAnuHGA5wzZAskDJsgxLlp6r61aFdfECaQY44vVKkOa5u6ps9tU1
# DATA FSQw8N59wOMun/rpOIKpi4gGfQLWBGUBtL9/PZGyaOTsincJNwfBFGSOTAG40skM2/lZMoGlmvuXaTDOCCNAFUkGMwXI4G1gGAYS
# DATA UpU0omUOCqaXh6xeyferIPOYYHEDI5tf/6IwS7V34DUaEVdxCcIfRZXR5oS8gQmFCUoCeClj0Q+8MVkQG0MuhMwVerD4q9p9jPWQ
# DATA NalRirofdrp/8uLU3z165u8dHz07ODs4Pjr1vHrNfwacdsodQ7ONM4vLb7CwpyVWs2up+T24AbE3rSNvADvOQNzHAcCvxc7mOAHx
# DATA Pw5uRLwFsxntz5wK6SkVEncpLHYWTxJExzLEjTUJstcCegyKLbF2G3JkxnpE4uK0BQXfEa8BMUdPQe77+wEMJU1Y/Y0i2NK02pm/
# DATA ASJvA1ptyAtxtkGo38BVAxUAxNAGsdghSqIogR2+hPmjkpDOL4Np8rNAIfws9TdYIEIXDBkjSRkDozkIOlTXomBGqjx+mYHsUAuB
# DATA 73go74ChZ1fEI4gBsehQAt6I5qpgFzDOEkSYOfKFqRe/Aa2Y3mMGYskhAg5QITs2EMCtDb4hMHkg28YJMnh8BYHnTxvDgIXTBg1s
# DATA tyINYCMEKT6HFvjLhiAiTgRcEG1TPaIstNU59e2JIiOPBcHAZGfBJQjnVRxHRCCkcLHZASKKxYIIJ8/G3E26HEestKLWEwGbDxdA
# DATA sgCF0l4S+DpOlLYACzPClSDdREgNqRz2J7Yw6wOboOrHb8IYFjl+E4fLhdhwuKs9ZGigQSH5iPrE4hdU7uuAlWJcr5cyTyQCUEnG
# DATA S2CLmlN4Dqco02RTI4NttgG6spLwWvURUcO8n/VDFJyoO4DqAgYPaeW0VGhXXQNLQVmZgd0wHss6AIau4zyh4/7EnY60M7MmQBwh
# DATA nuLg0rGHZI+9KsMhnWtVns0CVL5isavIvFPGZECqI/Q5T5eXV8D/NUZFJPN6gwzwwXSbZqNYJDYrsWJIM/yAF5ZkepTrmLunH0YB
# DATA yHDA9Wwc3AKr2J3hpOYJLtMhaclHKZidwDKU+hC/WSBx0HzJapCFC3i8KfITwjd0NEmm8A1I7Doh6eyN4mChzSdU7fXIsLsDa2xD
# DATA alMaX6v43gIWiAW74ChYiHpB0wb5OkfD9JbkjuI4flmIVejCnoS8kIi9JypOpCwwxVYzYpGMU+qD+jXsWAkShvQKDCWUQwmIWl4W
# DATA XzlCDNs+GKHdZ60DyNGMrIIAhs2IZ9IkUWULSLrAOs+IGRv5EniwW5dVNqsZ47AwaE4yc6GeJnG8yHj8cA5P56zgNGr+Katxe6AJ
# DATA iTTfsDS7DTa+HTbEAh/tauBs8Hji8HZyYvB2tDcpbYNkgWLoePjTmLg2dm921TSdbopapjoNLGZ7ugiQYUX+gUKXedlCIe9DZsIJ
# DATA PQObMAmTYOxlqocIlQjWygLckuklyDhUn6VB5g/TCPZRumq36IEypaUzDhD7uN3DJSpwYrJNEAljsL6XYCqhzhqLAZiR7Qb7gqyf
# DATA YJJCO8sCw0kTPxW2orpQ63N6m+H6HibDeYCMbIOloXBiozTI3tQiQ2Spp2UptUISAqUvHcdC8eWggqiTtyOFgiksCvADWRvgbuHr
# DATA 4JIZ+4vgp4CCPWBS6VS79liPFF5kVAAYgJp7VnPa28MKK+9A5VPWq5idKjNAAyz+NkDkyri45YHMQJ9mERb4q2RDy8XAgQah24oc
# DATA ylaEiDIgSH4YkwfxANS8623koNgQosGtlsKgbwAuIVTYGNgUNTNgOIDMUL3klV+D+R+PkbFPI2AeGa0xowZUUZByCgfKOhRjDVeA
# DATA G3vlBMngtoJSmCfIDNulCrDJsiprIjh8Mo7nTIds34GealyE3A72kNmyvNeAASzMe9gnbm6hz70UWEM2S9kTwgzGYSSJ2yORlKBo
# DATA PPbyxuU0jpXTkVT3RYwYhs06HgvpjBhKM1NizhUCi8xaazByaKW2W4cnyuRO2AQOOVuQp4R8o+kYmqVo02lNwfFsLEAti5nM1Y5T
# DATA 3ZYyL79ZCaU8kfHmbDmfYc+LNGWFWx6gTWvcOOgMVR45RbnKdWIpmYBVoAhEJpvcLsi4Jz3zsrspGVqY1XMkzzcBboqqX7SOnhb4
# DATA lvqgjTJ/lIxJj8rSEOV4xJtVVpMfirtT0M7+xTi/tdhrHYHwErRxmOF2GkzYL+KNk+lr5NnLoUaN0gW07r/Wiy9Oj6qnhOgQffaL
# DATA ZIK6RxQsAuUlEcOUTFgmhRFYqGApLW7ieMpI9mwYLI89YDdz0MvbowirROMOBWk1X3lS55mHXtd5rDaBHywXKQAs02PLa3VkZziP
# DATA h7sPEneb5jmedmJmwUTPqlnzPwsy4EgvtfGBxuIuWH/s1fUvKVYQFahLRIzqsVLZ0I+AMmbF4/tS+UIRzRSSgBlcp2yeKM2N6WmB
# DATA 5OdZfghsPokXyq+ixo/foH2ToJYagKaADgzyRy+n42SSYB+un1jxlFXrTkxQME9AV+f1UP4vtImMrUhmqXwn/6kFDsk+9vRKT+zL
# DATA mpKfkQQKCjr4kC2SBdgErHmbzvPzAzE9TW/ABL5k5/fckzVBP2+QcCBAO4pxX1wHY5bKmUHp8Na1/mB5vwaTElVitG2qhBbR+tl4
# DATA dYDKTAwBTFgMv7Aire1W22EE4m6MGlEgK6FCdwThDfqZJEyEfgQgGQrjKGhEQc8NLj6aTFNYliLBMPfFEOVVcC1+ygkba67uCtbD
# DATA eJnBMozZrgC4iI8rfyhFX5DTAT9MxsxvsZ3xfyIzFseQRacqTIMewFvChafoP8sbDLgdtUlHrhXkVvOEdTKRC4xhT8w/Ylh63Ygy
# DATA SNpcLbVT3AEyt2ieTNWfLDMUcrgyNiZgQ9ACDeOrYDyqyu6mn9jXkKCblr2BCEqVtjHNjaYOiLhKhuTCALTThlGGPHvBOHTmUY96
# DATA GnFkJg6Uk4k/OiGfPK/XVTJjwQNv1jD2rbAmLg3onck9TObhcoJ6P2r0TngbKQQ1dPF5xg6FEnOBeaO30vdPSUEUJ6kbxX6KnhYS
# DATA IY26h4RFUQVAOAbesmB+C+C1ashBMBKG77/ioBEb3ye8VZ8janZBPm3uEcDXqD5Cn4e0EY9SZ9lQdAJxDFEug2YbaTGPGtJoFLMH
# DATA AIa7mqbj9BLFB1iQAYUYDH4stw9sd3+0HIP0HhPFwGQvZV9IezR8QOlqNJTQ+erg5bHFMBZzsPuhzwiMVw73NOv+M0DBZAivN/r9
# DATA Lu4mT/m/ycWqiEMRaYzuIEZR6CABhkQpruagg8O8sYgbuByyylHWANGAU5VoICwXWQ9A9MMEJEd+EAdjvhrNd90iHJqxX0Vrj9HO
# DATA bBSU1HmYEKkIIy4QikS8KJtRbQU9NL81WQCyUy8Lx0EyoZlQgH4hgorEl2/SFADBjrPdNqnIBmQNHH6Op8hVyWAEVo6qtq3Qki5S
# DATA 5W1O3DSZM43Bbi0JMmVmGpsrS+YVYxPWrl3zzX79UiWT7LHDzEgdWdlctomalEjkUuYoMCxQdPw04WgaIg62SbKcFLPmaTYDsz5d
# DATA ZmPKdfEsNxX8IjEepOkYvfCSEnOvM+up9zqOZ7ha6L3Gzcq/M2PRSp+rJqHCM7310EuiFJJrHXGJxE7HYNJcKd3CeHomUMFkFN0D
# DATA gOAvGIKFGnL0DdCjfGpPCYxL2jhgqJn4wRofF7RKlafa9XPrZeQUCByEEjKQoqapfEbxY5BqLwmqDp7aAtgPBf5h981mKTK7uXED
# DATA SpIBh5dQtR3FqP92bDJ7oTQ50YElj6qA3mzv/YpSKrpF3u2lrepEtELnJfGuKJeXTa+KMcSeVgjUoraLaFWCVrEEXkaSn2EE17bn
# DATA BRVSUtmfh2I9BETdWq7DQlIkNAuSvEQ8NkAH7P7B0OI15p5EmFHgecNvNQZlgJkwZZGpwHvAlsRM+dxWcOP1lAosVh55ggT6TLIV
# DATA zAM0chRScbE21myNDZhYWGE9E+ektFJi/sDW5tqitfxpq9E6ifGhLxDa+Byjh9GA5tMsizMVlA1MVMt6+QZkMHu7MVDOG7tq77Kc
# DATA 6NY8wANEEcqA2RIxVRU/IEhtYSDGleRbkS1ZhWW5DObRGCPoqC2jd/sKtwM6zMkRGEd5w4Mj8NM0Zz/ZeFNWplHIboJb9h5aXhVQ
# DATA 88EkSZC4WL5aHUrKFGVhZTEAy1xZWHzETqmo4h9Ywu4qyO4JhgBmiOewzsvhCW9tWOQp4kL8QI7oyY9ie46J3NkOUiP4a0dgScvR
# DATA Bu0lIBOFtGbSyslDzs48LdtdnYepg3Gs8CRRsSieYVbfdKEC166TiBN8QLuecuiGFB0nQclRTIgruz0AYEPyt6uIpXK6sHowwWgH
# DATA SgHtN6+iYYcmKYaJr9PxciJ5INkixawjfOaEB5X4tsK9U28juLxEssU4aqIgNSiiyS8yJ3NJiWmB3FPuTValSDByFgkA4Cg66Ur/
# DATA JUlV9IYxbHZEifimTIRdjFM2OTAcNCXTqmj5KGIO/69mZDyOYbDkFDyz8ZDD2BLfRCONfFcdAeV0bUl4BOqFCMHnsDSFEtB1ZRS4
# DATA crXcYlbjGbmVAY9FxHfWii8rwDaBbQh0s4kZbsTNCv1VucHyKgjT0jQ24hBYjAjCPT1WzsFNohyME5AZpFdRcO3qNiNdlaX5wisb
# DATA j7H1tIAuK1VJ8gmmic6Y84qdb8kb1isCP1rO2auleubOvBD4UjrhyD3RJ3lLVTodcRnO+GRB/G82x8C7maMlPWXdrOoTD2cdDKQn
# DATA CHncD5hoeBsHc3acWk0yz/IBKfVuxvKGCBmMd8KEpfaxc4cdCwQ+CH0MqWDkQIw9JXdF2Kq0NwszEjukvFPPKLX3eUtZJtuLwMkH
# DATA DIVoN2tdftXi9fYYsf6j17uq4pCkO4PcnaQcaRcvDWyjLJ1KIgcHl9VYaMfYkYMk84ynSSulRDGYZWtS6UQxX0fNqOyupBEGqP+J
# DATA 4s86ldCoxRlda85eHsmPsBbGpTOEys5SLAJMaVUq55aMwUy5bNgFm4ZhkJG+xGYfhqcxJoDGO/5GWpKnvLVWmnZUDDLLPL0ZtK3m
# DATA ydOhUtW6Q9ZY1mzcodg6tCV5HQTNHN8grzdoFID+8iVa/rRVmDIY5xVW8Bhbxt/rJkgWL6jYKuz7D25Vgor5kQemFfZGyzn72Hil
# DATA 2UWrNRhRwX3LhnyQnnLWpIUWSqbgYC1BQKG7WQHby1bosbqWTDzJiePtqTMwhYzL7Fnh/Uw8ClFsvCG3FY/zW5k5ZTaqJcnJ8hZb
# DATA 8pBNWjRAkqkXAqO0vKkg80H/0oLdmlkWUI83KtF2lHBgzVuzAU4chf7GZOKCQptRqkjxq1WhdYRQuQLtkzG2LedmogMrVyzdRHQz
# DATA pFCOw2aOXYaaR7x2FyzJfzaL4/nmIt3Ev5wIpVPfFDbpLEAyZeuag2MxpVgwngpiw0XxMtdXNsfkauaMI2LoshwSu9UJx7QLxMEh
# DATA Fqq1zSM5RYC6OPF9IBLLLWeBhRo5uu1t10AiMQmcovYpFG8aJHknCA28S2/DoQ7oRm58YYWJ6UQcdFCjlYOybYMAsSQmZc1lywkr
# DATA 89REGRQ608db4JkvmjMsBZmkaPvEsGfspBHMNrFlnmoMci6YgDSseikSKzwHCzZSwZzMSCkVQdWBXxKcY+7NnIEgHy0a4LDJMfsP
# DATA E+ZQGYf3UKNMprKvOFlQTYtZSX6yVS9Kl8PFaDnm/Hzji4eFScfXjOVRcM0p9qQRBMQcn+dyiLT2oMUKZStZSUZoXlT9DQdRTiax
# DATA t7idkb6WcgYZEJdOpQHiDMcBb34Fu+8a+SqKupQzfHF+cJ8nQRsjoDNvJukk19QDI3ipoOQlit+gc5ukExHzjD3kADgdZpGTLwgY
# DATA Ztlola4Q7TnI1WJZfZA5jttvEVDmjWdkOQrjaIkaLaMKPax6AAZ3OaWuSYbjLzCepOqRZ560AKQxcvuxsymW5D3rFA/NxfM2Djh3
# DATA hc3QA+JN9FmlyNgbzMqPm8Ck0iirImWEcYTu8irmAFylc8nQ9l/Ht4xcZnWJ6VuxVkKwJM+Qqc45M6unH7ICH4LKR3MARO7jFRyt
# DATA oUNl2Xr9K3bAQ2+Lly0xVS/OCxMJvoGNvkRWsJwSBxXV1Dm5wQzLUxwST7SlnLoHy4XBB2YC7IrheXF6CoX6hjEZ026UBOlmiKke
# DATA eFALVu9g5ASWpitM0nZcKmYv1hYOxoEuOy9lJIfx2ASzcWuyYyxtPAyXaC1lng7rsegL1FDWLpTciZHtW8QuDV16zlpicofkE1ty
# DATA TatokmE0ixdLPOSq9EqPrVZK2igXOgpdCDNSCeEbaLE/k0TbNRofz9v1BiukkoNuGNt2pyen0dbtMDzwulyoo2XGB6y9KeQ38RI8
# DATA sctCDdd6mnJI1NLt4O0FHVTlYAkqcbf2zspRpBySYu3ZwTilrumEK9tF6RHVSYcsN06OX1QkdceG3rJ41k18NUMt8HJdqB1md6cM
# DATA a9QMKQlbRVWInJczdMlyloDERWi/mi2jsTC3JqJPDApVVYWQvBXkaFpOHuoURYQ2XwJPafiiwEcxOSVuruLpSoAGmVQ8HumUAhXk
# DATA i5CPxZwURHLKHI+ztDQ1EMBynaRjRAdPbjnmlDVk1os0xOy+kYhhk1UWhPM0y+yOKFnhnn3AHGHtKiutl5xediywcOPwKRx6Wfso
# DATA 1JE6Tx3TB7zRWWWJLvi5fNn1ybJePnVM7E4aXVl/wJ6JF6IKCNrIDQIMaAI5RhSxnGJwgQLR6ASUVACxngBXvZq/a+IaZzE7LDes
# DATA 30yoAA89zWM7/QSpW/KEV9yHOuIyvFU5KXyCgI+0Ua7dNOYDLvNYCTsTmKp5xUDIyTGJ3UiURqUQcBRJBRBIdQQuwNkTfJQLc6XY
# DATA 3gZVmY+O2EnatlPJyUvwlCDlkA372VbO92BeFxnSQSHsHnuVVXa2nT2qo5nsfsMnsvdIfTeRGU8x8lSdz+W+OehTgAVVEeASFRFO
# DATA 2vdWUiUwgYwFj5p28QzWpIawK6koSQQnEcgBdT54AWxzkkriSPEgKsYbLOQ4DrI3ctFgkJuR5pHDv7yGRgR1yq9l8lUlEpPeCBjw
# DATA HhptYDmhNc4Wx42aYC7DuVYxSXLkJPHWgI8cQphhVeKr4uEgG8mN9riZZxSGU6UJyONamAVhRqPspQUuIZ29UKlfquRFiueGFLe1
# DATA iZsPmUgSGOZ0AJwF4Ok1pMx4UZWNCDIQXdExX0o2o4VTfVfuZRJuug494sDCM0nKIctRJSJgzAjjSHQoJFFKg/YrqRTeonB/5jc6
# DATA xDwb3fzYT1GfREf/iT5GSabJ/FoLKnNQxXIBc/hKp32AhUboAWrXrv1MK/wm326ufIAr8UpP4pUqoslo5hAX6hYBG9LJgiEOK7jF
# DATA dYYX0IO2qRwJCyt2mUy10WooEzoxJ0f5WZEJQzabhn+I50fnr4lfehY2bugIWmZ5+bRThQEIdAkTBj+qwALIYspZNHZSkPjDhVX+
# DATA CKr/Ekz4Awe/07mFcW1rKyB5gLiCCXJjRhoGMJCIchljczBJcDqcoSdmBLnrJ0BD+JRHrpqmbB6KPke4yHi8kU1BGBSeTJ1UMQM5
# DATA ZQfYoAcLzyD41s1uQB6bOdPzy+pUaG6pgCdWeCdxRRryGOBRguVExC6BYWnbOTUSNQbK5zNtROpxEkxhn/pQLCg2KeVfeyycCics
# DATA We3Mn3KpWPkMC5K06EgAjQw50oY4xD2dykhKCc5Y9hTa+iriorNGjWtbiUQ3jS2iPDYxUZRMTjhFnG2UQLZ5UbqNJVbXZm4FbNop
# DATA FRF0xtWJGFYr8pFRH9MZKdQoVuo/afg83aFvdUj6QFERAj6K4eTz2gqbJbeLRIIhQ3fmVqjaPvVpVaty49WUslUANdpZlH2dLWGL
# DATA XUvCyjr4jT+BgGXVNC1wu6zT5Wm2HqnUJNN1OplOybKP3lQphQIQQPgXB8AK2bq1DXgzyOtk6AkxYbQuJHryVoIOjnIrWvnuSgKS
# DATA tXfS/G6qKiVIUq0lpGoOhlrJPkpP0qUxkMMtlMps1PanHlvrSJ52pEEmKxY/iAKAdqtG5kQyZb+ByYKgc1P6jIOpD5RbMzluTOOj
# DATA WMtA9dUUtJrahvYrKpQwD2BM1kkHNsb1aJ6MxtXSrtNELELKC3PPAy0E/Ngur2SX8FA73Y7xEwtZWHVGVo/uxOwHQfdTAM9mVw67
# DATA aqCD4gsrJYpUbczo4zJgZCQXqnQL0Vvnni7VxnFNy5WcV9h88uOQF4AN1YqnlUYO0ornlpxeYFiMC/U+5wwQ2OyjZOqi0D2IYs6r
# DATA Ir0GfMS9anKMpHNPOsfCRbStceOMJFbIbQ06gAlRcQJLJyHPL5Yp40Ot3bofkZYyWsg60AkCIc8XYIWmhHPnyMyjUOhZKLRmtDIh
# DATA 9QbNI4kzaybewzORik4JawOjZI75H8kk1oaDEWjCYaDrtfSiznyyhlkxNpeXB9ekyodLCfmZXjV2WzZ2PcmXAHBm2sRloND9ZvgC
# DATA PlvZXa6zRTvezH5EfOnthc5ZqROBGhNZUBoRKg1CD0DTxLms7mOWszY01Bf5zPTYkaQyLOyFtta/ah3R8v8CdCWyIFNdtwIrBznl
# DATA ClXk32iATi4u6i+e16+Rd25Gx2wwr1FUTQnsfcFnr5wUf5U7aIctgpBLOOTORIFg5LQPBSRaBngazU4Ssc7o7U5D4JYBJyTr+h2r
# DATA KXfkaSd1WOIDgQo9AUwqO/6BQLRngSXwYBEhYu2aMpRxH2gcWceLUZmgKKZTBsdOs0X+zHvRTbQtkhucPZ07LBjLOWG2+LgAjLXr
# DATA hYnLqbKCRXBrd6HDTNd84SNyjOSVY5BMbKJHiJgyOFjZ8Vz+hpJdUSveVdJOGoji/Cy9AVrGgqFAZCq1BF6hEkma36w5F+RGOxx5
# DATA qrhTZqmyqzaiNhqqclS0qvUD9gXLinDhERozW3KIgHQtB6nuPkCXsBRRwZCBOqLDZwcTwtjw1j2NY+mLpsrV7tTfQB8bmkcmKrPB
# DATA mr0dp9GRIB6FDxNy2SW7LBSrWyayihtlTDZWzPmmYAyqNpTfxYrGah+TeH7JNGPXnCKutm6jclY0Z/CqPKipvzo7Senm0A0hGgSF
# DATA PVdkvdYC24yDcz4wNVU3wGwZ3JyGi6tceo6BcPj7toSH2OKITvqx44QCj2AtAGuO2BBYjiOPPGVGvcJQZZIuKfWeNSxQlcdLhEtO
# DATA 0+XPCqwNn9lT0MS6BiZUYLz8c0piX+SqjcrhNC3e49EIE5xySrLY08hxCgylTEXD5DicjkfmDoyjkKdT2evUZqdggZh+nj2+2a1Y
# DATA D3ie3gZjiV+lVnoanzUysHgPHlw3eoWeMdZAwN2NKV1MrW4CLYV7Nvm4Hq8+ZW/SdwrG4MHHJbpBMKh1qUx1z1LLpbFh1JGJUFRZ
# DATA GgFL4SyWqskUpKrHwZg3ImJmrj1XdmkyHMekIdHZiUaj5r+ksTNV9GzKHsJ0vqGSYHIKIu4m7W2lPPiigzCuYLZKoznVS9RjGIkO
# DATA XbGw8WSnLTNTGc8k/6uEAQET9qENtS7/JqcmnHamNIuNcIkdIV9zfvZA2MSRVR1ibDuXdcdVkz40xjgWFqwUtQbWBUUnK/Xq16qS
# DATA D1i+jQJ11lqTcg2q2xRVW31c2VtNKh7lyYIcf3yGV4JVeZRUPfS6iPqnIsU81bUgUTiIylDlVCO164sOnRaMzXvZs92mNCFTXKQq
# DATA y5iON0zZMZPmoJyknixRpk5l0wErKr6DSGOXXEZNdCqp4w6gIIAjM/f5EKKB2VK6AvJc6GPxWHVvPo6wvpPmNptcwcUxrC2G75Lg
# DATA GgpEhcLjUguUH4UrKRucM8Jpd/PWNkVIuFrCPWoIjy7TXkcW6KZSpxQxR5pZB9WJViKKfEsb7hSZPUxvlQvEg6ax+J44FJ4s2Lcm
# DATA Z6gwUJ+KocIFTikTiEo8kBVLocyyLnw2VT2vaL5UK928w+Ndx9OADx9SmfKleOy5hV35sIJMJvU3aJU3JHU75xjhRAPWKHR5RqkP
# DATA zpnea2a7Mi9FGPZRa+p3Ndsop65iYQ+Amc67jVnfnq4Ayiey1qaH2iqCKl3gpu2SO9/TFbKpNjTmLqqTu9GDR3B0nnjgmZK9epDc
# DATA 8QAtmCni7xb3ZUeCt9AhTnR8Wumn6jDUmrnCHNCjmJrEZJMsikG6SzYyYqxTyfYIpYYIiqwy33S6wyUHNoaTzPa16Apa5ZYeoWrz
# DATA Iu8RvGg1rE8h/UjohLbE2DaRtP1jUuux6t6P88Siyudp/4tER3S5GKksiiJBmfo50vKlMoeVNOytuK6l4CbrXMqzwoDxIbmic4Se
# DATA +ybLHW2c2qkXCR5dBAHDSdSsqajApScdmDNm4l9B3ZXJYZzE17FJiqA9hwWo59ky4MQoVpNhktPYKdGJQnXsprZhAIqXmfmadVrd
# DATA NoXJUsMszqWyraCF2LzVFSOZjlpT9K+IB5E6YOfnxpmYqkUlXbRapovdqHxbDZsSFZ4OVOBcVc052zJasZ2nBTRCCfgMPkoDx0XN
# DATA hCzOHSwWZc6CuEOwukeOboon6+P3pKLu5tECA21gXYx5QsIknd/SCdCiQm0cfeOSczA3K5OHM7Orug5JljdXWJfOTIkpUxGANQJj
# DATA 2ORShbTOYtKB3JTQ9VaHVenIlHjNG8TisSGV1Ri9KJIMcerQnpXUKBE+T2JIQ9QbJZHTHPkjf5i6d4EBNAkgJABnwe2Eco5SEy6Q
# DATA EZy6CVIyRflQpVTdLSfGC0vJVYqzx8v3zTpZVRXR1mzaOFeZiyh/3MreUM7VKh33scknz+ypQuYqT3BPrTnsTCeySipNmfPYklhu
# DATA gBDrPM1UbeAKCw4MMgAcdPyPEy2nUdHQeoNKnnkmSoc6jpwpfkgx14LtK4EShC0mj0DEVQmEQA1T8/QhSxcnWNde6LZq/OrNLf9F
# DATA MIfVatbrPc72udKlTS3nnj4nQYXN5ksduxPj2UqeIXMY0xATqg8oxqS56WKkXTJONWtJHwG+phXjYezmL2rHuh2/VNOkUkuNZs0/
# DATA Sv3TJWgX1BDW+pgqi5X853zNB2ttubpz7IyIpGKWX1b2IJVVW1LFEg5VWDqjAbSisskwhSFKQp0Sr4YoCqbdqkprgEQUsjiu9gGt
# DATA f1eHEdDjY7MYV7BnqRzgVwe4smSyHC+CacyFcjhjbqVSlOMAUOU81Lks9EnQ1M1rIlZWPO+2o0cABO4eUMGOvFNIcUNELTnqTJRb
# DATA nV+jKDppuGDBY9kPZbmR4qMPMmo9x9qt8Bawlokl6r1cQqScD5Grmdjnp9E2TEnrS53LExwsaZObQgmjOW5fzpFUGWPuoS1TY6fR
# DATA quEdXynM70h07ANTafwp5lobrXP9NSrfNkdP8G7SED2NFKKOlRMjnMZgVQ1n61bfpOPpchpW9fs5TXBszqKuFkun7D8aUkby9JlM
# DATA stWs8usVOtFBD/kiLyt+s66YphZgah6s3ClPt3PtSOEx04ePSRsLitQ9XchaH4IPQEbp8l1yqjTQRS30KW65vkgKtRQCw4zYrmO7
# DATA /ty7RF/tg+364g3PunhjzRUpKqHIuo4ocjRvzvhQHgfta/i2BKkNnXxBmulrkZZYpmQlRqY0JeceDsljLrxnZN0NP3zGkM0GzxRF
# DATA MWVw7eoXuZss5MhUcY46ZX/Y5zec8h+UE6bPVa4WbFGJ12au+tAFFS3QxVtIQ6dzv3bulNpTj0AB8qQ28iRYIXj5S+eiK8fhhnNF
# DATA eQrkJoUOnoMlF8lZscCUXZtLX3JZl3WzjfjxHnP3ErNzjA0iyuAv1XQEFNjdeYQA9B9IlUIsHDVL5ok+ji3pq+aSIsQsAstZpfhC
# DATA hMeG8BorT25ooSGAZkHTmIjOBvJtPtUhS0VhgB4uA0u6KdLFEuaP5KFaTJdYTVGnC3r6HIGk/ypjQ+eL8wvukb1ihHk5hG3I7scD
# DATA L8afzlqTqF4Ls98IGs6eJ/Zk+RDXXBkkLh2VjKcA9TSgc1WZzoHAdy5cWuRpyDM0tJpUqS1DRtetdbcSD68MigfJyWQghlepCoGp
# DATA vsjNqcH0isC0SJ11SRvMlcUE2nlzy/fxwZNI3XU3WmKxJi9/l9zDewF7kmMbVV1M5c1tKRPXnZtA6IbrDcrsNCIrEqTULMYL9a7e
# DATA UB4mo74c0tIqBV/PBBF7Kf45O+eWakJJ9rZnn/mwSrWDQLXfsNTTnJKOp9QlIT4tyJkifVTuplPSnyalLpokEged2SFPZH+dmj4c
# DATA wCT1lRwPQKb3xf7Jvn9w6h8d+1/tnpzsHp197T8/PvHhgf/y5Pjzk90XVf/smL7v/+Rs/+jMf7l/8uLg7Gz/mf/Z197uy5eHB3u7
# DATA nx3u+4e7X+G9UD/Z23955n/1xf6Rf4zdf3Vwuu+fnu3iCwdH/lcnB2cHR59Th3vHL78+Ofj8izPvi+PDZ/sndP3WExidXvRf7p6c
# DATA HeyfIhxfHjzbt2HyN3ZPAewN/6uDsy+OX51p4L3j59DJ1/6PD46eVf39A+po/ycvT/ZPTwEA6PvgBUC8Dw8PjvYOXz0DWKr+Z9DD
# DATA 0fGZf3gAM4NmZ8dVRI1qq3pHYKD/F/sne1/A193PDg4PAF94Z9jzg7MjGIJwt8uQ77063D3xXr46eXl8uo/CFFEInQDCTw5Of+zD
# DATA DASxf/pqV3cE2IU+Xuwe7e3jWNacPVgmnK7/9fErlBYw78NnDlIQUfv+s/3n+3tnB1/uV7ElDHP66sW+4Pv0DDr1dg8P/aP9PYB3
# DATA 9+Rr/3T/5MuDPcLDyf7L3YMTxNLe8ckJ9nJ8hCTUrfHRAx1QO1T57sgujpB69r9E2nh1dIhYONn/01cwT6QQ36UQ7Hv385N9QrJF
# DATA D95XBwAUrpwmCp+JokqvwANDFF8DeR37L46fHTzHJRGi2Ts++nL/61PPxgjg2JDr7mfHiJTPAJADggcgQAzhmj3bfbH7+f6pRRU4
# DATA pieXHlf905f7ewf4AZ4DLcLiHzKajk5hrris8IN04u/C+mIPSJi8ht4r2ARIfEeKaGBs/M0GtmzGXiVI//D4FKnPe7Z7tusTxPD3
# DATA s31sfbJ/BIii/bW7t/fqBPYatsA3AJrTV7D7Do54NXC+tL0PTp55aoMRzT7fPTh8dZInOhz5GFCIXRLxWSvBLU4rVQ8X3z94DkPt
# DATA fSHL5jvb+Gv/C1iKz/ah2e6zLw9oK8o4AOSB4ARmRz0IHpHyejU2IPHyD019pytHlIzUihxWp09CYbOxQ8LmyIYu3MJ52uKEGMai
# DATA /YxTLGjBh5e4qrLkxgvn5QNynGDuoXIY37AVtCRzj4wb1o6lp+BGHR7COqXjlM/84uGmN3QbROah33SYpWOskkBFo1n5QJU7uU7G
# DATA FuwFfjnH7FXJyM6ZMHMYxUWEOdae5QqR6ZQIrOoAYt4tbAvkR8tZeIPiF3wt1S5hgDP/ztSpg69Rih2BOir9Zzr8KFcTyc2RM/sO
# DATA Bq6kTTdOSXhNgLykQ6sZiOJUgnfLLHdIuCphtWzBxaQww/OKwjE6U1hCqsnCc6+kZSUnVveS88UY1rXL1u3TOjiZmbMIZ5JKWMWM
# DATA +0B8yUYvVafitF6vUkcPyCTKghFODOHVb0/0xaILOYJDGWfW6Qu+dAbjlaoG+/jWI2VKnOFW8Ue33jL1RF1kV+QMIqVaFdEjG2cj
# DATA NFdXjtmIxSsPZyn5NthJpQoejZa6qC3OZoTaJuDkh4hIeleVy7PmXsroJJl0O5wn8QgDb4GuHSWxldqPchfN/xCL+/3I939Ir6fq
# DATA FOaP0MRLMtU9wWEv8La+ZdpZ1mThO7cye8miOPj8GE03yB6viFeVSbJi8Jt8m7lXdo8KV1YtlNrqvM309E1bVxiIUoe0lNkJ2wdW
# DATA js11pWgh/1fK1lP7fmLuRznJDbsZeXl9CXC5Tl3yjbp0GsePM37kDnu6Nx1NXZUVaFOuTm93Ey0f7Ntz6r8ZLLIxBxSNWTGx/8Or
# DATA xWKWbT95cnNzU7ucLmvp/PKJygR68iM6wpeRIeBUoMFaL8wdKUjC15JTwX50Cc/TKZb0wgtOghkmNcHcdH6GVY8xDMxFiwwp33Z8
# DATA j5vS03c63hpEcSlv97r5ZKGkI8sQXTqGb/Xm7ExV8b7YCz63KQ/6iIcq1MFUjnfMmHud2FWtKhQH/oa6yotcZnxOLg6iTMPAMUZg
# DATA 4texp6NgkU4Q5yt4uKD8bWZ5w6W8pxSYo5uetClHkpcUDLUThvFiIVlP5ryuuoDpKdGAPn7QUoalDrDmi8x9nUM6opEwFQPi0lvM
# DATA LBFPtrkpQd3vF88rlFWHth9sTb5+jSKQWA2Kq6Epbmh0oQ2TTmFd7W7dCPJc5za49IlE71wvyZoM/iAWp95HdAM0YMJ7cDd87w//
# DATA /if5BzbIwd5+bRL9Hseow79uu01/4V/+b6PdaqjP8nuv2e59z69/FwhYonIFQ/47Xf/v+7sL5/J0fRTL807iyTTAWJCc0OajzlxE
# DATA lN2h43SxAN6L2dzTeCznwCKU05TtRj5w6uWGtMtpJDWuiJdstmr1TQxjPjVnXZSWzJfmUskJVmHkyg652bJGgYufzFlcvdaVs1BU
# DATA LWeSqvYChmjW6trbJ6fUsH9+H8ZG1RSUwQVdBmT6SG+mYJnv7R+hovIZKGyYg52Ow5OzPaV+E0pUmfvw1pTkU0BzEA1gNjktX509
# DATA f3n4VIIglBUJkh8Q92Sq7sC8nIsr+QyTUDY5CUWPgmYb3SShrqaiu3wQ02rRQPa8UvNnQLd9xawvQXNYDmuAxCdztSZPhkH4Gjqv
# DATA 3t8KFhITeh9qNqXCogVNfnJ2ePoEl2sT0SGxGDzfQ7diknMXS/Az2cihm3tHst/dpHfLW7V6rV5RqFYEVgP7KjP0RYu6t2+VX3BI
# DATA jmkgRtPl38n+x3spMYGqFv40+7fh/816p9dz+X+j3mx2/sD/v4t/Tz72T5ZUElAVNwerklMoiDWBvUe1ZI/5Akpd/+MqABM3w6K/
# DATA 6LsK8XgXHTAA1vrxE6+Efhk+l1V6SgnJC3+U+TtKTy6XkFVsj7JSRT0O57cz0D7zTfhn0+yt/3KeZJNgb8z1Wfibf2e/+ARM5Seg
# DATA xhI/GoBVj4XznvzxjJo+CelN02M0hHfL5Yq/8yP/refDP0zu5U/4j1vJDenQ9Igid2Ue+NMa9yph509r3PunNTBvkkW5VCtVzusX
# DATA /qef+vWK/6Mdv+d/anWN/4IomIHlsU1usPIj5yAvbc4uS5UaQ/LyslJ2exbgxXV4usC0tW1KEQaboBZPr2voYf5s93R/8OrkEItj
# DATA vNn2m9V7+jgDSyNdLl7gpX3Ztt+oD2C7gqEB4jH3qMWPnL7uqrB6YNbEk4BnC6OW14FTqWUxWn0vAzTAamBAlUv8bqmC6Cyxu6/k
# DATA 31XMKHf+NrF/uon9qf5ZHJpTckMa4inLmla45R3Y2QtQMgwS0ay+odf25/N0Xi49E2Ypp/LGqkQuVmPAaxlp69z69jxKqnfvrlJG
# DATA mqMCyXtXcfiaOpV85YyH8N/eeU+esHKiRBYHwCP/9E8PTWU+MO6pwETAuaR0FIRynLlSjq5tAp2pECurLfBSOgf96ZgK7pEDE8x5
# DATA rGWc4EU4VNqZ9zYJRFNf/in2hadjIry/1pcrtfxJIioLZ1pxGjTY5XK1jS6UUpPdZoZ5od7ETcVILzXrzW6932g06y0gn0E8DwbB
# DATA GO36gc6pHFAp+dK2tU4CCyE1W062/VKjX29FwXCrGYxao2aj22w16+3WVqdX77U69eZWd9TrNRpb4VY3HG4NW9FWI66HzX4n6EdB
# DATA XO8NS4am1MlZ1TsQ97lD1qV2GPWao2gU96K4U4fXg07Uj7thGDSaW81wq9ndGoVBdxj0+r32VlgfAkSdVj3u91ph1Il6JXeblMJR
# DATA 0On0wu5w2B/F7WgU9vvNKGhFva1GozFq9IJGP+o2olELJ9McbbVanV4TZrM1agbNIOhY/V3wx7uqd6fYXca3tu/g0YRljEzvT06P
# DATA j2oZsQeg3jL9XvXLg6p/TUxxcTuLsWyGv7Oz45eGSJaLEvCx69oiZa4CzHMbGqshkH7sAZiH10Ly3n8BD2ErXwXNTheYF9d7LTNU
# DATA PHalUouSyziDHX8Vv8ENpMozq3v34ugwBi0wU7DOggUOeH5RVQF0oKi7ipBIMvK5of9Hf6Qnw7DhhLiabgkffrQ7Bx21lmT0V6Ch
# DATA B9IBlbSYhtgD8AJ59tkS/UXwFn9Qk3AIFIE6zyEaoa5cAKhXhBKBo2L4Fnp0yoxSLF6KacHUpoYlufUwhTg5hyaAjfNarYbDVH3+
# DATA zoBohhePs/hRwPFY/JpwU37tqXdnrc4YVAOFNYN7B+UfIcp5mJL/l3/pf0Q/1yjCkX0Fqn659Aa2fWO7BFOToagJD87YGN5i+Zwd
# DATA XzCP5kJZ+kFDqNwFM6CEjLrbVvg0aNzJ0eMkCDU9Vh3xuPvy5eB0f+9k/0zTKQG3Cd3gBDavGyVNq844YTJDx35uqGcx/55cl0tB
# DATA nG3CiJuX4aREq1PlWdXAsgmI+kCwNpoV1S29CDJxsQtWy1lwWc61bjSrfnOr4q6R4AfTv4JF+Vw6kankOsCXq2ocKlZUrlxUzBYv
# DATA LRejLcTmnRdkt9NQ10z3s2kwy67SRVmxSrX4jAva2bhaYLlhRGdY+8FfLOP57Ulw82qKYa/yxun+4f7eGbccUFDn+cnxC9tTOWDZ
# DATA X5POvqKsFm7PT3aUQrDhLAQXSdwhIX4KOgS/X5sEs/KCeFvNDKqQZ227Gd5lDrR7fl4KokkyhaUiChjwN9xhJW2UDmB1MIcu060K
# DATA Hl1c2IwBtweBWINtVsbRQFskrpL7tXFRqVj6iNEfyiWAdDSWS4wxhh3eCsqN6mHwgQ4DI2/xH7nZQaaVkgjhhoWcLwbLJX/DhwgJ
# DATA fl7M058G04EqqYw/XWPoWTeGj/rhhZFBhCocoKhT9cIA2Qz+ME/Hsf02zi65HMC2pHJxoDgu8YzyKmblCc/YJgFLItg/J9MhRuJg
# DATA K9n0sUoC52EwxTgN3RGSxOMou7A4cYznmoHpEl4dns9vy4Ls+LoXFjpMPyBEbXICIcpfS/4n5oWnuS6V/DYUopuCZmwNtG01YTjw
# DATA uUDE6HrqUOJH1DVMgr7lICY6Ka0jQkqMw9qJ3Oqpzhx+KuRn4DenY+5hCSVhCSFe1Di9nydwm0Km8IMGZSuYPb7zg6Z/fILZK59h
# DATA mDJCPjeYpRml7xFBMhep8juVPPLVWDtaL/y0Zijk4lMNDIg2phb8pKdMjCcknahmTa0CDBevDeNHH8FWIRYdDYIFwsTSg75d1FSR
# DATA gnJYqbjLJ0PXMJ1fejID048B/hjYI9PaQk8PratWMgQDaF84VLqCqSTC9XXHX5250BZyBiRO/oT7AP7ke8woaBpjv6jXqC17jvUK
# DATA 4btM/6JykX8RJnav/PkPQmw/eKuGMOtU2ih9En4C/63UfpqCdlOqlip3TIobP3hLRHK38R9WZi8mFDIdxTY+uz2ILC6UYzOIfGAr
# DATA CGol5yEo2Iw5rljKv6J3tKvQQu81fvXTmvA/GA21MPNEP6iB1XcJSuAaypCxqZrPNFXsNLP114JpSjOZan7IomnoqUgjENiXCLLF
# DATA v4nDWY8fpGYM8i45Qh1rkODFIuBpfGusIIqcsVbfuPPWf7NQIRsJtYsi2epI04q1wSlFK72p4H/O+SfU01n5tn7LQcYUeS7aHLZL
# DATA oguj4a9SPnV1Ucl1Y2i5qCuRiqiQ7yvJuNLxeVjgY3Lpu0BxQqWIQaImKL3Ql4Yun7wFJJA7gzgTuctbZoaD4w4VTlLVTk6e9LY1
# DATA +TuX9RYKg4qjRpCKz7ZCkQKherDer/HwlSJ+IKuJVh2ZVNxx0f4RYqO8NeQ/ej1skVO87cTzOY6esyQzQs+GkpECM0dgEAEXT9dv
# DATA Yt2ZNu7wXG7xC9IghyjTA8uU8jkbuGT/XZDDwliaFrVq6OA/+MZF0c4t+I02HmPvYY4oMhKDKhrleUkJn0vb/JN0K4LFL+U3212O
# DATA Yu+KDfCcPYYh2rJtgCubNphfXp83ef8AtDGYDZdXi9Kq1jqxXXMP6mi6NUl0sCHFU4b7ZkqZcAMs+cGVrAYYcITvIkIH7NAemBE3
# DATA SqvC1Lgm0clTKD8TvIoQy1Ppjoq2DbaquYBUjKrqrRI/6yjUe82d59OVzj968ufnwebPdjf/rL7ZH1x88oMnNUxWJQOPpSx1YyFl
# DATA HSXh4UXMsFpY/tW8bDIjjmC4i7fd9p0akIZRq1BZPwjf2GI8uKFxoAJ1EthFOBFvmwlRSFDCoP6Jeh9p3fxey/5iXCrqUflzRlkt
# DATA fgOLnZ0CQbMLCng8/Iple56DtmH9njdgLJtrBF1Rl5+uuC+gJ6ppXn7yzfyb6ZNL2HTfrKBWsUxx+KreAJRz+lCFIfB/VmfS1Rw7
# DATA u2BRxyWwHun/lNY5zyfO8vyiYN01bMYcyC/6OkmAlXimRlSDIDm+mZaL3PJVJgGYdtHTc3x4UbgMGkweCym/AGB6WMv57nmf8KMV
# DATA z/uHTNaN39h0v5wyWPaNEZpEDen7nxT2SR76pz7iA40hZ8c4UCHpP9VhErdhWaPjvHGBMy6RKi3q6YoYWFUjSaHTi1KbLYGmCvbr
# DATA XYHGw+xc++xyNqTVqRJ2SnpkiyhdLmpYGB94/5fIO+hwtcWdV1lJxhO2ujXCDjHkbr7ioXTUTYssutcrjszL4speK+zUdB1ZVzia
# DATA BCLyWMoB+9B4HAgskKy6DusOh11mwTyLy3kOV0cvGfErCzk5kLSz9SH0vdRqCTlnqnKhJ7mcME0cA4h8VTTZkpQao7RunQywMnXe
# DATA WzlRoq+yYz8xKyI1CquWY4pvoq5JqEjHcY1+kgdWZMUKjn7qm9UnkpJQK1MVvVmbYIbrZYxOgzVtJSyrI6rGr1+1SJZp9FYdG9Y+
# DATA VXEZY4kWK80Bq9FgWZoaOrt00OBNstjDVK4dv/EUtMmaFP2X7ALUoTBjl+PpZVzcf/v8nxgTkjF2PBgHt0g2s9vvNv+n3ew0Orn8
# DATA n2aj3vpD/s93kv/50ZNlNn8yTKZP4um1P7tdXKXTlrexsfGCb6TzuRytoRM+iZ9ZBg0phOqgCBk1uG+epeFrrJ0Ee7IG3XmqjOj8
# DATA kpie+o7J7OrzaDpBXqG+/jTDW7T5c5pxSRMca5wMVVHSl/BVNZnrPrPbTH3EygvqMzoXPQ8eUkwUtAnghwtktsAFy9hTeTBAHjgY
# DATA oJ5IV2sD+wJoUTOr6GHwzo+JVFix8xCNEePruU0mAWZNUuJqFg+QOXmeF8VYR3c2iyMVwQarFnOpbirbympLMsUSVRuAUh5bViCC
# DATA ju8BO+TAL4jtMv4IPVYq2xfYlQp2++p3ulrUirvi2umXSGcH0UVsnlqtB2kMPHMVpnOZG+pD1tT4inS00xKJ6V6s7xkrUq32/BZk
# DATA 17Z/T/fkZXHGqOG3rFxxbGeeFi+EWhukiazMHsmVBdFBJCTXWhTHM/wgrSs6ZqTuQEuUeS6JS/wzBgbfglSg0QEkMz1pcF6CPUgk
# DATA WEJHlMyz4KE9bUCfeUIFRAQIWsDzC8davkbXVmy1YgD5Z4Tv/MICq2B1qKEsD4lK/oW7wUg/UA6niUyj0vaK0sqtz0ucjWTPMv/E
# DATA mqIzA9LNAf6yOMEp2prFIJoXWSkH+/f9U8EF3WCPVb7kzCEnW2RcEBgzioixZE8lszqKw3Ewt8o4DONxelNbceWqrBAHm+wFWUHk
# DATA /aROuCzpNaRH24UWCG/zUp5KnJ/zyBtReel0OXsM5pyJWWRMHayj4H+N2X3bmRmitjedoeliiB8i7FIU45IywBaRR5ijPh+ks4X0
# DATA 7U5E0bHd7OJcdVZA8Gsa5ifqeP2EdYHeDaIJlFY1r4S8tCJ2ytAZyWDsrDSj5d7cBH2UP/zFMonBIJJM1YpixZTBF2WrTP3CBgNF
# DATA c22cBhFyzILRAK94NAFG+hg6A+HJAOttGJXZayv5xGSXcK4gBrVwb+4cpdNYpjWSYvjUUk7Ey2sGznEAm5SnLw95vfaI2IUM6JdD
# DATA alkiMfj2ziYIFwQ+DkON+UWYao0nWROpUZOmzPXc17fzTiXyMhprDRkOOjQfN0INTwqCXjWIkjkuYKmyGkXxP35kXxI/5OAhdaYS
# DATA lqvF/Z5PsOgx98sHNvk1OZq7pGLnecy/wN9FqFxc2HgOppJdp7QS9umtU0v4qeglDnsiJOZ2oJDo2VyQLd+fg9WmZD6a0gMllcuo
# DATA lVX1raacyLzT2KpLvxGY5nRQaIfreE1S2COo+pYRJmlPLW+u6Ex+vtEPdRcW93F2KkOwbo/CJiLg3L1KREU1Q1Ev+dANSewPYMgr
# DATA CfAzapDSMVE1fufx+djMeFwOhRKw0oC9s06W0yl5sNiKXtPqizgYL67sX7DJEnckiqcjutyndEWtbmXFQ6IvgapwveVhnsy+BRCU
# DATA kjBV4z80/HAeB69NzjgufjYGBbHcFMYdYFnYL5FixV2yt3t0fHSwt3s4ONz9+vjV2eDo+Gxwsr/77OuSYpRy4HmwnGLRrPI8TRdV
# DATA c/zN5psWiyQ7DJURsD3kpdrlOB2W9Yu4hzY/LlVcMch3QdWwhgPZX2X4EmdhMIvNm0jq89LmN9HbRvsO/nxS4rTbGvuIZfRakg2y
# DATA 2wke5S5X+ALOhX4AjIt/vEcKVB5gmoIXPO0Bs/OfYJpn+Ho5y54AFeA1J5vsxSjBIw1e/m0x6WqT1wjSJI3inXraw5MM/CDbQd6B
# DATA AgnMm0H6mr5WHMKSjjhakdeDDJCqHXIyihqV1S8qOrKJjiw0TGv4nzbYm1fxm/PtLSt8TfMAuKzX82QiCp3QCRUAsbFqy1IwxXcF
# DATA PvaDS0KYqjNNN6/QzTGmUDLVRAFj79pSpMmmJ/rGheD1MFazJNopstthmLRc4p9J/8wf5CtpTcS8zqcKQHGlI0n4Gp6KWfO6pbms
# DATA 7LyDoy93Dw+eDfaOX7w8Pto/OpPRLO/GDvkUygQvcFC6yRk0rNKFhss0LiR39zER/X0gvTo63X2+P3i2//Lw+OsXa0Cy+syhGGuV
# DATA RgGHzyiuXcQJbJBgZQkmlAAF9kXZZQQl0Ry+qc3VYWDkAVt3Z/Df7t2fISf4pobCx+EHRYaLYhGS9uWX9oIoukUVpDaka/426f7O
# DATA zevZtFTUgb5kcoXPcAUN/hX7K1cubG3W4GhFqcV94VnCgnrBpYd9CFs/S34W+z/yt/yP/Ua92VZ/bAybzu9d5cP9z3f3vga6O3p+
# DATA 8Png7PgYWP/J5/sltVHUTsVYs1HqeRfoZ0lGALPMNr+LknOJd37MOT2OqPdCCwagYbzp2RBEWXFPfg3Iu1Kbk6gofcyrmRMR3IOD
# DATA 9pwQXkfYJ/ufH5yenXxtramBtYamEKgq4lMjBabMY1W4fcDnmzFvRSk+thvJdOXar+i0JEtBvEQUmmNfjMUxXpjgOtsCuUk5qiZ1
# DATA aXGwLH4u6nOhqc+AU7oY+xbpfZejwArwaQmzq3mK3/f3eAhzJ1UyFVToQM0iTWv+LjPuiGs5YaWYbCElTYKp9KW8Q1UfvTKsrlcl
# DATA s5ov8EIfAFc/ta54yhYpGqrat+GZfGxLdbVdm8w1K6S6CpjIpD+mJFZlhsGzabpJBWFmeGVurH8DODcJEUuVjbu5ydm++JnJkoDQ
# DATA 1a7yiq/xxlkOH2kTLSezrKxfBfE+xTI4gyALk2SHrAN+lT1QA2WfvaXVk1MtsBWsr7gfVBm3snhMLb79xHKfFuVEGu9RTjg6pHW3
# DATA ApRKGnCGIrbqOsg0gyWJeZlM35DhV6pUClRG072z8V2+up4Jr3iCHsVKV7fNKh85PX51sre/jnUanqLX+5MdCtWCXiWaUxANFvGb
# DATA RRkep6jP7GBwdXNLepjhBelzSnU6X6SvYykbS5+Iw2AUL0KrZ14qlc7//Jtso/T27mn14hP4WrUGZlfsx+Qw4tehn9Knue/n5jsz
# DATA aNqONPp9NvYa98ej7W+Ezer/DD21VXHTWh5bByRA5Lnt+cryQFnubr2v7vV4e0W74BEu6d/JC30h+pQgQKyOdQ5PnvsKOSPRr3Fb
# DATA rhgpZr/iyfJVhlDJKXHWMOq1Hd6Z6VyXG2Ffh5guWcHGyXk9Vjwfj1AXrcdqB2tIlRLOUuge/ew+6043clZiTWdGW5ShzVa7Z3hU
# DATA 4ySOWJO/IYomc1QUd3tFzRu/CHKJC6xN+ikglbKGELZE7YnmOPyLdlxVPlwd5VUWq8pi1nOxg8ToLVk+AYue9dvy4Qm96XL1eZH5
# DATA UpbflVlrsfu5bc88Vvf7bHfvx69eDl7unn1RquTAK7C+19jb0j68grZlaiqqoTaz9TzLJbZmN1kVKDSunZdXoBDRmPCRxfO3JTqp
# DATA tm0vrEre21ah4BoFjflXXvK8C7WEA6hejFDEX/0/8mHgXu9uzU4Ut7uMxDk9auagwIMOlmDlUGWDvbUUzG2iQcN/UDFjl+82z/Cu
# DATA Iuz+ms2GC1X+wuWNvI1juvQOYPtZMisb+Krc1RoFIE9hazHmf7TDI5wr9F48RjkQrQCrT36+/2zw7NXJwdHng92TvS8OvsyrCAV+
# DATA FNtL5DYmnCjzxHAp9vD7nwFH2VelDVaRxcwKy3MCi6OeKoUChcYu2Gz36lZkpRfBr+bm8lTCGTMVzFgql979v+//5t0v3v/V+799
# DATA 90v/3T+/+82737771btf8cdfv/+P8OW/vv/5+7+CNv8bP/jtu1/C11+++zX8/Wv8+/5vOQELyUt5pJwolarXKBH2cRxMl7OBMdby
# DATA Dk0n2LOSV4F+nczXWR5oHTKfJr05M5Trqr+us8jhj5TAvGIDIwNRfrmaZW6sI+hvbwGvKNZuVzyvQuOYJYo9e9TS3n78Mdu5lnNt
# DATA u8g7dpezngmXtBpGSbu41yfBQ8fxdMUm57rDypxxzQjLwllOSY/DHHw2uy33NOUesufNTARPuBTKuULlS7M/f8fk9RR48/Imt3Lu
# DATA 6ddJIY2nj3NIP+SBrVipHvGUvAJ6JOXMnaKpOwY7Kb87TFLQgy7Rb+X9XO/BFcfRmr3ihBXsDcOUsOMXuXW8VYowS11xltpXRFVA
# DATA OPfNU8+PAisHR6dnu4eH+88EOAqrL/AGrPucvVU1ZQ3Nw7sCZgWdo/LO3W9/eyr5gPjPakYY9GrBIyYDYpamhN6xcVTouv42QSDs
# DATA i8SPme33/f03eLoyWVB1o/k0GD+RaohGGeG8GrocJxnzpS4sc7890ooQgAPIdHX8iVdnBQPYzOhmUXytUOb++ghnvgnwWapv4qQ/
# DATA EBXa2Q9Cgyqf4IJZo4Dq6AhWL/zYwcb9bmiONz47wKs/jk++hs0xeHW6byAsGo/uFtcoezCgYSZ/hn4a3oR6ROV0kQwLkF2hFWC1
# DATA fN147O5xCRyVxyVn5BHMYm54q/IA0NX3uw8pnQGD8q2JyaB3NlUqFOAtpPG0LF+JA+J3AxiNiWbt6hYtne9u/lmw+TM8AWY+Dmqb
# DATA F2/r1Uazd1eqSr7bXDttlIJkDfAYofHy5PhPYAmBYvAeGLOSlG+/4xe4gfkxhXaKExQk6+H35it2cppQV7Fx+kNWXxi+IqfVA1E7
# DATA 1urwUhaNGr5nR+0mDqLu5PJLebyqLYW4uZR8sNI+mdGta3juuoovOOwzF5aAspopc1NRJrC6kuh2+S7wrPbtS7zXgfpZM8J5Xdui
# DATA mOSBAzpO5yrTukGySr0lzeWhjJEL0Rw45pDv2+2Y1tR2DHEnsqPJN7KaIVBi/wClB5BjwM2KWO8q4PcfyBaoFJjpAomlNkmkUxnr
# DATA 1j5Z96ZaPfdF/nb/m1gc0HgF0KoShwAmeWM9n1S+C3Fh8R1ZjG2FUXR28IpQW/okTgN1moaLXHjFMY08Ca3aYAK8vUlYNrKn1DPR
# DATA YxnuXPnV8OhggL7IwSLlbHek3XLO51+p3ud0UdG2Z/EooHvXwGYf4zUCupgh/jJXpVHxKKE59sAOEboOpbYSUFETm8bLxTwYD9QE
# DATA VX8Zz/Kc9M+ZuCPX4s0OMP4+MbGOlsjFk6NBDUfFCkDPbwea41tUobDyiLjz9u/J5JZ0Q3/VmtZNpoCmgWpXcD7D5sJKsphXPtop
# DATA ChDk0FK8ZmR/06KZgKFyylnOeykDJFa7cXuIogzrrKwaiwvIMcFNY9ysOvlyAhk3OktUSW7EL6065g5aEtRGQ05tdFEgD13PmwLW
# DATA 2uGgfkub/COFCye4YYsGTYvbKx4/X1ljEiMtdFMWA66dhsspU59RCJx9cq/IrbIiYFPZzaBIaRKpW1lZFfXCg6qSZHS7fhfi2Xkn
# DATA xkrHy5nWrMBEy/SX4TIZR/xttuSsVKr4rBtQpi5ShozkjC5S5LGjR1qNC2NQ7pjePxiuj2VU159rMmXd3F8DReFrq6FX7meVUKRS
# DATA RFm3PldWxEWhBXF+n/Vw4a1mT8nh1R1LD+Iz+EWnTCTPZy0w+9NrhgSDq8C5pL0a5d7mNkrOSwdYH5x9dOZt+bH4AEuhF58uMDwZ
# DATA 0M2LB2dfK49+QSYY8ImBBId9DXhZsnuOMFoDkk6+PovxVmNJ8ZFkdZtfrImTWzFyjiPzeAXAIPn8rsA8FLV/PDTs8NEAfbRjw/fY
# DATA xXh2vPdjWIkvjw9fvdh/zIIoZdzY2Hjw+1SRcvG4lo0hsyfTwyasqOSeXVMSs2qfTnKkqzI4CqWAqB6qF89dxg+T/Nqfw33Z5xW0
# DATA arN6R0X2pFQgYR6IdyR04nxxW0B6ALPMjaSUSTJW75TNvCpFQY1icaY7rlp4KV52DcJHDEPxWucUFxXX0G8XpouukbwUhAONaPuB
# DATA SayH323HMFX9FenrNJOz8UpGOzL9/pAgpd1c5yWwo33lBWOhVvDhahnHsan+wPZ99db8e9WXomXXL9+jNzmDFC+jrcRV/TIaKVUs
# DATA yRJXHJWueFM/oIlxn1aXKy+7WilaTQUJ/kpLvT/RX7dao77+LswrR60uD1uxkp0UAnfXbf8eFF+1eSw/xmP0zlWdU2mRH6jpfbDO
# DATA +d3pm0UnzFYamti8UU/zQaXiKIhmROpMkveoqJHdWKIl0pPn4U2DA5IfgwGpGYMByvHBQI5xU9WGOR1q4QoOtd355RJDOS/pSTmK
# DATA tQjbGQyAlwwGFetNDHoOAnmlDIhE8LDQLig2Oy+JXcvtJ5HlUVvzrn2GJLxKEck75485HnJxf7ecqbBp8qsCqqm3U6KCTwMsVqjc
# DATA u3MqHC0d0R/sSiU5OhyeGMplVlOJENJ9jkZXsyToJV5Ffl8H4rz1slCXKjDx5Ef0YyeI/D/vfvHu79/95v3//u5X7/4b5oX8AjNG
# DATA 3v33d79591858UPKZq4ejxFhWDYKZdU/PpUPP45v6dOKZ/30FiY82X+DB1Df/X/vfgtj/9X7v3v3jwLDP8Dgv4a/v/Tf/0f4+N8I
# DATA kn/wMR/Ff/dP8Ms/YILK+/+DUlR+U/Pf/d/v/wpb0K//GWCHZr+Fn6gn+Prr93+L8/r/Kcvl1zizp/67X73/axz43X9//5/f/dP7
# DATA n0Nf/0IZMmrI938rA2LqzH+ivn4Fn37+/v98/zfv//r939WALv4nrP9yFY9nJPKnC7xeljTE7/j+x26r2c3V/2n02o0/1P/5Lv5h
# DATA gbIN8mRLOt7Gtr/RDpr9uNfrbQ3rjbhb7/S7jXa9HgftVicIRr1OVG8GraC9NYyD1lZjq9/vhf0teB63gv4ohj4w/3GDnMYb6qKe
# DATA DblPccPc3LNB1RThh1Zrq7elciY3LDh6/UZvFAE1BMMoqIfRqNuKhnG93wu6o2YD3uqHnU6r34lG9V67N2zFvXrc6MbDoNUdBVFn
# DATA Q91+Q/3qq06LQOj1WwUAdOO4ATMN4nAYbQ17w60g2urF0bDbbPbDRrczbERRO2g0uo1GA0tZBVGzDYgZhfWwuxVtRS4A9l17RTBs
# DATA dXqdAiDi3rDXhiWBUbZ6w3486gTdbtgPmnGrHcKEo3az0xqOhqMoCLdgHaKgH261+v2gPWy1G/1hDoiCgl9FwDR6sAeLUBJtdZAq
# DATA msMRLEqr1x52o27cbXXarfYIL1mK6sEI6AOIod8ARDRHgKs4ajRarV48CkMXGmY/gyFdsbkOkkankDr6LaCMfr3VjqNuM+h0hr16
# DATA O9pqtABNzW7QCJtbrVGv2d0adrtB1OrEgJl2s9uO+r1eox9GLRcSuuduIEJ4DSTtfqcIJfVOowWzb9abW0F/KwxaYSPoxu1uo9uD
# DATA JemM4n6/3QX8NIdNADVsx8N6FHbjfr0NywV0VQBItgaCfreQRKIwrofDZr8zCkdB2NoKOmF9qwu0gFu43usOG414OAo73WZUrwdb
# DATA 9S0g1bDe6w2HvV6/E+Y2CqjKAAIdFy2GAuba7RWA0WlGnXDUAsob9XuddjTc6jZbvX47Chtb3U5zFMad/hA5RrMHJBs0YgC2G9aj
# DATA JpBvs9Op58GY/2wYTNdRRbvRbhbAACCMWsPhMOh2oOs68KP+qNnuweCN+qjdHm11wrgX9Oq9fn80Gg37Qb/Z7221t1qwYvVmt+nC
# DATA QLfvjUDLuQE7eh026s1GvQCSYdQI+7DMva1OHHWCTr/X3+putYZbMOxWCH+AfBsh0MgW8FTYQGHcatQbYQTkChKw0y+AJAOrax0U
# DATA reL9OoRJb20FsGRA/72wC7PuAU8fdlrNVtyH31udrSGw0GZjCAgNtwJYtk6n3WmG7Qj2Vm8NFIMQmNk4vVwDDVBav5BSG93hqD/q
# DATA dOJ6EMVDwHtva2sIfDNqhfWgO2z340anAzxkGNWBVPvxVrfXrneDznDYCIO4kSMRUvgHkpSZLG7X7dt2p4iBRP2oAYwhbMD/YH+2
# DATA YWu24047GMXdTq/eiRsR8NZRv9GJe1EYRc3GVtxv1xtbrV6zEfejHCzKNF6zcRv9VtHyhMN+s9Fp9NvDUatd70cgakcdmDxIYBDA
# DATA w+aw1wcW0u9G0CSsN5r9Ed6YXR81YemAteTYKVcvHZA8X4eLRhEYsBvaHWBj/TDstGIgW2DtjXq81QDiadXb7XDYCXujfrPbGdXj
# DATA Zn1r1NqKga+3wh7eRJfnpbbZtU7YgULRL2TqTRSyMQwcBt1WGDRbQLPtKABW2etGcb8D+7YL8r3dbQf9Fgi7LnC+uBlF8FLY6KwH
# DATA ZGDusVyDGmAKRSTbrzcCUG62thrBsN1uNLeA2zaiTgN+6HeGYQMwAiQ63IJVafTCIBzVu2EXVJAm8Hek4ntAilI0sdeRDGzRoh3U
# DATA 7tc7gI54GAL9diMQw81GMGoBIwlhE3cBbf1uvQvQgaTuNoDxIdRxu9Fr1mEf3bNUpoDhOp7b3Oq3i0AKQO40QY0fhb02bJN2B7ZH
# DATA u4t3HQLuQD4DDwr6sGBRawSqVK/ZCkYByBCYQ9BrdO8DaXaPMGx1GvWifb0FdNlutUJg9UGnXYf1qHdGIOlauJdBl4hiVALiVjMC
# DATA ORi1WqAmDeudrRC0FHir2XDBWYzXCuP2VreIrTT6PSAKkLcgW4eNZgfIJgzDFqABxFKvHo62QIMEAhm1o2YcDPv9CFq2QCIPu/Ve
# DATA K0cvy9HN4HIZzKN1nBbIoUhNG4F8bcGW7YSwiQJgKlug8gRBtxE2QFEajWCttqI+QNVsN0ChC/ugSgPGGrCvOvW8TsJOok1Yi/U6
# DATA QQc08CLlqB8Gw1bUgbFCIJOoEXSAYzRHHeBgwDxa3QCw0hwC4dRBMWgBBcegqvWiBghJWKmtDX3zAQGzwTc7ITHS12u+eJeosNas
# DATA NXqAvjvve3/490H2v1HA/w3u/+6Cdpa3/0EV+YP9/29b//czrBURTH116GIuCW9S/hdLByWTyZI0jqqfjkZUI43pyQ9TvEfwvrq/
# DATA fD2n+hbP59NUfbn8WTJTn/Gim3EyVF+T9HcvDny1XCRjXR84mKOfQn+NJzP7O5cMxvyEk929M7z1oshhVvKeHx+f7Z9gckbpm+n3
# DATA /ZP9F0e7e69OzwZf7B++3D85HXzZ+Aaa7R89ozbf9+HTYF2r3aO9L45P6EZzctXiCbH5cKP86aTy59xy8Nmro2eH+4PTL3aBze6U
# DATA 7FtASj/YqHjPDw73TzEdpZTf4CXO8xRVFb/Zbom807zoN0dNsC8vLhmLDd/RhizdHjlWn3KyRLe0bG/lwrctL2egnJ67AuHMGnm9
# DATA DrjyVKtjhJYCRwn+7ljHNCFLQvOdlitGiZ6QGHDOd8uUwt/FT4YftceqVPFe7P5kcLL7FZaW77pFNOgRLjg8a+Ye5U6WRWVcbFXX
# DATA ECtzR3EIcJSdihgSGaLn6oqTIV9uUiUC12Xq5LYSq1N5V7ZtTY74UgPMqFaX5cr7Ir0Hr2N12/K2t7YoXYlqTan/lD/d3rROP+D3
# DATA 89rmhf1T5ePKpyUVI733jIPcXyDMS6DSxZkwX3+ANyTE6joPSdTEsM+Cro4slzbVIRrKvRglfERssZzB5sUa4xhawQivlF7EekRJ
# DATA BujAeo5cOabc4DpFFe++6gPq7KaBRpXurJV01846Mgx4J03CR8fm9it46y/iepim47LpFH61ZqJLZQOp0KYTdLJE2LEJjB+rVeQd
# DATA GmJKU5l5ZMX/kd+4bzGe6Zv5ZDlGabqI5+aMkvBaLDoydcJs9LUq7X05Ty5TlcHzZQ+5bS2eRpy9A2z5wRzjA3M7UxGEaqFIHCZT
# DATA eXi+vYmnerD/CwYJnxeVUEawyvjQzipCkfFs92zXL0kFRXtj4MO93b0v9n1bDtAGUd9bzTvaC9hvpfKYk/WvpvGbGd8b4szSl6uK
# DATA zHrgvFhk6Uo5TASUWXjvWr+QCxmNjiFjBdMQFAiXH/FyzvHy8FmZ2ZD/CfMjoU8FsUOj8nYOQouUK+d1WZLycKO0UTlvXGi2SMWh
# DATA NLvTCS33DAACBbopFtMbBG+9BNy528bPMFzV3lWmTnKgqqdMgjfJZDnZUUzecMgHC27mj5av4v8LxjaddsCKYZiTshwHc6rpYM74
# DATA W4fOkRp5gHQG614C4qv4QYbN4mBixqIr8HbkZzqFUJaZQJ8Nh3ZIOABXkOePgJdqnS3S1B9jpo1LJXlZp69b4DoZ5XlgXbKAw+MP
# DATA MHqr2etuPQZX0tHK+DJj65wb9qyPO8ciJnFPvC2xFUt3aIuwqWIVfxOGK+laHXd0XSm8eq7eunhwX72aZsvZjLJR1Y5ScJcq//oS
# DATA lqFTM7n49rK2GCpHu1WjOcj6oCFZaNGF4261F+6Yse6U7LFKT9FTVXlK9huuLSnc+lQhl0RRRzvlG9LY/WDm5QpbUaWK56bKKRWA
# DATA T+WspI0VIxFXz5wQ3byANYafZrd/CRp+5S9F6fxL1ji/AZWzIkdHHyEOHewiUFQzZ0XWWljkYhUaiYgyUltkc+gdQM4l3gEP0wX2
# DATA YKrHfCjcKmfWhRuTk8rcMcOCOdmZnDtcKLjq/g99pxHSgWLYHwgHFsozuyFbTtzhHR2QCUDV7UAKEyvhEXyMaWsdF8WtYMkirhQv
# DATA CWXA1qpSlkzKJjpy8C2u/jaLMDo9r6sz8WkdXeSMzpbLAZ63xWaPXDYmaY+rVXrsM0AOh9fb+E5ZGnJfXVmURJqEXblI2LfTi674
# DATA y1YLSQqsU+SqGcSfuUVeQaDmRfzqfj7gOlwQTw5D8KOUi6jhPig5IkZYzUc7WuBoTNx/nnlV2+OLxdewHqfnVRakL7+0xTG15iMr
# DATA lZV683L/JULu0ruF3JU2xZWi1pO8uppxgveVAu6si07XEL++bm+FbIB9mfMcMvV7iMwUj9YvFSTfrnSAm8h6BTaB8kVVWWOpVO0N
# DATA ajWl0Sv54hhSCtHAsKb+mTnSLSuJe/Tjj2XmCoZtHONudfn1OUQXdOf4naRMc3o9LXbZohW11pV8e1UFrougitY/GcZRlNP6LaU6
# DATA ZzfKmfGc7ZivwHePEVkF/RVsBNuiE2MYB43IwVfiey7R3DrvbV8UGISOEUjbYL3J5yhHahhRLuQrMv/uuuKq64WOwl2B9PlZIifx
# DATA 2VNbG3bbYhXJkFVNrla+LtkH6MCtfQ7/wePLtO/T4U93krT2Ga7zwXGZ+64UWg5AUjnDQbm+8oaDaO6PkHn77jSzFbGnVEA5s0yz
# DATA ENcwGzoFk8Dh+XTBTmm+zWaQZGAbWCaIYXIFqYqDQMXyY3mFDcoD0hVbD3G1M5gDiKvb/CJmOUcEd0oikrsvdDnwMzAbpdKvfrEm
# DATA pXu1l9E8UaKXsYc1Rp6UzDg1XXnkm2/yPz/OA4HXjK+QqOCxlD/pgsLFGuHCQnn8hnz1NDNuUmHKUjd03Ay0WbcjWtUsnZUVn6us
# DATA 4+76NYfNq6uaVp9rlWoaxfMimRIGIKTsangPiZR0uZgt6dyAIczKAzTM7yjSvVlDuYUyQE44PiQK8l6t6Sjlg0YEzFkwP4Bfyqv6
# DATA HDYkeqvyR4RQfcSIhb/jaAtVHwRBuw1/io7lYHY/LTm+X7UR5EoXi29rTse/lYmRoVU2j7OszHjDDUwqN1ZUIKh26rqitggNFhS6
# DATA ahsu6kP22YOuO+rlQ60aesnP2WMC5icciWLPIRVEwcY1mbpyfWkXW/5NEXFGTOGNvIzK8wTo+802/Re5dr1+obph+4Ue4BGoYHoZ
# DATA o3fclmRVfMGtJ2lJc+hIQYFBNKWncf1yjnKJnULt7b20zlutHdXKtDO3LOiCFdpD+UR/qqEDgQtssP5S0eyEYndi/zhvlwo0OEUm
# DATA OQNGu1NQ39U9fbl/cnpwfKQG5soeNfaJPsbVJ71KITGOZqjfCswKLRdzRp1lzX2QCedigu8OeowR9xhWaLuJ7aeKRPBmbaq0oc4z
# DATA OVVA1yywQzhEhqasirPq3zWmyOEkiJH1eyyZ2PaudkViQo3xRm6rTvNuye21pq5b81gXGhZ8vC2tdKCZuNh62w5vv7tXADmur8rd
# DATA nbXxytZtDzjJKr2DIUZ1rxOyn+lip6kvdVc8T8ohr7gA1Po/0sVvuQt0z9rbb9kkfGrbMoCsZ/ezjorzGsGpboSk1mqLsL9AZMeA
# DATA 2SJLMeWzMbxKfAtr+JMib8vYVJ1rND3C/KUb2bjM0bxsoLLueKM48zdv6nWOdJk2a+oAPVIEmpNq6uIk3S+bwPdc/SWaEtjHnY6c
# DATA 7lMGrukGEGetu/dQYZyVE+CmcVFIZ239xUej4TKexuqyGy936+qqz0EfpL7X3aDKT7qeBnUGUJ/7sw8DFpwB5BJcL0HFiufXXGgr
# DATA CjAjJLKArvlSKc6nxJEMdumtXHVD9TBzvUmSEu6wp77kMNAVDAAv6LqwVCMqorkwOUyGRGoF5Yvya122fYL3148TfW89KcSYaxQQ
# DATA h6FyYCoJCSkTP2NYfpS82SnVxMDbxChIMt+xNlBlPWX9js4cXXPcwCnyyGFCim8/5j3txGm33fa6qan2r7bcvaUT0kyfvVc9FBft
# DATA ENoU0kS7J8YPhTc105MaZaYpp9Fb+lbb3//JwSlsCfkGInz/xcuzr+/uKbGy8uT7/u6U7lqygt94fdNsORwn2RVtgwxlvdkD6n7R
# DATA qyQr6G42T0OwUvAwPpUPWcCWiZfAFPhKP18Fl1RiBxZ/kDS9otn/LszofoYElKKOuxfwJq6HQrgvuiD6X5dVFdbHwMlrOlxfIMFp
# DATA lkeTeSK3V5h7VD6yOYn1u0KufhPp2aksY7b/o3EuPhTl3QPSQBYqmXYFlWA4ObI2nyzmsbWZbF+Dq3qs9WQIkdCGd153PLh2mhK9
# DATA oMP1YFpWfi+FB9KZojW7dABaB1RPDWMEparWux4oGJCvYXBvY8LSo1tL8PfRzZGmPgweXpDV5g+UNlDVDDQiqVoEIdCQJVlbuu6A
# DATA qNHj4lcZ59a7jjG/0old8IBLFiitl5pKmpBloOmqB6yv8hdLI2aQWC2uPFwIg2nzf5EzBvnU2+8+/7/R6DR7K/n/je4f8v+/i38b
# DATA GxsnMVao8rPljC6siSOrMjLncEst6wCdApgQGkHjEJWN0XJs3017T7o/pet/QJL+cij6jP7lVn9En6vnney/PD49ODs+OaBMdz6Q
# DATA JCVg0N9weRXOa0n6ZJwuFmDSPzEX2OoyMSs/5a9tWt/HamUZp7+Cx/m+xyloYEVQ5R8U3OLCnXGZm/vnqirhrP6SH4Z+h57vPL5x
# DATA kZBq4fNqsZhl20+eXIIushyiV1wPd5KbxJ0zWQPmo7pgOO68gxe7n2P9wdw5CPEjbZ/XN/vB5oiTfyres/3dZ4cHR5gDTzFcFWiZ
# DATA pVlC1ZT0rQkm+6/0xyXnWrmVaLC57Frypf+4RMFfVQg932ouzbZ1MwUG7LBgPMCS3GXeUphOni4o42L1phddwse614heQ3D5fSuc
# DATA oNO0MQqED7lg5EHENzXm4w4Kr1b0wXRBaqjVI99dwHA+cBOOc+Nq2QLkBBbhLLjMTAXRT1aePyNr2jTxVu9RtN545PUM6fySAl/m
# DATA WokadyIXWVq1h2/Qe3oOU5BibSP3vkEu9mjTEtWos1nQuV7ElYKs6GuXyxucLhzlnrcjz8Dc+Shb0eq8cmEvKACeL7Z8eUlF32Sk
# DATA hJ3SeeCtWdJBLt4M5p7Fu5w/hWQEmg5olpLVhCPRlcHWrPxgnKVM7WSBZuISg9+TIIuzWq7X3esU7MEge409P6Pig+i54Q7w7Bm9
# DATA Bx35P8UMZf49wo7j8cjtrHgFC+fGCfQuPuRpAfYuCoprqQqW1sbB1Ho8CZOEixqKOXQ345XPlYrtGRvr2J+irO01N4AWrn3RrZ9r
# DATA 4Tk3Xy7caBq/pI7wENrLH6MSXCUxPWBVOJfbh1ov3/rQqiOcmuE6t5LrXzdJStcmKUwX4wRl6xIc1dUPd/x63pF7xqUtlcuAmJ5o
# DATA p6BpBBEl0YByD9p7ZO6SIcfHjqU11ObLaflcClpikT6c3kWVU8DEqRsGswVeAC3T5R8xUqI+Mig7E1D3W/WqAbziZKGoEbNFBK0p
# DATA D6f9+EQcoXpYElhjeIYOqjjK9JzHySRZuLmZVoZ5fmwAyVpBXhK3jaz6EPk+2EacO6pu3uP7tviSUSc0K804Mmumc5vE44iPQuFt
# DATA BPDmNr/PMV8ZC2sRDlhqKZM+ofL1QnolVWcx4MKKupC5kyKllppl0crlc5fzdEn3J6iZwRD2lX/qRX13towNpiPmPeYvkHn7tka0
# DATA d4eJxR9T5y44zoro3t0LD8tW6UWu8SlldV/H8UyAw8sPgJmqfUO/WbpMfhMhZpv1FVw4KFbEaQ1p2daS0Ji5RxXI72y94MQN78vk
# DATA 1v0xA3wwP+Gl3EdgVVVXXSAnSdhHaN8Wm185Tv1UZcftdGgNy/pLfN17pO00dBTSRaoRHtRjfWoiWn6pYl2grjk5AoDruv0g5FEO
# DATA bE2KagBDk7p3lzNTul3RccMCGbTS+7h4t6lKpwvgnGFu77kMzxqSDvOhzX4fi9N5amJM4tyH6XJKlqbjiZQGjt5bsLHN8JYWzIeN
# DATA 8b45EIT3oJQ381p8Kh1jR3KKRo4+XHV0wukHK/bKb5zf1T/a0Zt+u6gk54mWmYIiYDy4eaLt9cKRPbE7YDcj64/nc9fbO4R2r+8N
# DATA R7pmQAEXf/AS9O/7WryN4H1E2SZGJNiWieJxjDbtU+ApPhXhrSp2OAMipNRBqV3v6norqzufUB1evTSVnM7GS/rJjt94XJDS0iNO
# DATA 9ceisKUsD6spZk1k1mG6HPP1eeiEH98qxTZZrFsc7m9U2sNFBZDfCux3tndGm8pCDE919WC6NV0x2ByllCrfxrX+wUV4bZPoQwr6
# DATA suzBuCZfxbSjLNc17ZHVWuV5WQG2Xlc25AO+bCWp3bK44hJWd7XRF5LZ/+s5h3WRht/jGA/Uf2n2Gi3X/1vvdXp/qP/6Xfl/v5So
# DATA qs4HFM4hF3mx01Vsf1RYwEJnBnefvzdXt+Ve92/Vfwl22Eswud+s8QZbvl+p12LXn+CDzqS2ylku9jrs5MtQWInRfO8aabr3H2Sm
# DATA xKSr5fQ1+d4WwBPHwWQYBdvOEQXL2qtgjYx8hJYhUoog9eceOeLnBRUyVMibQ1WL4BL4UQa2j1J+5PJmmo+Jklnp7JaWTw2eqMIs
# DATA fBnIqqI/hsUtfE/zx012Uqzvwspmlas1OcmQKwLQCQLnsVAeP4c53qdOvvsv737Jtb1VIe9/gD+/ff/z93/97p+FMjff/ebd3+MV
# DATA 9u/+CQuB60oeAn9mHfTLXUEtl3/aZ+rMMzmf+ogy83cPzoBqjcsMqPQ4FiD/zQMzoMRp0k7fBuclSuu+2PYDItIACZRJg+fEn81F
# DATA QoEsBV3ByTcJLWe4wKAcmKv6LCEoOdFTC3Gr6UGzBB1vSDPnjA/3nnIchX8mZ4TgzvFhcsCWYNOnwelCmWRqZ0Gnc7sl3uiQLKyG
# DATA 8sODZwHf/V8Kr1zPnbD+m/d/QySFldzhE5Z/f/83VBP+/X+Cx/9I5ef/GV76Fz4yWFBAX4jFApGOIaAlAMxN3SnLBBRMom4bCSeY
# DATA T+DD3YMw/xcsPP8bJPJ3fw9Ug7D8hsviY1l6oBSrMD3Wu3/3zzCVn8P3v10LL5EMQFg1kQWC/TwH90VxRphcdzayAktv9Sh3m29h
# DATA E99tgj2yfLP5Fju8qwHnrl3+rJRLx5opF8boniCW1fP2W4ZSF/67UIPxMKUVK8aEDejiPFoCdTLJesjGhHO+9zFZljY3goWAZfjV
# DATA u395/3cFu/gXpUrRuas1d64/Eh1/LNGwEl/Nnj8Rb6anL9xkB8aHTo0Z7S/e/SN8+eX7v/bxD34AMoPZ3cuzHn/sxYXYVAHA29KK
# DATA KwCoWODaTuijioR98KxhS/2dT3vt1zRRvh2Cf4a5//zdv8D//eIRa02smC53If5NsHFKppI1xqLEVE/aDwXR0rfM0883TPwCNsAT
# DATA EZ/Z/2DvbbvjSK4zQX3Gr0hSc5yV7KoCwLeWiixq0CS6GxYJcABQ3S0QrklUJYASC1WlyiqCEIRzZMtej4+1Y8/sfpjdc2ZnfXa/
# DATA 7jlyW7Lbklo6Z38B+Rfml2zcl4i4ERmZVQDZLc9aGk8TlRkZ73Hvjfvy3OXe6HQIFH0Zj8Ry4TDg5zQzB5PRqboSdfQnndlkwOSU
# DATA uvCeOSXiK5JOqJyefSAwOM9lAdmLEWLkiL9gQvyT1/+o/v5Pr7+M1Az/EtOP/AKzgMBO/M3rL6KP+tOPZwd+AHe5nlKMgWJcEZEr
# DATA kQgOWGSPXiOCgwZTu3Hj1pXOC28GGMBPKjYJi4BaINHhKmpNu9Oi2Ock9AGSl7R8ia9CZlwS+a2MU2sFPwqM8r8hQ/wFLxLlVOEc
# DATA KJFaKDoj6sxEWKuihxHV6oZS6O7uSdFr3zeiEmtql3CmPfjNKXD5gEHCt1pBHtrTstA+jl1LTiCc8MZF1rDvrMf5jRv40omK4Y4Y
# DATA qQQzsKLgYd5pQcSLh5F9V4WJ9cZw6Fp65wWPJDSBW7LlblANbIEWLc4OVaN/mALyxhigaZxyK6qXWnyqtqCb0EXxjTMCQmGgyXNe
# DATA 7HN+UPPZKGdygdJAXLm3/rYowij6Ks+MQytINlPFQYqD/Ugpf34qsMlwVHPcARypk8fkyJ0L1QJ6t0I1Rak0MOr/jL3+UzWQvwHx
# DATA Qcl3RdFTPfpckZWfIh/6wpsSEF/VV2/+UhxFeOhcjZDeGNjF/uFZh+NkGWhM7pl+4GotRrUIisnOx2sNVShE94Tg/blaSSLtisjH
# DATA ZYHL1MF40lLy4zsOs0frBfpczE5qJxTrbjKzinLfKuMF5bv49efBwatxw1r9B5QrfhNBpi0gmerBb1//s5AbgEbljp1zwYB+Fs0d
# DATA nUpNRMYXWSU4mvfzTnqQjwazKTujx80mukfhWwC6zEti+TUPrRkIAQwLEDgBGlRgcQFMXWhQiFS7Q80Xi5+/w+3/syg4sb+Mg+PS
# DATA I8gXahp42+fAxCD/mDpKfwUZ0Og4XapxbBF01l6MO9jnyIkiBE0QG52El6eVxRn99WhS3OWFjzVsQ9APoXzmFdFwKpoj3Oqyjjm5
# DATA xh0tnjtduqgHygGE0XcXU4X2mOTQ9Wx//xKHDwmMkVOAGv4CmMPrf4CDJiiooblfwo0Gj6UWYUovNMTgkDqW4UyIgdl02oU1lRUF
# DATA 17WknqsvL99n/lyN+h+Iwb75n9TfX8xZaQvpJLosUTS0U6W4FXjqVx0iJtWcgqvou9r8Nf4vsKxwJ1PL+uekmaFDewVug2OTMpTQ
# DATA e9oQZWKOLvtkm3KN/wV7r+Sh34weDpTE1u9aIyhosHN0oaO2mMnes84QPaeUkelZPUyi7mAwOiUdoD9xdT2V5ra/b3xS2XV1df/C
# DATA seXrvtsTaR7hhkNvBb4ocMsLuDNhVsZ/wNP2T3C6yo6eFtTAE6LttLxUWJdzX4Qmd4o1R/hUUsIoN++2cpbQ8dDop/oMXYSXNU9f
# DATA Zr0aKffdFb1+/fpD6BGujTrns3SAlL7H9xT2kh9q28b0OAWNBUe3keOipa5gPHF5ggGf4lyvFo+oKAvg8ddOCuVQL3oYjFL04wqs
# DATA FytVFF7/Qaow7lMw7e+1JTRSpdShUbrwB/p5WIGTCPi33lLJYPORylP3j5gLFTSS6sgtoKAqE1guAxBVyopK/UPATCRWHGwFrhRT
# DATA rMeeFituVMA8+Ynj3RYt7nfMUlPEsdK0NfdaN1FJUIsPBqMDSoRAV58SDxhikAvCTnkzcVnG2Z7HOF1ZpQCOxZUuhQVM2LRajDOs
# DATA gR9cWlT7vYhpvsBC93d/CMwMrN3SxMiTW3PlIMrlkMscxTkCyiWEk683gzf53jhRtFrziCcFFZikVSTENscPL0Y++y7Da6fpUbXP
# DATA kDGILlaf1bHHv49c5K66raqk9oNbbFio6ly0sPYNvWoadB3wS9+TtjmwSYTGmRbJ9T+gKsi0HfRL1mpesWSE/wehw+ZZIR879wqO
# DATA iulUKwyO4qdQLyjVw8nYyaFPIBKxWr+iOj9HO/+W20E75LrtaWW5P3FaPRmYt5Dbpz8z+vQWmYunRsQPYXcZilTgvX7dRANKa2ZR
# DATA nJwk+8PmwQxQW0qqz7PSevRNzZ8Zc4XVE1OoOpTPXkPY1CWgIXmHlgCKMHvFNvFEFXtKGwVQkfD7ZI73LjGjnbNc3WjWX6n73eoV
# DATA fQ6dbEa/D/8/JS6+f8vz/1tduf2H/O9fm//f7iQd5nQo1YWWcmApRgbxPznHOIA2IZuoG6wN9lZ0CiTn0WxKZRFXRBUBn/F0kC+e
# DATA +q07Gp+9fVK3/pHqvPk1TaeLR5LrVG+TAYjchDzjPgM3ZrDMYn/4GY4osuVQzVKHv2ZD/NtNIQcHmfKyDBWjnEJgFRx2vEV3UJem
# DATA ZC2LBsOwMYpU66FSyjYxKi/bGZAe/MOMbcATGM7dFpnpP1E0QMcqKO4Nq6NkyS4or6InhjyQzGvpoNWJrEW9fno0HCnBuks6DyU7
# DATA I+zMdBTlx6NTs1GQyOFGQWl2xj2hADLcMWz7Vh+T5Qlf1aPRmHanE5PIAI44hZTjS95ldBIcV/1A37St+2eTMg2Zl5Uoc/5sLKJV
# DATA AG+RP2XvkX8GQ56b6kSPjLIhzE3eU+zB/60uC/8MGrZCQ2gCBDcV160tmNZHpxPScEc2Ztntj5kmOGKIKNkp6DFuvl2vK+1j1j4K
# DATA bhWkz/7Sd7tQ17HXv3OdK6DPBipW3cCmnRQBLKTXMB8Ik5dPbjKbvK8Dm7Nm3YfrkY1tYJxjMUHkmqE+RkjzdNrc6Ww82Xq0XiOk
# DATA 42kH3lmfWSj4R9HKSLHFcmh6cGrjrxVpgZv3CO+2mfq1yI753/GW+nM1j+pKSvfOX6GPzW9Bh/Q7sC/Dsqhr6K/VzBbu5L9581Oy
# DATA v8Pt+5/IDxEN9r9+8x9jFwiyw3PNV1WebcfJIoZHccvuR4ADpViQVkTwzzHqVfln9GOYntVVTND4Ut21QK3Ls6Ee4BWT4Cb0U/Xb
# DATA TwIS7lfL6lLVhOZddQT63CmU64ZTiAf3ALJnoFMRrrKZeoLa3hqXD0Nhc1YB2COHI1Cra6KTM4kryI/YkKtA5P2083jzu+5+MrpT
# DATA U2R7/aNiEfP20cZ2xdudrYde/aUa18UJJGw7pEo/h033K7klyUYuNmXYkbCif0S95CM6Ve+/TwaO0sNziYH9ndrvpNz5exzSL6M3
# DATA f05EDVxyqwekjhN6f/8j++/qiYCPFKVDezMokH4FHrzqEbm81UQDd1eUAOG18kUE+TuMk0c6Hg/OOi61o38gLgsv8g471ZcULNIq
# DATA yRuCcsQIdEijnCwNVH6PzvF+HZ5vdbYfbW0+/kydVfylttf6w92tbfNgc+vDrcePtz5hMFV5CeXzoYod4umwbTpWxppz5sVRR02k
# DATA 6RSTiP16pJ8Qddh3dniRIGuLl6mISZKoiIhSOM3UZWnuF+QliK4+v2Z3A9gVQIDZ1wlILxUXMoTjVosrGtZeFOhdaFZhygmbz761
# DATA w9UTQAgO2BZ59PvzsRTEVVSVdwdKunRa5hgec6Vgf0Wh+QCBttPvSRD3QnRBUa8mdhMZFikdMKlesh43w3U7M2mjvaGNdIjuXN4K
# DATA M4YGwzNrS+sy6vvIilDX0jqZJ6qKJpRSyUZTuKDk5pPCIHOAg67xGACANuAz4kh0wVGQY5XTW2bCXq9Uh0PdEiNZKlStXhXqVs9k
# DATA 5c5i6jPnqU4XkGj+s6KQf48SILoO6rbhcy0wFndJIuU7e+Pwx4jzbDtpZ5rtsBBNA1NTmEMTQgQlaFPNhhrrtRcbCpR5EUhkTDE/
# DATA F5HnlFCGVOJLskZEijGBDeHX5EBtzSbIVdB1/x/QwRB9CVH0xliSoshcpx7WwRmW/4oBpZnkLnyyF4O+YIcfGrdUxlzuHKtrob7F
# DATA mXhaIBUu1xGe2lxYzX1SkIHxHT5U92zAveB7N32EVrTWMuWgoScUdKQ96eHi494UVQVN6CLaH9W0Uxcr2uVvZmoWtJUafo/VZfl0
# DATA NOmZ3+omMX/l/tbGU/ypVJ64pi5kHF/Ciipx4M/IA54YxE+QI/wmwoVUggjHLYGo/uYv0eT0z+UXUAMyZlUWtRr0HWP19DLVeXiw
# DATA F+CvH84yQHqFPw8n6dGJTaPigAuVLQXjFWmcNFWAvVI0VgwGSHay4csaqGQ5ebcEqHmRnfFTU3UoKi2dqs5DZNok/pPad1rZK1iR
# DATA vej5dP+95DuwD2yojaqRo2fg9Y1288a/iSUZhXTZGSi5a1wroQSBFNV84tFVeEGAdZAkwJSnkNGo04LuAw1pm62oKzscpEd5G6us
# DATA sCdw/fCPzoSsEyFjdpX3ig3wKwdqV33OEz6ejF6dkfqb+uEc0nr0oj/steNu2uudxVbvYua29p3710Ra0WZjP3Enl6qj+a19p1CW
# DATA LZygawSPJpRHWdY0NKTmJ3AfjoaIlqY/XHLRsECCmA3tMgxD68DD4yUwk78hncJ0r/Rf6NgONT8QCYdcTC3eMjBrFPp41B86Pu/6
# DATA 0PEOgUk5Sf6k9jy/gej3EzTfPs/fS2p7f3JP7dXavaQAHSm8IWg8nMwQ/1FnCReApo4e3UTMPfr71j7tuJAFSYliyA1XhMPqUAKy
# DATA +LnNcR8KpBgASQCfCsJ7KAIGkj2eMt0RCfimg6goTh33RXUGb3PxeUyRqFQJPOK/dU3nuqZiNhw3uArwPQ4pyEr2hL4POJwMkb/z
# DATA hFIVeN7OUY+GVbmx3tjz94yHRRM3DTSQRA3/4YV3ucV51HhumK29uHdkdsHc0SbyTp3Pef4OmArcLoFD/AIFiF+CrIBCwpd4zfwF
# DATA PfkcpInfoa/C50qi+Bv19DfIdCYZxEhkREHuyUsMXmTgEkOhGqhQMm/e/HVcDkZn0m0CoE49EmqZgpxGLMkohq0SDghg2+qTzJFU
# DATA j1nChMpNbqFCyvJCfp+ichRZmdHHYfdklXuqrX1ETzWarEJmMcwFrtPMYxPYfCEBFfxVfv45tuiENF6eYtboPd5///3yBhCI/UKu
# DATA iOq9zqzZ6+sIELMeTD1acq4Dq7YUnhVzT2QmphsavkTYMbCPoyBZt9k4bCK8GftAYgmSmuFDDutF4NAqmbIIUWbq3KO/HFjXPbvX
# DATA UNtrOwQ3AvxAaz08WDFmKoQrhpNMHIxgNz3ZRUs+2iSCwk9/MhrijZhmVN0bppSNOw9IRCVhDjxPIOCpz83E72kBHpYEfcGE7kUT
# DATA O77MaJOQ7JE//fpFLNwKcClRy1lYVuoLyGvQFZuVZ98NcVlMyhNHG8A5qPus+8R2A1kbsJA+oVau967NgS+/Ge0eZ4rj5tNI7zo4
# DATA Telsejya9NWp67/MOPBwmJ1Cp+6xOEvZhMjuNQZA1uloVMy5cajNU/1hWRdQkzLpHyH+ats9XrggQotuAvto3euCrvleIIHxA+PF
# DATA Tuw1VvcJMFULwWUCNQmeRopWLequBiVlx3kjSGfEXcDWdK6aadG6XbjAhHb5y7eoJH9ud/ibPaf8PjqlQ7X6kIJNAHsFBJ3xA81D
# DATA Nw+6QB+N+SARyJ5imD9Qu76BQahWQ8KPUQBkqEB+pA6HF0xqK7EnqM7u7eJMQXOHcZ2TbeleaooDvl5wHHnSaTB4p+eBwBijtmMY
# DATA xo4lwknd9TdiY3INiuqxsr9ZfCO2rvgabLCvZKHJeDRgbzB8phaggXbwGbsXOsCcUveiveIDqId7nCBcqyXq0Q2hawHVeL+LxmfG
# DATA R3Hfo+PujiaTWGDfaxNJZ5H8SgdwGqukt/tGZYRoeMa9v4KKa2g3rcTUrkwQnYwLJvQx8KmAE9Dt7GmP34PRaFCTWHH8Nw16Z0qr
# DATA YAgHJ9zSsw1bBYUaJN6tSDePn7XQjUPJM9kY/qjRNpK2PB2abKx57gf02t/nE+5CywzGDjjnEecXQtaATgIxZAEaflqsTk1daW/w
# DATA tv7QFwM9aQZ5f+FkgQxg5ZyFP2GS0OC2m2cng7jYv1pFBZj2sTl9BYeBjNA4bnSU9UskhZyzFR4OgXEUrLUwnUZvkIGLSlFlr7Vp
# DATA rvK+Du4onZNM8Ur9AKzpKKPK38BU+Hd/iCCh8hE5qylOMclO08FA3jKNEs9KL+TJVNNvbE6+szGG58mqDGeAMwI8pEaZUJ1CfOvU
# DATA quBr7cU11P+Hum/9Cizkb/6S7Ty/dO5V5s5k2oJbGertVClQ5bnYCmCcpxsWxMH/tfUpsdPsiPpoEA10HXNV2U+MCh40pkButeSC
# DATA tHswmvUOBynCNMZHXTjXyYI+Mr8g9CJUZgJAjkG9+i3awv4+2n28UzIotf9Hk57RRLNJZwGrkdXA65228JTYL8yMAOR8Ps1SNEyA
# DATA oN9LB+rLt5uBn5CDBahw/xQu3XAr98evvUdMl1y7AfR5R717ot3MTT+TsL2MBgmjX3CAi40Prv+fs7r6y6rRfV5USf/8zV/4o0aV
# DATA PZ59caLhZ83QCbO09MO/2Abm6Ckl1Lp9+xbztFeT9CzYiCQ+JFzK33Oa2qDC3Nq3bHPz1gLNmXbm8QUE4py7E0Bml3TcxxZAeLGz
# DATA VbdjukBD0q35y/ffyJTw5q+jtacbdWexAHaCcSh+Hn2qai64LljkCXZd4AXMj9MJaU/nWGvZWSNkeUVC7MgzAWMZ1EoWQ6xJlBI5
# DATA XzFaymeofnktbovSVgK31AQHVrAxW4HMDqCFvmEkn4wGMBk1Y7FyjFJ29MS0GK/KmqYWsHobD8LgVC55vvLWdCYmQFb6bIJA4Xux
# DATA Gvveyv7l+lJoTc4yrNUjGmaxLl5JstvB8eCSies1qSbTZcYVc1I1QEHcaIHcadkrfrHvTEZ1pwxPmX8G/4vFewkrZSstt83o9d8h
# DATA Vf1L9DH5OZgHf4nFKViOzOLaqgh4gV/ip/ScudLP+eGvDIAOTYknT6mHqK+El7RMsZ4FK4S1zWy4AonhvA5PDgXaFafo/8HYuj+T
# DATA U0MeWIiWY10SyQoqSNFB2n0xGwv/BXpALhR84hoOTOKcjL70PSeO1rmhwSNLJpG2KlC8NaGETn6OCNOqtQJIxVpSfInV1Kkn6r/g
# DATA 5Ejbv2Xl6pI06xeY5AtEJfOTLkMtdX1VP8bHALDaUn+Q5I6YeDQQ7hb9SC4EgmuF9Ouyr6CIJVMhECh5x/Jrn6tXc2vPkcIRepIC
# DATA 3yTFtrUXqvu807IQLrTX7Zwq+oehMVxre3V7wV94NYOXH/Icxp5ZoFinuCC7VdOyZIeHih2BprHNricOBb0WpoKcbKLIX3GU56bT
# DATA DgvTOzMOprqTTh8aWEFoW1wVi9qCXgmBjuZpW1RZNjejWr3qLvwQipH237PN7DHKBessgpouM5UJY0Zz5TqkoNimTrvyCsrgHmyQ
# DATA fbca8pZGM08ApHpZGi/V2NsNZlAl6lFHHKbDSZYf13TQqel93Zdn6hVWAX+tTEg3uVR1iCa13Yu1nu5wlTg62Pym24HXAlUIQYUX
# DATA 76H9EqyqBO/cHzbzbMr5AGoxZ5IgbZ4LfIE2fUCfwI9b4ezv+JJOED2LE8/sgyUcsw99Y5ICgp8LOcbEpjmHhRbSb+MeWX6ZTpYH
# DATA /QOLALusmGq8uKvy/2UuV4ZhEnTrz8gT9e8pPMTEqRufU19joS7pStL4r/L2RoLFLzG2Xcosn2snJPXf/ygBo3COtX7uPAZlDBCZ
# DATA gz6mb4g5NR9xJHsm1WnvZhNIEKjK8Py3SqcGWWHa60Dmcy2EC2A1UCYP+j/Keh2zXfZ4E1QvaLUd1hsMsRbcACLN37KmurwhnTEX
# DATA 9svKvhxuYDtdVHcpsL2rxghILGJv7ossjOA/LCbKqbg4oWbo7nkp2c2KdrmI4HDn5SYt+AQ/MMgNONnWU9vsIJ5XEwThf6eTP+Ll
# DATA 0r7cowoR74MXUF+okB3IklyFugc4AWYL+oL/V9/HAmMh/gJVgV+Cy6a+Avyq0mmcj/Q98rD4LWNf/owkevILLJlrJ7nWqzN7CubR
# DATA 7z1DRfeDVezdJGARxxJg5i3xtlNH+3QEZtaBVQ+vEa+z52RUYi5Bs5WANrWcBpNKmY29F+9wD9wt7lhKnuBgLbC+2OqPMlCXUnr5
# DATA yv3OSh/zITebFPygCDcPe0ln4VKxN8YVGJXJP3P2Ctz+gAWwD2l4e/n4R87Kcb+k95bqsTgunEvOCGdqSotvy+0RLEBj4TWMM0AB
# DATA 2o1pkXX5kkivl/WewgbF74APeCXIeqU2liuEQum9ORbBeiSklv7hpQW4klXblm5VDA3jOWBpsOX/mVTJ3v0dQSsxdrKoFfhyEdb9
# DATA BaPpurA2pOv7Bcb5AQb6b61+OTDy0ID9N1oIwM8dUz6UZEutXUFvb1Bt2kAoJEzvBdZTuJ94QXZFR9vL2F2xaQ/HvbR7b2+ERSme
# DATA tzT+Ze8l+mBKwalGTqhNsLDOuamIC9W860otvEau8UToAoq2yJIKUJtgvfzMqJwsM0AI9Y0HR6fxkVBpUq1LuIIqwRvAvGCMArim
# DATA Oqyb0EvfSfLnnpx8D04eB4Lx6Xzzn4yrP+jbneJGofc5Unepw9OKPd9zkxPmoC7xC5Q3JA6m9l4Pzay16y6qPcFZC3gZcyvC83zu
# DATA etdJG2b7EC9+8eYu+C5GpiHpDk0uR72iEIPuDOEzQRprQeaojj1H0Q1n1dEZO+6H5/GH21ubu531zUedR1tP1jY24RYhDQRi5E/X
# DATA Ntcf22L6jZVrQIVNubBFCI566E0ieSNCHA2kTq02AnhZx6EFjxrrQRf15axU9+Ua7OW19qLaeXfOlJj27IPO02cfPN54qKdCN4Qe
# DATA 4MX4EhcNr8rPcm9IDjlmXvZcbRbe4Yeoa0OZ7jR9mTUC6F7GVXPJ4B8F9mpg4wizR3DfcEGdTUxSsDaFzEuy15bGQc882TbGwqTY
# DATA jaJI5MhMpYLRpTm5bnB0Osx6ToMhzy4plrlf1MPLldQdZd1+IhZkTsDnlY9S6CDsL13htHyd2/U8cKpaFWfqwl1q3pWFo/xEQ86U
# DATA Lny4NPgHl5wCXDuydljoUBGM2lp6+zbmL9RXQWFdVmnaL+ske3+x3Wd/D81L+CvBrUTfh5zUuNRS4S6kyQp52uoeoMM0e2aLKN1H
# DATA xlwtiJYHdkikXDhqc50XJlWh2n+9jqCNxgxcdkKJwZsvqB4yMrYjaUsibaCRpqkMdBAdnKrFh3Q2HcW+l/Tbm1tkvaUOWzKzBQ/L
# DATA FjQGOs9pCyvWY1vEeQtVYKUeKdxwW/f4yn5ABT+vz938Yb+8VwJKb2KIPLE5trZVvVtRnmvjf4XZo+1okRUjYA9E+gelQDCHtH3j
# DATA SBHcN5tAKmxFU3mTt2sOvZOHIZmzbQ15qGxmR+yrvB3XOearlMpaQpJY461zqkr9ZGQ1TykLHlslij1Uu/ChrrJdaATdPPEO2+aO
# DATA em4z2HT1GGQUL1K3sklBauhPTIhUJ16Fuo9kjb1xgz/1yBbOhPTgkV7atRjS0HWPwco0ziD9uNo9/ZeKwOHPpNSdOGDSUH85/qkL
# DATA O/r4nkjkfdApw5AIgTXQJ0X8AlMRR7+Z31VBcKYkGTRTq9YoEQe4HOpXMPZ9esZtl/LrhCJT0MHT09hQ7GPHDMm9wjGgXsUnV5QR
# DATA 5lV0NXGhbPZCN7IyQUAu476NY+ZeVnt+2y/9i9sCY73WXqD/gfBcatU61NEDV9fGrXqgE4Go3Rd4j/dM/6IJ/SNZCgOmh2VuqtiV
# DATA unWfriZ2zwnutNbFkHA+fzEqRfdvRo8xkJ4QJGc5Z/kmAJU4j8azAzWi6Nn244hgyih5CcfDEyyMmuFJlufNxbQjFOcAWfUm2YCS
# DATA YgyZBPDmJfeo0mA//mwOSk9pyoEyvS5X64EKD3tjxVskfZQ7QteFZiWtr11/srn2ydr31jukp1FTR86cIf0HLotuJHGASBRlWHBE
# DATA ZVudR4TYLebvS3v28JfVzj3FQvueOnyhIxWoBi6loSltuQAzeg59iuonVwW+QdvskiBLIYQlw/JMpSVgS0ECaz4q0p8wLbcf7Bf5
# DATA tVcbMhLwfTLR7hwYZTv2TUhlgAGBNoAxR0yH46w/sWGmLBQTbsGrKeODKM59xnTARrKaesDMQT6XYH4wjxsGeNSJ1cKkuBSqlYTm
# DATA WQ/1dKJogo1j9DyYZKYqCkL0gjVl5LEM2pwbp0gY+ByM4vTFDDLGqwiDf8HfTthUqJiBSSJEfYYoznLeH3r6HYS+BVaVeaccK/rq
# DATA 6tUk12+jlKP0lOrMbUxRiJXfJX4keTjs0bfqafOOidklkb/c2GP0N0JHl7hwI2xGQ8EbJ4RBV4sZisJ9NANgjaRvHiTNOk013ML5
# DATA 7X4otU8eIsu84QqBsuCEOzYhrN2soQ7pJJPRrr1snJsfB7P+oMdBwup6gWoVMAdXIMDcqO3FjR7j8vE0kQskVYm+R6gDvUE5iFz4
# DATA Um+CCty2bLaC0hsx8bR3VhWdqrMbs2ur9i6uoRK6VQSEtPjdTdWN2h4AaWevsu5smh4MMMh4Iw5iaYO/FQVT484yLTXHauclmFVX
# DATA rwNqyBtjshEigYLOAJWA3CvozV1HrPDRbNq+tbLCCmTKDSA6uGP+XHeTAFzGQ0Pa6MlDQ4YCRq9/FX28u/t0p6HDdN78NOgCZAMJ
# DATA v9AYLATUy85F/4hqFnBD+rU6iAgUjpc5pktK2gOyJZFx2ZW9HOmOaBI5mu/TLRmOxCCjeYY6s14DqqX7MvuhJ0GwUa5Pp+y2PtRr
# DATA IHy4nwV2U8D12oJYLswkF7RgSMYngnLZux6dld+eDV6NtU1OaIsrNiMJUezaRCRVGPQwRxCOw+cUH9CIKDrJwWPl75YN1gHmmcmb
# DATA NOU6J2kA11xyVc0NuQquNHG0LwIWxMW/KFwYjOuuNS9TBQHQIB4Go7pYsNM8ABVB9TZnQ3RZOunncG3qjF541RV9SlzhgaqpC2gg
# DATA RgPyOmFRguq6fyeEYUsJeAIwv+LgSN+pxAL/2q7OlUDcWBZ7vtvuiQ6IR2RdJ3GIyb7ahR1U0i5OWAqt4oiBHc1pUgQAOCdNu6uV
# DATA sDduj1xsEqNsm0cHgkKAI09hWC2eQrcJidfMAxAqTw59f5GdSRTcS9JiC60qgn/MPC4Sv84BZVotr/3I/wmdS4Dr/AdHNf/Vn1Z7
# DATA kS9ga/EBlRheLtQWF6hWZeoGrrV9srCom28hH4OD84xxfD+bh/TcjGRSau3Xw15CgMRvHPccs8iVD4wje12GtrjIw9gFtrahPpBs
# DATA SB4h9bNPsYGhCQrbzjjtaxZZsL4gm7MP64QXRYUd/Jt5FgRP30MSnU1yUpLPqXzZbQInlqkonYzvk8+hW8Noz7dIKDndu/43yYuk
# DATA lgTSO7K9f8oa5nM95S1vBeqRnAOOrkAOLx4nTeHKrr5QcypLAkyqLHFRuEksfth1yku6uxuIr8AsO5tVNGLu/UGmqHuFMlXdSHk2
# DATA OYPDEJKSa4+GqrumL9RhAlAUm4LiH4tFWvjDrgVAuKimQmxpMmdqrPxFhj0pd9VdA/9lq3q7Oow06tZT0Nq4jrOOuLnPeI5SHCxv
# DATA 2qdooZJUvSdnFkZcMQh6BXIw/X/FVxG/tTPJBpkivB6zCg1Oa120EdKR4V10opbL6IPdTXxEo4sgwhxrP80RLZKZVhkuHOs4Q9AK
# DATA pah+KD7JDx2MBfczY34vB4qjmvyRGoWXN7F+uWC1lBALFeiynyUWy7K5MbWg5wT/uMJUuZ++3WTput7ZdM0/Z1Xidhmi3ILayIB8
# DATA Ydzg29rXtxW8LTMaHYTd4A1Y34kd9Rtm5EEjAup/sTr5h8xaCjlftX54OZt2l7HUsnWfxzJpLx1PGf/Pc6wP3w8X1DaU5qpylKEm
# DATA YRWnHMAfNcGeZGSzkZ1Yukre1TySesFVNkCxaezgGgduoIX1LmqC4mRevL3WFRWifxZnG4vqlgoMzUpFRtrzSW5QLgqJPML/fEHN
# DATA VaGmziA9G80wgMXh5EVes+CBLPCbUtYevJDAsiwtthQsln+gvl/HPxUpFldWR1Xp3mRNihlDyxfKMfOWkGMmt1kZwIc9eq0gaKe3
# DATA ICG8Qg8GxMCEFJCEkoVcit4NSA/qBb2eqbvJE30pWcQxk3wN64xs8iQdyzvIPEzExGR6o8S/qNgnctJaRB/E10WzbPueT2RIX+To
# DATA UVvFLZ0qQROpse2MvPAlFcpvy+KuGRanw5qDXXHyNHh16iQ+4THSkorUKk74icsd1INavJyO+8sAfrxM0Jwx2cKhDdoXyxpEaAyQ
# DATA D+TXLpKpNtHY1aG3Ne8d8r2P1YwP1LtzDfTby9IeI1Tj1J6M1ESMhv1uDRTmqzcJruX0GJCZCwXum89b5emvKfkfdomym6GXlrb8
# DATA 3ME8gIpdqZkLZZsWgW3+yrjCm/FvKBG2xaoVnA3UBIc/Ohj1zlw0Xt1T1ITVIDkn5+iE2SrHf/aw06FeARAQeEt7T7cGh7eq9J4t
# DATA ybu2nz8eqeOzBg5GYNipY5BkBV406V6smga1baAkQ8vWz01WHXIe1rlBfwr5Rn9LSBcQz/o7jJb7JWjiAoK9twbMg2SS4CbY4arU
# DATA RIQYTugISvSdZMUsVOhapRijKhVBTqE4j54923jU9OVCTsWK/laKDlH7XQ69u71yO6kiC4tvvvCga1s7nPBcpkF3pkINQ2YFtjbh
# DATA 3Iay4JHMB1k2rt1kRhlWnaJ9M+JIxt968ckUxqyVpbyaP3n9j+rv//T6SzaFAu4kQZaE0uIWwyV/bTJTaDB+Mlu+hfnzmpBz5uvX
# DATA /1cbfv3LN38FQZ9+7gwYXRzQ0RY5XbncZayxX5vg1c/HgBFQSydHuc34Bb+AvnL+57bWUcee6hk/a5I9Cv90dL74BLSSNiQoULHu
# DATA ZRzouKm+ugozbY61hzbIglWA4adBzFyYra01TFRDM4dQeyb3ySRHDqoTqTfXJkcz2D5P8U1NyLftTqc36nY6ifiyCZ6BKX9Si03P
# DATA YnBwGIHfR3tPW4aMYUjD1kvrvTbdi9Fgwt3DkUHHCjWobooAfldH5OX2U8o5qDi9EuN60rwY/tZKKk53nRyB9ZBQW90lJYE1jNRp
# DATA 6100dqa6crgcNk6oZ7buMoTdBepC35TkXlkZhqflYlW1qbu6vsjGkN0T90xMF/CpWgrPfqdDvY6yRh/Fc4tPCrs19gwLbDVwErEF
# DATA uwFCpQ16gN2PHrlYFv+B0nktcSjGcOSCEda8gwYkV29j4IdEMirxurnJjMiwMz0uAjfi9AQQuLm9SOzTiBqpIHa6kxIgsQ/+sAyq
# DATA jp/QHdMdA/+mReAffPXkXzZKjB8YNAb5m4KB8bdENi4irGNGYG/uk3JSR2FomnxIkiFJiSAfEhaCVFqH3eF04LAwxybs0dvStMSo
# DATA MUIXMMrQVYsVx1ZdSThD8cPt9bVdnY94+9En235u4jplRrLN6MTghz1sQCbJjU9jvBpAC64AhKNpHsKLGvynzk8ebz38bmf9U1fs
# DATA dLllIByUdglK+L3ZyTiXhH/uptEqCkhWnoMndpp3+/02+1OCOWo4bd9MgAGphe2g61yng/u104H91unE1g817x8NZye44PBnOmju
# DATA bHy0u779pB7Z3x8/eyq9tOg5/VOjCkxKvhsddc1H177+tKYvJ46gQxxRyiU1KY4aGfW72RmJogGpnMSvnTNFhU/WX/Wnwl7r4aJl
# DATA VFlNC0gP2YEd9zm35IlxiQ6be/13VlQ1lxEjtxZcJoLue3Nc9hCl5yeYVx2k3881IMivMM36Fwi5941F/neSTn50oI7K+OwbX9n/
# DATA IGH93du38V/1P+/fW7duv39XP+Pn779/9+43opVvfA3/m4GHrGryG/86//fNa8uzfLJ80B8uZ8OX0fhMsY7hraXr169vZ2lPbXHc
# DATA HupauvZ0g+CK0H8ZL6t5ND2ejGZHx6GYIVW+qWpZYrKuRVf9G0wpcLDgkPam+qm6reKVkX+qm8uxumPqn0D49N+jfAn9K+DuoYpo
# DATA 7gHCpS4yMY0pwqL/hDb13/IG6z1z+uoqp8zTWb9HfWAaofuAdylF2NQFUdHS7kANKDImRLrwmduUkfDVoPnqadIAs+5fMcqTMSRW
# DATA 6ffUC5nzhLwtkOdxVI31z16SHo3V+YwxlFSR3nza6w+b/TydTs9qRZ8wdwTxE/J7jEQ8j6p20gevbBIfR0NM75QSXvGJ/r4VucIf
# DATA d4mXvsn/1mjYSJZp5ERc+8PxbKpfmundHG1npBX2NYmgS9DvWKHIQ6PwC3rT4eI1ENHxcqIY9Rg0/CA3neRHavrVcVBbvg7J3VQb
# DATA c+cHGjb1qz9+gLnn78HBweNySNE1qNKBiCY7mLVx3/aw0+kP+9NOh3tG+sjRC7URYgeoxOpX6YZowsugr44/M+d31j6B56ToNbgB
# DATA F0aTZOPRwNzkprx2E15TVmj6U2eFDjrJeXP0TD1L7RygiDWaTWUq7Hpk6tY1x+HxtNsa1QE19bb3ZqCrN99vrqj/twqDxQzCUAZ+
# DATA tFqr8cUiPd7OTkZTpnW5vsSSQz4tbRpRauKdnY+j6WwII4PDACViGVEzOGziWuJfuKC0giar8zKIqvjC/Yr3IXp7fdr4cDQ5TSe9
# DATA rNd4OhmBg11kl1O+VX/BOzsDFzR3NqnDAhPEcOEXbocW0u+LAwoSpj1/8tgZVAbUEICumJ1fIf2bFlTZ39oJjMKEMWJewCdxjBGO
# DATA IlJxmV13btyQ83jhII2axXD3Apfdi9co2eOPODAcdGofZOrGNkGaZj/3c8r6vqWoqy/NRcgf1fwDze6t8DHSRZgWWhNxJcC3SZPL
# DATA JuFxPKQkxI1dhlN1J+pV4/T0FHPuNUyrhGdsWyzOrGOdhoTbikLDtppAkGDtlgAsgZP60fouGxBXkwW8QtVGKe6wbbF7YH7AUIVb
# DATA ByawDf8xZLttyLeDAFJU++MtT+xruk0iQ9BmoNvz7EButmvXCnPrprbBCFNMmSUGsF+5oiR6EPnfzjOQ+MQLRDjdG8hBqu5ek6Os
# DATA xKmJ2bKT3JF6EnKZvZRdxPhMkQQRNGhUGcbc4yRr9PaXVzPQuNs3v12P7qzchP/cgv/cvsBiesPej26Gm5bWC0VD9AdJ6eoXArXn
# DATA LQxu5ugw7Q+yXgs5RqSdRe0gEhmrFViIWtAsU492afOGjDQVk/d7nxX1yTBDJSVPzD2wlIGPwIkq2o2ebu3swq5A7zo/iA06p253
# DATA J2MKqbH2h2Ku5hoGjx+qjT51ErrplOu9aVPfWBCKzqu6DgXg2Y9U683ZtBvS3pRW1s9HlOCUKmvqXPPx94H1vrey0lpZ8Rzsqa7m
# DATA 9EegfA+HKZnmuKyulb5pBzvs5GRvprkuUfNLN22fE9tf7qrq9PeFKW34MpsoOTQHf9n8h7O0BzLdaJpS8kdAx0j7Q1K1GzdauPk5
# DATA LJ5zO0ItZDTW4qhAV+C7zETN6mwwQHDq2iTeW2t8P238aKXx7U5j//xW/dbdi5iSac+V4Z9pkbc3yohZH/anKL33LM53RPPgbcxJ
# DATA pj7E4BqR87Vzko5RQKE7EQgoaw93N763jpp1dfNSdyfwk4kfbeysffB4/RHKYf0TdZ/Ex483nmzs0tPs1RjMJ/B0/dOnG9v0dDTs
# DATA HFP2IFuFyedj5449Ngx4vu3d3BkZvhiOTodaLxDpmpYIieIEAAlVOz1MnEyLzt5Iiht3sADBjq0kda8EfNaZTtLDw35Xl5HLuhLd
# DATA b1MT8Me3V1beX/32t2/euf3+7ZVvf3tV31qwFPYgUGje6DaG6OUZcS/U3p3BDTY3iwj+tEdnKJsFRtaB3Tvt6GI0iHg4oudx0pyN
# DATA x0oWtpBYuj5zQ9nc6myv7yjqq9by0dpn8M8n6+vfhX+fbG3ufgx/fLa+ti0vK2ULlavWRhPwScbmI9stcpNJJ3DoMGB+v9Aj4ALY
# DATA kLRWmtHbft4z9Wg0b/wsOsi6I4jGNwXlMeDcRbTj9mAm9/SW3N+Xu9U+xg6Z3W118n7jW5udj7ceP4L6z/JIn4F7aOh6SccV+FqP
# DATA FbnmBgd5mLJTS0csgSIjsqFRlJMRVltCaXw/m4wUA02HeQRhoXhgGUtDkopmtP7qOJ3l6Cje7VLahRP1O6IGIj7gTeeCC5v5Qdtv
# DATA 1Bw4NZurvrsIzzPuKUthNPm4CAcS4cKYQhV+ytRsg86Zc3/SW+Sa3COei5W/ZNt6bmnSI0yNrT++Z5FjosPZdIZLNQQzVB6hn6nV
# DATA K8nrdWirWqMVdLtiDz3LwTGHkrYogSb6kVrce0penqprPXXxJD2LVKtD4gXpAEEPonwMAr+mHekRel8uOaz43LKtFjsH6y2uU1wb
# DATA 2r4GF1grZ9B5oFcx5Z2wNIgfawPETUXsGqs3G7dWd2/eat35tvq/7xcwJGLu6WNYzQ8gTFK1xyTcebejCUfLTCw4CSAL2wD6OEwH
# DATA O8DXEQsIxFXMmgd+TDXk90lSQLmKheUKXI7NSBQpZGDKOMS5SPvc66TTuCCm7em3a+jUWJg78a3I5dVHzBDbAj+LZbaQmSCmbfAI
# DATA r3GpJGqoNX05gAhInLXRD8gonh+nvdEpREjmYhi2msuQ7zFodrqjQUucBRa5UOvKiDykfZbpxPk7JXVhcpG6jrGFuMOa7TUZ9vHn
# DATA M7VwoHeqiaFoTZ8d4FP9BEvKoXrF89wWdVEVdN806+P59OM3vPuCVnhz6T1dC7m50SgTP89AILKwWqNt+mbVkK7KUeTmsrPmtqB7
# DATA 6p4GuobIEBDu47dQtlG3fSoBv27dXKTPT3VfjT7WEVWlmMoBLOpPFFUnGadic0knHyUaIpyigqmgsFThnm2OouIWlppdmT9ESP0O
# DATA 8ku5VtvKssLvp6Pea+KRNBGuUqhTNQye+nOvsbrv75PKa8Pq3frd23BvUM0liyyMjDMmNa7W96VRfgxmItgRpDMeZEdp9yzgHMoT
# DATA WFyeGKvAfYfBkbOD4vWtbjibcSnDbD18EwPbzLCX9Xg034wemqWJlFCkNssUVZTaUSvKXqoxnB5nVP8Jam6QA6cAAgVeQCDB8IUc
# DATA 749EifrZoIdSpnNlswenSFZcyoHUVI/W8st6iIGVca59QxQZgpp65ZAkfqPnhawIepuBmyFINfot4mH7922cfLy0GnDnIPsG/oS1
# DATA 2demXlmkYLazdavJ6R8NkR2d52pmaSe4qo3cyUWYk9sGQnaZwxNk4ojOeSE3FHA828PgR/tItHS3bNyNJj8daLSWjvvO1VuTSfVc
# DATA a3VrqH2CwDoIMEAz8/LBWUPvHQxHcGgCiGQmTio9zMAwZs0EEujEmj6lD7qxkhbzugtdkloWtQc7xGNoHCK55gEcLR1ikqOeGeVF
# DATA sO+gZQdS8JItA+bS8ujR4WGeCTX5Sj1aJS8It1INsDV3rr5DNba15pB+IqDQH6FwZ95Q9S5jQxk3DHqDrwg1cy/GX26WNucFbm78
# DATA ohgDAAWtCgdRaSDNw2JUFaefnQ80DKm6zKEhGlfoHmkD9cM0QvS+SN27+6Ne7IXQgVctw4/ucW/2iyGZRZVTQphpvpmovN+PZmQs
# DATA yVgUo6Yxii9HHDPog8kb58UfZkNwn6yF+pHco7nQdxf4kfiZFLEEhhDjkrh9PlBC8QufFToTAt0U1TwI1VKmTtFef3rYtEaW84t6
# DATA rxW6F650HavgOygovTMwTrFOA73YHYht9m9qUMs6fP+cB9fSp5U3bov6cOFQDCyicdFmQ8+XHePSyA1yNh3PpmX57MrsyeQNY7qM
# DATA 2gBYgwOwJat6DkbgTQO1xSWJip3GFV0bDV5qw58py3gSMj95PUIfZw1cVY98sIn+ofheDgp9a4dnNfFW8QKoP1lEparGpW7wEdgJ
# DATA zuAi40yADhrLm91j1aGaILKia7yd2uArQeOnJx3j7SAlX1HM4UhgfxfuNgQ0+/DZzm5n7elGZ3fru+ubQFy3deJG9IEi83BkErJp
# DATA FXHbqerJ2vb3P1jb7DzbWd/eXHuC6hetM017SnhSNRiXHpGMzojx4eqeru3sfLK1/UhWpz+BPonJMU4F/NOwDJDQDM/AvixjUXMs
# DATA WD2h/5R3upZp7YKt8shfQSaA0O0OVUR8Aa/+OcbNWgVYkHH1WZRo0CcAZWHZ817c9yQNeRmBbWjln3Zb+zTTFx2s0Ao+VH8yXw1M
# DATA n1N5e6PC8wL19GSWT8v01VhdMUHfu8Umxv4h6+3k/R8JYLU6WSpzFhb2rMiq2RS2URG8OE7PwFBbl6pd1/oSmBx+aPWd2ltY38nU
# DATA 3QKuZb7Vl6Ij3NUlGU88qOs+Cdl/vwCgbCqT8peGXdOXFl3IVJkszHsFJcCpJNgvsvT3+oeHGcJ80Y3gHjY6UnMGvERJvB43Rrdy
# DATA k7yau4LHguc+1pOvHuo/ZThJKzhcgVOt7bjuMNzQO+3iXI/AgaPU2xmrw01lu+wdcF+goMzZmEIpmucb7fZQ6x61DYVJNE1rfFHK
# DATA oCVysmXLdCJi6j1MGv6hnuBGxVyNLX/nXmilHtiVDllQaEXnVsi4AOkw7Z2ph+oGizGVs73rekGuU4KjmUZVgOJat0vpKbpKPKFP
# DATA 53wGijrFtqc5N0/dTy5i2UVU3qBXIJMNSoehqmgZw7/NXWN4MtU1j4Y9nWSqB0fHU2M3lxxR3ddJeG5G22j5iOwyuIErvclZRwk9
# DATA fgxC/EitnnpuAuHIME9ksHh03NB2E1RypggrjJmcOuOH0rUYjfnTY3VIoGvfwZ0eqQ+AzaF94QwU1n63HsIGHZSPF2KoRGdY+gDF
# DATA PGuHQYW9j0pRXnD9gKYRf9l0MIgMwesuL2pIDMAGSnmFmEzs39Nm7ABZLKfrFumwmtZal9oAimHwUlfqbuVJUCXCAx1WS5EL1TAt
# DATA c/dmuLVvRmvWNwnsK0r+HYwUu2UdU2SwSMgDHR2JAadj2O0DDDTiZEcHSkDtDc7oDtgMNuSEJL/9FIenWV97Nffi11XMq/woP+Tx
# DATA kjYbwn37sL8nGZy/sTnn05Gdj2A8O2x1YwWx6ZeLY0K19CW6rqu2Z6ay8pDL3HzWrW/7ig11MztsJDuaXzvwSqG9V8Ik9QD4jO8H
# DATA 2SXLwgH2KLh3gMGxMpRZHDVVyg13Pl67eefuzrMnO+jXQqmtOAyimR+n6mVt7CGbHmevev0jOJ6o5omQeYwpL6L6/XwYkzkIJWDU
# DATA x4ub29FgdFCLbzDpTxKXhxJF7jEX42m6zlvo+j6wOskZZSHznIpptzanDD2EApbr+Gsxl9GlE9RZk/nrXiSmG/VKOTY9U4/B+s6i
# DATA F/MpJfnRMR318FDFwejrKwVeF8N4UR4Ch9rYj36+FyguyE7wm5JW3KvUQi2R5mDRBvDq0oCri47nRs85NWmpmvb2qrqhhxpBKa0Y
# DATA ES19v7Tu0FYmXpd1R4knDcIjC4Uyh3pyhmaC0sDn4gf6JtTgm1DV1zqQORjDDDttFbXk7h0QHt1ZWRHyg45HtpPdilb/+0/+lzvg
# DATA B0j3TWNTDNzpTKoSDiSdG9A5L87ykncREYyJ7sN/vLO1+Qjhl0uvKkRwrnbjME8NkcG0DSRVonwJehvy0msKM5cgANi8koYB2VNV
# DATA 0eZwKNVsUh47urpgiOW/6P/5qTG+/vjP92+trNx04z9XV1dv3fpD/OfvN/5z63QYjYZKmJ4iiFEvi45m6aQXob3iXvQiy8YY5QQH
# DATA TPEQRBFAv5Qz6wP1Uh1IKB6MBMUbHqeVEiGc/ISQCExcpjqKw5H+0R9z0rm3jww9HmSv7I/ZtD8wv6apifW0OV5MHGl2MgZSsbS0
# DATA Cy6GkU7zB3pignvD2YqXtre2drWmnsBCTbkGIscZOI5k6dH6h2vPHu92tj7ZXN/u8Jfx8mg8tR/FS882N7wacyRKPf63rIGmRn5K
# DATA lh5ube5ubz3uPN3eAvA8t7bZ4emyzPDW7Pk1whJNRtDjnY3d9avWkpPA/mTt0w583vngs931HfBmtBEu5iU8V7Ivjr2zu/4pTkwc
# DATA 7z0b9qf7S4+EGGa19bhnWQ2Fi7G0BnfJ9jCbno4mL4CxN9mVpwdQ9hM9QUsfoEdV+0QJIX20PHO5pT1OjLe/BMyurW56kNNtaf1V
# DATA 1t0Bf8G2OUx8kKKqFV/GXimiqyFQl8gXErsJLKathJWlvQ0CcN1f+iQFJvXBWaBjai70Wqx/uPEpzM6enYlNmAkMUtx/DllWB5BV
# DATA Qj9SXPAAluL5UEqzhG3Qo0k0JWDr5+1YGMNugIjhJkrC6CsHTZOcCNxETvQd8mgO1YJTz1V00zH4enZINqWHFXkyqXX8r8zTpKV5
# DATA XnAnCsS4ZBpa0uyPO05JTAXV706lfcaGXsANtP9qkCGiy0qE0Nr4op93cH26aT51H88w1yTeNPxbjcSyW4u4WJdDYzeeQj1q/obZ
# DATA VLrkxI6ZklK/Q1uJSS6nlhSMfqoSNZj8GEFe1KwfTPo9dWGsRxgrik/bKyYUnWAi9VTgb5aN4Wu0KOElEjwZTKVJ9OPo/ObNC8e0
# DATA y28eRHdva5shXBlq40Qrv/uUPtOIxmP4z907d27dsXdWqqVqxrTOGdgRlnYtzDxc6MjqzW/pnlT7fDVb4PVVX70DTl8HlJr3AHqj
# DATA K1ukP4+QrPAn2jMzPekP0DO5P76LQZVxKyYvBIud2R/Hrp3zMD6nDy+iHPZrdI7FL8CNHEJdWYwn1/J2VIv7/UNUAJyjNgCuV6RL
# DATA kJGiYlRiSfUAKQtVZJpAmZxf6vzgxs8JVtVuptDyYmCGLWLWeZF5JDolXAeYIOHETLvjqIdVntvqTa8RP8C2KvvN5+ZQ0U7ywejD
# DATA +TpHfn4RnZ8vga+OqueEoFvVExwnFuswq7gXHQ5SdedjonMvurhYijAtOF8/oBr6TEkLoMk8Ho301UTdOkYTcLNrrK6oqyoY+s+4
# DATA 3/fUV3oJrw9G1/mxetqdGjxpmpzeZDRWz89pr4BuWszIeXRu1/4kHcMVq84nKrlQvbUV26/+rR2zeXvOU34hu5Ch80o/P856dZ3O
# DATA t6uN+RReAeKgqeQkm6bR4DZ6gyrC+/Juo989UWdc/eflXZol1eNhrzHM+kfHB6NJI4dJAY90+TDtgU0Tn03UpGf6CQxHHSo1xWNy
# DATA D7l5585lG3f0LsNJlqrFxDyD4xSy3TSmo1HjoH9EbKah/U8wl7RaK+iLakB9cOLMLa2R3RuHFJhfsjv02zn7Y4GdcOWVOmdaciE7
# DATA r/4P5AwD7dgFvatRkzFzACawxN7bOnSzAFESK0rdUULo5vrD3Y2tTYrhY/9ch3TbStCB6TZB0JiH4MerOGuvfwQfCnUCdAa9pkCt
# DATA 4JYPYUsBHURkYXDEU8JJjHJcDoKc4nCUknMXejjtqQ1HHYXy4QTVDk/BE/W8916MiY6DiTOdzkIhPRN7prcFJNbyrJOOxyDbOjTZ
# DATA trFe6JmBQyXZl3KNIsvHoENG86dtieGJk75a7TbzMnj5Q29C7Mr1pWuttJNJcOLStjklN0A1qIp0G97EUVawnG1stKm2OKuTDN2w
# DATA fm44A1qzz58bmPsm3wC4G00q3mRvPy+Dk/c/PYwVZDZk8ttEmx7q2njGmPUcTBD7kEpt9OL9vdbqTb3KWpIjZkxU2khrRqijvNfI
# DATA stQsDowsIpwycHKHh1OKHyUID/yA5jeDB8jntOTuiri6piZ1CIPnMZFLWbV57FYkPvT5+zaBJWnbVjokOQGXPFJ1U3X6jKbDPNU0
# DATA pHYY9zL0Jiyy6+cEUx/qOIrnzPdBpMEpMxpSPZxGF/97iP+N+RIj2k+KX1SU5Yx+wEZP+8Pe6LQGMBL8t/G4X0Mm0jOjVr2kiJ7u
# DATA YARBcOhxr0b1UPG2gxFKUqCLAUyWiE981J2kiqjnTXM7udrKBxesqrqFVvxqqy5OgpqkzVE0OgVPd9I+9cGRC+/DYANVN0by1NJX
# DATA 6lzxuz7AgwIGZeWk5DgV3pTERvKJF5sf9BaySxuKCBBhos/GR5MUz1JEKZx4TOhAAI5iGgCJDjk6CU1z2rGRThvXlODNZbux5qJQ
# DATA QjaZiBzNhYh7adH2uUB5oXrVWoDgBT106yYJt0KmlHUlxdNFJx0j3elQzFmsGOXcbyH4wEUcJmvBhZKNqlm6Wos8R/Dn6p0T6oOm
# DATA AhJam/UK7GkL8KLGjxijlapch+XFaDs7nBF2SsTl9e2yV0fV5GiSooOwVlM2T16AanAMlt82NkWuwAi5cNh/1Y6buBcbIYhxD/n0
# DATA sGcRT6FuD/EUWqMxk77FvDU+vaaDNBNOCYNSYctYeHHETBucOSdwlFOgFyfzNN/58kKuE/baEjopLSDicnZLe1VE4D00Bl1BqWmX
# DATA 9eu+GasegoYGNdnN0+O+kkFj9cxFyFAPSnNu06AL/t76OW2bwmsODPSKoEt44GugYzUQ7DozNYZreD1Qklimfs0pjxH5fxStjFZu
# DATA 3qyan2dDCAWKnn34SSTWS9crQw+pIZ0KVphB1XWRgbh0IeqGT/7haXOns7Gzvf5RTX+l+4qjkQ9LBux/VxzjW4yTjvhXrRNGKZtC
# DATA ke2UoacKKHYp8a4/3eTx6EwvzICxiq/e9HLzltVR00HQrv+VexdT3+TdFPSPOCEoDMZ7K41vg6bvzsWy4lbPwZWA6koqKTDMOPcE
# DATA 83fMhic8O+SolIcIqaOL8mARiEtQjZoqsxOoJB/vRTH3M/FzfdXUsSb0fmBAs7HOVhda8/KvIQnLAl+hj5id9DCQna1WpJ23nH3R
# DATA tjhUH1edifgi+SmcDhY7V3n6v4IRlI4i7BXnbQjek+9ozWWODjbmmfzOZC1gS8GVeKAxD4JP0cnoZeYgOV2VQzFSeMsSg8uZKljp
# DATA WfDGEYYK9evm12KoQArK0+RbLP7/x4HNQB2uZHiFWU91J+roNa2i+P/SmLT/DtnXA+Bel2Df4Umax1SF15ZicQj25mgfn/sc/yE1
# DATA 89xl+ty4y+6f4lKwCaoGfDJtHK41Pmy2lvffSzTjr1kGWvtOq25/Jd9JfI7qrwr2cu4cFSenkuP6O0lTB2wMNKoujh7QJxIh7EfX
# DATA 2kxb4M5NFARsJ+jpSNXc3NdoEnXwmsUvvNO/+GgOssEIwrWmI9WR0fQYw71QxyFDzBTNBREuvJ6xhdRVV3ETeBYgvw7juFHbCzC2
# DATA fTEzKH7tQYZYy+zAvSa2qDLxdIS8cHgWG1ak/psIlF/0bpAHdy7zxWEwL+JRuCm153B3j9MyHIAOdv3KGK8ZtzMOs7PCMiGNryCd
# DATA zJOuitWXTNVc6cPFDkFPFHnDNucCXb0Kp6S1dOkeeXN8GO+dq5m7uCxRYiO4uYOgpbvE2BmUnBdcSLsZF8qLpre7J24FZpklsEGW
# DATA DmfjzhiTMxOCsXbQd84uvNNeVk7qOQraJwVSepCPBjM1vQSE02yydwHpfKZ5BdM+1AyJe4RftWCap8cXAlmqqzYCJsNGKKkbE4i9
# DATA yTNKh8cSAxgu4Od+RcAqYpe2bW3Ngce8eZ4h5e3maPoheBgGQogKMFEMgIf8/vHmd2vQjuH1cwh0YQpYyFKzYPp5IeGgUMYyAfl2
# DATA ZvB0gN5sYhdT9tD0ioWNlZCVyem6ETd0bGyt2BpG08kuUXidU4mZm+/tfpok4Wb9KhwZ6tHGtjun4UoI98OrqFaQxpyaYLr0A6RS
# DATA MLJV+ZSFK9drMEkuva7IeeXihFaYjytMrXdWEcybzirBqngdcg5s4YAH+EA4ixU2wDmqtjYff+ZnqbK/Nz+AnFIOfao4Nz6QdlVy
# DATA q8lBSNfLhxe+wVOLnAX+MxzVkmr5u3TFxVGIgjt/0d0RwMpcbEd4xE6g8RvJu0a+JQ5uO3srQNFk4eYfyp1o4Ni9HvBC4dWihzEU
# DATA 6rY8PWx8ywIs8+bqHvcHvQlvGt5/lZzFsmTJQYriGHeBPQd0M9aXQO+dHI/PhNrHGA/Fvx2kOOAd8BCBtgpvpdsHN5IA8KnxAS4L
# DATA G3RmdVdNpLoYnDnLmgfW1QxGc1TsWdNNZlqYRPxCziJ9xVftwxHIyPpinjPzDrQ5yQyMAP52FluX8MUDJcj4SOaopWDQwBLLAmFb
# DATA XcaoYLi/NSs4eYPcbqFRshbacODAHt5wfKYcYoru7suE75bpcMnVu7e+ddvC0cBnBXHfp2XQuXHan+SYLj4PwbkL5xAGhatrDLAh
# DATA +mYUtyXDw1EVC+xEgflEVl5yxEI8BF/7SqB+ACnnAC4WIP0MhnLmJvom/+nRAeQY6uDQO+BI1sY/nSMu4eGmmEUXIeIW2RViFL7j
# DATA sXrEmwJN9ST61+DvSQcyEtr9ivZy87yqWRL0B2oYaieyx3MeNRr4NSWUZaigU0o/A5pyZ/vhoRadaFrJuLArLW5S4kyyt8mXhHjp
# DATA GBto06I3Eba4jf1DJRL8LGxW1wVVqyiwFp3bdj8xKHrTtHvcYdxjMSJUz8KaX2V+t6k6rr1yhot7h9tFD/kkbGyJ98iTen/Pomiu
# DATA 1O/evIj9bldvOx62/sZb9Hew4KRc6SIuA1W7TIb+WP3BrdKeQJEIooGhMEZ2q6418+O4KM0ZnZ1D4qgGh6qxqPZs2DfxkQVQC71U
# DATA 3AEdkNprSR0YJWcpxdwo05WIUujQqLpMRaWTI8R6KVaVy8hg3QnSSS3eQd2hGvB5rB6Pya2IXTDzvdZNxA/ci73YtIM0P34+ZN+d
# DATA qJHNng8Rnc6hpbARqRpQ0SGGN8gnAJGddaPYbFZTBsZFJUAzkARS8tJYghMLoBRwq2mb+vbutDS2rLMhEBkLLRIQccbKQ/7cVq1e
# DATA ES2jQvBfXQgUGXn/FQfIjGfD7nRGMBXd43SSt+N7f/Tj+w9qSezVBiaWaZaPwWcQW1XVQx1eKWglw2QHGFnl3FTBZaqGxRimD4fC
# DATA dhL/1HM39sHhFUvOc590USbVB86yfZPxfP8NajEI0wx+/3vn96L1Q4dHE5C5UshLCAO6D2mVUKmhn5mKKT6CwXv5We7fNEu3ibdV
# DATA +KBbEnfJncY+gMTnDJ1S14ZBvswv8aTw35Z0U7fxVLXVqeL3dSZfDsCCbc64DOzFfkgb+pltxEj7a5oUzg5POzqaDVGkTM530116
# DATA Cq5Zfg/8nqJFjkz0SAno78vNF8g/lAwOI/gb8JtBO3Sf4d8GXHeBhFPv1BGblhZFr0wsq8FxdeKC0LTSoIa9DGZRjIiuTMd9dJiD
# DATA t/fxLW+ulgvHivOBxfZhB9KgSKUDn74Htkj5Ob6Tn0ERXHf8dM+p0Yc6pfLt6GaFctyMWd9enBqTcIWreoErmCGsMzGeaodhj9V4
# DATA GLAkzDhooLqZMDcxnITYAzhcIOlFFbIZbMI4Kg4GJTPnLXROnbjdon6o5xiJbDLKn05g1ia4Spov4sIULvN4YrSILiW+dNwnT5DW
# DATA Vyf8TicQ69Lr2MpDwq05tU7poLWiUKooF/so12rBPppREIwRJkzjgO6MDEck9TAVF4OowzjakBCFgNePgg0BQDkL+kY49kOxNVIa
# DATA L4q5EeAx9OcleGu9clfSIaDGYXQU4lvgZV13KGbbyVN0LdApnjIvQEYv7Z5bvICMLwV/cgtBwGYNDGyiPI3vhKOxGCfkgu+5Seiv
# DATA hWsGrJ6tcJ4lVSRrgnmOnDE4qjm5PA7AZI2aolR3upDOSGF6iSrrQEHQVBb0znO2sF4pCypKhvvgIMrGEMr1hs2SbMgkibYSLwXA
# DATA TirhRh4haPee7dCI0NXipWCdtVClceXxR+5RIpi52930kYF/+CyLQ4TdpBN/Sbrze5u30i0gl9jkwEQ+QRfvvKtkEq1oWSr2Mjx1
# DATA LmVC4I57YKtlsgEOE8ORt7089SJZY3PNdYTXoQ6ZPxm9BNgco/klrC7xgINyHT4vISLq4BSjL75jwr5suwpOwWywB9BXYLxJ4ihe
# DATA XKB+21ejoelPs9JNYdqGLUZ9bkcSPoGzbnIxaTsuiEM4JVoa8gZbm+cgmCSVshZHBnJeKvb1ZqcRsaPMcLRMAd8t6wy0vb5A0o2L
# DATA KqziDGn/FG8hPdAQsZZavOPvSj0WHK6jY+/EjsTMEx6msevE42vIXLRJmoaO7X8tLvF/KvE0iOdeJA/jS3gjzK2t6K3gxP4l5f6+
# DATA 4EBjWJIZcLswCSG0Rm/PFta1VnD1YV+OkKdPmUNSkiyE++jt8Yeea5TY5ZoV0Gwv43eVm9yozmm8Gnsx9+neIB2W0jxNFOuC1i1A
# DATA MJd0JIyfXlGojQuiIDdUaNIxrBgrHwi2bEyZjMZ91C0BOk4T9CaI9VbDnxoGstmTqcHALq2EnEKtXJd0sQw7FkIQ+VnD8QpsgFdg
# DATA E6CPY/L9aLron9LpL+JOGB/VeS4d4PumPfjKPUoYysWHdeE/a/2xzVXbQFwEQrVQP9DwMyZu0h8XXFBCapsy3xNbG8qYuh/gIwOx
# DATA GdcgjB1M1mP4E7UMVEIk0m1SMF8yb1pwFdRo2XZ2yMty3h9fNCGmbamYjtwh6Vi8Ht1e+fZdOWTDmQ9jg3j0fGhQjp6OckY6wgh5
# DATA 1VDUOKxGOnL7JQltEQ/FnzBF1e56uCjaKQtI/KQiCrH2nRYGIv6YIRWSyIdRsUEhatUvoiIDmEiEkdu3b3H4YsQK0+j6pNvopqoK
# DATA NVyvtoYqft2h3GCQU7T5ZTrpp7gatbkhlGqbcFd5Xi4itz9VPOswNggQmLyK7buU1rZyJGqlit3H3L8du5fgFOn7Em93/dK/ajnk
# DATA I1brEnMoNtCm5Hy1joYhnWLeb9JOWGBzECgEUIh5x8npYbvtLYeTDEw26x5CfxIcZXo/6CGE50tyZ+yIU1ExiDJvQnSzYop7VAke
# DATA oWL2hIqeBhgsOL2cpBPgo+CJTPQDuT3yBbPHWrCzfDVEfqwmuUux2weZgaKOLyHEHipxAZok3lhlKKL+qG2oAxuH/QL5Agbn+whQ
# DATA OeKFiBQn3E9wVrkn8D4ROWHhs6Dg6osoADkX+cJJmSHuOBuMHUOl4+pgNea691y+7OJSo/euhSSI4Ph8+BVAOAIxgMKFXXa9GgRR
# DATA dQbV1zS4YAWXgEl0aktCB4eXqmSaF7xtUWcXWONgm8KLxZFGS4W8paV/6yFfSiF1MOqakHBGoDzsDqcDMtyqlx12NdTtw7O46JJj
# DATA iposSUWnQ1OGPQ8fbq+v7WpHw+1Hn2zPc0IENfldrSZ3nd09p0Hb/u/bY9B137ys6yBMGWCb65mTfma4Ts1DXEHpV0nPYb4665/a
# DATA 4mfgIBSOdocAerBBOdMWVuJ0yO1eu9jnroeIfho0/V0hPq8c4oOjSPTBEVGzeQtb6kMgjyEy3hWlrqWiUI8rIzNvwIdS7lJXDRP2
# DATA QFOmKD4F2dRC9pU2ZWsMACReystG+3hWuddc2W6zVKHfFtocqV0z5qOlwiv/+noZF6hLqFzZbLY5kg5lRTVrUcy4Z13yX/QVsS16
# DATA 0TloK5169eUdbv3+GifFSSs7T76Pzj0NsrdXGNqoqFY2Q4CdSn3bT4J2bPy4bhPVLG4g9Ddrzzegy1QUvrdBtW7Euv2G+NO8zVO9
# DATA gSr2SNVEVu6Ft5zE8oksn8xAL8pYv78rS+bbDZvLbVhGkVIvjMB0NfLMPUH1Uln03rAWExp1dzpAytzPNQpVQwl0qFycj1MthDMB
# DATA ehbHVzmoUu8FTq9N0G2+yM7ymuSQIY5RGjwYGGaqmh821L0KEj65jdtAGNWD2jxdXd3rUDBPk83jMjlBNdpSIP0SYwaW5L6RWcWa
# DATA iLKub/Q1/NVc39xa39ytR+bX7vqTp7ufmQfrn27s7FYlNConlXQAPMsbLaAi9xQJa5wnCAXLpGzQCb1cCsrAa4D+paNHJQuvG7QD
# DATA 0tETA7AnX8JWV6ALqPkCObsQg4/SvwNMUmkBoOKFUHwUZr1XUqadA0xCkinNpZ9WFWulVLA226uXCNb4d77sj2Z5J+BuHrzkyKh0
# DATA VKqGS5nJQYXeuYEKtYuCge6y8TJDkTA58Zfa/QLrdl5ZZxlc55I2rHcLApJG2q2EvnFqB0VTQVbz/GhctG1ILmYwU5e0BhNhOB2c
# DATA 7nKMbndl3hLmEQgcWicKt+R6FAzFAAq1X7AgYDVuXHc5kNkCO1ZgH4wwNOecYlCxVh9NSMYrWaCgYv+0vx7l67HmwQKiiB+Z7ewh
# DATA X1/g1xYGUnGq8COgA3OPm6rTgXnodNxTVfKxs0oC3/uczaQtY77L82M6Py29y4SNvRVJ8DP3vLXcYajX9qi0xBm5KHSSVHRGGXcV
# DATA 3lksmQ31Jr+qCEG4qdIxNxDIXWC53poLdlu4q7vXWKMVR+DHJkYYheCGeMtVJmxcWDqptryKMHzZRV+ClZOmKQ8j8pI0yo/KAFd9
# DATA dbUa/h5SkvIBVgqP8xY8QOkW3XEln0qsJCcvHKaAu1JyOHzvJRoj6FgnOxqKMTRo3Hc8fsVBEKpA6y9iPo69Bp131IOA/2mDvVLp
# DATA O+AxcV24PZsfqFTCuIr+VDRicJz2K7rd4EYriyBhaYzJk6eYNG6l8mN1F/M/hcRu4cL9ISqxCx9UNVBQyJQN1IlA0qneqGwo3xtm
# DATA ZtPoxW2zBMVrOHJ/yrpNhHrv5k1MAc65uIUEUBbe40AVgQzZKs9bFm+zNOPlEQl0WW4rCStOkrEM9sMvhSzkSgQFlBB24bcidXFI
# DATA fl+8PS0j5534OK8nJp85hZwt0BhcfdzTxYfO9c4vLi8WIh9Rtw+OXzB9V6kjm6c9ma9BeSdalIAOQ+/8piNLl4jQRU/s5C3dwdy5
# DATA Y8ylvZV9L12g46WMEJPYEvKkFVOhVQCHt4xup3gKF9yxHhm1uB2VN6MwMqtv8wH08MP+Kwg9UD1u0KIKqI2XI4D4B7XcMtoqJ4qN
# DATA 51HanYxyi6A9sbjhhfvs13DH1M1e+gZ85b7BfAhLl2MsW9Ta5Vi3PNwMqKgMHFnagRj2KGwBCuwkkgTCzpR7FLgOwqYJYa+FNjDz
# DATA Ro1DfKiLW6MBRFPay5A5dKhNkfzJOw/mzlrKBNDEPud4hEngpdQOPoE0ieYFtaoM1ja3en8k4mqPQQ4OHWJ9WSUZay1CWbXX45XT
# DATA 8cnKqu14YpagoMThLUdD9W64rjNuPRxMUoFJFixvHSYvd9vF58mcLYcCrrfRBPp3KZ3X7hcLEu53t4lLNb/2YPqrUDmI+ehlZXNT
# DATA 7pe/gOa35PzTreZdH/x5arcSjQCJ4YU97QHIYmgAFjHKlP0kEeq68nmq2JsocpZdzLyNJbOKFPiEqWKBrM+c6Pkbf/jfv+L/oZcW
# DATA nPOvKPfz3PzPqyur76/e8fI/r9x8/84f8j9/Hf/zkzLr3/n0cvmZu6BqyYPZmo/THBIxm5/Tk8El8zbXo6ezSfYU8C9K0jhnXSVO
# DATA 5cHUzWfm8UxdLxRZfLi2u/Z466PO07Xdj7WoZRXu1iQbm7PRUaJXOhgdkQ8huIrpOnTO4pucsFjmLX6ytrnx4frOrk1sDI6q+ApM
# DATA qI/X6OldeoSRYzrV8d3bxbTIkAxB1I5m143Nj8w36r37Qn9493agc6bUo/WnOA3fWtrZVT3qbK49QUfOpklnQgx36Y+3nm1vrj0O
# DATA FGiI3FdcGC81garILXF7/eH6xtNdU8DWdJB2X8zGXMnW40ednd1nHwAmTXz/Wm+Emww30IP78N9okA6P2tez4fUH9zG9I0KhZNP2
# DATA dYTIU08xyOsBxzDcX6af98f6CVx+rIfr/eXxg/vLWD1EKGw8Wt/c3fhwY32bwl+6o5NxHyQFhDbSuEYIa3T7/Yvn31db4+P1TwNl
# DATA DxET++5tKrO79d31zdJSt25SqfVPd9c3dza2NncQxKIJvcKIlW6eU0ZP+id/eYT/Tl9N+TEKxnHzFZc/zQ7UUe0fKmErvlC7vztI
# DATA 8zzaUZNNF2Z7dzZ67VyHSHWKMGo+hNpc+LRq6DRWTprexI+ePX288RA24h/vbG12vrv+mWPDCQOluSBp3HeYCUJkbAVte0JfRPhp
# DATA B2fTghsIA9UF4Re98K0F8Ng6ApBNZ3SUyE98oYGRP8rE0+2sO8NwB1qngCdHYR43Nr+39njjEc6iutsiZcVv9PQgifPQBL1gf5sF
# DATA O3FyH0CMPmMOql+r30J1Tfz8OYY94YuKjj3b3Fn7cL2ztrOzvoskOE4cbGNJ6GUGKbh+hSGO4dJOmJPXNNqhRiYwoMcAT3DHBwqa
# DATA mwV6XyaExoP+bcwHDVUGYY3gBUzCOYWcNJvxBUW6TaYCaKoZTinpdaP2nZZitT8eT4Y/TmevfjycDX6s6MXequrWjwfjKf6RqELP
# DATA m80byXe4V3Dbbm4Ur2SH3AsXCjoxYXj57PCw/0pt31O4JmmNhiVCyRVWNIAZ2emN8NZx6X3nLCvvvQfRzTu3FjgCj7aerG1shvLx
# DATA GGKGNTYnkO99jOujVosOe783TNVPffbTvNvvq988UWUQbpc5obp78oxKjDTO6U7DrUpezntWbQnJmu6uXug3uEsUq5M2l/LQMZhs
# DATA KGtJt0550IyTJLnsxAdpNKhqC7i0jg/WOwA815sc7sCmpqbaacdOstyyfU0h/XZb/48OgA7TcaSEpakim/AC7L5TEn/hWf9ATWWO
# DATA GgtQt7+6vbIyh2XjBO189uTxxuZ3XQ/RMD55NZb4nMbkoqxtPlTi9da222htlJMjJag8EDOPLC/lTQYd9SqR16sQ1ReZrU+2N9Av
# DATA q2QIdt7aYt6E/2iOUYdvP5vYmc2t3Y76cP2h6sdnl+4IektcHdp94R6q+p49XtvG604pOnuH7E4CAZspiKQ0VhFdOMrmIHPM5Q15
# DATA oPeTQupXe3LDSuDOSfoiswj4FrAfkcTu3Ck/LUiobPUFaoW146BEnXZkoalxu0IDFJsETVkdGqvF8KbfnoPfpNRBCedLGP/c/J5F
# DATA TyR1Vu2S4bHl7KjwH2QKncNem1qkeooryePzEfnLN4Bw8KEUt20PYl+TxxF4ulnLHxHFwusPNjbX1MGBlyGbYEcg+WNzicDUVxJH
# DATA lp4EcGNNiByVWBBZX0O3iiNnH7nxb/b5PMx8/zSiVuLxxpON3SJKPve2DCc/PZxmk7mjC6Hpo3u17XN/OKp7Q5C/TyDUoTMkaNka
# DATA tmq+Mr/oI/PTfFMhEuD4H368tvnR+qMiQH9JDKdzplreJjZ5eB2zuGZh1wwLa7kBgq6VVpgSwxsafxka71u0lyrzTzDt0Zu3KEWH
# DATA 7haQMw6Fr73VloczqTH3bRtwbcHKzYEPxYWWRkA693U5CmwpJHBVxp9q9cAV+X8ZNPxlRABaYtu5S4eDFmhOIOf0O6H3FVlLRLvJ
# DATA /EiWEvp8OZvl3O1RtEzKI+zOt3jjHAdiUnTOCq4hQbbFawK6Ia1JroWUUuP0DMoAtyLALaGoduJACxro6rQvi9xGibJxnU82dnY2
# DATA Nj8q3kmd7jLsVVv321eQWfyN5xPC7XaxUExWYt0s6Krgd4HFYUMS9EAn8GXtABdwobwpeR++QMATfgr8bw6X0/dXZ04eqX8ltrYq
# DATA PkkHmGIU2tgTEL8GAZzRdABRAy20YFYhV9Eaf8/nMs5epoM4qQDetNU0D0a9szpW9XCErwmKE1OBeMWabmoQxW3fwdCBv/FYeBQd
# DATA 6L7ftpdncTypwYcE8kmfvYO+TNJTzHL/amo0NlI9G1ay7pwNp+mroG5V8WE1jZdXswb6GNDnoDonPU0Yb8A5woueTSl4sdBFqm6o
# DATA uEShRvpozPSBpyKbsnB1DWwLefc4O0m1/3dOKkvcTVBoT7/f9zPMuG+9g7XQTGkRanSas5J9j/uwXzISKCrgZx2VNLxDjbRjYbti
# DATA lwJmDlU/3hFVMy4oS7GP3mSrJzzX/R7GaIEZivz0TYgAou1BICrOf4FrFdvYg8r2XTWpNVlJ1aAui8XML6vXC7WnlYxem2B68bJ+
# DATA 8NMmKU8Nrq9+Dpv9JH3VP5mdlAH1S1R+D5CfJ5xrMsYmXSFo32pmOleVbAPohe6s3rq7kuwnyRWIjYzfZSw/nD1apiqYZA7wNpsA
# DATA Xt/S+5TCjfVGtXbfy/QQP3Diiwc9RGyD7eaGHZO8IiKQCK8mGINEViEXtk+PUD1sdpX8BU1B/N1QN8rjE8PnxuxGiZ+/WllBtazu
# DATA B+8S/ukT72QOIsvlJ0hj852fk1b64sLpjhbscZTCUoNm12RRmZ6q7ijC83D9463Hj9a3OwCuuf7prtcTmjmIMKl58+qqMmPE0Kde
# DATA aKMMbUWY1Nsrt8OvgtTjPE4PRrOpsSTjr2XRwEWzjwlAMjTk8zZdSD+3vf7vnqnL5SMlqX60vmPFRwd/Jefd6YXlgyfcELwYQQeE
# DATA 8rIJ2zTb132i7yNDz1iI21Yr60gHbuuEm3QzXmg0IG6rdXv8eANMX0Xzs6Gg+0QQSs0bnqyv8+idKxLWMlRNEzXyAazgD8mF5ELe
# DATA bYIEPXWe9606DP0ZiRmh1a1gwYcJa+kjYKV1cUTq6GyhMQ2pmnr0w9loyv68iSENhUNjo7Azga1XQZfY1VKSWE2lOOMG7xVjA5xP
# DATA Nly3eDZj6bki/jw7qaqw+vsryHHb65tAF6QYF9o7tHzofWTmXc2FWqKpVtjSY5D/2KrKyyxlKm+bGOx0rkkTDlemCRhdvru59ckm
# DATA UVYtWbmdF/st39PV75utZwx+Z8OuVIQJXVc7oOtaTEdRrb6ifXYZfVhQ7xzUXKAiCYYUUjgEY4KrlDYyHJdE9oLS5hLa7E+25WCd
# DATA sJb1Tx8+/srV3Kz6gXCYEmU3K39p2Hgh8V8dDmb5sZBnzHwX9MY8hXR+e46DAe/QmggWYA+DbJgrDtJBo36bAfuBCnUAFoYzbeWZ
# DATA 2gWpWqa8XYvrQJRbcaITwiSFWyf3Q31w0u/ydMjOlKwcnJjRJMUc0rhrhRuicLTDqWoAdCr4MjbhP7cV8T/OOK8QbyFTW92fkYD6
# DATA tkLztvjxm6Mm5LXTLEb0r5huNRyuHvqaj7Y45fmk23HOrjpI+bRTcpwtNWrKV4VzywST2iwx9HEwvilndgK/CCr/nQl/d/Y3A3RX
# DATA aXcTHePZC6st1UmDu5/J4skxnzQKCpcsZBKGx+WZhI3tYpJ11b1PYKRPR1PUqVGQJgBqcnotbkjd5ET+LH7fcm9BEwgsHyOZ5ALN
# DATA 8WhcS7wNr8u6YUkOG3FsLHM4VWEFqf7SA1PKs+i7r5RrceZlalRnbRadgUy74pefbINHVhx6MKPzYnmfvfzPvDFM+mfP2RmUT7jE
# DATA D6KiL3Or1LcpLJDtbq8XzZn+mQIsdBx2tEwjwQUKD4FsTFSKUqMHs0KHw6YyJTf1X2aaDejfnemoxniQENal9l4tKZvAakcXXMy3
# DATA 8f8ps9qEwUfswHBFTdKJ2Ibm1s2ok/Lv9VHW37OUhLsATMzhL8uhTxawOZUYBAVgrOdq3yD61ap0rrviJrTU8b2205XS0r3+UZYD
# DATA peb4i2Z+nN68c7dWXv9X4QwRhJ15CweJ0P8u4TRRsrbv0JHimrs86LegH/SHIzyCjh+D/EL9TFpzfTMXcUsoP4c2aaXb88rPiOGa
# DATA j+f38YBD7aVDyIm6o0IS+rt1W1My3xWV1wdrbC2U6fVtJsgeneZsDG5VNWx4/kd2Zhuk513gO1JSmQla/YoXfzH3m5KOfu3eN+9y
# DATA 9AX2gzhzlvMUh8N7QF2t6K+aDOANXu1LxaZLOCqwhOyRbHOJ0yoyFo+SRPbP6FgQLcZVshh/aQlO6XhRh4A/PHHdMTdKf7titFvi
# DATA Kocw74jqFfeN7vrc3dA70+/aFS2ZL/pD0qSyJgqVqaiKsnY2eK3uNkV729Vsn/YxNo4PfbgyxB8IpSz3hrhnO76Ihc//pBBeYjSE
# DATA WJAnYh9nzX0UMOZQAVbI2rkvDMHYt5wPAnau0jZwNbzxfrz+aXGgWG6hEATyTd+16kqreWb5qD+MnA4XDWMho1jAxo7VVXYeS1zK
# DATA ECl7voCjITAcRR6UVDwYnQFsWUhraN+qu4yJ03QkYMwQM8Gwy8AGbrxc1QmcXEWS1F9SFQW/pHUkP14MQzEuwnPnzSBBHtaHW5b+
# DATA vqxFEIYaF0IrnmYTBFBk/48SkOQw2/ng2c5nRT8P51YvZVuJKFQlVAd0dKEZktqI4TQOgElS1PNJ/rI7mRbe0mMMyFUyi5OZgl89
# DATA Vjvjg8eQzmN1EQ1dAaLKuVoskgRDzYv4vflBYbGqkawvs0hXz7TRUX1B6OnaIDuEeLv+0fHUZbT5Wd4ESqxozYmTqkcx2NmrOAkn
# DATA gSaAqv4Ba4EpoL758NHjx5ynYJZnHQysF1A6h7Mho3+YLcVVEOaj2iDp9KbaVhhUpTtpvqrMSu000EwnR9gjTHZPfet2EMbR/AKH
# DATA jc5YPJjzeqbe77utACYMxHi3nUqK+lGYe7wfwh8drevVb2lN4DX+1QkoUXWLNacCFIxZpQ8vKINh3anGLYVvdLGblOq6NMcwg133
# DATA xPjUqtGiWuMcFoAgUoO4vvPZjoFbR5pmfm093dza3Xn29OlFxRrSweDDU+uiiypo/hQfNU+sCQXh88mpERQs+VQdDpgpR3ut39ud
# DATA qJmLKe+phcWbkGY47E+xDuqVtd2NrU3SteyI/LULH7LAGZl7uEpPz9wTFBzN2u7Wk42HHW0AVvy282xz7XtrG4/BBVz68Xwtx23R
# DATA I1c4drTspJjBPwtHT24YKCZ+d0oMR+YoelXKY8aOvHzOipW6peVe409WfVhUGzxZdRyLqzr3GBmAp1IGjbYsFCpDx2ypyGKvtp/I
# DATA vMUzJ40C3mlke9I17crc9Nepo03c3ieGZBBqByLlCfHSNXwatxMiFCK8PwhFSKYGW5nu5XIUU2t5DH8boRSucw690e21RSXo/0jP
# DATA Qez3K8/ZsKBLW48Pfr9gsPAHaw+/++wpAp5WBT9T9pmCsB5WAYwAfBEsdYrcgbcYOkyJbwuW6KBqYJKe6mt2yR3BuR1YRBjP1aPq
# DATA 5l9E5he5fm26DAPXbx2WupmStJwNlE66x2AXaJXpH7iA6qvElKnQSLwDnYLtoFEh1Bmb7uvWJTBeTkGlwJd621GsobjjyhAxqsEY
# DATA 3GstH2LHUWpPXtSL6gg9IThl+4VcsbWgdoBLz1cPcMEkWVxDQCc2lpKM3Vn2FDiXZAo98LehLFxyOIKlk0AiC7NhPVoAnv7ydCO5
# DATA S0+L5BPFFqvk4YmZJ3Ux+XKVqsUmBH/wVHg2HiGkuaCQyAm41WTOYRdcpB5NRy8yJUKOBr16NMxOGVexzixKYkTodQiRtiWbdaCk
# DATA 6xR9LJp2xDzBIiwScS97CXMqvnFfLnQrpTlGfdhnO7vrT4QMqLeH04TaLDWBkwUuQDhFwq3BC/DmajDSfGXFjcYpW0mhxglvaRNk
# DATA Eizp0mCjtTZEtBWtajraqqRn9YLwJYlZK0DJNCVu4ZYpfk57vxW9zVGS2U1IJtL8Se8zcpZxeGh8enpKYWewCRXZCu9UKKBeXC72
# DATA mBmiN7+4L9TffIRYXuJcLSA2yN0OuSMGPZ42JU9lp+pvOHDOFEKZnXcwg16telH4bMd0uOEB/nEh46bMbkLerF1vPYy9G9HNeTNo
# DATA vpDWdu2v56ycBLwjh8wghBDJRIf9YT8/LqNnjh6UbxDCyzU7gM3vS1+4c2RGxaNCEcc5EEuEKIPIGLUIRSk0HdQ+uhQV+Tbtfh5N
# DATA 4iQ9oFe6I6gmUTUEwoA5eR+Vq+up8fWPi3WgDcnbTsUbnKGKxo1qj6uo06wngWhluhG5jEZGHPIi1+3+KyQYzPNgjpl5W4mq+YE6
# DATA IUP0lSvds1IlycWL5j/94soWQK6gXnIc317sJnLm0jGmWkyw6oI+GUnckpN3J5MvYLbDznpCKiI+Fq1YVDQJy+5isPsamV7ugpDk
# DATA XrxEh6TpBQX6MIacL+HDKuzXI/ODFiEg8gdnCxZvAYEei5VeImiRF75FcHHTajBWyoNWs1RS4nTGety6zsvcOHa31zZ31h7u2ggj
# DATA DXweMojbSw1KpaW3J/fqwBWR6nMRvuFuzKXLCKOBTwXbsSKi5SxzuV72aqxEWYxqFPugkH/aWXTGZqeLJ5wbXclbrktnEfXIvItI
# DATA dzZBHVb7rWQothO91NwJ2nT4Xp1/2+VPtGESsj1BeeNPgkkTwtNZuIbq7pv7pD3vNrXNADeLnXd8gzPT1h2Yq/aneXVFXUoGKYjO
# DATA UpUgUqVLkrvDEQMuoSLgunpm7o1kYxSspcRJ6IEn/SMM4HKPlvvpkmsUL46LakmqN/0lb/v2jB1ljhynlxdmnZJZ8UQE7SDmRsQj
# DATA lbehcB+v0E8rNrqt1CP/APiidPiYwH3DGyV/4O3q8rHbbRm4XmNXbaMBGRfl24AwKnrqA8GViqMFUz21b+p0N+4lOikoUL14Hipo
# DATA UT14ZHDMOO9yu82ZeLFEFRqeywwlMABJArGDi3EVts083Pre+vZnEAb+4eONh7txUkW3zHDnH6/isIorWVwcsnWWkCxz2k2fMNMR
# DATA fzyXWlYO+OvkjVzgmmE4bkrfci62EM5pgDfNT8eno8CsLFF5RFkbYUuz+jMpFX6ksQ7n129J94Cva9JC6C8FX/rO+Q7CSiPNPkN7
# DATA 1+p3ovgoG2YT3JLqQ31OPL2P8VRsGYHN+C7OEUYu9C1ZXZKn/XRAEdL6tDpuOPywPA7NuGSEo74uE5tsdA6XCU/WHXxHsV6OmkbH
# DATA WFw+vIvMH4ZBcJg/uFyFArcO+xMMMhlCIiYu4ftLaDs/Fi1P++stiv+lRUSUoBhwbSw2Xe19XXCQ8UK3qLlFQ7dC4SNvCbhchMp9
# DATA QDZBJ7LkGrnb6iwZyYIDLWjznAUH6UnMbyEwivVbhixWVBUKCVusR46huaxjzthRqad/FZRxprf1Ijhe8rYjCIULLxIHUOVjCEBq
# DATA 2eRlyJfXheDTOgOfqbq2xaWSyWAlZVKsUIToMjOANzPIBB+bzoGOjWRUMCBw/LwI7CPGEbCGvDt24DMcfmY4l2QZnPWUMTXEDcrH
# DATA 12jHE0U0RycYH4Ix5xocQFzUpAmyEokDosdB4chVGdp0MBoNAq7wuhNWLWYekRcAdc3cuIMBAQYpZGF9FED4rO8YYDm7Zo7DjmNw
# DATA s2fDqnICLuZ8GbOlF1Vd2/DvgvZazUpIce2EoNN02zgXrg1++5KBKVQlVUjCFDyfWEpe5dvlnlEF2xBhJEKPhSjn3ESWhL3ab5Vk
# DATA kTL3fx0A9TJj9c8ixirTKf2df1kRkxyk3guQDELYKFAMc/cKhnNJcmF65wbMuDRBFBLP9yWZEEX42f6FH+shN9SVN9Bim+hSascA
# DATA HwhdMwKjCKtQy8XmxTtP2rrA/iUpi6YI3oJy+NxpoCz0bW/fdWmrL/aVifSrEB7q/ufmjRP+V9qByq0SuufDM0ZecibjKlNdAfRE
# DATA aNujfpfciPs99WH/sJ9N0JQjfjIClO5+bf4msXibIJnCE1Fdu13k44lVZObZQOv1awvye4/eEP/npH9NGmKNR0qQZIZltgXLxK/0
# DATA G+fmrnsUhMO6NCSWBIx0cLF0OwIXy8b2v8hAgvBxfQr2/wCHrfQC8GVY302IlUReOorLAkdO04m64mC8N3RzOSrAYzDnooJNH6NE
# DATA ghdhCdOw79dqQbFu33b7ywAdFknunMd2Q2L8MISgIquUsvsoa06OBqODWnwjTpKLOmDxtQfpyUEvxWItP5NYXWcJoUiBkCbWR0gZ
# DATA Zqz2KjrrVDhDOfGrLbNJbSRrS0uu4bBnjmhsaaA/j8iVQW86yrb5++CirHV2x5KeFw6hdJx6zAyVePYsopoLevY4ZgijpbkW8ABZ
# DATA NLRc6rov68bYceyT4lEhm6CUnpjq9WIhJQZ5CxK4mO85QWEr4FdXJnyVbT5HtgqMyUpVeqakUKXRDTH1d/EqRgXrRnHYsa2V3r6C
# DATA YOnFr8u9DALFF743fbS+ub69JszFX+nV6aq3C2vFFz2iUokXN8FFRVSIbFSDPi/oH6ErwyCcS0VPxItebMCzqPQemThXxqpyYf+n
# DATA KsAe4yfQebq++cjFu7XWjBIZ+DKKm6LhIrBhcXwL+kRwTQuN0+7vAClkczSJOeUW95AjIs2L5xfijNcU1gZB4Nv6GXjLUot6YG9l
# DATA 62Z61Ot46xL01OdrMTU+3wvHxiPJJvxFcl/L1dJj9i8HXo+d9uZKkzYaa1EWxpvG2hnrXh+Mb75z6Kv5Gn3/lkoBVyHgTaNzsfAm
# DATA rcQtGet0uJwdslQZIBh0gbWh/k+JsC/dPJZKXpygIxTlWW+uTY5mMNlP8U1NAD234w1i4NHBbNhTbDxS5C8dREBkNbvIkTCOZtMI
# DATA 5w30WpATAfqcN01CXagZMMY7KTdWixsNibsGesn2U6MmKPuCpM3KMgJnRU1CqmbGKFErv6PZa0zIqXOx/rAEBOylSxNGwsRUbZzq
# DATA 1mCOrvAZb5uFO6jJc0NsIs2HEWCNv8N/4MscN0wSTFMNr5vQ8cL5pwNcvPKjKwV+xh0vOOXgSyeLozX3qzch9uKX0WKo/s0q8Eq7
# DATA Gw+bomXtvKqx/HCmOpNHYnciUQxOZd3sfbMVoBfePi3MkyNyuhNQd2arXjoJ/CaoKi1a8efPs52zxebLnxz+PrVT2ItmQ3U3g5mE
# DATA LQNVz3JFVUvmxLGIBOdEm0bwhzVNyC1QNSvjSV8dCQG8TE0vgrycFFjHyjwzVgAXpNCB8xhLMFPBv+HSX+yPkovhntsGnIF8qq7z
# DATA k0KHVhXJN8fVJJwBVZtNsiIg+81J3V8KW1GdKgDIHy6uiD7U6aAiq9OB1eh02AsBuqbk22kNeY6asG9c/n/AVXD9te6wOT77xjv+
# DATA 34r6393bt/Ff9T/n35urq7du33pfP6Pnq6vvv3/nG9HKN76G/80AO0I1/41/nf/zc6+dXyf11PXWav06ihrXW3vn1/u9663rKNhN
# DATA FX1QR+V6/TpmqVCPX//tm5+8+YvXX7z5s9e/fP2rN3/25qdvfvL659HrL6LXv1N//fbNn6pn6snrL+Gv15+//q36WAg8UMX/qV7/
# DATA 0+u/V4V/UvJVPVL//oVq4Tdv/loVef1reKUaVUVVlb+C1tT//Uo9/fWbn6lu/FT9+zfqQ6pRFf/tm79SL3/x+oumah5VWNdb59d1
# DATA DhXVifvXeiOEgcCkFw+ePx/ehz+igZKw2s+fX8+G6j8P7h9nae/B/ZNsmmKGojybwkvUnuF7fAOHFh6/7GenAIuk/tQaNHh82u9N
# DATA j9s9JVV2swb+qGtLQCNXwl7WXrV1HU+n4wbQ95fw6UOqpbEDecv607PG09Gg3z3zGmAhrJFPutHzOM8Gh8/jexFNuf9wejbIvGf9
# DATA kyPnCbrKte5Fo4MfqOXnV0PFtKDwQZpnDdUX8QhAWRokZtmnxdkRm8Dr/1r0sp/PUOqdZgej0YsI09UoKffoGO4kx4qRHI8GvRxZ
# DATA 4fRYScapYotRfgKCM10mIKFyBNpu9VyxpZMoS3MwT0xHwBSb0c501jvDb0eTXn8IsEuMJKsEOhCpTwAQEnuNW/3BU1Btg3hzCN4j
# DATA 0Y+jfzfrZ9Po5WigRL/7y1ToPvrrTLIBDKPfpZGp7h7C7+U0V/slX4bnzfzlEbxDmRLKnqjql9XD916dDLBVWROuUn6cZdNQfbAE
# DATA zW6eX/IztPPpz2gpAEK/UOQHUAIE+2zy4P4yFVR/4EmAYwLp/nCLoBIIPpekAmtXh2WgqsQ+veiPZW++CewLCu2oF7A6vA/uL6d0
# DATA 2qBV8f0BXCyc4VjTHlTjroqqY5i+VDJKP20M0gOalicgN6nH/aOUNx+0UFLf1stsAucY6xKlcrV/+lluyu2MUzjAET/3i8MWNGW3
# DATA YT+ejiYvcG2w6LLqD08qDJhEwx58qufnPqdmslMxBlsPfEGUafXB7nGqlnAMMrEJaFNbXP2tZLVhU1W/+uD+WBXLIvhWHY+z6Dh9
# DATA qf4YvQTtLmT+O8YDAKkc8TWsBoqZsFNHzUh9q67N6A6nJHF12qZwxM5GM1g6+FgrqvTRVa2OH9zv9V/afhNpyP2dcTCbTr0D4y7F
# DATA B0rI1M0cZOreC3i7PNFeLWAeHA176lQ79S2yaMuqr7DPabYD084PaNJvPtiaROO+6thsrCZJkZbDmZqU0WgA030TpvthOujO0Bx5
# DATA OBih9J+l5N8dIbWPepP0FCgO+PXBDKv1Mpsj6o0yWspeNgW0QnWDULLrDM6W6jjYfRG4BoGMuiMlovdBCU6zfpn9Z8a7DBvuwf1D
# DATA JcrDThy7J0rtLjkVoPWlWwLUa3NHqfpUwQd67Z2u2ERk8M0aUvY/Sk/G90Bef5l2z6BD0f/7T9Gl+k+rpnu9DEQJzhPzcsX0bbN/
# DATA 4PZ/4PbzuD1tyysw+XfM46/G4udz+P+BGPw75u8LsffLcfevhbnTjpTDNwz9X84JQoI/n3cqSj/KM81B1zTbJHWeahG5u+afcsgg
# DATA 16R2mKNDDoBUY1fbCtUqvEQ8Bd3+BJkvKvC8icDpQZFGs+Ac1WmDLJ0glP+JYtpqZw3qyIDVIPonWS86mPUHUxgB0Mechqx6+iyH
# DATA T1Da0v3TI4AWLEfvankg9wUCEgdGw8FZM9qYahmuC3m+gePDxCm2hZpma9bWokDaAw6D6kXsIixKA8UCOOt5jjhG0U6WvYh+qPYK
# DATA OGtp48JxNhijrgo6GaWHh7BKIJCkh9n0zIzws9FsYnk0D01JOnk0mQ2NqHkAzk7ZpBmtc6IhmFIYx2wM0grImXoXwh7PUYZRBSCF
# DATA wgiEJEUeciiTDs6m/S5KN2ps2WQKNv4jNYQU/C+0axvU1T3Oui9Q5YmmHVR7Op357z/533IeK2h50S8o747Gqh6UJ8WaNaOHsP4R
# DATA 2uUR8UIN7AxGznXBF/8fe+/a5Mhx5vd+lXJotewWAQyqcO/mjDy8SfSSFM2hxHCIelEACo3SACiwCuie1uxE6LK7skMbRw6fiLMR
# DATA jrAdjjjnPaUVbZqSqAj7C3R/hf0k5/k/T2ZWVuHS6J7unltKJBsoVGXlPZ98MvP/Q1SP8YpoSiU10oGyx5XaehhTXzSJKmwHgmIC
# DATA Q1nydpbHnNrEggubnqE7TI54fDBAVaz5vbeTk5mYechI2Vk2oBqDHWulqEk9lVsyGOEUVWrl6OEGkVT0cZJJ0WJPYcom/sMomueN
# DATA OhwMYPtPEjSGwYCvHyGgGAqJEF7izKTRA+FkNe/DhO9bcqnR7VHKRYa8NC0Kgc4R4XGkOwmqPh+gt4kXkgQK2m4ulGNLqtxczVVr
# DATA 1a0yekTGIpJ4QoGZrBjx5KVQkO9RjM3GpQziHtiNN5QOxsPxEiqhNNbnSocholjz3kTnI3sPUCQpxsWI+hZVXek9OL/Fv0mVUtb+
# DATA lac5uw02O81wdjSTb83Yv4qtfw2mftFoInv/O4/7ySMyX34GfE2fa2mVrjzBQ4/J4kkmk2o/orlwnKQH2ZSCHj9BuI+nYUq14aB+
# DATA iBWOoxSun4PjMN2rVufhPEr3DwfJhB6RS2SX7R+i/zrwO/NHd/xau+XJLwhr/xC7zKnLP6mepOH8oE818GGV0jZ8Ej6WYOIZNZB4
# DATA cQht/+oSW0fJ1ouqyWhECTqoBUE0fRIejBHOY75nCBYIN5IqVf7Bwxm13YNg/uiJVJJKPJsvFxXZv1XBExhrHnMU1bv0nTX5+3gY
# DATA ZzQMn9LP/OrRJHp0SKPF0azKW/4OBhEw0Yc/pdYZj06rqn3pyzQ/JaMF4+pBszl/dDgX4+CAcoL6TM+v+fh7KCVw4M8feRlNaYae
# DATA lX8rGY3OY7Yo5jSlV19WpZmGw3iZqZ/lS4ViIOVRPZE4tVv1Q5pKZRTOPGHe9WEpGw8wgVF5UjNNTOdOfuWxFU3qpmaZ7JhaqQ4q
# DATA qB+zhYq93Fk0vItF5588XkkoJ98OQKqYCuKASgajyvBxMg8HNBs8qLVaOjVqDkiVY0QGQlYlezDGCKQeLV7kSlG6JlWkdFFXmPK9
# DATA yyk1i9Pi1cfUtFFjDhqlQuW7qO7Lz7ouU9E8kXhQf733Y54i8TBOrfIn+9ZFFGXyk/2VOswz6QO/Xv92odK1qdJtqF14/f7u7Tiv
# DATA uqi5tY5VcXVla+hElOJfsS5K/FV0A2qahyqq/FkqcXW1E6FmV83GKX05qD8pBEe2+k8e68jVn5gMsXLB79YpbKps8c+iA7acaJh6
# DATA wvMj076P0nh4eETdUK3BKSs0k3pd7q5xkswzmzoDDqaDUMrt3w61SaGOQF2g8n+8tYx06vxa0NKhSgZSvKIjGsUf2wF36nXzSN2r
# DATA NemRJ2O/Mg4q40Zlrrrw6iKZ0+NjX3o/eR3mVzCTJaAKSMsY76bzvaDWxKsr7Vrr+KTSquHLPvXo9aaKqcqT/cMJWUJUJeB2RQTk
# DATA V+oSmKxRqdbqjRY9ejgNH6k0+O3B+FBFqp9Q+5xSQhsc6WC3yPnSnVYaFLWAMx5R87sXRI3iErSQncV385sb8mZ6iadynUJslAMs
# DATA Pskt4wkyWCet3RmMn8TTo0p2fGRqDZPQDq32qipIuFwkT2ROXOF9BjKiq6YCXJwf1KkiVzBh2sOTXtVro083EZFByg7pwrpaHrjY
# DATA XU5j/+IkimZck/1aq1SV/XrLdCsm29bV3Cc19l5IXnYkL5uSl8FqXupcC+pUIdaOQzSXKCaI+wW2HvAfaXiBGlr57xN2h1yYC+V2
# DATA uuntXigjl/Lq34UJ/JOy6XFgLJXDUrN8UoM36DHEE/jGUfwoGh7+rMo+GEr3IRpl1UcpH4K4QTmNjN7QRZtuAenkkGUIeoxQ8OST
# DATA Gpk0ie4cq8IMbKPsir0e/cfsWUPfu5zOsgN/lHr076b+jRsoh+/VyHKg13BauYvVZk1epM0WNQS5exQfLdPIGJL51UHI3lArnFo3
# DATA SPP2iVTVuvxaNZW4uC50S8/70kZryuAvZU2rnldrvnt9nVYPc4dUjMLOjcnOVOq+V7q/lh1LfpFHnWHxLso6lNzjHcoyjeY0K9xr
# DATA VKieU6Hs1StUstRt5DF6UhuE6fCxNbJYo06bh/pyLcyW6QhHuC+wL7abo/Jeb36A2X91MI4nw9Vk8i01uM8rtemSJqWPbQOBr1BA
# DATA +N2uPD3JwxNsy7etgd7aNrXefG5RJ9ukfxv0bxumVamcuH4WCoB9dsXmssFQNwMMAin1hpLmg9liLHmyF8z2PZ2WTSURrFptT2rG
# DATA b1qu69QNULLQSZhbPGUNSAaagR9DK0Z9fECI8FVag1yni7bNVz178OvUcZ3SEy92qaOUmarH0d1LoZUw1OZJDb4FY+0FN1kv8SZe
# DATA zFk1EfXYUhPz7RItMFjbAjks2Qz4uNBZibln9/OeqnNb6oBKGY8fzXUzSqstNKQ7OhnzYUn0Vgc0KeNeVMfogJKyODVp5JGwJtvW
# DATA CzZ2raWtZtX8AulWtC9yjaXdtFNXP8RdVV7AUW/J/ZiT+PEO5kZpjkI9B82b4kH02M6S8nxMN0fdPGTcrUmh0PTyyDKiTNTrOwwT
# DATA 8qwXYrpB88EdKkmhbnjmW4BvsOlWG4Q9phT7a6++m4FWjKU3twZm9VNGg/vs6HHJb0ANJDwqe0fEtN1SN00BBTKJTIt1pttenVRu
# DATA aJr9sGTb6pa0MraW7IJyFy4GgQrSk0khHjnwrXmW3+SeUppCntFl580wzMZRMYN/PI6Hw2j2k0ID+leCBwxniyfU3B4bP9gjNt3t
# DATA uRHmB/n7mhc0fTsru5sadsntFs5OT+CGfoK1ESnlUTiNJ6cHb5GJldC4XPnstffjvt77/kEySz57rTKlPxxusc1TXg5pHI4nmZVN
# DATA we71UflSHpe8UmWnVcle1+/0CrNbbsJqEnVRcz0sjo4c40BNfPIQG/Zwv87o3MEALFf5bh5Lq/VZdaCF8VXdUHBr8ExlN/8k9di5
# DATA t7o0E91QHWrzeDKppsnJxVa2sqkX0dyUuu5Gm/lP6MRN+2+qDnoBFx6HV24FT/gnXXDURU7CeUZWifpgT6DtGsgD82JcWQxlWsZ5
# DATA cYDYFMbRnSrjYput9aRGMYgec08uHfiBf6fq89ho+Ygso0FshmS5mC8XfCKhnFkyp+Jd+lUs26yxZnE8LVwk6WM97K6zZaVG647O
# DATA VOgn/3oaDeNwzzLR2tSt7T/e6HSwPQ2NNvpe5VUothZlk6yOTlxZ5BQFpruSTXad4fnpxvlnqVE2MHO1s7I4nzROlxb31Tw3upQx
# DATA po3VzfGxX75+CtnAYkNxhrhjtqwYDJun5cFI+xhblpWiH7xnz6Xs6hmUzGdtxq7Wi2aD6wXnYUVbuRvjw24Zcb3wqN7LC6cwoQjE
# DATA TaemmsXhYffU75xc7kTWzH+4I6eqZNI95yXNrJpGw+UgGlanCReLfKXWsW5NjAP/TuU7B7Lpgz6EI7SbcBZPc5dRPs4f8qJIvOYX
# DATA HQ05naPbojTDil6MKjs8xD7m0lTmh+XylZU6q1dgK0DNDfs0P31oZhvlm548KawY6l1b2CFIf7xH08mM1z6xL+/gzp2Tk5PaSaOW
# DATA pEd3gnq9fkdt8MIGojeTR7ix7tW9dpP+4WVf1HhPNgDSd77oSUeWf0/5OT/A5xENQbxnqlFvDJs9bHy89wbLlfBuoQ/8tuf3xo3g
# DATA uPv9oHns18f03+73/fbPCg+PglFj1JCHEcXiqmhGI2T09Ins0kSeJvOcgmSi9rfxjflmLKq4/VP8wvvm8t11avOTuWovOh/kO3rM
# DATA HoBoyGvhp2YDnpUlvbrXbLa8Rq/pBa36pFEPPL/bqDbqHc9vNooZM2wP+1F9NVc7Da/RbfzI77QnQeBXey0v8OnxeveY/r6PoFv1
# DATA oBhUNBr5nMc8XXjI6f9Ws9Wqt6L8YtUUfWPlpQi16x83A39arwZ+E6+s9nocGRURz5daccU3BEHdC5r+sR80Jr7ve63uj4Je92cf
# DATA NBs9r+FT9Qm6E7/eqTY7Pwra3WLyuoNeFIYrQXZalCu9sR/Up9V2nf45xscmXW40u2Pfp8utFv1zTB9LMe+3+/XmaF3Mmxtrqtq+
# DATA SBX1ACcLHytP8IGq4Yc8vz9QjeVQT20PvtVutfsNXDDeJ3qE/3doDJrVK8HBtyI/akWdQ+VjO/hWq9fudFqHYmEcfKs/GnQHeILd
# DATA zvTzsN0IhoeyvH/w2WsPoqMk8n74Hk0XPgnHZHtW7vP2sYy6wmoWpTGe1V3aTreje6phtyWZTHmXfiDWpBcUnc5dMQTM7WY0UvOb
# DATA 70XUpuOwIkGXluYOy44wGGeVTq15fFLpiCOMA1Y75XaZ3m/1b9FMtRhi2VFum3mqYFYf0D704jhRuGtesCrF5OQbMP4MYuwkenyJ
# DATA 5YF8LUA8gCWzSJxW9csZNx5ctOWNGEWvQH2jMVtIbWUlaRcZd8qzt1LH2Gy4SUvlyWpb/yma+mevYfcedRLxYME7yWe8AdL7K+iL
# DATA eXfvmS2Qtc+XUXr6gPcFJOletm/da26+n6bhaW2UJtO99c/dn0zoUetZtZfvb6JTSC/qZ9DCa9gOSLHluaX3uvfZawd2BKfRFKez
# DATA BTv2QTjf40ANK5zljB9GpxVvFE4mqNz73mMc+Kf/SgAik897yh5IJECkfo+yes+K1OvQKNs/NFRhpqvQS5eTifddb09iURuHGV62
# DATA T5fUFQpKrhxYETjwcPRTtAhYbP/Qe4KjyoMxxUq94TIh4vEndqr5UL0kW6FiH+vHM3lc/3Co8qKQ/mxD+isSb9SS2VE8OtXYKpMt
# DATA 2GKzJi0jHO5ejWR4uofJ874piggCtX+199lr3xLP72evUdAQG4omQLTWcLc6nUE34tthKchxcrIxTDFGLx3mbDndi4f7eWo+XE77
# DATA UbrHYX4G0T/6taZzs/DoUG0i3RM5NwQuehb0ps9ew9c71Jzj2aE+5iJnXF7LY79MEf0ffvx+TXZc/oCPh9B3qLd5b0JD78cI5ycV
# DATA 7zECfoLCkEdDuyHJ0+9MItbL+Oy1kLMhrGH3HzRr0gm+6fiiNVGMcWkwiQcPqU1h6+kn8TRKlou9vX20cUQqjY7JqMgjReGA+072
# DATA q8oKiQrWN3QpYDaBl9v5lMywoXlvNEPCUTZ4gIXwphD6eOeYIv2+0lqhMLJlfxpTQVa86JiL7R49xh9rUI2hv2/Lxqw9VdQcEE3H
# DATA aSr0I9A74sXp3j6FP8MNT1RU/wrR+7EcuAiPo59QJGv04DvhYLynNn/yiyZkNGehiNFx70IRwlfE58c/UW/8V9IDxhn/3eMb6I36
# DATA uR//RJcS5T92x0OXc1/Cl+unrGTJ99doVJksh1GmopF3iPQrvc9sklvc19L2KGFr6xui9oAb7d4p1DrNM8XKj3d+lyrmA0kOdTDy
# DATA GeeNnhzqqO7lj68pG64veJ9OznVklf68Q3ZQAuQuMqppart3jFiAHXzXW3v7gffjWo0/Dyvr7jAFRRZwhmRyPLh7tRIjkS5kEXq3
# DATA /BmTrWYf+nI+1JvJCxv4Vb6/qba9r9/jfijPSFi8pT1T29lxJpQMiuOoxi38ifxbrN5mwatYx5NHeQXnWzJdbPSTyRTz8OYilIep
# DATA DE0oKEQEsmIDfPbaup18drT4d4kYf5QIcDFI8Hl9kN91Tyzf1lVRPnlj11FlguQauZb9si3aByoun0HCc0q2h9Q2E4VNNWdDfuoI
# DATA qNqjv5J9NzuiySBMH4/NeM+8ly6WapluLRvq1aE5ULG+ZqHa5PVG1R2dPzBXzQjN31RPLjfQqE9zKzbG+Bb9vdzdS9N8T7RMTfZz
# DATA JrM+MYf8XclF72//lmKNCkH913SP/iTvJydR+hZl3p7JYmoIGYuv6VcWniYrCQnneo0TE3Rf/dCzGgQytVjp6IJdNVh0EeI9dN3u
# DATA NIuxyWsip2Xf++u/9vZ01O7e1TFBpDggUwVMvt29q5KC+otbZFmP3vyvOArS3PjjvqTl9deloJSxg5VDnf38JTd38G1f7siDlfxA
# DATA 71jPRySlVCRliBtMIPLbvrqnNHxIWFxLOYZRxgMHlbwu0TWNkdsR2qJVKZAcU45bG3DhIXoR4qiqKWWyDmS/WONwo7I49vbv3mOb
# DATA 8bPX3jWHwtBMXt+D2ffZa9L0KP3fke88B+Tmvkjexba6vWD/dST4f/++9hn9b/a2niUnyYJdrV648HyasbwuAfBhMwqAHlr/HjKe
# DATA 7hRvzd/l87v+zz9ZD+oI7fDcYCqNW2aA+YFMdzDbHcy+6GC2O5D9Uh/I9grbjdU56Of6oLbxnPHPhROAE+v49oM5q+VhZIuHgI3o
# DATA 09v57bytmM/JPV/nuV+UU40XCbfYjlKOv3ic771BPW25GepFMkTDrFR0Zb3LWsGTC+GEvxUPqpcXr6RJDxJkrrzpdDbQ0VB+7Hs/
# DATA WFn7YjOV7IHSwX/rGf7C6eAMmN/joj2gcoceDJUX7KF0cYpNxeb5uegGZOOQT8TqGuWpDRc0LeTjyMs+jWsevLoe5iAU5uccD96l
# DATA FCdpzfvBPJrxOd8Rn92nh9Rhfq6sHoU1Rq2jOunJNgTGMOFuejMYCxTQTOkG7Ki845V83FpHgM8Tc7TJWiAj+wjn0owMz9/gmDMq
# DATA HE53M9HB+2hp3L3eDJdZ/UjeEdNPyznMhqzmwZbiHzM2qZIRnDzUYoaw1FSzIXM5YQmA0TIlK2K5qobwch62NSE4681ZbxdZb8Ua
# DATA 5vR1nL7OZc22jQbiTenuPMAWNksOAq+BbxPCeUaB59lpvG0bLrG7z7Pl6gqWHK9/sP2BRRG1JUdf48JGJyR2LPsEdCYrL+DedP8N
# DATA 8YnqBjjj9SgUkoRmnjPdVX6FvWK8/aPW4k1EWsOaks8bonBxGvJ+o5baTBLNefdRTXr2OxzHUlTFC2GqA77tEFH9lImnuWCi2ai1
# DATA rzGa4hmhn7WXhi+8IY5WFSl9j4mUeeiNhDv8PHIB3nzPPwjqb9xJlFVYvqel7mltucevq5voQ37XHYlWnhRlq+vcVKtg9GDeDBa2
# DATA 5BGZDfwEGxLplN7Le4JVOtVqKEYvXTXzS9LzxMf8ojmN0wvJgTsSBOZPKrdkndYOJb+kd6iZK/csgzPEhMzqAGxpKjYapdkvKVUQ
# DATA fjEG5Qc0GFL/LEaj9lpb7R9jbDTjls+Gohlo41TsyJp3fzj0+EysMgsyPXzmNqT3PtZQlKonJgJmpF1CNl0cvWyUiiFOPQ7eiF0Y
# DATA 9Lb5cjLhH5dYhqVBPU618f/DLBLlHRGxEd2fuB9TFovEvBaR0nUeC7YZR4HMEhgWbEqjJ8K8Js4wLaQkzaTz0ypXbK9PIHxv9XIY
# DATA A/sR62VypnEHL0XCpfHyW832AOgMZ2c4X2Q4lwwkZzk7y3m7OfwcKFZ+Qm/jxpGJZl44VK0hN5tLmo0YXIzOGysiPowWVKCzI5G2
# DATA K0ovChMsGWHcSpQEZK6UKHqIZSO55J/FdkUpBbVl8Y1xg/XntJCzbuwU44a4zIxIJSwY7FOC3mIo0WUx7GQ0wvYvyPRxX5B54+SE
# DATA fvaohGS45Lyuecq4gKQlxe4Y4y76mWTEHQPnuSVfKT4rTk5x0FuE7M28n2K4mpiRzqTITtr77JQLB2TjQEjzhHqsPGUYeas8ZZAN
# DATA 0Yw6DScZbxeDpYMkHpEtlulebUiFN6bejEuJkymnfCiEGYuKw41IptORzJ3EiNH+smRKVuNCqQuGsAoeelopZEs63w5PuSfenlCU
# DATA obgqUcY6jQ+U/3EURZSsYTxiaT+a3cFQg8Ah9jBiHwJVq4VswWC6Mf2Cpohf2AT0PmEMj8d8QQTIlhUzZeEYpKqoE2Isuv7yVCr1
# DATA 6QL1GZtEtyTy4yhbk0AxKwpVeFVQ1VR1slLZb3kCVXhUsgmaII86abTOiEWRVrQdCcJbOIxx9k4GOrFTlZgk1d6Pof8ypEwku5Bt
# DATA PyQfdt6SjAl+4qF4XLVLmSFlqN1TeafYk3oqraVOR3E65cWRdXNbTtQnlDcyHwejd45jpGQmGbV1akHGes4XvzPxX8v9lB9cHckU
# DATA UNPzMBNbmHsn7wMt7km9K8Me2JRWIG7jQ6bG85DNY0wNyPClkg6XixjdRpiyTtdUKU+y+ql0KOBCiduYLARcV1OKjan9m1lyIvUT
# DATA rYSaCPpICLbqBL+dcPgL7KtEbktbpATN4UrgrpHHNrFLLL8CGj+VMrY0xBMD10p5upBScVP2kY1EGSYppCLHAWnsyAhXFGQL3TBP
# DATA EWanZTVZM5+wZWUtO19s5pfQ2n/ypGIYOosjwHnTU5ug8/+d/+rsD2ffnP2Psy8VI+fLsz/T/784/6139s9g2tAPP6d/f7uKzvmv
# DATA 9MNXdNNXuJ/hN38+/83Zlx59+Z2B6HxNgcpl/grQzi/Pf1Pxzv+OnqNncBvoOd/Qm/7IGJ9/oB+EqfPHs6/Of60j8xe65Q8C6gFs
# DATA x7F0XoDZDDplHF+iDqdPfxYF0eyjKKFw0nigTbCa986j+UTG5wn3iJH0Ddk4nlNvMbG8EbpzxCriPMp9BvlcKJlM1PhEL9Uyv1uh
# DATA OlhOVOGpluLQOsX5je5Bbhuss65kbg6vk1cdcytMuvxy+YGJ6E2bu9+X7zyiXzNhh8c1NawnanMrBlMH2Nmx2K4fsYO194itTxRO
# DATA JXcxsvGL3INDJouigmE6pvGE85Hl9rMFZqql3coaqYkgzKGUeLHC17m4+m12aK5pWc8Ks3NxMhxnx1kCN2EJaODOFQ2AV8S5eWuD
# DATA /42M/TsN/Zcd+W9n4JfquZoPOYPn+WtdNwHjsXKAUTzFV69J7yrIg143nauVRFV4lGcpXqrAN5FkTabypuIpCWwvHZ8uxlMORQ6Y
# DATA cAbtiuBRRZYvRFJHPGG8zBIrtVBJXyC3F8o/K8fkRuFxglFBsWZ0jPECgZvwcEoPaotBnas7zO0FIRbB9wMz4iScLWy32CCZO8aO
# DATA Y+w4xs5NMnZ2HVV2mubsaiXfssl/FYv/Ogx+R9txtB1H23G0HUfbcbQdR9txtB1H23G0HUfbcbQdR9txtB1H23G0HUfbcbQdR9tx
# DATA tB1H23G0HUfbcbQdR9txtB1H23G0neeJthO0wqvSdjqj1mjwAtF2Vteed2LucO6q3MOuTI/f1W4XFNJazVKuN9vdIjcnirojBTbC
# DATA 4UaK3oADbbRZBmTAoQYSDEtl+M12EeLToAxfg0bqNL1mUPdAt/FbvYnfrXtBu0TtafutVre/SsppNrym3/uR32uOm93jIGhN/Y7v
# DATA 1X/k1xvjZue44RejMAiGzX5/TSJa3XqeCD/omUQ0igEEvWDYWiX2UMZ6zU4wVrlo0XPMAyv0nPYV6DlcYy16DlX+Aj2n1eyGV6Hn
# DATA tIbRyM/pOe2g7XeGhp4z6PZHw15Oz2m3W3735uk5qo5XuRqbcaEhBB093BZuWueoavA4Uukdn1S6bEkV1phag/HhzqSd8tuUg9t2
# DATA bYmJoe7C0YLrwe3YIa7idtREs2uMVZTxIe/kGIfD5OSg7sG7Ufd0SRYAPdyuV1+h3e7GNO/I+kkh10s3FdbKZDgvwXAON+wHWB2t
# DATA FCVpnadW1m23hKy6GjW06YaS14ymid/FrlTVZ2ym+BRK+wIbsZB5dmGqxOjJC6wQR9lxlB1H2XGUHUfZcZQdR9lxlB1H2XGUHUfZ
# DATA cZSdV4uyE4/EfsO6B2r8Y/ub1J27asRUA5f8VuG6uH/4xML0PJZ8Q2bc5WBw6sgE8zo9AfzOZ6+9vvoOVakP9YCiXrJ6Y36LOqBB
# DATA d7Gde6ggQR/iGJe0fDblJ6d8Oke/tRylmvfv1Bl461AaHzxDWVOFMlGo6hvoh+9uG/GvKSuMzWySyotTtcWjRZ5m6h0/e+196+Sd
# DATA SQZ1lyoFMtEtnfNxR9DdEfSdj6AXD4S5s+juLPrqqcGNepvPwxn1Uh0vtBZbnIY9fyxAi8qc5WopSvg2HkZhVkC38IloKFuCXMQj
# DATA TUbdmZwT1koqvJWudFp21zPonATWZ8RYzuJ8ShKUXgUX6lz0+Posu4j4rTkMqnZZrerXK9sVVZA/KTV4JRyuf8z1zM0V3m4L+c+I
# DATA wzHRizMrqzervBuDmKXR5XNR4926w3Sf9lMrCu2wKHG4Ex2a3MfirpsE3VWXymF9T33efLccr2eVO/60+U7uc5XM7CDafJ/025x+
# DATA /rRFVF4Ommo5d7FDbTV3DDFbtNwLNQH+c1vWNf8F3nru6vQ8QD7pPC/nWUlsk936phcQq5prXrrk3PiXf/qPJh3liFv5P2eJUvQ5
# DATA k3Ce66+qpUTek5YuIZEAGy1hKYYZlOBZixpqpTHVQoYyhfM51UnW16WOGa2PJrGzhRz/hx7rAvpHWoeWtap58UOLzJ5Q5VaHxZXP
# DATA y26Z+cln3TTyg9XGcYbLKikmZ/TRS7rAvmCuKXSvBQIoq7ZeqojyinrZAvr7/765gHSll+J5D8VAFTnTBfTJSUJtNKWOzdOn/DJl
# DATA glCftJzBE0lD0rzmvUejPIycaXIsghSUBhYcgLDBUcTdKgpI9g+rcoq0uoUqracvFZOCWysX0y1ctlj+8b9uLhbVxUipiBzoIElp
# DATA MmJazkxNhOUyT3P6rOnKusryyZuHaFhDMR1EwXdEfXhyooqoaEeyNDubxYVx0LocL2BEP30p2Sm6tYLK++VL93C/3VxSuo+Xovo0
# DATA TKce7+7Ku7gTXBM4zvAYWthUMkdUMLx+gb4ukuF+NhQpjYjVY6EzHc0AwZESULOBfsTkjnghmhzYHWv/zNSJpy+fPBm3VjpPMwL9
# DATA P/+8+wj0FgbZKJUhwdIBn7JdTfFKHypLm5tUOGH18tCbLmn8mYQp9snNIZ+MjPZ+JMajGmDIRALDQJoNSvzpS6IQ3RehqfynXZvK
# DATA g2S08Pqo9iFKJ+/WMMb3KYum0LKBZsyARh5MDlgROhz+NMT+HFXjMxRWyvZ4PI0nOG+AnIJKBVnqny9jUauBCiILq0gBakXoa2gq
# DATA hWRcqYCKRqB4NG0j0FyR7L73YaJ9j1pTiGcfyieYpEJlxACdcCeuC1YJ/zwNO+jVEHdxcG7nSruCK815zl4Rz9lled3PhbpjYf/l
# DATA dmy3zLlpIF1gqyZZlEfs1NpI7n5OVSBfING0i7Sh7X2PN0HxXm0l187yXisjuonovZpydZtRxxbnCyZBNc83ktjsTKqI70jUIE8S
# DATA 47jInUyK2qccwlNAuY3MX17QFW+ZCb4UsoAUDHZGSBKyshb2mlqj9Lm5TuZ6mlfSAv8Qnq7ZEaCBAhgX3R4jBW4pC2rwjdLMOjBy
# DATA ojCrc1FRW0nUY58JWawLKS3Me2B9e9iIC73N40J9kM1sklm8XRWaqLO8wYt2oc4t5HDtVTIe7SCc+ejMx53NR7uuuXVYtw77lFbj
# DATA RiP1ZtZhPxDup60UnRMPnw2p4jYo4bz3B9WLjw0WljnVTzleW926sl6YLyTly2Ob1hbt5Q17tWbT/SVHe2kpYdNTBfdvwae96Ymy
# DATA m7LsZt30XNl7VvYKblw5LZQCb7JCTFGdhvGQ64MsNH33DS1fqYpF3Qt+uew5FZa4OmeqSeflRXAcMtf8Pdui8jT3njp126YSl5l+
# DATA 9Q4Ucd5UMD0tNKAXFyGOhaYFk1Dn6OkzZakmE/st0VyPJzLjZBM80jMpA5Gk9mNWq5ZsKlBo9Ayee1t3JOhb7OHZUwIhPAEwJrt6
# DATA 6lNY4tL3yLrjUFzLvK+cYgLhbizQqCfuJKsFl88b1zuN87qW7y0Ex1P3UVTSpRK+mAH+8ljJFhyQpZCSaYEN+B8VxO+bsz/Tv386
# DATA +woYvq88fGMs3zdg/f357EtA+VbpgP/97C9M/Pu9uvurs689BgX+7uyP5//X2R/Ovjj/JT37RxXo1woh+PX5r3CNfvvm/OcefQGR
# DATA UECAIBMiDvIcgIXMDfyLgwG+CFZ/oe8eRSdkO/Akeh5CulZBANCrT0eQj+hDsktjQKjjw6rsfYXVTfrMPFDdc193WrrPXs75NWhC
# DATA HB4ZGQPxn0SL5XwrAvA+pC684TLDZhdqzw4AWLD3dS9x2/y/1WK5OfofW1hMWMlvLdS3Ms/8TnQazeOIrA19/zvqggeVISC0k/Sa
# DATA MYCsHsZI6OWCx391RouamCMB7lqE148CpL4Gi+DU5mfxCJ0Ow+AZ4oztcmnyCBo6EZ9dFlMeBitqIXVugwW2MCxZ+l9+zNTmE733
# DATA RFc0camSJc6MG0zj4qPZChZw92q52dZZaXjPCg64e2IcJNBZCNdnIWg04JUMg1fDCXhrRsEN2AQ7mQSXtghu1yCQKlrODmMGPDet
# DATA 6iaQgFaq1fLXhihquBi7Lx6eekdpOFyGCvqX5asPkDEsrrExarC4KHEqmz6xNH/MriestbEsYjaPBhj5jSm2ExzQjOuszE0JzmQf
# DATA HWXgCPgyroDVZFRF5eR+lupQzYOKLY7PhmI5wEfHBDwVB8VWQ/LnKV3KeC1VlbYy32SRkCPLN5rsq3kfRgDIyQXZtPdgCTMkTZZH
# DATA Y285o2JayBl2fnHmMIIOI+gwgjeIEdx5GNppknRZg/pW5whXmSJc5wzBUQUdVdBRBR1V0FEFHVXQUQUdVdBRBR1V0FEFHVXQUQUd
# DATA VdBRBR1V0FEFHVXQUQUdVdBRBR1V0FEFHVXQUQUdVdBRBR1V8LmhCkadaDjyr0gV9LtB1AxfIKpgeQV6J6ZgEZ7Xa1rwvE7dwPM6
# DATA xXwdDqLmcLSGvtcObPpeM6fvtXsb8zYvmKlf73qB3/F8v+l1O16vVfVbgec3fSovuhp0vG63hOXrtHvdfncdlq8QZd6HuRpfeqGF
# DATA PPQ7Jr6tImCyHrUHnTXPB0GQP9+o58jE7m7PN+SVKr9aQZ5fuz3fbFnxb1j5veP7W10L+dhsdC77fr9tl7efx7+xY/zt+iJly483
# DATA d3u83bGTb8Med8x+eUQlv9277PuLuVff4fWXgURKI9GQSOnLLEjkoBMOO34REmkeMZDIoN7ot3oFSGTQb3barRwSOagP68ORgUQ2
# DATA B+1ut5lDIkf+sN0d3Tgkcob+vJo9PM3XOeQI5XF0DesOgeXq0DYX2w/mtdoiLJg+8jKazWBav2YPi8pwO5gatIuK9r0Vin2ntnJ2
# DATA I1YWIqoXPRQXUUpQ36Oy5PGuuVZrW1RDz84WdZund7UU80bPWrFPvuBoLQEdt+xQUPsRJB3VjH6YRgcQvdxMaTT5UCkld4vpVy7k
# DATA ytbyYmeKKTKxB1eqiZhPwS45xSE4CqSjQDoKpKNAOgqko0A6CqSjQDoKpKNAOgqko0C+YhTIVYjjNDy6C1OPenWcMaMk35Gv+iQL
# DATA MkEhFz+wFQXQql6np6kuvIsNkXv+/uufvfZ//qnGxMP7a3UG+Jk9CT+cy2EDvJGC2TfhBAjnf38h4byFFs/Hl6bhbDkKWadfTnXJ
# DATA eURqznM5+oZDVaEgF6JHdCMf/iRzIKOhrUBILJzRcafv3en7C07frznC5c7iu7P4T3MWf6Me542e0RdFxIQPIufHvWVY+a7R53z2
# DATA 8jG3odUpox1kVE0URnxAVlmde9PpvqIk6hY6YwdILuingzDdmrlgFC07raKS5DSeybpXXalO8iqQ0pvEfhv+dTNP0QzKdlW5bLyt
# DATA QEzU7Wsm9kFrXeQDK+rdQsTrtdbmqJvx3o66vqjq0d4wOkojmqpfkAIrLJMC+5pJQXtt9jfs3PeDLZm/UaFTtxLUaOkgXlR1TmvE
# DATA ZR4i3ZlKa9ZH3AtmH+ZNi/VNhl4V48h6/zRv5PYNLLIv8vlS3FG2kK5EnhQ8o6kSeRh8c/9UUI6FfknrDrB+hQ6N+hEyApWBiPne
# DATA XMyGYYy5Hz8GDWGW1DgJT2XgkeLksT/TwhpHy5BGnEUUsTS4Erb4nDo4Mr9wtF6JgqyJ0Q4Cni/fgfXSqOgsa2dZX2BZl4wmZ1U7
# DATA q7pgVW9mKz1PylfFVhCa/DLiVz8Ef8+oHWEVO9c6Yj0ZuMQrRr9J0MXRNM7mLEHjfWLoKmy8s25OBM/cScRk1oqn92xgVIrmWMZP
# DATA 6RHUn7JFXSQ4rohdmfto6H83VtJH4ySNf5YYyRul4B96WTgCXydKyShiCSZTKtk8yRXSWaKIRaPULCIKs1MeecfJNIIoD88myO6r
# DATA CCdDpHhwL43WNLDGMCG4s8oot7CKoNTAsVVhw5ShYNsMIx339yHMU+wAsXVCqfaAB5l3iMYmWs5CNmyoXtW8N+NZgjpEz2jMrjYE
# DATA ZtGjBRuSvKSCDFL9aJLBbaV6WGUCSRWY8sssUOg6Y2Jt2v7GBiNMkiOdwo9xolnKTapVYc4WY0EW6h9xLlZkuAsi4TU5VWr53ONn
# DATA D6Wm5eOG3hQp8q8Z67+OINXOidCKpAw9ZVyYx2fBgNtG9i6ybYn6SOS8pFVEp0oyCyP1fMpdmKRRVMFEfraflwc7AHPjNFwYwbB8
# DATA PKK8oApLaZQJp9JToizDLtcJ9pdwVcYRmtSu0KcZfOMcm0cUwIKMw3gIGmzNezvhJonhzyiTQQROGYwjdH6pFZsVAhJbVhfqvpq4
# DATA 9ENV2EtLQd+spxgmqbkig8SpXNAi+2pyVnyefyxOvfTiVGFaVecpkOrP8r6MiQVSc3OovZLZf6r3+YY8MQlPFTq8aKpk1BNe7zsD
# DATA HkIZ1zOMp9L/XO8bsE3x3od67ECa5tFsEE+u9y28h/sd3YL0Eprdg17v+1oCsBhFZs8QNTy2JWfU2orvurOc3BiD9uWbXzkSrZta
# DATA 7S4Z7CZSL/1E6rLo2edLQtjs6b0Jhmk5s6+dYLpG6fhifumkQFAQDWB2QxZ1hbfgdZ8vHeUXUUJ0R9yCV9hYro3wXG5V8sVMNmor
# DATA k+N82lvxjqDQnM9pMAvzQkyAsdXKzEMHNAW29WNFtRWTpmxRmpXm3oSSJ0Hb3yKgW6i1ZL0cRxcLSaNOTsO5BjnsVAZrSvSjNGKP
# DATA ekENO4uyTLMKXyHTLSdc9cOHUVrAW/23sy9BnTr/+dmfFYPqD4y5+uL83zOu6n95538PzNTZ71bhVv8ZtCoGUoFj9fPzf/TOfn/+
# DATA m7O/nH15/msK9KuKd/Y/6ZY/0fdf4rt39o0JDdSszcCrX4JrRf91TKsXgWRLdRjPw9lAFYwlsEPGPcsQQdZWzCPBEK4JyJWrzglz
# DATA MnFpzNhpwf3SSIF5hnIpQR8n+2uFkUc9R8aerq0IqzexgRbtJEJn4QBWtgEqncBt06vKJXJz7CpIQg9L712LrOIqZm58myvczcCq
# DATA aNSbq02/qKXYJJwMw1PeR0j142HkgFUXldu1c6reRDPgEphHKc6KsmI9juONGLAtpy89st2hZaJWQawteHq9H2L5R2k0jCN4o8Eo
# DATA oD41SuHtypdTVL8Yz8gcWkoOe9NlJv2ZmGGnQvUexPNohWK1S03dbM+Umt6zolftkgjHrXJWwJWtAI2pusLg/0p4nm5p4L/2cX+n
# DATA YX/XUf+2Bn2pjMXUm0H+WTWWm6BPFZPojaPJHNYJGR5AMJvI5QlOx6eL8RQrspL0AxlqIfSOEy4L/gC0NLJFVkepwwTN6D0y8MNj
# DATA GicznR2pSJvx1gOsyaZL1lKk+E9jwwXazp5SuyPgYYqwRB3xmS4ZiDn2GwZzcXFYBgHjiXgsyMSEqKL9DwvmBe8D1JsoFAqIX8IC
# DATA CkBN0T/YUwE7T6+RLxcJ5KEGTOpygCkHmHKAqZsDTF00juw0l9nd1L1Fq/0qRvv12OyOJOVIUo4k5UhSjiTlSFKOJOVIUo4k5UhS
# DATA jiTlSFKOJOVIUo4k5UhSjiTlSFKOJOVIUo4k5UhSjiTlSFKOJOVIUo4k5UhSzw1Jqt1otoPOFUlSo9GoNRy8QCSp4srzThwpO1OC
# DATA ttfodD+vNqt+t+v5rWY1qAf01/d8+qfZ8+hrMYcGUbffaK3yoHodLwD1qeH59e606gf0T1N9LYGgKJPrg/46EJTfk4Ap/TEN3Bp9
# DATA 1LDQS41W2yp6xUESKFERXBU1w6gVrUS02fG9oEvJbnl+I5g2ulW/2VLfVuIZ9fujtfFsrNavestrtlrjdt3/wG8GXrPrj1taL85i
# DATA YLWaQbQuyNUa225STBv+j3rNad0LWlX6x+9OA3oNFUsXn6tBl76s/lB6abfbbgSDLS+9DOpIWohGHUljs1BH/XrHD4ZF1NGI/2ej
# DATA juhrOKoXUEcjfzjq+znqqNOnrAoN6mgYDlq9Vo466jZbdb9146gj3mFSZdPDZgmpyBZnnz5GQk/+S83cngzYTCOZGWyD/PDIlb95
# DATA B/pQwQnXNk44WXpbBRRZYa865HmElW1z9FD0cFc4kbY0gnIA3iXG6y2PbR+8N0KIrBK0fYGemNCb01Mq3A5KtaOKtpg/m5PjSEKO
# DATA JORIQo4k5EhCjiTkSEKOJORIQo4k5EhCjiT0ypOERoojxEevKMGVk7uj78il8elQVg8B+yHjppKZn7KQLUq+emqunkbUI6vLmj70
# DATA LsJlgtDodcqhI+YDfUoxlIsnRRCR+v0BBc8/Z2t/fm8GUSQYC/Q+vu907X2fJItwIuf7+K4PwsW4xn6DvdHrJ69nr5+qm23OUH6S
# DATA xR2Vdkeli0elrXNN7sC0OzC9WcrvOThIjTOpo7yah6deiN8L8uYLVj6R+owSMBLhqDcV/AzZvMkkOdl+1ncaP+Ljx/M0SUb6/DF0
# DATA xk1DpfEXW1GWaZQ9hbY5jYjpKZKyoCxB+vRxy/tetpyjU42GqkXHmSEfkWWjwEYpDXionZDTm8QLLOIkNHnIWAlbQCaDdDntH0Ib
# DATA Jp7xeezMHKoewdl7zOd3P4ULt6BgkrKmuyhoZ4Mk4ScGyzlktuVc8zYF7bdgQ6Snso/O4yEqT9oIIutQAUSQXKqzKBpmujuT9GaL
# DATA VMxlKsdxMhnyWVfEnBJLc2CWA0epjPDbEUV5cspC4SbbTNmJsg7LpONUulZF5zRgIjdJFkg6XeonJxMvnGQJHwzeKhH+LlVvbjpy
# DATA bJveGqVW4bFgc5+tTc4ufXOc6VP0J6iL6J5Z3GeC873ox2seK6rnPfkAG1IiyKPHEz6Zi7PxWc17i9Waue56GlCD6kCRR6hIbTjE
# DATA RiAOyxxDVKr+4eIiUXfOOY7zCQ0kRlcQ21Fx/t3DURq8jJpOOOXX0UDHpaMk4QfLhRQuttXM1Wlg0Yk3571xZRIrCheqxc8gU89w
# DATA nMwomj+U8MS/wiGSaTixsyQ257nDdHo1XfM3RYgaWUeN/9LC5miE161s/jEyH4U3gnNaeqcbEDTP2ZYieISiYEPUy/UIbkDT3Cgz
# DATA slEzU20P3SzGvBuQOL/P3b6xlZSaxO0pgb88B7nzQNyMws0oijOKcpVy0wo3rdh5+rBx+nFz04oHyIochyPR0VOK514b8DYQpeJI
# DATA o8vs+fL2ji7CYuoHTIdlLuR0jvpVgKT1zVjP3LVHt3xff/H2vn1RZO0HTYQLF3OKZ3ddnJstK8q9XQmq7G9kQslksUMs1e054lV9
# DATA L5hUK1GzM7NRJKRuiZo4Penngldyh0jqB00szYXcrq11LoposC2iG0GoMn/FaGW1tBeXhipNLc6KYkdGs/Rd6luodXhHZi5e8drd
# DATA b3um3npTMqkzr9FU95zAP02zfJpIR0cpOkp+SiOzMP0WbhbfyN0Rf1U6bDIzNZDTmNVq44Hp6vDG6JGsmegpA5bBMKlHWCUpM5bn
# DATA svoyLWCbCatMnpZVCEz682mJxE6dPoi0CtoOlNOXx/Z29B1ne2/35jtD+6U0tC9L2XnGQqi8AzjfILtqgNoQGhYdDLUH2+iFShI2
# DATA U2ieqXzqCyEryP+9ZqZRSej1uolGK1K5a3lGO4jXWvuocwlbfIsgXJmEo4oh6LCVtczGysAq1VPsFJeSVbvF3xg37r2bxli3wS5F
# DATA 9iLSJTDq40ewYdj7L+e5mHYYF80dmkBiFhitW3ZRqpoiZCr6pOogA2/hUiZP0YChaanlUTVWi4muHe8HWLNCzMm+K8VcZHfNogrF
# DATA jtcvTJsQjVG9LKMYpDhOhu3Z1moRy6fy0hPOIm6JMJr9jrHlY22zhOm/HN8HWAlSC3R6+hwVxVHD4sIeL5lMzKofxVHBJ7ECgUWw
# DATA zRGll63L11dGu9MiB5HhNgCHx2IH/aezL8/+ePbN+S/OvgL05+wP579hqA/oQb9ghs/P6TfQhX67Cg9aefjsz+e/AW7oF2d/Of/5
# DATA 2Rdnv6cff80Moq8rHn368uzrKj3xFYL2+J5v6B56h6CFNsKEKHS85Qt6A93ogELPv0X9Q+iX8Tox9yaKFnZakQVBXJKOVu1OTaMj
# DATA 8Je1nLMs/Kv6agb3lEWbC5Rp6o23MoTeGoeiamBJhjuOkGVdqy7htklC68rl5mhCvCFgnMzNjZ+qC+uZQqM476bfjRfGE3zNNCGB
# DATA GrO9IL4ii+jzqnOEdimxa6cJ3fcEvA4QeHWx7Eem5MWDH2MP7dSTneA174OEasDMgBCpEI+h9w5JD6wRsIYHzLJQbXYJ8Xkimz5S
# DATA uA+nzGMUZx0bXwJrhEhsGR60vUpuNmLWtLNnhQ7angQHDXIj/WVGes0JuuIA/2q4zm5rcL+RsX2nof1yI/vND+xSLVdzIN/oenut
# DATA 5SZAQXnKIKJFAWSrcV7A44bNmnrzn47v0qSdDzkxTkQXIAgwMf/OfBMsgTFtRW0J5bdMwxmlLjPpltSa4AUzNJ1TFzZb7IQNgn21
# DATA wEF+5AOFNEqpt8sH/ViW+/XCFoJhMTmGGBkCUBpJVhkk8qkAlSvWSJ8A85OMBF2MF1FF9B4skOyYPR7xyKNW9VBoKCfUUWDPINog
# DATA bzBIkXfaIeroQY4e5OhBN0gP2m1M2RFqfrHNe8vG+1Vs96c13R07yLGDHDvIsYMcO8ixgxw7yLGDHDvIsYMcO8ixgxw7yLGDHDvI
# DATA sYMcO8ixgxw7yLGDHDvIsYMcO8ixgxw7yLGDHDvIsYOeG3ZQVB/VR8EV2UF+tzFo1V8gdtDquvNO/KAjk2TeRVhkzQxb0XBU38Sa
# DATA uffGIE5h/wvYJ5CEKLBPh0UaWN7A9xVhqHB7u9684HaL80Nhe3SPR79V/R79rdO/vdb36frE79XpWtsL/CZda1c7vWrQDMbN3gcB
# DATA gEWd7rjTnPqNVrXZGrfXxaQZbIq4AhjdOSpUoGbgIzL0hmnV9+rHgujZko3RqN9rr0ck1VeqJ8W5FdTH7Wb9A6S62WsdN+vTZr1Z
# DATA bdbpUxlB1As7/fa6oIPL04CkzmsakDQfiwZEyRh0GkUakN9pdJs9mwYU1Jvd1rBAAwq6rUY7zGlA/dGwORwaGlCr0el3o5wGNBoN
# DATA Rt3BTdOAlFGy3vGh01qytdRIhI1r1e1WiEc3Y9jJ7y2Df8xEad2kSLvRMNetNGtN5v8EzP9ZXY9qFyOljRurmxbbhRNCOR6m1SNM
# DATA jcGzqA+jo4q19m5/9oLe/FHlW416q9Pus9tvv7I5pN4lg9JRzubR4LJUIm3zwnu4YlJZK3KbF8fVUrj4hKsZ/TCNDoZh+nAzeyjP
# DATA 4Yod9c02R8nslTrEtpMjCTmSkCMJOZKQIwk5kpAjCTmSkCMJOZKQIwk5ktArSxJSpJ9PrGNd+Xnu4jmuMoZHuEFyypvySNOFsCMA
# DATA zQh0nsG0xjCft5IpC6CvHPLm421YShK1qhAHVZKZOr6mBWmLB8WkjcpETp+0cGec3RnnwlEbd9TZHXW+4lHnjeKDN3ME+t2YtS74
# DATA LC27IMunZ/VR6OdNbuM29LjV4IKqQ/VVSYYjlXuD6UUSzeZZ02HlV4xIc3etNnfLFmn2/XpRprm1ReqaBz9Iuqjeiy+8IbasUVGW
# DATA e3KBa/3QGwl3praEdJuXez6mvk/hhbievHEnUSKBa55oc3bR2OLd8RZp9JC1Ii98rMUvss2AKQwalk8uPntHUrODUPU7un6iynqo
# DATA si+uSvUHUZgtIRqNg7WDMM0Fqh8sRJKPepIkWcgNcqwZsj7hEcSe4Y86oTGr5v2QB7dJdEyVBh0gOtWpCpubsYLTJKkRHkoTMidr
# DATA 3se8ACCmkTzAeotK2I+Gk1MUNBVEvCjIVwOmVTi2L+dIvXSJM944ch3igD00HM14Dv1AstioznLhZzQ7W2bzSPQPWTE7nC1HGIhT
# DATA zKUkQHCRhvFohCvLPuupxxinKTDG7qyz9ZQIASVhsbPA9ctyztfJWzvz1TJfnb36Stirl9W2fsaSPbyunS/Abte2vk+jERuNbECy
# DATA HZvlUhTMUci2aFzfttjPC6F3cROy1qv1+tqlrddqOl1V3jpf9NfmmFgUyvaJQBblOpeLWrP5c0omjQA1eSmIXlfz3hTdIJoliVhN
# DATA FM5gonwKESGRe8kwuDFmVAiOXN1gRpHVFWvhZ7LhErJ5yKh7SG/QxJDLVZwfaCEWo+pk3OGvluJJIWecMeSMoVKf6rx5zptX7Ds3
# DATA WlHPWNCQecAAFyeTiejsl4Hdqp2EWS7hV/PeFU43W0nr5PkKWn7zNBlEQ9C4RYouST9fRuLLeRo+9/3YQJ0NjXdBI6hmAk7jhaCm
# DATA ZST1WMuFY7DkRn4ULo9o1PyYhmFNC6xwAGKWyHKPwjugwwhHIzjF2FWSuzzNOP3eDOP9Qvi1S0WLiKb9aAgRtGHUT2lEFioyD6Es
# DATA AogdSltR1jL65/KMggMOqSrAD8qagso0yLR1AeU4+GtScZYq8WmyAYaTqB+mNe992E+IJlVSytxQgcCGIToYIBH6ExFeG7Mw3joh
# DATA Q/6YWaqF4pLNQL3+nAo+HkHnbRph7S8ebIWRj1nVmivPbAEPDnuRTZI/BZQjGY28IxqydBJln6Q3WVKmDkIoNnI9Bl49PAlPxTGl
# DATA 46nKMNNuHc4+HgcoGBVzypdMFLjhX2IV7kMlawgpzJRPFqiKa6pzAayxQP1h3ojXpwhEG73OKtU80sjYAplw5oPnQtUQnDIti8yY
# DATA hBIfg0zC8k/xhH6uaD8UJyCH7QzCND1l5cb7lGch++1UQEKYF3ic5vgchyzJl2fSh1HMqRI/sVK/hEvuKEmGlrtd3ppQQ6PRcCRt
# DATA rViEV4N9oy2fsuoj9THfvTTsG3G7bti32OWxNHClXxjPAI6PhjcA/X4TzHslF6q2jtwA4/vTkgrpjbyJ4d7vo2lIH0PjmmzLyYSY
# DATA c71v41NAnxpKIlaI5mGceg/hLQ5XU3eTRPGXY6pjwWWSMB0ewbdu42X+i8LIfMNQF9BhvvTOvjr75/Ofn/9mlSfz3+i+P5z9TpAv
# DATA fBeTX0CF+ebsT/TxC2bJfFXxDF/mq7M/nn0BXM1X+Kmqn/rKo69f6KDoNnrhL89/peAyFI/zv/eYMfM7sGlAoXFQmRcA0zjTzK4V
# DATA X9w8SoCAViP3QgSm39LzNfF7HPG2bQxyChrG2r0sL5yTu8zAR9HTQ+FyNtxKmbnPt+RvdoyZwmzO9Ay3TZlZLZebY8xwAs1d34OQ
# DATA OOX1ZFS+bwjtZwP0wn7fRRqeXidahtpARjZ2KgLmNNOANcYzMRSEg8tsL6prp8qYTmgYkxnPJ/bE1CHzFU9B5D5+5HG98D7m7QHi
# DATA tj3C/sh1m8qFfQiNdq30jTKbRQvWNMfeDxrDsxWGzLaat9lOWWlDz4ofsy36jh7jhvSnGtI1TuZKI/mr4ZO9vVH8BgbxncbwHYfw
# DATA mx7BpS6Wk51vm3yGLeYmkDLlhOZkGaM5kceccjMKFWIG7jeWG4Cna0ZFmslqLZJh+BkyrAI9cRynjItBYWmsDKU8zHARR8YNURir
# DATA oTKwXgIicwpri327EuKRbDPDNIE+9ificTtKIz4PINmut7op3zqN/pBC4O8X8kgOMf5zlqSWzVDEjESpg8U4WIyDxdwgLOaCMWM3
# DATA JPyFlu2tmudX4lQ/lXHu+DCOD+P4MI4P4/gwjg/j+DCOD+P4MI4P4/gwjg/j+DCOD+P4MI4P4/gwjg/j+DCOD+P4MI4P4/gwjg/j
# DATA +DCOD+P4MI4P89zwYdqdZr9ZvyIfZjQaBcPRC8SHKa8570SHsbOlUff8Vmfc6DSOg17z+/S9mCP9TqfTHK5mZyvw/G6dMrRzHDTb
# DATA 36fvxeeobnb7isvCZSllJQV3KhyWoKAr0ewVy7jZLEWkH/U65QCDoHHVAIf1XtBprwTYDa43ho2mf70xbErVub4Y2oVCZXkNeWgV
# DATA yiUD3FDKVqFcSwztQrmWGNqFci0xtAulIYFfX0u5ZIAXt5RriaFdKNcSQ7tQriWGhUJpNa+3pVwywItbyrXEsFAo1xHDQqFcRwxb
# DATA gdWWe8VS9hulENWFVOV+efBvR40Siqvda4bNtbC0ddCxVqthQcck/NQgwSwjRYe6wk8LWk8XQKvbswJo9S4fQCEJvfZTJmG3AC7D
# DATA MxMbTfPMxNyzeGZhs91sREWe2Yj/Z/PM6GsvGhV4ZlF3GPaHOc+s02+3W23DMxu2B37YzXlm3UEzDG6cZ6a8HmpDg5kJiTOebEl2
# DATA UFjeC71IbeZnXV6pXLPoXwy5zDH7XkRGbBxWJCalvShrgrMdkbzIUwxdrfteHA0zfVm/S07fTpPjo2i3paLWLovTVqjlVWfbZ6Lr
# DATA SNHtHMhEfmX10G9Yi8TqXj8oemF0deU9luNwmJzwQgxW3OqernNW3vbYYcGzYjOb27CfTk9iVW7XNzPQ7Dy9wKNh5VapTvJkOXAg
# DATA NAdCcyA0B0JzIDQHQnMgNAdCcyA0B0JzIDQHQnu1QWiPVe2OqeDuKpQZPlOiK5wkdRFH95ARcruobt6ljo3qzB6qVny3fhi/wU8c
# DATA xq+/vv8YF/m2w3i0dxLPyLoiO+x0vki+CyP+Y0Axpj/icPYf6xY0v8ugNQaB7DWDXrPX7gS99h2O0v53+I+KQv8ubMAf0uy9EUjH
# DATA 6+8fDpPH8o7yK/b6+4dPWDZzr//j+k/u3aV37R+K5BsufJuDft0/fBKRsa604Ky4CP+NA9xT8dinu5X66HxJo57q9p5I9FA57qqf
# DATA f5rEsz3urSgHwYdDY3hd/SgLtHt7YaVPxRG+3q+Q9Zhb8iq1k/juRmt2EqNgJrFdIe9K86ByozdJ2mjmiNeyjS8zAhwgR7ufYyvB
# DATA bLg3ifcPJY+Kv/OqNE3cVVd8z6/vF2/AEKzi8xburcnpaapsTzSyzhz9dMoqTlllVVnFHAZ26ipOXeWS6iobRbFvQHXlY8hxaQWQ
# DATA ScJ6H6zZZYRXnq2Q123Q6dgUoKviCfKSESfmAiydeijvkdT3gprsCpHOt4B0bRtH52+B0bH5gqqPD5h/oChKMDp1Tw6j0w+tMOLa
# DATA EtQjMZE2s+R4THoH3vWL7vRFDZgs0ItuZIXdT06iCXWiF9wb1NW9MzKBS/fujq7j6o1WziX6wlLr/kYzGmQ8ysh6iIZGas/I65CR
# DATA ZWRxxHwvS+0wSW432R4WsfGyZJmC5TsSnAr0t8VqhIZDzqcTrwUZiTMl40NJPPXUoXsjFkPvXFGLGTfu2fo/lKYGFcxEFwpbZHZu
# DATA Wht1VQlMdqLNvQyKIflY4oxOZ3SuGp25deGsTmd1Zhfak89M6+8Bo4Y4kuziBnIU1d8YnQZINo0HaWJJ4C3ZQlX6dyG1rtkAdItV
# DATA 7TszKOYtSg2GGlLCUnKDZDqN0kGsx0C2XNMIKy3YuLCz9h+nbH7vgXir+qfwmUXYZYJh1ACUhP1Lgyn2UqzR31Ln3VZNVOWeRU3k
# DATA T8o4VTaH/jE3gMwVPvgMdFrE4aj4yXKDCA7qyK+1PY3PF5wg9bloeVp3mI7SfmrFsIPTFG0BrCm5L95mB2rj/G024DbdNUhA3KDm
# DATA csw3v5V/3fwMVyLc/RE+bLEuZWDWFp64UG2TBIPEFvOuUMLY8yENWh3tzJEO1CkZdgd7rGV1R+WlnRclHBDvhjHtXJzBXJvSJd8e
# DATA /MvP/++2SUU52ipnlSmmpCqpgqSLUzHGyL7jkQlMHm1J8iBE074q7K4hzxe9+8MhpPHoaWEBDdDYqPbzRJH5yWCv4EE2/2R0ZCKK
# DATA JibDNqW31Lw3w1lOBZwNZVIqP70LIgxe0qjTIGsoQfrYyZXytVR7rpC9zc3ZW6iLksuwl8WGp4QswonO5/vMk6FBYl6RXNMTa861
# DATA EJsAFvE0sqFs88mSZ880v1yKRc8EJOXR9+7HU+TViKy1bAxYFZveuOQH+DpPMjbRa947gC/iNcM4GywzFBCHJIuS15HLpr1dNn83
# DATA 561quTpX0eNT17vAB52nb2NvT+g1/s8/NcBKGlKeYPFgBp75CfBBVLeWlHdUFjLFzzyfCrQHp4WsvwwimoPUvI+oy6ap932p2FJ9
# DATA QYBiThKfV/Tg3jj03rTvwBlCcZfwTFpt8qp536evEVdkKv9rq8hXzuLtPUQhmz+lgZYmGRREqvPYmLMjavhV0XPKWWDQDqT6hco0
# DATA lzyUFZ9M+gK5G5UUfppQoccxIZQHP4R2KU4GZqxbGppAwpmGUlXkZfQbllAkbpzpR7FInoJHdhwn1ELUw6H0PM9H59G+VOfxb5cx
# DATA r3zqwVsXgmQw1V8a41CxuQKyDaQNI5kOIdu9bBLPKT+5cXDfAtAZT2/6rG+qPYJQUMWoLkqs3DV5R9FCio6zEAuJWTKNcOFoGXHH
# DATA gafjmUxUqF9aXEv3cfOD31s8LoGJFJuqbbpFcWssThLpkCVr0RtngtAUoeQoTml0O0Eouh6zjG1sFH5puo6mn6qWT7YgqzrjndQ1
# DATA 4bQi9dbHanJHYeOJaYKFXJ47oKdg7IR0L7BZy5lbNFdk2dg2V8wVyax71MDUAq8WEpbxW0xFy3yl5jbmhieFUruI9fQyuFzy2ZZz
# DATA uTiXyxqCgvOyvPxelo0OlOeKqFA4KrA6Uk5s1oI3iRc44sxKKIzEBMVSjSbsgskf5PMknLHPGsHwPGuVX8RPsg5+yKokH3259wZ1
# DATA pOX2po++F47XdeUsn3UuXy6EE+kOyziJlSPp0n4HCWqHvO10NtBRUSqPud/NFrPn8lgD5rCe4y+cHrUSMw7uPWCb3FQRQJDD2alZ
# DATA tfp+cgIc8qmqO9/1+MIS3imyqr7rvUX3R9SZwhiCEZJbwt/FJCyecoWbZScye1hgo53HS8esvx8roqtmUwFGG5JtBj4utMvI8Oon
# DATA j6IVXlSxtrwbMzCTHZCUHcvBghIpxf4qLDnZnMuEedw25fI/M5byfwA5ef5bD0TKs9+ffX32xSrhsnTnX3LgJe6veOe/oGtf0X+/
# DATA OfvaO//1+S/PvsQTuPcr3P5HQWDS7d+c/f78PwBe6dGHn9Ntf5JbHcfyBTDZvIz9/qk6gGj6eiSaJ+fcE9Q82S3vZUuZsMqGfObW
# DATA yoPcgDFm8GDCHoGZTKNGmLByg4OfDEsLY948v4Vi+abIgAkqwyEsiyacNPrbBliWiuTm6JWwA46t7l5VPKagy0/lJ1QVNE98rKok
# DATA quAMHrFrBVrybolxmLG/Bugf5ShXFoyDWu5agteOt7wPu/RIbBXDjq5wtzmEg00DgkyfJYb22/FoFA+wIR/blmXHTaQZ4PrWWURh
# DATA 0M+puPtXiJY71cHNZkmxdT0rruVOiXCASzfWP8VYr/GWlx/iXxEPzS0N79c9uu80uF96bL+1oV2qZSEbcszlM2s3NwG5LKQRU/Kw
# DATA mDBsK5UEINjpfCFD4TxF1wNO3Tjsx7zwt8h0qdETR0dYYHlI1SCTeTzVY7XMjem2jMxmBJ7EVCGx/CWEvwyKf+muiEtko2ECYtpA
# DATA 8Z9QV48zbFgDUWhHHXve9rqClVQ1qVowFmRBiGPJEikIBXmIDMDKZ1adR2mVrToqgeWUe9lDy0zAjYhylQy2jWaDY2A6BqZjYN4I
# DATA A3PnAWanmcwl7OHbM+2vYtlfk2Hv4JgOjungmA6O6eCYDo7p4JgOjungmA6O6eCYDo7p4JgOjungmA6O6eCYDo7p4JgOjungmA6O
# DATA 6eCYDo7p4JgOjungmA6O+dzAMYN2I2Lm1hXhmL2o9wLBMQsrzzuRMS3Um9/KKYuNIlWsU8rwhvwuOV5EljW77XpnTYYDu9kOxs3m
# DATA tNpsen53LKgzCzxWppHl4LHGCvStbsW1hFRbiWu9vSmu/X672wpX4hoEFNdu+7ri2rPi2ulujauC2a2Na7Pf5V+LcW34dS+g+ns9
# DATA cW10r6UOdAbdduivxLVZv8460OxcSx0YdsJhe7W+NnvXWQda7WupA512t9/pr8S11X36OmAFR6E1251xu1E/9tvf75bwuNShDlpX
# DATA g9hRX6ohdtItWxC7Zpu6je4OELvhqFWE2DWj5rCeQ+xanXar0zIQu0F3EPUHOcSu0Wt1O8GNQ+ywh6oqqxt6dG1a/DqLVtdlmzO/
# DATA /3JcurLTtZEvtbbF6coh8zmV3Xyp7W2+VD0nzANdXZVRvmY9zcBEQU25eq0VOhx8alhwkv80+HfDhYtnVKe8rpDhpDI0i3Q6VWvW
# DATA UfauRoyTFQO1iLu2CIxrr+wv2Aibs0pgi226WmMcX87x5RxfzvHlHF/O8eUcX87x5RxfzvHlHF/O8eUcX87w5Vi9UaHk2OdJif6O
# DATA fOXDe/T1jv5VQHNsbH722jvq+N/QnITEYT0mmTGTbRDFkz0Onclqop+Z1T6j/83uL3CbBKt+UAA29Y3hMDrcIU24PT7BsybwO+VQ
# DATA OBjr0YxHBIM7czqI7qD95oP27oD9S3zA/rLqh8/NwfvcsbVdDZFF3vg064xGKLIsILA8pu/btBCf7Tn9F+zE6kXqO7mj8ia0EUsq
# DATA BNcsjFjWcbhAFfG+AvSwGALlKrWhjAMz0kIfLeGN4R0M3tESULB+xGyw0FL9hu4BTdYxTnvv0tUEIvda/VBkohjRoNQVqN4mWsBZ
# DATA TpRzVVfiDch+PlOOc+h9qRB4GnUuejSXaYVSmS6rHm5VUio1OXivbfgFq24/SGikG6vT6rL5VYtvfxhCbtHI9KfRSZjiQL0SFD0J
# DATA J3I0P1QV1JsgIcxJYAd6HKYiTCGRL56HXoQskvqD5QJJMoegyxrlq3HUuWyoDTMpCabYcAeBTRgevgyj0EiphxmrNChhrZDxNHxa
# DATA PV5sid57oN5cInLoRUzELCENXZEggJlR4YepAhgkk0zxGA1Nh4NJH3on6IU4vjhtvyWSH8lr1mTiK3Ri3Q7F2cjORi7byKVa5WSp
# DATA nCzVVazjjdb4jclVfS/mNsBGQqiEnrSCDeXYQ0u76pY1EW8DDizOHYbgwHpMI+QcVCq344H1Y6Z3Mhdywm2zfhEiuFEXQ3YHSrB4
# DATA nYDsNQ4mvsQuIbz8ggjr502EzYU8wq31EZY4qij75SjXN8eZXWN21UXV2uMX3xHP1P6F2VykMOvveZyDtXFuXTXK2mFGN3yw3ud2
# DATA QYzzAEykrUtWXq+NthVrVX10pFuFOG8EIr+5jCdDa0RDb/HicpE/kGFYRvdwzkdveAFbz6UMOJl7Lz4lotShJPljeigCj+u+N4pO
# DATA 2KXNjuOF8ahCB2uNkPxRykJ1ZvyfRceaeWUkwH6o+nXdFQK4FgKLjv2zbJDXvH9HlsKQ5z3UM1rdLJn9Q+wMEtU1zcgUV7Z0pNxY
# DATA KEXyZjY9MKWjaYZw4OLFpinbS2yE26OrM8KdEb7iqF6xtpwd7uzwbWb18yMbqwY73QzYB4a2YKvAA7dDY5Vphcf5UKckSiu5iikP
# DATA NUbgFHqd2FuFUQeBz0WyE8OrciKizY0EiJItY8HMyGGQTZqrV6Yn5y/lhg0J/D4qhZ5F0Og8dPzkXfjJM/ah4gnxpm6+U9zJMoXA
# DATA py3kZO1WtJx/oNg+/wTlPDcuiZH8ZDNCUuerQCTvFzz3cGlTlQGUNo1QTCVgahodUY4Z/yz7YQWJRf8ZYe6s1GepRmZ8I902W8Q0
# DATA YZYVCJ4r17y3wjQ9hShrMiu6x9OQmY1stS7SU+UlZlFW7IFMJWLwmScz7SdXkwe7kearP7qJ5KtLZg+kjPJbkm/yV6so0gXe7MsN
# DATA MwTj1MxEnooVmlflSxbzO5uLWTcKVczG6Z8vycheC+4xdEG/jy4WRk4oTNaULHa9ypFZyHrRAhClaF56kcCzSXIyORVJ6JSVjdG5
# DATA YiwySz1U5ryBDx3k2PSKT1WE25N2a4VY6GUuWY4fb4EZ5/2VbrGCHlESyWkEFisNObOhEgPnktQksLydDuOQZoFTNlBH0eKUxtMl
# DATA 8jhWzqtQt2SFGzOTeV50odE156NlZgmHBt9HmJGyz409YFggjAW49tRtc1tCb61cr9wHP9i5D6YKu6BbhK4beTNmb2cPT1f6X822
# DATA kWKFVSNC02xkjKNpnM1Z+9p7n3vMkL0EkzA9gqw0lBlnmebUnySp9K/SVqRzHYVAJMMtcC3tcn2qnv9u9fs7d6tq7CL7CvL6SGqo
# DATA BqphqAnWpknKuje6y0Qbi2KHwtvCp+MgjoOiVHzr+GgGV49MRLWFCccKS4PD6EznKevVU68rxczxuI62t0PCXoiu9e1Lda1a1h2G
# DATA yTANT9BAeHfCJB5ZC9XKuabvUNZDFGJbKGUOZO/F3rHtGcxouLC0yTNYLmoeu/zMWrbaHjBIwznynI+E6v0U2kP2dOW6NYVXKtHb
# DATA BXg/lYf25fcp5gjMQUSjfTzIigjML89/fvbF2Z/Ovjr/NX3+BXiWwFb+if78AhzL85/ri+uwmN+c/ZH+/+XZ1+f/wLjL879jKOaf
# DATA BInJQf+ervya+ZlfMznTO//V+d8DoHn+K6ZjUthnfzz/RwriV/T3t/ROCgE3/YJ++AP9TPf8M73kq7M/n//GYTJfCEcptqWhu1Ld
# DATA oqp5HHR2IL4oHsL6ND2o8PcjbHaHF3UAZJ0CtRyH7LkKzRTB+FxDD164wbjmvfNoPoH5Qp0pCguxVgZNrg68lZ/51oTGL2mJiJ8j
# DATA aNo+VN1n3DZBc6VQbo6hyZXS3IWthbymrjyAK8RNqtpxYm5/wF89iHYtJxAJu06AZpxJVOA9lJ2NEc78huAHnUYLR8/cpexugJzJ
# DATA q6S8Wh5PMdVFaKYCqO5pEfERtQHqMR/r9z6Iwmyplm8px5aAQjFdASVHfaXxPWfMGfIW8SRSLuuU/eVkIA2Xk1Wc5m5VcrOlU25r
# DATA z4qouVs6HFLT2QU3YRdo1uZVzIFXYjn11kyB67cEdjIELmUH3J4ZIPWylAs2bvN5a1M3weEsJZ8TDTc1swtNZMrwTa1QnGfOMZwY
# DATA E8XjtA/ScG7x0rNR/ssBfPptyAzx5Wh8ZfYwWgzg994Vx5mP+JbFQJHL8uF/KnbCEPvyoBoFhRqKrych8smagj3AC98Ut2RYVX58
# DATA tPMs431kHu/hEltEOxVpVEJyxR+laJ28UYLdVqFZRnPoTYfedOjNG0Fv7jTW7DQFuozRfJtTgKvMAK5rAuDQmw696dCbDr3p0JsO
# DATA venQmw696dCbDr3p0JsOvenQmw696dCbDr3p0JsOvenQmw696dCbDr3p0JsOvenQmw696dCbDr353KA3G63msB1cFb3ZHnVG3RcI
# DATA vVlafN4JvkmhxzQsegORGetxXg5OhW7YyzM2aIoOFf8StIv8wt5wFHVXcxlMwKAx9oPW59Wu1/K9wPf8eo//NFrVbtMj+7jaa1Rb
# DATA 1U6v6gdtL+hVO4Hnd+hLo1gY7W631YvkHcU4B80gjzO9L49zO8ijLGRRq2K0Gu1oFWXZ6Xl+qzPudidVv07R63zeo8i2G9WAfmh3
# DATA q77frXaqrVbVb/ZKtcWPBpFfYh722+EoDNYxD5vrktKU2A9UjDsWhLFpJaVYx4fdwaC/hsjod71G0P282642KSWNnlenNHU9P6h/
# DATA XqWyaDQphb5XQiuGUafZXhu3VreTx40CtrK5Z9WMepEW6TcHzfYVSI3c9DSpUVqxRWqkuAx6u5AaC1dAagyibjS0SI1he9gZ5qTG
# DATA zjAYhhap0W8Nuo0bJzVib3t1m0lDA67l4xLb2DykLRkbSohUjvzSjLjZ/baHf8nU8NjcyIPQ4621xCi/sjm5o9c/sOK3di7BIUJQ
# DATA 2Pb513E3z0G0aXpoGeAFV6gq98uBFcX9lUMhS3nSojyhfxvyb2G1qtky2MhO69trCY9iLFKaZc6XL5daC1jrEY4bUY0XVgZtT66v
# DATA BZIpgV18O4dTKhqexZYmQ44D6TiQjgPpOJCOA+k4kI4D6TiQjgPpOJCOA+k4kI4DOQrRuO/6VeEpyqZjwB/JmtHIxwf6vPtJpPyZ
# DATA jHvcU7hIXMATEhSq6rvY6LfnM5JxMBX2YyEQNVe1QpErFwcjIrIQT1bH6eWovTePo0GkTyPijBz8h32UR5EDmZ+8cafD3enwnU+H
# DATA l49ouYPi7qD4dt3t5+YA+YP4kTShCo1Ps1Ms+cdyyNIG35gjj5ZoKprMRA514tmHq6eecRSUe151dnqEUORkZhZOokvKZxtVS3E9
# DATA chOnm5MpXKP2OW+nnL2LcjbvKOGqiA+b70N/idt+RH+3aGbToLgQ/OFH8vFF0Ms2eXBJkcg3N4tEqtwUgcg3cYpzhGPdGJRyPUhs
# DATA lvHIcqeqgvPgOJ0PLitNeU4h4DmJR3KCOVkwBSLjoQkuKATjjSKqRxMYRDRhSeTgMadEE1GeRjvzqlny1o5Z8o7WBKUxWWfIm+EE
# DATA ugKs1cvRpcbEF8yZa1nCYVlRbwTvMj2NnOIFEp7XgTlHQzP+UBMk6y+Wk/kIbHYdGaPbwSXz5Ueb80ValKopyyFbJnkdmYUpzUm9
# DATA Gc1pPfQzDAaFdCsWJCAzkMN/YNFwlYpmQiiDIEHGHBH6PEd/f3yqjZtnWEf+zY515KNkyRoWP10e5fmh1abnWn06mY6waQSYBuoE
# DATA 5pheoUEwzUhhjIZkatBgNqCMm4yTJU681bxPMCFgbQVWShC77mgS/swIdTyl+mzeFV4yfz7aoj2rO1XJIZpfe3N9SXLoozQ5Rh2g
# DATA NNPs5igy6FjeJEeVJlwOoMJxf+YtZ0iu7mEgEMxAVGCZJlDeh1Q0Ly4/w3bz8Y7thiu1Um6xkLWsyDBNllAfX0KpYiLGQ8pnZOHv
# DATA BxVrONQ9C5SWY+lK2SyzhXhDqS7UX5fz43albF8VhYbczHaTcDcJ33kS7mbcL/mMe+Nk+rmWbON9LGZHi1BZeVfLvTeoQZdLWO+/
# DATA RHLNtrqubKW0NofKhXDC38ryZyv7IqXCDBLsHJKXnc4GOibqpPG9H6xsq9ST/FV1Oesx/sKpKYzvkwLZC/AJZr2w4tiQqidN4LV/
# DATA IX+Ij07zcPOc6ta9SHJOOwrbemZLlVTfguFgNlBtMdT+5Z/+kzYj+JXjQKTsxIL0FtFkwlMXBZoQRa/vwf7MvCOxssIF0yKGUGGj
# DATA Gct4Oe3r4gq9dHy6GE+VNcsGK88NjmL5WSw/FiPDtBmiZpbml8d7HiHSpaSRK5RbaZQLzhk1QL0CLZihHF1xEqYrmrrFAmWokTEc
# DATA mVj1CspqWcE4q81ZbTtbbSv1za2duLWTK1hsG43DmxTfZUDTSOnos5g78poX4gsavM9eEH6bIYBzfp691rKydCK2ItuWw8K1wpqG
# DATA LPXT5Xep/+Wz33zF2xtMLwLd60dNd2YumBUGOSBSRsb7RdC9jYyv1/zN6y9qQ4EdWbm0S2zNwya6+RUT3951RldtvKDfP9D6v4tk
# DATA UagSe9++KNomEBPt/MoF2Vy34t3YGm1lvpoFM9mVyqtcUuUj3uJhmkJmIaJQw+69IWeCVZzV9mTbqZZfkv4nFlTVnMZuZcTekSCe
# DATA Ev4kthWjtPIuwFal/mFm9peg8Rnj9gNxphqlZkYOn4zjSZT3EzHUahfYq5Oy5K1Z6aDWHOXizSwPrFY4YeLKxhXZ+kambqkK6J1W
# DATA 3lCh+kxvoLWD0aVafQ+lajml+7E9OA+H9aQH4QzawXNKQIxzimE654Ve9hwDRQ535ck4EgM+77iQMghNc7/GC1tkdNQ8BbNDCo3Q
# DATA dLacU9ej9IOL4tJ3ON9fFevZgnDxHJ3nEDaH65+YwfXl+S+FdwVy1jdn/6zQXIBzgcX1xSqB67/RbV8B0CVorbP/aYVDnxiw9Ue6
# DATA R0O2/nz+m7P/ZShdZ1/QjV/xu35//h+Y0IWTDt7Z786+PPufVGnCiQNuvRD2Pxv31tYNoALTBHjXKfoJrm/GjmFSawZ5cuqSWL2P
# DATA esaZqH6fsG64LF1o2e2K4oYeobGPwz76KZmtixo21xmInfcjzBC2wbY+pbtMhBxqq2D65z3DbdO2SqVyc6wtoX0b/hNvybbeat35
# DATA 04yKW99YrGDXidgKBWyl4QpqgVAS4/BaFxTXtaO1PgrJ6MTPFOtWvVKv13nUoAygLqrmfUQDiLF6mGDBk65xOMdasN75vwj7h4ik
# DATA 4KgzA6FAcUWPaCDA2YIyQ+vC6rbZTCk2nmcFz7owAY6b5Yb36x7eNTPr8qP6q+HMu8UR/boH9J3G852H81sZzaU2FpJu++iepzZ0
# DATA E4ysQsIZ8ZMpZrudTJp0h5laNBti0awPyzzETuIKJTQG0ocaTUxJmMRgSc2G+rWjMJ7AXzkIwSpitlAxWRhtQ5PRUxrg9AJzPMvm
# DATA SBJcpNRCdqVl5SGzZkAm76P4M6WJt6KPqc7BvUIX+Uw5nzZn/8YMK3w8h10yIWoeigM2GTIyS8yCzJwVpxQ9OCXj7RE8ZfEwVCfZ
# DATA IzEMowz7EONsjHXMEF6NgXBXkK54hA2Ig3E0DT3e+c4UrjmPRQ6l5VBaDqV1gyitC8egnaY6O5rPtzcLuMok4BrmAA6d5dBZDp3l
# DATA 0FkOneXQWQ6d5dBZDp3l0FkOneXQWQ6d5dBZDp3l0FkOneXQWQ6d5dBZDp3l0FkOneXQWQ6d5dBZDp3l0FnPDToraDbrrSujs5qj
# DATA zqjzAqGzCqvOO4GzOGM5Lj3OOEEz1f2CHEXb7xYzvNHrbc7xeqPXXAU59QJGUqmgLLhUp97t9frr4FINCWQQpyxBpV7WtthSDY4n
# DATA H5jrFmlSw16j0173fKu10/O9fq/dX/d8t7nL892o3wn9ciZMg2bDC4J2lSp2q8fVO5g2/FbVD3yPr1XlWtX3G1W/2al2Op7f9e2g
# DATA ecNoCc/VHXaHvXU5yLiwUs3v9Lxmw6cKj1d79XGvXgrO5N1KcL0rILC4CWkElrRGC4HVaLf7neAqCKx61ItCC4EVUECdHIEVDOvD
# DATA Zo7ACrptv927eQQWzYSq9PtOk/YgoLGy6LcqjDQy4ukQPT4gZ7hP2oZTxqdOsA4g1a6VdYF4y8njksvEGgNW7g5LZr8xxbvKFM8f
# DATA 0KN2eR64bs6nvYRd9hLK6iD8hGsW29rFRBQXAmSO6NkTH2XI5U+YYXDNil0Zw7XW46MratHDsAnaZZzHKjrwG1vTL/5+QT4VX9RG
# DATA ctivWNh6svl5M05f8JoNU7jNWC9TwXfCcW2rvJun9aXKvK5OLicXTi45Co7z5ThfjvPlOF+O8+U4X47z5ThfjvPlOF+O8+U4X68Y
# DATA 5wt1QZ2Qj4aHNvVrgSVTzgik7q7U9WSZDiJUEK5Vh/GIjUzVMO+16jB4FmPACt5J0wRxfFtZXmheZPJQH50eSZ9sXnu3ZExbcwI2
# DATA YSuYXFSE/oVtjVwO+8IcM4HQd+oqPnuN7Roxz71386P/ZEefZmv6gv3DJ2yjP85jg62Wo3hG2aGoZiwjqnQfjq3g30LnQ80VLtUK
# DATA zjFOQzlDxaWOt/axR5nml/wiK35KUJe6GpyE+jAx9ql3gjOLyvqk3ziCVK0593Fqp6p/pF++u83u4DKk8snTdTdP2f7jQmREjMrE
# DATA QYs0qjfhNCDiIVb/4RNjzH/2mgm8hrjRW82F16mvAoWNrlFrz49B3pEbdW7w2aNyelVyTWXb2l44nesKb7dgaDKH11NAbC9Lnu2J
# DATA DT1YpBOa8v3t38pXbAakr/t//dfynR6lPP3stXcY8fDa/uMNlrcyuqkrzBYP2GLfk0J1EvdOTeFKagpOReHlVlG4rLr9M1VXMA5Y
# DATA SZGI9VlK7osQ1e3eh1qGm1PKB1mXkLaMNyfkbX12P1cekFjioW0PPuB2y9u8sCi08alCdoixYLW9/Kk7iKnWIeSjsRsF7g2JSUkh
# DATA UKveLm7/3IlNvACHq/m/10xOKIpiXDc3oaw1spaacFmVrE/TWJlu8YxZjWS7wZgxKllGB4SVyzJYwCcQMpsuRcPhlP3UFSOgL5VR
# DATA VR6uKBglM1G0tzQ9oHEQskWfjBYMV0ojdqMzgUsBt9jQ93hhkPXGZ9Ej9vEqZY0LOUYvxzl5E4Iz7pxxt5NxV1LKcZpZTjPrElbd
# DATA RtPxprS03hPBJqrYai6vnAhczXOyz20rNt6GyL3yLOjM1Ul/Q+/E0Irj+jaopounDJfZWVYQWKeMnEzYo80ABKwV8+j213AxHaJP
# DATA k08H6oKyqOVbRf6wW1zd9mO/ElQaP6FBUcdog6S8cqrRu97jT1xliwhic4vpW/OHVgjAASMbThKPt5JsAQ83xfAG97B05wooeKOY
# DATA vPFh5VXnxdWRx5RH5KWUjbRO4mxpBM7m0moqSsLs34TH4QPpYpWaGQgr2g2KZqLygfXeTmZFLTRRzQoBabFdckofiwZMiJ4JImly
# DATA qhyhprlD4UoEuOjpE5zu4qGTNacs91/NM8WFEZFs5OVgsVQUpkk8xUXeaATBKojEMe0C2l2ZjkqpIuRTEdtMzqcWUlpF1ynmlnqF
# DATA 37gO1ZzP1JyLZedfDgs1H2aciepM1J1MVNsWcQaqM1C3Gp7PWuz1w0IjmWGgW8TTHMr0QJZJWQC1YlEAJXXeO1oGEQKLOL7D2UW/
# DATA o6kMEx6rocvJaqHhEcULW85mp0YPckcFV46uiY2QoKgWQNBRDAJqrNTuI9a3ROexxlunThyvsVRljwIqGH9SdCBlyegfc+PKXGHp
# DATA CSDnIw5HxU723JhuaTOryGx8YOiPfC7aldYdpku0n1oxGbFzAKMjOka5L95mYaJFal/y5rssHVvBOJqvW0KOsviI0/42f9piuxbZ
# DATA 4LKTwDZYFM18k9lYKGPsrpbGegUAu86NSwLYHz/ZTGCXjBUCOyZxkWakK6f9qSaxf4Ito5TydJnJdi+ugTPWTlVCupgDgcypV6Bj
# DATA bMIIsYHC6y/J0FWKqfGg5r0ds8DqkoV2vWmc8exR9rpguxJTRHkTiFzj1sorw0JiAIKIXpcqPttTo+1LNeiSGfwv//DHzTlcqI2S
# DATA 0SzpmkYi/Au/ajyIFwZ5z7/k9CXWviWjWrRUk7k+db+g2payji8Ory5isc/vj/hQOM0Npv34aAnuo3L9VnR3J6gooT+GZOyzhG88
# DATA 5N9kwn4dOXrFujrNdqurH4ZTqQqQss6zTmoLpjhQsJV9vqJqC53qSbQAEkt2N5mnPcZ4oPdi0Mcp0LJC65pBGRANgqw/ig71nlQU
# DATA aoOCaSDPvvr920tVPmGdcewpFZ8vo2Wk8+99zOAwaaMJdK7EfBLG7MzhC+q4eQQA9NvSIHlNQipOlldUDhhZP8LRAs5PysAZXEgc
# DATA 0EKeAqY3AkWRhkoU2rVUPdO1XzIj39tS99QgIXlYXqH0Fml4TOPmCaVBZ+bH6ijBWAlkh1ItU7JhomGmjALq5WYLBschLNglMj+h
# DATA hjwzPYPqVafUa2Q8l4wh8Wgtq+ZwuUWs5Nwjmv9qFW7Yfs80Xz/ZNV8/YQKftVyF841561bLYWl0hP3gckCEEpKpIQOjTa5ebyTP
# DATA M/ZV5JZhNBpxDtv9QNjPWLyaZmjs3pF7VHVGbypWX4zO9qeym7WUoUUjQfYs2kaCuSLZQ3at3l2oJ3bsbFG7/qgjGowT6GeF8JdS
# DATA SeqCeCUW3myMHpVEZBP0/vPZN+d/d/bl2f86+/P5b8G9O/8FkHj032/Ofnf+G0Hj/f7si/Ofn32Fv2d/Pvvq/LerRD07HGbl/YJp
# DATA fHj2m/Nf46mzr+ki8/YEvUd//+TRLV+e/wM995fzXwKnhxj00+ikatB7X5//iv7+Fj8zce9PDq33InhrpKbZvHmZcj6M0Upnsi0Y
# DATA xIYfGt+MKN/DHCOLYQilH7YUZH0Dvz/U20nSaBDPlc2VLdEfcWufJizWv5Wk95bEy2pADqZne2mQO7fN0Vstk5tD6UnVyVcSP5aq
# DATA JJIn5ZvRE1lrjtHJjdCyeUf1XB26oKyQCSPeNo1mS8fT26HMrh2pJ2Y99+Xc9cDLLH6zPhkQuncTe567sU/ybomqa3KioD6acM46
# DATA a4L+5UMHKLR4OsUZHcCEqLANjPhS9W8LBrjcqJ4VYu/iRDjGnhvnn3Kc10i9Kw3vr8gCzK0M7Tcwsu80sF9mXL+dYV2qZDkHLLTe
# DATA s2w6N0HSKydVL4qISzVkucnSiJjZQyLivzImVgSKJYuzssYqShbH0SKZ8zNRxgfaEzKXFuNkmO2CyfsYeSjLWOUYUfbCQ8Abdyn5
# DATA 0xgbTBKyyrBnSwb6vLrQO8NsmQIMFrLAKGUy+/Mr2m2fRmg/nKJTLhnRwRESIBwrTKrTlSELJ4L7GsBZrXlmjobnaHiOhneDNLxd
# DATA Ro+d5iq7Gru3ardfxWy/DqvdUfEcFc9R8RwVz1HxHBXPUfEcFc9R8RwVz1HxHBXPUfEcFc9R8RwVz1HxHBXPUfEcFc9R8RwVz1Hx
# DATA HBXPUfEcFc9R8RwV77mh4rXaQb/RuSoVbzTqRcMXiIpXXnneCYxXoL41ehY1rlFvGOqb3+kUuXGjQben8oYiGNPIaoJo5EE0m/W8
# DATA bAKh7cnhqaBXCK/TDAaNwUpBBS3fC4JgHHTqx36z+Xm17fX8qt9oeb2A/tSrXXyp9oI1JbeK5msFFFqrPm62P+90vI5fbVI98JsX
# DATA UOdMYCuYuKCzNgO6FrmPIm9VzkYrz4BG4b3fag6CdqO+EuVGu+75Lf/zKqW1SbWl2vGnrSbF/fNq0NNXrpwAP7gC6I5bhQbdSQOz
# DATA QHedZqPRbO4AuhuO2kXQXTjsDZo56K7TbvXaLQO6G3YG9b4Fuuv4Db/ZuQXQHZpUdbu94fHwYt1a5sN9L6JeIA4rEnBpMW8FFdfg
# DATA BbN8uawYtLJbVpxUOodWHJElf78d1joP/KUGVY99b3U2nNQzaglsbdKNW3U1ksYsLyLkVNiCrlu/VaBMtFvFrK3NGTPw6dWv+jYa
# DATA 3A614KZMEYd2c2g3h3ZzaDeHdnNoN4d2c2g3h3ZzaDeHdnNot1cM7WbD3CTZfGDrroDUhjjl9tr+d+QbLzkylkshz5JFOJH70aJe
# DATA /yBcjGs8k9zji/uvUw7gOCq9RznR5tCYWc759r3CO+7IN/ox415kkbyL7Xh7vh3Kp3KYzAqk/M5SMPzsypEzTRCTKaA50uEOUbtD
# DATA 1OsOUZeO+bjj1O449WWPU28Rvr2pY9bSCtgOhl67rLKaY9bPUMjjNqgLQ3U8W9UMfPX2jvaVpK1udjN2YOQC8OqpvG9S33NmQZHF
# DATA MI1ZgK6lsA3s+5dFJ2yx4LWomr9Z+FbGU0gxm2ENxYBD1ZL/F0RXP2/iay6YCPvtdRHuWhEOdo8vD6qgtHE8OJp05YJIqody3V71
# DATA vcCBWImhb8Wwa0ewGL2NvIe3VIuKjGjQi4t7eIutPB7GGOCFyYk+kPzeCCqb6EP4GH7GAx3aXkZmybzCPk1qpRN4/SenHpQ0Ucli
# DATA 8PLEKBJvvdC5pNbxuXFqhirEIQVBAcLMGesABwmMHhWSPg7O/AmuyVG2wLo7T6lYgmnKFrElAoDT4KzAyMuoQ5wk82Tt5tAWA4DJ
# DATA ht4vS6aR7ojep9nLMWZIYwZgcPseYHewShCinfc1FwMaXp6DxQ4S6yzZ7Zass1tfcrv1slDYZy4PxAvm1kLwqtE3KUgCMvUnY9Ft
# DATA xT/o8zFSmCJbGarPXFXoBVHguAls6ooC0nWTU9eoSa2Hp+6mhFiqf8hqm6bAItJvpkirGtZZtT1XkOY9PXoitMwETqX5qWyLRZhn
# DATA DU8Lki6hh40Sy6myz1DB6EMWKUMJgUlNKhooCp38Lt9gjJKyBDfH+WMWe5UoR5TFOsbvmYlazHNAiqroGS3itMLK7BwbrcpesNC0
# DATA 4r2ND2CDFEGRFYAjGFui/REW5rbH+gGgKyrWvE0pGuqIv6MlroY0u0VsKAmcexWe8lW8U2yWFVUn9BiL5CiCilXNs4zqhJVFpx6D
# DATA ChT1ZVN09QtXY/wKCdjYfZKzNJ2luc7SLIxTzmPqPKYXGajPXphSYpApZcU0SaasUscNIpennEykqawVSaypel4RZ0VFBiPozqEZ
# DATA YX2aqWDsWfFk9U61K15GvBwF7F22EpS6o7RJtdzIYaLnmzN2Ey7gcIINDCKQ7aBgu0DBxOKyTatNdxo/N9Nd9JfN92uVTs5V9Xnz
# DATA 3VrGs2h+PP8YsTz/Lslx8Q/89maUiy4MQbn8YBZRZzJn12IVRxa1ZYj1Db/lHdkrGUGzTheUG/HTSBHIaAqCrXKT0wrZ7dj726d6
# DATA McLXBcZLhIw9JBnWPORUR8Y9BIytkzAbi5aqttDp0mSSXQcH51by75OThPNvSOPUvJh7jXox95pdK/ce8EINks19rcokKJYC6Lxg
# DATA OUqRxpS7xC88iYAvwmZdTx3CFaHSa8itQhu8fIa1NmeY1aAlz75HfSrF7t2Up7JzmcDk+RaUal2j07LybQFTipfJ2HCKZ8sFhhyI
# DATA lk6KEyseMRjWQzWPZleKgmcmYcfY0Th5DvKufYm8ewtVIBVZiXx9sJB9pWrXCOql7KvwVJpN1CMpiozmqaKUCmKftEbsRx+m4Qm2
# DATA 8uqlAdabzZcGnibP7D78kln2web8ykcDhfBLHobautaZ9C5zKoQbAXSf0AuPyeYwZjpZuA+p4U0U2mnIqsPTZMgkP2+MdWDvYxEK
# DATA ZqYVrpjlE7Mqk9FAT7nOmrxo0deRbfZgdumaFmzOuHxglIwzjoGigabz8AGuKq/LzPO7VMOGOq9Cr9HmPUNUUbEtkF0INF1Sjhix
# DATA 3Rgjz3Ut8Y6WseJ7MTdWeW/YbOQt588rwutlcUjkGK9RvIDErM3x+n/Pvjr/5dmfz74EY+sr7+wPZ78/++rsf5x9yeitL1eBXf+F
# DATA fvrd2TdgbJ3/e9ziCZLr7C9nf6Sfvj7/xflv/n/23q7JjePM95xrfYqyJxzdbQIgCkDhhVRTh6KolxlJ5iFpa89aWkUBKDRKBFAQ
# DATA CuhmW1aEbM2cmYlxHEfsTsRGTJzdiY1zsTd7obFHa1m2NBf7Bbq/wnySff7Pk5mVhbdGv7JJpmySQKEqK9/zyScz/78CwqEwKazv
# DATA 6Lc/esd/h5+KdMc39Puv+U3fHH1Hb/76+AvGgwHZpQhgv6avf6QA6SfH7HoeXCoZ1A9d5tDmAUkfksbwgVKT1LjAyawzZfV76VAo
# DATA w6KpwBf3Mf2Lh+KClHYLF2oPp8/BAYBCCT8FDiNvROXtnh2lkZ+Eg7UYr/tYGe+GhyamjuNl+1pUB3HVIK8lpXJ5JC9VC7Mlo0eq
# DATA Wg5iiufkcP5+qY365ndylfQiYV5wGaqYiBa+7MyPdLwc0GuzortwptejKAMdZCyICSCpussyVA4uOS9Fb4O9QCIjzFAFc4oYnp9D
# DATA fC15b8ddPTum3k2m1+KcUildIHudXBlX2zOLrexZob1OToVDezlz4OLNAU37OpsV8FKstlyVBXAZBsBG4/8ph/+rGf2lYi7kggX9
# DATA umaN6jI4YAvJB9QUa0Mpc97Xp6zANRCqV5yE+XS+M1VbI3gLBIuExOHEvEkHxSmXBScUp3IdbEQGe8y+XviDsAEnhestmoSDgrLk
# DATA aECLuzMUX9TlYoSxNqEawmvI3QzzxBHWpoDZMQLzgAIVlwecU9TG4ZqJR0XKYgaxe2RdTONRpB1VvHyG0LEMDbOlIDYLvVjsEAOC
# DATA cpQwRwlzlLDLo4RtOORsNAfa1HS+2mnAWWYBFzEJcKQwRwpzpDBHCnOkMEcKc6QwRwpzpDBHCnOkMEcKc6QwRwpzpDBHCnOkMEcK
# DATA c6QwRwpzpDBHCnOkMEcKc6QwRwpzpDBHCrs2pLBau9rln89ECmv0gl77OSKFLSw9b4QKs/PFD7yq3+wH9dYcbapOvWMzWkabqjYl
# DATA h7iMpAxqrEgppCzfzyn1zJddxbcLr57Lf/POXOhBy7/E0Fv1LPBaKxe4pCoL3K/WbQhYLvBWr9lu9+YDrwetCw89B3qrCYtNIGV+
# DATA PQO9Bc1cAFEQhs3qQrOgxz3fb+7XgkGl6fmNEwhkq+tE4wwAMm5sGkAm7TYHIAvCVn0DAFnuCgBkQbfTK2cAsnoniJplAyDr9DqV
# DATA bmQByIJap9W6dACZbqBr4VMlP9AUstz9ZnTUCwTBJrSxfBCaN5b14zqnFhyZ1qNtLMoseWbTZYFSXVkgFdvxUCktWRP22SDKvTnn
# DATA URDLAM/x/MV4k/yA7ASYVEs8khXjkZRMmV9mWbLQFyy8oHJbz7Wo9/Yzu2Qu+k2255Zx0VqtVp6GhlXm1ZSyXLkV5spijbWTv3HO
# DATA 92Dchw5D5jBkDkPmMGQOQ+YwZA5D5jBkDkPmMGQOQ+YwZC8Zhgx1gULpDqJCxMtE3d1ygZ3u/GlMZneU7v78owIcqvvRLluwBXS0
# DATA D/DTLqrkbVOh+XQZrKPJ9s5ncW9bHtr5TAdNLRQmSDjqRKURWag7RfWq23bwt1nVWR/c2Jbo7dxGV/Dh1uPsGFtXcGKfW3Mc7CPU
# DATA 75dSxLGPNe9F+ukpSioredDEeLKteivoE0v6KQGj7o3dsdq9n/4Yht1tSh8Cf5V+2/mMn94d3+YzGRQn+vEHfI3isTQ1uQSbrL9t
# DATA Mvy21DpM6LnRZzWM8vxNpe9Mea+QcPrkj1F+9h7jkFT+/OWEos8ED8qPOJHsE1v+9uerX8ekt04UD7a3KalFpHnnJpu2gLypLKGY
# DATA UJJNvaCGxKkvsRt357OswliXJe72fZRxNhcvq0EqlshVySE1Fux8lmUYig7FGVM2xq8qch5LuiGd8Y0b+ubSeEamyWcq5rfkTpyy
# DATA o/sKHBGaWH+AU3f/8cU/qTONwObFN/wd6mIoEgvBF/2dNWHjeKQd9kMcl+Tlj8XQP8/qwueqjvBkUrfJxaqsHridq/23pZ7tYgar
# DATA q551Q6ESlPMtajIbiZSwEPq4OnArowuvrTNwszavnprgDOlJT3H52t2FVfOzHJjrZ9Y1iYdQWc3ag0oUoqKTZOaAS6LFZ1DiAc2H
# DATA TJ+qa6B5TMaKnVykKdiDeETTxWWBYiWNHormMskxY5zOxBl1Jpy+xIuvL3Faksx10J3glZWcv349TuY9HIIHkQPiq/rgdLiHV02T
# DATA YTKhmdlapsx1FK14fo5wXwZpZlFj46JRM8tETM7ImvFyS0RSpXmF7Y5f1tLAgtk0cmL0MnULBDylnmQiH7bQ+xOyygriehIte0Te
# DATA WN6ympeMMYsEXE9YD/3ZZMpSX7F675hG/pHoJyRK6sOI2K8R+jhJefQFOqKfazjOhHIm1IYm1Fz/6kS7nGiXNfyuNL6ug5jX67MY
# DATA TK28bJWR8npLdKHspoSRZxwlaGgH/SQ3QglCQA9gJe8uRGxQdKypE8pcWMHHoifUHMNB3IPiDUS34XwQCalRFHU1Zuy0/BQTUQV8
# DATA UHLakFYvLFHScvCUTeApw0SKjvXu1ed1QJQJu9FEAl8+r74bu32Em32PP62+U5s7ii/En58HdIqde6dUyW/CcFytk5+VRY5lwV49
# DATA LY7Ps6JsZMP4NUlme/2sMXzCsHeW8NC4pNmIjEfWoso2TKM97ycxa1t12Dz09Al6WI0zFpsbs3wvjE2Kw140vQjKwDnyLzhd/r0R
# DATA pU88drZbaAFo4yq4k0kvS8aJKzxlnqFtOhyEgyeUV1o+kMPDbbMBMN2MavSiEZcBi7fhFITXnU20uC4NUhfDtMia4WnhDJX1+Za1
# DATA asm312mMl31/zNSZxab2KduK6lwUrRQyxOrRCCwLyUuWppPFhFTRu6J0WvL+moEYUac/ij+dRUZBkSopTejASpj2Me3oh1wTka9T
# DATA VXEvIDezbuq0eXlCHdS9nuTkB1R3WAVRSzUbDKnJJEojVyG2UBVq1CDhycLtPIEU5Jwpq3IvZNlFhfwbRGqSydmuNOSMqHcvPww/
# DATA qxZcP10Lfj0csB2hpgqRzaKBccAZks7GmIBRAsNJ+1DNDTqisyg7nUser9Qgd1mOfKLYbpRrvSiCiCKmWmRRROk46sRMhBX1y8kh
# DATA 6xmaSfgoOriIHLTHvtNWwPL6LMyGUgVbQeWamIuagkvTriF3bejsFanHTMM6Iag8lFEHZGDDVMcOCq9PFiHqF7KMVUBZ+JAqNXQg
# DATA 97FVTO2xubZQlRfItZEF4fwazq+xoV8jX9OcW8O5Nc64JrTSBXJpGuWqyuborzDFqZob78YzZ2Ws824wk3Elx543evMyB3Z/q5OL
# DATA +pqZ9PKuBnvkNFf0rJdzKTsfiZ0h9C3p9cQ0CLtiF+QcEryrhX5mG8n0Ottqe8qO8ovoFj7iDf14hURKPW16Rv3dzPOrcnwTw8CE
# DATA jHsyXvjMHS4Ow6dyR1nOyUVjPpq32nfCm2Q4JVaZbhxV9bSJqv5uolo5Map+c+OoyrYfRJY/nRQ3fXsWO3PFxK+2LHq+Fb3Kmtip
# DATA VUHjz5JzATz9A2/vJu9THJKJLTey+TEZ3nlVpBWyLMSxELsOZpdydW5Mg/tUjuPelCCyimx8M1b7MJdWOHDEJKLJYNcytXMK//+F
# DATA bNOOnqDSxLyHUdKAdGTKcBDS8A7YzpgeJQMNMzBFBcpmsRpIqeiEarIllFSz99dCWmJITgZFhlnyji16Sxc8zERoovCiFLxu/Itf
# DATA xBhS2L0ymqUQ5E8PyfZNhmnmRbVj1o8G4xMWjudKNVs8tv2q2TKw5L/s2aLHH+BDVuJnCky2ckmjjKZW9REblkvs5bDKLdbhbEI2
# DATA MZl0Nu3wvzO88GvQBvMMwuPf4O9F2uE/H33FPMI/HX1/9Hvv+G+Ovzz67ujb4/9KT35PnxS3kBmHIBZK4Byyx0DEr4BRPP6Cbvjd
# DATA 8T/QQ9/itu+P/o3C0U/+/uh74BK/YQwiBemYh8/DDMNUr2xiwRUexBPkKD1TUP5K7nA0EoOFkwzdWSJMFtEDKkWhEcCwMgQP6km1
# DATA 0TOOow7NxtfBDR/qbQw0ADBazaENrcmELrCrhhsulMrloQ1VHdG3gbOhiTv8y8L92L5idbiPkp7a03LhaEOOQA5sGKdc2R3WcLNi
# DATA u3Cs4f2n4wF6mVA7Q4ZJdzYIQV5PpqzZU/I+QN/PfVe2z4sXv7Axnp41+58oDrMh95SpbIOCCyWZhnotKxwJOmYBaHhyFVxttcy3
# DATA rGeFMzw5DQ5n6Eb6c4z0mlt4lgH+5fAUXtngfvFj+0ZD+ylH9qsZ2KVazuWBxSx8Vi3nMuCEc6nECgBIQIrzF3esxOpzjvMJCsWl
# DATA qaByoK3pTdQpioc3X8u2Yi3RDStpxF7R+XzbkEhovKxZ7NJp0uEVRx6PNSqO+XFcS7o01x6lJvrRbJJ44ZDxbzzkR2Q2xJ0YS+M5
# DATA myBnAURPcbAYgXcjeKPUjmq1VkjWAxXne1GYIkJs23WmcMWIkcheHaHUydq6Kur27FDql6MVOlqhoxVeFq1ww6Fmo6nNppbxVdr4
# DATA ZzHxL8LCd6xCxyp0rELHKnSsQscqdKxCxyp0rELHKnSsQscqdKxCxyp0rELHKnSsQscqdKxCxyp0rELHKnSsQscqdKxCxyp0rELH
# DATA Krw2rMLAr9WCzhlZhVG350eN54hVOLfwfGpSYeB7Vb+8X2y1PvUbxWrDawT0d78aVD6ttbyKV6941cZ+q5XLpY7frnZ68xg7Cqu+
# DATA FGNXWyAbykk/Afi18gC/oOrPEfxqzays5dhaRvCLmlHYWQQnWnzAZpALvlJt5YNvVVeGbpKZC71WDtaEHpwpdLtEmr5XqzX2a60h
# DATA da3FWmu/1to4p/1FGGHD9wK/0a8HwVwonaDTbneWoihPjx2UdqOxg9IELexgvRs0G90TsYNhr92r57CDXfq7W7Gwg9160AgMdrDd
# DATA 6dTaNQs7WAlqzeqlYwfNNjUI/+9tNF9fw+0T+9ZbsIu0OT73NjNQqqnXWxF1N3FYkPgtBRgGaiWuskDrw8Liwgvm3O620agLJD/v
# DATA JnPP82EHeHX5Y4fJ1unGORRo0wmZIkZuPqg74byhYmED85G1NxfoEV0te5WXeXtlMSWftAp8n/yX+mPPuNcTB+eytTCfJ2vMlrVJ
# DATA ZnvCAQcdcNABBx1w0AEHHXDQAQcdcNABBx1w0AEHHXDwJQMO2nw3SbZ4MYSUxkfFEf2dHzfLNyrlAs0s1U8HXIQ7MmXTmK/7ckiG
# DATA D7qhkd3gX8Gl6wwRcOT9f/+71yrjWzeKxqUP6b8RaGsU7p3d8msfbn3AWup8jo4XahAI/ShBlHjKQxGWsMzhG8TFax/iXqbjhe0U
# DATA Ie6Yp/CJ3/WOfZRNUudF6RR+5OiW9x+//n8QmYW0b1cr5RtylcU90TUgSI0ycwgxd7b7pLPd7kz3i36m+7SksOtw1nvOxbYeE/Yu
# DATA moZ5ouS9h2pva7sshYM909Phz8/RyMuggM0fZr9oBtiiJMBZCWB5f60+q/8uU7ukIshrepHRtXkDrsfQ6yb0Q3rAZ7QfwAmJqsVS
# DATA QP0wnpS8R/GU3U9a8F0qoAiXz8ZyPFkVbu74fphJGY0h2pj0+CxyJpozp3CzUM5PIpjKoZHbgU109Uo3z+gUrNWCnDHkjKF5Y2ih
# DATA R3WiN0705iQz6nqI4TyQ+spEi25i8BefJG2jiPPQaDdQM4z3Ror8pTTUFD5yQsNCB+IWPdwsShJpCPwq3KMaj8Mb8lm+Q3Ro4IYc
# DATA 2NotSzRTNgZ/PYbqDPxjmZKNzYNh34Wodjjc12a4L0oK9ElU0qfcalbDvtjtKLLQ/HH1vbw9l3uWx/zpeYB3WXlxSu7KozX8JJ2r
# DATA Qly5h1ZBpSu2lQBXHh8kItaUzCAYE0KORSArQ7QULZGIGh6yF0pkmcQ8pHFtH17kX0CeZTLMqxeJShHZfkk23oUQhKHaEYpGfY8N
# DATA ZX3mVBqNmh0sF3ZeFIA2C29ik2QJNDmmpRwwNmBBmTOGHrAEoc/HvzpzyT3cuOQeygFzsdJ10b0LWwQdYchsACqOPaX+nTLpKxqz
# DATA Oo5iCeXRYSg+lvQRtW8qApmk3tV8RngM1b4o7k0H0VSBBSYqLuk4mZ6/yHIpu7oyy3qTU5bZT9bRylS/JGX2EwgQIR/bCUXIBkSx
# DATA NJFeR9GCZnvCyKLcpU4cF5MeWSOGp9WLDkRzSg9uU5GEx52yuMMlfcD0N2aumEbHpd+epYfnL618mp6D4np/4+J6PwS4nRczqK/P
# DATA eFRpX7T0TWOgXm8P/vAn0aFY++0QClpePxlKw8LkYMShsUbdyKOCmoAWBlQOeFXsgO/FTwUfx9CErDDnhd/OX2j5lF1ZoWWj8CnL
# DATA 7PHqMtPjueoVRTkQ17LyEn8E9uFjGKAmlAorcCCOGJZH7qhxgr1x3l0u3x7ju6gTgggZxj2xPHFsyhvP+PAciyeMgHa5gH4vi/v1
# DATA L5HKpiXyfqSU6zB8TNVPinAp54MiPcBIcxJrQ4T6Eo+Pd6EFHIogoYABVavh/o1n1ggAZjcPZXGqjRSUrujfXUCbWUzImYrpaglz
# DATA 58KYvAx+NisI52hzjrZ5R5tdpZyPzfnYzrjYuNInd0mC0zIll5keRkBUbtiYxsX2DKEGl0Sey3my9N4T2Pu8yRrLT03eN8MzYfX7
# DATA CaCzLBTTXVmXMmrcSaiz+oYctgPtLTPgLp4XqF17253hiYA7CSAD3KnvFuBuKTbOl8saHFfeGHInu3ngLsQHYYwJBRkqxZxXcw5E
# DATA 9UDmPdQhLPjsGmXGfmFbu3eAhUzeX9Qor/by+T4/8jh6ip6oaz1Fv6x5rMaPvU13H9rP1Mpr3IQrEXXaNMVuWrLUps8vpM523R30
# DATA KRTvE7I8R9FhyZZ8VrrO0gnAIXSQeD63tHCiYHF6w9qYpknKdMeqM3UWFCdMr3jgpqCNO14cGty3iMdeufu1uja/WG078xhwSQVW
# DATA rZS53lktnPqomYZfqj25nXxNhd60kmGnULQKe4Es/KfS9Y0ojgOZKrJq9ng2AehdFraTlPVTLYHsDSByL4jxnCHkqBeJOpOwN7UQ
# DATA cu/pa8Xjvz36/vhXx78GRO7o94vouH9Zin+jL1/TU18ef3H8K1z26J+v6eLv+O+vAI6jK98efXX8dwYJ983R10ohHQpfY2in0pDt
# DATA MHHX3tRnyzz0TJ3x/ircD7373VjOYonovdpXwrPf3iSORl3qQPjbQTIZdI31D8/3bCy+U7gSxHU2OGS6bgKXtlBE2WmQLVCongdP
# DATA RU+poXXXIuReh4AGa014/LfwJBxHLpsRmE7hqjlyy4vm8mByfYoOkwsyODXXV339JJjcvVAkwS8DKMebr8h2pH9pTBDXFUZzNBgH
# DATA lNus6C4cKCd5FrKZM0LnJvMqM53Sho2aTA2lgyLLRVcUXuCj4Q39Llvbe7OQGsU0or7tjTh9UoD1Q0/fe/BTLx1HipSB4++UNqUK
# DATA M2MbCK7F6Qa0ueV1dLWJs7QNXhfs3PLEOPScsx4uyXrQWLozGw0vhQvx6gyGS7IXNjIXTmktXJ2xIJV0WWYYQ+F6NrTLoNhZ2QDQ
# DATA HBaJu9EYHCoyZcxAbXKIZ/MrsqWTDIczdNdYwHsHM4gOOyxYUiSlfOlE9og/idhBId4/ZFiqNtvTSE9Fxtd78YRP0abpxoQ7gLRS
# DATA 5ZvVMDHKkH2yCCfi51C/9miuHPMBB94R9F7yCY1oHievQxmY9KYl76GOtxxQULCweSfwgt0iZwU0gsxoWjDJDPkBXRxIB/cpk+OO
# DATA eI857SNx1/BezmjEHB2ckEfrAohMVQnKVce8c8w7x7y7RObdhqPXmQ52rTPLr3ymcREe1bPOMxwAzwHwHADPAfAcAM8B8BwAzwHw
# DATA HADPAfAcAM8B8BwAzwHwHADPAfAcAM8B8BwAzwHwHADPAfAcAM8B8BwAzwHwHADPAfCuDQCv4le71crZAXjV5wqAt2wFeiMKnsWL
# DATA q2Q4OjmNluV7Y06hNGjmsqsWtBpBNEdWq1SoAGpryGrWq1tnfnWz0q7Uq2d/daV+5ldXm412rXv2V1erZ351vdKq1hpnf3Wt/MzK
# DATA utZ4ZmUd1J5ZWdf9Z1bWuXbdal5lhufa9elefd4Mz7Xr0736vBmea9ene/W5G1f5mZV1rl1fbVnn2vXVlnWuXV9tWdvtuhLUrzLD
# DATA 7XZ9ylefN8Ptdn3KV583w+12fcpXn7txlZ9ZWdvt+orL2m7XV1zWdru+4rK223XVr12pqdA686vPm+F2uz7lq8+b4Xa7PuWrz924
# DATA ys+srO12fcVlbbfrKy5ru11fSVnbrodK2as2Kv2gXt5vBG/T17zTodGuB7XO0sdqtQY/Vq0vPlaDo6NxGnNMTUAsuLxfzwXpN6vV
# DATA ymJMgnLgVYKgXykPq4FX7lfKc7nRDqKg3ViKZG+eiaZezWjq4s+xaOrNchgF9TxN3W9V/UqQo6nP8dVBU29HrU4vo6kHlXq91jY0
# DATA 9bDV7oXljKZe84NOpXzpNHV2BhfbvEnfeDplsV1j0TNva1Mc1vYz80B0sxS3bNlNb9Ro8AZNbM9kJvribsc6/KzyGj4Ittm2jLq1
# DATA LWMl0N0KdT1rXYpLOS0Ds+yiawQfS+iH3eTgVot+xJ+yp0rx8xK9aggX2Iol2MpCcOvzMAvQU1tN9f41WbYyv46X7D5Qa726hpll
# DATA ALUXNPN0F+ZOFOSXt8urYet2Sa1xhy+ra+zkZr+6g6o7qLqDqjuouoOqO6i6g6o7qLqDqjuouoOqO6j6SwZVzyxGpd2wvWPsO0q1
# DATA 91C0PzLhj9tCrOIum23lwSHjykVUpDhMutGuoCvoomyzRaPOronIRBE2yG4lCOoBX8UsT2TT0l3NRuepsUKcq9/QKDUgHRGDC2IK
# DATA YbbdpgQeDxVsJPulLi9Ipl2EzIWJL6jm3DZKKQ3V0Xa5UK/twDjCQZXtmz//UP13a/cvf4B/JxzMRzf3ClSuFqedy9ZbhNNDVWD3
# DATA s/1wFA8G4a1KYTyY0bQ/vVUtQDLuVvD5zzkqPI01cflI4+kfzfb2olTGRRYg8x7efe+WwcZ3oniwjTfcmM+eH5f8JtPk34pfF2j9
# DATA 6yz/k+nwzoUiAYgADk3yEYTmx49jgcr7pYoOEp2zYolgVBDBC2jqidAhv1DVGWjiTSHPNyVzWdcgURKCZIsC0nMmZBqydPW1deYU
# DATA Z3DcW2HJfmYmGpBIm5OnpaezSr5zGyMLHFdzGjkQ+1AJgJKLLXnDMZaB4IeFvECH06lzOnWn0ambE3NxinVOsW6J5s9qlsV1UbLz
# DATA xhO0U9bQysfJSNndzUu67c0gjQthplXabQpsMQJvNu7EKmjM71iNVYtVMY12XpIuj9ZakKMz9/Urdx5gaKKuRUdcvOFabupnMm4r
# DATA xbSMfAUbOGFCPTCAQN1gGafIKvpTFqiX4FJo+Xoy5uup7m2IxUJrSqnNAbHlWU8yzhPKVhTnCNr4lJQYxrXmEPKRv6TH0YmeAqIm
# DATA sl7oqczDNFKtUurjdL+h7CKW28uUbtXQqNP/yBhSnjakoFgHvI8oFdN8WKgnKodi1rEoeT/DyLnwSKc/g26x1h9T5krJ40lDbqAV
# DATA PLAAUMVTW8hRhTOLgoxLKPRJz40+ljErMSLMoGJ6lTlLkK7Lkbuqi5ccUb06NxaTG9NkrNgGXFeSCavJQf0snY0xQmPLMfScqa51
# DATA oq7V/0/DJwJXgFXI9gwmX+NDVah6cAkPwsPMopIBSGIPX7X3OGJHpo4bg11DyxRjELE95HDdiqfrks3vx9s+SSjT2hgMQ65zNG/Q
# DATA CX8XHhTPsu21KiDToPJ6gUJDZdEuihIWtsZcciwlF3apC48N2UYJyukEiAydhj/pCUYmKKdZNwzoDLNWZkw1ptppU05lA/U5g+SQ
# DATA vb7zkDVRBnvxBc6yUccZqM5APY2B6szRl8ccXWlmXnNhZXuBfxFhNsjZqdJi6O9pnwck2CrKQs0eYb0ehcK6rvLLz5ea6ElAB2sr
# DATA h+DmeIvMnVepg55vqfo4Wm6TV7M8t8lLHTULB/xtWXtZPCYmrb+TwC0lbzwcdXR0lPrSnZ8snDJjDz7ZPCuEvK1n+Qunaw4CpjfS
# DATA aK3s15XN2NfK05w/2hhjg225eLOyyrQ8MPM6ZmPLljQMThrsYY/q6YLBfOUNzLw5ajn45vAV83Xh9VmMmr+oty2VYoHYdSLhY6Re
# DATA XKCITCIyXcI2Wd0K8DHX3nH6VZqCJgD3q3ceDQX4TblpaMjc3FjLN1RE5P38rIVlwEF9H0fJeEAt9ANe90BeZPMPVjNTxEWRSc7p
# DATA hOcNx2mIiqtBb8ZanEdKc5RV6enoqsmfMfYxe9DlqZhpMsPATgiZcTKWBLMU1VWp0l4TsQcTMiI70/URu8frDV4Ki/9QR09dlJk0
# DATA W+BeiKrEeYScPJiwanZyMKIpG/0UDyGHrivr0tjck8neYmxeQpFix012VvxZrfj5Kuf8zM7PfG4DfuV04fL8zIYnPs/jMFi1a4n5
# DATA ugr+sl75pR/uPx3Lvh1eBSdTJkpmqfa1nsAzzoIx/Z51yQB8mycBmP2NgcbG6P+Au0FELA8w1jdkjGUzTZjnCqtVdvymHPerGcRq
# DATA HV6mefxx9b0odTbb2G+/hlG8mDJeSzepwzdGTCjDfPut+PUTEdNWMPk80BdNPGsnFUtwCs40r/or6B9FVS5gTwi1V8qE9ZE2j1vY
# DATA aX0l402fFN3qprHljRxZBzakjoH6jrk4YneOjRqfdvOccfluYnfXS8li0ss0dlQ3YFLf16hk7iAmEa9ZaM/08wuoNmsF0gEPwtmI
# DATA 5kNYEEineUa1SX8XcBo2u3iNwKIMoWefgMwMhLT0MiXvLi7vx2Tv2ItkbAlFTztqNcOT9Qh11KGnqJnY4BEKwOYwxYY1nnXwjE2M
# DATA KF6rUIbSJIwVvQks6XAsPfVceWYOFNU7ZptIchlruUcMkmeRi5wVu+TRHI5pCYeJV9jmQUzMtOomkeCj1MzPAyfqAJWMMoORoZ2p
# DATA wvuYUehkTvaLNmuygNmzNO7AyxMnFjL76L8ff3n0h+N/BNX66E/Hvzn67uir4996YGfTD/929M3xbxfp2f909P3Rn+m+vz/67vi3
# DATA dPfRH+jhf6d7f3X8m4JHn76nJ39/9P3xr0HRRtBC0v4V/f3N0TfM0f6CHvlXugUk7T96dBd43b+hYL+hYL/C00e/o2j9kZ+kIH5H
# DATA f38HLPfxF46uff0nhNSJJcOoCLKcILI0d4r7qg41U4DwBrwMzKvlD9QIEWqbtiBIMHZOkRk3HkSKF6ZoV9T7TTTUntlgmdG6lqL9
# DATA EA9RHxQ5dHZuvpd1D1cNz7ZK5PKI2apWpdZMjy9wxUzn725HYdZdv05fuDK2IxrrLxKVTeEyuzrWI5naWrEwqXtJWdkbFNqFk7Lv
# DATA 9RPo1IeAmNOYOtL2K2Uwu50UUZJ7Eyq3hT3g4vMli4U6qf1ocBtx7fM2KbLvUttLFabSG+rNKaepf6stmKw1PSv29YmRd9hrN6yf
# DATA c1jXeOvTjeYvh+f2CkfyixzINxrHTzWMX8koLjXRJD3b7ftMm8plAKpNGmV76KrkceetPD5czgXZSUlp2GOpjHDalzT0sBGyL0u2
# DATA svpM0/NQyLST/uG0P8wKzNoLGercUMhiDMWbEKnfTzwTXQHvauYyx2aUeNJqlsN5S95d/pEFulMhE7OisyxhqV4VAaXTZEzWVl9R
# DATA cKdhGxkmB+zEeshSZQDZlF+dOBV9Cp2lHTgjHF/a8aUdX/oS+dIbDSkbzVc2NHyvxnY/i+l+AZa7A0k7kLQDSTuQtANJO5C0A0k7
# DATA kLQDSTuQtANJO5C0A0k7kLQDSTuQtANJO5C0A0k7kLQDSTuQtANJO5C0A0k7kLQDSTuQ9LUBSdcq1TAIzgiS7lV75V7wHIGkzYrz
# DATA RvRoOz/gYg2Cfr1c2a9Wy2/T91/M52MUtJbgrZqe36z1g1p9vwm8VTP/WMfvNrr+/GNDvxZ4FXq0Wi76Da9SpQ9etVms1bwq/Z9+
# DATA axSbXq3qAZ7lF6tNvlbB7YFXbXlVH3fjctlrebVmseLbb+WdkHm2VbUbhPXyMrbVkroRID6Nfb8yD2hr19t+u7MslNoCjM+mpFXz
# DATA yGAJ1wJ41bPqW82TzKMwaLQXYlip1M8fw4pfzWIYVC84hq3WBcSwWc9i2KhfbAyrjcr5Y1jlJnFJpVyjRnLuGNaqlcsr5cBvnj+G
# DATA QTm4vFIOWv4FxLDRvOBSPg1ITwYhDdKT8cwC6bVqgV9t5UF689g8vhLOg/R63VYUZCC9ehhEjaYB6XUa7S7N0Q1Ir0XWcbV56SA9
# DATA 3v5ZXGfdl6pzfLrPrYcWWXQ5l5DfzM96dCawjQWXLeU9Nj1uFyvdaG8nF/Icoe+tiMb1OCxI3Oed31V2fcuSN8P55tfvVcg8Wdt0
# DATA Ta2kzXf251atpCMYT288ylnuxrGAIwbaF46NYcVTLgHVljmg2Q9nhae8YIt4PlWb8qWBwrC8Eg0sryzfDrXwihJiTTarNcsnE1U3
# DATA BruEySoOOq3V0L2shAt2mayZRSzWNpVcqxopZ/f6wuGpAGr9ymlUVlCnm486CKCDADoIoIMAOgiggwA6CKCDADoIoIMAOgiggwC+
# DATA ZBBA1AU1Udxl67QQ4tBnARK+kwLLsJVvS37w6bBdqS1x93/ZxY9F1JbbHIiIR+yq4U19pbj9vFyoFGqFOvWRcW++h1S37ezox83d
# DATA t/l1piJujwox+G8j3e3tqiesXm/n9mhtLgEgp0esLH7qPTJKPt2981S/QXoyuqLs3KeqO6P/QK+z5xhjHB3b3vksl5O3+RCwthU5
# DATA Q3fmUjXavUMJ4uOXMEZ53o7mx+fgkISSnPxUmD8KmnslBcHbYXMuPw39cEud90NHkdXKXRp1WUJWThlTfRQG3kM5dIwkjKmDZcyd
# DATA SdiULV4g936g3r4jlv/ysjkhJdNkb2+QS0khpnaOWiRJ4kB/ju8fmSJQQMVkl2ultv3TDnQekdydwl7up7doEkEVO6EhK6KMGXUO
# DATA pdD4NfS28mt+s3yrWi3f3ivt0b0wFn+GG+6yUb+NUwsFFaBsQ8flHX139HScjCDYFg4ehsPx4yT/bNlffPZGqVxHhCghIyqi7T0E
# DATA pr/I3VDSi0e8sok72QO1LZ+S8fayEBtUTFKADyQzWTARcMdtfLjhM7Mx6XlNLlJOvP7lR83bXBd3rYkMSrpQLWMFTgCQcKMkXNc+
# DATA V3MSVsbXCEZdHT7L6v5tVTU+122Ap8BTbDfiIrx7b/cgHtHEqsSnyrlePp3+8pfq4kHUfhJP7Z+kt7i3M+3TOO3dn0y4dsuRdGuc
# DATA Rvo4i6Qe/PKXmA/evUcRCg/CmGZ/nH3op4cYJ5dU5lO2omRsNSLpH6Wh3P6cZ/t2nkgZSZzz5sXi8XURPRIFHkgfyinuduRFNE3T
# DATA bZP6HTOVXdLV8fm4eEDTulynhyIzj8mQt2PFkgJVpbAkSKzx0yMmKOs5ztrXpNVLMOJTM4dqnZaN07JZpmWTP2jtRG2cqM2mojYr
# DATA BcgvS+zmPtZdeHSF2sQosmVbtPDNsxNQuwqVcTEF6PJjfPC2URzpzWE8mk2jk3Ss9bOmczIXjOSyUg2fl4SWvSFKE7qyTsJaH/Ol
# DATA aPNxXSjGH6LL4vxOWDiDSocX0Pqy0sTFSQHI/fmMMetJVk6YH9ks5SVryRueApX5znxGaA9OlhXm1izp/KA/p269/l3+5u/y89mM
# DATA Byuneldl83dVcu/iB6uneld183dVc+/iB2uneldt83fVFqTW7wSnelew+buC3Lv4wfqp3lXf/F313Lv4wcap3tXY/F2NBf33O03z
# DATA Lq2vYtrwSnV1e/r6Aoip66FCkC5aicgabajveyJoJRydoamcdGAyQmL2AGwyT9KHkFqa5Lo8CcEveNWCF/Bw1ABFKxqxkKqHHQQc
# DATA tACFh4YEZkWMBqrl/lMP/SvDDCzZL+Ntz1SlaJjCvEErgmEQRJhiNZ5eD2wDKfPnX0zIQVvd1Gn91MnNlF7MmdJpQazPXBaUN3dl
# DATA +7wuA+FpyW9eMLfTFi9dCutciZNlDUE+eWhaqnBRIDO+Bit7DcRRnxOxwA3lzb1s56A2rsRrqefLcmKHcocm01DRhEqSMbTuKoXW
# DATA cMIiV3CMkjGEp8msIvuK+ae89iJirWOZxvPWLugwYp7Ou5oKeEAVVKbcyBN6KqR4QO/Yx05EoQLtgU3G8pP0cmbkQJdPi6GfPhdh
# DATA 9rFm5Jx27FVKpj8bSylXLZ2x5IylZcZSrqtybuaX3s280sh69prquuZTdQ5ZVvoQHoAR3cebkTKN9fEETRMywHONbG9G82N2NU8i
# DATA pYG9IO9NzcUogFvK4Ima4nMdmnMs56yGRRF1cx+Nq7oZ84hEpWv0lTFsJr2eF+4ncZdXP0dJnLJLfKI1taU7yMDjWcK0olvJe0RD
# DATA tNej0EREPeV1UjlKjMF3IHFJef8iAjk0WuDUs8zaKTX62VQMN5aRA/O7q4lwiHHJe0/pbHvDuDNJxn12wCh8XBR22C2P5ykHoFuN
# DATA 7mu5Jz5z94Rsa4yUGrzOlEfRVMyINJN+HiTYyDIFzVc24I1Dhhpa3Z4G6JW8u8hMCjoejxV4G0GwS+62h4VtXGX0dih32WXu4YwE
# DATA +uIRckej3yXdnCrvgN7GK+Nrkvd+CLtGuMV7iVGdx1U2t6gkYBZLAWvsPJW6VPJpMkwmk+RA6XtL9edVcl00XPU9ycQR9nUmsw40
# DATA YBiDLr6r7BBvljZhuBtoOhUVBj5FWV6XnjdZnp89Y1jgWQDkDMii4ylIBGtRLFClCJ9gkJryENYnk8E2LKlNYtLApl4qpiHd3sMJ
# DATA dTQFMw5KdQAOUTABeNGTiOHzqHmUjUMpJCZPk2W5h6o8AImeIjMbYWDGmlIyTucTKfbUSaSg16We88oV4iM5Krkwm/cII9o82OQ2
# DATA 0lq9blE7jjHMrfQqr3Mi5xdKTCmsybzMr8yvPOdrfXkt/SLNyjS+i30NL5dIo8lYWMIs4EZ0sW/jBZOHXLKmsk7R6VidMFrKxb6V
# DATA l06w73t1w8y/8OZscE5f/Is7+8kQl/S2bpJMUptv+S9H3x//LYCUx//I3MlfMeHyi+PfHv2/IEoefXP09SLg8l+YYAk85Rfe0bf4
# DATA h2GW3x59c/y3HqMvvzj+e/rzpRAuVcD0IsZafkeBf330Z02vZDAm3fYtKJdfH/8D/fZHh7C8/vO2RzLTmiQwktgUxqJRMtvrT5mR
# DATA IzLTangdxFOoa8gpYjMRm4207UKmFEa9kOGtMuCzBZPKzA0YFJiFIZ9BXcuvfMQ7LqgvjAfeJ2QxshHlSJbZHE73AleNsVxaMJcH
# DATA tOR6mVrzR11NBXmUvxmV1dz6QNVcDG8XSbMkY5WFFNQapuw1oSYxdiTLDUrrwkGWd9XWqgE1j8PiQTh4kpGayKwGbwf4H5Us2Lqd
# DATA EMeNaJSdQJ5N4XXCLkYIA40aRREZ+ViAp3p5yHMDRUHC+fnxAsnyhJq32ixZ1pyeFdHyhEQ4nqUb488zxmuY5VmH9pfCNXtlw/rl
# DATA jOobDeqnGdOvYEiXerkkB8yA/gzbz2UQLpck1aN5KH1i9lyolkkluYhlgdc5Q2R73ME4ixRzcpdFmTc+q4cniYACpW9qY92c4xty
# DATA 3EY51N4mcMucoxtRUskw2p/s7sZWP++A5thYAxblg1SogN5P08yEkpGfLDfs8u5RzGIYAoImjEe8tmRol7B2YnmB8gyj0Hgh666F
# DATA hlS+1W5EY+QwJrPhoB9xLEKPTRPeYNeLHO3S0S4d7fISaZebDDEbTWk2somv2rw/i3V/buPeIS8d8tIhLx3y0iEvHfLSIS8d8tIh
# DATA Lx3y0iEvHfLSIS8d8tIhLx3y0iEvHfLSIS8d8tIhLx3y0iEvHfLSIS8d8tIhLx3y8togLyu1WhjUz4q8bEatdu85Ql4uWXk+Lfyy
# DATA VvFq9bpH+eb51fLALwee3yi/W2s0vUZzUGlWvGpzjmtJ97YXcZhDv1X1KpTRgV9s0t8tr1Uv1oKi7xcrFH7wi/dqPoXdDAb1atEv
# DATA N7xmw/MrjWJAt9SKVXp9q1gJitXGXJkEUaPdXeQDVinajU/9oFwMyl6l6Xvlaa3a9Mr7jebbtWo+jHqn2W1UFsNo1rygVv60WCk3
# DATA ik2KVKVW9CkvKEYBYlpsNk4ga5rILXD0/Ka8rhNPMFvqcPHXORJeh4vWl5o7EVBhLr7doFmr1c5Ay+P6q2l50hQsWl67HkRVfwNa
# DATA Xr0b5Wh5UaMbtNoZLS/o1WFbG1petV1rVjJaXrNR8/3o0ml5XO2L6w0D9u7P+aapqHD28nMrAG0b5NhpkuhFnJvK10X/H/5QC799
# DATA 0hrCcmNnFfzNiuXJFD4bsicPng6yV1uE7GXBnAKypx2QK/PIzmmVoQpjp+qf7TGqsJ3GxoAZxFZsI9Bjt1rgKq9m32X5WrCzao05
# DATA cUJOGKKdg885+JyDzzn4nIPPOficg885+JyDzzn4nIPPOfjcSwSf47ThNEJR2zyUxtfWDWiMIJIcYrmhpf2pZ+hj6A0Gu3e2Bwt8
# DATA J5XiHd2RvUbBPP1IpjU/9/Bh58YgX8m45u+UPkniEQXwIf0HPtRtY15+uKWPnWdxKU2fIl8/3Hpj4US6CuAGPmtS1D2zQ0GHqsFP
# DATA mq3kFMLdweo1B6vdgeqX5ED1afXCn+1Ba/ZLZq60RRzRIKeFuZckXZwt9thPaI7ZMkkCgazR2X7W57OfhzOK/PcFa7UvO0h+0art
# DATA y8/lL9Vv3+CYfOanNfrhkQjUobS17KSqHEZj5nFEUUiTYQQhGD5aK1WNT8Ar9xsTWUQ3MH++PDs5XoAMMtmaWWPnOSP0TOEBTno9
# DATA OKb1gWbRPUTgUtX4FfOHz08jIr5QTeRAbphZJ89GrOZZnGY1zzuDyhlUS9TosgrlBGucYM1Z7aiV9trlCNlwn66bAVlSol3BGhj9
# DATA ZJrsTcJx3xIVf2a6aRcAsKRx+Q0lQ2ONXqfULBZjAIFcoGCxGvv1YD4Mx5w51pi/TPn2QlSLP2B5b+kbqTZCIQU93yUIF78JW51f
# DATA NPKip5SPXjq6cPlgFi1+Z5TOBuFU1MsPVfIOkNAxdeI9j/q7weAyZItnrKk01dyZGWuAz7WGi31vIMrTkPjueiJCr8c5Gv4u9l1M
# DATA f3wQTVKWYsJKFfPtRRaG2UbFMCYDfjamBhldsBp1I+tE5yxoKs4QPFhhgIjBfcES0XOsyWxaJkHmHZP0kNYK8oaHxvyQ3sbgKDMA
# DATA pK2obpaDMkV5TA7s+qOa0GGmPiUDmpw4SldIS3UAWNS6UpYuFVSBWFzKewSB72jkMXhl1KGC0vJTPUU9oLwvGIWsRPXOWtIUC0+H
# DATA WiuJZ0STWbsNkXwuF2YSo5okA8YXyzggGkeTGYS8PJ1pRsdLuTcjeYFZ7A6VbupmqMcXZ/phGRRuAuImIAsTkLyF6aYgbgqSn4Ks
# DATA nFg8ay1NxetgpkU/HDNsOMQMwxbHTiOlu6elIOfEIhm1o9UhFfooksmMpfM4tQUgMVYODsBPmgkuZF7iUVrsjJoy9V1UCvvREqXH
# DATA TdU2ObXjO2/y0mYW7/ZhNjti7nJ7Fg+6RotPRYYdjYtuY3V41ALQa/S2rPYzsAqflIWlLCD9YwbPNldYRaDPrBju2WRxVnav0NBt
# DATA JSUPAVfvNVsIYJWqz6/Kxgj1cusO07PaT72acA+bGX5Yg8cYS81G3ce2ZaIcufO30wRVHWZ4iz+tvrMziIdtjig+rL6POuYEm7Lo
# DATA zvvyMbv3pqTtzhymXNuashpvm5oYUdYYmrnSxWZgafbqjHRmOYeTrpme8uYHmaiqfMznwxyYi3dSm+5AdhbIxHbGt9e8J0OTjPl4
# DATA m0yFcmT1zsOYWU3diGFC1Fqr4iUYJul0cKjgl/gJVqKRYue1GuF1xaOpDIGRyGFil2TaT5SeaCjQcy0ey0DxkZGapZbL02Lt3lZS
# DATA mB4sM2UdqoNaV5uB9VNk4Ac0Jx6w7z6edGi6mGUh5qjUMQDFZXd0apYDTwl1C5+oLTrUk93jVQK2jXlvJcz2YdLGI9T7RVKnqSie
# DATA pLJopihgXBYXkV1WKzllfrXW5pdpcpJhP4HkJ7WLvchkFbwJfE8+jwyCSzKy5H1AY2bBY5W8mIywQ+V/UhAx6s6FEie7VcQdpjnz
# DATA NGwwxi3qXkRWmY7nlBnVWJtRqheTbHobfhwx5+ORVav41VQhDiiWKTtiwslArZ5q3wycCNgGF0KrVla6eJqNn+H92zvM/IURlgCx
# DATA J1/IuQCOcZ/H7RCSuoyu4JueaZsMTtEm3wWIDn0atbsiJbookCtT2+zL1NyEWqcy0lp5i8L0EIt7mghHj5DNL9LDnJ9ii6TAeFkz
# DATA 8mdZwfzK5jXs3YSKmMbIQXTIboKsjg3ol8zCUd5dcfjR7JaaIHviMmMNGUI9PDus9CKqWhQVawvqwDiRk6g6StaKuKBAI5zEnaX5
# DATA lh+IZW+dPRCbK5INd95P9C44rTzNJpjanQaniCpJRYnW+V06iSH2ojggMpbYOJoCzWujxP6HgMS8oz8cfeUx1gv0rz8f/9ejr47+
# DATA fPTNIkbs/z76+ujb4tGfAAA7/jUAZP8OXNjxr+j6vx19R3//jv7+/uj3R997x19K6Aj6G0DHvjr60/Fvjr49/pL+/S3eBBYZvZnC
# DATA +IpC+EqDyf589JWjiT0HFOiRrPxgH09HqdRnFOhxlIyZ38iAdR7aqe2JgdhNoHzO3kYMNJZLWonh8l3oozNhdX4D9SCxSMiz83gt
# DATA VewtmEvMbh8dOpyY7UNRHcFV08TyBXK5GLF4ZK3h3te1VP+yyBIbTXEI0PSx+CojXTS5SJ5YOBVEQT9MaTiFBUuWbtLrOZzYpqV2
# DATA 4Uyxe+Ggg1XHSBbADjNAdTjknfa8BDLgdRKvh6mEx1w4lvszqxwg6Q6HEU9+MZbwOmL8i4jpG143jqZLMGInVrrV1kmuLT07htiJ
# DATA KXAcMTe6X8Tornlipx7UX4pFkasa0C94PN94MeRUo/kVDeZSI+08yLZbPfumcxkoMTut4hhWOzj6CT2HxYd8QpECE0tdWFgkWpP0
# DATA d8BgH4xToSpx0qZh+kTtVUEE4hFOjuEYn8qSzVBiABjJUL0PXpeCNXUzspNUGxnWO9omAHwqwUY72ARY24rJQFhiF8yguxBPl9kD
# DATA yhpg8BHsAKxepU8oMBOPGM5xrk1UvwbYpY09ZLPpJJYyS0adaDJKHUfMccQcR+ySOWIbjTQbnsDY0Di+MiP/bL7HCzDxHU3M0cQc
# DATA TczRxBxNzNHEHE3M0cQcTczRxBxNzNHEHE3M0cQcTczRxBxNzNHEHE3M0cQcTczRxBxNzNHEHE3M0cQcTczRxK4PTawTVBZJV5vS
# DATA xHq9WtR8jmhi9rLzaTFiflD1qq3Gp8VquehT/jSqRT+oD4o1YLX8T32/Wgw8v1bx/HLFa1SKDQ934Q6/CQxYPuu6vVar0VsgjAHw
# DATA VSu3vAq9o9bwaq1iiy5UvGYdQQZeAIyX5yPsFl5XbeWDDerNbrO3BMxVLVtgrkorMGAuv5yvD+1aoxYtCSCoWQFULbJXc7FK1JaR
# DATA wSqN0z5v5Uu12vCqlA+VwGsW6S/fH1ZqPuWRh8wtcxavTohdinRnLQj6QaM5RzozDyyQzupn4JRxyzCcMm5kFqeM6lGjEW7AKQt7
# DATA 1RynrFfpNjp1i1PWqvcaGaes2+zU2rWMU1Zp1qv1xqVzysbR9ERKGcYXfd8GmC/LUVZlN1mpyctjGNJ2FklgJmSNOcvNdGvBj7yA
# DATA /lQCdjrm0FySoxKCivBmTjWVKuNYq5jp7tzbKzX2BbIbb862Ec/TGoSXTlchF781Q3juNu0Cc8guh+xyyC6H7HLILofscsguh+xy
# DATA yC6H7HLILofsesmQXcrisDhc3fAw3X0vnPZLvUFCExuYfR9u4TAWpf7HMGluqmt8PgoX5StNs2CoUqth6/PDrbtjmuA9hYsyGhxS
# DATA btxA0DcoV3ozkQvj42E9S+dKnbXiVSSQsoDU0oe5QnU4CxpkCFKO3YR8SBsHVMwZLNH7c5Qtd+z4tMeO3XHjF/W48VnwWtfgGDK7
# DATA 77S/az1lSwSsTLyXHlVewte6LoeXn6szfJcB3Moft75g0tZcZTgrYstypGaHyFVOZ1gQyDOKgLxSXeHs6lfvvMkTfNaV0zp0XH0g
# DATA FDpSenNyENZUn4OQnmgnBzjtHO3NBpDv07JzQ8iJJj2o4XdnE66g4WSope/VmXh+t47AXbKtYzJ+edusjoKmhFH29LBI2mYtzin8
# DATA RB5vThHLBEutA04b9Oy4LeBEZTvCi7tkk80mbSM8+ZIc9bTCcHaVs6vWiLXZlcvpujhdl9MaVGtwW5ej9/LXo+QA3b8oDrTDPdFY
# DATA g+SGGtj8q5cTuwC6Fq9AqB0g+lpOG54n+nT1pyPoLURKhsW4xbztJ3s7cySgEa8DZaAdFYTppvT3HA6JEk1dMvRkhjHL25ZL6LOp
# DATA Z5EtOWIcYS9n9uMKOXvxQwDoYwu2jLHFlQb77RPjq5/P+lV9IYNwNcvL4mzHGNt17CiviTB7SpjSBHd1pmODjDohrupRE1X9PYcL
# DATA WxtPf00s5whKan0JrVU5XUSNnKu6RUlCpbrzquw1VfFUa4y2lm92SXqXeF9SQOOvYrbelCDOR4GymE1W+7aFj5Q+vUK8hGj2Rh/w
# DATA PlxPdgPmBs1aKdHTWFRceLhDj6NdUJ/OqBeCVnk629uL2AMNYASvTKgOIpkAYwGoEqtKYxTmQEcAVAw0jUsYaOwbV+0OAipkys/Y
# DATA H09FAz0YKASHe4YRCwUqGKepjOTduMfSKVPRH2JlZ09t5Y1MfESOHtJEHI0l6kSZJBHLKsPTiMh44ZjqHAa4TdlOL4ixmxvBnLnr
# DATA zN2V5u6CaeMsXmfxrjZhr4nC4T1W34NmcQ+DTDxiGbPlfCfNl82kACfRMGZER2GV6t6bwhRcGG5Y2GxvFneBM8wGRgqN2mt3BgAh
# DATA D2/zJnAemrAgcGjuo3HdME2174mH+p8yJwDj2SShoSOc6jGX7fAhNfAZTChlB4R7k0jjKxeHTKV/SCF1aag2yYGramHgZGlAiMuw
# DATA 5yhiTTgvnKJCU4Rv29R2TYaMnvL2KLwjBtSAcn3FjEAk3pJ93t+kGJyanzvWDC9s5BRQyNNo0omx3zEHQZUM54Jh0T5LqFB5yUre
# DATA W+BscTfK3jSGdvVhc/FdDDABsRLuunejKfeznAyYNuF0zt+Gg2smsh4fbgD7ZF0a72o5StPf60R+gFmbZu+ovh8qkwXR3NNgIjyC
# DATA 9Ucq6EFaYDpGaqid2ugSM+l9BIae8hAmmNpoySPLhIekNiztqBt3QilBhc9EVi7UdAtzFj2lMW9wuC6V7/ORYmN+Mb5Ep/Mu7/RU
# DATA h0RmkwI8yawwPtTFz9NHRcqJAT9R5usISnxK/NNipHGS8kqVJe9RFD1hSgjcsszzQF7yrapaaMXKHF+G/afCDYHaIhzE2lEcpjyp
# DATA DfdGSRqnC2QONsRO0vl+nFDHxPmZdUHcak5Nimafth6DLoQTbbm5VWOAe5ud2JdAhn4P1Vfvg6HmGqLqiv67nqZcAiX6Xs5ZjjZL
# DATA 5S102UsgRb8bT3lWNqFuC0KQAoVUzBruOUVg8hJg0Q8G8k50kJzarHHxNKt7CaDou9QB6RaPXqpr9HW5SOEtmnQvmJ38os/fLC4O
# DATA PTVNbSzOPwOCc/Td0VfHvz767vgfj772jr8Aooa+fk2Xvzn+7SIZ518YdfOvDLXJ3330R6bkePTTr45+d/T18T+oUP4buDh07fvj
# DATA v8UT9Krf0i9/phf+0Tv+uxxpx4LpODTOc0AWZjCb0a4VRhY8v0B6FGQbqnCBe9xtHQDKfaAsqr2IFYOfwOEsOOGpZiUyZJQHUTAE
# DATA 9wbrCTjvRmGP3+LwN7k5Jrf3q6bfWIVxeegbSVrWLXLd6fE8bP5WjBzmRp7qTfqH0/7wInE3vMmWpj191PguzwiA3OOtmLjdYW9O
# DATA LLEL591gkpu0McfkeqY91tgpoqbD3L8MwslQLU1lk884FVf0wh5q0U9n21bmElRa1IthWkemCxzcC/ib9fVvtfGRtaNnhb1ZH3NH
# DATA vHGD9ikGbQ22Od1Y/XL4gq9mnL7IYXqjUXrzQfryx2ipfibRZkC+urZwGaQakx4hJKfzCdH7L7JNDGxP9JOhhsFYZSIzXRrQMNiF
# DATA XU4oU9ANkSJVjOVOMpsImyIbX3XC5Sg7vQR5xcFvxq1RU/zcGBwa57oevc24ndKN3dkg0lsieQkLXkUvHUedOEoLJv4Zu1g5Wgex
# DATA uF4j6mzDXjQ9zLkCVToYp8uYaEYBdyRR+QQ5QI0D1DhAzcUDak4eODaac2xiv16N/X0W8/u81reD0TgYjYPROBiNg9E4GI2D0TgY
# DATA jYPROBiNg9E4GI2D0TgYjYPROBiNg9E4GI2D0TgYjYPROBiNg9E4GI2D0TgYjYPROBjN9YHRVGtRtXtWGI3fC54rGI1Zbj4tiaZa
# DATA aXrVWrnP+JlKzfNr1berQSWfHZ1esxws8k9qlIBqrfEzv1Kd55/Ugk6tuYx/wqWUD6baanmVWuU/+62KV6mU6U/Da/mf+kHTa3p+
# DATA o+L5gU/vqnqVVvXTil8v+lUqQxBzakW/TrcU6RvdVKObfHqg9p8rLXq04lUphGrzUx9e5JpXo3uq9Vy6alGzVS8vAmIkQkUy4Yu+
# DATA 3xz6NcoXvKheBp5nLq2dVrcVdpalVaFnqBRjMj8Uu6ZWDjJ2Ta1VtipwTb4cLqnN3U5U7/TOwI7himzYMdwmLHZMrdIIg+qJ7Jh2
# DATA r9ur59gxFJ9mp22xY6r1Fgck7BjqJFphZLFjgqBdrV06O2ZAreBEeAycRp9ntxrKi8VxUalbdOyxc69C/zZ/ZJvbDTYfsiBPRtLY
# DATA vBnebCd7i5fFwriuSkvWT8nC8rBU6dXlTy40T1k0BijDo6jp/XPkGiniuRRTmLCMvED+GNeoJLsJ48r25/jWGo8KokEZ5tMf9a+2
# DATA MNl65QFxJa1mg7LMZ11+jr00I1YG5KA2DmrjoDYOauOgNg5q46A2DmrjoDYOauOgNg5q85JBbbRBqKV9tnZeWzeaMfxG9/p86kI9
# DATA VkAfuLRr9VTKrEq1eyfWvdcum8Q7t9HOP9y6l6l54bCKJecyohxWmi6YvuaZNebkgzs37M4NWydf3Olhd3r4pNPDK7UmL+VU8euo
# DATA uVCaywI3J4ufqf7EBeilQ2sObz6Ioid8wlHa7Bm15rKx5eLU5qJooFS527JKQhmi1QeVo/sSZOf0eWMFbhtTqXYn0J7zaI4UDQ4v
# DATA QXPunREONU+lh02VUjbs5V4mUH0J4nOP2fWl0kgmiOrNqU7Q2FGE+nX3EnTnHspRYvgAyZRTSTZwgUspV9aeex9nrUMjQIeWJyMc
# DATA TBYyL7EXajaJLlh9TnlgjHR8psmYUwbIDrfqhJhTs5Rh6AKmuR7EkqjPROFFAh4SqnOH9bk3KmXqmt3Joc7oDNUQDg7ALRxGLCGP
# DATA W7BQRYbGYFDy3o17pjkUgHsYLLZFpaI6QlQmXp9+nERYsBocypPcvRyEqURHE4WUWi3XQVF5R2ODN1e0q2lSgSX2fRUAtQ6KptSX
# DATA PnyDE3UiHjqZ9GiPhpRVkgE6V/Rxf+omRzj5ztsMaDxhKQAaqeclfuZGqocRjgOqU9wyaZU7ZNw5WTb+OT957JCTzn7P7Hdnsb9w
# DATA FvtpkZLPUAeIF/PNQvR6juSbMcufKzgKRM9HHu/lXQORvGL5oGsvp3EZfMhM5Oii4ZC2HNRZyZDWJgU9bXqIY1WmOsjEj4VTlPBU
# DATA Za4gsatBSlHtbgSx8fWJPAwaALbQaWjjXW8wG8ajZEZTRGMTjaiSJxCxGUeDAaTdMYb2leI62V+jkveTtsjtk2GCTdfQUuqTSaow
# DATA B8yz0W+3o/EWDDS+ixOjY/E+7CIKgmJHlZdqjWV2scnH50ci3oZwmEJLPUxZQl1aiNZ4HkLCerLu/eyG9nLvfktaUErmZcpL0SXv
# DATA vSSdavtPxIWY/aNjfRsZJO0L7CUo31B/DdsAwvbUjVBVZ9mQ+Zi86CIxVs/gbDVnq9kjg3O2vrzO1tXMyWcp4fgeL1bq+qwE2Pjo
# DATA tQWlhLQewxH2od0m7Sdz3hTYjcCASXaiacdhyXuQiQHiFI6otBm0D5chOw1CSz+QfZrsO+jFHS+l6X7HeFbavJUs0wwUzcUNNSA5
# DATA xeL4yBq/rPUhJqNwMtE8IT5cgvfA67PESFRnHBdpl2qdG5WUPyk/mfJk6R8zIKK5wjkO7EjE4cjTyv2UDAZWCpYSIM3iOVcT+fyq
# DATA bAlQL7fuMB2l/dSrCXeYmfsOq88YMQcDvTQawx+aKGtu/nayG7hVJQer79ljs4eRWfxp9Z1tttNYI3siVoq+86akKssHGY+1t1BW
# DATA oG0/H4aGNa7CtTaj5fkMJ13jhOcFf3HHqxy0cmAOJMU7g03rl6V0rkKTGefEXZOA+RhLXo7ZYLsHEcd4AiFT1PvMbIW9VlSanAWR
# DATA GC1iZqY1SGkYGybdiP34U9izMPy0BScoJduZCAekkeqMWGhIG9lT7xc04JZs/+qGvlTPbJNjSyOfFJM1WsIMgFcsd3Mjomcsp+u8
# DATA LXuq4skq3ylL6NHqEtLVWArp0Zh9sPkSombMHYl43IF9gVZmn+wfcYOGntR1ZfVb7ECzBoLnZRVEpFYTqI9iyoHSxQ5GZaWcv2zs
# DATA FFz/gnmwacE8CCcDFpUNB0NdMI+SHsNYRzSqsWbqASZ5NILu5edmJe/ufhJjZkx5b9z6Bdv1zaUypv4Fk7OumiVienju8rAjfmXl
# DATA kfW9pyyPv1pdHroXl/L4KzJYFjqyWaczG7CaLBYB1UlC1Tj0ZFWx9KiX4pUEnMemIaPkvU2t67BARUhmSBIPROV4yL1YMhyK/DMZ
# DATA F0NhidFPMXLQrBefv6CyFF3/Ynq4aTE9nLXb8/3Z6yxirXqzaPRJcpj1YFqMq+R9ENN0tzujjn5PlqKMfLJeFcosPDC1Ka864Uzo
# DATA eOcuCzva178Te3PTTuz1eNLlHQMjOICocYysxtMXxev+bBh3i1goZIlxVR486qRs2ENaaArL/INQc6mzdX6bt4cSNr0dhUTGk9o2
# DATA AS1kuIfOXU6LCTpTaeXtP9nGaNt/5ork/Z33E73hUGtwi8kvFjcv/TPUMqQZC7JDl7JaOL0cJtpz7fHKWGhpP4lyKLT/8+hfj788
# DATA +t3xb8AqA8aMPv/q6Oujfzv6jv7+HePR/ugx7Oyboz8d/2YRjPbPjFH76uhP9OzvPfqLAzz6pkAhHv2BvjH6jP73/dHX5iU2SY1u
# DATA +vPR1/ikOGr/Bioa3i/v/f7o34//0VHRngMot9nmwFtek+mBxq4aMjfEi4W8WuCZEW+zimDiaRYAoKFwJ7CMDHUAAmdABzoG3UAR
# DATA XakeT6a8ZwzP9WQJyzgF4OlYS06Dsjyagtj5Dp9m+/q4i7hqetp8gVweQo1Gi3CQ7GWIL95hyC+f53Df7MVZN/1mPLXwHRfHUIMp
# DATA rc5toIYmMoJzNjh82smldeH8tPcEA+61ybjAji6a9/dp3DHTy4I2stIEh6GQkTBkkUx0d2pPK+Y3ijT+FCopUdY5sc5XgWwqWY6c
# DATA ROxZZMKsPiYwpCISvAYGq+kCW219vVxtxMy1smcFWFsffQdYc+P/BY//GsJ2hmH/pVjeu5oh/8JH/I0G/FOM95c/3EtFzCfdjPLX
# DATA q/lcBrctn3AeJDlDDHTMpLp9iJAKcoZxMpNXSVynAnRKhyEWvszSmyf9UjtK4dKKJlia5ETTQJ0dW1DR68Y9w3ajZB96imSyIbNt
# DATA osw13laDIytkULBfIuo8wdik0GRcx4R7xaeGeSeQ0ObilPdQpVOhcfHSbJROxVRAvmSWw21FMQM9azqjEIbhaNbD54ltJCjPK/wE
# DATA bNNMDovJyCHbHLLNIdsuEdm2weiy0URnE5P4Cu36s5j157XqHbjNgdscuM2B2xy4zYHbHLjNgdscuM2B2xy4zYHbHLjNgdscuM2B
# DATA 2xy4zYHbHLjNgdscuM2B2xy4zYHbHLjNgdscuM2B264NuM0Pqp1q+azgtqBXj3rPEbgtv+Z8Wnob2apetdb8tB4Uq3WvWS361cqA
# DATA /qlUvGbg+WX6per5FfpUL1aqg3rLC+peq+xVGp9Wa3TVqwZerfK277c+LTaL1YZX8YvBXJZGrV6l256DnvmNWr1aWwY9ay2WXKXs
# DATA 1cpBP2hU9qv1t+lr/gUmrDyFrUIpqNQDr+EX/eawWGt4tabXKBf9Bn2pebW6V2/Sl40j5lcXYhb4gMQ1Pi1WqVCLyIv6exQAYjuo
# DATA 0oUcLY53cuZfFvUa9RWYO1WBO/GET9g9lUpfydBvfoNBcqxqUM+3ABMsBQDDxpOny8haTx5uNvPVvtfj77r/ZTlUFn+tNqneUBin
# DATA xMZxM9LYOGmRFjYuCpq1IMhj4+imWqWew8bNgeQEG9fqtjJsXK1TD4JGho3rdjrtXoaNa3WrrXJ06dg4tL+TsXFVbRSISaCfWcGP
# DATA QzLn/IvBj7wa/anSn3rwIzuIOV7cO0OaSkwL2AqM+Hrvs2IHfbVjbk+TgnL59rwzT9w9heb+QYFXyVasiKloAF41/mzTpYJSzcoL
# DATA rzrJB+Pp/RQ5g8TMl7CrWrv4tJczz7RTmVShP36gTX72FcVTsrA6OZCd9mFTv1xZwM+VV/PlTO4X7BxYY4qckEC2EhxHznHkHEfO
# DATA ceQcR85x5BxHznHkHEfOceQcR85x5F4yjpyyOPIdQDyi8Hdh7324JW2OEn5DvkMRhrOBTcwPtx6HE6jQ8iOe3IzmdYMvULV4E5vp
# DATA tv2dG5QbnWHpQ/pvdNc6JX7/p/ljePzwe+G0X+IZ+jaH82O/FCCE7HjfkkPjmfItpLhMt69Rc9mxFXeI2h2i3uQQtX20yZ2ldmep
# DATA 1+glP9sz1nI0uKDP+i45af3QnAuUOlLIK6uZQ71yYFUJsvBZYtjRB0qHWU7yRqyynx2eHIeHmEzL4UlorYysk5MbayC/KarHbWFE
# DATA dUGgwqtD06GjI3C6x5voHnfCdBYq2TR8Wn0nulTKWtz6gXxcfS91sN0k4Yz+iXx8HhSQs7w4pQjivdUiiDpXRQSRjLLJYRc6ROFo
# DATA P0wzBUScnKTmBQXxTsJuk9l4jHPP2GiAw2jeRGQhU+A55DA7e8GoqUUlj1p1jKPDczo6PB52J4cFLwrTQ24o59c9nEvDlUlUWvXv
# DATA 4hRDTU1WOtWwHSYzmJFZ2XRmaZ9qbsQiuTiDLkeoQ5GrZjMnMyJgVcIuEQwDCqoP7h26iEyZWuk58PHwGeoH/KVtzTw5lzp1loDn
# DATA oGA+2LhgHlJVL8KtcggNcEs5lA82F6hExhG3Hm42uoEwSAYFR/0RGo7WDcU5QihWQTE8GrNtiAy31DREcABrWzK+xYN+MmPp0fPr
# DATA u+aScmWldObO7d1NO7f3YuycgYbHbGIpI9MEheZ82BU4Tca66fTiyRDipLOxpwommbAEG/8q6iUHlKhJ0pbubhLhK+uGzUZ9Mqqg
# DATA bmDLeJynSHIxv7ISsQbJUxbJ49VFYoZbKZPHkzAeiF5KSGaNKRT6PoVxAvstkRzu0rQHRh6qpqFhTkLVHJRmNWDCWmkmU5LIxN5E
# DATA hGVwKGpv5y6YfPSvf1t5tGlb+UDmpDRBjcdUhU3BoHbDcqapu2wRgmHNwzhPR6HqMU55vMc0HzxabMxVyKxUNMOVSPiURa1RuvCc
# DATA nrso5mL88modvwhyIvpx591y3q1NvFt2FXPeLefd2tiLtdIJdjneLRbeMgC80NtLEhHF076ta6tfu873hSMNnu0BW3BqCd0UG0bU
# DATA PmR9LedtUsszjGYaYf89T1TVQul2Z7ij3F66YcqkFKUooZrnTVeWXTGunwrvrp2g50YvNozZQKrwtuphyFte9UbeaMxbr0v+agcZ
# DATA ryChlieqXMdGtSzvJ1M3mpjpBxdcU74i9MLu6d7yfK8zXO3H8ksBOxAosDia0N2lIHf/gi9LWVjGUSibbiiI+1q+cK6XtcwklB9F
# DATA gQ8X6VTJ7ivbdMkuSROPxTwb03g4lQ3pNyWIcxpAYqRgMLLam61m+Xgi7lchxqIfWFCJHrBe40h7aQsyY2Abjr0i4V4Yy64rbIkX
# DATA jBTNHkqegdxl9bTkcaEVePCzgCwsXpkFCb3KVFvHeB2sqXE8EowVwiSL2EgQYkGRFdRwaAySju1DaZ4izBdCgdJeRUxne+DX8k6B
# DATA bA1TTVtHWoKS9Soz2ckZW6iHntkuoPfEjdmG0XhZZPULb3hmQ40zPZ3puYnp6WzNF9fWXGkdXkO1aj7RYU4XLJphA8sMfQtmJ8cK
# DATA FPJJJMuEqbZCs4dYdok73+unbn39JV/5bzmnc+dV6kHnG5Y+FohwzRGuppzws84syoVwwN/mRbjnj+tJM+0kmCzIuw5HHTG/jf7V
# DATA nZ8snPbjHXxUiAvi5tZT/IXTsoGweHZsRdtjc3Dwg/CQpy/QczaG2T1espPJ0cgsCsKfuEchjQ9leVHmTqARjsN9nruUvIe8nDXV
# DATA FpS6R9lnqJVwGYszjg2e+bWuEOvhZKVpWsdGlWC+Mt1/Oh4g1DR+iq3rsgwp1fvK4R5XbjxlmDKqUPvRYG9G3YUNK/uX4y+Pf81Y
# DATA MhDEvuHPfwK6jLFhvwdRDL8cf7lIKfvfzI+/Ovr26BugyP6dL/z++MujP+FSwTv6w9FXjCL7Nb7jBn7d8d/TH4DIfkevA8jsG/r5
# DATA K0aZfUsBfIffjr+gYL4FrOz4C4/C+Iou/D0uAo3m2GXPhXWItPHUC/4QlivXtfcWiKTh5AlW+cJRVIDbg2alE547jkOZ/mCQoRkq
# DATA jkrzGhL0MrzZiANjbfJZPGA2KrXokHdz0sQynAokNcJWferM1lLLBCYdyUDpoGW2rWh1GFeNLpsrlcsjl3VjOYeZmjvfUFe4oi7Q
# DATA yzDumTup0klNnFwwvIzn+XHKGxDQHHhnmI6qI5htVmoXTjHTnU0v5ufCgTiV0k4/6s5km8hA2PGQ/GCQM/diHqu9en5QHMYj2Nrh
# DATA gCo39pHc1p5eRmeIFTaJKGABKcQjdMFiBirLSNrkwOCbN62aq02cfFN7VviytZF39DJnAVyYBaC5Zacf+F8KB9FVDvoXPeZvNOSf
# DATA csS/9AFf6mMu8Ta97Fo0n8vgluVS7EUyR0/FI8UUbi/p5fftcTZM+xTLPV43QaOLsU/TWEaMOBqGY064vBZ9lJwboNoJ6hKWWjQy
# DATA SfZr8ogr9d4z4mzphtgyzjlVKTzKjhleJwM+gCDiLjvQhgEVQYpYel0c+MHLn4ySAzkd0VWbS4GNGkdc1P1kNgH7ixlUcTseIKtg
# DATA 3TFohcYjxk3BWBANBMZzmTMECuQ0SpbDpxzHzHHMHMfsEjlmG440G015NrCPr87EP4uFf04D34HMHMjMgcwcyMyBzBzIzIHMHMjM
# DATA gcwcyMyBzBzIzIHMHMjMgcwcyMyBzBzIzIHMHMjMgcwcyMyBzBzIzIHMHMjMgcwcyOzagMwqzVrQqJwVZNbrhb3ycwQyy604n5Zj
# DATA Vqc8Kdf69Xpzv9qqvV2fR5BVonqnt5iTZZ+ystYPmg3+XAVkTH2uUcby52bT8ymHq7Xy0G+Wi/Sv+uzrz3NQL8r5bq+yDOpVaS5E
# DATA oRJQFMqVT/1G2fN9INi8il+e+nAbN0/ChzWCsNFZ+qagvoBD8xsBuGRetVJs1Ty/XgMEzQ8o4/wqk99qrRNe16nW28tpZRZErYjp
# DATA QAiBfqnRXmsJyIzikoHMKFIGZCY4tqwF1Kq9RmXj/K0veVWl3MheVfX9S3xVVYhs8qpKvXGJrwoqdqqa5Ut8VZ1RdDpV1QvOwFNB
# DATA 5bhL01A56R0tqFytUq82u3mo3DxCbilULvKjRjfIoHJBtx41qwYq16l3oo4FlavSe5v1S4fKye7Coiwz6GGuyjMIT69OGdulKeaf
# DATA /cw8FO6tiDrzOCws0t9qy+hv8H829g8KdfF/qpCH4WaQt1JjnVtTT8+yQOcXSGzzXpfPgmdTlUwuHBa3WOH6+st2kzqwbt7pdTo7
# DATA zGN3LZaqVoPhrKxaY88txDk/LbpE69Ax5hxjzjHmHGPOMeYcY84x5hxjzjHmHGPOMeYcY+4lY8yhLsRTmuFPQmixUwW7bbBzu3c+
# DATA M3OScbrL9UR6KT6/jKsfWS1fGv7uHdPs4972D/hR1XB3PlNcOq1cBDFUOfPFiKMxd9ViXN7+XF7dncna864d0I8Fd4dLGQKPuXSy
# DATA pGPfW/R3fuwHN/wA0dGh3ZEA2jOaL6JQTcxYbpYVaEdR1E3Bu9PPAJInMgSp0V7qRQfSgYzlVJ6IfdElPsGYSw4yGqcYd7VZP8GL
# DATA Jatk8WmbJ3Q7JVl82N4OC/uFmAohvKEM7f2dH2/H1DTKr9XLt/ydQhmbvrjVY/1pd7h7Z3t4Z9ev1cqvfbj1PlVJPmLJoSKDlOHD
# DATA +dQbJDRnHd6sl3d+VKnt0Aysy3pW25XCh1tl3M2P6WeGP6IbF2+6ndUcyXLUgO2UY62qDpxHuxy/baSeUYP/8cU/IWPT27hyY3dZ
# DATA YW7Hr+YL8TU/uFXWucmh3v58p/RJEo/oWQYXSqTVxxtLXtmLR3HaV6KofqALE6dlxeEiAMSfjqAyITgAPM/Qw+25ClPUtWLHrhbU
# DATA eLgemWzZoUje5gKnkijqWQU9/9o6k5FbHhpPFs5nGAfJGFKHjrVyhha30CFrtqKudGbeRYHr89Cl6VP0M1YcJexHOkz9EA24CMtg
# DATA GvVBNKcU4ZQi1itFWMcUnV6E04s4tV7ESp3SS9GReDCbZg2Ad21pTU8Z2Y2oxHWUMboKHXsxVkTGfSJWzJxyPS5luvX6ftN5mQtG
# DATA 6L3cuqUWzJVw/Qo9ejXgsiL9FCfLmYdkhL231ch7kpK+CcZEKbuSKenXysuk9Ku2lH6jUra19P1gtZS+ZdAg+hxxmpjQrIqrVV5O
# DATA P3ezlW92EAtq+RyzO9Wytj9W6+rXOJ614OQ76xxmfUmYC9r7+gAjpZsPIt5RRrEwg9By6Fb5ReVMxoTCpIHTlC837fiYz4RcOb2X
# DATA jWc8FMoE5I51ea5ALua1DzFucou335pdvZyXysFHjwbaCXUTuTfnf8rwnlm5rKQjSE+mMAHPLxLhXfj3ROpGGSvakreVM4zGTJcm
# DATA dJbdn+vk2QyC8EfuFiXAS1WYtWcgOcN6Ggw3YDEHzSBYpUGTF52xqWCL/K/lnDDJwNz8ASOhXqFg35YegmwI2Il8g+df3CJvYbh5
# DATA iZuXnDAvydmfbmripiYnzzieqcQdxnhUcB0JZM4gU7l700xEBHjAmk+mrVHphSmLXEFwijXHjAhVQZTThqE4Lo0QmhZrmJ9czKEX
# DATA sM3Gxn4Lj9Y2wISv+YEIz0VCmIWrFO2bEkMVOjVTGmZ0Ufakn84QzT3+bZYe0pg7YqYXJVA6i4KCEMn0SA+0DKTn7iJ9ogMd95Np
# DATA sjcJxzxUjyMY0kreN56w9JgkMT/sTUPGKr+XTERZV41183BTQSRblp+kVswRC4fGHRn6tgOFQcY2QdWxie8eq1MHQJFDH+6u8NME
# DATA K9EPbbwoPOQgDLDUGnx762Ifd9mqWxv5eeNRUmCQAgIRTg1BGCr+UwN67rAgnMJfaE3iTFlPWLZ57T1VLG102cInsHrtUOrvmjTd
# DATA xQ77UQJy63yyxEzIc2MXVBVNRSaz8AHc++rNyFcy2/og+Cpkg2QB/wBgLyKPteQOy7bBqCmgEo0kKWDewXubzFKVHyrgmPLh7n4S
# DATA d1mSmlXaAFCQLKUBKmFi7BBSa2M+6ca7U5ZP6TnWfy00EeUAl0mZjjMW1HPC1UlPZmHQoRsOk640bhQeXzZl5enDc0mvB5+6Ljut
# DATA YS1lWPDGszZZKNZzrD/HjTDswgLyJlyHpbLS2MXwYn6lBxI7DTpkaafUJtcl8RHQ4AruNcUgYiURhDJ5IfUMMbS9qLujtI7p+d5s
# DATA MDhUvBUVU3bjpFxRJd3DHKmQlQWlTzjoJ0odkTpI7ASlIp700Q6lwNDHzyNqxTB98expRwtztvTGatDOdH6hTefTssKesTq0ved/
# DATA PSzsMUYCDbtko0rq+3pa2PVRk34uJFVPIkhk+/41y+sioWJ5heyLZorNK44vRYop9xureaNQeRcaGUFSI1Ixa5KB7Q6NxroTu/M+
# DATA a5cIV4ymKqxPLJMmeh/9jnvejDPLGb0HJLNHsMuFRkb1JrtXZiawaWV3egILL4YU2aG66WYyWNU8xV6GnYvqy1OLcJmDcS0mBK5Y
# DATA Q3Je0B+HBcYyxOMJanQamWYmCs6hma7KNhsy7Ie4i+zcnLeVbG6IFtta6Gxp8xRScmrGouTawF1YZ1uw9V40Ky/Dmh1EbSV+bVPN
# DATA /tejr4/+tXj8t0ffM2Xsm6Pvjn7PdDH6dPw3x18cfWUTxo6/xJVFwNn/hctHv6OHv2ZE2dceffmKLn5Dl78Dmezodx7f8wdmnP2D
# DATA 3Hf8WwUy+wokNXrBl/TvbxXIjOPzFeJ0/HdgoDHv7PdH39MPdP8fHdvsebFlpZGj4WnxdV6yMuRNrAPRHE7UxXnyllBwU7R6xJFa
# DATA +U+hssgMefEeJfvs5QknmVfJIiGieaxFmb09Hw2HM7Nt2qyjuGqa2ZKCuTyimfhU0oWXq+vzt8sOAnP3wyilEagjAzYX0gWjzcS9
# DATA JHr+cK3Iwh9TCxzYbKPCu3Cu2V3P0jvPZgamBvCiMYR0ZgOmcLQP8TdOUyj3HKgnEkGxc+49+CndL5rmBc2p0PtdDMSE7Z99wIs9
# DATA ujhY4JltWDNX2ziLze5Z0c02TIrjnDlr4KzWgMaanc0IeCmcWldoAFzG+L/R8H+60f8KB3+pnws5YaHOnkkLugyy2UIimW5GWZUu
# DATA RguMM1lW9qh6oqbeEtBTwXv78eMHjwrqYKlaGeaS4T2jE7IfeGWHk4ERGk6JjKY0UWWpPQ86T/WYuynezFQFj/IaymB5AwApizvA
# DATA nGVGQB5wNp5EXfhG8kaBbQwUuJmis/BgYIw6yjxgqwAcKjEPBTnF8U/pNRndjJ0q6WHKRynVPW3HN3N8M8c3u1S+2WZjzUYTn1MZ
# DATA yFdr8Z/F4L8we99hzxz2zGHPHPbMYc8c9sxhzxz2zGHPHPbMYc8c9sxhzxz2zGHPHPbMYc8c9sxhzxz2zGHPHPbMYc8c9sxhzxz2
# DATA zGHPHPbs+mDPWrVWvX5W7Fm11+i1nyPs2cL680boM85clXlMCRPaVq2SOyzm1yv5XK8Ky0myvZnLuG4zCqLeHL6p2gwCQXXN45tq
# DATA ksVWPOTdEg9hX2XxqM4fWqtk0ajNY+uW8cLqFi/MbzUNgypHSPvLWrfpN6qLNadZo6rT7Euds5IX1tutTriUn7YueRUhpV1S8ioW
# DATA zWvj5NFDF5a8qjC+Lil5VfX0qZJHD50redVK5Vo0kmq1eXmNpFr3z9FIqs3yuRuJnbwLbyS55J26kSB5520kdvIuvJHkknfqRoLk
# DATA nbeRBH7zWjSSoFq7vEZCsThHIwka9XM3Ejt5F95Icsk7dSNB8s7bSOzkXXgjySXv1I0EyTtbI7GBreWmVwuC/Vq9X23V9ou1+rDo
# DATA t+perb5fPQmguroRnIWGyZauoWGy0WzRMKvteqUZnIWGWY7Cnm/RMKv1qFkzNMx2p9Ptdiwaph/Iz5dLw1SbeWV2Zzl71LKb4WPy
# DATA hJ1MdNup1uI19iXbJnKhYv66eM/8VoXFJbMmL5mVmtgqI4tmuVDVgvnakOu8epZ/TM8Cl282zO6m2eTeJBzm1uhOSq56Zsny/OIN
# DATA eqV+Ic8X7868iKt2SMqLfCkicQUsBIKlhkXUp6p2+eWCVqsFD8zp4J3sMVqSKnYbLvieF7cLreR+Olqno3U6WqejdTpap6N1Olqn
# DATA o3U6WqejdTpap6N1OlrnBdA6F9Gce3FbARSxOgfTU8ExNYOKrtz0y7Vm0Kjfzs1Z1GN8eBiPacQhGeazMa7c8PFkpXZbsTHvq2Ps
# DATA 0A8YTfuDQ8O5YkQixYTq1ZvY379dYSziW/HrglR8F+fM5ZTyeDBLPQg2e+pF/KyK0qrn73qV4EfmbZnQjsxLKQ/2I0Z1blMcfow1
# DATA /p1lIdksQ+ucqROEcYIwOUGYxUPHTh3GqcOcXR1mpZLyZarG6M4achDSXlBcrOSAjTa888aSkLk+OmZXATSUoZJBHzKQsQoHXz0B
# DATA JKifzHXzaQ7ZBjfCUpCgb3EE+aayvtPgBFfTBM1wDpag+oywWbBkjEFRJ8Hb/uv49ZOAiFZwJin2NZOa4OS0VE6RDLE20APAKyom
# DATA wfZ7J8dXP2ciay5YMd0s0zeMqbaDuJ1CKBGSI5ndQl3XOI5Oqi5ZIBl4Mrtkot44Keb1NbFeCfkzXYCeMvF4qAr5uYf+LSP9GQsx
# DATA Mr0feiaqY8Ly4ObRNfI6sA24SMMhzwF4eYYFYdRcs0OTKlaLZqgJ9kbS9KbgHfSp8pFxONmLrNBU7vZ61Ne2ZxP4NvAcTa4mERSa
# DATA 4qkW+FH+apl5pCzLzUpMVKUOxUBmHUy7npW8e8mQ3WLU9RWUWM+oa/SfMtElNZnryhPhROkiZbZMBpkdUrxmE/atKvGhDaiBL5pS
# DATA jGOeuInAiomAs/lfCpv/tKST66IUae+UWI88eSvmEVPUEnk9GiJxI1btobY1jNayT56dvOTzpa52krr03B6PywCfLApoXjT8ZJkO
# DATA 6VIASq7s9JYYqcjLAH9vwp7XJsLSO1jVc+0dr4tpbQyNU8p9K/If4ypjFhwESEQ0PsOplLkyNzfBYT7Kpt0ar/j24/feLXj3Hj0q
# DATA qHFY2gsPC0rLHRBLmReJ0OIYKqGhVlJlpUYqBSP7GafZvEGD7biBx1MM22uIio+kM5ANb+thkXetSKhKrFN0F0qgIyWPyrHjBFHC
# DATA uhFoftGoA0XQUUTxU3qsBaq9VF37eplN5Fnzqqxr0Zz5DuSEqGvBWbGmdbQVTJENbnXAMBJ/hsBIYfaL9j0b0JNDJYmpYlnyHmhO
# DATA DWLOq2O6Iwu9XhgPZpN1NMuHEgwWrlbxLF8iC9zur50N7mzwpTa4qiTOE+888TnrbqXxfn3027lOY6TOcM6hJ55C44EXX02cYuNe
# DATA woNkXnxcu9Dn6WezMXCCJe9n2CN+aBAtdEd31oGIzBBjsZE2Nv52JhqzvbOxkHumWyDNE1/vvKoNv0c45s0NG/oVqQJgy4xD9QWv
# DATA 3jRW4lR67+kEH0WYG6/qiLOe7I1JQmMwNez+0ht+KmN6D9TmFbd8AJMNqRQtbhabxq038c6b+v0yGM1HQxmqyoAzFg+/qXvnDbU5
# DATA kWtwwcOw0qO+P6EyY+wnVbVpl+9UY0TBk8G4oKW2wbkDpjjtS7hdFa0V8XgvHFGd6tq2oInM3UwCf+53iYJtuhn7i0p0EkG8mxcP
# DATA tOV1ckR+Fk+mMyiqs5S4FQdVwGzmcW1lSXnuUybJwETmJ2NWVDE3UCWPpqySPubBkzJoMNBVPbXic1MV1E1V6VZw6ddjvx9pOy/L
# DATA ezH5wu6QBn09y8nYPlpJXJHa034yG3S5XYo5O4Llh43nmFqJuroUcMlj+5Is4EFyOOQgyD4HzzqEOLwlQw8W/SdJmwdOJTE/GzEL
# DATA UYW0Dgg+Sg6UXrk2ncNpX0f/gwnL2VO991jcRJzdvN6i/cbsdCZrnIIJtbcZvRR1dnwPfmBGambjAgkFyKK+nSdGINWP4GCn4Twa
# DATA 6Xu7ivWYrQ2uS8x74opW6QlFPB9+dePeV551REyvZ2RchX40GKv+TBY8rb6IZfBpoExyUIVxFD5BCUuPibqHNctuNMQL7BmWAitQ
# DATA KDIfZCw8WoE9NVN2jA0+N+ufqJ/xcEOG+Itl23/++UeffzjaeuUvXvT/KOujwcfoMOLRDFDV8eGFvwNrl/Va7S/UuvHcv345CCp/
# DATA Uc7++4uy7zfK9b/wyleRATO0OXr9X7yc//3whz98OBNCRIc6kLjL4wwqxVbKe5GLjP3IKoh37913qNfgZU5q38mgy0v49ECJwnpF
# DATA pFLItt3jwzb6+ydkH+rPSfoKj17o9Adx21OXH9BXfcvEPJjO2so/o6/gSBaGA/19RqbLK6988PDugwf3H2ID9dbW1it8xuYVtcGy
# DATA J/uq2dm0TZPJbnSrl27t8G5GnAzZAoPvJvWKN0H1vdkZxDSD2br9imy17qUl5APcfI8OR51tPFTwtmi+3tyydqBusVOoiNCLWW5t
# DATA 7exo/1IpehpPt/2d26/M7/vMR43PkX2sHqI3UO94MOI3ZwFFHeRWwfu5iszyd39UeMXzvM+mcorkls/bHQrD8Onrsx72Pvr1arNW
# DATA eEJW5qN4bxQObm09euetv37n3Xe3Cum0Gye3fr5F12l42CpsjeMx/lHfP/p8R2WP2pgaTSY09Pzyl3qjasoB2hd4sVw2vq7OEtlD
# DATA vJs7raWf72IsmCbqWIXKfx0NfvA1LqhDfgkORuH1P5DDQ6U4fRT2onfILtrDIQXcXkJ+3cNK9g7unLvmveqVl12+w6dtlqZBX1Fx
# DATA PYAhs63iO/9Guj87tTUflPf5K6jEr7xCU2i4KT9mutF2PErHNAp/LIXOk/+dWyhiZAGvoOMSbAD+UGJrIsUUanuruLWDHwbRaFse
# DATA pIQEfgXX8OQkKmE/AW8j3p5s/fxu8X8Oi78oF1sfl27e+k/Fj25s5V+I/yYhpnI/Q8Luo/i3t94Z7eO0j9WT8DNbO/yMGoh3uaXn
# DATA ErOjEyG3cGXZppo//RgndSmmNe/HHjb0qn/Wx4HD9aKnHbJ1U5lIqhjA3px00RugPyrx7odt9U5UnY+xv3p7ZyeXpynFdBqOOqiK
# DATA /HjBw+kBk53q6g5VO8/fKHfUVFdhTKOJip2+vqvj+fPyR/KDvhF7vuUmPpS49U6XimVLPR6N9uNJMhqqveH2fTSd68V7dO9nn+/I
# DATA lfujfTkSZCd1vhKExR7VgI8+q9c+p5tNLHZ0pbGyxnr5XPZYv+yoxnOeTMJpaDngwl8xWZdOIx7ZOZC9YrEY+f4Cjt5yJLfIzsPT
# DATA EgxfmMxfeFouz13a3VJ7VuRa9r7lyfrpKJ2NMVzR7MKKpkoU/uPTnh9TyqSn4B2D2/SagufvzCdmeWv9+COr2X70Y3oSp1ZPipnO
# DATA cLv60HNWzDjLSzQ8RqOuOoBq2utsuI1Cxi0lmmxQ98bn/FD2WIeg7OGnUfKVoL5B871vRWNZE/5LrC3BseENFcfrjaTzBKdr8A9V
# DATA PnpwcsjTp4LMlztcH3GSAQWHTllgemT6l1SQ2IFFfa+i5cGWwZyW6X1qkei20M/gktIzf/igWTIU08W0H2L/lTRX0/vtUmRHEV8U
# DATA R5YyXUqPI9gu4eTwDRYWTCaHLGwXP93dohePws4MB8rNSI7Om6aqXX1zloFUah8rK4Z7VXPLjnfT27JrmnlE+8wTdCdJWgIhbFuH
# DATA U8CVn3z8wcOfvP/uf/F+Kd/uPbx/97H+cv9/uvduwSsnQHqYMDl19HOvy6Flr6Du6UAiT80tCof52ijX1ECJdlj6hApuW1WZG9w0
# DATA s5dM7YRzRiue2q5lJZaowLZ/nrsN/211uZagu5Sn8Kko7l18NLleynJ9F4e9YF2W8FeNBqR+9LSwGHSxqKoEh677q1t42nzjtxlz
# DATA Wl5O0+xid5KMd+/C4loWbqqXaMg+3R0l9J6DIma+MUAyqYRCJVdEyW1xj2YKcmdpgIglVRE8qW1eHYpuNfgOM0UP+PgZX5SBnQ/2
# DATA owKcBdPZJPpYtlDuPp7M1MFr/VGsz91quSDrpnx9J1+QVotRhaqNKPipxtv52zcbrnSYcz3gyha6WTfJlpgXs09saveSYl8oi36+
# DATA PlrVj40yyfRwOg07fTuuHy2W2rL/Ns1zf22mq5N5eQN78/z+sPuZXwjEMmAbGnbnaLqtvik7+dYp8taaZEqkFrKX5QCyl5hfe9jy
# DATA MZjrHijaJmMXo7GmiCZDKR8axjpRvng8yaZd6+k37v/s/Z++++6JJUdP0ixp2ZNZeQW6uN6EgMOOmgFgJNpW1ZgnRei59Qy7dHey
# DATA x179B/yLKjq5DWf5Pg7V7zQHKCqjm9Kk915YFWPVM2zCL32CboMtph7kf/BoqiKR67D53MZ2NpnBfSUVn4In33iCoazZp8Bwevf5
# DATA HwixmoD+Uo34N9943eNpZ8poUNXV2g7rkvcTDNqhx+geD7uXRvBSdjwan8IxGTVzhsgjdu7fxyxs6/0E+7izGtkxPvQ2X+/Fk2HU
# DATA 3UIZUUX7+GOYAx+T/bbrbX38MUrs44+3JNJSfNfUlTjBKfZhdBluv838f5V6tVatzvn/ymU/cP6/q/jvL39wc5ZObrbj0U0yHbzx
# DATA 4bSfjKqv/PCHP2ThDuHVYvFFFsawxoAVXyxXJONIQ2/1Bq6H2ozyeLY1GFC3sMYriGWKek1/w54m/bkfpvAN6q8x9MEmlhPw7P5E
# DATA WUE0X/uzaTww33gOYb6lg9VeSMoP45AMJ7Y/ct4/Oe1PBIZnLlB7yzkvOfazyYAiL52oTgJd43kg9TG8juLJRH4m2S6jZzaQqhGC
# DATA 8vuu3dfBuqbpj9c+5CIyBcNGO1ZUJtEnkVoKRN7IBDTlctPv/el4bxJ2o59B+EC/eDEuZoiibJKRCxvKtmmalGaeI+lplyRE36Ye
# DATA ZRkfFKl+TgZ/y3HDEx6+w3Le8CQUG0S3eEPV1o4OTyYZY3abKg8ANvzsykxG3jHFwZipnktx0HqmKz+V4vTj9HCI/TLbll3Jydw6
# DATA +j+OvvaO/nD01dG/H31z/Kvjfzz6HX3++ujP3vHf0Ic/Hv3JO/67o6+Pv6Brf/COf3X0zdGf6Zbvj/5Et+OHXx19e/zl8X+jn/jp
# DATA P+HrLQ/zCFj2EgM1PKroyLnH0hBG/bZ8SZUNyPPZjxPb8uOl013tL+mt8olEZHpIPndnw3Gqf4tGWOf8OEw7cSz2CbacYazdrejJ
# DATA mvhkugWeHLO6k5rwDp+g+xibWW4pm+aSaUGx382laIn9MDfFxEtoaolo5QscS/MHmEHu8uxx1dQTIXX6VAO21SQU0Rwl2ztSLXZW
# DATA z1ORi0t/7g1mUKJZeA22Kc+/JbsrwfICg8i0aJWUs+3zoXs4Q39AxgXN0PIpMVP+j3tda0afy081rX/4hj2tf+Odh/fvPf7Jw/+S
# DATA j/LCNDuXDvtt+eeW2uDqWcbEL3l24RlJLFpeiStwypmys1B2sxG3Qf5RNXBZW1YOKuMWh3dKKbLBBVVd4fDefu1W5jz7KPet+NFn
# DATA 5ULd/9z6fee1D0s7N9SFjz6rFOpVzIPsV1vdwv84+paa///P3rs3t3Vd+YL9Nz/FsZPpA0gA+NDDChTYTUm0zbZEcUjKTppiUCBx
# DATA SCIGAQQHkMSm0eXYnU7uxJVMulJTU13Vt29q5gMoitVWHNv5CtJXmE8ye732+wCgbKfvTHf6Xos4Z5/9XHvttdfjt/5dbfKPgEF8
# DATA qnb8F4oFfJk8/z1ygud/VizhK/XyK1UQuMHjinqmnnyonj1Onj+DEh+rv59pNTayQlIUdgEOpSSToA4q7RHZhONDdi+ozKyp5Cud
# DATA p7vkindT8BjN64uLwHt4XnUFsNUXW4POomor3YvP89KVpWAa/vfnnwLrU1zuMTA/xRBpeGqkak6QZarxP4N3wBB/gZPxBcyX+vn8
# DATA y+dfKpb4VOu61TUV9cCOtrSSOvrs5eT7DdZBY/Ey/F6ZtT7Qm2ewOs+gYWj/CXTz8bzdNyyezoIXv37xEbB1vXisI7A02Kh9IQ02
# DATA dtTW740Qowf/DS7napz0gonAsfjoNfR2j1Pl7rX6nl2dzNYpXeBtXW1sKV96If9oXe0F68ffkrs/Wty7WC6pzbho9l6t+Q9V9fRC
# DATA efGNlJW9gXqcKgQ3vh6AOh2hMlnN7llag4t9rZZOyAPYvMJPdlf2hJLUrJVnDN0fb93Z2kQ8GPlRNbST4HewmV/85vkXFcMBZLfj
# DATA zn+sCj+GilQxxRmePwEewPxBVS5z/acXnygK+wrIEyhX/f61NasEZBjbyTTW5T3YyTJuewrhy06PCXX6JMzYCzghf1JbSy15goP6
# DATA jIUd1eMXnygpx+4xK6LY0ADIhja3o7cxNkfDOh+nO9fW18s6fbg8FOC6pAKcwYmxNPxCe5YqApsRCZNXAL7SDBZoWZElPEfzhyqG
# DATA /zYaIYc+lJdcOA8Ppd/RMF58HFm1L198rOYEyRiOpU+Rtj6hfRs/v/B0uu68U2SsJuwpTSRUHZDsi08SKgEPNSXwcmO3Y6utbqml
# DATA Uf/9rOeub7EBW7GL+7XpvxVXsKv0RXrq+cfA2dXIVjfXq2YzzkEQPKJSurq52dy8u7XTuLS0vHS/t7V2Z2P1vdV315qbqxtrt5v3
# DATA tm43OI0NSscPWw+y+iXAfeilzi5MzZeqM82du++sbaCxAgdBovj6xs7a1sbq7ebfvrfT3F67ubW2g0X4/lvDos3j7FHpEkjvbv33
# DATA eztb97Z3mptbd3/ww8by/d6d1a2/u7G60by99tbqzR82b69vvNNc21i9cXvtVgOxZtFQQ6sFN1dfCoutEOrqWYMM9xuGthUBDQ9v
# DATA UBmyVKF+Xb1y5dKVYIn+jXinYTZEmi9+SRSmKFjVBS/pe3dRTAPSe3IIRnXePKNgiXBXExMIiytTpEFFUXAgqi6DkPC5IpwvVb+f
# DATA As/54sWvWRjkN49F1xIR/Li/lomvZCz0dVfUOJuExnJdeJqLAK7G7p4jn4PpO272RhP2gYanm2bINt3bVV/tIZgdflfI8sWttcnG
# DATA tpJlWxtk2TBXd5wH2XDYUXf6NDW6EEKRRNWHWG774FncOaDAAsSv0D6zwkOT/QwciEkLgkIKqIMb/qyB02s4cxvUzh2wommBlCqA
# DATA E1l9k7o3Hu43atf0j1fCssHJ9RkyWXUuKcpRPOcpkfxvnv8WOSs8Al4LrPhTUEWoraAEEKi0KqVf/Mph1c5xjItAfcCnPH95OA88
# DATA 4u1sBCb0PDIZOdESUyJvJqkwPJcTFBq/RLnmj9A5kB68Q+VLHhD8o36zHwCImbCP1IZX8oU64OAjVR2cVjBhT82SxOed3TqK+zbP
# DATA zPNR8Lnqy6/o3OBOBMOiE9hfABbFpRNloJzl4KLWA41XB1B3dUHFx4JLvCbqhtYoluJ8Yze9tbqzemN1ew1Oo3SvXJNvbaNM6Z3s
# DATA FHV2lSTQPnrtaesqr7i8ih60aq2ATP+EKwesG5nhUxJAQEaDh0aWpgVVkqVinZ8lTseNbMX9kD/1dVlfPPAWaTFI4CWw/shTnG0K
# DATA T7TfFa6ItwvwMVdBTyAQJ7N3wxa5k6hynRwnBLRznlcD2ZyMUVqMzWBpy4rb2lDDs7YvjIUUSkqaRss+jKpklZ9/z5ZrHULyDAys
# DATA OL2FO6ZwSGg87HYQ/kfNPv4pS0MBWPAEOyy9p56t0kdyMJU9NSZ+RmrMSawxMG6CKq7kTxv6dKXlWpeu2HD/k/64hxbbIajf5HBh
# DATA 9Q/TBEhV1nDUcxxMur65ShXARfStbn+/1V3ffHBVHnq9VoPTNKw+lxlj6V4/li6FE88UDlDlHNDLSkZISlAu43QIedmKZbzAQJHa
# DATA uKeE7tIFqYhsA+DjBUca7x9UGGNxm3dxTahIKFYGmV0cP6yQSf6UFGPqnvA5Ks2fRY8HfEGnwHWRo54gi/0Er3c2h0hIP/HU0qpZ
# DATA B4Kz7WVGYocEz8DLn9DQQTUVvwH5teh0KOBu1jkg3bI5LXf7pRmt21lVjgroaXsKd0Hr4Kolz39LJ+8T7Pov8MUfeayf8ar+EVcC
# DATA 7y834Yahx7WxtvPe3a13PHkpNsWSrqPP4+XfOTpXlrh4GXxnSXA8IBG6aZ94nmDPQnGOx1XQkpFZQoMJRGSVgy9IQC/8CP1j6wuB
# DATA 19DZxOHeWisYEbVDr1YsTawv5AO89v+c4D2crqdPtSHXdv10VDb6FoWS1Id4532WvLP2w8a7q7fvrYmeRD3wPHXwJqDzX9uXAtJX
# DATA Qgw95teFi0HU2UjVMGUY0Z5/iUa2T1HY+oq0Ej/Fi7p1uWLdLGlz4OL1x3SOSwm6uspoiN05bmPufcX0dOoEe9dU9ef/xtc+1JbS
# DATA 1FrrhU+9Aaivf6Yv3uJRr3pmG04lpsIYVBem+kU73tt8+XZd262bLAi5MI2fIYv7ueiIAj5G/BjG9BUNXQ3q15Fbrdm2YClr5set
# DATA lStX7dG0O0cQzdgQD4EaFykbL1vLLoyWsHS4H7cDwiY7OB733odNhmJ0t3Wy327VxaKHuRisuINyJdlPfX069ahGMcolrM8ZF78/
# DATA zh7RX9pWQ5GoTRiIOlKN5y5f3vv9UejVy1azLiUrIZY3ILkVdbbg1AwjAXswntEDMFnDB+onnGADY0ncfntVzdz2vTvbhuuClnHg
# DATA WLnniBAhDRrVXDadwW7OpQBBojFGcrSeIKE/oT1KBKU2gj6syRQLw120xwHREORD7JBP+WKaJOlF6uFFdPj3eilr8gDRCJq0NGbe
# DATA K3SK9MDYnVJ03OxlQgdxEaT0/WLYf4iiYNB324uhTGoTdIS2pe5CU4lah1b1EH1fy0lS8lanDO57/YfFhhIxA6AYD92OSjSFKydM
# DATA 6itLhsHjgtXGL34GJ8jHimt9YbFbTMrYwBlcjNkh0AocI0V5wWStngbMAghc7BzRsfyL30uW0KiXoOifRoVF6hVrdDiNKGDL2IQr
# DATA MOiVOu+Nt3iN4rBr4HbBXsKjzH8ort65fsKyjVNQSyuaZFHtRFRrSx3UD+xiKgowdPkQI2vXqQSdD0Cl5e/oe733exCtr2Ff+YvU
# DATA Cy7icX+/4ZOYRV6oapfFcFcAHskK0FnuK01w0uSko/0VzmM5Pj04Mo7Rh0/wbmgNpXj4Gwh3Aq+4AzQPqbvccj6kkhy+CrkjhqUO
# DATA McwOcm9Aa8B4GqxoV5YXEebSvXI5XqU1XI9Cyua+Fv0SjwJRFEAPdu2QEZ42oLPDjurZEF14ueo9iv6EVpHti7uGCZ7jLvEYuFvO
# DATA SuhviqhyyrcWS+x1DkkksCZini/92QAdxy5nEUnJEIdpafASQo3sUtIRGj2VxzFk7XTP4a7yAdEREAeqgrb6lD/QlyHcYWMcL5JA
# DATA dcgfeLQ734b6v/lAZZb8j4pz/UEJxeqq/OKfDBcjVaVi5nhXVtKZuo6CaBrwceSBmkOS6OxesQbOKeiaQJjb40HpBpHZLL21n/e7
# DATA kE/NmiD+Ute7CA8W5joklETe7z7ATEF5c5h1W6POg6w56ttxUiAIOGXRpBqGWjkifVVLK1Pk+V+yQGwcAEmIfwIWVpxZVGSA9R4v
# DATA 48//AOcO3Voe43w/scyIMljZNMiswuNwdofx6Pq1qlvd1vGO/1Ngp8UddsV0d64WmAJ62Xg0bAGQBFGCaCSUXKuxZABFCObf2GYA
# DATA TfCoByG+lEep2zrNhnkCmVyT1uEIcMz7PUwgi36i1xmshYLQCW1FN6QtNTEHG8Pf5MSU72qnrZOufZSaF/ScwkKqhd8Vvlev90Ii
# DATA Nsg6i4nWq/sboXCJI76nUf0qt+buS2shzDXQoizUJeIKzag98BDk1cdQENVRL3xb8adrbvw2jsvcR2HDnaWCnpTWk7OJ0YSIzeHu
# DATA 9jSTg9sL9E71Z5ZfF0q2j1GifYa7E6Ra7eYuOj+UNmCb/IwdRb4ANcMTbeRhA8WTAn5Llja6vn+KOjdSWyIvfuooIlxPGLNYMbso
# DATA gxbJzgvukSyVxa8o1uFJ5aadnAvOzYHPt9gRjp1MvpMwqi3hMjHQUKdXRWdXPb2M7aXu8w8IRKnfbWvUJiSnBf9MneWEHb2kgFCP
# DATA aod/BIXyi4+kA9XgbknR9yJPSKvsQm32L88oFpLJi4ibu6mec7CnGc7Jo6LWnFIga4JsaBpzvSIM6oCWR9A/4tKl+WfDOXaK50JU
# DATA DRYvFZnI64FpWnvRF7IfkpzgsS02GSWho1wLJa36HNGJQsZa3EZ/E4SxcMS8YmXpDEeNwinTXsqCRK33ltuyPwgpH5Vm7Jfxa6+U
# DATA wJsKtURv/Pk6zyU4HOQcN193LXXPUbuB+ZfU2YA43llJgjSsQM6uwRpgE5JWH8vageofrkO2tekMT7BDFuYqSRPAFES9M8FJgWIF
# DATA OqnfqhH/Hk0fZDR6LG6qSSg+PQm1UZIQ1CVevbnnuARg1CdZaYVcIIC/8CZg7w7zbZR03Ndx4jFlcKZka4ddjipTNs3wrWuwdJiC
# DATA JSXWBz/JCGibYLTHJ7ZOyJ5JZK1W11xjvBScxTrn7zH7/ADAYUvN3LESNU09dieHnZMW+lAXC1hW97i4d0OUStiSOJ1+X2LWAduw
# DATA 1UvGrJyR4xaZruslIAzd7jPl7vGX242Pos1Iz+zBFUdMAdm5kUv8j7l7veLIyHHd830resjaIRoA4BL637kNkW7atC9a8I27t9aa
# DATA 2zurO2s6HmZ9bRt3LDNRhAeCE5Y7Y8aFSvYi5jpjeShvk5sKODVa4oDziTkU6cGxT2sblW++tOLEOFzmpJMDWLUbFUaqvjxuYOTv
# DATA 9YXE4xscqwQT6dljuFcCCqOj8Ww7SDh1pNaPDr6BM/DXyVL/tddeMzdiPct2gPhWRigSjBycPej0x3myfmf1rbVKMs4pMQL4Az7M
# DATA rHTRvRHr/tRmGQAaplUjId0lPxn3R63kx4ok4GDHhXyIceHDTE3tOMPo8w6iFkH2rjbfYjEsYzww4eYcjEgsoOLtPHQn3HP3qNzP
# DATA 3JK2dtCdTLxJz38DlIMUv1KLyT0rWiAsVwnubNqHttvqNQlYEvTKTZbmSzS0Cs0yxPwfHHcwDbzlysmYI8wQ2g0gaVEc8A9LRdmk
# DATA KvGFrVag24PJNSEeVDrkVW1DoAKL1TzsAE4brunD1rBt9Alg+y1WCZNaHYNNeDjTygWCxz+jC4at8PkTWUcpUuyxGHkTlNKeqsvn
# DATA x+QZ42mJ0E/EqMd/VeBT6Fl8ebIFCcuBkIshxSk+TMmegQnnHwAs1gf3vxuBhrO95x3nElItQr+ePf+MrNighFISNRqSPo5MBV9Y
# DATA 4OKNESSxoT2gwGTM966Xih8Wjp7fu+OPealfLL1Rv1+jP8tnyxUK9qOv5xm0uH+SM9JP0XwRHyqZmcLxCW01zUBdcgvGGnzB/obu
# DATA ERFOiv/dS86OX015XoMimXnsmXKdfiPSN2OXoNMaGfDZYyZRPFdJuyXwaFD3+EEJQcEct/SaOpIgDmp3aS+5kFwu79Yve2IaVBzM
# DATA CuwJejN1fL9jrwi4Zj9GEubl5ngjPTLQG31K2iQeOPh+TLNAXie9PXCKf9ccQ5HUz2gzOV7In7Ji/xkFpJPGVyjLYEHn7vax33Bh
# DATA dQQ2vQ9cMox8I1l2/KL8fNX+ohK0YKxJPp1ahSyfFcw9YPeQOZlTJ2MTqXeua2fv1G+FnSWn7AATFOza3AF+z/hDaFdNpxte+2j4
# DATA U1PjFNI3V/9Tf+P6M2cm5RyDtPsaLIVflY+OSQtqLcb8bfG32u0IpkGe6RmwCoVDsvyQAyqNtXQOvxTHu4Fitf8JdYg/pdhMjz8F
# DATA BpynOp7Q51yUWwH6iwk6nO0HT7ZJvAKoYnfzOC/J9s2SGDmtKZmICmoBDb27jSa105PZ8neL/U5Xqp7rXhbMcjCf/13ND02B9n79
# DATA EwYW/j6I5PgKWdLH+N+Pnj9hGee8czkYoFfFLiU7Yd/0RsP0HB33Aps3U4QTyQ70RxUa8uPfmrAtiiukNv4mmJv/oYb0ewyufPzi
# DATA Vy/+GzNvmR8JaYhq3f5McS2qApYawHX6I6TYj1VNT0Mx6nMd88IAL42CqDF2sd/c5IBBC1yWBYVLK6J/pqpQ7Xx56XtXZVYOjolu
# DATA sB3yryO7231EVruPXisIp7oXzso/OyMuIIqoNvsZnnzojIgPrDEU6e3ZxWKKcl7rvgsvUewd6cTVRV039qKwBKSMRM39is352CVt
# DATA hs7yX60oXV/Elnn5kunsw0CPGbAuUWVq3ZZkBuCx03Nn+NixSnA7yrM1cPLdRDTJcllb/1E+A1EMnKZrAHr0fnaal3YvcD3cxJ79
# DATA SS17NAJV8Hz2ZfHls9XvnvVCX6Sh9nrgbja3cX2OgyNUHccD7XRPRe99RqYRdEMl6x94hJEyvx7xdQs6rz2UheVDqnecCMf+nNYU
# DATA H0jN3EiqJgq78S/ZQKH0Vzl2tmhXI9e/1uwLKk2fCkopYVC7syr+yiSnY3FSWk7xwKcRG7f7ucCfz2P5wQXVYLuFNl7Eaoku8hQX
# DATA GN1ZXCXb6ms7uBjPGBqss5JGm2N7asUp39191Gj5290JZgcoGQqCWowPeNF8OR5n39a+UPyDXTEBe67WzrIB/MGKKstT0AhUcLKn
# DATA FeHyHC0O2uFXGsHDIlecAv+AX4uT/JdoVoPDHZEpEoiVUnP2B3DGwXBREyL+4mM52m2MBEsYjDjBxKU22fwNmZVds8H3cOwGtCK+
# DATA tbh4EBTjBqDYosoX2ixRdNo74nYRrWSHhxkqCFXnS6I5nMWu5hmRrnjamIr1PfDjjzIelPO0D2vh6pu7xeOi4SJoNayt7h4NkJ47
# DATA cdZhCBIVCmKQnHphrKVI9L7L0Lm4hwjgTCcVod51+sZqU+O1AKNmRqG0qU3AVUhFmMaDTRsNvKIUMu9zXDtQRfIFRaQAsZloJ45U
# DATA 45CbGKiHBSMc7jthWC59RX2phpmi/w4IoEC83opy9gyJKOXF+BtcjN2lvdpQoxXhk+qyxi+qSxl7Oay2EA1J/RodDQlIXP7+CcOh
# DATA tzv4WK0pJAMATHAlozxCR7lWu41PlECWHXbeT6PWyef/VrhzYbP/QlE/CKY/x1gttT6fUxSoaKgS2kHPYKPgFsEANCiHYFofogfl
# DATA r+w708fWwvA67PIEQiQX/uUXqA36g1K6P+50IZEGGhEsm8/OcSdnFgI4IWBC6CNcHbg4YXIA7eIBr4eDfpdM3HBiiqxg1TeEfKhZ
# DATA D+iDgInZBgV5BXqqRwDB2YXgHVVhDxMf6PgxgCtWB2ItHKEN8Q/jPLtwIRbw6EtfJgEFnKHWdanOlzcNSpiCfj/97nclNlmTqH3K
# DATA xLiufX5obQd0yjJL2V0MK8ab/F6sz5wKRJUlmCu7HnYypc/cuFlUjNNJYanDSSyQ3sW+W3AD6i05Oex0GCovnKvw6I0yhuKJmrKW
# DATA 4RnhFP6f7ITQa1c459rkOETuKCXXN7Z3VjdurjV3fri5BssK3EztEGRkhNPbJ7D9g+OsPe5mw3Tiaw3pf6X9fr87g/SYC5Mk7Myn
# DATA 8OdGIymqQvOgckEHrJlX88G6UWhJ/bI2Ie1CaksIv+wctjxPoEf4Bo9dLeSY2NrHZMD7DHHqniqx9BmHBzveU9MPX4K1xW1xMUmv
# DATA h7aRUOvqBI+SmUw70z4pNqNq/3VtDXZdtEJ+ULcy36BMGeEuHg139ZHtELHRn1nyJXzhaMvgwdyqstmC51cxwfNpHJMGzcyfc4z+
# DATA DOF6Cuuexf5nMHK6ih10W3QXc1qcyhrUjOrvbIaOeWL5RWwPvYJAOHGxZfocPXFuLAJmaEVRhLZ5Y9r9A6xNBLjiuhD4F3wrRuPg
# DATA lyL1gOWPgPnOSfEe1Z+501hPkN/EDv+JG0jhXo7xlmtjmer4KWB0DXHgCM17DdKGVxJbN9rYxcs8qf7Ke/qlUSE27AJW5qmI3G35
# DATA ICO8HaCrB4ZH+8sdKHZPlWLZoLDgJjF6Qjox+s6CuvwtX/DFppbuvXun6f1M8ztG/V6bVPXflyfVy/rHJfXi2vda+3vOE/l7mfzk
# DATA dGNxNkOoHlNhPsPAiMfJ+c6Hp8j+H5NjxM8BD0VcAQye+idBhMRuwQKAIGyGZYdOnGlPiXqyDNE7Wv1f9/1GUZYgz03WODENuple
# DATA dEAnOEHpv9XHpFlDxZRRZVGGKHDwqoueRaJ91RMaFXSLdy2U4j8r7lm9bTyvolthIr5YM7X4qAkXKF0NiYI/g6COQkuIBcSLF82Y
# DATA L77ttknoj9cmO/TH1cnfsYP+fYltxm7BJdcDANfJeEJ9diScVcKy/IBpP+orHuxV8BS+pfjXoHkT0xrAKpuOe5BI7pHugB19BSeK
# DATA 1megI1jMkFNX54G6O/8ejwc5PnBfsf7VYFJXq3aATwglVLjCpvvgK2PnVsojCml34oMAwtzgfDzgNCMxh0FwJDQkCb88bycEJsEI
# DATA Tv0u9yHX5vTEK4yU+TM474CVrfDIjWuxQ5MjdHJWOFDJKklD2Sv6JPCVdo0NekYOAoBKVmJ7rbjK7MKXEQDWeSboKwqgQacuFpY+
# DATA tzXbU8zWtpP67gXqmOG6Sma4YAbLXBftSmH4peW3HkQf6eyrxYYEEz8RYgDBjuAqZgTguNhA4s/gWUbI04FdJNnMT7Z/mFQ5g//A
# DATA eQOe0Dk8ZQHYX+wJFDdMwglCRIh6HdB90hkVbUk2fzRdkKHpu/hlt8Q8sRZYhxdlIQbnSOBaQED1ueNm46RDluogWjMM8qBOWZZ+
# DATA fGAs/fRzftY0y7z/RHMvgporpA4HVce4peNEuQ7ps23ohf7jdgae0HXclDDE5bEoHW0uMa9EbI78g2IfU6mN6Y1u4RR52hfd60mr
# DATA pyTwdgJqDytvHDvtUyPgugjJzOFfcSO3XcNjkvucHoPnQiYXquFfSoCA5O3ncWKzBG16dB4M87/gzmWNuwCWsdDt2mLNASXUWWBr
# DATA tZgouZ4/QS9bwlAjT+MpLHP6rNGu0vcTqCB0xrMEk5j0HuTgtl3ufDcz70h2nG33HMFXajmHdzoAJaODPeNCwCXO1+DNppNYJ2I2
# DATA Zlo2R0cEn+19SwaOCGC+4ju4lyYxzicOAIIJn0H1WRMCuZrEniSQq8TBLsCszhV67yKN0T8OzFjPwIdDG3pDSHsufgpvBj9qj2Ru
# DATA 6g0F4HM1Jsa0CCIp3PJUZpYEK6WM3L1nwJNEVp8/aDOIptMhdDgrkZhNH4DKRwgyQ5+FEmSBDnybHQ6CTOdgnQEikbpRuZKJy0eD
# DATA QUeGO3V7yrLarsd7RcJVSIjzhY7+Zw0bLaYZChtl5XYL6aGbgaW4/7AHKRt7rUF+3B+Fxm8b8zl90O+OT+S4Me5Uo9MBqJjS/U6v
# DATA jeYy6nTdzjcIhn5ap3riDo2FtpcKXSd+az4FifCldHGJ62lbd9mPdsDFckiTdY9EbY0c/TFx2UY0DN67JvpB6jS8eRiN2clli0tr
# DATA NNGvqyn3OxLDFaRfZevIEkxS+iXHYHNMWUAlCEp8KYdZN2vlGeesri/MdLz0wGVfTy4vBZpGfbfuKcIddg60Q6jaw/0HGeWRVIRN
# DATA invugu8GOj3zzPcmJnINf+roNW6zXNwriTejCDMdW8YfOtFlru4LPruYlJYq5eRCUrqcVPnip56Xg4lGW0rJDq6cGcPph20GQ0jZ
# DATA 06ViBqMdU8RPJvA0WnBdlRxs51HrCBFJuY7a0AJ3rqeecCsYyuDRRMms1Of1EEiZKwu6aqhh9jouFCKmpiW0PnNdF1VdZVVFtfQg
# DATA eFx+A1+8UW+dtK9e/qA1PLl6WT3Ec+LIA2UysyPIoxok3+iLKhbWavDSX//xgICIS6ZyNxuueW6n/iulR8cHw1qnb/JILZJXl/4V
# DATA 0hofG00GUDfenFqc0k2bgSJKRcMn2JiPhIHExcXQ3Q5d2BY8n5kz43GmfdDwj+pg2H906v2s0qV+aDuoWe5toaub8XAjp7dJQI0G
# DATA TWxurxpwsMBo1PkcMeIOOJZnu4Mpg3VHXTfQ8O0itk7z7wjGR1AhYCk2khKry0VvLmSkpSh4hf+6ZjG7WKQPsY5Vor2NlvSagnNK
# DATA STROL52+TexNY1+pacSQoQP+oDsoZXbhSeRt0srBQc8/AXMf0oAkJRM7zb/5eLKADvJGqewknW5acLThSevWa2fqaJp83sXf6fbl
# DATA qDboH1ritjrASCJG7LUaCVBGzhPKPd0BXisRdE/0PBtFru5J5J09hXHIBj4Shu8zOIbx639UNfTKs+RnrLK2KFUReIU7qMKwF6lc
# DATA aIeyKcz3A/THLuK6XZc2gFlXp2BiYh/qUqkWTAw3H3R6PbBHR0mKWbuZVoex8wE/x8lVMEiO89qN4TdIz/bmGa1+M19crL3Gfiy8
# DATA KlgYDw+fCdix/aYQWrlUHNtru4fI07IcgTwMdV0hzPCgYqfXndknem5CH2js9hE/CbV42HI94rA+F8EUtlqOUNH5KWn6lqH++VFW
# DATA c1LOIfmyEb92MiZaGs02eIJ3IxnxOCug72prPGjpQyp8O+6Xy9KSLUWosdbIHaEmepzciQOPex2J9bbsu4dG6jNlIyFNiVCGRIh7
# DATA 1BFPYOYtqU+YZ0wFdXdW1ok01FnOEladuz4JhdI54ivmItdYB5yJPRdden3B3ndxG9tr0B8eYaISQ181uoW5oC7TSV3X3Ylc1OVl
# DATA OXR797fIubYHhXxWDFrZsSKgXoXd5OVSDszPmZhSOIxKIIWEwlTqoKNQRhwGQXmKLpWPldxHSghXQCyFg6oEkk0orLntud4JGLP/
# DATA ObaIslRR1CvNkEcX2tNglkaF/w1wuqQG3+dVnr/OYwmDpIatjlqRe9Tsu9QqYimz66uLJ2P7aEs2e8ja9t/I0bged3V9jN/RFKgP
# DATA K+ychMYleUuU4rkbCISxbQDWXka+jUUjMOnpqhhDTUwlNdUaEzOOLH7jphFYLPOt1gUDU7WrlC6akkroPHbwrs8H71uIKd+SsMm4
# DATA 1jSKWsAe8ARb8C2gEqSeA8e50BeocwGWR9TPQuMFdbslz70n8HKYCasP7jlBDOuLX0EkmySTNxiz9MZCYTIGHya2IjQFz7Gkfi5M
# DATA UtuUjsldvk0/TURhBJgGAvWWSDlKakfmgnGuzqv90yRrDbsdlLGYF+d0RmettlVdH9EeB+oO3xoxgmNHVd45ydRXJyAd58etdv+h
# DATA izdbC2EWXL/Rxf9Ir9HFGT6jus//U7qMzkFzegDsNGoWwfMZXYx5jLqwpDY0CbuQuruhJgHCbl31COyuC28Qc9OqB9AN5lphbyT2
# DATA Se731B2s62d4iJGGoy2QD93+mPqKe0TLH9afEANGFG84qD1IJXJasXIdSFyKZsoQj8IBuf+u/QStoOqvnFxtv6Zn56MKPb6XRnph
# DATA hh4xdLsCQyQxlOW7OAXgQQ5E1yk2eApnSIgkZBe1H5vCpoJYrX9J4Ag+3uEQFAZYDCDmagZoKK4bUhTViUjnKwsTpxg+ZQoQhBsB
# DATA +NQdgC/71aPwEI54F/WEQA49tYSHJ2Jd2M0NLmwqlujNbyxaxmuuZHZakVLagq2gmmKysumrn/g5htGkPaMu4M4TjKaXyh8yJXeI
# DATA 51EuTnxTWNp1BP+ivHHq/PtMPf2jxM99RTKYB6SJjwxSrpP0w/cY7rWzRxUtCWZoGmxphOqZsDmxbDivJ9cuQA4c/M8Ux3ADG4Uu
# DATA 389e/EJywP6exqoeuOlr0QUHjDcRlBzJnVF3e1lJJB1FPQlTZnCGOpgEKHlCFpWl/tWlpUnhwD3UDtUnUYkiirc3JTaodyUhb4pG
# DATA 4IBfjvgRR3NqVCQ9VXGqCTviBZdc6zdUTbbThJDpbNeUQ3Y94Qon01wpbEm0KeeSAaSjc8nKBIr46UrcbTipMmbyPHHgipk10IvS
# DATA sgTUDVOwjBT1mCMf2Et1/Bz/RaTgRIsVeFMaWX5Ns2R1OwNpPk+A1ySQ3utUbqWERt4agrIRc6YSmjtWatUFs19L1jCBGAgL6rMc
# DATA Qd/RE6zbZkjrAQB2YCMsUaBH96gWh1kP5a1Z3u32XojLoYyg/Y3cuPzbli+rCuJ/OSgRQv3P75+vZalvzD8p7vVvhRhz+q81/EdR
# DATA m5M23Ul8Ze+weLXuvrMYASjF5B7eG3kgQpbYYsMUoEaDYAzcYZFKq93J8fZbsrDtLd2mZiiMaS/SLhCzjWav7QVx84IV0xWxIbA8
# DATA OduEoFX+nhvouSwPmidRo6xc4TLBEf8vYYZwhDj1vNA5VIznHz3yHUhtLwxKnYofmcT2RfLyr7TWBbvahL1U4h98AvSH7xNotass
# DATA nN98UuMqQMNnEJyiGkEu6agDdQe4B+liWuDLb2W9T3DmCFbpWWGSr0KJqVo1x1wBAio82NNmbn7Acumc80KHQZPOTB/aquI3DFur
# DATA JJOxmAysKfQzjSP3dVSW9NgCoqbAlbKv6JuerNyZYoTmdcBmnyaWCnD2FEdUKYSrEYfknS+XM4+3AC5DtqJ+baPjxnVKoggKB2tX
# DATA DSknTF3XA/nchjaGS+eHuJ9/aQXOcAIITxuKukmnx9RC8521H0a2wf8Vb/gpqZohty01qa6Rdj2OZuAMoYJOWgwLYItBFtcO5ECm
# DATA TPJPJh5aF7biwQR4bsqMeeu4AtQT7XRnLoPklkx/76brbSWEuRU79++62jJUxx5K/aNhy0IK2N2bTMl+XXfPeLjZdzb7Qwq7Gag/
# DATA DAATur9v3t1CiOgV9b/U9XPFCvgkVF3o5WqfnWhnqfiRyI6sjotUxQU3IISRNNWeiFGAElvc/FrnJ4Oyn+sUtPxNGB2l2N/EQ2IP
# DATA 46XmgjQsBE9nZpR6lw4Sh7UPYwzqKuYNw9di8D6En2elg/lmsjx74uou8yvHQb7QH8P1w5gUA7NNhWMrxdgpwXsF5AaPA3G5NMUB
# DATA tPyywFseL46AGIa9i30xDdUwcFd6WaTKKA7at4RT+R/l//uysKM6U4sr4IY5t0kf+zl4GGgz4W+e/7aSMMZaVO3pwDt9C9CB7LuM
# DATA G9112irC3zNXrr72rCzYXyWsfU68PssFXLuuV53y5rH1pXVXVd9rfodIfy4XnA7p55ZdKKAIkdYJes+0WH+JPTcTt/Qcuzx+xhOa
# DATA 91SCNu4pU0RSR98w7I+UvEPuiWov1aWKXfWD4pLVH2RZtQQwvEfwC/5gUlz3riVzICuEOzfIJPxpsVxSjqlpQtjqyJ6IYmDODFDe
# DATA RRN3zYqCaaTA4cAXpgHqAjOmgpJ70QZtYKZI7aC10guBNzIytR/ixh0RL413eu8cAxQzHSycDIi8L3idK8YZQ/dHDmFZcRZ4VMUx
# DATA /RRaafnLc8792YUL6lEluXBB1zAJM6dXnO3oAGWpr0uqr4MuuvMfq5OCJAv4qwn05kqkuRFGpSyYgPuws0ryRIycef6Q8ooTyF5e
# DATA I4iy4+xR6dJKeUHnPkDxKgbL532hSHzz7vbOW1tr283N1e3t9+5u3UIFPzXkBUlYhe9tr21hrIR1KOqXt264r/xaPAzBQ+s4rS8u
# DATA yo/6mXRj8jeGSbf361cuX1pZLK79za27GzvNtY1bzVt376yuQ5R+ejwaDXJVN5CaWZF0c3Vj7bYppt/4VW7fu9HcvHfj9vpNU9gR
# DATA pMbDbl5yVtWsPGyt3Wt1uEy9/d76LdWz1Ru311Tv1t5cvXcblkZJGeMsHMidtZ2t9Ztmrlvtkw76ksgLWLHoyq5cLge1vbd24+27
# DATA d99hgmi+vbZ6C6uN0gUr5NVGhQBFJmYtKbtblAguFJIHrdEoG/Ywzu5HMPHDrIYo1Bns/DIGxzVqF76bunKbpIfkzyvYCzA61u54
# DATA bJS7B5+M9015zt/XrCcBg5HKDruto7yBVU7JX4v1X2wgjqqqIWRXF/GVzRzgE2YGCPQAvIAmGAM79zNxwKMfcinmV26cI+Y/EpRX
# DATA PyUS/H41vT+83wN411fP5daHuKRar3EdvHg4GxTrPs0Jy0mkbOR1wGOHP8iUyJKbY7oZtE7BcK0GB9aGGvwNxqs8u3q5tn/1MhvT
# DATA ZFoE9okCihxH6UjyN64bT9r3yy5KDr/bfZ8FBnbEat3MhqPN7AR2zo8fjjbH+4pvv8OI9Kon1mv4qd7ALx8wl7xe34V1J2dXx7ZQ
# DATA Mi8qyc7pgP4MVsWe2E9Bs8d+johRLCkWH2MCAdL8GQC5x4AYA8iwP0WH4o+eP0OdNKlnEanpWTyvKVPm4atasGmcEb1N7vdMhxrp
# DATA GQO3Kpp+lWn4YaszIsQSZKAlCVHrnGT98aixsmRCiq1IAYx1V+zgDqKPUAihWr12q6skyTQKLBKefKw/grpu4RPBeHB3jlUMmiRd
# DATA E/v0qHXtHMIRnU1J2IWh9apkvghGtYNj1VJtoNZfK7lMLQGgBBDdUvJ9p4xnqv9+I1m+tLz02kp0g/4enQrAi+Ax3P3cRDfRlX6c
# DATA vL2zs7ldNTA6OuCtxynv7d4YIzDrsrLWIbNMScJbhf/dWHtrfSO5uba1s/7m+s3VnTV8WrvwBv6rztLgXWrl1lbVbTvMC5oJBvy7
# DATA cDjBYPjKamnLRZ/7aCD3Ay9LeJ53a5trd5ow7Oaor47VLfy7BJ1QR2+5XJNk4Wai8OCALynJd5NRLpr8snTQQisa3BCs6Sw7NdQY
# DATA fgcPk+QDqu/dta31N3/Y/MGVpe+p41lN2ert5s23lcTgfKnO8c7J+MRKxQvf7tzeZnd6+PPBcnOFPcVbbUVzQMSw8WonfTXF4PtW
# DATA gjOU9yKZnI7BlBIU+r6uwsJSCZDVOqPjJAft2kgmRfW2ByZ2dUMopcsrr9WW1P8tp/okM4xAjae0AmHpj0q15Ypurup3BRLltnLF
# DATA Sx9G0oJDB2SCHg5bgyb1pqRKk1ouGzaFTzS0cAX1KcY1HhYJ+ookfYqh4sCsBlk2RGLZV7f0oVrL/vCEDyJNNcDAhPzqhdcqA3JP
# DATA GIsfgn+cg3YF9kWIBvm5pCexgSvVgldpwyN8/U/TcsGthbqeZ8BOu6XD9K21HcXCYB8tLteWQSB4W01NPTmTGZrAs5t6KdXNugvu
# DATA AiA5qP8P+dvwOC6Xi2ZvZWkJ2FgHdT/UvGKfD0pXlldET1feXd4DOru8tFQ8Qxa7t0/Ou9t8bNpH6Do4DPlnqFyBDBEDeeXdLBuU
# DATA anz7oWVw2YqdyJjX4EPEmP5TYqFffklJMV98cl2UahS684nkWcY1rUTZMiZO/3dKKgO2UhT+qqRqFGs+/uI8eCVzB8k74Fugji3b
# DATA ZD/zIogyjHqbpnj2Sh067Bov74cpJSAAOKBkCXfvkrpU4bEpX5QnwHqu3+9ZRXfr9b3Cco64e5imKe3M5Oxswapi3Os8qi8+aA0X
# DATA 1b5b1ErsxeG4t4gTUYPNDVUmqHJtwl27f9DvXl84o8FN5JKudj1OhSHo62QlybtN+4iPtDbqeqd69MsmCPYFXw+GnQfqtfut9DVP
# DATA kE3XVvjfS1QERKWVpN+7vmANAW9XedI/PLzONhB1TC6O8+GiYkrDjCZl8Xh00qX3rfGoj15z5pMMtkMTgSYvL11OFtV/atYH7ba6
# DATA vLXaail+UL1JJ3MVJNHqXbqQKprMe51DJVV3H7ZO8+CrLQBMGWbD6mZfTf8pSNadgxF78lUfHme96sGwn+f8xKmm2ydFSPKjf0gW
# DATA H8EEgLfMohAFHn3dDgTrqSOiud9vn5J0tHRdvz8aDg6aJK7QoZJcWlrKvffA9qa9B+6Af6mr/jQSxC4iCVIFk4k7DDWK+/drpTde
# DATA eZh1u1XEdVgsq9Gok613Cn7O14NPYLBwqpJXQvLd8bCD/1lMGmqhsLz6f2q/KHZAaof1zXevNjfWdt67u/UObGXdxWZn8OBqMwPt
# DATA Rp7ahW/e3Xhz/S1Q7WDbaVtRJ1p30/1hp03wF1mvtd/NoIrL6gUGrzlPIc0hHHAVu4pmf4Aw82e2ja2XjUApXaO6a0dqq6gVR3dL
# DATA qSjttUbphKvSEbZnruEKylZ5NOqTZfjAhZbH8TJnFAOvm4ec+t+uiGHcZpZzmHB5KJZF1UY2k7dugms/6zgXCgAb6MRZ33xwtU5Z
# DATA DMifSG5zzygdGeaIY7RkBvrUbg1k4fFsraoHETIBSy93xHJOB7dZcjWSl7vht3teZHh/IGZZ+Z5ubzZFRLI8lWKlgfCYBOm+xz/Q
# DATA 4uOUt8lThxIb9Bj7f1O+vWq+BVqOFH0EuqBWl0bgvsNEa/gu1qQ3vtl2WZu8afDLaaxinu/AlD1zm1Vom1Hd8NfXqF1PoWLE+U/G
# DATA GTj9k5lzLEuHf0ZnRtzyMDedM0sCBs8FLiZpE7RkIRESLPzsYlGfIt5jzxB1l2a8yvvnmfj3B05T2lBqS9sFoSNPtS/8eXKd6jwi
# DATA RTi0sGu+DWP/bMgEp1UmBaQs31EAjULIYous0zT5dh0JJmR5CnkT6T4DkjQF6n4iFmxLkIaQ4QL/LnZIeSqZM7968TOO9MZY8Fm2
# DATA 6tZo1ALTrQ+qpfl6uSBNnXwYNdJZtZJFEgVryxIpBRz2qL+yAJBMTaqqSXErKZ9IKbU1mZJV1vS8MKns7BMJnfFiGb2Mt6w7dVES
# DATA yU/zg1GIaMaPgyMkYjylkoWWUtMApgzEcJAwY6CAx3LpwJANumTPc17Rx31k3/fRo/R+rXbxvrr15+aUqSRoqUAL/2goYJPAJZfS
# DATA 2D03NI5wd8Q6Up62vWgH8Uow1LgefejGgQkZ/Axf2ulDQm9taPFgK+n+ijBgkXVo0LFmE7YA+BUHnDt+/Q+2bCiEnE0wtlf6Yd9j
# DATA cdn5Tcx1oKNuJCPwKHIOQXmuFnEp/EqO2aKvjx42p1cQ7kkpD4HnIyR7Xfn3k6VIii6/D+bDoHeqgvjMnmOv/9H0p9DZVY7TmGxE
# DATA 07NrJhas5aDyW67omqd8Zs+o9aU/1LAGIUhyBdHrNIUsDSONzpmcC84lQD4xd4Cg/ZhMjbFyMqx6sqRkKXug6slkwXFLiAj17Mog
# DATA 7cxK6hrYKfWOBXeeiDC1EKHbeGNRiiJJCrKqKbJ6jHGEaKB6ijq0L4mGKEGhJFR+yiaskGXFMizrcxqmUzq2UHTmxFYvHHTFuw0G
# DATA t+iy5Sc+/aJF/k4wZ+oIcaYr/l2pQAhhaQ+ZruVlGoqPNbKoO6eFHvW0Nea1dTpuOiB0RhfjupcHj3zBPJHJcXkJr+yAoNztHB2P
# DATA 5GpQ4eOqCeqtBkedgLfdonq+qCpfhO8WoQfgGtVuZSd9ykQghbPRwSJdXRbpLUcw81RAB/rj0WA8KrWGR2Nw2rEjLgKrBnv6kd8r
# DATA /6gNxz3zNSAJDNQosybVi9p/8hOQP9nIsXylXKy8tqrfofJrjwaQmm+GbGZ2FWifP3ElZtpocEXS3QWDlotFwWPClQJN/rfYniBQ
# DATA c5v5qK3GWQNF4aBUXtALRDRQwnv2YQtCEUCKCjIkWaSSLCa6tPpbFfdlXxdcZ8oY467s1BYOzTSk7p81duwIx6hjgMl66o6S5clw
# DATA oKkjPoqoyIHg0i7wiLTVJYQXPnbKUY1SRCLEPCs/I1vF86fXZWQk9TmJasxV9mFr2Cb9EPdYWjfvZMOrBUXnMctzg/fbbtoZwDfV
# DATA H+N/US+BxdHp9rj/0B6OBPfr+nbxL5wI+gs4H71EPOKxOA+0M8BjB85lPcQkA6r6MSB+5Ix+qn85AVtUaaF6zp68ImLhQVBVlkLA
# DATA 67gVDqCXtkHvdnEYez4RF6dxqtX/pgrA48tXADte1/fyF7s/Jng2f4S2qn+kXM7RgYmmYE5SLupQAaWGnVDTPqUb1pqLlYVys5fS
# DATA YUvNzPeINCyaJoUbXdHCMbQOgE831bc0gJW0eEa3VquYsOjDF79AeK2PfAVHLyNtH94WayEv0Y01Vuw8y7fwOLP6PN+mRUQ7NaxK
# DATA wt4COA1qG9LxmFpx9LAfq2C6boH8mp6d1bbR6lRjd4LJBMLuSyvXKiCgLpUD50A/NMVuhGMAgvbUlh+OqN5KcukSXMRtJmaB5gu9
# DATA /+jBG6X77Yvl+zX7H1UbcxgecAjkSnUBlLSbKgGf144U0QxAWgILNM9V0SpXMXEb6Q795eV1WgNTXJasXLsIVl2J2l6pXbpUW75o
# DATA lPOW7BI7l+i1y0jtT6yjxc1FTkIPaQQHV0ewA3PSdqOWvJh8ufv6o2BHXk82VneY5v6AiZUf4+a0UiqLSIZC1xTyjHT2UAk7D9Wx
# DATA UhUgdeLRvUMeQnzfFg9HPky4vkDb+JkMgRLT24qQpxon8Fybji3u0ZDuKcpq/S2cc/qwNBuIZWr4s5tH9uoG2LQnAPaIWi1wnMmt
# DATA 6G7WQmMDUZtP7KiOtt7p5eDFkhK4qjqi7ZgpHeXoavYLYIWLjEdsa57DcHSLDEczzEVrePsDinAtPrONRfpL384UFl2fahA6D9Qx
# DATA /3iJamSZsJoCGvv/skFpiiRTaBJwTDxwV/kScQqBV33BxTlPPMe9vQSC2fXEqd5LmIsKU8GXJURIyRgKM+mnboApjnrExvNHwzSj
# DATA IYUv5kosH4/6MHt0xvYPD9MCQzOyQpD4vkBPEXWE9mQW1FfoXIzc8GOQQ8DB+CMb3PFTCCGM+Qp78boxFC92oXVSuFWSC9NR7iGR
# DATA skH5xzHD4QADrIc3r/lcAti1wQfDi/qjRzQW8e9eoh+kJIhXJ2qCmzacaMTdTasRtOt4JXknOyUHOPBwRN8fJ/7YTGIvjXmqh02W
# DATA wISRUZWuBSajFsNPGC/O3K1/oYjs92hm0DN5PSmGFIzvKIJQcjJfK3EoJz/Yb6WPqY0s2RuVuDkQ2pNVtX/q03EnyMDs2SVf/LKm
# DATA Nim5CZ+iMkR1MaCiuE8KsZRDxd6OSzFEH21K15AG2vE11f63jfTS0tISmd0fnTZ0iDP665PbIJb2g80KABG8x+iSqFpYxhZwLyjW
# DATA 38QYpAbvPWzJPKWdQAlOwW8QwdrSPOseAg5vN7XfUfWXL1+Sp53efn/ca/OLa/DGzldm12n4pV23HWMQD4cBQnzCS8y+9oaNuj7o
# DATA GBmTlhdmRcG6/Wq4kQ5acWytSNCx3xIv9m3ngKcacY43yNifInQ95xD+RrpruqZDCHfRCTQGks0hS/6SRhYzRCQGNG1qguC0L0UB
# DATA ZP6Nnah/maxurlec9YE09Ywo8zj5wbB1aqJpvmQQbTRT/JxiaSxYmM6hT8uRfFc+NI6AkCLWMUCOK6GsuXrrzvqGGxk136lrgEwj
# DATA B7BBiQow5oPU2EXAU8WhZd3+0RHdGc4s30G4PxCWEMgcAwGBOVNn/KMquGlCoUtLGCAFj7CoenQlZR9IuLf3JecX5pCD1+NeF6S3
# DATA fNQfDDJMDcrNQw4O+iuIUSx0IRSgQYZmaNuYOpOgmnG3c9Jhh8Zen/t7lub9Q+jZ8tLla1deu6o6dKyuhubBZDKZDypJnf/ijEBD
# DATA Zy7dYF6d9R4QCBtCT5klXUzA2/5BWt6L6l9gufLG7qEJtahLoFYdOX38M87L2thlGIoqhU2Q6ys4uxp0CoK3y+uLapUX1SgW+UFB
# DATA ze0MMAbyZr/XsNET2vvsKdprY/g45lfjdCzHihePjk/TiQOsQKgYsz+aRLtBrzE9qurHSFEYwBClN+/cqm6/vXb7NiqpxsNuUj3M
# DATA t9H7ur64CH65XTg0YeqWF6kOBJ9EnZ2aE/RFXcILOVt4kKhzwoQYDSnR61U6WIaj5iAbdvpt2gu5jRAR8pQAtwGiEAfqXZui+1PN
# DATA QCwdcbs1akGQZJy0dIh0fflaDa5wL0lkZHk9PkH/60Z6ZXnlZJ9qkyB4Ncc7fwfDvLdzE9bR0Jf00HhVWzAoU5qbZwEHR81ODkqx
# DATA 06R6L/nud8+cSPNJUm07D2/dmASLeWnWWq4sTWz5TNFkwVzTjuGNU/9etdUddHrAHufda0WTwRpO63vU07JCVW0V+It+EcAHqCsp
# DATA MJWeKv57kp2oda4O0Euf3mVqG420YhYc36lf8NvrGv+Dvu9+cUXhyORfe+01egUcCf5aKhxQ8dIaXJzqQRdRWqr5HP0ZwAHx9VbW
# DATA gs+y2JYqpabUYUvIyISoowwL/3W0WKHo7HnD2e9J5CsGBij+EoN5JMTVfxE4dEQ+bYgYAM4GwWvAw7m2VEmUlD0phCNiAcyRvMjg
# DATA RA5ln7PIo6OYY3IXPtTRUxSo7MhMz0jMTaMoNvmuDc8TOMDuxfdvuEYh9ZKk0Ti7cIG+3RXZA2mv0BU3mko0cmxN4c7298KpQZo7
# DATA JABc531s38XEhGCFQWJYjm7b+KH+cofz9N1PGV3Vvg+hLVhOO8zAMPQqH9lmPND3RXHT57P71XJtdKwuD8PG6+J/kD3qqKt8rf/+
# DATA G0v15XK5doB2plLZK6FeFfEvh8tcmcVlllciwsCKKwzwCSFZFgH42EsMIwzHYpCGW2uBbOI5eTwixza649cL9gq9LdgV9La+Yk4z
# DATA 99B/6+6ttRv33oIxnYy7ow6YqUYHg8YSCAFMdOm1pfo1UAjAzb1Ot3f5c3HcHkyTAuJCa7A9bkIvCdkU9DN19AjCri/qV/UhHof4
# DATA tArzWV+E/5pn7OK0SP/ayj2rcQGgPrMqQqRqrxofvVrHG51R3INB60xsxGv5E5aZGgS8c/rL8gkEeE28auvViyw4qbh29yzrKsJK
# DATA Whs4kuzGKYS7ce4rjO3n30jhwHp5kZNF34Yj9mqtjrmI8xgrU4hDyQ1CFtHAvrSSBN+ou2bufNQ/WszHA1gdRICLdTlk2qDeXYR5
# DATA EMEr1g3meAVfH/SHmYYWjH2OadWdUntxqQYVSbCGMTryvE4imic8Biis2HpfDi8tQrd7AjcXjAyRM4qXZNTNYa8Wne1WlHQR08K3
# DATA 9eXayjXDt2LEuXA+LkMxyOSHaNgMBeGid0d7kb1UsBAynOmc7SWn5ry1zt4B56zw4cOHUmEsGhn66LFPi2XZC/iy/HHyTYAoGzXZ
# DATA bBjlAEc5JI9Iyi2Q0jykZfjlV+0jKSMwbgRGmSaRpSQGuKnb29WvGFUMuqAGCChQVrFNhMExH53SXDw6DbtL8Mz1RPS5af9hL2tb
# DATA PUUjoCxWeU4VGZvDbLn03rCbhwi0U4HTznXxsnNKnDktb1JiYDJPuG9o7IH4PG0TORXsQFj/vXGnzXQ4Vn/W4D+XS+WyF0cQzXUl
# DATA nHXqPSeWyc4Zr4241HC1/KSRF2ykBumEHZ19mYqsk87eK+Vo8ssxHEQbpxuIQvEPBy9W0ke1DkdAX61ut//QNyWxvabfbQN3f+jh
# DATA hlINZUdgLWF1ZRuSDsRrVYNjJUXVAkjsOcDLlAi3HnbF376303QwC+HH1tqtdfoLgfpsqD34WxD0ILO6afLMhTNU5W6tb63d3JFf
# DATA ARxhJYYnCA8Nrqn65cCQumC5IbywGjZFx7wCIeAPCR0tOy2MNnv+f2qb7LPnf2IgYfan+gLdIT6MRm9QrhLtL32iSIPSfRHk3oHa
# DATA BIpOsnZpt3RCvgBg0AZXf/653R8PD+wHtzJwxMHdYD3dei/l3Azo9cgw4XewOTUf6E4gFNOkXiDhNHWP6A9DOvzbohoIrFF3egCi
# DATA Tvc7vTYLbmh16ec1pjXuz9qdjdWb97Z3mlt37+KKoApdn7yqt8Y8g4c/VY6Zx1HbZZLzyCvJM20lEMT+sHHTjIwtVPQW41JknHZ4
# DATA iDwDzUX/QVbiD6j67yR3we8Rkh+NjodZZtKkVgfdFmTv5gOYWzxpnSb7GaCDZO1asoYZlQTKmCvEkhg80drvdDF6jbFNCaUQ7Y0k
# DATA qClWgXow4LMY+D3qM6fo5JJd1WRLoTX6usDw0RQqMtXSGAayh4xmar4I9NkZ93CN8Gg0Ux/GVOuS1mpKBQC4i75vQHvm6aU9288t
# DATA Aq0cC6WUpnZX9oR+kH8orrGz1iR+dHdrfW17zvpy3KZig6Sqlz0xcJh1W5wRkYqbHVCTd81RnzaUJLmwU6/Aoe5/2Mmbc32L4o3j
# DATA QaLxQ7lXsLZgbJYHCHeco1PqCoUXuM74dv4sFGtxQ1R3W9VDTKJ1aQU8893aIDiG63IeL+9BM/EV2JWF2gvXItzF+EvTrUVFxOgD
# DATA PhBj75h/5RMyRqO3XHFYnqup2qDte4f1eCAZ3FDECqnW4PfN1mC13ea/bg37GB2yOew8UGI1mGj3nJPYO/cNiDg6coR1eZtJ8Rn7
# DATA oBEk8Xpyhhh9rUFZyULqUo/EB1MHvj+dR6rmVXXgc+aHFqbpKXl5PAAvLWA0GrBenTVu8DosAvSGDhzuF/xjDhv8ZR01Edh3GTHz
# DATA SamooatPPlCShVGYTObnBHYTOJXFbVTP3Yaq304vPmXuFIVanLy4YNT5I5RPTAUkhNAFYWEhvssMRlLBNbmOV2lQ9vKNOY2ocgA4
# DATA 2lL5RAuGShtMg2n9ttCO1FlLcKrIXGLJbMxFtn5OhxCOldDvnVxgVjV+PbVW7+A4glUbpgaLwpV6CcJefMxYwuTmgjYi1z+JtZKl
# DATA c2bTKc+fQs5OiFOch3jmeCFWzMmSoxNBkSdPAFTyTB7CDHz14tcOa8Uwx0ZiqxlKafzMAfK2L5K14+wRO/0oAkIlybTUTjO0I9AR
# DATA fg5/llHLMug4yZ2AW1J+2opm0vGNFqJEYMpCEuXorHNlJm/ZbZke1o5axcwS8CZySUh03+ybXUFpMKejdmsxdf3QpJf1WHA8QBNI
# DATA AQxebfC5g63UUa6gY9xpDKBm5fpCfsHFF7B/cXdNQDUWtTkALRhaF/MrU68+cq9pNEkzsHO0pMdhuLDaQQZYC9mIEj3ZwAmiJMYl
# DATA FHXGGYVs1hO5WqXUEBMe/QDSo06qx/SHpTIBWt8V0twzFeuKhEBNHVbVE0dXAXUpHnzQBXzADdCHwEbbaQ3Xe4d9yMSMCWD5txVq
# DATA 3kTlR6akrmzUAvtQCTxOKwlAJytxz44876v7lJpG1ZHWSHWDS6jeNQ2un9RCeYURVwRSf6oqa+CO4yI38cPk9QRTPV9YQcLHZtSj
# DATA q8kFeR47QGGMfKXjniTSODqlZ+0cb4N56zBL0FvOUtLzF7XCngMSMXTEhHwDJibALz4qnCAcUDifUtD3m0YLjWJ9pmJd0mv0qDfu
# DATA 9ntH307DUnlR47kS+POssG1GfcdCnEqSchGPoJ0B6krwSm+W66RzNGROx1IDqooPRpbg0OSWwB6TtU4qeivA6jRxORsrmkAuVSh5
# DATA C79YXlL/4z6++uqrN2BiEsIAJVVDt3/UOVBUhsRCwh4mwsVkxz11dwfCQd918KZ/AJ1W3chqqjIrC7zIKzYXkk1ygIdBI1la0MDP
# DATA sgf7apeX4K/+/o8bMjwy9Aw/SHGkHbVHG/4mxigJnhbvtp6hHwxcOfzXxOOgLxcbybKHMzxEPRJdgLEKypdMV7wwTRLU8ro90bBd
# DATA w6+VUNbaV2LbeJSRZJbWaimlix6O8qLj4l4PN2ov3NWIpaDT82A30ijgC/eik5NMKK7p+jEnM9UTph4xcZen9EoTcS/GcKCesDdc
# DATA P8HjEzCS/eh1i4rVBQVppqgHFpsLuJreSAn6MLvdaJtjG5gZiRM/7nd6MJ+lC6QriE2j9aGvrGBKn6OvMkOUDUVxAEVqbVvGKZgy
# DATA XrwoIpc1hdOQou71NJK+EUUlYYfLibiXkahIexJO3oc+4Q5d6r+2tATBIpBMK+dwEAy1bPbfJ1T1+S6xxCfUnrQGVbR8NWru6/QD
# DATA jtvj8ajTBfC395vjXF3bZDVrh6Au/b5DoReTq5eLjl8rUE/tjsPDzgHAHkMq7/eRySox64QQgLwNbfP9qCpOTmU+DnC/Uq/C0dA3
# DATA DKJ2DoKUJBLqyxO1/w0uiPzvO5BFvTvOsTBkCYANNBhmD2Cmk/aYTFuy93OK9AJJWg4QMlvFMg9AlyvOyuJZkD7aT5G5U2xzfSox
# DATA HhwrAijh+lt7AoNd/jpZ6i8vL5PmcKl/dSmC6UZ6arq7FJGeybOgS8f3234XEM4t5WirXYI8CfqzSnL1ypVLV4uB94HfYC2zsg5E
# DATA VvKhmrHRcNyD1WgXJBOgGa1RkntsKF7OTEu1gXefgrJc36Gij+NS5HVeO8xPewclKacmsdcvuVZFPMG0NXFwGpN6LHWJkI3De9Xf
# DATA 5J5ggVgMUkvNgu4OcEXijQL3wxq6KrIbQxQ2ahPpESoHSxFAHzXst+uba/g8Gw795yz9dE4wLAcsMC3QoiJS1LC0DJ64Uvz9Trdr
# DATA Fa9pHAkd9U7P8eorOYggDFIV0fpwJ/o1wMSaIk+6yE6V4ArJ8axr+A9sfUVlQILjocdlpEv8MobJhUO1yMRDlcIsFdbrdqd11Our
# DATA rX6QE0aDFFZN0eZavnrp2uVyjdNLpePRYfUaeK1BV3IlPmbqFnhgH2deJX6L2o9FykE2pJKV+8g42hGvBF+7m/1xt82Z45WIhaIy
# DATA MAuU8ewxIGAN82nnjQO4itPI9iAExNRyGzU5Z+RverPVw0uHOnS6p7ixrLPnurbtWVtEMXUMTmhLvC72JbwtaUIHpJRuprjNJj3g
# DATA nSJuAuCLYo2S7Q3QaNcmViTuA4j4tWnDAjob9IFq4mdbAWXZr4I1JFaT91qD/Lhvb4oSKA1U/8e9hosdR9CCVKhRwKPs0NWRp8qI
# DATA JsD6TrKacKickMVJ6311X6QDE2L0wLTaJdENs9V0MqKin4yVuKTqOsg6A7AWc30H/eMMk7DK2GrJlpo78DBO3s+yAYnKkZXvtk7V
# DATA fxUb7o8RVZJGQtghCFQM+Hk2czW4IjJQUU7u7anJQvdwEsLmhdqTzWU65cCc6M4ws9BAJmxGt/SL621G5vB7liDCklMW75O2Bnpr
# DATA 3OuhDBToiv9NoztpoCfMHwMmtqg27ytHLf6M4MfAMEdhrIScyTq/j4uCQWkQdvYyzwbASmarMGp797RqHH4GaczwIYvRxovhFVtZ
# DATA zeC1L2czheo9U8/sJIW2etSb48fT9KWWuj1yJ9C3AMv3wkaPLtqprpwBOZXVB7uii1RUjlNOD1kd6eI08p6eapw3mm2YfFbIFliR
# DATA qb69qPGscFb/jFB3n8wxfUaPE0xi2VIPq2lqc+INi2k6+yyQ0VwtPNRQCF75HQa1SnNzZe61B+qajjcquFCMO/kx8sGktZ8Dt+tm
# DATA Ry3MXiMJS01lhpzxQCPRahGi3uAwVX/iLY1FlryWbGSQ2Ch/iKZr5JZdzDFa8+9bU059bYbCgZKkgTFZDj04rwttBv8awnc6Nqhn
# DATA 0cUlq5ak+vwzQx7Ai2iG+emgX3ENnuwiVEaB64DoIy8wDQ2Puv39UnohLXsUC7o8kLAAEq1LqRP9yRWEtSDzYkneaCunC8ZWnjaR
# DATA U6ETEVjozzoTI9j+noTz+iy2aaaoFLVWAwatE0RaI2QVHN1QizSMqL61TQGWordwwL8rJAmhiCcvfvniF5KYLpqWEmgMiQJ9A12G
# DATA 7E0ADsi7iweLJbMw9XYOhnRMa/NoVCrFeOwU7o0AMg6bRq+IWeb7cgUlS8svb0hidwn/knAOxiWu4YniGEDFlR1kleg3zp4hmQ7u
# DATA UrBxGEjKAlMC5UqnP87TsvNYcTJQq5wGO4oSGYKB3dRsG9DpfVxHTO/m9DThjIkM5ku/uMvqEVleXaUd5lP0ylJKxkjpAshUES2u
# DATA Xp7ghQKqnL7RvZMQkcWE7yESGEGuUA4SxV6/ICepJ4D2wYxVAFnU7vkUHoVddSYDiAxiKRCDYFG9Wnw0bJ0yRqksCg2fcrHgJ/vj
# DATA XrsLyBZzO/rYjb4ym7Ix+TnNWOGE/bM36qcy5q8IYZGk1WeSU+cJQUpbh5AqTrmuYL5cMe75YwRbg2p+js9klgV7mo63P2NFT8Co
# DATA bdJmMcDbExfi0elgnH5kAzKlWGxWbQr4q8lJQd1yJP1Onap/nQtM25mb32hcSjVoBKqDhJFe1l9DYxprup+j/Ex4fXZWA7g1orpN
# DATA iWEocHQghYeldwbHu2TQfwjXun6eqwsY6Bryg9aQrA697KFVGd0BLBeiBJNl58co0Tw87qsW5DYplsFW7zRh1Qr40NYshQ3V0iEk
# DATA IQvbCiRbgIxDwrXlBhTajawQHBuWC4f9GfucWw06ThsINUROG/gne4KCagIAbTnxeN03MGAIBiqx1PSj6g/aq8Cvu82tW3c3bv8w
# DATA +YB+iWCuH2zcffPu7dt333NJchTjrVorapr0crT4OhLrS1JZ2V9y3m5Q6TbVRV5djiVpN2OP1YOL4tdydmd7+KDbPz2h9NNFiba9
# DATA b05aw/fxXp9uScXJ//Phb1HOkBRexkMV9ppIY2qDSRpSiUil7EMiPHoJFopdwHSiBddirFMJ2XkcpCnyc3FXg1Cx6FJoHYE+hB28
# DATA 5oRNJOjAA59pEbWGUf90zOLkEh5XIeZAXmu1KVSTNojZRJblmRLrmHVbxEIGo7HkvOP43hjQcdhq7EvGnwJoW/QLw8VXlPX8X9Ap
# DATA GVabQPU+It8lph8T/gdubc//h6IAQOD6uVxerNNFvrPb93GuMR6OcZIZ2LmuHl3YTRP8OmBIdjckXnBvL1YrJH52EjE9g1yPnyPy
# DATA qAmfmd4YsTE9oeU9B9hePzdzT/N5EUwdiR3IANcVFMy/lMzGz7+QAVf1Pnp63YOdw4MI1ksugfFUejU2klitwwzgh7iDf4rj/iVg
# DATA t1knWy0RrDs8JVWpLxB//0PS5wimyOOwXcAeeaoYeJ5Uu60gwJUdN/+sCv4epATVOH+CY6loCO8XP0UwR+gcQjpCqBMCkLBD/BMk
# DATA py8pK5rkQ3tWCxtMiRbhjkT5uvU3mN2TKyX07ceGosnfEvaEoDyUw7H8HyaJtLqcud60iEipqgwrpBj3sDbo5FMiS98zVxFnWM8w
# DATA O1K3GbgexAdNuxWqUFfHenLQjm469TAh7XDCOycZYMQAmhKZ18PWGqsVrZpA0vjG34tEJhiQiEoEUEXjaFQhH/DD/rBdGz1CeA0r
# DATA 7LsiEdoVCqqu8CxW+K4Gf0BstBvF4DI3cukJb4B6d4jXIvYcjI6R+ZJ6ytq1bEBCF8sbbJMv1xd8pYg0TLfTQj2JhzeP+d47vaMG
# DATA W8jKjhstMmZfdUKgqahGULcDO98TbPA312+vbcMMB8KuGa51uBSkgycrtDtkk+tczYZ7rOhGYZ0gjT0475Rw0tHf977csymJ9vQz
# DATA 58UvK8B1fqZZBcC9MttCPMkYI0/TPTtVA9MwkidFQwsEjmPwUdeMtvG2NRsO3MFNLQBM6+kKMLYJvrauMGIMNC/04nuGQWwmG6K2
# DATA FvUS9Il3ZcKpAobu9IRW0VThiHVFkdJqr6OP84eIG2XLboYoUJgpqLfsLnJhxgo8TuUsx5pJGHPASk0bFhy3nOcUTrrny2Gze1cs
# DATA E4UTCtPx310qgiNt7plgfBVPy3ZE6Wfdwdns8E6BUxFykKNsVo9/R8cz0vw/ReC/6izIHGVz0cR0urBwxryJCRqYlzh8AgmaiNAK
# DATA NeZJfGan8w424lpwdi4G8fvqaK7xpVayme3WL624J8vMPRxogXj9o9uZF5goYtyTcN92OqtSiwCCcZxjueeh9/iyEqXH6pxrq5tR
# DATA F25ya4gW5NYiyq62DPdn0mD5Z8XHjD/8IWqncGiU1v2pziP9LJQZpZXvhzW+vkg2K4abql5YZDEa6BQEaU+2jOeuflYBbZTW3dFX
# DATA z55/Rop7ujU9jWrlws6CIMTz8e9zyKOEksbUL5f4aYInpRXC+HQ97Y+pEZjK33PJP+moKgcpORRzf2ddOJ7yDeaJ6tunCAcNA6dc
# DATA uHyFwJuImSW+EIqJXon9ot2Mau+UmCChtC9+VjPJx5APgNpQyylWBgKWYYRXxKUXJEwjvZAqB2GaeNeiP/YQfUGP8O/aKufp28Q3
# DATA WhOkdmyj2VQyeLNZtr6EK3pTUvuV0v4gG0qY1MFxH/QiDcb0AUg+lIVBWdhniNLRsNXLIXUNwsqAjFNlcRu/sf8m0BnIMAdxApJG
# DATA qjUU1LtOm0XsI8K9I/6VIiZzflyl3cIppzqHp9YDhysBekzwkFE3g+fcP/RHqY4HR5KqBBCnOqOqlecKUKxBcW49EtS+qpVPB8xN
# DATA lt8DNsjaUe+xOFPZXhJDdsbRNdGMQkNV7oA9WQWvufPxlzIOeutMxgiAa/RyGRQHs7SSKoa0iOLOECWkapUtbOXrRQXYYFdcQJyI
# DATA pjZjroU2xXridnEb5qyZ2opO6VPc2ROE5Sl8Twtf/J4Ji6DUp/YFUEfzKTUN2UUJ4jSHR3kD9OZTx6YobVrHxkMwAZjVKCxpqZv0
# DATA 6k9r2OwbjhxspDN6ilSoPqsiYID6sIWGs0aKRN2ktEJTm0R0sv7XrwOgkqonBINgyK4o+cSeNURTZs5WGHJZV4B5MK5P/Y4hmoJP
# DATA KYfGtGaJU7pLUtiWXz1C0k9nChFWPefiO5/Sbpuvl67QGnR5eWnm1sdzy6yyZFVJJWeYs770dvbanmumAUG8+K0kYSzbvu5cFv+B
# DATA 0lYCOfhV00e9QWsjBl/gtoAf4ZOyFw2Mzj+RVFjWZxLcy4YnfAhgWRDthhmuyp7Wx/pM26l8KDlsah26DBhyBZm3IwHLsXxVewWp
# DATA uaPdsjwyyl4aIcp8ytkkbRmVrielFBEQdNx2qrOCucMhrD60hYva+Sl4XVkZyiOLaMlpZhHBvZnckfFNyV/M6VXyUV9350HsiH5d
# DATA lSRY8zl6bIka9ZC0ghp9/FNNfs4i+13z19uyVmE2eRChIX/zXNAxCFBjUFIUK1i9fduFlHEshZLqAe+cSFrO64FByEE3diedoUwc
# DATA bBeYMuqvySTE/Y8CQDtR+U4nNMigGUUUkpXSVLQBMwbzVMDopo2yTaA/DN0w32yCD0Ms/cWc3MBdRGfueE+eQrJRiJ3gUrS7ev10
# DATA OnHa9w4zvfSgCS8zimioGTCNqfX5l4NzETvjfBThxbB01lTSBn3PD8rMbL0uzjm1VhHx34QOTB9m7MJjnSmRsIpzMo2pVyfrhs3F
# DATA 7FgMKeYO+zyL6N4VrQxAuWps1OQXTT6S89ghGHJN/MGfmNNxNnC6qUmWW7MLfkC0Xpoxo9591yZMeNHkF87xN2UGiwY0vRP+Fdu2
# DATA kZBs7nTjPJsuchf2N7R4UhTtFnv/kYyD4Bdc3XzLjE+4Oe0AythZpAWueNYXs6nNZyZExf2U1z1MbmE6glfHcoRb8CWvabiG+ci6
# DATA 1jWd/Rn4eE8bWiWZNQLPa5U8dzu9wXjkgL2gH03dmBDhpkUeo3XHew9fxgU4CuMynGwKq8PABSthQBGZTdPJOFn0sNRcFDTXlp3a
# DATA HO/e+cjVl+9nbdNCDVK4b6kDDqQyFrW6gYtRsbYg92uGlVpVN4u3uepCay3weZOen4ulaAVofRr1SKnSrKPZAjGPslHmemhSnDHW
# DATA QCU5vYdcusmlp/U05CH4g7+c0S2jJfZFHsyci+BBUiRGmuedQc5Y4fdZn434U05GofwATHwqb4heSSNX5etxjG+4baiBX4+7k4Gg
# DATA rW1iVrM23unefDfTwmNR6+qnkgjtXFWsNG1naiGTYOrpB0H/hnMLWp8Z9BJqieq+SK8tJCF0fLxJp4vl83RAjAdz9kEyfH3T3Zi5
# DATA Vk5bM5dMM885Lugzm0YJG5osdhymoEUEUKbQDotM5ukD5ywwazBLYOucYF6z/NSEz0NSZvKJ6oGwXlqy8L2byF+bTWuPcQBsOahT
# DATA g+U7fmCDRUrFMcVgb8WgzAOcCbHDn6NjIiZJC0PLdEckHSr+KA0qkszFITb9mekqRXK6QDjXrfc6YuvKFZ8dqjKO7xz+kLzoITtw
# DATA EwxoVjwjXbIGdZ5BImRTDE8XYcuUV3uu41ZnJrGPkqnsjdJoWONxChaxgEhKusgLuxk3o2gFtT+m0V7ffheZ3OhC2A+dxA6+svXr
# DATA nFBuFWuAS7YJEbuU+2NGNXOcwtdf7gwU+7MjMAfJKgLhY26xRDR22thURfT8NNAZP/+d8UFGx8M/60TX4HY4DaU7koM+ne+mktYD
# DATA FSNnhYoxj6CsnUbK+SCaP0q+AtKqUw5Lw/3DUrQF625Ga/tVOaYerSedgZphUL3XOgMt1Wp1CpBa52BkB/oXTRKChy74wRyBTlmq
# DATA dnBkrfAO/LCCSQHCTABFYR2+cKH2xwNOtQ63bAr1sAB4nBwwpgYrJKT4KocuFucw+HgpdcTwVPcUPinZ5+oWD52ES8aGahvMph5L
# DATA j8PlVgMJ2qpktjS8sKDabSIpNZs4/GYTiLTZ5AlwYrHIx2bBQjgKMXQA6gghcOrThA7Z4//9xS/U5v09xTMUOGzN9O7H5hR/wZx7
# DATA IM4QPoCFUIR4P9un+Sg7WaNUl/YgSu8CVWDvK8k72Sn/BSlZ+M+72/wHgqv87fbdjVuInoRPy3ac4TqqZjAxSKd30B23BbwOs33k
# DATA 9aSHYAk4/mSY/ZiwYii+CkMtx91uAg3UvuXpqyXP/81EYb74hJBWGPlCB4NUXPCVX1IUq8WXKS7ETYnz4pcAEnau1fir/wz/U3tu
# DATA vwvnqNpUtcHpt9IGoB5cvXwZ/1X/8/9dunrpkv4bny8vLy1f/qtk6S8xAWOIoFDN/9V/zv+9+uqrsK0UryTDrsR2YiylJBoiFVwH
# DATA QCGHWTdr5QBjRSHEy7WV2vdWagsLO8fgpG0X/MlYCezJ6FidGggXyBFACPLaOYK8RcdZd4CBRsfATACIUr3tj4+OF7CQvl4kOzc3
# DATA q4SSe5i1AIUKjaoQBG36yPnZk+PWg0z1LoPQAbBhtmuqb9kQ46vb6oDdh4MVkNR6fW2YPrCPDITkfZQdjAnZAZDRQL4klMoFQEqe
# DATA dUAF3CTdmTWeY3VE2Z1O/0L8xwnAOvhx/h+w/1+7emXZ3/8rS5f+a///Jf6XjvOMxe30+sKC2gj5KDlLNoed/KR1s9vB6zf9SiYY
# DATA sYLbupT+zQAfLh5gmbR8nb/98cORXQyEk4fZPhkcyrqF7Zt3NzHTy13MKoZIvX+flXYpS0uOO6cueO++N3BeB1A/JapKkmdO7hIE
# DATA PfD7vM6eysUFQPBX1exBDw/HPYJeGWbjHE7H0rD/sMw5aSSBYv9h8td/Df/UOGWPEwxvN4RhDakqbbQ68Fn2aKAmaHWEn/ZAwvrg
# DATA g8R58TqmU7wFAny5HHyfH6grQl5TfPUIcUsaPKfy5IMPHAl9rm8uJssyKi7K8mLuhibhfJbdTnFNIEmelvDrpPF6tCr8XVYzPVlY
# DATA aAF8QqJnXF0aH3TgZlIi6qpgLhXJSydrADq8VxZ/tLtU/V6rerh3dm1S1X9fnlQv6x+X1Itr32vt7zlP5O/llcl3F2ujLB9h6k+Y
# DATA f0g4Yk0c5MHoH0pWvFdI5wWJRVIoTI9l7r6fXFopAz6sogxYNwbvXO/hNV7OKTpg1HdttWk6LUiRc13QEhXdEC1NpyS7vPg1wh0L
# DATA 3McSmrZaa9DB7KZ5DTDN7vU6PxmrW2DyEM7ButreON5JMuHGFxeTrSwfq7Yx61PSwgO7ijc0wVSriJsGNIc0eoqHMGCIdDDkU/Ww
# DATA 1QVgjv4Bn6OHybBzdDzKa3rZdIcVmb2i95c8LcsK4+T7U8kuYQnykuTguNU7ytrXxXaJ0oCinxHdXuyIevLUpqFSjpyuWk6ovWFm
# DATA UC1owRQiVjZMH2art3pItAlrVklk19bNpoX/1Hr9hyUIC1leSi4kl65eUf+9dvUynnPgZYlbo57s1mo12kAckeWszQ6IUP1uOzka
# DATA ttRw6LZ20B+qkQ/6kBkDkjICit5YiU1qHRA3WqPt1dTagkghtfUpm2QLqKd1oEH3EFnYWWSQwTpIpyNaahwji0GxBZW/52Ie1jzS
# DATA ShTMvqgwiHbPYM4nFVyJM549a/ImE2eZmVmrI6kGEmfpjJdMnXlDWLY6Ml4AtelCVNrq5roVoNRpqcW8A0aIw26/P0QGSqTQXsVs
# DATA RYAAjRlDl3Ex9YeqOwUc/o3kDBALW6DUrgPEdzZJFEGpgkFL8nHY0KScTCqWayUwoYra063uUV9t2OMTNZK3t8HNAmloCpN9sz9c
# DATA J7YUZbcA+dprowrS5rzBQ9lQB91W5yS/boNXq27RU8CAVatApnxThWnqTHcftgMPYE8NQG2FAwAQU1UtXkhWk3bn8JCwcVHNjhio
# DATA iuW8ryjesFVI5ZMrNgZ7UUi4llxYTCaOIYj7pkiX/kJ7M53lQAvwgo8Afo98s2GfA9YJiPvrmzyVrEad/WL4/9SdY7N+4fxQV90e
# DATA jd4x9rw4gk9ZJ2IKDmerHn1Gm9om4U6ccb4jtVIHUHysUb45TCjWHqulUUxawJxbw6MHlKyzAdjvMj80L1Q7AOmpfaPEkDOXKCMz
# DATA 2SfJEpDYMZl6iWTeN2pU1bukMH2jRuLuG7V80IV7XS0F/OLkjTcgHdTrjeQ12OOBplhJsYMRJLwEeixp2RihmVqDwSJq4mmI+aII
# DATA 1vxRdXCUlmvUm82jcuks6muoBtEjbLptJMy6nid1ENbsJNcVyJBWT1YqM+rZITjnO52uko3rivU0lwCEt9PuZt6rS/QqqG8CXCk/
# DATA OM5OWjRy1XqpqFvlWp4BTuxma9hSJEXR8PitWlo1vSmGYR4AT3NbAg4K6aEUtStpIIJSgU3b95kSr7VNqsJjXMwvXwK5xX44SuDp
# DATA AJvp/D0JOiAigShC7C1xcoqHG6Jc4mfTGLE9T8Y2v33vxvbNrfXNnfW7G82du++sbTTv3Vu/5RaHNOlkv68EcPlTqttau6e6jJUa
# DATA vWgNJIoSSVxqH3k4/6TCp7cc+Wp9ilMqGxC3meKutYymsggQ9/ln8Ajh98C0riEMfm6BlqCd7XNMa2lAAQKAg7gy+TfPf4umuji0
# DATA nw9HU8NYHpm7R53RTbR9J8vqWLJGyjBvPFZmxN9FvzLcTiW67dAOh6O9TwmqzgwJVGLUUJF78uT6wl9A/9M0u/8bVQVP1/8sX7l6
# DATA 2df/Xlp57b/0P38p/e8mylFm7cX5FXOEgJpV7Vu8UQTqE+eWlbXVDQwTybFxCDjl1cvyCxRB8nc/X0AUb3Dx6Xb2xZoEzgVSZJjJ
# DATA X2AV1H/rZA7yZJSdDOB+RxWOh+pI2qdQOqkVPDngsF7QVVPuYI7RJ08rdHJFR2TS4B6258GOFKhI83vjxu27N98pm9x4ABHZpsR4
# DATA bYjq5oRIlB3PMkcSljYCSgKSNr330uxYgHJQqLbdXN/eWnurZKMxO/DMkoMSkqvEso0YG2MpXd94d/X2+i0+VQDkwAUw8nBMCbdK
# DATA GgKxmOHQz5ZwqtQBnqmnpfIkihe99Npr5Vk9Mj1p3oHT6sZac3Nr/d3VnTUH1ByPJp5Qk0zmip9MRvvRLTj+3bTy+F8nlxE+YRKJ
# DATA FnaShFieBPgWPRhwKbr6g3AhZiyCZEMgcq0FXoPcaSFjcsMhfFa5+2vXl8LumpLSYwpVY6R+HoH8hkGsLF2+huGg9+9jYhy7LATm
# DATA 9Yft0kEZ9GGX4BH/VFL68sprFJFmf1WeZzooYhSlKSzNDiN22iQMGuOOwI0AY1VDfwmZTALe8dF/8Ebpg3fZeUx4NktnFy6wz4JE
# DATA MmKgQxitOgl2rqmO5/olEpnEZ0txntXbMlcbq++urt9eveFsYwmapUBMu9UNerOdjUCBk9vtb3iRtn5tGuId2YON9aebk8T2zCJK
# DATA mJkd8XuGnTaGh6c98CIsO/jt2AYpRP3etk4y8k2FxAOwqyFHtD/T0r9Y/pN0d7X6d63q3wMeufmzWavuKf6lCHWSkmLvXJPO0cwF
# DATA k2/IM0khwLe+iKDeGl5Q4zkyiaLvlfyw/dz0ZPACgby/eXcLvXUpsF/7YNoOR1b7+k/If4H9sPcxBV1iDDL3UV5hXeo8VVXIqWpY
# DATA g2xD9aaGNzd7vVVlCBCDIc+azUBRIAWcA/UMfotuTn4LDKT8/sk4o5w28ONw2DpC4UMXVkeubhXhj6k1fAmHv+INSy/DctyBvdKQ
# DATA sejoXqa2aXW/vbOzuc01b639r/fWt9Zupc6po3W2Q0PWFalacfrNrbs31oCNKTGL9BaS/FddJlbHo+P+kO+k9SS9oS7Uis0g7pd/
# DATA /Xtv9d215urmOp006nqBftHRUnomGGvyPcCa1BRMiinuxW76g6q6vTxsDdtZG/5C769U7afakvq/5fR6vOTmsK+49V6iZxVuS57W
# DATA EkgdBTRoj8be2scVxRv6Kvx9k3CpuhDBXNE5+3LSoEIYPF3Q8Lsa/hfKXQOtqrqRi2qIVWuoXM8zrV87zIBxzJgjxgZW7JMHCkjl
# DATA 5LhcT/Hqq4gSdNGtbp26QT9IC4eGLWm41n9f7ElMPxQK0jqADpBeAdSuIOQ1lgD2Ytx7P2/s7sELYMPU7RINB9+iRUaq3++3T9Vk
# DATA wucXG/iaTVnXO4clePr65QuYmwT+Uz5zJu16pF9SserZhPpSG0AyyRtjUNjWQD4v4XN1GZ7oaUYvswY6l1HGYi6u3h4oOZgqKtdG
# DATA fdJroTSnhDkzXeTy+cEHoqnF3680GmkfLctoqaNCNb2kXmn9wvosOvXWEBf0nnWrUC8mAvuenB101R4U4kN6hLFPFkpI3KVy43VN
# DATA zGLsbtCyIWdfbA06i2QMX9TG8PJ1NfAS91+eikcnjIBV0+XIADT+yHVplg3gYatFpnLrW1V93lgdDluntU6O/3KUe15+Qwzr/G+N
# DATA /1Xfqs6/4n4E9ZRj3bWbVJ9Bud2lvTdIIz53jxfTixiRmN3bWr8pMQVSGWvXFcMpl8paZaXWxddXWbokcm20IEM0EPVjwJ3T2iko
# DATA 9SV5MBKy+Kf0NKqZwsOhkqgyiGUHyTQoQw/pwkwDCLltg3tiIiBP96WmzFdbNZavA5dB/yW8MqgC+1mJAxrMPYAvMHzoKL5CEccV
# DATA cbBikaj4BhVeMrgN+4aBj6Ydlpurb6011+/Af0N5itLO89W/tpPBxb41PL0lESIlAq6AxKGS4w4pAodcpSv4Yb+rGLQDhi+RSvSq
# DATA zBHQohKD4CrTYRbMSAWKWOVp5Dxo2OIT6Ugj5y+WctSoMZG9xCvhpAR6GcE9yGWBtrBI5cV3Ebr++1I2/2mJ/lSQ6zZZHWN5cpC4
# DATA TG7KPYRtyg4wtS8EtlUZMxy9q3sPypoyd6HKPYGQg+LwXxSVPOyRwAEfWwbHxR6KEdZI1IVGLeywpAdibivl+TrPwOTVKmEuVqsD
# DATA dfvAq07GmIw2sBr1ohhIomgO8LlaUCSw1EwCb7noXIiLufYgt33NrXyp2/pP36e8aMsC1a/evLm2vd18U+1YEG8pXx/e04ntgJ7Q
# DATA oKFgWo0i5sMtKpa1RWet+l7x46wNOvYHcKOXOSHt4/UkP24NyfsjodwiigOdWvlQgftZ/uuUXQluEAsma2IcpoizkbmwROwjr4Tv
# DATA 2OZP69bI0si+VwVwwJMFSRMCdZlOAcvBFFF5SQKpqBs28C5+y+MmaCSBeYhW1B8dA5J6QT1usiS+y1cS/MjkY7EnpgY1AZC9XPJf
# DATA 0Qk2Za4c7AnsBYOuEVLHWYpLpSbjbDKRE4QGVPcSWu6m1kUYLwxnFy4IK5bwe/uuzDkMJQuM/hQ0DRcu0PJNIpdla+oMYppdMSFT
# DATA nKXoMKW6LgSdwtjVb/hnUkkCsqkwzZij0r83qmd2r/l9k7KNzd6C6rwUPcQdiOS9t7F9bxPUA/quGWqCIMWODUClwdUqDrIahsnF
# DATA lD0Vg+Esn9pkEcZZUR4dOBpIeqaRglYHNYWy/REG1RzggBTqaHmgQ7aeSR9KVovycheiv6Rlc1jRc6cDrzQ8/jPndN+8u/Hm7fWb
# DATA O5FptmcXA9zO1Nk2AkVHV9EK5U+m5uvyjTXvrdGoBdwL0BdCykCA7JRr9zLXWvMglfAUuCOTl2E/J9Pi16yOgQNtCWrGi576Ni/t
# DATA XjBtwiSXy8Fu1kPAKDEu7TiMILIL8Yc9J0EWMvwSvqmIDyAHDNYXXO6liZNyHTFlWrxFrQWkNkR7VW3/6mW2HOB3uylFOkAWLM+i
# DATA QNDv5H2ISjP+gHjCXoGsSH2CNivyAe7tvaA6zqX5F/P/52DQbzwMaLr9d2Xl8muXPfvvyuX/8v//i9l/t097B+ru3QNjIQSnkKeN
# DATA 63lMqeZhD7XshCTkgmdQ01G+QoEP08A8GlnWXX7CCS3FGHt40Bt15QdA9akv5KcOEv5Gbchw4X8Za/E7az8EBeX2vRvNzXs3FKNv
# DATA 3rp7Z3V9I11Y3d5ef2vjztrGDkY+oCACWUWG6Y9Kb9TJ3WM3uT/au1h+I/gcX1xo1C58F9KtZ7U7YNE76LbyPLmF25GOGnPqaDx5
# DATA NS/EEHv94Qk4IzHHKrT18eFrX8OJNbKVj75OXk+uLK+QXyU7ZUHy1vv5/fv/yxvfuf9oaal6/9Hy4f1Hrx3upczCAiue3fWUBtpk
# DATA 1Tofj54ZgXm0ZY+gJ6ExwgqXLlTKz2lLYIwQMhfAFaWSXL58KWqeOP8A4Usaoa6kRnqoUtpp91qpPk/KtS5k+WTTtHM7d+Lk+c8S
# DATA VOcECxvisGBXgD7CY3ve3oNKAGgC2wKr7xW05qY1nRYdx6cewb9qYG1KQgUukZBQDvPnmr/Q4OclkQIVdbdb8rIEqx2z9Ei8YS9+
# DATA AH+pfZMCwtFwVOarxFD3wHLEDGpH2I2whV22+6mW+E+0+l1dnsib8htztfcSVM+pIMVWtVuvLu8JGVNeMJlItFwh9cs7WZeuuKrA
# DATA slxeomWppXK5gt90BTQpppzxL/LAV6t/pwZba/5Dde+ierToPytfoGmH7F/nHykLcEglZBSxHG7EpWZAQSOO3GZny8TGbW4WyYYp
# DATA ueM1EAkwAngyT5/V7Wj1Tbiy77ydRrbfN+EGxHsU8Fg2+qM3AbjF26rgXcMzUY85sGonBz2Wb9W/qHR+B6Ollcucyd5+2wNkJViN
# DATA 5TD/rSl1ft+hlZXoxWy+9cVEfa1Ry/cZsoZwMVku25sNipfdYb4cbfF6Qn1qM/yNJxHB5uiC/pA8U9ztIL4qNR3wDIz1/XSGt9p7
# DATA W0KUN7fWVndmUWxF7hxF9NW6WEBfEbe0QmLTpPT1VjFQY6MsCTE0B+9zmxV+BmNrrv1ADdf6vXEjUInegG87vaP1u94WLejfvc1b
# DATA qztrzRv3tn/oaDrlk9NO1m0z3+PVttdWvJIQwQNckvISEuNUxyRNmgTxYvJlYW4VAukmXQnCl5tCBanEiqd94+5O887qxupbWnWk
# DATA 9YVTckXb7NpkIw94tnnlMG7TglMmjtR2HooB+QtTTcdQHmk1EC7KKuMiaS3Y7NFWMEHFDB0kUsdy8v0Gsg58WYZfy1eLxBOvLhbQ
# DATA 4fCOCC50QKOj0nJleeWadlRyPa+w2ViDVmM83qKu82vs/LWXpBfJ731mllXSxNVJEAhfWGIBotxNFgxOHNY1MYnCsYuU0A87a4u/
# DATA yDbt6qmMfwhocWQKY9Go79ZGxUMhMKnYlpR7vU4Mj2f6HN68e2fz7ranto1wlvB2F02VXo6q+87ZvBGHYDl3YbJAX4fHmDtF5iX9
# DATA XvBNCZo4o1kQopYXHBGSuG+zxBOHysUMil52xDDnfCxDPO6D3b1YU47XLNcThQzzW9rVP9x6YVIIBQTd74IU4XZdEXou4be7hLO9
# DATA 56l78Z2TsB6fhFYeWlNpYk92hDxwBCFKba4koUsrL8cPRAAySI7MPXkymYrEUqj6gLd92mxarYE7t5N7OGS+sIxcE+cfddNGSYOB
# DATA kWjcRc8ZT6lbdg4wrqS4FUGc44K76j4HXiV8S2wobrZc3l3ec5zPBVJutw6XP/BUfFWVezV91aKjn4z7KBpQwSU7C0pbHuNASliy
# DATA IiIradc7Xf0plFcCbV13gV2lIVpxidUrqc1W4N33E7xWlrAmuUbCDzvfdPqdtDw3Y3Evh/bMUTeX66rdvYjCQoqBMgonVZ2DqEv7
# DATA jiifMKIR3zWWyzj51lzbTlpMVpLYojSLDI2nC/bAkCPtmfDo2nPXN6RRMYRWmIYLTRJWqnC5HIlHVbCDw/7RhUVSqzqt81Fm6quR
# DATA PTIAwJ3OsOlOCSm7Laf6mAF2Cj+3/Epc02zY0mEC2ldUQEOb9aibhMwDldlVX+wZTyU74YxzvstXvhJ14ZzHOpOiNEbaRNRrsOR8
# DATA lKE+kHXcNU5+UF6I0wVnKHbIw2qNqhNwBJ1iQRSMgDixn4KuFnNZeW0iedSoCuIHwlEF3ZH4wn560slz9PdxNtNZioNVIhwPWl1U
# DATA KHRRPeKeHWePpAFJhEnlO+2J7ENjd+CwFcL0aGAIACNpwU2I7xp4cTK3BXNHDS/Nzl2lYHdzWIG+kpk0I4Rs1jgHo7D5Jw0i3PvW
# DATA BFILgc7FFuawEstcnWcjfojXJFkCdJIaIOTJlqzBJKZtoW93w9J7UB11aNes4978EuPbqxtvrcUYu9lR0jj1mTJOec9C6nPE3ZN+
# DATA G3Dl2kb+f2l2Oo2VemnyWJxdKHKMmcIcX1KqtTorX0cJaaakey4m7YvC03hxjB/L3bFApC7uevFJWTyW2qA/KKnm/VChQGqOevuF
# DATA 9eFBIXJIYXmdZc13QKJKgu/YpwAvjO3xySDXLm9ZLwdnolZ+0OmQ4ruCac17o8aKJJCew22RG0BmDvO/n6aBg0LsIMU98Ip7kyDp
# DATA RQt6lqjM9j9orGAZC6mPO2hXNt7HoBysLVh72vVecSAzNSUNbfjjrxemUZLmIy81IO43/KPDcMAll5dG/RN0KrZq4MYFVegT+RW6
# DATA MYeNCm/Td2fnO//GL6XnOVh0wixRKEome9YPqjtkLINGFQYGZnJ0jr9cKsNp7nSE6nE1d/Ts66l0uV5KdgAq4sZS/zWAHaEEDzlp
# DATA hAoca0zaqpNWr3MIUggntDIehrtO96I5qiT/ED40ad05AxamJ7T1INFzy/PjNXmvPEnMqqhsi0xzNTIJBHbsbUUfc1lvfIJgpyUh
# DATA GjN1e17CrRG6QFuKj1C7bhoomUO3HG8oIrJa5BMzAeLKAh1Z445v0PPIIlajBfNZ0EacskpxmmCcb6490CgsTK/dTObsL3mpJMma
# DATA q7cUI0Yrz9bwT4gDDNZQqGMIbui5kpu5zvMuFaEyWZyrXiQreDM//aBHW+64R6r+hfMf7LG5nXtxjHHVYqr6GnDBuS/8/wMg3PH/
# DATA O+kcMb7fN+oCON3/79Ly8qWrPv7L8srSf/n//SX+951XFsf5cHG/01uEoInB6ei437sEUWJ3B6OqYhOcJxVCR1s9A5cZ4JI60JGA
# DATA xel5BbI7XWt4hP52C9orcHBK3nigyYCdK5548psCef8eboNf2w0wgI+BBAaCJANefrP9Am0vwoWXzlMVhaJpZzSl6kQzMf7E6bqt
# DATA fcX2QiSEmwyAbFRpt7GkE/NlW22pIm01rlHAktwKJWtLDbyy1UI21acEtCCAZfB27mqsT81deManEiphPg1sybYOmuP7rSE2IOjf
# DATA ASM5bg0Rj2RF45HgExuSRD2AM9FkJ5MrrQzZveEW2wM0eoOdEMfJhcPD8W27s/EouO1yceNicJpzkelGSlYnhtNgu0XFnXptE2YD
# DATA kPpFkykmbHo+ZVbE7nNgKdMallqNu9TQOb14sA3+txKLudPG+Qar4zCY6p7amQ3YhfYNpiw4ORJO0+p2lJiUm43mB53lHFGJgZcv
# DATA DZZCj3UsrYRTfK3tLFpYzDeEumrxH6XcQxLtYO46F0oyGkYMocGLsRNiobwStza2AWTFKhLi4UzDYqnMHtnb7BTLSQYNlOw5+AN9
# DATA tadv/6Japgxs5LTuOEU7t5pvwgW5EPTkzAM9mfxlQU/mcCSkZyXT9YrrrMxEVTGu0mASvHz5kjfghvG7xqm6tlQutp7oBEYF3ILW
# DATA j9LbjfqUkLiE/7VIChRmD9QMAKN2d2uFw7in4+ZUou+xFeo5hzs0XEJyt0gs4BOJUrNOCZoosFQb4xBHXDSSM6c91TmMTqN9zcFu
# DATA EmbLwQeqxTe37m7sNNc2bskzNvE+wH5CNveJ36MeNxn0SdvIQKRrWlGCaH94eTa44AUd5hnP90twVECbV5IZBuWXnH5SM99JbiHL
# DATA EEy0nH2/WgfDfp4nmKFAB3vrELZRHwHPD9C3ElM2cmU/Bhh+eCWfcKwtYRCo5xQEs5/9v+29fXNb13kv2r/5Kbbl+m5AAkBSkuUE
# DATA DupQJCyzkUgekrLjgigGJDZJxCCAYoOSGJl3Yvv0Np1k0jmd88eZM9N2eu+Z87fi2LFsx85XIL/RWc/Lel97Y5Oi3TRXbGMBG2uv
# DATA 12c961nPy+8BwZd8OXuEj9492u0fHI+OU47L5SjalD2Z4S2poTQnAwLk8QcsbzxrMD1SwHv4csyQ/CUjFr9k1HPhNcv6w/4hNbXI
# DATA icE9WDnOWB6qZDPRnQqsW8jKogKP9YaXtKxmN2dj7YdRCWzXazUK5qHuSJj7hGNCPfW33mViuRTylWoEWBeAZj3Kxu4Ksm61Ma0x
# DATA smephFNPPU6ZGqyyQTZpwvvvQBoAy+9e7JbjwVQrAdOEgBVFN7WRWqPXkRmNWzHz6gEuaAHBZhUTD1pS548RTFtVNXo8RIMfVlmb
# DATA cKE6udQstCn94+HepNYfzQ9GU/Cjntfhwh4cjOXkYkwCkTK0NWNlJ4kQQPp8j7I7NU+dqi4qz5+6PRbUpKnXlYjgd9IKefZ/Pp1N
# DATA fVB58fMT3cb0F1fPrJd4Jt1PkyNwUAvdYZ0I8pIHPiDxCOS9UT1QgfMUSA5t+MZh+QssJLTA0wsE7LoZguq018ND0dllQPxSrQq1
# DATA WR4P7I1BpTCauTEQ/KfXxYbrckQ53S8rL3CCCoFgYyF2Q/pLlEYaBu6G+OruSfGo1LpuvNQmQ1iDYsf3umPIItYZHU/Hx/LhlHCn
# DATA Gos/WFBMk8dJwwJFqJ4gI+Mox/iT+GvdKaBpw9YGNCxzMEXxGG+RjJEJH49R/mUglHQ6oq8IhyLBUBDi5RTsLgydYnibUuIZ9P3C
# DATA XlPSRox3MoB4km5KwP0lO+FRDPndjvcOI+PGAHkiz39x9ingJEVn355/fP4RJpeEXJSfnn8CqSKjs09losnYgZoHF/oPhoJVRPuD
# DATA Lo6YEZw+wgS/LHXwyxL6CYGZPsNmf3/2HOCbqBUnP6XfFmQKAfebEcCeDPtJDxs04KGisy/E+3/ErJf/CCDmfh3L3SFDjAKIkZRx
# DATA uKO9bnKE5rGYHyCclYk/9XmoTuYRXXZ1MlQ9+P5XmBH5F5iP82NAuxIzE04DKn4ITHTZWVlFjWiXBWKkDIVE/2TIIAoQZEk/qetw
# DATA fyiJSD4CQmM4LhN8S07A86yu/iYySefsWeymDpUXCj/5bGk/PvuflBhaTMdnZ89ka6WnasudlplcvkCEL+jYLzGB9DMAxq9Qrz6L
# DATA nnrb97QOD2H8p7XIzE4tE9V/Kv75FF8GZDDIg3r+se2MqzeXYBaaS6GTCDCcEmH0oIrFdM3yYkF8SBnHWSsUFAKGXl+Dh/Xpct3h
# DATA 3qF9Y+TZhtUtwfQ+w2SykHD7d7PR0TII3VKhtVx/mbHVJRn3bHNH0oNh0BrOhR1AUm6bs6CKSh2aDG2EH0ply1Tnqdfs4f8PKxvu
# DATA l4oDvdBEMHUoSKtKJIfDaFa076uswgnqPZ1T0WElRiWaaEiBrvWw4riD5N04HQj0JKeDIC4n6Mraiqv7/Cb8Vm63JVYIWy8oTqlD
# DATA 1kCGxkJlIT8iA2+HvBBVcmzOdRo6n0VjgyQZNwiZGz5qFCtzk2jDQyjLAkTS6W9zmUDVuve8kUjW4jAls/IH0oKn45X8EC3YYd5m
# DATA RemJy6oV0yXVo7ol8bk0nhs8halTGj5zKc9lBdnY0hIRDEOgxdeJJKXwUa0OR1VUDYwxXYF6BhBhyIcwnys93gfXRDyz2EMEVhjE
# DATA LtdY4Yhxc45vnuWa7YTe4F0nc8/+s9ipv+XNSYekvVsDCU2KCCxzJiY+clFN5uUa5TqA09RGw58FMW95xYLFrtYTFA8f2Kut7KrM
# DATA AwBq/LFtFW1xAvq2vFJZv6KrX7x73B+A8KPd/fTbF4QDszV4LiDYbIg23TBpqWWbTsUDS2kPNfdHNXWtkyrsKmQbE/UHboGnc5b7
# DATA Fi6kwaPKvucWwluCblqaTTHzoLSc1o6ne7jk+/CkFL/2/mtHr/W2X3vntQevbf0N+bYFvb5a9R+woukCrlmI+BBJjzBwyKIoVNxr
# DATA NI/sUkGzRwKGEcQanJNKZEHr1+UmhKhkM5izHilSO53zPUKwcxXVg/JcniMZ9ZtIXzqTFXtTmivsd+kb8zuptbFmSj01Zstuw0ie
# DATA Z26+x920MyF4TlGhVoFJXE8jV4K6mHcwVMFhsnSLq1a7dEGrVv/uuI/pc9V8S2bpBjWZ9WrGpzsQYOwWYqa+OZo1GczZ1KjY47UQ
# DATA RjNhSzkgg60Tw0cEIqZ9yo0kErr/yo29VzFSHhi4sFLI9XYpm/tNfEvWGnTqjvOy2RkTctbHyjS746BlZvhFZhCM7Ualq82yngTw
# DATA YUMmEEPUlzXW5/z0cjULfTgwKFJWKvBhnjhDA1LP1qXok5wMITS19Zl+o8Z4nY2rKgmAhHi0PENU9nRFGYJwQEum5VydhbM9UzCS
# DATA G1hOjTcPMIL+tMOdlizSoBuaIl80LodW1sTnc+YNLQei1KOgHFixpV7sRtm7RamKXo22pqPxGGHIDiTUa0qPatFSJLkDZqrqp6LP
# DATA nL4VTTfishshKqz0VxIz+ARtrCt3a97aUqeVSgsFy14iWaX4IoWUAM7vdUEZ1R5F6JpcCxWZLXodXVrghuRzWVPNabzuO3Z2UBkC
# DATA UTWlOwvlcER0gO2roV2S8VtNXCmvd88UmrGnfnzTYdIdYHh0/jHwDhYzn0CR4zTsL1zsSCFLHXcA9KHEt2J6cuIq7LPqz7KPoEc0
# DATA 2VQAkC2bL3scWUuwWAdy1dles3w7+ReluoR7BisvEb0etAjfgPaM1Evf8iXmC9SdFUrYOEMnEYeNgbti634QWia59g2xN4dy1jHi
# DATA LXf95MqTDrsnLkakjRZ8qJe1aM4k/fvM+5oG/z//JSjzIlP1ePbV+SfR2e/gUoePGOw/OAOoYSjdLAJnHtANfYxq2a/PvgV1IGhm
# DATA /wA62W9RH/0ZD+CfLrQyGVf/Auw7fAZ3Bt0TSJFB2o+rV1ow57h+XQrv+oh+myNDQkM6tSUmX3Qw1Ur42XJ8yXDEl1Uw1qs6dumQ
# DATA LX6kathbOyrGkef/A08scqcnTRzc3UoK02qSYmoe6Q1cW5ocHAM728BfStKKKMbe6HTEsdHplI03wYbX6fIrpVip0QlHH/QNDSCT
# DATA dG/ESPupEFekSQoVglKOILViMuiRGpHiokh8YrsnfCOzGhmxWLVEYDJo75KGbGSxsYogqsIdAL7KpCto2kWxCQ1gmOHkeDIwVWrB
# DATA 4VXxZo69zJmEahXjUiC87mScNFRGLrTYNeQ7+A+8leprG3yrGdY/wUnV3GXJzPQOTkvF9D+wOAAWIq8qcZo70h3+aJiXbccEpGh5
# DATA Twn3kdfUkMNp6V0+hK/SclmyFD7HOVMRiKyNXwAHV+PnH6HvK1fvumd4B6drAaOD8hu0AAm2fyE+G9QG04A0t1EFM1XBIBlR71t6
# DATA WO28peXshiZPs04bqVc3C1PVdKHDz3yTw8+Whh2fqLsEflO6dqVF19TTEbsE7Odi0TpoWOh0kAI6HWAqnU4c8O0kdpPphqhSX/wk
# DATA OZmd+AL09IkDrzoBP5747N/wKP+cTu+CFhfLzAeG2zejgE2SdboVsjxyEiDMWw0n+rfn/wSNQGVksYRD/kuoHdqvRYISn3FvIPMQ
# DATA Nv0pvvsRmspQhhMyAYp0lUi89hFlMgJl9D8YSbmxZ8+BdtFYhG0CxCvcNhsQ/0BWeYMUTyjnUGnxzyNC6s/7z1L54z36yuHf8+O/
# DATA Fhdu377t4b/fvLX4Mv7rPzb+a1PDvGOijmRCCByk3ffiv9I3xdkpePlufwqpuKSTAwujabEYMB81XmZP7LB/Qhgp/vIRYZh98U8+
# DATA PuxCZmTsYziuU2Pxa9WbSuxWMZz3TKGuYnnBszjfB8CK/vSEDLh1C/LZjnEvxTsLce1nI3Cgh+hpuGd9IH3ayaPd1HrGhkORtLuW
# DATA yxrZyIqTb9Vv3m4rXOm90QQQVDUMEAaha49WSutmwCEofFXP2pTGUjqml3IBSM2MMIxrsNm8t7q1vfl+bOM7mchOVO/BYLRbiq9L
# DATA bFfLM1l6hAQavkjjhseAJUfaweOyPUg2iUqnwAIXSZt7D9pfXt9c8RMyQ025ULRqzXxHTHKXDyydAY07p8YBj7QrjXSyV88DExqU
# DATA tI2IEB9z16SZDdLVyYZmg+56Iw1mFCdX4MfdR0k1aA8luA4oCED7vMWCHXwo2BPkCWqjnRu2f3dIeF1w0zotMkZ9n3ihgebfVDg3
# DATA xLD/dwghZWC9IgVDIABUZlxEsKiZt8gmXDKjWCiW9EoYxtKk6e31dYCvfB+Jest2i6I6ZNwu35ZtDDI8Qru9KvqYaxfr0X5EPqRk
# DATA ljhC0wVzbxmGIu6jyZPunqRYmbSO2LADCJ63ERTRdxznMmRH5vMQb+Mww1Oj7exdYoOFGqUD1KGbnwlhndUd664neQPbFGAvGdVb
# DATA O8pr1nQpqBgbLi6fevwLXw5GZxg2iX4vNYwrls0jw8Ai4x/KdoDCUFBySqk37shw5kAe+251H4KGny7erNy5fRqHHROhpqIsfHl9
# DATA bXtpda25CZidzbXtdfsgUYR8ERvPdegAufCL6SE1otY/iPkYPSZsN70A8xkcD4NB+6P53IIh9b2KFZnRxEVCSk79qFiUN5BZWVzL
# DATA iLfIMMLo0/ECwTKBsBjw0qcJNTQ8Mo7AIFStLjOWolCMTxAeyKiyBrntBDH4cUktVV3bjOF07BoBfY1U05QLAD2b88498s8jci1T
# DATA AeNxCE0uOEZ2YszweJ4Lwdmghwk7KcA/LOanp0FgQb1pAxaJsGHKTJnixCYHcKz9HCr5aDycGk8cNioLTXCUEo20RfaQ69gODzUj
# DATA WjHoZE0zlTEOL5Vopn3VO9oUpAPm2QEgkzRv6JniNcq4DnCZ0/YorclcqPHQ1FH7EISYl4Ul7+60VM7DSiyaMqUUyplixprSzJDv
# DATA PTz2yi8uLCyUy/nwifkTtP6eOELCuZJD3r8FchOXC4K8E7Nr2XJg23I15DBdIRCgQ9ipK2VQFXMzkyUX0h6HZJi5ufvNe0vLJFtS
# DATA mvOt7/j8K3oESgwFNsdgoC6KqRaQAg8lI7uczuxa4LTyZ0ICBB+Px3hZntGJrJ7SVsjsoQ1YO7OnFw03LSssioPEUNZ0JokQ++Cu
# DATA ID036tIdUfp05HvglX3pXuMFKPe1GRAF2YH/jmubMkFjtBdYu/HMzGtLe54YcAg5meoKRDgrBVbHtDUSZrSUKDi8WcPLmGEYhiNR
# DATA Vlq0Agg8LipTQUFa+0TqICeVqtgOdSr7iXICBdSRVkQV5R5XL3pB+Y4vJ5e5mFz1pcQNhd/X7kSWMG9sFHKpM12OVnsGhlUW8FNg
# DATA ikRVBTAGbHLW315xehGG59GygO8/NKt7ag9Qy/2eicelfy0Xi1QP8vhirnGXiEg3OaijmMTDwt6fGTI+zLGzKYt0ZdaNw7ttXOCm
# DATA UfyWYfl5t/x8NBe8ffg3D5hT46vDzyivAN0mwoDbl7lK6EFpLeOkNPNy4dw7C1wtXvBacakrRdHrRMGrxNVdI3IvB1dwx7j4/SLD
# DATA LVGTx1zBm0jxW0gAJcREktBXDsx/4eqmtZ+Z+FGw0izBHVzzkl66rMQxVGXOkCtPrxbCoqKmV3ZZo1qQfJa4IpmKtfVDaklw1d03
# DATA pTWtmSok9zk4IyyfSHctzD+aJ14gNT1Yvbe5tL26vtbZWn+4udyMrUBb6TzF4UdjgrjRTF2srS5Pj9z1Mrn9GNJsECyUZbTE0w0q
# DATA 13p0LmmbBfmhR+mvNApw7YwJwO2k0r89WN16sLS9/I5vQQTdOrcv+DISNx0w0iOMVocQYYuvvvugYiw9tNHwIFmgBXlPRE9Atr7I
# DATA tlEH2tGmGQvryM/oRi+ZqdEzBKGbKAXhKhURWulWu2LT04xVJ+VlqnMYuGOpezKOY4HKr3PmboDEbWREbm42V+Js3NIilyYXCafI
# DATA rG01N99dVbvwVRQo0kic/2j2qhIylLR80WmeQhycmIJodzJ6nKLyenw8TWtznmTTCgRWXQ9tnLaXTjKkYZ2dmfoSJnxXIMg4q6QW
# DATA RjyQOfMYoLkjZHIgAtoSPtJqFoiHcdHUIymIbKsz7rV4P2FPWbCS3wmyxdwAnCtgzpdUsnBFjEluODljXc9/AM2jL23zeOC+Ylrn
# DATA PIpcenB39d7D9YdbtCTbS5v3mtvxxXIEGmPXiQIXZCC8x7ucXFsoOFAVMUYQ1gMRhMoTQFuR+BHe/U6Vj8wxCMJCFOD2hsdHu0qd
# DATA gRZr5CMRA6MxBhu0/qaCFZGI4ONkAjgKKWIKIeIYbkoMsgONkTJbg8cRZttWIjn2gNsurJX4T6KMsCyBV6GNMLaVZ1c0GmMmXyhe
# DATA DWbIBGWrCVlVAmpP98ZGKVi1XciXOTzQsL0bYvnE/Rv3Fiwu9IgLQaf4Y8rQwZZhTjRW0QXA+0t3OgecElo0IUA5u0hbAn729/cT
# DATA VM+sbujajyAeFMA6oy72sxat4QkhxDmg4+7QcFeEHKEJwBUGmYQjQzr7W2tfvO09ExXP0EBkNzBLfSAFUut2wVyEz0hH6DB+RA/P
# DATA hirpiw66mNlD49VMHsYVPFU+j6wTUA6PzubTtXqRWJj0zo+Ly7rmzwSkUjqA2VqP06sRoF+NtgWfVAsCG4ycfCRflcsH59WjBFnv
# DATA JD3sjwGxdkhwR/Ki1WP8Sc+yFDotzFkNnhm6QOjkKIj15RsPAhneIcyjC+HGnekIqcUghYJmAr0pLoE0OpeB46lsP2zsqbnWH5X8
# DATA PZySPiuhfYP8tIwno4ljq1R9eeWC9iW3KkfO1ojg2SCjGZ6F5XIerwsKoswwJXWXIbvwJbzriPICkPuzgPH5oQ2z42c2M7NKEAXT
# DATA YzN4lR6V6B/Kjkq9MnMl2yFTRfyJAbIH+TTkjSJvX9M38QXEPT0KKeZJRzjDddc8o6Qk4q9lHgqAe49z0V8YaJJaydm2Ba0gL2Rq
# DATA 40YvAUJAIDNsAaerlOnU6VqGpIe5f7j6lx7vku6lKZXSLDz3tpAfBU9+tYbrq3HpyugDvRJqWIth0jmigibZgC/vrCNfeokazmae
# DATA cUMjRVjEasP1cj1B7BlDwvVeQtWa4eSZDfyAqXV1QX4MHiIy87E9ej5zgj2affLM9Ccp5EWiR1lRHYqPh91H3f6gu0sYMHGWPvpK
# DATA rpPZamrqFyZPpA7GHDsuHu2ORgPTP11dSXLqo+DqOo2zVRcXvLbjv4616m7qn/Kq1f4/mWR/GgBJVbfobu+EEWsUyPJNCbkCWBKc
# DATA cxePiKOR4HejYX8Ps3JzeYLsOgRAS6/Qj1QVIRCt8Ha58Fax/fzt26Hj2b+ZoIFX/+5vmLKWNia6NBCSDazhvZ+zM6E2B0wlCI2f
# DATA MSSrHr8f9r7P6YYNLJLHjjUWqETqyFWvLq28r3yE+FS1FNgq2l3rrHUAvBbuEIbBhNdOjEeSmw1G4jpdXF+9vtEka4itti6mZ9dg
# DATA FFaPZW8zekTx1HmSCYBS2MKJI5G07QYRI4Dak8AV2ChWIA57FG8WFxYUIMbeaDCaBKo17cQGyeX1VfWCsTQU+Eagj3LBpM6n7Ita
# DATA /my+0uAVNwUtyZUkVamgC/OUNlR9U3FjIU0faPDk6ipwUzTaTiEUBdAV+1NRjtWBgJQFJsRkDBofzFwqlX2z5IM/WQxYG/pVY5iG
# DATA UF1No0rgyiULz7SzsJkDtAVbq2v3JHwrau6Vvs8kRVZ3rWMcI1iuet0BGIlY/ATTICJK4jpxWEtai6RWd3rYnRp6BVh6rhFjRoEK
# DATA SCVxAKow1DNMH4+qkiB0Rkdpa+nKZDhIEjXGtez1ThCqOVNXAHelZVmMRBXRqw4hsDUABFP8Fkt5lVbAGhKFsqlLuR1caIgAdNwk
# DATA KsN9ivz8qWfZ5hZtVxl0b5K9DIQTWr9pVQBtG0dsMq/UYj/RRmu4l1BxNYye7gxpN2N2Xp4T7z5Zv7WwuLAzPDWzjh+NxKWUkivR
# DATA YFs8rDZ15ZEg/yNr7nBDguKeExSZvrIVzNbHrrxUAQDL8IkIOtY4MwERl2eMHHyDMAt5wuxakdy53vlkujeP5eY1gZCKDsiBhlg2
# DATA U8QoqtGfwXWFhmUvoYY/xmBiwbsaMg0wNC7XRbNbVaNc8ishMk0JvNOlcM4FNDAP2DG6OqWcZAyyPfJbJjJLoIa0Q+nOT8tOlix+
# DATA 07rMYG6k7pH0hjIZVyB7dwYHe2dpq7PS3GiurTTXtiU/k9qcApDRWRnqKTe9ETVYDaMdh7PUXwCrWN1VLwBD7MINt3WUKi6XXqq6
# DATA of1t8jEKOcKOuwMG76LjHKArBfceiTunuMC9yR5L8pSMxAyZ/uqv2hk8IpYgoiPIVEbKlRSuAYKRd4eRMYl4DmulseIT0Os23gD3
# DATA ldNUy8hDZK4DzDpU086sRgo0UEs8HMUXR1jWqEP5rxUvPxuOOfNNG5DZRoSjczczJLeYGvASsb3k8N8ddKgDbkSu0a0yWXDUd+Wh
# DATA 6ORRUjWqQPuMEF8d3ptXnb6vPgWqqJuxubzPdFAulDgth/bPKfuDAahpz4K1/o9H4M0kkcKIvJodYy5BB+qkZIArhTHHHNjejN2R
# DATA Q8oS1heThsYqg3fSYUctF1hQrYOK1SDPr153mnhEGOxOyJ/M5Lsaj5Fr9Yxx3qIHtdj+9PP9+Lp3FF6wHkpfhdcHDBn3K+STuwDF
# DATA m+nWAtRfLmR43Gw+WBd3d9QqLK+vvb26+aDpgG/Ym7vuuI7TfrfPaPsNRwm6H5aDQt7hmK3SQ8poW1tZya/StslpLnMhKNweqZdR
# DATA /JaGcPmUc2ceJBl9JON6waaMzmnWUM7GJzXKS5ZTzk2s4kyf58+csTWCsbIqa6wltACmpXOfioVcPOmqB+XMuFquMUBKft8hey3I
# DATA EkjYJoUbP4NByBdy28FZB71HHjH7B7k+qtjrNAvK1TgjKwZXMoErCCxFAXyillueA1JfzOr9AOwrBO0QAw1z81lwsMG9bLKQi0zF
# DATA jP3tyhcXaMWaR6ceF784QzQJNGGUOh7SRduL3aDLjI1ewIFEnsErGEmVO0oeKeebQKuDY6PO9rkKR2LMVGxdHLk3NyTDRPXNR/SF
# DATA mXRRfM1QAk31yiICusReQadTefQbnLLupf1SjLEu37ahkbLAOLREXFAat72mXLlckegLIoCZPv++qF6222FFkwl3L73eZTVGHEAI
# DATA YUdBXlllTKWFltdN11DKFmVGHWetZYU5tVYob3TTlB1HJUEwWCBeePbEd5hp8R31OYgnuCeNA6lYBp1NW6mTc/yTvZhazyOnkF9G
# DATA +aIL67pmy2xbbHO1gjuK7QoZ/x2Zrsyi2xD9HbuhIOQ4Nnyk6cQ6YvgXax7gGUWEQfxV2v95Ev1VdOf112/duYg3enPtXUMW0k6p
# DATA 4MnRB0X0oDSJ/zYQBt4oGaEB1faNnVr+9/JfUsKVPH0dxJLUHniIScphs2E5bJrL5Dho2ocXZUwjupb5wJYfbm13th7e3VreXN3A
# DATA EKHN5sOtJo8N1CFUtWAcO0Nl0XuxcBiyezohMGY8O8clWTK7XbyspWL5yE/v/J/WTFNAtUjLGM5FF7Sr5NnYGWJCA2maF5jcibZ2
# DATA J1oqDBO9GzBeljFcdCHRoXbs7ev6/FHw64tFURe7ZWYEyGXMjY/IwZ1pyY60W9yBtgNBae8EKwyqIJLGjJGIO/Jac5k38n95uKoj
# DATA nMIZwTK7BKmICyy75/okWY44LpPJtMOcosNsIfXjaonYKy+QKs+1RWTLiZ5y290qp/7LPkNr8Yq0jUQ3yr7tukLJ+XhIE/Eu1YZL
# DATA FgBe91MuB97jpV5Zf29NkO1Ks3P3/vryT5orYrYEnwZRE2sF728wfOIXxyoTzkypf8/KTZlBMT5d6KRw8mhy3wsUzU1AR0xcF2Y2
# DATA Vs5Ov3YhPzaUJXjw5G1LjyvuUFQ3jfxtfDxcJuNdVu2hvId0L+NBofWvWBanItaoPyELVP7uLrCJvwubzOVtLBe25uTZZL6jlH+v
# DATA wklC+TrTRKyi+DA4eROvLEYwjIzlSBOILqZfR4MBtBeRObw295/eYhGyx1ydJezqbVuXtK1djSXMOv6v3HLjH73Xr5eexq4hR+I8
# DATA zzqdkGX6Qo2+MIBrwSx7UPFUkJe3HF1CK55r5/nOk2QFXfpmZXU0XfouZn25uFXnRYwNhVXufsq6HOWxHxDgq78ta4/9W575iCtX
# DATA ZiGsp/jrWaauC014hoHMAEN/AdPP5YwgMg0ft+LkC85NancV1o3LJrx7aRnJsYx839kAMxmdmQyQ6Op4YuvHHEFfR65lYFBSqUz0
# DATA GQ4ekL4Nro6t5DZX1tFzhtN0SPPt30gQykBp+Mihs0EuFaMnJ41YwnLEs3E3CoJtMKpCCFFh7qrujIWmngP6LDW8DYJSIGYWGLE9
# DATA D7XucO9wNJntgriyutlcBvwF9IBoPtjYfl9HAfZlcPsFNPGWTUFJdRIQwRiMEPkR3qxsQIpiOy/QZ9T0g8upivBQpKM8SIsFcmyu
# DATA /9SolEjSCM6WkbbhsFe7Lw3tky1H6taXNdD1B0urnqINra7F8UdJD9wfTOmeNIDI34aooMZoyPLiyauIOnm5ojJKFe1BxhIxbKZ/
# DATA CyMvaezOIL3qXuSunMQOECv314I6Os2frm5tb8XeViTVDbOabNULsT9L79Lft4bvU7npr7qkI0ImCfPEqDvZO+w/Svhmy3Wh02g0
# DATA Gu4lb8rs7oY67dXoeIhh/4lusQ85T7pDjiJIwBRAaU92J7DttYsqt5elklEdu6CDsFF1IR2NxxbyQ/ydJ8D2TOCDQDWXxYVycRbw
# DATA nJCTNi+v8MeWK5Munz/0CoFJdUYfGDOhX947FC+W8L1yDoK1lYhMFOGjQ/R1POjuJUGQ6sbhdDquz2uY8vqtBQrUChWGZZbboDbR
# DATA ILchHZJvX62Y/bbgVJ7a0adGbF0d/IIEzadV8CocJxRaKMRUVJ/Uo5blzKCaKjuK93iMqDai/H68ePON2oL4v8X6U3h6igEerqae
# DATA mA688dSBOiBxqzoZDbKcI9yaRgcHFJb7NO5N+pjrl0xsVakDGo2l/vBpfNR9UgXDMRRaXDgiHeSTKo83vhWfug1QxOTeYbL3AdYw
# DATA FXMHQ42XH6ygdCmoDnkq/nc/ARyAa7zuejJgFubRVChk5Xmq81q5JrjPsDRp/JUMlsZ8o5Pa6IO3FuqL5XJtD2EFSmWnhPiJ4/5F
# DATA hUKiga6/jkyew3L1A8HbgEuJB4s3KZRyMu2Mk0l/BH5g8c2FVAw563CFGW/JxRLXuJmwFHC1o4+2ffWpDNH2XGBoWfx1pthu3TU+
# DATA Dty+8WPp6s8AAiovtaU2Ieup9cZT9Yboxal6C7oEuV9gsbS3HA+BK9Bdc2WLLGWttZF0VJAUsy8XNVX2BmiYh2XclMUE6GH9ppBO
# DATA xv1hEhfgB5Kt4MTcW19p3n14DwofiZnrw5VtujduLMQ4gZIVxD9YqP8Aed3t27fq4n/Gx/nj3hgJWIZyhViNniF0ZqqHQqrqk5ES
# DATA J6sQv1mfh//qZzQp9XlWAVtu1zRdsgs0SbomSRFmPfjsdBY7JjmqKuUocU9wNfvfjd+Yw7hsx9g6ooCUfCJx0AVc93V/XQLDK1tY
# DATA C/Th9AXwZTJd2UxlWq4eNFPlX0B52putTJD3MlutGdRBFTaHnbohOQSJaWOhMUwxJgWv8yE/SRENR2ajrS1NDo5ht27gLyWJ2Qa6
# DATA gk5HrF6nUzberAn67nT5lVKsQrOBZgkuuNGKlSq9qvGLCV0E/dJjwqCZ8n2HlRja9HI8SRRLrh5PBvwLXwSqgKiNhxdIVOrYVo6A
# DATA eEsR9MK4B3iJrHK0JTKv4zSpAt/R36gmEovcYH15CobABto5M1OtAvmK0hA+2thA7Zf03DAES9M73PZ8iVGYR8i7zEyx1hTZ86FH
# DATA LMfaP7LzZ1JVT7BONqjQ4Mh2YqIUhAcIEqj2mYXE9WjNx7L4D5RONVQSpra3UQCClOLCI6C7Ve/4aJyWgsjYWC8pN/CjAcSN300+
# DATA mQxTQV6dbrrX7zM2Movxg7weJrGl80V7OxYm/ZpYAfRh0s/JoxSjfl/QPceESzXtV43I6UHFVnSBEyEqrdz+lNVaqFcd452eeolw
# DATA PmuK+aqAn5Vxjl7K9PYLDGrGWuC2zqEOiVylenuZBXd5Rk57LuqwO0uGqo3mm/Uil+iVwbZyOmQA3bp9gYeXb1hzSBN5I+w6XXAW
# DATA +JtBmLn9kNzdHb1UW1+sVWPToP7V7YrhhKu0WMZEgrIjxqtqgP5ZPocisW6cAvQNjXj+cOWhaKT8ZV2/t7DobdgruhHzm9UHcN0R
# DATA fcFqkd/0xRnRrK5YJ76H/q68eDO6Vc7eJ08/SE7YgQiDsayQseBhWz69xN7Rx7OP+OOZJPxRqOmU1onWQju/QUMEyLpWGuQuHb6v
# DATA YrW0+OUOVcPxZK2TrNk0kktoqHyS02BRQtQVHeugxajTwS51OrAPOx3uEaxx2j8YHiMiYAk+dge1rdV7283NB5VIf3/n4YaZIZ2e
# DATA 0z8lqqAScQ6R6x1xEzvRahbf9YVk77lL+32SuLB1Avnpm9CK9uIE5croUTKeJPv9JzmunzbGrJVfVqHxFcroGOieuAqnmMrbhSnO
# DATA lmpEj87+OTr74/kvzj4/+/3ZN+K/X0bnH51/LB48E1+fn/8/Z59H8Pz8Y1Hs7Nuzz86+Ovv6/Dfn/yCKwu//FJ19Bb88w5e/Pnte
# DATA i87+P1Hmmaju+fnH8Pazs8+g/vOPrHIR/D80/Pzs07NnouQ357+Cxv+rKPLl2dfR0sZqVTz9VtQFLT17E/r1yfk/QkXi+afi82/E
# DATA t2eiB06Hn2GHRf1nX5z9AV/GCmruLZvUt0vLy82trc7bS6v3eUL+TdT1rejU5+Lfr6C2QuPmRv+IL38pylOjkVnd+a9xRt7Z3t7Y
# DATA qup5qUSi+Lc4ik9Eld/w51+L5/TaR6LB34Rn7xnMXmROlDMd57+SA/ij+PqRKAVL9C9i4qgYdPYr1X1rzs5/5c0ZRpx03hZz1XkA
# DATA QSl3wVa0+u7SdhOn7n9lLB4OUPT79/BVLvs3MAPiIVDeMxgvGVhwcNAJfGQMcuHOwoLo+v8rq5Uzjt+fiY6LEXsdlrZI3XHsqEOi
# DATA 35799vxXYm2JBi9ClhF2DycNJ/MP3Kvf4ng/Fx8X70Q/6d/N7JhOixnoV9bW+a348AX08xNR7nkFf8XmvwbCfC6/P+NpRAKsR6Da
# DATA Tuvz7G6YPOkejQfoCOh1DimUu2Yxi/9OLYheCVL9HRCP3TNs7HMxm59gwx+JwliXWDd+9Wterq/Pfw2U7laANPpHHMmvz74Q1XyJ
# DATA M9E9no7MXp5mM2XJBtF7SnNoIT+c/auoGZbpmeASzz3GEdgpvJhfIAXCTvxlzrYWH/9bdPZ7sSa/QNr+GlfiK1HqG0E+z89+h79Q
# DATA 278Bdibq+gqXV1KZ4Gq/ElWKLsCv4jdBlB/X4ND4iz/jv+lAiBIn320bC+Lvzu3b+K/4c/69efP24h35jJ+/sXjzzl9EC9/HBByD
# DATA Bks0+Rf///y7du3acjKZUihuErGbDwiznFdUm49JRZc8jjalLUu6SlGgAQbt9o/wWiiVqvI7VUQqMfkMriHy8yidw0gcMIoM+rsR
# DATA PwYZXRaZqMq0ZKaenKiPghONQUyfowpZyJQV0pW0YpmGOvQwrUR4MWBdsZCoh2k6KF0H+bqCIJcclrnf7Q/g+sO8rhGLA/1zYDWC
# DATA ZfwC2YpkKRtNIU8DAxOs6/n5f2WmBRyPWQ6LNXDmIv/9FgqKA4YkH0sUeo48SzTxMVQlSn2FJ+Sz2EUmN+RWMfhSK+aRgCcfjAUS
# DATA +UFqrAYMSdx5uuMpjGZ0PIWHZLNTqMavG44jiCNN6vW9US8vi5gzQwEk5RphHEl3QE2BnXG3PykdjtIpwznonyqUPMZcurQRK486
# DATA 8l+Sb7LZQrwN3l39RxRjg3c+o8oyaz1ExQZiOl6LrFftGGtwA9tDvDxxwI0JuAq/xzvDncnOQjxT00lyP8oPQCR80kkxTZzMEcpE
# DATA IIOBVMpSmDjCUex+fv73QAwgp32Krwgq8fMMjw0kARiVHwK+uHDzdnQd/5nZ4X/3aY9PWKZg1Xk4yWXnxdiqUnpDgei5KaGJo/uX
# DATA IKNFD/p3Vaq3TXHxRl+iKB257AiWPvm7Y3AwAfdqcEI9ThmzVKLYggkBaKimCKBDhC7WGD+BH6R4Sjf83RPQm5fVQltPKRyE+UD8
# DATA 5PWFH6JNazgCTwH4hN4NyRAtEz+4cxtdVJBRqGblqNZFLVtb92W8Rhr1MGMRYlr2U4xJB2+bKeOmvym2CWhbxEIOf55MRhLVnsIz
# DATA uDztWJWwaDfujZKU4tvNbRNLV8KZI4G9I77pzWePJR9dJPTnc8ogGYHg9RmwRaAiR8T9HewFoC26GD3Ld368ivoVH4B5wF0eOCtK
# DATA FhfSc4YmBes3GfZqm02ucq1efJ0usFb2VRKuEyAo03UNboyfwillzKjgBuLJM7xJPPNE/AKc8nvpBScUIlkiHRAJgPgAdjVLfuDv
# DATA dET+XNqJXo1gnWQYfhrtjqaH0ebWEm7Y5vLK1tKb4oDiFClH4GSHvx6NeseDPmKmGOxqfLw76O8Boq1HBOInwcYsegjxG2ZmgZrG
# DATA 8nXxk6SncRdSXZAVNU3rsk7JL7XLrtG5VxpOI7m78t+8K70+N+A4EMvwrZB9PkZh52OpYkK9V0joOf9EejKC1TM4UXq3oIG6R8Z2
# DATA Z65qvQQEmZKXykbUVcNisMid6aiTioLDXlrCBmVyqAYlh1psQ+pBSRi14ehxSdJG7Xi6V67BN9GLo3FpBu9Cee+rCNVXX9Is8E05
# DATA JPjBlfcf4dL7DWkJn53/A97sxbXfzoITOANVGMb4ZLbAZRiQsmQvfaxeTozj5UzAIiQxJJywiPkY6kgVHo5RuDCCz9n/pKlDkel3
# DATA 2KnUkb2QoyjZyxCylMZETPBHgoa/RuXCl7HX9YBXbciP1njB86SFOQO6LsWQI2nvUJw4tXFyRGaY/iNI2AhfWUAZ9HQ+ItOLAmsx
# DATA jBCUh1C2Og8/W9AbF8pTe/a/UWf0OR6un1uCHgiAtjxrioTunIrX/4CXGzWrKCca8qwYoETIHlvyGfXaj7sNWB9sfDgQIMUE/Vzs
# DATA eZwk4gzOmLvT0VF/j9tyJ07VY5kU2IpQvFkxNDdwM2+VDMQ6rCvNiDsby1AwzmJkk152MKY37LEzTjeOyy6Mrj2yvEyGIxNfEqoc
# DATA JMXhC7rYJ6A2HMMeb2D8GjmfIwztfv9JI65NB2k1DqwmwuWO0tp+Dzh/yWwkfrwbo31GsPSke+RmTYJnbP/zBmaU2B8cp4dOIB20
# DATA l54M90qyjBjDcFQy4qFHqfJqp0XHMHHalxDrNzCGgNwNJcbMtWIerWDT0tJRMj0c9SqMJOAgsJkpqqmAFZ8lM1EbN0J44l8K79z6
# DATA we3Az8DPov8rWhgtvPFGHo9dWdsy+1wXvEAc5b9XNgPj6gfcdHVtVTGOCFXt0uSAbOGOuFM5mFOmKqlGWCXssachpSSGlvkqsQ44
# DATA 6YcHpbjVG6btnWF8A4dpODnI9UoGmJEYkiAo70/xjnJ1SyZH/SkFr5eewi+dvcHouLc/6IJlfNwn43GMIfe0bmTMV4U44Qu9e7A3
# DATA otf4LbV0Ga/KFADUT0o44HYiOeIkN4HOgRhoJCIwR2NUq+QhoyWQ/FRpI9nyI/TqEDMKLI6/TPiLyt9AldQoYfuMcKizfwbiUPZP
# DATA oiJxXJz/PQnwX6O9FM+f37Id4Ru+0AkarCr12TMyCEKR2EEGM+He5FgZ4KawSPEvSNKfn30hGgPDz0fajvUJHnjGZrDaZ3Z3mSAc
# DATA i+1SbRDkWvvZqD8s7cdPPzgFM/Qj8HMnj46KNf0yu0MNYfUw9yrzGvDZNqQ2pKBKJNlOAUEwpISzqRiMSbYPIbZihFAaiSEnsQEN
# DATA WLuxU23f+LF+UjPBA9tPb1YgcSTWNlt8yVLZ0qbRPP1QcAZ0E445xIB6G9/Af2/EGE2AVC8HYqYJxdUepBod0j5zdeVecflx/lF3
# DATA Mj/o7+pUsPPi8bwlF2YVMmRFmSdGcVFq+oZcqRsYQhHfEK/diP1ICjsQy8g742o7jLGJmlNSRxfXnjiuVtGNBrKUG8DFiLqx2nLR
# DATA 7lZnJs4xfIHMu4YZZiK9y2mPwG1uIlO9iI2AtesUbQES1nk0untHSbVFxNtuKcRLANvhCmfzGodoBddBz4E/wD3xY2R2f7CYHfeJ
# DATA xALqrB+hrTXaWCJXo32BzaR4IBpxP8Mr6vNoaflBU6l7U7Qdi8NsnOyJCyIkskedyZNkbwuTmvzd8QjcBCPQmfTQZXBvSrqZ9DAZ
# DATA DOTvpD8RgmB3TKcYDkRHGe7sAA3tiL/YiD28Rg+vmc9eg2evvcY9NOiDkhNxh/nfuDwvaeFGLMPw7ASZcevhsD8VssaKEVCwmdiG
# DATA tO37W+YdeWe4tC9kmQbHTFVHICIm7KgWccAxt7YzfK8Lp0WwLPImqzMc2SL6sw3++EJISg9HotzDB930g8aCkO52hmr2G9cEo6M5
# DATA vRFf2wElER9Ud27fvsQE4eYpND1yYoxJEftKTFp3AGNqbUNN4q314XJXyOG97qRxvSr+L1q4VVl8vb6wUAc+ZQ19UxCWODd/nvRW
# DATA kkH3ZCvZa9y6A6U2QCmfwmWgMRVnLNa/SpbNNs1u0rt70sDOp2pinbkIRJhcKrikUFyJRGOggJAxqvRMOUNBBWAYAyCEkHpveqii
# DATA HSdSkjVcPltGRISplRZfWW9ouYTSqY7xIJTpy4q2SBlsTwVfwUcctJnrYOwHU9xQ1jj/RynTcvhhQ2bW9UtanP94gpPivgVKq3E4
# DATA QsPx6lQTbngDu9qubk1al7s1S9/VraHGq2vHQkOfTFdSz+t3fGL5HktV3exmTI/vi7VpkJDRtHED7dakMChq5ltot2aK0OGKnQBP
# DATA EjTNkbCoadZ/6WEQedetxKwwb+rQFh/pJAz52zIcowFtTJ7CNQIm9O+KGSTD+86WRF+NfpIkY7RUSgSgSB7FeOOGnM7DvcExoF1H
# DATA 4JmxO5rGaTSAeH6+kKQ1P0t2K54OZCwmb8u6MZnWbqaYSR6UaQyvaaGgzFveKgv70ixjp0ukg4CnyYJxDCubSNA1kvBOB2kgnzfL
# DATA L+CnRJBnxkhQdrF+hT6HUJKCMguZF749/3u6Pp7/N3LMwAsmGufhgilOZicFDHlziyZbVmfa5TfNn6An7QLe2DOcpMNeynB0ew7L
# DATA lmLkUk7MYH3/GUF+YAJPVpGRSCZeftSH64rBD3TKOYnhkUSD0UHN8XyPz/7VcGwRM1oXFyjDPRBB7XTuycRNjM663dh0iWG/P3Sx
# DATA WV1brWiHCvH/bG6HwFcYSMNIpZXtu7j45+3pl+H+tv+4c3DcnfS+Qy/AfP+/xZuv37lp+/8tLtxaXHjp//c9+f9tJ2Db7k76A4BM
# DATA SMHQAnkjGcnn4dvvCSkWs6nycVQh/Xt/SElHwRIxoQTDJ3kugPt7w+ngAv5+6eHxtK9eoLCTi3kA8ndA/5EKLnTYoUCpGX5z5PYX
# DATA 9o4Th7/jKHf79Xyvi2T4qPH0+vVRWuMAQXG+3l/uLN1Hz/NlQ+E7089ukzwajXMMfMQ+I6vm+Udw29aBBM+lzQ2jGsR//wkeilfE
# DATA sr4ZBfjpvhC6HgPS09mn4CODbvmfnP8mnunDJ+asYxyHMh+EBPE77KOZ0pjkDbTdWPhUNlYuW6/hzdrjrmDQcrJfv71QBJKS3pyC
# DATA snoIPSpnQ/IHGllc8IDqjc5vU6nmk7GN96Yr+6A/GLhQjLqVPHOabUijW6ZWMEk7TqZ22qePfP00mGLR+vox6tCBHL5WcTaCTLSF
# DATA +wUseeKYCVrywKhG5m+zfhxxMWvfn5exb5LsjkbTjmSnJTFtFVaR7U3F9UhsMiHRjCD9e4NVLp7qtwpzLWsACeh42J82MhU03ouI
# DATA sKpVWZryqN0rob2vLD+MghTI7RdyrzjqTj5AzTq9ROAphDkRs+ZxG/HmxHRX0cHrZ6NdscHFoAHdbjx6LF4ajNIUpm/Q/yCRikpx
# DATA F5tOusO0D8ceXixdzaOYxRdXOzIngKWrZKnIcKFwEzqnt+iGmDWpQ4T+KFWhlbMdMj30+pSVc3rYRD+KhkyQQTNYprRGO8NMvaFd
# DATA o6k5BFg2nhVRybWIc6aKs7C7O0gMLePGKJ025o/Tyfxufzg/OYqq+5HXDauZLBUdAitVj+ECZKjpDG0lesQbGyqmFNqC7OGqL1Vi
# DATA Xinqckx7qYZ5rq11ol5C4gUUmmSr0p+HjzKKla0zcc5gBSiUJz15QFYiiv0VXeMwhERMn7iH87fHh/29wwbJTDX8UpFSmZk4SrxO
# DATA 2HyYfYikIT5KsTbxo/wEMIb2mU5Iu/uPRSFsoRSLL7aZQTzwTnCu0D7q2aG5QXONfE4CzrR9fzz8oYaufCkcB5TK4ziFvNI05ZaF
# DATA Iqdd7mdOjYH6Qrzt30MiFTs+fctBvZ+xj5TgaW9K6dmIavsjhdSefcNzKG0hanr5QVXMkVVEEKVbSDyyV0JWxhoSVWrGsDhQ0OHa
# DATA 0lH6UxwWiZbqIThuuvG5NBfK8cMfSK+fdidHHeC/4EHBpIpEZ5+B5dAhyKDPYjNGqGkLHH1B9E9m/UuCx8j6ZSoxkC1A5wYqDCkE
# DATA 16KlCOQ4wcEkzugEcEvRjxdUFYOozw74BsvouaCxe6PBgHGKqlU8jbFvxNurVcF+iOYaiKyoGZ34DU8YSMwxFtRz0lja2zuedPfQ
# DATA drEI2jLaODobteRU7XIw+YTcacYLsBDGG7P2jyfbGBpN7Ky49x2J+Xp8mAwZrp2Dx7r9gaG5DHfG7r1pUs3hEgV3cRbJ622LbuHs
# DATA hfwLsXmfQxTppzZtn33+ZkT+SejT/KW0wGaKMMgP+Af58FuoAsyk4BSNHpAWnKvaGaWyPV/mkcQQXLgHAOhN2XS+c6izgoBewXeZ
# DATA lmK4Q4gLdkP1aLMJQNErzc1CGFpcDQ0prfHX1mK9rSCd5LP6YhvUroBTH7dJj2j+brJMWSuzTAoW42oW2o7ZfJboq53enp39Fh3c
# DATA gYp8y/hXSstf9tz44nmx7I6ADj4EtcFo7wPvXgaO8IgEMuQbpPi23lnebC5tRx/Sl82V9zbl57X1t9fv319/z5JUCP9eiI2T4zEg
# DATA ykiYj/0J3F4cx1ZEm3cwRFbXtk0IkXxIER9WRALp6zc6q/fWXKXtT5KT3ZEQj1ZlT0vlfGSTC/UqDHRizAobvmdfS2GZjDkDBZi4
# DATA bYqHJfhPhZ8APkmn+dMczbQnC2pcrxe3MHiTmYO5EishBgUc8T8MZ30zm/99i6AC53+PETfEK8PaqNg2e5jbyTB8XMyekYMZEzY5
# DATA mK0qo4Npu8Bg3n9EtdqvMnVogQFKiSL+U7MxUKqXavcAXBG/IxNArv5/ceH1O7dvufr/NxZexv9/L3+vvqIu3pCBenwyPRwNb81d
# DATA u3btPqfuhlw6RCXSSa0G+4RTfVMab8wRgKhqkBlgMjo+OESJUEnNhQ0Dh90UDALq61F3jywFgJ+Cegw4cuhH0PsCwMkmxASn03cE
# DATA axxcBbyAECHVZ3C1mlKz2cYH4BmWtQEbO54MRFu1CfVOtsmdrcDPcHDMqQ4Q7zFa0Q4PCPEb/IVRw+coOzUa1Nle30FXfyHJGVkG
# DATA 5pbvr8KNCdccc7OTykVKGPHc8vrathDEmpsAWbW9uX4fi9tiCChTJ6NBPLfV3Hx3dblp38EY6w0pRqkR5x6urW53NtfXt7VsE3IW
# DATA m9t4uAlJMCCVZ0ad1UeLouXtpXvNLQyRQi0G50fpjR4PUZGDkVKUppHRXClvRMzJMU/4BXDm6A/FUjL2a39f/rInyHkoXijPPVj6
# DATA aef++r3O3fe3sUkjbF6pbSkJ02R0IOY65fwyE7nSgqAAihDx4CtR8kiHx4hdsQHhk+lhtAsmNrGPxDyMqUxa4fwYUi6VYnSK1+Tu
# DATA 44jJUEaCwx6j+xtRXAOUmp0+5EzEB6yMoiu3naLCykSKHi6wfRTwNK/4PKtNjIR8rJ1hFw7RnsxiLTsh9Q+6UJbCxqjvIJGB0LzQ
# DATA kMUe5kSnxeEsVLTqBMcOV8yk52tuHiLd+Plx7m02t7ZssdsZMGUZkeuKKgU5Lidr5XAEajGMAIX/lAL3b1mNNcPaasCSDwCIr42m
# DATA bwM5ONFkRgVPY5wl9M+h3BT4L6pTk94SQGWLHsGNGikJAMkRa5yhXFIDkV3sk0f9EeriZAMtrr2t0AvgJcEsxJZKMJEL8CBBqKnU
# DATA hgD+Hnk1CYIF86H2hYKN91jIl6lCKqA1rYEB+UkJW4IIWuup7FTZH33LGEW7JQuC69NR90lpoYJLUXXHomemXfaqrBFnob40eEbt
# DATA 1xqiVk4FD9sY1xCc0iBEYefJwkJ158ni/s6TN/bFhx/utznpGJYtizvozYX2nD0IXhjodynw9EbUehp39TpiTYBGT0yECorv+O9p
# DATA u9yq3rxdd9vgPH4waNGMqGgulPsOswLyOyGfVqrF5W7k31V3GI7PC2zHeCznaWrDyVKD+2X2BnV4nrFR7RuGulOYHlbSm6qc3cfw
# DATA TkeyFc8dKnb2k9JejAcJR1vpCRsfIto4e39ykZgnGE55SnGtOmKzXp+relZuAO0H3/BcFs+HrBiaaC51c6+ijkBuPzikuUprU7r+
# DATA ewB5SkxdcG79Nt7W5WOatxbOW70dTHSopwDdUUq83dPjo5KqtIUVtnPrFsyhNJNHlP1kneicoTrRiBbqQZcPd604l9YATYpgeVE+
# DATA c71+Oh50T6IuRtR1IcVBdG0hYrCBazXX/yCfZA2vQC8ZrBBVDVLWh4dHoPIgWYW5gsxHSNY3okX5w7KYeuA7g2RYonkNJcJA0t2a
# DATA YmIKqyynfmPyxws2NuEmRkome8TfFhcWAu8QAVDnrmOZebMVt0upcSwaW0Y/piwWklnWwyzUqTQZdMcpZArB1RIvWVRZMtrZF+SQ
# DATA HlJDJA89BiIM9gSPr7I3AogIP4KObErqMtqVj8zj3j9STgU73xsIUrDkIcPJUiqLBbEQ45cIH4PRATN99nTgMxeyjkKyn0BOS8lV
# DATA MHOEn1WxaHTl6hAd7xWCl6hO11IgndnFEpixDGhmbVHh9/u9sHr1vc31tfvvS52qpWxt/nT5fq6y1UMoUKIY8Ek/z2TdZayqPATl
# DATA QufhlmBFn7lLpRevRnBFMuxSPbZSdJLfr/6FgscDgAOyjJWCNgsVQczI3gCSAO/3XD8og0tp1ep+j+P6fbrsIHWX6ALEdyuI85jq
# DATA IFC+HJG0U4pbICNQZrrpZB9P8Pi196uvHVVf622/9k79tQf117b+JibXvtrBEZ3xKEa00SuB7iGQdAq+UVPkJRGriNr4eLpf/QFE
# DATA o8LI00bMbh5SBuE+Sc8jf1iMxsSUlhj70yaaQlS5tLHRXFtxSTHTwUpNN2hUqad11wE+Y/5jRnIm25CE51bKaUhHpTw76Mdy0ZrF
# DATA DRzCJAFxD65M+RRmMDHK3CbRrTxWJrdF5hTj5GRyQmaA3+9M8QaBnyw+y/wqf2pMcZZmSCpNjNGhu5u2+FwRZ7fu4aBRebi29K6Y
# DATA hqW795txJguWffGXZpbpa3PF3AWS7vX3NYSGL+ZoOJGwIhj0ZK/ykeABDIGEfoOAmUHlAn6DjhNKbauzurXZvFeSlUisjcwolgKz
# DATA qG8Ax8O9Ll00zPoZ6sNSbNlGOep9miQfSIHGe79qv+8MEdRTDVkP3DZKdukAjWYacPJHTMHA+KLCcJDjNmuC/oj/gjF5ik5vpV3k
# DATA 2a2bdGFRJVp1KDYRUluPi4AATIXA9ZvrYfCwbFaf05tk2OObDEwy5GstTeIq/AGjBkSDqH2dsd2jnzTfx59i8jzX87ybHPSHw4yK
# DATA 7jbvra4VrgrQC6hPcOQjoIeuHZRv+CN5Wgi54Ef6V/nMoVeeqLi12VxZWt5urkRGH9p4BosSLa4XsJ3KrL4Q1x/Bo1KNaWXtef5V
# DATA AkL591jLoEW31xalA5HX74sqANT1ycxe3IieyhYp92VFcUbObCq/BjLWsZhDyfwMniofyUs/aJWhKUxBKH+sHQxGu6X4ulRqtOp3
# DATA boO+CAupUsGWUyGheG/fuqmhw6hJED+58RxtAoK42KoEfMdjdYaZFd+hK48hxuOxHuB3xnyDGwmZNbCKlvF6u1y+8ovyvpWb3pDG
# DATA +0nelAQPpFDK4UsdTy9yRGWdOpnnVc4xxPgc0/7wOJkLBLoYSaCz+X9B9mnejggtFWmzBswZ7kWC2/3tTnq99FY9eQLGsZ30Rvmt
# DATA EkPCdNoGekz7elkUbEDh2vXyX9p5n8FYU3tQrod1PpqzEvf5EOjksSD1D5GvfMhS3oc6MPJDwFh664Pk5EM4MkFJBjHLH6bdwfTD
# DATA XorQATCY1mIbW17NmGW5xajwzbbh8YZJrneu7cRxOfiq6DgoRLCGcvRXjeh2PTNAyeGp9I67pzxB0tswVA2iiIxAm1F6Sv1H9Cf8
# DATA BD8xdw/wBWIDeAA5XT9FzMjGAPLbM9IL3eiNvUjnDfyjfOqprYpxCLVlDAof41KFX3qrf1QudY+nh2KL/xxViYJQWvVGm4hrVxBA
# DATA MvlQLGR/rww0trMFmDSTeGfRqNs8VN0WYm5DVNa6JnjWWzu7FnGK51vN5c3m9ocbS1tb761vrnyIWVM+5GOz85Y4Nz8UBVaaa9ur
# DATA S/c/XNpYpWdLD7ffWd9c/ZslyC5UdivlxtRgyq2/3ZnsDNs34vhiA5gtVLR20p2t9vW3RKuzRJkP/7IcVzKFg7xu7OwmJ39tDNKE
# DATA gMr6vhvbNJBXfwlgecTrbf5X1HGjVm1fr8/Pw9Sl8z+ut2/U6VP7xo+9Ofxxfu+fLO7utFoL1bfa11tRdV7898fV/1tai7z3JKTX
# DATA 3mF30t2DAGsE5lHfxH7CkqAgNR9CfMQ0BrlNMCn9Nm6mWzcj8nG0fnilES3efCNPZFUC3QpfFyNOfZlS1Hc3nRKSey3aPkyUwtZS
# DATA 3ZGmEjxHCKsd3SpqAMPH8qCtpZY3P3EVlh8pAe6UdMPwBkCOyM7CI/n5lC+3A0DsnXaUI0qH/VRK2gK/SUbw6Oh4Ct7H0X18BTHo
# DATA K9DPoWBHU+wweE+Qk4D42p0S8Hw07R4YpvfxKO3zVVlHe5LIs9l8sLa0DJmbNpsb61ur2+ub71N63en0qDucV6g3VdVd136WiY0m
# DATA 6Hze+Q60qbpTzCi+2bzfXNpqqmhPadZjp5WSVjzFMp+ROOlqB0IqOd4Fl9p5bHH+qW74dF56Bs3TWryl3Do66LrReOp66Z8aTvCE
# DATA U5Y2nsZLe3AOgVoEHDggIAXwUR8Ne9z8DZRoK5AAXdRbXWYDYR0E8uoePIsDMbrxQ0GF1aUDTi+tl8C8R8Sn9Kbh+MneOyXl5GGk
# DATA zAAhbJKk49EwTbwbKD8nmejm63fYkwSumGqt4fgTxcEqrktcagFx5m00E6jYJCrjGFYpagH18jIUI7YCjhGrYVSP7gEqtTQll5xW
# DATA RQk++tlXxCHzRzs9wdPlf4BPdg+caM2J3WZv0t0HW0s/xfowQ6VXaCxOdJnh2Sp5mYFzXgcYC3ihW2Ff/IwZkixJ4k09YyVMgSg8
# DATA K9akiCMX/y2/JabHrHnGIN5tbm4JqUEp3yZ4754eC9ZdOuqOAVGV65Og55AQS6MkDU9K8BLQ6eLtN27/4Nad22+QJQOeipMIq7xM
# DATA X3juqEs3otJCpSz2Qel2VMXdQfXqsFnLnaaea7EJX7uCPt2oCZ9kAAqzxo8DhHE7A3bu69YuRlxpiapbaBq2tiGfH1MVy//G7rUQ
# DATA +cNEU3zzmm3xhGMdPK3sSXEhSgWlNPLzhw9XV/hVFC/wY8Gd9V8eNre2s/uVikdj0w2lIyPmj8SpI79xrlgFBVyf4f3GDhABJ7A5
# DATA A3dbfLdNZGLMebqn4grxh2tbS283OxtL2+/EVo+K2TVlYc+q6Xv16TlTlKQny4BmpWeoPXbRsHT5bEAsg0hUVRVUU7mWTKMh9bm1
# DATA 0HaUfhQsimY5M8u2eqNMfH1pY6NDVykUq0MYX+Dp3IhoJAyfZeqTlKLGGpsRQgF6CFvl+re61QZcIfYB4fPpndunUtPAGgZ/SFIR
# DATA gDC5lAfIAJBlNkKlQe9662YuET1Y3dpaXbsnJ4BPZdBSAObrUXevNkwec3UK/rcSsddtRbpf19LDrpA8UBrr9Q9A9CsHfMey6b4i
# DATA xHdSutap+VMHxVtWBDRVMjdu2ctjwCtkSH2piSDILsYKGbwlAQfBPRBDtfXKgfMKoo6xI7vgJIwJWIofjQbHRwk4ArcsF0HlHdnC
# DATA 10kVhZ8geRPV2N8PKldKxhbAksycKY8TPJAyEoImouuX54ANLKZo7UqB4rtxy87Kg7wel4VUcrNdbhuaHrUNxeqdjOHiFe/2hybE
# DATA IwHCMbMpa8DHut8ku1d3IE5A/A6s6nQu5L1gehnAUdGSHWmHojcteuemOg/WH65tQ8Nv319d3g4kQ+PqHcMdrp7Ue8lWQ5RuHy0S
# DATA EdhoQE4J6t1NL2mVnyIrD3nGi7CD2KevTnIp+LSji6BYlX4P4QjYybKO5tyL5n3ipeO827KSKEZNLH899QFfAXA36XX4IDVyyUt7
# DATA dDkT1YIDtkszMF9BSSCu+EDYkPI3KhF/Qb2BdOuU6BYuFq4DSOED3qZ9UEyYGLcqAIaDX6LqXTS9G0Oj6IrQuNARhCJi8SVzduAn
# DATA 1HF4nQLwDmh6NKyyZ8LOkJ8hLK0Nx1sc6yJEujryYj7igI0KB5+7S+uljtTYAj5URoXwIwwRJP91haERV6vD0WPxgXtz4ZomNFOZ
# DATA NchLAQKkCAkWdPLTExYYDcnF0AABAC5gng2AY52ovKeCF+Kh9qakO4jp7PaiKWDH0LGadMWRjdOtdECZIqZKPJB9cOakIbBETSmb
# DATA vpCAKbE1qa0Ao9JxGVp6NMFecwUz+YxnXJwDiSk35olr3LFbN6MfNWwBqBHdXvjhHYVZfqhtCqwbJRzjnQlC7KA+CNzz43b5T0hu
# DATA kikbfBlJ+WiiRqquYrI7nb7YsZ2O6MJgn2zLZsSyeFjLJjtVRF9x9BvmPUc1hyIXtuU7whv3CLNO99wzKus+SrjfnmrCmpa8+vhd
# DATA Jz5Bh6yTvrTn9xkN2g23167FndOyO97ufRnaxdCzIASAlzZFOLHhP1J2cyolWKvsTRh+wiK8tfXtzuqauIjfB28w3bRUE1HNrZi/
# DATA B2A6vBJ6WsChiwlGqinBDcC8D8+OF1O4c+BMH8o4JS+YOLFEOZ4PQG6M2BV4Okn7QCSXRepv3ZAtMSVxDiixr98YczBQhiIuVpe9
# DATA m7ch/QgUL+a6FVZ3uJOaudtKMTSF48OlccNcwpPPU/FdL4DTsfxVYDq23BDVJjV8ETVdoy+Lv9U1kKcTOVsbYOIIo9qy5XcNCXHI
# DATA sQCqcByZXCcP+AOwuGJrA1W3hLiOIV3hFeJVEnXacUAY5ijm7DjBC5gMeKQLnhF/FFX1u2YgwQIoHt+4uZARpwLvcNwbttiQ8ZPs
# DATA i9EQFLrd3Nx8uLFtcSbVZRyZqIVgx4UEVVf9AKRwM7GASXhiKGZSAx6uunegPewAVDOxAzA+O0Ay3DUVMGUZF8ccnEJrfmocV354
# DATA NTPRvcPu0OeeqDNGAkBkDzIhgMK4u0eYOEEOI39EnanBOLOCufLkuo0VcBC4+3Drfc//8yQUSEXew/4wa4B4eSjEt/7PE3MH0rjL
# DATA ocUI1bKC/2S5dGYPxHB1Jp9O8lE2N32HnA1pOYgzK1pSh9xFTzYdqqqCi+X9QqIsGVcOIbMfTLq9pMDZns3hkeEEOZUYGiohzPmn
# DATA gQqJYvS40+uniFtmQS15A4EQQtlPZBfQIJHWUXcoquuRzQuJdeY4NpbuNTsPVu9toosJDmd10+IJmXsAvmbsAPrpO6V/9iYvfHLO
# DATA 3jyGOjAUw50Rn+OfvY2cszf4smaZeHCrr9leXRcWORwGIdufPbBLHFh2Bc6p9aOcU+tC61/8xFCObK78RQcFBNRRmL1eh7rJeozF
# DATA rWthW+vr9KyYsYjGnLh6N3tPBiK2nfwamRSboUohLMZcpELWqVUR5g3AAA0AQxOa48CSssNaSPGeAjHUqi2qUP3A6EsPuk9ACQY0
# DATA AAVc9Ry+dBeUP6iUy2yPQergVNFiX4WlU8iUlUy4fXjQ78WS0YpHIDqo88TSLlmOHiFiK10Sq8oivBmCmbgubm53VAQRy0sNP9Rp
# DATA LuzuqU6WgqJ6oOAkrvLNp9p+euvO6Q4XDEV1XYCEM7a4NWAn0EQGQwFArS0swCJbssIlBYQrvxFeiDVf+hBzDuVyfcYF0z/Gitwd
# DATA yejvgRiAfoSZXpYIaj0G90BHLSVj2koFqbTsVtjZmyQc/YQSyWxmSdF5iISiA/6M/QK5bdgNsdiG8Knb7hewlDALaKlrUJtRncT3
# DATA ckAgyYwwxE0j927DnD59cim4b2MJDVGjHL72XbHoqmZfy69yDnRf2iE55Eok3heSfK/8HvFC4lvo8FBi2IvwZHKMCkS4qrTxBNja
# DATA Wr6/qsfmp1+lE1eqKhHXBnxC43bOaqI/BFdMa5lVL+5JU7mgPrfDJ6EjG12npC9hmeAEHApggnr9YcN4c6X57trD+/fxF5AL5P6j
# DATA fFPqa0iEeGNxYSEsg+ds6+X1Bxv3m9t48ttbuxg9aGgZKU/oTOkXjKO6nITT3zeZYJicOECeYAJmT5EMlxefpQhyKcEK9/v6RpP3
# DATA e1DgYM5kgHq0A3hABfaYZW059vSZuWr1MPZP4KKVATKCusE7C27iGswH0CHtJo+T1PX2/vGB1z2dO4tTdiX21HQxqWFjhrG3nzI6
# DATA un1ZgS609U56vWxkTEJwnqDSDVr0CQ7weXpCDIroVqABegZJV/QQ4Mx2J6PHKSQnZq0FQM8ABUyTwUktzC2z1CGZF/7sHwtZWbIF
# DATA N4s8ApYYMV3G0tdz3UisXcSw9eydUkCLDNp8uW0aBqGW89vEIaMV0T6d/DxOx5MJRx7CO9oseMEQ0XJWtUFd8vXrnPMy7j4Sg0c3
# DATA h7p6iV3L2blGdUm73XBB/yKrcM1EIReEzZCxaFJOTbPfnrz3QLIpN1SODMz3PWojOzMmcux0Sv3hMAkF5eJzjBNluANylZaO1q4N
# DATA l3FAEbC84oOQW4A5LkgOTOiNgNwSFN1dhG3dTwdnW7RWQkwpmBsSLozf1+6Wc7ViQYFd5iGDhoWotbqeoWWy5y/3dLOm2aK6QKf8
# DATA 2w2v5RP0GcC6KtH1TjjAVTd14R5z+/fxfmkdaEpLL30d/Ls3/dJBV/6KcRPXsRToaFLJvJpfXuucoXaZxV7DhuxZulxLQ/FC+sxL
# DATA WtrzOpjZuVnogpcagHJsolUHdx652i7DLtYUuE+sNd9rbjoNvRqtDxOFqYuCxs9GYqDdAfDj9Hh/v7/XR8cuiOuTMYoQogVaB5iV
# DATA rrjAHfZTBLXxQtFNoC6T4zG6gsKjlDAL9eI8jIndgulqgQuUgXJZrlfxCdfezgwBf3Fkr3yEr4J3hox6c5TuyvOVLkwhRbp0fdXa
# DATA dteflVlPeEyXUsRnSiLfj/o9S9XtqeTDDjCVTDX8TJ3996OaN7Xyfyoq+EIy7lUq5Gc4L0HAuVXoQmr4XAK+KuW7oXe/jMbd1Vtn
# DATA negv7HdWCJs8R2fdH+6PQpp5DivNgwvXkUiEAFS4jvTwgnpu+N00IYS06zNIrnwlinPsBWvPZ5PwFSvOO2EbvaHWJCo7qBdUx6Gm
# DATA SavYecqSHjFfVqtjb+xTCd3AgPQbxkyHz2+KUnOzRhsgAuvr2xyPY3FRXYIFsb9ev2udkyYOAQYxd1bX3l7vvC02ONcHlF3OjCcJ
# DATA VNBc295836wBCdtx4HKWic50WCSdw2HuQvd/e3/aORgM4tMjN3NFnP2bTtxDuX0+Pf8V5uX6CL5aHgwZ9yKZErCRAzNRSPFMym0h
# DATA AED/qjIs3dGVq8rbGFHYgKjCIiE/MzXWSMusrsbPobP2h1mqag0yoE2JSD8ZpdEzvadhAlrEC9QGCSMhKXdoej1cOZjnSNG6f+1d
# DATA mZhGL9NT9fG0zoltnsoKT1WIh3iFfwtv4NOd4TUVApDdj1BWaeNg8gYU/UhfhYLtli/k6iM3JlyQNptLK+/HF+nKha5ll7ieWQ72
# DATA TAVqcTSrfKWhV++Sjk4mSEOgdWRTXpQNCAXql1k3o0s3/2p0l7TK0B6l2EVc/KPuCVy3MONSNxomgBs/piwxOs9SbW6mdlbRM09o
# DATA I0xXUkUjS0kyUMIuVpfNBr8j7vzPmhlbOdYgq1wdcnVCnrnPz74+/3VEJ6nsNaWDKcZ39Q1mtyskq4pxdBlWTAnwGObGpnHw+2LL
# DATA mfTsblfYQuFlvxBBMzZH58Hq1oOl7eV34hdZZU6sBIv8r2e/9bOlfoGZUiGd3i8phWA8Y1FnXteKmDxniXqO2TVfyAtXnanzoXYD
# DATA 2U58p5/8VETlmdW72XOc/A9GGh3XYXN2Op18/4KwZcBONAIhcWaOomCvTzPE5UsYdnK1Ud+pEfxVREnjqwdhyEAQYYQa9l60e0Ix
# DATA puNRfzitRRtiEiCQONpARcv8MJnCJTtQKysbIDp1VMH7jWgj2huNIa+ZUnT2+t2D4Sid9vdAhTkd0fmyJ9OiX8pkn2GP75gQ9sXV
# DATA oMZ2mGn6ujQv8siffJu5ZcLh0IdSofD6DJ72TSZjk0nL5q6Snj1aRsU1LQoG4G+9v7XdfNDZWFr+CWRMkZ5N4iK48XA7zhtpMG+q
# DATA sQeW8eTZsLfBsEcE4Bjp33g9ryWc/1kZW41jSiZs5VtvUGF1KfUeT5wb8OYkQr+cf0ghCQquU1LxftRPxSQc2OA/nkops7TKATPs
# DATA P9lC/MWSmeOytn1IKREPHvSfrA4rVgLMGr6EvIpelekBEBigM8VXU1M5A9pAsPbwjnNdXMRpMKRo8ErU7fV4v6fHY9ErjARRL5YD
# DATA 7wB6C99OS697NslA3Qo+SvS9hDH33BeaEs4fWgqnFS2beQeIHR6JOkU1rOr0zKvWJiREgvHgRMaSiS1QQQwx563dUe/ExtXAQurG
# DATA GbBHJMNeR+IKlqBUViECUyzFywShWQVADJkRUwIqBpSUgQosiMUKQiwi2kJctOn7yfBgKiVuMGbBuF1/U3xdv52GRv8YDdMkYmAd
# DATA 1pQf4uJl0Z8ZGJ9PVCYcgBbPCLehCPJ8yBSNsAIgmnYnSYfRArA3PFrGRzBBiQkiQfznLgIS480HWyhnW3bx3EPKu71wCwQsad6K
# DATA 317fvLu6stJci08LqHjl7UJmIwUfzXvNbfK2xV9IzQz5YkmOiPPt4bpjNwHTjOaNfeHCIbIF2qd0BCkIPqV4HpTcFNo/n+lnm9cb
# DATA pcWGqskK69TZvtqeHiSZHZXojBn9oTfbEt5pPh8XnPAT4XZ487uLIMueU2we0c/p08Llp5EIjqN5L94bCiV/wdYtd2SKgr0U7Qci
# DATA jwv2bGN960W7NkCOrCjMYEIdSODoc+5WO5fEuD7CllZhnhZv2550h+l+Mqk24XCjWEFWv/HbgjJq/VQwx/5Uq+YWoh/BraWky6DK
# DATA 0gbJvTJiZpxPAwGRVg/PHYT9dPpSznXHMERYqFkiwuH8TBkv9BVwgUC8E4yLZ1yyzeRRH9ULp9/3lg0RJvb0BYkTN998d4/iKf88
# DATA qfLm63f+jIgSViyA4aBDw74L2tScmuP/oUMt2Zc2idFWrJB8pPvVLk72Ny91NmQSOYmFL8n7PwN522rc74mwTZr2bDNXQcfZMrV1
# DATA ObhtXQ7AdPf2+sO1Ffdy8J2qRa0O/ZA8eJQCCLaT6VtK+p7b4pzKUyPpMV1Cl+SuozEXvVFHyIMAD2fdMc3fgSeEC5BaRTrm0DL5
# DATA XvNQSiECGq8oqD4kYeN5GAvQeTlk7XR/x6+l2WHLjCm4tb78k6ZJ5WZ9lscoetyYyqepVECRi05FqmEIcx0L1YPVSqDrO6ZjAiuq
# DATA 8J/O/giTBWGC1T74w3NyTaCjTgekmE4nllmPJyk6coj9h59rS5ODY4Ax3MBfVKYtsJB2hAy01+mUjTchP1mny6+UtIsjOm9uoAac
# DATA gYbxm7ifjcbTeeWyKS03wcrMk3bvcATIxg0COUbxUDtNOsgGCJMug07FVFQlEiaWlaEl7dxhyDjI3EKkPC+/mfX7oLubDHJ+RzNb
# DATA fhPgDZpdAapNc35n9N6cEoxLyZ3gYFYui/9Aaal/glBVPEyT4z7bWBdcdMktdPNtPoG7+OYx5bshtxLa2wq2GnKFAK3opAqioZod
# DATA CqvjgOayzBv4Fpk38KOYMP6Eq8OfcSX4M866REcPt0sUZOJMAvC+2xQHP+Fnnmn+xrOa34hHnRakmw3h6jZdqAHeEbpaxNbUdZVr
# DATA 6LAqpy2/MnOP5dSo8SfwIX7t9/TahFDpSS/tVlWe+4uXfy//Xv69/Hv59/Lv5d/Lv5d/L/9e/r38e/n38u/l38u/l38v/y77938A
# DATA F12LaABQDwA=
# END_REMNACUST_HELPERS_V1
REMNACUST_INSTALLER_PAYLOAD_V1
if [[ $EUID == 0 ]]; then
    bash "$directory/installer.sh" "$@"
else
    sudo bash "$directory/installer.sh" "$@"
fi
