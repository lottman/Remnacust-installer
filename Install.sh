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
HELPER_BUNDLE_SHA256='40f2f01380c1fd3fe678d0ecd9156eec26de30a33bfd0af1efecd7ce6ca12a96'
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
# DATA tUYP6PvO+94f/n2Q/W8U8H+D+7+7oJ3l7X9QRf5g///b1v/9DGtFBFNfHbqYS8KblP/F0kHJZLIkjaPqp6MR1UhjevLDFO8RvK/u
# DATA L1/Pqb7F8/k0VV8uf5bM1Ge86GacDNXXJP3diwNfLRfJWNcHDubop9Bf48nM/s4lgzE/4WR37wxvvShymJW858fHZ/snmJxR+mb6
# DATA ff9k/8XR7t6r07PBF/uHL/dPTgdfNr6BZvtHz6jN9334NFjXavdo74vjE7rRnFy1eEJsPtwofzqp/Dm3HHz26ujZ4f7g9ItdYLM7
# DATA JfsWkNIPNire84PD/VNMRynlN3iJ8zxFVcVvtlsi7zQv+s1RE+zLi0vGYsN3tCFLt0eO1aecLNEtLdtbufBty8sZKKfnrkA4s0Ze
# DATA rwOuPNXqGKGlwFGCvzvWMU3IktB8p+WKUaInJAac890ypfB38ZPhR+2xKlW8F7s/GZzsfoWl5btuEQ16hAsOz5q5R7mTZVEZF1vV
# DATA NcTK3FEcAhxlpyKGRIboubriZMiXm1SJwHWZOrmtxOpU3pVtW5MjvtQAM6rVZbnyvkjvwetY3ba87a0tSleiWlPqP+VPtzet0w/4
# DATA /by2eWH/VPm48mlJxUjvPeMg9xcI8xKodHEmzNcf4A0JsbrOQxI1MeyzoKsjy6VNdYiGci9GCR8RWyxnsHmxxjiGVjDCK6UXsR5R
# DATA kgE6sJ4jV44pN7hOUcW7r/qAOrtpoFGlO2sl3bWzjgwD3kmT8NGxuf0K3vqLuB6m6bhsOoVfrZnoUtlAKrTpBJ0sEXZsAuPHahV5
# DATA h4aY0lRmHlnxf+Q37luMZ/pmPlmOUZou4rk5oyS8FouOTJ0wG32tSntfzpPLVGXwfNlDbluLpxFn7wBbfjDH+MDczlQEoVooEofJ
# DATA VB6eb2/iqR7s/4JBwudFJZQRrDI+tLOKUGQ82z3b9UtSQdHeGPhwb3fvi33flgO0QdT3VvOO9gL2W6k85mT9q2n8Zsb3hjiz9OWq
# DATA IrMeOC8WWbpSDhMBZRbeu9Yv5EJGo2PIWME0BAXC5Ue8nHO8PHxWZjbkf8L8SOhTQezQqLydg9Ai5cp5XZakPNwobVTOGxeaLVJx
# DATA KM3udELLPQOAQIFuisX0BsFbLwF37rbxMwxXtXeVqZMcqOopk+BNMllOdhSTNxzywYKb+aPlq/j/grFNpx2wYhjmpCzHwZxqOpgz
# DATA /tahc6RGHiCdwbqXgPgqfpBhsziYmLHoCrwd+ZlOIZRlJtBnw6EdEg7AFeT5I+ClWmeLNPXHmGnjUkle1unrFrhORnkeWJcs4PD4
# DATA A4zeava6/cfgSjpaGV9mbJ1zw571cedYxCTuibcltmLpDm0RNlWs4m/CcCVdq+OOriuFV8/VWxcP7qtX02w5m1E2qtpRCu5S5V9f
# DATA wjJ0aiYX317WFkPlaLdqNAdZHzQkCy26cNyt9sIdM9adkj1W6Sl6qipPyX7DtSWFW58q5JIo6minfEMaux/MvFxhK6pU8dxUOaUC
# DATA 8KmclbSxYiTi6pkTopsXsMbw0+z2L0HDr/ylKJ1/yRrnN6ByVuTo6CPEoYNdBIpq5qzIWguLXKxCIxFRRmqLbA69A8i5xDvgYbrA
# DATA Hkz1mA+FW+XMunBjclKZO2ZYMCc7k3OHCwVX3f+h7zRCOlAM+wPhwEJ5Zjdky4k7vKMDMgGouh1IYWIlPIKPMW2t46K4FSxZxJXi
# DATA JaEM2FpVypJJ2URHDr7F1d9mEUan53V1Jj6to4uc0dlyOcDzttjskcvGJO1xtUqPfQbI4fB6G98pS0PuqyuLkkiTsCsXCft2etEV
# DATA f9lqIUmBdYpcNYP4M7fIKwjUvIhf3c8HXIcL4slhCH6UchE13AclR8QIq/loRwscjYn7zzOvant8sfga1uP0vMqC9OWXtjim1nxk
# DATA pbJSb17uv0TIXXq3kLvSprhS1HqSV1czTvC+UsCdddHpGuLX1+2tkA2wL3OeQ6Z+D5GZ4tH6pYLk25UOcBNZr8AmUL6oKmsslaq9
# DATA Qa2mNHolXxxDSiEaGNbUPzNHumUlcY9+/LHMXMGwjWPcrS6/Pofogu4cv5OUaU6vp8UuW7Si1rqSb6+qwHURVNH6J8M4inJav6VU
# DATA 5+xGOTOesx3zFfjuMSKroL+CjWBbdGIM46AROfhKfM8lmlvnve2LAoPQMQJpG6w3+RzlSA0jyoV8RebfXVdcdb3QUbgrkD4/S+Qk
# DATA Pntqa8NuW6wiGbKqydXK1yX7AB24tc/hP3h8mfZ9OvzpTpLWPsN1Pjguc9+VQssBSCpnOCjXV95wEM39ETJv351mtiL2lAooZ5Zp
# DATA FuIaZkOnYBI4PJ8u2CnNt9kMkgxsA8sEMUyuIFVxEKhYfiyvsEF5QLpi6yGudgZzAHF1m1/ELOeI4E5JRHL3hS4HfgZmo1T61S/W
# DATA pHSv9jKaJ0r0MvawxsiTkhmnpiuPfPNN/ufHeSDwmvEVEhU8lvInXVC4WCNcWCiP35CvnmbGTSpMWeqGjpuBNut2RKuapbOy4nOV
# DATA ddxdv+aweXVV0+pzrVJNo3heJFPCAISUXQ3vIZGSLhezJZ0bMIRZeYCG+R1FujdrKLdQBsgJx4dEQd6rNR2lfNCIgDkL5gfwS3lV
# DATA n8OGRG9V/ogQqo8YsfB3HG2h6oMgaLfhT9GxHMzupyXH96s2glzpYvFtzen4tzIxMrTK5nGWlRlvuIFJ5caKCgTVTl1X1BahwYJC
# DATA V23DRX3IPnvQdUe9fKhVQy/5OXtMwPyEI1HsOaSCKNi4JlNXri/tYsu/KSLOiCm8kZdReZ4Afb/Zpv8i167XL1Q3bL/QAzwCFUwv
# DATA Y/SO25Ksii+49SQtaQ4dKSgwiKb0NK5fzlEusVOovb2X1nmrtaNamXbmlgVdsEJ7KJ/oTzV0IHCBDdZfKpqdUOxO7B/n7VKBBqfI
# DATA JGfAaHcK6ru6py/3T04Pjo/UwFzZo8Y+0ce4+qRXKSTG0Qz1W4FZoeVizqizrLkPMuFcTPDdQY8x4h7DCm03sf1UkQjerE2VNtR5
# DATA JqcK6JoFdgiHyNCUVXFW/bvGFDmcBDGyfo8lE9ve1a5ITKgx3sht1WneLbm91tR1ax7rQsOCj7ellQ40Exdbb9vh7Xf3CiDH9VW5
# DATA u7M2Xtm67QEnWaV3MMSo7nVC9jNd7DT1pe6K50k55BUXgFr/R7r4LXeB7ll7+y2bhE9tWwaQ9ex+1lFxXiM41Y2Q1FptEfYXiOwY
# DATA MFtkKaZ8NoZXiW9hDX9S5G0Zm6pzjaZHmL90IxuXOZqXDVTWHW8UZ/7mTb3OkS7TZk0doEeKQHNSTV2cpPtlE/ieq79EUwL7uNOR
# DATA 033KwDXdAOKsdfceKoyzcgLcNC4K6aytv/hoNFzG01hdduPlbl1d9Tnog9T3uhtU+UnX06DOAOpzf/ZhwIIzgFyC6yWoWPH8mgtt
# DATA RQFmhEQW0DVfKsX5lDiSwS69latuqB5mrjdJUsId9tSXHAa6ggHgBV0XlmpERTQXJofJkEitoHxRfq3Ltk/w/vpxou+tJ4UYc40C
# DATA 4jBUDkwlISFl4mcMy4+SNzulmhh4mxgFSeY71gaqrKes39GZo2uOGzhFHjlMSPHtx7ynnTjtttteNzXV/tWWu7d0Qprps/eqh+Ki
# DATA HUKbQppo98T4ofCmZnpSo8w05TR6S99q+/s/OTiFLSHfQITvv3h59vXdPSVWVp5839+d0l1LVvAbr2+aLYfjJLuibZChrDd7QN0v
# DATA epVkBd3N5mkIVgoexqfyIQvYMvESmAJf6eer4JJK7MDiD5KmVzT734UZ3c+QgFLUcfcC3sT1UAj3RRdE/+uyqsL6GDh5TYfrCyQ4
# DATA zfJoMk/k9gpzj8pHNiexflfI1W8iPTuVZcz2fzTOxYeivHtAGshCJdOuoBIMJ0fW5pPFPLY2k+1rcFWPtZ4MIRLa8M7rjgfXTlOi
# DATA F3S4HkzLyu+l8EA6U7Rmlw5A64DqqWGMoFTVetcDBQPyNQzubUxYenRrCf4+ujnS1IfBwwuy2vyB0gaqmoFGJFWLIAQasiRrS9cd
# DATA EDV6XPwq49x61zHmVzqxCx5wyQKl9VJTSROyDDRd9YD1Vf5iacQMEqvFlYcLYTBt/i9yxiCfevvd5/83Gp1mbyX/v9H9Q/7/d/Fv
# DATA Y2PjJMYKVX62nNGFNXFkVUbmHG6pZR2gUwATQiNoHKKyMVqO7btp70n3p3T9D0jSXw5Fn9G/3OqP6HP1vJP9l8enB2fHJweU6c4H
# DATA kqQEDPobLq/CeS1Jn4zTxQJM+ifmAltdJmblp/y1Tev7WK0s4/RX8Djf9zgFDawIqvyDgltcuDMuc3P/XFUlnNVf8sPQ79Dzncc3
# DATA LhJSLXxeLRazbPvJk0vQRZZD9Irr4U5yk7hzJmvAfFQXDMedd/Bi93OsP5g7ByF+pO3z+uZWsDni5J+K92x/99nhwRHmwFMMVwVa
# DATA ZmmWUDUlfWuCyf4r/XHJuVZuJRpsLruWfOk/LlHwVxVCz7eaS7Nt3UyBATssGA+wJHeZtxSmk6cLyrhYvelFl/Cx7jWi1xBcft8K
# DATA J+g0bYwC4UMuGHkQ8U2N+biDwqsVfTBdkBpq9ch3FzCcD9yE49y4WrYAOYFFOAsuM1NB9JOV58/ImjZNvNV7FK03Hnk9Qzq/pMCX
# DATA uVaixp3IRZZW7eEb9J6ewxSkWNvIvW+Qiz3atEQ16mwWdK4XcaUgK/ra5fIGpwtHueftyDMwdz7KVrQ6r1zYCwqA54stX15S0TcZ
# DATA KWGndB54a5Z0kIs3g7ln8S7nTyEZgaYDmqVkNeFIdGWwNSs/GGcpUztZoJm4xOD3JMjirJbrdfc6BXswyF5jz8+o+CB6brgDPHtG
# DATA 70FH/k8xQ5l/j7DjeDxyOytewcK5cQK9iw95WoC9i4LiWqqCpbVxMLUeT8Ik4aKGYg7dzXjlc6Vie8bGOvanKGt7zQ2ghWtfdOvn
# DATA WnjOzZcLN5rGL6kjPIT28seoBFdJTA9YFc7l9qHWy7c+tOoIp2a4zq3k+tdNktK1SQrTxThB2boER3X1wx2/nnfknnFpS+UyIKYn
# DATA 2iloGkFESTSg3IP2Hpm7ZMjxsWNpDbX5clo+l4KWWKQPp3dR5RQwceqGwWyBF0DLdPlHjJSojwzKzgTU/Va9agCvOFkoasRsEUFr
# DATA ysNpPz4RR6gelgTWGJ6hgyqOMj3ncTJJFm5uppVhnh8bQLJWkJfEbSOrPkS+D7YR546qm/f4vi2+ZNQJzUozjsya6dwm8Tjio1B4
# DATA GwG8uc3vc8xXxsJahAOWWsqkT6h8vZBeSdVZDLiwoi5k7qRIqaVmWbRy+dzlPF3S/QlqZjCEfeWfelHfnS1jg+mIeY/5C2Tevq0R
# DATA 7d1hYvHH1LkLjrMiunf3wsOyVXqRa3xKWd3XcTwT4PDyA2Cmat/Qb5Yuk99EiNlmfQUXDooVcVpDWra1JDRm7lEF8jtbLzhxw/sy
# DATA uXV/zAAfzE94KfcRWFXVVRfISRL2Edq3xeZXjlM/VdlxOx1aw7L+El/3Hmk7DR2FdJFqhAf1WJ+aiJZfqlgXqGtOjgDgum4/CHmU
# DATA A1uTohrA0KTu3eXMlG5XdNywQAat9D4u3m2q0ukCOGeY23suw7OGpMN8aLPfx+J0npoYkzj3YbqckqXpeCKlgaP3FmxsM7ylBfNh
# DATA Y7xvDgThPSjlzbwWn0rH2JGcopGjD1cdnXD6wYq98hvnd/WPdvSm3y4qyXmiZaagCBgPbp5oe71wZE/sDtjNyPrj+dz19g6h3et7
# DATA w5GuGVDAxR+8BP37vhZvI3gfUbaJEQm2ZaJ4HKNN+xR4ik9FeKuKHc6ACCl1UGrXu7reyurOJ1SHVy9NJaez8ZJ+suM3HhektPSI
# DATA U/2xKGwpy8NqilkTmXWYLsd8fR464ce3SrFNFusWh/sblfZwUQHktwL7ne2d0aayEMNTXT2Ybk1XDDZHKaXKt3Gtf3ARXtsk+pCC
# DATA vix7MK7JVzHtKMt1TXtktVZ5XlaArdeVDfmAL1tJarcsrriE1V1t9IVk9v96zmFdpOH3OMYD9V+avUbL9f/We53eH+q/flf+3y8l
# DATA qqrzAYVzyEVe7HQV2x8VFrDQmcHd5+/N1W251/1b9V+CHfYSTO43a7zBlu9X6rXY9Sf4oDOprXKWi70OO/kyFFZiNN+7Rpru/QeZ
# DATA KTHpajl9Tb63BfDEcTAZRsG2c0TBsvYqWCMjH6FliJQiSP25R474eUGFDBXy5lDVIrgEfpSB7aOUH7m8meZjomRWOrul5VODJ6ow
# DATA C18Gsqroj2FxC9/T/HGTnRTru7CyWeVqTU4y5IoAdILAeSyUx89hjvepk+/+y7tfcm1vVcj7H+DPb9///P1fv/tnoczNd7959/d4
# DATA hf27f8JC4LqSh8CfWQf9cldQy+Wf9pk680zOpz6izPzdgzOgWuMyAyo9jgXIf/PADChxmrTTt8F5idK6L7b9gIg0QAJl0uA58Wdz
# DATA kVAgS0FXcPJNQssZLjAoB+aqPksISk701ELcanrQLEHHG9LMOePDvaccR+GfyRkhuHN8mBywJdj0aXC6UCaZ2lnQ6dxuiTc6JAur
# DATA ofzw4FnAd/+XwivXcyes/+b93xBJYSV3+ITl39//DdWEf/+f4PE/Uvn5f4aX/oWPDBYU0BdisUCkYwhoCQBzU3fKMgEFk6jbRsIJ
# DATA 5hP4cPcgzP8FC8//Bon83d8D1SAsv+Gy+FiWHijFKkyP9e7f/TNM5efw/W/XwkskAxBWTWSBYD/PwX1RnBEm152NrMDSWz3K3eZb
# DATA 2MR3m2CPLN9svsUO72rAuWuXPyvl0rFmyoUxuieIZfW8/Zah1IX/LtRgPExpxYoxYQO6OI+WQJ1Msh6yMeGc731MlqXNjWAhYBl+
# DATA 9e5f3v9dwS7+RalSdO5qzZ3rj0THH0s0rMRXs+dPxJvp6Qs32YHxoVNjRvuLd/8IX375/q99/IMfgMxgdvfyrMcfe3EhNlUA8La0
# DATA 4goAKha4thP6qCJhHzxr2FJ/59Ne+zVNlG+H4J9h7j9/9y/wf794xFoTK6bLXYh/E2yckqlkjbEoMdXzf7D3tt1xJNeZoD7jVySp
# DATA Oc5KdlUB4FtLRRY1aBLdDYsEOACo7hYI1ySqEkCJhapSZRVBCMI5smWvx8fasWd2P8zuObOzPrtf9xy5LdltSS2ds7+A/AvzSzbu
# DATA S0TciIzMKoDslmctjaeJyoyM97j3xn15Lp6HgLX0nGj63nVrv1AHYJnZZ77cG50OgaIv45FYLhwG/Jxm5mAyOlVXoo7+pDObDJic
# DATA UhfeM6dEfEXSCZXTsw8EBue5LCB7MUKMHPEXTIh/8vof1d//6fWXkZrhX2L6kV9gFhDYib95/UX0UX/68ezAD+Au11OKMVCMKyJy
# DATA JRLBAYvs0WtEcNBgajdu3LrSeeHNAAP4ScUmYRFQCyQ6XEWtaXdaFPuchD5A8pKWL/FVyIxLIr+VcWqt4EeBUf43ZIi/4EWinCqc
# DATA AyVSC0VnRJ2ZCGtV9DCiWt1QCt3dPSl67ftGVGJN7RLOtAe/OQUuHzBI+FYryEN7Whbax7FryQmEE964yBr2nfU4v3EDXzpRMdwR
# DATA I5VgBlYUPMw7LYh48TCy76owsd4YDl1L77zgkYQmcEu23A2qgS3QosXZoWr0D1NA3hgDNI1TbkX1UotP1RZ0E7oovnFGQCgMNHnO
# DATA i33OD2o+G+VMLlAaiCv31t8WRRhFX+WZcWgFyWaqOEhxsB8p5c9PBTYZjmqOO4AjdfKYHLlzoVpA71aopiiVBkb9n7HXf6oG8jcg
# DATA Pij5rih6qkefK7LyU+RDX3hTAuKr+urNX4qjCA+dqxHSGwO72D8863CcLAONyT3TD1ytxagWQTHZ+XitoQqF6J4QvD9XK0mkXRH5
# DATA uCxwmToYT1pKfnzHYfZovUCfi9lJ7YRi3U1mVlHuW2W8oHwXv/48OHg1blir/4ByxW8iyLQFJFM9+O3rfxZyA9Co3LFzLhjQz6K5
# DATA o1Opicj4IqsER/N+3kkP8tFgNmVn9LjZRPcofAtAl3lJLL/moTUDIYBhAQInQIMKLC6AqQsNCpFqd6j5YvHzd7j9fxYFJ/aXcXBc
# DATA egT5Qk0Db/scmBjkH1NH6a8gAxodp0s1ji2CztqLcQf7HDlRhKAJYqOT8PK0sjijvx5Niru88LGGbQj6IZTPvCIaTkVzhFtd1jEn
# DATA 17ijxXOnSxf1QDmAMPruYqrQHpMcup7t71/i8CGBMXIKUMNfAHN4/Q9w0AQFNTT3S7jR4LHUIkzphYYYHFLHMpwJMTCbTruwprKi
# DATA 4LqW1HP15eX7zJ+rUf8DMdg3/5P6+4s5K20hnUSXJYqGdqoUtwJP/apDxKSaU3AVfVebv8b/BZYV7mRqWf+cNDN0aK/AbXBsUoYS
# DATA ek8bokzM0WWfbFOu8b9g75U89JvRw4GS2PpdawQFDXaOLnTUFjPZe9YZoueUMjI9q4dJ1B0MRqekA/Qnrq6n0tz2941PKruuru5f
# DATA OLZ83Xd7Is0j3HDorcAXBW55AXcmzMr4D3ja/glOV9nR04IaeEK0nZaXCuty7ovQ5E6x5gifSkoY5ebdVs4SOh4a/VSfoYvwsubp
# DATA y6xXI+W+u6LXr19/CD3CtVHnfJYOkNL3+J7CXvJDbduYHqegseDoNnJctNQVjCcuTzDgU5zr1eIRFWUBPP7aSaEc6kUPg1GKflyB
# DATA 9WKlisLrP0gVxn0Kpv29toRGqpQ6NEoX/kA/DytwEgH/1lsqGWw+Unnq/hFzoYJGUh25BRRUZQLLZQCiSllRqX8ImInEioOtwJVi
# DATA ivXY02LFjQqYJz9xvNuixf2OWWqKOFaatuZe6yYqCWrxwWB0QIkQ6OpT4gFDDHJB2ClvJi7LONvzGKcrqxTAsbjSpbCACZtWi3GG
# DATA NfCDS4tqvxcxzRdY6P7uD4GZgbVbmhh5cmuuHES5HHKZozhHQLmEcPL1ZvAm3xsnilZrHvGkoAKTtIqE2Ob44cXIZ99leO00Par2
# DATA GTIG0cXqszr2+PeRi9xVt1WV1H5wiw0LVZ2LFta+oVdNg64Dful70jYHNonQONMiuf4HVAWZtoN+yVrNK5aM8P8gdNg8K+Rj517B
# DATA UTGdaoXBUfwU6gWlejgZOzn0CUQiVutXVOfnaOffcjtoh1y3Pa0s9ydOqycD8xZy+/RnRp/eInPx1Ij4IewuQ5EKvNevm2hAac0s
# DATA ipOTZH/YPJgBaktJ9XlWWo++qfkzY66wemIKVYfy2WsIm7oENCTv0BJAEWav2CaeqGJPaaMAKhJ+n8zx3iVmtHOWqxvN+it1v1u9
# DATA os+hk83o9+H/p8TF9295/n+rK7f/kP/9a/P/252kw5wOpbrQUg4sxcgg/ifnGAfQJmQTdYO1wd6KToHkPJpNqSziiqgi4DOeDvLF
# DATA U791R+Ozt0/q1j9SnTe/pul08UhyneptMgCRm5Bn3GfgxgyWWewPP8MRRbYcqlnq8NdsiH+7KeTgIFNelqFilFMIrILDjrfoDurS
# DATA lKxl0WAYNkaRaj1UStkmRuVlOwPSg3+YsQ14AsO52yIz/SeKBuhYBcW9YXWULNkF5VX0xJAHknktHbQ6kbWo10+PhiMlWHdJ56Fk
# DATA Z4SdmY6i/Hh0ajYKEjncKCjNzrgnFECGO4Zt3+pjsjzhq3o0GtPudGISGcARp5ByfMm7jE6C46of6Ju2df9sUqYh87ISZc6fjUW0
# DATA CuAt8qfsPfLPYMhzU53okVE2hLnJe4o9+L/VZeGfQcNWaAhNgOCm4rq1BdP66HRCGu7Ixiy7/THTBEcMESU7BT3GzbfrdaV9zNpH
# DATA wa2C9Nlf+m4X6jr2+neucwX02UDFqhvYtJMigIX0GuYDYfLyyU1mk/d1YHPWrPtwPbKxDYxzLCaIXDPUxwhpnk6bO52NJ1uP1muE
# DATA dDztwDvrMwsF/yhaGSm2WA5ND05t/LUiLXDzHuHdNlO/Ftkx/zveUn+u5lFdSene+Sv0sfkt6JB+B/ZlWBZ1Df21mtnCnfw3b35K
# DATA 9ne4ff8T+SGiwf7Xb/5j7AJBdniu+arKs+04WcTwKG7Z/QhwoBQL0ooI/jlGvSr/jH4M07O6igkaX6q7Fqh1eTbUA7xiEtyEfqp+
# DATA +0lAwv1qWV2qmtC8q45AnzuFct1wCvHgHkD2DHQqwlU2U09Q21vj8mEobM4qAHvkcARqdU10ciZxBfkRG3IViLyfdh5vftfdT0Z3
# DATA aopsr39ULGLePtrYrni7s/XQq79U47o4gYRth1Tp57DpfiW3JNnIxaYMOxJW9I+ol3xEp+r998nAUXp4LjGwv1P7nZQ7f49D+mX0
# DATA 5s+JqIFLbvWA1HFC7+9/ZP9dPRHwkaJ0aG8GBdKvwINXPSKXt5po4O6KEiC8Vr6IIH+HcfJIx+PBWceldvQPxGXhRd5hp/qSgkVa
# DATA JXlDUI4YgQ5plJOlgcrv0Tner8Pzrc72o63Nx5+ps4q/1PZaf7i7tW0ebG59uPX48dYnDKYqL6F8PlSxQzwdtk3Hylhzzrw46qiJ
# DATA NJ1iErFfj/QTog77zg4vEmRt8TIVMUkSFRFRCqeZuizN/YK8BNHV59fsbgC7Aggw+zoB6aXiQoZw3GpxRcPaiwK9C80qTDlh89m3
# DATA drh6AgjBAdsij35/PpaCuIqq8u5ASZdOyxzDY64U7K8oNB8g0Hb6PQniXoguKOrVxG4iwyKlAybVS9bjZrhuZyZttDe0kQ7Rnctb
# DATA YcbQYHhmbWldRn0fWRHqWlon80RV0YRSKtloCheU3HxSGGQOcNA1HgMA0AZ8RhyJLjgKcqxyestM2OuV6nCoW2IkS4Wq1atC3eqZ
# DATA rNxZTH3mPNXpAhLNf1YU8u9RAkTXQd02fK4FxuIuSaR8Z28c/hhxnm0n7UyzHRaiaWBqCnNoQoigBG2q2VBjvfZiQ4EyLwKJjCnm
# DATA 5yLynBLKkEp8SdaISDEmsCH8mhyordkEuQq67v8DOhiiLyGK3hhLUhSZ69TDOjjD8l8xoDST3IVP9mLQF+zwQ+OWypjLnWN1LdS3
# DATA OBNPC6TC5TrCU5sLq7lPCjIwvsOH6p4NuBd876aP0IrWWqYcNPSEgo60Jz1cfNyboqqgCV1E+6OadupiRbv8zUzNgrZSw++xuiyf
# DATA jiY981vdJOav3N/aeIo/lcoT19SFjONLWFElDvwZecATg/gJcoTfRLiQShDhuCUQ1d/8JZqc/rn8AmpAxqzKolaDvmOsnl6mOg8P
# DATA 9gL89cNZBkiv8OfhJD06sWlUHHChsqVgvCKNk6YKsFeKxorBAMlONnxZA5UsJ++WADUvsjN+aqoORaWlU9V5iEybxH9S+04rewUr
# DATA shc9n+6/l3wH9oENtVE1cvQMvL7Rbt74N7Eko5AuOwMld41rJZQgkKKaTzy6Ci8IsA6SBJjyFDIadVrQfaAhbbMVdWWHg/Qob2OV
# DATA FfYErh/+0ZmQdSJkzK7yXrEBfuVA7arPecLHk9GrM1J/Uz+cQ1qPXvSHvXbcTXu9s9jqXczc1r5z/5pIK9ps7Cfu5FJ1NL+17xTK
# DATA soUTdI3g0YTyKMuahobU/ATuw9EQ0dL0h0suGhZIELOhXYZhaB14eLwEZvI3pFOY7pX+Cx3boeYHIuGQi6nFWwZmjUIfj/pDx+dd
# DATA HzreITApJ8mf1J7nNxD9foLm2+f5e0lt70/uqb1au5cUoCOFNwSNh5MZ4j/qLOEC0NTRo5uIuUd/39qnHReyIClRDLnhinBYHUpA
# DATA Fj+3Oe5DgRQDIAngU0F4D0XAQLLHU6Y7IgHfdBAVxanjvqjO4G0uPo8pEpUqgUf8t67pXNdUzIbjBlcBvschBVnJntD3AYeTIfJ3
# DATA nlCqAs/bOerRsCo31ht7/p7xsGjipoEGkqjhP7zwLrc4jxrPDbO1F/eOzC6YO9pE3qnzOc/fAVOB2yVwiF+gAPFLkBVQSPgSr5m/
# DATA oCefgzTxO/RV+FxJFH+jnv4Gmc4kgxiJjCjIPXmJwYsMXGIoVAMVSubNm7+Oy8HoTLpNANSpR0ItU5DTiCUZxbBVwgEBbFt9kjmS
# DATA 6jFLmFC5yS1USFleyO9TVI4iKzP6OOyerHJPtbWP6KlGk1XILIa5wHWaeWwCmy8koIK/ys8/xxadkMbLU8wavcf7779f3gACsV/I
# DATA FVG915k1e30dAWLWg6lHS851YNWWwrNi7onMxHRDw5cIOwb2cRQk6zYbh02EN2MfSCxBUjN8yGG9CBxaJVMWIcpMnXv0lwPrumf3
# DATA Gmp7bYfgRoAfaK2HByvGTIVwxXCSiYMR7KYnu2jJR5tEUPjpT0ZDvBHTjKp7w5SycecBiagkzIHnCQQ89bmZ+D0twMOSoC+Y0L1o
# DATA YseXGW0Skj3yp1+/iIVbAS4lajkLy0p9AXkNumKz8uy7IS6LSXniaAM4B3WfdZ/YbiBrAxbSJ9TK9d61OfDlN6Pd40xx3Hwa6V0H
# DATA pymdTY9Hk746df2XGQceDrNT6NQ9FmcpmxDZvcYAyDodjYo5Nw61eao/LOsCalIm/SPEX227xwsXRGjRTWAfrXtd0DXfCyQwfmC8
# DATA 2Im9xuo+AaZqIbhMoCbB00jRqkXd1aCk7DhvBOmMuAvYms5VMy1atwsXmNAuf/kWleTP7Q5/s+eU30endKhWH1KwCWCvgKAzfqB5
# DATA 6OZBF+ijMR8kAtlTDPMHatc3MAjVakj4MQqADBXIj9Th8IJJbSX2BNXZvV2cKWjuMK5zsi3dS01xwNcLjiNPOg0G7/Q8EBhj1HYM
# DATA w9ixRDipu/5GbEyuQVE9VvY3i2/E1hVfgw32lSw0GY8G7A2Gz9QCNNAOPmP3QgeYU+petFd8APVwjxOEa7VEPbohdC2gGu930fjM
# DATA +Cjue3Tc3dFkEgvse20i6SySX+kATmOV9HbfqIwQDc+491dQcQ3tppWY2pUJopNxwYQ+Bj4VcAK6nT3t8XswGg1qEiuO/6ZB70xp
# DATA FQzh4IRberZhq6BQg8S7Fenm8bMWunEoeSYbwx812kbSlqdDk401z/2AXvv7fMJdaJnB2AHnPOL8Qsga0EkghixAw0+L1ampK+0N
# DATA 3tYf+mKgJ80g7y+cLJABrJyz8CdMEhrcdvPsZBAX+1erqADTPjanr+AwkBEax42Osn6JpJBztsLDITCOgrUWptPoDTJwUSmq7LU2
# DATA zVXe18EdpXOSKV6pH4A1HWVU+RuYCv/uDxEkVD4iZzXFKSbZaToYyFumUeJZ6YU8mWr6jc3JdzbG8DxZleEMcEaAh9QoE6pTiG+d
# DATA WhV8rb24hvr/UPetX4GF/M1fsp3nl869ytyZTFtwK0O9nSoFqjwXWwGM83TDgjj4v7Y+JXaaHVEfDaKBrmOuKvuJUcGDxhTIrZZc
# DATA kHYPRrPe4SBFmMb4qAvnOlnQR+YXhF6EykwAyDGoV79FW9jfR7uPd0oGpfb/aNIzmmg26SxgNbIaeL3TFp4S+4WZEYCcz6dZioYJ
# DATA EPR76UB9+XYz8BNysAAV7p/CpRtu5f74tfeI6ZJrN4A+76h3T7SbuelnEraX0SBh9AsOcLHxwfX/c1ZXf1k1us+LKumfv/kLf9So
# DATA ssezL040/KwZOmGWln74F9vAHD2lhFq3b99invZqkp4FG5HEh4RL+XtOUxtUmFv7lm1u3lqgOdPOPL6AQJxzdwLI7JKO+9gCCC92
# DATA tup2TBdoSLo1f/n+G5kS3vx1tPZ0o+4sFsBOMA7Fz6NPVc0F1wWLPMGuC7yA+XE6Ie3pHGstO2uELK9IiB15JmAsg1rJYog1iVIi
# DATA 5ytGS/kM1S+vxW1R2krglprgwAo2ZiuQ2QG00DeM5JPRACajZixWjlHKjp6YFuNVWdPUAlZv40EYnMolz1fems7EBMhKn00QKHwv
# DATA VmPfW9m/XF8KrclZhrV6RMMs1sUrSXY7OB5cMnG9JtVkusy4Yk6qBiiIGy2QOy17xS/2ncmo7pThKfPP4H+xeC9hpWyl5bYZvf47
# DATA pKp/iT4mPwfz4C+xOAXLkVlcWxUBL/BL/JSeM1f6OT/8lQHQoSnx5Cn1EPWV8JKWKdazYIWwtpkNVyAxnNfhyaFAu+IU/T8YW/dn
# DATA cmrIAwvRcqxLIllBBSk6SLsvZmPhv0APyIWCT1zDgUmck9GXvufE0To3NHhkySTSVgWKtyaU0MnPEWFatVYAqVhLii+xmjr1RP0X
# DATA nBxp+7esXF2SZv0Ck3yBqGR+0mWopa6v6sf4GABWW+oPktwRE48Gwt2iH8mFQHCtkH5d9hUUsWQqBAIl71h+7XP1am7tOVI4Qk9S
# DATA 4Juk2Lb2QnWfd1oWwoX2up1TRf8wNIZrba9uL/gLr2bw8kOew9gzCxTrFBdkt2paluzwULEj0DS22fXEoaDXwlSQk00U+SuO8tx0
# DATA 2mFhemfGwVR30ulDAysIbYurYlFb0Csh0NE8bYsqy+ZmVKtX3YUfQjHS/nu2mT1GuWCdRVDTZaYyYcxorlyHFBTb1GlXXkEZ3IMN
# DATA su9WQ97SaOYJgFQvS+OlGnu7wQyqRD3qiMN0OMny45oOOjW9r/vyTL3CKuCvlQnpJpeqDtGktnux1tMdrhJHB5vfdDvwWqAKIajw
# DATA 4j20X4JVleCd+8Nmnk05H0At5kwSpM1zgS/Qpg/oE/hxK5z9HV/SCaJnceKZfbCEY/ahb0xSQPBzIceY2DTnsNBC+m3cI8sv08ny
# DATA oH9gEWCXFVONF3dV/r/M5cowTIJu/Rl5ov49hYeYOHXjc+prLNQlXUka/1Xe3kiw+CXGtkuZ5XPthKT++x8lYBTOsdbPncegjAEi
# DATA c9DH9A0xp+YjjmTPpDrt3WwCCQJVGZ7/VunUICtMex3IfK6FcAGsBsrkQf9HWa9jtsseb4LqBa22w3qDIdaCG0Ck+VvWVJc3pDPm
# DATA wn5Z2ZfDDWyni+ouBbZ31RgBiUXszX2RhRH8h8VEORUXJ9QM3T0vJbtZ0S4XERzuvNykBZ/gBwa5ASfbemqbHcTzaoIg/O908ke8
# DATA XNqXe1Qh4n3wAuoLFbIDWZKrUPcAJ8BsQV/w/+r7WGAsxF+gKvBLcNnUV4BfVTqN85G+Rx4Wv2Xsy5+RRE9+gSVz7STXenVmT8E8
# DATA +r1nqOh+sIq9mwQs4lgCzLwl3nbqaJ+OwMw6sOrhNeJ19pyMSswlaLYS0KaW02BSKbOx9+Id7oG7xR1LyRMcrAXWF1v9UQbqUkov
# DATA X7nfWeljPuRmk4IfFOHmYS/pLFwq9sa4AqMy+WfOXoHbH7AA9iENby8f/8hZOe6X9N5SPRbHhXPJGeFMTWnxbbk9ggVoLLyGcQYo
# DATA QLsxLbIuXxLp9bLeU9ig+B3wAa8EWa/UxnKFUCi9N8ciWI+E1NI/vLQAV7Jq29KtiqFhPAcsDbb8P5Mq2bu/I2glxk4WtQJfLsK6
# DATA v2A0XRfWhnR9v8A4P8BA/63VLwdGHhqw/0YLAfi5Y8qHkmyptSvo7Q2qTRsIhYTpvcB6CvcTL8iu6Gh7GbsrNu3huJd27+2NsCjF
# DATA 85bGv+y9RB9MKTjVyAm1CRbWOTcVcaGad12phdfINZ4IXUDRFllSAWoTrJefGZWTZQYIob7x4Og0PhIqTap1CVdQJXgDmBeMUQDX
# DATA VId1E3rpO0n+3JOT78HJ40AwPp1v/pNx9Qd9u1PcKPQ+R+oudXhased7bnLCHNQlfoHyhsTB1N7roZm1dt1FtSc4awEvY25FeJ7P
# DATA Xe86acNsH+LFL97cBd/FyDQk3aHJ5ahXFGLQnSF8JkhjLcgc1bHnKLrhrDo6Y8f98Dz+cHtrc7ezvvmo82jrydrGJtwipIFAjPzp
# DATA 2ub6Y1tMv7FyDaiwKRe2CMFRD71JJG9EiKOB1KnVRgAv6zi04FFjPeiivpyV6r5cg7281l5UO+/OmRLTnn3Qefrsg8cbD/VU6IbQ
# DATA A7wYX+Ki4VX5We4NySHHzMueq83CO/wQdW0o052mL7NGAN3LuGouGfyjwF4NbBxh9gjuGy6os4lJCtamkHlJ9trSOOiZJ9vGWJgU
# DATA u1EUiRyZqVQwujQn1w2OTodZz2kw5NklxTL3i3p4uZK6o6zbT8SCzAn4vPJRCh2E/aUrnJavc7ueB05Vq+JMXbhLzbuycJSfaMiZ
# DATA 0oUPlwb/4JJTgGtH1g4LHSqCUVtLb9/G/IX6KiisyypN+2WdZO8vtvvs76F5CX8luJXo+5CTGpdaKtyFNFkhT1vdA3SYZs9sEaX7
# DATA yJirBdHywA6JlAtHba7zwqQqVPuv1xG00ZiBy04oMXjzBdVDRsZ2JG1JpA000jSVgQ6ig1O1+JDOpqPY95J+e3OLrLfUYUtmtuBh
# DATA 2YLGQOc5bWHFemyLOG+hCqzUI4UbbuseX9kPqODn9bmbP+yX90pA6U0MkSc2x9a2qncrynNt/K8we7QdLbJiBOyBSP+gFAjmkLZv
# DATA HCmC+2YTSIWtaCpv8nbNoXfyMCRztq0hD5XN7Ih9lbfjOsd8lVJZS0gSa7x1TlWpn4ys5illwWOrRLGHahc+1FW2C42gmyfeYdvc
# DATA Uc9tBpuuHoOM4kXqVjYpSA39iQmR6sSrUPeRrLE3bvCnHtnCmZAePNJLuxZDGrruMViZxhmkH1e7p/9SETj8mZS6EwdMGuovxz91
# DATA YUcf3xOJvA86ZRgSIbAG+qSIX2Aq4ug387sqCM6UJINmatUaJeIAl0P9Csa+T8+47VJ+nVBkCjp4ehobin3smCG5VzgG1Kv45Ioy
# DATA wryKriYulM1e6EZWJgjIZdy3cczcy2rPb/ulf3FbYKzX2gv0PxCeS61ahzp64OrauFUPdCIQtfsC7/Ge6V80oX8kS2HA9LDMTRW7
# DATA Urfu09XE7jnBnda6GBLO5y9Gpej+zegxBtITguQs5yzfBKAS59F4dqBGFD3bfhwRTBklL+F4eIKFUTM8yfK8uZh2hOIcIKveJBtQ
# DATA UowhkwDevOQeVRrsx5/NQekpTTlQptflaj1Q4WFvrHiLpI9yR+i60Kyk9bXrTzbXPln73nqH9DRq6siZM6T/wGXRjSQOEImiDAuO
# DATA qGyr84gQu8X8fWnPHv6y2rmnWGjfU4cvdKQC1cClNDSlLRdgRs+hT1H95KrAN2ibXRJkKYSwZFieqbQEbClIYM1HRfoTpuX2g/0i
# DATA v/ZqQ0YCvk8m2p0Do2zHvgmpDDAg0AYw5ojpcJz1JzbMlIViwi14NWV8EMW5z5gO2EhWUw+YOcjnEswP5nHDAI86sVqYFJdCtZLQ
# DATA POuhnk4UTbBxjJ4Hk8xURUGIXrCmjDyWQZtz4xQJA5+DUZy+mEHGeBVh8C/42wmbChUzMEmEqM8QxVnO+0NPv4PQt8CqMu+UY0Vf
# DATA Xb2a5PptlHKUnlKduY0pCrHyu8SPJA+HPfpWPW3eMTG7JPKXG3uM/kbo6BIXboTNaCh444Qw6GoxQ1G4j2YArJH0zYOkWaephls4
# DATA v90PpfbJQ2SZN1whUBaccMcmhLWbNdQhnWQy2rWXjXPz42DWH/Q4SFhdL1CtAubgCgSYG7W9uNFjXD6eJnKBpCrR9wh1oDcoB5EL
# DATA X+pNUIHbls1WUHojJp72zqqiU3V2Y3Zt1d7FNVRCt4qAkBa/u6m6UdsDIO3sVdadTdODAQYZb8RBLG3wt6JgatxZpqXmWO28BLPq
# DATA 6nVADXljTDZCJFDQGaASkHsFvbnriBU+mk3bt1ZWWIFMuQFEB3fMn+tuEoDLeGhIGz15aMhQwOj1r6KPd3ef7jR0mM6bnwZdgGwg
# DATA 4Rcag4WAetm56B9RzQJuSL9WBxGBwvEyx3RJSXtAtiQyLruylyPdEU0iR/N9uiXDkRhkNM9QZ9ZrQLV0X2Y/9CQINsr16ZTd1od6
# DATA DYQP97PAbgq4XlsQy4WZ5IIWDMn4RFAue9ejs/Lbs8GrsbbJCW1xxWYkIYpdm4ikCoMe5gjCcfic4gMaEUUnOXis/N2ywTrAPDN5
# DATA k6Zc5yQN4JpLrqq5IVfBlSaO9kXAgrj4F4ULg3HdteZlqiAAGsTDYFQXC3aaB6AiqN7mbIguSyf9HK5NndELr7qiT4krPFA1dQEN
# DATA xGhAXicsSlBd9++EMGwpAU8A5lccHOk7lVjgX9vVuRKIG8tiz3fbPdEB8Yis6yQOMdlXu7CDStrFCUuhVRwxsKM5TYoAAOekaXe1
# DATA EvbG7ZGLTWKUbfPoQFAIcOQpDKvFU+g2IfGaeQBC5cmh7y+yM4mCe0labKFVRfCPmcdF4tc5oEyr5bUf+T+hcwlwnf/gqOa/+tNq
# DATA L/IFbC0+oBLDy4Xa4gLVqkzdwLW2TxYWdfMt5GNwcJ4xju9n85Cem5FMSq39ethLCJD4jeOeYxa58oFxZK/L0BYXeRi7wNY21AeS
# DATA DckjpH72KTYwNEFh2xmnfc0iC9YXZHP2YZ3woqiwg38zz4Lg6XtIorNJTkryOZUvu03gxDIVpZPxffI5dGsY7fkWCSWne9f/JnmR
# DATA 1JJAeke2909Zw3yup7zlrUA9knPA0RXI4cXjpClc2dUXak5lSYBJlSUuCjeJxQ+7TnlJd3cD8RWYZWezikbMvT/IFHWvUKaqGynP
# DATA JmdwGEJScu3RUHXX9IU6TACKYlNQ/GOxSAt/2LUACBfVVIgtTeZMjZW/yLAn5a66a+C/bFVvV4eRRt16Clob13HWETf3Gc9RioPl
# DATA TfsULVSSqvfkzMKIKwZBr0AOpv+v+Crit3Ym2SBThNdjVqHBaa2LNkI6MryLTtRyGX2wu4mPaHQRRJhj7ac5okUy0yrDhWMdZwha
# DATA oRTVD8Un+aGDseB+Zszv5UBxVJM/UqPw8ibWLxeslhJioQJd9rPEYlk2N6YW9JzgH1eYKvfTt5ssXdc7m67556xK3C5DlFtQGxmQ
# DATA L4wbfFv7+raCt2VGo4OwG7wB6zuxo37DjDxoRED9L1Yn/5BZSyHnq9YPL2fT7jKWWrbu81gm7aXjKeP/eY714fvhgtqG0lxVjjLU
# DATA JKzilAP4oybYk4xsNrITS1fJu5pHUi+4ygYoNo0dXOPADbSw3kVNUJzMi7fXuqJC9M/ibGNR3VKBoVmpyEh7PskNykUhkUf4ny+o
# DATA uSrU1BmkZ6MZBrA4nLzIaxY8kAV+U8ragxcSWJalxZaCxfIP1Pfr+KcixeLK6qgq3ZusSTFjaPlCOWbeEnLM5DYrA/iwR68VBO30
# DATA FiSEV+jBgBiYkAKSULKQS9G7AelBvaDXM3U3eaIvJYs4ZpKvYZ2RTZ6kY3kHmYeJmJhMb5T4FxX7RE5ai+iD+Lpolm3f84kM6Ysc
# DATA PWqruKVTJWgiNbadkRe+pEL5bVncNcPidFhzsCtOngavTp3EJzxGWlKRWsUJP3G5g3pQi5fTcX8ZwI+XCZozJls4tEH7YlmDCI0B
# DATA 8oH82kUy1SYauzr0tua9Q773sZrxgXp3roF+e1naY4RqnNqTkZqI0bDfrYHCfPUmwbWcHgMyc6HAffN5qzz9NSX/wy5RdjP00tKW
# DATA nzuYB1CxKzVzoWzTIrDNXxlXeDP+DSXCtli1grOBmuDwRwej3pmLxqt7ipqwGiTn5BydMFvl+M8edjrUKwACAm9p7+nW4PBWld6z
# DATA JXnX9vPHI3V81sDBCAw7dQySrMCLJt2LVdOgtg2UZGjZ+rnJqkPOwzo36E8h3+hvCekC4ll/h9FyvwRNXECw99aAeZBMEtwEO1yV
# DATA mogQwwkdQYm+k6yYhQpdqxRjVKUiyCkU59GzZxuPmr5cyKlY0d9K0SFqv8uhd7dXbidVZGHxzRcedG1rhxOeyzTozlSoYciswNYm
# DATA nNtQFjyS+SDLxrWbzCjDqlO0b0YcyfhbLz6Zwpi1spRX8yev/1H9/Z9ef8mmUMCdJMiSUFrcYrjkr01mCg3GT2bLtzB/XhNyznz9
# DATA +v9qw69/+eavIOjTz50Bo4sDOtoipyuXu4w19msTvPr5GDACaunkKLcZv+AX0FfO/9zWOurYUz3jZ02yR+Gfjs4Xn4BW0oYEBSrW
# DATA vYwDHTfVV1dhps2x9tAGWbAKMPw0iJkLs7W1holqaOYQas/kPpnkyEF1IvXm2uRoBtvnKb6pCfm23en0Rt1OJxFfNsEzMOVParHp
# DATA WQwODiPw+2jvacuQMQxp2HppvdemezEaTLh7ODLoWKEG1U0RwO/qiLzcfko5BxWnV2JcT5oXw99aScXprpMjsB4Saqu7pCSwhpE6
# DATA bb2Lxs5UVw6Xw8YJ9czWXYawu0Bd6JuS3Csrw/C0XKyqNnVX1xfZGLJ74p6J6QI+VUvh2e90qNdR1uijeG7xSWG3xp5hga0GTiK2
# DATA YDdAqLRBD7D70SMXy+I/UDqvJQ7FGI5cMMKad9CA5OptDPyQSEYlXjc3mREZdqbHReBGnJ4AAje3F4l9GlEjFcROd1ICJPbBH5ZB
# DATA 1fETumO6Y+DftAj8g6+e/MtGifEDg8Ygf1MwMP6WyMZFhHXMCOzNfVJO6igMTZMPSTIkKRHkQ8JCkErrsDucDhwW5tiEPXpbmpYY
# DATA NUboAkYZumqx4tiqKwlnKH64vb62q/MRbz/6ZNvPTVynzEi2GZ0Y/LCHDcgkufFpjFcDaMEVgHA0zUN4UYP/1PnJ462H3+2sf+qK
# DATA nS63DISD0i5BCb83OxnnkvDP3TRaRQHJynPwxE7zbr/fZn9KMEcNp+2bCTAgtbAddJ3rdHC/djqw3zqd2Pqh5v2j4ewEFxz+TAfN
# DATA nY2Pdte3n9Qj+/vjZ0+llxY9p39qVIFJyXejo6756NrXn9b05cQRdIgjSrmkJsVRI6N+NzsjUTQglZP4tXOmqPDJ+qv+VNhrPVy0
# DATA jCqraQHpITuw4z7nljwxLtFhc6//zoqq5jJi5NaCy0TQfW+Oyx6i9PwE86qD9Pu5BgT5FaZZ/wIh976xyP9O0smPDtRRGZ994yv7
# DATA HySsv3v7Nv6r/uf9e+vW7ffv6mf8/P337979RrTyja/hfzPwkFVNfuNf5/++eW15lk+WD/rD5Wz4MhqfKdYxvLV0/fr17SztqS2O
# DATA 20NdS9eebhBcEfov42U1j6bHk9Hs6DgUM6TKN1UtS0zWteiqf4MpBQ4WHNLeVD9Vt1W8MvJPdXM5VndM/RMIn/57lC+hfwXcPVQR
# DATA zT1AuNRFJqYxRVj0n9Cm/lveYL1nTl9d5ZR5Ouv3qA9MI3Qf8C6lCJu6ICpa2h2oAUXGhEgXPnObMhK+GjRfPU0aYNb9K0Z5MobE
# DATA Kv2eeiFznpC3BfI8jqqx/tlL0qOxOp8xhpIq0ptPe/1hs5+n0+lZregT5o4gfkJ+j5GI51HVTvrglU3i42iI6Z1Swis+0d+3Ilf4
# DATA 4y7x0jf53xoNG8kyjZyIa384nk31SzO9m6PtjLTCviYRdAn6HSsUeWgUfkFvOly8BiI6Xk4Uox6Dhh/kppP8SE2/Og5qy9chuZtq
# DATA Y+78QMOmfvXHDzD3/D04OHhcDim6BlU6ENFkB7M27tsedjr9YX/a6XDPSB85eqE2QuwAlVj9Kt0QTXgZ9NXxZ+b8zton8JwUvQY3
# DATA 4MJokmw8Gpib3JTXbsJrygpNf+qs0EEnOW+OnqlnqZ0DFLFGs6lMhV2PTN265jg8nnZbozqgpt723gx09eb7zRX1/1ZhsJhBGMrA
# DATA j1ZrNb5YpMfb2cloyrQu15dYcsinpU0jSk28s/NxNJ0NYWRwGKBELCNqBodNXEv8CxeUVtBkdV4GURVfuF/xPkRvr08bH44mp+mk
# DATA l/UaTycjcLCL7HLKt+oveGdn4ILmziZ1WGCCGC78wu3QQvp9cUBBwrTnTx47g8qAGgLQFbPzK6R/04Iq+1s7gVGYMEbMC/gkjjHC
# DATA UUQqLrPrzo0bch4vHKRRsxjuXuCye/EaJXv8EQeGg07tg0zd2CZI0+znfk5Z37cUdfWluQj5o5p/oNm9FT5GugjTQmsirgT4Nmly
# DATA 2SQ8joeUhLixy3Cq7kS9apyenmLOvYZplfCMbYvFmXWs05BwW1Fo2FYTCBKs3RKAJXBSP1rfZQPiarKAV6jaKMUdti12D8wPGKpw
# DATA 68AEtuE/hmy3Dfl2EECKan+85Yl9TbdJZAjaDHR7nh3IzXbtWmFu3dQ2GGGKKbPEAPYrV5REDyL/23kGEp94gQinewM5SNXda3KU
# DATA lTg1MVt2kjtST0Ius5eyixifKZIgggaNKsOYe5xkjd7+8moGGnf75rfr0Z2Vm/CfW/Cf2xdYTG/Y+9HNcNPSeqFoiP4gKV39QqD2
# DATA vIXBzRwdpv1B1mshx4i0s6gdRCJjtQILUQuaZerRLm3ekJGmYvJ+77OiPhlmqKTkibkHljLwEThRRbvR062dXdgV6F3nB7FB59Tt
# DATA 7mRMITXW/lDM1VzD4PFDtdGnTkI3nXK9N23qGwtC0XlV16EAPPuRar05m3ZD2pvSyvr5iBKcUmVNnWs+/j6w3vdWVlorK56DPdXV
# DATA nP4IlO/hMCXTHJfVtdI37WCHnZzszTTXJWp+6abtc2L7y11Vnf6+MKUNX2YTJYfm4C+b/3CW9kCmG01TSv4I6Bhpf0iqduNGCzc/
# DATA h8VzbkeohYzGWhwV6Ap8l5moWZ0NBghOXZvEe2uN76eNH600vt1p7J/fqt+6exFTMu25MvwzLfL2Rhkx68P+FKX3nsX5jmgevI05
# DATA ydSHGFwjcr52TtIxCih0JwIBZe3h7sb31lGzrm5e6u4EfjLxo42dtQ8erz9COax/ou6T+PjxxpONXXqavRqD+QSern/6dGObno6G
# DATA nWPKHmSrMPl87Nyxx4YBz7e9mzsjwxfD0elQ6wUiXdMSIVGcACChaqeHiZNp0dkbSXHjDhYg2LGVpO6VgM8600l6eNjv6jJyWVei
# DATA +21qAv749srK+6vf/vbNO7ffv73y7W+v6lsLlsIeBArNG93GEL08I+6F2rszuMHmZhHBn/boDGWzwMg6sHunHV2MBhEPR/Q8Tpqz
# DATA 8VjJwhYSS9dnbiibW53t9R1FfdVaPlr7DP75ZH39u/Dvk63N3Y/hj8/W17blZaVsoXLV2mgCPsnYfGS7RW4y6QQOHQbM7xd6BFwA
# DATA G5LWSjN62897ph6N5o2fRQdZdwTR+KagPAacu4h23B7M5J7ekvv7crfax9ghs7utTt5vfGuz8/HW40dQ/1ke6TNwDw1dL+m4Al/r
# DATA sSLX3OAgD1N2aumIJVBkRDY0inIywmpLKI3vZ5ORYqDpMI8gLBQPLGNpSFLRjNZfHaezHB3Fu11Ku3CifkfUQMQHvOlccGEzP2j7
# DATA jZoDp2Zz1XcX4XnGPWUpjCYfF+FAIlwYU6jCT5mabdA5c+5Peotck3vEc7Hyl2xbzy1NeoSpsfXH9yxyTHQ4m85wqYZghsoj9DO1
# DATA eiV5vQ5tVWu0gm5X7KFnOTjmUNIWJdBEP1KLe0/Jy1N1racunqRnkWp1SLwgHSDoQZSPQeDXtCM9Qu/LJYcVn1u21WLnYL3FdYpr
# DATA Q9vX4AJr5Qw6D/QqprwTlgbxY22AuKmIXWP1ZuPW6u7NW60731b/9/0ChkTMPX0Mq/kBhEmq9piEO+92NOFomYkFJwFkYRtAH4fp
# DATA YAf4OmIBgbiKWfPAj6mG/D5JCihXsbBcgcuxGYkihQxMGYc4F2mfe510GhfEtD39dg2dGgtzJ74Vubz6iBliW+BnscwWMhPEtA0e
# DATA 4TUulUQNtaYvBxABibM2+gEZxfPjtDc6hQjJXAzDVnMZ8j0GzU53NGiJs8AiF2pdGZGHtM8ynTh/p6QuTC5S1zG2EHdYs70mwz7+
# DATA fKYWDvRONTEUremzA3yqn2BJOVSveJ7boi6qgu6bZn08n378hndf0ApvLr2nayE3Nxpl4ucZCEQWVmu0Td+sGtJVOYrcXHbW3BZ0
# DATA T93TQNcQGQLCffwWyjbqtk8l4Netm4v0+anuq9HHOqKqFFM5gEX9iaLqJONUbC7p5KNEQ4RTVDAVFJYq3LPNUVTcwlKzK/OHCKnf
# DATA QX4p12pbWVb4/XTUe008kibCVQp1qobBU3/uNVb3/X1SeW1YvVu/exvuDaq5ZJGFkXHGpMbV+r40yo/BTAQ7gnTGg+wo7Z4FnEN5
# DATA AovLE2MVuO8wOHJ2ULy+1Q1nMy5lmK2Hb2Jgmxn2sh6P5pvRQ7M0kRKK1GaZoopSO2pF2Us1htPjjOo/Qc0NcuAUQKDACwgkGL6Q
# DATA 4/2RKFE/G/RQynSubPbgFMmKSzmQmurRWn5ZDzGwMs61b4giQ1BTrxySxG/0vJAVQW8zcDMEqUa/RTxs/76Nk4+XVgPuHGTfwJ+w
# DATA Nvva1CuLFMx2tm41Of2jIbKj81zNLO0EV7WRO7kIc3LbQMguc3iCTBzROS/khgKOZ3sY/GgfiZbulo270eSnA43W0nHfuXprMqme
# DATA a61uDbVPEFgHAQZoZl4+OGvovYPhCA5NAJHMxEmlhxkYxqyZQAKdWNOn9EE3VtJiXnehS1LLovZgh3gMjUMk1zyAo6VDTHLUM6O8
# DATA CPYdtOxACl6yZcBcWh49OjzMM6EmX6lHq+QF4VaqAbbmztV3qMa21hzSTwQU+iMU7swbqt5lbCjjhkFv8BWhZu7F+MvN0ua8wM2N
# DATA XxRjAKCgVeEgKg2keViMquL0s/OBhiFVlzk0ROMK3SNtoH6YRojeF6l7d3/Ui70QOvCqZfjRPe7NfjEks6hySggzzTcTlff70YyM
# DATA JRmLYtQ0RvHliGMGfTB547z4w2wI7pO1UD+SezQX+u4CPxI/kyKWwBBiXBK3zwdKKH7hs0JnQqCbopoHoVrK1Cna608Pm9bIcn5R
# DATA 77VC98KVrmMVfAcFpXcGxinWaaAXuwOxzf5NDWpZh++f8+Ba+rTyxm1RHy4cioFFNC7abOj5smNcGrlBzqbj2bQsn12ZPZm8YUyX
# DATA URsAa3AAtmRVz8EIvGmgtrgkUbHTuKJro8FLbfgzZRlPQuYnr0fo46yBq+qRDzbRPxTfy0Ghb+3wrCbeKl4A9SeLqFTVuNQNPgI7
# DATA wRlcZJwJ0EFjebN7rDpUE0RWdI23Uxt8JWj89KRjvB2k5CuKORwJ7O/C3YaAZh8+29ntrD3d6OxufXd9E4jrtk7ciD5QZB6OTEI2
# DATA rSJuO1U9Wdv+/gdrm51nO+vbm2tPUP2idaZpTwlPqgbj0iOS0RkxPlzd07WdnU+2th/J6vQn0CcxOcapgH8algESmuEZ2JdlLGqO
# DATA Basn9J/yTtcyrV2wVR75K8gEELrdoYqIL+DVP8e4WasACzKuPosSDfoEoCwse96L+56kIS8jsA2t/NNua59m+qKDFVrBh+pP5quB
# DATA 6XMqb29UeF6gnp7M8mmZvhqrKyboe7fYxNg/ZL2dvP8jAaxWJ0tlzsLCnhVZNZvCNiqCF8fpGRhq61K161pfApPDD62+U3sL6zuZ
# DATA ulvAtcy3+lJ0hLu6JOOJB3XdJyH77xcAlE1lUv7SsGv60qILmSqThXmvoAQ4lQT7RZb+Xv/wMEOYL7oR3MNGR2rOgJcoidfjxuhW
# DATA bpJXc1fwWPDcx3ry1UP9pwwnaQWHK3CqtR3XHYYbeqddnOsROHCUejtjdbipbJe9A+4LFJQ5G1MoRfN8o90eat2jtqEwiaZpjS9K
# DATA GbRETrZsmU5ETL2HScM/1BPcqJirseXv3Aut1AO70iELCq3o3AoZFyAdpr0z9VDdYDGmcrZ3XS/IdUpwNNOoClBc63YpPUVXiSf0
# DATA 6ZzPQFGn2PY05+ap+8lFLLuIyhv0CmSyQekwVBUtY/i3uWsMT6a65tGwp5NM9eDoeGrs5pIjqvs6Cc/NaBstH5FdBjdwpTc56yih
# DATA x49BiB+p1VPPTSAcGeaJDBaPjhvaboJKzhRhhTGTU2f8ULoWozF/eqwOCXTtO7jTI/UBsDm0L5yBwtrv1kPYoIPy8UIMlegMSx+g
# DATA mGftMKiw91EpyguuH9A04i+bDgaRIXjd5UUNiQHYQCmvEJOJ/XvajB0gi+V03SIdVtNa61IbQDEMXupK3a08CapEeKDDailyoRqm
# DATA Ze7eDLf2zWjN+iaBfUXJv4ORYresY4oMFgl5oKMjMeB0DLt9gIFGnOzoQAmovcEZ3QGbwYackOS3n+LwNOtrr+Ze/LqKeZUf5Yc8
# DATA XtJmQ7hvH/b3JIPzNzbnfDqy8xGMZ4etbqwgNv1ycUyolr5E13XV9sxUVh5ymZvPuvVtX7GhbmaHjWRH82sHXim090qYpB4An/H9
# DATA ILtkWTjAHgX3DjA4VoYyi6OmSrnhzsdrN+/c3Xn2ZAf9Wii1FYdBNPPjVL2sjT1k0+PsVa9/BMcT1TwRMo8x5UVUv58PYzIHoQSM
# DATA +nhxczsajA5q8Q0m/Uni8lCiyD3mYjxN13kLXd8HVic5oyxknlMx7dbmlKGHUMByHX8t5jK6dII6azJ/3YvEdKNeKcemZ+oxWN9Z
# DATA 9GI+pSQ/OqajHh6qOBh9faXA62IYL8pD4FAb+9HP9wLFBdkJflPSinuVWqgl0hws2gBeXRpwddHx3Og5pyYtVdPeXlU39FAjKKUV
# DATA I6Kl75fWHdrKxOuy7ijxpEF4ZKFQ5lBPztBMUBr4XPxA34QafBOq+loHMgdjmGGnraKW3L0DwqM7KytCftDxyHayW9Hqf//J/3IH
# DATA /ADpvmlsioE7nUlVwoGkcwM658VZXvIuIoIx0X34j3e2Nh8h/HLpVYUIztVuHOapITKYtoGkSpQvQW9DXnpNYeYSBACbV9IwIHuq
# DATA KtocDqWaTcpjR1cXDLH8F/0/PzXG1x//+f6tlZWbbvzn6urqrVt/iP/8/cZ/bp0Oo9FQCdNTBDHqZdHRLJ30IrRX3IteZNkYo5zg
# DATA gCkegigC6JdyZn2gXqoDCcWDkaB4w+O0UiKEk58QEoGJy1RHcTjSP/pjTjr39pGhx4Pslf0xm/YH5tc0NbGeNseLiSPNTsZAKpaW
# DATA dsHFMNJp/kBPTHBvOFvx0vbW1q7W1BNYqCnXQOQ4A8eRLD1a/3Dt2ePdztYnm+vbHf4yXh6Np/ajeOnZ5oZXY45Eqcf/ljXQ1MhP
# DATA ydLDrc3d7a3HnafbWwCe59Y2Ozxdlhnemj2/RliiyQh6vLOxu37VWnIS2J+sfdqBzzsffLa7vgPejDbCxbyE50r2xbF3dtc/xYmJ
# DATA 471nw/50f+mREMOsth73LKuhcDGW1uAu2R5m09PR5AUw9ia78vQAyn6iJ2jpA/Soap8oIaSPlmcut7THifH2l4DZtdVND3K6La2/
# DATA yro74C/YNoeJD1JUteLL2CtFdDUE6hL5QmI3gcW0lbCytLdBAK77S5+kwKQ+OAt0TM2FXov1Dzc+hdnZszOxCTOBQYr7zyHL6gCy
# DATA SuhHigsewFI8H0pplrANejSJpgRs/bwdC2PYDRAx3ERJGH3loGmSE4GbyIm+Qx7NoVpw6rmKbjoGX88Oyab0sCJPJrWO/5V5mrQ0
# DATA zwvuRIEYl0xDS5r9cccpiamg+t2ptM/Y0Au4gfZfDTJEdFmJEFobX/TzDq5PN82n7uMZ5prEm4Z/q5FYdmsRF+tyaOzGU6hHzd8w
# DATA m0qXnNgxU1Lqd2grMcnl1JKC0U9VogaTHyPIi5r1g0m/py6M9QhjRfFpe8WEohNMpJ4K/M2yMXyNFiW8RIIng6k0iX4cnd+8eeGY
# DATA dvnNg+jubW0zhCtDbZxo5Xef0mca0XgM/7l7586tO/bOSrVUzZjWOQM7wtKuhZmHCx1Zvfkt3ZNqn69mC7y+6qt3wOnrgFLzHkBv
# DATA dGWL9OcRkhX+RHtmpif9AXom98d3MagybsXkhWCxM/vj2LVzHsbn9OFFlMN+jc6x+AW4kUOoK4vx5Frejmpxv3+ICoBz1AbA9Yp0
# DATA CTJSVIxKLKkeIGWhikwTKJPzS50f3Pg5warazRRaXgzMsEXMOi8yj0SnhOsAEyScmGl3HPWwynNbvek14gfYVmW/+dwcKtpJPhh9
# DATA OF/nyM8vovPzJfDVUfWcEHSreoLjxGIdZhX3osNBqu58THTuRRcXSxGmBefrB1RDnylpATSZx6ORvpqoW8doAm52jdUVdVUFQ/8Z
# DATA 9/ue+kov4fXB6Do/Vk+7U4MnTZPTm4zG6vk57RXQTYsZOY/O7dqfpGO4YtX5RCUXqre2YvvVv7VjNm/PecovZBcydF7p58dZr67T
# DATA +Xa1MZ/CK0AcNJWcZNM0GtxGb1BFeF/ebfS7J+qMq/+8vEuzpHo87DWGWf/o+GA0aeQwKeCRLh+mPbBp4rOJmvRMP4HhqEOlpnhM
# DATA 7iE379y5bOOO3mU4yVK1mJhncJxCtpvGdDRqHPSPiM00tP8J5pJWawV9UQ2oD06cuaU1snvjkALzS3aHfjtnfyywE668UudMSy5k
# DATA 59X/gZxhoB27oHc1ajJmDsAElth7W4duFiBKYkWpO0oI3Vx/uLuxtUkxfOyf65BuWwk6MN0mCBrzEPx4FWft9Y/gQ6FOgM6g1xSo
# DATA FdzyIWwpoIOILAyOeEo4iVGOy0GQUxyOUnLuQg+nPbXhqKNQPpyg2uEpeKKe996LMdFxMHGm01kopGdiz/S2gMRannXS8RhkW4cm
# DATA 2zbWCz0zcKgk+1KuUWT5GHTIaP60LTE8cdJXq91mXgYvf+hNiF25vnStlXYyCU5c2jan5AaoBlWRbsObOMoKlrONjTbVFmd1kqEb
# DATA 1s8NZ0Br9vlzA3Pf5BsAd6NJxZvs7edlcPL+p4exgsyGTH6baNNDXRvPGLOegwliH1KpjV68v9davalXWUtyxIyJShtpzQh1lPca
# DATA WZaaxYGRRYRTBk7u8HBK8aME4YEf0Pxm8AD5nJbcXRFX19SkDmHwPCZyKas2j92KxIc+f98msCRt20qHJCfgkkeqbqpOn9F0mKea
# DATA htQO416G3oRFdv2cYOpDHUfxnPk+iDQ4ZUZDqofT6OJ/D/G/MV9iRPtJ8YuKspzRD9joaX/YG53WAEaC/zYe92vIRHpm1KqXFNHT
# DATA HYwgCA497tWoHiredjBCSQp0MYDJEvGJj7qTVBH1vGluJ1db+eCCVVW30IpfbdXFSVCTtDmKRqfg6U7apz44cuF9GGyg6sZInlr6
# DATA Sp0rftcHeFDAoKyclBynwpuS2Eg+8WLzg95CdmlDEQEiTPTZ+GiS4lmKKIUTjwkdCMBRTAMg0SFHJ6FpTjs20mnjmhK8uWw31lwU
# DATA SsgmE5GjuRBxLy3aPhcoL1SvWgsQvKCHbt0k4VbIlLKupHi66KRjpDsdijmLFaOc+y0EH7iIw2QtuFCyUTVLV2uR5wj+XL1zQn3Q
# DATA VEBCa7NegT1tAV7U+BFjtFKV67C8GG1nhzPCTom4vL5d9uqomhxNUnQQ1mrK5skLUA2OwfLbxqbIFRghFw77r9pxE/diIwQx7iGf
# DATA HvYs4inU7SGeQms0ZtK3mLfGp9d0kGbCKWFQKmwZCy+OmGmDM+cEjnIK9OJknuY7X17IdcJeW0InpQVEXM5uaa+KCLyHxqArKDXt
# DATA sn7dN2PVQ9DQoCa7eXrcVzJorJ65CBnqQWnObRp0wd9bP6dtU3jNgYFeEXQJD3wNdKwGgl1npsZwDa8HShLL1K855TEi/4+ildHK
# DATA zZtV8/NsCKFA0bMPP4nEeul6ZeghNaRTwQozqLouMhCXLkTd8Mk/PG3udDZ2ttc/qumvdF9xNPJhyYD974pjfItx0hH/qnXCKGVT
# DATA KLKdMvRUAcUuJd71p5s8Hp3phRkwVvHVm15u3rI6ajoI2vW/cu9i6pu8m4L+EScEhcF4b6XxbdD03blYVtzqObgSUF1JJQWGGeee
# DATA YP6O2fCEZ4cclfIQIXV0UR4sAnEJqlFTZXYCleTjvSjmfiZ+rq+aOtaE3g8MaDbW2epCa17+NSRhWeAr9BGzkx4GsrPVirTzlrMv
# DATA 2haH6uOqMxFfJD+F08Fi5ypP/1cwgtJRhL3ivA3Be/IdrbnM0cHGPJPfmawFbCm4Eg805kHwKToZvcwcJKercihGCm9ZYnA5UwUr
# DATA PQveOMJQoX7d/FoMFUhBeZp8i8X//ziwGajDlQyvMOup7kQdvaZVFP9fGpP23yH7egDc6xLsOzxJ85iq8NpSLA7B3hzt43Of4z+k
# DATA Zp67TJ8bd9n9U1wKNkHVgE+mjcO1xofN1vL+e4lm/DXLQGvfadXtr+Q7ic9R/VXBXs6do+LkVHJcfydp6oCNgUbVxdED+kQihP3o
# DATA WptpC9y5iYKA7QQ9Hamam/saTaIOXrP4hXf6Fx/NQTYYQbjWdKQ6MpoeY7gX6jhkiJmiuSDChdcztpC66ipuAs8C5NdhHDdqewHG
# DATA ti9mBsWvPcgQa5kduNfEFlUmno6QFw7PYsOK1H8TgfKL3g3y4M5lvjgM5kU8Cjel9hzu7nFahgPQwa5fGeM143bGYXZWWCak8RWk
# DATA k3nSVbH6kqmaK3242CHoiSJv2OZcoKtX4ZS0li7dI2+OD+O9czVzF5clSmwEN3cQtHSXGDuDkvOCC2k340J50fR298StwCyzBDbI
# DATA 0uFs3BljcmZCMNYO+s7ZhXfay8pJPUdB+6RASg/y0WCmppeAcJpN9i4gnc80r2Dah5ohcY/wqxZM8/T4QiBLddVGwGTYCCV1YwKx
# DATA N3lG6fBYYgDDBfzcrwhYRezStq2tOfCYN88zpLzdHE0/BA/DQAhRASaKAfCQ3z/e/G4N2jG8fg6BLkwBC1lqFkw/LyQcFMpYJiDf
# DATA zgyeDtCbTexiyh6aXrGwsRKyMjldN+KGjo2tFVvDaDrZJQqvcyoxc/O93U+TJNysX4UjQz3a2HbnNFwJ4X54FdUK0phTE0yXfoBU
# DATA Cka2Kp+ycOV6DSbJpdcVOa9cnNAK83GFqfXOKoJ501klWBWvQ86BLRzwAB8IZ7HCBjhH1dbm48/8LFX29+YHkFPKoU8V58YH0q5K
# DATA bjU5COl6+fDCN3hqkbPAf4ajWlItf5euuDgKUXDnL7o7AliZi+0Ij9gJNH4jedfIt8TBbWdvBSiaLNz8Q7kTDRy71wNeKLxa9DCG
# DATA Qt2Wp4eNb1mAZd5c3eP+oDfhTcP7r5KzWJYsOUhRHOMusOeAbsb6Eui9k+PxmVD7GOOh+LeDFAe8Ax4i0FbhrXT74EYSAD41PsBl
# DATA YYPOrO6qiVQXgzNnWfPAuprBaI6KPWu6yUwLk4hfyFmkr/iqfTgCGVlfzHNm3oE2J5mBEcDfzmLrEr54oAQZH8kctRQMGlhiWSBs
# DATA q8sYFQz3t2YFJ2+Q2y00StZCGw4c2MMbjs+UQ0zR3X2Z8N0yHS65evfWt25bOBr4rCDu+7QMOjdO+5Mc08XnITh34RzCoHB1jQE2
# DATA RN+M4rZkeDiqYoGdKDCfyMpLjliIh+BrXwnUDyDlHMDFAqSfwVDO3ETf5D89OoAcQx0cegccydr4p3PEJTzcFLPoIkTcIrtCjMJ3
# DATA PFaPeFOgqZ5E/xr8PelARkK7X9Febp5XNUuC/kANQ+1E9njOo0YDv6aEsgwVdErpZ0BT7mw/PNSiE00rGRd2pcVNSpxJ9jb5khAv
# DATA HWMDbVr0JsIWt7F/qESCn4XN6rqgahUF1qJz2+4nBkVvmnaPO4x7LEaE6llY86vM7zZVx7VXznBx73C76CGfhI0t8R55Uu/vWRTN
# DATA lfrdmxex3+3qbcfD1t94i/4OFpyUK13EZaBql8nQH6s/uFXaEygSQTQwFMbIbtW1Zn4cF6U5o7NzSBzV4FA1FtWeDfsmPrIAaqGX
# DATA ijugA1J7LakDo+QspZgbZboSUQodGlWXqah0coRYL8WqchkZrDtBOqnFO6g7VAM+j9XjMbkVsQtmvte6ifiBe7EXm3aQ5sfPh+y7
# DATA EzWy2fMhotM5tBQ2IlUDKjrE8Ab5BCCys24Um81qysC4qARoBpJASl4aS3BiAZQCbjVtU9/enZbGlnU2BCJjoUUCIs5Yecif26rV
# DATA K6JlVAj+qwuBIiPvv+IAmfFs2J3OCKaie5xO8nZ8749+fP9BLYm92sDEMs3yMfgMYquqeqjDKwWtZJjsACOrnJsquEzVsBjD9OFQ
# DATA 2E7in3ruxj44vGLJee6TLsqk+sBZtm8ynu+/QS0GYZrB73/v/F60fujwaAIyVwp5CWFA9yGtEio19DNTMcVHMHgvP8v9m2bpNvG2
# DATA Ch90S+IuudPYB5D4nKFT6towyJf5JZ4U/tuSbuo2nqq2OlX8vs7kywFYsM0Zl4G92A9pQz+zjRhpf02TwtnhaUdHsyGKlMn5brpL
# DATA T8E1y++B31O0yJGJHikB/X25+QL5h5LBYQR/A34zaIfuM/zbgOsukHDqnTpi09Ki6JWJZTU4rk5cEJpWGtSwl8EsihHRlem4jw5z
# DATA 8PY+vuXN1XLhWHE+sNg+7EAaFKl04NP3wBYpP8d38jMoguuOn+45NfpQp1S+Hd2sUI6bMevbi1NjEq5wVS9wBTOEdSbGU+0w7LEa
# DATA DwOWhBkHDVQ3E+YmhpMQewCHCyS9qEI2g00YR8XBoGTmvIXOqRO3W9QP9RwjkU1G+dMJzNoEV0nzRVyYwmUeT4wW0aXEl4775AnS
# DATA +uqE3+kEYl16HVt5SLg1p9YpHbRWFEoV5WIf5Vot2EczCoIxwoRpHNCdkeGIpB6m4mIQdRhHGxKiEPD6UbAhAChnQd8Ix34otkZK
# DATA 40UxNwI8hv68BG+tV+5KOgTUOIyOQnwLvKzrDsVsO3mKrgU6xVPmBcjopd1zixeQ8aXgT24hCNisgYFNlKfxnXA0FuOEXPA9Nwn9
# DATA tXDNgNWzFc6zpIpkTTDPkTMGRzUnl8cBmKxRU5TqThfSGSlML1FlHSgImsqC3nnOFtYrZUFFyXAfHETZGEK53rBZkg2ZJNFW4qUA
# DATA 2Ekl3MgjBO3esx0aEbpavBSssxaqNK48/sg9SgQzd7ubPjLwD59lcYiwm3TiL0l3fm/zVroF5BKbHJjIJ+jinXeVTKIVLUvFXoan
# DATA zqVMCNxxD2y1TDbAYWI48raXp14ka2yuuY7wOtQh8yejlwCbYzS/hNUlHnBQrsPnJUREHZxi9MV3TNiXbVfBKZgN9gD6Cow3SRzF
# DATA iwvUb/tqNDT9aVa6KUzbsMWoz+1Iwidw1k0uJm3HBXEIp0RLQ95ga/McBJOkUtbiyEDOS8W+3uw0InaUGY6WKeC7ZZ2BttcXSLpx
# DATA UYVVnCHtn+ItpAcaItZSi3f8XanHgsN1dOyd2JGYecLDNHadeHwNmYs2SdPQsf2vxSX+TyWeBvHci+RhfAlvhLm1Fb0VnNi/pNzf
# DATA FxxoDEsyA24XJiGE1ujt2cK61gquPuzLEfL0KXNISpKFcB+9Pf7Qc40Su1yzAprtZfyucpMb1TmNV2Mv5j7dG6TDUpqniWJd0LoF
# DATA COaSjoTx0ysKtXFBFOSGCk06hhVj5QPBlo0pk9G4j7olQMdpgt4Esd5q+FPDQDZ7MjUY2KWVkFOoleuSLpZhx0IIIj9rOF6BDfAK
# DATA bAL0cUy+H00X/VM6/UXcCeOjOs+lA3zftAdfuUcJQ7n4sC78Z60/trlqG4iLQKgW6gcafsbETfrjggtKSG1T5ntia0MZU/cDfGQg
# DATA NuMahLGDyXoMf6KWgUqIRLpNCuZL5k0LroIaLdvODnlZzvvjiybEtC0V05E7JB2L16PbK9++K4dsOPNhbBCPng8NytHTUc5IRxgh
# DATA rxqKGofVSEduvyShLeKh+BOmqNpdDxdFO2UBiZ9URCHWvtPCQMQfM6RCEvkwKjYoRK36RVRkABOJMHL79i0OX4xYYRpdn3Qb3VRV
# DATA oYbr1dZQxa87lBsMcoo2v0wn/RRXozY3hFJtE+4qz8tF5PanimcdxgYBApNXsX2X0tpWjkStVLH7mPu3Y/cSnCJ9X+Ltrl/6Vy2H
# DATA fMRqXWIOxQbalJyv1tEwpFPM+03aCQtsDgKFAAox7zg5PWy3veVwkoHJZt1D6E+Co0zvBz2E8HxJ7owdcSoqBlHmTYhuVkxxjyrB
# DATA I1TMnlDR0wCDBaeXk3QCfBQ8kYl+ILdHvmD2WAt2lq+GyI/VJHcpdvsgM1DU8SWE2EMlLkCTxBurDEXUH7UNdWDjsF8gX8DgfB8B
# DATA Kke8EJHihPsJzir3BN4nIicsfBYUXH0RBSDnIl84KTPEHWeDsWOodFwdrMZc957Ll11cavTetZAEERyfD78CCEcgBlC4sMuuV4Mg
# DATA qs6g+poGF6zgEjCJTm1J6ODwUpVM84K3LersAmscbFN4sTjSaKmQt7T0bz3kSymkDkZdExLOCJSH3eF0QIZb9bLDroa6fXgWF11y
# DATA TFGTJanodGjKsOfhw+31tV3taLj96JPteU6IoCa/q9XkrrO75zRo2/99ewy67puXdR2EKQNscz1z0s8M16l5iCso/SrpOcxXZ/1T
# DATA W/wMHITC0e4QQA82KGfawkqcDrndaxf73PUQ0U+Dpr8rxOeVQ3xwFIk+OCJqNm9hS30I5DFExrui1LVUFOpxZWTmDfhQyl3qqmHC
# DATA HmjKFMWnIJtayL7SpmyNAYDES3nZaB/PKveaK9ttlir020KbI7Vrxny0VHjlX18v4wJ1CZUrm802R9KhrKhmLYoZ96xL/ou+IrZF
# DATA LzoHbaVTr768w63fX+OkOGll58n30bmnQfb2CkMbFdXKZgiwU6lv+0nQjo0f122imsUNhP5m7fkGdJmKwvc2qNaNWLffEH+at3mq
# DATA N1DFHqmayMq98JaTWD6R5ZMZ6EUZ6/d3Zcl8u2FzuQ3LKFLqhRGYrkaeuSeoXiqL3hvWYkKj7k4HSJn7uUahaiiBDpWL83GqhXAm
# DATA QM/i+CoHVeq9wOm1CbrNF9lZXpMcMsQxSoMHA8NMVfPDhrpXQcInt3EbCKN6UJunq6t7HQrmabJ5XCYnqEZbCqRfYszAktw3MqtY
# DATA E1HW9Y2+hr+a65tb65u79cj82l1/8nT3M/Ng/dONnd2qhEblpJIOgGd5owVU5J4iYY3zBKFgmZQNOqGXS0EZeA3Qv3T0qGThdYN2
# DATA QDp6YgD25EvY6gp0ATVfIGcXYvBR+neASSotAFS8EIqPwqz3Ssq0c4BJSDKlufTTqmKtlArWZnv1EsEa/86X/dEs7wTczYOXHBmV
# DATA jkrVcCkzOajQOzdQoXZRMNBdNl5mKBImJ/5Su19g3c4r6yyD61zShvVuQUDSSLuV0DdO7aBoKshqnh+Ni7YNycUMZuqS1mAiDKeD
# DATA 012O0e2uzFvCPAKBQ+tE4ZZcj4KhGECh9gsWBKzGjesuBzJbYMcK7IMRhuacUwwq1uqjCcl4JQsUVOyf9tejfD3WPFhAFPEjs509
# DATA 5OsL/NrCQCpOFX4EdGDucVN1OjAPnY57qko+dlZJ4Hufs5m0Zcx3eX5M56eld5mwsbciCX7mnreWOwz12h6VljgjF4VOkorOKOOu
# DATA wjuLJbOh3uRXFSEIN1U65gYCuQss11tzwW4Ld3X3Gmu04gj82MQIoxDcEG+5yoSNC0sn1ZZXEYYvu+hLsHLSNOVhRF6SRvlRGeCq
# DATA r65Ww99DSlI+wErhcd6CByjdojuu5FOJleTkhcMUcFdKDofvvURjBB3rZEdDMYYGjfuOx684CEIVaP1FzMex16DzjnoQ8D9tsFcq
# DATA fQc8Jq4Lt2fzA5VKGFfRn4pGDI7TfkW3G9xoZREkLI0xefIUk8atVH6s7mL+p5DYLVy4P0QlduGDqgYKCpmygToRSDrVG5UN5XvD
# DATA zGwavbhtlqB4DUfuT1m3iVDv3byJKcA5F7eQAMrCexyoIpAhW+V5y+Jtlma8PCKBLsttJWHFSTKWwX74pZCFXImggBLCLvxWpC4O
# DATA ye+Lt6dl5LwTH+f1xOQzp5CzBRqDq497uvjQud75xeXFQuQj6vbB8Qum7yp1ZPO0J/M1KO9EixLQYeid33Rk6RIRuuiJnbylO5g7
# DATA d4y5tLey76ULdLyUEWISW0KetGIqtArg8JbR7RRP4YI71iOjFrej8mYURmb1bT6AHn7YfwWhB6rHDVpUAbXxcgQQ/6CWW0Zb5USx
# DATA 8TxKu5NRbhG0JxY3vHCf/RrumLrZS9+Ar9w3mA9h6XKMZYtauxzrloebARWVgSNLOxDDHoUtQIGdRJJA2JlyjwLXQdg0Iey10AZm
# DATA 3qhxiA91cWs0gGhKexkyhw61KZI/eefB3FlLmQCa2OccjzAJvJTawSeQJtG8oFaVwdrmVu+PRFztMcjBoUOsL6skY61FKKv2erxy
# DATA Oj5ZWbUdT8wSFJQ4vOVoqN4N13XGrYeDSSowyYLlrcPk5W67+DyZs+VQwPU2mkD/LqXz2v1iQcL97jZxqebXHkx/FSoHMR+9rGxu
# DATA yv3yF9D8lpx/utW864M/T+1WohEgMbywpz0AWQwNwCJGmbKfJEJdVz5PFXsTRc6yi5m3sWRWkQKfMFUskPWZEz1/4w//+1f8P/TS
# DATA gnP+FeV+npv/eXVl9f3VO17+55Wb79/5Q/7nr+N/flJm/TufXi4/cxdULXkwW/NxmkMiZvNzejK4ZN7mevR0NsmeAv5FSRrnrKvE
# DATA qTyYuvnMPJ6p64Uiiw/Xdtceb33Uebq2+7EWtazC3ZpkY3M2Okr0SgejI/IhBFcxXYfOWXyTExbLvMVP1jY3Plzf2bWJjcFRFV+B
# DATA CfXxGj29S48wckynOr57u5gWGZIhiNrR7Lqx+ZH5Rr13X+gP794OdM6UerT+FKfhW0s7u6pHnc21J+jI2TTpTIjhLv3x1rPtzbXH
# DATA gQINkfuKC+OlJlAVuSVurz9c33i6awrYmg7S7ovZmCvZevyos7P77APApInvX+uNcJPhBnpwH/4bDdLhUft6Nrz+4D6md0QolGza
# DATA vo4QeeopBnk94BiG+8v08/5YP4HLj/Vwvb88fnB/GauHCIWNR+ubuxsfbqxvU/hLd3Qy7oOkgNBGGtcIYY1uv3/x/Ptqa3y8/mmg
# DATA 7CFiYt+9TWV2t767vlla6tZNKrX+6e765s7G1uYOglg0oVcYsdLNc8roSf/kL4/w3+mrKT9GwThuvuLyp9mBOqr9QyVsxRdq93cH
# DATA aZ5HO2qy6cJs785Gr53rEKlOEUbNh1CbC59WDZ3GyknTm/jRs6ePNx7CRvzjna3NznfXP3NsOGGgNBckjfsOM0GIjK2gbU/oiwg/
# DATA 7eBsWnADYaC6IPyiF761AB5bRwCy6YyOEvmJLzQw8keZeLqddWcY7kDrFPDkKMzjxub31h5vPMJZVHdbpKz4jZ4eJHEemqAX7G+z
# DATA YCdO7gOI0WfMQfVr9VuoromfP8ewJ3xR0bFnmztrH6531nZ21neRBMeJg20sCb3MIAXXrzDEMVzaCXPymkY71MgEBvQY4Anu+EBB
# DATA c7NA78uE0HjQv435oKHKIKwRvIBJOKeQk2YzvqBIt8lUAE01wyklvW7UvtNSrPbH48nwx+ns1Y+Hs8GPFb3YW1Xd+vFgPMU/ElXo
# DATA ebN5I/kO9wpu282N4pXskHvhQkEnJgwvnx0e9l+p7XsK1ySt0bBEKLnCigYwIzu9Ed46Lr3vnGXlvfcgunnn1gJH4NHWk7WNzVA+
# DATA HkPMsMbmBPK9j3F91GrRYe/3hqn6qc9+mnf7ffWbJ6oMwu0yJ1R3T55RiZHGOd1puFXJy3nPqi0hWdPd1Qv9BneJYnXS5lIeOgaT
# DATA DWUt6dYpD5pxkiSXnfggjQZVbQGX1vHBegeA53qTwx3Y1NRUO+3YSZZbtq8ppN9u6//RAdBhOo6UsDRVZBNegN13SuIvPOsfqKnM
# DATA UWMB6vZXt1dW5rBsnKCdz5483tj8rushGsYnr8YSn9OYXJS1zYdKvN7adhutjXJypASVB2LmkeWlvMmgo14l8noVovois/XJ9gb6
# DATA ZZUMwc5bW8yb8B/NMerw7WcTO7O5tdtRH64/VP347NIdQW+Jq0O7L9xDVd+zx2vbeN0pRWfvkN1JIGAzBZGUxiqiC0fZHGSOubwh
# DATA D/R+Ukj9ak9uWAncOUlfZBYB3wL2I5LYnTvlpwUJla2+QK2wdhyUqNOOLDQ1bldogGKToCmrQ2O1GN7023Pwm5Q6KOF8CeOfm9+z
# DATA 6ImkzqpdMjy2nB0V/oNMoXPYa1OLVE9xJXl8PiJ/+QYQDj6U4rbtQexr8jgCTzdr+SOiWHj9wcbmmjo48DJkE+wIJH9sLhGY+kri
# DATA yNKTAG6sCZGjEgsi62voVnHk7CM3/s0+n4eZ759G1Eo83niysVtEyefeluHkp4fTbDJ3dCE0fXSvtn3uD0d1bwjy9wmEOnSGBC1b
# DATA w1bNV+YXfWR+mm8qRAIc/8OP1zY/Wn9UBOgvieF0zlTL28QmD69jFtcs7JphYS03QNC10gpTYnhD4y9D432L9lJl/gmmPXrzFqXo
# DATA 0N0Ccsah8LW32vJwJjXmvm0Dri1YuTnwobjQ0ghI574uR4EthQSuyvhTrR64Iv8vg4a/jAhAS2w7d+lw0ALNCeScfif0viJriWg3
# DATA mR/JUkKfL2eznLs9ipZJeYTd+RZvnONATIrOWcE1JMi2eE1AN6Q1ybWQUmqcnkEZ4FYEuCUU1U4caEEDXZ32ZZHbKFE2rvPJxs7O
# DATA xuZHxTup012GvWrrfvsKMou/8XxCuN0uForJSqybBV0V/C6wOGxIgh7oBL6sHeACLpQ3Je/DFwh4wk+B/83hcvr+6szJI/WvxNZW
# DATA xSfpAFOMQht7AuLXIIAzmg4gaqCFFswq5Cpa4+/5XMbZy3QQJxXAm7aa5sGod1bHqh6O8DVBcWIqEK9Y000NorjtOxg68DceC4+i
# DATA A9332/byLI4nNfiQQD7ps3fQl0l6ilnuX02NxkaqZ8NK1p2z4TR9FdStKj6spvHyatZAHwP6HFTnpKcJ4w04R3jRsykFLxa6SNUN
# DATA FZco1EgfjZk+8FRkUxauroFtIe8eZyep9v/OSWWJuwkK7en3+36GGfetd7AWmiktQo1Oc1ay73Ef9ktGAkUF/KyjkoZ3qJF2LGxX
# DATA 7FLAzKHqxzuiasYFZSn20Zts9YTnut/DGC0wQ5GfvgkRQLQ9CETF+S9wrWIbe1DZvqsmtSYrqRrUZbGY+WX1eqH2tJLRaxNML17W
# DATA D37aJOWpwfXVz2Gzn6Sv+iezkzKgfonK7wHy84RzTcbYpCsE7VvNTOeqkm0AvdCd1Vt3V5L9JLkCsZHxu4zlh7NHy1QFk8wB3mYT
# DATA wOtbep9SuLHeqNbue5ke4gdOfPGgh4htsN3csGOSV0QEEuHVBGOQyCrkwvbpEaqHza6Sv6ApiL8b6kZ5fGL43JjdKPHzVysrqJbV
# DATA /eBdwj994p3MQWS5/ARpbL7zc9JKX1w43dGCPY5SWGrQ7JosKtNT1R1FeB6uf7z1+NH6dgfANdc/3fV6QjMHESY1b15dVWaMGPrU
# DATA C22Uoa0Ik3p75Xb4VZB6nMfpwWg2NZZk/LUsGrho9jEBSIaGfN6mC+nnttf/3TN1uXykJNWP1nes+Ojgr+S8O72wfPCEG4IXI+iA
# DATA UF42YZtm+7pP9H1k6BkLcdtqZR3pwG2dcJNuxguNBsRttW6PH2+A6atofjYUdJ8IQql5w5P1dR69c0XCWoaqaaJGPoAV/CG5kFzI
# DATA u02QoKfO875Vh6E/IzEjtLoVLPgwYS19BKy0Lo5IHZ0tNKYhVVOPfjgbTdmfNzGkoXBobBR2JrD1KugSu1pKEqupFGfc4L1ibIDz
# DATA yYbrFs9mLD1XxJ9nJ1UVVn9/BTlue30T6IIU40J7h5YPvY/MvKu5UEs01QpbegzyH1tVeZmlTOVtE4OdzjVpwuHKNAGjy3c3tz7Z
# DATA JMqqJSu382K/5Xu6+n2z9YzB72zYlYowoetqB3Rdi+koqtVXtM8uow8L6p2DmgtUJMGQQgqHYExwldJGhuOSyF5Q2lxCm/3Jthys
# DATA E9ay/unDx1+5mptVPxAOU6LsZuUvDRsvJP6rw8EsPxbyjJnvgt6Yp5DOb89xMOAdWhPBAuxhkA1zxUE6aNRvM2A/UKEOwMJwpq08
# DATA U7sgVcuUt2txHYhyK050QpikcOvkfqgPTvpdng7ZmZKVgxMzmqSYQxp3rXBDFI52OFUNgE4FX8Ym/Oe2Iv7HGecV4i1kaqv7MxJQ
# DATA 31Zo3hY/fnPUhLx2msWI/hXTrYbD1UNf89EWpzyfdDvO2VUHKZ92So6zpUZN+apwbplgUpslhj4OxjflzE7gF0HlvzPh787+ZoDu
# DATA Ku1uomM8e2G1pTppcPczWTw55pNGQeGShUzC8Lg8k7CxXUyyrrr3CYz06WiKOjUK0gRATU6vxQ2pm5zIn8XvW+4taAKB5WMkk1yg
# DATA OR6Na4m34XVZNyzJYSOOjWUOpyqsINVfemBKeRZ995VyLc68TI3qrM2iM5BpV/zyk23wyIpDD2Z0Xizvs5f/mTeGSf/sOTuD8gmX
# DATA +EFU9GVulfo2hQWy3e31ojnTP1OAhY7DjpZpJLhA4SGQjYlKUWr0YFbocNhUpuSm/stMswH9uzMd1RgPEsK61N6rJWUTWO3ogov5
# DATA Nv4/ZVabMPiIHRiuqEk6EdvQ3LoZdVL+vT7K+nuWknAXgIk5/GU59MkCNqcSg6AAjPVc7RtEv1qVznVX3ISWOr7XdrpSWrrXP8py
# DATA oNQcf9HMj9Obd+7Wyuv/KpwhgrAzb+EgEfrfJZwmStb2HTpSXHOXB/0W9IP+cIRH0PFjkF+on0lrrm/mIm4J5efQJq10e175GTFc
# DATA 8/H8Ph5wqL10CDlRd1RIQn+3bmtK5rui8vpgja2FMr2+zQTZo9OcjcGtqoYNz//IzmyD9LwLfEdKKjNBq1/x4i/mflPS0a/d++Zd
# DATA jr7AfhBnznKe4nB4D6irFf1VkwG8wat9qdh0CUcFlpA9km0ucVpFxuJRksj+GR0LosW4ShbjLy3BKR0v6hDwhyeuO+ZG6W9XjHZL
# DATA XOUQ5h1RveK+0V2fuxt6Z/pdu6Il80V/SJpU1kShMhVVUdbOBq/V3aZob7ua7dM+xsbxoQ9XhvgDoZTl3hD3bMcXsfD5nxTCS4yG
# DATA EAvyROzjrLmPAsYcKsAKWTv3hSEY+5bzQcDOVdoGroY33o/XPy0OFMstFIJAvum7Vl1pNc8sH/WHkdPhomEsZBQL2NixusrOY4lL
# DATA GSJlzxdwNASGo8iDkooHozOALQtpDe1bdZcxcZqOBIwZYiYYdhnYwI2XqzqBk6tIkvpLqqLgl7SO5MeLYSjGRXjuvBkkyMP6cMvS
# DATA 35e1CMJQ40JoxdNsggCK7P9RApIcZjsfPNv5rOjn4dzqpWwrEYWqhOqAji40Q1IbMZzGATBJino+yV92J9PCW3qMAblKZnEyU/Cr
# DATA x2pnfPAY0nmsLqKhK0BUOVeLRZJgqHkRvzc/KCxWNZL1ZRbp6pk2OqovCD1dG2SHEG/XPzqeuow2P8ubQIkVrTlxUvUoBjt7FSfh
# DATA JNAEUNU/YC0wBdQ3Hz56/JjzFMzyrIOB9QJK53A2ZPQPs6W4CsJ8VBsknd5U2wqDqnQnzVeVWamdBprp5Ah7hMnuqW/dDsI4ml/g
# DATA sNEZiwdzXs/U+323FcCEgRjvtlNJUT8Kc4/3Q/ijo3W9+i2tCbzGvzoBJapuseZUgIIxq/ThBWUwrDvVuKXwjS52k1Jdl+YYZrDr
# DATA nhifWjVaVGucwwIQRGoQ13c+2zFw60jTzK+tp5tbuzvPnj69qFhDOhh8eGpddFEFzZ/io+aJNaEgfD45NYKCJZ+qwwEz5Wiv9Xu7
# DATA EzVzMeU9tbB4E9IMh/0p1kG9sra7sbVJupYdkb924UMWOCNzD1fp6Zl7goKjWdvderLxsKMNwIrfdp5trn1vbeMxuIBLP56v5bgt
# DATA euQKx46WnRQz+Gfh6MkNA8XE706J4cgcRa9KeczYkZfPWbFSt7Tca/zJqg+LaoMnq45jcVXnHiMD8FTKoNGWhUJl6JgtFVns1fYT
# DATA mbd45qRRwDuNbE+6pl2Zm/46dbSJ2/vEkAxC7UCkPCFeuoZP43ZChEKE9wehCMnUYCvTvVyOYmotj+FvI5TCdc6hN7q9tqgE/R/p
# DATA OYj9fuU5GxZ0aevxwe8XDBb+YO3hd589RcDTquBnyj5TENbDKoARgC+CpU6RO/AWQ4cp8W3BEh1UDUzSU33NLrkjOLcDiwjjuXpU
# DATA 3fyLyPwi169Nl2Hg+q3DUjdTkpazgdJJ9xjsAq0y/QMXUH2VmDIVGol3oFOwHTQqhDpj033dugTGyymoFPhSbzuKNRR3XBkiRjUY
# DATA g3ut5UPsOErtyYt6UR2hJwSnbL+QK7YW1A5w6fnqAS6YJItrCOjExlKSsTvLngLnkkyhB/42lIVLDkewdBJIZGE2rEcLwNNfnm4k
# DATA d+lpkXyi2GKVPDwx86QuJl+uUrXYhOAPngrPxiOENBcUEjkBt5rMOeyCi9Sj6ehFpkTI0aBXj4bZKeMq1plFSYwIvQ4h0rZksw6U
# DATA dJ2ij0XTjpgnWIRFIu5lL2FOxTfuy4VupTTHqA/7bGd3/YmQAfX2cJpQm6UmcLLABQinSLg1eAHeXA1Gmq+suNE4ZSsp1DjhLW2C
# DATA TIIlXRpstNaGiLaiVU1HW5X0rF4QviQxawUomabELdwyxc9p77eitzlKMrsJyUSaP+l9Rs4yDg+NT09PKewMNqEiW+GdCgXUi8vF
# DATA HjND9OYX94X6m48Qy0ucqwXEBrnbIXfEoMfTpuSp7FT9DQfOmUIos/MOZtCrVS8Kn+2YDjc8wD8uZNyU2U3Im7XrrYexdyO6OW8G
# DATA zRfS2q799ZyVk4B35JAZhBAimeiwP+znx2X0zNGD8g1CeLlmB7D5fekLd47MqHhUKOI4B2KJEGUQGaMWoSiFpoPaR5eiIt+m3c+j
# DATA SZykB/RKdwTVJKqGQBgwJ++jcnU9Nb7+cbEOtCF526l4gzNU0bhR7XEVdZr1JBCtTDcil9HIiENe5Lrdf4UEg3kezDEzbytRNT9Q
# DATA J2SIvnKle1aqJLl40fynX1zZAsgV1EuO49uL3UTOXDrGVIsJVl3QJyOJW3Ly7mTyBcx22FlPSEXEx6IVi4omYdldDHZfI9PLXRCS
# DATA 3IuX6JA0vaBAH8aQ8yV8WIX9emR+0CIERP7gbMHiLSDQY7HSSwQt8sK3CC5uWg3GSnnQapZKSpzOWI9b13mZG8fu9trmztrDXRth
# DATA pIHPQwZxe6lBqbT09uReHbgiUn0uwjfcjbl0GWE08KlgO1ZEtJxlLtfLXo2VKItRjWIfFPJPO4vO2Ox08YRzoyt5y3XpLKIemXcR
# DATA 6c4mqMNqv5UMxXail5o7QZsO36vzb7v8iTZMQrYnKG/8STBpQng6C9dQ3X1zn7Tn3aa2GeBmsfOOb3Bm2roDc9X+NK+uqEvJIAXR
# DATA WaoSRKp0SXJ3OGLAJVQEXFfPzL2RbIyCtZQ4CT3wpH+EAVzu0XI/XXKN4sVxUS1J9aa/5G3fnrGjzJHj9PLCrFMyK56IoB3E3Ih4
# DATA pPI2FO7jFfppxUa3lXrkHwBflA4fE7hveKPkD7xdXT52uy0D12vsqm00IOOifBsQRkVPfSC4UnG0YKqn9k2d7sa9RCcFBaoXz0MF
# DATA LaoHjwyOGeddbrc5Ey+WqELDc5mhBAYgSSB2cDGuwraZh1vfW9/+DMLAP3y88XA3Tqrolhnu/ONVHFZxJYuLQ7bOEpJlTrvpE2Y6
# DATA 4o/nUsvKAX+dvJELXDMMx03pW87FFsI5DfCm+en4dBSYlSUqjyhrI2xpVn8mpcKPNNbh/Pot6R7wdU1aCP2l4EvfOd9BWGmk2Wdo
# DATA 71r9ThQfZcNsgltSfajPiaf3MZ6KLSOwGd/FOcLIhb4lq0vytJ8OKEJan1bHDYcflsehGZeMcNTXZWKTjc7hMuHJuoPvKNbLUdPo
# DATA GIvLh3eR+cMwCA7zB5erUODWYX+CQSZDSMTEJXx/CW3nx6LlaX+9RfG/tIiIEhQDro3Fpqu9rwsOMl7oFjW3aOhWKHzkLQGXi1C5
# DATA D8gm6ESWXCN3W50lI1lwoAVtnrPgID2J+S0ERrF+y5DFiqpCIWGL9cgxNJd1zBk7KvX0r4IyzvS2XgTHS952BKFw4UXiAKp8DAFI
# DATA LZu8DPnyuhB8WmfgM1XXtrhUMhmspEyKFYoQXWYG8GYGmeBj0znQsZGMCgYEjp8XgX3EOALWkHfHDnyGw88M55Isg7OeMqaGuEH5
# DATA +BrteKKI5ugE40Mw5lyDA4iLmjRBViJxQPQ4KBy5KkObDkajQcAVXnfCqsXMI/ICoK6ZG3cwIMAghSysjwIIn/UdAyxn18xx2HEM
# DATA bvZsWFVOwMWcL2O29KKqaxv+XdBeq1kJKa6dEHSabhvnwrXBb18yMIWqpApJmILnE0vJq3y73DOqYBsijETosRDlnJvIkrBX+62S
# DATA LFLm/q8DoF5mrP5ZxFhlOqW/8y8rYpKD1HsBkkEIGwWKYe5ewXAuSS5M79yAGZcmiELi+b4kE6IIP9u/8GM95Ia68gZabBNdSu0Y
# DATA 4AOha0ZgFGEVarnYvHjnSVsX2L8kZdEUwVtQDp87DZSFvu3tuy5t9cW+MpF+FcJD3f/cvHHC/0o7ULlVQvd8eMbIS85kXGWqK4Ce
# DATA CG171O+SG3G/pz7sH/azCZpyxE9GgNLdr83fJBZvEyRTeCKqa7eLfDyxisw8G2i9fm1Bfu/RG+L/nPSvSUOs8UgJksywzLZgmfiV
# DATA fuPc3HWPgnBYl4bEkoCRDi6WbkfgYtnY/hcZSBA+rk/B/h/gsJVeAL4M67sJsZLIS0dxWeDIaTpRVxyM94ZuLkcFeAzmXFSw6WOU
# DATA SPAiLGEa9v1aLSjW7dtufxmgwyLJnfPYbkiMH4YQVGSVUnYfZc3J0WB0UItvxElyUQcsvvYgPTnopVis5WcSq+ssIRQpENLE+ggp
# DATA w4zVXkVnnQpnKCd+tWU2qY1kbWnJNRz2zBGNLQ305xG5MuhNR9k2fx9clLXO7ljS88IhlI5Tj5mhEs+eRVRzQc8exwxhtDTXAh4g
# DATA i4aWS133Zd0YO459UjwqZBOU0hNTvV4spMQgb0ECF/M9JyhsBfzqyoSvss3nyFaBMVmpSs+UFKo0uiGm/i5exahg3SgOO7a10ttX
# DATA ECy9+HW5l0Gg+ML3po/WN9e314S5+Cu9Ol31dmGt+KJHVCrx4ia4qIgKkY1q0OcF/SN0ZRiEc6noiXjRiw14FpXeIxPnylhVLuz/
# DATA VAXYY/wEOk/XNx+5eLfWmlEiA19GcVM0XAQ2LI5vQZ8Irmmhcdr9HSCFbI4mMafc4h5yRKR58fxCnPGawtogCHxbPwNvWWpRD+yt
# DATA bN1Mj3odb12Cnvp8LabG53vh2Hgk2YS/SO5ruVp6zP7lwOux095cadJGYy3KwnjTWDtj3euD8c13Dn01X6Pv31Ip4CoEvGl0Lhbe
# DATA pJW4JWOdDpezQ5YqAwSDLrA21P8pEfalm8dSyYsTdISiPOvNtcnRDCb7Kb6pCaDndrxBDDw6mA17io1HivylgwiIrGYXORLG0Wwa
# DATA 4byBXgtyIkCf86ZJqAs1A8Z4J+XGanGjIXHXQC/ZfmrUBGVfkLRZWUbgrKhJSNXMGCVq5Xc0e40JOXUu1h+WgIC9dGnCSJiYqo1T
# DATA 3RrM0RU+422zcAc1eW6ITaT5MAKs8Xf4D3yZ44ZJgmmq4XUTOl44/3SAi1d+dKXAz7jjBaccfOlkcbTmfvUmxF78MloM1b9ZBV5p
# DATA d+NhU7SsnVc1lh/OVGfySOxOJIrBqaybvW+2AvTC26eFeXJETncC6s5s1Usngd8EVaVFK/78ebZztth8+ZPD36d2CnvRbKjuZjCT
# DATA sGWg6lmuqGrJnDgWkeCcaNMI/rCmCbkFqmZlPOmrIyGAl6npRZCXkwLrWJlnxgrgghQ6cB5jCWYq+Ddc+ov9UXIx3HPbgDOQT9V1
# DATA flLo0Koi+ea4moQzoGqzSVYEZL85qftLYSuqUwUA+cPFFdGHOh1UZHU6sBqdDnshQNeUfDutIc9RE/aNy/8PuAquv9YdNsdn33jH
# DATA /1tR/7t7+zb+q/7n/HtzdfXW7Vvv62f0fHX1/ffvfCNa+cbX8L8ZYEeo5r/xr/N/fu618+uknrreWq1fR1Hjemvv/Hq/d711HQW7
# DATA qaIP6qhcr1/HLBXq8eu/ffOTN3/x+os3f/b6l69/9ebP3vz0zU9e/zx6/UX0+nfqr9+++VP1TD15/SX89frz179VHwuBB6r4P9Xr
# DATA f3r996rwT0q+qkfq379QLfzmzV+rIq9/Da9Uo6qoqvJX0Jr6v1+pp79+8zPVjZ+qf/9GfUg1quK/ffNX6uUvXn/RVM2jCut66/y6
# DATA zqGiOnH/Wm+EMBCY9OLB8+fD+/BHNFASVvv58+vZUP3nwf3jLO09uH+STVPMUJRnU3iJ2jN8j2/g0MLjl/3sFGCR1J9agwaPT/u9
# DATA 6XG7p6TKbtbAH3VtCWjkStjL2qu2ruPpdNwA+v4SPn1ItTR2IG9Zf3rWeDoa9LtnXgMshDXySTd6HufZ4PB5fC+iKfcfTs8Gmfes
# DATA f3LkPEFXuda9aHTwA7X8/GqomBYUPkjzrKH6Ih4BKEuDxCz7tDg7YhN4/V+LXvbzGUq90+xgNHoRYboaJeUeHcOd5FgxkuPRoJcj
# DATA K5weK8k4VWwxyk9AcKbLBCRUjkDbrZ4rtnQSZWkO5onpCJhiM9qZznpn+O1o0usPAXaJkWSVQAci9QkAQmKvcas/eAqqbRBvDsF7
# DATA JPpx9O9m/WwavRwNlOh3f5kK3Ud/nUk2gGH0uzQy1d1D+L2c5mq/5MvwvJm/PIJ3KFNC2RNV/bJ6+N6rkwG2KmvCVcqPs2waqg+W
# DATA oNnN80t+hnY+/RktBUDoF4r8AEqAYJ9NHtxfpoLqDzwJcEwg3R9uEVQCweeSVGDt6rAMVJXYpxf9sezNN4F9QaEd9QJWh/fB/eWU
# DATA Thu0Kr4/gIuFMxxr2oNq3FVRdQzTl0pG6aeNQXpA0/IE5Cb1uH+U8uaDFkrq23qZTeAcY12iVK72Tz/LTbmdcQoHOOLnfnHYgqbs
# DATA NuzH09HkBa4NFl1W/eFJhQGTaNiDT/X83OfUTHYqxmDrgS+IMq0+2D1O1RKOQSY2AW1qi6u/law2bKrqVx/cH6tiWQTfquNxFh2n
# DATA L9Ufo5eg3YXMf8d4ACCVI76G1UAxE3bqqBmpb9W1Gd3hlCSuTtsUjtjZaAZLBx9rRZU+uqrV8YP7vf5L228iDbm/Mw5m06l3YNyl
# DATA +EAJmbqZg0zdewFvlyfaqwXMg6NhT51qp75FFm1Z9RX2Oc12YNr5AU36zQdbk2jcVx2bjdUkKdJyOFOTMhoNYLpvwnQ/TAfdGZoj
# DATA DwcjlP6zlPy7I6T2UW+SngLFAb8+mGG1XmZzRL1RRkvZy6aAVqhuEEp2ncHZUh0Huy8C1yCQUXekRPQ+KMFp1i+z/8x4l2HDPbh/
# DATA qER52Ilj90Sp3SWnArS+dEuAem3uKFWfKvhAr73TFZuIDL5ZQ8r+R+nJ+B7I6y/T7hl0KPp//ym6VP9p1XSvl4EowXliXq6Yvm32
# DATA D9z+D9x+HrenbXkFJv+OefzVWPx8Dv8/EIN/x/x9IfZ+Oe7+tTB32pFy+Iah/8s5QUjw5/NORelHeaY56Jpmm6TOUy0id9f8Uw4Z
# DATA 5JrUDnN0yAGQauxqW6FahZeIp6DbnyDzRQWeNxE4PSjSaBacozptkKUThPI/UUxb7axBHRmwGkT/JOtFB7P+YAojAPqY05BVT5/l
# DATA 8AlKW7p/egTQguXoXS0P5L5AQOLAaDg4a0YbUy3DdSHPN3B8mDjFtlDTbM3aWhRIe8BhUL2IXYRFaaBYAGc9zxHHKNrJshfRD9Ve
# DATA AWctbVw4zgZj1FVBJ6P08BBWCQSS9DCbnpkRfjaaTSyP5qEpSSePJrOhETUPwNkpmzSjdU40BFMK45iNQVoBOVPvQtjjOcowqgCk
# DATA UBiBkKTIQw5l0sHZtN9F6UaNLZtMwcZ/pIaQgv+Fdm2DurrHWfcFqjzRtINqT6cz//0n/1vOYwUtL/oF5d3RWNWD8qRYs+b/x967
# DATA LjlyXPu9r1IOWZvdIoBBFe7dnNEZ3iR6kxTNocQ4IepDASg0SgOgwCqge1qzJ0IX7y075Dhy+EScHeEI2+GIc75T2qI91oWKsF+g
# DATA +xX2k5z1XyszK6twaXRPd88tJZINFKqy8p4rV2b+f947KH+P1+VZ8YISdoqUq7DwBKJ6jFdEUyqpkQ6UPa7U1sOY+qJJVGE7EBQT
# DATA GMqSt7M85tQmFlzY9AzdYXLE44MBqmLN772bnMzEzENGys6yAdUY7FgrRU3qqdySwQinqFIrRw83iKSij5NMihZ7ClM28R9G0Txv
# DATA 1OFgANt/kqAxDAZ8/QgBxVBIhPASZyaNHggnq3kfJ3zfkkuNbo9SLjLkpWlRCHSOCI8j3UlQ9fkIvU28kCRQ0HZzoRxbUuXmaq5a
# DATA q26V0SMyFpHEEwrMZMWIJy+FgvyAYmw2LmUQ98BuvKF0MB6Ol1AJpbE+VzoMEcWa9zY6H9l7gCJJMS5G1Leo6krvwfkt/k2qlLL2
# DATA rzzN2W2w2WmGs6OZfGvG/lVs/Wsw9YtGE9n733ncTx6R+fIz4Gv6XEurdOUJHnpMFk8ymVT7Ec2F4yQ9yKYU9PgJwn08DVOqDQf1
# DATA Q6xwHKVw/Rwch+letToP51G6fzhIJvSIXCK7bP8Q/deB35k/uuPX2i1PfkFY+4fYZU5d/kn1JA3nB32qgQ+rlLbhk/CxBBPPqIHE
# DATA i0No+1eX2DpKtl5UTUYjStBBLQii6ZPwYIxwHvM9Q7BAuJFUqfIPHs6o7R4E80dPpJJU4tl8uajI/q0KnsBY85ijqN6l76zJ38fD
# DATA OKNh+JR+5lePJtGjQxotjmZV3vJ3MIiAiT78KbXOeHRaVe1LX6b5KRktGFcPms35o8O5GAcHlBPUZ3p+zcffQymBA3/+yMtoSjP0
# DATA rPxbyWh0HrNFMacpvfqyKs00HMbLTP0sXyoUAymP6onEqd2qH9JUKqNw5gnzrg9L2XiACYzKk5ppYjp38iuPrWhSNzXLZMfUSnVQ
# DATA Qf2YLVTs5c6i4V0sOv/k8UpCOfl2AFLFVBAHVDIYVYaPk3k4oNngQa3V0qlRc0CqHCMyELIq2YMxRiD1aPEiV4rSNakipYu6wpTv
# DATA XU6pWZwWrz6mpo0ac9AoFSrfRXVfftZ1mYrmicSD+uu9H/MUiYdxapU/2bcuoiiTn+yv1GGeSR/49fq3C5WuTZVuQ+3C6/d3b8d5
# DATA 1UXNrXWsiqsrW0MnohT/inVR4q+iG1DTPFRR5c9SiaurnQg1u2o2TunLQf1JITiy1X/yWEeu/sRkiJULfrdOYVNli38WHbDlRMPU
# DATA E54fmfZ9lMbDwyPqhmoNTlmhmdTrcneNk2Se2dQZcDAdhFJu/3aoTQp1BOoClf/jrWWkU+fXgpYOVTKQ4hUd0Sj+2A64U6+bR+pe
# DATA rUmPPBn7lXFQGTcqc9WFVxfJnB4f+9L7yeswv4KZLAFVQFrGeDed7wW1Jl5daddaxyeVVg1f9qlHrzdVTFWe7B9OyBKiKgG3KyIg
# DATA v1KXwGSNSrVWb7To0cNp+EilwW8PxocqUv2E2ueUEtrgSAe7Rc6X7rTSoKgFnPGImt+9IGoUl6CF7Cy+m9/ckDfTSzyV6xRioxxg
# DATA 8UluGU+QwTpp7c5g/CSeHlWy4yNTa5iEdmi1V1VBwuUieSJz4grvM5ARXTUV4OL8oE4VuYIJ0x6e9KpeG326iYgMUnZIF9bV8sDF
# DATA 7nIa+xcnUTTjmuzXWqWq7Ndbplsx2bau5j6psfdC8rIjedmUvAxW81LnWlCnCrF2HKK5RDFB3C+w9YD/SMML1NDKf5+wO+TCXCi3
# DATA 001v90IZuZRX/y5M4J+UTY8DY6kclprlkxq8QY8hnsA3juJH0fDwZ1X2wVC6D9Eoqz5K+RDEDcppZPSGLtp0C0gnhyxD0GOEgief
# DATA 1MikSXTnWBVmYBtlV+z16D9mzxr63uV0lh34o9Sjfzf1b9xAOXyvRpYDvYbTyl2sNmvyIm22qCHI3aP4aJlGxpDMrw5C9oZa4dS6
# DATA QZq3T6Sq1uXXqqnExXWhW3relzZaUwZ/KWta9bxa893r67R6mDukYhR2bkx2plL3vdL9texY8os86gyLd1HWoeQe71CWaTSnWeFe
# DATA o0L1nAplr16hkqVuI4/Rk9ogTIePrZHFGnXaPNSXa2G2TEc4wn2BfbHdHJX3evMDzP6rg3E8Ga4mk2+pwX1eqU2XNCl9bBsIfIUC
# DATA wu925elJHp5gW75tDfTWtqn15nOLOtkm/dugf9swrUrlxPWzUADssys2lw2GuhlgEEipN5Q0H8wWY8mTvWC27+m0bCqJYNVqe1Iz
# DATA ftNyXadugJKFTsLc4ilrQDLQDPwYWjHq4wNChK/SGuQ6XbRtvurZg1+njuuUnnixSx2lzFQ9ju5eCq2EoTZPavAtGGsvuMl6iTfx
# DATA Ys6qiajHlpqYb5dogcHaFshhyWbAx4XOSsw9u5/3VJ3bUgdUynj8aK6bUVptoSHd0cmYD0uitzqgSRn3ojpGB5SUxalJI4+ENdm2
# DATA XrCxay1tNavmF0i3on2Rayztpp26+iHuqvICjnpL7secxI93MDdKcxTqOWjeFA+ix3aWlOdjujnq5iHjbk0KhaaXR5YRZaJe32GY
# DATA kGe9ENMNmg/uUEkKdcMz3wJ8g0232iDsMaXYX3v13Qy0Yiy9uTUwq58yGtxnR49LfgNqIOFR2Tsipu2WumkKKJBJZFqsM9326qRy
# DATA Q9PshyXbVreklbG1ZBeUu3AxCFSQnkwK8ciBb82z/Cb3lNIU8owuO2+GYTaOihn843E8HEaznxQa0L8QPGA4Wzyh5vbY+MEeselu
# DATA z40wP8jf17yg6dtZ2d3UsEtut3B2egI39BOsjUgpj8JpPDk9eIdMrITG5coXb3wY9/Xe94+SWfLFG5Up/eFwi22e8nJI43A8yaxs
# DATA Cnavj8qX8rjklSo7rUr2un6nV5jdchNWk6iLmuthcXTkGAdq4pOH2LCH+3VG5w4GYLnKd/NYWq3PqgMtjK/qhoJbg2cqu/knqcfO
# DATA vdWlmeiG6lCbx5NJNU1OLraylU29iOam1HU32sx/Qidu2n9TddALuPA4vHIreMI/6YKjLnISzjOyStQHewJt10AemBfjymIo0zLO
# DATA iwPEpjCO7lQZF9tsrSc1ikH0mHty6cAP/DtVn8dGy0dkGQ1iMyTLxXy54BMJ5cySORXv0q9i2WaNNYvjaeEiSR/rYXedLSs1Wnd0
# DATA pkI/+T+m0TAO9ywTrU3d2v7jjU4H29PQaKPvVV6FYmtRNsnq6MSVRU5RYLor2WTXGZ6fbpx/lhplAzNXOyuL80njdGlxX81zo0sZ
# DATA Y9pY3Rwf++Xrp5ANLDYUZ4g7ZsuKwbB5Wh6MtI+xZVkp+sF79lzKrp5ByXzWZuxqvWg2uF5wHla0lbsxPuyWEdcLj+q9vHAKE4pA
# DATA 3HRqqlkcHnZP/c7J5U5kzfyHO3KqSibdc17SzKppNFwOomF1mnCxyFdqHevWxDjw71S+cyCbPuhDOEK7CWfxNHcZ5eP8IS+KxGt+
# DATA 0dGQ0zm6LUozrOjFqLLDQ+xjLk1lflguX1mps3oFtgLU3LBP89OHZrZRvunJk8KKod61hR2C9Md7NJ3MeO0T+/IO7tw5OTmpnTRq
# DATA SXp0J6jX63fUBi9sIHo7eYQb617dazfpH172RY33ZAMgfeeLnnRk+feUn/MDfB7REMR7phr1xrDZw8bHe2+xXAnvFvrIb3t+b9wI
# DATA jrvfD5rHfn1M/+1+32//rPDwKBg1Rg15GFEsropmNEJGz57ILk3kaTLPKUgman8b35hvxqKK2z/FL7xvLt9dpzY/mav2ovNBvqPH
# DATA 7AGIhrwWfmo24FlZ0qt7zWbLa/SaXtCqTxr1wPO7jWqj3vH8ZqOYMcP2sB/VV3O10/Aa3caP/E57EgR+tdfyAp8er3eP6e+HCLpV
# DATA D4pBRaORz3nM04WHnP5vNVuteivKL1ZN0TdWXopQu/5xM/Cn9WrgN/HKaq/HkVER8XypFVd8QxDUvaDpH/tBY+L7vtfq/ijodX/2
# DATA UbPR8xo+VZ+gO/HrnWqz86Og3S0mrzvoRWG4EmSnRbnSG/tBfVpt1+mfY3xs0uVGszv2fbrcatE/x/SxFPN+u19vjtbFvLmxpqrt
# DATA i1RRD3Cy8LHyBB+oGn7I8/sD1VgO9dT24FvtVrvfwAXjfaJH+H+HxqBZvRIcfCvyo1bUOVQ+toNvtXrtTqd1KBbGwbf6o0F3gCfY
# DATA 7Uw/D9uNYHgoy/sHX7zxIDpKIu+HH9B04bNwTLZn5T5vH8uoK6xmURrjWd2l7XQ7uqcadluSyZR36QdiTXpB0encFUPA3G5GIzW/
# DATA +V5EbToOKxJ0aWnusOwIg3FW6dSaxyeVjjjCOGC1U26X6f1W/xbNVIshlh3ltpmnCmb1Ae1DL44ThbvmBatSTE6+AePPIMZOoseX
# DATA WB7I1wLEA1gyi8RpVb+ccePBRVveiFH0CtQ3GrOF1FZWknaRcac8eyt1jM2Gm7RUnqy29Z+iqX/xBnbvUScRDxa8k3zGGyC9fwl9
# DATA Me/uPbMFsvblMkpPH/C+gCTdy/ate83N99M0PK2N0mS6t/65+5MJPWo9q/by/W10CulF/QxaeA3bASm2PLf03vS+eOPAjuA0muJ0
# DATA tmDHPgrnexyoYYWznPHD6LTijcLJBJV733uMA//0XwlAZPJ5T9kDiQSI1B9QVu9ZkXoTGmX7h4YqzHQVeulyMvG+6+1JLGrjMMPL
# DATA 9umSukJByZUDKwIHHo5+ihYBi+0fek9wVHkwplipN1wmRDz+xE41H6qXZCtU7GP9eCaP6x8OVV4U0p9tSH9F4o1aMjuKR6caW2Wy
# DATA BVts1qRlhMPdq5EMT/cwed43RRFBoPZf7n3xxrfE8/vFGxQ0xIaiCRCtNdytTmfQjfh2WApynJxsDFOM0UuHOVtO9+Lhfp6aj5fT
# DATA fpTucZhfQPSPfq3p3Cw8OlSbSPdEzg2Bi54FvemLN/D1DjXneHaoj7nIGZc38tgvU0T/h59+WJMdlz/g4yH0Hept3tvQ0PsxwvlJ
# DATA xXuMgJ+gMOTR0G5I8vR7k4j1Mr54I+RsCGvY/QfNmnSCbzq+aE0UY1waTOLBQ2pT2Hr6WTyNkuVib28fbRyRSqNjMirySFE44L6T
# DATA /aqyQqKC9Q1dCphN4OV2PiUzbGjeG82QcJQNHmAhvCmEPt47pkh/qLRWKIxs2Z/GVJAVLzrmYrtHj/HHGlRj6O+7sjFrTxU1B0TT
# DATA cZoK/Qj0jnhxurdP4c9wwxMV1X+J6P1YDlyEx9FPKJI1evC9cDDeU5s/+UUTMpqzUMTouHehCOEr4vPjn6g3/gvpAeOM/+7xDfRG
# DATA /dyPf6JLifIfu+Ohy7kv4cv1U1ay5PtrNKpMlsMoU9HIO0T6ld5nNskt7mtpe5SwtfUNUXvAjXbvFGqd5pli5cc7v0sV84EkhzoY
# DATA +YzzRk8OdVT38sfXlA3XF7xPJ+c6skp/3iE7KAFyFxnVNLXdO0YswA6+6629/cD7ca3Gn4eVdXeYgiILOEMyOR7cvVqJkUgXsgi9
# DATA W/6MyVazD305H+rN5IUN/Crf31bb3tfvcT+UZyQs3tKeqe3sOBNKBsVxVOMW/kT+LVZvs+BVrOPJo7yC8y2ZLjb6yWSKeXhzEcrD
# DATA VIYmFBQiAlmxAb54Y91OPjta/LtEjD9KBLgYJPi8PsjvuieWb+uqKJ+8seuoMkFyjVzLftkW7QMVly8g4Tkl20Nqm4nCppqzIT91
# DATA BFTt0V/Jvpsd0WQQpo/HZrxn3ksXS7VMt5YN9erQHKhYX7NQbfJ6o+qOzh+Yq2aE5m+qJ5cbaNSnuRUbY3yL/l7u7qVpfiBapib7
# DATA OZNZn5hD/q7kovd3f0exRoWg/mu6R3+SD5OTKH2HMm/PZDE1hIzF1/QrC0+TlYSEc73GiQm6r37oWQ0CmVqsdHTBrhosugjxHrpu
# DATA d5rF2OQ1kdOy7/3N33h7Omp37+qYIFIckKkCJt/u3lVJQf3FLbKsR2/+FxwFaW78cV/S8uabUlDK2MHKoc5+/pKbO/i2L3fkwUp+
# DATA oHes5yOSUiqSMsQNJhD5bV/dUxo+JCyupRzDKOOBg0pel+iaxsjtCG3RqhRIjinHrQ248BC9CHFU1ZQyWQeyX6xxuFFZHHv7d++x
# DATA zfjFG++bQ2FoJm/uwez74g1pepT+78h3ngNyc18k72Nb3V6w/yYS/L9+X/uC/jd7V8+Sk2TBrlYvXHg+zVjelAD4sBkFQA+tfw8Z
# DATA T3eKt+bv8vld//sfrQd1hHZ4bjCVxi0zwPxApjuY7Q5mX3Qw2x3IfqUPZHuF7cbqHPQLfVDbeM7458IJwIl1fPvBnNXyMLLFQ8BG
# DATA 9Ont/HbeVszn5F6s89wvy6nGi4RbbEcpx188zvfeop623Az1IhmiYVYqurLeZa3gyYVwwt+KB9XLi1fSpAcJMlfedDob6GgoP/a9
# DATA H6ysfbGZSvZA6eC/9Qx/4XRwBszvcdEeULlDD4bKC/ZQujjFpmLz/Fx0A7JxyCdidY3y1IYLmhbyceRln8Y1D15dD3MQCvNLjgfv
# DATA UoqTtOb9YB7N+JzviM/u00PqMD9XVo/CGqPWUZ30ZBsCY5hwN70ZjAUKaKZ0A3ZU3vFKPm6tI8DniTnaZC2QkX2Ec2lGhudvccwZ
# DATA FQ6nu5no4H2yNO5eb4bLrH4k74jpp+UcZkNW82BL8Y8Zm1TJCE4eajFDWGqq2ZC5nLAEwGiZkhWxXFVDeDUP25oQnPXmrLeLrLdi
# DATA DXP6Ok5f57Jm20YD8aZ0dx5gC5slB4HXwLcJ4TyjwPP8NN62DZfY3efZcnUFS47XP9j+wKKI2pKjr3FhoxMSO5Z9AjqTlRdwb7r/
# DATA lvhEdQOc8XoUCklCM8+Z7iq/wl4x3v5Ra/EmIq1hTcnnDVG4OA15v1FLbSaJ5rz7qCY9+x2OYymq4oUw1QHfdoiofsrE01ww0WzU
# DATA 2tcYTfGM0M/aS8MX3hJHq4qUvsdEyjz0VsIdfh65AG++5x8E9bfuJMoqLN/TUve0ttzj19VN9CG/645EK0+KstV1bqpVMHowbwYL
# DATA W/KIzAZ+gg2JdErv5T3BKp1qNRSjl66a+SXpeeJjftGcxumF5MAdCQLzJ5Vbsk5rh5Jf0jvUzJV7lsEZYkJmdQC2NBUbjdLsl5Qq
# DATA CL8Yg/IjGgypfxajUXutrfaPMTaacctnQ9EMtHEqdmTNuz8cenwmVpkFmR4+cxvS+xBrKErVExMBM9IuIZsujl42SsUQpx4Hb8Qu
# DATA DHrbfDmZ8I9LLMPSoB6n2vj/YRaJ8o6I2IjuT9yPKYtFYl6LSOk6jwXbjKNAZgkMCzal0RNhXhNnmBZSkmbS+WmVK7bXJxC+t3o5
# DATA jIH9iPUyOdO4g5ci4dJ49a1mewB0hrMznC8ynEsGkrOcneW83Rx+ARQrP6O3cePIRDMvHKrWkJvNJc1GDC5G540VER9GCyrQ2ZFI
# DATA 2xWlF4UJlowwbiVKAjJXShQ9xLKRXPLPYruilILasvjWuMH6c1rIWTd2inFDXGZGpBIWDPYpQW8xlOiyGHYyGmH7F2T6uC/IvHFy
# DATA Qj97VEIyXHJe1zxlXEDSkmJ3jHEX/Uwy4o6B89ySrxSfFSenOOgtQvZm3k8xXE3MSGdSZCftQ3bKhQOycSCkeUI9Vp4yjLxVnjLI
# DATA hmhGnYaTjLeLwdJBEo/IFst0rzakwhtTb8alxMmUUz4UwoxFxeFGJNPpSOZOYsRof1kyJatxodQFQ1gFDz2tFLIlne+Gp9wTb08o
# DATA ylBclShjncYHyv84iiJK1jAesbQfze5gqEHgEHsYsQ+BqtVCtmAw3Zh+QVPEL2wCep8xhsdjviACZMuKmbJwDFJV1AkxFl1/eSqV
# DATA +nSB+oxNolsS+WmUrUmgmBWFKrwqqGqqOlmp7Lc8gSo8KtkETZBHnTRaZ8SiSCvajgThLRzGOHsnA53YqUpMkmrvp9B/GVImkl3I
# DATA th+SDztvScYEP/FQPK7apcyQMtTuqbxT7Ek9ldZSp6M4nfLiyLq5LSfqM8obmY+D0TvHMVIyk4zaOrUgYz3ni9+Z+K/lfsoPro5k
# DATA CqjpeZiJLcy9k/eRFvek3pVhD2xKKxC38SFT43nI5jGmBmT4UkmHy0WMbiNMWadrqpQnWf1UOhRwocRtTBYCrqspxcbU/u0sOZH6
# DATA iVZCTQR9JARbdYLfTTj8BfZVIrelLVKC5nAlcNfIY5vYJZZfAY2fShlbGuKJgWulPF1Iqbgp+8hGogyTFFKR44A0dmSEKwqyhW6Y
# DATA pwiz07KarJlP2LKylp0vNvMraO0/eVIxDJ3FEeC86alN0Pn/zn919oezb87++9nXipHz9dlf6P9fnf/WO/snMG3oh5/Tv79dRef8
# DATA F/rhKd30FPcz/OYv5785+9qjL78zEJ0/UqBymb8CtPPL899UvPN/Q8/RM7gN9Jxv6E1/YozPP9APwtT509nT81/ryPyVbvmDgHoA
# DATA 23EsnZdgNoNOGceXqMPp059FQTT7KEoonDQeaBOs5r33aD6R8XnCPWIkfUM2jufUW0wsb4TuHLGKOI9yn0E+F0omEzU+0Uu1zO9W
# DATA qA6WE1V4qqU4tE5xfqN7kNsG66wrmZvD6+RVx9wKky6/XH5gInrT5u4P5TuP6NdM2OFxTQ3ridrcisHUAXZ2LLbrR+xg7T1i6xOF
# DATA U8ldjGz8IvfgkMmiqGCYjmk84Xxkuf1sgZlqabeyRmoiCHMoJV6s8HUurn6bHZprWtbzwuxcnAzH2XGWwE1YAhq4c0UD4DVxbt7a
# DATA 4H8jY/9OQ/9lR/7bGfileq7mQ87gefFa103AeKwcYBRP8dVr0rsK8qDXTedqJVEVHuVZipcq8E0kWZOpvKl4SgLbS8eni/GUQ5ED
# DATA JpxBuyJ4VJHlC5HUEU8YL7PESi1U0hfI7YXyz8oxuVF4nGBUUKwZHWO8QOAmPJzSg9piUOfqDnN7QYhF8P3AjDgJZwvbLTZI5o6x
# DATA 4xg7jrFzk4ydXUeVnaY5u1rJt2zyX8Xivw6D39F2HG3H0XYcbcfRdhxtx9F2HG3H0XYcbcfRdhxtx9F2HG3H0XYcbcfRdhxtx9F2
# DATA HG3H0XYcbcfRdhxtx9F2HG3H0XYcbedFou0ErfCqtJ3OqDUavES0ndW1552YO5y7KvewK9Pjd7XbBYW0VrOU6812t8jNiaLuSIGN
# DATA cLiRojfgQBttlgEZcKiBBMNSGX6zXYT4NCjD16CROk2vGdQ90G38Vm/id+te0C5Re9p+q9Xtr5Jymg2v6fd+5Pea42b3OAhaU7/j
# DATA e/Uf+fXGuNk5bvjFKAyCYbPfX5OIVreeJ8IPeiYRjWIAQS8YtlaJPZSxXrMTjFUuWvQc88AKPad9BXoO11iLnkOVv0DPaTW74VXo
# DATA Oa1hNPJzek47aPudoaHnDLr90bCX03Pa7ZbfvXl6jqrjVa7GZlxoCEFHD7eFm9Y5qho8jlR6xyeVLltShTWm1mB8uDNpp/w25eC2
# DATA XVtiYqi7cLTgenA7doiruB010ewaYxVlfMg7OcbhMDk5qHvwbtQ9XZIFQA+369VXaLe7Mc07sn5SyPXSTYW1MhnOSzCcww37AVZH
# DATA K0VJWueplXXbLSGrrkYNbbqh5DWjaeJ3sStV9RmbKT6F0r7ARixknl2YKjF68gIrxFF2HGXHUXYcZcdRdhxlx1F2HGXHUXYcZcdR
# DATA dhxl5/Wi7MQjsd+w7oEa/9j+JnXnrhox1cAlv1W4Lu4fPrEwPY8l35AZdzkYnDoywbxJTwC/88Ubb66+Q1XqQz2gqJes3pjfog5o
# DATA 0F1s5x4qSNDHOMYlLZ9N+ckpn87Rby1Hqeb9n+oMvHUojQ+eoaypQpkoVPUN9MN3t43415QVxmY2SeXFqdri0SJPM/WOX7zxoXXy
# DATA ziSDukuVApnols75uCPo7gj6zkfQiwfC3Fl0dxZ99dTgRr3NF+GMeqmOF1qLLU7Dnj8WoEVlznK1FCV8Gw+jMCugW/hENJQtQS7i
# DATA kSaj7kzOCWslFd5KVzotu+sZdE4C6zNiLGdxPiUJSq+CC3Uuenx9ll1E/NYcBlW7rFb165XtiirIn5QavBIO1z/meubmCm+3hfxn
# DATA xOGY6MWZldWbVd6NQczS6PK5qPFu3WG6T/upFYV2WJQ43IkOTe5jcddNgu6qS+Wwvqc+b75bjtezyh1/2nwn97lKZnYQbb5P+m1O
# DATA P3/aIiovB021nLvYobaaO4aYLVruhZoA/7kt65r/Am89d3V6HiCfdJ6X86wktslufdMLiFXNNS9dcm788z/+B5OOcsSt/J+zRCn6
# DATA nEk4z/VX1VIi70lLl5BIgI2WsBTDDErwrEUNtdKYaiFDmcL5nOok6+tSx4zWR5PY2UKO/0OPdQH9I61Dy1rVvPihRWZPqHKrw+LK
# DATA 52W3zPzks24a+cFq4zjDZZUUkzP66CVdYF8w1xS61wIBlFVbL1VEeUW9bAH9/X/bXEC60kvxfIBioIqc6QL67CShNppSx+bpU36Z
# DATA MkGoT1rO4ImkIWle8z6gUR5GzjQ5FkEKSgMLDkDY4CjibhUFJPuHVTlFWt1Cldazl4pJwa2Vi+kWLlss//6/bC4W1cVIqYgc6CBJ
# DATA aTJiWs5MTYTlMk9z+qzpyrrK8smbh2hYQzEdRMF3RH14cqKKqGhHsjQ7m8WFcdC6HC9gRD97KdkpurWCyvvlS/dwv91cUrqPl6L6
# DATA PEynHu/uyru4E1wTOM7wGFrYVDJHVDC8foG+LpLhfjYUKY2I1WOhMx3NAMGRElCzgX7E5I54IZoc2B1r/8zUiWcvnzwZt1Y6zzIC
# DATA /T//tPsI9A4G2SiVIcHSAZ+yXU3xSh8qS5ubVDhh9fLQmy5p/JmEKfbJzSGfjIz2fiTGoxpgyEQCw0CaDUr82UuiEN2Xoan8x12b
# DATA yoNktPD6qPYhSifv1jDG9ymLptCygWbMgEYeTA5YEToc/jTE/hxV4zMUVsr2eDyNJzhvgJyCSgVZ6l8uY1GrgQoiC6tIAWpF6Gto
# DATA KoVkXKmAikageDRtI9Bckey+93GifY9aU4hnH8onmKRCZcQAnXAnrgtWCf88Czvo9RB3cXBu50q7givNec5eE8/ZZXndL4S6Y2H/
# DATA 5XZst8y5aSBdYKsmWZRH7NTaSO5+QVUgXyLRtIu0oe19jzdB8V5tJdfO8l4rI7qJ6L2acnWbUccW5wsmQTXPN5LY7EyqiO9I1CBP
# DATA EuO4yJ1MitqnHMJTQLmNzF9e0BVvmQm+FLKAFAx2RkgSsrIW9ppao/S5uU7meppX0gL/GJ6u2RGggQIYF90eIwVuKQtq8I3SzDow
# DATA cqIwq3NRUVtJ1GOfCVmsCyktzHtgfXvYiAu9zeNCfZDNbJJZvF0VmqizvMGLdqHOLeRw7XUyHu0gnPnozMedzUe7rrl1WLcO+4xW
# DATA 40Yj9WbWYT8S7qetFJ0TD58PqeI2KOG89wfVi48NFpY51U85XlvdurJemC8k5ctjm9YW7eUNe7Vm0/0lR3tpKWHTUwX3b8GnvemJ
# DATA spuy7Gbd9FzZe1b2Cm5cOS2UAm+yQkxRnYbxkOuDLDR99y0tX6mKRd0LfrnsORWWuDpnqknn5UVwHDLX/D3bovI09546ddumEpeZ
# DATA fvUOFHHeVDA9LTSglxchjoWmBZNQ5+jpM2WpJhP7LdFcjycy42QTPNIzKQORpPZjVquWbCpQaPQMnntXdyToW+zh2VMCITwBMCa7
# DATA eupzWOLS98i641Bcy7yvnGIC4W4s0Kgn7iSrBZfPG9c7jfO6lu8tBMdT91FU0qUSvpgB/upYyRYckKWQkmmBDfgfFMTvm7O/0L9/
# DATA PnsKDN9TD98Yy/cNWH9/OfsaUL5VOuB/O/srE/9+r+5+evZHj0GBvzv70/n/dfaHs6/Of0nP/kkF+keFEPzj+a9wjX775vznHn0B
# DATA kVBAgCATIg7yHICFzA38q4MBvgxWf6HvHkUnZDvwJHoeQrpWQQDQq09HkI/oQ7JLY0Co48Oq7H2F1U36zDxQ3XNfd1q6z17O+TVo
# DATA QhweGRkD8Z9Ei+V8KwLwPqQuvOEyw2YXas8OAFiw93Uvcdv8v9ViuTn6H1tYTFjJby3UtzLP/E50Gs3jiKwNff976oIHlSEgtJP0
# DATA mjGArB7GSOjlgsd/dUaLmpgjAe5ahNePAqS+Bovg1OZn8QidDsPgGeKM7XJp8ggaOhGfXRZTHgYraiF1boMFtjAsWfpffszU5hO9
# DATA 90RXNHGpkiXOjBtM4+Kj2QoWcPdqudnWWWl4zwsOuHtiHCTQWQjXZyFoNOCVDIPXwwl4a0bBDdgEO5kEl7YIbtcgkCpazg5jBrww
# DATA reomkIBWqtXy14YoargYuy8ennpHaThchgr6l+WrD5AxLK6xMWqwuChxKps+sTR/zK4nrLWxLGI2jwYY+Y0pthMc0IzrrMxNCc5k
# DATA Hx1l4Aj4Mq6A1WRUReXkfpbqUM2Dii2Oz4ZiOcBHxwQ8FQfFVkPy5yldyngtVZW2Mt9kkZAjyzea7Kt5H0cAyMkF2bT3YAkzJE2W
# DATA R2NvOaNiWsgZdn5x5jCCDiPoMII3iBHceRjaaZJ0WYP6VucIV5kiXOcMwVEFHVXQUQUdVdBRBR1V0FEFHVXQUQUdVdBRBR1V0FEF
# DATA HVXQUQUdVdBRBR1V0FEFHVXQUQUdVdBRBR1V0FEFHVXQUQUdVfCFoQpGnWg48q9IFfS7QdQMXyKqYHkFeiemYBGe12ta8LxO3cDz
# DATA OsV8HQ6i5nC0hr7XDmz6XjOn77V7G/M2L5ipX+96gd/xfL/pdTter1X1W4HnN30qL7oadLxut4Tl67R73X53HZavEGXeh7kaX3qh
# DATA hTz0Oya+rSJgsh61B501zwdBkD/fqOfIxO5uzzfklSq/WkGeX7s932xZ8W9Y+b3j+1tdC/nYbHQu+36/bZe3n8e/sWP87foiZcuP
# DATA N3d7vN2xk2/DHnfMfnlEJb/du+z7i7lX3+H1l4FESiPRkEjpyyxI5KATDjt+ERJpHjGQyKDe6Ld6BUhk0G922q0cEjmoD+vDkYFE
# DATA NgftbreZQyJH/rDdHd04JHKG/ryaPTzN1znkCOVxdA3rDoHl6tA2F9sP5rXaIiyYPvIyms1gWr9mD4vKcDuYGrSLiva9FYp9p7Zy
# DATA diNWFiKqFz0UF1FKUN+jsuTxrrlWa1tUQ8/OFnWbp3e1FPNGz1qxT77gaC0BHbfsUFD7ESQd1Yx+mEYHEL3cTGk0+VApJXeL6Vcu
# DATA 5MrW8mJniikysQdXqomYT8EuOcUhOAqko0A6CqSjQDoKpKNAOgqko0A6CqSjQDoKpKNAvmYUyFWI4zQ8ugtTj3p1nDGjJN+Rr/ok
# DATA CzJBIRc/shUF0KrepKepLryPDZF7/v6bX7zxv/+xxsTD+2t1BviZPQk/nMthA7yRgtk34QQI5399JeG8gxbPx5em4Ww5ClmnX051
# DATA yXlEas5zOfqGQ1WhIBeiR3QjH/4kcyCjoa1ASCyc0XGn793p+wtO3685wuXO4ruz+M9yFn+jHueNntEXRcSEDyLnx71lWPmu0ed8
# DATA /vIxt6HVKaMdZFRNFEZ8QFZZnXvT6b6iJOoWOmMHSC7op4Mw3Zq5YBQtO62ikuQ0nsm6V12pTvIqkNKbxH4b/nUzT9EMynZVuWy8
# DATA rUBM1O1rJvZBa13kAyvq3ULE67XW5qib8d6Our6o6tHeMDpKI5qqX5ACKyyTAvuaSUF7bfY37Nz3gy2Zv1GhU7cS1GjpIF5WdU5r
# DATA xGUeIt2ZSmvWR9wLZh/mTYv1TYZeFePIev80b+T2DSyyL/L5UtxRtpCuRJ4UPKOpEnkYfHP/VFCOhX5J6w6wfoUOjfoRMgKVgYj5
# DATA 3lzMhmGMuR8/Bg1hltQ4CU9l4JHi5LE/08IaR8uQRpxFFLE0uBK2+JI6ODK/cLReiYKsidEOAp6v3oH10qjoLGtnWV9gWZeMJmdV
# DATA O6u6YFVvZiu9SMpXxVYQmvwy4lc/BH/PqB1hFTvXOmI9GbjEK0a/SdDF0TTO5ixB431m6CpsvLNuTgTP3EnEZNaKp/dsYFSK5ljG
# DATA T+kR1J+yRV0kOK6IXZn7aOh/P1bSR+MkjX+WGMkbpeAfelk4Al8nSskoYgkmUyrZPMkV0lmiiEWj1CwiCrNTHnnHyTSCKA/PJsju
# DATA qwgnQ6R4cC+N1jSwxjAhuLPKKLewiqDUwLFVYcOUoWDbDCMd9w8hzFPsALF1Qqn2gAeZd4jGJlrOQjZsqF7VvLfjWYI6RM9ozK42
# DATA BGbRowUbkrykggxS/WiSwW2lelhlAkkVmPLLLFDoOmNibdr+1gYjTJIjncJPcaJZyk2qVWHOFmNBFuofcS5WZLgLIuE1OVVq+dzj
# DATA Zw+lpuXjht4UKfKvGeu/jiDVzonQiqQMPWVcmMdnwYDbRvYusm2J+kTkvKRVRKdKMgsj9XzKXZikUVTBRH62n5cHOwBz4zRcGMGw
# DATA fDyivKAKS2mUCafSU6Iswy7XCfaXcFXGEZrUrtCnGXzjHJtHFMCCjMN4CBpszXs34SaJ4c8ok0EEThmMI3R+qRWbFQISW1YX6r6a
# DATA uPRDVdhLS0HfrKcYJqm5IoPEqVzQIvtqclZ8nn8sTr304lRhWlXnKZDqz/K+jIkFUnNzqL2S2X+m9/mGPDEJTxU6vGiqZNQTXu87
# DATA Ax5CGdczjKfS/1zvG7BN8d7HeuxAmubRbBBPrvctvIf7Pd2C9BKa3YNe7/taArAYRWbPEDU8tiVn1NqK77qznNwYg/bVm185Eq2b
# DATA Wu0uGewmUq/8ROqy6NkXS0LY7Om9CYZpObOvnWC6Run4Yn7ppEBQEA1gdkMWdYW34HVfLB3ll1FCdEfcglfYWK6N8FxuVfLFTDZq
# DATA K5PjfNpb8Y6g0JzPaTAL80JMgLHVysxDBzQFtvVjRbUVk6ZsUZqV5t6EkidB298ioFuotWS9HEcXC0mjTk7DuQY57FQGa0r0kzRi
# DATA j3pBDTuLskyzCl8j0y0nXPXDh1FawFv917OvQZ06//nZXxSD6g+Mufrq/N8yrup/eud/D8zU2e9W4Vb/CbQqBlKBY/Xz83/vnf3+
# DATA /Ddnfz37+vzXFOjTinf2P+iWP9P3X+K7d/aNCQ3UrM3Aq1+Ca0X/dUyrl4FkS3UYz8PZQBWMJbBDxj3LEEHWVswjwRCuCciVq84J
# DATA czJxaczYacH90kiBeYZyKUEfJ/trhZFHPUfGnq6tCKu3sYEW7SRCZ+EAVrYBKp3AbdOryiVyc+wqSEIPS+9di6ziKmZufJcr3M3A
# DATA qmjUm6tNv6il2CScDMNT3kdI9eNh5IBVF5XbtXOq3kYz4BKYRynOirJiPY7jjRiwLacvPbLdoWWiVkGsLXh6vR9i+UdpNIwjeKPB
# DATA KKA+NUrh7cqXU1S/GM/IHFpKDnvTZSb9mZhhp0L1HsTzaIVitUtN3WzPlJre86JX7ZIIx61yVsCVrQCNqbrC4P9aeJ5uaeC/9nF/
# DATA p2F/11H/tgZ9qYzF1JtB/nk1lpugTxWT6I2jyRzWCRkeQDCbyOUJTseni/EUK7KS9AMZaiH0jhMuC/4AtDSyRVZHqcMEzegDMvDD
# DATA YxonM50dqUib8dYDrMmmS9ZSpPhPY8MF2s6eUrsj4GGKsEQd8ZkuGYg59hsGc3FxWAYB44l4LMjEhKii/Q8L5gXvA9SbKBQKiF/C
# DATA AgpATdE/2FMBO0+vkS8XCeShBkzqcoApB5hygKmbA0xdNI7sNJfZ3dS9Rav9Kkb79djsjiTlSFKOJOVIUo4k5UhSjiTlSFKOJOVI
# DATA Uo4k5UhSjiTlSFKOJOVIUo4k5UhSjiTlSFKOJOVIUo4k5UhSjiTlSFKOJOVIUi8MSardaLaDzhVJUqPRqDUcvEQkqeLK804cKTtT
# DATA grbX6HS/rDarfrfr+a1mNagH9Nf3fPqn2fPoazGHBlG332it8qB6HS8A9anh+fXutOoH9E9TfS2BoCiT64P+OhCU35OAKf0xDdwa
# DATA fdSw0EuNVtsqesVBEihREVwVNcOoFa1EtNnxvaBLyW55fiOYNrpVv9lS31biGfX7o7XxbKzWr3rLa7Za43bd/8hvBl6z649bWi/O
# DATA YmC1mkG0LsjVGttuUkwb/o96zWndC1pV+sfvTgN6DRVLF5+rQZe+rP5Qemm3224Egy0vvQzqSFqIRh1JY7NQR/16xw+GRdTRiP9n
# DATA o47oaziqF1BHI3846vs56qjTp6wKDepoGA5avVaOOuo2W3W/deOoI95hUmXTw2YJqcgWZ58+RkJP/kvN3J4M2EwjmRlsg/zwyJW/
# DATA eQf6UMEJ1zZOOFl6WwUUWWGvOuR5hJVtc/RQ9HBXOJG2NIJyAN4lxustj20fvDdCiKwStH2BnpjQm9NTKtwOSrWjiraYP5uT40hC
# DATA jiTkSEKOJORIQo4k5EhCjiTkSEKOJORIQo4k9NqThEaKI8RHryjBlZO7o+/IpfHpUFYPAfsh46aSmZ+ykC1Kvnpqrp5G1COry5o+
# DATA 9D7CZYLQ6E3KoSPmA31OMZSLJ0UQkfr9AQXPP2drf/5gBlEkGAv0Pr7vdO19nyWLcCLn+/iuj8LFuMZ+g73RmydvZm+eqpttzlB+
# DATA ksUdlXZHpYtHpa1zTe7AtDswvVnK7wU4SI0zqaO8moenXojfC/LmC1Y+kfqMEjAS4ag3FfwM2bzJJDnZftZ3Gj/i48fzNElG+vwx
# DATA dMZNQ6XxF1tRlmmUPYO2OY2I6SmSsqAsQfr0ccv7Xraco1ONhqpFx5khH5Flo8BGKQ14qJ2Q05vECyziJDR5yFgJW0Amg3Q57R9C
# DATA Gyae8XnszByqHsHZe8zndz+HC7egYJKyprsoaGeDJOEnBss5ZLblXPM2Be13YEOkp7KPzuMhKk/aCCLrUAFEkFyqsygaZro7k/Rm
# DATA i1TMZSrHcTIZ8llXxJwSS3NglgNHqYzw2xFFeXLKQuEm20zZibIOy6TjVLpWRec0YCI3SRZIOl3qJycTL5xkCR8M3ioR/j5Vb246
# DATA cmyb3hqlVuGxYHOfrU3OLn1znOlT9Ceoi+ieWdxngvO96MdrHiuq5z35ABtSIsijxxM+mYuz8VnNe4fVmrnuehpQg+pAkUeoSG04
# DATA xEYgDsscQ1Sq/uHiIlF3zjmO8wkNJEZXENtRcf7dw1EavIyaTjjl19FAx6WjJOEHy4UULrbVzNVpYNGJN+e9cWUSKwoXqsXPIFPP
# DATA cJzMKJo/lPDEv8Ihkmk4sbMkNue5w3R6NV3zt0WIGllHjf/SwuZohNetbP4pMh+FN4JzWnqnGxA0z9mWIniEomBD1Mv1CG5A09wo
# DATA M7JRM1NtD90sxrwbkDi/z92+sZWUmsTtKYG/Oge580DcjMLNKIozinKVctMKN63Yefqwcfpxc9OKB8iKHIcj0dFTihdeG/A2EKXi
# DATA SKPL7Pny9o4uwmLqB0yHZS7kdI76VYCk9c1Yz9y1R7d8X3/x9r59UWTtB02ECxdzimd3XZybLSvKvV0JquxvZELJZLFDLNXtOeJV
# DATA fS+YVCtRszOzUSSkbomaOD3p54JXcodI6gdNLM2F3K6tdS6KaLAtohtBqDJ/xWhltbSXl4YqTS3OimJHRrP0fepbqHV4R2YuXvHa
# DATA 3W97pt56UzKpM6/RVPecwD9Ns3yaSEdHKTpKfkojszD9Fm4W38jdEX9VOmwyMzWQ05jVauOB6erwxuiRrJnoKQOWwTCpR1glKTOW
# DATA 57L6Mi1gmwmrTJ6WVQhM+vNpicROnT6ItAraDpTTV8f2dvQdZ3tv9+Y7Q/uVNLQvS9l5zkKovAM43yC7aoDaEBoWHQy1B9vohUoS
# DATA NlNonqt86kshK8j/vWamUUno9bqJRitSuWt5RjuI11r7qHMJW3yLIFyZhKOKIeiwlbXMxsrAKtVT7BSXklW7xd8aN+69n8ZYt8Eu
# DATA RfYi0iUw6uNHsGHY+y/nuZh2GBfNHZpAYhYYrVt2UaqaImQq+qTqIANv4VImT9GAoWmp5VE1VouJrh3vB1izQszJvivFXGR3zaIK
# DATA xY7XL0ybEI1RvSyjGKQ4Tobt2dZqEcun8tITziJuiTCa/Y6x5WNts4TpvxzfB1gJUgt0evocFcVRw+LCHi+ZTMyqH8VRwSexAoFF
# DATA sM0RpZety9fXRrvTIgeR4TYAh8diB/3Hs6/P/nT2zfkvzp4C+nP2h/PfMNQH9KBfMMPn5/Qb6EK/XYUHrTx89pfz3wA39Iuzv57/
# DATA /Oyrs9/Tj79mBtEfKx59+vrsj1V64imC9vieb+geeoeghTbChCh0vOUregPd6IBCL75F/UPol/E6MfcmihZ2WpEFQVySjlbtTk2j
# DATA I/CXtZyzLPyr+moG95RFmwuUaeqNtzKE3hmHompgSYY7jpBlXasu4bZJQuvK5eZoQrwhYJzMzY2fqwvrmUKjOO+m348XxhN8zTQh
# DATA gRqzvSC+Iovo87pzhHYpsWunCd33BLwOEHh1sexHpuTFgx9jD+3Uk53gNe+jhGrAzIAQqRCPofcOSQ+sEbCGB8yyUG12CfF5Ips+
# DATA UrgPp8xjFGcdG18Ca4RIbBketL1KbjZi1rSz54UO2p4EBw1yI/1lRnrNCbriAP96uM5ua3C/kbF9p6H9ciP7zQ/sUi1XcyDf6Hp7
# DATA reUmQEF5yiCiRQFkq3FewOOGzZp685+O79KknQ85MU5EFyAIMDH/znwTLIExbUVtCeW3TMMZpS4z6ZbUmuAFMzSdUxc2W+yEDYJ9
# DATA tcBBfuQDhTRKqbfLB/1Ylvv1whaCYTE5hhgZAlAaSVYZJPKpAJUr1kifAPOTjARdjBdRRfQeLJDsmD0e8cijVvVQaCgn1FFgzyDa
# DATA IG8wSJF32iHq6EGOHuToQTdID9ptTNkRan6xzXvLxvtVbPdnNd0dO8ixgxw7yLGDHDvIsYMcO8ixgxw7yLGDHDvIsYMcO8ixgxw7
# DATA yLGDHDvIsYMcO8ixgxw7yLGDHDvIsYMcO8ixgxw7yLGDXhh2UFQf1UfBFdlBfrcxaNVfInbQ6rrzTvygI5Nk3kVYZM0MW9FwVN/E
# DATA mrn31iBOYf8L2CeQhCiwT4dFGljewPcVYahwe7vevOB2i/NDYXt0j0e/Vf0e/a3Tv73W9+n6xO/V6VrbC/wmXWtXO71q0AzGzd5H
# DATA AYBFne6405z6jVa12Rq318WkGWyKuAIY3TkqVKBm4CMy9IZp1ffqx4Lo2ZKN0ajfa69HJNVXqifFuRXUx+1m/SOkutlrHTfr02a9
# DATA WW3W6VMZQdQLO/32uqCDy9OApM5rGpA0H4sGRMkYdBpFGpDfaXSbPZsGFNSb3dawQAMKuq1GO8xpQP3RsDkcGhpQq9Hpd6OcBjQa
# DATA DUbdwU3TgJRRst7xodNasrXUSISNa9XtVohHN2PYye8tg3/MRGndpEi70TDXrTRrTeb/BMz/WV2PahcjpY0bq5sW24UTQjkeptUj
# DATA TI3Bs6gPo6OKtfZuf/aC3vxR5VuNeqvT7rPbb7+yOaTeJYPSUc7m0eCyVCJt88J7uGJSWStymxfH1VK4+ISrGf0wjQ6GYfpwM3so
# DATA z+GKHfXNNkfJ7JU6xLaTIwk5kpAjCTmSkCMJOZKQIwk5kpAjCTmSkCMJOZLQa0sSUqSfz6xjXfl57uI5rjKGR7hBcsqb8kjThbAj
# DATA AM0IdJ7BtMYwn3eSKQugrxzy5uNtWEoStaoQB1WSmTq+pgVpiwfFpI3KRE6ftHBnnN0Z58JRG3fU2R11vuJR543igzdzBPr9mLUu
# DATA +CwtuyDLp2f1UegXTW7jNvS41eCCqkP1VUmGI5V7g+lFEs3mWdNh5VeMSHN3rTZ3yxZp9v16Uaa5tUXqmgc/SLqo3osvvCW2rFFR
# DATA lntygWv90FsJd6a2hHSbl3s+pb5P4YW4nrx1J1EigWueaHN20dji3fEWafSQtSIvfKzFL7LNgCkMGpZPLj57R1Kzg1D1e7p+osp6
# DATA qLIvr0r1R1GYLSEajYO1gzDNBaofLESSj3qSJFnIDXKsGbI+4RHEnuGPOqExq+b9kAe3SXRMlQYdIDrVqQqbm7GC0ySpER5KEzIn
# DATA a96nvAAgppE8wHqLStiPhpNTFDQVRLwoyFcDplU4ti/nSL10iTPeOHId4oA9NBzNeA79QLLYqM5y4Wc0O1tm80j0D1kxO5wtRxiI
# DATA U8ylJEBwkYbxaIQryz7rqccYpykwxu6ss/WUCAElYbGzwPWrcs7XyVs789UyX529+lrYq5fVtn7Okj28rp0vwG7Xtr5PoxEbjWxA
# DATA sh2b5VIUzFHItmhc37bYz0uhd3ETstar9frapa3XajpdVd46X/TX5phYFMr2iUAW5TqXi1qz+XNKJo0ANXkpiF5X894W3SCaJYlY
# DATA TRTOYKJ8DhEhkXvJMLgxZlQIjlzdYEaR1RVr4Wey4RKyecioe0hv0MSQy1WcH2ghFqPqZNzhr5fiSSFnnDHkjKFSn+q8ec6bV+w7
# DATA N1pRz1nQkHnAABcnk4no7JeB3aqdhFku4Vfz3hdON1tJ6+T5Clp+8zQZREPQuEWKLkm/XEbiy3kWPvf92ECdDY13QSOoZgJO44Wg
# DATA pmUk9VjLhWOw5EZ+FC6PaNT8lIZhTQuscABilshyj8I7oMMIRyM4xdhVkrs8zTj9wQzj/UL4tUtFi4im/WgIEbRh1E9pRBYqMg+h
# DATA LAKIHUpbUdYy+ufyjIIDDqkqwA/KmoLKNMi0dQHlOPhrUnGWKvFpsgGGk6gfpjXvQ9hPiCZVUsrcUIHAhiE6GCAR+hMRXhuzMN46
# DATA IUP+mFmqheKSzUC9/pIKPh5B520aYe0vHmyFkY9Z1Zorz2wBDw57kU2SPweUIxmNvCMasnQSZZ+kN1lSpg5CKDZyPQZePTwJT8Ux
# DATA peOpyjDTbh3OPh4HKBgVc8qXTBS44V9iFe5DJWsIKcyUTxaoimuqcwGssUD9Yd6I16cIRBu9zirVPNLI2AKZcOaD50LVEJwyLYvM
# DATA mIQSH4NMwvJP8YR+rmg/FCcgh+0MwjQ9ZeXG+5RnIfvtVEBCmBd4nOb4HIcsyZdn0sdRzKkSP7FSv4RL7ihJhpa7Xd6aUEOj0XAk
# DATA ba1YhFeDfaMtn7LqI/Ux37007Btxu27Yt9jlsTRwpV8YzwCOj4Y3AP1+G8x7JReqto7cAOP785IK6Y28ieHeH6JpSB9D45psy8mE
# DATA mHO9b+NTQJ8bSiJWiOZhnHoP4S0OV1N3k0TxV2OqY8FlkjAdHsG3buNl/rPCyHzDUBfQYb72zp6e/dP5z89/s8qT+a903x/OfifI
# DATA F76LyS+gwnxz9mf6+BWzZJ5WPMOXeXr2p7OvgKt5ip+q+qmnHn39SgdFt9ELf3n+KwWXoXic/73HjJnfgU0DCo2DyrwEmMaZZnat
# DATA +OLmUQIEtBq5FyIw/Y6er4nf44i3bWOQU9Aw1u5leeGc3GUGPoqeHgqXs+FWysx9viV/s2PMFGZzpme4bcrMarncHGOGE2ju+h6E
# DATA xCmvJ6PyfUNoPxugF/b7LtLw9DrRMtQGMrKxUxEwp5kGrDGeiaEgHFxme1FdO1XGdELDmMx4PrEnpg6Zr3gKIvfxI4/rhfcpbw8Q
# DATA t+0R9keu21Qu7ENotGulb5TZLFqwpjn2ftAYnq0wZLbVvM12ykobel78mG3Rd/QYN6Q/05CucTJXGslfD5/s7Y3iNzCI7zSG7ziE
# DATA 3/QILnWxnOx82+RzbDE3gZQpJzQnyxjNiTzmlJtRqBAzcL+x3AA8XTMq0kxWa5EMw8+QYRXoieM4ZVwMCktjZSjlYYaLODJuiMJY
# DATA DZWB9RIQmVNYW+zblRCPZJsZpgn0sT8Rj9tRGvF5AMl2vdVN+dZp9IcUAn+/kEdyiPGfsyS1bIYiZiRKHSzGwWIcLOYGYTEXjBm7
# DATA IeEvtGxv1Ty/Eqf6mYxzx4dxfBjHh3F8GMeHcXwYx4dxfBjHh3F8GMeHcXwYx4dxfBjHh3F8GMeHcXwYx4dxfBjHh3F8GMeHcXwY
# DATA x4dxfBjHh3F8mBeGD9PuNPvN+hX5MKPRKBiOXiI+THnNeSc6jJ0tjbrntzrjRqdxHPSa36fvxRzpdzqd5nA1O1uB53frlKGd46DZ
# DATA /j59Lz5HdbPbV1wWLkspKym4U+GwBAVdiWavWMbNZiki/ajXKQcYBI2rBjis94JOeyXAbnC9MWw0/euNYVOqzvXF0C4UKstryEOr
# DATA UC4Z4IZStgrlWmJoF8q1xNAulGuJoV0oDQn8+lrKJQO8uKVcSwztQrmWGNqFci0xLBRKq3m9LeWSAV7cUq4lhoVCuY4YFgrlOmLY
# DATA Cqy23CuWst8ohagupCr3y4N/O2qUUFztXjNsroWlrYOOtVoNCzom4acGCWYZKTrUFX5a0Hq2AFrdnhVAq3f5AApJ6LWfMQm7BXAZ
# DATA npnYaJpnJuaexTMLm+1mIyryzEb8P5tnRl970ajAM4u6w7A/zHlmnX673WobntmwPfDDbs4z6w6aYXDjPDPl9VAbGsxMSJzxZEuy
# DATA g8LyXuhFajM/6/JK5ZpF/2LIZY7Z9yIyYuOwIjEp7UVZE5ztiORFnmLoat334miY6cv6XXL6dpocH0W7LRW1dlmctkItrzrbPhNd
# DATA R4pu50Am8iurh37DWiRW9/pB0QujqyvvsRyHw+SEF2Kw4lb3dJ2z8rbHDgueFZvZ3Ib9dHoSq3K7vpmBZufpBR4NK7dKdZIny4ED
# DATA oTkQmgOhORCaA6E5EJoDoTkQmgOhORCaA6E5ENrrDUJ7rGp3TAV3V6HM8JkSXeEkqYs4uoeMkNtFdfMudWxUZ/ZQteK79cP4LX7i
# DATA MH7zzf3HuMi3HcajvZN4RtYV2WGn80XyXRjxnwKKMf0Rh7P/WLeg+V0GrTEIZK8Z9Jq9difote9wlPa/w39UFPp3YQP+kGbvjUA6
# DATA Xn//cJg8lneUX7HX3z98wrKZe/0f139y7y69a/9QJN9w4dsc9Jv+4ZOIjHWlBWfFRfhvHOCeisc+3a3UR+dLGvVUt/dEoofKcVf9
# DATA /NMknu1xb0U5CD4cGsOb6kdZoN3bCyt9Ko7wzX6FrMfcklepncR3N1qzkxgFM4ntCnlXmgeVG71J0kYzR7yWbXyZEeAAOdr9HFsJ
# DATA ZsO9Sbx/KHlU/J1XpWnirrrie359v3gDhmAVn3dwb01OT1Nle6KRdebop1NWccoqq8oq5jCwU1dx6iqXVFfZKIp9A6orn0KOSyuA
# DATA TBLW+2DNLiO88nyFvG6DTsemAF0VT5CXjDgxF2Dp1EN5j6S+F9RkV4h0vgWka9s4On8LjI7NF1R9fMD8A0VRgtGpe3IYnX5ohRHX
# DATA lqAeiYm0mSXHY9J78K5fdKcvasBkgV50IyvsfnYSTagTveDeoK7unZEJXLp3d3QdV2+0ci7Rl5Za97ea0SDjUUbWQzQ0UntGXoeM
# DATA LCOLI+Z7WWqHSXK7yfawiI2XJcsULN+R4FSgvy1WIzQccj6deC3ISJwpGR9K4qmnDt0bsRh654pazLhxz9b/oTQ1qGAmulDYIrNz
# DATA 09qoq0pgshNt7lVQDMnHEmd0OqNz1ejMrQtndTqrM7vQnnxuWn8PGDXEkWQXN5CjqP7G6DRAsmk8SBNLAm/JFqrSvwupdc0GoFus
# DATA at+ZQTFvUWow1JASlpIbJNNplA5iPQay5ZpGWGnBxoWdtf84ZfN7D8Rb1T+FzyzCLhMMowagJOxfGkyxl2KN/pY677Zqoir3LGoi
# DATA f1LGqbI59I+5AWSu8MFnoNMiDkfFT5YbRHBQR36t7Wl8vuAEqc9Fy9O6w3SU9lMrhh2cpmgLYE3JffE2O1Ab5++yAbfprkEC4gY1
# DATA l2O++Z386+ZnuBLh7k/wYYt1KQOztvDEhWqbJBgktph3hRLGng9p0OpoZ450oE7JsDvYYy2rOyov7bwo4YB4N4xp5+IM5tqULvn2
# DATA 4J9//n+3TSrK0VY5q0wxJVVJFSRdnIoxRvYdj0xg8mhLkgchmvZVYXcNeb7o3R8OIY1HTwsLaIDGRrWfJ4rMTwZ7BQ+y+SejIxNR
# DATA NDEZtim9pea9Hc5yKuBsKJNS+el9EGHwkkadBllDCdLHTq6Ur6Xac4XsbW7O3kJdlFyGvSw2PCVkEU50Pt9nngwNEvOK5JqeWHOu
# DATA hdgEsIinkQ1lm0+WPHum+eVSLHomICmPvnc/niKvRmStZWPAqtj0xiU/wNd5krGJXvPeA3wRrxnG2WCZoYA4JFmUvI5cNu3tsvm7
# DATA OW9Vy9W5ih6fut4FPug8fRd7e0Kv8b//sQFW0pDyBIsHM/DMT4APorq1pLyjspApfub5VKA9OC1k/WUQ0Ryk5n1CXTZNve9LxZbq
# DATA CwIUc5L4vKIH98ah97Z9B84QiruEZ9Jqk1fN+z59jbgiU/lfW0W+chZv7yEK2fw5DbQ0yaAgUp3HxpwdUcOvip5TzgKDdiDVL1Sm
# DATA ueShrPhk0hfI3aik8NOECj2OCaE8+DG0S3EyMGPd0tAEEs40lKoiL6PfsIQiceNMP4pF8hQ8suM4oRaiHg6l53kxOo/2pTqPf72M
# DATA eeVTD966ECSDqf7SGIeKzRWQbSBtGMl0CNnuZZN4TvnJjYP7FoDOeHrTZ31T7RGEgipGdVFi5a7JO4oWUnSchVhIzJJphAtHy4g7
# DATA Djwdz2SiQv3S4lq6j5sf/N7hcQlMpNhUbdMtiltjcZJIhyxZi944E4SmCCVHcUqj2wlC0fWYZWxjo/BL03U0/VS1fLIFWdUZ76Su
# DATA CacVqbc+VpM7ChtPTBMs5PLcAT0FYyeke4HNWs7corkiy8a2uWKuSGbdowamFni1kLCM32IqWuYrNbcxNzwplNpFrKdXweWSz7ac
# DATA y8W5XNYQFJyX5dX3smx0oLxQRIXCUYHVkXJisxa8SbzAEWdWQmEkJiiWajRhF0z+IJ8n4Yx93giGF1mr/CJ+knXwQ1Yl+ejLvbeo
# DATA Iy23N330vXC8ritn+axz+XIhnEh3WMZJrBxJl/Y7SFA75G2ns4GOilJ5zP1utpg9l8caMIf1HH/h9KiVmHFw7wHb5KaKAIIczk7N
# DATA qtX3kxPgkE9V3fmuxxeW8E6RVfVd7x26P6LOFMYQjJDcEv4uJmHxlCvcLDuR2cMCG+08Xjpm/f1YEV01mwow2pBsM/BxoV1Ghlc/
# DATA eRSt8KKKteX9mIGZ7ICk7FgOFpRIKfbXYcnJ5lwmzOO2KZf/ibGU/x3IyfPfeiBSnv3+7I9nX60SLkt3/jUHXuL+inf+C7r2lP77
# DATA zdkfvfNfn//y7Gs8gXuf4vY/CQKTbv/m7Pfn/w7wSo8+/Jxu+7Pc6jiWL4HJ5mXs90/VAUTT1yPRPDnnnqDmyW55L1vKhFU25DO3
# DATA Vh7kBowxgwcT9gjMZBo1woSVGxz8ZFhaGPPm+S0Uy7dFBkxQGQ5hWTThpNHfNsCyVCQ3R6+EHXBsdfeq4jEFXX4qP6GqoHniU1Ul
# DATA UQVn8IhdK9CSd0uMw4z9NUD/KEe5smAc1HLXErx2vOV92KVHYqsYdnSFu80hHGwaEGT6LDG0341Ho3iADfnYtiw7biLNANe3ziIK
# DATA g35Oxd2/QrTcqQ5uNkuKret5cS13SoQDXLqx/hnGeo23vPwQ/5p4aG5peL/u0X2nwf3SY/utDe1SLQvZkGMun1u7uQnIZSGNmJKH
# DATA xYRhW6kkAMFO5wsZCucpuh5w6sZhP+aFv0WmS42eODrCAstDqgaZzOOpHqtlbky3ZWQ2I/AkpgqJ5S8h/GVQ/Et3RVwiGw0TENMG
# DATA iv+EunqcYcMaiEI76tjzttcVrKSqSdWCsSALQhxLlkhBKMhDZABWPrPqPEqrbNVRCSyn3MseWmYCbkSUq2SwbTQbHAPTMTAdA/NG
# DATA GJg7DzA7zWQuYQ/fnml/Fcv+mgx7B8d0cEwHx3RwTAfHdHBMB8d0cEwHx3RwTAfHdHBMB8d0cEwHx3RwTAfHdHBMB8d0cEwHx3Rw
# DATA TAfHdHBMB8d0cEwHx3RwzBcGjhm0GxEzt64Ix+xFvZcIjllYed6JjGmh3vxWTllsFKlinVKGN+R3yfEisqzZbdc7azIc2M12MG42
# DATA p9Vm0/O7Y0GdWeCxMo0sB481VqBvdSuuJaTaSlzr7U1x7ffb3Va4EtcgoLh229cV154V1053a1wVzG5tXJv9Lv9ajGvDr3sB1d/r
# DATA iWujey11oDPotkN/Ja7N+nXWgWbnWurAsBMO26v1tdm7zjrQal9LHei0u/1OfyWure6z1wErOAqt2e6M2436sd/+freEx6UOddC6
# DATA GsSO+lINsZNu2YLYNdvUbXR3gNgNR60ixK4ZNYf1HGLX6rRbnZaB2A26g6g/yCF2jV6r2wluHGKHPVRVWd3Qo2vT4tdZtLou25z5
# DATA /Zfj0pWdro18qbUtTlcOmc+p7OZLbW/zpeo5YR7o6qqM8jXraQYmCmrK1Wut0OHgU8OCk/ynwb8bLlw8ozrldYUMJ5WhWaTTqVqz
# DATA jrJ3NWKcrBioRdy1RWBce2V/wUbYnFUCW2zT1Rrj+HKOL+f4co4v5/hyji/n+HKOL+f4co4v5/hyji/n+HKGL8fqjQolxz5PSvR3
# DATA 5Csf3qOvd/SvAppjY/OLN95Tx/+G5iQkDusxyYyZbIMonuxx6ExWE/3MrPYF/W92f4HbJFj1gwKwqW8Mh9HhDmnC7fEJnjWB3ymH
# DATA wsFYj2Y8IhjcmdNBdAftNx+0dwfsX+ED9pdVP3xhDt7njq3taogs8sanWWc0QpFlAYHlMX3fpoX4fM/pv2QnVi9S38kdlTehjVhS
# DATA IbhmYcSyjsMFqoj3FaCHxRAoV6kNZRyYkRb6ZAlvDO9g8I6WgIL1I2aDhZbqN3QPaLKOcdp7n64mELnX6ociE8WIBqWuQPU20QLO
# DATA cqKcq7oSb0D285lynEPvS4XA06hz0aO5TCuUynRZ9XCrklKpycF7bcMvWHX7QUIj3VidVpfNr1p8++MQcotGpj+NTsIUB+qVoOhJ
# DATA OJGj+aGqoN4ECWFOAjvQ4zAVYQqJfPE89CJkkdQfLBdIkjkEXdYoX42jzmVDbZhJSTDFhjsIbMLw8GUYhUZKPcxYpUEJa4WMp+HT
# DATA 6vFiS/Q+APXmEpFDL2IiZglp6IoEAcyMCj9MFcAgmWSKx2hoOhxM+tA7QS/E8cVp+y2R/EResyYTX6MT63YozkZ2NnLZRi7VKidL
# DATA 5WSprmIdb7TGb0yu6nsxtwE2EkIl9KQVbCjHHlraVbesiXgbcGBx7jAEB9ZjGiHnoFK5HQ+sHzO9k7mQE26b9YsQwY26GLI7UILF
# DATA 6wRkr3Ew8SV2CeHlF0RYP28ibC7kEW6tj7DEUUXZL0e5vjnO7Bqzqy6q1h6/+I54pvYvzOYihVl/z+McrI1z66pR1g4zuuGj9T63
# DATA C2KcB2AibV2y8npttK1Yq+qjI90qxHkjEPntZTwZWiMaeouXl4v8kQzDMrqHcz56wwvYei5lwMnce/EpEaUOJckf00MReFz3vVF0
# DATA wi5tdhwvjEcVOlhrhOSPUhaqM+P/LDrWzCsjAfZD1a/rrhDAtRBYdOyfZYO85v2fZCkMed5DPaPVzZLZP8TOIFFd04xMcWVLR8qN
# DATA hVIkb2bTA1M6mmYIBy5ebJqyvcJGuD26OiPcGeErjuoVa8vZ4c4O32ZWvziysWqw082AfWBoC7YKPHA7NFaZVnicD3VKorSSq5jy
# DATA UGMETqHXib1VGHUQ+FwkOzG8Kici2txIgCjZMhbMjBwG2aS5emV6cv5SbtiQwO+jUuhZBI3OQ8dP3oWfPGMfKp4Qb+rmO8WdLFMI
# DATA fNpCTtZuRcv5B4rti09QznPjkhjJzzYjJHW+CkTyfsFzD5c2VRlAadMIxVQCpqbREeWY8c+yH1aQWPSfEebOSn2WamTGN9Jts0VM
# DATA E2ZZgeC5cs17J0zTU4iyJrOiezwNmdnIVusiPVVeYhZlxR7IVCIGn3ky035yNXmwG2m++qObSL66ZPZAyii/Jfkmf7WKIl3gzb7c
# DATA MEMwTs1M5JlYoXlVvmQxv7e5mHWjUMVsnP75kozsteAeQxf0h+hiYeSEwmRNyWLXqxyZhawXLQBRiualFwk8myQnk1ORhE5Z2Rid
# DATA K8Yis9RDZc4b+NBBjk2v+ExFuD1pt1aIhV7mkuX46RaYcd5f6RYr6BElkZxGYLHSkDMbKjFwLklNAsvb6TAOaRY4ZQN1FC1OaTxd
# DATA Io9j5bwKdUtWuDEzmedFFxpdcz5aZpZwaPB9hBkp+9zYA4YFwliAa8/cNrcl9NbK9cp98IOd+2CqsAu6Rei6kTdj9nb28HSl/9Vs
# DATA GylWWDUiNM1Gxjiaxtmcta+9D7nHDNlLMAnTI8hKQ5lxlmlO/UmSSv8qbUU611EIRDLcAtfSLten6sXvVr+/c7eqxi6yryCvj6SG
# DATA aqAahppgbZqkrHuju0y0sSh2KLwtfDoO4jgoSsW3jo9mcPXIRFRbmHCssDQ4jM50nrJePfW6Uswcj+toezsk7KXoWt+9VNeqZd1h
# DATA mAzT8AQNhHcnTOKRtVCtnGv6DmU9RCG2hVLmQPZe7B3bnsGMhgtLmzyD5aLmscvPrGWr7QGDNJwjz/lIqN5PoT1kz1auW1N4pRK9
# DATA XYD3M3loX32fYo7AHEQ02seDrIjA/Pr852dfnf357On5r+nzL8CzBLbyz/TnF+BYnv9cX1yHxfzm7E/0/6/P/nj+D4y7PP83DMX8
# DATA syAxOejf05VfMz/zj0zO9M5/df73AGie/4rpmBT22Z/O/z0F8Sv6+1t6J4WAm35BP/yBfqZ7/ole8vTsL+e/cZjMl8JRim1p6K5U
# DATA t6hqHgedHYgvioewPk0PKvz9CJvd4UUdAFmnQC3HIXuuQjNFMD7X0IMXbjCuee89mk9gvlBnisJCrJVBk6sDb+VnvjOh8UtaIuLn
# DATA CJq2D1X3GbdN0FwplJtjaHKlNHdhayGvqSsP4Apxk6p2nJjbH/BXD6JdywlEwq4ToBlnEhV4D2VnY4QzvyH4QafRwtEzdym7GyBn
# DATA 8iopr5bHU0x1EZqpAKp7WkR8RG2AeszH+r2PojBbquVbyrEloFBMV0DJUV9pfM8Zc4a8RTyJlMs6ZX85GUjD5WQVp7lbldxs6ZTb
# DATA 2vMiau6WDofUdHbBTdgFmrV5FXPgtVhOvTVT4PotgZ0MgUvZAbdnBki9LOWCjdt80drUTXA4S8nnRMNNzexCE5kyfFMrFOeZcwwn
# DATA xkTxOO2DNJxbvPRslP9yAJ9+GzJDfDkaX5k9jBYD+L13xXHmI75lMVDksnz4n4qdMMS+PKhGQaGG4utJiHyypmAP8MI3xS0ZVpUf
# DATA H+08y3gfmcd7uMQW0U5FGpWQXPFHKVonb5Rgt1VoltEcetOhNx1680bQmzuNNTtNgS5jNN/mFOAqM4DrmgA49KZDbzr0pkNvOvSm
# DATA Q2869KZDbzr0pkNvOvSmQ2869KZDbzr0pkNvOvSmQ2869KZDbzr0pkNvOvSmQ2869KZDbzr0pkNvvjDozUarOWwHV0VvtkedUfcl
# DATA Qm+WFp93gm9S6DENi95AZMZ6nJeDU6Eb9vKMDZqiQ8W/BO0iv7A3HEXd1VwGEzBojP2g9WW167V8L/A9v97jP41Wtdv0yD6u9hrV
# DATA VrXTq/pB2wt61U7g+R360igWRrvbbfUieUcxzkEzyONM78vj3A7yKAtZ1KoYrUY7WkVZdnqe3+qMu91J1a9T9Dpf9iiy7UY1oB/a
# DATA 3arvd6udaqtV9Zu9Um3xo0Hkl5iH/XY4CoN1zMPmuqQ0JfYDFeOOBWFsWkkp1vFhdzDoryEy+l2vEXS/7LarTUpJo+fVKU1dzw/q
# DATA X1apLBpNSqHvldCKYdRpttfGrdXt5HGjgK1s7lk1o16kRfrNQbN9BVIjNz1NapRWbJEaKS6D3i6kxsIVkBqDqBsNLVJj2B52hjmp
# DATA sTMMhqFFavRbg27jxkmN2Nte3WbS0IBr+bjENjYPaUvGhhIilSO/NCNudr/t4V8yNTw2N/Ig9HhrLTHKr2xO7uj1D6z4rZ1LcIgQ
# DATA FLZ9/nXczXMQbZoeWgZ4wRWqyv1yYEVxf+VQyFKetChP6N+G/FtYrWq2DDay0/r2WsKjGIuUZpnz5cul1gLWeoTjRlTjhZVB25Pr
# DATA a4FkSmAX387hlIqGZ7GlyZDjQDoOpONAOg6k40A6DqTjQDoOpONAOg6k40A6DqTjQI5CNO67flV4irLpGPBHsmY08vGBPu9+Eil/
# DATA JuMe9xQuEhfwhASFqvo+Nvrt+YxkHEyF/VgIRM1VrVDkysXBiIgsxJPVcXo5au/N42gQ6dOIOCMH/2Ef5VHkQOYnb9zpcHc6fOfT
# DATA 4eUjWu6guDsovl13+4U5QP4gfiRNqELj0+wUS/6xHLK0wTfmyKMlmoomM5FDnXj24eqpZxwF5Z5XnZ0eIRQ5mZmFk+iS8tlG1VJc
# DATA j9zE6eZkCteofc7bKWfvopzNO0q4KuLD5vvQX+K2H9HfLZrZNCguBH/4iXx8GfSyTR5cUiTy7c0ikSo3RSDybZziHOFYNwalXA8S
# DATA m2U8stypquA8OE7ng8tKU55TCHhO4pGcYE4WTIHIeGiCCwrBeKOI6tEEBhFNWBI5eMwp0USUZ9HOvGqWvLNjlrynNUFpTNYZ8nY4
# DATA ga4Aa/VydKkx8QVz5lqWcFhW1BvBu0xPI6d4gYTndWDO0dCMP9QEyfqL5WQ+AptdR8bodnDJfPnR5nyRFqVqynLIlkleR2ZhSnNS
# DATA b0ZzWg/9DINBId2KBQnIDOTwH1g0XKWimRDKIEiQMUeEPs/R3x+fauPmOdaRf7VjHfkkWbKGxU+XR3l+aLXpuVafTqYjbBoBpoE6
# DATA gTmmV2gQTDNSGKMhmRo0mA0o4ybjZIkTbzXvM0wIWFuBlRLErjuahD8zQh3PqD6bd4WXzJ9PtmjP6k5Vcojm195cX5Ic+iRNjlEH
# DATA KM00uzmKDDqWN8lRpQmXA6hw3J95yxmSq3sYCAQzEBVYpgmU9yEVzYvLz7HdfLpju+FKrZRbLGQtKzJMkyXUx5dQqpiI8ZDyGVn4
# DATA +0HFGg51zwKl5Vi6UjbLbCHeUKoL9dfl/LhdKdvXRaEhN7PdJNxNwneehLsZ9ys+4944mX6hJdt4H4vZ0SJUVt7Vcu8tatDlEtb7
# DATA L5Fcs62uK1sprc2hciGc8Ley/NnKvkipMIMEO4fkZaezgY6JOml87wcr2yr1JH9VXc56jL9wagrj+6RA9gJ8glkvrDg2pOpJE3jt
# DATA X8gf4qPTPNy8oLp1L5Oc047Ctp7ZUiXVt2A4mA1UWwy1f/7H/6jNCH7lOBApO7EgvUU0mfDURYEmRNHre7A/M+9IrKxwwbSIIVTY
# DATA aMYyXk77urhCLx2fLsZTZc2ywcpzg6NYfhbLj8XIMG2GqJml+eXxnkeIdClp5ArlVhrlgnNGDVCvQAtmKEdXnITpiqZusUAZamQM
# DATA RyZWvYayWlYwzmpzVtvOVttKfXNrJ27t5AoW20bj8CbFdxnQNFI6+izmjrzmhfiCBu/zF4TfZgjgnJ9nr7WsLJ2Irci25bBwrbCm
# DATA IUv9dPl96n/57Ddf8fYG04tA9/pR052ZC2aFQQ6IlJHxfhF0byPj6zV/8/qL2lBgR1Yu7RJb87CJbn7FxLd3ndFVGy/o94+0/u8i
# DATA WRSqxN63L4q2CcREO79yQTbXrXg3tkZbma9mwUx2pfIql1T5iLd4mKaQWYgo1LB7b8mZYBVntT3Zdqrll6T/iQVVNaexWxmxdySI
# DATA Z4Q/iW3FKK28C7BVqX+Ymf0laHzGuP1InKlGqZmRwyfjeBLl/UQMtdoF9uqkLHlrVjqoNUe5eDPLA6sVTpi4snFFtr6RqVuqAnqn
# DATA lTdUqD7TG2jtYHSpVt9DqVpO6X5sD87DYT3pQTiDdvCcEhDjnGKYznmhlz3HQJHDXXkyjsSAzzsupAxC09yv8cIWGR01T8HskEIj
# DATA NJ0t59T1KP3gorj0Hc7318V6tiBcPEfnOYTN4fpHZnB9ff5L4V2BnPXN2T8pNBfgXGBxfbVK4PqvdNtTALoErXX2P6xw6BMDtv5E
# DATA 92jI1l/Of3P2Pw2l6+wruvEpv+v35/+OCV046eCd/e7s67P/QZUmnDjg1kth/7Nxb23dACowTYB3naKf4Ppm7BgmtWaQJ6cuidX7
# DATA qGecier3CeuGy9KFlt2uKG7oERr7OOyjn5LZuqhhc52B2Hk/wgxhG2zrc7rLRMihtgqmf94z3DZtq1QqN8faEtq34T/xlmzrrdad
# DATA P82ouPWNxQp2nYitUMBWGq6gFgglMQ6vdUFxXTta65OQjE78TLFu1Sv1ep1HDcoA6qJq3ic0gBirhwkWPOkah3OsBeud/4uwf4hI
# DATA Co46MxAKFFf0iAYCnC0oM7QurG6bzZRi43le8KwLE+C4WW54v+7hXTOzLj+qvx7OvFsc0a97QN9pPN95OL+V0VxqYyHpto/uRWpD
# DATA N8HIKiScET+ZYrbbyaRJd5ipRbMhFs36sMxD7CSuUEJjIH2o0cSUhEkMltRsqF87CuMJ/JWDEKwiZgsVk4XRNjQZPaUBTi8wx7Ns
# DATA jiTBRUotZFdaVh4yawZk8j6KP1OaeCv6mOoc3Ct0kc+U82lz9m/MsMLHc9glE6LmoThgkyEjs8QsyMxZcUrRg1My3h7BUxYPQ3WS
# DATA PRLDMMqwDzHOxljHDOHVGAh3BemKR9iAOBhH09Djne9M4ZrzWORQWg6l5VBaN4jSunAM2mmqs6P5fHuzgKtMAq5hDuDQWQ6d5dBZ
# DATA Dp3l0FkOneXQWQ6d5dBZDp3l0FkOneXQWQ6d5dBZDp3l0FkOneXQWQ6d5dBZDp3l0FkOneXQWQ6d5dBZDp31wqCzgmaz3royOqs5
# DATA 6ow6LxE6q7DqvBM4izOW49LjjBM0U90vyFG0/W4xwxu93uYcrzd6zVWQUy9gJJUKyoJLderdXq+/Di7VkEAGccoSVOplbYst1eB4
# DATA 8oG5bpEmNew1Ou11z7daOz3f6/fa/XXPd5u7PN+N+p3QL2fCNGg2vCBoV6lit3pcvYNpw29V/cD3+FpVrlV9v1H1m51qp+P5Xd8O
# DATA mjeMlvBc3WF32FuXg4wLK9X8Ts9rNnyq8Hi1Vx/36qXgTN6tBNe7AgKLm5BGYElrtBBYjXa73wmugsCqR70otBBYAQXUyRFYwbA+
# DATA bOYIrKDb9tu9m0dg0UyoSr/vNGkPAhori36rwkgjI54O0eMDcob7pG04ZXzqBOsAUu1aWReIt5w8LrlMrDFg5e6wZPYbU7yrTPH8
# DATA AT1ql+eB6+Z82kvYZS+hrA7CT7hmsa1dTERxIUDmiJ498VGGXP6EGQbXrNiVMVxrPT66ohY9DJugXcZ5rKIDv7E1/eLvF+RT8UVt
# DATA JIf9ioWtJ5ufN+P0Ba/ZMIXbjPUyFXwnHNe2yrt5Wl+qzOvq5HJy4eSSo+A4X47z5ThfjvPlOF+O8+U4X47z5ThfjvPlOF+O8/Wa
# DATA cb5QF9QJ+Wh4aFO/Flgy5YxA6u5KXU+W6SBCBeFadRiP2MhUDfNeqw6DZzEGrOC9NE0Qx3eV5YXmRSYP9dHpkfTJ5rV3S8a0NSdg
# DATA E7aCyUVF6F/Y1sjlsC/MMRMIfaeu4os32K4R89x7Pz/6T3b0abamL9g/fMI2+uM8NthqOYpnlB2KasYyokr34dgK/h10PtRc4VKt
# DATA 4BzjNJQzVFzqeGsfe5RpfskvsuKnBHWpq8FJqI8TY596JzizqKxP+o0jSNWacx+ndqr6R/rlu9vsDi5DKp88XXfzlO0/LkRGxKhM
# DATA HLRIo3oTTgMiHmL1Hz4xxvwXb5jAa4gbvdVceJP6KlDY6Bq19vwY5B25UecGnz0qp1cl11S2re2F07mu8HYLhiZzeD0FxPay5Nme
# DATA 2NCDRTqhKd/f/Z18xWZA+rr/N38j3+lRytMv3niPEQ9v7D/eYHkro5u6wmzxgC32PSlUJ3Hv1BSupKbgVBRebRWFy6rbP1d1BeOA
# DATA lRSJWJ+l5L4IUd3ufaxluDmlfJB1CWnLeHNC3tVn93PlAYklHtr24ANut7zNC4tCG58qZIcYC1bby5+6g5hqHUI+GrtR4N6QmJQU
# DATA ArXq7eL2L5zYxEtwuJr/e83khKIoxnVzE8paI2upCZdVyfo8jZXpFs+Y1Ui2G4wZo5JldEBYuSyDBXwCIbPpUjQcTtlPXTEC+lIZ
# DATA VeXhioJRMhNFe0vTAxoHIVv0yWjBcKU0Yjc6E7gUcIsNfY8XBllvfBY9Yh+vUta4kGP0apyTNyE4484ZdzsZdyWlHKeZ5TSzLmHV
# DATA bTQdb0pL6wMRbKKKrebyyonA1Twn+9y2YuNtiNwrz4LOXJ30t/RODK04rm+Darp4ynCZnWUFgXXKyMmEPdoMQMBaMY9ufwMX0yH6
# DATA NPl0oC4oi1q+VeQPu8XVbT/2K0Gl8RMaFHWMNkjKK6cavesD/sRVtoggNreYvjV/aIUAHDCy4STxeCvJFvBwUwxvcA9Ld66AgjeK
# DATA yRsfVl51Xl4deUx5RF5K2UjrJM6WRuBsLq2moiTM/lV4HD6QLlapmYGwot2gaCYqH1jv7WRW1EIT1awQkBbbJaf0sWjAhOiZIJIm
# DATA p8oRapo7FK5EgIuePsHpLh46WXPKcv/VPFNcGBHJRl4OFktFYZrEU1zkjUYQrIJIHNMuoN2V6aiUKkI+FbHN5HxqIaVVdJ1ibqlX
# DATA +I3rUM35TM25WHb+1bBQ82HGmajORN3JRLVtEWegOgN1q+H5vMVePy40khkGukU8zaFMD2SZlAVQKxYFUFLnvadlECGwiOM7nF30
# DATA O5rKMOGxGrqcrBYaHlG8sOVsdmr0IHdUcOXomtgICYpqAQQdxSCgxkrtPmJ9S3Qea7x16sTxGktV9iiggvEnRQdSloz+MTeuzBWW
# DATA ngByPuJwVOxkz43pljaziszGB4b+yOeiXWndYbpE+6kVkxE7BzA6omOU++JtFiZapPYlb77L0rEVjKP5uiXkKIuPOO3v8qcttmuR
# DATA DS47CWyDRdHMN5mNhTLG7mpprFcAsOvcuCSA/fGTzQR2yVghsGMSF2lGunLan2oS+2fYMkopT5eZbPfiGjhj7VQlpIs5EMicegU6
# DATA xiaMEBsovP6SDF2lmBoPat67MQusLllo15vGGc8eZa8LtisxRZQ3gcg1bq28MiwkBiCI6HWp4rM9M9q+VIMumcH//A9/2pzDhdoo
# DATA Gc2Srmkkwr/wq8aDeGGQ9/xLTl9i7VsyqkVLNZnrU/cLqm0p6/ji8OoiFvv8/ogPhdPcYNqPj5bgPirXb0V3d4KKEvpjSMY+S/jG
# DATA Q/5NJuzXkaNXrKvTbLe6+nE4laoAKes866S2YIoDBVvZ5yuqttCpnkQLILFkd5N52mOMB3ovBn2cAi0rtK4ZlAHRIMj6o+hQ70lF
# DATA oTYomAby/Kvfv75U5RPWGceeUvHlMlpGOv8+xAwOkzaaQOdKzCdhzM4cvqCOm0cAQL8rDZLXJKTiZHlF5YCR9SMcLeD8pAycwYXE
# DATA AS3kKWB6I1AUaahEoV1L1TNd+yUz8oMtdU8NEpKH5RVKb5GGxzRunlAadGZ+qo4SjJVAdijVMiUbJhpmyiigXm62YHAcwoJdIvMT
# DATA asgz0zOoXnVKvUbGc8kYEo/WsmoOl1vESs49ovmvVuGG7fdc8/WzXfP1MybwWctVON+Yt261HJZGR9gPLgdEKCGZGjIw2uTq9Uby
# DATA PGNfRW4ZRqMR57DdD4T9jMWraYbG7h25R1Vn9KZi9cXobH8qu1lLGVo0EmTPom0kmCuSPWTX6t2FemLHzha16486osE4gX5WCH8p
# DATA laQuiNdi4c3G6FFJRDZB7z+dfXP+b86+PvufZ385/y24d+e/ABKP/vvN2e/OfyNovN+ffXX+87On+Hv2l7On579dJerZ4TAr7xdM
# DATA 48Oz35z/Gk+d/ZEuMm9P0Hv0988e3fL1+T/Qc389/yVweohBP41Oqga998fzX9Hf3+JnJu792aH1XgZvjdQ0mzcvU86HMVrpTLYF
# DATA g9jwQ+ObEeV7mGNkMQyh9MOWgqxv4PeHejtJGg3iubK5siX6I27t04TF+reS9N6ReFkNyMH0bC8Ncue2OXqrZXJzKD2pOvlK4qdS
# DATA lUTypHwzeiJrzTE6uRFaNu+onqtDF5QVMmHE26bRbOl4ejuU2bUj9cSs576cux54mcVv1icDQvduYs9zN/ZZ3i1RdU1OFNRHE85Z
# DATA Z03Qv3zoAIUWT6c4owOYEBW2gRFfqv5twQCXG9XzQuxdnAjH2HPj/DOO8xqpd6Xh/TVZgLmVof0GRvadBvbLjOu3M6xLlSzngIXW
# DATA e55N5yZIeuWk6kURcamGLDdZGhEze0hE/FfGxIpAsWRxVtZYRcniOFokc34myvhAe0Lm0mKcDLNdMHmfIg9lGascI8peeAh44y4l
# DATA fxpjg0lCVhn2bMlAn1cXemeYLVOAwUIWGKVMZn9+Rbvt0wjth1N0yiUjOjhCAoRjhUl1ujJk4URwXwM4qzXPzNHwHA3P0fBukIa3
# DATA y+ix01xlV2P3Vu32q5jt12G1Oyqeo+I5Kp6j4jkqnqPiOSqeo+I5Kp6j4jkqnqPiOSqeo+I5Kp6j4jkqnqPiOSqeo+I5Kp6j4jkq
# DATA nqPiOSqeo+I5Kp6j4r0wVLxWO+g3Olel4o1GvWj4ElHxyivPO4HxCtS3Rs+ixjXqDUN98zudIjduNOj2VN5QBGMaWU0QjTyIZrOe
# DATA l00gtD05PBX0CuF1msGgMVgpqKDle0EQjINO/dhvNr+str2eX/UbLa8X0J96tYsv1V6wpuRW0XytgEJr1cfN9pedjtfxq02qB37z
# DATA AuqcCWwFExd01mZA1yL3UeStytlo5RnQKLz3W81B0G7UV6LcaNc9v+V/WaW0Nqm2VDv+tNWkuH9ZDXr6ypUT4AdXAN1xq9CgO2lg
# DATA Fuiu02w0ms0dQHfDUbsIuguHvUEzB9112q1eu2VAd8POoN63QHcdv+E3O7cAukOTqm63NzweXqxby3y470XUC8RhRQIuLeatoOIa
# DATA vGCWL5cVg1Z2y4qTSufQiiOy5O+3w1rngb/UoOqx763OhpN6Ri2BrU26cauuRtKY5UWEnApb0HXrtwqUiXarmLW1OWMGPr36Vd9G
# DATA g9uhFtyUKeLQbg7t5tBuDu3m0G4O7ebQbg7t5tBuDu3m0G4O7faaod1smJskmw9s3RWQ2hCn3N7Y/4584yVHxnIp5FmyCCdyP1rU
# DATA mx+Fi3GNZ5J7fHH/TcoBHEel9ygn2hwaM8s5375XeMcd+UY/ZtyLLJL3sR1vz7dD+VwOk1mBlN9ZCoafXTlypgliMgU0RzrcIWp3
# DATA iHrdIerSMR93nNodp77sceotwrc3dcxaWgHbwdBrl1VWc8z6OQp53AZ1YaiOZ6uaga/e3tG+krTVzW7GDoxcAF49lfdN6nvOLCiy
# DATA GKYxC9C1FLaBff+y6IQtFrwWVfM3C9/KeAopZjOsoRhwqFry/4Lo6udNfM0FE2G/vS7CXSvCwe7x5UEVlDaOB0eTrlwQSfVQrtur
# DATA vhc4ECsx9K0Ydu0IFqO3kffwjmpRkRENenlxD++wlcfDGAO8MDnRB5I/GEFlE30IH8PPeKBD28vILJlX2KdJrXQCr//k1IOSJipZ
# DATA DF6eGEXirRc6l9Q6PjdOzVCFOKQgKECYOWMd4CCB0aNC0sfBmT/BNTnKFlh35ykVSzBN2SK2RABwGpwVGHkZdYiTZJ6s3RzaYgAw
# DATA 2dD7Zck00h3RhzR7OcYMacwADG7fA+wOVglCtPO+5mJAw6tzsNhBYp0lu92SdXbrK263XhYK+9zlgXjB3FoIXjX6JgVJQKb+ZCy6
# DATA rfgHfT5GClNkK0P1uasKvSQKHDeBTV1RQLpucuoaNan18NTdlBBL9Q9ZbdMUWET67RRpVcM6q7bnCtK8p0dPhJaZwKk0P5VtsQjz
# DATA rOFpQdIl9LBRYjlV9hkqGH3IImUoITCpSUUDRaGT3+cbjFFSluDmOH/KYq8S5YiyWMf4AzNRi3kOSFEVPaNFnFZYmZ1jo1XZCxaa
# DATA Vry38QFskCIosgJwBGNLtD/Bwtz2WD8AdEXFmrcpRUMd8fe0xNWQZreIDSWBc6/CU76Kd4rNsqLqhB5jkRxFULGqeZZRnbCy6NRj
# DATA UIGivmyKrn7haoxfIwEbu09ylqazNNdZmoVxynlMncf0IgP1+QtTSgwypayYJsmUVeq4QeTylJOJNJW1Iok1Vc8r4qyoyGAE3Tk0
# DATA I6xPMxWMPSuerN6pdsXLiJejgL3PVoJSd5Q2qZYbOUz0fHPGbsIFHE6wgUEEsh0UbBcomFhctmm16U7j52a6i/6y+X6t0sm5qj5v
# DATA vlvLeBbNjxcfI5bn3yU5Lv6B396MctGFISiXH8wi6kzm7Fqs4siitgyxvuG3vCN7JSNo1umCciN+HikCGU1BsFVuclohux17f/tU
# DATA L0b4usB4iZCxhyTDmoec6si4h4CxdRJmY9FS1RY6XZpMsuvg4NxK/n12knD+DWmcmhdzr1Ev5l6za+XeA16oQbK5r1WZBMVSAJ0X
# DATA LEcp0phyl/iFJxHwRdis66lDuCJUeg25VWiDl8+w1uYMsxq05Nn3qE+l2L2f8lR2LhOYPN+CUq1rdFpWvi1gSvEyGRtO8Wy5wJAD
# DATA 0dJJcWLFIwbDeqjm0exKUfDMJOwYOxonL0DetS+Rd++gCqQiK5GvDxayr1TtGkG9lH0VnkqziXokRZHRPFWUUkHsk9aI/ejDNDzB
# DATA Vl69NMB6s/nSwLPkmd2HXzLLPtqcX/looBB+ycNQW9c6k95nToVwI4DuE3rhMdkcxkwnC/chNbyJQjsNWXV4mgyZ5OeNsQ7sfSpC
# DATA wcy0whWzfGJWZTIa6CnXWZMXLfo6ss0ezC5d04LNGZcPjJJxxjFQNNB0Hj7AVeV1mXl+l2rYUOdV6DXavGeIKiq2BbILgaZLyhEj
# DATA thtj5LmuJd7RMlZ8L+bGKu8Nm4285fxFRXi9Kg6JHOM1iheQmLU5Xv/v2dPzX5795exrMLaeemd/OPv92dOz/372NaO3vl4Fdv1n
# DATA +ul3Z9+AsXX+b3GL9/+z93ZNbhxnvudc61OUPeHobhMAUQAKL6SaWoqiXs5IMg9JW3vW0ioKQKFRIoCCUEA327IiJGvmzEyM4zhi
# DATA dyI24sTZndjYi73ZC409WsuypbnYL9D9Fc4n2ef/PJlZWXhr9CubZMomCRSqsvI9n3wy8/8TJNfRvx/9mX767vjL438qIBwKk8L6
# DATA nn77k3f89/ipSHd8S7//ht/07dH39OZvjr9gPBiQXYoA9hv6+icKkH5yzK7nwaWSQf3QZQ5tHpD0IWkMHyg1SY0LnMw6U1a/lw6F
# DATA MiyaCnxxH9O/eCguSGm3cKH2cPocHAAolPBT4DDyRlTe7tlRGvlJOFiL8bqPlfFueGhi6jhetq9FdRBXDfJaUiqXR/JStTBbMnqk
# DATA quUgpnhODufvl9qob34nV0kvEuYFl6GKiWjhy878SMfLAb02K7oLZ3o9ijLQQcaCmACSqrssQ+XgkvNS9DbYCyQywgxVMKeI4fk5
# DATA xNeS93bc1bNj6t1kei3OKZXSBbLXyZVxtT2z2MqeFdrr5FQ4tJczBy7eHNC0r7NZAS/FastVWQCXYQBsNP6fcvi/mtFfKuZCLljQ
# DATA r2vWqC6DA7aQfEBNsTaUMud9fcoKXAOhesVJmE/nO1O1NYK3QLBISBxOzJt0UJxyWXBCcSrXwUZksMfs64U/CBtwUrjeokk4KChL
# DATA jga0uDtD8UVdLkYYaxOqIbyG3M0wTxxhbQqYHSMwDyhQcXnAOUVtHK6ZeFSkLGYQu0fWxTQeRdpRxctnCB3L0DBbCmKz0IvFDjEg
# DATA KEcJc5QwRwm7PErYhkPORnOgTU3nq50GnGUWcBGTAEcKc6QwRwpzpDBHCnOkMEcKc6QwRwpzpDBHCnOkMEcKc6QwRwpzpDBHCnOk
# DATA MEcKc6QwRwpzpDBHCnOkMEcKc6QwRwpzpLBrQwqrtatd/vlMpLBGL+i1nyNS2MLS80aoMDtf/MCr+s1+UG/N0abq1Ds2o2W0qWpT
# DATA cojLSMqgxoqUQsry/ZxSz3zZVXy78Oq5/DfvzIUetPxLDL1VzwKvtXKBS6qywP1q3YaA5QJv9Zrtdm8+8HrQuvDQc6C3mrDYBFLm
# DATA 1zPQW9DMBRAFYdisLjQLetzz/eZ+LRhUmp7fOIFAtrpONM4AIOPGpgFk0m5zALIgbNU3AJDlrgBAFnQ7vXIGIKt3gqhZNgCyTq9T
# DATA 6UYWgCyodVqtSweQ6Qa6Fj5V8gNNIcvdb0ZHvUAQbEIbyweheWNZP65zasGRaT3axqLMkmc2XRYo1ZUFUrEdD5XSkjVhnw2i3Jtz
# DATA HgWxDPAcz1+MN8kPyE6ASbXEI1kxHknJlPllliULfcHCCyq39VyLem8/s0vmot9ke24ZF63VauVpaFhlXk0py5VbYa4s1lg7+Rvn
# DATA fA/GfegwZA5D5jBkDkPmMGQOQ+YwZA5D5jBkDkPmMGQOQ/aSYchQFyiU7iAqRLxM1N0tF9jpzp/GZHZH6e4vPyrAobof7bIFW0BH
# DATA +wA/7aJK3jYVmk+XwTqabO98Fve25aGdz3TQ1EJhgoSjTlQakYW6U1Svum0Hf5tVnfXBjW2J3s5tdAUfbj3OjrF1BSf2uTXHwT5C
# DATA /X4pRRz7WPNepJ+eoqSykgdNjCfbqreCPrGknxIw6t7YHavd++lPYdjdpvQh8Ffpt53P+Ond8W0+k0Fxoh9/xNcoHktTk0uwyfrb
# DATA JsNvS63DhJ4bfVbDKM/fVPrOlPcKCadP/hjlZ+8xDknlz19OKPpM8KD8iBPJPrHlb3+++nVMeutE8WB7m5JaRJp3brJpC8ibyhKK
# DATA CSXZ1AtqSJz6Ertxdz7LKox1WeJu30cZZ3PxshqkYolclRxSY8HOZ1mGoehQnDFlY/yqIuexpBvSGd+4oW8ujWdkmnymYn5L7sQp
# DATA O7qvwBGhifUHOHX337/4Z3WmEdi8+Ia/Q10MRWIh+KK/syZsHI+0w36I45K8/LEY+udZXfhc1RGeTOo2uViV1QO3c7X/ttSzXcxg
# DATA ddWzbihUgnK+RU1mI5ESFkIfVwduZXThtXUGbtbm1VMTnCE96SkuX7u7sGp+lgNz/cy6JvEQKqtZe1CJQlR0kswccEm0+AxKPKD5
# DATA kOlTdQ00j8lYsZOLNAV7EI9ourgsUKyk0UPRXCY5ZozTmTijzoTTl3jx9SVOS5K5DroTvLKS89evx8m8h0PwIHJAfFUfnA738Kpp
# DATA MkwmNDNby5S5jqIVz88R7ssgzSxqbFw0amaZiMkZWTNebolIqjSvsN3xy1oaWDCbRk6MXqZugYCn1JNM5MMWen9CVllBXE+iZY/I
# DATA G8tbVvOSMWaRgOsJ66E/m0xZ6itW7x3TyD8S/YRESX0YEfs1Qh8nKY++QEf0cw3HmVDOhNrQhJrrX51olxPtsobflcbXdRDzen0W
# DATA g6mVl60yUl5viS6U3ZQw8oyjBA3toJ/kRihBCOgBrOTdhYgNio41dUKZCyv4WPSEmmM4iHtQvIHoNpwPIiE1iqKuxoydlp9iIqqA
# DATA D0pOG9LqhSVKWg6esgk8ZZhI0bHevfq8DogyYTeaSODL59V3Y7ePcLPv8afVd2pzR/GF+PPzgE6xc++UKvlNGI6rdfKzssixLNir
# DATA p8XxeVaUjWwYvybJbK+fNYZPGPbOEh4alzQbkfHIWlTZhmm05/0kZm2rDpuHnj5BD6txxmJzY5bvhbFJcdiLphdBGThH/gWny783
# DATA ovSJx852Cy0AbVwFdzLpZck4cYWnzDO0TYeDcPCE8krLB3J4uG02AKabUY1eNOIyYPE2nILwurOJFtelQepimBZZMzwtnKGyPt+y
# DATA Vi359jqN8bLvj5k6s9jUPmVbUZ2LopVChlg9GoFlIXnJ0nSymJAqeleUTkve3zAQI+r0R/Gns8goKFIlpQkdWAnTPqYd/ZBrIvJ1
# DATA qiruBeRm1k2dNi9PqIO615Oc/IDqDqsgaqlmgyE1mURp5CrEFqpCjRokPFm4nSeQgpwzZVXuhSy7qJB/g0hNMjnblYacEfXu5Yfh
# DATA Z9WC66drwa+HA7Yj1FQhslk0MA44Q9LZGBMwSmA4aR+quUFHdBZlp3PJ45Ua5C7LkU8U241yrRdFEFHEVIssiigdR52YibCifjk5
# DATA ZD1DMwkfRQcXkYP22HfaClhen4XZUKpgK6hcE3NRU3Bp2jXkrg2dvSL1mGlYJwSVhzLqgAxsmOrYQeH1ySJE/UKWsQooCx9SpYYO
# DATA 5D62iqk9NtcWqvICuTayIJxfw/k1NvRr5Guac2s4t8YZ14RWukAuTaNcVdkc/RWmOFVz49145qyMdd4NZjKu5NjzRm9e5sDub3Vy
# DATA UV8zk17e1WCPnOaKnvVyLmXnI7EzhL4lvZ6YBmFX7IKcQ4J3tdDPbCOZXmdbbU/ZUX4R3cJHvKEfr5BIqadNz6i/m3l+VY5vYhiY
# DATA kHFPxgufucPFYfhU7ijLOblozEfzVvtOeJMMp8Qq042jqp42UdXfTVQrJ0bVb24cVdn2g8jyp5Pipm/PYmeumPjVlkXPt6JXWRM7
# DATA tSpo/FlyLoCnf+Dt3eR9ikMyseVGNj8mwzuvirRCloU4FmLXwexSrs6NaXCfynHcmxJEVpGNb8ZqH+bSCgeOmEQ0GexapnZO4f8/
# DATA kW3a0RNUmpj3MEoakI5MGQ5CGt4B2xnTo2SgYQamqEDZLFYDKRWdUE22hJJq9v5aSEsMycmgyDBL3rFFb+mCh5kITRRelILXjX/1
# DATA qxhDCrtXRrMUgvzpIdm+yTDNvKh2zPrRYHzCwvFcqWaLx7ZfNVsGlvyXPVv0+AN8yEr8TIHJVi5plNHUqj5iw3KJvRxWucU6nE3I
# DATA JiaTzqYd/jeGF34D2mCeQXj8W/y9SDv8r0dfM4/wz0c/HP3BO/7b46+Ovj/67vg/05M/0CfFLWTGIYiFEjiH7DEQ8WtgFI+/oBt+
# DATA f/yP9NB3uO2Ho3+jcPSTfzj6AbjEbxmDSEE65uHzMMMw1SubWHCFB/EEOUrPFJS/kjscjcRg4SRDd5YIk0X0gEpRaAQwrAzBg3pS
# DATA bfSM46hDs/F1cMOHehsDDQCMVnNoQ2syoQvsquGGC6VyeWhDVUf0beBsaOIO/7JwP7avWB3uo6Sn9rRcONqQI5ADG8YpV3aHNdys
# DATA 2C4ca3j/6XiAXibUzpBh0p0NQpDXkylr9pS8D9D3c9+V7fPixS9sjKdnzf4nisNsyD1lKtug4EJJpqFeywpHgo5ZABqeXAVXWy3z
# DATA LetZ4QxPToPDGbqR/hwjveYWnmWAfzk8hVc2uF/82L7R0H7Kkf1qBnaplnN5YDELn1XLuQw44VwqsQIAEpDi/MUdK7H6nON8gkJx
# DATA aSqoHGhrehN1iuLhzdeyrVhLdMNKGrFXdD7fNiQSGi9rFrt0mnR4xZHHY42KY34c15IuzbVHqYl+NJskXjhk/BsP+RGZDXEnxtJ4
# DATA zibIWQDRUxwsRuDdCN4otaNarRWS9UDF+V4UpogQ23adKVwxYiSyV0codbK2roq6PTuU+uVohY5W6GiFl0Ur3HCo2Whqs6llfJU2
# DATA /llM/Iuw8B2r0LEKHavQsQodq9CxCh2r0LEKHavQsQodq9CxCh2r0LEKHavQsQodq9CxCh2r0LEKHavQsQodq9CxCh2r0LEKHavQ
# DATA sQqvDasw8Gu1oHNGVmHU7flR4zliFc4tPJ+aVBj4XtUv7xdbrU/9RrHa8BoB/d2vBpVPay2v4tUrXrWx32rlcqnjt6ud3jzGjsKq
# DATA L8XY1RbIhnLSTwB+rTzAL6j6cwS/WjMrazm2lhH8omYUdhbBiRYfsBnkgq9UW/ngW9WVoZtk5kKvlYM1oQdnCt0ukabv1WqN/Vpr
# DATA SF1rsdbar7U2zml/EUbY8L3Ab/TrQTAXSifotNudpSjK02MHpd1o7KA0QQs7WO8GzUb3ROxg2Gv36jnsYJf+7lYs7GC3HjQCgx1s
# DATA dzq1ds3CDlaCWrN66dhBs00Nwv97G83X13D7xL71FuwibY7Pvc0MlGrq9VZE3U0cFiR+SwGGgVqJqyzQ+rCwuPCCObe7bTTqAsnP
# DATA u8nc83zYAV5d/thhsnW6cQ4F2nRCpoiRmw/qTjhvqFjYwHxk7c0FekRXy17lZd5eWUzJJ60C3yf/pf7YM+71xMG5bC3M58kas2Vt
# DATA ktmecMBBBxx0wEEHHHTAQQccdMBBBxx0wEEHHHTAQQccfMmAgzbfTZItXgwhpfFRcUR/56fN8o1KuUAzS/XTARfhjkzZNObrvhyS
# DATA 4YNuaGQ3+Fdw6TpDBBx5/9//5rXK+NaNonHpQ/pvBNoahXtnt/zah1sfsJY6n6PjhRoEQj9KECWe8lCEJSxz+AZx8dqHuJfpeGE7
# DATA RYg75il84ne9Yx9lk9R5UTqFHzm65f333/w/iMxC2rerlfINucrinugaEKRGmTmEmDvbfdLZbnem+0U/031aUth1OOs952Jbjwl7
# DATA F03DPFHy3kO1t7VdlsLBnunp8OfnaORlUMDmD7NfNANsURLgrASwvL9Wn9V/l6ldUhHkNb3I6Nq8Addj6HUT+iE94DPaD+CERNVi
# DATA KaB+GE9K3qN4yu4nLfguFVCEy2djOZ6sCjd3fD/MpIzGEG1MenwWORPNmVO4WSjnJxFM5dDI7cAmunqlm2d0CtZqQc4YcsbQvDG0
# DATA 0KM60RsnenOSGXU9xHAeSH1lokU3MfiLT5K2UcR5aLQbqBnGeyNF/lIaagofOaFhoQNxix5uFiWJNAR+Fe5RjcfhDfks3yE6NHBD
# DATA DmztliWaKRuDvx5DdQb+sUzJxubBsO9CVDsc7msz3BclBfokKulTbjWrYV/sdhRZaP64+l7enss9y2P+9DzAu6y8OCV35dEafpLO
# DATA VSGu3EOroNIV20qAK48PEhFrSmYQjAkhxyKQlSFaipZIRA0P2QslskxiHtK4tg8v8q8gzzIZ5tWLRKWIbL8kG+9CCMJQ7QhFo77H
# DATA hrI+cyqNRs0Olgs7LwpAm4U3sUmyBJoc01IOGBuwoMwZQw9YgtDn41+dueQeblxyD+WAuVjpuujehS2CjjBkNgAVx55S/06Z9BWN
# DATA WR1HsYTy6DAUH0v6iNo3FYFMUu9qPiM8hmpfFPemg2iqwAITFZd0nEzPX2S5lF1dmWW9ySnL7GfraGWqX5Iy+xkEiJCP7YQiZAOi
# DATA WJpIr6NoQbM9YWRR7lInjotJj6wRw9PqRQeiOaUHt6lIwuNOWdzhkj5g+hszV0yj49Jvz9LD85dWPk3PQXG9v3FxvR8C3M6LGdTX
# DATA ZzyqtC9a+qYxUK+3B3/4k+hQrP12CAUtr58MpWFhcjDi0FijbuRRQU1ACwMqB7wqdsD34qeCj2NoQlaY88Jv5y+0fMqurNCyUfiU
# DATA ZfZ4dZnp8Vz1iqIciGtZeYk/AvvwMQxQE0qFFTgQRwzLI3fUOMHeOO8ul2+P8V3UCUGEDOOeWJ44NuWNZ3x4jsUTRkC7XEC/l8X9
# DATA +pdIZdMSeT9SynUYPqbqJ0W4lPNBkR5gpDmJtSFCfYnHx7vQAg5FkFDAgKrVcP/GM2sEALObh7I41UYKSlf07y6gzSwm5EzFdLWE
# DATA uXNhTF4GP5sVhHO0OUfbvKPNrlLOx+Z8bGdcbFzpk7skwWmZkstMDyMgKjdsTONie4ZQg0siz+U8WXrvCex93mSN5acm75vhmbD6
# DATA /QTQWRaK6a6sSxk17iTUWX1DDtuB9pYZcBfPC9Suve3O8ETAnQSQAe7UdwtwtxQb58tlDY4rbwy5k908cBfigzDGhIIMlWLOqzkH
# DATA onog8x7qEBZ8do0yY7+wrd07wEIm7y9qlFd7+XyfH3kcPUVP1LWeol/WPFbjx96muw/tZ2rlNW7ClYg6bZpiNy1ZatPnF1Jnu+4O
# DATA +hSK9wlZnqPosGRLPitdZ+kE4BA6SDyfW1o4UbA4vWFtTNMkZbpj1Zk6C4oTplc8cFPQxh0vDg3uW8Rjr9z9Wl2bX6y2nXkMuKQC
# DATA q1bKXO+sFk591EzDL9We3E6+pkJvWsmwUyhahb1AFv5T6fpGFMeBTBVZNXs8mwD0LgvbScr6qZZA9gYQuRfEeM4QctSLRJ1J2Jta
# DATA CLn39LXi8d8d/XD85fFvAJE7+sMiOu5fluLf6Ms39NRXx18cf4nLHv3zDV38Pf/9NcBxdOW7o6+P/94g4b49+kYppEPhawztVBqy
# DATA HSbu2pv6bJmHnqkz3n8I90PvfjeWs1gieq/2lfDstzeJo1GXOhD+dpBMBl1j/cPzPRuL7xSuBHGdDQ6ZrpvApS0UUXYaZAsUqufB
# DATA U9FTamjdtQi51yGgwVoTHv8tPAnHkctmBKZTuGqO3PKiuTyYXJ+iw+SCDE7N9VVfPwkmdy8USfDLAMrx5iuyHelfGhPEdYXRHA3G
# DATA AeU2K7oLB8pJnoVs5ozQucm8ykyntGGjJlND6aDIctEVhRf4aHhDv8vW9t4spEYxjahveyNOnxRg/dDT9x783EvHkSJl4Pg7pU2p
# DATA wszYBoJrcboBbW55HV1t4ixtg9cFO7c8MQ4956yHS7IeNJbuzEbDS+FCvDqD4ZLshY3MhVNaC1dnLEglXZYZxlC4ng3tMih2VjYA
# DATA NIdF4m40BoeKTBkzUJsc4tn8imzpJMPhDN01FvDewQyiww4LlhRJKV86kT3iTyJ2UIj3DxmWqs32NNJTkfH1XjzhU7RpujHhDiCt
# DATA VPlmNUyMMmSfLMKJ+DnUrz2aK8d8wIF3BL2XfEIjmsfJ61AGJr1pyXuo4y0HFBQsbN4JvGC3yFkBjSAzmhZMMkN+QBcH0sF9yuS4
# DATA I95jTvtI3DW8lzMaMUcHJ+TRugAiU1WCctUx7xzzzjHvLpF5t+HodaaDXevM8iufaVyER/Ws8wwHwHMAPAfAcwA8B8BzADwHwHMA
# DATA PAfAcwA8B8BzADwHwHMAPAfAcwA8B8BzADwHwHMAPAfAcwA8B8BzADwHwHMAPAfAcwC8awPAq/jVbrVydgBe9bkC4C1bgd6Igmfx
# DATA 4ioZjk5Oo2X53phTKA2aueyqBa1GEM2R1SoVKoDaGrKa9erWmV/drLQr9erZX12pn/nV1WajXeue/dXV6plfXa+0qrXG2V9dKz+z
# DATA sq41nllZB7VnVtZ1/5mVda5dt5pXmeG5dn26V583w3Pt+nSvPm+G59r16V597sZVfmZlnWvXV1vWuXZ9tWWda9dXW9Z2u64E9avM
# DATA cLtdn/LV581wu12f8tXnzXC7XZ/y1eduXOVnVtZ2u77isrbb9RWXtd2ur7is7XZd9WtXaiq0zvzq82a43a5P+erzZrjdrk/56nM3
# DATA rvIzK2u7XV9xWdvt+orL2m7XV1LWtuuhUvaqjUo/qJf3G8Hb9DXvdGi060Gts/SxWq3Bj1Xri4/V4OhonMYcUxMQCy7v13NB+s1q
# DATA tbIYk6AceJUg6FfKw2rglfuV8lxutIMoaDeWItmbZ6KpVzOauvhzLJp6sxxGQT1PU/dbVb8S5Gjqc3x10NTbUavTy2jqQaVer7UN
# DATA TT1stXthOaOp1/ygUylfOk2dncHFNm/SN55OWWzXWPTM29oUh7X9zDwQ3SzFLVt20xs1GrxBE9szmYm+uNuxDj+rvIYPgm22LaNu
# DATA bctYCXS3Ql3PWpfiUk7LwCy76BrBxxL6YTc5uNWiH/Gn7KlS/LxErxrCBbZiCbayENz6PMwC9NRWU71/TZatzK/jJbsP1FqvrmFm
# DATA GUDtBc083YW5EwX55e3yati6XVJr3OHL6ho7udmv7qDqDqruoOoOqu6g6g6q7qDqDqruoOoOqu6g6g6q/pJB1TOLUWk3bO8Y+45S
# DATA 7T0U7Y9M+OO2EKu4y2ZbeXDIuHIRFSkOk260K+gKuijbbNGos2siMlGEDbJbCYJ6wFcxyxPZtHRXs9F5aqwQ5+o3NEoNSEfE4IKY
# DATA QphttymBx0MFG8l+qcsLkmkXIXNh4guqObeNUkpDdbRdLtRrOzCOcFBl++YvP1T/3dr96x/h3wkH89HNvQKVq8Vp57L1FuH0UBXY
# DATA /Ww/HMWDQXirUhgPZjTtT29VC5CMuxV8/kuOCk9jTVw+0nj6R7O9vSiVcZEFyLyHd9+7ZbDxnSgebOMNN+az56clv8k0+bfi1wVa
# DATA /zrL/2Q6vHOhSAAigEOTfASh+fHjWKDyfqmig0TnrFgiGBVE8AKaeiJ0yC9UdQaaeFPI803JXNY1SJSEINmigPScCZmGLF19bZ05
# DATA xRkc91ZYsp+ZiQYk0ubkaenprJLv3MbIAsfVnEYOxD5UAqDkYkvecIxlIPhxIS/Q4XTqnE7daXTq5sRcnGKdU6xbovmzmmVxXZTs
# DATA vPEE7ZQ1tPJxMlJ2d/OSbnszSONCmGmVdpsCW4zAm407sQoa8ztWY9ViVUyjnZeky6O1FuTozH39yp0HGJqoa9ERF2+4lpv6hYzb
# DATA SjEtI1/BBk6YUA8MIFA3WMYpsor+lAXqJbgUWr6ejPl6qnsbYrHQmlJqc0BsedaTjPOEshXFOYI2PiUlhnGtOYR85C/pcXSip4Co
# DATA iawXeirzMI1Uq5T6ON1vKLuI5fYypVs1NOr0PzKGlKcNKSjWAe8jSsU0HxbqicqhmHUsSt4vMHIuPNLpz6BbrPXHlLlS8njSkBto
# DATA BQ8sAFTx1BZyVOHMoiDjEgp90nOjj2XMSowIM6iYXmXOEqTrcuSu6uIlR1Svzo3F5MY0GSu2AdeVZMJqclA/S2djjNDYcgw9Z6pr
# DATA nahr9f/T8InAFWAVsj2Dydf4UBWqHlzCg/Aws6hkAJLYw1ftPY7YkanjxmDX0DLFGERsDzlct+LpumTz+/G2TxLKtDYGw5DrHM0b
# DATA dMLfhQfFs2x7rQrINKi8XqDQUFm0i6KEha0xlxxLyYVd6sJjQ7ZRgnI6ASJDp+FPeoKRCcpp1g0DOsOslRlTjal22pRT2UB9ziA5
# DATA ZK/vPGRNlMFefIGzbNRxBqozUE9joDpz9OUxR1eamddcWNle4F9EmA1ydqq0GPp72ucBCbaKslCzR1ivR6Gwrqv88vOlJnoS0MHa
# DATA yiG4Od4ic+dV6qDnW6o+jpbb5NUsz23yUkfNwgF/W9ZeFo+JSevvJHBLyRsPRx0dHaW+dOdnC6fM2INPNs8KIW/rWf7C6ZqDgOmN
# DATA NFor+3VlM/a18jTnjzbG2GBbLt6srDItD8y8jtnYsiUNg5MGe9ijerpgMF95AzNvjloOvjl8xXxdeH0Wo+Yv6m1LpVggdp1I+Bip
# DATA FxcoIpOITJewTVa3AnzMtXecfpWmoAnA/eqdR0MBflNuGhoyNzfW8g0VEXk/P2thGXBQ38dRMh5QC/2A1z2QF9n8g9XMFHFRZJJz
# DATA OuF5w3EaouJq0JuxFueR0hxlVXo6umryZ4x9zB50eSpmmswwsBNCZpyMJcEsRXVVqrTXROzBhIzIznR9xO7xeoOXwuI/1NFTF2Um
# DATA zRa4F6IqcR4hJw8mrJqdHIxoykY/xUPIoevKujQ292Sytxibl1Ck2HGTnRV/Vit+vso5P7PzM5/bgF85Xbg8P7Phic/zOAxW7Vpi
# DATA vq6Cv6xXfumH+0/Hsm+HV8HJlImSWap9rSfwjLNgTL9nXTIA3+ZJAGZ/Y6CxMfo/4G4QEcsDjPUNGWPZTBPmucJqlR2/Kcf9agax
# DATA WoeXaR5/XH0vSp3NNvbbr2EUL6aM19JN6vCNERPKMN9+K379RMS0FUw+D/RFE8/aScUSnIIzzav+CvpHUZUL2BNC7ZUyYX2kzeMW
# DATA dlpfyXjTJ0W3umlseSNH1oENqWOgvmMujtidY6PGp908Z1y+m9jd9VKymPQyjR3VDZjU9zUqmTuIScRrFtoz/fwCqs1agXTAg3A2
# DATA ovkQFgTSaZ5RbdLfBZyGzS5eI7AoQ+jZJyAzAyEtvUzJu4vL+zHZO/YiGVtC0dOOWs3wZD1CHXXoKWomNniEArA5TLFhjWcdPGMT
# DATA I4rXKpShNAljRW8CSzocS089V56ZA0X1jtkmklzGWu4Rg+RZ5CJnxS55NIdjWsJh4hW2eRATM626SST4KDXz88CJOkAlo8xgZGhn
# DATA qvA+ZhQ6mZP9os2aLGD2LI078PLEiYXMPvpvx18d/fH4n0C1Pvrz8W+Pvj/6+vh3HtjZ9MO/HX17/LtFevY/H/1w9Be67x+Ovj/+
# DATA Hd199Ed6+N/p3i+Pf1vw6NMP9OQfjn44/g0o2ghaSNpf0t/fHn3LHO0v6JF/pVtA0v6TR3eB1/1bCvZbCvZrPH30e4rWn/hJCuL3
# DATA 9Pf3wHIff+Ho2td/QkidWDKMiiDLCSJLc6e4r+pQMwUIb8DLwLxa/kCNEKG2aQuCBGPnFJlx40GkeGGKdkW930RD7ZkNlhmtayna
# DATA D/EQ9UGRQ2fn5ntZ93DV8GyrRC6PmK1qVWrN9PgCV8x0/u52FGbd9ev0hStjO6Kx/iJR2RQus6tjPZKprRULk7qXlJW9QaFdOCn7
# DATA Xj+BTn0IiDmNqSNtv1IGs9tJESW5N6FyW9gDLj5fsliok9qPBrcR1z5vkyL7LrW9VGEqvaHenHKa+rfagsla07NiX58YeYe9dsP6
# DATA OYd1jbc+3Wj+cnhur3Akv8iBfKNx/FTD+JWM4lITTdKz3b7PtKlcBqDapFG2h65KHnfeyuPD5VyQnZSUhj2WyginfUlDDxsh+7Jk
# DATA K6vPND0PhUw76R9O+8OswKy9kKHODYUsxlC8CZH6/cQz0RXwrmYuc2xGiSetZjmct+Td5R9ZoDsVMjErOssSlupVEVA6TcZkbfUV
# DATA BXcatpFhcsBOrIcsVQaQTfnViVPRp9BZ2oEzwvGlHV/a8aUvkS+90ZCy0XxlQ8P3amz3s5juF2C5O5C0A0k7kLQDSTuQtANJO5C0
# DATA A0k7kLQDSTuQtANJO5C0A0k7kLQDSTuQtANJO5C0A0k7kLQDSTuQtANJO5C0A0k7kLQDSV8bkHStUg2D4Iwg6V61V+4FzxFI2qw4
# DATA b0SPtvMDLtYg6NfLlf1qtfw2ff/VfD5GQWsJ3qrp+c1aP6jV95vAWzXzj3X8bqPrzz829GuBV6FHq+Wi3/AqVfrgVZvFWs2r0v/p
# DATA t0ax6dWqHuBZfrHa5GsV3B541ZZX9XE3Lpe9lldrFiu+/VbeCZlnW1W7QVgvL2NbLakbAeLT2Pcr84C2dr3ttzvLQqktwPhsSlo1
# DATA jwyWcC2AVz2rvtU8yTwKg0Z7IYaVSv38Maz41SyGQfWCY9hqXUAMm/Usho36xcaw2qicP4ZVbhKXVMo1aiTnjmGtWrm8Ug785vlj
# DATA GJSDyyvloOVfQAwbzQsu5dOA9GQQ0iA9Gc8skF6rFvjVVh6kN4/N4yvhPEiv121FQQbSq4dB1GgakF6n0e7SHN2A9FpkHVeblw7S
# DATA 4+2fxXXWfak6x6f73HpokUWXcwn5zfysR2cC21hw2VLeY9PjdrHSjfZ2ciHPEfreimhcj8OCxH3e+V1l17cseTOcb379XoXMk7VN
# DATA 19RK2nxnf27VSjqC8fTGo5zlbhwLOGKgfeHYGFY85RJQbZkDmv1wVnjKC7aI51O1KV8aKAzLK9HA8sry7VALrygh1mSzWrN8MlF1
# DATA Y7BLmKzioNNaDd3LSrhgl8maWcRibVPJtaqRcnavLxyeCqDWr5xGZQV1uvmogwA6CKCDADoIoIMAOgiggwA6CKCDADoIoIMAOgjg
# DATA SwYBRF1QE8Vdtk4LIQ59FiDhOymwDFv5tuQHnw7bldoSd//nXfxYRG25zYGIeMSuGt7UV4rbL8uFSqFWqFMfGffme0h1286Oftzc
# DATA fZtfZyri9qgQg/820t3ernrC6vV2bo/W5hIAcnrEyuKn3iOj5NPdO0/1G6QnoyvKzn2qujP6D/Q6e44xxtGx7Z3Pcjl5mw8Ba1uR
# DATA M3RnLlWj3TuUID5+CWOU5+1ofnwODkkoyclPhfmjoLlXUhC8HTbn8tPQD7fUeT90FFmt3KVRlyVk5ZQx1Udh4D2UQ8dIwpg6WMbc
# DATA mYRN2eIFcu9H6u07YvkvL5sTUjJN9vYGuZQUYmrnqEWSJA70l/j+kSkCBVRMdrlWats/7UDnEcndKezlfnqLJhFUsRMasiLKmFHn
# DATA UAqNX0NvK7/mN8u3qtXy7b3SHt0LY/EXuOEuG/XbOLVQUAHKNnRc3tF3R0/HyQiCbeHgYTgcP07yz5b9xWdvlMp1RIgSMqIi2t5D
# DATA YPqL3A0lvXjEK5u4kz1Q2/IpGW8vC7FBxSQF+EAykwUTAXfcxocbPjMbk57X5CLlxOtfftK8zXVx15rIoKQL1TJW4AQACTdKwnXt
# DATA czUnYWV8jWDU1eGzrO7fVlXjc90GeAo8xXYjLsK793YP4hFNrEp8qpzr5dPpr3+tLh5E7Sfx1P5Jeot7O9M+jdPe/cmEa7ccSbfG
# DATA aaSPs0jqwa9/jfng3XsUofAgjGn2x9mHfnqIcXJJZT5lK0rGViOS/lEayu3PebZv54mUkcQ5b14sHl8X0SNR4IH0oZzibkdeRNM0
# DATA 3Tap3zFT2SVdHZ+Piwc0rct1eigy85gMeTtWLClQVQpLgsQaPz1igrKe46x9TVq9BCM+NXOo1mnZOC2bZVo2+YPWTtTGidpsKmqz
# DATA UoD8ssRu7mPdhUdXqE2MIlu2RQvfPDsBtatQGRdTgC4/xgdvG8WR3hzGo9k0OknHWj9rOidzwUguK9XweUlo2RuiNKEr6ySs9TFf
# DATA ijYf14Vi/CG6LM7vhIUzqHR4Aa0vK01cnBSA3J/PGLOeZOWE+ZHNUl6ylrzhKVCZ78xnhPbgZFlhbs2Szg/6c+rW69/lb/4uP5/N
# DATA eLByqndVNn9XJfcufrB6qndVN39XNfcufrB2qnfVNn9XbUFq/U5wqncFm78ryL2LH6yf6l31zd9Vz72LH2yc6l2Nzd/VWNB/v9M0
# DATA 79L6KqYNr1RXt6evL4CYuh4qBOmilYis0Yb6vieCVsLRGZrKSQcmIyRmD8Am8yR9CKmlSa7LkxD8glcteAEPRw1QtKIRC6l62EHA
# DATA QQtQeGhIYFbEaKBa7j/10L8yzMCS/TLe9kxVioYpzBu0IhgGQYQpVuPp9cA2kDJ//sWEHLTVTZ3WT53cTOnFnCmdFsT6zGVBeXNX
# DATA ts/rMhCelvzmBXM7bfHSpbDOlThZ1hDkk4empQoXBTLja7Cy10Ac9TkRC9xQ3tzLdg5q40q8lnq+LCd2KHdoMg0VTagkGUPrrlJo
# DATA DScscgXHKBlDeJrMKrKvmH/Kay8i1jqWaTxv7YIOI+bpvKupgAdUQWXKjTyhp0KKB/SOfexEFCrQHthkLD9JL2dGDnT5tBj66XMR
# DATA Zh9rRs5px16lZPqzsZRy1dIZS85YWmYs5boq52Z+6d3MK42sZ6+prms+VeeQZaUP4QEY0X28GSnTWB9P0DQhAzzXyPZmND9mV/Mk
# DATA UhrYC/Le1FyMArilDJ6oKT7XoTnHcs5qWBRRN/fRuKqbMY9IVLpGXxnDZtLreeF+End59XOUxCm7xCdaU1u6gww8niVMK7qVvEc0
# DATA RHs9Ck1E1FNeJ5WjxBh8BxKXlPcvIpBDowVOPcusnVKjn03FcGMZOTC/u5oIhxiXvPeUzrY3jDuTZNxnB4zCx0Vhh93yeJ5yALrV
# DATA 6L6We+Izd0/ItsZIqcHrTHkUTcWMSDPp50GCjSxT0HxlA944ZKih1e1pgF7Ju4vMpKDj8ViBtxEEu+Rue1jYxlVGb4dyl13mHs5I
# DATA oC8eIXc0+l3SzanyDuhtvDK+Jnnvh7BrhFu8lxjVeVxlc4tKAmaxFLDGzlOpSyWfJsNkMkkOlL63VH9eJddFw1Xfk0wcYV9nMutA
# DATA A4Yx6OK7yg7xZmkThruBplNRYeBTlOV16XmT5fnZM4YFngVAzoAsOp6CRLAWxQJVivAJBqkpD2F9Mhlsw5LaJCYNbOqlYhrS7T2c
# DATA UEdTMOOgVAfgEAUTgBc9iRg+j5pH2TiUQmLyNFmWe6jKA5DoKTKzEQZmrCkl43Q+kWJPnUQKel3qOa9cIT6So5ILs3mPMKLNg01u
# DATA I63V6xa14xjD3Eqv8joncn6hxJTCmszL/Mr8ynO+1pfX0i/SrEzju9jX8HKJNJqMhSXMAm5EF/s2XjB5yCVrKusUnY7VCaOlXOxb
# DATA eekE+75XN8z8C2/OBuf0xb+4s58McUlv6ybJJLX5lv9y9MPx3wFIefxPzJ38kgmXXxz/7uj/BVHy6NujbxYBl//CBEvgKb/wjr7D
# DATA Pwyz/O7o2+O/8xh9+cXxP9Cfr4RwqQKmFzHW8nsK/Jujv2h6JYMx6bbvQLn85vgf6bc/OYTl9Z+3PZKZ1iSBkcSmMBaNktlef8qM
# DATA HJGZVsPrIJ5CXUNOEZuJ2GykbRcypTDqhQxvlQGfLZhUZm7AoMAsDPkM6lp+5SPecUF9YTzwPiGLkY0oR7LM5nC6F7hqjOXSgrk8
# DATA oCXXy9SaP+pqKsij/M2orObWB6rmYni7SJolGasspKDWMGWvCTWJsSNZblBaFw6yvKu2Vg2oeRwWD8LBk4zURGY1eDvA/6hkwdbt
# DATA hDhuRKPsBPJsCq8TdjFCGGjUKIrIyMcCPNXLQ54bKAoSzs+PF0iWJ9S81WbJsub0rIiWJyTC8SzdGH+eMV7DLM86tL8UrtkrG9Yv
# DATA Z1TfaFA/zZh+BUO61MslOWAG9GfYfi6DcLkkqR7NQ+kTs+dCtUwqyUUsC7zOGSLb4w7GWaSYk7ssyrzxWT08SQQUKH1TG+vmHN+Q
# DATA 4zbKofY2gVvmHN2IkkqG0f5kdze2+nkHNMfGGrAoH6RCBfR+nmYmlIz8ZLlhl3ePYhbDEBA0YTzitSVDu4S1E8sLlGcYhcYLWXct
# DATA NKTyrXYjGiOHMZkNB/2IYxF6bJrwBrte5GiXjnbpaJeXSLvcZIjZaEqzkU181eb9Waz7cxv3DnnpkJcOeemQlw556ZCXDnnpkJcO
# DATA eemQlw556ZCXDnnpkJcOeemQlw556ZCXDnnpkJcOeemQlw556ZCXDnnpkJcOeemQl9cGeVmp1cKgflbkZTNqtXvPEfJyycrzaeGX
# DATA tYpXq9c9yjfPr5YHfjnw/Eb53Vqj6TWag0qz4lWbc1xLure9iMMc+q2qV6GMDvxik/5uea16sRYUfb9YofCDX71X8ynsZjCoV4t+
# DATA ueE1G55faRQDuqVWrNLrW8VKUKw25sokiBrt7iIfsErRbnzqB+ViUPYqTd8rT2vVplfebzTfrlXzYdQ7zW6jshhGs+YFtfKnxUq5
# DATA UWxSpCq1ok95QTEKENNis3ECWdNEboGj5zfldZ14gtlSh4u/zpHwOly0vtTciYAKc/HtBs1arXYGWh7XX03Lk6Zg0fLa9SCq+hvQ
# DATA 8urdKEfLixrdoNXOaHlBrw7b2tDyqu1as5LR8pqNmu9Hl07L42pfXG8YsHd/zjdNRYWzl59bAWjbIMdOk0Qv4txUvi76//CHWvjt
# DATA k9YQlhs7q+BvVixPpvDZkD158HSQvdoiZC8L5hSQPe2AXJlHdk6rDFUYO1X/bI9Rhe00NgbMILZiG4Eeu9UCV3k1+y7L14KdVWvM
# DATA iRNywhDtHHzOweccfM7B5xx8zsHnHHzOweccfM7B5xx8zsHnXiL4HKcNpxGK2uahNL62bkBjBJHkEMsNLe1PPUMfQ28w2L2zPVjg
# DATA O6kU7+iO7DUK5ulHMq35pYcPOzcG+UrGNX+n9EkSjyiAD+k/8KFuG/Pywy197DyLS2n6FPn64dYbCyfSVQA38FmTou6ZHQo6VA1+
# DATA 0mwlpxDuDlavOVjtDlS/JAeqT6sX/mwPWrNfMnOlLeKIBjktzL0k6eJsscd+QnPMlkkSCGSNzvazPp/9PJxR5L8vWKt92UHyi1Zt
# DATA X34uf6l++wbH5DM/rdEPj0SgDqWtZSdV5TAaM48jikKaDCMIwfDRWqlqfAJeud+YyCK6gfnz5dnJ8QJkkMnWzBo7zxmhZwoPcNLr
# DATA wTGtDzSL7iECl6rGr5g/fH4aEfGFaiIHcsPMOnk2YjXP4jSred4ZVM6gWqJGl1UoJ1jjBGvOakettNcuR8iG+3TdDMiSEu0K1sDo
# DATA J9NkbxKO+5ao+DPTTbsAgCWNy28oGRpr9DqlZrEYAwjkAgWL1divB/NhOObMscb8Zcq3F6Ja/AHLe0vfSLURCino+S5BuPhN2Or8
# DATA opEXPaV89NLRhcsHs2jxO6N0Nginol5+qJJ3gISOqRPvedTfDQaXIVs8Y02lqebOzFgDfK41XOx7A1GehsR31xMRej3O0fB3se9i
# DATA +uODaJKyFBNWqphvL7IwzDYqhjEZ8LMxNcjogtWoG1knOmdBU3GG4MEKA0QM7guWiJ5jTWbTMgky75ikh7RWkDc8NOaH9DYGR5kB
# DATA IG1FdbMclCnKY3Jg1x/VhA4z9SkZ0OTEUbpCWqoDwKLWlbJ0qaAKxOJS3iMIfEcjj8Erow4VlJaf6inqAeV9wShkJap31pKmWHg6
# DATA 1FpJPCOazNptiORzuTCTGNUkGTC+WMYB0TiazCDk5elMMzpeyr0ZyQvMYneodFM3Qz2+ONMPy6BwExA3AVmYgOQtTDcFcVOQ/BRk
# DATA 5cTiWWtpKl4HMy364ZhhwyFmGLY4dhop3T0tBTknFsmoHa0OqdBHkUxmLJ3HqS0AibFycAB+0kxwIfMSj9JiZ9SUqe+iUtiPlig9
# DATA bqq2yakd33mTlzazeLcPs9kRc5fbs3jQNVp8KjLsaFx0G6vDoxaAXqO3ZbWfgVX4pCwsZQHpHzN4trnCKgJ9ZsVwzyaLs7J7hYZu
# DATA Kyl5CLh6r9lCAKtUfX5VNkaol1t3mJ7VfurVhHvYzPDDGjzGWGo26j62LRPlyJ2/nSao6jDDW/xp9Z2dQTxsc0TxYfV91DEn2JRF
# DATA d96Xj9m9NyVtd+Yw5drWlNV429TEiLLG0MyVLjYDS7NXZ6QzyzmcdM30lDc/yERV5WM+H+bAXLyT2nQHsrNAJrYzvr3mPRmaZMzH
# DATA 22QqlCOrdx7GzGrqRgwTotZaFS/BMEmng0MFv8RPsBKNFDuv1QivKx5NZQiMRA4TuyTTfqL0REOBnmvxWAaKj4zULLVcnhZr97aS
# DATA wvRgmSnrUB3UutoMrJ8iAz+gOfGAfffxpEPTxSwLMUeljgEoLrujU7MceEqoW/hEbdGhnuwerxKwbcx7K2G2D5M2HqHeL5I6TUXx
# DATA JJVFM0UB47K4iOyyWskp86u1Nr9Mk5MM+xkkP6ld7EUmq+BN4HvyeWQQXJKRJe8DGjMLHqvkxWSEHSr/k4KIUXculDjZrSLuMM2Z
# DATA p2GDMW5R9yKyynQ8p8yoxtqMUr2YZNPb8OOIOR+PrFrFr6YKcUCxTNkRE04GavVU+2bgRMA2uBBatbLSxdNs/Azv395h5i+MsASI
# DATA PflCzgVwjPs8boeQ1GV0Bd/0TNtkcIo2+S5AdOjTqN0VKdFFgVyZ2mZfpuYm1DqVkdbKWxSmh1jc00Q4eoRsfpEe5vwUWyQFxsua
# DATA kT/LCuZXNq9h7yZUxDRGDqJDdhNkdWxAv2QWjvLuisOPZrfUBNkTlxlryBDq4dlhpRdR1aKoWFtQB8aJnETVUbJWxAUFGuEk7izN
# DATA t/xALHvr7IHYXJFsuPN+onfBaeVpNsHU7jQ4RVRJKkq0zu/SSQyxF8UBkbHExtEUaF4bJfZ/CUjMO/rj0dceY71A//rL8X8++vro
# DATA L0ffLmLE/u+jb46+Kx79GQCw498AQPbvwIUdf0nX/+3oe/r79/T3D0d/OPrBO/5KQkfQ3wI69vXRn49/e/Td8Vf07+/wJrDI6M0U
# DATA xtcUwtcaTPaXo68dTew5oECPZOUH+3g6SqU+o0CPo2TM/EYGrPPQTm1PDMRuAuVz9jZioLFc0koMl+9CH50Jq/MbqAeJRUKencdr
# DATA qWJvwVxidvvo0OHEbB+K6giumiaWL5DLxYjFI2sN976upfqXRZbYaIpDgKaPxVcZ6aLJRfLEwqkgCvphSsMpLFiydJNez+HENi21
# DATA C2eK3QsHHaw6RrIAdpgBqsMh77TnJZABr5N4PUwlPObCsdyfWeUASXc4jHjyi7GE1xHjX0VM3/C6cTRdghE7sdKttk5ybenZMcRO
# DATA TIHjiLnR/SJGd80TO/Wg/lIsilzVgH7B4/nGiyGnGs2vaDCXGmnnQbbd6tk3nctAidlpFcew2sHRT+g5LD7kE4oUmFjqwsIi0Zqk
# DATA vwMG+2CcClWJkzYN0ydqrwoiEI9wcgzH+FSWbIYSA8BIhup98LoUrKmbkZ2k2siw3tE2AeBTCTbawSbA2lZMBsISu2AG3YV4uswe
# DATA UNYAg49gB2D1Kn1CgZl4xHCOc22i+jXALm3sIZtNJ7GUWTLqRJNR6jhijiPmOGKXzBHbaKTZ8ATGhsbxlRn5Z/M9XoCJ72hijibm
# DATA aGKOJuZoYo4m5mhijibmaGKOJuZoYo4m5mhijibmaGKOJuZoYo4m5mhijibmaGKOJuZoYo4m5mhijibmaGKOJnZ9aGKdoLJIutqU
# DATA Jtbr1aLmc0QTs5edT4sR84OqV201Pi1Wy0Wf8qdRLfpBfVCsAavlf+r71WLg+bWK55crXqNSbHi4C3f4TWDA8lnX7bVajd4CYQyA
# DATA r1q55VXoHbWGV2sVW3Sh4jXrCDLwAmC8PB9ht/C6aisfbFBvdpu9JWCuatkCc1VagQFz+eV8fWjXGrVoSQBBzQqgapG9motVoraM
# DATA DFZpnPZ5K1+q1YZXpXyoBF6zSH/5/rBS8ymPPGRumbN4dULsUqQ7a0HQDxrNOdKZeWCBdFY/A6eMW4bhlHEjszhlVI8ajXADTlnY
# DATA q+Y4Zb1Kt9GpW5yyVr3XyDhl3Wan1q5lnLJKs16tNy6dUzaOpidSyjC+6Ps2wHxZjrIqu8lKTV4ew5C2s0gCMyFrzFluplsLfuIF
# DATA 9KcSsNMxh+aSHJUQVIQ3c6qpVBnHWsVMd+feXqmxL5DdeHO2jXie1iC8dLoKufitGcJzt2kXmEN2OWSXQ3Y5ZJdDdjlkl0N2OWSX
# DATA Q3Y5ZJdDdjlk10uG7FIWh8Xh6oaH6e574bRf6g0SmtjA7PtwC4exKPU/hUlzU13j81G4KF9pmgVDlVoNW58fbt0d0wTvKVyU0eCQ
# DATA cuMGgr5BudKbiVwYHw/rWTpX6qwVryKBlAWklj7MFarDWdAgQ5By7CbkQ9o4oGLOYInen6NsuWPHpz127I4bv6jHjc+C17oGx5DZ
# DATA faf9XespWyJgZeK99KjyEr7WdTm8/Fyd4bsM4Fb+uPUFk7bmKsNZEVuWIzU7RK5yOsOCQJ5RBOSV6gpnV796502e4LOunNah4+oD
# DATA odCR0puTg7Cm+hyE9EQ7OcBp52hvNoB8n5adG0JONOlBDb87m3AFDSdDLX2vzsTzu3UE7pJtHZPxy9tmdRQ0JYyyp4dF0jZrcU7h
# DATA J/J4c4pYJlhqHXDaoGfHbQEnKtsRXtwlm2w2aRvhyZfkqKcVhrOrnF21RqzNrlxO18XpupzWoFqD27ocvZe/GSUH6P5FcaAd7onG
# DATA GiQ31MDmX72c2AXQtXgFQu0A0ddy2vA80aerPx9BbyFSMizGLeZtP9nbmSMBjXgdKAPtqCBMN6W/53BIlGjqkqEnM4xZ3rZcQp9N
# DATA PYtsyRHjCHs5sx9XyNmLHwJAH1uwZYwtrjTYb58YX/181q/qCxmEq1leFmc7xtiuY0d5TYTZU8KUJrirMx0bZNQJcVWPmqjq7zlc
# DATA 2Np4+mtiOUdQUutLaK3K6SJq5FzVLUoSKtWdV2WvqYqnWmO0tXyzS9K7xPuSAhp/FbP1pgRxPgqUxWyy2rctfKT06RXiJUSzN/qA
# DATA 9+F6shswN2jWSomexqLiwsMdehztgvp0Rr0QtMrT2d5exB5oACN4ZUJ1EMkEGAtAlVhVGqMwBzoCoGKgaVzCQGPfuGp3EFAhU37G
# DATA /ngqGujBQCE43DOMWChQwThNZSTvxj2WTpmK/hArO3tqK29k4iNy9JAm4mgsUSfKJIlYVhmeRkTGC8dU5zDAbcp2ekGM3dwI5sxd
# DATA Z+6uNHcXTBtn8TqLd7UJe00UDu+x+h40i3sYZOIRy5gt5ztpvmwmBTiJhjEjOgqrVPfeFKbgwnDDwmZ7s7gLnGE2MFJo1F67MwAI
# DATA eXibN4Hz0IQFgUNzH43rhmmqfU881P+cOQEYzyYJDR3hVI+5bIcPqYHPYEIpOyDcm0QaX7k4ZCr9QwqpS0O1SQ5cVQsDJ0sDQlyG
# DATA PUcRa8J54RQVmiJ826a2azJk9JS3R+EdMaAGlOsrZgQi8Zbs8/4mxeDU/NyxZnhhI6eAQp5Gk06M/Y45CKpkOBcMi/ZZQoXKS1by
# DATA 3gJni7tR9qYxtKsPm4vvYoAJiJVw170bTbmf5WTAtAmnc/42HFwzkfX4cAPYJ+vSeFfLUZr+XifyA8zaNHtH9f1QmSyI5p4GE+ER
# DATA rD9SQQ/SAtMxUkPt1EaXmEnvIzD0lIcwwdRGSx5ZJjwktWFpR924E0oJKnwmsnKhpluYs+gpjXmDw3WpfJ+PFBvzi/ElOp13eaen
# DATA OiQymxTgSWaF8aEufp4+KlJODPiJMl9HUOJT4p8WI42TlFeqLHmPougJU0LglmWeB/KSb1XVQitW5vgy7D8VbgjUFuEg1o7iMOVJ
# DATA bbg3StI4XSBzsCF2ks7344Q6Js7PrAviVnNqUjT7tPUYdCGcaMvNrRoD3NvsxL4EMvR7qL56Hww11xBVV/Tf9TTlEijR93LOcrRZ
# DATA Km+hy14CKfrdeMqzsgl1WxCCFCikYtZwzykCk5cAi34wkHeig+TUZo2Lp1ndSwBF36UOSLd49FJdo6/LRQpv0aR7wezkF33+ZnFx
# DATA 6KlpamNx/isgOEffH319/Juj74//6egb7/gLIGro6zd0+dvj3y2Scf6FUTf/ylCb/N1Hf2JKjkc/fXn0+6Nvjv9RhfJfwMWhaz8c
# DATA /x2eoFf9jn75C73wT97x3+dIOxZMx6FxngOyMIPZjHatMLLg+QXSoyDbUIUL3ONu6wBQ7gNlUe1FrBj8BA5nwQlPNSuRIaM8iIIh
# DATA uDdYT8B5Nwp7/BaHv8nNMbm9XzX9xiqMy0PfSNKybpHrTo/nYfO3YuQwN/JUb9I/nPaHF4m74U22NO3po8Z3eUYA5B5vxcTtDntz
# DATA YoldOO8Gk9ykjTkm1zPtscZOETUd5v5lEE6Gamkqm3zGqbiiF/ZQi34627Yyl6DSol4M0zoyXeDgXsDfrK9/q42PrB09K+zN+pg7
# DATA 4o0btE8xaGuwzenG6pfDF3w14/RFDtMbjdKbD9KXP0ZL9TOJNgPy1bWFyyDVmPQIITmdT4jef5FtYmB7op8MNQzGKhOZ6dKAhsEu
# DATA 7HJCmYJuiBSpYix3ktlE2BTZ+KoTLkfZ6SXIKw5+M26NmuLnxuDQONf16G3G7ZRu7M4Gkd4SyUtY8Cp66TjqxFFaMPHP2MXK0TqI
# DATA xfUaUWcb9qLpYc4VqNLBOF3GRDMKuCOJyifIAWocoMYBai4eUHPywLHRnGMT+/Vq7O+zmN/ntb4djMbBaByMxsFoHIzGwWgcjMbB
# DATA aByMxsFoHIzGwWgcjMbBaByMxsFoHIzGwWgcjMbBaByMxsFoHIzGwWgcjMbBaByMxsForg+MplqLqt2zwmj8XvBcwWjMcvNpSTTV
# DATA StOr1sp9xs9Uap5fq75dDSr57Oj0muVgkX9SowRUa41f+JXqPP+kFnRqzWX8Ey6lfDDVVsur1Cr/0W9VvEqlTH8aXsv/1A+aXtPz
# DATA GxXPD3x6V9WrtKqfVvx60a9SGYKYUyv6dbqlSN/ophrd5NMDtf9YadGjFa9KIVSbn/rwIte8Gt1TrefSVYuarXp5ERAjESqSCV/0
# DATA /ebQr1G+4EX1MvA8c2nttLqtsLMsrQo9Q6UYk/mh2DW1cpCxa2qtslWBa/LlcElt7naieqd3BnYMV2TDjuE2YbFjapVGGFRPZMe0
# DATA e91ePceOofg0O22LHVOttzggYcdQJ9EKI4sdEwTtau3S2TEDagUnwmPgNPo8u9VQXiyOi0rdomOPnXsV+rf5E9vcbrD5kAV5MpLG
# DATA 5s3wZjvZW7wsFsZ1VVqyfkoWloelSq8uf3KhecqiMUAZHkVN758j10gRz6WYwoRl5AXyx7hGJdlNGFe2P8e31nhUEA3KMJ/+qH+1
# DATA hcnWKw+IK2k1G5RlPuvyc+ylGbEyIAe1cVAbB7VxUBsHtXFQGwe1cVAbB7VxUBsHtXFQm5cMaqMNQi3ts7Xz2rrRjOE3utfnUxfq
# DATA sQL6wKVdq6dSZlWq3Tux7r122STeuY12/uHWvUzNC4dVLDmXEeWw0nTB9DXPrDEnH9y5YXdu2Dr54k4Pu9PDJ50eXqk1eSmnil9H
# DATA zYXSXBa4OVn8TPUnLkAvHVpzePNBFD3hE47SZs+oNZeNLRenNhdFA6XK3ZZVEsoQrT6oHN2XIDunzxsrcNuYSrU7gfacR3OkaHB4
# DATA CZpz74xwqHkqPWyqlLJhL/cygepLEJ97zK4vlUYyQVRvTnWCxo4i1K+7l6A791COEsMHSKacSrKBC1xKubL23Ps4ax0aATq0PBnh
# DATA YLKQeYm9ULNJdMHqc8oDY6TjM03GnDJAdrhVJ8ScmqUMQxcwzfUglkR9JgovEvCQUJ07rM+9USlT1+xODnVGZ6iGcHAAbuEwYgl5
# DATA 3IKFKjI0BoOS927cM82hANzDYLEtKhXVEaIy8fr04yTCgtXgUJ7k7uUgTCU6miik1Gq5DorKOxobvLmiXU2TCiyx76sAqHVQNKW+
# DATA 9OEbnKgT8dDJpEd7NKSskgzQuaKP+1M3OcLJd95mQOMJSwHQSD0v8TM3Uj2McBxQneKWSavcIePOybLxz/nJY4ecdPZ7Zr87i/2F
# DATA s9hPi5R8hjpAvJhvFqLXcyTfjFn+XMFRIHo+8ngv7xqI5BXLB117OY3L4ENmIkcXDYe05aDOSoa0NinoadNDHKsy1UEmfiycooSn
# DATA KnMFiV0NUopqdyOIja9P5GHQALCFTkMb73qD2TAeJTOaIhqbaESVPIGIzTgaDCDtjjG0rxTXyf4albyftUVunwwTbLqGllKfTFKF
# DATA OWCejX67HY23YKDxXZwYHYv3YRdREBQ7qrxUayyzi00+Pj8S8TaEwxRa6mHKEurSQrTG8xAS1pN172c3tJd791vSglIyL1Neii55
# DATA 7yXpVNt/Ii7E7B8d69vIIGlfYC9B+Yb6a9gGELanboSqOsuGzMfkRReJsXoGZ6s5W80eGZyz9eV1tq5mTj5LCcf3eLFS12clwMZH
# DATA ry0oJaT1GI6wD+02aT+Z86bAbgQGTLITTTsOS96DTAwQp3BEpc2gfbgM2WkQWvqB7NNk30Ev7ngpTfc7xrPS5q1kmWagaC5uqAHJ
# DATA KRbHR9b4Za0PMRmFk4nmCfHhErwHXp8lRqI647hIu1Tr3Kik/En5yZQnS/+YARHNFc5xYEciDkeeVu6nZDCwUrCUAGkWz7mayOdX
# DATA ZUuAerl1h+ko7adeTbjDzNx3WH3GiDkY6KXRGP7QRFlz87eT3cCtKjlYfc8emz2MzOJPq+9ss53GGtkTsVL0nTclVVk+yHisvYWy
# DATA Am37+TA0rHEVrrUZLc9nOOkaJzwv+Is7XuWglQNzICneGWxavyylcxWazDgn7poEzMdY8nLMBts9iDjGEwiZot5nZivstaLS5CyI
# DATA xGgRMzOtQUrD2DDpRuzHn8KeheGnLThBKdnORDggjVRnxEJD2sieer+iAbdk+1c39KV6ZpscWxr5pJis0RJmALxiuZsbET1jOV3n
# DATA bdlTFU9W+U5ZQo9Wl5CuxlJIj8bsg82XEDVj7kjE4w7sC7Qy+2T/iBs09KSuK6vfYgeaNRA8L6sgIrWaQH0UUw6ULnYwKivl/GVj
# DATA p+D6F8yDTQvmQTgZsKhsOBjqgnmU9BjGOqJRjTVTDzDJoxF0Lz83K3l395MYM2PKe+PWL9iuby6VMfUvmJx11SwR08Nzl4cd8Ssr
# DATA j6zvPWV5/IfV5aF7cSmP/0AGy0JHNut0ZgNWk8UioDpJqBqHnqwqlh71UrySgPPYNGSUvLepdR0WqAjJDEnigagcD7kXS4ZDkX8m
# DATA 42IoLDH6KUYOmvXi8xdUlqLrX0wPNy2mh7N2e74/e51FrFVvFo0+SQ6zHkyLcZW8D2Ka7nZn1NHvyVKUkU/Wq0KZhQemNuVVJ5wJ
# DATA He/cZWFH+/p3Ym9u2om9Hk+6vGNgBAcQNY6R1Xj6onjdnw3jbhELhSwxrsqDR52UDXtIC01hmX8Qai51ts5v8/ZQwqa3o5DIeFLb
# DATA JqCFDPfQuctpMUFnKq28/SfbGG37z1yRvL/zfqI3HGoNbjH5xeLmpX+GWoY0Y0F26FJWC6eXw0R7rj1eGQst7SdRDoX2fxz96/FX
# DATA R78//i1YZcCY0ecvj745+rej7+nv3zMe7U8ew86+Pfrz8W8XwWj/lTFqXx/9mZ79g0d/cYBH3xYoxKM/0jdGn9H/fjj6xrzEJqnR
# DATA TX85+gafFEft30BFw/vlvT8c/fvxPzkq2nMA5TbbHHjLazI90NhVQ+aGeLGQVws8M+JtVhFMPM0CADQU7gSWkaEOQOAM6EDHoBso
# DATA oivV48mU94zhuZ4sYRmnADwda8lpUJZHUxA73+HTbF8fdxFXTU+bL5DLQ6jRaBEOkr0M8cU7DPnl8xzum70466bfjKcWvuPiGGow
# DATA pdW5DdTQREZwzgaHTzu5tC6cn/aeYMC9NhkX2NFF8/4+jTtmelnQRlaa4DAUMhKGLJKJ7k7tacX8RpHGn0IlJco6J9b5KpBNJcuR
# DATA k4g9i0yY1ccEhlREgtfAYDVdYKutr5erjZi5VvasAGvro+8Aa278v+DxX0PYzjDsvxTLe1cz5F/4iL/RgH+K8f7yh3upiPmkm1H+
# DATA ejWfy+C25RPOgyRniIGOmVS3DxFSQc4wTmbyKonrVIBO6TDEwpdZevOkX2pHKVxa0QRLk5xoGqizYwsqet24Z9hulOxDT5FMNmS2
# DATA TZS5xttqcGSFDAr2S0SdJxibFJqM65hwr/jUMO8EEtpcnPIeqnQqNC5emo3SqZgKyJfMcritKGagZ01nFMIwHM16+DyxjQTleYWf
# DATA gG2ayWExGTlkm0O2OWTbJSLbNhhdNprobGISX6Fdfxaz/rxWvQO3OXCbA7c5cJsDtzlwmwO3OXCbA7c5cJsDtzlwmwO3OXCbA7c5
# DATA cJsDtzlwmwO3OXCbA7c5cJsDtzlwmwO3OXCbA7c5cNu1Abf5QbVTLZ8V3Bb06lHvOQK35decT0tvI1vVq9aan9aDYrXuNatFv1oZ
# DATA 0D+VitcMPL9Mv1Q9v0Kf6sVKdVBveUHda5W9SuPTao2uetXAq1Xe9v3Wp8VmsdrwKn4xmMvSqNWrdNtz0DO/UatXa8ugZ63FkquU
# DATA vVo56AeNyn61/jZ9zb/AhJWnsFUoBZV64DX8ot8cFmsNr9b0GuWi36AvNa9W9+pN+rJxxPzqQswCH5C4xqfFKhVqEXlRf48CQGwH
# DATA VbqQo8XxTs78y6Jeo74Cc6cqcCee8Am7p1LpKxn6zW8wSI5VDer5FmCCpQBg2HjydBlZ68nDzWa+2vd6/F33vyyHyuKv1SbVGwrj
# DATA lNg4bkYaGyct0sLGRUGzFgR5bBzdVKvUc9i4OZCcYONa3VaGjat16kHQyLBx3U6n3cuwca1utVWOLh0bh/Z3Mjauqo0CMQn0Myv4
# DATA cUjmnH8x+IlXoz9V+lMPfmIHMceLe2dIU4lpAVuBEV/vfVbsoK92zO1pUlAu35535om7p9DcPyjwKtmKFTEVDcCrxp9tulRQqll5
# DATA 4VUn+WA8vZ8iZ5CY+RJ2VWsXn/Zy5pl2KpMq9McPtMnPvqJ4ShZWJwey0z5s6pcrC/i58mq+nMn9gp0Da0yRExLIVoLjyDmOnOPI
# DATA OY6c48g5jpzjyDmOnOPIOY6c48g5jtxLxpFTFke+A4hHFP4u7L0Pt6TNUcJvyHcownA2sIn54dbjcAIVWn7Ek5vRvG7wBaoWb2Iz
# DATA 3ba/c4NyozMsfUj/je5ap8Tv/zx/DI8ffi+c9ks8Q9/mcH7qlwKEkB3vW3JoPFO+hRSX6fY1ai47tuIOUbtD1JscoraPNrmz1O4s
# DATA 9Rq95Gd7xlqOBhf0Wd8lJ60fmnOBUkcKeWU1c6hXDqwqQRY+Sww7+kDpMMtJ3ohV9rPDk+PwEJNpOTwJrZWRdXJyYw3kN0X1uC2M
# DATA qC4IVHh1aDp0dARO93gT3eNOmM5CJZuGT6vvRJdKWYtbP5CPq++lDrabJJzRP5OPz4MCcpYXpxRBvLdaBFHnqoggklE2OexChygc
# DATA 7YdppoCIk5PUvKAg3knYbTIbj3HuGRsNcBjNm4gsZAo8hxxmZy8YNbWo5FGrjnF0eE5Hh8fD7uSw4EVhesgN5fy6h3NpuDKJSqv+
# DATA XZxiqKnJSqcatsNkBjMyK5vOLO1TzY1YJBdn0OUIdShy1WzmZEYErErYJYJhQEH1wb1DF5EpUys9Bz4ePkP9gL+0rZkn51KnzhLw
# DATA HBTMBxsXzEOq6kW4VQ6hAW4ph/LB5gKVyDji1sPNRjcQBsmg4Kg/QsPRuqE4RwjFKiiGR2O2DZHhlpqGCA5gbUvGt3jQT2YsPXp+
# DATA fddcUq6slM7cub27aef2XoydM9DwmE0sZWSaoNCcD7sCp8lYN51ePBlCnHQ29lTBJBOWYONfRb3kgBI1SdrS3U0ifGXdsNmoT0YV
# DATA 1A1sGY/zFEku5ldWItYgecoieby6SMxwK2XyeBLGA9FLCcmsMYVC36cwTmC/JZLDXZr2wMhD1TQ0zEmomoPSrAZMWCvNZEoSmdib
# DATA iLAMDkXt7dwFk4/+9W8rjzZtKx/InJQmqPGYqrApGNRuWM40dZctQjCseRjn6ShUPcYpj/eY5oNHi425CpmVima4Egmfsqg1Shee
# DATA 03MXxVyMX16t4xdBTkQ/7rxbzru1iXfLrmLOu+W8Wxt7sVY6wS7Hu8XCWwaAF3p7SSKieNq3dW31a9f5vnCkwbM9YAtOLaGbYsOI
# DATA 2oesr+W8TWp5htFMI+y/54mqWijd7gx3lNtLN0yZlKIUJVTzvOnKsivG9VPh3bUT9NzoxYYxG0gV3lY9DHnLq97IG41563XJX+0g
# DATA 4xUk1PJElevYqJbl/WTqRhMz/eCCa8pXhF7YPd1bnu91hqv9WH4pYAcCBRZHE7q7FOTuX/BlKQvLOApl0w0FcV/LF871spaZhPKj
# DATA KPDhIp0q2X1lmy7ZJWnisZhnYxoPp7Ih/aYEcU4DSIwUDEZWe7PVLB9PxP0qxFj0Awsq0QPWaxxpL21BZgxsw7FXJNwLY9l1hS3x
# DATA gpGi2UPJM5C7rJ6WPC60Ag9+FpCFxSuzIKFXmWrrGK+DNTWOR4KxQphkERsJQiwosoIaDo1B0rF9KM1ThPlCKFDaq4jpbA/8Wt4p
# DATA kK1hqmnrSEtQsl5lJjs5Ywv10DPbBfSeuDHbMBovi6x+4Q3PbKhxpqczPTcxPZ2t+eLamiutw2uoVs0nOszpgkUzbGCZoW/B7ORY
# DATA gUI+iWSZMNVWaPYQyy5x53v91K2vv+Qr/y3ndO68Sj3ofMPSxwIRrjnC1ZQTftaZRbkQDvjbvAj3/HE9aaadBJMFedfhqCPmt9G/
# DATA uvOzhdN+vIOPCnFB3Nx6ir9wWjYQFs+OrWh7bA4OfhAe8vQFes7GMLvHS3YyORqZRUH4E/copPGhLC/K3Ak0wnG4z3OXkveQl7Om
# DATA 2oJS9yj7DLUSLmNxxrHBM7/WFWI9nKw0TevYqBLMV6b7T8cDhJrGT7F1XZYhpXpfOdzjyo2nDFNGFWo/GuzNqLuwYWX/cvzV8W8Y
# DATA SwaC2Lf8+c9AlzE27A8giuGX468WKWX/q/nxy6Pvjr4Fiuzf+cIfjr86+jMuFbyjPx59zSiy3+A7buDXHf8D/QGI7Pf0OoDMvqWf
# DATA v2aU2XcUwPf47fgLCuY7wMqOv/AojK/pwj/gItBojl32XFiHSBtPveAPYblyXXtvgUgaTp5glS8cRQW4PWhWOuG54ziU6Q8GGZqh
# DATA 4qg0ryFBL8ObjTgw1iafxQNmo1KLDnk3J00sw6lAUiNs1afObC21TGDSkQyUDlpm24pWh3HV6LK5Urk8clk3lnOYqbnzDXWFK+oC
# DATA vQzjnrmTKp3UxMkFw8t4nh+nvAEBzYF3humoOoLZZqV24RQz3dn0Yn4uHIhTKe30o+5MtokMhB0PyQ8GOXMv5rHaq+cHxWE8gq0d
# DATA DqhyYx/Jbe3pZXSGWGGTiAIWkEI8QhcsZqCyjKRNDgy+edOqudrEyTe1Z4UvWxt5Ry9zFsCFWQCaW3b6gf+lcBBd5aB/0WP+RkP+
# DATA KUf8Sx/wpT7mEm/Ty65F87kMblkuxV4kc/RUPFJM4faSXn7fHmfDtE+x3ON1EzS6GPs0jWXEiKNhOOaEy2vRR8m5AaqdoC5hqUUj
# DATA k2S/Jo+4Uu89I86Wbogt45xTlcKj7JjhdTLgAwgi7rIDbRhQEaSIpdfFgR+8/MkoOZDTEV21uRTYqHHERd1PZhOwv5hBFbfjAbIK
# DATA 1h2DVmg8YtwUjAXRQGA8lzlDoEBOo2Q5fMpxzBzHzHHMLpFjtuFIs9GUZwP7+OpM/LNY+Oc08B3IzIHMHMjMgcwcyMyBzBzIzIHM
# DATA HMjMgcwcyMyBzBzIzIHMHMjMgcwcyMyBzBzIzIHMHMjMgcwcyMyBzBzIzIHMHMjMgcyuDcis0qwFjcpZQWa9XtgrP0cgs9yK82k5
# DATA ZnXKk3KtX68396ut2tv1eQRZJap3eos5WfYpK2v9oNngz1VAxtTnGmUsf242PZ9yuForD/1muUj/qs++/jwH9aKc7/Yqy6BeleZC
# DATA FCoBRaFc+dRvlD3fB4LNq/jlqQ+3cfMkfFgjCBudpW8K6gs4NL8RgEvmVSvFVs3z6zVA0PyAMs6vMvmt1jrhdZ1qvb2cVmZB1IqY
# DATA DoQQ6Jca7bWWgMwoLhnIjCJlQGaCY8taQK3aa1Q2zt/6kldVyo3sVVXfv8RXVYXIJq+q1BuX+KqgYqeqWb7EV9UZRadTVb3gDDwV
# DATA VI67NA2Vk97RgsrVKvVqs5uHys0j5JZC5SI/anSDDCoXdOtRs2qgcp16J+pYULkqvbdZv3SonOwuLMoygx7mqjyD8PTqlLFdmmL+
# DATA 2c/MQ+Heiqgzj8PCIv2ttoz+Bv9nY/+gUBf/pwp5GG4GeSs11rk19fQsC3R+gcQ273X5LHg2VcnkwmFxixWur79uN6kD6+adXqez
# DATA wzx212KpajUYzsqqNfbcQpzz06JLtA4dY84x5hxjzjHmHGPOMeYcY84x5hxjzjHmHGPOMeZeMsYc6kI8pRn+JIQWO1Ww2wY7t3vn
# DATA MzMnGae7XE+kl+Lzy7j6kdXypeHv3jHNPu5t/4gfVQ135zPFpdPKRRBDlTNfjDgac1ctxuXtz+XV3ZmsPe/aAf1UcHe4lCHwmEsn
# DATA Szr2vUV/56d+cMMPEB0d2h0JoD2j+SIK1cSM5WZZgXYURd0UvDv9DCB5IkOQGu2lXnQgHchYTuWJ2Bdd4hOMueQgo3GKcVeb9RO8
# DATA WLJKFp+2eUK3U5LFh+3tsLBfiKkQwhvK0N7f+el2TE2j/Fq9fMvfKZSx6YtbPdafdoe7d7aHd3b9Wq382odb71OV5COWHCoySBk+
# DATA nE+9QUJz1uHNennnJ5XaDs3AuqxntV0pfLhVxt38mH5m+BO6cfGm21nNkSxHDdhOOdaq6sB5tMvx20bqGTX437/4Z2RsehtXbuwu
# DATA K8zt+NV8Ib7mB7fKOjc51Nuf75Q+SeIRPcvgQom0+nhjySt78ShO+0oU1Q90YeK0rDhcBID48xFUJgQHgOcZerg9V2GKulbs2NWC
# DATA Gg/XI5MtOxTJ21zgVBJFPaug519bZzJyy0PjycL5DOMgGUPq0LFWztDiFjpkzVbUlc7MuyhwfR66NH2KfsaKo4T9SIepH6IBF2EZ
# DATA TKM+iOaUIpxSxHqlCOuYotOLcHoRp9aLWKlTeik6Eg9m06wB8K4trekpI7sRlbiOMkZXoWMvxorIuE/EiplTrselTLde3286L3PB
# DATA CL2XW7fUgrkSrl+hR68GXFakn+JkOfOQjLD3thp5T1LSN8GYKGVXMiX9WnmZlH7VltJvVMq2lr4frJbStwwaRJ8jThMTmlVxtcrL
# DATA 6edutvLNDmJBLZ9jdqda1vbHal39GsezFpx8Z53DrC8Jc0F7Xx9gpHTzQcQ7yigWZhBaDt0qv6icyZhQmDRwmvLlph0f85mQK6f3
# DATA svGMh0KZgNyxLs8VyMW89iHGTW7x9luzq5fzUjn46NFAO6FuIvfm/E8Z3jMrl5V0BOnJFCbg+UUivAv/nkjdKGNFW/K2cobRmOnS
# DATA hM6y+3OdPJtBEP7I3aIEeKkKs/YMJGdYT4PhBizmoBkEqzRo8qIzNhVskf+1nBMmGZibP2Ak1CsU7NvSQ5ANATuRb/D8i1vkLQw3
# DATA L3HzkhPmJTn7001N3NTk5BnHM5W4wxiPCq4jgcwZZCp3b5qJiAAPWPPJtDUqvTBlkSsITrHmmBGhKohy2jAUx6URQtNiDfOTizn0
# DATA ArbZ2Nhv4dHaBpjwNT8Q4blICLNwlaJ9U2KoQqdmSsOMLsqe9NMZornHv83SQxpzR8z0ogRKZ1FQECKZHumBloH03F2kT3Sg434y
# DATA TfYm4ZiH6nEEQ1rJ+8YTlh6TJOaHvWnIWOX3koko66qxbh5uKohky/KT1Io5YuHQuCND33agMMjYJqg6NvHdY3XqAChy6MPdFX6a
# DATA YCX6oY0XhYcchAGWWoNvb13s4y5bdWsjP288SgoMUkAgwqkhCEPFf2pAzx0WhFP4C61JnCnrCcs2r72niqWNLlv4BFavHUr9XZOm
# DATA u9hhP0pAbp1PlpgJeW7sgqqiqchkFj6Ae1+9GflKZlsfBF+FbJAs4B8A7EXksZbcYdk2GDUFVKKRJAXMO3hvk1mq8kMFHFM+3N1P
# DATA 4i5LUrNKGwAKkqU0QCVMjB1Cam3MJ914d8ryKT3H+m+EJqIc4DIp03HGgnpOuDrpySwMOnTDYdKVxo3C48umrDx9eC7p9eBT12Wn
# DATA NaylDAveeNYmC8V6jvXnuBGGXVhA3oTrsFRWGrsYXsyv9EBip0GHLO2U2uS6JD4CGlzBvaYYRKwkglAmL6SeIYa2F3V3lNYxPd+b
# DATA DQaHireiYspunJQrqqR7mCMVsrKg9AkH/USpI1IHiZ2gVMSTPtqhFBj6+HlErRimL5497WhhzpbeWA3amc4vtOl8WlbYM1aHtvf8
# DATA r4eFPcZIoGGXbFRJfV9PC7s+atLPhaTqSQSJbN+/ZnldJFQsr5B90UyxecXxpUgx5X5jNW8UKu9CIyNIakQqZk0ysN2h0Vh3Ynfe
# DATA Z+0S4YrRVIX1iWXSRO+j33HPm3FmOaP3gGT2CHa50Mio3mT3yswENq3sTk9g4cWQIjtUN91MBquap9jLsHNRfXlqES5zMK7FhMAV
# DATA a0jOC/rjsMBYhng8QY1OI9PMRME5NNNV2WZDhv0Qd5Gdm/O2ks0N0WJbC50tbZ5CSk7NWJRcG7gL62wLtt6LZuVlWLODqK3Er22q
# DATA 2f9y9M3RvxaP/+7oB6aMfXv0/dEfmC5Gn47/9viLo69twtjxV7iyCDj7P3H56Pf08DeMKPvGoy9f08Vv6fL3IJMd/d7je/7IjLN/
# DATA lPuOf6dAZl+DpEYv+Ir+/Z0CmXF8vkacjv8eDDTmnf3h6Af6ge7/k2ObPS+2rDRyNDwtvs5LVoa8iXUgmsOJujhP3hIKbopWjzhS
# DATA K/85VBaZIS/eo2SfvTzhJPMqWSRENI+1KLO356PhcGa2TZt1FFdNM1tSMJdHNBOfSrrwcnV9/nbZQWDufhilNAJ1ZMDmQrpgtJm4
# DATA l0TPH64VWfhjaoEDm21UeBfONbvrWXrn2czA1ABeNIaQzmzAFI72If7GaQrlngP1RCIods69Bz+n+0XTvKA5FXq/i4GYsP2zD3ix
# DATA RxcHCzyzDWvmahtnsdk9K7rZhklxnDNnDZzVGtBYs7MZAS+FU+sKDYDLGP83Gv5PN/pf4eAv9XMhJyzU2TNpQZdBNltIJNPNKKvS
# DATA xWiBcSbLyh5VT9TUWwJ6KnhvP3784FFBHSxVK8NcMrxndEL2A6/scDIwQsMpkdGUJqostedB56keczfFm5mq4FFeQxksbwAgZXEH
# DATA mLPMCMgDzsaTqAvfSN4osI2BAjdTdBYeDIxRR5kHbBWAQyXmoSCnOP4pvSajm7FTJT1M+Siluqft+GaOb+b4ZpfKN9tsrNlo4nMq
# DATA A/lqLf6zGPwXZu877JnDnjnsmcOeOeyZw5457JnDnjnsmcOeOeyZw5457JnDnjnsmcOeOeyZw5457JnDnjnsmcOeOeyZw5457JnD
# DATA njnsmcOeXR/sWavWqtfPij2r9hq99nOEPVtYf94IfcaZqzKPKWFC26pVcofF/Holn+tVYTlJtjdzGddtRkHUm8M3VZtBIKiueXxT
# DATA TbLYioe8W+Ih7KssHtX5Q2uVLBq1eWzdMl5Y3eKF+a2mYVDlCGl/Xes2/UZ1seY0a1R1mn2pc1bywnq71QmX8tPWJa8ipLRLSl7F
# DATA onltnDx66MKSVxXG1yUlr6qePlXy6KFzJa9aqVyLRlKtNi+vkVTr/jkaSbVZPncjsZN34Y0kl7xTNxIk77yNxE7ehTeSXPJO3UiQ
# DATA vPM2ksBvXotGElRrl9dIKBbnaCRBo37uRmIn78IbSS55p24kSN55G4mdvAtvJLnknbqRIHlnayQ2sLXc9GpBsF+r96ut2n6xVh8W
# DATA /Vbdq9X3qycBVFc3grPQMNnSNTRMNpotGma1Xa80g7PQMMtR2PMtGma1HjVrhobZ7nS63Y5Fw/QD+flyaZhqM6/M7ixnj1p2M3xM
# DATA nrCTiW471Vq8xr5k20QuVMxfF++Z36qwuGTW5CWzUhNbZWTRLBeqWjBfG3KdV8/yj+lZ4PLNhtndNJvcm4TD3BrdSclVzyxZnl+8
# DATA Qa/UL+T54t2ZF3HVDkl5kS9FJK6AhUCw1LCI+lTVLr9c0Gq14IE5HbyTPUZLUsVuwwXf8+J2oZXcT0frdLROR+t0tE5H63S0Tkfr
# DATA dLROR+t0tE5H63S0TkfrvABa5yKacy9uK4AiVudgeio4pmZQ0ZWbfrnWDBr127k5i3qMDw/jMY04JMN8NsaVGz6erNRuKzbmfXWM
# DATA HfoBo2l/cGg4V4xIpJhQvXoT+/u3K4xFfCt+XZCK7+KcuZxSHg9mqQfBZk+9iJ9VUVr1/F2vEvzEvC0T2pF5KeXBfsSozm2Kw0+x
# DATA xr+zLCSbZWidM3WCME4QJicIs3jo2KnDOHWYs6vDrFRSvkzVGN1ZQw5C2guKi5UcsNGGd95YEjLXR8fsKoCGMlQy6EMGMlbh4Ksn
# DATA gAT1k7luPs0h2+BGWAoS9C2OIN9U1ncanOBqmqAZzsESVJ8RNguWjDEo6iR4238Tv34SENEKziTFvmZSE5yclsopkiHWBnoAeEXF
# DATA JNh+7+T46udMZM0FK6abZfqGMdV2ELdTCCVCciSzW6jrGsfRSdUlCyQDT2aXTNQbJ8W8vibWKyF/pgvQUyYeD1UhP/fQv2WkP2Mh
# DATA Rqb3Q89EdUxYHtw8ukZeB7YBF2k45DkAL8+wIIyaa3ZoUsVq0Qw1wd5Imt4UvIM+VT4yDid7kRWayt1ej/ra9mwC3waeo8nVJIJC
# DATA UzzVAj/KXy0zj5RluVmJiarUoRjIrINp17OSdy8ZsluMur6CEusZdY3+Uya6pCZzXXkinChdpMyWySCzQ4rXbMK+VSU+tAE18EVT
# DATA inHMEzcRWDERcDb/S2Hzn5Z0cl2UIu2dEuuRJ2/FPGKKWiKvR0MkbsSqPdS2htFa9smzk5d8vtTVTlKXntvjcRngk0UBzYuGnyzT
# DATA IV0KQMmVnd4SIxV5GeDvTdjz2kRYegereq6943UxrY2hcUq5b0X+Y1xlzIKDAImIxmc4lTJX5uYmOMxH2bRb4xXffvzeuwXv3qNH
# DATA BTUOS3vhYUFpuQNiKfMiEVocQyU01EqqrNRIpWBkP+M0mzdosB038HiKYXsNUfGRdAay4W09LPKuFQlViXWK7kIJdKTkUTl2nCBK
# DATA WDcCzS8adaAIOooofkqPtUC1l6prXy+ziTxrXpV1LZoz34GcEHUtOCvWtI62gimywa0OGEbizxAYKcx+0b5nA3pyqCQxVSxL3gPN
# DATA qUHMeXVMd2Sh1wvjwWyyjmb5UILBwtUqnuVLZIHb/bWzwZ0NvtQGV5XEeeKdJz5n3a003q+PfjvXaYzUGc459MRTaDzw4quJU2zc
# DATA S3iQzIuPaxf6PP1sNgZOsOT9AnvEDw2ihe7ozjoQkRliLDbSxsbfzkRjtnc2FnLPdAukeeLrnVe14fcIx7y5YUO/IlUAbJlxqL7g
# DATA 1ZvGSpxK7z2d4KMIc+NVHXHWk70xSWgMpobdX3rDz2VM74HavOKWD2CyIZWixc1i07j1Jt55U79fBqP5aChDVRlwxuLhN3XvvKE2
# DATA J3INLngYVnrU9ydUZoz9pKo27fKdaowoeDIYF7TUNjh3wBSnfQm3q6K1Ih7vhSOqU13bFjSRuZtJ4M/9LlGwTTdjf1GJTiKId/Pi
# DATA gba8To7IL+LJdAZFdZYSt+KgCpjNPK6tLCnPfcokGZjI/GzMiirmBqrk0ZRV0sc8eFIGDQa6qqdWfG6qgrqpKt0KLv167Pcjbedl
# DATA eS8mX9gd0qCvZzkZ20criStSe9pPZoMut0sxZ0ew/LDxHFMrUVeXAi55bF+SBTxIDoccBNnn4FmHEIe3ZOjBov8kafPAqSTmZyNm
# DATA IaqQ1gHBR8mB0ivXpnM47evofzBhOXuq9x6Lm4izm9dbtN+Ync5kjVMwofY2o5eizo7vwQ/MSM1sXCChAFnUt/PECKT6ERzsNJxH
# DATA I31vV7Ees7XBdYl5T1zRKj2hiOfDr27c+8qzjojp9YyMq9CPBmPVn8mCp9UXsQw+DZRJDqowjsInKGHpMVH3sGbZjYZ4gT3DUmAF
# DATA CkXmg4yFRyuwp2bKjrHB52b9E/UzHm7IEH+xbPvPP//o8w9HW6/81Yv+H2V9NPgYHUY8mgGqOj688Hdg7bJeq/2VWjee+9cvB0Hl
# DATA r8rZf39V9v1Guf5XXvkqMmCGNkev/6uX878f//jHD2dCiOhQBxJ3eZxBpdhKeS9ykbEfWQXx7r37DvUavMxJ7TsZdHkJnx4oUViv
# DATA iFQK2bZ7fNhGf/+E7EP9OUlf4dELnf4gbnvq8gP6qm+ZmAfTWVv5Z/QVHMnCcKC/z8h0eeWVDx7effDg/kNsoN7a2nqFz9i8ojZY
# DATA 9mRfNTubtmky2Y1u9dKtHd7NiJMhW2Dw3aRe8Saovjc7g5hmMFu3X5Gt1r20hHyAm+/R4aizjYcK3hbN15tb1g7ULXYKFRF6Mcut
# DATA rZ0d7V8qRU/j6ba/c/uV+X2f+ajxObKP1UP0BuodD0b85iygqIPcKni/VJFZ/u6PCq94nvfZVE6R3PJ5u0NhGD59fdbD3ke/Xm3W
# DATA Ck/IynwU743Cwa2tR++89TfvvPvuViGdduPk1i+36DoND1uFrXE8xj/q+0ef76jsURtTo8mEhp5f/1pvVE05QPsCL5bLxtfVWSJ7
# DATA iHdzp7X0812MBdNEHatQ+a+jwQ++xgV1yC/BwSi8/kdyeKgUp4/CXvQO2UV7OKSA20vIr3tYyd7BnXPXvFe98rLLd/i0zdI06Csq
# DATA rgcwZLZVfOffSPdnp7bmg/I+fwWV+JVXaAoNN+XHTDfajkfpmEbhj6XQefK/cwtFjCzgFXRcgg3AH0psTaSYQm1vFbd28MMgGm3L
# DATA g5SQwK/gGp6cRCXsJ+BtxNuTrV/eLf5PYfFX5WLr49LNW/9D8aMbW/kX4r9JiKncL5Cw+yj+7a13Rvs47WP1JPzM1g4/owbiXW7p
# DATA ucTs6ETILVxZtqnmTz/GSV2Kac37qYcNveqf9XHgcL3oaYds3VQmkioGsDcnXfQG6I9KvPthW70TVedj7K/e3tnJ5WlKMZ2Gow6q
# DATA Ij9e8HB6wGSnurpD1c7zN8odNdVVGNNoomKnr+/qeP6y/JH8oG/Enm+5iQ8lbr3TpWLZUo9Ho/14koyGam+4fR9N53rxHt372ec7
# DATA cuX+aF+OBNlJna8EYbFHNeCjz+q1z+lmE4sdXWmsrLFePpc91i87qvGcJ5NwGloOuPBXTNal04hHdg5kr1gsRr6/gKO3HMktsvPw
# DATA tATDFybzF56Wy3OXdrfUnhW5lr1vebJ+PkpnYwxXNLuwoqkShf/4tOfHlDLpKXjH4Da9puD5O/OJWd5aP/7IarYf/ZSexKnVk2Km
# DATA M9yuPvScFTPO8hINj9Goqw6gmvY6G26jkHFLiSYb1L3xOT+UPdYhKHv4aZR8Jahv0HzvW9FY1oT/GmtLcGx4Q8XxeiPpPMHpGvxD
# DATA lY8enBzy9Kkg8+UO10ecZEDBoVMWmB6Z/iUVJHZgUd+raHmwZTCnZXqfWiS6LfQzuKT0zB8+aJYMxXQx7YfYfyXN1fR+uxTZUcQX
# DATA xZGlTJfS4wi2Szg5fIOFBZPJIQvbxU93t+jFo7Azw4FyM5Kj86apalffnGUgldrHyorhXtXcsuPd9LbsmmYe0T7zBN1JkpZACNvW
# DATA 4RRw5Wcff/DwZ++/+5+8X8u3ew/v332sv9z/H++9W/DKCZAeJkxOHf3c63Jo2SuoezqQyFNzi8JhvjbKNTVQoh2WPqGC21ZV5gY3
# DATA zewlUzvhnNGKp7ZrWYklKrDtX+Zuw39bXa4l6C7lKXwqinsXH02ul7Jc38VhL1iXJfxVowGpHz0tLAZdLKoqwaHr/uoWnjbf+G3G
# DATA nJaX0zS72J0k4927sLiWhZvqJRqyT3dHCb3noIiZbwyQTCqhUMkVUXJb3KOZgtxZGiBiSVUET2qbV4eiWw2+w0zRAz5+xhdlYOeD
# DATA /agAZ8F0Nok+li2Uu48nM3XwWn8U63O3Wi7Iuilf38kXpNViVKFqIwp+qvF2/vbNhisd5lwPuLKFbtZNsiXmxewTm9q9pNgXyqKf
# DATA r49W9WOjTDI9nE7DTt+O60eLpbbsv03z3F+b6epkXt7A3jy/P+x+5hcCsQzYhobdOZpuq2/KTr51iry1JpkSqYXsZTmA7CXm1x62
# DATA fAzmugeKtsnYxWisKaLJUMqHhrFOlC8eT7Jp13r6jfu/eP/n7757YsnRkzRLWvZkVl6BLq43IeCwo2YAGIm2VTXmSRF6bj3DLt2d
# DATA 7LFX/wH/oopObsNZvo9D9TvNAYrK6KY06b0XVsVY9Qyb8EufoNtgi6kH+R88mqpI5DpsPrexnU1mcF9JxafgyTeeYChr9ikwnN59
# DATA /gdCrCagv1Yj/s03Xvd42pkyGlR1tbbDuuT9DIN26DG6x8PupRG8lB2PxqdwTEbNnCHyiJ379zEL23o/wT7urEZ2jA+9zdd78WQY
# DATA dbdQRlTRPv4Y5sDHZL/telsff4wS+/jjLYm0FN81dSVOcIp9GF2G228z/1+lUa7W5v1/5bJfcf6/q/jvr390c5ZObrbj0U0yHbzx
# DATA 4bSfjKqv/PjHP2bhDuHVYvFFFsawxoAVXyxXJONIQ2/1Bq6H2ozyeLY1GFC3sMYriGWKek1/w54m/bkfpvAN6q8x9MEmlhPw7P5E
# DATA WUE0X/uzaTww33gOYb6lg9VeSMoP45AMJ7Y/ct4/Oe1PBIZnLlB7yzkvOfazyYAiL52oTgJd43kg9TG8juLJRH4m2S6jZzaQqhGC
# DATA 8vuu3dfBuqbpj9c+5CIyBcNGO1ZUJtEnkVoKRN7IBDTlctPv/fl4bxJ2o19A+EC/eDEuZoiibJKRCxvKtmmalGaeI+lplyRE36Ye
# DATA ZRkfFKl+TgZ/y3HDEx6+w3Le8CQUG0S3eEPV1o4OTyYZY3abKg8ANvzsykxG3jHFwZipnktx0HqmKz+V4vTj9HCI/TLbll3Jydw6
# DATA +t+PvvGO/nj09dG/H317/OXxPx39nj5/c/QX7/hv6cOfjv7sHf/90TfHX9C1P3rHXx59e/QXuuWHoz/T7fjhy6Pvjr86/i/0Ez/9
# DATA Z3y95WEeActeYqCGRxUdOfdYGsKo35YvqbIBeT77cWJbfrx0uqv9Jb1VPpGITA/J5+5sOE71b9EI65wfh2knjsU+wZYzjLW7FT1Z
# DATA E59Mt8CTY1Z3UhPe4RN0H2Mzyy1l01wyLSj2u7kULbEf5qaYeAlNLRGtfIFjaf4AM8hdnj2umnoipE6fasC2moQimqNke0eqxc7q
# DATA eSpycenPvcEMSjQLr8E25fm3ZHclWF5gEJkWrZJytn0+dA9n6I/IuKAZWj4lZsr/ca9rzehz+amm9Q/fsKf1b7zz8P69xz97+J/y
# DATA UV6YZufSYb8t/9xSG1w9y5j4Jc8uPCOJRcsrcQVOOVN2FspuNuI2yD+qBi5ry8pBZdzi8E4pRTa4oKorHN7br93KnGcf5b4VP/qs
# DATA XKj7n1u/77z2YWnnhrrw0WeV/5+9d29u67ryBe/f/BTHTm4fQALAhx5WoMBuSqJttiWKQ1J20hSDAolDEjEIIDiAJDaNLifudHIn
# DATA rmTSlZqa6qruvqk7H0BWrLbi2M5XkL7CfJLZ67XfBwBlO31nbufetohz9tnPtddeez1+q3L1EtyD7KYttvA/nn+utv+/q03+M2AQ
# DATA n6od/4ViAV8mzz9BTvD8z4olfKVefqUKAjd4XFHP1JMP1bPHyfNnUOIj9fczrcZGVkiKwi7AoZRkEtRBpT0im3B8yO4FlZk1lXyl
# DATA 83SXXPFuCh6jeX1xEXgPz6uuALb6YmvQWVRtpXvxeV66shRMw//x/FNgfYrLPQbmpxgiDU+NVM0Jskw1/mfwDhjiL3EyvoD5Uj+f
# DATA f/n8S8USn2pdt7qmoh7Y0ZZWUkefvZx8v8E6aCxeht8rs9YHevMMVucZNAztP4FuPp63+4bF01nw4jcvfgZsXS8e6wgsDTZqX0iD
# DATA jR219XsjxOjBf4PLuRonvWAicCw+eg293eNUuXutvmdXJ7N1Shd4W1cbW8qXXsg/Wld7wfrxt+Tujxb3LpZLajMumr1Xa/59VT29
# DATA UF58I2Vlb6AepwrBja8HoE5HqExWs3uW1uBiX6ulE/IANq/wk92VPaEkNWvlGUP3x1t3tjYRD0Z+VA3tJPgdbOYXv33+RcVwANnt
# DATA uPMfq8KPoSJVTHGG50+ABzB/UJXLXP/pxceKwr4C8gTKVb9/Y80qARnGdjKNdXkPdrKM255C+LLTY0KdPgkz9gJOyJ/U1lJLnuCg
# DATA PmNhR/X4xcdKyrF7zIooNjQAsqHN7ehtjM3RsM7H6c619fWyTh8uDwW4LqkAZ3BiLA2/0J6lisBmRMLkFYCvNIMFWlZkCc/R/KGK
# DATA 4b+NRsihD+UlF87DQ+n3NIwXH0VW7csXH6k5QTKGY+lTpK2Pad/Gzy88na477xQZqwl7ShMJVQck++LjhErAQ00JvNzY7dhqq1tq
# DATA adR/P+u561tswFbs4n5t+m/FFewqfZGeev4RcHY1stXN9arZjHMQBI+olK5ubjY3727tNC4tLS/d722t3dlYfW/13bXm5urG2u3m
# DATA va3bDU5jg9Lxw9aDrH4JcB96qbMLU/Ol6kxz5+47axtorMBBkCi+vrGztrWxerv5N+/tNLfXbm6t7WARvv/WsGjzOHtUugTSu1v/
# DATA /d7O1r3tnebm1t0f/LCxfL93Z3Xrb2+sbjRvr721evOHzdvrG+801zZWb9xeu9VArFk01NBqwc3Vl8JiK4S6etYgw/2GoW1FQMPD
# DATA G1SGLFWoX1evXLl0JViifyPeaZgNkeaLXxGFKQpWdcFL+t5dFNOA9J4cglGdN88oWCLc1cQEwuLKFGlQURQciKrLICR8rgjnS9Xv
# DATA p8BzvnjxGxYG+c1j0bVEBD/ur2XiKxkLfd0VNc4mobFcF57mIoCrsbvnyOdg+o6bvdGEfaDh6aYZsk33dtVXewhmh98Vsnxxa22y
# DATA sa1k2dYGWTbM1R3nQTYcdtSdPk2NLoRQJFH1IZbbPngWdw4osADxK7TPrPDQZD8DB2LSgqCQAurghj9r4PQaztwGtXMHrGhaIKUK
# DATA 4ERW36TujYf7jdo1/eOVsGxwcn2GTFadS4pyFM95SiT/2+e/Q84Kj4DXAiv+FFQRaisoAQQqrUrpF792WLVzHOMiUB/wKc9fHs4D
# DATA j3g7G4EJPY9MRk60xJTIm0kqDM/lBIXGL1Gu+SN0DqQH71D5kgcE/6jf7AcAYibsI7XhlXyhDjj4SFUHpxVM2FOzJPF5Z7eO4r7N
# DATA M/N8FHyu+vJrOje4E8Gw6AT2F4BFcelEGShnObio9UDj1QHUXV1Q8bHgEq+JuqE1iqU439hNb63urN5Y3V6D0yjdK9fkW9soU3on
# DATA O0WdXSUJtI9ee9q6yisur6IHrVorINM/4coB60Zm+JQEEJDR4KGRpWlBlWSpWOdnidNxI1txP+RPfV3WFw+8RVoMEngJrD/yFGeb
# DATA whPtd4Ur4u0CfMxV0BMIxMns3bBF7iSqXCfHCQHtnOfVQDYnY5QWYzNY2rLitjbU8KztC2MhhZKSptGyD6MqWeXn37PlWoeQPAMD
# DATA K05v4Y4pHBIaD7sdhP9Rs49/ytJQABY8wQ5L76lnq/SRHExlT42Jn5EacxJrDIyboIor+dOGPl1pudalKzbc/6Q/7qHFdgjqNzlc
# DATA WP3DNAFSlTUc9RwHk65vrlIFcBF9q9vfb3XXNx9clYder9XgNA2rz2XGWLrXj6VL4cQzhQNUOQf0spIRkhKUyzgdQl62YhkvMFCk
# DATA Nu4pobt0QSoi2wD4eMGRxvsHFcZY3OZdXBMqEoqVQWYXxw8rZJI/JcWYuid8jkrzZ9HjAV/QKXBd5KgnyGI/xuudzSES0k88tbRq
# DATA 1oHgbHuZkdghwTPw8ic0dFBNxW9Bfi06HQq4m3UOSLdsTsvdfmlG63ZWlaMCetqewl3QOrhqyfPf0cn7BLv+S3zxRx7rZ7yqf8SV
# DATA wPvLTbhh6HFtrO28d3frHU9eik2xpOvo83j5d47OlSUuXgbfWRIcD0iEbtonnifYs1Cc43EVtGRkltBgAhFZ5eALEtALP0L/2PpC
# DATA 4DV0NnG4t9YKRkTt0KsVSxPrC/kAr/0/JXgPp+vpU23ItV0/HZWNvkWhJPUh3nmfJe+s/bDx7urte2uiJ1EPPE8dvAno/Nf2pYD0
# DATA lRBDj/l14WIQdTZSNUwZRrTnX6KR7VMUtr4ircRP8aJuXa5YN0vaHLh4/TGd41KCrq4yGmJ3jtuYe18xPZ06wd41Vf35v/O1D7Wl
# DATA NLXWeuFTbwDq65/ri7d41Kue2YZTiakwBtWFqX7Rjvc2X75d13brJgtCLkzjZ8jifiE6ooCPET+GMX1FQ1eD+k3kVmu2LVjKmvlx
# DATA a+XKVXs07c4RRDM2xEOgxkXKxsvWsgujJSwd7sftgLDJDo7Hvfdhk6EY3W2d7LdbdbHoYS4GK+6gXEn2U1+fTj2qUYxyCetzxsXv
# DATA j7NH9Je21VAkahMGoo5U47nLl/d+fxR69bLVrEvJSojlDUhuRZ0tODXDSMAejGf0AEzW8IH6CSfYwFgSt99eVTO3fe/OtuG6oGUc
# DATA OFbuOSJESINGNZdNZ7CbcylAkGiMkRytJ0joT2iPEkGpjaAPazLFwnAX7XFANAT5EDvkU76YJkl6kXp4ER3+vV7KmjxANIImLY2Z
# DATA 9wqdIj0wdqcUHTd7mdBBXAQpfb8Y9h+iKBj03fZiKJPaBB2hbam70FSi1qFVPUTf13KSlLzVKYP7Xv9hsaFEzAAoxkO3oxJN4coJ
# DATA k/rKkmHwuGC18YufwwnykeJaX1jsFpMyNnAGF2N2CLQCx0hRXjBZq6cBswACFztHdCz/7PeSJTTqJSj6p1FhkXrFGh1OIwrYMjbh
# DATA Cgx6pc574y1eozjsGrhdsJfwKPMfiqt3rp+wbOMU1NKKJllUOxHV2lIH9QO7mIoCDF0+xMjadSpB5wNQafk7+l7v/R5E62vYV/4i
# DATA 9YKLeNzfb/gkZpEXqtplMdwVgEeyAnSW+0oTnDQ56Wh/hfNYjk8Pjoxj9OETvBtaQyke/gbCncAr7gDNQ+out5wPqSSHr0LuiGGp
# DATA Qwyzg9wb0BowngYr2pXlRYS5dK9cjldpDdejkLK5r0W/xKNAFAXQg107ZISnDejssKN6NkQXXq56j6I/oVVk++KuYYLnuEs8Bu6W
# DATA sxL6myKqnPKtxRJ7nUMSCayJmOdLfzZAx7HLWURSMsRhWhq8hFAju5R0hEZP5XEMWTvdc7irfEB0BMSBqqCtPuUP9GUId9gYx4sk
# DATA UB3yBx7tzreh/m8+UJkl/4PiXH9QQrG6Kr/4R8PFSFWpmDnelZV0pq6jIJoGfBx5oOaQJDq7V6yBcwq6JhDm9nhQukFkNktv7ef9
# DATA LuRTsyaIv9T1LsKDhbkOCSWR97sPMFNQ3hxm3dao8yBrjvp2nBQIAk5ZNKmGoVaOSF/V0soUef5XLBAbB0AS4p+AhRVnFhUZYL3H
# DATA y/jzP8C5Q7eWxzjfTywzogxWNg0yq/A4nN1hPLp+o+pWt3W84/8U2Glxh10x3Z2rBaaAXjYeDVsAJEGUIBoJJddqLBlAEYL5N7YZ
# DATA QBM86kGIL+VR6rZOs2GeQCbXpHU4Ahzzfg8TyKKf6HUGa6EgdEJb0Q1pS03MwcbwNzkx5bvaaeukax+l5gU9p7CQauF3he/V672Q
# DATA iA2yzmKi9er+Rihc4ojvaVS/yq25+9JaCHMNtCgLdYm4QjNqDzwEefUxFER11AvfVvzpmhu/jeMy91HYcGepoCel9eRsYjQhYnO4
# DATA uz3N5OD2Ar1T/Znl14WS7WOUaJ/h7gSpVru5i84PpQ3YJj9nR5EvQM3wRBt52EDxpIDfkqWNru+fos6N1JbIi586igjXE8YsVswu
# DATA yqBFsvOCeyRLZfErinV4UrlpJ+eCc3Pg8y12hGMnk+8kjGpLuEwMNNTpVdHZVU8vY3up+/wDAlHqd9satQnJacE/U2c5YUcvKSDU
# DATA o9rhH0Ch/OJn0oFqcLek6HuRJ6RVdqE2+5dnFAvJ5EXEzd1UzznY0wzn5FFRa04pkDVBNjSNuV4RBnVAyyPoH3Hp0vyz4Rw7xXMh
# DATA qgaLl4pM5PXANK296AvZD0lO8NgWm4yS0FGuhZJWfY7oRCFjLW6jvwnCWDhiXrGydIajRuGUaS9lQaLWe8tt2R+ElI9KM/bL+LVX
# DATA SuBNhVqiN/58necSHA5yjpuvu5a656jdwPxL6mxAHO+sJEEaViBn12ANsAlJq49l7UD1D9ch29p0hifYIQtzlaQJYAqi3pngpECx
# DATA Ap3U79SIP0HTBxmNHoubahKKT09CbZQkBHWJV2/uOS4BGPVJVlohFwjgL7wJ2LvDfBslHfd1nHhMGZwp2dphl6PKlE0zfOsaLB2m
# DATA YEmJ9cFPMgLaJhjt8YmtE7JnElmr1TXXGC8FZ7HO+XvMPj8AcNhSM3esRE1Tj93JYeekhT7UxQKW1T0u7t0QpRK2JE6n35eYdcA2
# DATA bPWSMStn5LhFput6CQhDt/tMuXv85Xbjo2gz0jN7cMURU0B2buQS/2PuXq84MnJc93zfih6ydogGALiE/nduQ6SbNu2LFnzj7q21
# DATA 5vbO6s6ajodZX9vGHctMFOGB4ITlzphxoZK9iLnOWB7K2+SmAk6NljjgfGIORXpw7NPaRuWbL604MQ6XOenkAFbtRoWRqi+PGxj5
# DATA e30h8fgGxyrBRHr2GO6VgMLoaDzbDhJOHan1o4Nv4Az8VbLUf+2118yNWM+yHSC+lRGKBCMHZw86/XGerN9ZfWutkoxzSowA/oAP
# DATA MytddG/Euj+1WQaAhmnVSEh3yU/G/VEr+bEiCTjYcSEfYlz4MFNTO84w+ryDqEWQvavNt1gMyxgPTLg5ByMSC6h4Ow/dCffcPSr3
# DATA M7ekrR10JxNv0vPfAOUgxa/UYnLPihYIy1WCO5v2oe22ek0ClgS9cpOl+RINrUKzDDH/B8cdTANvuXIy5ggzhHYDSFoUB/zDUlE2
# DATA qUp8YasV6PZgck2IB5UOeVXbEKjAYjUPO4DThmv6sDVsG30C2H6LVcKkVsdgEx7OtHKB4PFP6IJhK3z+RNZRihR7LEbeBKW0p+ry
# DATA +RF5xnhaIvQTMerxXxf4FHoWX55sQcJyIORiSHGKD1OyZ2DC+QcAi/XB/e9GoOFs73nHuYRUi9CvZ88/Iys2KKGURI2GpI8iU8EX
# DATA Frh4YwRJbGgPKDAZ873rpeKHhaPn9+74Y17qF0tv1O/X6M/y2XKFgv3o63kGLe6f5Iz0UzRfxIdKZqZwfEJbTTNQl9yCsQZfsL+h
# DATA e0SEk+J/95Kz41dTntegSGYee6Zcp9+I9M3YJei0RgZ89phJFM9V0m4JPBrUPX5QQlAwxy29po4kiIPaXdpLLiSXy7v1y56YBhUH
# DATA swJ7gt5MHd/v2SsCrtmPkYR5uTneSI8M9EafkjaJBw6+H9MskNdJbw+c4t81x1Ak9XPaTI4X8qes2H9GAemk8RXKMljQubt97Ddc
# DATA WB2BTe8Dlwwj30iWHb8oP1+1v6gELRhrkk+nViHLZwVzD9g9ZE7m1MnYROqd69rZO/VbYWfJKTvABAW7NneA3zP+ENpV0+mG1z4a
# DATA /tTUOIX0zdX/1N+4/syZSTnHIO2+BkvhV+WjY9KCWosxf1v8rXY7gmmQZ3oGrELhkCw/5IBKYy2dwy/F8W6gWO1/RB3iTyk20+NP
# DATA gQHnqY4n9DkX5VaA/mKCDmf7wZNtEq8AqtjdPM5Lsn2zJEZOa0omooJaQEPvbqNJ7fRktvzdYr/TlarnupcFsxzM57+q+aEp0N6v
# DATA f8LAwk+CSI6vkCV9hP/92fMnLOOcdy4HA/Sq2KVkJ+yb3miYnqPjXmDzZopwItmB/qhCQ378WxO2RXGF1MbfBHPz39WQPsHgyscv
# DATA fv3ivzHzlvmRkIao1u3PFNeiKmCpAVynf4YU+5Gq6WkoRn2uY14Y4KVREDXGLvabmxwwaIHLsqBwaUX0z1QVqp0vL33vqszKwTHR
# DATA DbZD/nVkd7uPyGr30WsF4VT3wln5J2fEBUQR1WY/w5MPnRHxgTWGIr09u1hMUc5r3XfhJYq9I524uqjrxl4UloCUkai5X7E5H7uk
# DATA zdBZ/osVpeuL2DIvXzKdfRjoMQPWJapMrduSzAA8dnruDB87VgluR3m2Bk6+m4gmWS5r6z/KZyCKgdN0DUCP3s9O89LuBa6Hm9iz
# DATA P6llj0agCp7Pviy+fLb63bNe6Is01F4P3M3mNq7PcXCEquN4oJ3uqei9z8g0gm6oZP0DjzBS5tcjvm5B57WHsrB8SPWOE+HYn9Oa
# DATA 4gOpmRtJ1URhN/4lGyiU/irHzhbtauT615p9QaXpU0EpJQxqd1bFX5nkdCxOSsspHvg0YuN2Pxf483ksP7igGmy30MaLWC3RRZ7i
# DATA AqM7i6tkW31tBxfjGUODdVbSaHNsT6045bu7jxotf7s7wewAJUNBUIvxAS+aL8fj7NvaF4p/sCsmYM/V2lk2gD9YUWV5ChqBCk72
# DATA tCJcnqPFQTv8SiN4WOSKU+Af8Btxkv8SzWpwuCMyRQKxUmrO/gDOOBguakLEX3wkR7uNkWAJgxEnmLjUJpu/IbOyazb4Ho7dgFbE
# DATA txYXD4Ji3AAUW1T5Qpslik57R9wuopXs8DBDBaHqfEk0h7PY1Twj0hVPG1Oxvgd+/FHGg3Ke9mEtXH1zt3hcNFwErYa11d2jAdJz
# DATA J846DEGiQkEMklMvjLUUid53GToX9xABnOmkItS7Tt9YbWq8FmDUzCiUNrUJuAqpCNN4sGmjgVeUQuZ9jmsHqki+oIgUIDYT7cSR
# DATA ahxyEwP1sGCEw30nDMulr6gv1TBT9N8BARSI11tRzp4hEaW8GH+Ni7G7tFcbarQifFJd1vhFdSljL4fVFqIhqV+joyEBicvfP2E4
# DATA 9HYHH6s1hWQAgAmuZJRH6CjXarfxiRLIssPO+2nUOvn83wp3Lmz2XyrqB8H0Fxirpdbnc4oCFQ1VQjvoGWwU3CIYgAblEEzrQ/Sg
# DATA /LV9Z/rIWhheh12eQIjkwr/8ArVBf1BK98edLiTSQCOCZfPZOe7kzEIAJwRMCH2EqwMXJ0wOoF084PVw0O+SiRtOTJEVrPqGkA81
# DATA 6wF9EDAx26Agr0BP9QggOLsQvKMq7GHiAx0/BnDF6kCshSO0If5hnGcXLsQCHn3pyySggDPUui7V+fKmQQlT0O+n3/2uxCZrErVP
# DATA mRjXtc8Pre2ATllmKbuLYcV4k9+L9ZlTgaiyBHNl18NOpvSZGzeLinE6KSx1OIkF0rvYdwtuQL0lJ4edDkPlhXMVHr1RxlA8UVPW
# DATA MjwjnML/k50Qeu0K51ybHIfIHaXk+sb2zurGzbXmzg8312BZgZupHYKMjHB6+wS2f3CctcfdbJhOfK0h/a+03+93Z5Aec2GShJ35
# DATA FP7caCRFVWgeVC7ogDXzaj5YNwotqV/WJqRdSG0J4Zedw5bnCfQI3+Cxq4UcE1v7mAx4nyFO3VMllj7j8GDHe2r64UuwtrgtLibp
# DATA 9dA2EmpdneBRMpNpZ9onxWZU7b+urcGui1bID+pW5huUKSPcxaPhrj6yHSI2+jNLvoQvHG0ZPJhbVTZb8PwqJng+jWPSoJn5c47R
# DATA nyFcT2Hds9j/DEZOV7GDbovuYk6LU1mDmlH9nc3QMU8sv4jtoVcQCCcutkyfoyfOjUXADK0oitA2b0y7f4C1iQBXXBcC/4JvxWgc
# DATA /FKkHrD8ETDfOSneo/ozdxrrCfKb2OE/cQMp3Msx3nJtLFMdPwWMriEOHKF5r0Ha8Epi60Ybu3iZJ9VfeU+/NCrEhl3AyjwVkbst
# DATA H2SEtwN09cDwaH+5A8XuqVIsGxQW3CRGT0gnRt9ZUJe/5Qu+2NTSvXfvNL2faX7HqN9rk6r++/Kkeln/uKReXPtea3/PeSJ/L5Of
# DATA nG4szmYI1WMqzGcYGPE4Od/58BTZ/2NyjPgF4KGIK4DBU/84iJDYLVgAEITNsOzQiTPtKVFPliF6R6v/677fKMoS5LnJGiemQTfT
# DATA iw7oBCco/bf6mDRrqJgyqizKEAUOXnXRs0i0r3pCo4Ju8a6FUvxnxT2rt43nVXQrTMQXa6YWHzXhAqWrIVHwZxDUUWgJsYB48aIZ
# DATA 88W33TYJ/fHaZIf+uDr5W3bQvy+xzdgtuOR6AOA6GU+oz46Es0pYlh8w7Ud9xYO9Cp7CtxT/GjRvYloDWGXTcQ8SyT3SHbCjr+BE
# DATA 0foMdASLGXLq6jxQd+dP8HiQ4wP3FetfDSZ1tWoH+IRQQoUrbLoPvjJ2bqU8opB2Jz4IIMwNzscDTjMScxgER0JDkvDL83ZCYBKM
# DATA 4NTvch9ybU5PvMJImT+D8w5Y2QqP3LgWOzQ5QidnhQOVrJI0lL2iTwJfadfYoGfkIACoZCW214qrzC58GQFgnWeCvqIAGnTqYmHp
# DATA c1uzPcVsbTup716gjhmuq2SGC2awzHXRrhSGX1p+60H0kc6+WmxIMPETIQYQ7AiuYkYAjosNJP4MnmWEPB3YRZLN/GT7h0mVM/gP
# DATA nDfgCZ3DUxaA/cWeQHHDJJwgRISo1wHdJ51R0ZZk80fTBRmavotfdkvME2uBdXhRFmJwjgSuBQRUnztuNk46ZKkOojXDIA/qlGXp
# DATA xwfG0k8/52dNs8z7TzT3Iqi5QupwUHWMWzpOlOuQPtuGXug/bmfgCV3HTQlDXB6L0tHmEvNKxObIPyj2MZXamN7oFk6Rp33RvZ60
# DATA ekoCbyeg9rDyxrHTPjUCrouQzBz+FTdy2zU8JrnP6TF4LmRyoRr+pQQISN5+Hic2S9CmR+fBMP8L7lzWuAtgGQvdri3WHFBCnQW2
# DATA VouJkuv5E/SyJQw18jSewjKnzxrtKn0/gQpCZzxLMIlJ70EObtvlzncz845kx9l2zxF8pZZzeKcDUDI62DMuBFzifA3ebDqJdSJm
# DATA Y6Zlc3RE8Nnet2TgiADmK76De2kS43ziACCY8BlUnzUhkKtJ7EkCuUoc7ALM6lyh9y7SGP3jwIz1DHw4tKE3hLTn4qfwZvCj9kjm
# DATA pt5QAD5XY2JMiyCSwi1PZWZJsFLKyN17BjxJZPX5gzaDaDodQoezEonZ9AGofIQgM/RZKEEW6MC32eEgyHQO1hkgEqkblSuZuHw0
# DATA GHRkuFO3pyyr7Xq8VyRchYQ4X+jo/6pho8U0Q2GjrNxuIT10M7AU9x/2IGVjrzXIj/uj0PhtYz6nD/rd8YkcN8adanQ6ABVTut/p
# DATA tdFcRp2u2/kGwdBP61RP3KGx0PZSoevEb82nIBG+lC4ucT1t6y770Q64WA5psu6RqK2Roz8mLtuIhsF710Q/SJ2GNw+jMTu5bHFp
# DATA jSb6dTXlfkdiuIL0q2wdWYJJSr/kGGyOKQuoBEGJL+Uw62atPOOc1fWFmY6XHrjs68nlpUDTqO/WPUW4w86BdghVe7j/IKM8koqw
# DATA SXHPXfDdQKdnnvnexESu4U8dvcZtlot7JfFmFGGmY8v4Qye6zNV9wWcXk9JSpZxcSEqXkypf/NTzcjDRaEsp2cGVM2M4/bDNYAgp
# DATA e7pUzGC0Y4r4yQSeRguuq5KD7TxqHSEiKddRG1rgzvXUE24FQxk8miiZlfq8HgIpc2VBVw01zF7HhULE1LSE1meu66Kqq6yqqJYe
# DATA BI/Lb+CLN+qtk/bVyx+0hidXL6uHeE4ceaBMZnYEeVSD5Bt9UcXCWg1e+us/HhAQcclU7mbDNc/t1H+l9Oj4YFjr9E0eqUXy6tK/
# DATA QlrjY6PJAOrGm1OLU7ppM1BEqWj4BBvzkTCQuLgYutuhC9uC5zNzZjzOtA8a/lEdDPuPTr2fVbrUD20HNcu9LXR1Mx5u5PQ2CajR
# DATA oInN7VUDDhYYjTqfI0bcAcfybHcwZbDuqOsGGr5dxNZp/h3B+AgqBCzFRlJidbnozYWMtBQFr/Bf1yxmF4v0IdaxSrS30ZJeU3BO
# DATA KYnG6aXTt4m9aewrNY0YMnTAH3QHpcwuPIm8TVo5OOj5J2DuQxqQpGRip/k3H08W0EHeKJWdpNNNC442PGndeu1MHU2Tz7v4O92+
# DATA HNUG/UNL3FYHGEnEiL1WIwHKyHlCuac7wGslgu6JnmejyNU9ibyzpzAO2cBHwvB9Bscwfv2PqoZeeZb8jFXWFqUqAq9wB1UY9iKV
# DATA C+1QNoX5foD+2EVct+vSBjDr6hRMTOxDXSrVgonh5oNOrwf26ChJMWs30+owdj7g5zi5CgbJcV67MfwG6dnePKPVb+aLi7XX2I+F
# DATA VwUL4+HhMwE7tt8UQiuXimN7bfcQeVqWI5CHoa4rhBkeVOz0ujP7RM9N6AON3T7iJ6EWD1uuRxzW5yKYwlbLESo6PyVN3zLUPz/K
# DATA ak7KOSRfNuLXTsZES6PZBk/wbiQjHmcF9F1tjQctfUiFb8f9cllasqUINdYauSPURI+TO3Hgca8jsd6WfffQSH2mbCSkKRHKkAhx
# DATA jzriCcy8JfUJ84ypoO7OyjqRhjrLWcKqc9cnoVA6R3zFXOQa64AzseeiS68v2PsubmN7DfrDI0xUYuirRrcwF9RlOqnrujuRi7q8
# DATA LIdu7/4WOdf2oJDPikErO1YE1Kuwm7xcyoH5ORNTCodRCaSQUJhKHXQUyojDIChP0aXysZL7SAnhCoilcFCVQLIJhTW3Pdc7AWP2
# DATA P8cWUZYqinqlGfLoQnsazNKo8L8BTpfU4Pu8yvPXeSxhkNSw1VErco+afZdaRSxldn118WRsH23JZg9Z2/4bORrX466uj/E7mgL1
# DATA YYWdk9C4JG+JUjx3A4Ewtg3A2svIt7FoBCY9XRVjqImppKZaY2LGkcVv3DQCi2W+1bpgYKp2ldJFU1IJnccO3vX54H0LMeVbEjYZ
# DATA 15pGUQvYA55gC74FVILUc+A4F/oCdS7A8oj6WWi8oG635Ln3BF4OM2H1wT0niGF98WuIZJNk8gZjlt5YKEzG4MPEVoSm4DmW1M+F
# DATA SWqb0jG5y7fpp4kojADTQKDeEilHSe3IXDDO1Xm1f5pkrWG3gzIW8+Kczuis1baq6yPa40Dd4VsjRnDsqMo7J5n66gSk4/y41e4/
# DATA dPFmayHMgus3uvgf6TW6OMNnVPf5f0qX0TloTg+AnUbNIng+o4sxj1EXltSGJmEXUnc31CRA2K2rHoHddeENYm5a9QC6wVwr7I3E
# DATA Psn9nrqDdf0MDzHScLQF8qHbH1NfcY9o+cP6E2LAiOINB7UHqUROK1auA4lL0UwZ4lE4IPfftZ+gFVT9lZOr7Tf07HxUocf30kgv
# DATA zNAjhm5XYIgkhrJ8F6cAPMiB6DrFBk/hDAmRhOyi9mNT2FQQq/UvCRzBxzscgsIAiwHEXM0ADcV1Q4qiOhHpfGVh4hTDp0wBgnAj
# DATA AJ+6A/Blv3oUHsIR76KeEMihp5bw8ESsC7u5wYVNxRK9+Y1Fy3jNlcxOK1JKW7AVVFNMVjZ99RM/xzCatGfUBdx5gtH0UvlDpuQO
# DATA 8TzKxYlvCku7juBflDdOnX+fqad/lPi5r0gG84A08ZFBynWSfvgew7129qiiJcEMTYMtjVA9EzYnlg3n9eTaBciBg/+Z4hhuYKPQ
# DATA 5fvZi19KDthPaKzqgZu+Fl1wwHgTQcmR3Bl1t5eVRNJR1JMwZQZnqINJgJInZFFZ6l9dWpoUDtxD7VB9EpUoonh7U2KDelcS8qZo
# DATA BA745YgfcTSnRkXSUxWnmrAjXnDJtX5D1WQ7TQiZznZNOWTXE65wMs2VwpZEm3IuGUA6OpesTKCIn67E3YaTKmMmzxMHrphZA70o
# DATA LUtA3TAFy0hRjznygb1Ux8/xX0QKTrRYgTelkeXXNEtWtzOQ5vMEeE0C6b1O5VZKaOStISgbMWcqobljpVZdMPu1ZA0TiIGwoD7L
# DATA EfQdPcG6bYa0HgBgBzbCEgV6dI9qcZj1UN6a5d1u74W4HMoI2t/Ijcu/bfmyqiD+l4MSIdT//P75Wpb6xvyT4l7/Vogxp/9aw38U
# DATA tTlp053EV/YOi1fr7juLEYBSTO7hvZEHImSJLTZMAWo0CMbAHRaptNqdHG+/JQvb3tJtaobCmPYi7QIx22j22l4QNy9YMV0RGwLL
# DATA k7NNCFrl77mBnsvyoHkSNcrKFS4THPH/HGYIR4hTzwudQ8V4/tEj34HU9sKg1Kn4M5PYvkhe/rXWumBXm7CXSvyDT4D+8H0CrXaV
# DATA hfObT2pcBWj4DIJTVCPIJR11oO4A9yBdTAt8+a2s9wnOHMEqPStM8lUoMVWr5pgrQECFB3vazM0PWC6dc17oMGjSmelDW1X8hmFr
# DATA lWQyFpOBNYV+pnHkvo7Kkh5bQNQUuFL2FX3Tk5U7U4zQvA7Y7NPEUgHOnuKIKoVwNeKQvPPlcubxFsBlyFbUr2103LhOSRRB4WDt
# DATA qiHlhKnreiCf29DGcOn8EPfzr6zAGU4A4WlDUTfp9JhaaL6z9sPINvgf8YafkqoZcttSk+oaadfjaAbOECropMWwALYYZHHtQA5k
# DATA yiT/ZOKhdWErHkyA56bMmLeOK0A90U535jJIbsn092663lZCmFuxc/+uqy1Ddeyh1D8atiykgN29yZTs13X3jIebfWezP6Swm4H6
# DATA wwAwofv75t0thIheUf9LXT9XrIBPQtWFXq722Yl2loofiezI6rhIVVxwA0IYSVPtiRgFKLHFza91fjIo+7lOQcvfhNFRiv1NPCT2
# DATA MF5qLkjDQvB0Zkapd+kgcVj7MMagrmLeMHwtBu9D+HlWOphvJsuzJ67uMr9yHOQL/TFcP4xJMTDbVDi2UoydErxXQG7wOBCXS1Mc
# DATA QMsvC7zl8eIIiGHYu9gX01ANA3ell0WqjOKgfUs4lf9R/r8vCzuqM7W4Am6Yc5v0sZ+Dh4E2E/72+e8qCWOsRdWeDrzTtwAdyL7L
# DATA uNFdp60i/D1z5eprz8qC/VXC2ufE67NcwLXretUpbx5bX1p3VfW95neFfUIIQJc9Tsf6c8suFJCKiPGEyWe6Un+JzTgT0PQc2z9+
# DATA +BPM91RKN34rU2RVRxEx7I+UIER+i2qT1aWKXfWDApbVH2RytSQzvGDwC/5gUlz3riWMII+EyzgIK/xpscBSjulvQjzryGaJgmPO
# DATA jFzeRdt3zQqPaaTA+sBJpgF6BDOmgpJ70QZtxKZI7aDO0guBVzWywR/ijh4Rk413eu8cAxT7HSycDIjcMnidK8ZLQ/dHTmdZcZaE
# DATA VMUxxRWab/nLc8792YUL6lEluXBB1zAJU6pXnO3oIGipr0uqr4Mu+vkfqyOERA74qwn05oqquZFSpSzYhvuws0ryRKyfef6QEo4T
# DATA +l5eI+yy4+xR6dJKeUEnRUC5K4bX532hSHzz7vbOW1tr283N1e3t9+5u3ULNPzXkRU9Yhe9tr21hEIV1WuqXt264r/xaPHDBQ+uc
# DATA rS8uyo/6mXRj8teGe7f361cuX1pZLK79za27GzvNtY1bzVt376yuQ/h+ejwaDXJVN5CaWZF0c3Vj7bYppt/4VW7fu9HcvHfj9vpN
# DATA U9iRsMbDbl5yVtWsPGyt3Wt1uGW9/d76LdWz1Ru311Tv1t5cvXcblkaJH+MsHMidtZ2t9Ztmrlvtkw46mcgLWLHoyq5cLge1vbd2
# DATA 4+27d99hgmi+vbZ6C6uN0gVr6tVGhchFJmYtQrtblAgulJ4HrdEoG/YwAO9HMPHDrIbw1Bns/DJGzTVqF76bugKd5I3kzyvYC7BG
# DATA 1u54bJS7B5+M9015TuzXrCcBg5HKDruto7yBVU5JbIv1X2wgwKqqIWRXF/GVzRzgE2YGiAABvIAmGCM+9zPxzKMfclvmV24AJCZG
# DATA EvhXP1cS/H41vT+83wPc11fP5e+HgKVa4XEd3Hs4TRQrRc0Jy9mlbEh2AGqHP8jGyCKdY9MZtE7Boq0GB2aIGvwNVq08u3q5tn/1
# DATA MlvZZFoED4oijRwP6khWOK4bT9r3yy58Dr/bfZ8FBvbQat3MhqPN7AR2zo8fjjbH+4pvv8NQ9aon1mv4qd7ALx9Jl9xh34V1Jy9Y
# DATA x+hQMi8qyc7pgP4MVsWe2E9B5ccOkAheLLkXH2NmAVIJGmS5xwAlA5CxP0VP4589f4bKatLbIoTTs3jCU6bMw1e1YNM4I3qb3O+Z
# DATA DjXSM0Z0VTT9KtPww1ZnRFAmyEBLErvWOcn641FjZcnEGlshBBgEr9jBHYQlodhCtXrtVldJkmkUcSQ8+VixBHXdwicC/uDuHKsY
# DATA NElKKHb2UevaOYQjOpuSyQtj7lXJfBGsbQfHqqXaQK2/1n6ZWgKkCSC6peT7ThnPhv/9RrJ8aXnptZXoBv0EvQ3AveAxXArdDDjR
# DATA lX6cvL2zs7ldNfg6OhKOcns3nN4Y6zArubLWIbNMyc5bhf/dWHtrfSO5uba1s/7m+s3VnTV8WrvwBv6rztLgXWol3VbVbTvMC5oJ
# DATA Bvz7cDjBYPgua6nRRdH7aCD3Ay99eJ53a5trd5ow7Oaor47VLfy7BJ1QR2+5XJMs4mai8OCALyn7d5PhL5r8snTQQvMa3BCs6Sw7
# DATA NdQYlwcPk+QDqu/dta31N3/Y/MGVpe+p41lN2ert5s23lcTgfKnO8c7J+MTK0Qvf7tzeZj97+PPBcnOFXchbbUVzQMSw8WonfTXF
# DATA 4BRXgjOU9yLZoo7BxhIU+r6uwgJZCSDXOqPjJAe120gmRfW2B7Z3dUMopcsrr9WW1P9bTvVJZhiBGk9pBeLVH5VqyxXdXNXvCmTQ
# DATA beWKlz6M5AuHDsgEPRy2Bk3qTUmVJn1dNmwKn2ho4QrqU4xrPCwS9BVJ+hRDxYFZDbJsiMSyr27pQ7WW/eEJH0SaaoCBCfnVC69V
# DATA Bv2ewBc/BMc5BwYLDI8QJvILyVtiI1qqBa/Shkdc+5+m5YJbC3U9z4CddkuH6VtrO4qFwT5aXK4tg0DwtpqaenImMzSBZzf1Uqqb
# DATA dRf8CEByUP8Hid3wOC6Xi2ZvZWkJ2FgHlULUvGKfD0pXlldEgVfeXd4DOru8tFQ8Qxa7t0/Ou9t8bNpH6Dp4EvlnqFyBDBEDeeXd
# DATA LBuUanz7oWVw2Yqd4ZjX4EMEn/5TYsFifknZMl98fF20bRTT87EkYMY1rUTZMmZU/3fKNgNGVBT+qqSDFDM//uIEeSVzB8k74HSg
# DATA ji3blj/zIogyjHqbpnj2Sh06Hhsv74cpZSYAnKBkCXfvkrpU4bEpX5QnwHqu3+9ZRXfr9b3Cco64e5imKe3M5Oxswapi3Os8qi8+
# DATA aA0X1b5b1NrtxeG4t4gTUYPNDVUmqIttwl27f9DvXl84o8FN5JKudj1OhSHo62Q+ybtN+4iPtDbqeqd69MsmCPYFXw+GnQfqtfut
# DATA 9DVPkE3XVvjfS1QERKWVpN+7vmANAW9XedI/PLzOxhF1TC6O8+GiYkrDjCZl8Xh00qX3rfGoj+505pMMtkMTESgvL11OFtV/atYH
# DATA 7ba6vLXaail+UL1JJ3MVJNHqXbqQKprMe51DJVV3H7ZO8+CrLUBSGWbD6mZfTf8pSNadgxG7+FUfHme96sGwn+f8xKmm2ydFSPKj
# DATA v08WH8EEgBvNohAFHn3dDkTxqSOiud9vn5J0tHRdvz8aDg6aJK7QoZJcWlrKvffA9qa9B+6Af6mr/jQSxC4iCVIFk4k7DDWK+/dr
# DATA pTdeeZh1u1UEfFgsq9Gok613Cg7Q14NPYLBwqpK7QvLd8bCD/1lMGmqhsLz6/2q/KHZAaof1zXevNjfWdt67u/UObGXdxWZn8OBq
# DATA MwPtRp7ahW/e3Xhz/S1Q7WDbaVtRJ5p90/1hp024GFmvtd/NoIrL6gVGtTlPIf8hHHAVu4pmf4D482e28a2XjUApXaO6a0dqq6gV
# DATA Rz9MqSjttUbphKvSobdnrkULylZ5NOqTZfjAxZzH8TJnFMuvm6Cc+t+uiMXcZpZz2HZ5KJap1YY8k7du5ms/HTkXCpAc6MRZ33xw
# DATA tU7pDcjRSG5zzyhPGSaPYxhlRgDV/g5k+vGMsKoHETIBEzB3xPJaB39a8kGSl7vht3teyHh/IPZa+Z5ubzZFRNI/lWKlgfCYBOm+
# DATA xz/QFOSUt8lTxxgbWBn7f1O+vWq+BVqOFH0EuqBWl0bgvsMMbPgu1qQ3vtkGW5u8afDLaaxinu/Axj1zm1Vom1Hd8NfXqF1PoWLE
# DATA +U/GGUQDkP1zLEuHf0ZnRvz1MGmdM0uCEs8FLiZpE7RkIRESXvzsYlFnI95jzxCOl2a8yvvnmTj+B95U2oJqS9sFMSVPtZP8eZKg
# DATA 6gQjRQC1sGu+DS+A2VgKTqtMCkhZvgcBGoWQxRaZrWny7ToSzNTyFBIq0n0GJGmK4P1YTNuWIA2xxAWOX+yp8lRSan714uccAo5B
# DATA 4rOM2K3RqAU2XR9tS/P1ckH+OvkwaqSzaiWLJArWliVSCjjsUX9lISOZmlRVk+JWUj6RUmprMiXdrOl5YbbZ2ScSeunFUn0ZN1p3
# DATA 6qIkkp/mB6MQ6owfB0dIxHhKJQstpaYBzCWIcSJhKkFBleXSgSEbdMmeS72ij/vIvu+jq+n9Wu3ifXXrz80pU0nQUoEW/tFQUCiB
# DATA Sy6lsXtuaBzh7oh1pDxte9EO4pVgDHI9+tC/AzM1+Km/tDeIxOTamOPBVtL9FWHAIuvQoGPNJmwBcDgOOHf8+h9s2VAIOZtg0K/0
# DATA w77H4rLzm5jrQEfdSEbgauQcgvJcLeJS+JUcs0VfHz1sTq8g3JNSHiLSR0j2uvLvJ0uR3F1+H8yHQe9UBfGZPcde/6PpT6EXrByn
# DATA MdmIpmfXTCxYy0Hlt1zRNU/5zJ5R60t/qGENQpDkCqLXaQpZGkYanTM5F5xLgHxi7gBB+zGZGoPoZFj1ZEnJUvZA1ZPJguOWEBHq
# DATA 2ZVB2pmV7TWwU+odC+48EWFqIUK38caiFEWSFKRbU2T1GAMM0UD1FHVoXxINUeZCybT8lE1YIcuKpV7W5zRMp3RsoejMia1eOOiK
# DATA dxsMbtFly4F8+kWL/J1gztQR4kxX/LtSgRDC0h4yXcv9NBQfa2RRd04LPeppa8xr63TcdEDojC7GdS9BHvmCeSKT4/ISXtkBWrnb
# DATA OToeydWgwsdVE9RbDQ5HATe8RfV8UVW+CN8tQg/ANardyk76lKJACmejg0W6uizSWw5t5qmADvTHo8F4VGoNj8bgtGOHYgRWDXYB
# DATA JIdY/lEbjnvma4AYGKhRZk2qF7X/5Ccgf7KRY/lKuVh5bVW/Q+XXHg0gZ98M2czsKtA+f+xKzLTR4IqkuwsGLRekgseEKwWa/G+x
# DATA PYGm5jbzUVuNswaKwkGpvKAXiGighPfswxbEKIAUFaROskglWUx0afW3Ku7Lvi7qzpQxxn3cqS0cmmlI3T9r7NgRjlEHB5P11B0l
# DATA y5PhQFNHfBRRkSPEpV3gEWmrS9AvfOyUoxqliESICVh+TraK50+vy8hI6nMy2Jir7MPWsE36Ie6xtG7eyYZXC4rOY5bnBu+33bQz
# DATA gG+qP8b/ol4Ci6M37nH/oT0cifrX9e3iXzgR9BdwPnqJQMVjcR5oZwDUDpzLeojZB1T1Y4ACyRkWVf9yIrmo0kL1nD15RcTCg6Cq
# DATA LIWA13ErTkAvbYPe7eIw9nwiLs7vVKv/dRUQyZevAKi8ru/lL3Z/TPBs/hnaqv6BkjxHByaagjlJuahDBZQadkJN+5RuWGsuVhZK
# DATA 2l5Khy01M98j0rBomhRudEULx9A6AD7dVN/SAFbS4hndWq1iJqMPX/wScbd+5is4ehlp+/C2WAt5iW6ssWInYL6Fx5nV5/k2LULd
# DATA qWFVEvYWwGlQ25COx9QKsIf9WAXTdQvk1/TsrLaNVqcauxNMJhCPX1q5VgEBdakcOAf6MSt2IxwcELSntvxwRPVWkkuX4CJuMzEL
# DATA TV/o/UcP3ijdb18s36/Z/6jamMPwgEOEV6oLMKbdHAr4vHakiGYA0hJYoHmuila5ihndSHfoLy+v0xqY4rJk5dpFsOpKOPdK7dKl
# DATA 2vJFo5y3ZJfYuUSvXUZqf2IdLW6SchJ6SCM4uDqCHZiTthu15MXky93XHwU78nqysbrDNPcHzLj8GDenlWtZRDIUuqaQZ6Szh0rY
# DATA eaiOlaogrBOP7h3yEOL7tng48mHC9QXaxs9kCJSx3laEPNUAgufadGxxj8Z6T1FW62/hnNOHpdlALFPDn908slc3wKY9ARRI1GqB
# DATA 40xuhX2zFhobiNp8Ykd1tPVOLwcvlpRQV9URbQdT6fBHV7NfgDdcZDxiW/MchqNbZDiaYS5aw9sfUIRr8ZltLNJf+namsOj6VIPQ
# DATA eTCQ+cdLVCPLhNUU0Nj/lw1KUySZQpOAY+KBu8qXCGAIvOoLLs4J5Dkg7iWgza4nTvVeJl1UmArwLEFFSipRmEk/pwNMcdQjNp5Y
# DATA GqYZDSl8MVdi+XjUh9mjM7Z/eJgWGJqRFYLE9wV6iqgjtCezoL5C52Lkhh+BHAIOxj+zUR8/hdjCmK+wF8gbg/diF1ont1sluTAd
# DATA /h4yLBv4fxwzHA4wwHp485rPJYBdG3yUvKg/ekRjEf/uJfpBSoJ4daImuGnjjEbc3bQaQbuOV5J3slNygAMPR/T9cQKTzST20pin
# DATA ethkCUwYGVXpWmAyajH8hIHkzN36l4rIPkEzg57J60kx1mB8RxG2kpMSW4lDOfnBfit9TG3Iyd6oxM2B0J6sqv1Tnw5IQQZmzy75
# DATA 4lc1tUnJTfgUlSGqiwEVxX1SiKUcKvZ2XIpB/WhTusY60I6vqfa/baSXlpaWyOz+6LShY5/RX5/cBrG0H2xWgJTgPUaXRNXCMraA
# DATA e0Gx/ibGIDV472FL5intBMp8Cn6DiOKW5ln3EAB6u6n9jqq/fPmSPO309vvjXptfXIM3diIzu07DL+267RiDeDgMEOITXmL2tTds
# DATA 1PVBx8iYtLwwKwrW7VfDjXTQimNrRYKO/Y54sW87B6DViHO8gcz+FDHtObnwN9Jd0zUdQriLTqAx9GwOWfKXNLKYIVQxwGxTE4Sz
# DATA fSmKLPNv7ET9q2R1c73irA/kr2eomcfJD4atUxNN8yWja6OZ4hcUS2PhxXQOfVqOJMLyMXMEnRRBkAGLXAllzdVbd9Y33Mio+U5d
# DATA g3AaOYANfFQAPh/kzC5CpCoOLev2j47oznBm+Q7C/YFAhkDmGAg6zJk64x9VwU0TCl1awgApeIRF1aMrKftAwr29L8nAMLkcvB73
# DATA uiC95aP+YJBhzlBuHpJz0F9BjGKhC6EgEDJmQ9sG25kE1Yy7nZMOOzT2+tzfszTvH0LPlpcuX7vy2lXVoWN1NTQPJpPJfBhK6vwX
# DATA ZwQaOnPpBvPqrPeA0NkQk8os6WIC3vYP0vJeVP8Cy5U3dg9NqEVdArXqyOnjn3HC1sYu41NUKWyCXF/B2dXAVhDuXV5fVKu8qEax
# DATA yA8Kam5ngDGQN/u9hg2r0N5nT9FeG8PHMfEa52k5Vrx4dHyaThzEBYLLmP3RJNoNeo15U1U/RorCAJ8ovXnnVnX77bXbt1FJNR52
# DATA k+phvo3e1/XFRfDL7cKhCVO3vEh1ICol6uzUnKAv6hJeyNnCg0SdE1jEaEgZYK/SwTIcNQfZsNNv017IbeiIkKcEuA0QhThQ79oU
# DATA 3Z9qBmLpiNutUQuCJOOkpUOk68vXaq+lL01kZHk9PkH/60Z6ZXnlZJ9qkyB4Ncc7fwvDvLdzE9bR0Jf00HhVW/goU5qbZwEHR81O
# DATA Dkqx06R6L/nud8+cSPNJUm07D2/dmASLeWnWWq4sTWz5TNFkwVzTjuGNU/9ebbl2qdrqDjo9YJHz7reiCWEtp/U96mpZqaq2C/xF
# DATA vwjkA1SWFJxKTxUPPslO1FpXB+ipT+8ytZVGWjkLzu/UL/jtdY3/Qf93v7iicmT0r732Gr0CrgR/LRUOqHh5DWhO9aCLEC7VfI7+
# DATA DOCQ+Hqra2FrWaxLlVJT6rAmZGZC2FGmhf86mqxQfPY84uz3JPYVgwMUf4kBPRLm6r8InDoinzZEFACHg+A1gOVcW6okStKeFGIV
# DATA sRDmSF9kdCKnss9Z7NGRzDHZCx/qCCoKVnbkpmck6qZRJJt818buCZxg9+J7OFyjkHpJ2micXbhA3+6K/IG0V+iOG80zGjm6pnBo
# DATA +3vh1iDRHRI6rvM+tu9iokKwwiA1LEe3bfxgf7kDevrup3Svat+H8BYsqx1mYBx6lY9tMx7o+6K46vP5/Wq5NjpWF4hh43XxQcge
# DATA ddR1vtZ//42l+nK5XDtAW1Op7JVQr4r4l8NlrsziMssrEYFgxRUI+ISQFIyAiuxljRGGYzFIw621UDbxHD0ekXMb3fPrBXuF3hbs
# DATA CnpbX6ktL9e+Z4409/R/6+6ttRv33oKBnYy7ow7Yq0YHg8YSSANMeem1pfo10AzAFb5O13j5c3HcHkwTB+LSa7BHbkJXCfsUFDV1
# DATA dA3C/i/qV/Uhnon4tAqTWl+E/5pn7Ou0SP/aWj6rcYGoPrMqQixrrxof31oHHp1RAITB80xsTGz5E9aaGgREdPrLcg4EAE68c+sl
# DATA jKw66bp29ywzKwJPWrs4kg7HKYRbcu67jO3w30jh1Hp52ZNl4IYj/2r1jrmR8xgrU4hDCQ9CFtEIv7SSBN+oS2fufNQ/WszHA1gd
# DATA xIiLdTnk3KDnXYR5EOkr1g1mewVfH/SHmQYfjH2OidedUntx0QY1SrCGMTry3E8iKig8Cyi+2HpfDm8vQrd7gjsXjAwhNIqXZNTN
# DATA Ya8WHfBWuHQR58K39eXayjXDt2LEuXA+LkPByOSQaNgMReOim0d7kd1VsBAynOmc7SWn5ry1zt4B56zw4cOHUmEsLBn66LFPi2XZ
# DATA C/iy/HHyTcAsG33ZbKDlAGk5JI9IUi4Q1TwsZvjlV+1jLSN0bgRomSaRRSVGuqnb29WvGHUNuqBGCijQWrFxhOEzH53SXDw6DbtL
# DATA AM71RBS7af9hL2tbPUVroCxWeU5dGdvFbOH03rCbhxi1UxHUznX7srNOnDktb1LqYLJTuG9o7IEMPW0TORXsQHz/vXGnzXQ4Vn/W
# DATA 4D+XS+WyF1AQzYYlnHXqZSeW684Zrw291HDV/aSaF5CkBimHHeV9mYqsk/LeK+Wo9MsxQEQbyVtDJ9qYsgC0UDKuwPw53vxBoM4B
# DATA AaZEmPNAr3/z3k7TgRWEH1trt9bpL8TSs9Hw4G8BuYOs6CZS78xFHFTlbq1vrd3ckV8BYmAlBvkHDw30qPrlIIW6QLcS3473oqZi
# DATA x3ClaHpgqC7CeS7JTOpTM8wHWdTmz0D+tRDOv2aW8W8yk3g8IDcaLKNT/BWgHEvyIz92dyrs8dzotsPsJ2OIAfDBOCseBOZEu4s4
# DATA KZQCNn5mE+BkoTjqUABtoyF8nVnbk+CXBVZXz6DZTzIuKkmtqnXTRQmdLzstjHbUSXKMG95vOHkfe/V9gU45H0ZjiJxk05RXB134
# DATA dYbogRJdnGWW3HatwxEcba1ut//QN2dzZ/vdNgiWD73VpRrKzl25hNWVbVhMmB1Vg5dHdDYvtIqrzynS7RWAc3g4cy6f/1/av0LN
# DATA E6OFzzGL1sThHVFxd8rpR/CZB+ocU6w+a5d2Sye0HcA5BcJ2+Od2fzw8sB/cysCpDvel9XTrvZQTsKAHM+cCuIPNqZ2ArkEy803q
# DATA BS5AU/eI/jBLwL+t2Ye9N+xDTtVSut/ptfnuhRbUfl7jeef+rN3ZWL15b3unuXX3Lu5FNIdp4Vn11phaUX6nymFIKWqtTQYueSXJ
# DATA 5K0sodgfZlhmZGxtprcYYybjtEO95BloIPsPshJ/QNV/J7kLPsyQ4Wx0PMwykwu5Oui2ej3IbowyNLd40jpN9jNA+snatWQN06YJ
# DATA LDlXiCUxEKq13+liJCrjFBPiKPoO0F1L7X3UZ4OohCAOoz7vuE4uKZRNSiRao6+b/SGaJ0mmWhpDUIpww05NCoP+d2rosBIo3Zqp
# DATA D/elLmmtplQA4Nnoxwq0Z55e2rN9ViMw6bGwaGlqd2VP6AcFDSVe7Kw1SXC5u7W+tj1nfTluU/EnoKqXvZvcMOu2OO0pFTc7oCbv
# DATA mqM+bSjJZGPnV4Lzy/+wkzfn+haPNscbTGMBc69gbcFxRB4gdHmODuYrFCrkBtbYSfLwZooborrbqh5iprxLKxBl49YGgW5cl/N4
# DATA GY/h+ArsykLthWsR7mL8penWoiJi9AEfiLF3TLL0MTmWoOdrcYitq3HeoO17h/XxINzfUMQK+RTh983WYLXd5r9uDfsY6bU57DxQ
# DATA N2Nwt9hzTjTv/DQJAdApK6zL20yKz9gHjchN9eQM8TZbg7K6zgyyIRIfTB348XUeqZpX1c2A07u0MBdXyRNlAfswYDQ6K4U6a1wg
# DATA ClgE6A0dONwv+MccNvjLOmoiKRxkxMwnpaKGrj75QIluRuc5mZ8T2E3gVBa3UT13G6p+Tro7a+4UhVqcvLhg1JErlE9MBXUty4H4
# DATA Ft9lBu+sQNNVR20Y3LBY6ZVGtLEAAm9pbaMFQ70r5rq1flvIZeqsJWhkZC6xjFVGF1U/p3MXxz3p907CP6sav55aq3dwHMGdDvP/
# DATA RaGHvSyALz5iXHByWUNbr+tryIaF0jkvlOX580TaWa+Kk43PHC/EfTqpsHS2N/LKC0CHnslDmIGv1O3EZq1aMvXGbQu1HA190G3R
# DATA BTBy07SyaYmC3f7UujmU2ka0Lgce85iVxi6BTAIClK2HQCyUixoD6fAvW+9iFa0NKdgZMknCFWsR120+ex513VRltcCtc4WHuhfF
# DATA Eo6l2+ArtyrqH5NcSSNxsrg4d5EgmFzPK31cnqFFELkazulHoxKd5K74qFfa9VpnyRpBmnBV8AEHNWPbFCfH/XDBR7Tkxu0z5fO1
# DATA y7li2gUwWJqi74isODoWv6vHZcOSvbcMMcpWpXLu7mXMN37lGQY0WLebWoc+cZ7JLXJaIoai+rYjU1GKzcUr3od0k0W/GJoBC+I5
# DATA RupOnRi6yU5ZdO0TbB+nDXXvpeCQOJhdoQqkIBLhjyz0RbiS5mZ0mjItLQRXHKHRegEcWkCsZp9EyLZcjItiKckiuxHTRqHgLHXt
# DATA xff41HkD56MXH6pj64nAaVv5RxFr058oOhJ0kk/IAfwrmE+SpdX/0fR5XSsbuN5GYtuGSmn8lgF12Nr/2nH2iF22FRWhKnBaxs4Z
# DATA Ji3oCD+HP8toGht0nJydhrVWtFgeZ7ChghAzUdPlfTfC5qYceEBMwosbNp9zFz96+BSUBkdIOYEca7b0cgbf1uyNMUZgMoK898GB
# DATA bKNCOeeymGjOiK3UE9E1CU+mdWGOCH5EREN1HrHF2oEUdmXl9kzFuiJZP1OHVfXEsb9AXUooVXs7B9S0drYNdLjTGq73DvtwwmHa
# DATA e/5t4eg00aCTqWtoNmqBz0sJwmkqCeSFUPdfG1anP2qBck11pDVS3eASqndNA1ostTT3T0c4Y0uwdFBlDXyNXVhKfpi8niwvrVy+
# DATA cGEF6QKbUY+uJhfkeYwFwBhZx8U9SaRxjLjL2jmqx/LWYZZgKIB1RPAXtcKeQ5oF6IjBswHAb8CWflQ4QTigcD6loC+wodeJ4gym
# DATA Yl3Sa/SoN+72e0ffTsNSeVHj+aA1zLPCtjmlDRbiBNrqdKHkRer+jspj1HGa5TrpHA1FJqNrFJq/D0bWTarJLYGPSdY6qeitAKvT
# DATA xOVsrGgCuVShzHT8YnlJ/Y/7+Oqrr96AiUkI4Jx0r93+UedAURkSC91+k4fDDobSd3qjPhIOBuZBqOAD6LTqRlZTlS040iZevOyj
# DATA VjbJAfLKRrK0oLNayB7sq11egr/6+z9uyPDIeWX4QYoj7ag92vA3MYaA8rR46ssMHXxBB+O/Jh4HfbnYSJa9JApDvL6QRhCrqOEd
# DATA nHReYQ5IqOV1e6Jhu4Zfq1tqa1/dY8ejjK6qaa2WYhY/qLbIgHGvhxu1F+5qBIrSuQexG2kUzY570cnpkiyCiX7MKdz1hKlHTNzl
# DATA Kb3SRNyLMRyoJ+wN10+5fwj10X70ukXFSZVopqgHFpsLuJreSAkGaLndcG59ctr+uN/pwXyWLpDyNDaN9sXN095GL0pTWTKlelMc
# DATA QJFaO3obc6eMFy8KN2pN4TQYzHs9LcQbSU2ykbmciHsZgXywJ+HkfegT7tCl/mtLSxAJCzJqzrGuiCPR7L9PKWPm0+oRn1B70hpU
# DATA 0fLVqLmv0w84bo/Ho04XkG3fb47z1lEmq1k7BPvR9x0KvZhcvVx0/FooBGp3HB52DiCnQwIVI5NVYtYJwRt6G9rm+9H7p5zKfBzg
# DATA fqVehaOhbxgh9hwEKRmy1Jcnav8b0DP533eStUcH3XGOhSEFEmygwTB7ADOdtMfkdSB7P6cwdpBE5QAhV5xYWiXocsVZWTwL0kf7
# DATA KTJ3Am6pTyXGg2NFACVcf2tPYCTvXyVL/eXlZTKlLPWvLkUAa8lwR6J9EemZJFK6dHy/7XchfYtlLWqpO2IHLDT8WSW5euXKpavF
# DATA WYWA32Ats1IqRVbyoZqx0XDcg9VoF2RKohmtwdJkJWwoXs5MS7WBRqaCslzfoaKP41LkdV47zE97ByUppyax1y+5nlJ4gmk3hcFp
# DATA TOqx9MdCNg7vVX+Ty6WF0DVILb0zOkXAJZQ3ClyfahiDwa6ZUUzMTaRHqBxM54Dr2LDfrm+u4fNsOPSfs/TTOcGYYzBJt8CshDCY
# DATA w9IyhBhJ8fc73a5VvKZBsjSkDz3Hm6EkWASMB1VEGwgdaI8A8HOKPOnCVlYcPYkF1rGG/8DWV1QGJDge+uoo7hK/jAGO4lAtMvEg
# DATA MzEFl/W63Wkd9fpqqx/kBEAlhVVTtLmWr166drlc49yZ6Xh0WL0GnvjQlVyJj5m6BTqqMK8Sv0XtmyvlINVjyUrsaIIHiFdC/MDN
# DATA /rhLktWhuviSqAzMAmU8ewxG3+i9cdDkcRrZQI5o31puoybnhDVJb7Z6eOlQh073FDeWdfZc184O1hZRTB2jLtsCRoJ9CW9LmtBB
# DATA 69TNFLfZpAe8U8T1EfxrrVGy7g0a7drEisR9ALo2mzYsFNdBH6gmfrYVUJb9KlhDYjV5rzXIj/v2pkAtqer/uNdwgXEJN5kKNQp4
# DATA lI3LMfJUGdHsnt9JVhPGARCyOGm9r+6LdGACAAH4mnRJdMNUfJ2MqOgnYyUuqboOss4A3Ge4voP+cYbKQhlbLdlScwehU8n7WTYg
# DATA UTmy8t3WqfqvYsP9MUJm00gIGA0VzAAObDNXA5omAxXd3d5ehfw7WQibF0dYNpfplIPhpjvDzEKjtLFfkaV+W28z7Jjfs8R2B2Vd
# DATA OUy1bZLbGvd6KAMFxrN/09CVGsUSk+MVqp+/cuyEzwhb1VLHIiw4614/KkK6oEHYqVk9oyjrYK3CqAzd07ZC+BnkaMWHLEYbt65X
# DATA bF0ua+9fzokEqvds37MzMNtWVm+OH09T8KdmJiJ3An0LsJzR7NQYRTvVlTPUFMMHu6KLVFSOU04PXbW4K5JP9VYyil+YfFbIFrjV
# DATA UH17UW+Cwln9M+L4fjzH9Bk9TjCJlpMvTFObs4pZTNPZZ4GM5iqpoYZCZO7vMGJnmpsrc689UNd0vFHBhWLcyY+RDyat/Ry4XTc7
# DATA amFqPsnGbioz5IwHGolWixDOD4ep+hNvaSyy5LVkI4OsjflD9OVBbtnFBOo1/7415dTXdnkcKEkallEt9rrQi/VfQmxyxyj/LLq4
# DATA lk2H03YCntOXaC9jWDJMrobQgR/OQDSNa/BkF6EyCnypRB95gWloeNTt75fSC2nZo1jQ5YGEBXivXcoLHThiM3xskFa6JG+024eL
# DATA NFueNpFTcaERNfHPOs00OEM8Cef1WWzTTFEpaq0GDFpnv7ZGyCo4uqEWaRhRfWubAixFb+GAfz/FzEcU8eTFr178UsyE0ZzbQGNI
# DATA FOgs7TJkbwJwQN5dPFgsmYWpt3PwLNI+BTEeO4V7o+nWYdNo8J/lz1SuoGRpOSoPSewu4V8SospJF2p4ojj2QQnPA1kl+o2zZ0im
# DATA g7sUbBxGybSQIkG50umPc+iX9VhxMlCrnAY7irI0g7+Cqdn2SaD3cR0xvZvT9Y7TQXOmAvrFXVaPyDDpKu0wWbRXlvJNR0oX4MGL
# DATA aHH18gQvFFDl9I3unYQImyp8D2FOCU+OEqwp9voFeY2C5fsTZqyCNqd2z6fwKOyqPRkYTYUBooiwtKjeLT4athCEJvK4KgkBJnQn
# DATA lFWj+aFMdEi4++Neuwu4XnO7Rtq9emU26S+CSoSmtHBG/8mblqcyKV8RvjSJs88ko+ATSqhhnVLgwoG+BDChrpz3/DFCzUI1v8Bn
# DATA sgySeYPOvz9jRU/AKc0kDWV42ycuwLXTwTiByQ5lUrL4sNo18FeTU6K75Ug8njpV/zJXKhFnbn6rUbnVoBGmF9JlE//lw8gmQp1p
# DATA o5+jgE1oxXZOJ7hWoj5OyWkokXQggZmlmAZX5WTQfwj3vn6eQ4ASiFYHrSGZJXrZQ6syuiRYTpfJJmSizo9R5Hl43FctyHVTTIet
# DATA 3mnCuheIOqhZGh2qpUM4ihayJ4i+AJiLhGsLFijVG2EiOFcsFwj7M47SsRrEfCsNdq/G6Kw6ajbxT/adB90FwPlnZDKo+xYIjDtF
# DATA LZeaftQNQnsV+HW3uXXr7sbtHyYf0C+R3PWDjbtv3r19++57LkmOYsxXq01Nk16GOl+JYn1JOi37S9J3oM63qW766vZc4kOHkVfr
# DATA wU3ya4UHscF80O2fnlBEINbJoXxT7rInreH7ePFPt6Ti5P/58HcoiEgCU+PTD3tNxDW1wSQJu8BwSHyoufFZ6aWKnWZ1minXpKwT
# DATA KdpZrKQpcoRxV4Pi/+jWaJ2RPoAvvBbnMpSE4IHPtIhaQ/87OodxcgmNtBBtKa+12oRPQRvEbCLLNE1pBc26LWIhg1Bdct4xqEks
# DATA zUPYauxLRt8EYH/0q8LFV5T1/J/R9QxWmyCFf0YuaGEoKBT+74oCAH/0F3K7sU4X+c5u38/ygSAAnCWCvejq6tGF3TTBrwOGZHdD
# DATA QBL29mK1quPATUP5DDJdf4646ybgcHpjxMb0hJb3nLQ++rkVzozzeRFsIYkd+gX3GZTcSR31JaqteMBVvY+eXvdAd/EggvWSW2I8
# DATA kXCNrShW6zAD+CHuYPZLBORa62SrJYL0i6ekKvUFZh/6kBQ+gqb2OGwXUNeeKgaeJ9VuK0D1YFf3P6uCn4CUoBrnT3AslcT4SyKU
# DATA NXQOAa0hOBSh1ziE6AmS05eUE1aywT6rhQ2mRItwiYKD/on5BnObc6WUe+SxoWjyV4Q9IfhW5XAs/yfCh4Pf/p/U7c2NP0AvWFVl
# DATA WCEB+4S1QSefEln6sQyKOMN6htmRuu7A/SE+aNqtUAX62h60o5tOPUxIfSwR58kAY6zQ1si8HrbWWK1o1aBnxDf+XiSWyyBjVSJQ
# DATA chpBrDpo5fnD/rBdGz1CYDEL66YisDQVQpKp8CxW+DIHfwAgjBv35TI38vkJr4h6d4hboxuqHTBJrMcKeiChi+UNNtqX3Yhq4OjS
# DATA MF1fCxUpXradDDRxnd5Rg01oZccNFRmzr1shyHjUM6jbgZ3tEjb4m+u317ZhhgNh1wzXOlwi1hE0uqOZ2h0yGWt5NtxjRTcK66TE
# DATA AfTuKeGko7/sfbmId3rt7NGMM+fFryrAdX6eGJd0zbYQTTvGyNN0z05UxTSM5EmIBQL+51iE1DWjbdxxzYYDd2pTC8Dye8oEjAaF
# DATA r60rjFgLzQu9+J7lEJvJKA4HFRf0iXdlwqkChu70hFbRVOGIdUXwMGqvq3l+jHCXjx3ZzRAFCjMF9ZbdRS7M14XHqZzlWDMJYw5U
# DATA u2nDSkYi5zkF4O/5ctjs3hXLROGEwnT8q0tFcKTNPRMMKuep4Y7Qs9sbnM0O7xR4HSEHOcpm9fj3dDwjzf9jBPi0zoLMUTYXTUyn
# DATA Cwth1ZuYoIF5icMnkKCJCK1QY57EZ3Y672AjrgVn52IAWqSO5hpfaiWX62790op7sszcw2FMFq1/dDvzAhNFjHsCkNBOZ1VqEUAw
# DATA jnMs9zz0Hl9WovRYnXNtdTPqwk1uDdECG11E2dWW4f5MGiz/rPiIsy98iNopHFqCHz2VvC/Pn4Uyo7Ty/bDG1xfJqMUYm9ULiyxG
# DATA A51igI8rW0ZzzTx/VgFtlNbd0VfPnn9Gmn26NT2NauXCzoIgxPPx73PIo4QPy9Qvl/hpgiclVUREDz3tj6kRmMpPuOSfdByqkyci
# DATA FHN/b104nvIN5onq26eYDAMGjh36jK8QeBMxs8QXQrHhK7FftJtR7Z0SEwR84MXPayb1KvIBUBtqOcXKv8QyjPCKuPSChGmkF1Ll
# DATA IDYl71p02B6is+gR/l1b5SzFm/hGa4LUjm00m0oGbzbL1pdwRW9KYuNS2h9kQwkzOjjug16kwUCGAEaMsjAoC/sMzj4atno5JO5D
# DATA LD2QcaosbuM39t+EtAf5dSGQQJJotoYoVqPLSJUD1qs2xBSBASOCEvx9RHDAxNxSTFeRH1dpK3E2zs7hqfXAYVmApxc8ZDDy4Dl3
# DATA nro2HhxJFjfA4OyMqlYKUEjwAVp165GAGVetVINgrLK8JrBBVp16j8UVy/axGLIrj66JphsaqnIH7MkqeM2dj7+UcdBbZzJGAOWn
# DATA 19KA4ph1lyx6pGIUZ4golVWrEq97vaiABFQWFhAXpKnNmDujTc6eLF7chjmIpraicdqKO3uCQIWF72nhi98zYVGWmal9ATD2fEpN
# DATA Q3ZwgiDI4VHeAKX61LEpSpvWMQpPNatRWNLa01UnWrugvNk3bC1rpDN6ilSoPqsi/or6sIVWtUaKRN2kjItTm0S81v7XrwPAI6sn
# DATA hCpjyK4oL9eeNURTZs5WOBOFrgBThF2f+h2DVgafUnqxac0Sp3SXpLAtv3rM1jOdKURY9ZyL73xKu22+XroSbdDl5aWZWx8PNbPK
# DATA knAulXSqzvrS29lre66ZhsQqxW8lP3XZ9pTnsvgPlLZy68KvmpYDDNwiMfgCpwf8iJA6vVhijfLhZQm1PpPQYLZK4UOADYRYOUz+
# DATA WfZUQtZn2ojlg+tiU+vQZUDVDZPHClCSH+4cS+XJeCTMkgxiS7Rblj9H2cuwSEnhOdG2LcDS3aWUIqCMzk2dWgiY9nAIvRgN5aKT
# DATA fgo+WwKEG19ES4gziwjO0eTMjG9K/mJOr5KP+ro7D2Jk9OuqJMGaz9FjS9Soh6QV1OgjwsdBZvyu+ettmbIgky+oyADPYT4kLsT7
# DATA MqBTihWs3r7tInQ5ZkTJgoUXUsLfsF8PDOAYOsE7mZ5l4mC7wJRRf02SRe5/NC+GE9PvdELDLptRREHqKYNXGyC4MIUXjG7aKNuE
# DATA oca4CPPNJjg4xDKDzckN3EV05o735CnkYYfICy5Fu6vXT6cTp33vMNNLD5rwMqN4iJpBqphan385OBexM4hGEfwWS2dNJW3Q9/yg
# DATA zMzW6+KcU2sVEe9P6MD0YcYuPNaZEgnKOCfTmHp1sq7fXMyO5JBi7rDPs4juXdFKjpirxkZNftHkIzmPHYIh18Qf/Ik5HWenkjE1
# DATA yXJrdsEPiNZL5XkGFbubWzRaCOk9dYiGDs938HhXcHuvwIsmv3BO5CmLWjTH0zvh3/ptmw5dF5xunIcPRK7nPo8Rz4+iDWyzBBK7
# DATA EM2Dq5uP8vAJN6c9WhkdkbTWFc9aZPiM+czE3LifMimGachMR/A2W44wML53NmMEZANKOywjcFqfNrRKMmsEnhsuuSJ3eoPxyEGv
# DATA Qb+fujF5wuWPXGDrjrchvozLlBSXZpjrFO6LkRhWVqciMpumJnJyHmOpuShori07tTnevfORq3/lmLVNC5Va4b6lDjh5L7Co1Q1c
# DATA jIq1BblfM6zqgCA4Y6JcDaa1Fvi8Sc/PxVK0wrY+jXqkVGmWtGBlmomyUUkpAMQ9Y6yBlnR6D7l0k0tP62nIQ/AHfzmjW0ar7Uth
# DATA FcizgGhIUiRGmuedQU4r5vdZH9f4Uw5rofwg48tU3hC9JUdu79fjiVjgAqQGfj3u/gayv7bhWc3aiNZ7812WC49FbVuYSiK0c1Wx
# DATA 0rSdqeVeyiVEPwjcPZxbUETNoJdQcVX3bxnaohPm94k36XSxfJ4OiD1jzj5ILtZvuhsz18ppa+aSaeY5h85gZtMo9EOTxY7OFIWp
# DATA U5NoecVK9TO1D5xYyqzBLIGtc4IZaPNTgweg/q6RD1cP7g+lJSuDQxP5a7Np7TGO6C0HdeqMRi4m6CLlS5viYGAF1cwDjQzB0J+j
# DATA IyWmsw1j5XRHJHk9/igNKpJxzyE2/ZnpKoWmusg+1633OgTtyhWfHaoyjq8f/mgSXyyF7MDNAqVZsZs+iqjeqPINbP8MEiEbaHi6
# DATA CFvG96W5jludPs4+SqayN8p1Zo3HKVjEAiLJgyMv7Gbc/O8VgkXVjfb69rvI5EYXwn7oZN/y9b9f54Ryq1gDoLVNCEGmBG0zqpnj
# DATA FL7+cmeg2MsdgTlI6xMIH3OLJaJE1PavKuZHSQM19vPfG59pdJTkLNbgGPlseh6GAFRc84dZN5W0Hmg9OXVnjHkEZe1cn84H0SSf
# DATA 8hWQVp2yjRvuH5aiLagzKjbBe7dkvyrHNLb1pDNQMwzWgFpnoKVareEBUuscjGzkgqJJQjTUBT/4JFBzS9V7BWDH+GEF076EuV6K
# DATA wlB84ULtjwek7X4At2wKTZmGZE01WCEsxVc59Po4hw3Ky3sotrC6p/BJyWRYt3joJFwytp3b6Dz1WA5DLrcaSNBWJbOl4YUF1W4T
# DATA SanZxOE3m0CkzSZPgBM7Rj5BCxZkUwgKBNhNiOlTnyZ0yB7/1xe/VJv3E4q/KHAwmxmNgM0p/oKJkUGcIcADC3IJAYy2T/NRdrJG
# DATA ScntQZTeBarA3leSd7JT/gugyvnPu9v8B6LF/M323Y1bCAeFT8t2XOQ6qmYw9VOnd9AdtwWND/M55fWkh+gPOP5kmP2YwG8oHgxD
# DATA Q8fdbgIN1L7l6aslz//NRI2++JigYxjKQwevVFw0mV9R1K3FlymOxU169uJXgHp2rtX4L//5vyn/U5t1vwsHsNqNtcHpt9IG4D9c
# DATA vXwZ/1X/8/9dunrpkv4bny8vLy1f/i/J0l9iAsYQKqKa/190/V999VXYj4rJkpFaglgxaFRy0JHurgPwmMOsm7VyAPSiWOnl2krt
# DATA eyu1hYWdY/BGtwtiOslkdKyOGwRO5FAnhLvtHEHqjeOsO8CIqmPgQgDJqd72x0fHC1hI30uSnZubVcILPsxagMeFBmKI9jZ9BOUr
# DATA PD1uPchU7zKIkQB7bLum+pYNMZC8rU7mfTiRAVOu19dG9gP7rEFw4kfZwZgwLgAjDgRTwutcAMzoWSdbwIbSnVnjOVZnm93p9C/E
# DATA uJxIs4Mf5/8B+/+1q1eW/f2/snTpP/f/X+J/6TjPWE5Pry8sqI2Qj5KzZHPYyU9aN7sdvLfTr2SCoTm4rUvpXw/w4eIBlknL1/nb
# DATA Hz8c2cVAqnmY7ZOloqxb2L55dxOTgN3FhJOIWfx3WWmXEnjluHPqgnzvezbndYA3VDIuhxdI3q8guoPf53X2ui4uADcGVc0e9PBw
# DATA 3CMQmmE2zuF0LA37D8ucrkzSY/cfJn/1V/BPjbO5OVH/dkMYv5Gq0kYdBJ9ljwZqglZH+GkPRLMPPkicF69jxtpbIPmXy8H3+YG6
# DATA W+Q1xVePIIxeVUJzKk8++MAR7ef65mKyLKPioixo5m4MVp1yxTid4ppABD0t4ddJ4/VoVfi7rGZ6srDQApyIRM+4um0+6MCVpkTU
# DATA VcGkK5KyVNYAlH+vLP5od6n6vVb1cO/s2qSq/748qV7WPy6pF9e+19rfc57I38srk+8u1kZZPsLE7jD/kJnEmjjICNI/lISpr5Cy
# DATA DFKUpFCYHsvcfT+5tFIGpFxFGbBuDGO63sP7v5xTdMCo79pq03RakD3tuuBGKrrhXNxTKckuLz6acDkDV7iEpq3WGnQwd31eA3S3
# DATA e73OT8bq+pg8hHOwrrY3jneSTLjxxcVkK8vHqm1MCJi08MCu4tVO0OUq4nICzSGNnkpGMsixAMPpAyrnMHvQP+Bz9DAZdo6OR3lN
# DATA L5vusCKzV/T+kqdlWWGcfH8q2b0tQV6SHBy3ekdZ+7oYPVEa0LmNHOgA8jqnoVIyna5aTqi9YWZQLWjBFCJqOEwf8KK61UOiTViz
# DATA SiK7tm42Lfyn1us/LEH8y/JSciG5dPWK+u+1q5fxnAOPUdwa9WS3VqvRBuLQM2dtdkCE6nfbydGwpYZD17yD/lCNfNCHHCGQrxfw
# DATA BMdKbFLrgAjaGnewptYWRAqprU+JhltAPa0DDT+IGMvOIoMM1kE6HdFS4xhZDIotqPw9F/Ow5pFWomD2RfdBtHsGcz6p4Eqc8exZ
# DATA kzeZOMvMzFodSTWQOEtnvGTqzBvCstWR8QJ6TxfC71Y3161IrE5LLeYdsF4cdvv9ITJQIoX2KqY1AixsTCa9jIupP1TdKeDwbyRn
# DATA gN3YAm14HcDOs0miCEoVDFqSj8OGJuVkUrHcRIEJVdSebnWP+mrDHp+okby9Df4ZSENTmOyb/eE6saUou62Y3O825w0eyoY66LY6
# DATA J/l1G8ZbdYueAhquWgXyATBVmKbOdPdhO/AA9tQA1FY4ACg1VdXihWQ1aXcODwklGPXziAarWM77iuINW4WkRrliY7AXhYRryYXF
# DATA ZOJYkLhvinTpLzRU01kOtAAv+Ajg98g3G/Y5YJ2AuL++yVPJatTZL4b/T905NusXzg911e3R6B1jz4sj+JR1SqrgcLbq0We0qW0S
# DATA 7sQZ5ztSK3UAxccapSLFzGPtsVoaxaQF1ro1PHpAeZwbgIIv80PzQrUDpKDaN0oMOXOJMjKTfZIsAZN+DGkUSiTzvlGjqt4lTesb
# DATA NRJ336jlgy7c62opIDknb7wBibFebySvwR4PVMxKih2MIBcy0GNJy8aIQdUaDBZRhU9DzBdFsOaPqoOjtFyj3mwelUtnUb9JNYge
# DATA gfBtI2HW9Typg7B2a3Vn9cbq9lrz3tbtirrhP6onK5UZ9ewQsPWdTlfJxnXFeppLAEfcaXcz79UlehXUNwGulB8cZyctGrlqvVTU
# DATA rXItzwAxd7M1bCmSorB//FYtrZreFONND4CnuS0BB4VEWYralTQQgePApu37TInX2iZV4TEuuJkvgdxiBx4l8HSAzXT+jgQdEJFA
# DATA FCH2ltjjSsMNUS7xs2mM2J4nY9Tfvndj++bW+ubO+t2N5s7dd9Y2mvfurd9yi69ubrLhvxIkDphS3dbaPdVlrNQoVGsgUZRI4lL7
# DATA yMt4QLp/esshvtanOKWyAXGbKe5ay2gqi6CBn38GjxBnEGzyGqvhFxY6CxroPseMxwb9IEByiGuhf/v8d2jji2MY+rg7NYxLkrl7
# DATA 1BndRKN5sqyOJWukjGfHY2VG/F10SMPtVKLbDu1wONr7lKrrzJBAJUYNFbknT64v/AX0P02z+79RVfB0/c/ylauXff3vpZXX/lP/
# DATA 85fS/26iHGXWXrxmMVsKqFnVvsUbRaA+cW5ZWVvdwDClHluVgFNevSy/QBEkf/fzBcQzB9+gbmdfzFDglSBFhpn8BeZE/bdOayFP
# DATA RtnJAO53VOF4qI6kfQoLlFrBBQQO6wVdNXn5MxgBuWihdyx6MJMG97A9D0imYGKa3xs3bt+9+U7ZZAkELMw2pQhsQ4Q6p4aiPIGW
# DATA HZNQxRE5EzDF6b2XcMhCzoNCte3m+vbW2lslG5faAaqWbJyQZiaWd8UYJ0vp+sa7q7fXb/GpAmgOLlKTB9hKAF3SEIjFDAx/toRT
# DATA pQ7wTD0tlSdR5Oyl114rz+qR6UnzDpxWN9aam1vr767urDnw7ng08YSatDpX/LQ62gFvwXEMp5XH/zpZnfAJk0i0sJMuxXJBwLfo
# DATA +oBL0dUfhAsxYxEkLwSRay1wN+ROCxmT/w4B0crdX/vMFHbXlJQeU9gd5yzgEchvGMTK0uVrGNp6/z6mCLLLQpBhf9guHZRBH3YJ
# DATA HvFPJaUvr7xG0XX2V+V5poOiX1GawtLsaWInkMIAOO4I3Agw7jZ0tJDJJIQhH+YIb5Q+Spmd0YVns3R24QI7O0hUJkZIhJG3k2Dn
# DATA muokv/j5U7rEZ0txntXbMlcbq++urt9eveFsYwkApqBSu9UNerOdjUCBY2eJl1c6ativTYPdI3uwQQ11czB0eMYsopQe93NUyO8P
# DATA O20MdU974H5YdpDssQ1SiPq9pZTzqdrUXdrVkEzan2npXywTTLq7Wv3bVvXvAJnd/NmsVfcU/1KEOklJsXeuSefI7ILJN+SZpBCs
# DATA XF9E9HKNo6iBK5lE0WlLftgOcnoyeIFA3t+8u4VuvgRSoJ03bU8lq339J2QCwX7Y+5gCSDGemvsor7AudZ6qKuRUNaxBtqF6U8Ob
# DATA m73eqjIEu8Hwbc1moCiQAs6Bega/RTcnvwXvUn7/ZJxRdh/4cThsHaHwoQurI1e3ijjP1Bq+hMNf8Yall2E57sBeachYdKQyU9u0
# DATA ut/e2dnc5pq31v63e+tba7dS59TROtuhIeuKVK04/ebW3RtrwMaUmEV6C0mDrC4Tq+PRcX/Id9J6kt5QF2rFZhDgzL/+vbf67lpz
# DATA dXOdThp1vUCH6mgpPRMMqvkegGpqCibFFPdiN/1BVd1eHraG7awNf6HbWKr2U21J/b/l9Hq85Oawr7j1XqJnFW5LntYSSB0FNGiP
# DATA xt7axxXFG/oq/H2TALi6EI1d0dkLc9KgQkg/XdDwuxr+F8pdA62qupGLaohVa6hczzOtXzvMgHHMmCMGQVbskwcKkOzk8VxP8eqr
# DATA iBJ00a1unbpBP0gLh4YtabjWf1/sSUw/FEPSOoAOkF4B1K4g5DWWAMJj3Hs/b+zuwQtgw9TtEg0H36JFRqrf77dP1WTC5xcb+JpN
# DATA Wdc7hyV4+vrlC5ilBf5TPnMm7XqkX1Kx6tmE+lIbQFrNG2NQ2NZAPi/hc3UZnuhpRve0BnqlUe5mLq7eHig5mCoq10Z90muhNKeE
# DATA OTNd5Cv6wQeiqcXfrzQaaR8ty2ipo0I1vaReaf3C+iw69dYQF/SedatQLyaCb5+cHXTVHhTiQ3qEsU8WSkjcpXLjdU3MYuxu0LIh
# DATA Z19sDTqLZAxf1Mbw8nU18BL3X56KKyiMgFXT5cgANJbKdWmWDeBhq0WmcutbVX3eWB0OW6e1To7/csR+Xn5DDOv8b43/Vd+qzr/i
# DATA fgT1lGPdtZtUn0G53aW9N0gjPnePF9OLGMqY3dtavynBCFIZa9cVwymXylplpdbF11dZuiTyibTgTzTi9mMA2NPaKSj1Jbk+EoT6
# DATA p/Q0qpnCw6GSqDII2gdZQyhXEenCTAOILW6jmGJKJE/3pabMV1s1lq8Dl0H/JbwyqAL7WYkjIcw9gC8wfOgovkKhyhVxsGKRqPgG
# DATA FV4yuA37hoGPph2Wm6tvrTXX78B/Q3kKr9Zy9a/tZHCxbw1Pb0loSYlAOCCFqmT7Q4rAIVfpCn7Y7yoG7aD+S4gTvSpz6LSoxCAq
# DATA y3SYBTNSgSIoexo5Dxq2+EQ60sj5i6UcNWpMZC/xSjjJkV5GcA+SdqAtLFJ58V2Erv++lM1/WqI/FeS6TX7LWEIgJC6TpXMPIaiy
# DATA A0xyDBFxVQZHR7fs3oOypsxdqHJP4PCgOPwXRSUPRyXw3Cfoh36OKgRnJOpCoxZ2WNIDMbeV8nydZwT2apXAJavVgbp94FUnY/BJ
# DATA GySOelEMilE0B/hcLSgSWGomgbdcdC7EN127nttO6lbm2G39p++MXrRlgepXb95c295uvql2LIi3lLkQ7+nEdkBPaJBdMH9IEfPh
# DATA FhXL2qKzVn2v+HHWBh37A7jRy5yQ9vF6kh+3huT9kVASFcWBTq3MsMD9LMd3SiMFN4gFkz8yDrnEedlciCV2rlfCd2zzp3VrZGlk
# DATA 36sCOODJguRDgbpMp4DlYC6svCQRWNQNG2EYv+VxE8yT4ENEK+qPjgEyvqAeNysU3+UrCX5kEs/YE1ODmgCxXy75r+hUozJXDmgF
# DATA 9oIB5Aji4yzFpVKTcTaZyAlCA6p7qT13Uxu+BS4MZxcuCCuWuH37rszZHCXdjf4UNA0XLtDyTSKXZWvqDPqbXTFBWpyl6DClui4E
# DATA ncLY1W/4Z1JJArKpMM2Yo9K/N6pndq/5fZPSqs3eguq8FD3EHQgBvrexfW8T1AP6rhlqgiCXkA2mpYHiKg5KHMbXxZQ9FQNWLZ/a
# DATA ZBEGaFHCIDgaSHqmkYJWBzWFsv0R0tUc4IB66mh5oEO2nkkfSlaL8nIXwsakZXNY0XOnA680PP4z53TfvLvx5u31mzuRabZnFyPj
# DATA ztTZNgJFR1fRCmWSpubr8o01763RqAXcC2AbQspAJPBUUvK5OXyteZBKeArckcnLsJ+TaYFvVsfAgbYENeNFT32bl3YvmDZhksvl
# DATA YDfrIWB4GZd2HEYQEob4w56TCQwZfgnfVMQHkCMN6wsu99LESUmdmDIt3qLWApI8or2qtn/1MlsO8LvdlCIdIN2XZ1EgjHvyPkSl
# DATA GX9APGGvQFakPkGbFfkA9/ZeUB1nFf2L+f9zFOk3HgY03f67snL5tcue/Xfl8n/6///F7L/bp70DdffugbEQglPI08b1PO4PO0cd
# DATA TPjasjOvkAuegYdH+QoFPsx382hkWXf5CWfuFGPs4UFv1JUfADuovpCfOrr4G7Uhw4X/ZazF76z9EBSU2/duNDfv3VCMvnnr7p3V
# DATA 9Y10YXV7e/2tjTtrGzsY+YCCCKRPGaY/Kr1RJ3eP3eT+aO9i+Y3gc3xxoVG78F1IPJ/V7oBF76DbyvPkFm5HOmrMqaOB89W8EEPs
# DATA 9Ycn4IzEHKvQ1seHr30NJ9bIVj76Onk9ubK8Qn6V7JQFaWzv5/fv/9c3vnP/0dJS9f6j5cP7j1473EuZhQVWPLvrKQ20yap1Ph49
# DATA MwLzaMseQU9CY4QVZ12olJ/TlsDgImQugCtKJbl8+VLUPHH+AcKXNEJdSY30UKW00+61Un2elGtdSGfKpmnndu4E2POfJajOiTI2
# DATA xGHhtQB9hMf2vL0HlQDQBLYFVt8raM1NazpBPI5PPYJ/1cDalG0LXCIhcx5mDDZ/ocHPy5YFKuput+TlS1Y7ZumReMNe/AD+Uvsm
# DATA BWik4ajMV4mh7oHliBnUjngdYQu7bPdTLfGfaPW7ujyRN+U35mrvJaiec16KrWq3Xl3eEzKmBGgykWi5QuqXd7IuXXFVgWW5vETL
# DATA UkvlcgW/6Qpocmk541/kga9W/1YNttb8++reRfVo0X9WvkDTDmnOzj9SFuCQSsgoYjnciEvNgIJGHLnNTguKjdvcLJL2k++WBsEE
# DATA GAE8mafP6na0+iZc2XfeTiPb75twA+I9CkAuG/3Rm4D44m1V8K7hmajHHFi1k4Mey7fqX1Q6v4PR0srl5AL9Y73tASQTrMZymOjX
# DATA lDq/79DKSvRiNt/6YkbC1qjl+wxZQ7iYLJftzQbFy+4wX462eD2hPrUZ/tqTiGBzdEF/SJ4p7nYQX5WaDngGxvp+OsNb7b0tIcqb
# DATA W2urO7MotiJ3jiL6al0soK+IW1ohsWlS+nqrGKixUZaEGJqD97nNCj+DsTXXfqCGa/3euBGoRG/At53e0fpdb4sW9O/e5q3VnbXm
# DATA jXvbP3Q0nfLJaSfrtpnv8WrbayteSQj9AS5JeQmJcapjkiZNwoYxicEwTwwBjpOuBKHYTaGCnGnF075xd6d5Z3Vj9S2tOtL6wilJ
# DATA sW12bdKuBzzbvHIYt2nBKROHeDsPxYD8hTm1Y/CQtBqIM2WVcSG4Fmz2aCuYoGLGHBKpYzn5fgNZB74sw6/lq0XiiVcXC+hweEcE
# DATA Fzqg0VFpubK8ck07KrmeV9hsrEGrMR5vUdf5NXb+2kvSiyQyPzPLKvnw6iQIhC8ssQDh8SYLBmAO65qYjOjYRcpciJ21xV9km3b1
# DATA VMY/BLQ4MoWxaAR7a6PioRCYVGxLyr1eJwbkM30Ob969s3l321PbRjhLeLuL5oQvR9V952zeiEOwnLswWaCvw2PMnSLzkn4v+KYE
# DATA TZzRjA5RywuOCEnct1niiUPlYgZFLw2kk9kd3YKs7A7ygmylu3uxphyvWa4nijXmt7Srf7j1wqQQCgi63wW50O26IvRcwm93CaB7
# DATA z1P34jtRd+M1Ap+EVh5aU2liT3aEPHAEIcrhriShSysvxw9EADIQkMw9eTKZisRSqPqAt33abFqtgTu3k3sAZr6wjFwT5x9100ZJ
# DATA g4GRaNxFzxlPqVt2DjCupLgVgarjgrvqPgdeJXxLbChutlzeXd5znM8Fi263Dpc/8FR8VZV7NX3VoqOfjPsoGlDBJTujS1se40BK
# DATA WLIiIitp1ztd/SmUVwJtXXeBXaUhWnGJ1SupzVbg3fcTvFaWsCa5RsIPO7F2+p20PDdjcS+H9sxRN5frqt29iMJCioEyCidVnYOo
# DATA S/uOKJ8wohHfNZbLOPnWXNtOWkxWkqSjNIsMjacL9sCQI+2Z8Ojac9c3pFExhFaYhgtNElZOdLkciUdVsIPD/tGFRXLIOq3zUWbq
# DATA q5E9MkDOnc6w6U4Jucktp/qYAXYKP7f8SlzTbNjSYQLaV1RAQ5v1qJuEzAOV2VVf7BlPJTt5jnO+y1e+EnXhnMc6k6I0RtpE1Guw
# DATA 5HyUoT6Qddw1zppQXojTBadidsjDao2qE3AEnZtBFIyAOLGfgq4W83J5bSJ51KgK4gfCUQUWkvjCfnrSyXP093E201mKg1UiHA9a
# DATA XVQodFE94p4dZ4+kAUnqSeU77YnsQ2N34LAVwvRoYAgAI2nBTYjvGnhxMrcFc0cNL83OXaVgd3NYgb6SmfwkhGzWOAejsPknDSLc
# DATA +9YEUguBzsUW5rASy1ydZyN+iNckWQJ0khog5MmWrMEkpm2hb3fD0ntQHXVo16zj3vwS49urG2+txRi72VHSOPWZsmd5z0Lqc8Td
# DATA k34bcOXaRv5/aXY6jZV6Kf9YnF0ocoyZwhxfUqq1OitfRwlppqR7Libti8LTeHGMH8vdsUCkLu568UlZPJbaoD8oqeb9UKFAao56
# DATA +4X14UEhckhheZ0xzndAokqC79inAC+M7fHJINcub1kvB2eiVn7Q6ZDiu4L523ujxopkyp7DbZEbQGYO87+fpoGDQuwgxT3winuT
# DATA IOlFC3qWqMz2P2isYBkLqY87aFc23segHKwtWHva9V5xIDM1JQ1t+OOvF6ZRkuYjLzUg7jf8o8NwwCWXl0b9E3QqtmrgxgVV6BP5
# DATA Fboxh40Kb9N3Z+c7/8Yvpec5WHSmLVEo0oN8kfWD6g4ZS71RhYGBmRyd4y+XynCaOx2helzNHT37eipdrpeyJICKuLHUfw1gRygz
# DATA RE4aoQLHGpPv6qTV6xyCFMKZsIyH4a7TvWhyK0lchA9N/npOnYWpFm09SPTc8vx4TcIsTxKzKirbItNcjUwCgR17W9HHXNYbnyDY
# DATA aUmIxkzdnpepa4Qu0JbiI9SumwZK5tAtxxuKiKwW+cRMgLiyQEfWuOMb9DyyiNVowXwWtBGnrFKcJhggnGsPNAoL02s3kzn7S14q
# DATA yc7m6i3FiNHKszX8E+IAgzUU6hiCG3qu5Gau87xLRahMFueqF8kK3sxPP+jRljvukap/4fwHe2xu514cY1y1mKq+Blxw7gv//0AW
# DATA d/z/TjpHjO/3jboATvf/u7R86bUrPv7L8sqV//T/+0v87zuvLI7z4eJ+p7cIQROD09Fxv3cJosTuDkZVxSY45yuEjrZ6Bi4zwCV1
# DATA oCMBi9PzCmR3utbwCP3tFrRX4OCUvPFAkwE7Vzzx5DcF8v4d3Aa/thtgAB8DmQ8ESQa8/Gb7BdpehAsvneAqCkXTzmhK1YlmYvyJ
# DATA 03Vb/297797cyHXdi+ZvforWyDoNzADgYx6SISMyh4RGjGdIhuRIVkAEBQJNEhYIIGhgZugRb1lScuOUXXad1P3j1qlKUrn31Pl7
# DATA LEvWSLLkr0B+o7PXYz97d6PB4ShOjiaxCDR27+faa6+9Hr91INheEglhjQGQtSrtPpa0Yr5Mqy1VpKzGFQpYkrdCme6lAl7ZYiFb
# DATA 4lUCWpCAZfBr7mqMV/VdeMarMlRCv5qwJZs6aI7vN4ZYg6B/C4zkuD1GPJIVhUeCT0xIEvEAzkSd1kxeaeWQ7Rtuuj1AoTeYmXSs
# DATA JDo8HNe2OxuPgtsupjcuDU45F5lupGR1YjgNtluU7KlXNmE2AIlvNJnShE3PM2ZF2n06hjKtZqjVuEs1lQyMB1vjvyVfzJ0yztdY
# DATA HYfBVA/FzqzBLjRvMEWJkyPDadr9nhCTYr3R3KCzmCMqMfDy0mAp9FjF0spwihfazlILi4mKUFct/UcpaZGMdtB3nesFORpGDKHB
# DATA S2MnxEI5JdY3dwFkxSiSxMPJwmIpzR7ZO+wUy9kJNZTsHPyB3mqq279ULVPqNnJat5yirVvNVbggp4KePHVAT86+W9CTHI6E9Kyg
# DATA u16ynZWZqEraVRpMgrdu3XQGXNN+1zhVbywV060nKvNRCreg9aO8eJMhZTIu4H8NkgKF2SMxA8Co7d1a4jDubNyckvd3bIV6zuEO
# DATA NZuQ7C3iC/hEolSsUwZNpFiqtXGIIy5qwVOrPdE5jE6jfc3BbjLMloMPRItv72xt7rXqm+vyGZt4H2E/IQ38mdujATeZ6JOykYFI
# DATA 1zKiBNH+cHk2uOAEHcYRz/clOCqgzQvJDIPyC1Y/qZlXg3VkGRITLWbfr3ZnPIzjADMUqGBvFcI2GSLgeQd9KzHXI1f2M4Dhh5/k
# DATA KxxrSxgE4jkFwRxEIPiSL2eX8NHbJwe9o+lwGnNcLkfRxuzJDG9JDaU5GRAgjz9geeNZjemRAt79l2OG5C8YsfgFo5651yztH/YP
# DATA qalBTgzuwcpxxvJQJZuJ7pRn3XxWFhV4rDe8pGU1uxkb69CPSmC7XqtRMA91R8Lcxx8TmlB/610mlkshX6lGgHUBaNajdOwuL+tW
# DATA G9MaI3uWSjj1OMEpY4NV1sgmTXj/LUgDYPndi90y7U+0EjCOCFhRdFMbqTV6HZnRuBUzIR/gguYQbDYwY6Eldf4YwbRVVcPHAzT4
# DATA YZWVMReqkkvNUpPyRh53xpXecLE/nIAf9aIOF07AwVhOLsYkEClDWzNWdhwJAaTH9yi7U4vUqfKy8vyp2mNBTZp6XYkIyU5aIc/J
# DATA n89mUx9Unv/8RLcx/cXVM+slnkn3k+gEHNR8d1gngryQAB+QeATy3qgeqMB5CiSHNpLGYfkLLCS0wNMLBOy6GYLqtNvFQ9HZZUD8
# DATA Uq0KtVkeD+yNQaUwmrnWF/yn28aGq3JEGd0vKi9wggqBYGMhdkPeTJRGagbuhvjq7knxqNC4brzUJENYjWLHO+0RZBFrDaeT0VQ+
# DATA nBDuVG35jSXFNHmcNCxQhOoJMlKVcow/ib/WnQKaNmxtQMMyB1MQjvAWyRiZ8HGK8i8DocSTIX1FOBQJhoIQL2dgd2HoFMPblBLP
# DATA oO8X9pqyPWK8kwHEE7VjAu4v2AmPQsjvNu0cB8aNARJMXvzi/FPASQrOv734+OIjzEoJSSw/vfgEckwG55/KDJWhAzUPLvQfDASr
# DATA CA77bRwxIzh9hJmBWerglyX0EwIzfYbN/uH8OcA3UStOYstkW5ApBNxvhgB7MuhFXWzQgIcKzr8Q7/8J02X+E4CYJ+tYaw8YYhRA
# DATA jKSMwx3ttqMTNI+F/ADhrEz8qc99dTKPaLOrk6Hqwfe/wlTKv8BEnh8D2pWYGX/+UPGDZ6KLzsoqakS7LBAjZSgk+idDBlGAIEv6
# DATA SV2HewNJRPIREBrDcZngW3ICnqd19TeBSTrnz0I356i8UCSz1hYOw/P/QRmlxXR8dv5MtlZ4qrbcWZHJ5QtE+IKO/RIzTz8DYPwS
# DATA 9eqz4Gli+55V4SGM/6wSmGmtZYb7T8WfT/FlQAaDBKoXH9vOuHpzCWahuRQ6iQDDKRBGD6pYTNesRCxIElLGcdbyBYWAoTepwcP6
# DATA dLn2oHNs3xh5tmF1CzC9zzALLWTq/v1sdLQUQrdUaA3XX2ZkdUnGPdvckfRgGLSGc2EHkBSb5iyoolKHJkMb4YdC0TLVJdRr9vD/
# DATA XyuN7peKA73QRDB1KEirUiCHw2hWtO/LrMLx6j2dU9FhJUYlmmhIga71sOK4g6zfOB0I9CSngyAux+jK2gjLh/wm/FZsNiVWCFsv
# DATA KE6pRdZAhsZCZSE/IgNvi7wQVVZtznXqO59FY/0oGtUImRs+ahQrc5Now4MvywJE0ulvC6lA1br3vJFI1uIwJbPyB9KCp+OVkiFa
# DATA sMMSmxWlJy6rVkyXVI+qlsTn0nhm8BSmTqklmUtxIS3IxpaWiGAYAi28TiQphY9yeTAso2pghOkK1DOACEM+hPlc6fEhuCbimcUe
# DATA IrDCIHa5xgpHjFtwfPMs12wn9AbvOql79p/FTv0db046JO3d6klokkdgWTAx8ZGLajIvVijXAZymNhr+LIh5yysWLHaVrqB4+MBe
# DATA bUVXZe4BUOOPTatogzPXN+WVyvoVXf3Cg2mvD8KPdvfTb88JB2Zr8FxAsNkQbbph0lLLNp2K+5bSHmruDSvqWidV2GXINibq99wC
# DATA zxYs9y1cSINHFZOeWwhvCbppaTbFzIPSclqZTjq45IfwpBC+9v5rJ691915757UHr+3+Dfm2eb2+GtU3WNE0h2sWIj4E0iMMHLIo
# DATA ChX3Gs0ju1TQ7JGAYQSxeuekFFjQ+lW5CSEq2QzmrAaK1M4Wkh4h2LmS6kFxIcuRjPpNpC+dyfK9Kc0V9rv0jfmd1NpYM6WeGrNl
# DATA t2EkzzM33+N23BoTPKeoUKvAJK6nkStBXcxbGKrgMFm6xZXLbbqglct/N+1h+lw135JZukFNZr2a8ekOeBi7hZipb45mTQZzNjUq
# DATA 9ngthNFU2FIOyGDrxOARgYhpn3IjiYTuv3Jj75aMlAcGLqwUchO7lM39Jr4law1aVcd52eyMCTmbxMo0u+OgZab4RaYQjO1GpatN
# DATA s5548GF9JhDHYVXW6ipivAy84a2xacYSdMV0j/rtjmBiAJgU/uAHjrdfrrGndM3Mf2WCI3vmnHSpChuZ19VQ0FTTVT1a0CA7Da18
# DATA daZbqzFXDl9RlXgwTBJbbYYkn1BlpcjpHiWeFsN1ktDmTLlN8hc5NYl5gBH0Ji3utOTgxtLSFCUl96JvZU34QGfe0LAhSj3yiqkl
# DATA WyjHbhQTlzxV0avB7mQ4GiFK2pFEoo3pUSVYDSTzwkRavVj0mbPLomVJ3MUDBK2V7lRiBp+gCXj9biWxttRppXFDubcbSU4uvkgZ
# DATA ygNDfF1QRrlLAcQmU0U9a4NeR48buMAlDwFzuxuvJ/1OW6irgaCfwp2loj9g23MqqaFd8lyymrjSo8g98mjGnibDr46jdh+jt7NP
# DATA qXewmPkEikxjvztzvhOPDIncAVDXEt8K6cmpa09Iqz/NfIMO22TyAby49GMjcWBoARvrQK4626mXL0//ojSrcA1i3SqC64OS4xtQ
# DATA 7pH261u+Y32Bqr1c+SRnqExCv63yQGzdD3zLJNe+JvbmQM46BuRlrp9ceVKxd8W9jZTlgg910xbNmaR/n3md1LkJLn4JusbA1Iye
# DATA f3XxSXD+e7hz4iPOReCdAVSAFFbyoK17VFcfo9b46/NvQVsJiuM/gsr4W1SXf8YD+O1cK5OimcjBvv1ncKvfPoUMHqScuXqdCnOO
# DATA 69fl3UIf0W9z4IpvSGe2UJMUHUytF362/HJS4gRkFQxFq45dOmTzH6kaldcO2nGuG/+BJxZ5+5OiEK6WBQW5NY4xc5B0Vq6sjo+m
# DATA wM628ZeCNHKKsddaLXFstFpF400wMbba/EohVFp+gvkHdUgNyCTuDDkRQCzEFWkxQ32llCNI6xn1u6TlpLAtEp/YLAvfyOpHNjbW
# DATA fBHWDZrjpJ0dWWyoApzKcEWBrzInDFqeUWxC+xwmYJmO+6bGzzu8MioOsJcZk1AuY9gMRP+djqKaShiGBsWafAf/wFuxvlXCt4ph
# DATA nBScVM1dmsxM7+C0lEz3CIsDYCFy+hKnuSPd4Y+G9dv2m0CKltcofx95TQ05nJbe5UP4Ki2XJUvhc5wzFSDJxoIl8L81fv4RuuZy
# DATA 9a73SOLgdA10dFB+gwYqwfbn4rNeZTUNSHMbVTBVUw2SEfW+oYfVzFpaTr5o8jTrtJFqf7MwVU0XOvzMNzn8bBkA8Im6S+A3ZQpQ
# DATA Sn5NPS2xS8C8LxathXaPVgspoNUCptJqhR7XU2I3qV6SKjPHT6LT2Xk5wIwQOeivY3AzCs//DY/yz+n0zmkQsqyQYFd+M/CYTFnl
# DATA XCLDKOcowrTacKJ/e/FbaAQqI4MqHPJfQu3QfiUQlPiMewOJkbDpT/Hdj9CShzKckAlQpCsF4rWPKNES6Mr/0cgZjj17DrSLtixs
# DATA ExBo4bZZg/AMchowSPGUUiIVlv9rBHBdZfwXXlSvHP49O/5reen28m03//fKysrr38d//cfGf+1omHdM1BGNCYGDtPuJ+K/4TXE4
# DATA CWZ50JtAKi7p5MDSXpwvBiyJGi+zJ7bYP8GPFH/5iDDMvvhnHx82lxkZ++iP69RY/Fq3pRK7lQznPVNqKlle8Cwv9wCwojc5JQNu
# DATA 1YJ8tmPcC+H+Ulj52RAc6CF6Gi4yH0ifdvJoN9WKoeFQJO2uxaJGNrLi5BvVlVtNhSvdGY4BQVXDAGEQuvZopbRuBhyCwldNWJvi
# DATA UIqf9FImAKmZEYZxDXbq9zZ293beD218JxPZieo96g8PCuF1ie1qeSZLjxBPw/M0bngMWIKaHTwu24Nkk6jV8SxwnrS596D9ta2d
# DATA 9WRCZqgpE4pWrVnSEZPc5T1LZ0DjLqhxwCPtSiOd7NVzz4R6RVkjIiSJuWvSzDYpw2RDs0F3EyP1ZhQnV+DH7UdR2WsPJbgOKAhA
# DATA +7zFvB18KNgT5Alqop0btn97QHhdcJU5yzNGLbC/0ECzrwKcG2LQ+zuEkDKwXpGCIRAAKjMkfSxq5i2yCZfsFBaKJb3ih7E0aXpv
# DATA awvgK99Hot613aKoDhm3y9dRG4MMj9B2t4w+5trFengYkA8p6f1P0DbA3FuGoYgLX/Sk3ZEUK5PWERt2AMGzNoIi+pbjXIbsyHzu
# DATA 420cZnhmtJ2+S2ywUKO0hzp08zMhrNO6Y12mJG9gpT3sJaN6a0clmjVdCkrGhguLZwn+hS97ozMMpX+vGxvWC8uokGLBkPEPRTtA
# DATA YSAoOabUG3dkOLMnj327fAhBw0+XV0p3bp2FfsdEqCkvC1/b2txb3dis7wBmZ31zb8s+SBQhz2NEuQ4dIBd+MT2kp9MXfDEfw8eE
# DATA 7aYXYDGF42EwaG+4mFnQpx9XsSIzmpgnpOQsGRWL8gYyK4trGfEWKVYOfTrOESzjCYsBL32aUEOFIuMIDELV+ihjKXLF+HjhgYwq
# DATA K5DbThBDMi6poaprmjGcjuHAoxCRepBiDqBnc965R8nziFzLVMB46EOT846RnRhTPJ4XfHA26GHCXgDwh8X8+MwLLKg3rUfl77f8
# DATA mClTnNhkD451ModKNhoPp8YTh43KQuMdpUQjbZDB4Tq2w0NNiVb0OlnTTKWMI5FKNNWAmTjaFKQD5tkBIJM4a+ip4jXKuA5wmdP2
# DATA MK7IXKjhwFQCJyEIMS8LS97tSaGYhZWYN2VKwZczxYw1pZkh33t4nCi/vLS0VCxmwydmT9DWe+II8edK9nn/5shNXMwJ8k7MrmHL
# DATA gU3L1ZDDdIVAgA5hZ66UQVUszEyWnEs965NhFhbu1++trpFsSWnOd1/y+Zf3CJQYCmzvwEBdFFMtIAUeSkp2OZ3ZNcdplZwJCRA8
# DATA HY3wsjyjE2k9pa2Q2kMbsHZmT+cNNy0qLIqjyFDWtMaREPvgriBdI6rSHVE6TWR74BWT0r3GC1D+YTMgCtID/x3fMWXjxWgvMCfj
# DATA mZnVlnbtMOAQMjLV5YhwVgqslmnMI8xoKVFweLOGlzHDMAxPnbS0aDkQeFxUppyCtAbT0UFOKlWxHepUTCbK8RRQR1oeVZR7XL3o
# DATA BeUlX04uczG56kuJGwp/qP11LGHe2Cjks2b69Gx0DQyrNOAnzxSJqnJgDNjkrL+94vTCD8+jZYGkg86s7qk9QC33uiYel/61mC9S
# DATA 3cvj8/meXSIi3eSgjmISDwt7f6bI+DDHzqbM05VZN47EbWOOm0b+W4bl591I5qOZ8/aRvHnAnBpfHX5GeQXoNuEH3L7MVcLwDlda
# DATA xnFh5uXCuXfmuFq84LXiUleKvNeJnFeJq7tGZF4OruCOMf/9IsXvT5PHQs6bSP5biAclxESS0FcOzH/h6qa1I5f4UbDSNMEdfN+i
# DATA brymxDFUZc6QK8+uFsKipKZXdlmjWpB8FrkimYq1TYbUkuCqu29Ka1ozlUvuc3BGWD6R/lCYfzRLvEBqerBxb2d1b2Nrs7W79XBn
# DATA rR5agbbSO4nDj0YEcaOZulhbXZ4euetlcvsRpNkgWCjLaImnG1Su9ehc0jYL8sMEpb9Sy8G1UyYAt5NK//ZgY/fB6t7aO0kLIujW
# DATA uX3Bl5G46YCRLle0OoQIm3/13QclY+mhjVoCkgVakPdEdLVj64tsG3WgLW2asbCOkhnd6CUzNXqKILSCUhCuUh6hlW616zY9zVh1
# DATA Ul7GOoeBO5ZqQsZxLFDZdc7cDZC4jYzI9Z36epiOW5rn0uQi4eSZtd36zrsbahe+igJFHIjzH81eZUKGkpYvOs1jiIMTUxAcjIeP
# DATA Y1Rej6aTuLKQkGwansil676N00ykk/RpWGdnpr6ECd8VCFLOKqmFEQ9kzjwGaG4JmRyIgLZEEmk1DcTDuGjqkeREttUZ9xq8n7Cn
# DATA LFjJ7wTZYm4AzhWwkJRU0nBFjEmuOTljXdd6AM2jL03zeOC+YlrnLIpcfXB3497DrYe7tCR7qzv36nvhfDkCjbHrRIFLMhA+wbuc
# DATA XFsoOFAVIYboVT0hesoTQFuR+BHe/c6Uj8wUBGEhCnB7g+nJgVJnoMUa+UjAwGiMwQatv6lgRSQi+CgaA45CjJhCiDiGmxKj2EBj
# DATA pMzW4HGE2baVSI494LZzayX+kygjLEvgVWgjjG2VsCsajTGTzxUQBjNkgrJVhKwqAbUnnZFRClbtAPJlDo40bO+2WD5x/8a9BYsL
# DATA PeJC0Cn+GDN0sGWYE42VdAHw/tKdzgCnhBZNCFDOLtKUgJ+9w8MI1TMb27r2Ewi4BLDOoI39rASbeEIIcQ7ouD0w3BUhR2gEcIVe
# DATA JuHIkM7+1tqXxPaeiYpnaCDSG5ilPpACqXW7YC7CZ6QjdBg/oodnTZVMig66mNlD49VUHsYVPFU+j6wTUA6PzubTtSZCnTDpXTLw
# DATA LO2aPxOQSukAZms9zq5GgH412BN8Ui0IbDBy8pF8VS4fnFePImS94/i4NwLE2gHBHcmLVpfxJxOWJd9pYc6q98zQBXwnR06sr6Tx
# DATA wJPhHeIo2hDP25oMkVoMUshpJtCb4hJIowspOJ7K9sPGnopr/VHJ3/0p6dMS2tfIT8t4Mhw7tkrVl1fmtC+5VTlytkYETwcZTfEs
# DATA LBazeJ1XEGWGKam7CNmFL+FdR5TngdyfBYzPD22YnWRmMzOrBFEwPTajQ+lRgf5QdlTqlZkr2Y5JyuNPDJA9yKchbxR5+5q+iS8g
# DATA 7ulRSDFPOsIZrrvmGSUlkeRaZoXZu/c4F/2FgSaplYxtm9MK8kKmNm70ElH+BDLDFnC6SplOna5lSHqYJw/X5KUncUlPpCmV0iw8
# DATA T2yhZJg5+dUarq/GpSulD/SKr2EthknniBKaZD2+vLOOfOklajibJYwbGorBIlYbJYbr8WLPGBJu4iVUrRlOnunICphaVxfkx+Ah
# DATA IjMf26PnM8fbo9knz0x/klxeJHqUJdWhcDpoP2r3+u0DAlkJ0/TRV3KdTFdTU78weSJ1MOTgbPHoYDjsm/7p6kqSUR9FL1dpnI2q
# DATA uOA1Hf91rFV3U/+UVa32/0kl+zMPSKq6Rbe7pwwJo0CWVySmCYA1cM5dPCJOhoLfDQe9Dmbl5vIE2XUMgJaJQj9SVfhAtPzbZe6t
# DATA Yvv527dDx7N/J0IDr/49uWGKWtoY69JASDZyReL9jJ0JtTloJV5o/JQhWfUk+2Hv+4xu2MgdWexYY4FKKIxM9erq+vvKR4hPVUuB
# DATA rcLJtc5aR5hr4Q5xDkx47ch4JLlZfyiu0/n11VvbdbKG2GrrfHp2jfZg9Vj2NqVHFLCcJZkA6oMtnDgSSdNuEIPwqT2JDIGNYgXi
# DATA sEfxZnlpSSFOdIb94dhTrWknNkguq6+qFwxWodAtPH2UCyZ1PsWkqJWczVdqvOKmoCW5kqQqFXRhntKGqm8ibiyk6QMNnlxdBW6K
# DATA RtsJhKIAumJvIsqxOhCgqMCEGI1A44OZS6Wyb5Z88GeLAWtDv2oMUx+qq2lU8Vy5ZOGZdhY2c4C2YHdj856Eb0XNvdL3maTI6q4t
# DATA jGMEy1W33QcjEYufYBpERElcJw5riSuB1OpOjtsTQ68AS881YswoUAGpJI5AFYZ6hsnjYVkShM7oKG0tbZkMB0miwriW3e4pQjWn
# DATA 6grgrrQmi5GoInrVIoizGoBgit9CKa/SClhDolA2dSm3gwsNEYCOm0hluI+Rnz9NWLa5RdtVBt2bZC894YTWb1oVQNvGEZvMK7XY
# DATA T7TRau4lVFwNg6f7A9rNmJ2X5yRxn6zeXFpe2h+cmVnHT4biUkrJlWiwDR5Wk7rySJD/iTV3uCFBcc8Jikxf2RJm62NXXqoAkFv4
# DATA RAQda5iagIjLMwgNvkGggDxhdq1I7lzvYjTpLGK5RU0gpKIDcqAhFs0UMYpq9GdwXaFh2Uuo4Y8xmFjwrppMAwyNy3XR7FbVKJf8
# DATA SohMUwLvdCmccwGNfAN2jLZOKScZg2yP/JaJzCKoIW5RuvOzopMli9+0LjOYG6l9Ir2hTMblyd6dwsHeWd1trde365vr9c09yc+k
# DATA NicHZHRahnrKTW9EDZb9aMf+LPVzYBWru+ocMMQu3HBTR6nicumlqhra3zofo5AjbNruMzoWHeeADSm491DcOcUF7k32WJKnZCBm
# DATA yPRXf9XO4BGwBBGcQKYyUq7EcA0QjLw9CIxJxHNYK40Vn4BeN/EGeKicphpGHiJzHWDWoZpmajVSoIFawsEwnB9hWcP6ZL+Wv/xs
# DATA OObUN21AZhtyjc7d1JDcfGrAS8T2ksN/u9+iDrgRuUa3imTBUd+Vh6KTR0nVqALtU0J8dXhvVnX6vvoUqKJqxubyPtNBuVDirOjb
# DATA P2fsDwaooV0L1vo/HuI2lURyQ95qdoy5BB2ok4KBXuQH9XJwcVN2RwYpS9xcTBoaqgzeUYsdtVzkPrUOKlaDPL+67UmUIEJvd3z+
# DATA ZCbf1YCHXGvCGJdYdK8WOzn9fD++njgK56yH0lfh9QFDxpMV8smdg+LNdGse6i/mMjzu1B9sibs7ahXWtjbf3th5UHfAN+zNXXVc
# DATA x2m/22e0/YajBD30y0E+73DMVplAymhaW1nJr9K2yWkuMyEo3B6pl1H8loZw+ZRzZx5FKX0k43rOpozOadZQTAcANcpLllPMTKzi
# DATA TF/Cnzlla3hjZVXWWEtoAdBI5z4VCrl43FYPiqlxtVyjh5SSfYfstSBLIGGbFG78DAahpJDb9M466D2yiDl5kOujir1O07BSjTOy
# DATA ZHAlE7iCwFIUgiZqueU5IPXFrN734KpC0A4xUD83n4W36t3LJguZZypm7G9XvpijFWsenXpcgOAU0cTThFFqOqCLdiJ2gy4zNnoB
# DATA BxIlDF7eSKrMUfJIOd8EWh0cG3W6z5U/EmOmYmt+aNzMkAwTNjcbMhdm0oXJNUMJNNUriwjoErs5nU7l0W9wymoi7ZdijFX5tg2N
# DATA lAbGoSXinNK47TXlyuWKRF8QAcz0+U+K6kW7HVY0mXjy0utdVmPEAfgQdhTklVXGVFpoed10DaVsUWbUcdpalphTa4XydjuO2XFU
# DATA EgSDBeKFpyO+w0yL76jPQTzBjjQOxGIZdDZtpU7O8E9OxNQmPHJy+WUU511Y1zVbZttim6sV3JFvV8j478B0ZRbdhujv0A0FIcex
# DATA wSNNJ9YRw79Y8wDPKCIM4q/i3s+j4C+DO7dv37wzjzd6ffNdQxbSTqngydEDRXS/MA7/1hMGXisYoQHl5o39Svb34g8oo0mWvg5i
# DATA SSoPEohJymGzZjlsmsvkOGjahxdlTCO6lvnA1h7u7rV2H97dXdvZ2MYQoZ36w906jw3UIVS1YBz7A2XRe7FwGLJ7OiEwZjw7xyVZ
# DATA MrtdvKilYvkomd75P62ZJodqkZbRn4vOa1fJsrEzxIQG0jQvMJkTbe1OtFQYJno3YLwoY7joQqJD7djb1/X5o+DXF4uiznfLTAmQ
# DATA S5mbJCIHd6YhO9JscAeaDgSlvROsMKicSBozRiLuyJv1Nd7If/1wY8e9Laf1IeF8AEvTzQPWYev7585aSK95cxZmCnxa8rv+VFy1
# DATA qqrPePHyJNKyb4wp6CHeHC5nZxk51VIXFZI559g4CecxOVlC4IjGkxbz2hYz1jgZmUzsovQCyQZda076xCfMAy6zOUu+nDwSGkxA
# DATA TSMXj/IQcJ3J5Hw8pIl4l2pDovdgwyeTVnve482yvvXeptj46/XW3ftbaz+pr4vZEicdCOtYK/jPg+kYvyy4dO7L7al/T8vumUIx
# DATA SbrQafXk4e6+5ymamcKPjkFdmA+CYnqGuLk8AVEaM3czTVCx5A5FddNIMccH7GVyBqbV7sscSTdbHhTaT/Mlmspjz/szsuFl7+4c
# DATA m/hlWLUub6Wa2x6WZdV6SVkJX4WzmDKexpFYRfGhf/omXvqMcCIZDRNHEJ9Nvw77fWgvIIeCysJ/epuPz6J1dbbEq7cOXtI6eTW2
# DATA ROv4v3LbV/LovX698DR0TWESKXvW6YQsMynU6CsXOGfMsqjlz1Z5edvbJewKmZayl57Hy+sUOSvxpOkUOZ/9an672IuYa3IbLZJZ
# DATA 9TLU78mQiqQBwbKX2b9lGeC4cmVYw3ryv55mLJxrwlNMjAac/AsYzy5nRpKZArkVJ+NyZt69q7APXTYn3/e2pQzb0nedsDCV0Zn5
# DATA ComupmNbw+gI+jr2LwXFk0ql4vdw+IX0DnG1lAW3uaKOPzTczn22g+SNBMEglI6UXGJr5JQyfHJaCyWwSTgbuSQnXAnjUvgwKRau
# DATA 6s6Ya+o5JNIyZNgwMjmijoER2/NQaQ86x8PxbCfO9Y2d+hogWKAPSf3B9t77Oo6yJ+EB5rBlWFYZJdVJSAljMELkR4C4ogHKiu28
# DATA QJ/RVgJOuypGRpGO8sHNFwqzs/VTo1IiSSO8XcYq+wOH7b7UtFe7HKlbX9pAtx6sbiRUlWi3zo/gSpr0Xn9C96Q+xE7XRAUVxpOW
# DATA F09eRbRqyBWVcb5oUTOWiIFHk7cw8jPH7vTjq+5F5spJ9AWxcn8lqKNV/+nG7t5umNiKpLphVpOueiH2Z+ldeofW8JNUbnr8ruqY
# DATA mnHEPDFojzvHvUcR32y5LnS7DYaDTvSmTEBvqNNeDaYDBE6IdIs9yBrTHnAcRgTGFEocczCGba+dfLm9NJWM6ticLtZG1bl0NAm2
# DATA kA2S4DwBtmdCR3iquSyylotUgeeEnLRFeYWfWs5gunz20EsEx9UafmDMhH65cyxeLOB7xQwMcCuVmyjCR4fW33sU9bXjyWRUXdRA
# DATA 79WbSxTq5isMyyy3QWWsYYJ9OqSkhbpk9tsCpHlqx+8a0YlV8KwSNB+XwS9zFFFwphBTUX1SDRqWO4hqqugo3sMR4gKJ8ofh8srr
# DATA lSXxf8vVp/D0DENkXE09MR1446kDFkHiVnk87Ke5l7g1DY+OKLD5adgd9zAdMRkpy1IHNBxJ/eHT8KT9pAymdyi0vHRCOsgnZR5v
# DATA eDM8cxugmNPOcdT5AGuYiLmDoYZrD9ZRuhRUhzwV/3sYAZLCNV53PRkwC4tobBWy8iLVea1YEdxnUBjX/lKGm2NK1HFl+MFbS9Xl
# DATA YrHSQWCGQtEpIX5i5ARRoZBooOu3kclzYLN+IHgbcCnxYHmFglHHk9YoGveG4EkXrizF4dlZ2uEKM96QiyWucTOBPeBqRx9tC/VT
# DATA GeSecCKiZUmuM0XH667xceD2jR/LYAmGYFCpsy21CdmfrTeeqjdEL87UW9AlyJ4Di6X9DXkIXIHumitbpClrrY2k46qkmH25uLNi
# DATA YoCGgV1GnllMgB5WVyrLy5UfChFl1BtEYQ6moAyeMDv3ttbrdx/eg8InYvp6cG+bdEa1pRBnUfKD8I2l6hvI8G7dulkV/zM+Lk67
# DATA I6RiGRHn4zd6mtAnrOqLTKuOh0qmLEMYbHUR/quf0cxUF1kPbHmv05zJLtBM6ZokWZj14LOzWTyZhKmyFKbEZcFV778c9zuHe9n+
# DATA xVUEUykkKcUxYbtRAMl18QyvaEFW0IezF4DpSfUINDVqmcrQVL1/Dg1qd7ZGQV7ObN2mVxGV2yZ25kY2EbKoDSnHaM+YvLzKJ/04
# DATA RlAhmdS3sjo+msJu3cZfChL6DhQGrZZYvVaraLxZEfTdavMrhVBFuAPNEupyrREqfXpZw0ATSAu694cE5TPhSw9rMrT9ZTqOFF8u
# DATA T8d9/oVvA2UAJscTDMQqdXYrf0q8qgh6YfgIvEmWOWgVmdc0jsrAd/Q3qolkIxfzQB6FPsyGZsbMlMtAvqI0ROHWtlEFJh1gDOnS
# DATA dLK3HYhClOgROTA14a41RfZ86BHLsfZO7DSkVNUTrJOtKjQ4MqCYYA/+AYIYql2PxS8xmvSxLP6B0rFGnIJvFRtMwUspLsoEeq11
# DATA pyejuOAFGMd6ScOBHw08c/xu8sloEAvyarXjTq/HENMsy/ezehiFluIXje5YmJRsYgXQFUw/J8dcDJ6+Ai8neS81jVi1wOlBydZ2
# DATA gS8maq7c/hTVWqhXHQuennoJFD9rivm+gJ+VhY5eSnWa9Axqxlrgts6gDgkApnp7mQV3eUZGey54sztLhr6N5puVI5folcG2Mjpk
# DATA 4AW7fYGHl29Yc0gTwMTvgZ5zFvibQZiZ/ZDc3R291F3P16qxaVAJ63bF8GVWqixjIkHjEeJ91UP/LKRDkVA3TjgHhlo8e7jyUDQy
# DATA J7PCP7Gw6LTZzbsRs5vVB3DVEX3BdJHd9PyMaFZXrBM/AaKvnKFTulVM3yfkXkmp7SGmzfKj9B62xbNL7B19PCeBkxJ2ieQo1HRK
# DATA E0VjqZndoCECpN0tDXKXfvNXsVpa/HKHqlGN0tZJ1mxayiXCVjbJacwtIeqKjrXQbNRqYZdaLdiHrRb3CNY47h0NpgisWICP7X5l
# DATA d+PeXn3nQSnQ3995uG0mmqfn9KdAFZQCTsVyvSVuYqda15L0fyHZe+HSzp8kLuyexoJW69CKduUEDcvwUTQaR4e9Jxn+nzZUr5Wm
# DATA V4Ea5kqM6emeuArHmBHdRXtOl2pEj87/OTj/08Uvzj8//8P5N+K/XwYXH118LB48E1+fX/zf558H8PziY1Hs/Nvzz86/Ov/64jcX
# DATA /yiKwu+/Dc6/gl+e4ctfnz+vBOf/vyjzTFT3/OJjePvZ+WdQ/8VHVrkA/h8afn7+6fkzUfKbi19B438vinx5/nWwur1RFk+/FXVB
# DATA S8/ehH59cvFPUJF4/qn4/Bvx7ZnogdPhZ9hhUf/5F+d/xJexgop7yyYd7uraWn13t/X26sZ9npB/E3V9Kzr1ufj7FdSWa9zc6J/w
# DATA 5S9FeWo0MKu7+DXOyDt7e9u7ZT0vpUAU/xZH8Ymo8hv+/GvxnF77SDT4G//sPYPZC8yJcqbj4ldyAH8SXz8SpWCJ/kVMHBWDzn6l
# DATA um/N2cWvEnOGLuutt8VctR5AbM9dMBhtvLu6V8ep+58pi4cDFP3+A3yVy/4NzIB4CJT3DMZLVhYcHHQCHxmDXLqztCS6/v/JauWM
# DATA 4/dnouNixIkOS4Ok7jh21CHRb89/d/ErsbZEg/OQZYDdw0nDyfwj9+p3ON7PxcflO8FPendTO6bjAzz9Sts6vxMfvoB+fiLKPS/h
# DATA r9j810CYz+X3ZzyNSIDVAPTbcXWRfQ6jJ+2TUR+9AROdQwrlrlnM4v+hFkSvBKn+HojH7hk29rmYzU+w4Y9EYaxLrBu/+jUv19cX
# DATA vwZKdytAGv0TjuTX51+Iar7EmWhPJ0Ozl2fpTFmyQXSh0hxayA/n/ypqhmV6JrjE8wTj8OwUXswvkAJhJ/4yY1uLj/89OP+DWJNf
# DATA IG1/jSvxlSj1jSCf5+e/x1+o7d8AOxN1fYXLK6lMcLVfiSpFF+BX8Zsgyo8rcGj8xff//vz+TfpCBjp9uW0siX93bt3Cv+Kf83dl
# DATA 5dbyHfmMn7++vHLnL4Kl72ICpqB6E03+H7r+165dW4vGEwrFjgJ2UgIpnPPKauM36Rajx8GOtMRJRy8Kk8Cg7d4J3melNlh+p4pI
# DATA lyefwf1Jfh7GCxhHBNacfu8g4MdwuZBFxqoyLVKqJ6fqo2ChI7hfLFCFLB3LCukuXbIMWy16GJcCvNGwkltcBQZx3C9ch4tBCUFO
# DATA OSz3sN3rw72NmXQtFJLI58AjBa/7BfJDyQu36+IiAJxX8NznF3/P3BZYNfNKlsdAWMCD41soKE5GEtksGe45MlvRxMdQlSj1FR7t
# DATA z0IXmd4QuMXgC42QRwJ+iDAWSOQIqdFqMCRxWWuPJjCa4XQCD8niqFCtbxtuL4gjTnaBzrCblUXOmSEPknaFMK6kM6OmwNao3RsX
# DATA jofxhOE89E8lSh5kLl1cC5U/IHlfyTfZ3iLeBt+03iOKEMLLqlFlkdU1omIDMR/vc9ardow9OLF1EC9RnMwjiprE7+H+YH+8vxTO
# DATA VNHShQUFHyASPqKlfClEigCFORAeQZxm8VHIHnhfeH7xD0AMIGB+iq8IKknmmR4ZSBIwqiQEwPLSyq3gOv6Z2eF/T9IeiwZMwarz
# DATA IILIzouxlaXYiZLcc1O0FDLHL0G4DB707qpUfztRu4ueUEE8dNkRLH30d1NwjwHncHChncaMWStRjMH2ATRUUQTQIkIXa4yfwItT
# DATA PCXVxMEpKPyLaqGtpxTMwnwgfHJ76YdojBsMwc8BPqFvRjRAk8obd26hgw0yCtWsHNWWqGV3976MNomDLmasQkzTXoyYBOArNGHc
# DATA /DfFNgE1kVjIwc+j8VBmNaDgEi5PO1YlrDoIu8MoJnwDc9uE0hFy5khg74hvevPZY8kZbGyi8iQ4pZeMQGL8DNgiUJEjm/8e9gLQ
# DATA Ft3onmW7bl5F/YoPwDzgLvecFQWLC+k5Q1uI9ZsM2rXtPVe5Vi++TnOslX0HhnsQSPh0z4Sr7qdwShkzKriBePIMr0DPEneTHJzy
# DATA O+kFJ5QiWSLuEwmA+AAGQUt+4O90RP5cGrheDWCdJAxDHBwMJ8fBzu4qbtj62vru6pvigOIUOSfgIoi/ngy7034PMXMMdjWaHvR7
# DATA HUA0ThCB+EmwMYsefPyGmZmnppF8Xfwk6WnUhlQnZP6N46qsU/JL7XBsdO6VmtNI5q78t4QuQp8bcByIZfhWyD4fo7DzsdSNocLO
# DATA J/RcfCL9MMFc650ovVvQst4lLwFnrirdCASZQiKVkairgsVgkVuTYSsWBQfduIANyuRgNUoOttyE1JOSMCqD4eOCpI3KdNIpVuCb
# DATA 6MXJqDCDd6G891WAercvaRb4iu8T/OCu/k9wW/+G1JvPLv4RVRIfXfzWzoLkOQNVEMnodLbAZVi+0mQvfaxeTozj5YzAlCUxRJyg
# DATA jsUQ6ogVHpJRODeC0/n/oKlDken32KnYkb2QoyjZyxCylKpHTPBHgoa/Rq3Il2Gi6x6fYJ8XsPFCwg8Y5gzouhBCjqzOsThxKqPo
# DATA hOxHvUeQsBO+soDS7+p8VKb7B9ZiWE8oD6VsdRF+tmBP5spTfP6/UNn1OR6un1uCHgiAtjxrioTunIrX/4iXGzWrKCca8qwYoERI
# DATA H1nyGfU6GTXsMZvY+IAgQIoJ+rnY8zhJxBmcMbcnw5Neh9tyJ07VY9lC2PyRv1kxNDfsNGuVDMRCrCtOiZobyUA2zmJlk156KGli
# DATA 2CNnnG4Uml0YfZJkeZkMSSY+JVRBSIrEF3SxT0DfOYI9XsPoO3KdRxjiw96TWliZ9ONy6FlNhEsexpXDLnD+gtlI+PggRMOSYOlR
# DATA +8TNmgXP2HCZGJhR4rA/jY+dMEBoLz4ddAqyjBjDYFgwormHsfLJp0XHIHfalxCp2DeGgNwNJcbUtWIerWDz4sJJNDkedkuMg+Ag
# DATA 8JkpyqmAFV0mM5EbN0J4krwU3rn5xi3Pz8DPgv8WLA2XXn89i8eub+6afa4KXiCO8j8oY4dx9QNuurG5oRhHgDYCaStBtnBH3Kkc
# DATA zDFTlVQhpBV2NdSQYhJDzXyVWAec9IOjQtjoDuLm/iC8gcM0vDPkekV9zEgNSTCU26p4R/noReOT3oRC7wtP4ZdWpz+cdg/7bTDp
# DATA j3pk9Q4RMIDWjbwQVCFO+EPvHnWG9Bq/pZYu5VWZAoL6SQkn3E5EJ5zkyNM5EAONRBTmaIxqlTxktASSnyptJNt+hO4oYkaBxfGX
# DATA MX9R+TuokgomnJiVX+L8n4E4lOGWqEgcFxf/QAL812joxfPnd2wA+YYvdIIGy0p99owsmVAkdJDhTLg/OVaG58ktUvwLkvTn51+I
# DATA xsBi9ZE2wH2CB56xGaz2md1dJoTIYrtUG4ToVn427A0Kh+HTD87Afv4IvPTJFaVkTb/M7lFBWEXMvcu8BpzNDakNKagUSLaTQxD0
# DATA KeFsKgYrmO38iK0YAaBGYtBxaEBDVm7sl5s3fqyfVEzwyObTlRIkDsXaZosvaSpb2jSapx8LzoD+zSEHSFBvwxv490aIsRBI9XIg
# DATA ZppYXO1+rNFB7TNXV54oLj8uPmqPF/u9A50KeFE8XrTkwrRChqwo8wQpLkpN35ArdQMDQMIb4rUbYTIOxA4jM/IOudoOY2yi5pjU
# DATA 0fm1J46PWHCjhizlBnAxom6stpi3u+WZiZMMJybzrmEGyUi3eNojcJsby1Q/YiNg7TpFn4eEdR6VduckKjeIeJsNhXgKUEFc4Wxe
# DATA 4xCt4Dro8vBHuCd+jMzujxaz4z6RWECdTcaXa402lsjUaM+xmRQPROvzZ3hFfR6srj2oK3VvjEZvcZiNoo64IIpFJJ3Jk6izi0lt
# DATA /m46BP/GAHQmXfR17ExINxMfR/2+/J30J0IQbI/oFMOB6BjJ/X2goX3xLzQiJ6/Rw2vms9fg2WuvcQ8N+qDkVNxh/hsWFyUt3Ahl
# DATA EKGdIDVsPBz0JkLWWDciIXYi25C2d3/XvCPvD1YPhSxT44iv8hBExIg97AIOl+bW9gfvteG08JZF3mR1hkNyRH/2IJBACEnx8VCU
# DATA e/igHX9QWxLS3f5AzX7tmmB0NKc3wmv7oCTig+rOrVuXmCDcPLmmR06MMSliX4lJa/dhTI09qEm8tTVYaws5vNse166Xxf8FSzdL
# DATA y7erS0tV4FPW0HcEYYlz8+dRdz3qt093o07t5h0otQ1K+RguA7WJOGOx/g2ybDZpdqPu3dMadj5WE+vMhSc05lJRMbkCYiSWBEWy
# DATA jFClZ8oZCugA4y8A34TUe5NjFas5lpKs4avaMEI5TK20+Mp6Q8uXlU51DGShTG9WmEjMUIEqagw+4qDNXBejZBTIDWWNS/4oZVoO
# DATA nqzJzMrJkhbnn45xUty3QGk18oeWOO6oasINN2ZX29WuSOtyu2Lpu9oV1Hi17Uhu6JPpA5twVx6dWk7TUlU3uxnTVX2+Ng0SMpo2
# DATA bqDtihQGRc18C21XTBHaX7ETnkqCpjkSFjXN+i89DCLvqpWYF+ZNHdriI52EPkdhBpM0oK3JxblCsIrJu2IKyfC+syXRV4OfRNEI
# DATA LZUSvyiQRzHeuCGn96DTnwLaeQCeGQfDSRgHfUAj4AtJXElmSW+Ek74MIuVtWTUm09rNFOzJgzKN4RUtFBR5y1tlYV+aZex0mXQQ
# DATA 8DRZIJR+ZRMJukYS5kk/9uRzZ/kF/JQIsM0YCcou1q/QZx/Gk1dmIfPCtxf/QNfHi/9Ojhl4wUTjPFwwxcnspAAiN3TRZMPqTLP4
# DATA pvkT9KSZw418hne3370aju6Ep7WlGLmU9zVY339GgCWYwJVVZCSSiZcf9eC6YvADnXJQIpBEQX94VHFc9sPzfzUcW8SMVsUFyvBr
# DATA REg+nXs0or7rkbNuNzRdYthhEV1sNjY3StqhQvw/m9shYhcGUjNSqaU7XS7/n+iiOD183Dqatsfdl+gFmO3/t7xy+86K7f+3vHRz
# DATA eel7/7/vyP9vLwLbdnvc6wPgQwyGFsgbyjhED99+T0ixmE2Xj6MS6d97A0o6C5aIMSWYPs1yATzsDCb9Ofz94uPppKdeoHiZ+TwA
# DATA +TtgF0kFFzrsUITXDL85cvvze8eJw99xlLt1O9vrIho8qj29fn0YyyQB4ny9v9ZavY8u82uGwnemn90OeTQa5xj4iH1GVs2Lj+C2
# DATA rSMgnkubG4ZjiP/+Fh6KV8Syvhl4+OmhELoeA07V+afgI4PxBJ9c/Cac6cMn5qxlHIcyH4iEIDzuoZnSmORttN1Y6Fo20i9br+HN
# DATA yuO2YNBysm/fWsoDqElvTkBZPYAeFdMTCngaWV5KwOwbnd+jUvUnIxutTlf2Qa/fd4EkdStZ5jTbkEa3TK1gknacVO10kj6y9dNg
# DATA ikXr68eoQwdy+FoFCAky0RbuF7DkiWPGa8kDoxqZv836ccT5rH3/tYx94+hgOJy0JDstiGkrsYqsMxHXI7HJhEQz7AtJpsYql4Tq
# DATA twxzLWsACWg66E1qqQqaxIuID6tVWZryqN0rob2vLD+MnBTI7edyrzhpjz9AzTq9RKgvBJYRsuZxD9HyxHSX0cHrZ8MDscHFoAGb
# DATA bzR8LF7qD+MYpq/f+yCSikpxF5uM24O4B8ceXixdzaOYxRdXOzIngKUrpanIcKFwEzqnt+iGmDWpQ4T+KFWhqRALIE9Ft0dZWSfH
# DATA dfSjqMn0HjSDRUprtT9I1RvaNZqaQwCV41kRlVwLOGeuOAvbB/3I0DJuD+NJbXEajxcPeoPF8UlQPgwS3bCaSVPRISJUeQoXIENN
# DATA Z2gr0SPe2FAhpVAXZA9XfakSS5SiLoe0lyqY59xaJ+olpI1AoUm2Kv15+CijIN8qE+cMVoBCedSVB2QpoKBl0TUOQ4jE9Il7OH97
# DATA fNzrHNdIZqrgl5KUyszEYeJ1QhbE7FMkDfFRirWJH+UnAGG0z3TCCT58LAphC4VQfLHNDOJB4gTnCu2jnh2aazTXyOckUk4z6Y+H
# DATA P1TQlS+G44ASkUxjyCtOU25ZKDLa5X5m1Oipz8fb/t0nUrHj07ccjfwZ+0gJnvamlJ6NcLw/USzw+Tc8h9IWoqaXH5TFHFlFBFG6
# DATA hcQjeyVkZawhUaVmDIsjHB2uLR2lP8VhkWipHoLjphtYTHOhHD+SA+n24vb4pAX8FzwomFSR6OwzsOg7BBmyWmzGADVtnqPPi13K
# DATA rH9V8BhZv0wlB7IF6NxAhSGF4EqwGoAcJziYREkdA+oq+vGCqqIf9NgB32AZXRfytjPs9xlgqVzG0xj7Rry9XBbsh2iuhriQmtGJ
# DATA 3/CEgbQiI0E9p7XVTmc6bnfQdrEM2jLaODobueRUzaI3dYbcacYLsBDGG7P2T0K2MTSa2Flx7zsR8/X4OBow2DwHj7V7fUNz6e+M
# DATA 3XvTpJrBJXLu4jSS19sW3cLZC/kXYvM+h/DXT23aPv/8zYD8k9Cn+UtpgU0VYZAf8A/y4bdQBZhJwSkaPSAtMFq1MwpFe77MI4mx
# DATA w3APAEKdsum8dIy2nEhk3neZlkK4Q4gLdk31aKcOMNfr9Z1c4F9cDQ0prvDXxnK1qbCo5LPqchPUroCyHzZJj2j+brJMWSuzTAoW
# DATA 42qWmo7ZfJboq53enp3/Dh3cgYqSlvGvlJa/mHDjCxfFsjsCOvgQVPrDzgeJexk4wiOEyYBvkOLbVmttp766F3xIX3bW39uRnze3
# DATA 3t66f3/rPUtSIfR+ITaOpyOAwpH4JIdjuL04jq2Ile+An2xs7pnYJ9lYKEk8FJkGQL/R2ri36SptfxKdHgyFeLQhe1ooZkOyzNUr
# DATA P0KLMSts+J59LYVlMuYMFGDitikeFuA/JX4CwCqt+k8zNNMJWVADkr24hSExmRlgMaESYlDAEf/DcNY30/nft4iGcPEPGHFDvNKv
# DATA jQpts4e5nQzDx3z2jAywG7/JwWxVGR1M2wUG8/4TqtV+lapD8wxQShThn5uNgRLVlNtH4Ir4kkwAmfr/5aXbd27ddPX/ry99H///
# DATA nfx79RV18YYM5KPTyfFwcHPh2rVr9zl1O2QCIiqRTmoV2Cec6p3SuGOGA4SDg7wG4+H06BglQiU15zYMHLdjMAioryftDlkKAPgF
# DATA 9Rhw5NCPoPcFZJYdiAmOJ+8I1ti/CngBIUKqz+BqNaFm040PwDMsawM2Nh33RVuVMfVOtsmdLcHPcHAsqA4Q7zFa0Q4PiE3s/YUx
# DATA zxcoOzka1Nle30JXfyHJGTkSFtbub8CNCde8DwtMKhcpYYQLa1ube0IQq+8A1tbeztZ9LG6LIaBMHQ/74cJufefdjbW6fQdjkDqk
# DATA GKVGXHi4ubHX2tna2tOyjc9ZbGH74Q6k8IBEpCl1lh8ti5b3Vu/VdzFECrUYnN2lO3w8QEUORkpRkkmGoaWsFyGn9jzlF8CZozcQ
# DATA S8mgtb1D+UtHkPNAvFBceLD609b9rXutu+/vYZNG2LxS21IKqfHwSMx1zNlxxnKlBUEBhiKi2ZeC6JEOjxG7YhvCJ+Pj4ABMbGIf
# DATA iXkYUZm4xNk9pFwqxegYr8ntxwGToYwEhz1G9zeiuBooNVs9yPiID1gZRVduO8GGlUcVPVxg+yjEbF7xRVabGOkEWTvDLhyiPZnF
# DATA XHZC6h90oTSFjVHfUSQDoXmhRS04JzqpD+fQolUnHHm4YkbdpObmIdJNMrvPvZ367q4tdjsDphwpcl1RpSDH5eTcHAxBLYYRoPCf
# DATA guf+LauxZlhbDVjyAeTzzeHkbSAHJ5rMqOBpiLOE/jmUWQP/ojo16q4CxrfoEdyokZIASR1B0hnKJTag5MU+edQboi5ONtDg2psK
# DATA vQBeEsxCbKkI09AADxKEGkttCAAHkleTIFgwH2pfKNh4j4V8GSukAlrTChiQnxSwJYigtZ7KThWTo28Yo2g2ZEFwfTppPykslXAp
# DATA yu5Y9Mw0i4kqK8RZqC81nlH7tZqolV7EbYxrCE5pEKKw/2Rpqbz/ZPlw/8nrh+LDDw+bnDINyxbFHXRlqblgD4IXBvpd8Dy9ETSe
# DATA hm29jlgTwOgTE6GC4jv+PWsWG+WVW1W3Dc5CuEpZ5kVFC77MfZjTkN/x+bRSLS53I/+uqsNwkrzAdozHcglNrT/Vq3e/zN6gDs8z
# DATA Nqp9w1B3CtPDSnpTFdP76N/pSLbiuUPFzn5S2otRP+JoKz1ho2OESWfvTy4S8gTDKU8JulVHbNab5KoJKzdkGwDf8EwWz4esGJpo
# DATA LnYzx6KOQG4/OKS5SmtTuv57gNVKTF1wbv023tblY5q3Bs5btelN06inAN1RCrzd4+lJQVXawAqbmXUL5lCYySOKyVSj6JyhOlEL
# DATA lqpelw93rTgTWB9NimB5UT5z3V486rdPgzZG1LUhN0NwbSlgsIFrFdf/IJtkDa/ARCpbIaoapKwPjwSByoNkA+YK8jYhWd8IluUP
# DATA a2Lqge/0o0GB5tWXwQNJd3eCGTWsspy4jskfL9jYhJvWKRp3iL8tLy153iECoM5dxzKLZitul2LjWDS2jH5M6Tcks6z6WahTadRv
# DATA j2JIcYKrJV6yqLJgtHMoyCE+poZIHnoMROjtCR5fxcQIICL8BDqyI6nLaFc+Mo/75JFyJth5py9IwZKHDCdLqSwWxEKMXyJ89IdH
# DATA zPTZ04HPXMiZCqmKPBk5JVfBlBfJnJB5oys3Buh4rxC8RHW6lhzJ2OZLv8YyoJluRoXfH3b96tX3drY2778vdaqWsrX+07X7mcrW
# DATA BEKBEsWATyazZFZdxqrKQ1AudB5uCVb0mbtUevEqBFckwy7VYyvBKPn96l8oeNwDOCDLWAl001ARxIx0+pDC+LDr+kEZXEqrVg+7
# DATA HNefpMsWUneBLkB8t4I4j4kOAuXLEUk7hbABMgLl1ZuMD/EED197v/zaSfm17t5r71Rfe1B9bfdvQnLtqxyd0BmPYkQTvRLoHgIp
# DATA s+AbNUVeEqGKqA2nk8PyGxCNCiOPayG7eUgZhPskPY+Sw2I0Jqa0yNifNtHkosrV7e365rpLiqkOVmq6QaNKPa26DvAp8x8yBDXZ
# DATA hiSuuFJOQx4t5dlBPxbz1ixu4BAmCYh7cGXKpjCDiVHeOYlulWBlclukTjFOTionZAb43c4UbxD4yeKzzK+yp8YUZ2mGpNLEGB26
# DATA u2mLzxVxduseDhqVh5ur74ppWL17vx6msmDZl+TSzDJ97aybu0DSvf6+iZj2+RwNxxJWBIOe7FU+ETyAIZDQbxAwM6icx2/QcUKp
# DATA 7LY2dnfq9wqyEom1kRrFkmMW9Q1gOui06aJh1s9QH5ZiyzbKUe/jKPpACjSJ98v2+84QQT1Vk/XAbaNgl/bQaKoBJ3vEFAyMLyoM
# DATA Bzlusyboj/gvGJMn6PRWOECe3VihC4sq0ahCsbGQ2rpcBARgKgSu31wPg4els/qM3kSDLt9kYJIh22xhHJbhHzBqQDQImtcZlD74
# DATA Sf19/Ckkz3M9zwfRUW8wSKnobv3exmbuqgC9gPoERz4CeujaQfmGP5KnhZALfqR/lc8ceuWJChs79fXVtb36emD0oYlnsCjR4HoB
# DATA 26nI6gtx/RE8KtaYVtae518lIFTyHmsZtOj22qA8JvL6Pa8CQF2fzNzLteCpbJEyd5YUZ+S8rPKrJ9UeizmUhdDgqfKRvPSDVhma
# DATA wtyJ8sfKUX94UAivS6VGo3rnFuiLsJAq5W05FhJK4u2bKxo6jJoE8ZMbz9AmIIiLrUrAdxKszjCz4jt05THEeDzWPfzOmG9wIyGz
# DATA BlbRMF5vFotXflGGudBnkCGN96KsKfEeSL6EyZc6nl7kiEo7dVLPq4xjiPE5Jr3BNFrwBLoYKazT+X9O9mnejggtFWmzAswZ7kWC
# DATA 2/3tfny98FY1egLGsf34RvGtAkPCtJoGekzzelEUrEHhyvXiD+ys1WCsqTwoVv06H81Zift8CHTyWJD6h8hXPmQp70MdGPkhYCy9
# DATA 9UF0+iEcmaAkg5jlD+N2f/JhN0boABhMY7mJLW+kzLLcYlR4pWl4vGGK7v1r+2FY9L4qOg4KEayhGPxlLbhVTQ1QcngqvePuqYQg
# DATA mdgwVA2iiAxBm1F4Sv1H9Cf8BD8xd/fwBWIDeAA5XT9DzMiaeFqSSC90ozf2Ip038Ef51FNbJeMQasoYFD7GpQq/8FbvpFhoTyfH
# DATA Yov/HFWJglAa1VqTiOtAEEA0/lAsZK9TBBrb3wVMmnG4v2zUbR6qbgshtyEqa1wTPOut/QOLOMXz3fraTn3vw+3V3d33tnbWP8R0
# DATA Lx/ysdl6S5ybH4oC6/XNvY3V+x+ubm/Qs9WHe+9s7Wz8zSqkRSq6lXJjajDFxt/uj/cHzRthON8AZgsVjf14f7d5/S3R6ixR5sMf
# DATA FMNSqnCQ1Y39g+j0r4xBmhBQad8PQpsGsuovACyPeL3Jf0UdNyrl5vXq4iJMXbz442rzRpU+NW/8ODGHP87u/ZPlg/1GY6n8VvN6
# DATA Iygviv/+uPx/SWtR4j0J6dU5bo/bHQiwRmAe9U3sJywJClLzIcRHTEKQ2wST0m/jZrq5EpCPo/XDK7VgeeX1LJFVCXTrfF0MOGdn
# DATA TFHf7XhCSO6VYO84UgpbS3VHmkrwHCGsdnSrqAAMH8uDtpZa3vzEVVh+pMy9E9INwxsAOSI7C4/k5zO+3PYBsXfSUo4oLfZTKWgL
# DATA /A4ZwYOT6QS8j4P7+Api0JegnwPBjibYYfCeICcB8bU9IeD5YNI+Mkzvo2Hc46uyjvYkkWen/mBzdQ1STu3Ut7d2N/a2dt6nvMCT
# DATA yUl7sKhQb8qqu679LBUbTdD5ovMdaFN1J59RfKd+v766W1fRntKsx04rBa14CmUiJnHSVY6EVDI9AJfaRWxx8alu+GxRegYt0lq8
# DATA pdw6Wui6UXvqeumfGU7whFMW156Gqx04h0AtAg4cEJAC+KiPBl1u/gZKtCXI3C7qLa+xgbAKAnm5A89CT4xu+FBQYXn1iPNi6yUw
# DATA 7xHhGb1pOH6y905BOXkYKTNACBtH8Wg4iKPEDZSfk0y0cvsOe5LAFVOtNRx/ojhYxXWJSy0gzryNZgIVm0RlHMMqty6gXl6GYsRW
# DATA wDFiNYzq0T5CpZam5ILTqijBRz/7ijhk/mi/K3i6/A/wyfaRE605ttvsjtuHYGvpxVgfptZMFBqJE12mprZKXmbgnNcBxgJe6FbY
# DATA Fz9jhiRLknhTTVkJUyDyz4o1KeLIxb/Ft8T0mDXPGMS79Z1dITUo5dsY792TqWDdhZP2CBBVuT4Jeg6ZvDRK0uC0AC8BnS7fev3W
# DATA Gzfv3HqdLBnwVJxEWOVl+sJzR126ERSWSkWxDwq3gjLuDqpXh81a7jTVTIuN/9rl9elGTfg4BVCYNX4cIIzbGbBzb1u7GHGlJapu
# DATA rmnY3YNEhExVLP8bu9dC5PcTTf7Na7bFE4518LSyJ8VclApKaeTnDx9urPOrKF7gx5w7668f1nf30vsVi0cj0w2lJSPmT8SpI79x
# DATA klsFBVyd4f3GDhAeJ7AFA3dbfLdNZGLMWbqn/Arxh5u7q2/XW9ure++EVo/y2TVl4YRVM+nVp+dMUZKeLAOalZ6h9thFw9Ll0wGx
# DATA DCJRVZVQTeVaMo2G1OfGUtNR+lGwKJrlzPTg6o0i8fXV7e0WXaVQrPZhfIGncy2gkTB8lqlPUooaa2xGCAXoIWyV69/qVmtwhTgE
# DATA hM+nd26dSU0DaxiSQ5KKAITJpTxABoAssxEqDXrXmyuZRPRgY3d3Y/OenAA+lUFLAZivJ+1OZRA95uoU/G8pYK/bknS/rsTHbSF5
# DATA oDTW7R2B6Ff0+I6l031JiO+kdK1S82cOiresCGiqYG7cYiKPAa+QIfXFJoIguxgrZPCGBBwE90AM1dYrB84riDrGjuyCkzAmYCF8
# DATA NOxPTyJwBG5YLoLKO7KBr5MqCj9B8iaqsXfoVa4UjC2AJZk5Ux4neCBlJARNRNevhAM2sJi8tSsFStKNW3ZWHuTVsCikkpVmsWlo
# DATA etQ2FKt3OoKLV3jQG5gQjwQIx8ymqAEfq8km2b26BXEC4ndgVWcLPu8F08sAjoqG7EjTF71p0Ts31Xqw9XBzDxp++/7G2p4nGRpX
# DATA 7xjucPWk3ku26qN0+2iRiMBGA3JKUO9uekmr/BRpCdRTXoQdxD59VZJLwacdXQTFqvS6CEfATpZVNOfOm/eJl44ThstKghA1sfz1
# DATA LAn4CoC7UbfFBykeDN3pySguSHt0MRXVggO2CzMwX0FJIK74QNiQqzgoEH9BvYF065ToFi4WrgNIkQS8jXugmDAxblUADAe/BOW7
# DATA aHo3hkbRFb5xoSMIRcTiS+bswE+o40h0CsA7oOnhoMyeCfsDfoawtDYcb36sCx/p6siLxYADNkocfO4ubSJ1pMYWSEJllAg/whBB
# DATA sl9XGBphuTwYPhYfuDdz1zSmmUqtQV4KECBFSLCgk5+cssBoSC6GBggAcAHzrA8c61TlPRW8EA+1NyXdQUxnuxtMADuGjtWoLY5s
# DATA nG6lA0oVMVXigfSDMyMNgSVqStn0hQRMia1JbXkYlY7L0NKjCfaaKZjJZzzj4hyITLkxS1zjjt1cCX5UswWgWnBr6Yd3FGb5sbYp
# DATA sG6UcIz3xwixg/ogcM8Pm8U/I7lJpmxIykjKRxM1UlUVk91q9cSObbVEF/qHZFs2I5bFw0o62aki+oqj3zDvOao5FLmwraQjvHGP
# DATA MOt0zz2jsvajiPudUE1Y05JVH7/rxCfokHXSl3aTfUaDds3ttWtx53zyjrd7T4Z2MfQsCAHgpU0RTmz4D5TdnEoJ1ip744efsAhv
# DATA c2uvtbEpLuL3wRtMNy3VRFRzI+TvHpiORAk9LeDQxQQj1ZTgBmDeh2fHiyncOXCm92WckhdMnFiinIQPQGaM2BV4Okn7QCCXRepv
# DATA 3ZAtMSVhBihxUr8x4mCgFEVcqC57K7cg/QgUz+e65Vd3uJOautsKITSF48OlccNc/JPPU/GyF8DpWPYqMB1bbohqkxq+iJqu0Zcl
# DATA udU1kKcTOVvpY+IIo9qi5XcNCXHIsQCqcByZXCcP+AdgcfnWBqpuCHEdQ7r8K8SrJOq044AwzFHM2TTCC5gMeKQLnhF/FJT1u2Yg
# DATA wRIoHl9fWUqJU4F3OO4NW6zJ+En2xagJCt2r7+w83N6zOJPqMo5M1EKw40KCqqp+AFK4mVjAJDwxFDOpAQ9X3TvQHnYEqpnQARif
# DATA HSDp75oKmLKMiyMOTqE1PzOOq2R4NTPRznF7kOSeqDNGAkBkDzIhgMK43SFMHC+HkT+iztRgnGnBXFly3fY6OAjcfbj7fsL/89QX
# DATA SEXew8lhVgDx8liIb72fR+YOpHEXfYvhq2Ud/6S5dKYPxHB1Jp9O8lE2N32LnA1pOYgzK1pSh9y8J5sOVVXBxfJ+IVGWjCuHkNmP
# DATA xu1ulONsT+fwyHC8nEoMDZUQ5vzTQIVEMXzc6vZixC2zoJYSA4EQQtlPZBfQIJHWSXsgquuSzQuJdeY4tlfv1VsPNu7toIsJDmdj
# DATA x+IJqXsAvqbsAPrppdI/e5PnPjlnbx5DHeiL4U6Jz0mevbWMs9f7smaZeHCrr+leXXOLHA6DkO3PHtglDiy7AufU+lHGqTXX+uc/
# DATA MZQjmyt/0UEBAXUUZq/XoWqyHmNxq1rY1vo6PStmLKIxJ67ezd6TnohtJ79GKsWmqFIIizETqZB1amWEeQMwQAPA0ITmOLKkbL8W
# DATA UrynQAy1aosqVD8w+tKD9hNQggENQAFXPYcv3QXlDyrlUttjkDo4VbTYV2LpFDJlRWNuHx70uqFktOIRiA7qPLG0S5ajh4/YCpfE
# DATA qrIIb4ZgJq6LO3stFUHE8lItGeq04Hf3VCdLTlHdU3AclvnmU24+vXnnbJ8L+qK65iDhlC1uDdgJNJHBUABQawsLsMiWrHBJAeHK
# DATA b4RzseZLH2LOoVyszrhgJo+xPHdHMvonQAxAP8JML00EtR6De6CjlpIxbYWcVFp0K2x1xhFHP6FEMptZUnQeIqHogD9jv0BuG3ZD
# DATA zLchktRt9wtYip8FNNQ1qMmoTuJ70SOQpEYY4qaRe7dmTp8+uRTct7GEhqhR9F/7rlh0VbOv5Vc5B7ovTZ8cciUS7wtJvld+j3gh
# DATA 8c13eCgx7EV4MjlGeSJcVdp4AmxtrN3f0GNLpl+lE1eqKhHXBnxCw2bGaqI/BFdMa5lWL+5JU7mgPjf9J6EjG12npC9+meAUHApg
# DATA grq9Qc14c73+7ubD+/fxF5AL5P6jfFPqq0+EeH15ackvg2ds67WtB9v363t48ttbOx89aGgZKU/oTOlzxlFdTsLpHZpM0E9OHCBP
# DATA MAGzp0iGy4vPUgS5lGCF+31ru8773StwMGcyQD2aHjygHHvMsrZME/rMTLW6H/vHc9FKARlB3eCdJTdxDeYDaJF2k8dJ6np7/ySB
# DATA 1xM6dxan7ErsqWljUsPaDGNvL2Z0dPuyAl1o6p10u2hkTEJwHq/SDVpMEhzg83SFGBTQrUAD9PSjtughwJkdjIePY0hOzFoLgJ4B
# DATA CphE/dOKn1umqUNSL/zpP+aysqQLbhZ5eCwxYrqMpa9mupFYu4hh69k7JYcWGbT5ctvUDEItZreJQ0Yron06JfM4TcdjjjyEd7RZ
# DATA cM4Q0WJatV5d8vXrnPMybD8Sg0c3h6p6iV3L2blGdUm73XDB5EVW4ZqJQi4ImyFj0aScmWa/jrz3QLIpN1SODMz3E9RGdmZM5Nhq
# DATA FXqDQeQLysXnGCfKcAfkKi0drV0bLuOAImB5KQlCbgHmuCA5MKE3PHKLV3R3EbZ1Px2cbdFaATGlYG5IuDB+37xbzNSKeQV2mYcM
# DATA Ghai1sZWipbJnr/M082aZovqPJ1K3m54LZ+gzwDWVQqut/wBrrqpuXvM7d/H+6V1oCktvfR1SN696ZcWuvKXjJu4jqVAR5NS6tX8
# DATA 8lrnFLXLLPbqN2TP0uVaGooX0mde0tKe1cHUzs1CF7zUAJRjE606uPPI1XYZdr6mwH1is/5efcdp6NVgaxApTF0UNH42FANt94Ef
# DATA x9PDw16nh45dENcnYxQhRAu0DjArbXGBO+7FCGqTCEU3gbpMjsfoCgqPUsIsVPPzMCZ2C6arAS5QBsplsVrGJ1x7MzUE/MWRvbIR
# DATA vnLeGVLqzVC6K89XujD5FOnS9VVr211/VmY9/jFdShGfKol8N+r3NFV3QiXvd4ApparhZ+rsvxvVvKmV/3NRweeSca9SIT/DeQkC
# DATA zq1Cc6nhMwn4qpTvht79Mhp3V2+ddqK/sN9ZLmzyDJ11b3A49GnmOaw0Cy5cRyIRAlDuOuLjOfXc8LtpQvBp12eQXPFKFOfYC9ae
# DATA zybhK1act/w2ekOtSVR2VM2pjkNNk1ax85RFXWK+rFbH3tinErqBAenXjJn2n98UpeZmjTZABLa29jgex+KiugQLYn+1ddc6J00c
# DATA Agxibm1svr3VeltscK4PKLuYGk/iqaC+ubfzvlkDErbjwOUsE53psEg6h8PCXPd/e3/aORgM4tMjN3NFnP+bTtxDuX0+vfgV5uX6
# DATA CL5aHgwp9yKZErCWATORS/FMym0hAED/yjIs3dGVq8qbGFFYg6jCPCE/MzXWSMusrsbPvrP2h2mqag0yoE2JSD8ppdEzvathAhrE
# DATA C9QG8SMhKXdoet1fOZjnSNF6eO1dmZhGL9NT9fGsyoltnsoKz1SIh3iFf/Nv4LP9wTUVApDeD19WaeNgSgwo+JG+CnnbLc7l6iM3
# DATA JlyQduqr6++H83RlrmvZJa5nloM9U4FaHM0qX6np1buko5MJ0uBpHdlUIsoGhAL1y6yb0aWbfzW4S1plaI9S7CIu/kn7FK5bmHGp
# DATA HQwiwI0fUZYYnWepsjBTO6vomSe05qcrqaKRpSQZKGEXq0tngy+JO/+zZsZWjjXIKleFXJ2QZ+7z868vfh3QSSp7Telg8vFdfYM5
# DATA aAvJqmQcXYYVUwI8+rmxaRz8rthyKj272xW2kH/Z5yJoxuZoPdjYfbC6t/ZO+CKrzImVYJH/9fx3yWypX2CmVEin90tKIRjOWNSZ
# DATA 17U8Js9Zop5jds0W8vxVp+p8qF1PtpOk0092KqLizOrd7DlO/gcjjY7rsDk7nU62f4HfMmAnGoGQODNHkbfXZyni8iUMO5naqJdq
# DATA BH8VUdL46kEYMhBEGKCGvRscnFKM6WjYG0wqwbaYBAgkDrZR0bI4iCZwyfbUysoGiE4dlvB+I9oIOsMR5DVTis5ur300GMaTXgdU
# DATA mJMhnS8dmRb9Uib7FHt8y4Swz68GNbbDTNPXpXlRgvzJt5lbJhwOfSjlCq9P4WnfpDI2mbRs4SrpOUHLqLimRcEA/N33d/fqD1rb
# DATA q2s/gYwp0rNJXAS3H+6FWSP15k019sAanjzb9jYYdIkAHCP967ezWsL5n5Wx1TimZMJWvvV6FVaXUu/xxLkBb04i9Mv5h+SSoOA6
# DATA JRXvJ71YTMKRDf6TUCmlllY5YAa9J7uIv1gwc1xW9o4pJeLRg96TjUHJSoBZwZeQV9GrMj0AAgO0JvhqbCpnQBsI1h7eca6LizgN
# DATA BhQNXgra3S7v93g6Er3CSBD1YtHzDqC38O20cDthk/TUreCjRN8LGHPPfaEp4fyhBX9a0aKZd4DY4YmoU1TDqs6EedXahIRIMOqf
# DATA ylgysQVKiCHmvHUw7J7auBpYSN04PfaIaNBtSVzBApRKK0RgioVwjSA0ywCIITNiSkBFj5LSU4EFsVhCiEVEWwjzNn0/GhxNpMQN
# DATA xiwYt+tviq/rt2Pf6B+jYZpEDKzDmvJjXLw0+jMD47OJyoQD0OIZ4TbkQZ73maIRVgBE0/Y4ajFaAPaGR8v4CCYoMUEkiP/cRUBi
# DATA vPlgC8V0yy6ee0h5t5ZugoAlzVvh21s7dzfW1+ub4VkOFa+8XchspOCjea++R962+AupmSFfLMkRYbY9XHdsBTDNaN7YF84fIpuj
# DATA fUpHEIPgUwgXQclNof2LqX62Wb1RWmyomqywTp3Nq+3pUZTaUYnOmNIferMp4Z0Ws3HBCT8RbocrLy+CLH1OsXlEP6dPS5efRiI4
# DATA juadvzcUSv6CrVvuyBQFeyna90Qe5+zZ9tbui3atjxxZUZjBhFqQwDHJuRvNTBLj+ghbWoV5Wrxtb9wexIfRuFyHw41iBVn9xm8L
# DATA yqj0YsEcexOtmlsKfgS3loIugypLGyT3yoiZcT4NBERaPTx3EPbT6Usx0x3DEGGhZokIh/MzYbzQV8AFAvFOMC6eccl2okc9VC+c
# DATA fddb1keY2NMXJE7cfIvtDsVT/tekypXbd/4LESWsmAfDQYeGvQza1Jya4/+hQw3ZlyaJ0VaskHyk+9XMT/YrlzobUomcxMLvyfs/
# DATA A3nbatzviLBNmk7YZq6CjtNlautycMu6HIDp7u2th5vr7uXgpapFrQ79kDx4lAIItpPpW0r6nlvinMpSI+kxXUKX5K6jMRfdYUvI
# DATA gwAPZ90xzd+BJ/gLkFpFOubQMiW95qGUQgQ0XlFQfUjCxnM/FqDzss/a6f6OXwuzw5YZU3B3a+0ndZPKzfosj1H0uDGVTxOpgCIX
# DATA nZJUwxDmOhaqequVQNd3TMcEVlThn9bhEJMFYYLVHvjDc3JNoKNWC6SYViuUWY/HMTpyiP2Hnyur46MpwBhu4y8q0xZYSFtCBuq0
# DATA WkXjTchP1mrzKwXt4ojOm9uoAWegYfwm7mfD0WRRuWxKy423MvOk7RwPAdm4RiDHKB5qp0kH2QBh0mXQqZiKskTCxLIytKSZOQwZ
# DATA B5lZiJTnxTfTfu+3D6J+xu9oZstuArxB0ytAtWnG74zem1GCcSm5ExzMymXxD5SW+icIVcXDNJr22Ma65KJL7qKbb/0J3MV3ppTv
# DATA htxKaG8r2GrIFQK0opMqiIYqdiisjgNaSDNv4Ftk3sCPYsL4E64Of8aV4M846xId3d8uUZCJMwnA+25THPyEn3mm+RvPanYjCeq0
# DATA IN1sCFe36VwN8I7Q1SK2pq6rWEGHVTlt2ZWZeyyjRo0/gQ/xa6+r18aHSk96abeq4sJffP/v+3/f//v+3/f/vv931f/+N2oFvjsA
# DATA UA8A
# END_REMNACUST_HELPERS_V1
REMNACUST_INSTALLER_PAYLOAD_V1
if [[ $EUID == 0 ]]; then
    bash "$directory/installer.sh" "$@"
else
    sudo bash "$directory/installer.sh" "$@"
fi
