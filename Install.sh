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
HELPER_BUNDLE_SHA256='07e361a93200e50dab57962d0ca7c10db8eecc2166de42acd39d23b58cacd55d'
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
# DATA tUYPOMCd970//Psg+98o4P8G9393QTvL2/+givzB/v+3rf/7GdaKCKa+OnQxl4Q3Kf+LpYOSyWRJGkfVT0cjqpHG9OSHKd4jeF/d
# DATA X76eU32L5/Npqr5c/iyZqc940c04GaqvSfq7Fwe+Wi6Ssa4PHMzRT6G/xpOZ/Z1LBmN+wsnu3hneelHkMCt5z4+Pz/ZPMDmj9M30
# DATA +/7J/ouj3b1Xp2eDL/YPX+6fnA6+bHwDzfaPnlGb7/vwabCu1e7R3hfHJ3SjOblq8YTYfLhR/nRS+XNuOfjs1dGzw/3B6Re7wGZ3
# DATA SvYtIKUfbFS85weH+6eYjlLKb/AS53mKqorfbLdE3mle9JujJtiXF5eMxYbvaEOWbo8cq085WaJbWra3cuHblpczUE7PXYFwZo28
# DATA XgdcearVMUJLgaMEf3esY5qQJaH5TssVo0RPSAw457tlSuHv4ifDj9pjVap4L3Z/MjjZ/QpLy3fdIhr0CBccnjVzj3Iny6IyLraq
# DATA a4iVuaM4BDjKTkUMiQzRc3XFyZAvN6kSgesydXJbidWpvCvbtiZHfKkBZlSry3LlfZHeg9exum1521tblK5EtabUf8qfbm9apx/w
# DATA +3lt88L+qfJx5dOSipHee8ZB7i8Q5iVQ6eJMmK8/wBsSYnWdhyRqYthnQVdHlkub6hAN5V6MEj4itljOYPNijXEMrWCEV0ovYj2i
# DATA JAN0YD1HrhxTbnCdoop3X/UBdXbTQKNKd9ZKumtnHRkGvJMm4aNjc/sVvPUXcT1M03HZdAq/WjPRpbKBVGjTCTpZIuzYBMaP1Sry
# DATA Dg0xpanMPLLi/8hv3LcYz/TNfLIcozRdxHNzRkl4LRYdmTphNvpalfa+nCeXqcrg+bKH3LYWTyPO3gG2/GCO8YG5nakIQrVQJA6T
# DATA qTw8397EUz3Y/wWDhM+LSigjWGV8aGcVoch4tnu265ekgqK9MfDh3u7eF/u+LQdog6jvreYd7QXst1J5zMn6V9P4zYzvDXFm6ctV
# DATA RWY9cF4ssnSlHCYCyiy8d61fyIWMRseQsYJpCAqEy494Oed4efiszGzI/4T5kdCngtihUXk7B6FFypXzuixJebhR2qicNy40W6Ti
# DATA UJrd6YSWewYAgQLdFIvpDYK3XgLu3G3jZxiuau8qUyc5UNVTJsGbZLKc7CgmbzjkgwU380fLV/H/BWObTjtgxTDMSVmOgznVdDBn
# DATA /K1D50iNPEA6g3UvAfFV/CDDZnEwMWPRFXg78jOdQijLTKDPhkM7JByAK8jzR8BLtc4WaeqPMdPGpZK8rNPXLXCdjPI8sC5ZwOHx
# DATA Bxi91ex1+4/BlXS0Mr7M2Drnhj3r486xiEncE29LbMXSHdoibKpYxd+E4Uq6VscdXVcKr56rty4e3FevptlyNqNsVLWjFNylyr++
# DATA hGXo1Ewuvr2sLYbK0W7VaA6yPmhIFlp04bhb7YU7Zqw7JXus0lP0VFWekv2Ga0sKtz5VyCVR1NFO+YY0dj+YebnCVlSp4rmpckoF
# DATA 4FM5K2ljxUjE1TMnRDcvYI3hp9ntX4KGX/lLUTr/kjXOb0DlrMjR0UeIQwe7CBTVzFmRtRYWuViFRiKijNQW2Rx6B5BziXfAw3SB
# DATA PZjqMR8Kt8qZdeHG5KQyd8ywYE52JucOFwquuv9D32mEdKAY9gfCgYXyzG7IlhN3eEcHZAJQdTuQwsRKeAQfY9pax0VxK1iyiCvF
# DATA S0IZsLWqlCWTsomOHHyLq7/NIoxOz+vqTHxaRxc5o7PlcoDnbbHZI5eNSdrjapUe+wyQw+H1Nr5TlobcV1cWJZEmYVcuEvbt9KIr
# DATA /rLVQpIC6xS5agbxZ26RVxCoeRG/up8PuA4XxJPDEPwo5SJquA9KjogRVvPRjhY4GhP3n2de1fb4YvE1rMfpeZUF6csvbXFMrfnI
# DATA SmWl3rzcf4mQu/RuIXelTXGlqPUkr65mnOB9pYA766LTNcSvr9tbIRtgX+Y8h0z9HiIzxaP1SwXJtysd4CayXoFNoHxRVdZYKlV7
# DATA g1pNafRKvjiGlEI0MKypf2aOdMtK4h79+GOZuYJhG8e4W11+fQ7RBd05ficp05xeT4tdtmhFrXUl315VgesiqKL1T4ZxFOW0fkup
# DATA ztmNcmY8ZzvmK/DdY0RWQX8FG8G26MQYxkEjcvCV+J5LNLfOe9sXBQahYwTSNlhv8jnKkRpGlAv5isy/u6646nqho3BXIH1+lshJ
# DATA fPbU1obdtlhFMmRVk6uVr0v2ATpwa5/Df/D4Mu37dPjTnSStfYbrfHBc5r4rhZYDkFTOcFCur7zhIJr7I2TevjvNbEXsKRVQzizT
# DATA LMQ1zIZOwSRweD5dsFOab7MZJBnYBpYJYphcQariIFCx/FheYYPygHTF1kNc7QzmAOLqNr+IWc4RwZ2SiOTuC10O/AzMRqn0q1+s
# DATA Sele7WU0T5ToZexhjZEnJTNOTVce+eab/M+P80DgNeMrJCp4LOVPuqBwsUa4sFAevyFfPc2Mm1SYstQNHTcDbdbtiFY1S2dlxecq
# DATA 67i7fs1h8+qqptXnWqWaRvG8SKaEAQgpuxreQyIlXS5mSzo3YAiz8gAN8zuKdG/WUG6hDJATjg+JgrxXazpK+aARAXMWzA/gl/Kq
# DATA PocNid6q/BEhVB8xYuHvONpC1QdB0G7Dn6JjOZjdT0uO71dtBLnSxeLbmtPxb2ViZGiVzeMsKzPecAOTyo0VFQiqnbquqC1CgwWF
# DATA rtqGi/qQffag6456+VCrhl7yc/aYgPkJR6LYc0gFUbBxTaauXF/axZZ/U0ScEVN4Iy+j8jwB+n6zTf9Frl2vX6hu2H6hB3gEKphe
# DATA xugdtyVZFV9w60la0hw6UlBgEE3paVy/nKNcYqdQe3svrfNWa0e1Mu3MLQu6YIX2UD7Rn2roQOACG6y/VDQ7odid2D/O26UCDU6R
# DATA Sc6A0e4U1Hd1T1/un5weHB+pgbmyR419oo9x9UmvUkiMoxnqtwKzQsvFnFFnWXMfZMK5mOC7gx5jxD2GFdpuYvupIhG8WZsqbajz
# DATA TE4V0DUL7BAOkaEpq+Ks+neNKXI4CWJk/R5LJra9q12RmFBjvJHbqtO8W3J7ranr1jzWhYYFH29LKx1oJi623rbD2+/uFUCO66ty
# DATA d2dtvLJ12wNOskrvYIhR3euE7Ge62GnqS90Vz5NyyCsuALX+j3TxW+4C3bP29ls2CZ/atgwg69n9rKPivEZwqhshqbXaIuwvENkx
# DATA YLbIUkz5bAyvEt/CGv6kyNsyNlXnGk2PMH/pRjYuczQvG6isO94ozvzNm3qdI12mzZo6QI8Ugeakmro4SffLJvA9V3+JpgT2cacj
# DATA p/uUgWu6AcRZ6+49VBhn5QS4aVwU0llbf/HRaLiMp7G67MbL3bq66nPQB6nvdTeo8pOup0GdAdTn/uzDgAVnALkE10tQseL5NRfa
# DATA igLMCIksoGu+VIrzKXEkg116K1fdUD3MXG+SpIQ77KkvOQx0BQPAC7ouLNWIimguTA6TIZFaQfmi/FqXbZ/g/fXjRN9bTwox5hoF
# DATA xGGoHJhKQkLKxM8Ylh8lb3ZKNTHwNjEKksx3rA1UWU9Zv6MzR9ccN3CKPHKYkOLbj3lPO3Habbe9bmqq/astd2/phDTTZ+9VD8VF
# DATA O4Q2hTTR7onxQ+FNzfSkRplpymn0lr7V9vd/cnAKW0K+gQjff/Hy7Ou7e0qsrDz5vr87pbuWrOA3Xt80Ww7HSXZF2yBDWW/2gLpf
# DATA 9CrJCrqbzdMQrBQ8jE/lQxawZeIlMAW+0s9XwSWV2IHFHyRNr2j2vwszup8hAaWo4+4FvInroRDuiy6I/tdlVYX1MXDymg7XF0hw
# DATA muXRZJ7I7RXmHpWPbE5i/a6Qq99EenYqy5jt/2iciw9FefeANJCFSqZdQSUYTo6szSeLeWxtJtvX4Koeaz0ZQiS04Z3XHQ+unaZE
# DATA L+hwPZiWld9L4YF0pmjNLh2A1gHVU8MYQamq9a4HCgbkaxjc25iw9OjWEvx9dHOkqQ+DhxdktfkDpQ1UNQONSKoWQQg0ZEnWlq47
# DATA IGr0uPhVxrn1rmPMr3RiFzzgkgVK66WmkiZkGWi66gHrq/zF0ogZJFaLKw8XwmDa/F/kjEE+9fa7z/9vNDrN3kr+f6P7h/z/7+Lf
# DATA xsbGSYwVqvxsOaMLa+LIqozMOdxSyzpApwAmhEbQOERlY7Qc23fT3pPuT+n6H5CkvxyKPqN/udUf0efqeSf7L49PD86OTw4o050P
# DATA JEkJGPQ3XF6F81qSPhmniwWY9E/MBba6TMzKT/lrm9b3sVpZxumv4HG+73EKGlgRVPkHBbe4cGdc5ub+uapKOKu/5Ieh36HnO49v
# DATA XCSkWvi8Wixm2faTJ5egiyyH6BXXw53kJnHnTNaA+aguGI477+DF7udYfzB3DkL8SNvn9c2tYHPEyT8V79n+7rPDgyPMgacYrgq0
# DATA zNIsoWpK+tYEk/1X+uOSc63cSjTYXHYt+dJ/XKLgryqEnm81l2bbupkCA3ZYMB5gSe4ybylMJ08XlHGxetOLLuFj3WtEryG4/L4V
# DATA TtBp2hgFwodcMPIg4psa83EHhVcr+mC6IDXU6pHvLmA4H7gJx7lxtWwBcgKLcBZcZqaC6Ccrz5+RNW2aeKv3KFpvPPJ6hnR+SYEv
# DATA c61EjTuRiyyt2sM36D09hylIsbaRe98gF3u0aYlq1Nks6Fwv4kpBVvS1y+UNTheOcs/bkWdg7nyUrWh1XrmwFxQAzxdbvrykom8y
# DATA UsJO6Tzw1izpIBdvBnPP4l3On0IyAk0HNEvJasKR6Mpga1Z+MM5SpnayQDNxicHvSZDFWS3X6+51CvZgkL3Gnp9R8UH03HAHePaM
# DATA 3oOO/J9ihjL/HmHH8Xjkdla8goVz4wR6Fx/ytAB7FwXFtVQFS2vjYGo9noRJwkUNxRy6m/HK50rF9oyNdexPUdb2mhtAC9e+6NbP
# DATA tfCcmy8XbjSNX1JHeAjt5Y9RCa6SmB6wKpzL7UOtl299aNURTs1wnVvJ9a+bJKVrkxSmi3GCsnUJjurqhzt+Pe/IPePSlsplQExP
# DATA tFPQNIKIkmhAuQftPTJ3yZDjY8fSGmrz5bR8LgUtsUgfTu+iyilg4tQNg9kCL4CW6fKPGClRHxmUnQmo+6161QBecbJQ1IjZIoLW
# DATA lIfTfnwijlA9LAmsMTxDB1UcZXrO42SSLNzcTCvDPD82gGStIC+J20ZWfYh8H2wjzh1VN+/xfVt8yagTmpVmHJk107lN4nHER6Hw
# DATA NgJ4c5vf55ivjIW1CAcstZRJn1D5eiG9kqqzGHBhRV3I3EmRUkvNsmjl8rnLebqk+xPUzGAI+8o/9aK+O1vGBtMR8x7zF8i8fVsj
# DATA 2rvDxOKPqXMXHGdFdO/uhYdlq/Qi1/iUsrqv43gmwOHlB8BM1b6h3yxdJr+JELPN+gouHBQr4rSGtGxrSWjM3KMK5He2XnDihvdl
# DATA cuv+mAE+mJ/wUu4jsKqqqy6QkyTsI7Rvi82vHKd+qrLjdjq0hmX9Jb7uPdJ2GjoK6SLVCA/qsT41ES2/VLEuUNecHAHAdd1+EPIo
# DATA B7YmRTWAoUndu8uZKd2u6LhhgQxa6X1cvNtUpdMFcM4wt/dchmcNSYf50Ga/j8XpPDUxJnHuw3Q5JUvT8URKA0fvLdjYZnhLC+bD
# DATA xnjfHAjCe1DKm3ktPpWOsSM5RSNHH646OuH0gxV75TfO7+of7ehNv11UkvNEy0xBETAe3DzR9nrhyJ7YHbCbkfXH87nr7R1Cu9f3
# DATA hiNdM6CAiz94Cfr3fS3eRvA+omwTIxJsy0TxOEab9inwFJ+K8FYVO5wBEVLqoNSud3W9ldWdT6gOr16aSk5n4yX9ZMdvPC5IaekR
# DATA p/pjUdhSlofVFLMmMuswXY75+jx0wo9vlWKbLNYtDvc3Ku3hogLIbwX2O9s7o01lIYanunow3ZquGGyOUkqVb+Na/+AivLZJ9CEF
# DATA fVn2YFyTr2LaUZbrmvbIaq3yvKwAW68rG/IBX7aS1G5ZXHEJq7va6AvJ7P/1nMO6SMPvcYwH6r80e42W6/+t9zq9P9R//a78v19K
# DATA VFXnAwrnkIu82Okqtj8qLGChM4O7z9+bq9tyr/u36r8EO+wlmNxv1niDLd+v1Gux60/wQWdSW+UsF3sddvJlKKzEaL53jTTd+w8y
# DATA U2LS1XL6mnxvC+CJ42AyjIJt54iCZe1VsEZGPkLLEClFkPpzjxzx84IKGSrkzaGqRXAJ/CgD20cpP3J5M83HRMmsdHZLy6cGT1Rh
# DATA Fr4MZFXRH8PiFr6n+eMmOynWd2Fls8rVmpxkyBUB6ASB81goj5/DHO9TJ9/9l3e/5NreqpD3P8Cf377/+fu/fvfPQpmb737z7u/x
# DATA Cvt3/4SFwHUlD4E/sw765a6glss/7TN15pmcT31Emfm7B2dAtcZlBlR6HAuQ/+aBGVDiNGmnb4PzEqV1X2z7ARFpgATKpMFz4s/m
# DATA IqFAloKu4OSbhJYzXGBQDsxVfZYQlJzoqYW41fSgWYKON6SZc8aHe085jsI/kzNCcOf4MDlgS7Dp0+B0oUwytbOg07ndEm90SBZW
# DATA Q/nhwbOA7/4vhVeu505Y/837vyGSwkru8AnLv7//G6oJ//4/weN/pPLz/wwv/QsfGSwooC/EYoFIxxDQEgDmpu6UZQIKJlG3jYQT
# DATA zCfw4e5BmP8LFp7/DRL5u78HqkFYfsNl8bEsPVCKVZge692/+2eYys/h+9+uhZdIBiCsmsgCwX6eg/uiOCNMrjsbWYGlt3qUu823
# DATA sInvNsEeWb7ZfIsd3tWAc9cuf1bKpWPNlAtjdE8Qy+p5+y1DqQv/XajBeJjSihVjwgZ0cR4tgTqZZD1kY8I53/uYLEubG8FCwDL8
# DATA 6t2/vP+7gl38i1Kl6NzVmjvXH4mOP5ZoWImvZs+fiDfT0xdusgPjQ6fGjPYX7/4Rvvzy/V/7+Ac/AJnB7O7lWY8/9uJCbKoA4G1p
# DATA xRUAVCxwbSf0UUXCPnjWsKX+zqe99muaKN8OwT/D3H/+7l/g/37xiLUmVkyXuxD/Jtg4JVPJGmNRYqrn/2DvbbvjSK4zQX3Gr0hS
# DATA c5yV7KoCwLeWiixq0CS6GxYJcABQ3S0QrklUJYASC1WlyiqCEIRzZMtej4+1Y8/sfpjdc2ZnfXa/7jlyW7Lbklo6Z38B+Rfml2zc
# DATA l4i4ERmZVQDZLc9aGk8TlRkZ73HvjfvyXDwPAWvpOdH0vevWfqEOwDKzz3y5NzodAkVfxiOxXDgM+DnNzMFkdKquRB39SWc2GTA5
# DATA pS68Z06J+IqkEyqnZx8IDM5zWUD2YoQYOeIvmBD/5PU/qr//0+svIzXDv8T0I7/ALCCwE3/z+ovoo/7049mBH8BdrqcUY6AYV0Tk
# DATA SiSCAxbZo9eI4KDB1G7cuHWl88KbAQbwk4pNwiKgFkh0uIpa0+60KPY5CX2A5CUtX+KrkBmXRH4r49RawY8Co/xvyBB/wYtEOVU4
# DATA B0qkForOiDozEdaq6GFEtbqhFLq7e1L02veNqMSa2iWcaQ9+cwpcPmCQ8K1WkIf2tCy0j2PXkhMIJ7xxkTXsO+txfuMGvnSiYrgj
# DATA RirBDKwoeJh3WhDx4mFk31VhYr0xHLqW3nnBIwlN4JZsuRtUA1ugRYuzQ9XoH6aAvDEGaBqn3IrqpRafqi3oJnRRfOOMgFAYaPKc
# DATA F/ucH9R8NsqZXKA0EFfurb8tijCKvsoz49AKks1UcZDiYD9Syp+fCmwyHNUcdwBH6uQxOXLnQrWA3q1QTVEqDYz6P2Ov/1QN5G9A
# DATA fFDyXVH0VI8+V2Tlp8iHvvCmBMRX9dWbvxRHER46VyOkNwZ2sX941uE4WQYak3umH7hai1EtgmKy8/FaQxUK0T0heH+uVpJIuyLy
# DATA cVngMnUwnrSU/PiOw+zReoE+F7OT2gnFupvMrKLct8p4Qfkufv15cPBq3LBW/wHlit9EkGkLSKZ68NvX/yzkBqBRuWPnXDCgn0Vz
# DATA R6dSE5HxRVYJjub9vJMe5KPBbMrO6HGzie5R+BaALvOSWH7NQ2sGQgDDAgROgAYVWFwAUxcaFCLV7lDzxeLn73D7/ywKTuwv4+C4
# DATA 9AjyhZoG3vY5MDHIP6aO0l9BBjQ6TpdqHFsEnbUX4w72OXKiCEETxEYn4eVpZXFGfz2aFHd54WMN2xD0QyifeUU0nIrmCLe6rGNO
# DATA rnFHi+dOly7qgXIAYfTdxVShPSY5dD3b37/E4UMCY+QUoIa/AObw+h/goAkKamjul3CjwWOpRZjSCw0xOKSOZTgTYmA2nXZhTWVF
# DATA wXUtqefqy8v3mT9Xo/4HYrBv/if19xdzVtpCOokuSxQN7VQpbgWe+lWHiEk1p+Aq+q42f43/Cywr3MnUsv45aWbo0F6B2+DYpAwl
# DATA 9J42RJmYo8s+2aZc43/B3it56DejhwMlsfW71ggKGuwcXeioLWay96wzRM8pZWR6Vg+TqDsYjE5JB+hPXF1Ppbnt7xufVHZdXd2/
# DATA cGz5uu/2RJpHuOHQW4EvCtzyAu5MmJXxH/C0/ROcrrKjpwU18IRoOy0vFdbl3BehyZ1izRE+lZQwys27rZwldDw0+qk+QxfhZc3T
# DATA l1mvRsp9d0WvX7/+EHqEa6PO+SwdIKXv8T2FveSH2rYxPU5BY8HRbeS4aKkrGE9cnmDApzjXq8UjKsoCePy1k0I51IseBqMU/bgC
# DATA 68VKFYXXf5AqjPsUTPt7bQmNVCl1aJQu/IF+HlbgJAL+rbdUMth8pPLU/SPmQgWNpDpyCyioygSWywBElbKiUv8QMBOJFQdbgSvF
# DATA FOuxp8WKGxUwT37ieLdFi/sds9QUcaw0bc291k1UEtTig8HogBIh0NWnxAOGGOSCsFPeTFyWcbbnMU5XVimAY3GlS2EBEzatFuMM
# DATA a+AHlxbVfi9imi+w0P3dHwIzA2u3NDHy5NZcOYhyOeQyR3GOgHIJ4eTrzeBNvjdOFK3WPOJJQQUmaRUJsc3xw4uRz77L8NppelTt
# DATA M2QMoovVZ3Xs8e8jF7mrbqsqqf3gFhsWqjoXLax9Q6+aBl0H/NL3pG0ObBKhcaZFcv0PqAoybQf9krWaVywZ4f9B6LB5VsjHzr2C
# DATA o2I61QqDo/gp1AtK9XAydnLoE4hErNavqM7P0c6/5XbQDrlue1pZ7k+cVk8G5i3k9unPjD69RebiqRHxQ9hdhiIVeK9fN9GA0ppZ
# DATA FCcnyf6weTAD1JaS6vOstB59U/Nnxlxh9cQUqg7ls9cQNnUJaEjeoSWAIsxesU08UcWe0kYBVCT8PpnjvUvMaOcsVzea9Vfqfrd6
# DATA RZ9DJ5vR78P/T4mL79/y/P9WV27/If/71+b/tztJhzkdSnWhpRxYipFB/E/OMQ6gTcgm6gZrg70VnQLJeTSbUlnEFVFFwGc8HeSL
# DATA p37rjsZnb5/UrX+kOm9+TdPp4pHkOtXbZAAiNyHPuM/AjRkss9gffoYjimw5VLPU4a/ZEP92U8jBQaa8LEPFKKcQWAWHHW/RHdSl
# DATA KVnLosEwbIwi1XqolLJNjMrLdgakB/8wYxvwBIZzt0Vm+k8UDdCxCop7w+ooWbILyqvoiSEPJPNaOmh1ImtRr58eDUdKsO6SzkPJ
# DATA zgg7Mx1F+fHo1GwUJHK4UVCanXFPKIAMdwzbvtXHZHnCV/VoNKbd6cQkMoAjTiHl+JJ3GZ0Ex1U/0Ddt6/7ZpExD5mUlypw/G4to
# DATA FcBb5E/Ze+SfwZDnpjrRI6NsCHOT9xR78H+ry8I/g4at0BCaAMFNxXVrC6b10emENNyRjVl2+2OmCY4YIkp2CnqMm2/X60r7mLWP
# DATA glsF6bO/9N0u1HXs9e9c5wros4GKVTewaSdFAAvpNcwHwuTlk5vMJu/rwOasWffhemRjGxjnWEwQuWaojxHSPJ02dzobT7YerdcI
# DATA 6XjagXfWZxYK/lG0MlJssRyaHpza+GtFWuDmPcK7baZ+LbJj/ne8pf5czaO6ktK981foY/Nb0CH9DuzLsCzqGvprNbOFO/lv3vyU
# DATA 7O9w+/4n8kNEg/2v3/zH2AWC7PBc81WVZ9txsojhUdyy+xHgQCkWpBUR/HOMelX+Gf0Ypmd1FRM0vlR3LVDr8myoB3jFJLgJ/VT9
# DATA 9pOAhPvVsrpUNaF5Vx2BPncK5brhFOLBPYDsGehUhKtspp6gtrfG5cNQ2JxVAPbI4QjU6pro5EziCvIjNuQqEHk/7Tze/K67n4zu
# DATA 1BTZXv+oWMS8fbSxXfF2Z+uhV3+pxnVxAgnbDqnSz2HT/UpuSbKRi00ZdiSs6B9RL/mITtX775OBo/TwXGJgf6f2Oyl3/h6H9Mvo
# DATA zZ8TUQOX3OoBqeOE3t//yP67eiLgI0Xp0N4MCqRfgQevekQubzXRwN0VJUB4rXwRQf4O4+SRjseDs45L7egfiMvCi7zDTvUlBYu0
# DATA SvKGoBwxAh3SKCdLA5Xfo3O8X4fnW53tR1ubjz9TZxV/qe21/nB3a9s82Nz6cOvx461PGExVXkL5fKhih3g6bJuOlbHmnHlx1FET
# DATA aTrFJGK/HuknRB32nR1eJMja4mUqYpIkKiKiFE4zdVma+wV5CaKrz6/Z3QB2BRBg9nUC0kvFhQzhuNXiioa1FwV6F5pVmHLC5rNv
# DATA 7XD1BBCCA7ZFHv3+fCwFcRVV5d2Bki6dljmGx1wp2F9RaD5AoO30exLEvRBdUNSrid1EhkVKB0yql6zHzXDdzkzaaG9oIx2iO5e3
# DATA woyhwfDM2tK6jPo+siLUtbRO5omqogmlVLLRFC4oufmkMMgc4KBrPAYAoA34jDgSXXAU5Fjl9JaZsNcr1eFQt8RIlgpVq1eFutUz
# DATA WbmzmPrMearTBSSa/6wo5N+jBIiug7pt+FwLjMVdkkj5zt44/DHiPNtO2plmOyxE08DUFObQhBBBCdpUs6HGeu3FhgJlXgQSGVPM
# DATA z0XkOSWUIZX4kqwRkWJMYEP4NTlQW7MJchV03f8HdDBEX0IUvTGWpCgy16mHdXCG5b9iQGkmuQuf7MWgL9jhh8YtlTGXO8fqWqhv
# DATA cSaeFkiFy3WEpzYXVnOfFGRgfIcP1T0bcC/43k0foRWttUw5aOgJBR1pT3q4+Lg3RVVBE7qI9kc17dTFinb5m5maBW2lht9jdVk+
# DATA HU165re6Scxfub+18RR/KpUnrqkLGceXsKJKHPgz8oAnBvET5Ai/iXAhlSDCcUsgqr/5SzQ5/XP5BdSAjFmVRa0GfcdYPb1MdR4e
# DATA 7AX464ezDJBe4c/DSXp0YtOoOOBCZUvBeEUaJ00VYK8UjRWDAZKdbPiyBipZTt4tAWpeZGf81FQdikpLp6rzEJk2if+k9p1W9gpW
# DATA ZC96Pt1/L/kO7AMbaqNq5OgZeH2j3bzxb2JJRiFddgZK7hrXSihBIEU1n3h0FV4QYB0kCTDlKWQ06rSg+0BD2mYr6soOB+lR3sYq
# DATA K+wJXD/8ozMh60TImF3lvWID/MqB2lWf84SPJ6NXZ6T+pn44h7QevegPe+24m/Z6Z7HVu5i5rX3n/jWRVrTZ2E/cyaXqaH5r3ymU
# DATA ZQsn6BrBownlUZY1DQ2p+Qnch6MhoqXpD5dcNCyQIGZDuwzD0Drw8HgJzORvSKcw3Sv9Fzq2Q80PRMIhF1OLtwzMGoU+HvWHjs+7
# DATA PnS8Q2BSTpI/qT3PbyD6/QTNt8/z95La3p/cU3u1di8pQEcKbwgaDyczxH/UWcIFoKmjRzcRc4/+vrVPOy5kQVKiGHLDFeGwOpSA
# DATA LH5uc9yHAikGQBLAp4LwHoqAgWSPp0x3RAK+6SAqilPHfVGdwdtcfB5TJCpVAo/4b13Tua6pmA3HDa4CfI9DCrKSPaHvAw4nQ+Tv
# DATA PKFUBZ63c9SjYVVurDf2/D3jYdHETQMNJFHDf3jhXW5xHjWeG2ZrL+4dmV0wd7SJvFPnc56/A6YCt0vgEL9AAeKXICugkPAlXjN/
# DATA QU8+B2nid+ir8LmSKP5GPf0NMp1JBjESGVGQe/ISgxcZuMRQqAYqlMybN38dl4PRmXSbAKhTj4RapiCnEUsyimGrhAMC2Lb6JHMk
# DATA 1WOWMKFyk1uokLK8kN+nqBxFVmb0cdg9WeWeamsf0VONJquQWQxzges089gENl9IQAV/lZ9/ji06IY2Xp5g1eo/333+/vAEEYr+Q
# DATA K6J6rzNr9vo6AsSsB1OPlpzrwKothWfF3BOZiemGhi8Rdgzs4yhI1m02DpsIb8Y+kFiCpGb4kMN6ETi0SqYsQpSZOvfoLwfWdc/u
# DATA NdT22g7BjQA/0FoPD1aMmQrhiuEkEwcj2E1PdtGSjzaJoPDTn4yGeCOmGVX3hill484DElFJmAPPEwh46nMz8XtagIclQV8woXvR
# DATA xI4vM9okJHvkT79+EQu3AlxK1HIWlpX6AvIadMVm5dl3Q1wWk/LE0QZwDuo+6z6x3UDWBiykT6iV671rc+DLb0a7x5niuPk00rsO
# DATA TlM6mx6PJn116vovMw48HGan0Kl7LM5SNiGye40BkHU6GhVzbhxq81R/WNYF1KRM+keIv9p2jxcuiNCim8A+Wve6oGu+F0hg/MB4
# DATA sRN7jdV9AkzVQnCZQE2Cp5GiVYu6q0FJ2XHeCNIZcRewNZ2rZlq0bhcuMKFd/vItKsmf2x3+Zs8pv49O6VCtPqRgE8BeAUFn/EDz
# DATA 0M2DLtBHYz5IBLKnGOYP1K5vYBCq1ZDwYxQAGSqQH6nD4QWT2krsCaqze7s4U9DcYVznZFu6l5rigK8XHEeedBoM3ul5IDDGqO0Y
# DATA hrFjiXBSd/2N2Jhcg6J6rOxvFt+IrSu+BhvsK1loMh4N2BsMn6kFaKAdfMbuhQ4wp9S9aK/4AOrhHicI12qJenRD6FpANd7vovGZ
# DATA 8VHc9+i4u6PJJBbY99pE0lkkv9IBnMYq6e2+URkhGp5x76+g4hraTSsxtSsTRCfjggl9DHwq4AR0O3va4/dgNBrUJFYc/02D3pnS
# DATA KhjCwQm39GzDVkGhBol3K9LN42ctdONQ8kw2hj9qtI2kLU+HJhtrnvsBvfb3+YS70DKDsQPOecT5hZA1oJNADFmAhp8Wq1NTV9ob
# DATA vK0/9MVAT5pB3l84WSADWDln4U+YJDS47ebZySAu9q9WUQGmfWxOX8FhICM0jhsdZf0SSSHnbIWHQ2AcBWstTKfRG2TgolJU2Wtt
# DATA mqu8r4M7SuckU7xSPwBrOsqo8jcwFf7dHyJIqHxEzmqKU0yy03QwkLdMo8Sz0gt5MtX0G5uT72yM4XmyKsMZ4IwAD6lRJlSnEN86
# DATA tSr4WntxDfX/oe5bvwIL+Zu/ZDvPL517lbkzmbbgVoZ6O1UKVHkutgIY5+mGBXHwf219Suw0O6I+GkQDXcdcVfYTo4IHjSmQWy25
# DATA IO0ejGa9w0GKMI3xURfOdbKgj8wvCL0IlZkAkGNQr36LtrC/j3Yf75QMSu3/0aRnNNFs0lnAamQ18HqnLTwl9gszIwA5n0+zFA0T
# DATA IOj30oH68u1m4CfkYAEq3D+FSzfcyv3xa+8R0yXXbgB93lHvnmg3c9PPJGwvo0HC6Bcc4GLjg+v/56yu/rJqdJ8XVdI/f/MX/qhR
# DATA ZY9nX5xo+FkzdMIsLf3wL7aBOXpKCbVu377FPO3VJD0LNiKJDwmX8vecpjaoMLf2LdvcvLVAc6adeXwBgTjn7gSQ2SUd97EFEF7s
# DATA bNXtmC7QkHRr/vL9NzIlvPnraO3pRt1ZLICdYByKn0efqpoLrgsWeYJdF3gB8+N0QtrTOdZadtYIWV6REDvyTMBYBrWSxRBrEqVE
# DATA zleMlvIZql9ei9uitJXALTXBgRVszFYgswNooW8YySejAUxGzVisHKOUHT0xLcarsqapBazexoMwOJVLnq+8NZ2JCZCVPpsgUPhe
# DATA rMa+t7J/ub4UWpOzDGv1iIZZrItXkux2cDy4ZOJ6TarJdJlxxZxUDVAQN1ogd1r2il/sO5NR3SnDU+afwf9i8V7CStlKy20zev13
# DATA SFX/En1Mfg7mwV9icQqWI7O4tioCXuCX+Ck9Z670c374KwOgQ1PiyVPqIeor4SUtU6xnwQphbTMbrkBiOK/Dk0OBdsUp+n8wtu7P
# DATA 5NSQBxai5ViXRLKCClJ0kHZfzMbCf4EekAsFn7iGA5M4J6Mvfc+Jo3VuaPDIkkmkrQoUb00ooZOfI8K0aq0AUrGWFF9iNXXqifov
# DATA ODnS9m9ZubokzfoFJvkCUcn8pMtQS11f1Y/xMQCsttQfJLkjJh4NhLtFP5ILgeBaIf267CsoYslUCARK3rH82ufq1dzac6RwhJ6k
# DATA wDdJsW3theo+77QshAvtdTuniv5haAzX2l7dXvAXXs3g5Yc8h7FnFijWKS7IbtW0LNnhoWJHoGlss+uJQ0GvhakgJ5so8lcc5bnp
# DATA tMPC9M6Mg6nupNOHBlYQ2hZXxaK2oFdCoKN52hZVls3NqFavugs/hGKk/fdsM3uMcsE6i6Cmy0xlwpjRXLkOKSi2qdOuvIIyuAcb
# DATA ZN+thryl0cwTAKlelsZLNfZ2gxlUiXrUEYfpcJLlxzUddGp6X/flmXqFVcBfKxPSTS5VHaJJbfdirac7XCWODja/6XbgtUAVQlDh
# DATA xXtovwSrKsE794fNPJtyPoBazJkkSJvnAl+gTR/QJ/DjVjj7O76kE0TP4sQz+2AJx+xD35ikgODnQo4xsWnOYaGF9Nu4R5ZfppPl
# DATA Qf/AIsAuK6YaL+6q/H+Zy5VhmATd+jPyRP17Cg8xcerG59TXWKhLupI0/qu8vZFg8UuMbZcyy+faCUn99z9KwCicY62fO49BGQNE
# DATA 5qCP6RtiTs1HHMmeSXXau9kEEgSqMjz/rdKpQVaY9jqQ+VwL4QJYDZTJg/6Psl7HbJc93gTVC1pth/UGQ6wFN4BI87esqS5vSGfM
# DATA hf2ysi+HG9hOF9VdCmzvqjECEovYm/siCyP4D4uJciouTqgZunteSnazol0uIjjceblJCz7BDwxyA0629dQ2O4jn1QRB+N/p5I94
# DATA ubQv96hCxPvgBdQXKmQHsiRXoe4BToDZgr7g/9X3scBYiL9AVeCX4LKprwC/qnQa5yN9jzwsfsvYlz8jiZ78Akvm2kmu9erMnoJ5
# DATA 9HvPUNH9YBV7NwlYxLEEmHlLvO3U0T4dgZl1YNXDa8Tr7DkZlZhL0GwloE0tp8GkUmZj78U73AN3izuWkic4WAusL7b6owzUpZRe
# DATA vnK/s9LHfMjNJgU/KMLNw17SWbhU7I1xBUZl8s+cvQK3P2AB7EMa3l4+/pGzctwv6b2leiyOC+eSM8KZmtLi23J7BAvQWHgN4wxQ
# DATA gHZjWmRdviTS62W9p7BB8TvgA14Jsl6pjeUKoVB6b45FsB4JqaV/eGkBrmTVtqVbFUPDeA5YGmz5fyZVsnd/R9BKjJ0sagW+XIR1
# DATA f8Foui6sDen6foFxfoCB/lurXw6MPDRg/40WAvBzx5QPJdlSa1fQ2xtUmzYQCgnTe4H1FO4nXpBd0dH2MnZXbNrDcS/t3tsbYVGK
# DATA 5y2Nf9l7iT6YUnCqkRNqEyysc24q4kI177pSC6+RazwRuoCiLbKkAtQmWC8/MyonywwQQn3jwdFpfCRUmlTrEq6gSvAGMC8YowCu
# DATA qQ7rJvTSd5L8uScn34OTx4FgfDrf/Cfj6g/6dqe4Ueh9jtRd6vC0Ys/33OSEOahL/ALlDYmDqb3XQzNr7bqLak9w1gJextyK8Dyf
# DATA u9510obZPsSLX7y5C76LkWlIukOTy1GvKMSgO0P4TJDGWpA5qmPPUXTDWXV0xo774Xn84fbW5m5nffNR59HWk7WNTbhFSAOBGPnT
# DATA tc31x7aYfmPlGlBhUy5sEYKjHnqTSN6IEEcDqVOrjQBe1nFowaPGetBFfTkr1X25Bnt5rb2odt6dMyWmPfug8/TZB483Huqp0A2h
# DATA B3gxvsRFw6vys9wbkkOOmZc9V5uFd/gh6tpQpjtNX2aNALqXcdVcMvhHgb0a2DjC7BHcN1xQZxOTFKxNIfOS7LWlcdAzT7aNsTAp
# DATA dqMoEjkyU6lgdGlOrhscnQ6zntNgyLNLimXuF/XwciV1R1m3n4gFmRPweeWjFDoI+0tXOC1f53Y9D5yqVsWZunCXmndl4Sg/0ZAz
# DATA pQsfLg3+wSWnANeOrB0WOlQEo7aW3r6N+Qv1VVBYl1Wa9ss6yd5fbPfZ30PzEv5KcCvR9yEnNS61VLgLabJCnra6B+gwzZ7ZIkr3
# DATA kTFXC6LlgR0SKReO2lznhUlVqPZfryNoozEDl51QYvDmC6qHjIztSNqSSBtopGkqAx1EB6dq8SGdTUex7yX99uYWWW+pw5bMbMHD
# DATA sgWNgc5z2sKK9dgWcd5CFVipRwo33NY9vrIfUMHP63M3f9gv75WA0psYIk9sjq1tVe9WlOfa+F9h9mg7WmTFCNgDkf5BKRDMIW3f
# DATA OFIE980mkApb0VTe5O2aQ+/kYUjmbFtDHiqb2RH7Km/HdY75KqWylpAk1njrnKpSPxlZzVPKgsdWiWIP1S58qKtsFxpBN0+8w7a5
# DATA o57bDDZdPQYZxYvUrWxSkBr6ExMi1YlXoe4jWWNv3OBPPbKFMyE9eKSXdi2GNHTdY7AyjTNIP652T/+lInD4Myl1Jw6YNNRfjn/q
# DATA wo4+vicSeR90yjAkQmAN9EkRv8BUxNFv5ndVEJwpSQbN1Ko1SsQBLof6FYx9n55x26X8OqHIFHTw9DQ2FPvYMUNyr3AMqFfxyRVl
# DATA hHkVXU1cKJu90I2sTBCQy7hv45i5l9We3/ZL/+K2wFivtRfofyA8l1q1DnX0wNW1case6EQgavcF3uM9079oQv9IlsKA6WGZmyp2
# DATA pW7dp6uJ3XOCO611MSScz1+MStH9m9FjDKQnBMlZzlm+CUAlzqPx7ECNKHq2/TgimDJKXsLx8AQLo2Z4kuV5czHtCMU5QFa9STag
# DATA pBhDJgG8eck9qjTYjz+bg9JTmnKgTK/L1XqgwsPeWPEWSR/ljtB1oVlJ62vXn2yufbL2vfUO6WnU1JEzZ0j/gcuiG0kcIBJFGRYc
# DATA UdlW5xEhdov5+9KePfxltXNPsdC+pw5f6EgFqoFLaWhKWy7AjJ5Dn6L6yVWBb9A2uyTIUghhybA8U2kJ2FKQwJqPivQnTMvtB/tF
# DATA fu3VhowEfJ9MtDsHRtmOfRNSGWBAoA1gzBHT4TjrT2yYKQvFhFvwasr4IIpznzEdsJGsph4wc5DPJZgfzOOGAR51YrUwKS6FaiWh
# DATA edZDPZ0ommDjGD0PJpmpioIQvWBNGXksgzbnxikSBj4Hozh9MYOM8SrC4F/wtxM2FSpmYJIIUZ8hirOc94eefgehb4FVZd4px4q+
# DATA uno1yfXbKOUoPaU6cxtTFGLld4kfSR4Oe/Stetq8Y2J2SeQvN/YY/Y3Q0SUu3Aib0VDwxglh0NVihqJwH80AWCPpmwdJs05TDbdw
# DATA frsfSu2Th8gyb7hCoCw44Y5NCGs3a6hDOslktGsvG+fmx8GsP+hxkLC6XqBaBczBFQgwN2p7caPHuHw8TeQCSVWi7xHqQG9QDiIX
# DATA vtSboAK3LZutoPRGTDztnVVFp+rsxuzaqr2La6iEbhUBIS1+d1N1o7YHQNrZq6w7m6YHAwwy3oiDWNrgb0XB1LizTEvNsdp5CWbV
# DATA 1euAGvLGmGyESKCgM0AlIPcKenPXESt8NJu2b62ssAKZcgOIDu6YP9fdJACX8dCQNnry0JChgNHrX0Uf7+4+3WnoMJ03Pw26ANlA
# DATA wi80BgsB9bJz0T+imgXckH6tDiICheNljumSkvaAbElkXHZlL0e6I5pEjub7dEuGIzHIaJ6hzqzXgGrpvsx+6EkQbJTr0ym7rQ/1
# DATA Gggf7meB3RRwvbYglgszyQUtGJLxiaBc9q5HZ+W3Z4NXY22TE9riis1IQhS7NhFJFQY9zBGE4/A5xQc0IopOcvBY+btlg3WAeWby
# DATA Jk25zkkawDWXXFVzQ66CK00c7YuABXHxLwoXBuO6a83LVEEANIiHwaguFuw0D0BFUL3N2RBdlk76OVybOqMXXnVFnxJXeKBq6gIa
# DATA iNGAvE5YlKC67t8JYdhSAp4AzK84ONJ3KrHAv7arcyUQN5bFnu+2e6ID4hFZ10kcYrKvdmEHlbSLE5ZCqzhiYEdzmhQBAM5J0+5q
# DATA JeyN2yMXm8Qo2+bRgaAQ4MhTGFaLp9BtQuI18wCEypND319kZxIF95K02EKriuAfM4+LxK9zQJlWy2s/8n9C5xLgOv/BUc1/9afV
# DATA XuQL2Fp8QCWGlwu1xQWqVZm6gWttnyws6uZbyMfg4DxjHN/P5iE9NyOZlFr79bCXECDxG8c9xyxy5QPjyF6XoS0u8jB2ga1tqA8k
# DATA G5JHSP3sU2xgaILCtjNO+5pFFqwvyObswzrhRVFhB/9mngXB0/eQRGeTnJTkcypfdpvAiWUqSifj++Rz6NYw2vMtEkpO967/TfIi
# DATA qSWB9I5s75+yhvlcT3nLW4F6JOeAoyuQw4vHSVO4sqsv1JzKkgCTKktcFG4Six92nfKS7u4G4iswy85mFY2Ye3+QKepeoUxVN1Ke
# DATA Tc7gMISk5Nqjoequ6Qt1mAAUxaag+MdikRb+sGsBEC6qqRBbmsyZGit/kWFPyl1118B/2arerg4jjbr1FLQ2ruOsI27uM56jFAfL
# DATA m/YpWqgkVe/JmYURVwyCXoEcTP9f8VXEb+1MskGmCK/HrEKD01oXbYR0ZHgXnajlMvpgdxMf0egiiDDH2k9zRItkplWGC8c6zhC0
# DATA QimqH4pP8kMHY8H9zJjfy4HiqCZ/pEbh5U2sXy5YLSXEQgW67GeJxbJsbkwt6DnBP64wVe6nbzdZuq53Nl3zz1mVuF2GKLegNjIg
# DATA Xxg3+Lb29W0Fb8uMRgdhN3gD1ndiR/2GGXnQiID6X6xO/iGzlkLOV60fXs6m3WUstWzd57FM2kvHU8b/8xzrw/fDBbUNpbmqHGWo
# DATA SVjFKQfwR02wJxnZbGQnlq6SdzWPpF5wlQ1QbBo7uMaBG2hhvYuaoDiZF2+vdUWF6J/F2caiuqUCQ7NSkZH2fJIblItCIo/wP19Q
# DATA c1WoqTNIz0YzDGBxOHmR1yx4IAv8ppS1By8ksCxLiy0Fi+UfqO/X8U9FisWV1VFVujdZk2LG0PKFcsy8JeSYyW1WBvBhj14rCNrp
# DATA LUgIr9CDATEwIQUkoWQhl6J3A9KDekGvZ+pu8kRfShZxzCRfwzojmzxJx/IOMg8TMTGZ3ijxLyr2iZy0FtEH8XXRLNu+5xMZ0hc5
# DATA etRWcUunStBEamw7Iy98SYXy27K4a4bF6bDmYFecPA1enTqJT3iMtKQitYoTfuJyB/WgFi+n4/4ygB8vEzRnTLZwaIP2xbIGERoD
# DATA 5AP5tYtkqk00dnXobc17h3zvYzXjA/XuXAP99rK0xwjVOLUnIzURo2G/WwOF+epNgms5PQZk5kKB++bzVnn6a0r+h12i7GbopaUt
# DATA P3cwD6BiV2rmQtmmRWCbvzKu8Gb8G0qEbbFqBWcDNcHhjw5GvTMXjVf3FDVhNUjOyTk6YbbK8Z897HSoVwAEBN7S3tOtweGtKr1n
# DATA S/Ku7eePR+r4rIGDERh26hgkWYEXTboXq6ZBbRsoydCy9XOTVYech3Vu0J9CvtHfEtIFxLP+DqPlfgmauIBg760B8yCZJLgJdrgq
# DATA NREhhhM6ghJ9J1kxCxW6VinGqEpFkFMozqNnzzYeNX25kFOxor+VokPUfpdD726v3E6qyMLimy886NrWDic8l2nQnalQw5BZga1N
# DATA OLehLHgk80GWjWs3mVGGVado34w4kvG3XnwyhTFrZSmv5k9e/6P6+z+9/pJNoYA7SZAlobS4xXDJX5vMFBqMn8yWb2H+vCbknPn6
# DATA 9f/Vhl//8s1fQdCnnzsDRhcHdLRFTlcudxlr7NcmePXzMWAE1NLJUW4zfsEvoK+c/7mtddSxp3rGz5pkj8I/HZ0vPgGtpA0JClSs
# DATA exkHOm6qr67CTJtj7aENsmAVYPhpEDMXZmtrDRPV0Mwh1J7JfTLJkYPqROrNtcnRDLbPU3xTE/Jtu9PpjbqdTiK+bIJnYMqf1GLT
# DATA sxgcHEbg99He05YhYxjSsPXSeq9N92I0mHD3cGTQsUINqpsigN/VEXm5/ZRyDipOr8S4njQvhr+1korTXSdHYD0k1FZ3SUlgDSN1
# DATA 2noXjZ2prhwuh40T6pmtuwxhd4G60DcluVdWhuFpuVhVbequri+yMWT3xD0T0wV8qpbCs9/pUK+jrNFH8dzik8JujT3DAlsNnERs
# DATA wW6AUGmDHmD3o0culsV/oHReSxyKMRy5YIQ176ABydXbGPghkYxKvG5uMiMy7EyPi8CNOD0BBG5uLxL7NKJGKoid7qQESOyDPyyD
# DATA quMndMd0x8C/aRH4B189+ZeNEuMHBo1B/qZgYPwtkY2LCOuYEdib+6Sc1FEYmiYfkmRIUiLIh4SFIJXWYXc4HTgszLEJe/S2NC0x
# DATA aozQBYwydNVixbFVVxLOUPxwe31tV+cj3n70ybafm7hOmZFsMzox+GEPG5BJcuPTGK8G0IIrAOFomofwogb/qfOTx1sPv9tZ/9QV
# DATA O11uGQgHpV2CEn5vdjLOJeGfu2m0igKSlefgiZ3m3X6/zf6UYI4aTts3E2BAamE76DrX6eB+7XRgv3U6sfVDzftHw9kJLjj8mQ6a
# DATA Oxsf7a5vP6lH9vfHz55KLy16Tv/UqAKTku9GR13z0bWvP63py4kj6BBHlHJJTYqjRkb9bnZGomhAKifxa+dMUeGT9Vf9qbDXerho
# DATA GVVW0wLSQ3Zgx33OLXliXKLD5l7/nRVVzWXEyK0Fl4mg+94clz1E6fkJ5lUH6fdzDQjyK0yz/gVC7n1jkf+dpJMfHaijMj77xlf2
# DATA P0hYf/f2bfxX/c/799at2+/f1c/4+fvv3737jWjlG1/D/2bgIaua/Ma/zv9989ryLJ8sH/SHy9nwZTQ+U6xjeGvp+vXr21naU1sc
# DATA t4e6lq493SC4IvRfxstqHk2PJ6PZ0XEoZkiVb6palpisa9FV/wZTChwsOKS9qX6qbqt4ZeSf6uZyrO6Y+icQPv33KF9C/wq4e6gi
# DATA mnuAcKmLTExjirDoP6FN/be8wXrPnL66yinzdNbvUR+YRug+4F1KETZ1QVS0tDtQA4qMCZEufOY2ZSR8NWi+epo0wKz7V4zyZAyJ
# DATA Vfo99ULmPCFvC+R5HFVj/bOXpEdjdT5jDCVVpDef9vrDZj9Pp9OzWtEnzB1B/IT8HiMRz6OqnfTBK5vEx9EQ0zulhFd8or9vRa7w
# DATA x13ipW/yvzUaNpJlGjkR1/5wPJvql2Z6N0fbGWmFfU0i6BL0O1Yo8tAo/ILedLh4DUR0vJwoRj0GDT/ITSf5kZp+dRzUlq9DcjfV
# DATA xtz5gYZN/eqPH2Du+XtwcPC4HFJ0Dap0IKLJDmZt3Lc97HT6w/600+GekT5y9EJthNgBKrH6VbohmvAy6Kvjz8z5nbVP4Dkpeg1u
# DATA wIXRJNl4NDA3uSmv3YTXlBWa/tRZoYNOct4cPVPPUjsHKGKNZlOZCrsembp1zXF4PO22RnVATb3tvRno6s33myvq/63CYDGDMJSB
# DATA H63WanyxSI+3s5PRlGldri+x5JBPS5tGlJp4Z+fjaDobwsjgMECJWEbUDA6buJb4Fy4oraDJ6rwMoiq+cL/ifYjeXp82PhxNTtNJ
# DATA L+s1nk5G4GAX2eWUb9Vf8M7OwAXNnU3qsMAEMVz4hduhhfT74oCChGnPnzx2BpUBNQSgK2bnV0j/pgVV9rd2AqMwYYyYF/BJHGOE
# DATA o4hUXGbXnRs35DxeOEijZjHcvcBl9+I1Svb4Iw4MB53aB5m6sU2QptnP/Zyyvm8p6upLcxHyRzX/QLN7K3yMdBGmhdZEXAnwbdLk
# DATA skl4HA8pCXFjl+FU3Yl61Tg9PcWcew3TKuEZ2xaLM+tYpyHhtqLQsK0mECRYuyUAS+CkfrS+ywbE1WQBr1C1UYo7bFvsHpgfMFTh
# DATA 1oEJbMN/DNluG/LtIIAU1f54yxP7mm6TyBC0Gej2PDuQm+3atcLcuqltMMIUU2aJAexXriiJHkT+t/MMJD7xAhFO9wZykKq71+Qo
# DATA K3FqYrbsJHeknoRcZi9lFzE+UyRBBA0aVYYx9zjJGr395dUMNO72zW/XozsrN+E/t+A/ty+wmN6w96Ob4aal9ULREP1BUrr6hUDt
# DATA eQuDmzk6TPuDrNdCjhFpZ1E7iETGagUWohY0y9SjXdq8ISNNxeT93mdFfTLMUEnJE3MPLGXgI3Ciinajp1s7u7Ar0LvOD2KDzqnb
# DATA 3cmYQmqs/aGYq7mGweOHaqNPnYRuOuV6b9rUNxaEovOqrkMBePYj1XpzNu2GtDellfXzESU4pcqaOtd8/H1gve+trLRWVjwHe6qr
# DATA Of0RKN/DYUqmOS6ra6Vv2sEOOznZm2muS9T80k3b58T2l7uqOv19YUobvswmSg7NwV82/+Es7YFMN5qmlPwR0DHS/pBU7caNFm5+
# DATA Dovn3I5QCxmNtTgq0BX4LjNRszobDBCcujaJ99Ya308bP1ppfLvT2D+/Vb919yKmZNpzZfhnWuTtjTJi1of9KUrvPYvzHdE8eBtz
# DATA kqkPMbhG5HztnKRjFFDoTgQCytrD3Y3vraNmXd281N0J/GTiRxs7ax88Xn+Eclj/RN0n8fHjjScbu/Q0ezUG8wk8Xf/06cY2PR0N
# DATA O8eUPchWYfL52Lljjw0Dnm97N3dGhi+Go9Oh1gtEuqYlQqI4AUBC1U4PEyfTorM3kuLGHSxAsGMrSd0rAZ91ppP08LDf1WXksq5E
# DATA 99vUBPzx7ZWV91e//e2bd26/f3vl299e1bcWLIU9CBSaN7qNIXp5RtwLtXdncIPNzSKCP+3RGcpmgZF1YPdOO7oYDSIejuh5nDRn
# DATA 47GShS0klq7P3FA2tzrb6zuK+qq1fLT2Gfzzyfr6d+HfJ1ubux/DH5+tr23Ly0rZQuWqtdEEfJKx+ch2i9xk0gkcOgyY3y/0CLgA
# DATA NiStlWb0tp/3TD0azRs/iw6y7gii8U1BeQw4dxHtuD2YyT29Jff35W61j7FDZndbnbzf+NZm5+Otx4+g/rM80mfgHhq6XtJxBb7W
# DATA Y0WuucFBHqbs1NIRS6DIiGxoFOVkhNWWUBrfzyYjxUDTYR5BWCgeWMbSkKSiGa2/Ok5nOTqKd7uUduFE/Y6ogYgPeNO54MJmftD2
# DATA GzUHTs3mqu8uwvOMe8pSGE0+LsKBRLgwplCFnzI126Bz5tyf9Ba5JveI52LlL9m2nlua9AhTY+uP71nkmOhwNp3hUg3BDJVH6Gdq
# DATA 9Uryeh3aqtZoBd2u2EPPcnDMoaQtSqCJfqQW956Sl6fqWk9dPEnPItXqkHhBOkDQgygfg8CvaUd6hN6XSw4rPrdsq8XOwXqL6xTX
# DATA hravwQXWyhl0HuhVTHknLA3ix9oAcVMRu8bqzcat1d2bt1p3vq3+7/sFDImYe/oYVvMDCJNU7TEJd97taMLRMhMLTgLIwjaAPg7T
# DATA wQ7wdcQCAnEVs+aBH1MN+X2SFFCuYmG5ApdjMxJFChmYMg5xLtI+9zrpNC6IaXv67Ro6NRbmTnwrcnn1ETPEtsDPYpktZCaIaRs8
# DATA wmtcKokaak1fDiACEmdt9AMyiufHaW90ChGSuRiGreYy5HsMmp3uaNASZ4FFLtS6MiIPaZ9lOnH+TkldmFykrmNsIe6wZntNhn38
# DATA +UwtHOidamIoWtNnB/hUP8GScqhe8Ty3RV1UBd03zfp4Pv34De++oBXeXHpP10JubjTKxM8zEIgsrNZom75ZNaSrchS5ueysuS3o
# DATA nrqnga4hMgSE+/gtlG3UbZ9KwK9bNxfp81PdV6OPdURVKaZyAIv6E0XVScap2FzSyUeJhginqGAqKCxVuGebo6i4haVmV+YPEVK/
# DATA g/xSrtW2sqzw++mo95p4JE2EqxTqVA2Dp/7ca6zu+/uk8tqwerd+9zbcG1RzySILI+OMSY2r9X1plB+DmQh2BOmMB9lR2j0LOIfy
# DATA BBaXJ8YqcN9hcOTsoHh9qxvOZlzKMFsP38TANjPsZT0ezTejh2ZpIiUUqc0yRRWldtSKspdqDKfHGdV/gpob5MApgECBFxBIMHwh
# DATA x/sjUaJ+NuihlOlc2ezBKZIVl3IgNdWjtfyyHmJgZZxr3xBFhqCmXjkkid/oeSErgt5m4GYIUo1+i3jY/n0bJx8vrQbcOci+gT9h
# DATA bfa1qVcWKZjtbN1qcvpHQ2RH57maWdoJrmojd3IR5uS2gZBd5vAEmTiic17IDQUcz/Yw+NE+Ei3dLRt3o8lPBxqtpeO+c/XWZFI9
# DATA 11rdGmqfILAOAgzQzLx8cNbQewfDERyaACKZiZNKDzMwjFkzgQQ6saZP6YNurKTFvO5Cl6SWRe3BDvEYGodIrnkAR0uHmOSoZ0Z5
# DATA Eew7aNmBFLxky4C5tDx6dHiYZ0JNvlKPVskLwq1UA2zNnavvUI1trTmknwgo9Eco3Jk3VL3L2FDGDYPe4CtCzdyL8Zebpc15gZsb
# DATA vyjGAEBBq8JBVBpI87AYVcXpZ+cDDUOqLnNoiMYVukfaQP0wjRC9L1L37v6oF3shdOBVy/Cje9yb/WJIZlHllBBmmm8mKu/3oxkZ
# DATA SzIWxahpjOLLEccM+mDyxnnxh9kQ3CdroX4k92gu9N0FfiR+JkUsgSHEuCRunw+UUPzCZ4XOhEA3RTUPQrWUqVO0158eNq2R5fyi
# DATA 3muF7oUrXccq+A4KSu8MjFOs00Avdgdim/2bGtSyDt8/58G19GnljduiPlw4FAOLaFy02dDzZce4NHKDnE3Hs2lZPrsyezJ5w5gu
# DATA ozYA1uAAbMmqnoMReNNAbXFJomKncUXXRoOX2vBnyjKehMxPXo/Qx1kDV9UjH2yifyi+l4NC39rhWU28VbwA6k8WUamqcakbfAR2
# DATA gjO4yDgToIPG8mb3WHWoJois6Bpvpzb4StD46UnHeDtIyVcUczgS2N+Fuw0BzT58trPbWXu60dnd+u76JhDXbZ24EX2gyDwcmYRs
# DATA WkXcdqp6srb9/Q/WNjvPdta3N9eeoPpF60zTnhKeVA3GpUckozNifLi6p2s7O59sbT+S1elPoE9icoxTAf80LAMkNMMzsC/LWNQc
# DATA C1ZP6D/lna5lWrtgqzzyV5AJIHS7QxURX8Crf45xs1YBFmRcfRYlGvQJQFlY9rwX9z1JQ15GYBta+afd1j7N9EUHK7SCD9WfzFcD
# DATA 0+dU3t6o8LxAPT2Z5dMyfTVWV0zQ926xibF/yHo7ef9HAlitTpbKnIWFPSuyajaFbVQEL47TMzDU1qVq17W+BCaHH1p9p/YW1ncy
# DATA dbeAa5lv9aXoCHd1ScYTD+q6T0L23y8AKJvKpPylYdf0pUUXMlUmC/NeQQlwKgn2iyz9vf7hYYYwX3QjuIeNjtScAS9REq/HjdGt
# DATA 3CSv5q7gseC5j/Xkq4f6TxlO0goOV+BUazuuOww39E67ONcjcOAo9XbG6nBT2S57B9wXKChzNqZQiub5Rrs91LpHbUNhEk3TGl+U
# DATA MmiJnGzZMp2ImHoPk4Z/qCe4UTFXY8vfuRdaqQd2pUMWFFrRuRUyLkA6THtn6qG6wWJM5Wzvul6Q65TgaKZRFaC41u1SeoquEk/o
# DATA 0zmfgaJOse1pzs1T95OLWHYRlTfoFchkg9JhqCpaxvBvc9cYnkx1zaNhTyeZ6sHR8dTYzSVHVPd1Ep6b0TZaPiK7DG7gSm9y1lFC
# DATA jx+DED9Sq6eem0A4MswTGSweHTe03QSVnCnCCmMmp874oXQtRmP+9FgdEujad3CnR+oDYHNoXzgDhbXfrYewQQfl44UYKtEZlj5A
# DATA Mc/aYVBh76NSlBdcP6BpxF82HQwiQ/C6y4saEgOwgVJeISYT+/e0GTtAFsvpukU6rKa11qU2gGIYvNSVult5ElSJ8ECH1VLkQjVM
# DATA y9y9GW7tm9Ga9U0C+4qSfwcjxW5ZxxQZLBLyQEdHYsDpGHb7AAONONnRgRJQe4MzugM2gw05IclvP8XhadbXXs29+HUV8yo/yg95
# DATA vKTNhnDfPuzvSQbnb2zO+XRk5yMYzw5b3VhBbPrl4phQLX2Jruuq7ZmprDzkMjefdevbvmJD3cwOG8mO5tcOvFJo75UwST0APuP7
# DATA QXbJsnCAPQruHWBwrAxlFkdNlXLDnY/Xbt65u/PsyQ76tVBqKw6DaObHqXpZG3vIpsfZq17/CI4nqnkiZB5jyouofj8fxmQOQgkY
# DATA 9fHi5nY0GB3U4htM+pPE5aFEkXvMxXiarvMWur4PrE5yRlnIPKdi2q3NKUMPoYDlOv5azGV06QR11mT+uheJ6Ua9Uo5Nz9RjsL6z
# DATA 6MV8Skl+dExHPTxUcTD6+kqB18UwXpSHwKE29qOf7wWKC7IT/KakFfcqtVBLpDlYtAG8ujTg6qLjudFzTk1aqqa9vapu6KFGUEor
# DATA RkRL3y+tO7SViddl3VHiSYPwyEKhzKGenKGZoDTwufiBvgk1+CZU9bUOZA7GMMNOW0UtuXsHhEd3VlaE/KDjke1kt6LV//6T/+UO
# DATA +AHSfdPYFAN3OpOqhANJ5wZ0zouzvORdRARjovvwH+9sbT5C+OXSqwoRnKvdOMxTQ2QwbQNJlShfgt6GvPSawswlCAA2r6RhQPZU
# DATA VbQ5HEo1m5THjq4uGGL5L/p/fmqMrz/+8/1bKys33fjP1dXVW7f+EP/5+43/3DodRqOhEqanCGLUy6KjWTrpRWivuBe9yLIxRjnB
# DATA AVM8BFEE0C/lzPpAvVQHEooHI0HxhsdppUQIJz8hJAITl6mO4nCkf/THnHTu7SNDjwfZK/tjNu0PzK9pamI9bY4XE0eanYyBVCwt
# DATA 7YKLYaTT/IGemODecLbipe2trV2tqSewUFOugchxBo4jWXq0/uHas8e7na1PNte3O/xlvDwaT+1H8dKzzQ2vxhyJUo//LWugqZGf
# DATA kqWHW5u721uPO0+3twA8z61tdni6LDO8NXt+jbBEkxH0eGdjd/2qteQksD9Z+7QDn3c++Gx3fQe8GW2Ei3kJz5Xsi2Pv7K5/ihMT
# DATA x3vPhv3p/tIjIYZZbT3uWVZD4WIsrcFdsj3MpqejyQtg7E125ekBlP1ET9DSB+hR1T5RQkgfLc9cbmmPE+PtLwGza6ubHuR0W1p/
# DATA lXV3wF+wbQ4TH6SoasWXsVeK6GoI1CXyhcRuAotpK2FlaW+DAFz3lz5JgUl9cBbomJoLvRbrH258CrOzZ2diE2YCgxT3n0OW1QFk
# DATA ldCPFBc8gKV4PpTSLGEb9GgSTQnY+nk7FsawGyBiuImSMPrKQdMkJwI3kRN9hzyaQ7Xg1HMV3XQMvp4dkk3pYUWeTGod/yvzNGlp
# DATA nhfciQIxLpmGljT7445TElNB9btTaZ+xoRdwA+2/GmSI6LISIbQ2vujnHVyfbppP3cczzDWJNw3/ViOx7NYiLtbl0NiNp1CPmr9h
# DATA NpUuObFjpqTU79BWYpLLqSUFo5+qRA0mP0aQFzXrB5N+T10Y6xHGiuLT9ooJRSeYSD0V+JtlY/gaLUp4iQRPBlNpEv04Or9588Ix
# DATA 7fKbB9Hd29pmCFeG2jjRyu8+pc80ovEY/nP3zp1bd+ydlWqpmjGtcwZ2hKVdCzMPFzqyevNbuifVPl/NFnh91VfvgNPXAaXmPYDe
# DATA 6MoW6c8jJCv8ifbMTE/6A/RM7o/vYlBl3IrJC8FiZ/bHsWvnPIzP6cOLKIf9Gp1j8QtwI4dQVxbjybW8HdXifv8QFQDnqA2A6xXp
# DATA EmSkqBiVWFI9QMpCFZkmUCbnlzo/uPFzglW1mym0vBiYYYuYdV5kHolOCdcBJkg4MdPuOOphlee2etNrxA+wrcp+87k5VLSTfDD6
# DATA cL7OkZ9fROfnS+Cro+o5IehW9QTHicU6zCruRYeDVN35mOjciy4uliJMC87XD6iGPlPSAmgyj0cjfTVRt47RBNzsGqsr6qoKhv4z
# DATA 7vc99ZVewuuD0XV+rJ52pwZPmianNxmN1fNz2iugmxYzch6d27U/ScdwxarziUouVG9txfarf2vHbN6e85RfyC5k6LzSz4+zXl2n
# DATA 8+1qYz6FV4A4aCo5yaZpNLiN3qCK8L682+h3T9QZV/95eZdmSfV42GsMs/7R8cFo0shhUsAjXT5Me2DTxGcTNemZfgLDUYdKTfGY
# DATA 3ENu3rlz2cYdvctwkqVqMTHP4DiFbDeN6WjUOOgfEZtpaP8TzCWt1gr6ohpQH5w4c0trZPfGIQXml+wO/XbO/lhgJ1x5pc6ZllzI
# DATA zqv/AznDQDt2Qe9q1GTMHIAJLLH3tg7dLECUxIpSd5QQurn+cHdja5Ni+Ng/1yHdthJ0YLpNEDTmIfjxKs7a6x/Bh0KdAJ1BrylQ
# DATA K7jlQ9hSQAcRWRgc8ZRwEqMcl4MgpzgcpeTchR5Oe2rDUUehfDhBtcNT8EQ9770XY6LjYOJMp7NQSM/EnultAYm1POuk4zHItg5N
# DATA tm2sF3pm4FBJ9qVco8jyMeiQ0fxpW2J44qSvVrvNvAxe/tCbELtyfelaK+1kEpy4tG1OyQ1QDaoi3YY3cZQVLGcbG22qLc7qJEM3
# DATA rJ8bzoDW7PPnBua+yTcA7kaTijfZ28/L4OT9Tw9jBZkNmfw20aaHujaeMWY9BxPEPqRSG714f6+1elOvspbkiBkTlTbSmhHqKO81
# DATA siw1iwMjiwinDJzc4eGU4kcJwgM/oPnN4AHyOS25uyKurqlJHcLgeUzkUlZtHrsViQ99/r5NYEnatpUOSU7AJY9U3VSdPqPpME81
# DATA Dakdxr0MvQmL7Po5wdSHOo7iOfN9EGlwyoyGVA+n0cX/HuJ/Y77EiPaT4hcVZTmjH7DR0/6wNzqtAYwE/2087teQifTMqFUvKaKn
# DATA OxhBEBx63KtRPVS87WCEkhToYgCTJeITH3UnqSLqedPcTq628sEFq6puoRW/2qqLk6AmaXMUjU7B0520T31w5ML7MNhA1Y2RPLX0
# DATA lTpX/K4P8KCAQVk5KTlOhTclsZF84sXmB72F7NKGIgJEmOiz8dEkxbMUUQonHhM6EICjmAZAokOOTkLTnHZspNPGNSV4c9lurLko
# DATA lJBNJiJHcyHiXlq0fS5QXqhetRYgeEEP3bpJwq2QKWVdSfF00UnHSHc6FHMWK0Y591sIPnARh8lacKFko2qWrtYizxH8uXrnhPqg
# DATA qYCE1ma9AnvaAryo8SPGaKUq12F5MdrODmeEnRJxeX277NVRNTmapOggrNWUzZMXoBocg+W3jU2RKzBCLhz2X7XjJu7FRghi3EM+
# DATA PexZxFOo20M8hdZozKRvMW+NT6/pIM2EU8KgVNgyFl4cMdMGZ84JHOUU6MXJPM13vryQ64S9toROSguIuJzd0l4VEXgPjUFXUGra
# DATA Zf26b8aqh6ChQU128/S4r2TQWD1zETLUg9Kc2zTogr+3fk7bpvCaAwO9IugSHvga6FgNBLvOTI3hGl4PlCSWqV9zymNE/h9FK6OV
# DATA mzer5ufZEEKBomcffhKJ9dL1ytBDakinghVmUHVdZCAuXYi64ZN/eNrc6WzsbK9/VNNf6b7iaOTDkgH73xXH+BbjpCP+VeuEUcqm
# DATA UGQ7ZeipAopdSrzrTzd5PDrTCzNgrOKrN73cvGV11HQQtOt/5d7F1Dd5NwX9I04ICoPx3krj26Dpu3OxrLjVc3AloLqSSgoMM849
# DATA wfwds+EJzw45KuUhQuroojxYBOISVKOmyuwEKsnHe1HM/Uz8XF81dawJvR8Y0Gyss9WF1rz8a0jCssBX6CNmJz0MZGerFWnnLWdf
# DATA tC0O1cdVZyK+SH4Kp4PFzlWe/q9gBKWjCHvFeRuC9+Q7WnOZo4ONeSa/M1kL2FJwJR5ozIPgU3Qyepk5SE5X5VCMFN6yxOBypgpW
# DATA eha8cYShQv26+bUYKpCC8jT5Fov//3FgM1CHKxleYdZT3Yk6ek2rKP6/NCbtv0P29QC41yXYd3iS5jFV4bWlWByCvTnax+c+x39I
# DATA zTx3mT437rL7p7gUbIKqAZ9MG4drjQ+breX99xLN+GuWgda+06rbX8l3Ep+j+quCvZw7R8XJqeS4/k7S1AEbA42qi6MH9IlECPvR
# DATA tTbTFrhzEwUB2wl6OlI1N/c1mkQdvGbxC+/0Lz6ag2wwgnCt6Uh1ZDQ9xnAv1HHIEDNFc0GEC69nbCF11VXcBJ4FyK/DOG7U9gKM
# DATA bV/MDIpfe5Ah1jI7cK+JLapMPB0hLxyexYYVqf8mAuUXvRvkwZ3LfHEYzIt4FG5K7Tnc3eO0DAegg12/MsZrxu2Mw+yssExI4ytI
# DATA J/Okq2L1JVM1V/pwsUPQE0XesM25QFevwilpLV26R94cH8Z752rmLi5LlNgIbu4gaOkuMXYGJecFF9JuxoXyount7olbgVlmCWyQ
# DATA pcPZuDPG5MyEYKwd9J2zC++0l5WTeo6C9kmBlB7ko8FMTS8B4TSb7F1AOp9pXsG0DzVD4h7hVy2Y5unxhUCW6qqNgMmwEUrqxgRi
# DATA b/KM0uGxxACGC/i5XxGwitilbVtbc+Axb55nSHm7OZp+CB6GgRCiAkwUA+Ahv3+8+d0atGN4/RwCXZgCFrLULJh+Xkg4KJSxTEC+
# DATA nRk8HaA3m9jFlD00vWJhYyVkZXK6bsQNHRtbK7aG0XSySxRe51Ri5uZ7u58mSbhZvwpHhnq0se3OabgSwv3wKqoVpDGnJpgu/QCp
# DATA FIxsVT5l4cr1GkySS68rcl65OKEV5uMKU+udVQTzprNKsCpeh5wDWzjgAT4QzmKFDXCOqq3Nx5/5Wars780PIKeUQ58qzo0PpF2V
# DATA 3GpyENL18uGFb/DUImeB/wxHtaRa/i5dcXEUouDOX3R3BLAyF9sRHrETaPxG8q6Rb4mD287eClA0Wbj5h3InGjh2rwe8UHi16GEM
# DATA hbotTw8b37IAy7y5usf9QW/Cm4b3XyVnsSxZcpCiOMZdYM8B3Yz1JdB7J8fjM6H2McZD8W8HKQ54BzxEoK3CW+n2wY0kAHxqfIDL
# DATA wgadWd1VE6kuBmfOsuaBdTWD0RwVe9Z0k5kWJhG/kLNIX/FV+3AEMrK+mOfMvANtTjIDI4C/ncXWJXzxQAkyPpI5aikYNLDEskDY
# DATA VpcxKhjub80KTt4gt1tolKyFNhw4sIc3HJ8ph5iiu/sy4btlOlxy9e6tb922cDTwWUHc92kZdG6c9ic5povPQ3DuwjmEQeHqGgNs
# DATA iL4ZxW3J8HBUxQI7UWA+kZWXHLEQD8HXvhKoH0DKOYCLBUg/g6GcuYm+yX96dAA5hjo49A44krXxT+eIS3i4KWbRRYi4RXaFGIXv
# DATA eKwe8aZAUz2J/jX4e9KBjIR2v6K93DyvapYE/YEahtqJ7PGcR40Gfk0JZRkq6JTSz4Cm3Nl+eKhFJ5pWMi7sSoublDiT7G3yJSFe
# DATA OsYG2rToTYQtbmP/UIkEPwub1XVB1SoKrEXntt1PDIreNO0edxj3WIwI1bOw5leZ322qjmuvnOHi3uF20UM+CRtb4j3ypN7fsyia
# DATA K/W7Ny9iv9vV246Hrb/xFv0dLDgpV7qIy0DVLpOhP1Z/cKu0J1AkgmhgKIyR3aprzfw4LkpzRmfnkDiqwaFqLKo9G/ZNfGQB1EIv
# DATA FXdAB6T2WlIHRslZSjE3ynQlohQ6NKouU1Hp5AixXopV5TIyWHeCdFKLd1B3qAZ8HqvHY3IrYhfMfK91E/ED92IvNu0gzY+fD9l3
# DATA J2pks+dDRKdzaClsRKoGVHSI4Q3yCUBkZ90oNpvVlIFxUQnQDCSBlLw0luDEAigF3Grapr69Oy2NLetsCETGQosERJyx8pA/t1Wr
# DATA V0TLqBD8VxcCRUbef8UBMuPZsDudEUxF9zid5O343h/9+P6DWhJ7tYGJZZrlY/AZxFZV9VCHVwpayTDZAUZWOTdVcJmqYTGG6cOh
# DATA sJ3EP/XcjX1weMWS89wnXZRJ9YGzbN9kPN9/g1oMwjSD3//e+b1o/dDh0QRkrhTyEsKA7kNaJVRq6GemYoqPYPBefpb7N83SbeJt
# DATA FT7olsRdcqexDyDxOUOn1LVhkC/zSzwp/Lcl3dRtPFVtdar4fZ3JlwOwYJszLgN7sR/Shn5mGzHS/pomhbPD046OZkMUKZPz3XSX
# DATA noJrlt8Dv6dokSMTPVIC+vty8wXyDyWDwwj+Bvxm0A7dZ/i3AdddIOHUO3XEpqVF0SsTy2pwXJ24IDStNKhhL4NZFCOiK9NxHx3m
# DATA 4O19fMubq+XCseJ8YLF92IE0KFLpwKfvgS1Sfo7v5GdQBNcdP91zavShTql8O7pZoRw3Y9a3F6fGJFzhql7gCmYI60yMp9ph2GM1
# DATA HgYsCTMOGqhuJsxNDCch9gAOF0h6UYVsBpswjoqDQcnMeQudUydut6gf6jlGIpuM8qcTmLUJrpLmi7gwhcs8nhgtokuJLx33yROk
# DATA 9dUJv9MJxLr0OrbykHBrTq1TOmitKJQqysU+yrVasI9mFARjhAnTOKA7I8MRST1MxcUg6jCONiREIeD1o2BDAFDOgr4Rjv1QbI2U
# DATA xotibgR4DP15Cd5ar9yVdAiocRgdhfgWeFnXHYrZdvIUXQt0iqfMC5DRS7vnFi8g40vBn9xCELBZAwObKE/jO+FoLMYJueB7bhL6
# DATA a+GaAatnK5xnSRXJmmCeI2cMjmpOLo8DMFmjpijVnS6kM1KYXqLKOlAQNJUFvfOcLaxXyoKKkuE+OIiyMYRyvWGzJBsySaKtxEsB
# DATA sJNKuJFHCNq9Zzs0InS1eClYZy1UaVx5/JF7lAhm7nY3fWTgHz7L4hBhN+nEX5Lu/N7mrXQLyCU2OTCRT9DFO+8qmUQrWpaKvQxP
# DATA nUuZELjjHthqmWyAw8Rw5G0vT71I1thccx3hdahD5k9GLwE2x2h+CatLPOCgXIfPS4iIOjjF6IvvmLAv266CUzAb7AH0FRhvkjiK
# DATA Fxeo3/bVaGj606x0U5i2YYtRn9uRhE/grJtcTNqOC+IQTomWhrzB1uY5CCZJpazFkYGcl4p9vdlpROwoMxwtU8B3yzoDba8vkHTj
# DATA ogqrOEPaP8VbSA80RKylFu/4u1KPBYfr6Ng7sSMx84SHaew68fgaMhdtkqahY/tfi0v8n0o8DeK5F8nD+BLeCHNrK3orOLF/Sbm/
# DATA LzjQGJZkBtwuTEIIrdHbs4V1rRVcfdiXI+TpU+aQlCQL4T56e/yh5xoldrlmBTTby/hd5SY3qnMar8ZezH26N0iHpTRPE8W6oHUL
# DATA EMwlHQnjp1cUauOCKMgNFZp0DCvGygeCLRtTJqNxH3VLgI7TBL0JYr3V8KeGgWz2ZGowsEsrIadQK9clXSzDjoUQRH7WcLwCG+AV
# DATA 2ATo45h8P5ou+qd0+ou4E8ZHdZ5LB/i+aQ++co8ShnLxYV34z1p/bHPVNhAXgVAt1A80/IyJm/THBReUkNqmzPfE1oYypu4H+MhA
# DATA bMY1CGMHk/UY/kQtA5UQiXSbFMyXzJsWXAU1WradHfKynPfHF02IaVsqpiN3SDoWr0e3V759Vw7ZcObD2CAePR8alKOno5yRjjBC
# DATA XjUUNQ6rkY7cfklCW8RD8SdMUbW7Hi6KdsoCEj+piEKsfaeFgYg/ZkiFJPJhVGxQiFr1i6jIACYSYeT27VscvhixwjS6Puk2uqmq
# DATA Qg3Xq62hil93KDcY5BRtfplO+imuRm1uCKXaJtxVnpeLyO1PFc86jA0CBCavYvsupbWtHIlaqWL3Mfdvx+4lOEX6vsTbXb/0r1oO
# DATA +YjVusQcig20KTlfraNhSKeY95u0ExbYHAQKARRi3nFyethue8vhJAOTzbqH0J8ER5neD3oI4fmS3Bk74lRUDKLMmxDdrJjiHlWC
# DATA R6iYPaGipwEGC04vJ+kE+Ch4IhP9QG6PfMHssRbsLF8NkR+rSe5S7PZBZqCo40sIsYdKXIAmiTdWGYqoP2ob6sDGYb9AvoDB+T4C
# DATA VI54ISLFCfcTnFXuCbxPRE5Y+CwouPoiCkDORb5wUmaIO84GY8dQ6bg6WI257j2XL7u41Oi9ayEJIjg+H34FEI5ADKBwYZddrwZB
# DATA VJ1B9TUNLljBJWASndqS0MHhpSqZ5gVvW9TZBdY42KbwYnGk0VIhb2np33rIl1JIHYy6JiScESgPu8PpgAy36mWHXQ11+/AsLrrk
# DATA mKImS1LR6dCUYc/Dh9vra7va0XD70Sfb85wQQU1+V6vJXWd3z2nQtv/79hh03Tcv6zoIUwbY5nrmpJ8ZrlPzEFdQ+lXSc5ivzvqn
# DATA tvgZOAiFo90hgB5sUM60hZU4HXK71y72ueshop8GTX9XiM8rh/jgKBJ9cETUbN7ClvoQyGOIjHdFqWupKNTjysjMG/ChlLvUVcOE
# DATA PdCUKYpPQTa1kH2lTdkaAwCJl/Ky0T6eVe41V7bbLFXot4U2R2rXjPloqfDKv75exgXqEipXNpttjqRDWVHNWhQz7lmX/Bd9RWyL
# DATA XnQO2kqnXn15h1u/v8ZJcdLKzpPvo3NPg+ztFYY2KqqVzRBgp1Lf9pOgHRs/rttENYsbCP3N2vMN6DIVhe9tUK0bsW6/If40b/NU
# DATA b6CKPVI1kZV74S0nsXwiyycz0Isy1u/vypL5dsPmchuWUaTUCyMwXY08c09QvVQWvTesxYRG3Z0OkDL3c41C1VACHSoX5+NUC+FM
# DATA gJ7F8VUOqtR7gdNrE3SbL7KzvCY5ZIhjlAYPBoaZquaHDXWvgoRPbuM2EEb1oDZPV1f3OhTM02TzuExOUI22FEi/xJiBJblvZFax
# DATA JqKs6xt9DX811ze31jd365H5tbv+5OnuZ+bB+qcbO7tVCY3KSSUdAM/yRguoyD1FwhrnCULBMikbdEIvl4Iy8Bqgf+noUcnC6wbt
# DATA gHT0xADsyZew1RXoAmq+QM4uxOCj9O8Ak1RaAKh4IRQfhVnvlZRp5wCTkGRKc+mnVcVaKRWszfbqJYI1/p0v+6NZ3gm4mwcvOTIq
# DATA HZWq4VJmclChd26gQu2iYKC7bLzMUCRMTvyldr/Aup1X1lkG17mkDevdgoCkkXYroW+c2kHRVJDVPD8aF20bkosZzNQlrcFEGE4H
# DATA p7sco9tdmbeEeQQCh9aJwi25HgVDMYBC7RcsCFiNG9ddDmS2wI4V2AcjDM05pxhUrNVHE5LxShYoqNg/7a9H+XqsebCAKOJHZjt7
# DATA yNcX+LWFgVScKvwI6MDc46bqdGAeOh33VJV87KySwPc+ZzNpy5jv8vyYzk9L7zJhY29FEvzMPW8tdxjqtT0qLXFGLgqdJBWdUcZd
# DATA hXcWS2ZDvcmvKkIQbqp0zA0EchdYrrfmgt0W7uruNdZoxRH4sYkRRiG4Id5ylQkbF5ZOqi2vIgxfdtGXYOWkacrDiLwkjfKjMsBV
# DATA X12thr+HlKR8gJXC47wFD1C6RXdcyacSK8nJC4cp4K6UHA7fe4nGCDrWyY6GYgwNGvcdj19xEIQq0PqLmI9jr0HnHfUg4H/aYK9U
# DATA +g54TFwXbs/mByqVMK6iPxWNGByn/YpuN7jRyiJIWBpj8uQpJo1bqfxY3cX8TyGxW7hwf4hK7MIHVQ0UFDJlA3UikHSqNyobyveG
# DATA mdk0enHbLEHxGo7cn7JuE6Heu3kTU4BzLm4hAZSF9zhQRSBDtsrzlsXbLM14eUQCXZbbSsKKk2Qsg/3wSyELuRJBASWEXfitSF0c
# DATA kt8Xb0/LyHknPs7riclnTiFnCzQGVx/3dPGhc73zi8uLhchH1O2D4xdM31XqyOZpT+ZrUN6JFiWgw9A7v+nI0iUidNETO3lLdzB3
# DATA 7hhzaW9l30sX6HgpI8QktoQ8acVUaBXA4S2j2ymewgV3rEdGLW5H5c0ojMzq23wAPfyw/wpCD1SPG7SoAmrj5Qgg/kEtt4y2yoli
# DATA 43mUdiej3CJoTyxueOE++zXcMXWzl74BX7lvMB/C0uUYyxa1djnWLQ83AyoqA0eWdiCGPQpbgAI7iSSBsDPlHgWug7BpQthroQ3M
# DATA vFHjEB/q4tZoANGU9jJkDh1qUyR/8s6DubOWMgE0sc85HmESeCm1g08gTaJ5Qa0qg7XNrd4fibjaY5CDQ4dYX1ZJxlqLUFbt9Xjl
# DATA dHyysmo7npglKChxeMvRUL0bruuMWw8Hk1RgkgXLW4fJy9128XkyZ8uhgOttNIH+XUrntfvFgoT73W3iUs2vPZj+KlQOYj56Wdnc
# DATA lPvlL6D5LTn/dKt51wd/ntqtRCNAYnhhT3sAshgagEWMMmU/SYS6rnyeKvYmipxlFzNvY8msIgU+YapYIOszJ3r+xh/+96/4f+il
# DATA Bef8K8r9PDf/8+rK6vurd7z8zys337/zh/zPX8f//KTM+nc+vVx+5i6oWvJgtubjNIdEzObn9GRwybzN9ejpbJI9BfyLkjTOWVeJ
# DATA U3kwdfOZeTxT1wtFFh+u7a493vqo83Rt92MtalmFuzXJxuZsdJTolQ5GR+RDCK5iug6ds/gmJyyWeYufrG1ufLi+s2sTG4OjKr4C
# DATA E+rjNXp6lx5h5JhOdXz3djEtMiRDELWj2XVj8yPzjXrvvtAf3r0d6Jwp9Wj9KU7Dt5Z2dlWPOptrT9CRs2nSmRDDXfrjrWfbm2uP
# DATA AwUaIvcVF8ZLTaAqckvcXn+4vvF01xSwNR2k3RezMVey9fhRZ2f32QeASRPfv9Yb4SbDDfTgPvw3GqTDo/b1bHj9wX1M74hQKNm0
# DATA fR0h8tRTDPJ6wDEM95fp5/2xfgKXH+vhen95/OD+MlYPEQobj9Y3dzc+3FjfpvCX7uhk3AdJAaGNNK4Rwhrdfv/i+ffV1vh4/dNA
# DATA 2UPExL57m8rsbn13fbO01K2bVGr90931zZ2Nrc0dBLFoQq8wYqWb55TRk/7JXx7hv9NXU36MgnHcfMXlT7MDdVT7h0rYii/U7u8O
# DATA 0jyPdtRk04XZ3p2NXjvXIVKdIoyaD6E2Fz6tGjqNlZOmN/GjZ08fbzyEjfjHO1ubne+uf+bYcMJAaS5IGvcdZoIQGVtB257QFxF+
# DATA 2sHZtOAGwkB1QfhFL3xrATy2jgBk0xkdJfITX2hg5I8y8XQ7684w3IHWKeDJUZjHjc3vrT3eeISzqO62SFnxGz09SOI8NEEv2N9m
# DATA wU6c3AcQo8+Yg+rX6rdQXRM/f45hT/iiomPPNnfWPlzvrO3srO8iCY4TB9tYEnqZQQquX2GIY7i0E+bkNY12qJEJDOgxwBPc8YGC
# DATA 5maB3pcJofGgfxvzQUOVQVgjeAGTcE4hJ81mfEGRbpOpAJpqhlNKet2ofaelWO2Px5Phj9PZqx8PZ4MfK3qxt6q69ePBeIp/JKrQ
# DATA 82bzRvId7hXctpsbxSvZIffChYJOTBhePjs87L9S2/cUrklao2GJUHKFFQ1gRnZ6I7x1XHrfOcvKe+9BdPPOrQWOwKOtJ2sbm6F8
# DATA PIaYYY3NCeR7H+P6qNWiw97vDVP1U5/9NO/2++o3T1QZhNtlTqjunjyjEiONc7rTcKuSl/OeVVtCsqa7qxf6De4SxeqkzaU8dAwm
# DATA G8pa0q1THjTjJEkuO/FBGg2q2gIureOD9Q4Az/Umhzuwqampdtqxkyy3bF9TSL/d1v+jA6DDdBwpYWmqyCa8ALvvlMRfeNY/UFOZ
# DATA o8YC1O2vbq+szGHZOEE7nz15vLH5XddDNIxPXo0lPqcxuShrmw+VeL217TZaG+XkSAkqD8TMI8tLeZNBR71K5PUqRPVFZuuT7Q30
# DATA yyoZgp23tpg34T+aY9Th288mdmZza7ejPlx/qPrx2aU7gt4SV4d2X7iHqr5nj9e28bpTis7eIbuTQMBmCiIpjVVEF46yOcgcc3lD
# DATA Huj9pJD61Z7csBK4c5K+yCwCvgXsRySxO3fKTwsSKlt9gVph7TgoUacdWWhq3K7QAMUmQVNWh8ZqMbzpt+fgNyl1UML5EsY/N79n
# DATA 0RNJnVW7ZHhsOTsq/AeZQuew16YWqZ7iSvL4fET+8g0gHHwoxW3bg9jX5HEEnm7W8kdEsfD6g43NNXVw4GXIJtgRSP7YXCIw9ZXE
# DATA kaUnAdxYEyJHJRZE1tfQreLI2Udu/Jt9Pg8z3z+NqJV4vPFkY7eIks+9LcPJTw+n2WTu6EJo+uhebfvcH47q3hDk7xMIdegMCVq2
# DATA hq2ar8wv+sj8NN9UiAQ4/ocfr21+tP6oCNBfEsPpnKmWt4lNHl7HLK5Z2DXDwlpugKBrpRWmxPCGxl+GxvsW7aXK/BNMe/TmLUrR
# DATA obsF5IxD4WtvteXhTGrMfdsGXFuwcnPgQ3GhpRGQzn1djgJbCglclfGnWj1wRf5fBg1/GRGAlth27tLhoAWaE8g5/U7ofUXWEtFu
# DATA Mj+SpYQ+X85mOXd7FC2T8gi78y3eOMeBmBSds4JrSJBt8ZqAbkhrkmshpdQ4PYMywK0IcEsoqp040IIGujrtyyK3UaJsXOeTjZ2d
# DATA jc2PindSp7sMe9XW/fYVZBZ/4/mEcLtdLBSTlVg3C7oq+F1gcdiQBD3QCXxZO8AFXChvSt6HLxDwhJ8C/5vD5fT91ZmTR+pfia2t
# DATA ik/SAaYYhTb2BMSvQQBnNB1A1EALLZhVyFW0xt/zuYyzl+kgTiqAN201zYNR76yOVT0c4WuC4sRUIF6xppsaRHHbdzB04G88Fh5F
# DATA B7rvt+3lWRxPavAhgXzSZ++gL5P0FLPcv5oajY1Uz4aVrDtnw2n6KqhbVXxYTePl1ayBPgb0OajOSU8TxhtwjvCiZ1MKXix0kaob
# DATA Ki5RqJE+GjN94KnIpixcXQPbQt49zk5S7f+dk8oSdxMU2tPv9/0MM+5b72AtNFNahBqd5qxk3+M+7JeMBIoK+FlHJQ3vUCPtWNiu
# DATA 2KWAmUPVj3dE1YwLylLsozfZ6gnPdb+HMVpghiI/fRMigGh7EIiK81/gWsU29qCyfVdNak1WUjWoy2Ix88vq9ULtaSWj1yaYXrys
# DATA H/y0ScpTg+urn8NmP0lf9U9mJ2VA/RKV3wPk5wnnmoyxSVcI2reamc5VJdsAeqE7q7furiT7SXIFYiPjdxnLD2ePlqkKJpkDvM0m
# DATA gNe39D6lcGO9Ua3d9zI9xA+c+OJBDxHbYLu5Ycckr4gIJMKrCcYgkVXIhe3TI1QPm10lf0FTEH831I3y+MTwuTG7UeLnr1ZWUC2r
# DATA +8G7hH/6xDuZg8hy+QnS2Hzn56SVvrhwuqMFexylsNSg2TVZVKanqjuK8Dxc/3jr8aP17Q6Aa65/uuv1hGYOIkxq3ry6qswYMfSp
# DATA F9ooQ1sRJvX2yu3wqyD1OI/Tg9FsaizJ+GtZNHDR7GMCkAwN+bxNF9LPba//u2fqcvlISaofre9Y8dHBX8l5d3ph+eAJNwQvRtAB
# DATA obxswjbN9nWf6PvI0DMW4rbVyjrSgds64SbdjBcaDYjbat0eP94A01fR/Gwo6D4RhFLzhifr6zx654qEtQxV00SNfAAr+ENyIbmQ
# DATA d5sgQU+d532rDkN/RmJGaHUrWPBhwlr6CFhpXRyROjpbaExDqqYe/XA2mrI/b2JIQ+HQ2CjsTGDrVdAldrWUJFZTKc64wXvF2ADn
# DATA kw3XLZ7NWHquiD/PTqoqrP7+CnLc9vom0AUpxoX2Di0feh+ZeVdzoZZoqhW29BjkP7aq8jJLmcrbJgY7nWvShMOVaQJGl+9ubn2y
# DATA SZRVS1Zu58V+y/d09ftm6xmD39mwKxVhQtfVDui6FtNRVKuvaJ9dRh8W1DsHNReoSIIhhRQOwZjgKqWNDMclkb2gtLmENvuTbTlY
# DATA J6xl/dOHj79yNTerfiAcpkTZzcpfGjZeSPxXh4NZfizkGTPfBb0xTyGd357jYMA7tCaCBdjDIBvmioN00KjfZsB+oEIdgIXhTFt5
# DATA pnZBqpYpb9fiOhDlVpzohDBJ4dbJ/VAfnPS7PB2yMyUrBydmNEkxhzTuWuGGKBztcKoaAJ0KvoxN+M9tRfyPM84rxFvI1Fb3ZySg
# DATA vq3QvC1+/OaoCXntNIsR/SumWw2Hq4e+5qMtTnk+6Xacs6sOUj7tlBxnS42a8lXh3DLBpDZLDH0cjG/KmZ3AL4LKf2fC3539zQDd
# DATA VdrdRMd49sJqS3XS4O5nsnhyzCeNgsIlC5mE4XF5JmFju5hkXXXvExjp09EUdWoUpAmAmpxeixtSNzmRP4vft9xb0AQCy8dIJrlA
# DATA czwa1xJvw+uybliSw0YcG8scTlVYQaq/9MCU8iz67ivlWpx5mRrVWZtFZyDTrvjlJ9vgkRWHHszovFjeZy//M28Mk/7Zc3YG5RMu
# DATA 8YOo6MvcKvVtCgtku9vrRXOmf6YACx2HHS3TSHCBwkMgGxOVotTowazQ4bCpTMlN/ZeZZgP6d2c6qjEeJIR1qb1XS8omsNrRBRfz
# DATA bfx/yqw2YfAROzBcUZN0IrahuXUz6qT8e32U9fcsJeEuABNz+Mty6JMFbE4lBkEBGOu52jeIfrUqneuuuAktdXyv7XSltHSvf5Tl
# DATA QKk5/qKZH6c379ytldf/VThDBGFn3sJBIvS/SzhNlKztO3SkuOYuD/ot6Af94QiPoOPHIL9QP5PWXN/MRdwSys+hTVrp9rzyM2K4
# DATA 5uP5fTzgUHvpEHKi7qiQhP5u3daUzHdF5fXBGlsLZXp9mwmyR6c5G4NbVQ0bnv+RndkG6XkX+I6UVGaCVr/ixV/M/aako1+79827
# DATA HH2B/SDOnOU8xeHwHlBXK/qrJgN4g1f7UrHpEo4KLCF7JNtc4rSKjMWjJJH9MzoWRItxlSzGX1qCUzpe1CHgD09cd8yN0t+uGO2W
# DATA uMohzDuiesV9o7s+dzf0zvS7dkVL5ov+kDSprIlCZSqqoqydDV6ru03R3nY126d9jI3jQx+uDPEHQinLvSHu2Y4vYuHzPymElxgN
# DATA IRbkidjHWXMfBYw5VIAVsnbuC0Mw9i3ng4Cdq7QNXA1vvB+vf1ocKJZbKASBfNN3rbrSap5ZPuoPI6fDRcNYyCgWsLFjdZWdxxKX
# DATA MkTKni/gaAgMR5EHJRUPRmcAWxbSGtq36i5j4jQdCRgzxEww7DKwgRsvV3UCJ1eRJPWXVEXBL2kdyY8Xw1CMi/DceTNIkIf14Zal
# DATA vy9rEYShxoXQiqfZBAEU2f+jBCQ5zHY+eLbzWdHPw7nVS9lWIgpVCdUBHV1ohqQ2YjiNA2CSFPV8kr/sTqaFt/QYA3KVzOJkpuBX
# DATA j9XO+OAxpPNYXURDV4Cocq4WiyTBUPMifm9+UFisaiTryyzS1TNtdFRfEHq6NsgOId6uf3Q8dRltfpY3gRIrWnPipOpRDHb2Kk7C
# DATA SaAJoKp/wFpgCqhvPnz0+DHnKZjlWQcD6wWUzuFsyOgfZktxFYT5qDZIOr2pthUGVelOmq8qs1I7DTTTyRH2CJPdU9+6HYRxNL/A
# DATA YaMzFg/mvJ6p9/tuK4AJAzHebaeSon4U5h7vh/BHR+t69VtaE3iNf3UCSlTdYs2pAAVjVunDC8pgWHeqcUvhG13sJqW6Ls0xzGDX
# DATA PTE+tWq0qNY4hwUgiNQgru98tmPg1pGmmV9bTze3dneePX16UbGGdDD48NS66KIKmj/FR80Ta0JB+HxyagQFSz5VhwNmytFe6/d2
# DATA J2rmYsp7amHxJqQZDvtTrIN6ZW13Y2uTdC07In/twocscEbmHq7S0zP3BAVHs7a79WTjYUcbgBW/7TzbXPve2sZjcAGXfjxfy3Fb
# DATA 9MgVjh0tOylm8M/C0ZMbBoqJ350Sw5E5il6V8pixIy+fs2Klbmm51/iTVR8W1QZPVh3H4qrOPUYG4KmUQaMtC4XK0DFbKrLYq+0n
# DATA Mm/xzEmjgHca2Z50TbsyN/116mgTt/eJIRmE2oFIeUK8dA2fxu2ECIUI7w9CEZKpwVame7kcxdRaHsPfRiiF65xDb3R7bVEJ+j/S
# DATA cxD7/cpzNizo0tbjg98vGCz8wdrD7z57ioCnVcHPlH2mIKyHVQAjAF8ES50id+Athg5T4tuCJTqoGpikp/qaXXJHcG4HFhHGc/Wo
# DATA uvkXkflFrl+bLsPA9VuHpW6mJC1nA6WT7jHYBVpl+gcuoPoqMWUqNBLvQKdgO2hUCHXGpvu6dQmMl1NQKfCl3nYUayjuuDJEjGow
# DATA Bvday4fYcZTakxf1ojpCTwhO2X4hV2wtqB3g0vPVA1wwSRbXENCJjaUkY3eWPQXOJZlCD/xtKAuXHI5g6SSQyMJsWI8WgKe/PN1I
# DATA 7tLTIvlEscUqeXhi5kldTL5cpWqxCcEfPBWejUcIaS4oJHICbjWZc9gFF6lH09GLTImQo0GvHg2zU8ZVrDOLkhgReh1CpG3JZh0o
# DATA 6TpFH4umHTFPsAiLRNzLXsKcim/clwvdSmmOUR/22c7u+hMhA+rt4TShNktN4GSBCxBOkXBr8AK8uRqMNF9ZcaNxylZSqHHCW9oE
# DATA mQRLujTYaK0NEW1Fq5qOtirpWb0gfEli1gpQMk2JW7hlip/T3m9Fb3OUZHYTkok0f9L7jJxlHB4an56eUtgZbEJFtsI7FQqoF5eL
# DATA PWaG6M0v7gv1Nx8hlpc4VwuIDXK3Q+6IQY+nTclT2an6Gw6cM4VQZucdzKBXq14UPtsxHW54gH9cyLgps5uQN2vXWw9j70Z0c94M
# DATA mi+ktV376zkrJwHvyCEzCCFEMtFhf9jPj8vomaMH5RuE8HLNDmDz+9IX7hyZUfGoUMRxDsQSIcogMkYtQlEKTQe1jy5FRb5Nu59H
# DATA kzhJD+iV7giqSVQNgTBgTt5H5ep6anz942IdaEPytlPxBmeoonGj2uMq6jTrSSBamW5ELqOREYe8yHW7/woJBvM8mGNm3laian6g
# DATA TsgQfeVK96xUSXLxovlPv7iyBZArqJccx7cXu4mcuXSMqRYTrLqgT0YSt+Tk3cnkC5jtsLOekIqIj0UrFhVNwrK7GOy+RqaXuyAk
# DATA uRcv0SFpekGBPowh50v4sAr79cj8oEUIiPzB2YLFW0Cgx2Kllwha5IVvEVzctBqMlfKg1SyVlDidsR63rvMyN47d7bXNnbWHuzbC
# DATA SAOfhwzi9lKDUmnp7cm9OnBFpPpchG+4G3PpMsJo4FPBdqyIaDnLXK6XvRorURajGsU+KOSfdhadsdnp4gnnRlfyluvSWUQ9Mu8i
# DATA 0p1NUIfVfisZiu1ELzV3gjYdvlfn33b5E22YhGxPUN74k2DShPB0Fq6huvvmPmnPu01tM8DNYucd3+DMtHUH5qr9aV5dUZeSQQqi
# DATA s1QliFTpkuTucMSAS6gIuK6emXsj2RgFaylxEnrgSf8IA7jco+V+uuQaxYvjolqS6k1/ydu+PWNHmSPH6eWFWadkVjwRQTuIuRHx
# DATA SOVtKNzHK/TTio1uK/XIPwC+KB0+JnDf8EbJH3i7unzsdlsGrtfYVdtoQMZF+TYgjIqe+kBwpeJowVRP7Zs63Y17iU4KClQvnocK
# DATA WlQPHhkcM8673G5zJl4sUYWG5zJDCQxAkkDs4GJchW0zD7e+t779GYSBf/h44+FunFTRLTPc+cerOKziShYXh2ydJSTLnHbTJ8x0
# DATA xB/PpZaVA/46eSMXuGYYjpvSt5yLLYRzGuBN89Px6SgwK0tUHlHWRtjSrP5MSoUfaazD+fVb0j3g65q0EPpLwZe+c76DsNJIs8/Q
# DATA 3rX6nSg+yobZBLek+lCfE0/vYzwVW0ZgM76Lc4SRC31LVpfkaT8dUIS0Pq2OGw4/LI9DMy4Z4aivy8QmG53DZcKTdQffUayXo6bR
# DATA MRaXD+8i84dhEBzmDy5XocCtw/4Eg0yGkIiJS/j+EtrOj0XL0/56i+J/aRERJSgGXBuLTVd7XxccZLzQLWpu0dCtUPjIWwIuF6Fy
# DATA H5BN0IksuUbutjpLRrLgQAvaPGfBQXoS81sIjGL9liGLFVWFQsIW65FjaC7rmDN2VOrpXwVlnOltvQiOl7ztCELhwovEAVT5GAKQ
# DATA WjZ5GfLldSH4tM7AZ6qubXGpZDJYSZkUKxQhuswM4M0MMsHHpnOgYyMZFQwIHD8vAvuIcQSsIe+OHfgMh58ZziVZBmc9ZUwNcYPy
# DATA 8TXa8UQRzdEJxodgzLkGBxAXNWmCrETigOhxUDhyVYY2HYxGg4ArvO6EVYuZR+QFQF0zN+5gQIBBCllYHwUQPus7BljOrpnjsOMY
# DATA 3OzZsKqcgIs5X8Zs6UVV1zb8u6C9VrMSUlw7Ieg03TbOhWuD375kYApVSRWSMAXPJ5aSV/l2uWdUwTZEGInQYyHKOTeRJWGv9lsl
# DATA WaTM/V8HQL3MWP2ziLHKdEp/519WxCQHqfcCJIMQNgoUw9y9guFcklyY3rkBMy5NEIXE831JJkQRfrZ/4cd6yA115Q202Ca6lNox
# DATA wAdC14zAKMIq1HKxefHOk7YusH9JyqIpgregHD53GigLfdvbd13a6ot9ZSL9KoSHuv+5eeOE/5V2oHKrhO758IyRl5zJuMpUVwA9
# DATA Edr2qN8lN+J+T33YP+xnEzTliJ+MAKW7X5u/SSzeJkim8ERU124X+XhiFZl5NtB6/dqC/N6jN8T/Oelfk4ZY45ESJJlhmW3BMvEr
# DATA /ca5ueseBeGwLg2JJQEjHVws3Y7AxbKx/S8ykCB8XJ+C/T/AYSu9AHwZ1ncTYiWRl47issCR03SirjgY7w3dXI4K8BjMuahg08co
# DATA keBFWMI07Pu1WlCs27fd/jJAh0WSO+ex3ZAYPwwhqMgqpew+ypqTo8HooBbfiJPkog5YfO1BenLQS7FYy88kVtdZQihSIKSJ9RFS
# DATA hhmrvYrOOhXOUE78astsUhvJ2tKSazjsmSMaWxrozyNyZdCbjrJt/j64KGud3bGk54VDKB2nHjNDJZ49i6jmgp49jhnCaGmuBTxA
# DATA Fg0tl7ruy7oxdhz7pHhUyCYopSemer1YSIlB3oIELuZ7TlDYCvjVlQlfZZvPka0CY7JSlZ4pKVRpdENM/V28ilHBulEcdmxrpbev
# DATA IFh68etyL4NA8YXvTR+tb65vrwlz8Vd6dbrq7cJa8UWPqFTixU1wUREVIhvVoM8L+kfoyjAI51LRE/GiFxvwLCq9RybOlbGqXNj/
# DATA qQqwx/gJdJ6ubz5y8W6tNaNEBr6M4qZouAhsWBzfgj4RXNNC47T7O0AK2RxNYk65xT3kiEjz4vmFOOM1hbVBEPi2fgbestSiHthb
# DATA 2bqZHvU63roEPfX5WkyNz/fCsfFIsgl/kdzXcrX0mP3Lgddjp7250qSNxlqUhfGmsXbGutcH45vvHPpqvkbfv6VSwFUIeNPoXCy8
# DATA SStxS8Y6HS5nhyxVBggGXWBtqP9TIuxLN4+lkhcn6AhFedaba5OjGUz2U3xTE0DP7XiDGHh0MBv2FBuPFPlLBxEQWc0uciSMo9k0
# DATA wnkDvRbkRIA+502TUBdqBozxTsqN1eJGQ+KugV6y/dSoCcq+IGmzsozAWVGTkKqZMUrUyu9o9hoTcupcrD8sAQF76dKEkTAxVRun
# DATA ujWYoyt8xttm4Q5q8twQm0jzYQRY4+/wH/gyxw2TBNNUw+smdLxw/ukAF6/86EqBn3HHC045+NLJ4mjN/epNiL34ZbQYqn+zCrzS
# DATA 7sbDpmhZO69qLD+cqc7kkdidSBSDU1k3e99sBeiFt08L8+SInO4E1J3ZqpdOAr8JqkqLVvz582znbLH58ieHv0/tFPai2VDdzWAm
# DATA YctA1bNcUdWSOXEsIsE50aYR/GFNE3ILVM3KeNJXR0IAL1PTiyAvJwXWsTLPjBXABSl04DzGEsxU8G+49Bf7o+RiuOe2AWcgn6rr
# DATA /KTQoVVF8s1xNQlnQNVmk6wIyH5zUveXwlZUpwoA8oeLK6IPdTqoyOp0YDU6HfZCgK4p+XZaQ56jJuwbl/8fcBVcf607bI7PvvGO
# DATA /7ei/nf39m38V/3P+ffm6uqt27fe18/o+erq++/f+Ua08o2v4X8zwI5QzX/jX+f//Nxr59dJPXW9tVq/jqLG9dbe+fV+73rrOgp2
# DATA U0Uf1FG5Xr+OWSrU49d/++Ynb/7i9Rdv/uz1L1//6s2fvfnpm5+8/nn0+ovo9e/UX79986fqmXry+kv46/Xnr3+rPhYCD1Txf6rX
# DATA //T671Xhn5R8VY/Uv3+hWvjNm79WRV7/Gl6pRlVRVeWvoDX1f79ST3/95meqGz9V//6N+pBqVMV/++av1MtfvP6iqZpHFdb11vl1
# DATA nUNFdeL+td4IYSAw6cWD58+H9+GPaKAkrPbz59ezofrPg/vHWdp7cP8km6aYoSjPpvAStWf4Ht/AoYXHL/vZKcAiqT+1Bg0en/Z7
# DATA 0+N2T0mV3ayBP+raEtDIlbCXtVdtXcfT6bgB9P0lfPqQamnsQN6y/vSs8XQ06HfPvAZYCGvkk270PM6zweHz+F5EU+4/nJ4NMu9Z
# DATA /+TIeYKucq170ejgB2r5+dVQMS0ofJDmWUP1RTwCUJYGiVn2aXF2xCbw+r8WveznM5R6p9nBaPQiwnQ1Sso9OoY7ybFiJMejQS9H
# DATA Vjg9VpJxqthilJ+A4EyXCUioHIG2Wz1XbOkkytIczBPTETDFZrQznfXO8NvRpNcfAuwSI8kqgQ5E6hMAhMRe41Z/8BRU2yDeHIL3
# DATA SPTj6N/N+tk0ejkaKNHv/jIVuo/+OpNsAMPod2lkqruH8Hs5zdV+yZfheTN/eQTvUKaEsieq+mX18L1XJwNsVdaEq5QfZ9k0VB8s
# DATA QbOb55f8DO18+jNaCoDQLxT5AZQAwT6bPLi/TAXVH3gS4JhAuj/cIqgEgs8lqcDa1WEZqCqxTy/6Y9mbbwL7gkI76gWsDu+D+8sp
# DATA nTZoVXx/ABcLZzjWtAfVuKui6himL5WM0k8bg/SApuUJyE3qcf8o5c0HLZTUt/Uym8A5xrpEqVztn36Wm3I74xQOcMTP/eKwBU3Z
# DATA bdiPp6PJC1wbLLqs+sOTCgMm0bAHn+r5uc+pmexUjMHWA18QZVp9sHucqiUcg0xsAtrUFld/K1lt2FTVrz64P1bFsgi+VcfjLDpO
# DATA X6o/Ri9BuwuZ/47xAEAqR3wNq4FiJuzUUTNS36prM7rDKUlcnbYpHLGz0QyWDj7Wiip9dFWr4wf3e/2Xtt9EGnJ/ZxzMplPvwLhL
# DATA 8YESMnUzB5m69wLeLk+0VwuYB0fDnjrVTn2LLNqy6ivsc5rtwLTzA5r0mw+2JtG4rzo2G6tJUqTlcKYmZTQawHTfhOl+mA66MzRH
# DATA Hg5GKP1nKfl3R0jto94kPQWKA359MMNqvczmiHqjjJayl00BrVDdIJTsOoOzpToOdl8ErkEgo+5Iieh9UILTrF9m/5nxLsOGe3D/
# DATA UInysBPH7olSu0tOBWh96ZYA9drcUao+VfCBXnunKzYRGXyzhpT9j9KT8T2Q11+m3TPoUPT//lN0qf7TquleLwNRgvPEvFwxfdvs
# DATA H7j9H7j9PG5P2/IKTP4d8/irsfj5HP5/IAb/jvn7Quz9ctz9a2HutCPl8A1D/5dzgpDgz+editKP8kxz0DXNNkmdp1pE7q75pxwy
# DATA yDWpHebokAMg1djVtkK1Ci8RT0G3P0Hmiwo8byJwelCk0Sw4R3XaIEsnCOV/opi22lmDOjJgNYj+SdaLDmb9wRRGAPQxpyGrnj7L
# DATA 4ROUtnT/9AigBcvRu1oeyH2BgMSB0XBw1ow2plqG60Keb+D4MHGKbaGm2Zq1tSiQ9oDDoHoRuwiL0kCxAM56niOOUbSTZS+iH6q9
# DATA As5a2rhwnA3GqKuCTkbp4SGsEggk6WE2PTMj/Gw0m1gezUNTkk4eTWZDI2oegLNTNmlG65xoCKYUxjEbg7QCcqbehbDHc5RhVAFI
# DATA oTACIUmRhxzKpIOzab+L0o0aWzaZgo3/SA0hBf8L7doGdXWPs+4LVHmiaQfVnk5n/vtP/recxwpaXvQLyrujsaoH5UmxZs3/j713
# DATA XXLkuPZ7X6Ucsja7RQCDKty7OaMzvEn0JimaQ4lxQtSHAlBolAZAgVVA97RmT4Qu3lt2yHHk8Ik4O8IRtsMR53yntEV7rAsVYb9A
# DATA 9yvsJznrv1ZmVlbh0uie7p5bSiQbKFRl5T1Xrsz8/7x3UP4er8uz4gUl7BQpV2HhCUT1GK+IplRSIx0oe1yprYcx9UWTqMJ2ICgm
# DATA MJQlb2d5zKlNLLiw6Rm6w+SIxwcDVMWa33s3OZmJmYeMlJ1lA6ox2LFWiprUU7klgxFOUaVWjh5uEElFHyeZFC32FKZs4j+Monne
# DATA qMPBALb/JEFjGAz4+hECiqGQCOElzkwaPRBOVvM+Tvi+JZca3R6lXGTIS9OiEOgcER5HupOg6vMRept4IUmgoO3mQjm2pMrN1Vy1
# DATA Vt0qo0dkLCKJJxSYyYoRT14KBfkBxdhsXMog7oHdeEPpYDwcL6ESSmN9rnQYIoo17210PrL3AEWSYlyMqG9R1ZXeg/Nb/JtUKWXt
# DATA X3mas9tgs9MMZ0cz+daM/avY+tdg6heNJrL3v/O4nzwi8+VnwNf0uZZW6coTPPSYLJ5kMqn2I5oLx0l6kE0p6PEThPt4GqZUGw7q
# DATA h1jhOErh+jk4DtO9anUezqN0/3CQTOgRuUR22f4h+q8DvzN/dMevtVue/IKw9g+xy5y6/JPqSRrOD/pUAx9WKW3DJ+FjCSaeUQOJ
# DATA F4fQ9q8usXWUbL2omoxGlKCDWhBE0yfhwRjhPOZ7hmCBcCOpUuUfPJxR2z0I5o+eSCWpxLP5clGR/VsVPIGx5jFHUb1L31mTv4+H
# DATA cUbD8Cn9zK8eTaJHhzRaHM2qvOXvYBABE334U2qd8ei0qtqXvkzzUzJaMK4eNJvzR4dzMQ4OKCeoz/T8mo+/h1ICB/78kZfRlGbo
# DATA Wfm3ktHoPGaLYk5TevVlVZppOIyXmfpZvlQoBlIe1ROJU7tVP6SpVEbhzBPmXR+WsvEAExiVJzXTxHTu5FceW9GkbmqWyY6pleqg
# DATA gvoxW6jYy51Fw7tYdP7J45WEcvLtAKSKqSAOqGQwqgwfJ/NwQLPBg1qrpVOj5oBUOUZkIGRVsgdjjEDq0eJFrhSla1JFShd1hSnf
# DATA u5xSszgtXn1MTRs15qBRKlS+i+q+/KzrMhXNE4kH9dd7P+YpEg/j1Cp/sm9dRFEmP9lfqcM8kz7w6/VvFypdmyrdhtqF1+/v3o7z
# DATA qouaW+tYFVdXtoZORCn+FeuixF9FN6Cmeaiiyp+lEldXOxFqdtVsnNKXg/qTQnBkq//ksY5c/YnJECsX/G6dwqbKFv8sOmDLiYap
# DATA Jzw/Mu37KI2Hh0fUDdUanLJCM6nX5e4aJ8k8s6kz4GA6CKXc/u1QmxTqCNQFKv/HW8tIp86vBS0dqmQgxSs6olH8sR1wp143j9S9
# DATA WpMeeTL2K+OgMm5U5qoLry6SOT0+9qX3k9dhfgUzWQKqgLSM8W463wtqTby60q61jk8qrRq+7FOPXm+qmKo82T+ckCVEVQJuV0RA
# DATA fqUugckalWqt3mjRo4fT8JFKg98ejA9VpPoJtc8pJbTBkQ52i5wv3WmlQVELOOMRNb97QdQoLkEL2Vl8N7+5IW+ml3gq1ynERjnA
# DATA 4pPcMp4gg3XS2p3B+Ek8Papkx0em1jAJ7dBqr6qChMtF8kTmxBXeZyAjumoqwMX5QZ0qcgUTpj086VW9Nvp0ExEZpOyQLqyr5YGL
# DATA 3eU09i9OomjGNdmvtUpV2a+3TLdism1dzX1SY++F5GVH8rIpeRms5qXOtaBOFWLtOERziWKCuF9g6wH/kYYXqKGV/z5hd8iFuVBu
# DATA p5ve7oUycimv/l2YwD8pmx4HxlI5LDXLJzV4gx5DPIFvHMWPouHhz6rsg6F0H6JRVn2U8iGIG5TTyOgNXbTpFpBODlmGoMcIBU8+
# DATA qZFJk+jOsSrMwDbKrtjr0X/MnjX0vcvpLDvwR6lH/27q37iBcvhejSwHeg2nlbtYbdbkRdpsUUOQu0fx0TKNjCGZXx2E7A21wql1
# DATA gzRvn0hVrcuvVVOJi+tCt/S8L220pgz+Uta06nm15rvX12n1MHdIxSjs3JjsTKXue6X7a9mx5Bd51BkW76KsQ8k93qEs02hOs8K9
# DATA RoXqORXKXr1CJUvdRh6jJ7VBmA4fWyOLNeq0eagv18JsmY5whPsC+2K7OSrv9eYHmP1XB+N4MlxNJt9Sg/u8UpsuaVL62DYQ+AoF
# DATA hN/tytOTPDzBtnzbGuitbVPrzecWdbJN+rdB/7ZhWpXKietnoQDYZ1dsLhsMdTPAIJBSbyhpPpgtxpIne8Fs39Np2VQSwarV9qRm
# DATA /Kbluk7dACULnYS5xVPWgGSgGfgxtGLUxweECF+lNch1umjbfNWzB79OHdcpPfFilzpKmal6HN29FFoJQ22e1OBbMNZecJP1Em/i
# DATA xZxVE1GPLTUx3y7RAoO1LZDDks2AjwudlZh7dj/vqTq3pQ6olPH40Vw3o7TaQkO6o5MxH5ZEb3VAkzLuRXWMDigpi1OTRh4Ja7Jt
# DATA vWBj11raalbNL5BuRfsi11jaTTt19UPcVeUFHPWW3I85iR/vYG6U5ijUc9C8KR5Ej+0sKc/HdHPUzUPG3ZoUCk0vjywjykS9vsMw
# DATA Ic96IaYbNB/coZIU6oZnvgX4BptutUHYY0qxv/bquxloxVh6c2tgVj9lNLjPjh6X/AbUQMKjsndETNstddMUUCCTyLRYZ7rt1Unl
# DATA hqbZD0u2rW5JK2NryS4od+FiEKggPZkU4pED35pn+U3uKaUp5Blddt4Mw2wcFTP4x+N4OIxmPyk0oH8heMBwtnhCze2x8YM9YtPd
# DATA nhthfpC/r3lB07ezsrupYZfcbuHs9ARu6CdYG5FSHoXTeHJ68A6ZWAmNy5Uv3vgw7uu97x8ls+SLNypT+sPhFts85eWQxuF4klnZ
# DATA FOxeH5Uv5XHJK1V2WpXsdf1OrzC75SasJlEXNdfD4ujIMQ7UxCcPsWEP9+uMzh0MwHKV7+axtFqfVQdaGF/VDQW3Bs9UdvNPUo+d
# DATA e6tLM9EN1aE2jyeTapqcXGxlK5t6Ec1NqetutJn/hE7ctP+m6qAXcOFxeOVW8IR/0gVHXeQknGdklagP9gTaroE8MC/GlcVQpmWc
# DATA FweITWEc3akyLrbZWk9qFIPoMffk0oEf+HeqPo+Nlo/IMhrEZkiWi/lywScSypklcyrepV/Fss0aaxbH08JFkj7Ww+46W1ZqtO7o
# DATA TIV+8n9Mo2Ec7lkmWpu6tf3HG50Otqeh0Ubfq7wKxdaibJLV0Ykri5yiwHRXssmuMzw/3Tj/LDXKBmaudlYW55PG6dLivprnRpcy
# DATA xrSxujk+9svXTyEbWGwozhB3zJYVg2HztDwYaR9jy7JS9IP37LmUXT2DkvmszdjVetFscL3gPKxoK3djfNgtI64XHtV7eeEUJhSB
# DATA uOnUVLM4POye+p2Ty53ImvkPd+RUlUy657ykmVXTaLgcRMPqNOFika/UOtatiXHg36l850A2fdCHcIR2E87iae4yysf5Q14Uidf8
# DATA oqMhp3N0W5RmWNGLUWWHh9jHXJrK/LBcvrJSZ/UKbAWouWGf5qcPzWyjfNOTJ4UVQ71rCzsE6Y/3aDqZ8don9uUd3LlzcnJSO2nU
# DATA kvToTlCv1++oDV7YQPR28gg31r26127SP7zsixrvyQZA+s4XPenI8u8pP+cH+DyiIYj3TDXqjWGzh42P995iuRLeLfSR3/b83rgR
# DATA HHe/HzSP/fqY/tv9vt/+WeHhUTBqjBryMKJYXBXNaISMnj2RXZrI02SeU5BM1P42vjHfjEUVt3+KX3jfXL67Tm1+MlftReeDfEeP
# DATA 2QMQDXkt/NRswLOypFf3ms2W1+g1vaBVnzTqged3G9VGveP5zUYxY4btYT+qr+Zqp+E1uo0f+Z32JAj8aq/lBT49Xu8e098PEXSr
# DATA HhSDikYjn/OYpwsPOf3farZa9VaUX6yaom+svBShdv3jZuBP69XAb+KV1V6PI6Mi4vlSK674hiCoe0HTP/aDxsT3fa/V/VHQ6/7s
# DATA o2aj5zV8qj5Bd+LXO9Vm50dBu1tMXnfQi8JwJchOi3KlN/aD+rTartM/x/jYpMuNZnfs+3S51aJ/juljKeb9dr/eHK2LeXNjTVXb
# DATA F6miHuBk4WPlCT5QNfyQ5/cHqrEc6qntwbfarXa/gQvG+0SP8P8OjUGzeiU4+FbkR62oc6h8bAffavXanU7rUCyMg2/1R4PuAE+w
# DATA 25l+HrYbwfBQlvcPvnjjQXSURN4PP6DpwmfhmGzPyn3ePpZRV1jNojTGs7pL2+l2dE817LYkkynv0g/EmvSCotO5K4aAud2MRmp+
# DATA 872I2nQcViTo0tLcYdkRBuOs0qk1j08qHXGEccBqp9wu0/ut/i2aqRZDLDvKbTNPFczqA9qHXhwnCnfNC1almJx8A8afQYydRI8v
# DATA sTyQrwWIB7BkFonTqn4548aDi7a8EaPoFahvNGYLqa2sJO0i40559lbqGJsNN2mpPFlt6z9FU//iDezeo04iHix4J/mMN0B6/xL6
# DATA Yt7de2YLZO3LZZSePuB9AUm6l+1b95qb76dpeFobpcl0b/1z9ycTetR6Vu3l+9voFNKL+hm08Bq2A1JseW7pvel98caBHcFpNMXp
# DATA bMGOfRTO9zhQwwpnOeOH0WnFG4WTCSr3vvcYB/7pvxKAyOTznrIHEgkQqT+grN6zIvUmNMr2Dw1VmOkq9NLlZOJ919uTWNTGYYaX
# DATA 7dMldYWCkisHVgQOPBz9FC0CFts/9J7gqPJgTLFSb7hMiHj8iZ1qPlQvyVao2Mf68Uwe1z8cqrwopD/bkP6KxBu1ZHYUj041tspk
# DATA C7bYrEnLCIe7VyMZnu5h8rxviiKCQO2/3PvijW+J5/eLNyhoiA1FEyBaa7hbnc6gG/HtsBTkODnZGKYYo5cOc7ac7sXD/Tw1Hy+n
# DATA /Sjd4zC/gOgf/VrTuVl4dKg2ke6JnBsCFz0LetMXb+DrHWrO8exQH3ORMy5v5LFfpoj+Dz/9sCY7Ln/Ax0PoO9TbvLehofdjhPOT
# DATA ivcYAT9BYcijod2Q5On3JhHrZXzxRsjZENaw+w+aNekE33R80Zooxrg0mMSDh9SmsPX0s3gaJcvF3t4+2jgilUbHZFTkkaJwwH0n
# DATA +1VlhUQF6xu6FDCbwMvtfEpm2NC8N5oh4SgbPMBCeFMIfbx3TJH+UGmtUBjZsj+NqSArXnTMxXaPHuOPNajG0N93ZWPWnipqDoim
# DATA 4zQV+hHoHfHidG+fwp/hhicqqv8S0fuxHLgIj6OfUCRr9OB74WC8pzZ/8osmZDRnoYjRce9CEcJXxOfHP1Fv/BfSA8YZ/93jG+iN
# DATA +rkf/0SXEuU/dsdDl3Nfwpfrp6xkyffXaFSZLIdRpqKRd4j0K73PbJJb3NfS9ihha+sbovaAG+3eKdQ6zTPFyo93fpcq5gNJDnUw
# DATA 8hnnjZ4c6qju5Y+vKRuuL3ifTs51ZJX+vEN2UALkLjKqaWq7d4xYgB1811t7+4H341qNPw8r6+4wBUUWcIZkcjy4e7USI5EuZBF6
# DATA t/wZk61mH/pyPtSbyQsb+FW+v622va/f434oz0hYvKU9U9vZcSaUDIrjqMYt/In8W6zeZsGrWMeTR3kF51syXWz0k8kU8/DmIpSH
# DATA qQxNKChEBLJiA3zxxrqdfHa0+HeJGH+UCHAxSPB5fZDfdU8s39ZVUT55Y9dRZYLkGrmW/bIt2gcqLl9AwnNKtofUNhOFTTVnQ37q
# DATA CKjao7+SfTc7oskgTB+PzXjPvJculmqZbi0b6tWhOVCxvmah2uT1RtUdnT8wV80Izd9UTy430KhPcys2xvgW/b3c3UvT/EC0TE32
# DATA cyazPjGH/F3JRe/v/o5ijQpB/dd0j/4kHyYnUfoOZd6eyWJqCBmLr+lXFp4mKwkJ53qNExN0X/3QsxoEMrVY6eiCXTVYdBHiPXTd
# DATA 7jSLsclrIqdl3/ubv/H2dNTu3tUxQaQ4IFMFTL7dvauSgvqLW2RZj978LzgK0tz4476k5c03paCUsYOVQ539/CU3d/BtX+7Ig5X8
# DATA QO9Yz0ckpVQkZYgbTCDy2766pzR8SFhcSzmGUcYDB5W8LtE1jZHbEdqiVSmQHFOOWxtw4SF6EeKoqillsg5kv1jjcKOyOPb2795j
# DATA m/GLN943h8LQTN7cg9n3xRvS9Cj935HvPAfk5r5I3se2ur1g/00k+H/9vvYF/W/2rp4lJ8mCXa1euPB8mrG8KQHwYTMKgB5a/x4y
# DATA nu4Ub83f5fO7/vc/Wg/qCO3w3GAqjVtmgPmBTHcw2x3MvuhgtjuQ/UofyPYK243VOegX+qC28Zzxz4UTgBPr+PaDOavlYWSLh4CN
# DATA 6NPb+e28rZjPyb1Y57lfllONFwm32I5Sjr94nO+9RT1tuRnqRTJEw6xUdGW9y1rBkwvhhL8VD6qXF6+kSQ8SZK686XQ20NFQfux7
# DATA P1hZ+2IzleyB0sF/6xn+wungDJjf46I9oHKHHgyVF+yhdHGKTcXm+bnoBmTjkE/E6hrlqQ0XNC3k48jLPo1rHry6HuYgFOaXHA/e
# DATA pRQnac37wTya8TnfEZ/dp4fUYX6urB6FNUatozrpyTYExjDhbnozGAsU0EzpBuyovOOVfNxaR4DPE3O0yVogI/sI59KMDM/f4pgz
# DATA KhxOdzPRwftkady93gyXWf1I3hHTT8s5zIas5sGW4h8zNqmSEZw81GKGsNRUsyFzOWEJgNEyJStiuaqG8GoetjUhOOvNWW8XWW/F
# DATA Gub0dZy+zmXNto0G4k3p7jzAFjZLDgKvgW8TwnlGgef5abxtGy6xu8+z5eoKlhyvf7D9gUURtSVHX+PCRickdiz7BHQmKy/g3nT/
# DATA LfGJ6gY44/UoFJKEZp4z3VV+hb1ivP2j1uJNRFrDmpLPG6JwcRryfqOW2kwSzXn3UU169jscx1JUxQthqgO+7RBR/ZSJp7lgotmo
# DATA ta8xmuIZoZ+1l4YvvCWOVhUpfY+JlHnorYQ7/DxyAd58zz8I6m/dSZRVWL6npe5pbbnHr6ub6EN+1x2JVp4UZavr3FSrYPRg3gwW
# DATA tuQRmQ38BBsS6ZTey3uCVTrVaihGL10180vS88TH/KI5jdMLyYE7EgTmTyq3ZJ3WDiW/pHeomSv3LIMzxITM6gBsaSo2GqXZLylV
# DATA EH4xBuVHNBhS/yxGo/ZaW+0fY2w045bPhqIZaONU7Miad3849PhMrDILMj185jak9yHWUJSqJyYCZqRdQjZdHL1slIohTj0O3ohd
# DATA GPS2+XIy4R+XWIalQT1OtfH/wywS5R0RsRHdn7gfUxaLxLwWkdJ1Hgu2GUeBzBIYFmxKoyfCvCbOMC2kJM2k89MqV2yvTyB8b/Vy
# DATA GAP7EetlcqZxBy9FwqXx6lvN9gDoDGdnOF9kOJcMJGc5O8t5uzn8AihWfkZv48aRiWZeOFStITebS5qNGFyMzhsrIj6MFlSgsyOR
# DATA titKLwoTLBlh3EqUBGSulCh6iGUjueSfxXZFKQW1ZfGtcYP157SQs27sFOOGuMyMSCUsGOxTgt5iKNFlMexkNML2L8j0cV+QeePk
# DATA hH72qIRkuOS8rnnKuICkJcXuGOMu+plkxB0D57klXyk+K05OcdBbhOzNvJ9iuJqYkc6kyE7ah+yUCwdk40BI84R6rDxlGHmrPGWQ
# DATA DdGMOg0nGW8Xg6WDJB6RLZbpXm1IhTem3oxLiZMpp3wohBmLisONSKbTkcydxIjR/rJkSlbjQqkLhrAKHnpaKWRLOt8NT7kn3p5Q
# DATA lKG4KlHGOo0PlP9xFEWUrGE8Ymk/mt3BUIPAIfYwYh8CVauFbMFgujH9gqaIX9gE9D5jDI/HfEEEyJYVM2XhGKSqqBNiLLr+8lQq
# DATA 9ekC9RmbRLck8tMoW5NAMSsKVXhVUNVUdbJS2W95AlV4VLIJmiCPOmm0zohFkVa0HQnCWziMcfZOBjqxU5WYJNXeT6H/MqRMJLuQ
# DATA bT8kH3bekowJfuKheFy1S5khZajdU3mn2JN6Kq2lTkdxOuXFkXVzW07UZ5Q3Mh8Ho3eOY6RkJhm1dWpBxnrOF78z8V/L/ZQfXB3J
# DATA FFDT8zATW5h7J+8jLe5JvSvDHtiUViBu40OmxvOQzWNMDcjwpZIOl4sY3UaYsk7XVClPsvqpdCjgQonbmCwEXFdTio2p/dtZciL1
# DATA E62Emgj6SAi26gS/m3D4C+yrRG5LW6QEzeFK4K6RxzaxSyy/Aho/lTK2NMQTA9dKebqQUnFT9pGNRBkmKaQixwFp7MgIVxRkC90w
# DATA TxFmp2U1WTOfsGVlLTtfbOZX0Np/8qRiGDqLI8B501OboPP/nf/q7A9n35z997OvFSPn67O/0P+/Ov+td/ZPYNrQDz+nf3+7is75
# DATA L/TDU7rpKe5n+M1fzn9z9rVHX35nIDp/pEDlMn8FaOeX57+peOf/hp6jZ3Ab6Dnf0Jv+xBiff6AfhKnzp7On57/Wkfkr3fIHAfUA
# DATA tuNYOi/BbAadMo4vUYfTpz+Lgmj2UZRQOGk80CZYzXvv0Xwi4/OEe8RI+oZsHM+pt5hY3gjdOWIVcR7lPoN8LpRMJmp8opdqmd+t
# DATA UB0sJ6rwVEtxaJ3i/Eb3ILcN1llXMjeH18mrjrkVJl1+ufzARPSmzd0fynce0a+ZsMPjmhrWE7W5FYOpA+zsWGzXj9jB2nvE1icK
# DATA p5K7GNn4Re7BIZNFUcEwHdN4wvnIcvvZAjPV0m5ljdREEOZQSrxY4etcXP02OzTXtKznhdm5OBmOs+MsgZuwBDRw54oGwGvi3Ly1
# DATA wf9Gxv6dhv7Ljvy3M/BL9VzNh5zB8+K1rpuA8Vg5wCie4qvXpHcV5EGvm87VSqIqPMqzFC9V4JtIsiZTeVPxlAS2l45PF+MphyIH
# DATA TDiDdkXwqCLLFyKpI54wXmaJlVqopC+Q2wvln5VjcqPwOMGooFgzOsZ4gcBNeDilB7XFoM7VHeb2ghCL4PuBGXESzha2W2yQzB1j
# DATA xzF2HGPnJhk7u44qO01zdrWSb9nkv4rFfx0Gv6PtONqOo+042o6j7TjajqPtONqOo+042o6j7TjajqPtONqOo+042o6j7TjajqPt
# DATA ONqOo+042o6j7TjajqPtONqOo+042s6LRNsJWuFVaTudUWs0eIloO6trzzsxdzh3Ve5hV6bH72q3CwpprWYp15vtbpGbE0XdkQIb
# DATA 4XAjRW/AgTbaLAMy4FADCYalMvxmuwjxaVCGr0EjdZpeM6h7oNv4rd7E79a9oF2i9rT9VqvbXyXlNBte0+/9yO81x83ucRC0pn7H
# DATA 9+o/8uuNcbNz3PCLURgEw2a/vyYRrW49T4Qf9EwiGsUAgl4wbK0SeyhjvWYnGKtctOg55oEVek77CvQcrrEWPYcqf4Ge02p2w6vQ
# DATA c1rDaOTn9Jx20PY7Q0PPGXT7o2Evp+e02y2/e/P0HFXHq1yNzbjQEIKOHm4LN61zVDV4HKn0jk8qXbakCmtMrcH4cGfSTvltysFt
# DATA u7bExFB34WjB9eB27BBXcTtqotk1xirK+JB3cozDYXJyUPfg3ah7uiQLgB5u16uv0G53Y5p3ZP2kkOulmwprZTKcl2A4hxv2A6yO
# DATA VoqStM5TK+u2W0JWXY0a2nRDyWtG08TvYleq6jM2U3wKpX2BjVjIPLswVWL05AVWiKPsOMqOo+w4yo6j7DjKjqPsOMqOo+w4yo6j
# DATA 7DjKzutF2YlHYr9h3QM1/rH9TerOXTViqoFLfqtwXdw/fGJheh5LviEz7nIwOHVkgnmTngB+54s33lx9h6rUh3pAUS9ZvTG/RR3Q
# DATA oLvYzj1UkKCPcYxLWj6b8pNTPp2j31qOUs37P9UZeOtQGh88Q1lThTJRqOob6IfvbhvxrykrjM1sksqLU7XFo0WeZuodv3jjQ+vk
# DATA nUkGdZcqBTLRLZ3zcUfQ3RH0nY+gFw+EubPo7iz66qnBjXqbL8IZ9VIdL7QWW5yGPX8sQIvKnOVqKUr4Nh5GYVZAt/CJaChbglzE
# DATA I01G3ZmcE9ZKKryVrnRadtcz6JwE1mfEWM7ifEoSlF4FF+pc9Pj6LLuI+K05DKp2Wa3q1yvbFVWQPyk1eCUcrn/M9czNFd5uC/nP
# DATA iMMx0YszK6s3q7wbg5il0eVzUePdusN0n/ZTKwrtsChxuBMdmtzH4q6bBN1Vl8phfU993ny3HK9nlTv+tPlO7nOVzOwg2nyf9Nuc
# DATA fv60RVReDppqOXexQ201dwwxW7TcCzUB/nNb1jX/Bd567ur0PEA+6Twv51lJbJPd+qYXEKuaa1665Nz453/8DyYd5Yhb+T9niVL0
# DATA OZNwnuuvqqVE3pOWLiGRABstYSmGGZTgWYsaaqUx1UKGMoXzOdVJ1teljhmtjyaxs4Uc/4ce6wL6R1qHlrWqefFDi8yeUOVWh8WV
# DATA z8tumfnJZ9008oPVxnGGyyopJmf00Uu6wL5gril0rwUCKKu2XqqI8op62QL6+/+2uYB0pZfi+QDFQBU50wX02UlCbTSljs3Tp/wy
# DATA ZYJQn7ScwRNJQ9K85n1AozyMnGlyLIIUlAYWHICwwVHE3SoKSPYPq3KKtLqFKq1nLxWTglsrF9MtXLZY/v1/2VwsqouRUhE50EGS
# DATA 0mTEtJyZmgjLZZ7m9FnTlXWV5ZM3D9GwhmI6iILviPrw5EQVUdGOZGl2NosL46B1OV7AiH72UrJTdGsFlffLl+7hfru5pHQfL0X1
# DATA eZhOPd7dlXdxJ7gmcJzhMbSwqWSOqGB4/QJ9XSTD/WwoUhoRq8dCZzqaAYIjJaBmA/2IyR3xQjQ5sDvW/pmpE89ePnkybq10nmUE
# DATA +n/+afcR6B0MslEqQ4KlAz5lu5rilT5UljY3qXDC6uWhN13S+DMJU+yTm0M+GRnt/UiMRzXAkIkEhoE0G5T4s5dEIbovQ1P5j7s2
# DATA lQfJaOH1Ue1DlE7erWGM71MWTaFlA82YAY08mBywInQ4/GmI/TmqxmcorJTt8XgaT3DeADkFlQqy1L9cxqJWAxVEFlaRAtSK0NfQ
# DATA VArJuFIBFY1A8WjaRqC5Itl97+NE+x61phDPPpRPMEmFyogBOuFOXBesEv55FnbQ6yHu4uDczpV2BVea85y9Jp6zy/K6Xwh1x8L+
# DATA y+3Ybplz00C6wFZNsiiP2Km1kdz9gqpAvkSiaRdpQ9v7Hm+C4r3aSq6d5b1WRnQT0Xs15eo2o44tzhdMgmqebySx2ZlUEd+RqEGe
# DATA JMZxkTuZFLVPOYSngHIbmb+8oCveMhN8KWQBKRjsjJAkZGUt7DW1Rulzc53M9TSvpAX+MTxdsyNAAwUwLro9RgrcUhbU4BulmXVg
# DATA 5ERhVueioraSqMc+E7JYF1JamPfA+vawERd6m8eF+iCb2SSzeLsqNFFneYMX7UKdW8jh2utkPNpBOPPRmY87m492XXPrsG4d9hmt
# DATA xo1G6s2sw34k3E9bKTonHj4fUsVtUMJ57w+qFx8bLCxzqp9yvLa6dWW9MF9IypfHNq0t2ssb9mrNpvtLjvbSUsKmpwru34JPe9MT
# DATA ZTdl2c266bmy96zsFdy4clooBd5khZiiOg3jIdcHWWj67ltavlIVi7oX/HLZcyoscXXOVJPOy4vgOGSu+Xu2ReVp7j116rZNJS4z
# DATA /eodKOK8qWB6WmhALy9CHAtNCyahztHTZ8pSTSb2W6K5Hk9kxskmeKRnUgYiSe3HrFYt2VSg0OgZPPeu7kjQt9jDs6cEQngCYEx2
# DATA 9dTnsMSl75F1x6G4lnlfOcUEwt1YoFFP3ElWCy6fN653Gud1Ld9bCI6n7qOopEslfDED/NWxki04IEshJdMCG/A/KIjfN2d/oX//
# DATA fPYUGL6nHr4xlu8bsP7+cvY1oHyrdMD/dvZXJv79Xt399OyPHoMCf3f2p/P/6+wPZ1+d/5Ke/ZMK9I8KIfjH81/hGv32zfnPPfoC
# DATA IqGAAEEmRBzkOQALmRv4VwcDfBms/kLfPYpOyHbgSfQ8hHStggCgV5+OIB/Rh2SXxoBQx4dV2fsKq5v0mXmguue+7rR0n72c82vQ
# DATA hDg8MjIG4j+JFsv5VgTgfUhdeMNlhs0u1J4dALBg7+te4rb5f6vFcnP0P7awmLCS31qob2We+Z3oNJrHEVkb+v731AUPKkNAaCfp
# DATA NWMAWT2MkdDLBY//6owWNTFHAty1CK8fBUh9DRbBqc3P4hE6HYbBM8QZ2+XS5BE0dCI+uyymPAxW1ELq3AYLbGFYsvS//JipzSd6
# DATA 74muaOJSJUucGTeYxsVHsxUs4O7VcrOts9LwnhcccPfEOEigsxCuz0LQaMArGQavhxPw1oyCG7AJdjIJLm0R3K5BIFW0nB3GDHhh
# DATA WtVNIAGtVKvlrw1R1HAxdl88PPWO0nC4DBX0L8tXHyBjWFxjY9RgcVHiVDZ9Ymn+mF1PWGtjWcRsHg0w8htTbCc4oBnXWZmbEpzJ
# DATA PjrKwBHwZVwBq8moisrJ/SzVoZoHFVscnw3FcoCPjgl4Kg6KrYbkz1O6lPFaqiptZb7JIiFHlm802VfzPo4AkJMLsmnvwRJmSJos
# DATA j8beckbFtJAz7PzizGEEHUbQYQRvECO48zC00yTpsgb1rc4RrjJFuM4ZgqMKOqqgowo6qqCjCjqqoKMKOqqgowo6qqCjCjqqoKMK
# DATA Oqqgowo6qqCjCjqqoKMKOqqgowo6qqCjCjqqoKMKOqqgowo6quALQxWMOtFw5F+RKuh3g6gZvkRUwfIK9E5MwSI8r9e04HmduoHn
# DATA dYr5OhxEzeFoDX2vHdj0vWZO32v3NuZtXjBTv971Ar/j+X7T63a8XqvqtwLPb/pUXnQ16HjdbgnL12n3uv3uOixfIcq8D3M1vvRC
# DATA C3nod0x8W0XAZD1qDzprng+CIH++Uc+Rid3dnm/IK1V+tYI8v3Z7vtmy4t+w8nvH97e6FvKx2ehc9v1+2y5vP49/Y8f42/VFypYf
# DATA b+72eLtjJ9+GPe6Y/fKISn67d9n3F3OvvsPrLwOJlEaiIZHSl1mQyEEnHHb8IiTSPGIgkUG90W/1CpDIoN/stFs5JHJQH9aHIwOJ
# DATA bA7a3W4zh0SO/GG7O7pxSOQM/Xk1e3iar3PIEcrj6BrWHQLL1aFtLrYfzGu1RVgwfeRlNJvBtH7NHhaV4XYwNWgXFe17KxT7Tm3l
# DATA 7EasLERUL3ooLqKUoL5HZcnjXXOt1raohp6dLeo2T+9qKeaNnrVin3zB0VoCOm7ZoaD2I0g6qhn9MI0OIHq5mdJo8qFSSu4W069c
# DATA yJWt5cXOFFNkYg+uVBMxn4JdcopDcBRIR4F0FEhHgXQUSEeBdBRIR4F0FEhHgXQUSEeBfM0okKsQx2l4dBemHvXqOGNGSb4jX/VJ
# DATA FmSCQi5+ZCsKoFW9SU9TXXgfGyL3/P03v3jjf/9jjYmH99fqDPAzexJ+OJfDBngjBbNvwgkQzv/6SsJ5By2ejy9Nw9lyFLJOv5zq
# DATA kvOI1JzncvQNh6pCQS5Ej+hGPvxJ5kBGQ1uBkFg4o+NO37vT9xecvl9zhMudxXdn8Z/lLP5GPc4bPaMviogJH0TOj3vLsPJdo8/5
# DATA /OVjbkOrU0Y7yKiaKIz4gKyyOvem031FSdQtdMYOkFzQTwdhujVzwShadlpFJclpPJN1r7pSneRVIKU3if02/OtmnqIZlO2qctl4
# DATA W4GYqNvXTOyD1rrIB1bUu4WI12utzVE3470ddX1R1aO9YXSURjRVvyAFVlgmBfY1k4L22uxv2LnvB1syf6NCp24lqNHSQbys6pzW
# DATA iMs8RLozldasj7gXzD7Mmxbrmwy9KsaR9f5p3sjtG1hkX+TzpbijbCFdiTwpeEZTJfIw+Ob+qaAcC/2S1h1g/QodGvUjZAQqAxHz
# DATA vbmYDcMYcz9+DBrCLKlxEp7KwCPFyWN/poU1jpYhjTiLKGJpcCVs8SV1cGR+4Wi9EgVZE6MdBDxfvQPrpVHRWdbOsr7Asi4ZTc6q
# DATA dlZ1warezFZ6kZSviq0gNPllxK9+CP6eUTvCKnaudcR6MnCJV4x+k6CLo2mczVmCxvvM0FXYeGfdnAieuZOIyawVT+/ZwKgUzbGM
# DATA n9IjqD9li7pIcFwRuzL30dD/fqykj8ZJGv8sMZI3SsE/9LJwBL5OlJJRxBJMplSyeZIrpLNEEYtGqVlEFGanPPKOk2kEUR6eTZDd
# DATA VxFOhkjx4F4arWlgjWFCcGeVUW5hFUGpgWOrwoYpQ8G2GUY67h9CmKfYAWLrhFLtAQ8y7xCNTbSchWzYUL2qeW/HswR1iJ7RmF1t
# DATA CMyiRws2JHlJBRmk+tEkg9tK9bDKBJIqMOWXWaDQdcbE2rT9rQ1GmCRHOoWf4kSzlJtUq8KcLcaCLNQ/4lysyHAXRMJrcqrU8rnH
# DATA zx5KTcvHDb0pUuRfM9Z/HUGqnROhFUkZesq4MI/PggG3jexdZNsS9YnIeUmriE6VZBZG6vmUuzBJo6iCifxsPy8PdgDmxmm4MIJh
# DATA +XhEeUEVltIoE06lp0RZhl2uE+wv4aqMIzSpXaFPM/jGOTaPKIAFGYfxEDTYmvduwk0Sw59RJoMInDIYR+j8Uis2KwQktqwu1H01
# DATA cemHqrCXloK+WU8xTFJzRQaJU7mgRfbV5Kz4PP9YnHrpxanCtKrOUyDVn+V9GRMLpObmUHsls/9M7/MNeWISnip0eNFUyagnvN53
# DATA BjyEMq5nGE+l/7neN2Cb4r2P9diBNM2j2SCeXO9beA/3e7oF6SU0uwe93ve1BGAxisyeIWp4bEvOqLUV33VnObkxBu2rN79yJFo3
# DATA tdpdMthNpF75idRl0bMvloSw2dN7EwzTcmZfO8F0jdLxxfzSSYGgIBrA7IYs6gpvweu+WDrKL6OE6I64Ba+wsVwb4bncquSLmWzU
# DATA VibH+bS34h1BoTmf02AW5oWYAGOrlZmHDmgKbOvHimorJk3ZojQrzb0JJU+Ctr9FQLdQa8l6OY4uFpJGnZyGcw1y2KkM1pToJ2nE
# DATA HvWCGnYWZZlmFb5GpltOuOqHD6O0gLf6r2dfgzp1/vOzvygG1R8Yc/XV+b9lXNX/9M7/Hpips9+twq3+E2hVDKQCx+rn5//eO/v9
# DATA +W/O/nr29fmvKdCnFe/sf9Atf6bvv8R37+wbExqoWZuBV78E14r+65hWLwPJluownoezgSoYS2CHjHuWIYKsrZhHgiFcE5ArV50T
# DATA 5mTi0pix04L7pZEC8wzlUoI+TvbXCiOPeo6MPV1bEVZvYwMt2kmEzsIBrGwDVDqB26ZXlUvk5thVkIQelt67FlnFVczc+C5XuJuB
# DATA VdGoN1ebflFLsUk4GYanvI+Q6sfDyAGrLiq3a+dUvY1mwCUwj1KcFWXFehzHGzFgW05femS7Q8tErYJYW/D0ej/E8o/SaBhH8EaD
# DATA UUB9apTC25Uvp6h+MZ6RObSUHPamy0z6MzHDToXqPYjn0QrFapeautmeKTW950Wv2iURjlvlrIArWwEaU3WFwf+18Dzd0sB/7eP+
# DATA TsP+rqP+bQ36UhmLqTeD/PNqLDdBnyom0RtHkzmsEzI8gGA2kcsTnI5PF+MpVmQl6Qcy1ELoHSdcFvwBaGlki6yOUocJmtEHZOCH
# DATA xzROZjo7UpE2460HWJNNl6ylSPGfxoYLtJ09pXZHwMMUYYk64jNdMhBz7DcM5uLisAwCxhPxWJCJCVFF+x8WzAveB6g3USgUEL+E
# DATA BRSAmqJ/sKcCdp5eI18uEshDDZjU5QBTDjDlAFM3B5i6aBzZaS6zu6l7i1b7VYz267HZHUnKkaQcScqRpBxJypGkHEnKkaQcScqR
# DATA pBxJypGkHEnKkaQcScqRpBxJypGkHEnKkaQcScqRpBxJypGkHEnKkaQcScqRpF4YklS70WwHnSuSpEajUWs4eIlIUsWV5504Unam
# DATA BG2v0el+WW1W/W7X81vNalAP6K/v+fRPs+fR12IODaJuv9Fa5UH1Ol4A6lPD8+vdadUP6J+m+loCQVEm1wf9dSAovycBU/pjGrg1
# DATA +qhhoZcarbZV9IqDJFCiIrgqaoZRK1qJaLPje0GXkt3y/EYwbXSrfrOlvq3EM+r3R2vj2VitX/WW12y1xu26/5HfDLxm1x+3tF6c
# DATA xcBqNYNoXZCrNbbdpJg2/B/1mtO6F7Sq9I/fnQb0GiqWLj5Xgy59Wf2h9NJut90IBlteehnUkbQQjTqSxmahjvr1jh8Mi6ijEf/P
# DATA Rh3R13BUL6CORv5w1Pdz1FGnT1kVGtTRMBy0eq0cddRttup+68ZRR7zDpMqmh80SUpEtzj59jISe/JeauT0ZsJlGMjPYBvnhkSt/
# DATA 8w70oYITrm2ccLL0tgoossJedcjzCCvb5uih6OGucCJtaQTlALxLjNdbHts+eG+EEFklaPsCPTGhN6enVLgdlGpHFW0xfzYnx5GE
# DATA HEnIkYQcSciRhBxJyJGEHEnIkYQcSciRhBxJ6LUnCY0UR4iPXlGCKyd3R9+RS+PToaweAvZDxk0lMz9lIVuUfPXUXD2NqEdWlzV9
# DATA 6H2EywSh0ZuUQ0fMB/qcYigXT4ogIvX7Awqef87W/vzBDKJIMBbofXzf6dr7PksW4UTO9/FdH4WLcY39BnujN0/ezN48VTfbnKH8
# DATA JIs7Ku2OShePSlvnmtyBaXdgerOU3wtwkBpnUkd5NQ9PvRC/F+TNF6x8IvUZJWAkwlFvKvgZsnmTSXKy/azvNH7Ex4/naZKM9Plj
# DATA 6IybhkrjL7aiLNMoewZtcxoR01MkZUFZgvTp45b3vWw5R6caDVWLjjNDPiLLRoGNUhrwUDshpzeJF1jESWjykLEStoBMBuly2j+E
# DATA Nkw84/PYmTlUPYKz95jP734OF25BwSRlTXdR0M4GScJPDJZzyGzLueZtCtrvwIZIT2UfncdDVJ60EUTWoQKIILlUZ1E0zHR3JunN
# DATA FqmYy1SO42Qy5LOuiDkllubALAeOUhnhtyOK8uSUhcJNtpmyE2UdlknHqXStis5pwERukiyQdLrUT04mXjjJEj4YvFUi/H2q3tx0
# DATA 5Ng2vTVKrcJjweY+W5ucXfrmONOn6E9QF9E9s7jPBOd70Y/XPFZUz3vyATakRJBHjyd8Mhdn47Oa9w6rNXPd9TSgBtWBIo9Qkdpw
# DATA iI1AHJY5hqhU/cPFRaLunHMc5xMaSIyuILaj4vy7h6M0eBk1nXDKr6OBjktHScIPlgspXGyrmavTwKITb85748okVhQuVIufQaae
# DATA 4TiZUTR/KOGJf4VDJNNwYmdJbM5zh+n0arrmb4sQNbKOGv+lhc3RCK9b2fxTZD4KbwTntPRONyBonrMtRfAIRcGGqJfrEdyAprlR
# DATA ZmSjZqbaHrpZjHk3IHF+n7t9YyspNYnbUwJ/dQ5y54G4GYWbURRnFOUq5aYVblqx8/Rh4/Tj5qYVD5AVOQ5HoqOnFC+8NuBtIErF
# DATA kUaX2fPl7R1dhMXUD5gOy1zI6Rz1qwBJ65uxnrlrj275vv7i7X37osjaD5oIFy7mFM/uujg3W1aUe7sSVNnfyISSyWKHWKrbc8Sr
# DATA +l4wqVaiZmdmo0hI3RI1cXrSzwWv5A6R1A+aWJoLuV1b61wU0WBbRDeCUGX+itHKamkvLw1VmlqcFcWOjGbp+9S3UOvwjsxcvOK1
# DATA u9/2TL31pmRSZ16jqe45gX+aZvk0kY6OUnSU/JRGZmH6LdwsvpG7I/6qdNhkZmogpzGr1cYD09XhjdEjWTPRUwYsg2FSj7BKUmYs
# DATA z2X1ZVrANhNWmTwtqxCY9OfTEomdOn0QaRW0HSinr47t7eg7zvbe7s13hvYraWhflrLznIVQeQdwvkF21QC1ITQsOhhqD7bRC5Uk
# DATA bKbQPFf51JdCVpD/e81Mo5LQ63UTjVakctfyjHYQr7X2UecStvgWQbgyCUcVQ9BhK2uZjZWBVaqn2CkuJat2i781btx7P42xboNd
# DATA iuxFpEtg1MePYMOw91/OczHtMC6aOzSBxCwwWrfsolQ1RchU9EnVQQbewqVMnqIBQ9NSy6NqrBYTXTveD7BmhZiTfVeKucjumkUV
# DATA ih2vX5g2IRqjellGMUhxnAzbs63VIpZP5aUnnEXcEmE0+x1jy8faZgnTfzm+D7ASpBbo9PQ5KoqjhsWFPV4ymZhVP4qjgk9iBQKL
# DATA YJsjSi9bl6+vjXanRQ4iw20ADo/FDvqPZ1+f/ensm/NfnD0F9OfsD+e/YagP6EG/YIbPz+k30IV+uwoPWnn47C/nvwFu6Bdnfz3/
# DATA +dlXZ7+nH3/NDKI/Vjz69PXZH6v0xFME7fE939A99A5BC22ECVHoeMtX9Aa60QGFXnyL+ofQL+N1Yu5NFC3stCILgrgkHa3anZpG
# DATA R+AvazlnWfhX9dUM7imLNhco09Qbb2UIvTMORdXAkgx3HCHLulZdwm2ThNaVy83RhHhDwDiZmxs/VxfWM4VGcd5Nvx8vjCf4mmlC
# DATA AjVme0F8RRbR53XnCO1SYtdOE7rvCXgdIPDqYtmPTMmLBz/GHtqpJzvBa95HCdWAmQEhUiEeQ+8dkh5YI2AND5hlodrsEuLzRDZ9
# DATA pHAfTpnHKM46Nr4E1giR2DI8aHuV3GzErGlnzwsdtD0JDhrkRvrLjPSaE3TFAf71cJ3d1uB+I2P7TkP75Ub2mx/YpVqu5kC+0fX2
# DATA WstNgILylEFEiwLIVuO8gMcNmzX15j8d36VJOx9yYpyILkAQYGL+nfkmWAJj2oraEspvmYYzSl1m0i2pNcELZmg6py5sttgJGwT7
# DATA aoGD/MgHCmmUUm+XD/qxLPfrhS0Ew2JyDDEyBKA0kqwySORTASpXrJE+AeYnGQm6GC+iiug9WCDZMXs84pFHreqh0FBOqKPAnkG0
# DATA Qd5gkCLvtEPU0YMcPcjRg26QHrTbmLIj1Pxim/eWjfer2O7Paro7dpBjBzl2kGMHOXaQYwc5dpBjBzl2kGMHOXaQYwc5dpBjBzl2
# DATA kGMHOXaQYwc5dpBjBzl2kGMHOXaQYwc5dpBjBzl2kGMHvTDsoKg+qo+CK7KD/G5j0Kq/ROyg1XXnnfhBRybJvIuwyJoZtqLhqL6J
# DATA NXPvrUGcwv4XsE8gCVFgnw6LNLC8ge8rwlDh9na9ecHtFueHwvboHo9+q/o9+lunf3ut79P1id+r07W2F/hNutaudnrVoBmMm72P
# DATA AgCLOt1xpzn1G61qszVur4tJM9gUcQUwunNUqEDNwEdk6A3Tqu/VjwXRsyUbo1G/116PSKqvVE+Kcyuoj9vN+kdIdbPXOm7Wp816
# DATA s9qs06cygqgXdvrtdUEHl6cBSZ3XNCBpPhYNiJIx6DSKNCC/0+g2ezYNKKg3u61hgQYUdFuNdpjTgPqjYXM4NDSgVqPT70Y5DWg0
# DATA Goy6g5umASmjZL3jQ6e1ZGupkQgb16rbrRCPbsawk99bBv+YidK6SZF2o2GuW2nWmsz/CZj/s7oe1S5GShs3VjcttgsnhHI8TKtH
# DATA mBqDZ1EfRkcVa+3d/uwFvfmjyrca9Van3We3335lc0i9Swalo5zNo8FlqUTa5oX3cMWkslbkNi+Oq6Vw8QlXM/phGh0Mw/ThZvZQ
# DATA nsMVO+qbbY6S2St1iG0nRxJyJCFHEnIkIUcSciQhRxJyJCFHEnIkIUcSciSh15YkpEg/n1nHuvLz3MVzXGUMj3CD5JQ35ZGmC2FH
# DATA AJoR6DyDaY1hPu8kUxZAXznkzcfbsJQkalUhDqokM3V8TQvSFg+KSRuViZw+aeHOOLszzoWjNu6oszvqfMWjzhvFB2/mCPT7MWtd
# DATA 8FladkGWT8/qo9AvmtzGbehxq8EFVYfqq5IMRyr3BtOLJJrNs6bDyq8YkebuWm3uli3S7Pv1okxza4vUNQ9+kHRRvRdfeEtsWaOi
# DATA LPfkAtf6obcS7kxtCek2L/d8Sn2fwgtxPXnrTqJEAtc80ebsorHFu+Mt0ugha0Ve+FiLX2SbAVMYNCyfXHz2jqRmB6Hq93T9RJX1
# DATA UGVfXpXqj6IwW0I0GgdrB2GaC1Q/WIgkH/UkSbKQG+RYM2R9wiOIPcMfdUJjVs37IQ9uk+iYKg06QHSqUxU2N2MFp0lSIzyUJmRO
# DATA 1rxPeQFATCN5gPUWlbAfDSenKGgqiHhRkK8GTKtwbF/OkXrpEme8ceQ6xAF7aDia8Rz6gWSxUZ3lws9odrbM5pHoH7JidjhbjjAQ
# DATA p5hLSYDgIg3j0QhXln3WU48xTlNgjN1ZZ+spEQJKwmJngetX5Zyvk7d25qtlvjp79bWwVy+rbf2cJXt4XTtfgN2ubX2fRiM2GtmA
# DATA ZDs2y6UomKOQbdG4vm2xn5dC7+ImZK1X6/W1S1uv1XS6qrx1vuivzTGxKJTtE4EsynUuF7Vm8+eUTBoBavJSEL2u5r0tukE0SxKx
# DATA miicwUT5HCJCIveSYXBjzKgQHLm6wYwiqyvWws9kwyVk85BR95DeoIkhl6s4P9BCLEbVybjDXy/Fk0LOOGPIGUOlPtV585w3r9h3
# DATA brSinrOgIfOAAS5OJhPR2S8Du1U7CbNcwq/mvS+cbraS1snzFbT85mkyiIagcYsUXZJ+uYzEl/MsfO77sYE6GxrvgkZQzQScxgtB
# DATA TctI6rGWC8dgyY38KFwe0aj5KQ3DmhZY4QDELJHlHoV3QIcRjkZwirGrJHd5mnH6gxnG+4Xwa5eKFhFN+9EQImjDqJ/SiCxUZB5C
# DATA WQQQO5S2oqxl9M/lGQUHHFJVgB+UNQWVaZBp6wLKcfDXpOIsVeLTZAMMJ1E/TGveh7CfEE2qpJS5oQKBDUN0MEAi9CcivDZmYbx1
# DATA Qob8MbNUC8Ulm4F6/SUVfDyCzts0wtpfPNgKIx+zqjVXntkCHhz2Ipskfw4oRzIaeUc0ZOkkyj5Jb7KkTB2EUGzkegy8engSnopj
# DATA SsdTlWGm3TqcfTwOUDAq5pQvmShww7/EKtyHStYQUpgpnyxQFddU5wJYY4H6w7wRr08RiDZ6nVWqeaSRsQUy4cwHz4WqIThlWhaZ
# DATA MQklPgaZhOWf4gn9XNF+KE5ADtsZhGl6ysqN9ynPQvbbqYCEMC/wOM3xOQ5Zki/PpI+jmFMlfmKlfgmX3FGSDC13u7w1oYZGo+FI
# DATA 2lqxCK8G+0ZbPmXVR+pjvntp2Dfidt2wb7HLY2ngSr8wngEcHw1vAPr9Npj3Si5UbR25Acb35yUV0ht5E8O9P0TTkD6GxjXZlpMJ
# DATA Med638angD43lESsEM3DOPUewlscrqbuJonir8ZUx4LLJGE6PIJv3cbL/GeFkfmGoS6gw3ztnT09+6fzn5//ZpUn81/pvj+c/U6Q
# DATA L3wXk19Ahfnm7M/08StmyTyteIYv8/TsT2dfAVfzFD9V9VNPPfr6lQ6KbqMX/vL8VwouQ/E4/3uPGTO/A5sGFBoHlXkJMI0zzexa
# DATA 8cXNowQIaDVyL0Rg+h09XxO/xxFv28Ygp6BhrN3L8sI5ucsMfBQ9PRQuZ8OtlJn7fEv+ZseYKczmTM9w25SZ1XK5OcYMJ9Dc9T0I
# DATA iVNeT0bl+4bQfjZAL+z3XaTh6XWiZagNZGRjpyJgTjMNWGM8E0NBOLjM9qK6dqqM6YSGMZnxfGJPTB0yX/EURO7jRx7XC+9T3h4g
# DATA btsj7I9ct6lc2IfQaNdK3yizWbRgTXPs/aAxPFthyGyreZvtlJU29Lz4Mdui7+gxbkh/piFd42SuNJK/Hj7Z2xvFb2AQ32kM33EI
# DATA v+kRXOpiOdn5tsnn2GJuAilTTmhOljGaE3nMKTejUCFm4H5juQF4umZUpJms1iIZhp8hwyrQE8dxyrgYFJbGylDKwwwXcWTcEIWx
# DATA GioD6yUgMqewtti3KyEeyTYzTBPoY38iHrejNOLzAJLtequb8q3T6A8pBP5+IY/kEOM/Z0lq2QxFzEiUOliMg8U4WMwNwmIuGDN2
# DATA Q8JfaNneqnl+JU71Mxnnjg/j+DCOD+P4MI4P4/gwjg/j+DCOD+P4MI4P4/gwjg/j+DCOD+P4MI4P4/gwjg/j+DCOD+P4MI4P4/gw
# DATA jg/j+DCOD+P4MC8MH6bdafab9SvyYUajUTAcvUR8mPKa8050GDtbGnXPb3XGjU7jOOg1v0/fiznS73Q6zeFqdrYCz+/WKUM7x0Gz
# DATA /X36XnyO6ma3r7gsXJZSVlJwp8JhCQq6Es1esYybzVJE+lGvUw4wCBpXDXBY7wWd9kqA3eB6Y9ho+tcbw6ZUneuLoV0oVJbXkIdW
# DATA oVwywA2lbBXKtcTQLpRriaFdKNcSQ7tQGhL49bWUSwZ4cUu5lhjahXItMbQL5VpiWCiUVvN6W8olA7y4pVxLDAuFch0xLBTKdcSw
# DATA FVhtuVcsZb9RClFdSFXulwf/dtQoobjavWbYXAtLWwcda7UaFnRMwk8NEswyUnSoK/y0oPVsAbS6PSuAVu/yARSS0Gs/YxJ2C+Ay
# DATA PDOx0TTPTMw9i2cWNtvNRlTkmY34fzbPjL72olGBZxZ1h2F/mPPMOv12u9U2PLNhe+CH3Zxn1h00w+DGeWbK66E2NJiZkDjjyZZk
# DATA B4XlvdCL1GZ+1uWVyjWL/sWQyxyz70VkxMZhRWJS2ouyJjjbEcmLPMXQ1brvxdEw05f1u+T07TQ5Pop2Wypq7bI4bYVaXnW2fSa6
# DATA jhTdzoFM5FdWD/2GtUis7vWDohdGV1feYzkOh8kJL8Rgxa3u6Tpn5W2PHRY8KzazuQ376fQkVuV2fTMDzc7TCzwaVm6V6iRPlgMH
# DATA QnMgNAdCcyA0B0JzIDQHQnMgNAdCcyA0B0JzILTXG4T2WNXumArurkKZ4TMlusJJUhdxdA8ZIbeL6uZd6tiozuyhasV364fxW/zE
# DATA Yfzmm/uPcZFvO4xHeyfxjKwrssNO54vkuzDiPwUUY/ojDmf/sW5B87sMWmMQyF4z6DV77U7Qa9/hKO1/h/+oKPTvwgb8Ic3eG4F0
# DATA vP7+4TB5LO8ov2Kvv3/4hGUz9/o/rv/k3l161/6hSL7hwrc56Df9wycRGetKC86Ki/DfOMA9FY99ulupj86XNOqpbu+JRA+V4676
# DATA +adJPNvj3opyEHw4NIY31Y+yQLu3F1b6VBzhm/0KWY+5Ja9SO4nvbrRmJzEKZhLbFfKuNA8qN3qTpI1mjngt2/gyI8ABcrT7ObYS
# DATA zIZ7k3j/UPKo+DuvStPEXXXF9/z6fvEGDMEqPu/g3pqcnqbK9kQj68zRT6es4pRVVpVVzGFgp67i1FUuqa6yURT7BlRXPoUcl1YA
# DATA mSSs98GaXUZ45fkKed0GnY5NAboqniAvGXFiLsDSqYfyHkl9L6jJrhDpfAtI17ZxdP4WGB2bL6j6+ID5B4qiBKNT9+QwOv3QCiOu
# DATA LUE9EhNpM0uOx6T34F2/6E5f1IDJAr3oRlbY/ewkmlAnesG9QV3dOyMTuHTv7ug6rt5o5VyiLy217m81o0HGo4ysh2hopPaMvA4Z
# DATA WUYWR8z3stQOk+R2k+1hERsvS5YpWL4jwalAf1usRmg45Hw68VqQkThTMj6UxFNPHbo3YjH0zhW1mHHjnq3/Q2lqUMFMdKGwRWbn
# DATA prVRV5XAZCfa3KugGJKPJc7odEbnqtGZWxfO6nRWZ3ahPfnctP4eMGqII8kubiBHUf2N0WmAZNN4kCaWBN6SLVSlfxdS65oNQLdY
# DATA 1b4zg2LeotRgqCElLCU3SKbTKB3EegxkyzWNsNKCjQs7a/9xyub3Hoi3qn8Kn1mEXSYYRg1ASdi/NJhiL8Ua/S113m3VRFXuWdRE
# DATA /qSMU2Vz6B9zA8hc4YPPQKdFHI6Knyw3iOCgjvxa29P4fMEJUp+Llqd1h+ko7adWDDs4TdEWwJqS++JtdqA2zt9lA27TXYMExA1q
# DATA Lsd88zv5183PcCXC3Z/gwxbrUgZmbeGJC9U2STBIbDHvCiWMPR/SoNXRzhzpQJ2SYXewx1pWd1Re2nlRwgHxbhjTzsUZzLUpXfLt
# DATA wT///P9um1SUo61yVpliSqqSKki6OBVjjOw7HpnA5NGWJA9CNO2rwu4a8nzRuz8cQhqPnhYW0ACNjWo/TxSZnwz2Ch5k809GRyai
# DATA aGIybFN6S817O5zlVMDZUCal8tP7IMLgJY06DbKGEqSPnVwpX0u15wrZ29ycvYW6KLkMe1lseErIIpzofL7PPBkaJOYVyTU9seZc
# DATA C7EJYBFPIxvKNp8sefZM88ulWPRMQFIefe9+PEVejchay8aAVbHpjUt+gK/zJGMTvea9B/giXjOMs8EyQwFxSLIoeR25bNrbZfN3
# DATA c96qlqtzFT0+db0LfNB5+i729oRe43//YwOspCHlCRYPZuCZnwAfRHVrSXlHZSFT/MzzqUB7cFrI+ssgojlIzfuEumyaet+Xii3V
# DATA FwQo5iTxeUUP7o1D7237DpwhFHcJz6TVJq+a9336GnFFpvK/top85Sze3kMUsvlzGmhpkkFBpDqPjTk7ooZfFT2nnAUG7UCqX6hM
# DATA c8lDWfHJpC+Qu1FJ4acJFXocE0J58GNol+JkYMa6paEJJJxpKFVFXka/YQlF4saZfhSL5Cl4ZMdxQi1EPRxKz/NidB7tS3Ue/3oZ
# DATA 88qnHrx1IUgGU/2lMQ4Vmysg20DaMJLpELLdyybxnPKTGwf3LQCd8fSmz/qm2iMIBVWM6qLEyl2TdxQtpOg4C7GQmCXTCBeOlhF3
# DATA HHg6nslEhfqlxbV0Hzc/+L3D4xKYSLGp2qZbFLfG4iSRDlmyFr1xJghNEUqO4pRGtxOEousxy9jGRuGXputo+qlq+WQLsqoz3kld
# DATA E04rUm99rCZ3FDaemCZYyOW5A3oKxk5I9wKbtZy5RXNFlo1tc8Vckcy6Rw1MLfBqIWEZv8VUtMxXam5jbnhSKLWLWE+vgssln205
# DATA l4tzuawhKDgvy6vvZdnoQHmhiAqFowKrI+XEZi14k3iBI86shMJITFAs1WjCLpj8QT5Pwhn7vBEML7JW+UX8JOvgh6xK8tGXe29R
# DATA R1pub/roe+F4XVfO8lnn8uVCOJHusIyTWDmSLu13kKB2yNtOZwMdFaXymPvdbDF7Lo81YA7rOf7C6VErMePg3gO2yU0VAQQ5nJ2a
# DATA VavvJyfAIZ+quvNdjy8s4Z0iq+q73jt0f0SdKYwhGCG5JfxdTMLiKVe4WXYis4cFNtp5vHTM+vuxIrpqNhVgtCHZZuDjQruMDK9+
# DATA 8iha4UUVa8v7MQMz2QFJ2bEcLCiRUuyvw5KTzblMmMdtUy7/E2Mp/zuQk+e/9UCkPPv92R/PvlolXJbu/GsOvMT9Fe/8F3TtKf33
# DATA m7M/eue/Pv/l2dd4Avc+xe1/EgQm3f7N2e/P/x3glR59+Dnd9me51XEsXwKTzcvY75+qA4imr0eieXLOPUHNk93yXraUCatsyGdu
# DATA rTzIDRhjBg8m7BGYyTRqhAkrNzj4ybC0MObN81solm+LDJigMhzCsmjCSaO/bYBlqUhujl4JO+DY6u5VxWMKuvxUfkJVQfPEp6pK
# DATA ogrO4BG7VqAl75YYhxn7a4D+UY5yZcE4qOWuJXjteMv7sEuPxFYx7OgKd5tDONg0IMj0WWJovxuPRvEAG/KxbVl23ESaAa5vnUUU
# DATA Bv2cirt/hWi5Ux3cbJYUW9fz4lrulAgHuHRj/TOM9Rpvefkh/jXx0NzS8H7do/tOg/ulx/ZbG9qlWhayIcdcPrd2cxOQy0IaMSUP
# DATA iwnDtlJJAIKdzhcyFM5TdD3g1I3DfswLf4tMlxo9cXSEBZaHVA0ymcdTPVbL3Jhuy8hsRuBJTBUSy19C+Mug+JfuirhENhomIKYN
# DATA FP8JdfU4w4Y1EIV21LHnba8rWElVk6oFY0EWhDiWLJGCUJCHyACsfGbVeZRW2aqjElhOuZc9tMwE3IgoV8lg22g2OAamY2A6BuaN
# DATA MDB3HmB2mslcwh6+PdP+Kpb9NRn2Do7p4JgOjungmA6O6eCYDo7p4JgOjungmA6O6eCYDo7p4JgOjungmA6O6eCYDo7p4JgOjung
# DATA mA6O6eCYDo7p4JgOjungmC8MHDNoNyJmbl0RjtmLei8RHLOw8rwTGdNCvfmtnLLYKFLFOqUMb8jvkuNFZFmz26531mQ4sJvtYNxs
# DATA TqvNpud3x4I6s8BjZRpZDh5rrEDf6lZcS0i1lbjW25vi2u+3u61wJa5BQHHttq8rrj0rrp3u1rgqmN3auDb7Xf61GNeGX/cCqr/X
# DATA E9dG91rqQGfQbYf+Slyb9eusA83OtdSBYScctlfra7N3nXWg1b6WOtBpd/ud/kpcW91nrwNWcBRas90Ztxv1Y7/9/W4Jj0sd6qB1
# DATA NYgd9aUaYifdsgWxa7ap2+juALEbjlpFiF0zag7rOcSu1Wm3Oi0DsRt0B1F/kEPsGr1WtxPcOMQOe6iqsrqhR9emxa+zaHVdtjnz
# DATA +y/HpSs7XRv5UmtbnK4cMp9T2c2X2t7mS9VzwjzQ1VUZ5WvW0wxMFNSUq9daocPBp4YFJ/lPg383XLh4RnXK6woZTipDs0inU7Vm
# DATA HWXvasQ4WTFQi7hri8C49sr+go2wOasEttimqzXG8eUcX87x5RxfzvHlHF/O8eUcX87x5RxfzvHlHF/O8eUMX47VGxVKjn2elOjv
# DATA yFc+vEdf7+hfBTTHxuYXb7ynjv8NzUlIHNZjkhkz2QZRPNnj0JmsJvqZWe0L+t/s/gK3SbDqBwVgU98YDqPDHdKE2+MTPGsCv1MO
# DATA hYOxHs14RDC4M6eD6A7abz5o7w7Yv8IH7C+rfvjCHLzPHVvb1RBZ5I1Ps85ohCLLAgLLY/q+TQvx+Z7Tf8lOrF6kvpM7Km9CG7Gk
# DATA QnDNwohlHYcLVBHvK0APiyFQrlIbyjgwIy30yRLeGN7B4B0tAQXrR8wGCy3Vb+ge0GQd47T3Pl1NIHKv1Q9FJooRDUpdgeptogWc
# DATA 5UQ5V3Ul3oDs5zPlOIfelwqBp1HnokdzmVYolemy6uFWJaVSk4P32oZfsOr2g4RGurE6rS6bX7X49sch5BaNTH8anYQpDtQrQdGT
# DATA cCJH80NVQb0JEsKcBHagx2EqwhQS+eJ56EXIIqk/WC6QJHMIuqxRvhpHncuG2jCTkmCKDXcQ2ITh4cswCo2UepixSoMS1goZT8On
# DATA 1ePFluh9AOrNJSKHXsREzBLS0BUJApgZFX6YKoBBMskUj9HQdDiY9KF3gl6I44vT9lsi+Ym8Zk0mvkYn1u1QnI3sbOSyjVyqVU6W
# DATA yslSXcU63miN35hc1fdibgNsJIRK6Ekr2FCOPbS0q25ZE/E24MDi3GEIDqzHNELOQaVyOx5YP2Z6J3MhJ9w26xchght1MWR3oASL
# DATA 1wnIXuNg4kvsEsLLL4iwft5E2FzII9xaH2GJo4qyX45yfXOc2TVmV11UrT1+8R3xTO1fmM1FCrP+nsc5WBvn1lWjrB1mdMNH631u
# DATA F8Q4D8BE2rpk5fXaaFuxVtVHR7pViPNGIPLby3gytEY09BYvLxf5IxmGZXQP53z0hhew9VzKgJO59+JTIkodSpI/poci8Ljue6Po
# DATA hF3a7DheGI8qdLDWCMkfpSxUZ8b/WXSsmVdGAuyHql/XXSGAayGw6Ng/ywZ5zfs/yVIY8ryHekarmyWzf4idQaK6phmZ4sqWjpQb
# DATA C6VI3symB6Z0NM0QDly82DRle4WNcHt0dUa4M8JXHNUr1pazw50dvs2sfnFkY9Vgp5sB+8DQFmwVeOB2aKwyrfA4H+qURGklVzHl
# DATA ocYInEKvE3urMOog8LlIdmJ4VU5EtLmRAFGyZSyYGTkMsklz9cr05Pyl3LAhgd9HpdCzCBqdh46fvAs/ecY+VDwh3tTNd4o7WaYQ
# DATA +LSFnKzdipbzDxTbF5+gnOfGJTGSn21GSOp8FYjk/YLnHi5tqjKA0qYRiqkETE2jI8ox459lP6wgseg/I8ydlfos1ciMb6TbZouY
# DATA JsyyAsFz5Zr3TpimpxBlTWZF93gaMrORrdZFeqq8xCzKij2QqUQMPvNkpv3kavJgN9J89Uc3kXx1yeyBlFF+S/JN/moVRbrAm325
# DATA YYZgnJqZyDOxQvOqfMlifm9zMetGoYrZOP3zJRnZa8E9hi7oD9HFwsgJhcmaksWuVzkyC1kvWgCiFM1LLxJ4NklOJqciCZ2ysjE6
# DATA V4xFZqmHypw38KGDHJte8ZmKcHvSbq0QC73MJcvx0y0w47y/0i1W0CNKIjmNwGKlIWc2VGLgXJKaBJa302Ec0ixwygbqKFqc0ni6
# DATA RB7HynkV6pascGNmMs+LLjS65ny0zCzh0OD7CDNS9rmxBwwLhLEA1565bW5L6K2V65X74Ac798FUYRd0i9B1I2/G7O3s4elK/6vZ
# DATA NlKssGpEaJqNjHE0jbM5a197H3KPGbKXYBKmR5CVhjLjLNOc+pMklf5V2op0rqMQiGS4Ba6lXa5P1YvfrX5/525VjV1kX0FeH0kN
# DATA 1UA1DDXB2jRJWfdGd5loY1HsUHhb+HQcxHFQlIpvHR/N4OqRiai2MOFYYWlwGJ3pPGW9eup1pZg5HtfR9nZI2EvRtb57qa5Vy7rD
# DATA MBmm4QkaCO9OmMQja6FaOdf0Hcp6iEJsC6XMgey92Du2PYMZDReWNnkGy0XNY5efWctW2wMGaThHnvORUL2fQnvInq1ct6bwSiV6
# DATA uwDvZ/LQvvo+xRyBOYhotI8HWRGB+fX5z8++Ovvz2dPzX9PnX4BnCWzln+nPL8CxPP+5vrgOi/nN2Z/o/1+f/fH8Hxh3ef5vGIr5
# DATA Z0FictC/pyu/Zn7mH5mc6Z3/6vzvAdA8/xXTMSnssz+d/3sK4lf097f0TgoBN/2CfvgD/Uz3/BO95OnZX85/4zCZL4WjFNvS0F2p
# DATA blHVPA46OxBfFA9hfZoeVPj7ETa7w4s6ALJOgVqOQ/ZchWaKYHyuoQcv3GBc8957NJ/AfKHOFIWFWCuDJlcH3srPfGdC45e0RMTP
# DATA ETRtH6ruM26boLlSKDfH0ORKae7C1kJeU1cewBXiJlXtODG3P+CvHkS7lhOIhF0nQDPOJCrwHsrOxghnfkPwg06jhaNn7lJ2N0DO
# DATA 5FVSXi2Pp5jqIjRTAVT3tIj4iNoA9ZiP9XsfRWG2VMu3lGNLQKGYroCSo77S+J4z5gx5i3gSKZd1yv5yMpCGy8kqTnO3KrnZ0im3
# DATA tedF1NwtHQ6p6eyCm7ALNGvzKubAa7GcemumwPVbAjsZApeyA27PDJB6WcoFG7f5orWpm+BwlpLPiYabmtmFJjJl+KZWKM4z5xhO
# DATA jInicdoHaTi3eOnZKP/lAD79NmSG+HI0vjJ7GC0G8HvviuPMR3zLYqDIZfnwPxU7YYh9eVCNgkINxdeTEPlkTcEe4IVvilsyrCo/
# DATA Ptp5lvE+Mo/3cIktop2KNCohueKPUrRO3ijBbqvQLKM59KZDbzr05o2gN3caa3aaAl3GaL7NKcBVZgDXNQFw6E2H3nToTYfedOhN
# DATA h9506E2H3nToTYfedOhNh9506E2H3nToTYfedOhNh9506E2H3nToTYfedOhNh9506E2H3nToTYfefGHQm41Wc9gOrorebI86o+5L
# DATA hN4sLT7vBN+k0GMaFr2ByIz1OC8Hp0I37OUZGzRFh4p/CdpFfmFvOIq6q7kMJmDQGPtB68tq12v5XuB7fr3HfxqtarfpkX1c7TWq
# DATA rWqnV/WDthf0qp3A8zv0pVEsjHa32+pF8o5inINmkMeZ3pfHuR3kURayqFUxWo12tIqy7PQ8v9UZd7uTql+n6HW+7FFk241qQD+0
# DATA u1Xf71Y71Var6jd7pdriR4PILzEP++1wFAbrmIfNdUlpSuwHKsYdC8LYtJJSrOPD7mDQX0Nk9LteI+h+2W1Xm5SSRs+rU5q6nh/U
# DATA v6xSWTSalELfK6EVw6jTbK+NW6vbyeNGAVvZ3LNqRr1Ii/Sbg2b7CqRGbnqa1Cit2CI1UlwGvV1IjYUrIDUGUTcaWqTGsD3sDHNS
# DATA Y2cYDEOL1Oi3Bt3GjZMasbe9us2koQHX8nGJbWwe0paMDSVEKkd+aUbc7H7bw79kanhsbuRB6PHWWmKUX9mc3NHrH1jxWzuX4BAh
# DATA KGz7/Ou4m+cg2jQ9tAzwgitUlfvlwIri/sqhkKU8aVGe0L8N+bewWtVsGWxkp/XttYRHMRYpzTLny5dLrQWs9QjHjajGCyuDtifX
# DATA 1wLJlMAuvp3DKRUNz2JLkyHHgXQcSMeBdBxIx4F0HEjHgXQcSMeBdBxIx4F0HEjHgRyFaNx3/arwFGXTMeCPZM1o5OMDfd79JFL+
# DATA TMY97ilcJC7gCQkKVfV9bPTb8xnJOJgK+7EQiJqrWqHIlYuDERFZiCer4/Ry1N6bx9Eg0qcRcUYO/sM+yqPIgcxP3rjT4e50+M6n
# DATA w8tHtNxBcXdQfLvu9gtzgPxB/EiaUIXGp9kplvxjOWRpg2/MkUdLNBVNZiKHOvHsw9VTzzgKyj2vOjs9QihyMjMLJ9El5bONqqW4
# DATA HrmJ083JFK5R+5y3U87eRTmbd5RwVcSHzfehv8RtP6K/WzSzaVBcCP7wE/n4Muhlmzy4pEjk25tFIlVuikDk2zjFOcKxbgxKuR4k
# DATA Nst4ZLlTVcF5cJzOB5eVpjynEPCcxCM5wZwsmAKR8dAEFxSC8UYR1aMJDCKasCRy8JhTookoz6KdedUseWfHLHlPa4LSmKwz5O1w
# DATA Al0B1url6FJj4gvmzLUs4bCsqDeCd5meRk7xAgnP68Cco6EZf6gJkvUXy8l8BDa7jozR7eCS+fKjzfkiLUrVlOWQLZO8jszClOak
# DATA 3ozmtB76GQaDQroVCxKQGcjhP7BouEpFMyGUQZAgY44IfZ6jvz8+1cbNc6wj/2rHOvJJsmQNi58uj/L80GrTc60+nUxH2DQCTAN1
# DATA AnNMr9AgmGakMEZDMjVoMBtQxk3GyRIn3mreZ5gQsLYCKyWIXXc0CX9mhDqeUX027wovmT+fbNGe1Z2q5BDNr725viQ59EmaHKMO
# DATA UJppdnMUGXQsb5KjShMuB1DhuD/zljMkV/cwEAhmICqwTBMo70MqmheXn2O7+XTHdsOVWim3WMhaVmSYJkuojy+hVDER4yHlM7Lw
# DATA 94OKNRzqngVKy7F0pWyW2UK8oVQX6q/L+XG7Uravi0JDbma7SbibhO88CXcz7ld8xr1xMv1CS7bxPhazo0WorLyr5d5b1KDLJaz3
# DATA XyK5ZltdV7ZSWptD5UI44W9l+bOVfZFSYQYJdg7Jy05nAx0TddL43g9WtlXqSf6qupz1GH/h1BTG90mB7AX4BLNeWHFsSNWTJvDa
# DATA v5A/xEenebh5QXXrXiY5px2FbT2zpUqqb8FwMBuothhq//yP/1GbEfzKcSBSdmJBeotoMuGpiwJNiKLX92B/Zt6RWFnhgmkRQ6iw
# DATA 0YxlvJz2dXGFXjo+XYynypplg5XnBkex/CyWH4uRYdoMUTNL88vjPY8Q6VLSyBXKrTTKBeeMGqBegRbMUI6uOAnTFU3dYoEy1MgY
# DATA jkyseg1ltaxgnNXmrLadrbaV+ubWTtzayRUsto3G4U2K7zKgaaR09FnMHXnNC/EFDd7nLwi/zRDAOT/PXmtZWToRW5Fty2HhWmFN
# DATA Q5b66fL71P/y2W++4u0NpheB7vWjpjszF8wKgxwQKSPj/SLo3kbG12v+5vUXtaHAjqxc2iW25mET3fyKiW/vOqOrNl7Q7x9p/d9F
# DATA sihUib1vXxRtE4iJdn7lgmyuW/FubI22Ml/NgpnsSuVVLqnyEW/xME0hsxBRqGH33pIzwSrOanuy7VTLL0n/Ewuqak5jtzJi70gQ
# DATA zwh/EtuKUVp5F2CrUv8wM/tL0PiMcfuROFONUjMjh0/G8STK+4kYarUL7NVJWfLWrHRQa45y8WaWB1YrnDBxZeOKbH0jU7dUBfRO
# DATA K2+oUH2mN9DawehSrb6HUrWc0v3YHpyHw3rSg3AG7eA5JSDGOcUwnfNCL3uOgSKHu/JkHIkBn3dcSBmEprlf44UtMjpqnoLZIYVG
# DATA aDpbzqnrUfrBRXHpO5zvr4v1bEG4eI7Ocwibw/WPzOD6+vyXwrsCOeubs39SaC7AucDi+mqVwPVf6banAHQJWuvsf1jh0CcGbP2J
# DATA 7tGQrb+c/+bsfxpK19lXdONTftfvz/8dE7pw0sE7+93Z12f/gypNOHHArZfC/mfj3tq6AVRgmgDvOkU/wfXN2DFMas0gT05dEqv3
# DATA Uc84E9XvE9YNl6ULLbtdUdzQIzT2cdhHPyWzdVHD5joDsfN+hBnCNtjW53SXiZBDbRVM/7xnuG3aVqlUbo61JbRvw3/iLdnWW607
# DATA f5pRcesbixXsOhFboYCtNFxBLRBKYhxe64Liuna01ichGZ34mWLdqlfq9TqPGpQB1EXVvE9oADFWDxMseNI1DudYC9Y7/xdh/xCR
# DATA FBx1ZiAUKK7oEQ0EOFtQZmhdWN02mynFxvO84FkXJsBxs9zwft3Du2ZmXX5Ufz2cebc4ol/3gL7TeL7zcH4ro7nUxkLSbR/di9SG
# DATA boKRVUg4I34yxWy3k0mT7jBTi2ZDLJr1YZmH2ElcoYTGQPpQo4kpCZMYLKnZUL92FMYT+CsHIVhFzBYqJgujbWgyekoDnF5gjmfZ
# DATA HEmCi5RayK60rDxk1gzI5H0Uf6Y08Vb0MdU5uFfoIp8p59Pm7N+YYYWP57BLJkTNQ3HAJkNGZolZkJmz4pSiB6dkvD2Cpywehuok
# DATA eySGYZRhH2KcjbGOGcKrMRDuCtIVj7ABcTCOpqHHO9+ZwjXnscihtBxKy6G0bhCldeEYtNNUZ0fz+fZmAVeZBFzDHMChsxw6y6Gz
# DATA HDrLobMcOsuhsxw6y6GzHDrLobMcOsuhsxw6y6GzHDrLobMcOsuhsxw6y6GzHDrLobMcOsuhsxw6y6GzHDrrhUFnBc1mvXVldFZz
# DATA 1Bl1XiJ0VmHVeSdwFmcsx6XHGSdoprpfkKNo+91ihjd6vc05Xm/0mqsgp17ASCoVlAWX6tS7vV5/HVyqIYEM4pQlqNTL2hZbqsHx
# DATA 5ANz3SJNathrdNrrnm+1dnq+1++1++ue7zZ3eb4b9TuhX86EadBseEHQrlLFbvW4egfTht+q+oHv8bWqXKv6fqPqNzvVTsfzu74d
# DATA NG8YLeG5usPusLcuBxkXVqr5nZ7XbPhU4fFqrz7u1UvBmbxbCa53BQQWNyGNwJLWaCGwGu12vxNcBYFVj3pRaCGwAgqokyOwgmF9
# DATA 2MwRWEG37bd7N4/AoplQlX7fadIeBDRWFv1WhZFGRjwdoscH5Az3SdtwyvjUCdYBpNq1si4Qbzl5XHKZWGPAyt1hyew3pnhXmeL5
# DATA A3rULs8D1835tJewy15CWR2En3DNYlu7mIjiQoDMET174qMMufwJMwyuWbErY7jWenx0RS16GDZBu4zzWEUHfmNr+sXfL8in4ova
# DATA SA77FQtbTzY/b8bpC16zYQq3GetlKvhOOK5tlXfztL5UmdfVyeXkwsklR8Fxvhzny3G+HOfLcb4c58txvhzny3G+HOfLcb4c5+s1
# DATA 43yhLqgT8tHw0KZ+LbBkyhmB1N2Vup4s00GECsK16jAesZGpGua9Vh0Gz2IMWMF7aZogju8qywvNi0we6qPTI+mTzWvvloxpa07A
# DATA JmwFk4uK0L+wrZHLYV+YYyYQ+k5dxRdvsF0j5rn3fn70n+zo02xNX7B/+IRt9Md5bLDVchTPKDsU1YxlRJXuw7EV/DvofKi5wqVa
# DATA wTnGaShnqLjU8dY+9ijT/JJfZMVPCepSV4OTUB8nxj71TnBmUVmf9BtHkKo15z5O7VT1j/TLd7fZHVyGVD55uu7mKdt/XIiMiFGZ
# DATA OGiRRvUmnAZEPMTqP3xijPkv3jCB1xA3equ58Cb1VaCw0TVq7fkxyDtyo84NPntUTq9KrqlsW9sLp3Nd4e0WDE3m8HoKiO1lybM9
# DATA saEHi3RCU76/+zv5is2A9HX/b/5GvtOjlKdfvPEeIx7e2H+8wfJWRjd1hdniAVvse1KoTuLeqSlcSU3BqSi82ioKl1W3f67qCsYB
# DATA KykSsT5LyX0Rorrd+1jLcHNK+SDrEtKW8eaEvKvP7ufKAxJLPLTtwQfcbnmbFxaFNj5VyA4xFqy2lz91BzHVOoR8NHajwL0hMSkp
# DATA BGrV28XtXzixiZfgcDX/95rJCUVRjOvmJpS1RtZSEy6rkvV5GivTLZ4xq5FsNxgzRiXL6ICwclkGC/gEQmbTpWg4nLKfumIE9KUy
# DATA qsrDFQWjZCaK9pamBzQOQrbok9GC4UppxG50JnAp4BYb+h4vDLLe+Cx6xD5epaxxIcfo1Tgnb0Jwxp0z7nYy7kpKOU4zy2lmXcKq
# DATA 22g63pSW1gci2EQVW83llROBq3lO9rltxcbbELlXngWduTrpb+mdGFpxXN8G1XTxlOEyO8sKAuuUkZMJe7QZgIC1Yh7d/gYupkP0
# DATA afLpQF1QFrV8q8gfdour237sV4JK4yc0KOoYbZCUV041etcH/ImrbBFBbG4xfWv+0AoBOGBkw0ni8VaSLeDhphje4B6W7lwBBW8U
# DATA kzc+rLzqvLw68pjyiLyUspHWSZwtjcDZXFpNRUmY/avwOHwgXaxSMwNhRbtB0UxUPrDe28msqIUmqlkhIC22S07pY9GACdEzQSRN
# DATA TpUj1DR3KFyJABc9fYLTXTx0suaU5f6reaa4MCKSjbwcLJaKwjSJp7jIG40gWAWROKZdQLsr01EpVYR8KmKbyfnUQkqr6DrF3FKv
# DATA 8BvXoZrzmZpzsez8q2Gh5sOMM1GdibqTiWrbIs5AdQbqVsPzeYu9flxoJDMMdIt4mkOZHsgyKQugViwKoKTOe0/LIEJgEcd3OLvo
# DATA dzSVYcJjNXQ5WS00PKJ4YcvZ7NToQe6o4MrRNbEREhTVAgg6ikFAjZXafcT6lug81njr1InjNZaq7FFABeNPig6kLBn9Y25cmSss
# DATA PQHkfMThqNjJnhvTLW1mFZmNDwz9kc9Fu9K6w3SJ9lMrJiN2DmB0RMco98XbLEy0SO1L3nyXpWMrGEfzdUvIURYfcdrf5U9bbNci
# DATA G1x2EtgGi6KZbzIbC2WM3dXSWK8AYNe5cUkA++MnmwnskrFCYMckLtKMdOW0P9Uk9s+wZZRSni4z2e7FNXDG2qlKSBdzIJA59Qp0
# DATA jE0YITZQeP0lGbpKMTUe1Lx3YxZYXbLQrjeNM549yl4XbFdiiihvApFr3Fp5ZVhIDEAQ0etSxWd7ZrR9qQZdMoP/+R/+tDmHC7VR
# DATA MpolXdNIhH/hV40H8cIg7/mXnL7E2rdkVIuWajLXp+4XVNtS1vHF4dVFLPb5/REfCqe5wbQfHy3BfVSu34ru7gQVJfTHkIx9lvCN
# DATA h/ybTNivI0evWFen2W519eNwKlUBUtZ51kltwRQHCrayz1dUbaFTPYkWQGLJ7ibztMcYD/ReDPo4BVpWaF0zKAOiQZD1R9Gh3pOK
# DATA Qm1QMA3k+Ve/f32pyiesM449peLLZbSMdP59iBkcJm00gc6VmE/CmJ05fEEdN48AgH5XGiSvSUjFyfKKygEj60c4WsD5SRk4gwuJ
# DATA A1rIU8D0RqAo0lCJQruWqme69ktm5Adb6p4aJCQPyyuU3iINj2ncPKE06Mz8VB0lGCuB7FCqZUo2TDTMlFFAvdxsweA4hAW7ROYn
# DATA 1JBnpmdQveqUeo2M55IxJB6tZdUcLreIlZx7RPNfrcIN2++55utnu+brZ0zgs5arcL4xb91qOSyNjrAfXA6IUEIyNWRgtMnV643k
# DATA eca+itwyjEYjzmG7Hwj7GYtX0wyN3Ttyj6rO6E3F6ovR2f5UdrOWMrRoJMieRdtIMFcke8iu1bsL9cSOnS1q1x91RINxAv2sEP5S
# DATA KkldEK/FwpuN0aOSiGyC3n86++b835x9ffY/z/5y/ltw785/ASQe/febs9+d/0bQeL8/++r852dP8ffsL2dPz3+7StSzw2FW3i+Y
# DATA xodnvzn/NZ46+yNdZN6eoPfo7589uuXr83+g5/56/kvg9BCDfhqdVA1674/nv6K/v8XPTNz7s0PrvQzeGqlpNm9eppwPY7TSmWwL
# DATA BrHhh8Y3I8r3MMfIYhhC6YctBVnfwO8P9XaSNBrEc2VzZUv0R9zapwmL9W8l6b0j8bIakIPp2V4a5M5tc/RWy+TmUHpSdfKVxE+l
# DATA KonkSflm9ETWmmN0ciO0bN5RPVeHLigrZMKIt02j2dLx9HYos2tH6olZz305dz3wMovfrE8GhO7dxJ7nbuyzvFui6pqcKKiPJpyz
# DATA zpqgf/nQAQotnk5xRgcwISpsAyO+VP3bggEuN6rnhdi7OBGOsefG+Wcc5zVS70rD+2uyAHMrQ/sNjOw7DeyXGddvZ1iXKlnOAQut
# DATA 9zybzk2Q9MpJ1Ysi4lINWW6yNCJm9pCI+K+MiRWBYsnirKyxipLFcbRI5vxMlPGB9oTMpcU4GWa7YPI+RR7KMlY5RpS98BDwxl1K
# DATA /jTGBpOErDLs2ZKBPq8u9M4wW6YAg4UsMEqZzP78inbbpxHaD6folEtGdHCEBAjHCpPqdGXIwongvgZwVmuemaPhORqeo+HdIA1v
# DATA l9Fjp7nKrsburdrtVzHbr8Nqd1Q8R8VzVDxHxXNUPEfFc1Q8R8VzVDxHxXNUPEfFc1Q8R8VzVDxHxXNUPEfFc1Q8R8VzVDxHxXNU
# DATA PEfFc1Q8R8VzVDxHxXthqHitdtBvdK5KxRuNetHwJaLilVeedwLjFahvjZ5FjWvUG4b65nc6RW7caNDtqbyhCMY0spogGnkQzWY9
# DATA L5tAaHtyeCroFcLrNINBY7BSUEHL94IgGAed+rHfbH5ZbXs9v+o3Wl4voD/1ahdfqr1gTcmtovlaAYXWqo+b7S87Ha/jV5tUD/zm
# DATA BdQ5E9gKJi7orM2ArkXuo8hblbPRyjOgUXjvt5qDoN2or0S50a57fsv/skppbVJtqXb8aatJcf+yGvT0lSsnwA+uALrjVqFBd9LA
# DATA LNBdp9loNJs7gO6Go3YRdBcOe4NmDrrrtFu9dsuA7oadQb1vge46fsNvdm4BdIcmVd1ub3g8vFi3lvlw34uoF4jDigRcWsxbQcU1
# DATA eMEsXy4rBq3slhUnlc6hFUdkyd9vh7XOA3+pQdVj31udDSf1jFoCW5t041ZdjaQxy4sIORW2oOvWbxUoE+1WMWtrc8YMfHr1q76N
# DATA BrdDLbgpU8Sh3RzazaHdHNrNod0c2s2h3RzazaHdHNrNod0c2u01Q7vZMDdJNh/YuisgtSFOub2x/x35xkuOjOVSyLNkEU7kfrSo
# DATA Nz8KF+MazyT3+OL+m5QDOI5K71FOtDk0ZpZzvn2v8I478o1+zLgXWSTvYzvenm+H8rkcJrMCKb+zFAw/u3LkTBPEZApojnS4Q9Tu
# DATA EPW6Q9SlYz7uOLU7Tn3Z49RbhG9v6pi1tAK2g6HXLqus5pj1cxTyuA3qwlAdz1Y1A1+9vaN9JWmrm92MHRi5ALx6Ku+b1PecWVBk
# DATA MUxjFqBrKWwD+/5l0QlbLHgtquZvFr6V8RRSzGZYQzHgULXk/wXR1c+b+JoLJsJ+e12Eu1aEg93jy4MqKG0cD44mXbkgkuqhXLdX
# DATA fS9wIFZi6Fsx7NoRLEZvI+/hHdWiIiMa9PLiHt5hK4+HMQZ4YXKiDyR/MILKJvoQPoaf8UCHtpeRWTKvsE+TWukEXv/JqQclTVSy
# DATA GLw8MYrEWy90Lql1fG6cmqEKcUhBUIAwc8Y6wEECo0eFpI+DM3+Ca3KULbDuzlMqlmCaskVsiQDgNDgrMPIy6hAnyTxZuzm0xQBg
# DATA sqH3y5JppDuiD2n2cowZ0pgBGNy+B9gdrBKEaOd9zcWAhlfnYLGDxDpLdrsl6+zWV9xuvSwU9rnLA/GCubUQvGr0TQqSgEz9yVh0
# DATA W/EP+nyMFKbIVobqc1cVekkUOG4Cm7qigHTd5NQ1alLr4am7KSGW6h+y2qYpsIj02ynSqoZ1Vm3PFaR5T4+eCC0zgVNpfirbYhHm
# DATA WcPTgqRL6GGjxHKq7DNUMPqQRcpQQmBSk4oGikInv883GKOkLMHNcf6UxV4lyhFlsY7xB2aiFvMckKIqekaLOK2wMjvHRquyFyw0
# DATA rXhv4wPYIEVQZAXgCMaWaH+ChbntsX4A6IqKNW9TioY64u9piashzW4RG0oC516Fp3wV7xSbZUXVCT3GIjmKoGJV8yyjOmFl0anH
# DATA oAJFfdkUXf3C1Ri/RgI2dp/kLE1naa6zNAvjlPOYOo/pRQbq8xemlBhkSlkxTZIpq9Rxg8jlKScTaSprRRJrqp5XxFlRkcEIunNo
# DATA RlifZioYe1Y8Wb1T7YqXES9HAXufrQSl7ihtUi03cpjo+eaM3YQLOJxgA4MIZDso2C5QMLG4bNNq053Gz810F/1l8/1apZNzVX3e
# DATA fLeW8SyaHy8+RizPv0tyXPwDv70Z5aILQ1AuP5hF1JnM2bVYxZFFbRlifcNveUf2SkbQrNMF5Ub8PFIEMpqCYKvc5LRCdjv2/vap
# DATA XozwdYHxEiFjD0mGNQ851ZFxDwFj6yTMxqKlqi10ujSZZNfBwbmV/PvsJOH8G9I4NS/mXqNezL1m18q9B7xQg2RzX6syCYqlADov
# DATA WI5SpDHlLvELTyLgi7BZ11OHcEWo9Bpyq9AGL59hrc0ZZjVoybPvUZ9KsXs/5ansXCYweb4FpVrX6LSsfFvAlOJlMjac4tlygSEH
# DATA oqWT4sSKRwyG9VDNo9mVouCZSdgxdjROXoC8a18i795BFUhFViJfHyxkX6naNYJ6KfsqPJVmE/VIiiKjeaoopYLYJ60R+9GHaXiC
# DATA rbx6aYD1ZvOlgWfJM7sPv2SWfbQ5v/LRQCH8koehtq51Jr3PnArhRgDdJ/TCY7I5jJlOFu5DangThXYasurwNBkyyc8bYx3Y+1SE
# DATA gplphStm+cSsymQ00FOusyYvWvR1ZJs9mF26pgWbMy4fGCXjjGOgaKDpPHyAq8rrMvP8LtWwoc6r0Gu0ec8QVVRsC2QXAk2XlCNG
# DATA bDfGyHNdS7yjZaz4XsyNVd4bNht5y/mLivB6VRwSOcZrFC8gMWtzvP7fs6fnvzz7y9nXYGw99c7+cPb7s6dn//3sa0Zvfb0K7PrP
# DATA 9NPvzr4BY+v83+IW7/9n7+2a3DjOfM+51qcoe8LR3SYAogAUXkg1tRRFvZyRZB6StvaspVUUgEKjRAAFoYButmVFSNbMmZkYx3HE
# DATA 7kRsxImzO7GxF3uzFxp7tJZlS3OxX6D7K5xPss//eTKzsvDW6Fc2yZRNEihUZeV7Pvlk5v8nSK6jfz/6M/303fGXx/9UQDgUJoX1
# DATA Pf32J+/47/FTke74ln7/Db/p26Pv6c3fHH/BeDAguxQB7Df09U8UIP3kmF3Pg0slg/qhyxzaPCDpQ9IYPlBqkhoXOJl1pqx+Lx0K
# DATA ZVg0FfjiPqZ/8VBckNJu4ULt4fQ5OABQKOGnwGHkjai83bOjNPKTcLAW43UfK+Pd8NDE1HG8bF+L6iCuGuS1pFQuj+SlamG2ZPRI
# DATA VctBTPGcHM7fL7VR3/xOrpJeJMwLLkMVE9HCl535kY6XA3ptVnQXzvR6FGWgg4wFMQEkVXdZhsrBJeel6G2wF0hkhBmqYE4Rw/Nz
# DATA iK8l7+24q2fH1LvJ9FqcUyqlC2SvkyvjantmsZU9K7TXyalwaC9nDly8OaBpX2ezAl6K1ZarsgAuwwDYaPw/5fB/NaO/VMyFXLCg
# DATA X9esUV0GB2wh+YCaYm0oZc77+pQVuAZC9YqTMJ/Od6ZqawRvgWCRkDicmDfpoDjlsuCE4lSug43IYI/Z1wt/EDbgpHC9RZNwUFCW
# DATA HA1ocXeG4ou6XIww1iZUQ3gNuZthnjjC2hQwO0ZgHlCg4vKAc4raOFwz8ahIWcwgdo+si2k8irSjipfPEDqWoWG2FMRmoReLHWJA
# DATA UI4S5ihhjhJ2eZSwDYecjeZAm5rOVzsNOMss4CImAY4U5khhjhTmSGGOFOZIYY4U5khhjhTmSGGOFOZIYY4U5khhjhTmSGGOFOZI
# DATA YY4U5khhjhTmSGGOFOZIYY4U5khhjhTmSGHXhhRWa1e7/POZSGGNXtBrP0eksIWl541QYXa++IFX9Zv9oN6ao03VqXdsRstoU9Wm
# DATA 5BCXkZRBjRUphZTl+zmlnvmyq/h24dVz+W/emQs9aPmXGHqrngVea+UCl1RlgfvVug0BywXe6jXb7d584PWgdeGh50BvNWGxCaTM
# DATA r2egt6CZCyAKwrBZXWgW9Ljn+839WjCoND2/cQKBbHWdaJwBQMaNTQPIpN3mAGRB2KpvACDLXQGALOh2euUMQFbvBFGzbABknV6n
# DATA 0o0sAFlQ67Ralw4g0w10LXyq5AeaQpa734yOeoEg2IQ2lg9C88ayflzn1IIj03q0jUWZJc9suixQqisLpGI7HiqlJWvCPhtEuTfn
# DATA PApiGeA5nr8Yb5IfkJ0Ak2qJR7JiPJKSKfPLLEsW+oKFF1Ru67kW9d5+ZpfMRb/J9twyLlqr1crT0LDKvJpSliu3wlxZrLF28jfO
# DATA +R6M+9BhyByGzGHIHIbMYcgchsxhyByGzGHIHIbMYcgchuwlw5ChLlAo3UFUiHiZqLtbLrDTnT+NyeyO0t1fflSAQ3U/2mULtoCO
# DATA 9gF+2kWVvG0qNJ8ug3U02d75LO5ty0M7n+mgqYXCBAlHnag0Igt1p6heddsO/jarOuuDG9sSvZ3b6Ao+3HqcHWPrCk7sc2uOg32E
# DATA +v1Sijj2sea9SD89RUllJQ+aGE+2VW8FfWJJPyVg1L2xO1a799OfwrC7TelD4K/Sbzuf8dO749t8JoPiRD/+iK9RPJamJpdgk/W3
# DATA TYbfllqHCT03+qyGUZ6/qfSdKe8VEk6f/DHKz95jHJLKn7+cUPSZ4EH5ESeSfWLL3/589euY9NaJ4sH2NiW1iDTv3GTTFpA3lSUU
# DATA E0qyqRfUkDj1JXbj7nyWVRjrssTdvo8yzubiZTVIxRK5KjmkxoKdz7IMQ9GhOGPKxvhVRc5jSTekM75xQ99cGs/INPlMxfyW3IlT
# DATA dnRfgSNCE+sPcOruv3/xz+pMI7B58Q1/h7oYisRC8EV/Z03YOB5ph/0QxyV5+WMx9M+zuvC5qiM8mdRtcrEqqwdu52r/balnu5jB
# DATA 6qpn3VCoBOV8i5rMRiIlLIQ+rg7cyujCa+sM3KzNq6cmOEN60lNcvnZ3YdX8LAfm+pl1TeIhVFaz9qAShajoJJk54JJo8RmUeEDz
# DATA IdOn6hpoHpOxYicXaQr2IB7RdHFZoFhJo4eiuUxyzBinM3FGnQmnL/Hi60ucliRzHXQneGUl569fj5N5D4fgQeSA+Ko+OB3u4VXT
# DATA ZJhMaGa2lilzHUUrnp8j3JdBmlnU2Lho1MwyEZMzsma83BKRVGleYbvjl7U0sGA2jZwYvUzdAgFPqSeZyIct9P6ErLKCuJ5Eyx6R
# DATA N5a3rOYlY8wiAdcT1kN/Npmy1Fes3jumkX8k+gmJkvowIvZrhD5OUh59gY7o5xqOM6GcCbWhCTXXvzrRLifaZQ2/K42v6yDm9fos
# DATA BlMrL1tlpLzeEl0ouylh5BlHCRraQT/JjVCCENADWMm7CxEbFB1r6oQyF1bwsegJNcdwEPegeAPRbTgfREJqFEVdjRk7LT/FRFQB
# DATA H5ScNqTVC0uUtBw8ZRN4yjCRomO9e/V5HRBlwm40kcCXz6vvxm4f4Wbf40+r79TmjuIL8efnAZ1i594pVfKbMBxX6+RnZZFjWbBX
# DATA T4vj86woG9kwfk2S2V4/awyfMOydJTw0Lmk2IuORtaiyDdNoz/tJzNpWHTYPPX2CHlbjjMXmxizfC2OT4rAXTS+CMnCO/AtOl39v
# DATA ROkTj53tFloA2rgK7mTSy5Jx4gpPmWdomw4H4eAJ5ZWWD+TwcNtsAEw3oxq9aMRlwOJtOAXhdWcTLa5Lg9TFMC2yZnhaOENlfb5l
# DATA rVry7XUa42XfHzN1ZrGpfcq2ojoXRSuFDLF6NALLQvKSpelkMSFV9K4onZa8v2EgRtTpj+JPZ5FRUKRKShM6sBKmfUw7+iHXROTr
# DATA VFXcC8jNrJs6bV6eUAd1ryc5+QHVHVZB1FLNBkNqMonSyFWILVSFGjVIeLJwO08gBTlnyqrcC1l2USH/BpGaZHK2Kw05I+rdyw/D
# DATA z6oF10/Xgl8PB2xHqKlCZLNoYBxwhqSzMSZglMBw0j5Uc4OO6CzKTueSxys1yF2WI58othvlWi+KIKKIqRZZFFE6jjoxE2FF/XJy
# DATA yHqGZhI+ig4uIgftse+0FbC8PguzoVTBVlC5JuaipuDStGvIXRs6e0XqMdOwTggqD2XUARnYMNWxg8Lrk0WI+oUsYxVQFj6kSg0d
# DATA yH1sFVN7bK4tVOUFcm1kQTi/hvNrbOjXyNc059Zwbo0zrgmtdIFcmka5qrI5+itMcarmxrvxzFkZ67wbzGRcybHnjd68zIHd3+rk
# DATA or5mJr28q8EeOc0VPevlXMrOR2JnCH1Lej0xDcKu2AU5hwTvaqGf2UYyvc622p6yo/wiuoWPeEM/XiGRUk+bnlF/N/P8qhzfxDAw
# DATA IeOejBc+c4eLw/Cp3FGWc3LRmI/mrfad8CYZTolVphtHVT1toqq/m6hWToyq39w4qrLtB5HlTyfFTd+exc5cMfGrLYueb0WvsiZ2
# DATA alXQ+LPkXABP/8Dbu8n7FIdkYsuNbH5MhndeFWmFLAtxLMSug9mlXJ0b0+A+leO4NyWIrCIb34zVPsylFQ4cMYloMti1TO2cwv9/
# DATA Itu0oyeoNDHvYZQ0IB2ZMhyENLwDtjOmR8lAwwxMUYGyWawGUio6oZpsCSXV7P21kJYYkpNBkWGWvGOL3tIFDzMRmii8KAWvG//q
# DATA VzGGFHavjGYpBPnTQ7J9k2GaeVHtmPWjwfiEheO5Us0Wj22/arYMLPkve7bo8Qf4kJX4mQKTrVzSKKOpVX3EhuUSezmscot1OJuQ
# DATA TUwmnU07/G8ML/wGtME8g/D4t/h7kXb4X4++Zh7hn49+OPqDd/y3x18dfX/03fF/pid/oE+KW8iMQxALJXAO2WMg4tfAKB5/QTf8
# DATA /vgf6aHvcNsPR/9G4egn/3D0A3CJ3zIGkYJ0zMPnYYZhqlc2seAKD+IJcpSeKSh/JXc4GonBwkmG7iwRJovoAZWi0AhgWBmCB/Wk
# DATA 2ugZx1GHZuPr4IYP9TYGGgAYrebQhtZkQhfYVcMNF0rl8tCGqo7o28DZ0MQd/mXhfmxfsTrcR0lP7Wm5cLQhRyAHNoxTruwOa7hZ
# DATA sV041vD+0/EAvUyonSHDpDsbhCCvJ1PW7Cl5H6Dv574r2+fFi1/YGE/Pmv1PFIfZkHvKVLZBwYWSTEO9lhWOBB2zADQ8uQqutlrm
# DATA W9azwhmenAaHM3Qj/TlGes0tPMsA/3J4Cq9scL/4sX2jof2UI/vVDOxSLefywGIWPquWcxlwwrlUYgUAJCDF+Ys7VmL1Ocf5BIXi
# DATA 0lRQOdDW9CbqFMXDm69lW7GW6IaVNGKv6Hy+bUgkNF7WLHbpNOnwiiOPxxoVx/w4riVdmmuPUhP9aDZJvHDI+Dce8iMyG+JOjKXx
# DATA nE2QswCipzhYjMC7EbxRake1Wisk64GK870oTBEhtu06U7hixEhkr45Q6mRtXRV1e3Yo9cvRCh2t0NEKL4tWuOFQs9HUZlPL+Cpt
# DATA /LOY+Bdh4TtWoWMVOlahYxU6VqFjFTpWoWMVOlahYxU6VqFjFTpWoWMVOlahYxU6VqFjFTpWoWMVOlahYxU6VqFjFTpWoWMVOlah
# DATA YxVeG1Zh4NdqQeeMrMKo2/OjxnPEKpxbeD41qTDwvapf3i+2Wp/6jWK14TUC+rtfDSqf1lpexatXvGpjv9XK5VLHb1c7vXmMHYVV
# DATA X4qxqy2QDeWknwD8WnmAX1D15wh+tWZW1nJsLSP4Rc0o7CyCEy0+YDPIBV+ptvLBt6orQzfJzIVeKwdrQg/OFLpdIk3fq9Ua+7XW
# DATA kLrWYq21X2ttnNP+Ioyw4XuB3+jXg2AulE7Qabc7S1GUp8cOSrvR2EFpghZ2sN4Nmo3uidjBsNfu1XPYwS793a1Y2MFuPWgEBjvY
# DATA 7nRq7ZqFHawEtWb10rGDZpsahP/3Npqvr+H2iX3rLdhF2hyfe5sZKNXU662Iups4LEj8lgIMA7USV1mg9WFhceEFc25322jUBZKf
# DATA d5O55/mwA7y6/LHDZOt04xwKtOmETBEjNx/UnXDeULGwgfnI2psL9Iiulr3Ky7y9spiST1oFvk/+S/2xZ9zriYNz2VqYz5M1Zsva
# DATA JLM94YCDDjjogIMOOOiAgw446ICDDjjogIMOOOiAgw44+JIBB22+myRbvBhCSuOj4oj+zk+b5RuVcoFmluqnAy7CHZmyaczXfTkk
# DATA wwfd0Mhu8K/g0nWGCDjy/r//zWuV8a0bRePSh/TfCLQ1CvfObvm1D7c+YC11PkfHCzUIhH6UIEo85aEIS1jm8A3i4rUPcS/T8cJ2
# DATA ihB3zFP4xO96xz7KJqnzonQKP3J0y/vvv/l/EJmFtG9XK+UbcpXFPdE1IEiNMnMIMXe2+6Sz3e5M94t+pvu0pLDrcNZ7zsW2HhP2
# DATA LpqGeaLkvYdqb2u7LIWDPdPT4c/P0cjLoIDNH2a/aAbYoiTAWQlgeX+tPqv/LlO7pCLIa3qR0bV5A67H0Osm9EN6wGe0H8AJiarF
# DATA UkD9MJ6UvEfxlN1PWvBdKqAIl8/GcjxZFW7u+H6YSRmNIdqY9PgsciaaM6dws1DOTyKYyqGR24FNdPVKN8/oFKzVgpwx5IyheWNo
# DATA oUd1ojdO9OYkM+p6iOE8kPrKRItuYvAXnyRto4jz0Gg3UDOM90aK/KU01BQ+ckLDQgfiFj3cLEoSaQj8KtyjGo/DG/JZvkN0aOCG
# DATA HNjaLUs0UzYGfz2G6gz8Y5mSjc2DYd+FqHY43NdmuC9KCvRJVNKn3GpWw77Y7Siy0Pxx9b28PZd7lsf86XmAd1l5cUruyqM1/CSd
# DATA q0JcuYdWQaUrtpUAVx4fJCLWlMwgGBNCjkUgK0O0FC2RiBoeshdKZJnEPKRxbR9e5F9BnmUyzKsXiUoR2X5JNt6FEISh2hGKRn2P
# DATA DWV95lQajZodLBd2XhSANgtvYpNkCTQ5pqUcMDZgQZkzhh6wBKHPx786c8k93LjkHsoBc7HSddG9C1sEHWHIbAAqjj2l/p0y6Ssa
# DATA szqOYgnl0WEoPpb0EbVvKgKZpN7VfEZ4DNW+KO5NB9FUgQUmKi7pOJmev8hyKbu6Mst6k1OW2c/W0cpUvyRl9jMIECEf2wlFyAZE
# DATA sTSRXkfRgmZ7wsii3KVOHBeTHlkjhqfViw5Ec0oPblORhMedsrjDJX3A9DdmrphGx6XfnqWH5y+tfJqeg+J6f+Piej8EuJ0XM6iv
# DATA z3hUaV+09E1joF5vD/7wJ9GhWPvtEApaXj8ZSsPC5GDEobFG3cijgpqAFgZUDnhV7IDvxU8FH8fQhKww54Xfzl9o+ZRdWaFlo/Ap
# DATA y+zx6jLT47nqFUU5ENey8hJ/BPbhYxigJpQKK3AgjhiWR+6ocYK9cd5dLt8e47uoE4IIGcY9sTxxbMobz/jwHIsnjIB2uYB+L4v7
# DATA 9S+RyqYl8n6klOswfEzVT4pwKeeDIj3ASHMSa0OE+hKPj3ehBRyKIKGAAVWr4f6NZ9YIAGY3D2Vxqo0UlK7o311Am1lMyJmK6WoJ
# DATA c+fCmLwMfjYrCOdoc462eUebXaWcj8352M642LjSJ3dJgtMyJZeZHkZAVG7YmMbF9gyhBpdEnst5svTeE9j7vMkay09N3jfDM2H1
# DATA +wmgsywU011ZlzJq3Emos/qGHLYD7S0z4C6eF6hde9ud4YmAOwkgA9yp7xbgbik2zpfLGhxX3hhyJ7t54C7EB2GMCQUZKsWcV3MO
# DATA RPVA5j3UISz47Bplxn5hW7t3gIVM3l/UKK/28vk+P/I4eoqeqGs9Rb+seazGj71Ndx/az9TKa9yEKxF12jTFblqy1KbPL6TOdt0d
# DATA 9CkU7xOyPEfRYcmWfFa6ztIJwCF0kHg+t7RwomBxesPamKZJynTHqjN1FhQnTK944KagjTteHBrct4jHXrn7tbo2v1htO/MYcEkF
# DATA Vq2Uud5ZLZz6qJmGX6o9uZ18TYXetJJhp1C0CnuBLPyn0vWNKI4DmSqyavZ4NgHoXRa2k5T1Uy2B7A0gci+I8Zwh5KgXiTqTsDe1
# DATA EHLv6WvF4787+uH4y+PfACJ39IdFdNy/LMW/0Zdv6Kmvjr84/hKXPfrnG7r4e/77a4Dj6Mp3R18f/71Bwn179I1SSIfC1xjaqTRk
# DATA O0zctTf12TIPPVNnvP8Q7ofe/W4sZ7FE9F7tK+HZb28SR6MudSD87SCZDLrG+ofnezYW3ylcCeI6GxwyXTeBS1soouw0yBYoVM+D
# DATA p6Kn1NC6axFyr0NAg7UmPP5beBKOI5fNCEyncNUcueVFc3kwuT5Fh8kFGZya66u+fhJM7l4okuCXAZTjzVdkO9K/NCaI6wqjORqM
# DATA A8ptVnQXDpSTPAvZzBmhc5N5lZlOacNGTaaG0kGR5aIrCi/w0fCGfpet7b1ZSI1iGlHf9kacPinA+qGn7z34uZeOI0XKwPF3SptS
# DATA hZmxDQTX4nQD2tzyOrraxFnaBq8Ldm55Yhx6zlkPl2Q9aCzdmY2Gl8KFeHUGwyXZCxuZC6e0Fq7OWJBKuiwzjKFwPRvaZVDsrGwA
# DATA aA6LxN1oDA4VmTJmoDY5xLP5FdnSSYbDGbprLOC9gxlEhx0WLCmSUr50InvEn0TsoBDvHzIsVZvtaaSnIuPrvXjCp2jTdGPCHUBa
# DATA qfLNapgYZcg+WYQT8XOoX3s0V475gAPvCHov+YRGNI+T16EMTHrTkvdQx1sOKChY2LwTeMFukbMCGkFmNC2YZIb8gC4OpIP7lMlx
# DATA R7zHnPaRuGt4L2c0Yo4OTsijdQFEpqoE5apj3jnmnWPeXSLzbsPR60wHu9aZ5Vc+07gIj+pZ5xkOgOcAeA6A5wB4DoDnAHgOgOcA
# DATA eA6A5wB4DoDnAHgOgOcAeA6A5wB4DoDnAHgOgOcAeA6A5wB4DoDnAHgOgOcAeA6A5wB41waAV/Gr3Wrl7AC86nMFwFu2Ar0RBc/i
# DATA xVUyHJ2cRsvyvTGnUBo0c9lVC1qNIJojq1UqVAC1NWQ169WtM7+6WWlX6tWzv7pSP/Orq81Gu9Y9+6ur1TO/ul5pVWuNs7+6Vn5m
# DATA ZV1rPLOyDmrPrKzr/jMr61y7bjWvMsNz7fp0rz5vhufa9elefd4Mz7Xr07363I2r/MzKOteur7asc+36ass6166vtqztdl0J6leZ
# DATA 4Xa7PuWrz5vhdrs+5avPm+F2uz7lq8/duMrPrKztdn3FZW236ysua7tdX3FZ2+266teu1FRonfnV581wu12f8tXnzXC7XZ/y1edu
# DATA XOVnVtZ2u77isrbb9RWXtd2ur6SsbddDpexVG5V+UC/vN4K36Wve6dBo14NaZ+ljtVqDH6vWFx+rwdHROI05piYgFlzer+eC9JvV
# DATA amUxJkE58CpB0K+Uh9XAK/cr5bncaAdR0G4sRbI3z0RTr2Y0dfHnWDT1ZjmMgnqepu63qn4lyNHU5/jqoKm3o1anl9HUg0q9Xmsb
# DATA mnrYavfCckZTr/lBp1K+dJo6O4OLbd6kbzydstiuseiZt7UpDmv7mXkgulmKW7bspjdqNHiDJrZnMhN9cbdjHX5WeQ0fBNtsW0bd
# DATA 2paxEuhuhbqetS7FpZyWgVl20TWCjyX0w25ycKtFP+JP2VOl+HmJXjWEC2zFEmxlIbj1eZgF6Kmtpnr/mixbmV/HS3YfqLVeXcPM
# DATA MoDaC5p5ugtzJwryy9vl1bB1u6TWuMOX1TV2crNf3UHVHVTdQdUdVN1B1R1U3UHVHVTdQdUdVN1B1R1U/SWDqmcWo9Ju2N4x9h2l
# DATA 2nso2h+Z8MdtIVZxl8228uCQceUiKlIcJt1oV9AVdFG22aJRZ9dEZKIIG2S3EgT1gK9ilieyaemuZqPz1FghztVvaJQakI6IwQUx
# DATA hTDbblMCj4cKNpL9UpcXJNMuQubCxBdUc24bpZSG6mi7XKjXdmAc4aDK9s1ffqj+u7X71z/CvxMO5qObewUqV4vTzmXrLcLpoSqw
# DATA +9l+OIoHg/BWpTAezGjan96qFiAZdyv4/JccFZ7Gmrh8pPH0j2Z7e1Eq4yILkHkP7753y2DjO1E82MYbbsxnz09LfpNp8m/Frwu0
# DATA /nWW/8l0eOdCkQBEAIcm+QhC8+PHsUDl/VJFB4nOWbFEMCqI4AU09UTokF+o6gw08aaQ55uSuaxrkCgJQbJFAek5EzINWbr62jpz
# DATA ijM47q2wZD8zEw1IpM3J09LTWSXfuY2RBY6rOY0ciH2oBEDJxZa84RjLQPDjQl6gw+nUOZ260+jUzYm5OMU6p1i3RPNnNcviuijZ
# DATA eeMJ2ilraOXjZKTs7uYl3fZmkMaFMNMq7TYFthiBNxt3YhU05nesxqrFqphGOy9Jl0drLcjRmfv6lTsPMDRR16IjLt5wLTf1Cxm3
# DATA lWJaRr6CDZwwoR4YQKBusIxTZBX9KQvUS3AptHw9GfP1VPc2xGKhNaXU5oDY8qwnGecJZSuKcwRtfEpKDONacwj5yF/S4+hETwFR
# DATA E1kv9FTmYRqpVin1cbrfUHYRy+1lSrdqaNTpf2QMKU8bUlCsA95HlIppPizUE5VDMetYlLxfYORceKTTn0G3WOuPKXOl5PGkITfQ
# DATA Ch5YAKjiqS3kqMKZRUHGJRT6pOdGH8uYlRgRZlAxvcqcJUjX5chd1cVLjqhenRuLyY1pMlZsA64ryYTV5KB+ls7GGKGx5Rh6zlTX
# DATA OlHX6v+n4ROBK8AqZHsGk6/xoSpUPbiEB+FhZlHJACSxh6/aexyxI1PHjcGuoWWKMYjYHnK4bsXTdcnm9+NtnySUaW0MhiHXOZo3
# DATA 6IS/Cw+KZ9n2WhWQaVB5vUChobJoF0UJC1tjLjmWkgu71IXHhmyjBOV0AkSGTsOf9AQjE5TTrBsGdIZZKzOmGlPttCmnsoH6nEFy
# DATA yF7feciaKIO9+AJn2ajjDFRnoJ7GQHXm6Mtjjq40M6+5sLK9wL+IMBvk7FRpMfT3tM8DEmwVZaFmj7Bej0JhXVf55edLTfQkoIO1
# DATA lUNwc7xF5s6r1EHPt1R9HC23yatZntvkpY6ahQP+tqy9LB4Tk9bfSeCWkjcejjo6Okp96c7PFk6ZsQefbJ4VQt7Ws/yF0zUHAdMb
# DATA abRW9uvKZuxr5WnOH22MscG2XLxZWWVaHph5HbOxZUsaBicN9rBH9XTBYL7yBmbeHLUcfHP4ivm68PosRs1f1NuWSrFA7DqR8DFS
# DATA Ly5QRCYRmS5hm6xuBfiYa+84/SpNQROA+9U7j4YC/KbcNDRkbm6s5RsqIvJ+ftbCMuCgvo+jZDygFvoBr3sgL7L5B6uZKeKiyCTn
# DATA dMLzhuM0RMXVoDdjLc4jpTnKqvR0dNXkzxj7mD3o8lTMNJlhYCeEzDgZS4JZiuqqVGmvidiDCRmRnen6iN3j9QYvhcV/qKOnLspM
# DATA mi1wL0RV4jxCTh5MWDU7ORjRlI1+ioeQQ9eVdWls7slkbzE2L6FIseMmOyv+rFb8fJVzfmbnZz63Ab9yunB5fmbDE5/ncRis2rXE
# DATA fF0Ff1mv/NIP95+OZd8Or4KTKRMls1T7Wk/gGWfBmH7PumQAvs2TAMz+xkBjY/R/wN0gIpYHGOsbMsaymSbMc4XVKjt+U4771Qxi
# DATA tQ4v0zz+uPpelDqbbey3X8MoXkwZr6Wb1OEbIyaUYb79Vvz6iYhpK5h8HuiLJp61k4olOAVnmlf9FfSPoioXsCeE2itlwvpIm8ct
# DATA 7LS+kvGmT4puddPY8kaOrAMbUsdAfcdcHLE7x0aNT7t5zrh8N7G766VkMellGjuqGzCp72tUMncQk4jXLLRn+vkFVJu1AumAB+Fs
# DATA RPMhLAik0zyj2qS/CzgNm128RmBRhtCzT0BmBkJaepmSdxeX92Oyd+xFMraEoqcdtZrhyXqEOurQU9RMbPAIBWBzmGLDGs86eMYm
# DATA RhSvVShDaRLGit4ElnQ4lp56rjwzB4rqHbNNJLmMtdwjBsmzyEXOil3yaA7HtITDxCts8yAmZlp1k0jwUWrm54ETdYBKRpnByNDO
# DATA VOF9zCh0Mif7RZs1WcDsWRp34OWJEwuZffTfjr86+uPxP4FqffTn498efX/09fHvPLCz6Yd/O/r2+HeL9Ox/Pvrh6C903z8cfX/8
# DATA O7r76I/08L/TvV8e/7bg0acf6Mk/HP1w/BtQtBG0kLS/pL+/PfqWOdpf0CP/SreApP0nj+4Cr/u3FOy3FOzXePro9xStP/GTFMTv
# DATA 6e/vgeU+/sLRta//hJA6sWQYFUGWE0SW5k5xX9WhZgoQ3oCXgXm1/IEaIUJt0xYECcbOKTLjxoNI8cIU7Yp6v4mG2jMbLDNa11K0
# DATA H+Ih6oMih87Ozfey7uGq4dlWiVweMVvVqtSa6fEFrpjp/N3tKMy669fpC1fGdkRj/UWisilcZlfHeiRTWysWJnUvKSt7g0K7cFL2
# DATA vX4CnfoQEHMaU0fafqUMZreTIkpyb0LltrAHXHy+ZLFQJ7UfDW4jrn3eJkX2XWp7qcJUekO9OeU09W+1BZO1pmfFvj4x8g577Yb1
# DATA cw7rGm99utH85fDcXuFIfpED+Ubj+KmG8SsZxaUmmqRnu32faVO5DEC1SaNsD12VPO68lceHy7kgOykpDXsslRFO+5KGHjZC9mXJ
# DATA VlafaXoeCpl20j+c9odZgVl7IUOdGwpZjKF4EyL1+4lnoivgXc1c5tiMEk9azXI4b8m7yz+yQHcqZGJWdJYlLNWrIqB0mozJ2uor
# DATA Cu40bCPD5ICdWA9Zqgwgm/KrE6eiT6GztANnhONLO76040tfIl96oyFlo/nKhobv1djuZzHdL8BydyBpB5J2IGkHknYgaQeSdiBp
# DATA B5J2IGkHknYgaQeSdiBpB5J2IGkHknYgaQeSdiBpB5J2IGkHknYgaQeSdiBpB5J2IGkHkr42IOlapRoGwRlB0r1qr9wLniOQtFlx
# DATA 3ogebecHXKxB0K+XK/vVavlt+v6r+XyMgtYSvFXT85u1flCr7zeBt2rmH+v43UbXn39s6NcCr0KPVstFv+FVqvTBqzaLtZpXpf/T
# DATA b41i06tVPcCz/GK1ydcquD3wqi2v6uNuXC57La/WLFZ8+628EzLPtqp2g7BeXsa2WlI3AsSnse9X5gFt7Xrbb3eWhVJbgPHZlLRq
# DATA Hhks4VoAr3pWfat5knkUBo32Qgwrlfr5Y1jxq1kMg+oFx7DVuoAYNutZDBv1i41htVE5fwyr3CQuqZRr1EjOHcNatXJ5pRz4zfPH
# DATA MCgHl1fKQcu/gBg2mhdcyqcB6ckgpEF6Mp5ZIL1WLfCrrTxIbx6bx1fCeZBer9uKggykVw+DqNE0IL1Oo92lOboB6bXIOq42Lx2k
# DATA x9s/i+us+1J1jk/3ufXQIosu5xLym/lZj84EtrHgsqW8x6bH7WKlG+3t5EKeI/S9FdG4HocFifu887vKrm9Z8mY43/z6vQqZJ2ub
# DATA rqmVtPnO/tyqlXQE4+mNRznL3TgWcMRA+8KxMax4yiWg2jIHNPvhrPCUF2wRz6dqU740UBiWV6KB5ZXl26EWXlFCrMlmtWb5ZKLq
# DATA xmCXMFnFQae1GrqXlXDBLpM1s4jF2qaSa1Uj5exeXzg8FUCtXzmNygrqdPNRBwF0EEAHAXQQQAcBdBBABwF0EEAHAXQQQAcBdBDA
# DATA lwwCiLqgJoq7bJ0WQhz6LEDCd1JgGbbybckPPh22K7Ul7v7Pu/ixiNpymwMR8YhdNbyprxS3X5YLlUKtUKc+Mu7N95Dqtp0d/bi5
# DATA +za/zlTE7VEhBv9tpLu9XfWE1evt3B6tzSUA5PSIlcVPvUdGyae7d57qN0hPRleUnftUdWf0H+h19hxjjKNj2zuf5XLyNh8C1rYi
# DATA Z+jOXKpGu3coQXz8EsYoz9vR/PgcHJJQkpOfCvNHQXOvpCB4O2zO5aehH26p837oKLJauUujLkvIyiljqo/CwHsoh46RhDF1sIy5
# DATA MwmbssUL5N6P1Nt3xPJfXjYnpGSa7O0NcikpxNTOUYskSRzoL/H9I1MECqiY7HKt1LZ/2oHOI5K7U9jL/fQWTSKoYic0ZEWUMaPO
# DATA oRQav4beVn7Nb5ZvVavl23ulPboXxuIvcMNdNuq3cWqhoAKUbei4vKPvjp6OkxEE28LBw3A4fpzkny37i8/eKJXriBAlZERFtL2H
# DATA wPQXuRtKevGIVzZxJ3ugtuVTMt5eFmKDikkK8IFkJgsmAu64jQ83fGY2Jj2vyUXKide//KR5m+virjWRQUkXqmWswAkAEm6UhOva
# DATA 52pOwsr4GsGoq8NnWd2/rarG57oN8BR4iu1GXIR37+0exCOaWJX4VDnXy6fTX/9aXTyI2k/iqf2T9Bb3dqZ9Gqe9+5MJ1245km6N
# DATA 00gfZ5HUg1//GvPBu/coQuFBGNPsj7MP/fQQ4+SSynzKVpSMrUYk/aM0lNuf82zfzhMpI4lz3rxYPL4uokeiwAPpQznF3Y68iKZp
# DATA um1Sv2Omsku6Oj4fFw9oWpfr9FBk5jEZ8nasWFKgqhSWBIk1fnrEBGU9x1n7mrR6CUZ8auZQrdOycVo2y7Rs8getnaiNE7XZVNRm
# DATA pQD5ZYnd3Me6C4+uUJsYRbZsixa+eXYCalehMi6mAF1+jA/eNoojvTmMR7NpdJKOtX7WdE7mgpFcVqrh85LQsjdEaUJX1klY62O+
# DATA FG0+rgvF+EN0WZzfCQtnUOnwAlpfVpq4OCkAuT+fMWY9ycoJ8yObpbxkLXnDU6Ay35nPCO3BybLC3JolnR/059St17/L3/xdfj6b
# DATA 8WDlVO+qbP6uSu5d/GD1VO+qbv6uau5d/GDtVO+qbf6u2oLU+p3gVO8KNn9XkHsXP1g/1bvqm7+rnnsXP9g41bsam7+rsaD/fqdp
# DATA 3qX1VUwbXqmubk9fXwAxdT1UCNJFKxFZow31fU8ErYSjMzSVkw5MRkjMHoBN5kn6EFJLk1yXJyH4Ba9a8AIejhqgaEUjFlL1sIOA
# DATA gxag8NCQwKyI0UC13H/qoX9lmIEl+2W87ZmqFA1TmDdoRTAMgghTrMbT64FtIGX+/IsJOWirmzqtnzq5mdKLOVM6LYj1mcuC8uau
# DATA bJ/XZSA8LfnNC+Z22uKlS2GdK3GyrCHIJw9NSxUuCmTG12Blr4E46nMiFrihvLmX7RzUxpV4LfV8WU7sUO7QZBoqmlBJMobWXaXQ
# DATA Gk5Y5AqOUTKG8DSZVWRfMf+U115ErHUs03je2gUdRszTeVdTAQ+ogsqUG3lCT4UUD+gd+9iJKFSgPbDJWH6SXs6MHOjyaTH00+ci
# DATA zD7WjJzTjr1KyfRnYynlqqUzlpyxtMxYynVVzs380ruZVxpZz15TXdd8qs4hy0ofwgMwovt4M1KmsT6eoGlCBniuke3NaH7MruZJ
# DATA pDSwF+S9qbkYBXBLGTxRU3yuQ3OO5ZzVsCiibu6jcVU3Yx6RqHSNvjKGzaTX88L9JO7y6ucoiVN2iU+0prZ0Bxl4PEuYVnQreY9o
# DATA iPZ6FJqIqKe8TipHiTH4DiQuKe9fRCCHRgucepZZO6VGP5uK4cYycmB+dzURDjEuee8pnW1vGHcmybjPDhiFj4vCDrvl8TzlAHSr
# DATA 0X0t98Rn7p6QbY2RUoPXmfIomooZkWbSz4MEG1mmoPnKBrxxyFBDq9vTAL2SdxeZSUHH47ECbyMIdsnd9rCwjauM3g7lLrvMPZyR
# DATA QF88Qu5o9Lukm1PlHdDbeGV8TfLeD2HXCLd4LzGq87jK5haVBMxiKWCNnadSl0o+TYbJZJIcKH1vqf68Sq6Lhqu+J5k4wr7OZNaB
# DATA Bgxj0MV3lR3izdImDHcDTaeiwsCnKMvr0vMmy/OzZwwLPAuAnAFZdDwFiWAtigWqFOETDFJTHsL6ZDLYhiW1SUwa2NRLxTSk23s4
# DATA oY6mYMZBqQ7AIQomAC96EjF8HjWPsnEohcTkabIs91CVByDRU2RmIwzMWFNKxul8IsWeOokU9LrUc165QnwkRyUXZvMeYUSbB5vc
# DATA Rlqr1y1qxzGGuZVe5XVO5PxCiSmFNZmX+ZX5led8rS+vpV+kWZnGd7Gv4eUSaTQZC0uYBdyILvZtvGDykEvWVNYpOh2rE0ZLudi3
# DATA 8tIJ9n2vbpj5F96cDc7pi39xZz8Z4pLe1k2SSWrzLf/l6IfjvwOQ8vifmDv5JRMuvzj+3dH/C6Lk0bdH3ywCLv+FCZbAU37hHX2H
# DATA fxhm+d3Rt8d/5zH68ovjf6A/XwnhUgVML2Ks5fcU+DdHf9H0SgZj0m3fgXL5zfE/0m9/cgjL6z9veyQzrUkCI4lNYSwaJbO9/pQZ
# DATA OSIzrYbXQTyFuoacIjYTsdlI2y5kSmHUCxneKgM+WzCpzNyAQYFZGPIZ1LX8yke844L6wnjgfUIWIxtRjmSZzeF0L3DVGMulBXN5
# DATA QEuul6k1f9TVVJBH+ZtRWc2tD1TNxfB2kTRLMlZZSEGtYcpeE2oSY0ey3KC0LhxkeVdtrRpQ8zgsHoSDJxmpicxq8HaA/1HJgq3b
# DATA CXHciEbZCeTZFF4n7GKEMNCoURSRkY8FeKqXhzw3UBQknJ8fL5AsT6h5q82SZc3pWREtT0iE41m6Mf48Y7yGWZ51aH8pXLNXNqxf
# DATA zqi+0aB+mjH9CoZ0qZdLcsAM6M+w/VwG4XJJUj2ah9InZs+FaplUkotYFnidM0S2xx2Ms0gxJ3dZlHnjs3p4kggoUPqmNtbNOb4h
# DATA x22UQ+1tArfMOboRJZUMo/3J7m5s9fMOaI6NNWBRPkiFCuj9PM1MKBn5yXLDLu8exSyGISBownjEa0uGdglrJ5YXKM8wCo0Xsu5a
# DATA aEjlW+1GNEYOYzIbDvoRxyL02DThDXa9yNEuHe3S0S4vkXa5yRCz0ZRmI5v4qs37s1j35zbuHfLSIS8d8tIhLx3y0iEvHfLSIS8d
# DATA 8tIhLx3y0iEvHfLSIS8d8tIhLx3y0iEvHfLSIS8d8tIhLx3y0iEvHfLSIS8d8tIhL68N8rJSq4VB/azIy2bUaveeI+TlkpXn08Iv
# DATA axWvVq97lG+eXy0P/HLg+Y3yu7VG02s0B5Vmxas257iWdG97EYc59FtVr0IZHfjFJv3d8lr1Yi0o+n6xQuEHv3qv5lPYzWBQrxb9
# DATA csNrNjy/0igGdEutWKXXt4qVoFhtzJVJEDXa3UU+YJWi3fjUD8rFoOxVmr5XntaqTa+832i+Xavmw6h3mt1GZTGMZs0LauVPi5Vy
# DATA o9ikSFVqRZ/ygmIUIKbFZuMEsqaJ3AJHz2/K6zrxBLOlDhd/nSPhdbhofam5EwEV5uLbDZq1Wu0MtDyuv5qWJ03BouW160FU9Teg
# DATA 5dW7UY6WFzW6Qaud0fKCXh22taHlVdu1ZiWj5TUbNd+PLp2Wx9W+uN4wYO/+nG+aigpnLz+3AtC2QY6dJolexLmpfF30/+EPtfDb
# DATA J60hLDd2VsHfrFieTOGzIXvy4Okge7VFyF4WzCkge9oBuTKP7JxWGaowdqr+2R6jCttpbAyYQWzFNgI9dqsFrvJq9l2WrwU7q9aY
# DATA EyfkhCHaOficg885+JyDzzn4nIPPOficg885+JyDzzn4nIPPvUTwOU4bTiMUtc1DaXxt3YDGCCLJIZYbWtqfeoY+ht5gsHtne7DA
# DATA d1Ip3tEd2WsUzNOPZFrzSw8fdm4M8pWMa/5O6ZMkHlEAH9J/4EPdNublh1v62HkWl9L0KfL1w603Fk6kqwBu4LMmRd0zOxR0qBr8
# DATA pNlKTiHcHaxec7DaHah+SQ5Un1Yv/NketGa/ZOZKW8QRDXJamHtJ0sXZYo/9hOaYLZMkEMgane1nfT77eTijyH9fsFb7soPkF63a
# DATA vvxc/lL99g2OyWd+WqMfHolAHUpby06qymE0Zh5HFIU0GUYQguGjtVLV+AS8cr8xkUV0A/Pny7OT4wXIIJOtmTV2njNCzxQe4KTX
# DATA g2NaH2gW3UMELlWNXzF/+Pw0IuIL1UQO5IaZdfJsxGqexWlW87wzqJxBtUSNLqtQTrDGCdac1Y5aaa9djpAN9+m6GZAlJdoVrIHR
# DATA T6bJ3iQc9y1R8Wemm3YBAEsal99QMjTW6HVKzWIxBhDIBQoWq7FfD+bDcMyZY435y5RvL0S1+AOW95a+kWojFFLQ812CcPGbsNX5
# DATA RSMvekr56KWjC5cPZtHid0bpbBBORb38UCXvAAkdUyfe86i/GwwuQ7Z4xppKU82dmbEG+FxruNj3BqI8DYnvrici9Hqco+HvYt/F
# DATA 9McH0SRlKSasVDHfXmRhmG1UDGMy4GdjapDRBatRN7JOdM6CpuIMwYMVBogY3BcsET3HmsymZRJk3jFJD2mtIG94aMwP6W0MjjID
# DATA QNqK6mY5KFOUx+TArj+qCR1m6lMyoMmJo3SFtFQHgEWtK2XpUkEViMWlvEcQ+I5GHoNXRh0qKC0/1VPUA8r7glHISlTvrCVNsfB0
# DATA qLWSeEY0mbXbEMnncmEmMapJMmB8sYwDonE0mUHIy9OZZnS8lHszkheYxe5Q6aZuhnp8caYflkHhJiBuArIwAclbmG4K4qYg+SnI
# DATA yonFs9bSVLwOZlr0wzHDhkPMMGxx7DRSuntaCnJOLJJRO1odUqGPIpnMWDqPU1sAEmPl4AD8pJngQuYlHqXFzqgpU99FpbAfLVF6
# DATA 3FRtk1M7vvMmL21m8W4fZrMj5i63Z/Gga7T4VGTY0bjoNlaHRy0AvUZvy2o/A6vwSVlYygLSP2bwbHOFVQT6zIrhnk0WZ2X3Cg3d
# DATA VlLyEHD1XrOFAFap+vyqbIxQL7fuMD2r/dSrCfewmeGHNXiMsdRs1H1sWybKkTt/O01Q1WGGt/jT6js7g3jY5ojiw+r7qGNOsCmL
# DATA 7rwvH7N7b0ra7sxhyrWtKavxtqmJEWWNoZkrXWwGlmavzkhnlnM46ZrpKW9+kImqysd8PsyBuXgntekOZGeBTGxnfHvNezI0yZiP
# DATA t8lUKEdW7zyMmdXUjRgmRK21Kl6CYZJOB4cKfomfYCUaKXZeqxFeVzyayhAYiRwmdkmm/UTpiYYCPdfisQwUHxmpWWq5PC3W7m0l
# DATA henBMlPWoTqodbUZWD9FBn5Ac+IB++7jSYemi1kWYo5KHQNQXHZHp2Y58JRQt/CJ2qJDPdk9XiVg25j3VsJsHyZtPEK9XyR1mori
# DATA SSqLZooCxmVxEdlltZJT5ldrbX6ZJicZ9jNIflK72ItMVsGbwPfk88gguCQjS94HNGYWPFbJi8kIO1T+JwURo+5cKHGyW0XcYZoz
# DATA T8MGY9yi7kVklel4TplRjbUZpXoxyaa34ccRcz4eWbWKX00V4oBimbIjJpwM1Oqp9s3AiYBtcCG0amWli6fZ+Bnev73DzF8YYQkQ
# DATA e/KFnAvgGPd53A4hqcvoCr7pmbbJ4BRt8l2A6NCnUbsrUqKLArkytc2+TM1NqHUqI62VtyhMD7G4p4lw9AjZ/CI9zPkptkgKjJc1
# DATA I3+WFcyvbF7D3k2oiGmMHESH7CbI6tiAfsksHOXdFYcfzW6pCbInLjPWkCHUw7PDSi+iqkVRsbagDowTOYmqo2StiAsKNMJJ3Fma
# DATA b/mBWPbW2QOxuSLZcOf9RO+C08rTbIKp3WlwiqiSVJRond+lkxhiL4oDImOJjaMp0Lw2Suz/EpCYd/THo689xnqB/vWX4/989PXR
# DATA X46+XcSI/d9H3xx9Vzz6MwBgx78BgOzfgQs7/pKu/9vR9/T37+nvH47+cPSDd/yVhI6gvwV07OujPx//9ui746/o39/hTWCR0Zsp
# DATA jK8phK81mOwvR187mthzQIEeycoP9vF0lEp9RoEeR8mY+Y0MWOehndqeGIjdBMrn7G3EQGO5pJUYLt+FPjoTVuc3UA8Si4Q8O4/X
# DATA UsXegrnE7PbRocOJ2T4U1RFcNU0sXyCXixGLR9Ya7n1dS/Uviyyx0RSHAE0fi68y0kWTi+SJhVNBFPTDlIZTWLBk6Sa9nsOJbVpq
# DATA F84UuxcOOlh1jGQB7DADVIdD3mnPSyADXifxephKeMyFY7k/s8oBku5wGPHkF2MJryPGv4qYvuF142i6BCN2YqVbbZ3k2tKzY4id
# DATA mALHEXOj+0WM7pondupB/aVYFLmqAf2Cx/ONF0NONZpf0WAuNdLOg2y71bNvOpeBErPTKo5htYOjn9BzWHzIJxQpMLHUhYVFojVJ
# DATA fwcM9sE4FaoSJ20apk/UXhVEIB7h5BiO8aks2QwlBoCRDNX74HUpWFM3IztJtZFhvaNtAsCnEmy0g02Ata2YDIQldsEMugvxdJk9
# DATA oKwBBh/BDsDqVfqEAjPxiOEc59pE9WuAXdrYQzabTmIps2TUiSaj1HHEHEfMccQumSO20Uiz4QmMDY3jKzPyz+Z7vAAT39HEHE3M
# DATA 0cQcTczRxBxNzNHEHE3M0cQcTczRxBxNzNHEHE3M0cQcTczRxBxNzNHEHE3M0cQcTczRxBxNzNHEHE3M0cQcTez60MQ6QWWRdLUp
# DATA TazXq0XN54gmZi87nxYj5gdVr9pqfFqslos+5U+jWvSD+qBYA1bL/9T3q8XA82sVzy9XvEal2PBwF+7wm8CA5bOu22u1Gr0FwhgA
# DATA X7Vyy6vQO2oNr9YqtuhCxWvWEWTgBcB4eT7CbuF11VY+2KDe7DZ7S8Bc1bIF5qq0AgPm8sv5+tCuNWrRkgCCmhVA1SJ7NRerRG0Z
# DATA GazSOO3zVr5Uqw2vSvlQCbxmkf7y/WGl5lMeecjcMmfx6oTYpUh31oKgHzSac6Qz88AC6ax+Bk4ZtwzDKeNGZnHKqB41GuEGnLKw
# DATA V81xynqVbqNTtzhlrXqvkXHKus1OrV3LOGWVZr1ab1w6p2wcTU+klGF80fdtgPmyHGVVdpOVmrw8hiFtZ5EEZkLWmLPcTLcW/MQL
# DATA 6E8lYKdjDs0lOSohqAhv5lRTqTKOtYqZ7s69vVJjXyC78eZsG/E8rUF46XQVcvFbM4TnbtMuMIfscsguh+xyyC6H7HLILofscsgu
# DATA h+xyyC6H7HLIrpcM2aUsDovD1Q0P0933wmm/1BskNLGB2ffhFg5jUep/CpPmprrG56NwUb7SNAuGKrUatj4/3Lo7pgneU7goo8Eh
# DATA 5cYNBH2DcqU3E7kwPh7Ws3Su1FkrXkUCKQtILX2YK1SHs6BBhiDl2E3Ih7RxQMWcwRK9P0fZcseOT3vs2B03flGPG58Fr3UNjiGz
# DATA +077u9ZTtkTAysR76VHlJXyt63J4+bk6w3cZwK38cesLJm3NVYazIrYsR2p2iFzldIYFgTyjCMgr1RXOrn71zps8wWddOa1Dx9UH
# DATA QqEjpTcnB2FN9TkI6Yl2coDTztHebAD5Pi07N4ScaNKDGn53NuEKGk6GWvpenYnnd+sI3CXbOibjl7fN6ihoShhlTw+LpG3W4pzC
# DATA T+Tx5hSxTLDUOuC0Qc+O2wJOVLYjvLhLNtls0jbCky/JUU8rDGdXObtqjVibXbmcrovTdTmtQbUGt3U5ei9/M0oO0P2L4kA73BON
# DATA NUhuqIHNv3o5sQuga/EKhNoBoq/ltOF5ok9Xfz6C3kKkZFiMW8zbfrK3M0cCGvE6UAbaUUGYbkp/z+GQKNHUJUNPZhizvG25hD6b
# DATA ehbZkiPGEfZyZj+ukLMXPwSAPrZgyxhbXGmw3z4xvvr5rF/VFzIIV7O8LM52jLFdx47ymgizp4QpTXBXZzo2yKgT4qoeNVHV33O4
# DATA sLXx9NfEco6gpNaX0FqV00XUyLmqW5QkVKo7r8peUxVPtcZoa/lml6R3ifclBTT+KmbrTQnifBQoi9lktW9b+Ejp0yvES4hmb/QB
# DATA 78P1ZDdgbtCslRI9jUXFhYc79DjaBfXpjHohaJWns729iD3QAEbwyoTqIJIJMBaAKrGqNEZhDnQEQMVA07iEgca+cdXuIKBCpvyM
# DATA /fFUNNCDgUJwuGcYsVCggnGaykjejXssnTIV/SFWdvbUVt7IxEfk6CFNxNFYok6USRKxrDI8jYiMF46pzmGA25Tt9IIYu7kRzJm7
# DATA ztxdae4umDbO4nUW72oT9pooHN5j9T1oFvcwyMQjljFbznfSfNlMCnASDWNGdBRWqe69KUzBheGGhc32ZnEXOMNsYKTQqL12ZwAQ
# DATA 8vA2bwLnoQkLAofmPhrXDdNU+554qP85cwIwnk0SGjrCqR5z2Q4fUgOfwYRSdkC4N4k0vnJxyFT6hxRSl4Zqkxy4qhYGTpYGhLgM
# DATA e44i1oTzwikqNEX4tk1t12TI6Clvj8I7YkANKNdXzAhE4i3Z5/1NisGp+bljzfDCRk4BhTyNJp0Y+x1zEFTJcC4YFu2zhAqVl6zk
# DATA vQXOFnej7E1jaFcfNhffxQATECvhrns3mnI/y8mAaRNO5/xtOLhmIuvx4QawT9al8a6WozT9vU7kB5i1afaO6vuhMlkQzT0NJsIj
# DATA WH+kgh6kBaZjpIbaqY0uMZPeR2DoKQ9hgqmNljyyTHhIasPSjrpxJ5QSVPhMZOVCTbcwZ9FTGvMGh+tS+T4fKTbmF+NLdDrv8k5P
# DATA dUhkNinAk8wK40Nd/Dx9VKScGPATZb6OoMSnxD8tRhonKa9UWfIeRdETpoTALcs8D+Ql36qqhVaszPFl2H8q3BCoLcJBrB3FYcqT
# DATA 2nBvlKRxukDmYEPsJJ3vxwl1TJyfWRfErebUpGj2aesx6EI40ZabWzUGuLfZiX0JZOj3UH31PhhqriGqrui/62nKJVCi7+Wc5Wiz
# DATA VN5Cl70EUvS78ZRnZRPqtiAEKVBIxazhnlMEJi8BFv1gIO9EB8mpzRoXT7O6lwCKvksdkG7x6KW6Rl+XixTeokn3gtnJL/r8zeLi
# DATA 0FPT1Mbi/FdAcI6+P/r6+DdH3x//09E33vEXQNTQ12/o8rfHv1sk4/wLo27+laE2+buP/sSUHI9++vLo90ffHP+jCuW/gItD1344
# DATA /js8Qa/6Hf3yF3rhn7zjv8+RdiyYjkPjPAdkYQazGe1aYWTB8wukR0G2oQoXuMfd1gGg3AfKotqLWDH4CRzOghOealYiQ0Z5EAVD
# DATA cG+wnoDzbhT2+C0Of5ObY3J7v2r6jVUYl4e+kaRl3SLXnR7Pw+ZvxchhbuSp3qR/OO0PLxJ3w5tsadrTR43v8owAyD3eionbHfbm
# DATA xBK7cN4NJrlJG3NMrmfaY42dImo6zP3LIJwM1dJUNvmMU3FFL+yhFv10tm1lLkGlRb0YpnVkusDBvYC/WV//VhsfWTt6Vtib9TF3
# DATA xBs3aJ9i0NZgm9ON1S+HL/hqxumLHKY3GqU3H6Qvf4yW6mcSbQbkq2sLl0GqMekRQnI6nxC9/yLbxMD2RD8ZahiMVSYy06UBDYNd
# DATA 2OWEMgXdEClSxVjuJLOJsCmy8VUnXI6y00uQVxz8ZtwaNcXPjcGhca7r0duM2ynd2J0NIr0lkpew4FX00nHUiaO0YOKfsYuVo3UQ
# DATA i+s1os427EXTw5wrUKWDcbqMiWYUcEcSlU+QA9Q4QI0D1Fw8oObkgWOjOccm9uvV2N9nMb/Pa307GI2D0TgYjYPROBiNg9E4GI2D
# DATA 0TgYjYPROBiNg9E4GI2D0TgYjYPROBiNg9E4GI2D0TgYjYPROBiNg9E4GI2D0TgYjYPRXB8YTbUWVbtnhdH4veC5gtGY5ebTkmiq
# DATA laZXrZX7jJ+p1Dy/Vn27GlTy2dHpNcvBIv+kRgmo1hq/8CvVef5JLejUmsv4J1xK+WCqrZZXqVX+o9+qeJVKmf40vJb/qR80vabn
# DATA NyqeH/j0rqpXaVU/rfj1ol+lMgQxp1b063RLkb7RTTW6yacHav+x0qJHK16VQqg2P/XhRa55NbqnWs+lqxY1W/XyIiBGIlQkE77o
# DATA +82hX6N8wYvqZeB55tLaaXVbYWdZWhV6hkoxJvNDsWtq5SBj19RaZasC1+TL4ZLa3O1E9U7vDOwYrsiGHcNtwmLH1CqNMKieyI5p
# DATA 97q9eo4dQ/FpdtoWO6Zab3FAwo6hTqIVRhY7Jgja1dqls2MG1ApOhMfAafR5dquhvFgcF5W6RcceO/cq9G/zJ7a53WDzIQvyZCSN
# DATA zZvhzXayt3hZLIzrqrRk/ZQsLA9LlV5d/uRC85RFY4AyPIqa3j9HrpEinksxhQnLyAvkj3GNSrKbMK5sf45vrfGoIBqUYT79Uf9q
# DATA C5OtVx4QV9JqNijLfNbl59hLM2JlQA5q46A2DmrjoDYOauOgNg5q46A2DmrjoDYOauOgNi8Z1EYbhFraZ2vntXWjGcNvdK/Ppy7U
# DATA YwX0gUu7Vk+lzKpUu3di3Xvtskm8cxvt/MOte5maFw6rWHIuI8phpemC6WueWWNOPrhzw+7csHXyxZ0edqeHTzo9vFJr8lJOFb+O
# DATA mguluSxwc7L4mepPXIBeOrTm8OaDKHrCJxylzZ5Ray4bWy5ObS6KBkqVuy2rJJQhWn1QObovQXZOnzdW4LYxlWp3Au05j+ZI0eDw
# DATA EjTn3hnhUPNUethUKWXDXu5lAtWXID73mF1fKo1kgqjenOoEjR1FqF93L0F37qEcJYYPkEw5lWQDF7iUcmXtufdx1jo0AnRoeTLC
# DATA wWQh8xJ7oWaT6ILV55QHxkjHZ5qMOWWA7HCrTog5NUsZhi5gmutBLIn6TBReJOAhoTp3WJ97o1KmrtmdHOqMzlAN4eAA3MJhxBLy
# DATA uAULVWRoDAYl7924Z5pDAbiHwWJbVCqqI0Rl4vXpx0mEBavBoTzJ3ctBmEp0NFFIqdVyHRSVdzQ2eHNFu5omFVhi31cBUOugaEp9
# DATA 6cM3OFEn4qGTSY/2aEhZJRmgc0Uf96ducoST77zNgMYTlgKgkXpe4mdupHoY4TigOsUtk1a5Q8adk2Xjn/OTxw456ez3zH53FvsL
# DATA Z7GfFin5DHWAeDHfLESv50i+GbP8uYKjQPR85PFe3jUQySuWD7r2chqXwYfMRI4uGg5py0GdlQxpbVLQ06aHOFZlqoNM/Fg4RQlP
# DATA VeYKErsapBTV7kYQG1+fyMOgAWALnYY23vUGs2E8SmY0RTQ20YgqeQIRm3E0GEDaHWNoXymuk/01Knk/a4vcPhkm2HQNLaU+maQK
# DATA c8A8G/12OxpvwUDjuzgxOhbvwy6iICh2VHmp1lhmF5t8fH4k4m0Ihym01MOUJdSlhWiN5yEkrCfr3s9uaC/37rekBaVkXqa8FF3y
# DATA 3kvSqbb/RFyI2T861reRQdK+wF6C8g3117ANIGxP3QhVdZYNmY/Jiy4SY/UMzlZztpo9Mjhn68vrbF3NnHyWEo7v8WKlrs9KgI2P
# DATA XltQSkjrMRxhH9pt0n4y502B3QgMmGQnmnYclrwHmRggTuGISptB+3AZstMgtPQD2afJvoNe3PFSmu53jGelzVvJMs1A0VzcUAOS
# DATA UyyOj6zxy1ofYjIKJxPNE+LDJXgPvD5LjER1xnGRdqnWuVFJ+ZPykylPlv4xAyKaK5zjwI5EHI48rdxPyWBgpWApAdIsnnM1kc+v
# DATA ypYA9XLrDtNR2k+9mnCHmbnvsPqMEXMw0EujMfyhibLm5m8nu4FbVXKw+p49NnsYmcWfVt/ZZjuNNbInYqXoO29KqrJ8kPFYewtl
# DATA Bdr282FoWOMqXGszWp7PcNI1Tnhe8Bd3vMpBKwfmQFK8M9i0fllK5yo0mXFO3DUJmI+x5OWYDbZ7EHGMJxAyRb3PzFbYa0WlyVkQ
# DATA idEiZmZag5SGsWHSjdiPP4U9C8NPW3CCUrKdiXBAGqnOiIWGtJE99X5FA27J9q9u6Ev1zDY5tjTySTFZoyXMAHjFcjc3InrGcrrO
# DATA 27KnKp6s8p2yhB6tLiFdjaWQHo3ZB5svIWrG3JGIxx3YF2hl9sn+ETdo6EldV1a/xQ40ayB4XlZBRGo1gfoophwoXexgVFbK+cvG
# DATA TsH1L5gHmxbMg3AyYFHZcDDUBfMo6TGMdUSjGmumHmCSRyPoXn5uVvLu7icxZsaU98atX7Bd31wqY+pfMDnrqlkipofnLg874ldW
# DATA Hlnfe8ry+A+ry0P34lIe/4EMloWObNbpzAasJotFQHWSUDUOPVlVLD3qpXglAeexacgoeW9T6zosUBGSGZLEA1E5HnIvlgyHIv9M
# DATA xsVQWGL0U4wcNOvF5y+oLEXXv5geblpMD2ft9nx/9jqLWKveLBp9khxmPZgW4yp5H8Q03e3OqKPfk6UoI5+sV4UyCw9MbcqrTjgT
# DATA Ot65y8KO9vXvxN7ctBN7PZ50ecfACA4gahwjq/H0RfG6PxvG3SIWClliXJUHjzopG/aQFprCMv8g1FzqbJ3f5u2hhE1vRyGR8aS2
# DATA TUALGe6hc5fTYoLOVFp5+0+2Mdr2n7kieX/n/URvONQa3GLyi8XNS/8MtQxpxoLs0KWsFk4vh4n2XHu8MhZa2k+iHArt/zj61+Ov
# DATA jn5//FuwyoAxo89fHn1z9G9H39Pfv2c82p88hp19e/Tn498ugtH+K2PUvj76Mz37B4/+4gCPvi1QiEd/pG+MPqP//XD0jXmJTVKj
# DATA m/5y9A0+KY7av4GKhvfLe384+vfjf3JUtOcAym22OfCW12R6oLGrhswN8WIhrxZ4ZsTbrCKYeJoFAGgo3AksI0MdgMAZ0IGOQTdQ
# DATA RFeqx5Mp7xnDcz1ZwjJOAXg61pLToCyPpiB2vsOn2b4+7iKump42XyCXh1Cj0SIcJHsZ4ot3GPLL5zncN3tx1k2/GU8tfMfFMdRg
# DATA SqtzG6ihiYzgnA0On3ZyaV04P+09wYB7bTIusKOL5v19GnfM9LKgjaw0wWEoZCQMWSQT3Z3a04r5jSKNP4VKSpR1TqzzVSCbSpYj
# DATA JxF7Fpkwq48JDKmIBK+BwWq6wFZbXy9XGzFzrexZAdbWR98B1tz4f8Hjv4awnWHYfymW965myL/wEX+jAf8U4/3lD/dSEfNJN6P8
# DATA 9Wo+l8FtyyecB0nOEAMdM6luHyKkgpxhnMzkVRLXqQCd0mGIhS+z9OZJv9SOUri0ogmWJjnRNFBnxxZU9Lpxz7DdKNmHniKZbMhs
# DATA myhzjbfV4MgKGRTsl4g6TzA2KTQZ1zHhXvGpYd4JJLS5OOU9VOlUaFy8NBulUzEVkC+Z5XBbUcxAz5rOKIRhOJr18HliGwnK8wo/
# DATA Ads0k8NiMnLINodsc8i2S0S2bTC6bDTR2cQkvkK7/ixm/Xmtegduc+A2B25z4DYHbnPgNgduc+A2B25z4DYHbnPgNgduc+A2B25z
# DATA 4DYHbnPgNgduc+A2B25z4DYHbnPgNgduc+A2B25z4LZrA27zg2qnWj4ruC3o1aPecwRuy685n5beRraqV601P60HxWrda1aLfrUy
# DATA oH8qFa8ZeH6Zfql6foU+1YuV6qDe8oK61yp7lcan1Rpd9aqBV6u87futT4vNYrXhVfxiMJelUatX6bbnoGd+o1av1pZBz1qLJVcp
# DATA e7Vy0A8alf1q/W36mn+BCStPYatQCir1wGv4Rb85LNYaXq3pNcpFv0Ffal6t7tWb9GXjiPnVhZgFPiBxjU+LVSrUIvKi/h4FgNgO
# DATA qnQhR4vjnZz5l0W9Rn0F5k5V4E484RN2T6XSVzL0m99gkByrGtTzLcAESwHAsPHk6TKy1pOHm818te/1+Lvuf1kOlcVfq02qNxTG
# DATA KbFx3Iw0Nk5apIWNi4JmLQjy2Di6qVap57BxcyA5wca1uq0MG1fr1IOgkWHjup1Ou5dh41rdaqscXTo2Du3vZGxcVRsFYhLoZ1bw
# DATA 45DMOf9i8BOvRn+q9Kce/MQOYo4X986QphLTArYCI77e+6zYQV/tmNvTpKBcvj3vzBN3T6G5f1DgVbIVK2IqGoBXjT/bdKmgVLPy
# DATA wqtO8sF4ej9FziAx8yXsqtYuPu3lzDPtVCZV6I8faJOffUXxlCysTg5kp33Y1C9XFvBz5dV8OZP7BTsH1pgiJySQrQTHkXMcOceR
# DATA cxw5x5FzHDnHkXMcOceRcxw5x5FzHLmXjCOnLI58BxCPKPxd2Hsfbkmbo4TfkO9QhOFsYBPzw63H4QQqtPyIJzejed3gC1Qt3sRm
# DATA um1/5wblRmdY+pD+G921Tonf/3n+GB4//F447Zd4hr7N4fzULwUIITvet+TQeKZ8Cyku0+1r1Fx2bMUdonaHqDc5RG0fbXJnqd1Z
# DATA 6jV6yc/2jLUcDS7os75LTlo/NOcCpY4U8spq5lCvHFhVgix8lhh29IHSYZaTvBGr7GeHJ8fhISbTcngSWisj6+TkxhrIb4rqcVsY
# DATA UV0QqPDq0HTo6Aic7vEmusedMJ2FSjYNn1bfiS6Vsha3fiAfV99LHWw3STijfyYfnwcF5CwvTimCeG+1CKLOVRFBJKNsctiFDlE4
# DATA 2g/TTAERJyepeUFBvJOw22Q2HuPcMzYa4DCaNxFZyBR4DjnMzl4wampRyaNWHePo8JyODo+H3clhwYvC9JAbyvl1D+fScGUSlVb9
# DATA uzjFUFOTlU41bIfJDGZkVjadWdqnmhuxSC7OoMsR6lDkqtnMyYwIWJWwSwTDgILqg3uHLiJTplZ6Dnw8fIb6AX9pWzNPzqVOnSXg
# DATA OSiYDzYumIdU1YtwqxxCA9xSDuWDzQUqkXHErYebjW4gDJJBwVF/hIajdUNxjhCKVVAMj8ZsGyLDLTUNERzA2paMb/Ggn8xYevT8
# DATA +q65pFxZKZ25c3t3087tvRg7Z6DhMZtYysg0QaE5H3YFTpOxbjq9eDKEOOls7KmCSSYswca/inrJASVqkrSlu5tE+Mq6YbNRn4wq
# DATA qBvYMh7nKZJczK+sRKxB8pRF8nh1kZjhVsrk8SSMB6KXEpJZYwqFvk9hnMB+SySHuzTtgZGHqmlomJNQNQelWQ2YsFaayZQkMrE3
# DATA EWEZHIra27kLJh/9699WHm3aVj6QOSlNUOMxVWFTMKjdsJxp6i5bhGBY8zDO01GoeoxTHu8xzQePFhtzFTIrFc1wJRI+ZVFrlC48
# DATA p+cuirkYv7xaxy+CnIh+3Hm3nHdrE++WXcWcd8t5tzb2Yq10gl2Od4uFtwwAL/T2kkRE8bRv69rq167zfeFIg2d7wBacWkI3xYYR
# DATA tQ9ZX8t5m9TyDKOZRth/zxNVtVC63RnuKLeXbpgyKUUpSqjmedOVZVeM66fCu2sn6LnRiw1jNpAqvK16GPKWV72RNxrz1uuSv9pB
# DATA xitIqOWJKtexUS3L+8nUjSZm+sEF15SvCL2we7q3PN/rDFf7sfxSwA4ECiyOJnR3Kcjdv+DLUhaWcRTKphsK4r6WL5zrZS0zCeVH
# DATA UeDDRTpVsvvKNl2yS9LEYzHPxjQeTmVD+k0J4pwGkBgpGIys9marWT6eiPtViLHoBxZUoges1zjSXtqCzBjYhmOvSLgXxrLrClvi
# DATA BSNFs4eSZyB3WT0teVxoBR78LCALi1dmQUKvMtXWMV4Ha2ocjwRjhTDJIjYShFhQZAU1HBqDpGP7UJqnCPOFUKC0VxHT2R74tbxT
# DATA IFvDVNPWkZagZL3KTHZyxhbqoWe2C+g9cWO2YTReFln9whue2VDjTE9nem5iejpb88W1NVdah9dQrZpPdJjTBYtm2MAyQ9+C2cmx
# DATA AoV8EskyYaqt0Owhll3izvf6qVtff8lX/lvO6dx5lXrQ+YaljwUiXHOEqykn/Kwzi3IhHPC3eRHu+eN60kw7CSYL8q7DUUfMb6N/
# DATA dednC6f9eAcfFeKCuLn1FH/htGwgLJ4dW9H22Bwc/CA85OkL9JyNYXaPl+xkcjQyi4LwJ+5RSONDWV6UuRNohONwn+cuJe8hL2dN
# DATA tQWl7lH2GWolXMbijGODZ36tK8R6OFlpmtaxUSWYr0z3n44HCDWNn2LruixDSvW+crjHlRtPGaaMKtR+NNibUXdhw8r+5fir498w
# DATA lgwEsW/585+BLmNs2B9AFMMvx18tUsr+V/Pjl0ffHX0LFNm/84U/HH919GdcKnhHfzz6mlFkv8F33MCvO/4H+gMQ2e/pdQCZfUs/
# DATA f80os+8ogO/x2/EXFMx3gJUdf+FRGF/ThX/ARaDRHLvsubAOkTaeesEfwnLluvbeApE0nDzBKl84igpwe9CsdMJzx3Eo0x8MMjRD
# DATA xVFpXkOCXoY3G3FgrE0+iwfMRqUWHfJuTppYhlOBpEbYqk+d2VpqmcCkIxkoHbTMthWtDuOq0WVzpXJ55LJuLOcwU3PnG+oKV9QF
# DATA ehnGPXMnVTqpiZMLhpfxPD9OeQMCmgPvDNNRdQSzzUrtwilmurPpxfxcOBCnUtrpR92ZbBMZCDsekh8McuZezGO1V88PisN4BFs7
# DATA HFDlxj6S29rTy+gMscImEQUsIIV4hC5YzEBlGUmbHBh886ZVc7WJk29qzwpftjbyjl7mLIALswA0t+z0A/9L4SC6ykH/osf8jYb8
# DATA U474lz7gS33MJd6ml12L5nMZ3LJcir1I5uipeKSYwu0lvfy+Pc6GaZ9iucfrJmh0MfZpGsuIEUfDcMwJl9eij5JzA1Q7QV3CUotG
# DATA Jsl+TR5xpd57Rpwt3RBbxjmnKoVH2THD62TABxBE3GUH2jCgIkgRS6+LAz94+ZNRciCnI7pqcymwUeOIi7qfzCZgfzGDKm7HA2QV
# DATA rDsGrdB4xLgpGAuigcB4LnOGQIGcRsly+JTjmDmOmeOYXSLHbMORZqMpzwb28dWZ+Gex8M9p4DuQmQOZOZCZA5k5kJkDmTmQmQOZ
# DATA OZCZA5k5kJkDmTmQmQOZOZCZA5k5kJkDmTmQmQOZOZCZA5k5kJkDmTmQmQOZOZCZA5ldG5BZpVkLGpWzgsx6vbBXfo5AZrkV59Ny
# DATA zOqUJ+Vav15v7ldbtbfr8wiySlTv9BZzsuxTVtb6QbPBn6uAjKnPNcpY/txsej7lcLVWHvrNcpH+VZ99/XkO6kU53+1VlkG9Ks2F
# DATA KFQCikK58qnfKHu+DwSbV/HLUx9u4+ZJ+LBGEDY6S98U1BdwaH4jAJfMq1aKrZrn12uAoPkBZZxfZfJbrXXC6zrVens5rcyCqBUx
# DATA HQgh0C812mstAZlRXDKQGUXKgMwEx5a1gFq116hsnL/1Ja+qlBvZq6q+f4mvqgqRTV5VqTcu8VVBxU5Vs3yJr6ozik6nqnrBGXgq
# DATA qBx3aRoqJ72jBZWrVerVZjcPlZtHyC2FykV+1OgGGVQu6NajZtVA5Tr1TtSxoHJVem+zfulQOdldWJRlBj3MVXkG4enVKWO7NMX8
# DATA s5+Zh8K9FVFnHoeFRfpbbRn9Df7Pxv5BoS7+TxXyMNwM8lZqrHNr6ulZFuj8Aolt3uvyWfBsqpLJhcPiFitcX3/dblIH1s07vU5n
# DATA h3nsrsVS1WownJVVa+y5hTjnp0WXaB06xpxjzDnGnGPMOcacY8w5xpxjzDnGnGPMOcacY8y9ZIw51IV4SjP8SQgtdqpgtw12bvfO
# DATA Z2ZOMk53uZ5IL8Xnl3H1I6vlS8PfvWOafdzb/hE/qhruzmeKS6eViyCGKme+GHE05q5ajMvbn8uruzNZe961A/qp4O5wKUPgMZdO
# DATA lnTse4v+zk/94IYfIDo6tDsSQHtG80UUqokZy82yAu0oiropeHf6GUDyRIYgNdpLvehAOpCxnMoTsS+6xCcYc8lBRuMU46426yd4
# DATA sWSVLD5t84RupySLD9vbYWG/EFMhhDeUob2/89PtmJpG+bV6+Za/Uyhj0xe3eqw/7Q5372wP7+z6tVr5tQ+33qcqyUcsOVRkkDJ8
# DATA OJ96g4TmrMOb9fLOTyq1HZqBdVnPartS+HCrjLv5Mf3M8Cd04+JNt7OaI1mOGrCdcqxV1YHzaJfjt43UM2rwv3/xz8jY9Dau3Nhd
# DATA Vpjb8av5QnzND26VdW5yqLc/3yl9ksQjepbBhRJp9fHGklf24lGc9pUoqh/owsRpWXG4CADx5yOoTAgOAM8z9HB7rsIUda3YsasF
# DATA NR6uRyZbdiiSt7nAqSSKelZBz7+2zmTklofGk4XzGcZBMobUoWOtnKHFLXTImq2oK52Zd1Hg+jx0afoU/YwVRwn7kQ5TP0QDLsIy
# DATA mEZ9EM0pRTiliPVKEdYxRacX4fQiTq0XsVKn9FJ0JB7MplkD4F1bWtNTRnYjKnEdZYyuQsdejBWRcZ+IFTOnXI9LmW69vt90XuaC
# DATA EXovt26pBXMlXL9Cj14NuKxIP8XJcuYhGWHvbTXynqSkb4IxUcquZEr6tfIyKf2qLaXfqJRtLX0/WC2lbxk0iD5HnCYmNKviapWX
# DATA 08/dbOWbHcSCWj7H7E61rO2P1br6NY5nLTj5zjqHWV8S5oL2vj7ASOnmg4h3lFEszCC0HLpVflE5kzGhMGngNOXLTTs+5jMhV07v
# DATA ZeMZD4UyAbljXZ4rkIt57UOMm9zi7bdmVy/npXLw0aOBdkLdRO7N+Z8yvGdWLivpCNKTKUzA84tEeBf+PZG6UcaKtuRt5QyjMdOl
# DATA CZ1l9+c6eTaDIPyRu0UJ8FIVZu0ZSM6wngbDDVjMQTMIVmnQ5EVnbCrYIv9rOSdMMjA3f8BIqFco2LelhyAbAnYi3+D5F7fIWxhu
# DATA XuLmJSfMS3L2p5uauKnJyTOOZypxhzEeFVxHApkzyFTu3jQTEQEesOaTaWtUemHKIlcQnGLNMSNCVRDltGEojksjhKbFGuYnF3Po
# DATA BWyzsbHfwqO1DTDha34gwnOREGbhKkX7psRQhU7NlIYZXZQ96aczRHOPf5ulhzTmjpjpRQmUzqKgIEQyPdIDLQPpubtIn+hAx/1k
# DATA muxNwjEP1eMIhrSS940nLD0mScwPe9OQscrvJRNR1lVj3TzcVBDJluUnqRVzxMKhcUeGvu1AYZCxTVB1bOK7x+rUAVDk0Ie7K/w0
# DATA wUr0QxsvCg85CAMstQbf3rrYx1226tZGft54lBQYpIBAhFNDEIaK/9SAnjssCKfwF1qTOFPWE5ZtXntPFUsbXbbwCaxeO5T6uyZN
# DATA d7HDfpSA3DqfLDET8tzYBVVFU5HJLHwA9756M/KVzLY+CL4K2SBZwD8A2IvIYy25w7JtMGoKqEQjSQqYd/DeJrNU5YcKOKZ8uLuf
# DATA xF2WpGaVNgAUJEtpgEqYGDuE1NqYT7rx7pTlU3qO9d8ITUQ5wGVSpuOMBfWccHXSk1kYdOiGw6QrjRuFx5dNWXn68FzS68GnrstO
# DATA a1hLGRa88axNFor1HOvPcSMMu7CAvAnXYamsNHYxvJhf6YHEToMOWdoptcl1SXwENLiCe00xiFhJBKFMXkg9QwxtL+ruKK1jer43
# DATA GwwOFW9FxZTdOClXVEn3MEcqZGVB6RMO+olSR6QOEjtBqYgnfbRDKTD08fOIWjFMXzx72tHCnC29sRq0M51faNP5tKywZ6wObe/5
# DATA Xw8Le4yRQMMu2aiS+r6eFnZ91KSfC0nVkwgS2b5/zfK6SKhYXiH7opli84rjS5Fiyv3Gat4oVN6FRkaQ1IhUzJpkYLtDo7HuxO68
# DATA z9olwhWjqQrrE8ukid5Hv+OeN+PMckbvAcnsEexyoZFRvcnulZkJbFrZnZ7AwoshRXaobrqZDFY1T7GXYeei+vLUIlzmYFyLCYEr
# DATA 1pCcF/THYYGxDPF4ghqdRqaZiYJzaKarss2GDPsh7iI7N+dtJZsbosW2Fjpb2jyFlJyasSi5NnAX1tkWbL0XzcrLsGYHUVuJX9tU
# DATA s//l6Jujfy0e/93RD0wZ+/bo+6M/MF2MPh3/7fEXR1/bhLHjr3BlEXD2f+Ly0e/p4W8YUfaNR1++povf0uXvQSY7+r3H9/yRGWf/
# DATA KPcd/06BzL4GSY1e8BX9+zsFMuP4fI04Hf89GGjMO/vD0Q/0A93/J8c2e15sWWnkaHhafJ2XrAx5E+tANIcTdXGevCUU3BStHnGk
# DATA Vv5zqCwyQ168R8k+e3nCSeZVskiIaB5rUWZvz0fD4cxsmzbrKK6aZrakYC6PaCY+lXTh5er6/O2yg8Dc/TBKaQTqyIDNhXTBaDNx
# DATA L4meP1wrsvDH1AIHNtuo8C6ca3bXs/TOs5mBqQG8aAwhndmAKRztQ/yN0xTKPQfqiURQ7Jx7D35O94umeUFzKvR+FwMxYftnH/Bi
# DATA jy4OFnhmG9bM1TbOYrN7VnSzDZPiOGfOGjirNaCxZmczAl4Kp9YVGgCXMf5vNPyfbvS/wsFf6udCTlios2fSgi6DbLaQSKabUVal
# DATA i9EC40yWlT2qnqiptwT0VPDefvz4waOCOliqVoa5ZHjP6ITsB17Z4WRghIZTIqMpTVRZas+DzlM95m6KNzNVwaO8hjJY3gBAyuIO
# DATA MGeZEZAHnI0nURe+kbxRYBsDBW6m6Cw8GBijjjIP2CoAh0rMQ0FOcfxTek1GN2OnSnqY8lFKdU/b8c0c38zxzS6Vb7bZWLPRxOdU
# DATA BvLVWvxnMfgvzN532DOHPXPYM4c9c9gzhz1z2DOHPXPYM4c9c9gzhz1z2DOHPXPYM4c9c9gzhz1z2DOHPXPYM4c9c9gzhz1z2DOH
# DATA PXPYM4c9uz7Ys1atVa+fFXtW7TV67ecIe7aw/rwR+owzV2UeU8KEtlWr5A6L+fVKPterwnKSbG/mMq7bjIKoN4dvqjaDQFBd8/im
# DATA mmSxFQ95t8RD2FdZPKrzh9YqWTRq89i6ZbywusUL81tNw6DKEdL+utZt+o3qYs1p1qjqNPtS56zkhfV2qxMu5aetS15FSGmXlLyK
# DATA RfPaOHn00IUlryqMr0tKXlU9fark0UPnSl61UrkWjaRabV5eI6nW/XM0kmqzfO5GYifvwhtJLnmnbiRI3nkbiZ28C28kueSdupEg
# DATA eedtJIHfvBaNJKjWLq+RUCzO0UiCRv3cjcRO3oU3klzyTt1IkLzzNhI7eRfeSHLJO3UjQfLO1khsYGu56dWCYL9W71dbtf1irT4s
# DATA +q26V6vvV08CqK5uBGehYbKla2iYbDRbNMxqu15pBmehYZajsOdbNMxqPWrWDA2z3el0ux2LhukH8vPl0jDVZl6Z3VnOHrXsZviY
# DATA PGEnE912qrV4jX3JtolcqJi/Lt4zv1VhccmsyUtmpSa2ysiiWS5UtWC+NuQ6r57lH9OzwOWbDbO7aTa5NwmHuTW6k5KrnlmyPL94
# DATA g16pX8jzxbszL+KqHZLyIl+KSFwBC4FgqWER9amqXX65oNVqwQNzOngne4yWpIrdhgu+58XtQiu5n47W6WidjtbpaJ2O1ulonY7W
# DATA 6WidjtbpaJ2O1ulonY7WeQG0zkU0517cVgBFrM7B9FRwTM2gois3/XKtGTTqt3NzFvUYHx7GYxpxSIb5bIwrN3w8WandVmzM++oY
# DATA O/QDRtP+4NBwrhiRSDGhevUm9vdvVxiL+Fb8uiAV38U5czmlPB7MUg+CzZ56ET+rorTq+bteJfiJeVsmtCPzUsqD/YhRndsUh59i
# DATA jX9nWUg2y9A6Z+oEYZwgTE4QZvHQsVOHceowZ1eHWamkfJmqMbqzhhyEtBcUFys5YKMN77yxJGSuj47ZVQANZahk0IcMZKzCwVdP
# DATA AAnqJ3PdfJpDtsGNsBQk6FscQb6prO80OMHVNEEznIMlqD4jbBYsGWNQ1Enwtv8mfv0kIKIVnEmKfc2kJjg5LZVTJEOsDfQA8IqK
# DATA SbD93snx1c+ZyJoLVkw3y/QNY6rtIG6nEEqE5Ehmt1DXNY6jk6pLFkgGnswumag3Top5fU2sV0L+TBegp0w8HqpCfu6hf8tIf8ZC
# DATA jEzvh56J6piwPLh5dI28DmwDLtJwyHMAXp5hQRg11+zQpIrVohlqgr2RNL0peAd9qnxkHE72Iis0lbu9HvW17dkEvg08R5OrSQSF
# DATA pniqBX6Uv1pmHinLcrMSE1WpQzGQWQfTrmcl714yZLcYdX0FJdYz6hr9p0x0SU3muvJEOFG6SJktk0FmhxSv2YR9q0p8aANq4Ium
# DATA FOOYJ24isGIi4Gz+l8LmPy3p5LooRdo7JdYjT96KecQUtURej4ZI3IhVe6htDaO17JNnJy/5fKmrnaQuPbfH4zLAJ4sCmhcNP1mm
# DATA Q7oUgJIrO70lRiryMsDfm7DntYmw9A5W9Vx7x+tiWhtD45Ry34r8x7jKmAUHARIRjc9wKmWuzM1NcJiPsmm3xiu+/fi9dwvevUeP
# DATA CmoclvbCw4LScgfEUuZFIrQ4hkpoqJVUWamRSsHIfsZpNm/QYDtu4PEUw/YaouIj6Qxkw9t6WORdKxKqEusU3YUS6EjJo3LsOEGU
# DATA sG4Eml806kARdBRR/JQea4FqL1XXvl5mE3nWvCrrWjRnvgM5IepacFasaR1tBVNkg1sdMIzEnyEwUpj9on3PBvTkUEliqliWvAea
# DATA U4OY8+qY7shCrxfGg9lkHc3yoQSDhatVPMuXyAK3+2tngzsbfKkNriqJ88Q7T3zOultpvF8f/Xau0xipM5xz6Imn0HjgxVcTp9i4
# DATA l/AgmRcf1y70efrZbAycYMn7BfaIHxpEC93RnXUgIjPEWGykjY2/nYnGbO9sLOSe6RZI88TXO69qw+8Rjnlzw4Z+RaoA2DLjUH3B
# DATA qzeNlTiV3ns6wUcR5sarOuKsJ3tjktAYTA27v/SGn8uY3gO1ecUtH8BkQypFi5vFpnHrTbzzpn6/DEbz0VCGqjLgjMXDb+reeUNt
# DATA TuQaXPAwrPSo70+ozBj7SVVt2uU71RhR8GQwLmipbXDugClO+xJuV0VrRTzeC0dUp7q2LWgiczeTwJ/7XaJgm27G/qISnUQQ7+bF
# DATA A215nRyRX8ST6QyK6iwlbsVBFTCbeVxbWVKe+5RJMjCR+dmYFVXMDVTJoymrpI958KQMGgx0VU+t+NxUBXVTVboVXPr12O9H2s7L
# DATA 8l5MvrA7pEFfz3Iyto9WElek9rSfzAZdbpdizo5g+WHjOaZWoq4uBVzy2L4kC3iQHA45CLLPwbMOIQ5vydCDRf9J0uaBU0nMz0bM
# DATA QlQhrQOCj5IDpVeuTedw2tfR/2DCcvZU7z0WNxFnN6+3aL8xO53JGqdgQu1tRi9FnR3fgx+YkZrZuEBCAbKob+eJEUj1IzjYaTiP
# DATA RvrermI9ZmuD6xLznriiVXpCEc+HX92495VnHRHT6xkZV6EfDcaqP5MFT6svYhl8GiiTHFRhHIVPUMLSY6LuYc2yGw3xAnuGpcAK
# DATA FIrMBxkLj1ZgT82UHWODz836J+pnPNyQIf5i2faff/7R5x+Otl75qxf9P8r6aPAxOox4NANUdXx44e/A2mW9VvsrtW48969fDoLK
# DATA X5Wz//6q7PuNcv2vvPJVZMAMbY5e/1cv538//vGPH86EENGhDiTu8jiDSrGV8l7kImM/sgri3Xv3Heo1eJmT2ncy6PISPj1QorBe
# DATA EakUsm33+LCN/v4J2Yf6c5K+wqMXOv1B3PbU5Qf0Vd8yMQ+ms7byz+grOJKF4UB/n5Hp8sorHzy8++DB/YfYQL21tfUKn7F5RW2w
# DATA 7Mm+anY2bdNkshvd6qVbO7ybESdDtsDgu0m94k1QfW92BjHNYLZuvyJbrXtpCfkAN9+jw1FnGw8VvC2arze3rB2oW+wUKiL0YpZb
# DATA Wzs72r9Uip7G021/5/Yr8/s+81Hjc2Qfq4foDdQ7Hoz4zVlAUQe5VfB+qSKz/N0fFV7xPO+zqZwiueXzdofCMHz6+qyHvY9+vdqs
# DATA FZ6Qlfko3huFg1tbj95562/eeffdrUI67cbJrV9u0XUaHrYKW+N4jH/U948+31HZozamRpMJDT2//rXeqJpygPYFXiyXja+rs0T2
# DATA EO/mTmvp57sYC6aJOlah8l9Hgx98jQvqkF+Cg1F4/Y/k8FApTh+Fvegdsov2cEgBt5eQX/ewkr2DO+euea965WWX7/Bpm6Vp0FdU
# DATA XA9gyGyr+M6/ke7PTm3NB+V9/goq8Suv0BQabsqPmW60HY/SMY3CH0uh8+R/5xaKGFnAK+i4BBuAP5TYmkgxhdreKm7t4IdBNNqW
# DATA BykhgV/BNTw5iUrYT8DbiLcnW7+8W/yfwuKvysXWx6Wbt/6H4kc3tvIvxH+TEFO5XyBh91H821vvjPZx2sfqSfiZrR1+Rg3Eu9zS
# DATA c4nZ0YmQW7iybFPNn36Mk7oU05r3Uw8betU/6+PA4XrR0w7ZuqlMJFUMYG9OuugN0B+VePfDtnonqs7H2F+9vbOTy9OUYjoNRx1U
# DATA RX684OH0gMlOdXWHqp3nb5Q7aqqrMKbRRMVOX9/V8fxl+SP5Qd+IPd9yEx9K3HqnS8WypR6PRvvxJBkN1d5w+z6azvXiPbr3s893
# DATA 5Mr90b4cCbKTOl8JwmKPasBHn9Vrn9PNJhY7utJYWWO9fC57rF92VOM5TybhNLQccOGvmKxLpxGP7BzIXrFYjHx/AUdvOZJbZOfh
# DATA aQmGL0zmLzwtl+cu7W6pPStyLXvf8mT9fJTOxhiuaHZhRVMlCv/xac+PKWXSU/COwW16TcHzd+YTs7y1fvyR1Ww/+ik9iVOrJ8VM
# DATA Z7hdfeg5K2ac5SUaHqNRVx1ANe11NtxGIeOWEk02qHvjc34oe6xDUPbw0yj5SlDfoPnet6KxrAn/NdaW4Njwhorj9UbSeYLTNfiH
# DATA Kh89ODnk6VNB5ssdro84yYCCQ6csMD0y/UsqSOzAor5X0fJgy2BOy/Q+tUh0W+hncEnpmT980CwZiuli2g+x/0qaq+n9dimyo4gv
# DATA iiNLmS6lxxFsl3By+AYLCyaTQxa2i5/ubtGLR2FnhgPlZiRH501T1a6+OctAKrWPlRXDvaq5Zce76W3ZNc08on3mCbqTJC2BELat
# DATA wyngys8+/uDhz95/9z95v5Zv9x7ev/tYf7n/P957t+CVEyA9TJicOvq51+XQsldQ93QgkafmFoXDfG2Ua2qgRDssfUIFt62qzA1u
# DATA mtlLpnbCOaMVT23XshJLVGDbv8zdhv+2ulxL0F3KU/hUFPcuPppcL2W5vovDXrAuS/irRgNSP3paWAy6WFRVgkPX/dUtPG2+8duM
# DATA OS0vp2l2sTtJxrt3YXEtCzfVSzRkn+6OEnrPQREz3xggmVRCoZIrouS2uEczBbmzNEDEkqoIntQ2rw5Ftxp8h5miB3z8jC/KwM4H
# DATA +1EBzoLpbBJ9LFsodx9PZurgtf4o1udutVyQdVO+vpMvSKvFqELVRhT8VOPt/O2bDVc6zLkecGUL3aybZEvMi9knNrV7SbEvlEU/
# DATA Xx+t6sdGmWR6OJ2Gnb4d148WS23Zf5vmub8209XJvLyBvXl+f9j9zC8EYhmwDQ27czTdVt+UnXzrFHlrTTIlUgvZy3IA2UvMrz1s
# DATA +RjMdQ8UbZOxi9FYU0SToZQPDWOdKF88nmTTrvX0G/d/8f7P3333xJKjJ2mWtOzJrLwCXVxvQsBhR80AMBJtq2rMkyL03HqGXbo7
# DATA 2WOv/gP+RRWd3IazfB+H6neaAxSV0U1p0nsvrIqx6hk24Zc+QbfBFlMP8j94NFWRyHXYfG5jO5vM4L6Sik/Bk288wVDW7FNgOL37
# DATA /A+EWE1Af61G/JtvvO7xtDNlNKjqam2Hdcn7GQbt0GN0j4fdSyN4KTsejU/hmIyaOUPkETv372MWtvV+gn3cWY3sGB96m6/34skw
# DATA 6m6hjKiiffwxzIGPyX7b9bY+/hgl9vHHWxJpKb5r6kqc4BT7MLoMt99m/r9Ko1ytzfv/ymW/4vx/V/HfX//o5iyd3GzHo5tkOnjj
# DATA w2k/GVVf+fGPf8zCHcKrxeKLLIxhjQErvliuSMaRht7qDVwPtRnl8WxrMKBuYY1XEMsU9Zr+hj1N+nM/TOEb1F9j6INNLCfg2f2J
# DATA soJovvZn03hgvvEcwnxLB6u9kJQfxiEZTmx/5Lx/ctqfCAzPXKD2lnNecuxnkwFFXjpRnQS6xvNA6mN4HcWTifxMsl1Gz2wgVSME
# DATA 5fddu6+DdU3TH699yEVkCoaNdqyoTKJPIrUUiLyRCWjK5abf+/Px3iTsRr+A8IF+8WJczBBF2SQjFzaUbdM0Kc08R9LTLkmIvk09
# DATA yjI+KFL9nAz+luOGJzx8h+W84UkoNohu8YaqrR0dnkwyxuw2VR4AbPjZlZmMvGOKgzFTPZfioPVMV34qxenH6eEQ+2W2LbuSk7l1
# DATA 9L8ffeMd/fHo66N/P/r2+Mvjfzr6PX3+5ugv3vHf0oc/Hf3ZO/77o2+Ov6Brf/SOvzz69ugvdMsPR3+m2/HDl0ffHX91/F/oJ376
# DATA z/h6y8M8Apa9xEANjyo6cu6xNIRRvy1fUmUD8nz248S2/HjpdFf7S3qrfCIRmR6Sz93ZcJzq36IR1jk/DtNOHIt9gi1nGGt3K3qy
# DATA Jj6ZboEnx6zupCa8wyfoPsZmllvKprlkWlDsd3MpWmI/zE0x8RKaWiJa+QLH0vwBZpC7PHtcNfVESJ0+1YBtNQlFNEfJ9o5Ui53V
# DATA 81Tk4tKfe4MZlGgWXoNtyvNvye5KsLzAIDItWiXlbPt86B7O0B+RcUEztHxKzJT/417XmtHn8lNN6x++YU/r33jn4f17j3/28D/l
# DATA o7wwzc6lw35b/rmlNrh6ljHxS55deEYSi5ZX4gqccqbsLJTdbMRtkH9UDVzWlpWDyrjF4Z1SimxwQVVXOLy3X7uVOc8+yn0rfvRZ
# DATA uVD3P7d+33ntw9LODXXho88q/z97797c1nXlC96/+SmOndw+gASADz2sQIHdlETbbEsUh6TspCkGBRKHJGIQQHAASWwaXU7c6eRO
# DATA XMmkKzU11VXdfVN3PoCsWG3FsZ2vIH2F+SSz12u/DwDKdvrO3M69bRHn7LOfa6+99nr8VuXqJbgH2U1bbOF/PP9cbf9/V5v8Z8Ag
# DATA PlU7/gvFAr5Mnn+CnOD5nxVL+Eq9/EoVBG7wuKKeqScfqmePk+fPoMRH6u9nWo2NrJAUhV2AQynJJKiDSntENuH4kN0LKjNrKvlK
# DATA 5+kuueLdFDxG8/riIvAenlddAWz1xdags6jaSvfi87x0ZSmYhv/j+afA+hSXewzMTzFEGp4aqZoTZJlq/M/gHTDEX+JkfAHzpX4+
# DATA //L5l4olPtW6bnVNRT2woy2tpI4+ezn5foN10Fi8DL9XZq0P9OYZrM4zaBjafwLdfDxv9w2Lp7PgxW9e/AzYul481hFYGmzUvpAG
# DATA Gztq6/dGiNGD/waXczVOesFE4Fh89Bp6u8epcvdafc+uTmbrlC7wtq42tpQvvZB/tK72gvXjb8ndHy3uXSyX1GZcNHuv1vz7qnp6
# DATA obz4RsrK3kA9ThWCG18PQJ2OUJmsZvcsrcHFvlZLJ+QBbF7hJ7sre0JJatbKM4buj7fubG0iHoz8qBraSfA72Mwvfvv8i4rhALLb
# DATA cec/VoUfQ0WqmOIMz58AD2D+oCqXuf7Ti48VhX0F5AmUq37/xppVAjKM7WQa6/Ie7GQZtz2F8GWnx4Q6fRJm7AWckD+praWWPMFB
# DATA fcbCjurxi4+VlGP3mBVRbGgAZEOb29HbGJujYZ2P051r6+tlnT5cHgpwXVIBzuDEWBp+oT1LFYHNiITJKwBfaQYLtKzIEp6j+UMV
# DATA w38bjZBDH8pLLpyHh9LvaRgvPoqs2pcvPlJzgmQMx9KnSFsf076Nn194Ol133ikyVhP2lCYSqg5I9sXHCZWAh5oSeLmx27HVVrfU
# DATA 0qj/ftZz17fYgK3Yxf3a9N+KK9hV+iI99fwj4OxqZKub61WzGecgCB5RKV3d3Gxu3t3aaVxaWl6639tau7Ox+t7qu2vNzdWNtdvN
# DATA e1u3G5zGBqXjh60HWf0S4D70UmcXpuZL1Znmzt131jbQWIGDIFF8fWNnbWtj9Xbzb97baW6v3dxa28EifP+tYdHmcfaodAmkd7f+
# DATA +72drXvbO83Nrbs/+GFj+X7vzurW395Y3WjeXntr9eYPm7fXN95prm2s3ri9dquBWLNoqKHVgpurL4XFVgh19axBhvsNQ9uKgIaH
# DATA N6gMWapQv65euXLpSrBE/0a80zAbIs0XvyIKUxSs6oKX9L27KKYB6T05BKM6b55RsES4q4kJhMWVKdKgoig4EFWXQUj4XBHOl6rf
# DATA T4HnfPHiNywM8pvHomuJCH7cX8vEVzIW+rorapxNQmO5LjzNRQBXY3fPkc/B9B03e6MJ+0DD000zZJvu7aqv9hDMDr8rZPni1tpk
# DATA Y1vJsq0NsmyYqzvOg2w47Kg7fZoaXQihSKLqQyy3ffAs7hxQYAHiV2ifWeGhyX4GDsSkBUEhBdTBDX/WwOk1nLkNaucOWNG0QEoV
# DATA wImsvkndGw/3G7Vr+scrYdng5PoMmaw6lxTlKJ7zlEj+t89/h5wVHgGvBVb8Kagi1FZQAghUWpXSL37tsGrnOMZFoD7gU56/PJwH
# DATA HvF2NgITeh6ZjJxoiSmRN5NUGJ7LCQqNX6Jc80foHEgP3qHyJQ8I/lG/2Q8AxEzYR2rDK/lCHXDwkaoOTiuYsKdmSeLzzm4dxX2b
# DATA Z+b5KPhc9eXXdG5wJ4Jh0QnsLwCL4tKJMlDOcnBR64HGqwOou7qg4mPBJV4TdUNrFEtxvrGb3lrdWb2xur0Gp1G6V67Jt7ZRpvRO
# DATA doo6u0oSaB+99rR1lVdcXkUPWrVWQKZ/wpUD1o3M8CkJICCjwUMjS9OCKslSsc7PEqfjRrbifsif+rqsLx54i7QYJPASWH/kKc42
# DATA hSfa7wpXxNsF+JiroCcQiJPZu2GL3ElUuU6OEwLaOc+rgWxOxigtxmawtGXFbW2o4VnbF8ZCCiUlTaNlH0ZVssrPv2fLtQ4heQYG
# DATA Vpzewh1TOCQ0HnY7CP+jZh//lKWhACx4gh2W3lPPVukjOZjKnhoTPyM15iTWGBg3QRVX8qcNfbrScq1LV2y4/0l/3EOL7RDUb3K4
# DATA sPqHaQKkKms46jkOJl3fXKUK4CL6Vre/3+qubz64Kg+9XqvBaRpWn8uMsXSvH0uXwolnCgeocg7oZSUjJCUol3E6hLxsxTJeYKBI
# DATA bdxTQnfpglREtgHw8YIjjfcPKoyxuM27uCZUJBQrg8wujh9WyCR/SooxdU/4HJXmz6LHA76gU+C6yFFPkMV+jNc7m0MkpJ94amnV
# DATA rAPB2fYyI7FDgmfg5U9o6KCait+C/Fp0OhRwN+sckG7ZnJa7/dKM1u2sKkcF9LQ9hbugdXDVkue/o5P3CXb9l/jijzzWz3hV/4gr
# DATA gfeXm3DD0OPaWNt57+7WO568FJtiSdfR5/Hy7xydK0tcvAy+syQ4HpAI3bRPPE+wZ6E4x+MqaMnILKHBBCKyysEXJKAXfoT+sfWF
# DATA wGvobOJwb60VjIjaoVcrlibWF/IBXvt/SvAeTtfTp9qQa7t+OiobfYtCSepDvPM+S95Z+2Hj3dXb99ZET6IeeJ46eBPQ+a/tSwHp
# DATA KyGGHvPrwsUg6mykapgyjGjPv0Qj26cobH1FWomf4kXdulyxbpa0OXDx+mM6x6UEXV1lNMTuHLcx975iejp1gr1rqvrzf+drH2pL
# DATA aWqt9cKn3gDU1z/XF2/xqFc9sw2nElNhDKoLU/2iHe9tvny7ru3WTRaEXJjGz5DF/UJ0RAEfI34MY/qKhq4G9ZvIrdZsW7CUNfPj
# DATA 1sqVq/Zo2p0jiGZsiIdAjYuUjZetZRdGS1g63I/bAWGTHRyPe+/DJkMxuts62W+36mLRw1wMVtxBuZLsp74+nXpUoxjlEtbnjIvf
# DATA H2eP6C9tq6FI1CYMRB2pxnOXL+/9/ij06mWrWZeSlRDLG5DcijpbcGqGkYA9GM/oAZis4QP1E06wgbEkbr+9qmZu+96dbcN1Qcs4
# DATA cKzcc0SIkAaNai6bzmA351KAINEYIzlaT5DQn9AeJYJSG0Ef1mSKheEu2uOAaAjyIXbIp3wxTZL0IvXwIjr8e72UNXmAaARNWhoz
# DATA 7xU6RXpg7E4pOm72MqGDuAhS+n4x7D9EUTDou+3FUCa1CTpC21J3oalErUOreoi+r+UkKXmrUwb3vf7DYkOJmAFQjIduRyWawpUT
# DATA JvWVJcPgccFq4xc/hxPkI8W1vrDYLSZlbOAMLsbsEGgFjpGivGCyVk8DZgEELnaO6Fj+2e8lS2jUS1D0T6PCIvWKNTqcRhSwZWzC
# DATA FRj0Sp33xlu8RnHYNXC7YC/hUeY/FFfvXD9h2cYpqKUVTbKodiKqtaUO6gd2MRUFGLp8iJG161SCzgeg0vJ39L3e+z2I1tewr/xF
# DATA 6gUX8bi/3/BJzCIvVLXLYrgrAI9kBegs95UmOGly0tH+CuexHJ8eHBnH6MMneDe0hlI8/A2EO4FX3AGah9RdbjkfUkkOX4XcEcNS
# DATA hxhmB7k3oDVgPA1WtCvLiwhz6V65HK/SGq5HIWVzX4t+iUeBKAqgB7t2yAhPG9DZYUf1bIguvFz1HkV/QqvI9sVdwwTPcZd4DNwt
# DATA ZyX0N0VUOeVbiyX2OockElgTMc+X/myAjmOXs4ikZIjDtDR4CaFGdinpCI2eyuMYsna653BX+YDoCIgDVUFbfcof6MsQ7rAxjhdJ
# DATA oDrkDzzanW9D/d98oDJL/gfFuf6ghGJ1VX7xj4aLkapSMXO8KyvpTF1HQTQN+DjyQM0hSXR2r1gD5xR0TSDM7fGgdIPIbJbe2s/7
# DATA XcinZk0Qf6nrXYQHC3MdEkoi73cfYKagvDnMuq1R50HWHPXtOCkQBJyyaFINQ60ckb6qpZUp8vyvWCA2DoAkxD8BCyvOLCoywHqP
# DATA l/Hnf4Bzh24tj3G+n1hmRBmsbBpkVuFxOLvDeHT9RtWtbut4x/8psNPiDrtiujtXC0wBvWw8GrYASIIoQTQSSq7VWDKAIgTzb2wz
# DATA gCZ41IMQX8qj1G2dZsM8gUyuSetwBDjm/R4mkEU/0esM1kJB6IS2ohvSlpqYg43hb3Jiyne109ZJ1z5KzQt6TmEh1cLvCt+r13sh
# DATA ERtkncVE69X9jVC4xBHf06h+lVtz96W1EOYaaFEW6hJxhWbUHngI8upjKIjqqBe+rfjTNTd+G8dl7qOw4c5SQU9K68nZxGhCxOZw
# DATA d3uaycHtBXqn+jPLrwsl28co0T7D3QlSrXZzF50fShuwTX7OjiJfgJrhiTbysIHiSQG/JUsbXd8/RZ0bqS2RFz91FBGuJ4xZrJhd
# DATA lEGLZOcF90iWyuJXFOvwpHLTTs4F5+bA51vsCMdOJt9JGNWWcJkYaKjTq6Kzq55exvZS9/kHBKLU77Y1ahOS04J/ps5ywo5eUkCo
# DATA R7XDP4BC+cXPpAPV4G5J0fciT0ir7EJt9i/PKBaSyYuIm7upnnOwpxnOyaOi1pxSIGuCbGgac70iDOqAlkfQP+LSpflnwzl2iudC
# DATA VA0WLxWZyOuBaVp70ReyH5Kc4LEtNhkloaNcCyWt+hzRiULGWtxGfxOEsXDEvGJl6QxHjcIp017KgkSt95bbsj8IKR+VZuyX8Wuv
# DATA lMCbCrVEb/z5Os8lOBzkHDdfdy11z1G7gfmX1NmAON5ZSYI0rEDOrsEaYBOSVh/L2oHqH65DtrXpDE+wQxbmKkkTwBREvTPBSYFi
# DATA BTqp36kRf4KmDzIaPRY31SQUn56E2ihJCOoSr97cc1wCMOqTrLRCLhDAX3gTsHeH+TZKOu7rOPGYMjhTsrXDLkeVKZtm+NY1WDpM
# DATA wZIS64OfZAS0TTDa4xNbJ2TPJLJWq2uuMV4KzmKd8/eYfX4A4LClZu5YiZqmHruTw85JC32oiwUsq3tc3LshSiVsSZxOvy8x64Bt
# DATA 2OolY1bOyHGLTNf1EhCGbveZcvf4y+3GR9FmpGf24IojpoDs3Mgl/sfcvV5xZOS47vm+FT1k7RANAHAJ/e/chkg3bdoXLfjG3Vtr
# DATA ze2d1Z01HQ+zvraNO5aZKMIDwQnLnTHjQiV7EXOdsTyUt8lNBZwaLXHA+cQcivTg2Ke1jco3X1pxYhwuc9LJAazajQojVV8eNzDy
# DATA 9/pC4vENjlWCifTsMdwrAYXR0Xi2HSScOlLrRwffwBn4q2Sp/9prr5kbsZ5lO0B8KyMUCUYOzh50+uM8Wb+z+tZaJRnnlBgB/AEf
# DATA Zla66N6IdX9qswwADdOqkZDukp+M+6NW8mNFEnCw40I+xLjwYaamdpxh9HkHUYsge1ebb7EYljEemHBzDkYkFlDxdh66E+65e1Tu
# DATA Z25JWzvoTibepOe/AcpBil+pxeSeFS0QlqsEdzbtQ9tt9ZoELAl65SZL8yUaWoVmGWL+D447mAbecuVkzBFmCO0GkLQoDviHpaJs
# DATA UpX4wlYr0O3B5JoQDyod8qq2IVCBxWoedgCnDdf0YWvYNvoEsP0Wq4RJrY7BJjycaeUCweOf0AXDVvj8iayjFCn2WIy8CUppT9Xl
# DATA 8yPyjPG0ROgnYtTjvy7wKfQsvjzZgoTlQMjFkOIUH6Zkz8CE8w8AFuuD+9+NQMPZ3vOOcwmpFqFfz55/RlZsUEIpiRoNSR9FpoIv
# DATA LHDxxgiS2NAeUGAy5nvXS8UPC0fP793xx7zUL5beqN+v0Z/ls+UKBfvR1/MMWtw/yRnpp2i+iA+VzEzh+IS2mmagLrkFYw2+YH9D
# DATA 94gIJ8X/7iVnx6+mPK9Bkcw89ky5Tr8R6ZuxS9BpjQz47DGTKJ6rpN0SeDSoe/yghKBgjlt6TR1JEAe1u7SXXEgul3frlz0xDSoO
# DATA ZgX2BL2ZOr7fs1cEXLMfIwnzcnO8kR4Z6I0+JW0SDxx8P6ZZIK+T3h44xb9rjqFI6ue0mRwv5E9Zsf+MAtJJ4yuUZbCgc3f72G+4
# DATA sDoCm94HLhlGvpEsO35Rfr5qf1EJWjDWJJ9OrUKWzwrmHrB7yJzMqZOxidQ717Wzd+q3ws6SU3aACQp2be4Av2f8IbSrptMNr300
# DATA /KmpcQrpm6v/qb9x/Zkzk3KOQdp9DZbCr8pHx6QFtRZj/rb4W+12BNMgz/QMWIXCIVl+yAGVxlo6h1+K491Asdr/iDrEn1Jspsef
# DATA AgPOUx1P6HMuyq0A/cUEHc72gyfbJF4BVLG7eZyXZPtmSYyc1pRMRAW1gIbe3UaT2unJbPm7xX6nK1XPdS8LZjmYz39V80NToL1f
# DATA /4SBhZ8EkRxfIUv6CP/7s+dPWMY571wOBuhVsUvJTtg3vdEwPUfHvcDmzRThRLID/VGFhvz4tyZsi+IKqY2/Cebmv6shfYLBlY9f
# DATA /PrFf2PmLfMjIQ1RrdufKa5FVcBSA7hO/wwp9iNV09NQjPpcx7wwwEujIGqMXew3Nzlg0AKXZUHh0oron6kqVDtfXvreVZmVg2Oi
# DATA G2yH/OvI7nYfkdXuo9cKwqnuhbPyT86IC4giqs1+hicfOiPiA2sMRXp7drGYopzXuu/CSxR7RzpxdVHXjb0oLAEpI1Fzv2JzPnZJ
# DATA m6Gz/BcrStcXsWVevmQ6+zDQYwasS1SZWrclmQF47PTcGT52rBLcjvJsDZx8NxFNslzW1n+Uz0AUA6fpGoAevZ+d5qXdC1wPN7Fn
# DATA f1LLHo1AFTyffVl8+Wz1u2e90BdpqL0euJvNbVyf4+AIVcfxQDvdU9F7n5FpBN1QyfoHHmGkzK9HfN2CzmsPZWH5kOodJ8KxP6c1
# DATA xQdSMzeSqonCbvxLNlAo/VWOnS3a1cj1rzX7gkrTp4JSShjU7qyKvzLJ6ViclJZTPPBpxMbtfi7w5/NYfnBBNdhuoY0XsVqiizzF
# DATA BUZ3FlfJtvraDi7GM4YG66yk0ebYnlpxynd3HzVa/nZ3gtkBSoaCoBbjA140X47H2be1LxT/YFdMwJ6rtbNsAH+wosryFDQCFZzs
# DATA aUW4PEeLg3b4lUbwsMgVp8A/4DfiJP8lmtXgcEdkigRipdSc/QGccTBc1ISIv/hIjnYbI8ESBiNOMHGpTTZ/Q2Zl12zwPRy7Aa2I
# DATA by0uHgTFuAEotqjyhTZLFJ32jrhdRCvZ4WGGCkLV+ZJoDmexq3lGpCueNqZifQ/8+KOMB+U87cNauPrmbvG4aLgIWg1rq7tHA6Tn
# DATA Tpx1GIJEhYIYJKdeGGspEr3vMnQu7iECONNJRah3nb6x2tR4LcComVEobWoTcBVSEabxYNNGA68ohcz7HNcOVJF8QREpQGwm2okj
# DATA 1TjkJgbqYcEIh/tOGJZLX1FfqmGm6L8DAigQr7einD1DIkp5Mf4aF2N3aa821GhF+KS6rPGL6lLGXg6rLURDUr9GR0MCEpe/f8Jw
# DATA 6O0OPlZrCskAABNcySiP0FGu1W7jEyWQZYed99OodfL5vxXuXNjsv1TUD4LpLzBWS63P5xQFKhqqhHbQM9gouEUwAA3KIZjWh+hB
# DATA +Wv7zvSRtTC8Drs8gRDJhX/5BWqD/qCU7o87XUikgUYEy+azc9zJmYUATgiYEPoIVwcuTpgcQLt4wOvhoN8lEzecmCIrWPUNIR9q
# DATA 1gP6IGBitkFBXoGe6hFAcHYheEdV2MPEBzp+DOCK1YFYC0doQ/zDOM8uXIgFPPrSl0lAAWeodV2q8+VNgxKmoN9Pv/tdiU3WJGqf
# DATA MjGua58fWtsBnbLMUnYXw4rxJr8X6zOnAlFlCebKroedTOkzN24WFeN0UljqcBILpHex7xbcgHpLTg47HYbKC+cqPHqjjKF4oqas
# DATA ZXhGOIX/Jzsh9NoVzrk2OQ6RO0rJ9Y3tndWNm2vNnR9ursGyAjdTOwQZGeH09gls/+A4a4+72TCd+FpD+l9pv9/vziA95sIkCTvz
# DATA Kfy50UiKqtA8qFzQAWvm1XywbhRaUr+sTUi7kNoSwi87hy3PE+gRvsFjVws5Jrb2MRnwPkOcuqdKLH3G4cGO99T0w5dgbXFbXEzS
# DATA 66FtJNS6OsGjZCbTzrRPis2o2n9dW4NdF62QH9StzDcoU0a4i0fDXX1kO0Rs9GeWfAlfONoyeDC3qmy24PlVTPB8GsekQTPz5xyj
# DATA P0O4nsK6Z7H/GYycrmIH3RbdxZwWp7IGNaP6O5uhY55YfhHbQ68gEE5cbJk+R0+cG4uAGVpRFKFt3ph2/wBrEwGuuC4E/gXfitE4
# DATA +KVIPWD5I2C+c1K8R/Vn7jTWE+Q3scN/4gZSuJdjvOXaWKY6fgoYXUMcOELzXoO04ZXE1o02dvEyT6q/8p5+aVSIDbuAlXkqIndb
# DATA PsgIbwfo6oHh0f5yB4rdU6VYNigsuEmMnpBOjL6zoC5/yxd8samle+/eaXo/0/yOUb/XJlX99+VJ9bL+cUm9uPa91v6e80T+XiY/
# DATA Od1YnM0QqsdUmM8wMOJxcr7z4Smy/8fkGPELwEMRVwCDp/5xECGxW7AAIAibYdmhE2faU6KeLEP0jlb/132/UZQlyHOTNU5Mg26m
# DATA Fx3QCU5Q+m/1MWnWUDFlVFmUIQocvOqiZ5FoX/WERgXd4l0LpfjPintWbxvPq+hWmIgv1kwtPmrCBUpXQ6LgzyCoo9ASYgHx4kUz
# DATA 5otvu20S+uO1yQ79cXXyt+ygf19im7FbcMn1AMB1Mp5Qnx0JZ5WwLD9g2o/6igd7FTyFbyn+NWjexLQGsMqm4x4kknukO2BHX8GJ
# DATA ovUZ6AgWM+TU1Xmg7s6f4PEgxwfuK9a/GkzqatUO8AmhhApX2HQffGXs3Ep5RCHtTnwQQJgbnI8HnGYk5jAIjoSGJOGX5+2EwCQY
# DATA wanf5T7k2pyeeIWRMn8G5x2wshUeuXEtdmhyhE7OCgcqWSVpKHtFnwS+0q6xQc/IQQBQyUpsrxVXmV34MgLAOs8EfUUBNOjUxcLS
# DATA 57Zme4rZ2nZS371AHTNcV8kMF8xgmeuiXSkMv7T81oPoI519tdiQYOInQgwg2BFcxYwAHBcbSPwZPMsIeTqwiySb+cn2D5MqZ/Af
# DATA OG/AEzqHpywA+4s9geKGSThBiAhRrwO6Tzqjoi3J5o+mCzI0fRe/7JaYJ9YC6/CiLMTgHAlcCwioPnfcbJx0yFIdRGuGQR7UKcvS
# DATA jw+MpZ9+zs+aZpn3n2juRVBzhdThoOoYt3ScKNchfbYNvdB/3M7AE7qOmxKGuDwWpaPNJeaViM2Rf1DsYyq1Mb3RLZwiT/uiez1p
# DATA 9ZQE3k5A7WHljWOnfWoEXBchmTn8K27ktmt4THKf02PwXMjkQjX8SwkQkLz9PE5slqBNj86DYf4X3LmscRfAMha6XVusOaCEOgts
# DATA rRYTJdfzJ+hlSxhq5Gk8hWVOnzXaVfp+AhWEzniWYBKT3oMc3LbLne9m5h3JjrPtniP4Si3n8E4HoGR0sGdcCLjE+Rq82XQS60TM
# DATA xkzL5uiI4LO9b8nAEQHMV3wH99IkxvnEAUAw4TOoPmtCIFeT2JMEcpU42AWY1blC712kMfrHgRnrGfhwaENvCGnPxU/hzeBH7ZHM
# DATA Tb2hAHyuxsSYFkEkhVueysySYKWUkbv3DHiSyOrzB20G0XQ6hA5nJRKz6QNQ+QhBZuizUIIs0IFvs8NBkOkcrDNAJFI3Klcycflo
# DATA MOjIcKduT1lW2/V4r0i4CglxvtDR/1XDRotphsJGWbndQnroZmAp7j/sQcrGXmuQH/dHofHbxnxOH/S74xM5bow71eh0ACqmdL/T
# DATA a6O5jDpdt/MNgqGf1qmeuENjoe2lQteJ35pPQSJ8KV1c4nra1l32ox1wsRzSZN0jUVsjR39MXLYRDYP3rol+kDoNbx5GY3Zy2eLS
# DATA Gk3062rK/Y7EcAXpV9k6sgSTlH7JMdgcUxZQCYISX8ph1s1aecY5q+sLMx0vPXDZ15PLS4GmUd+te4pwh50D7RCq9nD/QUZ5JBVh
# DATA k+Keu+C7gU7PPPO9iYlcw586eo3bLBf3SuLNKMJMx5bxh050mav7gs8uJqWlSjm5kJQuJ1W++Knn5WCi0ZZSsoMrZ8Zw+mGbwRBS
# DATA 9nSpmMFoxxTxkwk8jRZcVyUH23nUOkJEUq6jNrTAneupJ9wKhjJ4NFEyK/V5PQRS5sqCrhpqmL2OC4WIqWkJrc9c10VVV1lVUS09
# DATA CB6X38AXb9RbJ+2rlz9oDU+uXlYP8Zw48kCZzOwI8qgGyTf6ooqFtRq89Nd/PCAg4pKp3M2Ga57bqf9K6dHxwbDW6Zs8Uovk1aV/
# DATA hbTGx0aTAdSNN6cWp3TTZqCIUtHwCTbmI2EgcXExdLdDF7YFz2fmzHicaR80/KM6GPYfnXo/q3SpH9oOapZ7W+jqZjzcyOltElCj
# DATA QROb26sGHCwwGnU+R4y4A47l2e5gymDdUdcNNHy7iK3T/DuC8RFUCFiKjaTE6nLRmwsZaSkKXuG/rlnMLhbpQ6xjlWhvoyW9puCc
# DATA UhKN00unbxN709hXahoxZOiAP+gOSpldeBJ5m7RycNDzT8DchzQgScnETvNvPp4soIO8USo7SaebFhxteNK69dqZOpomn3fxd7p9
# DATA OaoN+oeWuK0OMJKIEXutRgKUkfOEck93gNdKBN0TPc9Gkat7EnlnT2EcsoGPhOH7DI5h/PofVQ298iz5GausLUpVBF7hDqow7EUq
# DATA F9qhbArz/QD9sYu4btelDWDW1SmYmNiHulSqBRPDzQedXg/s0VGSYtZuptVh7HzAz3FyFQyS47x2Y/gN0rO9eUar38wXF2uvsR8L
# DATA rwoWxsPDZwJ2bL8phFYuFcf22u4h8rQsRyAPQ11XCDM8qNjpdWf2iZ6b0Acau33ET0ItHrZcjzisz0Uwha2WI1R0fkqavmWof36U
# DATA 1ZyUc0i+bMSvnYyJlkazDZ7g3UhGPM4K6LvaGg9a+pAK34775bK0ZEsRaqw1ckeoiR4nd+LA415HYr0t++6hkfpM2UhIUyKUIRHi
# DATA HnXEE5h5S+oT5hlTQd2dlXUiDXWWs4RV565PQqF0jviKucg11gFnYs9Fl15fsPdd3Mb2GvSHR5ioxNBXjW5hLqjLdFLXdXciF3V5
# DATA WQ7d3v0tcq7tQSGfFYNWdqwIqFdhN3m5lAPzcyamFA6jEkghoTCVOugolBGHQVCeokvlYyX3kRLCFRBL4aAqgWQTCmtue653Asbs
# DATA f44toixVFPVKM+TRhfY0mKVR4X8DnC6pwfd5leev81jCIKlhq6NW5B41+y61iljK7Prq4snYPtqSzR6ytv03cjSux11dH+N3NAXq
# DATA wwo7J6FxSd4SpXjuBgJhbBuAtZeRb2PRCEx6uirGUBNTSU21xsSMI4vfuGkEFst8q3XBwFTtKqWLpqQSOo8dvOvzwfsWYsq3JGwy
# DATA rjWNohawBzzBFnwLqASp58BxLvQF6lyA5RH1s9B4Qd1uyXPvCbwcZsLqg3tOEMP64tcQySbJ5A3GLL2xUJiMwYeJrQhNwXMsqZ8L
# DATA k9Q2pWNyl2/TTxNRGAGmgUC9JVKOktqRuWCcq/Nq/zTJWsNuB2Us5sU5ndFZq21V10e0x4G6w7dGjODYUZV3TjL11QlIx/lxq91/
# DATA 6OLN1kKYBddvdPE/0mt0cYbPqO7z/5Quo3PQnB4AO42aRfB8RhdjHqMuLKkNTcIupO5uqEmAsFtXPQK768IbxNy06gF0g7lW2BuJ
# DATA fZL7PXUH6/oZHmKk4WgL5EO3P6a+4h7R8of1J8SAEcUbDmoPUomcVqxcBxKXopkyxKNwQO6/az9BK6j6KydX22/o2fmoQo/vpZFe
# DATA mKFHDN2uwBBJDGX5Lk4BeJAD0XWKDZ7CGRIiCdlF7cemsKkgVutfEjiCj3c4BIUBFgOIuZoBGorrhhRFdSLS+crCxCmGT5kCBOFG
# DATA AD51B+DLfvUoPIQj3kU9IZBDTy3h4YlYF3ZzgwubiiV68xuLlvGaK5mdVqSUtmArqKaYrGz66id+jmE0ac+oC7jzBKPppfKHTMkd
# DATA 4nmUixPfFJZ2HcG/KG+cOv8+U0//KPFzX5EM5gFp4iODlOsk/fA9hnvt7FFFS4IZmgZbGqF6JmxOLBvO68m1C5ADB/8zxTHcwEah
# DATA y/ezF7+UHLCf0FjVAzd9LbrggPEmgpIjuTPqbi8riaSjqCdhygzOUAeTACVPyKKy1L+6tDQpHLiH2qH6JCpRRPH2psQG9a4k5E3R
# DATA CBzwyxE/4mhOjYqkpypONWFHvOCSa/2Gqsl2mhAyne2acsiuJ1zhZJorhS2JNuVcMoB0dC5ZmUARP12Juw0nVcZMnicOXDGzBnpR
# DATA WpaAumEKlpGiHnPkA3upjp/jv4gUnGixAm9KI8uvaZasbmcgzecJ8JoE0nudyq2U0MhbQ1A2Ys5UQnPHSq26YPZryRomEANhQX2W
# DATA I+g7eoJ12wxpPQDADmyEJQr06B7V4jDrobw1y7vd3gtxOZQRtL+RG5d/2/JlVUH8LwclQqj/+f3ztSz1jfknxb3+rRBjTv+1hv8o
# DATA anPSpjuJr+wdFq/W3XcWIwClmNzDeyMPRMgSW2yYAtRoEIyBOyxSabU7Od5+Sxa2vaXb1AyFMe1F2gVittHstb0gbl6wYroiNgSW
# DATA J2ebELTK33MDPZflQfMkapSVK1wmOOL/OcwQjhCnnhc6h4rx/KNHvgOp7YVBqVPxZyaxfZG8/GutdcGuNmEvlfgHnwD94fsEWu0q
# DATA C+c3n9S4CtDwGQSnqEaQSzrqQN0B7kG6mBb48ltZ7xOcOYJVelaY5KtQYqpWzTFXgIAKD/a0mZsfsFw657zQYdCkM9OHtqr4DcPW
# DATA KslkLCYDawr9TOPIfR2VJT22gKgpcKXsK/qmJyt3phiheR2w2aeJpQKcPcURVQrhasQheefL5czjLYDLkK2oX9vouHGdkiiCwsHa
# DATA VUPKCVPX9UA+t6GN4dL5Ie7nX1mBM5wAwtOGom7S6TG10Hxn7YeRbfA/4g0/JVUz5LalJtU10q7H0QycIVTQSYthAWwxyOLagRzI
# DATA lEn+ycRD68JWPJgAz02ZMW8dV4B6op3uzGWQ3JLp7910va2EMLdi5/5dV1uG6thDqX80bFlIAbt7kynZr+vuGQ83+85mf0hhNwP1
# DATA hwFgQvf3zbtbCBG9ov6Xun6uWAGfhKoLvVztsxPtLBU/EtmR1XGRqrjgBoQwkqbaEzEKUGKLm1/r/GRQ9nOdgpa/CaOjFPubeEjs
# DATA YbzUXJCGheDpzIxS79JB4rD2YYxBXcW8YfhaDN6H8POsdDDfTJZnT1zdZX7lOMgX+mO4fhiTYmC2qXBspRg7JXivgNzgcSAul6Y4
# DATA gJZfFnjL48UREMOwd7EvpqEaBu5KL4tUGcVB+5ZwKv+j/H9fFnZUZ2pxBdww5zbpYz8HDwNtJvzt899VEsZYi6o9HXinbwE6kH2X
# DATA caO7TltF+HvmytXXnpUF+6uEtc+J12e5gGvX9apT3jy2vrTuqup7ze8K+4QQgC57nI7155ZdKCAVEeMJk890pf4Sm3EmoOk5tn/8
# DATA 8CeY76mUbvxWpsiqjiJi2B8pQYj8FtUmq0sVu+oHBSyrP8jkaklmeMHgF/zBpLjuXUsYQR4Jl3EQVvjTYoGlHNPfhHjWkc0SBcec
# DATA Gbm8i7bvmhUe00iB9YGTTAP0CGZMBSX3og3aiE2R2kGdpRcCr2pkgz/EHT0iJhvv9N45Bij2O1g4GRC5ZfA6V4yXhu6PnM6y4iwJ
# DATA qYpjiis03/KX55z7swsX1KNKcuGCrmESplSvONvRQdBSX5dUXwdd9PM/VkcIiRzwVxPozRVVcyOlSlmwDfdhZ5XkiVg/8/whJRwn
# DATA 9L28Rthlx9mj0qWV8oJOioByVwyvz/tCkfjm3e2dt7bWtpubq9vb793duoWaf2rIi56wCt/bXtvCIArrtNQvb91wX/m1eOCCh9Y5
# DATA W19clB/1M+nG5K8N927v169cvrSyWFz7m1t3N3aaaxu3mrfu3lldh/D99Hg0GuSqbiA1syLp5urG2m1TTL/xq9y+d6O5ee/G7fWb
# DATA prAjYY2H3bzkrKpZedhau9fqcMt6+731W6pnqzdur6nerb25eu82LI0SP8ZZOJA7aztb6zfNXLfaJx10MpEXsGLRlV25XA5qe2/t
# DATA xtt3777DBNF8e231FlYbpQvW1KuNCpGLTMxahHa3KBFcKD0PWqNRNuxhAN6PYOKHWQ3hqTPY+WWMmmvULnw3dQU6yRvJn1ewF2CN
# DATA rN3x2Ch3Dz4Z75vynNivWU8CBiOVHXZbR3kDq5yS2Bbrv9hAgFVVQ8iuLuIrmznAJ8wMEAECeAFNMEZ87mfimUc/5LbMr9wASEyM
# DATA JPCvfq4k+P1qen94vwe4r6+ey98PAUu1wuM6uPdwmihWipoTlrNL2ZDsANQOf5CNkUU6x6YzaJ2CRVsNDswQNfgbrFp5dvVybf/q
# DATA ZbayybQIHhRFGjke1JGscFw3nrTvl134HH63+z4LDOyh1bqZDUeb2QnsnB8/HG2O9xXffoeh6lVPrNfwU72BXz6SLrnDvgvrTl6w
# DATA jtGhZF5Ukp3TAf0ZrIo9sZ+Cyo8dIBG8WHIvPsbMAqQSNMhyjwFKBiBjf4qexj97/gyV1aS3RQinZ/GEp0yZh69qwaZxRvQ2ud8z
# DATA HWqkZ4zoqmj6Vabhh63OiKBMkIGWJHatc5L1x6PGypKJNbZCCDAIXrGDOwhLQrGFavXara6SJNMo4kh48rFiCeq6hU8E/MHdOVYx
# DATA aJKUUOzso9a1cwhHdDYlkxfG3KuS+SJY2w6OVUu1gVp/rf0ytQRIE0B0S8n3nTKeDf/7jWT50vLSayvRDfoJehuAe8FjuBS6GXCi
# DATA K/04eXtnZ3O7avB1dCQc5fZuOL0x1mFWcmWtQ2aZkp23Cv+7sfbW+kZyc21rZ/3N9ZurO2v4tHbhDfxXnaXBu9RKuq2q23aYFzQT
# DATA DPj34XCCwfBd1lKji6L30UDuB1768Dzv1jbX7jRh2M1RXx2rW/h3CTqhjt5yuSZZxM1E4cEBX1L27ybDXzT5ZemgheY1uCFY01l2
# DATA aqgxLg8eJskHVN+7a1vrb/6w+YMrS99Tx7OastXbzZtvK4nB+VKd452T8YmVoxe+3bm9zX728OeD5eYKu5C32ormgIhh49VO+mqK
# DATA wSmuBGco70WyRR2DjSUo9H1dhQWyEkCudUbHSQ5qt5FMiuptD2zv6oZQSpdXXqstqf+3nOqTzDACNZ7SCsSrPyrVliu6uarfFcig
# DATA 28oVL30YyRcOHZAJejhsDZrUm5IqTfq6bNgUPtHQwhXUpxjXeFgk6CuS9CmGigOzGmTZEIllX93Sh2ot+8MTPog01QADE/KrF16r
# DATA DPo9gS9+CI5zDgwWGB4hTOQXkrfERrRUC16lDY+49j9NywW3Fup6ngE77ZYO07fWdhQLg320uFxbBoHgbTU19eRMZmgCz27qpVQ3
# DATA 6y74EYDkoP4PErvhcVwuF83eytISsLEOKoWoecU+H5SuLK+IAq+8u7wHdHZ5aal4hix2b5+cd7f52LSP0HXwJPLPULkCGSIG8sq7
# DATA WTYo1fj2Q8vgshU7wzGvwYcIPv2nxILF/JKyZb74+Lpo2yim52NJwIxrWomyZcyo/u+UbQaMqCj8VUkHKWZ+/MUJ8krmDpJ3wOlA
# DATA HVu2LX/mRRBlGPU2TfHslTp0PDZe3g9TykwAOEHJEu7eJXWpwmNTvihPgPVcv9+ziu7W63uF5Rxx9zBNU9qZydnZglXFuNd5VF98
# DATA 0Bouqn23qLXbi8NxbxEnogabG6pMUBfbhLt2/6Dfvb5wRoObyCVd7XqcCkPQ18l8kneb9hEfaW3U9U716JdNEOwLvh4MOw/Ua/db
# DATA 6WueIJuurfC/l6gIiEorSb93fcEaAt6u8qR/eHidjSPqmFwc58NFxZSGGU3K4vHopEvvW+NRH93pzCcZbIcmIlBeXrqcLKr/1KwP
# DATA 2m11eWu11VL8oHqTTuYqSKLVu3QhVTSZ9zqHSqruPmyd5sFXW4CkMsyG1c2+mv5TkKw7ByN28as+PM561YNhP8/5iVNNt0+KkORH
# DATA f58sPoIJADeaRSEKPPq6HYjiU0dEc7/fPiXpaOm6fn80HBw0SVyhQyW5tLSUe++B7U17D9wB/1JX/WkkiF1EEqQKJhN3GGoU9+/X
# DATA Sm+88jDrdqsI+LBYVqNRJ1vvFBygrwefwGDhVCV3heS742EH/7OYNNRCYXn1/9V+UeyA1A7rm+9ebW6s7bx3d+sd2Mq6i83O4MHV
# DATA ZgbajTy1C9+8u/Hm+lug2sG207aiTjT7pvvDTptwMbJea7+bQRWX1QuManOeQv5DOOAqdhXN/gDx589s41svG4FSukZ1147UVlEr
# DATA jn6YUlHaa43SCVelQ2/PXIsWlK3yaNQny/CBizmP42XOKJZfN0E59b9dEYu5zSznsO3yUCxTqw15Jm/dzNd+OnIuFCA50Imzvvng
# DATA ap3SG5CjkdzmnlGeMkwexzDKjACq/R3I9OMZYVUPImQCJmDuiOW1Dv605IMkL3fDb/e8kPH+QOy18j3d3myKiKR/KsVKA+ExCdJ9
# DATA j3+gKcgpb5OnjjE2sDL2/6Z8e9V8C7QcKfoIdEGtLo3AfYcZ2PBdrElvfLMNtjZ50+CX01jFPN+BjXvmNqvQNqO64a+vUbueQsWI
# DATA 85+MM4gGIPvnWJYO/4zOjPjrYdI6Z5YEJZ4LXEzSJmjJQiIkvPjZxaLORrzHniEcL814lffPM3H8D7yptAXVlrYLYkqeaif58yRB
# DATA 1QlGigBqYdd8G14As7EUnFaZFJCyfA8CNAohiy0yW9Pk23UkmKnlKSRUpPsMSNIUwfuxmLYtQRpiiQscv9hT5amk1Pzqxc85BByD
# DATA xGcZsVujUQtsuj7alubr5YL8dfJh1Ehn1UoWSRSsLUukFHDYo/7KQkYyNamqJsWtpHwipdTWZEq6WdPzwmyzs08k9NKLpfoybrTu
# DATA 1EVJJD/ND0Yh1Bk/Do6QiPGUShZaSk0DmEsQ40TCVIKCKsulA0M26JI9l3pFH/eRfd9HV9P7tdrF++rWn5tTppKgpQIt/KOhoFAC
# DATA l1xKY/fc0DjC3RHrSHna9qIdxCvBGOR69KF/B2Zq8FN/aW8Qicm1MceDraT7K8KARdahQceaTdgC4HAccO749T/YsqEQcjbBoF/p
# DATA h32PxWXnNzHXgY66kYzA1cg5BOW5WsSl8Cs5Zou+PnrYnF5BuCelPESkj5DsdeXfT5Yiubv8PpgPg96pCuIze469/kfTn0IvWDlO
# DATA Y7IRTc+umViwloPKb7mia57ymT2j1pf+UMMahCDJFUSv0xSyNIw0OmdyLjiXAPnE3AGC9mMyNQbRybDqyZKSpeyBqieTBcctISLU
# DATA syuDtDMr22tgp9Q7Ftx5IsLUQoRu441FKYokKUi3psjqMQYYooHqKerQviQaosyFkmn5KZuwQpYVS72sz2mYTunYQtGZE1u9cNAV
# DATA 7zYY3KLLlgP59IsW+TvBnKkjxJmu+HelAiGEpT1kupb7aSg+1sii7pwWetTT1pjX1um46YDQGV2M616CPPIF80Qmx+UlvLIDtHK3
# DATA c3Q8kqtBhY+rJqi3GhyOAm54i+r5oqp8Eb5bhB6Aa1S7lZ30KUWBFM5GB4t0dVmktxzazFMBHeiPR4PxqNQaHo3BaccOxQisGuwC
# DATA SA6x/KM2HPfM1wAxMFCjzJpUL2r/yU9A/mQjx/KVcrHy2qp+h8qvPRpAzr4ZspnZVaB9/tiVmGmjwRVJdxcMWi5IBY8JVwo0+d9i
# DATA ewJNzW3mo7YaZw0UhYNSeUEvENFACe/Zhy2IUQApKkidZJFKspjo0upvVdyXfV3UnSljjPu4U1s4NNOQun/W2LEjHKMODibrqTtK
# DATA lifDgaaO+CiiIkeIS7vAI9JWl6Bf+NgpRzVKEYkQE7D8nGwVz59el5GR1OdksDFX2YetYZv0Q9xjad28kw2vFhSdxyzPDd5vu2ln
# DATA AN9Uf4z/Rb0EFkdv3OP+Q3s4EvWv69vFv3Ai6C/gfPQSgYrH4jzQzgCoHTiX9RCzD6jqxwAFkjMsqv7lRHJRpYXqOXvyioiFB0FV
# DATA WQoBr+NWnIBe2ga928Vh7PlEXJzfqVb/6yogki9fAVB5Xd/LX+z+mODZ/DO0Vf0DJXmODkw0BXOSclGHCig17ISa9indsNZcrCyU
# DATA tL2UDltqZr5HpGHRNCnc6IoWjqF1AHy6qb6lAaykxTO6tVrFTEYfvvgl4m79zFdw9DLS9uFtsRbyEt1YY8VOwHwLjzOrz/NtWoS6
# DATA U8OqJOwtgNOgtiEdj6kVYA/7sQqm6xbIr+nZWW0brU41dieYTCAev7RyrQIC6lI5cA70Y1bsRjg4IGhPbfnhiOqtJJcuwUXcZmIW
# DATA mr7Q+48evFG6375Yvl+z/1G1MYfhAYcIr1QXYEy7ORTwee1IEc0ApCWwQPNcFa1yFTO6ke7QX15epzUwxWXJyrWLYNWVcO6V2qVL
# DATA teWLRjlvyS6xc4leu4zU/sQ6Wtwk5ST0kEZwcHUEOzAnbTdqyYvJl7uvPwp25PVkY3WHae4PmHH5MW5OK9eyiGQodE0hz0hnD5Ww
# DATA 81AdK1VBWCce3TvkIcT3bfFw5MOE6wu0jZ/JEChjva0IeaoBBM+16djiHo31nqKs1t/COacPS7OBWKaGP7t5ZK9ugE17AiiQqNUC
# DATA x5ncCvtmLTQ2ELX5xI7qaOudXg5eLCmhrqoj2g6m0uGPrma/AG+4yHjEtuY5DEe3yHA0w1y0hrc/oAjX4jPbWKS/9O1MYdH1qQah
# DATA 82Ag84+XqEaWCaspoLH/LxuUpkgyhSYBx8QDd5UvEcAQeNUXXJwTyHNA3EtAm11PnOq9TLqoMBXgWYKKlFSiMJN+TgeY4qhHbDyx
# DATA NEwzGlL4Yq7E8vGoD7NHZ2z/8DAtMDQjKwSJ7wv0FFFHaE9mQX2FzsXIDT8COQQcjH9moz5+CrGFMV9hL5A3Bu/FLrRObrdKcmE6
# DATA /D1kWDbw/zhmOBxggPXw5jWfSwC7NvgoeVF/9IjGIv7dS/SDlATx6kRNcNPGGY24u2k1gnYdryTvZKfkAAcejuj74wQmm0nspTFP
# DATA 9bDJEpgwMqrStcBk1GL4CQPJmbv1LxWRfYJmBj2T15NirMH4jiJsJSclthKHcvKD/Vb6mNqQk71RiZsDoT1ZVfunPh2QggzMnl3y
# DATA xa9qapOSm/ApKkNUFwMqivukEEs5VOztuBSD+tGmdI11oB1fU+1/20gvLS0tkdn90WlDxz6jvz65DWJpP9isACnBe4wuiaqFZWwB
# DATA 94Ji/U2MQWrw3sOWzFPaCZT5FPwGEcUtzbPuIQD0dlP7HVV/+fIledrp7ffHvTa/uAZv7ERmdp2GX9p12zEG8XAYIMQnvMTsa2/Y
# DATA qOuDjpExaXlhVhSs26+GG+mgFcfWigQd+x3xYt92DkCrEed4A5n9KWLac3Lhb6S7pms6hHAXnUBj6NkcsuQvaWQxQ6higNmmJghn
# DATA +1IUWebf2In6V8nq5nrFWR/IX89QM4+THwxbpyaa5ktG10YzxS8olsbCi+kc+rQcSYTlY+YIOimCIAMWuRLKmqu37qxvuJFR8526
# DATA BuE0cgAb+KgAfD7ImV2ESFUcWtbtHx3RneHM8h2E+wOBDIHMMRB0mDN1xj+qgpsmFLq0hAFS8AiLqkdXUvaBhHt7X5KBYXI5eD3u
# DATA dUF6y0f9wSDDnKHcPCTnoL+CGMVCF0JBIGTMhrYNtjMJqhl3Oycddmjs9bm/Z2neP4SeLS9dvnbltauqQ8fqamgeTCaT+TCU1Pkv
# DATA zgg0dObSDebVWe8BobMhJpVZ0sUEvO0fpOW9qP4Flitv7B6aUIu6BGrVkdPHP+OErY1dxqeoUtgEub6Cs6uBrSDcu7y+qFZ5UY1i
# DATA kR8U1NzOAGMgb/Z7DRtWob3PnqK9NoaPY+I1ztNyrHjx6Pg0nTiICwSXMfujSbQb9Brzpqp+jBSFAT5RevPOrer222u3b6OSajzs
# DATA JtXDfBu9r+uLi+CX24VDE6ZueZHqQFRK1NmpOUFf1CW8kLOFB4k6J7CI0ZAywF6lg2U4ag6yYaffpr2Q29ARIU8JcBsgCnGg3rUp
# DATA uj/VDMTSEbdboxYEScZJS4dI15ev1V5LX5rIyPJ6fIL+1430yvLKyT7VJkHwao53/haGeW/nJqyjoS/pofGqtvBRpjQ3zwIOjpqd
# DATA HJRip0n1XvLd7545keaTpNp2Ht66MQkW89KstVxZmtjymaLJgrmmHcMbp/692nLtUrXVHXR6wCLn3W9FE8JaTut71NWyUlVtF/iL
# DATA fhHIB6gsKTiVnioefJKdqLWuDtBTn95laiuNtHIWnN+pX/Db6xr/g/7vfnFF5cjoX3vtNXoFXAn+WiocUPHyGtCc6kEXIVyq+Rz9
# DATA GcAh8fVW18LWsliXKqWm1GFNyMyEsKNMC/91NFmh+Ox5xNnvSewrBgco/hIDeiTM1X8ROHVEPm2IKAAOB8FrAMu5tlRJlKQ9KcQq
# DATA YiHMkb7I6EROZZ+z2KMjmWOyFz7UEVQUrOzITc9I1E2jSDb5ro3dEzjB7sX3cLhGIfWStNE4u3CBvt0V+QNpr9AdN5pnNHJ0TeHQ
# DATA 9vfCrUGiOyR0XOd9bN/FRIVghUFqWI5u2/jB/nIH9PTdT+le1b4P4S1YVjvMwDj0Kh/bZjzQ90Vx1efz+9VybXSsLhDDxuvig5A9
# DATA 6qjrfK3//htL9eVyuXaAtqZS2SuhXhXxL4fLXJnFZZZXIgLBiisQ8AkhKRgBFdnLGiMMx2KQhltroWziOXo8Iuc2uufXC/YKvS3Y
# DATA FfS2vlJbXq59zxxp7un/1t1bazfuvQUDOxl3Rx2wV40OBo0lkAaY8tJrS/VroBmAK3ydrvHy5+K4PZgmDsSl12CP3ISuEvYpKGrq
# DATA 6BqE/V/Ur+pDPBPxaRUmtb4I/zXP2Ndpkf61tXxW4wJRfWZVhFjWXjU+vrUOPDqjAAiD55nYmNjyJ6w1NQiI6PSX5RwIAJx459ZL
# DATA GFl10nXt7llmVgSetHZxJB2OUwi35Nx3Gdvhv5HCqfXysifLwA1H/tXqHXMj5zFWphCHEh6ELKIRfmklCb5Rl87c+ah/tJiPB7A6
# DATA iBEX63LIuUHPuwjzINJXrBvM9gq+PugPMw0+GPscE687pfbiog1qlGANY3TkuZ9EVFB4FlB8sfW+HN5ehG73BHcuGBlCaBQvyaib
# DATA w14tOuCtcOkizoVv68u1lWuGb8WIc+F8XIaCkckh0bAZisZFN4/2IrurYCFkONM520tOzXlrnb0Dzlnhw4cPpcJYWDL00WOfFsuy
# DATA F/Bl+ePkm4BZNvqy2UDLAdJySB6RpFwgqnlYzPDLr9rHWkbo3AjQMk0ii0qMdFO3t6tfMeoadEGNFFCgtWLjCMNnPjqluXh0GnaX
# DATA AJzriSh20/7DXta2eorWQFms8py6MraL2cLpvWE3DzFqpyKonev2ZWedOHNa3qTUwWSncN/Q2AMZetomcirYgfj+e+NOm+lwrP6s
# DATA wX8ul8plL6Agmg1LOOvUy04s150zXht6qeGq+0k1LyBJDVIOO8r7MhVZJ+W9V8pR6ZdjgIg2kreGTrQxZQFooWRcgflzvPmDQJ0D
# DATA AkyJMOeBXv/mvZ2mAysIP7bWbq3TX4ilZ6Phwd8CcgdZ0U2k3pmLOKjK3VrfWru5I78CxMBKDPIPHhroUfXLQQp1gW4lvh3vRU3F
# DATA juFK0fTAUF2E81ySmdSnZpgPsqjNn4H8ayGcf80s499kJvF4QG40WEan+CtAOZbkR37s7lTY47nRbYfZT8YQA+CDcVY8CMyJdhdx
# DATA UigFbPzMJsDJQnHUoQDaRkP4OrO2J8EvC6yunkGzn2RcVJJaVeumixI6X3ZaGO2ok+QYN7zfcPI+9ur7Ap1yPozGEDnJpimvDrrw
# DATA 6wzRAyW6OMssue1ahyM42lrdbv+hb87mzva7bRAsH3qrSzWUnbtyCasr27CYMDuqBi+P6GxeaBVXn1Ok2ysA5/Bw5lw+/7+0f4Wa
# DATA J0YLn2MWrYnDO6Li7pTTj+AzD9Q5plh91i7tlk5oO4BzCoTt8M/t/nh4YD+4lYFTHe5L6+nWeyknYEEPZs4FcAebUzsBXYNk5pvU
# DATA C1yApu4R/WGWgH9bsw97b9iHnKqldL/Ta/PdCy2o/bzG8879WbuzsXrz3vZOc+vuXdyLaA7TwrPqrTG1ovxOlcOQUtRamwxc8kqS
# DATA yVtZQrE/zLDMyNjaTG8xxkzGaYd6yTPQQPYfZCX+gKr/TnIXfJghw9noeJhlJhdyddBt9XqQ3RhlaG7xpHWa7GeA9JO1a8kapk0T
# DATA WHKuEEtiIFRrv9PFSFTGKSbEUfQdoLuW2vuozwZRCUEcRn3ecZ1cUiiblEi0Rl83+0M0T5JMtTSGoBThhp2aFAb979TQYSVQujVT
# DATA H+5LXdJaTakAwLPRjxVozzy9tGf7rEZg0mNh0dLU7sqe0A8KGkq82FlrkuByd2t9bXvO+nLcpuJPQFUveze5YdZtcdpTKm52QE3e
# DATA NUd92lCSycbOrwTnl/9hJ2/O9S0ebY43mMYC5l7B2oLjiDxA6PIcHcxXKFTIDayxk+ThzRQ3RHW3VT3ETHmXViDKxq0NAt24Lufx
# DATA Mh7D8RXYlYXaC9ci3MX4S9OtRUXE6AM+EGPvmGTpY3IsQc/X4hBbV+O8Qdv3DuvjQbi/oYgV8inC75utwWq7zX/dGvYx0mtz2Hmg
# DATA bsbgbrHnnGje+WkSAqBTVliXt5kUn7EPGpGb6skZ4m22BmV1nRlkQyQ+mDrw4+s8UjWvqpsBp3dpYS6ukifKAvZhwGh0Vgp11rhA
# DATA FLAI0Bs6cLhf8I85bPCXddREUjjIiJlPSkUNXX3ygRLdjM5zMj8nsJvAqSxuo3ruNlT9nHR31twpCrU4eXHBqCNXKJ+YCupalgPx
# DATA Lb7LDN5ZgaarjtowuGGx0iuNaGMBBN7S2kYLhnpXzHVr/baQy9RZS9DIyFxiGauMLqp+TucujnvS752Ef1Y1fj21Vu/gOII7Heb/
# DATA i0IPe1kAX3zEuODksoa2XtfXkA0LpXNeKMvz54m0s14VJxufOV6I+3RSYelsb+SVF4AOPZOHMANfqduJzVq1ZOqN2xZqORr6oNui
# DATA C2Dkpmll0xIFu/2pdXMotY1oXQ485jErjV0CmQQEKFsPgVgoFzUG0uFftt7FKlobUrAzZJKEK9Yirtt89jzquqnKaoFb5woPdS+K
# DATA JRxLt8FXblXUPya5kkbiZHFx7iJBMLmeV/q4PEOLIHI1nNOPRiU6yV3xUa+067XOkjWCNOGq4AMOasa2KU6O++GCj2jJjdtnyudr
# DATA l3PFtAtgsDRF3xFZcXQsflePy4Yle28ZYpStSuXc3cuYb/zKMwxosG43tQ594jyTW+S0RAxF9W1HpqIUm4tXvA/pJot+MTQDFsRz
# DATA jNSdOjF0k52y6Non2D5OG+reS8EhcTC7QhVIQSTCH1noi3Alzc3oNGVaWgiuOEKj9QI4tIBYzT6JkG25GBfFUpJFdiOmjULBWera
# DATA i+/xqfMGzkcvPlTH1hOB07byjyLWpj9RdCToJJ+QA/hXMJ8kS6v/o+nzulY2cL2NxLYNldL4LQPqsLX/tePsEbtsKypCVeC0jJ0z
# DATA TFrQEX4Of5bRNDboODk7DWutaLE8zmBDBSFmoqbL+26EzU058ICYhBc3bD7nLn708CkoDY6QcgI51mzp5Qy+rdkbY4zAZAR574MD
# DATA 2UaFcs5lMdGcEVupJ6JrEp5M68IcEfyIiIbqPGKLtQMp7MrK7ZmKdUWyfqYOq+qJY3+BupRQqvZ2Dqhp7Wwb6HCnNVzvHfbhhMO0
# DATA 9/zbwtFpokEnU9fQbNQCn5cShNNUEsgLoe6/NqxOf9QC5ZrqSGukusElVO+aBrRYamnun45wxpZg6aDKGvgau7CU/DB5PVleWrl8
# DATA 4cIK0gU2ox5dTS7I8xgLgDGyjot7kkjjGHGXtXNUj+WtwyzBUADriOAvaoU9hzQL0BGDZwOA34At/ahwgnBA4XxKQV9gQ68TxRlM
# DATA xbqk1+hRb9zt946+nYal8qLG80FrmGeFbXNKGyzECbTV6ULJi9T9HZXHqOM0y3XSORqKTEbXKDR/H4ysm1STWwIfk6x1UtFbAVan
# DATA icvZWNEEcqlCmen4xfKS+h/38dVXX70BE5MQwDnpXrv9o86BojIkFrr9Jg+HHQyl7/RGfSQcDMyDUMEH0GnVjaymKltwpE28eNlH
# DATA rWySA+SVjWRpQWe1kD3YV7u8BH/193/ckOGR88rwgxRH2lF7tOFvYgwB5Wnx1JcZOviCDsZ/TTwO+nKxkSx7SRSGeH0hjSBWUcM7
# DATA OOm8whyQUMvr9kTDdg2/VrfU1r66x45HGV1V01otxSx+UG2RAeNeDzdqL9zVCBSlcw9iN9Iomh33opPTJVkEE/2YU7jrCVOPmLjL
# DATA U3qlibgXYzhQT9gbrp9y/xDqo/3odYuKkyrRTFEPLDYXcDW9kRIM0HK74dz65LT9cb/Tg/ksXSDlaWwa7Yubp72NXpSmsmRK9aY4
# DATA gCK1dvQ25k4ZL14UbtSawmkwmPd6Wog3kppkI3M5EfcyAvlgT8LJ+9An3KFL/deWliASFmTUnGNdEUei2X+fUsbMp9UjPqH2pDWo
# DATA ouWrUXNfpx9w3B6PR50uINu+3xznraNMVrN2CPaj7zsUejG5erno+LVQCNTuODzsHEBOhwQqRiarxKwTgjf0NrTN96P3TzmV+TjA
# DATA /Uq9CkdD3zBC7DkIUjJkqS9P1P43oGfyv+8ka48OuuMcC0MKJNhAg2H2AGY6aY/J60D2fk5h7CCJygFCrjixtErQ5YqzsngWpI/2
# DATA U2TuBNxSn0qMB8eKAEq4/taewEjev0qW+svLy2RKWepfXYoA1pLhjkT7ItIzSaR06fh+2+9C+hbLWtRSd8QOWGj4s0py9cqVS1eL
# DATA swoBv8FaZqVUiqzkQzVjo+G4B6vRLsiURDNag6XJSthQvJyZlmoDjUwFZbm+Q0Ufx6XI67x2mJ/2DkpSTk1ir19yPaXwBNNuCoPT
# DATA mNRj6Y+FbBzeq/4ml0sLoWuQWnpndIqASyhvFLg+1TAGg10zo5iYm0iPUDmYzgHXsWG/Xd9cw+fZcOg/Z+mnc4Ixx2CSboFZCWEw
# DATA h6VlCDGS4u93ul2reE2DZGlIH3qON0NJsAgYD6qINhA60B4B4OcUedKFraw4ehILrGMN/4Gtr6gMSHA89NVR3CV+GQMcxaFaZOJB
# DATA ZmIKLut1u9M66vXVVj/ICYBKCqumaHMtX7107XK5xrkz0/HosHoNPPGhK7kSHzN1C3RUYV4lfovaN1fKQarHkpXY0QQPEK+E+IGb
# DATA /XGXJKtDdfElURmYBcp49hiMvtF746DJ4zSygRzRvrXcRk3OCWuS3mz18NKhDp3uKW4s6+y5rp0drC2imDpGXbYFjAT7Et6WNKGD
# DATA 1qmbKW6zSQ94p4jrI/jXWqNk3Rs02rWJFYn7AHRtNm1YKK6DPlBN/GwroCz7VbCGxGryXmuQH/ftTYFaUtX/ca/hAuMSbjIVahTw
# DATA KBuXY+SpMqLZPb+TrCaMAyBkcdJ6X90X6cAEAALwNemS6Iap+DoZUdFPxkpcUnUdZJ0BuM9wfQf94wyVhTK2WrKl5g5Cp5L3s2xA
# DATA onJk5butU/VfxYb7Y4TMppEQMBoqmAEc2GauBjRNBiq6u729Cvl3shA2L46wbC7TKQfDTXeGmYVGaWO/Ikv9tt5m2DG/Z4ntDsq6
# DATA cphq2yS3Ne71UAYKjGf/pqErNYolJscrVD9/5dgJnxG2qqWORVhw1r1+VIR0QYOwU7N6RlHWwVqFURm6p22F8DPI0YoPWYw2bl2v
# DATA 2Lpc1t6/nBMJVO/ZvmdnYLatrN4cP56m4E/NTETuBPoWYDmj2akxinaqK2eoKYYPdkUXqagcp5weumpxVySf6q1kFL8w+ayQLXCr
# DATA ofr2ot4EhbP6Z8Tx/XiO6TN6nGASLSdfmKY2ZxWzmKazzwIZzVVSQw2FyNzfYcTONDdX5l57oK7peKOCC8W4kx8jH0xa+zlwu252
# DATA 1MLUfJKN3VRmyBkPNBKtFiGcHw5T9Sfe0lhkyWvJRgZZG/OH6MuD3LKLCdRr/n1ryqmv7fI4UJI0LKNa7HWhF+u/hNjkjlH+WXRx
# DATA LZsOp+0EPKcv0V7GsGSYXA2hAz+cgWga1+DJLkJlFPhSiT7yAtPQ8Kjb3y+lF9KyR7GgywMJC/Beu5QXOnDEZvjYIK10Sd5otw8X
# DATA abY8bSKn4kIjauKfdZppcIZ4Es7rs9immaJS1FoNGLTOfm2NkFVwdEMt0jCi+tY2BViK3sIB/36KmY8o4smLX734pZgJozm3gcaQ
# DATA KNBZ2mXI3gTggLy7eLBYMgtTb+fgWaR9CmI8dgr3RtOtw6bR4D/Ln6lcQcnSclQekthdwr8kRJWTLtTwRHHsgxKeB7JK9Btnz5BM
# DATA B3cp2DiMkmkhRYJypdMf59Av67HiZKBWOQ12FGVpBn8FU7Ptk0Dv4zpiejen6x2ng+ZMBfSLu6wekWHSVdphsmivLOWbjpQuwIMX
# DATA 0eLq5QleKKDK6RvdOwkRNlX4HsKcEp4cJVhT7PUL8hoFy/cnzFgFbU7tnk/hUdhVezIwmgoDRBFhaVG9W3w0bCEITeRxVRICTOhO
# DATA KKtG80OZ6JBw98e9dhdwveZ2jbR79cps0l8ElQhNaeGM/pM3LU9lUr4ifGkSZ59JRsEnlFDDOqXAhQN9CWBCXTnv+WOEmoVqfoHP
# DATA ZBkk8wadf3/Gip6AU5pJGsrwtk9cgGung3ECkx3KpGTxYbVr4K8mp0R3y5F4PHWq/mWuVCLO3PxWo3KrQSNML6TLJv7Lh5FNhDrT
# DATA Rj9HAZvQiu2cTnCtRH2cktNQIulAAjNLMQ2uysmg/xDuff08hwAlEK0OWkMyS/Syh1ZldEmwnC6TTchEnR+jyPPwuK9akOummA5b
# DATA vdOEdS8QdVCzNDpUS4dwFC1kTxB9ATAXCdcWLFCqN8JEcK5YLhD2ZxylYzWI+VYa7F6N0Vl11Gzin+w7D7oLgPPPyGRQ9y0QGHeK
# DATA Wi41/agbhPYq8Otuc+vW3Y3bP0w+oF8iuesHG3ffvHv79t33XJIcxZivVpuaJr0Mdb4SxfqSdFr2l6TvQJ1vU9301e25xIcOI6/W
# DATA g5vk1woPYoP5oNs/PaGIQKyTQ/mm3GVPWsP38eKfbknFyf/z4e9QEJEEpsanH/aaiGtqg0kSdoHhkPhQc+Oz0ksVO83qNFOuSVkn
# DATA UrSzWElT5AjjrgbF/9Gt0TojfQBfeC3OZSgJwQOfaRG1hv53dA7j5BIaaSHaUl5rtQmfgjaI2USWaZrSCpp1W8RCBqG65LxjUJNY
# DATA moew1diXjL4JwP7oV4WLryjr+T+j6xmsNkEK/4xc0MJQUCj83xUFAP7oL+R2Y50u8p3dvp/lA0EAOEsEe9HV1aMLu2mCXwcMye6G
# DATA gCTs7cVqVceBm4byGWS6/hxx103A4fTGiI3pCS3vOWl99HMrnBnn8yLYQhI79AvuMyi5kzrqS1Rb8YCreh89ve6B7uJBBOslt8R4
# DATA IuEaW1Gs1mEG8EPcweyXCMi11slWSwTpF09JVeoLzD70ISl8BE3tcdguoK49VQw8T6rdVoDqwa7uf1YFPwEpQTXOn+BYKonxl0Qo
# DATA a+gcAlpDcChCr3EI0RMkpy8pJ6xkg31WCxtMiRbhEgUH/RPzDeY250op98hjQ9Hkrwh7QvCtyuFY/k+EDwe//T+p25sbf4BesKrK
# DATA sEIC9glrg04+JbL0YxkUcYb1DLMjdd2B+0N80LRboQr0tT1oRzedepiQ+lgizpMBxlihrZF5PWytsVrRqkHPiG/8vUgsl0HGqkSg
# DATA 5DSCWHXQyvOH/WG7NnqEwGIW1k1FYGkqhCRT4Vms8GUO/gBAGDfuy2Vu5PMTXhH17hC3RjdUO2CSWI8V9EBCF8sbbLQvuxHVwNGl
# DATA Ybq+FipSvGw7GWjiOr2jBpvQyo4bKjJmX7dCkPGoZ1C3AzvbJWzwN9dvr23DDAfCrhmudbhErCNodEcztTtkMtbybLjHim4U1kmJ
# DATA A+jdU8JJR3/Z+3IR7/Ta2aMZZ86LX1WA6/w8MS7pmm0hmnaMkafpnp2oimkYyZMQCwT8z7EIqWtG27jjmg0H7tSmFoDl95QJGA0K
# DATA X1tXGLEWmhd68T3LITaTURwOKi7oE+/KhFMFDN3pCa2iqcIR64rgYdReV/P8GOEuHzuymyEKFGYK6i27i1yYrwuPUznLsWYSxhyo
# DATA dtOGlYxEznMKwN/z5bDZvSuWicIJhen4V5eK4EibeyYYVM5Twx2hZ7c3OJsd3inwOkIOcpTN6vHv6XhGmv/HCPBpnQWZo2wumphO
# DATA FxbCqjcxQQPzEodPIEETEVqhxjyJz+x03sFGXAvOzsUAtEgdzTW+1Eou1936pRX3ZJm5h8OYLFr/6HbmBSaKGPcEIKGdzqrUIoBg
# DATA HOdY7nnoPb6sROmxOufa6mbUhZvcGqIFNrqIsqstw/2ZNFj+WfERZ1/4ELVTOLQEP3oqeV+ePwtlRmnl+2GNry+SUYsxNqsXFlmM
# DATA BjrFAB9Xtozmmnn+rALaKK27o6+ePf+MNPt0a3oa1cqFnQVBiOfj3+eQRwkflqlfLvHTBE9KqoiIHnraH1MjMJWfcMk/6ThUJ09E
# DATA KOb+3rpwPOUbzBPVt08xGQYMHDv0GV8h8CZiZokvhGLDV2K/aDej2jslJgj4wIuf10zqVeQDoDbUcoqVf4llGOEVcekFCdNIL6TK
# DATA QWxK3rXosD1EZ9Ej/Lu2ylmKN/GN1gSpHdtoNpUM3myWrS/hit6UxMaltD/IhhJmdHDcB71Ig4EMAYwYZWFQFvYZnH00bPVySNyH
# DATA WHog41RZ3MZv7L8JaQ/y60IggSTRbA1RrEaXkSoHrFdtiCkCA0YEJfj7iOCAibmlmK4iP67SVuJsnJ3DU+uBw7IATy94yGDkwXPu
# DATA PHVtPDiSLG6AwdkZVa0UoJDgA7Tq1iMBM65aqQbBWGV5TWCDrDr1Hosrlu1jMWRXHl0TTTc0VOUO2JNV8Jo7H38p46C3zmSMAMpP
# DATA r6UBxTHrLln0SMUozhBRKqtWJV73elEBCagsLCAuSFObMXdGm5w9Wby4DXMQTW1F47QVd/YEgQoL39PCF79nwqIsM1P7AmDs+ZSa
# DATA huzgBEGQw6O8AUr1qWNTlDatYxSealajsKS1p6tOtHZBebNv2FrWSGf0FKlQfVZF/BX1YQutao0UibpJGRenNol4rf2vXweAR1ZP
# DATA CFXGkF1RXq49a4imzJytcCYKXQGmCLs+9TsGrQw+pfRi05olTukuSWFbfvWYrWc6U4iw6jkX3/mUdtt8vXQl2qDLy0sztz4eamaV
# DATA JeFcKulUnfWlt7PX9lwzDYlVit9Kfuqy7SnPZfEfKG3l1oVfNS0HGLhFYvAFTg/4ESF1erHEGuXDyxJqfSahwWyVwocAGwixcpj8
# DATA s+yphKzPtBHLB9fFptahy4CqGyaPFaAkP9w5lsqT8UiYJRnElmi3LH+OspdhkZLCc6JtW4Clu0spRUAZnZs6tRAw7eEQejEaykUn
# DATA /RR8tgQIN76IlhBnFhGco8mZGd+U/MWcXiUf9XV3HsTI6NdVSYI1n6PHlqhRD0krqNFHhI+DzPhd89fbMmVBJl9QkQGew3xIXIj3
# DATA ZUCnFCtYvX3bRehyzIiSBQsvpIS/Yb8eGMAxdIJ3Mj3LxMF2gSmj/poki9z/aF4MJ6bf6YSGXTajiILUUwavNkBwYQovGN20UbYJ
# DATA Q41xEeabTXBwiGUGm5MbuIvozB3vyVPIww6RF1yKdlevn04nTvveYaaXHjThZUbxEDWDVDG1Pv9ycC5iZxCNIvgtls6aStqg7/lB
# DATA mZmt18U5p9YqIt6f0IHpw4xdeKwzJRKUcU6mMfXqZF2/uZgdySHF3GGfZxHdu6KVHDFXjY2a/KLJR3IeOwRDrok/+BNzOs5OJWNq
# DATA kuXW7IIfEK2XyvMMKnY3t2i0ENJ76hANHZ7v4PGu4PZegRdNfuGcyFMWtWiOp3fCv/XbNh26LjjdOA8fiFzPfR4jnh9FG9hmCSR2
# DATA IZoHVzcf5eETbk57tDI6ImmtK561yPAZ85mJuXE/ZVIM05CZjuBtthxhYHzvbMYIyAaUdlhG4LQ+bWiVZNYIPDdcckXu9AbjkYNe
# DATA g34/dWPyhMsfucDWHW9DfBmXKSkuzTDXKdwXIzGsrE5FZDZNTeTkPMZSc1HQXFt2anO8e+cjV//KMWubFiq1wn1LHXDyXmBRqxu4
# DATA GBVrC3K/ZljVAUFwxkS5GkxrLfB5k56fi6VohW19GvVIqdIsacHKNBNlo5JSAIh7xlgDLen0HnLpJpee1tOQh+AP/nJGt4xW25fC
# DATA KpBnAdGQpEiMNM87g5xWzO+zPq7xpxzWQvlBxpepvCF6S47c3q/HE7HABUgN/Hrc/Q1kf23Ds5q1Ea335rssFx6L2rYwlURo56pi
# DATA pWk7U8u9lEuIfhC4ezi3oIiaQS+h4qru3zK0RSfM7xNv0uli+TwdEHvGnH2QXKzfdDdmrpXT1swl08xzDp3BzKZR6Icmix2dKQpT
# DATA pybR8oqV6mdqHzixlFmDWQJb5wQz0OanBg9A/V0jH64e3B9KS1YGhyby12bT2mMc0VsO6tQZjVxM0EXKlzbFwcAKqpkHGhmCoT9H
# DATA R0pMZxvGyumOSPJ6/FEaVCTjnkNs+jPTVQpNdZF9rlvvdQjalSs+O1RlHF8//NEkvlgK2YGbBUqzYjd9FFG9UeUb2P4ZJEI20PB0
# DATA EbaM70tzHbc6fZx9lExlb5TrzBqPU7CIBUSSB0de2M24+d8rBIuqG+317XeRyY0uhP3Qyb7l63+/zgnlVrEGQGubEIJMCdpmVDPH
# DATA KXz95c5AsZc7AnOQ1icQPuYWS0SJqO1fVcyPkgZq7Oe/Nz7T6CjJWazBMfLZ9DwMAai45g+zbippPdB6curOGPMIytq5Pp0Pokk+
# DATA 5SsgrTplGzfcPyxFW1BnVGyC927JflWOaWzrSWegZhisAbXOQEu1WsMDpNY5GNnIBUWThGioC37wSaDmlqr3CsCO8cMKpn0Jc70U
# DATA haH4woXaHw9I2/0AbtkUmjINyZpqsEJYiq9y6PVxDhuUl/dQbGF1T+GTksmwbvHQSbhkbDu30XnqsRyGXG41kKCtSmZLwwsLqt0m
# DATA klKzicNvNoFIm02eACd2jHyCFizIphAUCLCbENOnPk3okD3+ry9+qTbvJxR/UeBgNjMaAZtT/AUTI4M4Q4AHFuQSAhhtn+aj7GSN
# DATA kpLbgyi9C1SBva8k72Sn/BdAlfOfd7f5D0SL+Zvtuxu3EA4Kn5btuMh1VM1g6qdO76A7bgsaH+ZzyutJD9EfcPzJMPsxgd9QPBiG
# DATA ho673QQaqH3L01dLnv+biRp98TFBxzCUhw5eqbhoMr+iqFuLL1Mci5v07MWvAPXsXKvxX/7zf1P+pzbrfhcOYLUba4PTb6UNwH+4
# DATA evky/qv+5/+7dPXSJf03Pl9eXlq+/F+Spb/EBIwhVEQ1/7/o+r/66quwHxWTJSO1BLFi0KjkoCPdXQfgMYdZN2vlAOhFsdLLtZXa
# DATA 91ZqCws7x+CNbhfEdJLJ6FgdNwicyKFOCHfbOYLUG8dZd4ARVcfAhQCSU73tj4+OF7CQvpckOzc3q4QXfJi1AI8LDcQQ7W36CMpX
# DATA eHrcepCp3mUQIwH22HZN9S0bYiB5W53M+3AiA6Zcr6+N7Af2WYPgxI+ygzFhXABGHAimhNe5AJjRs062gA2lO7PGc6zONrvT6V+I
# DATA cTmRZgc/zv8D9v9rV68s+/t/ZenSf+7/v8T/0nGesZyeXl9YUBshHyVnyeawk5+0bnY7eG+nX8kEQ3NwW5fSvx7gw8UDLJOWr/O3
# DATA P344souBVPMw2ydLRVm3sH3z7iYmAbuLCScRs/jvstIuJfDKcefUBfne92zO6wBvqGRcDi+QvF9BdAe/z+vsdV1cAG4Mqpo96OHh
# DATA uEcgNMNsnMPpWBr2H5Y5XZmkx+4/TP7qr+CfGmdzc6L+7YYwfiNVpY06CD7LHg3UBK2O8NMeiGYffJA4L17HjLW3QPIvl4Pv8wN1
# DATA t8hriq8eQRi9qoTmVJ588IEj2s/1zcVkWUbFRVnQzN0YrDrlinE6xTWBCHpawq+TxuvRqvB3Wc30ZGGhBTgRiZ5xddt80IErTYmo
# DATA q4JJVyRlqawBKP9eWfzR7lL1e63q4d7ZtUlV/315Ur2sf1xSL659r7W/5zyRv5dXJt9drI2yfISJ3WH+ITOJNXGQEaR/KAlTXyFl
# DATA GaQoSaEwPZa5+35yaaUMSLmKMmDdGMZ0vYf3fzmn6IBR37XVpum0IHvadcGNVHTDubinUpJdXnw04XIGrnAJTVutNehg7vq8Buhu
# DATA 93qdn4zV9TF5COdgXW1vHO8kmXDji4vJVpaPVduYEDBp4YFdxaudoMtVxOUEmkMaPZWMZJBjAYbTB1TOYfagf8Dn6GEy7Bwdj/Ka
# DATA XjbdYUVmr+j9JU/LssI4+f5UsntbgrwkOThu9Y6y9nUxeqI0oHMbOdAB5HVOQ6VkOl21nFB7w8ygWtCCKUTUcJg+4EV1q4dEm7Bm
# DATA lUR2bd1sWvhPrdd/WIL4l+Wl5EJy6eoV9d9rVy/jOQceo7g16slurVajDcShZ87a7IAI1e+2k6NhSw2HrnkH/aEa+aAPOUIgXy/g
# DATA CY6V2KTWARG0Ne5gTa0tiBRSW58SDbeAeloHGn4QMZadRQYZrIN0OqKlxjGyGBRbUPl7LuZhzSOtRMHsi+6DaPcM5nxSwZU449mz
# DATA Jm8ycZaZmbU6kmogcZbOeMnUmTeEZasj4wX0ni6E361urluRWJ2WWsw7YL047Pb7Q2SgRArtVUxrBFjYmEx6GRdTf6i6U8Dh30jO
# DATA ALuxBdrwOoCdZ5NEEZQqGLQkH4cNTcrJpGK5iQITqqg93eoe9dWGPT5RI3l7G/wzkIamMNk3+8N1YktRdlsxud9tzhs8lA110G11
# DATA TvLrNoy36hY9BTRctQrkA2CqME2d6e7DduAB7KkBqK1wAFBqqqrFC8lq0u4cHhJKMOrnEQ1WsZz3FcUbtgpJjXLFxmAvCgnXkguL
# DATA ycSxIHHfFOnSX2ioprMcaAFe8BHA75FvNuxzwDoBcX99k6eS1aizXwz/n7pzbNYvnB/qqtuj0TvGnhdH8CnrlFTB4WzVo89oU9sk
# DATA 3IkzznekVuoAio81SkWKmcfaY7U0ikkLrHVrePSA8jg3AAVf5ofmhWoHSEG1b5QYcuYSZWQm+yRZAib9GNIolEjmfaNGVb1LmtY3
# DATA aiTuvlHLB12419VSQHJO3ngDEmO93khegz0eqJiVFDsYQS5koMeSlo0Rg6o1GCyiCp+GmC+KYM0fVQdHablGvdk8KpfOon6TahA9
# DATA AuHbRsKs63lSB2Ht1urO6o3V7bXmva3bFXXDf1RPVioz6tkhYOs7na6SjeuK9TSXAI640+5m3qtL9CqobwJcKT84zk5aNHLVeqmo
# DATA W+VangFi7mZr2FIkRWH/+K1aWjW9KcabHgBPc1sCDgqJshS1K2kgAseBTdv3mRKvtU2qwmNccDNfArnFDjxK4OkAm+n8HQk6ICKB
# DATA KELsLbHHlYYbolziZ9MYsT1Pxqi/fe/G9s2t9c2d9bsbzZ2776xtNO/dW7/lFl/d3GTDfyVIHDCluq21e6rLWKlRqNZAoiiRxKX2
# DATA kZfxgHT/9JZDfK1PcUplA+I2U9y1ltFUFkEDP/8MHiHOINjkNVbDLyx0FjTQfY4Zjw36QYDkENdC//b579DGF8cw9HF3ahiXJHP3
# DATA qDO6iUbzZFkdS9ZIGc+Ox8qM+LvokIbbqUS3HdrhcLT3KVXXmSGBSowaKnJPnlxf+Avof5pm93+jquDp+p/lK1cv+/rfSyuv/af+
# DATA 5y+l/91EOcqsvXjNYrYUULOqfYs3ikB94tyysra6gWFKPbYqAae8ell+gSJI/u7nC4hnDr5B3c6+mKHAK0GKDDP5C8yJ+m+d1kKe
# DATA jLKTAdzvqMLxUB1J+xQWKLWCCwgc1gu6avLyZzACctFC71j0YCYN7mF7HpBMwcQ0vzdu3L57852yyRIIWJhtShHYhgh1Tg1FeQIt
# DATA OyahiiNyJmCK03sv4ZCFnAeFatvN9e2ttbdKNi61A1Qt2TghzUws74oxTpbS9Y13V2+v3+JTBdAcXKQmD7CVALqkIRCLGRj+bAmn
# DATA Sh3gmXpaKk+iyNlLr71WntUj05PmHTitbqw1N7fW313dWXPg3fFo4gk1aXWu+Gl1tAPeguMYTiuP/3WyOuETJpFoYSddiuWCgG/R
# DATA 9QGXoqs/CBdixiJIXggi11rgbsidFjIm/x0CopW7v/aZKeyuKSk9prA7zlnAI5DfMIiVpcvXMLT1/n1MEWSXhSDD/rBdOiiDPuwS
# DATA POKfSkpfXnmNouvsr8rzTAdFv6I0haXZ08ROIIUBcNwRuBFg3G3oaCGTSQhDPswR3ih9lDI7owvPZunswgV2dpCoTIyQCCNvJ8HO
# DATA NdVJfvHzp3SJz5biPKu3Za42Vt9dXb+9esPZxhIATEGldqsb9GY7G4ECx84SL6901LBfmwa7R/Zggxrq5mDo8IxZRCk97ueokN8f
# DATA dtoY6p72wP2w7CDZYxukEPV7SynnU7Wpu7SrIZm0P9PSv1gmmHR3tfq3rerfATK7+bNZq+4p/qUIdZKSYu9ck86R2QWTb8gzSSFY
# DATA ub6I6OUaR1EDVzKJotOW/LAd5PRk8AKBvL95dwvdfAmkQDtv2p5KVvv6T8gEgv2w9zEFkGI8NfdRXmFd6jxVVcipaliDbEP1poY3
# DATA N3u9VWUIdoPh25rNQFEgBZwD9Qx+i25Ofgvepfz+yTij7D7w43DYOkLhQxdWR65uFXGeqTV8CYe/4g1LL8Ny3IG90pCx6EhlprZp
# DATA db+9s7O5zTVvrf1v99a31m6lzqmjdbZDQ9YVqVpx+s2tuzfWgI0pMYv0FpIGWV0mVsej4/6Q76T1JL2hLtSKzSDAmX/9e2/13bXm
# DATA 6uY6nTTqeoEO1dFSeiYYVPM9ANXUFEyKKe7FbvqDqrq9PGwN21kb/kK3sVTtp9qS+n/L6fV4yc1hX3HrvUTPKtyWPK0lkDoKaNAe
# DATA jb21jyuKN/RV+PsmAXB1IRq7orMX5qRBhZB+uqDhdzX8L5S7BlpVdSMX1RCr1lC5nmdav3aYAeOYMUcMgqzYJw8UINnJ47me4tVX
# DATA ESXoolvdOnWDfpAWDg1b0nCt/77Yk5h+KIakdQAdIL0CqF1ByGssAYTHuPd+3tjdgxfAhqnbJRoOvkWLjFS/32+fqsmEzy828DWb
# DATA sq53Dkvw9PXLFzBLC/ynfOZM2vVIv6Ri1bMJ9aU2gLSaN8agsK2BfF7C5+oyPNHTjO5pDfRKo9zNXFy9PVByMFVUro36pNdCaU4J
# DATA c2a6yFf0gw9EU4u/X2k00j5altFSR4Vqekm90vqF9Vl06q0hLug961ahXkwE3z45O+iqPSjEh/QIY58slJC4S+XG65qYxdjdoGVD
# DATA zr7YGnQWyRi+qI3h5etq4CXuvzwVV1AYAaumy5EBaCyV69IsG8DDVotM5da3qvq8sToctk5rnRz/5Yj9vPyGGNb53xr/q75VnX/F
# DATA /QjqKce6azepPoNyu0t7b5BGfO4eL6YXMZQxu7e1flOCEaQy1q4rhlMulbXKSq2Lr6+ydEnkE2nBn2jE7ccAsKe1U1DqS3J9JAj1
# DATA T+lpVDOFh0MlUWUQtA+yhlCuItKFmQYQW9xGMcWUSJ7uS02Zr7ZqLF8HLoP+S3hlUAX2sxJHQph7AF9g+NBRfIVClSviYMUiUfEN
# DATA KrxkcBv2DQMfTTssN1ffWmuu34H/hvIUXq3l6l/byeBi3xqe3pLQkhKBcEAKVcn2hxSBQ67SFfyw31UM2kH9lxAnelXm0GlRiUFU
# DATA lukwC2akAkVQ9jRyHjRs8Yl0pJHzF0s5atSYyF7ilXCSI72M4B4k7UBbWKTy4rsIXf99KZv/tER/Ksh1m/yWsYRASFwmS+ceQlBl
# DATA B5jkGCLiqgyOjm7ZvQdlTZm7UOWewOFBcfgvikoejkrguU/QD/0cVQjOSNSFRi3ssKQHYm4r5fk6zwjs1SqBS1arA3X7wKtOxuCT
# DATA Nkgc9aIYFKNoDvC5WlAksNRMAm+56FyIb7p2Pbed1K3Msdv6T98ZvWjLAtWv3ry5tr3dfFPtWBBvKXMh3tOJ7YCe0CC7YP6QIubD
# DATA LSqWtUVnrfpe8eOsDTr2B3Cjlzkh7eP1JD9uDcn7I6EkKooDnVqZYYH7WY7vlEYKbhALJn9kHHKJ87K5EEvsXK+E79jmT+vWyNLI
# DATA vlcFcMCTBcmHAnWZTgHLwVxYeUkisKgbNsIwfsvjJpgnwYeIVtQfHQNkfEE9blYovstXEvzIJJ6xJ6YGNQFiv1zyX9GpRmWuHNAK
# DATA 7AUDyBHEx1mKS6Um42wykROEBlT3UnvupjZ8C1wYzi5cEFYscfv2XZmzOUq6G/0paBouXKDlm0Quy9bUGfQ3u2KCtDhL0WFKdV0I
# DATA OoWxq9/wz6SSBGRTYZoxR6V/b1TP7F7z+yalVZu9BdV5KXqIOxACfG9j+94mqAf0XTPUBEEuIRtMSwPFVRyUOIyviyl7KgasWj61
# DATA ySIM0KKEQXA0kPRMIwWtDmoKZfsjpKs5wAH11NHyQIdsPZM+lKwW5eUuhI1Jy+awoudOB15pePxnzum+eXfjzdvrN3ci02zPLkbG
# DATA namzbQSKjq6iFcokTc3X5Rtr3lujUQu4F8A2hJSBSOCppORzc/ha8yCV8BS4I5OXYT8n0wLfrI6BA20JasaLnvo2L+1eMG3CJJfL
# DATA wW7WQ8DwMi7tOIwgJAzxhz0nExgy/BK+qYgPIEca1hdc7qWJk5I6MWVavEWtBSR5RHtVbf/qZbYc4He7KUU6QLovz6JAGPfkfYhK
# DATA M/6AeMJegaxIfYI2K/IB7u29oDrOKvoX8//nKNJvPAxouv13ZeXya5c9++/K5f/0//+L2X+3T3sH6u7dA2MhBKeQp43redwfdo46
# DATA mPC1ZWdeIRc8Aw+P8hUKfJjv5tHIsu7yE87cKcbYw4PeqCs/AHZQfSE/dXTxN2pDhgv/y1iL31n7ISgot+/daG7eu6EYffPW3Tur
# DATA 6xvpwur29vpbG3fWNnYw8gEFEUifMkx/VHqjTu4eu8n90d7F8hvB5/jiQqN24buQeD6r3QGL3kG3lefJLdyOdNSYU0cD56t5IYbY
# DATA 6w9PwBmJOVahrY8PX/saTqyRrXz0dfJ6cmV5hfwq2SkL0tjez+/f/69vfOf+o6Wl6v1Hy4f3H712uJcyCwuseHbXUxpok1XrfDx6
# DATA ZgTm0ZY9gp6ExggrzrpQKT+nLYHBRchcAFeUSnL58qWoeeL8A4QvaYS6khrpoUppp91rpfo8Kde6kM6UTdPO7dwJsOc/S1CdE2Vs
# DATA iMPCawH6CI/teXsPKgGgCWwLrL5X0Jqb1nSCeByfegT/qoG1KdsWuERC5jzMGGz+QoOfly0LVNTdbsnLl6x2zNIj8Ya9+AH8pfZN
# DATA CtBIw1GZrxJD3QPLETOoHfE6whZ22e6nWuI/0ep3dXkib8pvzNXeS1A957wUW9Vuvbq8J2RMCdBkItFyhdQv72RduuKqAstyeYmW
# DATA pZbK5Qp+0xXQ5NJyxr/IA1+t/q0abK3599W9i+rRov+sfIGmHdKcnX+kLMAhlZBRxHK4EZeaAQWNOHKbnRYUG7e5WSTtJ98tDYIJ
# DATA MAJ4Mk+f1e1o9U24su+8nUa23zfhBsR7FIBcNvqjNwHxxduq4F3DM1GPObBqJwc9lm/Vv6h0fgejpZXLyQX6x3rbA0gmWI3lMNGv
# DATA KXV+36GVlejFbL71xYyErVHL9xmyhnAxWS7bmw2Kl91hvhxt8XpCfWoz/LUnEcHm6IL+kDxT3O0gvio1HfAMjPX9dIa32ntbQpQ3
# DATA t9ZWd2ZRbEXuHEX01bpYQF8Rt7RCYtOk9PVWMVBjoywJMTQH73ObFX4GY2uu/UAN1/q9cSNQid6Abzu9o/W73hYt6N+9zVurO2vN
# DATA G/e2f+hoOuWT007WbTPf49W211a8khD6A1yS8hIS41THJE2ahA1jEoNhnhgCHCddCUKxm0IFOdOKp33j7k7zzurG6ltadaT1hVOS
# DATA Ytvs2qRdD3i2eeUwbtOCUyYO8XYeigH5C3Nqx+AhaTUQZ8oq40JwLdjs0VYwQcWMOSRSx3Ly/QayDnxZhl/LV4vEE68uFtDh8I4I
# DATA LnRAo6PScmV55Zp2VHI9r7DZWINWYzzeoq7za+z8tZekF0lkfmaWVfLh1UkQCF9YYgHC400WDMAc1jUxGdGxi5S5EDtri7/INu3q
# DATA qYx/CGhxZApj0Qj21kbFQyEwqdiWlHu9TgzIZ/oc3rx7Z/Putqe2jXCW8HYXzQlfjqr7ztm8EYdgOXdhskBfh8eYO0XmJf1e8E0J
# DATA mjijGR2ilhccEZK4b7PEE4fKxQyKXhpIJ7M7ugVZ2R3kBdlKd/diTTles1xPFGvMb2lX/3DrhUkhFBB0vwtyodt1Rei5hN/uEkD3
# DATA nqfuxXei7sZrBD4JrTy0ptLEnuwIeeAIQpTDXUlCl1Zejh+IAGQgIJl78mQyFYmlUPUBb/u02bRaA3duJ/cAzHxhGbkmzj/qpo2S
# DATA BgMj0biLnjOeUrfsHGBcSXErAlXHBXfVfQ68SviW2FDcbLm8u7znOJ8LFt1uHS5/4Kn4qir3avqqRUc/GfdRNKCCS3ZGl7Y8xoGU
# DATA sGRFRFbSrne6+lMorwTauu4Cu0pDtOISq1dSm63Au+8neK0sYU1yjYQfdmLt9DtpeW7G4l4O7Zmjbi7XVbt7EYWFFANlFE6qOgdR
# DATA l/YdUT5hRCO+ayyXcfKtubadtJisJElHaRYZGk8X7IEhR9oz4dG1565vSKNiCK0wDReaJKyc6HI5Eo+qYAeH/aMLi+SQdVrno8zU
# DATA VyN7ZICcO51h050ScpNbTvUxA+wUfm75lbim2bClwwS0r6iAhjbrUTcJmQcqs6u+2DOeSnbyHOd8l698JerCOY91JkVpjLSJqNdg
# DATA yfkoQ30g67hrnDWhvBCnC07F7JCH1RpVJ+AIOjeDKBgBcWI/BV0t5uXy2kTyqFEVxA+EowosJPGF/fSkk+fo7+NsprMUB6tEOB60
# DATA uqhQ6KJ6xD07zh5JA5LUk8p32hPZh8buwGErhOnRwBAARtKCmxDfNfDiZG4L5o4aXpqdu0rB7uawAn0lM/lJCNmscQ5GYfNPGkS4
# DATA 960JpBYCnYstzGEllrk6z0b8EK9JsgToJDVAyJMtWYNJTNtC3+6GpfegOurQrlnHvfklxrdXN95aizF2s6OkceozZc/ynoXU54i7
# DATA J/024Mq1jfz/0ux0Giv1Uv6xOLtQ5BgzhTm+pFRrdVa+jhLSTEn3XEzaF4Wn8eIYP5a7Y4FIXdz14pOyeCy1QX9QUs37oUKB1Bz1
# DATA 9gvrw4NC5JDC8jpjnO+ARJUE37FPAV4Y2+OTQa5d3rJeDs5Erfyg0yHFdwXzt/dGjRXJlD2H2yI3gMwc5n8/TQMHhdhBinvgFfcm
# DATA QdKLFvQsUZntf9BYwTIWUh930K5svI9BOVhbsPa0673iQGZqShra8MdfL0yjJM1HXmpA3G/4R4fhgEsuL436J+hUbNXAjQuq0Cfy
# DATA K3RjDhsV3qbvzs53/o1fSs9zsOhMW6JQpAf5IusH1R0ylnqjCgMDMzk6x18uleE0dzpC9biaO3r29VS6XC9lSQAVcWOp/xrAjlBm
# DATA iJw0QgWONSbf1Umr1zkEKYQzYRkPw12ne9HkVpK4CB+a/PWcOgtTLdp6kOi55fnxmoRZniRmVVS2Raa5GpkEAjv2tqKPuaw3PkGw
# DATA 05IQjZm6PS9T1whdoC3FR6hdNw2UzKFbjjcUEVkt8omZAHFlgY6sccc36HlkEavRgvksaCNOWaU4TTBAONceaBQWptduJnP2l7xU
# DATA kp3N1VuKEaOVZ2v4J8QBBmso1DEEN/Rcyc1c53mXilCZLM5VL5IVvJmfftCjLXfcI1X/wvkP9tjczr04xrhqMVV9Dbjg3Bf+/4Es
# DATA 7vj/nXSOGN/vG3UBnO7/d2n50mtXfPyX5ZUr/+n/95f433deWRznw8X9Tm8RgiYGp6Pjfu8SRIndHYyqik1wzlcIHW31DFxmgEvq
# DATA QEcCFqfnFcjudK3hEfrbLWivwMEpeeOBJgN2rnjiyW8K5P07uA1+bTfAAD4GMh8Ikgx4+c32C7S9CBdeOsFVFIqmndGUqhPNxPgT
# DATA p+u2/t/23r25keu6F83f/BStkXUamAHAxzwkQ0ZkDgmNGM+QDMmRrIAICgSaJCwQQNDAzNAj3rKk5MYpu+w6qfvHrVOVpHLvqfP3
# DATA WJaskWTJX4H8Rmevx3727kaDw1GcHE1iEWjs3s+11157PX7rQLC9JBLCGgMga1XafSxpxXyZVluqSFmNKxSwJG+FMt1LBbyyxUK2
# DATA xKsEtCABy+DX3NUYr+q78IxXZaiEfjVhSzZ10BzfbwyxBkH/FhjJcXuMeCQrCo8En5iQJOIBnIk6rZm80soh2zfcdHuAQm8wM+lY
# DATA SXR4OK5tdzYeBbddTG9cGpxyLjLdSMnqxHAabLco2VOvbMJsABLfaDKlCZueZ8yKtPt0DGVazVCrcZdqKhkYD7bGf0u+mDtlnK+x
# DATA Og6DqR6KnVmDXWjeYIoSJ0eG07T7PSEmxXqjuUFnMUdUYuDlpcFS6LGKpZXhFC+0naUWFhMVoa5a+o9S0iIZ7aDvOtcLcjSMGEKD
# DATA l8ZOiIVySqxv7gLIilEkiYeThcVSmj2yd9gplrMTaijZOfgDvdVUt3+pWqbUbeS0bjlFW7eaq3BBTgU9eeqAnpx9t6AnORwJ6VlB
# DATA d71kOyszUZW0qzSYBG/duukMuKb9rnGq3lgqpltPVOajFG5B60d58SZDymRcwP8aJAUKs0diBoBR27u1xGHc2bg5Je/v2Ar1nMMd
# DATA ajYh2VvEF/CJRKlYpwyaSLFUa+MQR1zUgqdWe6JzGJ1G+5qD3WSYLQcfiBbf3tna3GvVN9flMzbxPsJ+Qhr4M7dHA24y0SdlIwOR
# DATA rmVECaL94fJscMEJOowjnu9LcFRAmxeSGQblF6x+UjOvBuvIMiQmWsy+X+3OeBjHAWYoUMHeKoRtMkTA8w76VmKuR67sZwDDDz/J
# DATA VzjWljAIxHMKgjmIQPAlX84u4aO3Tw56R9PhNOa4XI6ijdmTGd6SGkpzMiBAHn/A8sazGtMjBbz7L8cMyV8wYvELRj1zr1naP+wf
# DATA UlODnBjcg5XjjOWhSjYT3SnPuvmsLCrwWG94SctqdjM21qEflcB2vVajYB7qjoS5jz8mNKH+1rtMLJdCvlKNAOsC0KxH6dhdXtat
# DATA NqY1RvYslXDqcYJTxgarrJFNmvD+W5AGwPK7F7tl2p9oJWAcEbCi6KY2Umv0OjKjcStmQj7ABc0h2GxgxkJL6vwxgmmrqoaPB2jw
# DATA wyorYy5UJZeapSbljTzujCu94WJ/OAE/6kUdLpyAg7GcXIxJIFKGtmas7DgSAkiP71F2pxapU+Vl5flTtceCmjT1uhIRkp20Qp6T
# DATA P5/Npj6oPP/5iW5j+ourZ9ZLPJPuJ9EJOKj57rBOBHkhAT4g8QjkvVE9UIHzFEgObSSNw/IXWEhogacXCNh1MwTVabeLh6Kzy4D4
# DATA pVoVarM8Htgbg0phNHOtL/hPt40NV+WIMrpfVF7gBBUCwcZC7Ia8mSiN1AzcDfHV3ZPiUaFx3XipSYawGsWOd9ojyCLWGk4no6l8
# DATA OCHcqdryG0uKafI4aVigCNUTZKQq5Rh/En+tOwU0bdjagIZlDqYgHOEtkjEy4eMU5V8GQoknQ/qKcCgSDAUhXs7A7sLQKYa3KSWe
# DATA Qd8v7DVle8R4JwOIJ2rHBNxfsBMehZDfbdo5DowbAySYvPjF+aeAkxScf3vx8cVHmJUSklh+evEJ5JgMzj+VGSpDB2oeXOg/GAhW
# DATA ERz22zhiRnD6CDMDs9TBL0voJwRm+gyb/cP5c4BvolacxJbJtiBTCLjfDAH2ZNCLutigAQ8VnH8h3v8Tpsv8JwAxT9ax1h4wxCiA
# DATA GEkZhzvabUcnaB4L+QHCWZn4U5/76mQe0WZXJ0PVg+9/hamUf4GJPD8GtCsxM/78oeIHz0QXnZVV1Ih2WSBGylBI9E+GDKIAQZb0
# DATA k7oO9waSiOQjIDSG4zLBt+QEPE/r6m8Ck3TOn4VuzlF5oUhmrS0chuf/gzJKi+n47PyZbK3wVG25syKTyxeI8AUd+yVmnn4GwPgl
# DATA 6tVnwdPE9j2rwkMY/1klMNNaywz3n4o/n+LLgAwGCVQvPradcfXmEsxCcyl0EgGGUyCMHlSxmK5ZiViQJKSM46zlCwoBQ29Sg4f1
# DATA 6XLtQefYvjHybMPqFmB6n2EWWsjU/fvZ6GgphG6p0Bquv8zI6pKMe7a5I+nBMGgN58IOICk2zVlQRaUOTYY2wg+FomWqS6jX7OH/
# DATA v1Ya3S8VB3qhiWDqUJBWpUAOh9GsaN+XWYXj1Xs6p6LDSoxKNNGQAl3rYcVxB1m/cToQ6ElOB0FcjtGVtRGWD/lN+K3YbEqsELZe
# DATA UJxSi6yBDI2FykJ+RAbeFnkhqqzanOvUdz6LxvpRNKoRMjd81ChW5ibRhgdflgWIpNPfFlKBqnXveSORrMVhSmblD6QFT8crJUO0
# DATA YIclNitKT1xWrZguqR5VLYnPpfHM4ClMnVJLMpfiQlqQjS0tEcEwBFp4nUhSCh/l8mBYRtXACNMVqGcAEYZ8CPO50uNDcE3EM4s9
# DATA RGCFQexyjRWOGLfg+OZZrtlO6A3edVL37D+Lnfo73px0SNq71ZPQJI/AsmBi4iMX1WRerFCuAzhNbTT8WRDzllcsWOwqXUHx8IG9
# DATA 2oquytwDoMYfm1bRBmeub8orlfUruvqFB9NeH4Qf7e6n354TDszW4LmAYLMh2nTDpKWWbToV9y2lPdTcG1bUtU6qsMuQbUzU77kF
# DATA ni1Y7lu4kAaPKiY9txDeEnTT0myKmQel5bQynXRwyQ/hSSF87f3XTl7r7r32zmsPXtv9G/Jt83p9NapvsKJpDtcsRHwIpEcYOGRR
# DATA FCruNZpHdqmg2SMBwwhi9c5JKbCg9atyE0JUshnMWQ0UqZ0tJD1CsHMl1YPiQpYjGfWbSF86k+V7U5or7HfpG/M7qbWxZko9NWbL
# DATA bsNInmduvsftuDUmeE5RoVaBSVxPI1eCupi3MFTBYbJ0iyuX23RBK5f/btrD9LlqviWzdIOazHo149Md8DB2CzFT3xzNmgzmbGpU
# DATA 7PFaCKOpsKUckMHWicEjAhHTPuVGEgndf+XG3i0ZKQ8MXFgp5CZ2KZv7TXxL1hq0qo7zstkZE3I2iZVpdsdBy0zxi0whGNuNSleb
# DATA Zj3x4MP6TCCOw6qs1VXEeBl4w1tj04wl6IrpHvXbHcHEADAp/MEPHG+/XGNP6ZqZ/8oER/bMOelSFTYyr6uhoKmmq3q0oEF2Glr5
# DATA 6ky3VmOuHL6iKvFgmCS22gxJPqHKSpHTPUo8LYbrJKHNmXKb5C9yahLzACPoTVrcacnBjaWlKUpK7kXfyprwgc68oWFDlHrkFVNL
# DATA tlCO3SgmLnmqoleD3clwNEKUtCOJRBvTo0qwGkjmhYm0erHoM2eXRcuSuIsHCFor3anEDD5BE/D63UpibanTSuOGcm83kpxcfJEy
# DATA lAeG+LqgjHKXAohNpop61ga9jh43cIFLHgLmdjdeT/qdtlBXA0E/hTtLRX/AtudUUkO75LlkNXGlR5F75NGMPU2GXx1H7T5Gb2ef
# DATA Uu9gMfMJFJnGfnfmfCceGRK5A6CuJb4V0pNT156QVn+a+QYdtsnkA3hx6cdG4sDQAjbWgVx1tlMvX57+RWlW4RrEulUE1wclxzeg
# DATA 3CPt17d8x/oCVXu58knOUJmEflvlgdi6H/iWSa59TezNgZx1DMjLXD+58qRi74p7GynLBR/qpi2aM0n/PvM6qXMTXPwSdI2BqRk9
# DATA /+rik+D893DnxEeci8A7A6gAKazkQVv3qK4+Rq3x1+ffgrYSFMd/BJXxt6gu/4wH8Nu5ViZFM5GDffvP4Fa/fQoZPEg5c/U6FeYc
# DATA 16/Lu4U+ot/mwBXfkM5soSYpOphaL/xs+eWkxAnIKhiKVh27dMjmP1I1Kq8dtONcN/4DTyzy9idFIVwtCwpyaxxj5iDprFxZHR9N
# DATA gZ1t4y8FaeQUY6+1WuLYaLWKxptgYmy1+ZVCqLT8BPMP6pAakEncGXIigFiIK9JihvpKKUeQ1jPqd0nLSWFbJD6xWRa+kdWPbGys
# DATA +SKsGzTHSTs7sthQBTiV4YoCX2VOGLQ8o9iE9jlMwDId902Nn3d4ZVQcYC8zJqFcxrAZiP47HUU1lTAMDYo1+Q7+gbdifauEbxXD
# DATA OCk4qZq7NJmZ3sFpKZnuERYHwELk9CVOc0e6wx8N67ftN4EULa9R/j7ymhpyOC29y4fwVVouS5bC5zhnKkCSjQVL4H9r/PwjdM3l
# DATA 6l3vkcTB6Rro6KD8Bg1Ugu3PxWe9ymoakOY2qmCqphokI+p9Qw+rmbW0nHzR5GnWaSPV/mZhqpoudPiZb3L42TIA4BN1l8BvyhSg
# DATA lPyaelpil4B5XyxaC+0erRZSQKsFTKXVCj2up8RuUr0kVWaOn0Sns/NygBkhctBfx+BmFJ7/Gx7ln9PpndMgZFkhwa78ZuAxmbLK
# DATA uUSGUc5RhGm14UT/9uK30AhURgZVOOS/hNqh/UogKPEZ9wYSI2HTn+K7H6ElD2U4IROgSFcKxGsfUaIl0JX/o5EzHHv2HGgXbVnY
# DATA JiDQwm2zBuEZ5DRgkOIppUQqLP/XCOC6yvgvvKheOfx7dvzX8tLt5dtu/u+VlZXXv4//+o+N/9rRMO+YqCMaEwIHafcT8V/xm+Jw
# DATA EszyoDeBVFzSyYGlvThfDFgSNV5mT2yxf4IfKf7yEWGYffHPPj5sLjMy9tEf16mx+LVuSyV2KxnOe6bUVLK84Fle7gFgRW9ySgbc
# DATA qgX5bMe4F8L9pbDysyE40EP0NFxkPpA+7eTRbqoVQ8OhSNpdi0WNbGTFyTeqK7eaCle6MxwDgqqGAcIgdO3RSmndDDgEha+asDbF
# DATA oRQ/6aVMAFIzIwzjGuzU723s7u28H9r4TiayE9V71B8eFMLrEtvV8kyWHiGehudp3PAYsAQ1O3hctgfJJlGr41ngPGlz70H7a1s7
# DATA 68mEzFBTJhStWrOkIya5y3uWzoDGXVDjgEfalUY62avnngn1irJGREgSc9ekmW1ShsmGZoPuJkbqzShOrsCP24+istceSnAdUBCA
# DATA 9nmLeTv4ULAnyBPURDs3bP/2gPC64CpzlmeMWmB/oYFmXwU4N8Sg93cIIWVgvSIFQyAAVGZI+ljUzFtkEy7ZKSwUS3rFD2Np0vTe
# DATA 1hbAV76PRL1ru0VRHTJul6+jNgYZHqHtbhl9zLWL9fAwIB9S0vufoG2AubcMQxEXvuhJuyMpViatIzbsAIJnbQRF9C3HuQzZkfnc
# DATA x9s4zPDMaDt9l9hgoUZpD3Xo5mdCWKd1x7pMSd7ASnvYS0b11o5KNGu6FJSMDRcWzxL8C1/2RmcYSv9eNzasF5ZRIcWCIeMfinaA
# DATA wkBQckypN+7IcGZPHvt2+RCChp8ur5Tu3DoL/Y6JUFNeFr62tbm3urFZ3wHMzvrm3pZ9kChCnseIch06QC78YnpIT6cv+GI+ho8J
# DATA 200vwGIKx8Ng0N5wMbOgTz+uYkVmNDFPSMlZMioW5Q1kVhbXMuItUqwc+nScI1jGExYDXvo0oYYKRcYRGISq9VHGUuSK8fHCAxlV
# DATA ViC3nSCGZFxSQ1XXNGM4HcOBRyEi9SDFHEDP5rxzj5LnEbmWqYDx0Icm5x0jOzGmeDwv+OBs0MOEvQDgD4v58ZkXWFBvWo/K32/5
# DATA MVOmOLHJHhzrZA6VbDQeTo0nDhuVhcY7SolG2iCDw3Vsh4eaEq3odbKmmUoZRyKVaKoBM3G0KUgHzLMDQCZx1tBTxWuUcR3gMqft
# DATA YVyRuVDDgakETkIQYl4Wlrzbk0IxCysxb8qUgi9nihlrSjNDvvfwOFF+eWlpqVjMhk/MnqCt98QR4s+V7PP+zZGbuJgT5J2YXcOW
# DATA A5uWqyGH6QqBAB3Czlwpg6pYmJksOZd61ifDLCzcr99bXSPZktKc777k8y/vESgxFNjegYG6KKZaQAo8lJTscjqza47TKjkTEiB4
# DATA OhrhZXlGJ9J6SlshtYc2YO3Mns4bblpUWBRHkaGsaY0jIfbBXUG6RlSlO6J0msj2wCsmpXuNF6D8w2ZAFKQH/ju+Y8rGi9FeYE7G
# DATA MzOrLe3aYcAhZGSqyxHhrBRYLdOYR5jRUqLg8GYNL2OGYRieOmlp0XIg8LioTDkFaQ2mo4OcVKpiO9SpmEyU4ymgjrQ8qij3uHrR
# DATA C8pLvpxc5mJy1ZcSNxT+UPvrWMK8sVHIZ8306dnoGhhWacBPnikSVeXAGLDJWX97xemFH55HywJJB51Z3VN7gFrudU08Lv1rMV+k
# DATA upfH5/M9u0REuslBHcUkHhb2/kyR8WGOnU2ZpyuzbhyJ28YcN438twzLz7uRzEcz5+0jefOAOTW+OvyM8grQbcIPuH2Zq4ThHa60
# DATA jOPCzMuFc+/McbV4wWvFpa4Uea8TOa8SV3eNyLwcXMEdY/77RYrfnyaPhZw3kfy3EA9KiIkkoa8cmP/C1U1rRy7xo2ClaYI7+L5F
# DATA 3XhNiWOoypwhV55dLYRFSU2v7LJGtSD5LHJFMhVrmwypJcFVd9+U1rRmKpfc5+CMsHwi/aEw/2iWeIHU9GDj3s7q3sbWZmt36+HO
# DATA Wj20Am2ldxKHH40I4kYzdbG2ujw9ctfL5PYjSLNBsFCW0RJPN6hc69G5pG0W5IcJSn+lloNrp0wAbieV/u3Bxu6D1b21d5IWRNCt
# DATA c/uCLyNx0wEjXa5odQgRNv/quw9KxtJDG7UEJAu0IO+J6GrH1hfZNupAW9o0Y2EdJTO60UtmavQUQWgFpSBcpTxCK91q1216mrHq
# DATA pLyMdQ4DdyzVhIzjWKCy65y5GyBxGxmR6zv19TAdtzTPpclFwskza7v1nXc31C58FQWKOBDnP5q9yoQMJS1fdJrHEAcnpiA4GA8f
# DATA x6i8Hk0ncWUhIdk0PJFL130bp5lIJ+nTsM7OTH0JE74rEKScVVILIx7InHkM0NwSMjkQAW2JJNJqGoiHcdHUI8mJbKsz7jV4P2FP
# DATA WbCS3wmyxdwAnCtgISmppOGKGJNcc3LGuq71AJpHX5rm8cB9xbTOWRS5+uDuxr2HWw93aUn2Vnfu1ffC+XIEGmPXiQKXZCB8gnc5
# DATA ubZQcKAqQgzRq3pC9JQngLYi8SO8+50pH5kpCMJCFOD2BtOTA6XOQIs18pGAgdEYgw1af1PBikhE8FE0BhyFGDGFEHEMNyVGsYHG
# DATA SJmtweMIs20rkRx7wG3n1kr8J1FGWJbAq9BGGNsqYVc0GmMmnysgDGbIBGWrCFlVAmpPOiOjFKzaAeTLHBxp2N5tsXzi/o17CxYX
# DATA esSFoFP8MWboYMswJxor6QLg/aU7nQFOCS2aEKCcXaQpAT97h4cRqmc2tnXtJxBwCWCdQRv7WQk28YQQ4hzQcXtguCtCjtAI4Aq9
# DATA TMKRIZ39rbUvie09ExXP0ECkNzBLfSAFUut2wVyEz0hH6DB+RA/PmiqZFB10MbOHxqupPIwreKp8HlknoBwenc2na02EOmHSu2Tg
# DATA Wdo1fyYgldIBzNZ6nF2NAP1qsCf4pFoQ2GDk5CP5qlw+OK8eRch6x/FxbwSItQOCO5IXrS7jTyYsS77TwpxV75mhC/hOjpxYX0nj
# DATA gSfDO8RRtCGetzUZIrUYpJDTTKA3xSWQRhdScDyV7YeNPRXX+qOSv/tT0qcltK+Rn5bxZDh2bJWqL6/MaV9yq3LkbI0Ing4ymuJZ
# DATA WCxm8TqvIMoMU1J3EbILX8K7jijPA7k/CxifH9owO8nMZmZWCaJgemxGh9KjAv2h7KjUKzNXsh2TlMefGCB7kE9D3ijy9jV9E19A
# DATA 3NOjkGKedIQzXHfNM0pKIsm1zAqzd+9xLvoLA01SKxnbNqcV5IVMbdzoJaL8CWSGLeB0lTKdOl3LkPQwTx6uyUtP4pKeSFMqpVl4
# DATA nthCyTBz8qs1XF+NS1dKH+gVX8NaDJPOESU0yXp8eWcd+dJL1HA2Sxg3NBSDRaw2SgzX48WeMSTcxEuoWjOcPNORFTC1ri7Ij8FD
# DATA RGY+tkfPZ463R7NPnpn+JLm8SPQoS6pD4XTQftTu9dsHBLISpumjr+Q6ma6mpn5h8kTqYMjB2eLRwXDYN/3T1ZUkoz6KXq7SOBtV
# DATA ccFrOv7rWKvupv4pq1rt/5NK9mcekFR1i253TxkSRoEsr0hMEwBr4Jy7eEScDAW/Gw56HczKzeUJsusYAC0ThX6kqvCBaPm3y9xb
# DATA xfbzt2+Hjmf/ToQGXv17csMUtbQx1qWBkGzkisT7GTsTanPQSrzQ+ClDsupJ9sPe9xndsJE7stixxgKVUBiZ6tXV9feVjxCfqpYC
# DATA W4WTa521jjDXwh3iHJjw2pHxSHKz/lBcp/Prq7e262QNsdXW+fTsGu3B6rHsbUqPKGA5SzIB1AdbOHEkkqbdIAbhU3sSGQIbxQrE
# DATA YY/izfLSkkKc6Az7w7GnWtNObJBcVl9VLxisQqFbePooF0zqfIpJUSs5m6/UeMVNQUtyJUlVKujCPKUNVd9E3FhI0wcaPLm6CtwU
# DATA jbYTCEUBdMXeRJRjdSBAUYEJMRqBxgczl0pl3yz54M8WA9aGftUYpj5UV9Oo4rlyycIz7Sxs5gBtwe7G5j0J34qae6XvM0mR1V1b
# DATA GMcIlqtuuw9GIhY/wTSIiJK4ThzWElcCqdWdHLcnhl4Blp5rxJhRoAJSSRyBKgz1DJPHw7IkCJ3RUdpa2jIZDpJEhXEtu91ThGpO
# DATA 1RXAXWlNFiNRRfSqRRBnNQDBFL+FUl6lFbCGRKFs6lJuBxcaIgAdN5HKcB8jP3+asGxzi7arDLo3yV56wgmt37QqgLaNIzaZV2qx
# DATA n2ij1dxLqLgaBk/3B7SbMTsvz0niPlm9ubS8tD84M7OOnwzFpZSSK9FgGzysJnXlkSD/E2vucEOC4p4TFJm+siXM1seuvFQBILfw
# DATA iQg61jA1ARGXZxAafINAAXnC7FqR3LnexWjSWcRyi5pASEUH5EBDLJopYhTV6M/gukLDspdQwx9jMLHgXTWZBhgal+ui2a2qUS75
# DATA lRCZpgTe6VI45wIa+QbsGG2dUk4yBtke+S0TmUVQQ9yidOdnRSdLFr9pXWYwN1L7RHpDmYzLk707hYO9s7rbWq9v1zfX65t7kp9J
# DATA bU4OyOi0DPWUm96IGiz70Y79WernwCpWd9U5YIhduOGmjlLF5dJLVTW0v3U+RiFH2LTdZ3QsOs4BG1Jw76G4c4oL3JvssSRPyUDM
# DATA kOmv/qqdwSNgCSI4gUxlpFyJ4RogGHl7EBiTiOewVhorPgG9buIN8FA5TTWMPETmOsCsQzXN1GqkQAO1hINhOD/Csob1yX4tf/nZ
# DATA cMypb9qAzDbkGp27qSG5+dSAl4jtJYf/dr9FHXAjco1uFcmCo74rD0Unj5KqUQXap4T46vDerOr0ffUpUEXVjM3lfaaDcqHEWdG3
# DATA f87YHwxQQ7sWrPV/PMRtKonkhrzV7BhzCTpQJwUDvcgP6uXg4qbsjgxSlri5mDQ0VBm8oxY7arnIfWodVKwGeX5125MoQYTe7vj8
# DATA yUy+qwEPudaEMS6x6F4tdnL6+X58PXEUzlkPpa/C6wOGjCcr5JM7B8Wb6dY81F/MZXjcqT/YEnd31CqsbW2+vbHzoO6Ab9ibu+q4
# DATA jtN+t89o+w1HCXrol4N83uGYrTKBlNG0trKSX6Vtk9NcZkJQuD1SL6P4LQ3h8innzjyKUvpIxvWcTRmd06yhmA4AapSXLKeYmVjF
# DATA mb6EP3PK1vDGyqqssZbQAqCRzn0qFHLxuK0eFFPjarlGDykl+w7Za0GWQMI2Kdz4GQxCSSG36Z110HtkEXPyINdHFXudpmGlGmdk
# DATA yeBKJnAFgaUoBE3UcstzQOqLWb3vwVWFoB1ioH5uPgtv1buXTRYyz1TM2N+ufDFHK9Y8OvW4AMEpoomnCaPUdEAX7UTsBl1mbPQC
# DATA DiRKGLy8kVSZo+SRcr4JtDo4Nup0nyt/JMZMxdb80LiZIRkmbG42ZC7MpAuTa4YSaKpXFhHQJXZzOp3Ko9/glNVE2i/FGKvybRsa
# DATA KQ2MQ0vEOaVx22vKlcsVib4gApjp858U1Yt2O6xoMvHkpde7rMaIA/Ah7CjIK6uMqbTQ8rrpGkrZosyo47S1LDGn1grl7XYcs+Oo
# DATA JAgGC8QLT0d8h5kW31Gfg3iCHWkciMUy6GzaSp2c4Z+ciKlNeOTk8ssozruwrmu2zLbFNlcruCPfrpDx34Hpyiy6DdHfoRsKQo5j
# DATA g0eaTqwjhn+x5gGeUUQYxF/FvZ9HwV8Gd27fvnlnHm/0+ua7hiyknVLBk6MHiuh+YRz+rScMvFYwQgPKzRv7lezvxR9QRpMsfR3E
# DATA klQeJBCTlMNmzXLYNJfJcdC0Dy/KmEZ0LfOBrT3c3WvtPry7u7azsY0hQjv1h7t1HhuoQ6hqwTj2B8qi92LhMGT3dEJgzHh2jkuy
# DATA ZHa7eFFLxfJRMr3zf1ozTQ7VIi2jPxed166SZWNniAkNpGleYDIn2tqdaKkwTPRuwHhRxnDRhUSH2rG3r+vzR8GvLxZFne+WmRIg
# DATA lzI3SUQO7kxDdqTZ4A40HQhKeydYYVA5kTRmjETckTfra7yR//rhxo57W07rQ8L5AJammwesw9b3z521kF7z5izMFPi05Hf9qbhq
# DATA VVWf8eLlSaRl3xhT0EO8OVzOzjJyqqUuKiRzzrFxEs5jcrKEwBGNJy3mtS1mrHEyMpnYRekFkg261pz0iU+YB1xmc5Z8OXkkNJiA
# DATA mkYuHuUh4DqTyfl4SBPxLtWGRO/Bhk8mrfa8x5tlfeu9TbHx1+utu/e31n5SXxezJU46ENaxVvCfB9Mxfllw6dyX21P/npbdM4Vi
# DATA knSh0+rJw919z1M0M4UfHYO6MB8ExfQMcXN5AqI0Zu5mmqBiyR2K6qaRYo4P2MvkDEyr3Zc5km62PCi0n+ZLNJXHnvdnZMPL3t05
# DATA NvHLsGpd3ko1tz0sy6r1krISvgpnMWU8jSOxiuJD//RNvPQZ4UQyGiaOID6bfh32+9BeQA4FlYX/9DYfn0Xr6myJV28dvKR18mps
# DATA idbxf+W2r+TRe/164WnomsIkUvas0wlZZlKo0VcucM6YZVHLn63y8ra3S9gVMi1lLz2Pl9cpclbiSdMpcj771fx2sRcx1+Q2WiSz
# DATA 6mWo35MhFUkDgmUvs3/LMsBx5cqwhvXkfz3NWDjXhKeYGA04+Rcwnl3OjCQzBXIrTsblzLx7V2EfumxOvu9tSxm2pe86YWEqozPz
# DATA FRJdTce2htER9HXsXwqKJ5VKxe/h8AvpHeJqKQtuc0Udf2i4nftsB8kbCYJBKB0pucTWyCll+OS0Fkpgk3A2cklOuBLGpfBhUixc
# DATA 1Z0x19RzSKRlyLBhZHJEHQMjtueh0h50jofj2U6c6xs79TVAsEAfkvqD7b33dRxlT8IDzGHLsKwySqqTkBLGYITIjwBxRQOUFdt5
# DATA gT6jrQScdlWMjCId5YObLxRmZ+unRqVEkkZ4u4xV9gcO232paa92OVK3vrSBbj1Y3UioKtFunR/BlTTpvf6E7kl9iJ2uiQoqjCct
# DATA L568imjVkCsq43zRomYsEQOPJm9h5GeO3enHV92LzJWT6Ati5f5KUEer/tON3b3dMLEVSXXDrCZd9ULsz9K79A6t4Sep3PT4XdUx
# DATA NeOIeWLQHneOe48ivtlyXeh2GwwHnehNmYDeUKe9GkwHCJwQ6RZ7kDWmPeA4jAiMKZQ45mAM2147+XJ7aSoZ1bE5XayNqnPpaBJs
# DATA IRskwXkCbM+EjvBUc1lkLRepAs8JOWmL8go/tZzBdPnsoZcIjqs1/MCYCf1y51i8WMD3ihkY4FYqN1GEjw6tv/co6mvHk8mouqiB
# DATA 3qs3lyjUzVcYlllug8pYwwT7dEhJC3XJ7LcFSPPUjt81ohOr4FklaD4ug1/mKKLgTCGmovqkGjQsdxDVVNFRvIcjxAUS5Q/D5ZXX
# DATA K0vi/5arT+HpGYbIuJp6YjrwxlMHLILErfJ42E9zL3FrGh4dUWDz07A77mE6YjJSlqUOaDiS+sOn4Un7SRlM71BoeemEdJBPyjze
# DATA 8GZ45jZAMaed46jzAdYwEXMHQw3XHqyjdCmoDnkq/vcwAiSFa7zuejJgFhbR2Cpk5UWq81qxIrjPoDCu/aUMN8eUqOPK8IO3lqrL
# DATA xWKlg8AMhaJTQvzEyAmiQiHRQNdvI5PnwGb9QPA24FLiwfIKBaOOJ61RNO4NwZMuXFmKw7OztMMVZrwhF0tc42YCe8DVjj7aFuqn
# DATA Msg94UREy5JcZ4qO113j48DtGz+WwRIMwaBSZ1tqE7I/W288VW+IXpypt6BLkD0HFkv7G/IQuALdNVe2SFPWWhtJx1VJMftycWfF
# DATA xAANA7uMPLOYAD2srlSWlys/FCLKqDeIwhxMQRk8YXbuba3X7z68B4VPxPT14N426YxqSyHOouQH4RtL1TeQ4d26dbMq/md8XJx2
# DATA R0jFMiLOx2/0NKFPWNUXmVYdD5VMWYYw2Ooi/Fc/o5mpLrIe2PJepzmTXaCZ0jVJsjDrwWdns3gyCVNlKUyJy4Kr3n857ncO97L9
# DATA i6sIplJIUopjwnajAJLr4hle0YKsoA9nLwDTk+oRaGrUMpWhqXr/HBrU7myNgryc2bpNryIqt03szI1sImRRG1KO0Z4xeXmVT/px
# DATA jKBCMqlvZXV8NIXduo2/FCT0HSgMWi2xeq1W0XizIui71eZXCqGKcAeaJdTlWiNU+vSyhoEmkBZ07w8JymfClx7WZGj7y3QcKb5c
# DATA no77/AvfBsoATI4nGIhV6uxW/pR4VRH0wvAReJMsc9AqMq9pHJWB7+hvVBPJRi7mgTwKfZgNzYyZKZeBfEVpiMKtbaMKTDrAGNKl
# DATA 6WRvOxCFKNEjcmBqwl1riuz50COWY+2d2GlIqaonWCdbVWhwZEAxwR78AwQxVLsei19iNOljWfwDpWONOAXfKjaYgpdSXJQJ9Frr
# DATA Tk9GccELMI71koYDPxp45vjd5JPRIBbk1WrHnV6PIaZZlu9n9TAKLcUvGt2xMCnZxAqgK5h+To65GDx9BV5O8l5qGrFqgdODkq3t
# DATA Al9M1Fy5/SmqtVCvOhY8PfUSKH7WFPN9AT8rCx29lOo06RnUjLXAbZ1BHRIATPX2Mgvu8oyM9lzwZneWDH0bzTcrRy7RK4NtZXTI
# DATA wAt2+wIPL9+w5pAmgInfAz3nLPA3gzAz+yG5uzt6qbuer1Vj06AS1u2K4cusVFnGRILGI8T7qof+WUiHIqFunHAODLV49nDloWhk
# DATA TmaFf2Jh0Wmzm3cjZjerD+CqI/qC6SK76fkZ0ayuWCd+AkRfOUOndKuYvk/IvZJS20NMm+VH6T1si2eX2Dv6eE4CJyXsEslRqOmU
# DATA JorGUjO7QUMESLtbGuQu/eavYrW0+OUOVaMapa2TrNm0lEuErWyS05hbQtQVHWuh2ajVwi61WrAPWy3uEaxx3DsaTBFYsQAf2/3K
# DATA 7sa9vfrOg1Kgv7/zcNtMNE/P6U+BKigFnIrlekvcxE61riXp/0Ky98KlnT9JXNg9jQWt1qEV7coJGpbho2g0jg57TzL8P22oXitN
# DATA rwI1zJUY09M9cRWOMSO6i/acLtWIHp3/c3D+p4tfnH9+/ofzb8R/vwwuPrr4WDx4Jr4+v/i/zz8P4PnFx6LY+bfnn51/df71xW8u
# DATA /lEUhd9/G5x/Bb88w5e/Pn9eCc7/f1Hmmaju+cXH8Paz88+g/ouPrHIB/D80/Pz80/NnouQ3F7+Cxv9eFPny/OtgdXujLJ5+K+qC
# DATA lp69Cf365OKfoCLx/FPx+Tfi2zPRA6fDz7DDov7zL87/iC9jBRX3lk063NW1tfrubuvt1Y37PCH/Jur6VnTqc/H3K6gt17i50T/h
# DATA y1+K8tRoYFZ38WuckXf29rZ3y3peSoEo/i2O4hNR5Tf8+dfiOb32kWjwN/7ZewazF5gT5UzHxa/kAP4kvn4kSsES/YuYOCoGnf1K
# DATA dd+as4tfJeYMXdZbb4u5aj2A2J67YDDaeHd1r45T9z9TFg8HKPr9B/gql/0bmAHxECjvGYyXrCw4OOgEPjIGuXRnaUl0/f+T1coZ
# DATA x+/PRMfFiBMdlgZJ3XHsqEOi357/7uJXYm2JBuchywC7h5OGk/lH7tXvcLyfi4/Ld4Kf9O6mdkzHB3j6lbZ1fic+fAH9/ESUe17C
# DATA X7H5r4Ewn8vvz3gakQCrAei34+oi+xxGT9onoz56AyY6hxTKXbOYxf9DLYheCVL9PRCP3TNs7HMxm59gwx+JwliXWDd+9Wterq8v
# DATA fg2U7laANPonHMmvz78Q1XyJM9GeToZmL8/SmbJkg+hCpTm0kB/O/1XUDMv0THCJ5wnG4dkpvJhfIAXCTvxlxrYWH/97cP4HsSa/
# DATA QNr+GlfiK1HqG0E+z89/j79Q278Bdibq+gqXV1KZ4Gq/ElWKLsCv4jdBlB9X4ND4i+///fn9m/SFDHT6cttYEv/u3LqFf8U/5+/K
# DATA yq3lO/IZP399eeXOXwRL38UETEH1Jpr8P3T9r127thaNJxSKHQXspARSOOeV1cZv0i1Gj4MdaYmTjl4UJoFB270TvM9KbbD8ThWR
# DATA Lk8+g/uT/DyMFzCOCKw5/d5BwI/hciGLjFVlWqRUT07VR8FCR3C/WKAKWTqWFdJdumQZtlr0MC4FeKNhJbe4CgziuF+4DheDEoKc
# DATA cljuYbvXh3sbM+laKCSRz4FHCl73C+SHkhdu18VFADiv4LnPL/6euS2wauaVLI+BsIAHx7dQUJyMJLJZMtxzZLaiiY+hKlHqKzza
# DATA n4UuMr0hcIvBFxohjwT8EGEskMgRUqPVYEjistYeTWA0w+kEHpLFUaFa3zbcXhBHnOwCnWE3K4ucM0MeJO0KYVxJZ0ZNga1Ruzcu
# DATA HA/jCcN56J9KlDzIXLq4Fip/QPK+km+yvUW8Db5pvUcUIYSXVaPKIqtrRMUGYj7e56xX7Rh7cGLrIF6iOJlHFDWJ38P9wf54fymc
# DATA qaKlCwsKPkAkfERL+VKIFAEKcyA8gjjN4qOQPfC+8PziH4AYQMD8FF8RVJLMMz0ykCRgVEkIgOWllVvBdfwzs8P/nqQ9Fg2YglXn
# DATA QQSRnRdjK0uxEyW556ZoKWSOX4JwGTzo3VWp/naidhc9oYJ46LIjWPro76bgHgPO4eBCO40Zs1aiGIPtA2ioogigRYQu1hg/gRen
# DATA eEqqiYNTUPgX1UJbTymYhflA+OT20g/RGDcYgp8DfELfjGiAJpU37txCBxtkFKpZOaotUcvu7n0ZbRIHXcxYhZimvRgxCcBXaMK4
# DATA +W+KbQJqIrGQg59H46HMakDBJVyedqxKWHUQdodRTPgG5rYJpSPkzJHA3hHf9Oazx5Iz2NhE5UlwSi8ZgcT4GbBFoCJHNv897AWg
# DATA LbrRPct23byK+hUfgHnAXe45KwoWF9JzhrYQ6zcZtGvbe65yrV58neZYK/sODPcgkPDpnglX3U/hlDJmVHAD8eQZXoGeJe4mOTjl
# DATA d9ILTihFskTcJxIA8QEMgpb8wN/piPy5NHC9GsA6SRiGODgYTo6Dnd1V3LD1tfXd1TfFAcUpck7ARRB/PRl2p/0eYuYY7Go0Pej3
# DATA OoBonCAC8ZNgYxY9+PgNMzNPTSP5uvhJ0tOoDalOyPwbx1VZp+SX2uHY6NwrNaeRzF35bwldhD434DgQy/CtkH0+RmHnY6kbQ4Wd
# DATA T+i5+ET6YYK51jtReregZb1LXgLOXFW6EQgyhUQqI1FXBYvBIrcmw1YsCg66cQEblMnBapQcbLkJqSclYVQGw8cFSRuV6aRTrMA3
# DATA 0YuTUWEG70J576sA9W5f0izwFd8n+MFd/Z/gtv4NqTefXfwjqiQ+uvitnQXJcwaqIJLR6WyBy7B8pcle+li9nBjHyxmBKUtiiDhB
# DATA HYsh1BErPCSjcG4Ep/P/QVOHItPvsVOxI3shR1GylyFkKVWPmOCPBA1/jVqRL8NE1z0+wT4vYOOFhB8wzBnQdSGEHFmdY3HiVEbR
# DATA CdmPeo8gYSd8ZQGl39X5qEz3D6zFsJ5QHkrZ6iL8bMGezJWn+Px/obLrczxcP7cEPRAAbXnWFAndORWv/xEvN2pWUU405FkxQImQ
# DATA PrLkM+p1MmrYYzax8QFBgBQT9HOx53GSiDM4Y25Phie9DrflTpyqx7KFsPkjf7NiaG7YadYqGYiFWFecEjU3koFsnMXKJr30UNLE
# DATA sEfOON0oNLsw+iTJ8jIZkkx8SqiCkBSJL+hin4C+cwR7vIbRd+Q6jzDEh70ntbAy6cfl0LOaCJc8jCuHXeD8BbOR8PFBiIYlwdKj
# DATA 9ombNQueseEyMTCjxGF/Gh87YYDQXnw66BRkGTGGwbBgRHMPY+WTT4uOQe60LyFSsW8MAbkbSoypa8U8WsHmxYWTaHI87JYYB8FB
# DATA 4DNTlFMBK7pMZiI3boTwJHkpvHPzjVuen4GfBf8tWBouvf56Fo9d39w1+1wVvEAc5X9Qxg7j6gfcdGNzQzGOAG0E0laCbOGOuFM5
# DATA mGOmKqlCSCvsaqghxSSGmvkqsQ446QdHhbDRHcTN/UF4A4dpeGfI9Yr6mJEakmAot1XxjvLRi8YnvQmF3heewi+tTn847R7222DS
# DATA H/XI6h0iYACtG3khqEKc8IfePeoM6TV+Sy1dyqsyBQT1kxJOuJ2ITjjJkadzIAYaiSjM0RjVKnnIaAkkP1XaSLb9CN1RxIwCi+Mv
# DATA Y/6i8ndQJRVMODErv8T5PwNxKMMtUZE4Li7+gQT4r9HQi+fP79gA8g1f6AQNlpX67BlZMqFI6CDDmXB/cqwMz5NbpPgXJOnPz78Q
# DATA jYHF6iNtgPsEDzxjM1jtM7u7TAiRxXapNgjRrfxs2BsUDsOnH5yB/fwReOmTK0rJmn6Z3aOCsIqYe5d5DTibG1IbUlApkGwnhyDo
# DATA U8LZVAxWMNv5EVsxAkCNxKDj0ICGrNzYLzdv/Fg/qZjgkc2nKyVIHIq1zRZf0lS2tGk0Tz8WnAH9m0MOkKDehjfw740QYyGQ6uVA
# DATA zDSxuNr9WKOD2meurjxRXH5cfNQeL/Z7BzoV8KJ4vGjJhWmFDFlR5glSXJSaviFX6gYGgIQ3xGs3wmQciB1GZuQdcrUdxthEzTGp
# DATA o/NrTxwfseBGDVnKDeBiRN1YbTFvd8szEycZTkzmXcMMkpFu8bRH4DY3lql+xEbA2nWKPg8J6zwq7c5JVG4Q8TYbCvEUoIK4wtm8
# DATA xiFawXXQ5eGPcE/8GJndHy1mx30isYA6m4wv1xptLJGp0Z5jMykeiNbnz/CK+jxYXXtQV+reGI3e4jAbRR1xQRSLSDqTJ1FnF5Pa
# DATA /N10CP6NAehMuujr2JmQbiY+jvp9+TvpT4Qg2B7RKYYD0TGS+/tAQ/viX2hETl6jh9fMZ6/Bs9de4x4a9EHJqbjD/DcsLkpauBHK
# DATA IEI7QWrYeDjoTYSssW5EQuxEtiFt7/6ueUfeH6weClmmxhFf5SGIiBF72AUcLs2t7Q/ea8Np4S2LvMnqDIfkiP7sQSCBEJLi46Eo
# DATA 9/BBO/6gtiSku/2Bmv3aNcHoaE5vhNf2QUnEB9WdW7cuMUG4eXJNj5wYY1LEvhKT1u7DmBp7UJN4a2uw1hZyeLc9rl0vi/8Llm6W
# DATA lm9Xl5aqwKesoe8IwhLn5s+j7nrUb5/uRp3azTtQahuU8jFcBmoTccZi/Rtk2WzS7Ebdu6c17HysJtaZC09ozKWiYnIFxEgsCYpk
# DATA GaFKz5QzFNABxl8Avgmp9ybHKlZzLCVZw1e1YYRymFpp8ZX1hpYvK53qGMhCmd6sMJGYoQJV1Bh8xEGbuS5GySiQG8oal/xRyrQc
# DATA PFmTmZWTJS3OPx3jpLhvgdJq5A8tcdxR1YQbbsyutqtdkdbldsXSd7UrqPFq25Hc0CfTBzbhrjw6tZympapudjOmq/p8bRokZDRt
# DATA 3EDbFSkMipr5FtqumCK0v2InPJUETXMkLGqa9V96GETeVSsxL8ybOrTFRzoJfY7CDCZpQFuTi3OFYBWTd8UUkuF9Z0uirwY/iaIR
# DATA WiolflEgj2K8cUNO70GnPwW08wA8Mw6GkzAO+oBGwBeSuJLMkt4IJ30ZRMrbsmpMprWbKdiTB2UawytaKCjylrfKwr40y9jpMukg
# DATA 4GmyQCj9yiYSdI0kzJN+7MnnzvIL+CkRYJsxEpRdrF+hzz6MJ6/MQuaFby/+ga6PF/+dHDPwgonGebhgipPZSQFEbuiiyYbVmWbx
# DATA TfMn6Ekzhxv5DO9uv3s1HN0JT2tLMXIp72uwvv+MAEswgSuryEgkEy8/6sF1xeAHOuWgRCCJgv7wqOK47Ifn/2o4togZrYoLlOHX
# DATA iJB8OvdoRH3XI2fdbmi6xLDDIrrYbGxulLRDhfh/NrdDxC4MpGakUkt3ulz+P9FFcXr4uHU0bY+7L9ELMNv/b3nl9p0V2/9veenm
# DATA 8tL3/n/fkf/fXgS27fa41wfAhxgMLZA3lHGIHr79npBiMZsuH0cl0r/3BpR0FiwRY0owfZrlAnjYGUz6c/j7xcfTSU+9QPEy83kA
# DATA 8nfALpIKLnTYoQivGX5z5Pbn944Th7/jKHfrdrbXRTR4VHt6/fowlkkCxPl6f621eh9d5tcMhe9MP7sd8mg0zjHwEfuMrJoXH8Ft
# DATA W0dAPJc2NwzHEP/9LTwUr4hlfTPw8NNDIXQ9Bpyq80/BRwbjCT65+E0404dPzFnLOA5lPhAJQXjcQzOlMcnbaLux0LVspF+2XsOb
# DATA lcdtwaDlZN++tZQHUJPenICyegA9KqYnFPA0sryUgNk3Or9HpepPRjZana7sg16/7wJJ6layzGm2IY1umVrBJO04qdrpJH1k66fB
# DATA FIvW149Rhw7k8LUKEBJkoi3cL2DJE8eM15IHRjUyf5v144jzWfv+axn7xtHBcDhpSXZaENNWYhVZZyKuR2KTCYlm2BeSTI1VLgnV
# DATA bxnmWtYAEtB00JvUUhU0iRcRH1arsjTlUbtXQntfWX4YOSmQ28/lXnHSHn+AmnV6iVBfCCwjZM3jHqLliekuo4PXz4YHYoOLQQM2
# DATA 32j4WLzUH8YxTF+/90EkFZXiLjYZtwdxD449vFi6mkcxiy+udmROAEtXSlOR4ULhJnROb9ENMWtShwj9UapCUyEWQJ6Kbo+ysk6O
# DATA 6+hHUZPpPWgGi5TWan+Qqje0azQ1hwAqx7MiKrkWcM5ccRa2D/qRoWXcHsaT2uI0Hi8e9AaL45OgfBgkumE1k6aiQ0So8hQuQIaa
# DATA ztBWoke8saFCSqEuyB6u+lIllihFXQ5pL1Uwz7m1TtRLSBuBQpNsVfrz8FFGQb5VJs4ZrACF8qgrD8hSQEHLomschhCJ6RP3cP72
# DATA +LjXOa6RzFTBLyUplZmJw8TrhCyI2adIGuKjFGsTP8pPAMJon+mEE3z4WBTCFgqh+GKbGcSDxAnOFdpHPTs012iukc9JpJxm0h8P
# DATA f6igK18MxwElIpnGkFecptyyUGS0y/3MqNFTn4+3/btPpGLHp285Gvkz9pESPO1NKT0b4Xh/oljg8294DqUtRE0vPyiLObKKCKJ0
# DATA C4lH9krIylhDokrNGBZHODpcWzpKf4rDItFSPQTHTTewmOZCOX4kB9Ltxe3xSQv4L3hQMKki0dlnYNF3CDJktdiMAWraPEefF7uU
# DATA Wf+q4DGyfplKDmQL0LmBCkMKwZVgNQA5TnAwiZI6BtRV9OMFVUU/6LEDvsEyui7kbWfY7zPAUrmMpzH2jXh7uSzYD9FcDXEhNaMT
# DATA v+EJA2lFRoJ6Tmurnc503O6g7WIZtGW0cXQ2csmpmkVv6gy504wXYCGMN2btn4RsY2g0sbPi3nci5uvxcTRgsHkOHmv3+obm0t8Z
# DATA u/emSTWDS+TcxWkkr7ctuoWzF/IvxOZ9DuGvn9q0ff75mwH5J6FP85fSApsqwiA/4B/kw2+hCjCTglM0ekBaYLRqZxSK9nyZRxJj
# DATA h+EeAIQ6ZdN56RhtOZHIvO8yLYVwhxAX7Jrq0U4dYK7X6zu5wL+4GhpSXOGvjeVqU2FRyWfV5SaoXQFlP2ySHtH83WSZslZmmRQs
# DATA xtUsNR2z+SzRVzu9PTv/HTq4AxUlLeNfKS1/MeHGFy6KZXcEdPAhqPSHnQ8S9zJwhEcIkwHfIMW3rdbaTn11L/iQvuysv7cjP29u
# DATA vb11//7We5akQuj9QmwcT0cAhSPxSQ7HcHtxHFsRK98BP9nY3DOxT7KxUJJ4KDINgH6jtXFv01Xa/iQ6PRgK8WhD9rRQzIZkmatX
# DATA foQWY1bY8D37WgrLZMwZKMDEbVM8LMB/SvwEgFVa9Z9maKYTsqAGJHtxC0NiMjPAYkIlxKCAI/6H4axvpvO/bxEN4eIfMOKGeKVf
# DATA GxXaZg9zOxmGj/nsGRlgN36Tg9mqMjqYtgsM5v0nVKv9KlWH5hmglCjCPzcbAyWqKbePwBXxJZkAMvX/y0u379y66er/X1/6Pv7/
# DATA O/n36ivq4g0ZyEenk+Ph4ObCtWvX7nPqdsgERFQindQqsE841TulcccMBwgHB3kNxsPp0TFKhEpqzm0YOG7HYBBQX0/aHbIUAPAL
# DATA 6jHgyKEfQe8LyCw7EBMcT94RrLF/FfACQoRUn8HVakLNphsfgGdY1gZsbDrui7YqY+qdbJM7W4Kf4eBYUB0g3mO0oh0eEJvY+wtj
# DATA ni9QdnI0qLO9voWu/kKSM3IkLKzd34AbE655HxaYVC5SwggX1rY294QgVt8BrK29na37WNwWQ0CZOh72w4Xd+s67G2t1+w7GIHVI
# DATA MUqNuPBwc2OvtbO1tadlG5+z2ML2wx1I4QGJSFPqLD9aFi3vrd6r72KIFGoxOLtLd/h4gIocjJSiJJMMQ0tZL0JO7XnKL4AzR28g
# DATA lpJBa3uH8peOIOeBeKG48GD1p637W/dad9/fwyaNsHmltqUUUuPhkZjrmLPjjOVKC4ICDEVEsy8F0SMdHiN2xTaET8bHwQGY2MQ+
# DATA EvMwojJxibN7SLlUitExXpPbjwMmQxkJDnuM7m9EcTVQarZ6kPERH7Ayiq7cdoINK48qerjA9lGI2bzii6w2MdIJsnaGXThEezKL
# DATA ueyE1D/oQmkKG6O+o0gGQvNCi1pwTnRSH86hRatOOPJwxYy6Sc3NQ6SbZHafezv13V1b7HYGTDlS5LqiSkGOy8m5ORiCWgwjQOE/
# DATA Bc/9W1ZjzbC2GrDkA8jnm8PJ20AOTjSZUcHTEGcJ/XMoswb+RXVq1F0FjG/RI7hRIyUBkjqCpDOUS2xAyYt98qg3RF2cbKDBtTcV
# DATA egG8JJiF2FIRpqEBHiQINZbaEAAOJK8mQbBgPtS+ULDxHgv5MlZIBbSmFTAgPylgSxBBaz2VnSomR98wRtFsyILg+nTSflJYKuFS
# DATA lN2x6JlpFhNVVoizUF9qPKP2azVRK72I2xjXEJzSIERh/8nSUnn/yfLh/pPXD8WHHx42OWUali2KO+jKUnPBHgQvDPS74Hl6I2g8
# DATA Ddt6HbEmgNEnJkIFxXf8e9YsNsort6puG5yFcJWyzIuKFnyZ+zCnIb/j82mlWlzuRv5dVYfhJHmB7RiP5RKaWn+qV+9+mb1BHZ5n
# DATA bFT7hqHuFKaHlfSmKqb30b/TkWzFc4eKnf2ktBejfsTRVnrCRscIk87en1wk5AmGU54SdKuO2Kw3yVUTVm7INgC+4Zksng9ZMTTR
# DATA XOxmjkUdgdx+cEhzldamdP33AKuVmLrg3PptvK3LxzRvDZy3atObplFPAbqjFHi7x9OTgqq0gRU2M+sWzKEwk0cUk6lG0TlDdaIW
# DATA LFW9Lh/uWnEmsD6aFMHyonzmur141G+fBm2MqGtDbobg2lLAYAPXKq7/QTbJGl6BiVS2QlQ1SFkfHgkClQfJBswV5G1Csr4RLMsf
# DATA 1sTUA9/pR4MCzasvgweS7u4EM2pYZTlxHZM/XrCxCTetUzTuEH9bXlryvEMEQJ27jmUWzVbcLsXGsWhsGf2Y0m9IZln1s1Cn0qjf
# DATA HsWQ4gRXS7xkUWXBaOdQkEN8TA2RPPQYiNDbEzy+iokRQET4CXRkR1KX0a58ZB73ySPlTLDzTl+QgiUPGU6WUlksiIUYv0T46A+P
# DATA mOmzpwOfuZAzFVIVeTJySq6CKS+SOSHzRlduDNDxXiF4iep0LTmSsc2Xfo1lQDPdjAq/P+z61avv7Wxt3n9f6lQtZWv9p2v3M5Wt
# DATA CYQCJYoBn0xmyay6jFWVh6Bc6DzcEqzoM3ep9OJVCK5Ihl2qx1aCUfL71b9Q8LgHcECWsRLopqEiiBnp9CGF8WHX9YMyuJRWrR52
# DATA Oa4/SZctpO4CXYD4bgVxHhMdBMqXI5J2CmEDZATKqzcZH+IJHr72fvm1k/Jr3b3X3qm+9qD62u7fhOTaVzk6oTMexYgmeiXQPQRS
# DATA ZsE3aoq8JEIVURtOJ4flNyAaFUYe10J285AyCPdJeh4lh8VoTExpkbE/baLJRZWr29v1zXWXFFMdrNR0g0aVelp1HeBT5j9kCGqy
# DATA DUlccaWchjxayrODfizmrVncwCFMEhD34MqUTWEGE6O8cxLdKsHK5LZInWKcnFROyAzwu50p3iDwk8VnmV9lT40pztIMSaWJMTp0
# DATA d9MWnyvi7NY9HDQqDzdX3xXTsHr3fj1MZcGyL8mlmWX62lk3d4Gke/19EzHt8zkajiWsCAY92at8IngAQyCh3yBgZlA5j9+g44RS
# DATA 2W1t7O7U7xVkJRJrIzWKJccs6hvAdNBp00XDrJ+hPizFlm2Uo97HUfSBFGgS75ft950hgnqqJuuB20bBLu2h0VQDTvaIKRgYX1QY
# DATA DnLcZk3QH/FfMCZP0OmtcIA8u7FCFxZVolGFYmMhtXW5CAjAVAhcv7keBg9LZ/UZvYkGXb7JwCRDttnCOCzDP2DUgGgQNK8zKH3w
# DATA k/r7+FNInud6ng+io95gkFLR3fq9jc3cVQF6AfUJjnwE9NC1g/INfyRPCyEX/Ej/Kp859MoTFTZ26uura3v19cDoQxPPYFGiwfUC
# DATA tlOR1Rfi+iN4VKwxraw9z79KQKjkPdYyaNHttUF5TOT1e14FgLo+mbmXa8FT2SJl7iwpzsh5WeVXT6o9FnMoC6HBU+UjeekHrTI0
# DATA hbkT5Y+Vo/7woBBel0qNRvXOLdAXYSFVyttyLCSUxNs3VzR0GDUJ4ic3nqFNQBAXW5WA7yRYnWFmxXfoymOI8Xise/idMd/gRkJm
# DATA DayiYbzeLBav/KIMc6HPIEMa70VZU+I9kHwJky91PL3IEZV26qSeVxnHEONzTHqDabTgCXQxUlin8/+c7NO8HRFaKtJmBZgz3IsE
# DATA t/vb/fh64a1q9ASMY/vxjeJbBYaEaTUN9Jjm9aIoWIPClevFH9hZq8FYU3lQrPp1PpqzEvf5EOjksSD1D5GvfMhS3oc6MPJDwFh6
# DATA 64Po9EM4MkFJBjHLH8bt/uTDbozQATCYxnITW95ImWW5xajwStPweMMU3fvX9sOw6H1VdBwUIlhDMfjLWnCrmhqg5PBUesfdUwlB
# DATA MrFhqBpEERmCNqPwlPqP6E/4CX5i7u7hC8QG8AByun6GmJE18bQkkV7oRm/sRTpv4I/yqae2SsYh1JQxKHyMSxV+4a3eSbHQnk6O
# DATA xRb/OaoSBaE0qrUmEdeBIIBo/KFYyF6nCDS2vwuYNONwf9mo2zxU3RZCbkNU1rgmeNZb+wcWcYrnu/W1nfreh9uru7vvbe2sf4jp
# DATA Xj7kY7P1ljg3PxQF1uubexur9z9c3d6gZ6sP997Z2tn4m1VIi1R0K+XG1GCKjb/dH+8PmjfCcL4BzBYqGvvx/m7z+lui1VmizIc/
# DATA KIalVOEgqxv7B9HpXxmDNCGg0r4fhDYNZNVfAFge8XqT/4o6blTKzevVxUWYunjxx9XmjSp9at74cWIOf5zd+yfLB/uNxlL5reb1
# DATA RlBeFP/9cfn/ktaixHsS0qtz3B63OxBgjcA86pvYT1gSFKTmQ4iPmIQgtwkmpd/GzXRzJSAfR+uHV2rB8srrWSKrEujW+boYcM7O
# DATA mKK+2/GEkNwrwd5xpBS2luqONJXgOUJY7ehWUQEYPpYHbS21vPmJq7D8SJl7J6QbhjcAckR2Fh7Jz2d8ue0DYu+kpRxRWuynUtAW
# DATA +B0yggcn0wl4Hwf38RXEoC9BPweCHU2ww+A9QU4C4mt7QsDzwaR9ZJjeR8O4x1dlHe1JIs9O/cHm6hqknNqpb2/tbuxt7bxPeYEn
# DATA k5P2YFGh3pRVd137WSo2mqDzRec70KbqTj6j+E79fn11t66iPaVZj51WClrxFMpETOKkqxwJqWR6AC61i9ji4lPd8Nmi9AxapLV4
# DATA S7l1tNB1o/bU9dI/M5zgCacsrj0NVztwDoFaBBw4ICAF8FEfDbrc/A2UaEuQuV3UW15jA2EVBPJyB56Fnhjd8KGgwvLqEefF1ktg
# DATA 3iPCM3rTcPxk752CcvIwUmaAEDaO4tFwEEeJGyg/J5lo5fYd9iSBK6Zaazj+RHGwiusSl1pAnHkbzQQqNonKOIZVbl1AvbwMxYit
# DATA gGPEahjVo32ESi1NyQWnVVGCj372FXHI/NF+V/B0+R/gk+0jJ1pzbLfZHbcPwdbSi7E+TK2ZKDQSJ7pMTW2VvMzAOa8DjAW80K2w
# DATA L37GDEmWJPGmmrISpkDknxVrUsSRi3+Lb4npMWueMYh36zu7QmpQyrcx3rsnU8G6CyftESCqcn0S9BwyeWmUpMFpAV4COl2+9fqt
# DATA N27eufU6WTLgqTiJsMrL9IXnjrp0IygslYpiHxRuBWXcHVSvDpu13GmqmRYb/7XL69ONmvBxCqAwa/w4QBi3M2Dn3rZ2MeJKS1Td
# DATA XNOwuweJCJmqWP43dq+FyO8nmvyb12yLJxzr4GllT4q5KBWU0sjPHz7cWOdXUbzAjzl31l8/rO/upfcrFo9GphtKS0bMn4hTR37j
# DATA JLcKCrg6w/uNHSA8TmALBu62+G6byMSYs3RP+RXiDzd3V9+ut7ZX994JrR7ls2vKwgmrZtKrT8+ZoiQ9WQY0Kz1D7bGLhqXLpwNi
# DATA GUSiqiqhmsq1ZBoNqc+Npaaj9KNgUTTLmenB1RtF4uur29stukqhWO3D+AJP51pAI2H4LFOfpBQ11tiMEArQQ9gq17/VrdbgCnEI
# DATA CJ9P79w6k5oG1jAkhyQVAQiTS3mADABZZiNUGvSuN1cyiejBxu7uxuY9OQF8KoOWAjBfT9qdyiB6zNUp+N9SwF63Jel+XYmP20Ly
# DATA QGms2zsC0a/o8R1Lp/uSEN9J6Vql5s8cFG9ZEdBUwdy4xUQeA14hQ+qLTQRBdjFWyOANCTgI7oEYqq1XDpxXEHWMHdkFJ2FMwEL4
# DATA aNifnkTgCNywXASVd2QDXydVFH6C5E1UY+/Qq1wpGFsASzJzpjxO8EDKSAiaiK5fCQdsYDF5a1cKlKQbt+ysPMirYVFIJSvNYtPQ
# DATA 9KhtKFbvdAQXr/CgNzAhHgkQjplNUQM+VpNNsnt1C+IExO/Aqs4WfN4LppcBHBUN2ZGmL3rTonduqvVg6+HmHjT89v2NtT1PMjSu
# DATA 3jHc4epJvZds1Ufp9tEiEYGNBuSUoN7d9JJW+SnSEqinvAg7iH36qiSXgk87ugiKVel1EY6AnSyraM6dN+8TLx0nDJeVBCFqYvnr
# DATA WRLwFQB3o26LD1I8GLrTk1FckPboYiqqBQdsF2ZgvoKSQFzxgbAhV3FQIP6CegPp1inRLVwsXAeQIgl4G/dAMWFi3KoAGA5+Ccp3
# DATA 0fRuDI2iK3zjQkcQiojFl8zZgZ9Qx5HoFIB3QNPDQZk9E/YH/AxhaW043vxYFz7S1ZEXiwEHbJQ4+Nxd2kTqSI0tkITKKBF+hCGC
# DATA ZL+uMDTCcnkwfCw+cG/mrmlMM5Vag7wUIECKkGBBJz85ZYHRkFwMDRAA4ALmWR841qnKeyp4IR5qb0q6g5jOdjeYAHYMHatRWxzZ
# DATA ON1KB5QqYqrEA+kHZ0YaAkvUlLLpCwmYEluT2vIwKh2XoaVHE+w1UzCTz3jGxTkQmXJjlrjGHbu5EvyoZgtAteDW0g/vKMzyY21T
# DATA YN0o4RjvjxFiB/VB4J4fNot/RnKTTNmQlJGUjyZqpKoqJrvV6okd22qJLvQPybZsRiyLh5V0slNF9BVHv2Hec1RzKHJhW0lHeOMe
# DATA YdbpnntGZe1HEfc7oZqwpiWrPn7XiU/QIeukL+0m+4wG7Zrba9fizvnkHW/3ngztYuhZEALAS5sinNjwHyi7OZUSrFX2xg8/YRHe
# DATA 5tZea2NTXMTvgzeYblqqiajmRsjfPTAdiRJ6WsChiwlGqinBDcC8D8+OF1O4c+BM78s4JS+YOLFEOQkfgMwYsSvwdJL2gUAui9Tf
# DATA uiFbYkrCDFDipH5jxMFAKYq4UF32Vm5B+hEons91y6/ucCc1dbcVQmgKx4dL44a5+Cefp+JlL4DTsexVYDq23BDVJjV8ETVdoy9L
# DATA cqtrIE8ncrbSx8QRRrVFy+8aEuKQYwFU4TgyuU4e8A/A4vKtDVTdEOI6hnT5V4hXSdRpxwFhmKOYs2mEFzAZ8EgXPCP+KCjrd81A
# DATA giVQPL6+spQSpwLvcNwbtliT8ZPsi1ETFLpX39l5uL1ncSbVZRyZqIVgx4UEVVX9AKRwM7GASXhiKGZSAx6uunegPewIVDOhAzA+
# DATA O0DS3zUVMGUZF0ccnEJrfmYcV8nwamaineP2IMk9UWeMBIDIHmRCAIVxu0OYOF4OI39EnanBONOCubLkuu11cBC4+3D3/YT/56kv
# DATA kIq8h5PDrADi5bEQ33o/j8wdSOMu+hbDV8s6/klz6UwfiOHqTD6d5KNsbvoWORvSchBnVrSkDrl5TzYdqqqCi+X9QqIsGVcOIbMf
# DATA jdvdKMfZns7hkeF4OZUYGiohzPmngQqJYvi41e3FiFtmQS0lBgIhhLKfyC6gQSKtk/ZAVNclmxcS68xxbK/eq7cebNzbQRcTHM7G
# DATA jsUTUvcAfE3ZAfTTS6V/9ibPfXLO3jyGOtAXw50Sn5M8e2sZZ6/3Zc0y8eBWX9O9uuYWORwGIdufPbBLHFh2Bc6p9aOMU2uu9c9/
# DATA YihHNlf+ooMCAuoozF6vQ9VkPcbiVrWwrfV1elbMWERjTly9m70nPRHbTn6NVIpNUaUQFmMmUiHr1MoI8wZggAaAoQnNcWRJ2X4t
# DATA pHhPgRhq1RZVqH5g9KUH7SegBAMagAKueg5fugvKH1TKpbbHIHVwqmixr8TSKWTKisbcPjzodUPJaMUjEB3UeWJplyxHDx+xFS6J
# DATA VWUR3gzBTFwXd/ZaKoKI5aVaMtRpwe/uqU6WnKK6p+A4LPPNp9x8evPO2T4X9EV1zUHCKVvcGrATaCKDoQCg1hYWYJEtWeGSAsKV
# DATA 3wjnYs2XPsScQ7lYnXHBTB5jee6OZPRPgBiAfoSZXpoIaj0G90BHLSVj2go5qbToVtjqjCOOfkKJZDazpOg8RELRAX/GfoHcNuyG
# DATA mG9DJKnb7hewFD8LaKhrUJNRncT3okcgSY0wxE0j927NnD59cim4b2MJDVGj6L/2XbHoqmZfy69yDnRfmj455Eok3heSfK/8HvFC
# DATA 4pvv8FBi2IvwZHKM8kS4qrTxBNjaWLu/oceWTL9KJ65UVSKuDfiEhs2M1UR/CK6Y1jKtXtyTpnJBfW76T0JHNrpOSV/8MsEpOBTA
# DATA BHV7g5rx5nr93c2H9+/jLyAXyP1H+abUV58I8fry0pJfBs/Y1mtbD7bv1/fw5Le3dj560NAyUp7QmdLnjKO6nITTOzSZoJ+cOECe
# DATA YAJmT5EMlxefpQhyKcEK9/vWdp33u1fgYM5kgHo0PXhAOfaYZW2ZJvSZmWp1P/aP56KVAjKCusE7S27iGswH0CLtJo+T1PX2/kkC
# DATA ryd07ixO2ZXYU9PGpIa1GcbeXszo6PZlBbrQ1DvpdtHImITgPF6lG7SYJDjA5+kKMSigW4EG6OlHbdFDgDM7GA8fx5CcmLUWAD0D
# DATA FDCJ+qcVP7dMU4ekXvjTf8xlZUkX3Czy8FhixHQZS1/NdCOxdhHD1rN3Sg4tMmjz5bapGYRazG4Th4xWRPt0SuZxmo7HHHkI72iz
# DATA 4JwhosW0ar265OvXOedl2H4kBo9uDlX1EruWs3ON6pJ2u+GCyYuswjUThVwQNkPGokk5M81+HXnvgWRTbqgcGZjvJ6iN7MyYyLHV
# DATA KvQGg8gXlIvPMU6U4Q7IVVo6Wrs2XMYBRcDyUhKE3ALMcUFyYEJveOQWr+juImzrfjo426K1AmJKwdyQcGH8vnm3mKkV8wrsMg8Z
# DATA NCxErY2tFC2TPX+Zp5s1zRbVeTqVvN3wWj5BnwGsqxRcb/kDXHVTc/eY27+P90vrQFNaeunrkLx70y8tdOUvGTdxHUuBjial1Kv5
# DATA 5bXOKWqXWezVb8iepcu1NBQvpM+8pKU9q4OpnZuFLnipASjHJlp1cOeRq+0y7HxNgfvEZv29+o7T0KvB1iBSmLooaPxsKAba7gM/
# DATA jqeHh71ODx27IK5PxihCiBZoHWBW2uICd9yLEdQmEYpuAnWZHI/RFRQepYRZqObnYUzsFkxXA1ygDJTLYrWMT7j2ZmoI+Isje2Uj
# DATA fOW8M6TUm6F0V56vdGHyKdKl66vWtrv+rMx6/GO6lCI+VRL5btTvaaruhEre7wBTSlXDz9TZfzeqeVMr/+eigs8l416lQn6G8xIE
# DATA nFuF5lLDZxLwVSnfDb37ZTTurt467UR/Yb+zXNjkGTrr3uBw6NPMc1hpFly4jkQiBKDcdcTHc+q54XfThODTrs8gueKVKM6xF6w9
# DATA n03CV6w4b/lt9IZak6jsqJpTHYeaJq1i5ymLusR8Wa2OvbFPJXQDA9KvGTPtP78pSs3NGm2ACGxt7XE8jsVFdQkWxP5q6651Tpo4
# DATA BBjE3NrYfHur9bbY4FwfUHYxNZ7EU0F9c2/nfbMGJGzHgctZJjrTYZF0DoeFue7/9v60czAYxKdHbuaKOP83nbiHcvt8evErzMv1
# DATA EXy1PBhS7kUyJWAtA2Yil+KZlNtCAID+lWVYuqMrV5U3MaKwBlGFeUJ+ZmqskZZZXY2ffWftD9NU1RpkQJsSkX5SSqNnelfDBDSI
# DATA F6gN4kdCUu7Q9Lq/cjDPkaL18Nq7MjGNXqan6uNZlRPbPJUVnqkQD/EK/+bfwGf7g2sqBCC9H76s0sbBlBhQ8CN9FfK2W5zL1Udu
# DATA TLgg7dRX198P5+nKXNeyS1zPLAd7pgK1OJpVvlLTq3dJRycTpMHTOrKpRJQNCAXql1k3o0s3/2pwl7TK0B6l2EVc/JP2KVy3MONS
# DATA OxhEgBs/oiwxOs9SZWGmdlbRM09ozU9XUkUjS0kyUMIuVpfOBl8Sd/5nzYytHGuQVa4KuTohz9zn519f/Dqgk1T2mtLB5OO7+gZz
# DATA 0BaSVck4ugwrpgR49HNj0zj4XbHlVHp2tytsIf+yz0XQjM3RerCx+2B1b+2d8EVWmRMrwSL/6/nvktlSv8BMqZBO75eUQjCcsagz
# DATA r2t5TJ6zRD3H7Jot5PmrTtX5ULuebCdJp5/sVETFmdW72XOc/A9GGh3XYXN2Op1s/wK/ZcBONAIhcWaOIm+vz1LE5UsYdjK1US/V
# DATA CP4qoqTx1YMwZCCIMEANezc4OKUY09GwN5hUgm0xCRBIHGyjomVxEE3gku2plZUNEJ06LOH9RrQRdIYjyGumFJ3dXvtoMIwnvQ6o
# DATA MCdDOl86Mi36pUz2Kfb4lglhn18NamyHmaavS/OiBPmTbzO3TDgc+lDKFV6fwtO+SWVsMmnZwlXSc4KWUXFNi4IB+Lvv7+7VH7S2
# DATA V9d+AhlTpGeTuAhuP9wLs0bqzZtq7IE1PHm27W0w6BIBOEb6129ntYTzPytjq3FMyYStfOv1Kqwupd7jiXMD3pxE6JfzD8klQcF1
# DATA SireT3qxmIQjG/wnoVJKLa1ywAx6T3YRf7Fg5ris7B1TSsSjB70nG4OSlQCzgi8hr6JXZXoABAZoTfDV2FTOgDYQrD2841wXF3Ea
# DATA DCgavBS0u13e7/F0JHqFkSDqxaLnHUBv4dtp4XbCJumpW8FHib4XMOae+0JTwvlDC/60okUz7wCxwxNRp6iGVZ0J86q1CQmRYNQ/
# DATA lbFkYguUEEPMeetg2D21cTWwkLpxeuwR0aDbkriCBSiVVojAFAvhGkFolgEQQ2bElICKHiWlpwILYrGEEIuIthDmbfp+NDiaSIkb
# DATA jFkwbtffFF/Xb8e+0T9GwzSJGFiHNeXHuHhp9GcGxmcTlQkHoMUzwm3IgzzvM0UjrACIpu1x1GK0AOwNj5bxEUxQYoJIEP+5i4DE
# DATA ePPBForpll0895Dybi3dBAFLmrfCt7d27m6sr9c3w7McKl55u5DZSMFH8159j7xt8RdSM0O+WJIjwmx7uO7YCmCa0byxL5w/RDZH
# DATA +5SOIAbBpxAugpKbQvsXU/1ss3qjtNhQNVlhnTqbV9vToyi1oxKdMaU/9GZTwjstZuOCE34i3A5XXl4EWfqcYvOIfk6fli4/jURw
# DATA HM07f28olPwFW7fckSkK9lK074k8ztmz7a3dF+1aHzmyojCDCbUggWOSczeamSTG9RG2tArztHjb3rg9iA+jcbkOhxvFCrL6jd8W
# DATA lFHpxYI59iZaNbcU/AhuLQVdBlWWNkjulREz43waCIi0enjuIOyn05dipjuGIcJCzRIRDudnwnihr4ALBOKdYFw845LtRI96qF44
# DATA +663rI8wsacvSJy4+RbbHYqn/K9JlSu37/wXIkpYMQ+Ggw4Nexm0qTk1x/9DhxqyL00So61YIflI96uZn+xXLnU2pBI5iYXfk/d/
# DATA BvK21bjfEWGbNJ2wzVwFHafL1Nbl4JZ1OQDT3dtbDzfX3cvBS1WLWh36IXnwKAUQbCfTt5T0PbfEOZWlRtJjuoQuyV1HYy66w5aQ
# DATA BwEezrpjmr8DT/AXILWKdMyhZUp6zUMphQhovKKg+pCEjed+LEDnZZ+10/0dvxZmhy0zpuDu1tpP6iaVm/VZHqPocWMqnyZSAUUu
# DATA OiWphiHMdSxU9VYrga7vmI4JrKjCP63DISYLwgSrPfCH5+SaQEetFkgxrVYosx6PY3TkEPsPP1dWx0dTgDHcxl9Upi2wkLaEDNRp
# DATA tYrGm5CfrNXmVwraxRGdN7dRA85Aw/hN3M+Go8mictmUlhtvZeZJ2zkeArJxjUCOUTzUTpMOsgHCpMugUzEVZYmEiWVlaEkzcxgy
# DATA DjKzECnPi2+m/d5vH0T9jN/RzJbdBHiDpleAatOM3xm9N6ME41JyJziYlcviHygt9U8QqoqHaTTtsY11yUWX3EU33/oTuIvvTCnf
# DATA DbmV0N5WsNWQKwRoRSdVEA1V7FBYHQe0kGbewLfIvIEfxYTxJ1wd/owrwZ9x1iU6ur9doiATZxKA992mOPgJP/NM8zee1exGEtRp
# DATA QbrZEK5u07ka4B2hq0VsTV1XsYIOq3Lasisz91hGjRp/Ah/i115Xr40PlZ700m5VxYW/+P7f9/++//f9v+//ff/vqv/9b6zKJfwA
# DATA UA8A
# END_REMNACUST_HELPERS_V1
REMNACUST_INSTALLER_PAYLOAD_V1
if [[ $EUID == 0 ]]; then
    bash "$directory/installer.sh" "$@"
else
    sudo bash "$directory/installer.sh" "$@"
fi
