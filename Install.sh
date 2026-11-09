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
HELPER_BUNDLE_SHA256='f45a60167d64d5913c90a5dc1651dd44a8e74a90956d241f46666892b29d94e4'
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
            [[ ! -f /etc/remnacust-node-firewall/state.json ]] || PANEL_IP=managed
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
    installed_helper; lock_operation
    local script="$HELPER_ROOT/subscription_pages.py" count index=1 selected_container
    local -a selectors=()
    [[ -z $CONTAINER ]] || selectors+=(--container "$CONTAINER")
    [[ -z $DIRECTORY ]] || selectors+=(--directory "$DIRECTORY")
    [[ -z $COMPOSE_FILE$PROJECT ]] || die 'Выберите существующую страницу через --container или --directory; её Compose-проект сохраняется.'
    python3 -I "$script" migration-candidates --root "$ROOT" "${selectors[@]}" > "$WORK/page-migration-candidates.json" || return $?
    count=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))))' "$WORK/page-migration-candidates.json")
    ((count > 0)) || die 'Не найдена страница Remnawave под управлением Compose. Укажите --container или --directory; для уже перенесённой страницы используйте upgrade-subscription-page.'
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
    prepare_host; choose_version
    confirm "Перенести выбранную страницу подписки на Remnacust ($VERSION); подключение к панели и настройки сохраняются"
    release_source; select_subscription_image
    step 'Готовый образ сайта подписки' prepare_subscription_image
    step 'Перенос страницы подписки' python3 -I "$script" migrate --root "$ROOT" --container "$selected_container" --image "$SUBSCRIPTION_IMAGE" --version "$SUBSCRIPTION_IMAGE_VERSION" --release "$TAG"
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
    if [[ $TLS_METHOD == http ]]; then
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
        install -m 0700 "${HELPER%/*}/ufw_guard.py" "$ACME_ROOT/ufw_guard.py"
        { printf '#!/usr/bin/env bash\nset -eu\nexec /usr/bin/python3 -I %q --root %q -- %q renew --quiet --config-dir %q --work-dir %q --logs-dir %q --deploy-hook %q' "$ACME_ROOT/ufw_guard.py" "$ROOT" "$CERTBOT" "$ACME_ROOT/config" "$ACME_ROOT/work" "$ACME_ROOT/logs" "$hook"; if ((${#renewal_hooks[@]})); then printf ' %q' "${renewal_hooks[@]}"; fi; printf '\n'; } > "$renew_cli"
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
node_acl() {
    local https_port=0
    if [[ -n $STATE && -f $STATE ]]; then
        https_port=$(python3 -c 'import json,sys;s=json.load(open(sys.argv[1]));print(s.get("nodeSitePort",443) if s.get("nodeSiteMode")=="standalone" else 0)' "$STATE") || return $?
    fi
    if [[ $https_port != 0 || ( -n $NODE_SITE_MODE && ( -f /etc/ufw/applications.d/remnacust-node-site || -f /etc/remnacust-node-firewall/state.json ) ) ]]; then
        python3 -I "$HELPER_ROOT/node_firewall.py" site --https-port "$https_port" || return $?
    fi
    if [[ $PANEL_IP == managed ]]; then PANEL_IP=$(python3 -c 'import json;print(json.load(open("/etc/remnacust-node-firewall/state.json"))["panel"])') || return $?; fi
    [[ -n $PANEL_IP ]] || { info "Ограничьте TCP $PORT адресом панели в firewall провайдера"; return; }
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
    info "$COMPONENT удалён. Копия описаний контейнеров: $snapshot"
    if [[ $COMPONENT == node ]] && python3 -c 'import json,sys;sys.exit(json.load(open(sys.argv[1])).get("nodeSiteMode")!="standalone")' "$WORK/uninstall-state.json"; then
        python3 -I "$HELPER_ROOT/node_firewall.py" site --https-port 0 || return $?
    fi
    if [[ $COMPONENT == node ]]; then
        local renewal_project removed_api_port
        removed_api_port=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("apiPort",""))' "$WORK/uninstall-state.json") || return $?
        if [[ -n $removed_api_port ]]; then
            python3 -I "$HELPER_ROOT/node_firewall.py" remove-control --api-port "$removed_api_port" --owner-root "$ROOT" || return $?
        fi
        renewal_project=$(python3 -c 'import json,re,sys;p=json.load(open(sys.argv[1]))["project"];assert re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,62}",p);print(p)' "$WORK/uninstall-state.json") || return $?
        if [[ -f /etc/systemd/system/remnacust-acme-$renewal_project.timer && ! -L /etc/systemd/system/remnacust-acme-$renewal_project.timer ]]; then
            systemctl disable --now "remnacust-acme-$renewal_project.timer" || return $?
        fi
    fi
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
# DATA H4sIAAAAAAAC/+y9a3cjyXUgqM/5K7IpHQPoBlF4g2CJarNZrG5aLLJMsrrVZtOYRGaCTBWAhJEAWVSZ59jWzO6e4znrXzD7OPsH
# DATA ZI+11ngs6S9U/aO9r3glEiSrZbWP1ypbTQAZGXHjxo37jhuHB3v7R6f73/t9/qvDv267TX/hn/u3UW82ml31m/ze7XXa3/Pr3/sO
# DATA /i2zRTCHIb/3H/Pf50ev/N3nz/dPjv3P94/2T3YP/ZevPjs82PMPmTK8L+N5lqRTv1X1+/6fBNNlML/1m/Vmx/P20tntPLm8Wvjl
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
# DATA /p38AxvkYG+/Nol+j2PU4V+33aa/8C//t9FuNdRn+b3XbPe+59e/CwQsUbmCIf+Drv/3/d2Fc3m6PorleSfxZBpgLEhOaPNRZy4i
# DATA yu7QcbpYAO/FbO5pPJZzYBHKacp2Ix849XJD2uU0khpXxEs2W7X6JoYxn5qzLkpL5ktzqeQEqzByZYfcbFmjwMVP5iyuXuvKWSiq
# DATA ljNJVXsBQzRrde3tk1Nq2D+/D2OjagrK4IIuAzJ9pDdTsMz39o9QUfkMFDbMwU7H4cnZnlK/CSWqzH14a0ryKaA5iAYwm5yWr86e
# DATA vzx8KkEQyooEyQ+IezJVd2BezsWVfIZJKJuchKJHQbONbpJQV1PRXT6IabVoIHteqfkzoNu+YtaXoDkshzVA4pO5WpMnwyB8DZ1X
# DATA 728FC4kJvQ81m1Jh0YImPzk7PH2Cy7WJ6JBYDJ7voVsxybmLJfiZbOTQzb0j2e9u0rvlrVq9Vq8oVCsCq4F9lRn6okXd27fKLzgk
# DATA xzQQo+nyH2T/472UmEBVC3+a/dvw/2a90+u5/L9RbzY7f+D/38W/Jx/7J0sqCaiKm4NVySkUxJrA3qNassd8AaWu/3EVgImbYdFf
# DATA 9F2FeLyLDhgAa/34iVdCvwyfyyo9pYTkhT/K/B2lJ5dLyCq2R1mpoh6H89sZaJ/5JvyzafbWfzlPskmwN+b6LPzNv7NffAKm8hNQ
# DATA Y4kfDcCqx8J5T/54Rk2fhPSm6TEawrvlcsXf+ZH/1vPhHyb38if8x63khnRoekSRuzIP/GmNe5Ww86c17v3TGpg3yaJcqpUq5/UL
# DATA /9NP/XrF/9GO3/M/tbrGf0EUzMDy2CY3WPmRc5CXNmeXpUqNIXl5WSm7PQvw4jo8XWDa2jalCINNUIun1zX0MH+2e7o/eHVyiMUx
# DATA 3mz7zeo9fZyBpZEuFy/w0r5s22/UB7BdwdAA8Zh71OJHTl93VVg9MGviScCzhVHL68Cp1LIYrb6XARpgNTCgyiV+t1RBdJbY3Vfy
# DATA 7ypmlDt/m9g/3cT+VP8sDs0puSEN8ZRlTSvc8g7s7AUoGQaJaFbf0Gv783k6L5eeCbOUU3ljVSIXqzHgtYy0dW59ex4l1bt3Vykj
# DATA zVGB5L2rOHxNnUq+csZD+G/vvCdPWDlRIosD4JF/+qeHpjIfGPdUYCLgXFI6CkI5zlwpR9c2gc5UiJXVFngpnYP+dEwF98iBCeY8
# DATA 1jJO8CIcKu3Me5sEoqkv/xT7wtMxEd5f68uVWv4kEZWFM604DRrscrnaRhdKqcluM8O8UG/ipmKkl5r1ZrfebzSa9RaQzyCeB4Ng
# DATA jHb9QOdUDqiUfGnbWieBhZCaLSfbfqnRr7eiYLjVDEatUbPRbbaa9XZrq9Or91qdenOrO+r1Go2tcKsbDreGrWirEdfDZr8T9KMg
# DATA rveGJUNT6uSs6h2I+9wh61I7jHrNUTSKe1HcqcPrQSfqx90wDBrNrWa41exujcKgOwx6/V57K6wPAaJOqx73e60w6kS9krtNSuEo
# DATA 6HR6YXc47I/idjQK+/1mFLSi3laj0Rg1ekGjH3Ub0aiFk2mOtlqtTq8Js9kaNYNmEHSs/i74413Vu1PsLuNb23fwaMIyRqb3J6fH
# DATA R7WM2ANQb5l+r/rlQdW/Jqa4uJ3FWDbD39nZ8UtDJMtFCfjYdW2RMlcB5rkNjdUQSD/2AMzDayF577+Ah7CVr4JmpwvMi+u9lhkq
# DATA HrtSqUXJZZzBjr+K3+AGUuWZ1b17cXQYgxaYKVhnwQIHPL+oqgA6UNRdRUgkGfnc0P+jP9KTYdhwQlxNt4QPP9qdg45aSzL6K9DQ
# DATA A+mASlpMQ+wBeIE8+2yJ/iJ4iz+oSTgEikCd5xCNUFcuANQrQonAUTF8Cz06ZUYpFi/FtGBqU8OS3HqYQpycQxPAxnmtVsNhqj5/
# DATA Z0A0w4vHWfwo4Hgsfk24Kb/21LuzVmcMqoHCmsG9g/KPEOU8TMn/y7/0P6KfaxThyL4CVb9cegPbvrFdgqnJUNSEB2dsDG+xfM6O
# DATA L5hHc6Es/aAhVO6CGVBCRt1tK3waNO7k6HEShJoeq4543H35cnC6v3eyf6bplIDbhG5wApvXjZKmVWecMJmhYz831LOYf0+uy6Ug
# DATA zjZhxM3LcFKi1anyrGpg2QREfSBYG82K6pZeBJm42AWr5Sy4LOdaN5pVv7lVcddI8IPpX8GifC6dyFRyHeDLVTUOFSsqVy4qZouX
# DATA lovRFmLzzguy22moa6b72TSYZVfpoqxYpVp8xgXtbFwtsNwwojOs/eAvlvH89iS4eTXFsFd543T/cH/vjFsOKKjz/OT4he2pHLDs
# DATA r0lnX1FWC7fnJztKIdhwFoKLJO6QED8FHYLfr02CWXlBvK1mBlXIs7bdDO8yB9o9Py8F0SSZwlIRBQz4G+6wkjZKB7A6mEOX6VYF
# DATA jy4ubMaA24NArME2K+NooC0SV8n92rioVCx9xOgP5RJAOhrLJcYYww5vBeVG9TD4QIeBkbf4j9zsINNKSYRww0LOF4Plkr/hQ4QE
# DATA Py/m6U+D6UCVVMafrjH0rBvDR/3wwsggQhUOUNSpemGAbAZ/mKfj2H4bZ5dcDmBbUrk4UByXeEZ5FbPyhGdsk4AlEeyfk+kQI3Gw
# DATA lWz6WCWB8zCYYpyG7ghJ4nGUXVicOMZzzcB0Ca8Oz+e3ZUF2fN0LCx2mHxCiNjmBEOWvJf8T88LTXJdKfhsK0U1BM7YG2raaMBz4
# DATA XCBidD11KPEj6homQd9yEBOdlNYRISXGYe1EbvVUZw4/FfIz8JvTMfewhJKwhBAvapzezxO4TSFT+EGDshXMHt/5QdM/PsHslc8w
# DATA TBkhnxvM0ozS94ggmYtU+Z1KHvlqrB2tF35aMxRy8akGBkQbUwt+0lMmxhOSTlSzplYBhovXhvGjj2CrEIuOBsECYWLpQd8uaqpI
# DATA QTmsVNzlk6FrmM4vPZmB6ccAfwzskWltoaeH1lUrGYIBtC8cKl3BVBLh+rrjr85caAs5AxInf8J9AH/yPWYUNI2xX9Rr1JY9x3qF
# DATA 8F2mf1G5yL8IE7tX/vwnIbYfvFVDmHUqbZQ+CT+B/1ZqP01BuylVS5U7JsWNH7wlIrnb+E8rsxcTCpmOYhuf3R5EFhfKsRlEPrAV
# DATA BLWS8xAUbMYcVyzlX9E72lVoofcav/ppTfgfjIZamHmiH9TA6rsEJXANZcjYVM1nmip2mtn6a8E0pZlMNT9k0TT0VKQRCOxLBNni
# DATA 38ThrMcPUjMGeZccoY41SPBiEfA0vjVWEEXOWKtv3Hnrv1mokI2E2kWRbHWkacXa4JSild5U8D/n/BPq6ax8W7/lIGOKPBdtDtsl
# DATA 0YXR8Fcpn7q6qOS6MbRc1JVIRVTI95VkXOn4PCzwMbn0XaA4oVLEIFETlF7oS0OXT94CEsidQZyJ3OUtM8PBcYcKJ6lqJydPetua
# DATA /J3LeguFQcVRI0jFZ1uhSIFQPVjv13j4ShE/kNVEq45MKu64aP8IsVHeGvIfvR62yCneduL5HEfPWZIZoWdDyUiBmSMwiICLp+s3
# DATA se5MG3d4Lrf4BWmQQ5TpgWVK+ZwNXLL/LshhYSxNi1o1dPAffOOiaOcW/EYbj7H3MEcUGYlBFY3yvKSEz6Vt/km6FcHil/Kb7S5H
# DATA sXfFBnjOHsMQbdk2wJVNG8wvr8+bvH8A2hjMhsurRWlVa53YrrkHdTTdmiQ62JDiKcN9M6VMuAGW/OBKVgMMOMJ3EaEDdmgPzIgb
# DATA pVVhalyT6OQplJ8JXkWI5al0R0XbBlvVXEAqRlX1VomfdRTqvebO8+lK5x89+fPzYPNnu5t/Vt/sDy4++cGTGiarkoHHUpa6sZCy
# DATA jpLw8CJmWC0s/2peNpkRRzDcxdtu+04NSMOoVaisH4RvbDEe3NA4UIE6CewinIi3zYQoJChhUP9EvY+0bn6vZX8xLhX1qPw5o6wW
# DATA v4HFzk6BoNkFBTwefsWyPc9B27B+zxswls01gq6oy09X3BfQE9U0Lz/5Zv7N9MklbLpvVlCrWKY4fFVvAMo5fajCEPg/qzPpao6d
# DATA XbCo4xJYj/R/Suuc5xNneX5RsO4aNmMO5Bd9nSTASjxTI6pBkBzfTMtFbvkqkwBMu+jpOT68KFwGDSaPhZRfADA9rOV897xP+NGK
# DATA 5/1DJuvGb2y6X04ZLPvGCE2ihvT9Twr7JA/9Ux/xgcaQs2McqJD0n+owiduwrNFx3rjAGZdIlRb1dEUMrKqRpNDpRanNlkBTBfv1
# DATA rkDjYXaufXY5G9LqVAk7JT2yRZQuFzUsjA+8/0vkHXS42uLOq6wk4wlb3RphhxhyN1/xUDrqpkUW3esVR+ZlcWWvFXZquo6sKxxN
# DATA AhF5LOWAfWg8DgQWSFZdh3WHwy6zYJ7F5TyHq6OXjPiVhZwcSNrZ+hD6Xmq1hJwzVbnQk1xOmCaOAUS+KppsSUqNUVq3TgZYmTrv
# DATA rZwo0VfZsZ+YFZEahVXLMcU3UdckVKTjuEY/yQMrsmIFRz/1zeoTSUmolamK3qxNMMP1MkanwZq2EpbVEVXj169aJMs0equODWuf
# DATA qriMsUSLleaA1WiwLE0NnV06aPAmWexhKteO33gK2mRNiv5LdgHqUJixy/H0Mi7uv33+T4wJyRg7HoyDWySb2e13m//TbnYanVz+
# DATA T7NRb/0h/+c7yf/86Mkymz8ZJtMn8fTan90urtJpy9vY2HjBN9L5XI7W0AmfxM8sg4YUQnVQhIwa3DfP0vA11k6CPVmD7jxVRnR+
# DATA SUxPfcdkdvV5NJ0gr1Bff5rhLdr8Oc24pAmONU6GqijpS/iqmsx1n9ltpj5i5QX1GZ2LngcPKSYK2gTwwwUyW+CCZeypPBggDxwM
# DATA UE+kq7WBfQG0qJlV9DB458dEKqzYeYjGiPH13CaTALMmKXE1iwfInDzPi2KsozubxZGKYINVi7lUN5VtZbUlmWKJqg1AKY8tKxBB
# DATA x/eAHXLgF8R2GX+EHiuV7QvsSgW7ffU7XS1qxV1x7fRLpLOD6CI2T63WgzQGnrkK07nMDfUha2p8RTraaYnEdC/W94wVqVZ7fguy
# DATA a9u/p3vysjhj1PBbVq44tjNPixdCrQ3SRFZmj+TKguggEpJrLYrjGX6Q1hUdM1J3oCXKPJfEJf4ZA4NvQSrQ6ACSmZ40OC/BHiQS
# DATA LKEjSuZZ8NCeNqDPPKECIgIELeD5hWMtX6NrK7ZaMYD8M8J3fmGBVbA61FCWh0Ql/8LdYKQfKIfTRKZRaXtFaeXW5yXORrJnmX9i
# DATA TdGZAenmAH9ZnOAUbc1iEM2LrJSD/fv+qeCCbrDHKl9y5pCTLTIuCIwZRcRYsqeSWR3F4TiYW2UchvE4vamtuHJVVoiDTfaCrCDy
# DATA flInXJb0GtKj7UILhLd5KU8lzs955I2ovHS6nD0Gc87ELDKmDtZR8L/G7L7tzAxR25vO0HQxxA8RdimKcUkZYIvII8xRnw/S2UL6
# DATA diei6NhudnGuOisg+DUN8xN1vH7CukDvBtEESquaV0JeWhE7ZeiMZDB2VprRcm9ugj7KH/5imcRgEEmmakWxYsrgi7JVpn5hg4Gi
# DATA uTZOgwg5ZsFogFc8mgAjfQydgfBkgPU2jMrstZV8YrJLOFcQg1q4N3eO0mks0xpJMXxqKSfi5TUD5ziATcrTl4e8XntE7EIG9Msh
# DATA tSyRGHx7ZxOECwIfh6HG/CJMtcaTrInUqElT5nru69t5pxJ5GY21hgwHHZqPG6GGJwVBrxpEyRwXsFRZjaL4Hz+yL4kfcvCQOlMJ
# DATA y9Xifs8nWPSY++UDm/yaHM1dUrHzPOZf4O8iVC4ubDwHU8muU1oJ+/TWqSX8VPQShz0REnM7UEj0bC7Ilu/PwWpTMh9N6YGSymXU
# DATA yqr6VlNOZN5pbNWl3whMczootMN1vCYp7BFUfcsIk7SnljdXdCY/3+iHuguL+zg7lSFYt0dhExFw7l4loqKaoaiXfOiGJPYHMOSV
# DATA BPgZNUjpmKgav/P4fGxmPC6HQglYacDeWSfL6ZQ8WGxFr2n1RRyMF1f2L9hkiTsSxdMRXe5TuqJWt7LiIdGXQFW43vIwT2bfAghK
# DATA SZiq8R8afjiPg9cmZxwXPxuDglhuCuMOsCzsl0ix4i7Z2z06PjrY2z0cHO5+ffzqbHB0fDY42d999nVJMUo58DxYTrFoVnmepouq
# DATA Of5m802LRZIdhsoI2B7yUu1ynA7L+kXcQ5sflyquGOS7oGpYw4HsrzJ8ibMwmMXmTST1eWnzm+hto30Hfz4pcdptjX3EMnotyQbZ
# DATA 7QSPcpcrfAHnQj8AxsU/3iMFKg8wTcELnvaA2flPMM0zfL2cZU+ACvCak032YpTgkQYv/7aYdLXJawRpkkbxTj3t4UkGfpDtIO9A
# DATA gQTmzSB9TV8rDmFJRxytyOtBBkjVDjkZRY3K6hcVHdlERxYapjX8Txvszav4zfn2lhW+pnkAXNbreTIRhU7ohAqA2Fi1ZSmY4rsC
# DATA H/vBJSFM1Zmmm1fo5hhTKJlqooCxd20p0mTTE33jQvB6GKtZEu0U2e0wTFou8c+kf+YP8pW0JmJe51MFoLjSkSR8DU/FrHnd0lxW
# DATA dt7B0Ze7hwfPBnvHL14eH+0fnclolndjh3wKZYIXOCjd5AwaVulCw2UaF5K7+5iI/j6QXh2d7j7fHzzbf3l4/PWLNSBZfeZQjLVK
# DATA o4DDZxTXLuIENkiwsgQTSoAC+6LsMoKSaA7f1ObqMDDygK27M/hv9+7PkBN8U0Ph4/CDIsNFsQhJ+/JLe0EU3aIKUhvSNX+bdH/n
# DATA 5vVsWirqQF8yucJnuIIG/4r9lSsXtjZrcLSi1OK+8CxhQb3g0sM+hK2fJT+L/R/5W/7HfqPebKs/NoZN5/eu8uH+57t7XwPdHT0/
# DATA +HxwdnwMrP/k8/2S2ihqp2Ks2Sj1vAv0syQjgFlmm99FybnEOz/mnB5H1HuhBQPQMN70bAiirLgnvwbkXanNSVSUPubVzIkI7sFB
# DATA e04IryPsk/3PD07PTr621tTAWkNTCFQV8amRAlPmsSrcPuDzzZi3ohQf241kunLtV3RakqUgXiIKzbEvxuIYL0xwnW2B3KQcVZO6
# DATA tDhYFj8X9bnQ1GfAKV2MfYv0vstRYAX4tITZ1TzF7/t7PIS5kyqZCip0oGaRpjV/lxl3xLWcsFJMtpCSJsFU+lLeoaqPXhlW16uS
# DATA Wc0XeKEPgKufWlc8ZYsUDVXt2/BMPralutquTeaaFVJdBUxk0h9TEqsyw+DZNN2kgjAzvDI31r8BnJuEiKXKxt3c5Gxf/MxkSUDo
# DATA ald5xdd44yyHj7SJlpNZVtavgnifYhmcQZCFSbJD1gG/yh6ogbLP3tLqyakW2ArWV9wPqoxbWTymFt9+YrlPi3IijfcoJxwd0rpb
# DATA AUolDThDEVt1HWSawZLEvEymb8jwK1UqBSqj6d7Z+C5fXc+EVzxBj2Klq9tmlY+cHr862dtfxzoNT9Hr/ckOhWpBrxLNKYgGi/jN
# DATA ogyPU9RndjC4urklPczwgvQ5pTqdL9LXsZSNpU/EYTCKF6HVMy+VSud//k22UXp797R68Ql8rVoDsyv2Y3IY8evQT+nT3Pdz850Z
# DATA NG1HGv0+G3uN++PR9jfCZvV/hp7aqrhpLY+tAxIg8tz2fGV5oCx3t95X93q8vaJd8AiX9O/khb4QfUoQIFbHOocnz32FnJHo17gt
# DATA V4wUs1/xZPkqQ6jklDhrGPXaDu/MdK7LjbCvQ0yXrGDj5LweK56PR6iL1mO1gzWkSglnKXSPfnafdacbOSuxpjOjLcrQZqvdMzyq
# DATA cRJHrMnfEEWTOSqKu72i5o1fBLnEBdYm/RSQSllDCFui9kRzHP5FO64qH66O8iqLVWUx67nYQWL0liyfgEXP+m358ITedLn6vMh8
# DATA Kcvvyqy12P3ctmceq/t9trv341cvBy93z74oVXLgFVjfa+xtaR9eQdsyNRXVUJvZep7lEluzm6wKFBrXzssrUIhoTPjI4vnbEp1U
# DATA 27YXViXvbatQcI2CxvwrL3nehVrCAVQvRijir/4f+TBwr3e3ZieK211G4pweNXNQ4EEHS7ByqLLB3loK5jbRoOE/qJixy3ebZ3hX
# DATA EXZ/zWbDhSp/4fJG3sYxXXoHsP0smZUNfFXuao0CkKewtRjzP9rhEc4Vei8eoxyIVoDVJz/ffzZ49urk4Ojzwe7J3hcHX+ZVhAI/
# DATA iu0lchsTTpR5YrgUe/j9z4Cj7KvSBqvIYmaF5TmBxVFPlUKBQmMXbLZ7dSuy0ovgV3NzeSrhjJkKZiyVS+/+7/d/8+4X7//q/d++
# DATA +6X/7p/f/ebdb9/96t2v+OOv3/9n+PLf3//8/V9Bm/+FH/z23S/h6y/f/Rr+/jX+ff+3nICF5KU8Uk6UStVrlAj7OA6my9nAGGt5
# DATA h6YT7FnJq0C/TubrLA+0DplPk96cGcp11V/XWeTwR0pgXrGBkYEov1zNMjfWEfS3t4BXFGu3K55XoXHMEsWePWppbz/+mO1cy7m2
# DATA XeQdu8tZz4RLWg2jpF3c65PgoeN4umKTc91hZc64ZoRl4SynpMdhDj6b3ZZ7mnIP2fNmJoInXArlXKHypdmfv2Pyegq8eXmTWzn3
# DATA 9OukkMbTxzmkH/LAVqxUj3hKXgE9knLmTtHUHYOdlN8dJinoQZfot/J+rvfgiuNozV5xwgr2hmFK2PGL3DreKkWYpa44S+0roiog
# DATA nPvmqedHgZWDo9Oz3cPD/WcCHIXVF3gD1n3O3qqasobm4V0Bs4LOUXnn7re/PZV8QPxnNSMMerXgEZMBMUtTQu/YOCp0XX+bIBD2
# DATA ReLHzPb7/v4bPF2ZLKi60XwajJ9INUSjjHBeDV2Ok4z5UheWud8eaUUIwAFkujr+xKuzggFsZnSzKL5WKHN/fYQz3wT4LNU3cdIf
# DATA iArt7AehQZVPcMGsUUB1dASrF37sYON+NzTHG58d4NUfxydfw+YYvDrdNxAWjUd3i2uUPRjQMJM/Qz8Nb0I9onK6SIYFyK7QCrBa
# DATA vm48dve4BI7K45Iz8ghmMTe8VXkA6Or73YeUzoBB+dbEZNA7myoVCvAW0nhalq/EAfG7AYzGRLN2dYuWznc3/yzY/BmeADMfB7XN
# DATA i7f1aqPZuytVJd9trp02SkGyBniM0Hh5cvwnsIRAMXgPjFlJyrff8QvcwPyYQjvFCQqS9fB78xU7OU2oq9g4/SGrLwxfkdPqgagd
# DATA a3V4KYtGDd+zo3YTB1F3cvmlPF7VlkLcXEo+WGmfzOjWNTx3XcUXHPaZC0tAWc2UuakoE1hdSXS7fBd4Vvv2Jd7rQP2sGeG8rm1R
# DATA TPLAAR2nc5Vp3SBZpd6S5vJQxsiFaA4cc8j37XZMa2o7hrgT2dHkG1nNECixf4DSA8gx4GZFrHcV8PsPZAtUCsx0gcRSmyTSqYx1
# DATA a5+se1Otnvsif7v/TSwOaLwCaFWJQwCTvLGeTyrfhbiw+I4sxrbCKDo7eEWoLX0Sp4E6TcNFLrzimEaehFZtMAHe3iQsG9lT6pno
# DATA sQx3rvxqeHQwQF/kYJFytjvSbjnn869U73O6qGjbs3gU0L1rYLOP8RoBXcwQf5mr0qh4lNAce2CHCF2HUlsJqKiJTePlYh6MB2qC
# DATA qr+MZ3lO+udM3JFr8WYHGH+fmFhHS+TiydGghqNiBaDntwPN8S2qUFh5RNx5+/dkcku6ob9qTesmU0DTQLUrOJ9hc2ElWcwrH+0U
# DATA BQhyaCleM7K/adFMwFA55SznvZQBEqvduD1EUYZ1VlaNxQXkmOCmMW5WnXw5gYwbnSWqJDfil1YdcwctCWqjIac2uiiQh67nTQFr
# DATA 7XBQv6VN/pHChRPcsEWDpsXtFY+fr6wxiZEWuimLAddOw+WUqc8oBM4+uVfkVlkRsKnsZlCkNInUraysinrhQVVJMrpdvwvx7LwT
# DATA Y6Xj5UxrVmCiZfrLcJmMI/42W3JWKlV81g0oUxcpQ0ZyRhcp8tjRI63GhTEod0zvHwzXxzKq6881mbJu7q+BovC11dAr97NKKFIp
# DATA oqxbnysr4qLQgji/z3q48Fazp+Tw6o6lB/EZ/KJTJpLnsxaY/ek1Q4LBVeBc0l6Ncm9zGyXnpQOsD84+OvO2/Fh8gKXQi08XGJ4M
# DATA 6ObFg7OvlUe/IBMM+MRAgsO+Brws2T1HGK0BSSdfn8V4q7Gk+Eiyus0v1sTJrRg5x5F5vAJgkHx+V2Aeito/Hhp2+GiAPtqx4Xvs
# DATA Yjw73vsxrMSXx4evXuw/ZkGUMm5sbDz4fapIuXhcy8aQ2ZPpYRNWVHLPrimJWbVPJznSVRkchVJAVA/Vi+cu44dJfu3P4b7s8wpa
# DATA tVm9oyJ7UiqQMA/EOxI6cb64LSA9gFnmRlLKJBmrd8pmXpWioEaxONMdVy28FC+7BuEjhqF4rXOKi4pr6LcL00XXSF4KwoFGtP3A
# DATA JNbD77ZjmKr+ivR1msnZeCWjHZl+f0iQ0m6u8xLY0b7ygrFQK/hwtYzj2FR/YPu+emv+vepL0bLrl+/Rm5xBipfRVuKqfhmNlCqW
# DATA ZIkrjkpXvKkf0MS4T6vLlZddrRStpoIEf6Wl3p/or1utUV9/F+aVo1aXh61YyU4Kgbvrtn8Piq/aPJYf4zF656rOqbTID9T0Pljn
# DATA /O70zaITZisNTWzeqKf5oFJxFEQzInUmyXtU1MhuLNES6cnz8KbBAcmPwYDUjMEA5fhgIMe4qWrDnA61cAWH2u78comhnJf0pBzF
# DATA WoTtDAbASwaDivUmBj0HgbxSBkQieFhoFxSbnZfEruX2k8jyqK151z5DEl6liOSd88ccD7m4v1vOVNg0+VUB1dTbKVHBpwEWK1Tu
# DATA 3TkVjpaO6A92pZIcHQ5PDOUyq6lECOk+R6OrWRL0Eq8iv68Dcd56WahLFZh48iP6sRNE/q93v3j39+9+8/5/fferd/8D80J+gRkj
# DATA 7/7nu9+8+++c+CFlM1ePx4gwLBuFsuofn8qHH8e39GnFs356CxOe7L/BA6jv/p93v4Wx/+r93737R4HhH2DwX8PfX/rv/zN8/B8E
# DATA yT/4mI/iv/sn+OUfMEHl/f9GKSq/qfnv/s/3f4Ut6Nf/CrBDs9/CT9QTfP31+7/Fef2/lOXya5zZU//dr97/NQ787n++/6/v/un9
# DATA z6Gvf6EMGTXk+7+VATF15r9QX7+CTz9//7+//5v3f/3+72pAF/8O679cxeMZifzpAq+XJQ3xO77/sdtqdnP1fxq9duMP9X++i39Y
# DATA oGyDPNmSjrex7W80uo1hqxuNWp16d9gNO3Fc70TNoNnoBaMgDDujfrwVdYNupx7HW73+aDhqx1Gn34Flq4dxs72B+Y8b5DTeUBf1
# DATA bMh9ihvm5p4NqqYIP7RaW70tlTO5YeBo9/qN3iiCboNhFNTDaNRtRcO43u8F3VGzAW/1w06n1e9Eo3qv3Ru24l49bnTjYdDqjoKo
# DATA s6Fuv6F+9VWnRSD0+q0CALpx3AhaQRCHw2hr2BtuBdFWL46G3WazHza6nWEjitpBA/DVaGApqyBqtltBexTWw+5WtBW5ANh37RXB
# DATA sNXpdQqAiHvDXrsN2O82tnrDfjzqBN1u2A+acasdwoSjdrPTGsIiREG41d+qR0E/3Gr1+0F72Go3+sMcEAUFv4qAafRgDxahJNrq
# DATA 1BtxtzkcwaK0eu1hN+rG3Van3WqP8JKlqB6M6k3AWavfAEQ0R4CrOGo0Wq1ePApDFxpmP4MhXbG5DpJGp5A6+i2gjH69BbTXbQad
# DATA zrBXb0dbjRagqdkNGmFzqzXqNbtbw243iFqdGDDTbnbbUb/Xa/TDqOVCQvfcDUQIr4Gk3esWomRr2G80I7xYCvbKsBn1AaQh7JB+
# DATA p9cadqJ6vdkLesOw3u03YRW3Op2w3wygUdzqhL0oLAAkWwNBv1tIIlEY18Nhs98ZhbBBW1tBJ6xvdYEWelvDer3XHTYa8XAUdrpN
# DATA ACbYqm8BqYb1Xm847PX6nTC3UUBVBhDouGgxFLCUjV4BGL1+POx3WgBKozEcRu1GM2xEXdilQbfXCuN2pz5sN4MY0ATk2dnqdcN6
# DATA q1nvD/vNuBv1oxUw5j8bBtN1VNFutJsFMMA6jFrD4RC4E3Rf74/i/qjZ7jVHYaM+ardHW50whtWo9/r90Wg07Af9Zr+31d5qdeN2
# DATA vdltujDQ7Xsj0HJuwI5eB0mnXi+iTyCKeNjrt4GXxkAh0bAZhq1ep9lpw5bY2hq2gFe0YWM0u2HYaPTjfguAbva7re7WaNgZtgog
# DATA ycDqWr8mhfsVeHN7aytotZtA/72wC7Puxd36sNNqtuI+/N7qACj9TrMxBISGW0E7GnY67U4zbEewt3proBiEwMzG6eUaaIDS+oWU
# DATA 2ugOR/1RpxPXgygeAt57gAngm1ErrAfdYbsfNzod4CHDqA6kCnKmCzKlG3SGw0YYxI26Cw4p/ANJykwWt+v2bbtTtEBAcg1gDGED
# DATA /tfttNvdsN2OO+1gFHc7vXonbkTAW0f9RieGTRpFzcZW3G/XG1utXrMR96McLMo0LgYBeE6rCIa4sxWMgB8BX+h1t2AzAKX2Ol3A
# DATA UQuoJmy1u31AQIRyDbjXKIK9FA0DoNigD+x31HVh4OqlA5Ln63DRaBTu3H6702m0+iDdW3HY7wJrb9TjrQYQT6vebodD4FSjfrPb
# DATA GdXjZn1r1NqKga+3wh7eRJfnpbbZtU7YtWF1C5l6E4VsDAOHQbcVBs0W0Gw7CkCy9bpR3O/Avu2CfG9320G/BcKuC+wmbkYRvBQ2
# DATA OusBGZh7LNetUb2QZPv1RlCPg62tRjBsA0/bAm7biDoN+KHfGYYNwAiQ6HAL+EujFwbhqN4Nu6CCNOvtLaTie0CKUjSx1/F62KJF
# DATA O6jdr3cAHfEwBPoFLS0YNhvBqNUFIoVN3AW09bv1LkAHkrrbAMaHUMftRq9ZD1bYSnEBw3WcrrnVbxeBFIDcaYIaPwp7bdgm7Q5s
# DATA j3YX7zoE3IEwBB4U9GHBotYIVKleswV6JMhimEPQa3TvA2l2jzBsAc8r5DFBfxhGsKdC4PBhAMABa4tCYEnNTtjsdftDlDiwOkDf
# DATA wxEuay+oN0GNDYArbfVyLG8xXiuM21vdIrbS6PeAKEDegmwdNpodIJsQWD+gAcRSrx6OtkCDBAIZtaNmHAz7/QhatkAiD7v1XitH
# DATA L8vRzeByGcyjdZwWyKFIJxm1gkYLtmwnhE0UNEadLVB5gqDbCBugKI1GsFZbUR+garZBgDXCPqjS4VanAfuqU9/KKY3sJNqEtViv
# DATA E3RAAy8ApN4Pg2Er6sBYIaxE1Ag6wDGao06zHwDzaHUDwEpzCIRT3wLWChQcg6rWixqj4dZWFG9t6JsPCJgNvtkJiZG+XvPFu7Ts
# DATA tWat0QEBfud97w//Psj+Nwr4v8H9313QzvL2P6gif7D//23r/36GtSKCqa8OXcwl4U3K/2LpoGQyWZLGUfXT0YhqpDE9+WGK9wje
# DATA V/eXr+dU3+L5fJqqL5c/S2bqM150M06G6muS/u7Fga+Wi2Ss6wMHc/RT6K/xZGZ/55LBmJ9wsrt3hrdeFDnMSt7z4+Oz/RNMzih9
# DATA M/2+f7L/4mh379Xp2eCL/cOX+yengy8b30Cz/aNn1Ob7PnwarGu1e7T3xfEJ3WhOrlo8ITYfbpQ/nVT+nFsOPnt19Oxwf3D6xS6w
# DATA 2Z2SfQtI6QcbFe/5weH+KaajlPIbvMR5nqKq4jfbLZF3mhf95qgJ9uXFJWOx4TvakKXbI8fqU06W6JaW7a1c+Lbl5QyU03NXIJxZ
# DATA I6/XAVeeanWM0FLgKMHfHeuYJmRJaL7TcsUo0RMSA875bplS+Lv4yfCj9liVKt6L3Z8MTna/wtLyXbeIBj3CBYdnzdyj3MmyqIyL
# DATA reoaYmXuKA4BjrJTEUMiQ/RcXXEy5MtNqkTgukyd3FZidSrvyratyRFfaoAZ1eqyXHlfpPfgdaxuW9721halK1GtKfWf8qfbm9bp
# DATA B/x+Xtu8sH+qfFz5tKRipPeecZD7C4R5CVS6OBPm6w/whoRYXechiZoY9lnQ1ZHl0qY6REO5F6OEj4gtljPYvFhjHEMrGOGV0otY
# DATA jyjJAB1Yz5Erx5QbXKeo4t1XfUCd3TTQqNKdtZLu2llHhgHvpEn46NjcfgVv/UVcD9N0XDadwq/WTHSpbCAV2nSCTpYIOzaB8WO1
# DATA irxDQ0xpKjOPrPg/8hv3LcYzfTOfLMcoTRfx3JxREl6LRUemTpiNvlalvS/nyWWqMni+7CG3rcXTiLN3gC0/mGN8YG5nKoJQLRSJ
# DATA w2QqD8+3N/FUD/Z/wSDh86ISyghWGR/aWUUoMp7tnu36JamgaG8MfLi3u/fFvm/LAdog6nureUd7AfutVB5zsv7VNH4z43tDnFn6
# DATA clWRWQ+cF4ssXSmHiYAyC+9d6xdyIaPRMWSsYBqCAuHyI17OOV4ePiszG/I/YX4k9KkgdmhU3s5BaJFy5bwuS1IebpQ2KueNC80W
# DATA qTiUZnc6oeWeAUCgQDfFYnqD4K2XgDt32/gZhqvau8rUSQ5U9ZRJ8CaZLCc7iskbDvlgwc380fJV/H/B2KbTDlgxDHNSluNgTjUd
# DATA zBl/69A5UiMPkM5g3UtAfBU/yLBZHEzMWHQF3o78TKcQyjIT6LPh0A4JB+AK8vwR8FKts0Wa+mPMtHGpJC/r9HULXCejPA+sSxZw
# DATA ePwBRm81e92tx+BKOloZX2ZsnXPDnvVx51jEJO6JtyW2YukObRE2Vazib8JwJV2r446uK4VXz9VbFw/uq1fTbDmbUTaq2lEK7lLl
# DATA X1/CMnRqJhffXtYWQ+Vot2o0B1kfNCQLLbpw3K32wh0z1p2SPVbpKXqqKk/JfsO1JYVbnyrkkijqaKd8Qxq7H8y8XGErqlTx3FQ5
# DATA pQLwqZyVtLFiJOLqmROimxewxvDT7PYvQcOv/KUonX/JGuc3oHJW5OjoI8Shg10EimrmrMhaC4tcrEIjEVFGaotsDr0DyLnEO+Bh
# DATA usAeTPWYD4Vb5cy6cGNyUpk7ZlgwJzuTc4cLBVfd/6HvNEI6UAz7A+HAQnlmN2TLiTu8owMyAai6HUhhYiU8go8xba3jorgVLFnE
# DATA leIloQzYWlXKkknZREcOvsXV32YRRqfndXUmPq2ji5zR2XI5wPO22OyRy8Yk7XG1So99Bsjh8Hob3ylLQ+6rK4uSSJOwKxcJ+3Z6
# DATA 0RV/2WohSYF1ilw1g/gzt8grCNS8iF/dzwdchwviyWEIfpRyETXcByVHxAir+WhHCxyNifvPM69qe3yx+BrW4/S8yoL05Ze2OKbW
# DATA fGSlslJvXu6/RMhdereQu9KmuFLUepJXVzNO8L5SwJ110eka4tfX7a2QDbAvc55Dpn4PkZni0fqlguTblQ5wE1mvwCZQvqgqayyV
# DATA qr1BraY0eiVfHENKIRoY1tQ/M0e6ZSVxj378scxcwbCNY9ytLr8+h+iC7hy/k5RpTq+nxS5btKLWupJvr6rAdRFU0fonwziKclq/
# DATA pVTn7EY5M56zHfMV+O4xIqugv4KNYFt0YgzjoBE5+Ep8zyWaW+e97YsCg9AxAmkbrDf5HOVIDSPKhXxF5t9dV1x1vdBRuCuQPj9L
# DATA 5CQ+e2prw25brCIZsqrJ1crXJfsAHbi1z+E/eHyZ9n06/OlOktY+w3U+OC5z35VCywFIKmc4KNdX3nAQzf0RMm/fnWa2IvaUCihn
# DATA lmkW4hpmQ6dgEjg8ny7YKc232QySDGwDywQxTK4gVXEQqFh+LK+wQXlAumLrIa52BnMAcXWbX8Qs54jgTklEcveFLgd+BmajVPrV
# DATA L9akdK/2MponSvQy9rDGyJOSGaemK498803+58d5IPCa8RUSFTyW8iddULhYI1xYKI/fkK+eZsZNKkxZ6oaOm4E263ZEq5qls7Li
# DATA c5V13F2/5rB5dVXT6nOtUk2jeF4kU8IAhJRdDe8hkZIuF7MlnRswhFl5gIb5HUW6N2sot1AGyAnHh0RB3qs1HaV80IiAOQvmB/BL
# DATA eVWfw4ZEb1X+iBCqjxix8HccbaHqgyBot+FP0bEczO6nJcf3qzaCXOli8W3N6fi3MjEytMrmcZaVGW+4gUnlxooKBNVOXVfUFqHB
# DATA gkJXbcNFfcg+e9B1R718qFVDL/k5e0zA/IQjUew5pIIo2LgmU1euL+1iy78pIs6IKbyRl1F5ngB9v9mm/yLXrtcvVDdsv9ADPAIV
# DATA TC9j9I7bkqyKL7j1JC1pDh0pKDCIpvQ0rl/OUS6xU6i9vZfWeau1o1qZduaWBV2wQnson+hPNXQgcIEN1l8qmp1Q7E7sH+ftUoEG
# DATA p8gkZ8Bodwrqu7qnL/dPTg+Oj9TAXNmjxj7Rx7j6pFcpJMbRDPVbgVmh5WLOqLOsuQ8y4VxM8N1BjzHiHsMKbTex/VSRCN6sTZU2
# DATA 1HkmpwromgV2CIfI0JRVcVb9u8YUOZwEMbJ+jyUT297VrkhMqDHeyG3Vad4tub3W1HVrHutCw4KPt6WVDjQTF1tv2+Htd/cKIMf1
# DATA Vbm7szZe2brtASdZpXcwxKjudUL2M13sNPWl7ornSTnkFReAWv9Huvgtd4HuWXv7LZuET21bBpD17H7WUXFeIzjVjZDUWm0R9heI
# DATA 7BgwW2Qppnw2hleJb2ENf1LkbRmbqnONpkeYv3QjG5c5mpcNVNYdbxRn/uZNvc6RLtNmTR2gR4pAc1JNXZyk+2UT+J6rv0RTAvu4
# DATA 05HTfcrANd0A4qx19x4qjLNyAtw0LgrprK2/+Gg0XMbTWF124+VuXV31OeiD1Pe6G1T5SdfToM4A6nN/9mHAgjOAXILrJahY8fya
# DATA C21FAWaERBbQNV8qxfmUOJLBLr2Vq26oHmauN0lSwh321JccBrqCAeAFXReWakRFNBcmh8mQSK2gfFF+rcu2T/D++nGi760nhRhz
# DATA jQLiMFQOTCUhIWXiZwzLj5I3O6WaGHibGAVJ5jvWBqqsp6zf0Zmja44bOEUeOUxI8e3HvKedOO222143NdX+1Za7t3RCmumz96qH
# DATA 4qIdQptCmmj3xPih8KZmelKjzDTlNHpL32r7+z85OIUtId9AhO+/eHn29d09JVZWnnzf353SXUtW8Buvb5oth+Mku6JtkKGsN3tA
# DATA 3S96lWQF3c3maQhWCh7Gp/IhC9gy8RKYAl/p56vgkkrswOIPkqZXNPvfhRndz5CAUtRx9wLexPVQCPdFF0T/67KqwvoYOHlNh+sL
# DATA JDjN8mgyT+T2CnOPykc2J7F+V8jVbyI9O5VlzPZ/NM7Fh6K8e0AayEIl066gEgwnR9bmk8U8tjaT7WtwVY+1ngwhEtrwzuuOB9dO
# DATA U6IXdLgeTMvK76XwQDpTtGaXDkDrgOqpYYygVNV61wMFA/I1DO5tTFh6dGsJ/j66OdLUh8HDC7La/IHSBqqagUYkVYsgBBqyJGtL
# DATA 1x0QNXpc/Crj3HrXMeZXOrELHnDJAqX1UlNJE7IMNF31gPVV/mJpxAwSq8WVhwthMG3+/+SMQT719rvP/280mq3GSv5/vfuH/P/v
# DATA 4t/GxsZJjBWq/Gw5owtr4siqjMw53FLLOkCnACaERtA4RGVjtBzbd9Pek+5P6fofkKS/HIo+o3+51R/R5+p5J/svj08Pzo5PDijT
# DATA nQ8kSQkY9DdcXoXzWpI+GaeLBZj0T8wFtrpMzMpP+Wub1vexWlnG6a/g5hXunEvT3A+fql6T+wV6uPP4NkSasDXXq8Vilm0/eXIJ
# DATA esJyiB5r3e1Jbo53ziQNOI/qguG48w5e7H6OtQFzZxTEx7N9Xt/sB5sjTsypeM/2d58dHhxhfjrFV1UQZJZmCVU60jcamMy80h+X
# DATA nCvfViK15iJqyWX+4xIFZlWR8nyruTTb1s0UGED9wXiA5bLLTO6Y6p0uKBti9RYWXV7HunOIXkNw+X3L1a9TqDFCgw+5mONBxLco
# DATA 5mMCCq9WZMB0QSqi1SPfK8BwPnBLjXMbatkC5AQW4Sy4zEx1z09Wnj8jS9c0MRV7b9DneA6dS4mzkXtLH5dItFeZKrvZG/dco/fi
# DATA wkYGdJ0vInx5ScXMpLuEna357i046IASE5K5P/Au5ycg3ocqMZpbZA3gSHQVrgW6H4yzlCmFLKtMXD3wexJkcVbL9bp7nYKdE2Sv
# DATA sednVFQPPRLcAZ6povegI/+nmHnLv0fYcTweuZ0V47hwbpwY7uJDnhZg76KgaJSqzGgRHaaM4wmPJFzUkH2jGxWvMq5UbI/PWMe0
# DATA 1Npvr7kN06KtR16ykc4vKXxpLgepcSdyHem6OzRh2sIsLSIrujdz7czPzZcLNx7FL6lDMLTA5Y9RjaySoBuwMpnLjkO9ke9NaNUR
# DATA Ts0WnXu99a+bJOdqkxQQi572snWNjOrqhzt+Pe8KPePikMroJtYk+h3I6iCiNBRQj0H/jcxtLOQ62LHkbm2+nJbPpSQklrnD6V1U
# DATA OYlK3KJhMFvgFcoyXf4RYw3qI4OyMwGFuVWvGsArTh6HGjFbRNCaMlnaj09lkf0FSwJrDM/QxRNHmZ7zOJkkCze70crRzo8NIFkr
# DATA yEvitpFVHyJ3BuuCsy/V3XV8YxVf0+kEN6UZxzbNdG6TeBzxYSKs5w9vbvP7HDWVsbCa34BlizKKEyoAL6RXUpUKAy5NqEuBO0lG
# DATA aqlZYqxc33Y5T5d0A4GaGQxhX5qnXtS3T8vYYHxh5mD+Cpa3b2tEe3eYmvsxde6C46yI7t29MrBsFS/kKplSmPZ1HM8EOLw+ANi2
# DATA 2jf0m6Vx5DcRYrZZX8GFg2JFnNaQlnUqKYGZm+xPnlvrBSfydl8utO6PWe2DEf6XUtHfqkuuukBOkrCXzb5vNb9ynDypCnfbCcUa
# DATA lvXX4Lo3MduJ3BhSLlJg8Kgbaz0T0ZNLFesKci0zEABc1+0HIY9yYGtSVAMYmtS9u5yZEtaKDuwVSLuV3sfFu03VCl0A5wxze89l
# DATA eNaQdBwOrd77WJzO9BJzDOc+TJdTstUcX540cLTTgo1thrd0VT6uize2gSC8B6W8mdfiU2kzO5KVM3K01qqjH04/WP1Wntf8rv7R
# DATA jt7020VFLU+0zBQUAePBzRNtrxeO7MvcAcsTWX88n7uqxhDavb43oOcq6wVc/MFrxL/va/E2gvcRZZvo02eLI4rHMVqYT4Gn+FTG
# DATA tqrY4QyIkJLvpPq7q1WurO58QpVszV32Oe2Ql/STHb/xuDCfpUec6o9FgT9ZHlZTzJrIrMN0OeYL6NCNPb5VKnSyWLc43N+otIeL
# DATA CiC/FdjvbP+GNmiFGJ7q+rt077hisDlKKVW+jXP6g8vY2ubRh5TEZdmDkUG+zGhH2Zdr2iOrtQrcsgJsva4svQe8wUpSu4Vlxamq
# DATA bjujLySz/4O5V/99+H+z35Pj93H1X5q9Rsv1/9Z7nd4f6r9+V/7fLyWqqvMBhe/JRV7sdBUfCapbi1TY833+3lzdlnvdv1X/JViR
# DATA L9MsebPGG2z5fqVei11/gg86k9ItZ7nYO7OTL0NhJUbzvWukp99/kJkSk66W09fk31sARx8Hk2EUbDtHFCxbtYI1MvIRWoZIqbHU
# DATA n3vkiJ8XVMhQIW8OVS2CS+CmGVhuSnWTy5tpPiZKZqWzWzYKNXiiCrPwZSCrZsoYFrfwPc3dN9nFsr4LK5tVrtbkJEOuCEAnCJzH
# DATA Qnn8HOZ4nzL87r+9+yXX9laFvP8B/vz2/c/f//W7fxbK3Hz3m3d/j1fYv/snLASuK3kI/Jl10C93BbVc/mmfqTPP5HzqI8rM3z04
# DATA A6o1LjOg0uNYgPw3D8yAEqdJt34bnJcorfti2w+ISAMkUCYNnhN/NhcJBbIUdAUn3yS0nOECg2pjruqzRLjkRE8txK2mB80SdFAi
# DATA zZwzPtx7ynEU/plcKYI7x9fLAVuCTZ8GpwtlkqmdBZ3O7ZZ4o0OysBrKDw+eBXz3fyi8cj13wvpv3v8NkRRWcodPWP79/d9QTfj3
# DATA /wUe/yOVn/9neOlf+MhgQQF9IRYLRDqGgHYMMDd1pywTUDCJum0knGA+gQ93D8L837Dw/G+QyN/9PVANwvIbLouPZemBUqzC9Fjv
# DATA /t0/w1R+Dt//di28RDIAYdVELwj28xzcF8UZYXLd2cgKUr3Vo9xtvoVNfLcJ1tTyzeZb7PCuBpy7dvmzUi4da6YcMKN7AmJWz9tv
# DATA GUpd+O9CDcbDlFZsMONwpovzaAnUySTrIZtCzvnex2RZ2twIFgKW4Vfv/uX93xXs4l+seqrvuXP9kej4Y4m4lfhq9vyJeDM9feEm
# DATA u18+dGrMaH/x7h/hyy/f/7WPf/ADkBnM7l6e9fhjLy7EpgoA3pZWXAFAxRvXdkIfVbTtg2cNW+rvfNprv6aJ8u0Q/DPM/efv/gX+
# DATA 7xePWGtixXS5C/Fvgo1TMpWsMfYwpnrSfiiIyL5lnn6+YeI8sAGeiPjM/j/23rW7jfQ8EPRn/oqSvJsC1AB4ldQNCnLYEtvNsURp
# DATA SMruNsXgFIEiWRYIICiAl6Z5jhMnm8mJd5LM7ofZPWd2Nmf3657jdNyJY7vtc+YXqP/C/JJ9bu+13gJASd2e3XEnFlFV7/3y3C+L
# DATA 3cF5HyH6Il2JxcJloOq8MoejwTkwdG1VpT0Z9QSc8hDe07fEqsXUCZdTq48Ahta5zCF7PkBMGPEXAoh/8vqf4fffv/4yghX+gtKP
# DATA /IKygOBJ/M3rX0bfzcYfTw59B+5yKas1B/ZxpYhcVTuCAxXZ588UwUEFU7tzZ/WN7oscBpzAT6YcEiEBFUGi3FVgTzvjItnnJPRB
# DATA kFdt+hTfFJpxwcpvpY1ap+CjwCz/MyHEX8gmcU4VyYESwUbxHYE7E1GrAA8jbtV1pVDD3bdJrwNLU2fEmcoJu4CZ9vFZUuDKBcOE
# DATA b5UCPbSvaKEDmruinJA4kYNLqOHA2Y+rO3foo+MVIwPRVAllYCXCQ39ThIjnD2OPHQoz6o3x0jXVyQteSeyCjmTTPaAqsAXp4yQ7
# DATA VIX/CASUg9EjpSrnVoSPinyarnvVrotWHWcGHIWBF8/5cCD5QXW1QS7ggqiBeOrZ+rsiCQPw1b4zDqxg2gyKIxWH55FT/vzUik1G
# DATA s5qhSHaoTpmTQ3fO1QpKDQvNFKnSwKz/A436z2Aif4vkA9B3RdITXn0OYOWnhId+6S0Jkq9Q66u/sq4ivnRYI4I3OuxidnTZFj9Z
# DATA CTRmn5kswFpbs5onisnuxxt1KBSCexbh/TnsJIN2APJxmeMyDzAeNYF+fMdu9qR7oRhEk9PKKfu668ysVrn3y3BB+Sl+/Xlw8jBv
# DATA 3Kt/R3TFbyLMtIUgE1789vW/WnQDwqjc0dLO6dAvpLkjU6lYnvFFVImG5lneTg7zQW8yFmP0uNEgEyz6ioEu8xJffoVDKzqEALkF
# DATA WHECVFCB+QkwYGiIiITTAesl5Ofv6Pj/LAou7BdxcF5qBvlcXSNu+xyRGOYfg6v015gBja/TjTqnHlHi7vm4o3aRTUBCoQliLZPw
# DATA 8rQKOaNqD0bFU16orMI2BK0oylcegIbT0AziVpV1lOEVGWjx3qnSRTlQjkEYfZM0KLQvIIfZs4ODG1w+AjCaTkFo+AtEDq//CS+a
# DATA BUE1zP0SORq6loqEKWVoGMERdCyLM2FNzKTTLuyp3VBwX0vaefPtFX7mL2DW/8QI9qv/CX7/csZOm5BO1pDtKBrKcNPiCjzxq3IR
# DATA s8WcFlZRvNrsPf6PuK3Ik8G2/gVLZvjSvgG2obnZNJQl9zQuyowcXfQpGvGK/EVttY1Dvx096gHFlnWMChcl2DmZGnJfgmTXjSlH
# DATA 1ymlaXoRDzOp2+sNzlkG6C9cTS2l5vYPtN2rmMcuH1w7lghq7OZG6ld04MjWQhgF6XkOYyzKyvhPdNv+BW9X2dVThBracbScnhcK
# DATA +3Llk9BsDLLhEJ9AJQxy/e1ZLhQ6XRr1Vt2h6/C25slZ2q2wcN/d0du3bz/CEdHewD2fJD2C9F3hU8RKvq90G+OTBCUW4t3GBp4G
# DATA uqLyxMUJOviU5Ho18YiKtABdf2ViUR7qRU1DohT9eEqsF0NVFD7/garQxl+47O+17NBIU6kOFaWLHshKxRCcDMDff0shg8lHat+6
# DATA f6ZcqCiRhCs3h4CqjGC5SYCoUlRUat2CaiJrx1FX4FIxxXbMbTHkxpQwT37ieLdHE/c7FqopEl9pPpr7zRUSElTiw97gkBMhMOtT
# DATA Yr/DCHLOsFPeStwUcbZmIU6XVikEx5JGF8IEJh5aRcZp1CAvbkyq/V7INJ9gYf7dn4IgA6O31D7ybJQ9dRLldMhNruIMAuUGxMk3
# DATA m8GbLYccL1oleaSbQgJMlipyxDbHijAmPPsu3WvHyfF0iyetEJ2vPSNjj38fuchdcdu0ksqKb75pkahz3sLKsvVN06Arh1+uz9Lm
# DATA wCGxJM68Sa79ATfBqu2gVbUS81pbxvH/0HVYvyvkY5dR4VXRg2qGg6P4KdQLQvVwMnY2R7QiEolYf0pzfo52ebaPgzIndvtTwnJ/
# DATA 4ZR4MrBuIaNVf2XU7S0iF0+MSBXxdGmIVMC9ftsMA0pbFlKcTTyzfuNwglFbSprP09J2FKfmr4xmYdXCFJoO5bNXIWxqdkBDtm0t
# DATA CSgi6JX6pBtVHCkfFIyKRPWrM2yPGRntXubA0WxeAH+3/IYWk042o9+H/d/y0vK9e3c9/++lNSj+B/u/b8b+b2+U9HO+lMDQcg4s
# DATA QGTovZSLhwZKE9IRcLDG2RvgFFLOg8mYy1JcESiCFu9JL58/9VtnMLx8+6Ru2TEMXj+Nk/H8nuQq1duohyQ3R55x36ERNmpmaTzy
# DATA jmYUmXIkZqnhr0mffrsp5PAic16WPiDKMbqF4WUnLrpNsjSgtUw0GAkbA6BaTZVTtlmz8rKdIeihH3puPVnAcO62SC//KcAA5WkB
# DATA 2Bt3B2jJDgqvoqcaPDDNa+CgkYlsRN0sOe4PgLDusMwDaGcKOzMeRPnJ4FwfFAJydFCImp3ISNj9jU6M6L6hMmue6FMtGgz5dDoe
# DATA lRLAkZaQc3zZvIxKguOKH7hOy5h/NjjTkP44NcqcvxrzSBXQWuTPxHrkX1GR56Y6UTPjbAgzk/cUR/B/A7PwryhhK3REKkA0U3HN
# DATA 2oJpfVQ6IRXuiIZTKY5HLxNeMYoo2S7IMVbebtRT9WNGP4pmFSzP/tI3uwB27PXvXOMKHLMOFQsc2LidUAAL22pYLoTOy2cfMpO8
# DATA r42Hs2LMh2uR8cyQOMfWArFpBlSmkObJuLHb3nr67PFmhSMdj9v4zdjMYsE/ipYGgBbLQ9OjUZvUBtCCnPeAeNsUnuY5Mf87cak/
# DATA h3UElpT5zl+Rjc1vUYb0O9Qv47YAG/prWNkCT/6br37K+nfkvv+F7RBJYf/rr/597AaCbMtaC6sqq+0YWcT4Km6a84jhQNmTpRlx
# DATA +OeY5KryGP0Yl2d5mRI0ngGvhWJdWQ14QSwmh7RQb+HZTwISHlfTyFJhQfMOXIFMBkV0XX+MfvNegOwJylQsU9kU3pC0tyLlw6Gw
# DATA JasAnpGjAYrVFdDJBcQV6EfqyBUgynnafbL9Pfc8admpLrKz+d1iEf318dbOlK+7zx557ZdKXOcHkHjsCCr9HA/dr+wjyTpy61CG
# DATA DQmnjI+hl/2Kb9X9+6zgKL08N5jYP8B5Z+HOP9KUvoi++gsGamiSO31CcJ3I+vufxX5XLQRWAkhH+mYUIP0KLXjhFZu8VawO7i0B
# DATA AeH18ssI83doI49kOOxdtl1ox3/Qq4wYeQedKiaFijRL8oYQHTFAGdIgZ00Dl9/ne3xQw/fP2juPn20/+RTuKj3B8dp8tPdsR7/Y
# DATA fvbRsydPnv1AgqnaTKjcDyh2RLfD9OloGSvOnbeuOkki9aAERBzUIvWGocOBc8KLAFlpvHRDApKshhgohdNM3RTm/pKtBMnU59di
# DATA boCnAgGw2Doh6OXiFg3hmNXSjoalFwV4F1pVXHKOzWe+mumqBeD4E9QXW/T767EQjKsIjXd6QF06PYsPj2YpxF7RknwgQdvOunYQ
# DATA 94J3QVGuZp0mVixyOmAWvaRd6UbadlbS+KpjH0mfzLm8HZYIIBKeWWlaF0nex1qEmqLWWT0xrWiVUyoZbwo3KLmuUphkjuGgKzIH
# DATA DEAbsBlxKLrgLNiwyhmtIGFvVDDg0LCsmSwUmoZPhbbhnd24s5nqznmi0zkomv8AEPIfiQIk00HVN1ZXBGPxlFRt+s5wHP4caZ3N
# DATA IM1Kix4WvWlwaQprqF2IsAQfqklfxXrtxhoCpZ4HEitT9OM89BwQZQQlvmRtRASICXUIv2YDaqM2IaxCpvv/RAaGZEtIpDf5khRJ
# DATA 5hqPsIbGsPIrxijNTHfRm/0Y5QW78lKbpUrM5fYJsIWKi9PewAgqXKxjWWpLYVj7aoEGpm/0EvhsjNohfDdXIi1ac5Fz0PAbdjpS
# DATA lvTI+LicIjTQwCGS/hGWnYc4pV+pM4FVUFpqfB4Cs3w+GHX1M3ASs3fu74w/xZ/ZwhNX1UWI40vcUSAH/pwt4BlB/IQwwm8i2kgg
# DATA RMRvCUn1r/6KVE7/Ws6A6kBmRmRRqeDYyVdPbVNNpodnAX/96STFSK/482iUHJ+aNCpOaKSyrZBoSyoWGxQQqxQV6YYcJNtp/6yC
# DATA IllJ3m2H13mVXspb3XTIKy0Zw+DRM20U/0nlO830AndkP3o5Pniv+h08B8bVBloU7xn8fKfVuPM/xDYYxXTZKQq5K9IqxzhCKqrx
# DATA 1IOr+IGD4mGSAF2eXUajdhOHjzCkpY+iauyolxznLWpyij5B2sc/KhOySoRM2VXeK3Ygn5xQu1BdFnw4Glxcsvibx+Fc0lr0Kut3
# DATA W3En6XYvYyN30Wtb+c6DW1Za0Ub9oOouLjfH61v5TqGsaDhR1ogWTUSPCq2pYUjFT+DeH/R7AwpfzRUX3FheSEFM+mYb+qF9kOnJ
# DATA FujF37KNwtSo1C8ybMeWH1oJh9yIYHJkcNXY9fE46zs27+rSyQnBRTmt/knlZX6Hot+PSH37Mn+vWtn/k3U4q5X1aiEspWUNwfOR
# DATA ZIb0B+4SbQAvHb9aobh+/Hv1gE9cSIMEpBhhwyXLYLVvh5Pxc5vTObTi3GCIB7Sp4GgVxaCErI/nTHcMAr7tRG20bp2MBQZD3Fx8
# DATA FbMnKjeCr+S3aulKtVTMhuM6V2F0kiN2srJHwvUDBid9wu+yoNwE3bcrkqNRU66vN438PW1h0aBDgx1Uo7r/8tpjbmkdVTQ6ytZe
# DATA PDt2dsHckSbKSZ2Nef4BkQpyl4ghfkEExBdIKxCR8CWxmb/gN58jNfE7slX4HCiKv4W3vyGkM0rRRyJlCLJuMzHEyCATw64aJFDS
# DATA X776m7g8lJ5Ot4nhgGqRJZYp0GmMkrRg2AjhEAC2jDxJX0l4LRQmNq5zCxVSlhfy+xSFo4TKtDyOhmc3uQ99HVCEVi3JKmQWo1zg
# DATA Ks08dUHdFxJQ4a/y+y++Racs8fIEs1rucf/+/fIOKBD7tb0jMHqVWbObKQ8QvR8CPZr2Wgd2bSG8KppPFCSmOuqfUdA01I8TIVkz
# DATA 2ThMIryJ2EBSCaaasaK49VJw0mk0ZTHAmm5zn385oWP3zVkjaa8ZEHIEVEFJPbygaIJUOCoaLTJjMA5P6tEuivJRKhEifrLRoE8c
# DATA Ma8o8A1jzsadByiiEjcHWSck8KC6Xvh9RcDjlpAtmCV7UcBOmBmlErJH5C+/+hBbZgW0lSTlLGwrjwXpNRyKycpz4Lq4zEflWVcb
# DATA g3Pw8EX2Sf0GsjZQIXVDDV3vsc2Bmt+O9k5SwLj5OFKnDm9TMhmfDEYZ3LrsLBXHw356joNaF3KWswmx3muIgWvHg0Ex58aRUk9l
# DATA /bIhkCRllB1TnNqWe71oQywpunbs432vWXDNtwIJzB8RLw1iv758wIFlFRFcRlAz4ampaOhRDTVIKTvGG0E4Y/ECpqUr6KbJ+3bt
# DATA hlU0219+RG3w50Wo5Tr7TvkDMkrHZtUlRZ0AjQoBukQ/1C/dPOhW7NRYLhKHCASE+SM49XVyQjUSEnlNBKAEOpRXcDk8Z1LTiLlB
# DATA NTFvt+4UdncU1yTZlhqlgjho64XXURadJ0M8vUwE5xi1HMUwDaxqGam79kaiTK5gUTVXsTeL78TGFF+FSsyAFhoNBz2xBqN3sAF1
# DATA 0oNPxLzQCStqy16UVXwgZuO+JAhXYoladMeStaBoPOuQ8lnio7jfyXB3V4FJKnDg9Umgswh+bQNwnqsNbw+0yIhi+Wnz/ilQXAWm
# DATA U0JMZcqE3sm0YZY8Bqta4QRUP/vK4vdwMOhV7Eh38psnvTvmXdCAQxJuqdXGo0JEDQHvZqS6p2pNMuMAeiYd4o8KHyNbl6dck7U2
# DATA z63An/1zPpIhNPVkzIRzmXF+bdEaOEgEhkJA46OJNKqgK58NOdYf+WSgR80Q7i/cLKQBDJ0zdxUBCXXpu3F52ouL46tMaYDSPjbG
# DATA F3gZWAlN8yZDWb9EtZBzdoqFQ2AeBW0tLqeWG6RoolIU2Stpmiu8r6E5Svs0BVypXqA2nWhU+xmRijxnfQpxal7JYLW4ztApbLNU
# DATA UV9M9j3dp0P3knbQiHRv6RBFmLjJVNHyaBQfIuxRaJwAWW8w6R71Eoq4GB938JBX5zQY+QWH8iHJHkaL0SGgfkuKoX+M9p7sIlf2
# DATA a+ah0NPdME3QU1eLZUW/MYcKxYij1bLPvSSmhl4RjFOfj9OEpPRI9XaTHtR8uxX4CVsboDzzz5ADRRbVn78ypdBDcoXoOOZd+PZU
# DATA 2VzrcVbDyiOeJM5+zgnONz/khT8X2e2X02b3eVE++/Ov/tKfNcmv6SJYhx4fK/rS6K3lB5/LC6zRc84utba2KgD+YpRcBjuxbyJT
# DATA WvbzjK62uLD09r7pbtZekG7PrDx9QK+UK3cBWAeRDDPqATG5Wa2amdM1aVVWZ2/ff2a5+ld/E20836o5m4UxGCQow8+jT6Dlgh7f
# DATA hGEQPb5sYH6SjFiUOEN1KZYLITUkHvWKg9wDmiNsldVn1JJVykqASq5DPnbxyyva0yptyFEDTWhiBYWroU7MBJpkKMXIetDDxaho
# DATA 9Y2joTGzZ7guwZuMnmYOFbA2pwsu5YJnOG70SNYC2I2+GFHM7/0Y5r6/dHCzsRR6s1cZ9+oxT7PYluwkK7HwekjJqmtCCIvJ8tA5
# DATA 1mTaBC3gxhvkLst+scaBsxjTB6Vxyuw7+B9N8JOwhHKqGrMRvf4Hgqp/RQYXP0dd2RdUnD3HWEesVGwYPO9LqsrvBSv9XF7+SkeT
# DATA 4SXxSA54ScI7/MjbFKtVMHRKS6+GS5BozOvg5JDXWXGJ/h9yNPtze2nYHIlCxxj7PFYJWqDoMOm8mgwtZT6/YHsCuXF1J2bgjPS2
# DATA XF+yKKtEyWieZGdUNvJAYiGIXGWjP4pZqlhkgmJNm3yJYengDfyLFn98/JuGyCzJOX5N2bOQVNKPzBk0gZeDh+EJRhttwg8mYylA
# DATA HE9EhsUP1etZqCpITtkZDDiWeNvgZh+DT8fMngWBQ+BUCziSJbpGUQaMrNOzRUgoc9MZTWRHoTncanlte15PxJPgx48AwZxTGk1X
# DATA Hl5s0+IM3aZ5C9KjI0A9KGJric2Fsym3whBPckQUcSnN8koP2kFX6hTGwRxvtrWDiihgiRlc2QIcN6+EFRbMEzNAWdGzkjx5GhP4
# DATA CIux2NtTSuxLeAdh1oMiHr2UVQmWLI0rW/pinypbygWWoTNYZ8Xm9FivPJtZN4jbFcq7VFRtDpgOp1CL2tZlOhql+UlFeVvq0dd8
# DATA 2qU2RRzu75X2ZWZbojbDn5bLZ6rlDjdJs8PDr4cd+GyF06FouvOP0NREdSLHNc76jTwdSxj/SiwJIFiM5UZ8IGU2hl2gys1w2nP6
# DATA yDeI38VVT99BJRx9B9fRGffQwIMtQmLdnYMuC3mn6YwsniWjxV52aEKfLgICjee30f2/NCOlkSPHLP0Zm2D+I/tFaAdtbWz5KzRm
# DATA B/qBTTK/QIYcqIr/ZHNqTER8QU7dNn3yubK+gX//vR0pidZYCaauYvS/RSBzmFHWhViymTH2MXcSbnsnHWH2PSgj698sXRpCe0m3
# DATA jSm/FcFtRRRDKWov+yzttvVx2ZdDMH1DpysgvckwaqEDYCWvXlRQVw6kM+fCeVk6sKcbOE7X04cUON7T5oghSKyzeWClIkbDWWuh
# DATA nIaLC6qn7t6XktMMsMsNhY38rXRpoi7ICx2ygBbbmCjrEyTrqq3//XoqXx4xkubjPjdIgS5kAxXzROjALilNAM3veFbNaQT9n3zj
# DATA AnIC+EuyLfgSbRUVuf+rqdbScqXX2bTgtxL08WdMvbNBXMlaOzmxLi7NLZgFv/c1FD0INrG/whE1HBG4Xreqd5zaypghsLJOPPHw
# DATA Hsk+e9Y1JXoC0tdYMT0NpqFcUPpg78e7MgL3iDsqgqc0WRNR3jrqj1MUjXJe9annXQQ8uqJ0Wy0YAHHAOBol34UbOZ1oG1jyrviZ
# DATA c1aQ00MUIMaT4ePlB/5xdk7GZZstwYit6yIp4DRxBkta/FouiBcCmgpvkIE9EdCuM4fdlk+JdLtp9zkeUKqHeMArwWobOFguEYql
# DATA 92eowmqRRbVkRzcm4Ep2bce2J5KYKJ7lkYoy/D+z2Njj1SlaIzkNFiUAX86Dun8pYWTdeC4s1/sFObhh8O/fGllyYOahCftfFBFA
# DATA 1R0dNpYUFaXZQe9scGtKM2ZRmN4HaqfAn3jeZUUL05soHKlrL4B56fDeXvtIVLwcafpl+BJ1MW3CqcLWlw1ULc7gVCyGaha7Ugnv
# DATA kasosWQBRSVcSQMkTTDmbXpWTnoVBISK46HZqcBAJCCZLkt4A1GCN4FZXgiFqJJwWbdxlL514M89Onkdb554QMnt/OrvtY07ytad
# DATA 4lp49zlBd1tep4R4vsmiZIohueEvid6wA0Aqs+3QyhqF5rzSE1q1gHmt9GKZXM/c7xpLvswY4vkZbxmCb1ujO7LtgNnWplskYkiP
# DATA H74Tkn7egDluY98RauNddeTDjt3dVfzRzrPtvfbm9uP242dPN7a2kYuwlQHWzJ9vbG8+McXUF0PXoLiak2Vbvifw0ltENsNDBxLM
# DATA eDpd4H9QdTA89uBBYzXpomxcBOg+XUOjvNWaVxLvrhmQaS8+bD9/8eGTrUdqKVRHZPpcdKxww8BNMzDc77Mlil6XfVeaRTx8n2Rt
# DATA RNOdJ2dpPRDWStsoLujAP4GzGjg4loojeG6koEqjZUOwFvuK22CvZSsCPVVkSysGq8VhFEkih2YqJYxujMlVh4Pzftp1OgyZNNlk
# DATA mVujFt6uas0R1h1UrQ2Z4en4xlcpdBEOFt7gtnyTx/UqcKuaU+7UtbvVcioLV/mpirVSuvHh0mgYW3ILaO9Ys2FiZlpemM2Ft+9j
# DATA 9kZ9HRDWRZW6/7JBitmT6HgO9kmVRE9VOkpcP2SdJaUWCryQAitsYqpGQJbCYpJsuac+1qppC2h5Uf4YlFsWytLmtc7RB+ev27Zg
# DATA o1b5lt1QRvC6BrfDCsVWZOuSWBqoqWkugwMkY6bp5EMyGQ9i3zz47dUtdrulxll2SgeZlimo46R4BlrUsJrbPIZaJAIrtT6Rjltq
# DATA xG9s81Ow6frcTZz1xXpJNHbtPOORzbHRo6rTSvRci/611B4tR4oMiEBM7/gPUYGoDmn5ypFiVNt0hBmsAabKIW9VHHhnX4bqjGOr
# DATA wcPUbnatc5W34po4O5VCWQNIqpJ30r9VpTYxdjPPOf2baCWKI4RT+Eg12Sp0QvaNxMO2ZKCeiQx1PX0OtvsqQbeyRSFo6C9MCFRX
# DATA vQbVGFkbe+eOVPXAFq2Eba1jmydXYsy/1jlBLdMwxazhcHqyMwBw9FgttaMNqDTgl2OuObdRj291xJYG7bLgCaEoBVyl6LivGxK3
# DATA L/08zftLl2SFZmLEGiXkgJQj+Qo5fY8vpe9SfF1llwwy5vQkNuz019ZTclk4iSQ3pcob0gizGnozcqFs9UIcWRkhYG/jgXHglVFO
# DATA N3k2NX3GbY653mrNMf6AXyr3aozn+IUra5NevWgLAXfVV8THe6p/qwv1UF0IRwoP09zcsEt1qzG9Gdk9w6vRaBdDxPnszZhKun87
# DATA ekIe5Bw6cZJLemuOHBLn0XByCDOKXuw8iTg+F2ftEEdwjocCKzxK87wxn3SEDfwxndwo7XE2iL6AADm8bApV6uUm1WaEpymNtV8m
# DATA 15VmvWi6/e4QcIsNH+0TodoitZKS124+3d74wcb3N9ssp4GlY8PNkPyDtkV1UnUicABkmHNGZUddZkRBS/TvG1v2SM3pxj3FQgee
# DATA OHyuKxVoBpnS0JI23cgqag19iOpnFUW8wcfshtGFQqGFNMrTjZZEGQoCWF2pCH/CsNxUOCjia681QiRo+6TdvMUjyAzs25FOeK99
# DATA 4nIKZnCSZiPjXylEMTvsX4wlMAZg7kuBA8aFU7eDag62r0T1g35d1xE3HSclygbLPkrV0DqrqZ6PMkwar1rzLJjsFE3sfed5Kdou
# DATA t7a34kwHPQ7+Lo4nzlj0JGNiRSTqFf52/IVCxXR8IA4lL7F501zOh1p+JzTdHLsquNOeK9nlqt1kM28tlOO8jHDntsZExNr1qr4L
# DATA ddjfz9fqKfWOdlZlkr9c2aPlN5aMrurG2RA1GhHetCASbbSYmic8Rj0BkUj66kGWrPNSIxcuXw9COW3yEFiWA1fwEEWD26H23eyk
# DATA dbiko9R28+ymw1w/HE6yXle8Y4G9ILEKqoOnhD65U9mP610JSCfLxCaQ3CTZHpEM9A4n33HjdnoLVMC2ZasVpN4YiSfdy2lumSqt
# DATA r5i2HollbIWE0M1iJEQTuLoBw6jsYwTp9CLtTMbJYY+8a7fiYBBptLdiL2I6WbqnxhBOXpXSyap9IAl5fcg6QgJQOBiEEph0hCy3
# DATA axQkezAZt1aXlkSAzEHxrQHu6p+bbvT7m1ho2Dp6ttBA5Ty9+unr30WvfxV9vLf3fLeuXHK++mnQBEhNl/x1OPgIR6gV46J/JjEL
# DATA miH9Gi4iRcgmZk7gElB7CLbskLBitl4e4o1hEhuVHzCXjFeil/I6Y5tpt47NMr8sNufVYJRNaU/lqjY21BtIfLjVAqcpYHptojfO
# DATA jSTn1GDYiM/yRhVLejJWfns0+GaobXTKRxzQjA2IYlcnYkOFXpeS49A8fEzxIc+IPZGcQKRSb1E7+VOClbzBS66ScQYCettYVWFD
# DATA aUIarTrSFysehhv4ocAwaNNdo17mBgLRcmQaEs7ERPnMAzESuN3GpE8mS6dZjmxTe/DKa65oU+ISD9xMzYqJI2FwvEGY8Dg1Nb5T
# DATA Dt7KmWcC8W2ti2PbTlVNxFsz1JkUiOu3Yu53y73RAfKItetMDgnYh1PYJiHt/ICl0CvNGNHRjC4tBwDnpilztRL0Jv2xiU1VC9tm
# DATA wYEgEeDQU+RCS7fQ7cIOVCwTsESe4gb+Kr20vb9vCItNTFHL0Uev4xyS/f9DnMeUWF7Zkf8LGZcg1vl3jmj+67+thpEvBJWSC2oH
# DATA r3JjTEmB6aJM1cGtlg8W5jXzLSQicAIck8/ez2aFOG5EdjZmZdcjVkIYgl4b7jlqkTe+MA7tdRPY4obcpSGIto3kgaxD8gCpn3ZJ
# DATA FAwNFNi2h0mmUGRB+0JozryscaAkLuwEfpmlQfDkPUzRmeweJYmMyrfdZC4SmorzqPg2+eK61Y/2fY0E0Oke+99gK5JKNZDXUPT9
# DATA Y5EwX6klb3o7UIvsNRDvCsLw1utqwzJlhxqwpnZJjA9ql7gucBLzX3aV65F5dx3bKrDKzmG1OtF8fxApqlERTVXTVJ7JSuAghGoJ
# DATA 26NitN1SDHUYABTJpiD5J2SRIv5oaIHoU9xSwY+0OmNpDP3Fij2b7qq5Cv6bNvV2bWhq1G2nILVxDWcdcvNAAhna5GB51z5EC5Xk
# DATA 5j06szDjKZPgT0gH8/8Ar1Lg0vYo7aUAeD1kFZqckrooJaRDw7theZouog8Ot+qH8rkOhlYT6ae+okUw0ywLiCYyzlAYhdJwdkQ+
# DATA 2RWdeApuNa1+L4+Qxi35M9UCL29h/XLBZjkTFAnQ7XGWaCzL1ka3QpYT8vAGS+VWfbvFUm29s+Wafc+mkdtlodTmlEYG6AttBt9S
# DATA tr7NILcsYdjQ7YY4YMUTO+I3SkVDSgSS/1Jz9g87XScmO1Xy4cV03FmkUovGfJ7KJN1kOJbAd55hfZg/nFPaUJqkyRGG6kxNEmuf
# DATA HioWerI9mzXtJNRV9V2tI4sXXGEDFhvHTkDfAAda2O+iJCiuzvK3V7KigvfP/GhjXtlSAaEZqkhTez7IDdJFIZLHsj+fU3JVaKnd
# DATA Sy4HE3JgcTB5EdfMeSEL+KYUtQcZEtyWhfm2QsjyD6H+Jv0EUGyxrI6o0uVkdW4VDcvnSq7yluHFdFKvsmAe5uo1g9EqvQ0JBerz
# DATA Qn7okCCFqEHVuUyK3k1AHpILeiMD3uSpYkrmMcxkW8OaRDF5mgxtHmRWMMCqTnHGGW9JsM/gpDmPPEjYRb1tB55NZEhe5MhRm8Uj
# DATA nQChSdDYDMZm+KpThN8Gxd3SKE65NQeH4iQo8NpU2WvCc+QttXKKOO4nLnaAF5V4MRlmixj1d5FjUsasC8c++FwsqoBBQwz5wHbt
# DATA VhbRBim72vy14n0jvPcxrHgPvl2pCLfdNOlKaGZa2tMBLMSgn3UqKDBfXuFwLecnGJK4UOCBrt4sz/vMWe9oSJzWi6y0lObnLiXA
# DATA A3QFKxdKs2w5tvk74xJv2r6hhNi2dq1gbAALHK50OOheumFo1UhJElbBrJSSnBJXqzzwsRc0HNu1AgQEvvLZU73h5Z1Wet+UlFOb
# DATA 5U8GcH020MAIFTs1cpKcEiiZZS9GTEPSNhSSkWbr5zqdDBsPq6SYP8VEm7/lSBfoz/o78pb7AiVxAcLe2wPBQXZ23Abq4aaJiThU
# DATA NkdHANJ3lBbTL5FpFSBGKBVhMp04j1682Hrc8OlCyUFK9lYAh7j/jrjerS2tVaeBhfkPX3jSlWe7kunbzv/tLAVMw06Ha3TCuXFl
# DATA oSuZ99J0WFkRRBkWnZJ+MxJPxt96/snsxqyEpbKbP3n9z/D7719/KapQjDHJIUtC+WCL7pK/1ikZVBR6Vlu+hfrzlkXnzJav/6/G
# DATA /fqLr/4anT79pBE4uzggoy1iunK6S2tjvzHCK8uHGCOA8sybVFeUAR7gqyQ+bikZdeyJnjk9Peuj6Kcj86U3KJU0LkGBhtUo48DA
# DATA dfPTm9DL5mh7+IDM2QQqfuqMzC21tdGGWc3wylFYPZ30Y5QTBlUZxBsbo+MJHp/n9KVi0betdrs76LTbVatmAy0DE6lSifXIYjRw
# DATA GKDdR2tfaYa0YkjFa7e190p1b82GMs0eDXR0rFCHwClioDtApJfDtPWck+0BpgcyrmurF8N1DaXiDNdJjlcLEbXThwQUWF1Tnabd
# DATA eX1npjeOzGH9lEdm2i6LpjtHW2SbUl0vKyOhaKVYwFsBF6SeEYFtoonieYs91YDI/Z0cYsEukSw0bgt4fsmmlsrSHyydV6pT7rw6
# DATA cnacwAzNQiWoNlVhVotvv2Gh6JlnIg/CgcmTcZaSFzoogf3MPrH0bAfzrZbfZfazUvfDvhP2XbHuhx33gGU2R53+uOfAaEfp6QGU
# DATA 0oSzJBIhGyfOvVSJASXBUKqSe/bRzubGnso0u/P4Bzt+1tka57wx3aiUz0dd6sBOfxqfx0T7Yg8uhqfZNI7wQwX/qcmbJ88efa+9
# DATA +YlLV7noIODvyPtPJGx3cjrMbcg28zgoHhzTUOdoapzknSxricEg6lv649ZKFSEsbGybbMPabTqJ7TaepHY7NoaWeXbcn5zShuPP
# DATA pNfY3fru3ubO01pknj9+8dw2Q+L3/KfCDehka3fawMeS7Vo2rijq28HkDPJtxFux6S1NhH0vvWRaK0B2Mn2xewlg5nTzIhtbCkkv
# DATA 8FfKjVUUBfBILLTpnEtPHp1SVX5hr//B0GKa2taEWcEmIGifNsMmjcLQ/IQyZiN597mKePErSqD9S4op9613999pMvrsEC7U8PJb
# DATA X9t/mLD83toa/YX/vL+rq2v376l38v7+/Xv3vhUtfesb+G+ChqLQ5bf++/zv27cWJ/lo8TDrL6b9s2h4Caijv7pw+/btHeCd4SLQ
# DATA 8QDubOP5FkftITNe4tnyaHwyGkyOT0KuM1C+Aa0sCPBXFJx6Ro0CXj+8yt2xegtMG3FO8ggE/AmwWuoRwaP6PcgXyMwASXAoonAM
# DATA 0liqyEh3BuBH/cQ+1W+bkfPeOWN1ZTT67STr8hgEkqgxEEsB4A/4JIC4nR5MKNKaNOZ7NFOhCV2YtHBgOg2siMABnZ4OMbFG1oUP
# DATA dmZFNjogzCjOJcZMecE27Juez5Y8KgFA5+Nu1m9keTIeX1aKplHuDOKnbP4XWW4t0OwoQ+NkpsEGfUrvk3DY3lNVvxm5FJQMSba+
# DATA IX8rPG0C3jxzBsFZfzgZq496ebcHOykLR32BGrLU6pvI1WRq7IXAX9pSvIKUKtHogM6HKOhGuuk0P4blh+sAR76Gyb2gj5nrgx3r
# DATA 9uHHjyj3+DpeHLouR+xkQpINdOwxk9kYZmaE7XbWz8bttoyMxXKDV3AQYidehxEzMqOkvaxwrI5Zr+T3VaZxVyzv1O7z11qgYtyy
# DATA UOvipjx2Ex5zVmD+qbICB23FvDV6gfnjzRoQITaYjO1UyLVIt61ajsPzabVUcAMSWJvR64kur9xvLMH/LeNkKYMslsGHZnM5vp5n
# DATA xDvp6WAssC5XvBzbpfPWJhGnpt3d/TgaT/o4M7wMWCK2HUt6Rw3aS/pFG8o7qLP6LiJBSx/cWnIOyejpk/pHg9F5Muqm3frz0QDt
# DATA zCKznfZX+IXfzApc89qZPAZzLJBEzb52BzSXmNu6oEiHmvtnXzsdnIAYZRSZig0opv9S5KyYHTv+QZQjxVoXNM0bkqOf5bC3KBYs
# DATA d+7Y63jtBNzUm+GeBSm7H29wsr/PxD8aRUsfpsCxjQimmep+TlHfxJJE1qW56KRSxb/QYuWJlQku4rLwnliMA32tNqRsNTyPR5yE
# DATA tr4nUUXdhbqon5+fU861uu6Vw/qaHosr6yhpMeEyQGg8ViP0lausWnE78KZ+d3NP9GjL1TmMI+GgFE/YjnV6cH1QX0NHBxewhf9o
# DATA sN3S4NsJhFGUfhMvaJ1r5jkJIShtyNosdYib7dhVRqyuKFWEpZEoU0hgCFRpqBo9jPy6s/QEPvBCEk6NBnNQAoc2Ok5LbHsELTvJ
# DATA /XgkIcvRG6kHtOkQUxBBuf40/ZB7newWvfPltYwwbm3lg1p0d2kF/1nFf9auqZg6sA+ilXDXthAfYIiqUC3d/YK/8qyNocMcHSVZ
# DATA L+02CWNEymbSTKJquywFNqIS1E7Uoj0+vCFdxZTF+72vClTpY7KCQV8WZh0VRqgqP4Winej5s909PBVkZOb7cuHggLs7HToZ5IO5
# DATA eivkQ30EB33s5DBTKbe744biWCgim9d0DQvgu8+g98Zk3AnJeEoby/IBJ7jkxhoq13j8Q0S97y0tNZeWPDtzbqsx/gxl0GFvHSvV
# DATA PJVVrXKdVnDATk7uRpKrEhW/dMOMuWrGK0OFQf/Q0ij1z9IR0KE5mo3mfzpJukjTDcYJJ//DIBFJ1meJs7YmRc7PQfGS8Q9bYd2p
# DATA IketIAPCy4xgVSe9HsVorozi/Y36D5P6Z0v1D9r1g6vV2uq965iTKc+k4V8okrc7SBlZH2Vjot67Jtx1xOvgHcxRChXJx8TK+dk+
# DATA TYZEoDBPhATKxqO9re9vkngaOC/gndBcJH68tbvx4ZPNx0SHZafAT9LrJ1tPt/b4bXoxRC0Cvt385PnWDr8d9NsnnDDHNKFT2Ji1
# DATA E8MFHUPejG7mivRf9QfnfSUXiFRLCxyQ4RTj8kE/XUqcy5suRjmAjdtUgKNvLVVrXgms1h6PkqOjrKPK2Nu6FD1ocRf444OlpfvL
# DATA H3ywcnft/trSBx8sK66FStEIAoVmzW6rT8aOkYwCzu4EOdhcbyKalR5fEm0WmFkbT++4rYrxJOL+gN/H1cZkOARa2ESGUu1pDmX7
# DATA WXtncxegL+zl441P8c8PNje/h3+fPtve+xh/fLq5sWMzK2UblUNvgxGa5lL3kRkWW4skI7x05Dd+UBgRYgHqyFba6dmbca7rdlRQ
# DATA a6oWHaadATql64L2NZAUPnzi9nEl99WRPDiwT6t5TQPSp9tI7v3On223P3725DG2f5lH6g6sR3Th+LoiXuuKuFdzcJiOKD03cMQA
# DATA KNalahjFaQhxt+2IEj9MRwNAoEk/j9A7ki6shJSwQUUj2rw4SSY52Ut3Opx94BSeI+4gkgvecBhcPMwPW36n+sLBai77VhOyznSm
# DATA DIRR4OM67E9DG6MLTTHX5W7rfM8c/kkdkVv2GfEsjfwt21Fry4seUWpkVXndBFCJjibjCW1VH21P84jMLY1cyWavQ0fVqLZw2FPO
# DATA 0Isc7VM4dwkQNNFnsLnrQC+Pga3nIZ4mlxH02mdckPTI9z/Kh0jwK9iRHJMR4oKDiq8M2mqKjaw64irFsYbtG8jAGjqD7wN/ijn9
# DATA goFB8lqpKVYA2NWXV+qry3srq827H8D//7AQSiGWkT7B3fwQvQWhPwHhzrddBTiaemFRV04obAvhYz/p7SJep5A4SK5Sojg056kQ
# DATA vq9WC8GeYku/hZa3eiYACiU+YxzCXCx97raTcVwg0/bV1w3O3O6vnVXXSmmVUegM04O8i+2kGRMLmLbQMLoipapRHfb0rIeOgLRq
# DATA gx+xZjk/SbqDc3QUzK1pmGZuAr6HKNnpDHpN6y4IyUVSVwlMw9JnO5201AOqi3Js1JSrKbrfVcyoWTtOjy9g41DuVLGmoiR9ZoLP
# DATA 1RsqaU/VK57npqgbXECNTaE+WU/fjcHjF5TAW0rvq1bY2otnWfXD7Qcc7KZLtPXYjBjSFTlaKarMqrk9qJG6t4HZENsTQsb4PtE2
# DATA wO1zCXxaXZlnzM/VWLU81iFVbTJV/DjgJ5Gqo1QykrmgU64STxFvUUFVUNiq8Mi2B1HxCNuSXTuNhkX1OwFQyqXahpa1zF/a8F0B
# DATA j2qDojZa4lQVDQ5+7teXD/xzMpVtWL5Xu7eGfAN0V51nY2x3WxbjKnlfEuUnqCbCE8Ey4156nHQuAzaSsoDF7YmpCTp35CM4OSyy
# DATA bzWN2bRlFSWtEU4MdTP9btqV2Xw7eqS3JgKiCA7LmESUyl4pSs9gDucnKbd/SpIbwsAJxkJCUxqkYIQhJ/6RIVGW9rpEZTosm7k4
# DATA RbDiQg6Cpmq2Bl/WQgisDHMdaKAokZh5VA5Iki9qXViLoI4ZWtshVaO+Ulhon9+mxSemVcc4DqJvxE/Umvms27WLFNR2pm1YnOy4
# DATA T+joKoeV5ZPgijZyJyVfzsYdFLlKX54gEqcgldf2gUKMZ0YYrHRAQEsNy7ifKPDTxk4ryTBzWG8FJuG9kupWSPqE/mVoZ09q5sXD
# DATA y7o6O2SV78AEJMm0u1BylKJizKgJ7HgfRvVpm2JrLWkxlbklS4JtgTPYZhzD87ByTB7i1VKeFjnJmYleRP0OaXYw6yzrMnAtDY4e
# DATA HB3lqSUmX6pFy2wF4Taq4kzNXKvvcIstJTnkR4qr80dE3Okv3LyL2IjGDcd+oU8cPHI/pic3WZnzgQ431SiawmNBI8Kh4CyY7WA+
# DATA qErLL8YHKhonMHOkiKYdWmdpoHqZRBTELgK+Oxt0Y8+TDI1LJQrnvozmoOiZWBQ5VTl0mK8mKh/34wkrS1IhxbhrcmbLKZwXjkGn
# DATA T/Pc8NI+2iBWQuOorvNaKN4FH6p+QkEqQZ60tCXumA+BKH7lo0JnQXCYVjMPQ62UiVOUbaCaNu+RwfxWu7cKwws3uklNCA+KQu8U
# DATA lVMi0yBjbifStNg31bln5cV+JZNrqtsqB7fJY7h2IAYVUeHBJn3PpJvcs9hYcjIeTsZlad3K9MlsDaOHTNIA3IND1CVDO4cDtKbB
# DATA 1uKSfL1O5wDXBr0zpfjTZSWsgp2SuxaRqa+K31SL/JgL2ZFV354Unoikf1mxvgIuwPar84hUYV7AwUeoJ7hERsZZAOU7lTc6JzCg
# DATA igVkraHJcWqhrQTPn9+0tbWDTflaxRyMhPp3y9yG460+erG71954vtXee/a9zW0ErjsqfyHZQLF6ONJ5yZSIuOU09XRj54cfbmy3
# DATA X+xu7mxvPCXxi5KZJl0gnqAFbdJj5WTTZHy4uecbu7s/eLbz2G5OVcExWYujjQrkUaMMpNA0zqCxLFJRfS1EPKF+2jxdU/d2LVp5
# DATA wq9IE6AHc5sbYrxArH9O7qNGABZEXJmQEnWughEdDHrejzOP0rCZETyGhv5ptZRNM9doU4OG8OH2q7PFwFydyxuOiu4LttO1k10a
# DATA pA9zdckExXdbh5jGR6i3nWefWfHFaqypzIVY2Dckq0JT1McUH75hcomK2pot2nW1L4HFkZdG3qlsihVPBrwFsmW+1pedBNzdZRrP
# DATA elFTY7Jo/4NCHGHdmE1/qehjimlRhXST1blxrwUJaCk5+hVr+rvZ0VFK0a6YI1inTgewZohLgOL1sDEZn+sczjIUuhay9rFafHip
# DATA ftpeFc3gdK1wzUqP607D9UBThtC1CA04Sm2iqTk6VGbI3gX3CQpOIE2ZhKJZFtTuCJXsUelQBETzssbXpQjaDiBs0DLfiJhHj4tG
# DATA P+ANHVRKWdj0T+61EuqhXulICIVmdGWIjGukDpPuJbwEDpZcCyf7t9WG3OY8PxMVXACLK9kuZ2noAHnCVWdUQ0EdoO1xLt3z8KvX
# DATA sT1EEt6QVaCADc4KAU00teLfpHDROJnbmgXDno9SGMHxyVjrzW2MCPw6E8+NaIc0H5HZBtdxpTu6bAPR43sqxI9h9+C99gdjxTyD
# DATA weLVcT28CXBj45cAWHHObNQZP7JNi0mZPz6BS4JD+w6d9AgqIJoj/cJlmhccaOJHeEB75fNFVyJrMEJ9oGBepMMowj4goahsuHrB
# DATA y0hPJisKBUiQfbcZNQIGqAPl9DoCJg7WlRo7ABbL4boJ+Dcd1hqT2kAwvyBTV2pu5VFQJcQDX1YDkQvNCCxzz2a4t29HG8Y2CfUr
# DATA QP/2BoBuRcYU6ZAcbIFOhsQYrqLfyTAaMoWLjg6BQO32LpkHbAQ7cjxz336Jw8us2F6FveTzNORVfpUfyXxZmo1erxme71GK92+o
# DATA 7/l4YNYj6NaNR11rQUwW4uKcSCx9g6Grps2dmdp4yGRuNupW3D6goU5qpk1gR+FrJ8pQ6OyVIEk1AbnjB0F0KbRwAD1a2DuA4EQY
# DATA KiiOuyrFhrsfb6zcvbf74uku2bVwhidxg2jkJwl8rAy9AJ8n6UU3O8brSWKeiJDHkNMDwvPLfszqIKKASR5vcW7HvcFhJb4joL9a
# DATA dXEoQ+SuYDFZpttyhG4fIKqzMaNdSL/nYsqszSnDL7GAwTr+XsxEdMmIZNas/lqPrOUmuVJOXU/gNWrfhfQSPAWUH1/TQZcuVRx0
# DATA Qn4j/+OiNyvRQ2hQG/tOwOuB4hbYCdYp6cVlpebqiSUH83ZArEsdWRfl1kyWc7BoCSx7axk49FAnRKUVHYNt2y8lOzSNWZ/LhgPk
# DATA SZ3DciVkJdiKOaTWGKYQB0dySWqCUOmSLhQnVBdOaFpt5Q0cdATGk7ZMUnKXB8RXd5eWLPqBrTcrsVnsZrT8X3/yv9xFO0DmN7VO
# DATA McDT6Ywd4m460+1zljfmDXkRy2WTzIf/ze6z7ccUhbiUVWGA82Ych36rgQxlL2CqkuhLlNuwlV7DUnNZAIC6B2oYA1xCEy1xh4Ju
# DATA q+Uepsvv1BHz9/SfnyHi9+D/eXdlbcn1/1xeXl69+wf/z9+v/+ez83406AMxPaZYPt00Op4ko25E+or16FWaDsnLCS8Y4BCKIkB2
# DATA KZfGBuoMLiQWn+YJmg0lkdrbu3meTMZZTz+NE+2raVKVaD/Q9HSIV31hYQ9NBCOVrQ7lvBy1jGYbL+w8e7anJO0c81KXq1MAtCMd
# DATA lHHhxfaWVzYncNGVv2VVGyo0UdVSM9xB4O1mYiG/FidcH6tn3UwxXI+gnzjBYP4qaaKTDNGKrs1Yn19OScTHvdO/diIYNc5+Oj4f
# DATA jF459vXa2E1vbCMbtp2SlGsm64xtybcxakfaPrvopRQrYymi2L30Icvbp/AXiMp87L6eUDI7ouF8etEOlrURSbGOOB1uPcd2YP36
# DATA 6dg2dogdBRDnlsa+9P6gKhzVKdAITCY/ofAZsOqHo6wLpHgtMrnnW0vayZfj0KmloGehOrA2yeqJPEcdsW60Gv04ulpZuXaUZvLl
# DATA YXRvTWljkBirDKtKrJhxfj5NdAzxn3t3767eNdwAtzJtxZQ0Dy86lXZ1dzJdHMjyyvtqJNOtaRpNtKepLd9Fc5pDzv15iKNRjc0z
# DATA nscYgn8kVZTNW3Ka9cjmMxveI3e1uBmzftcE58uGsatBOoqvuOJ1lON5ja6o+DUa6KIToRBIbLTbiipxlh0Ra3VFfBYSrsyl2T54
# DATA 1qysLVUT5DQ3ke6CqB35qBIQawsS3FVzmELbSybvpoje53nWkSOOWUrZ8/QQI8TQwow7w6hLTV6Z5vWoyTPb9GqPW+7NURzHrN3O
# DATA 8H5dEaS9jq6uFtAKAto55diQ8IbmScXaAguBZewlQE0L0FmPrq8XIso7LIQdNsPVAI6jjOhkMFBEH9BzgxEaMNWXl4AJQBXqpYx7
# DATA HWqpLbzdG9yW1/C2M9YBa3lxuqPBEN5f8VlBqZ+1IlfRldn702SIxGtNblT1GkZrGja1/tjMWX+9kiW/toeQkllAlp+k3ZrKF9pR
# DATA alI2XEdEqxs5TcdJ1FsjOzsAvGf36lnnFO44/HN2j1cJRtzv1vtpdnxyOBgBPwqLgra+9suki9oiejeCRU/VG5wOXCpY4iEr3lfu
# DATA 3r1p5w5H2x+lCWwmJTIbJphOoz4eDOqH2TGjmbrS7FOyWtgrHAt0ABVOnbXlPTJn44hdnktOh/o643zMcRLeeKeuBJZc24OH/4e7
# DATA YmLHdVCipQUQghwQCSyIXaxyiisEf4gBUrcfPdve3ny0t/Vsm72jxPLRAd2mETINWePgHvolWkgCZu1mx1jRYtRwMGSPggybWz4U
# DATA 2wfhIIUuRRMnIE5iIjdzpDcBw3HOvz0c4bgLB44HiuXDGXAdnEI36mX3vZgyqQYz8zmDxUJqJfb1aAuhHsvT2jm2WCJFVmDbeNGQ
# DATA zpum2iUkxckMCeWTO5eEC+djSY5fowx2uyW4DD/+qbcgZucy22jR1kDY0U9L+5acv+gEDw2pPryF47RDuWgv+FA9k7QxtlG8sSCi
# DATA FVAyU6mu42g3eCQNGUaDizfEjspLEeP9p6axRMiGlSnbpC0hKYasmKCewxGFZuNSW934YL+5vKJ2WVFyjIwZSmtqTRN1nFiXUBas
# DATA Yk/TIpa6mxa3fzRmzzwOjkAVeH1TfEF4TlHuLomrWmrwgMgtmTJFlDWbx25DVkUfv+9wGBqlNUj6TCfQlkfQNjen7mjSzxMFQypH
# DATA cTclO60iun7JcbBDAyfyXPA+kjS0ZFr2pKZT79C/R/RvLEyM1X+1WGNKWUkZhmj0POt3B+cVdNCX39qWeYOQSFfPGkbJvhKd3gDd
# DATA i8iWGWb1CHDb4YAoKeRyMdpFJDc+6owSAOomvfcb7nxww6Y1N9eOv9muWzcBFml7EA3O0YaY+foMTWQoYwJql4BjZBsYxaPmgO+y
# DATA Xo/jk05dlJyWwluSWFM+8XzrQ3YYZmtDttaWA96L4fEoobsUcY4YmROpZtEER4WW4UtO5hfjnE9spPJSNezosGWnseJGAcR0FRGb
# DATA 8Fok7o1J25dW/AxuF/YCCS8cods2U7hTaEq7rWrxdvFNJx9ivhQzNismOvd9cuu+jsNgLbhRdqewSm/Wo6wR/ly+e8pjUFDAjt3r
# DATA efiT78c0Q0ybGdpJjyYciSKS8oqj7NZIUDQYJWRuqYRGjdNXKM4Zoh6tRV2xYSU5sB9lF624QeevHopb7EWbPOqaKJPYthdlEnvj
# DATA efIM9VdtIakHWIhrOciN078pZIIWUwiq3qVz7QY5+81IikBdzycScpUG1JRQqS4xwKjkzDP8IcUxI9m6JR2bHJ0vWnFk8kbXl5BR
# DATA quKq2ddvmh2GEaJYhgSLjfOTDAjPGN65AQfgRWkmX550wXxWvedzU/gsflZeEbKwDdRG4FVBaq49gTncIp4AyK8UnmaUJwfnP4Jz
# DATA s7SyMm19XvTRsyJ68dEPImu/VLu2Jxd3pBJMWlol4BElrpEqxMPwYT6+bey2t3Z3Nr9bUbXUWGk29suSCfv1inN8i3nyHUc5074x
# DATA Dd7GXuj4HLwEhDzuYf5S9UpJVV72bYUxBxntsmxdlyDatMUQXDw7zZKR4h+luZzO019uNiBzlhdXQCsZl1e8jJ9lbVSUT6lrzuIy
# DATA YFAn7yQodKQFIQow3l+qf4DivbvXi4CiXqJmltuqTgXBuOIyEsoKMOmfyuqw3UcegqSOAMrzMmfUwC0qsCw2dTb4eC+KZZxVP4NQ
# DATA Ba41xwSPKZu9yoEV2vPy2pjaYY5aZHJjFj0cF8w0ayWzNuh83r7E85l2XYD4PFHvnQEWBzf19n8NMyidRdjIyDsQcibf0Z7bkf/R
# DATA aXk06OmssawiEPXAG+FAaZGzWJ8OzlInMM6bYigJz9w0wOBm+gmRdBaMGyztBDytfCPaCYKgsky+muL/fxhYT9TBShpX6P0ERqit
# DATA 9nQaxP9vDUn73wh9PUTsdQP0HV6kWUjVMoIBFEexsxyR40sf4z/ibl66SF86d9H9c9oK0TtVEE8m9aON+keN5uLBe1WF+CsGgVa+
# DATA 06yZp+p3qj5G9XeFRjlzjYqLMxXj+idJQQfqDMWoblgyhE9MQphKt1oCW5DRZgiCChMyHONmVg6Uc34NjRCphnf755/NYdoboPfL
# DATA eAADGYxPyHuGBBu2xw7AXCThwvsZmwilwH9rP54A+HUQx53KfgCxHVgrQ+TXPuadNMgODRxiE6QjHg8IF/YvY42K4N+qFTSV7M7s
# DATA izsT+dI0BBfJLNxEvTOwu4dpxbta+Q5+bYhXz9uZhz5ZYZqQ51egTmZRV8XmS5ZqJvXhhmLAvXI4bH0vyHKmcEuaCzcekbfGR/H+
# DATA Fazc9U2Bkmi+NQ9C6u0SDWeQcp5zI81hnCvbkjruHrkVWGURDlMGJVkv2w6jpokzniA75KMMdNTG9Bq2ac0UYgj2EI2CCiRDhd7a
# DATA fNQ03YYUL1AOZPDifbKx4ww+ijEgSz99p1pq1c+v7rkBaxb3LBtMYIKk43SS69G4/RzcNhIl1jRcSi+OHUna2RTCy3bnSpFEZZ4T
# DATA bUcBKjg5p11TMavUtvOJySG9zyV9UIEdTtgUs1GGVcdpXeflNAUs12uLZq5ZCkKj111Qt4BUhY4tUbkdkbszb6mKQhkfKS3VNtGJ
# DATA aQwR5wR2rhahaZtxScXqbFkDzbhoqFzwOseJtUg1gHmo88b2mtyqL/ywxJRVI9cojk+FMmFrbUUttIoMkI9InDNUCK7qtRbm+5wm
# DATA fIAdWHs6VG1KiNRuu7eqpLKzS5YN0pVkCmtGMpQ4z0/4/jTVKeNY8fgS3tmyWve+Nd1pYJxRfVWa1h25LgwSTw1epnj/RT8bHyw8
# DATA tlCPobyIfRMcRGuxsIFOXy2BvWiB35CYW6JMFkXKwoeE01tkFUghYqTcwv4ulzhYQKv0FuxwfjIYL2xepJ1dDOzX0lavYvEaTTPt
# DATA XFQ7pDENBy2kYaIteOsyzRf2t5jKPFj4QYLW5B9eBgYWxx6+jNk0tDOm5GjdBPB7vz5KyWFwWsm0r676bKNSy8+poOG2MXAA+xbc
# DATA A72Tb6HlgjrBhhY1HRE9IxVdOAW4dfGmOi0qEDaTHp3udWbRTvYQfUrOXjQFf8V2QsKX8asy1bhPicL09wmelk8wcDI4PPA8Gx6A
# DATA 9/OeuJKqtoDra0zQyEp+x0PIpJzjcyfzBzzKvxB3xqI/rKNCTT+Qqp/00dnYqqbFadOTDzLwnFqEACZnHgy5Qi1NrZwMM7/qnFkO
# DATA rQrTOiCwzPknb5SpUBmFtPTq+l46QrBI6jnCLfsrKxSzQoJHWERLmQ+4IwxCsndKKrd4Rwgwzzw7OGRnj3UYienkaFh752ctRLOS
# DATA o+wCAyrDeOpsO2G8N5OzAdp+YS7ARZJDjABq5FHSGQ1yY1oxMgYlBSbiGyDsVbc3ZjveeGy4Hlb2RrUPlLLxjTI2evpzzr0Y1qDb
# DATA ORqFNQ7naAycJD8vry0G3+d4cYjbJHJcP+L7ANe6NLlmMNAchdcqJHOwkwDzDfPulWYUOPiT4UJcjdKM6+HO7o14vYVADnVvTMa+
# DATA xmOz6OJrVsqficVPkRLBXl47cH0phzgzy7clxHG9dm6gk3Eam66LsWPKQUFbV1uuMfPYCpqwSgJ8UIvk2Zn8wRS5VbC8MV69GYtB
# DATA 76szjhxhX++gWRYiPr4o5H+fE3C/u0M8NSgGX0x/F6ZOYraEq2xtrNNtGDWAhdVqefSIWfefiah3ffFnyTpKGBAmJApn2lMyktqe
# DATA imgO9qBatWQk5es05WxyQuMSqtE7WLa5aQFP6CamScG/NnreWVCf10AmYy4WaX5G1Iq188wyHmWA012PWN+ipiBCLu1nraPwzPZJ
# DATA Fzf0b/3hv6/f/xuBzteYAXiq//fy0vL95bue//fSyv0/+H9/I/+VOGUn+Zgdr0kkcjG2fK/lDWuLdd7cDjKl2rs6HY36g5Isvifj
# DATA 094NXb1r0fPJKH0+yLOLEs/vtAO0XR50/Ta5fylj78LCo429jSfPvtt+vrH3saL7jMiVMssjWMJcFHI32kAHJr3BMcpoqwtPNz5p
# DATA qzY+/HRvczdCOxcnMx+VebqxvfXR5u6eLrR8b/V9/rS3+fT5kw1+e49f7W7tbbY/2npiv8NHXRut96zWNz/Z2t3b2v6urgPf3Q+q
# DATA 4r21wOB0qcebz2kZ3l/Y3YMRtTFaKSrGG9r+lrH/wr959mJne+NJoEDd8tCQwsRhBZoitm9hZ/PR5tbzPV3AtHSYdF5NhtLIsyeP
# DATA 27t7Lz6EIofxg1vdAR0yOkAPH+C/UQ/QSet22r/98AE5IQJ+GWH069uT8VH9fXhL+s+HIgx+sMiPD4bqDXJiJkjBg8XhwweL1Dza
# DATA 0G893tze2/poa3OHDUEw1F2GZEu8n9Q/O9hnf+b6wdVSbe3+9UtMefbx5ieBskdkxHFvjctQXNnSUqsrXGrzk73N7d2tZ9u7FJ2u
# DATA gaMif9MOJ+2AJaI/+RnFzmmML8bymqj0uHEh5c/TQ7iq2RFQfvG1zjG8C4vN3Lth5Iu5qNvDJBvlFRLV+t79V9d2TP2aYYSpdCiy
# DATA PlcN6YPMaOLHL54/2XqEBxGjxrS/t/lpMfsBxt53MlM4eQ/U2HElKmhDVG0GtTtWeBmOkkABtarBVKxkitSlEDbA0eHZKnrUWNQz
# DATA tzc4xJzPvIZtdD9t8W/X7/BFP9ORccLxcmrRTtqZjHIT96YYP6ewjlvb3994svWYVlGlRuRE57I8BOI8rwkvUruJ1VB1jPXcRCXL
# DATA 75PsKH75kpzt/YTj/sBebO9ufLTZ3tjd3dwjEBwbjSRCYxvQ2z4PyAsq5WJymA96E+BQqyxbGNEXEifwMZSQ5co1g0Ml3PW9DWfG
# DATA KjiwwxbQRf+AohZgk0HfRfzAWbcadPkanE4bXzeA2ckRuVTgW7CyN4zKd5qAan88HPV/nEwuftyf9H4M8GJ/GYb1495wTD+qUOhl
# DATA o3Gn+h0ZFbL+ja0if3gko1BKUbUqop1p5JOjo+wCju858mxKvGKAUPUNdtTJNS+nrjsguv7G587ZVjl7D6OVu6tzXIHHz55ubG2H
# DATA DMg1MJO8m5IrphHr/Mlx1u0n8KjufpJ3sgyeZaHsm2xf5JvcUDU8+46qA8/B8ijyCE93WogNObNwJGzUdG/5Wn2hUwKoLu1Vp1qm
# DATA GMdtLGtAt7LRa6CN3k0XPgijUW4sujctN3atcBgoICwwfks6S0EIGuClc0+5OuTIZeqWGnDSThyX7rJzTYSZdaxxYTpJv4vJlAjh
# DATA 7d8ZYfDRHB2LjS8Y+hfj48EUXSolb22Z1ho9z9xWjtZHQCRsD8YfoSw5EEO1kCdLMgCShe6T7e9VsB/HOvcYiKUxgE38QCl1mPzF
# DATA d9nhhDPpLFVR9n+xZkemC64TLdDup0+fbG1/z02UZZaJjNtgC5Q+Rg/v8daOO7wZndmbsrH9CMjrZztup5VBzrEvUagwRFTCaqDy
# DATA LoOmWnYJbZmshu991E1/f++T6jyr9YOdLbLMKZmCWbeWtW5G1QRUK8pw3n41aTDbz/baUHHzEYzj0xsPhIRSbPFbsAwvnDv1gkRS
# DATA eCiW5x4htPfiycYOsTsuSMFxKYCi0lyMT1wIYkMaI/4qXGV9kfe56B37Qh9UCw7K5uaGJdLt0+RV2tbrVdHlKZvF3bvlt4UAlWm+
# DATA AK2odZqU1WYh2ZGzNO5QeILWISG9WpvnKvQUYDF+9ky8yiNK03pZmkhqf4pcFO6q2bIGh9jVFQkptI+6Le6R2ynupMwPhdPynmLU
# DATA lB8AS47KjtgtpXp8tv3k0+jHGjwO0NbJqCEZKBY+f7i1vbHzKX0MKSjb9C/3TN1RkP1D1lcCxZEmp82icwLWJ2TAJRoIn/uDSnW6
# DATA KwZXd66ceWUunfte/CsC+WXDt5GkEpQm1gIWwijJaGkvOFLQe3DHdSkO5j1rdhKhhng3NTAysDVjzvqDmjcF+5nys7f7nFaoQr3q
# DATA WvqJK+lHXWcKSUDzf/TxxvZ3Nx+7QAgHCyfxjz3pmHDR5k41vUOsPccdHb1CYbc0CjODusSMCq7K2NJrhg80PWkY76vXVcIcstQZ
# DATA jCxtvUUpqcMbDvHj8xbo5ETE1/5y00up1TnJyLTT9IFsCzWuL7wZTNUHF6SgqZQVcGZBPYUILn38yppB8cAb4v+y2OY3IQF4i83g
# DATA wt76wcUQYOjDHJ3dCc0o3iG8Lz01Tr/u4gaVqyXw+WYK1JnHo6gmta+wu97WF+c6MJLie1awUwmiLdkTlA0pSXIlJJQyeSMYmdmC
# DATA 6obhcmpRQQLtMKIFbmEebpQhm7T5dGt3d2v7u0We1BmuDqEo4/YFZDr4RPxyRG5rseMsYtzoVbcoq8LnAorjDFackZtEKMrjXKQD
# DATA UsBIWLAj9jajD5RpXd4i/puB5RT/6qzJY/hrjb6HKc8oIyL3sU/yJh5W084um15gAPGcAy0l+Zgt7ypSX+5lnJ75SYY9mYhppnE4
# DATA 6GIiKWjq0YA+kyyKQ2N4xRoiKhGDI8C272DqiN9kLjKLNg7f79tzDByOKliRNkCqvYOxjJJzistyMdYSG1s8Gxay7l72x8lFULY6
# DATA I6PSTcYYkOeQOCc5R6KmcIXnvZs24SVEF4u6seESgRrLozkZLN6KdCzE1S3ULeSdk/Q0UZayOYss6TRhoX31/cB33na/ehdrrpVS
# DATA JNTgPBch+76M4aBkJlhU8oUWRNL4jSTSjobtDYcUUHNA+8QjQjcOfqwUx+gtNryRtZZ8x6iGYg9RbR5NnqBZT9a/gLWKfWC+FTYB
# DATA M2JSo7KyRYOqLBXTT0auF+pPCRm9PlH14nap3jZYeFpVQlr1Hg/7aXKRnU5Oy6L9YV+DUbeC2jvYwGh1hTlzeJQFl5a0skk1yJns
# DATA 1XJi8gnMSO+u6uq9pepBtfoGwMZOF5uJsxauHm/TwRRoTSWsQ4CfV9U5pY/6oBq9701GSBWcdLa9LsUnNumF1bFlesXyvqD+w/4X
# DATA rBUKJpLCl40O0F/YVYUy4EqnxRS/0pk5KPHLi6UlEsuqccgpkUcfeCsIaRTgc5DVUxdIZhFfXbFU+vraGY4i7GmWlqaG1K7VeWl6
# DATA broNgOfR5sfPnjze3MFQrHubn+x5I+GVo8ik3rq6osw463fTCx6FUsrwUcRFXVtaC38KQo+rODnEiKJKk0xPi1YH15xGJOeArnJM
# DATA 55LP7Wz+2xfAXD4GSvW7m7uGfFywxUK5nE5u1zG9xiSeY5Wdtqod9/Txdd8ofqTvKQvp2CphHcvATZvISTfiuWaD5Dbs25MnW6j6
# DATA KqqfNQQ9YIBQqt7waH0psn8FIKypoZqdlb4yDT9Ur20s5HETTOjBfT4w4jAyrmRkRFq3ggYfF6yproCh1q0rUiNjCxXniZupRZRx
# DATA na0Iqxo0FC6N8cOF1heKyqUCXBK7TxvEKigl6ejlrGgd4Gyw4droixpLrRXj58nptAan138DOm5ncxvhgk3Ghc4Obx9ZH+l1x1B7
# DATA GGBaNpJfI/0nWlXZZpum8o6JDqMnLSnA4dI0AaXL97af/WCbIauirNzBW+ct31fNH+ijpxV+l/2OLQizZF2tgKxrPhnFdPEVn7Ob
# DATA yMOCcueg5IIESTilkMAh6A85TWhjuyIyyV4Q2txAmv2DHXuyjo/N5iePnnztYm4R/aBvTomwW4S/kgYPGRL/01Fvkp9UnIiWvN4F
# DATA ubEsId/frpeQhE6onaBBLAzSfo65UEipz9bVbH3eBniskqTnKQagh23KWxidpoZJJTj8xcu+ZSeguE4ZB1Q4zTqB2KQlO2dHGaVT
# DATA a5khWoZ2tFQU5poSgOE/axXKACjKEV5LK9qntyIB8e0Uydv812+GmHCeaKTTXXVDteVqW7c8H3Xazt2Fi5SP2yXX2UCjhv0pFBbV
# DATA 9Fmi6CuLhqo+BIX/zoK/O/3bHOHwTPxWa/XCYku4acj7DZRCTSJo8CzwwdNdMFM4GJd6VxrdBeYrHXWt4PmUAhAelxjYAUrhqOv7
# DATA 0hFwcrxWJ+izJd+bLhc0QhfcIYFJKdAYDoaVqnfgVVnXGcJBI46OZQamKuwgt196YUpxFtf7WrEWfB1lqSCKnPTHIwsf4VTtJysr
# DATA O5F0MrPi1KXdZtD6DD8SkVtayhaS8cEAAouZZM/YGYVPtMUPo6Itc7PUtilMkO3tbBbVmf6dwnw4HFh8kWdCGxSeAuuYuBRpmaBm
# DATA b3Cu/HzzkB+PuSEYpOwsVWhAPbfHA76DjQR9zODsVaplCzjd0IU2823sf8q0NuHAC2ZitKMqS0QlNn7CNT3ranl9dZVVfaGS6BSg
# DATA ijlcszzswxw6pxKFoKjLA6b2dYZfzanGdW94CA10fK/lDKW0NOcEhoPkpQ8ub//rMIYIhtx4CwOJ0H83MJoo2dt3aEhxy90esltQ
# DATA L7L+gK6gY8dg14DHanOmbeY8Zgnl91BS6qJThTPyqdUY4erKs8d4KH7/tkHIKfCoGOP1Xs20VJ1tiir7Qy3O7vhtF8hcnQZHr6tQ
# DATA x7MrmZWts5x3jnospNILtPw1b/585jclA/3GrW/e5ewL6IcijRnMU5yOnAEruXp1BmtfSjbdwFBBKGQPZGsmTonIhDxyk79rGQu6
# DATA Q3tCFm0v7YR5t62oQ1FIPHLdUTfa9nZFbzc37VKbwjTDqGRszOvLcEPf9Lgrb6jJfJX1WZIqkigSppIoyujZ8DPwNkV925vpPs1r
# DATA 6pxexqF0Fn53gSnum4HPo+HzqxTcS7SEkArKQhzQqrmvAsocLiACWbP2hSlo/ZZTIaDnKu2DdsOb78ebnxQnSuXmckFg2/Q9I640
# DATA kmehj7J+5Ay4qBgLKcUCOnZqburgqcSNFJH2yOcwNESEA+ABqOLe4BIDQYWkhuYr8DLaT9OhgE+T0StCFIehA1w/W1YphlxBki2/
# DATA 5CYKdkmbBH48H4aiX4Rnzpti/Flqj44s/76pRhCnGhdcK56nI4qMIPYfAZuPcrTz4YvdT4t2Hg5Xb9O2dnijaUR1QEYXWiFbGtEf
# DATA x4FAeuz1fJqfdUbjwld+TQ65QLNYiKimPj2Bk/Hhk0ffq9kWvOVcVSFelsNaWJGY7K6ceEywLtbz9oeFzZIcje9gk7SV5c1NK2Es
# DATA FMWi0kuP0N8uOz4Zu4g2v8wbCIkB1pzaVmsxINjJRVzEsHT1OFpWdihSYHaobzx6/ORJhQMVT/K0TY71VgCPo0lfJfFTR0qa4Oh4
# DATA cECS8QocK3KqUoPUtQoyxMKAVNFGMjqmEaE0TsbWaVPAO/2EBhvtofVixucJfD9we8EANejj3XIaKcpHce2JP8QfbSXrVV95T/Az
# DATA /WoHhKiqx4rTABHGItLHD3TDqjWnGbcUfVHFViiV6lIoVx2JRyTccdeaH+wab6pRzlEBdCKl943N7We7n+7WInkimKafnj3ffra3
# DATA ++L58+spe8gXQy5PpUMmqij5Azyq3xgVCgZy0RHvraS9jvRafTcnUSEXXd4TC1tfQpLhsD3FJopXNjCRLctadk3kv/kvWeCOzLxc
# DATA pbdn5g0KzmZj79nTrUdtpQAGfNt+sb3x/Y2tJ2gCbtvxfCPXbd4rV7h2vO0smKGfhatnHxgsZj23SxRH+ip6TdrXTAx55Z4VG3VL
# DATA 22dNqiz7USaN8+S061jc1ZnXSEebKkXQpMsiojJ0zRaKKPbNzhOrt2TlbKWAdxtFn3RLmTI3/H1qKxW3V0WDDI7aQWH7LPLSVXxq
# DATA sxMGFJZ7fzAuIqsaTGNqlItRzL3lMf7WRCmycw68Uf21rEbI/pHfI9nvN56LYkGVNhYf8n1OZ+EPNx5978XzNoZQm+b8TLEOi8R6
# DATA WASg8jL2AdyhtRgZTFl1C5rooGhglJwrNruER3C4AxMRxjP1mMb5F2OzqyADTsIEk4hOGyx1UqC0nAOUjDonqBdolskfpACM1Y4p
# DATA M0Ui8Q5kCmaAWoRQk0B537QsQeLlFEQKwtSbgVILxRNXFhFjejAGl62VS+wYSu3bjHpRHKEWhJbswLn22pG4IB2Q0rPFA1KwWp1f
# DATA QsA3NrYpGXOyzC1wmGR2PfCPoV245HIES1cDqQz0gfVgAVr627ebwB2MpgA+iWwxQh5ZmFlUl4AvV6ha7MLCD54Iz/gjhCQX7BI5
# DATA QrOa1LnsFhapRePBqxRIyEGvW4v66bkEeVRZkuwYEWofQqBtwURcLxk6ex9bXTtknoUiTFjkbnqGa2rVcT/OxZXyGpM87NPdvc2n
# DATA Fg2ojofTBRyWihUnC02AaIksswbPwVuaIU9zOyvwtJ20xDjhI62dTIIlXRispdYaiDajZQVHm1PhWa1AfNnArBmAZAoSN+nIFKvz
# DATA 2W9Gb3OV7PwWTBMp/KTOGRvLODg0Pj8/Z7czPIQAtsInFQvAh5v5HgtC9NaXzgX8lisk9JJk60CywT7tmMyj15VlA3oqPYffeOGc
# DATA JcQyu+9gBb1W1abI3Y75cuML+nFt+03p00S4WZneejH27kQrs1ZQ17C17cpez9k5O+AdG2QGQwgxTXSU9bP8pAyeOXJQ4SAsK1fO
# DATA /etTX3RyLIvI5LhQxDEOpBIhyGDlDJoHohS6DkofXYhKeJtPv8ymqjMmmU9qICQmgRYCbsAkfVDlamppfPnjfANoYfquc+sLrdCU
# DATA zrVoT5qo8apXA97KzBG5iMb2OJRNrpnzV/Ut9fI8mF9j1lHiZn4EN6RPtnKlZ9YWSUrxovpPfXhjDaA0UCu5jm9PdjM4c+GYQC0B
# DATA WDULPmlK3ICTd0eTz6G2o8F6RCpFfCxqsbhoNUy7W5M9UGHy7VMQotyLTHSImp6ToA/HkPMpfNyFg1qkH3gTAiR/cLVw8+Yg6KlY
# DATA KRPBmzw3FyHFda9BXykvtJqBknaczljNW7V5E45jb2dje3fj0Z7xMFJR2EMKccPUEFVayj25rIM0xKLPefCGezAXbkKMBqpaaMeQ
# DATA iAazzMR66cUQSFnyarTOwYJl5Vg87BIonhlPvDeqkbfcl/Y84pFZjEhnMiIZVuutaCjRE50p7IR9OnivJs9m+1Xu2ByT52B5bU9C
# DATA GRzCy1lgQ9XwNT9p7rvJs9Ojw2LWnb7QyrTUAGaK/XldXVKX0wFaQGdhGiEyTZZknw6HDLiBiEDa6uq115SNFrCWAidLDjzKjsmB
# DATA y71abtUFVylenBe3Up1+6G/I7Zs7dpw6dJzaXlx1fNYLEdSDaI5IZmpzQ+ExvsE4Ddno9lKL/Avgk9Lha4L8hjdLqeCd6vK5m2MZ
# DATA YK9pqKbTAI1L9G2AGLVG6geCKyVHC6p67l+36R7cGwzSgkC14n2YAotqwStDc6Z1t4/bjIW3tmiKhOcmUwlMwAaBNMD5sIroZh49
# DATA +/7mzqfoBv7Rk61He3F1GtzS0519vYrTKu5kcXNY11kCsvRt12OitEtSeSa0nDrhbxI3SoFbGuG4SV3LsdhccU4DuMmnSAKXXpyt
# DATA DC0x9YqKNMKUFvFntZT4sZV1tL5+T2oEwq7ZGkJ/K4TpuxIeRIRGCn2Gzq6R70TxcdpPR3QkoaK6J57cR1sqNjXBpm0XZxAj14pL
# DATA BiZ5nCU99pBWt9Uxw5GX5X5o2iQj7PV1E99kLXO4iXuyGuA78vVyxDTKx+Lm7l2s/tAIQtz80eQq5Lh1lI3IyaSPWaGkhG8vofT8
# DATA VLQ85am3KX5NExHRDoqBbGOx6+nW1wUDGc91i7ub13Ur5D7ylgGXi6FyH7JO0PEsucXmtipLRnXOiRakec6GI/VkrW/BMUrkWxos
# DATA Tmkq5BI234gcRXPZwJy5k1BPPRWEcXq0tWJwvOrbziDkLjyPH8A0G0MMpJaOzkK2vG4IPiUz8JGqq1tcKFkMEVJWiw1aLrqCDPDL
# DATA BHOBx3pwKGNTGb2akfjPW459jDgC2pB3hw58hCPvNOayUYakYJWYGhYH5cfXaMUjAJqDU/IPIZ9zFRzAYtRsFeTUSBzoPY4CR2lK
# DATA w6bDwaAXMIVXgzBiMf2KrQB4aJrjDjoE6Eghc8ujMITP5q4OLGf2zDHYcRRu5m4YUU7AxFyYMVN6XtG1cf8uSK9hVUKCa8cFnZfb
# DATA +LlIa/jsUwa60DSqwgZMwftJpWxWvlVuGVXQDXGMRByxRco5nMiCpa/2e2VapMz8XzlAnaUi/plHWaUHper5zIq1yEHoPQfI4Agb
# DATA BYihea+gO5cNLvToXIcZFyZYhaz3BzaYsIrIu4Nr39fDPlBvfIDmO0Q3EjsG8ECIzQjMIixCLSeb5x88S+sC55epLF4i/IrC4Sun
# DATA gzLXt/0D16StNl8t7ek3hXio+dX1F8f9r3QAU49KiM/HdxJ5yVmMN1nqKYGeONr2IOuwGXHWhYrZUYb5OZEwMY8SAUoNvzL7kJh4
# DATA m0iZ4huruVariMerRpCZpz0l16/Mie89eMP4X5L+NXiKFZkphyTTKLNloUyqpb44nLsaUTAc1o1DYtkBI524WKofKy6W8e1/lSIF
# DATA 4cf1Kej/Axh2qhWAT8P6ZkIiJPLSUdw0cOQ4GQGLQ/7eOMzFqBAeQzAXF2z4MUrs4EVUQnfs27WaoFhra+54JUCHiSR3JXO7Y8f4
# DATA kRCCAFY5f/hx2hgd9waHlfhOXK1e1zAWX6uXnB52EyrW9DOJ1VSWEPYUCEli/Qgp/VTEXkVjnSnGUI7/alMfUuPJ2lSUa9jtWTwa
# DATA myrQnwfkykJvOsK22efguqx3MceyLS8cQOkY9egVKrHsmUc0F7TscdQQWkpzK2ABMq9ruS3rvqkZY9vRT1qvCtkEbepJoF43tqjE
# DATA IG4hABcLnxMktgJ2dWXEV9nhc2irwJwMVaVWyiaqVHRDykNeZMW4YE0LDtumt1LuKxgsvVi73MogUHxuvum7m9ubOxuWuvhrZZ3e
# DATA lLswWnxrRFyq6vlNSFHLK8TuVAV9ntM+QjVGTjg38p6I52Vs0LKolI+sOizjtHJh+6dpAXu0nUD7+eb2YzferdFmlNDANxHcFBUX
# DATA gQNL85vTJkJammue5nwHQKGoo5nMKde4hwwReV08uxBnvrqwUggi3lbv0FqWe1QTeytdt8Cjbtvbl6ClvrDF3PlsKxzjj2R34W+S
# DATA +9neLTVnnznwRuz0N5OaNN5Y86IwOTRGz1jzxqBt851LPx2vcf23FAq4AgFvGR3Gwlu0ErNkatPBcmbKtsiAgkEXUBvJ/4CEPXPz
# DATA WAK9OCJDKM6z3tgYHU9wsZ/Tl4oV6LkVbzECjw4n/S6g8QjAX9KLEMgqdJETYBxMxhGtG8q1MCcCjjlv6IS62DLGGG8n0lklrtft
# DATA uGsol2w912KCshpMbU4tY8VZgUVIYGW0EHVqPV69+oiNOucbj1BAiF46vGBMTIzh4EzvDdfoDarJsZl7gAo8161DpPAwBViTevQH
# DATA a+Z0YKrBNNX4uYEDL9x/vsBFlp9MKaiaDLxglEMfnSyORt0PX0LoxS+jyFD1LCLwqXo3mTZ7y5p1hbn86QQGk0fW6SSgGFzKmj77
# DATA +ijgKLxzWlgnh+R0F6DmrFatdBHkS1BUWtTiz15ns2bzrZe/OFI/MUvYjSZ94M1wJfHIYNOTHKBqyZo4GpHgmijVCD0Y1YR9BKat
# DATA ynCUwZWwAi9z1/NEXq4WUMfSLDVWIC5IYQBXMZUQpEK/kekvjgfoYuRzWxhnIB8DOz8qDGgZQL6+rjrhDIraTJIVK2S/vqkHC2Et
# DATA qtMEBvJHxpWiD7XbJMhqt3E32m2xQsChAX07rhDOgQX71s3/Q6xC+69kh43h5bfe8X9L8N+9tTX6C/85f1eWl1fXVu+rd/x+efn+
# DATA /bvfipa+9Q38N8HYEdD9t/77/M/PvXZ1m8VTt5vLtdtEatxu7l/dzrq3m7eJsBsDfICrcrt2m7JUwOvXf/fVT776y9e//OrPX3/x
# DATA +ldf/flXP/3qJ69/Hr3+ZfT6d/Drt1/9GbyDN6+/xF+vP3/9W6hsETzYxP8Jn//l9T9C4Z+U1KpF8PcvoYfffPU3UOT1r/ETdApF
# DATA oclfYW/w/7+Ct7/+6mcwjJ/C37+FitwiFP/tV38NH3/x+pcN6J5EWLebV7dVDhUYxINb3QGFgaCkFw9fvuw/wB9RDyis1suXt9M+
# DATA /PPwwUmadB8+OE3HCWUoytMxfiTpGX2nL3hp8fVZlp5jWCT4qSRo+Po8645PWl2gKjtpnR5qShNQz4HYS1vLpq2T8XhYR/h+hlUf
# DATA cSv1Xcxblo0v688Hvaxz6XUgRFg9H3Wil3Ge9o5exusRL7n/cnzZS7132emx84ZM5Zrr0eDwR7D98qkPSAsLHyZ5WoexWK8wKEud
# DATA ySzztrg61iHwxr8RnWX5hKjecXo4GLyKKF0NULnHJ8iTnAAiORn0ujmhwvEJUMYJoMUoP0XCmZkJTKgcobQb3gNaOo3SJEf1xHiA
# DATA SLER7Y4n3UuqOxh1sz6GXZJIskDQIUl9igEhadR01B8+R9E2kjdHaD0S/Tj6t5MsHUdngx6Qfg8WudADstcZpT2cRtbhmcFwj/B5
# DATA McnhvOSL+L6Rnx3jN6IpsewpNL8IL9+7OO1Rr3ZLtEv5SZqOQ+3hFjQ6eX7DaqTnU9V4KzCEfqHIj7AEEvbp6OGDRS4IP+gm4DXB
# DATA dH90REgIhNVtUEGtw2XpQZM0plfZ0B7NtxF9YaFd+IC7I+fgwWLCtw17teofImPhTMeo9rAZd1egjX5yBjRKltR7ySEvy1Okm+B1
# DATA dpzI4cMeStp7dpaO8B5TW1apHM5Plua63O4wwQscyXu/OB5BXXYHz+P5YPSK9oaKLsJ4ZFFxwkwadrGqWp8HkprJLMUQdT1YgyHT
# DATA 8sO9kwS2cIg0sXZogyMOv4FW6zeg+eWHD4ZQLI2wLlyPy+gkOYMfgzOU7mLmvxO6AJjKkT7jbhCZiSd10IigLrDNZA4HlDjctjFe
# DATA scvBBLcOKytBlbq60Ovw4YNudmbGzaAh90/G4WQ89i6MuxUfApGpujlMge/FeLuy0F4rqB4c9Ltwq5325tm0RRgrnnNe7cCyywte
# DATA 9JWHz0bRMIOBTYawSABajiawKINBD5d7BZf7UdLrTEgdedQbEPWfJmzfHRG0j7qj5BwhDtr14QrDfunDEXUHKW9lNx1jtELgIIB2
# DATA neDdgoGj3pcC11Ago84ASPQMheC86jc5f3q+i3jgHj44AlIeT+LQvVFwuuylQKkvcwnYrskdBe1BwYdq752hmERkWGeDIPsfJafD
# DATA daTXz5LOJQ4o+i//Et1o/LxratSLCJTwPgkuB6Rvuv0Dtv8Dtp+F7flYvgGSf8c4/s1Q/GwM//8hBP+O8ftc6P1m2P0bQe58Iu3p
# DATA a4T+384NIoA/G3cCpB/kqcKgGwptsjgPeiTsrvCnPWWkaxIzzcGROEDC3OFYkVhFtkiWoJONCPmSAM9bCFoeImkUCs5JnNZLkxGF
# DATA 8j8FpA0nq1cjBAyTyE7TbnQ4yXpjnAHCx5ynDCN9kWMVorbU+NQMsAeD0TuKHsh9goDJgUG/d9mItsaKhutgnm/E+LhwgLZI0mzU
# DATA 2ooUSLqIYUi8SEPETakTWYB3Pc8pjlG0m6avoj+Fs4LGWkq5cJL2hiSrwkFGydER7hISJMlROr7UM/x0MBkZHC1TA0onj0aTviY1
# DATA D9HYKR01ok1JNIRLivOYDJFaQTpTnUI84znRMFAAUygMkEgC8JBjmaR3Oc46RN3A3NLRGHX8xzCFBO0vlGkbttU5STuvSORJqh0S
# DATA ezqD+a8/+d9ymStKeckuKO8MhtAO0ZPWnjWiR7j/EenlKeIFTOwSZy5tYQ0c6hl2kZ7CTh2pRkniCnc9yQAW9dIa0YGYxQQJZV7b
# DATA vhk53IkxbTbUgRJ6RSJyDJCDNXz4eHDeZzIPF5ItyzpwYtBizRsan1MukiMRDkOFW44QrpPyQT8Z5Ly1aFM4IhL/VZoOzaVOOh2k
# DATA /XsDvAydDr0/xoYyjJCIgZdoMQF7YDt5I9oeULkJ7RoUT0e0ZbiW+kZho0Mc8EmqgAQcn6cIbbIxTwGatq8LrNgEDjcdc7mt6lam
# DATA F0As4hTPoTG9FEfEvDgbuQUj1oZLOQb3QGu8LgOYCN1LYIdGmfIr7SY4xEb0IQIftj3ALRkhXkwBtshxhX7Qf4u+8ZESav+N2Zz5
# DATA kM1cHM6cZPI3Ruy/Ca3/Dkh9l2gCev/O1eHgAsiXzzB9zSGd0jq8ucZKV0DxDHq9+mEKvHA2GDXzU2j65BrbvTpNRnAamkvrqOE4
# DATA HqHop3mWjCr1+jAZpqPqemfQgyr8Cuiy6jrCr+by/eHF4nLj3t2Iv2Bb1XW0MgeQf14/HyXD5iGcwFd1mFv3OrniZrI+XJBsvI6x
# DATA /esTNB0FWi+tD46OYELNxspKenqdNE+wnSsq08VcIHRJ6nD4O6/6cHebK8OLaz4ktaw/nIxrbL9VwxqIa65oiNKXKtngv1fdLAc0
# DATA fAmfqeujXnqxDtjiuF8nk79mJ8U00es/gtuZHV3W5X6p18CfAtGCeLW5tja8WB8ycdCElQCYGS03lvHvOu9Ac3l4EeXA0nQja/0K
# DATA C43Aoz92Vxrmq17Lbo6SbjbJ5TM/1GAEvB/1cx7TvbtL68BK5dDOcED5rte9ZWwiAyNr0tBXTK2OeXNlDRPAVD9ni6nCcZCm9olC
# DATA RVvuPO22UOl8cFWYKE3fboCPmDTRhJ1BrNK9GgyTDnCDzcbdu2o2wgPC4TgCAiGvAz2YIQaSqu5LOhTeOz4i3kt1YPyyk1O4Fpfu
# DATA 2yu42nhimqveplIpOPv8WZ1l2JprHgfA68o+sUiExuFWHlStl7iVg4Nq4QwTJ91cXlr6H51Ddw8OXcnpwu6r899jc3Tx5DbuWwdX
# DATA HbZVNQlv/DXrJY9fhrsCV3Ndhkq/+RDXi0AErl09PxnBQ3Pp2mkOaPWDKzW4pWu9INYqLL+/BG3DYcs+S5tEOQGauib+SN/v41HW
# DATA XT8GMNRYpZk512RpiUs3aEq6ThkwoGbuYyv+/bdbXYNWjzDrAuz/1dQ9UrNbbqzcVa3yAsK40mPA4ld2w/eXlnSVpaixBlWuT5Zr
# DATA Jyu1k9XaUEB4fTwYQvWTZYZ+3B3yV0gmc0M1zLSM+O50WFlprGHXtXuNu2fntbsNfKgCRF9ak5HKmlTXe0AJwZFAsSsOgL8CSKDM
# DATA GrV6Y2n1LlRdP00uZA7L9zon6zKowwHcz1OY6CoNemW+wS0zOK2twtBWaOFxaMvvzxgajGXlLi6n2zf1vMo9QyeRrDq0uOo36Nak
# DATA m3GNC6ymdu9+5+Q6Oz2u5WfH+tRQJrR1677KAUkm48E188Q1sjNgjC5XBdPFLa8swUGuIcNUwZpRPbqHMF0PhJGU3dLMs+ojLhKX
# DATA A+4fn6dpn07ycuOud5SXl+5qsKKXLXRyrxskveC1vM9rucZruVJcS7VqK0twIIJ4CHgJd0IEF4h6wH/44q0IaqW/1yQOmbkK/j0t
# DATA 6z1KGHOJVL+FJPCBT3o0NaWy7l3L6wZKg64weAIVPMou0u76Z3WSwcC81/FS1pdxl9cx4wasNC50CYjWYAHnSS0zCrrCVrDmdQNI
# DATA moECjnXOGXgP986FevCPtllD2Ds57efN5aNRBP8rg290Qan9qAGUA3RDcyUQq8gas6Vrd+EicOmj7HgySjUhad52EpKGWu003l8Z
# DATA mfuJs2q8T90KKzH7LLzv1V/mO9oQgt9bmrtL5lhT6fCZlsoEkNwhzH2Z7EUF8F0Af3ftUVJHEQBDtxQsHe7c1Rx7OUqHwBVWVmtw
# DATA zmFTKks12FkAG2ZE141OMupeWZjFwjr3CNX7pzCfjI7QhXsGfTGdHOV+o2ETuf965yTrdYvTpCINFJ/XGqcTYEqvbAKB3kBD+N0+
# DATA PB/wGp6jWb5NDXwQvFNh8vkuANk1+N8q/O8eklbePtH5dDaAZHbudSkh1DWCwUY8aMhzbvbHJ7wmlZV+NVJzKduJlSLVdt3QclP/
# DATA rAMYgGkhkNBFIqEGeAE14kfUilgff2CLKKu0kNz99/Fu09vIRn73l/A9zCcbz3NGYTEF4ijw4twSSmpz3UDZgqb2Vr7Oc4k9kTKn
# DATA SCIq3NJg8u0GN3AleAOpLTYGvHKAFZN7NpyP5MxNOQMyM8IfayGO0roLqwyOzk/IWRKhVROYMoKiakRNmMr4Us+RMGGDzdYdGrtx
# DATA V1HNcv1WGKwoWWSA0l6zZ7e0jqXqpMCRXowcs5ddzUFueDwKQA7gm7JOemUvic+Pqeuorgfj3QZvCrCXxxYRpYe+NAea4LpRguwG
# DATA 8INzHBLnbET6aQWfkKYrXggbp7jwOlqaj0BzRxkNLcQsn3JA7v3jK09uABckOfalI0zaTjmbeoNWmIkcuWfm/XtFprLkah4mHm2r
# DATA blIBt3p0gQ/CmSCQJiNmCrFKc9nis5bXCFLyVTAL7Qtvukl+kroLvH+Sdbtp/8C5QLc4PWDSH1/DdbvScrALIt1t3gj5A9Pf2oyr
# DATA by/l+2UX2xO7Jf3LcxRDX6NuhHf5KDnNepfNR0BiDQAv117GT7JDZfv+dNAfvIxrp/CH2nXvPKxlF/Bw1sutZVqZ/zyKLOXKk0r5
# DATA QiuPXld9Rg53S1dYmKhZ13XdxY404hVhfEyLqza6DxGdcxCA/pF/34zSun3WGbiL+FUKOGIN4lTmk08CxDbSao8TLTkOjWHW69VH
# DATA g/PZVLbQ1ON0qHddgdE18wmBuL7/awKgxyjCo/b8W3BNn9TGAYjsJcMcqBL5YTPQ9gkkxDw+qY27zJbRWjRxNA4eneswjqfRWtcN
# DATA GEF6RZCcAXhzebG+TLjRkhFZRAPTDIPJeDgZk0eCv1jMU5GVfh3VNgFqFt3TkvFgdKXQboiW5ROtAJ0+0Nd/fJp2s6RikWj3AKxV
# DATA r0qFDrakYfUewl6RKri3RWiSInaiw8JeFMju8jLZZ4b401L+07uUq8i52kvp8pNa6HKXYDXxRjcixhSxWj4eu/MwC7mKygaXQ5xz
# DATA WQoEQzlbvnKkZIx3LSpFVXxo81L28VzxyGdFxhbPxdoqnQtaw5qickvHQ2IZFr0QVv/AbI7DUKywmE5YTRc9zD/7uadLQCTA/xAg
# DATA h6Ok5z0klWZeH6XdSSft1k8HtC38CLcjpBOjxu/U7jTZ6AN+JEd4b5J+dmpERgbPr5NSJAt8UcNg7xx1F/ka1pQyyhd4MH1Muynk
# DATA hyXyZU2dBRWIChDe8BD401ea2/ALXV87GkNltYUWgvAnujjt9Un3iXZ5zcXF8/PzxvlqYzA6XlxZWlpaFAMvNCD6cHCBBZeipeje
# DATA Gvw/qX3xxEdsAAjP9DJiQGaeR1RveQV/HwEKIpup1aXV7toHaPj48AGFKyFroafL96LlD05WV87e/3hl7Wx56QT+ff/j5XufOZWP
# DATA Vo5W/1/23nXJkeO6932VcsgyuzXoHhTumOYMY3gZiVskxc2hxHCI+lBAFRqlAVBgFdA9rTEjKMm2tkOOox0+J44iHGdvx4445zt1
# DATA oT0mRSpi+wW6X8FPctZ/rcysrMKl0T3onltKJBsoVGXlPVeuzPz/BnV5GFEsropmNEJGT57IDk3kaTLPKUhGan8b35hvxqKK2zvB
# DATA L7xvLt9dpzY/mav2ovOtfEeP2QMQhbwWfmI24FlZ0q16jUbTq3cbXq1ZHdWrNc/v1Pfq1bbnN+rFjAlbYS+qLuZqu+7VO/Uf+e3W
# DATA qFbz97pNr+bT49XOEf19B0E3q7ViUNFg4HMe83ThAaf/W41ms9qM8ot7pujrCy9FqB3/qFHzx9W9mt/AK/e6XY6MiojnS6245Btq
# DATA tapXa/hHfq0+8n3fa3Z+VOt2fvZuo9716j5Vn1pn5Ffbe432j2qtTjF5nX43CoKFINtNypXu0K9Vx3utKv1zhI8NulxvdIa+T5eb
# DATA TfrniD6WYt5r9aqNwbKYN1bWVLV9kSrqLZwsfKQ8wbdUDT/g+f0t1VgO9NT21rdazVavjgvG+0SP8P8OjEGzeKV261uRHzWj9oHy
# DATA sd36VrPbarebB2Jh3PpWb9Dv9PEEu53p57BVr4UHsrx/6+NX7keHSeT98G2aLnwYDMn2rNzl7WMZdYV7WZTGeFZ3aRvdju5pH7st
# DATA yWTKu/RbYk16taLTuSOGgLndjEZqfvPdiNp0HFQk6NLS3EHZEQbjrNLebxwdV9riCOOA1U65Tab3a/1bNFMthlh2lNtmniqYxQe0
# DATA D704ThTumhasSjE5+QaMP/0YO4keXWB5IF8LEA9gySwSp1X1YsaNBxdteSNG0StQXWnMFlJbWUjaecad8uwt1DE2G67SUvl0sa3/
# DATA FE3941ewe486ibg/453kE94A6f0l9MW823fMFsj9T+ZRenKf9wUk6U62a91rbr6bpsHJ/iBNxjvLn7s7GtGj1rNqL9/3oxNIL+pn
# DATA 0ML3sR2QYstzS++G9/Ert+wIjqMxTmcLduzdYLrDgRpWOMsZP4hOKt4gGI1QuXe9RzjwT/+VAEQmn/eU3ZdIgEj9NmX1jhWpG9Ao
# DATA 2z0wVGGmq9BL56OR95q3I7HYHwYZXrZLl9QVCkqu3LIicMvD0U/RImCx/QPvUxxV7g8pVuoNFwkRj39qp5oP1UuyFSr2kX48k8f1
# DATA DwcqLwrpz1akvyLxRi2ZHMaDE42tMtmCLTZL0jLA4e7FSAYnO5g875qiiCBQ+5c7H7/yLfH8fvwKBQ2xoWgEROs+7lanM+hGfDso
# DATA BTlMjleGKcbohcOczMc7cbibp+a9+bgXpTsc5scQ/aNf93VuFh4N1SbSHZFzQ+CiZ0Fv+vgVfL1JzTmeHOhjLnLG5ZU89vMU0f/h
# DATA B+/sy47LH/DxEPoO9TbvdWjo/Rjh/KTiPULAn6Iw5NHAbkjy9FujiPUyPn4l4GwI9rH7D5o16QjfdHzRmijGuNQfxf0H1Kaw9fTD
# DATA eBwl89nOzi7aOCKVRkdkVOSRonDAfSf7VWWFRAXrG7oUMJvAy+18SibY0LwzmCDhKBs8wEJ4Ywh9vHVEkX5Haa1QGNm8N46pICte
# DATA dMTFdoce44/7UI2hv2/KxqwdVdQcEE3HaSr0I9A74tnJzi6FP8ENn6qo/iWi92M5cBEcRT+hSO7Tg28F/eGO2vzJLxqR0ZwFIkbH
# DATA vQtFCF8Rnx//RL3xL6QHjDP+u8M30Bv1cz/+iS4lyn/sjocu566EL9dPWMmS79+nUWU0D6NMRSPvEOlXep/ZJDe7q6XtUcLW1jdE
# DATA 7T432p0TqHWaZ4qVH+98jSrmfUkOdTDyGeeNPj3QUd3JH19SNlxf8D6dnG1klf68QXZQAuQuMqppartzhFiAHXzbW3r7Le/H+/v8
# DATA Oawsu8MUFFnAGZLJ8eDu1UqMRLqQRejd8mdMtpp96PNpqDeTFzbwq3x/XW17X77H/UCekbB4S3umtrPjTCgZFEfRPrfwT+XfYvU2
# DATA C17FOp48zCs435LpYqOfTKaYh1cXoTxMZWhCQSEikAUb4ONXlu3ks6PFv0vE+KNEgItBgs/rg/yue2L5tqyK8skbu44qEyTXyLXs
# DATA l3XRvqXi8jEkPMdke0htM1FYVXNW5KeOgKo9+ivZd5NDmgzC9PHYjPfMe+liqZbp1rKiXh2YAxXLaxaqTV5vVN3R+QNz1YzQ/E31
# DATA 5HIDjfo0t2JjjG/R38vdvTTNt0XL1GQ/ZzLrE3PIr0kuen/zNxRrVAjqv8Y79Cd5JzmO0jco83ZMFlNDyFh8Tb+y8DRZSUg412uc
# DATA mKD7qgee1SCQqcVKRxfsqsGiixDvoet2p1mMTV4TOS273l/9lbejo3b7to4JIsUBmSpg8u32bZUU1F/cIst69Oa/4ChIc+OPu5KW
# DATA GzekoJSxg5VDnf38JTd38G1X7siDlfxA71jNRySlVCRliBtMIPLbrrqnNHxIWFxLOYZRxgMHlbwu0SWNkdsR2qJVKZAcU45rG3Dh
# DATA IXoR4qiqKWWyDmS3WONwo7I4dnZv32Gb8eNX7plDYWgmN3Zg9n38ijQ9Sv935DvPAbm5z5J72Fa3U9u9gQT/79/vf0z/m7ypZ8lJ
# DATA MmNXqxfMPJ9mLDckAD5sRgHQQ8vfQ8bTzeKt+bt8ftd//NZ6UEdog+f6Y2ncMgPMD2S6g9nuYPZ5B7PdgewX+kC2V9hurM5BP9MH
# DATA tY3njH8unAAcWce3709ZLQ8jWxwCNqJPb+e387ZiPif3bJ3nfl5ONZ4n3GI7Sjn+4nG+8yr1tOVmqBfJEA2zUtGR9S5rBU8uBCP+
# DATA VjyoXl68kibdT5C58qaTSV9HQ/mx7/xgYe2LzVSyB0oH/61n+AungzNgeoeL9haVO/RgqLxgD6WzE2wqNs9PRTcgGwZ8IlbXKE9t
# DATA uKBpIR9HnvdoXPPg1fUwB6EwP+F48C6lOEn3vR9Mowmf8x3w2X16SB3m58rqUVhD1Dqqk55sQ2AME+6mN4OxQAFNlG7Ahso7XsnH
# DATA rXUE+DwxR5usBTKyD3EuzcjwfB/HnFHhcLqbiQ7e+3Pj7vUmuMzqR/KOmH6aT2E2ZPsebCn+MWOTKhnAyUMtJoSlppoNmcsJSwAM
# DATA 5ilZEfNFNYQX87CtCcFZb856O896K9Ywp6/j9HUuaratNBCvSnfnPrawWXIQeA18mxDOMwo8T0/jbd1wid19ni1XV7DkeP2D7Q8s
# DATA iqgtOfoaFzY6IbFj2SegM1l5AXfGu6+KT1Q3wAmvR6GQJDTznOmu8ivsFePtH/tN3kSkNawp+bwhChfHAe83aqrNJNGUdx/tS89+
# DATA k+NYiqp4IUx1wLcNIqqfMvE0F0w06/utLUZTPCP0s/bS8IVXxdGqIqXvMZEyD72acIefR66GN9/xb9Wqr95MlFVYvqep7mmuucev
# DATA qpvoQ37XTYlWnhRlq+vcVKtg9GDeDGa25BGZDfwEGxLpmN7Le4JVOtVqKEYvXTXzS9LzxEf8oimN0zPJgZsSBOZPKrdkndYOJb+k
# DATA d6iZK3csgzPAhMzqAGxpKjYapdnPKVUQfjEG5bs0GFL/LEaj9lpb7R9jbDThls+Gohlo41TsyH3vbhh6fCZWmQWZHj5zG9J7B2so
# DATA StUTEwEz0s4hmy6OXjZKxRCnHgdvxC4Mett0Phrxj3Msw9KgHqfa+P9hFonyjojYiO5P3Ispi0ViXotI6TqPBduMo0BmCQwLNqXR
# DATA E2FeE2eYFlKSJtL5aZUrttdHEL63ejmMgb2I9TI507iDlyLh0njxrWZ7AHSGszOczzOcSwaSs5yd5bzeHH4GFCs/pLdx48hEMy8I
# DATA VWvIzeaSZiMGF6PzxoqID6IZFejkUKTtitKLwgRLBhi3EiUBmSslih5i2Ugu+WexXVFKQW1ZfHVYZ/05LeSsGzvFuC4uMyNSCQsG
# DATA +5SgtxhIdFkMOxkMsP0LMn3cF2TeMDmmnz0qIRkuOa/3PWVcQNKSYneEcRf9TDLgjoHz3JKvFJ8VJ6c46M0C9mbeTTFcjcxIZ1Jk
# DATA J+0ddsoFfbJxIKR5TD1WnjKMvHs8ZZAN0Yw6DUYZbxeDpYMkHpItluleLaTCG1JvxqXEyZRTPhTChEXF4UYk0+lQ5k5ixGh/WTIm
# DATA q3Gm1AUDWAUPPK0UsiadbwYn3BOvTyjKUFyVKGOdxvvK/ziIIkpWGA9Y2o9mdzDUIHCIPYzYh0DVaiZbMJhuTL+gKeIXNgG9DxnD
# DATA 4zFfEAGyZcVMWTgGqSrqhBiLrjc/kUp9MkN9xibRNYn8IMqWJFDMikIVXhRUNVWdrFT2Wx5DFR6VbIQmyKNOGi0zYlGkFW1HgvAW
# DATA hDHO3slAJ3aqEpOk2vsB9F9CykSyC9n2Q/Jh583JmOAnHojHVbuUGVKG2j2Wd4o9qafSWup0EKdjXhxZNrflRH1IeSPzcTB6pzhG
# DATA SmaSUVunFmSs53zxOxP/tdxP+cHVkUwBNT0PMrGFuXfy3tXintS7MuyBTWkF4jY+ZGo8D9g8xtSADF8q6WA+i9FtBCnrdI2V8iSr
# DATA n0qHAi6UuI3JQsB1NaVYmdrvT5JjqZ9oJdRE0EdCsFUn+M2Ew59hXyVyW9oiJWgKVwJ3jTy2iV1i+RXQ+KmUsaUhHhm4VsrThZSK
# DATA m7KPbCTKMEkhFTkOSGNHRrCgIFvohnmKMDkpq8ma+YQtK2vZ+WIzv4DW/qefVgxDZ3YIOG96YhN0/r+zX57+8fSb0389/UIxcr44
# DATA /Zr+//nZb7zTP4BpQz98Rv/+ZhGd8z/ph8d002Pcz/Cbr89+ffqFR19+ZyA6X1Kgcpm/ArTzi7NfV7yzv6Xn6BncBnrON/Smrxjj
# DATA 8/f0gzB1vjp9fPYrHZk/0y1/FFAPYDuOpfMczGbQKeP4EnU4PfozK4hmH0YJhZPGfW2C7XtvPZyOZHwecY8YSd+QDeMp9RYjyxuh
# DATA O0esIk6j3GeQz4WS0UiNT/RSLfO7FqqD5UQVnmopDq1TnN/oHuS6wTrLSubq8Dp51TG3wqTLL5cfGInetLn7HfnOI/qWCTs8rqlh
# DATA PVGbWzGYOsDOhsW2fcQO1t4jtj5ROJXcxcjGL3IPDpksigqG6ZDGE85HltvPZpiplnYra6QmgjCHUuLZAl/n/Oq32qG5pGU9LczO
# DATA +clwnB1nCVyFJaCBO5c0AF4S5+a1Df5XMvZvNPRfdOS/noFfqudiPuQMnmevdV0FjMfKAUbxFF+9JL2LIA963XiqVhJV4VGepXip
# DATA At9EkjWZypuKpySwvXR4MhuOORQ5YMIZtCmCRxVZvhBJHfGI8TJzrNRCJX2G3J4p/6wckxsERwlGBcWa0THGCwRuwsMpPagtBnWu
# DATA 7iC3F4RYBN8PzIjjYDKz3WL9ZOoYO46x4xg7V8nY2XRU2Wias6mVfM0m/2Us/m0Y/I6242g7jrbjaDuOtuNoO46242g7jrbjaDuO
# DATA tuNoO46242g7jrbjaDuOtuNoO46242g7jrbjaDuOtuNoO46242g7jrbjaDvPEm2n1gwuS9tpD5qD/nNE21lce96IucO5q3IPuzI9
# DATA flerVVBIazZKud5odYrcnCjqDBTYCIcbKXp9DrTeYhmQPodak2BYKsNvtIoQnzpl+BI0UrvhNWpVD3Qbv9kd+Z2qV2uVqD0tv9ns
# DATA 9BZJOY261/C7P/K7jWGjc1SrNcd+2/eqP/Kr9WGjfVT3i1Ho18JGr7ckEc1ONU+EX+uaRNSLAdS6tbC5SOyhjPUa7dpQ5aJFzzEP
# DATA LNBzWpeg53CNteg5VPkL9JxmoxNchp7TDKOBn9NzWrWW3w4NPaff6Q3Cbk7PabWafufq6Tmqju9xNTbjQl0IOnq4Ldy0zFFV53Gk
# DATA 0j06rnTYkiqsMTX7w4ONSTvltykHt+3aEhND3YWjBdvB7dghLuJ21ESzY4xVlPEB7+QYBmFyfKvqwbtR9XRJFgA93K4XX6Hd7sY0
# DATA b8v6SSHXSzcV1spkOC/BcA5W7AdYHK0UJWmZp1bWbdeErLoaNbTphpLXjIaJ3/muVNVnrKb4FEr7HBuxkHl2YarE6MkLrBBH2XGU
# DATA HUfZcZQdR9lxlB1H2XGUHUfZcZQdR9lxlJ2Xi7ITD8R+w7oHavwj+5vUndtqxFQDl/xW4bq4e/Cphel5JPmGzLjNweDUkQnmBj0B
# DATA /M7Hr9xYfIeq1Ad6QFEvWbwxv0Ud0KC72M49UJCg93CMS1o+m/KjEz6do99ajtK+99fqDLx1KI0PnqGsqUKZKOzpG+iH19aN+FvK
# DATA CmMzm6Ty4tT+7OEsTzP1jh+/8o518s4kg7pLlQKZ6JbO+bgj6O4I+sZH0IsHwtxZdHcWffHU4Eq9zWfhjHqpjhdaiy1Ow54/FqBF
# DATA Zc5ytRQlfBuHUZAV0C18IhrKliAX8UiTUXcm54S1kgpvpSudlt30DDongfUZMZazOJ+SBKVXwYU6FT2+HssuIn5LDoOqXVaL+vXK
# DATA dkUV5E9KDV4Jh+sfcz1zc4W320L+M+JwTPTizMrq1SrvxiBmaXT5XNR4t+4w3af91IJCOyxKHO5Ehyb3sbjrKkF31aVyWN9Vn1ff
# DATA LcfrWeWOP62+k/tcJTPbj1bfJ/02p58/rRGVl4OmWs5d7FBbzR1DzBot90JNgP/clnXNf4G3nrs6PQ+QTzrPy3lWEttkt77pBcSq
# DATA 5pqXzjk3/vO3/92koxxxK/+nLFGKPmcUTHP9VbWUyHvS0jkkEmCjJSzFMIESPGtRQ600plrIUKZgOqU6yfq61DGj9dEkdjKT4//Q
# DATA Y51B/0jr0LJWNS9+aJHZY6rc6rC48nnZLTM/+aybRn6w2jjOcFklxeSMPnpJF9gXzDWF7rVAAGXV1gsVUV5RL1pAf/e/VheQrvRS
# DATA PG+jGKgiZ7qAPjxOqI2m1LF5+pRfpkwQ6pPmE3giaUia7ntv0ygPI2ecHIkgBaWBBQcgbHAYcbeKApL9w6qcIq1uoUrryUvFpODa
# DATA ysV0Cxctln/8n6uLRXUxUioiB9pPUpqMmJYzURNhuczTnB5rurKusnzypgEaViimgyj4DqgPT45VERXtSJZmZ7O4MA5al+MZjOgn
# DATA LyU7RddWUHm/fOEe7jerS0r38VJUHwXp2OPdXXkXd4xrAscJj6CFTSVzSAXD6xfo6yIZ7iehSGlErB4LneloAgiOlICaDfQiJnfE
# DATA M9HkwO5Y+2emTjx5+eTJuLbSeZIR6P/+w+Yj0BsYZKNUhgRLB3zMdjXFK32gLG1uUsGI1csDbzyn8WcUpNgnN4V8MjLa+5EYj2qA
# DATA IRMJDANpNijxJy+JQnSfh6byT5s2lfvJYOb1UO0DlE7erWGM71EWjaFlA82YPo08mBywInQQ/jTA/hxV4zMUVsr2eDyORzhvgJyC
# DATA SgVZ6p/MY1GrgQoiC6tIAWpF6C00lUIyLlVARSNQPJq2EWiuSHbfeS/RvketKcSzD+UTTFKhMmKATrgT1wWrhH+ehB30coi7ODi3
# DATA c6VdwpXmPGcviefsorzuZ0LdsbD/cj22W+bcNJDOsFWTLMpDdmqtJHc/oyqQz5Fo2nna0Pa+x6ugeC+2kq2zvJfKiK4iei+mXN1m
# DATA 1LHF+YJJ0L7nG0lsdiZVxHckapDHiXFc5E4mRe1TDuExoNxG5i8v6Io3zwRfCllACgY7IyQJWVkLe0mtUfrcXCdzPc1LaYG/B0/X
# DATA 5BDQQAGMi26PkQK3lAU1+EZpZt0ycqIwq3NRUVtJ1GOfCVmsMyktzHtgfXvYiAu9zaNCfZDNbJJZvF0VmqiTvMGLdqHOLeTw/stk
# DATA PNpBOPPRmY8bm492XXPrsG4d9gmtxpVG6tWsw74r3E9bKTonHj4dUsV1UMJ57w+qFx8bLCxzqp9yvLa6dWG9MF9IypfHVq0t2ssb
# DATA 9mrNqvtLjvbSUsKqpwru34JPe9UTZTdl2c266rmy96zsFVy5clooBd5khZiiOoVxyPVBFppee1XLV6piUfeCXy57ToUlrs6ZatJ5
# DATA eREch8w1f8+2qDzNvadO3bapxGWmX70BRZw3FYxPCg3o+UWIY6FpxiTUKXr6TFmqych+SzTV44nMONkEj/RMykAkqf2Y1ao5mwoU
# DATA Gj2D597UHQn6Fnt49pRACE8AjMmunvoIlrj0PbLuGIprmfeVU0wg3I0FGvXEzWSx4PJ543KncV7X8r2F4HjqPopKulTC5zPAXxwr
# DATA 2YIDshRSMi6wAf+7gvh9c/o1/fun08fA8D328I2xfN+A9ff16ReA8i3SAf/X6Z+Z+Pd7dffj0y89BgX+7vSrs//j9I+nn5/9gp79
# DATA SgX6pUIIfnn2S1yj3745+8yjLyASCggQZELEQZ4DsJC5gX92MMDnweov9N2D6JhsB55ETwNI1yoIAHr18QDyET1IdmkMCHV8WJW9
# DATA q7C6SY+ZB6p77ulOS/fZ8ym/Bk2IwyMjoy/+k2g2n65FAN6F1IUXzjNsdqH27ACABXtf9xLXzf9bLJaro/+xhcWElfzWQn0r88xv
# DATA RifRNI7I2tD3v6UueFAZAkI7SbeMAWT1MEZCz2c8/qszWtTEHAlw0yLcPgqQ+hosglObn8QDdDoMg2eIM7bLpclDaOhEfHZZTHkY
# DATA rKiF1Ln1Z9jCMGfpf/kxU5tP9N4TXdHEpUqWODNuMI2LDycLWMDNq+VqW2eh4T0tOODmiXGQQGchbM9C0GjASxkGL4cT8NqMgiuw
# DATA CTYyCS5sEVyvQSBVtJwdxgx4ZlrVVSABrVSr5a8VUdRwMXZfPDjxDtMgnAcK+pflqw+QMSyusTFqsLgocSKbPrE0f8SuJ6y1sSxi
# DATA No36GPmNKbYRHNCM66zMTQnOZB8dZeAA+DKugHvJYA+Vk/tZqkP7HlRscXw2EMsBPjom4Kk4KLYakj9N6VLGa6mqtJX5JouEHFm+
# DATA 0WTfvvdeBICcXJBNe/fnMEPSZH449OYTKqaZnGHnF2cOI+gwgg4jeIUYwY2HoY0mSRc1qK91jnCZKcI2ZwiOKuiogo4q6KiCjiro
# DATA qIKOKuiogo4q6KiCjiroqIKOKuiogo4q6KiCjiroqIKOKuiogo4q6KiCjiroqIKOKuiogo4q6KiCzwxVMGpH4cC/JFXQ79SiRvAc
# DATA UQXLK9AbMQWL8Lxuw4LntasGntcu5mvYjxrhYAl9r1Wz6XuNnL7X6q7M27xgxn6149X8tuf7Da/T9rrNPb9Z8/yGT+VFV2ttr9Mp
# DATA YfnarW6n11mG5StEmfdhLsaXXmghD/22iW+zCJisRq1+e8nztVotf75ezZGJnc2er8srVX41a3l+bfZ8o2nFv27l94bvb3Ys5GOj
# DATA 3r7o+/2WXd5+Hv/6hvG364uULT/e2OzxVttOvg173DD75RGV/Fb3ou8v5l51g9dfBBIpjURDIqUvsyCR/XYQtv0iJNI8YiCRtWq9
# DATA 1+wWIJG1XqPdauaQyH41rIYDA4ls9FudTiOHRA78sNUZXDkkcoL+fC97cJKvc8gRyqNoC+sONcvVoW0uth/Ma7VFWDB95GU0m8G0
# DATA fskeFpXhdjD70C4q2vdWKPad2srZjFhZiKhe9FBcRClBfY/Kkkeb5tp+y6Iaena2qNs8vaulmDd61op98gVHawnouGaHgtqPIOnY
# DATA y+iHcXQLoperKY0mHyql5K4x/cqFXFlbXuxMMUUm9uBCNRHzqbZJTnEIjgLpKJCOAukokI4C6SiQjgLpKJCOAukokI4C6SiQLxkF
# DATA chHiOA4Ob8PUo14dZ8woyTflqz7JgkxQyMV3bUUBtKob9DTVhXvYELnj7974+JX/+O0+Ew/vLtUZ4Gd2JPxgKocN8EYKZteEU0M4
# DATA //tzCecNtHg+vjQOJvNBwDr9cqpLziNSc57K0TccqgoEuRA9pBv58CeZAxkNbQVCYuGMjjt9707fn3P6fskRLncW353Ff5Kz+Cv1
# DATA OK/0jL4oIiZ8EDk/7i3DymtGn/Ppy8dch1anjHaQUTVRGPABWWV17ozHu4qSqFvohB0guaCfDsJ0a+aCUbRsN4tKkuN4IuteVaU6
# DATA yatASm8S+23419U8RTMo21XlovG2AjFRt6+Z2NeayyJfs6LeKUS8ut9cHXUz3ttR1xdVPdoJo8M0oqn6OSmwwjIpsK+ZFLSWZn/d
# DATA zn2/tibzVyp06laCGi0dxPOqzmmNuMxDpDtTac36iHvB7MO8aba8ydCrYhxZ753kjdy+gUX2RT5fijvKZtKVyJOCZzRVIg+Db+6d
# DATA CMqx0C9p3QHWr9ChUT9CRqAyEDHfm4rZEMaY+/Fj0BBmSY3j4EQGHilOHvszLaxxOA9oxJlFEUuDK2GLT6iDI/MLR+uVKMiSGG0g
# DATA 4PniHVgvjYrOsnaW9TmWdclocla1s6oLVvVqttKzpHxVbAWByS8jfvVD8PeM2hFWsXOtI9aTgUu8YvSbBF0cjeNsyhI03oeGrsLG
# DATA O+vmRPDMHUdMZq14es8GRqVoimX8lB5B/Slb1EWC44LYlbmPhv57sZI+GiZp/LPESN4oBf/Ay4IB+DpRSkYRSzCZUsmmSa6QzhJF
# DATA LBqlZhFRkJ3wyDtMxhFEeXg2QXZfRTgZIsWDe2m0poE1hgnBnVVGuYVVBKUGjq0KK6YMBdsmjHTc34EwT7EDxNYJpdoDHmTeIRqb
# DATA aD4J2LCherXvvR5PEtQhekZjdrUhMIkeztiQ5CUVZJDqR5MMbivVwyoTSKrAmF9mgUKXGRNL0/Z9G4wwSg51Cj/AiWYpN6lWhTlb
# DATA jAVZqH/EuViR4S6IhNfoRKnlc4+fPZCalo8belOkyL9mrP86gFQ7J0IrkjL0lHFhHp8FA24b2TvL1iXqfZHzklYRnSjJLIzU0zF3
# DATA YZJGUQUT+dleXh7sAMyN02BmBMPy8YjygiospVEmnEpPibIMu1xH2F/CVRlHaFK7Qp9k8I1zbB5SADMyDuMQNNh9782EmySGP6NM
# DATA BhE4ZTAO0PmlVmwWCEhsWZ2r+2ri0gtUYc8tBX2znmKYpOaKDBInckGL7KvJWfF5/rE49dKLU4VpVZWnQKo/y/syJhZIzc2h9kpm
# DATA /4ne5xvyxCg4UejwoqmSUU+43XfWeAhlXE8Yj6X/2e4bsE3xznt67ECaptGkH4+2+xbew/2WbkF6Cc3uQbf7vqYALAaR2TNEDY9t
# DATA yQm1tuK7bs5HV8agffHmV45E66ZWm0sGu4nUCz+Ruih69tmSEDZ7eq+CYVrO7K0TTJcoHZ/PLx0VCAqiAcxuyKKu8Bq87rOlo/w8
# DATA SohuiFvwChvLtRGey61KvpjJxv7C5Dif9la8Qyg053MazMK8ABNgbLUy89A+TYFt/VhRbcWkKZuVZqW5N6HkSdD2twjoFmotWS9H
# DATA 0flC0qiT42CqQQ4blcGSEn0/jdijXlDDzqIs06zCl8h0ywlXveBBlBbwVv9y+gWoU2efnX6tGFR/ZMzV52f/jXFV/+6d/R0wU6e/
# DATA W4Rb/TNoVQykAsfqs7N/9E5/f/br0z+ffnH2Kwr0ccU7/Te65U/0/Rf47p1+Y0IDNWs18OoX4FrRfx3T6nkg2VIdxvNwNlAFYwns
# DATA gHHPMkSQtRXzSBDCNQG5ctU5YU4mLo0JOy24XxooME8olxL0cbK/Vhh51HNk7Olai7B6HRto0U4idBYOYGUboNIJXDe9qlwiV8eu
# DATA giR0WHrvUmQVVzFz45tc4a4GVkWj3lRt+kUtxSbhJAxOeB8h1Y8HkQNWnVduW+dUvY5mwCUwjVKcFWXFehzHGzBgW05femS7Q8tE
# DATA rYJYW/D0ej/E8g/TKIwjeKPBKKA+NUrh7cqXU1S/GE/IHJpLDnvjeSb9mZhhJ0L17sfTaIFitUlNXW3PlJre06JXbZIIx61yVsCl
# DATA rQCNqbrE4P9SeJ6uaeDf+ri/0bC/6ah/XYO+VMZi6s0g/7Qay1XQp4pJ9IbRaArrhAwPIJhN5PIEp8OT2XCMFVlJ+i0ZaiH0jhMu
# DATA M/4AtDSyRVZHqcMEzehtMvCDIxonM50dqUib8dYDrMmmc9ZSpPiPY8MFWs+eUrsj4GGKsEQd8ZkuGYg59isGc3FxWAYB44l4LMjE
# DATA hNhD+w8L5gXvA9SbKBQKiF/CAgpATdE/2FMBO0+vkc9nCeSh+kzqcoApB5hygKmrA0ydN45sNJfZ3NS9Rqv9Mkb7dmx2R5JyJClH
# DATA knIkKUeSciQpR5JyJClHknIkKUeSciQpR5JyJClHknIkKUeSciQpR5JyJClHknIkKUeSciQpR5JyJClHknIkqWeGJNWqN1q19iVJ
# DATA UoPBoBn2nyOSVHHleSOOlJ0ptZZXb3c+2Wvs+Z2O5zcbe7Vqjf76nk//NLoefS3mUD/q9OrNRR5Ut+3VQH2qe361M97za/RPQ30t
# DATA gaAok6v93jIQlN+VgCn9MQ3cGn1Ut9BL9WbLKnrFQRIoURFcFTWCqBktRLTR9r1ah5Ld9Px6bVzv7PmNpvq2EM+o1xssjWd9sX5V
# DATA m16j2Ry2qv67fqPmNTr+sKn14iwGVrNRi5YFuVhjWw2Kad3/Ubcxrnq15h7943fGNXoNFUsHn/dqHfqy+EPppZ1Oq17rr3npRVBH
# DATA 0kI06kgam4U66lXbfi0soo4G/D8bdURfg0G1gDoa+OGg5+eoo3aPsiowqKMw6De7zRx11Gk0q37zylFHvMNkj00PmyWkIlucffoY
# DATA CT35LzVzezJgM41kZrAO8sMjV/7mDehDBSdcyzjhZOltEVBkhb3okOcRVrbN0UPRg03hRNrSqJUD8C4wXq95bP3gvRJCZJWg7Qv0
# DATA xIRenZ5S4bZRqm1VtMX8WZ0cRxJyJCFHEnIkIUcSciQhRxJyJCFHEnIkIUcSciShl54kNFAcIT56RQmuHN8efEcuDU9CWT0E7IeM
# DATA m0pmfsoCtij56om5ehJRj6wua/rQPYTLBKHBDcqhQ+YDfUQxlIvHRRCR+v0+Bc8/Z0t/fnsCUSQYC/Q+vu9k6X0fJrNgJOf7+K53
# DATA g9lwn/0GO4MbxzeyGyfqZpszlJ9kcUel3VHp4lFp61yTOzDtDkyvlvJ7Bg5S40zqIK/mwYkX4PeCvPmMlU+kPqMEjEQ46k0FP0M2
# DATA bzRKjtef9R3HD/n48TRNkoE+fwydcdNQafzFVpR5GmVPoG1OI2J6gqTMKEuQPn3c8q6XzafoVKNQteg4M+QjsmwU2CilAQ+1E3J6
# DATA o3iGRZyEJg8ZK2ELyKSfzse9A2jDxBM+j52ZQ9UDOHuP+PzuR3DhFhRMUtZ0FwXtrJ8k/ER/PoXMtpxrXqeg/QZsiPRE9tF5PETl
# DATA SRtAZB0qgAiSS3USRWGmuzNJbzZLxVymchwmo5DPuiLmlFiaA7McOEplgN8OKcqjExYKN9lmyk6UdVgmHafStSo6pwETuVEyQ9Lp
# DATA Ui85HnnBKEv4YPBaifB7VL256cixbXprlFqFx4LNPbY2Obv0zXGmT9Efoy6ie2ZxnxHO96If3/dYUT3vyfvYkBJBHj0e8clcnI3P
# DATA 9r03WK2Z666nATWoDhR5hIrUBiE2AnFY5hiiUvUPZueJunPOcZyPaSAxuoLYjorz7x6O0uBl1HSCMb+OBjouHSUJ35/PpHCxrWaq
# DATA TgOLTrw5740ro1hRuFAtfgaZeobjZEbR/IGEJ/4VDpFMw5GdJbE5zx2k48vpmr8uQtTIOmr8FxY2RyPctrL5B8h8FN4Azmnpna5A
# DATA 0DxnW4rgEYqCDVEv1yO4Ak1zo8zIRs1EtT10sxjzrkDi/C53+8ZWUmoS16cE/uIc5M4DcTMKN6MozijKVcpNK9y0YuPpw8rpx9VN
# DATA K+4jK3IcjkRHTymeeW3A60CUiiONLrPny9s5PA+LqR8wHZa5kNM5qpcBklZXYz1z1x7d8j39xdv59nmRtR80ES5czCmenWVxbjSt
# DATA KHc3Jaiyv5EJJaPZBrFUt+eIV/W9YFItRM3OzHqRkLomauL0pJ8LXskNIqkfNLE0F3K7dr99XkRr6yK6EoQq81eMVlZLe35pqNLU
# DATA 4qwodmQ0S+9R30Ktwzs0c/GK1+p82zP11huTSZ159Ya65xj+aZrl00Q6OkzRUfJTGpmF6bdws/hG7o74q9Jhk5mpgZzGrFYb901X
# DATA hzdGD2XNRE8ZsAyGST3CKkmZsTyX1ZdpAdtMWGXytKxCYNKfT0skdur0QaRV0DagnL44trej7zjbe7033xnaL6ShfVHKzlMWQuUd
# DATA wPkG2UUD1IbQsOhgoD3YRi9UkrCaQvNU5VOfC1lB/u+WmUYloddtE40WpHKX8ow2EK+19lHnErb4FkG4MgkGFUPQYStrng2VgVWq
# DATA p9gpLiWrdou/OqzfuZfGWLfBLkX2ItIlMOrjh7Bh2Psv57mYdhgXzR2aQGIWGC1bdlGqmiJkKvqk6iADb+FSJk/RgKFpqeVRNVaL
# DATA ia4d7/tYs0LMyb4rxVxkd82iCsWO1y9MmxCNUb0soxikOE6G7dnWahHLp/LSE84irokwmv2GseVjbZOE6b8c3/tYCVILdHr6HBXF
# DATA UYPiwh4vmYzMqh/FUcEnsQKBRbDVEaWXLcvXl0a70yIHkeHWB4fHYgf90+kXp1+dfnP289PHgP6c/vHs1wz1AT3o58zw+Yx+A13o
# DATA N4vwoIWHT78++zVwQz8//fPZZ6efn/6efvwVM4i+rHj06YvTL/foiccI2uN7vqF76B2CFloJE6LQ8ZbP6Q10owMKPfsW9Q+hX8br
# DATA xNybKFrYSUUWBHFJOlq1OzWNDsFf1nLOsvCv6qsZ3FMWbS5Qpqk3XssQemMYiKqBJRnuOEKWda26hOsmCS0rl6ujCfGGgGEyNTd+
# DATA pC4sZwoN4rybvhfPjCd4yzQhgRqzvSC+Iovo87JzhDYpsa3ThO56Al4HCHxvNu9FpuTFgx9jD+3Yk53g+967CdWAiQEhUiEeQe8d
# DATA kh5YI2AND5hlgdrsEuDzSDZ9pHAfjpnHKM46Nr4E1giR2DI8aH2VXG3ELGlnTwsdtD4JDhrkRvqLjPSaE3TJAf7lcJ1d1+B+JWP7
# DATA RkP7xUb2qx/YpVou5kC+0fX6WstVgILylEFEiwLIFuM8g8cNmzX15j8d37lJOx9yYpyILkAQYGL+nfkmWAJj2oraEspvGQcTSl1m
# DATA 0i2pNcELZmg8pS5sMtsIGwT7aoaD/MgHCmmQUm+XD/qxLPfrhS0Ew2JyDDEyBKA0kqwySOQTASpXrJE+AeYnGQi6GC+iiujdnyHZ
# DATA MXs84oFHreqB0FCOqaPAnkG0Qd5gkCLvtEPU0YMcPcjRg66QHrTZmLIh1Px8m/eajffL2O5Paro7dpBjBzl2kGMHOXaQYwc5dpBj
# DATA Bzl2kGMHOXaQYwc5dpBjBzl2kGMHOXaQYwc5dpBjBzl2kGMHOXaQYwc5dpBjBzl2kGMHPTPsoKg6qA5ql2QH+Z16v1l9jthBi+vO
# DATA G/GDDk2SeRdhkTUTNqNwUF3Fmrnzaj9OYf8L2KcmCVFgnzaLNLC8ge8rwlDh9la1cc7tFueHwvboHo9+2/O79LdK/3ab36PrI79b
# DATA pWstr+Y36Fprr93dqzVqw0b33RqARe3OsN0Y+/XmXqM5bC2LSaO2KuIKYHTzsFCBGjUfkaE3jPd8r3okiJ412RgNet3WckRSdaF6
# DATA Upybteqw1ai+i1Q3us2jRnXcqDb2GlX6VEYQdYN2r7Us6NrFaUBS5zUNSJqPRQOiZPTb9SINyG/XO42uTQOqVRudZligAdU6zXor
# DATA yGlAvUHYCENDA2rW271OlNOABoP+oNO/ahqQMkqWOz50Wku2lhqJsHFtb70V4tHNGHbye8vgHzNRWjYp0m40zHUrjf0G839qzP9Z
# DATA XI9qFSOljRurmxbbhRNCOR6ke4eYGoNnUQ2jw4q19m5/9mrd6cPKt+rVZrvVY7ffbmV1SN0LBqWjnE2j/kWpRNrmhfdwwaSyVuRW
# DATA L46rpXDxCe9l9MM4uhUG6YPV7KE8hyt21FfbHCWzV+oQ206OJORIQo4k5EhCjiTkSEKOJORIQo4k5EhCjiTkSEIvLUlIkX4+tI51
# DATA 5ee5i+e4yhge4QbJKW/KI00Xwo4ANCPQefrjfYb5vJGMWQB94ZA3H2/DUpKoVQU4qJJM1PE1LUhbPCgmbVQmcvqkhTvj7M44F47a
# DATA uKPO7qjzJY86rxQfvJoj0Pdi1rrgs7TsgiyfntVHoZ81uY3r0ONWgwuqDtVXJRmOVO70x+dJNJtnTYeVXzEizZ2l2txNW6TZ96tF
# DATA mebmGqlrHvwg6aJ6L77wqtiyRkVZ7skFrvVDrybcmdoS0i1e7vmA+j6FF+J68urNRIkELnmixdlFY4t305ul0QPWijz3sSa/yDYD
# DATA xjBoWD65+OxNSc0GQtVv6fqJKuuhyj6/KtXvRkE2h2g0Dtb2gzQXqL4/E0k+6kmSZCY3yLFmyPoEhxB7hj/qmMasfe+HPLiNoiOq
# DATA NOgA0amOVdjcjBWcJkmN8FCakDm5733ACwBiGskDrLeohP1oODlBQVNBxLOCfDVgWoVj+3KO1EvnOOONI9cBDthDw9GM59APJIuN
# DATA 6iwXfkazs3k2jUT/kBWzg8l8gIE4xVxKAgQXKYwHA1yZ91hPPcY4TYExdmeZradECCgJs40Frl+Uc75O3tqZr5b56uzVl8Jevai2
# DATA 9VOW7OF17XwBdr229V0ajdhoZAOS7dgsl6JgjkK2RuP6usV+ngu9i6uQtV6s11uXtl6q6XRZeet80V+bY2JRKNsnAlmU61wuas3m
# DATA zwmZNALU5KUget2+97roBtEsScRqomACE+UjiAiJ3EuGwY0xo0Jw5OoGM4qsrlgLP5MNl5DNQ0bdA3qDJoZcrOL8QAuxGFUn4w5/
# DATA uRRPCjnjjCFnDJX6VOfNc968Yt+50op6yoKGzAMGuDgZjURnvwzsVu0kyHIJv33vnnC62UpaJs9X0PKbpkk/CkHjFim6JP1kHokv
# DATA 50n43HdjA3U2NN4ZjaCaCTiOZ4KalpHUYy0XjsGcG/lhMD+kUfMDGoY1LbDCAYhZIss9Cu+ADiMYDOAUY1dJ7vI04/TbE4z3M+HX
# DATA zhUtIhr3ohAiaGHUS2lEFioyD6EsAogdSmtR1jL65/KMggMOqCrAD8qagso0yLR1AeU4+GtScZYq8WmyAcJR1AvSfe8d2E+IJlVS
# DATA ytxAgcDCAB0MkAi9kQivDVkYb5mQIX/MLNVCcclmoF5/QgUfD6DzNo6w9hf318LIh6xqzZVnMoMHh73IJskfAcqRDAbeIQ1ZOomy
# DATA T9IbzSlT+wEUG7keA68eHAcn4pjS8VRlmGm3DmcfjwMUjIo55UsmCtzwL7EK94GSNYQUZsonC1TFNdW5ANaYof4wb8TrUQSilV5n
# DATA lWoeaWRsgUw488FzoWoITpmWRWZMQomPQSZh+ad4RD9XtB+KE5DDdvpBmp6wcuNdyrOA/XYqICHMCzxOc3yOApbkyzPpvSjmVImf
# DATA WKlfwiV3mCSh5W6XtybU0Gg0HEhbKxbh5WDfaMsnrPpIfcxrF4Z9I27bhn2LXR5LA1f6hfEE4PgovALo9+tg3iu5ULV15AoY3x+V
# DATA VEiv5E0M934HTUP6GBrXZFtOJsSc7b6NTwF9ZCiJWCGaBnHqPYC3OFhM3VUSxV+MqY4Fl0mCNDyEb93Gy/wPhZH5hqEuoMN84Z0+
# DATA Pv3D2Wdnv17kyfwL3ffH098J8oXvYvILqDDfnP6JPn7OLJnHFc/wZR6ffnX6OXA1j/HTnn7qsUdfP9dB0W30wl+c/VLBZSgeZ3/n
# DATA MWPmd2DTgELjoDLPAaZxopldC764aZQAAa1G7pkITL+h52vi9zjkbdsY5BQ0jLV7WV44J3eZgY+ip4fC+SRcS5m5y7fkb3aMmcJs
# DATA zvQM102ZWSyXq2PMcALNXd+FkDjl9WhQvi+E9rMBemG/7ywNTraJlqE2kJGNnYqAOc00YI3xTAwF4eAy64tq61QZ0wmFMZnxfGJP
# DATA TB0yX/EURO7jhx7XC+8D3h4gbttD7I9ctqlc2IfQaNdK3yizSTRjTXPs/aAxPFtgyKyreavtlIU29LT4Meui7+gxbkh/oiFd42Qu
# DATA NZK/HD7Z6xvFr2AQ32gM33AIv+oRXOpiOdn5tsmn2GKuAilTTmhOljGaE3nMKTejQCFm4H5juQF4uiZUpJms1iIZhp8hwyrQE0dx
# DATA yrgYFJbGylDKgwwXcWTcEIWxGioD6wUgMiewtti3KyEeyjYzTBPoY28kHrfDNOLzAJLtequb8q3T6A8pBP5+Lo/kAOM/Z0lq2QxF
# DATA zEiUOliMg8U4WMwVwmLOGTM2Q8Kfa9leq3l+KU71Exnnjg/j+DCOD+P4MI4P4/gwjg/j+DCOD+P4MI4P4/gwjg/j+DCOD+P4MI4P
# DATA 4/gwjg/j+DCOD+P4MI4P4/gwjg/j+DCOD+P4MM8MH6bVbvQa1UvyYQaDQS0cPEd8mPKa80Z0GDtb6lXPb7aH9Xb9qNZtfI++F3Ok
# DATA 1263G+FidjZrnt+pUoa2j2qN1vfoe/E5qpudnuKycFlKWUnBnQiHpVbQlWh0i2XcaJQi0ou67XKAtVr9sgGG1W6t3VoIsFPbbgzr
# DATA DX+7MWxI1dleDO1CobLcQh5ahXLBAFeUslUoW4mhXShbiaFdKFuJoV0odQl8ey3lggGe31K2EkO7ULYSQ7tQthLDQqE0G9ttKRcM
# DATA 8PyWspUYFgplGzEsFMo2YtisWW25Wyxlv14KUV1IVe6XB/9WVC+huFrdRtBYCktbBh1rNusWdEzCTw0SzDJSdKgL/LRa88kCaHa6
# DATA VgDN7sUDKCSh23rCJGwWwEV4ZmKjaZ6ZmHsWzyxotBr1qMgzG/D/bJ4Zfe1GgwLPLOqEQS/MeWbtXqvVbBmeWdjq+0En55l1+o2g
# DATA duU8M+X1UBsazExInPFkS7KDwvJe6EVqMz/r8ErlkkX/Yshljtl3IzJi46AiMSntRVkSnO2I5EWeYuhq3ff8aJjpy/Jdcvp2mhwf
# DATA RpstFTU3WZy2Qi2vOts+E11Him7nmkzkF1YP/bq1SKzu9WtFL4yurrzHchiEyTEvxGDFrerpOmflbZcdFjwrNrO5Ffvp9CRW5XZ1
# DATA NQPNztNzPBpWbpXqJE+Waw6E5kBoDoTmQGgOhOZAaA6E5kBoDoTmQGgOhOZAaC83CO2Rqt0xFdxthTLDZ0p0hZOkLuLoHjJCbhfV
# DATA zdvUsVGd2UHVim9XD+JX+YmD+MaN3Ue4yLcdxIOd43hC1hXZYSfTWfIajPgPAMUY/4jD2X2kW9D0NoPWGASy06h1G91Wu9Zt3eQo
# DATA 7X6H/6go9G7DBvwhzd7rNel4/d2DMHkk7yi/Yqe3e/Apy2bu9H5c/cmd2/Su3QORfMOFb3PQN/yDTyMy1pUWnBUX4b9xgDsqHrt0
# DATA t1Ifnc5p1FPd3qcSPVSO2+rnnybxZId7K8pB8OHQGG6oH2WBdmcnqPSoOIIbvQpZj7klr1I7im+vtGZHMQpmFNsV8rY0Dyo3epOk
# DATA jWaOeC3b+DIjwAFytPspthJMwp1RvHsgeVT8nVelaeKuuuI7fnW3eAOGYBWfN3Dvvpyepsr2qUbWmaOfTlnFKassKquYw8BOXcWp
# DATA q1xQXWWlKPYVqK58ADkurQAySljvgzW7jPDK0xXyug46HZsCdFU8QV4y4MScg6VTD+U9kvpeUJNdINL5FpCuZePo/DUwOjZfUPXx
# DATA AfMPFEUJRqfuyWF0+qEFRlxLgnooJtJqlhyPSW/Bu37enb6oAZMFet6NrLD74XE0ok70nHtrVXXvhEzg0r2bo+u4eqOVc4k+t9S6
# DATA 72tGg4xHGVkPUWik9oy8DhlZRhZHzPey1A6T5DaT7WERGy9L5ilYvgPBqUB/W6xGaDjkfDrxWpCROFEyPpTEE08dujdiMfTOBbWY
# DATA Yf2Orf9DaapTwYx0obBFZuemtVFXlcBoI9rci6AYko8lzuh0Ruei0ZlbF87qdFZndq49+dS0/u4zaogjyS5uIEdR/Y3RaYBk47if
# DATA JpYE3pwtVKV/F1DrmvRBt1jUvjODYt6i1GCoISUsJddPxuMo7cd6DGTLNY2w0oKNCxtr/3HKpnfui7eqdwKfWYRdJhhGDUBJ2L80
# DATA mGIvxRL9LXXebdFEVe5Z1ET+pIxTZXPoH3MDyFzhg89Ap0UcjoqfLDeI4KCO/FLb0/h8wQlSn4uWp3WH6SjtpxYMOzhN0RbAmpL7
# DATA 4nV2oDbO32QDbtVd/QTEDWouR3zzG/nX1c9wJcLd7+PDGutSBmZt4YkL1TZJMEisMe8KJYw9H9Kg1dHOHOlAnZJhd7DHWlZ3VF7a
# DATA eVHCAfFuGNPOxRnMtSmd8+21//zs/2yZVJSjrXJWmWJKqpIqSDo7EWOM7DsemcDk0ZYkD0I07duD3RXyfNG7G4aQxqOnhQXUR2Oj
# DATA 2s8TReYng72CB9n8k9GRiSiamAzblN6y770eTHIq4CSUSan8dA9EGLykXqVB1lCC9LGTS+VrqfZcInsbq7O3UBcll2Eviw1PCZkF
# DATA I53Pd5knQ4PEtCK5pifWnGsBNgHM4nFkQ9mmoznPnml+OReLnglIyqPv3Y3HyKsBWWvZELAqNr1xya/h6zTJ2ETf994CfBGvCeOs
# DATA P89QQBySLEpuI5dNe7to/q7OW9Vyda6ix6eud4YPOk/fxN6ewKv/x2/rYCWFlCdYPJiAZ34MfBDVrTnlHZWFTPEzz6cC7cJpIesv
# DATA /YjmIPve+9Rl09T7rlRsqb4gQDEnic8renBvHHiv23fgDKG4S3gmrTZ57Xvfo68RV2Qq/61V5Etn8foeopDNH9FAS5MMCiLVeWzM
# DATA 2QE1/D3Rc8pZYNAOpPqFyjSVPJQVn0z6ArkblRR+mkChxzEhlAffg3YpTgZmrFsamECCiYZSVeRl9BuWUCRunOmHsUiegkd2FCfU
# DATA QtTDgfQ8z0bn0bpQ5/Ff5zGvfOrBWxeCZDDVXxrjULG5ArINpA0jmQ4h271sFE8pP7lxcN8C0BlPb3qsb6o9glBQxaguSqzcNXmH
# DATA 0UyKjrMQC4lZMo5w4XAecceBp+OJTFSoX5ptpfu4+sHvDR6XwESKTdU23aK4NWbHiXTIkrXojTNBaIpQchSnNLodIxRdj1nGNjYK
# DATA vzRdR9NPVcsnW5BVnfFO6ppwWpF66yM1uaOw8cQ4wUIuzx3QUzB2QroX2KzlzC2aK7JsbJsr5opk1h1qYGqBVwsJy/gtpqJlvlJz
# DATA G3LDk0LZP4/19CK4XPLZlnO5OJfLEoKC87K8+F6WlQ6UZ4qoUDgqsDhSjmzWgjeKZzjizEoojMQExVKNJuyCyR/k8yScsU8bwfAs
# DATA a5Wfx0+yDn7IqiQffbnzKnWk5famj74Xjtd15CyfdS5fLgQj6Q7LOImFI+nSfvsJaoe87WTS11FRKo+5380Ws+fyWALmsJ7jL5we
# DATA tRIzrN25zza5qSKAIAeTE7Nq9b3kGDjkE1V3XvP4whzeKbKqXvPeoPsj6kxhDMEIyS3h1zAJi8dc4SbZscweZtho5/HSMevvx4ro
# DATA qtlUgNEGZJuBjwvtMjK8esnDaIEXVawt92IGZrIDkrJj3p9RIqXYX4YlJ5tzmTCP26Zc/jNjKf8VyMmz33ggUp7+/vTL088XCZel
# DATA O/+cAy9xf8U7+zlde0z//eb0S+/sV2e/OP0CT+Dex7j9K0Fg0u3fnP7+7B8Ar/Tow2d025/kVsexfA5MNi9jv3+qDiCavh6J5sk5
# DATA 9wT7nuyW97K5TFhlQz5za+VBbsAYM3gwYY/ARKZRA0xYucHBT4alhSFvnl9DsXxdZMAEleEQlkUTThr9dQMsS0VydfRK2AFHVnev
# DATA Kh5T0OWn8hOqCponPlBVElVwAo/YVoGWvFtiGGTsrwH6RznKlQXjoJabluDW8ZZ3YZceiq1i2NEV7jZDONg0IMj0WWJovxkPBnEf
# DATA G/KxbVl23ESaAa5vnUQUBv2cirt/gWi5UR1cbZYUW9fT4lpulAgHuHRj/ROM9RpvefEh/iXx0FzT8L7t0X2jwf3CY/u1De1SLQvZ
# DATA kGMun1q7uQrIZSGNmJIHxYRhW6kkAMGOpzMZCqcpuh5w6oZBL+aFv1mmS42eODzEAssDqgaZzOOpHqtlbky3ZWQ2I/AopgqJ5S8h
# DATA /GVQ/Es3RVwiGw0TENMGiv+IunqcYcMaiEI76tjzttcFrKSqSXsFY0EWhDiWLJGCUJCHyACsfGZ70yjdY6uOSmA+5l72wDITcCOi
# DATA vEcG20qzwTEwHQPTMTCvhIG58QCz0UzmAvbw9Zn2l7Hst2TYOzimg2M6OKaDYzo4poNjOjimg2M6OKaDYzo4poNjOjimg2M6OKaD
# DATA Yzo4poNjOjimg2M6OKaDYzo4poNjOjimg2M6OKaDYz4zcMxaqx4xc+uScMxu1H2O4JiFleeNyJgW6s1v5pTFepEq1i5leF1+lxwv
# DATA IssanVa1vSTDgd1s1YaNxniv0fD8zlBQZxZ4rEwjy8Fj9QXoW9WKawmpthDXamtVXHu9VqcZLMS1VqO4dlrbimvXimu7szauCma3
# DATA NK6NXod/Lca17le9GtXf7cS13tlKHWj3O63AX4hro7rNOtBob6UOhO0gbC3W10Z3m3Wg2dpKHWi3Or12byGuzc6T1wErOAqt0WoP
# DATA W/Xqkd/6XqeEx6UOtd+8HMSO+lINsZNu2YLYNVrUbXQ2gNiFg2YRYteIGmE1h9g1261mu2kgdv1OP+r1c4hdvdvstGtXDrHDHqo9
# DATA Wd3Qo2vD4tdZtLoO25z5/Rfj0pWdrvV8qbUlTlcOmc+pbOZLba3zpeo5YR7o4qqM8jXraQYmCmrK1W0u0OHgU8OCk/ynzr8bLlw8
# DATA oTrldYQMJ5WhUaTTqVqzjLJ3OWKcrBioRdylRWBce2V/wUrYnFUCa2zTxRrj+HKOL+f4co4v5/hyji/n+HKOL+f4co4v5/hyji/n
# DATA +HKGL8fqjQolxz5PSvR35Csf3qOvN/WvAppjY/PjV95Sx/9CcxISh/WYZMZMtn4Uj3Y4dCariX5mtv8x/W9yd4bbJFj1gwKwqW8M
# DATA h9HhhjTh9vgEz5LAb5ZD4WCsRzMeEQzuzOkguoP2qw/auwP2L/AB+4uqHz4zB+9zx9Z6NUQWeePTrBMaociygMDykL6v00J8uuf0
# DATA n7MTq+ep7+SOyqvQRiypEGxZGLGs43COKuJdBehhMQTKVWpDGQdmpIXen8MbwzsYvMM5oGC9iNlggaX6Dd0DmqxjnPbu0dUEIvda
# DATA /VBkohjRoNQVqN4mWsBZTpRzVVfiDch+PlOOc+g9qRB4GnUuejiVaYVSmS6rHq5VUio1OXivbfgFq27fT2ikG6rT6rL5VYtvvxdA
# DATA btHI9KfRcZDiQL0SFD0ORnI0P1AV1BshIcxJYAd6HKQiTCGRL56HngUskvqD+QxJMoegyxrli3HUuWyoDRMpCabYcAeBTRgevoRR
# DATA YKTUg4xVGpSwVsB4Gj6tHs/WRO9tUG8uEDn0IiZilpCGrkgQwMyo8INUAQySUaZ4jIamw8GkD7xj9EIcX5y2XxPJ9+U1SzLxJTqx
# DATA bofibGRnI5dt5FKtcrJUTpbqMtbxSmv8yuSqvhtzG2AjIVBCT1rBhnLsgaVddc2aiNcBBxbnDkNwYD2mEXIOKpXr8cD6MdM7mQs5
# DATA 4bZRPQ8RXK+KIbsBJVi8TkD2GgcTX2KXEF5+ToT18ybC5kIe4ebyCEscVZT9cpSrq+PMrjG76qJq7fCLb4pnavfcbC5SmPX3PM61
# DATA pXFuXjbK2mFGN7y73Od2TozzAEykrUtWXi+NthVrVX10pJuFOK8EIr8+j0ehNaKht3h+ucjvyjAso3sw5aM3vICt51IGnMy9F58S
# DATA UepQkvwhPRSBx3XXG0TH7NJmx/HMeFShg7VESP4wZaE6M/5PoiPNvDISYD9U/bruCgFcC4BFx/5ZNsj3vb8mSyHkeQ/1jFY3S2Z/
# DATA iJ1BorqmGZniypaOlBsLpUjezKYHpnQ0zRAOXDxbNWV7gY1we3R1Rrgzwhcc1QvWlrPDnR2+zqx+dmRj1WCnmwH7wNAWbBV44HZo
# DATA rDKt8Cgf6pREaSVXMeWhxgicQq8Te6sw6iDwqUh2YnhVTkS0uYEAUbJ5LJgZOQyySnP10vTk/KXcsCGB30Ol0LMIGp1Dx0/ehJ88
# DATA YR8qnhBv6uo7xZ0sUwh8WkNO1m5Fy/kHiu2zT1DOc+OCGMkPVyMkdb4KRPJuwXMPlzZVGUBp0wjFVAKmptEh5Zjxz7IfVpBY9J8B
# DATA 5s5KfZZqZMY30m2TWUwTZlmB4LnyvvdGkKYnEGVNJkX3eBows5Gt1ll6orzELMqKPZCpRAw+82Si/eRq8mA30nz1RzeRfHXJ7IGU
# DATA UX5N8k3+ahVFusCbfblhBmCcmpnIE7FC86p8wWJ+a3Ux60ahitk4/fMlGdlrwT2GLuh30MXCyAmEyZqSxa5XOTILWS9aAKIUzUsv
# DATA Eng2So5HJyIJnbKyMTpXjEVmqYfKnDfwoYMcml7xiYpwfdKurRALvcwFy/GDNTDjvL/SLVbQI0oiOY3AYqUhZxIqMXAuSU0Cy9tp
# DATA GAc0CxyzgTqIZic0ns6Rx7FyXgW6JSvcmJnM86ILja45Hy0zSzg0+D7EjJR9buwBwwJhLMC1J26b6xJ6beV66T74/sZ9MFXYGd0i
# DATA dN3ImzB7O3twstD/araNFCusGhGaZiNjGI3jbMra19473GMG7CUYBekhZKWhzDjJNKf+OEmlf5W2Ip3rIAAiGW6BrbTL5al69rvV
# DATA 723craqxi+wryOsjqYEaqMJAE6xNk5R1b3SXiTYWxQ6Ft4VPx0EcB0Wp+Nbx4QSuHpmIagsTjhWWBofRmU5T1qunXleKmeOxjba3
# DATA QcKei671zQt1rVrWHYZJmAbHaCC8O2EUD6yFauVc03co6yEKsC2UMgey92Lv2PYMZjRcWNrk6c9n+x67/Mxattoe0E+DKfKcj4Tq
# DATA /RTaQ/Zk5bo2hZcq0esFeD+Rh/bF9ynmCMx+RKN93M+KCMwvzj47/fz0T6ePz35Fn38OniWwlX+iPz8Hx/LsM31xGRbzm9Ov6P9f
# DATA nH559veMuzz7W4Zi/kmQmBz07+nKr5if+SWTM72zX579HQCaZ79kOiaFffrV2T9SEL+kv7+hd1IIuOnn9MMf6We65w/0ksenX5/9
# DATA 2mEynwtHKbalobtS3aKqeRx0dkt8UTyE9Wh6UOHvh9jsDi9qH8g6BWo5CthzFZgpgvG5Bh68cP3hvvfWw+kI5gt1pigsxFoZNLk6
# DATA 8Fp+5hsjGr+kJSJ+jqBp+1B1n3HdBM2FQrk6hiZXSnMXthbymrryAC4QN6lqx4m5/T5/9SDaNR9BJGybAM04k6jAeyg7GyOc+Q3A
# DATA DzqJZo6euUnZXQE5k1dJebU8HmOqi9BMBVDd0yziI2p91GM+1u+9GwXZXC3fUo7NAYViugJKjvpK43vOmDPkzeJRpFzWKfvLyUAK
# DATA 56NFnOZmVXK1pVNua0+LqLlZOhxS09kFV2EXaNbmZcyBl2I59dpMge1bAhsZAheyA67PDJB6WcoFG7f5rLWpq+BwlpLPiYabmtmF
# DATA JjJl+KZWKM4z5whOjJHicdoHaTi3eOnZKP/lAD79NmSG+HI0vjJ7EM368HtviuPMR3zLYqDIZfnwPxY7IcS+PKhGQaGG4utJiHyy
# DATA pmAP8MI3xS0J95QfH+08y3gfmcd7uMQW0U5FGpWQXPFHKVonb5Rgt1VgltEcetOhNx1680rQmxuNNRtNgS5iNF/nFOAyM4BtTQAc
# DATA etOhNx1606E3HXrToTcdetOhNx1606E3HXrToTcdetOhNx1606E3HXrToTcdetOhNx1606E3HXrToTcdetOhNx1606E3nxn0Zr3Z
# DATA CFu1y6I3W4P2oPMcoTdLi88bwTcp9JiGRa8vMmNdzsv+idANu3nG1hqiQ8W/1FpFfmE3HESdxVwGE7BWH/q15id7Ha/pezXf86td
# DATA /lNv7nUaHtnHe936XnOv3d3zay2v1t1r1zy/TV/qxcJodTrNbiTvKMa51qjlcab35XFu1fIoC1nUqhjNeitaRFm2u57fbA87ndGe
# DATA X6XotT/pUmRb9b0a/dDq7Pl+Z6+912zu+Y1uqbb4UT/yS8zDXisYBLVlzMPGsqQ0JPZ9FeO2BWFsWEkp1vGw0+/3lhAZ/Y5Xr3U+
# DATA 6bT2GpSSeterUpo6nl+rfrJHZVFvUAp9r4RWDKJ2o7U0bs1OO48bBWxlc9eqGdUiLdJv9ButS5AauelpUqO0YovUSHHpdzchNRau
# DATA gNRYizpRaJEag1bYDnNSYzushYFFavSb/U79ykmN2Nu+t86koQHX8nGJbWwe0paMDSVEKgd+aUbc6Hzbw79kanhsbuRB6PHWWmKU
# DATA X9mc3NDrX7Pit3QuwSFCUNj2+VdxN89BtGl6YBngBVeoKveLgRXF/ZVDIUt50qQ8oX/r8m9htarRNNjIdvPbSwmPYixSmmXOly+X
# DATA WgtYyxGOK1GN51YGbU8urwWSKTW7+DYOp1Q0PIstTYYcB9JxIB0H0nEgHQfScSAdB9JxIB0H0nEgHQfScSAdB3IQoHHf9veEpyib
# DATA jgF/JGtGIx/v6/Pux5HyZzLucUfhInEBT0hQqKr3sNFvx2ckY38s7MdCIGquaoUiV84PRkRkIZ6sjtPLUXtvGkf9SJ9GxBk5+A97
# DATA KI8iBzI/eeNOh7vT4RufDi8f0XIHxd1B8fW628/MAfL78UNpQhUanyYnWPKP5ZClDb4xRx4t0VQ0mZEc6sSzDxZPPeMoKPe86uz0
# DATA AKHIycwsGEUXlM82qpbieuQmTjcnY7hG7XPeTjl7E+Vs3lHCVREfVt+H/hK3/Yj+rtHMpkFxJvjD9+Xj86CXbfLggiKRr68WiVS5
# DATA KQKRr+MU5wDHujEo5XqQ2CzjkeVOVQXnwXE6H1xWmvKcQMBzFA/kBHMyYwpExkMTXFAIxhtEVI9GMIhowpLIwWNOiSaiPIl25mWz
# DATA 5I0Ns+QtrQlKY7LOkNeDEXQFWKuXo0uNiS+YM9eyhMOyot4A3mV6GjnFCyQ8rwNzjoZm/KEmSNZfLCfzEdhkGxmj28EF8+VHq/NF
# DATA WpSqKfOQLZO8jkyClOak3oTmtB76GQaDQroVCxKQGcjhP7BouEpFEyGUQZAgY44IfZ6ivz860cbNU6wj/2XDOvJ+MmcNi5/OD/P8
# DATA 0GrTU60+nYwH2DQCTAN1AlNMr9AgmGakMEYhmRo0mPUp40bDZI4Tb/veh5gQsLYCKyWIXXc4Cn5mhDqeUH027wovmD/vr9Ge1Z2q
# DATA 5BDNr72pviQ59H6aHKEOUJppdnMYGXQsb5KjShPM+1DhuDvx5hMkV/cwEAhmICqwTCMo70MqmheXn2K7+WDDdsOVWim3WMhaVmQY
# DATA J3Ooj8+hVDES4yHlM7Lw94OKFYa6Z4HScixdKZtlthBvINWF+utyflyvlO3LotCQm9luEu4m4RtPwt2M+wWfca+cTD/Tkm28j8Xs
# DATA aBEqK+9qufMqNehyCev9l0iu2VbXka2U1uZQuRCM+FtZ/mxhX6RUmH6CnUPyspNJX8dEnTS+84OFbZV6kr+oLmc9xl84NYXxfVQg
# DATA ewE+wawXVhwLqXrSBF77F/KH+Og0DzfPqG7d8yTntKGwrWe2VEn1LRgOZgPVGkPtP3/7T9qM4FcOayJlJxakN4tGI566KNCEKHp9
# DATA F/Zn5h2KlRXMmBYRQoWNZizD+biniyvw0uHJbDhW1iwbrDw3OIzlZ7H8WIwM02aImlmaXx7veYRIl5JGrlBupVEuOGfUAPUKtGCG
# DATA cnTFcZAuaOoWC5ShRsZwZGLVSyirZQXjrDZntW1stS3UN7d24tZOLmGxrTQOr1J8lwFNA6Wjz2LuyGteiC9o8D59Qfh1hgDO+Xn2
# DATA WsvC0onYimxbhoVrhTUNWeqny/eo/+Wz33zF2+mPzwPd60dNd2YumBUGOSBSRsb7RdC9jYyv7vur11/UhgI7snJpk9iah0108ysm
# DATA vt1tRldtvKDf39X6v7NkVqgSO98+L9omEBPt/Mo52Vy14l1fG21lvpoFM9mVyqtcUuUj3uJhmkJmIaJQw+68KmeCVZzV9mTbqZZf
# DATA kv4nFlTVlMZuZcTelCCeEP4kthWjtPIuwFal/mFm9peg8Rnj9l1xphqlZkYOHw/jUZT3EzHUamfYq5Oy5K1Z6aDWHOXizSwPrFY4
# DATA YeLKxhXZ+kambqkK6J1WXqhQfaY30NrB6FKtvodSNR/T/dgenIfDetL9YALt4CklIMY5xSCd8kIve46BIoe78ngYiQGfd1xIGYSm
# DATA uV/jhS0yOvY9BbNDCo3QdDafUtej9IOL4tI3Od9fFuvZgnDxHJ3nEDaH67fM4Pri7BfCuwI565vTPyg0F+BcYHF9vkjg+he67TEA
# DATA XYLWOv03Kxz6xICtr+geDdn6+uzXp/9uKF2nn9ONj/ldvz/7ByZ04aSDd/q70y9O/40qTTBywK3nwv5n497augFUYJoA7zpGP8H1
# DATA zdgxTGrNIE9OXRKr91HPOBHV72PWDZelCy27XVHc0EM09mHQQz8ls3VRw+Y6A7HzXoQZwjrY1kd0l4mQQ20VTP+8Z7hu2lapVK6O
# DATA tSW0b8N/4i3Z1lutO3+aUXHrG4sVbJuIrUDAVhquoBYIJTEOr3VOcW0drfV+QEYnfqZYN6uVarXKowZlAHVR+977NIAYq4cJFjzp
# DATA GgZTrAXrnf+zoHeASAqOOjMQChRX9JAGApwtKDO0zq1uq82UYuN5WvCscxPguFlueN/28K6ZWRcf1V8OZ941jujbHtA3Gs83Hs6v
# DATA ZTSX2lhIuu2je5ba0FUwsgoJZ8RPppjtdjJp0h1katEsxKJZD5Z5gJ3EFUpoDKQPNZqYkjCKwZKahPq1gyAewV/ZD8AqYrZQMVkY
# DATA bQOT0WMa4PQCczzJpkgSXKTUQjalZeUhs2ZAJu+j+DOlibeiD6nOwb1CF/lMOZ82Z//GBCt8PIedMyFqGogDNgkZmSVmQWbOilOK
# DATA 7p+Q8fYQnrI4DNRJ9kgMwyjDPsQ4G2IdM4BXoy/cFaQrHmADYn8YjQOPd74zhWvKY5FDaTmUlkNpXSFK69wxaKOpzobm8/XNAi4z
# DATA CdjCHMChsxw6y6GzHDrLobMcOsuhsxw6y6GzHDrLobMcOsuhsxw6y6GzHDrLobMcOsuhsxw6y6GzHDrLobMcOsuhsxw6y6GzHDrr
# DATA mUFn1RqNavPS6KzGoD1oP0forMKq80bgLM5YjkuXM07QTFW/IEfR8jvFDK93u6tzvFrvNhZBTt0aI6lUUBZcql3tdLu9ZXCpugTS
# DATA j1OWoFIva1lsqTrHkw/MdYo0qbBbb7eWPd9sbvR8t9dt9ZY932ls8nwn6rUDv5wJ41qj7tVqrT2q2M0uV+/auO439/ya7/G1Pbm2
# DATA 5/v1Pb/R3mu3Pb/j20HzhtESnqsTdsLushxkXFip5re7XqPuU4XHq73qsFstBWfybiG47iUQWNyENAJLWqOFwKq3Wr127TIIrGrU
# DATA jQILgVWjgNo5AqsWVsNGjsCqdVp+q3v1CCyaCe3R7xtN2ms1GiuLfqvCSCMjng7R4wNyhvukbThlfOoE6wBS7VpZFog3Hz0quUys
# DATA MWDh7qBk9htTvKNM8fwBPWqX54HL5nzaS9hhL6GsDsJPuGSxrVVMRHEhQOaInj3xUYZc/oQZBpes2JUxXEs9PrqiFj0Mq6Bdxnms
# DATA ogO/sTX94u/n5FPxRS0kh/2Kha0nq5834/Q5r1kxhVuN9TIVfCMc17rKu3paX6rMy+rkfHTu5JKj4DhfjvPlOF+O8+U4X47z5Thf
# DATA jvPlOF+O8+U4X47z9ZJxvlAX1An5KDywqV8zLJlyRiB1t6WuJ/O0H6GCcK06iAdsZKqGeadZhcEzGwJW8FaaJojjm8ryQvMik4f6
# DATA 6PRQ+mTz2tslY9qaE7AJW8HkoiL0L2xr5HLYFeaYCYS+U1fx8Sts14h57t3Lj/6THX2SLekLdg8+ZRv9UR4bbLUcxBPKDkU1YxlR
# DATA pftwZAX/Bjofaq5wqVZwjnEcyBkqLnW8tYc9yjS/5BdZ8VOCutTV4CTUe4mxT71jnFlU1if9xhGkas25j1M7e/pH+uW1dXYHlyGV
# DATA T56u23nKdh8VIiNiVCYOWqRRvQmnAREPsfoPPjXG/MevmMD3ETd6q7lwg/oqUNjoGrX2/BjkTblR5wafPSqnVyXXVLa17YXTuazw
# DATA NguGJnN4PQXE9rLk2Y7Y0P1ZOqIp39/8jXzFZkD6uvtXfyXf6VHK049feYsRD6/sPlpheSujm7rCbHafLfYdKVQnce/UFC6lpuBU
# DATA FF5sFYWLqts/VXUF44CVFIlYn6XkPgtQ3e68p2W4OaV8kHUOact4dULe1Gf3c+UBiSUeWvfgfW63vM0Li0IrnypkhxgLVtvLn7qJ
# DATA mGodQj4au1Lg3pCYlBQCter14vbPnNjEc3C4mv+7ZXJCURRj29yEstbIUmrCRVWyPkpjZbrFE2Y1ku0GY8aoZBkdEFYuy2ABH0PI
# DATA bDwXDYcT9lNXjIC+VEZVebiiYJTMRNHe0vSAxkHAFn0ymDFcKY3Yjc4ELgXcYkPf44VB1hufRA/Zx6uUNc7lGL0Y5+RNCM64c8bd
# DATA RsZdSSnHaWY5zawLWHUrTcer0tJ6WwSbqGKrubxyInA1z8k+163YeB0i98qzoDNXJ/1VvRNDK47r26CaLp4yXGZnWUFgnTJyNGKP
# DATA NgMQsFbMo9tfwcV0gD5NPt1SF5RFLd8q8ofd4uq2H/uVWqX+ExoUdYxWSMorpxq9623+xFW2iCA2t5i+NX9ogQBcY2TDceLxVpI1
# DATA 4OGGGN7gHpbuXAAFrxSTNz6svOo8vzrymPKIvJSykZZJnM2NwNlUWk1FSZj9l+AouC9drFIzA2FFu0HRTFQ+sN7b8aSohSaqWQEg
# DATA LbZLTulj0YAJ0TNBJI1OlCPUNHcoXIkAFz19jNNdPHSy5pTl/tv3THFhRCQbed6fzRWFaRSPcZE3GkGwCiJxTLuAdlemo1KqCPlU
# DATA xDaT86mFlFbRdYq5pV7hN65DNeczNed82fkXw0LNhxlnojoTdSMT1bZFnIHqDNS1hufTFnt9r9BIJhjoZvE4hzLdl2VSFkCtWBRA
# DATA SZ33lpZBhMAiju9wdtHvaCphwmM1dDlZLTQ4pHhhy9nkxOhBbqjgytE1sRESFNUCCDqKQUCNldp9xPqW6DyWeOvUieMllqrsUUAF
# DATA 40+KDqQsGf1jblyZKyw9AeR8xOGo2MmeG9MtrWYVmY0PDP2Rz0W70rrDdIn2UwsmI3YOYHRExyj3xessTLRI7UtefZelYysYR/N1
# DATA TchRFh9y2t/kT2ts1yIbXHYS2AaLopmvMhsLZYzd1dJYLwFg17lxQQD7o09XE9glY4XAjklcpBnpyml/oknsH2LLKKU8nWey3Ytr
# DATA 4IS1U5WQLuZAIHPqFegYmzACbKDwenMydJViatzf996MWWB1zkK73jjOePYoe12wXYkporwJRK5xa+WVYSExAEFEr0sVn+2J0fal
# DATA GnTBDP7Pv/9qdQ4XaqNkNEu6ppEI/8KvGvfjmUHe8y85fYm1b8moFi3VZKpP3c+otqWs44vDq7NY7PO7Az4UTnODcS8+nIP7qFy/
# DATA Fd3dCSpK6I8BGfss4RuH/JtM2LeRo5esq+Nss7r6XjCWqgAp6zzrpLZgigMFW9nnK6q20KkeRTMgsWR3k3naY4wHei8GfZwALSu0
# DATA rgmUAdEgyPqj6FDvSUWhNiiYBvL0q99/vVDlE9YZx55S8ck8mkc6/97BDA6TNppA50rMx0HMzhy+oI6bRwBAvykNktckpOJkeUXl
# DATA gJH1Axwt4PykDJzAhcQBzeQpYHojUBRpqEShbaXqma79ghn59pq6pwYJycPyCqU3S4MjGjePKQ06Mz9QRwmGSiA7kGqZkg0ThZky
# DATA CqiXm8wYHIewYJfI/IQa8sT0DKpXHVOvkfFcMobEo7WsmsPlZrGSc49o/qtVuGH7PdV8/XDTfP2QCXzWchXON+atWy2HpdEh9oPL
# DATA ARFKSKaGDIw2uXq9kTzP2FeRW4bRYMA5bPcDQS9j8WqaobF7R+5R1Rm9qVh9MTrbn8pu1lKGFo0E2bNoGwnmimQP2bV6d6Ge2LGz
# DATA Re36o46oP0ygnxXAX0olqQvipVh4szF6VBKRTdD759Nvzv729IvTfz/9+uw34N6d/RxIPPrvN6e/O/u1oPF+f/r52Wenj/H39OvT
# DATA x2e/WSTq2eEwK+/nTOPDs9+c/QpPnX5JF5m3J+g9+vsnj2754uzv6bk/n/0COD3EoJdGx3sGvffl2S/p72/wMxP3/uTQes+Dt0Zq
# DATA ms2blynngxitdCLbgkFs+KHxzYjyPcwxshhCKP2wpSDrG/j9gd5Okkb9eKpsrmyO/ohb+zhhsf61JL03JF5WA3IwPdtLg9y5bo7e
# DATA YplcHUpPqk6+kviBVCWRPCnfjJ7IWnOMjq+Els07qqfq0AVlhUwY8bZxNJk7nt4GZbZ1pJ6Y9dyXc9cDL7P4zXpkQOjeTex57sY+
# DATA zLslqq7JsYL6aMI566wJ+pcPHaDQ4vEYZ3QAE6LCNjDiC9W/NRjgcqN6Woi98xPhGHtunH/CcV4j9S41vL8kCzDXMrRfwci+0cB+
# DATA kXH9eoZ1qZLlHLDQek+z6VwFSa+cVL0oIi7VgOUmSyNiZg+JiP/CmFgRKJYszsoaqyhZHEWzZMrPRBkfaE/IXJoNkzDbBJP3AfJQ
# DATA lrHKMaLshYeAN+5S8scxNpgkZJVhz5YM9Hl1oXcG2TwFGCxggVHKZPbnV7TbPo3QfjhFJ1wyooMjJEA4VphUpytDFowE99WHs1rz
# DATA zBwNz9HwHA3vCml4m4weG81VNjV2r9Vuv4zZvg2r3VHxHBXPUfEcFc9R8RwVz1HxHBXPUfEcFc9R8RwVz1HxHBXPUfEcFc9R8RwV
# DATA z1HxHBXPUfEcFc9R8RwVz1HxHBXPUfEcFe+ZoeI1W7VevX1ZKt5g0I3C54iKV1553giMV6C+1bsWNa5erRvqm99uF7lxg36nq/KG
# DATA IhjTyGqCqOdBNBrVvGxqQtuTw1O1biG8dqPWr/cXCqrW9L1arTastatHfqPxyV7L6/p7fr3pdWv0p7rXwZe9bm1JyS2i+Zo1Cq1Z
# DATA HTZan7TbXtvfa1A98BvnUOdMYAuYuFp7aQZ0LHIfRd6qnPVmngH1wnu/1ejXWvXqQpTrrarnN/1P9iitDaote21/3GxQ3D/Zq3X1
# DATA lUsnwK9dAnTHrUKD7qSBWaC7dqNebzQ2AN2Fg1YRdBeE3X4jB921W81uq2lAd2G7X+1ZoLu2X/cb7WsA3aFJ7a23NzweXqxby3y4
# DATA 70bUC8RBRQIuLeYtoOLqvGCWL5cVg1Z2y4KTSufQgiOy5O+3w1rmgb/QoOqx763KhpN6Ri2BLU26casuRtKY5UWEnApb0HXLtwqU
# DATA iXaLmLWlOWMGPr36VV1Hg9ugFlyVKeLQbg7t5tBuDu3m0G4O7ebQbg7t5tBuDu3m0G4O7faSod1smJskmw9s3RaQWohTbq/sfke+
# DATA 8ZIjY7kU8iyZBSO5Hy3qxrvBbLjPM8kdvrh7g3IAx1HpPcqJNoXGzHzKt+8U3nFTvtGPGfcis+QetuPt+HYoH8lhMiuQ8jtLwfCz
# DATA C0fONEFMpoDmSIc7RO0OUS87RF065uOOU7vj1Bc9Tr1G+PaqjllLK2A7GHrtsspqjlk/RSGP66AuhOp4tqoZ+OrtHO4qSVvd7Cbs
# DATA wMgF4NVTed+kvufMgiKLYRyzAF1TYRvY9y+LTthiwWtR+/5q4VsZTyHFbIY1FAMOVUv+nxNd/byJr7lgIuy3lkW4Y0W4tnl8eVAF
# DATA pY3jwdGkK+dEUj2U6/aq7wUOxEIMfSuGHTuCxeit5D28oVpUZESDnl/cwxts5fEwxgAvTE70geS3B1DZRB/Cx/AzHujQ9jIyS6YV
# DATA 9mlSKx3B6z868aCkiUoWg5cnRpF464XOJbWOz41TM1QhhhQEBQgzZ6gD7CcwelRI+jg48ye4JkfZDOvuPKViCaYxW8SWCABOg7MC
# DATA Iy+jhjhJ5snazYEtBgCTDb1flowj3RG9Q7OXI8yQhgzA4Pbdx+5glSBEO+9rzgc0vDgHix0k1lmy6y1ZZ7e+4HbrRaGwT10eiBfM
# DATA rYXgRaNvVJAEZOpPxqLbin/Q42OkMEXWMlSfuqrQc6LAcRXY1AUFpG2TU5eoSS2Hp26mhFiqf8hqm6bAItKvp0irGtZZtT1XkOY9
# DATA PXoiNM8ETqX5qWyLRZhnhScFSZfAw0aJ+VjZZ6hg9CGLlKGEwKQmFQ0UhU6+xzcYo6Qswc1x/oDFXiXKEWWxjvHbZqIW8xyQoip6
# DATA RrM4rbAyO8dGq7IXLDSteG/jA9ggRVBkBeAIxppov4+FufWxvg/oioo1b1OKQh3xt7TEVUizW8SGksC5V+EpX8U7wWZZUXVCjzFL
# DATA DiOoWO17llGdsLLo2GNQgaK+rIqufuFijF8iARu7T3KWprM0l1mahXHKeUydx/Q8A/XpC1NKDDKlrJgmyZhV6rhB5PKUo5E0laUi
# DATA ifuqnlfEWVGRwQi6c2hGWJ9mKhh7VjxZvVPtipcRL0YBu8dWglJ3lDaplhs5TPR8U8ZuwgUcjLCBQQSyHRRsEyiYWFy2abXqTuPn
# DATA ZrqL/rL6fq3SybmqPq++W8t4Fs2PZx8jluffBTku/i2/tRrlogtDUC4/mETUmUzZtbiHI4vaMsT6ht/0Du2VjFqjSheUG/GjSBHI
# DATA aAqCrXKjkwrZ7dj726N6McDXGcZLhIw9JBnWPORUR8Y9BIyt4yAbipaqttDp0miUbYODcy359+FxwvkX0jg1LeZevVrMvUbHyr37
# DATA vFCDZHNfqzIJiqUAOs9YjlKkMeUu8QuPIuCLsFnXU4dwRah0C7lVaIMXz7Dm6gyzGrTk2XepT6XY3Ut5KjuVCUyeb7VSrau3m1a+
# DATA zWBK8TIZG07xZD7DkAPR0lFxYsUjBsN6qObR7EpR8Mwk7Ag7GkfPQN61LpB3b6AKpCIrka8PFrKvVO3qtWop+yo8lWYT9VCKIqN5
# DATA qiilgtgnrRH70cM0OMZWXr00wHqz+dLAk+SZ3YdfMMveXZ1f+WigEH7Jg0Bb1zqT7jGnQrgRQPcJvfCIbA5jppOF+4Aa3kihnUJW
# DATA HR4nIZP8vCHWgb0PRCiYmVa4YpZPzKpMRgM95Tpr8qJFbyPb7MHswjWttjrj8oFRMs44BooGms7D+7iqvC4Tz+9QDQt1XgVevcV7
# DATA hqiiYlsguxBouqQcMWK7MUae61riHc5jxfdibqzy3rDZyFvOn1WE14vikMgxXoN4BolZm+P1/54+PvvF6denX4Cx9dg7/ePp708f
# DATA n/7r6ReM3vpiEdj1P+in351+A8bW2X/DLZ4guU7/fPoV/fTl2c/Pfl1BOBQmhfU1/fbv3tmv8NMe3fGYfv8Fv+nx6df05i/OPmM8
# DATA GJBdigD2C/r67xQg/eSYXc+DSyWH+qHLHNs8IOlDshg+UGqSGheYzvszVr+XDoUyLJoJfPEI0794LC5IabdwoQ5w+hwcACiU8FPg
# DATA MPJGVN7u2Vca+UkwWovxegsr42FwYmLqOF62r0V1ENcN8lpSKldH8lK1MF8yuq+q5SimeKYn5fulNuqb3y5U0m3CvOAyVDERLXzZ
# DATA mR/peDmg12ZFt3Wm1/0oBx3kLIgUkFTdZRkqB5ecl6G3wV4gkRFmqII5RQzPzwm+7nvfi0M9O6beTabX4pxSKV0ge51fGVfbM4ut
# DATA 7Gmhvc5PhUN7OXNg++aApn1dzgp4KVZbrssCuAoDYKPx/4LD//WM/lIxF3LBgn49Y43qKjhgC8kH1BRrQxlz3tenrMI1EKpXnIRy
# DATA Ot+eqa0RvAWCRULiIDVv0kFxymXBCcWpXAcbkcE+ZF8v/EHYgJPB9RalwaiiLDka0OJwjuKLQi5GGGsp1RBeQw5zzBNHWJsCZscI
# DATA zAMKVFwecE5RG4drJp7sURYziN0j62IWTyLtqOLlM4SOZWiYLRWxWejFYocYEJSjhDlKmKOEXR0lbMMhZ6M50Kam8/VOAy4zC9jG
# DATA JMCRwhwpzJHCHCnMkcIcKcyRwhwpzJHCHCnMkcIcKcyRwhwpzJHCHCnMkcIcKcyRwhwpzJHCHCnMkcIcKcyRwhwpzJHCHCnsmSGF
# DATA NXr1kH++FCmsPWgOes8RKWxh6XkjVJidL37Tq/udYbPVLdGmWtQ7dqJltKl6R3KIy0jKoMGKlELK8v2CUk+57Gq+XXitQv6bdxZC
# DATA b3b9Kwy928oDb3QLgUuq8sD9esuGgBUC7w46vd6gHHir2d166AXQW0NYbAIp81s56K3ZKQQQNYOgU19oFvS45/udo0ZzVOt4fvsc
# DATA AtnqOtG+BICMG5sGkEm7LQDImkG3tQGArHAFALJm2B9UcwBZq9+MOlUDIOsP+rUwsgBkzUa/271yAJluoGvhU/t+U1PICveb0VEv
# DATA EDQ3oY0Vg9C8sbwf1zm14Mi0Hu1hUWbJM5suC+y3lAVSsx0Ptf0la8I+G0SFNxc8CmIZ4Dmevxhvkt8kOwEm1RKPZM14JCVTysss
# DATA Sxb6mgsvqB3ouRb13n5ul5Si32F7bhkXrdvtFmloWGVeTSkrlFulVBZrrJ3ijSXfg3EfOgyZw5A5DJnDkDkMmcOQOQyZw5A5DJnD
# DATA kDkMmcOQvWQYMtQFCiUcRZWIl4nC29UKO93505TM7ii7/eOfVOBQPYpuswVbQUf7Pn66jSp5YCo0ny6DdZTu7D6KBzvy0O4jHTS1
# DATA UJggwaQf7U/IQt3dU686sIM/YFVnfXBjR6K3e4Cu4ONXPsyPsYWCE/vUmuNgH6F+v5Qijn2seS/ST09RUlnJgybG6Y7qraBPLOmn
# DATA BEzCG7enavd+9h0YdgeUPgT+Kv22+4ifvj094DMZFCf68S/4GsVjaWoKCTZZf2Ay/EBqHSb03OjzGkZ5fk/pO1PeKyScPvljlJ+9
# DATA D3FIqnj+MqXoM8GD8iNOJPvElj/4dPXrmPTWj+LRzg4ldQ9p3r3Jpi0gbypLKCaUZFMvqCFx6vfZjbv7KK8w1mWJu30fZZzNxctr
# DATA kIolclVySI0Fu4/yDEPRoThjysb4VUXOY0k3pDO+cUPfvD+dk2nySMX8ltyJU3Z0X4UjQhPrj3Dq7j8/+7/UmUZg8+Ib/i51MRSJ
# DATA heD3/N01YeN4pB32Bzguycsfi6F/mteFT1Ud4cmkbpOLVVk9cFCo/QdSz25jBqurnnVDpdasFltUOp+IlLAQ+rg6cCujC6+tM3Dz
# DATA Nq+eSnGG9LynuHzt7sKq+XkOlPqZdU3iA6is5u1BJQpR0Ukyc8Al0eIzKPGI5kOmT9U10DwmY8VuIdIU7HE8oeniskCxkkYPRaVM
# DATA cswYpzNxSZ0Jpy/x4utLXJQk8yzoTvDKSsFfvx4n8y4OwYPIAfFVfXA6OMSrZsk4SWlmtpYp8yyKVjw/R7ivgjSzqLGxbdTMMhGT
# DATA S7JmvMISkVRpXmG741e1NLBgNo2cGL1M3QIBT6knuciHLfT+gKyyirieRMsekTeWt6zmJVPMIgHXE9bDcJ7OWOorVu+d0sg/Ef2E
# DATA REl9GBH7NUIf5ymPvkBH9AsNx5lQzoTa0IQq9a9OtMuJdlnD70rj61kQ83p9HoOpVZStMlJe3xVdKLspYeSZRgka2vEwKYxQghDQ
# DATA A9i+dxciNig61tQJZC6s4GPRA2qOwSgeQPEGottwPoiE1CSKQo0Zuyg/xURUAR+UnDak1StLlLQcPGUTeMo4kaJjvXv1eR0QJWU3
# DATA mkjgy+fVd2O3j3Cz3+BPq+/U5o7iC/Hn5wGdYufeBVXyOzAcV+vk52VRYFmwV0+L4/OsKB/ZMH6lyfxwmDeGnzLsnSU8NC5pPiHj
# DATA kbWo8g3TaM9HSczaVn02Dz19gh5W45zF5qYs3wtjk+JwGM22QRl4gvxrXiz/3oyyBx472y20ALRxFdzJpJcl48QVnjHP0DYdjoPR
# DATA A8orLR/I4eG2+QiYbkY1etGEy4DF23AKwgvnqRbXpUFqO0yLvBleFM5QW59veauWfHudxnjZ98dMnXlsap+yrajORdFKIUOsHk3A
# DATA spC8ZGk6WUzIFL0rymb73vcZiBH1h5P4k3lkFBSpktKEDqyE2RDTjmHANRH5OlMVdwu5mXdTF83Lc+qg7vUkJz+iusMqiFqq2WBI
# DATA TSZRGrkKsYWqUKMGCU8Wbv8BpCBLpqzKvYBlFxXybxSpSSZnu9KQM6Leg+Iw/LRacOtiLfj1YMR2hJoqRDaLBsYBZ0g2n2ICRgkM
# DATA 0t6Jmhv0RWdRdjrve7xSg9xlOfJUsd0o1wZRBBFFTLXIooiyadSPmQgr6pfpCesZmkn4JDreRg7aY99FK2B1fRbmQ6mCraBypeai
# DATA puDStGvMXRs6e0XqMdOwfgAqD2XUMRnYMNWxg8IbkkWI+oUsYxVQFj6kSg0dyCNsFVN7bJ5ZqMoL5NrIg3B+DefX2NCvUaxpzq3h
# DATA 3BqXXBNa6QK5Mo1yVWUL9FeY4lTNjXfjqbMy1nk3mMm4kmPPG715mQO7v9XJRX3NTHp5V4M9cporetbLuZSfj8TOEPqWDAZiGgSh
# DATA 2AUFhwTvaqGf2UYyvc6O2p6yq/wiuoVPeEM/XiGRUk+bnlF/N/P8uhzfxDCQknFPxgufucPFcfBQ7qjKObloykfzVvtOeJMMp8Qq
# DATA 042jqp42UdXfTVRr50bV72wcVdn2g8jyp/Pipm/PY2eumPg1lkXPt6JXWxM7tSpo/FlyLoCnf+Dt3eR9imMyseVGNj/S8Z1XRVoh
# DATA z0IcC7HrYH6pUOemNLjP5DjuTQkir8jGN2O1D3NphQNHTCKaDIaWqV1Q+P9rsk37eoJKE/MBRkkD0pEpw3FAwztgO1N6lAw0zMAU
# DATA FSifxWogpaITqsmWUFLN3l8LaYkhORntMcySd2zRW0LwMBOhicKLUvHC+Gc/izGksHtlMs8gyJ+dkO2bjLPci2rHbBiNpucsHJdK
# DATA NV88tv2q+TKw5L/s2aLH38eHvMQvFZhs5ZJGGc2s6iM2LJfYy2GVW6zDeUo2MZl0Nu3w/2F44RegDRYZhGf/iP8u0g7/+fRz5hF+
# DATA dfrN6R+8s789++Xp16dfnv09PfkNfVLcQmYcglgogXPIHgMRPwdG8ewzuuH3Z/9AD32J2745/SOFo5/8w+k3wCU+ZgwiBemYh8/D
# DATA DMNUr3xiwRUexBPkKD1TUf5K7nA0EoOFkwzdWSJMFtH7VIpCI4BhZQge1JNqo2caR32aja+DG36gtzHQAMBoNYc2tCYTusCuG264
# DATA UCpXhzZUdUTfBs6GJu7wLwv3Y/uK1eHeTwZqT8vW0YYcgQLYMM64sjus4WbFtnWs4VsPpyP0MoF2hoyTcD4KQF5PZqzZs+99hL6f
# DATA +658nxcvfmFjPD1r9j9RHOZj7ikz2QYFF0oyC/RaVjARdMwC0PD8Krjaaim3rKeFMzw/DQ5n6Eb6JxjpNbfwMgP8y+EpvLbBfftj
# DATA +0ZD+wVH9usZ2KValvLAYhY+rZZzFXDCUiqxAgASkOL8xX0rsfqcYzlBgbg0FVQOtDW9iTpD8fDma9lWrCW6YSVN2CtazrcNiYTG
# DATA y5rHLpslfV5x5PFYo+KYH8e1JKS59iQz0Y/maeIFY8a/8ZAfkdkQ92MsjRdsgoIFEP3/7L1bkxtHlufZz/oUUVVWlplFAMQdSFJJ
# DATA bYqiLl0kxSGp0vRIHFoACGSGCCAgBJDJbJXWpFLXdPVWWWt7ts3WbGx328ZmzfZlH9iq4oi69sN+AeRXmE+y53+Ou4dH4JLIZGaS
# DATA FF1VJIFAhIff/fhx9//vIQ4WI/BOAG+U2lGt1grJeqDivBH4MSLEtl17DFeMGIns1RFKnaytq6JuTQ6kfjlaoaMVOlrhWdEKVxxq
# DATA VprarGoZn6eNfxIT/zQsfMcqdKxCxyp0rELHKnSsQscqdKxCxyp0rELHKnSsQscqdKxCxyp0rELHKnSsQscqdKxCxyp0rELHKnSs
# DATA QscqdKxCxyp0rMLnhlVYK1WrtfYJWYVBp1sKGi8QqzCz8HxsUmGt5FVKxb385ubHpUa+0vAaNfp7t1Irf1zd9MpevexVGnubm6lc
# DATA apdalXY3i7GjsOpzMXbVGbKhnPQTgN9mGuBXq5QyBL9qMylrObaWEPyCZuC3Z8GJFh+wWUsFX65spoPfrCwM3SQzFXq1WFsSeu1E
# DATA odsl0ix51Wpjr7rZp641X93cq26unNOlWRhho+TVSo3deq2WCaVda7da7bkoyuNjB6XdaOygNEELO1jv1JqNzpHYQb/b6tZT2MEO
# DATA /d0pW9jBTr3WqBnsYKvdrraqFnawXKs2K2eOHTTb1CD8v7PSfH0Jt0/sW2/GLtLmeOZtZqBUU6+3AupuQj8n8ZsLMKyplbjyDK0P
# DATA C4szL8i43W2jURdIet5N5p5Xgh3g1eWPHSZbpyvnUE2bTsgUMXLTQV3xs4aKhQ1MR9beXKBHdLXsVZzn7ZXFlHTSyvB98l/qjz3j
# DATA Xk4czGRrLpsnS8yWpUlme8IBBx1w0AEHHXDQAQcdcNABBx1w0AEHHXDQAQcdcPAlAw7afDdJtngxhJTGR8UR/Y1fNYsXysUczSzV
# DATA T/tchBsyZdOYr2tySIYPuqGRXeBfwaVr9xFw4P1//7u3WcS3ThAMCx/SfwPQ1ijcK1vF1z5ce5+11PkcHS/UIBD6UYIo8JSHIixh
# DATA mcM3iIvXOsC9TMfzWzFC3DBP4RO/6x37KJukzgviMfzIwSXvf/zu/0VkZtK+XikXL8hVFvdE14AgNcrMIcTc2e6jzna7M90/9TPd
# DATA xyWFPQ9nvTMutuWYsOtoGuaJgncD1d7WdpkLB3ump8NfnKORZ0EByx5mP20G2KwkwEkJYGl/rT6rf52pXVIR5DXdwOjavAHXo+91
# DATA Ivoh3ucz2rfghETVYimgXT8cFbw74ZjdT1rwXSqgCJdPhnI8WRVu6vi+n0gZDSHaGHX5LHIimpNRuJkp5wcBTGXfyO3AJjp/pZtn
# DATA dArWakHOGHLGUNYYmulRneiNE705yox6PsRwbkl9ZaJFJzL4i4+illHEuW20G6gZhjsDRf5SGmoKHzmiYaENcYsubhYlidgHfhXu
# DATA UY3H4Q35LN8hOjRwQ/Zs7ZY5mikrg7/uQnUG/rFEycbmwbDvQlQ7HO5rNdwXJQX6JCrpY241i2Ff7HYUWWj+uPhe3p7LPctd/vQi
# DATA wLusvDgmd+XOEn6SzlUhrlxFq6DSFdtKgCt39yMRa4omEIzxIccikJU+WoqWSEQN99kLJbJMYh7SuLYHL/LfQp5l1E+rF4lKEdl+
# DATA UTLe+RCEodrhi0Z9lw1lfeZUGo2aHcwXdp4VgDYLb2KTJAk0OaalHDA2YEGZM4YesAShn45/deKSu71yyd2WA+Zipeuiuw5bBB2h
# DATA z2wAKo4dpf4dM+krGLI6jmIJpdFhKD6W9BG1byoCmaRuaz4jPIZqXxT3pr1grMACIxWXeBiNn77IUik7vzJLepNjltm7y2hlql+S
# DATA MnsXAkTIx1ZEEbIBUSxNpNdRtKDZjjCyKHepE8fFqEvWiOFpdYN90ZzSg9tYJOFxpyzucEnvM/2NmSum0XHptybxwdOXVjpNL0Bx
# DATA 3Vy5uG76ALfzYgb19QmPKt4VLX3TGKjX24E//EFwINZ+y4eClrcb9aVhYXIw4NBYo27gUUGNQAsDKge8KnbAd8OHgo9jaEJSmFnh
# DATA t6cvtHTKzq3QklH4mGV2d3GZ6fFc9YqiHIhrSXmJPwL78DEMUBOKhRXYE0cMyyO31TjB3jhvm8u3y/gu6oQgQoZxTyxPHJvyhhM+
# DATA PMfiCQOgXU6h30vi/vyXSHnVErkZKOU6DB9j9ZMiXMr5oEAPMNKcxNoQob7I4+NdaAEHIkgoYEDVarh/45k1AoDZzUNZGGsjBaUr
# DATA +nen0GZmE3KiYjpfwtxTYUxeBj+bFYRztDlHW9bRZlcp52NzPrYTLjYu9MmdkeC0TMllpocREJUbNqZxsT1DqMEZkedSniy99wT2
# DATA Pm+yxvJTk/fN8ExY/X4E6CwJxXRX1qWEGncU6qy+IodtX3vLDLiL5wVq1956u38k4E4CSAB36rsFuJuLjSvJZQ2OK64MuZPdPHAX
# DATA 4oMwxoSCDJVizquMA1E9kHgPdQgzPrtGkbFf2Nbu7WMhk/cXNYqLvXylEj9yN3iInqhjPUW/LHmsyo+9TXcf2M9Ui0vchAsRddo0
# DATA xW5astTGLy6kznbd7e9SKN5HZHkOgoOCLfmsdJ2lE4BDaD/yStzS/JGCxekNa0OaJinTHavO1FlQnDC94oGbgjbueHFocN8iHnvl
# DATA 7tfq2vxite3MY8AlFVilXOR6Z7Vw6qMmGn6p9uS20zUVetNKhp1C0SrsObLwH0rXN6A49mSqyKrZw8kIoHdZ2I5i1k+1BLJXgMj9
# DATA RIznBCFHvUjQHvndsYWQu6Gv5Q9/P/3x8PPD3wEiN/3zLDruX+bi3+jLY3rqi8PPDj/HZY/+eUwXv+K/HwEcR1e+nT46/HuDhHsy
# DATA fawU0qHwNYR2Kg3ZDhP33Jv6bJn7nqkz3l/7e753rRPKWSwRvVf7Snj22x2FwaBDHQh/249GvY6x/uH5ngzFdwpXgrjOegdM143g
# DATA 0haKKDsNkgUK1fPgqeAhNbTOUoTc6xDQYK0Jj/8WnoTjyCUzAtMpnDdHbn7RnB1Mbpeiw+SCBE7N9VVfPwomd9UXSfCzAMrx5iuy
# DATA HelfGhPEdYXRHA3GAeVWK7pTB8pJnvls5gzQucm8ykyntGGjJlN96aDIctEVhRf4aHhDv8vW9s7Ep0YxDqhveyOMH+Rg/dDTV2+9
# DATA 58XDQJEycPyd0qZUYSZsA8G1OF6BNje/ji42cea2wecFOzc/MQ4956yHM7IeNJbuxEbDS+FCPD+D4YzshZXMhWNaC+dnLEglnZcZ
# DATA xlB4PhvaWVDsrGwAaA6LxJ1gCA4VmTJmoDY5xLP5BdnSjvr9CbprLOC9gxlEmx0WLCkSU760A3vEHwXsoBDvHzIsVpvtaaSnIuPr
# DATA 3XDEp2jjeGXCHUBasfLNapgYZcgeWYQj8XOoX7s0Vw75gAPvCLoRfUQjmsfJa1MGRt1xwbut4y0HFBQsLOsEnrFb5KyARpAZTQsm
# DATA mSE/oIsD6eBdyuSwLd5jTvtA3DW8lzMYMEcHJ+TRugAiU1WCctUx7xzzzjHvzpB5t+LodaKDXcvM8nOfaZyGR/Wk8wwHwHMAPAfA
# DATA cwA8B8BzADwHwHMAPAfAcwA8B8BzADwHwHMAPAfAcwA8B8BzADwHwHMAPAfAcwA8B8BzADwHwHMAPAfAcwC85waAVy5VOpXyyQF4
# DATA lRcKgDdvBXolCp7FiysnODo5jZbkeyOjUFprprKrWtts1IIMWa1cpgKoLiGrWa/ePPGrm+VWuV45+avL9RO/utJstKqdk7+6Ujnx
# DATA q+vlzUq1cfJXV4vPrKyrjWdW1rXqMyvreumZlXWqXW82zzPDU+36eK9+2gxPtevjvfppMzzVro/36qduXMVnVtapdn2+ZZ1q1+db
# DATA 1ql2fb5lbbfrcq1+nhlut+tjvvppM9xu18d89dNmuN2uj/nqp25cxWdW1na7Pueyttv1OZe13a7Puaztdl0pVc/VVNg88aufNsPt
# DATA dn3MVz9thtvt+pivfurGVXxmZW2363Mua7tdn3NZ2+36XMradj2Ui16lUd6t1Yt7jdrb9DXtdGi06rVqe+5j1WqDH6vUZx+rwtHR
# DATA OI45piYgFly+VE8FWWpWKuXZmNSKNa9cq+2Wi/1KzSvulouZ3GjVglqrMRfJ3jwRTb2S0NTFn2PR1JtFP6jV0zT10malVK6laOoZ
# DATA vjpo6q1gs91NaOq1cr1ebRmaur/Z6vrFhKZeLdXa5eKZ09TZGZxv8SZ94+mUxXaNRU+8rU1xWNvPZIHoZilu3rKb3qjR4A2a2J7J
# DATA TPTZ3Y51+FnlNXwQbLVtGXVrW8ZCoLsV6nLWuhSXclrWzLKLrhF8LGHX70T7lzbpR/wpeqoUPy3Qq/pwgS1Ygi3PBLc8D5MAPbXV
# DATA VO9fk2Ur8+twzu4Dtdara5hZBlB7QRNPdy5zoiC9vF1cDFu3S2qJO3xeXWMnN/vVHVTdQdUdVN1B1R1U3UHVHVTdQdUdVN1B1R1U
# DATA 3UHVXzKoemIxKu2G9Q1j31Gqvdui/ZEIf1wWYhV32Wwr9w4YVy6iIvl+1Am2BF1BF2WbLRp1ck1EJvKwQbbKtVq9xlcxyxPZtHhL
# DATA s9F5aqwQ5+o3NEoNSEfE4IIYQ5htqymBh30FG0l+qcsLonEHIXNh4guqObeNQkxDdbBezNWrGzCOcFBl/eIHH6r/Lm394mf4d8TB
# DATA 3Lu4k6NytTjtXLbeLJweqgJbn+z5g7DX8y+Vc8PehKb98aVKDpJxl2qffsBR4Wmsics9jae/M9nZCWIZF1mAzLu9feOSwca3g7C3
# DATA jjdcyGbPrwqlJtPk3wpfF2j96yz/k+jwZkKRAEQAhyb5CELz44ehQOVLhbIOEp2zYolgVBDBC2jqidAhv1DVGWjijSHPNyZzWdcg
# DATA URKCZIsC0nMmJBqydPW1ZeYUZ3DYXWDJfmImGpBIy8jT0tNJJd+4jJEFjquMRg7EPlQCoORiS95wjGUg+HkuLdDhdOqcTt1xdOoy
# DATA Yi5Osc4p1s3R/FnMsnhelOy84QjtlDW00nEyUnbbaUm3nQmkcSHMtEi7TYEtBuDNhu1QBY35HauxarEqptFmJenSaK0ZOTpz3275
# DATA yi0MTdS16IiLN1zLTf1Gxm2lmJaQr2ADR0yoBwYQqBss4+RZRX/MAvUSXAwtX0/GfD3VvQyxWGhNKbU5ILY860nGeULZiuIcQBuf
# DATA khLCuNYcQj7yF3U5OsFDQNRE1gs9lXmYRqpFSn2c7jeUXcRye4nSrRoadfrvGEPK04YUFOuA9xGlYpoPC/VE5VDIOhYF7zcYOWce
# DATA ae9OoFus9ceUuVLweNKQGmgFDywAVPHU5lJU4cSiIOMSCn3Sc6OPZcxKiAgzqJheZc4SxMtyZFt18ZIjqlfnxmJyYxwNFduA60o0
# DATA YjU5qJ/FkyFGaGw5hp4z1bV20LH6/7H/QOAKsArZnsHka3igClUPLv6+f5BYVDIASezhq/buBuzI1HFjsKtvmWIMIraHHK5b4XhZ
# DATA svn9eNtHEWVaC4Ohz3WO5g064dfhQfEs216rAjINKq0XKDRUFu2iKGFha8glx1Jyfoe68NCQbZSgnE6AyNBp+JOeYCSCcpp1w4BO
# DATA P2llxlRjqp025VQ2UJ/Tiw7Y65uFrIky2E9f4CwZdZyB6gzU4xiozhx9eczRhWbmcy6sbC/wzyLMeik7VVoM/T3e5QEJtoqyUJNH
# DATA WK9HobCeV/nlF0tN9Cigg7WVQ3BzvEXmyqvUQWdbqj6Oltrk1SxmNnmpo2Z+j7/Nay+zx8Sk9bcjuKXkjQeDto6OUl+68u7MKTP2
# DATA 4JPNs0DI23qWv3C6MhAwvZFGa2W/rmzGXa08zfmjjTE22OaLNyurTMsDM69jMrRsScPgpMEe9qieLhjMV9rATJujloMvg6/I1oXX
# DATA JyFq/qzetlSKGWLXkYSPgXpxjiIyCsh08VtkdSvAR6a94/SrNAVNAN6tXLnTF+A35aahIXNzYy1fXxGR99KzFpYBB/V9GETDHrXQ
# DATA 93ndA3mRzD9YzUwRF0UmOaUTnjYcxz4qrga9GWsxi5TmKKvS09FVkz9j7GP2oMtTMdNkhoGdEDLjZCwJZimqq1KlvSRit0ZkRLbH
# DATA yyN2ldcbvBgW/4GOnrooM2m2wD0fVYnzCDm5P2LV7Gh/QFM2+insQw5dV9a5sbkqk73Z2LyEIsWOm+ys+JNa8dkq5/zMzs/81Ab8
# DATA wunC2fmZDU88y+MwWLXnEvN1HvxlvfJLP1x7OJR9O7wKTqZMEE1i7Ws9gmecBGP6PeuSAfg2jwIwl1YGGhuj/33uBhGxNMBY35Aw
# DATA ls00IcsVVqvs+E057hcziNU6vEzz+OPie1HqbLax334Jo3g2ZbyWblKHb4yYUIb5+lvh60cipq1g0nmgL5p4Vo8qltoxONO86q+g
# DATA fxRVuYA9IdReKROWR9o8bmGn9ZWEN31UdCurxpY3ciQdWJ86Buo7MnHE7hwbNT7upDnj8t3EbtuLyWLSyzR2VFdgUl/TqGTuIEYB
# DATA r1loz/SLC6g2awXSAff8yYDmQ1gQiMdpRrVJfwdwGja7eI3AogyhZx+BzAyEtPQyBW8bl/dCsnfsRTK2hIKHbbWa4cl6hDrq0FXU
# DATA TGzw8AVgcxBjwxrPOnjGJkYUr1UoQ2nkh4reBJa0P5SeOlOeiQNF9Y7JJpJUxlruEYPkmeUiJ8UueZTBMc3hMPEKWxbExEyrThQI
# DATA PkrN/DxwovZRySgzGBnaHiu8jxmFjuZk/9RmTRYwexKHbXh5wshCZk//j8Mvpl8f/hFU6+l3h3+a/jB9dPilB3Y2/fCX6ZPDL2fp
# DATA 2f88/XH6Pd33h+kPh1/S3dOv6eF/o3s/P/xTzqNPP9KTf57+ePg7ULQRtJC0P6e/n0yfMEf7M3rkX+kWkLS/8egu8Lr/RME+oWAf
# DATA 4enpVxStb/hJCuIr+vsHYLkPP3N07ed/QkidWNQP8iDLCSJLc6e4r2pTMwUIr8fLwLxafkuNEL62aXOCBGPnFJlxw16geGGKdkW9
# DATA 30hD7ZkNlhitSynat/EQ9UGBQ2en5ntJ93De8GyrRM6OmK1qVWzN9PgCV8w4e3cr8JPu+nX6wpWxFdBYf5qobAqX2dWhHsnU1oqZ
# DATA Sd1LyspeodBOnZR9dTeCTr0PiDmNqQNtv1IGs9tJESW5N6Fym9kDLj5fsliok9oLepcR113eJkX2XWx7qfxYekO9OeU49W+xBZO0
# DATA pmfFvj4y8g577Yb1pxzWNd76eKP5y+G5PceR/DQH8pXG8WMN4+cyiktNNElPdvs+06ZyFoBqk0bZHrooedx5K48Pl3NOdlJSGnZY
# DATA KsMf70oautgIuStLtrL6TNNzX8i0o92D8W4/KTBrL6Svc0MhizEUr0Kkvhl5JroC3tXMZY7NIPKk1cyH8xa8bf6RBbpjIROzorMs
# DATA YaleFQHF42hI1tauouCO/RYyTA7YifWQpMoAsim/2mEs+hQ6S9twRji+tONLO770GfKlVxpSVpqvrGj4no/tfhLT/RQsdweSdiBp
# DATA B5J2IGkHknYgaQeSdiBpB5J2IGkHknYgaQeSdiBpB5J2IGkHknYgaQeSdiBpB5J2IGkHknYgaQeSdiBpB5J2IOnnBiRdLVf8Wu2E
# DATA IOlupVvs1l4gkLRZcV6JHm3nB1ystdpuvVjeq1SKb9P3v83mY1DbnIO3anqlZnW3Vq3vNYG3aqYfa5c6jU4p+1i/VK15ZXq0UsyX
# DATA Gl65Qh+8SjNfrXoV+j/91sg3vWrFAzyrlK80+VoZt9e8yqZXKeFuXC56m161mS+X7LfyTsg026rSqfn14jy21Zy6UUN8GnulchbQ
# DATA 1qq3Sq32vFCqMzA+m5JWSSODJVwL4FVPqm8lTTIP/FqjNRPDcrn+9DEslypJDGuVU47h5uYpxLBZT2LYqJ9uDCuN8tPHsMJN4oxK
# DATA uUqN5KljWK2Uz66Ua6Xm08ewVqydXSnXNkunEMNG85RL+TggPRmENEhPxjMLpLdZrZUqm2mQXhabx1f8LEiv29kMaglIr+7XgkbT
# DATA gPTajVaH5ugGpLdJ1nGleeYgPd7+mV9m3RcqGT7dp9ZDsyy6lEuo1EzPenQmsI0Fly3lPTY9rufLnWBnIxVyhtD3VkDjeujnJO5Z
# DATA 53eFXd+y5M1wvuz6vQqZJ2urrqkVtPnO/tyKlXQE4+mNRynL3TgWcMRA+8KxMSx/zCWg6jwHNPvhrPCUF2wWz6dqU7o0UBiWV6KB
# DATA 5ZX526FmXlFArMlmtWb5ZKLqxmCXMFnFtfbmYuheUsI5u0yWzCJma5tKrlWNlLN7eeHwVAC1fuE0Kimo481HHQTQQQAdBNBBAB0E
# DATA 0EEAHQTQQQAdBNBBAB0E0EEAXzIIIOqCmihusXWa83HoMwcJ31GOZdiKlyU/+HTYltSWsPMft/BjHrXlMgci4hFbanhTXyluHxRz
# DATA 5Vw1V6c+Muxme0h128aGftzcfZlfZyri+iAXgv820N3elnrC6vU2Lg+W5hIAcnrESuKn3iOj5MOtKw/1G6QnoyvKzn2oujP6D/Q6
# DATA e44xxNGx9Y1PUjl5mQ8Ba1uRM3Qjk6rB1hVKEB+/hDHK83Y0Pz4HhyQU5OSnwvxR0NwrKQjeBptz6Wnoh2vqvB86iqRWbtGoyxKy
# DATA csqY6qMw8G7LoWMkYUgdLGPuTMLGbPECufcz9fYNsfznl80RKRlHOzu9VEpyIbVz1CJJEgf6Ab7fM0WggIrRFtdKbfvHbeg8Irkb
# DATA uZ3UT2/RJIIqdkRDVkAZM2gfSKHxa+htxddKzeKlSqV4eaewQ/fCWPwNbthmo34dpxZyKkDZho7LG/ru4OEwGkCwze/d9vvDu1H6
# DATA 2WJp9tkLhWIdEaKEDKiI1ncQmP4id0NJLxzwyibuZA/UunyKhuvzQmxQMUkB3pLMZMFEwB3X8eFCiZmNUddrcpFy4vUvv2xe5rq4
# DATA ZU1kUNK5ShErcAKAhBsl4rr2qZqTsDK+RjDq6vBJUvcvq6rxqW4DPAUeY7sRF+H21a39cEATqwKfKud6+XD829+qi/tB60E4tn+S
# DATA 3uLqxniXxmnv2mjEtVuOpFvjNNLHWST14Le/xXxw+ypFyN/3Q5r9cfahn+5jnJxTmY/ZiqKh1Yikf5SGcvlTnu3beSJlJHFOmxez
# DATA x9dF9EgUeCB9KKe4W4EX0DRNt03qd8xUdk5Xx+fjwh5N61KdHorMPCZD3oYVSwpUlcKcILHGT4+YoKznOGtfk1YvwYhPzRyqdVo2
# DATA TstmnpZN+qC1E7VxojaritosFCA/K7Gba1h34dEVahODwJZt0cI3z05A7TxUxsUUoMt38cFbR3HEF/vhYDIOjtKx1s+azslcMJLL
# DATA SjU8Kwkte0OUJnR5mYS1PuZL0ebjulCMP0CXxfkdsXAGlQ4voO3KShMXJwUg96czxqwnWTlhfmSzlJesJW94ClTkO9MZoT04SVaY
# DATA W5Ok84OljLr18neVVn9XKZ3NeLB8rHeVV39XOfUufrByrHdVVn9XJfUufrB6rHdVV39XdUZq/UrtWO+qrf6uWupd/GD9WO+qr/6u
# DATA eupd/GDjWO9qrP6uxoz++5WmeZfWVzFteKG6uj19/QmIqeuhQpAuWonIGm2o73sgaCUcnaGpnHRgMkJi9gBsMk/S+5BaGqW6PAmh
# DATA lPMqOa/Gw1EDFK1gwEKqHnYQcNACFO4bEpgVMRqo5vtPPfSvDDOwZL+Mtz1RlaJhCvMGrQiGQRBhitV4fD2wFaTMX3wxIQdtdVOn
# DATA 5VMnN1P6ac6UjgtifeayoLy5K9nndRYIT0t+85S5nbZ46VxY50KcLGsI8slD01KFiwKZ8SVY2edAHPUFEQtcUd7cS3YOauNKvJZ6
# DATA viwndih3aDINFU2oJBlDa1sptPojFrmCY5SMITxNZhXZV8w/5bUXEWsdyjSet3ZBhxHzdN7VlMMDqqAS5Uae0FMhhT16xx52IgoV
# DATA aAdsMpafpJczIwe6fFoM/fi5CLOPNSMz2rHnKZn+bCylVLV0xpIzluYZS6muyrmZX3o380Ij69lrquuaT9XZZ1npA3gABnQfb0ZK
# DATA NNaHIzRNyABnGtnOhObH7GoeBUoDe0bem5qLUQC3lMEjNcXnOpRxLKeshlkRdXMfjau6GfOIRKVr9JUxbEbdrufvRWGHVz8HURiz
# DATA S3ykNbWlO0jA40nCtKJbwbtDQ7TXpdBERD3mdVI5SozBtydxiXn/IgI5MFrg1LNMWjE1+slYDDeWkQPzu6OJcIhxwbuhdLa9ftge
# DATA RcNddsAofFzgt9ktj+cpB6Bbje5rvic+cff4bGsMlBq8zpQ7wVjMiDiRfu5F2MgyBs1XNuANfYYaWt2eBugVvG1kJgUdDocKvI0g
# DATA 2CV32cPCNq4yetuXu+wy93BGAn3xALmj0e+Sbk6Vt09v45XxJcm76cOuEW7xTmRU53GVzS0qCZjFUsAaO0+lLpV8HPWj0SjaV/re
# DATA Uv15lVwXDVd9TzJxgH2d0aQNDRjGoIvvKjnEm6RNGO4Gmk5FhYFPUZaXpedNludnzxgWeGYAOT2y6HgKEsBaFAtUKcJHGKTGPITt
# DATA kslgG5bUJjFpYFMvFtOQbu/ihDqaghkHpToAhyiYALzoQcDwedQ8ysa+FBKTp8my3EFV7oFET5GZDDAwY00pGsbZRIo9dRQp6HWp
# DATA 57xyhfhIjkouTLIeYUSbB5vURlqr181rxzGGuYVe5WVO5PRCiSmFJZmX+JX5lU/52pK8ln6RZmUa3+m+hpdLpNEkLCxhFnAjOt23
# DATA 8YLJbS5ZU1nH6HSsThgt5XTfyksn2Pe9uGGmX3hx0ntKX/xPd/aTIC7pbZ0oGsU23/Jfpj8e/h5AysM/MnfycyZcfnb45fS/gyg5
# DATA fTJ9PAu4/BcmWAJP+Zk3/Rb/MMzy2+mTw997jL787PAP9OcLIVyqgOlFjLX8gQJ/PP1e0ysZjEm3fQvK5ePDf6DfvnEIy+d/3nZH
# DATA ZlqjCEYSm8JYNIomO7tjZuSIzLQaXnvhGOoacorYTMQmA227kCmFUc9neKsM+GzBxDJzAwYFZqHPZ1CX8ivv8I4L6gvDnvcRWYxs
# DATA RDmSZTKH073AeWMs5xbM2QEtuV7G1vxRV1NBHqVvRmU1t95SNRfD22nSLMlYZSEFtYYpe02oSQwdyXKF0jp1kOW22lrVo+ZxkN/3
# DATA ew8SUhOZ1eDtAP+jkgVbt+3juBGNsiPIsym8jt/BCGGgUYMgICMfC/BULw94bqAoSDg/P5whWR5R8xabJfOa07MiWh6RCMezdGP8
# DATA 04zxGmZ50qH9pXDNntuwfjaj+kqD+nHG9HMY0qVezskBM6A/w/ZzFoTLOUn1aB5Kn5g956tlUkkuYpnjdU4f2R62Mc4ixZzceVHm
# DATA jc/q4VEkoEDpm1pYN+f4+hy3QQq1twrcMuXoRpRUMoz2J7u7sdXP26c5NtaARfkgFiqg916cmFAy8pPlhl3eXYpZCENA0IThgNeW
# DATA DO0S1k4oL1CeYRQaL2RtW2hI5VvtBDRG9kMyG/Z3A46F77FpwhvsuoGjXTrapaNdniHtcpUhZqUpzUo28Xmb9yex7p/auHfIS4e8
# DATA dMhLh7x0yEuHvHTIS4e8dMhLh7x0yEuHvHTIS4e8dMhLh7x0yEuHvHTIS4e8dMhLh7x0yEuHvHTIS4e8dMhLh7x8bpCX5WrVr9VP
# DATA irxsBput7guEvJyz8nxc+GW17FXrdY/yzStVir1SseaVGsXr1UbTazR75WbZqzQzXEu6tzWLw+yXNitemTK6Vso36e9Nb7Oer9by
# DATA pVK+TOHX/vZGtURhN2u9eiVfKja8ZsMrlRv5Gt1SzVfo9Zv5ci1faWTKpBY0Wp1ZPmCFot34uFQr5mtFr9wsecVxtdL0inuN5tvV
# DATA SjqMervZaZRnw2hWvVq1+HG+XGzkmxSpcjVforygGNUQ03yzcQRZ00RuhqNXasrr2uEIs6U2F3+dI+G1uWhLUnNHAipMxbdTa1ar
# DATA 1RPQ8rj+alqeNAWLlteq14JKaQVaXr0TpGh5QaNT22wltLxatw7b2tDyKq1qs5zQ8pqNaqkUnDktj6t9frlhwN79jG+aigpnLz+1
# DATA AtC2QYqdJomexbmpfJ31/+EPtfDLR60hzDd2FsHfrFgeTeGzIXvy4PEge9VZyF4SzDEge9oBuTCP7JxWGaowdqr+2R6jMttpbAyY
# DATA QWzBNgI9dqsFruJi9l2Srzk7q5aYE0fkhCHaOficg885+JyDzzn4nIPPOficg885+JyDzzn4nIPPvUTwOU4bTiPktc1DaXxt2YDG
# DATA CCLJIZYbmtufeoY+ht6gt3VlvTfDd1Ip3tAd2WsUzMN7Mq35wMOHjQu9dCXjmr9R+CgKBxTAh/Qf+FCXjXn54Zo+dp7EpTB+iHz9
# DATA cO2NmRPpKoAL+KxJUVfNDgUdqgY/abaSUwh3B6uXHKx2B6pfkgPVx9ULf7YHrdkvmbjSZnFEvZQW5k4UdXC22GM/oTlmyyQJBLJE
# DATA Z/tZn89+Ec4o8t+nrNU+7yD5aau2zz+XP1e/fYVj8omf1uiHByJQh9LWspOqchiNmbsBRSGO+gGEYPhorVQ1PgGv3G9MZBHdwPT5
# DATA 8uTkeA4yyGRrJo2d54zQM4UHOOp24ZjWB5pF9xCBS1XjV2QPnx9HRHymmsiBXD+xTp6NWM2zOM1qnncGlTOo5qjRJRXKCdY4wZqT
# DATA 2lEL7bWzEbLhPl03A7KkRLuCNTB2o3G0M/KHu5ao+DPTTTsFgCWNy28oGRpr9DqmZrEYAwjkFAWL1divB/O+P+TMscb8ecq3p6Ja
# DATA /D7Le0vfSLURCino+c5AuPhN2Or8ooEXPKR89OLBqcsHs2jxO4N40vPHol5+oJK3j4QOqRPvetTf9XpnIVs8YU2lsebOTFgDPNMa
# DATA Tve9NVGehsR3xxMRej3O0fB3uu9i+uOtYBSzFBNWqphvL7IwzDbK+yEZ8JMhNcjglNWoG0knmrGgqTh98GCFASIG9ylLRGdYk8m0
# DATA TIJMOybpIa0V5PUPjPkhvY3BUSYASFtR3SwHJYrymBzY9Uc1oYNEfUoGNDlxFC+QlmoDsKh1pSxdKqgCsbiUdwcC38HAY/DKoE0F
# DATA peWnuop6QHmfMwpZkeqdtaQpFp4OtFYSz4hGk1YLIvlcLswkRjWJeowvlnFANI5GEwh5eTrTjI6Xcm8G8gKz2O0r3dTVUI8/nemH
# DATA ZVC4CYibgMxMQNIWppuCuClIegqycGLxrLU0Fa+DmRa7/pBhwz5mGLY4dhwo3T0tBZkRi2TUjlaHVOijQCYzls7j2BaAxFjZ2wc/
# DATA aSK4kKzEo7TYCTVl6ruoFPaCOUqPq6ptcmqHV97kpc0k3q2DZHbE3OXWJOx1jBafigw7GmfdxurwqAWg1+htWe1nYBU+KQtLWUD6
# DATA xwSeba6wisAus2K4Z5PFWdm9QkO3lZQ0BFy912whgFWqPr8qGyPUy607TM9qP/VqxD1sYvhhDR5jLDUbdR/blpFy5GZvpwmqOszw
# DATA Fn9afGe7F/ZbHFF8WHwfdcwRNmXRndfkY3LvRUnblQymXNuashpvm5oYUZYYmqnSxWZgafbqjHRiOfujjpme8uYHmaiqfEznQwbM
# DATA xTupTXcgOwtkYjvh26veg75JRjbeJlOhHFm5cjtkVlMnYJgQtdaKeAn6UTzuHSj4JX6ClWik2HmtRnhd4WAsQ2AgcpjYJRnvRkpP
# DATA 1BfouRaPZaD4wEjNUsvlabF2byspTA+WmbIO1UGt883A+jEy8H2aE/fYdx+O2jRdTLIQc1TqGIDisjs6NcuBp4S6hY/UFh3qya7y
# DATA KgHbxry3EmZ7P2rhEer9AqnTVBQPYlk0UxQwLovTyC6rlRwzvzaX5pdpcpJh70Lyk9rFTmCyCt4EviedRwbBJRlZ8N6nMTPnsUpe
# DATA SEbYgfI/KYgYdedCiZPdKuIO05x5GjYY4xZ0TiOrTMdzzIxqLM0o1YtJNr0NP46Y8+HAqlX8aqoQ+xTLmB0x/qinVk+1bwZOBGyD
# DATA 86FVKytdPM3Gz/D+7Rwk/sIAS4DYky/kXADHuM/jdghJXUZX8E3PtE3WjtEmrwNEhz6N2l2eEp0XyJWpbfZlam5CrVMZaa28BX58
# DATA gMU9TYSjR8jmF+lhzk+xRWJgvKwZ+bOsYKXy6jXsekRFTGNkLzhgN0FSx3r0S2LhKO+uOPxodktNkD1xibGGDKEenh1WehFVLYqK
# DATA tQV1YJzIiVQdJWtFXFCgEY7C9tx8Sw/EsrfOHojNFcmGKzcjvQtOK0+zCaZ2p8EpokpSUaJ1fheOYoj9VBwQCUtsGIyB5rVRYv9N
# DATA QGLe9OvpI4+xXqB/fX/4n6aPpt9Pn8xixP6f6ePpt/npdwCAHf4OALJ/Ay7s8HO6/pfpD/T3V/T3j9M/T3/0Dr+Q0BH0E0DHHk2/
# DATA O/zT9NvDL+jfL/EmsMjozRTGIwrhkQaTfT995GhiLwAFeiArP9jH01Yq9QkFehhEQ+Y3MmCdh3Zqe2IgdiIon7O3EQON5ZJWYrh8
# DATA F/roRFid30A9SCgS8uw8XkoVewvmErPbBwcOJ2b7UFRHcN40sXSBnC1GLBxYa7jXdC3Vv8yyxAZjHAI0fSy+ykgXjE6TJ+aPBVGw
# DATA 68c0nMKCJUs36nYdTmzVUjt1pthVv9fGqmMgC2AHCaDa7/NOe14C6fE6idfFVMJjLhzL/ZlVDpB0+/2AJ78YS3gdMfzbgOkbXicM
# DATA xnMwYkdWusXWSaotPTuG2JEpcBwxN7qfxuiueWLHHtRfikWR8xrQT3k8X3kx5Fij+TkN5lIj7TxItls9+6ZzFigxO63iGFY7OHYj
# DATA eg6LD+mEIgUmlrqwsEi0JOnvgMHeG8ZCVeKkjf34gdqrggiEA5wcwzE+lSWrocQAMJKheg+8LgVr6iRkJ6k2Mqy3tU0A+FSEjXaw
# DATA CbC2FZKBMMcumEB3IRzPsweUNcDgI9gBWL2KH1BgJh4hnONcm6h+9bBLG3vIJuNRKGUWDdrBaBA7jpjjiDmO2BlzxFYaaVY8gbGi
# DATA cXxuRv7JfI+nYOI7mpijiTmamKOJOZqYo4k5mpijiTmamKOJOZqYo4k5mpijiTmamKOJOZqYo4k5mpijiTmamKOJOZqYo4k5mpij
# DATA iTmamKOJPT80sXatPEu6WpUm1u1Wg+YLRBOzl52PixEr1SpeZbPxcb5SzJcofxqVfKlW7+WrwGqVPi6VKvmaV6qWvVKx7DXK+YaH
# DATA u3BHqQkMWDrrOt3NzUZ3hjAGwFe1uOmV6R3VhlfdzG/ShbLXrCPImlcDxssrIexNvK6ymQ62Vm92mt05YK5K0QJzlTdrBsxVKqbr
# DATA Q6vaqAZzAqhVrQAqFtmrOVslqvPIYOXGcZ+38qVSaXgVyodyzWvm6a9SqV+uliiPPGRukbN4cULsUqQ7q7Xabq3RzJDOzAMzpLP6
# DATA CThl3DIMp4wbmcUpo3rUaPgrcMr8biXFKeuWO4123eKUbda7jYRT1mm2q61qwikrN+uVeuPMOWXDYHwkpQzji75vBcyX5SirsJus
# DATA 0OTlMQxpG7MkMBOyxpylZrrV2i+9Gv0p19jpmEJzSY5KCCrCqznVVKqMY61spruZt5er7AtkN17GthHP0xKEl05XLhW/JUN46jbt
# DATA AnPILofscsguh+xyyC6H7HLILofscsguh+xyyC6H7HrJkF3K4rA4XB3/IN664Y93C91eRBMbmH0fruEwFqX+VzBpLqprfD4KF+Ur
# DATA TbNgqFKrYevzw7XtIU3wHsJFGfQOKDcuIOgLlCvdiciF8fGwrqVzpc5a8SoSSFlAaunDXL46nAUNMgQpx258PqSNAyrmDJbo/TnK
# DATA ljt2fNxjx+648U/1uPFJ8FrPwTFkdt9pf9dyypYIWJl4zz2qPIev9bwcXn6hzvCdBXArfdz6lElbmcpwUsSW5UhNDpGrnE6wIJBn
# DATA FAF5pbrC2bVbufImT/BZV07r0HH1gVDoQOnNyUFYU332fXqiFe3jtHOwM+lBvk/LzvUhJxp1oYbfmYy4gvqjvpa+V2fi+d06Attk
# DATA W4dk/PK2WR0FTQmj7OlikbTFWpxj+Ik83pwilgmWWnucNujZcVvAicpWgBd3yCabjFpGePIlOeppheHsKmdXLRFrsyuX03Vxui7H
# DATA NaiW4LbORu/l14NoH92/KA60/B3RWIPkhhrYSucvJ3YKdC1egVA7QPS1lDY8T/Tp6nsD6C0ESobFuMW89Qc7GxkS0IDXgRLQjgrC
# DATA dFP6ewqHRImmLhl6Mv2Q5W2LBfTZ1LPIlhwxjrCXM/lxgZy9+CEA9LEFW4bY4kqD/fqR8dXPJ/2qvpBAuJrFeXG2Y4ztOnaUl0SY
# DATA PSVMaYK7OtGxQUYdEVf1qImq/p7ChS2NZ2lJLDMEJbW+hNaqnC6iRs5V3aIkoVJdeVX2mqp4qjVGW8s3uSS9S7gnKaDxVzFbL0oQ
# DATA T0eBsphNVvu2hY+UPr1CvPho9kYf8BpcT3YD5gbNWinBw1BUXHi4Q4+jXVAfT6gXglZ5PNnZCdgDDWAEr0yoDiIaAWMBqBKrSmMU
# DATA 5kAHAFT0NI1LGGjsG1ftDgIqZMpP2B9PRQM9GCgE+zuGEQsFKhinsYzknbDL0ilj0R9iZWdPbeUNTHxEjh7SRByNOepEiSQRyyrD
# DATA 04jIeP6Q6hwGuFXZTj8RYzc1gjlz15m7C83dGdPGWbzO4l1swj4nCodXWX0PmsVdDDLhgGXM5vOdNF82kQIcBf2QER25Rap7bwpT
# DATA cGa4YWGznUnYAc4wGRgpNGqvnQkAhDy8ZU3gNDRhRuDQ3EfjumGaat8TD/XvMScA49kooqHDH+sxl+3wPjXwCUwoZQf4O6NA4ytn
# DATA h0ylf0ghdWioNsmBq2pm4GRpQIjLsOcoYE04zx+jQlOEL9vUdk2GDB7y9ii8IwTUgHJ9wYxAJN6iPd7fpBicmp871AwvbOQUUMjD
# DATA YNQOsd8xBUGVDOeCYdE+S6hQeckK3lvgbHE3yt40hnbtwubiuxhgAmIl3HXXgzH3s5wMmDb+OONvw8E1E1mPDzeAfbIsjdtajtL0
# DATA 9zqR72PWptk7qu+HymRONPc0mAiPYP2RCroX55iOERtqpza6xEy6icDQUx7ABFMbLXlkGfGQ1IKlHXTCti8lqPCZyMqZmm5hzoKH
# DATA NOb1Dpal8iYfKTbmF+NLdDq3eaenOiQyGeXgSWaF8b4ufp4+KlJOCPiJMl8HUOJT4p8WI42TlFaqLHh3guABU0LglmWeB/KSb1XV
# DATA QitWpvgy7D8VbgjUFuEg1o5iP+ZJrb8ziOIwniFzsCF2lM733Yg6Js7PpAviVnNsUjT7tPUYdCqcaMvNrRoD3NvsxD4DMvQNVF+9
# DATA D4aaq4+qK/rveppyBpToqylnOdoslbfQZc+AFH09HPOsbETdFoQgBQqpmDXcc4rA5BnAom/15J3oIDm1SePiaVbnDEDR29QB6RaP
# DATA Xqpj9HW5SOEtGnVOmZ38U5+/WVwcemoc21ic/wIIzvSH6aPD301/OPzj9LF3+BkQNfT1MV1+cvjlLBnnXxh1868MtUnfPf2GKTke
# DATA /fT59Kvp48N/UKH8I7g4dO3Hw9/jCXrVl/TL9/TCb7zDv0+RdiyYjkPjvABkYQazGe1aYWTB8wukR062oQoXuMvd1j6g3PvKotoJ
# DATA WDH4ARzOghMea1YiQ0Z5EAVDcKe3nIBzPfC7/BaHv0nNMbm9nzf9xiqMs0PfSNKSbpHrTpfnYdlbMXKYG3mqN9o9GO/2TxN3w5ts
# DATA adqzixrf4RkBkHu8FRO3O+zNkSV26rwbTHKjFuaYXM+0xxo7RdR0mPuXnj/qq6WpZPIZxuKKntlDLfrpbNvKXIJKi3oxTOvIdIGD
# DATA ewZ/s7z+LTY+knb0rLA3y2PuiDdu0D7GoK3BNscbq18OX/D5jNOnOUyvNEqvPkif/Rgt1c8k2gzI59cWzoJUY9IjhOQ4mxC9/yLZ
# DATA xMD2xG7U1zAYq0xkpksDGgY7v8MJZQq6IVLEirHcjiYjYVMk46tOuBxlp5cgrzj41bg1aoqfGoN941zXo7cZt2O6sTPpBXpLJC9h
# DATA wavoxcOgHQZxzsQ/YRcrR2svFNdrQJ2t3w3GBylXoEoH43QZE80o4LYkKp0gB6hxgBoHqDl9QM3RA8dKc45V7Nfzsb9PYn4/rfXt
# DATA YDQORuNgNA5G42A0DkbjYDQORuNgNA5G42A0DkbjYDQORuNgNA5G42A0DkbjYDQORuNgNA5G42A0DkbjYDQORuNgNA5G8/zAaCrV
# DATA oNI5KYym1K29UDAas9x8XBJNpdz0KtXiLuNnylWvVK28XamV09nR7jaLtVn+SZUSUKk2flMqV7L8k2qtXW3O459wKaWDqWxueuVq
# DATA +d+VNsteuVykPw1vs/Rxqdb0ml6pUfZKtRK9q+KVNysfl0v1fKlCZQhiTjVfqtMtefpGN1XpphI9UP135U16tOxVKIRK8+MSvMhV
# DATA r0r3VOqpdFWD5ma9OAuIkQjlyYTPl0rNfqlK+YIX1YvA82TS2t7sbPrteWlV6BkqxZDMD8WuqRZrCbumulm0KnBVvhzMqc2ddlBv
# DATA d0/AjuGKbNgx3CYsdky13PBrlSPZMa1up1tPsWMoPs12y2LHVOqbHJCwY6iT2PQDix1Tq7Uq1TNnx/SoFRwJj4HT6NPkVkN5sTgu
# DATA KnWzjj127pXp3+YvbXO7weZDEuTRSBqbN8Ob7WRv8bxYGNdVYc76KVlYHpYqvbr8SYXmKYvGAGV4FDW9f4pcI0WcSTGFCcvIq8kf
# DATA 4xqVZDdhXNn+nJK1xqOCaFCGleiP+ldbmGy98oC4kFazQlmmsy49x56bEQsDclAbB7VxUBsHtXFQGwe1cVAbB7VxUBsHtXFQGwe1
# DATA ecmgNtog1NI+axuvLRvNGH6je30+daEey6EPnNu1eiplVqXauhLq3muLTeKNy2jnH65dTdS8cFjFknMZUA4rTRdMX9PMGnPywZ0b
# DATA dueGrZMv7vSwOz181OnhhVqTZ3Kq+HXUXCjNJYGbk8XPVH/iFPTSoTWHN+8HwQM+4Sht9oRac8nYcnpqc0HQU6rcLVkloQzR6oPK
# DATA 0X0GsnP6vLECtw2pVDsjaM95NEcKegdnoDn3zgCHmsfSw8ZKKRv2cjcRqD4D8bm77PpSaSQTRPXmVCdo7MhD/bpzBrpzt+UoMXyA
# DATA ZMqpJBu4wJmUK2vP3cRZa98I0KHlyQgHk4XMS+yFmoyCU1afUx4YIx2faDKmlAGSw606IebULGUYuoBxqgexJOoTUXiRgIeEauaw
# DATA PvdGhURdszM60BmdoBr83j64hf2AJeRxCxaqyNDo9Qre9bBrmkMOuIfebFtUKqoDRGXk7dKPowALVr0DeZK7l30/luhoopBSq+U6
# DATA KCrvaGzw5op2NU0qsMS+pwKg1kHRlPqyC9/gSJ2Ih04mPdqlIWWRZIDOFX3cn7rJAU6+8zYDGk9YCoBG6qzET2akuh3gOKA6xS2T
# DATA VrlDxp2jZeNf8JPHDjnp7PfEfncW+0/OYj8uUvIZ6gDxYr5ZiF7OkXwzZPlzBUeB6PnA4728SyCS5ywf9NzLaZwFHzIROTptOKQt
# DATA B3VSMqS1SUFPm27jWJWpDjLxY+EUJTxVzhQkdjVIKardjSA2vj6Sh0EDwBY6DW3c9nqTfjiIJjRFNDbRgCp5BBGbYdDrQdodY+iu
# DATA Ulwn+2tQ8N5tidw+GSbYdA0tpV0ySRXmgHk2+u12NN6CgcZ3cWJ0LG7CLqIgKHZUeanWWGYXm3x8fiTgbQgHMbTU/Zgl1KWFaI3n
# DATA PiSsR8vez25oL/Xut6QFxWRexrwUXfBuRPFY238iLsTsHx3ry8ggaV9gL0H5hvpr2AYQtqduhKo6y4ZkY/JTF4mxegZnqzlbzR4Z
# DATA nLP15XW2LmZOPksJxxu8WKnrsxJg46PXFpQS0noMR9iDdpu0n8R5k2M3AgMm2YmmHYcF71YiBohTOKLSZtA+XIbsNPAt/UD2abLv
# DATA oBu2vZim+23jWWnxVrJEM1A0F1fUgOQUi+Mjafyy1oeYDPzRSPOE+HAJ3gOvzxwjUZ1xnKVdqnVuVFL+pPxkypOlf0yAiOYK5ziw
# DATA IwGHI08r91PU61kpmEuANIvnXE3k86uyJUC93LrDdJT2U69G3GEm7jusPmPE7PX00mgIf2ikrLns7WQ3cKuK9hffs8NmDyOz+NPi
# DATA O1tsp7FG9kisFH3nRUlVkg8yHmtvoaxA234+DA1LXIVLbUbL8+mPOsYJzwv+4o5XOWjlQAYkxTuDTeuXpXSuQqMJ58S2SUA2xpKX
# DATA QzbYrkLEMRxByBT1PjFbYa/llSZnTiRG85iZaQ1SGsb6USdgP/4Y9iwMP23BCUrJdibCAWmkOgMWGtJG9tj7WxpwC7Z/dUVfqme2
# DATA ybGlkU6KyRotYQbAK5a7uRHRM5bTNWvLHqt4ksp3zBK6s7iEdDWWQrozZB9suoSoGXNHIh53YF+glblL9o+4QX1P6rqy+i12oFkD
# DATA wfOyCiJSqxHURzHlQOliB6OyUp6+bOwUPP8Fc2vVgrnlj3osKuv3+rpg7kRdhrEOaFRjzdR9TPJoBN1Jz80K3vZeFGJmTHlv3Po5
# DATA 2/XNpTKk/gWTs46aJWJ6+NTlYUf83Moj6XuPWR5/vbg8dC8u5fHXZLDMdGSTdnvSYzVZLAKqk4SqcejJqmLpUS/FKwk4j01DRsF7
# DATA m1rXQY6KkMyQKOyJynGfe7Go3xf5ZzIu+sISo59C5KBZL376gkpS9PwX0+1Vi+n2pNXK9mevs4i16s2CwUfRQdKDaTGugvd+SNPd
# DATA zoQ6+h1ZijLyyXpVKLHwwNSmvGr7E6HjPXVZ2NF+/juxN1ftxF4PRx3eMTCAA4gax8BqPLuieL076YedPBYKWWJclQePOjEb9pAW
# DATA GsMyf9/XXOpknd/m7aGETW9HIZHxpLZNQAsZ7qGnLqfZBJ2otNL2n2xjtO0/c0Xy/srNSG841BrcYvKLxc1L/wy19GnGguzQpawW
# DATA Ts+GifZCe7wSFlq8GwUpFNr/Nf3Xwy+mXx3+CawyYMzo8+fTx9O/TH+gv79iPNo3HsPOnky/O/zTLBjtvzBG7dH0O3r2zx79xQFO
# DATA n+QoxOnX9I3RZ/S/H6ePzUtskhrd9P30MT4pjtpfQEXD++W9P07/7fCPjor2AkC5zTYH3vIajfc1dtWQuSFeLOTVHM+MeJtVABNP
# DATA swAADYU7gWVkqAMQOAM60CHoBoroSvV4NOY9Y3iuK0tYxikAT8dSchqU5dEUxM53+DTb18ddxHnT07IFcnYINRot/F60kyC+eIch
# DATA vzzL4b7YDZNu+s1wbOE7To+hBlNandtADY1kBOdscPi0o0vr1PlpNwQD7rXIuMCOLpr379K4Y6aXOW1kxREOQyEjYcgimeju1J5W
# DATA zG8UafwhVFKCpHNina8c2VSyHDkK2LPIhFl9TKBPRSR4DQxW4xm22vJ6udiIybSyZwVYWx59B1hz4/8pj/8awnaCYf+lWN47nyH/
# DATA 1Ef8lQb8Y4z3Zz/cS0VMJ92M8s9X8zkLbls64TxIcoYY6JhJdesAIeXkDONoIq+SuI4F6BT3fSx8maU3T/qlVhDDpRWMsDTJiaaB
# DATA Ojm2oKLXCbuG7UbJPvAUyWRFZttImWu8rQZHVsigYL9E0H6AsUmhybiOCfeKTw3zTiChzYUx76GKx0Lj4qXZIB6LqYB8SSyHy4pi
# DATA BnrWeEIh9P3BpIvPI9tIUJ5X+AnYphkd5KOBQ7Y5ZJtDtp0hsm2F0WWlic4qJvE52vUnMeuf1qp34DYHbnPgNgduc+A2B25z4DYH
# DATA bnPgNgduc+A2B25z4DYHbnPgNgduc+A2B25z4DYHbnPgNgduc+A2B25z4DYHbnPgNgdue27AbaVapV0pnhTcVuvWg+4LBG5Lrzkf
# DATA l95GtqpXqTY/rtfylbrXrORLlXKP/imXvWbNKxXpl4pXKtOner5c6dU3vVrd2yx65cbHlSpd9So1r1p+u1Ta/DjfzFcaXrmUr2Wy
# DATA NNjsljutDPSs1KjWK9V50LPN2ZIrF71qsbZba5T3KvW36Wv6BSasNIWtTCko12teo5QvNfv5asOrNr1GMV9q0JeqV6179SZ9WTli
# DATA pcpMzGolQOIaH+crVKh55EX9BgWA2PYqdCFFi+OdnOmXBd1GfQHmTlXgdjjiE3YPpdKXE/RbqcEgOVY1qKdbgAmWAoBh48nTRWSt
# DATA Jw83m+lq3+3yd93/shwqi79WmlRvKIxjYuO4GWlsnLRICxsX1JrVWi2NjaObquV6ChuXAckJNm6zs5lg46rteq3WSLBxnXa71U2w
# DATA cZudymYxOHNsHNrf0di4ijYKxCTQzyzgxyGZGf9i7Zdelf5U6E+99ks7iAwv7p0+TSXGOWwFRny9m6zYQV/tmNvTpFqxeDnrzBN3
# DATA T665t5/jVbIFK2IqGoBXDT9ZdamgULXywquM0sF4ej9FyiAx8yXsqtYuPu3lTDPtVCaV6U+ppk1+9hWFY7Kw2imQnfZhU79cnsHP
# DATA FRfz5Uzu5+wcWGKKHJFAthIcR85x5BxHznHkHEfOceQcR85x5BxHznHkHEfOceReMo6csjjSHUA4oPC3YO99uCZtjhJ+Qb5DEYaz
# DATA gU3MD9fu+iOo0PIjntyM5nWBL1C1eBOb6dZLGxcoN9r9wof032DbOiV+7b30MTx++IY/3i3wDH2dw/lVqVBDCMnxvjmHxhPlW0hx
# DATA mW5fo+aSYyvuELU7RL3KIWr7aJM7S+3OUi/RS362Z6zlaHBOn/Wdc9L6tjkXKHUkl1ZWM4d65cCqEmThs8Swo/eVDrOc5A1YZT85
# DATA PDn0DzCZlsOT0FoZWCcnV9ZAflNUj1vCiOqAQIVX+6ZDR0fgdI9X0T1u+/HEV7Jp+LT4TnSplLW49X35uPhe6mA7UcQZ/a58fBEU
# DATA kJO8OKYI4tXFIog6V0UEkYyy0UEHOkT+YM+PEwVEnJyk5gUF8XbEbpPJcIhzz9hogMNo3khkIWPgOeQwO3vBqKkFBY9adYijwxkd
# DATA HR4PO6ODnBf48QE3lKfXPcyk4dwkKq36d3qKoaYmK51q2A6jCczIpGzak3iXam7AIrk4gy5HqH2Rq2YzJzEiYFXCLhEMAwpqF9w7
# DATA dBGJMrXSc+Dj4RPUD/hLW5p58lTq1EkCXoCCeX/lgrlNVT0Pt8oBNMAt5VA+2JyjEhkG3Hq42egGwiAZFBz1R2g4WjcU5wihWAXF
# DATA 8GDItiEy3FLTEMEBrG3J+Bb2dqMJS48+vb5rKinnVkon7tyur9q53QixcwYaHpORpYxMExSa82FX4Dga6qbTDUd9iJNOhp4qmGjE
# DATA Emz8q6iX7FOiRlFLurtRgK+sGzYZ7JJRBXUDW8bjaYokFfNzKxFrkDxmkdxdXCRmuJUyuTvyw57opfhk1phCoe9jGCew3yLJ4Q5N
# DATA e2DkoWoaGubIV81BaVYDJqyVZhIliUTsTURYegei9vbUBZOO/vPfVu6s2lbelzkpTVDDIVVhUzCo3bCcaeouW4RgWPMwztNRqHoM
# DATA Yx7vMc0HjxYbcxUyKxbNcCUSPmZRa5QuPKdPXRSZGL+8Wsc/BTkR/bjzbjnv1ireLbuKOe+W826t7MVa6AQ7G+8WC28ZAJ7v7USR
# DATA iOJp39Zzq1+7zPeFIw2e7QGbcWoJ3RQbRtQ+ZH0t5W1SyzOMZhpg/z1PVNVC6Xq7v6HcXrphyqQUpSihmudNV5ZcMa6fMu+uHaHn
# DATA Ri/WD9lAKvO26r7PW171Rt5gyFuvC6XFDjJeQUItj1S5Do1qWdpPpm40MdMPzrimSorQC7unc8kree3+Yj9WqVBjBwIFFgYjurtQ
# DATA S90/48tSFpZxFMqmGwrimpYvzPSylpmE8qMo8OEinSrZfWWbLsklaeKhmGdDGg/HsiH9ogTxlAaQGCkYjKz2ZqtZ3h2J+1WIsegH
# DATA ZlSie6zXONBe2pzMGNiGY6+Iv+OHsusKW+IFI0Wzh4JnIHdJPS14XGg5HvwsIAuLVyZBQq8y1tYxXgdrahgOBGOFMMkiNhKEWFBk
# DATA BTUcGoOkY+tAmqcI8/lQoLRXEePJDvi1vFMgWcNU09aBlqBkvcpEdnLCFuqBZ7YL6D1xQ7ZhNF4WWf2TNzyTocaZns70XMX0dLbm
# DATA T9fWXGgdPodq1Xyiw5wumDXDepYZ+hbMTo4VKOSjQJYJY22FJg+x7BJ3vs+fuvXzL/nKf8s5nSuvUg+abVj6WCDCNUe4mnLCzzqz
# DATA KBf8Hn/LinBnj+tJM21HmCzIuw4GbTG/jf7VlXdnTvvxDj4qxBlxc+sp/sJpWUFYPDm2ou2xDBx83z/g6Qv0nI1hdpWX7GRyNDCL
# DATA gvAn7lBIwwNZXpS5E2iEQ3+P5y4F7zYvZ421BaXuUfYZaiVcxuKMY4Mnu9blYz2crDRN61ipEmQr07WHwx5CjcOH2Louy5BSvc8d
# DATA 7nHuxlOCKaMKtRf0dibUXdiwsn85/OLwd4wlA0HsCX/+Dugyxob9GUQx/HL4xSyl7H8zP34+/Xb6BCiyf+MLfz78YvodLuW86dfT
# DATA R4wi+x2+4wZ+3eEf6A9AZF/R6wAye0I/P2KU2bcUwA/47fAzCuZbwMoOP/MojEd04Q+4CDSaY5e9ENYh0sZTL/hDWK5c195LIJL6
# DATA owdY5fMHQQ5uD5qVjnjuOPRl+oNBhmaoOCrNa0jQy/AmAw6MtcknYY/ZqNSifd7NSRNLfyyQ1ABb9akzW0otE5h0IAOlg5bZtqLV
# DATA YZw3uixTKmdHLuuEcg4zNne+oa5wRZ2hl2HcM3dSpZOaODpleBnP88OYNyCgOfDOMB1VRzBbrdROnWKmO5tuyM/5PXEqxe3doDOR
# DATA bSI9YcdD8oNBztyLeaz26pVq+X44gK3t96hyYx/JZe3pZXSGWGGjgAIWkEI4QBcsZqCyjKRN9gy+edWqudjESTe1Z4UvWxp5Ry9z
# DATA FsCpWQCaW3b8gf+lcBCd56B/2mP+SkP+MUf8Mx/wpT6mEm/Ty56L5nMW3LJUir1A5uixeKSYwu1F3fS+Pc6G8S7FcofXTdDoQuzT
# DATA NJYRI476/pATLq9FHyXnBqh2grqEpRaNTJL9mjziSr33jDhbvCK2jHNOVQqPsmOC18mADyCIuMv2tWFARRAjll4HB37w8geDaF9O
# DATA R3TU5lJgo4YBF/VuNBmB/cUMqrAV9pBVsO4YtELjEeOmYCyIBgLjucwZAgVyGkTz4VOOY+Y4Zo5jdoYcsxVHmpWmPCvYx+dn4p/E
# DATA wn9KA9+BzBzIzIHMHMjMgcwcyMyBzBzIzIHMHMjMgcwcyMyBzBzIzIHMHMjMgcwcyMyBzBzIzIHMHMjMgcwcyMyBzBzIzIHMHMjs
# DATA uQGZlZvVWqN8UpBZt+t3iy8QyCy14nxcjlmd8qRY3a3Xm3uVzerb9SyCrBzU293ZnCyWKCuru7Vmgz9XABlTn6uUsfy52fRKlMOV
# DATA arFfahbz9K/6XNKfM1AvyvlOtzwP6lVuzkShXKMoFMsflxpFr1QCgs0rl4rjEtzGzaPwYY2a32jPfVOtPoNDKzVq4JJ5lXJ+s+qV
# DATA 6lVA0Eo1yrhShclv1c0jXteu1FvzaWUWRC2P6YAPgX6p0d7mHJAZxSUBmVGkDMhMcGxJC6hWuo3yyvlbn/OqcrGRvKpSKp3hqypC
# DATA ZJNXleuNM3xVrWynqlk8w1fVGUWnU1U55Qw8FlSOuzQNlZPe0YLKVcv1SrOThsplEXJzoXJBKWh0aglUrtapB82Kgcq16+2gbUHl
# DATA KvTeZv3MoXKyuzAvywx6mKvwDMLTq1PGdmmK+Wc/k4XCvRVQZx76uVn6W3Ue/Q3+z8befq4u/k8Vct9fDfJWaCxza+rpWRJodoHE
# DATA Nu91+cx4NlXJpMJhcYsFrq9ftJrUgXXSTq/j2WEeu2uxVLUYDGdl1RJ7bibO6WnRGVqHjjHnGHOOMecYc44x5xhzjjHnGHOOMecY
# DATA c44x5xhzLxljDnUhHNMMf+RDi50q2GWDndu68omZkwzjLa4n0kvx+WVcvWe1fGn4W1dMsw+76z/jR1XD3fhEcem0chHEUOXMFyOO
# DATA htxVi3F5+VN5dWcia89bdkC/EtwdLiUIPObSyZKOfW++tPGrUu1CqYbo6NCuSACtCc0XUagmZiw3ywq0gyDoxODd6WcAyRMZgtho
# DATA L3WDfelAhnIqT8S+6BKfYEwlBxmNU4xb2qwf4cWSVbL4tM4Tuo2CLD6sr/u5vVxIheBfUIb23sav1kNqGsXX6sVLpY1cEZu+uNVj
# DATA /Wmrv3VlvX9lq1StFl/7cO0mVUk+YsmhIoOU4cP51O1FNGftX6wXN35Zrm7QDKzDelbr5dyHa0XczY/pZ/q/pBtnb7qc1BzJctSA
# DATA 9ZhjraoOnEdbHL91pJ5Rg//js39GxsaXceXC1rzCXA9fTRfia6XapaLOTQ718qcbhY+icEDPMrhQIq0+Xpjzym44CONdJYpaqunC
# DATA xGlZcbgIAPG9AVQmBAeA5xl6uJ6pMHldKzbsakGNh+uRyZYNiuRlLnAqibyeVdDzry0zGbnlofEk4XyCcZCMIXXoWCtnaHELHbJm
# DATA K+pKZ+ZdFLg+D10YP0Q/Y8VRwr6jw9QP0YCLsAymUR9Ec0oRTiliuVKEdUzR6UU4vYhj60Us1Ck9Ex2JW5Nx0gB415bW9JSR3YhK
# DATA PI8yRuehYy/Gisi4j8SKySjX41KiW6/vN52XuWCE3oubl9SCuRKuX6BHrwZcVqQf42Q585CMsPe6GnmPUtI3wZgoJVcSJf1qcZ6U
# DATA fsWW0m+Ui7aWfqm2WErfMmgQfY44TUxoVsXVKi2nn7rZyjc7iBm1fI7ZlUpR2x+LdfWrHM9q7eg76xxmfU6YM9r7+gAjpZsPIl5R
# DATA RrEwg9By6Fb5ReVMwoTCpIHTlC437fjIZkKqnG4k4xkPhTIBuWJdzhTI6bz2NsZNbvH2W5OrZ/NSOfjo0UA7om4i9eb0TwneMymX
# DATA hXQE6ckUJuDFRSJch39PpG6UsaIteVs5w2jMdGhCZ9n9qU6ezSAIf6RuUQK8VIVZewaSM6ynwXADFnPQDIJFGjRp0RmbCjbL/5rP
# DATA CZMMTM0fMBLqFQr2bekhyIaAHck3ePHFLdIWhpuXuHnJEfOSlP3ppiZuanL0jOOZStxhjEcF15FA5vQSlbs3zUREgAes+WTaGpWe
# DATA H7PIFQSnWHPMiFDlRDmt74vj0gihabGG7OQig17ANhsb+y08WtsAE77m+yI8FwhhFq5StG9KDFXo2ExpmNFF2RN/PEE0d/i3SXxA
# DATA Y+6AmV6UQOkscgpCJNMjPdAykJ67i/iBDnS4G42jnZE/5KF6GMCQVvK+4YilxySJ6WFv7DNW+UY0EmVdNdZl4aaCSLYsP0mtmCMW
# DATA Do07MvRt+wqDjG2CqmMT3z1Wp/aBIoc+3Lbw0wQrsevbeFF4yEEYYKk1+PaWxT7ssFW3NPJZ41FSYJACAhGODUEYKv5jA3pusyCc
# DATA wl9oTeJEWU9YtmntPVUsLXTZwiewem1f6u+SNG1jh/0gArk1mywxE9Lc2BlVRVORySy8Bfe+ejPylcy2XRB8FbJBsoB/ALAXkcda
# DATA cptl22DU5FCJBpIUMO/gvY0mscoPFXBI+bC9F4UdlqRmlTYAFCRLaYCKmBjbh9TakE+68e6U+VN6jvWvhSaiHOAyKdNxxoJ6Srg6
# DATA 6sosDDp0/X7UkcaNwuPLpqw8fXgu6nbhU9dlpzWspQxz3nDSIgvFeo7157gR+h1YQN6I67BUVhq7GF7Mr/RAYqdBhyztmNrksiTe
# DATA ARpcwb3GGESsJIJQJi+kniGEthd1d5TWIT3fnfR6B4q3omLKbpyYK6qku58iFbKyoPQJ+7uRUkekDhI7QamIR7toh1Jg6OOziFox
# DATA TH969rSjhTlbemU1aGc6/6RN5+Oywp6xOrS95385LOwuRgINu2SjSur7clrY86Mm/UJIqh5FkEj2/WuW12lCxdIK2afNFMsqjs9F
# DATA iin3G6t5o1B5FxoZQVIjYjFrop7tDg2GuhO7cpO1S4QrRlMV1ieWSRO9j37HPW+GieWM3gOS2QPY5UIjo3qT3CszE9i0sjs9goUX
# DATA QorsQN10Meotap5iL8PORfXlqYU/z8G4FBMCV6whOc/oj8MCYxni4Qg1Og5MMxMFZ99MV2WbDRn2fdxFdm7K20o2N0SLbS10trR5
# DATA Cik5NWFRcm3gzqyzzdh6PzUrL8Ga7QctJX5tU83+8/Tx9F/zh7+f/siUsSfTH6Z/ZroYfTr8u8PPpo9swtjhF7gyCzj7r7g8/Yoe
# DATA fsyIsscefXlEF5/Q5R9AJpt+5fE9XzPj7B/kvsMvFcjsEUhq9IIv6N8vFciM4/MIcTr8ezDQmHf25+mP9APd/41jm70otqw0cjQ8
# DATA Lb7OS1aGvIl1IJrDibo4T94iCm6MVo84Uit/DyqLzJAX71G0x14ef5R4lSwSIprHUpTZ29loOJyZbdMmHcV508zmFMzZEc3EpxLP
# DATA vFxdz94uOwjM3beDmEagtgzYXEinjDYT95Lo+cO1Igt/TC1wYLOVCu/UuWbbnqV3nswMTA3gRWMI6Ux6TOFoHeBvnKZQ7jlQTySC
# DATA YudcvfUe3S+a5jnNqdD7XQzEhO2fPcCLPbrYm+GZrVgzF9s4s83uWdHNVkyK45w5a+Ck1oDGmp3MCHgpnFrnaACcxfi/0vB/vNH/
# DATA HAd/qZ8zOWGhzp5JCzoLstlMIpluRlkVz0YLjDNZVvaoeqKmXhLQU857++7dW3dy6mCpWhnmkuE9oyOyH3hlh5OBERpOiYSmNFJl
# DATA qT0POk/1mLsq3sxUBY/yGspgaQMAKQvbwJwlRkAacDYcBR34RtJGgW0M5LiZorPwYGAM2so8YKsAHCoxDwU5xfGP6TUJ3YydKvFB
# DATA zEcp1T0txzdzfDPHNztTvtlqY81KE59jGcjna/GfxOA/NXvfYc8c9sxhzxz2zGHPHPbMYc8c9sxhzxz2zGHPHPbMYc8c9sxhzxz2
# DATA zGHPHPbMYc8c9sxhzxz2zGHPHPbMYc8c9sxhzxz27PnBnm1WN+v1k2LPKt1Gt/UCYc9m1p9XQp9x5qrMY0qY0Laq5dRhsVK9nM71
# DATA irCcJNubqYzrNINa0M3gmyrNWk1QXVl8U1Wy2IqHvFviIeyrJB6V7KG1chKNahZbN48XVrd4YaXNpmFQpQhpv6h2mqVGZbbmNKtU
# DATA dZq7Uues5Pn11mbbn8tPW5a8spDSzih5ZYvmtXLy6KFTS15FGF9nlLyKevpYyaOHnip5lXL5uWgklUrz7BpJpV56ikZSaRafupHY
# DATA yTv1RpJK3rEbCZL3tI3ETt6pN5JU8o7dSJC8p20ktVLzuWgktUr17BoJxeIpGkmtUX/qRmIn79QbSSp5x24kSN7TNhI7eafeSFLJ
# DATA O3YjQfJO1khsYGux6VVrtb1qfbeyWd3LV+v9fGmz7lXre5WjAKqLG8FJaJhs6RoaJhvNFg2z0qqXm7WT0DCLgd8tWTTMSj1oVg0N
# DATA s9Vudzpti4ZZqsnPZ0vDVJt5ZXZnOXvUspvhY/KEnUx026m2yWvsc7ZNpELF/HX2nuxWhdklsyYvmRWa2Coji2apUNWC+dKQ67x6
# DATA ln5MzwLnbzZM7qbZ5M7I76fW6I5KrnpmzvL87A16pX4mz2fvTryIi3ZIyotKUkTiCpgJBEsNs6hPVe3SywWbm5vwwBwP3skeozmp
# DATA YrfhjO95drvQQu6no3U6WqejdTpap6N1Olqno3U6WqejdTpap6N1Olqno3WeAq1zFs25E7YUQBGrczA9FRxTM6joysVSsdqsNeqX
# DATA U3MW9RgfHsZjGnFIhvlkiCsXSniyXL2s2JjX1DF26AcMxru9A8O5YkQixYTq1ZvY379eZiziW+HrglS8jnPmckp52JvEHgSbPfUi
# DATA flZFadHz21659kvztkRoR+allAd7AaM61ykOv8Ia/8a8kGyWoXXO1AnCOEGYlCDM7KFjpw7j1GFOrg6zUEn5LFVjdGcNOQhpLygu
# DATA VnLARhveeWNJyDw/OmbnATSUoZJBHzKQsQoHXz0CJKifTHXzcQrZBjfCXJBgyeII8k1FfafBCS6mCZrhHCxB9Rlhs2DJEIOiToK3
# DATA /uvw9aOAiFZwJin2NZOa2tFpKR8jGWJtoAeAV1RMgvUbR8dXP2ciay5YMV0t01eMqbaDuJ1CKBGSI4ndQl3XMAyOqi5JIAl4Mrlk
# DATA ot44Kub1JbFeCPkzXYCeMvF4qAr5hYf+zSP9GQsxML0feiaqY8Ly4ObRMfI6sA24SP0+zwF4eYYFYdRcs02TKlaLZqgJ9kbS9Cbn
# DATA 7e9S5SPjcLQTWKGp3O12qa9tTUbwbeA5mlyNAig0hWMt8KP81TLziFmWm5WYqEodiIHMOph2PSt4V6M+u8Wo68spsZ5Bx+g/JaJL
# DATA ajLXkSf8kdJFSmyZBDLbp3hNRuxbVeJDK1ADf2pKMY554iYCCyYCzuZ/KWz+45JOnhelSHunxHLkyVshj5iilsjr0RCJG7BqD7Wt
# DATA frCUffLs5CVfLHW1o9SlM3s8zgJ8Miugedrwk3k6pHMBKKmy01tipCLPA/y9CXtemwhz72BVz6V3vC6mtTE0jin3rch/jKsMWXAQ
# DATA IBHR+PTHUubK3FwFh3knmXZrvOLbd29cz3lX79zJqXFY2gsPC0rLHRBLmReJ0OIQKqG+VlJlpUYqBSP7GcbJvEGD7biBh2MM20uI
# DATA inekM5ANb8thkdtWJFQl1inahhLoQMmjcuw4QZSwTgCaXzBoQxF0EFD8lB5rjmovVdddvcwm8qxpVdalaM50B3JE1LXgrFjTOtoK
# DATA psgGtzpgGIg/Q2CkMPtF+54N6NGBksRUsSx4tzSnBjHn1THdkfle1w97k9EymuVtCQYLV4t4li+RBW73184Gdzb4XBtcVRLniXee
# DATA +JR1t9B4f37027lOY6ROcM6+J55C44EXX00YY+NexINkWnxcu9Cz9LPJEDjBgvcb7BE/MIgWuqMzaUNEpo+x2EgbG387E43Z3llZ
# DATA yD3RLZDmia9XXtWG3x0c8+aGDf2KWAGwZcah+oJXLxorcSy993iEjyLMjVe1xVlP9sYoojGYGvbu3BvekzG9C2rzglveh8mGVIoW
# DATA N4tN49aLeOdF/X4ZjLLRUIaqMuCMxcNv6lx5Q21O5Bqc8zCsdKnvj6jMGPtJVW3c4TvVGJHzZDDOaaltcO6AKY53JdyOitaCeNzw
# DATA B1SnOrYtaCKznUjgZ36XKNimm7G/qERHAcS7efFAW15HR+Q34Wg8gaI6S4lbcVAFzGYe11aWlOc+ZRT1TGTeHbKiirmBKnkwZpX0
# DATA IQ+elEG9nq7qsRWfi6qgLqpKt4BLvxz7fUfbeUnei8nnd/o06OtZTsL20UriitQe70aTXofbpZizA1h+2HiOqZWoq0sBFzy2L8kC
# DATA 7kUHfQ6C7HPwrH2Iw1sy9GDRfxS1eOBUEvOTAbMQVUjLgOCDaF/plWvT2R/v6ui/P2I5e6r3HoubiLOb11u035idzmSNUzC+9jaj
# DATA l6LOju/BD8xITWxcIKEAWdS388QIpPoBHOw0nAcDfW9HsR6TtcFlibkhrmiVHl/E8+FXN+595VlHxPR6RsJV2A16Q9WfyYKn1Rex
# DATA DD4NlFEKqjAM/AcoYekxUfewZtkJ+niBPcNSYAUKReaDjIVHK7CnZsqOscHnZv0T9TPsr8gQ/2nZ9p9+eu/TDwdrr/zVT/0/yvqg
# DATA dx8dRjiYAKo6PDj1d2Dtsl6t/pVaN878WyrWauW/Kib//VWxVGoU63/lFc8jAyZoc/T6v3o5//v5z39+eyKEiDZ1IGGHxxlUirWY
# DATA 9yLnGfuRVBDv6vV3qNfgZU5q31Gvw0v49ECBwnpFpFLItt3hwzb6+0dkH+rPUfwKj17o9Hthy1OXb9FXfcvIPBhPWso/o6/gSBaG
# DATA A/19QqbLK6+8f3v71q1rt7GBem1t7RU+Y/OK2mDZlX3V7Gxap8lkJ7jUjdc2eDcjToasgcF3kXrFi6D6Xmz3QprBrF1+RbZad+MC
# DATA 8gFuvjsHg/Y6Hsp5azRfb65ZO1DX2CmUR+j5JLfWNja0f6kQPAzH66WNy69k932mo8bnyO6rh+gN1DvuD/jNSUBBG7mV8z5QkZn/
# DATA 7nu5VzzP+2Qsp0gulXi7Q67vP3x90sXex1K90qzmHpCVeSfcGfi9S2t33nnr1+9cv76Wi8edMLr0wRpdp+FhLbc2DIf4R32/9+mG
# DATA yh61MTUYjWjo+e1v9UbVmAO0L/BiuWx8XZwlsod4K3VaSz/fwVgwjtSxCpX/Ohr84GtcUAf8EhyMwut/JoeHCmF8x+8G75BdtIND
# DATA Cri9gPy6ipXsDdyZuea96hXnXb7Cp23mpkFfUXHdhyGzruKbfSPdn5zaygblffoKKvErr9AUGm7K+0w3Wg8H8ZBG4ftS6Dz537iE
# DATA IkYW8Ao6LsEG4A8FtiZiTKHW1/JrG/ihFwzW5UFKSK1UxjU8OQoK2E/A24jXR2sfbOf/g5//22J+837h4qX/KX/vwlr6hfhv5GMq
# DATA 9xsk7BqKf33tncEeTvtYPQk/s7bBz6iBeItbeioxGzoRcgtXlnWq+eP7OKlLMa16v/KwoVf9szwOHK4XPGyTrRvLRFLFAPbmqIPe
# DATA AP1RgXc/rKt3ourcx/7q9Y2NVJ7GFNOxP2ijKvLjOQ+nB0x2qqsbVO280kq5o6a6CmMajFTs9PUtHc8PivfkB30j9nzLTXwoce2d
# DATA DhXLmno8GOyFo2jQV3vD7ftoOtcNd+jeTz7dkCvXBntyJMhOarYS+Pku1YB7n9Srn9LNJhYbutJYWWO9PJM91i8bqvE8TSbhNLQc
# DATA cOGvmKxLpxEO7BxIXjFbjHx/DkdvOZJrZOfhaQmGL4yyFx4Wi5lLW2tqz4pcS943P1nvDeLJEMMVzS6saKpE4T8+7XmfUiY9Be8Y
# DATA XKfX5LzSRjYx81vr/XtWs733K3oSp1aPipnOcLv60HNWzDjLCzQ8BoOOOoBq2uukv45Cxi0FmmxQ98bn/FD2WIeg7OGnUfLlWn2F
# DATA 5nvNisa8JvwLrC3BseH1Fcfrjaj9AKdr8A9VPnpwdMDTp5zMl9tcH3GSAQWHTllgemT6F1SQ2IFFfa+i5cGWwZyW6X1qkeiy0M/g
# DATA ktIzf/igWTIU08V418f+K2mupvfbosgOAr4ojixluhTuBrBd/NHBGywsGI0OWNgufLi1Ri8e+O0JDpSbkRydN01VO/rmJAOp1O4r
# DATA K4Z7VXPLhnfRW7NrmnlE+8wjdCdRXAAhbF2Hk8OVd++/f/vdm9f/xvutfLt6+9r2Xf3l2r+/ej3nFSMgPUyYnDr6udvh0JJXUPe0
# DATA L5Gn5hb4/XRtlGtqoEQ7LHxEBbeuqswFbprJS8Z2wjmjFU9ty7ISC1Rg6x+kbsN/ax2uJegu5Sl8yot7Fx9NrheSXN/CYS9YlwX8
# DATA VaUBaTd4mJsNOp9XVYJD1/3VJTxtvvHbjDktL6dpdr4zioZb27C45oUb6yUask+3BhG9Zz+PmW8IkEwsoVDJ5VFya9yjmYLcmBsg
# DATA YklVBE9qm1eHolsNvsNM0QM+fsYXZWCng72Xg7NgPBkF92UL5dbd0UQdvNYfxfrcqhRzsm7K1zfSBWm1GFWo2oiCn2q4nr59teFK
# DATA h5npARe20NW6SbbEvJB9YmO7lxT7Qln02fpoVT82yiTT/fHYb+/acb03W2rz/ls1z0tLM12dzEsb2Kvn94edT0q5mlgGbEPD7hyM
# DATA 19U3ZSdfOkbeWpNMidRM9rIcQPIS82sXWz56me6Bom0ydjYaS4po1JfyoWGsHaSLx5Ns2rKefuPab26+d/36kSVHT9Isad6TSXnV
# DATA dHG9CQGHDTUDwEi0rqoxT4rQc+sZdmF7tMNe/Vv8iyo6uQ1n+e776neaA+SV0U1p0nsvrIqx6Bk24ec+QbfBFlMP8j94NFaRSHXY
# DATA fG5jPZnM4L6Cik/Ok288wVDW7ENgOL1r/A+EWE1Av1Aj/sU3Xvd42hkzGlR1tbbDuuC9i0Hb9xjd42H30gBeyrZH45M/JKMmY4jc
# DATA Yef+NczC1m5G2Med1Mi28aG3+Ho3HPWDzhrKiCra/fswB+6T/bblrd2/jxK7f39NIi3F95y6Ekc4xd4PzsLtt5r/r1yu18pZ/1+x
# DATA WKo4/995/PeLn12cxKOLrXBwkUwHb3gw3o0GlVd+/vOfs3CH8Gqx+CILY1hjwIovliuiYaCht3oD121tRnk82+r1qFtY4hXEMkW9
# DATA qr9hT5P+vOvH8A3qryH0wUaWE/Dk/kRZQTRfdyfjsGe+8RzCfIt7S7yQ/sh2QmadkuPdkRDwzAVqZCmPJUd5MupRjKXn1PGmazz5
# DATA o46FF088mb1PJK9lyExGTzUsUCZv2x0cTGqa83itAy4XUxpsqWMZZRR8FKj1P2SIzDpjLiwZdLAXbJ1mOHHi9JFOck509G3qUVbg
# DATA QWno52TctnwuPFfhOyy/C88fsbdzjfdCrW3o8GR+MGSPp5q8Y6/OlkxC5B1jnGkZ62kQB60nqfJTIYzvxwd9bHVZt0xCTuba9P+c
# DATA PvamX08fTf9t+uTw88M/Tr+iz4+n33uHf0cfvpl+5x3+/fTx4Wd07Wvv8PPpk+n3dMuP0+/odvzw+fTbwy8O/5F+4qe/w9dLHqYA
# DATA MMolBmpkU9GRI4uFPuzxdfkSK/ONp6L3I9to41XPLe3q6C5yZwRkNUg+dyb9Yax/CwZYorzvx+0wFNMCu8UwTG6V9TxL3CmdHM9r
# DATA WZhJzVX7D9Dyh2aCWkhmqGQVUOy3UimaM/RjYtjepSJbR/gouoUzR9xAM0ZEOV0ZsOK+j4nhFk8KV5pRItM25v3c7U2gGZP6CXHA
# DATA huJ1fQ+lfRBpZ6C6YxQwMkzLS0mx2t4Zuofz72dkBtBcKh05Mzm/3+1Yc+9U9qkJ+O037An4G+/cvnb17ru3/yYd5ZkJcSod9tvS
# DATA z821ltWzDHSf8+zMM5JYNLQC19eYMyUz2aI7JgNucvyjas+yCqxcScaBDT+S0k6Ds6iywDW9/tqlxM11L/Utf++TYq5e+tT6feO1
# DATA DwsbF9SFe5+Uc/UKZiz2q61e4L9Nv6XW/t+pTf8O/cFfqIF/Ty3+B2/6r9zwp/9GPcCP9OOPdCMa/6McXaMrn9G1R970Ce74gj4/
# DATA MQ5n7vnEpdeDcMm6zgQaUszexfvo83VjhXPLyko1+cp4GVXAH6xhb2d86eJFdDUqX00AaNk0xQ8v0rvW7s3P52KtOJMN/+v0L+jp
# DATA qFN7hL6O+j9JHqWU8oR7SEr/E/yG/u8PnBnfI7/o6/SH6Q/UAz42Xmlg6+OsXzO3lvI8l7xXt5S3mG/fwPfyUeWD2DxB6TzBi/H+
# DATA rxDNR6tGP+nRpes//PLwd+jFTeGp2bzla2Y/ifiaOaK2J27Majr878w0mtIpP6hKkFqbMWWYaT2pID9oXrpnB6dz60Cm2rZXdV5R
# DATA nrggv7Em4VqVJ9skP/iPF+9d2FinxngxaXuF+/9znq7+auPia2vKLTvjyJYAseFuAPmlHXb7Uu5+slbAFLxQWPtU9uomP/EjH5Tv
# DATA 6ZpEubZxRNKz6b2UatpSefiMRj6pOx4/h8Z8+E/T73NJD6BbO7f8R3TzIwREt1HPMP0KfYDqHyhwndffHf6JatiPqJ6oufT9SytX
# DATA RXJwXkuWtJbuoSXrdNtZiCfDgaqoyzPhiLbAGfIdNS0qco8T9bWybSjGh38io8aOsXIZqSUBaBDavZ38Oq+bk2Qdr6c7VtM3xbo8
# DATA uSop6HXFWXdET8x34xuvPNEtaIxcMVUJ4CnTwaIuU7XEdV6ooNv4362t2R66q39UN8ezg9J/lWQcfjGn1H44/ILyhKsxhqW/cN36
# DATA k7Tb+eMXj06XU79RNaYMeywZiaBnquzhnzy5AxdNTVDFzdGeV9o0n1wfRw+CQbp8Fy81U3fxYWH5d+oV7CCzFrzE/Av07JSy7Vvv
# DATA 5JPGuEKFUClaX9u+dev+rXdv392qFEvFDwe3r924uf3+9m+u3b+1ffPa9fvv3b6+pYAzbAzv+3vBpQoUGgZrqVa4ljxJkbl/991f
# DATA X7vJywqcCLG837l599rtm9vX7//1+3fv37l29fa1u3yLmqkW+Nb7u8HD9QqM9XT4Hw7u3n7vzt37t26/++//Zqv04eDG9u3/8Pr2
# DATA zfvXr721ffVv7l9/5+av71+7uf369WtvbLEqLC+pSGlhupm1wuaVEHvVla8X0xklQqsNNB684dxTVgV9q9dqldpMEf2L9J1JZyNV
# DATA 8/CPUsOoBlNY+FGeTxdK8gIde9m6y463VVKhLMIPTGWCsVheYg1SjcKASFGGkfAtVZwfKN6P0ed8f/ilMgbVL4+0V2SO4afiay3G
# DATA rSdr6ZfSpsYnn84ua5ubly3mc2l8cC9ln2ORev4CNS82t42Q3LIl5yR6H9BT91h2jp9b2OXrDaj31bLYurUKNgyCUUxznL1gNApp
# DATA Cr+2ljgwRO+R/RV6jTXCHuCwLUcAWGnC7G7VfajXCrDVV1wXbKTAcbuVzTVsT53NuZvynhtY7zIGqQSAEZmeWUvPeFS82Q9mvvxs
# DATA 9t6Zketr7mRpXKKaQ33OY6ny/zT9Z+5ZcQl9Lbriv8DzQE2BDBAEmtd3H/5jqqtODcdcCBIHvqryL57NB5XiO8EYi93xnMyIpS6p
# DATA mqgakw5wdlz22Gj8ge2abxA5WA+ZQeUHlSD8Q9/Vij3MTLQjavBkX9AAh4coOIxWyLDHSZHMz3e1AWNx3FbJeTUUfEtx+UcZN1Qk
# DATA ZpIlI3C2AJQpriOxgZpTmpmoDeDgCqGPa26kfmxmEm8q9ZZxA67P7zc+WHtj++7269t3rmE0Wru3UdDP2ssn678ODthFl/NmXIaZ
# DATA 95l1UFXi+qe5Ay2VFarpd1xy6Lq5M3wsBghsNFxMbGkpULIsqev82ktFPLGtVDz0RzNdNhMPnkVaHST6EpQ/9ympZoorZocUl0im
# DATA FfBlFYRcwZGZwG4Nt2XjB90XxpwhcMZl9h/I6lCyfKyXhbEmFix+101KntV8kRZxKJE1zWvwSNW6df/qbXajEIrm5sxSKGfvwhaz
# DATA MEm8zNcLWaiHcp8/6qKRo1K4whHWsZeYbctDemDayHgt+THxWn4672VYhoQrbj2bbbz7am2j0JMpNuZ/Oj7pQUutGEi8ZWuEFT8W
# DATA 9NdBWcmh65yYtXdubUsAmIi+1Ytafu+dW3t1fTETa0qcqcP0uM4xZd2byzpKsxmvajhExdXRW+VkBD5gY4OzQ1cv24/MExjcUpgM
# DATA yOhe/5UOSBz62I2FIU21H/YP8+1236VCYkfCYmdQ0ornD1bcSX4ujjGaJ3zLPvInc4cH/kFGgcvajvqKu9g/8fTO7iE88U88trxq
# DATA 1oCQavY6R+YNEioHTj5CI4KUFf8E+3XR6LCgd7PGAR0tu6dV0T5xR5uOLN0nN5hse4y5oDVwFbzpP8vI+xVH/Q/8wzcqrV+rUv2G
# DATA S4LnL1cxwzDpunnt7vvv3v51xl6al8UarBGp9KrvMW+DXFe3b2CXqxiObTGh79sjXsawV0ZxzMPVzJsSm2V2fQRnpzZmnhADfeFD
# DATA vJP10isz+3s++TTVexuv4BxTe3b/Kd8tXd9sP6DK/j97PA+X6eljs+Rqb9JMuWzMLIotqc94zvvE+/W1v9n6zfb1965pPwldyOyp
# DATA 4ZmAIVXbkwLxV+K0O5NwMTGYuy2IQliSjLkx/4HX1P7CxtaP4pX4nCfq1uRK+WbFm4OJ1zdrK0xKeFOqTo10d6kNXun5ShLTpRmc
# DATA mabSx/9FTfvYWypZa5UXX80kgJ7+vZl4673vFDN7nVSffkjWT19ZuoM5tc9aTb7Tm9CtmSyMXGTj19zF/b32Ec30Y9IfI00/StIp
# DATA UV/OmdUmzRYrZffjXb9cq9up6YQ7OHe4pdfyC+qWjWQ/rLUMzCtha6PW/KU9NLL27mTwAI2Mzeie3291/Et6RY+pCdYJgY2c11rL
# DATA +tMlRgU5TbzO4aXSpX7fDR7KJ7NWI2dG7yMhNKQme2zV5D2KxrP7b9WqWU+wItLlDcVuZZ8tth8jJVj+5TF6iBVqPEBfMYINk5XE
# DATA O29vU87dee/GnaTXhZdxmFrUXuEsh3jQJOSNJDIczZUcIFxpkjVxXj3hiv6VtFGpUNQQzGAtS7FI7kU7HTi3ILt9U9Vn48Ka561d
# DATA kBhe4K35mVjqMtlj3YD7UjRJvudkFBlgbXtNzrEdXUy8lVsbUmZ+MYr22RScibu9aWFD3Ca8Zdm2uhculVA5+Pku71Ld8Lz1TOls
# DATA YKNdtL94oUQvA7AZj2jPtWgWlpzupH60bBgeLpTb+PD3GEG+oF7re6u7ZXziFufgxXnrELwKPK8q6h9UtaarM50FKrhe55iblv+S
# DATA jaWy0CSWcPQvq4WL3CtW6jgb2cDWadO9gpKnovE+2dddkBPTBeyyUPt5x0H2ot6UHZsryrZJ3WisFVNl2e0ktda2OiQeHMU17QDj
# DATA HR56kbWXCoQ3H8CllW3R7w0eDHCu3gi0qifWMseAVLpf3cpWMat6satdF0a6BHBJl4CM5VmnCWeaHumkfc3m48b87OGUqdP0eITn
# DATA hlZSFif/JguT4CcVAcmHtXRx6/FhTWPc86A8jNZD6TBD7r2hq8AnXzigD3Txshbc2r2NjflBWsnN1JCNZL4290keCrSjADH4wD7c
# DATA obIN9awbUsxGvNlWBX1Pzmnirdzt6+0ayTE3FSWVBhWtVEmYZxbVyiXPWl3iIOyKSWBlxCpPZnMDPo4PFO9jTRbiGCDDkxB5yQeC
# DATA B5HUy/2chqCzdi/Vu+oHpB6hcrAr6HYkpL+sDZFONp+45SqQH6kHMnV3tQb1f6sBVXXJf0c915/JKKap8uF/SnoxcVVSZ85zZbLO
# DATA aDoK03SmH+c+0PSQYjqnp1jD1CiYXgJRvT0PlOnjXnaX7rfiqAfymZVB6kkT7kVceGWlQYIs8qi3x0yf+P4o6PnjcC+4P47sE00w
# DATA BFL38pLq7KGolEmfN9bKEnv+j8ogTvb7iRH/FVZYOWfZkYHVe56MT/+McUdmLY84v7+ylhF1YnWj4c5qdjg8OsI8dH1JYdNsnef4
# DATA n6M7XRzhtJmezqtXVA0YBJPxyIfkg9QE7ZEgu9aovkDvB/mfrM1A929ngMO4Qjzq+QfBKPbAXPX87hiK49GAUa+8LfSyklWR4+Ki
# DATA i2JeZFZq5m2wSfo3PWLq5woHfr9nD6XJD3JdDnDkFz638Hf6+d5sJU40cC56xq+ebQgLi3jOVtO5/lX1tnS7tAoimQZaNYt9iVxC
# DATA R4Q+s0NQlT4f2qCI/v/svftzW0d2J56f+VdcPyYXoAHwIVnWQAM7lETb3JFEfklqnAmFoEACFDEGAQwuIImhseXHZpOtmZqppFLf
# DATA 2kpVkp3/QOPYGWfG9vwL0r+wf8n2eXT36ce9ACl5kuxmsmsR9/bt5+nTp8/jc7xAa8WfrruR1jguex+FDXeeapyjtJ6cz6wmRNsc
# DATA tveKTA5uL9AZ1Z9Zfp0r2T5FifYr3J0g1RqHdK3zQ2kDtslfsqPI16Bm+NwYedhA8XkOvyVLG13fv0CdG6ktkRd/6SgiXE8Yu1gx
# DATA uyjDC+mdF9wjWSqLX1HE4Unlik7OJefmwOdb7AjHTiavJYw/SwhKDAnUG1TR2dVML6Nwqfv8I4I7GvY7Bl8JyWnJP1Pn+VxHLykg
# DATA 1KPa4b+BQvn5p7oD1eBuSXHyWp7QrbLHtN2/PKNYSE9eRNw8SM2cgz3Nck4eFbXmlAJZE2RD25jrFWHxAYw8gv4RV64sPhvOsZM/
# DATA F1rVIHiplom8HtimjdN8LvshyQkeS7HJKgkd5VooadUXiCPUZGzEbfQ3QcAJR8zLV5bOcdTInTLjpawxo83eclv2B6HLR6UZ+TJ+
# DATA 7dUl8KZCLdEbf74ucgkOB7nAzdddS9Nz1G5gpiR1NiDidrekYzJEyGXfogKwCcmoj/XageofrkPS2nSOJ9gxC3OVpAWwB1q9M8NJ
# DATA gWI5Oqm/UyP+NZo+yGj0VLupJqH49HmojdKpO13iNZt7gUsAxmeSlVaTC4Ta594E5O6w30ZJx30dJx5bBmdKb+2wy1Flyo4dvrgG
# DATA 6w5TWKMO7cFPugSJTYDX01OpE5IziaxVdM01xuuC81jn4j1mnx+AImyrmTtRoqatR3Zy3Dttow91voAlusfFvRuiroQticX0e4lZ
# DATA BxTC9iCZsnJGH7fIdF0vAc3QZZ8py46/3G44FG1GeiYHlx8gBWTnBirxP/bu9YojI8d1zw9EsJDYISZU/wr637kNkW7atq+14Pe2
# DATA b2+29vY39jdNPMzW5h7uWGaiCOQDJyx3xo4Llex5zHXO8lCGJTdpb2q1xAHn0+ZQpAfHPm1sVL75UoSFcbjMaS8DWGk3CIxUfVnc
# DATA wMjfmwuJxzc4Vgkm0rPHcK80fIsJvpN2kHDqSK0fHXwDZ+CPk9XhW2+9ZW/EZpZlKPdul/AeGOO3+6g3nGbJ1t2N9zYryTSjFAbg
# DATA D/i4KxI7Dyas+1ObZQS4laJGwqRLfjodTtrJTxRJwMGOC/kYI7jHXTW10y7GifcQXwjybHX4FothGdORDQzn2ENiARVv56E7YdPd
# DATA o/p+5paU2kF3MvEmvfgNUB+k+JVaTO5Z3gJhuUpwZzM+tP32oEUQkKBXbrE0X6KhVWiWITr/6KSHCduFKyejgzBD6DSApLXigH8I
# DATA FWWLqsQXUq1AtwebFUJ7UJk4VbUNgQoEq3ncA0Q1XNPH7XHH6hPA9puvEia1Ogab8HCKygWCx9+iC4ZU+PyOrKMUKfZUG3kTlNK+
# DATA VJfPz8gzxtMSoZ+IVY//Isen0LP48mRrzCoH7C2G6ab4MKVlBiacfQQAVh89eD0C4ia95x3nElItQr++evYbsmKDEkpJ1GhI+iwy
# DATA FXxhgYs3RpDEhvYItsVwgJnZzVLxw9zR83t3/DEv9TdK79Qf1OjP8vlahYL96OtFBq3dP8kZ6RM0X8SHSmamcHyatlp2oC65BWMN
# DATA vmB/Q/eICCfF/+6Ss+NXU17UoEhmHjlTrtNvRPpmlBF0WiMDPnvMJIrnKmm3BB4N6h4/KiF8l+OWXlNHEsRBHaw2k+XkavmgftUT
# DATA 06DiYFZgT9CbwvH9ir0i4Jr9FEmYl5vjjczIQG/0BWmTeODg+1FkgbxBenvgFP9iOIYiqb+kzeR4IX/Biv2vKP6cNL6asixqc+Zu
# DATA H/mGC6sjsOV94JJh5BudD8cvys835BeVoAVrTfLpVBQSPiuYJUD2kDmZUyejCKl3rmvn4MxvhZ0lC3aADQp2be4AlGf9IYyrptMN
# DATA r300/KmpcQqZm6v/qb9x/Zmzk3KBQcq+BkvhV+XjWNKCisVYvC3+1rgdwTToZ2YGRKFwSMIPOaDSWEsX8EtxvBsoVvu/ow7xE4rN
# DATA 9PhTYMD50sQT+pyLsiBAfzGVhrP94MkeiVcAKuxuHucl2b5ZEiOnNSUTUUEjoKF3t9Wk9gZ6tvzdIt+ZStVz08ucWQ7m8x/V/NAU
# DATA GO/X32Fg4a+DSI5vkSV9hv/99NnnLONcdC5HI/SqOKC0JOyb3mjYnqPjXmDzZopwItmB/qhCS3782xC2oLhcauNvgrn5X2pIv8bg
# DATA yqfPf/H8fzDz1vOjQxqiWrffU1yLqoClBnCd/hQp9jNV05ehGPVbE/PCqCyNnKgxdrHf2eGAQQEDy4LClXWtf6aqUO18dfX71/Ss
# DATA HJ0Q3WA75F9HdrcHiIH2AL1WEPi0Gc7K3zojziGKqDb7Kzz50BkRH4gx5Ont2cWiQDlvdN+5lyj2jnTi6qKuG80oLAEpI1Fzvy45
# DATA H7ukzdFZ/oOI0vVFbD0v3zCdfRzoMQPWpVWZRrelMfx57PTcGT52rBLcjrLuJjj57iDuY7lsrP8on4EoBk7TNUAq+rB7lpUOlrke
# DATA bqIpP6l1n0xAFbyYfVn78kn1u2e9MBdpqL0euJstbFxf4OAIVcfxQDvTU633PifTCLqhkvUPPMJImV+P+LoFnTceyprlQ1J2nAjH
# DATA /pzWFB9I7dzopEoUduNfsoFC6a9y7Gwxrkauf63dF1SaPtV4ooQW7c6q9lcmOR2Lk9KywAOfRmzd7heCab6I5QcX1MDi5tp4Easl
# DATA usgFLjCms7hK0uorHVysZwwN1llJq82Rnlpxynd3HzVa/m53gt0BSoaCoBbrA543X47H2Xe1LxT/YFdMQImrdbrdEfzBiirhKWgF
# DATA KjjZ04rm8hwtDtrhVxrBwzxXnBz/gF9qJ/lv0KwGhzsiUyQQK6Xm7J/BGQfDRW2I+PPP9NEuMRKEMBhxgolLbXrzN/SsHNgN3sSx
# DATA W9CK+Nbi4kFQjBuAIkWVr41ZIu+0d8TtPFrpHh93UUGoOl/SmsN57GqREZmKi8aUr++BH/+qx4NynvFhzV19e7d4mjdchJeGtTXd
# DATA owHScyfOOgxBokJBDJJTL4y1FInedxk6F/cQAZzppCLUu97QWm1qvBZg1OxSKG0qCbgKSQPTeLBpo4FXlFzmfYFrB6pIvqaIFCA2
# DATA G+3EkWocchMD9RCAv+G+0wzLpa+oL9W4q+i/BwIoEK+3opznQkeU8mL8CS7GwWqzNjZoRfikumbwi+q6jFwO0RaiIalfk4djgvzW
# DATA f/+Ugcs7PXys1hRg+wG9W8koT9BRrt3p4BMlkHWPex+mUevks3/K3bmw2f9aUT8Ipn+FsVpqfX5LUaBaQ5XQDvoKNgpuEQxAg3II
# DATA pvUxelD+Qt6ZPhMLw+twwBMIkVz4l1+gNhqOSunhtNeHlBdoRBA2n/2TXsYsBHBCwIQwRLg6cHFCGH/j4gGvx6Nhn0zccGJqWUHU
# DATA N4bMpd0B0AdBCLMNCjIADFSPADezD8E7qsIBpigw8WMALKwOxFo4QgnGD+M8X16OBTz60pdNFQFnqLgu1fnyZkAJU9Dvp6+/rmOT
# DATA DYnKUybGdeX5YbQd0ClhlpJdDCvGm3wz1mdO2qHKEsyVrIedTOkzN24WFeN0Ugh1OIkFunex75bcgHohJ4edDkPlNefKPXqjjCF/
# DATA ogrWMjwjnML/zk4Is3a5c25MjmPkjrrk1r29/Y17tzZb+z/e2YRlBW6mdggyMkLUHRIs/tFJtzPtd8fpzNca0v9Kh8Nhfw7pMRcm
# DATA SdiZT82fG40krwrDg8o5HRAzr+aDdaPQkvolNiHtQmpLE37ZOWx5nkCP8BKPXSPk2Njap2TA+w3i1H2pxNKvODzY8Z4qPnwJxRa3
# DATA xRtJeiO0jYRaVyd4lMxkxpn283wzqvFfN9Zg10Ur5Ad1kaMGZcoId/FouG+ObIeIrf5MyJfwhaMtgwcLq8rmC57fxgTPL+OYNGhm
# DATA /i3H6M8RrgtY9zz2P4eR01XsqN+mu5jTYiFrUDNqvpMMHTO68ovYHnoFgXDiYkvxHH3u3Fg0mKGIoght89a0+8+wNhHgihuawL/m
# DATA WzEaB7/RUg9Y/giY74IU71H9uTuN9QT5Tezwn7mBFO7lGG+5EsvUxE8Bo2toB47QvNcgbXglkbrRxgFe5kn1V26al1aF2JAFRI6o
# DATA iNwtfJAR3g4g0QPDo/xyH4rdV6VYNsgtuEOMnpBOrL4zpy5/y+d8sWOke+/eaXs/1/yOUb/XZ1Xz99VZ9ar5cUW9uP799mHTeaL/
# DATA XiM/OdNYnM0QqkchzGcYGPE0udj58CWy/6fkGPFXgIeiXQEsfPrPgwiJg5wFAEHYDkuGTpwbT4l6sgbRO0b9X/f9RlGWIM9N1jgx
# DATA Dbo5WUxAJzhBmb/Vx6RZQ8WUVWVRLidw8KprPYuO9lVPaFTQLd61UIr/rLhn9Z71vIpuhZn2xZqrxUdNuIbSNZAo+DMI6si1hAgg
# DATA XrxoxnzxpdsmoT9en+3TH9dmf8YO+g90bDN2Cy65HgC4SZsT6rMj4aw6LMsPmPajvuLBXjlP4VuKfw2atzGtAayy7bgHieQe6Q7Y
# DATA 0bdwohh9BjqCxQw5dXUeqLvzr/F40McH7ivWv1pM6mpVBviEUEK5K2y7D74yMgtSFlFIuxMfBBBmFufjEScEiTkMgiOhJUn45Xk7
# DATA ITAJRnCad5kPubagJ15upMzvwXkHrGy5R25cix2aHKGT88KBSqIkDaWZ90ngK+0aG8yMHAUAlazE9lpxldm5LyMArItM0LcUQINO
# DATA XSws/VZqtgvM1tJJ/WCZOma5rpIZlu1gmeuiXSkMvxR+60H0kcmTmm9IsPETIQYQ7AiuYk4AjosNpP0ZPMsIeTqwiySb+cn2D5Oq
# DATA z+B/5rwBn9M5XLAA7C/2ORS3TMIJQkSIehPQfdqb5G1JNn+0XJCh4l182S2xSKwF1uFFWWiDcyRwLSCg+sJxs3HSIUt1EK0ZBnlQ
# DATA p4SlHx9YSz/9XJw1zTPvf264F0HN5VKHg6pj3dJxolyH9Pk29Fz/cZlwJ3QdtyUscXksykSb65hXIjZH/kGxj6lUYnqjWzhFng61
# DATA 7vW0PVASeCcBtYfI8MZO+9QIuC5C2nH4V7uRS9fwmOS+oMfghZDJNdXwLyVAQJr1izixCUGbHl0Ew/wPuHNZ464By1jodm2x9oDS
# DATA 1JljaxVMlFzPP0cvW8JQI0/jApZZPGu0q8z9BCoInfGEYBKT3oNs2dLlzncz845kx9m26Qi+upYLeKcDUDI62DMuBFzifA3efDqJ
# DATA dSJmY6Zlc3RE8FnzOzJwRADzFd/BvTSLcT7tAKAx4btQfbcFgVwtYk86kKvEwS7ArC4Ueu8ijdE/DszYwMKHQxtmQ+j2XPwU3gx+
# DATA 1B7J3NQbCsDnamyMaR5EUrjlqcw8CVaXsnJ304InaVl98aDNIJrOhNDhrERiNn0AKh8hyA59HkqQAB34LjscBJkuwDoDRCJ1o3Il
# DATA E5ePBoOODLdwe+plla7HzTzhKiTExUJH/18NG82nGQobZeV2G+mh3wVL8fDxAPIsDtqj7GQ4CY3fEvM5fTTsT0/1cWPdqSZnI1Ax
# DATA pYe9QQfNZdTpukwvCIZ+Wqd64g6NhbZLha4Tv7WfgkR4KV1c4nra1l32YxxwsRzSZN0jUamRoz9mLtuIhsF710Q/SJ2GtwijsTu5
# DATA LLi0QRN9UU2535EYriD9KosjS2OS0i/vUqiBZqSYbnRB/klo4uQgpLPfRT2mOU75CaelXuDMjB1hKy/9AIOdZr81OxY2sqxSd9GW
# DATA VDeAEweV6GIgLLnIX23t3Ban7ahvOdspybn8O/AdT71r9oV85KlzQcRF9DZsorr6/ZKnhAnuonPBz0CJEngaPv8F+BvplF8WCYTe
# DATA iFg5eywzseX5vHvX//qFkCPkhQchOL9LbTrGyoMzPUEvaX8mgh4npj7N1DlzeJZ02+N+D3NjcNbfrIJ/d9sdUd0QY/JHSuxsTzjO
# DATA vjfGPMXqq1OI0FEsszN87KKC1EJneFe7v/JvqdtfmaPZN33+d6nYX4DmzABYtW8XwdPsr8T0+i54hAwgYUW/uxtq2o3TraseAUdx
# DATA ndBjyrR64GBvFXFyI7HlaDhQF+a+j8MXIw1Hr6s/dPtj68vvES1/WH9CDBixlsA9wwt8I9WCQKTT3gOGKYPXALtN2vSFwvX1WwdR
# DATA +5f07GJUYcZ36XgcZuiR64grMETge4WGucANXx+IrukieApnSBjvJYvKx7awrSBW6x/SvZ+PdzgENQPMD/N0tTA0FFdZFI29I9L5
# DATA VkQu5Qe5FLjru35aX7oD8GU/3EilSwEv5NzyHuV/yW0uFvsbAhHMm5XUz6ATC3YzKqZl3Bw62O1SQIwFIIyeaU5rQwu4zg0vS6d6
# DATA +q/aEelbEpM8RAJ8ZCFHHPRE3/Qy6HSfVIyw1h2o2+i4baB+5sYfxWBF306uLwOY6HJemuIg/s5PSPxrGqt64OYBQV0G+EtFwo00
# DATA CGHd7aV6w7h+9STEHmSob5gEKIn4dfVkdXhtdXWWO3Av/EH1Sd8KEQ7JmxKJjlRJ6FraCCyZ5YhBJgpOWNE4v/mYfdJ1AJdcH7xQ
# DATA k7x9ajKdf8c/5js8VzgrupNKYbGljw4b2UtHh0ipgEBUSiJtOJiDOWypLkEpURP2pGrFbS5E6ujUyMPYcb7jCu1nPaYRhdAK44jE
# DATA f83CzH05amkrbm+a0KeM87glwGsSwEk+0xdHgnVqj8GQgMknCBYLKxV1wezXkk1EYobzXH2WIXoWqtT6HcYGGkHkAzbChz6axia1
# DATA OF5VKBLNMxPKvRAXFRmK6KVcivwLkS9Oaui0clAixExb3NBpxJ2XpuiJm0+FrybjKG/iP4ranPxTDoKw3GHxat19JxhBu8e4y+jt
# DATA 5kVjCclC+nuj0oH8wd1hcd7XXoYXVJnv1WwkoWlicDAtkAIxS1gwE7owN+/tnTBIgkU+xBeyrvWqqRpJ9jVNnlo29PXpcz7LHCgP
# DATA w5OoURZzuExwxP99mGrpG0rx5pjz2OeG5x9Nmw42kedPwinz5oi0vzCKEZE0mX/wCTAcf0joP64+zw9TyJ/LGlcBSjgbChdV2nFJ
# DATA R2NnOsA9gMyOcaOoSB9GueopPu2rXLTkXImpWrXHXA6UBDxomiwk/IBu26UF54UOgxadmX6MYMVvGLZWSU/GSjISU+inbELu62gV
# DATA 6bFA9CEPgLKviyvO+uRMMWKcOKgdXyZCSzd/iiPaDgpQiGObLJYUh8ebE3egt6J5LWFG4mofrasJB+tno7R13Qjkc4kRA9eTj3E/
# DATA /0x4IDCSnqewRPWh02NqoYUZ+yJZl6MNf0naYEgS8jOddVnW41zezzHm6rTN/tVSDBJcO5ADmTLJ0EM8tK7Ziudv7dl7GDzEsUvW
# DATA ExOLblMskX2H/j6A/LlNr2LnilxXW4bqaKLUPxm3hcv1QXNWkEao7p7xcPnu7QzH5L8wUn/YSDa0I+5s7yLWzrr6X1p2nGWxAj4J
# DATA VRcGmdpnpwZIM34kcgSGeZk14H7ieElRqIZJZZcT6SHFzRc6Pxnd6kKnoPCh4TATV9PhpROPwVZdEJIqF4WKmVHqXTpIHDYhlrGY
# DATA wRjEHl+LIQYPkwiXjhabyfL8iau7zK8cj5bEWDPWIDGFzPIjXAvjWksxdkpxkgG5weNAXC4VxKeWLxvB6PHiSDR42LvYF0Xh4f7C
# DATA XjrkPxpQ+h0F/JvQfRPMj39UFaN9cub9rJJ35FhG+gucgBAzwEIFEHrA7MXxG76N5xINkxeRyvS3oKgzlry/efZ3lYSDVaOaSSdO
# DATA 7juIwQYaxfyGoL8zcCMJZvaNBzLbK5c6Di1+c2x/lbD2BQOfjTL4PMWt9Lj9qFt1ytvH4ktxV1XfG36HIdMuFyyOjXbLLuVQhJbW
# DATA KYbZtli/xJ6bCwBxgV1ekCqwmKBtREGBSOroG8bDiZJ3KDckJEDWVVA6YpFI/kAKcniP4Bf8wSy/7gMhcyArhDs3yCT8ab5cUo6p
# DATA aUL8n8ieiIIJzPX0PIjligYL5RuIJ/CGGFNOyWa0QRnhFqkdtFZmIfBGRtZwJyV3vNPNCwxQW9Jg4fSAyEGC17li/SVMf/QhrFec
# DATA BR5VcUw/hYZU/vKCc3++vKweVZLlZVPDLExBVXG2oxNxqL4uqb6O+gj1fqJOCpIs4K8W0JsrkWZWGNVlwUo7hJ1V0k+0HTLLHlOC
# DATA JopWzmoU63nSfVK6sl62Sa9RvIrFN3tfKBLf2d7bf293c6+1s7G398H27m1U8FNDFW/qbOH7e5u7oPCXh6J5efum+8qvxQvGPhbH
# DATA aX1lRf+on+tuzP7EMunOYf3Nq1fWV/Jrf3d3+95+a/Pe7dbt7bsbW+DunJ5MJqNM1Q2kZlck3dm4t3nHFjNv/Cr37t9s7dy/eWfr
# DATA li3sCFLTcT8rOatqVx621sH1Olym3v9g67bq2cbNO5uqd5vvbty/A0ujpIxpNxzI3c393a1bdq7bndMeunvoF7Bi0ZWFfN1+bR9s
# DATA 3nx/e/uHTBCt9zc3bmO1UbpghbzaqBBPzMRsJGV3ixLBhULyqD2ZdMdw+xmnfw4TP+7WEM6nCzsfoMfHaaO2/Hrqym0aZ58/r2Av
# DATA wIJZu+uxUe4efDI9tOUZCL1VTwIGoys77rcfZg2ssiARCNb/RgMBKVQNIbt6A19J5gCf6LyQ4DEPvIAmuJIMpqeHXe0jRz/0pZhf
# DATA udEQCCSr4TJ8bFn4/Wr6YPxgADgZr17I8w4BHoxe4wY42jCsLus+7QnLaLwSwgqAreAPMiVqy6/j6tU+A0cGNTiwNtTgbzBeZd1r
# DATA V2uH166yMU1Pi46fo7wsjkN0BEWb68aT9sOyG27E7w4+ZIGBfaXat7rjyU73FHbOTx5PdqaHim//kKG9VE/Ea/ip3sAvH3kEFfwi
# DATA A2PJsS2U7ItKsn82CrI00qrIiZXJUxHsRWPVP6VkipwPWkfiPoXQG4DY+ATt8p9iOr+vWD2LIW9fxRNEMGUev2oEm8Y50dvswcB2
# DATA qJGeMwKGoulXmYYft3sTCv1ABlri9CXg0zacThrrqzZEWQA9oNOwYgd3MYwDIyBg9TrtvpIk02iERnjysf4I6rqNT7SzvLtzRDFo
# DATA knRN7Haj1rV3DEd0twD5GH2UVclsBYxqRyeqpdpIrb9RctlaojnGVpMfOGXCDKBrV9ZW31qPbtBfo1MBeBE8hbufixgaXemnyfv7
# DATA +zt7VRuPlBonI84dJntjjcCsy+q2j5ll6mwmVfjfzc33tu4ltzZ397fe3bq1sb+JT2vL7+C/6iwN3qUiSZGqbs9hXtBMMOBfhcMJ
# DATA BsNXVqEt1/rcJyN9P/DSLWVZv7azebcFw25NhupY3cW/S9AJdfSWyzWddclOFB4c8CVlS2pxuECLX5aO2mhFgxuCmM6yU0ON45jw
# DATA MEk+ovp+tLm79e6PW3/65ur31fGspmzjTuvW+0picL5U53jvdHoqcprAt/t39n5ED+DPR2utdXbmbncUzQERw8arnQ7VFIN7WgnO
# DATA UN6LZHI6AVNKUOgHpop6fiJbyA+UZKBdm+hJUb0dgIld3RBK6dr6W7VV9X9rqTnJLCNQ4ymtgz//k1JtrWKaq/pdgYwj7Uzx0seR
# DATA /ErQAT1Bj8ftUYt6U1KlSS3XHbc0n2gY4QrqU4xrOs4T9BVJ+hRDxYFZjbrdMRLLobqlj9VaDsenfBAZqgEGpsmvnnutsmhhFKz+
# DATA MbiwOWGD33Ki8b/SOI8SAUAteJU2POKAfZKWc24t1PWsC+y0XzpO39vcVywM9tHKWm0NBIL31dTUk3M9QzN4dssspbpZ98FdACQH
# DATA 9f9TnaasXM6bvfXVVWBjPdT9UPOKfT4qvbm2rvV05YM1yMOaXF1dzZ8hwe7nZDeuJFvgMBTLdAxXAkvEQF5Zv9sdlWp8+6FlcNlK
# DATA NNk7gPX8LhEwAt9QdoHnP7+hlWrkAfdznbAG17QSZcuYgepfCJ0TbKUo/FVJ1ait+fiLAcVL9g6S9cC3QB1b0mQ/9yKIMox6m6Z4
# DATA 9uo6dCY8urwfp4TkBnFVySru3lV1qcJjU39RngHrufFgIIoe1OvN3HKOuHucpintzOT8fElUMR30ntRXHrXHK2rfrRgl9sp4OljB
# DATA iajB5oYqE1S5tuCuPTwa9m8sndPgZvqSrnY9ToUl6BtkJcn6LXnER1qb9L1TPfplCwT7nK9H494j9dr9Vvc1S5BN19b53ytUBESl
# DATA 9WQ4uLEkhoC3qywZHh/fYBuIOiZXptl4RTGlcZcmZeVkctqn9+3pZIhec/aTLmyHFkbsX129mqyo/9TEB52Oury1O2op/rR6i07m
# DATA Kkii1W26kCqazAa9YyVV9x+3z7Lgq13AaB13x9WdoZr+M5Cse0cT9uSrPj7pDqpH42GW8ROnmv6QFCHJn//XZOUJTAB4y6xoosCj
# DATA r98DQH11RLQOh50zko5Wb5j3D8ejoxaJK3SoJFdWVzPvPbC9ovfAHfAvddUvIkHsIpIgVcBJ180w1CgePKiV3nnlcbffr2Ia0ZWy
# DATA Go062QZn4Ip8I/gEBgunKnklJK9Pxz38z0rSUAuF5dX/U/uF2cHxuJudlGLuPBVj/dX2THPqpebwbaRq+KtphbZPw9g3UFgnnoGl
# DATA fU1TjjXUe4z8SLWwhi2gVmvQnbRQAUExa9ySfQqHJj9EpoGemoo59I8hTqafyndU/dWrV/TT3uBwOFVLSy+uwxt7s3Dr1Iq/klO3
# DATA vGDE78IAhvA5m/dZ0P6Y/NCffZ24Aihei9Py0jwVuNuvhnvNMckDxIqEyZcRYA6PIApC+7mJd4hIxjZyDe6OX2skhpfSXds1oz88
# DATA wBMgFsTG+gp/SSOLGUYMQbQbNUHhblfysChRgvpZsrGzVXHWB8B+2J3kafKn4/aZvUp/w0FuGpwSTnPhE9I79mmZglnMhBVlq8RY
# DATA JAgJvKfuyxu376rrkovs/QXLD58BsBDc6T+VIU9f0ErbQIMYbJZxEQtiQAOAkTyvs3y9Un/48CH5o52nHXWsoVtIChqaKucjSYcj
# DATA 7QFynipGXQUeDYWurKJ2BB5hUfXozZQZIITG4g0GDGyY7RVeTweKCWbVbDIE3Ev4mJtXL/mvQEHJJnBo3DF8Gy9jtst2pEPNLKhm
# DATA 2u+d9iZUz2DI/T1Ps+Ex9Gxt9er1N9+6pjqkjt2OfTCbzRbzk2qPRhoFmobOXFqjf2r0c3JltUuqc86Um5WYhAzLlTUOju09q661
# DATA NHXk9PHPOLq9ccA26Crdmejcg5POmqbJtzWrr6hVXlGjWOEHOTV3umBgzFrDQUOaTjuHOJtKjO2g7QgWm00pIEj0Jydn6cyxqpJJ
# DATA fP5Hs2g36DUGmat+TBSFgQ9Seuvu7ere+5t3EGj4CGCEq8fZHope6uiHQ7kPhyZM3doK1YGe54hWr+YEerC2ilYLFieQqDMyCCvJ
# DATA B32drtHBMp60RuqqP+zQXsikeTjkKYHRFlSQI/WOwDkPUsNA0mYMqzZCWsY+Ul+7XruaXprI6Ap5corCVyNVF7jTw9TJKqzmeP/P
# DATA YJj392/BOlr60j20IpXwgShobpEFHD1s9TKQ/c6S6v3k9dfPHTPTLKl2nIe3b86Cxbwyby3XV2cybEPRZM5c047hjVP/frXdH/UG
# DATA wB4X3Wt5kwHtqPNGfI9XA+hmtZqprYKg2fiLrPuA1kVaaXqq+O9p91Stc3WEIjq966pthJsKy4DUS/2C317X+B8UfP3iisKRyb/1
# DATA 1lv0CjgS/LWaO6D8pbVOMVUl92N92QL9gUQPL7iywndOsC1VSk2pw5aQkQmE2ZBh4b9OkFIoOtfzM6KQyJdvFcz/Em/yWr/tvwg8
# DATA NCKfNrQYAN4kwWtwhrm+WkmUlD3L9UViAawY/FiaMGJyF4GCa9VJJGXoVyTmplEXluxA+uYErm7N+P4N1yikXpI0GoSnpb490LIH
# DATA 0l6u01095nEXObYKuLP8XnNqkOaOKfrFeR/bdzExIVhhkBjWots2fqhf7nAu3v1474B9H9q1WU477kL80qt8ZNvxQN9XkAEM2n0+
# DATA u18t1yYnkAe38Tb7bkGs4KQ0rg0/fGe1vlYu144wHKpU9kqoV3n8y+Eyb87jMmvrEWFg3RUG+IQA3gNbHKKePOAGg25tGaTl1kYg
# DATA cyMj4YJPkWB4x6/n7BV6m7Mr6G193Z5m7qH/3vbtzZv334MxnU77kx6obyZHo8YqCAFMdOn11fp1UAjAzb1Ot3f958q0MyqSAuJC
# DATA a7A9bkEvKawBjOv1FUUjK9j1FfOqPh6aXExVmM/6CvzXPiMVa33FRe/0GtfRZ+eiIgxT86rxQ9eMv/g5BeJbV/1EhrvpP2GZGYCq
# DATA rpueCRX4ZNzGq7ZZvciCkzL3wAqL7FMuNnAEjMIphLtx4SuMEmXBG5FVOHBgXV7kZNG34Yi9RqtjL+I8xkoBcSi5QZNFVKuHuQm9
# DATA b9RdM3M+Gj5cyaYjWB10/4x1OWTaYDVegXnQglesG8zxcr4+Go67xq849jmso1uqGZdqUJEEaxijo6YbzxPRPOExQDYF8b4cXlo0
# DATA 3Ta1r2kwMjSb5y/JpJ/BXs0724WJJI9p4dv6Wm39uuVbMeJcuhiXIQME7G/JZkgDD09rnRW2B2MhZDjFnO2SU3PRWufvgAtW+Pjx
# DATA Y11hzBQBffTYp2BZcgEvyx9nLyOCyqrJ5sdQBUFUIXlEIHFASvPCrDCBvVe1H0aFUTGRGCqaRJaS2LulLrerXzGqGExBYx3MUVYR
# DATA M03ZM/7JGc3Fk7OwuxSbVU+0PjdFaEXRU8TxMJC6C6rI2MtGyqX3xyBd++EnhV6TF7p4yYDy8zDTTD0h84T7hsYeiM9Fmygn6wrR
# DATA IWRcqcF/rpbK5Vk57KGPRaM5a+E9J4Y05YxXuls1XC0/aeS1Y1SDdMKOzr5MRbZIZ++VcjT55ZgTtAzSA6JQ/MMJFiH8hwrhilfA
# DATA cjZ87JuS2F4z7HeAuz/2ggYYorHipiKD6srSHxXEa1WDE6KFqgWQ2DPwLSlR0Crsiv/ywX7LcVhOESj59hb9hV660s8W/tbus5AN
# DATA zzZ5HmQ9I0xU/SvwRa7EnInhoQ1qUL+cGAQ3UiaMLVLDpiiJVxowf+Qa2T3LT/L9P01yha+e/Y6jiDBjEQbTQr6iSNDQ818SUAHU
# DATA TJGNijQI64f8bY/UJhhCJs/SQemUHAHB/AwhEPxzj9BT7YPb6tLYG+BuEE93P0g5MBthdTlG8C42x9ktyppiWtQLJJyW6RH9YUmH
# DATA fwuqAT8jdaeHKDQNAQs7GK0uw6zGtMb9AQTtW/f39lu729u4IqhCNyev6q2A412huFtVOQwpRW2XRebQryoJkb4A+ML+sHHTjowt
# DATA VPQW4jzNOO3y2meguRg+6pb4A6r+NZtydXIy7nYtjGEV8GARSxcPYG7xtH2WHHbBNaDbqSWbCKei45i4QiwJMGmj9mGv35uc0SWx
# DATA ol2U0d5IgppiFagHAz6LoA6TIXOKXqbRDy1UAq3Ri0aFRvET9FTrxjhVrc9oCoPFgSZh6JjiE45GO/XlYF+akmI1dQUQbQPWRqQ9
# DATA +/RKU+Mdw3kViavyw/RkUwfrTU0/cYzmBesjkGNtg6Sq1zwxcNyFhL+IzErF7Q6o6XetyZA2lI5wl7gLcKj7H/ay1kLfhhloTPAA
# DATA 9wrWFozN+gHGOmUYkbeOLy+Fj+3WBq6lXJfzeK0JzcRX4EAvVDNci3AX4y9Dt4KKiNEHfCDG3il9HBmjMTddhLFHEhio6zpt37us
# DATA xwPJ4KYiVsBZgt+32qONTof/uj0ejrDQuPdIidVgom06J7F37tsIQnTkCOvyNpPiM/Kg0WGE9eQcHXTbo7KShdSlHokPpm407h73
# DATA nqiaN9SBz2HfbcToKHlB/OAsGTAaE62qzho3nhAWAXpDBw73C/6xhw3+EkdNJOZTj5j5pK6oYapPPlKShVWYzBbnBLIJnMr8NqoX
# DATA bsOkOJg7d4pCBSfPLxh1/gjlE1uBzZ4LfpXxXQY3Saw3zbkm1/EqDcpevjGnEVUORI0JlU+0YKi0QQw88buyZNIRQvYKm0YjhmTh
# DATA Z9FY3CFEY3fr9y50t63Gr6cIuNvFBYrGKsyF8fb9k1grWboglEZ5cfwoiYaRjxM6d7yU8kVAZBgUmC90UtBvn/8lyszfmExv+PAT
# DATA zDP2S4e1ordnI5FqhlIaP3OAvOVFsnbSfeKkQjkvxHWZox2BjvBz+LMskwNoZJdjk/OhYph0TtKHIOYP8cpIlKOzzpWZvGWXMr1N
# DATA gIFh5fAmckkQ+SjEzS6nNOagBu3WSur6oelehjANapkgiEEXqMB1p8HnDrZSR7mCjnGnMYgz0deXCopv+Rewv3d3TUA1gtqcxNWY
# DATA xynmV6Zefepe0ziFRTHIg5H0yBsZVzuAfwxyWb9odg364WTXoD+EysRNVGErNhVpArV1iKpnbtZNVZfiwUd9cA6+pxNa7LfHW4Pj
# DATA IcCwIvoj/9acVzHsFio/ukrq6k7aYB8qgcdpRadKLsuUyxOE1lYdaU9UN7iE6l3L7HFTC4GKqllZBdqEKmvgjuOou/RDAFUHnNfl
# DATA dSR8bAbynyXL+nnsAIUx8pWOe5LoxjHqotvJ8DaYtY+7CXrLCSU9f1HL7TkmGFYdWbITBRbX1kjtm7wJwgGF86kL+plY0UKjWJ+t
# DATA 2JT0Gn04mEJOoe+mYV15XuOZEvghG0hO2xzyiYUYR46ASCfQzgh1JXilt8t12ns4Zk7HUgOqio8mMv8WtwT2mG77tGK2AqxOC5ez
# DATA sW4I5AonKOYXa6vqfzYv4E2YmIQCAEjV0B8+RFx3JBZOOgIomIh0OlB3dyAc9F0HoMtH0GnVja7JC+gmO5JcSG+SIzwMGsnqkon6
# DATA 0ntwqHZ5Cf4aHv6koYdHhp7xR5SgqKf2aMPfxBgExtPi3da76AcDVw7/NfE46MsbjWTNCzIaox6JLsBYBYGl0hUvxEiBWt6WEw3b
# DATA NfxaCWXtQyW2TSddkszSWi0lrNjxJMs7Lu4PcKMOwl2NYLIGmwO7kZajZxr1opeRTKhd081jRjI0E6YeMXGXC3pliHgQYzhQT9gb
# DATA rp9iY5NV0STzO0vF6oKCNJPXA8HmAq5mNlKCPsxuNzr22AZmRuLET4a9AeYBWCZdQWwaxYe+soIpfYG+6hkiKATFARSpdaSMkzNl
# DATA vHhRxGAxhfH4O71mJozWiqI6Wt/lRNzLSBiinITTD6FPuENXh2+trkKwCCDpZBwOgoDereGHFFK52CWW+ITak2JQecunc5W9QD/g
# DATA uD2ZTnr9WqeXfdiaZuraplezdgzq0h84FPpGcu1q3vFrZ3pL7Y7j494RxDwBju+HyGSVmHWKbMnf0JLvR1Vx+lTm4wD3K/UqHA19
# DATA w5GAFyBIHUGuvjxV+x98Md3KXwMI5f40w8IQIgwbiFGyFQ1PybSl975AytYHCJmtYmHH0OWKs7J4FqRPDlNk7sPpZDSd1AuJ8ehE
# DATA EUAJ11/sCYMOv7a2RppDBJ8PiZH01HR3ySM9G2RtSsf322EfwhuFcrTdKUGQtPmsklx7880r1/KjboHfYC3zQo4jK/lYzdhkPB3A
# DATA anRyIolpRmsMhA8NxcvZaalSbqqcslzfsaKPkwhk+DCrHWdng6OSLqcmcTAsuVZFPMGMNXF0FpN6hLpEk43De9Xf5J5AigJ0Cxul
# DATA Qs2C7g4IuU0bBe6HNXRVZDcG9h8kY7V2JtxBeoTKwVLUgaB3+XZrZxOfd8dj/zlLP71TDMsBC0wbtKi1fXhSWgNPXF38w16/L4rX
# DATA Ou0uxdYA2xLP8eqrAUggKlQVMfpwJ7I/CPMvkCd1L2h4leAK6cOow74EEpyOPS6ju8QvlzwwNjPUkszJI9uuYYi6eN3ptR8Ohmqr
# DATA H2FiYVtYNUWbC3NC+4kaKtSVTImPlAA7jbYIlfgtGj8WXQ6gUEoC+MQ62hGvBF+7W8Npv8Ow0UrEQlEZmAXKeHIMCBnIfNp5I2+B
# DATA NI1sD8KobiO3UZMxgJpbMrcYAdWkt9oDvHSoQ6d/hhtLnD03bOozu0V0UogOKM8xqQLUFN6WDKHf0sk5d+gB7xTtJgC+KGKUGqBb
# DATA NdqXxIrEfQQ4P5I2yCUSmxkNgWriZ1sOZclXwRoSq9GZRKV2ltKoKx4qt7P6WSHGhIUaOTxKhq4ulJ/4tWQj4VA5TRan7Q/VfZEO
# DATA TIjRA9Nqn0Q3hKrodYmKfjpV4hJkDen2RmAt5vqOhiddRGDUY6slOoNn8mG3O8rcpHd25SlhhmLDwymgYdJh3RtkBn1FzUFJMld+
# DATA l1ZsVnJWTjYhfwO6h5MQpsRdNeJui04AfghoH/pPb3PZTjlAUqYzzCzKIs+ap1/c6hD8UNAzuHZ4ZfE+KTXQu9PBAGWgSGohyjz3
# DATA Bajn6E8Ej8DUOjFt3reOWpxTlklUdEwnRDq/z/KCQedmnWclsyiM2l6bZB1+BhhG+DCaVFgmLLh0TmGs3jP1XCw3qDfHT4v0pULd
# DATA HrkTmFuA8L1YJIGzK2cAoKqTDLgyN7Ez7+lC47zVbMPks0I2x4pM9TXz0i3GZ/X3iO/98wWmz+pxgkkUKQVhmjoMnC6YprPPAhnN
# DATA 1cJDDTXig3Bs173bxm1iMpm9Mg86lJhT3ajgQjHtQV4kxQeT9mEG3K7ffdhG6AqNVmgrs+SMBxqJVisQ9QaHqfoTb2kssmS15B7k
# DATA EUqyx2i6Rm7ZR4DBmn/fKjj1jRkKB0qSBsZkOfTgvM61GfwDZTb5gvYFGfWlDeqr6OLqJGaE8/d7hjz4Rqf2iOZPQagEyqrwNwZ/
# DATA K1+D5+c9OtD6yGWmofHD/vCwlC6nZY9iQZfHyTJrfcJNi6VLisKumYS4xsrpZsgtF00kW1U04B6kmXwKoNgECwF5J39vYNjA9vd5
# DATA OK9fxTZNgUrRaDVg0AYdToyQVXB0Q83TMKL6VpoChKI3d8C/yiUJTRGfP//Z87/WqFRRTDqgMSQK9A10GbI3ATgg7y4eLJaehcLb
# DATA +RFlvB4AIFspxmMLuDcCNDtsGr0i5pnvyxIGGyd+zIka8S+TRpxywEYS1jmZPGPfOHuGZDq4S8HGYXRFgaQIypXecJqlZefxmBIX
# DATA nwU7ilDMCFtf1ywN6PQ+riOmdwt6mjBcGu75Bv/iLkPiQLS8uko7BFPzyhIeW6Q0d8lPjKlFi2tXZ3ihgCqLN3o0syXzPcT4IsgV
# DATA yoih2OvX5CSFmYeZsWpAFrV7voBHYVedyQAig1gKxCBYUa9WnozbZ5wZQi8KDf+U8DHhk8PpoNMHZIuFHX1ko6/Mp2xEPqYZy52w
# DATA v/VG/aUeM2XfZWn1K515gFL1ykMI8hKoCeSEvY4Yh0l7vcRbfn5nP3EXVvWlyWqAKLWcINbvYJx+9AZkShFsVm0KmSHSLUfSb+FU
# DATA RU5jCRonT2M9NyK//K8pFS6gxXmQn5bGlozfX0a5AGGRIRRGpC3cSFDdpsQwFDjUtbgn9c7geJeMho/hWjfMMshqjDnl2mOyOgy6
# DATA j0VldAcQLkQJIuVmJyjRPD6BpAv6Nqktg+3BWcKqFfChrQmFDdXSIyQhgW0Fkq2SDfD8duQGFNqtrBAcG8KFQ37GPueiQcdpA6GG
# DATA yGkD/2RPUFBNAPgmow7XfQMDhmCgEktNP6r+OP1fVttu7d7evnfnx8lH9EsL5ubBve13t+/c2f7AJclJjLcaraht0v0q0JGIL0ll
# DATA Jb9k0F5Q6bbURV5djjViL+czqgcXxRdydmd7uMknno+y631z2uYkH+murjj53x//HcoZOumZzFeSyMzwGoNQR6SiprarhUc6Vk0O
# DATA n3wXsBqhUJU8/24tTvgpHVoMknTgA0MTKhZdCsURWPZSRMDrCkY5spAHD3ymRdS6FMvGqSeX8LhyMQeyWrtDoZq0QewmEpZnL7U9
# DATA JMWzKXIht5GbI57iey33rC/ltxr7kvGn1JUQmQEtvqIsTOD4Na42+tA9/1TnwkT6cXPGPvtfBXkJbQ5NmVXXC3fD6By8Uuq0VpA5
# DATA aPkgTfDrgCHJbuh4wWYzViugvprD6V/J7xFy8nysEdvQL6u4MWJjZkLLTScNoXlu557m8w0wdSQykAGuKyiY21RCXyd+QuhnX97w
# DATA YOfwIIL10pdAL/kgJxyqsZFEtA4zgB/iDv4Ex/0zwG4TJ1st0Vh3eEqqUl9j0rGPSZ+jMUWe5iQ9VAw8S6r9dpgjgRw3f68K/ppA
# DATA 6U2exBpm8TDpvz9xMghiqBMCkLBD/OdITpSfULvbPfuqFjaYEi3KZOD8DSYD50phapFCLWWySsegPIQZGp79/xZBVl3OXG9aTIOo
# DATA qgwrpBj3sDbo5JdElr5nriLOsJ5x96G6zcD1ID5o2q1Qhbo61pOjTnTTqYcJaYd19qhkhBEDaEpkXg9ba5rpVJYYSBrf+M1IZIIF
# DATA iahEAFUMjkZVZw+pTZ5MTIYvCvuu6AjtCgVVV3gWK3xXgz8gNtqNYnCZG7n0xFOW4+6QOZrQ6BiZL11P2biWjUjoYnmDbfLzksSX
# DATA cvUkNpd5PBW440aLjNlXneh8xr+CxMWUH5AEcNzg727d2dyDGQ6EXZHXOMy/7mFBy7TResgW6FjNhnusmEZhnQDDGpx3SjjpZU7K
# DATA wWcZIugWnznPf1YBrvOXNkHzVzIda5yRp6mlTEvDSJ4UDa0hcByDzxHl7gk2HLiD21rUAHxdAcY2wdfiCqONgfaFWXzPMIjNdMeo
# DATA rUW9BH3iXZlwqt7QiXp1T2gVbRWOWJcXKa32Ovo4f4y4UVJ2s0SBwkxOvWV3kct57eBxqs/yxE0jZcBKbRsmiMCe5xRO2vTlsPm9
# DATA y5eJwgmF6fhHl4rgSFt4JhhfxdOyYUI6f3CSHd7NcSpCDvKwO6/Hv6LjGWn+v0fgv+osyDzsLkQTxXQhcMa8iQkaWJQ4fAIJmojQ
# DATA CjXmSXx2p/MOtuJacHauBPH76miu8aWWd3X5oH5l3T1Z5u7hQAvE6x/dzrzARBHTgQ737aTzKhUEEIzjAsu9CL3Hl5UoPVbnQlvd
# DATA jjp3k4shCsitFZRdpQz3e9Jg+WfFZ4w//DFqp3BoCX70pc4M/+yrUGbUrfwgrPHtFbJZMdxUdXmFxWigUxCkPdkymo3+2VcV0EYZ
# DATA 3R19BfmARDb3L6NaubCzIAjxfPzLAvIooaQx9etLfJHgmVZMhLyZ9qecNgFEDC75OxNV5SAlh2Lur8SF40u+wXyu+obZxhMYOHbo
# DATA N3yFwJuInSW+EGoTvc4ibmw+nvZOiQk6lPb5X+q7EJvWUW1o5BSRDotlGM0r4tILEqaVXkiVgzBNvGvRH3uMvqAP8e/axvjhFJra
# DATA wTdGE6R2bKPVUjJ4q1UWX8IVvdXmT0rpcNQd6zCpo5Mh6EUajOmDuZ5SDCXL0NDAiXApBTfCyoCMU2VxG7+Rf5ucuhgnkDKST3us
# DATA Ue8w3Rf8/ZBw74h/pYjJnJ1UabdgWUywIx44XAnQY4KHjLoZPOf+AcBUb6KxfajxbAJ6cvFIg/RVGcIAR9xvD4SbA9bPylDvsfad
# DATA kk4RY/a9MTXRBEJDVe6AnJuc19z5+Es9DnrrjB1zT5jVsaANeO1BNaH2V4hSSrXKJrTyjbwCbJHLL6C9hAqbsfc+SZKePJ3fhj1M
# DATA ClvRAFEFnaX8vbnvaanz3zMpEVZ6YV8wQXJBTWP2QYJAzPHDrAGK8cKxKdoq6hjlubWrkVtS6JPM6hc1bHcKhwY20jk9RTJVn1V1
# DATA Vss2WsYaKZJxCzNiFjeJ8GPDF68DsJCqp4RzYMkuL7tEUwzRllmwFcZUNhVgoosbhd8xBlPwKSXJKGqWWKG7JLlt+dUj5nwxU4jw
# DATA 4gUX3/mUdttivXSl0qDLa6tztz4eTHaVTVp4VKcw/LSpkd7OX9sLzTRAhOe/5Yxw3Cg7s3NZ/AdKZzbqH37VzFluUn7wGW6FED+T
# DATA I14c8GPkZmWNMhavkk+Juquw0TYmv65KIp5QRG5x9f65VPeCkPVFR9boY2OiX1IQsex37cBB8RMX/+6gfdhHDQkkHV0MVgTBSyyC
# DATA hqKijTt3XLgRx4qk0wDgfQQ1dM7rkUVPQRdn4/Qvlxpwx2DKqL82ywz3PwoO7ERsO50wAHR2FDnZ5OGzDuCJYA4DGF3RKDsECMNh
# DATA /YvNJti3Y6kRrH5QLL+xaLqBB2YRnbljDeaZogjKfk6lCCVxMEyLiVPKpHZ66UELXnbJ271mgRYK6/MlyQsRO2NA5GGJ8MHeUgcV
# DATA fc8PypUk1sUFp1YU0b590IHiYcakY+EmFXG5vyDTKJSzxe2Li0k/fV3MHfZFFtG7R8g1hBctfiFYD9cfb4x/M/OvmK1e3An/6iJV
# DATA zSQBOd24CH1G7hg+7WuDdB5hSVKlFCmIIcDVhavtnBryHOHmjB8dQxCRMq3iKbEt/dvPrKe/+ymNPpIjwHYEBfRyZGOxKN2yG8x+
# DATA JITnlkPKgats0dAqybwReM5/5ADZG4ymEwczA90R6tYSA/IsOd7VHScofDmLbnuKhrGbvoAroP+3wF3PI7Oiu66TjAxLLURBC23Z
# DATA wuZ49y5GroJSF9qmuTfzcN9SBxxkWiwquoGLURFbkPs1x9inqivNmShX6yLWgtId0/MLsRSjR6oXUY8uVZp3igks6CgbZa6Hlpk5
# DATA Yw1UPcU95NItLl3U05CH4A/+ck63rLLNlw4qAM6OGCy6SIw0LzqDDPzv99lInfiTBKaSofwAk7mQN/hCheMoLbbSjThUMgjmauA3
# DATA 4l45IJMa04JoVsJGNqMij3C5nnMsGpVnIYnQzlXFSkU708hjhPZNPwhBNZxbuFvPoZfwLl73pV+jaA4RuONNOl0sX6QDWge7YB90
# DATA oqSX3Y25a+W0NXfJDPNc4C47t2kURqHJfP9Liv1CHFrykBdkskgfGPrdrsE8ga13iumhsjMbhaz+rpFrySCDLOmrAia5hfy11RJ7
# DATA jOMIy0GdBnPccacZrVBGgwK7p3DlXwR/EEIwf4v+XZhrKozQMR3RWSXxR2lU0TkxHGIzn9muUkCciydyQ7w3gS9vvumzQ1XGcUFy
# DATA EoKH7MDFaTeseE7WWYONO4dEyDQTni6aLVN64oWOW5PgQR4lheyNshGI8TgF81hAJLNX5IVsxk3MWEFFiW10MJTvIpMbXQj50MHH
# DATA 99MfvMgJ5VaxCfBOOxD4SCkU5lSzwCl843JnoDbjOQJzgPkfCB8LiyVauWVU+lUEIXdQG7QzmnHlRP+t35t8weC9VQR2HCB3Gv4w
# DATA 76aS1gNtHCfXiTGPoKzMxuN8EE3Do78C0qpTKkDL/cNStAXrbmJg+aoc0yTWk95IzfAYsA16IyPV6tcVzgEv46XzJgkxGJd8n/hA
# DATA /aqrduA4hZc8flhBbPUQUD3PO94XLtT+eMQZq+GWTR7zAsfESaVhaxCe9flXObRU1+dKsUs5mUm0er/uKXxSsoLUBQ+dhUvG5kCJ
# DATA CVKPZRnhchuBBC0qmS8NLy2pdltISq0WDr/VAiJttXgCnJAWclVYEkAxIRQJIMYgkki9SOjQe/wfn/+12ry/JrfwHL+XuU7S2Jzi
# DATA L5i6DMQZCrMWQC8Im7J3lk26p5uUMVAOovQjoArsfSX5YfeM/4LMFvzn9h7/gRgV/2Vv+95tBKHBp2UZrrWFqhnMr9AbHPWnHY0B
# DATA hkkTsnoywJhzHH8y7v6EIDc4HztErE37/QQaqH3H01dLnv2TDWZ7/nMCrGAAAeNTX3ExLH5GwYCCL5N7vZtZ5PnPAGvpQqvxR/+h
# DATA /qc2z2EfDkS1O2qjs++kDYgCv3b1Kv6r/uf/u3rtyhXzNz5fW1tdu/pHyeofYgKm4FGumv+j/zf/9+qrr8L+UEyPjJk61g1jy3Ti
# DATA FdKl9QAkb9ztd9sZwPpQSOVabb32/fXa0tL+CTityoI/nSrJO5mcKPaP8GkcEYGgl72HkMflpNsfYeDFCXAFAOZTb4fThydLWMjc
# DATA E5L9WztVQg097rYBlQcNiRAUavvI+aqTk/ajrupdF1ypwW7Xqam+dccYb9pRJ+UhnJCALDUYGmPskeT9CFH6pHs0pUh3QIoCQZFQ
# DATA +5YAOXbeSROwhXR/3nhO1FkjO53+gRiJE5By9JPs32D/v3XtzTV//6+vXvnP/f+H+F86zbosN6c3lpbURsgmyXmyM+5lp+1b/R7e
# DATA o+lXMkMPftzWpfRPRvhw5QjLpOUb/O1PHk9kMZAyHncPyXJQNi3s3drewcwX25hlCZFL/6JbOqCsFRnunLrGv/a9I7M6gJwpmVMn
# DATA veVkF4ETOL/P6uy5mV8AJHhVTRN6eDwdEBTFuDvN4HQsjYePy5yjQyeUGz5O/viP4Z8apzBxgoNlQ+jmnarSVj0Dn3WfjNQEbUzw
# DATA 0wGISh99lDgv3sb0crdBEi+Xg++zIyXrZzXFVx8ijkOD51Q/+egjR9Re6Js3kjU9Ki7Kgl/mhmrgfJbdTnFNIBKelfDrpPF2tCr8
# DATA XVYzPVtaakM4eWJmXN3+HvXgilEi6qpgbgmdp0uvASjjXln584PV6vfb1ePm+fVZ1fx9dVa9an5cUS+uf7992HSe6L/X1mevr9Qg
# DATA EzimQoT5hwQMYuIgL8DwWGcJe4WUV5BoIYXC9FjP3Q+SK+tlwMtUlAHrxmCGWwO8j+tzig4Y9V1HbZpeG1KG3NDocYpuiJaKKUmW
# DATA 125gcFkCl6mEpq3WHvUw22NWA4yn+4PeT6fqOpc8hnOwrrY3jneWzLjxlZVkt5tNVduYBSdp44FdxauWxpiqaNcEaA5p9AwPYcBU
# DATA 6GEInOphuw9ABcMjPkePk3Hv4ckkq5llMx1WZPaK2V/6aVmvME6+P5XsBpUgL0mOTtqDh93ODW2ERGlA0c+EriEywpgcW2molDOk
# DATA r5YTam/YGVQLmjOFiB0M04fZu0UPiTZhzSqJ3rV1u2nhP7XB8HEJ3OTXVpPl5Mq1N9V/r1+7iuccgOTg1qgnB7VajTYQR6g4a7MP
# DATA ItSw30kejttqOHTtUjd7NfLREDIFQJI6QBWbQtb5CaIadwz6WE2tLYgUurYhZddrA/W0jwwIGSKtOosMMlgP6XRCS41jZDEotqD6
# DATA 74WYh5hHWomc2de6CKLdc5jzWQVX4pxnT0zebOYsMzNrdSTVQOIsnfOSqTNvTBnvgfECyEcfonQ2drZEwEavrRbzLlgTjvvD4RgZ
# DATA KJFCZwOztwAiLmZQXMPFNB+q7uRw+HeSc0Bwa4N2ug6Qx91ZoghKFQxa0h+HDc3Kyawi3AmBCVXUnm73Hw7Vhj05VSN5fw/8JZCG
# DATA Cpjsu8PxFrGlKLsFCMxBB3WJkvMGD/WGOuq3e6fZDQnmq7pFTwETU60C2eRtFbapc9N92A48gKYagNoKRwCopKpaWU42kk7v+Jiw
# DATA QlFfjpiQiuV8qCjeslVIbZIpNgZ7UZNwLVleSWaORYf7pkiX/kLDMZ3lQAvwgo8Afo98syHPAXEC4v56maeSaNTZL5b/F+4cyfo1
# DATA 54e66nI0ZsfIeXEEn7JJTBMczqIec0bb2mbhTpxzviO1UgdQfKxR/i1MsNSZqqVRTFqD27bHDx9R8sIGYGHr+aF5odoBWEztGyWG
# DATA nLtEGZnJIUmWgEyNyaVLJPO+U6OqfkSaz3dqJO6+U8tGfbjX1VLAc03eeQfS47zdSN6CPR6ofJUUO5pAAkCgx5KRjRGqpj0araBK
# DATA nYaYrWjBmj+qjh6m5Rr1ZudhuXQejR9VgxgQVtceEmbdzJM6CGsy6W8FMkbVk/XKnHr2Cd72bq+vZOO6Yj2tVQAl7XX6Xe/VFXoV
# DATA 1DcDrkQZ0mnkqvVSXrfKtawLuJk77XFbkRRFB1N29TJMb4phaUfA09yWgINCuhxF7UoaiETtY9PyPlPitZakqnmMi4HkSyC32aFG
# DATA CTw9YDO9vyBBB0QkEEWIvSVOjuVwQ5RL/KyIEct5skb2vfs3927tbu3sb23fa+1v/3DzXuv+/a3bbnFIG02G+EoAH15Q3e7mfdVl
# DATA rNQqOGsgUZRI4lL7yMM9J108veVIQPEpTqnegLjNFHetdWkq8wBCn/0GHiEcGdjITUj3XwkQBzSY/RbT/Nkg6SDgO64V/ptnf4c2
# DATA tzjUmQ/PUcPQBz13T3qTW2jETtbUsSRGyrBXPFZmxK+jgxhupxLddmiHw9E+pIQ955YEKjFqqOh78uzG0h9A/9Oyu/+lqoKL9T9r
# DATA b1676ut/r6y/9Z/6nz+U/ncH5Si79tqLFXMmgJpV7Vu8UQTqE+eW1e2oGxgm1mIrD3DKa1f1L1AE6b+H2RKiGoOvTr93qM1C4CWg
# DATA i4y7+i8w75m/Dbi9fjLpno7gfkcVTsfqSDqkyCNdK7hkwGG9ZKqmXKocs0wuU+itih7FpME97iyCpaeh8+zvezfvbN/6YdnmCgPI
# DATA vA4lCutA2CsniKFsYcKuSNjCCLAHyML03ks7IgC2oFBtr7W1t7v5Xkmi0zpwtTonHySbiGVfsMbCUrp170cbd7Zu86kCQd8uoIuH
# DATA 60g4ProhEIsZHvp8FadKHeBd9bRUnkXxc1ffeqs8r0e2J627cFrd3Gzt7G79aGN/0wF5xqOJJ9Qm13jTT65hHOKWHEdtWnn8r5Pb
# DATA BZ8wiUQLO0kThEsAvkVXBFyKvvkgXIg5i6DR4Ylca4H7H3dakzH50xBepb77Gx+W3O7akrrHFJ7FyOU8Av0bBrG+evU6JoN78AAT
# DATA hciyEIw2HHdKR2XQh12BR/xTSelr629RFJb8qrzIdOxs3Nu8Q9LUEuUeR88PmUYGA6W4I3AjaE8nw4jjg55MAiLx0VDwRumDGcm8
# DATA DjybpfPlZXY+0NF7GLGA3gxOxN4s2Lm2Op7rSyR2iM+W4jwbd/Rc3dv40cbWnY2bzjbmecso+FC2yunT97qTCadMN+3zK5Pc2K/N
# DATA QF4je5DYZ6Y5neibWUQJM1Ujnsm418Fo2nQA7oBlB88a2yCFqN/b9mmXnEwBiB12NeTM9Wda9y+WDyI92Kj+Wbv6F4DPbP9s1apN
# DATA xb8Uoc5SUuxdaNLvbe5/sL37w5zJt+SZpBDUWl9Z0bnBbY4nwLdjEkUnKv1DOqyZyeAFAnl/Z3sX3W4pDto4U0rPIdG++RPyAWA/
# DATA 5D6mQEOMu+U+6ldYlzpPVRX6VLWsQW9D9aaGNze53qoyBMzAMF/DZqAokALOgXoGv7VuTv/WsHj690+nXcrxAT+Ox+2HKHyYwurI
# DATA Na0iHCy1hi/h8Fe8YfUyLMcd2CsNPRYT0crUVlT3+/v7O3tc8+7m/3d/a3fzduqcOkZnO7ZkXdFVK06/s7t9cxPYmBKzSG+hk6Gq
# DATA y8TGdHIyHPOdtJ6kN9WFWrEZxEHyr38fbPxos7Wxs0UnjbpeoINztJSZCcbe+wCw9wwFk2KKe3GQ/mlV3V4et8edbgf+QjeuVO2n
# DATA 2qr6v7X0RrzkzniouHUzMbMKtyVPawmkjgIatEdjbx/iiuINfQP+vkU4PX2I2q2YHGYZaVAh9JsuaPhdDf8L5a6DVlXdyLVqiFVr
# DATA qFzPuka/dtwFxjFnjhgrVbFPHiggN5MHcj3Fq68iStBFt/t16gb9IC0cGrZ0w7Xhh9qexPRDMR3tI+gA6RVA7QpCXmMVUAKmgw+z
# DATA xkETXgAbpm6XaDj4Fi0yuvrDYedMTSZ8/kYDX7Mp60bvuARP3766jLka4D/lc2fSbkT6pStWPZtRX2ojSK53cwoK2xrI5yV8ri7D
# DATA MzPN6C7WQC8xyuDKxdXbIyUHU0Xl2mRIei2U5pQwZ6eLfDc/+khravH3K41GOkTLMlrqqFDNLKlX2rwQn0WnXgxxyexZtwr1YqZh
# DATA sJPzo77ag5r4kB5h7LOlEhJ3qdx42xCzNnY3aNmQs6+0R70VMoavGGN4+YYaeIn7r59q10wYAaumy5EBGLiGG7pZNoCHreaZysW3
# DATA qvqssTEet89qvQz/5cjurPyONqzzvzX+V32rOv+K+xHUU451VzapPoNyB6vNd0gjvnCPV9I3MLSwe39365YODtCVsXZdMZxyqWxU
# DATA VmpdfH2V0CWRj6KA+TLAvE8Bh8top6DUN+SKSEjLX9DTqGYKD4dKosogthckF6CMJaQLsw0gBLEEO8TEKJ7uS02Zr7ZqrN0ALoP+
# DATA S3hlUAUOuyWOTLD3AL7A8KGj+AqFDle0gxWLRPk3qPCSwW3IGwY+Kjosdzbe22xt3YX/hvIUpeHmq39tvwsX+/b47LYO9SgRWAMk
# DATA UtQ5v5AicMhVuoIfD/uKQTvg4DrkiF6VOZRZq8QgSsp2mAUzUoEidnMaOQ8aUnwiHWnk/MVSjho1JrKXeCWcFCmXEdwDbH+0hUUq
# DATA z7+L0PXfl7L5TyH6U0Gu22a5i+UNQeKyufqaiHLTPcJUpxChVmUMZXSTHjwqG8o8gCqbGnELisN/UVTy8DYCT3psGRwXByhGiJGo
# DATA C41a2HHJDMTeVsqLdZ6BmqtVwqCrVkfq9oFXnS5j1EkcKupFPjho3hzgc7WgSGCpnQTectG50L7ixhVcOo2L/JF75k/fOTxvywLV
# DATA b9y6tbm313pX7VgQbyl/Gd7Tie2AntAigGCagTzmwy0qlrVLZ636XvHjbgd07I8wkzrPCWkfbyTZSXtM3h8J5VpQHOhM5IcE7icc
# DATA 0SnbDNwglmwWuTg0D2dncqF42NldCd+xzZ/WxcjSyL5XBXDAsyWdNgHqsp0CloMpc7KSjoiibkggUvyWx01wQBqvIVrRcHICyNI5
# DATA 9bjJY/guX0nwI5ufQk5MDWoCYG99yX/FJBzUc+WASGAvGKOKIDfOU1wqNRnns9mSSXIOA6p7Cf4OUnERxgvD+fKyZsU6jl7elTmn
# DATA m86KYT4FTcPyMi3fLHJZFlOnfYPdigli4jxFhynVdU3QKYxd/YZ/ZpUkIJsK04w9Kv17o3ome83vW5R9af4WVOel1kPchZDc+/f2
# DATA 7u+AesDcNUNNEKQckaBL+i2xfvMRxrvFlD0Vi2mrP5VkEQZMUV4ROBpIeqaRglYHNYV6+yNOpD3AAVjR0fJAh6SeyRxKokX98gDC
# DATA uHTL9rCi504HXml4/GfB6b61fe/dO1u39iPTLGcXI9XO1dk2AUVHX9EK5ZOl5uv6GzHv7cmkDdwLYBRCykDA4JRr9zJ5innQlfAU
# DATA uCPTL8N+zooC0UTHwIG2BDXjRU99m5UOlm2bMMnlcrCbzRAw3ItLOw4jCNFC/KHpJAxChl/CNxXtA8iRf/Ull3sZ4qTcL0yZgreo
# DATA tYBUb2ivqh1eu8qWA/zuIKVIB8gK5FkUCAqbvA9RacYfEE9o5siK1Cdos6I/wL3dDKrj3IJ/MP9/jup86WFAxfbf9fWrb1317L/r
# DATA V//T//8PZv/dOxscqbv3AIyFEJxCnjau5zGl3oY91JYJGsgFz6JIo3yFAh+mxXgyEdZdfsIJ/rQx9vhoMOnrHwBPp77QP02070u1
# DATA IcOF/zLW4h9u/hgUlHv3b7Z27t9UjL51e/vuxta9dGljb2/rvXt3N+/tY+QDCiKQZWGc/nnpnTq5exwkDybNN8rvBJ/ji+VGbfl1
# DATA SD/drd0Fi95Rv51lyW3cjnTU2FPH4GureSGGOBiOT8EZiTlWrq2PD195DSfWyFY++jp5O3lzbZ38KtkpC5JZPsgePPjeO689eLK6
# DATA Wn3wZO34wZO3jpsps7DAiie7ntJAW6xa5+PRMyMwjxb2CHoSGiNE3HOuUn5BWwKDfZC5AK4oleTq1StR88TFBwhf0ghNJTXSQ5XS
# DATA XmfQTs15Uq71Ieshm6ad27kT8M5/lqA6J+rXEofATwH6CI/tRXsPKgGgCWwLrL5vojU3rZk00Tg+9Qj+VQPrUFIecImEBFuYT9T+
# DATA hQY/L6kOqKj7/ZKXNVXtmNUn2hv2jY/gL7VvUoAqGk/KfJUYmx4IR8ygdsTPCFs4YLufaon/RKvftbWZflN+Z6H2LkH1nBpP26oO
# DATA 6tW1piZjypOkJxItV0j9+p1el752VYFlubpKy1JL9eUKftMV0Kbccca/wgPfqP6ZGmyt9V+rzTfUoxX/WXmZph2yIV18pCzAIZWQ
# DATA UUQ43GiXmhEFjThym8weiI1LbhbJDqhzaRtEEWAE8GSRPqvb0ca7cGXffz+NbL+X4QbEexSAVe4NJ+8CAou3VcG7hmeiHnNgNU4O
# DATA ZizfqX9R6eIORqvrVzmzt3w7AIgkWI21MB+oLXVx36H19ejFbLH1xcRl7Unb9xkSQ3gjWSvLzQbFy+4wL0dbvJ5Qn9oMf+JJRLA5
# DATA +qA/JM8UdztoX5WaCXgGxvphOsdb7YNdTZS3djc39udRbEXmM4/RV/uNHPqKuKXlEpshpRdbxUCNjbIkxNAcfchtVvgZjK21+adq
# DATA uOL3vZuBSvQmfNsbPNza9rZoTv/u79ze2N9s3by/92NH06k/Oet1+x3me7zacm21VxJCcYBLUlZCYix0TDKkKTKs21QUBExNuhKE
# DATA 7LaFclIr5U/7ve391t2NexvvGdWR0RcW5M6V7NpmZw54tn3lMG7bglMmDrl2EYoB+QtT78bgGmk1EPdJlHEhsZYke5QKJqiYMYC0
# DATA 1LGW/KCBrANfluHX2rU88cSriwV0OLwjggsd0OiotFZZW79uHJVczytsNtagaIzHm9d1fo2dv35JetH5js/tsuq0WXUSBMIXQixA
# DATA uLrZkgV8w7pmNnEydpESnGFnpfiLbFNWT2X8Q8CIIwWMxSCdi42Kh0JgUpGWlPuDXgxYp3gOb23f3dne89S2Ec4S3u6iqaPLUXXf
# DATA BZu34hAs5wFMFujr8Bhzp8i+pN9LvinBEGcU+T9qecERIYn7Nks8cahczKDoZYsLc3DHMmbjPjhoxppyvGa5nij2l9/Sgfnh1guT
# DATA Qigg6H4XpEyWdUXouYTfHhBgdtNT9+I7J4E3PgmtPLSmuomm3hH6gSMIUapnJQldWb8cP9ACkIVkZO7Jk8lUpC2Fqg9426fNZtQa
# DATA uHN7mQco5gvLyDVx/lE3bZU0GBiJxl30nPGUumXnAONK8lvR0HFc8EDd58CrhG+JDcXN1soHa03H+Vxjwx3U4fIHnoqvqnKvpq8K
# DATA OvrpdIiiARVclZk/OvoxDqSEJStaZCXteq9vPoXySqCtmy6wqzREK66yeiWVbAXe/SDBa2UJa9LXSPgh8++mr6XlhRmLezmUM0fd
# DATA XKurdpsRhYUuBsoonFR1DqIu7TWtfMKIRnzXWCvj5Iu5lk5aTFY6mUNpHhlaTxfsgSVH2jPh0dV01zekUW0IrTAN55okROpkfTnS
# DATA HlXBDg77RxcWnWrSaZ2PMltfjeyRAZJtMcOmOyWkMBZO9TEDbAE/F34lrmk2bOk4Ae0rKqChzXrUTULPA5U5UF80raeSTLLinO/6
# DATA K1+JunTBY51JUTdG2kTUa7Dk/LCL+kDWcdc4i0F5KU4XnLHVIQ/RGlWnwRFMrgStYATEicMUdLWgMS15bSJ51KgK4geao2qYRuIL
# DATA h+lpL8vQ38fZTOcpDlaJcDxodVGh0EX1iHt20n2iG9CZAql8rzPT+9DaHThshTA9GhgCwEhacBPiuwZenOxtwd5Rw0uzc1fJ2d0c
# DATA VmCuZDZfCCGbNS7AKCT/pEGEe19MILUQ6FykMIeVCHN11p3wQ7wm6SVAJ6kRQp7s6jWYxbQt9O1BWLoJ1VGHDuw6NheXGN/fuPfe
# DATA Zoyx2x2lG6c+U5Yl71lIfY64ezrsAK5cx8r/l2anRazUCPqOOLuU5xhTwBwvKdWKzuqvo4Q0V9K9EJP2ReEiXhzjx/rumCNS53c9
# DATA /6TMH0ttNByVVPN+qFAgNUe9/cL68KDQckhueZNZzHdAokqC79inAC+MnenpKDMub91BBs5E7eyo1yPFdwXTPA8mjXWdUHcBt0Vu
# DATA AJk5zP9hmgYOCrGDFPfAK+5NgqQXI+gJUZntf9BYzjLmUh93UFY2PcSgHKwtWHva9V5xIDM1JQ1j+OOvl4ooyfCRSw2I+w3/mDAc
# DATA cMnlpVH/BJ2KrRq4cUEV5kR+hW7MYaOat5m7s/Odf+PXpRc5WEzmK61Q1Jm9WT+o7pCxVBhVGBiYydE5/mqpDKe50xGqx9Xc0bMX
# DATA U+lyvZS1AFTEjdXhWwA7QpkaMtII5TjW2PxTp+1B7xikEM5MZT0MD5zuRZNN6URC+NCmueZUVpiST+pBoueW58drE1h5kpioqCxF
# DATA poUamQUCO/a2Yo657mB6imCnJU00duqaXuasCbpAC8VHqF23DZTsoVuONxQRWQX5xEyAuLJAR2Lc8Q16EVlENJoznzltxCmrFKcJ
# DATA Buzm2gONwlJx7XYy53/JS6Wzpbl6S23EaGfdTfwT4gCDNdTUMQY39EzJzVznRZeKUJkE56rnyQrezBcf9GjLnQ5I1b908YM9NrcL
# DATA L441rgqmaq4By8594T8a0vcC/n+nvYeM7/dSXQCL/f+urK1duebjv6ytr/6n/98f4n+vvbIyzcYrh73BCgRNjM4mJ8PBFYgS2x5B
# DATA 5vVkOlI00elC6Gh7YOEyA1xSBzoSsDg9r0B2p2uPH6K/3ZLxChydkTceaDJg52pPPP2bAnn/Am6DL+wGGMDHQCYCjSQDXn7z/QKl
# DATA F+HSpRNORaFoOl2aUnWi2Rh/4nT99qFieyESwi0GQLaqtDtY0on5klZbqshYjWsUsKRvhTr9Sg28stVCttSnBLSgAcvg7cLViE/t
# DATA XXjOpzpUwn4a2JKlDprj+8UQGxD074CRnLTHiEeybvBI8ImEJFEP4Ey0acb0lVYP2b3h5tsDDHqDzGzjJLXh4fi23fl4FNx2Ob9x
# DATA bXBacJHpRkpWJ4bTYLtFxZ16YxNmA5D6RZOpTdj0vGBWtN3nSCjTGkKtxl1qmORcPNgG/1uJxdwZ43yD1XEYTHVf7cwG7EJ5gylr
# DATA nBwdTtPu95SYlNmN5gedZRxRiYGXlwZLoccmllaHU7zQdtZaWEwchLpq7T9KSYR0tIO96yyX9GgYMYQGr42dEAvllbh9bw9AVkSR
# DATA EA+nCIulMn9k77NTLGcLtFCyF+AP9FXT3P61aplSqZHTuuMU7dxqXoYLci7oybkHejL7w4KeLOBISM9KtusV11mZiapiXaXBJHj1
# DATA 6hVvwA3rd41TdX21nG89MZmIcrgFrR/lqZsMKbNwCf8rSAoUZo/UDACjdndrhcO4i3FzKtH32Ar1nMMdGi4huVskFvCJRGlYpw6a
# DATA yLFUW+MQR1w0knOnPdU5jE6jfc3BbjrMloMPVIvv7m7f229t3rutn7GJ9xH2E9Kyz/weDbjJoE/GRgYiXUtECaL94fJscMkLOsy6
# DATA PN+X4KiANq8kMwzKLzn9pGZeS24jy9CYaBn7frWPxsMsSzBDgQn2NiFskyECnh+hbyXmXuTKfgIw/PBKf8KxtoRBoJ5TEMxhFwRf
# DATA 8uXsED56+/Sw93A6nGYcl8tRtBl7MsNXWkMpJwMC5PEFlhfPGkyPFPAevxwzJH9JxOKXRD0XXrO8/2H/kJoOyInBP1g5zlgfqmQz
# DATA sZ2KrFvMymICj+2G17RsZrdgYx3HUQlc12szCuah/kiY+8RjQgP1t91larkM8pVpBFgXgGY9ysfuirJuszGdMbJnqYZTzwJOmQlW
# DATA 2SCbNOH9tyANgON3r3bLtD+xSsCsS8CKqpvWSG3R68iMxq3IBHmAC7qAYLOFGQQdqfNPEEzbVDV8PECDH1ZZG3OhOrnUrDYpj+PJ
# DATA 0bjWG670hxPwo16x4cIBHIzj5CImgUgZ2pqzsuOuEkB6fI9yO7VCnaquGc+fujsW1KSZz42IEHbSCXkOX8/mUx9Uvvj5iW5j9oev
# DATA Z7ZLPJfuJ91TcFCL3WG9CPJSAD6g8Qj0vdE8MIHzFEgObYTGYf0GFhJa4OkFAvbdDEF12ungoejtMiB+rVaF2hyPB/bGoFIYzdzo
# DATA K/7TaWPDdT2igu6XjRc4QYVAsLESuyGPJUojDYG7oX76e1I9Kh0si4+aZAhrUOz4UXsEWcRaw+lkNNUPJ4Q71Vi7vmqYJo+ThgWK
# DATA UDtBInUox/iT+OvcKaBpYWsDGtY5mJJ0hLdIxsiEP6co/zIQSjYZ0k+EQ9FgKAjxMgO7C0OnCG9TSjyDvl/Ya8q+iPFOAoin284I
# DATA uL/kJjxKIb/b9OgkETcGSPj4/ONnnwNOUvLs2+efPv8Es0RCUsnPn38GOR+TZ5/rjJGpBzUPLvQfDhSrSI77bRwxIzh9gpl6Werg
# DATA jzX0EwIzfYHN/suzrwC+iVrxEk2GbUGmEHC/GQLsyaDX7WCDAh4qefYb9f3vMX3l/wAQ87COW+0BQ4wCiJGWcbijnXb3FM1jKT9A
# DATA OCuJP/VlrE7mEW12dRKqHvz+t5ja+GNMrPkpoF2pmYnn81QvIhNd9lbWUCPaZYEYKUMh0T8ZMogCFFnSK3Md7g00EelHQGgMxyXB
# DATA t/QEfJXX1V8kknSePU39HKD6QhFmkS0dp8/+njI8q+n44tlT3Vrp3Gy5WZnJ5TeI8AUd+2vMBP0UgPEr1KsvkvNg+87q8BDGP6sl
# DATA Ms20zjj/ufrnc/wYkMEgoenzT11nXLu5FLOwXAqdRIDhlAijB1Us0jUriAUJIWU8Z61YUAgYekMNHtZny7UHRyfujZFnG1a3BNP7
# DATA FLPCQubsf56PjpZD6I4K7cD3lxk5XdJxzy53JD0YBq3hXLgBJOWmnAVTVOvQdGgjvCiVHVNdoF5zh/8/nbS2/2o40AtNBFOHgbSq
# DATA JHo4jGZF+77KKpyo3tM7FT1WIiqxREMKdKuHVccdZOHG6UCgJz0dBHE5RlfWg7R6zF/Cu3KzqbFC2HpBcUotsgYyNBYqC/kRGXhb
# DATA 5IVoslxzrtPY+awa63e7owYhc8OfFsVKbhJreIhlWYBIOvtrKReo2vaeNxLJWhymJCu/qy14Nl4pDNGCHRZsVpSeuKxZMVvSPKo7
# DATA Ep9P44XBU5g6pREyl/JSXpCNKy0RwTAEWrpMJKmFj2p1MKyiamCE6QrMM4AIQz6E+Vzp8TG4JuKZxR4isMIgdvnGCk+MW/J88xzX
# DATA bC/0Bu86uXv2b9VO/TVvTjok3d0aSWiyiMCyJDHxkYtaMi/XKNcBnKYuGv48iHnHKxYsdrWOonj4g73ayr7KPAKgxn82naIHnEm+
# DATA qa9Uzlt09UsPp70+CD/W3c9+fUE4MFeD5wOCzYdosw2Tllq36VXcd5T2UHNvWDPXOq3CrkK2MVV/5BY4W3Lct3AhBY8qh55bCG8J
# DATA umltNsXMg9pyWptOjnDJj+FJKf3ej793+r3O/vfe/97d7+39Gfm2Rb2+DurXWdF0AdcsRHxItEcYOGRRFCruNZpHdqmg2SMBQwSx
# DATA RuekkjjQ+nW9CSEqWQZz1hNDarOl0CMEO1cxPSgvFTmSUb+J9LUz2WJfanOF+y39Yn6ntTbOTJmnYrbcNkTyPLn5Hrez1pjgOVWF
# DATA VgWmcT1FrgRzMW9hqILHZOkWV6226YJWrf502sP0uWa+NbP0g5pkvZbx2Q5EGLuDmGlvjrImwZylRsUdr4MwmgtbygEZbJ0YPCIQ
# DATA MetTLpJI2P4bN/ZORaQ8ELiwWsgNdimb+yW+JWsNWnXPeVl2RkLOhliZsjseWmaOX2QOwbhuVLbaPOtJBB82ZgIRor6usb4Upper
# DATA OejDkUGRstKAD/PECQ1IPV+XYk9yMoTQ1Nbn+o2K8Xob11QSAQkJaHmOqBzoinIE4YiWzMq5Ngtnc65gpDewnppgHmAEvUmLO61Z
# DATA pKAbmqJQNC7HVlbi83nzhpYDVepRVA6suFIvdqMc3KJMRa8le5PhaIQwZA811GtGj2rJRqK5A2aq6mWqz5y+FU036rKbICqs9ldS
# DATA M/gEbay3b9aCtaVOG5UWCpadrmaV6ocWUiI4v8uKMqoditCVXAsVmQf0Obq0wA0p5LJSzSk+Dx07W6gMgaia0rXVcjwiOsL2zdAu
# DATA yfidJl4qr/fPFJqx8zC+6aTb7mN4dPEx8D4Wk0+gyDSL+wsvdqSQpY47APpQ4lspPTnzFfZ59efZR9AjmmwqAMiWz5cDjmwlWKwD
# DATA uep8r1m+nfyDUV3CPYOVl4heD1qEb0B7Ruqlb/kS8xvUnS2UsHGOTiKNGwMP1db9MLZMeu0bam8O9KxjxFvh+umVJx12R12MSBut
# DATA +FAnb9G8SfrV3PuaBf9//tegzEuk6vHZb59/ljz7Z7jU4SMG+4/OAGoYSuuLwJlHdEOfolr2d8++BXUgaGa/Bp3st6iP/oIH8MsL
# DATA rUzO1X8B9h0/g1v99hmkyCDtx8tXWjDnWF7Wwrs9ot/lyJDYkGauxBSKDlKthH87ji85jvi6CsZ6NccuHbKLH6kW9taNivHk+X/D
# DATA E4vc6UkTB3e3ksG0GmeYmkd7A9c2xg+nwM528E1JWxHV2Butljo2Wq2y+BJseK02f1JKjRqdcPRB39AAMsmOhoy0nylxRZukUCGo
# DATA 5QhSK3b7HVIjUlwUiU9s94RfZFYjIxarlghMBu1d2pCNLDY1EURVuAPAT510BU27KDahAQwznEzHfalSiw6vijdz7GXBJFSrGJcC
# DATA 4XVno27DZORCi11Df4P/wFeZvbbBr5qw/ilOauYuT2amb3BaKtL/wOEAWIi8qtRp7kl3+FKYl13HBKRofU+J95HXVMjhtPQ+H8JP
# DATA abkcWQqf45yZCETWxq+Cg6t4/QP0feXqffeM4OD0LWB0UH6DFiDF9i/EZ6PaYBqQ5TamYK4qGCQj6v2BHVazaGk5u6Hkac5po/Xq
# DATA sjBVTRc6/Jtvcvi3o2HHJ+Yugb+Mrt1o0S31tNQuAfu5WrQWGhZaLaSAVguYSquVRnw7id3kuiGa1Bc/7J7NT3wBevquB686Bj+e
# DATA 9Nk/4VH+JZ3eC1pcHDMfGG5vJBGbJOt0K2R55CRAmLcaTvRvn/8SGoHKyGIJh/y/Qu3Qfi1RlPiUewOZh7Dpz/HbT9BUhjKckglQ
# DATA pKsk6rNPKJMRKKP/SiTlxp59BbSLxiJsEyBe4bbZgPgHssoLUjyjnEOltf87IqT+7/6fo/LHe/RLh38vjv9aW11bu/KWj/++vv7m
# DATA f8Z//dvGf+1amHdM1NEdEwIHafeD+K/shjo7FS8/7E0gFZd2cmBhNFssBixEjdfZE1vsnxBHir98RBhmX/x3Hx92ITMy9jEe12mx
# DATA +K3qzSR2qwjnPSnUsQDfA4iK3uSMTLZ1B+TZjWovpQ9W09pPhuAyD/HScLP6UHuxkw+71HOmwoVIW1rLZYtl5ETGH9TXrzYNkvTR
# DATA cAyYqRb4B8POrQ8rJXITAAgGUTWwL2Wplofpo0LIUZkDhpEMdjff29rb3/1x6iI6SSwnqvdhf3hYSpc1mqvji6x9QCINX6Rx4SPg
# DATA SI5uuLhuD9JLopopssCLJMp9D9q/tb17O0zBDDUVgs+aNQtdL8lBPrJ0Agx3yYwDHlnnGe1Wb55HJjQqW4sYkBBlV9LMDmnndEPz
# DATA YXaDkUZziJPz7+P2o241agElgA4oCND6vMWiHbyvGBJkBmqiZRs2fHtACF1wt5otMkZ7g3ihgRbfTTgbxKD3UwSNEuiuSMHg+g+V
# DATA iasHFpWZilzCJcOJg1tJn8SBKyVN729vA2Dlj5Go91xHKKpDR+ry/dhFHcNDs92pole5daoeHifkNUqGiFM0VjC/1oEn6gbafdI+
# DATA 0hSr09TR9ceDAC/aCIboW547GbIj+TzG2ziwcCbazt8lLjyoKB2hDtv8XNDqvO44tzvNG9iKAHtJVO/sqKBZ6URQERsuLc8C/oUf
# DATA R+MxhBWi18mEOcWxcuSYVHTEQ9kNSRgoSs4o2cY1HcAcyVzfrh5DmPD52nrl2tVZGndFhJoWZeG3tu/tb2zd29wFlM7Ne/vb7kFi
# DATA CPkiVp1l6AA57avpIcWh1Tio+Rg+JjQ3uwArORwPwz97w5XCgjGFvYkOmdPERYJIZmEcLMobyKwcriUiLHLMLvZ0vEB4TCQQBvzy
# DATA aUKFTkdHDghCtQoysRQLRfVEAYFElTXIZqeIIYxEOjDVNWXUpmfJiGhotGKmvAC0s5x37lF4HpEzmQkRT2P4cdExsttijo/zUgzA
# DATA Bn1K2C0B/mHBPptFoQTtpo3YIOKmKJkkxYtGjiBXh1lTivF3OBmeOmxM3pnoKDX+6AFZQJaxHR5qTnxi1K2aZipnHEHy0FyLanC0
# DATA GRAHzKwD0CVZ0dBzxWuUcT2oMq/tYVbT2U/TgdRKh6CDmImFJe/2pFQuQkdcNElKKZYlRUaX0syQtz08Dsqvra6ulsvFgInFE7T9
# DATA gTpC4tmRY/6+C2QjLi8I607M7sCVA5uOcyEH5iqBAF3AZr6UQVUszU2PvJC+OCbDLC3d2Xxv4xbJlpTYfO87Pv8WPQI1agIbYDA0
# DATA F8VUBzqBh5KTT87mcl3gtApnQhsJ9b2gJW1KhA2szxEOY7UwItLdXjiM5KW/WgBpxUffWVB8sr5vNpjFpKR1Q1rKYUKUSAHDyBZR
# DATA QPhM6kXF0u9YJL2MOPqyRVE/5PnYuo04IpywMZLrlJfP3mIV5QH8RKZIVbVALLlLzvbXK14v4jAs9gQI/UTmdc/sAWq515G4S/Zt
# DATA ebGI5JC3LOb/dImwY3aIiumi8Kh0N2eOWAcT7O3IRboyT8gMBMwLCJeLC5aOM+9BmHTkggJnKGzCnIqfHjMj8HgSIOOoypeRHu2g
# DATA rGJpXJorT3pXjQWkyReUJC8lRS4qQS4oPb48ybFQHnwJYuXFRcoc3zNLHksLCp+LC54RKAgJF2ClTExy4KsjrTOReqn46OzlQgtU
# DATA zIzoVizaAMlTXV+EMjGQgT83jdsqChYSyDygBxYctL8MJoAsOvdxpe9uvbe7sb+1fa+1t31/99Zm6kQ6au8Vjv8YEcaIZbhq3jVC
# DATA YfdRjxB3HOsQninwmVVYcknX/sIPA/p6pbEAr8wZGhKxyax1d2vv7sb+rfdDUw0oMbl9xQ2RpIita2cbmncC28xZwIpYMaigEUBZ
# DATA wOc6AQd6ULEOW1eMmqSWVXA7GDFhJiz6SKaUzhEs1lGqwCVYRAiku8FtlwzmLCmpgDKL/e6PpR6IDZ4ev7jOuUQMCa/IFLe5u3k7
# DATA zcd7XOQS4iOILDJre5u7P9oym+c1PKOzRB2paDyoEqKOth/QAZlB/JCaguRwPHycoQpwNJ1ktaVAWDiIBKQsx3ZFM0jDF9NTzc/o
# DATA ewlDqH/G5rB/fZdVD3SuMQa2bSkZF4iAtkSIUJkHfiAubnYkCyKC2kxlB7yfsKcsq+jfBHUhNwBjrC+Fh38eHoOY5IaXa9P3mAaw
# DATA MfrRlFyd+4rpcIsocuPuza337m/f36Ml2d/YfW9zP71YbjUxdptgbVUHEAe8y8tRhGcxVZFi5FU9Enll7KlWF8+P8C41M54GU5At
# DATA 1VHN7Q2mp4dGPYB2P+QjCQNKMXYVtH7DwDFoJOVRdwzx5xlisSBSE25KDE4CZ29j/ANPDcxSbKRc7AG3vfAt/z/I5d6xp7yM273Y
# DATA VoF1RjTGTH6hOB+YIQlmJdO1T45GohSs2iHkGRw8tHCnO2r51JUW9xYsLvSIC0Gn+M+MIVcd84ZqrGILgA+N7XQBqB+0KKETOStD
# DATA UwMl9o6Pu6ju2NqxtZ9CHB2AHCZt7GctuYcnhJLCgI7bA+HmBbkVuwDzFmUSnujn7W+rzQi291w0MXGpz29g3o1cy5GOwM5chM9I
# DATA T+gQL9EzrmFKhqKDLSZ7KD7N5WFcwbnxFeNrtnEU8zafrTWIYMFkYWE8Ud7NeS6Qj7lWz1ckzF6OdPxasq/4pFkQ2GDkKqH5ql4+
# DATA OK8edZH1jrOT3giQPgcEE6MvQh3G7Qv087HTQs5q9MywBWInx4IYSaFzQyQzNrjHtyFMszUZIrUIUpA2Czu7BZviEgiNSzn4h0bX
# DATA z8r9mq/tN0mz46m88xKBN8jbRTwZjj2Lj+nLKxeEgfSr8uRsi6ScD86Y459VLhfxuqggygxTU3cZsrJewkeJKC8CVT4PUJwfuvAk
# DATA YUYoicZPFEyPZdAfPSrRP5RVknolc8y6oSaLeGUC1Anyaci3Qz6T0sPrBcQ9Owot5ml3IuEAKc8oLYmEa1kUPe3f43zUDAboo1YK
# DATA tu2CVoUXMl1xo5cI3iZwDrYj0lVKusb5lhbtpxseruGlJ7ikB+kdtTQLz4MtFEYPk3eicCAUl66cPtAnsYatGKZNzBX0sIx4RM47
# DATA 8rWvnXDZCVPRmwh7h1hdmFOuJ4rZISTc4CPUmwlXufyAeUxJagvyY7Cz64yx7uj5zIn2aP7JM9cqv5At3o6yYjqUTgftR+1ev31I
# DATA 2Blpnor3pVwn86z0FFc6zTDpHHUw5Zhb9ehwOOxLL19zJSmoj4JS6zTOg7q64DU9L2Cs1XbTviqq1npR5JL9LAIuaW7R7c4ZI30Y
# DATA cNp1DVUBMficqxSPiNOh4nfDQe8IsxlzeYI6OgEgwKDQD0wVMfCh+Ha58FZxvaXd26HnH73bRYOpfR9umLKVNsa2NBCSC0gQfF+w
# DATA M6E2D4QiCimeMySnnrAf7r4v6IYLyFDEji2GokY4KFSvbtwGjYHWYOOp6iiwTZSw1VnbwGEr3GH4uoQl7opHmpv1h+o6vbi+entn
# DATA k4wYrtp6MT27DeJ3eqx7m9MjikMtkkwgmN8VTjyJpOk2iLHV1J4O+MdGsQJ12KN4s7a6aoAEjob94ThSrTS9CpIr6qvpBWMQGNCC
# DATA SB/1gmmdTzkUtcLZfKXBKy4FLc2VNFUZ13V5SgtV30TdWEjTBxo8vboGFBLtoBNw6AdUut5ElWN1ICAMgYmvOwKND2Z81Mq+efLB
# DATA v1vsTBcy02I/xtAwpVElcuXShefaWdjMAdqCva1772nYS9TcG32fJEVWd21jNBhYrjrtPhiJWPwEux8i8eE6cXBAVku0Vndy0p4I
# DATA vQIsPdeIsXZABaSSeAiqMNQzTB4Pq5ogbCY8bWtp6yQiSBI1xgPsdM4Q4jZXVwB3pVu6GIkqqlctQq5qAHigepdqeZVWwBkSBQQt
# DATA OUnnYyIAHTddkxk8Q35+HlieuUXX+wTdhXQvI0FZzjurCqBt44lN8kqtU9cbWFZzCVVXw+T8wYB2M2Y15TkJ7pP1K6trqw8GM5mt
# DATA +XSoLqWUlIYGe8DDoiTt6SNF/qfO3OGGBMU9J3aRPpEVzHLGDpFUAQBy8IkIOtY0N3ELl2dsEfyCsN54wtxakdy53pXu5GgFy61Y
# DATA AiEVHZADDbEsU2sYqrF/gzcIDctdQgsbiyGZinc1dPpUaFyvi2W3pka95C+FyCwl8E7XwjkXsIAmYMdo21RcmjHo9shPlcisCzVk
# DATA LUoTPSt72YX4S+cygzll2qfawUgyrkjW4xwO9v7GXuv25s7mvdub9/Y1P9PanAWgdvMye1NObxF7VY2jxMaze18A49XcVS8A3+rD
# DATA tDZtrB8ul12qutD+bvIxCrmVpu0+gx7RcQ6Qf4p7D9WdU13gbrATkD4lEzVDas1FXU7mg4QliOQUMjyRciWDa4Bi5O1BIiYRz2Gr
# DATA NDZ8AnrdxBvgsfFDOhD5W+Q6wKxDNc3carRAA7Wkg2F6cWRai9ZS/Nni5efD2OZ+6QLZukhadO7mBjYupga8RIQkpWFq91vUAT+u
# DATA UXSrTBYc89s4/Xn5Z0yNJlw5J1DSBkkWVWfvq+dAFXUZ4cj7zIY2QolZObZ/ZuzGBWCQHQcO+N8euTSXRBZGMhWZ6yEHmwcRURKg
# DATA NHGsJg/uNGd3FJCyhkPFZIupyXzcbbEXlg/IZtbBZPEit65Oe9INiDDanZizmOS7FseOaw2MccGiR7XY4fTz/Xg5OAovWA+l/cHr
# DATA AwbehhXyyb0Axcs0VRHqLy9keNzdvLut7u6oVbi1fe/drd27mx6Egbu56543Nu1394x2v/CUoMdxOSjmcI1Z/gK8gaazlY38qm2b
# DATA nB6wMJDf75H5GMVvbQjXTznn4MNuTh/JuL5gU6JzljWU83EdRXnNcsqFCSm86QtchHO2RjTi0GTbdIQWwAL07lOpkovHbfOgnBud
# DATA yDVGSCnsO2T9BFkCCVtSuHgNBqFQyG1GZx30HkXEHB7k9qiqJB4tezY8e0ZWBFeS4f8EOWGAEVHLrc8BrS9m9X4ELhOCYIiBxrn5
# DATA PBjN6F6WLOQiUzFnf/vyxQVacebRq8fHfc0RTSJNiFLTAV20g3AIusy4MeAcmxMYvKKRSYWj5JEyTj9aHTwbdb7PVTy4Ya5i6+KI
# DATA p4VRDhINtRgJFWbSRz+Vrv6W6o1FBHSJnQWdTvXRLzhlPUiXZBhjPTHJ1CXATB6kgZWIF5TGXa8pXy43JPqCOErSoT8U1ctuO6xo
# DATA kjDh2utdVyOc/GM4JQY4yCkjlRZWXpeuoZRlR+Jy561lhTm1VSjvtLOMHUc1QTDIGl54jtRvmGn1G/U5iMN2pI0DmVoGm4XYqJML
# DATA /JODGNXAI2chv4zyRRfWd83WWYrY5upEbiy2K3Qaj0S6MqtuAz566sd5kOPY4JGlE+eI4TfOPMAzCrKCkKas9xfd5O3k2ptvXrl2
# DATA EW/0zXs/ErKQdUoFT44eKKL7pXH65xHg9kZJhAZUm288qBX/Lr9OiSqK9HUQKFK7G+DOGIfNhuOwKZfJc9B0Dy/KNEV0rfMo3bq/
# DATA t9/au39z79bu1g5G9uxu3t/b5LGBOoSqVozjwcBY9C4U60Ins4W+49BwLwRGxodzOJEjs7vFy1Yq1o/CtLj/Yc00C6gWaRnjObyi
# DATA dpUiG3vhXDobEI0Rwgrvx1iXdQwW3TlstBs79PpufRQy+gKBx4vdInPi1uLJhXx6DQOLaPLjWdHs+7y8aC5Gs806pPew336kaGGG
# DATA I6J2W5jXu5yf3+dCDj/IdHmE5JZIjyv+UEw3RYIg3keXSamUV3tZkneL2Q84iyw4qqir5XD8EIDMBzYCgTCzawImPi3YPCa4zYO1
# DATA eNB5o/RO/UFN/Vs+X69cQWdAt+vlRb/T5Z0NOpmO1Kl52h6VcKq8urXnbw12jjomvdKxUgvtr9vbH9xTO+z2Zuvmne1bPzQaGjf9
# DATA F10reFHQeLVY8pZFjCn/jgwobv670FDmG1h8dj37LkwKlzcRXNgYUWRS+I4yfb0GJElp+rKuWkX1R//sBkrcIpZDhyJkXQiOpbfD
# DATA fh/aS8iaW1v6D69wj5kTXp4h5+WbZi5pGno5hhzHzvLSDQ+hKLy8XDpPfTvE/2nvW5/buK4857P+io48rgYkAHyIkhM4GIciYZkJ
# DATA RXJIyo6HRFAg0CQRgwAGDUpiJG7FzmQmqaSSmtR+2qpJana39rPiRIlsJ86/QP5He1731X27AVKSN5shEotAP+7z3HPPPY/fUWCv
# DATA WbKHK9Si+XuSzWL6NG+Xt25cQnOba4t47QlwvG5nkzK22W5nF7MQXNzy8DIK8anVwul0VDkKzrTTelpF61gk3Ht5Jg4pXJsuqJzp
# DATA X88yx1xowDOMOBbs8UuYJy6nqFcptqSWRC7Q3IRVr0IDf9lkVlfa+xzt/Ved6SuT0dmJvpiujkeuDidxxjLRVYoqHoqYxapUO/O4
# DATA TyUkDu7K/p7UAxWS1RVNhJfl2OvTzqYPgxRur7VQ7HRYY7P/4PFJLVTQEeFkbIgpASEk8t8X9X/tVR3Xpxp6CTpzVMUuUMcUcZ3I
# DATA iN1xqLT67cPBaLKb3PLKZn0JMQLISl+/v7H9oYlU66oA7Atoix29txbdVNC+1RmQ6wnVqmjBSFI9L9Fm0kajW6SOQtCko70cpws2
# DATA 2Fz/rlUok6QVQKyiQf2hmW5basZvWPU0WV7m0fz+4gpqdf/xwYoDd3MRzEnWVXZ7Yz4M9VBlUoMCKoJ7qk6XMoukN1YzqiIpyWZh
# DATA TZFAJaaPWuzJS83pxa+6Fbkzp+LbYea+DdTRrH93ZWt7K0wtRScrdrbWS5Jj2yqv7r7T/TSV2z6ViyZqYRQJTwxao/Zh92Ekx1cp
# DATA ixwbg0G/Hb2tMjdbitY3guM+haZHpsYuZjdo9cXTPUJ1NSc42BvhsjdulFJflt5FN+yCTqxW0VMpYlJsIT8MPXEF2Z4dnO8p5rLY
# DATA RUksANon1KDNqHP6seNuY57P73qJAY+ag4+skTAvtw/hxQK9p/XZSl9i8RUnyRA8IlsHtHXYa7Ujb4L42uF4PKzOGEDi6q1ZDiby
# DATA PYzTrJZBZWSATX2KorQNsGS324H8eOJGSFrxX1X0XQGaj8uSSpx8fEBMJR1JNdhxDO66qmLDdSIIh4S8As/vh3Pzb1Vm4X9z1Sd4
# DATA 9ZSCEMLkCz3WFlexbU44Potb5dGgl2XAT5Y0ODjg0NEnYWfUpTyebAYqK0XPYKiUhE/Co9bjMho38aG52SNWND4uS3/DW+FpsgKO
# DATA 6msfRu2PqIQxjB12NVy6v0zSJVAd8VT6dz9CTfN1mXczGDgKM2TOAll5hsu8XqwA9+kXRrV/UAG9lEtwVBl89M5sda5YrLRJcV0o
# DATA Jp6AWxKbDgWCRINNv01MXkJHzQXgbcil4MLcPIf7jcbNYTTqDtBXKZyfjaHLWZsrjviOmiw4xk2ETsCjHX91bYBPVBhxyk2DpyU9
# DATA zxx/bJom20GybXJZuaNLkLvOOeuoTdjC57zxRL8BrTjVb2GTMMsDTpbx6JIuSAGmaUnZIksj6ywkE7mixOzLRfYUUx20TJgqtsdh
# DATA AnyxOg/SybDbj8Ip+IFiKzQw99aX63cf3MOHj2DkunhkG7eHtdmQBlCxgvDrs9WvE69bWLhVhf+srzPHnSERsAo38rEaM0LkcFP1
# DATA hf1URwMtTpYxxrA6g/+aazwo1RnR8zquwTxcqgk8SKYkRRF2OXTtdBI7ZjmqrOQoOCck1fevx7cpwbhc580qIVUU0kSSiIBPulin
# DATA 58XTvaKDB8BfTl8CAyXT3cpWpuXqQTP1+lMoTzuTlQnqXOaqNb06qKltXqfJsBGGbXTxuv4f5RfXptmygcZlBAzynQ4ZJ2Us5x2V
# DATA d7xk5LZEGnC+IweBMgIp66TietvWzmp0SgF6kdh8OkSWJSKQmNdxHJWR75hfXBKLRcmAcrUL+gLiG7lJxyXJOeUc3yDt1ygC4nID
# DATA 2m0PZtd1IyRhnmDZMnNCOkPkjofpseqrzsZucDdow8hIxF6cKve68eu8VDZ1L6UkQ/jJJahzfDSMC17QZc6SbdJnW2DO9Nvmk1E/
# DATA BvJqtuJ2tyv4vfm51BXNJhul8KMnVW5n/fbm9Z5QP5FyzogoRCHdjst0MrlOcupLosEm+2+plzhNuegCLtEqa6nmNMgCIE22BS9e
# DATA vmLDFWxEBL9L65SjYGd/p1NTfjsUR0v2XqlqL1arThhfYp1jsimWc6TW3FgDiQf8kI5nHsoWmRQfCU3lHDhtaYHzu6s2Aiuhpei3
# DATA UxNLLmudqZdYbrVm06kmxD3U1OdXbY2po2XGgSSNcXKQJzbF2eVSqNzauzKjWcXsdfLko+hEPGMoSMYJ5fFuMMXTS6wdsyWlkVhS
# DATA avh0L/RwKo38zmwjv0Jr28s6SlnkrhxxX8VsGZEj2VUDk5I1Tz6vRAXZk09yBsQHxDtoWJOsJM0mNanZxHXYbEqLcI4xj/cxIbUV
# DATA OKV3ZWvl3nZ9834pML/fe7Bh5//l6/ynwAWUAsm9cKNZxdzfWrWQ9ulgefNaVvpCDVM2VcIwzOAdubCdcP6KKVNsEr81ZO3Y4tJS
# DATA fWur+e7iymp9GaXns9+c//Dsy7NPz57D38/PngVnf4Gfv4evX5z/4vzfzp6f/fnsxfkvg7PP8c4z+PX87IuzFwF+gSv08mfwPD73
# DATA rBLYxZ3//PwTeOi97e2NrTK8+nu49fz841IAj395/vH5J+c/giL/LN9/Dtf5tY+hwl8kanvBdT2DR54FUOyX0ECqMqCXf0jPvjj/
# DATA 1/OfqQ78BX5+DE+9gEb9x9kzeQwb+7lu/ouzP579icqB/85/Vkke/MjpvPkujFXzPvql30VV/Mr7i9t1Grr/DbV+dvZFsLixUnba
# DATA hB2Edv8Bf3LDX+B1uPwFXPoDtAb6y/pr6hw2gi5ZnZy9MzsLTf+fqlg14vT7GTQcepxqsDL1mIZTQ/8XvfIHGBGcECjht+c/g7mF
# DATA Lp99ptr3KbZKLp3/S1bPqHk0aDSYf5JW/Zb6+xy+zt0JvtO9m9kwraP1tUuTSGLyfwtf/ojt/BE896JEd6n6L5AwX6jfz2QYiQCr
# DATA AWoO4+qMuGxFj1tHwx45U6UaRxQqTdN2KWzff+caoFVAqr9D4nFbRpU9h9H8EVX8MTxMZcG8yatfyHR9cf5zpPRkAUSjf6Ge/Pzs
# DATA j1DMZzQSrePxwG7lacJGtHWC2dfryGXUgifnFNQwEEPAM/jZr6FknKZn5/9KS3jiSpHJ/CNRIK7En+Qsa/j678HZH2BOfki0/QXN
# DATA xOfw1J+BfF6c/Y7ucN2/eBsqh7I+p+lVVHb2Kfz5FJuAd+EeEOUn6ON77e+uPn/dn3EPtt6T11vHLHzuLCzQX/gk/s7PL8zdUdfk
# DATA +ltz83f+Lpj9KgbgGLUcUOV/0fm/fv36UjQac0hhFIgrCAp/km/QmBhZjRM9CjaVvUO507DHOQUfdo/oGKUUb+o3F8RqE3UNxXb1
# DATA fRBfIyg1VJz3unuBXEaZVj0y0oUZQUpfOdFfgZ0OUay9xgWKjKwK5CNcyTEfNPliXApIkBZ9IsZoxHGvcAPl0RKB9Ul42X6r28Pj
# DATA gjDsWghSyXPkl8D3fki8UfHFjTrIn8iFgf++OP8X4bzItoVvimyGggNtIl/ig7BLsvjmyHMviPFCFZ9gUfDU57TNPwuTCMuWmAmd
# DATA L+yE0hP09sK+UB7u4fG4hl2CM0JrOMbeDI7HeJHtOhqd9bblXEB4uKyCbQ86edmQEiPkQYStMFaLchkzFNgctrqjwuEgHktYurlV
# DATA 4iQY9tTFtVB7XbGPi3pTVNvwNnoAdR9ysAWdkawii6IlgIIt5Gc6RjivupEw6CrUJtwv2KWHDMBDv8Pd/u5odzacaPE/+5UWgpBI
# DATA ZLtWsiaIFwEJdihIomgtoiTIIUAtP4X5/zESAwqbn9IrQCXp/KNDKyIae5UOZZ2bnV8IbtCfiQ3+zzTtiZggFKwbj+KIajz0raxE
# DATA UJLqXthiJsgfP0FBM7jfvatTVm3CQZX8TYJ4kGRHOPXRPx+jEwK64KKj4nEs2IsKjRPVzEhDFU0ATSZ0mGP6hr5ycJVPxHsnqFst
# DATA 6ol2rnJcgPCB8PHt2W+Q3aM/QGsyfiMLeNQn7fXX7yyQGwMxCl2t6tU6lLK1taoc9+OgQ5lXCJuvG1MsFnpkjAX/+W1YJqidgIns
# DATA /yAaDRQ6Nw6Cfp5XrE68shd2BlHMcbr2sgmVu9nEnuDagV9m8bl9yUdJ8H3SnNJLRig9/h7ZIlJRQk7/Ha4FpC0+3T3Ld5B7FeVr
# DATA PoDjQKvcs1cUHC5kxoyiQ5x7Cp7W4SCvdK5efp4uMFfueRjPRCjt85kTj72f4i5ljShwA7jyjI5Dz1LnlCk45VfSCkmMwrJE3GMS
# DATA QPEBbS+O/CC/eYv8gYr2eSPAeYKJH5KtP9gbjA+Dza1FWrD1peWtxbdhg5JUD0foiEV3jwad416XsB8sdjU83ut124jMmSICuAVs
# DATA zKEHH78RZuYpaaheh1uKnoYthOxnS1scV1WZil8at06rcV+rJSrJXZW/SeklzL6B2wFMw5cg+3xCwg6evuEbn8S9Qs/5j5S3G1rG
# DATA vANlVgsZMTtskE2MVaUToSBTSKXkgLIq9BhOcnM8aMbwYL8TF6hCFcRa4yQ3cw2Md1WEUekPHhUUbVSOx+1iBX9BK46GhQm8i+S9
# DATA zwPSwX3GoyDHfZ/gh+f2n+LJnTZUYF3n/0bqiY/Pf+lm8/DsgdpVf3gyWeCyDC5ZspfZVi8nxsl0RmhBEdVz0nV+JsQyYo3rYT08
# DATA NRLJ2f/goSOR6XfUqDghexFH0bKXJWRptQ8M8MdAw1+QhuSzMNV0j+elz9fSeiHlbYljhnRdCDFSu30IO05lGB2x2aL7EBPP4U8R
# DATA UHodN4O9srRTKZbSnvOpqVpn8LaT+/ZC+TbP/g8pvp7T5vrcEfRQAHTlWVskTI4pvP4nOtzoUSU50ZJnoYMK6XfoyGfc6nQApkdb
# DATA 7+JcoQAJA/QDWPM0SMwZEn1ujQdH3bbUlRw4XY5jARCl//TVQteSwX15s2Qhb1FZcUZs0lCFC0k2Fpf0sgP2Ut0eJvqZjPVxHyb3
# DATA D/W8SuqhEvgxOhYm95ADOqwT1H0OcY3XrNzvBKe5331cCyvjXlwOPbNJsJ+DuLLfQc5fsCsJH+2FZE4Blh61jpLZX/Ca2MtSHbOe
# DATA 2O8dx4eJYCusLz7ptwvqGehDf1CwYmYHsfZ85kmneGFelxgP1rO6QNyNJMbMuRIereGf4sJRND4cdEoSUp5AkrJT7fIDTgyPyqhr
# DATA nQhNEnn7UHjn1tcXPLdNevi33srjsctrW3abq8ALYCv/gzZ8WEc/5KYrayuacQRkL1B2E2ILd+BMlcDOsVVJFQbdEK8uA42jsIDs
# DATA V5l14E7fPyiEO51+3Njthzepm5ZTgJqvqEeZVRHMXXsIwjvaHSoaHXXHHOBceIJ3mu3e4Liz32uhJXnYZWNrSLHXPG9s/NYPSeIK
# DATA fvegPeDX5C0DAOJ/VUGZczsZOD3ZiOhIknV4GodioAWobvfGKlbLQ1ZNKPnpp62ksQ/JCwJGFFmc/BjJD41Dz4VUOPH0hJCZs18h
# DATA cRDNoMjPVATbxfmPWYDHzUdMD78VY8if5UAHNFjW6rNnbNXER8IEwpENW6X6KvgzU4sU/0Ek/fzsj1AZWq8+Nsa4H9GGZy0Gp35h
# DATA d5cJ1HDYLpeGgZCV7w+6/cJ++OSjU7QaP0RfaPaAKDnDr1DqKwQPRjkkhdegX68ltREFlQLFdqYQBH1KOJeK0SIWutBrWIsVZufA
# DATA 09jZ0W/ulhs3v2WuVGwQtMaT+RJi11Bpk8WXLJUtLxrD0w+BM5AraShu6Nza8Cb9vRmSxzlRveqIne6QZrsXG5Q7d881haceV19n
# DATA HrZGM73unklpOQOXZxy5MOshS1ZU+S40F+Wqb6qZuklu9uFNeO1mmPa2d4N1rPwZSW2H1TcoOWZ19PTak4RrUnCzRizlJnIxpm4q
# DATA tjhtc8sTE4BYvjP2WcMORVAeyLxG8DQ3UikrYCFQ6SbVlIeETT6AVvsoKu8w8TZ2NHIfoq5IgZN5TYJogeuQ+8Of8Jz4CTG7PznM
# DATA TtrEYgE3Nh3FazTa9ESuRvsCi0nzQLJE/56OqC+CxaX7da3ujckADpvZMGrDARETcpPO5HHU3qLkDP98PEC3ugB1Jh1ysWuPWTcT
# DATA H0a9nrrP+hMQBFtD3sWoIyYSbXcXaWgXPqEVn3adL163r72J1958U+FMGfrgJCvSYPkbFmcULdwMVaiWm+gv3HnQ745B1li2nM43
# DATA I9eQtr26ZZ+Rd/uL+yDL1CSupjxAETESx65AglKltt3+By3cLbzPEm9yGiPRD9CebfTZBiEpPhzAcw/ut+KParMg3e329ejXrgOj
# DATA 4zG9GV7fRSWRbFR3FhYuMUC0eKYaHjUw1qDAuoJBa/WwTzvbWBK8td5faoEc3mmNajfK8L9g9lZp7nZ1draKfMrp+iYQFuybP4g6
# DATA y1GvdbIVtWu37uBTG6iUxzTm49oY9lgqf4Utmw0e3ahz96RGjY/1wCbGwhOFcKkAhKliD1TEPgcNDEmlZ8sZOpycXN0RRYLVe+ND
# DATA HRE3UpKs5SK5Y3nN21pp+Cl6Q8eFknd1ihngjEWOR34sqGs6QAe/UqdtzPZh2uH+prbGpW8qmVZC1GoKKi/9pMP5j0c0KMm3UGk1
# DATA 9HvxJ7wg9YBb3rNJbVeroqzLrYqj72pVSOPVcuNlsU2262XKS3Z44vjqKlXd5GpsD+mL1WmRkFW1dQJtVZQwCCXLKbRVsUVof8GJ
# DATA IEAWNO2eiKhpl3/pbjB5V50EkzhuetOGr7wT+vxTBZfPgmhlz9oKI9Slz4oZJCPrzpVE3wi+E0VDslQqlJhAbcV04sbctP127xhR
# DATA ewP0zNgbjMM46GHMtxxI4ko62+9OOO6peD1ZllVrMJ3VzHF10inbGF4xQkFRlrzzLK5L+xk37RtvBDJMDp6fX9nEgq6VTHTciz15
# DATA iUV+QT8lhsWyekKyi3MX2+xD0vHKLGxe+PL8x3x8PP93dsygAyYZ5/GACTtzIpUFez9DlTtOYxrFt+1b2JLGFN7Ll3Iqxq075V/s
# DATA KEYu5XOM1vfvMywEJSIUFRmLZPDywy4eVyx+YFJnKZyHKOgNDioJT/Hw7NeWYwuMaBUOUJaPIwGfmRx6UTLBs+h2Q9slRpwXycVm
# DATA ZW2lZBwq4P9ibsfgSOxIzUoJlO2AOfdf0V3xeP9R8+C4Neq8Ri/AfP+/ufnbd+Zd/7+52Vtzs1f+f1+R/992hLbt1qjbw7D6GA0t
# DATA mP9O0F4evPsBSLGUFVK2oxLr37t9Tp6IlogRJ0o9yXMB3G/3x70L+PvFh8fjrn6BwzQu5gEovxEhRim4yGGHA4sm+M2x25/fOw42
# DATA /4Sj3MLtfK+LqP+w9uTGjUFckYA62F9Xl5qLq+Q+v2QpfCf62W2yR6O1j6GP2O/Zqnn+MZ62TTTEC2Vzo9AM+PeXeBFegWl9O/Dw
# DATA 030Quh4hGtDZp+gjQ7EFPzr/RTjRhw/GrGlthwrXXgG9HXbJTGkN8gbZbhwMIxc0VazX+GblUQsYtBrs2wuz08AW8ptjVFb3sUWG
# DATA 9Tv1mEedSuZmLeGF67Eav81P1R8PXUwwU9hH3V4vCddnaskzp7mGND5lGgWTsuNkaqfT9JGvn0ZTLFlfPyEdOpLDFzpYCMjEWLhf
# DATA wpIH24zXkodGNTZ/2+VTj6ez9v1tGftG0d5gMG4qdlqAYSuJiqw9huMRLDKQaAaYxromKpeU6reMY61KQAnouN8d1zIVNKkXCYXT
# DATA qLIM5XG9r4T2Pnf8MKakQKl/KveKo9boI9Ks80sMsMG4BKFoHrcJkwyGu0wOXt8f7MECh04jAtpw8Ahe6g3iGIev1/0oUopKOIuN
# DATA R61+3MVtjw6WSc0jjOLLqx2FE+DUlbJUZDRRtAgTuzc0A0ZN6RCxPVpV6OSexpQFnS5nFxwf1smPghC3UDLnESxyepbdfqbe0C3R
# DATA 1hwidJeMChRyPZDcj7AXtvZ6kaVl3BjE49rMcTya2ev2Z0ZHQXk/SDXDqSZLRUfgO+VjPABZajpLW0ke8daCCjkVMJA9HvWVSiz1
# DATA FDc55LVUoXy9zjxxKxGBn4QmVavy55GtjGNLq0KcE1gBCeVRR22QpYBjZaFpEoYQwfDBOVx+PTrstg9rLDNV6EdJSWV2Ahx4nfHb
# DATA KMUKS0OylVJpQU1/Q6g7d09nNNb9R/AQ1VAI4YdrZoALqR1cCnS3enForvFYE59ToCSNtD8e3aiQK1+M2wHndDiOMT8uD7ljocip
# DATA V9qZU6KnPB9v+0+fSCWOT1+SYPWcHPmYk335tpKerdA83IF/irdlDJUtRA+vXCjDGDmPAFEmH4JL7kyowkRDop+a0C2JdkxwbeUo
# DATA /Sl1i0VLfREdN5NBxjwW2vEj3ZFON26NjprIf9GDQkiViM7dA4u+TVCAgWExBqRp82x9XoRIYf2LwGNU+SolEsoWqHNDFYYSgivB
# DATA YoByHHAwhUU5QmxL8uNFVUUv6IoDvsUyOklg0fag1xMsm3KZdmNqG/P2chnYD9NcjdD3DKODe7TDYIaGIVDPSW2x3T4etdpku5hD
# DATA bRkvHJNVV3GqRtGbhUCtNOsFnAjrjUnrJyXbWBpNaiyc+45gvB4dRn0nVTv6l1uaS39j3NbbJtUcLjHlKs4iebNsyS1cvJB/CIv3
# DATA BYbCfurS9tnztwP2TyKf5s+UBTZThCF+IDfUxS+xCDSTolM0eUA6kJ96ZRSK7njZW5LANNEaQDAwbdN57XBYU4I+ed8VWgrxDAEH
# DATA 7Jpu0WYdwYSX65tT4SxJMdyluCI/d+aqDQ3BpK5V5xqodkUs87DBekT7vs0yVanCMjlYTIqZbSTM5pNEX+P09uzst+TgjlSUtox/
# DATA rrX8xZQbXzgD054Q0NGHoNIbtD9KncvQEZ6QM/pygoRf682lzfridvCUf2wuf7Cpvq+tv7u+urr+gSOpMEY6iI2j4yEisChYjP0R
# DATA nl4Sjq2ESJ7A3FhZ27YhN/IhONIwHAps3bzRXLm3llTafic62RuAeLSiWloo5iOBXKhVfmAQa1TE8D35WIrTZI0ZKsDgtAkXC/hP
# DATA Sa5gXqtm/bs5mumULGhwsF7ewpAazGp2Q0ItxJCAA/9ROOvb2fzvS0JGOP8xRdwwr/Rro0LX7GEvJ8vwcTF7Rqr9k0wOdq3a6GDb
# DATA LiiY96ekVvtZpg7N00ElUYR/bTYGTgdSbh2gK+JrMgHk6v/nZm/fWbiV1P+/NXsV//+VfN74mj54Yybd4cn4cNC/de369eurkoIY
# DATA 860wlSgntQquE0lZzOmICUeeUMgQPX40OD44JIlQS81TGwYOWzEaBPTPo1abLQUIAkN6DNxy+CbqfRGlZRNjguPxe8Aae68CXgBE
# DATA SP0dXa3GXG228QF5hmNtoMqORz2oqzLi1qk6pbElvI0bxzXdAOY9Vi3G4YFgYL13BFn6GmfZJYO62Oub5OoPkpyFRH9taXUFT0w0
# DATA 55RjmlUuSsIIry2tr22DIFbfbOK3zfVVetwVQ1CZOhr0wmtb9c33V5bq7hlMsNGIYrQa8dqDtZXt5ub6+raRbXzOYtc2HmxiogTM
# DATA 6ZhRZvnhHNS8vXivvkUhUqTFkBwancGjPilyKFKK8/UJ4ifnFgglS+KJvIDOHN0+TKXgg3b31Z02kHMfXiheu7/43ebq+r3m3Q+3
# DATA qUorbF6rbTlRz2hwAGMdSw6SkZppICiE7iPM8FIQPTThMZj9G8Mn48NgD01ssI5gHIb8TFySHApKLlVidEzH5NajQMhQRYKr5N+K
# DATA 4mqo1Gx2MXkeXRBlFB+53TQGTkpK8nDB5aPBiWXGZ0Rt4uZ5t1w4oD6Vqlc1QukfzENZChurvINIBULLRGM2bhwTkzpFMhXxrDNk
# DATA Nx4xMYt7UgB4QHSTzqFyb7O+teWK3YkOcyYKNa+kUlD9SqQv7A9QLUYRoPhPwXP+VsU4I2ysBiL5IMj02mD8LpJDIprMKuBJSKNE
# DATA /jmcv4D+kjo16iwinDK0CE/UREkIWk141ALlEluo3VbidVXBjpTe0OgF+BIwC1hSESX7QB4EhBorbcjR4CGnoUedCpoPjS8ULrxH
# DATA IF/GGqmA57SCBuTHBaoJI2idq6pRxXTvd6xeNHbUgw1KUf64MFuiqSgn+2JGplFMFVlhzsJtqcmIuq/VoFR+kZYx52+HUcAQhd3H
# DATA s7Pl3cdz+7uP39qHL9/Yb0hiKnq2CGfQeUmbblolE4PtLniu3gx2noQtM49UEiKWMxPhB+E3/T1tFHfK8wvVZB2S6w07DdVAQdd8
# DATA +dEoc5y84/Np5VKS3I39u6oJhpPmBa5jPD2X0tT6s2Z618vkBZrgedZCdU8Y+kxhe1gpb6pidhv9K53IFq4nqDixnrT2YtiLJNrK
# DATA DNjwkBCpxftTHgllgHGX51zHuiEu601z1ZSVG4Hd0Tc8l8XLJgtdg+riZH5O0hGo5YebtBTpLMqk/x5ChDJTB85t3qbTurrM47ZD
# DATA 41ZteJPhmSEgd5SCLPf4+KigC92hAhu5ZQNzKEzkEcV0QkdyztCNqAWzVa/LR3KuJN9Sj0yKaHnRPnOdbjzstU6CFkXUtRAGP7g+
# DATA GwjYwPVK0v8gn2Qtr8BUwlAQVS1SNptHikDVRrKCY4XZcYisbwZz6sYSDD3ynV7UL/C4+pIlEOlujSl5gfOspAcT8qcDNlWRTJ4T
# DATA jdrM3+ZmZz3vMAFw427QMzN2Lckmxda2aC0Zc5kzHShmWfWz0EShUa81jDGbBM0WvORQZcGqZx/IIT7kilgeeoRE6G0JbV/FVA8w
# DATA IvwIG7KpqMuqV12yt/v0lnIK7LzdA1Jw5CHLyVIpi4FYmPErhI/e4ECYvng6yJ6LmSkxIYwn76HiKpRdIJ15b9roypU+Od5rBC8o
# DATA zpQyRcqriyW5EhnQzuyhw+/3O3716geb62urHyqdqqNsrX93aTVX2ZpCKNCiGPLJdC7CapKx6ucxKBcbj6cEJ/osOVVm8ioMV6TC
# DATA LvVlJ40j+/2aOxw87gEcUM84aUqzUBFgRNo9TBS730n6QVlcyqhW9zsS15+myyZRd4EPQHK2wjiPsQkClcMRSzuFcAdlBM5eNh7t
# DATA 0w4evvlh+c2j8pud7Tffq755v/rm1j+F7NpXOTjiPZ7EiAZ5JfA5BBMT4S+uir0kQh1RGx6P98tfx2hU7HlcC8XNQ8kg0ibleZTu
# DATA lqAxCaVF1vp0iWYqqlzc2KivLSdJMdPBSg83alS5pdWkA3zG+IcCR822IVG1VrRyGlMWac8OvlmctmQ4gUs+ezoy5VOYxcQ4u5dC
# DATA t0qxMrUsMoeYBieTEwoD/GpHShYI3nL4rPCr/KGxxVkeIaU0sXpH7m7G4vOKOLtzDkeNyoO1xfdhGBbvrtbDTBas2pKemkmmr81l
# DATA exUouje/1+6i6WU6R8ORghWhoCd3lo+ABwgEEvkNImYGP+fxG0w4oVS2mitbm/V7BVWIwtrIjGKZYhTNCeC4327xQcMuX6A+HMWW
# DATA a5Tj1sdR9JESaFLvl933E11E9VRNlYOnjYL7tIdGMw04+T3mYGB6UWM4qH7bJWF74F80Jo/J6a2wRzx7Z54PLPqJnSo+NgKprSOP
# DATA oADMD6Hrt5Qj4GHZrD6nNVG/IycZHGTM6VkYhWX8IKNGRIOgcUMA6oPv1D+kWyF7nptx3osOuv1+RkF36/dW1qYuCtELuE245ROg
# DATA hykdlW90kz0tQC74prmrriXoVQYq3NmsLy8ubdeXA6sNDdqD4YkdKRexnYqivoDjD/Co2GBaOWte7ipAqPQ51jFo8el1h9NnqOP3
# DATA RRUA+vhkZ7itBU9UjZwfsaQ5o2S/VD89Wc1EzOGEbxZPVZfUoR+1ylgVpalTNysHvcFeIbyhlBo71TsLqC+ih/RT3ppjkFBSb9+a
# DATA N9BhKvF9X1Weo00gEBdXleBJd++aWekdPvJYYjxt6x5+Z403upGwWYOK2LFebxSLr/ygvO/kL7ek8W6UNyTeDcmXlvZS29PLbFFZ
# DATA u07mfpWzDQk+x7jbP46ueQJdrETB2fx/SvZpn44YLZVos4LMGc9FwO2+txvfKLxTjR6jcWw3vll8pyCQMM2GhR7TuFGEB2v4cOVG
# DATA 8e/d3MBorKncL1b9Oh/DWZn7PEU6eQSk/pT4ylOR8p6awMiniLH0zkfRyVPcMlFJhjHLT+NWb/y0ExN0AHZmZ65BNa9kjLJaYvzw
# DATA fMPyeKNEyLvXd8Ow6H0VGo4KESqhGPxDLVioZgYoJXgqv5NcUylBMrVguBhCERmgNqPwhNtP6E/0DW8Jd/fwBWYDtAElmn5KmJG1
# DATA HuZAF6QXPtFba5H3G/yjfeq5rpK1CTVUDIps40qFX3ine1QstI7Hh7DEf0CqRCCUnWqtwcS1BwQQjZ7CRHbbRaSx3S3EpBmFu3NW
# DATA 2fammqwhlDqgsJ3rwLPe2d1ziBOub9WXNuvbTzcWt7Y+WN9cfkqpX57Kttl8B/bNp/DAcn1te2Vx9enixgpfW3yw/d765so/LW6v
# DATA rK8Vk4VKZbozxZ3v7Y52+42bYXixDkwWKnZ2492txo13oNZJoszTvy+GpUzhIK8Zu3vRybetTtoQUFm/90KXBvLKLyAsD7zekL9Q
# DATA xs1KuXGjOjODQxfPfKvauFnlb42b30qN4bfyW/94bm93Z2e2/E7jxk5QnoF/v1X+b8palHpPQXq1D1ujVhsDrAmYR/+C9URPooLU
# DATA vojxEeMQ5TZgUuZtWky35gP2cXRufK0WzM2/lSeyaoFuWY6LgSSBjDnquxWPGcm9EmwfRlph66juWFOJniOM1U5uFRWE4RN50NVS
# DATA q5MfHIXVV06SOmbdML6BkCOqsXhJfT+Vw20PEXvHTe2I0hQ/lYKxwG+yETw4Oh6j93GwSq8QBn0J29kHdjSmBqP3BDsJwM/WmIHn
# DATA g3HrwDK9DwdxV47KJtqTRR5KcL+E6ac26xvrWyvb65sfcgrW8fio1Z/RqDdl3dyk/SwTGw3ofCbxG2lTN2c6o/hmfbW+uFXX0Z7K
# DATA rCdOKwWjeApVUibY6SoHIJUc76FL7QzVOPPEVHw6ozyDZngu3tFuHU1y3ag9SXrpn1pO8IxTFteehItt3IdQLYIOHBiQgvioD/sd
# DATA qf4mSbQlTJIN5ZaXxEBYRYG83MZroSdGN3wAVFhePJAUxGYK7HNEeMpvWo6f4r1T0E4eVsoMFMJGUTwc9OModQKV6ywTzd++I54k
# DATA eMTUc43bHzyOVnHzxKUmkEbeRTPBgm2isrZheb5EqJeXoRhYCtRHKkZQPVoHpNQylFxI1ApPyNYvviIJMn+42wGerv5BPtk6SERr
# DATA jtw6O6PWPtpaujGVRxkdUw8NYUdXWYCdJy/TccnrgH1BL3Qn7EuuCUNST7J4U82YCVsg8o+KMyiw5dLf4jswPHbJEzrxfn1zC6QG
# DATA rXwb0bl7fAysu3DUGiKiqpSnQM8xq5dBSeqfFPAlpNO5hbcWvn7rzsJbbMnAq7ATUZGXaYuMHTfpZlCYLRVhHRQWgjKtDi7XhM06
# DATA 7jTVXIuN/9jl9ekmTfgoA1BYNH4SIEzLGbFzbzurmHClFaruVMOwtY1JCYWqRP63Vq+DyO8nmukXr12XDDiVIcMqnhQXolRUShM/
# DATA f/BgZVleJfGCvk65sv7xQX1rO7tdMVwa2m4oTRUxzwns+ZfkVtVQwNUJ3m/iAOFxArtm4W7Db9dEBn3O0z1NrxB/sLa1+G69ubG4
# DATA /V7otGg6u6Z6OGXVTHv1mTHTlGQGy4Jm5WukPU6iYZnnswGxLCLRRZVITZW0ZFoV6e87s42E0o+DRcksZ2el1m8Uma8vbmw0+ShF
# DATA YrUP4ws9nWsB90Tgs2x9klbUOH2zQihQD+GqXL9naq3hEWIfET6f3Fk4VZoG0TCku6QUAQSTy3mALABZYSP8NOpdb83nEtH9la2t
# DATA lbV7agBkV0YtBWK+HrXalX70SIrT8L+lQLxuS8r9uhIftkDyIGms0z1A0a/o8R3LpvsSiO+sdK1y9acJFG9VENJUwV64xVQeA5kh
# DATA S+qLbQRBcTHWyOA7CnAQ3QMpVNvMHDqvEOqYOLIDJxFMwEL4cNA7PorQEXjHcRHU3pE79DqrougbJm/iErv7XuVKwVoC9KQwZ87j
# DATA hBeUjESgieT6lXLARhYzbelagZJ241aNVRt5NSyCVDLfKDYsTY9ehjB7J0M8eIV73b4N8ciAcMJsigbwsZquUtyrmxgnAPeRVZ1e
# DATA 83kv2F4GuFXsqIY0fNGbDr1LVc376w/WtrHid1dXlrY9ydCk+IThjmZP6b1UrT5Kd7cWhQhsVaCGhPTutpe0zk+Rlbc740VcQeLT
# DATA V2W5FH3ayUUQZqXbITgCcbKskjn3onmfZOreZ4FUFRKEpImVn6dpwFcE3I06TdlIrdzryh5dzES1kIDtwgTMV1QSwBEfCRvzFgcF
# DATA 5i+kN1BunQrdIomFmwCkSAPexl1UTNgYtzoARoJfgvJdMr1bXePoCl+/yBGEI2LpJXt08BbpOFKNQvAOrHrQL4tnwm5frhEsrQvH
# DATA Oz3WhY90TeTFTCABGyUJPk9ObSp1pMEWSENllBg/whJB8l/XGBphudwfPIIv0poLlzTikcosQR0KCCAFJFjUyY9PRGC0JBdLA4QA
# DATA uIh51kOOdaLzngIvpE3tbUV3GNPZ6gRjxI7hbTVqwZZNw611QJkipk48kL1x5qQhcERNJZu+lICpsDW5Lg+jMnEZRnq0wV5zBTN1
# DATA TUYc9oHIlhvzxDVp2K354Js1VwCqBQuz37ijMcsPjU1BdKOMY7w7Iogd0gehe37YKP4VyU0qZUNaRtI+mqSRquqY7GazCyu22YQm
# DATA 9PbZtmxHLMPFSjbZ6UfMEce8YZ9zdHUkclFdaUd46xxhl5nc96zCWg8jaXdKNeEMS1558m4iPsGErLO+tJNuMxm0a8lWJy3ukls+
# DATA 4e3eVaFdAj2LQgB6aXOEkxj+A20356eAtarW+OEnHMJbW99urqzBQXwVvcFM1UpNxCXvhPLbA9OResIMCzp0CcEoNSW6Adjn4cnx
# DATA Yhp3Dp3pfRmn1AGTBpYpJ+UDkBsj9go8nZR9IFDTovS3yZAtGJIwB5Q4rd8YSjBQhiIu1Ie9+QVMP4KPT+e65Vd3JAc1c7UVQqyK
# DATA +kdTkwxz8Q++DMXrnoBEw/JnQejYcUPUi9TyRTR0Tb4s6aVugDwTkbOVHiWOsIotOn7XmBCHHQuwiIQjU9LJAz8IFjfd3GDROyCu
# DATA U0iXf4ZklqBMNw6IwhxhzI4jOoCpgEc+4FnxR0HZvGsHEsyi4vGt+dmMOBV8R+LeqMaaip8UX4waUOh2fXPzwca2w5l0k6lnUArD
# DATA joMEVdXtQKRwO7GATXjQFTupgXRXnzvIHnaAqpkwATA+OUDS3zQdMOUYF4cSnMJzfmptV+nwamGi7cNWP809SWdMBEDIHmxCQIVx
# DATA q82YOF4Oo26SztRinFnBXHly3cYyOgjcfbD1Ycr/88QXSMXew+luVhDx8hDEt+4PInsFcr+LvsnwlbJMf7JcOrM7Yrk6s08n+yjb
# DATA i77JzoY8HcyZNS3pTe6iO5sJVdXBxep8oVCWrCMHyOwHo1YnmmJvz+bwxHC8nAq6RkoIe/y5oyBRDB41O92YcMscqKVURzCEULWT
# DATA 2AVWyKR11OpDcR22eRGxTuzHxuK9evP+yr1NcjGh7qxsOjwhcw3gz4wVwLdeK/2LN/nUO+fkxWOpA30x3BnxOem9t5az93pfNiyT
# DATA Nm79M9ur68IiR4JBqPond+wSG5ZbQGLX+mbOrnWh+Z9+x9CObEn5izcKDKjjMHszD1Wb9ViTWzXCttHXmVGxYxGtMUnq3dw16YnY
# DATA TuTXyKTYDFUKYzHmIhWKTq1MMG8IBmgBGNrQHAeOlO3XQsJ7GsTQqLa4QH1D0Jfutx6jEgxpAB9Iqufopbuo/CGlXGZ9AlKHu4oR
# DATA +0oinWKmrGgk9eOFbidUjBYuoeig9xNHu+Q4eviIrXBJrCqH8CYIZnBc3Nxu6ggikZdq6VCna353T72zTCmqex4chWU5+ZQbT27d
# DATA Od2VB31RXRcg4Ywl7nQ4EWiigqEQoNYVFnCSHVnhkgLCKz8RXog1X3oTS2zKxeqEA2Z6G5vm7MhG/xSIAepHhOlliaDOZXQPTKil
# DATA VExbYUoqLSYLbLZHkUQ/kUQymVlydB4hoZiAP2u9YG4bcUOcbkGkqdttF7IUPwvY0ceghqA6we+iRyDJjDCkRaPWbs0ePrNzabhv
# DATA awotUaPoP/a9YtFVj76RX9UYmLY0fHLIK5F4X0ryfeXniJcS33ybhxbDXoYns2OUJ8JVp41nwNadpdUV07d0+lXecZWqknBt0Cc0
# DATA bOTMJvlDSME8l1nl0pq0lQv6e8O/EyZkoxuc9MUvE5ygQwEOUKfbr1lvLtffX3uwukp3UC5Q64/zTemfPhHirbnZWb8MnrOsl9bv
# DATA b6zWt2nnd5f2dPRgoGWUPGEypV8wjupyEk5332aCfnKSAHmGCZg8RCpcHr4rEeRSghWt9/WNuqx3r8AhnMkC9Wh48ICmWGOOteU4
# DATA pc/MVav7sX88B60MkBHSDd6ZTSauoXwATdZuSj9ZXe+unzTwekrnLuKUW4g7NC1KalibYOztxoKO7h5WsAkNs5JuF62MSQTO41W6
# DATA YY1pgkN8ng6IQQGfCgxATy9qQQsRzmxvNHgUY3Ji0Vog9AxSwDjqnVT83DJLHZJ54M++OZWVJVtwc8jDY4mB4bKmvprrRuKsIoGt
# DATA F++UKbTIqM1Xy6ZmEWoxv07qMlkR3d0pncfpeDSSyEN8x5gFLxgiWswq1qtLvnFDcl6GrYfQeXJzqOqXxLVcnGt0k4zbjTyYPshq
# DATA XDN4KAnCZslYPCinttmvrc49mGwqGSrHBubVFLWxnZkSOTabhW6/H/mCcuk6xYkK3AG7SitH66QNV3BACbC8lAYhdwBzkiA5OKA3
# DATA PXKLV3RPImybdiZwtqG2AmFK4diwcGHdX7tbzNWKeQV2lYcMKwZRa2U9Q8vkjl/u7uYMs0N1nkalTzcyl4/JZ4DKKgU3mv4AV1PV
# DATA hVss9a/S+dLZ0LSWXvk6pM/efKdJrvwl6yRuYinI0aSUeTS/vNY5Q+0yib36DdmTdLmOhuKl9JmXtLTnNTCzcZPQBS/VAe3YxLOO
# DATA 7jxqtpMMe7qq0H1irf5BfTNR0RvBej/SmLokaHx/AB1t9ZAfx8f7+912lxy7MK5PxShiiBZqHXBUWnCAO+zGBGqTCkW3gbpsjifo
# DATA ChqPUsEsVKfnYULsDkzXDrpAWSiXxWqZrkjpjcwQ8JdH9spH+JryzJBRbo7SXXu+8oHJp0hXrq9G2570ZxXW4+/TpRTxmZLIV6N+
# DATA z1J1p1TyfgeYUqYafqLO/qtRzdta+b8WFfxUMu6rVMhPcF7CgHPnoQup4XMJ+FUp3y29+2U07km9ddaO/tJ+Z1Nhk+forLv9/YFP
# DATA My9hpXlw4SYSiRGApi4jPrygnhvv2yYEn3Z9AskVX4ninFoh2vPJJPyKFedNv43eUmsylR1Up1THkabJqNhlyKIOM19Rq1Nr3F2J
# DATA 3MCQ9GvWSPv3b45SS2aNtkAE1te3JR7H4aLmCRHEvr1+19knbRwCCmJurqy9u958Fxa4lIeUXcyMJ/EUUF/b3vzQLoEIO+HAlZgm
# DATA 3tNxkkwOh2sXOv+769PNwWARn+m5nSvi7DcmcQ/n9vn0/GeUl+tj/Ol4MGSci1RKwFoOzMRUimdWboMAgO0rq7D0hK5cF96giMIa
# DATA RhVOE/IzUWNNtCzqavru22u/kaWqNiADxpRI9JPxNHmmdwxMwA7zAr1A/EhI2h2aX/cXjuY5VrTuX39fJaYx0/REfz2tSmKbJ6rA
# DATA Ux3iAa/IPf8CPt3tX9chANnt8GWVtjamVIeCb5qjkLfe4oVcfdTCxAPSZn1x+cPwIk250LHsEsczx8FeqEBPjmGVX6uZ2buko5MN
# DATA 0uCpndhUKsoGhQJ9Z9LJ6NLVvxHcZa0y1scpdgkX/6h1gsctyrjUCvoR4sYPOUuMybNUuTZRO6vpWQa05qcrpaJRTyky0MIuFZfN
# DATA Bl8Td/6VYcZOjjXMKlfFXJ2YZ+752RfnPw94J1Wt5nQw0/Fdc4LZa4FkVbK2LsuKqQAe/dzYNg5+VWw5k56TyxWXkH/aL0TQgs3R
# DATA vL+ydX9xe+m98GVmWRIr4ST/+uy36Wypf6RMqZhO7yecQjCcMKkTj2vTmDwniXoJs2u+kOcvOlPnw/V6sp2knX7yUxEVJxafzJ6T
# DATA yP9gpdFJOmxOTqeT71/gtwy4iUYwJM7OUeRt9WmGuHwJw06uNuq1GsHfIJQ0OXowhgwGEQakYe8EeyccYzocdPvjSrABg4CBxMEG
# DATA KVpm+tEYD9meUkXZgNGpgxKdb6COoD0YYl4zrejsdFsH/UE87rZRhTke8P7SVmnRL2Wyz7DHN20I++nVoNZymGj6ujQvSpE/+zZL
# DATA zYzDYTalqcLrM3janzMZm0padu1V0nOKlklxzZNCAfhbH25t1+83NxaXvoMZU5RnExwENx5sh3k99eZNtdbAEu08G+4y6HeYABJG
# DATA +rdu59VE4z8pY6u1TamErXLq9SqsLqXek4FLBrwlEqFfzj9kKgkKj1NK8X7UjWEQDlzwn5RKKfNpnQOm3328RfiLBTvHZWX7kFMi
# DATA HtzvPl7pl5wEmBV6iXgVv6rSAxAwQHNMr8a2cga1gWjtkRWXdHGB3aDP0eCloNXpyHqPj4fQKooE0S8WPe8geoucTgu3UzZJT9ka
# DATA PgraXqCYe2kLD4nkDy3404oW7bwDzA6PoEwoRlSdKfOqswgZkWDYO1GxZLAESoQhlnhrb9A5cXE16CF94vTYI6J+p6lwBQv4VNZD
# DATA DKZYCJcYQrOMgBgqI6YCVPQoKT0FOBCLJYJYJLSFcNqqV6P+wVhJ3GjMwn4n/U3pdfN27Ov9IzJMs4hBZThDfkiTl0V/dmB8PlHZ
# DATA cABGPGPchmmQ532maIIVQNG0NYqaghZArZHeCj6CDUrMEAnwz10CJKaTD9VQzLbs0r5HlLcwewsFLGXeCt9d37y7srxcXwtPp1Dx
# DATA qtOFykaKPpr36tvsbUt3WM2M+WJZjgjz7eGmYfOIacbjJr5w/hDZKerndAQxCj6FcAaV3BzaP5PpZ5vXGq3FxqLZCpsos/FqW3oQ
# DATA ZTZUoTNmtIffbCh4p5l8XHDGT8TT4fzriyDLHlOqntDP+dvs5YeRCU6ieS/eGg4lf8naHXdkjoK9FO17Io+nbNnG+tbLNq1HHFlT
# DATA mMWEmpjAMc25dxq5JCblMba0DvN0eNv2qNWP96NRuY6bG8cKivpN3gbKqHRjYI7dsVHNzQbfxFNLwTxDKksXJPeVEbPgfFoIiDx7
# DATA tO8Q7GeiLcVcdwxLhMWSFSIcjc9Y8EK/hi4QhHdCcfGCS7YZPeySeuH0q16yPsKklr4kcdLim2m1OZ7yb5Mq52/f+RsiSpwxD4aD
# DATA CQ17HbRpOLXE/2ODdlRbGixGO7FC6pJpV2N6sp+/1N6QSeQsFl6R9/8P5O2qcb8iwrZpOmWbeRV0nC1TO4eDBedwgKa7d9cfrC0n
# DATA DwevVS3qNOgb7MGjFUC4nGzfUtb3LMA+ladGMn26hC4pOY/WWHQGTZAHER7OOWPa95En+B9gtYpyzOFpSnvN41MaEdB6RUP1EQlb
# DATA 1/1YgImXfdbO5H36WZgctiyYglvrS9+p21Rul+d4jJLHja18GisFFLvolJQahjHX6aGqt1gFdH3HdkwQRRX9ae4PKFkQJVjtoj+8
# DATA JNdEOmo2UYppNkOV9XgUkyMHrD/6XlkcHRwjjOEG3dGZttBC2gQZqN1sFq03MT9ZsyWvFIyLIzlvbpAGXICG6ReczwbD8Yx22VSW
# DATA G29h9k7bPhwgsnGNQY5JPDROkwlkA4JJV0GnMBRlhYRJz6rQkkZuN1QcZO5DrDwvvp11v9fai3o598nMll8FeoNmF0Bq05z7gt6b
# DATA 84TgUkojJJhVnqU/+LTSP2GoKm2m0XFXbKyzSXTJLXLzrT/Gs/jmMee7YbcSXtsathpzhSCtmKQKUFHFDYU1cUDXsswb9BabN+gr
# DATA DJh8o9mR7zQT8p1GXaGj++tlCrJxJhF4P1mVBD/Rdxlp+SWjml9JijodSDcXwjVZ9VQVyIowxRK2pimrWCGHVTVs+YXZayynRIM/
# DATA QRfpZ7dj5saHSs966WRRxWt/d/W5+lx9rj5Xn6vP1efqc/W5+lx9rj5Xn6vP1efqc/W5+lx9rj5Xn6vP1efqc5HP/wUxcT2eANgO
# DATA AA==
# END_REMNACUST_HELPERS_V1
REMNACUST_INSTALLER_PAYLOAD_V1
if [[ $EUID == 0 ]]; then
    bash "$directory/installer.sh" "$@"
else
    sudo bash "$directory/installer.sh" "$@"
fi
