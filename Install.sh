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
HELPER_BUNDLE_SHA256='fb9e257886ea269c5b876e1b7dfcb9813303ca52c9f6694fe2f0ec2800283d55'
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
# DATA tUYPXrjzvveHfx9k/xsF/N/g/u8uaGd5+x9UkT/Y//+29X8/w1oRwdRXhy7mkvAm5X+xdFAymSxJ46j66WhENdKYnvwwxXsE76v7
# DATA y9dzqm/xfD5N1ZfLnyUz9RkvuhknQ/U1SX/34sBXy0Uy1vWBgzn6KfTXeDKzv3PJYMxPONndO8NbL4ocZiXv+fHx2f4JJmeUvpl+
# DATA 3z/Zf3G0u/fq9Gzwxf7hy/2T08GXjW+g2f7RM2rzfR8+Dda12j3a++L4hG40J1ctnhCbDzfKn04qf84tB5+9Onp2uD84/WIX2OxO
# DATA yb4FpPSDjYr3/OBw/xTTUUr5DV7iPE9RVfGb7ZbIO82LfnPUBPvy4pKx2PAdbcjS7ZFj9SknS3RLy/ZWLnzb8nIGyum5KxDOrJHX
# DATA 64ArT7U6RmgpcJTg7451TBOyJDTfablilOgJiQHnfLdMKfxd/GT4UXusShXvxe5PBie7X2Fp+a5bRIMe4YLDs2buUe5kWVTGxVZ1
# DATA DbEydxSHAEfZqYghkSF6rq44GfLlJlUicF2mTm4rsTqVd2Xb1uSILzXAjGp1Wa68L9J78DpWty1ve2uL0pWo1pT6T/nT7U3r9AN+
# DATA P69tXtg/VT6ufFpSMdJ7zzjI/QXCvAQqXZwJ8/UHeENCrK7zkERNDPss6OrIcmlTHaKh3ItRwkfEFssZbF6sMY6hFYzwSulFrEeU
# DATA ZIAOrOfIlWPKDa5TVPHuqz6gzm4aaFTpzlpJd+2sI8OAd9IkfHRsbr+Ct/4irodpOi6bTuFXaya6VDaQCm06QSdLhB2bwPixWkXe
# DATA oSGmNJWZR1b8H/mN+xbjmb6ZT5ZjlKaLeG7OKAmvxaIjUyfMRl+r0t6X8+QyVRk8X/aQ29biacTZO8CWH8wxPjC3MxVBqBaKxGEy
# DATA lYfn25t4qgf7v2CQ8HlRCWUEq4wP7awiFBnPds92/ZJUULQ3Bj7c2937Yt+35QBtEPW91byjvYD9ViqPOVn/ahq/mfG9Ic4sfbmq
# DATA yKwHzotFlq6Uw0RAmYX3rvULuZDR6BgyVjANQYFw+REv5xwvD5+VmQ35nzA/EvpUEDs0Km/nILRIuXJelyUpDzdKG5XzxoVmi1Qc
# DATA SrM7ndByzwAgUKCbYjG9QfDWS8Cdu238DMNV7V1l6iQHqnrKJHiTTJaTHcXkDYd8sOBm/mj5Kv6/YGzTaQesGIY5KctxMKeaDuaM
# DATA v3XoHKmRB0hnsO4lIL6KH2TYLA4mZiy6Am9HfqZTCGWZCfTZcGiHhANwBXn+CHip1tkiTf0xZtq4VJKXdfq6Ba6TUZ4H1iULODz+
# DATA AKO3mr1u/zG4ko5WxpcZW+fcsGd93DkWMYl74m2JrVi6Q1uETRWr+JswXEnX6rij60rh1XP11sWD++rVNFvOZpSNqnaUgrtU+deX
# DATA sAydmsnFt5e1xVA52q0azUHWBw3JQosuHHervXDHjHWnZI9VeoqeqspTst9wbUnh1qcKuSSKOtop35DG7gczL1fYiipVPDdVTqkA
# DATA fCpnJW2sGIm4euaE6OYFrDH8NLv9S9DwK38pSudfssb5DaicFTk6+ghx6GAXgaKaOSuy1sIiF6vQSESUkdoim0PvAHIu8Q54mC6w
# DATA B1M95kPhVjmzLtyYnFTmjhkWzMnO5NzhQsFV93/oO42QDhTD/kA4sFCe2Q3ZcuIO7+iATACqbgdSmFgJj+BjTFvruChuBUsWcaV4
# DATA SSgDtlaVsmRSNtGRg29x9bdZhNHpeV2diU/r6CJndLZcDvC8LTZ75LIxSXtcrdJjnwFyOLzexnfK0pD76sqiJNIk7MpFwr6dXnTF
# DATA X7ZaSFJgnSJXzSD+zC3yCgI1L+JX9/MB1+GCeHIYgh+lXEQN90HJETHCaj7a0QJHY+L+88yr2h5fLL6G9Tg9r7IgffmlLY6pNR9Z
# DATA qazUm5f7LxFyl94t5K60Ka4UtZ7k1dWME7yvFHBnXXS6hvj1dXsrZAPsy5znkKnfQ2SmeLR+qSD5dqUD3ETWK7AJlC+qyhpLpWpv
# DATA UKspjV7JF8eQUogGhjX1z8yRbllJ3KMffywzVzBs4xh3q8uvzyG6oDvH7yRlmtPrabHLFq2ota7k26sqcF0EVbT+yTCOopzWbynV
# DATA ObtRzoznbMd8Bb57jMgq6K9gI9gWnRjDOGhEDr4S33OJ5tZ5b/uiwCB0jEDaButNPkc5UsOIciFfkfl31xVXXS90FO4KpM/PEjmJ
# DATA z57a2rDbFqtIhqxqcrXydck+QAdu7XP4Dx5fpn2fDn+6k6S1z3CdD47L3Hel0HIAksoZDsr1lTccRHN/hMzbd6eZrYg9pQLKmWWa
# DATA hbiG2dApmAQOz6cLdkrzbTaDJAPbwDJBDJMrSFUcBCqWH8srbFAekK7YeoirncEcQFzd5hcxyzkiuFMSkdx9ocuBn4HZKJV+9Ys1
# DATA Kd2rvYzmiRK9jD2sMfKkZMap6coj33yT//lxHgi8ZnyFRAWPpfxJFxQu1ggXFsrjN+Srp5lxkwpTlrqh42agzbod0apm6ays+Fxl
# DATA HXfXrzlsXl3VtPpcq1TTKJ4XyZQwACFlV8N7SKSky8VsSecGDGFWHqBhfkeR7s0ayi2UAXLC8SFRkPdqTUcpHzQiYM6C+QH8Ul7V
# DATA 57Ah0VuVPyKE6iNGLPwdR1uo+iAI2m34U3QsB7P7acnx/aqNIFe6WHxbczr+rUyMDK2yeZxlZcYbbmBSubGiAkG1U9cVtUVosKDQ
# DATA VdtwUR+yzx503VEvH2rV0Et+zh4TMD/hSBR7DqkgCjauydSV60u72PJviogzYgpv5GVUnidA32+26b/Itev1C9UN2y/0AI9ABdPL
# DATA GL3jtiSr4gtuPUlLmkNHCgoMoik9jeuXc5RL7BRqb++ldd5q7ahWpp25ZUEXrNAeyif6Uw0dCFxgg/WXimYnFLsT+8d5u1SgwSky
# DATA yRkw2p2C+q7u6cv9k9OD4yM1MFf2qLFP9DGuPulVColxNEP9VmBWaLmYM+osa+6DTDgXE3x30GOMuMewQttNbD9VJII3a1OlDXWe
# DATA yakCumaBHcIhMjRlVZxV/64xRQ4nQYys32PJxLZ3tSsSE2qMN3JbdZp3S26vNXXdmse60LDg421ppQPNxMXW23Z4+929AshxfVXu
# DATA 7qyNV7Zue8BJVukdDDGqe52Q/UwXO019qbvieVIOecUFoNb/kS5+y12ge9befssm4VPblgFkPbufdVSc1whOdSMktVZbhP0FIjsG
# DATA zBZZiimfjeFV4ltYw58UeVvGpupco+kR5i/dyMZljuZlA5V1xxvFmb95U69zpMu0WVMH6JEi0JxUUxcn6X7ZBL7n6i/RlMA+7nTk
# DATA dJ8ycE03gDhr3b2HCuOsnAA3jYtCOmvrLz4aDZfxNFaX3Xi5W1dXfQ76IPW97gZVftL1NKgzgPrcn30YsOAMIJfgegkqVjy/5kJb
# DATA UYAZIZEFdM2XSnE+JY5ksEtv5aobqoeZ602SlHCHPfUlh4GuYAB4QdeFpRpREc2FyWEyJFIrKF+UX+uy7RO8v36c6HvrSSHGXKOA
# DATA OAyVA1NJSEiZ+BnD8qPkzU6pJgbeJkZBkvmOtYEq6ynrd3Tm6JrjBk6RRw4TUnz7Me9pJ0677bbXTU21f7Xl7i2dkGb67L3qobho
# DATA h9CmkCbaPTF+KLypmZ7UKDNNOY3e0rfa/v5PDk5hS8g3EOH7L16efX13T4mVlSff93endNeSFfzG65tmy+E4ya5oG2Qo680eUPeL
# DATA XiVZQXezeRqClYKH8al8yAK2TLwEpsBX+vkquKQSO7D4g6TpFc3+d2FG9zMkoBR13L2AN3E9FMJ90QXR/7qsqrA+Bk5e0+H6AglO
# DATA szyazBO5vcLco/KRzUms3xVy9ZtIz05lGbP9H41z8aEo7x6QBrJQybQrqATDyZG1+WQxj63NZPsaXNVjrSdDiIQ2vPO648G105To
# DATA BR2uB9Oy8nspPJDOFK3ZpQPQOqB6ahgjKFW13vVAwYB8DYN7GxOWHt1agr+Pbo409WHw8IKsNn+gtIGqZqARSdUiCIGGLMna0nUH
# DATA RI0eF7/KOLfedYz5lU7sggdcskBpvdRU0oQsA01XPWB9lb9YGjGDxGpx5eFCGEyb/4ucMcin3n73+f+NRqfZW8n/b3T/kP//Xfzb
# DATA 2Ng4ibFClZ8tZ3RhTRxZlZE5h1tqWQfoFMCE0Agah6hsjJZj+27ae9L9KV3/A5L0l0PRZ/Qvt/oj+lw972T/5fHpwdnxyQFluvOB
# DATA JCkBg/6Gy6twXkvSJ+N0sQCT/om5wFaXiVn5KX9t0/o+VivLOP0VPM73PU5BAyuCKv+g4BYX7ozL3Nw/V1UJZ/WX/DD0O/R85/GN
# DATA i4RUC59Xi8Us237y5BJ0keUQveJ6uJPcJO6cyRowH9UFw3HnHbzY/RzrD+bOQYgfafu8vrkVbI44+afiPdvffXZ4cIQ58BTDVYGW
# DATA WZolVE1J35pgsv9Kf1xyrpVbiQaby64lX/qPSxT8VYXQ863m0mxbN1NgwA4LxgMsyV3mLYXp5OmCMi5Wb3rRJXyse43oNQSX37fC
# DATA CTpNG6NA+JALRh5EfFNjPu6g8GpFH0wXpIZaPfLdBQznAzfhODeuli1ATmARzoLLzFQQ/WTl+TOypk0Tb/UeReuNR17PkM4vKfBl
# DATA rpWocSdykaVVe/gGvafnMAUp1jZy7xvkYo82LVGNOpsFnetFXCnIir52ubzB6cJR7nk78gzMnY+yFa3OKxf2ggLg+WLLl5dU9E1G
# DATA StgpnQfemiUd5OLNYO5ZvMv5U0hGoOmAZilZTTgSXRlszcoPxlnK1E4WaCYuMfg9CbI4q+V63b1OwR4MstfY8zMqPoieG+4Az57R
# DATA e9CR/1PMUObfI+w4Ho/czopXsHBunEDv4kOeFmDvoqC4lqpgaW0cTK3HkzBJuKihmEN3M175XKnYnrGxjv0pytpecwNo4doX3fq5
# DATA Fp5z8+XCjabxS+oID6G9/DEqwVUS0wNWhXO5faj18q0PrTrCqRmucyu5/nWTpHRtksJ0MU5Qti7BUV39cMev5x25Z1zaUrkMiOmJ
# DATA dgqaRhBREg0o96C9R+YuGXJ87FhaQ22+nJbPpaAlFunD6V1UOQVMnLphMFvgBdAyXf4RIyXqI4OyMwF1v1WvGsArThaKGjFbRNCa
# DATA 8nDaj0/EEaqHJYE1hmfooIqjTM95nEyShZubaWWY58cGkKwV5CVx28iqD5Hvg23EuaPq5j2+b4svGXVCs9KMI7NmOrdJPI74KBTe
# DATA RgBvbvP7HPOVsbAW4YClljLpEypfL6RXUnUWAy6sqAuZOylSaqlZFq1cPnc5T5d0f4KaGQxhX/mnXtR3Z8vYYDpi3mP+Apm3b2tE
# DATA e3eYWPwxde6C46yI7t298LBslV7kGp9SVvd1HM8EOLz8AJip2jf0m6XL5DcRYrZZX8GFg2JFnNaQlm0tCY2Ze1SB/M7WC07c8L5M
# DATA bt0fM8AH8xNeyn0EVlV11QVykoR9hPZtsfmV49RPVXbcTofWsKy/xNe9R9pOQ0chXaQa4UE91qcmouWXKtYF6pqTIwC4rtsPQh7l
# DATA wNakqAYwNKl7dzkzpdsVHTcskEErvY+Ld5uqdLoAzhnm9p7L8Kwh6TAf2uz3sTidpybGJM59mC6nZGk6nkhp4Oi9BRvbDG9pwXzY
# DATA GO+bA0F4D0p5M6/Fp9IxdiSnaOTow1VHJ5x+sGKv/Mb5Xf2jHb3pt4tKcp5omSkoAsaDmyfaXi8c2RO7A3Yzsv54Pne9vUNo9/re
# DATA cKRrBhRw8QcvQf++r8XbCN5HlG1iRIJtmSgex2jTPgWe4lMR3qpihzMgQkodlNr1rq63srrzCdXh1UtTyelsvKSf7PiNxwUpLT3i
# DATA VH8sClvK8rCaYtZEZh2myzFfn4dO+PGtUmyTxbrF4f5GpT1cVAD5rcB+Z3tntKksxPBUVw+mW9MVg81RSqnybVzrH1yE1zaJPqSg
# DATA L8sejGvyVUw7ynJd0x5ZrVWelxVg63VlQz7gy1aS2i2LKy5hdVcbfSGZ/b+ec1gXafg9jvFA/Zdmr9Fy/b/1Xqf3h/qv35X/90uJ
# DATA qup8QOEccpEXO13F9keFBSx0ZnD3+XtzdVvudf9W/Zdgh70Ek/vNGm+w5fuVei12/Qk+6Exqq5zlYq/DTr4MhZUYzfeukaZ7/0Fm
# DATA Sky6Wk5fk+9tATxxHEyGUbDtHFGwrL0K1sjIR2gZIqUIUn/ukSN+XlAhQ4W8OVS1CC6BH2Vg+yjlRy5vpvmYKJmVzm5p+dTgiSrM
# DATA wpeBrCr6Y1jcwvc0f9xkJ8X6LqxsVrlak5MMuSIAnSBwHgvl8XOY433q5Lv/8u6XXNtbFfL+B/jz2/c/f//X7/5ZKHPz3W/e/T1e
# DATA Yf/un7AQuK7kIfBn1kG/3BXUcvmnfabOPJPzqY8oM3/34Ayo1rjMgEqPYwHy3zwwA0qcJu30bXBeorTui20/ICINkECZNHhO/Nlc
# DATA JBTIUtAVnHyT0HKGCwzKgbmqzxKCkhM9tRC3mh40S9DxhjRzzvhw7ynHUfhnckYI7hwfJgdsCTZ9GpwulEmmdhZ0Ordb4o0OycJq
# DATA KD88eBbw3f+l8Mr13Anrv3n/N0RSWMkdPmH59/d/QzXh3/8nePyPVH7+n+Glf+EjgwUF9IVYLBDpGAJaAsDc1J2yTEDBJOq2kXCC
# DATA +QQ+3D0I83/BwvO/QSJ/9/dANQjLb7gsPpalB0qxCtNjvft3/wxT+Tl8/9u18BLJAIRVE1kg2M9zcF8UZ4TJdWcjK7D0Vo9yt/kW
# DATA NvHdJtgjyzebb7HDuxpw7trlz0q5dKyZcmGM7gliWT1vv2UodeG/CzUYD1NasWJM2IAuzqMlUCeTrIdsTDjnex+TZWlzI1gIWIZf
# DATA vfuX939XsIt/UaoUnbtac+f6I9HxxxINK/HV7PkT8WZ6+sJNdmB86NSY0f7i3T/Cl1++/2sf/+AHIDOY3b086/HHXlyITRUAvC2t
# DATA uAKAigWu7YQ+qkjYB88attTf+bTXfk0T5dsh+GeY+8/f/Qv83y8esdbEiulyF+LfBBunZCpZYyxKTPX8H+y9bXccyXUmqM/4FUlq
# DATA jrOSXVUA+NZSkUUNmkR3wyIBDgCquwXCNYmqBFBioapUWUUQgnCObNnr8bF27JndD7N7zuysz+7XPUduS3ZbUkvn7C8g/8L8ko37
# DATA EhE3IiOzCiC75VlL42miMiPjPe69cV+ei+chYC09J5q+d93aL9QBWGb2mS/3RqdDoOjLeCSWC4cBP6eZOZiMTtWVqKM/6cwmAyan
# DATA 1IX3zCkRX5F0QuX07AOBwXkuC8hejBAjR/wFE+KfvP5H9fd/ev1lpGb4l5h+5BeYBQR24m9efxF91J9+PDvwA7jL9ZRiDBTjiohc
# DATA iURwwCJ79BoRHDSY2o0bt650XngzwAB+UrFJWATUAokOV1Fr2p0WxT4noQ+QvKTlS3wVMuOSyG9lnFor+FFglP8NGeIveJEopwrn
# DATA QInUQtEZUWcmwloVPYyoVjeUQnd3T4pe+74RlVhTu4Qz7cFvToHLBwwSvtUK8tCeloX2cexacgLhhDcusoZ9Zz3Ob9zAl05UDHfE
# DATA SCWYgRUFD/NOCyJePIzsuypMrDeGQ9fSOy94JKEJ3JItd4NqYAu0aHF2qBr9wxSQN8YATeOUW1G91OJTtQXdhC6Kb5wREAoDTZ7z
# DATA Yp/zg5rPRjmTC5QG4sq99bdFEUbRV3lmHFpBspkqDlIc7EdK+fNTgU2Go5rjDuBInTwmR+5cqBbQuxWqKUqlgVH/Z+z1n6qB/A2I
# DATA D0q+K4qe6tHniqz8FPnQF96UgPiqvnrzl+IowkPnaoT0xsAu9g/POhwny0Bjcs/0A1drMapFUEx2Pl5rqEIhuicE78/VShJpV0Q+
# DATA Lgtcpg7Gk5aSH99xmD1aL9DnYnZSO6FYd5OZVZT7VhkvKN/Frz8PDl6NG9bqP6Bc8ZsIMm0ByVQPfvv6n4XcADQqd+ycCwb0s2ju
# DATA 6FRqIjK+yCrB0byfd9KDfDSYTdkZPW420T0K3wLQZV4Sy695aM1ACGBYgMAJ0KACiwtg6kKDQqTaHWq+WPz8HW7/n0XBif1lHByX
# DATA HkG+UNPA2z4HJgb5x9RR+ivIgEbH6VKNY4ugs/Zi3ME+R04UIWiC2OgkvDytLM7or0eT4i4vfKxhG4J+COUzr4iGU9Ec4VaXdczJ
# DATA Ne5o8dzp0kU9UA4gjL67mCq0xySHrmf7+5c4fEhgjJwC1PAXwBxe/wMcNEFBDc39Em40eCy1CFN6oSEGh9SxDGdCDMym0y6sqawo
# DATA uK4l9Vx9efk+8+dq1P9ADPbN/6T+/mLOSltIJ9FliaKhnSrFrcBTv+oQManmFFxF39Xmr/F/gWWFO5la1j8nzQwd2itwGxyblKGE
# DATA 3tOGKBNzdNkn25Rr/C/YeyUP/Wb0cKAktn7XGkFBg52jCx21xUz2nnWG6DmljEzP6mESdQeD0SnpAP2Jq+upNLf9feOTyq6rq/sX
# DATA ji1f992eSPMINxx6K/BFgVtewJ0JszL+A562f4LTVXb0tKAGnhBtp+Wlwrqc+yI0uVOsOcKnkhJGuXm3lbOEjodGP9Vn6CK8rHn6
# DATA MuvVSLnvruj169cfQo9wbdQ5n6UDpPQ9vqewl/xQ2zamxyloLDi6jRwXLXUF44nLEwz4FOd6tXhERVkAj792UiiHetHDYJSiH1dg
# DATA vVipovD6D1KFcZ+CaX+vLaGRKqUOjdKFP9DPwwqcRMC/9ZZKBpuPVJ66f8RcqKCRVEduAQVVmcByGYCoUlZU6h8CZiKx4mArcKWY
# DATA Yj32tFhxowLmyU8c77Zocb9jlpoijpWmrbnXuolKglp8MBgdUCIEuvqUeMAQg1wQdsqbicsyzvY8xunKKgVwLK50KSxgwqbVYpxh
# DATA Dfzg0qLa70VM8wUWur/7Q2BmYO2WJkae3JorB1Euh1zmKM4RUC4hnHy9GbzJ98aJotWaRzwpqMAkrSIhtjl+eDHy2XcZXjtNj6p9
# DATA hoxBdLH6rI49/n3kInfVbVUltR/cYsNCVeeihbVv6FXToOuAX/qetM2BTSI0zrRIrv8BVUGm7aBfslbziiUj/D8IHTbPCvnYuVdw
# DATA VEynWmFwFD+FekGpHk7GTg59ApGI1foV1fk52vm33A7aIddtTyvL/YnT6snAvIXcPv2Z0ae3yFw8NSJ+CLvLUKQC7/XrJhpQWjOL
# DATA 4uQk2R82D2aA2lJSfZ6V1qNvav7MmCusnphC1aF89hrCpi4BDck7tARQhNkrtoknqthT2iiAioTfJ3O8d4kZ7Zzl6kaz/krd71av
# DATA 6HPoZDP6ffj/KXHx/Vue/9/qyu0/5H//2vz/difpMKdDqS60lANLMTKI/8k5xgG0CdlE3WBtsLeiUyA5j2ZTKou4IqoI+Iyng3zx
# DATA 1G/d0fjs7ZO69Y9U582vaTpdPJJcp3qbDEDkJuQZ9xm4MYNlFvvDz3BEkS2HapY6/DUb4t9uCjk4yJSXZagY5RQCq+Cw4y26g7o0
# DATA JWtZNBiGjVGkWg+VUraJUXnZzoD04B9mbAOewHDutshM/4miATpWQXFvWB0lS3ZBeRU9MeSBZF5LB61OZC3q9dOj4UgJ1l3SeSjZ
# DATA GWFnpqMoPx6dmo2CRA43CkqzM+4JBZDhjmHbt/qYLE/4qh6NxrQ7nZhEBnDEKaQcX/Iuo5PguOoH+qZt3T+blGnIvKxEmfNnYxGt
# DATA AniL/Cl7j/wzGPLcVCd6ZJQNYW7ynmIP/m91Wfhn0LAVGkITILipuG5twbQ+Op2QhjuyMctuf8w0wRFDRMlOQY9x8+16XWkfs/ZR
# DATA cKsgffaXvtuFuo69/p3rXAF9NlCx6gY27aQIYCG9hvlAmLx8cpPZ5H0d2Jw16z5cj2xsA+Mciwki1wz1MUKap9PmTmfjydaj9Roh
# DATA HU878M76zELBP4pWRootlkPTg1Mbf61IC9y8R3i3zdSvRXbM/4631J+reVRXUrp3/gp9bH4LOqTfgX0ZlkVdQ3+tZrZwJ//Nm5+S
# DATA /R1u3/9EfohosP/1m/8Yu0CQHZ5rvqrybDtOFjE8ilt2PwIcKMWCtCKCf45Rr8o/ox/D9KyuYoLGl+quBWpdng31AK+YBDehn6rf
# DATA fhKQcL9aVpeqJjTvqiPQ506hXDecQjy4B5A9A52KcJXN1BPU9ta4fBgKm7MKwB45HIFaXROdnElcQX7EhlwFIu+nnceb33X3k9Gd
# DATA miLb6x8Vi5i3jza2K97ubD306i/VuC5OIGHbIVX6OWy6X8ktSTZysSnDjoQV/SPqJR/RqXr/fTJwlB6eSwzs79R+J+XO3+OQfhm9
# DATA +XMiauCSWz0gdZzQ+/sf2X9XTwR8pCgd2ptBgfQr8OBVj8jlrSYauLuiBAivlS8iyN9hnDzS8Xhw1nGpHf0DcVl4kXfYqb6kYJFW
# DATA Sd4QlCNGoEMa5WRpoPJ7dI736/B8q7P9aGvz8WfqrOIvtb3WH+5ubZsHm1sfbj1+vPUJg6nKSyifD1XsEE+HbdOxMtacMy+OOmoi
# DATA TaeYROzXI/2EqMO+s8OLBFlbvExFTJJERUSUwmmmLktzvyAvQXT1+TW7G8CuAALMvk5Aeqm4kCEct1pc0bD2okDvQrMKU07YfPat
# DATA Ha6eAEJwwLbIo9+fj6UgrqKqvDtQ0qXTMsfwmCsF+ysKzQcItJ1+T4K4F6ILino1sZvIsEjpgEn1kvW4Ga7bmUkb7Q1tpEN05/JW
# DATA mDE0GJ5ZW1qXUd9HVoS6ltbJPFFVNKGUSjaawgUlN58UBpkDHHSNxwAAtAGfEUeiC46CHKuc3jIT9nqlOhzqlhjJUqFq9apQt3om
# DATA K3cWU585T3W6gETznxWF/HuUANF1ULcNn2uBsbhLEinf2RuHP0acZ9tJO9Nsh4VoGpiawhyaECIoQZtqNtRYr73YUKDMi0AiY4r5
# DATA uYg8p4QypBJfkjUiUowJbAi/JgdqazZBroKu+/+ADoboS4iiN8aSFEXmOvWwDs6w/FcMKM0kd+GTvRj0BTv80LilMuZy51hdC/Ut
# DATA zsTTAqlwuY7w1ObCau6TggyM7/ChumcD7gXfu+kjtKK1likHDT2hoCPtSQ8XH/emqCpoQhfR/qimnbpY0S5/M1OzoK3U8HusLsun
# DATA o0nP/FY3ifkr97c2nuJPpfLENXUh4/gSVlSJA39GHvDEIH6CHOE3ES6kEkQ4bglE9Td/iSanfy6/gBqQMauyqNWg7xirp5epzsOD
# DATA vQB//XCWAdIr/Hk4SY9ObBoVB1yobCkYr0jjpKkC7JWisWIwQLKTDV/WQCXLybslQM2L7IyfmqpDUWnpVHUeItMm8Z/UvtPKXsGK
# DATA 7EXPp/vvJd+BfWBDbVSNHD0Dr2+0mzf+TSzJKKTLzkDJXeNaCSUIpKjmE4+uwgsCrIMkAaY8hYxGnRZ0H2hI22xFXdnhID3K21hl
# DATA hT2B64d/dCZknQgZs6u8V2yAXzlQu+pznvDxZPTqjNTf1A/nkNajF/1hrx13017vLLZ6FzO3te/cvybSijYb+4k7uVQdzW/tO4Wy
# DATA bOEEXSN4NKE8yrKmoSE1P4H7cDREtDT94ZKLhgUSxGxol2EYWgceHi+BmfwN6RSme6X/Qsd2qPmBSDjkYmrxloFZo9DHo/7Q8XnX
# DATA h453CEzKSfIntef5DUS/n6D59nn+XlLb+5N7aq/W7iUF6EjhDUHj4WSG+I86S7gANHX06CZi7tHft/Zpx4UsSEoUQ264IhxWhxKQ
# DATA xc9tjvtQIMUASAL4VBDeQxEwkOzxlOmOSMA3HURFceq4L6ozeJuLz2OKRKVK4BH/rWs61zUVs+G4wVWA73FIQVayJ/R9wOFkiPyd
# DATA J5SqwPN2jno0rMqN9caev2c8LJq4aaCBJGr4Dy+8yy3Oo8Zzw2ztxb0jswvmjjaRd+p8zvN3wFTgdgkc4hcoQPwSZAUUEr7Ea+Yv
# DATA 6MnnIE38Dn0VPlcSxd+op79BpjPJIEYiIwpyT15i8CIDlxgK1UCFknnz5q/jcjA6k24TAHXqkVDLFOQ0YklGMWyVcEAA21afZI6k
# DATA eswSJlRucgsVUpYX8vsUlaPIyow+Drsnq9xTbe0jeqrRZBUyi2EucJ1mHpvA5gsJqOCv8vPPsUUnpPHyFLNG7/H++++XN4BA7Bdy
# DATA RVTvdWbNXl9HgJj1YOrRknMdWLWl8KyYeyIzMd3Q8CXCjoF9HAXJus3GYRPhzdgHEkuQ1AwfclgvAodWyZRFiDJT5x795cC67tm9
# DATA htpe2yG4EeAHWuvhwYoxUyFcMZxk4mAEu+nJLlry0SYRFH76k9EQb8Q0o+reMKVs3HlAIioJc+B5AgFPfW4mfk8L8LAk6AsmdC+a
# DATA 2PFlRpuEZI/86dcvYuFWgEuJWs7CslJfQF6DrtisPPtuiMtiUp442gDOQd1n3Se2G8jagIX0CbVyvXdtDnz5zWj3OFMcN59GetfB
# DATA aUpn0+PRpK9OXf9lxoGHw+wUOnWPxVnKJkR2rzEAsk5Ho2LOjUNtnuoPy7qAmpRJ/wjxV9vu8cIFEVp0E9hH614XdM33AgmMHxgv
# DATA dmKvsbpPgKlaCC4TqEnwNFK0alF3NSgpO84bQToj7gK2pnPVTIvW7cIFJrTLX75FJflzu8Pf7Dnl99EpHarVhxRsAtgrIOiMH2ge
# DATA unnQBfpozAeJQPYUw/yB2vUNDEK1GhJ+jAIgQwXyI3U4vGBSW4k9QXV2bxdnCpo7jOucbEv3UlMc8PWC48iTToPBOz0PBMYYtR3D
# DATA MHYsEU7qrr8RG5NrUFSPlf3N4huxdcXXYIN9JQtNxqMBe4PhM7UADbSDz9i90AHmlLoX7RUfQD3c4wThWi1Rj24IXQuoxvtdND4z
# DATA Por7Hh13dzSZxAL7XptIOovkVzqA01glvd03KiNEwzPu/RVUXEO7aSWmdmWC6GRcMKGPgU8FnIBuZ097/B6MRoOaxIrjv2nQO1Na
# DATA BUM4OOGWnm3YKijUIPFuRbp5/KyFbhxKnsnG8EeNtpG05enQZGPNcz+g1/4+n3AXWmYwdsA5jzi/ELIGdBKIIQvQ8NNidWrqSnuD
# DATA t/WHvhjoSTPI+wsnC2QAK+cs/AmThAa33Tw7GcTF/tUqKsC0j83pKzgMZITGcaOjrF8iKeScrfBwCIyjYK2F6TR6gwxcVIoqe61N
# DATA c5X3dXBH6ZxkilfqB2BNRxlV/gamwr/7QwQJlY/IWU1xikl2mg4G8pZplHhWeiFPppp+Y3PynY0xPE9WZTgDnBHgITXKhOoU4lun
# DATA VgVfay+uof4/1H3rV2Ahf/OXbOf5pXOvMncm0xbcylBvp0qBKs/FVgDjPN2wIA7+r61PiZ1mR9RHg2ig65iryn5iVPCgMQVyqyUX
# DATA pN2D0ax3OEgRpjE+6sK5Thb0kfkFoRehMhMAcgzq1W/RFvb30e7jnZJBqf0/mvSMJppNOgtYjawGXu+0hafEfmFmBCDn82mWomEC
# DATA BP1eOlBfvt0M/IQcLECF+6dw6YZbuT9+7T1iuuTaDaDPO+rdE+1mbvqZhO1lNEgY/YIDXGx8cP3/nNXVX1aN7vOiSvrnb/7CHzWq
# DATA 7PHsixMNP2uGTpilpR/+xTYwR08podbt27eYp72apGfBRiTxIeFS/p7T1AYV5ta+ZZubtxZozrQzjy8gEOfcnQAyu6TjPrYAwoud
# DATA rbod0wUakm7NX77/RqaEN38drT3dqDuLBbATjEPx8+hTVXPBdcEiT7DrAi9gfpxOSHs6x1rLzhohyysSYkeeCRjLoFayGGJNopTI
# DATA +YrRUj5D9ctrcVuUthK4pSY4sIKN2QpkdgAt9A0j+WQ0gMmoGYuVY5SyoyemxXhV1jS1gNXbeBAGp3LJ85W3pjMxAbLSZxMECt+L
# DATA 1dj3VvYv15dCa3KWYa0e0TCLdfFKkt0OjgeXTFyvSTWZLjOumJOqAQriRgvkTste8Yt9ZzKqO2V4yvwz+F8s3ktYKVtpuW1Gr/8O
# DATA qepfoo/Jz8E8+EssTsFyZBbXVkXAC/wSP6XnzJV+zg9/ZQB0aEo8eUo9RH0lvKRlivUsWCGsbWbDFUgM53V4cijQrjhF/w/G1v2Z
# DATA nBrywEK0HOuSSFZQQYoO0u6L2Vj4L9ADcqHgE9dwYBLnZPSl7zlxtM4NDR5ZMom0VYHirQkldPJzRJhWrRVAKtaS4kuspk49Uf8F
# DATA J0fa/i0rV5ekWb/AJF8gKpmfdBlqqeur+jE+BoDVlvqDJHfExKOBcLfoR3IhEFwrpF+XfQVFLJkKgUDJO5Zf+1y9mlt7jhSO0JMU
# DATA +CYptq29UN3nnZaFcKG9budU0T8MjeFa26vbC/7Cqxm8/JDnMPbMAsU6xQXZrZqWJTs8VOwINI1tdj1xKOi1MBXkZBNF/oqjPDed
# DATA dliY3plxMNWddPrQwApC2+KqWNQW9EoIdDRP26LKsrkZ1epVd+GHUIy0/55tZo9RLlhnEdR0malMGDOaK9chBcU2ddqVV1AG92CD
# DATA 7LvVkLc0mnkCINXL0nipxt5uMIMqUY864jAdTrL8uKaDTk3v6748U6+wCvhrZUK6yaWqQzSp7V6s9XSHq8TRweY33Q68FqhCCCq8
# DATA eA/tl2BVJXjn/rCZZ1POB1CLOZMEafNc4Au06QP6BH7cCmd/x5d0guhZnHhmHyzhmH3oG5MUEPxcyDEmNs05LLSQfhv3yPLLdLI8
# DATA 6B9YBNhlxVTjxV2V/y9zuTIMk6Bbf0aeqH9P4SEmTt34nPoaC3VJV5LGf5W3NxIsfomx7VJm+Vw7Ian//kcJGIVzrPVz5zEoY4DI
# DATA HPQxfUPMqfmII9kzqU57N5tAgkBVhue/VTo1yArTXgcyn2shXACrgTJ50P9R1uuY7bLHm6B6QavtsN5giLXgBhBp/pY11eUN6Yy5
# DATA sF9W9uVwA9vporpLge1dNUZAYhF7c19kYQT/YTFRTsXFCTVDd89LyW5WtMtFBIc7LzdpwSf4gUFuwMm2ntpmB/G8miAI/zud/BEv
# DATA l/blHlWIeB+8gPpChexAluQq1D3ACTBb0Bf8v/o+FhgL8ReoCvwSXDb1FeBXlU7jfKTvkYfFbxn78mck0ZNfYMlcO8m1Xp3ZUzCP
# DATA fu8ZKrofrGLvJgGLOJYAM2+Jt5062qcjMLMOrHp4jXidPSejEnMJmq0EtKnlNJhUymzsvXiHe+BuccdS8gQHa4H1xVZ/lIG6lNLL
# DATA V+53VvqYD7nZpOAHRbh52Es6C5eKvTGuwKhM/pmzV+D2ByyAfUjD28vHP3JWjvslvbdUj8Vx4VxyRjhTU1p8W26PYAEaC69hnAEK
# DATA 0G5Mi6zLl0R6vaz3FDYofgd8wCtB1iu1sVwhFErvzbEI1iMhtfQPLy3AlazatnSrYmgYzwFLgy3/z6RK9u7vCFqJsZNFrcCXi7Du
# DATA LxhN14W1IV3fLzDODzDQf2v1y4GRhwbsv9FCAH7umPKhJFtq7Qp6e4Nq0wZCIWF6L7Cewv3EC7IrOtpexu6KTXs47qXde3sjLErx
# DATA vKXxL3sv0QdTCk41ckJtgoV1zk1FXKjmXVdq4TVyjSdCF1C0RZZUgNoE6+VnRuVkmQFCqG88ODqNj4RKk2pdwhVUCd4A5gVjFMA1
# DATA 1WHdhF76TpI/9+Tke3DyOBCMT+eb/2Rc/UHf7hQ3Cr3PkbpLHZ5W7Pmem5wwB3WJX6C8IXEwtfd6aGatXXdR7QnOWsDLmFsRnudz
# DATA 17tO2jDbh3jxizd3wXcxMg1Jd2hyOeoVhRh0ZwifCdJYCzJHdew5im44q47O2HE/PI8/3N7a3O2sbz7qPNp6sraxCbcIaSAQI3+6
# DATA trn+2BbTb6xcAypsyoUtQnDUQ28SyRsR4mggdWq1EcDLOg4teNRYD7qoL2elui/XYC+vtRfVzrtzpsS0Zx90nj774PHGQz0VuiH0
# DATA AC/Gl7hoeFV+lntDcsgx87LnarPwDj9EXRvKdKfpy6wRQPcyrppLBv8osFcDG0eYPYL7hgvqbGKSgrUpZF6SvbY0DnrmybYxFibF
# DATA bhRFIkdmKhWMLs3JdYOj02HWcxoMeXZJscz9oh5erqTuKOv2E7EgcwI+r3yUQgdhf+kKp+Xr3K7ngVPVqjhTF+5S864sHOUnGnKm
# DATA dOHDpcE/uOQU4NqRtcNCh4pg1NbS27cxf6G+CgrrskrTflkn2fuL7T77e2hewl8JbiX6PuSkxqWWCnchTVbI01b3AB2m2TNbROk+
# DATA MuZqQbQ8sEMi5cJRm+u8MKkK1f7rdQRtNGbgshNKDN58QfWQkbEdSVsSaQONNE1loIPo4FQtPqSz6Sj2vaTf3twi6y112JKZLXhY
# DATA tqAx0HlOW1ixHtsizluoAiv1SOGG27rHV/YDKvh5fe7mD/vlvRJQehND5InNsbWt6t2K8lwb/yvMHm1Hi6wYAXsg0j8oBYI5pO0b
# DATA R4rgvtkEUmErmsqbvF1z6J08DMmcbWvIQ2UzO2Jf5e24zjFfpVTWEpLEGm+dU1XqJyOreUpZ8NgqUeyh2oUPdZXtQiPo5ol32DZ3
# DATA 1HObwaarxyCjeJG6lU0KUkN/YkKkOvEq1H0ka+yNG/ypR7ZwJqQHj/TSrsWQhq57DFamcQbpx9Xu6b9UBA5/JqXuxAGThvrL8U9d
# DATA 2NHH90Qi74NOGYZECKyBPiniF5iKOPrN/K4KgjMlyaCZWrVGiTjA5VC/grHv0zNuu5RfJxSZgg6ensaGYh87ZkjuFY4B9So+uaKM
# DATA MK+iq4kLZbMXupGVCQJyGfdtHDP3strz237pX9wWGOu19gL9D4TnUqvWoY4euLo2btUDnQhE7b7Ae7xn+hdN6B/JUhgwPSxzU8Wu
# DATA 1K37dDWxe05wp7UuhoTz+YtRKbp/M3qMgfSEIDnLOcs3AajEeTSeHagRRc+2H0cEU0bJSzgenmBh1AxPsjxvLqYdoTgHyKo3yQaU
# DATA FGPIJIA3L7lHlQb78WdzUHpKUw6U6XW5Wg9UeNgbK94i6aPcEbouNCtpfe36k821T9a+t94hPY2aOnLmDOk/cFl0I4kDRKIow4Ij
# DATA KtvqPCLEbjF/X9qzh7+sdu4pFtr31OELHalANXApDU1pywWY0XPoU1Q/uSrwDdpmlwRZCiEsGZZnKi0BWwoSWPNRkf6Eabn9YL/I
# DATA r73akJGA75OJdufAKNuxb0IqAwwItAGMOWI6HGf9iQ0zZaGYcAteTRkfRHHuM6YDNpLV1ANmDvK5BPODedwwwKNOrBYmxaVQrSQ0
# DATA z3qopxNFE2wco+fBJDNVURCiF6wpI49l0ObcOEXCwOdgFKcvZpAxXkUY/Av+dsKmQsUMTBIh6jNEcZbz/tDT7yD0LbCqzDvlWNFX
# DATA V68muX4bpRylp1RnbmOKQqz8LvEjycNhj75VT5t3TMwuifzlxh6jvxE6usSFG2EzGgreOCEMulrMUBTuoxkAayR98yBp1mmq4RbO
# DATA b/dDqX3yEFnmDVcIlAUn3LEJYe1mDXVIJ5mMdu1l49z8OJj1Bz0OElbXC1SrgDm4AgHmRm0vbvQYl4+niVwgqUr0PUId6A3KQeTC
# DATA l3oTVOC2ZbMVlN6Iiae9s6roVJ3dmF1btXdxDZXQrSIgpMXvbqpu1PYASDt7lXVn0/RggEHGG3EQSxv8rSiYGneWaak5Vjsvway6
# DATA eh1QQ94Yk40QCRR0BqgE5F5Bb+46YoWPZtP2rZUVViBTbgDRwR3z57qbBOAyHhrSRk8eGjIUMHr9q+jj3d2nOw0dpvPmp0EXIBtI
# DATA +IXGYCGgXnYu+kdUs4Ab0q/VQUSgcLzMMV1S0h6QLYmMy67s5Uh3RJPI0XyfbslwJAYZzTPUmfUaUC3dl9kPPQmCjXJ9OmW39aFe
# DATA A+HD/SywmwKu1xbEcmEmuaAFQzI+EZTL3vXorPz2bPBqrG1yQltcsRlJiGLXJiKpwqCHOYJwHD6n+IBGRNFJDh4rf7dssA4wz0ze
# DATA pCnXOUkDuOaSq2puyFVwpYmjfRGwIC7+ReHCYFx3rXmZKgiABvEwGNXFgp3mAagIqrc5G6LL0kk/h2tTZ/TCq67oU+IKD1RNXUAD
# DATA MRqQ1wmLElTX/TshDFtKwBOA+RUHR/pOJRb413Z1rgTixrLY8912T3RAPCLrOolDTPbVLuygknZxwlJoFUcM7GhOkyIAwDlp2l2t
# DATA hL1xe+Rikxhl2zw6EBQCHHkKw2rxFLpNSLxmHoBQeXLo+4vsTKLgXpIWW2hVEfxj5nGR+HUOKNNqee1H/k/oXAJc5z84qvmv/rTa
# DATA i3wBW4sPqMTwcqG2uEC1KlM3cK3tk4VF3XwL+RgcnGeM4/vZPKTnZiSTUmu/HvYSAiR+47jnmEWufGAc2esytMVFHsYusLUN9YFk
# DATA Q/IIqZ99ig0MTVDYdsZpX7PIgvUF2Zx9WCe8KCrs4N/MsyB4+h6S6GySk5J8TuXLbhM4sUxF6WR8n3wO3RpGe75FQsnp3vW/SV4k
# DATA tSSQ3pHt/VPWMJ/rKW95K1CP5BxwdAVyePE4aQpXdvWFmlNZEmBSZYmLwk1i8cOuU17S3d1AfAVm2dmsohFz7w8yRd0rlKnqRsqz
# DATA yRkchpCUXHs0VN01faEOE4Ci2BQU/1gs0sIfdi0AwkU1FWJLkzlTY+UvMuxJuavuGvgvW9Xb1WGkUbeegtbGdZx1xM19xnOU4mB5
# DATA 0z5FC5Wk6j05szDiikHQK5CD6f8rvor4rZ1JNsgU4fWYVWhwWuuijZCODO+iE7VcRh/sbuIjGl0EEeZY+2mOaJHMtMpw4VjHGYJW
# DATA KEX1Q/FJfuhgLLifGfN7OVAc1eSP1Ci8vIn1ywWrpYRYqECX/SyxWJbNjakFPSf4xxWmyv307SZL1/XOpmv+OasSt8sQ5RbURgbk
# DATA C+MG39a+vq3gbZnR6CDsBm/A+k7sqN8wIw8aEVD/i9XJP2TWUsj5qvXDy9m0u4yllq37PJZJe+l4yvh/nmN9+H64oLahNFeVoww1
# DATA Cas45QD+qAn2JCObjezE0lXyruaR1AuusgGKTWMH1zhwAy2sd1ETFCfz4u21rqgQ/bM421hUt1RgaFYqMtKeT3KDclFI5BH+5wtq
# DATA rgo1dQbp2WiGASwOJy/ymgUPZIHflLL24IUElmVpsaVgsfwD9f06/qlIsbiyOqpK9yZrUswYWr5Qjpm3hBwzuc3KAD7s0WsFQTu9
# DATA BQnhFXowIAYmpIAklCzkUvRuQHpQL+j1TN1NnuhLySKOmeRrWGdkkyfpWN5B5mEiJibTGyX+RcU+kZPWIvogvi6aZdv3fCJD+iJH
# DATA j9oqbulUCZpIjW1n5IUvqVB+WxZ3zbA4HdYc7IqTp8GrUyfxCY+RllSkVnHCT1zuoB7U4uV03F8G8ONlguaMyRYObdC+WNYgQmOA
# DATA fCC/dpFMtYnGrg69rXnvkO99rGZ8oN6da6DfXpb2GKEap/ZkpCZiNOx3a6AwX71JcC2nx4DMXChw33zeKk9/Tcn/sEuU3Qy9tLTl
# DATA 5w7mAVTsSs1cKNu0CGzzV8YV3ox/Q4mwLVat4GygJjj80cGod+ai8eqeoiasBsk5OUcnzFY5/rOHnQ71CoCAwFvae7o1OLxVpfds
# DATA Sd61/fzxSB2fNXAwAsNOHYMkK/CiSfdi1TSobQMlGVq2fm6y6pDzsM4N+lPIN/pbQrqAeNbfYbTcL0ETFxDsvTVgHiSTBDfBDlel
# DATA JiLEcEJHUKLvJCtmoULXKsUYVakIcgrFefTs2cajpi8XcipW9LdSdIja73Lo3e2V20kVWVh884UHXdva4YTnMg26MxVqGDIrsLUJ
# DATA 5zaUBY9kPsiyce0mM8qw6hTtmxFHMv7Wi0+mMGatLOXV/Mnrf1R//6fXX7IpFHAnCbIklBa3GC75a5OZQoPxk9nyLcyf14ScM1+/
# DATA /r/a8OtfvvkrCPr0c2fA6OKAjrbI6crlLmON/doEr34+BoyAWjo5ym3GL/gF9JXzP7e1jjr2VM/4WZPsUfino/PFJ6CVtCFBgYp1
# DATA L+NAx0311VWYaXOsPbRBFqwCDD8NYubCbG2tYaIamjmE2jO5TyY5clCdSL25NjmawfZ5im9qQr5tdzq9UbfTScSXTfAMTPmTWmx6
# DATA FoODwwj8Ptp72jJkDEMatl5a77XpXowGE+4ejgw6VqhBdVME8Ls6Ii+3n1LOQcXplRjXk+bF8LdWUnG66+QIrIeE2uouKQmsYaRO
# DATA W++isTPVlcPlsHFCPbN1lyHsLlAX+qYk98rKMDwtF6uqTd3V9UU2huyeuGdiuoBP1VJ49jsd6nWUNfoonlt8UtitsWdYYKuBk4gt
# DATA 2A0QKm3QA+x+9MjFsvgPlM5riUMxhiMXjLDmHTQguXobAz8kklGJ181NZkSGnelxEbgRpyeAwM3tRWKfRtRIBbHTnZQAiX3wh2VQ
# DATA dfyE7pjuGPg3LQL/4Ksn/7JRYvzAoDHI3xQMjL8lsnERYR0zAntzn5STOgpD0+RDkgxJSgT5kLAQpNI67A6nA4eFOTZhj96WpiVG
# DATA jRG6gFGGrlqsOLbqSsIZih9ur6/t6nzE248+2fZzE9cpM5JtRicGP+xhAzJJbnwa49UAWnAFIBxN8xBe1OA/dX7yeOvhdzvrn7pi
# DATA p8stA+GgtEtQwu/NTsa5JPxzN41WUUCy8hw8sdO82++32Z8SzFHDaftmAgxILWwHXec6HdyvnQ7st04ntn6oef9oODvBBYc/00Fz
# DATA Z+Oj3fXtJ/XI/v742VPppUXP6Z8aVWBS8t3oqGs+uvb1pzV9OXEEHeKIUi6pSXHUyKjfzc5IFA1I5SR+7ZwpKnyy/qo/FfZaDxct
# DATA o8pqWkB6yA7suM+5JU+MS3TY3Ou/s6KquYwYubXgMhF035vjsocoPT/BvOog/X6uAUF+hWnWv0DIvW8s8r+TdPKjA3VUxmff+Mr+
# DATA Bwnr796+jf+q/3n/3rp1+/27+hk/f//9u3e/Ea1842v43ww8ZFWT3/jX+b9vXlue5ZPlg/5wORu+jMZninUMby1dv359O0t7aovj
# DATA 9lDX0rWnGwRXhP7LeFnNo+nxZDQ7Og7FDKnyTVXLEpN1Lbrq32BKgYMFh7Q31U/VbRWvjPxT3VyO1R1T/wTCp/8e5UvoXwF3D1VE
# DATA cw8QLnWRiWlMERb9J7Sp/5Y3WO+Z01dXOWWezvo96gPTCN0HvEspwqYuiIqWdgdqQJExIdKFz9ymjISvBs1XT5MGmHX/ilGejCGx
# DATA Sr+nXsicJ+RtgTyPo2qsf/aS9GiszmeMoaSK9ObTXn/Y7OfpdHpWK/qEuSOIn5DfYyTieVS1kz54ZZP4OBpieqeU8IpP9PetyBX+
# DATA uEu89E3+t0bDRrJMIyfi2h+OZ1P90kzv5mg7I62wr0kEXYJ+xwpFHhqFX9CbDhevgYiOlxPFqMeg4Qe56SQ/UtOvjoPa8nVI7qba
# DATA mDs/0LCpX/3xA8w9fw8ODh6XQ4quQZUORDTZwayN+7aHnU5/2J92Otwz0keOXqiNEDtAJVa/SjdEE14GfXX8mTm/s/YJPCdFr8EN
# DATA uDCaJBuPBuYmN+W1m/CaskLTnzordNBJzpujZ+pZaucARazRbCpTYdcjU7euOQ6Pp93WqA6oqbe9NwNdvfl+c0X9v1UYLGYQhjLw
# DATA o9VajS8W6fF2djKaMq3L9SWWHPJpadOIUhPv7HwcTWdDGBkcBigRy4iawWET1xL/wgWlFTRZnZdBVMUX7le8D9Hb69PGh6PJaTrp
# DATA Zb3G08kIHOwiu5zyrfoL3tkZuKC5s0kdFpgghgu/cDu0kH5fHFCQMO35k8fOoDKghgB0xez8CunftKDK/tZOYBQmjBHzAj6JY4xw
# DATA FJGKy+y6c+OGnMcLB2nULIa7F7jsXrxGyR5/xIHhoFP7IFM3tgnSNPu5n1PW9y1FXX1pLkL+qOYfaHZvhY+RLsK00JqIKwG+TZpc
# DATA NgmP4yElIW7sMpyqO1GvGqenp5hzr2FaJTxj22JxZh3rNCTcVhQattUEggRrtwRgCZzUj9Z32YC4mizgFao2SnGHbYvdA/MDhirc
# DATA OjCBbfiPIdttQ74dBJCi2h9veWJf020SGYI2A92eZwdys127VphbN7UNRphiyiwxgP3KFSXRg8j/dp6BxCdeIMLp3kAOUnX3mhxl
# DATA JU5NzJad5I7Uk5DL7KXsIsZniiSIoEGjyjDmHidZo7e/vJqBxt2++e16dGflJvznFvzn9gUW0xv2fnQz3LS0Xigaoj9ISle/EKg9
# DATA b2FwM0eHaX+Q9VrIMSLtLGoHkchYrcBC1IJmmXq0S5s3ZKSpmLzf+6yoT4YZKil5Yu6BpQx8BE5U0W70dGtnF3YFetf5QWzQOXW7
# DATA OxlTSI21PxRzNdcwePxQbfSpk9BNp1zvTZv6xoJQdF7VdSgAz36kWm/Opt2Q9qa0sn4+ogSnVFlT55qPvw+s972VldbKiudgT3U1
# DATA pz8C5Xs4TMk0x2V1rfRNO9hhJyd7M811iZpfumn7nNj+cldVp78vTGnDl9lEyaE5+MvmP5ylPZDpRtOUkj8COkbaH5Kq3bjRws3P
# DATA YfGc2xFqIaOxFkcFugLfZSZqVmeDAYJT1ybx3lrj+2njRyuNb3ca++e36rfuXsSUTHuuDP9Mi7y9UUbM+rA/Rem9Z3G+I5oHb2NO
# DATA MvUhBteInK+dk3SMAgrdiUBAWXu4u/G9ddSsq5uXujuBn0z8aGNn7YPH649QDuufqPskPn688WRjl55mr8ZgPoGn658+3dimp6Nh
# DATA 55iyB9kqTD4fO3fssWHA823v5s7I8MVwdDrUeoFI17RESBQnAEio2ulh4mRadPZGUty4gwUIdmwlqXsl4LPOdJIeHva7uoxc1pXo
# DATA fpuagD++vbLy/uq3v33zzu33b698+9ur+taCpbAHgULzRrcxRC/PiHuh9u4MbrC5WUTwpz06Q9ksMLIO7N5pRxejQcTDET2Pk+Zs
# DATA PFaysIXE0vWZG8rmVmd7fUdRX7WWj9Y+g38+WV//Lvz7ZGtz92P447P1tW15WSlbqFy1NpqATzI2H9lukZtMOoFDhwHz+4UeARfA
# DATA hqS10oze9vOeqUejeeNn0UHWHUE0vikojwHnLqIdtwczuae35P6+3K32MXbI7G6rk/cb39rsfLz1+BHUf5ZH+gzcQ0PXSzquwNd6
# DATA rMg1NzjIw5SdWjpiCRQZkQ2NopyMsNoSSuP72WSkGGg6zCMIC8UDy1gaklQ0o/VXx+ksR0fxbpfSLpyo3xE1EPEBbzoXXNjMD9p+
# DATA o+bAqdlc9d1FeJ5xT1kKo8nHRTiQCBfGFKrwU6ZmG3TOnPuT3iLX5B7xXKz8JdvWc0uTHmFqbP3xPYscEx3OpjNcqiGYofII/Uyt
# DATA Xkler0Nb1RqtoNsVe+hZDo45lLRFCTTRj9Ti3lPy8lRd66mLJ+lZpFodEi9IBwh6EOVjEPg17UiP0PtyyWHF55Zttdg5WG9xneLa
# DATA 0PY1uMBaOYPOA72KKe+EpUH8WBsgbipi11i92bi1unvzVuvOt9X/fb+AIRFzTx/Dan4AYZKqPSbhzrsdTThaZmLBSQBZ2AbQx2E6
# DATA 2AG+jlhAIK5i1jzwY6ohv0+SAspVLCxX4HJsRqJIIQNTxiHORdrnXiedxgUxbU+/XUOnxsLciW9FLq8+YobYFvhZLLOFzAQxbYNH
# DATA eI1LJVFDrenLAURA4qyNfkBG8fw47Y1OIUIyF8Ow1VyGfI9Bs9MdDVriLLDIhVpXRuQh7bNMJ87fKakLk4vUdYwtxB3WbK/JsI8/
# DATA n6mFA71TTQxFa/rsAJ/qJ1hSDtUrnue2qIuqoPumWR/Ppx+/4d0XtMKbS+/pWsjNjUaZ+HkGApGF1Rpt0zerhnRVjiI3l501twXd
# DATA U/c00DVEhoBwH7+Fso267VMJ+HXr5iJ9fqr7avSxjqgqxVQOYFF/oqg6yTgVm0s6+SjREOEUFUwFhaUK92xzFBW3sNTsyvwhQup3
# DATA kF/KtdpWlhV+Px31XhOPpIlwlUKdqmHw1J97jdV9f59UXhtW79bv3oZ7g2ouWWRhZJwxqXG1vi+N8mMwE8GOIJ3xIDtKu2cB51Ce
# DATA wOLyxFgF7jsMjpwdFK9vdcPZjEsZZuvhmxjYZoa9rMej+Wb00CxNpIQitVmmqKLUjlpR9lKN4fQ4o/pPUHODHDgFECjwAgIJhi/k
# DATA eH8kStTPBj2UMp0rmz04RbLiUg6kpnq0ll/WQwysjHPtG6LIENTUK4ck8Rs9L2RF0NsM3AxBqtFvEQ/bv2/j5OOl1YA7B9k38Ces
# DATA zb429coiBbOdrVtNTv9oiOzoPFczSzvBVW3kTi7CnNw2ELLLHJ4gE0d0zgu5oYDj2R4GP9pHoqW7ZeNuNPnpQKO1dNx3rt6aTKrn
# DATA WqtbQ+0TBNZBgAGamZcPzhp672A4gkMTQCQzcVLpYQaGMWsmkEAn1vQpfdCNlbSY113oktSyqD3YIR5D4xDJNQ/gaOkQkxz1zCgv
# DATA gn0HLTuQgpdsGTCXlkePDg/zTKjJV+rRKnlBuJVqgK25c/UdqrGtNYf0EwGF/giFO/OGqncZG8q4YdAbfEWomXsx/nKztDkvcHPj
# DATA F8UYAChoVTiISgNpHhajqjj97HygYUjVZQ4N0bhC90gbqB+mEaL3Rere3R/1Yi+EDrxqGX50j3uzXwzJLKqcEsJM881E5f1+NCNj
# DATA ScaiGDWNUXw54phBH0zeOC/+MBuC+2Qt1I/kHs2FvrvAj8TPpIglMIQYl8Tt84ESil/4rNCZEOimqOZBqJYydYr2+tPDpjWynF/U
# DATA e63QvXCl61gF30FB6Z2BcYp1GujF7kBss39Tg1rW4fvnPLiWPq28cVvUhwuHYmARjYs2G3q+7BiXRm6Qs+l4Ni3LZ1dmTyZvGNNl
# DATA 1AbAGhyALVnVczACbxqoLS5JVOw0rujaaPBSG/5MWcaTkPnJ6xH6OGvgqnrkg030D8X3clDoWzs8q4m3ihdA/ckiKlU1LnWDj8BO
# DATA cAYXGWcCdNBY3uweqw7VBJEVXePt1AZfCRo/PekYbwcp+YpiDkcC+7twtyGg2YfPdnY7a083Ortb313fBOK6rRM3og8UmYcjk5BN
# DATA q4jbTlVP1ra//8HaZufZzvr25toTVL9onWnaU8KTqsG49IhkdEaMD1f3dG1n55Ot7UeyOv0J9ElMjnEq4J+GZYCEZngG9mUZi5pj
# DATA weoJ/ae807VMaxdslUf+CjIBhG53qCLiC3j1zzFu1irAgoyrz6JEgz4BKAvLnvfividpyMsIbEMr/7Tb2qeZvuhghVbwofqT+Wpg
# DATA +pzK2xsVnheopyezfFqmr8bqign63i02MfYPWW8n7/9IAKvVyVKZs7CwZ0VWzaawjYrgxXF6BobaulTtutaXwOTwQ6vv1N7C+k6m
# DATA 7hZwLfOtvhQd4a4uyXjiQV33Scj++wUAZVOZlL807Jq+tOhCpspkYd4rKAFOJcF+kaW/1z88zBDmi24E97DRkZoz4CVK4vW4MbqV
# DATA m+TV3BU8Fjz3sZ589VD/KcNJWsHhCpxqbcd1h+GG3mkX53oEDhyl3s5YHW4q22XvgPsCBWXOxhRK0TzfaLeHWveobShMomla44tS
# DATA Bi2Rky1bphMRU+9h0vAP9QQ3KuZqbPk790Ir9cCudMiCQis6t0LGBUiHae9MPVQ3WIypnO1d1wtynRIczTSqAhTXul1KT9FV4gl9
# DATA OuczUNQptj3NuXnqfnIRyy6i8ga9AplsUDoMVUXLGP5t7hrDk6mueTTs6SRTPTg6nhq7ueSI6r5OwnMz2kbLR2SXwQ1c6U3OOkro
# DATA 8WMQ4kdq9dRzEwhHhnkig8Wj44a2m6CSM0VYYczk1Bk/lK7FaMyfHqtDAl37Du70SH0AbA7tC2egsPa79RA26KB8vBBDJTrD0gco
# DATA 5lk7DCrsfVSK8oLrBzSN+Mumg0FkCF53eVFDYgA2UMorxGRi/542YwfIYjldt0iH1bTWutQGUAyDl7pSdytPgioRHuiwWopcqIZp
# DATA mbs3w619M1qzvklgX1Hy72Ck2C3rmCKDRUIe6OhIDDgdw24fYKARJzs6UAJqb3BGd8BmsCEnJPntpzg8zfraq7kXv65iXuVH+SGP
# DATA l7TZEO7bh/09yeD8jc05n47sfATj2WGrGyuITb9cHBOqpS/RdV21PTOVlYdc5uazbn3bV2yom9lhI9nR/NqBVwrtvRImqQfAZ3w/
# DATA yC5ZFg6wR8G9AwyOlaHM4qipUm648/HazTt3d5492UG/FkptxWEQzfw4VS9rYw/Z9Dh71esfwfFENU+EzGNMeRHV7+fDmMxBKAGj
# DATA Pl7c3I4Go4NafINJf5K4PJQoco+5GE/Tdd5C1/eB1UnOKAuZ51RMu7U5ZeghFLBcx1+LuYwunaDOmsxf9yIx3ahXyrHpmXoM1ncW
# DATA vZhPKcmPjumoh4cqDkZfXynwuhjGi/IQONTGfvTzvUBxQXaC35S04l6lFmqJNAeLNoBXlwZcXXQ8N3rOqUlL1bS3V9UNPdQISmnF
# DATA iGjp+6V1h7Yy8bqsO0o8aRAeWSiUOdSTMzQTlAY+Fz/QN6EG34SqvtaBzMEYZthpq6gld++A8OjOyoqQH3Q8sp3sVrT633/yv9wB
# DATA P0C6bxqbYuBOZ1KVcCDp3IDOeXGWl7yLiGBMdB/+452tzUcIv1x6VSGCc7Ubh3lqiAymbSCpEuVL0NuQl15TmLkEAcDmlTQMyJ6q
# DATA ijaHQ6lmk/LY0dUFQyz/Rf/PT43x9cd/vn9rZeWmG/+5urp669Yf4j9/v/GfW6fDaDRUwvQUQYx6WXQ0Sye9CO0V96IXWTbGKCc4
# DATA YIqHIIoA+qWcWR+ol+pAQvFgJCje8DitlAjh5CeERGDiMtVRHI70j/6Yk869fWTo8SB7ZX/Mpv2B+TVNTaynzfFi4kizkzGQiqWl
# DATA XXAxjHSaP9ATE9wbzla8tL21tas19QQWaso1EDnOwHEkS4/WP1x79ni3s/XJ5vp2h7+Ml0fjqf0oXnq2ueHVmCNR6vG/ZQ00NfJT
# DATA svRwa3N3e+tx5+n2FoDnubXNDk+XZYa3Zs+vEZZoMoIe72zsrl+1lpwE9idrn3bg884Hn+2u74A3o41wMS/huZJ9ceyd3fVPcWLi
# DATA eO/ZsD/dX3okxDCrrcc9y2ooXIylNbhLtofZ9HQ0eQGMvcmuPD2Asp/oCVr6AD2q2idKCOmj5ZnLLe1xYrz9JWB2bXXTg5xuS+uv
# DATA su4O+Au2zWHigxRVrfgy9koRXQ2BukS+kNhNYDFtJaws7W0QgOv+0icpMKkPzgIdU3Oh12L9w41PYXb27ExswkxgkOL+c8iyOoCs
# DATA EvqR4oIHsBTPh1KaJWyDHk2iKQFbP2/Hwhh2A0QMN1ESRl85aJrkROAmcqLvkEdzqBaceq6im47B17NDsik9rMiTSa3jf2WeJi3N
# DATA 84I7USDGJdPQkmZ/3HFKYiqofncq7TM29AJuoP1XgwwRXVYihNbGF/28g+vTTfOp+3iGuSbxpuHfaiSW3VrExbocGrvxFOpR8zfM
# DATA ptIlJ3bMlJT6HdpKTHI5taRg9FOVqMHkxwjyomb9YNLvqQtjPcJYUXzaXjGh6AQTqacCf7NsDF+jRQkvkeDJYCpNoh9H5zdvXjim
# DATA XX7zILp7W9sM4cpQGyda+d2n9JlGNB7Df+7euXPrjr2zUi1VM6Z1zsCOsLRrYebhQkdWb35L96Ta56vZAq+v+uodcPo6oNS8B9Ab
# DATA Xdki/XmEZIU/0Z6Z6Ul/gJ7J/fFdDKqMWzF5IVjszP44du2ch/E5fXgR5bBfo3MsfgFu5BDqymI8uZa3o1rc7x+iAuActQFwvSJd
# DATA gowUFaMSS6oHSFmoItMEyuT8UucHN35OsKp2M4WWFwMzbBGzzovMI9Ep4TrABAknZtodRz2s8txWb3qN+AG2VdlvPjeHinaSD0Yf
# DATA ztc58vOL6Px8CXx1VD0nBN2qnuA4sViHWcW96HCQqjsfE5170cXFUoRpwfn6AdXQZ0paAE3m8Wikrybq1jGagJtdY3VFXVXB0H/G
# DATA /b6nvtJLeH0wus6P1dPu1OBJ0+T0JqOxen5OewV002JGzqNzu/Yn6RiuWHU+UcmF6q2t2H71b+2YzdtznvIL2YUMnVf6+XHWq+t0
# DATA vl1tzKfwChAHTSUn2TSNBrfRG1QR3pd3G/3uiTrj6j8v79IsqR4Pe41h1j86PhhNGjlMCniky4dpD2ya+GyiJj3TT2A46lCpKR6T
# DATA e8jNO3cu27ijdxlOslQtJuYZHKeQ7aYxHY0aB/0jYjMN7X+CuaTVWkFfVAPqgxNnbmmN7N44pMD8kt2h387ZHwvshCuv1DnTkgvZ
# DATA efV/IGcYaMcu6F2NmoyZAzCBJfbe1qGbBYiSWFHqjhJCN9cf7m5sbVIMH/vnOqTbVoIOTLcJgsY8BD9exVl7/SP4UKgToDPoNQVq
# DATA Bbd8CFsK6CAiC4MjnhJOYpTjchDkFIejlJy70MNpT2046iiUDyeodngKnqjnvfdiTHQcTJzpdBYK6ZnYM70tILGWZ510PAbZ1qHJ
# DATA to31Qs8MHCrJvpRrFFk+Bh0ymj9tSwxPnPTVareZl8HLH3oTYleuL11rpZ1MghOXts0puQGqQVWk2/AmjrKC5Wxjo021xVmdZOiG
# DATA 9XPDGdCaff7cwNw3+QbA3WhS8SZ7+3kZnLz/6WGsILMhk98m2vRQ18YzxqznYILYh1Rqoxfv77VWb+pV1pIcMWOi0kZaM0Id5b1G
# DATA lqVmcWBkEeGUgZM7PJxS/ChBeOAHNL8ZPEA+pyV3V8TVNTWpQxg8j4lcyqrNY7ci8aHP37cJLEnbttIhyQm45JGqm6rTZzQd5qmm
# DATA IbXDuJehN2GRXT8nmPpQx1E8Z74PIg1OmdGQ6uE0uvjfQ/xvzJcY0X5S/KKiLGf0AzZ62h/2Rqc1gJHgv43H/RoykZ4ZteolRfR0
# DATA ByMIgkOPezWqh4q3HYxQkgJdDGCyRHzio+4kVUQ9b5rbydVWPrhgVdUttOJXW3VxEtQkbY6i0Sl4upP2qQ+OXHgfBhuoujGSp5a+
# DATA UueK3/UBHhQwKCsnJcep8KYkNpJPvNj8oLeQXdpQRIAIE302PpqkeJYiSuHEY0IHAnAU0wBIdMjRSWia046NdNq4pgRvLtuNNReF
# DATA ErLJRORoLkTcS4u2zwXKC9Wr1gIEL+ihWzdJuBUypawrKZ4uOukY6U6HYs5ixSjnfgvBBy7iMFkLLpRsVM3S1VrkOYI/V++cUB80
# DATA FZDQ2qxXYE9bgBc1fsQYrVTlOiwvRtvZ4YywUyIur2+XvTqqJkeTFB2EtZqyefICVINjsPy2sSlyBUbIhcP+q3bcxL3YCEGMe8in
# DATA hz2LeAp1e4in0BqNmfQt5q3x6TUdpJlwShiUClvGwosjZtrgzDmBo5wCvTiZp/nOlxdynbDXltBJaQERl7Nb2qsiAu+hMegKSk27
# DATA rF/3zVj1EDQ0qMlunh73lQwaq2cuQoZ6UJpzmwZd8PfWz2nbFF5zYKBXBF3CA18DHauBYNeZqTFcw+uBksQy9WtOeYzI/6NoZbRy
# DATA 82bV/DwbQihQ9OzDTyKxXrpeGXpIDelUsMIMqq6LDMSlC1E3fPIPT5s7nY2d7fWPavor3VccjXxYMmD/u+IY32KcdMS/ap0wStkU
# DATA imynDD1VQLFLiXf96SaPR2d6YQaMVXz1ppebt6yOmg6Cdv2v3LuY+ibvpqB/xAlBYTDeW2l8GzR9dy6WFbd6Dq4EVFdSSYFhxrkn
# DATA mL9jNjzh2SFHpTxESB1dlAeLQFyCatRUmZ1AJfl4L4q5n4mf66umjjWh9wMDmo11trrQmpd/DUlYFvgKfcTspIeB7Gy1Iu285eyL
# DATA tsWh+rjqTMQXyU/hdLDYucrT/xWMoHQUYa84b0PwnnxHay5zdLAxz+R3JmsBWwquxAONeRB8ik5GLzMHyemqHIqRwluWGFzOVMFK
# DATA z4I3jjBUqF83vxZDBVJQnibfYvH/Pw5sBupwJcMrzHqqO1FHr2kVxf+XxqT9d8i+HgD3ugT7Dk/SPKYqvLYUi0OwN0f7+Nzn+A+p
# DATA mecu0+fGXXb/FJeCTVA14JNp43Ct8WGztbz/XqIZf80y0Np3WnX7K/lO4nNUf1Wwl3PnqDg5lRzX30maOmBjoFF1cfSAPpEIYT+6
# DATA 1mbaAnduoiBgO0FPR6rm5r5Gk6iD1yx+4Z3+xUdzkA1GEK41HamOjKbHGO6FOg4ZYqZoLohw4fWMLaSuuoqbwLMA+XUYx43aXoCx
# DATA 7YuZQfFrDzLEWmYH7jWxRZWJpyPkhcOz2LAi9d9EoPyid4M8uHOZLw6DeRGPwk2pPYe7e5yW4QB0sOtXxnjNuJ1xmJ0VlglpfAXp
# DATA ZJ50Vay+ZKrmSh8udgh6osgbtjkX6OpVOCWtpUv3yJvjw3jvXM3cxWWJEhvBzR0ELd0lxs6g5LzgQtrNuFBeNL3dPXErMMssgQ2y
# DATA dDgbd8aYnJkQjLWDvnN24Z32snJSz1HQPimQ0oN8NJip6SUgnGaTvQtI5zPNK5j2oWZI3CP8qgXTPD2+EMhSXbURMBk2QkndmEDs
# DATA TZ5ROjyWGMBwAT/3KwJWEbu0bWtrDjzmzfMMKW83R9MPwcMwEEJUgIliADzk9483v1uDdgyvn0OgC1PAQpaaBdPPCwkHhTKWCci3
# DATA M4OnA/RmE7uYsoemVyxsrISsTE7XjbihY2NrxdYwmk52icLrnErM3Hxv99MkCTfrV+HIUI82tt05DVdCuB9eRbWCNObUBNOlHyCV
# DATA gpGtyqcsXLleg0ly6XVFzisXJ7TCfFxhar2zimDedFYJVsXrkHNgCwc8wAfCWaywAc5RtbX5+DM/S5X9vfkB5JRy6FPFufGBtKuS
# DATA W00OQrpePrzwDZ5a5Czwn+GollTL36UrLo5CFNz5i+6OAFbmYjvCI3YCjd9I3jXyLXFw29lbAYomCzf/UO5EA8fu9YAXCq8WPYyh
# DATA ULfl6WHjWxZgmTdX97g/6E140/D+q+QsliVLDlIUx7gL7Dmgm7G+BHrv5Hh8JtQ+xngo/u0gxQHvgIcItFV4K90+uJEEgE+ND3BZ
# DATA 2KAzq7tqItXF4MxZ1jywrmYwmqNiz5puMtPCJOIXchbpK75qH45ARtYX85yZd6DNSWZgBPC3s9i6hC8eKEHGRzJHLQWDBpZYFgjb
# DATA 6jJGBcP9rVnByRvkdguNkrXQhgMH9vCG4zPlEFN0d18mfLdMh0uu3r31rdsWjgY+K4j7Pi2Dzo3T/iTHdPF5CM5dOIcwKFxdY4AN
# DATA 0TejuC0ZHo6qWGAnCswnsvKSIxbiIfjaVwL1A0g5B3CxAOlnMJQzN9E3+U+PDiDHUAeH3gFHsjb+6RxxCQ83xSy6CBG3yK4Qo/Ad
# DATA j9Uj3hRoqifRvwZ/TzqQkdDuV7SXm+dVzZKgP1DDUDuRPZ7zqNHArymhLEMFnVL6GdCUO9sPD7XoRNNKxoVdaXGTEmeSvU2+JMRL
# DATA x9hAmxa9ibDFbewfKpHgZ2Gzui6oWkWBtejctvuJQdGbpt3jDuMeixGhehbW/Crzu03Vce2VM1zcO9wuesgnYWNLvEee1Pt7FkVz
# DATA pX735kXsd7t62/Gw9Tfeor+DBSflShdxGajaZTL0x+oPbpX2BIpEEA0MhTGyW3WtmR/HRWnO6OwcEkc1OFSNRbVnw76JjyyAWuil
# DATA 4g7ogNReS+rAKDlLKeZGma5ElEKHRtVlKiqdHCHWS7GqXEYG606QTmrxDuoO1YDPY/V4TG5F7IKZ77VuIn7gXuzFph2k+fHzIfvu
# DATA RI1s9nyI6HQOLYWNSNWAig4xvEE+AYjsrBvFZrOaMjAuKgGagSSQkpfGEpxYAKWAW03b1Ld3p6WxZZ0NgchYaJGAiDNWHvLntmr1
# DATA imgZFYL/6kKgyMj7rzhAZjwbdqczgqnoHqeTvB3f+6Mf339QS2KvNjCxTLN8DD6D2KqqHurwSkErGSY7wMgq56YKLlM1LMYwfTgU
# DATA tpP4p567sQ8Or1hynvukizKpPnCW7ZuM5/tvUItBmGbw+987vxetHzo8moDMlUJeQhjQfUirhEoN/cxUTPERDN7Lz3L/plm6Tbyt
# DATA wgfdkrhL7jT2ASQ+Z+iUujYM8mV+iSeF/7akm7qNp6qtThW/rzP5cgAWbHPGZWAv9kPa0M9sI0baX9OkcHZ42tHRbIgiZXK+m+7S
# DATA U3DN8nvg9xQtcmSiR0pAf19uvkD+oWRwGMHfgN8M2qH7DP824LoLJJx6p47YtLQoemViWQ2OqxMXhKaVBjXsZTCLYkR0ZTruo8Mc
# DATA vL2Pb3lztVw4VpwPLLYPO5AGRSod+PQ9sEXKz/Gd/AyK4Lrjp3tOjT7UKZVvRzcrlONmzPr24tSYhCtc1QtcwQxhnYnxVDsMe6zG
# DATA w4AlYcZBA9XNhLmJ4STEHsDhAkkvqpDNYBPGUXEwKJk5b6Fz6sTtFvVDPcdIZJNR/nQCszbBVdJ8ERemcJnHE6NFdCnxpeM+eYK0
# DATA vjrhdzqBWJdex1YeEm7NqXVKB60VhVJFudhHuVYL9tGMgmCMMGEaB3RnZDgiqYepuBhEHcbRhoQoBLx+FGwIAMpZ0DfCsR+KrZHS
# DATA eFHMjQCPoT8vwVvrlbuSDgE1DqOjEN8CL+u6QzHbTp6ia4FO8ZR5ATJ6affc4gVkfCn4k1sIAjZrYGAT5Wl8JxyNxTghF3zPTUJ/
# DATA LVwzYPVshfMsqSJZE8xz5IzBUc3J5XEAJmvUFKW604V0RgrTS1RZBwqCprKgd56zhfVKWVBRMtwHB1E2hlCuN2yWZEMmSbSVeCkA
# DATA dlIJN/IIQbv3bIdGhK4WLwXrrIUqjSuPP3KPEsHM3e6mjwz8w2dZHCLsJp34S9Kd39u8lW4BucQmBybyCbp4510lk2hFy1Kxl+Gp
# DATA cykTAnfcA1stkw1wmBiOvO3lqRfJGptrriO8DnXI/MnoJcDmGM0vYXWJBxyU6/B5CRFRB6cYffEdE/Zl21VwCmaDPYC+AuNNEkfx
# DATA 4gL1274aDU1/mpVuCtM2bDHqczuS8AmcdZOLSdtxQRzCKdHSkDfY2jwHwSSplLU4MpDzUrGvNzuNiB1lhqNlCvhuWWeg7fUFkm5c
# DATA VGEVZ0j7p3gL6YGGiLXU4h1/V+qx4HAdHXsndiRmnvAwjV0nHl9D5qJN0jR0bP9rcYn/U4mnQTz3InkYX8IbYW5tRW8FJ/YvKff3
# DATA BQcaw5LMgNuFSQihNXp7trCutYKrD/tyhDx9yhySkmQh3Edvjz/0XKPELtesgGZ7Gb+r3ORGdU7j1diLuU/3BumwlOZpolgXtG4B
# DATA grmkI2H89IpCbVwQBbmhQpOOYcVY+UCwZWPKZDTuo24J0HGaoDdBrLca/tQwkM2eTA0Gdmkl5BRq5bqki2XYsRCCyM8ajldgA7wC
# DATA mwB9HJPvR9NF/5ROfxF3wvioznPpAN837cFX7lHCUC4+rAv/WeuPba7aBuIiEKqF+oGGnzFxk/644IISUtuU+Z7Y2lDG1P0AHxmI
# DATA zbgGYexgsh7Dn6hloBIikW6TgvmSedOCq6BGy7azQ16W8/74ogkxbUvFdOQOScfi9ej2yrfvyiEbznwYG8Sj50ODcvR0lDPSEUbI
# DATA q4aixmE10pHbL0loi3go/oQpqnbXw0XRTllA4icVUYi177QwEPHHDKmQRD6Mig0KUat+ERUZwEQijNy+fYvDFyNWmEbXJ91GN1VV
# DATA qOF6tTVU8esO5QaDnKLNL9NJP8XVqM0NoVTbhLvK83IRuf2p4lmHsUGAwORVbN+ltLaVI1ErVew+5v7t2L0Ep0jfl3i765f+Vcsh
# DATA H7Fal5hDsYE2JeerdTQM6RTzfpN2wgKbg0AhgELMO05OD9ttbzmcZGCyWfcQ+pPgKNP7QQ8hPF+SO2NHnIqKQZR5E6KbFVPco0rw
# DATA CBWzJ1T0NMBgwenlJJ0AHwVPZKIfyO2RL5g91oKd5ash8mM1yV2K3T7IDBR1fAkh9lCJC9Ak8cYqQxH1R21DHdg47BfIFzA430eA
# DATA yhEvRKQ44X6Cs8o9gfeJyAkLnwUFV19EAci5yBdOygxxx9lg7BgqHVcHqzHXvefyZReXGr13LSRBBMfnw68AwhGIARQu7LLr1SCI
# DATA qjOovqbBBSu4BEyiU1sSOji8VCXTvOBtizq7wBoH2xReLI40WirkLS39Ww/5Ugqpg1HXhIQzAuVhdzgdkOFWveywq6FuH57FRZcc
# DATA U9RkSSo6HZoy7Hn4cHt9bVc7Gm4/+mR7nhMiqMnvajW56+zuOQ3a9n/fHoOu++ZlXQdhygDbXM+c9DPDdWoe4gpKv0p6DvPVWf/U
# DATA Fj8DB6FwtDsE0IMNypm2sBKnQ2732sU+dz1E9NOg6e8K8XnlEB8cRaIPjoiazVvYUh8CeQyR8a4odS0VhXpcGZl5Az6Ucpe6apiw
# DATA B5oyRfEpyKYWsq+0KVtjACDxUl422sezyr3mynabpQr9ttDmSO2aMR8tFV7519fLuEBdQuXKZrPNkXQoK6pZi2LGPeuS/6KviG3R
# DATA i85BW+nUqy/vcOv31zgpTlrZefJ9dO5pkL29wtBGRbWyGQLsVOrbfhK0Y+PHdZuoZnEDob9Ze74BXaai8L0NqnUj1u03xJ/mbZ7q
# DATA DVSxR6omsnIvvOUklk9k+WQGelHG+v1dWTLfbthcbsMyipR6YQSmq5Fn7gmql8qi94a1mNCou9MBUuZ+rlGoGkqgQ+XifJxqIZwJ
# DATA 0LM4vspBlXovcHptgm7zRXaW1ySHDHGM0uDBwDBT1fywoe5VkPDJbdwGwqge1Obp6upeh4J5mmwel8kJqtGWAumXGDOwJPeNzCrW
# DATA RJR1faOv4a/m+ubW+uZuPTK/dtefPN39zDxY/3RjZ7cqoVE5qaQD4FneaAEVuadIWOM8QShYJmWDTujlUlAGXgP0Lx09Kll43aAd
# DATA kI6eGIA9+RK2ugJdQM0XyNmFGHyU/h1gkkoLABUvhOKjMOu9kjLtHGASkkxpLv20qlgrpYK12V69RLDGv/NlfzTLOwF38+AlR0al
# DATA o1I1XMpMDir0zg1UqF0UDHSXjZcZioTJib/U7hdYt/PKOsvgOpe0Yb1bEJA00m4l9I1TOyiaCrKa50fjom1DcjGDmbqkNZgIw+ng
# DATA dJdjdLsr85Ywj0Dg0DpRuCXXo2AoBlCo/YIFAatx47rLgcwW2LEC+2CEoTnnFIOKtfpoQjJeyQIFFfun/fUoX481DxYQRfzIbGcP
# DATA +foCv7YwkIpThR8BHZh73FSdDsxDp+OeqpKPnVUS+N7nbCZtGfNdnh/T+WnpXSZs7K1Igp+5563lDkO9tkelJc7IRaGTpKIzyrir
# DATA 8M5iyWyoN/lVRQjCTZWOuYFA7gLL9dZcsNvCXd29xhqtOAI/NjHCKAQ3xFuuMmHjwtJJteVVhOHLLvoSrJw0TXkYkZekUX5UBrjq
# DATA q6vV8PeQkpQPsFJ4nLfgAUq36I4r+VRiJTl54TAF3JWSw+F7L9EYQcc62dFQjKFB477j8SsOglAFWn8R83HsNei8ox4E/E8b7JVK
# DATA 3wGPievC7dn8QKUSxlX0p6IRg+O0X9HtBjdaWQQJS2NMnjzFpHErlR+ru5j/KSR2CxfuD1GJXfigqoGCQqZsoE4Ekk71RmVD+d4w
# DATA M5tGL26bJShew5H7U9ZtItR7N29iCnDOxS0kgLLwHgeqCGTIVnnesnibpRkvj0igy3JbSVhxkoxlsB9+KWQhVyIooISwC78VqYtD
# DATA 8vvi7WkZOe/Ex3k9MfnMKeRsgcbg6uOeLj50rnd+cXmxEPmIun1w/ILpu0od2TztyXwNyjvRogR0GHrnNx1ZukSELnpiJ2/pDubO
# DATA HWMu7a3se+kCHS9lhJjElpAnrZgKrQI4vGV0O8VTuOCO9cioxe2ovBmFkVl9mw+ghx/2X0HogepxgxZVQG28HAHEP6jlltFWOVFs
# DATA PI/S7mSUWwTticUNL9xnv4Y7pm720jfgK/cN5kNYuhxj2aLWLse65eFmQEVl4MjSDsSwR2ELUGAnkSQQdqbco8B1EDZNCHsttIGZ
# DATA N2oc4kNd3BoNIJrSXobMoUNtiuRP3nkwd9ZSJoAm9jnHI0wCL6V28AmkSTQvqFVlsLa51fsjEVd7DHJw6BDryyrJWGsRyqq9Hq+c
# DATA jk9WVm3HE7MEBSUObzkaqnfDdZ1x6+FgkgpMsmB56zB5udsuPk/mbDkUcL2NJtC/S+m8dr9YkHC/u01cqvm1B9NfhcpBzEcvK5ub
# DATA cr/8BTS/JeefbjXv+uDPU7uVaARIDC/saQ9AFkMDsIhRpuwniVDXlc9Txd5EkbPsYuZtLJlVpMAnTBULZH3mRM/f+MP//hX/D720
# DATA 4Jx/Rbmf5+Z/Xl1ZfX/1jpf/eeXm+3f+kP/56/ifn5RZ/86nl8vP3AVVSx7M1nyc5pCI2fycngwumbe5Hj2dTbKngH9RksY56ypx
# DATA Kg+mbj4zj2fqeqHI4sO13bXHWx91nq7tfqxFLatwtybZ2JyNjhK90sHoiHwIwVVM16FzFt/khMUyb/GTtc2ND9d3dm1iY3BUxVdg
# DATA Qn28Rk/v0iOMHNOpju/eLqZFhmQIonY0u25sfmS+Ue/dF/rDu7cDnTOlHq0/xWn41tLOrupRZ3PtCTpyNk06E2K4S3+89Wx7c+1x
# DATA oEBD5L7iwnipCVRFbonb6w/XN57umgK2poO0+2I25kq2Hj/q7Ow++wAwaeL713oj3GS4gR7ch/9Gg3R41L6eDa8/uI/pHREKJZu2
# DATA ryNEnnqKQV4POIbh/jL9vD/WT+DyYz1c7y+PH9xfxuohQmHj0frm7saHG+vbFP7SHZ2M+yApILSRxjVCWKPb7188/77aGh+vfxoo
# DATA e4iY2HdvU5ndre+ub5aWunWTSq1/uru+ubOxtbmDIBZN6BVGrHTznDJ60j/5yyP8d/pqyo9RMI6br7j8aXagjmr/UAlb8YXa/d1B
# DATA mufRjppsujDbu7PRa+c6RKpThFHzIdTmwqdVQ6exctL0Jn707OnjjYewEf94Z2uz8931zxwbThgozQVJ477DTBAiYyto2xP6IsJP
# DATA OzibFtxAGKguCL/ohW8tgMfWEYBsOqOjRH7iCw2M/FEmnm5n3RmGO9A6BTw5CvO4sfm9tccbj3AW1d0WKSt+o6cHSZyHJugF+9ss
# DATA 2ImT+wBi9BlzUP1a/Raqa+LnzzHsCV9UdOzZ5s7ah+udtZ2d9V0kwXHiYBtLQi8zSMH1KwxxDJd2wpy8ptEONTKBAT0GeII7PlDQ
# DATA 3CzQ+zIhNB70b2M+aKgyCGsEL2ASzinkpNmMLyjSbTIVQFPNcEpJrxu177QUq/3xeDL8cTp79ePhbPBjRS/2VlW3fjwYT/GPRBV6
# DATA 3mzeSL7DvYLbdnOjeCU75F64UNCJCcPLZ4eH/Vdq+57CNUlrNCwRSq6wogHMyE5vhLeOS+87Z1l57z2Ibt65tcAReLT1ZG1jM5SP
# DATA xxAzrLE5gXzvY1wftVp02Pu9Yap+6rOf5t1+X/3miSqDcLvMCdXdk2dUYqRxTncablXyct6zaktI1nR39UK/wV2iWJ20uZSHjsFk
# DATA Q1lLunXKg2acJMllJz5Io0FVW8CldXyw3gHgud7kcAc2NTXVTjt2kuWW7WsK6bfb+n90AHSYjiMlLE0V2YQXYPedkvgLz/oHaipz
# DATA 1FiAuv3V7ZWVOSwbJ2jnsyePNza/63qIhvHJq7HE5zQmF2Vt86ESr7e23UZro5wcKUHlgZh5ZHkpbzLoqFeJvF6FqL7IbH2yvYF+
# DATA WSVDsPPWFvMm/EdzjDp8+9nEzmxu7XbUh+sPVT8+u3RH0Fvi6tDuC/dQ1ffs8do2XndK0dk7ZHcSCNhMQSSlsYrowlE2B5ljLm/I
# DATA A72fFFK/2pMbVgJ3TtIXmUXAt4D9iCR25075aUFCZasvUCusHQcl6rQjC02N2xUaoNgkaMrq0Fgthjf99hz8JqUOSjhfwvjn5vcs
# DATA eiKps2qXDI8tZ0eF/yBT6Bz22tQi1VNcSR6fj8hfvgGEgw+luG17EPuaPI7A081a/ogoFl5/sLG5pg4OvAzZBDsCyR+bSwSmvpI4
# DATA svQkgBtrQuSoxILI+hq6VRw5+8iNf7PP52Hm+6cRtRKPN55s7BZR8rm3ZTj56eE0m8wdXQhNH92rbZ/7w1HdG4L8fQKhDp0hQcvW
# DATA sFXzlflFH5mf5psKkQDH//Djtc2P1h8VAfpLYjidM9XyNrHJw+uYxTULu2ZYWMsNEHSttMKUGN7Q+MvQeN+ivVSZf4Jpj968RSk6
# DATA dLeAnHEofO2ttjycSY25b9uAawtWbg58KC60NALSua/LUWBLIYGrMv5UqweuyP/LoOEvIwLQEtvOXToctEBzAjmn3wm9r8haItpN
# DATA 5keylNDny9ks526PomVSHmF3vsUb5zgQk6JzVnANCbItXhPQDWlNci2klBqnZ1AGuBUBbglFtRMHWtBAV6d9WeQ2SpSN63yysbOz
# DATA sflR8U7qdJdhr9q6376CzOJvPJ8QbreLhWKyEutmQVcFvwssDhuSoAc6gS9rB7iAC+VNyfvwBQKe8FPgf3O4nL6/OnPySP0rsbVV
# DATA 8Uk6wBSj0MaegPg1COCMpgOIGmihBbMKuYrW+Hs+l3H2Mh3ESQXwpq2meTDqndWxqocjfE1QnJgKxCvWdFODKG77DoYO/I3HwqPo
# DATA QPf9tr08i+NJDT4kkE/67B30ZZKeYpb7V1OjsZHq2bCSdedsOE1fBXWrig+raby8mjXQx4A+B9U56WnCeAPOEV70bErBi4UuUnVD
# DATA xSUKNdJHY6YPPBXZlIWra2BbyLvH2Umq/b9zUlniboJCe/r9vp9hxn3rHayFZkqLUKPTnJXse9yH/ZKRQFEBP+uopOEdaqQdC9sV
# DATA uxQwc6j68Y6omnFBWYp99CZbPeG57vcwRgvMUOSnb0IEEG0PAlFx/gtcq9jGHlS276pJrclKqgZ1WSxmflm9Xqg9rWT02gTTi5f1
# DATA g582SXlqcH31c9jsJ+mr/snspAyoX6Lye4D8POFckzE26QpB+1Yz07mqZBtAL3Rn9dbdlWQ/Sa5AbGT8LmP54ezRMlXBJHOAt9kE
# DATA 8PqW3qcUbqw3qrX7XqaH+IETXzzoIWIbbDc37JjkFRGBRHg1wRgksgq5sH16hOphs6vkL2gK4u+GulEenxg+N2Y3Svz81coKqmV1
# DATA P3iX8E+feCdzEFkuP0Eam+/8nLTSFxdOd7Rgj6MUlho0uyaLyvRUdUcRnofrH289frS+3QFwzfVPd72e0MxBhEnNm1dXlRkjhj71
# DATA QhtlaCvCpN5euR1+FaQe53F6MJpNjSUZfy2LBi6afUwAkqEhn7fpQvq57fV/90xdLh8pSfWj9R0rPjr4KznvTi8sHzzhhuDFCDog
# DATA lJdN2KbZvu4TfR8ZesZC3LZaWUc6cFsn3KSb8UKjAXFbrdvjxxtg+iqanw0F3SeCUGre8GR9nUfvXJGwlqFqmqiRD2AFf0guJBfy
# DATA bhMk6KnzvG/VYejPSMwIrW4FCz5MWEsfASutiyNSR2cLjWlI1dSjH85GU/bnTQxpKBwaG4WdCWy9CrrErpaSxGoqxRk3eK8YG+B8
# DATA suG6xbMZS88V8efZSVWF1d9fQY7bXt8EuiDFuNDeoeVD7yMz72ou1BJNtcKWHoP8x1ZVXmYpU3nbxGCnc02acLgyTcDo8t3NrU82
# DATA ibJqycrtvNhv+Z6uft9sPWPwOxt2pSJM6LraAV3XYjqKavUV7bPL6MOCeueg5gIVSTCkkMIhGBNcpbSR4bgksheUNpfQZn+yLQfr
# DATA hLWsf/rw8Veu5mbVD4TDlCi7WflLw8YLif/qcDDLj4U8Y+a7oDfmKaTz23McDHiH1kSwAHsYZMNccZAOGvXbDNgPVKgDsDCcaSvP
# DATA 1C5I1TLl7VpcB6LcihOdECYp3Dq5H+qDk36Xp0N2pmTl4MSMJinmkMZdK9wQhaMdTlUDoFPBl7EJ/7mtiP9xxnmFeAuZ2ur+jATU
# DATA txWat8WP3xw1Ia+dZjGif8V0q+Fw9dDXfLTFKc8n3Y5zdtVByqedkuNsqVFTviqcWyaY1GaJoY+D8U05sxP4RVD570z4u7O/GaC7
# DATA Srub6BjPXlhtqU4a3P1MFk+O+aRRULhkIZMwPC7PJGxsF5Osq+59AiN9OpqiTo2CNAFQk9NrcUPqJifyZ/H7lnsLmkBg+RjJJBdo
# DATA jkfjWuJteF3WDUty2IhjY5nDqQorSPWXHphSnkXffaVcizMvU6M6a7PoDGTaFb/8ZBs8suLQgxmdF8v77OV/5o1h0j97zs6gfMIl
# DATA fhAVfZlbpb5NYYFsd3u9aM70zxRgoeOwo2UaCS5QeAhkY6JSlBo9mBU6HDaVKbmp/zLTbED/7kxHNcaDhLAutfdqSdkEVju64GK+
# DATA jf9PmdUmDD5iB4YrapJOxDY0t25GnZR/r4+y/p6lJNwFYGIOf1kOfbKAzanEICgAYz1X+wbRr1alc90VN6Glju+1na6Ulu71j7Ic
# DATA KDXHXzTz4/Tmnbu18vq/CmeIIOzMWzhIhP53CaeJkrV9h44U19zlQb8F/aA/HOERdPwY5BfqZ9Ka65u5iFtC+Tm0SSvdnld+RgzX
# DATA fDy/jwccai8dQk7UHRWS0N+t25qS+a6ovD5YY2uhTK9vM0H26DRnY3CrqmHD8z+yM9sgPe8C35GSykzQ6le8+Iu535R09Gv3vnmX
# DATA oy+wH8SZs5ynOBzeA+pqRX/VZABv8GpfKjZdwlGBJWSPZJtLnFaRsXiUJLJ/RseCaDGuksX4S0twSseLOgT84YnrjrlR+tsVo90S
# DATA VzmEeUdUr7hvdNfn7obemX7XrmjJfNEfkiaVNVGoTEVVlLWzwWt1tyna265m+7SPsXF86MOVIf5AKGW5N8Q92/FFLHz+J4XwEqMh
# DATA xII8Efs4a+6jgDGHCrBC1s59YQjGvuV8ELBzlbaBq+GN9+P1T4sDxXILhSCQb/quVVdazTPLR/1h5HS4aBgLGcUCNnasrrLzWOJS
# DATA hkjZ8wUcDYHhKPKgpOLB6Axgy0JaQ/tW3WVMnKYjAWOGmAmGXQY2cOPlqk7g5CqSpP6Sqij4Ja0j+fFiGIpxEZ47bwYJ8rA+3LL0
# DATA 92UtgjDUuBBa8TSbIIAi+3+UgCSH2c4Hz3Y+K/p5OLd6KdtKRKEqoTqgowvNkNRGDKdxAEySop5P8pfdybTwlh5jQK6SWZzMFPzq
# DATA sdoZHzyGdB6ri2joChBVztVikSQYal7E780PCotVjWR9mUW6eqaNjuoLQk/XBtkhxNv1j46nLqPNz/ImUGJFa06cVD2Kwc5exUk4
# DATA CTQBVPUPWAtMAfXNh48eP+Y8BbM862BgvYDSOZwNGf3DbCmugjAf1QZJpzfVtsKgKt1J81VlVmqngWY6OcIeYbJ76lu3gzCO5hc4
# DATA bHTG4sGc1zP1ft9tBTBhIMa77VRS1I/C3OP9EP7oaF2vfktrAq/xr05AiapbrDkVoGDMKn14QRkM6041bil8o4vdpFTXpTmGGey6
# DATA J8anVo0W1RrnsAAEkRrE9Z3PdgzcOtI082vr6ebW7s6zp08vKtaQDgYfnloXXVRB86f4qHliTSgIn09OjaBgyafqcMBMOdpr/d7u
# DATA RM1cTHlPLSzehDTDYX+KdVCvrO1ubG2SrmVH5K9d+JAFzsjcw1V6euaeoOBo1na3nmw87GgDsOK3nWeba99b23gMLuDSj+drOW6L
# DATA HrnCsaNlJ8UM/lk4enLDQDHxu1NiODJH0atSHjN25OVzVqzULS33Gn+y6sOi2uDJquNYXNW5x8gAPJUyaLRloVAZOmZLRRZ7tf1E
# DATA 5i2eOWkU8E4j25OuaVfmpr9OHW3i9j4xJINQOxApT4iXruHTuJ0QoRDh/UEoQjI12Mp0L5ejmFrLY/jbCKVwnXPojW6vLSpB/0d6
# DATA DmK/X3nOhgVd2np88PsFg4U/WHv43WdPEfC0KviZss8UhPWwCmAE4ItgqVPkDrzF0GFKfFuwRAdVA5P0VF+zS+4Izu3AIsJ4rh5V
# DATA N/8iMr/I9WvTZRi4fuuw1M2UpOVsoHTSPQa7QKtM/8AFVF8lpkyFRuId6BRsB40Koc7YdF+3LoHxcgoqBb7U245iDcUdV4aIUQ3G
# DATA 4F5r+RA7jlJ78qJeVEfoCcEp2y/kiq0FtQNcer56gAsmyeIaAjqxsZRk7M6yp8C5JFPogb8NZeGSwxEsnQQSWZgN69EC8PSXpxvJ
# DATA XXpaJJ8otlglD0/MPKmLyZerVC02IfiDp8Kz8QghzQWFRE7ArSZzDrvgIvVoOnqRKRFyNOjVo2F2yriKdWZREiNCr0OItC3ZrAMl
# DATA XafoY9G0I+YJFmGRiHvZS5hT8Y37cqFbKc0x6sM+29ldfyJkQL09nCbUZqkJnCxwAcIpEm4NXoA3V4OR5isrbjRO2UoKNU54S5sg
# DATA k2BJlwYbrbUhoq1oVdPRViU9qxeEL0nMWgFKpilxC7dM8XPa+63obY6SzG5CMpHmT3qfkbOMw0Pj09NTCjuDTajIVninQgH14nKx
# DATA x8wQvfnFfaH+5iPE8hLnagGxQe52yB0x6PG0KXkqO1V/w4FzphDK7LyDGfRq1YvCZzumww0P8I8LGTdldhPyZu1662Hs3YhuzptB
# DATA 84W0tmt/PWflJOAdOWQGIYRIJjrsD/v5cRk9c/SgfIMQXq7ZAWx+X/rCnSMzKh4VijjOgVgiRBlExqhFKEqh6aD20aWoyLdp9/No
# DATA EifpAb3SHUE1iaohEAbMyfuoXF1Pja9/XKwDbUjedire4AxVNG5Ue1xFnWY9CUQr043IZTQy4pAXuW73XyHBYJ4Hc8zM20pUzQ/U
# DATA CRmir1zpnpUqSS5eNP/pF1e2AHIF9ZLj+PZiN5Ezl44x1WKCVRf0yUjilpy8O5l8AbMddtYTUhHxsWjFoqJJWHYXg93XyPRyF4Qk
# DATA 9+IlOiRNLyjQhzHkfAkfVmG/HpkftAgBkT84W7B4Cwj0WKz0EkGLvPAtgoubVoOxUh60mqWSEqcz1uPWdV7mxrG7vba5s/Zw10YY
# DATA aeDzkEHcXmpQKi29PblXB66IVJ+L8A13Yy5dRhgNfCrYjhURLWeZy/WyV2MlymJUo9gHhfzTzqIzNjtdPOHc6Erecl06i6hH5l1E
# DATA urMJ6rDabyVDsZ3opeZO0KbD9+r82y5/og2TkO0Jyht/EkyaEJ7OwjVUd9/cJ+15t6ltBrhZ7LzjG5yZtu7AXLU/zasr6lIySEF0
# DATA lqoEkSpdktwdjhhwCRUB19Uzc28kG6NgLSVOQg886R9hAJd7tNxPl1yjeHFcVEtSvekvedu3Z+woc+Q4vbww65TMiiciaAcxNyIe
# DATA qbwNhft4hX5asdFtpR75B8AXpcPHBO4b3ij5A29Xl4/dbsvA9Rq7ahsNyLgo3waEUdFTHwiuVBwtmOqpfVOnu3Ev0UlBgerF81BB
# DATA i+rBI4NjxnmX223OxIslqtDwXGYogQFIEogdXIyrsG3m4db31rc/gzDwDx9vPNyNkyq6ZYY7/3gVh1VcyeLikK2zhGSZ0276hJmO
# DATA +OO51LJywF8nb+QC1wzDcVP6lnOxhXBOA7xpfjo+HQVmZYnKI8raCFua1Z9JqfAjjXU4v35Lugd8XZMWQn8p+NJ3zncQVhpp9hna
# DATA u1a/E8VH2TCb4JZUH+pz4ul9jKdiywhsxndxjjByoW/J6pI87acDipDWp9Vxw+GH5XFoxiUjHPV1mdhko3O4THiy7uA7ivVy1DQ6
# DATA xuLy4V1k/jAMgsP8weUqFLh12J9gkMkQEjFxCd9fQtv5sWh52l9vUfwvLSKiBMWAa2Ox6Wrv64KDjBe6Rc0tGroVCh95S8DlIlTu
# DATA A7IJOpEl18jdVmfJSBYcaEGb5yw4SE9ifguBUazfMmSxoqpQSNhiPXIMzWUdc8aOSj39q6CMM72tF8HxkrcdQShceJE4gCofQwBS
# DATA yyYvQ768LgSf1hn4TNW1LS6VTAYrKZNihSJEl5kBvJlBJvjYdA50bCSjggGB4+dFYB8xjoA15N2xA5/h8DPDuSTL4KynjKkhblA+
# DATA vkY7niiiOTrB+BCMOdfgAOKiJk2QlUgcED0OCkeuytCmg9FoEHCF152wajHziLwAqGvmxh0MCDBIIQvrowDCZ33HAMvZNXMcdhyD
# DATA mz0bVpUTcDHny5gtvajq2oZ/F7TXalZCimsnBJ2m28a5cG3w25cMTKEqqUISpuD5xFLyKt8u94wq2IYIIxF6LEQ55yayJOzVfqsk
# DATA i5S5/+sAqJcZq38WMVaZTunv/MuKmOQg9V6AZBDCRoFimLtXMJxLkgvTOzdgxqUJopB4vi/JhCjCz/Yv/FgPuaGuvIEW20SXUjsG
# DATA +EDomhEYRViFWi42L9550tYF9i9JWTRF8BaUw+dOA2Whb3v7rktbfbGvTKRfhfBQ9z83b5zwv9IOVG6V0D0fnjHykjMZV5nqCqAn
# DATA Qtse9bvkRtzvqQ/7h/1sgqYc8ZMRoHT3a/M3icXbBMkUnojq2u0iH0+sIjPPBlqvX1uQ33v0hvg/J/1r0hBrPFKCJDMssy1YJn6l
# DATA 3zg3d92jIBzWpSGxJGCkg4ul2xG4WDa2/0UGEoSP61Ow/wc4bKUXgC/D+m5CrCTy0lFcFjhymk7UFQfjvaGby1EBHoM5FxVs+hgl
# DATA ErwIS5iGfb9WC4p1+7bbXwbosEhy5zy2GxLjhyEEFVmllN1HWXNyNBgd1OIbcZJc1AGLrz1ITw56KRZr+ZnE6jpLCEUKhDSxPkLK
# DATA MGO1V9FZp8IZyolfbZlNaiNZW1pyDYc9c0RjSwP9eUSuDHrTUbbN3wcXZa2zO5b0vHAIpePUY2aoxLNnEdVc0LPHMUMYLc21gAfI
# DATA oqHlUtd9WTfGjmOfFI8K2QSl9MRUrxcLKTHIW5DAxXzPCQpbAb+6MuGrbPM5slVgTFaq0jMlhSqNboipv4tXMSpYN4rDjm2t9PYV
# DATA BEsvfl3uZRAovvC96aP1zfXtNWEu/kqvTle9XVgrvugRlUq8uAkuKqJCZKMa9HlB/whdGQbhXCp6Il70YgOeRaX3yMS5MlaVC/s/
# DATA VQH2GD+BztP1zUcu3q21ZpTIwJdR3BQNF4ENi+Nb0CeCa1ponHZ/B0ghm6NJzCm3uIccEWlePL8QZ7ymsDYIAt/Wz8BbllrUA3sr
# DATA WzfTo17HW5egpz5fi6nx+V44Nh5JNuEvkvtarpYes3858HrstDdXmrTRWIuyMN401s5Y9/pgfPOdQ1/N1+j7t1QKuAoBbxqdi4U3
# DATA aSVuyVinw+XskKXKAMGgC6wN9X9KhH3p5rFU8uIEHaEoz3pzbXI0g8l+im9qAui5HW8QA48OZsOeYuORIn/pIAIiq9lFjoRxNJtG
# DATA OG+g14KcCNDnvGkS6kLNgDHeSbmxWtxoSNw10Eu2nxo1QdkXJG1WlhE4K2oSUjUzRola+R3NXmNCTp2L9YclIGAvXZowEiamauNU
# DATA twZzdIXPeNss3EFNnhtiE2k+jABr/B3+A1/muGGSYJpqeN2EjhfOPx3g4pUfXSnwM+54wSkHXzpZHK25X70JsRe/jBZD9W9WgVfa
# DATA 3XjYFC1r51WN5Ycz1Zk8ErsTiWJwKutm75utAL3w9mlhnhyR052AujNb9dJJ4DdBVWnRij9/nu2cLTZf/uTw96mdwl40G6q7Gcwk
# DATA bBmoepYrqloyJ45FJDgn2jSCP6xpQm6BqlkZT/rqSAjgZWp6EeTlpMA6VuaZsQK4IIUOnMdYgpkK/g2X/mJ/lFwM99w24AzkU3Wd
# DATA nxQ6tKpIvjmuJuEMqNpskhUB2W9O6v5S2IrqVAFA/nBxRfShTgcVWZ0OrEanw14I0DUl305ryHPUhH3j8v8DroLrr3WHzfHZN97x
# DATA /1bU/+7evo3/qv85/95cXb11+9b7+hk9X119//0734hWvvE1/G8G2BGq+W/86/yfn3vt/Dqpp663VuvXUdS43to7v97vXW9dR8Fu
# DATA quiDOirX69cxS4V6/Ppv3/zkzV+8/uLNn73+5etfvfmzNz9985PXP49efxG9/p3667dv/lQ9U09efwl/vf789W/Vx0LggSr+T/X6
# DATA n17/vSr8k5Kv6pH69y9UC79589eqyOtfwyvVqCqqqvwVtKb+71fq6a/f/Ex146fq379RH1KNqvhv3/yVevmL1180VfOowrreOr+u
# DATA c6ioTty/1hshDAQmvXjw/PnwPvwRDZSE1X7+/Ho2VP95cP84S3sP7p9k0xQzFOXZFF6i9gzf4xs4tPD4ZT87BVgk9afWoMHj035v
# DATA etzuKamymzXwR11bAhq5Evay9qqt63g6HTeAvr+ETx9SLY0dyFvWn541no4G/e6Z1wALYY180o2ex3k2OHwe34toyv2H07NB5j3r
# DATA nxw5T9BVrnUvGh38QC0/vxoqpgWFD9I8a6i+iEcAytIgMcs+Lc6O2ARe/9eil/18hlLvNDsYjV5EmK5GSblHx3AnOVaM5Hg06OXI
# DATA CqfHSjJOFVuM8hMQnOkyAQmVI9B2q+eKLZ1EWZqDeWI6AqbYjHams94Zfjua9PpDgF1iJFkl0IFIfQKAkNhr3OoPnoJqG8SbQ/Ae
# DATA iX4c/btZP5tGL0cDJfrdX6ZC99FfZ5INYBj9Lo1MdfcQfi+nudov+TI8b+Yvj+AdypRQ9kRVv6wevvfqZICtyppwlfLjLJuG6oMl
# DATA aHbz/JKfoZ1Pf0ZLARD6hSI/gBIg2GeTB/eXqaD6A08CHBNI94dbBJVA8LkkFVi7OiwDVSX26UV/LHvzTWBfUGhHvYDV4X1wfzml
# DATA 0watiu8P4GLhDMea9qAad1VUHcP0pZJR+mljkB7QtDwBuUk97h+lvPmghZL6tl5mEzjHWJcolav9089yU25nnMIBjvi5Xxy2oCm7
# DATA DfvxdDR5gWuDRZdVf3hSYcAkGvbgUz0/9zk1k52KMdh64AuiTKsPdo9TtYRjkIlNQJva4upvJasNm6r61Qf3x6pYFsG36nicRcfp
# DATA S/XH6CVodyHz3zEeAEjliK9hNVDMhJ06akbqW3VtRnc4JYmr0zaFI3Y2msHSwcdaUaWPrmp1/OB+r//S9ptIQ+7vjIPZdOodGHcp
# DATA PlBCpm7mIFP3XsDb5Yn2agHz4GjYU6faqW+RRVtWfYV9TrMdmHZ+QJN+88HWJBr3VcdmYzVJirQcztSkjEYDmO6bMN0P00F3hubI
# DATA w8EIpf8sJf/uCKl91Jukp0BxwK8PZlitl9kcUW+U0VL2simgFaobhJJdZ3C2VMfB7ovANQhk1B0pEb0PSnCa9cvsPzPeZdhwD+4f
# DATA KlEeduLYPVFqd8mpAK0v3RKgXps7StWnCj7Qa+90xSYig2/WkLL/UXoyvgfy+su0ewYdiv7ff4ou1X9aNd3rZSBKcJ6Ylyumb5v9
# DATA A7f/A7efx+1pW16Byb9jHn81Fj+fw/8PxODfMX9fiL1fjrt/LcyddqQcvmHo/3JOEBL8+bxTUfpRnmkOuqbZJqnzVIvI3TX/lEMG
# DATA uSa1wxwdcgCkGrvaVqhW4SXiKej2J8h8UYHnTQROD4o0mgXnqE4bZOkEofxPFNNWO2tQRwasBtE/yXrRwaw/mMIIgD7mNGTV02c5
# DATA fILSlu6fHgG0YDl6V8sDuS8QkDgwGg7OmtHGVMtwXcjzDRwfJk6xLdQ0W7O2FgXSHnAYVC9iF2FRGigWwFnPc8Qxinay7EX0Q7VX
# DATA wFlLGxeOs8EYdVXQySg9PIRVAoEkPcymZ2aEn41mE8ujeWhK0smjyWxoRM0DcHbKJs1onRMNwZTCOGZjkFZAztS7EPZ4jjKMKgAp
# DATA FEYgJCnykEOZdHA27XdRulFjyyZTsPEfqSGk4H+hXdugru5x1n2BKk807aDa0+nMf//J/5bzWEHLi35BeXc0VvWgPCnWrPn/sfeu
# DATA S44c137vq5RD1ma3CGBQhXs3Z3SGN4neJEVzKDFOiPpQAAqN0gAosArontbsidDFe8sOOY4cPhFnRzjCdjjinO+UtmiPdaEi7Bfo
# DATA foX9JGf918rMyipcGt3T3XNLiWQDhaqsvOfKlZn/n/cOyt/jdXlWvKCEnSLlKiw8gage4xXRlEpqpANljyu19TCmvmgSVdgOBMUE
# DATA hrLk7SyPObWJBRc2PUN3mBzx+GCAqljze+8mJzMx85CRsrNsQDUGO9ZKUZN6KrdkMMIpqtTK0cMNIqno4ySTosWewpRN/IdRNM8b
# DATA dTgYwPafJGgMgwFfP0JAMRQSIbzEmUmjB8LJat7HCd+35FKj26OUiwx5aVoUAp0jwuNIdxJUfT5CbxMvJAkUtN1cKMeWVLm5mqvW
# DATA qltl9IiMRSTxhAIzWTHiyUuhID+gGJuNSxnEPbAbbygdjIfjJVRCaazPlQ5DRLHmvY3OR/YeoEhSjIsR9S2qutJ7cH6Lf5Mqpaz9
# DATA K09zdhtsdprh7Ggm35qxfxVb/xpM/aLRRPb+dx73k0dkvvwM+Jo+19IqXXmChx6TxZNMJtV+RHPhOEkPsikFPX6CcB9Pw5Rqw0H9
# DATA ECscRylcPwfHYbpXrc7DeZTuHw6SCT0il8gu2z9E/3Xgd+aP7vi1dsuTXxDW/iF2mVOXf1I9ScP5QZ9q4MMqpW34JHwswcQzaiDx
# DATA 4hDa/tUlto6SrRdVk9GIEnRQC4Jo+iQ8GCOcx3zPECwQbiRVqvyDhzNquwfB/NETqSSVeDZfLiqyf6uCJzDWPOYoqnfpO2vy9/Ew
# DATA zmgYPqWf+dWjSfTokEaLo1mVt/wdDCJgog9/Sq0zHp1WVfvSl2l+SkYLxtWDZnP+6HAuxsEB5QT1mZ5f8/H3UErgwJ8/8jKa0gw9
# DATA K/9WMhqdx2xRzGlKr76sSjMNh/EyUz/LlwrFQMqjeiJxarfqhzSVyiicecK868NSNh5gAqPypGaamM6d/MpjK5rUTc0y2TG1Uh1U
# DATA UD9mCxV7ubNoeBeLzj95vJJQTr4dgFQxFcQBlQxGleHjZB4OaDZ4UGu1dGrUHJAqx4gMhKxK9mCMEUg9WrzIlaJ0TapI6aKuMOV7
# DATA l1NqFqfFq4+paaPGHDRKhcp3Ud2Xn3VdpqJ5IvGg/nrvxzxF4mGcWuVP9q2LKMrkJ/srdZhn0gd+vf7tQqVrU6XbULvw+v3d23Fe
# DATA dVFzax2r4urK1tCJKMW/Yl2U+KvoBtQ0D1VU+bNU4upqJ0LNrpqNU/pyUH9SCI5s9Z881pGrPzEZYuWC361T2FTZ4p9FB2w50TD1
# DATA hOdHpn0fpfHw8Ii6oVqDU1ZoJvW63F3jJJlnNnUGHEwHoZTbvx1qk0IdgbpA5f94axnp1Pm1oKVDlQykeEVHNIo/tgPu1OvmkbpX
# DATA a9IjT8Z+ZRxUxo3KXHXh1UUyp8fHvvR+8jrMr2AmS0AVkJYx3k3ne0GtiVdX2rXW8UmlVcOXferR600VU5Un+4cTsoSoSsDtigjI
# DATA r9QlMFmjUq3VGy169HAaPlJp8NuD8aGKVD+h9jmlhDY40sFukfOlO600KGoBZzyi5ncviBrFJWghO4vv5jc35M30Ek/lOoXYKAdY
# DATA fJJbxhNksE5auzMYP4mnR5Xs+MjUGiahHVrtVVWQcLlInsicuML7DGREV00FuDg/qFNFrmDCtIcnvarXRp9uIiKDlB3ShXW1PHCx
# DATA u5zG/sVJFM24Jvu1Vqkq+/WW6VZMtq2ruU9q7L2QvOxIXjYlL4PVvNS5FtSpQqwdh2guUUwQ9wtsPeA/0vACNbTy3yfsDrkwF8rt
# DATA dNPbvVBGLuXVvwsT+Cdl0+PAWCqHpWb5pAZv0GOIJ/CNo/hRNDz8WZV9MJTuQzTKqo9SPgRxg3IaGb2hizbdAtLJIcsQ9Bih4Mkn
# DATA NTJpEt05VoUZ2EbZFXs9+o/Zs4a+dzmdZQf+KPXo3039GzdQDt+rkeVAr+G0cherzZq8SJstaghy9yg+WqaRMSTzq4OQvaFWOLVu
# DATA kObtE6mqdfm1aipxcV3olp73pY3WlMFfyppWPa/WfPf6Oq0e5g6pGIWdG5OdqdR9r3R/LTuW/CKPOsPiXZR1KLnHO5RlGs1pVrjX
# DATA qFA9p0LZq1eoZKnbyGP0pDYI0+Fja2SxRp02D/XlWpgt0xGOcF9gX2w3R+W93vwAs//qYBxPhqvJ5FtqcJ9XatMlTUof2wYCX6GA
# DATA 8LtdeXqShyfYlm9bA721bWq9+dyiTrZJ/zbo3zZMq1I5cf0sFAD77IrNZYOhbgYYBFLqDSXNB7PFWPJkL5jtezotm0oiWLXantSM
# DATA 37Rc16kboGShkzC3eMoakAw0Az+GVoz6+IAQ4au0BrlOF22br3r24Nep4zqlJ17sUkcpM1WPo7uXQithqM2TGnwLxtoLbrJe4k28
# DATA mLNqIuqxpSbm2yVaYLC2BXJYshnwcaGzEnPP7uc9Vee21AGVMh4/mutmlFZbaEh3dDLmw5LorQ5oUsa9qI7RASVlcWrSyCNhTbat
# DATA F2zsWktbzar5BdKtaF/kGku7aaeufoi7qryAo96S+zEn8eMdzI3SHIV6Dpo3xYPosZ0l5fmYbo66eci4W5NCoenlkWVEmajXdxgm
# DATA 5FkvxHSD5oM7VJJC3fDMtwDfYNOtNgh7TCn21159NwOtGEtvbg3M6qeMBvfZ0eOS34AaSHhU9o6IabulbpoCCmQSmRbrTLe9Oqnc
# DATA 0DT7Ycm21S1pZWwt2QXlLlwMAhWkJ5NCPHLgW/Msv8k9pTSFPKPLzpthmI2jYgb/eBwPh9HsJ4UG9C8EDxjOFk+ouT02frBHbLrb
# DATA cyPMD/L3NS9o+nZWdjc17JLbLZydnsAN/QRrI1LKo3AaT04P3iETK6FxufLFGx/Gfb33/aNklnzxRmVKfzjcYpunvBzSOBxPMiub
# DATA gt3ro/KlPC55pcpOq5K9rt/pFWa33ITVJOqi5npYHB05xoGa+OQhNuzhfp3RuYMBWK7y3TyWVuuz6kAL46u6oeDW4JnKbv5J6rFz
# DATA b3VpJrqhOtTm8WRSTZOTi61sZVMvorkpdd2NNvOf0Imb9t9UHfQCLjwOr9wKnvBPuuCoi5yE84ysEvXBnkDbNZAH5sW4shjKtIzz
# DATA 4gCxKYyjO1XGxTZb60mNYhA95p5cOvAD/07V57HR8hFZRoPYDMlyMV8u+ERCObNkTsW79KtYtlljzeJ4WrhI0sd62F1ny0qN1h2d
# DATA qdBP/o9pNIzDPctEa1O3tv94o9PB9jQ02uh7lVeh2FqUTbI6OnFlkVMUmO5KNtl1huenG+efpUbZwMzVzsrifNI4XVrcV/Pc6FLG
# DATA mDZWN8fHfvn6KWQDiw3FGeKO2bJiMGyelgcj7WNsWVaKfvCePZeyq2dQMp+1GbtaL5oNrhechxVt5W6MD7tlxPXCo3ovL5zChCIQ
# DATA N52aahaHh91Tv3NyuRNZM//hjpyqkkn3nJc0s2oaDZeDaFidJlws8pVax7o1MQ78O5XvHMimD/oQjtBuwlk8zV1G+Th/yIsi8Zpf
# DATA dDTkdI5ui9IMK3oxquzwEPuYS1OZH5bLV1bqrF6BrQA1N+zT/PShmW2Ub3rypLBiqHdtYYcg/fEeTSczXvvEvryDO3dOTk5qJ41a
# DATA kh7dCer1+h21wQsbiN5OHuHGulf32k36h5d9UeM92QBI3/miJx1Z/j3l5/wAn0c0BPGeqUa9MWz2sPHx3lssV8K7hT7y257fGzeC
# DATA 4+73g+axXx/Tf7vf99s/Kzw8CkaNUUMeRhSLq6IZjZDRsyeySxN5msxzCpKJ2t/GN+absaji9k/xC++by3fXqc1P5qq96HyQ7+gx
# DATA ewCiIa+Fn5oNeFaW9Opes9nyGr2mF7Tqk0Y98Pxuo9qodzy/2ShmzLA97Ef11VztNLxGt/Ejv9OeBIFf7bW8wKfH691j+vshgm7V
# DATA g2JQ0Wjkcx7zdOEhp/9bzVar3oryi1VT9I2VlyLUrn/cDPxpvRr4Tbyy2utxZFREPF9qxRXfEAR1L2j6x37QmPi+77W6Pwp63Z99
# DATA 1Gz0vIZP1SfoTvx6p9rs/Chod4vJ6w56URiuBNlpUa70xn5Qn1bbdfrnGB+bdLnR7I59ny63WvTPMX0sxbzf7tebo3Uxb26sqWr7
# DATA IlXUA5wsfKw8wQeqhh/y/P5ANZZDPbU9+Fa71e43cMF4n+gR/t+hMWhWrwQH34r8qBV1DpWP7eBbrV6702kdioVx8K3+aNAd4Al2
# DATA O9PPw3YjGB7K8v7BF288iI6SyPvhBzRd+Cwck+1Zuc/bxzLqCqtZlMZ4VndpO92O7qmG3ZZkMuVd+oFYk15QdDp3xRAwt5vRSM1v
# DATA vhdRm47DigRdWpo7LDvCYJxVOrXm8UmlI44wDljtlNtler/Vv0Uz1WKIZUe5beapgll9QPvQi+NE4a55waoUk5NvwPgziLGT6PEl
# DATA lgfytQDxAJbMInFa1S9n3Hhw0ZY3YhS9AvWNxmwhtZWVpF1k3CnP3kodY7PhJi2VJ6tt/ado6l+8gd171EnEgwXvJJ/xBkjvX0Jf
# DATA zLt7z2yBrH25jNLTB7wvIEn3sn3rXnPz/TQNT2ujNJnurX/u/mRCj1rPqr18fxudQnpRP4MWXsN2QIotzy29N70v3jiwIziNpjid
# DATA Ldixj8L5HgdqWOEsZ/wwOq14o3AyQeXe9x7jwD/9VwIQmXzeU/ZAIgEi9QeU1XtWpN6ERtn+oaEKM12FXrqcTLzvensSi9o4zPCy
# DATA fbqkrlBQcuXAisCBh6OfokXAYvuH3hMcVR6MKVbqDZcJEY8/sVPNh+ol2QoV+1g/nsnj+odDlReF9Gcb0l+ReKOWzI7i0anGVpls
# DATA wRabNWkZ4XD3aiTD0z1MnvdNUUQQqP2Xe1+88S3x/H7xBgUNsaFoAkRrDXer0xl0I74dloIcJycbwxRj9NJhzpbTvXi4n6fm4+W0
# DATA H6V7HOYXEP2jX2s6NwuPDtUm0j2Rc0PgomdBb/riDXy9Q805nh3qYy5yxuWNPPbLFNH/4acf1mTH5Q/4eAh9h3qb9zY09H6McH5S
# DATA 8R4j4CcoDHk0tBuSPP3eJGK9jC/eCDkbwhp2/0GzJp3gm44vWhPFGJcGk3jwkNoUtp5+Fk+jZLnY29tHG0ek0uiYjIo8UhQOuO9k
# DATA v6qskKhgfUOXAmYTeLmdT8kMG5r3RjMkHGWDB1gIbwqhj/eOKdIfKq0VCiNb9qcxFWTFi4652O7RY/yxBtUY+vuubMzaU0XNAdF0
# DATA nKZCPwK9I16c7u1T+DPc8ERF9V8iej+WAxfhcfQTimSNHnwvHIz31OZPftGEjOYsFDE67l0oQviK+Pz4J+qN/0J6wDjjv3t8A71R
# DATA P/fjn+hSovzH7njocu5L+HL9lJUs+f4ajSqT5TDKVDTyDpF+pfeZTXKL+1raHiVsbX1D1B5wo907hVqneaZY+fHO71LFfCDJoQ5G
# DATA PuO80ZNDHdW9/PE1ZcP1Be/TybmOrNKfd8gOSoDcRUY1TW33jhELsIPvemtvP/B+XKvx52Fl3R2moMgCzpBMjgd3r1ZiJNKFLELv
# DATA lj9jstXsQ1/Oh3ozeWEDv8r3t9W29/V73A/lGQmLt7Rnajs7zoSSQXEc1biFP5F/i9XbLHgV63jyKK/gfEumi41+MpliHt5chPIw
# DATA laEJBYWIQFZsgC/eWLeTz44W/y4R448SAS4GCT6vD/K77onl27oqyidv7DqqTJBcI9eyX7ZF+0DF5QtIeE7J9pDaZqKwqeZsyE8d
# DATA AVV79Fey72ZHNBmE6eOxGe+Z99LFUi3TrWVDvTo0ByrW1yxUm7zeqLqj8wfmqhmh+ZvqyeUGGvVpbsXGGN+iv5e7e2maH4iWqcl+
# DATA zmTWJ+aQvyu56P3d31GsUSGo/5ru0Z/kw+QkSt+hzNszWUwNIWPxNf3KwtNkJSHhXK9xYoLuqx96VoNAphYrHV2wqwaLLkK8h67b
# DATA nWYxNnlN5LTse3/zN96ejtrduzomiBQHZKqAybe7d1VSUH9xiyzr0Zv/BUdBmht/3Je0vPmmFJQydrByqLOfv+TmDr7tyx15sJIf
# DATA 6B3r+YiklIqkDHGDCUR+21f3lIYPCYtrKccwynjgoJLXJbqmMXI7Qlu0KgWSY8pxawMuPEQvQhxVNaVM1oHsF2scblQWx97+3Xts
# DATA M37xxvvmUBiayZt7MPu+eEOaHqX/O/Kd54Dc3BfJ+9hWtxfsv4kE/6/f176g/83e1bPkJFmwq9ULF55PM5Y3JQA+bEYB0EPr30PG
# DATA 053irfm7fH7X//5H60EdoR2eG0ylccsMMD+Q6Q5mu4PZFx3MdgeyX+kD2V5hu7E6B/1CH9Q2njP+uXACcGId334wZ7U8jGzxELAR
# DATA fXo7v523FfM5uRfrPPfLcqrxIuEW21HK8ReP8723qKctN0O9SIZomJWKrqx3WSt4ciGc8LfiQfXy4pU06UGCzJU3nc4GOhrKj33v
# DATA BytrX2ymkj1QOvhvPcNfOB2cAfN7XLQHVO7Qg6Hygj2ULk6xqdg8PxfdgGwc8olYXaM8teGCpoV8HHnZp3HNg1fXwxyEwvyS48G7
# DATA lOIkrXk/mEczPuc74rP79JA6zM+V1aOwxqh1VCc92YbAGCbcTW8GY4ECmindgB2Vd7ySj1vrCPB5Yo42WQtkZB/hXJqR4flbHHNG
# DATA hcPpbiY6eJ8sjbvXm+Eyqx/JO2L6aTmH2ZDVPNhS/GPGJlUygpOHWswQlppqNmQuJywBMFqmZEUsV9UQXs3DtiYEZ7056+0i661Y
# DATA w5y+jtPXuazZttFAvCndnQfYwmbJQeA18G1COM8o8Dw/jbdtwyV293m2XF3BkuP1D7Y/sCiituToa1zY6ITEjmWfgM5k5QXcm+6/
# DATA JT5R3QBnvB6FQpLQzHOmu8qvsFeMt3/UWryJSGtYU/J5QxQuTkPeb9RSm0miOe8+qknPfofjWIqqeCFMdcC3HSKqnzLxNBdMNBu1
# DATA 9jVGUzwj9LP20vCFt8TRqiKl7zGRMg+9lXCHn0cuwJvv+QdB/a07ibIKy/e01D2tLff4dXUTfcjvuiPRypOibHWdm2oVjB7Mm8HC
# DATA ljwis4GfYEMindJ7eU+wSqdaDcXopatmfkl6nviYXzSncXohOXBHgsD8SeWWrNPaoeSX9A41c+WeZXCGmJBZHYAtTcVGozT7JaUK
# DATA wi/GoPyIBkPqn8Vo1F5rq/1jjI1m3PLZUDQDbZyKHVnz7g+HHp+JVWZBpofP3Ib0PsQailL1xETAjLRLyKaLo5eNUjHEqcfBG7EL
# DATA g942X04m/OMSy7A0qMepNv5/mEWivCMiNqL7E/djymKRmNciUrrOY8E24yiQWQLDgk1p9ESY18QZpoWUpJl0flrliu31CYTvrV4O
# DATA Y2A/Yr1MzjTu4KVIuDRefavZHgCd4ewM54sM55KB5CxnZzlvN4dfAMXKz+ht3Dgy0cwLh6o15GZzSbMRg4vReWNFxIfRggp0diTS
# DATA dkXpRWGCJSOMW4mSgMyVEkUPsWwkl/yz2K4opaC2LL41brD+nBZy1o2dYtwQl5kRqYQFg31K0FsMJboshp2MRtj+BZk+7gsyb5yc
# DATA 0M8elZAMl5zXNU8ZF5C0pNgdY9xFP5OMuGPgPLfkK8VnxckpDnqLkL2Z91MMVxMz0pkU2Un7kJ1y4YBsHAhpnlCPlacMI2+Vpwyy
# DATA IZpRp+Ek4+1isHSQxCOyxTLdqw2p8MbUm3EpcTLllA+FMGNRcbgRyXQ6krmTGDHaX5ZMyWpcKHXBEFbBQ08rhWxJ57vhKffE2xOK
# DATA MhRXJcpYp/GB8j+OooiSNYxHLO1HszsYahA4xB5G7EOgarWQLRhMN6Zf0BTxC5uA3meM4fGYL4gA2bJipiwcg1QVdUKMRddfnkql
# DATA Pl2gPmOT6JZEfhplaxIoZkWhCq8KqpqqTlYq+y1PoAqPSjZBE+RRJ43WGbEo0oq2I0F4C4cxzt7JQCd2qhKTpNr7KfRfhpSJZBey
# DATA 7Yfkw85bkjHBTzwUj6t2KTOkDLV7Ku8Ue1JPpbXU6ShOp7w4sm5uy4n6jPJG5uNg9M5xjJTMJKO2Ti3IWM/54ncm/mu5n/KDqyOZ
# DATA Amp6HmZiC3Pv5H2kxT2pd2XYA5vSCsRtfMjUeB6yeYypARm+VNLhchGj2whT1umaKuVJVj+VDgVcKHEbk4WA62pKsTG1fztLTqR+
# DATA opVQE0EfCcFWneB3Ew5/gX2VyG1pi5SgOVwJ3DXy2CZ2ieVXQOOnUsaWhnhi4FopTxdSKm7KPrKRKMMkhVTkOCCNHRnhioJsoRvm
# DATA KcLstKwma+YTtqysZeeLzfwKWvtPnlQMQ2dxBDhvemoTdP6/81+d/eHsm7P/fva1YuR8ffYX+v9X57/1zv4JTBv64ef0729X0Tn/
# DATA hX54Sjc9xf0Mv/nL+W/Ovvboy+8MROePFKhc5q8A7fzy/DcV7/zf0HP0DG4DPecbetOfGOPzD/SDMHX+dPb0/Nc6Mn+lW/4goB7A
# DATA dhxL5yWYzaBTxvEl6nD69GdREM0+ihIKJ40H2gSree89mk9kfJ5wjxhJ35CN4zn1FhPLG6E7R6wizqPcZ5DPhZLJRI1P9FIt87sV
# DATA qoPlRBWeaikOrVOc3+ge5LbBOutK5ubwOnnVMbfCpMsvlx+YiN60uftD+c4j+jUTdnhcU8N6oja3YjB1gJ0di+36ETtYe4/Y+kTh
# DATA VHIXIxu/yD04ZLIoKhimYxpPOB9Zbj9bYKZa2q2skZoIwhxKiRcrfJ2Lq99mh+aalvW8MDsXJ8NxdpwlcBOWgAbuXNEAeE2cm7c2
# DATA +N/I2L/T0H/Zkf92Bn6pnqv5kDN4XrzWdRMwHisHGMVTfPWa9K6CPOh107laSVSFR3mW4qUKfBNJ1mQqbyqeksD20vHpYjzlUOSA
# DATA CWfQrggeVWT5QiR1xBPGyyyxUguV9AVye6H8s3JMbhQeJxgVFGtGxxgvELgJD6f0oLYY1Lm6w9xeEGIRfD8wI07C2cJ2iw2SuWPs
# DATA OMaOY+zcJGNn11Flp2nOrlbyLZv8V7H4r8Pgd7QdR9txtB1H23G0HUfbcbQdR9txtB1H23G0HUfbcbQdR9txtB1H23G0HUfbcbQd
# DATA R9txtB1H23G0HUfbcbQdR9txtB1H23mRaDtBK7wqbaczao0GLxFtZ3XteSfmDueuyj3syvT4Xe12QSGt1SzlerPdLXJzoqg7UmAj
# DATA HG6k6A040EabZUAGHGogwbBUht9sFyE+DcrwNWikTtNrBnUPdBu/1Zv43boXtEvUnrbfanX7q6ScZsNr+r0f+b3muNk9DoLW1O/4
# DATA Xv1Hfr0xbnaOG34xCoNg2Oz31ySi1a3nifCDnklEoxhA0AuGrVViD2Ws1+wEY5WLFj3HPLBCz2lfgZ7DNdai51DlL9BzWs1ueBV6
# DATA TmsYjfycntMO2n5naOg5g25/NOzl9Jx2u+V3b56eo+p4lauxGRcaQtDRw23hpnWOqgaPI5Xe8Umly5ZUYY2pNRgf7kzaKb9NObht
# DATA 15aYGOouHC24HtyOHeIqbkdNNLvGWEUZH/JOjnE4TE4O6h68G3VPl2QB0MPtevUV2u1uTPOOrJ8Ucr10U2GtTIbzEgzncMN+gNXR
# DATA SlGS1nlqZd12S8iqq1FDm24oec1omvhd7EpVfcZmik+htC+wEQuZZxemSoyevMAKcZQdR9lxlB1H2XGUHUfZcZQdR9lxlB1H2XGU
# DATA HUfZeb0oO/FI7Dese6DGP7a/Sd25q0ZMNXDJbxWui/uHTyxMz2PJN2TGXQ4Gp45MMG/SE8DvfPHGm6vvUJX6UA8o6iWrN+a3qAMa
# DATA dBfbuYcKEvQxjnFJy2dTfnLKp3P0W8tRqnn/pzoDbx1K44NnKGuqUCYKVX0D/fDdbSP+NWWFsZlNUnlxqrZ4tMjTTL3jF298aJ28
# DATA M8mg7lKlQCa6pXM+7gi6O4K+8xH04oEwdxbdnUVfPTW4UW/zRTijXqrjhdZii9Ow548FaFGZs1wtRQnfxsMozAroFj4RDWVLkIt4
# DATA pMmoO5NzwlpJhbfSlU7L7noGnZPA+owYy1mcT0mC0qvgQp2LHl+fZRcRvzWHQdUuq1X9emW7ogryJ6UGr4TD9Y+5nrm5wtttIf8Z
# DATA cTgmenFmZfVmlXdjELM0unwuarxbd5ju035qRaEdFiUOd6JDk/tY3HWToLvqUjms76nPm++W4/WscsefNt/Jfa6SmR1Em++TfpvT
# DATA z5+2iMrLQVMt5y52qK3mjiFmi5Z7oSbAf27Luua/wFvPXZ2eB8gnneflPCuJbbJb3/QCYlVzzUuXnBv//I//waSjHHEr/+csUYo+
# DATA ZxLOc/1VtZTIe9LSJSQSYKMlLMUwgxI8a1FDrTSmWshQpnA+pzrJ+rrUMaP10SR2tpDj/9BjXUD/SOvQslY1L35okdkTqtzqsLjy
# DATA edktMz/5rJtGfrDaOM5wWSXF5Iw+ekkX2BfMNYXutUAAZdXWSxVRXlEvW0B//982F5Cu9FI8H6AYqCJnuoA+O0mojabUsXn6lF+m
# DATA TBDqk5YzeCJpSJrXvA9olIeRM02ORZCC0sCCAxA2OIq4W0UByf5hVU6RVrdQpfXspWJScGvlYrqFyxbLv/8vm4tFdTFSKiIHOkhS
# DATA moyYljNTE2G5zNOcPmu6sq6yfPLmIRrWUEwHUfAdUR+enKgiKtqRLM3OZnFhHLQuxwsY0c9eSnaKbq2g8n750j3cbzeXlO7jpag+
# DATA D9Opx7u78i7uBNcEjjM8hhY2lcwRFQyvX6Cvi2S4nw1FSiNi9VjoTEczQHCkBNRsoB8xuSNeiCYHdsfaPzN14tnLJ0/GrZXOs4xA
# DATA /88/7T4CvYNBNkplSLB0wKdsV1O80ofK0uYmFU5YvTz0pksafyZhin1yc8gnI6O9H4nxqAYYMpHAMJBmgxJ/9pIoRPdlaCr/cdem
# DATA 8iAZLbw+qn2I0sm7NYzxfcqiKbRsoBkzoJEHkwNWhA6HPw2xP0fV+AyFlbI9Hk/jCc4bIKegUkGW+pfLWNRqoILIwipSgFoR+hqa
# DATA SiEZVyqgohEoHk3bCDRXJLvvfZxo36PWFOLZh/IJJqlQGTFAJ9yJ64JVwj/Pwg56PcRdHJzbudKu4EpznrPXxHN2WV73C6HuWNh/
# DATA uR3bLXNuGkgX2KpJFuURO7U2krtfUBXIl0g07SJtaHvf401QvFdbybWzvNfKiG4ieq+mXN1m1LHF+YJJUM3zjSQ2O5Mq4jsSNciT
# DATA xDgucieTovYph/AUUG4j85cXdMVbZoIvhSwgBYOdEZKErKyFvabWKH1urpO5nuaVtMA/hqdrdgRooADGRbfHSIFbyoIafKM0sw6M
# DATA nCjM6lxU1FYS9dhnQhbrQkoL8x5Y3x424kJv87hQH2Qzm2QWb1eFJuosb/CiXahzCzlce52MRzsIZz4683Fn89Gua24d1q3DPqPV
# DATA uNFIvZl12I+E+2krRefEw+dDqrgNSjjv/UH14mODhWVO9VOO11a3rqwX5gtJ+fLYprVFe3nDXq3ZdH/J0V5aStj0VMH9W/Bpb3qi
# DATA 7KYsu1k3PVf2npW9ghtXTgulwJusEFNUp2E85PogC03ffUvLV6piUfeCXy57ToUlrs6ZatJ5eREch8w1f8+2qDzNvadO3bapxGWm
# DATA X70DRZw3FUxPCw3o5UWIY6FpwSTUOXr6TFmqycR+SzTX44nMONkEj/RMykAkqf2Y1aolmwoUGj2D597VHQn6Fnt49pRACE8AjMmu
# DATA nvoclrj0PbLuOBTXMu8rp5hAuBsLNOqJO8lqweXzxvVO47yu5XsLwfHUfRSVdKmEL2aAvzpWsgUHZCmkZFpgA/4HBfH75uwv9O+f
# DATA z54Cw/fUwzfG8n0D1t9fzr4GlG+VDvjfzv7KxL/fq7ufnv3RY1Dg787+dP5/nf3h7KvzX9Kzf1KB/lEhBP94/itco9++Of+5R19A
# DATA JBQQIMiEiIM8B2AhcwP/6mCAL4PVX+i7R9EJ2Q48iZ6HkK5VEAD06tMR5CP6kOzSGBDq+LAqe19hdZM+Mw9U99zXnZbus5dzfg2a
# DATA EIdHRsZA/CfRYjnfigC8D6kLb7jMsNmF2rMDABbsfd1L3Db/b7VYbo7+xxYWE1byWwv1rcwzvxOdRvM4ImtD3/+euuBBZQgI7SS9
# DATA Zgwgq4cxEnq54PFfndGiJuZIgLsW4fWjAKmvwSI4tflZPEKnwzB4hjhju1yaPIKGTsRnl8WUh8GKWkid22CBLQxLlv6XHzO1+UTv
# DATA PdEVTVyqZIkz4wbTuPhotoIF3L1abrZ1Vhre84ID7p4YBwl0FsL1WQgaDXglw+D1cALemlFwAzbBTibBpS2C2zUIpIqWs8OYAS9M
# DATA q7oJJKCVarX8tSGKGi7G7ouHp95RGg6XoYL+ZfnqA2QMi2tsjBosLkqcyqZPLM0fs+sJa20si5jNowFGfmOK7QQHNOM6K3NTgjPZ
# DATA R0cZOAK+jCtgNRlVUTm5n6U6VPOgYovjs6FYDvDRMQFPxUGx1ZD8eUqXMl5LVaWtzDdZJOTI8o0m+2rexxEAcnJBNu09WMIMSZPl
# DATA 0dhbzqiYFnKGnV+cOYygwwg6jOANYgR3HoZ2miRd1qC+1TnCVaYI1zlDcFRBRxV0VEFHFXRUQUcVdFRBRxV0VEFHFXRUQUcVdFRB
# DATA RxV0VEFHFXRUQUcVdFRBRxV0VEFHFXRUQUcVdFRBRxV0VEFHFXxhqIJRJxqO/CtSBf1uEDXDl4gqWF6B3okpWITn9ZoWPK9TN/C8
# DATA TjFfh4OoORytoe+1A5u+18zpe+3exrzNC2bq17te4Hc832963Y7Xa1X9VuD5TZ/Ki64GHa/bLWH5Ou1et99dh+UrRJn3Ya7Gl15o
# DATA IQ/9jolvqwiYrEftQWfN80EQ5M836jkysbvb8w15pcqvVpDn127PN1tW/BtWfu/4/lbXQj42G53Lvt9v2+Xt5/Fv7Bh/u75I2fLj
# DATA zd0eb3fs5Nuwxx2zXx5RyW/3Lvv+Yu7Vd3j9ZSCR0kg0JFL6MgsSOeiEw45fhESaRwwkMqg3+q1eARIZ9JuddiuHRA7qw/pwZCCR
# DATA zUG7223mkMiRP2x3RzcOiZyhP69mD0/zdQ45QnkcXcO6Q2C5OrTNxfaDea22CAumj7yMZjOY1q/Zw6Iy3A6mBu2ion1vhWLfqa2c
# DATA 3YiVhYjqRQ/FRZQS1PeoLHm8a67V2hbV0LOzRd3m6V0txbzRs1bsky84WktAxy07FNR+BElHNaMfptEBRC83UxpNPlRKyd1i+pUL
# DATA ubK1vNiZYopM7MGVaiLmU7BLTnEIjgLpKJCOAukokI4C6SiQjgLpKJCOAukokI4C6SiQrxkFchXiOA2P7sLUo14dZ8woyXfkqz7J
# DATA gkxQyMWPbEUBtKo36WmqC+9jQ+Sev//mF2/873+sMfHw/lqdAX5mT8IP53LYAG+kYPZNOAHC+V9fSTjvoMXz8aVpOFuOQtbpl1Nd
# DATA ch6RmvNcjr7hUFUoyIXoEd3Ihz/JHMhoaCsQEgtndNzpe3f6/oLT92uOcLmz+O4s/rOcxd+ox3mjZ/RFETHhg8j5cW8ZVr5r9Dmf
# DATA v3zMbWh1ymgHGVUThREfkFVW5950uq8oibqFztgBkgv66SBMt2YuGEXLTquoJDmNZ7LuVVeqk7wKpPQmsd+Gf93MUzSDsl1VLhtv
# DATA KxATdfuaiX3QWhf5wIp6txDxeq21OepmvLejri+qerQ3jI7SiKbqF6TACsukwL5mUtBem/0NO/f9YEvmb1To1K0ENVo6iJdVndMa
# DATA cZmHSHem0pr1EfeC2Yd502J9k6FXxTiy3j/NG7l9A4vsi3y+FHeULaQrkScFz2iqRB4G39w/FZRjoV/SugOsX6FDo36EjEBlIGK+
# DATA NxezYRhj7sePQUOYJTVOwlMZeKQ4eezPtLDG0TKkEWcRRSwNroQtvqQOjswvHK1XoiBrYrSDgOerd2C9NCo6y9pZ1hdY1iWjyVnV
# DATA zqouWNWb2UovkvJVsRWEJr+M+NUPwd8zakdYxc61jlhPBi7xitFvEnRxNI2zOUvQeJ8Zugob76ybE8EzdxIxmbXi6T0bGJWiOZbx
# DATA U3oE9adsURcJjitiV+Y+Gvrfj5X00ThJ458lRvJGKfiHXhaOwNeJUjKKWILJlEo2T3KFdJYoYtEoNYuIwuyUR95xMo0gysOzCbL7
# DATA KsLJECke3EujNQ2sMUwI7qwyyi2sIig1cGxV2DBlKNg2w0jH/UMI8xQ7QGydUKo94EHmHaKxiZazkA0bqlc17+14lqAO0TMas6sN
# DATA gVn0aMGGJC+pIINUP5pkcFupHlaZQFIFpvwyCxS6zphYm7a/tcEIk+RIp/BTnGiWcpNqVZizxViQhfpHnIsVGe6CSHhNTpVaPvf4
# DATA 2UOpafm4oTdFivxrxvqvI0i1cyK0IilDTxkX5vFZMOC2kb2LbFuiPhE5L2kV0amSzMJIPZ9yFyZpFFUwkZ/t5+XBDsDcOA0XRjAs
# DATA H48oL6jCUhplwqn0lCjLsMt1gv0lXJVxhCa1K/RpBt84x+YRBbAg4zAeggZb895NuEli+DPKZBCBUwbjCJ1fasVmhYDEltWFuq8m
# DATA Lv1QFfbSUtA36ymGSWquyCBxKhe0yL6anBWf5x+LUy+9OFWYVtV5CqT6s7wvY2KB1Nwcaq9k9p/pfb4hT0zCU4UOL5oqGfWE1/vO
# DATA gIdQxvUM46n0P9f7BmxTvPexHjuQpnk0G8ST630L7+F+T7cgvYRm96DX+76WACxGkdkzRA2PbckZtbbiu+4sJzfGoH315leOROum
# DATA VrtLBruJ1Cs/kbosevbFkhA2e3pvgmFazuxrJ5iuUTq+mF86KRAURAOY3ZBFXeEteN0XS0f5ZZQQ3RG34BU2lmsjPJdblXwxk43a
# DATA yuQ4n/ZWvCMoNOdzGszCvBATYGy1MvPQAU2Bbf1YUW3FpClblGaluTeh5EnQ9rcI6BZqLVkvx9HFQtKok9NwrkEOO5XBmhL9JI3Y
# DATA o15Qw86iLNOswtfIdMsJV/3wYZQW8Fb/9exrUKfOf372F8Wg+gNjrr46/7eMq/qf3vnfAzN19rtVuNV/Aq2KgVTgWP38/N97Z78/
# DATA /83ZX8++Pv81Bfq04p39D7rlz/T9l/junX1jQgM1azPw6pfgWtF/HdPqZSDZUh3G83A2UAVjCeyQcc8yRJC1FfNIMIRrAnLlqnPC
# DATA nExcGjN2WnC/NFJgnqFcStDHyf5aYeRRz5Gxp2srwuptbKBFO4nQWTiAlW2ASidw2/SqconcHLsKktDD0nvXIqu4ipkb3+UKdzOw
# DATA Khr15mrTL2opNgknw/CU9xFS/XgYOWDVReV27Zyqt9EMuATmUYqzoqxYj+N4IwZsy+lLj2x3aJmoVRBrC55e74dY/lEaDeMI3mgw
# DATA CqhPjVJ4u/LlFNUvxjMyh5aSw950mUl/JmbYqVC9B/E8WqFY7VJTN9szpab3vOhVuyTCcaucFXBlK0Bjqq4w+L8WnqdbGvivfdzf
# DATA adjfddS/rUFfKmMx9WaQf16N5SboU8UkeuNoMod1QoYHEMwmcnmC0/HpYjzFiqwk/UCGWgi944TLgj8ALY1skdVR6jBBM/qADPzw
# DATA mMbJTGdHKtJmvPUAa7LpkrUUKf7T2HCBtrOn1O4IeJgiLFFHfKZLBmKO/YbBXFwclkHAeCIeCzIxIapo/8OCecH7APUmCoUC4pew
# DATA gAJQU/QP9lTAztNr5MtFAnmoAZO6HGDKAaYcYOrmAFMXjSM7zWV2N3Vv0Wq/itF+PTa7I0k5kpQjSTmSlCNJOZKUI0k5kpQjSTmS
# DATA lCNJOZKUI0k5kpQjSTmSlCNJOZKUI0k5kpQjSTmSlCNJOZKUI0k5kpQjSTmS1AtDkmo3mu2gc0WS1Gg0ag0HLxFJqrjyvBNHys6U
# DATA oO01Ot0vq82q3+16fqtZDeoB/fU9n/5p9jz6WsyhQdTtN1qrPKhexwtAfWp4fr07rfoB/dNUX0sgKMrk+qC/DgTl9yRgSn9MA7dG
# DATA HzUs9FKj1baKXnGQBEpUBFdFzTBqRSsRbXZ8L+hSslue3wimjW7Vb7bUt5V4Rv3+aG08G6v1q97ymq3WuF33P/Kbgdfs+uOW1ouz
# DATA GFitZhCtC3K1xrabFNOG/6Nec1r3glaV/vG704BeQ8XSxedq0KUvqz+UXtrtthvBYMtLL4M6khaiUUfS2CzUUb/e8YNhEXU04v/Z
# DATA qCP6Go7qBdTRyB+O+n6OOur0KatCgzoahoNWr5WjjrrNVt1v3TjqiHeYVNn0sFlCKrLF2aePkdCT/1IztycDNtNIZgbbID88cuVv
# DATA 3oE+VHDCtY0TTpbeVgFFVtirDnkeYWXbHD0UPdwVTqQtjaAcgHeJ8XrLY9sH740QIqsEbV+gJyb05vSUCreDUu2ooi3mz+bkOJKQ
# DATA Iwk5kpAjCTmSkCMJOZKQIwk5kpAjCTmSkCMJvfYkoZHiCPHRK0pw5eTu6DtyaXw6lNVDwH7IuKlk5qcsZIuSr56aq6cR9cjqsqYP
# DATA vY9wmSA0epNy6Ij5QJ9TDOXiSRFEpH5/QMHzz9nanz+YQRQJxgK9j+87XXvfZ8kinMj5Pr7ro3AxrrHfYG/05smb2Zun6mabM5Sf
# DATA ZHFHpd1R6eJRaetckzsw7Q5Mb5byewEOUuNM6iiv5uGpF+L3grz5gpVPpD6jBIxEOOpNBT9DNm8ySU62n/Wdxo/4+PE8TZKRPn8M
# DATA nXHTUGn8xVaUZRplz6BtTiNieoqkLChLkD593PK+ly3n6FSjoWrRcWbIR2TZKLBRSgMeaifk9CbxAos4CU0eMlbCFpDJIF1O+4fQ
# DATA holnfB47M4eqR3D2HvP53c/hwi0omKSs6S4K2tkgSfiJwXIOmW0517xNQfsd2BDpqeyj83iIypM2gsg6VAARJJfqLIqGme7OJL3Z
# DATA IhVzmcpxnEyGfNYVMafE0hyY5cBRKiP8dkRRnpyyULjJNlN2oqzDMuk4la5V0TkNmMhNkgWSTpf6ycnECydZwgeDt0qEv0/Vm5uO
# DATA HNumt0apVXgs2Nxna5OzS98cZ/oU/QnqIrpnFveZ4Hwv+vGax4rqeU8+wIaUCPLo8YRP5uJsfFbz3mG1Zq67ngbUoDpQ5BEqUhsO
# DATA sRGIwzLHEJWqf7i4SNSdc47jfEIDidEVxHZUnH/3cJQGL6OmE075dTTQcekoSfjBciGFi201c3UaWHTizXlvXJnEisKFavEzyNQz
# DATA HCcziuYPJTzxr3CIZBpO7CyJzXnuMJ1eTdf8bRGiRtZR47+0sDka4XUrm3+KzEfhjeCclt7pBgTNc7alCB6hKNgQ9XI9ghvQNDfK
# DATA jGzUzFTbQzeLMe8GJM7vc7dvbCWlJnF7SuCvzkHuPBA3o3AziuKMolyl3LTCTSt2nj5snH7c3LTiAbIix+FIdPSU4oXXBrwNRKk4
# DATA 0ugye768vaOLsJj6AdNhmQs5naN+FSBpfTPWM3ft0S3f11+8vW9fFFn7QRPhwsWc4tldF+dmy4pyb1eCKvsbmVAyWewQS3V7jnhV
# DATA 3wsm1UrU7MxsFAmpW6ImTk/6ueCV3CGS+kETS3Mht2trnYsiGmyL6EYQqsxfMVpZLe3lpaFKU4uzotiR0Sx9n/oWah3ekZmLV7x2
# DATA 99ueqbfelEzqzGs01T0n8E/TLJ8m0tFRio6Sn9LILEy/hZvFN3J3xF+VDpvMTA3kNGa12nhgujq8MXokayZ6yoBlMEzqEVZJyozl
# DATA uay+TAvYZsIqk6dlFQKT/nxaIrFTpw8irYK2A+X01bG9HX3H2d7bvfnO0H4lDe3LUnaesxAq7wDON8iuGqA2hIZFB0PtwTZ6oZKE
# DATA zRSa5yqf+lLICvJ/r5lpVBJ6vW6i0YpU7lqe0Q7itdY+6lzCFt8iCFcm4ahiCDpsZS2zsTKwSvUUO8WlZNVu8bfGjXvvpzHWbbBL
# DATA kb2IdAmM+vgRbBj2/st5LqYdxkVzhyaQmAVG65ZdlKqmCJmKPqk6yMBbuJTJUzRgaFpqeVSN1WKia8f7AdasEHOy70oxF9lds6hC
# DATA seP1C9MmRGNUL8soBimOk2F7trVaxPKpvPSEs4hbIoxmv2Ns+VjbLGH6L8f3AVaC1AKdnj5HRXHUsLiwx0smE7PqR3FU8EmsQGAR
# DATA bHNE6WXr8vW10e60yEFkuA3A4bHYQf/x7OuzP519c/6Ls6eA/pz94fw3DPUBPegXzPD5Of0GutBvV+FBKw+f/eX8N8AN/eLsr+c/
# DATA P/vq7Pf046+ZQfTHikefvj77Y5WeeIqgPb7nG7qH3iFooY0wIQodb/mK3kA3OqDQi29R/xD6ZbxOzL2JooWdVmRBEJeko1W7U9Po
# DATA CPxlLecsC/+qvprBPWXR5gJlmnrjrQyhd8ahqBpYkuGOI2RZ16pLuG2S0LpyuTmaEG8IGCdzc+Pn6sJ6ptAozrvp9+OF8QRfM01I
# DATA oMZsL4ivyCL6vO4coV1K7NppQvc9Aa8DBF5dLPuRKXnx4MfYQzv1ZCd4zfsooRowMyBEKsRj6L1D0gNrBKzhAbMsVJtdQnyeyKaP
# DATA FO7DKfMYxVnHxpfAGiESW4YHba+Sm42YNe3seaGDtifBQYPcSH+ZkV5zgq44wL8errPbGtxvZGzfaWi/3Mh+8wO7VMvVHMg3ut5e
# DATA a7kJUFCeMohoUQDZapwX8Lhhs6be/KfjuzRp50NOjBPRBQgCTMy/M98ES2BMW1FbQvkt03BGqctMuiW1JnjBDE3n1IXNFjthg2Bf
# DATA LXCQH/lAIY1S6u3yQT+W5X69sIVgWEyOIUaGAJRGklUGiXwqQOWKNdInwPwkI0EX40VUEb0HCyQ7Zo9HPPKoVT0UGsoJdRTYM4g2
# DATA yBsMUuSddog6epCjBzl60A3Sg3YbU3aEml9s896y8X4V2/1ZTXfHDnLsIMcOcuwgxw5y7CDHDnLsIMcOcuwgxw5y7CDHDnLsIMcO
# DATA cuwgxw5y7CDHDnLsIMcOcuwgxw5y7CDHDnLsIMcOcuygF4YdFNVH9VFwRXaQ320MWvWXiB20uu68Ez/oyCSZdxEWWTPDVjQc1Tex
# DATA Zu69NYhT2P8C9gkkIQrs02GRBpY38H1FGCrc3q43L7jd4vxQ2B7d49FvVb9Hf+v0b6/1fbo+8Xt1utb2Ar9J19rVTq8aNINxs/dR
# DATA AGBRpzvuNKd+o1VttsbtdTFpBpsirgBGd44KFagZ+IgMvWFa9b36sSB6tmRjNOr32usRSfWV6klxbgX1cbtZ/wipbvZax836tFlv
# DATA Vpt1+lRGEPXCTr+9Lujg8jQgqfOaBiTNx6IBUTIGnUaRBuR3Gt1mz6YBBfVmtzUs0ICCbqvRDnMaUH80bA6HhgbUanT63SinAY1G
# DATA g1F3cNM0IGWUrHd86LSWbC01EmHjWnW7FeLRzRh28nvL4B8zUVo3KdJuNMx1K81ak/k/AfN/Vtej2sVIaePG6qbFduGEUI6HafUI
# DATA U2PwLOrD6Khirb3bn72gN39U+Vaj3uq0++z2269sDql3yaB0lLN5NLgslUjbvPAerphU1orc5sVxtRQuPuFqRj9Mo4NhmD7czB7K
# DATA c7hiR32zzVEye6UOse3kSEKOJORIQo4k5EhCjiTkSEKOJORIQo4k5EhCjiT02pKEFOnnM+tYV36eu3iOq4zhEW6QnPKmPNJ0IewI
# DATA QDMCnWcwrTHM551kygLoK4e8+XgblpJErSrEQZVkpo6vaUHa4kExaaMykdMnLdwZZ3fGuXDUxh11dkedr3jUeaP44M0cgX4/Zq0L
# DATA PkvLLsjy6Vl9FPpFk9u4DT1uNbig6lB9VZLhSOXeYHqRRLN51nRY+RUj0txdq83dskWafb9elGlubZG65sEPki6q9+ILb4kta1SU
# DATA 5Z5c4Fo/9FbCnaktId3m5Z5Pqe9TeCGuJ2/dSZRI4Jon2pxdNLZ4d7xFGj1krcgLH2vxi2wzYAqDhuWTi8/ekdTsIFT9nq6fqLIe
# DATA quzLq1L9URRmS4hG42DtIExzgeoHC5Hko54kSRZygxxrhqxPeASxZ/ijTmjMqnk/5MFtEh1TpUEHiE51qsLmZqzgNElqhIfShMzJ
# DATA mvcpLwCIaSQPsN6iEvaj4eQUBU0FES8K8tWAaRWO7cs5Ui9d4ow3jlyHOGAPDUcznkM/kCw2qrNc+BnNzpbZPBL9Q1bMDmfLEQbi
# DATA FHMpCRBcpGE8GuHKss966jHGaQqMsTvrbD0lQkBJWOwscP2qnPN18tbOfLXMV2evvhb26mW1rZ+zZA+va+cLsNu1re/TaMRGIxuQ
# DATA bMdmuRQFcxSyLRrXty3281LoXdyErPVqvb52aeu1mk5XlbfOF/21OSYWhbJ9IpBFuc7lotZs/pySSSNATV4KotfVvLdFN4hmSSJW
# DATA E4UzmCifQ0RI5F4yDG6MGRWCI1c3mFFkdcVa+JlsuIRsHjLqHtIbNDHkchXnB1qIxag6GXf466V4UsgZZww5Y6jUpzpvnvPmFfvO
# DATA jVbUcxY0ZB4wwMXJZCI6+2Vgt2onYZZL+NW894XTzVbSOnm+gpbfPE0G0RA0bpGiS9Ivl5H4cp6Fz30/NlBnQ+Nd0AiqmYDTeCGo
# DATA aRlJPdZy4RgsuZEfhcsjGjU/pWFY0wIrHICYJbLco/AO6DDC0QhOMXaV5C5PM05/MMN4vxB+7VLRIqJpPxpCBG0Y9VMakYWKzEMo
# DATA iwBih9JWlLWM/rk8o+CAQ6oK8IOypqAyDTJtXUA5Dv6aVJylSnyabIDhJOqHac37EPYTokmVlDI3VCCwYYgOBkiE/kSE18YsjLdO
# DATA yJA/ZpZqobhkM1Cvv6SCj0fQeZtGWPuLB1th5GNWtebKM1vAg8NeZJPkzwHlSEYj74iGLJ1E2SfpTZaUqYMQio1cj4FXD0/CU3FM
# DATA 6XiqMsy0W4ezj8cBCkbFnPIlEwVu+JdYhftQyRpCCjPlkwWq4prqXABrLFB/mDfi9SkC0Uavs0o1jzQytkAmnPnguVA1BKdMyyIz
# DATA JqHExyCTsPxTPKGfK9oPxQnIYTuDME1PWbnxPuVZyH47FZAQ5gUepzk+xyFL8uWZ9HEUc6rET6zUL+GSO0qSoeVul7cm1NBoNBxJ
# DATA WysW4dVg32jLp6z6SH3Mdy8N+0bcrhv2LXZ5LA1c6RfGM4Djo+ENQL/fBvNeyYWqrSM3wPj+vKRCeiNvYrj3h2ga0sfQuCbbcjIh
# DATA 5lzv2/gU0OeGkogVonkYp95DeIvD1dTdJFH81ZjqWHCZJEyHR/Ct23iZ/6wwMt8w1AV0mK+9s6dn/3T+8/PfrPJk/ivd94ez3wny
# DATA he9i8guoMN+c/Zk+fsUsmacVz/Blnp796ewr4Gqe4qeqfuqpR1+/0kHRbfTCX57/SsFlKB7nf+8xY+Z3YNOAQuOgMi8BpnGmmV0r
# DATA vrh5lAABrUbuhQhMv6Pna+L3OOJt2xjkFDSMtXtZXjgnd5mBj6Knh8LlbLiVMnOfb8nf7Bgzhdmc6RlumzKzWi43x5jhBJq7vgch
# DATA ccrryah83xDazwbohf2+izQ8vU60DLWBjGzsVATMaaYBa4xnYigIB5fZXlTXTpUxndAwJjOeT+yJqUPmK56CyH38yON64X3K2wPE
# DATA bXuE/ZHrNpUL+xAa7VrpG2U2ixasaY69HzSGZysMmW01b7OdstKGnhc/Zlv0HT3GDenPNKRrnMyVRvLXwyd7e6P4DQziO43hOw7h
# DATA Nz2CS10sJzvfNvkcW8xNIGXKCc3JMkZzIo855WYUKsQM3G8sNwBP14yKNJPVWiTD8DNkWAV64jhOGReDwtJYGUp5mOEijowbojBW
# DATA Q2VgvQRE5hTWFvt2JcQj2WaGaQJ97E/E43aURnweQLJdb3VTvnUa/SGFwN8v5JEcYvznLEktm6GIGYlSB4txsBgHi7lBWMwFY8Zu
# DATA SPgLLdtbNc+vxKl+JuPc8WEcH8bxYRwfxvFhHB/G8WEcH8bxYRwfxvFhHB/G8WEcH8bxYRwfxvFhHB/G8WEcH8bxYRwfxvFhHB/G
# DATA 8WEcH8bxYRwf5oXhw7Q7zX6zfkU+zGg0Coajl4gPU15z3okOY2dLo+75rc640WkcB73m9+l7MUf6nU6nOVzNzlbg+d06ZWjnOGi2
# DATA v0/fi89R3ez2FZeFy1LKSgruVDgsQUFXotkrlnGzWYpIP+p1ygEGQeOqAQ7rvaDTXgmwG1xvDBtN/3pj2JSqc30xtAuFyvIa8tAq
# DATA lEsGuKGUrUK5lhjahXItMbQL5VpiaBdKQwK/vpZyyQAvbinXEkO7UK4lhnahXEsMC4XSal5vS7lkgBe3lGuJYaFQriOGhUK5jhi2
# DATA Aqst94ql7DdKIaoLqcr98uDfjholFFe71wyba2Fp66BjrVbDgo5J+KlBgllGig51hZ8WtJ4tgFa3ZwXQ6l0+gEISeu1nTMJuAVyG
# DATA ZyY2muaZibln8czCZrvZiIo8sxH/z+aZ0ddeNCrwzKLuMOwPc55Zp99ut9qGZzZsD/ywm/PMuoNmGNw4z0x5PdSGBjMTEmc82ZLs
# DATA oLC8F3qR2szPurxSuWbRvxhymWP2vYiM2DisSExKe1HWBGc7InmRpxi6Wve9OBpm+rJ+l5y+nSbHR9FuS0WtXRanrVDLq862z0TX
# DATA kaLbOZCJ/Mrqod+wFonVvX5Q9MLo6sp7LMfhMDnhhRisuNU9XeesvO2xw4JnxWY2t2E/nZ7Eqtyub2ag2Xl6gUfDyq1SneTJcuBA
# DATA aA6E5kBoDoTmQGgOhOZAaA6E5kBoDoTmQGgOhPZ6g9Aeq9odU8HdVSgzfKZEVzhJ6iKO7iEj5HZR3bxLHRvVmT1Urfhu/TB+i584
# DATA jN98c/8xLvJth/Fo7ySekXVFdtjpfJF8F0b8p4BiTH/E4ew/1i1ofpdBawwC2WsGvWav3Ql67Tscpf3v8B8Vhf5d2IA/pNl7I5CO
# DATA 198/HCaP5R3lV+z19w+fsGzmXv/H9Z/cu0vv2j8UyTdc+DYH/aZ/+CQiY11pwVlxEf4bB7in4rFPdyv10fmSRj3V7T2R6KFy3FU/
# DATA /zSJZ3vcW1EOgg+HxvCm+lEWaPf2wkqfiiN8s18h6zG35FVqJ/HdjdbsJEbBTGK7Qt6V5kHlRm+StNHMEa9lG19mBDhAjnY/x1aC
# DATA 2XBvEu8fSh4Vf+dVaZq4q674nl/fL96AIVjF5x3cW5PT01TZnmhknTn66ZRVnLLKqrKKOQzs1FWcusol1VU2imLfgOrKp5Dj0gog
# DATA k4T1PlizywivPF8hr9ug07EpQFfFE+QlI07MBVg69VDeI6nvBTXZFSKdbwHp2jaOzt8Co2PzBVUfHzD/QFGUYHTqnhxGpx9aYcS1
# DATA JahHYiJtZsnxmPQevOsX3emLGjBZoBfdyAq7n51EE+pEL7g3qKt7Z2QCl+7dHV3H1RutnEv0paXW/a1mNMh4lJH1EA2N1J6R1yEj
# DATA y8jiiPleltphktxusj0sYuNlyTIFy3ckOBXob4vVCA2HnE8nXgsyEmdKxoeSeOqpQ/dGLIbeuaIWM27cs/V/KE0NKpiJLhS2yOzc
# DATA tDbqqhKY7ESbexUUQ/KxxBmdzuhcNTpz68JZnc7qzC60J5+b1t8DRg1xJNnFDeQoqr8xOg2QbBoP0sSSwFuyhar070JqXbMB6Bar
# DATA 2ndmUMxblBoMNaSEpeQGyXQapYNYj4FsuaYRVlqwcWFn7T9O2fzeA/FW9U/hM4uwywTDqAEoCfuXBlPspVijv6XOu62aqMo9i5rI
# DATA n5RxqmwO/WNuAJkrfPAZ6LSIw1Hxk+UGERzUkV9rexqfLzhB6nPR8rTuMB2l/dSKYQenKdoCWFNyX7zNDtTG+btswG26a5CAuEHN
# DATA 5Zhvfif/uvkZrkS4+xN82GJdysCsLTxxodomCQaJLeZdoYSx50MatDramSMdqFMy7A72WMvqjspLOy9KOCDeDWPauTiDuTalS749
# DATA +Oef/99tk4pytFXOKlNMSVVSBUkXp2KMkX3HIxOYPNqS5EGIpn1V2F1Dni9694dDSOPR08ICGqCxUe3niSLzk8FewYNs/snoyEQU
# DATA TUyGbUpvqXlvh7OcCjgbyqRUfnofRBi8pFGnQdZQgvSxkyvla6n2XCF7m5uzt1AXJZdhL4sNTwlZhBOdz/eZJ0ODxLwiuaYn1pxr
# DATA ITYBLOJpZEPZ5pMlz55pfrkUi54JSMqj792Pp8irEVlr2RiwKja9cckP8HWeZGyi17z3AF/Ea4ZxNlhmKCAOSRYlryOXTXu7bP5u
# DATA zlvVcnWuosenrneBDzpP38XentBr/O9/bICVNKQ8weLBDDzzE+CDqG4tKe+oLGSKn3k+FWgPTgtZfxlENAepeZ9Ql01T7/tSsaX6
# DATA ggDFnCQ+r+jBvXHovW3fgTOE4i7hmbTa5FXzvk9fI67IVP7XVpGvnMXbe4hCNn9OAy1NMiiIVOexMWdH1PCroueUs8CgHUj1C5Vp
# DATA LnkoKz6Z9AVyNyop/DShQo9jQigPfgztUpwMzFi3NDSBhDMNparIy+g3LKFI3DjTj2KRPAWP7DhOqIWoh0PpeV6MzqN9qc7jXy9j
# DATA XvnUg7cuBMlgqr80xqFicwVkG0gbRjIdQrZ72SSeU35y4+C+BaAznt70Wd9UewShoIpRXZRYuWvyjqKFFB1nIRYSs2Qa4cLRMuKO
# DATA A0/HM5moUL+0uJbu4+YHv3d4XAITKTZV23SL4tZYnCTSIUvWojfOBKEpQslRnNLodoJQdD1mGdvYKPzSdB1NP1Utn2xBVnXGO6lr
# DATA wmlF6q2P1eSOwsYT0wQLuTx3QE/B2AnpXmCzljO3aK7IsrFtrpgrkln3qIGpBV4tJCzjt5iKlvlKzW3MDU8KpXYR6+lVcLnksy3n
# DATA cnEulzUEBedlefW9LBsdKC8UUaFwVGB1pJzYrAVvEi9wxJmVUBiJCYqlGk3YBZM/yOdJOGOfN4LhRdYqv4ifZB38kFVJPvpy7y3q
# DATA SMvtTR99Lxyv68pZPutcvlwIJ9IdlnESK0fSpf0OEtQOedvpbKCjolQec7+bLWbP5bEGzGE9x184PWolZhzce8A2uakigCCHs1Oz
# DATA avX95AQ45FNVd77r8YUlvFNkVX3Xe4fuj6gzhTEEIyS3hL+LSVg85Qo3y05k9rDARjuPl45Zfz9WRFfNpgKMNiTbDHxcaJeR4dVP
# DATA HkUrvKhibXk/ZmAmOyApO5aDBSVSiv11WHKyOZcJ87htyuV/Yizlfwdy8vy3HoiUZ78/++PZV6uEy9Kdf82Bl7i/4p3/gq49pf9+
# DATA c/ZH7/zX5788+xpP4N6nuP1PgsCk2785+/35vwO80qMPP6fb/iy3Oo7lS2CyeRn7/VN1ANH09Ug0T865J6h5slvey5YyYZUN+cyt
# DATA lQe5AWPM4MGEPQIzmUaNMGHlBgc/GZYWxrx5fgvF8m2RARNUhkNYFk04afS3DbAsFcnN0SthBxxb3b2qeExBl5/KT6gqaJ74VFVJ
# DATA VMEZPGLXCrTk3RLjMGN/DdA/ylGuLBgHtdy1BK8db3kfdumR2CqGHV3hbnMIB5sGBJk+Swztd+PRKB5gQz62LcuOm0gzwPWts4jC
# DATA oJ9TcfevEC13qoObzZJi63peXMudEuEAl26sf4axXuMtLz/EvyYemlsa3q97dN9pcL/02H5rQ7tUy0I25JjL59ZubgJyWUgjpuRh
# DATA MWHYVioJQLDT+UKGwnmKrgecunHYj3nhb5HpUqMnjo6wwPKQqkEm83iqx2qZG9NtGZnNCDyJqUJi+UsIfxkU/9JdEZfIRsMExLSB
# DATA 4j+hrh5n2LAGotCOOva87XUFK6lqUrVgLMiCEMeSJVIQCvIQGYCVz6w6j9IqW3VUAssp97KHlpmAGxHlKhlsG80Gx8B0DEzHwLwR
# DATA BubOA8xOM5lL2MO3Z9pfxbK/JsPewTEdHNPBMR0c08ExHRzTwTEdHNPBMR0c08ExHRzTwTEdHNPBMR0c08ExHRzTwTEdHNPBMR0c
# DATA 08ExHRzTwTEdHNPBMR0c84WBYwbtRsTMrSvCMXtR7yWCYxZWnnciY1qoN7+VUxYbRapYp5ThDfldcryILGt22/XOmgwHdrMdjJvN
# DATA abXZ9PzuWFBnFnisTCPLwWONFehb3YprCam2Etd6e1Nc+/12txWuxDUIKK7d9nXFtWfFtdPdGlcFs1sb12a/y78W49rw615A9fd6
# DATA 4troXksd6Ay67dBfiWuzfp11oNm5ljow7ITD9mp9bfausw602tdSBzrtbr/TX4lrq/vsdcAKjkJrtjvjdqN+7Le/3y3hcalDHbSu
# DATA BrGjvlRD7KRbtiB2zTZ1G90dIHbDUasIsWtGzWE9h9i1Ou1Wp2UgdoPuIOoPcohdo9fqdoIbh9hhD1VVVjf06Nq0+HUWra7LNmd+
# DATA /+W4dGWnayNfam2L05VD5nMqu/lS29t8qXpOmAe6uiqjfM16moGJgppy9VordDj41LDgJP9p8O+GCxfPqE55XSHDSWVoFul0qtas
# DATA o+xdjRgnKwZqEXdtERjXXtlfsBE2Z5XAFtt0tcY4vpzjyzm+nOPLOb6c48s5vpzjyzm+nOPLOb6c48s5vpzhy7F6o0LJsc+TEv0d
# DATA +cqH9+jrHf2rgObY2PzijffU8b+hOQmJw3pMMmMm2yCKJ3scOpPVRD8zq31B/5vdX+A2CVb9oABs6hvDYXS4Q5pwe3yCZ03gd8qh
# DATA cDDWoxmPCAZ35nQQ3UH7zQft3QH7V/iA/WXVD1+Yg/e5Y2u7GiKLvPFp1hmNUGRZQGB5TN+3aSE+33P6L9mJ1YvUd3JH5U1oI5ZU
# DATA CK5ZGLGs43CBKuJ9BehhMQTKVWpDGQdmpIU+WcIbwzsYvKMloGD9iNlgoaX6Dd0DmqxjnPbep6sJRO61+qHIRDGiQakrUL1NtICz
# DATA nCjnqq7EG5D9fKYc59D7UiHwNOpc9Ggu0wqlMl1WPdyqpFRqcvBe2/ALVt1+kNBIN1an1WXzqxbf/jiE3KKR6U+jkzDFgXolKHoS
# DATA TuRofqgqqDdBQpiTwA70OExFmEIiXzwPvQhZJPUHywWSZA5BlzXKV+Ooc9lQG2ZSEkyx4Q4CmzA8fBlGoZFSDzNWaVDCWiHjafi0
# DATA erzYEr0PQL25ROTQi5iIWUIauiJBADOjwg9TBTBIJpniMRqaDgeTPvRO0AtxfHHafkskP5HXrMnE1+jEuh2Ks5GdjVy2kUu1yslS
# DATA OVmqq1jHG63xG5Or+l7MbYCNhFAJPWkFG8qxh5Z21S1rIt4GHFicOwzBgfWYRsg5qFRuxwPrx0zvZC7khNtm/SJEcKMuhuwOlGDx
# DATA OgHZaxxMfIldQnj5BRHWz5sImwt5hFvrIyxxVFH2y1Gub44zu8bsqouqtccvviOeqf0Ls7lIYdbf8zgHa+PcumqUtcOMbvhovc/t
# DATA ghjnAZhIW5esvF4bbSvWqvroSLcKcd4IRH57GU+G1oiG3uLl5SJ/JMOwjO7hnI/e8AK2nksZcDL3XnxKRKlDSfLH9FAEHtd9bxSd
# DATA sEubHccL41GFDtYaIfmjlIXqzPg/i44188pIgP1Q9eu6KwRwLQQWHftn2SCvef8nWQpDnvdQz2h1s2T2D7EzSFTXNCNTXNnSkXJj
# DATA oRTJm9n0wJSOphnCgYsXm6Zsr7ARbo+uzgh3RviKo3rF2nJ2uLPDt5nVL45srBrsdDNgHxjagq0CD9wOjVWmFR7nQ52SKK3kKqY8
# DATA 1BiBU+h1Ym8VRh0EPhfJTgyvyomINjcSIEq2jAUzI4dBNmmuXpmenL+UGzYk8PuoFHoWQaPz0PGTd+Enz9iHiifEm7r5TnEnyxQC
# DATA n7aQk7Vb0XL+gWL74hOU89y4JEbys80ISZ2vApG8X/Dcw6VNVQZQ2jRCMZWAqWl0RDlm/LPshxUkFv1nhLmzUp+lGpnxjXTbbBHT
# DATA hFlWIHiuXPPeCdP0FKKsyazoHk9DZjay1bpIT5WXmEVZsQcylYjBZ57MtJ9cTR7sRpqv/ugmkq8umT2QMspvSb7JX62iSBd4sy83
# DATA zBCMUzMTeSZWaF6VL1nM720uZt0oVDEbp3++JCN7LbjH0AX9IbpYGDmhMFlTstj1KkdmIetFC0CUonnpRQLPJsnJ5FQkoVNWNkbn
# DATA irHILPVQmfMGPnSQY9MrPlMRbk/arRVioZe5ZDl+ugVmnPdXusUKekRJJKcRWKw05MyGSgycS1KTwPJ2OoxDmgVO2UAdRYtTGk+X
# DATA yONYOa9C3ZIVbsxM5nnRhUbXnI+WmSUcGnwfYUbKPjf2gGGBMBbg2jO3zW0JvbVyvXIf/GDnPpgq7IJuEbpu5M2YvZ09PF3pfzXb
# DATA RooVVo0ITbORMY6mcTZn7WvvQ+4xQ/YSTML0CLLSUGacZZpTf5Kk0r9KW5HOdRQCkQy3wLW0y/WpevG71e/v3K2qsYvsK8jrI6mh
# DATA GqiGoSZYmyYp697oLhNtLIodCm8Ln46DOA6KUvGt46MZXD0yEdUWJhwrLA0OozOdp6xXT72uFDPH4zra3g4Jeym61ncv1bVqWXcY
# DATA JsM0PEED4d0Jk3hkLVQr55q+Q1kPUYhtoZQ5kL0Xe8e2ZzCj4cLSJs9guah57PIza9lqe8AgDefIcz4SqvdTaA/Zs5Xr1hReqURv
# DATA F+D9TB7aV9+nmCMwBxGN9vEgKyIwvz7/+dlXZ38+e3r+a/r8C/Asga38M/35BTiW5z/XF9dhMb85+xP9/+uzP57/A+Muz/8NQzH/
# DATA LEhMDvr3dOXXzM/8I5MzvfNfnf89AJrnv2I6JoV99qfzf09B/Ir+/pbeSSHgpl/QD3+gn+mef6KXPD37y/lvHCbzpXCUYlsauivV
# DATA Laqax0FnB+KL4iGsT9ODCn8/wmZ3eFEHQNYpUMtxyJ6r0EwRjM819OCFG4xr3nuP5hOYL9SZorAQa2XQ5OrAW/mZ70xo/JKWiPg5
# DATA gqbtQ9V9xm0TNFcK5eYYmlwpzV3YWshr6soDuELcpKodJ+b2B/zVg2jXcgKRsOsEaMaZRAXeQ9nZGOHMbwh+0Gm0cPTMXcruBsiZ
# DATA vErKq+XxFFNdhGYqgOqeFhEfURugHvOxfu+jKMyWavmWcmwJKBTTFVBy1Fca33PGnCFvEU8i5bJO2V9OBtJwOVnFae5WJTdbOuW2
# DATA 9ryImrulwyE1nV1wE3aBZm1exRx4LZZTb80UuH5LYCdD4FJ2wO2ZAVIvS7lg4zZftDZ1ExzOUvI50XBTM7vQRKYM39QKxXnmHMOJ
# DATA MVE8TvsgDecWLz0b5b8cwKffhswQX47GV2YPo8UAfu9dcZz5iG9ZDBS5LB/+p2InDLEvD6pRUKih+HoSIp+sKdgDvPBNcUuGVeXH
# DATA RzvPMt5H5vEeLrFFtFORRiUkV/xRitbJGyXYbRWaZTSH3nToTYfevBH05k5jzU5ToMsYzbc5BbjKDOC6JgAOvenQmw696dCbDr3p
# DATA 0JsOvenQmw696dCbDr3p0JsOvenQmw696dCbDr3p0JsOvenQmw696dCbDr3p0JsOvenQmw696dCbLwx6s9FqDtvBVdGb7VFn1H2J
# DATA 0Julxeed4JsUekzDojcQmbEe5+XgVOiGvTxjg6boUPEvQbvIL+wNR1F3NZfBBAwaYz9ofVntei3fC3zPr/f4T6NV7TY9so+rvUa1
# DATA Ve30qn7Q9oJetRN4foe+NIqF0e52W71I3lGMc9AM8jjT+/I4t4M8ykIWtSpGq9GOVlGWnZ7ntzrjbndS9esUvc6XPYpsu1EN6Id2
# DATA t+r73Wqn2mpV/WavVFv8aBD5JeZhvx2OwmAd87C5LilNif1AxbhjQRibVlKKdXzYHQz6a4iMftdrBN0vu+1qk1LS6Hl1SlPX84P6
# DATA l1Uqi0aTUuh7JbRiGHWa7bVxa3U7edwoYCube1bNqBdpkX5z0GxfgdTITU+TGqUVW6RGisugtwupsXAFpMYg6kZDi9QYtoedYU5q
# DATA 7AyDYWiRGv3WoNu4cVIj9rZXt5k0NOBaPi6xjc1D2pKxoYRI5cgvzYib3W97+JdMDY/NjTwIPd5aS4zyK5uTO3r9Ayt+a+cSHCIE
# DATA hW2ffx138xxEm6aHlgFecIWqcr8cWFHcXzkUspQnLcoT+rch/xZWq5otg43stL69lvAoxiKlWeZ8+XKptYC1HuG4EdV4YWXQ9uT6
# DATA WiCZEtjFt3M4paLhWWxpMuQ4kI4D6TiQjgPpOJCOA+k4kI4D6TiQjgPpOJCOA+k4kKMQjfuuXxWeomw6BvyRrBmNfHygz7ufRMqf
# DATA ybjHPYWLxAU8IUGhqr6PjX57PiMZB1NhPxYCUXNVKxS5cnEwIiIL8WR1nF6O2nvzOBpE+jQizsjBf9hHeRQ5kPnJG3c63J0O3/l0
# DATA ePmIljso7g6Kb9fdfmEOkD+IH0kTqtD4NDvFkn8shyxt8I058miJpqLJTORQJ559uHrqGUdBuedVZ6dHCEVOZmbhJLqkfLZRtRTX
# DATA IzdxujmZwjVqn/N2ytm7KGfzjhKuiviw+T70l7jtR/R3i2Y2DYoLwR9+Ih9fBr1skweXFIl8e7NIpMpNEYh8G6c4RzjWjUEp14PE
# DATA ZhmPLHeqKjgPjtP54LLSlOcUAp6TeCQnmJMFUyAyHprggkIw3iiiejSBQUQTlkQOHnNKNBHlWbQzr5ol7+yYJe9pTVAak3WGvB1O
# DATA oCvAWr0cXWpMfMGcuZYlHJYV9UbwLtPTyCleIOF5HZhzNDTjDzVBsv5iOZmPwGbXkTG6HVwyX360OV+kRamashyyZZLXkVmY0pzU
# DATA m9Gc1kM/w2BQSLdiQQIyAzn8BxYNV6loJoQyCBJkzBGhz3P098en2rh5jnXkX+1YRz5Jlqxh8dPlUZ4fWm16rtWnk+kIm0aAaaBO
# DATA YI7pFRoE04wUxmhIpgYNZgPKuMk4WeLEW837DBMC1lZgpQSx644m4c+MUMczqs/mXeEl8+eTLdqzulOVHKL5tTfXlySHPkmTY9QB
# DATA SjPNbo4ig47lTXJUacLlACoc92fecobk6h4GAsEMRAWWaQLlfUhF8+Lyc2w3n+7YbrhSK+UWC1nLigzTZAn18SWUKiZiPKR8Rhb+
# DATA flCxhkPds0BpOZaulM0yW4g3lOpC/XU5P25XyvZ1UWjIzWw3CXeT8J0n4W7G/YrPuDdOpl9oyTbex2J2tAiVlXe13HuLGnS5hPX+
# DATA SyTXbKvrylZKa3OoXAgn/K0sf7ayL1IqzCDBziF52elsoGOiThrf+8HKtko9yV9Vl7Me4y+cmsL4PimQvQCfYNYLK44NqXrSBF77
# DATA F/KH+Og0DzcvqG7dyyTntKOwrWe2VEn1LRgOZgPVFkPtn//xP2ozgl85DkTKTixIbxFNJjx1UaAJUfT6HuzPzDsSKytcMC1iCBU2
# DATA mrGMl9O+Lq7QS8eni/FUWbNssPLc4CiWn8XyYzEyTJshamZpfnm85xEiXUoauUK5lUa54JxRA9Qr0IIZytEVJ2G6oqlbLFCGGhnD
# DATA kYlVr6GslhWMs9qc1baz1bZS39zaiVs7uYLFttE4vEnxXQY0jZSOPou5I695Ib6gwfv8BeG3GQI45+fZay0rSydiK7JtOSxcK6xp
# DATA yFI/XX6f+l8++81XvL3B9CLQvX7UdGfmgllhkAMiZWS8XwTd28j4es3fvP6iNhTYkZVLu8TWPGyim18x8e1dZ3TVxgv6/SOt/7tI
# DATA FoUqsffti6JtAjHRzq9ckM11K96NrdFW5qtZMJNdqbzKJVU+4i0epilkFiIKNezeW3ImWMVZbU+2nWr5Jel/YkFVzWnsVkbsHQni
# DATA GeFPYlsxSivvAmxV6h9mZn8JGp8xbj8SZ6pRambk8Mk4nkR5PxFDrXaBvTopS96alQ5qzVEu3szywGqFEyaubFyRrW9k6paqgN5p
# DATA 5Q0Vqs/0Blo7GF2q1fdQqpZTuh/bg/NwWE96EM6gHTynBMQ4pximc17oZc8xUORwV56MIzHg844LKYPQNPdrvLBFRkfNUzA7pNAI
# DATA TWfLOXU9Sj+4KC59h/P9dbGeLQgXz9F5DmFzuP6RGVxfn/9SeFcgZ31z9k8KzQU4F1hcX60SuP4r3fYUgC5Ba539Dysc+sSArT/R
# DATA PRqy9Zfz35z9T0PpOvuKbnzK7/r9+b9jQhdOOnhnvzv7+ux/UKUJJw649VLY/2zcW1s3gApME+Bdp+gnuL4ZO4ZJrRnkyalLYvU+
# DATA 6hlnovp9wrrhsnShZbcriht6hMY+Dvvop2S2LmrYXGcgdt6PMEPYBtv6nO4yEXKorYLpn/cMt03bKpXKzbG2hPZt+E+8Jdt6q3Xn
# DATA TzMqbn1jsYJdJ2IrFLCVhiuoBUJJjMNrXVBc147W+iQkoxM/U6xb9Uq9XudRgzKAuqia9wkNIMbqYYIFT7rG4RxrwXrn/yLsHyKS
# DATA gqPODIQCxRU9ooEAZwvKDK0Lq9tmM6XYeJ4XPOvCBDhulhver3t418ysy4/qr4cz7xZH9Ose0Hcaz3cezm9lNJfaWEi67aN7kdrQ
# DATA TTCyCglnxE+mmO12MmnSHWZq0WyIRbM+LPMQO4krlNAYSB9qNDElYRKDJTUb6teOwngCf+UgBKuI2ULFZGG0DU1GT2mA0wvM8Syb
# DATA I0lwkVIL2ZWWlYfMmgGZvI/iz5Qm3oo+pjoH9wpd5DPlfNqc/RszrPDxHHbJhKh5KA7YZMjILDELMnNWnFL04JSMt0fwlMXDUJ1k
# DATA j8QwjDLsQ4yzMdYxQ3g1BsJdQbriETYgDsbRNPR45ztTuOY8FjmUlkNpOZTWDaK0LhyDdprq7Gg+394s4CqTgGuYAzh0lkNnOXSW
# DATA Q2c5dJZDZzl0lkNnOXSWQ2c5dJZDZzl0lkNnOXSWQ2c5dJZDZzl0lkNnOXSWQ2c5dJZDZzl0lkNnOXSWQ2e9MOisoNmst66MzmqO
# DATA OqPOS4TOKqw67wTO4ozluPQ44wTNVPcLchRtv1vM8EavtznH641ecxXk1AsYSaWCsuBSnXq31+uvg0s1JJBBnLIElXpZ22JLNTie
# DATA fGCuW6RJDXuNTnvd863WTs/3+r12f93z3eYuz3ejfif0y5kwDZoNLwjaVarYrR5X72Da8FtVP/A9vlaVa1Xfb1T9Zqfa6Xh+17eD
# DATA 5g2jJTxXd9gd9tblIOPCSjW/0/OaDZ8qPF7t1ce9eik4k3crwfWugMDiJqQRWNIaLQRWo93ud4KrILDqUS8KLQRWQAF1cgRWMKwP
# DATA mzkCK+i2/Xbv5hFYNBOq0u87TdqDgMbKot+qMNLIiKdD9PiAnOE+aRtOGZ86wTqAVLtW1gXiLSePSy4TawxYuTssmf3GFO8qUzx/
# DATA QI/a5Xngujmf9hJ22Usoq4PwE65ZbGsXE1FcCJA5omdPfJQhlz9hhsE1K3ZlDNdaj4+uqEUPwyZol3Eeq+jAb2xNv/j7BflUfFEb
# DATA yWG/YmHryebnzTh9wWs2TOE2Y71MBd8Jx7Wt8m6e1pcq87o6uZxcOLnkKDjOl+N8Oc6X43w5zpfjfDnOl+N8Oc6X43w5zpfjfL1m
# DATA nC/UBXVCPhoe2tSvBZZMOSOQurtS15NlOohQQbhWHcYjNjJVw7zXqsPgWYwBK3gvTRPE8V1leaF5kclDfXR6JH2yee3dkjFtzQnY
# DATA hK1gclER+he2NXI57AtzzARC36mr+OINtmvEPPfez4/+kx19mq3pC/YPn7CN/jiPDbZajuIZZYeimrGMqNJ9OLaCfwedDzVXuFQr
# DATA OMc4DeUMFZc63trHHmWaX/KLrPgpQV3qanAS6uPE2KfeCc4sKuuTfuMIUrXm3Mepnar+kX757ja7g8uQyidP1908ZfuPC5ERMSoT
# DATA By3SqN6E04CIh1j9h0+MMf/FGybwGuJGbzUX3qS+ChQ2ukatPT8GeUdu1LnBZ4/K6VXJNZVta3vhdK4rvN2CockcXk8Bsb0sebYn
# DATA NvRgkU5oyvd3fydfsRmQvu7/zd/Id3qU8vSLN95jxMMb+483WN7K6KauMFs8YIt9TwrVSdw7NYUrqSk4FYVXW0Xhsur2z1VdwThg
# DATA JUUi1mcpuS9CVLd7H2sZbk4pH2RdQtoy3pyQd/XZ/Vx5QGKJh7Y9+IDbLW/zwqLQxqcK2SHGgtX28qfuIKZah5CPxm4UuDckJiWF
# DATA QK16u7j9Cyc28RIcrub/XjM5oSiKcd3chLLWyFpqwmVVsj5PY2W6xTNmNZLtBmPGqGQZHRBWLstgAZ9AyGy6FA2HU/ZTV4yAvlRG
# DATA VXm4omCUzETR3tL0gMZByBZ9MlowXCmN2I3OBC4F3GJD3+OFQdYbn0WP2MerlDUu5Bi9GufkTQjOuHPG3U7GXUkpx2lmOc2sS1h1
# DATA G03Hm9LS+kAEm6hiq7m8ciJwNc/JPret2HgbIvfKs6AzVyf9Lb0TQyuO69ugmi6eMlxmZ1lBYJ0ycjJhjzYDELBWzKPb38DFdIg+
# DATA TT4dqAvKopZvFfnDbnF124/9SlBp/IQGRR2jDZLyyqlG7/qAP3GVLSKIzS2mb80fWiEAB4xsOEk83kqyBTzcFMMb3MPSnSug4I1i
# DATA 8saHlVedl1dHHlMekZdSNtI6ibOlETibS6upKAmzfxUehw+ki1VqZiCsaDcomonKB9Z7O5kVtdBENSsEpMV2ySl9LBowIXomiKTJ
# DATA qXKEmuYOhSsR4KKnT3C6i4dO1pyy3H81zxQXRkSykZeDxVJRmCbxFBd5oxEEqyASx7QLaHdlOiqlipBPRWwzOZ9aSGkVXaeYW+oV
# DATA fuM6VHM+U3Mulp1/NSzUfJhxJqozUXcyUW1bxBmozkDdang+b7HXjwuNZIaBbhFPcyjTA1kmZQHUikUBlNR572kZRAgs4vgOZxf9
# DATA jqYyTHishi4nq4WGRxQvbDmbnRo9yB0VXDm6JjZCgqJaAEFHMQiosVK7j1jfEp3HGm+dOnG8xlKVPQqoYPxJ0YGUJaN/zI0rc4Wl
# DATA J4CcjzgcFTvZc2O6pc2sIrPxgaE/8rloV1p3mC7RfmrFZMTOAYyO6BjlvnibhYkWqX3Jm++ydGwF42i+bgk5yuIjTvu7/GmL7Vpk
# DATA g8tOAttgUTTzTWZjoYyxu1oa6xUA7Do3Lglgf/xkM4FdMlYI7JjERZqRrpz2p5rE/hm2jFLK02Um2724Bs5YO1UJ6WIOBDKnXoGO
# DATA sQkjxAYKr78kQ1cppsaDmvduzAKrSxba9aZxxrNH2euC7UpMEeVNIHKNWyuvDAuJAQgiel2q+GzPjLYv1aBLZvA//8OfNudwoTZK
# DATA RrOkaxqJ8C/8qvEgXhjkPf+S05dY+5aMatFSTeb61P2CalvKOr44vLqIxT6/P+JD4TQ3mPbjoyW4j8r1W9HdnaCihP4YkrHPEr7x
# DATA kH+TCft15OgV6+o0262ufhxOpSpAyjrPOqktmOJAwVb2+YqqLXSqJ9ECSCzZ3WSe9hjjgd6LQR+nQMsKrWsGZUA0CLL+KDrUe1JR
# DATA qA0KpoE8/+r3ry9V+YR1xrGnVHy5jJaRzr8PMYPDpI0m0LkS80kYszOHL6jj5hEA0O9Kg+Q1Cak4WV5ROWBk/QhHCzg/KQNncCFx
# DATA QAt5CpjeCBRFGipRaNdS9UzXfsmM/GBL3VODhORheYXSW6ThMY2bJ5QGnZmfqqMEYyWQHUq1TMmGiYaZMgqol5stGByHsGCXyPyE
# DATA GvLM9AyqV51Sr5HxXDKGxKO1rJrD5RaxknOPaP6rVbhh+z3XfP1s13z9jAl81nIVzjfmrVsth6XREfaDywERSkimhgyMNrl6vZE8
# DATA z9hXkVuG0WjEOWz3A2E/Y/FqmqGxe0fuUdUZvalYfTE625/KbtZShhaNBNmzaBsJ5opkD9m1enehntixs0Xt+qOOaDBOoJ8Vwl9K
# DATA JakL4rVYeLMxelQSkU3Q+09n35z/m7Ovz/7n2V/Ofwvu3fkvgMSj/35z9rvz3wga7/dnX53//Owp/p795ezp+W9XiXp2OMzK+wXT
# DATA +PDsN+e/xlNnf6SLzNsT9B79/bNHt3x9/g/03F/PfwmcHmLQT6OTqkHv/fH8V/T3t/iZiXt/dmi9l8FbIzXN5s3LlPNhjFY6k23B
# DATA IDb80PhmRPke5hhZDEMo/bClIOsb+P2h3k6SRoN4rmyubIn+iFv7NGGx/q0kvXckXlYDcjA920uD3Lltjt5qmdwcSk+qTr6S+KlU
# DATA JZE8Kd+Mnshac4xOboSWzTuq5+rQBWWFTBjxtmk0Wzqe3g5ldu1IPTHruS/nrgdeZvGb9cmA0L2b2PPcjX2Wd0tUXZMTBfXRhHPW
# DATA WRP0Lx86QKHF0ynO6AAmRIVtYMSXqn9bMMDlRvW8EHsXJ8Ix9tw4/4zjvEbqXWl4f00WYG5laL+BkX2ngf0y4/rtDOtSJcs5YKH1
# DATA nmfTuQmSXjmpelFEXKohy02WRsTMHhIR/5UxsSJQLFmclTVWUbI4jhbJnJ+JMj7QnpC5tBgnw2wXTN6nyENZxirHiLIXHgLeuEvJ
# DATA n8bYYJKQVYY9WzLQ59WF3hlmyxRgsJAFRimT2Z9f0W77NEL74RSdcsmIDo6QAOFYYVKdrgxZOBHc1wDOas0zczQ8R8NzNLwbpOHt
# DATA MnrsNFfZ1di9Vbv9Kmb7dVjtjornqHiOiueoeI6K56h4jornqHiOiueoeI6K56h4jornqHiOiueoeI6K56h4jornqHiOiueoeI6K
# DATA 56h4jornqHiOiueoeC8MFa/VDvqNzlWpeKNRLxq+RFS88srzTmC8AvWt0bOocY16w1Df/E6nyI0bDbo9lTcUwZhGVhNEIw+i2azn
# DATA ZRMIbU8OTwW9QnidZjBoDFYKKmj5XhAE46BTP/abzS+rba/nV/1Gy+sF9Kde7eJLtResKblVNF8roNBa9XGz/WWn43X8apPqgd+8
# DATA gDpnAlvBxAWdtRnQtch9FHmrcjZaeQY0Cu/9VnMQtBv1lSg32nXPb/lfVimtTaot1Y4/bTUp7l9Wg56+cuUE+MEVQHfcKjToThqY
# DATA BbrrNBuNZnMH0N1w1C6C7sJhb9DMQXeddqvXbhnQ3bAzqPct0F3Hb/jNzi2A7tCkqtvtDY+HF+vWMh/uexH1AnFYkYBLi3krqLgG
# DATA L5jly2XFoJXdsuKk0jm04ogs+fvtsNZ54C81qHrse6uz4aSeUUtga5Nu3KqrkTRmeREhp8IWdN36rQJlot0qZm1tzpiBT69+1bfR
# DATA 4HaoBTdliji0m0O7ObSbQ7s5tJtDuzm0m0O7ObSbQ7s5tJtDu71maDcb5ibJ5gNbdwWkNsQptzf2vyPfeMmRsVwKeZYswoncjxb1
# DATA 5kfhYlzjmeQeX9x/k3IAx1HpPcqJNofGzHLOt+8V3nFHvtGPGfcii+R9bMfb8+1QPpfDZFYg5XeWguFnV46caYKYTAHNkQ53iNod
# DATA ol53iLp0zMcdp3bHqS97nHqL8O1NHbOWVsB2MPTaZZXVHLN+jkIet0FdGKrj2apm4Ku3d7SvJG11s5uxAyMXgFdP5X2T+p4zC4os
# DATA hmnMAnQthW1g378sOmGLBa9F1fzNwrcynkKK2QxrKAYcqpb8vyC6+nkTX3PBRNhvr4tw14pwsHt8eVAFpY3jwdGkKxdEUj2U6/aq
# DATA 7wUOxEoMfSuGXTuCxeht5D28o1pUZESDXl7cwzts5fEwxgAvTE70geQPRlDZRB/Cx/AzHujQ9jIyS+YV9mlSK53A6z859aCkiUoW
# DATA g5cnRpF464XOJbWOz41TM1QhDikIChBmzlgHOEhg9KiQ9HFw5k9wTY6yBdbdeUrFEkxTtogtEQCcBmcFRl5GHeIkmSdrN4e2GABM
# DATA NvR+WTKNdEf0Ic1ejjFDGjMAg9v3ALuDVYIQ7byvuRjQ8OocLHaQWGfJbrdknd36itutl4XCPnd5IF4wtxaCV42+SUESkKk/GYtu
# DATA K/5Bn4+RwhTZylB97qpCL4kCx01gU1cUkK6bnLpGTWo9PHU3JcRS/UNW2zQFFpF+O0Va1bDOqu25gjTv6dEToWUmcCrNT2VbLMI8
# DATA a3hakHQJPWyUWE6VfYYKRh+ySBlKCExqUtFAUejk9/kGY5SUJbg5zp+y2KtEOaIs1jH+wEzUYp4DUlRFz2gRpxVWZufYaFX2goWm
# DATA Fe9tfAAbpAiKrAAcwdgS7U+wMLc91g8AXVGx5m1K0VBH/D0tcTWk2S1iQ0ng3KvwlK/inWKzrKg6ocdYJEcRVKxqnmVUJ6wsOvUY
# DATA VKCoL5uiq1+4GuPXSMDG7pOcpekszXWWZmGcch5T5zG9yEB9/sKUEoNMKSumSTJllTpuELk85WQiTWWtSGJN1fOKOCsqMhhBdw7N
# DATA COvTTAVjz4onq3eqXfEy4uUoYO+zlaDUHaVNquVGDhM935yxm3ABhxNsYBCBbAcF2wUKJhaXbVptutP4uZnuor9svl+rdHKuqs+b
# DATA 79YynkXz48XHiOX5d0mOi3/gtzejXHRhCMrlB7OIOpM5uxarOLKoLUOsb/gt78heyQiadbqg3IifR4pARlMQbJWbnFbIbsfe3z7V
# DATA ixG+LjBeImTsIcmw5iGnOjLuIWBsnYTZWLRUtYVOlyaT7Do4OLeSf5+dJJx/Qxqn5sXca9SLudfsWrn3gBdqkGzua1UmQbEUQOcF
# DATA y1GKNKbcJX7hSQR8ETbreuoQrgiVXkNuFdrg5TOstTnDrAYtefY96lMpdu+nPJWdywQmz7egVOsanZaVbwuYUrxMxoZTPFsuMORA
# DATA tHRSnFjxiMGwHqp5NLtSFDwzCTvGjsbJC5B37Uvk3TuoAqnISuTrg4XsK1W7RlAvZV+Fp9Jsoh5JUWQ0TxWlVBD7pDViP/owDU+w
# DATA lVcvDbDebL408Cx5Zvfhl8yyjzbnVz4aKIRf8jDU1rXOpPeZUyHcCKD7hF54TDaHMdPJwn1IDW+i0E5DVh2eJkMm+XljrAN7n4pQ
# DATA MDOtcMUsn5hVmYwGesp11uRFi76ObLMHs0vXtGBzxuUDo2SccQwUDTSdhw9wVXldZp7fpRo21HkVeo027xmiioptgexCoOmScsSI
# DATA 7cYYea5riXe0jBXfi7mxynvDZiNvOX9REV6vikMix3iN4gUkZm2O1/979vT8l2d/OfsajK2n3tkfzn5/9vTsv599zeitr1eBXf+Z
# DATA fvrd2TdgbJ3/W9zi/f/svV2TG8eZ7znX+hRlTzi62wRAFIDCC6mmlqKolzOSzEPS1p61tIoCUGiUCKAgFNDNtqwIyZo5MxPjOI7Y
# DATA nYiNOHF2Jzb2Ym/2QmOP1rJsaS72C3R/hfNJ9vk/T2ZWFt4a/commbJJAoWqrHzPJ5/M/P8EyXX070d/pp++O/7y+J8KCIfCpLC+
# DATA p9/+5B3/PX4q0h3f0u+/4Td9e/Q9vfmb4y8YDwZklyKA/Ya+/okCpJ8cs+t5cKlkUD90mUObByR9SBrDB0pNUuMCJ7POlNXvpUOh
# DATA DIumAl/cx/QvHooLUtotXKg9nD4HBwAKJfwUOIy8EZW3e3aURn4SDtZivO5jZbwbHpqYOo6X7WtRHcRVg7yWlMrlkbxULcyWjB6p
# DATA ajmIKZ6Tw/n7pTbqm9/JVdKLhHnBZahiIlr4sjM/0vFyQK/Niu7CmV6Pogx0kLEgJoCk6i7LUDm45LwUvQ32AomMMEMVzClieH4O
# DATA 8bXkvR139eyYejeZXotzSqV0gex1cmVcbc8strJnhfY6ORUO7eXMgYs3BzTt62xWwEux2nJVFsBlGAAbjf+nHP6vZvSXirmQCxb0
# DATA 65o1qsvggC0kH1BTrA2lzHlfn7IC10CoXnES5tP5zlRtjeAtECwSEocT8yYdFKdcFpxQnMp1sBEZ7DH7euEPwgacFK63aBIOCsqS
# DATA owEt7s5QfFGXixHG2oRqCK8hdzPME0dYmwJmxwjMAwpUXB5wTlEbh2smHhUpixnE7pF1MY1HkXZU8fIZQscyNMyWgtgs9GKxQwwI
# DATA ylHCHCXMUcIujxK24ZCz0RxoU9P5aqcBZ5kFXMQkwJHCHCnMkcIcKcyRwhwpzJHCHCnMkcIcKcyRwhwpzJHCHCnMkcIcKcyRwhwp
# DATA zJHCHCnMkcIcKcyRwhwpzJHCHCnMkcIcKezakMJq7WqXfz4TKazRC3rt54gUtrD0vBEqzM4XP/CqfrMf1FtztKk69Y7NaBltqtqU
# DATA HOIykjKosSKlkLJ8P6fUM192Fd8uvHou/807c6EHLf8SQ2/Vs8BrrVzgkqoscL9atyFgucBbvWa73ZsPvB60Ljz0HOitJiw2gZT5
# DATA 9Qz0FjRzAURBGDarC82CHvd8v7lfCwaVpuc3TiCQra4TjTMAyLixaQCZtNscgCwIW/UNAGS5KwCQBd1Or5wByOqdIGqWDYCs0+tU
# DATA upEFIAtqnVbr0gFkuoGuhU+V/EBTyHL3m9FRLxAEm9DG8kFo3ljWj+ucWnBkWo+2sSiz5JlNlwVKdWWBVGzHQ6W0ZE3YZ4Mo9+ac
# DATA R0EsAzzH8xfjTfIDshNgUi3xSFaMR1IyZX6ZZclCX7DwgsptPdei3tvP7JK56DfZnlvGRWu1WnkaGlaZV1PKcuVWmCuLNdZO/sY5
# DATA 34NxHzoMmcOQOQyZw5A5DJnDkDkMmcOQOQyZw5A5DJnDkL1kGDLUBQqlO4gKES8TdXfLBXa686cxmd1RuvvLjwpwqO5Hu2zBFtDR
# DATA PsBPu6iSt02F5tNlsI4m2zufxb1teWjnMx00tVCYIOGoE5VGZKHuFNWrbtvB32ZVZ31wY1uit3MbXcGHW4+zY2xdwYl9bs1xsI9Q
# DATA v19KEcc+1rwX6aenKKms5EET48m26q2gTyzppwSMujd2x2r3fvpTGHa3KX0I/FX6beczfnp3fJvPZFCc6Mcf8TWKx9LU5BJssv62
# DATA yfDbUuswoedGn9UwyvM3lb4z5b1CwumTP0b52XuMQ1L585cTij4TPCg/4kSyT2z525+vfh2T3jpRPNjepqQWkeadm2zaAvKmsoRi
# DATA Qkk29YIaEqe+xG7cnc+yCmNdlrjb91HG2Vy8rAapWCJXJYfUWLDzWZZhKDoUZ0zZGL+qyHks6YZ0xjdu6JtL4xmZJp+pmN+SO3HK
# DATA ju4rcERoYv0BTt399y/+WZ1pBDYvvuHvUBdDkVgIvujvrAkbxyPtsB/iuCQvfyyG/nlWFz5XdYQnk7pNLlZl9cDtXO2/LfVsFzNY
# DATA XfWsGwqVoJxvUZPZSKSEhdDH1YFbGV14bZ2Bm7V59dQEZ0hPeorL1+4urJqf5cBcP7OuSTyEymrWHlSiEBWdJDMHXBItPoMSD2g+
# DATA ZPpUXQPNYzJW7OQiTcEexCOaLi4LFCtp9FA0l0mOGeN0Js6oM+H0JV58fYnTkmSug+4Er6zk/PXrcTLv4RA8iBwQX9UHp8M9vGqa
# DATA DJMJzczWMmWuo2jF83OE+zJIM4saGxeNmlkmYnJG1oyXWyKSKs0rbHf8spYGFsymkROjl6lbIOAp9SQT+bCF3p+QVVYQ15No2SPy
# DATA xvKW1bxkjFkk4HrCeujPJlOW+orVe8c08o9EPyFRUh9GxH6N0MdJyqMv0BH9XMNxJpQzoTY0oeb6Vyfa5US7rOF3pfF1HcS8Xp/F
# DATA YGrlZauMlNdbogtlNyWMPOMoQUM76Ce5EUoQAnoAK3l3IWKDomNNnVDmwgo+Fj2h5hgO4h4UbyC6DeeDSEiNoqirMWOn5aeYiCrg
# DATA g5LThrR6YYmSloOnbAJPGSZSdKx3rz6vA6JM2I0mEvjyefXd2O0j3Ox7/Gn1ndrcUXwh/vw8oFPs3DulSn4ThuNqnfysLHIsC/bq
# DATA aXF8nhVlIxvGr0ky2+tnjeEThr2zhIfGJc1GZDyyFlW2YRrteT+JWduqw+ahp0/Qw2qcsdjcmOV7YWxSHPai6UVQBs6Rf8Hp8u+N
# DATA KH3isbPdQgtAG1fBnUx6WTJOXOEp8wxt0+EgHDyhvNLygRwebpsNgOlmVKMXjbgMWLwNpyC87myixXVpkLoYpkXWDE8LZ6isz7es
# DATA VUu+vU5jvOz7Y6bOLDa1T9lWVOeiaKWQIVaPRmBZSF6yNJ0sJqSK3hWl05L3NwzEiDr9UfzpLDIKilRJaUIHVsK0j2lHP+SaiHyd
# DATA qop7AbmZdVOnzcsT6qDu9SQnP6C6wyqIWqrZYEhNJlEauQqxhapQowYJTxZu5wmkIOdMWZV7IcsuKuTfIFKTTM52pSFnRL17+WH4
# DATA WbXg+ula8OvhgO0INVWIbBYNjAPOkHQ2xgSMEhhO2odqbtARnUXZ6VzyeKUGucty5BPFdqNc60URRBQx1SKLIkrHUSdmIqyoX04O
# DATA Wc/QTMJH0cFF5KA99p22ApbXZ2E2lCrYCirXxFzUFFyadg25a0Nnr0g9ZhrWCUHloYw6IAMbpjp2UHh9sghRv5BlrALKwodUqaED
# DATA uY+tYmqPzbWFqrxAro0sCOfXcH6NDf0a+Zrm3BrOrXHGNaGVLpBL0yhXVTZHf4UpTtXceDeeOStjnXeDmYwrOfa80ZuXObD7W51c
# DATA 1NfMpJd3Ndgjp7miZ72cS9n5SOwMoW9JryemQdgVuyDnkOBdLfQz20im19lW21N2lF9Et/ARb+jHKyRS6mnTM+rvZp5fleObGAYm
# DATA ZNyT8cJn7nBxGD6VO8pyTi4a89G81b4T3iTDKbHKdOOoqqdNVPV3E9XKiVH1mxtHVbb9ILL86aS46duz2JkrJn61ZdHzrehV1sRO
# DATA rQoaf5acC+DpH3h7N3mf4pBMbLmRzY/J8M6rIq2QZSGOhdh1MLuUq3NjGtynchz3pgSRVWTjm7Hah7m0woEjJhFNBruWqZ1T+P9P
# DATA ZJt29ASVJuY9jJIGpCNThoOQhnfAdsb0KBlomIEpKlA2i9VASkUnVJMtoaSavb8W0hJDcjIoMsySd2zRW7rgYSZCE4UXpeB141/9
# DATA KsaQwu6V0SyFIH96SLZvMkwzL6ods340GJ+wcDxXqtnise1XzZaBJf9lzxY9/gAfshI/U2CylUsaZTS1qo/YsFxiL4dVbrEOZxOy
# DATA icmks2mH/43hhd+ANphnEB7/Fn8v0g7/69HXzCP889EPR3/wjv/2+Kuj74++O/7P9OQP9ElxC5lxCGKhBM4hewxE/BoYxeMv6Ibf
# DATA H/8jPfQdbvvh6N8oHP3kH45+AC7xW8YgUpCOefg8zDBM9comFlzhQTxBjtIzBeWv5A5HIzFYOMnQnSXCZBE9oFIUGgEMK0PwoJ5U
# DATA Gz3jOOrQbHwd3PCh3sZAAwCj1Rza0JpM6AK7arjhQqlcHtpQ1RF9GzgbmrjDvyzcj+0rVof7KOmpPS0XjjbkCOTAhnHKld1hDTcr
# DATA tgvHGt5/Oh6glwm1M2SYdGeDEOT1ZMqaPSXvA/T93Hdl+7x48Qsb4+lZs/+J4jAbck+ZyjYouFCSaajXssKRoGMWgIYnV8HVVst8
# DATA y3pWOMOT0+Bwhm6kP8dIr7mFZxngXw5P4ZUN7hc/tm80tJ9yZL+agV2q5VweWMzCZ9VyLgNOOJdKrACABKQ4f3HHSqw+5zifoFBc
# DATA mgoqB9qa3kSdonh487VsK9YS3bCSRuwVnc+3DYmExsuaxS6dJh1eceTxWKPimB/HtaRLc+1RaqIfzSaJFw4Z/8ZDfkRmQ9yJsTSe
# DATA swlyFkD0FAeLEXg3gjdK7ahWa4VkPVBxvheFKSLEtl1nCleMGIns1RFKnaytq6Juzw6lfjlaoaMVOlrhZdEKNxxqNprabGoZX6WN
# DATA fxYT/yIsfMcqdKxCxyp0rELHKnSsQscqdKxCxyp0rELHKnSsQscqdKxCxyp0rELHKnSsQscqdKxCxyp0rELHKnSsQscqdKxCxyp0
# DATA rMJrwyoM/Fot6JyRVRh1e37UeI5YhXMLz6cmFQa+V/XL+8VW61O/Uaw2vEZAf/erQeXTWsurePWKV23st1q5XOr47WqnN4+xo7Dq
# DATA SzF2tQWyoZz0E4BfKw/wC6r+HMGv1szKWo6tZQS/qBmFnUVwosUHbAa54CvVVj74VnVl6CaZudBr5WBN6MGZQrdLpOl7tVpjv9Ya
# DATA UtdarLX2a62Nc9pfhBE2fC/wG/16EMyF0gk67XZnKYry9NhBaTcaOyhN0MIO1rtBs9E9ETsY9tq9eg472KW/uxULO9itB43AYAfb
# DATA nU6tXbOwg5Wg1qxeOnbQbFOD8P/eRvP1Ndw+sW+9BbtIm+NzbzMDpZp6vRVRdxOHBYnfUoBhoFbiKgu0PiwsLrxgzu1uG426QPLz
# DATA bjL3PB92gFeXP3aYbJ1unEOBNp2QKWLk5oO6E84bKhY2MB9Ze3OBHtHVsld5mbdXFlPySavA98l/qT/2jHs9cXAuWwvzebLGbFmb
# DATA ZLYnHHDQAQcdcNABBx1w0AEHHXDQAQcdcNABBx1w0AEHXzLgoM13k2SLF0NIaXxUHNHf+WmzfKNSLtDMUv10wEW4I1M2jfm6L4dk
# DATA +KAbGtkN/hVcus4QAUfe//e/ea0yvnWjaFz6kP4bgbZG4d7ZLb/24dYHrKXO5+h4oQaB0I8SRImnPBRhCcscvkFcvPYh7mU6XthO
# DATA EeKOeQqf+F3v2EfZJHVelE7hR45uef/9N/8PIrOQ9u1qpXxDrrK4J7oGBKlRZg4h5s52n3S2253pftHPdJ+WFHYdznrPudjWY8Le
# DATA RdMwT5S891DtbW2XpXCwZ3o6/Pk5GnkZFLD5w+wXzQBblAQ4KwEs76/VZ/XfZWqXVAR5TS8yujZvwPUYet2EfkgP+Iz2AzghUbVY
# DATA CqgfxpOS9yiesvtJC75LBRTh8tlYjierws0d3w8zKaMxRBuTHp9FzkRz5hRuFsr5SQRTOTRyO7CJrl7p5hmdgrVakDOGnDE0bwwt
# DATA 9KhO9MaJ3pxkRl0PMZwHUl+ZaNFNDP7ik6RtFHEeGu0Gaobx3kiRv5SGmsJHTmhY6EDcooebRUkiDYFfhXtU43F4Qz7Ld4gODdyQ
# DATA A1u7ZYlmysbgr8dQnYF/LFOysXkw7LsQ1Q6H+9oM90VJgT6JSvqUW81q2Be7HUUWmj+uvpe353LP8pg/PQ/wLisvTsldebSGn6Rz
# DATA VYgr99AqqHTFthLgyuODRMSakhkEY0LIsQhkZYiWoiUSUcND9kKJLJOYhzSu7cOL/CvIs0yGefUiUSki2y/JxrsQgjBUO0LRqO+x
# DATA oazPnEqjUbOD5cLOiwLQZuFNbJIsgSbHtJQDxgYsKHPG0AOWIPT5+FdnLrmHG5fcQzlgLla6Lrp3YYugIwyZDUDFsafUv1MmfUVj
# DATA VsdRLKE8OgzFx5I+ovZNRSCT1LuazwiPodoXxb3pIJoqsMBExSUdJ9PzF1kuZVdXZllvcsoy+9k6Wpnql6TMfgYBIuRjO6EI2YAo
# DATA libS6yha0GxPGFmUu9SJ42LSI2vE8LR60YFoTunBbSqS8LhTFne4pA+Y/sbMFdPouPTbs/Tw/KWVT9NzUFzvb1xc74cAt/NiBvX1
# DATA GY8q7YuWvmkM1OvtwR/+JDoUa78dQkHL6ydDaViYHIw4NNaoG3lUUBPQwoDKAa+KHfC9+Kng4xiakBXmvPDb+Qstn7IrK7RsFD5l
# DATA mT1eXWZ6PFe9oigH4lpWXuKPwD58DAPUhFJhBQ7EEcPyyB01TrA3zrvL5dtjfBd1QhAhw7gnlieOTXnjGR+eY/GEEdAuF9DvZXG/
# DATA /iVS2bRE3o+Uch2Gj6n6SREu5XxQpAcYaU5ibYhQX+Lx8S60gEMRJBQwoGo13L/xzBoBwOzmoSxOtZGC0hX9uwtoM4sJOVMxXS1h
# DATA 7lwYk5fBz2YF4RxtztE272izq5TzsTkf2xkXG1f65C5JcFqm5DLTwwiIyg0b07jYniHU4JLIczlPlt57AnufN1lj+anJ+2Z4Jqx+
# DATA PwF0loViuivrUkaNOwl1Vt+Qw3agvWUG3MXzArVrb7szPBFwJwFkgDv13QLcLcXG+XJZg+PKG0PuZDcP3IX4IIwxoSBDpZjzas6B
# DATA qB7IvIc6hAWfXaPM2C9sa/cOsJDJ+4sa5dVePt/nRx5HT9ETda2n6Jc1j9X4sbfp7kP7mVp5jZtwJaJOm6bYTUuW2vT5hdTZrruD
# DATA PoXifUKW5yg6LNmSz0rXWToBOIQOEs/nlhZOFCxOb1gb0zRJme5YdabOguKE6RUP3BS0cceLQ4P7FvHYK3e/VtfmF6ttZx4DLqnA
# DATA qpUy1zurhVMfNdPwS7Unt5OvqdCbVjLsFIpWYS+Qhf9Uur4RxXEgU0VWzR7PJgC9y8J2krJ+qiWQvQFE7gUxnjOEHPUiUWcS9qYW
# DATA Qu49fa14/HdHPxx/efwbQOSO/rCIjvuXpfg3+vINPfXV8RfHX+KyR/98Qxd/z39/DXAcXfnu6OvjvzdIuG+PvlEK6VD4GkM7lYZs
# DATA h4m79qY+W+ahZ+qM9x/C/dC7343lLJaI3qt9JTz77U3iaNSlDoS/HSSTQddY//B8z8biO4UrQVxng0Om6yZwaQtFlJ0G2QKF6nnw
# DATA VPSUGlp3LULudQhosNaEx38LT8Jx5LIZgekUrpojt7xoLg8m16foMLkgg1NzfdXXT4LJ3QtFEvwygHK8+YpsR/qXxgRxXWE0R4Nx
# DATA QLnNiu7CgXKSZyGbOSN0bjKvMtMpbdioydRQOiiyXHRF4QU+Gt7Q77K1vTcLqVFMI+rb3ojTJwVYP/T0vQc/99JxpEgZOP5OaVOq
# DATA MDO2geBanG5Am1teR1ebOEvb4HXBzi1PjEPPOevhkqwHjaU7s9HwUrgQr85guCR7YSNz4ZTWwtUZC1JJl2WGMRSuZ0O7DIqdlQ0A
# DATA zWGRuBuNwaEiU8YM1CaHeDa/Ils6yXA4Q3eNBbx3MIPosMOCJUVSypdOZI/4k4gdFOL9Q4alarM9jfRUZHy9F0/4FG2abky4A0gr
# DATA Vb5ZDROjDNkni3Aifg71a4/myjEfcOAdQe8ln9CI5nHyOpSBSW9a8h7qeMsBBQULm3cCL9gtclZAI8iMpgWTzJAf0MWBdHCfMjnu
# DATA iPeY0z4Sdw3v5YxGzNHBCXm0LoDIVJWgXHXMO8e8c8y7S2TebTh6nelg1zqz/MpnGhfhUT3rPMMB8BwAzwHwHADPAfAcAM8B8BwA
# DATA zwHwHADPAfAcAM8B8BwAzwHwHADPAfAcAM8B8BwAzwHwHADPAfAcAM8B8BwAzwHwHADv2gDwKn61W62cHYBXfa4AeMtWoDei4Fm8
# DATA uEqGo5PTaFm+N+YUSoNmLrtqQasRRHNktUqFCqC2hqxmvbp15lc3K+1KvXr2V1fqZ351tdlo17pnf3W1euZX1yutaq1x9lfXys+s
# DATA rGuNZ1bWQe2ZlXXdf2ZlnWvXreZVZniuXZ/u1efN8Fy7Pt2rz5vhuXZ9ulefu3GVn1lZ59r11ZZ1rl1fbVnn2vXVlrXdritB/Soz
# DATA 3G7Xp3z1eTPcbtenfPV5M9xu16d89bkbV/mZlbXdrq+4rO12fcVlbbfrKy5ru11X/dqVmgqtM7/6vBlut+tTvvq8GW6361O++tyN
# DATA q/zMytpu11dc1na7vuKyttv1lZS17XqolL1qo9IP6uX9RvA2fc07HRrtelDrLH2sVmvwY9X64mM1ODoapzHH1ATEgsv79VyQfrNa
# DATA rSzGJCgHXiUI+pXysBp45X6lPJcb7SAK2o2lSPbmmWjq1YymLv4ci6beLIdRUM/T1P1W1a8EOZr6HF8dNPV21Or0Mpp6UKnXa21D
# DATA Uw9b7V5YzmjqNT/oVMqXTlNnZ3CxzZv0jadTFts1Fj3ztjbFYW0/Mw9EN0txy5bd9EaNBm/QxPZMZqIv7nasw88qr+GDYJtty6hb
# DATA 2zJWAt2tUNez1qW4lNMyMMsuukbwsYR+2E0ObrXoR/wpe6oUPy/Rq4Zwga1Ygq0sBLc+D7MAPbXVVO9fk2Ur8+t4ye4Dtdara5hZ
# DATA BlB7QTNPd2HuREF+ebu8GrZul9Qad/iyusZObvarO6i6g6o7qLqDqjuouoOqO6i6g6o7qLqDqjuouoOqv2RQ9cxiVNoN2zvGvqNU
# DATA ew9F+yMT/rgtxCrustlWHhwyrlxERYrDpBvtCrqCLso2WzTq7JqITBRhg+xWgqAe8FXM8kQ2Ld3VbHSeGivEufoNjVID0hExuCCm
# DATA EGbbbUrg8VDBRrJf6vKCZNpFyFyY+IJqzm2jlNJQHW2XC/XaDowjHFTZvvnLD9V/t3b/+kf4d8LBfHRzr0DlanHauWy9RTg9VAV2
# DATA P9sPR/FgEN6qFMaDGU3701vVAiTjbgWf/5KjwtNYE5ePNJ7+0WxvL0plXGQBMu/h3fduGWx8J4oH23jDjfns+WnJbzJN/q34dYHW
# DATA v87yP5kO71woEoAI4NAkH0Fofvw4Fqi8X6roINE5K5YIRgURvICmnggd8gtVnYEm3hTyfFMyl3UNEiUhSLYoID1nQqYhS1dfW2dO
# DATA cQbHvRWW7GdmogGJtDl5Wno6q+Q7tzGywHE1p5EDsQ+VACi52JI3HGMZCH5cyAt0OJ06p1N3Gp26OTEXp1jnFOuWaP6sZllcFyU7
# DATA bzxBO2UNrXycjJTd3byk294M0rgQZlql3abAFiPwZuNOrILG/I7VWLVYFdNo5yXp8mitBTk6c1+/cucBhibqWnTExRuu5aZ+IeO2
# DATA UkzLyFewgRMm1AMDCNQNlnGKrKI/ZYF6CS6Flq8nY76e6t6GWCy0ppTaHBBbnvUk4zyhbEVxjqCNT0mJYVxrDiEf+Ut6HJ3oKSBq
# DATA IuuFnso8TCPVKqU+Tvcbyi5iub1M6VYNjTr9j4wh5WlDCop1wPuIUjHNh4V6onIoZh2LkvcLjJwLj3T6M+gWa/0xZa6UPJ405AZa
# DATA wQMLAFU8tYUcVTizKMi4hEKf9NzoYxmzEiPCDCqmV5mzBOm6HLmrunjJEdWrc2MxuTFNxoptwHUlmbCaHNTP0tkYIzS2HEPPmepa
# DATA J+pa/f80fCJwBViFbM9g8jU+VIWqB5fwIDzMLCoZgCT28FV7jyN2ZOq4Mdg1tEwxBhHbQw7XrXi6Ltn8frztk4QyrY3BMOQ6R/MG
# DATA nfB34UHxLNteqwIyDSqvFyg0VBbtoihhYWvMJcdScmGXuvDYkG2UoJxOgMjQafiTnmBkgnKadcOAzjBrZcZUY6qdNuVUNlCfM0gO
# DATA 2es7D1kTZbAXX+AsG3WcgeoM1NMYqM4cfXnM0ZVm5jUXVrYX+BcRZoOcnSothv6e9nlAgq2iLNTsEdbrUSis6yq//HypiZ4EdLC2
# DATA cghujrfI3HmVOuj5lqqPo+U2eTXLc5u81FGzcMDflrWXxWNi0vo7CdxS8sbDUUdHR6kv3fnZwikz9uCTzbNCyNt6lr9wuuYgYHoj
# DATA jdbKfl3ZjH2tPM35o40xNtiWizcrq0zLAzOvYza2bEnD4KTBHvaoni4YzFfewMybo5aDbw5fMV8XXp/FqPmLettSKRaIXScSPkbq
# DATA xQWKyCQi0yVsk9WtAB9z7R2nX6UpaAJwv3rn0VCA35SbhobMzY21fENFRN7Pz1pYBhzU93GUjAfUQj/gdQ/kRTb/YDUzRVwUmeSc
# DATA TnjecJyGqLga9GasxXmkNEdZlZ6Orpr8GWMfswddnoqZJjMM7ISQGSdjSTBLUV2VKu01EXswISOyM10fsXu83uClsPgPdfTURZlJ
# DATA swXuhahKnEfIyYMJq2YnByOastFP8RBy6LqyLo3NPZnsLcbmJRQpdtxkZ8Wf1Yqfr3LOz+z8zOc24FdOFy7Pz2x44vM8DoNVu5aY
# DATA r6vgL+uVX/rh/tOx7NvhVXAyZaJklmpf6wk84ywY0+9ZlwzAt3kSgNnfGGhsjP4PuBtExPIAY31Dxlg204R5rrBaZcdvynG/mkGs
# DATA 1uFlmscfV9+LUmezjf32axjFiynjtXSTOnxjxIQyzLffil8/ETFtBZPPA33RxLN2UrEEp+BM86q/gv5RVOUC9oRQe6VMWB9p87iF
# DATA ndZXMt70SdGtbhpb3siRdWBD6hio75iLI3bn2KjxaTfPGZfvJnZ3vZQsJr1MY0d1Ayb1fY1K5g5iEvGahfZMP7+AarNWIB3wIJyN
# DATA aD6EBYF0mmdUm/R3Aadhs4vXCCzKEHr2CcjMQEhLL1Py7uLyfkz2jr1IxpZQ9LSjVjM8WY9QRx16ipqJDR6hAGwOU2xY41kHz9jE
# DATA iOK1CmUoTcJY0ZvAkg7H0lPPlWfmQFG9Y7aJJJexlnvEIHkWuchZsUsezeGYlnCYeIVtHsTETKtuEgk+Ss38PHCiDlDJKDMYGdqZ
# DATA KryPGYVO5mS/aLMmC5g9S+MOvDxxYiGzj/7b8VdHfzz+J1Ctj/58/Nuj74++Pv6dB3Y2/fBvR98e/26Rnv3PRz8c/YXu+4ej749/
# DATA R3cf/ZEe/ne698vj3xY8+vQDPfmHox+OfwOKNoIWkvaX9Pe3R98yR/sLeuRf6RaQtP/k0V3gdf+Wgv2Wgv0aTx/9nqL1J36Sgvg9
# DATA /f09sNzHXzi69vWfEFInlgyjIshygsjS3CnuqzrUTAHCG/AyMK+WP1AjRKht2oIgwdg5RWbceBApXpiiXVHvN9FQe2aDZUbrWor2
# DATA QzxEfVDk0Nm5+V7WPVw1PNsqkcsjZqtalVozPb7AFTOdv7sdhVl3/Tp94crYjmisv0hUNoXL7OpYj2Rqa8XCpO4lZWVvUGgXTsq+
# DATA 10+gUx8CYk5j6kjbr5TB7HZSREnuTajcFvaAi8+XLBbqpPajwW3Etc/bpMi+S20vVZhKb6g3p5ym/q22YLLW9KzY1ydG3mGv3bB+
# DATA zmFd461PN5q/HJ7bKxzJL3Ig32gcP9UwfiWjuNREk/Rst+8zbSqXAag2aZTtoauSx5238vhwORdkJyWlYY+lMsJpX9LQw0bIvizZ
# DATA yuozTc9DIdNO+ofT/jArMGsvZKhzQyGLMRRvQqR+P/FMdAW8q5nLHJtR4kmrWQ7nLXl3+UcW6E6FTMyKzrKEpXpVBJROkzFZW31F
# DATA wZ2GbWSYHLAT6yFLlQFkU3514lT0KXSWduCMcHxpx5d2fOlL5EtvNKRsNF/Z0PC9Gtv9LKb7BVjuDiTtQNIOJO1A0g4k7UDSDiTt
# DATA QNIOJO1A0g4k7UDSDiTtQNIOJO1A0g4k7UDSDiTtQNIOJO1A0g4k7UDSDiTtQNIOJO1A0tcGJF2rVMMgOCNIulftlXvBcwSSNivO
# DATA G9Gj7fyAizUI+vVyZb9aLb9N3381n49R0FqCt2p6frPWD2r1/SbwVs38Yx2/2+j6848N/VrgVejRarnoN7xKlT541WaxVvOq9H/6
# DATA rVFserWqB3iWX6w2+VoFtwdeteVVfdyNy2Wv5dWaxYpvv5V3QubZVtVuENbLy9hWS+pGgPg09v3KPKCtXW/77c6yUGoLMD6bklbN
# DATA I4MlXAvgVc+qbzVPMo/CoNFeiGGlUj9/DCt+NYthUL3gGLZaFxDDZj2LYaN+sTGsNirnj2GVm8QllXKNGsm5Y1irVi6vlAO/ef4Y
# DATA BuXg8ko5aPkXEMNG84JL+TQgPRmENEhPxjMLpNeqBX61lQfpzWPz+Eo4D9LrdVtRkIH06mEQNZoGpNdptLs0RzcgvRZZx9XmpYP0
# DATA ePtncZ11X6rO8ek+tx5aZNHlXEJ+Mz/r0ZnANhZctpT32PS4Xax0o72dXMhzhL63IhrX47AgcZ93flfZ9S1L3gznm1+/VyHzZG3T
# DATA NbWSNt/Zn1u1ko5gPL3xKGe5G8cCjhhoXzg2hhVPuQRUW+aAZj+cFZ7ygi3i+VRtypcGCsPySjSwvLJ8O9TCK0qINdms1iyfTFTd
# DATA GOwSJqs46LRWQ/eyEi7YZbJmFrFY21RyrWqknN3rC4enAqj1K6dRWUGdbj7qIIAOAugggA4C6CCADgLoIIAOAugggA4C6CCADgL4
# DATA kkEAURfURHGXrdNCiEOfBUj4Tgosw1a+LfnBp8N2pbbE3f95Fz8WUVtucyAiHrGrhjf1leL2y3KhUqgV6tRHxr35HlLdtrOjHzd3
# DATA 3+bXmYq4PSrE4L+NdLe3q56wer2d26O1uQSAnB6xsvip98go+XT3zlP9BunJ6Iqyc5+q7oz+A73OnmOMcXRse+ezXE7e5kPA2lbk
# DATA DN2ZS9Vo9w4liI9fwhjleTuaH5+DQxJKcvJTYf4oaO6VFARvh825/DT0wy113g8dRVYrd2nUZQlZOWVM9VEYeA/l0DGSMKYOljF3
# DATA JmFTtniB3PuRevuOWP7Ly+aElEyTvb1BLiWFmNo5apEkiQP9Jb5/ZIpAARWTXa6V2vZPO9B5RHJ3Cnu5n96iSQRV7ISGrIgyZtQ5
# DATA lELj19Dbyq/5zfKtarV8e6+0R/fCWPwFbrjLRv02Ti0UVICyDR2Xd/Td0dNxMoJgWzh4GA7Hj5P8s2V/8dkbpXIdEaKEjKiItvcQ
# DATA mP4id0NJLx7xyibuZA/UtnxKxtvLQmxQMUkBPpDMZMFEwB238eGGz8zGpOc1uUg58fqXnzRvc13ctSYyKOlCtYwVOAFAwo2ScF37
# DATA XM1JWBlfIxh1dfgsq/u3VdX4XLcBngJPsd2Ii/Duvd2DeEQTqxKfKud6+XT661+riwdR+0k8tX+S3uLezrRP47R3fzLh2i1H0q1x
# DATA GunjLJJ68OtfYz549x5FKDwIY5r9cfahnx5inFxSmU/ZipKx1Yikf5SGcvtznu3beSJlJHHOmxeLx9dF9EgUeCB9KKe425EX0TRN
# DATA t03qd8xUdklXx+fj4gFN63KdHorMPCZD3o4VSwpUlcKSILHGT4+YoKznOGtfk1YvwYhPzRyqdVo2TstmmZZN/qC1E7Vxojabitqs
# DATA FCC/LLGb+1h34dEVahOjyJZt0cI3z05A7SpUxsUUoMuP8cHbRnGkN4fxaDaNTtKx1s+azslcMJLLSjV8XhJa9oYoTejKOglrfcyX
# DATA os3HdaEYf4gui/M7YeEMKh1eQOvLShMXJwUg9+czxqwnWTlhfmSzlJesJW94ClTmO/MZoT04WVaYW7Ok84P+nLr1+nf5m7/Lz2cz
# DATA Hqyc6l2Vzd9Vyb2LH6ye6l3Vzd9Vzb2LH6yd6l21zd9VW5BavxOc6l3B5u8Kcu/iB+uneld983fVc+/iBxuneldj83c1FvTf7zTN
# DATA u7S+imnDK9XV7enrCyCmrocKQbpoJSJrtKG+74mglXB0hqZy0oHJCInZA7DJPEkfQmppkuvyJAS/4FULXsDDUQMUrWjEQqoedhBw
# DATA 0AIUHhoSmBUxGqiW+0899K8MM7Bkv4y3PVOVomEK8watCIZBEGGK1Xh6PbANpMyffzEhB211U6f1Uyc3U3oxZ0qnBbE+c1lQ3tyV
# DATA 7fO6DISnJb95wdxOW7x0KaxzJU6WNQT55KFpqcJFgcz4GqzsNRBHfU7EAjeUN/eynYPauBKvpZ4vy4kdyh2aTENFEypJxtC6qxRa
# DATA wwmLXMExSsYQniaziuwr5p/y2ouItY5lGs9bu6DDiHk672oq4AFVUJlyI0/oqZDiAb1jHzsRhQq0BzYZy0/Sy5mRA10+LYZ++lyE
# DATA 2ceakXPasVcpmf5sLKVctXTGkjOWlhlLua7KuZlfejfzSiPr2Wuq65pP1TlkWelDeABGdB9vRso01scTNE3IAM81sr0ZzY/Z1TyJ
# DATA lAb2grw3NRejAG4pgydqis91aM6xnLMaFkXUzX00rupmzCMSla7RV8awmfR6XrifxF1e/Rwlccou8YnW1JbuIAOPZwnTim4l7xEN
# DATA 0V6PQhMR9ZTXSeUoMQbfgcQl5f2LCOTQaIFTzzJrp9ToZ1Mx3FhGDszvribCIcYl7z2ls+0N484kGffZAaPwcVHYYbc8nqccgG41
# DATA uq/lnvjM3ROyrTFSavA6Ux5FUzEj0kz6eZBgI8sUNF/ZgDcOGWpodXsaoFfy7iIzKeh4PFbgbQTBLrnbHha2cZXR26HcZZe5hzMS
# DATA 6ItHyB2Nfpd0c6q8A3obr4yvSd77Iewa4RbvJUZ1HlfZ3KKSgFksBayx81TqUsmnyTCZTJIDpe8t1Z9XyXXRcNX3JBNH2NeZzDrQ
# DATA gGEMuviuskO8WdqE4W6g6VRUGPgUZXldet5keX72jGGBZwGQMyCLjqcgEaxFsUCVInyCQWrKQ1ifTAbbsKQ2iUkDm3qpmIZ0ew8n
# DATA 1NEUzDgo1QE4RMEE4EVPIobPo+ZRNg6lkJg8TZblHqryACR6isxshIEZa0rJOJ1PpNhTJ5GCXpd6zitXiI/kqOTCbN4jjGjzYJPb
# DATA SGv1ukXtOMYwt9KrvM6JnF8oMaWwJvMyvzK/8pyv9eW19Is0K9P4LvY1vFwijSZjYQmzgBvRxb6NF0wecsmayjpFp2N1wmgpF/tW
# DATA XjrBvu/VDTP/wpuzwTl98S/u7CdDXNLbukkySW2+5b8c/XD8dwBSHv8Tcye/ZMLlF8e/O/p/QZQ8+vbom0XA5b8wwRJ4yi+8o+/w
# DATA D8Msvzv69vjvPEZffnH8D/TnKyFcqoDpRYy1/J4C/+boL5peyWBMuu07UC6/Of5H+u1PDmF5/edtj2SmNUlgJLEpjEWjZLbXnzIj
# DATA R2Sm1fA6iKdQ15BTxGYiNhtp24VMKYx6IcNbZcBnCyaVmRswKDALQz6DupZf+Yh3XFBfGA+8T8hiZCPKkSyzOZzuBa4aY7m0YC4P
# DATA aMn1MrXmj7qaCvIofzMqq7n1gaq5GN4ukmZJxioLKag1TNlrQk1i7EiWG5TWhYMs76qtVQNqHofFg3DwJCM1kVkN3g7wPypZsHU7
# DATA IY4b0Sg7gTybwuuEXYwQBho1iiIy8rEAT/XykOcGioKE8/PjBZLlCTVvtVmyrDk9K6LlCYlwPEs3xp9njNcwy7MO7S+Fa/bKhvXL
# DATA GdU3GtRPM6ZfwZAu9XJJDpgB/Rm2n8sgXC5JqkfzUPrE7LlQLZNKchHLAq9zhsj2uINxFinm5C6LMm98Vg9PEgEFSt/Uxro5xzfk
# DATA uI1yqL1N4JY5RzeipJJhtD/Z3Y2tft4BzbGxBizKB6lQAb2fp5kJJSM/WW7Y5d2jmMUwBARNGI94bcnQLmHtxPIC5RlGofFC1l0L
# DATA Dal8q92IxshhTGbDQT/iWIQemya8wa4XOdqlo1062uUl0i43GWI2mtJsZBNftXl/Fuv+3Ma9Q1465KVDXjrkpUNeOuSlQ1465KVD
# DATA XjrkpUNeOuSlQ1465KVDXjrkpUNeOuSlQ1465KVDXjrkpUNeOuSlQ1465KVDXjrk5bVBXlZqtTConxV52Yxa7d5zhLxcsvJ8Wvhl
# DATA reLV6nWP8s3zq+WBXw48v1F+t9Zoeo3moNKseNXmHNeS7m0v4jCHfqvqVSijA7/YpL9bXqterAVF3y9WKPzgV+/VfAq7GQzq1aJf
# DATA bnjNhudXGsWAbqkVq/T6VrESFKuNuTIJoka7u8gHrFK0G5/6QbkYlL1K0/fK01q16ZX3G823a9V8GPVOs9uoLIbRrHlBrfxpsVJu
# DATA FJsUqUqt6FNeUIwCxLTYbJxA1jSRW+Do+U15XSeeYLbU4eKvcyS8DhetLzV3IqDCXHy7QbNWq52Blsf1V9PypClYtLx2PYiq/ga0
# DATA vHo3ytHyokY3aLUzWl7Qq8O2NrS8arvWrGS0vGaj5vvRpdPyuNoX1xsG7N2f801TUeHs5edWANo2yLHTJNGLODeVr4v+P/yhFn77
# DATA pDWE5cbOKvibFcuTKXw2ZE8ePB1kr7YI2cuCOQVkTzsgV+aRndMqQxXGTtU/22NUYTuNjQEziK3YRqDHbrXAVV7NvsvytWBn1Rpz
# DATA 4oScMEQ7B59z8DkHn3PwOQefc/A5B59z8DkHn3PwOQefc/C5lwg+x2nDaYSitnkoja+tG9AYQSQ5xHJDS/tTz9DH0BsMdu9sDxb4
# DATA TirFO7oje42CefqRTGt+6eHDzo1BvpJxzd8pfZLEIwrgQ/oPfKjbxrz8cEsfO8/iUpo+Rb5+uPXGwol0FcANfNakqHtmh4IOVYOf
# DATA NFvJKYS7g9VrDla7A9UvyYHq0+qFP9uD1uyXzFxpiziiQU4Lcy9Jujhb7LGf0ByzZZIEAlmjs/2sz2c/D2cU+e8L1mpfdpD8olXb
# DATA l5/LX6rfvsEx+cxPa/TDIxGoQ2lr2UlVOYzGzOOIopAmwwhCMHy0Vqoan4BX7jcmsohuYP58eXZyvAAZZLI1s8bOc0bomcIDnPR6
# DATA cEzrA82ie4jAparxK+YPn59GRHyhmsiB3DCzTp6NWM2zOM1qnncGlTOolqjRZRXKCdY4wZqz2lEr7bXLEbLhPl03A7KkRLuCNTD6
# DATA yTTZm4TjviUq/sx00y4AYEnj8htKhsYavU6pWSzGAAK5QMFiNfbrwXwYjjlzrDF/mfLthagWf8Dy3tI3Um2EQgp6vksQLn4Ttjq/
# DATA aORFTykfvXR04fLBLFr8ziidDcKpqJcfquQdIKFj6sR7HvV3g8FlyBbPWFNpqrkzM9YAn2sNF/veQJSnIfHd9USEXo9zNPxd7LuY
# DATA /vggmqQsxYSVKubbiywMs42KYUwG/GxMDTK6YDXqRtaJzlnQVJwheLDCABGD+4IloudYk9m0TILMOybpIa0V5A0PjfkhvY3BUWYA
# DATA SFtR3SwHZYrymBzY9Uc1ocNMfUoGNDlxlK6QluoAsKh1pSxdKqgCsbiU9wgC39HIY/DKqEMFpeWneop6QHlfMApZieqdtaQpFp4O
# DATA tVYSz4gms3YbIvlcLswkRjVJBowvlnFANI4mMwh5eTrTjI6Xcm9G8gKz2B0q3dTNUI8vzvTDMijcBMRNQBYmIHkL001B3BQkPwVZ
# DATA ObF41lqaitfBTIt+OGbYcIgZhi2OnUZKd09LQc6JRTJqR6tDKvRRJJMZS+dxagtAYqwcHICfNBNcyLzEo7TYGTVl6ruoFPajJUqP
# DATA m6ptcmrHd97kpc0s3u3DbHbE3OX2LB50jRafigw7GhfdxurwqAWg1+htWe1nYBU+KQtLWUD6xwyeba6wikCfWTHcs8nirOxeoaHb
# DATA SkoeAq7ea7YQwCpVn1+VjRHq5dYdpme1n3o14R42M/ywBo8xlpqNuo9ty0Q5cudvpwmqOszwFn9afWdnEA/bHFF8WH0fdcwJNmXR
# DATA nfflY3bvTUnbnTlMubY1ZTXeNjUxoqwxNHOli83A0uzVGenMcg4nXTM95c0PMlFV+ZjPhzkwF++kNt2B7CyQie2Mb695T4YmGfPx
# DATA NpkK5cjqnYcxs5q6EcOEqLVWxUswTNLp4FDBL/ETrEQjxc5rNcLrikdTGQIjkcPELsm0nyg90VCg51o8loHiIyM1Sy2Xp8Xava2k
# DATA MD1YZso6VAe1rjYD66fIwA9oTjxg33086dB0MctCzFGpYwCKy+7o1CwHnhLqFj5RW3SoJ7vHqwRsG/PeSpjtw6SNR6j3i6ROU1E8
# DATA SWXRTFHAuCwuIrusVnLK/GqtzS/T5CTDfgbJT2oXe5HJKngT+J58HhkEl2RkyfuAxsyCxyp5MRlhh8r/pCBi1J0LJU52q4g7THPm
# DATA adhgjFvUvYisMh3PKTOqsTajVC8m2fQ2/Dhizscjq1bxq6lCHFAsU3bEhJOBWj3Vvhk4EbANLoRWrax08TQbP8P7t3eY+QsjLAFi
# DATA T76QcwEc4z6P2yEkdRldwTc90zYZnKJNvgsQHfo0andFSnRRIFemttmXqbkJtU5lpLXyFoXpIRb3NBGOHiGbX6SHOT/FFkmB8bJm
# DATA 5M+ygvmVzWvYuwkVMY2Rg+iQ3QRZHRvQL5mFo7y74vCj2S01QfbEZcYaMoR6eHZY6UVUtSgq1hbUgXEiJ1F1lKwVcUGBRjiJO0vz
# DATA LT8Qy946eyA2VyQb7ryf6F1wWnmaTTC1Ow1OEVWSihKt87t0EkPsRXFAZCyxcTQFmtdGif1fAhLzjv549LXHWC/Qv/5y/J+Pvj76
# DATA y9G3ixix//vom6Pvikd/BgDs+DcAkP07cGHHX9L1fzv6nv7+Pf39w9Efjn7wjr+S0BH0t4COfX305+PfHn13/BX9+zu8CSwyejOF
# DATA 8TWF8LUGk/3l6GtHE3sOKNAjWfnBPp6OUqnPKNDjKBkzv5EB6zy0U9sTA7GbQPmcvY0YaCyXtBLD5bvQR2fC6vwG6kFikZBn5/Fa
# DATA qthbMJeY3T46dDgx24eiOoKrponlC+RyMWLxyFrDva9rqf5lkSU2muIQoOlj8VVGumhykTyxcCqIgn6Y0nAKC5Ys3aTXczixTUvt
# DATA wpli98JBB6uOkSyAHWaA6nDIO+15CWTA6yReD1MJj7lwLPdnVjlA0h0OI578YizhdcT4VxHTN7xuHE2XYMROrHSrrZNcW3p2DLET
# DATA U+A4Ym50v4jRXfPETj2ovxSLIlc1oF/weL7xYsipRvMrGsylRtp5kG23evZN5zJQYnZaxTGsdnD0E3oOiw/5hCIFJpa6sLBItCbp
# DATA 74DBPhinQlXipE3D9Inaq4IIxCOcHMMxPpUlm6HEADCSoXofvC4Fa+pmZCepNjKsd7RNAPhUgo12sAmwthWTgbDELphBdyGeLrMH
# DATA lDXA4CPYAVi9Sp9QYCYeMZzjXJuofg2wSxt7yGbTSSxllow60WSUOo6Y44g5jtglc8Q2Gmk2PIGxoXF8ZUb+2XyPF2DiO5qYo4k5
# DATA mpijiTmamKOJOZqYo4k5mpijiTmamKOJOZqYo4k5mpijiTmamKOJOZqYo4k5mpijiTmamKOJOZqYo4k5mpijiV0fmlgnqCySrjal
# DATA ifV6taj5HNHE7GXn02LE/KDqVVuNT4vVctGn/GlUi35QHxRrwGr5n/p+tRh4fq3i+eWK16gUGx7uwh1+ExiwfNZ1e61Wo7dAGAPg
# DATA q1ZueRV6R63h1VrFFl2oeM06ggy8ABgvz0fYLbyu2soHG9Sb3WZvCZirWrbAXJVWYMBcfjlfH9q1Ri1aEkBQswKoWmSv5mKVqC0j
# DATA g1Uap33eypdqteFVKR8qgdcs0l++P6zUfMojD5lb5ixenRC7FOnOWhD0g0ZzjnRmHlggndXPwCnjlmE4ZdzILE4Z1aNGI9yAUxb2
# DATA qjlOWa/SbXTqFqesVe81Mk5Zt9mptWsZp6zSrFfrjUvnlI2j6YmUMowv+r4NMF+Wo6zKbrJSk5fHMKTtLJLATMgac5ab6daCn3gB
# DATA /akE7HTMobkkRyUEFeHNnGoqVcaxVjHT3bm3V2rsC2Q33pxtI56nNQgvna5CLn5rhvDcbdoF5pBdDtnlkF0O2eWQXQ7Z5ZBdDtnl
# DATA kF0O2eWQXQ7Z9ZIhu5TFYXG4uuFhuvteOO2XeoOEJjYw+z7cwmEsSv1PYdLcVNf4fBQuyleaZsFQpVbD1ueHW3fHNMF7ChdlNDik
# DATA 3LiBoG9QrvRmIhfGx8N6ls6VOmvFq0ggZQGppQ9zhepwFjTIEKQcuwn5kDYOqJgzWKL35yhb7tjxaY8du+PGL+px47Pgta7BMWR2
# DATA 32l/13rKlghYmXgvPaq8hK91XQ4vP1dn+C4DuJU/bn3BpK25ynBWxJblSM0OkauczrAgkGcUAXmlusLZ1a/eeZMn+Kwrp3XouPpA
# DATA KHSk9ObkIKypPgchPdFODnDaOdqbDSDfp2XnhpATTXpQw+/OJlxBw8lQS9+rM/H8bh2Bu2Rbx2T88rZZHQVNCaPs6WGRtM1anFP4
# DATA iTzenCKWCZZaB5w26NlxW8CJynaEF3fJJptN2kZ48iU56mmF4ewqZ1etEWuzK5fTdXG6Lqc1qNbgti5H7+VvRskBun9RHGiHe6Kx
# DATA BskNNbD5Vy8ndgF0LV6BUDtA9LWcNjxP9Onqz0fQW4iUDItxi3nbT/Z25khAI14HykA7KgjTTenvORwSJZq6ZOjJDGOWty2X0GdT
# DATA zyJbcsQ4wl7O7McVcvbihwDQxxZsGWOLKw322yfGVz+f9av6QgbhapaXxdmOMbbr2FFeE2H2lDClCe7qTMcGGXVCXNWjJqr6ew4X
# DATA tjae/ppYzhGU1PoSWqtyuogaOVd1i5KESnXnVdlrquKp1hhtLd/skvQu8b6kgMZfxWy9KUGcjwJlMZus9m0LHyl9eoV4CdHsjT7g
# DATA fbie7AbMDZq1UqKnsai48HCHHke7oD6dUS8ErfJ0trcXsQcawAhemVAdRDIBxgJQJVaVxijMgY4AqBhoGpcw0Ng3rtodBFTIlJ+x
# DATA P56KBnowUAgO9wwjFgpUME5TGcm7cY+lU6aiP8TKzp7ayhuZ+IgcPaSJOBpL1IkySSKWVYanEZHxwjHVOQxwm7KdXhBjNzeCOXPX
# DATA mbsrzd0F08ZZvM7iXW3CXhOFw3usvgfN4h4GmXjEMmbL+U6aL5tJAU6iYcyIjsIq1b03hSm4MNywsNneLO4CZ5gNjBQatdfuDABC
# DATA Ht7mTeA8NGFB4NDcR+O6YZpq3xMP9T9nTgDGs0lCQ0c41WMu2+FDauAzmFDKDgj3JpHGVy4OmUr/kELq0lBtkgNX1cLAydKAEJdh
# DATA z1HEmnBeOEWFpgjftqntmgwZPeXtUXhHDKgB5fqKGYFIvCX7vL9JMTg1P3esGV7YyCmgkKfRpBNjv2MOgioZzgXDon2WUKHykpW8
# DATA t8DZ4m6UvWkM7erD5uK7GGACYiXcde9GU+5nORkwbcLpnL8NB9dMZD0+3AD2ybo03tVylKa/14n8ALM2zd5RfT9UJguiuafBRHgE
# DATA 649U0IO0wHSM1FA7tdElZtL7CAw95SFMMLXRkkeWCQ9JbVjaUTfuhFKCCp+JrFyo6RbmLHpKY97gcF0q3+cjxcb8YnyJTudd3ump
# DATA DonMJgV4kllhfKiLn6ePipQTA36izNcRlPiU+KfFSOMk5ZUqS96jKHrClBC4ZZnngbzkW1W10IqVOb4M+0+FGwK1RTiItaM4THlS
# DATA G+6NkjROF8gcbIidpPP9OKGOifMz64K41ZyaFM0+bT0GXQgn2nJzq8YA9zY7sS+BDP0eqq/eB0PNNUTVFf13PU25BEr0vZyzHG2W
# DATA ylvospdAin43nvKsbELdFoQgBQqpmDXcc4rA5CXAoh8M5J3oIDm1WePiaVb3EkDRd6kD0i0evVTX6OtykcJbNOleMDv5RZ+/WVwc
# DATA emqa2lic/woIztH3R18f/+bo++N/OvrGO/4CiBr6+g1d/vb4d4tknH9h1M2/MtQmf/fRn5iS49FPXx79/uib439UofwXcHHo2g/H
# DATA f4cn6FW/o1/+Qi/8k3f89znSjgXTcWic54AszGA2o10rjCx4foH0KMg2VOEC97jbOgCU+0BZVHsRKwY/gcNZcMJTzUpkyCgPomAI
# DATA 7g3WE3DejcIev8Xhb3JzTG7vV02/sQrj8tA3krSsW+S60+N52PytGDnMjTzVm/QPp/3hReJueJMtTXv6qPFdnhEAucdbMXG7w96c
# DATA WGIXzrvBJDdpY47J9Ux7rLFTRE2HuX8ZhJOhWprKJp9xKq7ohT3Uop/Otq3MJai0qBfDtI5MFzi4F/A36+vfauMja0fPCnuzPuaO
# DATA eOMG7VMM2hpsc7qx+uXwBV/NOH2Rw/RGo/Tmg/Tlj9FS/UyizYB8dW3hMkg1Jj1CSE7nE6L3X2SbGNie6CdDDYOxykRmujSgYbAL
# DATA u5xQpqAbIkWqGMudZDYRNkU2vuqEy1F2egnyioPfjFujpvi5MTg0znU9eptxO6Ubu7NBpLdE8hIWvIpeOo46cZQWTPwzdrFytA5i
# DATA cb1G1NmGvWh6mHMFqnQwTpcx0YwC7kii8glygBoHqHGAmosH1Jw8cGw059jEfr0a+/ss5vd5rW8Ho3EwGgejcTAaB6NxMBoHo3Ew
# DATA GgejcTAaB6NxMBoHo3EwGgejcTAaB6NxMBoHo3EwGgejcTAaB6NxMBoHo3EwGgejcTCa6wOjqdaiavesMBq/FzxXMBqz3HxaEk21
# DATA 0vSqtXKf8TOVmufXqm9Xg0o+Ozq9ZjlY5J/UKAHVWuMXfqU6zz+pBZ1acxn/hEspH0y11fIqtcp/9FsVr1Ip05+G1/I/9YOm1/T8
# DATA RsXzA5/eVfUqreqnFb9e9KtUhiDm1Ip+nW4p0je6qUY3+fRA7T9WWvRoxatSCNXmpz68yDWvRvdU67l01aJmq15eBMRIhIpkwhd9
# DATA vzn0a5QveFG9DDzPXFo7rW4r7CxLq0LPUCnGZH4odk2tHGTsmlqrbFXgmnw5XFKbu52o3umdgR3DFdmwY7hNWOyYWqURBtUT2THt
# DATA XrdXz7FjKD7NTttix1TrLQ5I2DHUSbTCyGLHBEG7Wrt0dsyAWsGJ8Bg4jT7PbjWUF4vjolK36Nhj516F/m3+xDa3G2w+ZEGejKSx
# DATA eTO82U72Fi+LhXFdlZasn5KF5WGp0qvLn1xonrJoDFCGR1HT++fINVLEcymmMGEZeYH8Ma5RSXYTxpXtz/GtNR4VRIMyzKc/6l9t
# DATA YbL1ygPiSlrNBmWZz7r8HHtpRqwMyEFtHNTGQW0c1MZBbRzUxkFtHNTGQW0c1MZBbRzU5iWD2miDUEv7bO28tm40Y/iN7vX51IV6
# DATA rIA+cGnX6qmUWZVq906se69dNol3bqOdf7h1L1PzwmEVS85lRDmsNF0wfc0za8zJB3du2J0btk6+uNPD7vTwSaeHV2pNXsqp4tdR
# DATA c6E0lwVuThY/U/2JC9BLh9Yc3nwQRU/4hKO02TNqzWVjy8WpzUXRQKlyt2WVhDJEqw8qR/clyM7p88YK3DamUu1OoD3n0RwpGhxe
# DATA gubcOyMcap5KD5sqpWzYy71MoPoSxOces+tLpZFMENWbU52gsaMI9evuJejOPZSjxPABkimnkmzgApdSrqw99z7OWodGgA4tT0Y4
# DATA mCxkXmIv1GwSXbD6nPLAGOn4TJMxpwyQHW7VCTGnZinD0AVMcz2IJVGficKLBDwkVOcO63NvVMrUNbuTQ53RGaohHByAWziMWEIe
# DATA t2ChigyNwaDkvRv3THMoAPcwWGyLSkV1hKhMvD79OImwYDU4lCe5ezkIU4mOJgoptVqug6LyjsYGb65oV9OkAkvs+yoAah0UTakv
# DATA ffgGJ+pEPHQy6dEeDSmrJAN0rujj/tRNjnDynbcZ0HjCUgA0Us9L/MyNVA8jHAdUp7hl0ip3yLhzsmz8c37y2CEnnf2e2e/OYn/h
# DATA LPbTIiWfoQ4QL+abhej1HMk3Y5Y/V3AUiJ6PPN7LuwYiecXyQddeTuMy+JCZyNFFwyFtOaizkiGtTQp62vQQx6pMdZCJHwunKOGp
# DATA ylxBYleDlKLa3Qhi4+sTeRg0AGyh09DGu95gNoxHyYymiMYmGlElTyBiM44GA0i7YwztK8V1sr9GJe9nbZHbJ8MEm66hpdQnk1Rh
# DATA Dphno99uR+MtGGh8FydGx+J92EUUBMWOKi/VGsvsYpOPz49EvA3hMIWWepiyhLq0EK3xPISE9WTd+9kN7eXe/Za0oJTMy5SXokve
# DATA e0k61fafiAsx+0fH+jYySNoX2EtQvqH+GrYBhO2pG6GqzrIh8zF50UVirJ7B2WrOVrNHBudsfXmdrauZk89SwvE9XqzU9VkJsPHR
# DATA awtKCWk9hiPsQ7tN2k/mvCmwG4EBk+xE047DkvcgEwPEKRxRaTNoHy5DdhqEln4g+zTZd9CLO15K0/2O8ay0eStZphkomosbakBy
# DATA isXxkTV+WetDTEbhZKJ5Qny4BO+B12eJkajOOC7SLtU6Nyopf1J+MuXJ0j9mQERzhXMc2JGIw5GnlfspGQysFCwlQJrFc64m8vlV
# DATA 2RKgXm7dYTpK+6lXE+4wM/cdVp8xYg4Gemk0hj80Udbc/O1kN3CrSg5W37PHZg8js/jT6jvbbKexRvZErBR9501JVZYPMh5rb6Gs
# DATA QNt+PgwNa1yFa21Gy/MZTrrGCc8L/uKOVzlo5cAcSIp3BpvWL0vpXIUmM86JuyYB8zGWvByzwXYPIo7xBEKmqPeZ2Qp7rag0OQsi
# DATA MVrEzExrkNIwNky6Efvxp7BnYfhpC05QSrYzEQ5II9UZsdCQNrKn3q9owC3Z/tUNfame2SbHlkY+KSZrtIQZAK9Y7uZGRM9YTtd5
# DATA W/ZUxZNVvlOW0KPVJaSrsRTSozH7YPMlRM2YOxLxuAP7Aq3MPtk/4gYNPanryuq32IFmDQTPyyqISK0mUB/FlAOlix2Myko5f9nY
# DATA Kbj+BfNg04J5EE4GLCobDoa6YB4lPYaxjmhUY83UA0zyaATdy8/NSt7d/STGzJjy3rj1C7brm0tlTP0LJmddNUvE9PDc5WFH/MrK
# DATA I+t7T1ke/2F1eeheXMrjP5DBstCRzTqd2YDVZLEIqE4SqsahJ6uKpUe9FK8k4Dw2DRkl721qXYcFKkIyQ5J4ICrHQ+7FkuFQ5J/J
# DATA uBgKS4x+ipGDZr34/AWVpej6F9PDTYvp4azdnu/PXmcRa9WbRaNPksOsB9NiXCXvg5imu90ZdfR7shRl5JP1qlBm4YGpTXnVCWdC
# DATA xzt3WdjRvv6d2JubdmKvx5Mu7xgYwQFEjWNkNZ6+KF73Z8O4W8RCIUuMq/LgUSdlwx7SQlNY5h+EmkudrfPbvD2UsOntKCQyntS2
# DATA CWghwz107nJaTNCZSitv/8k2Rtv+M1ck7++8n+gNh1qDW0x+sbh56Z+hliHNWJAdupTVwunlMNGea49XxkJL+0mUQ6H9H0f/evzV
# DATA 0e+PfwtWGTBm9PnLo2+O/u3oe/r794xH+5PHsLNvj/58/NtFMNp/ZYza10d/pmf/4NFfHODRtwUK8eiP9I3RZ/S/H46+MS+xSWp0
# DATA 01+OvsEnxVH7N1DR8H557w9H/378T46K9hxAuc02B97ymkwPNHbVkLkhXizk1QLPjHibVQQTT7MAAA2FO4FlZKgDEDgDOtAx6AaK
# DATA 6Er1eDLlPWN4ridLWMYpAE/HWnIalOXRFMTOd/g029fHXcRV09PmC+TyEGo0WoSDZC9DfPEOQ375PIf7Zi/Ouuk346mF77g4hhpM
# DATA aXVuAzU0kRGcs8Hh004urQvnp70nGHCvTcYFdnTRvL9P446ZXha0kZUmOAyFjIQhi2Siu1N7WjG/UaTxp1BJibLOiXW+CmRTyXLk
# DATA JGLPIhNm9TGBIRWR4DUwWE0X2Grr6+VqI2aulT0rwNr66DvAmhv/L3j81xC2Mwz7L8Xy3tUM+Rc+4m804J9ivL/84V4qYj7pZpS/
# DATA Xs3nMrht+YTzIMkZYqBjJtXtQ4RUkDOMk5m8SuI6FaBTOgyx8GWW3jzpl9pRCpdWNMHSJCeaBurs2IKKXjfuGbYbJfvQUySTDZlt
# DATA E2Wu8bYaHFkhg4L9ElHnCcYmhSbjOibcKz41zDuBhDYXp7yHKp0KjYuXZqN0KqYC8iWzHG4rihnoWdMZhTAMR7MePk9sI0F5XuEn
# DATA YJtmclhMRg7Z5pBtDtl2ici2DUaXjSY6m5jEV2jXn8WsP69V78BtDtzmwG0O3ObAbQ7c5sBtDtzmwG0O3ObAbQ7c5sBtDtzmwG0O
# DATA 3ObAbQ7c5sBtDtzmwG0O3ObAbQ7c5sBtDtzmwG0O3HZtwG1+UO1Uy2cFtwW9etR7jsBt+TXn09LbyFb1qrXmp/WgWK17zWrRr1YG
# DATA 9E+l4jUDzy/TL1XPr9CnerFSHdRbXlD3WmWv0vi0WqOrXjXwapW3fb/1abFZrDa8il8M5rI0avUq3fYc9Mxv1OrV2jLoWWux5Cpl
# DATA r1YO+kGjsl+tv01f8y8wYeUpbBVKQaUeeA2/6DeHxVrDqzW9RrnoN+hLzavVvXqTvmwcMb+6ELPABySu8WmxSoVaRF7U36MAENtB
# DATA lS7kaHG8kzP/sqjXqK/A3KkK3IknfMLuqVT6SoZ+8xsMkmNVg3q+BZhgKQAYNp48XUbWevJws5mv9r0ef9f9L8uhsvhrtUn1hsI4
# DATA JTaOm5HGxkmLtLBxUdCsBUEeG0c31Sr1HDZuDiQn2LhWt5Vh42qdehA0Mmxct9Np9zJsXKtbbZWjS8fGof2djI2raqNATAL9zAp+
# DATA HJI5518MfuLV6E+V/tSDn9hBzPHi3hnSVGJawFZgxNd7nxU76Ksdc3uaFJTLt+edeeLuKTT3Dwq8SrZiRUxFA/Cq8WebLhWUalZe
# DATA eNVJPhhP76fIGSRmvoRd1drFp72ceaadyqQK/fEDbfKzryiekoXVyYHstA+b+uXKAn6uvJovZ3K/YOfAGlPkhASyleA4co4j5zhy
# DATA jiPnOHKOI+c4co4j5zhyjiPnOHKOI/eSceSUxZHvAOIRhb8Le+/DLWlzlPAb8h2KMJwNbGJ+uPU4nECFlh/x5GY0rxt8garFm9hM
# DATA t+3v3KDc6AxLH9J/o7vWKfH7P88fw+OH3wun/RLP0Lc5nJ/6pQAhZMf7lhwaz5RvIcVlun2NmsuOrbhD1O4Q9SaHqO2jTe4stTtL
# DATA vUYv+dmesZajwQV91nfJSeuH5lyg1JFCXlnNHOqVA6tKkIXPEsOOPlA6zHKSN2KV/ezw5Dg8xGRaDk9Ca2VknZzcWAP5TVE9bgsj
# DATA qgsCFV4dmg4dHYHTPd5E97gTprNQyabh0+o70aVS1uLWD+Tj6nupg+0mCWf0z+Tj86CAnOXFKUUQ760WQdS5KiKIZJRNDrvQIQpH
# DATA +2GaKSDi5CQ1LyiIdxJ2m8zGY5x7xkYDHEbzJiILmQLPIYfZ2QtGTS0qedSqYxwdntPR4fGwOzkseFGYHnJDOb/u4Vwarkyi0qp/
# DATA F6cYamqy0qmG7TCZwYzMyqYzS/tUcyMWycUZdDlCHYpcNZs5mREBqxJ2iWAYUFB9cO/QRWTK1ErPgY+Hz1A/4C9ta+bJudSpswQ8
# DATA BwXzwcYF85CqehFulUNogFvKoXywuUAlMo649XCz0Q2EQTIoOOqP0HC0bijOEUKxCorh0ZhtQ2S4paYhggNY25LxLR70kxlLj55f
# DATA 3zWXlCsrpTN3bu9u2rm9F2PnDDQ8ZhNLGZkmKDTnw67AaTLWTacXT4YQJ52NPVUwyYQl2PhXUS85oERNkrZ0d5MIX1k3bDbqk1EF
# DATA dQNbxuM8RZKL+ZWViDVInrJIHq8uEjPcSpk8noTxQPRSQjJrTKHQ9ymME9hvieRwl6Y9MPJQNQ0NcxKq5qA0qwET1kozmZJEJvYm
# DATA IiyDQ1F7O3fB5KN//dvKo03bygcyJ6UJajymKmwKBrUbljNN3WWLEAxrHsZ5OgpVj3HK4z2m+eDRYmOuQmalohmuRMKnLGqN0oXn
# DATA 9NxFMRfjl1fr+EWQE9GPO++W825t4t2yq5jzbjnv1sZerJVOsMvxbrHwlgHghd5ekogonvZtXVv92nW+Lxxp8GwP2IJTS+im2DCi
# DATA 9iHrazlvk1qeYTTTCPvveaKqFkq3O8Md5fbSDVMmpShFCdU8b7qy7Ipx/VR4d+0EPTd6sWHMBlKFt1UPQ97yqjfyRmPeel3yVzvI
# DATA eAUJtTxR5To2qmV5P5m60cRMP7jgmvIVoRd2T/eW53ud4Wo/ll8K2IFAgcXRhO4uBbn7F3xZysIyjkLZdENB3NfyhXO9rGUmofwo
# DATA Cny4SKdKdl/Zpkt2SZp4LObZmMbDqWxIvylBnNMAEiMFg5HV3mw1y8cTcb8KMRb9wIJK9ID1GkfaS1uQGQPbcOwVCffCWHZdYUu8
# DATA YKRo9lDyDOQuq6cljwutwIOfBWRh8cosSOhVpto6xutgTY3jkWCsECZZxEaCEAuKrKCGQ2OQdGwfSvMUYb4QCpT2KmI62wO/lncK
# DATA ZGuYato60hKUrFeZyU7O2EI99Mx2Ab0nbsw2jMbLIqtfeMMzG2qc6elMz01MT2drvri25krr8BqqVfOJDnO6YNEMG1hm6FswOzlW
# DATA oJBPIlkmTLUVmj3Eskvc+V4/devrL/nKf8s5nTuvUg8637D0sUCEa45wNeWEn3VmUS6EA/42L8I9f1xPmmknwWRB3nU46oj5bfSv
# DATA 7vxs4bQf7+CjQlwQN7ee4i+clg2ExbNjK9oem4ODH4SHPH2BnrMxzO7xkp1MjkZmURD+xD0KaXwoy4sydwKNcBzu89yl5D3k5ayp
# DATA tqDUPco+Q62Ey1iccWzwzK91hVgPJytN0zo2qgTzlen+0/EAoabxU2xdl2VIqd5XDve4cuMpw5RRhdqPBnsz6i5sWNm/HH91/BvG
# DATA koEg9i1//jPQZYwN+wOIYvjl+KtFStn/an788ui7o2+BIvt3vvCH46+O/oxLBe/oj0dfM4rsN/iOG/h1x/9AfwAi+z29DiCzb+nn
# DATA rxll9h0F8D1+O/6CgvkOsLLjLzwK42u68A+4CDSaY5c9F9Yh0sZTL/hDWK5c195bIJKGkydY5QtHUQFuD5qVTnjuOA5l+oNBhmao
# DATA OCrNa0jQy/BmIw6Mtcln8YDZqNSiQ97NSRPLcCqQ1Ahb9akzW0stE5h0JAOlg5bZtqLVYVw1umyuVC6PXNaN5Rxmau58Q13hirpA
# DATA L8O4Z+6kSic1cXLB8DKe58cpb0BAc+CdYTqqjmC2WaldOMVMdza9mJ8LB+JUSjv9qDuTbSIDYcdD8oNBztyLeaz26vlBcRiPYGuH
# DATA A6rc2EdyW3t6GZ0hVtgkooAFpBCP0AWLGagsI2mTA4Nv3rRqrjZx8k3tWeHL1kbe0cucBXBhFoDmlp1+4H8pHERXOehf9Ji/0ZB/
# DATA yhH/0gd8qY+5xNv0smvRfC6DW5ZLsRfJHD0VjxRTuL2kl9+3x9kw7VMs93jdBI0uxj5NYxkx4mgYjjnh8lr0UXJugGonqEtYatHI
# DATA JNmvySOu1HvPiLOlG2LLOOdUpfAoO2Z4nQz4AIKIu+xAGwZUBCli6XVx4AcvfzJKDuR0RFdtLgU2ahxxUfeT2QTsL2ZQxe14gKyC
# DATA dcegFRqPGDcFY0E0EBjPZc4QKJDTKFkOn3IcM8cxcxyzS+SYbTjSbDTl2cA+vjoT/ywW/jkNfAcycyAzBzJzIDMHMnMgMwcycyAz
# DATA BzJzIDMHMnMgMwcycyAzBzJzIDMHMnMgMwcycyAzBzJzIDMHMnMgMwcycyAzBzJzILNrAzKrNGtBo3JWkFmvF/bKzxHILLfifFqO
# DATA WZ3ypFzr1+vN/Wqr9nZ9HkFWieqd3mJOln3Kylo/aDb4cxWQMfW5RhnLn5tNz6ccrtbKQ79ZLtK/6rOvP89BvSjnu73KMqhXpbkQ
# DATA hUpAUShXPvUbZc/3gWDzKn556sNt3DwJH9YIwkZn6ZuC+gIOzW8E4JJ51UqxVfP8eg0QND+gjPOrTH6rtU54Xadaby+nlVkQtSKm
# DATA AyEE+qVGe60lIDOKSwYyo0gZkJng2LIWUKv2GpWN87e+5FWVciN7VdX3L/FVVSGyyasq9cYlviqo2Klqli/xVXVG0elUVS84A08F
# DATA leMuTUPlpHe0oHK1Sr3a7OahcvMIuaVQuciPGt0gg8oF3XrUrBqoXKfeiToWVK5K723WLx0qJ7sLi7LMoIe5Ks8gPL06ZWyXpph/
# DATA 9jPzULi3IurM47CwSH+rLaO/wf/Z2D8o1MX/qUIehptB3kqNdW5NPT3LAp1fILHNe10+C55NVTK5cFjcYoXr66/bTerAunmn1+ns
# DATA MI/dtViqWg2Gs7JqjT23EOf8tOgSrUPHmHOMOceYc4w5x5hzjDnHmHOMOceYc4w5x5hzjLmXjDGHuhBPaYY/CaHFThXstsHO7d75
# DATA zMxJxuku1xPppfj8Mq5+ZLV8afi7d0yzj3vbP+JHVcPd+Uxx6bRyEcRQ5cwXI47G3FWLcXn7c3l1dyZrz7t2QD8V3B0uZQg85tLJ
# DATA ko59b9Hf+akf3PADREeHdkcCaM9ovohCNTFjuVlWoB1FUTcF704/A0ieyBCkRnupFx1IBzKWU3ki9kWX+ARjLjnIaJxi3NVm/QQv
# DATA lqySxadtntDtlGTxYXs7LOwXYiqE8IYytPd3frodU9Mov1Yv3/J3CmVs+uJWj/Wn3eHune3hnV2/Viu/9uHW+1Ql+Yglh4oMUoYP
# DATA 51NvkNCcdXizXt75SaW2QzOwLutZbVcKH26VcTc/pp8Z/oRuXLzpdlZzJMtRA7ZTjrWqOnAe7XL8tpF6Rg3+9y/+GRmb3saVG7vL
# DATA CnM7fjVfiK/5wa2yzk0O9fbnO6VPknhEzzK4UCKtPt5Y8spePIrTvhJF9QNdmDgtKw4XASD+fASVCcEB4HmGHm7PVZiirhU7drWg
# DATA xsP1yGTLDkXyNhc4lURRzyro+dfWmYzc8tB4snA+wzhIxpA6dKyVM7S4hQ5ZsxV1pTPzLgpcn4cuTZ+in7HiKGE/0mHqh2jARVgG
# DATA 06gPojmlCKcUsV4pwjqm6PQinF7EqfUiVuqUXoqOxIPZNGsAvGtLa3rKyG5EJa6jjNFV6NiLsSIy7hOxYuaU63Ep063X95vOy1ww
# DATA Qu/l1i21YK6E61fo0asBlxXppzhZzjwkI+y9rUbek5T0TTAmStmVTEm/Vl4mpV+1pfQblbKtpe8Hq6X0LYMG0eeI08SEZlVcrfJy
# DATA +rmbrXyzg1hQy+eY3amWtf2xWle/xvGsBSffWecw60vCXNDe1wcYKd18EPGOMoqFGYSWQ7fKLypnMiYUJg2cpny5acfHfCbkyum9
# DATA bDzjoVAmIHesy3MFcjGvfYhxk1u8/dbs6uW8VA4+ejTQTqibyL05/1OG98zKZSUdQXoyhQl4fpEI78K/J1I3yljRlrytnGE0Zro0
# DATA obPs/lwnz2YQhD9ytygBXqrCrD0DyRnW02C4AYs5aAbBKg2avOiMTQVb5H8t54RJBubmDxgJ9QoF+7b0EGRDwE7kGzz/4hZ5C8PN
# DATA S9y85IR5Sc7+dFMTNzU5ecbxTCXuMMajgutIIHMGmcrdm2YiIsAD1nwybY1KL0xZ5AqCU6w5ZkSoCqKcNgzFcWmE0LRYw/zkYg69
# DATA gG02NvZbeLS2ASZ8zQ9EeC4SwixcpWjflBiq0KmZ0jCji7In/XSGaO7xb7P0kMbcETO9KIHSWRQUhEimR3qgZSA9dxfpEx3ouJ9M
# DATA k71JOOahehzBkFbyvvGEpcckiflhbxoyVvm9ZCLKumqsm4ebCiLZsvwktWKOWDg07sjQtx0oDDK2CaqOTXz3WJ06AIoc+nB3hZ8m
# DATA WIl+aONF4SEHYYCl1uDbWxf7uMtW3drIzxuPkgKDFBCIcGoIwlDxnxrQc4cF4RT+QmsSZ8p6wrLNa++pYmmjyxY+gdVrh1J/16Tp
# DATA LnbYjxKQW+eTJWZCnhu7oKpoKjKZhQ/g3ldvRr6S2dYHwVchGyQL+AcAexF5rCV3WLYNRk0BlWgkSQHzDt7bZJaq/FABx5QPd/eT
# DATA uMuS1KzSBoCCZCkNUAkTY4eQWhvzSTfenbJ8Ss+x/huhiSgHuEzKdJyxoJ4Trk56MguDDt1wmHSlcaPw+LIpK08fnkt6PfjUddlp
# DATA DWspw4I3nrXJQrGeY/05boRhFxaQN+E6LJWVxi6GF/MrPZDYadAhSzulNrkuiY+ABldwrykGESuJIJTJC6lniKHtRd0dpXVMz/dm
# DATA g8Gh4q2omLIbJ+WKKuke5kiFrCwofcJBP1HqiNRBYicoFfGkj3YoBYY+fh5RK4bpi2dPO1qYs6U3VoN2pvMLbTqflhX2jNWh7T3/
# DATA 62FhjzESaNglG1VS39fTwq6PmvRzIal6EkEi2/evWV4XCRXLK2RfNFNsXnF8KVJMud9YzRuFyrvQyAiSGpGKWZMMbHdoNNad2J33
# DATA WbtEuGI0VWF9Ypk00fvod9zzZpxZzug9IJk9gl0uNDKqN9m9MjOBTSu70xNYeDGkyA7VTTeTwarmKfYy7FxUX55ahMscjGsxIXDF
# DATA GpLzgv44LDCWIR5PUKPTyDQzUXAOzXRVttmQYT/EXWTn5rytZHNDtNjWQmdLm6eQklMzFiXXBu7COtuCrfeiWXkZ1uwgaivxa5tq
# DATA 9r8cfXP0r8Xjvzv6gSlj3x59f/QHpovRp+O/Pf7i6GubMHb8Fa4sAs7+T1w++j09/A0jyr7x6MvXdPFbuvw9yGRHv/f4nj8y4+wf
# DATA 5b7j3ymQ2dcgqdELvqJ/f6dAZhyfrxGn478HA415Z384+oF+oPv/5Nhmz4stK40cDU+Lr/OSlSFvYh2I5nCiLs6Tt4SCm6LVI47U
# DATA yn8OlUVmyIv3KNlnL084ybxKFgkRzWMtyuzt+Wg4nJlt02YdxVXTzJYUzOURzcSnki68XF2fv112EJi7H0YpjUAdGbC5kC4YbSbu
# DATA JdHzh2tFFv6YWuDAZhsV3oVzze56lt55NjMwNYAXjSGkMxswhaN9iL9xmkK550A9kQiKnXPvwc/pftE0L2hOhd7vYiAmbP/sA17s
# DATA 0cXBAs9sw5q52sZZbHbPim62YVIc58xZA2e1BjTW7GxGwEvh1LpCA+Ayxv+Nhv/Tjf5XOPhL/VzICQt19kxa0GWQzRYSyXQzyqp0
# DATA MVpgnMmyskfVEzX1loCeCt7bjx8/eFRQB0vVyjCXDO8ZnZD9wCs7nAyM0HBKZDSliSpL7XnQearH3E3xZqYqeJTXUAbLGwBIWdwB
# DATA 5iwzAvKAs/Ek6sI3kjcKbGOgwM0UnYUHA2PUUeYBWwXgUIl5KMgpjn9Kr8noZuxUSQ9TPkqp7mk7vpnjmzm+2aXyzTYbazaa+JzK
# DATA QL5ai/8sBv+F2fsOe+awZw575rBnDnvmsGcOe+awZw575rBnDnvmsGcOe+awZw575rBnDnvmsGcOe+awZw575rBnDnvmsGcOe+aw
# DATA Zw575rBn1wd71qq16vWzYs+qvUav/RxhzxbWnzdCn3HmqsxjSpjQtmqV3GExv17J53pVWE6S7c1cxnWbURD15vBN1WYQCKprHt9U
# DATA kyy24iHvlngI+yqLR3X+0Foli0ZtHlu3jBdWt3hhfqtpGFQ5Qtpf17pNv1FdrDnNGlWdZl/qnJW8sN5udcKl/LR1yasIKe2Sklex
# DATA aF4bJ48eurDkVYXxdUnJq6qnT5U8euhcyatWKteikVSrzctrJNW6f45GUm2Wz91I7ORdeCPJJe/UjQTJO28jsZN34Y0kl7xTNxIk
# DATA 77yNJPCb16KRBNXa5TUSisU5GknQqJ+7kdjJu/BGkkveqRsJknfeRmIn78IbSS55p24kSN7ZGokNbC03vVoQ7Nfq/Wqrtl+s1YdF
# DATA v1X3avX96kkA1dWN4Cw0TLZ0DQ2TjWaLhllt1yvN4Cw0zHIU9nyLhlmtR82aoWG2O51ut2PRMP1Afr5cGqbazCuzO8vZo5bdDB+T
# DATA J+xkottOtRavsS/ZNpELFfPXxXvmtyosLpk1ecms1MRWGVk0y4WqFszXhlzn1bP8Y3oWuHyzYXY3zSb3JuEwt0Z3UnLVM0uW5xdv
# DATA 0Cv1C3m+eHfmRVy1Q1Je5EsRiStgIRAsNSyiPlW1yy8XtFoteGBOB+9kj9GSVLHbcMH3vLhdaCX309E6Ha3T0TodrdPROh2t09E6
# DATA Ha3T0TodrdPROh2t09E6L4DWuYjm3IvbCqCI1TmYngqOqRlUdOWmX641g0b9dm7Ooh7jw8N4TCMOyTCfjXHlho8nK7Xbio15Xx1j
# DATA h37AaNofHBrOFSMSKSZUr97E/v7tCmMR34pfF6TiuzhnLqeUx4NZ6kGw2VMv4mdVlFY9f9erBD8xb8uEdmReSnmwHzGqc5vi8FOs
# DATA 8e8sC8lmGVrnTJ0gjBOEyQnCLB46duowTh3m7OowK5WUL1M1RnfWkIOQ9oLiYiUHbLThnTeWhMz10TG7CqChDJUM+pCBjFU4+OoJ
# DATA IEH9ZK6bT3PINrgRloIEfYsjyDeV9Z0GJ7iaJmiGc7AE1WeEzYIlYwyKOgne9t/Er58ERLSCM0mxr5nUBCenpXKKZIi1gR4AXlEx
# DATA CbbfOzm++jkTWXPBiulmmb5hTLUdxO0UQomQHMnsFuq6xnF0UnXJAsnAk9klE/XGSTGvr4n1Ssif6QL0lInHQ1XIzz30bxnpz1iI
# DATA ken90DNRHROWBzePrpHXgW3ARRoOeQ7AyzMsCKPmmh2aVLFaNENNsDeSpjcF76BPlY+Mw8leZIWmcrfXo762PZvAt4HnaHI1iaDQ
# DATA FE+1wI/yV8vMI2VZblZioip1KAYy62Da9azk3UuG7Bajrq+gxHpGXaP/lIkuqclcV54IJ0oXKbNlMsjskOI1m7BvVYkPbUANfNGU
# DATA YhzzxE0EVkwEnM3/Utj8pyWdXBelSHunxHrkyVsxj5iilsjr0RCJG7FqD7WtYbSWffLs5CWfL3W1k9Sl5/Z4XAb4ZFFA86LhJ8t0
# DATA SJcCUHJlp7fESEVeBvh7E/a8NhGW3sGqnmvveF1Ma2NonFLuW5H/GFcZs+AgQCKi8RlOpcyVubkJDvNRNu3WeMW3H7/3bsG79+hR
# DATA QY3D0l54WFBa7oBYyrxIhBbHUAkNtZIqKzVSKRjZzzjN5g0abMcNPJ5i2F5DVHwknYFseFsPi7xrRUJVYp2iu1ACHSl5VI4dJ4gS
# DATA 1o1A84tGHSiCjiKKn9JjLVDtpera18tsIs+aV2Vdi+bMdyAnRF0Lzoo1raOtYIpscKsDhpH4MwRGCrNftO/ZgJ4cKklMFcuS90Bz
# DATA ahBzXh3THVno9cJ4MJuso1k+lGCwcLWKZ/kSWeB2f+1scGeDL7XBVSVxnnjnic9ZdyuN9+uj3851GiN1hnMOPfEUGg+8+GriFBv3
# DATA Eh4k8+Lj2oU+Tz+bjYETLHm/wB7xQ4NooTu6sw5EZIYYi420sfG3M9GY7Z2Nhdwz3QJpnvh651Vt+D3CMW9u2NCvSBUAW2Ycqi94
# DATA 9aaxEqfSe08n+CjC3HhVR5z1ZG9MEhqDqWH3l97wcxnTe6A2r7jlA5hsSKVocbPYNG69iXfe1O+XwWg+GspQVQacsXj4Td07b6jN
# DATA iVyDCx6GlR71/QmVGWM/qapNu3ynGiMKngzGBS21Dc4dMMVpX8LtqmitiMd74YjqVNe2BU1k7mYS+HO/SxRs083YX1Sikwji3bx4
# DATA oC2vkyPyi3gynUFRnaXErTioAmYzj2srS8pznzJJBiYyPxuzooq5gSp5NGWV9DEPnpRBg4Gu6qkVn5uqoG6qSreCS78e+/1I23lZ
# DATA 3ovJF3aHNOjrWU7G9tFK4orUnvaT2aDL7VLM2REsP2w8x9RK1NWlgEse25dkAQ+SwyEHQfY5eNYhxOEtGXqw6D9J2jxwKon52YhZ
# DATA iCqkdUDwUXKg9Mq16RxO+zr6H0xYzp7qvcfiJuLs5vUW7TdmpzNZ4xRMqL3N6KWos+N78AMzUjMbF0goQBb17TwxAql+BAc7DefR
# DATA SN/bVazHbG1wXWLeE1e0Sk8o4vnwqxv3vvKsI2J6PSPjKvSjwVj1Z7LgafVFLINPA2WSgyqMo/AJSlh6TNQ9rFl2oyFeYM+wFFiB
# DATA QpH5IGPh0QrsqZmyY2zwuVn/RP2MhxsyxF8s2/7zzz/6/MPR1it/9aL/R1kfDT5GhxGPZoCqjg8v/B1Yu6zXan+l1o3n/vXLQVD5
# DATA q3L231+Vfb9Rrv+VV76KDJihzdHr/+rl/O/HP/7xw5kQIjrUgcRdHmdQKbZS3otcZOxHVkG8e+++Q70GL3NS+04GXV7CpwdKFNYr
# DATA IpVCtu0eH7bR3z8h+1B/TtJXePRCpz+I2566/IC+6lsm5sF01lb+GX0FR7IwHOjvMzJdXnnlg4d3Hzy4/xAbqLe2tl7hMzavqA2W
# DATA PdlXzc6mbZpMdqNbvXRrh3cz4mTIFhh8N6lXvAmq783OIKYZzNbtV2SrdS8tIR/g5nt0OOps46GCt0Xz9eaWtQN1i51CRYRezHJr
# DATA a2dH+5dK0dN4uu3v3H5lft9nPmp8juxj9RC9gXrHgxG/OQso6iC3Ct4vVWSWv/ujwiue5302lVMkt3ze7lAYhk9fn/Ww99GvV5u1
# DATA whOyMh/Fe6NwcGvr0Ttv/c077767VUin3Ti59cstuk7Dw1ZhaxyP8Y/6/tHnOyp71MbUaDKhoefXv9YbVVMO0L7Ai+Wy8XV1lsge
# DATA 4t3caS39fBdjwTRRxypU/uto8IOvcUEd8ktwMAqv/5EcHirF6aOwF71DdtEeDing9hLy6x5Wsndw59w171WvvOzyHT5tszQN+oqK
# DATA 6wEMmW0V3/k30v3Zqa35oLzPX0ElfuUVmkLDTfkx042241E6plH4Yyl0nvzv3EIRIwt4BR2XYAPwhxJbEymmUNtbxa0d/DCIRtvy
# DATA ICUk8Cu4hicnUQn7CXgb8fZk65d3i/9TWPxVudj6uHTz1v9Q/OjGVv6F+G8SYir3CyTsPop/e+ud0T5O+1g9CT+ztcPPqIF4l1t6
# DATA LjE7OhFyC1eWbar5049xUpdiWvN+6mFDr/pnfRw4XC962iFbN5WJpIoB7M1JF70B+qMS737YVu9E1fkY+6u3d3ZyeZpSTKfhqIOq
# DATA yI8XPJweMNmpru5QtfP8jXJHTXUVxjSaqNjp67s6nr8sfyQ/6Bux51tu4kOJW+90qVi21OPRaD+eJKOh2htu30fTuV68R/d+9vmO
# DATA XLk/2pcjQXZS5ytBWOxRDfjos3rtc7rZxGJHVxora6yXz2WP9cuOajznySSchpYDLvwVk3XpNOKRnQPZKxaLke8v4OgtR3KL7Dw8
# DATA LcHwhcn8hafl8tyl3S21Z0WuZe9bnqyfj9LZGMMVzS6saKpE4T8+7fkxpUx6Ct4xuE2vKXj+znxilrfWjz+ymu1HP6UncWr1pJjp
# DATA DLerDz1nxYyzvETDYzTqqgOopr3OhtsoZNxSoskGdW98zg9lj3UIyh5+GiVfCeobNN/7VjSWNeG/xtoSHBveUHG83kg6T3C6Bv9Q
# DATA 5aMHJ4c8fSrIfLnD9REnGVBw6JQFpkemf0kFiR1Y1PcqWh5sGcxpmd6nFoluC/0MLik984cPmiVDMV1M+yH2X0lzNb3fLkV2FPFF
# DATA cWQp06X0OILtEk4O32BhwWRyyMJ28dPdLXrxKOzMcKDcjOTovGmq2tU3ZxlIpfaxsmK4VzW37Hg3vS27pplHtM88QXeSpCUQwrZ1
# DATA OAVc+dnHHzz82fvv/ifv1/Lt3sP7dx/rL/f/x3vvFrxyAqSHCZNTRz/3uhxa9grqng4k8tTconCYr41yTQ2UaIelT6jgtlWVucFN
# DATA M3vJ1E44Z7Tiqe1aVmKJCmz7l7nb8N9Wl2sJukt5Cp+K4t7FR5PrpSzXd3HYC9ZlCX/VaEDqR08Li0EXi6pKcOi6v7qFp803fpsx
# DATA p+XlNM0udifJePcuLK5l4aZ6iYbs091RQu85KGLmGwMkk0ooVHJFlNwW92imIHeWBohYUhXBk9rm1aHoVoPvMFP0gI+f8UUZ2Plg
# DATA PyrAWTCdTaKPZQvl7uPJTB281h/F+tytlguybsrXd/IFabUYVajaiIKfarydv32z4UqHOdcDrmyhm3WTbIl5MfvEpnYvKfaFsujn
# DATA 66NV/dgok0wPp9Ow07fj+tFiqS37b9M899dmujqZlzewN8/vD7uf+YVALAO2oWF3jqbb6puyk2+dIm+tSaZEaiF7WQ4ge4n5tYct
# DATA H4O57oGibTJ2MRprimgylPKhYawT5YvHk2zatZ5+4/4v3v/5u++eWHL0JM2Slj2ZlVegi+tNCDjsqBkARqJtVY15UoSeW8+wS3cn
# DATA e+zVf8C/qKKT23CW7+NQ/U5zgKIyuilNeu+FVTFWPcMm/NIn6DbYYupB/gePpioSuQ6bz21sZ5MZ3FdS8Sl48o0nGMqafQoMp3ef
# DATA /4EQqwnor9WIf/ON1z2edqaMBlVdre2wLnk/w6Adeozu8bB7aQQvZcej8Skck1EzZ4g8Yuf+fczCtt5PsI87q5Ed40Nv8/VePBlG
# DATA 3S2UEVW0jz+GOfAx2W+73tbHH6PEPv54SyItxXdNXYkTnGIfRpfh9tvM/1dplKu1ef9fuexXnP/vKv776x/dnKWTm+14dJNMB298
# DATA OO0no+orP/7xj1m4Q3i1WHyRhTGsMWDFF8sVyTjS0Fu9geuhNqM8nm0NBtQtrPEKYpmiXtPfsKdJf+6HKXyD+msMfbCJ5QQ8uz9R
# DATA VhDN1/5sGg/MN55DmG/pYLUXkvLDOCTDie2PnPdPTvsTgeGZC9Tecs5Ljv1sMqDISyeqk0DXeB5IfQyvo3gykZ9JtsvomQ2kaoSg
# DATA /L5r93Wwrmn647UPuYhMwbDRjhWVSfRJpJYCkTcyAU253PR7fz7em4Td6BcQPtAvXoyLGaIom2TkwoaybZompZnnSHraJQnRt6lH
# DATA WcYHRaqfk8HfctzwhIfvsJw3PAnFBtEt3lC1taPDk0nGmN2mygOADT+7MpORd0xxMGaq51IctJ7pyk+lOP04PRxiv8y2ZVdyMreO
# DATA /vejb7yjPx59ffTvR98ef3n8T0e/p8/fHP3FO/5b+vCnoz97x39/9M3xF3Ttj97xl0ffHv2Fbvnh6M90O3748ui746+O/wv9xE//
# DATA GV9veZhHwLKXGKjhUUVHzj2WhjDqt+VLqmxAns9+nNiWHy+d7mp/SW+VTyQi00PyuTsbjlP9WzTCOufHYdqJY7FPsOUMY+1uRU/W
# DATA xCfTLfDkmNWd1IR3+ATdx9jMckvZNJdMC4r9bi5FS+yHuSkmXkJTS0QrX+BYmj/ADHKXZ4+rpp4IqdOnGrCtJqGI5ijZ3pFqsbN6
# DATA nopcXPpzbzCDEs3Ca7BNef4t2V0JlhcYRKZFq6ScbZ8P3cMZ+iMyLmiGlk+JmfJ/3OtaM/pcfqpp/cM37Gn9G+88vH/v8c8e/qd8
# DATA lBem2bl02G/LP7fUBlfPMiZ+ybMLz0hi0fJKXIFTzpSdhbKbjbgN8o+qgcvasnJQGbc4vFNKkQ0uqOoKh/f2a7cy59lHuW/Fjz4r
# DATA F+r+59bvO699WNq5oS589Fnl/2fv3Zvbuq58wfs3P8Wxk9sHkADwoYcVKLCbkmibbYnikJSdNMWgQOKQRAwCCA4giU2jy4k7ndyJ
# DATA K5l0paamuqq7b+rOB5AVq604tvMVpK8wn2T2eu33AUDZTt+Z27m3LeKcffZz7bXXXo/fqly9BPcgu2mLLfyP55+r7f/vapP/DBjE
# DATA p2rHf6FYwJfJ80+QEzz/s2IJX6mXX6mCwA0eV9Qz9eRD9exx8vwZlPhI/f1Mq7GRFZKisAtwKCWZBHVQaY/IJhwfsntBZWZNJV/p
# DATA PN0lV7ybgsdoXl9cBN7D86orgK2+2Bp0FlVb6V58npeuLAXT8H88/xRYn+Jyj4H5KYZIw1MjVXOCLFON/xm8A4b4S5yML2C+1M/n
# DATA Xz7/UrHEp1rXra6pqAd2tKWV1NFnLyffb7AOGouX4ffKrPWB3jyD1XkGDUP7T6Cbj+ftvmHxdBa8+M2LnwFb14vHOgJLg43aF9Jg
# DATA Y0dt/d4IMXrw3+ByrsZJL5gIHIuPXkNv9zhV7l6r79nVyWyd0gXe1tXGlvKlF/KP1tVesH78Lbn7o8W9i+WS2oyLZu/Vmn9fVU8v
# DATA lBffSFnZG6jHqUJw4+sBqNMRKpPV7J6lNbjY12rphDyAzSv8ZHdlTyhJzVp5xtD98dadrU3Eg5EfVUM7CX4Hm/nFb59/UTEcQHY7
# DATA 7vzHqvBjqEgVU5zh+RPgAcwfVOUy13968bGisK+APIFy1e/fWLNKQIaxnUxjXd6DnSzjtqcQvuz0mFCnT8KMvYAT8ie1tdSSJzio
# DATA z1jYUT1+8bGScuwesyKKDQ2AbGhzO3obY3M0rPNxunNtfb2s04fLQwGuSyrAGZwYS8MvtGepIrAZkTB5BeArzWCBlhVZwnM0f6hi
# DATA +G+jEXLoQ3nJhfPwUPo9DePFR5FV+/LFR2pOkIzhWPoUaetj2rfx8wtPp+vOO0XGasKe0kRC1QHJvvg4oRLwUFMCLzd2O7ba6pZa
# DATA GvXfz3ru+hYbsBW7uF+b/ltxBbtKX6Snnn8EnF2NbHVzvWo24xwEwSMqpaubm83Nu1s7jUtLy0v3e1trdzZW31t9d625ubqxdrt5
# DATA b+t2g9PYoHT8sPUgq18C3Ide6uzC1HypOtPcufvO2gYaK3AQJIqvb+ysbW2s3m7+zXs7ze21m1trO1iE7781LNo8zh6VLoH07tZ/
# DATA v7ezdW97p7m5dfcHP2ws3+/dWd362xurG83ba2+t3vxh8/b6xjvNtY3VG7fXbjUQaxYNNbRacHP1pbDYCqGunjXIcL9haFsR0PDw
# DATA BpUhSxXq19UrVy5dCZbo34h3GmZDpPniV0RhioJVXfCSvncXxTQgvSeHYFTnzTMKlgh3NTGBsLgyRRpUFAUHouoyCAmfK8L5UvX7
# DATA KfCcL178hoVBfvNYdC0RwY/7a5n4SsZCX3dFjbNJaCzXhae5COBq7O458jmYvuNmbzRhH2h4ummGbNO9XfXVHoLZ4XeFLF/cWpts
# DATA bCtZtrVBlg1zdcd5kA2HHXWnT1OjCyEUSVR9iOW2D57FnQMKLED8Cu0zKzw02c/AgZi0ICikgDq44c8aOL2GM7dB7dwBK5oWSKkC
# DATA OJHVN6l74+F+o3ZN/3glLBucXJ8hk1XnkqIcxXOeEsn/9vnvkLPCI+C1wIo/BVWE2gpKAIFKq1L6xa8dVu0cx7gI1Ad8yvOXh/PA
# DATA I97ORmBCzyOTkRMtMSXyZpIKw3M5QaHxS5Rr/gidA+nBO1S+5AHBP+o3+wGAmAn7SG14JV+oAw4+UtXBaQUT9tQsSXze2a2juG/z
# DATA zDwfBZ+rvvyazg3uRDAsOoH9BWBRXDpRBspZDi5qPdB4dQB1VxdUfCy4xGuibmiNYinON3bTW6s7qzdWt9fgNEr3yjX51jbKlN7J
# DATA TlFnV0kC7aPXnrau8orLq+hBq9YKyPRPuHLAupEZPiUBBGQ0eGhkaVpQJVkq1vlZ4nTcyFbcD/lTX5f1xQNvkRaDBF4C6488xdmm
# DATA 8ET7XeGKeLsAH3MV9AQCcTJ7N2yRO4kq18lxQkA753k1kM3JGKXF2AyWtqy4rQ01PGv7wlhIoaSkabTsw6hKVvn592y51iEkz8DA
# DATA itNbuGMKh4TGw24H4X/U7OOfsjQUgAVPsMPSe+rZKn0kB1PZU2PiZ6TGnMQaA+MmqOJK/rShT1darnXpig33P+mPe2ixHYL6TQ4X
# DATA Vv8wTYBUZQ1HPcfBpOubq1QBXETf6vb3W931zQdX5aHXazU4TcPqc5kxlu71Y+lSOPFM4QBVzgG9rGSEpATlMk6HkJetWMYLDBSp
# DATA jXtK6C5dkIrINgA+XnCk8f5BhTEWt3kX14SKhGJlkNnF8cMKmeRPSTGm7gmfo9L8WfR4wBd0ClwXOeoJstiP8Xpnc4iE9BNPLa2a
# DATA dSA4215mJHZI8Ay8/AkNHVRT8VuQX4tOhwLuZp0D0i2b03K3X5rRup1V5aiAnrancBe0Dq5a8vx3dPI+wa7/El/8kcf6Ga/qH3El
# DATA 8P5yE24Yelwbazvv3d16x5OXYlMs6Tr6PF7+naNzZYmLl8F3lgTHAxKhm/aJ5wn2LBTneFwFLRmZJTSYQERWOfiCBPTCj9A/tr4Q
# DATA eA2dTRzurbWCEVE79GrF0sT6Qj7Aa/9PCd7D6Xr6VBtybddPR2Wjb1EoSX2Id95nyTtrP2y8u3r73proSdQDz1MHbwI6/7V9KSB9
# DATA JcTQY35duBhEnY1UDVOGEe35l2hk+xSFra9IK/FTvKhblyvWzZI2By5ef0znuJSgq6uMhtid4zbm3ldMT6dOsHdNVX/+73ztQ20p
# DATA Ta21XvjUG4D6+uf64i0e9apntuFUYiqMQXVhql+0473Nl2/Xtd26yYKQC9P4GbK4X4iOKOBjxI9hTF/R0NWgfhO51ZptC5ayZn7c
# DATA Wrly1R5Nu3ME0YwN8RCocZGy8bK17MJoCUuH+3E7IGyyg+Nx733YZChGd1sn++1WXSx6mIvBijsoV5L91NenU49qFKNcwvqccfH7
# DATA 4+wR/aVtNRSJ2oSBqCPVeO7y5b3fH4VevWw161KyEmJ5A5JbUWcLTs0wErAH4xk9AJM1fKB+wgk2MJbE7bdX1cxt37uzbbguaBkH
# DATA jpV7jggR0qBRzWXTGezmXAoQJBpjJEfrCRL6E9qjRFBqI+jDmkyxMNxFexwQDUE+xA75lC+mSZJepB5eRId/r5eyJg8QjaBJS2Pm
# DATA vUKnSA+M3SlFx81eJnQQF0FK3y+G/YcoCgZ9t70YyqQ2QUdoW+ouNJWodWhVD9H3tZwkJW91yuC+139YbCgRMwCK8dDtqERTuHLC
# DATA pL6yZBg8Llht/OLncIJ8pLjWFxa7xaSMDZzBxZgdAq3AMVKUF0zW6mnALIDAxc4RHcs/+71kCY16CYr+aVRYpF6xRofTiAK2jE24
# DATA AoNeqfPeeIvXKA67Bm4X7CU8yvyH4uqd6ycs2zgFtbSiSRbVTkS1ttRB/cAupqIAQ5cPMbJ2nUrQ+QBUWv6Ovtd7vwfR+hr2lb9I
# DATA veAiHvf3Gz6JWeSFqnZZDHcF4JGsAJ3lvtIEJ01OOtpf4TyW49ODI+MYffgE74bWUIqHv4FwJ/CKO0DzkLrLLedDKsnhq5A7Yljq
# DATA EMPsIPcGtAaMp8GKdmV5EWEu3SuX41Vaw/UopGzua9Ev8SgQRQH0YNcOGeFpAzo77KieDdGFl6veo+hPaBXZvrhrmOA57hKPgbvl
# DATA rIT+pogqp3xrscRe55BEAmsi5vnSnw3QcexyFpGUDHGYlgYvIdTILiUdodFTeRxD1k73HO4qHxAdAXGgKmirT/kDfRnCHTbG8SIJ
# DATA VIf8gUe7822o/5sPVGbJ/6A41x+UUKyuyi/+0XAxUlUqZo53ZSWdqesoiKYBH0ceqDkkic7uFWvgnIKuCYS5PR6UbhCZzdJb+3m/
# DATA C/nUrAniL3W9i/BgYa5DQknk/e4DzBSUN4dZtzXqPMiao74dJwWCgFMWTaphqJUj0le1tDJFnv8VC8TGAZCE+CdgYcWZRUUGWO/x
# DATA Mv78D3Du0K3lMc73E8uMKIOVTYPMKjwOZ3cYj67fqLrVbR3v+D8FdlrcYVdMd+dqgSmgl41HwxYASRAliEZCybUaSwZQhGD+jW0G
# DATA 0ASPehDiS3mUuq3TbJgnkMk1aR2OAMe838MEsugnep3BWigIndBWdEPaUhNzsDH8TU5M+a522jrp2kepeUHPKSykWvhd4Xv1ei8k
# DATA YoOss5hovbq/EQqXOOJ7GtWvcmvuvrQWwlwDLcpCXSKu0IzaAw9BXn0MBVEd9cK3FX+65sZv47jMfRQ23Fkq6ElpPTmbGE2I2Bzu
# DATA bk8zObi9QO9Uf2b5daFk+xgl2me4O0Gq1W7uovNDaQO2yc/ZUeQLUDM80UYeNlA8KeC3ZGmj6/unqHMjtSXy4qeOIsL1hDGLFbOL
# DATA MmiR7LzgHslSWfyKYh2eVG7aybng3Bz4fIsd4djJ5DsJo9oSLhMDDXV6VXR21dPL2F7qPv+AQJT63bZGbUJyWvDP1FlO2NFLCgj1
# DATA qHb4B1Aov/iZdKAa3C0p+l7kCWmVXajN/uUZxUIyeRFxczfVcw72NMM5eVTUmlMKZE2QDU1jrleEQR3Q8gj6R1y6NP9sOMdO8VyI
# DATA qsHipSITeT0wTWsv+kL2Q5ITPLbFJqMkdJRroaRVnyM6UchYi9vob4IwFo6YV6wsneGoUThl2ktZkKj13nJb9gch5aPSjP0yfu2V
# DATA EnhToZbojT9f57kEh4Oc4+brrqXuOWo3MP+SOhsQxzsrSZCGFcjZNVgDbELS6mNZO1D9w3XItjad4Ql2yMJcJWkCmIKodyY4KVCs
# DATA QCf1OzXiT9D0QUajx+KmmoTi05NQGyUJQV3i1Zt7jksARn2SlVbIBQL4C28C9u4w30ZJx30dJx5TBmdKtnbY5agyZdMM37oGS4cp
# DATA WFJiffCTjIC2CUZ7fGLrhOyZRNZqdc01xkvBWaxz/h6zzw8AHLbUzB0rUdPUY3dy2DlpoQ91sYBldY+LezdEqYQtidPp9yVmHbAN
# DATA W71kzMoZOW6R6bpeAsLQ7T5T7h5/ud34KNqM9MweXHHEFJCdG7nE/5i71yuOjBzXPd+3ooesHaIBAC6h/53bEOmmTfuiBd+4e2ut
# DATA ub2zurOm42HW17ZxxzITRXggOGG5M2ZcqGQvYq4zlofyNrmpgFOjJQ44n5hDkR4c+7S2UfnmSytOjMNlTjo5gFW7UWGk6svjBkb+
# DATA Xl9IPL7BsUowkZ49hnsloDA6Gs+2g4RTR2r96OAbOAN/lSz1X3vtNXMj1rNsB4hvZYQiwcjB2YNOf5wn63dW31qrJOOcEiOAP+DD
# DATA zEoX3Rux7k9tlgGgYVo1EtJd8pNxf9RKfqxIAg52XMiHGBc+zNTUjjOMPu8gahFk72rzLRbDMsYDE27OwYjEAirezkN3wj13j8r9
# DATA zC1pawfdycSb9Pw3QDlI8Su1mNyzogXCcpXgzqZ9aLutXpOAJUGv3GRpvkRDq9AsQ8z/wXEH08BbrpyMOcIMod0AkhbFAf+wVJRN
# DATA qhJf2GoFuj2YXBPiQaVDXtU2BCqwWM3DDuC04Zo+bA3bRp8Att9ilTCp1THYhIczrVwgePwTumDYCp8/kXWUIsUei5E3QSntqbp8
# DATA fkSeMZ6WCP1EjHr81wU+hZ7FlydbkLAcCLkYUpziw5TsGZhw/gHAYn1w/7sRaDjbe95xLiHVIvTr2fPPyIoNSiglUaMh6aPIVPCF
# DATA BS7eGEESG9oDCkzGfO96qfhh4ej5vTv+mJf6xdIb9fs1+rN8tlyhYD/6ep5Bi/snOSP9FM0X8aGSmSkcn9BW0wzUJbdgrMEX7G/o
# DATA HhHhpPjfveTs+NWU5zUokpnHninX6TcifTN2CTqtkQGfPWYSxXOVtFsCjwZ1jx+UEBTMcUuvqSMJ4qB2l/aSC8nl8m79siemQcXB
# DATA rMCeoDdTx/d79oqAa/ZjJGFebo430iMDvdGnpE3igYPvxzQL5HXS2wOn+HfNMRRJ/Zw2k+OF/Ckr9p9RQDppfIWyDBZ07m4f+w0X
# DATA Vkdg0/vAJcPIN5Jlxy/Kz1ftLypBC8aa5NOpVcjyWcHcA3YPmZM5dTI2kXrnunb2Tv1W2Flyyg4wQcGuzR3g94w/hHbVdLrhtY+G
# DATA PzU1TiF9c/U/9TeuP3NmUs4xSLuvwVL4VfnomLSg1mLM3xZ/q92OYBrkmZ4Bq1A4JMsPOaDSWEvn8EtxvBsoVvsfUYf4U4rN9PhT
# DATA YMB5quMJfc5FuRWgv5igw9l+8GSbxCuAKnY3j/OSbN8siZHTmpKJqKAW0NC722hSOz2ZLX+32O90peq57mXBLAfz+a9qfmgKtPfr
# DATA nzCw8JMgkuMrZEkf4X9/9vwJyzjnncvBAL0qdinZCfumNxqm5+i4F9i8mSKcSHagP6rQkB//1oRtUVwhtfE3wdz8dzWkTzC48vGL
# DATA X7/4b8y8ZX4kpCGqdfszxbWoClhqANfpnyHFfqRqehqKUZ/rmBcGeGkURI2xi/3mJgcMWuCyLChcWhH9M1WFaufLS9+7KrNycEx0
# DATA g+2Qfx3Z3e4jstp99FpBONW9cFb+yRlxAVFEtdnP8ORDZ0R8YI2hSG/PLhZTlPNa9114iWLvSCeuLuq6sReFJSBlJGruV2zOxy5p
# DATA M3SW/2JF6foitszLl0xnHwZ6zIB1iSpT67YkMwCPnZ47w8eOVYLbUZ6tgZPvJqJJlsva+o/yGYhi4DRdA9Cj97PTvLR7gevhJvbs
# DATA T2rZoxGoguezL4svn61+96wX+iINtdcDd7O5jetzHByh6jgeaKd7KnrvMzKNoBsqWf/AI4yU+fWIr1vQee2hLCwfUr3jRDj257Sm
# DATA +EBq5kZSNVHYjX/JBgqlv8qxs0W7Grn+tWZfUGn6VFBKCYPanVXxVyY5HYuT0nKKBz6N2LjdzwX+fB7LDy6oBtsttPEiVkt0kae4
# DATA wOjO4irZVl/bwcV4xtBgnZU02hzbUytO+e7uo0bL3+5OMDtAyVAQ1GJ8wIvmy/E4+7b2heIf7IoJ2HO1dpYN4A9WVFmegkaggpM9
# DATA rQiX52hx0A6/0ggeFrniFPgH/Eac5L9Esxoc7ohMkUCslJqzP4AzDoaLmhDxFx/J0W5jJFjCYMQJJi61yeZvyKzsmg2+h2M3oBXx
# DATA rcXFg6AYNwDFFlW+0GaJotPeEbeLaCU7PMxQQag6XxLN4Sx2Nc+IdMXTxlSs74Eff5TxoJynfVgLV9/cLR4XDRdBq2FtdfdogPTc
# DATA ibMOQ5CoUBCD5NQLYy1Fovddhs7FPUQAZzqpCPWu0zdWmxqvBRg1MwqlTW0CrkIqwjQebNpo4BWlkHmf49qBKpIvKCIFiM1EO3Gk
# DATA GofcxEA9LBjhcN8Jw3LpK+pLNcwU/XdAAAXi9VaUs2dIRCkvxl/jYuwu7dWGGq0In1SXNX5RXcrYy2G1hWhI6tfoaEhA4vL3TxgO
# DATA vd3Bx2pNIRkAYIIrGeUROsq12m18ogSy7LDzfhq1Tj7/t8KdC5v9l4r6QTD9BcZqqfX5nKJARUOV0A56BhsFtwgGoEE5BNP6ED0o
# DATA f23fmT6yFobXYZcnECK58C+/QG3QH5TS/XGnC4k00Ihg2Xx2jjs5sxDACQETQh/h6sDFCZMDaBcPeD0c9Ltk4oYTU2QFq74h5EPN
# DATA ekAfBEzMNijIK9BTPQIIzi4E76gKe5j4QMePAVyxOhBr4QhtiH8Y59mFC7GAR1/6Mgko4Ay1rkt1vrxpUMIU9Pvpd78rscmaRO1T
# DATA JsZ17fNDazugU5ZZyu5iWDHe5PdifeZUIKoswVzZ9bCTKX3mxs2iYpxOCksdTmKB9C723YIbUG/JyWGnw1B54VyFR2+UMRRP1JS1
# DATA DM8Ip/D/ZCeEXrvCOdcmxyFyRym5vrG9s7pxc62588PNNVhW4GZqhyAjI5zePoHtHxxn7XE3G6YTX2tI/yvt9/vdGaTHXJgkYWc+
# DATA hT83GklRFZoHlQs6YM28mg/WjUJL6pe1CWkXUltC+GXnsOV5Aj3CN3jsaiHHxNY+JgPeZ4hT91SJpc84PNjxnpp++BKsLW6Li0l6
# DATA PbSNhFpXJ3iUzGTamfZJsRlV+69ra7DrohXyg7qV+QZlygh38Wi4q49sh4iN/sySL+ELR1sGD+ZWlc0WPL+KCZ5P45g0aGb+nGP0
# DATA ZwjXU1j3LPY/g5HTVeyg26K7mNPiVNagZlR/ZzN0zBPLL2J76BUEwomLLdPn6IlzYxEwQyuKIrTNG9PuH2BtIsAV14XAv+BbMRoH
# DATA vxSpByx/BMx3Tor3qP7MncZ6gvwmdvhP3EAK93KMt1wby1THTwGja4gDR2jea5A2vJLYutHGLl7mSfVX3tMvjQqxYRewMk9F5G7L
# DATA Bxnh7QBdPTA82l/uQLF7qhTLBoUFN4nRE9KJ0XcW1OVv+YIvNrV07907Te9nmt8x6vfapKr/vjypXtY/LqkX177X2t9znsjfy+Qn
# DATA pxuLsxlC9ZgK8xkGRjxOznc+PEX2/5gcI34BeCjiCmDw1D8OIiR2CxYABGEzLDt04kx7StSTZYje0er/uu83irIEeW6yxolp0M30
# DATA ogM6wQlK/60+Js0aKqaMKosyRIGDV130LBLtq57QqKBbvGuhFP9Zcc/qbeN5Fd0KE/HFmqnFR024QOlqSBT8GQR1FFpCLCBevGjG
# DATA fPFtt01Cf7w22aE/rk7+lh3070tsM3YLLrkeALhOxhPqsyPhrBKW5QdM+1Ff8WCvgqfwLcW/Bs2bmNYAVtl03INEco90B+zoKzhR
# DATA tD4DHcFihpy6Og/U3fkTPB7k+MB9xfpXg0ldrdoBPiGUUOEKm+6Dr4ydWymPKKTdiQ8CCHOD8/GA04zEHAbBkdCQJPzyvJ0QmAQj
# DATA OPW73Idcm9MTrzBS5s/gvANWtsIjN67FDk2O0MlZ4UAlqyQNZa/ok8BX2jU26Bk5CAAqWYntteIqswtfRgBY55mgryiABp26WFj6
# DATA 3NZsTzFb207quxeoY4brKpnhghksc120K4Xhl5bfehB9pLOvFhsSTPxEiAEEO4KrmBGA42IDiT+DZxkhTwd2kWQzP9n+YVLlDP4D
# DATA 5w14QufwlAVgf7EnUNwwCScIESHqdUD3SWdUtCXZ/NF0QYam7+KX3RLzxFpgHV6UhRicI4FrAQHV546bjZMOWaqDaM0wyIM6ZVn6
# DATA 8YGx9NPP+VnTLPP+E829CGqukDocVB3jlo4T5Tqkz7ahF/qP2xl4QtdxU8IQl8eidLS5xLwSsTnyD4p9TKU2pje6hVPkaV90ryet
# DATA npLA2wmoPay8cey0T42A6yIkM4d/xY3cdg2PSe5zegyeC5lcqIZ/KQECkrefx4nNErTp0XkwzP+CO5c17gJYxkK3a4s1B5RQZ4Gt
# DATA 1WKi5Hr+BL1sCUONPI2nsMzps0a7St9PoILQGc8STGLSe5CD23a5893MvCPZcbbdcwRfqeUc3ukAlIwO9owLAZc4X4M3m05inYjZ
# DATA mGnZHB0RfLb3LRk4IoD5iu/gXprEOJ84AAgmfAbVZ00I5GoSe5JArhIHuwCzOlfovYs0Rv84MGM9Ax8ObegNIe25+Cm8GfyoPZK5
# DATA qTcUgM/VmBjTIoikcMtTmVkSrJQycveeAU8SWX3+oM0gmk6H0OGsRGI2fQAqHyHIDH0WSpAFOvBtdjgIMp2DdQaIROpG5UomLh8N
# DATA Bh0Z7tTtKctqux7vFQlXISHOFzr6v2rYaDHNUNgoK7dbSA/dDCzF/Yc9SNnYaw3y4/4oNH7bmM/pg353fCLHjXGnGp0OQMWU7nd6
# DATA bTSXUafrdr5BMPTTOtUTd2gstL1U6DrxW/MpSIQvpYtLXE/bust+tAMulkOarHskamvk6I+JyzaiYfDeNdEPUqfhzcNozE4uW1xa
# DATA o4l+XU2535EYriD9KltHlmCS0i85BptjygIqQVDiSznMulkrzzhndX1hpuOlBy77enJ5KdA06rt1TxHusHOgHULVHu4/yCiPpCJs
# DATA UtxzF3w30OmZZ743MZFr+FNHr3Gb5eJeSbwZRZjp2DL+0Ikuc3Vf8NnFpLRUKScXktLlpMoXP/W8HEw02lJKdnDlzBhOP2wzGELK
# DATA ni4VMxjtmCJ+MoGn0YLrquRgO49aR4hIynXUhha4cz31hFvBUAaPJkpmpT6vh0DKXFnQVUMNs9dxoRAxNS2h9ZnruqjqKqsqqqUH
# DATA wePyG/jijXrrpH318get4cnVy+ohnhNHHiiTmR1BHtUg+UZfVLGwVoOX/vqPBwREXDKVu9lwzXM79V8pPTo+GNY6fZNHapG8uvSv
# DATA kNb42GgygLrx5tTilG7aDBRRKho+wcZ8JAwkLi6G7nbowrbg+cycGY8z7YOGf1QHw/6jU+9nlS71Q9tBzXJvC13djIcbOb1NAmo0
# DATA aGJze9WAgwVGo87niBF3wLE82x1MGaw76rqBhm8XsXWaf0cwPoIKAUuxkZRYXS56cyEjLUXBK/zXNYvZxSJ9iHWsEu1ttKTXFJxT
# DATA SqJxeun0bWJvGvtKTSOGDB3wB91BKbMLTyJvk1YODnr+CZj7kAYkKZnYaf7Nx5MFdJA3SmUn6XTTgqMNT1q3XjtTR9Pk8y7+Trcv
# DATA R7VB/9ASt9UBRhIxYq/VSIAycp5Q7ukO8FqJoHui59kocnVPIu/sKYxDNvCRMHyfwTGMX/+jqqFXniU/Y5W1RamKwCvcQRWGvUjl
# DATA QjuUTWG+H6A/dhHX7bq0Acy6OgUTE/tQl0q1YGK4+aDT64E9OkpSzNrNtDqMnQ/4OU6ugkFynNduDL9BerY3z2j1m/niYu019mPh
# DATA VcHCeHj4TMCO7TeF0Mql4the2z1EnpblCORhqOsKYYYHFTu97sw+0XMT+kBjt4/4SajFw5brEYf1uQimsNVyhIrOT0nTtwz1z4+y
# DATA mpNyDsmXjfi1kzHR0mi2wRO8G8mIx1kBfVdb40FLH1Lh23G/XJaWbClCjbVG7gg10ePkThx43OtIrLdl3z00Up8pGwlpSoQyJELc
# DATA o454AjNvSX3CPGMqqLuzsk6koc5ylrDq3PVJKJTOEV8xF7nGOuBM7Lno0usL9r6L29heg/7wCBOVGPqq0S3MBXWZTuq67k7koi4v
# DATA y6Hbu79FzrU9KOSzYtDKjhUB9SrsJi+XcmB+zsSUwmFUAikkFKZSBx2FMuIwCMpTdKl8rOQ+UkK4AmIpHFQlkGxCYc1tz/VOwJj9
# DATA z7FFlKWKol5phjy60J4GszQq/G+A0yU1+D6v8vx1HksYJDVsddSK3KNm36VWEUuZXV9dPBnbR1uy2UPWtv9Gjsb1uKvrY/yOpkB9
# DATA WGHnJDQuyVuiFM/dQCCMbQOw9jLybSwagUlPV8UYamIqqanWmJhxZPEbN43AYplvtS4YmKpdpXTRlFRC57GDd30+eN9CTPmWhE3G
# DATA taZR1AL2gCfYgm8BlSD1HDjOhb5AnQuwPKJ+FhovqNstee49gZfDTFh9cM8JYlhf/Boi2SSZvMGYpTcWCpMx+DCxFaEpeI4l9XNh
# DATA ktqmdEzu8m36aSIKI8A0EKi3RMpRUjsyF4xzdV7tnyZZa9jtoIzFvDinMzprta3q+oj2OFB3+NaIERw7qvLOSaa+OgHpOD9utfsP
# DATA XbzZWgiz4PqNLv5Heo0uzvAZ1X3+n9JldA6a0wNgp1GzCJ7P6GLMY9SFJbWhSdiF1N0NNQkQduuqR2B3XXiDmJtWPYBuMNcKeyOx
# DATA T3K/p+5gXT/DQ4w0HG2BfOj2x9RX3CNa/rD+hBgwonjDQe1BKpHTipXrQOJSNFOGeBQOyP137SdoBVV/5eRq+w09Ox9V6PG9NNIL
# DATA M/SIodsVGCKJoSzfxSkAD3Iguk6xwVM4Q0IkIbuo/dgUNhXEav1LAkfw8Q6HoDDAYgAxVzNAQ3HdkKKoTkQ6X1mYOMXwKVOAINwI
# DATA wKfuAHzZrx6Fh3DEu6gnBHLoqSU8PBHrwm5ucGFTsURvfmPRMl5zJbPTipTSFmwF1RSTlU1f/cTPMYwm7Rl1AXeeYDS9VP6QKblD
# DATA PI9yceKbwtKuI/gX5Y1T599n6ukfJX7uK5LBPCBNfGSQcp2kH77HcK+dPapoSTBD02BLI1TPhM2JZcN5Pbl2AXLg4H+mOIYb2Ch0
# DATA +X724peSA/YTGqt64KavRRccMN5EUHIkd0bd7WUlkXQU9SRMmcEZ6mASoOQJWVSW+leXliaFA/dQO1SfRCWKKN7elNig3pWEvCka
# DATA gQN+OeJHHM2pUZH0VMWpJuyIF1xyrd9QNdlOE0Kms11TDtn1hCucTHOlsCXRppxLBpCOziUrEyjipytxt+GkypjJ88SBK2bWQC9K
# DATA yxJQN0zBMlLUY458YC/V8XP8F5GCEy1W4E1pZPk1zZLV7Qyk+TwBXpNAeq9TuZUSGnlrCMpGzJlKaO5YqVUXzH4tWcMEYiAsqM9y
# DATA BH1HT7BumyGtBwDYgY2wRIEe3aNaHGY9lLdmebfbeyEuhzKC9jdy4/JvW76sKoj/5aBECPU/v3++lqW+Mf+kuNe/FWLM6b/W8B9F
# DATA bU7adCfxlb3D4tW6+85iBKAUk3t4b+SBCFliiw1TgBoNgjFwh0UqrXYnx9tvycK2t3SbmqEwpr1Iu0DMNpq9thfEzQtWTFfEhsDy
# DATA 5GwTglb5e26g57I8aJ5EjbJyhcsER/w/hxnCEeLU80LnUDGef/TIdyC1vTAodSr+zCS2L5KXf621LtjVJuylEv/gE6A/fJ9Aq11l
# DATA 4fzmkxpXARo+g+AU1QhySUcdqDvAPUgX0wJffivrfYIzR7BKzwqTfBVKTNWqOeYKEFDhwZ42c/MDlkvnnBc6DJp0ZvrQVhW/Ydha
# DATA JZmMxWRgTaGfaRy5r6OypMcWEDUFrpR9Rd/0ZOXOFCM0rwM2+zSxVICzpziiSiFcjTgk73y5nHm8BXAZshX1axsdN65TEkVQOFi7
# DATA akg5Yeq6HsjnNrQxXDo/xP38KytwhhNAeNpQ1E06PaYWmu+s/TCyDf5HvOGnpGqG3LbUpLpG2vU4moEzhAo6aTEsgC0GWVw7kAOZ
# DATA Msk/mXhoXdiKBxPguSkz5q3jClBPtNOduQySWzL9vZuut5UQ5lbs3L/rastQHXso9Y+GLQspYHdvMiX7dd094+Fm39nsDynsZqD+
# DATA MABM6P6+eXcLIaJX1P9S188VK+CTUHWhl6t9dqKdpeJHIjuyOi5SFRfcgBBG0lR7IkYBSmxx82udnwzKfq5T0PI3YXSUYn8TD4k9
# DATA jJeaC9KwEDydmVHqXTpIHNY+jDGoq5g3DF+LwfsQfp6VDuabyfLsiau7zK8cB/lCfwzXD2NSDMw2FY6tFGOnBO8VkBs8DsTl0hQH
# DATA 0PLLAm95vDgCYhj2LvbFNFTDwF3pZZEqozho3xJO5X+U/+/Lwo7qTC2ugBvm3CZ97OfgYaDNhL99/rtKwhhrUbWnA+/0LUAHsu8y
# DATA bnTXaasIf89cufras7Jgf5Ww9jnx+iwXcO26XnXKm8fWl9ZdVX2v+V1hnxAC0GWP07H+3LILBaQiYjxh8pmu1F9iM84END3H9o8f
# DATA /gTzPZXSjd/KFFnVUUQM+yMlCJHfotpkdaliV/2ggGX1B5lcLckMLxj8gj+YFNe9awkjyCPhMg7CCn9aLLCUY/qbEM86slmi4Jgz
# DATA I5d30fZds8JjGimwPnCSaYAewYypoORetEEbsSlSO6iz9ELgVY1s8Ie4o0fEZOOd3jvHAMV+BwsnAyK3DF7nivHS0P2R01lWnCUh
# DATA VXFMcYXmW/7ynHN/duGCelRJLlzQNUzClOoVZzs6CFrq65Lq66CLfv7H6gghkQP+agK9uaJqbqRUKQu24T7srJI8Eetnnj+khOOE
# DATA vpfXCLvsOHtUurRSXtBJEVDuiuH1eV8oEt+8u73z1tbadnNzdXv7vbtbt1DzTw150RNW4Xvba1sYRGGdlvrlrRvuK78WD1zw0Dpn
# DATA 64uL8qN+Jt2Y/LXh3u39+pXLl1YWi2t/c+vuxk5zbeNW89bdO6vrEL6fHo9Gg1zVDaRmViTdXN1Yu22K6Td+ldv3bjQ37924vX7T
# DATA FHYkrPGwm5ecVTUrD1tr91odbllvv7d+S/Vs9cbtNdW7tTdX792GpVHixzgLB3JnbWdr/aaZ61b7pINOJvICViy6siuXy0Ft763d
# DATA ePvu3XeYIJpvr63ewmqjdMGaerVRIXKRiVmL0O4WJYILpedBazTKhj0MwPsRTPwwqyE8dQY7v4xRc43ahe+mrkAneSP58wr2AqyR
# DATA tTseG+XuwSfjfVOeE/s160nAYKSyw27rKG9glVMS22L9FxsIsKpqCNnVRXxlMwf4hJkBIkAAL6AJxojP/Uw88+iH3Jb5lRsAiYmR
# DATA BP7Vz5UEv19N7w/v9wD39dVz+fshYKlWeFwH9x5OE8VKUXPCcnYpG5IdgNrhD7Ixskjn2HQGrVOwaKvBgRmiBn+DVSvPrl6u7V+9
# DATA zFY2mRbBg6JII8eDOpIVjuvGk/b9sgufw+9232eBgT20Wjez4WgzO4Gd8+OHo83xvuLb7zBUveqJ9Rp+qjfwy0fSJXfYd2HdyQvW
# DATA MTqUzItKsnM6oD+DVbEn9lNQ+bEDJIIXS+7Fx5hZgFSCBlnuMUDJAGTsT9HT+GfPn6GymvS2COH0LJ7wlCnz8FUt2DTOiN4m93um
# DATA Q430jBFdFU2/yjT8sNUZEZQJMtCSxK51TrL+eNRYWTKxxlYIAQbBK3ZwB2FJKLZQrV671VWSZBpFHAlPPlYsQV238ImAP7g7xyoG
# DATA TZISip191Lp2DuGIzqZk8sKYe1UyXwRr28Gxaqk2UOuvtV+mlgBpAohuKfm+U8az4X+/kSxfWl56bSW6QT9BbwNwL3gMl0I3A050
# DATA pR8nb+/sbG5XDb6OjoSj3N4NpzfGOsxKrqx1yCxTsvNW4X831t5a30hurm3trL+5fnN1Zw2f1i68gf+qszR4l1pJt1V12w7zgmaC
# DATA Af8+HE4wGL7LWmp0UfQ+Gsj9wEsfnufd2ubanSYMuznqq2N1C/8uQSfU0Vsu1ySLuJkoPDjgS8r+3WT4iya/LB200LwGNwRrOstO
# DATA DTXG5cHDJPmA6nt3bWv9zR82f3Bl6XvqeFZTtnq7efNtJTE4X6pzvHMyPrFy9MK3O7e32c8e/nyw3FxhF/JWW9EcEDFsvNpJX00x
# DATA OMWV4AzlvUi2qGOwsQSFvq+rsEBWAsi1zug4yUHtNpJJUb3tge1d3RBK6fLKa7Ul9f+WU32SGUagxlNagXj1R6XackU3V/W7Ahl0
# DATA W7nipQ8j+cKhAzJBD4etQZN6U1KlSV+XDZvCJxpauIL6FOMaD4sEfUWSPsVQcWBWgywbIrHsq1v6UK1lf3jCB5GmGmBgQn71wmuV
# DATA Qb8n8MUPwXHOgcECwyOEifxC8pbYiJZqwau04RHX/qdpueDWQl3PM2Cn3dJh+tbajmJhsI8Wl2vLIBC8raamnpzJDE3g2U29lOpm
# DATA 3QU/ApAc1P9BYjc8jsvlotlbWVoCNtZBpRA1r9jng9KV5RVR4JV3l/eAzi4vLRXPkMXu7ZPz7jYfm/YRug6eRP4ZKlcgQ8RAXnk3
# DATA ywalGt9+aBlctmJnOOY1+BDBp/+UWLCYX1K2zBcfXxdtG8X0fCwJmHFNK1G2jBnV/52yzYARFYW/KukgxcyPvzhBXsncQfIOOB2o
# DATA Y8u25c+8CKIMo96mKZ69UoeOx8bL+2FKmQkAJyhZwt27pC5VeGzKF+UJsJ7r93tW0d16fa+wnCPuHqZpSjszOTtbsKoY9zqP6osP
# DATA WsNFte8WtXZ7cTjuLeJE1GBzQ5UJ6mKbcNfuH/S71xfOaHATuaSrXY9TYQj6OplP8m7TPuIjrY263qke/bIJgn3B14Nh54F67X4r
# DATA fc0TZNO1Ff73EhUBUWkl6feuL1hDwNtVnvQPD6+zcUQdk4vjfLiomNIwo0lZPB6ddOl9azzqozud+SSD7dBEBMrLS5eTRfWfmvVB
# DATA u60ub622WoofVG/SyVwFSbR6ly6kiibzXudQSdXdh63TPPhqC5BUhtmwutlX038KknXnYMQuftWHx1mvejDs5zk/carp9kkRkvzo
# DATA 75PFRzAB4EazKESBR1+3A1F86oho7vfbpyQdLV3X74+Gg4MmiSt0qCSXlpZy7z2wvWnvgTvgX+qqP40EsYtIglTBZOIOQ43i/v1a
# DATA 6Y1XHmbdbhUBHxbLajTqZOudggP09eATGCycquSukHx3POzgfxaThlooLK/+v9ovih2Q2mF9892rzY21nffubr0DW1l3sdkZPLja
# DATA zEC7kad24Zt3N95cfwtUO9h22lbUiWbfdH/YaRMuRtZr7XczqOKyeoFRbc5TyH8IB1zFrqLZHyD+/JltfOtlI1BK16ju2pHaKmrF
# DATA 0Q9TKkp7rVE64ap06O2Za9GCslUejfpkGT5wMedxvMwZxfLrJiin/rcrYjG3meUctl0eimVqtSHP5K2b+dpPR86FAiQHOnHWNx9c
# DATA rVN6A3I0ktvcM8pThsnjGEaZEUC1vwOZfjwjrOpBhEzABMwdsbzWwZ+WfJDk5W747Z4XMt4fiL1Wvqfbm00RkfRPpVhpIDwmQbrv
# DATA 8Q80BTnlbfLUMcYGVsb+35Rvr5pvgZYjRR+BLqjVpRG47zADG76LNemNb7bB1iZvGvxyGquY5zuwcc/cZhXaZlQ3/PU1atdTqBhx
# DATA /pNxBtEAZP8cy9Lhn9GZEX89TFrnzJKgxHOBi0naBC1ZSISEFz+7WNTZiPfYM4TjpRmv8v55Jo7/gTeVtqDa0nZBTMlT7SR/niSo
# DATA OsFIEUAt7JpvwwtgNpaC0yqTAlKW70GARiFksUVma5p8u44EM7U8hYSKdJ8BSZoieD8W07YlSEMscYHjF3uqPJWUml+9+DmHgGOQ
# DATA +Cwjdms0aoFN10fb0ny9XJC/Tj6MGumsWskiiYK1ZYmUAg571F9ZyEimJlXVpLiVlE+klNqaTEk3a3pemG129omEXnqxVF/Gjdad
# DATA uiiJ5Kf5wSiEOuPHwRESMZ5SyUJLqWkAcwlinEiYSlBQZbl0YMgGXbLnUq/o4z6y7/voanq/Vrt4X936c3PKVBK0VKCFfzQUFErg
# DATA kktp7J4bGke4O2IdKU/bXrSDeCUYg1yPPvTvwEwNfuov7Q0iMbk25niwlXR/RRiwyDo06FizCVsAHI4Dzh2//gdbNhRCziYY9Cv9
# DATA sO+xuOz8JuY60FE3khG4GjmHoDxXi7gUfiXHbNHXRw+b0ysI96SUh4j0EZK9rvz7yVIkd5ffB/Nh0DtVQXxmz7HX/2j6U+gFK8dp
# DATA TDai6dk1EwvWclD5LVd0zVM+s2fU+tIfaliDECS5guh1mkKWhpFG50zOBecSIJ+YO0DQfkymxiA6GVY9WVKylD1Q9WSy4LglRIR6
# DATA dmWQdmZlew3slHrHgjtPRJhaiNBtvLEoRZEkBenWFFk9xgBDNFA9RR3al0RDlLlQMi0/ZRNWyLJiqZf1OQ3TKR1bKDpzYqsXDrri
# DATA 3QaDW3TZciCfftEifyeYM3WEONMV/65UIISwtIdM13I/DcXHGlnUndNCj3raGvPaOh03HRA6o4tx3UuQR75gnsjkuLyEV3aAVu52
# DATA jo5HcjWo8HHVBPVWg8NRwA1vUT1fVJUvwneL0ANwjWq3spM+pSiQwtnoYJGuLov0lkObeSqgA/3xaDAelVrDozE47dihGIFVg10A
# DATA ySGWf9SG4575GiAGBmqUWZPqRe0/+QnIn2zkWL5SLlZeW9XvUPm1RwPI2TdDNjO7CrTPH7sSM200uCLp7oJBywWp4DHhSoEm/1ts
# DATA T6Cpuc181FbjrIGicFAqL+gFIhoo4T37sAUxCiBFBamTLFJJFhNdWv2tivuyr4u6M2WMcR93aguHZhpS988aO3aEY9TBwWQ9dUfJ
# DATA 8mQ40NQRH0VU5AhxaRd4RNrqEvQLHzvlqEYpIhFiApafk63i+dPrMjKS+pwMNuYq+7A1bJN+iHssrZt3suHVgqLzmOW5wfttN+0M
# DATA 4Jvqj/G/qJfA4uiNe9x/aA9Hov51fbv4F04E/QWcj14iUPFYnAfaGQC1A+eyHmL2AVX9GKBAcoZF1b+cSC6qtFA9Z09eEbHwIKgq
# DATA SyHgddyKE9BL26B3uziMPZ+Ii/M71ep/XQVE8uUrACqv63v5i90fEzybf4a2qn+gJM/RgYmmYE5SLupQAaWGnVDTPqUb1pqLlYWS
# DATA tpfSYUvNzPeINCyaJoUbXdHCMbQOgE831bc0gJW0eEa3VquYyejDF79E3K2f+QqOXkbaPrwt1kJeohtrrNgJmG/hcWb1eb5Ni1B3
# DATA aliVhL0FcBrUNqTjMbUC7GE/VsF03QL5NT07q22j1anG7gSTCcTjl1auVUBAXSoHzoF+zIrdCAcHBO2pLT8cUb2V5NIluIjbTMxC
# DATA 0xd6/9GDN0r32xfL92v2P6o25jA84BDhleoCjGk3hwI+rx0pohmAtAQWaJ6rolWuYkY30h36y8vrtAamuCxZuXYRrLoSzr1Su3Sp
# DATA tnzRKOct2SV2LtFrl5Han1hHi5uknIQe0ggOro5gB+ak7UYteTH5cvf1R8GOvJ5srO4wzf0BMy4/xs1p5VoWkQyFrinkGensoRJ2
# DATA HqpjpSoI68Sje4c8hPi+LR6OfJhwfYG28TMZAmWstxUhTzWA4Lk2HVvco7HeU5TV+ls45/RhaTYQy9TwZzeP7NUNsGlPAAUStVrg
# DATA OJNbYd+shcYGojaf2FEdbb3Ty8GLJSXUVXVE28FUOvzR1ewX4A0XGY/Y1jyH4egWGY5mmIvW8PYHFOFafGYbi/SXvp0pLLo+1SB0
# DATA Hgxk/vES1cgyYTUFNPb/ZYPSFEmm0CTgmHjgrvIlAhgCr/qCi3MCeQ6Iewlos+uJU72XSRcVpgI8S1CRkkoUZtLP6QBTHPWIjSeW
# DATA hmlGQwpfzJVYPh71YfbojO0fHqYFhmZkhSDxfYGeIuoI7cksqK/QuRi54Ucgh4CD8c9s1MdPIbYw5ivsBfLG4L3YhdbJ7VZJLkyH
# DATA v4cMywb+H8cMhwMMsB7evOZzCWDXBh8lL+qPHtFYxL97iX6QkiBenagJbto4oxF3N61G0K7jleSd7JQc4MDDEX1/nMBkM4m9NOap
# DATA HjZZAhNGRlW6FpiMWgw/YSA5c7f+pSKyT9DMoGfyelKMNRjfUYSt5KTEVuJQTn6w30ofUxtysjcqcXMgtCerav/UpwNSkIHZs0u+
# DATA +FVNbVJyEz5FZYjqYkBFcZ8UYimHir0dl2JQP9qUrrEOtONrqv1vG+mlpaUlMrs/Om3o2Gf01ye3QSztB5sVICV4j9ElUbWwjC3g
# DATA XlCsv4kxSA3ee9iSeUo7gTKfgt8goriledY9BIDebmq/o+ovX74kTzu9/f641+YX1+CNncjMrtPwS7tuO8YgHg4DhPiEl5h97Q0b
# DATA dX3QMTImLS/MioJ1+9VwIx204thakaBjvyNe7NvOAWg14hxvILM/RUx7Ti78jXTXdE2HEO6iE2gMPZtDlvwljSxmCFUMMNvUBOFs
# DATA X4oiy/wbO1H/KlndXK846wP56xlq5nHyg2Hr1ETTfMno2mim+AXF0lh4MZ1Dn5YjibB8zBxBJ0UQZMAiV0JZc/XWnfUNNzJqvlPX
# DATA IJxGDmADHxWAzwc5s4sQqYpDy7r9oyO6M5xZvoNwfyCQIZA5BoIOc6bO+EdVcNOEQpeWMEAKHmFR9ehKyj6QcG/vSzIwTC4Hr8e9
# DATA Lkhv+ag/GGSYM5Sbh+Qc9FcQo1joQigIhIzZ0LbBdiZBNeNu56TDDo29Pvf3LM37h9Cz5aXL1668dlV16FhdDc2DyWQyH4aSOv/F
# DATA GYGGzly6wbw66z0gdDbEpDJLupiAt/2DtLwX1b/AcuWN3UMTalGXQK06cvr4Z5ywtbHL+BRVCpsg11dwdjWwFYR7l9cX1SovqlEs
# DATA 8oOCmtsZYAzkzX6vYcMqtPfZU7TXxvBxTLzGeVqOFS8eHZ+mEwdxgeAyZn80iXaDXmPeVNWPkaIwwCdKb965Vd1+e+32bVRSjYfd
# DATA pHqYb6P3dX1xEfxyu3BowtQtL1IdiEqJOjs1J+iLuoQXcrbwIFHnBBYxGlIG2Kt0sAxHzUE27PTbtBdyGzoi5CkBbgNEIQ7UuzZF
# DATA 96eagVg64nZr1IIgyThp6RDp+vK12mvpSxMZWV6PT9D/upFeWV452afaJAhezfHO38Iw7+3chHU09CU9NF7VFj7KlObmWcDBUbOT
# DATA g1LsNKneS7773TMn0nySVNvOw1s3JsFiXpq1litLE1s+UzRZMNe0Y3jj1L9XW65dqra6g04PWOS8+61oQljLaX2PulpWqqrtAn/R
# DATA LwL5AJUlBafSU8WDT7ITtdbVAXrq07tMbaWRVs6C8zv1C357XeN/0P/dL66oHBn9a6+9Rq+AK8FfS4UDKl5eA5pTPegihEs1n6M/
# DATA Azgkvt7qWthaFutSpdSUOqwJmZkQdpRp4b+OJisUnz2POPs9iX3F4ADFX2JAj4S5+i8Cp47Ipw0RBcDhIHgNYDnXliqJkrQnhVhF
# DATA LIQ50hcZncip7HMWe3Qkc0z2woc6goqClR256RmJumkUySbftbF7AifYvfgeDtcopF6SNhpnFy7Qt7sifyDtFbrjRvOMRo6uKRza
# DATA /l64NUh0h4SO67yP7buYqBCsMEgNy9FtGz/YX+6Anr77Kd2r2vchvAXLaocZGIde5WPbjAf6viiu+nx+v1qujY7VBWLYeF18ELJH
# DATA HXWdr/Xff2Opvlwu1w7Q1lQqeyXUqyL+5XCZK7O4zPJKRCBYcQUCPiEkBSOgIntZY4ThWAzScGstlE08R49H5NxG9/x6wV6htwW7
# DATA gt7WV2rLy7XvmSPNPf3funtr7ca9t2BgJ+PuqAP2qtHBoLEE0gBTXnptqX4NNANwha/TNV7+XBy3B9PEgbj0GuyRm9BVwj4FRU0d
# DATA XYOw/4v6VX2IZyI+rcKk1hfhv+YZ+zot0r+2ls9qXCCqz6yKEMvaq8bHt9aBR2cUAGHwPBMbE1v+hLWmBgERnf6ynAMBgBPv3HoJ
# DATA I6tOuq7dPcvMisCT1i6OpMNxCuGWnPsuYzv8N1I4tV5e9mQZuOHIv1q9Y27kPMbKFOJQwoOQRTTCL60kwTfq0pk7H/WPFvPxAFYH
# DATA MeJiXQ45N+h5F2EeRPqKdYPZXsHXB/1hpsEHY59j4nWn1F5ctEGNEqxhjI4895OICgrPAoovtt6Xw9uL0O2e4M4FI0MIjeIlGXVz
# DATA 2KtFB7wVLl3EufBtfbm2cs3wrRhxLpyPy1AwMjkkGjZD0bjo5tFeZHcVLIQMZzpne8mpOW+ts3fAOSt8+PChVBgLS4Y+euzTYln2
# DATA Ar4sf5x8EzDLRl82G2g5QFoOySOSlAtENQ+LGX75VftYywidGwFapklkUYmRbur2dvUrRl2DLqiRAgq0VmwcYfjMR6c0F49Ow+4S
# DATA gHM9EcVu2n/Yy9pWT9EaKItVnlNXxnYxWzi9N+zmIUbtVAS1c92+7KwTZ07Lm5Q6mOwU7hsaeyBDT9tETgU7EN9/b9xpMx2O1Z81
# DATA +M/lUrnsBRREs2EJZ5162YnlunPGa0MvNVx1P6nmBSSpQcphR3lfpiLrpLz3Sjkq/XIMENFG8tbQiTamLAAtlIwrMH+ON38QqHNA
# DATA gCkR5jzQ69+8t9N0YAXhx9barXX6C7H0bDQ8+FtA7iAruonUO3MRB1W5W+tbazd35FeAGFiJQf7BQwM9qn45SKEu0K3Et+O9qKnY
# DATA MVwpmh4Yqotwnksyk/rUDPNBFrX5M5B/LYTzr5ll/JvMJB4PyI0Gy+gUfwUox5L8yI/dnQp7PDe67TD7yRhiAHwwzooHgTnR7iJO
# DATA CqWAjZ/ZBDhZKI46FEDbaAhfZ9b2JPhlgdXVM2j2k4yLSlKrat10UULny04Lox11khzjhvcbTt7HXn1foFPOh9EYIifZNOXVQRd+
# DATA nSF6oEQXZ5klt13rcARHW6vb7T/0zdnc2X63DYLlQ291qYayc1cuYXVlGxYTZkfV4OURnc0LreLqc4p0ewXgHB7OnMvn/5f2r1Dz
# DATA xGjhc8yiNXF4R1TcnXL6EXzmgTrHFKvP2qXd0gltB3BOgbAd/rndHw8P7Ae3MnCqw31pPd16L+UELOjBzLkA7mBzaiega5DMfJN6
# DATA gQvQ1D2iP8wS8G9r9mHvDfuQU7WU7nd6bb57oQW1n9d43rk/a3c2Vm/e295pbt29i3sRzWFaeFa9NaZWlN+pchhSilprk4FLXkky
# DATA eStLKPaHGZYZGVub6S3GmMk47VAveQYayP6DrMQfUPXfSe6CDzNkOBsdD7PM5EKuDrqtXg+yG6MMzS2etE6T/QyQfrJ2LVnDtGkC
# DATA S84VYkkMhGrtd7oYico4xYQ4ir4DdNdSex/12SAqIYjDqM87rpNLCmWTEonW6Otmf4jmSZKplsYQlCLcsFOTwqD/nRo6rARKt2bq
# DATA w32pS1qrKRUAeDb6sQLtmaeX9myf1QhMeiwsWpraXdkT+kFBQ4kXO2tNElzubq2vbc9ZX47bVPwJqOpl7yY3zLotTntKxc0OqMm7
# DATA 5qhPG0oy2dj5leD88j/s5M25vsWjzfEG01jA3CtYW3AckQcIXZ6jg/kKhQq5gTV2kjy8meKGqO62qoeYKe/SCkTZuLVBoBvX5Txe
# DATA xmM4vgK7slB74VqEuxh/abq1qIgYfcAHYuwdkyx9TI4l6PlaHGLrapw3aPveYX08CPc3FLFCPkX4fbM1WG23+a9bwz5Gem0OOw/U
# DATA zRjcLfacE807P01CAHTKCuvyNpPiM/ZBI3JTPTlDvM3WoKyuM4NsiMQHUwd+fJ1HquZVdTPg9C4tzMVV8kRZwD4MGI3OSqHOGheI
# DATA AhYBekMHDvcL/jGHDf6yjppICgcZMfNJqaihq08+UKKb0XlO5ucEdhM4lcVtVM/dhqqfk+7OmjtFoRYnLy4YdeQK5RNTQV3LciC+
# DATA xXeZwTsr0HTVURsGNyxWeqURbSyAwFta22jBUO+KuW6t3xZymTprCRoZmUssY5XRRdXP6dzFcU/6vZPwz6rGr6fW6h0cR3Cnw/x/
# DATA UehhLwvgi48YF5xc1tDW6/oasmGhdM4LZXn+PJF21qviZOMzxwtxn04qLJ3tjbzyAtChZ/IQZuArdTuxWauWTL1x20ItR0MfdFt0
# DATA AYzcNK1sWqJgtz+1bg6lthGty4HHPGalsUsgk4AAZeshEAvlosZAOvzL1rtYRWtDCnaGTJJwxVrEdZvPnkddN1VZLXDrXOGh7kWx
# DATA hGPpNvjKrYr6xyRX0kicLC7OXSQIJtfzSh+XZ2gRRK6Gc/rRqEQnuSs+6pV2vdZZskaQJlwVfMBBzdg2xclxP1zwES25cftM+Xzt
# DATA cq6YdgEMlqboOyIrjo7F7+px2bBk7y1DjLJVqZy7exnzjV95hgEN1u2m1qFPnGdyi5yWiKGovu3IVJRic/GK9yHdZNEvhmbAgniO
# DATA kbpTJ4ZuslMWXfsE28dpQ917KTgkDmZXqAIpiET4Iwt9Ea6kuRmdpkxLC8EVR2i0XgCHFhCr2ScRsi0X46JYSrLIbsS0USg4S117
# DATA 8T0+dd7A+ejFh+rYeiJw2lb+UcTa9CeKjgSd5BNyAP8K5pNkafV/NH1e18oGrreR2LahUhq/ZUAdtva/dpw9YpdtRUWoCpyWsXOG
# DATA SQs6ws/hzzKaxgYdJ2enYa0VLZbHGWyoIMRM1HR5342wuSkHHhCT8OKGzefcxY8ePgWlwRFSTiDHmi29nMG3NXtjjBGYjCDvfXAg
# DATA 26hQzrksJpozYiv1RHRNwpNpXZgjgh8R0VCdR2yxdiCFXVm5PVOxrkjWz9RhVT1x7C9QlxJK1d7OATWtnW0DHe60huu9wz6ccJj2
# DATA nn9bODpNNOhk6hqajVrg81KCcJpKAnkh1P3XhtXpj1qgXFMdaY1UN7iE6l3TgBZLLc390xHO2BIsHVRZA19jF5aSHyavJ8tLK5cv
# DATA XFhBusBm1KOryQV5HmMBMEbWcXFPEmkcI+6ydo7qsbx1mCUYCmAdEfxFrbDnkGYBOmLwbADwG7ClHxVOEA4onE8p6Ats6HWiOIOp
# DATA WJf0Gj3qjbv93tG307BUXtR4PmgN86ywbU5pg4U4gbY6XSh5kbq/o/IYdZxmuU46R0ORyegahebvg5F1k2pyS+BjkrVOKnorwOo0
# DATA cTkbK5pALlUoMx2/WF5S/+M+vvrqqzdgYhICOCfda7d/1DlQVIbEQrff5OGwg6H0nd6oj4SDgXkQKvgAOq26kdVUZQuOtIkXL/uo
# DATA lU1ygLyykSwt6KwWsgf7apeX4K/+/o8bMjxyXhl+kOJIO2qPNvxNjCGgPC2e+jJDB1/QwfivicdBXy42kmUvicIQry+kEcQqangH
# DATA J51XmAMSanndnmjYruHX6pba2lf32PEoo6tqWqulmMUPqi0yYNzr4UbthbsagaJ07kHsRhpFs+NedHK6JItgoh9zCnc9YeoRE3d5
# DATA Sq80EfdiDAfqCXvD9VPuH0J9tB+9blFxUiWaKeqBxeYCrqY3UoIBWm43nFufnLY/7nd6MJ+lC6Q8jU2jfXHztLfRi9JUlkyp3hQH
# DATA UKTWjt7G3CnjxYvCjVpTOA0G815PC/FGUpNsZC4n4l5GIB/sSTh5H/qEO3Sp/9rSEkTCgoyac6wr4kg0++9Typj5tHrEJ9SetAZV
# DATA tHw1au7r9AOO2+PxqNMFZNv3m+O8dZTJatYOwX70fYdCLyZXLxcdvxYKgdodh4edA8jpkEDFyGSVmHVC8Ibehrb5fvT+KacyHwe4
# DATA X6lX4WjoG0aIPQdBSoYs9eWJ2v8G9Ez+951k7dFBd5xjYUiBBBtoMMwewEwn7TF5HcjezymMHSRROUDIFSeWVgm6XHFWFs+C9NF+
# DATA isydgFvqU4nx4FgRQAnX39oTGMn7V8lSf3l5mUwpS/2rSxHAWjLckWhfRHomiZQuHd9v+11I32JZi1rqjtgBCw1/VkmuXrly6Wpx
# DATA ViHgN1jLrJRKkZV8qGZsNBz3YDXaBZmSaEZrsDRZCRuKlzPTUm2gkamgLNd3qOjjuBR5ndcO89PeQUnKqUns9UuupxSeYNpNYXAa
# DATA k3os/bGQjcN71d/kcmkhdA1SS++MThFwCeWNAtenGsZgsGtmFBNzE+kRKgfTOeA6Nuy365tr+DwbDv3nLP10TjDmGEzSLTArIQzm
# DATA sLQMIUZS/P1Ot2sVr2mQLA3pQ8/xZigJFgHjQRXRBkIH2iMA/JwiT7qwlRVHT2KBdazhP7D1FZUBCY6HvjqKu8QvY4CjOFSLTDzI
# DATA TEzBZb1ud1pHvb7a6gc5AVBJYdUUba7lq5euXS7XOHdmOh4dVq+BJz50JVfiY6ZugY4qzKvEb1H75ko5SPVYshI7muAB4pUQP3Cz
# DATA P+6SZHWoLr4kKgOzQBnPHoPRN3pvHDR5nEY2kCPat5bbqMk5YU3Sm60eXjrUodM9xY1lnT3XtbODtUUUU8eoy7aAkWBfwtuSJnTQ
# DATA OnUzxW026QHvFHF9BP9aa5Sse4NGuzaxInEfgK7Npg0LxXXQB6qJn20FlGW/CtaQWE3eaw3y4769KVBLqvo/7jVcYFzCTaZCjQIe
# DATA ZeNyjDxVRjS753eS1YRxAIQsTlrvq/siHZgAQAC+Jl0S3TAVXycjKvrJWIlLqq6DrDMA9xmu76B/nKGyUMZWS7bU3EHoVPJ+lg1I
# DATA VI6sfLd1qv6r2HB/jJDZNBICRkMFM4AD28zVgKbJQEV3t7dXIf9OFsLmxRGWzWU65WC46c4ws9AobexXZKnf1tsMO+b3LLHdQVlX
# DATA DlNtm+S2xr0eykCB8ezfNHSlRrHE5HiF6uevHDvhM8JWtdSxCAvOutePipAuaBB2albPKMo6WKswKkP3tK0QfgY5WvEhi9HGresV
# DATA W5fL2vuXcyKB6j3b9+wMzLaV1Zvjx9MU/KmZicidQN8CLGc0OzVG0U515Qw1xfDBrugiFZXjlNNDVy3uiuRTvZWM4hcmnxWyBW41
# DATA VN9e1JugcFb/jDi+H88xfUaPE0yi5eQL09TmrGIW03T2WSCjuUpqqKEQmfs7jNiZ5ubK3GsP1DUdb1RwoRh38mPkg0lrPwdu182O
# DATA WpiaT7Kxm8oMOeOBRqLVIoTzw2Gq/sRbGosseS3ZyCBrY/4QfXmQW3YxgXrNv29NOfW1XR4HSpKGZVSLvS70Yv2XEJvcMco/iy6u
# DATA ZdPhtJ2A5/Ql2ssYlgyTqyF04IczEE3jGjzZRaiMAl8q0UdeYBoaHnX7+6X0Qlr2KBZ0eSBhAd5rl/JCB47YDB8bpJUuyRvt9uEi
# DATA zZanTeRUXGhETfyzTjMNzhBPwnl9Fts0U1SKWqsBg9bZr60RsgqObqhFGkZU39qmAEvRWzjg308x8xFFPHnxqxe/FDNhNOc20BgS
# DATA BTpLuwzZmwAckHcXDxZLZmHq7Rw8i7RPQYzHTuHeaLp12DQa/Gf5M5UrKFlajspDErtL+JeEqHLShRqeKI59UMLzQFaJfuPsGZLp
# DATA 4C4FG4dRMi2kSFCudPrjHPplPVacDNQqp8GOoizN4K9garZ9Euh9XEdM7+Z0veN00JypgH5xl9UjMky6SjtMFu2VpXzTkdIFePAi
# DATA Wly9PMELBVQ5faN7JyHCpgrfQ5hTwpOjBGuKvX5BXqNg+f6EGaugzand8yk8CrtqTwZGU2GAKCIsLap3i4+GLQShiTyuSkKACd0J
# DATA ZdVofigTHRLu/rjX7gKu19yukXavXplN+ougEqEpLZzRf/Km5alMyleEL03i7DPJKPiEEmpYpxS4cKAvAUyoK+c9f4xQs1DNL/CZ
# DATA LINk3qDz789Y0RNwSjNJQxne9okLcO10ME5gskOZlCw+rHYN/NXklOhuORKPp07Vv8yVSsSZm99qVG41aITphXTZxH/5MLKJUGfa
# DATA 6OcoYBNasZ3TCa6VqI9TchpKJB1IYGYppsFVORn0H8K9r5/nEKAEotVBa0hmiV720KqMLgmW02WyCZmo82MUeR4e91ULct0U02Gr
# DATA d5qw7gWiDmqWRodq6RCOooXsCaIvAOYi4dqCBUr1RpgIzhXLBcL+jKN0rAYx30qD3asxOquOmk38k33nQXcBcP4ZmQzqvgUC405R
# DATA y6WmH3WD0F4Fft1tbt26u3H7h8kH9Eskd/1g4+6bd2/fvvueS5KjGPPValPTpJehzleiWF+STsv+kvQdqPNtqpu+uj2X+NBh5NV6
# DATA cJP8WuFBbDAfdPunJxQRiHVyKN+Uu+xJa/g+XvzTLak4+X8+/B0KIpLA1Pj0w14TcU1tMEnCLjAcEh9qbnxWeqlip1mdZso1KetE
# DATA inYWK2mKHGHc1aD4P7o1WmekD+ALr8W5DCUheOAzLaLW0P+OzmGcXEIjLURbymutNuFT0AYxm8gyTVNaQbNui1jIIFSXnHcMahJL
# DATA 8xC2GvuS0TcB2B/9qnDxFWU9/2d0PYPVJkjhn5ELWhgKCoX/u6IAwB/9hdxurNNFvrPb97N8IAgAZ4lgL7q6enRhN03w64Ah2d0Q
# DATA kIS9vVit6jhw01A+g0zXnyPuugk4nN4YsTE9oeU9J62Pfm6FM+N8XgRbSGKHfsF9BiV3Ukd9iWorHnBV76On1z3QXTyIYL3klhhP
# DATA JFxjK4rVOswAfog7mP0SAbnWOtlqiSD94impSn2B2Yc+JIWPoKk9DtsF1LWnioHnSbXbClA92NX9z6rgJyAlqMb5ExxLJTH+kghl
# DATA DZ1DQGsIDkXoNQ4heoLk9CXlhJVssM9qYYMp0SJcouCgf2K+wdzmXCnlHnlsKJr8FWFPCL5VORzL/4nw4eC3/yd1e3PjD9ALVlUZ
# DATA VkjAPmFt0MmnRJZ+LIMizrCeYXakrjtwf4gPmnYrVIG+tgft6KZTDxNSH0vEeTLAGCu0NTKvh601VitaNegZ8Y2/F4nlMshYlQiU
# DATA nEYQqw5aef6wP2zXRo8QWMzCuqkILE2FkGQqPIsVvszBHwAI48Z9ucyNfH7CK6LeHeLW6IZqB0wS67GCHkjoYnmDjfZlN6IaOLo0
# DATA TNfXQkWKl20nA01cp3fUYBNa2XFDRcbs61YIMh71DOp2YGe7hA3+5vrttW2Y4UDYNcO1DpeIdQSN7mimdodMxlqeDfdY0Y3COilx
# DATA AL17Sjjp6C97Xy7inV47ezTjzHnxqwpwnZ8nxiVdsy1E044x8jTdsxNVMQ0jeRJigYD/ORYhdc1oG3dcs+HAndrUArD8njIBo0Hh
# DATA a+sKI9ZC80Ivvmc5xGYyisNBxQV94l2ZcKqAoTs9oVU0VThiXRE8jNrrap4fI9zlY0d2M0SBwkxBvWV3kQvzdeFxKmc51kzCmAPV
# DATA btqwkpHIeU4B+Hu+HDa7d8UyUTihMB3/6lIRHGlzzwSDynlquCP07PYGZ7PDOwVeR8hBjrJZPf49Hc9I8/8YAT6tsyBzlM1FE9Pp
# DATA wkJY9SYmaGBe4vAJJGgiQivUmCfxmZ3OO9iIa8HZuRiAFqmjucaXWsnlulu/tOKeLDP3cBiTResf3c68wEQR454AJLTTWZVaBBCM
# DATA 4xzLPQ+9x5eVKD1W51xb3Yy6cJNbQ7TARhdRdrVluD+TBss/Kz7i7AsfonYKh5bgR08l78vzZ6HMKK18P6zx9UUyajHGZvXCIovR
# DATA QKcY4OPKltFcM8+fVUAbpXV39NWz55+RZp9uTU+jWrmwsyAI8Xz8+xzyKOHDMvXLJX6a4ElJFRHRQ0/7Y2oEpvITLvknHYfq5IkI
# DATA xdzfWxeOp3yDeaL69ikmw4CBY4c+4ysE3kTMLPGFUGz4SuwX7WZUe6fEBAEfePHzmkm9inwA1IZaTrHyL7EMI7wiLr0gYRrphVQ5
# DATA iE3JuxYdtofoLHqEf9dWOUvxJr7RmiC1YxvNppLBm82y9SVc0ZuS2LiU9gfZUMKMDo77oBdpMJAhgBGjLAzKwj6Ds4+GrV4OifsQ
# DATA Sw9knCqL2/iN/Tch7UF+XQgkkCSarSGK1egyUuWA9aoNMUVgwIigBH8fERwwMbcU01Xkx1XaSpyNs3N4aj1wWBbg6QUPGYw8eM6d
# DATA p66NB0eSxQ0wODujqpUCFBJ8gFbdeiRgxlUr1SAYqyyvCWyQVafeY3HFsn0shuzKo2ui6YaGqtwBe7IKXnPn4y9lHPTWmYwRQPnp
# DATA tTSgOGbdJYseqRjFGSJKZdWqxOteLyogAZWFBcQFaWoz5s5ok7Mnixe3YQ6iqa1onLbizp4gUGHhe1r44vdMWJRlZmpfAIw9n1LT
# DATA kB2cIAhyeJQ3QKk+dWyK0qZ1jMJTzWoUlrT2dNWJ1i4ob/YNW8sa6YyeIhWqz6qIv6I+bKFVrZEiUTcp4+LUJhGvtf/16wDwyOoJ
# DATA ocoYsivKy7VnDdGUmbMVzkShK8AUYdenfseglcGnlF5sWrPEKd0lKWzLrx6z9UxnChFWPefiO5/Sbpuvl65EG3R5eWnm1sdDzayy
# DATA JJxLJZ2qs770dvbanmumIbFK8VvJT122PeW5LP4Dpa3cuvCrpuUAA7dIDL7A6QE/IqROL5ZYo3x4WUKtzyQ0mK1S+BBgAyFWDpN/
# DATA lj2VkPWZNmL54LrY1Dp0GVB1w+SxApTkhzvHUnkyHgmzJIPYEu2W5c9R9jIsUlJ4TrRtC7B0dymlCCijc1OnFgKmPRxCL0ZDueik
# DATA n4LPlgDhxhfREuLMIoJzNDkz45uSv5jTq+Sjvu7OgxgZ/boqSbDmc/TYEjXqIWkFNfqI8HGQGb9r/npbpizI5AsqMsBzmA+JC/G+
# DATA DOiUYgWrt2+7CF2OGVGyYOGFlPA37NcDAziGTvBOpmeZONguMGXUX5NkkfsfzYvhxPQ7ndCwy2YUUZB6yuDVBgguTOEFo5s2yjZh
# DATA qDEuwnyzCQ4Oscxgc3IDdxGdueM9eQp52CHygkvR7ur10+nEad87zPTSgya8zCgeomaQKqbW518OzkXsDKJRBL/F0llTSRv0PT8o
# DATA M7P1ujjn1FpFxPsTOjB9mLELj3WmRIIyzsk0pl6drOs3F7MjOaSYO+zzLKJ7V7SSI+aqsVGTXzT5SM5jh2DINfEHf2JOx9mpZExN
# DATA styaXfADovVSeZ5Bxe7mFo0WQnpPHaKhw/MdPN4V3N4r8KLJL5wTecqiFs3x9E74t37bpkPXBacb5+EDkeu5z2PE86NoA9ssgcQu
# DATA RPPg6uajPHzCzWmPVkZHJK11xbMWGT5jPjMxN+6nTIphGjLTEbzNliMMjO+dzRgB2YDSDssInNanDa2SzBqB54ZLrsid3mA8ctBr
# DATA 0O+nbkyecPkjF9i6422IL+MyJcWlGeY6hftiJIaV1amIzKapiZycx1hqLgqaa8tObY5373zk6l85Zm3TQqVWuG+pA07eCyxqdQMX
# DATA o2JtQe7XDKs6IAjOmChXg2mtBT5v0vNzsRStsK1Pox4pVZolLViZZqJsVFIKAHHPGGugJZ3eQy7d5NLTehryEPzBX87oltFq+1JY
# DATA BfIsIBqSFImR5nlnkNOK+X3WxzX+lMNaKD/I+DKVN0RvyZHb+/V4Iha4AKmBX4+7v4Hsr214VrM2ovXefJflwmNR2xamkgjtXFWs
# DATA NG1narmXcgnRDwJ3D+cWFFEz6CVUXNX9W4a26IT5feJNOl0sn6cDYs+Ysw+Si/Wb7sbMtXLamrlkmnnOoTOY2TQK/dBksaMzRWHq
# DATA 1CRaXrFS/UztAyeWMmswS2DrnGAG2vzU4AGov2vkw9WD+0Npycrg0ET+2mxae4wjestBnTqjkYsJukj50qY4GFhBNfNAI0Mw9Ofo
# DATA SInpbMNYOd0RSV6PP0qDimTcc4hNf2a6SqGpLrLPdeu9DkG7csVnh6qM4+uHP5rEF0shO3CzQGlW7KaPIqo3qnwD2z+DRMgGGp4u
# DATA wpbxfWmu41anj7OPkqnsjXKdWeNxChaxgEjy4MgLuxk3/3uFYFF1o72+/S4yudGFsB862bd8/e/XOaHcKtYAaG0TQpApQduMauY4
# DATA ha+/3Bko9nJHYA7S+gTCx9xiiSgRtf2rivlR0kCN/fz3xmcaHSU5izU4Rj6bnochABXX/GHWTSWtB1pPTt0ZYx5BWTvXp/NBNMmn
# DATA fAWkVads44b7h6VoC+qMik3w3i3Zr8oxjW096QzUDIM1oNYZaKlWa3iA1DoHIxu5oGiSEA11wQ8+CdTcUvVeAdgxfljBtC9hrpei
# DATA MBRfuFD74wFpux/ALZtCU6YhWVMNVghL8VUOvT7OYYPy8h6KLazuKXxSMhnWLR46CZeMbec2Ok89lsOQy60GErRVyWxpeGFBtdtE
# DATA Umo2cfjNJhBps8kT4MSOkU/QggXZFIICAXYTYvrUpwkdssf/9cUv1eb9hOIvChzMZkYjYHOKv2BiZBBnCPDAglxCAKPt03yUnaxR
# DATA UnJ7EKV3gSqw95XkneyU/wKocv7z7jb/gWgxf7N9d+MWwkHh07IdF7mOqhlM/dTpHXTHbUHjw3xOeT3pIfoDjj8ZZj8m8BuKB8PQ
# DATA 0HG3m0ADtW95+mrJ838zUaMvPiboGIby0MErFRdN5lcUdWvxZYpjcZOevfgVoJ6dazX+y3/+b8r/1Gbd78IBrHZjbXD6rbQB+A9X
# DATA L1/Gf9X//H+Xrl66pP/G58vLS8uX/0uy9JeYgDGEiqjm/xdd/1dffRX2o2KyZKSWIFYMGpUcdKS76wA85jDrZq0cAL0oVnq5tlL7
# DATA 3kptYWHnGLzR7YKYTjIZHavjBoETOdQJ4W47R5B64zjrDjCi6hi4EEByqrf98dHxAhbS95Jk5+ZmlfCCD7MW4HGhgRiivU0fQfkK
# DATA T49bDzLVuwxiJMAe266pvmVDDCRvq5N5H05kwJTr9bWR/cA+axCc+FF2MCaMC8CIA8GU8DoXADN61skWsKF0Z9Z4jtXZZnc6/Qsx
# DATA LifS7ODH+X/A/n/t6pVlf/+vLF36z/3/l/hfOs4zltPT6wsLaiPko+Qs2Rx28pPWzW4H7+30K5lgaA5u61L61wN8uHiAZdLydf72
# DATA xw9HdjGQah5m+2SpKOsWtm/e3cQkYHcx4SRiFv9dVtqlBF457py6IN/7ns15HeANlYzL4QWS9yuI7uD3eZ29rosLwI1BVbMHPTwc
# DATA 9wiEZpiNczgdS8P+wzKnK5P02P2HyV/9FfxT42xuTtS/3RDGb6SqtFEHwWfZo4GaoNURftoD0eyDDxLnxeuYsfYWSP7lcvB9fqDu
# DATA FnlN8dUjCKNXldCcypMPPnBE+7m+uZgsy6i4KAuauRuDVadcMU6nuCYQQU9L+HXSeD1aFf4uq5meLCy0ACci0TOubpsPOnClKRF1
# DATA VTDpiqQslTUA5d8riz/aXap+r1U93Du7Nqnqvy9Pqpf1j0vqxbXvtfb3nCfy9/LK5LuLtVGWjzCxO8w/ZCaxJg4ygvQPJWHqK6Qs
# DATA gxQlKRSmxzJ3308urZQBKVdRBqwbw5iu9/D+L+cUHTDqu7baNJ0WZE+7LriRim44F/dUSrLLi48mXM7AFS6haau1Bh3MXZ/XAN3t
# DATA Xq/zk7G6PiYP4Rysq+2N450kE258cTHZyvKxahsTAiYtPLCreLUTdLmKuJxAc0ijp5KRDHIswHD6gMo5zB70D/gcPUyGnaPjUV7T
# DATA y6Y7rMjsFb2/5GlZVhgn359Kdm9LkJckB8et3lHWvi5GT5QGdG4jBzqAvM5pqJRMp6uWE2pvmBlUC1owhYgaDtMHvKhu9ZBoE9as
# DATA ksiurZtNC/+p9foPSxD/sryUXEguXb2i/nvt6mU858BjFLdGPdmt1Wq0gTj0zFmbHRCh+t12cjRsqeHQNe+gP1QjH/QhRwjk6wU8
# DATA wbESm9Q6IIK2xh2sqbUFkUJq61Oi4RZQT+tAww8ixrKzyCCDdZBOR7TUOEYWg2ILKn/PxTyseaSVKJh90X0Q7Z7BnE8quBJnPHvW
# DATA 5E0mzjIzs1ZHUg0kztIZL5k684awbHVkvIDe04Xwu9XNdSsSq9NSi3kHrBeH3X5/iAyUSKG9immNAAsbk0kv42LqD1V3Cjj8G8kZ
# DATA YDe2QBteB7DzbJIoglIFg5bk47ChSTmZVCw3UWBCFbWnW92jvtqwxydqJG9vg38G0tAUJvtmf7hObCnKbism97vNeYOHsqEOuq3O
# DATA SX7dhvFW3aKngIarVoF8AEwVpqkz3X3YDjyAPTUAtRUOAEpNVbV4IVlN2p3DQ0IJRv08osEqlvO+onjDViGpUa7YGOxFIeFacmEx
# DATA mTgWJO6bIl36Cw3VdJYDLcALPgL4PfLNhn0OWCcg7q9v8lSyGnX2i+H/U3eOzfqF80NddXs0esfY8+IIPmWdkio4nK169BltapuE
# DATA O3HG+Y7USh1A8bFGqUgx81h7rJZGMWmBtW4Njx5QHucGoODL/NC8UO0AKaj2jRJDzlyijMxknyRLwKQfQxqFEsm8b9SoqndJ0/pG
# DATA jcTdN2r5oAv3uloKSM7JG29AYqzXG8lrsMcDFbOSYgcjyIUM9FjSsjFiULUGg0VU4dMQ80URrPmj6uAoLdeoN5tH5dJZ1G9SDaJH
# DATA IHzbSJh1PU/qIKzdWt1ZvbG6vda8t3W7om74j+rJSmVGPTsEbH2n01WycV2xnuYSwBF32t3Me3WJXgX1TYAr5QfH2UmLRq5aLxV1
# DATA q1zLM0DM3WwNW4qkKOwfv1VLq6Y3xXjTA+BpbkvAQSFRlqJ2JQ1E4Diwafs+U+K1tklVeIwLbuZLILfYgUcJPB1gM52/I0EHRCQQ
# DATA RYi9Jfa40nBDlEv8bBojtufJGPW3793Yvrm1vrmzfnejuXP3nbWN5r1767fc4qubm2z4rwSJA6ZUt7V2T3UZKzUK1RpIFCWSuNQ+
# DATA 8jIekO6f3nKIr/UpTqlsQNxmirvWMprKImjg55/BI8QZBJu8xmr4hYXOgga6zzHjsUE/CJAc4lro3z7/Hdr44hiGPu5ODeOSZO4e
# DATA dUY30WieLKtjyRop49nxWJkRfxcd0nA7lei2QzscjvY+peo6MyRQiVFDRe7Jk+sLfwH9T9Ps/m9UFTxd/7N85eplX/97aeW1/9T/
# DATA /KX0v5soR5m1F69ZzJYCala1b/FGEahPnFtW1lY3MEypx1Yl4JRXL8svUATJ3/18AfHMwTeo29kXMxR4JUiRYSZ/gTlR/63TWsiT
# DATA UXYygPsdVTgeqiNpn8ICpVZwAYHDekFXTV7+DEZALlroHYsezKTBPWzPA5IpmJjm98aN23dvvlM2WQIBC7NNKQLbEKHOqaEoT6Bl
# DATA xyRUcUTOBExxeu8lHLKQ86BQbbu5vr219lbJxqV2gKolGyekmYnlXTHGyVK6vvHu6u31W3yqAJqDi9TkAbYSQJc0BGIxA8OfLeFU
# DATA qQM8U09L5UkUOXvptdfKs3pketK8A6fVjbXm5tb6u6s7aw68Ox5NPKEmrc4VP62OdsBbcBzDaeXxv05WJ3zCJBIt7KRLsVwQ8C26
# DATA PuBSdPUH4ULMWATJC0HkWgvcDbnTQsbkv0NAtHL31z4zhd01JaXHFHbHOQt4BPIbBrGydPkahrbev48pguyyEGTYH7ZLB2XQh12C
# DATA R/xTSenLK69RdJ39VXme6aDoV5SmsDR7mtgJpDAAjjsCNwKMuw0dLWQyCWHIhznCG6WPUmZndOHZLJ1duMDODhKViRESYeTtJNi5
# DATA pjrJL37+lC7x2VKcZ/W2zNXG6rur67dXbzjbWAKAKajUbnWD3mxnI1Dg2Fni5ZWOGvZr02D3yB5sUEPdHAwdnjGLKKXH/RwV8vvD
# DATA ThtD3dMeuB+WHSR7bIMUon5vKeV8qjZ1l3Y1JJP2Z1r6F8sEk+6uVv+2Vf07QGY3fzZr1T3FvxShTlJS7J1r0jkyu2DyDXkmKQQr
# DATA 1xcRvVzjKGrgSiZRdNqSH7aDnJ4MXiCQ9zfvbqGbL4EUaOdN21PJal//CZlAsB/2PqYAUoyn5j7KK6xLnaeqCjlVDWuQbaje1PDm
# DATA Zq+3qgzBbjB8W7MZKAqkgHOgnsFv0c3Jb8G7lN8/GWeU3Qd+HA5bRyh86MLqyNWtIs4ztYYv4fBXvGHpZViOO7BXGjIWHanM1Dat
# DATA 7rd3dja3ueattf/t3vrW2q3UOXW0znZoyLoiVStOv7l198YasDElZpHeQtIgq8vE6nh03B/ynbSepDfUhVqxGQQ4869/762+u9Zc
# DATA 3Vynk0ZdL9ChOlpKzwSDar4HoJqagkkxxb3YTX9QVbeXh61hO2vDX+g2lqr9VFtS/285vR4vuTnsK269l+hZhduSp7UEUkcBDdqj
# DATA sbf2cUXxhr4Kf98kAK4uRGNXdPbCnDSoENJPFzT8rob/hXLXQKuqbuSiGmLVGirX80zr1w4zYBwz5ohBkBX75IECJDt5PNdTvPoq
# DATA ogRddKtbp27QD9LCoWFLGq713xd7EtMPxZC0DqADpFcAtSsIeY0lgPAY997PG7t78ALYMHW7RMPBt2iRker3++1TNZnw+cUGvmZT
# DATA 1vXOYQmevn75AmZpgf+Uz5xJux7pl1SsejahvtQGkFbzxhgUtjWQz0v4XF2GJ3qa0T2tgV5plLuZi6u3B0oOporKtVGf9FoozSlh
# DATA zkwX+Yp+8IFoavH3K41G2kfLMlrqqFBNL6lXWr+wPotOvTXEBb1n3SrUi4ng2ydnB121B4X4kB5h7JOFEhJ3qdx4XROzGLsbtGzI
# DATA 2Rdbg84iGcMXtTG8fF0NvMT9l6fiCgojYNV0OTIAjaVyXZplA3jYapGp3PpWVZ83VofD1mmtk+O/HLGfl98Qwzr/W+N/1beq86+4
# DATA H0E95Vh37SbVZ1Bud2nvDdKIz93jxfQihjJm97bWb0owglTG2nXFcMqlslZZqXXx9VWWLol8Ii34E424/RgA9rR2Ckp9Sa6PBKH+
# DATA KT2NaqbwcKgkqgyC9kHWEMpVRLow0wBii9soppgSydN9qSnz1VaN5evAZdB/Ca8MqsB+VuJICHMP4AsMHzqKr1CockUcrFgkKr5B
# DATA hZcMbsO+YeCjaYfl5upba831O/DfUJ7Cq7Vc/Ws7GVzsW8PTWxJaUiIQDkihKtn+kCJwyFW6gh/2u4pBO6j/EuJEr8ocOi0qMYjK
# DATA Mh1mwYxUoAjKnkbOg4YtPpGONHL+YilHjRoT2Uu8Ek5ypJcR3IOkHWgLi1RefBeh678vZfOfluhPBbluk98ylhAIictk6dxDCKrs
# DATA AJMcQ0RclcHR0S2796CsKXMXqtwTODwoDv9FUcnDUQk89wn6oZ+jCsEZibrQqIUdlvRAzG2lPF/nGYG9WiVwyWp1oG4feNXJGHzS
# DATA BomjXhSDYhTNAT5XC4oElppJ4C0XnQvxTdeu57aTupU5dlv/6TujF21ZoPrVmzfXtrebb6odC+ItZS7EezqxHdATGmQXzB9SxHy4
# DATA RcWytuisVd8rfpy1Qcf+AG70Miekfbye5MetIXl/JJRERXGgUyszLHA/y/Gd0kjBDWLB5I+MQy5xXjYXYomd65XwHdv8ad0aWRrZ
# DATA 96oADniyIPlQoC7TKWA5mAsrL0kEFnXDRhjGb3ncBPMk+BDRivqjY4CML6jHzQrFd/lKgh+ZxDP2xNSgJkDsl0v+KzrVqMyVA1qB
# DATA vWAAOYL4OEtxqdRknE0mcoLQgOpeas/d1IZvgQvD2YULwoolbt++K3M2R0l3oz8FTcOFC7R8k8hl2Zo6g/5mV0yQFmcpOkyprgtB
# DATA pzB29Rv+mVSSgGwqTDPmqPTvjeqZ3Wt+36S0arO3oDovRQ9xB0KA721s39sE9YC+a4aaIMglZINpaaC4ioMSh/F1MWVPxYBVy6c2
# DATA WYQBWpQwCI4Gkp5ppKDVQU2hbH+EdDUHOKCeOloe6JCtZ9KHktWivNyFsDFp2RxW9NzpwCsNj//MOd037268eXv95k5kmu3Zxci4
# DATA M3W2jUDR0VW0Qpmkqfm6fGPNe2s0agH3AtiGkDIQCTyVlHxuDl9rHqQSngJ3ZPIy7OdkWuCb1TFwoC1BzXjRU9/mpd0Lpk2Y5HI5
# DATA 2M16CBhexqUdhxGEhCH+sOdkAkOGX8I3FfEB5EjD+oLLvTRxUlInpkyLt6i1gCSPaK+q7V+9zJYD/G43pUgHSPflWRQI4568D1Fp
# DATA xh8QT9grkBWpT9BmRT7Avb0XVMdZRf9i/v8cRfqNhwFNt/+urFx+7bJn/125/J/+/38x++/2ae9A3b17YCyE4BTytHE9j/vDzlEH
# DATA E7627Mwr5IJn4OFRvkKBD/PdPBpZ1l1+wpk7xRh7eNAbdeUHwA6qL+Snji7+Rm3IcOF/GWvxO2s/BAXl9r0bzc17NxSjb966e2d1
# DATA fSNdWN3eXn9r487axg5GPqAgAulThumPSm/Uyd1jN7k/2rtYfiP4HF9caNQufBcSz2e1O2DRO+i28jy5hduRjhpz6mjgfDUvxBB7
# DATA /eEJOCMxxyq09fHha1/DiTWylY++Tl5PriyvkF8lO2VBGtv7+f37//WN79x/tLRUvf9o+fD+o9cO91JmYYEVz+56SgNtsmqdj0fP
# DATA jMA82rJH0JPQGGHFWRcq5ee0JTC4CJkL4IpSSS5fvhQ1T5x/gPAljVBXUiM9VCnttHutVJ8n5VoX0pmyadq5nTsB9vxnCapzoowN
# DATA cVh4LUAf4bE9b+9BJQA0gW2B1fcKWnPTmk4Qj+NTj+BfNbA2ZdsCl0jInIcZg81faPDzsmWBirrbLXn5ktWOWXok3rAXP4C/1L5J
# DATA ARppOCrzVWKoe2A5Yga1I15H2MIu2/1US/wnWv2uLk/kTfmNudp7CarnnJdiq9qtV5f3hIwpAZpMJFqukPrlnaxLV1xVYFkuL9Gy
# DATA 1FK5XMFvugKaXFrO+Bd54KvVv1WDrTX/vrp3UT1a9J+VL9C0Q5qz84+UBTikEjKKWA434lIzoKARR26z04Ji4zY3i6T95LulQTAB
# DATA RgBP5umzuh2tvglX9p2308j2+ybcgHiPApDLRn/0JiC+eFsVvGt4JuoxB1bt5KDH8q36F5XO72C0tHI5uUD/WG97AMkEq7EcJvo1
# DATA pc7vO7SyEr2Yzbe+mJGwNWr5PkPWEC4my2V7s0HxsjvMl6MtXk+oT22Gv/YkItgcXdAfkmeKux3EV6WmA56Bsb6fzvBWe29LiPLm
# DATA 1trqziyKrcido4i+WhcL6CvillZIbJqUvt4qBmpslCUhhubgfW6zws9gbM21H6jhWr83bgQq0Rvwbad3tH7X26IF/bu3eWt1Z615
# DATA 4972Dx1Np3xy2sm6beZ7vNr22opXEkJ/gEtSXkJinOqYpEmTsGFMYjDME0OA46QrQSh2U6ggZ1rxtG/c3WneWd1YfUurjrS+cEpS
# DATA bJtdm7TrAc82rxzGbVpwysQh3s5DMSB/YU7tGDwkrQbiTFllXAiuBZs92gomqJgxh0TqWE6+30DWgS/L8Gv5apF44tXFAjoc3hHB
# DATA hQ5odFRariyvXNOOSq7nFTYba9BqjMdb1HV+jZ2/9pL0IonMz8yySj68OgkC4QtLLEB4vMmCAZjDuiYmIzp2kTIXYmdt8RfZpl09
# DATA lfEPAS2OTGEsGsHe2qh4KAQmFduScq/XiQH5TJ/Dm3fvbN7d9tS2Ec4S3u6iOeHLUXXfOZs34hAs5y5MFujr8Bhzp8i8pN8LvilB
# DATA E2c0o0PU8oIjQhL3bZZ44lC5mEHRSwPpZHZHtyAru4O8IFvp7l6sKcdrluuJYo35Le3qH269MCmEAoLud0EudLuuCD2X8NtdAuje
# DATA 89S9+E7U3XiNwCehlYfWVJrYkx0hDxxBiHK4K0no0srL8QMRgAwEJHNPnkymIrEUqj7gbZ82m1Zr4M7t5B6AmS8sI9fE+UfdtFHS
# DATA YGAkGnfRc8ZT6padA4wrKW5FoOq44K66z4FXCd8SG4qbLZd3l/cc53PBotutw+UPPBVfVeVeTV+16Ogn4z6KBlRwyc7o0pbHOJAS
# DATA lqyIyEra9U5XfwrllUBb111gV2mIVlxi9UpqsxV49/0Er5UlrEmukfDDTqydfictz81Y3MuhPXPUzeW6ancvorCQYqCMwklV5yDq
# DATA 0r4jyieMaMR3jeUyTr4117aTFpOVJOkozSJD4+mCPTDkSHsmPLr23PUNaVQMoRWm4UKThJUTXS5H4lEV7OCwf3RhkRyyTut8lJn6
# DATA amSPDJBzpzNsulNCbnLLqT5mgJ3Czy2/Etc0G7Z0mID2FRXQ0GY96iYh80BldtUXe8ZTyU6e45zv8pWvRF0457HOpCiNkTYR9Ros
# DATA OR9lqA9kHXeNsyaUF+J0wamYHfKwWqPqBBxB52YQBSMgTuynoKvFvFxem0geNaqC+IFwVIGFJL6wn5508hz9fZzNdJbiYJUIx4NW
# DATA FxUKXVSPuGfH2SNpQJJ6UvlOeyL70NgdOGyFMD0aGALASFpwE+K7Bl6czG3B3FHDS7NzVynY3RxWoK9kJj8JIZs1zsEobP5Jgwj3
# DATA vjWB1EKgc7GFOazEMlfn2Ygf4jVJlgCdpAYIebIlazCJaVvo292w9B5URx3aNeu4N7/E+PbqxltrMcZudpQ0Tn2m7Fnes5D6HHH3
# DATA pN8GXLm2kf9fmp1OY6Veyj8WZxeKHGOmMMeXlGqtzsrXUUKaKemei0n7ovA0Xhzjx3J3LBCpi7tefFIWj6U26A9Kqnk/VCiQmqPe
# DATA fmF9eFCIHFJYXmeM8x2QqJLgO/YpwAtje3wyyLXLW9bLwZmolR90OqT4rmD+9t6osSKZsudwW+QGkJnD/O+naeCgEDtIcQ+84t4k
# DATA SHrRgp4lKrP9DxorWMZC6uMO2pWN9zEoB2sL1p52vVccyExNSUMb/vjrhWmUpPnISw2I+w3/6DAccMnlpVH/BJ2KrRq4cUEV+kR+
# DATA hW7MYaPC2/Td2fnOv/FL6XkOFp1pSxSK9CBfZP2gukPGUm9UYWBgJkfn+MulMpzmTkeoHldzR8++nkqX66UsCaAibiz1XwPYEcoM
# DATA kZNGqMCxxuS7Omn1OocghXAmLONhuOt0L5rcShIX4UOTv55TZ2GqRVsPEj23PD9ekzDLk8Ssisq2yDRXI5NAYMfeVvQxl/XGJwh2
# DATA WhKiMVO352XqGqELtKX4CLXrpoGSOXTL8YYiIqtFPjETIK4s0JE17vgGPY8sYjVaMJ8FbcQpqxSnCQYI59oDjcLC9NrNZM7+kpdK
# DATA srO5eksxYrTybA3/hDjAYA2FOobghp4ruZnrPO9SESqTxbnqRbKCN/PTD3q05Y57pOpfOP/BHpvbuRfHGFctpqqvARec+8L/P5DF
# DATA Hf+/k84R4/t9oy6A0/3/Li1feu2Kj/+yvHLlP/3//hL/+84ri+N8uLjf6S1C0MTgdHTc712CKLG7g1FVsQnO+Qqho62egcsMcEkd
# DATA 6EjA4vS8AtmdrjU8Qn+7Be0VODglbzzQZMDOFU88+U2BvH8Ht8Gv7QYYwMdA5gNBkgEvv9l+gbYX4cJLJ7iKQtG0M5pSdaKZGH/i
# DATA dN3W/9veuzc3cl33ovmbn6I1sk4DMwD4mIdkyIjMIaER4xmSITmSFRBBgUCThAUCCBqYGXrEW5aU3Dhll10ndf+4daqSVO49df4e
# DATA y5I1kiz5K5Df6Oz12M/e3WhwOIqTo0ksAo3d+7n22muvx28dCLaXREJYYwBkrUq7jyWtmC/TaksVKatxhQKW5K1QpnupgFe2WMiW
# DATA eJWAFiRgGfyauxrjVX0XnvGqDJXQryZsyaYOmuP7jSHWIOjfAiM5bo8Rj2RF4ZHgExOSRDyAM1GnNZNXWjlk+4abbg9Q6A1mJh0r
# DATA iQ4Px7Xtzsaj4LaL6Y1Lg1PORaYbKVmdGE6D7RYle+qVTZgNQOIbTaY0YdPzjFmRdp+OoUyrGWo17lJNJQPjwdb4b8kXc6eM8zVW
# DATA x2Ew1UOxM2uwC80bTFHi5Mhwmna/J8SkWG80N+gs5ohKDLy8NFgKPVaxtDKc4oW2s9TCYqIi1FVL/1FKWiSjHfRd53pBjoYRQ2jw
# DATA 0tgJsVBOifXNXQBZMYok8XCysFhKs0f2DjvFcnZCDSU7B3+gt5rq9i9Vy5S6jZzWLado61ZzFS7IqaAnTx3Qk7PvFvQkhyMhPSvo
# DATA rpdsZ2UmqpJ2lQaT4K1bN50B17TfNU7VG0vFdOuJynyUwi1o/Sgv3mRImYwL+F+DpEBh9kjMADBqe7eWOIw7Gzen5P0dW6Gec7hD
# DATA zSYke4v4Aj6RKBXrlEETKZZqbRziiIta8NRqT3QOo9NoX3Owmwyz5eAD0eLbO1ube6365rp8xibeR9hPSAN/5vZowE0m+qRsZCDS
# DATA tYwoQbQ/XJ4NLjhBh3HE830Jjgpo80Iyw6D8gtVPaubVYB1ZhsREi9n3q90ZD+M4wAwFKthbhbBNhgh43kHfSsz1yJX9DGD44Sf5
# DATA CsfaEgaBeE5BMAcRCL7ky9klfPT2yUHvaDqcxhyXy1G0MXsyw1tSQ2lOBgTI4w9Y3nhWY3qkgHf/5Zgh+QtGLH7BqGfuNUv7h/1D
# DATA amqQE4N7sHKcsTxUyWaiO+VZN5+VRQUe6w0vaVnNbsbGOvSjEtiu12oUzEPdkTD38ceEJtTfepeJ5VLIV6oRYF0AmvUoHbvLy7rV
# DATA xrTGyJ6lEk49TnDK2GCVNbJJE95/C9IAWH73YrdM+xOtBIwjAlYU3dRGao1eR2Y0bsVMyAe4oDkEmw3MWGhJnT9GMG1V1fDxAA1+
# DATA WGVlzIWq5FKz1KS8kcedcaU3XOwPJ+BHvajDhRNwMJaTizEJRMrQ1oyVHUdCAOnxPcru1CJ1qrysPH+q9lhQk6ZeVyJCspNWyHPy
# DATA 57PZ1AeV5z8/0W1Mf3H1zHqJZ9L9JDoBBzXfHdaJIC8kwAckHoG8N6oHKnCeAsmhjaRxWP4CCwkt8PQCAbtuhqA67XbxUHR2GRC/
# DATA VKtCbZbHA3tjUCmMZq71Bf/ptrHhqhxRRveLygucoEIg2FiI3ZA3E6WRmoG7Ib66e1I8KjSuGy81yRBWo9jxTnsEWcRaw+lkNJUP
# DATA J4Q7VVt+Y0kxTR4nDQsUoXqCjFSlHONP4q91p4CmDVsb0LDMwRSEI7xFMkYmfJyi/MtAKPFkSF8RDkWCoSDEyxnYXRg6xfA2pcQz
# DATA 6PuFvaZsjxjvZADxRO2YgPsLdsKjEPK7TTvHgXFjgASTF784/xRwkoLzby8+vvgIs1JCEstPLz6BHJPB+acyQ2XoQM2DC/0HA8Eq
# DATA gsN+G0fMCE4fYWZgljr4ZQn9hMBMn2Gzfzh/DvBN1IqT2DLZFmQKAfebIcCeDHpRFxs04KGC8y/E+3/CdJn/BCDmyTrW2gOGGAUQ
# DATA IynjcEe77egEzWMhP0A4KxN/6nNfncwj2uzqZKh68P2vMJXyLzCR58eAdiVmxp8/VPzgmeiis7KKGtEuC8RIGQqJ/smQQRQgyJJ+
# DATA Utfh3kASkXwEhMZwXCb4lpyA52ld/U1gks75s9DNOSovFMmstYXD8Px/UEZpMR2fnT+TrRWeqi13VmRy+QIRvqBjv8TM088AGL9E
# DATA vfoseJrYvmdVeAjjP6sEZlprmeH+U/HnU3wZkMEggerFx7Yzrt5cglloLoVOIsBwCoTRgyoW0zUrEQuShJRxnLV8QSFg6E1q8LA+
# DATA Xa496BzbN0aebVjdAkzvM8xCC5m6fz8bHS2F0C0VWsP1lxlZXZJxzzZ3JD0YBq3hXNgBJMWmOQuqqNShydBG+KFQtEx1CfWaPfz/
# DATA 10qj+6XiQC80EUwdCtKqFMjhMJoV7fsyq3C8ek/nVHRYiVGJJhpSoGs9rDjuIOs3TgcCPcnpIIjLMbqyNsLyIb8JvxWbTYkVwtYL
# DATA ilNqkTWQobFQWciPyMDbIi9ElVWbc536zmfRWD+KRjVC5oaPGsXK3CTa8ODLsgCRdPrbQipQte49bySStThMyaz8gbTg6XilZIgW
# DATA 7LDEZkXpicuqFdMl1aOqJfG5NJ4ZPIWpU2pJ5lJcSAuysaUlIhiGQAuvE0lK4aNcHgzLqBoYYboC9QwgwpAPYT5XenwIrol4ZrGH
# DATA CKwwiF2uscIR4xYc3zzLNdsJvcG7Tuqe/WexU3/Hm5MOSXu3ehKa5BFYFkxMfOSimsyLFcp1AKepjYY/C2Le8ooFi12lKygePrBX
# DATA W9FVmXsA1Phj0yra4Mz1TXmlsn5FV7/wYNrrg/Cj3f3023PCgdkaPBcQbDZEm26YtNSyTafivqW0h5p7w4q61kkVdhmyjYn6PbfA
# DATA swXLfQsX0uBRxaTnFsJbgm5amk0x86C0nFamkw4u+SE8KYSvvf/ayWvdvdfeee3Ba7t/Q75tXq+vRvUNVjTN4ZqFiA+B9AgDhyyK
# DATA QsW9RvPILhU0eyRgGEGs3jkpBRa0flVuQohKNoM5q4EitbOFpEcIdq6kelBcyHIko34T6UtnsnxvSnOF/S59Y34ntTbWTKmnxmzZ
# DATA bRjJ88zN97gdt8YEzykq1Cowietp5EpQF/MWhio4TJZuceVymy5o5fLfTXuYPlfNt2SWblCTWa9mfLoDHsZuIWbqm6NZk8GcTY2K
# DATA PV4LYTQVtpQDMtg6MXhEIGLap9xIIqH7r9zYuyUj5YGBCyuF3MQuZXO/iW/JWoNW1XFeNjtjQs4msTLN7jhomSl+kSkEY7tR6WrT
# DATA rCcefFifCcRxWJW1uooYLwNveGtsmrEEXTHdo367I5gYACaFP/iB4+2Xa+wpXTPzX5ngyJ45J12qwkbmdTUUNNV0VY8WNMhOQytf
# DATA nenWasyVw1dUJR4Mk8RWmyHJJ1RZKXK6R4mnxXCdJLQ5U26T/EVOTWIeYAS9SYs7LTm4sbQ0RUnJvehbWRM+0Jk3NGyIUo+8YmrJ
# DATA FsqxG8XEJU9V9GqwOxmORoiSdiSRaGN6VAlWA8m8MJFWLxZ95uyyaFkSd/EAQWulO5WYwSdoAl6/W0msLXVaadxQ7u1GkpOLL1KG
# DATA 8sAQXxeUUe5SALHJVFHP2qDX0eMGLnDJQ8Dc7sbrSb/TFupqIOincGep6A/Y9pxKamiXPJesJq70KHKPPJqxp8nwq+Oo3cfo7exT
# DATA 6h0sZj6BItPY786c78QjQyJ3ANS1xLdCenLq2hPS6k8z36DDNpl8AC8u/dhIHBhawMY6kKvOdurly9O/KM0qXINYt4rg+qDk+AaU
# DATA e6T9+pbvWF+gai9XPskZKpPQb6s8EFv3A98yybWvib05kLOOAXmZ6ydXnlTsXXFvI2W54EPdtEVzJunfZ14ndW6Ci1+CrjEwNaPn
# DATA X118Epz/Hu6c+IhzEXhnABUghZU8aOse1dXHqDX++vxb0FaC4viPoDL+FtXln/EAfjvXyqRoJnKwb/8Z3Oq3TyGDBylnrl6nwpzj
# DATA +nV5t9BH9NscuOIb0pkt1CRFB1PrhZ8tv5yUOAFZBUPRqmOXDtn8R6pG5bWDdpzrxn/giUXe/qQohKtlQUFujWPMHCSdlSur46Mp
# DATA sLNt/KUgjZxi7LVWSxwbrVbReBNMjK02v1IIlZafYP5BHVIDMok7Q04EEAtxRVrMUF8p5QjSekb9Lmk5KWyLxCc2y8I3svqRjY01
# DATA X4R1g+Y4aWdHFhuqAKcyXFHgq8wJg5ZnFJvQPocJWKbjvqnx8w6vjIoD7GXGJJTLGDYD0X+no6imEoahQbEm38E/8Fasb5XwrWIY
# DATA JwUnVXOXJjPTOzgtJdM9wuIAWIicvsRp7kh3+KNh/bb9JpCi5TXK30deU0MOp6V3+RC+SstlyVL4HOdMBUiysWAJ/G+Nn3+Errlc
# DATA ves9kjg4XQMdHZTfoIFKsP25+KxXWU0D0txGFUzVVINkRL1v6GE1s5aWky+aPM06baTa3yxMVdOFDj/zTQ4/WwYAfKLuEvhNmQKU
# DATA kl9TT0vsEjDvi0Vrod2j1UIKaLWAqbRaocf1lNhNqpekyszxk+h0dl4OMCNEDvrrGNyMwvN/w6P8czq9cxqELCsk2JXfDDwmU1Y5
# DATA l8gwyjmKMK02nOjfXvwWGoHKyKAKh/yXUDu0XwkEJT7j3kBiJGz6U3z3I7TkoQwnZAIU6UqBeO0jSrQEuvJ/NHKGY8+eA+2iLQvb
# DATA BARauG3WIDyDnAYMUjyllEiF5f8aAVxXGf+FF9Urh3/Pjv9aXrq9fNvN/72ysvL69/Ff/7HxXzsa5h0TdURjQuAg7X4i/it+UxxO
# DATA glke9CaQiks6ObC0F+eLAUuixsvsiS32T/AjxV8+IgyzL/7Zx4fNZUbGPvrjOjUWv9ZtqcRuJcN5z5SaSpYXPMvLPQCs6E1OyYBb
# DATA tSCf7Rj3Qri/FFZ+NgQHeoiehovMB9KnnTzaTbViaDgUSbtrsaiRjaw4+UZ15VZT4Up3hmNAUNUwQBiErj1aKa2bAYeg8FUT1qY4
# DATA lOInvZQJQGpmhGFcg536vY3dvZ33QxvfyUR2onqP+sODQnhdYrtansnSI8TT8DyNGx4DlqBmB4/L9iDZJGp1PAucJ23uPWh/bWtn
# DATA PZmQGWrKhKJVa5Z0xCR3ec/SGdC4C2oc8Ei70kgne/XcM6FeUdaICEli7po0s03KMNnQbNDdxEi9GcXJFfhx+1FU9tpDCa4DCgLQ
# DATA Pm8xbwcfCvYEeYKaaOeG7d8eEF4XXGXO8oxRC+wvNNDsqwDnhhj0/g4hpAysV6RgCASAygxJH4uaeYtswiU7hYViSa/4YSxNmt7b
# DATA 2gL4yveRqHdttyiqQ8bt8nXUxiDDI7TdLaOPuXaxHh4G5ENKev8TtA0w95ZhKOLCFz1pdyTFyqR1xIYdQPCsjaCIvuU4lyE7Mp/7
# DATA eBuHGZ4ZbafvEhss1CjtoQ7d/EwI67TuWJcpyRtYaQ97yaje2lGJZk2XgpKx4cLiWYJ/4cve6AxD6d/rxob1wjIqpFgwZPxD0Q5Q
# DATA GAhKjin1xh0ZzuzJY98uH0LQ8NPlldKdW2eh3zERasrLwte2NvdWNzbrO4DZWd/c27IPEkXI8xhRrkMHyIVfTA/p6fQFX8zH8DFh
# DATA u+kFWEzheBgM2hsuZhb06cdVrMiMJuYJKTlLRsWivIHMyuJaRrxFipVDn45zBMt4wmLAS58m1FChyDgCg1C1PspYilwxPl54IKPK
# DATA CuS2E8SQjEtqqOqaZgynYzjwKESkHqSYA+jZnHfuUfI8ItcyFTAe+tDkvGNkJ8YUj+cFH5wNepiwFwD8YTE/PvMCC+pN61H5+y0/
# DATA ZsoUJzbZg2OdzKGSjcbDqfHEYaOy0HhHKdFIG2RwuI7t8FBTohW9TtY0UynjSKQSTTVgJo42BemAeXYAyCTOGnqqeI0yrgNc5rQ9
# DATA jCsyF2o4MJXASQhCzMvCknd7UihmYSXmTZlS8OVMMWNNaWbI9x4eJ8ovLy0tFYvZ8InZE7T1njhC/LmSfd6/OXITF3OCvBOza9hy
# DATA YNNyNeQwXSEQoEPYmStlUBULM5Ml51LP+mSYhYX79XurayRbUprz3Zd8/uU9AiWGAts7MFAXxVQLSIGHkpJdTmd2zXFaJWdCAgRP
# DATA RyO8LM/oRFpPaSuk9tAGrJ3Z03nDTYsKi+IoMpQ1rXEkxD64K0jXiKp0R5ROE9keeMWkdK/xApR/2AyIgvTAf8d3TNl4MdoLzMl4
# DATA Zma1pV07DDiEjEx1OSKclQKrZRrzCDNaShQc3qzhZcwwDMNTJy0tWg4EHheVKacgrcF0dJCTSlVshzoVk4lyPAXUkZZHFeUeVy96
# DATA QXnJl5PLXEyu+lLihsIfan8dS5g3Ngr5rJk+PRtdA8MqDfjJM0WiqhwYAzY562+vOL3ww/NoWSDpoDOre2oPUMu9ronHpX8t5otU
# DATA 9/L4fL5nl4hINzmoo5jEw8LenykyPsyxsynzdGXWjSNx25jjppH/lmH5eTeS+WjmvH0kbx4wp8ZXh59RXgG6TfgBty9zlTC8w5WW
# DATA cVyYeblw7p05rhYveK241JUi73Ui51Xi6q4RmZeDK7hjzH+/SPH70+SxkPMmkv8W4kEJMZEk9JUD81+4umntyCV+FKw0TXAH37eo
# DATA G68pcQxVmTPkyrOrhbAoqemVXdaoFiSfRa5IpmJtkyG1JLjq7pvSmtZM5ZL7HJwRlk+kPxTmH80SL5CaHmzc21nd29jabO1uPdxZ
# DATA q4dWoK30TuLwoxFB3GimLtZWl6dH7nqZ3H4EaTYIFsoyWuLpBpVrPTqXtM2C/DBB6a/UcnDtlAnA7aTSvz3Y2H2wurf2TtKCCLp1
# DATA bl/wZSRuOmCkyxWtDiHC5l9990HJWHpoo5aAZIEW5D0RXe3Y+iLbRh1oS5tmLKyjZEY3eslMjZ4iCK2gFISrlEdopVvtuk1PM1ad
# DATA lJexzmHgjqWakHEcC1R2nTN3AyRuIyNyfae+Hqbjlua5NLlIOHlmbbe+8+6G2oWvokARB+L8R7NXmZChpOWLTvMY4uDEFAQH4+Hj
# DATA GJXXo+kkriwkJJuGJ3Lpum/jNBPpJH0a1tmZqS9hwncFgpSzSmphxAOZM48BmltCJgcioC2RRFpNA/EwLpp6JDmRbXXGvQbvJ+wp
# DATA C1byO0G2mBuAcwUsJCWVNFwRY5JrTs5Y17UeQPPoS9M8HrivmNY5iyJXH9zduPdw6+EuLcne6s69+l44X45AY+w6UeCSDIRP8C4n
# DATA 1xYKDlRFiCF6VU+InvIE0FYkfoR3vzPlIzMFQViIAtzeYHpyoNQZaLFGPhIwMBpjsEHrbypYEYkIPorGgKMQI6YQIo7hpsQoNtAY
# DATA KbM1eBxhtm0lkmMPuO3cWon/JMoIyxJ4FdoIY1sl7IpGY8zkcwWEwQyZoGwVIatKQO1JZ2SUglU7gHyZgyMN27stlk/cv3FvweJC
# DATA j7gQdIo/xgwdbBnmRGMlXQC8v3SnM8ApoUUTApSzizQl4Gfv8DBC9czGtq79BAIuAawzaGM/K8EmnhBCnAM6bg8Md0XIERoBXKGX
# DATA STgypLO/tfYlsb1nouIZGoj0BmapD6RAat0umIvwGekIHcaP6OFZUyWTooMuZvbQeDWVh3EFT5XPI+sElMOjs/l0rYlQJ0x6lww8
# DATA S7vmzwSkUjqA2VqPs6sRoF8N9gSfVAsCG4ycfCRflcsH59WjCFnvOD7ujQCxdkBwR/Ki1WX8yYRlyXdamLPqPTN0Ad/JkRPrK2k8
# DATA 8GR4hziKNsTztiZDpBaDFHKaCfSmuATS6EIKjqey/bCxp+Jaf1Tyd39K+rSE9jXy0zKeDMeOrVL15ZU57UtuVY6crRHB00FGUzwL
# DATA i8UsXucVRJlhSuouQnbhS3jXEeV5IPdnAePzQxtmJ5nZzMwqQRRMj83oUHpUoD+UHZV6ZeZKtmOS8vgTA2QP8mnIG0XevqZv4guI
# DATA e3oUUsyTjnCG6655RklJJLmWWWH27j3ORX9hoElqJWPb5rSCvJCpjRu9RJQ/gcywBZyuUqZTp2sZkh7mycM1eelJXNITaUqlNAvP
# DATA E1soGWZOfrWG66tx6UrpA73ia1iLYdI5ooQmWY8v76wjX3qJGs5mCeOGhmKwiNVGieF6vNgzhoSbeAlVa4aTZzqyAqbW1QX5MXiI
# DATA yMzH9uj5zPH2aPbJM9OfJJcXiR5lSXUonA7aj9q9fvuAQFbCNH30lVwn09XU1C9MnkgdDDk4Wzw6GA77pn+6upJk1EfRy1UaZ6Mq
# DATA LnhNx38da9Xd1D9lVav9f1LJ/swDkqpu0e3uKUPCKJDlFYlpAmANnHMXj4iToeB3w0Gvg1m5uTxBdh0DoGWi0I9UFT4QLf92mXur
# DATA 2H7+9u3Q8ezfidDAq39PbpiiljbGujQQko1ckXg/Y2dCbQ5aiRcaP2VIVj3Jftj7PqMbNnJHFjvWWKASCiNTvbq6/r7yEeJT1VJg
# DATA q3ByrbPWEeZauEOcAxNeOzIeSW7WH4rrdH599dZ2nawhtto6n55doz1YPZa9TekRBSxnSSaA+mALJ45E0rQbxCB8ak8iQ2CjWIE4
# DATA 7FG8WV5aUogTnWF/OPZUa9qJDZLL6qvqBYNVKHQLTx/lgkmdTzEpaiVn85Uar7gpaEmuJKlKBV2Yp7Sh6puIGwtp+kCDJ1dXgZui
# DATA 0XYCoSiArtibiHKsDgQoKjAhRiPQ+GDmUqnsmyUf/NliwNrQrxrD1IfqahpVPFcuWXimnYXNHKAt2N3YvCfhW1Fzr/R9JimyumsL
# DATA 4xjBctVt98FIxOInmAYRURLXicNa4kogtbqT4/bE0CvA0nONGDMKVEAqiSNQhaGeYfJ4WJYEoTM6SltLWybDQZKoMK5lt3uKUM2p
# DATA ugK4K63JYiSqiF61COKsBiCY4rdQyqu0AtaQKJRNXcrt4EJDBKDjJlIZ7mPk508Tlm1u0XaVQfcm2UtPOKH1m1YF0LZxxCbzSi32
# DATA E220mnsJFVfD4On+gHYzZuflOUncJ6s3l5aX9gdnZtbxk6G4lFJyJRpsg4fVpK48EuR/Ys0dbkhQ3HOCItNXtoTZ+tiVlyoA5BY+
# DATA EUHHGqYmIOLyDEKDbxAoIE+YXSuSO9e7GE06i1huURMIqeiAHGiIRTNFjKIa/RlcV2hY9hJq+GMMJha8qybTAEPjcl00u1U1yiW/
# DATA EiLTlMA7XQrnXEAj34Ado61TyknGINsjv2UiswhqiFuU7vys6GTJ4jetywzmRmqfSG8ok3F5snencLB3Vndb6/Xt+uZ6fXNP8jOp
# DATA zckBGZ2WoZ5y0xtRg2U/2rE/S/0cWMXqrjoHDLELN9zUUaq4XHqpqob2t87HKOQIm7b7jI5FxzlgQwruPRR3TnGBe5M9luQpGYgZ
# DATA Mv3VX7UzeAQsQQQnkKmMlCsxXAMEI28PAmMS8RzWSmPFJ6DXTbwBHiqnqYaRh8hcB5h1qKaZWo0UaKCWcDAM50dY1rA+2a/lLz8b
# DATA jjn1TRuQ2YZco3M3NSQ3nxrwErG95PDf7reoA25ErtGtIllw1HfloejkUVI1qkD7lBBfHd6bVZ2+rz4Fqqiasbm8z3RQLpQ4K/r2
# DATA zxn7gwFqaNeCtf6Ph7hNJZHckLeaHWMuQQfqpGCgF/lBvRxc3JTdkUHKEjcXk4aGKoN31GJHLRe5T62DitUgz69uexIliNDbHZ8/
# DATA mcl3NeAh15owxiUW3avFTk4/34+vJ47COeuh9FV4fcCQ8WSFfHLnoHgz3ZqH+ou5DI879Qdb4u6OWoW1rc23N3Ye1B3wDXtzVx3X
# DATA cdrv9hltv+EoQQ/9cpDPOxyzVSaQMprWVlbyq7RtcprLTAgKt0fqZRS/pSFcPuXcmUdRSh/JuJ6zKaNzmjUU0wFAjfKS5RQzE6s4
# DATA 05fwZ07ZGt5YWZU11hJaADTSuU+FQi4et9WDYmpcLdfoIaVk3yF7LcgSSNgmhRs/g0EoKeQ2vbMOeo8sYk4e5PqoYq/TNKxU44ws
# DATA GVzJBK4gsBSFoIlabnkOSH0xq/c9uKoQtEMM1M/NZ+GteveyyULmmYoZ+9uVL+ZoxZpHpx4XIDhFNPE0YZSaDuiinYjdoMuMjV7A
# DATA gUQJg5c3kipzlDxSzjeBVgfHRp3uc+WPxJip2JofGjczJMOEzc2GzIWZdGFyzVACTfXKIgK6xG5Op1N59BucsppI+6UYY1W+bUMj
# DATA pYFxaIk4pzRue025crki0RdEADN9/pOietFuhxVNJp689HqX1RhxAD6EHQV5ZZUxlRZaXjddQylblBl1nLaWJebUWqG83Y5jdhyV
# DATA BMFggXjh6YjvMNPiO+pzEE+wI40DsVgGnU1bqZMz/JMTMbUJj5xcfhnFeRfWdc2W2bbY5moFd+TbFTL+OzBdmUW3Ifo7dENByHFs
# DATA 8EjTiXXE8C/WPMAzigiD+Ku49/Mo+Mvgzu3bN+/M441e33zXkIW0Uyp4cvRAEd0vjMO/9YSB1wpGaEC5eWO/kv29+APKaJKlr4NY
# DATA ksqDBGKSctisWQ6b5jI5Dpr24UUZ04iuZT6wtYe7e63dh3d313Y2tjFEaKf+cLfOYwN1CFUtGMf+QFn0XiwchuyeTgiMGc/OcUmW
# DATA zG4XL2qpWD5Kpnf+T2umyaFapGX056Lz2lWybOwMMaGBNM0LTOZEW7sTLRWGid4NGC/KGC66kOhQO/b2dX3+KPj1xaKo890yUwLk
# DATA UuYmicjBnWnIjjQb3IGmA0Fp7wQrDConksaMkYg78mZ9jTfyXz/c2HFvy2l9SDgfwNJ084B12Pr+ubMW0mvenIWZAp+W/K4/FVet
# DATA quozXrw8ibTsG2MKeog3h8vZWUZOtdRFhWTOOTZOwnlMTpYQOKLxpMW8tsWMNU5GJhO7KL1AskHXmpM+8QnzgMtszpIvJ4+EBhNQ
# DATA 08jFozwEXGcyOR8PaSLepdqQ6D3Y8Mmk1Z73eLOsb723KTb+er119/7W2k/q62K2xEkHwjrWCv7zYDrGLwsunftye+rf07J7plBM
# DATA ki50Wj15uLvveYpmpvCjY1AX5oOgmJ4hbi5PQJTGzN1ME1QsuUNR3TRSzPEBe5mcgWm1+zJH0s2WB4X203yJpvLY8/6MbHjZuzvH
# DATA Jn4ZVq3LW6nmtodlWbVeUlbCV+EspoyncSRWUXzon76Jlz4jnEhGw8QRxGfTr8N+H9oLyKGgsvCf3ubjs2hdnS3x6q2Dl7ROXo0t
# DATA 0Tr+r9z2lTx6r18vPA1dU5hEyp51OiHLTAo1+soFzhmzLGr5s1Ve3vZ2CbtCpqXspefx8jpFzko8aTpFzme/mt8u9iLmmtxGi2RW
# DATA vQz1ezKkImlAsOxl9m9ZBjiuXBnWsJ78r6cZC+ea8BQTowEn/wLGs8uZkWSmQG7FybicmXfvKuxDl83J971tKcO29F0nLExldGa+
# DATA QqKr6djWMDqCvo79S0HxpFKp+D0cfiG9Q1wtZcFtrqjjDw23c5/tIHkjQTAIpSMll9gaOaUMn5zWQglsEs5GLskJV8K4FD5MioWr
# DATA ujPmmnoOibQMGTaMTI6oY2DE9jxU2oPO8XA824lzfWOnvgYIFuhDUn+wvfe+jqPsSXiAOWwZllVGSXUSUsIYjBD5ESCuaICyYjsv
# DATA 0Ge0lYDTroqRUaSjfHDzhcLsbP3UqJRI0ghvl7HK/sBhuy817dUuR+rWlzbQrQerGwlVJdqt8yO4kia915/QPakPsdM1UUGF8aTl
# DATA xZNXEa0ackVlnC9a1IwlYuDR5C2M/MyxO/34qnuRuXISfUGs3F8J6mjVf7qxu7cbJrYiqW6Y1aSrXoj9WXqX3qE1/CSVmx6/qzqm
# DATA ZhwxTwza485x71HEN1uuC91ug+GgE70pE9Ab6rRXg+kAgRMi3WIPssa0BxyHEYExhRLHHIxh22snX24vTSWjOjani7VRdS4dTYIt
# DATA ZIMkOE+A7ZnQEZ5qLous5SJV4DkhJ21RXuGnljOYLp899BLBcbWGHxgzoV/uHIsXC/heMQMD3ErlJorw0aH19x5Ffe14MhlVFzXQ
# DATA e/XmEoW6+QrDMsttUBlrmGCfDilpoS6Z/bYAaZ7a8btGdGIVPKsEzcdl8MscRRScKcRUVJ9Ug4blDqKaKjqK93CEuECi/GG4vPJ6
# DATA ZUn833L1KTw9wxAZV1NPTAfeeOqARZC4VR4P+2nuJW5Nw6MjCmx+GnbHPUxHTEbKstQBDUdSf/g0PGk/KYPpHQotL52QDvJJmccb
# DATA 3gzP3AYo5rRzHHU+wBomYu5gqOHag3WULgXVIU/F/x5GgKRwjdddTwbMwiIaW4WsvEh1XitWBPcZFMa1v5Th5pgSdVwZfvDWUnW5
# DATA WKx0EJihUHRKiJ8YOUFUKCQa6PptZPIc2KwfCN4GXEo8WF6hYNTxpDWKxr0heNKFK0txeHaWdrjCjDfkYolr3ExgD7ja0UfbQv1U
# DATA BrknnIhoWZLrTNHxumt8HLh948cyWIIhGFTqbEttQvZn642n6g3RizP1FnQJsufAYml/Qx4CV6C75soWacpaayPpuCopZl8u7qyY
# DATA GKBhYJeRZxYToIfVlcrycuWHQkQZ9QZRmIMpKIMnzM69rfX63Yf3oPCJmL4e3NsmnVFtKcRZlPwgfGOp+gYyvFu3blbF/4yPi9Pu
# DATA CKlYRsT5+I2eJvQJq/oi06rjoZIpyxAGW12E/+pnNDPVRdYDW97rNGeyCzRTuiZJFmY9+OxsFk8mYaoshSlxWXDV+y/H/c7hXrZ/
# DATA cRXBVApJSnFM2G4UQHJdPMMrWpAV9OHsBWB6Uj0CTY1apjI0Ve+fQ4Pana1RkJczW7fpVUTltomduZFNhCxqQ8ox2jMmL6/yST+O
# DATA EVRIJvWtrI6PprBbt/GXgoS+A4VBqyVWr9UqGm9WBH232vxKIVQR7kCzhLpca4RKn17WMNAE0oLu/SFB+Uz40sOaDG1/mY4jxZfL
# DATA 03Gff+HbQBmAyfEEA7FKnd3KnxKvKoJeGD4Cb5JlDlpF5jWNozLwHf2NaiLZyMU8kEehD7OhmTEz5TKQrygNUbi1bVSBSQcYQ7o0
# DATA nextB6IQJXpEDkxNuGtNkT0fesRyrL0TOw0pVfUE62SrCg2ODCgm2IN/gCCGatdj8UuMJn0si3+gdKwRp+BbxQZT8FKKizKBXmvd
# DATA 6ckoLngBxrFe0nDgRwPPHL+bfDIaxIK8Wu240+sxxDTL8v2sHkahpfhFozsWJiWbWAF0BdPPyTEXg6evwMtJ3ktNI1YtcHpQsrVd
# DATA 4IuJmiu3P0W1FupVx4Knp14Cxc+aYr4v4GdloaOXUp0mPYOasRa4rTOoQwKAqd5eZsFdnpHRngve7M6SoW+j+WblyCV6ZbCtjA4Z
# DATA eMFuX+Dh5RvWHNIEMPF7oOecBf5mEGZmPyR3d0cvddfztWpsGlTCul0xfJmVKsuYSNB4hHhf9dA/C+lQJNSNE86BoRbPHq48FI3M
# DATA yazwTywsOm12827E7Gb1AVx1RF8wXWQ3PT8jmtUV68RPgOgrZ+iUbhXT9wm5V1Jqe4hps/wovYdt8ewSe0cfz0ngpIRdIjkKNZ3S
# DATA RNFYamY3aIgAaXdLg9yl3/xVrJYWv9yhalSjtHWSNZuWcomwlU1yGnNLiLqiYy00G7Va2KVWC/Zhq8U9gjWOe0eDKQIrFuBju1/Z
# DATA 3bi3V995UAr093cebpuJ5uk5/SlQBaWAU7Fcb4mb2KnWtST9X0j2Xri08yeJC7unsaDVOrSiXTlBwzJ8FI3G0WHvSYb/pw3Va6Xp
# DATA VaCGuRJjeronrsIxZkR30Z7TpRrRo/N/Ds7/dPGL88/P/3D+jfjvl8HFRxcfiwfPxNfnF//3+ecBPL/4WBQ7//b8s/Ovzr+++M3F
# DATA P4qi8Ptvg/Ov4Jdn+PLX588rwfn/L8o8E9U9v/gY3n52/hnUf/GRVS6A/4eGn59/ev5MlPzm4lfQ+N+LIl+efx2sbm+UxdNvRV3Q
# DATA 0rM3oV+fXPwTVCSefyo+/0Z8eyZ64HT4GXZY1H/+xfkf8WWsoOLeskmHu7q2Vt/dbb29unGfJ+TfRF3fik59Lv5+BbXlGjc3+id8
# DATA +UtRnhoNzOoufo0z8s7e3vZuWc9LKRDFv8VRfCKq/IY//1o8p9c+Eg3+xj97z2D2AnOinOm4+JUcwJ/E149EKViifxETR8Wgs1+p
# DATA 7ltzdvGrxJyhy3rrbTFXrQcQ23MXDEYb767u1XHq/mfK4uEARb//AF/lsn8DMyAeAuU9g/GSlQUHB53AR8Ygl+4sLYmu/3+yWjnj
# DATA +P2Z6LgYcaLD0iCpO44ddUj02/PfXfxKrC3R4DxkGWD3cNJwMv/Ivfodjvdz8XH5TvCT3t3Ujun4AE+/0rbO78SHL6Cfn4hyz0v4
# DATA Kzb/NRDmc/n9GU8jEmA1AP12XF1kn8PoSftk1EdvwETnkEK5axaz+H+oBdErQaq/B+Kxe4aNfS5m8xNs+CNRGOsS68avfs3L9fXF
# DATA r4HS3QqQRv+EI/n1+Reimi9xJtrTydDs5Vk6U5ZsEF2oNIcW8sP5v4qaYZmeCS7xPME4PDuFF/MLpEDYib/M2Nbi438Pzv8g1uQX
# DATA SNtf40p8JUp9I8jn+fnv8Rdq+zfAzkRdX+HySioTXO1XokrRBfhV/CaI8uMKHBp/8f2/P79/k76QgU5fbhtL4t+dW7fwr/jn/F1Z
# DATA ubV8Rz7j568vr9z5i2Dpu5iAKajeRJP/h67/tWvX1qLxhEKxo4CdlEAK57yy2vhNusXocbAjLXHS0YvCJDBou3eC91mpDZbfqSLS
# DATA 5clncH+Sn4fxAsYRgTWn3zsI+DFcLmSRsapMi5Tqyan6KFjoCO4XC1QhS8eyQrpLlyzDVosexqUAbzSs5BZXgUEc9wvX4WJQQpBT
# DATA Dss9bPf6cG9jJl0LhSTyOfBIwet+gfxQ8sLturgIAOcVPPf5xd8ztwVWzbyS5TEQFvDg+BYKipORRDZLhnuOzFY08TFUJUp9hUf7
# DATA s9BFpjcEbjH4QiPkkYAfIowFEjlCarQaDElc1tqjCYxmOJ3AQ7I4KlTr24bbC+KIk12gM+xmZZFzZsiDpF0hjCvpzKgpsDVq98aF
# DATA 42E8YTgP/VOJkgeZSxfXQuUPSN5X8k22t4i3wTet94gihPCyalRZZHWNqNhAzMf7nPWqHWMPTmwdxEsUJ/OIoibxe7g/2B/vL4Uz
# DATA VbR0YUHBB4iEj2gpXwqRIkBhDoRHEKdZfBSyB94Xnl/8AxADCJif4iuCSpJ5pkcGkgSMKgkBsLy0ciu4jn9mdvjfk7THogFTsOo8
# DATA iCCy82JsZSl2oiT33BQthczxSxAugwe9uyrV307U7qInVBAPXXYESx/93RTcY8A5HFxopzFj1koUY7B9AA1VFAG0iNDFGuMn8OIU
# DATA T0k1cXAKCv+iWmjrKQWzMB8In9xe+iEa4wZD8HOAT+ibEQ3QpPLGnVvoYIOMQjUrR7UlatndvS+jTeKgixmrENO0FyMmAfgKTRg3
# DATA /02xTUBNJBZy8PNoPJRZDSi4hMvTjlUJqw7C7jCKCd/A3DahdIScORLYO+Kb3nz2WHIGG5uoPAlO6SUjkBg/A7YIVOTI5r+HvQC0
# DATA RTe6Z9mum1dRv+IDMA+4yz1nRcHiQnrO0BZi/SaDdm17z1Wu1Yuv0xxrZd+B4R4EEj7dM+Gq+ymcUsaMCm4gnjzDK9CzxN0kB6f8
# DATA TnrBCaVIloj7RAIgPoBB0JIf+DsdkT+XBq5XA1gnCcMQBwfDyXGws7uKG7a+tr67+qY4oDhFzgm4COKvJ8PutN9DzByDXY2mB/1e
# DATA BxCNE0QgfhJszKIHH79hZuapaSRfFz9Jehq1IdUJmX/juCrrlPxSOxwbnXul5jSSuSv/LaGL0OcGHAdiGb4Vss/HKOx8LHVjqLDz
# DATA CT0Xn0g/TDDXeidK7xa0rHfJS8CZq0o3AkGmkEhlJOqqYDFY5NZk2IpFwUE3LmCDMjlYjZKDLTch9aQkjMpg+LggaaMynXSKFfgm
# DATA enEyKszgXSjvfRWg3u1LmgW+4vsEP7ir/xPc1r8h9eazi39ElcRHF7+1syB5zkAVRDI6nS1wGZavNNlLH6uXE+N4OSMwZUkMESeo
# DATA YzGEOmKFh2QUzo3gdP4/aOpQZPo9dip2ZC/kKEr2MoQspeoRE/yRoOGvUSvyZZjouscn2OcFbLyQ8AOGOQO6LoSQI6tzLE6cyig6
# DATA IftR7xEk7ISvLKD0uzoflen+gbUY1hPKQylbXYSfLdiTufIUn/8vVHZ9jofr55agBwKgLc+aIqE7p+L1P+LlRs0qyomGPCsGKBHS
# DATA R5Z8Rr1ORg17zCY2PiAIkGKCfi72PE4ScQZnzO3J8KTX4bbciVP1WLYQNn/kb1YMzQ07zVolA7EQ64pTouZGMpCNs1jZpJceSpoY
# DATA 9sgZpxuFZhdGnyRZXiZDkolPCVUQkiLxBV3sE9B3jmCP1zD6jlznEYb4sPekFlYm/bgcelYT4ZKHceWwC5y/YDYSPj4I0bAkWHrU
# DATA PnGzZsEzNlwmBmaUOOxP42MnDBDai08HnYIsI8YwGBaMaO5hrHzyadExyJ32JUQq9o0hIHdDiTF1rZhHK9i8uHASTY6H3RLjIDgI
# DATA fGaKcipgRZfJTOTGjRCeJC+Fd26+ccvzM/Cz4L8FS8Ol11/P4rHrm7tmn6uCF4ij/A/K2GFc/YCbbmxuKMYRoI1A2kqQLdwRdyoH
# DATA c8xUJVUIaYVdDTWkmMRQM18l1gEn/eCoEDa6g7i5Pwhv4DAN7wy5XlEfM1JDEgzltireUT560fikN6HQ+8JT+KXV6Q+n3cN+G0z6
# DATA ox5ZvUMEDKB1Iy8EVYgT/tC7R50hvcZvqaVLeVWmgKB+UsIJtxPRCSc58nQOxEAjEYU5GqNaJQ8ZLYHkp0obybYfoTuKmFFgcfxl
# DATA zF9U/g6qpIIJJ2bllzj/ZyAOZbglKhLHxcU/kAD/NRp68fz5HRtAvuELnaDBslKfPSNLJhQJHWQ4E+5PjpXheXKLFP+CJP35+Rei
# DATA MbBYfaQNcJ/ggWdsBqt9ZneXCSGy2C7VBiG6lZ8Ne4PCYfj0gzOwnz8CL31yRSlZ0y+ze1QQVhFz7zKvAWdzQ2pDCioFku3kEAR9
# DATA SjibisEKZjs/YitGAKiRGHQcGtCQlRv75eaNH+snFRM8svl0pQSJQ7G22eJLmsqWNo3m6ceCM6B/c8gBEtTb8Ab+vRFiLARSvRyI
# DATA mSYWV7sfa3RQ+8zVlSeKy4+Lj9rjxX7vQKcCXhSPFy25MK2QISvKPEGKi1LTN+RK3cAAkPCGeO1GmIwDscPIjLxDrrbDGJuoOSZ1
# DATA dH7tieMjFtyoIUu5AVyMqBurLebtbnlm4iTDicm8a5hBMtItnvYI3ObGMtWP2AhYu07R5yFhnUel3TmJyg0i3mZDIZ4CVBBXOJvX
# DATA OEQruA66PPwR7okfI7P7o8XsuE8kFlBnk/HlWqONJTI12nNsJsUD0fr8GV5Rnweraw/qSt0bo9FbHGajqCMuiGIRSWfyJOrsYlKb
# DATA v5sOwb8xAJ1JF30dOxPSzcTHUb8vfyf9iRAE2yM6xXAgOkZyfx9oaF/8C43IyWv08Jr57DV49tpr3EODPig5FXeY/4bFRUkLN0IZ
# DATA RGgnSA0bDwe9iZA11o1IiJ3INqTt3d8178j7g9VDIcvUOOKrPAQRMWIPu4DDpbm1/cF7bTgtvGWRN1md4ZAc0Z89CCQQQlJ8PBTl
# DATA Hj5oxx/UloR0tz9Qs1+7JhgdzemN8No+KIn4oLpz69YlJgg3T67pkRNjTIrYV2LS2n0YU2MPahJvbQ3W2kIO77bHtetl8X/B0s3S
# DATA 8u3q0lIV+JQ19B1BWOLc/HnUXY/67dPdqFO7eQdKbYNSPobLQG0izlisf4Msm02a3ah797SGnY/VxDpz4QmNuVRUTK6AGIklQZEs
# DATA I1TpmXKGAjrA+AvANyH13uRYxWqOpSRr+Ko2jFAOUystvrLe0PJlpVMdA1ko05sVJhIzVKCKGoOPOGgz18UoGQVyQ1njkj9KmZaD
# DATA J2sys3KypMX5p2OcFPctUFqN/KEljjuqmnDDjdnVdrUr0rrcrlj6rnYFNV5tO5Ib+mT6wCbclUenltO0VNXNbsZ0VZ+vTYOEjKaN
# DATA G2i7IoVBUTPfQtsVU4T2V+yEp5KgaY6ERU2z/ksPg8i7aiXmhXlTh7b4SCehz1GYwSQNaGtyca4QrGLyrphCMrzvbEn01eAnUTRC
# DATA S6XELwrkUYw3bsjpPej0p4B2HoBnxsFwEsZBH9AI+EISV5JZ0hvhpC+DSHlbVo3JtHYzBXvyoExjeEULBUXe8lZZ2JdmGTtdJh0E
# DATA PE0WCKVf2USCrpGEedKPPfncWX4BPyUCbDNGgrKL9Sv02Yfx5JVZyLzw7cU/0PXx4r+TYwZeMNE4DxdMcTI7KYDIDV002bA60yy+
# DATA af4EPWnmcCOf4d3td6+GozvhaW0pRi7lfQ3W958RYAkmcGUVGYlk4uVHPbiuGPxApxyUCCRR0B8eVRyX/fD8Xw3HFjGjVXGBMvwa
# DATA EZJP5x6NqO965KzbDU2XGHZYRBebjc2NknaoEP/P5naI2IWB1IxUaulOl8v/J7ooTg8ft46m7XH3JXoBZvv/La/cvrNi+/8tL91c
# DATA Xvre/+878v/bi8C23R73+gD4EIOhBfKGMg7Rw7ffE1IsZtPl46hE+vfegJLOgiViTAmmT7NcAA87g0l/Dn+/+Hg66akXKF5mPg9A
# DATA /g7YRVLBhQ47FOE1w2+O3P783nHi8Hcc5W7dzva6iAaPak+vXx/GMkmAOF/vr7VW76PL/Jqh8J3pZ7dDHo3GOQY+Yp+RVfPiI7ht
# DATA 6wiI59LmhuEY4r+/hYfiFbGsbwYefnoohK7HgFN1/in4yGA8wScXvwln+vCJOWsZx6HMByIhCI97aKY0JnkbbTcWupaN9MvWa3iz
# DATA 8rgtGLSc7Nu3lvIAatKbE1BWD6BHxfSEAp5GlpcSMPtG5/eoVP3JyEar05V90Ov3XSBJ3UqWOc02pNEtUyuYpB0nVTudpI9s/TSY
# DATA YtH6+jHq0IEcvlYBQoJMtIX7BSx54pjxWvLAqEbmb7N+HHE+a99/LWPfODoYDictyU4LYtpKrCLrTMT1SGwyIdEM+0KSqbHKJaH6
# DATA LcNcyxpAApoOepNaqoIm8SLiw2pVlqY8avdKaO8ryw8jJwVy+7ncK07a4w9Qs04vEeoLgWWErHncQ7Q8Md1ldPD62fBAbHAxaMDm
# DATA Gw0fi5f6wziG6ev3PoikolLcxSbj9iDuwbGHF0tX8yhm8cXVjswJYOlKaSoyXCjchM7pLbohZk3qEKE/SlVoKsQCyFPR7VFW1slx
# DATA Hf0oajK9B81gkdJa7Q9S9YZ2jabmEEDleFZEJdcCzpkrzsL2QT8ytIzbw3hSW5zG48WD3mBxfBKUD4NEN6xm0lR0iAhVnsIFyFDT
# DATA GdpK9Ig3NlRIKdQF2cNVX6rEEqWoyyHtpQrmObfWiXoJaSNQaJKtSn8ePsooyLfKxDmDFaBQHnXlAVkKKGhZdI3DECIxfeIezt8e
# DATA H/c6xzWSmSr4pSSlMjNxmHidkAUx+xRJQ3yUYm3iR/kJQBjtM51wgg8fi0LYQiEUX2wzg3iQOMG5QvuoZ4fmGs018jmJlNNM+uPh
# DATA DxV05YvhOKBEJNMY8orTlFsWiox2uZ8ZNXrq8/G2f/eJVOz49C1HI3/GPlKCp70ppWcjHO9PFAt8/g3PobSFqOnlB2UxR1YRQZRu
# DATA IfHIXglZGWtIVKkZw+IIR4drS0fpT3FYJFqqh+C46QYW01wox4/kQLq9uD0+aQH/BQ8KJlUkOvsMLPoOQYasFpsxQE2b5+jzYpcy
# DATA 618VPEbWL1PJgWwBOjdQYUghuBKsBiDHCQ4mUVLHgLqKfrygqugHPXbAN1hG14W87Qz7fQZYKpfxNMa+EW8vlwX7IZqrIS6kZnTi
# DATA NzxhIK3ISFDPaW2105mO2x20XSyDtow2js5GLjlVs+hNnSF3mvECLITxxqz9k5BtDI0mdlbc+07EfD0+jgYMNs/BY+1e39Bc+jtj
# DATA 9940qWZwiZy7OI3k9bZFt3D2Qv6F2LzPIfz1U5u2zz9/MyD/JPRp/lJaYFNFGOQH/IN8+C1UAWZScIpGD0gLjFbtjELRni/zSGLs
# DATA MNwDgFCnbDovHaMtJxKZ912mpRDuEOKCXVM92qkDzPV6fScX+BdXQ0OKK/y1sVxtKiwq+ay63AS1K6Dsh03SI5q/myxT1sosk4LF
# DATA uJqlpmM2nyX6aqe3Z+e/Qwd3oKKkZfwrpeUvJtz4wkWx7I6ADj4Elf6w80HiXgaO8AhhMuAbpPi21Vrbqa/uBR/Sl53193bk582t
# DATA t7fu3996z5JUCL1fiI3j6QigcCQ+yeEYbi+OYyti5TvgJxubeyb2STYWShIPRaYB0G+0Nu5tukrbn0SnB0MhHm3InhaK2ZAsc/XK
# DATA j9BizAobvmdfS2GZjDkDBZi4bYqHBfhPiZ8AsEqr/tMMzXRCFtSAZC9uYUhMZgZYTKiEGBRwxP8wnPXNdP73LaIhXPwDRtwQr/Rr
# DATA o0Lb7GFuJ8PwMZ89IwPsxm9yMFtVRgfTdoHBvP+EarVfperQPAOUEkX452ZjoEQ15fYRuCK+JBNApv5/een2nVs3Xf3/60vfx/9/
# DATA J/9efUVdvCED+eh0cjwc3Fy4du3afU7dDpmAiEqkk1oF9gmneqc07pjhAOHgIK/BeDg9OkaJUEnNuQ0Dx+0YDALq60m7Q5YCAH5B
# DATA PQYcOfQj6H0BmWUHYoLjyTuCNfavAl5AiJDqM7haTajZdOMD8AzL2oCNTcd90VZlTL2TbXJnS/AzHBwLqgPEe4xWtMMDYhN7f2HM
# DATA 8wXKTo4GdbbXt9DVX0hyRo6EhbX7G3BjwjXvwwKTykVKGOHC2tbmnhDE6juAtbW3s3Ufi9tiCChTx8N+uLBb33l3Y61u38EYpA4p
# DATA RqkRFx5ubuy1dra29rRs43MWW9h+uAMpPCARaUqd5UfLouW91Xv1XQyRQi0GZ3fpDh8PUJGDkVKUZJJhaCnrRcipPU/5BXDm6A3E
# DATA UjJobe9Q/tIR5DwQLxQXHqz+tHV/617r7vt72KQRNq/UtpRCajw8EnMdc3acsVxpQVCAoYho9qUgeqTDY8Su2Ibwyfg4OAATm9hH
# DATA Yh5GVCYucXYPKZdKMTrGa3L7ccBkKCPBYY/R/Y0orgZKzVYPMj7iA1ZG0ZXbTrBh5VFFDxfYPgoxm1d8kdUmRjpB1s6wC4doT2Yx
# DATA l52Q+gddKE1hY9R3FMlAaF5oUQvOiU7qwzm0aNUJRx6umFE3qbl5iHSTzO5zb6e+u2uL3c6AKUeKXFdUKchxOTk3B0NQi2EEKPyn
# DATA 4Ll/y2qsGdZWA5Z8APl8czh5G8jBiSYzKnga4iyhfw5l1sC/qE6NuquA8S16BDdqpCRAUkeQdIZyiQ0oebFPHvWGqIuTDTS49qZC
# DATA L4CXBLMQWyrCNDTAgwShxlIbAsCB5NUkCBbMh9oXCjbeYyFfxgqpgNa0AgbkJwVsCSJoraeyU8Xk6BvGKJoNWRBcn07aTwpLJVyK
# DATA sjsWPTPNYqLKCnEW6kuNZ9R+rSZqpRdxG+MaglMahCjsP1laKu8/WT7cf/L6ofjww8Mmp0zDskVxB11Zai7Yg+CFgX4XPE9vBI2n
# DATA YVuvI9YEMPrERKig+I5/z5rFRnnlVtVtg7MQrlKWeVHRgi9zH+Y05Hd8Pq1Ui8vdyL+r6jCcJC+wHeOxXEJT60/16t0vszeow/OM
# DATA jWrfMNSdwvSwkt5UxfQ++nc6kq147lCxs5+U9mLUjzjaSk/Y6Bhh0tn7k4uEPMFwylOCbtURm/UmuWrCyg3ZBsA3PJPF8yErhiaa
# DATA i93MsagjkNsPDmmu0tqUrv8eYLUSUxecW7+Nt3X5mOatgfNWbXrTNOopQHeUAm/3eHpSUJU2sMJmZt2CORRm8ohiMtUoOmeoTtSC
# DATA parX5cNdK84E1keTIlhelM9ctxeP+u3ToI0RdW3IzRBcWwoYbOBaxfU/yCZZwyswkcpWiKoGKevDI0Gg8iDZgLmCvE1I1jeCZfnD
# DATA mph64Dv9aFCgefVl8EDS3Z1gRg2rLCeuY/LHCzY24aZ1isYd4m/LS0ued4gAqHPXscyi2Yrbpdg4Fo0tox9T+g3JLKt+FupUGvXb
# DATA oxhSnOBqiZcsqiwY7RwKcoiPqSGShx4DEXp7gsdXMTECiAg/gY7sSOoy2pWPzOM+eaScCXbe6QtSsOQhw8lSKosFsRDjlwgf/eER
# DATA M332dOAzF3KmQqoiT0ZOyVUw5UUyJ2Te6MqNATreKwQvUZ2uJUcytvnSr7EMaKabUeH3h12/evW9na3N++9LnaqlbK3/dO1+prI1
# DATA gVCgRDHgk8ksmVWXsaryEJQLnYdbghV95i6VXrwKwRXJsEv12EowSn6/+hcKHvcADsgyVgLdNFQEMSOdPqQwPuy6flAGl9Kq1cMu
# DATA x/Un6bKF1F2gCxDfrSDOY6KDQPlyRNJOIWyAjEB59SbjQzzBw9feL792Un6tu/faO9XXHlRf2/2bkFz7KkcndMajGNFErwS6h0DK
# DATA LPhGTZGXRKgiasPp5LD8BkSjwsjjWshuHlIG4T5Jz6PksBiNiSktMvanTTS5qHJ1e7u+ue6SYqqDlZpu0KhST6uuA3zK/IcMQU22
# DATA IYkrrpTTkEdLeXbQj8W8NYsbOIRJAuIeXJmyKcxgYpR3TqJbJViZ3BapU4yTk8oJmQF+tzPFGwR+svgs86vsqTHFWZohqTQxRofu
# DATA btric0Wc3bqHg0bl4ebqu2IaVu/er4epLFj2Jbk0s0xfO+vmLpB0r79vIqZ9PkfDsYQVwaAne5VPBA9gCCT0GwTMDCrn8Rt0nFAq
# DATA u62N3Z36vYKsRGJtpEax5JhFfQOYDjptumiY9TPUh6XYso1y1Ps4ij6QAk3i/bL9vjNEUE/VZD1w2yjYpT00mmrAyR4xBQPjiwrD
# DATA QY7brAn6I/4LxuQJOr0VDpBnN1bowqJKNKpQbCykti4XAQGYCoHrN9fD4GHprD6jN9GgyzcZmGTINlsYh2X4B4waEA2C5nUGpQ9+
# DATA Un8ffwrJ81zP80F01BsMUiq6W7+3sZm7KkAvoD7BkY+AHrp2UL7hj+RpIeSCH+lf5TOHXnmiwsZOfX11ba++Hhh9aOIZLEo0uF7A
# DATA diqy+kJcfwSPijWmlbXn+VcJCJW8x1oGLbq9NiiPibx+z6sAUNcnM/dyLXgqW6TMnSXFGTkvq/zqSbXHYg5lITR4qnwkL/2gVYam
# DATA MHei/LFy1B8eFMLrUqnRqN65BfoiLKRKeVuOhYSSePvmioYOoyZB/OTGM7QJCOJiqxLwnQSrM8ys+A5deQwxHo91D78z5hvcSMis
# DATA gVU0jNebxeKVX5RhLvQZZEjjvShrSrwHki9h8qWOpxc5otJOndTzKuMYYnyOSW8wjRY8gS5GCut0/p+TfZq3I0JLRdqsAHOGe5Hg
# DATA dn+7H18vvFWNnoBxbD++UXyrwJAwraaBHtO8XhQFa1C4cr34AztrNRhrKg+KVb/OR3NW4j4fAp08FqT+IfKVD1nK+1AHRn4IGEtv
# DATA fRCdfghHJijJIGb5w7jdn3zYjRE6AAbTWG5iyxspsyy3GBVeaRoeb5iie//afhgWva+KjoNCBGsoBn9ZC25VUwOUHJ5K77h7KiFI
# DATA JjYMVYMoIkPQZhSeUv8R/Qk/wU/M3T18gdgAHkBO188QM7ImnpYk0gvd6I29SOcN/FE+9dRWyTiEmjIGhY9xqcIvvNU7KRba08mx
# DATA 2OI/R1WiIJRGtdYk4joQBBCNPxQL2esUgcb2dwGTZhzuLxt1m4eq20LIbYjKGtcEz3pr/8AiTvF8t762U9/7cHt1d/e9rZ31DzHd
# DATA y4d8bLbeEufmh6LAen1zb2P1/oer2xv0bPXh3jtbOxt/swppkYpupdyYGkyx8bf74/1B80YYzjeA2UJFYz/e321ef0u0OkuU+fAH
# DATA xbCUKhxkdWP/IDr9K2OQJgRU2veD0KaBrPoLAMsjXm/yX1HHjUq5eb26uAhTFy/+uNq8UaVPzRs/Tszhj7N7/2T5YL/RWCq/1bze
# DATA CMqL4r8/Lv9f0lqUeE9CenWO2+N2BwKsEZhHfRP7CUuCgtR8CPERkxDkNsGk9Nu4mW6uBOTjaP3wSi1YXnk9S2RVAt06XxcDztkZ
# DATA U9R3O54Qknsl2DuOlMLWUt2RphI8RwirHd0qKgDDx/KgraWWNz9xFZYfKXPvhHTD8AZAjsjOwiP5+Ywvt31A7J20lCNKi/1UCtoC
# DATA v0NG8OBkOgHv4+A+voIY9CXo50Cwowl2GLwnyElAfG1PCHg+mLSPDNP7aBj3+Kqsoz1J5NmpP9hcXYOUUzv17a3djb2tnfcpL/Bk
# DATA ctIeLCrUm7Lqrms/S8VGE3S+6HwH2lTdyWcU36nfr6/u1lW0pzTrsdNKQSueQpmISZx0lSMhlUwPwKV2EVtcfKobPluUnkGLtBZv
# DATA KbeOFrpu1J66XvpnhhM84ZTFtafhagfOIVCLgAMHBKQAPuqjQZebv4ESbQkyt4t6y2tsIKyCQF7uwLPQE6MbPhRUWF494rzYegnM
# DATA e0R4Rm8ajp/svVNQTh5GygwQwsZRPBoO4ihxA+XnJBOt3L7DniRwxVRrDcefKA5WcV3iUguIM2+jmUDFJlEZx7DKrQuol5ehGLEV
# DATA cIxYDaN6tI9QqaUpueC0Kkrw0c++Ig6ZP9rvCp4u/wN8sn3kRGuO7Ta74/Yh2Fp6MdaHqTUThUbiRJepqa2Slxk453WAsYAXuhX2
# DATA xc+YIcmSJN5UU1bCFIj8s2JNijhy8W/xLTE9Zs0zBvFufWdXSA1K+TbGe/dkKlh34aQ9AkRVrk+CnkMmL42SNDgtwEtAp8u3Xr/1
# DATA xs07t14nSwY8FScRVnmZvvDcUZduBIWlUlHsg8KtoIy7g+rVYbOWO00102Ljv3Z5fbpREz5OARRmjR8HCON2Buzc29YuRlxpiaqb
# DATA axp29yARIVMVy//G7rUQ+f1Ek3/zmm3xhGMdPK3sSTEXpYJSGvn5w4cb6/wqihf4MefO+uuH9d299H7F4tHIdENpyYj5E3HqyG+c
# DATA 5FZBAVdneL+xA4THCWzBwN0W320TmRhzlu4pv0L84ebu6tv11vbq3juh1aN8dk1ZOGHVTHr16TlTlKQny4BmpWeoPXbRsHT5dEAs
# DATA g0hUVSVUU7mWTKMh9bmx1HSUfhQsimY5Mz24eqNIfH11e7tFVykUq30YX+DpXAtoJAyfZeqTlKLGGpsRQgF6CFvl+re61RpcIQ4B
# DATA 4fPpnVtnUtPAGobkkKQiAGFyKQ+QASDLbIRKg9715komET3Y2N3d2LwnJ4BPZdBSAObrSbtTGUSPuToF/1sK2Ou2JN2vK/FxW0ge
# DATA KI11e0cg+hU9vmPpdF8S4jspXavU/JmD4i0rApoqmBu3mMhjwCtkSH2xiSDILsYKGbwhAQfBPRBDtfXKgfMKoo6xI7vgJIwJWAgf
# DATA DfvTkwgcgRuWi6Dyjmzg66SKwk+QvIlq7B16lSsFYwtgSWbOlMcJHkgZCUET0fUr4YANLCZv7UqBknTjlp2VB3k1LAqpZKVZbBqa
# DATA HrUNxeqdjuDiFR70BibEIwHCMbMpasDHarJJdq9uQZyA+B1Y1dmCz3vB9DKAo6IhO9L0RW9a9M5NtR5sPdzcg4bfvr+xtudJhsbV
# DATA O4Y7XD2p95Kt+ijdPlokIrDRgJwS1LubXtIqP0VaAvWUF2EHsU9fleRS8GlHF0GxKr0uwhGwk2UVzbnz5n3ipeOE4bKSIERNLH89
# DATA SwK+AuBu1G3xQYoHQ3d6MooL0h5dTEW14IDtwgzMV1ASiCs+EDbkKg4KxF9QbyDdOiW6hYuF6wBSJAFv4x4oJkyMWxUAw8EvQfku
# DATA mt6NoVF0hW9c6AhCEbH4kjk78BPqOBKdAvAOaHo4KLNnwv6AnyEsrQ3Hmx/rwke6OvJiMeCAjRIHn7tLm0gdqbEFklAZJcKPMESQ
# DATA 7NcVhkZYLg+Gj8UH7s3cNY1pplJrkJcCBEgREizo5CenLDAakouhAQIAXMA86wPHOlV5TwUvxEPtTUl3ENPZ7gYTwI6hYzVqiyMb
# DATA p1vpgFJFTJV4IP3gzEhDYImaUjZ9IQFTYmtSWx5GpeMytPRogr1mCmbyGc+4OAciU27MEte4YzdXgh/VbAGoFtxa+uEdhVl+rG0K
# DATA rBslHOP9MULsoD4I3PPDZvHPSG6SKRuSMpLy0USNVFXFZLdaPbFjWy3Rhf4h2ZbNiGXxsJJOdqqIvuLoN8x7jmoORS5sK+kIb9wj
# DATA zDrdc8+orP0o4n4nVBPWtGTVx+868Qk6ZJ30pd1kn9GgXXN77VrcOZ+84+3ek6FdDD0LQgB4aVOEExv+A2U3p1KCtcre+OEnLMLb
# DATA 3NprbWyKi/h98AbTTUs1EdXcCPm7B6YjUUJPCzh0McFINSW4AZj34dnxYgp3DpzpfRmn5AUTJ5YoJ+EDkBkjdgWeTtI+EMhlkfpb
# DATA N2RLTEmYAUqc1G+MOBgoRREXqsveyi1IPwLF87lu+dUd7qSm7rZCCE3h+HBp3DAX/+TzVLzsBXA6lr0KTMeWG6LapIYvoqZr9GVJ
# DATA bnUN5OlEzlb6mDjCqLZo+V1DQhxyLIAqHEcm18kD/gFYXL61gaobQlzHkC7/CvEqiTrtOCAMcxRzNo3wAiYDHumCZ8QfBWX9rhlI
# DATA sASKx9dXllLiVOAdjnvDFmsyfpJ9MWqCQvfqOzsPt/cszqS6jCMTtRDsuJCgqqofgBRuJhYwCU8MxUxqwMNV9w60hx2BaiZ0AMZn
# DATA B0j6u6YCpizj4oiDU2jNz4zjKhlezUy0c9weJLkn6oyRABDZg0wIoDBudwgTx8th5I+oMzUYZ1owV5Zct70ODgJ3H+6+n/D/PPUF
# DATA UpH3cHKYFUC8PBbiW+/nkbkDadxF32L4alnHP2kunekDMVydyaeTfJTNTd8iZ0NaDuLMipbUITfvyaZDVVVwsbxfSJQl48ohZPaj
# DATA cbsb5Tjb0zk8MhwvpxJDQyWEOf80UCFRDB+3ur0YccssqKXEQCCEUPYT2QU0SKR10h6I6rpk80JinTmO7dV79daDjXs76GKCw9nY
# DATA sXhC6h6Aryk7gH56qfTP3uS5T87Zm8dQB/piuFPic5Jnby3j7PW+rFkmHtzqa7pX19wih8MgZPuzB3aJA8uuwDm1fpRxas21/vlP
# DATA DOXI5spfdFBAQB2F2et1qJqsx1jcqha2tb5Oz4oZi2jMiat3s/ekJ2Lbya+RSrEpqhTCYsxEKmSdWhlh3gAM0AAwNKE5jiwp26+F
# DATA FO8pEEOt2qIK1Q+MvvSg/QSUYEADUMBVz+FLd0H5g0q51PYYpA5OFS32lVg6hUxZ0Zjbhwe9bigZrXgEooM6TyztkuXo4SO2wiWx
# DATA qizCmyGYievizl5LRRCxvFRLhjot+N091cmSU1T3FByHZb75lJtPb9452+eCvqiuOUg4ZYtbA3YCTWQwFADU2sICLLIlK1xSQLjy
# DATA G+FcrPnSh5hzKBerMy6YyWMsz92RjP4JEAPQjzDTSxNBrcfgHuiopWRMWyEnlRbdCludccTRTyiRzGaWFJ2HSCg64M/YL5Dbht0Q
# DATA 822IJHXb/QKW4mcBDXUNajKqk/he9AgkqRGGuGnk3q2Z06dPLgX3bSyhIWoU/de+KxZd1exr+VXOge5L0yeHXInE+0KS75XfI15I
# DATA fPMdHkoMexGeTI5RnghXlTaeAFsba/c39NiS6VfpxJWqSsS1AZ/QsJmxmugPwRXTWqbVi3vSVC6oz03/SejIRtcp6YtfJjgFhwKY
# DATA oG5vUDPeXK+/u/nw/n38BeQCuf8o35T66hMhXl9eWvLL4Bnbem3rwfb9+h6e/PbWzkcPGlpGyhM6U/qccVSXk3B6hyYT9JMTB8gT
# DATA TMDsKZLh8uKzFEEuJVjhft/arvN+9woczJkMUI+mBw8oxx6zrC3ThD4zU63ux/7xXLRSQEZQN3hnyU1cg/kAWqTd5HGSut7eP0ng
# DATA 9YTOncUpuxJ7atqY1LA2w9jbixkd3b6sQBeaeifdLhoZkxCcx6t0gxaTBAf4PF0hBgV0K9AAPf2oLXoIcGYH4+HjGJITs9YCoGeA
# DATA AiZR/7Ti55Zp6pDUC3/6j7msLOmCm0UeHkuMmC5j6auZbiTWLmLYevZOyaFFBm2+3DY1g1CL2W3ikNGKaJ9OyTxO0/GYIw/hHW0W
# DATA nDNEtJhWrVeXfP0657wM24/E4NHNoapeYtdydq5RXdJuN1wweZFVuGaikAvCZshYNClnptmvI+89kGzKDZUjA/P9BLWRnRkTObZa
# DATA hd5gEPmCcvE5xoky3AG5SktHa9eGyzigCFheSoKQW4A5LkgOTOgNj9ziFd1dhG3dTwdnW7RWQEwpmBsSLozfN+8WM7ViXoFd5iGD
# DATA hoWotbGVomWy5y/zdLOm2aI6T6eStxteyyfoM4B1lYLrLX+Aq25q7h5z+/fxfmkdaEpLL30dkndv+qWFrvwl4yauYynQ0aSUejW/
# DATA vNY5Re0yi736DdmzdLmWhuKF9JmXtLRndTC1c7PQBS81AOXYRKsO7jxytV2Gna8pcJ/YrL9X33EaejXYGkQKUxcFjZ8NxUDbfeDH
# DATA 8fTwsNfpoWMXxPXJGEUI0QKtA8xKW1zgjnsxgtokQtFNoC6T4zG6gsKjlDAL1fw8jIndgulqgAuUgXJZrJbxCdfeTA0Bf3Fkr2yE
# DATA r5x3hpR6M5TuyvOVLkw+Rbp0fdXadteflVmPf0yXUsSnSiLfjfo9TdWdUMn7HWBKqWr4mTr770Y1b2rl/1xU8Llk3KtUyM9wXoKA
# DATA c6vQXGr4TAK+KuW7oXe/jMbd1Vunnegv7HeWC5s8Q2fdGxwOfZp5DivNggvXkUiEAJS7jvh4Tj03/G6aEHza9RkkV7wSxTn2grXn
# DATA s0n4ihXnLb+N3lBrEpUdVXOq41DTpFXsPGVRl5gvq9WxN/aphG5gQPo1Y6b95zdFqblZow0Qga2tPY7HsbioLsGC2F9t3bXOSROH
# DATA AIOYWxubb2+13hYbnOsDyi6mxpN4Kqhv7u28b9aAhO04cDnLRGc6LJLO4bAw1/3f3p92DgaD+PTIzVwR5/+mE/dQbp9PL36Febk+
# DATA gq+WB0PKvUimBKxlwEzkUjyTclsIANC/sgxLd3TlqvImRhTWIKowT8jPTI010jKrq/Gz76z9YZqqWoMMaFMi0k9KafRM72qYgAbx
# DATA ArVB/EhIyh2aXvdXDuY5UrQeXntXJqbRy/RUfTyrcmKbp7LCMxXiIV7h3/wb+Gx/cE2FAKT3w5dV2jiYEgMKfqSvQt52i3O5+siN
# DATA CReknfrq+vvhPF2Z61p2ieuZ5WDPVKAWR7PKV2p69S7p6GSCNHhaRzaViLIBoUD9MutmdOnmXw3uklYZ2qMUu4iLf9I+hesWZlxq
# DATA B4MIcONHlCVG51mqLMzUzip65gmt+elKqmhkKUkGStjF6tLZ4Evizv+smbGVYw2yylUhVyfkmfv8/OuLXwd0kspeUzqYfHxX32AO
# DATA 2kKyKhlHl2HFlACPfm5sGge/K7acSs/udoUt5F/2uQiasTlaDzZ2H6zurb0Tvsgqc2IlWOR/Pf9dMlvqF5gpFdLp/ZJSCIYzFnXm
# DATA dS2PyXOWqOeYXbOFPH/VqTofateT7STp9JOdiqg4s3o3e46T/8FIo+M6bM5Op5PtX+C3DNiJRiAkzsxR5O31WYq4fAnDTqY26qUa
# DATA wV9FlDS+ehCGDAQRBqhh7wYHpxRjOhr2BpNKsC0mAQKJg21UtCwOoglcsj21srIBolOHJbzfiDaCznAEec2UorPbax8NhvGk1wEV
# DATA 5mRI50tHpkW/lMk+xR7fMiHs86tBje0w0/R1aV6UIH/ybeaWCYdDH0q5wutTeNo3qYxNJi1buEp6TtAyKq5pUTAAf/f93b36g9b2
# DATA 6tpPIGOK9GwSF8Hth3th1ki9eVONPbCGJ8+2vQ0GXSIAx0j/+u2slnD+Z2VsNY4pmbCVb71ehdWl1Hs8cW7Am5MI/XL+IbkkKLhO
# DATA ScX7SS8Wk3Bkg/8kVEqppVUOmEHvyS7iLxbMHJeVvWNKiXj0oPdkY1CyEmBW8CXkVfSqTA+AwACtCb4am8oZ0AaCtYd3nOviIk6D
# DATA AUWDl4J2t8v7PZ6ORK8wEkS9WPS8A+gtfDst3E7YJD11K/go0fcCxtxzX2hKOH9owZ9WtGjmHSB2eCLqFNWwqjNhXrU2ISESjPqn
# DATA MpZMbIESYog5bx0Mu6c2rgYWUjdOjz0iGnRbElewAKXSChGYYiFcIwjNMgBiyIyYElDRo6T0VGBBLJYQYhHRFsK8Td+PBkcTKXGD
# DATA MQvG7fqb4uv67dg3+sdomCYRA+uwpvwYFy+N/szA+GyiMuEAtHhGuA15kOd9pmiEFQDRtD2OWowWgL3h0TI+gglKTBAJ4j93EZAY
# DATA bz7YQjHdsovnHlLeraWbIGBJ81b49tbO3Y319fpmeJZDxStvFzIbKfho3qvvkbct/kJqZsgXS3JEmG0P1x1bAUwzmjf2hfOHyOZo
# DATA n9IRxCD4FMJFUHJTaP9iqp9tVm+UFhuqJiusU2fzant6FKV2VKIzpvSH3mxKeKfFbFxwwk+E2+HKy4sgS59TbB7Rz+nT0uWnkQiO
# DATA o3nn7w2Fkr9g65Y7MkXBXor2PZHHOXu2vbX7ol3rI0dWFGYwoRYkcExy7kYzk8S4PsKWVmGeFm/bG7cH8WE0LtfhcKNYQVa/8duC
# DATA Miq9WDDH3kSr5paCH8GtpaDLoMrSBsm9MmJmnE8DAZFWD88dhP10+lLMdMcwRFioWSLC4fxMGC/0FXCBQLwTjItnXLKd6FEP1Qtn
# DATA 3/WW9REm9vQFiRM332K7Q/GU/zWpcuX2nf9CRAkr5sFw0KFhL4M2Nafm+H/oUEP2pUlitBUrJB/pfjXzk/3Kpc6GVCInsfB78v7P
# DATA QN62Gvc7ImyTphO2maug43SZ2roc3LIuB2C6e3vr4ea6ezl4qWpRq0M/JA8epQCC7WT6lpK+55Y4p7LUSHpMl9AluetozEV32BLy
# DATA IMDDWXdM83fgCf4CpFaRjjm0TEmveSilEAGNVxRUH5Kw8dyPBei87LN2ur/j18LssGXGFNzdWvtJ3aRysz7LYxQ9bkzl00QqoMhF
# DATA pyTVMIS5joWq3mol0PUd0zGBFVX4p3U4xGRBmGC1B/7wnFwT6KjVAimm1Qpl1uNxjI4cYv/h58rq+GgKMIbb+IvKtAUW0paQgTqt
# DATA VtF4E/KTtdr8SkG7OKLz5jZqwBloGL+J+9lwNFlULpvScuOtzDxpO8dDQDauEcgxiofaadJBNkCYdBl0KqaiLJEwsawMLWlmDkPG
# DATA QWYWIuV58c203/vtg6if8Tua2bKbAG/Q9ApQbZrxO6P3ZpRgXEruBAezcln8A6Wl/glCVfEwjaY9trEuueiSu+jmW38Cd/GdKeW7
# DATA IbcS2tsKthpyhQCt6KQKoqGKHQqr44AW0swb+BaZN/CjmDD+hKvDn3El+DPOukRH97dLFGTiTALwvtsUBz/hZ55p/sazmt1Igjot
# DATA SDcbwtVtOlcDvCN0tYitqesqVtBhVU5bdmXmHsuoUeNP4EP82uvqtfGh0pNe2q2quPAX3//7/t/3/77/9/2/7/9d9b//DcDxJ4kA
# DATA UA8A
# END_REMNACUST_HELPERS_V1
REMNACUST_INSTALLER_PAYLOAD_V1
if [[ $EUID == 0 ]]; then
    bash "$directory/installer.sh" "$@"
else
    sudo bash "$directory/installer.sh" "$@"
fi
