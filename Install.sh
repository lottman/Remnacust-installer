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
HELPER_BUNDLE_SHA256='cb98a90023cd2b5283d0886102ef2e505583cf60811e0565b20a3b356619b379'
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
# DATA qLDWrDV6gL4773t/+PdB9r9RwP8N7v/ugnaWt/9BFfmD/f9vW//3M6wVEUx9dehiLglvUv4XSwclk8mSNI6qn45GVCON6ckPU7xH
# DATA 8L66v3w9p/oWz+fTVH25/FkyU5/xoptxMlRfk/R3Lw58tVwkY10fOJijn0J/jScz+zuXDMb8hJPdvTO89aLIYVbynh8fn+2fYHJG
# DATA 6Zvp9/2T/RdHu3uvTs8GX+wfvtw/OR182fgGmu0fPaM23/fh02Bdq92jvS+OT+hGc3LV4gmx+XCj/Omk8ufccvDZq6Nnh/uD0y92
# DATA gc3ulOxbQEo/2Kh4zw8O908xHaWU3+AlzvMUVRW/2W6JvNO86DdHTbAvLy4Ziw3f0YYs3R45Vp9yskS3tGxv5cK3LS9noJyeuwLh
# DATA zBp5vQ648lSrY4SWAkcJ/u5YxzQhS0LznZYrRomekBhwznfLlMLfxU+GH7XHqlTxXuz+ZHCy+xWWlu+6RTToES44PGvmHuVOlkVl
# DATA XGxV1xArc0dxCHCUnYoYEhmi5+qKkyFfblIlAtdl6uS2EqtTeVe2bU2O+FIDzKhWl+XK+yK9B69jddvytre2KF2Jak2p/5Q/3d60
# DATA Tj/g9/Pa5oX9U+XjyqclFSO994yD3F8gzEug0sWZMF9/gDckxOo6D0nUxLDPgq6OLJc21SEayr0YJXxEbLGcwebFGuMYWsEIr5Re
# DATA xHpESQbowHqOXDmm3OA6RRXvvuoD6uymgUaV7qyVdNfOOjIMeCdNwkfH5vYreOsv4nqYpuOy6RR+tWaiS2UDqdCmE3SyRNixCYwf
# DATA q1XkHRpiSlOZeWTF/5HfuG8xnumb+WQ5Rmm6iOfmjJLwWiw6MnXCbPS1Ku19OU8uU5XB82UPuW0tnkacvQNs+cEc4wNzO1MRhGqh
# DATA SBwmU3l4vr2Jp3qw/wsGCZ8XlVBGsMr40M4qQpHxbPds1y9JBUV7Y+DDvd29L/Z9Ww7QBlHfW8072gvYb6XymJP1r6bxmxnfG+LM
# DATA 0perisx64LxYZOlKOUwElFl471q/kAsZjY4hYwXTEBQIlx/xcs7x8vBZmdmQ/wnzI6FPBbFDo/J2DkKLlCvndVmS8nCjtFE5b1xo
# DATA tkjFoTS70wkt9wwAAgW6KRbTGwRvvQTcudvGzzBc1d5Vpk5yoKqnTII3yWQ52VFM3nDIBwtu5o+Wr+L/C8Y2nXbAimGYk7IcB3Oq
# DATA 6WDO+FuHzpEaeYB0ButeAuKr+EGGzeJgYsaiK/B25Gc6hVCWmUCfDYd2SDgAV5Dnj4CXap0t0tQfY6aNSyV5WaevW+A6GeV5YF2y
# DATA gMPjDzB6q9nr9h+DK+loZXyZsXXODXvWx51jEZO4J96W2IqlO7RF2FSxir8Jw5V0rY47uq4UXj1Xb108uK9eTbPlbEbZqGpHKbhL
# DATA lX99CcvQqZlcfHtZWwyVo92q0RxkfdCQLLTownG32gt3zFh3SvZYpafoqao8JfsN15YUbn2qkEuiqKOd8g1p7H4w83KFrahSxXNT
# DATA 5ZQKwKdyVtLGipGIq2dOiG5ewBrDT7PbvwQNv/KXonT+JWuc34DKWZGjo48Qhw52ESiqmbMiay0scrEKjUREGaktsjn0DiDnEu+A
# DATA h+kCezDVYz4UbpUz68KNyUll7phhwZzsTM4dLhRcdf+HvtMI6UAx7A+EAwvlmd2QLSfu8I4OyASg6nYghYmV8Ag+xrS1joviVrBk
# DATA EVeKl4QyYGtVKUsmZRMdOfgWV3+bRRidntfVmfi0ji5yRmfL5QDP22KzRy4bk7TH1So99hkgh8PrbXynLA25r64sSiJNwq5cJOzb
# DATA 6UVX/GWrhSQF1ily1Qziz9wiryBQ8yJ+dT8fcB0uiCeHIfhRykXUcB+UHBEjrOajHS1wNCbuP8+8qu3xxeJrWI/T8yoL0pdf2uKY
# DATA WvORlcpKvXm5/xIhd+ndQu5Km+JKUetJXl3NOMH7SgF31kWna4hfX7e3QjbAvsx5Dpn6PURmikfrlwqSb1c6wE1kvQKbQPmiqqyx
# DATA VKr2BrWa0uiVfHEMKYVoYFhT/8wc6ZaVxD368ccycwXDNo5xt7r8+hyiC7pz/E5Spjm9nha7bNGKWutKvr2qAtdFUEXrnwzjKMpp
# DATA /ZZSnbMb5cx4znbMV+C7x4isgv4KNoJt0YkxjING5OAr8T2XaG6d97YvCgxCxwikbbDe5HOUIzWMKBfyFZl/d11x1fVCR+GuQPr8
# DATA LJGT+OyprQ27bbGKZMiqJlcrX5fsA3Tg1j6H/+DxZdr36fCnO0la+wzX+eC4zH1XCi0HIKmc4aBcX3nDQTT3R8i8fXea2YrYUyqg
# DATA nFmmWYhrmA2dgkng8Hy6YKc032YzSDKwDSwTxDC5glTFQaBi+bG8wgblAemKrYe42hnMAcTVbX4Rs5wjgjslEcndF7oc+BmYjVLp
# DATA V79Yk9K92stonijRy9jDGiNPSmacmq488s03+Z8f54HAa8ZXSFTwWMqfdEHhYo1wYaE8fkO+epoZN6kwZakbOm4G2qzbEa1qls7K
# DATA is9V1nF3/ZrD5tVVTavPtUo1jeJ5kUwJAxBSdjW8h0RKulzMlnRuwBBm5QEa5ncU6d6sodxCGSAnHB8SBXmv1nSU8kEjAuYsmB/A
# DATA L+VVfQ4bEr1V+SNCqD5ixMLfcbSFqg+CoN2GP0XHcjC7n5Yc36/aCHKli8W3Nafj38rEyNAqm8dZVma84QYmlRsrKhBUO3VdUVuE
# DATA BgsKXbUNF/Uh++xB1x318qFWDb3k5+wxAfMTjkSx55AKomDjmkxdub60iy3/pog4I6bwRl5G5XkC9P1mm/6LXLtev1DdsP1CD/AI
# DATA VDC9jNE7bkuyKr7g1pO0pDl0pKDAIJrS07h+OUe5xE6h9vZeWuet1o5qZdqZWxZ0wQrtoXyiP9XQgcAFNlh/qWh2QrE7sX+ct0sF
# DATA Gpwik5wBo90pqO/qnr7cPzk9OD5SA3Nljxr7RB/j6pNepZAYRzPUbwVmhZaLOaPOsuY+yIRzMcF3Bz3GiHsMK7TdxPZTRSJ4szZV
# DATA 2lDnmZwqoGsW2CEcIkNTVsVZ9e8aU+RwEsTI+j2WTGx7V7siMaHGeCO3Vad5t+T2WlPXrXmsCw0LPt6WVjrQTFxsvW2Ht9/dK4Ac
# DATA 11fl7s7aeGXrtgecZJXewRCjutcJ2c90sdPUl7orniflkFdcAGr9H+nit9wFumft7bdsEj61bRlA1rP7WUfFeY3gVDdCUmu1Rdhf
# DATA ILJjwGyRpZjy2RheJb6FNfxJkbdlbKrONZoeYf7SjWxc5mheNlBZd7xRnPmbN/U6R7pMmzV1gB4pAs1JNXVxku6XTeB7rv4STQns
# DATA 405HTvcpA9d0A4iz1t17qDDOyglw07gopLO2/uKj0XAZT2N12Y2Xu3V11eegD1Lf625Q5SddT4M6A6jP/dmHAQvOAHIJrpegYsXz
# DATA ay60FQWYERJZQNd8qRTnU+JIBrv0Vq66oXqYud4kSQl32FNfchjoCgaAF3RdWKoRFdFcmBwmQyK1gvJF+bUu2z7B++vHib63nhRi
# DATA zDUKiMNQOTCVhISUiZ8xLD9K3uyUamLgbWIUJJnvWBuosp6yfkdnjq45buAUeeQwIcW3H/OeduK022573dRU+1db7t7SCWmmz96r
# DATA HoqLdghtCmmi3RPjh8KbmulJjTLTlNPoLX2r7e//5OAUtoR8AxG+/+Ll2dd395RYWXnyfX93SnctWcFvvL5pthyOk+yKtkGGst7s
# DATA AXW/6FWSFXQ3m6chWCl4GJ/Khyxgy8RLYAp8pZ+vgksqsQOLP0iaXtHsfxdmdD9DAkpRx90LeBPXQyHcF10Q/a/LqgrrY+DkNR2u
# DATA L5DgNMujyTyR2yvMPSof2ZzE+l0hV7+J9OxUljHb/9E4Fx+K8u4BaSALlUy7gkownBxZm08W89jaTLavwVU91noyhEhowzuvOx5c
# DATA O02JXtDhejAtK7+XwgPpTNGaXToArQOqp4YxglJV610PFAzI1zC4tzFh6dGtJfj76OZIUx8GDy/IavMHShuoagYakVQtghBoyJKs
# DATA LV13QNTocfGrjHPrXceYX+nELnjAJQuU1ktNJU3IMtB01QPWV/mLpREzSKwWVx4uhMG0+b/IGYN86u13n//faHSavZX8/0b3D/n/
# DATA 38W/jY2NkxgrVPnZckYX1sSRVRmZc7illnWATgFMCI2gcYjKxmg5tu+mvSfdn9L1PyBJfzkUfUb/cqs/os/V8072Xx6fHpwdnxxQ
# DATA pjsfSJISMOhvuLwK57UkfTJOFwsw6Z+YC2x1mZiVn/LXNq3vY7WyjNNfweN83+MUNLAiqPIPCm5x4c64zM39c1WVcFZ/yQ9Dv0PP
# DATA dx7fuEhItfB5tVjMsu0nTy5BF1kO0SuuhzvJTeLOmawB81FdMBx33sGL3c+x/mDuHIT4kbbP65tbweaIk38q3rP93WeHB0eYA08x
# DATA XBVomaVZQtWU9K0JJvuv9Mcl51q5lWiwuexa8qX/uETBX1UIPd9qLs22dTMFBuywYDzAktxl3lKYTp4uKONi9aYXXcLHuteIXkNw
# DATA +X0rnKDTtDEKhA+5YORBxDc15uMOCq9W9MF0QWqo1SPfXcBwPnATjnPjatkC5AQW4Sy4zEwF0U9Wnj8ja9o08VbvUbTeeOT1DOn8
# DATA kgJf5lqJGnciF1latYdv0Ht6DlOQYm0j975BLvZo0xLVqLNZ0LlexJWCrOhrl8sbnC4c5Z63I8/A3PkoW9HqvHJhLygAni+2fHlJ
# DATA Rd9kpISd0nngrVnSQS7eDOaexbucP4VkBJoOaJaS1YQj0ZXB1qz8YJylTO1kgWbiEoPfkyCLs1qu193rFOzBIHuNPT+j4oPoueEO
# DATA 8OwZvQcd+T/FDGX+PcKO4/HI7ax4BQvnxgn0Lj7kaQH2LgqKa6kKltbGwdR6PAmThIsaijl0N+OVz5WK7Rkb69ifoqztNTeAFq59
# DATA 0a2fa+E5N18u3Ggav6SO8BDayx+jElwlMT1gVTiX24daL9/60KojnJrhOreS6183SUrXJilMF+MEZesSHNXVD3f8et6Re8alLZXL
# DATA gJieaKegaQQRJdGAcg/ae2TukiHHx46lNdTmy2n5XApaYpE+nN5FlVPAxKkbBrMFXgAt0+UfMVKiPjIoOxNQ91v1qgG84mShqBGz
# DATA RQStKQ+n/fhEHKF6WBJYY3iGDqo4yvScx8kkWbi5mVaGeX5sAMlaQV4St42s+hD5PthGnDuqbt7j+7b4klEnNCvNODJrpnObxOOI
# DATA j0LhbQTw5ja/zzFfGQtrEQ5YaimTPqHy9UJ6JVVnMeDCirqQuZMipZaaZdHK5XOX83RJ9yeomcEQ9pV/6kV9d7aMDaYj5j3mL5B5
# DATA +7ZGtHeHicUfU+cuOM6K6N7dCw/LVulFrvEpZXVfx/FMgMPLD4CZqn1Dv1m6TH4TIWab9RVcOChWxGkNadnWktCYuUcVyO9sveDE
# DATA De/L5Nb9MQN8MD/hpdxHYFVVV10gJ0nYR2jfFptfOU79VGXH7XRoDcv6S3zde6TtNHQU0kWqER7UY31qIlp+qWJdoK45OQKA67r9
# DATA IORRDmxNimoAQ5O6d5czU7pd0XHDAhm00vu4eLepSqcL4Jxhbu+5DM8akg7zoc1+H4vTeWpiTOLch+lySpam44mUBo7eW7CxzfCW
# DATA FsyHjfG+ORCE96CUN/NafCodY0dyikaOPlx1dMLpByv2ym+c39U/2tGbfruoJOeJlpmCImA8uHmi7fXCkT2xO2A3I+uP53PX2zuE
# DATA dq/vDUe6ZkABF3/wEvTv+1q8jeB9RNkmRiTYlonicYw27VPgKT4V4a0qdjgDIqTUQald7+p6K6s7n1AdXr00lZzOxkv6yY7feFyQ
# DATA 0tIjTvXHorClLA+rKWZNZNZhuhzz9XnohB/fKsU2WaxbHO5vVNrDRQWQ3wrsd7Z3RpvKQgxPdfVgujVdMdgcpZQq38a1/sFFeG2T
# DATA 6EMK+rLswbgmX8W0oyzXNe2R1VrleVkBtl5XNuQDvmwlqd2yuOISVne10ReS2f/rOYd1kYbf4xgP1H9p9hot1/9b73V6f6j/+l35
# DATA f7+UqKrOBxTOIRd5sdNVbH9UWMBCZwZ3n783V7flXvdv1X8JdthLMLnfrPEGW75fqddi15/gg86ktspZLvY67OTLUFiJ0XzvGmm6
# DATA 9x9kpsSkq+X0NfneFsATx8FkGAXbzhEFy9qrYI2MfISWIVKKIPXnHjni5wUVMlTIm0NVi+AS+FEGto9SfuTyZpqPiZJZ6eyWlk8N
# DATA nqjCLHwZyKqiP4bFLXxP88dNdlKs78LKZpWrNTnJkCsC0AkC57FQHj+HOd6nTr77L+9+ybW9VSHvf4A/v33/8/d//e6fhTI33/3m
# DATA 3d/jFfbv/gkLgetKHgJ/Zh30y11BLZd/2mfqzDM5n/qIMvN3D86Aao3LDKj0OBYg/80DM6DEadJO3wbnJUrrvtj2AyLSAAmUSYPn
# DATA xJ/NRUKBLAVdwck3CS1nuMCgHJir+iwhKDnRUwtxq+lBswQdb0gz54wP955yHIV/JmeE4M7xYXLAlmDTp8HpQplkamdBp3O7Jd7o
# DATA kCyshvLDg2cB3/1fCq9cz52w/pv3f0MkhZXc4ROWf3//N1QT/v1/gsf/SOXn/xle+hc+MlhQQF+IxQKRjiGgJQDMTd0pywQUTKJu
# DATA GwknmE/gw92DMP8XLDz/GyTyd38PVIOw/IbL4mNZeqAUqzA91rt/988wlZ/D979dCy+RDEBYNZEFgv08B/dFcUaYXHc2sgJLb/Uo
# DATA d5tvYRPfbYI9snyz+RY7vKsB565d/qyUS8eaKRfG6J4gltXz9luGUhf+u1CD8TClFSvGhA3o4jxaAnUyyXrIxoRzvvcxWZY2N4KF
# DATA gGX41bt/ef93Bbv4F6VK0bmrNXeuPxIdfyzRsBJfzZ4/EW+mpy/cZAfGh06NGe0v3v0jfPnl+7/28Q9+ADKD2d3Lsx5/7MWF2FQB
# DATA wNvSiisAqFjg2k7oo4qEffCsYUv9nU977dc0Ub4dgn+Guf/83b/A//3iEWv9P9h72+44kutMUJ/xK5LUHGclu6oA8K2lIosaNInu
# DATA hkUCHABUdwuEaxJVCaDEQlWpsoogBOEc2bLX42Pt2DO7H2b3nNlZn92ve47cluy2pJbO2V9A/oX5JRv3JSJuREZmFUB2y7OWxtNE
# DATA ZUbGe9x74748F0kxJndB+o19I5dMzWvsjRJcPfE8BKyl50TT965b+4U6AMvMPvPl3uh0CBR9GY/EcuEw4Oc0MweT0am6EnX0J53Z
# DATA ZMDklLrwnjkl4iuSTqicnn0gMDjPZQHZixFi5Ii/YEL8k9f/qP7+T6+/jNQM/xLTj/wCs4DATvzN6y+ij/rTj2cHfgB3uZ5SjIFi
# DATA XBGRK5EIDlhkj14jgoMGU7tx49aVzgtvBhjATyo2CYuAWiDR4SpqTbvTotjnJPQBkpe0fImvQmZcEvmtjFNrBT8KjPK/IUP8BS8S
# DATA 5VThHCiRWig6I+rMRFiroocR1eqGUuju7knRa983ohJrapdwpj34zSlw+YBBwrdaQR7a07LQPo5dS04gnPDGRdaw76zH+Y0b+NKJ
# DATA iuGOGKkEM7Ci4GHeaUHEi4eRfVeFifXGcOhaeucFjyQ0gVuy5W5QDWyBFi3ODlWjf5gC8sYYoGmcciuql1p8qragm9BF8Y0zAkJh
# DATA oMlzXuxzflDz2ShncoHSQFy5t/62KMIo+irPjEMrSDZTxUGKg/1IKX9+KrDJcFRz3AEcqZPH5MidC9UCerdCNUWpNDDq/4y9/lM1
# DATA kL8B8UHJd0XRUz36XJGVnyIf+sKbEhBf1Vdv/lIcRXjoXI2Q3hjYxf7hWYfjZBloTO6ZfuBqLUa1CIrJzsdrDVUoRPeE4P25Wkki
# DATA 7YrIx2WBy9TBeNJS8uM7DrNH6wX6XMxOaicU624ys4py3yrjBeW7+PXnwcGrccNa/QeUK34TQaYtIJnqwW9f/7OQG4BG5Y6dc8GA
# DATA fhbNHZ1KTUTGF1klOJr38056kI8Gsyk7o8fNJrpH4VsAusxLYvk1D60ZCAEMCxA4ARpUYHEBTF1oUIhUu0PNF4ufv8Pt/7MoOLG/
# DATA jIPj0iPIF2oaeNvnwMQg/5g6Sn8FGdDoOF2qcWwRdNZejDvY58iJIgRNEBudhJenlcUZ/fVoUtzlhY81bEPQD6F85hXRcCqaI9zq
# DATA so45ucYdLZ47XbqoB8oBhNF3F1OF9pjk0PVsf/8Shw8JjJFTgBr+ApjD63+AgyYoqKG5X8KNBo+lFmFKLzTE4JA6luFMiIHZdNqF
# DATA NZUVBde1pJ6rLy/fZ/5cjfofiMG++Z/U31/MWWkL6SS6LFE0tFOluBV46lcdIibVnIKr6Lva/DX+L7CscCdTy/rnpJmhQ3sFboNj
# DATA kzKU0HvaEGViji77ZJtyjf8Fe6/kod+MHg6UxNbvWiMoaLBzdKGjtpjJ3rPOED2nlJHpWT1Mou5gMDolHaA/cXU9lea2v298Utl1
# DATA dXX/wrHl677bE2ke4YZDbwW+KHDLC7gzYVbGf8DT9k9wusqOnhbUwBOi7bS8VFiXc1+EJneKNUf4VFLCKDfvtnKW0PHQ6Kf6DF2E
# DATA lzVPX2a9Gin33RW9fv36Q+gRro0657N0gJS+x/cU9pIfatvG9DgFjQVHt5HjoqWuYDxxeYIBn+JcrxaPqCgL4PHXTgrlUC96GIxS
# DATA 9OMKrBcrVRRe/0GqMO5TMO3vtSU0UqXUoVG68Af6eViBkwj4t95SyWDzkcpT94+YCxU0kurILaCgKhNYLgMQVcqKSv1DwEwkVhxs
# DATA Ba4UU6zHnhYrblTAPPmJ490WLe53zFJTxLHStDX3WjdRSVCLDwajA0qEQFefEg8YYpALwk55M3FZxtmexzhdWaUAjsWVLoUFTNi0
# DATA WowzrIEfXFpU+72Iab7AQvd3fwjMDKzd0sTIk1tz5SDK5ZDLHMU5AsolhJOvN4M3+d44UbRa84gnBRWYpFUkxDbHDy9GPvsuw2un
# DATA 6VG1z5AxiC5Wn9Wxx7+PXOSuuq2qpPaDW2xYqOpctLD2Db1qGnQd8Evfk7Y5sEmExpkWyfU/oCrItB30S9ZqXrFkhP8HocPmWSEf
# DATA O/cKjorpVCsMjuKnUC8o1cPJ2MmhTyASsVq/ojo/Rzv/lttBO+S67WlluT9xWj0ZmLeQ26c/M/r0FpmLp0bED2F3GYpU4L1+3UQD
# DATA SmtmUZycJPvD5sEMUFtKqs+z0nr0Tc2fGXOF1RNTqDqUz15D2NQloCF5h5YAijB7xTbxRBV7ShsFUJHw+2SO9y4xo52zXN1o1l+p
# DATA +93qFX0OnWxGvw//PyUuvn/L8/9bXbn9h/zvX5v/3+4kHeZ0KNWFlnJgKUYG8T85xziANiGbqBusDfZWdAok59FsSmURV0QVAZ/x
# DATA dJAvnvqtOxqfvX1St/6R6rz5NU2ni0eS61RvkwGI3IQ84z4DN2awzGJ/+BmOKLLlUM1Sh79mQ/zbTSEHB5nysgwVo5xCYBUcdrxF
# DATA d1CXpmQtiwbDsDGKVOuhUso2MSov2xmQHvzDjG3AExjO3RaZ6T9RNEDHKijuDaujZMkuKK+iJ4Y8kMxr6aDViaxFvX56NBwpwbpL
# DATA Og8lOyPszHQU5cejU7NRkMjhRkFpdsY9oQAy3DFs+1Yfk+UJX9Wj0Zh2pxOTyACOOIWU40veZXQSHFf9QN+0rftnkzINmZeVKHP+
# DATA bCyiVQBvkT9l75F/BkOem+pEj4yyIcxN3lPswf+tLgv/DBq2QkNoAgQ3FdetLZjWR6cT0nBHNmbZ7Y+ZJjhiiCjZKegxbr5dryvt
# DATA Y9Y+Cm4VpM/+0ne7UNex179znSugzwYqVt3App0UASyk1zAfCJOXT24ym7yvA5uzZt2H65GNbWCcYzFB5JqhPkZI83Ta3OlsPNl6
# DATA tF4jpONpB95Zn1ko+EfRykixxXJoenBq468VaYGb9wjvtpn6tciO+d/xlvpzNY/qSkr3zl+hj81vQYf0O7Avw7Koa+iv1cwW7uS/
# DATA efNTsr/D7fufyA8RDfa/fvMfYxcIssNzzVdVnm3HySKGR3HL7keAA6VYkFZE8M8x6lX5Z/RjmJ7VVUzQ+FLdtUCty7OhHuAVk+Am
# DATA 9FP1208CEu5Xy+pS1YTmXXUE+twplOuGU4gH9wCyZ6BTEa6ymXqC2t4alw9DYXNWAdgjhyNQq2uikzOJK8iP2JCrQOT9tPN487vu
# DATA fjK6U1Nke/2jYhHz9tHGdsXbna2HXv2lGtfFCSRsO6RKP4dN9yu5JclGLjZl2JGwon9EveQjOlXvv08GjtLDc4mB/Z3a76Tc+Xsc
# DATA 0i+jN39ORA1ccqsHpI4Ten//I/vv6omAjxSlQ3szKJB+BR686hG5vNVEA3dXlADhtfJFBPk7jJNHOh4PzjoutaN/IC4LL/IOO9WX
# DATA FCzSKskbgnLECHRIo5wsDVR+j87xfh2eb3W2H21tPv5MnVX8pbbX+sPdrW3zYHPrw63Hj7c+YTBVeQnl86GKHeLpsG06Vsaac+bF
# DATA UUdNpOkUk4j9eqSfEHXYd3Z4kSBri5epiEmSqIiIUjjN1GVp7hfkJYiuPr9mdwPYFUCA2dcJSC8VFzKE41aLKxrWXhToXWhWYcoJ
# DATA m8++tcPVE0AIDtgWefT787EUxFVUlXcHSrp0WuYYHnOlYH9FofkAgbbT70kQ90J0QVGvJnYTGRYpHTCpXrIeN8N1OzNpo72hjXSI
# DATA 7lzeCjOGBsMza0vrMur7yIpQ19I6mSeqiiaUUslGU7ig5OaTwiBzgIOu8RgAgDbgM+JIdMFRkGOV01tmwl6vVIdD3RIjWSpUrV4V
# DATA 6lbPZOXOYuoz56lOF5Bo/rOikH+PEiC6Duq24XMtMBZ3SSLlO3vj8MeI82w7aWea7bAQTQNTU5hDE0IEJWhTzYYa67UXGwqUeRFI
# DATA ZEwxPxeR55RQhlTiS7JGRIoxgQ3h1+RAbc0myFXQdf8f0MEQfQlR9MZYkqLIXKce1sEZlv+KAaWZ5C58sheDvmCHHxq3VMZc7hyr
# DATA a6G+xZl4WiAVLtcRntpcWM19UpCB8R0+VPdswL3gezd9hFa01jLloKEnFHSkPenh4uPeFFUFTegi2h/VtFMXK9rlb2ZqFrSVGn6P
# DATA 1WX5dDTpmd/qJjF/5f7WxlP8qVSeuKYuZBxfwooqceDPyAOeGMRPkCP8JsKFVIIIxy2BqP7mL9Hk9M/lF1ADMmZVFrUa9B1j9fQy
# DATA 1Xl4sBfgrx/OMkB6hT8PJ+nRiU2j4oALlS0F4xVpnDRVgL1SNFYMBkh2suHLGqhkOXm3BKh5kZ3xU1N1KCotnarOQ2TaJP6T2nda
# DATA 2StYkb3o+XT/veQ7sA9sqI2qkaNn4PWNdvPGv4klGYV02RkouWtcK6EEgRTVfOLRVXhBgHWQJMCUp5DRqNOC7gMNaZutqCs7HKRH
# DATA eRurrLAncP3wj86ErBMhY3aV94oN8CsHald9zhM+noxenZH6m/rhHNJ69KI/7LXjbtrrncVW72Lmtvad+9dEWtFmYz9xJ5eqo/mt
# DATA fadQli2coGsEjyaUR1nWNDSk5idwH46GiJamP1xy0bBAgpgN7TIMQ+vAw+MlMJO/IZ3CdK/0X+jYDjU/EAmHXEwt3jIwaxT6eNQf
# DATA Oj7v+tDxDoFJOUn+pPY8v4Ho9xM03z7P30tqe39yT+3V2r2kAB0pvCFoPJzMEP9RZwkXgKaOHt1EzD36+9Y+7biQBUmJYsgNV4TD
# DATA 6lACsvi5zXEfCqQYAEkAnwrCeygCBpI9njLdEQn4poOoKE4d90V1Bm9z8XlMkahUCTziv3VN57qmYjYcN7gK8D0OKchK9oS+Dzic
# DATA DJG/84RSFXjezlGPhlW5sd7Y8/eMh0UTNw00kEQN/+GFd7nFedR4bpitvbh3ZHbB3NEm8k6dz3n+DpgK3C6BQ/wCBYhfgqyAQsKX
# DATA eM38BT35HKSJ36GvwudKovgb9fQ3yHQmGcRIZERB7slLDF5k4BJDoRqoUDJv3vx1XA5GZ9JtAqBOPRJqmYKcRizJKIatEg4IYNvq
# DATA k8yRVI9ZwoTKTW6hQsryQn6fonIUWZnRx2H3ZJV7qq19RE81mqxCZjHMBa7TzGMT2HwhARX8VX7+ObbohDRenmLW6D3ef//98gYQ
# DATA iP1Crojqvc6s2evrCBCzHkw9WnKuA6u2FJ4Vc09kJqYbGr5E2DGwj6MgWbfZOGwivBn7QGIJkprhQw7rReDQKpmyCFFm6tyjvxxY
# DATA 1z2711DbazsENwL8QGs9PFgxZiqEK4aTTByMYDc92UVLPtokgsJPfzIa4o2YZlTdG6aUjTsPSEQlYQ48TyDgqc/NxO9pAR6WBH3B
# DATA hO5FEzu+zGiTkOyRP/36RSzcCnApUctZWFbqC8hr0BWblWffDXFZTMoTRxvAOaj7rPvEdgNZG7CQPqFWrveuzYEvvxntHmeK4+bT
# DATA SO86OE3pbHo8mvTVqeu/zDjwcJidQqfusThL2YTI7jUGQNbpaFTMuXGozVP9YVkXUJMy6R8h/mrbPV64IEKLbgL7aN3rgq75XiCB
# DATA 8QPjxU7sNVb3CTBVC8FlAjUJnkaKVi3qrgYlZcd5I0hnxF3A1nSummnRul24wIR2+cu3qCR/bnf4mz2n/D46pUO1+pCCTQB7BQSd
# DATA 8QPNQzcPukAfjfkgEcieYpg/ULu+gUGoVkPCj1EAZKhAfqQOhxdMaiuxJ6jO7u3iTEFzh3Gdk23pXmqKA75ecBx50mkweKfngcAY
# DATA o7ZjGMaOJcJJ3fU3YmNyDYrqsbK/WXwjtq74Gmywr2ShyXg0YG8wfKYWoIF28Bm7FzrAnFL3or3iA6iHe5wgXKsl6tENoWsB1Xi/
# DATA i8Znxkdx36Pj7o4mk1hg32sTSWeR/EoHcBqrpLf7RmWEaHjGvb+CimtoN63E1K5MEJ2MCyb0MfCpgBPQ7expj9+D0WhQk1hx/DcN
# DATA emdKq2AIByfc0rMNWwWFGiTerUg3j5+10I1DyTPZGP6o0TaStjwdmmysee4H9Nrf5xPuQssMxg445xHnF0LWgE4CMWQBGn5arE5N
# DATA XWlv8Lb+0BcDPWkGeX/hZIEMYOWchT9hktDgtptnJ4O42L9aRQWY9rE5fQWHgYzQOG50lPVLJIWcsxUeDoFxFKy1MJ1Gb5CBi0pR
# DATA Za+1aa7yvg7uKJ2TTPFK/QCs6Sijyt/AVPh3f4ggofIROaspTjHJTtPBQN4yjRLPSi/kyVTTb2xOvrMxhufJqgxngDMCPKRGmVCd
# DATA Qnzr1Krga+3FNdT/h7pv/Qos5G/+ku08v3TuVebOZNqCWxnq7VQpUOW52ApgnKcbFsTB/7X1KbHT7Ij6aBANdB1zVdlPjAoeNKZA
# DATA brXkgrR7MJr1DgcpwjTGR10418mCPjK/IPQiVGYCQI5Bvfot2sL+Ptp9vFMyKLX/R5Oe0USzSWcBq5HVwOudtvCU2C/MjADkfD7N
# DATA UjRMgKDfSwfqy7ebgZ+QgwWocP8ULt1wK/fHr71HTJdcuwH0eUe9e6LdzE0/k7C9jAYJo19wgIuND67/n7O6+suq0X1eVEn//M1f
# DATA +KNGlT2efXGi4WfN0AmztPTDv9gG5ugpJdS6ffsW87RXk/Qs2IgkPiRcyt9zmtqgwtzat2xz89YCzZl25vEFBOKcuxNAZpd03McW
# DATA QHixs1W3Y7pAQ9Kt+cv338iU8Oavo7WnG3VnsQB2gnEofh59qmouuC5Y5Al2XeAFzI/TCWlP51hr2VkjZHlFQuzIMwFjGdRKFkOs
# DATA SZQSOV8xWspnqH55LW6L0lYCt9QEB1awMVuBzA6ghb5hJJ+MBjAZNWOxcoxSdvTEtBivypqmFrB6Gw/C4FQueb7y1nQmJkBW+myC
# DATA QOF7sRr73sr+5fpSaE3OMqzVIxpmsS5eSbLbwfHgkonrNakm02XGFXNSNUBB3GiB3GnZK36x70xGdacMT5l/Bv+LxXsJK2UrLbfN
# DATA 6PXfIVX9S/Qx+TmYB3+JxSlYjszi2qoIeIFf4qf0nLnSz/nhrwyADk2JJ0+ph6ivhJe0TLGeBSuEtc1suAKJ4bwOTw4F2hWn6P/B
# DATA 2Lo/k1NDHliIlmNdEskKKkjRQdp9MRsL/wV6QC4UfOIaDkzinIy+9D0njta5ocEjSyaRtipQvDWhhE5+jgjTqrUCSMVaUnyJ1dSp
# DATA J+q/4ORI279l5eqSNOsXmOQLRCXzky5DLXV9VT/GxwCw2lJ/kOSOmHg0EO4W/UguBIJrhfTrsq+giCVTIRAoecfya5+rV3Nrz5HC
# DATA EXqSAt8kxba1F6r7vNOyEC601+2cKvqHoTFca3t1e8FfeDWDlx/yHMaeWaBYp7ggu1XTsmSHh4odgaaxza4nDgW9FqaCnGyiyF9x
# DATA lOem0w4L0zszDqa6k04fGlhBaFtcFYvagl4JgY7maVtUWTY3o1q96i78EIqR9t+zzewxygXrLIKaLjOVCWNGc+U6pKDYpk678grK
# DATA 4B5skH23GvKWRjNPAKR6WRov1djbDWZQJepRRxymw0mWH9d00Knpfd2XZ+oVVgF/rUxIN7lUdYgmtd2LtZ7ucJU4Otj8ptuB1wJV
# DATA CEGFF++h/RKsqgTv3B8282zK+QBqMWeSIG2eC3yBNn1An8CPW+Hs7/iSThA9ixPP7IMlHLMPfWOSAoKfCznGxKY5h4UW0m/jHll+
# DATA mU6WB/0DiwC7rJhqvLir8v9lLleGYRJ068/IE/XvKTzExKkbn1NfY6Eu6UrS+K/y9kaCxS8xtl3KLJ9rJyT13/8oAaNwjrV+7jwG
# DATA ZQwQmYM+pm+IOTUfcSR7JtVp72YTSBCoyvD8t0qnBllh2utA5nMthAtgNVAmD/o/ynods132eBNUL2i1HdYbDLEW3AAizd+yprq8
# DATA IZ0xF/bLyr4cbmA7XVR3KbC9q8YISCxib+6LLIzgPywmyqm4OKFm6O55KdnNina5iOBw5+UmLfgEPzDIDTjZ1lPb7CCeVxME4X+n
# DATA kz/i5dK+3KMKEe+DF1BfqJAdyJJchboHOAFmC/qC/1ffxwJjIf4CVYFfgsumvgL8qtJpnI/0PfKw+C1jX/6MJHryCyyZaye51qsz
# DATA ewrm0e89Q0X3g1Xs3SRgEccSYOYt8bZTR/t0BGbWgVUPrxGvs+dkVGIuQbOVgDa1nAaTSpmNvRfvcA/cLe5YSp7gYC2wvtjqjzJQ
# DATA l1J6+cr9zkof8yE3mxT8oAg3D3tJZ+FSsTfGFRiVyT9z9grc/oAFsA9peHv5+EfOynG/pPeW6rE4LpxLzghnakqLb8vtESxAY+E1
# DATA jDNAAdqNaZF1+ZJIr5f1nsIGxe+AD3glyHqlNpYrhELpvTkWwXokpJb+4aUFuJJV25ZuVQwN4zlgabDl/5lUyd79HUErMXayqBX4
# DATA chHW/QWj6bqwNqTr+wXG+QEG+m+tfjkw8tCA/TdaCMDPHVM+lGRLrV1Bb29QbdpAKCRM7wXWU7ifeEF2RUfby9hdsWkPx720e29v
# DATA hEUpnrc0/mXvJfpgSsGpRk6oTbCwzrmpiAvVvOtKLbxGrvFE6AKKtsiSClCbYL38zKicLDNACPWNB0en8ZFQaVKtS7iCKsEbwLxg
# DATA jAK4pjqsm9BL30ny556cfA9OHgeC8el885+Mqz/o253iRqH3OVJ3qcPTij3fc5MT5qAu8QuUNyQOpvZeD82stesuqj3BWQt4GXMr
# DATA wvN87nrXSRtm+xAvfvHmLvguRqYh6Q5NLke9ohCD7gzhM0Eaa0HmqI49R9ENZ9XRGTvuh+fxh9tbm7ud9c1HnUdbT9Y2NuEWIQ0E
# DATA YuRP1zbXH9ti+o2Va0CFTbmwRQiOeuhNInkjQhwNpE6tNgJ4WcehBY8a60EX9eWsVPflGuzltfai2nl3zpSY9uyDztNnHzzeeKin
# DATA QjeEHuDF+BIXDa/Kz3JvSA45Zl72XG0W3uGHqGtDme40fZk1AuhexlVzyeAfBfZqYOMIs0dw33BBnU1MUrA2hcxLsteWxkHPPNk2
# DATA xsKk2I2iSOTITKWC0aU5uW5wdDrMek6DIc8uKZa5X9TDy5XUHWXdfiIWZE7A55WPUugg7C9d4bR8ndv1PHCqWhVn6sJdat6VhaP8
# DATA REPOlC58uDT4B5ecAlw7snZY6FARjNpaevs25i/UV0FhXVZp2i/rJHt/sd1nfw/NS/grwa1E34ec1LjUUuEupMkKedrqHqDDNHtm
# DATA iyjdR8ZcLYiWB3ZIpFw4anOdFyZVodp/vY6gjcYMXHZCicGbL6geMjK2I2lLIm2gkaapDHQQHZyqxYd0Nh3Fvpf025tbZL2lDlsy
# DATA swUPyxY0BjrPaQsr1mNbxHkLVWClHinccFv3+Mp+QAU/r8/d/GG/vFcCSm9iiDyxOba2Vb1bUZ5r43+F2aPtaJEVI2APRPoHpUAw
# DATA h7R940gR3DebQCpsRVN5k7drDr2ThyGZs20NeahsZkfsq7wd1znmq5TKWkKSWOOtc6pK/WRkNU8pCx5bJYo9VLvwoa6yXWgE3Tzx
# DATA DtvmjnpuM9h09RhkFC9St7JJQWroT0yIVCdehbqPZI29cYM/9cgWzoT04JFe2rUY0tB1j8HKNM4g/bjaPf2XisDhz6TUnThg0lB/
# DATA Of6pCzv6+J5I5H3QKcOQCIE10CdF/AJTEUe/md9VQXCmJBk0U6vWKBEHuBzqVzD2fXrGbZfy64QiU9DB09PYUOxjxwzJvcIxoF7F
# DATA J1eUEeZVdDVxoWz2QjeyMkFALuO+jWPmXlZ7ftsv/YvbAmO91l6g/4HwXGrVOtTRA1fXxq16oBOBqN0XeI/3TP+iCf0jWQoDpodl
# DATA bqrYlbp1n64mds8J7rTWxZBwPn8xKkX3b0aPMZCeECRnOWf5JgCVOI/GswM1oujZ9uOIYMooeQnHwxMsjJrhSZbnzcW0IxTnAFn1
# DATA JtmAkmIMmQTw5iX3qNJgP/5sDkpPacqBMr0uV+uBCg97Y8VbJH2UO0LXhWYlra9df7K59sna99Y7pKdRU0fOnCH9By6LbiRxgEgU
# DATA ZVhwRGVbnUeE2C3m70t79vCX1c49xUL7njp8oSMVqAYupaEpbbkAM3oOfYrqJ1cFvkHb7JIgSyGEJcPyTKUlYEtBAms+KtKfMC23
# DATA H+wX+bVXGzIS8H0y0e4cGGU79k1IZYABgTaAMUdMh+OsP7FhpiwUE27BqynjgyjOfcZ0wEaymnrAzEE+l2B+MI8bBnjUidXCpLgU
# DATA qpWE5lkP9XSiaIKNY/Q8mGSmKgpC9II1ZeSxDNqcG6dIGPgcjOL0xQwyxqsIg3/B307YVKiYgUkiRH2GKM5y3h96+h2EvgVWlXmn
# DATA HCv66urVJNdvo5Sj9JTqzG1MUYiV3yV+JHk47NG36mnzjonZJZG/3Nhj9DdCR5e4cCNsRkPBGyeEQVeLGYrCfTQDYI2kbx4kzTpN
# DATA NdzC+e1+KLVPHiLLvOEKgbLghDs2IazdrKEO6SST0a69bJybHwez/qDHQcLqeoFqFTAHVyDA3KjtxY0e4/LxNJELJFWJvkeoA71B
# DATA OYhc+FJvggrctmy2gtIbMfG0d1YVnaqzG7Nrq/YurqESulUEhLT43U3VjdoeAGlnr7LubJoeDDDIeCMOYmmDvxUFU+POMi01x2rn
# DATA JZhVV68DasgbY7IRIoGCzgCVgNwr6M1dR6zw0WzavrWywgpkyg0gOrhj/lx3kwBcxkND2ujJQ0OGAkavfxV9vLv7dKehw3Te/DTo
# DATA AmQDCb/QGCwE1MvORf+IahZwQ/q1OogIFI6XOaZLStoDsiWRcdmVvRzpjmgSOZrv0y0ZjsQgo3mGOrNeA6ql+zL7oSdBsFGuT6fs
# DATA tj7UayB8uJ8FdlPA9dqCWC7MJBe0YEjGJ4Jy2bsenZXfng1ejbVNTmiLKzYjCVHs2kQkVRj0MEcQjsPnFB/QiCg6ycFj5e+WDdYB
# DATA 5pnJmzTlOidpANdcclXNDbkKrjRxtC8CFsTFvyhcGIzrrjUvUwUB0CAeBqO6WLDTPAAVQfU2Z0N0WTrp53Bt6oxeeNUVfUpc4YGq
# DATA qQtoIEYD8jphUYLqun8nhGFLCXgCML/i4EjfqcQC/9quzpVA3FgWe77b7okOiEdkXSdxiMm+2oUdVNIuTlgKreKIgR3NaVIEADgn
# DATA TburlbA3bo9cbBKjbJtHB4JCgCNPYVgtnkK3CYnXzAMQKk8OfX+RnUkU3EvSYgutKoJ/zDwuEr/OAWVaLa/9yP8JnUuA6/wHRzX/
# DATA 1Z9We5EvYGvxAZUYXi7UFheoVmXqBq61fbKwqJtvIR+Dg/OMcXw/m4f03IxkUmrt18NeQoDEbxz3HLPIlQ+MI3tdhra4yMPYBba2
# DATA oT6QbEgeIfWzT7GBoQkK28447WsWWbC+IJuzD+uEF0WFHfybeRYET99DEp1NclKSz6l82W0CJ5apKJ2M75PPoVvDaM+3SCg53bv+
# DATA N8mLpJYE0juyvX/KGuZzPeUtbwXqkZwDjq5ADi8eJ03hyq6+UHMqSwJMqixxUbhJLH7YdcpLursbiK/ALDubVTRi7v1Bpqh7hTJV
# DATA 3Uh5NjmDwxCSkmuPhqq7pi/UYQJQFJuC4h+LRVr4w64FQLiopkJsaTJnaqz8RYY9KXfVXQP/Zat6uzqMNOrWU9DauI6zjri5z3iO
# DATA Uhwsb9qnaKGSVL0nZxZGXDEIegVyMP1/xVcRv7UzyQaZIrweswoNTmtdtBHSkeFddKKWy+iD3U18RKOLIMIcaz/NES2SmVYZLhzr
# DATA OEPQCqWofig+yQ8djAX3M2N+LweKo5r8kRqFlzexfrlgtZQQCxXosp8lFsuyuTG1oOcE/7jCVLmfvt1k6bre2XTNP2dV4nYZotyC
# DATA 2siAfGHc4Nva17cVvC0zGh2E3eANWN+JHfUbZuRBIwLqf7E6+YfMWgo5X7V+eDmbdpex1LJ1n8cyaS8dTxn/z3OsD98PF9Q2lOaq
# DATA cpShJmEVpxzAHzXBnmRks5GdWLpK3tU8knrBVTZAsWns4BoHbqCF9S5qguJkXry91hUVon8WZxuL6pYKDM1KRUba80luUC4KiTzC
# DATA /3xBzVWhps4gPRvNMIDF4eRFXrPggSzwm1LWHryQwLIsLbYULJZ/oL5fxz8VKRZXVkdV6d5kTYoZQ8sXyjHzlpBjJrdZGcCHPXqt
# DATA IGintyAhvEIPBsTAhBSQhJKFXIreDUgP6gW9nqm7yRN9KVnEMZN8DeuMbPIkHcs7yDxMxMRkeqPEv6jYJ3LSWkQfxNdFs2z7nk9k
# DATA SF/k6FFbxS2dKkETqbHtjLzwJRXKb8virhkWp8Oag11x8jR4deokPuEx0pKK1CpO+InLHdSDWrycjvvLAH68TNCcMdnCoQ3aF8sa
# DATA RGgMkA/k1y6SqTbR2NWhtzXvHfK9j9WMD9S7cw3028vSHiNU49SejNREjIb9bg0U5qs3Ca7l9BiQmQsF7pvPW+Xpryn5H3aJspuh
# DATA l5a2/NzBPICKXamZC2WbFoFt/sq4wpvxbygRtsWqFZwN1ASHPzoY9c5cNF7dU9SE1SA5J+fohNkqx3/2sNOhXgEQEHhLe0+3Boe3
# DATA qvSeLcm7tp8/HqnjswYORmDYqWOQZAVeNOlerJoGtW2gJEPL1s9NVh1yHta5QX8K+UZ/S0gXEM/6O4yW+yVo4gKCvbcGzINkkuAm
# DATA 2OGq1ESEGE7oCEr0nWTFLFToWqUYoyoVQU6hOI+ePdt41PTlQk7Fiv5Wig5R+10Ovbu9cjupIguLb77woGtbO5zwXKZBd6ZCDUNm
# DATA BbY24dyGsuCRzAdZNq7dZEYZVp2ifTPiSMbfevHJFMaslaW8mj95/Y/q7//0+ks2hQLuJEGWhNLiFsMlf20yU2gwfjJbvoX585qQ
# DATA c+br1/9XG379yzd/BUGffu4MGF0c0NEWOV253GWssV+b4NXPx4ARUEsnR7nN+AW/gL5y/ue21lHHnuoZP2uSPQr/dHS++AS0kjYk
# DATA KFCx7mUc6LipvroKM22OtYc2yIJVgOGnQcxcmK2tNUxUQzOHUHsm98kkRw6qE6k31yZHM9g+T/FNTci37U6nN+p2Oon4sgmegSl/
# DATA UotNz2JwcBiB30d7T1uGjGFIw9ZL67023YvRYMLdw5FBxwo1qG6KAH5XR+Tl9lPKOag4vRLjetK8GP7WSipOd50cgfWQUFvdJSWB
# DATA NYzUaetdNHamunK4HDZOqGe27jKE3QXqQt+U5F5ZGYan5WJVtam7ur7IxpDdE/dMTBfwqVoKz36nQ72OskYfxXOLTwq7NfYMC2w1
# DATA cBKxBbsBQqUNeoDdjx65WBb/gdJ5LXEoxnDkghHWvIMGJFdvY+CHRDIq8bq5yYzIsDM9LgI34vQEELi5vUjs04gaqSB2upMSILEP
# DATA /rAMqo6f0B3THQP/pkXgH3z15F82SowfGDQG+ZuCgfG3RDYuIqxjRmBv7pNyUkdhaJp8SJIhSYkgHxIWglRah93hdOCwMMcm7NHb
# DATA 0rTEqDFCFzDK0FWLFcdWXUk4Q/HD7fW1XZ2PePvRJ9t+buI6ZUayzejE4Ic9bEAmyY1PY7waQAuuAISjaR7Cixr8p85PHm89/G5n
# DATA /VNX7HS5ZSAclHYJSvi92ck4l4R/7qbRKgpIVp6DJ3aad/v9NvtTgjlqOG3fTIABqYXtoOtcp4P7tdOB/dbpxNYPNe8fDWcnuODw
# DATA Zzpo7mx8tLu+/aQe2d8fP3sqvbToOf1TowpMSr4bHXXNR9e+/rSmLyeOoEMcUcolNSmOGhn1u9kZiaIBqZzEr50zRYVP1l/1p8Je
# DATA 6+GiZVRZTQtID9mBHfc5t+SJcYkOm3v9d1ZUNZcRI7cWXCaC7ntzXPYQpecnmFcdpN/PNSDIrzDN+hcIufeNRf53kk5+dKCOyvjs
# DATA G1/Z/yBh/d3bt/Ff9T/v31u3br9/Vz/j5++/f/fuN6KVb3wN/5uBh6xq8hv/Ov/3zWvLs3yyfNAfLmfDl9H4TLGO4a2l69evb2dp
# DATA T21x3B7qWrr2dIPgitB/GS+reTQ9noxmR8ehmCFVvqlqWWKyrkVX/RtMKXCw4JD2pvqpuq3ilZF/qpvLsbpj6p9A+PTfo3wJ/Svg
# DATA 7qGKaO4BwqUuMjGNKcKi/4Q29d/yBus9c/rqKqfM01m/R31gGqH7gHcpRdjUBVHR0u5ADSgyJkS68JnblJHw1aD56mnSALPuXzHK
# DATA kzEkVun31AuZ84S8LZDncVSN9c9ekh6N1fmMMZRUkd582usPm/08nU7PakWfMHcE8RPye4xEPI+qdtIHr2wSH0dDTO+UEl7xif6+
# DATA FbnCH3eJl77J/9Zo2EiWaeREXPvD8WyqX5rp3RxtZ6QV9jWJoEvQ71ihyEOj8At60+HiNRDR8XKiGPUYNPwgN53kR2r61XFQW74O
# DATA yd1UG3PnBxo29as/foC55+/BwcHjckjRNajSgYgmO5i1cd/2sNPpD/vTTod7RvrI0Qu1EWIHqMTqV+mGaMLLoK+OPzPnd9Y+geek
# DATA 6DW4ARdGk2Tj0cDc5Ka8dhNeU1Zo+lNnhQ46yXlz9Ew9S+0coIg1mk1lKux6ZOrWNcfh8bTbGtUBNfW292agqzffb66o/7cKg8UM
# DATA wlAGfrRaq/HFIj3ezk5GU6Z1ub7EkkM+LW0aUWrinZ2Po+lsCCODwwAlYhlRMzhs4lriX7igtIImq/MyiKr4wv2K9yF6e33a+HA0
# DATA OU0nvazXeDoZgYNdZJdTvlV/wTs7Axc0dzapwwITxHDhF26HFtLviwMKEqY9f/LYGVQG1BCArpidXyH9mxZU2d/aCYzChDFiXsAn
# DATA cYwRjiJScZldd27ckPN44SCNmsVw9wKX3YvXKNnjjzgwHHRqH2TqxjZBmmY/93PK+r6lqKsvzUXIH9X8A83urfAx0kWYFloTcSXA
# DATA t0mTyybhcTykJMSNXYZTdSfqVeP09BRz7jVMq4RnbFsszqxjnYaE24pCw7aaQJBg7ZYALIGT+tH6LhsQV5MFvELVRinusG2xe2B+
# DATA wFCFWwcmsA3/MWS7bci3gwBSVPvjLU/sa7pNIkPQZqDb8+xAbrZr1wpz66a2wQhTTJklBrBfuaIkehD5384zkPjEC0Q43RvIQaru
# DATA XpOjrMSpidmyk9yRehJymb2UXcT4TJEEETRoVBnG3OMka/T2l1cz0LjbN79dj+6s3IT/3IL/3L7AYnrD3o9uhpuW1gtFQ/QHSenq
# DATA FwK15y0MbuboMO0Psl4LOUaknUXtIBIZqxVYiFrQLFOPdmnzhow0FZP3e58V9ckwQyUlT8w9sJSBj8CJKtqNnm7t7MKuQO86P4gN
# DATA OqdudydjCqmx9odiruYaBo8fqo0+dRK66ZTrvWlT31gQis6rug4F4NmPVOvN2bQb0t6UVtbPR5TglCpr6lzz8feB9b63stJaWfEc
# DATA 7Kmu5vRHoHwPhymZ5risrpW+aQc77ORkb6a5LlHzSzdtnxPbX+6q6vT3hSlt+DKbKDk0B3/Z/IeztAcy3WiaUvJHQMdI+0NStRs3
# DATA Wrj5OSyecztCLWQ01uKoQFfgu8xEzepsMEBw6tok3ltrfD9t/Gil8e1OY//8Vv3W3YuYkmnPleGfaZG3N8qIWR/2pyi99yzOd0Tz
# DATA 4G3MSaY+xOAakfO1c5KOUUChOxEIKGsPdze+t46adXXzUncn8JOJH23srH3weP0RymH9E3WfxMePN55s7NLT7NUYzCfwdP3Tpxvb
# DATA 9HQ07BxT9iBbhcnnY+eOPTYMeL7t3dwZGb4Yjk6HWi8Q6ZqWCIniBAAJVTs9TJxMi87eSIobd7AAwY6tJHWvBHzWmU7Sw8N+V5eR
# DATA y7oS3W9TE/DHt1dW3l/99rdv3rn9/u2Vb397Vd9asBT2IFBo3ug2hujlGXEv1N6dwQ02N4sI/rRHZyibBUbWgd077ehiNIh4OKLn
# DATA cdKcjcdKFraQWLo+c0PZ3Opsr+8o6qvW8tHaZ/DPJ+vr34V/n2xt7n4Mf3y2vrYtLytlC5Wr1kYT8EnG5iPbLXKTSSdw6DBgfr/Q
# DATA I+AC2JC0VprR237eM/VoNG/8LDrIuiOIxjcF5THg3EW04/ZgJvf0ltzfl7vVPsYOmd1tdfJ+41ubnY+3Hj+C+s/ySJ+Be2joeknH
# DATA FfhajxW55gYHeZiyU0tHLIEiI7KhUZSTEVZbQml8P5uMFANNh3kEYaF4YBlLQ5KKZrT+6jid5ego3u1S2oUT9TuiBiI+4E3nggub
# DATA +UHbb9QcODWbq767CM8z7ilLYTT5uAgHEuHCmEIVfsrUbIPOmXN/0lvkmtwjnouVv2Tbem5p0iNMja0/vmeRY6LD2XSGSzUEM1Qe
# DATA oZ+p1SvJ63Voq1qjFXS7Yg89y8Exh5K2KIEm+pFa3HtKXp6qaz118SQ9i1SrQ+IF6QBBD6J8DAK/ph3pEXpfLjms+NyyrRY7B+st
# DATA rlNcG9q+BhdYK2fQeaBXMeWdsDSIH2sDxE1F7BqrNxu3Vndv3mrd+bb6v+8XMCRi7uljWM0PIExStcck3Hm3owlHy0wsOAkgC9sA
# DATA +jhMBzvA1xELCMRVzJoHfkw15PdJUkC5ioXlClyOzUgUKWRgyjjEuUj73Ouk07ggpu3pt2vo1FiYO/GtyOXVR8wQ2wI/i2W2kJkg
# DATA pm3wCK9xqSRqqDV9OYAISJy10Q/IKJ4fp73RKURI5mIYtprLkO8xaHa6o0FLnAUWuVDryog8pH2W6cT5OyV1YXKRuo6xhbjDmu01
# DATA Gfbx5zO1cKB3qomhaE2fHeBT/QRLyqF6xfPcFnVRFXTfNOvj+fTjN7z7glZ4c+k9XQu5udEoEz/PQCCysFqjbfpm1ZCuylHk5rKz
# DATA 5rage+qeBrqGyBAQ7uO3ULZRt30qAb9u3Vykz091X40+1hFVpZjKASzqTxRVJxmnYnNJJx8lGiKcooKpoLBU4Z5tjqLiFpaaXZk/
# DATA REj9DvJLuVbbyrLC76ej3mvikTQRrlKoUzUMnvpzr7G67++TymvD6t363dtwb1DNJYssjIwzJjWu1velUX4MZiLYEaQzHmRHafcs
# DATA 4BzKE1hcnhirwH2HwZGzg+L1rW44m3Epw2w9fBMD28ywl/V4NN+MHpqliZRQpDbLFFWU2lEryl6qMZweZ1T/CWpukAOnAAIFXkAg
# DATA wfCFHO+PRIn62aCHUqZzZbMHp0hWXMqB1FSP1vLLeoiBlXGufUMUGYKaeuWQJH6j54WsCHqbgZshSDX6LeJh+/dtnHy8tBpw5yD7
# DATA Bv6EtdnXpl5ZpGC2s3WryekfDZEdnedqZmknuKqN3MlFmJPbBkJ2mcMTZOKIznkhNxRwPNvD4Ef7SLR0t2zcjSY/HWi0lo77ztVb
# DATA k0n1XGt1a6h9gsA6CDBAM/PywVlD7x0MR3BoAohkJk4qPczAMGbNBBLoxJo+pQ+6sZIW87oLXZJaFrUHO8RjaBwiueYBHC0dYpKj
# DATA nhnlRbDvoGUHUvCSLQPm0vLo0eFhngk1+Uo9WiUvCLdSDbA1d66+QzW2teaQfiKg0B+hcGfeUPUuY0MZNwx6g68INXMvxl9uljbn
# DATA BW5u/KIYAwAFrQoHUWkgzcNiVBWnn50PNAypusyhIRpX6B5pA/XDNEL0vkjdu/ujXuyF0IFXLcOP7nFv9oshmUWVU0KYab6ZqLzf
# DATA j2ZkLMlYFKOmMYovRxwz6IPJG+fFH2ZDcJ+shfqR3KO50HcX+JH4mRSxBIYQ45K4fT5QQvELnxU6EwLdFNU8CNVSpk7RXn962LRG
# DATA lvOLeq8VuheudB2r4DsoKL0zME6xTgO92B2IbfZvalDLOnz/nAfX0qeVN26L+nDhUAwsonHRZkPPlx3j0sgNcjYdz6Zl+ezK7Mnk
# DATA DWO6jNoAWIMDsCWreg5G4E0DtcUliYqdxhVdGw1easOfKct4EjI/eT1CH2cNXFWPfLCJ/qH4Xg4KfWuHZzXxVvECqD9ZRKWqxqVu
# DATA 8BHYCc7gIuNMgA4ay5vdY9WhmiCyomu8ndrgK0Hjpycd4+0gJV9RzOFIYH8X7jYENPvw2c5uZ+3pRmd367vrm0Bct3XiRvSBIvNw
# DATA ZBKyaRVx26nqydr29z9Y2+w821nf3lx7guoXrTNNe0p4UjUYlx6RjM6I8eHqnq7t7Hyytf1IVqc/gT6JyTFOBfzTsAyQ0AzPwL4s
# DATA Y1FzLFg9of+Ud7qWae2CrfLIX0EmgNDtDlVEfAGv/jnGzVoFWJBx9VmUaNAnAGVh2fNe3PckDXkZgW1o5Z92W/s00xcdrNAKPlR/
# DATA Ml8NTJ9TeXujwvMC9fRklk/L9NVYXTFB37vFJsb+Ievt5P0fCWC1OlkqcxYW9qzIqtkUtlERvDhOz8BQW5eqXdf6Epgcfmj1ndpb
# DATA WN/J1N0CrmW+1ZeiI9zVJRlPPKjrPgnZf78AoGwqk/KXhl3TlxZdyFSZLMx7BSXAqSTYL7L09/qHhxnCfNGN4B42OlJzBrxESbwe
# DATA N0a3cpO8mruCx4LnPtaTrx7qP2U4SSs4XIFTre247jDc0Dvt4lyPwIGj1NsZq8NNZbvsHXBfoKDM2ZhCKZrnG+32UOsetQ2FSTRN
# DATA a3xRyqAlcrJly3QiYuo9TBr+oZ7gRsVcjS1/515opR7YlQ5ZUGhF51bIuADpMO2dqYfqBosxlbO963pBrlOCo5lGVYDiWrdL6Sm6
# DATA SjyhT+d8Boo6xbanOTdP3U8uYtlFVN6gVyCTDUqHoapoGcO/zV1jeDLVNY+GPZ1kqgdHx1NjN5ccUd3XSXhuRtto+YjsMriBK73J
# DATA WUcJPX4MQvxIrZ56bgLhyDBPZLB4dNzQdhNUcqYIK4yZnDrjh9K1GI3502N1SKBr38GdHqkPgM2hfeEMFNZ+tx7CBh2UjxdiqERn
# DATA WPoAxTxrh0GFvY9KUV5w/YCmEX/ZdDCIDMHrLi9qSAzABkp5hZhM7N/TZuwAWSyn6xbpsJrWWpfaAIph8FJX6m7lSVAlwgMdVkuR
# DATA C9UwLXP3Zri1b0Zr1jcJ7CtK/h2MFLtlHVNksEjIAx0diQGnY9jtAww04mRHB0pA7Q3O6A7YDDbkhCS//RSHp1lfezX34tdVzKv8
# DATA KD/k8ZI2G8J9+7C/Jxmcv7E559ORnY9gPDtsdWMFsemXi2NCtfQluq6rtmemsvKQy9x81q1v+4oNdTM7bCQ7ml878EqhvVfCJPUA
# DATA +IzvB9kly8IB9ii4d4DBsTKUWRw1VcoNdz5eu3nn7s6zJzvo10KprTgMopkfp+plbewhmx5nr3r9IzieqOaJkHmMKS+i+v18GJM5
# DATA CCVg1MeLm9vRYHRQi28w6U8Sl4cSRe4xF+Npus5b6Po+sDrJGWUh85yKabc2pww9hAKW6/hrMZfRpRPUWZP5614kphv1Sjk2PVOP
# DATA wfrOohfzKSX50TEd9fBQxcHo6ysFXhfDeFEeAofa2I9+vhcoLshO8JuSVtyr1EItkeZg0Qbw6tKAq4uO50bPOTVpqZr29qq6oYca
# DATA QSmtGBEtfb+07tBWJl6XdUeJJw3CIwuFMod6coZmgtLA5+IH+ibU4JtQ1dc6kDkYwww7bRW15O4dEB7dWVkR8oOOR7aT3YpW//tP
# DATA /pc74AdI901jUwzc6UyqEg4knRvQOS/O8pJ3ERGMie7Df7yztfkI4ZdLrypEcK524zBPDZHBtA0kVaJ8CXob8tJrCjOXIADYvJKG
# DATA AdlTVdHmcCjVbFIeO7q6YIjlv+j/+akxvv74z/dvrazcdOM/V1dXb936Q/zn7zf+c+t0GI2GSpieIohRL4uOZumkF6G94l70IsvG
# DATA GOUEB0zxEEQRQL+UM+sD9VIdSCgejATFGx6nlRIhnPyEkAhMXKY6isOR/tEfc9K5t48MPR5kr+yP2bQ/ML+mqYn1tDleTBxpdjIG
# DATA UrG0tAsuhpFO8wd6YoJ7w9mKl7a3tna1pp7AQk25BiLHGTiOZOnR+odrzx7vdrY+2Vzf7vCX8fJoPLUfxUvPNje8GnMkSj3+t6yB
# DATA pkZ+SpYebm3ubm897jzd3gLwPLe22eHpsszw1uz5NcISTUbQ452N3fWr1pKTwP5k7dMOfN754LPd9R3wZrQRLuYlPFeyL469s7v+
# DATA KU5MHO89G/an+0uPhBhmtfW4Z1kNhYuxtAZ3yfYwm56OJi+AsTfZlacHUPYTPUFLH6BHVftECSF9tDxzuaU9Toy3vwTMrq1uepDT
# DATA bWn9VdbdAX/BtjlMfJCiqhVfxl4poqshUJfIFxK7CSymrYSVpb0NAnDdX/okBSb1wVmgY2ou9Fqsf7jxKczOnp2JTZgJDFLcfw5Z
# DATA VgeQVUI/UlzwAJbi+VBKs4Rt0KNJNCVg6+ftWBjDboCI4SZKwugrB02TnAjcRE70HfJoDtWCU89VdNMx+Hp2SDalhxV5Mql1/K/M
# DATA 06SleV5wJwrEuGQaWtLsjztOSUwF1e9OpX3Ghl7ADbT/apAhostKhNDa+KKfd3B9umk+dR/PMNck3jT8W43EsluLuFiXQ2M3nkI9
# DATA av6G2VS65MSOmZJSv0NbiUkup5YUjH6qEjWY/BhBXtSsH0z6PXVhrEcYK4pP2ysmFJ1gIvVU4G+WjeFrtCjhJRI8GUylSfTj6Pzm
# DATA zQvHtMtvHkR3b2ubIVwZauNEK7/7lD7TiMZj+M/dO3du3bF3Vqqlasa0zhnYEZZ2Lcw8XOjI6s1v6Z5U+3w1W+D1VV+9A05fB5Sa
# DATA 9wB6oytbpD+PkKzwJ9ozMz3pD9AzuT++i0GVcSsmLwSLndkfx66d8zA+pw8vohz2a3SOxS/AjRxCXVmMJ9fydlSL+/1DVACcozYA
# DATA rlekS5CRomJUYkn1ACkLVWSaQJmcX+r84MbPCVbVbqbQ8mJghi1i1nmReSQ6JVwHmCDhxEy746iHVZ7b6k2vET/Atir7zefmUNFO
# DATA 8sHow/k6R35+EZ2fL4GvjqrnhKBb1RMcJxbrMKu4Fx0OUnXnY6JzL7q4WIowLThfP6Aa+kxJC6DJPB6N9NVE3TpGE3Cza6yuqKsq
# DATA GPrPuN/31Fd6Ca8PRtf5sXranRo8aZqc3mQ0Vs/Paa+AblrMyHl0btf+JB3DFavOJyq5UL21Fduv/q0ds3l7zlN+IbuQofNKPz/O
# DATA enWdzrerjfkUXgHioKnkJJum0eA2eoMqwvvybqPfPVFnXP3n5V2aJdXjYa8xzPpHxwejSSOHSQGPdPkw7YFNE59N1KRn+gkMRx0q
# DATA NcVjcg+5eefOZRt39C7DSZaqxcQ8g+MUst00pqNR46B/RGymof1PMJe0Wivoi2pAfXDizC2tkd0bhxSYX7I79Ns5+2OBnXDllTpn
# DATA WnIhO6/+D+QMA+3YBb2rUZMxcwAmsMTe2zp0swBREitK3VFC6Ob6w92NrU2K4WP/XId020rQgek2QdCYh+DHqzhrr38EHwp1AnQG
# DATA vaZAreCWD2FLAR1EZGFwxFPCSYxyXA6CnOJwlJJzF3o47akNRx2F8uEE1Q5PwRP1vPdejImOg4kznc5CIT0Te6a3BSTW8qyTjscg
# DATA 2zo02baxXuiZgUMl2ZdyjSLLx6BDRvOnbYnhiZO+Wu028zJ4+UNvQuzK9aVrrbSTSXDi0rY5JTdANaiKdBvexFFWsJxtbLSptjir
# DATA kwzdsH5uOANas8+fG5j7Jt8AuBtNKt5kbz8vg5P3Pz2MFWQ2ZPLbRJse6tp4xpj1HEwQ+5BKbfTi/b3W6k29ylqSI2ZMVNpIa0ao
# DATA o7zXyLLULA6MLCKcMnByh4dTih8lCA/8gOY3gwfI57Tk7oq4uqYmdQiD5zGRS1m1eexWJD70+fs2gSVp21Y6JDkBlzxSdVN1+oym
# DATA wzzVNKR2GPcy9CYssuvnBFMf6jiK58z3QaTBKTMaUj2cRhf/e4j/jfkSI9pPil9UlOWMfsBGT/vD3ui0BjAS/LfxuF9DJtIzo1a9
# DATA pIie7mAEQXDoca9G9VDxtoMRSlKgiwFMlohPfNSdpIqo501zO7naygcXrKq6hVb8aqsuToKapM1RNDoFT3fSPvXBkQvvw2ADVTdG
# DATA 8tTSV+pc8bs+wIMCBmXlpOQ4Fd6UxEbyiRebH/QWsksbiggQYaLPxkeTFM9SRCmceEzoQACOYhoAiQ45OglNc9qxkU4b15TgzWW7
# DATA seaiUEI2mYgczYWIe2nR9rlAeaF61VqA4AU9dOsmCbdCppR1JcXTRScdI93pUMxZrBjl3G8h+MBFHCZrwYWSjapZulqLPEfw5+qd
# DATA E+qDpgISWpv1CuxpC/Cixo8Yo5WqXIflxWg7O5wRdkrE5fXtsldH1eRokqKDsFZTNk9egGpwDJbfNjZFrsAIuXDYf9WOm7gXGyGI
# DATA cQ/59LBnEU+hbg/xFFqjMZO+xbw1Pr2mgzQTTgmDUmHLWHhxxEwbnDkncJRToBcn8zTf+fJCrhP22hI6KS0g4nJ2S3tVROA9NAZd
# DATA Qalpl/XrvhmrHoKGBjXZzdPjvpJBY/XMRchQD0pzbtOgC/7e+jltm8JrDgz0iqBLeOBroGM1EOw6MzWGa3g9UJJYpn7NKY8R+X8U
# DATA rYxWbt6smp9nQwgFip59+Ekk1kvXK0MPqSGdClaYQdV1kYG4dCHqhk/+4Wlzp7Oxs73+UU1/pfuKo5EPSwbsf1cc41uMk474V60T
# DATA RimbQpHtlKGnCih2KfGuP93k8ehML8yAsYqv3vRy85bVUdNB0K7/lXsXU9/k3RT0jzghKAzGeyuNb4Om787FsuJWz8GVgOpKKikw
# DATA zDj3BPN3zIYnPDvkqJSHCKmji/JgEYhLUI2aKrMTqCQf70Ux9zPxc33V1LEm9H5gQLOxzlYXWvPyryEJywJfoY+YnfQwkJ2tVqSd
# DATA t5x90bY4VB9XnYn4IvkpnA4WO1d5+r+CEZSOIuwV520I3pPvaM1ljg425pn8zmQtYEvBlXigMQ+CT9HJ6GXmIDldlUMxUnjLEoPL
# DATA mSpY6VnwxhGGCvXr5tdiqEAKytPkWyz+/8eBzUAdrmR4hVlPdSfq6DWtovj/0pi0/w7Z1wPgXpdg3+FJmsdUhdeWYnEI9uZoH5/7
# DATA HP8hNfPcZfrcuMvun+JSsAmqBnwybRyuNT5stpb330s0469ZBlr7TqtufyXfSXyO6q8K9nLuHBUnp5Lj+jtJUwdsDDSqLo4e0CcS
# DATA IexH19pMW+DOTRQEbCfo6UjV3NzXaBJ18JrFL7zTv/hoDrLBCMK1piPVkdH0GMO9UMchQ8wUzQURLryesYXUVVdxE3gWIL8O47hR
# DATA 2wswtn0xMyh+7UGGWMvswL0mtqgy8XSEvHB4FhtWpP6bCJRf9G6QB3cu88VhMC/iUbgptedwd4/TMhyADnb9yhivGbczDrOzwjIh
# DATA ja8gncyTrorVl0zVXOnDxQ5BTxR5wzbnAl29CqektXTpHnlzfBjvnauZu7gsUWIjuLmDoKW7xNgZlJwXXEi7GRfKi6a3uyduBWaZ
# DATA JbBBlg5n484YkzMTgrF20HfOLrzTXlZO6jkK2icFUnqQjwYzNb0EhNNssncB6XymeQXTPtQMiXuEX7VgmqfHFwJZqqs2AibDRiip
# DATA GxOIvckzSofHEgMYLuDnfkXAKmKXtm1tzYHHvHmeIeXt5mj6IXgYBkKICjBRDICH/P7x5ndr0I7h9XMIdGEKWMhSs2D6eSHhoFDG
# DATA MgH5dmbwdIDebGIXU/bQ9IqFjZWQlcnpuhE3dGxsrdgaRtPJLlF4nVOJmZvv7X6aJOFm/SocGerRxrY7p+FKCPfDq6hWkMacmmC6
# DATA 9AOkUjCyVfmUhSvXazBJLr2uyHnl4oRWmI8rTK13VhHMm84qwap4HXIObOGAB/hAOIsVNsA5qrY2H3/mZ6myvzc/gJxSDn2qODc+
# DATA kHZVcqvJQUjXy4cXvsFTi5wF/jMc1ZJq+bt0xcVRiII7f9HdEcDKXGxHeMROoPEbybtGviUObjt7K0DRZOHmH8qdaODYvR7wQuHV
# DATA oocxFOq2PD1sfMsCLPPm6h73B70Jbxref5WcxbJkyUGK4hh3gT0HdDPWl0DvnRyPz4TaxxgPxb8dpDjgHfAQgbYKb6XbBzeSAPCp
# DATA 8QEuCxt0ZnVXTaS6GJw5y5oH1tUMRnNU7FnTTWZamET8Qs4ifcVX7cMRyMj6Yp4z8w60OckMjAD+dhZbl/DFAyXI+EjmqKVg0MAS
# DATA ywJhW13GqGC4vzUrOHmD3G6hUbIW2nDgwB7ecHymHGKK7u7LhO+W6XDJ1bu3vnXbwtHAZwVx36dl0Llx2p/kmC4+D8G5C+cQBoWr
# DATA awywIfpmFLclw8NRFQvsRIH5RFZecsRCPARf+0qgfgAp5wAuFiD9DIZy5ib6Jv/p0QHkGOrg0DvgSNbGP50jLuHhpphFFyHiFtkV
# DATA YhS+47F6xJsCTfUk+tfg70kHMhLa/Yr2cvO8qlkS9AdqGGonssdzHjUa+DUllGWooFNKPwOacmf74aEWnWhaybiwKy1uUuJMsrfJ
# DATA l4R46RgbaNOiNxG2uI39QyUS/CxsVtcFVasosBad23Y/MSh607R73GHcYzEiVM/Cml9lfrepOq69coaLe4fbRQ/5JGxsiffIk3p/
# DATA z6JortTv3ryI/W5Xbzsetv7GW/R3sOCkXOkiLgNVu0yG/lj9wa3SnkCRCKKBoTBGdquuNfPjuCjNGZ2dQ+KoBoeqsaj2bNg38ZEF
# DATA UAu9VNwBHZDaa0kdGCVnKcXcKNOViFLo0Ki6TEWlkyPEeilWlcvIYN0J0kkt3kHdoRrweawej8mtiF0w873WTcQP3Iu92LSDND9+
# DATA PmTfnaiRzZ4PEZ3OoaWwEakaUNEhhjfIJwCRnXWj2GxWUwbGRSVAM5AEUvLSWIITC6AUcKtpm/r27rQ0tqyzIRAZCy0SEHHGykP+
# DATA 3FatXhEto0LwX10IFBl5/xUHyIxnw+50RjAV3eN0krfje3/04/sPakns1QYmlmmWj8FnEFtV1UMdXiloJcNkBxhZ5dxUwWWqhsUY
# DATA pg+HwnYS/9RzN/bB4RVLznOfdFEm1QfOsn2T8Xz/DWoxCNMMfv975/ei9UOHRxOQuVLISwgDug9plVCpoZ+Ziik+gsF7+Vnu3zRL
# DATA t4m3VfigWxJ3yZ3GPoDE5wydUteGQb7ML/Gk8N+WdFO38VS11ani93UmXw7Agm3OuAzsxX5IG/qZbcRI+2uaFM4OTzs6mg1RpEzO
# DATA d9NdegquWX4P/J6iRY5M9EgJ6O/LzRfIP5QMDiP4G/CbQTt0n+HfBlx3gYRT79QRm5YWRa9MLKvBcXXigtC00qCGvQxmUYyIrkzH
# DATA fXSYg7f38S1vrpYLx4rzgcX2YQfSoEilA5++B7ZI+Tm+k59BEVx3/HTPqdGHOqXy7ehmhXLcjFnfXpwak3CFq3qBK5ghrDMxnmqH
# DATA YY/VeBiwJMw4aKC6mTA3MZyE2AM4XCDpRRWyGWzCOCoOBiUz5y10Tp243aJ+qOcYiWwyyp9OYNYmuEqaL+LCFC7zeGK0iC4lvnTc
# DATA J0+Q1lcn/E4nEOvS69jKQ8KtObVO6aC1olCqKBf7KNdqwT6aURCMESZM44DujAxHJPUwFReDqMM42pAQhYDXj4INAUA5C/pGOPZD
# DATA sTVSGi+KuRHgMfTnJXhrvXJX0iGgxmF0FOJb4GVddyhm28lTdC3QKZ4yL0BGL+2eW7yAjC8Ff3ILQcBmDQxsojyN74SjsRgn5ILv
# DATA uUnor4VrBqyerXCeJVUka4J5jpwxOKo5uTwOwGSNmqJUd7qQzkhheokq60BB0FQW9M5ztrBeKQsqSob74CDKxhDK9YbNkmzIJIm2
# DATA Ei8FwE4q4UYeIWj3nu3QiNDV4qVgnbVQpXHl8UfuUSKYudvd9JGBf/gsi0OE3aQTf0m683ubt9ItIJfY5MBEPkEX77yrZBKtaFkq
# DATA 9jI8dS5lQuCOe2CrZbIBDhPDkbe9PPUiWWNzzXWE16EOmT8ZvQTYHKP5Jawu8YCDch0+LyEi6uAUoy++Y8K+bLsKTsFssAfQV2C8
# DATA SeIoXlygfttXo6HpT7PSTWHahi1GfW5HEj6Bs25yMWk7LohDOCVaGvIGW5vnIJgklbIWRwZyXir29WanEbGjzHC0TAHfLesMtL2+
# DATA QNKNiyqs4gxp/xRvIT3QELGWWrzj70o9Fhyuo2PvxI7EzBMeprHrxONryFy0SZqGju1/LS7xfyrxNIjnXiQP40t4I8ytreit4MT+
# DATA JeX+vuBAY1iSGXC7MAkhtEZvzxbWtVZw9WFfjpCnT5lDUpIshPvo7fGHnmuU2OWaFdBsL+N3lZvcqM5pvBp7Mffp3iAdltI8TRTr
# DATA gtYtQDCXdCSMn15RqI0LoiA3VGjSMawYKx8ItmxMmYzGfdQtATpOE/QmiPVWw58aBrLZk6nBwC6thJxCrVyXdLEMOxZCEPlZw/EK
# DATA bIBXYBOgj2Py/Wi66J/S6S/iThgf1XkuHeD7pj34yj1KGMrFh3XhP2v9sc1V20BcBEK1UD/Q8DMmbtIfF1xQQmqbMt8TWxvKmLof
# DATA 4CMDsRnXIIwdTNZj+BO1DFRCJNJtUjBfMm9acBXUaNl2dsjLct4fXzQhpm2pmI7cIelYvB7dXvn2XTlkw5kPY4N49HxoUI6ejnJG
# DATA OsIIedVQ1DisRjpy+yUJbREPxZ8wRdXuergo2ikLSPykIgqx9p0WBiL+mCEVksiHUbFBIWrVL6IiA5hIhJHbt29x+GLECtPo+qTb
# DATA 6KaqCjVcr7aGKn7dodxgkFO0+WU66ae4GrW5IZRqm3BXeV4uIrc/VTzrMDYIEJi8iu27lNa2ciRqpYrdx9y/HbuX4BTp+xJvd/3S
# DATA v2o55CNW6xJzKDbQpuR8tY6GIZ1i3m/STlhgcxAoBFCIecfJ6WG77S2HkwxMNuseQn8SHGV6P+ghhOdLcmfsiFNRMYgyb0J0s2KK
# DATA e1QJHqFi9oSKngYYLDi9nKQT4KPgiUz0A7k98gWzx1qws3w1RH6sJrlLsdsHmYGiji8hxB4qcQGaJN5YZSii/qhtqAMbh/0C+QIG
# DATA 5/sIUDnihYgUJ9xPcFa5J/A+ETlh4bOg4OqLKAA5F/nCSZkh7jgbjB1DpePqYDXmuvdcvuziUqP3roUkiOD4fPgVQDgCMYDChV12
# DATA vRoEUXUG1dc0uGAFl4BJdGpLQgeHl6pkmhe8bVFnF1jjYJvCi8WRRkuFvKWlf+shX0ohdTDqmpBwRqA87A6nAzLcqpcddjXU7cOz
# DATA uOiSY4qaLElFp0NThj0PH26vr+1qR8PtR59sz3NCBDX5Xa0md53dPadB2/7v22PQdd+8rOsgTBlgm+uZk35muE7NQ1xB6VdJz2G+
# DATA Ouuf2uJn4CAUjnaHAHqwQTnTFlbidMjtXrvY566HiH4aNP1dIT6vHOKDo0j0wRFRs3kLW+pDII8hMt4Vpa6lolCPKyMzb8CHUu5S
# DATA Vw0T9kBTpig+BdnUQvaVNmVrDAAkXsrLRvt4VrnXXNlus1Sh3xbaHKldM+ajpcIr//p6GReoS6hc2Wy2OZIOZUU1a1HMuGdd8l/0
# DATA FbEtetE5aCudevXlHW79/honxUkrO0++j849DbK3VxjaqKhWNkOAnUp920+Cdmz8uG4T1SxuIPQ3a883oMtUFL63QbVuxLr9hvjT
# DATA vM1TvYEq9kjVRFbuhbecxPKJLJ/MQC/KWL+/K0vm2w2by21YRpFSL4zAdDXyzD1B9VJZ9N6wFhMadXc6QMrczzUKVUMJdKhcnI9T
# DATA LYQzAXoWx1c5qFLvBU6vTdBtvsjO8prkkCGOURo8GBhmqpofNtS9ChI+uY3bQBjVg9o8XV3d61AwT5PN4zI5QTXaUiD9EmMGluS+
# DATA kVnFmoiyrm/0NfzVXN/cWt/crUfm1+76k6e7n5kH659u7OxWJTQqJ5V0ADzLGy2gIvcUCWucJwgFy6Rs0Am9XArKwGuA/qWjRyUL
# DATA rxu0A9LREwOwJ1/CVlegC6j5Ajm7EIOP0r8DTFJpAaDihVB8FGa9V1KmnQNMQpIpzaWfVhVrpVSwNturlwjW+He+7I9meSfgbh68
# DATA 5MiodFSqhkuZyUGF3rmBCrWLgoHusvEyQ5EwOfGX2v0C63ZeWWcZXOeSNqx3CwKSRtqthL5xagdFU0FW8/xoXLRtSC5mMFOXtAYT
# DATA YTgdnO5yjG53Zd4S5hEIHFonCrfkehQMxQAKtV+wIGA1blx3OZDZAjtWYB+MMDTnnGJQsVYfTUjGK1mgoGL/tL8e5eux5sECoogf
# DATA me3sIV9f4NcWBlJxqvAjoANzj5uq04F56HTcU1XysbNKAt/7nM2kLWO+y/NjOj8tvcuEjb0VSfAz97y13GGo1/aotMQZuSh0klR0
# DATA Rhl3Fd5ZLJkN9Sa/qghBuKnSMTcQyF1gud6aC3ZbuKu711ijFUfgxyZGGIXghnjLVSZsXFg6qba8ijB82UVfgpWTpikPI/KSNMqP
# DATA ygBXfXW1Gv4eUpLyAVYKj/MWPEDpFt1xJZ9KrCQnLxymgLtScjh87yUaI+hYJzsaijE0aNx3PH7FQRCqQOsvYj6OvQadd9SDgP9p
# DATA g71S6TvgMXFduD2bH6hUwriK/lQ0YnCc9iu63eBGK4sgYWmMyZOnmDRupfJjdRfzP4XEbuHC/SEqsQsfVDVQUMiUDdSJQNKp3qhs
# DATA KN8bZmbT6MVtswTFazhyf8q6TYR67+ZNTAHOubiFBFAW3uNAFYEM2SrPWxZvszTj5REJdFluKwkrTpKxDPbDL4Us5EoEBZQQduG3
# DATA InVxSH5fvD0tI+ed+DivJyafOYWcLdAYXH3c08WHzvXOLy4vFiIfUbcPjl8wfVepI5unPZmvQXknWpSADkPv/KYjS5eI0EVP7OQt
# DATA 3cHcuWPMpb2VfS9doOOljBCT2BLypBVToVUAh7eMbqd4ChfcsR4ZtbgdlTejMDKrb/MB9PDD/isIPVA9btCiCqiNlyOA+Ae13DLa
# DATA KieKjedR2p2McougPbG44YX77Ndwx9TNXvoGfOW+wXwIS5djLFvU2uVYtzzcDKioDBxZ2oEY9ihsAQrsJJIEws6UexS4DsKmCWGv
# DATA hTYw80aNQ3yoi1ujAURT2suQOXSoTZH8yTsP5s5aygTQxD7neIRJ4KXUDj6BNInmBbWqDNY2t3p/JOJqj0EODh1ifVklGWstQlm1
# DATA 1+OV0/HJyqrteGKWoKDE4S1HQ/VuuK4zbj0cTFKBSRYsbx0mL3fbxefJnC2HAq630QT6dymd1+4XCxLud7eJSzW/9mD6q1A5iPno
# DATA ZWVzU+6Xv4Dmt+T8063mXR/8eWq3Eo0AieGFPe0ByGJoABYxypT9JBHquvJ5qtibKHKWXcy8jSWzihT4hKligazPnOj5G3/437/i
# DATA /6GXFpzzryj389z8z6srq++v3vHyP6/cfP/OH/I/fx3/85My69/59HL5mbugasmD2ZqP0xwSMZuf05PBJfM216Ons0n2FPAvStI4
# DATA Z10lTuXB1M1n5vFMXS8UWXy4trv2eOujztO13Y+1qGUV7tYkG5uz0VGiVzoYHZEPIbiK6Tp0zuKbnLBY5i1+sra58eH6zq5NbAyO
# DATA qvgKTKiP1+jpXXqEkWM61fHd28W0yJAMQdSOZteNzY/MN+q9+0J/ePd2oHOm1KP1pzgN31ra2VU96myuPUFHzqZJZ0IMd+mPt55t
# DATA b649DhRoiNxXXBgvNYGqyC1xe/3h+sbTXVPA1nSQdl/MxlzJ1uNHnZ3dZx8AJk18/1pvhJsMN9CD+/DfaJAOj9rXs+H1B/cxvSNC
# DATA oWTT9nWEyFNPMcjrAccw3F+mn/fH+glcfqyH6/3l8YP7y1g9RChsPFrf3N34cGN9m8JfuqOTcR8kBYQ20rhGCGt0+/2L599XW+Pj
# DATA 9U8DZQ8RE/vubSqzu/Xd9c3SUrduUqn1T3fXN3c2tjZ3EMSiCb3CiJVunlNGT/onf3mE/05fTfkxCsZx8xWXP80O1FHtHyphK75Q
# DATA u787SPM82lGTTRdme3c2eu1ch0h1ijBqPoTaXPi0aug0Vk6a3sSPnj19vPEQNuIf72xtdr67/pljwwkDpbkgadx3mAlCZGwFbXtC
# DATA X0T4aQdn04IbCAPVBeEXvfCtBfDYOgKQTWd0lMhPfKGBkT/KxNPtrDvDcAdap4AnR2EeNza/t/Z44xHOorrbImXFb/T0IInz0AS9
# DATA YH+bBTtxch9AjD5jDqpfq99CdU38/DmGPeGLio4929xZ+3C9s7azs76LJDhOHGxjSehlBim4foUhjuHSTpiT1zTaoUYmMKDHAE9w
# DATA xwcKmpsFel8mhMaD/m3MBw1VBmGN4AVMwjmFnDSb8QVFuk2mAmiqGU4p6XWj9p2WYrU/Hk+GP05nr348nA1+rOjF3qrq1o8H4yn+
# DATA kahCz5vNG8l3uFdw225uFK9kh9wLFwo6MWF4+ezwsP9Kbd9TuCZpjYYlQskVVjSAGdnpjfDWcel95ywr770H0c07txY4Ao+2nqxt
# DATA bIby8RhihjU2J5DvfYzro1aLDnu/N0zVT33207zb76vfPFFlEG6XOaG6e/KMSow0zulOw61KXs57Vm0JyZrurl7oN7hLFKuTNpfy
# DATA 0DGYbChrSbdOedCMkyS57MQHaTSoagu4tI4P1jsAPNebHO7Apqam2mnHTrLcsn1NIf12W/+PDoAO03GkhKWpIpvwAuy+UxJ/4Vn/
# DATA QE1ljhoLULe/ur2yModl4wTtfPbk8cbmd10P0TA+eTWW+JzG5KKsbT5U4vXWtttobZSTIyWoPBAzjywv5U0GHfUqkderENUXma1P
# DATA tjfQL6tkCHbe2mLehP9ojlGHbz+b2JnNrd2O+nD9oerHZ5fuCHpLXB3afeEeqvqePV7bxutOKTp7h+xOAgGbKYikNFYRXTjK5iBz
# DATA zOUNeaD3k0LqV3tyw0rgzkn6IrMI+BawH5HE7twpPy1IqGz1BWqFteOgRJ12ZKGpcbtCAxSbBE1ZHRqrxfCm356D36TUQQnnSxj/
# DATA 3PyeRU8kdVbtkuGx5eyo8B9kCp3DXptapHqKK8nj8xH5yzeAcPChFLdtD2Jfk8cReLpZyx8RxcLrDzY219TBgZchm2BHIPljc4nA
# DATA 1FcSR5aeBHBjTYgclVgQWV9Dt4ojZx+58W/2+TzMfP80olbi8caTjd0iSj73tgwnPz2cZpO5owuh6aN7te1zfziqe0OQv08g1KEz
# DATA JGjZGrZqvjK/6CPz03xTIRLg+B9+vLb50fqjIkB/SQync6Za3iY2eXgds7hmYdcMC2u5AYKulVaYEsMbGn8ZGu9btJcq808w7dGb
# DATA tyhFh+4WkDMOha+91ZaHM6kx920bcG3Bys2BD8WFlkZAOvd1OQpsKSRwVcafavXAFfl/GTT8ZUQAWmLbuUuHgxZoTiDn9Duh9xVZ
# DATA S0S7yfxIlhL6fDmb5dztUbRMyiPszrd44xwHYlJ0zgquIUG2xWsCuiGtSa6FlFLj9AzKALciwC2hqHbiQAsa6Oq0L4vcRomycZ1P
# DATA NnZ2NjY/Kt5Jne4y7FVb99tXkFn8jecTwu12sVBMVmLdLOiq4HeBxWFDEvRAJ/Bl7QAXcKG8KXkfvkDAE34K/G8Ol9P3V2dOHql/
# DATA Jba2Kj5JB5hiFNrYExC/BgGc0XQAUQMttGBWIVfRGn/P5zLOXqaDOKkA3rTVNA9GvbM6VvVwhK8JihNTgXjFmm5qEMVt38HQgb/x
# DATA WHgUHei+37aXZ3E8qcGHBPJJn72DvkzSU8xy/2pqNDZSPRtWsu6cDafpq6BuVfFhNY2XV7MG+hjQ56A6Jz1NGG/AOcKLnk0peLHQ
# DATA RapuqLhEoUb6aMz0gacim7JwdQ1sC3n3ODtJtf93TipL3E1QaE+/3/czzLhvvYO10ExpEWp0mrOSfY/7sF8yEigq4GcdlTS8Q420
# DATA Y2G7YpcCZg5VP94RVTMuKEuxj95kqyc81/0exmiBGYr89E2IAKLtQSAqzn+BaxXb2IPK9l01qTVZSdWgLovFzC+r1wu1p5WMXptg
# DATA evGyfvDTJilPDa6vfg6b/SR91T+ZnZQB9UtUfg+QnyecazLGJl0haN9qZjpXlWwD6IXurN66u5LsJ8kViI2M32UsP5w9WqYqmGQO
# DATA 8DabAF7f0vuUwo31RrV238v0ED9w4osHPURsg+3mhh2TvCIikAivJhiDRFYhF7ZPj1A9bHaV/AVNQfzdUDfK4xPD58bsRomfv1pZ
# DATA QbWs7gfvEv7pE+9kDiLL5SdIY/Odn5NW+uLC6Y4W7HGUwlKDZtdkUZmequ4owvNw/eOtx4/WtzsArrn+6a7XE5o5iDCpefPqqjJj
# DATA xNCnXmijDG1FmNTbK7fDr4LU4zxOD0azqbEk469l0cBFs48JQDI05PM2XUg/t73+756py+UjJal+tL5jxUcHfyXn3emF5YMn3BC8
# DATA GEEHhPKyCds029d9ou8jQ89YiNtWK+tIB27rhJt0M15oNCBuq3V7/HgDTF9F87OhoPtEEErNG56sr/PonSsS1jJUTRM18gGs4A/J
# DATA heRC3m2CBD11nvetOgz9GYkZodWtYMGHCWvpI2CldXFE6uhsoTENqZp69MPZaMr+vIkhDYVDY6OwM4GtV0GX2NVSklhNpTjjBu8V
# DATA YwOcTzZct3g2Y+m5Iv48O6mqsPr7K8hx2+ubQBekGBfaO7R86H1k5l3NhVqiqVbY0mOQ/9iqysssZSpvmxjsdK5JEw5XpgkYXb67
# DATA ufXJJlFWLVm5nRf7Ld/T1e+brWcMfmfDrlSECV1XO6DrWkxHUa2+on12GX1YUO8c1FygIgmGFFI4BGOCq5Q2MhyXRPaC0uYS2uxP
# DATA tuVgnbCW9U8fPv7K1dys+oFwmBJlNyt/adh4IfFfHQ5m+bGQZ8x8F/TGPIV0fnuOgwHv0JoIFmAPg2yYKw7SQaN+mwH7gQp1ABaG
# DATA M23lmdoFqVqmvF2L60CUW3GiE8IkhVsn90N9cNLv8nTIzpSsHJyY0STFHNK4a4UbonC0w6lqAHQq+DI24T+3FfE/zjivEG8hU1vd
# DATA n5GA+rZC87b48ZujJuS10yxG9K+YbjUcrh76mo+2OOX5pNtxzq46SPm0U3KcLTVqyleFc8sEk9osMfRxML4pZ3YCvwgq/50Jf3f2
# DATA NwN0V2l3Ex3j2QurLdVJg7ufyeLJMZ80CgqXLGQShsflmYSN7WKSddW9T2CkT0dT1KlRkCYAanJ6LW5I3eRE/ix+33JvQRMILB8j
# DATA meQCzfFoXEu8Da/LumFJDhtxbCxzOFVhBan+0gNTyrPou6+Ua3HmZWpUZ20WnYFMu+KXn2yDR1YcejCj82J5n738z7wxTPpnz9kZ
# DATA lE+4xA+ioi9zq9S3KSyQ7W6vF82Z/pkCLHQcdrRMI8EFCg+BbExUilKjB7NCh8OmMiU39V9mmg3o353pqMZ4kBDWpfZeLSmbwGpH
# DATA F1zMt/H/KbPahMFH7MBwRU3SidiG5tbNqJPy7/VR1t+zlIS7AEzM4S/LoU8WsDmVGAQFYKznat8g+tWqdK674ia01PG9ttOV0tK9
# DATA /lGWA6Xm+ItmfpzevHO3Vl7/V+EMEYSdeQsHidD/LuE0UbK279CR4pq7POi3oB/0hyM8go4fg/xC/Uxac30zF3FLKD+HNmml2/PK
# DATA z4jhmo/n9/GAQ+2lQ8iJuqNCEvq7dVtTMt8VldcHa2wtlOn1bSbIHp3mbAxuVTVseP5HdmYbpOdd4DtSUpkJWv2KF38x95uSjn7t
# DATA 3jfvcvQF9oM4c5bzFIfDe0BdreivmgzgDV7tS8WmSzgqsITskWxzidMqMhaPkkT2z+hYEC3GVbIYf2kJTul4UYeAPzxx3TE3Sn+7
# DATA YrRb4iqHMO+I6hX3je763N3QO9Pv2hUtmS/6Q9KksiYKlamoirJ2Nnit7jZFe9vVbJ/2MTaOD324MsQfCKUs94a4Zzu+iIXP/6QQ
# DATA XmI0hFiQJ2IfZ819FDDmUAFWyNq5LwzB2LecDwJ2rtI2cDW88X68/mlxoFhuoRAE8k3ftepKq3lm+ag/jJwOFw1jIaNYwMaO1VV2
# DATA HktcyhApe76AoyEwHEUelFQ8GJ0BbFlIa2jfqruMidN0JGDMEDPBsMvABm68XNUJnFxFktRfUhUFv6R1JD9eDEMxLsJz580gQR7W
# DATA h1uW/r6sRRCGGhdCK55mEwRQZP+PEpDkMNv54NnOZ0U/D+dWL2VbiShUJVQHdHShGZLaiOE0DoBJUtTzSf6yO5kW3tJjDMhVMouT
# DATA mYJfPVY744PHkM5jdRENXQGiyrlaLJIEQ82L+L35QWGxqpGsL7NIV8+00VF9Qejp2iA7hHi7/tHx1GW0+VneBEqsaM2Jk6pHMdjZ
# DATA qzgJJ4EmgKr+AWuBKaC++fDR48ecp2CWZx0MrBdQOoezIaN/mC3FVRDmo9og6fSm2lYYVKU7ab6qzErtNNBMJ0fYI0x2T33rdhDG
# DATA 0fwCh43OWDyY83qm3u+7rQAmDMR4t51KivpRmHu8H8IfHa3r1W9pTeA1/tUJKFF1izWnAhSMWaUPLyiDYd2pxi2Fb3Sxm5TqujTH
# DATA MINd98T41KrRolrjHBaAIFKDuL7z2Y6BW0eaZn5tPd3c2t159vTpRcUa0sHgw1ProosqaP4UHzVPrAkF4fPJqREULPlUHQ6YKUd7
# DATA rd/bnaiZiynvqYXFm5BmOOxPsQ7qlbXdja1N0rXsiPy1Cx+ywBmZe7hKT8/cExQczdru1pONhx1tAFb8tvNsc+17axuPwQVc+vF8
# DATA Lcdt0SNXOHa07KSYwT8LR09uGCgmfndKDEfmKHpVymPGjrx8zoqVuqXlXuNPVn1YVBs8WXUci6s69xgZgKdSBo22LBQqQ8dsqchi
# DATA r7afyLzFMyeNAt5pZHvSNe3K3PTXqaNN3N4nhmQQagci5Qnx0jV8GrcTIhQivD8IRUimBluZ7uVyFFNreQx/G6EUrnMOvdHttUUl
# DATA 6P9Iz0Hs9yvP2bCgS1uPD36/YLDwB2sPv/vsKQKeVgU/U/aZgrAeVgGMAHwRLHWK3IG3GDpMiW8LluigamCSnuprdskdwbkdWEQY
# DATA z9Wj6uZfROYXuX5tugwD128dlrqZkrScDZROusdgF2iV6R+4gOqrxJSp0Ei8A52C7aBRIdQZm+7r1iUwXk5BpcCXettRrKG448oQ
# DATA MarBGNxrLR9ix1FqT17Ui+oIPSE4ZfuFXLG1oHaAS89XD3DBJFlcQ0AnNpaSjN1Z9hQ4l2QKPfC3oSxccjiCpZNAIguzYT1aAJ7+
# DATA 8nQjuUtPi+QTxRar5OGJmSd1MflylarFJgR/8FR4Nh4hpLmgkMgJuNVkzmEXXKQeTUcvMiVCjga9ejTMThlXsc4sSmJE6HUIkbYl
# DATA m3WgpOsUfSyadsQ8wSIsEnEvewlzKr5xXy50K6U5Rn3YZzu760+EDKi3h9OE2iw1gZMFLkA4RcKtwQvw5mow0nxlxY3GKVtJocYJ
# DATA b2kTZBIs6dJgo7U2RLQVrWo62qqkZ/WC8CWJWStAyTQlbuGWKX5Oe78Vvc1RktlNSCbS/EnvM3KWcXhofHp6SmFnsAkV2QrvVCig
# DATA Xlwu9pgZoje/uC/U33yEWF7iXC0gNsjdDrkjBj2eNiVPZafqbzhwzhRCmZ13MINerXpR+GzHdLjhAf5xIeOmzG5C3qxdbz2MvRvR
# DATA zXkzaL6Q1nbtr+esnAS8I4fMIIQQyUSH/WE/Py6jZ44elG8Qwss1O4DN70tfuHNkRsWjQhHHORBLhCiDyBi1CEUpNB3UProUFfk2
# DATA 7X4eTeIkPaBXuiOoJlE1BMKAOXkflavrqfH1j4t1oA3J207FG5yhisaNao+rqNOsJ4FoZboRuYxGRhzyItft/iskGMzzYI6ZeVuJ
# DATA qvmBOiFD9JUr3bNSJcnFi+Y//eLKFkCuoF5yHN9e7CZy5tIxplpMsOqCPhlJ3JKTdyeTL2C2w856QioiPhatWFQ0CcvuYrD7Gple
# DATA 7oKQ5F68RIek6QUF+jCGnC/hwyrs1yPzgxYhIPIHZwsWbwGBHouVXiJokRe+RXBx02owVsqDVrNUUuJ0xnrcus7L3Dh2t9c2d9Ye
# DATA 7toIIw18HjKI20sNSqWltyf36sAVkepzEb7hbsylywijgU8F27EiouUsc7le9mqsRFmMahT7oJB/2ll0xmaniyecG13JW65LZxH1
# DATA yLyLSHc2QR1W+61kKLYTvdTcCdp0+F6df9vlT7RhErI9QXnjT4JJE8LTWbiG6u6b+6Q97za1zQA3i513fIMz09YdmKv2p3l1RV1K
# DATA BimIzlKVIFKlS5K7wxEDLqEi4Lp6Zu6NZGMUrKXESeiBJ/0jDOByj5b76ZJrFC+Oi2pJqjf9JW/79owdZY4cp5cXZp2SWfFEBO0g
# DATA 5kbEI5W3oXAfr9BPKza6rdQj/wD4onT4mMB9wxslf+Dt6vKx220ZuF5jV22jARkX5duAMCp66gPBlYqjBVM9tW/qdDfuJTopKFC9
# DATA eB4qaFE9eGRwzDjvcrvNmXixRBUanssMJTAASQKxg4txFbbNPNz63vr2ZxAG/uHjjYe7cVJFt8xw5x+v4rCKK1lcHLJ1lpAsc9pN
# DATA nzDTEX88l1pWDvjr5I1c4JphOG5K33IuthDOaYA3zU/Hp6PArCxReURZG2FLs/ozKRV+pLEO59dvSfeAr2vSQugvBV/6zvkOwkoj
# DATA zT5De9fqd6L4KBtmE9yS6kN9Tjy9j/FUbBmBzfguzhFGLvQtWV2Sp/10QBHS+rQ6bjj8sDwOzbhkhKO+LhObbHQOlwlP1h18R7Fe
# DATA jppGx1hcPryLzB+GQXCYP7hchQK3DvsTDDIZQiImLuH7S2g7PxYtT/vrLYr/pUVElKAYcG0sNl3tfV1wkPFCt6i5RUO3QuEjbwm4
# DATA XITKfUA2QSey5Bq52+osGcmCAy1o85wFB+lJzG8hMIr1W4YsVlQVCglbrEeOobmsY87YUamnfxWUcaa39SI4XvK2IwiFCy8SB1Dl
# DATA YwhAatnkZciX14Xg0zoDn6m6tsWlkslgJWVSrFCE6DIzgDczyAQfm86Bjo1kVDAgcPy8COwjxhGwhrw7duAzHH5mOJdkGZz1lDE1
# DATA xA3Kx9doxxNFNEcnGB+CMecaHEBc1KQJshKJA6LHQeHIVRnadDAaDQKu8LoTVi1mHpEXAHXN3LiDAQEGKWRhfRRA+KzvGGA5u2aO
# DATA w45jcLNnw6pyAi7mfBmzpRdVXdvw74L2Ws1KSHHthKDTdNs4F64NfvuSgSlUJVVIwhQ8n1hKXuXb5Z5RBdsQYSRCj4Uo59xEloS9
# DATA 2m+VZJEy938dAPUyY/XPIsYq0yn9nX9ZEZMcpN4LkAxC2ChQDHP3CoZzSXJheucGzLg0QRQSz/clmRBF+Nn+hR/rITfUlTfQYpvo
# DATA UmrHAB8IXTMCowirUMvF5sU7T9q6wP4lKYumCN6CcvjcaaAs9G1v33Vpqy/2lYn0qxAe6v7n5o0T/lfagcqtErrnwzNGXnIm4ypT
# DATA XQH0RGjbo36X3Ij7PfVh/7CfTdCUI34yApTufm3+JrF4myCZwhNRXbtd5OOJVWTm2UDr9WsL8nuP3hD/56R/TRpijUdKkGSGZbYF
# DATA y8Sv9Bvn5q57FITDujQklgSMdHCxdDsCF8vG9r/IQILwcX0K9v8Ah630AvBlWN9NiJVEXjqKywJHTtOJuuJgvDd0czkqwGMw56KC
# DATA TR+jRIIXYQnTsO/XakGxbt92+8sAHRZJ7pzHdkNi/DCEoCKrlLL7KGtOjgajg1p8I06Sizpg8bUH6clBL8ViLT+TWF1nCaFIgZAm
# DATA 1kdIGWas9io661Q4Qznxqy2zSW0ka0tLruGwZ45obGmgP4/IlUFvOsq2+fvgoqx1dseSnhcOoXSceswMlXj2LKKaC3r2OGYIo6W5
# DATA FvAAWTS0XOq6L+vG2HHsk+JRIZuglJ6Y6vViISUGeQsSuJjvOUFhK+BXVyZ8lW0+R7YKjMlKVXqmpFCl0Q0x9XfxKkYF60Zx2LGt
# DATA ld6+gmDpxa/LvQwCxRe+N320vrm+vSbMxV/p1emqtwtrxRc9olKJFzfBRUVUiGxUgz4v6B+hK8MgnEtFT8SLXmzAs6j0Hpk4V8aq
# DATA cmH/pyrAHuMn0Hm6vvnIxbu11owSGfgyipui4SKwYXF8C/pEcE0LjdPu7wApZHM0iTnlFveQIyLNi+cX4ozXFNYGQeDb+hl4y1KL
# DATA emBvZetmetTreOsS9NTnazE1Pt8Lx8YjySb8RXJfy9XSY/YvB16PnfbmSpM2GmtRFsabxtoZ614fjG++c+ir+Rp9/5ZKAVch4E2j
# DATA c7HwJq3ELRnrdLicHbJUGSAYdIG1of5PibAv3TyWSl6coCMU5Vlvrk2OZjDZT/FNTQA9t+MNYuDRwWzYU2w8UuQvHURAZDW7yJEw
# DATA jmbTCOcN9FqQEwH6nDdNQl2oGTDGOyk3VosbDYm7BnrJ9lOjJij7gqTNyjICZ0VNQqpmxihRK7+j2WtMyKlzsf6wBATspUsTRsLE
# DATA VG2c6tZgjq7wGW+bhTuoyXNDbCLNhxFgjb/Df+DLHDdMEkxTDa+b0PHC+acDXLzyoysFfsYdLzjl4Esni6M196s3Ifbil9FiqP7N
# DATA KvBKuxsPm6Jl7byqsfxwpjqTR2J3IlEMTmXd7H2zFaAX3j4tzJMjcroTUHdmq146CfwmqCotWvHnz7Ods8Xmy58c/j61U9iLZkN1
# DATA N4OZhC0DVc9yRVVL5sSxiATnRJtG8Ic1TcgtUDUr40lfHQkBvExNL4K8nBRYx8o8M1YAF6TQgfMYSzBTwb/h0l/sj5KL4Z7bBpyB
# DATA fKqu85NCh1YVyTfH1SScAVWbTbIiIPvNSd1fCltRnSoAyB8urog+1OmgIqvTgdXodNgLAbqm5NtpDXmOmrBvXP5/wFVw/bXusDk+
# DATA +8Y7/t+K+t/d27fxX/U/59+bq6u3bt96Xz+j56ur779/5xvRyje+hv/NADtCNf+Nf53/83OvnV8n9dT11mr9Oooa11t759f7veut
# DATA 6yjYTRV9UEflev06ZqlQj1//7ZufvPmL11+8+bPXv3z9qzd/9uanb37y+ufR6y+i179Tf/32zZ+qZ+rJ6y/hr9efv/6t+lgIPFDF
# DATA /6le/9Prv1eFf1LyVT1S//6FauE3b/5aFXn9a3ilGlVFVZW/gtbU//1KPf31m5+pbvxU/fs36kOqURX/7Zu/Ui9/8fqLpmoeVVjX
# DATA W+fXdQ4V1Yn713ojhIHApBcPnj8f3oc/ooGSsNrPn1/Phuo/D+4fZ2nvwf2TbJpihqI8m8JL1J7he3wDhxYev+xnpwCLpP7UGjR4
# DATA fNrvTY/bPSVVdrMG/qhrS0AjV8Je1l61dR1Pp+MG0PeX8OlDqqWxA3nL+tOzxtPRoN898xpgIayRT7rR8zjPBofP43sRTbn/cHo2
# DATA yLxn/ZMj5wm6yrXuRaODH6jl51dDxbSg8EGaZw3VF/EIQFkaJGbZp8XZEZvA6/9a9LKfz1DqnWYHo9GLCNPVKCn36BjuJMeKkRyP
# DATA Br0cWeH0WEnGqWKLUX4CgjNdJiChcgTabvVcsaWTKEtzME9MR8AUm9HOdNY7w29Hk15/CLBLjCSrBDoQqU8AEBJ7jVv9wVNQbYN4
# DATA cwjeI9GPo38362fT6OVooES/+8tU6D7660yyAQyj36WRqe4ewu/lNFf7JV+G58385RG8Q5kSyp6o6pfVw/denQywVVkTrlJ+nGXT
# DATA UH2wBM1unl/yM7Tz6c9oKQBCv1DkB1ACBPts8uD+MhVUf+BJgGMC6f5wi6ASCD6XpAJrV4dloKrEPr3oj2VvvgnsCwrtqBewOrwP
# DATA 7i+ndNqgVfH9AVwsnOFY0x5U466KqmOYvlQySj9tDNIDmpYnIDepx/2jlDcftFBS39bLbALnGOsSpXK1f/pZbsrtjFM4wBE/94vD
# DATA FjRlt2E/no4mL3BtsOiy6g9PKgyYRMMefKrn5z6nZrJTMQZbD3xBlGn1we5xqpZwDDKxCWhTW1z9rWS1YVNVv/rg/lgVyyL4Vh2P
# DATA s+g4fan+GL0E7S5k/jvGAwCpHPE1rAaKmbBTR81IfauuzegOpyRxddqmcMTORjNYOvhYK6r00VWtjh/c7/Vf2n4Tacj9nXEwm069
# DATA A+MuxQdKyNTNHGTq3gt4uzzRXi1gHhwNe+pUO/UtsmjLqq+wz2m2A9POD2jSbz7YmkTjvurYbKwmSZGWw5malNFoANN9E6b7YTro
# DATA ztAceTgYofSfpeTfHSG1j3qT9BQoDvj1wQyr9TKbI+qNMlrKXjYFtEJ1g1Cy6wzOluo42H0RuAaBjLojJaL3QQlOs36Z/WfGuwwb
# DATA 7sH9QyXKw04cuydK7S45FaD1pVsC1GtzR6n6VMEHeu2drthEZPDNGlL2P0pPxvdAXn+Zds+gQ9H/+0/RpfpPq6Z7vQxECc4T83LF
# DATA 9G2zf+D2f+D287g9bcsrMPl3zOOvxuLnc/j/gRj8O+bvC7H3y3H3r4W5046UwzcM/V/OCUKCP593Kko/yjPNQdc02yR1nmoRubvm
# DATA n3LIINekdpijQw6AVGNX2wrVKrxEPAXd/gSZLyrwvInA6UGRRrPgHNVpgyydIJT/iWLaamcN6siA1SD6J1kvOpj1B1MYAdDHnIas
# DATA evosh09Q2tL90yOAFixH72p5IPcFAhIHRsPBWTPamGoZrgt5voHjw8QptoWaZmvW1qJA2gMOg+pF7CIsSgPFAjjreY44RtFOlr2I
# DATA fqj2CjhraePCcTYYo64KOhmlh4ewSiCQpIfZ9MyM8LPRbGJ5NA9NSTp5NJkNjah5AM5O2aQZrXOiIZhSGMdsDNIKyJl6F8Iez1GG
# DATA UQUghcIIhCRFHnIokw7Opv0uSjdqbNlkCjb+IzWEFPwvtGsb1NU9zrovUOWJph1Uezqd+e8/+d9yHitoedEv6P9j712XHDmu/d5X
# DATA KYeszW4RwKAK927O6AxvEr1JiuZQYjhEfSgAhUZpABRYBXRPa/ZE6OK9dRxyHDl8Is6OcITtcMQ53ylt0R7rQkXYL9D9CvtJzvqv
# DATA lZmVVbg0uqe755YSyQYKVVl5z5UrM/+/bJDMKRy2J60yq3nvoPw9XpdnxQtK2ClSrsLCE4jqMV4RTamkRjpQ9rhSWw9j6osmUYXt
# DATA QFBMYChL3s7ymFObWHBh0zN0h8kRjw8GqIo1v/ducjITMw8ZKTvLBlRjsGOtFDWpp3JLBiOcokqtHD3cIJKKPk4yKVrsKUzZxH8Y
# DATA RfO8UYeDAWz/SYLGMBjw9SMEFEMhEcJLnJk0eiCcrOZ9nPB9Sy41uj1KuciQl6ZFIdA5IjyOdCdB1ecj9DbxQpJAQdvNhXJsSZWb
# DATA q7lqrbpVRo/IWEQSTygwkxUjnrwUCvIDirHZuJRB3AO78YbSwXg4XkIllMb6XOkwRBRr3tvofGTvAYokxbgYUd+iqiu9B+e3+Dep
# DATA Usrav/I0Z7fBZqcZzo5m8q0Z+1ex9a/B1C8aTWTvf+dxP3lE5svPgK/pcy2t0pUneOgxWTzJZFLtRzQXjpP0IJtS0OMnCPfxNEyp
# DATA NhzUD7HCcZTC9XNwHKZ71eo8nEfp/uEgmdAjconssv1D9F8Hfmf+6I5fa7c8+QVh7R9ilzl1+SfVkzScH/SpBj6sUtqGT8LHEkw8
# DATA owYSLw6h7V9dYuso2XpRNRmNKEEHtSCIpk/CgzHCecz3DMEC4UZSpco/eDijtnsQzB89kUpSiWfz5aIi+7cqeAJjzWOOonqXvrMm
# DATA fx8P44yG4VP6mV89mkSPDmm0OJpVecvfwSACJvrwp9Q649FpVbUvfZnmp2S0YFw9aDbnjw7nYhwcUE5Qn+n5NR9/D6UEDvz5Iy+j
# DATA Kc3Qs/JvJaPRecwWxZym9OrLqjTTcBgvM/WzfKlQDKQ8qicSp3arfkhTqYzCmSfMuz4sZeMBJjAqT2qmiencya88tqJJ3dQskx1T
# DATA K9VBBfVjtlCxlzuLhnex6PyTxysJ5eTbAUgVU0EcUMlgVBk+TubhgGaDB7VWS6dGzQGpcozIQMiqZA/GGIHUo8WLXClK16SKlC7q
# DATA ClO+dzmlZnFavPqYmjZqzEGjVKh8F9V9+VnXZSqaJxIP6q/3fsxTJB7GqVX+ZN+6iKJMfrK/Uod5Jn3g1+vfLlS6NlW6DbULr9/f
# DATA vR3nVRc1t9axKq6ubA2diFL8K9ZFib+KbkBN81BFlT9LJa6udiLU7KrZOKUvB/UnheDIVv/JYx25+hOTIVYu+N06hU2VLf5ZdMCW
# DATA Ew1TT3h+ZNr3URoPD4+oG6o1OGWFZlKvy901TpJ5ZlNnwMF0EEq5/duhNinUEagLVP6Pt5aRTp1fC1o6VMlAild0RKP4YzvgTr1u
# DATA Hql7tSY98mTsV8ZBZdyozFUXXl0kc3p87EvvJ6/D/ApmsgRUAWkZ4910vhfUmnh1pV1rHZ9UWjV82acevd5UMVV5sn84IUuIqgTc
# DATA roiA/EpdApM1KtVavdGiRw+n4SOVBr89GB+qSPUTap9TSmiDIx3sFjlfutNKg6IWcMYjan73gqhRXIIWsrP4bn5zQ95ML/FUrlOI
# DATA jXKAxSe5ZTxBBuuktTuD8ZN4elTJjo9MrWES2qHVXlUFCZeL5InMiSu8z0BGdNVUgIvzgzpV5AomTHt40qt6bfTpJiIySNkhXVhX
# DATA ywMXu8tp7F+cRNGMa7Jfa5Wqsl9vmW7FZNu6mvukxt4LycuO5GVT8jJYzUuda0GdKsTacYjmEsUEcb/A1gP+Iw0vUEMr/33C7pAL
# DATA c6HcTje93Qtl5FJe/bswgX9SNj0OjKVyWGqWT2rwBj2GeALfOIofRcPDn1XZB0PpPkSjrPoo5UMQNyinkdEbumjTLSCdHLIMQY8R
# DATA Cp58UiOTJtGdY1WYgW2UXbHXo/+YPWvoe5fTWXbgj1KP/t3Uv3ED5fC9GlkO9BpOK3ex2qzJi7TZooYgd4/io2UaGUMyvzoI2Rtq
# DATA hVPrBmnePpGqWpdfq6YSF9eFbul5X9poTRn8paxp1fNqzXevr9PqYe6QilHYuTHZmUrd90r317JjyS/yqDMs3kVZh5J7vENZptGc
# DATA ZoV7jQrVcyqUvXqFSpa6jTxGT2qDMB0+tkYWa9Rp81BfroXZMh3hCPcF9sV2c1Te680PMPuvDsbxZLiaTL6lBvd5pTZd0qT0sW0g
# DATA 8BUKCL/blacneXiCbfm2NdBb26bWm88t6mSb9G+D/m3DtCqVE9fPQgGwz67YXDYY6maAQSCl3lDSfDBbjCVP9oLZvqfTsqkkglWr
# DATA 7UnN+E3LdZ26AUoWOglzi6esAclAM/BjaMWojw8IEb5Ka5DrdNG2+apnD36dOq5TeuLFLnWUMlP1OLp7KbQShto8qcG3YKy94Cbr
# DATA Jd7EizmrJqIeW2pivl2iBQZrWyCHJZsBHxc6KzH37H7eU3VuSx1QKePxo7luRmm1hYZ0RydjPiyJ3uqAJmXci+oYHVBSFqcmjTwS
# DATA 1mTbesHGrrW01ayaXyDdivZFrrG0m3bq6oe4q8oLOOotuR9zEj/ewdwozVGo56B5UzyIHttZUp6P6eaom4eMuzUpFJpeHllGlIl6
# DATA fYdhQp71Qkw3aD64QyUp1A3PfAvwDTbdaoOwx5Rif+3VdzPQirH05tbArH7KaHCfHT0u+Q2ogYRHZe+ImLZb6qYpoEAmkWmxznTb
# DATA q5PKDU2zH5ZsW92SVsbWkl1Q7sLFIFBBejIpxCMHvjXP8pvcU0pTyDO67LwZhtk4Kmbwj8fxcBjNflJoQP9C8IDhbPGEmttj4wd7
# DATA xKa7PTfC/CB/X/OCpm9nZXdTwy653cLZ6Qnc0E+wNiKlPAqn8eT04B0ysRIalytfvPFh3Nd73z9KZskXb1Sm9IfDLbZ5ysshjcPx
# DATA JLOyKdi9PipfyuOSV6rstCrZ6/qdXmF2y01YTaIuaq6HxdGRYxyoiU8eYsMe7tcZnTsYgOUq381jabU+qw60ML6qGwpuDZ6p7Oaf
# DATA pB4791aXZqIbqkNtHk8m1TQ5udjKVjb1IpqbUtfdaDP/CZ24af9N1UEv4MLj8Mqt4An/pAuOushJOM/IKlEf7Am0XQN5YF6MK4uh
# DATA TMs4Lw4Qm8I4ulNlXGyztZ7UKAbRY+7JpQM/8O9UfR4bLR+RZTSIzZAsF/Plgk8klDNL5lS8S7+KZZs11iyOp4WLJH2sh911tqzU
# DATA aN3RmQr95P+YRsM43LNMtDZ1a/uPNzodbE9Do42+V3kViq1F2SSroxNXFjlFgemuZJNdZ3h+unH+WWqUDcxc7awszieN06XFfTXP
# DATA jS5ljGljdXN87Jevn0I2sNhQnCHumC0rBsPmaXkw0j7GlmWl6Afv2XMpu3oGJfNZm7Gr9aLZ4HrBeVjRVu7G+LBbRlwvPKr38sIp
# DATA TCgCcdOpqWZxeNg99TsnlzuRNfMf7sipKpl0z3lJM6um0XA5iIbVacLFIl+pdaxbE+PAv1P5zoFs+qAP4QjtJpzF09xllI/zh7wo
# DATA Eq/5RUdDTufotijNsKIXo8oOD7GPuTSV+WG5fGWlzuoV2ApQc8M+zU8fmtlG+aYnTworhnrXFnYI0h/v0XQy47VP7Ms7uHPn5OSk
# DATA dtKoJenRnaBer99RG7ywgejt5BFurHt1r92kf3jZFzXekw2A9J0vetKR5d9Tfs4P8HlEQxDvmWrUG8NmDxsf773FciW8W+gjv+35
# DATA vXEjOO5+P2ge+/Ux/bf7fb/9s8LDo2DUGDXkYUSxuCqa0QgZPXsiuzSRp8k8pyCZqP1tfGO+GYsqbv8Uv/C+uXx3ndr8ZK7ai84H
# DATA +Y4eswcgGvJa+KnZgGdlSa/uNZstr9FrekGrPmnUA8/vNqqNesfzm41ixgzbw35UX83VTsNrdBs/8jvtSRD41V7LC3x6vN49pr8f
# DATA IuhWPSgGFY1GPucxTxcecvq/1Wy16q0ov1g1Rd9YeSlC7frHzcCf1quB38Qrq70eR0ZFxPOlVlzxDUFQ94Kmf+wHjYnv+16r+6Og
# DATA 1/3ZR81Gz2v4VH2C7sSvd6rNzo+CdreYvO6gF4XhSpCdFuVKb+wH9Wm1Xad/jvGxSZcbze7Y9+lyq0X/HNPHUsz77X69OVoX8+bG
# DATA mqq2L1JFPcDJwsfKE3ygavghz+8PVGM51FPbg2+1W+1+AxeM94ke4f8dGoNm9Upw8K3Ij1pR51D52A6+1eq1O53WoVgYB9/qjwbd
# DATA AZ5gtzP9PGw3guGhLO8ffPHGg+goibwffkDThc/CMdmelfu8fSyjrrCaRWmMZ3WXttPt6J5q2G1JJlPepR+INekFRadzVwwBc7sZ
# DATA jdT85nsRtek4rEjQpaW5w7IjDMZZpVNrHp9UOuII44DVTrldpvdb/Vs0Uy2GWHaU22aeKpjVB7QPvThOFO6aF6xKMTn5Bow/gxg7
# DATA iR5fYnkgXwsQD2DJLBKnVf1yxo0HF215I0bRK1DfaMwWUltZSdpFxp3y7K3UMTYbbtJSebLa1n+Kpv7FG9i9R51EPFjwTvIZb4D0
# DATA /iX0xby798wWyNqXyyg9fcD7ApJ0L9u37jU330/T8LQ2SpPp3vrn7k8m9Kj1rNrL97fRKaQX9TNo4TVsB6TY8tzSe9P74o0DO4LT
# DATA aIrT2YId+yic73GghhXOcsYPo9OKNwonE1Tufe8xDvzTfyUAkcnnPWUPJBIgUn9AWb1nRepNaJTtHxqqMNNV6KXLycT7rrcnsaiN
# DATA wwwv26dL6goFJVcOrAgceDj6KVoELLZ/6D3BUeXBmGKl3nCZEPH4EzvVfKhekq1QsY/145k8rn84VHlRSH+2If0ViTdqyewoHp1q
# DATA bJXJFmyxWZOWEQ53r0YyPN3D5HnfFEUEgdp/uffFG98Sz+8Xb1DQEBuKJkC01nC3Op1BN+LbYSnIcXKyMUwxRi8d5mw53YuH+3lq
# DATA Pl5O+1G6x2F+AdE/+rWmc7Pw6FBtIt0TOTcELnoW9KYv3sDXO9Sc49mhPuYiZ1zeyGO/TBH9H376YU12XP6Aj4fQd6i3eW9DQ+/H
# DATA COcnFe8xAn6CwpBHQ7shydPvTSLWy/jijZCzIaxh9x80a9IJvun4ojVRjHFpMIkHD6lNYevpZ/E0SpaLvb19tHFEKo2OyajII0Xh
# DATA gPtO9qvKCokK1jd0KWA2gZfb+ZTMsKF5bzRDwlE2eICF8KYQ+njvmCL9odJaoTCyZX8aU0FWvOiYi+0ePcYfa1CNob/vysasPVXU
# DATA HBBNx2kq9CPQO+LF6d4+hT/DDU9UVP8lovdjOXARHkc/oUjW6MH3wsF4T23+5BdNyGjOQhGj496FIoSviM+Pf6Le+C+kB4wz/rvH
# DATA N9Ab9XM//okuJcp/7I6HLue+hC/XT1nJku+v0agyWQ6jTEUj7xDpV3qf2SS3uK+l7VHC1tY3RO0BN9q9U6h1mmeKlR/v/C5VzAeS
# DATA HOpg5DPOGz051FHdyx9fUzZcX/A+nZzryCr9eYfsoATIXWRU09R27xixADv4rrf29gPvx7Uafx5W1t1hCoos4AzJ5Hhw92olRiJd
# DATA yCL0bvkzJlvNPvTlfKg3kxc28Kt8f1tte1+/x/1QnpGweEt7praz40woGRTHUY1b+BP5t1i9zYJXsY4nj/IKzrdkutjoJ5Mp5uHN
# DATA RSgPUxmaUFCICGTFBvjijXU7+exo8e8SMf4oEeBikODz+iC/655Yvq2ronzyxq6jygTJNXIt+2VbtA9UXL6AhOeUbA+pbSYKm2rO
# DATA hvzUEVC1R38l+252RJNBmD4em/GeeS9dLNUy3Vo21KtDc6Bifc1Ctcnrjao7On9grpoRmr+pnlxuoFGf5lZsjPEt+nu5u5em+YFo
# DATA mZrs50xmfWIO+buSi97f/R3FGhWC+q/pHv1JPkxOovQdyrw9k8XUEDIWX9OvLDxNVhISzvUaJybovvqhZzUIZGqx0tEFu2qw6CLE
# DATA e+i63WkWY5PXRE7Lvvc3f+Pt6ajdvatjgkhxQKYKmHy7e1clBfUXt8iyHr35X3AUpLnxx31Jy5tvSkEpYwcrhzr7+Utu7uDbvtyR
# DATA Byv5gd6xno9ISqlIyhA3mEDkt311T2n4kLC4lnIMo4wHDip5XaJrGiO3I7RFq1IgOaYctzbgwkP0IsRRVVPKZB3IfrHG4UZlcezt
# DATA 373HNuMXb7xvDoWhmby5B7Pvizek6VH6vyPfeQ7IzX2RvI9tdXvB/ptI8P/6fe0L+t/sXT1LTpIFu1q9cOH5NGN5UwLgw2YUAD20
# DATA /j1kPN0p3pq/y+d3/e9/tB7UEdrhucFUGrfMAPMDme5gtjuYfdHBbHcg+5U+kO0Vthurc9Av9EFt4znjnwsnACfW8e0Hc1bLw8gW
# DATA DwEb0ae389t5WzGfk3uxznO/LKcaLxJusR2lHH/xON97i3racjPUi2SIhlmp6Mp6l7WCJxfCCX8rHlQvL15Jkx4kyFx50+lsoKOh
# DATA /Nj3frCy9sVmKtkDpYP/1jP8hdPBGTC/x0V7QOUOPRgqL9hD6eIUm4rN83PRDcjGIZ+I1TXKUxsuaFrIx5GXfRrXPHh1PcxBKMwv
# DATA OR68SylO0pr3g3k043O+Iz67Tw+pw/xcWT0Ka4xaR3XSk20IjGHC3fRmMBYooJnSDdhReccr+bi1jgCfJ+Zok7VARvYRzqUZGZ6/
# DATA xTFnVDic7maig/fJ0rh7vRkus/qRvCOmn5ZzmA1ZzYMtxT9mbFIlIzh5qMUMYampZkPmcsISAKNlSlbEclUN4dU8bGtCcNabs94u
# DATA st6KNczp6zh9ncuabRsNxJvS3XmALWyWHAReA98mhPOMAs/z03jbNlxid59ny9UVLDle/2D7A4siakuOvsaFjU5I7Fj2CehMVl7A
# DATA ven+W+IT1Q1wxutRKCQJzTxnuqv8CnvFePtHrcWbiLSGNSWfN0Th4jTk/UYttZkkmvPuo5r07Hc4jqWoihfCVAd82yGi+ikTT3PB
# DATA RLNRa19jNMUzQj9rLw1feEscrSpS+h4TKfPQWwl3+HnkArz5nn8Q1N+6kyirsHxPS93T2nKPX1c30Yf8rjsSrTwpylbXualWwejB
# DATA vBksbMkjMhv4CTYk0im9l/cEq3Sq1VCMXrpq5pek54mP+UVzGqcXkgN3JAjMn1RuyTqtHUp+Se9QM1fuWQZniAmZ1QHY0lRsNEqz
# DATA X1KqIPxiDMqPaDCk/lmMRu21tto/xthoxi2fDUUz0Map2JE17/5w6PGZWGUWZHr4zG1I70OsoShVT0wEzEi7hGy6OHrZKBVDnHoc
# DATA vBG7MOht8+Vkwj8usQxLg3qcauP/h1kkyjsiYiO6P3E/piwWiXktIqXrPBZsM44CmSUwLNiURk+EeU2cYVpISZpJ56dVrthen0D4
# DATA 3urlMAb2I9bL5EzjDl6KhEvj1bea7QHQGc7OcL7IcC4ZSM5ydpbzdnP4BVCs/Izexo0jE828cKhaQ242lzQbMbgYnTdWRHwYLahA
# DATA Z0cibVeUXhQmWDLCuJUoCchcKVH0EMtGcsk/i+2KUgpqy+Jb4wbrz2khZ93YKcYNcZkZkUpYMNinBL3FUKLLYtjJaITtX5Dp474g
# DATA 88bJCf3sUQnJcMl5XfOUcQFJS4rdMcZd9DPJiDsGznNLvlJ8Vpyc4qC3CNmbeT/FcDUxI51JkZ20D9kpFw7IxoGQ5gn1WHnKMPJW
# DATA ecogG6IZdRpOMt4uBksHSTwiWyzTvdqQCm9MvRmXEidTTvlQCDMWFYcbkUynI5k7iRGj/WXJlKzGhVIXDGEVPPS0UsiWdL4bnnJP
# DATA vD2hKENxVaKMdRofKP/jKIooWcN4xNJ+NLuDoQaBQ+xhxD4EqlYL2YLBdGP6BU0Rv7AJ6H3GGB6P+YIIkC0rZsrCMUhVUSfEWHT9
# DATA 5alU6tMF6jM2iW5J5KdRtiaBYlYUqvCqoKqp6mSlst/yBKrwqGQTNEEeddJonRGLIq1oOxKEt3AY4+ydDHRipyoxSaq9n0L/ZUiZ
# DATA SHYh235IPuy8JRkT/MRD8bhqlzJDylC7p/JOsSf1VFpLnY7idMqLI+vmtpyozyhvZD4ORu8cx0jJTDJq69SCjPWcL35n4r+W+yk/
# DATA uDqSKaCm52EmtjD3Tt5HWtyTeleGPbAprUDcxodMjechm8eYGpDhSyUdLhcxuo0wZZ2uqVKeZPVT6VDAhRK3MVkIuK6mFBtT+7ez
# DATA 5ETqJ1oJNRH0kRBs1Ql+N+HwF9hXidyWtkgJmsOVwF0jj21il1h+BTR+KmVsaYgnBq6V8nQhpeKm7CMbiTJMUkhFjgPS2JERrijI
# DATA FrphniLMTstqsmY+YcvKWna+2MyvoLX/5EnFMHQWR4Dzpqc2Qef/O//V2R/Ovjn772dfK0bO12d/of9/df5b7+yfwLShH35O//52
# DATA FZ3zX+iHp3TTU9zP8Ju/nP/m7GuPvvzOQHT+SIHKZf4K0M4vz39T8c7/LT1Hz+A20HO+oTf9iTE+/0A/CFPnT2dPz3+tI/NXuuUP
# DATA AuoBbMexdF6C2Qw6ZRxfog6nT38WBdHsoyihcNJ4oE2wmvfeo/lExucJ94iR9A3ZOJ5TbzGxvBG6c8Qq4jzKfQb5XCiZTNT4RC/V
# DATA Mr9boTpYTlThqZbi0DrF+Y3uQW4brLOuZG4Or5NXHXMrTLr8cvmBiehNm7s/lO88ol8zYYfHNTWsJ2pzKwZTB9jZsdiuH7GDtfeI
# DATA rU8UTiV3MbLxi9yDQyaLooJhOqbxhPOR5fazBWaqpd3KGqmJIMyhlHixwte5uPptdmiuaVnPC7NzcTIcZ8dZAjdhCWjgzhUNgNfE
# DATA uXlrg/+NjP07Df2XHflvZ+CX6rmaDzmD58VrXTcB47FygFE8xVevSe8qyINeN52rlURVeJRnKV6qwDeRZE2m8qbiKQlsLx2fLsZT
# DATA DkUOmHAG7YrgUUWWL0RSRzxhvMwSK7VQSV8gtxfKPyvH5EbhcYJRQbFmdIzxAoGb8HBKD2qLQZ2rO8ztBSEWwfcDM+IknC1st9gg
# DATA mTvGjmPsOMbOTTJ2dh1Vdprm7Gol37LJfxWL/zoMfkfbcbQdR9txtB1H23G0HUfbcbQdR9txtB1H23G0HUfbcbQdR9txtB1H23G0
# DATA HUfbcbQdR9txtB1H23G0HUfbcbQdR9txtJ0XibYTtMKr0nY6o9Zo8BLRdlbXnndi7nDuqtzDrkyP39VuFxTSWs1Srjfb3SI3J4q6
# DATA IwU2wuFGit6AA220WQZkwKEGEgxLZfjNdhHi06AMX4NG6jS9ZlD3QLfxW72J3617QbtE7Wn7rVa3v0rKaTa8pt/7kd9rjpvd4yBo
# DATA Tf2O79V/5Ncb42bnuOEXozAIhs1+f00iWt16ngg/6JlENIoBBL1g2Fol9lDGes1OMFa5aNFzzAMr9Jz2Feg5XGMteg5V/gI9p9Xs
# DATA hleh57SG0cjP6TntoO13hoaeM+j2R8NeTs9pt1t+9+bpOaqOV7kam3GhIQQdPdwWblrnqGrwOFLpHZ9UumxJFdaYWoPx4c6knfLb
# DATA lIPbdm2JiaHuwtGC68Ht2CGu4nbURLNrjFWU8SHv5BiHw+TkoO7Bu1H3dEkWAD3crldfod3uxjTvyPpJIddLNxXWymQ4L8FwDjfs
# DATA B1gdrRQlaZ2nVtZtt4Ssuho1tOmGkteMponfxa5U1WdspvgUSvsCG7GQeXZhqsToyQusEEfZcZQdR9lxlB1H2XGUHUfZcZQdR9lx
# DATA lB1H2XGUndeLshOPxH7Dugdq/GP7m9Sdu2rEVAOX/Fbhurh/+MTC9DyWfENm3OVgcOrIBPMmPQH8zhdvvLn6DlWpD/WAol6yemN+
# DATA izqgQXexnXuoIEEf4xiXtHw25SenfDpHv7UcpZr3b9QZeOtQGh88Q1lThTJRqOob6IfvbhvxrykrjM1sksqLU7XFo0WeZuodv3jj
# DATA Q+vknUkGdZcqBTLRLZ3zcUfQ3RH0nY+gFw+EubPo7iz66qnBjXqbL8IZ9VIdL7QWW5yGPX8sQIvKnOVqKUr4Nh5GYVZAt/CJaChb
# DATA glzEI01G3ZmcE9ZKKryVrnRadtcz6JwE1mfEWM7ifEoSlF4FF+pc9Pj6LLuI+K05DKp2Wa3q1yvbFVWQPyk1eCUcrn/M9czNFd5u
# DATA C/nPiMMx0YszK6s3q7wbg5il0eVzUePdusN0n/ZTKwrtsChxuBMdmtzH4q6bBN1Vl8phfU993ny3HK9nlTv+tPlO7nOVzOwg2nyf
# DATA 9Nucfv60RVReDppqOXexQ201dwwxW7TcCzUB/nNb1jX/Bd567ur0PEA+6Twv51lJbJPd+qYXEKuaa1665Nz453/8DyYd5Yhb+T9n
# DATA iVL0OZNwnuuvqqVE3pOWLiGRABstYSmGGZTgWYsaaqUx1UKGMoXzOdVJ1teljhmtjyaxs4Uc/4ce6wL6R1qHlrWqefFDi8yeUOVW
# DATA h8WVz8tumfnJZ9008oPVxnGGyyopJmf00Uu6wL5gril0rwUCKKu2XqqI8op62QL6+/+2uYB0pZfi+QDFQBU50wX02UlCbTSljs3T
# DATA p/wyZYJQn7ScwRNJQ9K85n1AozyMnGlyLIIUlAYWHICwwVHE3SoKSPYPq3KKtLqFKq1nLxWTglsrF9MtXLZY/v1/2VwsqouRUhE5
# DATA 0EGS0mTEtJyZmgjLZZ7m9FnTlXWV5ZM3D9GwhmI6iILviPrw5EQVUdGOZGl2NosL46B1OV7AiH72UrJTdGsFlffLl+7hfru5pHQf
# DATA L0X1eZhOPd7dlXdxJ7gmcJzhMbSwqWSOqGB4/QJ9XSTD/WwoUhoRq8dCZzqaAYIjJaBmA/2IyR3xQjQ5sDvW/pmpE89ePnkybq10
# DATA nmUE+n/+afcR6B0MslEqQ4KlAz5lu5rilT5UljY3qXDC6uWhN13S+DMJU+yTm0M+GRnt/UiMRzXAkIkEhoE0G5T4s5dEIbovQ1P5
# DATA j7s2lQfJaOH1Ue1DlE7erWGM71MWTaFlA82YAY08mBywInQ4/GmI/TmqxmcorJTt8XgaT3DeADkFlQqy1L9cxqJWAxVEFlaRAtSK
# DATA 0NfQVArJuFIBFY1A8WjaRqC5Itl97+NE+x61phDPPpRPMEmFyogBOuFOXBesEv55FnbQ6yHu4uDczpV2BVea85y9Jp6zy/K6Xwh1
# DATA x8L+y+3Ybplz00C6wFZNsiiP2Km1kdz9gqpAvkSiaRdpQ9v7Hm+C4r3aSq6d5b1WRnQT0Xs15eo2o44tzhdMgmqebySx2ZlUEd+R
# DATA qEGeJMZxkTuZFLVPOYSngHIbmb+8oCveMhN8KWQBKRjsjJAkZGUt7DW1Rulzc53M9TSvpAX+MTxdsyNAAwUwLro9RgrcUhbU4Bul
# DATA mXVg5ERhVueioraSqMc+E7JYF1JamPfA+vawERd6m8eF+iCb2SSzeLsqNFFneYMX7UKdW8jh2utkPNpBOPPRmY87m492XXPrsG4d
# DATA 9hmtxo1G6s2sw34k3E9bKTonHj4fUsVtUMJ57w+qFx8bLCxzqp9yvLa6dWW9MF9IypfHNq0t2ssb9mrNpvtLjvbSUsKmpwru34JP
# DATA e9MTZTdl2c266bmy96zsFdy4clooBd5khZiiOg3jIdcHWWj67ltavlIVi7oX/HLZcyoscXXOVJPOy4vgOGSu+Xu2ReVp7j116rZN
# DATA JS4z/eodKOK8qWB6WmhALy9CHAtNCyahztHTZ8pSTSb2W6K5Hk9kxskmeKRnUgYiSe3HrFYt2VSg0OgZPPeu7kjQt9jDs6cEQngC
# DATA YEx29dTnsMSl75F1x6G4lnlfOcUEwt1YoFFP3ElWCy6fN653Gud1Ld9bCI6n7qOopEslfDED/NWxki04IEshJdMCG/A/KIjfN2d/
# DATA oX//fPYUGL6nHr4xlu8bsP7+cvY1oHyrdMD/dvZXJv79Xt399OyPHoMCf3f2p/P/6+wPZ1+d/5Ke/ZMK9I8KIfjH81/hGv32zfnP
# DATA PfoCIqGAAEEmRBzkOQALmRv4VwcDfBms/kLfPYpOyHbgSfQ8hHStggCgV5+OIB/Rh2SXxoBQx4dV2fsKq5v0mXmguue+7rR0n72c
# DATA 82vQhDg8MjIG4j+JFsv5VgTgfUhdeMNlhs0u1J4dALBg7+te4rb5f6vFcnP0P7awmLCS31qob2We+Z3oNJrHEVkb+v731AUPKkNA
# DATA aCfpNWMAWT2MkdDLBY//6owWNTFHAty1CK8fBUh9DRbBqc3P4hE6HYbBM8QZ2+XS5BE0dCI+uyymPAxW1ELq3AYLbGFYsvS//Jip
# DATA zSd674muaOJSJUucGTeYxsVHsxUs4O7VcrOts9LwnhcccPfEOEigsxCuz0LQaMArGQavhxPw1oyCG7AJdjIJLm0R3K5BIFW0nB3G
# DATA DHhhWtVNIAGtVKvlrw1R1HAxdl88PPWO0nC4DBX0L8tXHyBjWFxjY9RgcVHiVDZ9Ymn+mF1PWGtjWcRsHg0w8htTbCc4oBnXWZmb
# DATA EpzJPjrKwBHwZVwBq8moisrJ/SzVoZoHFVscnw3FcoCPjgl4Kg6KrYbkz1O6lPFaqiptZb7JIiFHlm802VfzPo4AkJMLsmnvwRJm
# DATA SJosj8beckbFtJAz7PzizGEEHUbQYQRvECO48zC00yTpsgb1rc4RrjJFuM4ZgqMKOqqgowo6qqCjCjqqoKMKOqqgowo6qqCjCjqq
# DATA oKMKOqqgowo6qqCjCjqqoKMKOqqgowo6qqCjCjqqoKMKOqqgowo6quALQxWMOtFw5F+RKuh3g6gZvkRUwfIK9E5MwSI8r9e04Hmd
# DATA uoHndYr5OhxEzeFoDX2vHdj0vWZO32v3NuZtXjBTv971Ar/j+X7T63a8XqvqtwLPb/pUXnQ16HjdbgnL12n3uv3uOixfIcq8D3M1
# DATA vvRCC3nod0x8W0XAZD1qDzprng+CIH++Uc+Rid3dnm/IK1V+tYI8v3Z7vtmy4t+w8nvH97e6FvKx2ehc9v1+2y5vP49/Y8f42/VF
# DATA ypYfb+72eLtjJ9+GPe6Y/fKISn67d9n3F3OvvsPrLwOJlEaiIZHSl1mQyEEnHHb8IiTSPGIgkUG90W/1CpDIoN/stFs5JHJQH9aH
# DATA IwOJbA7a3W4zh0SO/GG7O7pxSOQM/Xk1e3iar3PIEcrj6BrWHQLL1aFtLrYfzGu1RVgwfeRlNJvBtH7NHhaV4XYwNWgXFe17KxT7
# DATA Tm3l7EasLERUL3ooLqKUoL5HZcnjXXOt1raohp6dLeo2T+9qKeaNnrVin3zB0VoCOm7ZoaD2I0g6qhn9MI0OIHq5mdJo8qFSSu4W
# DATA 069cyJWt5cXOFFNkYg+uVBMxn4JdcopDcBRIR4F0FEhHgXQUSEeBdBRIR4F0FEhHgXQUSEeBfM0okKsQx2l4dBemHvXqOGNGSb4j
# DATA X/VJFmSCQi5+ZCsKoFW9SU9TXXgfGyL3/P03v3jjf/9jjYmH99fqDPAzexJ+OJfDBngjBbNvwgkQzv/6SsJ5By2ejy9Nw9lyFLJO
# DATA v5zqkvOI1JzncvQNh6pCQS5Ej+hGPvxJ5kBGQ1uBkFg4o+NO37vT9xecvl9zhMudxXdn8Z/lLP5GPc4bPaMviogJH0TOj3vLsPJd
# DATA o8/5/OVjbkOrU0Y7yKiaKIz4gKyyOvem031FSdQtdMYOkFzQTwdhujVzwShadlpFJclpPJN1r7pSneRVIKU3if02/OtmnqIZlO2q
# DATA ctl4W4GYqNvXTOyD1rrIB1bUu4WI12utzVE3470ddX1R1aO9YXSURjRVvyAFVlgmBfY1k4L22uxv2LnvB1syf6NCp24lqNHSQbys
# DATA 6pzWiMs8RLozldasj7gXzD7Mmxbrmwy9KsaR9f5p3sjtG1hkX+TzpbijbCFdiTwpeEZTJfIw+Ob+qaAcC/2S1h1g/QodGvUjZAQq
# DATA AxHzvbmYDcMYcz9+DBrCLKlxEp7KwCPFyWN/poU1jpYhjTiLKGJpcCVs8SV1cGR+4Wi9EgVZE6MdBDxfvQPrpVHRWdbOsr7Asi4Z
# DATA Tc6qdlZ1warezFZ6kZSviq0gNPllxK9+CP6eUTvCKnaudcR6MnCJV4x+k6CLo2mczVmCxvvM0FXYeGfdnAieuZOIyawVT+/ZwKgU
# DATA zbGMn9IjqD9li7pIcFwRuzL30dD/fqykj8ZJGv8sMZI3SsE/9LJwBL5OlJJRxBJMplSyeZIrpLNEEYtGqVlEFGanPPKOk2kEUR6e
# DATA TZDdVxFOhkjx4F4arWlgjWFCcGeVUW5hFUGpgWOrwoYpQ8G2GUY67h9CmKfYAWLrhFLtAQ8y7xCNTbSchWzYUL2qeW/HswR1iJ7R
# DATA mF1tCMyiRws2JHlJBRmk+tEkg9tK9bDKBJIqMOWXWaDQdcbE2rT9rQ1GmCRHOoWf4kSzlJtUq8KcLcaCLNQ/4lysyHAXRMJrcqrU
# DATA 8rnHzx5KTcvHDb0pUuRfM9Z/HUGqnROhFUkZesq4MI/PggG3jexdZNsS9YnIeUmriE6VZBZG6vmUuzBJo6iCifxsPy8PdgDmxmm4
# DATA MIJh+XhEeUEVltIoE06lp0RZhl2uE+wv4aqMIzSpXaFPM/jGOTaPKIAFGYfxEDTYmvduwk0Sw59RJoMInDIYR+j8Uis2KwQktqwu
# DATA 1H01cemHqrCXloK+WU8xTFJzRQaJU7mgRfbV5Kz4PP9YnHrpxanCtKrOUyDVn+V9GRMLpObmUHsls/9M7/MNeWISnip0eNFUyagn
# DATA vN53BjyEMq5nGE+l/7neN2Cb4r2P9diBNM2j2SCeXO9beA/3e7oF6SU0uwe93ve1BGAxisyeIWp4bEvOqLUV33VnObkxBu2rN79y
# DATA JFo3tdpdMthNpF75idRl0bMvloSw2dN7EwzTcmZfO8F0jdLxxfzSSYGgIBrA7IYs6gpvweu+WDrKL6OE6I64Ba+wsVwb4bncquSL
# DATA mWzUVibH+bS34h1BoTmf02AW5oWYAGOrlZmHDmgKbOvHimorJk3ZojQrzb0JJU+Ctr9FQLdQa8l6OY4uFpJGnZyGcw1y2KkM1pTo
# DATA J2nEHvWCGnYWZZlmFb5GpltOuOqHD6O0gLf6r2dfgzp1/vOzvygG1R8Yc/XV+f/JuKr/6Z3/PTBTZ79bhVv9J9CqGEgFjtXPz/+9
# DATA d/b789+c/fXs6/NfU6BPK97Z/6Bb/kzff4nv3tk3JjRQszYDr34JrhX91zGtXgaSLdVhPA9nA1UwlsAOGfcsQwRZWzGPBEO4JiBX
# DATA rjonzMnEpTFjpwX3SyMF5hnKpQR9nOyvFUYe9RwZe7q2IqzexgZatJMInYUDWNkGqHQCt02vKpfIzbGrIAk9LL13LbKKq5i58V2u
# DATA cDcDq6JRb642/aKWYpNwMgxPeR8h1Y+HkQNWXVRu186pehvNgEtgHqU4K8qK9TiON2LAtpy+9Mh2h5aJWgWxtuDp9X6I5R+l0TCO
# DATA 4I0Go4D61CiFtytfTlH9Yjwjc2gpOexNl5n0Z2KGnQrVexDPoxWK1S41dbM9U2p6z4tetUsiHLfKWQFXtgI0puoKg/9r4Xm6pYH/
# DATA 2sf9nYb9XUf92xr0pTIWU28G+efVWG6CPlVMojeOJnNYJ2R4AMFsIpcnOB2fLsZTrMhK0g9kqIXQO064LPgD0NLIFlkdpQ4TNKMP
# DATA yMAPj2mczHR2pCJtxlsPsCabLllLkeI/jQ0XaDt7Su2OgIcpwhJ1xGe6ZCDm2G8YzMXFYRkEjCfisSATE6KK9j8smBe8D1BvolAo
# DATA IH4JCygANUX/YE8F7Dy9Rr5cJJCHGjCpywGmHGDKAaZuDjB10Tiy01xmd1P3Fq32qxjt12OzO5KUI0k5kpQjSTmSlCNJOZKUI0k5
# DATA kpQjSTmSlCNJOZKUI0k5kpQjSTmSlCNJOZKUI0k5kpQjSTmSlCNJOZKUI0k5kpQjSb0wJKl2o9kOOlckSY1Go9Zw8BKRpIorzztx
# DATA pOxMCdpeo9P9stqs+t2u57ea1aAe0F/f8+mfZs+jr8UcGkTdfqO1yoPqdbwA1KeG59e706of0D9N9bUEgqJMrg/660BQfk8CpvTH
# DATA NHBr9FHDQi81Wm2r6BUHSaBERXBV1AyjVrQS0WbH94IuJbvl+Y1g2uhW/WZLfVuJZ9Tvj9bGs7Fav+otr9lqjdt1/yO/GXjNrj9u
# DATA ab04i4HVagbRuiBXa2y7STFt+D/qNad1L2hV6R+/Ow3oNVQsXXyuBl36svpD6aXdbrsRDLa89DKoI2khGnUkjc1CHfXrHT8YFlFH
# DATA I/6fjTqir+GoXkAdjfzhqO/nqKNOn7IqNKijYTho9Vo56qjbbNX91o2jjniHSZVND5slpCJbnH36GAk9+S81c3syYDONZGawDfLD
# DATA I1f+5h3oQwUnXNs44WTpbRVQZIW96pDnEVa2zdFD0cNd4UTa0gjKAXiXGK+3PLZ98N4IIbJK0PYFemJCb05PqXA7KNWOKtpi/mxO
# DATA jiMJOZKQIwk5kpAjCTmSkCMJOZKQIwk5kpAjCTmS0GtPEhopjhAfvaIEV07ujr4jl8anQ1k9BOyHjJtKZn7KQrYo+eqpuXoaUY+s
# DATA Lmv60PsIlwlCozcph46YD/Q5xVAunhRBROr3BxQ8/5yt/fmDGUSRYCzQ+/i+07X3fZYswomc7+O7PgoX4xr7DfZGb568mb15qm62
# DATA OUP5SRZ3VNodlS4elbbONbkD0+7A9GYpvxfgIDXOpI7yah6eeiF+L8ibL1j5ROozSsBIhKPeVPAzZPMmk+Rk+1nfafyIjx/P0yQZ
# DATA 6fPH0Bk3DZXGX2xFWaZR9gza5jQipqdIyoKyBOnTxy3ve9lyjk41GqoWHWeGfESWjQIbpTTgoXZCTm8SL7CIk9DkIWMlbAGZDNLl
# DATA tH8IbZh4xuexM3OoegRn7zGf3/0cLtyCgknKmu6ioJ0NkoSfGCznkNmWc83bFLTfgQ2Rnso+Oo+HqDxpI4isQwUQQXKpzqJomOnu
# DATA TNKbLVIxl6kcx8lkyGddEXNKLM2BWQ4cpTLCb0cU5ckpC4WbbDNlJ8o6LJOOU+laFZ3TgIncJFkg6XSpn5xMvHCSJXwweKtE+PtU
# DATA vbnpyLFtemuUWoXHgs19tjY5u/TNcaZP0Z+gLqJ7ZnGfCc73oh+veayonvfkA2xIiSCPHk/4ZC7Oxmc17x1Wa+a662lADaoDRR6h
# DATA IrXhEBuBOCxzDFGp+oeLi0TdOec4zic0kBhdQWxHxfl3D0dp8DJqOuGUX0cDHZeOkoQfLBdSuNhWM1engUUn3pz3xpVJrChcqBY/
# DATA g0w9w3Eyo2j+UMIT/wqHSKbhxM6S2JznDtPp1XTN3xYhamQdNf5LC5ujEV63svmnyHwU3gjOaemdbkDQPGdbiuARioINUS/XI7gB
# DATA TXOjzMhGzUy1PXSzGPNuQOL8Pnf7xlZSahK3pwT+6hzkzgNxMwo3oyjOKMpVyk0r3LRi5+nDxunHzU0rHiArchyOREdPKV54bcDb
# DATA QJSKI40us+fL2zu6CIupHzAdlrmQ0znqVwGS1jdjPXPXHt3yff3F2/v2RZG1HzQRLlzMKZ7ddXFutqwo93YlqLK/kQklk8UOsVS3
# DATA 54hX9b1gUq1Ezc7MRpGQuiVq4vSknwteyR0iqR80sTQXcru21rkoosG2iG4Eocr8FaOV1dJeXhqqNLU4K4odGc3S96lvodbhHZm5
# DATA eMVrd7/tmXrrTcmkzrxGU91zAv80zfJpIh0dpego+SmNzML0W7hZfCN3R/xV6bDJzNRATmNWq40HpqvDG6NHsmaipwxYBsOkHmGV
# DATA pMxYnsvqy7SAbSasMnlaViEw6c+nJRI7dfog0ipoO1BOXx3b29F3nO293ZvvDO1X0tC+LGXnOQuh8g7gfIPsqgFqQ2hYdDDUHmyj
# DATA FypJ2Eyhea7yqS+FrCD/95qZRiWh1+smGq1I5a7lGe0gXmvto84lbPEtgnBlEo4qhqDDVtYyGysDq1RPsVNcSlbtFn9r3Lj3fhpj
# DATA 3Qa7FNmLSJfAqI8fwYZh77+c52LaYVw0d2gCiVlgtG7ZRalqipCp6JOqgwy8hUuZPEUDhqallkfVWC0muna8H2DNCjEn+64Uc5Hd
# DATA NYsqFDtevzBtQjRG9bKMYpDiOBm2Z1urRSyfyktPOIu4JcJo9jvGlo+1zRKm/3J8H2AlSC3Q6elzVBRHDYsLe7xkMjGrfhRHBZ/E
# DATA CgQWwTZHlF62Ll9fG+1OixxEhtsAHB6LHfQfz74++9PZN+e/OHsK6M/ZH85/w1Af0IN+wQyfn9NvoAv9dhUetPLw2V/OfwPc0C/O
# DATA /nr+87Ovzn5PP/6aGUR/rHj06euzP1bpiacI2uN7vqF76B2CFtoIE6LQ8Zav6A10owMKvfgW9Q+hX8brxNybKFrYaUUWBHFJOlq1
# DATA OzWNjsBf1nLOsvCv6qsZ3FMWbS5Qpqk33soQemcciqqBJRnuOEKWda26hNsmCa0rl5ujCfGGgHEyNzd+ri6sZwqN4rybfj9eGE/w
# DATA NdOEBGrM9oL4iiyiz+vOEdqlxK6dJnTfE/A6QODVxbIfmZIXD36MPbRTT3aC17yPEqoBMwNCpEI8ht47JD2wRsAaHjDLQrXZJcTn
# DATA iWz6SOE+nDKPUZx1bHwJrBEisWV40PYqudmIWdPOnhc6aHsSHDTIjfSXGek1J+iKA/zr4Tq7rcH9Rsb2nYb2y43sNz+wS7VczYF8
# DATA o+vttZabAAXlKYOIFgWQrcZ5AY8bNmvqzX86vkuTdj7kxDgRXYAgwMT8O/NNsATGtBW1JZTfMg1nlLrMpFtSa4IXzNB0Tl3YbLET
# DATA Ngj21QIH+ZEPFNIopd4uH/RjWe7XC1sIhsXkGGJkCEBpJFllkMinAlSuWCN9AsxPMhJ0MV5EFdF7sECyY/Z4xCOPWtVDoaGcUEeB
# DATA PYNog7zBIEXeaYeoowc5epCjB90gPWi3MWVHqPnFNu8tG+9Xsd2f1XR37CDHDnLsIMcOcuwgxw5y7CDHDnLsIMcOcuwgxw5y7CDH
# DATA DnLsIMcOcuwgxw5y7CDHDnLsIMcOcuwgxw5y7CDHDnLsIMcOemHYQVF9VB8FV2QH+d3GoFV/idhBq+vOO/GDjkySeRdhkTUzbEXD
# DATA UX0Ta+beW4M4hf0vYJ9AEqLAPh0WaWB5A99XhKHC7e1684LbLc4Phe3RPR79VvV79LdO//Za36frE79Xp2ttL/CbdK1d7fSqQTMY
# DATA N3sfBQAWdbrjTnPqN1rVZmvcXheTZrAp4gpgdOeoUIGagY/I0BumVd+rHwuiZ0s2RqN+r70ekVRfqZ4U51ZQH7eb9Y+Q6mavddys
# DATA T5v1ZrVZp09lBFEv7PTb64IOLk8DkjqvaUDSfCwaECVj0GkUaUB+p9Ft9mwaUFBvdlvDAg0o6LYa7TCnAfVHw+ZwaGhArUan341y
# DATA GtBoNBh1BzdNA1JGyXrHh05rydZSIxE2rlW3WyEe3YxhJ7+3DP4xE6V1kyLtRsNct9KsNZn/EzD/Z3U9ql2MlDZurG5abBdOCOV4
# DATA mFaPMDUGz6I+jI4q1tq7/dkLevNHlW816q1Ou89uv/3K5pB6lwxKRzmbR4PLUom0zQvv4YpJZa3IbV4cV0vh4hOuZvTDNDoYhunD
# DATA zeyhPIcrdtQ32xwls1fqENtOjiTkSEKOJORIQo4k5EhCjiTkSEKOJORIQo4k5EhCry1JSJF+PrOOdeXnuYvnuMoYHuEGySlvyiNN
# DATA F8KOADQj0HkG0xrDfN5JpiyAvnLIm4+3YSlJ1KpCHFRJZur4mhakLR4UkzYqEzl90sKdcXZnnAtHbdxRZ3fU+YpHnTeKD97MEej3
# DATA Y9a64LO07IIsn57VR6FfNLmN29DjVoMLqg7VVyUZjlTuDaYXSTSbZ02HlV8xIs3dtdrcLVuk2ffrRZnm1hapax78IOmiei++8JbY
# DATA skZFWe7JBa71Q28l3JnaEtJtXu75lPo+hRfievLWnUSJBK55os3ZRWOLd8dbpNFD1oq88LEWv8g2A6YwaFg+ufjsHUnNDkLV7+n6
# DATA iSrrocq+vCrVH0VhtoRoNA7WDsI0F6h+sBBJPupJkmQhN8ixZsj6hEcQe4Y/6oTGrJr3Qx7cJtExVRp0gOhUpypsbsYKTpOkRngo
# DATA TcicrHmf8gKAmEbyAOstKmE/Gk5OUdBUEPGiIF8NmFbh2L6cI/XSJc5448h1iAP20HA04zn0A8liozrLhZ/R7GyZzSPRP2TF7HC2
# DATA HGEgTjGXkgDBRRrGoxGuLPuspx5jnKbAGLuzztZTIgSUhMXOAtevyjlfJ2/tzFfLfHX26mthr15W2/o5S/bwuna+ALtd2/o+jUZs
# DATA NLIByXZslktRMEch26JxfdtiPy+F3sVNyFqv1utrl7Zeq+l0VXnrfNFfm2NiUSjbJwJZlOtcLmrN5s8pmTQC1OSlIHpdzXtbdINo
# DATA liRiNVE4g4nyOUSERO4lw+DGmFEhOHJ1gxlFVleshZ/JhkvI5iGj7iG9QRNDLldxfqCFWIyqk3GHv16KJ4WcccaQM4ZKfarz5jlv
# DATA XrHv3GhFPWdBQ+YBA1ycTCais18Gdqt2Ema5hF/Ne1843WwlrZPnK2j5zdNkEA1B4xYpuiT9chmJL+dZ+Nz3YwN1NjTeBY2gmgk4
# DATA jReCmpaR1GMtF47Bkhv5Ubg8olHzUxqGNS2wwgGIWSLLPQrvgA4jHI3gFGNXSe7yNOP0BzOM9wvh1y4VLSKa9qMhRNCGUT+lEVmo
# DATA yDyEsgggdihtRVnL6J/LMwoOOKSqAD8oawoq0yDT1gWU4+CvScVZqsSnyQYYTqJ+mNa8D2E/IZpUSSlzQwUCG4boYIBE6E9EeG3M
# DATA wnjrhAz5Y2apFopLNgP1+ksq+HgEnbdphLW/eLAVRj5mVWuuPLMFPDjsRTZJ/hxQjmQ08o5oyNJJlH2S3mRJmToIodjI9Rh49fAk
# DATA PBXHlI6nKsNMu3U4+3gcoGBUzClfMlHghn+JVbgPlawhpDBTPlmgKq6pzgWwxgL1h3kjXp8iEG30OqtU80gjYwtkwpkPngtVQ3DK
# DATA tCwyYxJKfAwyCcs/xRP6uaL9UJyAHLYzCNP0lJUb71Oehey3UwEJYV7gcZrjcxyyJF+eSR9HMadK/MRK/RIuuaMkGVrudnlrQg2N
# DATA RsORtLViEV4N9o22fMqqj9THfPfSsG/E7bph32KXx9LAlX5hPAM4PhreAPT7bTDvlVyo2jpyA4zvz0sqpDfyJoZ7f4imIX0MjWuy
# DATA LScTYs71vo1PAX1uKIlYIZqHceo9hLc4XE3dTRLFX42pjgWXScJ0eATfuo2X+c8KI/MNQ11Ah/naO3t69k/nPz//zSpP5r/SfX84
# DATA +50gX/guJr+ACvPN2Z/p41fMknla8Qxf5unZn86+Aq7mKX6q6qeeevT1Kx0U3UYv/OX5rxRchuJx/vceM2Z+BzYNKDQOKvMSYBpn
# DATA mtm14oubRwkQ0GrkXojA9Dt6viZ+jyPeto1BTkHDWLuX5YVzcpcZ+Ch6eihczoZbKTP3+Zb8zY4xU5jNmZ7htikzq+Vyc4wZTqC5
# DATA 63sQEqe8nozK9w2h/WyAXtjvu0jD0+tEy1AbyMjGTkXAnGYasMZ4JoaCcHCZ7UV17VQZ0wkNYzLj+cSemDpkvuIpiNzHjzyuF96n
# DATA vD1A3LZH2B+5blO5sA+h0a6VvlFms2jBmubY+0FjeLbCkNlW8zbbKStt6HnxY7ZF39Fj3JD+TEO6xslcaSR/PXyytzeK38AgvtMY
# DATA vuMQftMjuNTFcrLzbZPPscXcBFKmnNCcLGM0J/KYU25GoULMwP3GcgPwdM2oSDNZrUUyDD9DhlWgJ47jlHExKCyNlaGUhxku4si4
# DATA IQpjNVQG1ktAZE5hbbFvV0I8km1mmCbQx/5EPG5HacTnASTb9VY35Vun0R9SCPz9Qh7JIcZ/zpLUshmKmJEodbAYB4txsJgbhMVc
# DATA MGbshoS/0LK9VfP8SpzqZzLOHR/G8WEcH8bxYRwfxvFhHB/G8WEcH8bxYRwfxvFhHB/G8WEcH8bxYRwfxvFhHB/G8WEcH8bxYRwf
# DATA xvFhHB/G8WEcH8bxYV4YPky70+w361fkw4xGo2A4eon4MOU1553oMHa2NOqe3+qMG53GcdBrfp++F3Ok3+l0msPV7GwFnt+tU4Z2
# DATA joNm+/v0vfgc1c1uX3FZuCylrKTgToXDEhR0JZq9Yhk3m6WI9KNepxxgEDSuGuCw3gs67ZUAu8H1xrDR9K83hk2pOtcXQ7tQqCyv
# DATA IQ+tQrlkgBtK2SqUa4mhXSjXEkO7UK4lhnahNCTw62splwzw4pZyLTG0C+VaYmgXyrXEsFAoreb1tpRLBnhxS7mWGBYK5TpiWCiU
# DATA 64hhK7Dacq9Yyn6jFKK6kKrcLw/+7ahRQnG1e82wuRaWtg461mo1LOiYhJ8aJJhlpOhQV/hpQevZAmh1e1YArd7lAygkodd+xiTs
# DATA FsBleGZio2memZh7Fs8sbLabjajIMxvx/2yeGX3tRaMCzyzqDsP+MOeZdfrtdqtteGbD9sAPuznPrDtohsGN88yU10NtaDAzIXHG
# DATA ky3JDgrLe6EXqc38rMsrlWsW/Yshlzlm34vIiI3DisSktBdlTXC2I5IXeYqhq3Xfi6Nhpi/rd8np22lyfBTttlTU2mVx2gq1vOps
# DATA +0x0HSm6nQOZyK+sHvoNa5FY3esHRS+Mrq68x3IcDpMTXojBilvd03XOytseOyx4Vmxmcxv20+lJrMrt+mYGmp2nF3g0rNwq1Ume
# DATA LAcOhOZAaA6E5kBoDoTmQGgOhOZAaA6E5kBoDoTmQGivNwjtsardMRXcXYUyw2dKdIWTpC7i6B4yQm4X1c271LFRndlD1Yrv1g/j
# DATA t/iJw/jNN/cf4yLfdhiP9k7iGVlXZIedzhfJd2HEfwooxvRHHM7+Y92C5ncZtMYgkL1m0Gv22p2g177DUdr/Dv9RUejfhQ34Q5q9
# DATA NwLpeP39w2HyWN5RfsVef//wCctm7vV/XP/Jvbv0rv1DkXzDhW9z0G/6h08iMtaVFpwVF+G/cYB7Kh77dLdSH50vadRT3d4TiR4q
# DATA x13180+TeLbHvRXlIPhwaAxvqh9lgXZvL6z0qTjCN/sVsh5zS16ldhLf3WjNTmIUzCS2K+RdaR5UbvQmSRvNHPFatvFlRoAD5Gj3
# DATA c2wlmA33JvH+oeRR8XdelaaJu+qK7/n1/eINGIJVfN7BvTU5PU2V7YlG1pmjn05ZxSmrrCqrmMPATl3FqatcUl1loyj2DaiufAo5
# DATA Lq0AMklY74M1u4zwyvMV8roNOh2bAnRVPEFeMuLEXIClUw/lPZL6XlCTXSHS+RaQrm3j6PwtMDo2X1D18QHzDxRFCUan7slhdPqh
# DATA FUZcW4J6JCbSZpYcj0nvwbt+0Z2+qAGTBXrRjayw+9lJNKFO9IJ7g7q6d0YmcOne3dF1XL3RyrlEX1pq3d9qRoOMRxlZD9HQSO0Z
# DATA eR0ysowsjpjvZakdJsntJtvDIjZelixTsHxHglOB/rZYjdBwyPl04rUgI3GmZHwoiaeeOnRvxGLonStqMePGPVv/h9LUoIKZ6EJh
# DATA i8zOTWujriqByU60uVdBMSQfS5zR6YzOVaMzty6c1emszuxCe/K5af09YNQQR5Jd3ECOovobo9MAyabxIE0sCbwlW6hK/y6k1jUb
# DATA gG6xqn1nBsW8RanBUENKWEpukEynUTqI9RjIlmsaYaUFGxd21v7jlM3vPRBvVf8UPrMIu0wwjBqAkrB/aTDFXoo1+lvqvNuqiarc
# DATA s6iJ/EkZp8rm0D/mBpC5wgefgU6LOBwVP1luEMFBHfm1tqfx+YITpD4XLU/rDtNR2k+tGHZwmqItgDUl98Xb7EBtnL/LBtymuwYJ
# DATA iBvUXI755nfyr5uf4UqEuz/Bhy3WpQzM2sITF6ptkmCQ2GLeFUoYez6kQaujnTnSgTolw+5gj7Ws7qi8tPOihAPi3TCmnYszmGtT
# DATA uuTbg3/++f/dNqkoR1vlrDLFlFQlVZB0cSrGGNl3PDKByaMtSR6EaNpXhd015Pmid384hDQePS0soAEaG9V+nigyPxnsFTzI5p+M
# DATA jkxE0cRk2Kb0lpr3djjLqYCzoUxK5af3QYTBSxp1GmQNJUgfO7lSvpZqzxWyt7k5ewt1UXIZ9rLY8JSQRTjR+XyfeTI0SMwrkmt6
# DATA Ys25FmITwCKeRjaUbT5Z8uyZ5pdLseiZgKQ8+t79eIq8GpG1lo0Bq2LTG5f8AF/nScYmes17D/BFvGYYZ4NlhgLikGRR8jpy2bS3
# DATA y+bv5rxVLVfnKnp86noX+KDz9F3s7Qm9xv/+xwZYSUPKEywezMAzPwE+iOrWkvKOykKm+JnnU4H24LSQ9ZdBRHOQmvcJddk09b4v
# DATA FVuqLwhQzEni84oe3BuH3tv2HThDKO4SnkmrTV417/v0NeKKTOV/bRX5ylm8vYcoZPPnNNDSJIOCSHUeG3N2RA2/KnpOOQsM2oFU
# DATA v1CZ5pKHsuKTSV8gd6OSwk8TKvQ4JoTy4MfQLsXJwIx1S0MTSDjTUKqKvIx+wxKKxI0z/SgWyVPwyI7jhFqIejiUnufF6Dzal+o8
# DATA /vUy5pVPPXjrQpAMpvpLYxwqNldAtoG0YSTTIWS7l03iOeUnNw7uWwA64+lNn/VNtUcQCqoY1UWJlbsm7yhaSNFxFmIhMUumES4c
# DATA LSPuOPB0PJOJCvVLi2vpPm5+8HuHxyUwkWJTtU23KG6NxUkiHbJkLXrjTBCaIpQcxSmNbicIRddjlrGNjcIvTdfR9FPV8skWZFVn
# DATA vJO6JpxWpN76WE3uKGw8MU2wkMtzB/QUjJ2Q7gU2azlzi+aKLBvb5oq5Ipl1jxqYWuDVQsIyfoupaJmv1NzG3PCkUGoXsZ5eBZdL
# DATA PttyLhfncllDUHBellffy7LRgfJCERUKRwVWR8qJzVrwJvECR5xZCYWRmKBYqtGEXTD5g3yehDP2eSMYXmSt8ov4SdbBD1mV5KMv
# DATA 996ijrTc3vTR98Lxuq6c5bPO5cuFcCLdYRknsXIkXdrvIEHtkLedzgY6KkrlMfe72WL2XB5rwBzWc/yF06NWYsbBvQdsk5sqAghy
# DATA ODs1q1bfT06AQz5Vdee7Hl9YwjtFVtV3vXfo/og6UxhDMEJyS/i7mITFU65ws+xEZg8LbLTzeOmY9fdjRXTVbCrAaEOyzcDHhXYZ
# DATA GV795FG0wosq1pb3YwZmsgOSsmM5WFAipdhfhyUnm3OZMI/bplz+J8ZS/ncgJ89/64FIefb7sz+efbVKuCzd+dcceIn7K975L+ja
# DATA U/rvN2d/9M5/ff7Ls6/xBO59itv/JAhMuv2bs9+f/zvAKz368HO67c9yq+NYvgQmm5ex3z9VBxBNX49E8+Sce4KaJ7vlvWwpE1bZ
# DATA kM/cWnmQGzDGDB5M2CMwk2nUCBNWbnDwk2FpYcyb57dQLN8WGTBBZTiEZdGEk0Z/2wDLUpHcHL0SdsCx1d2riscUdPmp/ISqguaJ
# DATA T1WVRBWcwSN2rUBL3i0xDjP21wD9oxzlyoJxUMtdS/Da8Zb3YZceia1i2NEV7jaHcLBpQJDps8TQfjcejeIBNuRj27LsuIk0A1zf
# DATA OosoDPo5FXf/CtFypzq42Swptq7nxbXcKREOcOnG+mcY6zXe8vJD/Gviobml4f26R/edBvdLj+23NrRLtSxkQ465fG7t5iYgl4U0
# DATA YkoeFhOGbaWSAAQ7nS9kKJyn6HrAqRuH/ZgX/haZLjV64ugICywPqRpkMo+neqyWuTHdlpHZjMCTmCoklr+E8JdB8S/dFXGJbDRM
# DATA QEwbKP4T6upxhg1rIArtqGPP215XsJKqJlULxoIsCHEsWSIFoSAPkQFY+cyq8yitslVHJbCcci97aJkJuBFRrpLBttFscAxMx8B0
# DATA DMwbYWDuPMDsNJO5hD18e6b9VSz7azLsHRzTwTEdHNPBMR0c08ExHRzTwTEdHNPBMR0c08ExHRzTwTEdHNPBMR0c08ExHRzTwTEd
# DATA HNPBMR0c08ExHRzTwTEdHNPBMV8YOGbQbkTM3LoiHLMX9V4iOGZh5XknMqaFevNbOWWxUaSKdUoZ3pDfJceLyLJmt13vrMlwYDfb
# DATA wbjZnFabTc/vjgV1ZoHHyjSyHDzWWIG+1a24lpBqK3GttzfFtd9vd1vhSlyDgOLabV9XXHtWXDvdrXFVMLu1cW32u/xrMa4Nv+4F
# DATA VH+vJ66N7rXUgc6g2w79lbg269dZB5qda6kDw044bK/W12bvOutAq30tdaDT7vY7/ZW4trrPXges4Ci0Zrszbjfqx377+90SHpc6
# DATA 1EHrahA76ks1xE66ZQti12xTt9HdAWI3HLWKELtm1BzWc4hdq9NudVoGYjfoDqL+IIfYNXqtbie4cYgd9lBVZXVDj65Ni19n0eq6
# DATA bHPm91+OS1d2ujbypda2OF05ZD6nspsvtb3Nl6rnhHmgq6syytespxmYKKgpV6+1QoeDTw0LTvKfBv9uuHDxjOqU1xUynFSGZpFO
# DATA p2rNOsre1YhxsmKgFnHXFoFx7ZX9BRthc1YJbLFNV2uM48s5vpzjyzm+nOPLOb6c48s5vpzjyzm+nOPLOb6c48sZvhyrNyqUHPs8
# DATA KdHfka98eI++3tG/CmiOjc0v3nhPHf8bmpOQOKzHJDNmsg2ieLLHoTNZTfQzs9oX9L/Z/QVuk2DVDwrApr4xHEaHO6QJt8cneNYE
# DATA fqccCgdjPZrxiGBwZ04H0R2033zQ3h2wf4UP2F9W/fCFOXifO7a2qyGyyBufZp3RCEWWBQSWx/R9mxbi8z2n/5KdWL1IfSd3VN6E
# DATA NmJJheCahRHLOg4XqCLeV4AeFkOgXKU2lHFgRlrokyW8MbyDwTtaAgrWj5gNFlqq39A9oMk6xmnvfbqaQOReqx+KTBQjGpS6AtXb
# DATA RAs4y4lyrupKvAHZz2fKcQ69LxUCT6PORY/mMq1QKtNl1cOtSkqlJgfvtQ2/YNXtBwmNdGN1Wl02v2rx7Y9DyC0amf40OglTHKhX
# DATA gqIn4USO5oeqgnoTJIQ5CexAj8NUhCkk8sXz0IuQRVJ/sFwgSeYQdFmjfDWOOpcNtWEmJcEUG+4gsAnDw5dhFBop9TBjlQYlrBUy
# DATA noZPq8eLLdH7ANSbS0QOvYiJmCWkoSsSBDAzKvwwVQCDZJIpHqOh6XAw6UPvBL0Qxxen7bdE8hN5zZpMfI1OrNuhOBvZ2chlG7lU
# DATA q5wslZOluop1vNEavzG5qu/F3AbYSAiV0JNWsKEce2hpV92yJuJtwIHFucMQHFiPaYScg0rldjywfsz0TuZCTrht1i9CBDfqYsju
# DATA QAkWrxOQvcbBxJfYJYSXXxBh/byJsLmQR7i1PsISRxVlvxzl+uY4s2vMrrqoWnv84jvimdq/MJuLFGb9PY9zsDbOratGWTvM6IaP
# DATA 1vvcLohxHoCJtHXJyuu10bZiraqPjnSrEOeNQOS3l/FkaI1o6C1eXi7yRzIMy+gezvnoDS9g67mUASdz78WnRJQ6lCR/TA9F4HHd
# DATA 90bRCbu02XG8MB5V6GCtEZI/Slmozoz/s+hYM6+MBNgPVb+uu0IA10Jg0bF/lg3ymvdvyFIY8ryHekarmyWzf4idQaK6phmZ4sqW
# DATA jpQbC6VI3symB6Z0NM0QDly82DRle4WNcHt0dUa4M8JXHNUr1pazw50dvs2sfnFkY9Vgp5sB+8DQFmwVeOB2aKwyrfA4H+qURGkl
# DATA VzHlocYInEKvE3urMOog8LlIdmJ4VU5EtLmRAFGyZSyYGTkMsklz9cr05Pyl3LAhgd9HpdCzCBqdh46fvAs/ecY+VDwh3tTNd4o7
# DATA WaYQ+LSFnKzdipbzDxTbF5+gnOfGJTGSn21GSOp8FYjk/YLnHi5tqjKA0qYRiqkETE2jI8ox459lP6wgseg/I8ydlfos1ciMb6Tb
# DATA ZouYJsyyAsFz5Zr3TpimpxBlTWZF93gaMrORrdZFeqq8xCzKij2QqUQMPvNkpv3kavJgN9J89Uc3kXx1yeyBlFF+S/JN/moVRbrA
# DATA m325YYZgnJqZyDOxQvOqfMlifm9zMetGoYrZOP3zJRnZa8E9hi7oD9HFwsgJhcmaksWuVzkyC1kvWgCiFM1LLxJ4NklOJqciCZ2y
# DATA sjE6V4xFZqmHypw38KGDHJte8ZmKcHvSbq0QC73MJcvx0y0w47y/0i1W0CNKIjmNwGKlIWc2VGLgXJKaBJa302Ec0ixwygbqKFqc
# DATA 0ni6RB7HynkV6pascGNmMs+LLjS65ny0zCzh0OD7CDNS9rmxBwwLhLEA1565bW5L6K2V65X74Ac798FUYRd0i9B1I2/G7O3s4elK
# DATA /6vZNlKssGpEaJqNjHE0jbM5a197H3KPGbKXYBKmR5CVhjLjLNOc+pMklf5V2op0rqMQiGS4Ba6lXa5P1YvfrX5/525VjV1kX0Fe
# DATA H0kN1UA1DDXB2jRJWfdGd5loY1HsUHhb+HQcxHFQlIpvHR/N4OqRiai2MOFYYWlwGJ3pPGW9eup1pZg5HtfR9nZI2EvRtb57qa5V
# DATA y7rDMBmm4QkaCO9OmMQja6FaOdf0Hcp6iEJsC6XMgey92Du2PYMZDReWNnkGy0XNY5efWctW2wMGaThHnvORUL2fQnvInq1ct6bw
# DATA SiV6uwDvZ/LQvvo+xRyBOYhotI8HWRGB+fX5z8++Ovvz2dPzX9PnX4BnCWzln+nPL8CxPP+5vrgOi/nN2Z/o/1+f/fH8Hxh3ef5v
# DATA GYr5Z0FictC/pyu/Zn7mH5mc6Z3/6vzvAdA8/xXTMSnssz+d/3sK4lf097f0TgoBN/2CfvgD/Uz3/BO95OnZX85/4zCZL4WjFNvS
# DATA 0F2pblHVPA46OxBfFA9hfZoeVPj7ETa7w4s6ALJOgVqOQ/ZchWaKYHyuoQcv3GBc8957NJ/AfKHOFIWFWCuDJlcH3srPfGdC45e0
# DATA RMTPETRtH6ruM26boLlSKDfH0ORKae7C1kJeU1cewBXiJlXtODG3P+CvHkS7lhOIhF0nQDPOJCrwHsrOxghnfkPwg06jhaNn7lJ2
# DATA N0DO5FVSXi2Pp5jqIjRTAVT3tIj4iNoA9ZiP9XsfRWG2VMu3lGNLQKGYroCSo77S+J4z5gx5i3gSKZd1yv5yMpCGy8kqTnO3KrnZ
# DATA 0im3tedF1NwtHQ6p6eyCm7ALNGvzKubAa7GcemumwPVbAjsZApeyA27PDJB6WcoFG7f5orWpm+BwlpLPiYabmtmFJjJl+KZWKM4z
# DATA 5xhOjInicdoHaTi3eOnZKP/lAD79NmSG+HI0vjJ7GC0G8HvviuPMR3zLYqDIZfnwPxU7YYh9eVCNgkINxdeTEPlkTcEe4IVvilsy
# DATA rCo/Ptp5lvE+Mo/3cIktop2KNCohueKPUrRO3ijBbqvQLKM59KZDbzr05o2gN3caa3aaAl3GaL7NKcBVZgDXNQFw6E2H3nToTYfe
# DATA dOhNh9506E2H3nToTYfedOhNh9506E2H3nToTYfedOhNh9506E2H3nToTYfedOhNh9506E2H3nToTYfefGHQm41Wc9gOrorebI86
# DATA o+5LhN4sLT7vBN+k0GMaFr2ByIz1OC8Hp0I37OUZGzRFh4p/CdpFfmFvOIq6q7kMJmDQGPtB68tq12v5XuB7fr3HfxqtarfpkX1c
# DATA 7TWqrWqnV/WDthf0qp3A8zv0pVEsjHa32+pF8o5inINmkMeZ3pfHuR3kURayqFUxWo12tIqy7PQ8v9UZd7uTql+n6HW+7FFk241q
# DATA QD+0u1Xf71Y71Var6jd7pdriR4PILzEP++1wFAbrmIfNdUlpSuwHKsYdC8LYtJJSrOPD7mDQX0Nk9LteI+h+2W1Xm5SSRs+rU5q6
# DATA nh/Uv6xSWTSalELfK6EVw6jTbK+NW6vbyeNGAVvZ3LNqRr1Ii/Sbg2b7CqRGbnqa1Cit2CI1UlwGvV1IjYUrIDUGUTcaWqTGsD3s
# DATA DHNSY2cYDEOL1Oi3Bt3GjZMasbe9us2koQHX8nGJbWwe0paMDSVEKkd+aUbc7H7bw79kanhsbuRB6PHWWmKUX9mc3NHrH1jxWzuX
# DATA 4BAhKGz7/Ou4m+cg2jQ9tAzwgitUlfvlwIri/sqhkKU8aVGe0L8N+bewWtVsGWxkp/XttYRHMRYpzTLny5dLrQWs9QjHjajGCyuD
# DATA tifX1wLJlMAuvp3DKRUNz2JLkyHHgXQcSMeBdBxIx4F0HEjHgXQcSMeBdBxIx4F0HEjHgRyFaNx3/arwFGXTMeCPZM1o5OMDfd79
# DATA JFL+TMY97ilcJC7gCQkKVfV9bPTb8xnJOJgK+7EQiJqrWqHIlYuDERFZiCer4/Ry1N6bx9Eg0qcRcUYO/sM+yqPIgcxP3rjT4e50
# DATA +M6nw8tHtNxBcXdQfLvu9gtzgPxB/EiaUIXGp9kplvxjOWRpg2/MkUdLNBVNZiKHOvHsw9VTzzgKyj2vOjs9QihyMjMLJ9El5bON
# DATA qqW4HrmJ083JFK5R+5y3U87eRTmbd5RwVcSHzfehv8RtP6K/WzSzaVBcCP7wE/n4Muhlmzy4pEjk25tFIlVuikDk2zjFOcKxbgxK
# DATA uR4kNst4ZLlTVcF5cJzOB5eVpjynEPCcxCM5wZwsmAKR8dAEFxSC8UYR1aMJDCKasCRy8JhTookoz6KdedUseWfHLHlPa4LSmKwz
# DATA 5O1wAl0B1url6FJj4gvmzLUs4bCsqDeCd5meRk7xAgnP68Cco6EZf6gJkvUXy8l8BDa7jozR7eCS+fKjzfkiLUrVlOWQLZO8jszC
# DATA lOak3ozmtB76GQaDQroVCxKQGcjhP7BouEpFMyGUQZAgY44IfZ6jvz8+1cbNc6wj/2rHOvJJsmQNi58uj/L80GrTc60+nUxH2DQC
# DATA TAN1AnNMr9AgmGakMEZDMjVoMBtQxk3GyRIn3mreZ5gQsLYCKyWIXXc0CX9mhDqeUX027wovmT+fbNGe1Z2q5BDNr725viQ59Ema
# DATA HKMOUJppdnMUGXQsb5KjShMuB1DhuD/zljMkV/cwEAhmICqwTBMo70MqmheXn2O7+XTHdsOVWim3WMhaVmSYJkuojy+hVDER4yHl
# DATA M7Lw94OKNRzqngVKy7F0pWyW2UK8oVQX6q/L+XG7Uravi0JDbma7SbibhO88CXcz7ld8xr1xMv1CS7bxPhazo0WorLyr5d5b1KDL
# DATA Jaz3XyK5ZltdV7ZSWptD5UI44W9l+bOVfZFSYQYJdg7Jy05nAx0TddL43g9WtlXqSf6qupz1GH/h1BTG90mB7AX4BLNeWHFsSNWT
# DATA JvDav5A/xEenebh5QXXrXiY5px2FbT2zpUqqb8FwMBuothhq//yP/1GbEfzKcSBSdmJBeotoMuGpiwJNiKLX92B/Zt6RWFnhgmkR
# DATA Q6iw0YxlvJz2dXGFXjo+XYynypplg5XnBkex/CyWH4uRYdoMUTNL88vjPY8Q6VLSyBXKrTTKBeeMGqBegRbMUI6uOAnTFU3dYoEy
# DATA 1MgYjkyseg1ltaxgnNXmrLadrbaV+ubWTtzayRUsto3G4U2K7zKgaaR09FnMHXnNC/EFDd7nLwi/zRDAOT/PXmtZWToRW5Fty2Hh
# DATA WmFNQ5b66fL71P/y2W++4u0NpheB7vWjpjszF8wKgxwQKSPj/SLo3kbG12v+5vUXtaHAjqxc2iW25mET3fyKiW/vOqOrNl7Q7x9p
# DATA /d9FsihUib1vXxRtE4iJdn7lgmyuW/FubI22Ml/NgpnsSuVVLqnyEW/xME0hsxBRqGH33pIzwSrOanuy7VTLL0n/Ewuqak5jtzJi
# DATA 70gQzwh/EtuKUVp5F2CrUv8wM/tL0PiMcfuROFONUjMjh0/G8STK+4kYarUL7NVJWfLWrHRQa45y8WaWB1YrnDBxZeOKbH0jU7dU
# DATA BfROK2+oUH2mN9DawehSrb6HUrWc0v3YHpyHw3rSg3AG7eA5JSDGOcUwnfNCL3uOgSKHu/JkHIkBn3dcSBmEprlf44UtMjpqnoLZ
# DATA IYVGaDpbzqnrUfrBRXHpO5zvr4v1bEG4eI7Ocwibw/WPzOD6+vyXwrsCOeubs39SaC7AucDi+mqVwPVf6banAHQJWuvsf1jh0CcG
# DATA bP2J7tGQrb+c/+bsfxpK19lXdONTftfvz/8dE7pw0sE7+93Z12f/gypNOHHArZfC/mfj3tq6AVRgmgDvOkU/wfXN2DFMas0gT05d
# DATA Eqv3Uc84E9XvE9YNl6ULLbtdUdzQIzT2cdhHPyWzdVHD5joDsfN+hBnCNtjW53SXiZBDbRVM/7xnuG3aVqlUbo61JbRvw3/iLdnW
# DATA W607f5pRcesbixXsOhFboYCtNFxBLRBKYhxe64Liuna01ichGZ34mWLdqlfq9TqPGpQB1EXVvE9oADFWDxMseNI1DudYC9Y7/xdh
# DATA /xCRFBx1ZiAUKK7oEQ0EOFtQZmhdWN02mynFxvO84FkXJsBxs9zwft3Du2ZmXX5Ufz2cebc4ol/3gL7TeL7zcH4ro7nUxkLSbR/d
# DATA i9SGboKRVUg4I34yxWy3k0mT7jBTi2ZDLJr1YZmH2ElcoYTGQPpQo4kpCZMYLKnZUL92FMYT+CsHIVhFzBYqJgujbWgyekoDnF5g
# DATA jmfZHEmCi5RayK60rDxk1gzI5H0Uf6Y08Vb0MdU5uFfoIp8p59Pm7N+YYYWP57BLJkTNQ3HAJkNGZolZkJmz4pSiB6dkvD2Cpywe
# DATA huokeySGYZRhH2KcjbGOGcKrMRDuCtIVj7ABcTCOpqHHO9+ZwjXnscihtBxKy6G0bhCldeEYtNNUZ0fz+fZmAVeZBFzDHMChsxw6
# DATA y6GzHDrLobMcOsuhsxw6y6GzHDrLobMcOsuhsxw6y6GzHDrLobMcOsuhsxw6y6GzHDrLobMcOsuhsxw6y6GzHDrrhUFnBc1mvXVl
# DATA dFZz1Bl1XiJ0VmHVeSdwFmcsx6XHGSdoprpfkKNo+91ihjd6vc05Xm/0mqsgp17ASCoVlAWX6tS7vV5/HVyqIYEM4pQlqNTL2hZb
# DATA qsHx5ANz3SJNathrdNrrnm+1dnq+1++1++ue7zZ3eb4b9TuhX86EadBseEHQrlLFbvW4egfTht+q+oHv8bWqXKv6fqPqNzvVTsfz
# DATA u74dNG8YLeG5usPusLcuBxkXVqr5nZ7XbPhU4fFqrz7u1UvBmbxbCa53BQQWNyGNwJLWaCGwGu12vxNcBYFVj3pRaCGwAgqokyOw
# DATA gmF92MwRWEG37bd7N4/AoplQlX7fadIeBDRWFv1WhZFGRjwdoscH5Az3SdtwyvjUCdYBpNq1si4Qbzl5XHKZWGPAyt1hyew3pnhX
# DATA meL5A3rULs8D1835tJewy15CWR2En3DNYlu7mIjiQoDMET174qMMufwJMwyuWbErY7jWenx0RS16GDZBu4zzWEUHfmNr+sXfL8in
# DATA 4ovaSA77FQtbTzY/b8bpC16zYQq3GetlKvhOOK5tlXfztL5UmdfVyeXkwsklR8Fxvhzny3G+HOfLcb4c58txvhzny3G+HOfLcb4c
# DATA 5+s143yhLqgT8tHw0KZ+LbBkyhmB1N2Vup4s00GECsK16jAesZGpGua9Vh0Gz2IMWMF7aZogju8qywvNi0we6qPTI+mTzWvvloxp
# DATA a07AJmwFk4uK0L+wrZHLYV+YYyYQ+k5dxRdvsF0j5rn3fn70n+zo02xNX7B/+IRt9Md5bLDVchTPKDsU1YxlRJXuw7EV/DvofKi5
# DATA wqVawTnGaShnqLjU8dY+9ijT/JJfZMVPCepSV4OTUB8nxj71TnBmUVmf9BtHkKo15z5O7VT1j/TLd7fZHVyGVD55uu7mKdt/XIiM
# DATA iFGZOGiRRvUmnAZEPMTqP3xijPkv3jCB1xA3equ58Cb1VaCw0TVq7fkxyDtyo84NPntUTq9KrqlsW9sLp3Nd4e0WDE3m8HoKiO1l
# DATA ybM9saEHi3RCU76/+zv5is2A9HX/b/5GvtOjlKdfvPEeIx7e2H+8wfJWRjd1hdniAVvse1KoTuLeqSlcSU3BqSi82ioKl1W3f67q
# DATA CsYBKykSsT5LyX0Rorrd+1jLcHNK+SDrEtKW8eaEvKvP7ufKAxJLPLTtwQfcbnmbFxaFNj5VyA4xFqy2lz91BzHVOoR8NHajwL0h
# DATA MSkpBGrV28XtXzixiZfgcDX/95rJCUVRjOvmJpS1RtZSEy6rkvV5GivTLZ4xq5FsNxgzRiXL6ICwclkGC/gEQmbTpWg4nLKfumIE
# DATA 9KUyqsrDFQWjZCaK9pamBzQOQrbok9GC4UppxG50JnAp4BYb+h4vDLLe+Cx6xD5epaxxIcfo1Tgnb0Jwxp0z7nYy7kpKOU4zy2lm
# DATA XcKq22g63pSW1gci2EQVW83llROBq3lO9rltxcbbELlXngWduTrpb+mdGFpxXN8G1XTxlOEyO8sKAuuUkZMJe7QZgIC1Yh7d/gYu
# DATA pkP0afLpQF1QFrV8q8gfdour237sV4JK4yc0KOoYbZCUV041etcH/ImrbBFBbG4xfWv+0AoBOGBkw0ni8VaSLeDhphje4B6W7lwB
# DATA BW8Ukzc+rLzqvLw68pjyiLyUspHWSZwtjcDZXFpNRUmY/avwOHwgXaxSMwNhRbtB0UxUPrDe28msqIUmqlkhIC22S07pY9GACdEz
# DATA QSRNTpUj1DR3KFyJABc9fYLTXTx0suaU5f6reaa4MCKSjbwcLJaKwjSJp7jIG40gWAWROKZdQLsr01EpVYR8KmKbyfnUQkqr6DrF
# DATA 3FKv8BvXoZrzmZpzsez8q2Gh5sOMM1GdibqTiWrbIs5AdQbqVsPzeYu9flxoJDMMdIt4mkOZHsgyKQugViwKoKTOe0/LIEJgEcd3
# DATA OLvodzSVYcJjNXQ5WS00PKJ4YcvZ7NToQe6o4MrRNbEREhTVAgg6ikFAjZXafcT6lug81njr1InjNZaq7FFABeNPig6kLBn9Y25c
# DATA mSssPQHkfMThqNjJnhvTLW1mFZmNDwz9kc9Fu9K6w3SJ9lMrJiN2DmB0RMco98XbLEy0SO1L3nyXpWMrGEfzdUvIURYfcdrf5U9b
# DATA bNciG1x2EtgGi6KZbzIbC2WM3dXSWK8AYNe5cUkA++MnmwnskrFCYMckLtKMdOW0P9Uk9s+wZZRSni4z2e7FNXDG2qlKSBdzIJA5
# DATA 9Qp0jE0YITZQeP0lGbpKMTUe1Lx3YxZYXbLQrjeNM549yl4XbFdiiihvApFr3Fp5ZVhIDEAQ0etSxWd7ZrR9qQZdMoP/+R/+tDmH
# DATA C7VRMpolXdNIhH/hV40H8cIg7/mXnL7E2rdkVIuWajLXp+4XVNtS1vHF4dVFLPb5/REfCqe5wbQfHy3BfVSu34ru7gQVJfTHkIx9
# DATA lvCNh/ybTNivI0evWFen2W519eNwKlUBUtZ51kltwRQHCrayz1dUbaFTPYkWQGLJ7ibztMcYD/ReDPo4BVpWaF0zKAOiQZD1R9Gh
# DATA 3pOKQm1QMA3k+Ve/f32pyiesM449peLLZbSMdP59iBkcJm00gc6VmE/CmJ05fEEdN48AgH5XGiSvSUjFyfKKygEj60c4WsD5SRk4
# DATA gwuJA1rIU8D0RqAo0lCJQruWqme69ktm5Adb6p4aJCQPyyuU3iINj2ncPKE06Mz8VB0lGCuB7FCqZUo2TDTMlFFAvdxsweA4hAW7
# DATA ROYn1JBnpmdQveqUeo2M55IxJB6tZdUcLreIlZx7RPNfrcIN2++55utnu+brZ0zgs5arcL4xb91qOSyNjrAfXA6IUEIyNWRgtMnV
# DATA 643keca+itwyjEYjzmG7Hwj7GYtX0wyN3Ttyj6rO6E3F6ovR2f5UdrOWMrRoJMieRdtIMFcke8iu1bsL9cSOnS1q1x91RINxAv2s
# DATA EP5SKkldEK/FwpuN0aOSiGyC3n86++b83559ffY/z/5y/ltw785/ASQe/febs9+d/0bQeL8/++r852dP8ffsL2dPz3+7StSzw2FW
# DATA 3i+Yxodnvzn/NZ46+yNdZN6eoPfo7589uuXr83+g5/56/kvg9BCDfhqdVA1674/nv6K/v8XPTNz7s0PrvQzeGqlpNm9eppwPY7TS
# DATA mWwLBrHhh8Y3I8r3MMfIYhhC6YctBVnfwO8P9XaSNBrEc2VzZUv0R9zapwmL9W8l6b0j8bIakIPp2V4a5M5tc/RWy+TmUHpSdfKV
# DATA xE+lKonkSflm9ETWmmN0ciO0bN5RPVeHLigrZMKIt02j2dLx9HYos2tH6olZz305dz3wMovfrE8GhO7dxJ7nbuyzvFui6pqcKKiP
# DATA Jpyzzpqgf/nQAQotnk5xRgcwISpsAyO+VP3bggEuN6rnhdi7OBGOsefG+Wcc5zVS70rD+2uyAHMrQ/sNjOw7DeyXGddvZ1iXKlnO
# DATA AQut9zybzk2Q9MpJ1Ysi4lINWW6yNCJm9pCI+K+MiRWBYsnirKyxipLFcbRI5vxMlPGB9oTMpcU4GWa7YPI+RR7KMlY5RpS98BDw
# DATA xl1K/jTGBpOErDLs2ZKBPq8u9M4wW6YAg4UsMEqZzP78inbbpxHaD6folEtGdHCEBAjHCpPqdGXIwongvgZwVmuemaPhORqeo+Hd
# DATA IA1vl9Fjp7nKrsburdrtVzHbr8Nqd1Q8R8VzVDxHxXNUPEfFc1Q8R8VzVDxHxXNUPEfFc1Q8R8VzVDxHxXNUPEfFc1Q8R8VzVDxH
# DATA xXNUPEfFc1Q8R8VzVDxHxXthqHitdtBvdK5KxRuNetHwJaLilVeedwLjFahvjZ5FjWvUG4b65nc6RW7caNDtqbyhCMY0spogGnkQ
# DATA zWY9L5tAaHtyeCroFcLrNINBY7BSUEHL94IgGAed+rHfbH5ZbXs9v+o3Wl4voD/1ahdfqr1gTcmtovlaAYXWqo+b7S87Ha/jV5tU
# DATA D/zmBdQ5E9gKJi7orM2ArkXuo8hblbPRyjOgUXjvt5qDoN2or0S50a57fsv/skppbVJtqXb8aatJcf+yGvT0lSsnwA+uALrjVqFB
# DATA d9LALNBdp9loNJs7gO6Go3YRdBcOe4NmDrrrtFu9dsuA7oadQb1vge46fsNvdm4BdIcmVd1ub3g8vFi3lvlw34uoF4jDigRcWsxb
# DATA QcU1eMEsXy4rBq3slhUnlc6hFUdkyd9vh7XOA3+pQdVj31udDSf1jFoCW5t041ZdjaQxy4sIORW2oOvWbxUoE+1WMWtrc8YMfHr1
# DATA q76NBrdDLbgpU8Sh3RzazaHdHNrNod0c2s2h3RzazaHdHNrNod0c2u01Q7vZMDdJNh/YuisgtSFOub2x/x35xkuOjOVSyLNkEU7k
# DATA frSoNz8KF+MazyT3+OL+m5QDOI5K71FOtDk0ZpZzvn2v8I478o1+zLgXWSTvYzvenm+H8rkcJrMCKb+zFAw/u3LkTBPEZApojnS4
# DATA Q9TuEPW6Q9SlYz7uOLU7Tn3Z49RbhG9v6pi1tAK2g6HXLqus5pj1cxTyuA3qwlAdz1Y1A1+9vaN9JWmrm92MHRi5ALx6Ku+b1Pec
# DATA WVBkMUxjFqBrKWwD+/5l0QlbLHgtquZvFr6V8RRSzGZYQzHgULXk/wXR1c+b+JoLJsJ+e12Eu1aEg93jy4MqKG0cD44mXbkgkuqh
# DATA XLdXfS9wIFZi6Fsx7NoRLEZvI+/hHdWiIiMa9PLiHt5hK4+HMQZ4YXKiDyR/MILKJvoQPoaf8UCHtpeRWTKvsE+TWukEXv/JqQcl
# DATA TVSyGLw8MYrEWy90Lql1fG6cmqEKcUhBUIAwc8Y6wEECo0eFpI+DM3+Ca3KULbDuzlMqlmCaskVsiQDgNDgrMPIy6hAnyTxZuzm0
# DATA xQBgsqH3y5JppDuiD2n2cowZ0pgBGNy+B9gdrBKEaOd9zcWAhlfnYLGDxDpLdrsl6+zWV9xuvSwU9rnLA/GCubUQvGr0TQqSgEz9
# DATA yVh0W/EP+nyMFKbIVobqc1cVekkUOG4Cm7qigHTd5NQ1alLr4am7KSGW6h+y2qYpsIj02ynSqoZ1Vm3PFaR5T4+eCC0zgVNpfirb
# DATA YhHmWcPTgqRL6GGjxHKq7DNUMPqQRcpQQmBSk4oGikInv883GKOkLMHNcf6UxV4lyhFlsY7xB2aiFvMckKIqekaLOK2wMjvHRquy
# DATA Fyw0rXhv4wPYIEVQZAXgCMaWaH+ChbntsX4A6IqKNW9TioY64u9piashzW4RG0oC516Fp3wV7xSbZUXVCT3GIjmKoGJV8yyjOmFl
# DATA 0anHoAJFfdkUXf3C1Ri/RgI2dp/kLE1naa6zNAvjlPOYOo/pRQbq8xemlBhkSlkxTZIpq9Rxg8jlKScTaSprRRJrqp5XxFlRkcEI
# DATA unNoRlifZioYe1Y8Wb1T7YqXES9HAXufrQSl7ihtUi03cpjo+eaM3YQLOJxgA4MIZDso2C5QMLG4bNNq053Gz810F/1l8/1apZNz
# DATA VX3efLeW8SyaHy8+RizPv0tyXPwDv70Z5aILQ1AuP5hF1JnM2bVYxZFFbRlifcNveUf2SkbQrNMF5Ub8PFIEMpqCYKvc5LRCdjv2
# DATA /vapXozwdYHxEiFjD0mGNQ851ZFxDwFj6yTMxqKlqi10ujSZZNfBwbmV/PvsJOH8G9I4NS/mXqNezL1m18q9B7xQg2RzX6syCYql
# DATA ADovWI5SpDHlLvELTyLgi7BZ11OHcEWo9Bpyq9AGL59hrc0ZZjVoybPvUZ9KsXs/5ansXCYweb4FpVrX6LSsfFvAlOJlMjac4tly
# DATA gSEHoqWT4sSKRwyG9VDNo9mVouCZSdgxdjROXoC8a18i795BFUhFViJfHyxkX6naNYJ6KfsqPJVmE/VIiiKjeaoopYLYJ60R+9GH
# DATA aXiCrbx6aYD1ZvOlgWfJM7sPv2SWfbQ5v/LRQCH8koehtq51Jr3PnArhRgDdJ/TCY7I5jJlOFu5DangThXYasurwNBkyyc8bYx3Y
# DATA +1SEgplphStm+cSsymQ00FOusyYvWvR1ZJs9mF26pgWbMy4fGCXjjGOgaKDpPHyAq8rrMvP8LtWwoc6r0Gu0ec8QVVRsC2QXAk2X
# DATA lCNGbDfGyHNdS7yjZaz4XsyNVd4bNht5y/mLivB6VRwSOcZrFC8gMWtzvP7fs6fnvzz7y9nXYGw99c7+cPb7s6dn//3sa0Zvfb0K
# DATA 7PrP9NP/z967NblxnHmfvtanKNvh6G4TAFE4g1RTS1HUYUYHviRl7aylZRSAQqNEAAWhgG62ZUVI1sw7M2HH64jdidiIiXd3YmMv
# DATA 9mYvNPZoLUuWfLFfAP0V5pPs83+ezKwsnBp9ZJNM2SSBQlVWnvPJJzP/v3+f/QDG1tE/4RZPkFyzv86+o5++Pfri6Lc5hENhUljf
# DATA 029/9o7+ET/l6Y5v6Pff8Ju+mX1Pb/766HPGgwHZpQhgv6Gvf6YA6SfH7HoWXCop1A9d5sDmAUkfkkTwgVKT1LjA8bQ9YfV76VAo
# DATA w8KJwBf3Mf2LBuKClHYLF2oXp8/BAYBCCT8FDiNvROXtnm2lkR8H/bUYr7tYGe8EhyamjuNl+1pUB3HZIK8lpXJxJC9VC9Mloweq
# DATA WvYjiuf4cP5+qY365rcylfQ8YV5wGaqYiBa+7MwPdbwc0Guzojt3pteDMAUdpCyIMSCpussyVA4uOS9Bb4O9QCIjzFAFc4oYnp9D
# DATA fC14b0YdPTum3k2m1+KcUildIHsdXxlX2zOLrexpob2OT4VDezlz4PzNAU37Op0V8EKstlyWBXARBsBG4/8Jh//LGf2lYi7kggX9
# DATA umKN6iI4YAvJB9QUa0MJc97XpyzHNRCqV5yE+XS+NVFbI3gLBIuERMHYvEkHxSmXBScUp3IdbEQGe8i+XviDsAEngestHAf9nLLk
# DATA aECLOlMUX9jhYoSxNqYawmvInRTzxBHWpoDZMQLzgAIVlwecU9TG4ZqJhnnKYgaxe2RdTKJhqB1VvHyG0LEMDbMlJzYLvVjsEAOC
# DATA cpQwRwlzlLCLo4RtOORsNAfa1HS+3GnAaWYB5zEJcKQwRwpzpDBHCnOkMEcKc6QwRwpzpDBHCnOkMEcKc6QwRwpzpDBHCnOkMEcK
# DATA c6QwRwpzpDBHCnOkMEcKc6QwRwpzpDBHCrsypLBKq9zhn09FCqt3q93WM0QKW1h63ggVZueLX/XKfqNXrTXnaFM16h0b4TLaVLkh
# DATA OcRlJGVQYUVKIWX5fkapZ77sSr5deLVM/pt3ZkKvNv0LDL1ZSwOvNDOBS6rSwP1yzYaAZQJvdhutVnc+8Fq1ee6hZ0BvFWGxCaTM
# DATA r6Wgt2ojE0BYDYJGeaFZ0OOe7zf2K9V+qeH59WMIZKvrRP0UADJubBpAJu02AyCrBs3aBgCyzBUAyKqddreYAshq7WrYKBoAWbvb
# DATA LnVCC0BWrbSbzQsHkOkGuhY+VfCrmkKWud+MjnqBoLoJbSwbhOaNpf24zqkFR6b1aAuLMkue2XRZoFBTFkjJdjyUCkvWhH02iDJv
# DATA zngUxDLAczx/Md4kv0p2AkyqJR7JkvFISqbML7MsWeirLrygdFPPtaj39lO7ZC76DbbnlnHRms1mloaGVebVlLJMueXmymKNtZO9
# DATA cc73YNyHDkPmMGQOQ+YwZA5D5jBkDkPmMGQOQ+YwZA5D5jBkLxiGDHWBQun0w1zIy0Sd3WKOne78aURmd5js/vKjHByq++EuW7A5
# DATA dLT38NMuquRNU6H5dBmso/H2zqdRd1se2vlUB00tFCZIMGyHhSFZqDt59aqbdvA3WdVZH9zYlujt3ERX8OHWw/QYW0dwYp9Zcxzs
# DATA I9Tvl1LEsY8170X66SlKKit50MR4vK16K+gTS/opAcPOtd2R2r2f/ByG3U1KHwJ/mX7b+ZSf3h3d5DMZFCf68cd8jeKxNDWZBJus
# DATA v2ky/KbUOkzoudGnNYzy/HWl70x5r5Bw+uSPUX72HuKQVPb85ZiizwQPyo8oluwTW/7mZ6tfx6S3dhj1t7cpqXmkeec6m7aAvKks
# DATA oZhQkk29oIbEqS+wG3fn07TCWJcl7vZ9lHE2Fy+tQSqWyFXJITUW7HyaZhiKDsUZUTZGLytyHku6IZ3RtWv65sJoSqbJpyrmN+RO
# DATA nLKj+3IcEZpYf4BTd//5+b+oM43A5kXX/B3qYigSC8Hn/Z01YeN4pB32fRyX5OWPxdA/S+vCZ6qO8GRSt8nFqqweuJmp/Telnu1i
# DATA BqurnnVDrlQtZlvUeDoUKWEh9HF14FZGF15ZZ+CmbV49NcYZ0uOe4vK1uwur5qc5MNfPrGsS96GymrYHlShERSfJzAGXRIvPoER9
# DATA mg+ZPlXXQPOYjBU7mUhTsAfRkKaLywLFSho9FM5lkmPGOJ2JU+pMOH2J519f4qQkmaugO8ErKxl//XqczDs4BA8iB8RX9cHpYA+v
# DATA msSDeEwzs7VMmasoWvHsHOG+CNLMosbGeaNmlomYnJI142WWiKRK8wrbLb+opYEFs2nkxOhl6hYIeEo9SUU+bKH3x2SV5cT1JFr2
# DATA iLyxvGU1Lx5hFgm4nrAeetPxhKW+IvXeEY38Q9FPiJXUhxGxXyP0cZzy6HN0RD/TcJwJ5UyoDU2ouf7ViXY50S5r+F1pfF0FMa9X
# DATA pxGYWlnZKiPl9YboQtlNCSPPKIzR0A56cWaEEoSAHsAK3m2I2KDoWFMnkLmwgo+Fj6k5Bv2oC8UbiG7D+SASUsMw7GjM2En5KSai
# DATA Cvig5LQhrZ5boqTl4CmbwFMGsRQd692rz+uAKGN2o4kEvnxefTd2+wg3+w5/Wn2nNncUX4g/PwvoFDv3TqiS34DhuFonPy2LDMuC
# DATA vXpaHJ9nRenIhvFrHE/3emlj+Jhh7yzhoXFJ0yEZj6xFlW6YRnvejyPWtmqzeejpE/SwGqcsNjdi+V4YmxSHvXByHpSBM+Rf9WT5
# DATA 91qYPPbY2W6hBaCNq+BOJr0sGSeu8IR5hrbpcBD0H1NeaflADg+3TfvAdDOq0QuHXAYs3oZTEF5nOtbiujRInQ/TIm2GJ4UzlNbn
# DATA W9qqJd9epTFe9v0xU2camdqnbCuqc2G4UsgQq0dDsCwkL1maThYTEkXvCpNJwftbBmKE7d4w+mQaGgVFqqQ0oQMrYdLDtKMXcE1E
# DATA vk5UxT2H3Ey7qZPm5TF1UPd6kpMfUN1hFUQt1WwwpCaTKI1chdhCVahRg4QnC7f9GFKQc6asyr2AZRcV8q8fqkkmZ7vSkDOi3t3s
# DATA MPy0WnDtZC341aDPdoSaKoQ2iwbGAWdIMh1hAkYJDMatQzU3aIvOoux0Lni8UoPcZTnysWK7Ua51wxAiiphqkUURJqOwHTERVtQv
# DATA x4esZ2gm4cPw4Dxy0B77TloBi+uzMB1KFWwFlWtsLmoKLk27Bty1obNXpB4zDWsHoPJQRh2QgQ1THTsovB5ZhKhfyDJWAWXhQ6rU
# DATA 0IHcx1YxtcfmykJVniPXRhqE82s4v8aGfo1sTXNuDefWOOWa0EoXyIVplKsqm6G/whSnam68G0+dlbHOu8FMxpUce97ozcsc2P2t
# DATA Ti7qa2bSy7sa7JHTXNGzXs6l9HwkdobQt7jbFdMg6IhdkHFI8K4W+pltJNPrbKvtKTvKL6Jb+JA39OMVEin1tOkZ9Xczzy/L8U0M
# DATA A2My7sl44TN3uDgInsgdRTknF474aN5q3wlvkuGUWGW6cVTV0yaq+ruJaunYqPqNjaMq234QWf50XNz07WnszBUTv8qy6PlW9Epr
# DATA YqdWBY0/S84F8PQPvL3rvE9xQCa23Mjmx3hw62WRVkizEMdC7DqYXsrUuREN7hM5jntdgkgrsvHNWO3DXFrhwBGTiCaDHcvUzij8
# DATA /x3Zpm09QaWJeRejpAHpyJThIKDhHbCdET1KBhpmYIoKlM5iNZBS0QnVZEsoqWbvr4W0xJAc9/MMs+QdW/SWDniYsdBE4UXJeZ3o
# DATA V7+KMKSwe2U4TSDInxyS7RsPktSLasesF/ZHxywcz5Vqunhs+1XTZWDJf9mzRY/fw4e0xE8VmGzlkkYZTqzqIzYsl9iLYZVbrMPp
# DATA mGxiMuls2uF/Z3jh16ANZhmER7/D34u0w3+dfcU8wu9mP8z+6B39/dGXs+9n3x79V3ryB/qkuIXMOASxUALnkD0GIn4FjOLR53TD
# DATA H47+mR76Frf9MPsPCkc/+cfZD8AlfsMYRArSMQ+fhRmGqV7pxIIrPIgnyFF6Jqf8ldzhaCQGCycZurNEmCyie1SKQiOAYWUIHtST
# DATA aqNnFIVtmo2vgxve19sYaABgtJpDG1qTCV1glw03XCiVi0MbqjqibwNnQxN3+JeF+7F9xepwH8Rdtafl3NGGHIEM2DBKuLI7rOFm
# DATA xXbuWMO7T0Z99DKBdoYM4s60H4C8Hk9Ys6fgfYC+n/uudJ8XL35hYzw9a/Y/URymA+4pE9kGBRdKPAn0WlYwFHTMAtDw+Cq42mqZ
# DATA b1lPC2d4fBocztCN9GcY6TW38DQD/IvhKby0wf38x/aNhvYTjuyXM7BLtZzLA4tZ+LRazkXACedSiRUAkIAU5y9qW4nV5xznExSI
# DATA S1NB5UBb05uoExQPb76WbcVaohtW0pC9ovP5tiGR0HhZ09glk7jNK448HmtUHPPjuJZ0aK49TEz0w+k49oIB4994yA/JbIjaEZbG
# DATA MzZBxgIIn+BgMQLvhPBGqR3Vaq2QrAcqznfCIEGE2LZrT+CKESORvTpCqZO1dVXUremh1C9HK3S0QkcrvCha4YZDzUZTm00t48u0
# DATA 8U9j4p+Hhe9YhY5V6FiFjlXoWIWOVehYhY5V6FiFjlXoWIWOVehYhY5V6FiFjlXoWIWOVehYhY5V6FiFjlXoWIWOVehYhY5V6FiF
# DATA jlV4ZViFVb9SqbZPySoMO10/rD9DrMK5hecTkwqrvlf2i/v5ZvMTv54v1716lf7ulaulTypNr+TVSl65vt9sZnKp7bfK7e48xo7C
# DATA qi3F2FUWyIZy0k8Afs0swK9a9ucIfpVGWtZybC0l+IWNMGgvghMtPmCjmgm+VG5mg2+WV4ZukpkJvVKsrgm9eqrQ7RJp+F6lUt+v
# DATA NAfUteYrzf1Kc+Oc9hdhhHXfq/r1Xq1anQulXW23Wu2lKMqTYwel3WjsoDRBCztY61Qb9c6x2MGg2+rWMtjBDv3dKVnYwU6tWq8a
# DATA 7GCr3a60KhZ2sFStNMoXjh0029Qg/L+30Xx9DbdP7FtvwS7S5vjc28xAqaZeb4TU3URBTuK3FGBYVStxpQVaHxYWF14w53a3jUZd
# DATA INl5N5l7ng87wKvJHztMtk43zqGqNp2QKWLkZoO6FcwbKhY2MBtZe3OBHtHVsldxmbdXFlOySSvB98l/qT/2jHs9cXAuW3PzebLG
# DATA bFmbZLYnHHDQAQcdcNABBx1w0AEHHXDQAQcdcNABBx1w0AEHXzDgoM13k2SLF0NIaXxUHNHf+XmjeK1UzNHMUv10wEW4I1M2jfm6
# DATA K4dk+KAbGtk1/hVcuvYAAYfe//e/ec0ivnXCcFT4kP4bgrZG4d7aLb7y4dYHrKXO5+h4oQaB0I8SRIGnPBRhCcscvkFcvNYh7mU6
# DATA XtBKEOKOeQqf+F1v2UfZJHVemEzgRw5veP/5m/8HkVlI+3a5VLwmV1ncE10DgtQoM4cQc2e7jzvb7c50P+9nuk9KCrsKZ73nXGzr
# DATA MWFvo2mYJwreO6j2trbLUjjYUz0d/uwcjbwICtj8YfbzZoAtSgKclgCW9dfqs/pvM7VLKoK8phsaXZvX4HoMvE5MPyQHfEb7HpyQ
# DATA qFosBdQLonHBexBN2P2kBd+lAopw+XQkx5NV4WaO7weplNEIoo1xl88ip6I5cwo3C+X8OISpHBi5HdhEl69085ROwVotyBlDzhia
# DATA N4YWelQneuNEb44zo66GGM49qa9MtOjEBn/xcdwyijj3jXYDNcNob6jIX0pDTeEjxzQstCFu0cXNoiSRBMCvwj2q8Ti8IZ/lO0SH
# DATA Bm7Ivq3dskQzZWPw10OozsA/lirZ2DwY9l2IaofDfW2G+6KkQJ9EJX3CrWY17IvdjiILzR9X38vbc7lnecifngV4l5UXJ+SuPFjD
# DATA T9K5KsSVO2gVVLpiWwlw5eFBLGJN8RSCMQHkWASyMkBL0RKJqOEBe6FElknMQxrX9uFF/hXkWcaDrHqRqBSR7Ren410AQRiqHYFo
# DATA 1HfZUNZnTqXRqNnBcmHnRQFos/AmNkmaQJNjWsoBYwMWlDlj6AFLEPps/KtTl9z9jUvuvhwwFytdF93bsEXQEQbMBqDi2FPq3wmT
# DATA vsIRq+MollAWHYbiY0kfUfumIpBJ6m3NZ4THUO2L4t60H04UWGCs4pKM4snZiyyTsssrs7Q3OWGZvbeOVqb6JSmz9yBAhHxsxRQh
# DATA GxDF0kR6HUULmu0JI4tylzpxXIy7ZI0YnlY3PBDNKT24TUQSHnfK4g6X9AHT35i5Yhodl35rmhyevbSyaXoGiuvdjYvr3QDgdl7M
# DATA oL4+5VElPdHSN42Ber09+MMfh4di7bcCKGh5vXggDQuTgyGHxhp1Q48KagxaGFA54FWxA74bPRF8HEMT0sKcF347e6FlU3ZphZaO
# DATA wicss4ery0yP56pXFOVAXEvLS/wR2IePYYCaUCKswL44Ylgeua3GCfbGebe5fLuM76JOCCJkGPfE8sSxKW805cNzLJ4wBNrlHPq9
# DATA NO5Xv0RKm5bIu6FSrsPwMVE/KcKlnA8K9QAjzUmsDRHqiz0+3oUWcCiChAIGVK2G+zeeWSMAmN08lEWJNlJQuqJ/dw5tZjEhpyqm
# DATA yyXMnQlj8iL42awgnKPNOdrmHW12lXI+NudjO+Vi40qf3AUJTsuUXGZ6GAFRuWFjGhfbU4QaXBB5LuPJ0ntPYO/zJmssPzV43wzP
# DATA hNXvx4DO0lBMd2VdSqlxx6HOahty2A60t8yAu3heoHbtbbcHxwLuJIAUcKe+W4C7pdg4Xy5rcFxxY8id7OaBuxAfhDEmFGSoFHNe
# DATA zTkQ1QOp91CHsOCzqxcZ+4Vt7d4BFjJ5f1G9uNrL5/v8yMPwCXqijvUU/bLmsQo/9ibdfWg/UymucROuRNRp0xS7aclSmzy7kDrb
# DATA dXfQo1C8j8nyHIaHBVvyWek6SycAh9BB7Pnc0oKxgsXpDWsjmiYp0x2rztRZUJwwveKBm4I27nhxaHDfIh575e7X6tr8YrXtzGPA
# DATA JRVYuVTkeme1cOqjphp+qfbktrM1FXrTSoadQtEq7Dmy8J9I1zekOPZlqsiq2aPpGKB3WdiOE9ZPtQSyN4DIPSfGc4qQo14kbI+D
# DATA 7sRCyL2jr+WP/mH2w9EXR78BRG72x0V03L8txb/Rl6/pqS+PPj/6Apc9+udruvgH/vsrgOPoyrezr47+0SDhvpl9rRTSofA1gnYq
# DATA DdkOE3flTX22zAPP1Bnvb4L9wLvbieQslojeq30lPPvtjqNw2KEOhL8dxON+x1j/8HxPR+I7hStBXGf9Q6brxnBpC0WUnQbpAoXq
# DATA efBU+IQaWmctQu5VCGiw1oTHfwtPwnHk0hmB6RQumyO3vGguDibXo+gwuSCFU3N91dePg8ndCUQS/CKAcrz5imxH+pfGBHFdYTRH
# DATA g3FAuc2K7tyBcpJnAZs5Q3RuMq8y0ylt2KjJ1EA6KLJcdEXhBT4a3tDvsrW9Nw2oUUxC6ttei5LHOVg/9PSde+97yShUpAwcf6e0
# DATA KVWYKdtAcC1ONqDNLa+jq02cpW3wqmDnlifGoeec9XBB1oPG0p3aaHghXIiXZzBckL2wkblwQmvh8owFqaTLMsMYClezoV0Exc7K
# DATA BoDmsEjcCUfgUJEpYwZqk0M8m1+RLe14MJiiu8YC3luYQbTZYcGSIgnlSzu0R/xxyA4K8f4hwxK12Z5Geioyvt6NxnyKNkk2JtwB
# DATA pJUo36yGiVGG7JNFOBY/h/q1S3PliA848I6gd+KPaUTzOHltysC4Oyl493W85YCCgoXNO4EX7BY5K6ARZEbTgklmyA/o4kA6uEeZ
# DATA HLXFe8xpH4q7hvdyhkPm6OCEPFoXQGSqSlCuOuadY9455t0FMu82HL1OdbBrnVl+6TON8/Connae4QB4DoDnAHgOgOcAeA6A5wB4
# DATA DoDnAHgOgOcAeA6A5wB4DoDnAHgOgOcAeA6A5wB4DoDnAHgOgOcAeA6A5wB4DoDnAHgOgHdlAHglv9wpl04PwCs/UwC8ZSvQG1Hw
# DATA LF5cKcXRyWm0NN/rcwql1UYmuyrVZr0azpHVSiUqgMoaspr16uapX90otUq18ulfXaqd+tXlRr1V6Zz+1eXyqV9dKzXLlfrpX10p
# DATA PrWyrtSfWllXK0+trGv+UyvrTLtuNi4zwzPt+mSvPmuGZ9r1yV591gzPtOuTvfrMjav41Mo6064vt6wz7fpyyzrTri+3rO12XarW
# DATA LjPD7XZ9wlefNcPtdn3CV581w+12fcJXn7lxFZ9aWdvt+pLL2m7Xl1zWdru+5LK223XZr1yqqdA89avPmuF2uz7hq8+a4Xa7PuGr
# DATA z9y4ik+trO12fcllbbfrSy5ru11fSlnbrodS0SvXS71qrbhfr75JX7NOh3qrVq20lz5WqdT5sXJt8bEKHB31k5hjagJiweX9WiZI
# DATA v1EulxZjUi1WvVK12isVB+WqV+yVinO50aqG1VZ9KZK9cSqaejmlqYs/x6KpN4pBWK1laep+s+yXqhma+hxfHTT1Vthsd1OaerVU
# DATA q1VahqYeNFvdoJjS1Ct+tV0qXjhNnZ3B+RZv0jeeTlls11j01NvaEIe1/cw8EN0sxS1bdtMbNeq8QRPbM5mJvrjbsQY/q7yGD4Jt
# DATA ti2jZm3LWAl0t0Jdz1qX4lJOy6pZdtE1go8l9IJOfHCjST/iT9FTpfhZgV41gAtsxRJsaSG49XmYBuipraZ6/5osW5lfR0t2H6i1
# DATA Xl3DzDKA2guaerpzcycKssvbxdWwdbuk1rjDl9U1dnKzX91B1R1U3UHVHVTdQdUdVN1B1R1U3UHVHVTdQdUdVP0Fg6qnFqPSbtje
# DATA MfYdpdq7L9ofqfDHTSFWcZfNtnL/kHHlIiqSH8SdcFfQFXRRttmiUafXRGQiDxtkt1St1qp8FbM8kU1LdjUbnafGCnGufkOj1IB0
# DATA RAwuiAmE2XYbEng0ULCR9JeavCCedBAyFya+oJpz2ygkNFSH28VcrbID4wgHVbav//JD9d+N3Z/+GP+OOZiPru/lqFwtTjuXrbcI
# DATA p4eqwO6n+8Ew6veDG6XcqD+laX9yo5yDZNyN6me/5KjwNNbE5SONp38w3dsLExkXWYDMu3/7nRsGG98Oo/423nBtPnt+XvAbTJN/
# DATA I3pVoPWvsvxPqsM7F4oEIAI4NMlHEJofP4oEKu8XSjpIdM6KJYJRQQQvoKknQof8QlVnoIk3gTzfhMxlXYNESQiSLQpIz5mQasjS
# DATA 1VfWmVOcwVF3hSX7qZloQCJtTp6Wnk4r+c5NjCxwXM1p5EDsQyUASi625A3HWAaCn+SyAh1Op87p1J1Ep25OzMUp1jnFuiWaP6tZ
# DATA FldFyc4bjdFOWUMrGycjZXc7K+m2N4U0LoSZVmm3KbDFELzZqB2poDG/YzVWLVbFNNp5SbosWmtBjs7c1yvduoehiboWHXHxhmu5
# DATA qV/IuK0U01LyFWzgmAn1wAACdYNlnDyr6E9YoF6CS6Dl68mYr6e6NyEWC60ppTYHxJZnPck4TyhbUZxDaONTUiIY15pDyEf+4i5H
# DATA J3wCiJrIeqGnMg/TSLVKqY/T/Zqyi1huL1W6VUOjTv8DY0h52pCCYh3wPqJUTPNhoZ6oHIpYx6Lg/QIj58Ij7d4UusVaf0yZKwWP
# DATA Jw2ZgVbwwAJAFU9tLkMVTi0KMi6h0Cc9N/pYxqxEiDCDiulV5ixBsi5HbqsuXnJE9ercWExuTOKRYhtwXYnHrCYH9bNkOsIIjS3H
# DATA 0HOmutYOO1b/PwkeC1wBViHbM5h8jQ5VoerBJTgIDlOLSgYgiT181d7DkB2ZOm4Mdg0sU4xBxPaQw3UrmqxLNr8fb/s4pkxrYTAM
# DATA uM7RvEEn/G14UDzLtteqgEyDyuoFCg2VRbsoSljYGnHJsZRc0KEuPDJkGyUopxMgMnQa/qQnGKmgnGbdMKAzSFuZMdWYaqdNOZUN
# DATA 1Of040P2+s5D1kQZ7PkXOEtHHWegOgP1JAaqM0dfHHN0pZl5xYWV7QX+RYRZP2OnSouhvyc9HpBgqygLNX2E9XoUCuuqyi8/W2qi
# DATA xwEdrK0cgpvjLTK3XqYOer6l6uNomU1ejeLcJi911Czo87dl7WXxmJi0/nYMt5S88XDY1tFR6ku33ls4ZcYefLJ5Vgh5W8/yF07X
# DATA HARMb6TRWtmvKpuxp5WnOX+0McYG23LxZmWVaXlg5nVMR5YtaRicNNjDHtXTBYP5yhqYWXPUcvDN4Svm68Kr0wg1f1FvWyrFArHr
# DATA WMLHUL04RxEZh2S6BC2yuhXgY6694/SrNAVNAO6Vbz0YCPCbctPQkLm5sZZvoIjI+9lZC8uAg/o+CuNRn1roB7zugbxI5x+sZqaI
# DATA iyKTnNEJzxqOkwAVV4PejLU4j5TmKKvS09FVkz9j7GP2oMtTMdNkhoGdEDLjZCwJZimqq1KlvSZi98ZkRLYn6yN2h9cbvAQW/6GO
# DATA nrooM2m2wL0AVYnzCDl5MGbV7PhgSFM2+ikaQA5dV9alsbkjk73F2LyAIsWOm+ys+NNa8fNVzvmZnZ/5zAb8yunCxfmZDU98nsdh
# DATA sGpXEvN1GfxlvfJLP9x9MpJ9O7wKTqZMGE8T7Ws9hmecBmP6PeuSAfg2jgMw+xsDjY3R/wF3g4hYFmCsb0gZy2aaMM8VVqvs+E05
# DATA 7lcziNU6vEzz+OPqe1HqbLax334No3gxZbyWblKHb4yYUIb59hvRq8cipq1gsnmgL5p4Vo4rluoJONO86q+gfxRVuYA9IdReKRPW
# DATA R9o8bmGn9ZWUN31cdMubxpY3cqQd2IA6Buo75uKI3Tk2anzSyXLG5buJ3W0vIYtJL9PYUd2ASX1Xo5K5gxiHvGahPdPPLqDarBVI
# DATA B9wPpkOaD2FBIJlkGdUm/R3Aadjs4jUCizKEnn0MMjMQ0tLLFLzbuLwfkb1jL5KxJRQ+aavVDE/WI9RRh66iZmKDRyAAm8MEG9Z4
# DATA 1sEzNjGieK1CGUrjIFL0JrCkg5H01HPlmTpQVO+YbiLJZKzlHjFInkUuclrskkdzOKYlHCZeYZsHMTHTqhOHgo9SMz8PnKgDVDLK
# DATA DEaGticK72NGoeM52c/brMkCZk+TqA0vTxRbyOzZfz/6cvano9+Caj377uh3s+9nXx393gM7m374j9k3R79fpGf/y+yH2V/ovn+a
# DATA fX/0e7p79id6+K907xdHv8t59OkHevKPsx+OfgOKNoIWkvYX9Pc3s2+Yo/05PfLvdAtI2n/26C7wun9HwX5DwX6Fp2d/oGj9mZ+k
# DATA IP5Af38PLPfR546uffUnhNSJxYMwD7KcILI0d4r7qjY1U4Dw+rwMzKvl99QIEWibNidIMHZOkRk36oeKF6ZoV9T7jTXUntlgqdG6
# DATA lqJ9Hw9RHxQ6dHZmvpd2D5cNz7ZK5OKI2apWJdZMjy9wxUzm726FQdpdv0pfuDK2QhrrzxOVTeEyuzrSI5naWrEwqXtBWdkbFNq5
# DATA k7Lv9GLo1AeAmNOYOtT2K2Uwu50UUZJ7Eyq3hT3g4vMli4U6qf2wfxNx7fE2KbLvEttLFSTSG+rNKSepf6stmLQ1PS329bGRd9hr
# DATA N6yfcVjXeOuTjeYvhuf2Ekfy8xzINxrHTzSMX8ooLjXRJD3d7ftUm8pFAKpNGmV76KrkceetPD5czjnZSUlp2GOpjGDSkzR0sRGy
# DATA J0u2svpM0/NAyLTj3uGkN0gLzNoLGejcUMhiDMWbEKnfjT0TXQHvauYyx2YYe9JqlsN5C95t/pEFuhMhE7OisyxhqV4VASWTeETW
# DATA Vk9RcCdBCxkmB+zEekhTZQDZlF/tKBF9Cp2lbTgjHF/a8aUdX/oC+dIbDSkbzVc2NHwvx3Y/jel+Dpa7A0k7kLQDSTuQtANJO5C0
# DATA A0k7kLQDSTuQtANJO5C0A0k7kLQDSTuQtANJO5C0A0k7kLQDSTuQtANJO5C0A0k7kLQDSTuQ9JUBSVdK5aBaPSVIulvuFrvVZwgk
# DATA bVacN6JH2/kBF2u12qsVS/vlcvFN+v6r+XwMq80leKuG5zcqvWqltt8A3qqRfaztd+odf/6xgV+peiV6tFzM+3WvVKYPXrmRr1S8
# DATA Mv2ffqvnG16l7AGe5efLDb5Wwu1Vr9z0yj7uxuWi1/QqjXzJt9/KOyGzbKtypxrUisvYVkvqRhXxqe/7pXlAW6vW8lvtZaFUFmB8
# DATA NiWtnEUGS7gWwKuWVt9ylmQeBtV6ayGGpVLt7DEs+eU0htXyOcew2TyHGDZqaQzrtfONYbleOnsMy9wkLqiUK9RIzhzDSrl0caVc
# DATA 9Rtnj2G1WL24Uq42/XOIYb1xzqV8EpCeDEIapCfjmQXSa1aqfrmZBenNY/P4SjAP0ut2mmE1BenVgmpYbxiQXrve6tAc3YD0mmQd
# DATA lxsXDtLj7Z/5ddZ9oTzHp/vMemiRRZdxCfmN7KxHZwLbWHDZUt5j0+N2vtQJ93YyIc8R+t4IaVyPgpzEfd75XWbXtyx5M5xvfv1e
# DATA hcyTtU3X1ArafGd/btlKOoLx9MajjOVuHAs4YqB94dgYlj/hElBlmQOa/XBWeMoLtojnU7UpWxooDMsrUcfyyvLtUAuvKCDWZLNa
# DATA s3wyUXVjsEuYrOJqu7kaupeWcM4ukzWziMXappJrVSPl7F5fODwVQK1fOY1KC+pk81EHAXQQQAcBdBBABwF0EEAHAXQQQAcBdBBA
# DATA BwF0EMAXDAKIuqAmirtsneYCHPrMQcJ3nGMZtuJNyQ8+HbYrtSXq/M+7+DGP2nKTAxHxiF01vKmvFLdfFnOlXCVXoz4y6s73kOq2
# DATA nR39uLn7Jr/OVMTtYS4C/22ou71d9YTV6+3cHK7NJQDk9IiVxk+9R0bJJ7u3nug3SE9GV5Sd+0R1Z/Qf6HX2HGOEo2PbO59mcvIm
# DATA HwLWtiJn6M5cqoa7tyhBfPwSxijP29H8+BwcklCQk58K80dBc6+kIHg7bM5lp6Efbqnzfugo0lq5S6MuS8jKKWOqj8LAuy+HjpGE
# DATA EXWwjLkzCZuwxQvk3o/V23fE8l9eNsekZBLv7fUzKclF1M5RiyRJHOgv8f0jUwQKqBjvcq3Utn/Shs4jkruT28v89AZNIqhixzRk
# DATA hZQxw/ahFBq/ht5WfMVvFG+Uy8Wbe4U9uhfG4i9ww2026rdxaiGnApRt6Li8o+8On4ziIQTbgv79YDB6GGefLfqLz14rFGuIECVk
# DATA SEW0vYfA9Be5G0p60ZBXNnEne6C25VM82l4WYp2KSQrwnmQmCyYC7riND9d8ZjbGXa/BRcqJ17/8rHGT6+KuNZFBSefKRazACQAS
# DATA bpSY69pnak7Cyvgawairw6dp3b+pqsZnug3wFHiC7UZchLfv7B5EQ5pYFfhUOdfLJ5Nf/1pdPAhbj6OJ/ZP0Fnd2Jj0ap7274zHX
# DATA bjmSbo3TSB9nkdSDX/8a88HbdyhCwUEQ0eyPsw/99ADj5JLKfMJWFI+sRiT9ozSUm5/xbN/OEykjiXPWvFg8vi6iR6LAA+lDOcXd
# DATA Cr2Qpmm6bVK/Y6ayS7o6Ph8X9Wlal+n0UGTmMRnydqxYUqCqFJYEiTV+esQEZT3HWfuKtHoJRnxq5lCt07JxWjbLtGyyB62dqI0T
# DATA tdlU1GalAPlFid3cxboLj65QmxiGtmyLFr55egJql6EyLqYAXX6ID942iiO5PoiG00l4nI61ftZ0TuaCkVxWquHzktCyN0RpQpfW
# DATA SVjrY74UbT6uC8X4Q3RZnN8xC2dQ6fACWk9Wmrg4KQC5P5sxZj3JygnzI5ulvGQtecNToCLfmc0I7cFJs8LcmiadH/Tn1K3Xv8vf
# DATA /F1+NpvxYOlE7ypt/q5S5l38YPlE7ypv/q5y5l38YOVE76ps/q7KgtT6reqJ3lXd/F3VzLv4wdqJ3lXb/F21zLv4wfqJ3lXf/F31
# DATA Bf33Ww3zLq2vYtrwSnV1e/r6HIip66FCkC5aicgabajveyxoJRydoamcdGAyQmL2AGwyT9IHkFoaZ7o8CcHPeeWcV+XhqA6KVjhk
# DATA IVUPOwg4aAEKDwwJzIoYDVTL/ace+leGGViyX8bbnqpK0TCFeYNWBMMgiDDFajy5HtgGUubPvpiQg7a6qdP6qZObKT2fM6WTglif
# DATA uiwob+5K93ldBMLTkt88Z26nLV66FNa5EifLGoJ88tC0VOGiQGZ8DVb2CoijPiNigRvKm3vpzkFtXInXUs+X5cQO5Q5NpqGiCZUk
# DATA Y2jdVgqtwZhFruAYJWMIT5NZRfYV80957UXEWkcyjeetXdBhxDyddzXl8IAqqFS5kSf0VEhRn96xj52IQgXaA5uM5Sfp5czIgS6f
# DATA FkM/eS7C7GPNyDnt2MuUTH86llKmWjpjyRlLy4ylTFfl3MwvvJt5pZH19DXVdc2n6hywrPQhPABDuo83I6Ua66MxmiZkgOca2d6U
# DATA 5sfsah6HSgN7Qd6bmotRALeUwWM1xec6NOdYzlgNiyLq5j4aV3Uz5hGJStfoK2PYjLtdL9iPow6vfg7jKGGX+Fhrakt3kILH04Rp
# DATA RbeC94CGaK9LoYmIesLrpHKUGINvX+KS8P5FBHJotMCpZ5m2Emr004kYbiwjB+Z3RxPhEOOC947S2fYGUXscj3rsgFH4uDBos1se
# DATA z1MOQLca3ddyT3zq7gnY1hgqNXidKQ/CiZgRSSr93I+xkWUCmq9swBsFDDW0uj0N0Ct4t5GZFHQ0GinwNoJgl9xNDwvbuMro7UDu
# DATA ssvcwxkJ9MVD5I5Gv0u6OVXeAb2NV8bXJO/dAHaNcIv3YqM6j6tsblFJwCyWAtbYeSp1qeSTeBCPx/GB0veW6s+r5LpouOp7kolD
# DATA 7OuMp21owDAGXXxX6SHeNG3CcDfQdCoqDHyKsrwuPa+zPD97xrDAswDI6ZNFx1OQENaiWKBKET7GIDXhIaxHJoNtWFKbxKSBTb1E
# DATA TEO6vYsT6mgKZhyU6gAcomAC8KLHIcPnUfMoGwdSSEyeJstyD1W5DxI9RWY6xMCMNaV4lMwnUuyp40hBr0o955UrxEdyVHJhOu8R
# DATA RrR5sMlspLV63bx2HGOYW+lVXudEzi6UmFJYk3mpX5lfecbX+vJa+kWalWl85/saXi6RRpOysIRZwI3ofN/GCyb3uWRNZZ2g07E6
# DATA YbSU830rL51g3/fqhpl94fVp/4y++Od39pMiLultnTgeJzbf8t9mPxz9A4CUR79l7uQXTLj8/Oj3s/8XRMnZN7OvFwGX/8YES+Ap
# DATA P/dm3+Ifhll+O/vm6B88Rl9+fvRP9OdLIVyqgOlFjLX8ngL/evYXTa9kMCbd9i0ol18f/TP99meHsLz687YHMtMaxzCS2BTGolE8
# DATA 3etNmJEjMtNqeO1HE6hryCliMxGbDrXtQqYURr2A4a0y4LMFk8jMDRgUmIUBn0Fdy698wDsuqC+M+t7HZDGyEeVIlukcTvcCl42x
# DATA XFowFwe05HqZWPNHXU0FeZS9GZXV3HpP1VwMb+dJsyRjlYUU1Bqm7DWhJjFyJMsNSuvcQZa31daqPjWPw/xB0H+ckprIrAZvB/gf
# DATA lSzYuu0Ax41olB1Dnk3hdYIORggDjRqGIRn5WICnennIcwNFQcL5+dECyfKYmrfaLFnWnJ4W0fKYRDiepRvjzzLGa5jlaYf2F8I1
# DATA e2nD+sWM6hsN6icZ0y9hSJd6uSQHzID+FNvPRRAulyTVo3kofWL2XKCWSSW5iGWO1zkDZHvUxjiLFHNyl0WZNz6rh8exgAKlb2ph
# DATA 3ZzjG3DchhnU3iZwy4yjG1FSyTDan+zuxlY/74Dm2FgDFuWDRKiA3vtJakLJyE+WG3Z5dylmEQwBQRNGQ15bMrRLWDuRvEB5hlFo
# DATA vJB120JDKt9qJ6QxchCR2XDQCzkWgcemCW+w64aOdulol452eYG0y02GmI2mNBvZxJdt3p/Guj+zce+Qlw556ZCXDnnpkJcOeemQ
# DATA lw556ZCXDnnpkJcOeemQlw556ZCXDnnpkJcOeemQlw556ZCXDnnpkJcOeemQlw556ZCXDnl5ZZCXpUolqNZOi7xshM1W9xlCXi5Z
# DATA eT4p/LJS8iq1mkf55vnlYt8vVj2/Xny7Um949Ua/1Ch55cYc15LubS3iMAd+s+yVKKOrfr5Bfze9Zi1fqeZ9P1+i8Ku/eqfiU9iN
# DATA ar9WzvvFuteoe36pnq/SLZV8mV7fzJeq+XJ9rkyqYb3VWeQDlina9U/8ajFfLXqlhu8VJ5Vywyvu1xtvVsrZMGrtRqdeWgyjUfGq
# DATA leIn+VKxnm9QpEqVvE95QTGqIqb5Rv0YsqaJ3AJHz2/I69rRGLOlNhd/jSPhtblofam5YwEVZuLbqTYqlcopaHlcfzUtT5qCRctr
# DATA 1aph2d+AllfrhBlaXljvVJutlJZX7dZgWxtaXrlVaZRSWl6jXvH98MJpeVzt8+sNA/buz/mmqahw9vIzKwBtG2TYaZLoRZybytdF
# DATA /x/+UAu/edwawnJjZxX8zYrl8RQ+G7InD54MsldZhOylwZwAsqcdkCvzyM5plaEKY6fqn+0xKrGdxsaAGcRWbCPQY7da4CquZt+l
# DATA +Zqzs2qNOXFMThiinYPPOficg885+JyDzzn4nIPPOficg885+JyDzzn43AsEn+O04TRCXts8lMZX1g1ojCCSHGK5oaX9qWfoY+gN
# DATA +ru3tvsLfCeV4h3dkb1CwTz5SKY1v/TwYedaP1vJuObvFD6OoyEF8CH9Bz7UTWNefrilj52ncSlMniBfP9x6beFEugrgGj5rUtQd
# DATA s0NBh6rBT5qt5BTC3cHqNQer3YHqF+RA9Un1wp/uQWv2S6autEUcUT+jhbkXxx2cLfbYT2iO2TJJAoGs0dl+2uezn4Uzivz3OWu1
# DATA LztIft6q7cvP5S/Vb9/gmHzqpzX64aEI1KG0teykqhxGY+ZhSFFI4kEIIRg+WitVjU/AK/cbE1lENzB7vjw9OZ6DDDLZmmlj5zkj
# DATA 9EzhAY67XTim9YFm0T1E4FLV+BXzh89PIiK+UE3kQG6QWidPR6zmaZxmNc87g8oZVEvU6NIK5QRrnGDNae2olfbaxQjZcJ+umwFZ
# DATA UqJdwRoYvXgS742DUc8SFX9qumnnALCkcfk1JUNjjV4n1CwWYwCBnKNgsRr79WA+CEacOdaYv0z59lxUiz9geW/pG6k2QiEFPd8F
# DATA CBe/DludXzT0wieUj14yPHf5YBYtfmuYTPvBRNTLD1XyDpDQEXXiXY/6u37/ImSLp6ypNNHcmSlrgM+1hvN9b1WUpyHx3fFEhF6P
# DATA czT8ne+7mP54LxwnLMWElSrm24ssDLON8kFEBvx0RA0yPGc16nraic5Z0FScAXiwwgARg/ucJaLnWJPptEyCzDom6SGtFeQNDo35
# DATA Ib2NwVGmAEhbUd0sB6WK8pgc2PVHNaHDVH1KBjQ5cZSskJZqA7CodaUsXSqoArG4lPcAAt/h0GPwyrBNBaXlp7qKekB5nzMKWbHq
# DATA nbWkKRaeDrVWEs+IxtNWCyL5XC7MJEY1ifuML5ZxQDSOxlMIeXk604yOl3JvhvICs9gdKN3UzVCPz8/0wzIo3ATETUAWJiBZC9NN
# DATA QdwUJDsFWTmxeNpamorXwUyLXjBi2HCAGYYtjp2ESndPS0HOiUUyakerQyr0USiTGUvncWILQGKs7B+AnzQVXMi8xKO02Ck1Zeq7
# DATA qBT2wyVKj5uqbXJqR7de56XNNN6tw3R2xNzl1jTqd4wWn4oMOxoX3cbq8KgFoNfobVntZ2AVPikLS1lA+scUnm2usIpAj1kx3LPJ
# DATA 4qzsXqGh20pKFgKu3mu2EMAqVZ9flo0R6uXWHaZntZ96OeYeNjX8sAaPMZaajbqPbctYOXLnb6cJqjrM8AZ/Wn1nux8NWhxRfFh9
# DATA H3XMMTZl0Z135WN673VJ2605TLm2NWU13jY1MaKsMTQzpYvNwNLs1Rnp1HIOxh0zPeXNDzJRVfmYzYc5MBfvpDbdgewskIntlG+v
# DATA eI8HJhnz8TaZCuXI8q37EbOaOiHDhKi1lsVLMIiTSf9QwS/xE6xEI8XOazXC64qGExkCQ5HDxC7JpBcrPdFAoOdaPJaB4kMjNUst
# DATA l6fF2r2tpDA9WGbKOlQHtS43A2snyMAPaE7cZ999NG7TdDHNQsxRqWMAisvu6NQsB54S6hY+Vlt0qCe7w6sEbBvz3kqY7YO4hUeo
# DATA 9wulTlNRPE5k0UxRwLgsziO7rFZywvxqrs0v0+Qkw96D5Ce1i73QZBW8CXxPNo8MgksysuB9QGNmzmOVvIiMsEPlf1IQMerOhRIn
# DATA u1XEHaY58zRsMMYt7JxHVpmO54QZVV+bUaoXk2x6E34cMeejoVWr+NVUIQ4olgk7YoJxX62eat8MnAjYBhdAq1ZWuniajZ/h/ds7
# DATA TP2FIZYAsSdfyLkAjnGfx+0QkrqMruCbnmqbrJ6gTb4NEB36NGp3eUp0XiBXprbZl6m5CbVOZaS18hYGySEW9zQRjh4hm1+khzk/
# DATA xRZJgPGyZuRPs4L5pc1r2NsxFTGNkf3wkN0EaR3r0y+phaO8u+Lwo9ktNUH2xKXGGjKEenh2WOlFVLUoKtYW1IFxIidWdZSsFXFB
# DATA gUY4jtpL8y07EMveOnsgNlckG269G+tdcFp5mk0wtTsNThFVkooSrfO7cBxD7HlxQKQssVE4AZrXRon9XwIS82Z/mn3lMdYL9K+/
# DATA HP3X2Vezv8y+WcSI/d+zr2ff5mffAQB29BsAyP4KXNjRF3T9P2bf099/oL9/mP1x9oN39KWEjqC/AXTsq9l3R7+bfXv0Jf37e7wJ
# DATA LDJ6M4XxFYXwlQaT/WX2laOJPQMU6KGs/GAfT1up1KcU6FEYj5jfyIB1Htqp7YmB2ImhfM7eRgw0lktaieHyXeijU2F1fgP1IJFI
# DATA yLPzeC1V7A2YS8xuHx46nJjtQ1EdwWXTxLIFcrEYsWhoreHe1bVU/7LIEhtOcAjQ9LH4KiNdOD5PnlgwEURBL0hoOIUFS5Zu3O06
# DATA nNimpXbuTLE7Qb+NVcdQFsAOU0B1MOCd9rwE0ud1Eq+LqYTHXDiW+zOrHCDpDgYhT34xlvA6YvSrkOkbXicKJ0swYsdWutXWSaYt
# DATA PT2G2LEpcBwxN7qfx+iueWInHtRfiEWRyxrQz3k833gx5ESj+SUN5lIj7TxIt1s9/aZzESgxO63iGFY7OHoxPYfFh2xCkQITS11Y
# DATA WCRak/S3wGDvjxKhKnHSJkHyWO1VQQSiIU6O4RifypLNUGIAGMlQvQ9el4I1dVKyk1QbGdbb2iYAfCrGRjvYBFjbishAWGIXTKG7
# DATA EE2W2QPKGmDwEewArF4ljykwE48IznGuTVS/+tiljT1k08k4kjKLh+1wPEwcR8xxxBxH7II5YhuNNBuewNjQOL40I/90vsdzMPEd
# DATA TczRxBxNzNHEHE3M0cQcTczRxBxNzNHEHE3M0cQcTczRxBxNzNHEHE3M0cQcTczRxBxNzNHEHE3M0cQcTczRxBxNzNHErg5NrF0t
# DATA LZKuNqWJdbuVsPEM0cTsZeeTYsT8atkrN+uf5MvFvE/5Uy/n/Wqtn68Aq+V/4vvlfNXzKyXPL5a8eilf93AX7vAbwIBls67TbTbr
# DATA 3QXCGABflWLTK9E7KnWv0sw36ULJa9QQZNWrAuPl+Qi7ideVm9lgq7VGp9FdAuYqFy0wV6lZNWAuv5itD61KvRIuCaBasQIoW2Sv
# DATA xmKVqCwjg5XqJ33eypdyue6VKR9KVa+Rp798f1Cq+JRHHjK3yFm8OiF2KdKdlWq1V6035khn5oEF0lntFJwybhmGU8aNzOKUUT2q
# DATA 14MNOGVBt5zhlHVLnXq7ZnHKmrVuPeWUdRrtSquScspKjVq5Vr9wTtkonBxLKcP4ou/bAPNlOcrK7CYrNHh5DEPaziIJzISsMWeZ
# DATA mW6l+jOvSn9KVXY6ZtBckqMSgorwZk41lSrjWCuZ6e7c20sV9gWyG2/OthHP0xqEl05XLhO/NUN45jbtAnPILofscsguh+xyyC6H
# DATA 7HLILofscsguh+xyyC6H7HrBkF3K4rA4XJ3gMNl9J5j0Ct1+TBMbmH0fbuEwFqX+5zBprqtrfD4KF+UrTbNgqFKrYevzw63bI5rg
# DATA PYGLMuwfUm5cQ9DXKFe6U5EL4+NhXUvnSp214lUkkLKA1NKHuQJ1OAsaZAhSjt0EfEgbB1TMGSzR+3OULXfs+KTHjt1x4+f1uPFp
# DATA 8FpX4Bgyu++0v2s9ZUsErEy8lx5VXsLXuiqHl5+pM3wXAdzKHrc+Z9LWXGU4LWLLcqSmh8hVTqdYEMgzioC8Ul3h7OqVb73OE3zW
# DATA ldM6dFx9IBQ6VHpzchDWVJ+DgJ5oxQc47RzuTfuQ79OycwPIicZdqOF3pmOuoMF4oKXv1Zl4freOwG2yrSMyfnnbrI6CpoRR9nSx
# DATA SNpiLc4J/EQeb04RywRLrX1OG/TsuC3gRGUrxIs7ZJNNxy0jPPmCHPW0wnB2lbOr1oi12ZXL6bo4XZeTGlRrcFsXo/fyt8P4AN2/
# DATA KA60gj3RWIPkhhrY/MuXEzsHuhavQKgdIPpaRhueJ/p09f0h9BZCJcNi3GLe9uO9nTkS0JDXgVLQjgrCdFP6ewaHRImmLhl6MoOI
# DATA 5W2LBfTZ1LPIlhwxjrCXM/1xhZy9+CEA9LEFW0bY4kqD/fax8dXPp/2qvpBCuBrFZXG2Y4ztOnaU10SYPSVMaYK7OtWxQUYdE1f1
# DATA qImq/p7Bha2Np78mlnMEJbW+hNaqnC6iRs5V3aIkoVLdeln2mqp4qjVGW8s3vSS9S7QvKaDxVzFbr0sQZ6NAWcwmq33bwkdKn14h
# DATA XgI0e6MPeBeuJ7sBc4NmrZTwSSQqLjzcocfRLqhPptQLQas8me7theyBBjCCVyZUBxGPgbEAVIlVpTEKc6BDACr6msYlDDT2jat2
# DATA BwEVMuWn7I+nooEeDBSCgz3DiIUCFYzTREbyTtRl6ZSJ6A+xsrOntvKGJj4iRw9pIo7GEnWiVJKIZZXhaURkvGBEdQ4D3KZsp+fE
# DATA 2M2MYM7cdebuSnN3wbRxFq+zeFebsFdE4fAOq+9Bs7iLQSYasozZcr6T5sumUoDjcBAxoiO3SnXvdWEKLgw3LGy2N406wBmmAyOF
# DATA Ru21MwWAkIe3eRM4C01YEDg099G4bpim2vfEQ/37zAnAeDaOaegIJnrMZTt8QA18ChNK2QHB3jjU+MrFIVPpH1JIHRqqTXLgqloY
# DATA OFkaEOIy7DkKWRPOCyao0BThmza1XZMhwye8PQrviAA1oFxfMSMQibd4n/c3KQan5ueONMMLGzkFFPIkHLcj7HfMQFAlw7lgWLTP
# DATA EipUXrKC9wY4W9yNsjeNoV092Fx8FwNMQKyEu+7tcML9LCcDpk0wmfO34eCaiazHhxvAPlmXxttajtL09zqRH2DWptk7qu+HymRO
# DATA NPc0mAiPYP2RCrqf5JiOkRhqpza6xEx6F4GhpzyECaY2WvLIMuYhqQVLO+xE7UBKUOEzkZULNd3CnIVPaMzrH65L5bt8pNiYX4wv
# DATA 0em8zTs91SGR6TgHTzIrjA908fP0UZFyIsBPlPk6hBKfEv+0GGmcpKxSZcF7EIaPmRICtyzzPJCXfKuqFlqxMsOXYf+pcEOgtggH
# DATA sXYUBwlPaoO9YZxEyQKZgw2x43S+H8bUMXF+pl0Qt5oTk6LZp63HoHPhRFtubtUY4N5mJ/YFkKHfQfXV+2CouQaouqL/rqcpF0CJ
# DATA vpNxlqPNUnkLXfYCSNFvRxOelY2p24IQpEAhFbOGe04RmLwAWPS9vrwTHSSnNm1cPM3qXAAo+jZ1QLrFo5fqGH1dLlJ4i8adc2Yn
# DATA P+/zN4uLQ09NEhuL86+A4My+n3119JvZ90e/nX3tHX0ORA19/Zouf3P0+0Uyzr8x6ubfGWqTvXv2Z6bkePTTF7M/zL4++mcVyn8D
# DATA F4eu/XD0D3iCXvV7+uUv9MI/e0f/mCHtWDAdh8Z5BsjCDGYz2rXCyILnF0iPnGxDFS5wl7utA0C5D5RFtReyYvBjOJwFJzzRrESG
# DATA jPIgCobgXn89AeftMOjyWxz+JjPH5PZ+2fQbqzAuDn0jSUu7Ra47XZ6Hzd+KkcPcyFO9ce9w0hucJ+6GN9nStKeHGt/hGQGQe7wV
# DATA E7c77M2xJXbuvBtMcuMW5phcz7THGjtF1HSY+5d+MB6opal08hkl4ope2EMt+uls28pcgkqLejFM68h0gYN7AX+zvv6tNj7SdvS0
# DATA sDfrY+6IN27QPsGgrcE2JxurXwxf8OWM0+c5TG80Sm8+SF/8GC3VzyTaDMiX1xYuglRj0iOE5GQ+IXr/RbqJge2JXjzQMBirTGSm
# DATA SwMaBrugwwllCrohUiSKsdyOp2NhU6Tjq064HGWnlyCvOPjNuDVqip8ZgwPjXNejtxm3E7qxM+2HekskL2HBq+glo7AdhUnOxD9l
# DATA FytHaz8S12tInW3QDSeHGVegSgfjdBkTzSjgtiQqmyAHqHGAGgeoOX9AzfEDx0Zzjk3s18uxv09jfp/V+nYwGgejcTAaB6NxMBoH
# DATA o3EwGgejcTAaB6NxMBoHo3EwGgejcTAaB6NxMBoHo3EwGgejcTAaB6NxMBoHo3EwGgejcTAaB6O5OjCaciUsd04Lo/G71WcKRmOW
# DATA m09KoimXGl65UuwxfqZU8fxK+c1ytZTNjna3Uawu8k8qlIBypf4Lv1Se559Uqu1KYxn/hEspG0y52fRKldJ/8Zslr1Qq0p+61/Q/
# DATA 8asNr+H59ZLnV316V9krNcuflPxa3i9TGYKYU8n7NbolT9/opgrd5NMDlf9SatKjJa9MIZQbn/jwIle8Ct1TrmXSVQkbzVpxERAj
# DATA EcqTCZ/3/cbAr1C+4EW1IvA8c2ltNzvNoL0srQo9Q6UYkfmh2DWVYjVl11SaRasCV+TL4ZLa3GmHtXb3FOwYrsiGHcNtwmLHVEr1
# DATA oFo+lh3T6na6tQw7huLTaLcsdky51uSAhB1DnUQzCC12TLXaKlcunB3Tp1ZwLDwGTqPP0lsN5cXiuKjULTr22LlXon8bP7PN7Tqb
# DATA D2mQxyNpbN4Mb7aTvcXLYmFcV4Ul66dkYXlYqvRq8icTmqcsGgOU4VHU9P4Zco0U8VyKKUxYRl5V/hjXqCS7AePK9uf41hqPCqJO
# DATA GebTH/WvtjDZeuUBcSWtZoOyzGZddo69NCNWBuSgNg5q46A2DmrjoDYOauOgNg5q46A2DmrjoDYOavOCQW20QailfbZ2Xlk3mjH8
# DATA Rvf6fOpCPZZDH7i0a/VUyqxKtXsr0r3XLpvEOzfRzj/cupOqeeGwiiXnMqQcVpoumL5mmTXm5IM7N+zODVsnX9zpYXd6+LjTwyu1
# DATA Ji/kVPGrqLlQmksDNyeLn6r+xDnopUNrDm8+CMPHfMJR2uwptebSseX81ObCsK9UuVuySkIZotUHlaP7AmTn9HljBW4bUal2xtCe
# DATA 82iOFPYPL0Bz7q0hDjVPpIdNlFI27OVuKlB9AeJzD9n1pdJIJojqzalO0NiRh/p15wJ05+7LUWL4AMmUU0k2cIELKVfWnnsXZ60D
# DATA I0CHlicjHEwWMi+xF2o6Ds9ZfU55YIx0fKrJmFEGSA+36oSYU7OUYegCJpkexJKoT0XhRQIeEqpzh/W5Nyqk6pqd8aHO6BTVEPQP
# DATA wC0chCwhj1uwUEWGRr9f8N6OuqY55IB76C+2RaWiOkRUxl6PfhyHWLDqH8qT3L0cBIlERxOFlFot10FReUdjgzdXtKtpUoEl9n0V
# DATA ALUOiqbUlx58g2N1Ih46mfRol4aUVZIBOlf0cX/qJoc4+c7bDGg8YSkAGqnnJX7mRqr7IY4DqlPcMmmVO2TcOV42/hk/eeyQk85+
# DATA T+13Z7E/dxb7SZGST1EHiBfzzUL0eo7k6xHLnys4CkTPhx7v5V0Dkbxk+aArL6dxEXzIVOTovOGQthzUacmQ1iYFPW26j2NVpjrI
# DATA xI+FU5TwVGmuILGrQUpR7W4EsfHVsTwMGgC20Glo422vPx1Ew3hKU0RjEw2pkscQsRmF/T6k3TGG9pTiOtlfw4L3Xkvk9skwwaZr
# DATA aCn1yCRVmAPm2ei329F4AwYa38WJ0bF4F3YRBUGxo8pLtcYyu9jk4/MjIW9DOEygpR4kLKEuLURrPA8gYT1e9352Q3uZd78hLSgh
# DATA 8zLhpeiC906cTLT9J+JCzP7Rsb6JDJL2BfYSlG+ov4ZtAGF76kaoqrNsyHxMnneRGKtncLaas9XskcE5W19cZ+tq5uTTlHB8hxcr
# DATA dX1WAmx89NqCUkJaj+EI+9Buk/aTOm9y7EZgwCQ70bTjsODdS8UAcQpHVNoM2ofLkJ0GgaUfyD5N9h10o7aX0HS/bTwrLd5KlmoG
# DATA iubihhqQnGJxfKSNX9b6EJNhMB5rnhAfLsF74PVZYiSqM46LtEu1zo1Kyp+Un0x5svSPKRDRXOEcB3Yk5HDkaeV+ivt9KwVLCZBm
# DATA 8ZyriXx+WbYEqJdbd5iO0n7q5Zg7zNR9h9VnjJj9vl4ajeAPjZU1N3872Q3cquKD1ffssdnDyCz+tPrOFttprJE9FitF33ldUpXm
# DATA g4zH2lsoK9C2nw9DwxpX4Vqb0fJ8BuOOccLzgr+441UOWjkwB5LincGm9ctSOleh8ZRz4rZJwHyMJS9HbLDdgYhjNIaQKep9arbC
# DATA XssrTc6cSIzmMTPTGqQ0jA3iTsh+/AnsWRh+2oITlJLtTIQD0kh1hiw0pI3sifcrGnALtn91Q1+qZ7bJsaWRTYrJGi1hBsArlru5
# DATA EdEzltN13pY9UfGkle+EJfRgdQnpaiyF9GDEPthsCVEz5o5EPO7AvkArs0f2j7hBA0/qurL6LXagWQPB87IKIlKrMdRHMeVA6WIH
# DATA o7JSzl42dgqufsHc27Rg7gXjPovKBv2BLpgHcZdhrEMa1Vgz9QCTPBpB97Jzs4J3ez+OMDOmvDdu/Zzt+uZSGVH/gslZR80SMT08
# DATA c3nYEb+08kj73hOWx9+sLg/di0t5/A0ZLAsd2bTdnvZZTRaLgOokoWocerKqWHrUS/FKAs5j05BR8N6k1nWYoyIkMySO+qJyPOBe
# DATA LB4MRP6ZjIuBsMTopwg5aNaLz15QaYqufjHd37SY7k9brfn+7FUWsVa9WTj8OD5MezAtxlXwPohoutuZUke/J0tRRj5ZrwqlFh6Y
# DATA 2pRX7WAqdLwzl4Ud7avfib2+aSf2ajTu8I6BIRxA1DiGVuPpieJ1bzqIOnksFLLEuCoPHnUSNuwhLTSBZf5BoLnU6Tq/zdtDCZve
# DATA jkIi40ltm4AWMtxDZy6nxQSdqrSy9p9sY7TtP3NF8v7Wu7HecKg1uMXkF4ubl/4ZahnQjAXZoUtZLZxeDBPtmfZ4pSy0pBeHGRTa
# DATA /zH796MvZ384+h1YZcCY0ecvZl/P/mP2Pf39B8aj/dlj2Nk3s++OfrcIRvtXxqh9NfuOnv2jR39xgLNvchTi7E/0jdFn9L8fZl+b
# DATA l9gkNbrpL7Ov8Ulx1P4DVDS8X977w+yvR791VLRnAMpttjnwltd4cqCxq4bMDfFiIa/meGbE26xCmHiaBQBoKNwJLCNDHYDAGdCB
# DATA jkA3UERXqsfjCe8Zw3NdWcIyTgF4OtaS06Asj6Ygdr7Dp9m+Pu4iLpueNl8gF4dQo9Ei6Md7KeKLdxjyy+c53Ne7UdpNvx5NLHzH
# DATA +THUYEqrcxuoobGM4JwNDp92fGmdOz/tHcGAey0yLrCji+b9PRp3zPQyp42sJMZhKGQkDFkkE92d2tOK+Y0ijT+BSkqYdk6s85Uj
# DATA m0qWI8chexaZMKuPCQyoiASvgcFqssBWW18vVxsxc63saQHW1kffAdbc+H/O47+GsJ1i2H8hlvcuZ8g/9xF/owH/BOP9xQ/3UhGz
# DATA STej/NVqPhfBbcsmnAdJzhADHTOpbh0ipJycYRxP5VUS14kAnZJBgIUvs/TmSb/UChO4tMIxliY50TRQp8cWVPQ6Udew3SjZh54i
# DATA mWzIbBsrc4231eDIChkU7JcI248xNik0Gdcx4V7xqWHeCSS0uSjhPVTJRGhcvDQbJhMxFZAvqeVwU1HMQM+aTCmEQTCcdvF5bBsJ
# DATA yvMKPwHbNOPDfDx0yDaHbHPItgtEtm0wumw00dnEJL5Eu/40Zv1ZrXoHbnPgNgduc+A2B25z4DYHbnPgNgduc+A2B25z4DYHbnPg
# DATA Ngduc+A2B25z4DYHbnPgNgduc+A2B25z4DYHbnPgNgduc+C2KwNu86vldrl4WnBbtVsLu88QuC275nxSehvZql650vikVs2Xa16j
# DATA nPfLpT79Uyp5jarnF+mXsueX6FMtXyr3a02vWvOaRa9U/6RcoateuepVSm/6fvOTfCNfrnslP1+dy9Kw2S11WnPQM79eqZUry6Bn
# DATA zcWSKxW9SrHaq9ZL++Xam/Q1+wITVpbCVqIUlGpVr+7n/cYgX6l7lYZXL+b9On2peJWaV2vQl40j5pcXYlb1AYmrf5IvU6HmkRe1
# DATA dygAxLZfpgsZWhzv5My+LOzWayswd6oCt6Mxn7B7IpW+lKLf/DqD5FjVoJZtASZYCgCGjSdPF5G1njzcaGSrfbfL33X/y3KoLP5a
# DATA blC9oTBOiI3jZqSxcdIiLWxcWG1UqtUsNo5uqpRqGWzcHEhOsHHNTjPFxlXatWq1nmLjOu12q5ti45qdcrMYXjg2Du3veGxcWRsF
# DATA YhLoZ1bw45DMOf9i9Wdehf6U6U+t+jM7iDle3FsDmkpMctgKjPh677JiB321Y25Pk6rF4s15Z564e3KN/YMcr5KtWBFT0QC8avTp
# DATA pksFhYqVF155nA3G0/spMgaJmS9hV7V28WkvZ5ZppzKpRH/8qjb52VcUTcjCamdAdtqHTf1yaQE/V1zNlzO5n7NzYI0pckwC2Upw
# DATA HDnHkXMcOceRcxw5x5FzHDnHkXMcOceRcxw5x5F7wThyyuLIdgDRkMLfhb334Za0OUr4NfkORRjOBjYxP9x6GIyhQsuPeHIzmtc1
# DATA vkDV4nVsptv2d65RbrQHhQ/pv+Ft65T43fezx/D44XeCSa/AM/RtDufnfqGKENLjfUsOjafKt5DiMt2+Rs2lx1bcIWp3iHqTQ9T2
# DATA 0SZ3ltqdpV6jl/x0z1jL0eCcPuu75KT1fXMuUOpILqusZg71yoFVJcjCZ4lhRx8oHWY5yRuyyn56eHIUHGIyLYcnobUytE5ObqyB
# DATA /LqoHreEEdUBgQqvDkyHjo7A6R5vonvcDpJpoGTT8Gn1nehSKWtx6wfycfW91MF24pgz+j35+CwoIKd5cUIRxDurRRB1rooIIhll
# DATA 48MOdIiC4X6QpAqIODlJzQsK4u2Y3SbT0QjnnrHRAIfRvLHIQibAc8hhdvaCUVMLCx616ghHh+d0dHg87IwPc14YJIfcUM6ueziX
# DATA hkuTqLTq3/kphpqarHSqYTuMpzAj07JpT5Me1dyQRXJxBl2OUAciV81mTmpEwKqEXSIYBhRUD9w7dBGpMrXSc+Dj4VPUD/hLW5p5
# DATA ciZ16jQBz0DBfLBxwdynqp6HW+UQGuCWcigfbM5RiYxCbj3cbHQDYZAMCo76IzQcrRuKc4RQrIJieDhi2xAZbqlpiOAA1rZkfIv6
# DATA vXjK0qNn13fNJOXSSunUndvbm3Zu70TYOQMNj+nYUkamCQrN+bArcBKPdNPpRuMBxEmnI08VTDxmCTb+VdRLDihR47gl3d04xFfW
# DATA DZsOe2RUQd3AlvE4S5FkYn5pJWINkicskoeri8QMt1ImD8dB1Be9lIDMGlMo9H0C4wT2Wyw53KFpD4w8VE1DwxwHqjkozWrAhLXS
# DATA TKokkYq9iQhL/1DU3s5cMNnoX/228mDTtvKBzElpghqNqAqbgkHthuVMU3fZIgTDmodxno5C1WOU8HiPaT54tNiYq5BZiWiGK5Hw
# DATA CYtao3ThOT1zUczF+MXVOn4e5ET048675bxbm3i37CrmvFvOu7WxF2ulE+xivFssvGUAeIG3F8ciiqd9W1dWv3ad7wtHGjzbA7bg
# DATA 1BK6KTaMqH3I+lrG26SWZxjNNMT+e56oqoXS7fZgR7m9dMOUSSlKUUI1z5uuLL1iXD8l3l07Rs+NXmwQsYFU4m3Vg4C3vOqNvOGI
# DATA t14X/NUOMl5BQi2PVbmOjGpZ1k+mbjQx0w8uuKZ8ReiF3dO54flee7Daj+UXquxAoMCicEx3F6qZ+xd8WcrCMo5C2XRDQdzV8oVz
# DATA vaxlJqH8KAp8uEinSnZf2aZLekmaeCTm2YjGw4lsSL8uQZzRABIjBYOR1d5sNcuHY3G/CjEW/cCCSnSf9RqH2kubkxkD23DsFQn2
# DATA gkh2XWFLvGCkaPZQ8AzkLq2nBY8LLceDnwVkYfHKNEjoVSbaOsbrYE2NoqFgrBAmWcRGghALiqyghkNjkHRsHUrzFGG+AAqU9ipi
# DATA Mt0Dv5Z3CqRrmGraOtQSlKxXmcpOTtlCPfTMdgG9J27ENozGyyKrn3vDMx1qnOnpTM9NTE9naz6/tuZK6/AKqlXziQ5zumDRDOtb
# DATA ZugbMDs5VqCQj0NZJky0FZo+xLJL3PlePXXrqy/5yn/LOZ1bL1MPOt+w9LFAhGuOcDXkhJ91ZlEuBH3+Ni/CPX9cT5ppO8ZkQd51
# DATA OGyL+W30r269t3Daj3fwUSEuiJtbT/EXTssGwuLpsRVtj83BwQ+CQ56+QM/ZGGZ3eMlOJkdDsygIf+IehTQ6lOVFmTuBRjgK9nnu
# DATA UvDu83LWRFtQ6h5ln6FWwmUszjg2eObXugKsh5OVpmkdG1WC+cp098moj1CT6Am2rssypFTvS4d7XLrxlGLKqELth/29KXUXNqzs
# DATA 346+PPoNY8lAEPuGP38HdBljw/4Iohh+OfpykVL2v5ofv5h9O/sGKLK/8oU/Hn05+w6Xct7sT7OvGEX2G3zHDfy6o3+iPwCR/YFe
# DATA B5DZN/TzV4wy+5YC+B6/HX1OwXwLWNnR5x6F8RVd+CdcBBrNscueCesQaeOpF/whLFeua+8NEEmD8WOs8gXDMAe3B81Kxzx3HAUy
# DATA /cEgQzNUHJXmNSToZXjTIQfG2uTTqM9sVGrRAe/mpIllMBFIaoit+tSZraWWCUw6lIHSQctsW9HqMC4bXTZXKhdHLutEcg4zMXe+
# DATA pq5wRV2gl2HcM3dSpZOaOD5neBnP86OENyCgOfDOMB1VRzDbrNTOnWKmO5tuxM8FfXEqJe1e2JnKNpG+sOMh+cEgZ+7FPFZ79fxq
# DATA fhANYWsHfarc2EdyU3t6GZ0hVtg4pIAFpBAN0QWLGagsI2mTfYNv3rRqrjZxsk3taeHL1kbe0cucBXBuFoDmlp184H8hHESXOeif
# DATA 95i/0ZB/whH/wgd8qY+ZxNv0sivRfC6CW5ZJsRfKHD0RjxRTuL24m923x9kw6VEs93jdBI0uwj5NYxkx4mgQjDjh8lr0UXJugGon
# DATA qEtYatHIJNmvySOu1HvPiLMlG2LLOOdUpfAoO6Z4nQz4AIKIu+xAGwZUBAli6XVw4AcvfzyMD+R0REdtLgU2ahRyUffi6RjsL2ZQ
# DATA Ra2oj6yCdcegFRqPGDcFY0E0EBjPZc4QKJDTMF4On3IcM8cxcxyzC+SYbTjSbDTl2cA+vjwT/zQW/hkNfAcycyAzBzJzIDMHMnMg
# DATA MwcycyAzBzJzIDMHMnMgMwcycyAzBzJzIDMHMnMgMwcycyAzBzJzIDMHMnMgMwcycyAzBzJzILMrAzIrNSrVeum0ILNuN+gWnyGQ
# DATA WWbF+aQcsxrlSbHSq9Ua++Vm5c3aPIKsFNba3cWcLPqUlZVetVHnz2VAxtTnCmUsf240PJ9yuFwpDvxGMU//qs++/jwH9aKc73RL
# DATA y6BepcZCFEpVikKx9IlfL3q+DwSbV/KLEx9u48Zx+LB6Nai3l76pWlvAofn1KrhkXrmUb1Y8v1YBBM2vUsb5ZSa/VZrHvK5drrWW
# DATA 08osiFoe04EAAv1So73mEpAZxSUFmVGkDMhMcGxpC6iUu/XSxvlbW/KqUrGevqrs+xf4qrIQ2eRVpVr9Al9VLdmpahQv8FU1RtHp
# DATA VJXPOQNPBJXjLk1D5aR3tKBylVKt3OhkoXLzCLmlULnQD+udagqVq3ZqYaNsoHLtWjtsW1C5Mr23UbtwqJzsLszLMoMe5so8g/D0
# DATA 6pSxXRpi/tnPzEPh3gipM4+C3CL9rbKM/gb/Z33/IFcT/6cKeRBsBnkr1Ne5NfX0LA10foHENu91+Sx4NlXJZMJhcYsVrq+fthrU
# DATA gXWyTq+T2WEeu2uxVLUaDGdl1Rp7biHO2WnRBVqHjjHnGHOOMecYc44x5xhzjjHnGHOOMecYc44x5xhzLxhjDnUhmtAMfxxAi50q
# DATA 2E2Dndu99amZk4ySXa4n0kvx+WVc/chq+dLwd2+ZZh91t3/Mj6qGu/Op4tJp5SKIocqZL0YcjbirFuPy5mfy6s5U1p537YB+Lrg7
# DATA XEoReMylkyUd+968v/Nzv3rNryI6OrRbEkBrSvNFFKqJGcvNsgLtMAw7CXh3+hlA8kSGIDHaS93wQDqQkZzKE7EvusQnGDPJQUbj
# DATA FOOuNuvHeLFklSw+bfOEbqcgiw/b20FuPxdRIQTXlKG9v/Pz7YiaRvGVWvGGv5MrYtMXt3qsP+0Odm9tD27t+pVK8ZUPt96lKslH
# DATA LDlUZJAyfDifuv2Y5qyD67Xizs9KlR2agXVYz2q7lPtwq4i7+TH9zOBndOPiTTfTmiNZjhqwnXCsVdWB82iX47eN1DNq8D8//xdk
# DATA bHITV67tLivM7ejlbCG+4ldvFHVucqg3P9spfBxHQ3qWwYUSafXx2pJXdqNhlPSUKKpf1YWJ07LicBEA4vtDqEwIDgDPM/Rwe67C
# DATA 5HWt2LGrBTUerkcmW3Yokje5wKkk8npWQc+/ss5k5JaHxpOG8ynGQTKG1KFjrZyhxS10yJqtqCudmXdR4Po8dGHyBP2MFUcJ+4EO
# DATA Uz9EAy7CMphGfRDNKUU4pYj1ShHWMUWnF+H0Ik6sF7FSp/RCdCTuTSdpA+BdW1rTU0Z2IypxFWWMLkPHXowVkXEfixUzp1yPS6lu
# DATA vb7fdF7mghF6LzZvqAVzJVy/Qo9eDbisSD/ByXLmIRlh72018h6npG+CMVFKr6RK+pXiMin9si2lXy8VbS19v7paSt8yaBB9jjhN
# DATA TGhWxdUqK6efudnKNzuIBbV8jtmtclHbH6t19Sscz0r1+DtrHGZtSZgL2vv6ACOlmw8i3lJGsTCD0HLoVvlF5UzKhMKkgdOULTft
# DATA +JjPhEw5vZOOZzwUygTklnV5rkDO57X3MW5yi7ffml69mJfKwUePBtoxdROZN2d/SvGeabmspCNIT6YwAc8uEuFt+PdE6kYZK9qS
# DATA t5UzjMZMhyZ0lt2f6eTZDILwR+YWJcBLVZi1ZyA5w3oaDDdgMQfNIFilQZMVnbGpYIv8r+WcMMnAzPwBI6FeoWDflh6CbAjYsXyD
# DATA Z1/cImthuHmJm5ccMy/J2J9uauKmJsfPOJ6qxB3GeFRwHQlkTj9VuXvdTEQEeMCaT6atUekFCYtcQXCKNceMCFVOlNMGgTgujRCa
# DATA FmuYn1zMoRewzcbGfguP1jbAhK/5gQjPhUKYhasU7ZsSQxU6MVMaZnRR9iSfTBHNPf5tmhzSmDtkphclUDqLnIIQyfRID7QMpOfu
# DATA InmsAx314km8Nw5GPFSPQhjSSt43GrP0mCQxO+xNAsYqvxOPRVlXjXXzcFNBJFuWn6RWzBELh8YdGfq2A4VBxjZB1bGJ7x6rUwdA
# DATA kUMf7rbw0wQr0QtsvCg85CAMsNQafHvrYh912KpbG/l541FSYJACAhFODEEYKv4TA3pusyCcwl9oTeJUWU9YtlntPVUsLXTZwiew
# DATA eu1A6u+aNN3GDvthDHLrfLLETMhyYxdUFU1FJrPwHtz76s3IVzLbeiD4KmSDZAH/AGAvIo+15DbLtsGoyaESDSUpYN7BextPE5Uf
# DATA KuCI8uH2fhx1WJKaVdoAUJAspQEqZmLsAFJrIz7pxrtTlk/pOdZ/KzQR5QCXSZmOMxbUM8LVcVdmYdChGwzijjRuFB5fNmXl6cNz
# DATA cbcLn7ouO61hLWWY80bTFlko1nOsP8eNMOjAAvLGXIelstLYxfBifqUHEjsNOmRpJ9Qm1yXxAdDgCu41wSBiJRGEMnkh9QwRtL2o
# DATA u6O0juj57rTfP1S8FRVTduMkXFEl3YMMqZCVBaVPOOjFSh2ROkjsBKUiHvfQDqXA0MfPI2rFMH3+7GlHC3O29MZq0M50fq5N55Oy
# DATA wp6yOrS95389LOwhRgINu2SjSur7elrY1VGTfiYkVY8jSKT7/jXL6zyhYlmF7PNmis0rji9Fiin3G6t5o1B5FxoZQVIjEjFr4r7t
# DATA Dg1HuhO79S5rlwhXjKYqrE8skyZ6H/2Oe16PUssZvQcks4ewy4VGRvUmvVdmJrBpZXd6DAsvghTZobrpetxf1TzFXoadi+rLU4tg
# DATA mYNxLSYErlhDcl7QH4cFxjLEozFqdBKaZiYKzoGZrso2GzLsB7iL7NyMt5VsbogW21robGnzFFJyasqi5NrAXVhnW7D1njcrL8Wa
# DATA HYQtJX5tU83+l9nXs3/PH/3D7AemjH0z+372R6aL0aejvz/6fPaVTRg7+hJXFgFn/ycuz/5AD3/NiLKvPfryFV38hi5/DzLZ7A8e
# DATA 3/MnZpz9s9x39HsFMvsKJDV6wZf07+8VyIzj8xXidPSPYKAx7+yPsx/oB7r/z45t9qzYstLI0fC0+DovWRnyJtaBaA4n6uI8eYsp
# DATA uAlaPeJIrfx9qCwyQ168R/E+e3mCcepVskiIaB5rUWZvzkfD4cxsmzbtKC6bZrakYC6OaCY+lWTh5er6/O2yg8DcfT9MaARqy4DN
# DATA hXTOaDNxL4meP1wrsvDH1AIHNtuo8M6da3bbs/TO05mBqQG8aAwhnWmfKRytQ/yN0xTKPQfqiURQ7Jw7996n+0XTPKc5FXq/i4GY
# DATA sP2zD3ixRxf7CzyzDWvmahtnsdk9LbrZhklxnDNnDZzWGtBYs9MZAS+EU+sSDYCLGP83Gv5PNvpf4uAv9XMhJyzU2VNpQRdBNltI
# DATA JNPNKKuSxWiBcSbLyh5VT9TUGwJ6ynlvPnx470FOHSxVK8NcMrxndEz2A6/scDIwQsMpkdKUxqostedB56keczfFm5mq4FFeQxks
# DATA awAgZVEbmLPUCMgCzkbjsAPfSNYosI2BHDdTdBYeDIxhW5kHbBWAQyXmoSCnOP4JvSalm7FTJTlM+Ciluqfl+GaOb+b4ZhfKN9ts
# DATA rNlo4nMiA/lyLf7TGPznZu877JnDnjnsmcOeOeyZw5457JnDnjnsmcOeOeyZw5457JnDnjnsmcOeOeyZw5457JnDnjnsmcOeOeyZ
# DATA w5457JnDnjnsmcOeXR3sWbPSrNVOiz0rd+vd1jOEPVtYf94IfcaZqzKPKWFC26qUMofF/Fopm+tlYTlJtjcyGddphNWwO4dvKjeq
# DATA VUF1zeObKpLFVjzk3RIPYV+l8SjPH1orpdGozGPrlvHCahYvzG82DIMqQ0j7aaXT8OvlxZrTqFDVafSkzlnJC2qtZjtYyk9bl7yS
# DATA kNIuKHkli+a1cfLooXNLXlkYXxeUvLJ6+kTJo4fOlLxyqXQlGkm53Li4RlKu+WdoJOVG8cyNxE7euTeSTPJO3EiQvLM2Ejt5595I
# DATA Msk7cSNB8s7aSKp+40o0kmq5cnGNhGJxhkZSrdfO3Ejs5J17I8kk78SNBMk7ayOxk3fujSSTvBM3EiTvdI3EBrYWG16lWt2v1Hrl
# DATA ZmU/X6kN8n6z5lVq++XjAKqrG8FpaJhs6RoaJhvNFg2z3KqVGtXT0DCLYdD1LRpmuRY2KoaG2Wq3O522RcP0q/LzxdIw1WZemd1Z
# DATA zh617Gb4mDxhJxPddqo1eY19ybaJTKiYvy7eM79VYXHJrMFLZoUGtsrIolkmVLVgvjbkGq+eZR/Ts8Dlmw3Tu2k2uTcOBpk1uuOS
# DATA q55Zsjy/eINeqV/I88W7Uy/iqh2S8iJfikhcAQuBYKlhEfWpql12uaDZbMIDczJ4J3uMlqSK3YYLvufF7UIruZ+O1ulonY7W6Wid
# DATA jtbpaJ2O1ulonY7W6WidjtbpaJ2O1nkOtM5FNOde1FIARazOwfRUcEzNoKIr1/1ipVGt125m5izqMT48jMc04pAM8+kIV675eLJU
# DATA uanYmHfVMXboBwwnvf6h4VwxIpFiQvXqdezv3y4xFvGN6FVBKr6Nc+ZySnnUnyYeBJs99SJ+VkVp1fO3vVL1Z+ZtqdCOzEspD/ZD
# DATA RnVuUxx+jjX+nWUh2SxD65ypE4RxgjAZQZjFQ8dOHcapw5xeHWalkvJFqsbozhpyENJeUFys5ICNNrzzxpKQuTo6ZpcBNJShkkEf
# DATA MpCxCgdfPQYkqJ/MdPNJBtkGN8JSkKBvcQT5pqK+0+AEV9MEzXAOlqD6jLBZsGSEQVEnwdv+2+jV44CIVnAmKfY1k5rq8WkpnSAZ
# DATA Ym2gB4BXVEyC7XeOj69+zkTWXLBiulmmbxhTbQdxO4VQIiRHUruFuq5RFB5XXdJAUvBkeslEvX5czGtrYr0S8me6AD1l4vFQFfIz
# DATA D/1bRvozFmJoej/0TFTHhOXBzaNj5HVgG3CRBgOeA/DyDAvCqLlmmyZVrBbNUBPsjaTpTc476FHlI+NwvBdaoanc7Xapr21Nx/Bt
# DATA 4DmaXI1DKDRFEy3wo/zVMvNIWJablZioSh2Kgcw6mHY9K3h34gG7xajryymxnmHH6D+loktqMteRJ4Kx0kVKbZkUMjugeE3H7FtV
# DATA 4kMbUAOfN6UYxzxxE4EVEwFn878QNv9JSSdXRSnS3imxHnnyRsQjpqgl8no0ROKGrNpDbWsQrmWfPD15yWdLXe04dem5PR4XAT5Z
# DATA FNA8b/jJMh3SpQCUTNnpLTFSkZcB/l6HPa9NhKV3sKrn2jteFdPaGBonlPtW5D/GVUYsOAiQiGh8BhMpc2VuboLDfJBOuzVe8c2H
# DATA 77yd8+48eJBT47C0Fx4WlJY7IJYyLxKhxRFUQgOtpMpKjVQKRvYzStJ5gwbbcQOPJhi21xAVH0hnIBve1sMib1uRUJVYp+g2lECH
# DATA Sh6VY8cJooR1QtD8wmEbiqDDkOKn9FhzVHupuvb0MpvIs2ZVWdeiObMdyDFR14KzYk3raCuYIhvc6oBhKP4MgZHC7Bftezagx4dK
# DATA ElPFsuDd05waxJxXx3RHFnjdIOpPx+tolvclGCxcreJZvkAWuN1fOxvc2eBLbXBVSZwn3nniM9bdSuP96ui3c53GSJ3inANPPIXG
# DATA Ay++mijBxr2YB8ms+Lh2oc/Tz6Yj4AQL3i+wR/zQIFrojs60DRGZAcZiI21s/O1MNGZ7Z2Mh91S3QJonvt56WRt+D3DMmxs29CsS
# DATA BcCWGYfqC16+bqzEifTekzE+ijA3XtUWZz3ZG+OYxmBq2L2lN7wvY3oX1OYVt3wAkw2pFC1uFpvGrdfxzuv6/TIYzUdDGarKgDMW
# DATA D7+pc+s1tTmRa3DOw7DSpb4/pjJj7CdVtUmH71RjRM6TwTinpbbBuQOmOOlJuB0VrRXxeCcYUp3q2LagicztVAJ/7neJgm26GfuL
# DATA SnQcQrybFw+05XV8RH4RjSdTKKqzlLgVB1XAbOZxbWVJee5TxnHfROa9ESuqmBuokocTVkkf8eBJGdTv66qeWPG5rgrquqp0K7j0
# DATA 67HfD7Sdl+a9mHxBZ0CDvp7lpGwfrSSuSO1JL572O9wuxZwdwvLDxnNMrURdXQq44LF9SRZwPz4ccBBkn4NnHUAc3pKhB4v+47jF
# DATA A6eSmJ8OmYWoQloHBB/GB0qvXJvOwaSno//BmOXsqd57LG4izm5eb9F+Y3Y6kzVOwQTa24xeijo7vgc/MCM1tXGBhAJkUd/OEyOQ
# DATA 6odwsNNwHg71vR3FekzXBtcl5h1xRav0BCKeD7+6ce8rzzoiptczUq5CL+yPVH8mC55WX8Qy+DRQxhmowigMHqOEpcdE3cOaZScc
# DATA 4AX2DEuBFSgUmQ8yFh6twJ6aKTvGBp+b9U/Uz2iwIUP8+bLtP/vso88+HG699KPn/T/K+rD/CB1GNJwCqjo6PPd3YO2yVqn8SK0b
# DATA z/3rF6vV0o+K6X8/Kvp+vVj7kVe8jAyYos3R63/0Yv73k5/85P5UCBFt6kCiDo8zqBRbCe9FzjP2I60g3p2336Jeg5c5qX3H/Q4v
# DATA 4dMDBQrrJZFKIdt2jw/b6O8fk32oP8fJSzx6odPvRy1PXb5HX/UtY/NgMm0p/4y+giNZGA709ymZLi+99MH92/fu3b2PDdRbW1sv
# DATA 8Rmbl9QGy67sq2Zn0zZNJjvhjW6ytcO7GXEyZAsMvuvUK14H1fd6ux/RDGbr5kuy1bqbFJAPcPM9OBy2t/FQztui+Xpjy9qBusVO
# DATA oTxCz6e5tbWzo/1LhfBJNNn2d26+NL/vMxs1Pkf2SD1Eb6De8WDIb04DCtvIrZz3SxWZ5e/+KPeS53mfTuQUyQ2ftzvkBsGTV6dd
# DATA 7H30a+VGJfeYrMwH0d4w6N/YevDWG3/71ttvb+WSSSeKb/xyi67T8LCV2xpFI/yjvn/02Y7KHrUxNRyPaej59a/1RtWEA7Qv8GK5
# DATA bHxdnSWyh3g3c1pLP9/BWDCJ1bEKlf86GvzgK1xQh/wSHIzC638sh4cKUfIg6IZvkV20h0MKuL2A/LqDlewd3Dl3zXvZKy67fItP
# DATA 2yxNg76i4noAQ2ZbxXf+jXR/emprPijvs5dQiV96iabQcFM+YrrRdjRMRjQKP5JC58n/zg0UMbKAV9BxCTYAfyiwNZFgCrW9ld/a
# DATA wQ/9cLgtD1JCqn4J1/DkOCxgPwFvI94eb/3ydv5/CvK/KuabjwrXb/wP+Y+ubWVfiP/GAaZyv0DC7qL4t7feGu7jtI/Vk/AzWzv8
# DATA jBqId7mlZxKzoxMht3Bl2aaaP3mEk7oU04r3cw8betU/6+PA4XrhkzbZuolMJFUMYG+OO+gN0B8VePfDtnonqs4j7K/e3tnJ5GlC
# DATA MZ0EwzaqIj+e83B6wGSnurpD1c7zN8odNdVVGNNwrGKnr+/qeP6y+JH8oG/Enm+5iQ8lbr3VoWLZUo+Hw/1oHA8Ham+4fR9N57rR
# DATA Ht376Wc7cuXucF+OBNlJna8EQb5LNeCjT2uVz+hmE4sdXWmsrLFePpc91i87qvGcJZNwGloOuPBXTNal04iGdg6kr1gsRr4/h6O3
# DATA HMktsvPwtATDF8bzF54Ui3OXdrfUnhW5lr5vebLeHybTEYYrml1Y0VSJwn982vMRpUx6Ct4xuE2vyXn+znxilrfWRx9Zzfajn9OT
# DATA OLV6XMx0htvVh56zYsZZXqDhMRx21AFU016ng20UMm4p0GSDujc+54eyxzoEZQ8/jZIvVWsbNN+7VjSWNeGfYm0Jjg1voDher8Xt
# DATA xzhdg3+o8tGD40OePuVkvtzm+oiTDCg4dMoC0yPTv6CCxA4s6nsVLQ+2DOa0TO9Ti0Q3hX4Gl5Se+cMHzZKhmC4mvQD7r6S5mt5v
# DATA lyI7DPmiOLKU6VJ4GMJ2CcaHr7GwYDw+ZGG76MnuFr14GLSnOFBuRnJ03jRV7eib0wykUnukrBjuVc0tO951b8uuaeYR7TOP0Z3E
# DATA SQGEsG0dTg5X3nv0wf333n3777xfy7c79+/efqi/3P0f77yd84oxkB4mTE4d/dztcGjpK6h7OpDIU3MLg0G2Nso1NVCiHRY+poLb
# DATA VlXmGjfN9CUTO+Gc0YqntmtZiQUqsO1fZm7Df1sdriXoLuUpfMqLexcfTa4X0lzfxWEvWJcF/FWhAakXPsktBp3PqyrBoev+6gae
# DATA Nt/4bcaclpfTNDvfGcej3duwuJaFm+glGrJPd4cxvecgj5lvBJBMIqFQyeVRclvco5mC3FkaIGJJVQRPaptXh6JbDb7DTNEDPn7G
# DATA F2VgZ4P9KAdnwWQ6Dh/JFsrdh+OpOnitP4r1uVsu5mTdlK/vZAvSajGqULURBT/VaDt7+2bDlQ5zrgdc2UI36ybZEvMi9olN7F5S
# DATA 7Atl0c/XR6v6sVEmmR5MJkG7Z8f1o8VSW/bfpnnur810dTIva2Bvnt8fdj71c1WxDNiGht05nGyrb8pOvnGCvLUmmRKphexlOYD0
# DATA JebXLrZ89Oe6B4q2ydjFaKwpovFAyoeGsXaYLR5PsmnXevq1u7949/233z625OhJmiUtezItr6ourtch4LCjZgAYibZVNeZJEXpu
# DATA PcMu3B7vsVf/Hv+iik5uw1m+R4H6neYAeWV0U5r03gurYqx6hk34pU/QbbDF1IP8Dx5NVCQyHTaf29hOJzO4r6Dik/PkG08wlDX7
# DATA BBhO7y7/AyFWE9BP1Yh//bVXPZ52JowGVV2t7bAueO9h0A48Rvd42L00hJey7dH4FIzIqJkzRB6wc/8uZmFb78bYx53WyLbxobf4
# DATA ejcaD8LOFsqIKtqjRzAHHpH9tuttPXqEEnv0aEsiLcV3RV2JY5xiH4QX4fbbzP9XqhfLZX/O/wevoPP/XcZ/P/3x9Wkyvt6KhtfJ
# DATA dPBGh5NePCy/9JOf/ISFO4RXi8UXWRjDGgNWfLFcEY9CDb3VG7juazPK49lWv0/dwhqvIJYpahX9DXua9OdekMA3qL9G0AcbW07A
# DATA 0/sTZQXRfO1NJ1HffOM5hPmW9Fd7ISk/jEMyGNv+yHn/5KQ3FhieuUDtLeO85NhPx32KvHSiOgl0jeeB1MfwOoonE/mpZLuMnulA
# DATA qkYIyu/bdl8H65qmP17rkIvIFAwb7VhRGYcfh2opEHkjE9CEy02/9/3R3jjohL+A8IF+8WJczBBF2SQjFzaUbdM0KUk9R9LTLkmI
# DATA vk09yjI+KFL9nAz+luOGJzx8h+W84UkoNohu8YaqrR0dnkwyRuw2VR4AbPjZlZmMvGOCgzETPZfioPVMV34qRMmj5HCA/TLbll3J
# DATA ydya/e+zr73Zn2Zfzf46++boi6Pfzv5An7+e/cU7+nv68OfZd97RP86+Pvqcrv3JO/pi9s3sL3TLD7Pv6Hb88MXs26Mvj/4b/cRP
# DATA f4evNzzMI2DZSwzU8KiiI+ceCwMY9dvyJVE2IM9nH8W25cdLp7vaX9Jd5RMJyfSQfO5MB6NE/xYOsc75KEjaUST2CbacYazdLenJ
# DATA mvhkOjmeHLO6k5rwDh6j+xiZWW4hneaSaUGx382kaIn9MDfFxEtoaoloZQscS/MHmEHu8uxx1dQTIbV7VAO21SQU0RzG2ztSLXZW
# DATA z1ORi0t/7vanUKJZeA22Kc+/Jb0rxvICg8i0aJWUs+3zoXs4Q39MxgXN0LIpMVP+R92ONaPP5Kea1t9/zZ7Wv/bW/bt3Hr53/++y
# DATA UV6YZmfSYb8t+9xSG1w9y5j4Jc8uPCOJRcsrcAVOOFN2FspuOuQ2yD+qBi5ry8pBZdzi8E4pRTa4oMorHN7br9xInWcfZb7lP/q0
# DATA mKv5n1m/77zyYeH/Z+/dm9u6rnzB+zc/xbGT2weQAPChhxUosJuSaJttieKQlJ00xaBA4pBEDAIIDiCJTaPLiTud3IkrmXSlpqa6
# DATA qrtv6s4HkBWrrTi28xWkrzCfZPZ67fcBQNlO35nbubct4px99nPttddej98qX+QHe2crlauX4B5kN22xhf/x/HO1/f9dbfKfAYP4
# DATA VO34LxQL+DJ5/glygud/VizhK/XyK1UQuMHjinqmnnyonj1Onj+DEh+pv59pNTayQlIUdgEOpSSToA4q7RHZhONDdi+ozKyp5Cud
# DATA p7vkindT8BjN64uLwHt4XnUFsNUXW4POomor3YvP89KVpWAa/o/nnwLrU1zuMTA/xRBpeGqkak6QZarxP4N3wBB/iZPxBcyX+vn8
# DATA y+dfKpb4VOu61TUV9cCOtrSSOvrs5eT7DdZBY/Ey/F6ZtT7Qm2ewOs+gYWj/CXTz8bzdNyyezoIXv3nxM2DrevFYR2BpsFH7Qhps
# DATA 7Kit3xshRg/+G1zO1TjpBROBY/HRa+jtHqfK3Wv1Pbs6ma1TusDbutrYUr70Qv7RutoL1o+/JXd/tLh3sVxSm3HR7L1a8++r6umF
# DATA 8uIbKSt7A/U4VQhufD0AdTpCZbKa3bO0Bhf7Wi2dkAeweYWf7K7sCSWpWSvPGLo/3rqztYl4MPKjamgnwe9gM7/47fMvKoYDyG7H
# DATA nf9YFX4MFaliijM8fwI8gPmDqlzm+k8vPlYU9hWQJ1Cu+v0ba1YJyDC2k2msy3uwk2Xc9hTCl50eE+r0SZixF3BC/qS2llryBAf1
# DATA GQs7qscvPlZSjt1jVkSxoQGQDW1uR29jbI6GdT5Od66tr5d1+nB5KMB1SQU4gxNjafiF9ixVBDYjEiavAHylGSzQsiJLeI7mD1UM
# DATA /200Qg59KC+5cB4eSr+nYbz4KLJqX774SM0JkjEcS58ibX1M+zZ+fuHpdN15p8hYTdhTmkioOiDZFx8nVAIeakrg5cZux1Zb3VJL
# DATA o/77Wc9d32IDtmIX92vTfyuuYFfpi/TU84+As6uRrW6uV81mnIMgeESldHVzs7l5d2uncWlpeel+b2vtzsbqe6vvrjU3VzfWbjfv
# DATA bd1ucBoblI4fth5k9UuA+9BLnV2Ymi9VZ5o7d99Z20BjBQ6CRPH1jZ21rY3V282/eW+nub12c2ttB4vw/beGRZvH2aPSJZDe3frv
# DATA 93a27m3vNDe37v7gh43l+707q1t/e2N1o3l77a3Vmz9s3l7feKe5trF64/barQZizaKhhlYLbq6+FBZbIdTVswYZ7jcMbSsCGh7e
# DATA oDJkqUL9unrlyqUrwRL9G/FOw2yINF/8iihMUbCqC17S9+6imAak9+QQjOq8eUbBEuGuJiYQFlemSIOKouBAVF0GIeFzRThfqn4/
# DATA BZ7zxYvfsDDIbx6LriUi+HF/LRNfyVjo666ocTYJjeW68DQXAVyN3T1HPgfTd9zsjSbsAw1PN82Qbbq3q77aQzA7/K6Q5Ytba5ON
# DATA bSXLtjbIsmGu7jgPsuGwo+70aWp0IYQiiaoPsdz2wbO4c0CBBYhfoX1mhYcm+xk4EJMWBIUUUAc3/FkDp9dw5jaonTtgRdMCKVUA
# DATA J7L6JnVvPNxv1K7pH6+EZYOT6zNksupcUpSjeM5TIvnfPv8dclZ4BLwWWPGnoIpQW0EJIFBpVUq/+LXDqp3jGBeB+oBPef7ycB54
# DATA xNvZCEzoeWQycqIlpkTeTFJheC4nKDR+iXLNH6FzID14h8qXPCD4R/1mPwAQM2EfqQ2v5At1wMFHqjo4rWDCnpolic87u3UU922e
# DATA meej4HPVl1/TucGdCIZFJ7C/ACyKSyfKQDnLwUWtBxqvDqDu6oKKjwWXeE3UDa1RLMX5xm56a3Vn9cbq9hqcRuleuSbf2kaZ0jvZ
# DATA KersKkmgffTa09ZVXnF5FT1o1VoBmf4JVw5YNzLDpySAgIwGD40sTQuqJEvFOj9LnI4b2Yr7IX/q67K+eOAt0mKQwEtg/ZGnONsU
# DATA nmi/K1wRbxfgY66CnkAgTmbvhi1yJ1HlOjlOCGjnPK8GsjkZo7QYm8HSlhW3taGGZ21fGAsplJQ0jZZ9GFXJKj//ni3XOoTkGRhY
# DATA cXoLd0zhkNB42O0g/I+affxTloYCsOAJdlh6Tz1bpY/kYCp7akz8jNSYk1hjYNwEVVzJnzb06UrLtS5dseH+J/1xDy22Q1C/yeHC
# DATA 6h+mCZCqrOGo5ziYdH1zlSqAi+hb3f5+q7u++eCqPPR6rQanaVh9LjPG0r1+LF0KJ54pHKDKOaCXlYyQlKBcxukQ8rIVy3iBgSK1
# DATA cU8J3aULUhHZBsDHC4403j+oMMbiNu/imlCRUKwMMrs4flghk/wpKcbUPeFzVJo/ix4P+IJOgesiRz1BFvsxXu9sDpGQfuKppVWz
# DATA DgRn28uMxA4JnoGXP6Ghg2oqfgvya9HpUMDdrHNAumVzWu72SzNat7OqHBXQ0/YU7oLWwVVLnv+OTt4n2PVf4os/8lg/41X9I64E
# DATA 3l9uwg1Dj2tjbee9u1vvePJSbIolXUefx8u/c3SuLHHxMvjOkuB4QCJ00z7xPMGeheIcj6ugJSOzhAYTiMgqB1+QgF74EfrH1hcC
# DATA r6GzicO9tVYwImqHXq1YmlhfyAd47f8pwXs4XU+fakOu7frpqGz0LQolqQ/xzvsseWfth413V2/fWxM9iXrgeergTUDnv7YvBaSv
# DATA hBh6zK8LF4Oos5GqYcowoj3/Eo1sn6Kw9RVpJX6KF3XrcsW6WdLmwMXrj+kclxJ0dZXRELtz3Mbc+4rp6dQJ9q6p6s//na99qC2l
# DATA qbXWC596A1Bf/1xfvMWjXvXMNpxKTIUxqC5M9Yt2vLf58u26tls3WRByYRo/Qxb3C9ERBXyM+DGM6SsauhrUbyK3WrNtwVLWzI9b
# DATA K1eu2qNpd44gmrEhHgI1LlI2XraWXRgtYelwP24HhE12cDzuvQ+bDMXobutkv92qi0UPczFYcQflSrKf+vp06lGNYpRLWJ8zLn5/
# DATA nD2iv7SthiJRmzAQdaQaz12+vPf7o9Crl61mXUpWQixvQHIr6mzBqRlGAvZgPKMHYLKGD9RPOMEGxpK4/faqmrnte3e2DdcFLePA
# DATA sXLPESFCGjSquWw6g92cSwGCRGOM5Gg9QUJ/QnuUCEptBH1YkykWhrtojwOiIciH2CGf8sU0SdKL1MOL6PDv9VLW5AGiETRpacy8
# DATA V+gU6YGxO6XouNnLhA7iIkjp+8Ww/xBFwaDvthdDmdQm6AhtS92FphK1Dq3qIfq+lpOk5K1OGdz3+g+LDSViBkAxHrodlWgKV06Y
# DATA 1FeWDIPHBauNX/wcTpCPFNf6wmK3mJSxgTO4GLNDoBU4RorygslaPQ2YBRC42DmiY/lnv5csoVEvQdE/jQqL1CvW6HAaUcCWsQlX
# DATA YNArdd4bb/EaxWHXwO2CvYRHmf9QXL1z/YRlG6egllY0yaLaiajWljqoH9jFVBRg6PIhRtauUwk6H4BKy9/R93rv9yBaX8O+8hep
# DATA F1zE4/5+wycxi7xQ1S6L4a4APJIVoLPcV5rgpMlJR/srnMdyfHpwZByjD5/g3dAaSvHwNxDuBF5xB2geUne55XxIJTl8FXJHDEsd
# DATA Ypgd5N6A1oDxNFjRriwvIsyle+VyvEpruB6FlM19LfolHgWiKIAe7NohIzxtQGeHHdWzIbrwctV7FP0JrSLbF3cNEzzHXeIxcLec
# DATA ldDfFFHllG8tltjrHJJIYE3EPF/6swE6jl3OIpKSIQ7T0uAlhBrZpaQjNHoqj2PI2umew13lA6IjIA5UBW31KX+gL0O4w8Y4XiSB
# DATA 6pA/8Gh3vg31f/OByiz5HxTn+oMSitVV+cU/Gi5GqkrFzPGurKQzdR0F0TTg48gDNYck0dm9Yg2cU9A1gTC3x4PSDSKzWXprP+93
# DATA IZ+aNUH8pa53ER4szHVIKIm8332AmYLy5jDrtkadB1lz1LfjpEAQcMqiSTUMtXJE+qqWVqbI879igdg4AJIQ/wQsrDizqMgA6z1e
# DATA xp//Ac4durU8xvl+YpkRZbCyaZBZhcfh7A7j0fUbVbe6reMd/6fATos77Irp7lwtMAX0svFo2AIgCaIE0UgouVZjyQCKEMy/sc0A
# DATA muBRD0J8KY9St3WaDfMEMrkmrcMR4Jj3e5hAFv1ErzNYCwWhE9qKbkhbamIONoa/yYkp39VOWydd+yg1L+g5hYVUC78rfK9e74VE
# DATA bJB1FhOtV/c3QuESR3xPo/pVbs3dl9ZCmGugRVmoS8QVmlF74CHIq4+hIKqjXvi24k/X3PhtHJe5j8KGO0sFPSmtJ2cTowkRm8Pd
# DATA 7WkmB7cX6J3qzyy/LpRsH6NE+wx3J0i12s1ddH4obcA2+Tk7inwBaoYn2sjDBoonBfyWLG10ff8UdW6ktkRe/NRRRLieMGaxYnZR
# DATA Bi2SnRfcI1kqi19RrMOTyk07ORecmwOfb7EjHDuZfCdhVFvCZWKgoU6vis6uenoZ20vd5x8QiFK/29aoTUhOC/6ZOssJO3pJAaEe
# DATA 1Q7/AArlFz+TDlSDuyVF34s8Ia2yC7XZvzyjWEgmLyJu7qZ6zsGeZjgnj4pac0qBrAmyoWnM9YowqANaHkH/iEuX5p8N59gpngtR
# DATA NVi8VGQirwemae1FX8h+SHKCx7bYZJSEjnItlLTqc0QnChlrcRv9TRDGwhHzipWlMxw1CqdMeykLErXeW27L/iCkfFSasV/Gr71S
# DATA Am8q1BK98efrPJfgcJBz3HzdtdQ9R+0G5l9SZwPieGclCdKwAjm7BmuATUhafSxrB6p/uA7Z1qYzPMEOWZirJE0AUxD1zgQnBYoV
# DATA 6KR+p0b8CZo+yGj0WNxUk1B8ehJqoyQhqEu8enPPcQnAqE+y0gq5QAB/4U3A3h3m2yjpuK/jxGPK4EzJ1g67HFWmbJrhW9dg6TAF
# DATA S0qsD36SEdA2wWiPT2ydkD2TyFqtrrnGeCk4i3XO32P2+QGAw5aauWMlapp67E4OOyct9KEuFrCs7nFx74YolbAlcTr9vsSsA7Zh
# DATA q5eMWTkjxy0yXddLQBi63WfK3eMvtxsfRZuRntmDK46YArJzI5f4H3P3esWRkeO65/tW9JC1QzQAwCX0v3MbIt20aV+04Bt3b601
# DATA t3dWd9Z0PMz62jbuWGaiCA8EJyx3xowLlexFzHXG8lDeJjcVcGq0xAHnE3Mo0oNjn9Y2Kt98acWJcbjMSScHsGo3KoxUfXncwMjf
# DATA 6wuJxzc4Vgkm0rPHcK8EFEZH49l2kHDqSK0fHXwDZ+CvkqX+a6+9Zm7EepbtAPGtjFAkGDk4e9Dpj/Nk/c7qW2uVZJxTYgTwB3yY
# DATA WemieyPW/anNMgA0TKtGQrpLfjLuj1rJjxVJwMGOC/kQ48KHmZracYbR5x1ELYLsXW2+xWJYxnhgws05GJFYQMXbeehOuOfuUbmf
# DATA uSVt7aA7mXiTnv8GKAcpfqUWk3tWtEBYrhLc2bQPbbfVaxKwJOiVmyzNl2hoFZpliPk/OO5gGnjLlZMxR5ghtBtA0qI44B+WirJJ
# DATA VeILW61AtweTa0I8qHTIq9qGQAUWq3nYAZw2XNOHrWHb6BPA9lusEia1Ogab8HCmlQsEj39CFwxb4fMnso5SpNhjMfImKKU9VZfP
# DATA j8gzxtMSoZ+IUY//usCn0LP48mQLEpYDIRdDilN8mJI9AxPOPwBYrA/ufzcCDWd7zzvOJaRahH49e/4ZWbFBCaUkajQkfRSZCr6w
# DATA wMUbI0hiQ3tAgcmY710vFT8sHD2/d8cf81K/WHqjfr9Gf5bPlisU7EdfzzNocf8kZ6SfovkiPlQyM4XjE9pqmoG65BaMNfiC/Q3d
# DATA IyKcFP+7l5wdv5ryvAZFMvPYM+U6/Uakb8YuQac1MuCzx0yieK6Sdkvg0aDu8YMSgoI5buk1dSRBHNTu0l5yIblc3q1f9sQ0qDiY
# DATA FdgT9Gbq+H7PXhFwzX6MJMzLzfFGemSgN/qUtEk8cPD9mGaBvE56e+AU/645hiKpn9NmcryQP2XF/jMKSCeNr1CWwYLO3e1jv+HC
# DATA 6ghseh+4ZBj5RrLs+EX5+ar9RSVowViTfDq1Clk+K5h7wO4hczKnTsYmUu9c187eqd8KO0tO2QEmKNi1uQP8nvGH0K6aTje89tHw
# DATA p6bGKaRvrv6n/sb1Z85MyjkGafc1WAq/Kh8dkxbUWoz52+JvtdsRTIM80zNgFQqHZPkhB1Qaa+kcfimOdwPFav8j6hB/SrGZHn8K
# DATA DDhPdTyhz7kotwL0FxN0ONsPnmyTeAVQxe7mcV6S7ZslMXJaUzIRFdQCGnp3G01qpyez5e8W+52uVD3XvSyY5WA+/1XND02B9n79
# DATA EwYWfhJEcnyFLOkj/O/Pnj9hGee8czkYoFfFLiU7Yd/0RsP0HB33Aps3U4QTyQ70RxUa8uPfmrAtiiukNv4mmJv/rob0CQZXPn7x
# DATA 6xf/jZm3zI+ENES1bn+muBZVAUsN4Dr9M6TYj1RNT0Mx6nMd88IAL42CqDF2sd/c5IBBC1yWBYVLK6J/pqpQ7Xx56XtXZVYOjolu
# DATA sB3yryO7231EVruPXisIp7oXzso/OSMuIIqoNvsZnnzojIgPrDEU6e3ZxWKKcl7rvgsvUewd6cTVRV039qKwBKSMRM39is352CVt
# DATA hs7yX6woXV/Elnn5kunsw0CPGbAuUWVq3ZZkBuCx03Nn+NixSnA7yrM1cPLdRDTJcllb/1E+A1EMnKZrAHr0fnaal3YvcD3cxJ79
# DATA SS17NAJV8Hz2ZfHls9XvnvVCX6Sh9nrgbja3cX2OgyNUHccD7XRPRe99RqYRdEMl6x94hJEyvx7xdQs6rz2UheVDqnecCMf+nNYU
# DATA H0jN3EiqJgq78S/ZQKH0Vzl2tmhXI9e/1uwLKk2fCkopYVC7syr+yiSnY3FSWk7xwKcRG7f7ucCfz2P5wQXVYLuFNl7Eaoku8hQX
# DATA GN1ZXCXb6ms7uBjPGBqss5JGm2N7asUp39191Gj5290JZgcoGQqCWowPeNF8OR5n39a+UPyDXTEBe67WzrIB/MGKKstT0AhUcLKn
# DATA FeHyHC0O2uFXGsHDIlecAv+A34iT/JdoVoPDHZEpEoiVUnP2B3DGwXBREyL+4iM52m2MBEsYjDjBxKU22fwNmZVds8H3cOwGtCK+
# DATA tbh4EBTjBqDYosoX2ixRdNo74nYRrWSHhxkqCFXnS6I5nMWu5hmRrnjamIr1PfDjjzIelPO0D2vh6pu7xeOi4SJoNayt7h4NkJ47
# DATA cdZhCBIVCmKQnHphrKVI9L7L0Lm4hwjgTCcVod51+sZqU+O1AKNmRqG0qU3AVUhFmMaDTRsNvKIUMu9zXDtQRfIFRaQAsZloJ45U
# DATA 45CbGKiHBSMc7jthWC59RX2phpmi/w4IoEC83opy9gyJKOXF+GtcjN2lvdpQoxXhk+qyxi+qSxl7Oay2EA1J/RodDQlIXP7+CcOh
# DATA tzv4WK0pJAMATHAlozxCR7lWu41PlECWHXbeT6PWyef/VrhzYbP/UlE/CKa/wFgttT6fUxSoaKgS2kHPYKPgFsEANCiHYFofogfl
# DATA r+0700fWwvA67PIEQiQX/uUXqA36g1K6P+50IZEGGhEsm8/OcSdnFgI4IWBC6CNcHbg4YXIA7eIBr4eDfpdM3HBiiqxg1TeEfKhZ
# DATA D+iDgInZBgV5BXqqRwDB2YXgHVVhDxMf6PgxgCtWB2ItHKEN8Q/jPLtwIRbw6EtfJgEFnKHWdanOlzcNSpiCfj/97nclNlmTqH3K
# DATA xLiufX5obQd0yjJL2V0MK8ab/F6sz5wKRJUlmCu7HnYypc/cuFlUjNNJYanDSSyQ3sW+W3AD6i05Oex0GCovnKvw6I0yhuKJmrKW
# DATA 4RnhFP6f7ITQa1c459rkOETuKCXXN7Z3VjdurjV3fri5BssK3EztEGRkhNPbJ7D9g+OsPe5mw3Tiaw3pf6X9fr87g/SYC5Mk7Myn
# DATA 8OdGIymqQvOgckEHrJlX88G6UWhJ/bI2Ie1CaksIv+wctjxPoEf4Bo9dLeSY2NrHZMD7DHHqniqx9BmHBzveU9MPX4K1xW1xMUmv
# DATA h7aRUOvqBI+SmUw70z4pNqNq/3VtDXZdtEJ+ULcy36BMGeEuHg139ZHtELHRn1nyJXzhaMvgwdyqstmC51cxwfNpHJMGzcyfc4z+
# DATA DOF6Cuuexf5nMHK6ih10W3QXc1qcyhrUjOrvbIaOeWL5RWwPvYJAOHGxZfocPXFuLAJmaEVRhLZ5Y9r9A6xNBLjiuhD4F3wrRuPg
# DATA lyL1gOWPgPnOSfEe1Z+501hPkN/EDv+JG0jhXo7xlmtjmer4KWB0DXHgCM17DdKGVxJbN9rYxcs8qf7Ke/qlUSE27AJW5qmI3G35
# DATA ICO8HaCrB4ZH+8sdKHZPlWLZoLDgJjF6Qjox+s6CuvwtX/DFppbuvXun6f1M8ztG/V6bVPXflyfVy/rHJfXi2vda+3vOE/l7mfzk
# DATA dGNxNkOoHlNhPsPAiMfJ+c6Hp8j+H5NjxC8AD0VcAQye+sdBhMRuwQKAIGyGZYdOnGlPiXqyDNE7Wv1f9/1GUZYgz03WODENuple
# DATA dEAnOEHpv9XHpFlDxZRRZVGGKHDwqoueRaJ91RMaFXSLdy2U4j8r7lm9bTyvolthIr5YM7X4qAkXKF0NiYI/g6COQkuIBcSLF82Y
# DATA L77ttknoj9cmO/TH1cnfsoP+fYltxm7BJdcDANfJeEJ9diScVcKy/IBpP+orHuxV8BS+pfjXoHkT0xrAKpuOe5BI7pHugB19BSeK
# DATA 1megI1jMkFNX54G6O3+Cx4McH7ivWP9qMKmrVTvAJ4QSKlxh033wlbFzK+URhbQ78UEAYW5wPh5wmpGYwyA4EhqShF+etxMCk2AE
# DATA p36X+5Brc3riFUbK/Bmcd8DKVnjkxrXYockROjkrHKhklaSh7BV9EvhKu8YGPSMHAUAlK7G9VlxlduHLCADrPBP0FQXQoFMXC0uf
# DATA 25rtKWZr20l99wJ1zHBdJTNcMINlrot2pTD80vJbD6KPdPbVYkOCiZ8IMYBgR3AVMwJwXGwg8WfwLCPk6cAukmzmJ9s/TKqcwX/g
# DATA vAFP6ByesgDsL/YEihsm4QQhIkS9Dug+6YyKtiSbP5ouyND0XfyyW2KeWAusw4uyEINzJHAtIKD63HGzcdIhS3UQrRkGeVCnLEs/
# DATA PjCWfvo5P2uaZd5/orkXQc0VUoeDqmPc0nGiXIf02Tb0Qv9xOwNP6DpuShji8liUjjaXmFciNkf+QbGPqdTG9Ea3cIo87Yvu9aTV
# DATA UxJ4OwG1h5U3jp32qRFwXYRk5vCvuJHbruExyX1Oj8FzIZML1fAvJUBA8vbzOLFZgjY9Og+G+V9w57LGXQDLWOh2bbHmgBLqLLC1
# DATA WkyUXM+foJctYaiRp/EUljl91mhX6fsJVBA641mCSUx6D3Jw2y53vpuZdyQ7zrZ7juArtZzDOx2AktHBnnEh4BLna/Bm00msEzEb
# DATA My2boyOCz/a+JQNHBDBf8R3cS5MY5xMHAMGEz6D6rAmBXE1iTxLIVeJgF2BW5wq9d5HG6B8HZqxn4MOhDb0hpD0XP4U3gx+1RzI3
# DATA 9YYC8LkaE2NaBJEUbnkqM0uClVJG7t4z4Ekiq88ftBlE0+kQOpyVSMymD0DlIwSZoc9CCbJAB77NDgdBpnOwzgCRSN2oXMnE5aPB
# DATA oCPDnbo9ZVlt1+O9IuEqJMT5Qkf/Vw0bLaYZChtl5XYL6aGbgaW4/7AHKRt7rUF+3B+Fxm8b8zl90O+OT+S4Me5Uo9MBqJjS/U6v
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
# DATA 1jSKWsAe8ARb8C2gEqSeA8e50BeocwGWR9TPQuMFdbslz70n8HKYCasP7jlBDOuLX0MkmySTNxiz9MZCYTIGHya2IjQFz7Gkfi5M
# DATA UtuUjsldvk0/TURhBJgGAvWWSDlKakfmgnGuzqv90yRrDbsdlLGYF+d0RmettlVdH9EeB+oO3xoxgmNHVd45ydRXJyAd58etdv+h
# DATA izdbC2EWXL/Rxf9Ir9HFGT6jus//U7qMzkFzegDsNGoWwfMZXYx5jLqwpDY0CbuQuruhJgHCbl31COyuC28Qc9OqB9AN5lphbyT2
# DATA Se731B2s62d4iJGGoy2QD93+mPqKe0TLH9afEANGFG84qD1IJXJasXIdSFyKZsoQj8IBuf+u/QStoOqvnFxtv6Fn56MKPb6XRnph
# DATA hh4xdLsCQyQxlOW7OAXgQQ5E1yk2eApnSIgkZBe1H5vCpoJYrX9J4Ag+3uEQFAZYDCDmagZoKK4bUhTViUjnKwsTpxg+ZQoQhBsB
# DATA +NQdgC/71aPwEI54F/WEQA49tYSHJ2Jd2M0NLmwqlujNbyxaxmuuZHZakVLagq2gmmKysumrn/g5htGkPaMu4M4TjKaXyh8yJXeI
# DATA 51EuTnxTWNp1BP+ivHHq/PtMPf2jxM99RTKYB6SJjwxSrpP0w/cY7rWzRxUtCWZoGmxphOqZsDmxbDivJ9cuQA4c/M8Ux3ADG4Uu
# DATA 389e/FJywH5CY1UP3PS16IIDxpsISo7kzqi7vawkko6inoQpMzhDHUwClDwhi8pS/+rS0qRw4B5qh+qTqEQRxdubEhvUu5KQN0Uj
# DATA cMAvR/yIozk1KpKeqjjVhB3xgkuu9RuqJttpQsh0tmvKIbuecIWTaa4UtiTalHPJANLRuWRlAkX8dCXuNpxUGTN5njhwxcwa6EVp
# DATA WQLqhilYRop6zJEP7KU6fo7/IlJwosUKvCmNLL+mWbK6nYE0nyfAaxJI73Uqt1JCI28NQdmIOVMJzR0rteqC2a8la5hADIQF9VmO
# DATA oO/oCdZtM6T1AAA7sBGWKNCje1SLw6yH8tYs73Z7L8TlUEbQ/kZuXP5ty5dVBfG/HJQIof7n98/XstQ35p8U9/q3Qow5/dca/qOo
# DATA zUmb7iS+sndYvFp331mMAJRicg/vjTwQIUtssWEKUKNBMAbusEil1e7kePstWdj2lm5TMxTGtBdpF4jZRrPX9oK4ecGK6YrYEFie
# DATA nG1C0Cp/zw30XJYHzZOoUVaucJngiP/nMEM4Qpx6XugcKsbzjx75DqS2FwalTsWfmcT2RfLyr7XWBbvahL1U4h98AvSH7xNotass
# DATA nN98UuMqQMNnEJyiGkEu6agDdQe4B+liWuDLb2W9T3DmCFbpWWGSr0KJqVo1x1wBAio82NNmbn7Acumc80KHQZPOTB/aquI3DFur
# DATA JJOxmAysKfQzjSP3dVSW9NgCoqbAlbKv6JuerNyZYoTmdcBmnyaWCnD2FEdUKYSrEYfknS+XM4+3AC5DtqJ+baPjxnVKoggKB2tX
# DATA DSknTF3XA/nchjaGS+eHuJ9/ZQXOcAIITxuKukmnx9RC8521H0a2wf+IN/yUVM2Q25aaVNdIux5HM3CGUEEnLYYFsMUgi2sHciBT
# DATA JvknEw+tC1vxYAI8N2XGvHVcAeqJdrozl0FyS6a/d9P1thLC3Iqd+3ddbRmqYw+l/tGwZSEF7O5NpmS/rrtnPNzsO5v9IYXdDNQf
# DATA BoAJ3d83724hRPSK+l/q+rliBXwSqi70crXPTrSzVPxIZEdWx0Wq4oIbEMJImmpPxChAiS1ufq3zk0HZz3UKWv4mjI5S7G/iIbGH
# DATA 8VJzQRoWgqczM0q9SweJw9qHMQZ1FfOG4WsxeB/Cz7PSwXwzWZ49cXWX+ZXjIF/oj+H6YUyKgdmmwrGVYuyU4L0CcoPHgbhcmuIA
# DATA Wn5Z4C2PF0dADMPexb6YhmoYuCu9LFJlFAftW8Kp/I/y/31Z2FGdqcUVcMOc26SP/Rw8DLSZ8LfPf1dJGGMtqvZ04J2+BehA9l3G
# DATA je46bRXh75krV197VhbsrxLWPiden+UCrl3Xq05589j60rqrqu81vyvsE0IAuuxxOtafW3ahgFREjCdMPtOV+ktsxpmApufY/vHD
# DATA n2C+p1K68VuZIqs6iohhf6QEIfJbVJusLlXsqh8UsKz+IJOrJZnhBYNf8AeT4rp3LWEEeSRcxkFY4U+LBZZyTH8T4llHNksUHHNm
# DATA 5PIu2r5rVnhMIwXWB04yDdAjmDEVlNyLNmgjNkVqB3WWXgi8qpEN/hB39IiYbLzTe+cYoNjvYOFkQOSWwetcMV4auj9yOsuKsySk
# DATA Ko4prtB8y1+ec+7PLlxQjyrJhQu6hkmYUr3ibEcHQUt9XVJ9HXTRz/9YHSEkcsBfTaA3V1TNjZQqZcE23IedVZInYv3M84eUcJzQ
# DATA 9/IaYZcdZ49Kl1bKCzopAspdMbw+7wtF4pt3t3fe2lrbbm6ubm+/d3frFmr+qSEvesIqfG97bQuDKKzTUr+8dcN95dfigQseWuds
# DATA fXFRftTPpBuTvzbcu71fv3L50spice1vbt3d2Gmubdxq3rp7Z3UdwvfT49FokKu6gdTMiqSbqxtrt00x/cavcvvejebmvRu312+a
# DATA wo6ENR5285KzqmblYWvtXqvDLevt99ZvqZ6t3ri9pnq39ubqvduwNEr8GGfhQO6s7Wyt3zRz3WqfdNDJRF7AikVXduVyOajtvbUb
# DATA b9+9+w4TRPPttdVbWG2ULlhTrzYqRC4yMWsR2t2iRHCh9DxojUbZsIcBeD+CiR9mNYSnzmDnlzFqrlG78N3UFegkbyR/XsFegDWy
# DATA dsdjo9w9+GS8b8pzYr9mPQkYjFR22G0d5Q2sckpiW6z/YgMBVlUNIbu6iK9s5gCfMDNABAjgBTTBGPG5n4lnHv2Q2zK/cgMgMTGS
# DATA wL/6uZLg96vp/eH9HuC+vnoufz8ELNUKj+vg3sNpolgpak5Yzi5lQ7IDUDv8QTZGFukcm86gdQoWbTU4MEPU4G+wauXZ1cu1/auX
# DATA 2com0yJ4UBRp5HhQR7LCcd140r5fduFz+N3u+ywwsIdW62Y2HG1mJ7BzfvxwtDneV3z7HYaqVz2xXsNP9QZ++Ui65A77Lqw7ecE6
# DATA RoeSeVFJdk4H9GewKvbEfgoqP3aARPBiyb34GDMLkErQIMs9BigZgIz9KXoa/+z5M1RWk94WIZyexROeMmUevqoFm8YZ0dvkfs90
# DATA qJGeMaKroulXmYYftjojgjJBBlqS2LXOSdYfjxorSybW2AohwCB4xQ7uICwJxRaq1Wu3ukqSTKOII+HJx4olqOsWPhHwB3fnWMWg
# DATA SVJCsbOPWtfOIRzR2ZRMXhhzr0rmi2BtOzhWLdUGav219svUEiBNANEtJd93yng2/O83kuVLy0uvrUQ36CfobQDuBY/hUuhmwImu
# DATA 9OPk7Z2dze2qwdfRkXCU27vh9MZYh1nJlbUOmWVKdt4q/O/G2lvrG8nNta2d9TfXb67urOHT2oU38F91lgbvUivptqpu22Fe0Eww
# DATA 4N+HwwkGw3dZS40uit5HA7kfeOnD87xb21y704RhN0d9daxu4d8l6IQ6esvlmmQRNxOFBwd8Sdm/mwx/0eSXpYMWmtfghmBNZ9mp
# DATA oca4PHiYJB9Qfe+uba2/+cPmD64sfU8dz2rKVm83b76tJAbnS3WOd07GJ1aOXvh25/Y2+9nDnw+WmyvsQt5qK5oDIoaNVzvpqykG
# DATA p7gSnKG8F8kWdQw2lqDQ93UVFshKALnWGR0nOajdRjIpqrc9sL2rG0IpXV55rbak/t9yqk8ywwjUeEorEK/+qFRbrujmqn5XIINu
# DATA K1e89GEkXzh0QCbo4bA1aFJvSqo06euyYVP4REMLV1CfYlzjYZGgr0jSpxgqDsxqkGVDJJZ9dUsfqrXsD0/4INJUAwxMyK9eeK0y
# DATA 6PcEvvghOM45MFhgeIQwkV9I3hIb0VIteJU2POLa/zQtF9xaqOt5Buy0WzpM31rbUSwM9tHicm0ZBIK31dTUkzOZoQk8u6mXUt2s
# DATA u+BHAJKD+j9I7IbHcblcNHsrS0vAxjqoFKLmFft8ULqyvCIKvPLu8h7Q2eWlpeIZsti9fXLe3eZj0z5C18GTyD9D5QpkiBjIK+9m
# DATA 2aBU49sPLYPLVuwMx7wGHyL49J8SCxbzS8qW+eLj66Jto5iejyUBM65pJcqWMaP6v1O2GTCiovBXJR2kmPnxFyfIK5k7SN4BpwN1
# DATA bNm2/JkXQZRh1Ns0xbNX6tDx2Hh5P0wpMwHgBCVLuHuX1KUKj035ojwB1nP9fs8quluv7xWWc8TdwzRNaWcmZ2cLVhXjXudRffFB
# DATA a7io9t2i1m4vDse9RZyIGmxuqDJBXWwT7tr9g373+sIZDW4il3S163EqDEFfJ/NJ3m3aR3yktVHXO9WjXzZBsC/4ejDsPFCv3W+l
# DATA r3mCbLq2wv9eoiIgKq0k/d71BWsIeLvKk/7h4XU2jqhjcnGcDxcVUxpmNCmLx6OTLr1vjUd9dKczn2SwHZqIQHl56XKyqP5Tsz5o
# DATA t9XlrdVWS/GD6k06masgiVbv0oVU0WTe6xwqqbr7sHWaB19tAZLKMBtWN/tq+k9Bsu4cjNjFr/rwOOtVD4b9POcnTjXdPilCkh/9
# DATA fbL4CCYA3GgWhSjw6Ot2IIpPHRHN/X77lKSjpev6/dFwcNAkcYUOleTS0lLuvQe2N+09cAf8S131p5EgdhFJkCqYTNxhqFHcv18r
# DATA vfHKw6zbrSLgw2JZjUadbL1TcIC+HnwCg4VTldwVku+Ohx38z2LSUAuF5dX/V/tFsQNSO6xvvnu1ubG2897drXdgK+suNjuDB1eb
# DATA GWg38tQufPPuxpvrb4FqB9tO24o60eyb7g87bcLFyHqt/W4GVVxWLzCqzXkK+Q/hgKvYVTT7A8SfP7ONb71sBErpGtVdO1JbRa04
# DATA +mFKRWmvNUonXJUOvT1zLVpQtsqjUZ8swwcu5jyOlzmjWH7dBOXU/3ZFLOY2s5zDtstDsUytNuSZvHUzX/vpyLlQgORAJ8765oOr
# DATA dUpvQI5Gcpt7RnnKMHkcwygzAqj2dyDTj2eEVT2IkAmYgLkjltc6+NOSD5K83A2/3fNCxvsDsdfK93R7sykikv6pFCsNhMckSPc9
# DATA /oGmIKe8TZ46xtjAytj/m/LtVfMt0HKk6CPQBbW6NAL3HWZgw3exJr3xzTbY2uRNg19OYxXzfAc27pnbrELbjOqGv75G7XoKFSPO
# DATA fzLOIBqA7J9jWTr8Mzoz4q+HSeucWRKUeC5wMUmboCULiZDw4mcXizob8R57hnC8NONV3j/PxPE/8KbSFlRb2i6IKXmqneTPkwRV
# DATA JxgpAqiFXfNteAHMxlJwWmVSQMryPQjQKIQstshsTZNv15FgppankFCR7jMgSVME78di2rYEaYglLnD8Yk+Vp5JS86sXP+cQcAwS
# DATA n2XEbo1GLbDp+mhbmq+XC/LXyYdRI51VK1kkUbC2LJFSwGGP+isLGcnUpKqaFLeS8omUUluTKelmTc8Ls83OPpHQSy+W6su40bpT
# DATA FyWR/DQ/GIVQZ/w4OEIixlMqWWgpNQ1gLkGMEwlTCQqqLJcODNmgS/Zc6hV93Ef2fR9dTe/Xahfvq1t/bk6ZSoKWCrTwj4aCQglc
# DATA cimN3XND4wh3R6wj5Wnbi3YQrwRjkOvRh/4dmKnBT/2lvUEkJtfGHA+2ku6vCAMWWYcGHWs2YQuAw3HAuePX/2DLhkLI2QSDfqUf
# DATA 9j0Wl53fxFwHOupGMgJXI+cQlOdqEZfCr+SYLfr66GFzegXhnpTyEJE+QrLXlX8/WYrk7vL7YD4MeqcqiM/sOfb6H01/Cr1g5TiN
# DATA yUY0PbtmYsFaDiq/5Yquecpn9oxaX/pDDWsQgiRXEL1OU8jSMNLonMm54FwC5BNzBwjaj8nUGEQnw6onS0qWsgeqnkwWHLeEiFDP
# DATA rgzSzqxsr4GdUu9YcOeJCFMLEbqNNxalKJKkIN2aIqvHGGCIBqqnqEP7kmiIMhdKpuWnbMIKWVYs9bI+p2E6pWMLRWdObPXCQVe8
# DATA 22Bwiy5bDuTTL1rk7wRzpo4QZ7ri35UKhBCW9pDpWu6nofhYI4u6c1roUU9bY15bp+OmA0JndDGuewnyyBfME5kcl5fwyg7Qyt3O
# DATA 0fFIrgYVPq6aoN5qcDgKuOEtqueLqvJF+G4RegCuUe1WdtKnFAVSOBsdLNLVZZHecmgzTwV0oD8eDcajUmt4NAanHTsUI7BqsAsg
# DATA OcTyj9pw3DNfA8TAQI0ya1K9qP0nPwH5k40cy1fKxcprq/odKr/2aAA5+2bIZmZXgfb5Y1dipo0GVyTdXTBouSAVPCZcKdDkf4vt
# DATA CTQ1t5mP2mqcNVAUDkrlBb1ARAMlvGcftiBGAaSoIHWSRSrJYqJLq79VcV/2dVF3powx7uNObeHQTEPq/lljx45wjDo4mKyn7ihZ
# DATA ngwHmjrio4iKHCEu7QKPSFtdgn7hY6cc1ShFJEJMwPJzslU8f3pdRkZSn5PBxlxlH7aGbdIPcY+ldfNONrxaUHQeszw3eL/tpp0B
# DATA fFP9Mf4X9RJYHL1xj/sP7eFI1L+ubxf/womgv4Dz0UsEKh6L80A7A6B24FzWQ8w+oKofAxRIzrCo+pcTyUWVFqrn7MkrIhYeBFVl
# DATA KQS8jltxAnppG/RuF4ex5xNxcX6nWv2vq4BIvnwFQOV1fS9/sftjgmfzz9BW9Q+U5Dk6MNEUzEnKRR0qoNSwE2rap3TDWnOxslDS
# DATA 9lI6bKmZ+R6RhkXTpHCjK1o4htYB8Omm+pYGsJIWz+jWahUzGX344peIu/UzX8HRy0jbh7fFWshLdGONFTsB8y08zqw+z7dpEepO
# DATA DauSsLcAToPahnQ8plaAPezHKpiuWyC/pmdntW20OtXYnWAygXj80sq1CgioS+XAOdCPWbEb4eCAoD215YcjqreSXLoEF3GbiVlo
# DATA +kLvP3rwRul++2L5fs3+R9XGHIYHHCK8Ul2AMe3mUMDntSNFNAOQlsACzXNVtMpVzOhGukN/eXmd1sAUlyUr1y6CVVfCuVdqly7V
# DATA li8a5bwlu8TOJXrtMlL7E+tocZOUk9BDGsHB1RHswJy03aglLyZf7r7+KNiR15ON1R2muT9gxuXHuDmtXMsikqHQNYU8I509VMLO
# DATA Q3WsVAVhnXh075CHEN+3xcORDxOuL9A2fiZDoIz1tiLkqQYQPNemY4t7NNZ7irJafwvnnD4szQZimRr+7OaRvboBNu0JoECiVgsc
# DATA Z3Ir7Ju10NhA1OYTO6qjrXd6OXixpIS6qo5oO5hKhz+6mv0CvOEi4xHbmucwHN0iw9EMc9Ea3v6AIlyLz2xjkf7StzOFRdenGoTO
# DATA g4HMP16iGlkmrKaAxv6/bFCaIskUmgQcEw/cVb5EAEPgVV9wcU4gzwFxLwFtdj1xqvcy6aLCVIBnCSpSUonCTPo5HWCKox6x8cTS
# DATA MM1oSOGLuRLLx6M+zB6dsf3Dw7TA0IysECS+L9BTRB2hPZkF9RU6FyM3/AjkEHAw/pmN+vgpxBbGfIW9QN4YvBe70Dq53SrJhenw
# DATA 95Bh2cD/45jhcIAB1sOb13wuAeza4KPkRf3RIxqL+Hcv0Q9SEsSrEzXBTRtnNOLuptUI2nW8kryTnZIDHHg4ou+PE5hsJrGXxjzV
# DATA wyZLYMLIqErXApNRi+EnDCRn7ta/VET2CZoZ9ExeT4qxBuM7irCVnJTYShzKyQ/2W+ljakNO9kYlbg6E9mRV7Z/6dEAKMjB7dskX
# DATA v6qpTUpuwqeoDFFdDKgo7pNCLOVQsbfjUgzqR5vSNdaBdnxNtf9tI720tLREZvdHpw0d+4z++uQ2iKX9YLMCpATvMbokqhaWsQXc
# DATA C4r1NzEGqcF7D1syT2knUOZT8BtEFLc0z7qHANDbTe13VP3ly5fkaae33x/32vziGryxE5nZdRp+addtxxjEw2GAEJ/wErOvvWGj
# DATA rg86Rsak5YVZUbBuvxpupINWHFsrEnTsd8SLfds5AK1GnOMNZPaniGnPyYW/ke6arukQwl10Ao2hZ3PIkr+kkcUMoYoBZpuaIJzt
# DATA S1FkmX9jJ+pfJaub6xVnfSB/PUPNPE5+MGydmmiaLxldG80Uv6BYGgsvpnPo03IkEZaPmSPopAiCDFjkSihrrt66s77hRkbNd+oa
# DATA hNPIAWzgowLw+SBndhEiVXFoWbd/dER3hjPLdxDuDwQyBDLHQNBhztQZ/6gKbppQ6NISBkjBIyyqHl1J2QcS7u19SQaGyeXg9bjX
# DATA BektH/UHgwxzhnLzkJyD/gpiFAtdCAWBkDEb2jbYziSoZtztnHTYobHX5/6epXn/EHq2vHT52pXXrqoOHauroXkwmUzmw1BS5784
# DATA I9DQmUs3mFdnvQeEzoaYVGZJFxPwtn+Qlvei+hdYrryxe2hCLeoSqFVHTh//jBO2NnYZn6JKYRPk+grOrga2gnDv8vqiWuVFNYpF
# DATA flBQczsDjIG82e81bFiF9j57ivbaGD6Oidc4T8ux4sWj49N04iAuEFzG7I8m0W7Qa8ybqvoxUhQG+ETpzTu3qttvr92+jUqq8bCb
# DATA VA/zbfS+ri8ugl9uFw5NmLrlRaoDUSlRZ6fmBH1Rl/BCzhYeJOqcwCJGQ8oAe5UOluGoOciGnX6b9kJuQ0eEPCXAbYAoxIF616bo
# DATA /lQzEEtH3G6NWhAkGSctHSJdX75WgyvcSxIZWV6PT9D/upFeWV452afaJAhezfHO38Iw7+3chHU09CU9NF7VFj7KlObmWcDBUbOT
# DATA g1LsNKneS7773TMn0nySVNvOw1s3JsFiXpq1litLE1s+UzRZMNe0Y3jj1L9XbXUHnR6wx3n3WtFksIbT+h71tKxQVVsF/qJfBPAB
# DATA 6koKTKWniv+eZCdqnasD9NKnd5naRiOtmAXHd+oX/Pa6xv+g77tfXFE4MvnXXnuNXgFHgr+WCgdUvLQGMKd60EX4lmo+R38GcEB8
# DATA vZW1cLUstqVKqSl12BIyMiHqKMPCfx0tVig6e95w9nsS+YqBAYq/xGAeCXH1XwQOHZFPGyIGgLNB8BqAcq4tVRIlZU8KcYpYAHMk
# DATA LzI4kUPZ5yzy6CjmmNyFD3X0FAUqOzLTMxJz0yiKTb5r4/YEDrB78f0brlFIvSRpNM4uXKBvd0X2QNordMWN5hiNHFtTuLP9vXBq
# DATA kOYOCRnXeR/bdzExIVhhkBiWo9s2fqi/3OE8ffdTqle170NoC5bTDjMwDL3KR7YZD/R9Udz0+ex+tVwbHavLw7DxuvgfZI866ipf
# DATA 67//xlJ9uVyuHaCdqVT2SqhXRfzL4TJXZnGZ5ZWIMLDiCgN8Qkj6RUBE9jLGCMOxGKTh1logm3hOHo/IsY3u+PWCvUJvC3YFva2v
# DATA mNPMPfTfuntr7ca9t2BMJ+PuqANmqtHBoLEEQgATXXptqX4NFAJwc6/T7V3+XBy3B9OkgLjQGmyPm9BLgjwF/UwdPYKw64v6VX2I
# DATA xyE+rcJ81hfhv+YZuzgt0r+2cs9qXJCpz6yKEMLaq8aHtdbxRmcU92BgPBMbClv+hGWmBgEInf6yfAIBdxOv2nr1IgtOKq7dPcu6
# DATA iniT1gaOZMFxCuFunPsKY/v5N1I4sF5e5GTRt+GIvVqrYy7iPMbKFOJQcoOQRTSwL60kwTfqrpk7H/WPFvPxAFYHoeFiXQ6ZNqh3
# DATA F2EeRPCKdYM5XsHXB/1hpjEHY59jvnWn1F5cqkFFEqxhjI48r5OI5gmPAQortt6Xw0uL0O2ewM0FI0PkjOIlGXVz2KtFZ7sVJV3E
# DATA tPBtfbm2cs3wrRhxLpyPy1AMMvkhGjZDQbjo3dFeZC8VLIQMZzpne8mpOW+ts3fAOSt8+PChVBiLRoY+euzTYln2Ar4sf5x8E+jK
# DATA Rk02G185AFgOySOSiwukNA+CGX75VfsQy4iYG8FXpklkKYkBbur2dvUrRhWDLqgBAgqUVWwTYdTMR6c0F49Ow+4SbnM9EX1u2n/Y
# DATA y9pWT9EIKItVnlNFxuYwWy69N+zmITTtVOC0c1287GQTZ07Lm5QxmMwT7hsaeyA+T9tETgU7ENZ/b9xpMx2O1Z81+M/lUrnsxRFE
# DATA k2AJZ516z4mluHPGayMuNVwtP2nkBRupQTphR2dfpiLrpLP3Sjma/HIMB9EG8NaIiTaULOArlIwHMH+Ol36QpXMAfikR1DzQ69+8
# DATA t9N00AThx9barXX6CyH0bBA8+Fuw7SAZugnQO3OBBlW5W+tbazd35FcAFFiJIf3BQ4M4qn45AKEuvq2EteOVqKnYMdwmmh4Gqgts
# DATA nksOk/rUxPJB8rT5E49/LWDzr5lc/JtMIB6Pw43GyOjMfgXgxpLzyA/ZnYp2PDeo7TD7yRhc/30MzoqHfDnRXiJO5qSAjZ/ZBDhZ
# DATA KA42FBzbaOReZ9b2JNRlQdPVM2j2k4yLSlKrat10UQLly04Lgxx1bhzjffcbztnHznxfoC/Oh9HQISfHNKXTQc99nRh6oEQXZ5kl
# DATA pV3rcARHW6vb7T/0rdjc2X63DYLlQ291qYayc1cuYXVlGw0TZkfV4KUPnc0LreLqcwpwewVQHB7OnMvn/5d2q1DzxCDhc8yiNXF4
# DATA R1TcnVL5EWrmgTrHFKvP2qXd0gltB/BJgWgd/rndHw8P7Ae3MvClw31pPd16L+W8K+i4zCkA7mBzaiegR5DMfJN6gQvQ1D2iP8wS
# DATA 8G9r9mHvDfuQSrWU7nd6bb57oeG0n9d43rk/a3c2Vm/e295pbt29i3sRrWBaeFa9NRZWlN+pchhSigprk3hLXkkOeSs5KPaHGZYZ
# DATA GRuZ6S2Glsk47QgveQbKx/6DrMQfUPXfSe6C6zIkNhsdD7PMpECuDrqtXg+SGqMMzS2etE6T/QwAfrJ2LVnDbGmCRs4VYkmMf2rt
# DATA d7oYgMrwxAQ0ii4DdNdSex9V2SAqIXbDqM87rpNL5mSTCYnW6OsmfYimR5KplsYQiyLcsFNzwaDbnRo6rARKt2bqw32pS1qrKRUA
# DATA Zja6rwLtmaeX9mxX1Qg6eiwaWpraXdkT+kFBQ4kXO2tNElzubq2vbc9ZX47bVNwIqOpl7yY3zLotznZKxc0OqMm75qhPG0oS2Nhp
# DATA leD88j/s5M25vsWjzXEC0xDA3CtYW/AXkQeIWJ6jX/kKRQi58TR2bjy8meKGqO62qoeYIO/SCgTXuLVBfBvX5TxexmM4vgK7slB7
# DATA 4VqEuxh/abq1qIgYfcAHYuwdcyt9TP4k6PBaHFnrKps3aPveYVU8CPc3FLFCGkX4fbM1WG23+a9bwz4GeG0OOw/UzRi8LPacE807
# DATA P00eAPTFCuvyNpPiM/ZBI3JTPTlDmM3WoKyuM4NsiMQHUwfue51HquZVdTPgrC4tTMFV8kRZgDwMGI1ORqHOGhd/AhYBekMHDvcL
# DATA /jGHDf6yjppI5gYZMfNJqaihq08+UKKb0XlO5ucEdhM4lcVtVM/dhqqfc+3OmjtFoRYnLy4Y9d8K5RNTQV3LciC+xXeZgTkr0HTV
# DATA URsGNyxWeqURbSxgv1ta22jBUO+KKW6t3xZgmTprCREZmUssUZXRRdXP6dPF4U76vZPnz6rGr6fW6h0cR+Cmw7R/UcRhL/nfi48Y
# DATA Dpw81dDM67oYsmGhdM4LZXn+9JB2sqviHOMzxwvhnk4GLJ3kjZzxAqyhZ/IQZuArdTuxWauWTL1x20ItB0EfdFt0AYzcNK0kWqJg
# DATA tz+1bg6lthGty4GjPCajsUsgk4C4ZOshEAuloMb4OfzL1rtYRWtDinGGBJJwxVrEdZvPnkddN1VZLXDrXOGh7kWxhGPpNvjKrYr6
# DATA xyRX0kic5C3OXSSIIdfzSh+XZ2gRRK6Gc/rRqEQnuSs+6pV2ndVZskZsJlwVfMCxzNg2hcdxP1zMES25cftM+Xztcq6YdgGMkaag
# DATA OyIrDorF7+px2bBk7y1DjLJVqZy7exnqjV95hgGN0e1m1KFPnGdyi5yWf6Govu3IVJRic/GK9yHdZNElhmbAQnaOkbpTJ0Zssj8W
# DATA XfsE0sdpQ917KSYkjmFXqAIpCED4Iwt9Ea6kuRmdpkxLC8EVR2i0XoCCFhCr2ScRsi0Xw6FYSrLIbsRsUSg4S1178T0+dd7A7+jF
# DATA h+rYeiIo2lbaUYTY9CeKjgSd2xNS//4K5pNkafV/NH1e18oGpbeR2LahUhq/ZUAdtva/dpw9Yk9tRUWoCpyWqHOGSQs6ws/hzzKa
# DATA xgYdJ1WnYa0VLZbHGWyoIMQE1HR5342wuSkHHhCT8OKGzefcxY8ePgWlwQdSTiDHmi29nMG3NXtjaBGYjCDdfXAg22BQzrksJpoz
# DATA Yiv1RHRNwpNpXZgjggsR0VCdR2yxdiCFXVm5PVOxrkjWz9RhVT1x7C9QlxJK1d7OASytnW0DHe60huu9wz6ccJjtnn9b8DlNNOhk
# DATA 6hqajVrg81KCKJpKAukg1P3XRtPpj1qgXFMdaY1UN7iE6l3TYBVLLc390xHO2BIsHVRZAxdjF42SHyavJ8tLK5cvXFhBusBm1KOr
# DATA yQV5HmMBMEbWcXFPEmkcA+2ydo7qsbx1mCUYAWAdEfxFrbDnkF0BOmJgbADnGyClHxVOEA4onE8p6Ats6HWiOIOpWJf0Gj3qjbv9
# DATA 3tG307BUXtR4PmgN86ywbc5kg4U4b7Y6XShnkbq/o/IYdZxmuU46R0ORyegahebvg5F1k2pyS+BjkrVOKnorwOo0cTkbK5pALlUo
# DATA IR2/WF5S/+M+vvrqqzdgYhLCNSfda7d/1DlQVIbEQrff5OGwgxH0nd6oj4SD8XgQIfgAOq26kdVUZQuOtIkXL/uolU1ygLyykSwt
# DATA 6GQWsgf7apeX4K/+/o8bMjxyXhl+kOJIO2qPNvxNjJGfPC2e+jJD317QwfivicdBXy42kmUvd8IQry+kEcQqangHJ51XmPoRannd
# DATA nmjYruHX6pba2lf32PEoo6tqWqulmLwPqi0yYNzr4Ubthbsa8aF0ykHsRhoFseNedHK6JItgoh9z5nY9YeoRE3d5Sq80EfdiDAfq
# DATA CXvD9VPKHwJ7tB+9blFxUiWaKeqBxeYCrqY3UoJxWW43nFufnLY/7nd6MJ+lC6Q8jU2jfXHztLfRi9JUlkwZ3hQHUKTWjt7G3Cnj
# DATA xYuijFpTOA398l5PC/FGUpMkZC4n4l5GkB7sSTh5H/qEO3Sp/9rSEgTAgoyac4grwkc0++9Tppj5tHrEJ9SetAZVtHw1au7r9AOO
# DATA 2+PxqNMFQNv3m+O8dZTJatYOwX70fYdCLyZXLxcdvxb4gNodh4edA0jlkEDFyGSVmHVCqIbehrb5fvT+KacyHwe4X6lX4WjoGwaG
# DATA PQdBSmIs9eWJ2v8G60z+951k7dFBd5xjYch8BBtoMMwewEwn7TF5Hcjezyl6HSRROUDIFSeWTQm6XHFWFs+C9NF+isyd8FrqU4nx
# DATA 4FgRQAnX39oTGMD7V8lSf3l5mUwpS/2rSxGcWjLckWhfRHomd5QuHd9v+13I2mJZi1rqjtgBCw1/VkmuXrly6WpxMiHgN1jLrExK
# DATA kZV8qGZsNBz3YDXaBQmSaEZrsDRZCRuKlzPTUm2gkamgLNd3qOjjuBR5ndcO89PeQUnKqUns9UuupxSeYNpNYXAak3os/bGQjcN7
# DATA 1d/kcmkBcw1SS++MThFwCeWNAtenGoZfsGtmFApzE+kRKgfTOcA5Nuy365tr+DwbDv3nLP10TjDUGEzSLTArIfrlsLQM0UVS/P1O
# DATA t2sVr2lsLI3kQ8/xZih5FQHaQRXRBkIH0SPA+ZwiT7polRVHT2JhdKzhP7D1FZUBCY6HvjqKu8QvYzijOFSLTDykTMy8Zb1ud1pH
# DATA vb7a6gc54U5JYdUUba7lq5euXS7XOGVmOh4dVq+BJz50JVfiY6ZugY4qzKvEb1H75ko5yPBYsvI5muAB4pUQP3CzP+6SZHWoLr4k
# DATA KgOzQBnPHoPRN3pvHBB5nEY2kCPIt5bbqMk50UzSm60eXjrUodM9xY1lnT3XtbODtUUUU8eAy7ZgkGBfwtuSJnTQOnUzxW026QHv
# DATA FHF9BP9aa5Sse4NGuzaxInEfgK7Npg0LvHXQB6qJn20FlGW/CtaQWE3eaw3y4769KVBLqvo/7jVcPFyCS6ZCjQIeZcNxjDxVRjSp
# DATA 53eS1YTD/4UsTlrvq/siHZiAOwC+Jl0S3TADXycjKvrJWIlLqq6DrDMA9xmu76B/nKGyUMZWS7bU3EHUVPJ+lg1IVI6sfLd1qv6r
# DATA 2HB/jEjZNBLCQ0MFM2AC28zVYKXJQEV3t7dXIf9OFsLmhQ+WzWU65UC36c4ws9DgbOxXZKnf1tuMNub3LLHdQVlXDlNtm+S2xr0e
# DATA ykCB8ezfNGKlBq/EnHiF6uevHDvhM4JUtdSxiAbOutePigAuaBB2RlbPKMo6WKswKkP3tK0QfgapWfEhi9HGresVW5fL2vuXcyKB
# DATA 6j3b9+zEy7aV1Zvjx9MU/KmZicidQN8CLGc0OyNG0U515Qw1xfDBrugiFZXjlNNDVy3uiuRTvZWM4hcmnxWyBW41VN9e1JugcFb/
# DATA jPC9H88xfUaPE0yi5eQL09TmZGIW03T2WSCjuUpqqKEQkPs7DNSZ5ubK3GsP1DUdb1RwoRh38mPkg0lrPwdu182OWpiRT5Kwm8oM
# DATA OeOBRqLVIkTyw2Gq/sRbGosseS3ZyCBZY/4QfXmQW3Yxb3rNv29NOfW1XR4HSpKGZVSLvS70Yv2XEJLcMco/iy6uZdPhbJ0A4/Ql
# DATA 2ssYjQxzqiFi4IczgEzjGjzZRaiMAl8q0UdeYBoaHnX7+6X0Qlr2KBZ0eSBhAcxrl9JBB47YjBobZJMuyRvt9uECzJanTeRUOGgE
# DATA S/yzzi4NzhBPwnl9Fts0U1SKWqsBg9ZJr60RsgqObqhFGkZU39qmAEvRWzjg308x8xFFPHnxqxe/FDNhNNU20BgSBTpLuwzZmwAc
# DATA kHcXDxZLZmHq7Rw8i7RPQYzHTuHeaLp12DQa/Gf5M5UrKFlajspDErtL+JeEqHKuhRqeKI59UMLzQFaJfuPsGZLp4C4FG4fBMS2A
# DATA SFCudPrjHPplPVacDNQqp8GOouTM4K9garZ9Euh9XEdM7+Z0veMs0JyggH5xl9UjMky6SjvMEe2VpTTTkdIFMPAiWly9PMELBVQ5
# DATA faN7JyGipQrfQ3RTgpGjvGqKvX5BXqNg+f6EGauAzKnd8yk8CrtqTwZGU2GAKAIrLap3i4+GLcSfiTyuSh6ACd0JZdVofigBHRLu
# DATA /rjX7gKc19yukXavXplN+ougEqEpLZzRf/Km5alMylcEK03i7DNJJPiE8mhYpxS4cKAvAUyoK+c9f4wIs1DNL/CZLIMk3KDz789Y
# DATA 0RNwSjO5QhnV9omLa+10ME5gskOZlCw+rHYN/NXkTOhuORKPp07Vv8yVQcSZm99qMG41aETnhSzZxH/5MLKJUCfY6OcoYBNIsZ3K
# DATA Ca6VqI9TchpKJB3IW2YppsFVORn0H8K9r5/nEKAEotVBa0hmiV720KqMLgmW02WyCQmo82MUeR4e91ULct0U02Grd5qw7gWiDmqW
# DATA Rodq6RB8ogXoCaIv4OQi4dqCBUr1RpgIzhXLBcL+jKN0rAYxzUqD3asxOquOmk38k33nQXcBKP4ZmQzqvgUC405Ry6WmH3WD0F4F
# DATA ft1tbt26u3H7h8kH9Eskd/1g4+6bd2/fvvueS5KjGPPValPTpJeYzleiWF+STsv+kvQdqPNtqpu+uj2X+NBhwNV6cJP8WuFBbDAf
# DATA dPunJxQRiHVyKN+Uu+xJa/g+XvzTLak4+X8+/B0KIpK31Pj0w14TcU1tMMm9LjAcEh9qbnxWVqlip1mdXco1Kev8iXbyKmmKHGHc
# DATA 1aD4P7o1Wmekj9sLr8W5DCUheOAzLaLW0P+OzmGcXAIhLQRaymutNuFT0AYxm8gyTVM2QbNui1jIAFOXnHcMahLL7hC2GvuSQTcB
# DATA zx/9qnDxFWU9/2d0PYPVJiThn5ELWhgKCoX/u6IAgB39hdxurNNFvrPb95N7IAgAJ4dgL7q6enRhN03w64Ah2d0QkIS9vVit6jhw
# DATA s08+gwTXnyPcugk4nN4YsTE9oeU9J5uPfm6FM+N8XgRbSGKHfsF9BiV3Ukd9iWorHnBV76On1z2sXTyIYL3klhjPH1xjK4rVOswA
# DATA fog7mP0SAbDWOtlqiQD84impSn2BSYc+JIWPAKk9DtsFwLWnioHnSbXbClA92NX9z6rgJyAlqMb5ExxLJTH+kohgDZ1DHGsIDkXU
# DATA NQ4heoLk9CWlgpUksM9qYYMp0SJcouCgf2K+wZTmXCmlHHlsKJr8FWFPCLRVORzL/4mo4eC3/yd1e3PjD9ALVlUZVkjAPmFt0Mmn
# DATA RJZ+LIMizrCeYXakrjtwf4gPmnYrVIG+tgft6KZTDxNSH0vEeTLAGCu0NTKvh601VitaNegZ8Y2/F4nlMshYlQiKnAYPqw5aef6w
# DATA P2zXRo8QU8zCuqkILE2FkGQqPIsVvszBHwAI48Z9ucyNfH7CK6LeHeLW6IZqB0wS67GCHkjoYnmDjfZlN6IaOLo0TNfXQkWKl2Qn
# DATA A01cp3fUYBNa2XFDRcbs61YIKR71DOp2YCe5hA3+5vrttW2Y4UDYNcO1DpeIdQSN7mimdodMxlqeDfdY0Y3COilxAL17Sjjp6C97
# DATA Xy7inV47ezTjzHnxqwpwnZ8nxiVdsy0E0Y4x8jTds/NTMQ0jeRJigeD+ORYhdc1oG3dcs+HAndrUAmj8njIBo0Hha+sKI9ZC80Iv
# DATA vmc5xGYyisNBxQV94l2ZcKqAoTs9oVU0VThiXRE8jNrrap4fI9LlY0d2M0SBwkxBvWV3kQvTdOFxKmc51kzCmIPQbtqwcpDIeU4B
# DATA +Hu+HDa7d8UyUTihMB3/6lIRHGlzzwSDynlquCP07PYGZ7PDOwVeR8hBjrJZPf49Hc9I8/8YwTytsyBzlM1FE9PpwgJX9SYmaGBe
# DATA 4vAJJGgiQivUmCfxmZ3OO9iIa8HZuRiAFqmjucaXWknhulu/tOKeLDP3cBiTResf3c68wEQR454AJLTTWZVaBBCM4xzLPQ+9x5eV
# DATA KD1W51xb3Yy6cJNbQ7RwRhdRdrVluD+TBss/Kz7ipAsfonYKh5bgR08l3cvzZ6HMKK18P6zx9UUyajHGZvXCIovRQKcY4OPKltEU
# DATA M8+fVUAbpXV39NWz55+RZp9uTU+jWrmwsyAI8Xz8+xzyKEHDMvXLJX6a4Em5FBHRQ0/7Y2oEpvITLvknHYfqpIcIxdzfWxeOp3yD
# DATA eaL69inmwICBY4c+4ysE3kTMLPGFUGz4SuwX7WZUe6fEBAEfePHzmsm4inwA1IZaTrHSLrEMI7wiLr0gYRrphVQ5iE3JuxYdtofo
# DATA LHqEf9dWOTnxJr7RmiC1YxvNppLBm82y9SVc0ZuSz7iU9gfZUMKMDo77oBdpMJAh4BCjLAzKwj7jso+GrV4O+foQSw9knCqL2/iN
# DATA /Tch7UFaXQgkkNyZrSGK1egyUuWA9aoNMUU4wIigBH8fERIwMbcUs1Tkx1XaSpyEs3N4aj1wWBbg6QUPGYc8eM6dp66NB0eSvA0w
# DATA ODujqpX5E/J6gFbdeiQ4xlUrwyAYqyyvCWyQVafeY3HFsn0shuzKo2ui6YaGqtwBe7IKXnPn4y9lHPTWmYwRQPnptTSgOGbdJXke
# DATA qRjFGSJKZdWqxOteLyogAZWFBcQFaWoz5s5ok7Mnixe3YQ6iqa1onLbizp4gUGHhe1r44vdMWJRcZmpfAIc9n1LTkB2cIAhyeJQ3
# DATA QKk+dWyK0qZ1jMJTzWoUlrT2dNWJ1i4ob/YNW8sa6YyeIhWqz6qIv6I+bKFVrZEiUTcp0eLUJhGvtf/16wDwyOoJocoYsitKx7Vn
# DATA DdGUmbMVTkKhK8DMYNenfseglcGnlFVsWrPEKd0lKWzLrx6T9ExnChFWPefiO5/Sbpuvl65EG3R5eWnm1sdDzayy5JlLJYuqs770
# DATA dvbanmumIadK8VtJS122PeW5LP4Dpa2UuvCrpuUAA7dIDL7A6QE/IqROL5ZYo3x4yUGtzyQ0mK1S+BBgAyFWDnN+lj2VkPWZNmL5
# DATA 4LrY1Dp0GVB1w5yxApTkhzvHMngyHgmzJIPYEu2W5c9R9hIrUi54zq9tC7B0dymlCCijU1KnFgKmPRxCL0ZDueikn4LPlgDhxhfR
# DATA EuLMIoJzNDkz45uSv5jTq+Sjvu7OgxgZ/boqSbDmc/TYEjXqIWkFNfqI8HGQGb9r/npbpixI4AsqMsBzmA+JC/G+DOiUYgWrt2+7
# DATA CF2OGVGSX+GFlPA37NcDAziGTvBOgmeZONguMGXUX5NbkfsfTYnhxPQ7ndCwy2YUUZB6StzVBgguzNwFo5s2yjZhqDEuwnyzCQ4O
# DATA sYRgc3IDdxGdueM9eQrp1yHygkvR7ur10+nEad87zPTSgya8zCgeomaQKqbW518OzkXsDKJRBL/F0llTSRv0PT8oM7P1ujjn1FpF
# DATA xPsTOjB9mLELj3WmRIIyzsk0pl6drOs3F7MjOaSYO+zzLKJ7V7RyIuaqsVGTXzT5SM5jh2DINfEHf2JOx9mpZExNstyaXfADovVS
# DATA eZ5Bxe7mFo0WQnpPHaKhw/MdPN4V3N4r8KLJL5wTecqiFs3x9E74t37bpkPXBacb5+EDkeu5z2PE86NoA9ssgcQuRPPg6uajPHzC
# DATA zWmPVkZHJK11xbMWGT5jPjMxN+6nTIphBjLTEbzNliMMjO+dzRgB2YDSDssInNanDa2SzBqB54ZLrsid3mA8ctBr0O+nbkyecPkj
# DATA F9i6422IL+MyJcWlGeY6hftiJIaV1amIzKapiZxUx1hqLgqaa8tObY5373zk6l85Zm3TQqVWuG+pA07eCyxqdQMXo2JtQe7XDKs6
# DATA IAjOmChXg2mtBT5v0vNzsRStsK1Pox4pVZolLViZZqJsVFIKAHHPGGugJZ3eQy7d5NLTehryEPzBX87oltFq+1JYBfIsIBqSFImR
# DATA 5nlnkNOK+X3WxzX+lMNaKD/I+DKVN0RvyZHb+/V4Iha4AKmBX4+7v4Hsr214VrM2ovXefJflwmNR2xamkgjtXFWsNG1narmXcgnR
# DATA DwJ3D+cWFFEz6CVUXNX9W4a26IT5feJNOl0sn6cDYs+Ysw+ShvWb7sbMtXLamrlkmnnOoTOY2TQK/dBksaMzRWHq1CRaXrFS/Uzt
# DATA AyeWMmswS2DrnGDy2fzU4AGov2vkw9WD+0Npycrg0ET+2mxae4wjestBnTqjkYsJukj50qY4GFhBNfNAI0Mw9OfoSImZbMNYOd0R
# DATA yVmPP0qDimTcc4hNf2a6SqGpLrLPdeu9DkG7csVnh6qM4+uHP5rEF0shO3CzQGlW7KaPIqo3qnwD2z+DRMgGGp4uwpbxfWmu41an
# DATA j7OPkqnsjXKdWeNxChaxgEje4MgLuxk37XuFYFF1o72+/S4yudGFsB862bd8/e/XOaHcKtYAaG0TQpApQduMauY4ha+/3Bko9nJH
# DATA YA7S+gTCx9xiiSgRtf2rivlR0kCN/fz3xmcaHSU5gTU4Rj6bnochABXX/GHWTSWtB1pPTt0ZYx5BWTvXp/NBNMmnfAWkVadE44b7
# DATA h6VoC+qMik3w3i3Zr8oxjW096QzUDIM1oNYZaKlWa3iA1DoHIxu5oGiSEA11wQ8+CdTcUvVeAdgxfljBtC9hrpeiMBRfuFD74wFp
# DATA ux/ALZtCU6YhWVMNVghL8VUOvT7OYYPy8h6KLazuKXxSMhnWLR46CZeMbec2Ok89lsOQy60GErRVyWxpeGFBtdtEUmo2cfjNJhBp
# DATA s8kT4MSOkU/QggXZFIICAXYTYvrUpwkdssf/9cUv1eb9hOIvChzMZkYjYHOKv2BiZBBnCPDAglxCAKPt03yUnaxRPnJ7EKV3gSqw
# DATA 95XkneyU/wKocv7z7jb/gWgxf7N9d+MWwkHh07IdF7mOqhlM/dTpHXTHbUHjw3xOeT3pIfoDjj8ZZj8m8BuKB8PQ0HG3m0ADtW95
# DATA +mrJ838zUaMvPiboGIby0MErFRdN5lcUdWvxZYpjcZOevfgVoJ6dazX+y3/+b57/qV2734WTWG3L2uD0W2kDgCCuXr6M/6r/+f8u
# DATA Xb10Sf+Nz5eXl5Yv/5dk6S8xAWOIGVHN/y+6/q+++ipsTMVtyVot0awYPSrJ6EiJ1wGczGHWzVo5IHtR0PRybaX2vZXawsLOMbil
# DATA 2wUxr2QyOlbnDiIocswT4t52jiAHx3HWHWBo1TGwI8DmVG/746PjBSykLyjJzs3NKgEHH2YtAOZCSzGEfZs+ghYWnh63HmSqdxkE
# DATA S4Bhtl1TfcuGGFHeVkf0PhzNAC7X62tr+4F96CBK8aPsYExgFwAWBxIqAXcuAHj0rCMu4EfpzqzxHKtDzu50+hfiYE7I2cGP8/+A
# DATA /f/a1SvL/v5fWbr0n/v/L/G/dJxnLLCn1xcW1EbIR8lZsjns5Cetm90OXuDpVzLBGB3c1qX0rwf4cPEAy6Tl6/ztjx+O7GIg3jzM
# DATA 9slkUdYtbN+8u4nZwO5i5kkEL/67rLRLmbxy3Dl1gcD3XZzzOuAcKmGX4wwkAVgQ5sHv8zq7XxcXgKuDqmYPeng47hEazTAb53A6
# DATA lob9h2XOWyZ5svsPk7/6K/inxmndnPB/uyEM5EhVaaMXgs+yRwM1Qasj/LQHMtoHHyTOi9cxde0tuAKUy8H3+YG6ZOQ1xVePIJ5e
# DATA VUJzKk8++MCR8ef65mKyLKPioixx5m4wVp2Sxjid4ppAFj0t4ddJ4/VoVfi7rGZ6srDQAsCIRM+4unY+6MDdpkTUVcHsK5K7VNYA
# DATA tICvLP5od6n6vVb1cO/s2qSq/748qV7WPy6pF9e+19rfc57I38srk+8u1kZZPsIM7zD/kKLEmjhIDdI/lMypr5DWDHKVpFCYHsvc
# DATA fT+5tFIGyFxFGbBujGe63kNFgJxTdMCo79pq03RakEbtugBIKrrhpNxTKckuL86acEsDn7iEpq3WGnQwiX1eA5i3e73OT8bqHpk8
# DATA hHOwrrY3jneSTLjxxcVkK8vHqm3MDJi08MCu4h1PYOYq4nsCzSGNnkpqMki2AMPpAzznMHvQP+Bz9DAZdo6OR3lNL5vusCKzV/T+
# DATA kqdlWWGcfH8q2c8tQV6SHBy3ekdZ+7pYP1Ea0EmOHAwBcj+noVJWna5aTqi9YWZQLWjBFCJ8OEwf8KK61UOiTVizSiK7tm42Lfyn
# DATA 1us/LEEgzPJSciG5dPWK+u+1q5fxnAPXUdwa9WS3VqvRBuIYNGdtdkCE6nfbydGwpYZD972D/lCNfNCHZCGQuBeABcdKbFLrgFDa
# DATA GoCwptYWRAqprU8Zh1tAPa0DjUOIYMvOIoMM1kE6HdFS4xhZDIotqPw9F/Ow5pFWomD2RQlCtHsGcz6p4Eqc8exZkzeZOMvMzFod
# DATA STWQOEtnvGTqzBvCstWR8QKMTxfi8FY3162QrE5LLeYdMGMcdvv9ITJQIoX2KuY3AlBszCq9jIupP1TdKeDwbyRnAOLYArV4HVDP
# DATA s0miCEoVDFqSj8OGJuVkUrH8RYEJVdSebnWP+mrDHp+okby9DY4aSENTmOyb/eE6saUou62YJPA25w0eyoY66LY6J/l1G89bdYue
# DATA AiyuWgVyBjBVmKbOdPdhO/AA9tQA1FY4AEw1VdXihWQ1aXcODwkuGBX1CAurWM77iuINW4XsRrliY7AXhYRryYXFZOKYkrhvinTp
# DATA L7RY01kOtAAv+Ajg98g3G/Y5YJ2AuL++yVPJatTZL4b/T905NusXzg911e3R6B1jz4sj+JR1bqrgcLbq0We0qW0S7sQZ5ztSK3UA
# DATA xcca5STFFGTtsVoaxaQF37o1PHpACZ0bAIcv80PzQrUDtqDaN0oMOXOJMjKTfZIsAZx+DPkUSiTzvlGjqt4llesbNRJ336jlgy7c
# DATA 62opQDonb7wBGbJebySvwR4PdM1Kih2MICky0GNJy8YIRtUaDBZRl09DzBdFsOaPqoOjtFyj3mwelUtnUQdKNYgeofFtI2HW9Typ
# DATA g7B2a3Vn9cbq9lrz3tbtirrhP6onK5UZ9ewQwvWdTlfJxnXFeppLgEvcaXcz79UlehXUNwGulB8cZyctGrlqvVTUrXItzwA6d7M1
# DATA bCmSovh//FYtrZreFANPD4CnuS0BB4WMWYralTQQweXApu37TInX2iZV4TEuypkvgdxiTx4l8HSAzXT+jgQdEJFAFCH2ltjjSsMN
# DATA US7xs2mM2J4nY93fvndj++bW+ubO+t2N5s7dd9Y2mvfurd9yi69ubrIHQCXIIDCluq21e6rLWKnRrNZAoiiRxKX2kZf6gIwA9JZj
# DATA fa1PcUplA+I2U9y1ltFUFmEEP/8MHiHgIBjnNWjDLyyYFrTUfY6pjw0MQgDpEFdH//b579DYFwcz9AF4ahigJHP3qDO6idbzZFkd
# DATA S9ZIGdiOx8qM+LvomYbbqUS3HdrhcLT3KWfXmSGBSowaKnJPnlxf+Avof5pm93+jquDp+p/lK1cv+/rfSyuv/af+5y+l/91EOcqs
# DATA vbjPYtoUULOqfYs3ikB94tyysra6gWFuPTYvAae8ell+gSJI/u7nCwhsDk5C3c6+2KPAPUGKDDP5C+yK+m+d30KejLKTAdzvqMLx
# DATA UB1J+xQfKLWCLwgc1gu6anL3Z1QC8tVCN1l0ZSYN7mF7HrRMAcc0vzdu3L57852ySRcIoJhtyhXYhlB1zhFFCQMtgybBiyOEJoCL
# DATA 03sv85AFoQeFatvN9e2ttbdKNkC1g1gtaTkh30wsAYuxUpbS9Y13V2+v3+JTBWAdXMgmD7mVkLqkIRCLGSH+bAmnSh3gmXpaKk+i
# DATA ENpLr71WntUj05PmHTitbqw1N7fW313dWXNw3vFo4gk1+XWu+Pl1tCfeguMhTiuP/3XSO+ETJpFoYSdviuWLgG/RBwKXoqs/CBdi
# DATA xiJIgggi11rgd8idFjImRx5CpJW7v3aeKeyuKSk9pvg7Tl7AI5DfMIiVpcvXMMb1/n3MFWSXhWjD/rBdOiiDPuwSPOKfSkpfXnmN
# DATA wuzsr8rzTAeFwaI0haXZ5cTOJIWRcNwRuBFgAG7ocSGTSVBDPt4R3ih9uDI7tQvPZunswgX2epDwTAyVCENwJ8HONdVJovHz53aJ
# DATA z5biPKu3Za42Vt9dXb+9esPZxhIJTNGldqsb9GY7G4ECx04XL690+LBfm0a9R/Zgoxvq5mDo8IxZRCk97ueokN8fdtoY8572wA+x
# DATA 7EDaYxukEPV7S7nnU7Wpu7SrIau0P9PSv1hKmHR3tfq3rerfAUS7+bNZq+4p/qUIdZKSYu9ck84h2gWTb8gzSSFqub6IMOYaUFEj
# DATA WDKJoveW/LA95fRk8AKBvL95dwv9fQmtQHtx2i5LVvv6T0gJgv2w9zFFkmJgNfdRXmFd6jxVVcipaliDbEP1poY3N3u9VWWIeoNx
# DATA 3JrNQFEgBZwD9Qx+i25Ofgvwpfz+yTijND/w43DYOkLhQxdWR65uFQGfqTV8CYe/4g1LL8Ny3IG90pCx6JBlprZpdb+9s7O5zTVv
# DATA rf1v99a31m6lzqmjdbZDQ9YVqVpx+s2tuzfWgI0pMYv0FpIPWV0mVsej4/6Q76T1JL2hLtSKzSDSmX/9e2/13bXm6uY6nTTqeoGe
# DATA 1dFSeiYYXfM9QNfUFEyKKe7FbvqDqrq9PGwN21kb/kL/sVTtp9qS+n/L6fV4yc1hX3HrvUTPKtyWPK0lkDoKaNAejb21jyuKN/RV
# DATA +PsmIXF1ISy7otMY5qRBhdh+uqDhdzX8L5S7BlpVdSMX1RCr1lC5nmdav3aYAeOYMUeMhqzYJw8UsNnJ9bme4tVXESXoolvdOnWD
# DATA fpAWDg1b0nCt/77Yk5h+KJikdQAdIL0CqF1ByGssAZbHuPd+3tjdgxfAhqnbJRoOvkWLjFS/32+fqsmEzy828DWbsq53Dkvw9PXL
# DATA FzBdC/ynfOZM2vVIv6Ri1bMJ9aU2gPyaN8agsK2BfF7C5+oyPNHTjH5qDXRPoyTOXFy9PVByMFVUro36pNdCaU4Jc2a6yGn0gw9E
# DATA U4u/X2k00j5altFSR4Vqekm90vqF9Vl06q0hLug961ahXkwE6D45O+iqPSjEh/QIY58slJC4S+XG65qYxdjdoGVDzr7YGnQWyRi+
# DATA qI3h5etq4CXuvzwVn1AYAaumy5EBaFCV69IsG8DDVotM5da3qvq8sToctk5rnRz/5dD9vPyGGNb53xr/q75VnX/F/QjqKce6azep
# DATA PoNyu0t7b5BGfO4eL6YXMaYxu7e1flOiEqQy1q4rhlMulbXKSq2Lr6+ydEnkHGnhoGjo7ceAtKe1U1DqS/KBJCz1T+lpVDOFh0Ml
# DATA UWUQvQ/Sh1DSItKFmQYQZNyGM8XcSJ7uS02Zr7ZqLF8HLoP+S3hlUAX2sxKHRJh7AF9g+NBRfIViliviYMUiUfENKrxkcBv2DQMf
# DATA TTssN1ffWmuu34H/hvIUXq3l6l/byeBi3xqe3pIYkxKhcUAuVUn7hxSBQ67SFfyw31UM2oH/l1gnelXmGGpRiUF4lukwC2akAkV0
# DATA 9jRyHjRs8Yl0pJHzF0s5atSYyF7ilXCyJL2M4B5k70BbWKTy4rsIXf99KZv/tER/Ksh1m0SXscxASFwmXeceYlFlB5jtGELjqoyS
# DATA jv7ZvQdlTZm7UOWe4OJBcfgvikoeoErgwk8YEP0cVQjOSNSFRi3ssKQHYm4r5fk6z1Ds1SqhTFarA3X7wKtOxiiUNloc9aIYHaNo
# DATA DvC5WlAksNRMAm+56FyIk7r2Qbe91a0Ustv6T98rvWjLAtWv3ry5tr3dfFPtWBBvKYUh3tOJ7YCe0EC8YCKRIubDLSqWtUVnrfpe
# DATA 8eOsDTr2B3Cjlzkh7eP1JD9uDcn7I6FsKooDnVopYoH7WR7wlE8KbhALJpFkHHuJE7S5WEvsZa+E79jmT+vWyNLIvlcFcMCTBUmM
# DATA AnWZTgHLwaRYeUlCsagbNtQwfsvjJrwnAYqIVtQfHQN2fEE9bnoovstXEvzIZKCxJ6YGNQF0v1zyX9E5R2WuHPQK7AUjyRHWx1mK
# DATA S6Um42wykROEBlT3cnzupjaOC1wYzi5cEFYsAfz2XZnTOkreG/0paBouXKDlm0Quy9bUGRg4u2LCtjhL0WFKdV0IOoWxq9/wz6SS
# DATA BGRTYZoxR6V/b1TP7F7z+yblV5u9BdV5KXqIOxALfG9j+94mqAf0XTPUBEFSIRtVSyPGVRy4OAy0iyl7Kga1Wj61ySKM1KLMQXA0
# DATA kPRMIwWtDmoKZfsjtqs5wAH+1NHyQIdsPZM+lKwW5eUuxI9Jy+awoudOB15pePxnzum+eXfjzdvrN3ci02zPLobInamzbQSKjq6i
# DATA FUopTc3X5Rtr3lujUQu4F+A3hJSBkOCp5OZzk/la8yCV8BS4I5OXYT8n0yLgrI6BA20JasaLnvo2L+1eMG3CJJfLwW7WQ8A4My7t
# DATA OIwgNgzxhz0nJRgy/BK+qYgPIIcc1hdc7qWJk7I7MWVavEWtBWR7RHtVbf/qZbYc4He7KUU6QN4vz6JAYPfkfYhKM/6AeMJegaxI
# DATA fYI2K/IB7u29oDpOL/oX8//ncNJvPAxouv13ZeXya5c9++/K5f/0//+L2X+3T3sH6u7dA2MhBKeQp43redwfdo46mPm1ZadgIRc8
# DATA gxOP8hUKfJj45tHIsu7yE07hKcbYw4PeqCs/AH9QfSE/dZjxN2pDhgv/y1iL31n7ISgot+/daG7eu6EYffPW3Tur6xvpwur29vpb
# DATA G3fWNnYw8gEFEcijMkx/VHqjTu4eu8n90d7F8hvB5/jiQqN24buQgT6r3QGL3kG3lefJLdyOdNSYU0cj6Kt5IYbY6w9PwBmJOVah
# DATA rY8PX/saTqyRrXz0dfJ6cmV5hfwq2SkL8tnez+/f/69vfOf+o6Wl6v1Hy4f3H712uJcyCwuseHbXUxpok1XrfDx6ZgTm0ZY9gp6E
# DATA xggr4LpQKT+nLYFRRshcAFeUSnL58qWoeeL8A4QvaYS6khrpoUppp91rpfo8Kde6kNeUTdPO7dyJtOc/S1CdE25siMMCbgH6CI/t
# DATA eXsPKgGgCWwLrL5X0Jqb1nSmeByfegT/qoG1Ke0WuERCCj1MHWz+QoOflzYLVNTdbslLnKx2zNIj8Ya9+AH8pfZNChhJw1GZrxJD
# DATA 3QPLETOoHYE7whZ22e6nWuI/0ep3dXkib8pvzNXeS1A9J78UW9Vuvbq8J2RMmdBkItFyhdQv72RduuKqAstyeYmWpZbK5Qp+0xXQ
# DATA JNVyxr/IA1+t/q0abK3599W9i+rRov+sfIGmHfKdnX+kLMAhlZBRxHK4EZeaAQWNOHKbnR8UG7e5WST/J98tDZQJMAJ4Mk+f1e1o
# DATA 9U24su+8nUa23zfhBsR7FBBdNvqjNwH6xduq4F3DM1GPObBqJwc9lm/Vv6h0fgejpZXLyQX6x3rbA2wmWI3lMOOvKXV+36GVlejF
# DATA bL71xdSErVHL9xmyhnAxWS7bmw2Kl91hvhxt8XpCfWoz/LUnEcHm6IL+kDxT3O0gvio1HfAMjPX9dIa32ntbQpQ3t9ZWd2ZRbEXu
# DATA HEX01bpYQF8Rt7RCYtOk9PVWMVBjoywJMTQH73ObFX4GY2uu/UAN1/q9cSNQid6Abzu9o/W73hYt6N+9zVurO2vNG/e2f+hoOuWT
# DATA 007WbTPf49W211a8khADBFyS8hIS41THJE2aBBJjMoRhwhhCHiddCWKym0IFydOKp33j7k7zzurG6ltadaT1hVOyY9vs2uRfD3i2
# DATA eeUwbtOCUyaO9XYeigH5C5Nrx3AiaTUQcMoq42JxLdjs0VYwQcUMPiRSx3Ly/QayDnxZhl/LV4vEE68uFtDh8I4ILnRAo6PScmV5
# DATA 5Zp2VHI9r7DZWINWYzzeoq7za+z8tZekF8lofmaWVRLj1UkQCF9YYgHi5E0WDNIc1jUxqdGxi5TCEDtri7/INu3qqYx/CGhxZApj
# DATA 0VD21kbFQyEwqdiWlHu9TgzRZ/oc3rx7Z/Putqe2jXCW8HYXTQ5fjqr7ztm8EYdgOXdhskBfh8eYO0XmJf1e8E0JmjijqR2ilhcc
# DATA EZK4b7PEE4fKxQyKXj5IJ8U7ugVZaR7kBdlKd/diTTles1xPFHTMb2lX/3DrhUkhFBB0vwuSott1Rei5hN/uElL3nqfuxXei7sZr
# DATA BD4JrTy0ptLEnuwIeeAIQpTMXUlCl1Zejh+IAGSwIJl78mQyFYmlUPUBb/u02bRaA3duJ/eQzHxhGbkmzj/qpo2SBgMj0biLnjOe
# DATA UrfsHGBcSXErglnHBXfVfQ68SviW2FDcbLm8u7znOJ8LKN1uHS5/4Kn4qir3avqqRUc/GfdRNKCCS3Zql7Y8xoGUsGRFRFbSrne6
# DATA +lMorwTauu4Cu0pDtOISq1dSm63Au+8neK0sYU1yjYQfdobt9DtpeW7G4l4O7Zmjbi7XVbt7EYWFFANlFE6qOgdRl/YdUT5hRCO+
# DATA ayyXcfKtubadtJisJFtHaRYZGk8X7IEhR9oz4dG1565vSKNiCK0wDReaJKzk6HI5Eo+qYAeH/aMLiySTdVrno8zUVyN7ZAChO51h
# DATA 050SkpRbTvUxA+wUfm75lbim2bClwwS0r6iAhjbrUTcJmQcqs6u+2DOeSnYWHed8l698JerCOY91JkVpjLSJqNdgyfkoQ30g67hr
# DATA nD6hvBCnC87J7JCH1RpVJ+AIOkmDKBgBcWI/BV0tJujy2kTyqFEVxA+Eowo+JPGF/fSkk+fo7+NsprMUB6tEOB60uqhQ6KJ6xD07
# DATA zh5JA5Ldk8p32hPZh8buwGErhOnRwBAARtKCmxDfNfDiZG4L5o4aXpqdu0rB7uawAn0lM4lKCNmscQ5GYfNPGkS4960JpBYCnYst
# DATA zGEllrk6z0b8EK9JsgToJDVAyJMtWYNJTNtC3+6GpfegOurQrlnHvfklxrdXN95aizF2s6OkceozpdHynoXU54i7J/024Mq1jfz/
# DATA 0ux0Giv1cv+xOLtQ5BgzhTm+pFRrdVa+jhLSTEn3XEzaF4Wn8eIYP5a7Y4FIXdz14pOyeCy1QX9QUs37oUKB1Bz19gvrw4NC5JDC
# DATA 8jp1nO+ARJUE37FPAV4Y2+OTQa5d3rJeDs5Erfyg0yHFdwUTufdGjRVJmT2H2yI3gMwc5n8/TQMHhdhBinvgFfcmQdKLFvQsUZnt
# DATA f9BYwTIWUh930K5svI9BOVhbsPa0673iQGZqShra8MdfL0yjJM1HXmpA3G/4R4fhgEsuL436J+hUbNXAjQuq0CfyK3RjDhsV3qbv
# DATA zs53/o1fSs9zsOiUW6JQpAf5IusH1R0yloOjCgMDMzk6x18uleE0dzpC9biaO3r29VS6XC+lSwAVcWOp/xrAjlCKiJw0QgWONSbx
# DATA 1Umr1zkEKYRTYhkPw12ne9EsV5LBCB+aRPacQwtzLtp6kOi55fnxmsxZniRmVVS2Raa5GpkEAjv2tqKPuaw3PkGw05IQjZm6PS9l
# DATA 1whdoC3FR6hdNw2UzKFbjjcUEVkt8omZAHFlgY6sccc36HlkEavRgvksaCNOWaU4TTBSONceaBQWptduJnP2l7xUkqbN1VuKEaOV
# DATA Z2v4J8QBBmso1DEEN/Rcyc1c53mXilCZLM5VL5IVvJmfftCjLXfcI1X/wvkP9tjczr04xrhqMVV9Dbjg3Bf+/wEx7vj/nXSOGN/v
# DATA G3UBnO7/d2n50mtXfPyX5ZUr/+n/95f433deWRznw8X9Tm8RgiYGp6Pjfu8SRIndHYyqik1w8lcIHW31DFxmgEvqQEcCFqfnFcju
# DATA dK3hEfrbLWivwMEpeeOBJgN2rnjiyW8K5P07uA1+bTfAAD4GUiAIkgx4+c32C7S9CBdeOtNVFIqmndGUqhPNxPgTp+u29hXbC5EQ
# DATA bv6/7b17cyPXdS+av/kpWiPrNDADgI95SIaMyBwSGjGeIRmSI1kBERQINElYIICggZmhR7xlScmNU3bZdVL3j1unKknl3lPn77Es
# DATA WSPJkr8C+Y3OXo/97N2NBoejODmaxCLQ2L2fa6+99nr8FgMga1XafSxpxXyZVluqSFmNKxSwJG+FMu9LBbyyxUK2xKsEtCABy+DX
# DATA 3NUYr+q78IxXZaiEfjVhSzZ10BzfbwyxBkH/FhjJcXuMeCQrCo8En5iQJOIBnIk6v5m80soh2zfcdHuAQm8wU+pY2XR4OK5tdzYe
# DATA BbddTG9cGpxyLjLdSMnqxHAabLco2VOvbMJsABLfaDKlCZueZ8yKtPt0DGVazVCrcZdqKisYD7bGf0u+mDtlnK+xOg6DqR6KnVmD
# DATA XWjeYIoSJ0eG07T7PSEmxXqjuUFnMUdUYuDlpcFS6LGKpZXhFC+0naUWFjMWoa5a+o9S9iIZ7aDvOtcLcjSMGEKDl8ZOiIVySqxv
# DATA 7gLIilEkiYeThcVSmj2yd9gpltMUaijZOfgDvdVUt3+pWqYcbuS0bjlFW7eaq3BBTgU9eeqAnpx9t6AnORwJ6VlBd71kOyszUZW0
# DATA qzSYBG/duukMuKb9rnGq3lgqpltPVAqkFG5B60cJ8iZDSmlcwP8aJAUKs0diBoBR27u1xGHc2bg5Je/v2Ar1nMMdajYh2VvEF/CJ
# DATA RKlYpwyaSLFUa+MQR1zUgqdWe6JzGJ1G+5qD3WSYLQcfiBbf3tna3GvVN9flMzbxPsJ+Qj74M7dHA24y0SdlIwORrmVECaL94fJs
# DATA cMEJOowjnu9LcFRAmxeSGQblF6x+UjOvBuvIMiQmWsy+X+3OeBjHAWYoUMHeKoRtMkTA8w76VmLSR67sZwDDDz/JVzjWljAIxHMK
# DATA gjmIQPAlX84u4aO3Tw56R9PhNOa4XI6ijdmTGd6SGkpzMiBAHn/A8sazGtMjBbz7L8cMyV8wYvELRj1zr1naP+wfUlODnBjcg5Xj
# DATA jOWhSjYT3SnPuvmsLCrwWG94SctqdjM21qEflcB2vVajYB7qjoS5jz8mNKH+1rtMLJdCvlKNAOsC0KxH6dhdXtatNqY1RvYslXDq
# DATA cYJTxgarrJFNmvD+W5AGwPK7F7tl2p9oJWAcEbCi6KY2Umv0OjKjcStmZj7ABc0h2Gxg6kJL6vwxgmmrqoaPB2jwwyorYy5UJZea
# DATA pSYlkDzujCu94WJ/OAE/6kUdLpyAg7GcXIxJIFKGtmas7DgSAkiP71F2pxapU+Vl5flTtceCmjT1uhIRkp20Qp6TP5/Npj6oPP/5
# DATA iW5j+ourZ9ZLPJPuJ9EJOKj57rBOBHkhAT4g8QjkvVE9UIHzFEgObSSNw/IXWEhogacXCNh1MwTVabeLh6Kzy4D4pVoVarM8Htgb
# DATA g0phNHOtL/hPt40NV+WIMrpfVF7gBBUCwcZC7IYEmiiN1AzcDfHV3ZPiUaFx3XipSYawGsWOd9ojyCLWGk4no6l8OCHcqdryG0uK
# DATA afI4aVigCNUTZOQs5Rh/En+tOwU0bdjagIZlDqYgHOEtkjEy4eMU5V8GQoknQ/qKcCgSDAUhXs7A7sLQKYa3KSWeQd8v7DWlfcR4
# DATA JwOIJ2rHBNxfsBMehZDfbdo5DowbA2SavPjF+aeAkxScf3vx8cVHmJ4Ssll+evEJJJsMzj+VqSpDB2oeXOg/GAhWERz22zhiRnD6
# DATA CFMEs9TBL0voJwRm+gyb/cP5c4BvolacDJfJtiBTCLjfDAH2ZNCLutigAQ8VnH8h3v8T5s38JwAxT9ax1h4wxCiAGEkZhzvabUcn
# DATA aB4L+QHCWZn4U5/76mQe0WZXJ0PVg+9/hTmVf4EZPT8GtCsxM/5EouIHz0QXnZVV1Ih2WSBGylBI9E+GDKIAQZb0k7oO9waSiOQj
# DATA IDSG4zLBt+QEPE/r6m8Ck3TOn4Vu8lF5oUimry0chuf/g1JLi+n47PyZbK3wVG25syKTyxeI8AUd+yWmoH4GwPgl6tVnwdPE9j2r
# DATA wkMY/1klMPNby1T3n4o/n+LLgAwGmVQvPradcfXmEsxCcyl0EgGGUyCMHlSxmK5ZiViQJKSM46zlCwoBQ29Sg4f16XLtQefYvjHy
# DATA bMPqFmB6n2E6WkjZ/fvZ6GgphG6p0Bquv8zI6pKMe7a5I+nBMGgN58IOICk2zVlQRaUOTYY2wg+FomWqS6jX7OH/v1Y+3S8VB3qh
# DATA iWDqUJBWpUAOh9GsaN+XWYXj1Xs6p6LDSoxKNNGQAl3rYcVxB+m/cToQ6ElOB0FcjtGVtRGWD/lN+K3YbEqsELZeUJxSi6yBDI2F
# DATA ykJ+RAbeFnkhqvTanOvUdz6LxvpRNKoRMjd81ChW5ibRhgdflgWIpNPfFlKBqnXveSORrMVhSmblD6QFT8crJUO0YIclNitKT1xW
# DATA rZguqR5VLYnPpfHM4ClMnVJLMpfiQlqQjS0tEcEwBFp4nUhSCh/l8mBYRtXACNMVqGcAEYZ8CPO50uNDcE3EM4s9RGCFQexyjRWO
# DATA GLfg+OZZrtlO6A3edVL37D+Lnfo73px0SNq71ZPQJI/AsmBi4iMX1WRerFCuAzhNbTT8WRDzllcsWOwqXUHx8IG92oquytwDoMYf
# DATA m1bRBqewb8orlfUruvqFB9NeH4Qf7e6n354TDszW4LmAYLMh2nTDpKWWbToV9y2lPdTcG1bUtU6qsMuQbUzU77kFni1Y7lu4kAaP
# DATA KiY9txDeEnTT0myKmQel5bQynXRwyQ/hSSF87f3XTl7r7r32zmsPXtv9G/Jt83p9NapvsKJpDtcsRHwIpEcYOGRRFCruNZpHdqmg
# DATA 2SMBwwhi9c5JKbCg9atyE0JUshnMWQ0UqZ0tJD1CsHMl1YPiQpYjGfWbSF86k+V7U5or7HfpG/M7qbWxZko9NWbLbsNInmduvsft
# DATA uDUmeE5RoVaBSVxPI1eCupi3MFTBYbJ0iyuX23RBK5f/btrD9LlqviWzdIOazHo149Md8DB2CzFT3xzNmgzmbGpU7PFaCKOpsKUc
# DATA kMHWicEjAhHTPuVGEgndf+XG3i0ZKQ8MXFgp5CZ2KZv7TXxL1hq0qo7zstkZE3I2iZVpdsdBy0zxi0whGNuNSlebZj3x4MP6TCCO
# DATA w6qs1VXEeBl4w1tj04wl6IrpHvXbHcHEADAp/MEPHG+/XGNP6ZqZ/8oER/bMOelSFTYyr6uhoKmmq3q0oEF2Glr56ky3VmOuHL6i
# DATA KvFgmCS22gxJPqHKSpHTPUo8LYbrJKHNmXKb5C9yahLzACPoTVrcacnBjaWlKUpK7kXfyprwgc68oWFDlHrkFVNLtlCO3SgmLnmq
# DATA oleD3clwNEKUtCOJRBvTo0qwGkjmhYm0erHoM2eXRcuSuIsHCFor3anEDD5BE/D63UpibanTSuOGcm83kpxcfJEylAeG+LqgjHKX
# DATA AohNpop61ga9jh43cIFLHgLmdjdeT/qdtlBXA0E/hTtLRX/AtudUUkO75LlkNXGlR5F75NGMPU2GXx1H7T5Gb2efUu9gMfMJFJnG
# DATA fnfmfCceGRK5A6CuJb4V0pNT156QVn+a+QYdtsnkA3hx6cdG4sDQAjbWgVx1tlMvX57+RWlW4RrEulUE1wclxzeg3CPt17d8x/oC
# DATA VXu58knOUJmEflvlgdi6H/iWSa59TezNgZx1DMjLXD+58qRi74p7GynLBR/qpi2aM0n/PvM6qXMTXPwSdI2BqRk9/+rik+D893Dn
# DATA xEeci8A7A6gAKazkQVv3qK4+Rq3x1+ffgrYSFMd/BJXxt6gu/4wH8Nu5ViZFM5GDffvP4Fa/fQoZPEg5c/U6FeYc16/Lu4U+ot/m
# DATA wBXfkM5soSYpOphaL/xs+eWkxAnIKhiKVh27dMjmP1I1Kq8dtONcN/4DTyzy9idFIVwtCwpyaxxj5iDprFxZHR9NgZ1t4y8FaeQU
# DATA Y6+1WuLYaLWKxptgYmy1+ZVCqLT8BPMP6pAakEncGXIigFiIK9JihvpKKUeQ1jPqd0nLSWFbJD6xWRa+kdWPbGys+SKsGzTHSTs7
# DATA sthQBTiV4YoCX2VOGLQ8o9iE9jlMwDId902Nn3d4ZVQcYC8zJqFcxrAZiP47HUU1lTAMDYo1+Q7+gbdifauEbxXDOCk4qZq7NJmZ
# DATA 3sFpKZnuERYHwELk9CVOc0e6wx8N67ftN4EULa9R/j7ymhpyOC29y4fwVVouS5bC5zhnKkCSjQVL4H9r/PwjdM3l6l3vkcTB6Rro
# DATA 6KD8Bg1Ugu3PxWe9ymoakOY2qmCqphokI+p9Qw+rmbW0nHzR5GnWaSPV/mZhqpoudPiZb3L42TIA4BN1l8BvyhSglPyaelpil4B5
# DATA XyxaC+0erRZSQKsFTKXVCj2up8RuUr0kVWaOn0Sns/NygBkhctBfx+BmFJ7/Gx7ln9PpndMgZFkhwa78ZuAxmbLKuUSGUc5RhGm1
# DATA 4UT/9uK30AhURgZVOOS/hNqh/UogKPEZ9wYSI2HTn+K7H6ElD2U4IROgSFcKxGsfUaIl0JX/o5EzHHv2HGgXbVnYJiDQwm2zBuEZ
# DATA 5DRgkOIppUQqLP/XCOC6yvgvvKheOfx7dvzX8tLt5Vt3XPz3lZvL38d//cfGf+1omHdM1BGNCYGDtPuJ+K/4TXE4CWZ50JtAKi7p
# DATA 5MDSXpwvBiyJGi+zJ7bYP8GPFH/5iDDMvvhnHx82lxkZ++iP69RY/Fq3pRK7lQznPVNqKlle8Cwv9wCwojc5JQNu1YJ8tmPcC+H+
# DATA Ulj52RAc6CF6Gi4yH0ifdvJoN9WKoeFQJO2uxaJGNrLi5BvVlVtNhSvdGY4BQVXDAGEQuvZopbRuBhyCwldNWJviUIqf9FImAKmZ
# DATA EYZxDXbq9zZ293beD218JxPZieo96g8PCuF1ie1qeSZLjxBPw/M0bngMWIKaHTwu24Nkk6jV8SxwnrS596D9ta2d9WRCZqgpE4pW
# DATA rVnSEZPc5T1LZ0DjLqhxwCPtSiOd7NVzz4R6RVkjIiSJuWvSzDYpw2RDs0F3EyP1ZhQnV+DH7UdR2WsPJbgOKAhA+7zFvB18KNgT
# DATA 5Alqop0btn97QHhdcJU5yzNGLbC/0ECzrwKcG2LQ+zuEkDKwXpGCIRAAKjMkfSxq5i2yCZfsFBaKJb3ih7E0aXpvawvgK99Hot61
# DATA 3aKoDhm3y9dRG4MMj9B2t4w+5trFengYkA8p6f1P0DbA3FuGoYgLX/Sk3ZEUK5PWERt2AMGzNoIi+pbjXIbsyHzu420cZnhmtJ2+
# DATA S2ywUKO0hzp08zMhrNO6Y12mJG9gpT3sJaN6a0clmjVdCkrGhguLZwn+hS97ozMMpX+vGxvWC8uokGLBkPEPRTtAYSAoOabUG3dk
# DATA OLMnj327fAhBw0+XV0p3bp2FfsdEqCkvC1/b2txb3dis7wBmZ31zb8s+SBQhz2NEuQ4dIBd+MT2kp9MXfDEfw8eE7aYXYDGF42Ew
# DATA aG+4mFnQpx9XsSIzmpgnpOQsGRWL8gYyK4trGfEWKVYOfTrOESzjCYsBL32aUEOFIuMIDELV+ihjKXLF+HjhgYwqK5DbThBDMi6p
# DATA oaprmjGcjuHAoxCRepBiDqBnc965R8nziFzLVMB46EOT846RnRhTPJ4XfHA26GHCXgDwh8X8+MwLLKg3rUfl77f8mClTnNhkD451
# DATA ModKNhoPp8YTh43KQuMdpUQjbZDB4Tq2w0NNiVb0OlnTTKWMI5FKNNWAmTjaFKQD5tkBIJM4a+ip4jXKuA5wmdP2MK7IXKjhwFQC
# DATA JyEIMS8LS97tSaGYhZWYN2VKwZczxYw1pZkh33t4nCi/vLS0VCxmwydmT9DWe+II8edK9nn/5shNXMwJ8k7MrmHLgU3L1ZDDdIVA
# DATA gA5hZ66UQVUszEyWnEs965NhFhbu1++trpFsSWnOd1/y+Zf3CJQYCmzvwEBdFFMtIAUeSkp2OZ3ZNcdplZwJCRA8HY3wsjyjE2k9
# DATA pa2Q2kMbsHZmT+cNNy0qLIqjyFDWtMaREPvgriBdI6rSHVE6TWR74BWT0r3GC1D+YTMgCtID/x3fMWXjxWgvMCfjmZnVlnbtMOAQ
# DATA MjLV5YhwVgqslmnMI8xoKVFweLOGlzHDMAxPnbS0aDkQeFxUppyCtAbT0UFOKlWxHepUTCbK8RRQR1oeVZR7XL3oBeUlX04uczG5
# DATA 6kuJGwp/qP11LGHe2Cjks2b69Gx0DQyrNOAnzxSJqnJgDNjkrL+94vTCD8+jZYGkg86s7qk9QC33uiYel/61mC9S3cvj8/meXSIi
# DATA 3eSgjmISDwt7f6bI+DDHzqbM05VZN47EbWOOm0b+W4bl591I5qOZ8/aRvHnAnBpfHX5GeQXoNuEH3L7MVcLwDldaxnFh5uXCuXfm
# DATA uFq84LXiUleKvNeJnFeJq7tGZF4OruCOMf/9IsXvT5PHQs6bSP5biAclxESS0FcOzH/h6qa1I5f4UbDSNMEdfN+ibrymxDFUZc6Q
# DATA K8+uFsKipKZXdlmjWpB8FrkimYq1TYbUkuCqu29Ka1ozlUvuc3BGWD6R/lCYfzRLvEBqerBxb2d1b2Nrs7W79XBnrR5agbbSO4nD
# DATA j0YEcaOZulhbXZ4euetlcvsRpNkgWCjLaImnG1Su9ehc0jYL8sMEpb9Sy8G1UyYAt5NK//ZgY/fB6t7aO0kLIujWuX3Bl5G46YCR
# DATA Lle0OoQIm3/13QclY+mhjVoCkgVakPdEdLVj64tsG3WgLW2asbCOkhnd6CUzNXqKILSCUhCuUh6hlW616zY9zVh1Ul7GOoeBO5Zq
# DATA QsZxLFDZdc7cDZC4jYzI9Z36epiOW5rn0uQi4eSZtd36zrsbahe+igJFHIjzH81eZUKGkpYvOs1jiIMTUxAcjIePY1Rej6aTuLKQ
# DATA kGwansil676N00ykk/RpWGdnpr6ECd8VCFLOKqmFEQ9kzjwGaG4JmRyIgLZEEmk1DcTDuGjqkeREttUZ9xq8n7CnLFjJ7wTZYm4A
# DATA zhWwkJRU0nBFjEmuOTljXdd6AM2jL03zeOC+YlrnLIpcfXB3497DrYe7tCR7qzv36nvhfDkCjbHrRIFLMhA+wbucXFsoOFAVIYbo
# DATA VT0hesoTQFuR+BHe/c6Uj8wUBGEhCnB7g+nJgVJnoMUa+UjAwGiMwQatv6lgRSQi+CgaA45CjJhCiDiGmxKj2EBjpMzW4HGE2baV
# DATA SI494LZzayX+kygjLEvgVWgjjG2VsCsajTGTzxUQBjNkgrJVhKwqAbUnnZFRClbtAPJlDo40bO+2WD5x/8a9BYsLPeJC0Cn+GDN0
# DATA sGWYE42VdAHw/tKdzgCnhBZNCFDOLtKUgJ+9w8MI1TMb27r2Ewi4BLDOoI39rASbeEIIcQ7ouD0w3BUhR2gEcIVeJuHIkM7+1tqX
# DATA xPaeiYpnaCDSG5ilPpACqXW7YC7CZ6QjdBg/oodnTZVMig66mNlD49VUHsYVPFU+j6wTUA6PzubTtSZCnTDpXTLwLO2aPxOQSukA
# DATA Zms9zq5GgH412BN8Ui0IbDBy8pF8VS4fnFePImS94/i4NwLE2gHBHcmLVpfxJxOWJd9pYc6q98zQBXwnR06sr6TxwJPhHeIo2hDP
# DATA 25oMkVoMUshpJtCb4hJIowspOJ7K9sPGnopr/VHJ3/0p6dMS2tfIT8t4Mhw7tkrVl1fmtC+5VTlytkYETwcZTfEsLBazeJ1XEGWG
# DATA Kam7CNmFL+FdR5TngdyfBYzPD22YnWRmMzOrBFEwPTajQ+lRgf5QdlTqlZkr2Y5JyuNPDJA9yKchbxR5+5q+iS8g7ulRSDFPOsIZ
# DATA rrvmGSUlkeRaZoXZu/c4F/2FgSaplYxtm9MK8kKmNm70ElH+BDLDFnC6SplOna5lSHqYJw/X5KUncUlPpCmV0iw8T2yhZJg5+dUa
# DATA rq/GpSulD/SKr2EthknniBKaZD2+vLOOfOklajibJYwbGorBIlYbJYbr8WLPGBJu4iVUrRlOnunICphaVxfkx+AhIjMf26PnM8fb
# DATA o9knz0x/klxeJHqUJdWhcDpoP2r3+u0DAlkJ0/TRV3KdTFdTU78weSJ1MOTgbPHoYDjsm/7p6kqSUR9FL1dpnI2quOA1Hf91rFV3
# DATA U/+UVa32/0kl+zMPSKq6Rbe7pwwJo0CWVySmCYA1cM5dPCJOhoLfDQe9Dmbl5vIE2XUMgJaJQj9SVfhAtPzbZe6tYvv527dDx7N/
# DATA J0IDr/49uWGKWtoY69JASDZyReL9jJ0JtTloJV5o/JQhWfUk+2Hv+4xu2MgdWexYY4FKKIxM9erq+vvKR4hPVUuBrcLJtc5aR5hr
# DATA 4Q5xDkx47ch4JLlZfyiu0/n11VvbdbKG2GrrfHp2jfZg9Vj2NqVHFLCcJZkA6oMtnDgSSdNuEIPwqT2JDIGNYgXisEfxZnlpSSFO
# DATA dIb94dhTrWknNkguq6+qFwxWodAtPH2UCyZ1PsWkqJWczVdqvOKmoCW5kqQqFXRhntKGqm8ibiyk6QMNnlxdBW6KRtsJhKIAumJv
# DATA IsqxOhCgqMCEGI1A44OZS6Wyb5Z88GeLAWtDv2oMUx+qq2lU8Vy5ZOGZdhY2c4C2YHdj856Eb0XNvdL3maTI6q4tjGMEy1W33Qcj
# DATA EYufYBpERElcJw5riSuB1OpOjtsTQ68AS881YswoUAGpJI5AFYZ6hsnjYVkShM7oKG0tbZkMB0miwriW3e4pQjWn6grgrrQmi5Go
# DATA InrVIoizGoBgit9CKa/SClhDolA2dSm3gwsNEYCOm0hluI+Rnz9NWLa5RdtVBt2bZC894YTWb1oVQNvGEZvMK7XYT7TRau4lVFwN
# DATA g6f7A9rNmJ2X5yRxn6zeXFpe2h+cmVnHT4biUkrJlWiwDR5Wk7rySJD/iTV3uCFBcc8Jikxf2RJm62NXXqoAkFv4RAQda5iagIjL
# DATA MwgNvkGggDxhdq1I7lzvYjTpLGK5RU0gpKIDcqAhFs0UMYpq9GdwXaFh2Uuo4Y8xmFjwrppMAwyNy3XR7FbVKJf8SohMUwLvdCmc
# DATA cwGNfAN2jLZOKScZg2yP/JaJzCKoIW5RuvOzopMli9+0LjOYG6l9Ir2hTMblyd6dwsHeWd1trde365vr9c09yc+kNicHZHRahnrK
# DATA TW9EDZb9aMf+LPVzYBWru+ocMMQu3HBTR6nicumlqhra3zofo5AjbNruMzoWHeeADSm491DcOcUF7k32WJKnZCBmyPRXf9XO4BGw
# DATA BBGcQKYyUq7EcA0QjLw9CIxJxHNYK40Vn4BeN/EGeKicphpGHiJzHWDWoZpmajVSoIFawsEwnB9hWcP6ZL+Wv/xsOObUN21AZhty
# DATA jc7d1JDcfGrAS8T2ksN/u9+iDrgRuUa3imTBUd+Vh6KTR0nVqALtU0J8dXhvVnX6vvoUqKJqxubyPtNBuVDirOjbP2fsDwaooV0L
# DATA 1vo/HuI2lURyQ95qdoy5BB2ok4KBXuQH9XJwcVN2RwYpS9xcTBoaqgzeUYsdtVzkPrUOKlaDPL+67UmUIEJvd3z+ZCbf1YCHXGvC
# DATA GJdYdK8WOzn9fD++njgK56yH0lfh9QFDxpMV8smdg+LNdGse6i/mMjzu1B9sibs7ahXWtjbf3th5UHfAN+zNXXVcx2m/22e0/Yaj
# DATA BD30y0E+73DMVplAymhaW1nJr9K2yWkuMyEo3B6pl1H8loZw+ZRzZx5FKX0k43rOpozOadZQTAcANcpLllPMTKziTF/Cnzlla3hj
# DATA ZVXWWEtoAdBI5z4VCrl43FYPiqlxtVyjh5SSfYfstSBLIGGbFG78DAahpJDb9M466D2yiDl5kOujir1O07BSjTOyZHAlE7iCwFIU
# DATA giZqueU5IPXFrN734KpC0A4xUD83n4W36t3LJguZZypm7G9XvpijFWsenXpcgOAU0cTThFFqOqCLdiJ2gy4zNnoBBxIlDF7eSKrM
# DATA UfJIOd8EWh0cG3W6z5U/EmOmYmt+aNzMkAwTNjcbMhdm0oXJNUMJNNUriwjoErs5nU7l0W9wymoi7ZdijFX5tg2NlAbGoSXinNK4
# DATA 7TXlyuWKRF8QAcz0+U+K6kW7HVY0mXjy0utdVmPEAfgQdhTklVXGVFpoed10DaVsUWbUcdpalphTa4XydjuO2XFUEgSDBeKFpyO+
# DATA w0yL76jPQTzBjjQOxGIZdDZtpU7O8E9OxNQmPHJy+WUU511Y1zVbZttim6sV3JFvV8j478B0ZRbdhujv0A0FIcexwSNNJ9YRw79Y
# DATA 8wDPKCIM4q/i3s+j4C+DO7dv37wzjzd6ffNdQxbSTqngydEDRXS/MA7/1hMGXisYoQHl5o39Svb34g8oo0mWvg5iSSoPEohJymGz
# DATA ZjlsmsvkOGjahxdlTCO6lvnA1h7u7rV2H97dXdvZ2MYQoZ36w906jw3UIVS1YBz7A2XRe7FwGLJ7OiEwZjw7xyVZMrtdvKilYvko
# DATA md75P62ZJodqkZbRn4vOa1fJsrEzxIQG0jQvMJkTbe1OtFQYJno3YLwoY7joQqJD7djb1/X5o+DXF4uiznfLTAmQS5mbJCIHd6Yh
# DATA O9JscAeaDgSlvROsMKicSBozRiLuyJv1Nd7If/1wY8e9Laf1IeF8AEvTzQPWYev7585aSK95cxZmCnxa8rv+VFy1qqrPePHyJNKy
# DATA b4wp6CHeHC5nZxk51VIXFZI559g4CecxOVlC4IjGkxbz2hYz1jgZmUzsovQCyQZda076xCfMAy6zOUu+nDwSGkxATSMXj/IQcJ3J
# DATA 5Hw8pIl4l2pDovdgwyeTVnve482yvvXeptj46/XW3ftbaz+pr4vZEicdCOtYK/jPg+kYvyy4dO7L7al/T8vumUIxSbrQafXk4e6+
# DATA 5ymamcKPjkFdmA+CYnqGuLk8AVEaM3czTVCx5A5FddNIMccH7GVyBqbV7sscSTdbHhTaT/Mlmspjz/szsuFl7+4cm/hlWLUub6Wa
# DATA 2x6WZdV6SVkJX4WzmDKexpFYRfGhf/omXvqMcCIZDRNHEJ9Nvw77fWgvIIeCysJ/epuPz6J1dbbEq7cOXtI6eTW2ROv4v3LbV/Lo
# DATA vX698DR0TWESKXvW6YQsMynU6CsXOGfMsqjlz1Z5edvbJewKmZayl57Hy+sUOSvxpOkUOZ/9an672IuYa3IbLZJZ9TLU78mQiqQB
# DATA wbKX2b9lGeC4cmVYw3ryv55mLJxrwlNMjAac/AsYzy5nRpKZArkVJ+NyZt69q7APXTYn3/e2pQzb0nedsDCV0Zn5ComupmNbw+gI
# DATA +jr2LwXFk0ql4vdw+IX0DnG1lAW3uaKOPzTczn22g+SNBMEglI6UXGJr5JQyfHJaCyWwSTgbuSQnXAnjUvgwKRau6s6Ya+o5JNIy
# DATA ZNgwMjmijoER2/NQaQ86x8PxbCfO9Y2d+hogWKAPSf3B9t77Oo6yJ+EB5rBlWFYZJdVJSAljMELkR4C4ogHKiu28QJ/RVgJOuypG
# DATA RpGO8sHNFwqzs/VTo1IiSSO8XcYq+wOH7b7UtFe7HKlbX9pAtx6sbiRUlWi3zo/gSpr0Xn9C96Q+xE7XRAUVxpOWF09eRbRqyBWV
# DATA cb5oUTOWiIFHk7cw8jPH7vTjq+5F5spJ9AWxcn8lqKNV/+nG7t5umNiKpLphVpOueiH2Z+ldeofW8JNUbnr8ruqYmnHEPDFojzvH
# DATA vUcR32y5LnS7DYaDTvSmTEBvqNNeDaYDBE6IdIs9yBrTHnAcRgTGFEocczCGba+dfLm9NJWM6ticLtZG1bl0NAm2kA2S4DwBtmdC
# DATA R3iquSyylotUgeeEnLRFeYWfWs5gunz20EsEx9UafmDMhH65cyxeLOB7xQwMcCuVmyjCR4fW33sU9bXjyWRUXdRA79WbSxTq5isM
# DATA yyy3QWWsYYJ9OqSkhbpk9tsCpHlqx+8a0YlV8KwSNB+XwS9zFFFwphBTUX1SDRqWO4hqqugo3sMR4gKJ8ofh8srrlSXxf8vVp/D0
# DATA DENkXE09MR1446kDFkHiVnk87Ke5l7g1DY+OKLD5adgd9zAdMRkpy1IHNBxJ/eHT8KT9pAymdyi0vHRCOsgnZR5veDM8cxugmNPO
# DATA cdT5AGuYiLmDoYZrD9ZRuhRUhzwV/3sYAZLCNV53PRkwC4tobBWy8iLVea1YEdxnUBjX/lKGm2NK1HFl+MFbS9XlYrHSQWCGQtEp
# DATA IX5i5ARRoZBooOu3kclzYLN+IHgbcCnxYHmFglHHk9YoGveG4EkXrizF4dlZ2uEKM96QiyWucTOBPeBqRx9tC/VTGeSecCKiZUmu
# DATA M0XH667xceD2jR/LYAmGYFCpsy21CdmfrTeeqjdEL87UW9AlyJ4Di6X9DXkIXIHumitbpClrrY2k46qkmH25uLNiYoCGgV1GnllM
# DATA gB5WV4R0MuoNojAHP1C2TpiYe1vr9bsP70HhEzFzPbiyTTqj2lKIEyhZQfjGUvUN5HW3bt2siv8ZHxen3RESsAyG87EaPUPoDlb1
# DATA BaVVx0MlTpYhAra6CP/Vz2hSqousArYc12m6ZBdoknRNkiLMevDZ2Sx2THJUWcpR4p7gavZfjuedw7hs1+Iq4qgUkkTiWK/dAIDk
# DATA uniGV7TQKujD2Qsg9KQ6A5rKtEw9aKrKP4fytDtbmSDvZbZa06uDym0OO3ODmghU1EaTY6BnzFte5UN+HCOekMznW1kdH01ht27j
# DATA LwWJege6glZLrF6rVTTerAj6brX5lUKogtuBZglwudYIlSq9rBGgCZ8FPftDQvGZ8H2HlRja9DIdR4oll6fjPv/CF4EyYJLj4QUS
# DATA lTq2lSsl3lIEvTByBF4iyxyvisxrGkdl4Dv6G9VEYpELdyBPQR9cQzNjZsplIF9RGgJwa9uo/ZK+L4ZgafrX275DIQrzCBqYmmvX
# DATA miJ7PvSI5Vh7J3YGUqrqCdbJBhUaHNlOTJwH/wBBAtVex+KXGK35WBb/QOlYg03Bt4qNo+ClFBdgAh3WutOTUVzwYotjvaTcwI8G
# DATA lDl+N/lkNIgFebXacafXY3RpFuP7WT2MQkvni/Z2LEz6NbEC6AWmn5NPLsZNX4GDk7ySmvarWuD0oGQrusANE5VWbn+Kai3Uq47x
# DATA Tk+9xIifNcV8VcDPyjhHL6X6S3oGNWMtcFtnUIfE/lK9vcyCuzwjoz0Xt9mdJUPVRvPNepFL9MpgWxkdMqCC3b7Aw8s3rDmkiV3i
# DATA dz7POQv8zSDMzH5I7u6OXqqt52vV2DSof3W7YrgxKy2WMZGg7Ajxquqhf5bPoUioGyeIA0Mjnj1ceSgaSZNZ159YWPTX7ObdiNnN
# DATA 6gO46oi+YLXIbnp+RjSrK9aJn8DPV37QKd0qpu8T8qykrPYQzma5UHoP2+LZJfaOPp6TmEkJk0RyFGo6pXWisdTMbtAQAdKulQa5
# DATA S5f5q1gtLX65Q9WARmnrJGs2jeQSXCub5DTclhB1RcdaaDFqtbBLrRbsw1aLewRrHPeOBlPEVCzAx3a/srtxb6++86AU6O/vPNw2
# DATA c8zTc/pToApKAWdhud4SN7FTrWZJur6Q7L1wab9PEhd2T2NBq3VoRXtxgnJl+CgajaPD3pMM108bpdfK0KvwDHPlxPR0T1yFY0yG
# DATA 7gI9p0s1okfn/xyc/+niF+efn//h/Bvx3y+Di48uPhYPnomvzy/+7/PPA3h+8bEodv7t+WfnX51/ffGbi38UReH33wbnX8Evz/Dl
# DATA r8+fV4Lz/1+UeSaqe37xMbz97PwzqP/iI6tcAP8PDT8///T8mSj5zcWvoPG/F0W+PP86WN3eKIun34q6oKVnb0K/Prn4J6hIPP9U
# DATA fP6N+PZM9MDp8DPssKj//IvzP+LLWEHFvWWT+nZ1ba2+u9t6e3XjPk/Iv4m6vhWd+lz8/QpqyzVubvRP+PKXojw1GpjVXfwaZ+Sd
# DATA vb3t3bKel1Igin+Lo/hEVPkNf/61eE6vfSQa/I1/9p7B7AXmRDnTcfErOYA/ia8fiVKwRP8iJo6KQWe/Ut235uziV4k5Q2/11tti
# DATA rloPIKznLtiKNt5d3avj1P3PlMXDAYp+/wG+ymX/BmZAPATKewbjJQMLDg46gY+MQS7dWVoSXf//ZLVyxvH7M9FxMeJEh6UtUncc
# DATA O+qQ6Lfnv7v4lVhbosF5yDLA7uGk4WT+kXv1Oxzv5+Lj8p3gJ727qR3ToQGefqVtnd+JD19APz8R5Z6X8Fds/msgzOfy+zOeRiTA
# DATA agCq7bi6yO6G0ZP2yaiPjoCJziGFctcsZvH/UAuiV4JUfw/EY/cMG/tczOYn2PBHojDWJdaNX/2al+vri18DpbsVII3+CUfy6/Mv
# DATA RDVf4ky0p5Oh2cuzdKYs2SB6T2kOLeSH838VNcMyPRNc4nmCcXh2Ci/mF0iBsBN/mbGtxcf/Hpz/QazJL5C2v8aV+EqU+kaQz/Pz
# DATA 3+Mv1PZvgJ2Jur7C5ZVUJrjar0SVogvwq/hNEOXHFTg0/uL7f3+m/yZ9IQidvtw2lsS/O7du4V/xz/m7snJr+Y58xs9fX1658xfB
# DATA 0ncxAVPQv4km/w9d/2vXrq1F4wmFYkcBOymBKM55ZbXxmxSM0eNgR1ripKMXhUlg0HbvBC+1UiUsv1NFpNCTz+ASJT8P4wWMIwKT
# DATA Tr93EPBjuGHIImNVmZYr1ZNT9VHw0RFcMhaoQhaRZYV0oS5Zhq0WPYxLAV5rWNMt7gODOO4XrsPtoIQgpxyWe9ju9eHyxpy6Fgpx
# DATA 5HNglILh/QKZomSI23VxGwD2Kxjv84u/Z5YL/JoZJgtlIDHg6fEtFBTHI8ltliD3HDmuaOJjqEqU+grP92ehi0xvSN1i8IVGyCMB
# DATA P0QYCyRyhNRoNRiSuLG1RxMYzXA6gYdkcVSo1rcNtxfEESfjQGfYzcoi58yQB0m7QhhX0plRU2Br1O6NC8fDeMJwHvqnEiUPMpcu
# DATA roXKH5C8r+SbbHQRb4NvWu8RRQjhjdWossg6G1GxgZiPlzrrVTvGHpzYOoiXKI7nEUVN4vdwf7A/3l8KZ+pp6daC0g8QCZ/TUsgU
# DATA ckWAEh1IkCBTswwpBBC8NDy/+AcgBpAyP8VXBJUk80yPDCQJGFUSAmB5aeVWcB3/zOzwvydpj+UDpmDVeZBDZOfF2MpS9kRx7rkp
# DATA XwrB45cgYQYPendVqr+dqN1FT6ggHrrsCJY++rspuMeAczi40E5jxqyVKMZgAAEaqigCaBGhizXGT+DFKZ6SfuLgFLT+RbXQ1lMK
# DATA ZmE+ED65vfRDtMgNhuDnAJ/QNyMaoF3ljTu30MEGGYVqVo5qS9Syu3tfRpvEQRczViGmaS9GTALwFZowbv6bYpuArkgs5ODn0Xgo
# DATA sxpQcAmXpx2rElYdhN1hFBO+gbltQukIOXMksHfEN7357LHkDDY2UXkSnNJLRiA2fgZsEajIEdB/D3sBaIuudc+yXTevon7FB2Ae
# DATA cJd7zoqCxYX0nKFBxPpNBu3aRp+rXKsXX6c51sq+CMNlCMR8umzCffdTOKWMGRXcQDx5hvegZ4kLSg5O+Z30ghNKkSwR94kEQHwA
# DATA q6AlP/B3OiJ/Lq1crwawThKGIQ4OhpPjYGd3FTdsfW19d/VNcUBxipwTcBHEX0+G3Wm/h5g5BrsaTQ/6vQ4gGieIQPwk2JhFDz5+
# DATA w8zMU9NIvi5+kvQ0akOqE7IBx3FV1in5pXY4Njr3Ss1pJHNX/ltCIaHPDTgOxDJ8K2Sfj1HY+VgqyFBr5xN6Lj6Rfphgs/VOlN4t
# DATA aF7vkquAM1eVbgSCTCGRykjUVcFisMitybAVi4KDblzABmVysBolB1tuQupJSRiVwfBxQdJGZTrpFCvwTfTiZFSYwbtQ3vsqQOXb
# DATA lzQLfM/3CX5wYf8nuLJ/QzrOZxf/iHqJjy5+a2dB8pyBKohkdDpb4DLMX2mylz5WLyfG8XJGYM+SGCJOUMdiCHXECg/JKJwbwen8
# DATA f9DUocj0e+xU7MheyFGU7GUIWUrfIyb4I0HDX6Nq5Msw0XWPT7DPC9h4IeEHDHMGdF0IIUdW51icOJVRdEJGpN4jSNgJX1lA6Xd1
# DATA PirTBwRrMUwolIdStroIP1uwJ3PlKT7/X6jx+hwP188tQQ8EQFueNUVCd07F63/Ey42aVZQTDXlWDFAipI8s+Yx6nYwa9thObHxA
# DATA ECDFBP1c7HmcJOIMzpjbk+FJr8NtuROn6rEMImwDyd+sGJobdpq1SgZiIdYVp0TNjWQgG2exskkvPZQ0MeyRM043Cs0ujI5JsrxM
# DATA hiQTnxKqICRF4gu62Ceg9BzBHq9h9B25ziMM8WHvSS2sTPpxOfSsJsIlD+PKYRc4f8FsJHx8EKJ1SbD0qH3iZs2CZ2y9TAzMKHHY
# DATA n8bHThggtBefDjoFWUaMYTAsGNHcw1j55NOiY5A77UuIVOwbQ0DuhhJj6loxj1aweXHhJJocD7slxkFwEPjMFOVUwIouk5nIjRsh
# DATA PEleCu/cfOOW52fgZ8F/C5aGS6+/nsVj1zd3zT5XBS8QR/kflMXDuPoBN93Y3FCMI0BDgTSYIFu4I+5UDuaYqUqqENIK+xtqSDGJ
# DATA oWa+SqwDTvrBUSFsdAdxc38Q3sBhGi4acr2iPmakhiQYyndVvKMc9aLxSW9CofeFp/BLq9MfTruH/TbY9Uc9Mn2HCBhA60auCKoQ
# DATA J/yhd486Q3qN31JLl/KqTAFB/aSEE24nohNOcuTpHIiBRiIKczRGtUoeMloCyU+VNpJtP0KfFDGjwOL4y5i/qPwdVEkFE07Myi9x
# DATA /s9AHMp6S1QkjouLfyAB/mu09uL58zu2gnzDFzpBg2WlPntG5kwoEjrIcCbcnxwrw/PkFin+BUn68/MvRGNgtvpIW+E+wQPP2AxW
# DATA +8zuLhNCZLFdqg1CdCs/G/YGhcPw6QdnYER/BF765I9SsqZfZveoIKwi5t5lXgMe54bUhhRUCiTbySEI+pRwNhWDKcz2gMRWjABQ
# DATA IzHoODSgISs39svNGz/WTyomeGTz6UoJEodibbPFlzSVLW0azdOPBWdAJ+eQAySot+EN/HsjxFgIpHo5EDNNLK52P9booPaZqytP
# DATA FJcfFx+1x4v93oFOBbwoHi9acmFaIUNWlHmCFBelpm/IlbqBASDhDfHajTAZB2KHkRl5h1xthzE2UXNM6uj82hPHUSy4UUOWcgO4
# DATA GFE3VlvM293yzMRJhieTedcwg2SkbzztEbjNjWWqH7ERsHados9DwjqPSrtzEpUbRLzNhkI8BaggrnA2r3GIVnAd9Hv4I9wTP0Zm
# DATA 90eL2XGfSCygzibjy7VGG0tkarTn2EyKB6IJ+jO8oj4PVtce1JW6N0bLtzjMRlFHXBDFIpLO5EnU2cWkNn83HYKTYwA6ky46PHYm
# DATA pJuJj6N+X/5O+hMhCLZHdIrhQHSM5P4+0NC++BcakZPX6OE189lr8Oy117iHBn1QciruMP8Ni4uSFm6EMojQTpAaNh4OehMha6wb
# DATA 4RA7kW1I27u/a96R9werh0KWqXHEV3kIImLEbnYBh0tza/uD99pwWnjLIm+yOsNxOaI/exBNIISk+Hgoyj180I4/qC0J6W5/oGa/
# DATA dk0wOprTG+G1fVAS8UF159atS0wQbp5c0yMnxpgUsa/EpLX7MKbGHtQk3toarLWFHN5tj2vXy+L/gqWbpeXb1aWlKvApa+g7grDE
# DATA ufnzqLse9dunu1GndvMOlNoGpXwMl4HaRJyxWP8GWTabNLtR9+5pDTsfq4l15sITH3Op0JhcUTESS4LCWUao0jPlDAV0gEEYgG9C
# DATA 6r3JsYrVHEtJ1nBYbRjxHKZWWnxlvaHl0EqnOkazUKY3K1YkZqhAFToGH3HQZq6LUTIU5IayxiV/lDItB0/WZGblZEmL80/HOCnu
# DATA W6C0GvnjSxyfVDXhhi+zq+1qV6R1uV2x9F3tCmq82nYkN/TJdIRN+CyPTi3Paamqm92M6a8+X5sGCRlNGzfQdkUKg6JmvoW2K6YI
# DATA 7a/YCU8lQdMcCYuaZv2XHgaRd9VKzAvzpg5t8ZFOQp+3MINJGtDW5OdcIVjF5F0xhWR439mS6KvBT6JohJZKiV8UyKMYb9yQ03vQ
# DATA 6U8B7TwAz4yD4SSMgz6gEfCFJK4ks6Q3wklfRpLytqwak2ntZor45EGZxvCKFgqKvOWtsrAvzTJ2ukw6CHiaLBBKv7KJBF0jCfOk
# DATA H3vyubP8An5KBNhmjARlF+tX6LMP48krs5B54duLf6Dr48V/J8cMvGCicR4umOJkdlIAkS+6aLJhdaZZfNP8CXrSzOFLPsPF2+9j
# DATA DUd3wt3aUoxcygUbrO8/I8ASTODKKjISycTLj3pwXTH4gU45KBFIoqA/PKo4fvvh+b8aji1iRqviAmU4NyIkn849GlHf9chZtxua
# DATA LjHstYguNhubGyXtUCH+n83tELYLA6kZqdTSPS+X/0/0U5wePm4dTdvj7kv0Asz2/1teuX1nxfb/W166ubz0vf/fd+T/txeBbbs9
# DATA 7vUB8CEGQwvkDWUcoodvvyekWMymy8dRifTvvQElnQVLxJgSTJ9muQAedgaT/hz+fvHxdNJTL1DQzHwegPwdsIukggsddijMa4bf
# DATA HLn9+b3jxOHvOMrdup3tdRENHtWeXr8+jGWSAHG+3l9rrd5Hv/k1Q+E7089uhzwajXMMfMQ+I6vmxUdw29ZhEM+lzQ1jMsR/fwsP
# DATA xStiWd8MPPz0UAhdjwGn6vxT8JHBoIJPLn4TzvThE3PWMo5DmQ9EQhAe99BMaUzyNtpuLHQtG+mXrdfwZuVxWzBoOdm3by3lAdSk
# DATA NyegrB5Aj4rpCQU8jSwvJWD2jc7vUan6k5GNVqcr+6DX77tAkrqVLHOabUijW6ZWMEk7Tqp2Okkf2fppMMWi9fVj1KEDOXytooQE
# DATA mWgL9wtY8sQx47XkgVGNzN9m/TjifNa+/1rGvnF0MBxOWpKdFsS0lVhF1pmI65HYZEKiGfaFJFNjlUtC9VuGuZY1gAQ0HfQmtVQF
# DATA TeJFxIfVqixNedTuldDeV5YfRk4K5PZzuVectMcfoGadXiLoF0LMCFnzuIdoeWK6y+jg9bPhgdjgYtCAzTcaPhYv9YdxDNPX730Q
# DATA SUWluItNxu1B3INjDy+WruZRzOKLqx2ZE8DSldJUZLhQuAmd01t0Q8ya1CFCf5Sq0FSIBZCnotujrKyT4zr6UdRkeg+awSKltdof
# DATA pOoN7RpNzSGAyvGsiEquBZwzV5yF7YN+ZGgZt4fxpLY4jceLB73B4vgkKB8GiW5YzaSp6BAWqjyFC5ChpjO0legRb2yokFKoC7KH
# DATA q75UiSVKUZdD2ksVzHNurRP1EtJGoNAkW5X+PHyUUaRvlYlzBitAoTzqygOyFFDksugahyFEYvrEPZy/PT7udY5rJDNV8EtJSmVm
# DATA 4jDxOiELYvYpkob4KMXaxI/yE4Aw2mc64QQfPhaFsIVCKL7YZgbxIHGCc4X2Uc8OzTWaa+RzEi6nmfTHwx8q6MoXw3FAiUimMeQV
# DATA pym3LBQZ7XI/M2r01Ofjbf/uE6nY8elbDkn+jH2kBE97U0rPRkzenygg+PwbnkNpC1HTyw/KYo6sIoIo3ULikb0SsjLWkKhSM4bF
# DATA YY4O15aO0p/isEi0VA/BcdONLqa5UI4fyYF0e3F7fNIC/gseFEyqSHT2GVj0HYIMWS02Y4CaNs/R58UuZda/KniMrF+mkgPZAnRu
# DATA oMKQQnAlWA1AjhMcTKKkjgF1Ff14QVXRD3rsgG+wjK4LedsZ9vuMslQu42mMfSPeXi4L9kM0V0NcSM3oxG94wkBakZGgntPaaqcz
# DATA Hbc7aLtYBm0ZbRydjVxyqmbRmzpD7jTjBVgI441Z+ych2xgaTeysuPediPl6fBwNGGyeg8favb6hufR3xu69aVLN4BI5d3Eayett
# DATA i27h7IX8C7F5n0MM7Kc2bZ9//mZA/kno0/yltMCmijDID/gH+fBbqALMpOAUjR6QFhit2hmFoj1f5pHEAGK4BwCmTtl0XjpQW044
# DATA Mu+7TEsh3CHEBbumerRTB5jr9fpOLgQwroaGFFf4a2O52lSAVPJZdbkJaldA2Q+bpEc0fzdZpqyVWSYFi3E1S03HbD5L9NVOb8/O
# DATA f4cO7kBFScv4V0rLX0y48YWLYtkdAR18CCr9YeeDxL0MHOERx2TAN0jxbau1tlNf3Qs+pC876+/tyM+bW29v3b+/9Z4lqRB6vxAb
# DATA x9MR4OFIkJLDMdxeHMdWxMp3EFA2NvdMAJRsQJQkKIpMA6DfaG3c23SVtj+JTg+GQjzakD0tFLNxWebqlR+mxZgVNnzPvpbCMhlz
# DATA BgowcdsUDwvwnxI/AXSVVv2nGZrphCyoUcle3MKQmMwMxJhQCTEo4Ij/YTjrm+n871uERLj4B4y4IV7p10aFttnD3E6G4WM+e0YG
# DATA 4o3f5GC2qowOpu0Cg3n/CdVqv0rVoXkGKCWK8M/NxkCJasrtI3BFfEkmgEz9//LS7Tu3brr6/9eXvo///07+vfqKunhDBvLR6eR4
# DATA OLi5cO3atfucuh0yARGVSCe1CuwTTvVOadwxwwFiwkFeg/FwenSMEqGSmnMbBo7bMRgE1NeTdocsBYD+gnoMOHLoR9D7AjzLDsQE
# DATA x5N3BGvsXwW8gBAh1WdwtZpQs+nGB+AZlrUBG5uO+6Ktyph6J9vkzpbgZzg4FlQHiPcYrWiHBwQo9v7CmOcLlJ0cDepsr2+hq7+Q
# DATA 5IwcCQtr9zfgxoRr3ocFJpWLlDDChbWtzT0hiNV3AHBrb2frPha3xRBQpo6H/XBht77z7sZa3b6DMVIdUoxSIy483NzYa+1sbe1p
# DATA 2cbnLLaw/XAHUnhAItKUOsuPlkXLe6v36rsYIoVaDM7u0h0+HqAiByOlKMkkY9FS1ouQU3ue8gvgzNEbiKVk5NreofylI8h5IF4o
# DATA LjxY/Wnr/ta91t3397BJI2xeqW0phdR4eCTmOubsOGO50oKgAEgR0exLQfRIh8eIXbEN4ZPxcXAAJjaxj8Q8jKhMXOLsHlIulWJ0
# DATA jNfk9uOAyVBGgsMeo/sbUVwNlJqtHmR8xAesjKIrt51gw8qjih4usH0UbDav+CKrTYx0gqydYRcO0Z7MYi47IfUPulCawsao7yiS
# DATA gdC80KIWnBOd1IdzaNGqE5g8XDGjblJz8xDpJpnd595OfXfXFrudAVOOFLmuqFKQ43Jybg6GoBbDCFD4T8Fz/5bVWDOsrQYs+QD8
# DATA +eZw8jaQgxNNZlTwNMRZQv8cyqyBf1GdGnVXAehb9Ahu1EhJAKeOSOkM5RIbePJinzzqDVEXJxtocO1NhV4ALwlmIbZUhGlogAcJ
# DATA Qo2lNgTQA8mrSRAsmA+1LxRsvMdCvowVUgGtaQUMyE8K2BJE0FpPZaeKydE3jFE0G7IguD6dtJ8Ulkq4FGV3LHpmmsVElRXiLNSX
# DATA Gs+o/VpN1Eov4jbGNQSnNAhR2H+ytFTef7J8uP/k9UPx4YeHTU6ZhmWL4g66stRcsAfBCwP9Lnie3ggaT8O2XkesCbD0iYlQQfEd
# DATA /541i43yyq2q2wZnIVylLPOiogVf5j7Macjv+HxaqRaXu5F/V9VhOEleYDvGY7mEptaf6tW7X2ZvUIfnGRvVvmGoO4XpYSW9qYrp
# DATA ffTvdCRb8dyhYmc/Ke3FqB9xtJWesNExYqWz9ycXCXmC4ZSnBN2qIzbrTXLVhJUbUg6Ab3gmi+dDVgxNNBe7mWNRRyC3HxzSXKW1
# DATA KV3/PQBsJaYuOLd+G2/r8jHNWwPnrdr0pmnUU4DuKAXe7vH0pKAqbWCFzcy6BXMozOQRxWSqUXTOUJ2oBUtVr8uHu1acCayPJkWw
# DATA vCifuW4vHvXbp0EbI+rakKAhuLYUMNjAtYrrf5BNsoZXYCKVrRBVDVLWh0eCQOVBsgFzBXmbkKxvBMvyhzUx9cB3+tGgQPPqS+OB
# DATA pLs7wbQaVllOXMfkjxdsbMJN6xSNO8TflpeWPO8QAVDnrmOZRbMVt0uxcSwaW0Y/phwckllW/SzUqTTqt0cx5DnB1RIvWVRZMNo5
# DATA FOQQH1NDJA89BiL09gSPr2JiBBARfgId2ZHUZbQrH5nHffJIORPsvNMXpGDJQ4aTpVQWC2Ihxi8RPvrDI2b67OnAZy7kTIVURZ6M
# DATA nJKrYN6LZE7IvNGVGwN0vFcIXqI6XUuOZGzzpV9jGdDMOaPC7w+7fvXqeztbm/fflzpVS9la/+na/UxlawKhQIliwCeTWTKrLmNV
# DATA 5SEoFzoPtwQr+sxdKr14FYIrkmGX6rGVYJT8fvUvFDzuARyQZawEummoCGJGOn1IYXzYdf2gDC6lVauHXY7rT9JlC6m7QBcgvltB
# DATA nMdEB4Hy5YiknULYABmB8upNxod4goevvV9+7aT8WnfvtXeqrz2ovrb7NyG59lWOTuiMRzGiiV4JdA+BlFnwjZoiL4lQRdSG08lh
# DATA +Q2IRoWRx7WQ3TykDMJ9kp5HyWExGhNTWmTsT5toclHl6vZ2fXPdJcVUBys13aBRpZ5WXQf4lPkPGYeabEMSXFwppyGZlvLsoB+L
# DATA eWsWN3AIkwTEPbgyZVOYwcQo75xEt0qwMrktUqcYJyeVEzID/G5nijcI/GTxWeZX2VNjirM0Q1JpYowO3d20xeeKOLt1DweNysPN
# DATA 1XfFNKzevV8PU1mw7EtyaWaZvnbWzV0g6V5/30Rg+3yOhmMJK4JBT/YqnwgewBBI6DcImBlUzuM36DihVHZbG7s79XsFWYnE2kiN
# DATA Yskxi/oGMB102nTRMOtnqA9LsWUb5aj3cRR9IAWaxPtl+31niKCeqsl64LZRsEt7aDTVgJM9YgoGxhcVhoMct1kT9Ef8F4zJE3R6
# DATA Kxwgz26s0IVFlWhUodhYSG1dLgICMBUC12+uh8HD0ll9Rm+iQZdvMjDJkG22MA7L8A8YNSAaBM3rjEwf/KT+Pv4Ukue5nueD6Kg3
# DATA GKRUdLd+b2Mzd1WAXkB9giMfAT107aB8wx/J00LIBT/Sv8pnDr3yRIWNnfr66tpefT0w+tDEM1iUaHC9gO1UZPWFuP4IHhVrTCtr
# DATA z/OvEhAqeY+1DFp0e21QMhN5/Z5XAaCuT2bu5VrwVLZImTtLijNyXlb51ZNvj8UcSkVo8FT5SF76QasMTWECRflj5ag/PCiE16VS
# DATA o1G9cwv0RVhIlfK2HAsJJfH2zRUNHUZNgvjJjWdoExDExVYl4DsJVmeYWfEduvIYYjwe6x5+Z8w3uJGQWQOraBivN4vFK78ow1zo
# DATA M8iQxntR1pR4DyRfwuRLHU8vckSlnTqp51XGMcT4HJPeYBoteAJdjBTW6fw/J/s0b0eEloq0WQHmDPciwe3+dj++XnirGj0B49h+
# DATA fKP4VoEhYVpNAz2meb0oCtagcOV68Qd21mow1lQeFKt+nY/mrMR9PgQ6eSxI/UPkKx+ylPehDoz8EDCW3vogOv0QjkxQkkHM8odx
# DATA uz/5sBsjdAAMprHcxJY3UmZZbjEqvNI0PN4wRff+tf0wLHpfFR0HhQjWUAz+shbcqqYGKDk8ld5x91RCkExsGKoGUUSGoM0oPKX+
# DATA I/oTfoKfmLt7+AKxATyAnK6fIWZkTTwtSaQXutEbe5HOG/ijfOqprZJxCDVlDAof41KFX3ird1IstKeTY7HFf46qREEojWqtScR1
# DATA IAggGn8oFrLXKQKN7e8CJs043F826jYPVbeFkNsQlTWuCZ711v6BRZzi+W59bae+9+H26u7ue1s76x9izpcP+dhsvSXOzQ9FgfX6
# DATA 5t7G6v0PV7c36Nnqw713tnY2/mYVciMV3Uq5MTWYYuNv98f7g+aNMJxvALOFisZ+vL/bvP6WaHWWKPPhD4phKVU4yOrG/kF0+lfG
# DATA IE0IqLTvB6FNA1n1FwCWR7ze5L+ijhuVcvN6dXERpi5e/HG1eaNKn5o3fpyYwx9n9/7J8sF+o7FUfqt5vRGUF8V/f1z+v6S1KPGe
# DATA hPTqHLfH7Q4EWCMwj/om9hOWBAWp+RDiIyYhyG2CSem3cTPdXAnIx9H64ZVasLzyepbIqgS6db4uBpy4M6ao73Y8IST3SrB3HCmF
# DATA raW6I00leI4QVju6VVQAho/lQVtLLW9+4iosP1L63gnphuENgByRnYVH8vMZX277gNg7aSlHlBb7qRS0BX6HjODByXQC3sfBfXwF
# DATA MehL0M+BYEcT7DB4T5CTgPjanhDwfDBpHxmm99Ew7vFVWUd7ksizU3+wuboGead26ttbuxt7WzvvU3LgyeSkPVhUqDdl1V3XfpaK
# DATA jSbofNH5DrSpupPPKL5Tv19f3a2raE9p1mOnlYJWPIUyG5M46SpHQiqZHoBL7SK2uPhUN3y2KD2DFmkt3lJuHS103ag9db30zwwn
# DATA eMIpi2tPw9UOnEOgFgEHDghIAXzUR4MuN38DJdoSpG8X9ZbX2EBYBYG83IFnoSdGN3woqLC8esTJsfUSmPeI8IzeNBw/2XunoJw8
# DATA jJQZIISNo3g0HMRR4gbKz0kmWrl9hz1J4Iqp1hqOP1EcrOK6xKUWEGfeRjOBik2iMo5hlWAXUC8vQzFiK+AYsRpG9WgfoVJLU3LB
# DATA aVWU4KOffUUcMn+03xU8Xf4H+GT7yInWHNttdsftQ7C19GKsD/NrJgqNxIku81NbJS8zcM7rAGMBL3Qr7IufMUOSJUm8qaashCkQ
# DATA +WfFmhRx5OLf4ltiesyaZwzi3frOrpAalPJtjPfuyVSw7sJJewSIqlyfBD2HdF4aJWlwWoCXgE6Xb71+642bd269TpYMeCpOIqzy
# DATA Mn3huaMu3QgKS6Wi2AeFW0EZdwfVq8NmLXeaaqbFxn/t8vp0oyZ8nAIozBo/DhDG7QzYubetXYy40hJVN9c07O5BNkKmKpb/jd1r
# DATA IfL7iSb/5jXb4gnHOnha2ZNiLkoFpTTy84cPN9b5VRQv8GPOnfXXD+u7e+n9isWjkemG0pIR8yfi1JHfONOtggKuzvB+YwcIjxPY
# DATA goG7Lb7bJjIx5izdU36F+MPN3dW3663t1b13QqtH+eyasnDCqpn06tNzpihJT5YBzUrPUHvsomHp8umAWAaRqKpKqKZyLZlGQ+pz
# DATA Y6npKP0oWBTNcmaOcPVGkfj66vZ2i65SKFb7ML7A07kW0EgYPsvUJylFjTU2I4QC9BC2yvVvdas1uEIcAsLn0zu3zqSmgTUMySFJ
# DATA RQDC5FIeIANAltkIlQa9682VTCJ6sLG7u7F5T04An8qgpQDM15N2pzKIHnN1Cv63FLDXbUm6X1fi47aQPFAa6/aOQPQrenzH0um+
# DATA JMR3UrpWqfkzB8VbVgQ0VTA3bjGRx4BXyJD6YhNBkF2MFTJ4QwIOgnsghmrrlQPnFUQdY0d2wUkYE7AQPhr2pycROAI3LBdB5R3Z
# DATA wNdJFYWfIHkT1dg79CpXCsYWwJLMnCmPEzyQMhKCJqLrV8IBG1hM3tqVAiXpxi07Kw/yalgUUslKs9g0ND1qG4rVOx3BxSs86A1M
# DATA iEcChGNmU9SAj9Vkk+xe3YI4AfE7sKqzBZ/3gullAEdFQ3ak6YvetOidm2o92Hq4uQcNv31/Y23PkwyNq3cMd7h6Uu8lW/VRun20
# DATA SERgowE5Jah3N72kVX6KtCzqKS/CDmKfvirJpeDTji6CYlV6XYQjYCfLKppz5837xEvHWcNlJUGImlj+epYEfAXA3ajb4oMUD4bu
# DATA 9GQUF6Q9upiKasEB24UZmK+gJBBXfCBsSFgcFIi/oN5AunVKdAsXC9cBpEgC3sY9UEyYGLcqAIaDX4LyXTS9G0Oj6ArfuNARhCJi
# DATA 8SVzduAn1HEkOgXgHdD0cFBmz4T9AT9DWFobjjc/1oWPdHXkxWLAARslDj53lzaROlJjCyShMkqEH2GIINmvKwyNsFweDB+LD9yb
# DATA uWsa00yl1iAvBQiQIiRY0MlPTllgNCQXQwMEALiAedYHjnWq8p4KXoiH2puS7iCms90NJoAdQ8dq1BZHNk630gGlipgq8UD6wZmR
# DATA hsASNaVs+kICpsTWpLY8jErHZWjp0QR7zRTM5DOecXEORKbcmCWuccdurgQ/qtkCUC24tfTDOwqz/FjbFFg3SjjG+2OE2EF9ELjn
# DATA h83in5HcJFM2JGUk5aOJGqmqislutXpix7Zaogv9Q7ItmxHL4mElnexUEX3F0W+Y9xzVHIpc2FbSEd64R5h1uueeUVn7UcT9Tqgm
# DATA rGnJqo/fdeITdMg66Uu7yT6jQbvm9tq1uHNSecfbvSdDuxh6FoQA8NKmCCc2/AfKbk6lBGuVvfHDT1iEt7m119rYFBfx++ANppuW
# DATA aiKquRHydw9MR6KEnhZw6GKCkWpKcAMw78Oz48UU7hw40/syTskLJk4sUU7CByAzRuwKPJ2kfSCQyyL1t27IlpiSMAOUOKnfGHEw
# DATA UIoiLlSXvZVbkH4Eiudz3fKrO9xJTd1thRCawvHh0rhhLv7J56l42QvgdCx7FZiOLTdEtUkNX0RN1+jLktzqGsjTiZyt9DFxhFFt
# DATA 0fK7hoQ45FgAVTiOTK6TB/wDsLh8awNVN4S4jiFd/hXiVRJ12nFAGOYo5mwa4QVMBjzSBc+IPwrK+l0zkGAJFI+vryylxKnAOxz3
# DATA hi3WZPwk+2LUBIXu1Xd2Hm7vWZxJdRlHJmoh2HEhQVVVPwAp3EwsYBKeGIqZ1ICHq+4daA87AtVM6ACMzw6Q9HdNBUxZxsURB6fQ
# DATA mp8Zx1UyvJqZaOe4PUhyT9QZIwEgsgeZEEBh3O4QJo6Xw8gfUWdqMM60YK4suW57HRwE7j7cfT/h/3nqC6Qi7+HkMCuAeHksxLfe
# DATA zyNzB9K4i77F8NWyjn/SXDrTB2K4OpNPJ/kom5u+Rc6GtBzEmRUtqUNu3pNNh6qq4GJ5v5AoS8aVQ8jsR+N2N8pxtqdzeGQ4Xk4l
# DATA hoZKCHP+aaBCohg+bnV7MeKWWVBLiYFACKHsJ7ILaJBI66Q9ENV1yeaFxDpzHNur9+qtBxv3dtDFBIezsWPxhNQ9AF9TdgD99FLp
# DATA n73Jc5+cszePoQ70xXCnxOckz95axtnrfVmzTDy41dd0r665RQ6HQcj2Zw/sEgeWXYFzav0o49Saa/3znxjKkc2Vv+iggIA6CrPX
# DATA 61A1WY+xuFUtbGt9nZ4VMxbRmBNX72bvSU/EtpNfI5ViU1QphMWYiVTIOrUywrwBGKABYGhCcxxZUrZfCyneUyCGWrVFFaofGH3p
# DATA QfsJKMGABqCAq57Dl+6C8geVcqntMUgdnCpa7CuxdAqZsqIxtw8Pet1QMlrxCEQHdZ5Y2iXL0cNHbIVLYlVZhDdDMBPXxZ29loog
# DATA Ynmplgx1WvC7e6qTJaeo7ik4Dst88yk3n968c7bPBX1RXXOQcMoWtwbsBJrIYCgAqLWFBVhkS1a4pIBw5TfCuVjzpQ8x51AuVmdc
# DATA MJPHWJ67Ixn9EyAGoB9hppcmglqPwT3QUUvJmLZCTiotuhW2OuOIo59QIpnNLCk6D5FQdMCfsV8gtw27IebbEEnqtvsFLMXPAhrq
# DATA GtRkVCfxvegRSFIjDHHTyL1bM6dPn1wK7ttYQkPUKPqvfVcsuqrZ1/KrnAPdl6ZPDrkSifeFJN8rv0e8kPjmOzyUGPYiPJkcozwR
# DATA riptPAG2Ntbub+ixJdOv0okrVZWIawM+oWEzYzXRH4IrprVMqxf3pKlcUJ+b/pPQkY2uU9IXv0xwCg4FMEHd3qBmvLlef3fz4f37
# DATA +AvIBXL/Ub4p9dUnQry+vLTkl8EztvXa1oPt+/U9PPntrZ2PHjS0jJQndKb0OeOoLifh9A5NJugnJw6QJ5iA2VMkw+XFZymCXEqw
# DATA wv2+tV3n/e4VOJgzGaAeTQ8eUI49Zllbpgl9ZqZa3Y/947lopYCMoG7wzpKbuAbzAbRIu8njJHW9vX+SwOsJnTuLU3Yl9tS0Malh
# DATA bYaxtxczOrp9WYEuNPVOul00MiYhOI9X6QYtJgkO8Hm6QgwK6FagAXr6UVv0EODMDsbDxzEkJ2atBUDPAAVMov5pxc8t09QhqRf+
# DATA 9B9zWVnSBTeLPDyWGDFdxtJXM91IrF3EsPXsnZJDiwzafLltagahFrPbxCGjFdE+nZJ5nKbjMUcewjvaLDhniGgxrVqvLvn6dc55
# DATA GbYficGjm0NVvcSu5exco7qk3W64YPIiq3DNRCEXhM2QsWhSzkyzX0feeyDZlBsqRwbm+wlqIzszJnJstQq9wSDyBeXic4wTZbgD
# DATA cpWWjtauDZdxQBGwvJQEIbcAc1yQHJjQGx65xSu6uwjbup8OzrZorYCYUjA3JFwYv2/eLWZqxbwCu8xDBg0LUWtjK0XLZM9f5ulm
# DATA TbNFdZ5OJW83vJZP0GcA6yoF11v+AFfd1Nw95vbv4/3SOtCUll76OiTv3vRLC135S8ZNXMdSoKNJKfVqfnmtc4raZRZ79RuyZ+ly
# DATA LQ3FC+kzL2lpz+pgaudmoQteagDKsYlWHdx55Gq7DDtfU+A+sVl/r77jNPRqsDWIFKYuCho/G4qBtvvAj+Pp4WGv00PHLojrkzGK
# DATA EKIFWgeYlba4wB33YgS1SYSim0BdJsdjdAWFRylhFqr5eRgTuwXT1QAXKAPlslgt4xOuvZkaAv7iyF7ZCF857wwp9WYo3ZXnK12Y
# DATA fIp06fqqte2uPyuzHv+YLqWIT5VEvhv1e5qqO6GS9zvAlFLV8DN19t+Nat7Uyv+5qOBzybhXqZCf4bwEAedWobnU8JkEfFXKd0Pv
# DATA fhmNu6u3TjvRX9jvLBc2eYbOujc4HPo08xxWmgUXriORCAEodx3x8Zx6bvjdNCH4tOszSK54JYpz7AVrz2eT8BUrzlt+G72h1iQq
# DATA O6rmVMehpkmr2HnKoi4xX1arY2/sUwndwID0a8ZM+89vilJzs0YbIAJbW3scj2NxUV2CBbG/2rprnZMmDgEGMbc2Nt/ear0tNjjX
# DATA B5RdTI0n8VRQ39zbed+sAQnbceBylonOdFgkncNhYa77v70/7RwMBvHpkZu5Is7/TSfuodw+n178CvNyfQRfLQ+GlHuRTAlYy4CZ
# DATA yKV4JuW2EACgf2UZlu7oylXlTYworEFUYZ6Qn5kaa6RlVlfjZ99Z+8M0VbUGGdCmRKSflNLomd7VMAEN4gVqg/iRkJQ7NL3urxzM
# DATA c6RoPbz2rkxMo5fpqfp4VuXENk9lhWcqxEO8wr/5N/DZ/uCaCgFI74cvq7RxMCUGFPxIX4W87RbncvWRGxMuSDv11fX3w3m6Mte1
# DATA 7BLXM8vBnqlALY5mla/U9Opd0tHJBGnwtI5sKhFlA0KB+mXWzejSzb8a3CWtMrRHKXYRF/+kfQrXLcy41A4GEeDGjyhLjM6zVFmY
# DATA qZ1V9MwTWvPTlVTRyFKSDJSwi9Wls8GXxJ3/WTNjK8caZJWrQq5OyDP3+fnXF78O6CSVvaZ0MPn4rr7BHLSFZFUyji7DiikBHv3c
# DATA 2DQOfldsOZWe3e0KW8i/7HMRNGNztB5s7D5Y3Vt7J3yRVebESrDI/3r+u2S21C8wUyqk0/slpRAMZyzqzOtaHpPnLFHPMbtmC3n+
# DATA qlN1PtSuJ9tJ0uknOxVRcWb1bvYcJ/+DkUbHddicnU4n27/AbxmwE41ASJyZo8jb67MUcfkShp1MbdRLNYK/iihpfPUgDBkIIgxQ
# DATA w94NDk4pxnQ07A0mlWBbTAIEEgfbqGhZHEQTuGR7amVlA0SnDkt4vxFtBJ3hCPKaKUVnt9c+GgzjSa8DKszJkM6XjkyLfimTfYo9
# DATA vmVC2OdXgxrbYabp69K8KEH+5NvMLRMOhz6UcoXXp/C0b1IZm0xatnCV9JygZVRc06JgAP7u+7t79Qet7dW1n0DGFOnZJC6C2w/3
# DATA wqyRevOmGntgDU+ebXsbDLpEAI6R/vXbWS3h/M/K2GocUzJhK996vQqrS6n3eOLcgDcnEfrl/ENySVBwnZKK95NeLCbhyAb/SaiU
# DATA UkurHDCD3pNdxF8smDkuK3vHlBLx6EHvycagZCXArOBLyKvoVZkeAIEBWhN8NTaVM6ANBGsP7zjXxUWcBgOKBi8F7W6X93s8HYle
# DATA YSSIerHoeQfQW/h2WridsEl66lbwUaLvBYy5577QlHD+0II/rWjRzDtA7PBE1CmqYVVnwrxqbUJCJBj1T2UsmdgCJcQQc946GHZP
# DATA bVwNLKRunB57RDTotiSuYAFKpRUiMMVCuEYQmmUAxJAZMSWgokdJ6anAglgsIcQioi2EeZu+Hw2OJlLiBmMWjNv1N8XX9duxb/SP
# DATA 0TBNIgbWYU35MS5eGv2ZgfHZRGXCAWjxjHAb8iDP+0zRCCsAoml7HLUYLQB7w6NlfAQTlJggEsR/7iIgMd58sIViumUXzz2kvFtL
# DATA N0HAkuat8O2tnbsb6+v1zfAsh4pX3i5kNlLw0bxX3yNvW/yF1MyQL5bkiDDbHq47tgKYZjRv7AvnD5HN0T6lI4hB8CmEi6DkptD+
# DATA xVQ/26zeKC02VE1WWKfO5tX29ChK7ahEZ0zpD73ZlPBOi9m44ISfCLfDlZcXQZY+p9g8op/Tp6XLTyMRHEfzzt8bCiV/wdYtd2SK
# DATA gr0U7Xsij3P2bHtr90W71keOrCjMYEItSOCY5NyNZiaJcX2ELa3CPC3etjduD+LDaFyuw+FGsYKsfuO3BWVUerFgjr2JVs0tBT+C
# DATA W0tBl0GVpQ2Se2XEzDifBgIirR6eOwj76fSlmOmOYYiwULNEhMP5mTBe6CvgAoF4JxgXz7hkO9GjHqoXzr7rLesjTOzpCxInbr7F
# DATA dofiKf9rUuXK7Tv/hYgSVsyD4aBDw14GbWpOzfH/0KGG7EuTxGgrVkg+0v1q5if7lUudDalETmLh9+T9n4G8bTXud0TYJk0nbDNX
# DATA QcfpMrV1ObhlXQ7AdPf21sPNdfdy8FLVolaHfkgePEoBBNvJ9C0lfc8tcU5lqZH0mC6hS3LX0ZiL7rAl5EGAh7PumObvwBP8BUit
# DATA Ih1zaJmSXvNQSiECGq8oqD4kYeO5HwvQedln7XR/x6+F2WHLjCm4u7X2k7pJ5WZ9lscoetyYyqeJVECRi05JqmEIcx0LVb3VSqDr
# DATA O6ZjAiuq8E/rcIjJgjDBag/84Tm5JtBRqwVSTKsVyqzH4xgdOcT+w8+V1fHRFGAMt/EXlWkLLKQtIQN1Wq2i8SbkJ2u1+ZWCdnFE
# DATA 581t1IAz0DB+E/ez4WiyqFw2peXGW5l50naOh4BsXCOQYxQPtdOkg2yAMOky6FRMRVkiYWJZGVrSzByGjIPMLETK8+Kbab/32wdR
# DATA P+N3NLNlNwHeoOkVoNo043dG780owbiU3AkOZuWy+AdKS/0ThKriYRpNe2xjXXLRJXfRzbf+BO7iO1PKd0NuJbS3FWw15AoBWtFJ
# DATA FURDFTsUVscBLaSZN/AtMm/gRzFh/AlXhz/jSvBnnHWJju5vlyjIxJkE4H23KQ5+ws880/yNZzW7kQR1WpBuNoSr23SuBnhH6GoR
# DATA W1PXVaygw6qctuzKzD2WUaPGn8CH+LXX1WvjQ6UnvbRbVXHhL77/9/2/7/99/+/7f9//u+p//xvu8tmiAFAPAA==
# END_REMNACUST_HELPERS_V1
REMNACUST_INSTALLER_PAYLOAD_V1
if [[ $EUID == 0 ]]; then
    bash "$directory/installer.sh" "$@"
else
    sudo bash "$directory/installer.sh" "$@"
fi
