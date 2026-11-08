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
HELPER_BUNDLE_SHA256='3473444232bfdffdb4efbc568d882d341d815392bf7902383bb57e0318a2fa52'
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
    if component_installed panel; then panel_available=true; panel_install=false; panel_note='Уже установлена. Обновить: пункт 4; удалить: пункт 14.'; panel_upgrade=''; fi
    if component_installed node; then node_available=true; node_install=false; node_note='Уже установлена. Обновить: пункт 5; удалить: пункт 15.'; node_upgrade=''; fi
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
    terminal_section 'Обслуживание'
    terminal_action 10 'Проверить выпуск' --check-release
    terminal_action 11 'Состояние компонентов' status
    terminal_action 12 'Управление компонентами' ''
    terminal_action 13 'Логи, запуск и резервные копии' '' "$service_note" "$service_available"
    terminal_section 'Удаление'
    terminal_text 'Данные, тома, настройки и резервные копии сохраняются.' '      ' '      ' "$DIM"
    terminal_action 14 'Удалить панель' uninstall-panel "$panel_upgrade" "$panel_available"
    terminal_action 15 'Удалить ноду' uninstall-node "$node_upgrade" "$node_available"
    terminal_action 16 'Удалить страницу подписки' uninstall-subscription-page "$page_upgrade" "$page_available"
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
            manage-panel|manage-node|configure-node-site|change-domain|show-config|install-subscription-page|upgrade-subscription-page|uninstall-subscription-page|manage-subscription-page|configure-subscription-page|normalize-layout|cleanup-backups|install-panel|install-node|upgrade-panel|upgrade-node|uninstall-panel|uninstall-node|migrate-remnawave-panel|migrate-remnawave-node|migrate-marzban-panel|--check-release|status|check-panel|logs|start|stop|restart|backup-panel|restore-panel|renew-node-certificate|renew-panel-certificate)
                [[ -z $ACTION ]] || die 'Укажите одно действие'; ACTION=$1 ;;
            --page-id|--page-operation|--panel-url|--panel-token-file|--version|--component|--directory|--compose-file|--container|--project-name|--domain|--subscription-urls|--subscription-port|--server-ip|--port|--proxy|--node-domain|--email|--tls-method|--cert-file|--key-file|--dns-credentials|--panel-ip|--backup|--source-url|--destination-url|--internal-squad|--quota-mode)
                (($#>=2)) && [[ -n $2 && $2 != --* ]] || die "Нужно значение после $1"
                case "$1" in
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
 for key in ['nodeDomain','panelDomain','proxy','apiPort','extraServices','version','image','ownedServices','tls','subscriptionUrls','subscriptionPage','subscriptionPort','subscriptionTokenUuid','subscriptionMigration','composeEntryPoint']:
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
    if [[ -n $previous && -z $NODE_DOMAIN$TLS_METHOD$CERT_FILE$KEY_FILE$DNS_CREDENTIALS$EMAIL ]]; then
        if [[ ! -t 0 ]] || $YES; then return 0; fi
        choice=$(ask_yes_no "TLS/XHTTP уже настроен для $previous. Изменить настройки?") || return $?
        [[ $choice == yes ]] || return 0
        NODE_DOMAIN=$(ask_confirmed_domain 'Домен ноды' "$previous") || return $?
    elif [[ -n $NODE_DOMAIN ]]; then
        NODE_DOMAIN=$(ask_confirmed_domain 'Домен ноды' "$NODE_DOMAIN") || return $?
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
    [[ -z $PANEL_IP ]] || node_acl
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
        choice=$(ask_menu_choice 16) || return $?
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
            10) ACTION=--check-release;;
            11) ACTION=status;;
            12) management_menu || return $?;;
            13) service_menu || return $?;;
            14) ACTION=uninstall-panel;;
            15) ACTION=uninstall-node;;
            16) ACTION=uninstall-subscription-page;;
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
    if [[ $ACTION == install-node && -n $NODE_DOMAIN ]]; then NODE_DOMAIN=$(ask_confirmed_domain 'Домен ноды' "$NODE_DOMAIN") || return $?; fi
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
            case "$choice" in yes) NODE_DOMAIN=$(ask_confirmed_domain 'Домен ноды') || return $?;;no) ;;esac
        fi
        if [[ -z $NODE_DOMAIN ]]; then
            [[ -z $TLS_METHOD$CERT_FILE$KEY_FILE$DNS_CREDENTIALS$EMAIL ]] || die 'Для TLS ноды укажите --node-domain'
            return 0
        fi
        domain=$NODE_DOMAIN; suggested=http
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
        ((cert_status == 0)) || return "$cert_status"
        lineage="$ACME_ROOT/config/live/$domain"
        CERT_FILE="$lineage/fullchain.pem"; KEY_FILE="$lineage/privkey.pem"
}
acme_certbot() {
    if [[ $ACTION == change-domain ]]; then
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
        helper node-proxy --directory "$DEPLOY" --domain "$domain"
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
    [[ -n $PANEL_IP ]] || { info "Ограничьте TCP $PORT адресом панели в firewall провайдера"; return; }
    command -v nft >/dev/null || package_step 'Сетевая защита ноды' install --no-install-recommends nftables || return $?
    python3 -I "$HELPER_ROOT/node_firewall.py" apply --panel "$PANEL_IP"
    info "Все входящие порты и ping разрешены только от $PANEL_IP; SSH сохранён. Клиенты VPN должны идти через главный сервер."
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
 if owned is not None:selected=[c for c in peers if service(c) in owned]
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
# DATA /zn09S+UIaOGfP+3MiCmzvwX6utX8Onn7//393/z/q/f/10N6OLfYf2Xq3g8I5E/XeD1sqQhfsf3P3ZbzXz9n0avXf9D/Z/v4h8W
# DATA KNsgT7ak423s+BvtRnsYDTuNftzqdNrDXjMedsPmaNjqD4f1XtCIt+Nms9uAZ/1WrzuKusNOrx33m72o02h2m8MNzH/cIKfxhrqo
# DATA Z0PuU9wwN/dsUDVF+KHV2u5tq5zJDQuOXr/RG0VADcEwCuphNOq2omFc7/eC7qjZgLf6YafT6neiUb3X7g1bca8eN7rxMGh1R0HU
# DATA 2VC331C/+qrTIhB6/VYBAN04bgStIIjDYbQ97A23g2i7F0fDbrPZDxvdzrARRe2g0eg2Gg0sZRVEzXYraI/CetjdjrYjFwD7rr0i
# DATA GLY7vU4BEHFv2Gu3gyaMst0b9uNRJ+h2w37QjFvtECYctZud1nA0HEVBuN3frkdBP9xu9ftBe9hqN/rDHBAFBb+KgGn0eu1GEUqi
# DATA 7U69EcMqj2BRWr32sBt1426r0261R3jJUlQPRvUm4KzVbwAimiPAVRw1Gq1WLx6FoQsNs5/BkK7YXAdJo1NIHf0WUEa/3mrHUbcZ
# DATA dDrDXr0dbTdagKZmN2iEze3WqNfsbg+73SBqdWLATLvZbUf9Xq/RD6OWCwndczcQIbwGknavW4iS7WG/0YzwYqmwEw+bUR9AGm5H
# DATA 3X6n1xp2onq92Qt6w7De7TdhFbc7nbDfDKARbK+wF4UFgGRrIOh3C0kkCuN6OGz2O6NwFISt7aAT1re7QAu97WG93usOG414OAo7
# DATA 3SYAE2zXt4FUw3qvNxz2ev1OmNsooCoDCHRctBiKVr3dLtouo/52O0TmEHW67XpUbwIKtpvNUdQaDZvdqBG3mu3OdhCP6lHUhK0N
# DATA /KMzavXCuAFL1ekHeTDmPxsG03VUAUyqWQADjD1qDYfDoNvphvV6fxT3R812rzkKG/VRuz3a7oQxrEa91++PRqNhP+g3+73t9nar
# DATA G7frwLxcGOj2vRFoOTdgR6+BZLvVLOQdQR1v6ur1h8Ap4n633+jDsrRHPRgSmFZr1G/WW6PWqNFpx41+IwKO1ahvt8JoG1tudwsA
# DATA ycDoWrckreLtOoQ5b28HrXYTyL8XdmHSvbhbH3YA6LgPv7c628DXO83GEPAZbgdtYPyddqcZtiPYWr01UAxC4GXj9HINNEBo/UJC
# DATA bXSHo/6o04nrQRQPAe297e0hsM2oFdaD7rDdj0GqAAsZRkA+9X683QVNoBt0hsNGGMSNugsO6fsDyclMFrfrti0QXdGm6UcN4Ath
# DATA A/7X7bTb3bDdjjvtYBR3O716J25EwFpH/UYnhj0KBNvYjvvtOpBqr9mI+1EOFmUZF4PQawFPKoIhjmAXNkCqtQNo0w3DJvCqJjCv
# DATA ZgjMptfdHgFfAZbVjJv9CDZuD54DdGEYtEDc5YiEi5cOSJyvw0WjiEpgM7Q7nUarH4adVhz2u8DZG/V4uwHEg5s9HAKjAoLtdkb1
# DATA uFnfHrVQA+i3EMZolGelttW1Tta1YXULeXoTZWwMA4dBtxUGzRbQbDsKQLD1ulHc78C27YJ4b3fbQb8Fsq4LjA8YTgQvhY3OekAG
# DATA 5hrLdWtULyTZfr0R1ONge7sRDNvtRnMbmG0DFB34od+BvQ0YARIdbgN7afTCIBzVu2EXNJBmvb2NVHwPSFGKFvY6Vg9btGgHtfv1
# DATA DqAjHoZAv90IpHCzEYxaXSBS2MRdQFu/W+8CdCCouw3gewh13G70mnXYR/cslalfuI7lNuuFGwn42zasQqs+CkYBsNEgBKWpDzQa
# DATA NYi1dEG5ikAeAU01QbcfgQgadgGbzU4chKC73QPS7B5Z2Oy3u0WMt9UEWLa32/0uMFtQTps90BpHQCzbXdAaR6ADhMOw12t2Gt3R
# DATA sDEEbHVg/UB5qQM9j5o5fWkxXiuL29uFW7rR78EcQdyCaB02mh0gmzAMW3E0AqkEW3e0DQokEMioHTXjYNjvR9CyBVgbduu9Vo5e
# DATA lqObweUymEfrOC2QQ5HwGbWCRgu2bCeETRQ0Rp1t0HiCoNsIG6AnjUbdUbgd9QGqZrsB+lzYB0063O40YF916ts5HLCPaBPWYr1K
# DATA ABZArwCQej8Mhq2oA2OFwQgoIugAx2iOOs1+AMyj1Q0AK01Yj3Z9G1grUHAMmlovaoyG29tRvL2hLz4gYDb4YickRvp6zffu0sao
# DATA NWsA/oZ3533vD/8+zP43Cvi/wf3fXdDO8vY/6CJ/sP//bev/foa1IoKprw5dzCXhTcr/YumgZDJZkspR9dPRiGqkMT35YYr3CN5X
# DATA 95ev51Tf4vl8mqovlz9LZuozXnQzTobqa5L+7sWBr5aLZKzrAwdz9FPor/FkZn/nksGYn3Cyt3+Gt14UOcxK3rPj47ODE0zOKH0z
# DATA /b5/cvDiaG//1enZ4IuD5y8PTk4HXza+gWYHR0+pzfd9+DRY12rvaP+L4xO60ZxctXhCbD7cKH86qfw5txx89uro6fODwekXe8Bn
# DATA d0v2LSClH2xUvGeHzw9OMR2llN/gJc7zFF0Vv9luibzTvOg3R0+wLy8uGYsN39GGLN0eOVafcsJEt7Rsb+XCty0vZ6CcorsC4cwa
# DATA eb0SuPJU62OElgJHCf7uWMc0IUtE852WK1aJnpBYcM53y5bC38VPhh+1x6pU8V7s/WRwsvcVlpbvukU06BEuODxr5h7lTpZFZVxs
# DATA VdcQK3NHcQhwlJ2KGBIZoufqipMhX25SJQLXZerkthKrU3lXtm1NjvhSA8yoVpflyvsivgevY3Xb8o63tihdiWpNqf+UP93ZtE4/
# DATA 4Pfz2uaF/VPl48qnJRUjvfeMg9xfIMxLoNLFmTBff4A3JMTqOg9J1MSwz4KujiyXNtUhGsq9GCV8RGyxnMHmxRrjGFrBCK+UXsR6
# DATA REkG6MB6jlw5ptzgOkUV777qA+rspoFGle6slXTXzjoyDHgnTcJHx+b2K3jrL+J6mKbjsukUfrVmoktlA6nQphN0skTYtQmMH6tV
# DATA 5B0aYkpTmXlkxf+R37hvMZ7qm/lkOUZpuojn5oyS8FosOjJ1wmz0tSrtfTlPLlOVwfNlD7ltLZ5GnL0DbPnBHONDcztTEYRqoUgc
# DATA JlN5eL6ziad6sP8LBgmfF5VQRrDK+NDOKkKR8XTvbM8vSQVFe2Pgw/29/S8OfFsO0AZR31vNO9oL2G+l8piT9a+m8ZsZ3xvizNKX
# DATA q4rMeuC8WGTpSjlMBJRZeO9av5ALGY2OIWMF0xAUCJcf8XLO8fLwWZnZkP8J8yOhTwWxQ6Pydg5Ci5Qr53VZkvJwo7RROW9caLZI
# DATA xaE0u9MJLfcMAAIFuikW0xsEb70E3Lnbxs8wXNXeVaZOcqCqp0yCN8lkOdlVTN5wyAcLbuaPlq/i/wvGNp12wIphmJOyHAdzqulg
# DATA zvhbh86RGnmAdAbrXgLiq/hBhs3iYGLGoivwduVnOoVQlplAnw2Hdkg4AFeQ54+Al2qdLdLUH2OmjUsleVmnr1vgOhnleWBdsoDD
# DATA 4w8weqvZ624/BlfS0cr4MmPrnBv2rI87xyImcU+8LbEZS3doi7CpYhV/E4Yr6Vodd3RdKbx6rt66eHBfvZpmy9mMslHVjlJwlyr/
# DATA +hKWoVMzufj2srYYKke7VaM5yPqgIVlo0YXjbrUX7pix7pTssUpP0VNVeUr2G64tKdz6VCGXRFFHO+Ub0tj9YOblCltRpYrnpsop
# DATA FYBP5aykjRUjEVfPnBDdvIA1hp9mt38JGn7lL0Xp/EvWOL8BlbMiR0cfIQ4d7CJQVDNnRdZaWORiFRqJiDJSW2Rz6B1A3iXeAQ/T
# DATA BfZgqsd8KNwqZ9aFG5OTytwxw4I52ZmcO1wouOr+D32nEdKBYtgfCAcWyjO7IVtO3OEdHZAJQNXtQAoTK+ERfIxpax0Xxa1gySKu
# DATA FC8JZcDWqlKWTMomOnLwLa7+DoswOj2vqzPxaR1d5IzOlssBnrfFZo9cNiZpj6tVeuwzQA6H19v4Tlkacl9dWZREmoRduUjYt9OL
# DATA rvjLVgtJCqxT5KoZxJ+5RV5BoOZF/Op+PuA6XBBPDkPwo5SLqOE+KDkiRljNR7ta4GhM3H+eeVXb44vF17Aep+dVFqQvv7TFMbXm
# DATA IyuVlXrzcv8lQu7Su4XclTbFlaLWk7y6mnGC95UC7qyLTtcQv75ub4VsgH2Z8xwy9XuIzBSP1i8VJN+udICbyHoFNoHyRVVZY6lU
# DATA 7Q1qNaXRK/niGFIK0cCwpv6ZOdItK4l79OOPZeYKhh0c4251+fU5RBd05/idpExzej0tdtmiFbXWlXx7VQWui6CK1j8ZxlGU0/ot
# DATA pTpnN8qZ8ZztmK/Ad48RWQX9FWwE26ITYxgHjcjBV+J7LtHcOu/tXBQYhI4RSNtgvcnnKEdqGFEu5Csy/+664qrrhY7CXYH0+Vki
# DATA J/HZU1sbdttiFcmQVU2uVr4u2QfowK19Dv/B48u079PhT3eTtPYZrvPhcZn7rhRaDkBSOcNBub7yhoNo7o+QeQfuNLMVsadUQDmz
# DATA TLMQ1zAbOgWTwOH5dMFuab7DZpBkYBtYJohhcgWpioNAxfJjeYUNygPSFVsPcbUzmAOIq9v8ImY5RwR3SiKSuy90OfAzMBul0q9+
# DATA sSale7WX0TxRopexhzVGtkpmnJquPPLNN/mfH+eBwGvGV0hU8FjKn3RB4WKNcGGhPH5DvnqaGTepMGWpGzpuBtqs2xWtapbOyorP
# DATA VdZxd/2aw+bVVU2rz7VKNY3ieZFMCQMQUnY1vIdESrpczJZ0bsAQZuUBGuZ3FOnerKHcQhkgJxwfEgV5r9Z0lPJBIwLmLJgfwi/l
# DATA VX0OGxK9VfkjQqg+YsTC33W0haoPgqDdhj9Fx3Iwu5+WHN+v2ghypYvFtzWn49/KxMjQKpvHWVZmvOEGJpUbKyoQVLt1XVFbhAYL
# DATA Cl21DRf1IfvsQdcd9fKhVg295OfsMQHzE45EseeQCqJg45pMXbm+tIst/6aIOCOm8EZeRuV5AvT9Zof+i1y7Xr9Q3bD9Qg/wCFQw
# DATA vYzRO25Lsiq+4NaTtKQ5dKSgwCCa0tO4fjlHucROofb2XlrnrdaOamXamVsWdMEK7aHc0p9q6EDgAhusv1Q0O6HYndg/ztulAg1O
# DATA kUnOgNHuFNR3dU9fHpycHh4fqYG5skeNfaKPcfVJr1JIjKMZ6rcCs0LLxZxRZ1lzH2TCuZjgu4MeY8Q9hhXabmL7qSIRvFmbKm2o
# DATA 80xOFdA1C+wQDpGhKavirPp3jSlyOAliZP0eSya2vatdkZhRY7yRO6rTvFtyZ62p69Y81oWGBR9vSysdaCYutt6Ow9vv7hVAjuur
# DATA cndnbbyyddsDTrJK72CIUd3rhOxnutht6kvdFc+TcsgrLgC1/o908VvuAt2z9vZbNgmf2rYMIOvZ/ayj4rxGcKobIam12iLsLxDZ
# DATA MWC2yFJM+WwMrxLfwhr+pMjbMjZV5xpNjzB/6UY2LnM0LxuorDveKM78zZt6nSNdps2aOkCPFIHmpJq6OEn3yybwPVd/iaYE9nGn
# DATA I6f7lIFrugHEWevuPVQYZ+UEuGlcFNJZW3/x0Wi4jKexuuzGy926uupz0Aep73U3qPKTrqdBnQHU5/7sw4AFZwC5BNdLULHi+TUX
# DATA 2ooCzAiJLKBrvlSK8ylxJINdeitX3VA9zFxvkqSEO+yJLzkMdAUDwAu6LizViIpoLkwOkyGRWkH5ovxal22f4P3140TfW08KMeYa
# DATA BcRhqByYSkJCysTPGJYfJW92SzUx8DYxCpLMd60NVFlPWb+jM0fXHDdwijxymJDi2495Tztx2m23vW5qqv2rLXdv6YQ002fvVQ/F
# DATA RTuENoU00e6J8UPhTc30pEaZacpp9Ja+1Q4OfnJ4CltCvoEIP3jx8uzru3tKrKw8+b6/N6W7lqzgN17fNFsOx0l2RdsgQ1lv9oC6
# DATA X/QqyQq6m83TEKwUPIxP5UMWsGXiJTAFvtLPV8ElldiBxR8kTa9o9r8LM7qfIQGlqOPuBbyJ66EQ7osuiP7XZVWF9TFw8poO1xdI
# DATA cJrl0WSeyO0V5h6Vj2xOYv2ukKvfRHp2KsuY7f9onIsPRXn3gDSQhUqmXUElGE6OrM0ni3lsbSbb1+CqHms9GUIktOGd1x0Prp2m
# DATA RC/ocD2YlpXfS+GBdKZozS4dgNYB1VPDGEGpqvWuBwoG5GsY3NuYsPTo1hL8fXRzpKkPg4cXZLX5A6UNVDUDjUiqFkEINGRJ1pau
# DATA OyBq9Lj4Vca59a5jzK90Yhc84JIFSuulppImZBlouuoB66v8xdKIGSRWiysPF8Jg2vz/ySGDfOrtd5//32g0W42V/P969w/5/9/F
# DATA v42NjZMYK1T52XJGF9bEkVUZmXO4pZZ1gE4BTAiNoHGIysZoObbvpr0n3Z/S9T8gSX85FH1G/3KrP6LP1fNODl4enx6eHZ8cUqY7
# DATA n0iSEjDob7i8Cue1JN0ap4sFmPRb5gJbXSZm5af8tU3r+1itLOP0V3DzCnfOpWnuh09Vr8n9Aj3ceXwbIk3YmuvVYjHLdra2LkFP
# DATA WA7RY627PcnN8c6ZpAHnUV0wHHfe4Yu9z7E2YO6Mgvh4ds7rm/1gc8SJORXv6cHe0+eHR5ifTvFVFQSZpVlClY70jQYmM6/0xyXn
# DATA yreVSK25iFpymf+4RIFZVaQ832ouzXZ0MwUGUH8wHmC57DKTO6Z6pwvKhli9hUWX17HuHKLXEFx+33L16xRqjNDgQy7meBjxLYr5
# DATA mIDCqxUZMF2Qimj1yPcKMJwP3FLj3IZatgA5gUU4Cy4zU93zk5XnT8nSNU1Mxd4b9DmeQ+dS4mzk3tLHJRLtVabKbvbGPdfovbiw
# DATA kQFd54sIX15SMTPpLmFna757Cw46oMSEZO4PvMv5CYj3oUqM5hZZAzgSXYVrge4H4yxlSiHLKhNXD/yeBFmc1XK97l2nYOcE2Wvs
# DATA +SkV1UOPBHeAZ6roPejI/ylm3vLvEXYcj0duZ8U4LpwbJ4a7+JCnBdi7KCgapSozWkSHKeN4wiMJFzVk3+hGxauMKxXb4zPWMS21
# DATA 9jtrbsO0aOuRl2yk80sKX5rLQWrciVxHuu4OTZi2MEuLyIruzVw783Pz5cKNR/FL6hAMLXD5Y1QjqyToBqxM5rLjUG/kexNadYRT
# DATA s0XnXm/96ybJudokBcSip71sXSOjuvrhrl/Pu0LPuDikMrqJNYl+B7I6iCgNBdRj0H8jcxsLuQ52Lblbmy+n5XMpCYll7nB6F1VO
# DATA ohK3aBjMFniFskyXf8RYg/rIoOxOQGFu1asG8IqTx6FGzBYRtKZMlvbjU1lkf8GSwBrDM3TxxFGm5zxOJsnCzW60crTzYwNI1gry
# DATA krhtZNWHyJ3BuuDsS3V3Hd9Yxdd0OsFNacaxTTOd2yQeR3yYCOv5w5s7/D5HTWUsrOY3YNmijOKECsAL6ZVUpcKASxPqUuBOkpFa
# DATA apYYK9e3Xc7TJd1AoGYGQ9iX5qkX9e3TMjYYX5g5mL+C5e3bGtHeHabmfkydu+A4K6J7d68MLFvFC7lKphSmfR3HMwEOrw8Atq32
# DATA Df1maRz5TYSYbdZXcOGgWBGnNaRlnUpKYOYm+5Pn1nrBibzdlwut+2NW+2CE/6VU9LfqkqsukJMk7GWz71vNrxwnT6rC3XZCsYZl
# DATA /TW47k3MdiI3hpSLFBg86sZaz0T05FLFuoJcywwEANd150HIoxzYmhTVAIYmde8uZ6aEtaIDewXSbqX3cfFuU7VCF8A5w9zecxme
# DATA NSQdh0Or9z4WpzO9xBzDuQ/T5ZRsNceXJw0c7bRgY5vhLV2Vj+vijW0gCO9BKW/mtfhU2syuZOWMHK216uiH0w9Wv5XnNb+rf7Sr
# DATA N/1OUVHLEy0zBUXAeHDzRDvrhSP7MnfB8kTWH8/nrqoxhHav7w3oucp6ARd/8Brx7/tavI3gfUTZJvr02eKI4nGMFuYT4Ck+lbGt
# DATA KnY4AyKk5Dup/u5qlSurO59QJVtzl31OO+Ql/WTXbzwuzGfpEaf6Y1HgT5aH1RSzJjLrMF2O+QI6dGOPb5UKnSzWLQ73Nyrt46IC
# DATA yG8F9jvbv6ENWiGGJ7r+Lt07rhhsjlJKlW/jnP7gMra2efQhJXFZ9mBkkC8z2lX25Zr2yGqtAresAFuvK0vvAW+wktRuYVlxqqrb
# DATA zugLyez/YO7Vfx/+3+z35Ph9XP2XZq/Rcv2/9V6n1/iD//c78v9+KVFVnQ8ofE8u8mKnq/hIUN1apMKe7/P35uq23Ov+rfovwYp8
# DATA mWbJmzXeYMv3K/Va7PoTfNCZlG45y8Xemd18GQorMZrvXSM9/f6DzJSYdLWcvib/3gI4+jiYDKNgxzmiYNmqFayRkY/QMkRKjaX+
# DATA 3CNH/LygQoYKeXOoahFcAjfNwHJTqptc3kzzMVEyK53dslGowZYqzMKXgayaKWNY3ML3NHffZBfL+i6sbFa5WpOTDLkiAJ0gcB4L
# DATA 5fFzmON9yvC7//bul1zbWxXy/gf489v3P3//1+/+WShz891v3v09XmH/7p+wELiu5CHwZ9ZBv9wV1HL5p32mzjyT86mPKDN/9+AM
# DATA qNa4zIBKj2MB8t88MANKnCbd+m1wXqK07osdPyAiDZBAmTR4TvzZXCQUyFLQFZx8k9ByhgsMqo25qs8S4ZITPbUQt5oeNEvQQYk0
# DATA c874cO8px1H4Z3KlCO4cXy8HbAk2fRqcLpRJpnYWdDq3W+KNDsnCaig/PHgW8N3/ofDK9dwJ6795/zdEUljJHT5h+ff3f0M14d//
# DATA F3j8j1R+/p/hpX/hI4MFBfSFWCwQ6RgC2jHA3NSdskxAwSTqtpFwgvkEPtw9CPN/w8Lzv0Eif/f3QDUIy2+4LD6WpQdKsQrTY737
# DATA d/8MU/k5fP/btfASyQCEVRO9INjPc3BfFGeEyXVnIytI9VaPcrf5Fjbx3SZYU8s3m2+xw7sacO7a5c9KuXSsmXLAjO4JiFk977xl
# DATA KHXlvws1GA9TWrHBjMOZLs6jJVAnk6yHbAo553sfk2VpcyNYCFiGX737l/d/V7CLf7Hqqb7nzvVHouOPJeJW4qvZ8yfizfT0hZvs
# DATA fvnQqTGj/cW7f4Qvv3z/1z7+wQ9AZjC7e3nW44+9uBCbKgB4W1pxBQAVb1zbCX1U0bYPnjVsqb/zaa/9mibKt0PwzzD3n7/7F/i/
# DATA XzxirYkV0+UuxL8JNk7JVLLG2MOY6kn7oSAi+5Z5+vmGifPABtgS8ZltRf8fe+/a3EaWHQj6M39FSuXtBFQASPAhqUBBbZbEruK0
# DATA RGlIqrvLFI1IAgkSLRBAIwFSLBYj2m57PY7pHXtm98PsRszuOna/boRd7rbb/YyYX6D6C/NL9rzuM28CoKSq3keX2yIy8z7PPffc
# DATA c89zeDFAir5MW2I5txmoOkPmeDy8gAtdS1VpTcd9Iac8hA/1LrFqMXfC5RT0kcAQnIscshcjxHQi/kwI8Y/f/DP8/o9vfhMBhH9O
# DATA 6Ud+RllAEBN//eYX0Se9yafTY9+Bu1jKas2BfVwpIlfZjuBARQ75M0VwUMHU7txZe6v9IsiAE/jxDCQRFlAxJMpdBda0PcmzfU5C
# DATA HyR55YbP8c3gGZes/FbaqHXGeRSY5f9GB+LPZJE4p4rkQIlgoXiPwJ6JqFWghxG36rpSqOEe2qzXkaWpM+JM5YSdO5kO8VlS4MoG
# DATA w4RvpRw/dKh4oSOau+KckDkRxKWj4chZj6s7d+ij4xUjA9FcCWVgJcZDf1OMiOcPY48dCvPRG+OmayjMC25J7IJQsuEiqApsQfo4
# DATA yQ5V4j9CAQUx+qRU5dyK8FGxT7N1r9p10arjzICjMDDwnA9Hkh9UVxtmQi6IG4hn4tbf5VkYoK/2nnFoBfNmUBy5OMRHTvnzEys2
# DATA Gc1qjiLZ4TplTg7fuVArKDXMNZPnSgOz/k806j+Hifwtsg/A3+VZT3j1JZCVn9A59AsPJMi+Qq2v/traivjSuRoRvdFhF3vdy5b4
# DATA yUqgMRtneoGrtTWrRaKY7H+6VYVCIbpnMd5fwkoyaQciHxc5LvMA43ED+Mf37GZPuheKQTQ9K52xr7vOzGqVu190FhRj8Zsvg5OH
# DATA eeNa/TviK34dYaYtJJnw4rdv/tXiG5BGZY6WdkGHfmHNHZlKyfKMzx+VaGjey1rJcTbsTydijB7XamSCRV8x0GVW4MuvztCSDiFA
# DATA bgFWnAAVVGBxBgwuNMREAnYAvIT9/B2h/0+jIGB/HgfnpWaQLdQ1nm1f4iGG+cdgK/0NZkDj7XSjzqlHlLh7Pu6oXWQTkFBogljL
# DATA JLw8rcLOqNrDcR7Lc5VV2IagFUUx5IFoOA3NYW5VWUcZXpKB5vedKp2XA2UYhNE3SYNCh0Jy+Hp2dHSDzUcERvMpSA1/hofDm3/C
# DATA jWZRUE1zf4M3GtqWioUpvNDwAUfUsSjOhDUxk047t6Z2Q8F1LWjn7ZdX7jN/CbP+Jz5gv/rv4fcv5qy0CelkDdmOoqEMN61bgSd+
# DATA VS5itpjTOlXUXW3+Gv9nXFa8k8Gy/iVLZnjTvsVpQ3OzeShL7mlclPlwdI9P0YiX5C9qq+0z9IPoUR84tl7bqHBRgp2RqSH3JYfs
# DATA pjHl6DilNE8v4mFmdfv94QXLAH3AVRQo9W3/SNu9inls/ejasURQYzc7Ur8ihCNbC7koSM8LGGNRVsZ/ot32L7i7iraeYtTQjqPp
# DATA 9LyUW5crn4VmY5Ath/kELmGY6W/PMuHQadOot2oPXYeXNUvO006Jhfvuit6+ffsRjojWBvb5NOkTpe/IPUWs5AdKtzE5TVBiId5t
# DATA bOBpqCsqT9wzQQefklyvJh5Rnheg7a9MLIpDvahpSJSiL2bEejFcRe7zH7gKbfyFYP+waYdGmsl1qChd9EBWKobhZAJ+/x2FDCYf
# DATA qb3r/plyoaJEErbcAgKqIoblJgGiCo+iQusWVBNZK466ApeLybdjdothN2aEefITx7s9mrjfsXBNkfhKM2oeNlZJSFCKj/vDY06E
# DATA wFefAvsdPiAXDDvlQeKmB2dz3sHp8iq54FjS6FKYwUSkVWycPhrkxY1Ztd8Lm+YzLHx/96cgh4HRW2ofeTbKnjmJYj7kJltxDoNy
# DATA A+bkm83gzZZDjhetkjzSTiEBJksVOWKbY0UY0zn7Pt1rJ8nJbIsnrRBdrD0jY49/H7nIXXHbrJLKim+xaZGoc9HCyrL1bdOgK4df
# DATA rs/S5gCSWBJnXiTX/oCbYNV20KpaiXmtJeP4f+g6rN/l8rHLqHCr6EE1wsFR/BTqOaF6OBk7myNaEYlErD+jOT9Huzzb6KDMid3+
# DATA lLDcB5wSTwbgFjJa9SGjdm/+cPHEiFQRsUtTpNzZ67fNNKCwZWHF2cSzN6gdTzFqS0HzWVrYjrqp+ZDRV1gFmFzToXz2KoRNxQ5o
# DATA yLatBQFF5HilPmlH5UfKiIJRkah+eY7tMR9G+5cZ3Gi2X8P9rv6WFpNONqPfi/3fvbW1Dc/+r76yvv4H/+9vyv7vYJwMMt6UcKHl
# DATA HFhwkKH3UiYeGihNSMdwgzXO3kCnkHMeTidcluKKQBG0eE/62eKp39rD0eW7J3XrncDg9dMkmRT5javEbuM+MtgcZ8Z9hybXqIel
# DATA 3uUdjT8y5UioUsFf0wH9dhPG4bblLCwDOBYn6ASGW5vuzC2SnAFnZWK/SJAYIMxqYpygzfKG93KbIaGhH3pufQFXOFNbpIF9Bjte
# DATA +VXAWY1rAZxjG0VV0VNNDJjDNVTPSEC2ok4vORkMgY1us4QDOGUKMjMZRtnp8EKjBZE0QgviXacyEnZ2I/wQTTdUZj0TfapEwxHj
# DATA ouM/KeEaCYSc0cu+uaiUN66wges0jbFnjfMK6Y8zY8r50FhEhoC2IX8utiL/imo7N7GJmhnnPpibqic/gv8Trgb/ivK0XEek8EOj
# DATA FNeILZjERyUPUsGNaDil/Hg0mHBDUfzIVk5qsfpuo56pDTPaUDSiYOn1b3wjC7h8vfmda0qBY9aBYeG+NWklFK7CthGWDaGz8NlI
# DATA ZlL1tRA5S8ZYuBIZPwyJamwBiA0xoDIFME8mtf3WztNnj7dLHNd40sJvxkIWC34rWhmurNSLA9GjCZvUBtKC9+wh3WRTeFoEY/4X
# DATA upP+A8ARLqB8y/wlWdT8FiVGv0NtMi4LXDp/BZDN3cB//dVPWNuOd+1/YatDUs//6qv/ELthH1sCa7mYCrQdk4oYX8UNg48Y/JP9
# DATA VhoRB3uOSYoqj9EXCJ56ndIxnsPNCoW4Ag14QRdKDmCh3sKzn/IjPK6GkZwCQLM2bIGeDIq4uMEEveS9cNhTlKBYhrEpvCHZbknK
# DATA hwNfSw4BxJHuEIXoiuhkQuJy3CJ15IoLBZ/2n+x+18UnLSnVRfa2P8kX0V8f7+zN+Lr/7JHXfqF8dXECiWhHVOkfEOl+aaMka8Qt
# DATA pAybDc4YH1Mv+xXvqnv3WJ1RuHluMLG/B3xnUc4/0pR+Hn31l0zU0AB39oRgO5Gt9z+Lta4CBFYCSkfaZRQX/RLtdeEVG7iVrA7u
# DATA rgAD4fXyiwizdWiTjmQ06l+2XGrHf9CHjK7tznGqriRUpFGQJYT4iCFKjIYZ6xW4/CHv46MKvn/W2nv8bPfJZ7BX6QnQa/vRwbM9
# DATA /WL32XeePXny7PsSOtW+csr+gGJd2h2mT0enWHL2vLXVSe6oByUk4qgSqTdMHY4cDM8TZKXf0g0JSbIaYqIUTip1U5r7C7YJJMOe
# DATA X4lxAWIFEmCxbELSy8UtHsIxoqUVDcsqcvQuBFUEOUfiM1/NdBUAONoE9cX2+z48loJRFKHxdh+4S6dn8djRFwixTrTkHMjQtnod
# DATA O2R7zpcgL0WzsInViJz8lwUtaUe6kbYdSBrPdOwjGZDxlrfCEu9DgjErveoySfdYZ1BR3DorI2YVLXMCJeM74YYg11Vyk8ww+HNJ
# DATA 5oDhZgMWIg5HF5wFm1E5o5VD2BsVDDg0LGsmS7mm4VOubXhnN+4sptpznqB0AY7mPwGF/EfiAMlQUPWN1RXDmMeSss3fmRuHP0eC
# DATA sxmkgbRoXdF3BkGTg6F2GMISjFTTgYrs2ok1BUo9fyNWnejHRfg5YMqISvyGdQ8RHEyoMfgVm0sbJQmdKmSo/09kTkiWg8R6k+dI
# DATA nmWu8AgraPoqv2KMycx8F705jFE6sC8vtRGqRFhuncK1UN3itO8vkgr31LHssqUwwL6c44HpG72EezbG6JB7N1cinVljmTPO8Bt2
# DATA MVJ283jxcW+K0EANh0jaRgA7D3FGv1JnClBQOml8HsFl+WI47uhnuEnMX7m/M94Tf26LSlzFFh0cv8EVBXbgL9jenQ+IH9OJ8OuI
# DATA FhIYEfFSQlb9q78mBdO/Fl9AddgyI7IolXDs5Jmnlqki00NcwF8/mqYY1xV/dsfJyZlJmuIEQipaComtpCKvQQGxQVFxbcgdspUO
# DATA zksogJVU3XYwnVfppbzVTYd80JIJDB790Mbxn5W+3Uhf44ocRi8nRx+Wv414YBxroEXxlcHPd5q1O38c22QUk2OnKNIuSasc0Qi5
# DATA qNpTj67iBw6BhykBdHl2EI1aDRw+0pCmRkXVWLefnGRNanKG9kDaxz8q77FKe0y5VD7MdyCfnMC6UF0APhoPX1+ysJvH4WzSSvSq
# DATA N+g043bS6VzGRu6iYVv69oNbVhLRWvWo7AKXm2P4lr6dKyv6TJQsov0S8aPCa2oaUvLTtQ+Gg/6QglVzxSU3chdyENOBWYZBaB1k
# DATA erIEGvg7tgmYGpX6RWbs2PJDK72QG/9LUAahxo6OJ72BY+GuNp1gCALlrPxnpZfZHYp1PyZl7cvsw3Lp8M82AVdLm+VcEErL9oHn
# DATA I6kL6Q/sJVoABh2/WqUofvx77YgxLqQvAlaMTsMVyzx1YAeP8TOZEx5aUW0woANaUHBsinwIQta+c147JgEfODEarV0nY4HB0G0u
# DATA vorZ75QbwVfyW7V0pVrK575xXakwFkmXXarskXD9gHnJgM53ASg3QfvtiuRo1JTr2U0j/1DbU0iyeyhfjqr+y2vvcktwVLHnKDd7
# DATA HnfsXIKZI00UTJ1/8vw9Hip4u8QT4mfEQPwceQViEn5D18yf8ZsvkZv4HVkmfAkcxd/C21/ToTNO0SMiZQqyaV9i6CKDlxh2zCCB
# DATA kv7y1b+PiwPn6eSaGPynEllimRyfxkeSFgwbIRwSwKaRJ+ktCa+Fw8TGdSahXILyXDafvHCUjjItj6Ph2U0eQl9HFI9VS7JyecQo
# DATA 87dKKk9dUPe5dFP4q3j/iyfRGUu8PMGslnvcu3evuAMKu35trwiMXuXR7PSUv4deD6EeDRvWgVVbCkNF3xPlEFMdDc4pRBpqw4mR
# DATA rJjcGybt3VQsHqkEc81YUZx4KRTpLJ4yH05Nt3nIv5xAsYcG10jaawaENwKqoKQeXgg0OVQ4BhoBmU8wDkbq8S6K81EqEWJ+euPh
# DATA gG7EDFG4N0w493YW4IgKnBoETsjgQXUN+EPFwOOSkOWXJXtRxE4uM0olZI/IB7/6EFtGBLSUJOXMLSuPBfk1HIrJwXPkOrQsxuVZ
# DATA WxtDcfDwRfZJ/QZyNFAhtUMNX+9dmwM1P4gOTlM4cbNJpLAOd1MynZwOxz3Ydb3zVNwMB+kFDmpT2FnOHcR6rxGGqZ0Mh/kMG12l
# DATA nuoNioZAkpRx74Si0jbd7UULYknRtRsfr3vFomu+zUdg/njw0iAOq/UjDiOrmOAihpoZT81FQ49qqEFO2THVCNIZ6y5gWrqCbhq8
# DATA btduEEWz/MUoapM/Lx4t1zl0yh+RCTo2qzYp6gRoVEjQJdahfulmPbcipcaykTggIByYPwSsr5LLqZGQyGtiACWsobyCzeG5jppG
# DATA zA5S6e6tPYXddeOKpNZSo1QUBy27cDsK0HkydKeXieAco6ajGKaBlS2TdNe6SJTJJSyq5irWZfGd2Bjeq8CIPeCFxqNhX2y/6B0s
# DATA QJX04FMxJnSCiNqyF2UDH4jQeCjpwJVYohLdsWQtKBrvtUn5LNFQ3O9kpruvyCQVOPL6JNKZJ7+2uTfP1aa3R1pkRJH7tDH/DCqu
# DATA wtApIaYyXEJfZFowSx6DVa3gAaqfQ2Xfezwc9kt2XDv5zZPen/AqaMIh6bUUtBFViKkh4t2IVPdUrUFGG8DPpCP8UWI0snV5yhFZ
# DATA a/PcCvzZx/OxDKGhJ2MmnMmMs2uL18BBIjEUBhofTVxRRV0ZNwStv+OzgR43Q2d/bmchD2D4nIWrCEmoSt+1y7N+nB9faUYDlOSx
# DATA NnmNm4GV0DRvMov1S5RzGWZnWDgE5pHT1iI4tdwgRROVvMheSdNc4X0FzVFaZymclY40X8veDNPB5kYl9cUkztMNOEwsqfqMfPaW
# DATA ji6EOZdMFS1cRlkgEhJ1JhNV6g+nnW4/oWCJ8UkbMba8oPXHzzgKD4npMNCLjt70W9Ly/GN08GQfr1i/4gsROqmbGxD01NEyVlFW
# DATA LKAPEaw7TcYsn5ijDxF1aEi3gVAqORQjII7GVlkmTy1ZpawciuR94KOsX14daFZpc8YZiTlNLKfFMSTPTKBB1hdMAYZ9BEZJy4Qd
# DATA sa+ZPeOXxH8xwt8F9EraRicIyiXP9tQIpy0A2I2+GFPY4MMY5n64cnSzseR6s6GMa/WYp5lvS1aSJeO4VaRk2bVLAmCykGUBmMya
# DATA oLWNeIFcsBzmaxw5wJg9KL3d52/W/2ziJ4TFHjN1I7Xozd+TKP2vSYv7DyiA/zkVZ+cTVjwpuT3G3/oNVeX3Qh/+QV7+UgekYJB4
# DATA pA9ekkQAP/IyxQoKhl42NTRcwhhyUckD4/8ir5S/sIHA1gwUZ8KY97BGAVXSMuDjpP1qOrJ0gfyC1ZGyt6pOgLE5uTC5vqRcVVlV
# DATA 0brBTr9qxAnEgdBpxzZDFOBQcdhErxo2wYwBSPAG/kWDIUb0hjmjChIUX1OqHSTO+pEZiwawgvAwOsXQhA34wacgRZPiiciw+KHM
# DATA hCntdoHC4fWwKfpCZ1PeCm8siWaeJ9mEEld66A5VVCCIg9mIbE2d8n21WGSXL4a5eiWsADYeiwxlRUdAspBZDMwjLMYiG0+gdiiO
# DATA yMJoBq8nGpSSslo1ruxA832quP6vsQzRiioL5WdHJeTZhC0OuBwHhsZ2hbcoFLOY7agdfytRy9r3XbjvnJaUX5AefcU/IiszRDn+
# DATA WmmvO9aDtxj5my5bpcAdbpJmhxcHPezAZyvwA8V9XHyEpiaKwjkCZ29Qy9KJBJwuxRKqnK9grm8yKWLQQZgqN8IJeukj7yB+F5c9
# DATA WR2VcGR1XEfnhkLlJGszY92dQ5VzGVIJR5bPk/Fyv3dsgvQtA52OF7cv+z80t6gpM0fX+ymbD/0j2/RqV0JtKPRLNMSEY4rNiX6O
# DATA /CccXv/F1gLzWfVzcj+0j8EvleYY/v0PdkwPgrG6VF3F6CmGROa4R/HBY8m7w6TP7EnY7e10jHmioIzAv1EIGqK5SaeFyWkVX2fF
# DATA vkEJQL/3edppaXQ5FCSYvaCzhefeZNgKlxDASrO6rKiuIKQz5xy+rBzZ0w2g0/XsIQXQe9Yc0Vnews0jK2kmGn1ZgHIazgNUT93d
# DATA LwXYDLTLDdqK/sHSpfEPlhfauZaAbczrNAYJXLXlql9PZXai+4r5eMgNkku2LKDi0ek4sEtKE8BaOl4BCxrw/RdfMUYGrH9FerHf
# DATA oJ2N4ip/OdPST7b0JqvFfivhyX7KTCIbcxTA2sne8vrS7IJ59PtQU9GjYBOHq+z77YhvNNzKHjq1lCIuAFkn8m14jWSdPc1wgYyL
# DATA ZI1W9Dlz0lDWEo3Yh/G+jMBFcUe89ZQma2IfW6j+OEVJgMo2PQPfCbmsitJtOae85tBGNEreCzcymNb2W2QZ/FMHV/BCgUeAGP6E
# DATA 0csPUeGsnIzLVrnDiK3tIsmKNHMGIM1/LRYisUCKC2+RcSjJ0V1DZLstnxPpdNLOc0RQqofngFeCRY6AWC4TiqUP54hxK5HFtfS6
# DATA N2bgClZtz9aFi/e+pzVX8TD/B5YTeVdCiitGDi/5i+ZvFjm6fyEBD93IAxwI8GfknIFhan9rnI8CMw9N2P+imACqXn4rMTVVvfaX
# DATA XYl6LbbzreXVSl6ALYvE3yCVHOVer1QsdyOyfDG4/EjjJf0ylwu1u2zup8TmPzWUbc+5bli3oqWgRkz3YRRG1LgKA6H5erJQnDFv
# DATA y+DLMqbQzTuh+yt8cTYi3Xjxq5PSGpASr5M/YUhBEL5fSRZbgyDcxqEj2MI1cGREjkL/Kv7O3rPdg9b27uPW42dPt3Z2kcWzBYLW
# DATA pJ5v7W4/McXUF3PooMiKc25aRq3w0oMP6/fRMhUTp80W+h2VHfKLPbhkVE86Lx8TIZp/6NAobzUXlca5MIMz9MXHrecvPn6y80iB
# DATA QnVENlV5i003mswsy4XDAau4NFwOXVEDXbAGJAihA/ciOU8DCZOPtPGDSR4fQMMA4lhiziDe6IL5E8U5cgrPFTOgOS4Eb41KIUQ4
# DATA WnoLbPkml+sqgFWNGTh17Wj0ZVJ5VH6qnJh9fA6CwZRGi5MCLKC1Y5mfCT1luTc0lt69j/kL9XVQGNfEU/dfNEjRJ4r08+iQhKz0
# DATA VCZU4vohtaeUWsoxairJDdtuqBGQCY7Y+lh+H4+1esbatF6wHCZllumPtHmtU90kmNzYog1a7VG0Q/ns0jW4HRaqNyNbg8OiCs10
# DATA cBkcICkWZ5+MyXQyjH27m3eXBdvtFipK7cjIMi1TUDsge8pSaljNbRGlKd3Pi6SlquOmGvFiGlY0LP1SHCF+U6Bf/dLNP/HzzYKg
# DATA ptoq1bVWVcHvEJEVthJP1KR/LZls0xFxAYckOm3+Q4waymqbvuQ2HxwuHWMiSKCpguTNkkPv7M1QnoO2mjzM7GbfwqusGVfEiriQ
# DATA yhpCUpb0Tf6uKtQL28085ywqIjLNjxCw8JFqspnrhAwHiNVvykA9NTF1PXsOtl8IUbcioBA19AETItVlr0E1RmoA7jxS1SNbBAlb
# DATA Y23b/ZRiTGPSPkUR+CjF5JuAPb1zIHD0WC40UAnIW+GXYzqxsGLb17yzDq5V5JUYcv/jKnmPON2Q2FPr51lm1boka1sSc/srYAek
# DATA HF1ByZtqcil9F57XZbZ1JMMKTy7F1vQtPSX3CiMhWmZUeUseYV5Db8cuFEEvdCMpYgTsZTwynjEyytm2RKamf3FZYK63mguMP+Dw
# DATA wb0aAxJ+4YojpFfPjTHgB/KK7rGeXtLqQj2Ul8IBN8M8Nzfsct1qTG/Hds9xFzCqjxBzPn8xZrLuH0RPyDWLYxJNM8kSyS65cRaN
# DATA pscwo+jF3pOIA19w8GvxsGJHY4DwGPMELyYdYMs5zMoyTvscVHkgJECQl40ECs3Hpdocv+/CkLVFoi9p1gtKN+iM4Gyx6aONEaot
# DATA knkrsdb2092t7299b7vFcgoAHRsvhe7/tCyqk7Lj2gqUYcEZFaG6zIi8gfXvG5sdSM3Zlgf5QkdeWqyFtlSgGbyUhkDacF2WFQx9
# DATA iuon58Jzg9Hshm77IZ99feTpRgvc94MEVlfK058wLTcVjvLntdcaHSRomKH9p8TU1gzsg0jnjdXG5pTRHXZ4b2wcF4QpZk+41xOV
# DATA VRaz2TMdML4Ruh2UBrPlEYpV9euqDmXlWP9SUjU2/i2H4KymejHuYe5V1ZpnXmFnOmCzds/83/Zlsd0A5lq+cwxVMQJ1xqInGdNV
# DATA RMJJ4G/HEDdUTDvec0RWybCeZoIfCvxOzJcFVlXOTnuuZJumVlML0+0snLDndibExNr1yr5vUtiQ3lc5KGm+9gJhlj8s4yZOVslv
# DATA LGufsuvAKnJ/YrwJIBLGKx/hPjxGPQGRtvuaBJYsM6jxFi5fj0Kh4bMQWRaEy7leoCnaSDtFtNMqbNJxavtPdNJRph+Op71+R9xO
# DATA 4HpBYhXUVc3wKb5TOoyrHYn0ImBi+yxukgwjYnKZ4Bj2bkAsD0C507YIWkHujQ/xpHM5y99B8B64CdwWdiwvMRgsjs3BOM/mfEd8
# DATA C0OQ91OGJ7aZdqrYLN/HxNqvHAyPtMhmKtLNeBcPi+xZRv5iYUh2dO9OBN+OsI3PGJuAyNhoqOR1ardZONHvUIRxmodPJz7mGbEt
# DATA thPfSeota98pilKd1fiwUBmNAnESbZqqaKE0IY2Wnbu35Wbo+tPl2EVtVWb0ZtxAwAlZpiFeoiZ4UhZwPeN2a9MBadPPehkyza3h
# DATA K6+5fDAI9+jgZiqWq7F4F3uDMF7HFTW+M46JxeG7A2HD6JAROxxLrV82gcTMUOeeP649r9l9TXe/BQ5HVn/yYSj+4oCFLRLRLb7t
# DATA c73SjJEYzenSsk11dpqypCggbtIfK47LWtQyjw4EjwDnNCXnK9qFbhd2/DeZgCXwEnecV+ml7YdzQ0ppQjVZBtAajgvIdf9XMZ9X
# DATA Qlll4vgvZDCBdgz/zhHMfv271Vzjcr76skHtmACu674UmC3IUh3cavpkYVELtFx8VyduHHkt/HRe5LhaZKe0U+4Jf87NYGRPbVPi
# DATA CMXfesM4wf1uQlvcSGY0BNG1kDSINQgeIfVj14t4uYbiutYo6akjMid7p2POvKyw/zkXdvxp58mPvds+x4o3QZMLosEXL7sJ/16O
# DATA KJgzh6f2zUXFq2AQHfryaODSvMtfjXXopXIgOYxoeyciX7xSIG94K1CJbBiI4S+d8Nbrcs2ysoQaAFO7JIZdsktc5/jIxTe7SpjD
# DATA NzcdMiAAZQdZrU70rS94KKpREU9V0VyeCfbqHAjlAqZXhb64pa5TYQKQZ5uC7J+wRYr5o6EFnPq5pZx/TXkOaAz/xWodm++quOrd
# DATA mzb1bm1obtRtJ3dnd63LHHbzSOLD2Oxgcdc+RQuV5OY9PjM34xmT4E/IB/P/w7lK8aBaksjdO6xCk1N3bqWCcnh419u54R70weGW
# DATA fQ/p62DECpF96S2aJzONojgTIuEKOZIWRgkh9smu6HiUutW08rU48AS35M9Uizs8wPrlgs1ygH0Sn9rjLNBXFcFGt0J6c3l4C1C5
# DATA Vd8NWKqt9wau+ftsFrtdFKFiQVlUgL/Qxp1NZcTYCN6WJboFWoTTDVjdiR3hC0X4JhEySf+oOfuHnfMIM0Yp6eByOmkvU6llYxRK
# DATA ZZJOMppIPBHPXDR8P1xQ2lAY+94RhekA+BLClB5K1vFkO91p3km4q/L7giOLF1xhAxabxE6ctMANtBxgLzTb5NOuIIMR4h0sM9YF
# DATA RUC5llr95HI4JVNp50jME+0FMTtHuAvPyCBn34Pb3NJiW1T424+h/jb9BJpm3f0ciZx7JdSxnzVRXCj48ztGTNBJB4q8hQ0ON4LR
# DATA dLwFCQUS8XyKtc9xLgBBeSHLjPfj208CNm9kwOQ/Vdz9IvZtbLJVETfpp8nIZubnBSspX7spdckSm/dlYxHBikugb2kCrfzFQoIX
# DATA N2qpJ6xVIa3lQqfx4ciCoxVo2DEdd2kbvCjFy8mot4yhwJY5UE3MejzsgxdjWTn8j9CXlm1yrdRCNRLUt/hryftGVPtToJh9+Hal
# DATA wl510qQj8dpoi54NARDDQa9dQnFvfVUSAZ9inLJcgQe6eqM49RunwqAhcax/sjDBtoBeNTcoKwYQW4BcKNOa5YPhr4zLemjdbAGr
# DATA aK1aTlEKAA5XOh52Lt3YVGqknHDVSk2L0CqOhuZFEsR2Lc/LwFfGPdUb7phZpQ9NScHaXvZkCOfaFqfWxvroBzMjelowJTCKeDgZ
# DATA sI4xzYaPKlPOTzD7zm/ZhRgdhX5Hrkg/RzlSgC311kAIv50yq/bpwcHzWUIOjp/HbqfAuI3TfEx2MguB0whKRRhhO86iFy92Htd8
# DATA rkYSE5GtCDC53H+bsuw0o/WV9fIssrA48oUnXXq2L8n+7BSADihgGnaOLKPPyowZPm3JrJ+mo9KqnE5hwR/CdT+SyCG/9Ry/VK5Y
# DATA FvXJamLa3J+hT6q4mWISH/YFDyWJ+pK8DO3wJL/ScVpVaEpWib2Dau2WxVzMlw7/T8av7edf/c1X/zEfSRZnFwckjPnjpZjZ0Zq+
# DATA b4zb6WUjdL6kVJMm/j0lgQT6KtnQmkrCGnuCU85QydoUTghqSyzpDcrUltzcmm7DapRxYOC6+dlNaLA5ugpGkAWbQLVFlQ9zy6zV
# DATA 6HKsZhhyFBan/LXkLNYjc3P1sl5DqzVUEEdbM6zUwtZsKP1Ud3jDHMaoRvvRFHinjq0c+0ZTCwPXV9Wsnml3Ubv/o3LAnhm7rfaI
# DATA dzQxt3BVY098LLJhJ3x/cJTIfBnD5gUTDbuopxbW6ovyrKp4dn4aXj/pLs9EHuRyoTL2aneKcjH6s1uFQikbjWz0slDKDuLHl/Ru
# DATA ezDpO2TN0XJ5e7AwcRMpXpDFa3EM81IMVByGUpYcTo/2trcOVMamvcff3/OzN1U4drTpRqVO63aoAzuNUHwRE7uIPbiHIs2m1sUP
# DATA JfynIm+ePHv03db2D1xWxKWgAfemXHZl+4Y5b23VXRHTuWVoWZhk7V6vKfZBKGAfTJqr5QXyqpNOpncymJ7RgnMu0tr+zicH23tP
# DATA K5F5/vTFc9uyn9/znxI3oJMW3Gk1MHUpahkxuW/g8GMquVSUpVjzLSpdcSg5cS6NsNFAeUFIUm6spA7NR3ZOT+nJO9rLyg3kzd8b
# DATA 9kUzqJqXySmBg+EyhB3g7IMSfOOfydMHw3T8ilzif0yZ55Aj+pKD2rBb0O/e/ILi2/zRH/4L5X8ef34MpOFrS/48N//z2tr6vbtu
# DATA /ueVe/fu/iH/8zfy3we3lqfZePm4N1hOB+fR6BJOtMHa0u3bt/fg4gxbmtADrmZbz3c4KgPZH9KFLYsmp+Ph9OQ0ZPMP5WflgEZh
# DATA OBISJEodnT0Zbmx0bZJH4N4x9fO7Z4e+cQ5oZ6xeXmg70zONQWiiGgPdJ4CQwyXJZFZWSiC+9OgbheZyYdJy/dKJoUToDIzB2QhD
# DATA 7fY68MHOtcL6cjrjxSre2Fcu2TZpszNckSsY55nvDWq9LJlMLgOZZd0ZxE/Zci2y7PGh2XEvOe6L8exwQAG/Ew6GqFNRc0ZiM0gZ
# DATA kix9Tf6WeNp0DPHM+TDpDUbTifqowbs73EtZHOlL0/A+rb6JUE2mxubT/KUlxUtZ2u8Sgw6MyQhFy5iS9iw7AfDDdgCUr2C4f+hj
# DATA LnywY90+/PghZSPcxI1D26XL1vEk1kCPBDOZrVHPjLDV6g16k1ZLRsYyueErQITYCTRgZIx8S9LuIThWxyJVMn4pq64rFnZqv99r
# DATA LU0x/iSo53CToLkp0DhPGP9UecKCZk4ejF5gRkkDA5NQ3iRHq0S6bdVyHJ5Ps6m8sslg3IxeT7S+eq+2Av9Xx8lSTiksgw+NRj2+
# DATA XmTEe+nZcCK0LlMXuYiENry0ScTJqvb3P40m0wHODDcDlohti/h+t0ZrSb9oQXkFdZ6vZWTN6YNbS/CQ7HV+UP3OcHyRjDtpp/p8
# DATA PEQTqcgsp/0VfuE3A4Frhp0JQrwAgCQW6bU7oIVk3NYGRY7a7D9722mvarolo7xUzBcxIYBizMVi1nFsoNjiFlzQqmxEHkqWp9Gy
# DATA GF/cuWPD8doJY6YXw8UFKXsYb3H6j8/FsRPlSh+ncJEcc5Z1Xd3PMuRbB5K8ujA7hVQq+RtaDBSxMtFFBAuviXUFoq/lmpQth+fx
# DATA iNNSVQ8kVpsLqNfVi4sLysJQ1b1ysETTYx6yjloUU7ABhUa0GqOTT2nNCjiAO/WT7QPRXNXLC9j1AaLkMWzPwh6EDyprCHUQgE38
# DATA R5Ptpibfjgd/XvRNt1oLr/n2TAeCUoWsz9OFuPnPXE3E2qrSQ1jqiCJtBAaWk4bK0cPIrztPSeATL2Th1GgwKw3cNccnaYFZihzL
# DATA TroPHknI6PFGugFt9cIcRFCoP0s55G4nu0UPv7yWkcatr35UiTZWVvGfNfxn/ZqKKYR9EK2Gu7Yl+EBDVIVy4ernHC3nLQwhc9RN
# DATA ev2006ATI1LmfmYSyjI0BwIlAwiqJirRASNvSFExA3i/d6hAlQGGgB4OBDCbqC1C5fQZFG1Hz5/tHyBWkH2UAQyz0jg4uN2djZyc
# DATA ksHsXSVy/uwCok+cVBAqCV9nUlM3Fko74zVdwQL47nPovTadtEPSqsLGetmQU95wYzWVfTD+Uzx6P1xZaayseCbSkll18jllUA86
# DATA mljJJ6msapXrNIMDdrL01ZJMlSj5pWtmzGUzXhkqDPpPLXXS4DwdAx+aocVj9qNp0kGebjhJKGVdE73bk96Axc3aEBJvfs4RL2lD
# DATA sBXJrizsqOUdrZOj1zC4BkW+LI1jKwlp9ehqrbJ29zrm9GpzefgXiuXtDFM+rLu9CXHvHRNENGI4eIg5TqEiuUdYWYBaZ8mIGBS+
# DATA EyGDsvXoYOd72yQ1h5vXMeaKhrePd/a3Pn6y/Zj4sN4Z3Cfp9ZOdpzsH/DZ9PUIVAr7d/sHznT1+Oxy0TjkGvmniWruraNiJ1YKO
# DATA zGtGNxcig1eD4cVAyQUi1dISe5KfYUAx6KdDqbR40cUMBk7jFhXgsEErmBjcKYHVWpNx0u322qqMvawr0YMmd4E/PlpZuVf/6KPV
# DATA jfV76ysffVRXtxYqRSMIFJo3u50B2elFMgrO/wpcg15EtIg8uSTeLDCzFmLvpKWK8STiwZDfx+XadDQCXtjKFS7t6RvK7rPW3vY+
# DATA UF9Yy8dbn+Gf729vfxf/Pn22e/Ap/vhse2vPvqwULVQGvQ3HaFVK3UdmWGwqkoxx01npXu0R4SlAHdkaOz17M85N3Y4KFUrVouO0
# DATA PURvWl3Q3gaSGIEx7hAheahQ8ujIxlbzmgaksdvoIPzOn+22Pn325DG2f5lFag9sRrTheLviudYRwbW+wY3T8156YeiIIVCsSNU0
# DATA iqrTatuu8H+ajodwgCaDLELHPtqw4gtvk4patP36NJlmZOrbbnNM5zN4jriDSDZ4zbngIjI/bPqd6g0H0Kz7JhMCZ8IpQ2EU+bgO
# DATA u4LQwuhCMyxNudsq7zPn/qRQ5JaNI56Zkb9kewq2DPSIkqWpypsm8kPUnU6mtFSD9ALTppOBo5Er2dfrEKoaJR0OewYOvcjQOIUj
# DATA wgNDE30Oi7sJ/PIErvU8xLPkMoJeB3wWJH1yWo6yETL8inYkJ2T25yZfvzLHVkOsUhWKq6RnmrZv4QXW8Bm8H/hTzEGtDQ2S10rh
# DATA sgrErlpfra7VD1bXGhsfwf/+NOcDHstIn+BqfoyObtCfkHDn274iHA0NWFSU0xG2g/RxkPT38VynWB7IrlLuF7TlKdF5Xy7notTE
# DATA lqYObV31TIAUSmC5OHRysfS500omcY5NO1RftziXow87q66VKKRHPv+mB3kX26HIpxYxxZS0JIDEUpji+So+76MPG0Ft+ENWeGen
# DATA SWd4gT5umTUN08xNyPcIJTvtYb9h7QVhuUjqKhE1WPpsJ5iTesB1UeTyivKSRM+xkhk1K+3p8QUsHMqdStZUlKTPTPC5ekMl7al6
# DATA xbPMFHX94tXYdJJmhmc+h7hzX1ACbyl9qFqRdKg0y7KfBS/gGzZboq3HZsSQrsjRSvxhoOb2oEbq7gZJDGyRVhnjfeJt4LbPJfBp
# DATA bXWRMT9XY9XyWIdVtdlUcUGAn8SqjlPJ8+KSTtlKPEU3aa7KKugvVXhku8Moj8K2ZNcOTm5x/RbDMT0ulmobXtayfWnBd0U8yjVO
# DATA gWvEqSqMFfzEPLc+nsy8NtTvVu6u470BuisvsjC2pyiLcZW8L4myU1QTIUawzLifniTty4CBpAAwvzwxNUF4R+5t0+P89a2iTzZt
# DATA VkWpAOQmhrqZQSftyGw+iB7ppYmAKQJkmZCIUhkrRek5zOHiNOX2z0hyQydwgkFc0MIHORi5kNP9kSlRL+13iMt0rmxm4+TJiks5
# DATA iJqq2ZrzshI6wIpOrqMlK9U00hselUOSdF5phgtrERSaoakdcjXqK8Wz9e/bBHy6tOrgrMHje4uSd96yTyjdrl0kp7YzbQNweicD
# DATA Oo6uMoAsY4Ir2sicREcZm6lQyB29eYKHOEXXc3LE44lnRhisdERESw3LOHwo8tPCTkvJqOdcvRWZhPdKqlsi6RO6RqGRPamZl48v
# DATA qwp3yCTfoQnIkmkHnaSbomLMqAnsUBVG9WnbYWstqZNo1Dj1S856yoDd4jOG52Fl7jrGraV8GzKSMxO/iPod0uxgIjnWZSAszRk9
# DATA 7Haz1BKTr1SiOltBuI2qADlzYfVtbrGpJIf8SCFhvkXMnf7CzbsHG/G44bAl9Imj3h3G9OSmgHE+EHJTjbwdPBY0IhyKK4IpnRej
# DATA qgR+MT5QYQThMkeKaFqhTZYGqpdJRNG3Irh394ad2PPdQstSCR94KKM5yjvV5UVOZY555KuJisf9eMrKklRYMe6a3McAKqgxhzHo
# DATA pDReqvJ0gKaRpdA4ypsMC50BObM9nEWDQCXICZSWxB3zMTDFr/KJgy2A4DCtZh6GWikSpygrRzVtXiNz8lvt3soNL9zoNjUhd1AU
# DATA eqeonBKZBllyOyFyxb6pyj0rB+wrmVxD7VZB3AaP4drNg4xFVNyp6cCz5yaHKDb7nE5G00lRspwifTJbw+ghkzQA1+AYdcnQzvEQ
# DATA rWmwtbggC6LTOeVSP1eKP11WIgLYWTYrEdn5qtBDQDK9cAG9rlXfnhRiRDK4LFlf4SzA9suLiFRhXnCDj1BPcIkXGQcAynEqq7VP
# DATA YUAli8haQxN0aqKtBM+f37S0tYPN+VrFnBMJ9e+WuQ0Hinz0Yv+gtfV8p3Xw7Lvbu0hc91RWKLKBYvVwpDOeKBFx02nq6dben368
# DATA tdt6sb+9t7v1lMQvSmaadIB5gha0SY+Vd0az8eHmnm/t73//2d5juzlVBcdkAUcbFcijPjKQQ9NnBo1lmYrqbSHiCfXTvtM1dG/X
# DATA opWn8xV5AnS+bXFDkvieGANy2DQCsODB1RNWospVMBiBOZ4P457HadiXEURDw/80m2zaq2q0qEHD+HD75fliYK7O5c2NivYLttOx
# DATA U4iZQx/m6rIJ6t5tITGNj47eVtb73AqNVWFNZSbMwqFhWdUxRX3McOAbJZeoqK3Yol1X+xIAjrw08k5lHa3uZHC3wGuZr/VlDwF3
# DATA dZnHs15U1Jgs3v8oFwBVN+YnescHdWlRhXST5YXPXosSECg5cBNr+ju9bjelQE18I9jkzNMAMzxLgOP1TmMyo9eZMWUotC0E9rEC
# DATA PrxUP22XikZwulacWaXHdafhup8pk+5KhAYchdbd1BwhlRmyt8F9hoLTclIKlGieLbg7QiV7VDoUIdEM1vi68IC2I5+aY5l3RMyj
# DATA R6DRD3hDiPqUEv/4mHuthHqoV+oKo9CIrgyTcY3cYdK5hJdwgyW/wunhbbUgtzlByVS582NxJdvl8PJtYE+46pxqKKiDY3uSSfc8
# DATA /PJ1bA+RhDdkFShkg8PZQxMNrfg3uSf0mcxtzaNhz8cpjODkdKL15vaJCPd1Zp5r0R5pPiKzDK4/TWd82QKmx/e5iB/D6sF77QzG
# DATA inkmg/mtY/lWKsKNjV8CYcU5s1Fn/Mg2LSZl/uQUNgkO7duE6RFUwGOO9AuXaZbz64kfIYL2i+cblzftwQj3gYJ5kQ6rpN96wdUL
# DATA BiM9mXQOFJJA1t2+qBExQB0o5wURMnG0qdTYAbJYTNdNrLrZtNZN9OzFoQte6grNrTwOqoB54M1qKHKuGaFlLm6Ge/sg2jK2Sahf
# DATA Af63P4TjVmRMkQ6CwRboZEiMASIGbVgXtMoFmh0dA4Pa6V/yHbAW7Mhxy313EIfBrK696vSSz7MOr+Kt/Ejmy9JsdHntIX6PU9x/
# DATA I73PJ0MDj6BPN6K61oKY3I75OZFY+gZDV02bPTOz8ZDJ3PyjW9324Rhqp2baRHbUee0EyAnhXsEhqSYge/woeFwKLxw4Hq3TO3DA
# DATA iTBUjjjuqvA03P90a3Xj7v6Lp/tk18KpacQNopadJvCxNPJiU56mrzu9E9yeJOaJ6PAYcV4zeH45iFkdRBwwyeOtm9tJf3hciu8I
# DATA 6S+X3TOUKXJHTjEB021BodtHeNTZJ6NdSL/nYsqszSnDL7GAOXX8tZh70CVjklmz+mszssBNcqWMup7Ca9S+C+sl5xRwfrxNhx3a
# DATA VHHQA/mtnI9z3qzMD6FBbex7AG8GiltkJ1inoBf3KrVQTyw5WLQDurpU8eqifJrJcg6AlgDYm3W4oYc6IS6tesb+ysbj2Lb9UrJD
# DATA 05j1uWg4wJ5UOaJUQlaCzZijQU1gCnFwJJekJgiVLuhC3YSqchOaVVs5KQf9kxHT6iQld++A+GpjZcXiH9h6sxQbYDei+n/78f+4
# DATA gXaAfN/UOsXAnU6nGhDH2bkOrPP8Sm94F7GcT8l8+N/sP9t9TAF0C68qTHDe7sah32oiAwdX+xVzlcRfotyGrfRqlprLIgDUPXDD
# DATA GJsRmmiKOxR0Wy72la3/f8GllCK9dWHbXyT9/tfkBTrb/3MV/m/N9f+s1+urf/D//D37fz67GETDATDTEwrk00mjk2ky7kSkr9iM
# DATA XqXpiLyccIPBGXI8nFKwzhHWUDZQ57AhsfgsT9DeSDJAvbub5/RYogBqb8/0bIQbemnpAA0BI5VMC6W5LUJ9mlO8tPfs2YGSp3NQ
# DATA Rl2uSsEH1RYB+vtid8crmxFR6Mjfoqo1FX2obCkT7iCJrjDFEjk8ea84YfBYCatnV1OkvcI0TlxdML2ONNFORmgr1+KznV/OyBPG
# DATA vdO/xs1lbUWNc5BOLobjV44VvTZp08tX641aTkkM3DfutSe2fNuYriMH33vdTylQx0pEwWXpQy9rncFfYB2zift6Srm2iFPzuUI7
# DATA HtZWJMXa4lq48xzbAfgN0olt0hA7ah5OfYt96fVBhTcqTaARmEx22kKkAqgfj3sdYLi18y4Hl1OTp2fhJrA8yeCJ7Ubdr26mHH0R
# DATA Xa2uXjvKMPnyMLq7rrQsyGSVRmUlLuxxwjDNTIzwn7sbG2sbhsvnVmbBSEnpcANTaVcnpyYIA6mv3lcjmW0lU2ugnUylvoFmMsec
# DATA jPAYR+NCa/Z4HmNU+LFUUbZsyVmvT7acvdFdckOLGzHrbU3Evd4odjVD3fiKK15HGWJodEXFr9HwFp0DhfFhY9xmVIp7vS5dma7o
# DATA /oQMKd++bN86a1bWkqoJcuaVSHdBXIx8VBlRbYzrxnHM2t8eYuYV0ajr6OpqCa0EoBXg19CbE94Qq03FWkJF4ErVT4DblO26GV1f
# DATA L0WUUFQYH2yGqwEFRBnK6XComCLgd4ZjNPCp1leASUYV46WMehNqKVDc7g9vy2t4257oEKq8WJ3xcATvrxjmKBWbtEdRhygvDPnK
# DATA wPAsGSFzVxHMLF/DaE3DptafmDnnu01JVd7LTtNORSX/ayvVIRtz4+GjK56lkyTqr5PtGZCp87vVXvsM9gf8c36XIQOjHHSqg7R3
# DATA cno8HMMdDQCB9q/2y6SDGhR6NwZAp+oNTgEQEsA6YmX06sbGTTt3bnkDuFbDAh6jOGuUYHaE6mQ4rB73TpgoV5W2mzJPwvrgWKAD
# DATA qHDmwJPXxeBDl92ACzBCfZ2DEwus/luv1JXsw2t78PA/2B8mmFobpTz6Ui6EFQnoktiKKkexXECEGKhc69Gz3d3tRwc7z3bZY0is
# DATA AR2yZxohc4l1DnihX6LVIJxDnd4JVrQuLzgYstHAS4xbPhS5B2kIxfJEsx84ymNiwTLkweB04AReBzjCSQcQjgeK5cPpLB16TLvo
# DATA ZefDmNIiBtNsOYPFQgoSh3q0udiHFu+xr3/6voRasqpInvEsIT0wTbVDBJ4zk9FxSS5OEv2Z0ZKcocY9WO2mnAP48UceQMzK9WxD
# DATA Plsqb4cDLexbEniiYzg0pPrwAMdZZDKR6DNSPZMsILahuLGqIQgoOaJU19GcazySmgyjxsVrYlvkZfzw/lPTWNHZ7Q/jXdIg0M1e
# DATA ICbHzfGYoqhxqZ1OfHTYqK+qVVZ8Dx9kTJk1b6NZIM6SSccUQLGvz3FLBUzAHXQn7K3GAQOoAsM3xRd0tik+12UIVUs1HhC56lLg
# DATA /6Jms9htyKro8xh7HJpFSdKTAbNQtOQRtM3NqT2aDLJE0ZBSN+6kZLuUP6JfcjTm0MCJmZWzHtkBApmWx6jpVNv0b5f+jYXlt/ov
# DATA 52vMKCsZoPDovOgNOsOLEjqty29t37tFh0hHzxpGyf4D7f4QXW7Ivhdm9QjOtuMhMZl488MIEJHs+Kg9ToCom1y9b7nywQWb1dxC
# DATA K/52q27tBADS7jAaXqBdLd91e2g2QgHwUeMC9yu2C1E3ugzOu16/zwE7ZwIlI1B4IIk1txMvBh+yTTBLG7I/tpzSXoxOxgntpYhT
# DATA fsicSF2JZikq3ApvcjJJmGSMsZFKM1Szw6UWYWPJjfGH2QciNmu12Nobs7MvrZgS3C6sBTJeOEK3beZqZ/CRdlvl/O7inU5+tbwp
# DATA 5ixWTLztfXJ1vo7DZC24UHanAKW361FghD/rG2c8BkUF7GC2ntc7+UPMMk60L2R7aZfTeZMRomV+2O1USKwyHCdkgqhELLWzVyj8
# DATA GKFuqUldqezrfNNvxjXCv2ookK8XS7LbMTEksW0vhiT2xvPkGeqv2mpQDzAXtXKYGUd4U8hE8aWwTP1LZ9sNM/YlkYxvup7PJGQq
# DATA q6Mp4WXnQ8HAXKEB9IjiqJzJZYne6rRzcETOTP3OxXETl5CraU2BZ78lohbvE/m5fgtAtbK6Wp6JFi8GaGIvlMQ32qRW/dRTnpmp
# DATA JRepWIyi4e9lb/bptSuB8aQvoqlMz3vDafaObAiuLzGsJAhcjmKaYW2EcVvVKye7EwoBjYkeVmeJBDTjOroVb7oFIGwlfQESjvcd
# DATA bK/BrZIWGIV+nJbQRlErKWF+fNeB/Ue7KTB3EnK2KNRsq1W2uywXVHagZMlOriRscSOS1YzhrvOcRE8NXtnrXJsIZLysxYcvBr3J
# DATA 0dJjS91qrHJJNi1yHxr60hbajDRla6ECryYue8J3y5mz9DF5TjZJ3EgeJlJu6VAS2B8toVKrCWDE3OtL26/T9j76BTe10FwE5tEs
# DATA mfGyAqhKVrPEPs80TFQlNS+BRzzcYU7jaOn7CSqjPr4MDCyO3cTmpZhlzu0JBYTuJOnZcFCFOzfaG80qmQ7UzpgvrbbMJHKXAfu+
# DATA GIiTrpCvogMi9YgbKUzqp4sV2SsRms/LnltsaGKfj7mARu4EFWmRK6F4KvKrIo7fOTb6nUMiEwXxWfKrxxFAFlmUAAlbBCOKqllh
# DATA 67/G4Ot8X3EMAExsbN4ZMnc4CvgXkv9YWKEq8gb6gW4tc+KcM8W5Ufxwdf9r6t59JbWcSRJDmkjZ4eoqmWyXiyweh3T3T+EILpHx
# DATA 4sqMEMzx3nAYUlPk4oHjlQ4YKwzwATWqfG8x1kTJ+RDlLhhlexnpN/SEKeyT9niYmWvN2FzmckzHN8AIqG5vzKa89dgQHlZcdHVs
# DATA UTD0t4qF7vGuHNU8zL3a0c+7ZLZYEP08gI1+kgg/UYThH91g9A5C8x5zG2GRrZM8J3SYFxz+i3BzBecH7yNJQstb9ahi61VYyPuh
# DATA ylOr+YWjspFTlWfMmaPvF1AO7+ixpSc50Osm5uRnf+/0PA+12DPtxANmoeNwcWbBMqd+ZslCmCx3NqPh5BQOBTUF4dW1KY02tJ5v
# DATA diSWRn8Iwv77tv+hTI9fXwT4mfY/9ZX6vfqGZ/+zsnpv4w/2P9/EfwVGOUk2YcMb4pFfTyzbG3lzRskedNz0Nkr0tN1NOh4PhgVR
# DATA 3E8nZ/0bmvrAPXQ6Tp8Ps97rAsuftA0Ml+4eD4xA7HeK2L609GjrYOvJs09az7cOPlV2POaKSzlSkGaVYr03Wu0EmKXhCd6Jy0tP
# DATA t37QUm18/NnB9j404kVmpTJPt3Z3vrO9f6AL1e+u3edPB9tPnz/Z4rd3+dX+zsF2i1Iomnf4qGtv1Fft1rd/sLN/sLP7ia4D390P
# DATA quLd9cDgdKnH288JDPeX9g9gRC30VkVbixodVEQZOLzvv3n2Ym9360mgQNXSRkhh4mgCTRGbtbS3/Wh75/mBLmBa4qzn0sizJ49b
# DATA +wcvPoYix/GDW3C9ILExItDDB/hv1Iezpnk7Hdx++IAU7nD4jDH6we3ppFu9D28nvUk/fSi3+QfL/PhgpN4gm22M1B4sjx4+WKbm
# DATA UV6883h792DnOzvbeySJogQymHJnHB8m1c+PDtnupXp0tVJZv3f9EkNefrr9g0DZLhQ7urq7zmXIr7iw1Noql9r+wcH27v7Os919
# DATA 8k6q4ajInqLNQZsARPQnOyfbaUq7ya/phhXXXkv5i/QYtmqvC7xffK1jzO8DsJlbNoxzPhdBa5T0xhml+8x8u6+razumSkWF0BiQ
# DATA sjEYWYWrhuRfZjTx4xfPn+w8QkREq+HWd7c/y0e/wdgrTmQiJ+6NGjtCooTqiXLAyNk1L2b7OXKoKAdDceOfWodMmEsx4VZee2Tx
# DATA z9ze8Bhj/jMMW2hq0eTfro79xaCnLaPD9tKVaC9tT8eZsXsuTORj4Liz+72tJzuPCYoqNC4nuhDwEInzNARepA5jxVd2TM7cQFX1
# DATA +3RXi1++JKMsP+GEP7AXu/tb39lube3vbx8QCY6NBBapsU3obfk+JoJUwtTkOBv2p5OU5eJouEcCfLw3MhpKyAqlhmCTug1fsz7X
# DATA pu3INm+jjf4RWbdhk0E9PX7gqIs12nw1TqeAr2tw3cnwcCnBt2BlbxilbzfgqP1iNB58kUxffzGY9r8AenFYh2F90R9N6EcZCr2s
# DATA 1e6Uvy2jQi+O2k7e+6sro1BCYAUVEc/VOClYDZOQwq1NRWUzRKj8Fivq5BoRrOOEajfHO2dZBfceRqsbawtsgcfPnm7t7IbUTpqY
# DATA SdxliRUG66Pi58e9ziCBR7X3KUcYPAug7J1sb+Sb7FA1PHuPKoRnZymySeXpzjLFFJwFlLCPprv1a/WFsASOOltQUPgfGSlhWUO6
# DATA VQC1GjqK3RTwQRqNchoRxmo5jW36rIgC5Z23841ylJoQNcBN52K5QnK8guqWaoBpp475UhFeE2NmoTUCpp0MOhhMjw68wztjdD7N
# DATA 0k7J0nuiLQ0+Hs2I2EDBu5umtVqfhV2+EyMmG98dTr6DJvYBH9pcnESJAFvbb+3sP9n9bgn7UQI0AtIJMEsTIJv4gUKqMfuL73rH
# DATA U46ktlJGWdvrddszKQgnAtD+Z0+f7Ox+15WAGzDdavISqLAOeniPd/bc4c3pzF6Urd1HwF4/23M7LQ0z9n2kBJB4lHDQ3uIug6pU
# DATA u4QSOurhex910987+EF5EWh9f2+HNJEFUzBwa1pwM6Jd4FpRwPPu0KTB7D47aEHF7Ucwjs9uPBCSWNHrkjOUve1P8ninXpC8CpGi
# DATA vvAIob0XT7b26LrjkhQclyIoKsyRyVzMFMSmNEY2ltvKeiMfctE79oa2A/IJCTI7Vyle3em0zpJXaUvDq6TLUzSjjY3i3UKEyjSf
# DATA o1bUOk3KajMX7M4BjTsUnqCFJCTHbvFchZ+CU4yfPZV2cUQBgpcl+af2ZwhNYa+aJauxi7WuSIdCq9tpco/cTn4lZX6UXoXfkz12
# DATA MQJYQlY2OmoqUf+z3SefRV9o8jjEiCNG7M9EMff5453drb3P6GNIIdDi/KvUM3VHQVaOWT8AHEeanBmYSCxfGlCXDgMuUUP6PBiW
# DATA yrnwts6G4+rOljOvzKZz35MP6sNQfPHwbiSpBIUJt4iFXJRktLQWbBXv5LfhYA7zZifW2HR3UwMjAxgz5t4Azi13CvYz5edoDTis
# DATA XIl61bX0E1fSj7rODJaA5v/o063dT7Yfu0QIBwuY+CeedExu0WZPNTwk1lZSjk5MHWG39BFmBnWJEXXc/C+WsjGM0PSkabyvzloq
# DATA zhpsOCWFvGFzdv9uAVNi5uuw3vBCKrZPe2TKYvoYT6RxveHNYMo+uSDtTamogDML6inEcGn0K2oGxQNvef4Xxba4CQvAS2wGF7ZM
# DATA CwJDiKFPc3R0P1Rbvkd6X4g1Tr/l+Qm+Cuizxwh/nGRpwMpkYfQwxg6ByL0evK0vznbgQ4r3WU4vHDy2ZE1QNqQkyaWQUMrEDeLD
# DATA zBZU18wtpxLlJNDORTR3W1jkNsqUTdp8urO/v7P7Sf5O6gxXu9rJuH0BmckL9HL8koSSL20NKpuFovhXdYuyKnzOHXEcwZAzMpAI
# DATA hetq6YAUMBIW7IhEQ/yBMm3IWzz/5pxy6v7qwOQx/LVG38eQlxQRl/s4JHkTD6thRxdPX2MAiYydCpJswqYnJakv+zJOz/0g855M
# DATA xDRTwwx/FWrq0ZA+kyyKTKr9YjURlYjvKJy272HqeL7JXGQWLRy+37eXr2o0LmFFWgCp9h7GMk4uyAb59URLbGzxbFjIun85mCSv
# DATA g7LVORH1bjLGgDyHxDnJBTI1uS286N60GS9huljUjQ0XCNRYHs3BwHFXpBNhrm6hboHypybkpdDDq/+1xiYsdKi+H/kuyO5Xb2Mt
# DATA BCnFQg0vMhGyH8oYjgpmgkUlXnROJI3fSCLtaNjeckgBNQe0T3dE6MY5H0v5MXrAhjcCa4l3j2oo9jswWVAwxlyvL/DPnVr5PjDe
# DATA FhnMWGJSo7KyRYOqLBXTT0auF+pPCRm9PlH14nap3tZYeFpWQlr1HpH9LHndO5ueFXm2YV/DcaeE2jtYQMxzSTdzeBSAS0ta2aQa
# DATA 5EwmCpwYfAgzkrhQXbu7Uj4ql9+C2NjhwntikI7Q42U6mkGtqYSFBPh5TeEpfdSIavS+NxkhVXDCmfc7OjmNG+Wc+RXL/Jb6Dxvg
# DATA slYoGEgQX9bawH9hVyWKgC6d5kO8S2cGUeKXr1dWSCyrxiFYIo8+8VYU0ijAF2CrZwJIZhFfXbFU+vraGY5i7GmWlqaG1K7lRXl6
# DATA broFhOfRNqYh295Dt+OD7R8ceCNhyJEXrgdXV5QZ9wad9DWPQillGBURqOsr6+FPQepxFSfH6D2rNMn0tGx1cM1hpDJ2XhY0XUg+
# DATA t7f9b19gCkLgVD/Z3jfs45ItFsoEO7ldx9QRgzhPVHTysnZU0OjrvlH3kYGnLCS0VcI6SUem28SbdC1eaDbIbsO6PXmyg6qvvPpZ
# DATA U9AjJgiF6g2P15cih1dAwhqaqtlZSUqzzofytX0KebcJZvRgPx8ZcRiZV/JhRFq3nAYfAdZQW8Bw69YWqZCxRQ1GkSA7QM1w9s6U
# DATA TQzLmjTkNg3bxEvrS3nlUo4uieWnTWIVlSrrHFqIK1oHOJ9sUE/aNEHUWApWfD5Pz2Y1OLv+W/Bxe9u7SBdsNi6EO7x8ZH2k4Y5u
# DATA ZRhMQRaSXyP/J1pVWWabp/LQROelkZYU4XB5moDS5bu7z76/y5RVcVbu4C18yw5V80ca9bTC73LQtgVhlqyrGZB1LSajmC2+Yjy7
# DATA iTwsKHcOSi5IkIRTCgkccgKbeUIb2zeFWfac0OYG0uzv79mTdWzat3/w6MnXLuYW0Q/awhcIu0X4K2FQ8ULif+r2p9lpyfHeZHjn
# DATA 5MYCQklW74WqIgy1A/mIhUE6yDBKFin12fSa7c9bQI9VkowsxWArsExZsxRXkCg3Yg70g+KE3K1TxgEVznrtgB9uwcrZHrWEtZYZ
# DATA omVoR6CikA4UABL/WS9RBFhRjjAsLc9WDyIB8e0Mydvi22+OmHARz9vZfluh2rK1rV2ejdstZ+/CRsomrYLtbKhRzf4UcgE2fRYo
# DATA +oo8f9WHoPDfAfj7079Jl3P0btbABHphsSXsNLz7DZVCDX9qEoQPnu6CL4XDSQBSshO17gLjVY87VqAYlWVqhYkdHCkcYeRQOoKb
# DATA HMPqFB2a5HvDvQWNMYDsiMikFKiNhqNS2UN4Vdb1lHCOEUfHMuekyq0gt1+4YQrPLK73tZ5a8HXMaU+hgYz0x2PrPKLEP9aTnxVN
# DATA ZpafurTbCFqf4UdicgtL2UIyRowy5j0OGDuj8ImW+GGUt2VuFNo2hRmyg73tvDrT31MYUI6DaCzzTGiBwlNgHROXIi0T1OwPL5Rf
# DATA XRZy8jE7BPim3nmqjgH13JoMeQ/WkqxFuFcqFwFwtqELLea72P8UaW3yLkfuxGhFVUSkUmz88ip61uXi+morq/rCJREWoIo5XDN8
# DATA liyocypQCIq6PGBqXw2lRntPSGio44dNZyiFpTkmPCCSFz6+uP2vwxgi9N+7GEiE/ruB0UTB2r5HQ4pb7vKQ3YJ60RsMaQs6dgx2
# DATA DXgsN+baZi5illC8D1W29aY38pnV+MDVleeP8Vj8bG2DkDO4o2Kk0rsV01J5vimqrA+1OL/jdwWQ2Tq16QjNqkrU8fxKBrJVlvMu
# DATA UI+FVBpA9a958RczvykY6DduffM+Z587fiiyijl58tMRHLCSa5TnXO0L2aYbGCoIh+yRbH2JUyIyYY/c5B9axoLu0p6QRdtL2+GD
# DATA HCvqkNe/x6476kbb3i7v7eaGGGxJ7vFUxsZ3fRlu6Jsed+ktNZmvegOWpIokioSpJIoyejZKFp2meX3b2+k+zWvqnF76ft94iY/9
# DATA 7gJTPDQDX0TD51fJuZdoCSEVFEBwDmr3VUCZwwVEIGtgn5uC1m85FQJ6rsI+aDW8+X66/YP8RKncQi4IbJt+YMSVRvIs/FFvEDkD
# DATA zivGQkqxgI6dmps5eCpxI0WkPfIFDA3xwMHsPumoP7zEICghqaH5CncZ7afpcMBnyfgVHRTHIQSuntdVOD1XkGTLL7mJnF0SZeDJ
# DATA PB+GvF+EZ86bYgRpao9Qln/fVCOIU83nh3qejilswpwEUcFj5+MX+5/l7TycW73N29rhRGYx1QEZXQhCtjRiMInz4BCv57PsvD2e
# DATA 5L7ya3LIBZ7FOogq6tMTwIyPnzz6bsW24C2+VeXi0zhXCyvyid2VE/8E4GI9736cWyyJR/weFklbWd7ctBLGQiEuSv20i/52mIXM
# DATA PWgxewxSYkw5Y1utxXDATl/H+ROWth5Hp+kdixSYHeprjx4/eVLizPHTLG2RY70V3aM7HaiAtQqlpAkOnwQIkkxWY04+r0V0ulZO
# DATA hpgbkCpaS8YnNCKUxsnY2i3K/aSf0GCjNbJezPk8he9Hbi8YogZ9vJtOI3n5KMKe7of4o6Vkveorrwl+pl+tgBBV9VhyGiDGWET6
# DATA +IF2WLniNOOWoi+q2CqFDV8JxWUl8YhEKu9Y84NV40U1yjkqgE6k9L62vfts/7P9SiRPRNP007Pnu88O9l88f349Yw15Y8jmKbXJ
# DATA RBUlf3CO6jdGhYJRXkzmYhOg3pFeq+8GE9XhYmVLdMTCdjrJgGQ4bE+xjeKVLQzazrKWfZOmYvFNFtgjczdX4e6Zu4OCs9k6ePZ0
# DATA 51FLKYDhvG292N363tbOEzQBt+14vpHttuiWy207XnYWzHDCdX/r2QiDxex8mgWKI70VvSbtbSaGvLLP8o26pW1ckyp1P+6acZ6c
# DATA tR3zqzp3G+lQVIUHNOmyiKkMbbOl/BH7dvjE6i2BnK0U8Haj6JNu6VTx/jq1lIrbq6JJBkftaKGA2mIvXcWnNjthQmG59+N4xMTC
# DATA VzWYxtQol6OYe8ti/K2ZUrzOOfRG9de0GjHphDiLu9d4JooFVdpYfMj3BZ2FP9569N0Xz1sYRG2W8zMG7BvnmfWwCEDFIB4AuUNr
# DATA MTKYsurmNNFB0cA4uVDX7II7gnM7MBFhPFOPWTf/fCxaFWTACWisA9Qag6V2CpyWg0DJuH2KeoFGkfxBCsBY7ZgyMyQS70GmYAao
# DATA RQgVCZX3TcsSJF5OTqQgl3ozUGohj3FFETFmB2Nwr7WyiR1DqUP7op4XRyiAEMiOnG2vHYlz0gEpPV88IAXL5cUlBLxjY5uTMZhl
# DATA doFzSWbXAx8N7cIFmyNYuhwI3awR1qMFaOnvZP1FcgejyZFPYluMkEcAM4/rEvLlClXzXVjngyfCM/4IIckFu0SO0awmdTa7dYpU
# DATA osnwVQos5LDfwdzeFxUOAlmRI8pJjyfrECJtSyYUb8HQ2fvY6tph86wjwoQh7aTnCFOrjvtxoVspw5jkYZ/tH2w/tXhAhR5OF4As
# DATA JStOFpoAEYgsswbPwVuaIU9zOwL+rJW0xDhhlNZOJsGSLg3WUmtNRBtRXdHRxkx6lk9WaBOzRoCSKUrcIJTJV2fcb0TvspXsAOXM
# DATA E6nzSeEZG8s4Z2h8cXHBbmeIhEC2wpiKBeDDzXyP5UD04Et4Ab9lCwm/hFGFJWu5je3wHcYlYMPESBeY6hw2nANCLLP/HiDotaoW
# DATA RfZ2zJsbX+icYtokRGMTnc3K9NaLsXcnWp0HQV3D1rYrez1n5eyAd2yQGQwhxDxRtzfoZadF9MyRg8oNwrJyTY8R+X3uizDHsohM
# DATA TnJFHONAKhGiDFaOhEUoSq7roPTRpah0bjP2y2zK6mpsfVIDITEJtBBwAybpgypXUaDx5Y+LDaCJ6TUurC8EoRmda9GeNFFhqJcD
# DATA 3sp8I3IPmmDqNI1/Zd9ST7Kl+QHY56ESN/ND2CEDspUrxFlbJCnF8+o/9eGtNYDSQKVgO747283kzKVjQrWEYFUs+qQ5cUNO3h9P
# DATA voDajgbrMakU8TGvxeKi5TDvbk2Wuvfpdohzz1+iQ9z0ggx9OIacz+HjKhxVIv3AixBg+YPQwsVbgKGnYoWXCF7khW8RUlz3GvSV
# DATA 8kKrGSppx+mM1bxVmze5cRzsbe3ub3E+Sga1isMeUoibSw1xpYW3J/fqIA2x6HORc8NFzKWbMKOBqtaxY1hEc7LMPfXS15ivjbwa
# DATA LTxYsqwc88guoeL54on7RjXyjuvSWkQ8Mu8i0p6OSYbVfCceSvRE5+p0wj6dc68iz2b5y0oxiekksLy2J8FxlsPgzF1D1fD1fdLs
# DATA d32clPqELAbunMkRIdNUA5gr9me4uqwupz+yiM7SLEZklizJxg6HDbiBiEDa6mjYa85GC1gLiZMlBx73TsiBy91abtUlVymenxe3
# DATA Up6N9De87Zs9dpI6fJxaXoQ6PmtABPUg+kYkM7VvQ+ExvsU4Ddvo9lKJ/A3gs9LhbYL3DW+WUsHD6uK5G7QMXK9pqKbTAI9L/G2A
# DATA GbVG6geCK2RHc6p67l+36SLuDQZpUaBKfj/MoEWV4JahORPcbXSbA3hriWZIeG4ylcAEbBJIA1zsVBHdzKNn39ve+wzdwL/zZOfR
# DATA QVyeRbf0dOdvr/y08iuZXxzWdRaQLL3b9ZjQ1EJVnkstZ074mzwbpcAtfeA4G3PGKbZQnNPA2eRzJIFNL85WhpeYuUVFGmFKi/iz
# DATA XMj82Mo6gq/fkxqBXNdsDaG/FHLpu5I7iAiN1PEZwl0j34nik3SQjgkloaLaJ57cR1sqNjTDpm0X5zAj1+qWDJfkSS/ps4e02q2O
# DATA GY68LPZD0yYZYa+vm/gma5nDTdyT1QDfk69XMKPqzd27WP2hDwhx80eTq5DjVrc3JieTAeaFkhK+vYTS81PRQv9Qf1H8miYioh0U
# DATA A6+N+a5nW1/nDGQ81y3ublHXrZD7yDsGXM6Hyn3IOkHHs+QWm9uqLBnlBSeak+Y5C47ckwXfnGOUyLc0WZzRVMglbLEROYrmooE5
# DATA cyehnnrKCeP0aCv54Hjld51ByF14ET+AWTaGGEgtHZ+HbHndEHxKZuAfqq5ucakAGCKkLOcbtFx05TDAL1PM1RrrwaGMTaX7akTi
# DATA P2859vHBEdCGvL/jwD9w5J0+uewjQ1IeSkwN6wblx9doxmMgmsMz8g8hn3MVHMC6qNkqyJmRONB7HAWO0pSmTcfDYT9gCq8GYcRi
# DATA +hVbAfDQ9I076BCgI4UsLI/CED7b+zqwnFkzx2DHUbiZvWFEOQETc7mMmdKLiq6N+3dOeg1QCQmuHRd0Brfxc5HW8NnnDHShWVyF
# DATA TZiC+5NK2Vf5ZrFlVE43xDESccQWK+fcRJYsfbXfK/MiReb/ygHqPBXxzyLKKj0oVc+/rFhADlLvBUgGR9jIUQx99wq6c9nkQo/O
# DATA dZhxaYJVyHp/ZJMJq4i8O7r2fT1shHprBFoMiW4kdgycA6FrRmAWYRFqMdu8+OBZWhfAX+ayGET4FYXDV04HRa5vmF3XvgdWFqul
# DATA Pf1mMA8Vv7r+4rj/FQ5gJqqE7vn4TiIvOcB4G1DPCPTE0bYp1TKaEfc6ULHX7WHyTmRMzKNEgFLDL81HEhNvEzlTfGM112zmz/Gy
# DATA EWRmaV/J9UsLnvceveHzX5L+1XiKJZkphyTTR2bTOjKplvri3NzViILhsG4cEssOGOnExVL9WHGxjG//qxQ5CD+uT07/HzhhZ1oB
# DATA +DysbyYkQiIvHcVNA0dyenry98ZhLke58BhycnHBmh+jxA5eRCV0x75dqwmKtb7ujlcCdJhIclcytzt2jB+dkp4KYoHa+KQ/PC7F
# DATA d+Jy+bqCsfia/eTsuJNQsYafSayisoSwp0BIEutHSBmkIvbKG+vMMIZy/FcbGkmNJ2tDca5ht2fxaGyoQH8ekSsKvekI2+bjwXVR
# DATA 72KOZVteOITSMerRECqw7FlENBe07HHUEFpKcytgAbKoa7kt676pGWPL0U9ar3LZBG3uSaheJ7a4xODZQgQuVqndQ8xWwK6uiPkq
# DATA Qj6HtwrMyXBVClI2U6WiG1Im8vxVjAtWtOCwZXorvH0Fg6XnaxdbGQSKL3xv+mR7d3tvy1IXf61Xp7e9XRgtvjUiLlX2/CakqOUV
# DATA Yneqgj4vaB+hGiMnnBt5T8SLXmzQsqjwHll2royzyoXtn2YF7NF2Aq3n27uP3Xi3RptRwAPfRHCTV1wEEJbmt6BNhLS00DwNfgdI
# DATA oaijmc0p1riHDBEZLp5diDNfXVgpBPHcVu/QWpZ7VBN7J1230KNOy1uXoKW+XIu58/lWOMYfye7CXyT3s71aas7+5cAbsdPfXG7S
# DATA eGMteoQJ0hg9Y8Ubg7bNdzb97HON67+jUMAVCHhgdC4WHtAKzJKpTeeUM1O2RQYUDDp3tJH8D1jYczePJfCLYzKE4jzrta3xyRSB
# DATA /Zy+lKxAz814hw/w6Hg66MAxHgH5S/oREll1XGREGIfTSURwQ7kW5kTAMWc1nVAXW8YY461EOivF1aoddw3lks3nWkxQVIO5zZll
# DATA rDgrAIQEIKOFqDPrMfSqYzbqXGw8wgHh8dJmgDEzMQHEmd0bwugtqgnaLDxARZ6rFhKpc5gCrEk9+oM1M0KYcjBNNX6u4cBz+583
# DATA cP7KT6YUVE0GnjPKoY9OFkej7ocvoePFL6PYUPUsIvCZejeZNnvLGrjCXH40hcFkkYWdRBSDoKxo3NeogKPw8DQHJ4fldAFQcaBV
# DATA KQSCfAmKSvNa/PlwNjBbDF4+cKR+YkDYiaYDuJshJBFlsOlpBlS1ACaORiQIE6UaoQejmrBRYBZURuMebAkr8DJ3vUjk5XLu6FiZ
# DATA p8YKxAXJDeAqphJyqNBvvPTnxwN8Md5zmxhnIJvAdX6cG1AdSL7erjrhDIraTJIVK2S/3qlHS2EtqtMEBvLHiytFH2q1SJDVauFq
# DATA tFpihYBDA/52UqIzBwD2Rzf/D08VWn8lO6yNLv/oPf+3Av/dXV+nv/Cf83e1Xl9bX7un3vH7ev3evY0/ilb+6Bv4b4qxI6D7P/r/
# DATA 539+7rWr2yyeut2oV24Tq3G7cXh1u9e53bhNjN0E6ANslduV25SlAl6/+buvfvzVX735xVd/8ebnb3751V989ZOvfvzmH6I3v4je
# DATA /A5+/farP4d38ObNb/DXmy/f/BYqWwwPNvG/w+d/efOPUPjHBbUqEfz9K+jh11/9eyjy5lf4CTqFotDkL7E3+N8v4e2vvvopDOMn
# DATA 8PdvoSK3CMV/+9XfwMefvflFDbonEdbtxtVtlUMFBvHgVmdIYSAo6cXDly8HD/BH1AcOq/ny5e10AP88fHCaJp2HD87SSUIZirJ0
# DATA gh9Jekbf6QtuWnx93ksvMCwS/FQSNHx90etMTpsd4CrbaZUeKkoTUM2A2UubddPW6WQyqiJ9P8eqj7iV6j7mLetNLqvPh/1e+9Lr
# DATA QJiwajZuRy/jLO13X8abEYPcfzm57Kfeu97ZifOGTOUam9Hw+Iew/PJpAIcWFj5OsrQKY7FeYVCWKrNZ5m0eOhYSeOPfis572ZS4
# DATA 3kl6PBy+iihdDXC5J6d4JzmFg+R02O9kdBROToEzTuBYjLIzZJz5MoEJlSOUdsN7OJbOojTJUD0xGeKhWIv2J9POJdUdjju9AYZd
# DATA kkiywNAhS32GASFp1ITqD5+jaBvZmy5aj0RfRP922ksn0fmwD6zfg2Uu9IDsdcZpH6fRa/PMYLhdfF5OMsCXbBnf17LzE/xGPCWW
# DATA PYPml+Hlh6/P+tSr3RKtUnaappNQe7gEtXaW3bAa6flUNV4KDKGfK/JDLIGMfTp++GCZC8IP2gm4TTDdH6EICYGwuk0qqHXYLH1o
# DATA ksb0qjeyR/MBHl9YaB8+4OoIHjxYTni3Ya9W/WO8WDjTMao9bMZdFWhjkJwDj9JLqv3kmMHyFPkmeN07SQT5sIeC9p6dp2Pcx9SW
# DATA VSoD/OmlmS63P0pwA0fy3i+OKKjL7iE+XgzHr2htqOgyjEeAihNm1rCDVRV8HkhqJgOKEep6sAZTpvrDg9MElnCEPLF2aAMUh9/A
# DATA qw1q0Hz94YMRFEsjrAvb4zI6Tc7hx/AcpbuY+e+UNgCmcqTPuBrEZiKmDmsR1IVrM5nDAScOu22CW+xyOMWlw8pKUKW2LvQ6evig
# DATA 0zs342bSkPmYcTydTLwN4y7Fx8Bkqm6OU7j3YrxdAbTXCqoHh4MO7GqnvUUWbRnGinjO0A6AXV4w0FcfPhtHox4MbDoCIAFp6U4B
# DATA KMNhH8G9iuB+lPTbU1JHdvtD4v7ThO27I6L2UWecXCDFQbs+hDCsl0aOqDNMeSk76QSjFcINAnjXKe4tGDjqfSlwDQUyag+BRe+h
# DATA EJyhfhP80/NdRoR7+KALrDxi4sjdUYBdNihQ6su3BGzX5I6C9qDgQ7X2zlBMIjKss0WU/VvJ2WgT+fXzpH2JA4r+679ENxo/r5oa
# DATA 9TISJdxPcpbDoW+6/cNp/4fTft5pz2j5Fof8ez7j3+6In3/C/7/ogH/P5/tCx/vNTvdv5HBnjLSnrw/0/+fsICL4889OoPTDLFUn
# DATA 6JY6NlmcBz3S6a7OT3vKyNckZprDrjhAwtwBrUisIkskIGj3xnT4kgDPAwSBh1gadQRnJE7rp8mYQvmfwaENmNWv0AEMk+idpZ3o
# DATA eNrrT3AGSB8znjKM9EWGVYjbUuNTM8AezIneVvxA5jMEzA4MB/3LWrQzUTxcG/N844mPgINjiyTNRq2tWIGkgycMiRdpiLgoVWIL
# DATA cK9nGcUxivbT9FX0I8AVNNZSyoXTtD8iWRUOMkq6XVwlZEiSbjq51DP8bDgdmzNapgacThaNpwPNah6jsVM6rkXbkmgIQYrzmI6Q
# DATA W0E+U2Eh4nhGPAwUwBQKQ2SSgDxkWCbpX056beJuYG7peII6/hOYQoL2F8q0Ddtqn6btVyTyJNUOiT2dwfy3H//PmcwVpbxkF5S1
# DATA hyNoh/hJa81q0SNc/4j08hTxAiZ2iTOXtrAGDvUcu0jPYKW6qlGSuMJeT3pAi/pphfhAzGKCjDLDdmBGDntiQosNdaCEhkhEjgGC
# DATA WKOHj4cXA2bzEJBsWdYGjEGLNW9ojKdcJEMmHIYKuxwpXDtlRD8dZry0aFM4Jhb/VZqOzKZO2m3k/ftD3AztNr0/wYZ6GCERAy8R
# DATA MOH0wHayWrQ7pHJTWjUono5pyRCWekdhoyMc8GmqiASgz1OkNr0JTwGatrcLQGwKyE1oLrtV7cr0NTCLOMULaEyDokuXF2chd2DE
# DATA 2nApw+AeaI3XYQIToXsJrNC4p/xKOwkOsRZ9jMSHbQ9wScZ4LqZAWwRdoR/036JvjFLC7b/1NWexw2ahG86CbPI3xuy/Da//Hlh9
# DATA l2kCfv/O1fHwNbAvn2P6mmPC0iq8ucZKV8DxDPv96nEKd+HecNzIzqDp02ts9+osGQM2NFY2UcNxMkbRT+M8GZeq1VEySsflzfaw
# DATA D1X4FfBl5U2kX436vdHr5Xrt7kbEX7Ct8iZamQPJv6hejJNR4xgw8FUV5ta5Tq64md4ANkhvsomx/atTNB0FXi+tDrtdmFCjtrqa
# DATA nl0njVNs54rKdDAXCG2SKiB/+9UA9m5jdfT6mpGk0huMppMK229VsAaeNVc0ROlLlazx36tOL4Nj+BI+U9fdfvp6E06Lk0GVTP4a
# DATA 7RTTRG/+EHZnr3tZlf2lXsP9FJgWPFcb6+uj15sjZg4aAAmgmVG9Vse/m7wCjfrodZTBlaYTWfDLARqJx2DiQhrmq17Lao6TTm+a
# DATA yWd+qMAIeD2qFzymuxsrm3CVyqCd0ZDyXW96YGzgBUZgUtNbTEHHvLmyhglkapCxxVQOHaSpQ+JQ0ZY7SztNVDofXeUmStO3G2AU
# DATA kyYasDJ4qnSuhqOkDbfBRm1jQ81G7oCAHF1gELIq8IM9PIGkqvuSkMJ7xyjivVQI45ednsG2uHTfXsHWRoxprHmLSqUA9/mzwmVY
# DATA mmseB9Dr0iFdkegYh115VLZe4lIOj8o5HKabdKO+svLfOUh3F5CuALuw+/Li+9igLmJu7Z6FuArZ1tQkvPFXrJc8fhnuKmzNTRkq
# DATA /WYkruaJCGy7anY6hofGyrXTHPDqR1dqcCvXGiAWFOr3V6BtQLbe52mDOCc4pq7pfqT398m419k8ATJUW6OZOdtkZYVL12hKuk4R
# DATA MaBm7mEr/v63W12HVruYdQHW/2rmGqnZ1WurG6pVBiCMKz2BU/zKbvjeyoqushLV1qHK9Wm9crpaOV2rjISEVyfDEVQ/rTP14+7w
# DATA foVsMjdUwUzLeN6djUqrtXXsunK3tnF+Udmo4UMZKPrKuoxUYFLe7AMnBCiBYlccAH8FkkCZNSrV2sraBlTdPEteyxzqd9unmzKo
# DATA 4yHszzOY6BoNenWxwdWZnFbWYGirBHgcWv3+nKHBWFY3EJxu39TzGvcMnUQCdWhxzW/QrUk74xoBrKZ291779Lp3dlLJzk801lAm
# DATA tE1rvwqCJNPJ8JrvxBWyM+ATXbYKpourr64AIlfwwlTCmlE1uos0XQ+EDym7pbm46h9cJC6Hs39ykaYDwuR6bcND5frKhiYrGmwh
# DATA zL2ukfSCYXmPYbnOsFzNw1JBbXUFECJ4DsFdwp0Q0QXiHvAf3nircrTS32sSh8yFgr9Pi3qPEj65RKrfRBb4yGc9GppT2fS25XUN
# DATA pUFXGDyBCnZ7r9PO5udVksHAvDdxU1bruMqbmHEDII2ALiDRmizgPKllPoKusBWseV0DlmaoiGOVcwbexbVzqR78o23WkPZOzwZZ
# DATA o94dR/D/RfSNNii1H9WAc4BuaK5EYhVbY5Z0fQM2Apfu9k6m41QzkuZtOyFpqNVO7f7q2OxPnFXtPnUrV4n5uHDfq1/nPVoTht8D
# DATA zcaKQWsqHcZpqUwEyR3CwpvJBiqQ7xz527BHSR1FQAzdUgA6XLmrBdZynI7gVlhaqwCew6KUViqwskA2zIiua+1k3LmyThbr1LlL
# DATA R72Phdl03EUX7jn8xWx2lPuNRg28/Vfbp71+Jz9NKlJD8XmldjaFS+mVzSDQG2gIv9vI8xHD8ALN8m1u4KPgngqzzxtAZNfh/9fg
# DATA /+8ia+WtE+GnswAks3O3SwGjrg8YbMSjhjznxmByyjAprQ7KkZpL0Uqs5rm265qWm/q4DmQApoVEQheJhBtgAOqDH49WPPXxB7aI
# DATA skrrkLt3H/c2vY3sw+/eCr6H+fQmi+AoAFMojiIvzi6hpDbXNZQtaG5v9evES+yJlDl5FlGdLTVm326wA1eDO5DaYmPAK4dYMbtn
# DATA 0/lIcG4GDsjM6PxYD90orb2wxuTo4pScJZFaNeBSRlRUjagBU5lc6jnSSVhjs3WHx65tKK5Ztt8qkxUliwxw2uv27FY2sVSVFDjS
# DATA i5Fj9ntXC7Ab3h0FKAfcm3rt9MoGiX8fU9tRbQ8+d2u8KHC9PLGYKD30lQWOCa4bJXjdgPvgAkji4Eakn1bxCXm6/IawzxSXXkcr
# DATA izFo7iijkXUwy6cMDvfByZUnN4ANkpz40hFmbWfgpl6gVb5Ejl2cuX83f6ks2JrHicfbqp2UO1s9vsAn4cwQSJMRXwqxSqNu3bPq
# DATA 60QpeSsYQPvCm06SnaYugA9Pe51OOjhyNtAtTg+YDCbXsN2utBzsNbHu9t0I7wemv/U5W98G5f2ije2J3ZLB5QWKoa9RN8Kr3E3O
# DATA ev3LxiNgsYZwLldexk96x8r2/elwMHwZV87gD7Xr7nmAZQfO4V4/s8C0ujg+iizlypNK+UIrj19XfUbO7Za2sFyi5m3XTfd0pBGv
# DATA ysXHtLhmH/chpnMBBtBH+ftmlNbus3BgA89XKeCINeimsph8Eii2kVZ7N9ECdKiNev1+dTy8mM9lC089SUd61RUZXTefkIjr/b8u
# DATA BHqCIjxqz98F1/RJLRyQyH4yyoArkR/2BdrGQDqYJ6eVSYevZQSLBo7GOUcXQsbJLF7rugYjSK+IkjMBb9SXq3U6Gy0ZkcU0MM8w
# DATA nE5G0wl5JPjA4jsVWelXUW0T4GbRPS2ZDMdX6tgN8bKM0YrQaYS+/pOztNNLShaLdhfIWvmqUOhgSxrW7iLtFamCu1uEJ8mfToQs
# DATA 7EWB110Gk40zdD8tvH96m3INb642KN37pBa6bBCtprvRjZgxxawWj8fuPHyFXENlg3tDXBAsOYah+Fq+2lUyxg2LS1EVH9p3KRs9
# DATA Vz32WbGxebxYXyO8IBhWFJdbOB4Sy7DohU71j8ziOBeKVRbTyVXTPR4Wn/3C0yUiErj/ECEHVNLzHpFKM6uO0860nXaqZ0NaFn6E
# DATA 3RHSiVHjdyp3Gmz0AT+SLu6bZNA7MyIjc85vklKkF/iihsHeOWov8jasKGWUL/Bg/phWU9gPS+TLmjqLKhAXIHfDY7ifvtK3Db/Q
# DATA 9bWjMVRWW2ghCH+i12f9Aek+0S6vsbx8cXFRu1irDccny6srKyvLYuCFBkQfD19jwZVoJbq7Dv8jtS9ifMQGgPBMLyMmZOZ5TPXq
# DATA q/i7C0cQ2Uytrax11j9Cw8eHDyhcCVkLPa3fjeofna6tnt//dHX9vL5yCv/e/7R+93Oncne1u9Zd48o4RFcrmsEJmb77JO/DRR4u
# DATA 8zSDYV/s26igMcYCxD2+xC9kN2es68T4Sb+1lc4NY9GjbQDSDunCL7UBngWSj1ai9fWNaO2j9Wh1Y6W/trIa1e+vVddW7kX19TUX
# DATA MJ27neN0JQ/Ve2vR2v2179Xv3e2vrtarH21Eq3WovnL/HP4+waY3VlbdptJut04wpuvCK5r/B+sbGysbqXlZ1Uu/lusUW71fP19f
# DATA rZ+tVFfr69hl9aOPaDAykKjOWPGWPayurkSr6/Xz+upav16vRxv3v7f60f3Pn66vfRSt1QF9Vu/36yv3quv3vrd69747vfvtj9Ik
# DATA yTV5bwOg8tFpfXXlrHp3Bf53jj/X4fXa+v3Teh1eb2zA/87hpzfy47vHK+vd0MjXCzFVzBcBURvoWXglkuCGYPgm3e8bslk21dW2
# DATA 8cHdjbvHa/hCS5+gCv23qRma/JvVxgdpPd1I722KjK3xwcZHd+/d29hkDqPxwXG3fb+NNUjsDJ87d9dWO5us3m+8jPfTk2EavdiB
# DATA 68JBcgq8Z2WLzMcyIIXVLB33sK4iaQsVR/JUQ2tLYJkMSW8wNxmtukLn+8wI6OL6NJL7zScp7OleUuGmPdXcpi8IQ+ascq+2fn5R
# DATA uceCMGpYLOUWud7PlG/BTdVt0ReU22yeLEy+gpKhu+eEU2rkcJXMclIBPH/aPbQkurqBesDoAlgC6LFFLLRauRlzE6GI1jfEcKUC
# DATA K4XMrDPbSm5q85g7kezlcIzYhq+TU7nO7/Uf4lZ/GaP1HhCJXntCluQDMoCM/hjji0XNh9oEsvajaTq+3Ce7gOG4lJWtsrrw1nic
# DATA XNa64+FZKVxvq9+HqlZdseX7bnqJoRdVHdzhNTQHhNHS3TL6MHoZN+wBnqVn6J3NaceeJqMSNapzhVM441fpZSXqJv0+Inc5ukKH
# DATA f/iXG+Aw+WRTts+DwIzUOwDqkjWoDzFGWXlTZxWm7CrQ6bTfj74dlXgUtdMkw87K8EreQFP8pmENoBGh6yfHIqBg+5vRNboqt09h
# DATA VNLDTVrE6tf2rMmpnqctqWKvVPWMq6sPmwILZ/5ZwfwrPG7EksFJr3up0lZpsKCJTWAuXXTuzg8yuSzh5bmslyLFALV/XHoZf8CS
# DATA 35cxNI3BhtI+pmitYWnxzoCC+LTpNXk6vChsk5nRG7c5mJ6Vep2ymc3u9Ow4HZeozZcY9A++1hQ0naodMSItcTg3bJzjWUBPL2N8
# DATA XIbt3BtsKjcX9nGJzeinYxz+i70nNba4fEbuIfCM0duijzGG3iG2c1SJrrDha1wMrprYG4lrb/dTipfxMk4IDEkNrf8wZs24j09q
# DATA vLibYMT4qt3vtV/BnkLT04PeWTqcTkqlMu5xHNQ4PQemwgwK2sG878C/Cih4KKjfUKuAtwns3IbTcIAGzaXuACeOa4MVKBDeGQb6
# DATA 2D6HQT+RWCvQRjY9PuvBQlai9JyW7SFUo581jBoDfx+zYVZJlpoagus4XIW+h9k7epPLUhnaH2CBaxnqH+PwDtnhIjlPj2CQNai4
# DATA nbRPS2L8SR31gWnOEg5GR9QFBoSPOJ7DI+nxFlPAXkZ/S1QAelT1Do/UKgH80Toe43KWuX1+f0mRLKl8DU6V/rSTZjIMQxDhK/Sn
# DATA jeQmWyq0Pa6wZfqGQ9unTVu6xGiduo6L/NjntwEx93k6QGD4N/obXW+qoZZM9cDaEL5gf2o67wNU6vcC4IAJcClgquFqWzrHUWDu
# DATA 4GYULN6IDms1+t2phErohQIOOMNp0jiIvFqT4UE7IELqZuposGo79Omoo4zJHQN+gfvHYvYetnHf5DrcFpm0Z2LOjj6hwFCcpzXa
# DATA 4df8/y56a4WXi+PD1wbBqUimlg0+aaDoysVLyJVhDXUruIjYSI4HeBmHLPnsYdF3Hhj95AHQMnDzBh/4u6LE/BRCUfK8sXFUWBAT
# DATA I9fiX2YNuyFjeYkhPM+A92Bs00MowpwCeKoBCPaoR+DvBidwGUTWJyI2PtL9wksPy9RuKcCrTe1QEcYsRBuDN4I7Cj7IruoTmp6E
# DATA knMBOPXhbkXMGBVRzz655625w7FMNfgJyBSfmFr+NkMx+uILGDUiBNCvsxL8GT4ZXqTjRwC8kgYxbISMgq+pLp3awCXhxAmv0WMC
# DATA yq1sRtaGQKC6SAcvbNSgoIsYvAfe20TTHY3BRJpLOfrWt6KSGlqzqUaCg6KGNApouDWbMhXEXyzCaj3o+RYNgbcb/SzzXD78kBdK
# DATA mB3UHCrw04Nhd/CpzCVMswwPpI4r5kSSSEW8hlhAN8LfylLGOz64LcJSGmGa0cEBK69WNLAZaR/hXrSQAqej13HmBnYqQUc4RkFT
# DATA ALJqpOxiHBYUjqNUbj4knvFl/B3tFIbb5MMSsn0vY956MP//m723bXLjuPI9v0pt3PCINLubKDxDFOmgHmhrLMm6JG3FxGheFFCF
# DATA RpkACqoCutnWVYQkz4zvhCfWN2Y31hETe+/Ejdh9ty9k2ZzhSBYdcecLoL+CP8me/zmZWVmFh0Y30c1uMmWTBApVWfmcJ09m/n/f
# DATA l+88B+TmPk3uYVvdter1G0jw//p672P6b/y2niUnyZRdrV4w9XyasdyQAPiwGQVADy1/DxlPN4u35u/y+V3/8VvrQR2hDZ7rjaRx
# DATA ywwwP5DpDma7g9knHcx2B7Jf6gPZXmG7sToHfakPahvPGf9cOAE4tI5vP5iwWh5GtjgEbESf3s5v523FfE7ucp3nviqnGk8SbrEd
# DATA pRx/8TjfeYN62nIz1ItkiIZZqWjLepe1gicXgiF/Kx5ULy9eSZPuJchcedPRuKejofzYd36ysPbFZirZA6WD/9Yz/IXTwRkwucNF
# DATA +zqVO/RgqLxgD6XTI2wqNs9PRDcgGwR8IlbXKE9tuKBpIR9HnnVpXPPg1fUwB6EwP+F48C6lOEn3vJ9MojGf8+3z2X16SB3m58rq
# DATA UVgD1Dqqk55sQ2AME+6mN4OxQAGNlW7Ahso7XsnHrXUE+DwxR5usBTKy93Euzcjw/BjHnFHhcLqbiQ7ehzPj7vXGuMzqR/KOmH6a
# DATA TWA2ZHsebCn+MWOTKunDyUMtJoSlppoNmcsJSwD0ZylZEbNFNYSX87CtCcFZb856O8l6K9Ywp6/j9HVOa7atNBDPS3fnAbawWXIQ
# DATA eA18mxDOMwo8L07jbd1wid19ni1XV7DkeP2D7Q8siqgtOfoaFzY6IbFj2SegM1l5Aa+Nrr8hPlHdAMe8HoVCktDMc6a7yq+wV4y3
# DATA f+w1eBOR1rCm5POGKFwcBbzfqKE2k0QT3n20Jz37TY5jKarihTDVAd82iKh+ysTTXDDRrO01txhN8YzQz9pLwxfeEEeripS+x0TK
# DATA PPRGwh1+Hrkq3nzHf71aeeNmoqzC8j0NdU9jzT1+Rd1EH/K7bkq08qQoW13nploFowfzZjC1JY/IbOAn2JBIR/Re3hOs0qlWQzF6
# DATA 6aqZX5KeJz7gF01onJ5KDtyUIDB/Urkl67R2KPklvUPNXLljGZwBJmRWB2BLU7HRKM1+RqmC8IsxKN+nwZD6ZzEatdfaav8YY6Mx
# DATA t3w2FM1AG6diR+55d8PQ4zOxyizI9PCZ25Dee1hDUaqemAiYkXYG2XRx9LJRKoY49Th4I3Zh0Nsms+GQf5xhGZYG9TjVxv9Ps0iU
# DATA d0TERnR/4m5MWSwS81pEStd5LNhmHAUyS2BYsCmNngjzmjjDtJCSNJbOT6tcsb0+hPC91cthDOxGrJfJmcYdvBQJl8bLbzXbA6Az
# DATA nJ3hfJLhXDKQnOXsLOf15vAlUKx8SG/jxpGJZl4QqtaQm80lzUYMLkbnjRURH0VTKtDxvkjbFaUXhQmW9DFuJUoCMldKFD3EspFc
# DATA 8s9iu6KUgtqy+MagxvpzWshZN3aKcU1cZkakEhYM9ilBbzGQ6LIYdtLvY/sXZPq4L8i8QXJIP3tUQjJccl7vecq4gKQlxe4A4y76
# DATA maTPHQPnuSVfKT4rTk5x0JsG7M28m2K4GpqRzqTITtp77JQLemTjQEjzkHqsPGUYeXd5yiAbohl1Ggwz3i4GSwdJ3CdbLNO9WkiF
# DATA N6DejEuJkymnfCiEMYuKw41IptO+zJ3EiNH+smREVuNUqQsGsAoeeVopZE063w6OuCden1CUobgqUcY6jQ+U/7EfRZSsMO6ztB/N
# DATA 7mCoQeAQexixD4Gq1VS2YDDdmH5BU8QvbAJ6DxnD4zFfEAGyZcVMWTgGqSrqhBiLrjs7kkp9NEV9xibRNYm8H2VLEihmRaEKLwqq
# DATA mqpOVir7LQ+hCo9KNkQT5FEnjZYZsSjSHW1HgvAWhDHO3slAJ3aqEpOk2nsf+i8hZSLZhWz7Ifmw82ZkTPATj8Tjql3KDClD7R7J
# DATA O8We1FNpLXXaj9MRL44sm9tyoh5S3sh8HIzeCY6Rkplk1NapBRnrOV/8zsR/LfdTfnB1JFNATc+DTGxh7p2897W4J/WuDHtgU1qB
# DATA uI0PmRrPIzaPMTUgw5dKOphNY3QbQco6XSOlPMnqp9KhgAslbmOyEHBdTSlWpvbH4+RQ6idaCTUR9JEQbNUJfjvh8KfYV4nclrZI
# DATA CZrAlcBdI49tYpdYfgU0fiplbGmIhwaulfJ0IaXipuwjG4kyTFJIRY4D0tiRESwoyBa6YZ4ijI/KarJmPmHLylp2vtjML6G1/9ln
# DATA O4ahM90HnDc9sgk6/+/xL+d/mD+b/+v8iWLkPJl/R//76vg33vz3YNrQD5/Tn98sonP+B/3wlG56ivsZfvPd8a/nTzz68jsD0fmG
# DATA ApXL/BWgnS+Pf73jHf8tPUfP4DbQc57Rm75ljM/f0w/C1Pl2/vT4Vzoyf6Jb/iCgHsB2HEvnCsxm0Cnj+BJ1OF36Z1oQzd6PEgon
# DATA jXvaBNvz3nk8Gcr4POQeMZK+IRvEE+othpY3QneOWEWcRLnPIJ8LJcOhGp/opVrmdy1UB8uJKjzVUhxapzi/0T3IRYN1lpXM+eF1
# DATA 8qpjboVJl18uPzAUvWlz93vynUf0LRN2eFxTw3qiNrdiMHWAnQ2LbfuIHay9R2x9onB2chcjG7/IPThksigqGKYDGk84H1luP5ti
# DATA plrarayRmgjCHEqJpwt8nZOr32qH5pKW9aIwOycnw3F2nCVwHpaABu6c0QB4RZybFzb4n8vYv9HQf9qR/2IGfqmei/mQM3guX+s6
# DATA DxiPlQOM4im+ekl6F0Ee9LrRRK0kqsKjPEvxUgW+iSRrMpU3O56SwPbSwdF0MOJQ5IAJZ9CmCB5VZPlCJHXEQ8bLzLBSC5X0KXJ7
# DATA qvyzckyuHxwkGBUUa0bHGC8QuAkPp/SgthjUubpbub0gxCL4fmBGHAbjqe0W6yUTx9hxjB3H2DlPxs6mo8pG05xNreQLNvnPYvFv
# DATA w+B3tB1H23G0HUfbcbQdR9txtB1H23G0HUfbcbQdR9txtB1H23G0HUfbcbQdR9txtB1H23G0HUfbcbQdR9txtB1H23G0HUfbuUy0
# DATA nWojOCttp9Vv9HtXiLazuPa8EXOHc1flHnZlevyuZrOgkNaol3K93mwXuTlR1O4rsBEON1L0ehxorckyID0OtSrBsFSGX28WIT41
# DATA yvAlaKRW3atXKx7oNn6jM/TbFa/aLFF7mn6j0e4uknLqNa/ud37md+qDevugWm2M/JbvVX7mV2qDeuug5hej0KuG9W53SSIa7Uqe
# DATA CL/aMYmoFQOodqphY5HYQxnr1VvVgcpFi55jHlig5zTPQM/hGmvRc6jyF+g5jXo7OAs9pxFGfT+n5zSrTb8VGnpOr93th52cntNs
# DATA Nvz2+dNzVB3f5WpsxoWaEHT0cFu4aZmjqsbjyE7n4HCnzZZUYY2p0Rvc2pi0U36bcnDbri0xMdRdOFqwHdyOHeIibkdNNNvGWEUZ
# DATA 3+KdHIMgTA5fr3jwblQ8XZIFQA+368VXaLe7Mc1bsn5SyPXSTYW1MhnOSzCcWyv2AyyOVoqStMxTK+u2a0JWXY0a2nRDyWtG3cTv
# DATA ZFeq6jNWU3wKpX2CjVjIPLswVWL05AVWiKPsOMqOo+w4yo6j7DjKjqPsOMqOo+w4yo6j7DjKzqtF2Yn7Yr9h3QM1/lP7m9Sd22rE
# DATA VAOX/LbDdfH6rc8sTM+nkm/IjNscDE4dmWBu0BPA73z82o3Fd6hKfUsPKOolizfmt6gDGnQX27m3FCToAxzjkpbPpvzwiE/n6LeW
# DATA o7Tn/ZU6A28dSuODZyhrqlAmCrv6BvrhB+tG/C1lhbGZTVJ5cWpv+niap5l6x49fe886eWeSQd2lSoFMdEvnfNwRdHcEfeMj6MUD
# DATA Ye4sujuLvnhqcKXe5mU4o16q44XWYovTsOePBWhRmbNcLUUJ38ZhFGQFdAufiIayJchFPNJk1J3JOWGtpMJb6UqnZTc9g85JYH1G
# DATA jOUszqckQelVcKFORI+vy7KLiN+Sw6Bql9Wifr2yXVEF+ZNSg1fC4frHXM/cXOHttpD/jDgcE704s7J6tcq7MYhZGl0+FzXerTtM
# DATA 92k/taDQDosShzvRocl9LO66StBddakc1g/V59V3y/F6VrnjT6vv5D5Xycz2otX3Sb/N6edPa0Tl5aCplnMXO9RWc8cQs0bLvVAT
# DATA 4D+3ZV3zX+Ct565OzwPkk87zcp6VxDbZrW96AbGquealM86NP//2v5l0lCNu5f+EJUrR5wyDSa6/qpYSeU9aOoNEAmy0hKUYxlCC
# DATA Zy1qqJXGVAsZyhRMJlQnWV+XOma0PprEjqdy/B96rFPoH2kdWtaq5sUPLTJ7SJVbHRZXPi+7ZeYnn3XTyA9WG8cZLqukmJzRRy/p
# DATA AvuCuabQvRYIoKzaeqoiyivqaQvo7/7n6gLSlV6K510UA1XkTBfQw8OE2mhKHZunT/llygShPmk2hieShqTJnvcujfIwckbJgQhS
# DATA UBpYcADCBvsRd6soINk/rMop0uoWqrSev1RMCi6sXEy3cNpi+cf/sbpYVBcjpSJyoL0kpcmIaTljNRGWyzzN6bKmK+sqyydvEqBh
# DATA hWI6iIJvn/rw5FAVUdGOZGl2NosL46B1OZ7CiH7+UrJTdGEFlffLp+7hfrO6pHQfL0X1UZCOPN7dlXdxh7gmcJzwAFrYVDL7VDC8
# DATA foG+LpLhfhyKlEbE6rHQmY7GgOBICajZQDdickc8FU0O7I61f2bqxPOXT56MCyud5xmB/q/fbz4CvYVBNkplSLB0wEdsV1O80kfK
# DATA 0uYmFQxZvTzwRjMaf4ZBin1yE8gnI6O9n4nxqAYYMpHAMJBmgxJ//pIoRPcqNJV/2rSpPEj6U6+Lah+gdPJuDWN8l7JoBC0baMb0
# DATA aOTB5IAVoYPw5wH256gan6GwUrbH41E8xHkD5BRUKshS/2QWi1oNVBBZWEUKUCtCb6GpFJJxpgIqGoHi0bSNQHNFsvvOB4n2PWpN
# DATA IZ59KJ9gkgqVEQN0wp24Llgl/PM87KBXQ9zFwbmdK+0MrjTnOXtFPGen5XVfCnXHwv7L9dhumXPTQDrFVk2yKPfZqbWS3H1JVSCv
# DATA kGjaSdrQ9r7H86B4L7aSrbO8l8qIriJ6L6Zc3WbUscX5gknQnucbSWx2Ju2I70jUIA8T47jInUyK2qccwiNAuY3MX17QO94sE3wp
# DATA ZAEpGOyMkCRkZS3sJbVG6XNzncz1NM+kBf4BPF3jfUADBTAuuj1GCtxSFtTgG6WZ9bqRE4VZnYuK2kqiHvtMyGKdSmlh3gPr28NG
# DATA XOhtHhTqg2xmk8zi7arQRB3nDV60C3VuIYf3XiXj0Q7CmY/OfNzYfLTrmluHdeuwz2k1rjRSz2cd9n3hftpK0Tnx8MWQKi6CEs57
# DATA f1C9+NhgYZlT/ZTjtdWtC+uF+UJSvjy2am3RXt6wV2tW3V9ytJeWElY9VXD/Fnzaq54ouynLbtZVz5W9Z2Wv4MqV00Ip8CYrxBTV
# DATA KYxDrg+y0PSDN7R8pSoWdS/45bLnVFji6pypJp2XF8FxyFzz92yLytPce+rUbZtKXGb61RtQxHlTweio0ICuLkIcC01TJqFO0NNn
# DATA ylJNhvZbookeT2TGySZ4pGdSBiJJ7cesVs3YVKDQ6Bk897buSNC32MOzpwRCeAJgTHb11EewxKXvkXXHUFzLvK+cYgLhbizQqCdu
# DATA JosFl88blzuN87qW7y0Ex1P3UVTSpRI+mQH+8ljJFhyQpZCSUYEN+N8UxO/Z/Dv688f5U2D4nnr4xli+Z2D9fTd/AijfIh3wf87/
# DATA xMS/r9XdT+ffeAwK/N382+P/ff6H+VfHX9Kz36pAv1EIwW+Of4lr9Nuz4889+gIioYAAQSZEHOQ5AAuZG/gnBwO8ClZ/oe/uR4dk
# DATA O/AkehJAulZBANCrj/qQj+hCsktjQKjjw6rsXYXVTbrMPFDdc1d3WrrPnk34NWhCHB4ZGT3xn0TT2WQtAvAupC68cJZhswu1ZwcA
# DATA LNj7upe4aP7fYrGcH/2PLSwmrOS3FupbmWd+MzqKJnFE1oa+/x11wYPKEBDaSbplDCCrhzESejbl8V+d0aIm5kiAmxbh9lGA1Ndg
# DATA EZza/Djuo9NhGDxDnLFdLk0eQ0Mn4rPLYsrDYEUtpM6tN8UWhhlL/8uPmdp8ovee6IomLlWyxJlxg2lcvD9ewAJuXi1X2zoLDe9F
# DATA wQE3T4yDBDoLYXsWgkYDnskweDWcgBdmFJyDTbCRSXBqi+BiDQKpouXsMGbApWlV54EEtFKtlr9WRFHDxdh98ejI20+DcBYo6F+W
# DATA rz5AxrC4xsaoweKixJFs+sTS/AG7nrDWxrKI2STqYeQ3pthGcEAzrrMyNyU4k310lIF94Mu4Au4m/V1UTu5nqQ7teVCxxfHZQCwH
# DATA +OiYgKfioNhqSP4kpUsZr6Wq0lbmmywScmT5RpN9e94HEQByckE27T2YwQxJk9n+wJuNqZimcoadX5w5jKDDCDqM4DliBDcehjaa
# DATA JJ3WoL7QOcJZpgjbnCE4qqCjCjqqoKMKOqqgowo6qqCjCjqqoKMKOqqgowo6qqCjCjqqoKMKOqqgowo6qqCjCjqqoKMKOqqgowo6
# DATA qqCjCjqqoKMKXhqqYNSKwr5/Rqqg365G9eAKUQXLK9AbMQWL8LxO3YLntSoGntcq5mvYi+phfwl9r1m16Xv1nL7X7KzM27xgRn6l
# DATA 7VX9luf7da/d8jqNXb9R9fy6T+VFV6str90uYflazU67216G5StEmfdhLsaXXmghD/2WiW+jCJisRM1ea8nz1Wo1f75WyZGJ7c2e
# DATA r8krVX41qnl+bfZ8vWHFv2bl94bvb7Qt5GO91jrt+/2mXd5+Hv/ahvG364uULT9e3+zxZstOvg173DD75RGV/GbntO8v5l5lg9ef
# DATA BhIpjURDIqUvsyCRvVYQtvwiJNI8YiCR1Uqt2+gUIJHVbr3VbOSQyF4lrIR9A4ms95rtdj2HRPb9sNnunzskcoz+fDd7dJSvc8gR
# DATA yoNoC+sOVcvVoW0uth/Ma7VFWDB95GU0m8G0fskeFpXhdjB70C4q2vdWKPad2srZjFhZiKhe9FBcRClBfY/Kkk83zbW9pkU19Oxs
# DATA Ubd5eldLMW/0rBX75AuO1hLQcc0OBbUfQdKxm9EPo+h1iF6upjSafNgpJXeN6Vcu5J215cXOFFNkYg8uVBMxn6qb5BSH4CiQjgLp
# DATA KJCOAukokI4C6SiQjgLpKJCOAukokI4C+YpRIBchjqNg/zZMPerVccaMknxTvuqTLMgEhVx831YUQKu6QU9TXbiHDZHX/Os3Pn7t
# DATA P367x8TDu0t1BviZaxJ+MJHDBngjBXPdhFNFOP/rKwnnLbR4Pr40CsazfsA6/XKqS84jUnOeyNE3HKoKBLkQPaYb+fAnmQMZDW0F
# DATA QmLhjI47fe9O359w+n7JES53Ft+dxX+es/gr9TjP9Yy+KCImfBA5P+4tw8oPjD7ni5ePuQitThntIKNqotDnA7LK6rw2Gl1XlETd
# DATA QsfsAMkF/XQQplszF4yiZatRVJIcxWNZ96oo1UleBVJ6k9hvw7+u5imaQdmuKqeNtxWIibp9zcS+2lgW+aoV9XYh4pW9xuqom/He
# DATA jrq+qOrRtTDaTyOaqp+QAisskwL7mklBc2n21+zc96trMn+lQqduJajR0kFcVXVOa8RlHiLdmUpr1kfcC2Yf5k3T5U2GXhXjyHr3
# DATA KG/k9g0ssi/y+VLcUTaVrkSeFDyjqRJ5GHxz90hQjoV+SesOsH6FDo36ETIClYGI+d5EzIYwxtyPH4OGMEtqHAZHMvBIcfLYn2lh
# DATA jf1ZQCPONIpYGlwJW3xCHRyZXzhar0RBlsRoAwHPl+/AemlUdJa1s6xPsKxLRpOzqp1VXbCqV7OVLpPyVbEVBCa/jPjVT8HfM2pH
# DATA WMXOtY5YTwYu8R2j3yTo4mgUZxOWoPEeGroKG++smxPBM3cYMZl1x9N7NjAqRRMs46f0COpP2aIuEhwXxK7MfTT034uV9NEgSeNf
# DATA JEbyRin4B14W9MHXiVIyiliCyZRKNklyhXSWKGLRKDWLiILsiEfeQTKKIMrDswmy+3aEkyFSPLiXRmsaWGOYENxZZZRbWEVQauDY
# DATA qrBiylCwbcJIx/09CPMUO0BsnVCqPeBB5h2isYlm44ANG6pXe96b8ThBHaJnNGZXGwLj6PGUDUleUkEGqX40yeC2Uj2sMoGkCoz4
# DATA ZRYodJkxsTRtP7bBCMNkX6fwPk40S7lJtSrM2WIsyEL9I87Figx3QSS8hkdKLZ97/OyR1LR83NCbIkX+NWP91z6k2jkRWpGUoaeM
# DATA C/P4LBhw28jeabYuUR+KnJe0iuhISWZhpJ6MuAuTNIoqmMjPdvPyYAdgbpwGUyMYlo9HlBdUYSmNMuFUekqUZdjlOsT+Eq7KOEKT
# DATA 2hX6KINvnGPzmAKYknEYh6DB7nlvJ9wkMfwZZTKIwCmDsY/OL7Vis0BAYsvqRN1XE5duoAp7Zinom/UUwyQ1V2SQOJILWmRfTc6K
# DATA z/OPxamXXpwqTKsqPAVS/VnelzGxQGpuDrVXMvvP9T7fkCeGwZFChxdNlYx6wu2+s8pDKON6wngk/c9234Btinc+0GMH0jSJxr14
# DATA uN238B7ud3QL0ktodg+63fc1BGDRj8yeIWp4bEuOqbUV33VzNjw3Bu3LN79yJFo3tdpcMthNpF76idRp0bOXS0LY7Ok9D4ZpObO3
# DATA TjBdonR8Mr90WCAoiAYwuyGLusJr8LqXS0f5KkqIbohb8Aoby7URnsutSr6YycbewuQ4n/buePtQaM7nNJiFeQEmwNhqZeahPZoC
# DATA 2/qxotqKSVM2Lc1Kc29CyZOg7W8R0C3UWrJeDqKThaRRJ0fBRIMcNiqDJSX6YRqxR72ghp1FWaZZha+Q6ZYTrrrBoygt4K3+Zf4E
# DATA 1Knjz+ffKQbVHxhz9dXxf2Vc1b97x38HzNT8d4twq38GrYqBVOBYfX78j9786+Nfz/80f3L8Kwr06Y43/ze65Y/0/Ut89+bPTGig
# DATA Zq0GXn0JrhX97ZhWV4FkS3UYz8PZQBWMJbADxj3LEEHWVswjQQjXBOTKVeeEOZm4NMbstOB+qa/APKFcStDHyf5aYeRRz5Gxp2st
# DATA wupNbKBFO4nQWTiAlW2ASidw0fSqcomcH7sKktBh6b1LkVVcxcyNb3OFOx9YFY16E7XpF7UUm4STMDjifYRUPx5FDlh1UrltnVP1
# DATA JpoBl8AkSnFWlBXrcRyvz4BtOX3pke0OLRO1CmJtwdPr/RDL30+jMI7gjQajgPrUKIW3K19OUf1iPCZzaCY57I1mmfRnYoYdCdW7
# DATA F0+iBYrVJjV1tT1Tanovil61SSIct8pZAWe2AjSm6gyD/yvhebqggX/r4/5Gw/6mo/5FDfpSGYupN4P8i2os50GfKibRG0TDCawT
# DATA MjyAYDaRyxOcDo6mgxFWZCXpr8tQC6F3nHCZ8gegpZEtsjpKHSZoRu+SgR8c0DiZ6exIRdqMtx5gTTadsZYixX8UGy7QevaU2h0B
# DATA D1OEJeqIz3TJQMyxXzGYi4vDMggYT8RjQSYmxC7af1gwL3gfoN5EoVBA/BIWUABqiv6PPRWw8/Qa+WyaQB6qx6QuB5hygCkHmDo/
# DATA wNRJ48hGc5nNTd0LtNrPYrRvx2Z3JClHknIkKUeSciQpR5JyJClHknIkKUeSciQpR5JyJClHknIkKUeSciQpR5JyJClHknIkKUeS
# DATA ciQpR5JyJClHknIkKUeSujQkqWat3qy2zkiS6vf7jbB3hUhSxZXnjThSdqZUm16t1f5kt77rt9ue36jvVitV+tf3fPp/vePR12IO
# DATA 9aJ2t9ZY5EF1Wl4V1Kea51fao12/Sv+vq68lEBRlcqXXXQaC8jsSMKU/poFbo49qFnqp1mhaRa84SAIlKoKronoQNaKFiNZbvldt
# DATA U7Ibnl+rjmrtXb/eUN8W4hl1u/2l8awt1q9Kw6s3GoNmxX/fr1e9etsfNLRenMXAatSr0bIgF2tss04xrfk/69RHFa/a2KX/++1R
# DATA lV5DxdLG591qm74s/lB6abvdrFV7a156GtSRtBCNOpLGZqGOupWWXw2LqKM+/2ejjuhr0K8UUEd9P+x3/Rx11OpSVgUGdRQGvUan
# DATA kaOO2vVGxW+cO+qId5jssulhs4RUZIuzTx8joSd/UzO3JwM200hmBusgPzxy5W/egD5UcMI1jRNOlt4WAUVW2IsOeR5hZdscPRQ9
# DATA 2hROpC2NajkA7xTj9ZrH1g/eKyFEVgnavkBPTOjV6SkVbgul2lJFW8yf1clxJCFHEnIkIUcSciQhRxJyJCFHEnIkIUcSciQhRxJ6
# DATA 5UlCfcUR4qNXlOCdw9v978ulwVEoq4eA/ZBxs5OZn7KALUq+emSuHkXUI6vLmj50D+EyQah/g3Jon/lAH1EM5eJhEUSkfn9AwfPP
# DATA 2dKf3x1DFAnGAr2P7ztaet/DZBoM5Xwf3/V+MB3ssd/gWv/G4Y3sxpG62eYM5SdZ3FFpd1S6eFTaOtfkDky7A9OrpfwuwUFqnEnt
# DATA 59U8OPIC/F6QN5+y8onUZ5SAkQhHvdnBz5DNGw6Tw/VnfUfxYz5+PEmTpK/PH0Nn3DRUGn+xFWWWRtlzaJvTiJgeISlTyhKkTx+3
# DATA vOtlswk61ShULTrODPmILBsFNkppwEPthJzeMJ5iESehyUPGStgCMumls1H3FrRh4jGfx87Moeo+nL0HfH73I7hwCwomKWu6i4J2
# DATA 1ksSfqI3m0BmW841r1PQfgs2RHok++g8HqLypPUhsg4VQATJpTqOojDT3ZmkN5umYi5TOQ6SYchnXRFzSizNgVkOHKXSx2/7FOXh
# DATA EQuFm2wzZSfKOiyTjlPpWhWd04CJ3DCZIul0qZscDr1gmCV8MHitRPg9qt7cdOTYNr01Sq3CY8HmLlubnF365jjTp+gPURfRPbO4
# DATA zxDne9GP73msqJ735D1sSIkgjx4P+WQuzsZne95brNbMddfTgBpUB4o8QkVqgxAbgTgscwxRqfoH05NE3TnnOM6HNJAYXUFsR8X5
# DATA dw9HafAyajrBiF9HAx2XjpKE782mUrjYVjNRp4FFJ96c98aVYawoXKgWv4BMPcNxMqNo/kjCE/8Kh0im4dDOktic5w7S0dl0zd8U
# DATA IWpkHTX+UwuboxFuW9n8PjIfhdeHc1p6p3MQNM/ZliJ4hKJgQ9TL9QjOQdPcKDOyUTNWbQ/dLMa8c5A4v8vdvrGVlJrExSmBvzwH
# DATA ufNA3IzCzSiKM4pylXLTCjet2Hj6sHL6cX7TigfIihyHI9HRU4pLrw14EYhScaTRZfZ8edf2T8Ji6gdMh2Uu5HSOylmApJXVWM/c
# DATA tUe3/Eh/8a5976TI2g+aCBcu5hTP9rI41xtWlDubElTZ38iEkuF0g1iq23PEq/peMKkWomZnZq1ISF0TNXF60s8Fr+QGkdQPmlia
# DATA C7ldu9c6KaLVdRFdCUKV+StGK6ulXV0aqjS1OCuKHRnN0nvUt1Dr8PbNXHzHa7a/55l6643IpM68Wl3dcwj/NM3yaSId7afoKPkp
# DATA jczC9Fu4WXwjd0f8VemwyczUQE5jVquNe6arwxujx7JmoqcMWAbDpB5hlaTMWJ7L6su0gG0mrDJ5WlYhMOnPpyUSO3X6INIqaBtQ
# DATA Tl8e29vRd5ztvd6b7wztl9LQPi1l5wULofIO4HyD7KIBakNoWHQw0B5soxcqSVhNoXmh8qlXQlaQ/94y06gk9LptotGCVO5SntEG
# DATA 4rXWPupcwhbfIghXJkF/xxB02MqaZQNlYJXqKXaKS8mq3eJvDGp37qUx1m2wS5G9iHQJjPr4MWwY9v7LeS6mHcZFc4cmkJgFRsuW
# DATA XZSqpgiZij6pOsjAW7iUyVM0YGhaanlUjdViomvH+wHWrBBzsu9KMRfZXbOoQrHj9QvTJkRjVC/LKAYpjpNhe7a1WsTyqbz0hLOI
# DATA ayKMZr9hbPlY2zhh+i/H9wFWgtQCnZ4+R0Vx1KC4sMdLJkOz6kdxVPBJrEBgEWx1ROlly/L1ldHutMhBZLj1wOGx2EH/NH8y/3b+
# DATA 7PiL+VNAf+Z/OP41Q31AD/qCGT6f02+gC/1mER608PD8u+NfAzf0xfxPx5/Pv5p/TT/+ihlE3+x49OnJ/JtdeuIpgvb4nmd0D71D
# DATA 0EIrYUIUOt7yFb2BbnRAoctvUf8U+mW8Tsy9iaKFHe3IgiAuSUerdqem0T74y1rOWRb+VX01g3vKos0FyjT1xmsZQm8NAlE1sCTD
# DATA HUfIsq5Vl3DRJKFl5XJ+NCHeEDBIJubGj9SF5Uyhfpx30/fiqfEEb5kmJFBjthfEV2QRfV51jtAmJbZ1mtBdT8DrAIHvTmfdyJS8
# DATA ePBj7KEdebITfM97P6EaMDYgRCrEA+i9Q9IDawSs4QGzLFCbXQJ8HsqmjxTuwxHzGMVZx8aXwBohEluGB62vkquNmCXt7EWhg9Yn
# DATA wUGD3Eh/mpFec4LOOMC/Gq6zixrcz2Vs32hoP93Ifv4Du1TLxRzIN7peXGs5D1BQnjKIaFEA2WKcp/C4YbOm3vyn4zszaedDTowT
# DATA 0QUIAkzMvzPfBEtgTFtRW0L5LaNgTKnLTLoltSZ4wQyNJtSFjacbYYNgX01xkB/5QCH1U+rt8kE/luV+vbCFYFhMjiFGhgCURpJV
# DATA Bol8JEDlHWukT4D5SfqCLsaLqCJ6D6ZIdswej7jvUat6JDSUQ+oosGcQbZA3GKTIO+0QdfQgRw9y9KBzpAdtNqZsCDU/2ea9YOP9
# DATA LLb785rujh3k2EGOHeTYQY4d5NhBjh3k2EGOHeTYQY4d5NhBjh3k2EGOHeTYQY4d5NhBjh3k2EGOHeTYQY4d5NhBjh3k2EGOHeTY
# DATA QZeGHRRV+pV+9YzsIL9d6zUqV4gdtLjuvBE/aN8kmXcRFlkzYSMK+5VVrJk7b/TiFPa/gH2qkhAF9mmxSAPLG/i+IgwVbm9W6ifc
# DATA bnF+KGyP7vHot12/Q/9W6E+n8SO6PvQ7FbrW9Kp+na41d1ud3Wq9Oqh33q8CWNRqD1r1kV9r7NYbg+aymNSrqyKuAEY39wsVqF71
# DATA ERl6w2jX9yoHguhZk41Rv9tpLkckVRaqJ8W5Ua0MmvXK+0h1vdM4qFdG9Up9t16hT2UEUSdodZvLgq6engYkdV7TgKT5WDQgSkav
# DATA VSvSgPxWrV3v2DSgaqXeboQFGlC13ag1g5wG1O2H9TA0NKBGrdVtRzkNqN/v9du986YBKaNkueNDp7Vka6mRCBvXdtdbIR7djGEn
# DATA v7cM/jETpWWTIu1Gw1x3p75XZ/5Plfk/i+tRzWKktHFjddNiu3BCKMeDdHcfU2PwLCphtL9jrb3bn71qZ/J45z/VKo1Ws8tuv+s7
# DATA q0PqnDIoHeVsEvVOSyXSNi+8hwsmlbUit3pxXC2Fi094N6MfRtHrYZA+Ws0eynN4x476apujZPZKHWLbyZGEHEnIkYQcSciRhBxJ
# DATA yJGEHEnIkYQcSciRhBxJ6JUlCSnSz0PrWFd+nrt4jquM4RFukJzypjzSdCHsCEAzAp2nN9pjmM9byYgF0BcOefPxNiwliVpVgIMq
# DATA yVgdX9OCtMWDYtJGZSKnT1q4M87ujHPhqI076uyOOp/xqPNK8cHzOQJ9L2atCz5Lyy7I8ulZfRT6ssltXIQetxpcUHWovirJcKTy
# DATA Wm90kkSzedZ0WPkVI9LcXqrN3bBFmn2/UpRpbqyRuubBD5IuqvfiC2+ILWtUlOWeXOBaP/RGwp2pLSHd5OWe+9T3KbwQ15M3biZK
# DATA JHDJE03OLhpbvJveNI0esVbkiY81+EW2GTCCQcPyycVnb0pqNhCqfkfXT1RZD1X26qpUvx8F2Qyi0ThY2wvSXKD6wVQk+agnSZKp
# DATA 3CDHmiHrE+xD7Bn+qEMas/a8n/LgNowOqNKgA0SnOlJhczNWcJokNcJDaULm5J53nxcAxDSSB1hvUQn70XByhIKmgoinBflqwLQK
# DATA x/blHKmXznDGG0euAxywh4ajGc+hH0gWG9VZLvyMZmezbBKJ/iErZgfjWR8DcYq5lAQILlIY9/u4MuuynnqMcZoCY+zOMltPiRBQ
# DATA EqYbC1y/LOd8nby1M18t89XZq6+EvXpabesXLNnD69r5Aux6beu7NBqx0cgGJNuxWS5FwRyFbI3G9UWL/VwJvYvzkLVerNdbl7Ze
# DATA qul0VnnrfNFfm2NiUSjbJwJZlOtcLmrN5s8RmTQC1OSlIHrdnvem6AbRLEnEaqJgDBPlI4gIidxLhsGNMaNCcOTqBjOKrK5YCz+T
# DATA DZeQzUNG3SN6gyaGnK7i/EQLsRhVJ+MOf7UUTwo544whZwyV+lTnzXPevGLfudKKesGChswDBrg4GQ5FZ78M7FbtJMhyCb89755w
# DATA utlKWibPV9Dym6RJLwpB4xYpuiT9ZBaJL+d5+Nx3YwN1NjTeKY2gmgk4iqeCmpaR1GMtF47BjBv5fjDbp1HzPg3Dmha4wwGIWSLL
# DATA PQrvgA4j6PfhFGNXSe7yNOP0u2OM91Ph184ULSIadaMQImhh1E1pRBYqMg+hLAKIHUprUdYy+ufyjIIDDqgqwA/KmoLKNMi0dQHl
# DATA OPhrUnGWKvFpsgHCYdQN0j3vPdhPiCZVUsrcQIHAwgAdDJAI3aEIrw1YGG+ZkCF/zCzVQnHJZqBef0IFH/eh8zaKsPYX99bCyAes
# DATA as2VZzyFB4e9yCbJHwHKkfT73j4NWTqJsk/SG84oU3sBFBu5HgOvHhwGR+KY0vFUZZhptw5nH48DFIyKOeVLJgrc8C+xCvctJWsI
# DATA KcyUTxaoimuqcwGsMUX9Yd6I16UIRCu9zirVPNLI2AKZcOaD50LVEJwyLYvMmIQSH4NMwvJP8ZB+3tF+KE5ADtvpBWl6xMqNdynP
# DATA AvbbqYCEMC/wOM3xOQhYki/PpA+imFMlfmKlfgmX3H6ShJa7Xd6aUEOj0bAvba1YhGeDfaMtH7HqI/UxPzg17Btx2zbsW+zyWBq4
# DATA 0i+MxwDHR+E5QL/fBPNeyYWqrSPnwPj+qKRCei5vYrj3e2ga0sfQuCbbcjIh5mz3bXwK6CNDScQK0SSIU+8RvMXBYurOkyj+ckx1
# DATA LLhMEqThPnzrNl7mvyuMzDOGuoAO88SbP53//vjz418v8mT+he77w/x3gnzhu5j8AirMs/kf6eNXzJJ5uuMZvszT+bfzr4CreYqf
# DATA dvVTTz36+pUOim6jF355/EsFl6F4HP+dx4yZ34FNAwqNg8pcAUzjWDO7FnxxkygBAlqN3FMRmH5Lz9fE77HP27YxyCloGGv3srxw
# DATA Tu4yAx9FTw+Fs3G4ljJzl2/J3+wYM4XZnOkZLpoys1gu58eY4QSau34IIXHK62G/fF8I7WcD9MJ+32kaHG0TLUNtICMbOxUBc5pp
# DATA wBrjmRgKwsFl1hfV1qkyphMKYzLj+cSemDpkvuIpiNzHjz2uF9593h4gbtt97I9ctqlc2IfQaNdK3yizcTRlTXPs/aAxPFtgyKyr
# DATA eavtlIU29KL4Meui7+gxbkh/riFd42TONJK/Gj7ZixvFz2EQ32gM33AIP+8RXOpiOdn5tskX2GLOAylTTmhOljGaE3nMKTejQCFm
# DATA 4H5juQF4usZUpJms1iIZhp8hwyrQEwdxyrgYFJbGylDKgwwXcWTcEIWxGioD6ykgMkewtti3KyHuyzYzTBPoY3coHrf9NOLzAJLt
# DATA equb8q3T6A8pBP5+Io/kFsZ/zpLUshmKmJEodbAYB4txsJhzhMWcMGZshoQ/0bK9UPP8TJzq5zLOHR/G8WEcH8bxYRwfxvFhHB/G
# DATA 8WEcH8bxYRwfxvFhHB/G8WEcH8bxYRwfxvFhHB/G8WEcH8bxYRwfxvFhHB/G8WEcH8bxYS4NH6bZqnfrlTPyYfr9fjXsXyE+THnN
# DATA eSM6jJ0ttYrnN1qDWqt2UO3Uf0TfiznSbbVa9XAxOxtVz29XKENbB9V680f0vfgc1c12V3FZuCylrKTgjoTDUi3oStQ7xTKu10sR
# DATA 6UadVjnAarV21gDDSqfaai4E2K5uN4a1ur/dGNal6mwvhnahUFluIQ+tQjllgCtK2SqUrcTQLpStxNAulK3E0C6UmgS+vZZyygBP
# DATA bilbiaFdKFuJoV0oW4lhoVAa9e22lFMGeHJL2UoMC4WyjRgWCmUbMWxUrbbcKZayXyuFqC6kKvfLg38zqpVQXM1OPagvhaUtg441
# DATA GjULOibhpwYJZhkpOtQFflq18XwBNNodK4BG5/QBFJLQaT5nEjYL4DQ8M7HRNM9MzD2LZxbUm/VaVOSZ9fk/m2dGXztRv8Azi9ph
# DATA 0A1znlmr22w2moZnFjZ7ftDOeWbtXj2onjvPTHk91IYGMxMSZzzZkuygsLwXepHazM/avFK5ZNG/GHKZY/bDiIzYONiRmJT2oiwJ
# DATA znZE8iJPMXS17ntyNMz0ZfkuOX07TY73o82WihqbLE5boZZXnW2fia4jRbdzVSbyC6uHfs1aJFb3+tWiF0ZXV95jOQjC5JAXYrDi
# DATA VvF0nbPytsMOC54Vm9nciv10ehKrcruymoFm5+kJHg0rt0p1kifLVQdCcyA0B0JzIDQHQnMgNAdCcyA0B0JzIDQHQnMgtFcbhPap
# DATA qt0xFdxthTLDZ0r0DidJXcTRPWSE3C6qm7epY6M6cw1VK75duRW/wU/cim/cuP4pLvJtt+L+tcN4TNYV2WFHk2nyAxjx9wHFGP2M
# DATA w7n+qW5Bk9sMWmMQyLV6tVPvNFvVTvMmR+n69/kfFYXubdiAP6XZe60qHa9//VaYfCrvKL/iWvf6rc9YNvNa968rf3PnNr3r+i2R
# DATA fMOF73HQN/xbn0VkrCstOCsuwn/jAK+peFynu5X66GRGo57q9j6T6KFy3FY//zyJx9e4t6IcBB8OjeGG+lEWaK9dC3a6VBzBje4O
# DATA WY+5Ja9SO4xvr7RmhzEKZhjbFfK2NA8qN3qTpI1mjngt2/gyI8ABcrT7CbYSjMNrw/j6Lcmj4u+8Kk0Td9UV3/Er14s3YAhW8XkL
# DATA 9+7J6WmqbJ9pZJ05+umUVZyyyqKyijkM7NRVnLrKKdVVVopin4Pqyn3IcWkFkGHCeh+s2WWEV16skNdF0OnYFKCr4gnykj4n5gQs
# DATA nXoo75HU94Ka7AKRzreAdE0bR+evgdGx+YKqjw+Yf6AoSjA6dU8Oo9MPLTDimhLUYzGRVrPkeEx6B971k+70RQ2YLNCTbmSF3YeH
# DATA 0ZA60RPurVbUvWMygUv3bo6u4+qNVs4lemWpdT/WjAYZjzKyHqLQSO0ZeR0ysowsjpjvZakdJsltJtvDIjZelsxSsHz7glOB/rZY
# DATA jdBwyPl04rUgI3GsZHwoiUeeOnRvxGLonQtqMYPaHVv/h9JUo4IZ6kJhi8zOTWujriqB4Ua0uZdBMSQfS5zR6YzORaMzty6c1ems
# DATA zuxEe/KFaf09YNQQR5Jd3ECOovobo9MAyUZxL00sCbwZW6hK/y6g1jXugW6xqH1nBsW8RanBUENKWEqul4xGUdqL9RjIlmsaYaUF
# DATA Gxc21v7jlE3uPBBvVfcIPrMIu0wwjBqAkrB/aTDFXool+lvqvNuiiarcs6iJ/EkZp8rm0D/mBpC5wgefgU6LOBwVP1luEMFBHfml
# DATA tqfx+YITpD4XLU/rDtNR2k8tGHZwmqItgDUl98Xr7EBtnL/NBtyqu3oJiBvUXA745rfyr6uf4UqEuz/EhzXWpQzM2sITF6ptkmCQ
# DATA WGPeFUoYez6kQaujnTnSgTolw+5gj7Ws7qi8tPOihAPi3TCmnYszmGtTOuPbq3/+/P9omlSUo61yVpliSqqSKkg6PRJjjOw7HpnA
# DATA 5NGWJA9CNO3bhd0V8nzRuxuGkMajp4UF1ENjo9rPE0XmJ4O9ggfZ/JPRkYkompgM25Tesue9GYxzKuA4lEmp/HQPRBi8pFahQdZQ
# DATA gvSxkzPla6n2nCF766uzt1AXJZdhL4sNTwmZBkOdz3eZJ0ODxGRHck1PrDnXAmwCmMajyIayTYYznj3T/HImFj0TkJRH37sbj5BX
# DATA fbLWsgFgVWx645JfxddJkrGJvue9A/giXhPGWW+WoYA4JFmU3EYum/Z22vxdnbeq5epcRY9PXe8UH3Sevo29PYFX+4/f1sBKCilP
# DATA sHgwBs/8EPggqlszyjsqC5niZ55PBdqB00LWX3oRzUH2vA+py6ap912p2FJ9QYBiThKfV/Tg3rjlvWnfgTOE4i7hmbTa5LXn/Yi+
# DATA RlyRqfy3VpHPnMXre4hCNn9EAy1NMiiIVOexMWf71PB3Rc8pZ4FBO5DqFyrTRPJQVnwy6QvkblRS+GkChR7HhFAe/ADapTgZmLFu
# DATA aWACCcYaSrUjL6PfsIQiceNM349F8hQ8soM4oRaiHg6k57kcnUfzVJ3Hf57FvPKpB29dCJLBVH9pjEPF5grINpA2jGQ6hGz3smE8
# DATA ofzkxsF9C0BnPL3psr6p9ghCQRWjuiixctfk7UdTKTrOQiwkZskowoX9WcQdB56OxzJRoX5pupXu4/wHv7d4XAITKTZV23SL4taY
# DATA HibSIUvWojfOBKEpQslRnNLodohQdD1mGdvYKPzSdB1NP1Utn2xBVnXGO6lrwmlF6q0P1OSOwsYTowQLuTx3QE/B2AnpXmCzljO3
# DATA aK7IsrFtrpgrkll3qIGpBV4tJCzjt5iKlvlKzW3ADU8KZe8k1tPL4HLJZ1vO5eJcLksICs7L8vJ7WVY6UC4VUaFwVGBxpBzarAVv
# DATA GE9xxJmVUBiJCYqlGk3YBZM/yOdJOGNfNILhMmuVn8RPsg5+yKokH3258wZ1pOX2po++F47XteUsn3UuXy4EQ+kOyziJhSPp0n57
# DATA CWqHvO1o3NNRUSqPud/NFrPn8lgC5rCe4y+cHrUSM6jeecA2uakigCAH4yOzavWj5BA45CNVd37g8YUZvFNkVf3Ae4vuj6gzhTEE
# DATA IyS3hH+ASVg84go3zg5l9jDFRjuPl45Zfz9WRFfNpgKMNiDbDHxcaJeR4dVNHkcLvKhibbkXMzCTHZCUHbPelBIpxf4qLDnZnMuE
# DATA edw25fKfGUv5r0BOHv/GA5Fy/vX8m/lXi4TL0p1/yoGXuH/HO/6Crj2lv5/Nv/GOf3X85fwJnsC9T3H7t4LApNufzb8+/gfAKz36
# DATA 8Dnd9ke51XEsr4DJ5mXs90/VAUTT1yPRPDnnnmDPk93yXjaTCatsyGdurTzIDRhjBg8m7BEYyzSqjwkrNzj4ybC0MODN82solm+K
# DATA DJigMhzCsmjCSaO/aIBlqUjOj14JO+DA6u5VxWMKuvxUfkJVQfPEfVUlUQXH8IhtFWjJuyUGQcb+GqB/lKNcWTAOarlpCW4db3kX
# DATA dum+2CqGHb3D3WYIB5sGBJk+Swztt+N+P+5hQz62LcuOm0gzwPWt44jCoJ9TcfcvEC03qoOrzZJi63pRXMuNEuEAl26sf46xXuMt
# DATA Tz/EvyIemgsa3rc9um80uJ96bL+woV2qZSEbcszlC2s35wG5LKQRU/KgmDBsK5UEINjRZCpD4SRF1wNO3SDoxrzwN810qdET+/tY
# DATA YHlE1SCTeTzVY7XMjem2jMxmBB7GVCGx/CWEvwyKf+mmiEtko2ECYtpA8R9SV48zbFgDUWhHHXve9rqAlVQ1abdgLMiCEMeSJVIQ
# DATA CvIQGYCVz2x3EqW7bNVRCcxG3MvesswE3Igo75LBttJscAxMx8B0DMxzYWBuPMBsNJM5hT18cab9WSz7LRn2Do7p4JgOjungmA6O
# DATA 6eCYDo7p4JgOjungmA6O6eCYDo7p4JgOjungmA6O6eCYDo7p4JgOjungmA6O6eCYDo7p4JgOjungmJcGjllt1iJmbp0RjtmJOlcI
# DATA jllYed6IjGmh3vxGTlmsFalirVKG1+R3yfEisqzeblZaSzIc2M1mdVCvj3brdc9vDwR1ZoHHyjSyHDxWW4C+Vay4lpBqC3GtNFfF
# DATA tdttthvBQlyrVYpru7mtuHasuLbaa+OqYHZL41rvtvnXYlxrfsWrUv3dTlxr7a3UgVav3Qz8hbjWK9usA/XWVupA2ArC5mJ9rXe2
# DATA WQcaza3UgVaz3W11F+LaaD9/HbCCo9DqzdagWasc+M0ftUt4XOpQe42zQeyoL9UQO+mWLYhdvUndRnsDiF3YbxQhdvWoHlZyiF2j
# DATA 1Wy0GgZi12v3om4vh9jVOo12q3ruEDvsodqV1Q09utYtfp1Fq2uzzZnffzouXdnpWsuXWpvidOWQ+ZzKZr7U5jpfqp4T5oEursoo
# DATA X7OeZmCioKZcncYCHQ4+NSw4yV81/t1w4eIx1SmvLWQ4qQz1Ip1O1ZpllL2zEeNkxUAt4i4tAuPaK/sLVsLmrBJYY5su1hjHl3N8
# DATA OceXc3w5x5dzfDnHl3N8OceXc3w5x5dzfDnHlzN8OVZvVCg59nlSor8vX/nwHn29qX8V0Bwbmx+/9o46/heak5A4rMckM2ay9aJ4
# DATA eI1DZ7Ka6Gdmex/Tf+O7U9wmwaofFIBNfWM4jA43pAm3xyd4lgR+sxwKB2M9mvGIYHBnTgfRHbRffdDeHbB/iQ/Yn1b98NIcvM8d
# DATA W+vVEFnkjU+zjmmEIssCAssD+r5OC/HFntO/YidWT1LfyR2V56GNWFIh2LIwYlnH4QRVxLsK0MNiCJSr1IYyDsxIC304gzeGdzB4
# DATA +zNAwboRs8ECS/Ubugc0Wcc47d2jqwlE7rX6ochEMaJBqStQvU20gLOcKOeqrsQbkP18phzn0LtSIfA06lz0eCLTCqUyXVY9XKuk
# DATA VGpy8F7b8AtW3X6Q0Eg3UKfVZfOrFt/+IIDcopHpT6PDIMWBeiUoehgM5Wh+oCqoN0RCmJPADvQ4SEWYQiJfPA89DVgk9SezKZJk
# DATA DkGXNcoX46hz2VAbxlISTLHhDgKbMDx8CaPASKkHGas0KGGtgPE0fFo9nq6J3rug3pwicuhFTMQsIQ1dkSCAmVHhB6kCGCTDTPEY
# DATA DU2Hg0kfeYfohTi+OG2/JpIfymuWZOIrdGLdDsXZyM5GLtvIpVrlZKmcLNVZrOOV1vi5yVX9MOY2wEZCoISetIIN5dgjS7vqgjUR
# DATA LwIOLM4dhuDAekwj5BxUKtfjgfVjpncyF3LCbb1yEiK4VhFDdgNKsHidgOw1Dia+xC4hvPyECOvnTYTNhTzCjeURljiqKPvlKFdW
# DATA x5ldY3bVRdW6xi++KZ6p6ydmc5HCrL/nca4ujXPjrFHWDjO64f3lPrcTYpwHYCJtXbLyemm0rVir6qMj3SjEeSUQ+c1ZPAytEQ29
# DATA xdXlIr8vw7CM7sGEj97wAraeSxlwMvdefEpEqUNJ8gf0UAQe112vHx2yS5sdx1PjUYUO1hIh+f2UherM+D+ODjTzykiA/VT167or
# DATA BHAtABYd+2fZIN/z/ooshZDnPdQzWt0smf0hdgaJ6ppmZIorWzpSbiyUInkzmx6Y0tE0Qzhw8XTVlO0lNsLt0dUZ4c4IX3BUL1hb
# DATA zg53dvg6s/ryyMaqwU43A/aBoS3YKvDA7dBYZVrhQT7UKYnSnVzFlIcaI3AKvU7srcKog8AnItmJ4VU5EdHm+gJEyWaxYGbkMMgq
# DATA zdUz05Pzl3LDhgR+F5VCzyJodA4dP3kTfvKYfah4Qrypq+8Ud7JMIfBpDTlZuxUt5x8otpefoJznxikxkg9XIyR1vgpE8m7Bcw+X
# DATA NlUZQGnTCMVUAqam0T7lmPHPsh9WkFj0Vx9zZ6U+SzUy4xvptvE0pgmzrEDwXHnPeytI0yOIsibjons8DZjZyFbrND1SXmIWZcUe
# DATA yFQiBp95MtZ+cjV5sBtpvvqjm0i+umT2QMoovyb5Jn+1iiJd4M2+3DADME7NTOS5WKF5VT5lMb+zuph1o1DFbJz++ZKM7LXgHkMX
# DATA 9HvoYmHkBMJkTcli16scmYWsFy0AUYrmpRcJPBsmh8MjkYROWdkYnSvGIrPUQ2XOG/jQQQ5Mr/hcRbg+aRdWiIVe5pTleH8NzDjv
# DATA r3SLFfSIkkhOI7BYacgZh0oMnEtSk8DydhrGAc0CR2yg9qPpEY2nM+RxrJxXgW7JCjdmJvO86EKja85Hy8wSDg2+jzEjZZ8be8Cw
# DATA QBgLcO252+a6hF5YuZ65D36wcR9MFXZKtwhdN/LGzN7OHh0t9L+abSPFCqtGhKbZyBhEozibsPa19x73mAF7CYZBug9ZaSgzjjPN
# DATA qT9MUulfpa1I59oPgEiGW2Ar7XJ5qi5/t/qjjbtVNXaRfQV5fSQ1UANVGGiCtWmSsu6N7jLRxqLYofC28Ok4iOOgKBXfOt4fw9Uj
# DATA E1FtYcKxwtLgMDrTScp69dTrSjFzPLbR9jZI2JXoWt8+VdeqZd1hmIRpcIgGwrsThnHfWqhWzjV9h7IeogDbQilzIHsv9o5tz2BG
# DATA w4WlTZ7ebLrnscvPrGWr7QG9NJggz/lIqN5PoT1kz1eua1N4phK9WID3c3loX36fYo7A7EU02se9rIjAfHL8+fyr+R/nT49/RZ+/
# DATA AM8S2Mo/0j9fgGN5/Lm+uAyL+Wz+Lf3vyfyb479n3OXx3zIU84+CxOSgv6Yrv2J+5jdMzvSOf3n8dwBoHv+S6ZgU9vzb43+kIH5J
# DATA //6G3kkh4KYv6Ic/0M90z+/pJU/n3x3/2mEyr4SjFNvS0F2pblHVPA46e118UTyEdWl6sMPf97HZHV7UHpB1CtRyELDnKjBTBONz
# DATA DTx44XqDPe+dx5MhzBfqTFFYiLUyaHJ14LX8zLeGNH5JS0T8HEHT9qHqPuOiCZoLhXJ+DE2ulOYubC3kNXXlAVwgblLVjhNz+wP+
# DATA 6kG0azaESNg2AZpxJlGB91B2NkY48xuAH3QUTR09c5OyOwdyJq+S8mp5PMJUF6GZCqC6p2nER9R6qMd8rN97PwqymVq+pRybAQrF
# DATA dAWUHPWVxvecMWfIm8bDSLmsU/aXk4EUzoaLOM3NquRqS6fc1l4UUXOzdDikprMLzsMu0KzNs5gDr8Ry6oWZAtu3BDYyBE5lB1yc
# DATA GSD1spQLNm7zsrWp8+BwlpLPiYabmtmFJjJl+KZWKM4z5wBOjKHicdoHaTi3eOnZKP/lAD79NmSG+HI0vjJ7FE178HtviuPMR3zL
# DATA YqDIZfnwPxI7IcS+PKhGQaGG4utJiHyypmAP8MI3xS0Jd5UfH+08y3gfmcd7uMQW0U5FGpWQXPFHKVonb5Rgt1VgltEcetOhNx16
# DATA 81zQmxuNNRtNgU5jNF/kFOAsM4BtTQAcetOhNx1606E3HXrToTcdetOhNx1606E3HXrToTcdetOhNx1606E3HXrToTcdetOhNx16
# DATA 06E3HXrToTcdetOhNx1606E3Lw16s9aoh83qWdGbzX6r375C6M3S4vNG8E0KPaZh0euJzFiH87J3JHTDTp6x1broUPEv1WaRX9gJ
# DATA +1F7MZfBBKzWBn618clu22v4XtX3/EqH/6k1dtt1j+zj3U5tt7Hb6uz61aZX7ey2qp7foi+1YmE02+1GJ5J3FONcrVfzONP78jg3
# DATA q3mUhSxqVYxGrRktoixbHc9vtAbt9nDXr1D0Wp90KLLN2m6Vfmi2d32/vdvabTR2/XqnVFv8qBf5JeZhtxn0g+oy5mF9WVLqEvue
# DATA inHLgjDWraQU63jY7vW6S4iMfturVduftJu7dUpJreNVKE1tz69WPtmlsqjVKYW+V0IrBlGr3lwat0a7lceNArayuWPVjEqRFunX
# DATA e/XmGUiN3PQ0qVFasUVqpLj0OpuQGgtXQGqsRu0otEiNQTNshTmpsRVWw8AiNfqNXrt27qRG7G3fXWfS0IBr+bjENjYPaUvGhhIi
# DATA lX2/NCOut7/n4Q+ZGh6bG3kQery1lhjlVzYnN/T6V634LZ1LcIgQFLZ9/hXczXMQbZresgzwgitUlfvpwIri/sqhkKU8aVCe0J+a
# DATA /CmsVtUbBhvZanxvKeFRjEVKs8z58uVSawFrOcJxJarxxMqg7cnltUAypWoX38bhlIqGZ7GlyZDjQDoOpONAOg6k40A6DqTjQDoO
# DATA pONAOg6k40A6DqTjQPYDNO7b/q7wFGXTMeCPZM1o5OMDfd79MFL+TMY9XlO4SFzAExIUquo9bPS75jOSsTcS9mMhEDVXtUKRKycH
# DATA IyKyEE9Wx+nlqL03iaNepE8j4owc/IddlEeRA5mfvHGnw93p8I1Ph5ePaLmD4u6g+Hrd7UtzgPxB/Fia0A6NT+MjLPnHcsjSBt+Y
# DATA I4+WaCqazFAOdeLZR4unnnEUlHtedXa6j1DkZGYWDKNTymcbVUtxPXITp5uTEVyj9jlvp5y9iXI27yjhqogPq+9Df4nbfkb/rtHM
# DATA pkFxKvjDD+XjVdDLNnlwSpHIN1eLRKrcFIHIN3GKs49j3RiUcj1IbJbxyHKnqoLz4DidDy4rTXmOIOA5jPtygjmZMgUi46EJLigE
# DATA 4/UjqkdDGEQ0YUnk4DGnRBNRnkc786xZ8taGWfKO1gSlMVlnyJvBELoCrNXL0aXGxBfMmWtZwmFZUa8P7zI9jZziBRKe14E5R0Mz
# DATA /qEmSNZfLCfzEdh4Gxmj28Ep8+Vnq/NFWpSqKbOQLZO8joyDlOak3pjmtB76GQaDQroVCxKQGcjhP7BouEpFYyGUQZAgY44IfZ6g
# DATA vz840sbNC6wjf7lhHfkwmbGGxc9n+3l+aLXpiVafTkZ9bBoBpoE6gQmmV2gQTDNSGKOQTA0azHqUccNBMsOJtz3vISYErK3ASgli
# DATA 1+0Pg18YoY7nVJ/Nu8JT5s+Ha7RndacqOUTza2+iL0kOfZgmB6gDlGaa3exHBh3Lm+So0gSzHlQ47o692RjJ1T0MBIIZiAos0xDK
# DATA +5CK5sXlF9hu7m/YbrhSK+UWC1nLigyjZAb18RmUKoZiPKR8Rhb+flCxwlD3LFBajqUrZbPMFuINpLpQf13Oj4uVsn1VFBpyM9tN
# DATA wt0kfONJuJtxv+Qz7pWT6Ust2cb7WMyOFqGy8q6WO29Qgy6XsN5/ieSabXVt2UppbQ6VC8GQv5Xlzxb2RUqF6SXYOSQvOxr3dEzU
# DATA SeM7P1nYVqkn+YvqctZj/IVTUxjfhwWyF+ATzHphxbGQqidN4LV/IX+Ij07zcHNJdeuukpzThsK2ntlSJdW3YDiYDVRrDLU///af
# DATA tBnBrxxURcpOLEhvGg2HPHVRoAlR9Poh7M/M2xcrK5gyLSKEChvNWAazUVcXV+Clg6PpYKSsWTZYeW6wH8vPYvmxGBmmzRA1szS/
# DATA PN7zCJEuJY28Q7mVRrngnFED1CvQghnK0RWHQbqgqVssUIYaGcORiVWvoKyWFYyz2pzVtrHVtlDf3NqJWzs5g8W20jg8T/FdBjT1
# DATA lY4+i7kjr3khvqDB++IF4dcZAjjn59lrLQtLJ2Irsm0ZFq4V1jRkqZ8u36P+l89+8xXvWm90EuheP2q6M3PBrDDIAZEyMt4vgu5t
# DATA ZHxlz1+9/qI2FNiRlUubxNY8bKKbXzHx7WwzumrjBf3+vtb/nSbTQpW49r2Tom0CMdHOr5yQzRUr3rW10Vbmq1kwk12pvMolVT7i
# DATA LR6mKWQWIgo17M4bciZYxVltT7adavkl6X9iQVVNaOxWRuxNCeI54U9iWzFKK+8CbFXqn2ZmfwkanzFu3xdnqlFqZuTw4SAeRnk/
# DATA EUOtdoq9OilL3pqVDmrNUS7ezPLAaoUTJq5sXJGtb2TqlqqA3mnlhQrVZ3oDrR2MLtXqeyhVsxHdj+3BeTisJ90LxtAOnlACYpxT
# DATA DNIJL/Sy5xgocrgrDweRGPB5x4WUQWia+zVe2CKjY89TMDuk0AhNZ7MJdT1KP7goLn2T8/1VsZ4tCBfP0XkOYXO4fssMrifHXwrv
# DATA CuSsZ/PfKzQX4FxgcX21SOD6F7rtKQBdgtaa/5sVDn1iwNa3dI+GbH13/Ov5vxtK1/wruvEpv+vr439gQhdOOnjz382fzP+NKk0w
# DATA dMCtK2H/s3Fvbd0AKjBNgHcdoZ/g+mbsGCa1ZpAnpy6J1fuoZxyL6vch64bL0oWW3d5R3NB9NPZB0EU/JbN1UcPmOgOx826EGcI6
# DATA 2NZHdJeJkENtFUz/vGe4aNpWqVTOj7UltG/Df+It2dZbrTt/nlFx6xuLFWybiK1AwFYarqAWCCUxDq91QnFtHa31YUBGJ36mWDcq
# DATA O5VKhUcNygDqova8D2kAMVYPEyx40jUIJlgL1jv/p0H3FiIpOOrMQChQXNFjGghwtqDM0Dqxuq02U4qN50XBs05MgONmueF928O7
# DATA ZmadflR/NZx5Fziib3tA32g833g4v5DRXGpjIem2j+4ytaHzYGQVEs6In0wx2+1k0qQ7yNSiWYhFsy4s8wA7iXcooTGQPtRoYkrC
# DATA MAZLahzq1/aDeAh/ZS8Aq4jZQsVkYbQNTEaPaIDTC8zxOJsgSXCRUgvZlJaVh8yaAZm8j+LPlCbeij6gOgf3Cl3kM+V82pz9G2Os
# DATA 8PEcdsaEqEkgDtgkZGSWmAWZOStOKXpwRMbbY3jK4jBQJ9kjMQyjDPsQ42yAdcwAXo2ecFeQrriPDYi9QTQKPN75zhSuCY9FDqXl
# DATA UFoOpXWOKK0Tx6CNpjobms8XNws4yyRgC3MAh85y6CyHznLoLIfOcugsh85y6CyHznLoLIfOcugsh85y6CyHznLoLIfOcugsh85y
# DATA 6CyHznLoLIfOcugsh85y6CyHznLorEuDzqrW65XGmdFZ9X6r37pC6KzCqvNG4CzOWI5LhzNO0EwVvyBH0fTbxQyvdTqrc7xS69QX
# DATA QU6dKiOpVFAWXKpVaXc63WVwqZoE0otTlqBSL2tabKkax5MPzLWLNKmwU2s1lz3faGz0fKfbaXaXPd+ub/J8O+q2Ar+cCaNqveZV
# DATA q81dqtiNDlfv6qjmN3b9qu/xtV25tuv7tV2/3tpttTy/7dtB84bREp6rHbbDzrIcZFxYqea3Ol695lOFx6u9yqBTKQVn8m4huM4Z
# DATA EFjchDQCS1qjhcCqNZvdVvUsCKxK1IkCC4FVpYBaOQKrGlbCeo7AqrabfrNz/ggsmgnt0u8bTdqrVRori36rwkgjI54O0eMDcob7
# DATA pG04ZXzqBOsAUu1aWRaINxt+WnKZWGPAwt1Byew3pnhbmeL5A3rULs8Dl835tJewzV5CWR2En3DJYluzmIjiQoDMET174qMMufwJ
# DATA MwwuWbErY7iWenx0RS16GFZBu4zzWEUHfmNr+sXfT8in4ouaSA77FQtbT1Y/b8bpE16zYgq3GutlKvhGOK51lXf1tL5UmZfVydnw
# DATA xMklR8Fxvhzny3G+HOfLcb4c58txvhzny3G+HOfLcb4c5+sV43yhLqgT8lF4y6Z+TbFkyhmB1N2Wup7M0l6ECsK16lbcZyNTNcw7
# DATA jQoMnukAsIJ30jRBHN9WlheaF5k81Een+9Inm9feLhnT1pyATdgdTC52hP6FbY1cDteFOWYCoe/UVXz8Gts1Yp579/Kj/2RHH2VL
# DATA +oLrtz5jG/3TPDbYatmPx5QdimrGMqJK9+HACv4tdD7UXOFS3cE5xlEgZ6i41PHWLvYo0/ySX2TFTwnqUleDk1AfJMY+9Q5xZlFZ
# DATA n/QbR5CqNec+Tu3s6h/plx+sszu4DKl88nTdzlN2/dNCZESMysRBizSqN+E0IOIhVv+tz4wx//FrJvA9xI3eai7coL4KFDa6Rq09
# DATA PwZ5U27UucFnj8rpVck1lW1te+F0Liu8zYKhyRxeTwGxvSx5dk1s6N40HdKU77/8F/mKzYD09fpf/IV8p0cpTz9+7R1GPLx2/dMV
# DATA lrcyuqkrzKYP2GK/JoXqJO6dmsKZ1BScisLLraJwWnX7F6quYBywkiIR67OU3KcBqtudD7QMN6eUD7LOIG0Zr07I2/rsfq48ILHE
# DATA Q+sefMDtlrd5YVFo5VOF7BBjwWp7+VM3EVOtQ8hHY1cK3BsSk5JCoFa9Xtz+0olNXIHD1fz3lskJRVGMbXMTylojS6kJp1XJ+iiN
# DATA lekWj5nVSLYbjBmjkmV0QFi5LIMFfAghs9FMNByO2E+9YwT0pTKqysMVBaNkJor2lqYHNA4CtuiT/pThSmnEbnQmcCngFhv6Hi8M
# DATA st74OHrMPl6lrHEix+jlOCdvQnDGnTPuNjLuSko5TjPLaWadwqpbaTqel5bWuyLYRBVbzeWVE4GreU72uWjFxosQuVeeBZ25Oulv
# DATA 6J0YWnFc3wbVdPGU4TI7ywoC65SRwyF7tBmAgLViHt3+Ai6mW+jT5NPr6oKyqOXbjvzDbnF121/7O9Wd2t/QoKhjtEJSXjnV6F3v
# DATA 8ieuskUEsbnF9K35QwsE4CojGw4Tj7eSrAEP18XwBvewdOcCKHilmLzxYeVV5+rqyGPKI/JSykZaJnE2MwJnE2k1O0rC7C+Dg+CB
# DATA dLFKzQyEFe0GRTNR+cB6b4fjohaaqGYFgLTYLjmlj0UDJkTPBJE0PFKOUNPcoXAlAlz09CFOd/HQyZpTlvtvzzPFhRGRbORZbzpT
# DATA FKZhPMJF3mgEwSqIxDHtAtpdmY5KqSLkUxHbTM6nFlJaRdcp5pZ6hd+4DtWcz9Sck2XnXw4LNR9mnInqTNSNTFTbFnEGqjNQ1xqe
# DATA L1rs9YNCIxljoJvGoxzK9ECWSVkAdceiAErqvHe0DCIEFnF8h7OLfkdTCRMeq6HLyWqhwT7FC1vOxkdGD3JDBVeOromNkKCoFkDQ
# DATA UQwCaqzU7iPWt0TnscRbp04cL7FUZY8CKhh/UnQgZcnoH3Pjylxh6Qkg5yMOR8VO9tyYbmk1q8hsfGDoj3wu2pXWHaZLtJ9aMBmx
# DATA cwCjIzpGuS9eZ2GiRWpf8uq7LB1bwTiar2tCjrJ4n9P+Nn9aY7sW2eCyk8A2WBTNfJXZWChj7K6WxnoGALvOjVMC2D/9bDWBXTJW
# DATA COyYxEWaka6c9keaxP4QW0Yp5eksk+1eXAPHrJ2qhHQxBwKZU69Ax9iEEWADhdedkaGrFFPj3p73dswCqzMW2vVGccazR9nrgu1K
# DATA TBHlTSByjVsrrwwLiQEIInpdqvhsz422L9WgU2bwn//+29U5XKiNktEs6ZpGIvwLv2rci6cGec+/5PQl1r4lo1q0VJOJPnU/pdqW
# DATA so4vDq9OY7HP7/b5UDjNDUbdeH8G7qNy/e7o7k5QUUJ/DMjYZwnfOOTfZMK+jRw9Y10dZZvV1Q+CkVQFSFnnWSe1BVMcKNjKPl9R
# DATA tYVO9TCaAoklu5vM0x5jPNB7MejjCGhZoXWNoQyIBkHWH0WHek8qCrVBwTSQF1/9/vOpKp+wzjj2lIpPZtEs0vn3HmZwmLTRBDpX
# DATA Yj4MYnbm8AV13DwCAPptaZC8JiEVJ8srKgeMrO/jaAHnJ2XgGC4kDmgqTwHTG4GiSEMlCm0rVc907afMyHfX1D01SEgellcovWka
# DATA HNC4eUhp0Jl5Xx0lGCiB7ECqZUo2TBRmyiigXm48ZXAcwoJdIvMTashj0zOoXnVEvUbGc8kYEo/WsmoOl5vGSs49ovmvVuGG7fdC
# DATA 8/Xhpvn6kAl81nIVzjfmrVsth6XRPvaDywERSkimhgyMNrl6vZE8z9hXkVuGUb/POWz3A0E3Y/FqmqGxe0fuUdUZvalYfTE625/L
# DATA btZShhaNBNmzaBsJ5opkD9m1enehntixs0Xt+qOOqDdIoJ8VwF9KJakL4pVYeLMxelQSkU3Q++f5s+O/nT+Z//v8u+PfgHt3/AWQ
# DATA ePT3s/nvjn8taLyv518dfz5/in/n382fHv9mkahnh8OsvC+Yxodnnx3/Ck/Nv6GLzNsT9B79+0ePbnly/Pf03J+OvwRODzHoptHh
# DATA rkHvfXP8S/r3N/iZiXt/dGi9q+CtkZpm8+ZlyvkoRisdy7ZgEBt+anwzonwPc4wshhBKP2wpyPoGfn+kt5OkUS+eKJsrm6E/4tY+
# DATA Slisfy1J7y2Jl9WAHEzP9tIgdy6ao7dYJueH0pOqk68k3peqJJIn5ZvRE1lrjtHhudCyeUf1RB26oKyQCSPeNorGM8fT26DMto7U
# DATA E7Oe+3LueuBlFr9ZlwwI3buJPc/d2MO8W6LqmhwqqI8mnLPOmqB/+dABCi0ejXBGBzAhKmwDIz5V/VuDAS43qheF2Ds5EY6x58b5
# DATA 5xznNVLvTMP7K7IAcyFD+zmM7BsN7KcZ1y9mWJcqWc4BC633IpvOeZD0yknViyLiUg1YbrI0Imb2kIj4L4yJOwLFksVZWWMVJYuD
# DATA aJpM+Jko4wPtCZlL00ESZptg8u4jD2UZqxwjyl54CHjjLiV/FGODSUJWGfZsyUCfVxd6Z5DNUoDBAhYYpUxmf/6OdtunEdoPp+iI
# DATA S0Z0cIQECMcKk+p0ZciCoeC+enBWa56Zo+E5Gp6j4Z0jDW+T0WOjucqmxu6F2u1nMdu3YbU7Kp6j4jkqnqPiOSqeo+I5Kp6j4jkq
# DATA nqPiOSqeo+I5Kp6j4jkqnqPiOSqeo+I5Kp6j4jkqnqPiOSqeo+I5Kp6j4jkqnqPiXRoqXqNZ7dZaZ6Xi9fudKLxCVLzyyvNGYLwC
# DATA 9a3WsahxtUrNUN/8VqvIjev32h2VNxTBmEZWE0QtD6Jer+RlUxXanhyeqnYK4bXq1V6tt1BQ1YbvVavVQbVVOfDr9U92m17H3/Vr
# DATA Da9TpX8qu2182e1Ul5TcIpqvUaXQGpVBvflJq+W1/N061QO/fgJ1zgS2gImrtpZmQNsi91HkrcpZa+QZUCu89z/Ve9VmrbIQ5Vqz
# DATA 4vkN/5NdSmudastuyx816hT3T3arHX3lzAnwq2cA3XGr0KA7aWAW6K5Vr9Xq9Q1Ad2G/WQTdBWGnV89Bd61mo9NsGNBd2OpVuhbo
# DATA ruXX/HrrAkB3aFK76+0Nj4cX69YyH+6HEfUCcbAjAZcW8xZQcTVeMMuXy4pBK7tlwUmlc2jBEVny99thLfPAn2pQ9dj3VmHDST2j
# DATA lsCWJt24VRcjaczyIkJOhS3ouuVbBcpEu0XM2tKcMQOfXv2qrKPBbVALzssUcWg3h3ZzaDeHdnNoN4d2c2g3h3ZzaDeHdnNoN4d2
# DATA e8XQbjbMTZLNB7ZuC0gtxCm3165/X77xkiNjuRTyLJkGQ7kfLerG+8F0sMczyWt88foNygEcR6X3KCfaBBozswnffq3wjpvyjX7M
# DATA uBeZJvewHe+ab4fykRwmswIpv7MUDD+7cORME8RkCmiOdLhD1O4Q9bJD1KVjPu44tTtOfdrj1GuEb8/rmLW0AraDodcuq6zmmPUL
# DATA FPK4COpCqI5nq5qBr961/etK0lY3uzE7MHIBePVU3jep7zmzoMhiGMUsQNdQ2Ab2/cuiE7ZY8FrUnr9a+FbGU0gxm2ENxYBD1ZL/
# DATA J0RXP2/iay6YCPvNZRFuWxGubh5fHlRBaeN4cDTpygmRVA/lur3qe4EDsRBD34ph245gMXoreQ9vqRYVGdGgq4t7eIutPB7GGOCF
# DATA yYk+kPxuHyqb6EP4GH7GAx3aXkZmyWSHfZrUSofw+g+PPChpopLF4OWJUSTeeqFzSa3jc+PUDFWIIQVBAcLMGegAewmMHhWSPg7O
# DATA /AmuyVE2xbo7T6lYgmnEFrElAoDT4KzAyMuoIU6SebJ2c8sWA4DJht4vS0aR7ojeo9nLAWZIAwZgcPvuYXewShCinfc1JwMaXp6D
# DATA xQ4S6yzZ9Zass1tfcrv1tFDYFy4PxAvm1kLwotE3LEgCMvUnY9FtxT/o8jFSmCJrGaovXFXoiihwnAc2dUEBadvk1CVqUsvhqZsp
# DATA IZbqH7LapimwiPSbKdKqhnVWbc8VpHlPj54IzTKBU2l+KttiEeZZ4VFB0iXwsFFiNlL2GSoYfcgiZSghMKlJRQNFoZPv8Q3GKClL
# DATA cHOc77PYq0Q5oizWMX7XTNRingNSVEXPaBqnO6zMzrHRquwFC00r3tv4ADZIERRZATiCsSbaH2Jhbn2sHwC6omLN25SiUEf8HS1x
# DATA FdLsFrGhJHDu7fCUb8c7wmZZUXVCjzFN9iOoWO15llGdsLLoyGNQgaK+rIqufuFijF8hARu7T3KWprM0l1mahXHKeUydx/QkA/XF
# DATA C1NKDDKlrJgmyYhV6rhB5PKUw6E0laUiiXuqnu+Is2JHBiPozqEZYX2aqWDsWfFk9U61K15GPB0F7B5bCUrdUdqkWm7kMNHzTRi7
# DATA CRdwMMQGBhHIdlCwTaBgYnHZptWqO42fm+ku+svq+7VKJ+eq+rz6bi3jWTQ/Lj9GLM+/U3Jc/Nf95mqUiy4MQbn8ZBxRZzJh1+Iu
# DATA jixqyxDrG37D27dXMqr1Cl1QbsSPIkUgoykItsoNj3bIbsfe3y7Viz6+TjFeImTsIcmw5iGnOjLuIWBsHQbZQLRUtYVOl4bDbBsc
# DATA nAvJv4eHCedfSOPUpJh7tUox9+ptK/ce8EINks19rcokKJYC6DxlOUqRxpS7xC88jIAvwmZdTx3CFaHSLeRWoQ2ePsMaqzPMatCS
# DATA Zz+kPpVidy/lqexEJjB5vlVLta7Walj5NoUpxctkbDjF49kUQw5ES4fFiRWPGAzroZpHsytFwTOTsAPsaBxegrxrniLv3kIVSEVW
# DATA Il8fLGRfqdrVqpVS9u3wVJpN1H0piozmqaKUCmKftEbsRw/T4BBbefXSAOvN5ksDz5Nndh9+yix7f3V+5aOBQvgljwJtXetMusec
# DATA CuFGAN0n9MIDsjmMmU4W7iNqeEOFdgpZdXiUhEzy8wZYB/bui1AwM61wxSyfmFWZjAZ6ynXW5EWL3ka22YPZqWtadXXG5QOjZJxx
# DATA DBQNNJ2HD3BVeV3Gnt+mGhbqvAq8WpP3DFFFxbZAdiHQdEk5YsR2Y4w817XE25/Fiu/F3FjlvWGzkbecX1aE18vikMgxXv14ColZ
# DATA m+P1/8yfHn85/27+BIytp978D/Ov50/n/zp/wuitJ4vArv9OP/1u/gyMreP/ils8QXLN/zT/ln765viL41/vIBwKk8L6jn77d+/4
# DATA V/hpl+54Sr9/yW96Ov+O3vzk+HPGgwHZpQhgX9LXf6cA6SfH7LoKLpUc6ocuc2TzgKQPyWL4QKlJalxgOutNWf1eOhTKsGgq8MUD
# DATA TP/ikbggpd3ChdrH6XNwAKBQwk+Bw8gbUXm7Z09p5CfBcC3G6x2sjIfBkYmp43jZvhbVQVw0yGtJqZwfyUvVwnzJ6IGqlsOY4pke
# DATA le+X2qhvfrdQSbcJ84LLUMVEtPBlZ36k4+WAXpsV3daZXg+iHHSQsyBSQFJ1l2WoHFxyXobeBnuBREaYoQrmFDE8P0f4uuf9KA71
# DATA 7Jh6N5lei3NKpXSB7HVyZVxtzyy2sheF9jo5FQ7t5cyB7ZsDmvZ1NivglVhtuSgL4DwMgI3G/1MO/xcz+kvFXMgFC/p1yRrVeXDA
# DATA FpIPqCnWhjLmvK9P2Q7XQKhecRLK6Xx3qrZG8BYIFgmJg9S8SQfFKZcFJxSnch1sRAZ7yL5e+IOwASeD6y1Kg+GOsuRoQIvDGYov
# DATA CrkYYaylVEN4DTnMMU8cYW0KmB0jMA8oUHF5wDlFbRyumXi8S1nMIHaPrItpPI60o4qXzxA6lqFhtuyIzUIvFjvEgKAcJcxRwhwl
# DATA 7PwoYRsOORvNgTY1nS92GnCWWcA2JgGOFOZIYY4U5khhjhTmSGGOFOZIYY4U5khhjhTmSGGOFOZIYY4U5khhjhTmSGGOFOZIYY4U
# DATA 5khhjhTmSGGOFOZIYY4U5khhl4YUVu/WQv75TKSwVr/R714hUtjC0vNGqDA7X/yGV/Pbg0azU6JNNal3bEfLaFO1tuQQl5GUQZ0V
# DATA KYWU5fsFpZ5y2VV9u/Cahfw37yyE3uj45xh6p5kHXu8UApdU5YH7taYNASsE3um3u91+OfBmo7P10Augt7qw2ARS5jdz0FujXQgg
# DATA agRBu7bQLOhxz/fbB/XGsNr2/NYJBLLVdaJ1BgAZNzYNIJN2WwCQNYJOcwMAWeEKAGSNsNev5ACyZq8RtSsGQNbr96phZAHIGvVe
# DATA p3PuADLdQNfCp/b8hqaQFe43o6NeIGhsQhsrBqF5Y3k/rnNqwZFpPdrFosySZzZdFthrKgukajseqntL1oR9NogKby54FMQywHM8
# DATA fzHeJL9BdgJMqiUeyarxSEqmlJdZliz0NRZeUL2l51rUe/u5XVKKfpvtuWVctE6nU6ShYZV5NaWsUG47pbJYY+0Ubyz5Hoz70GHI
# DATA HIbMYcgchsxhyByGzGHIHIbMYcgchsxhyByG7BXDkKEuUCjhMNqJeJkovF3ZYac7f5qQ2R1lt//6b3bgUD2IbrMFu4OO9kP8dBtV
# DATA 8pap0Hy6DNZReu36p3H/mjx0/VMdNLVQmCDBuBftjclCvb6rXnXLDv4WqzrrgxvXJHrXb6Er+Pi1h/kxtlBwYp9ZcxzsI9Tvl1LE
# DATA sY8170X66SlKKit50MQ4vaZ6K+gTS/opAePwxu2J2r2ffR+G3S1KHwJ/g367/ik/fXtyi89kUJzox/+Nr1E8lqamkGCT9bdMht+S
# DATA WocJPTf6vIZRnt9T+s6U9woJp0/+GOVn7yEOSRXPX6YUfSZ4UH7EiWSf2PK3Plv9Oia99aJ4eO0aJXUXab5+k01bQN5UllBMKMmm
# DATA XlBD4tTvsRv3+qd5hbEuS9zt+yjjbC5eXoNULJGrkkNqLLj+aZ5hKDoUZ0zZGL+hyHks6YZ0xjdu6Jv3JjMyTT5VMX9d7sQpO7pv
# DATA hyNCE+uPcOruz5//n+pMI7B58Q3/OnUxFImF4Hf962vCxvFIO+z7OC7Jyx+LoX+W14XPVB3hyaRuk4tVWT1wq1D7b0k9u40ZrK56
# DATA 1g071Ual2KLS2VikhIXQx9WBWxld+ME6Azdv8+qpFGdIT3qKy9fuLqyan+dAqZ9Z1yTuQ2U1bw8qUYiKTpKZAy6JFp9BiYc0HzJ9
# DATA qq6B5jEZK64XIk3BHsZjmi4uCxQrafRQVMokx4xxOhNn1Jlw+hIvv77EaUkyl0F3gldWCv769TiZ93EIHkQOiK/qg9PBPl41TUZJ
# DATA SjOztUyZyyhacXWOcJ8HaWZRY2PbqJllIiZnZM14hSUiqdK8wnbHr2hpYMFsGjkxepm6BQKeUk9ykQ9b6P0RWWU74noSLXtE3lje
# DATA spqXTDCLBFxPWA+DWTplqa9YvXdCI/9Y9BMSJfVhROzXCH2cpDz6Eh3RLzQcZ0I5E2pDE6rUvzrRLifaZQ2/K42vyyDm9eYsBlOr
# DATA KFtlpLx+KLpQdlPCyDOJEjS0w0FSGKEEIaAHsD3vLkRsUHSsqRPIXFjBx6JH1ByDYdyH4g1Et+F8EAmpcRSFGjN2Wn6KiagCPig5
# DATA bUir7yxR0nLwlE3gKaNEio717tXndUCUlN1oIoEvn1ffjd0+ws1+iz+tvlObO4ovxJ+vAjrFzr1TquS3YTiu1snPy6LAsmCvnhbH
# DATA 51lRPrJh/EqT2f4gbww/Z9g7S3hoXNJsTMYja1HlG6bRng+SmLWtemweevoEPazGGYvNTVi+F8YmxWE/mm6DMvAc+dc4Xf69HWWP
# DATA PHa2W2gBaOMquJNJL0vGiSs8Y56hbTocBsNHlFdaPpDDw22zITDdjGr0ojGXAYu34RSEF85SLa5Lg9R2mBZ5MzwtnKG6Pt/yVi35
# DATA 9iaN8bLvj5k6s9jUPmVbUZ2LopVChlg9GoNlIXnJ0nSymJApeleUTfe8HzMQI+oNxvEns8goKFIlpQkdWAnTAaYdg4BrIvJ1qiru
# DATA FnIz76ZOm5cn1EHd60lOfkR1h1UQtVSzwZCaTKI0chViC1WhRg0Snizc3iNIQZZMWZV7AcsuKuTfMFKTTM52pSFnRL37xWH4RbXg
# DATA 5ula8JvBkO0INVWIbBYNjAPOkGw2wQSMEhik3SM1N+iJzqLsdN7zeKUGucty5Kliu1Gu9aMIIoqYapFFEWWTqBczEVbUL9Mj1jM0
# DATA k/BxdLiNHLTHvtNWwMr6LMyHUgVbQeVKzUVNwaVp14i7NnT2itRjpmG9AFQeyqhDMrBhqmMHhTcgixD1C1nGKqAsfEiVGjqQB9gq
# DATA pvbYXFqoykvk2siDcH4N59fY0K9RrGnOreHcGmdcE1rpAjk3jXJVZQv0V5jiVM2Nd+OFszLWeTeYybiSY88bvXmZA7u/1clFfc1M
# DATA enlXgz1ymit61su5lJ+PxM4Q+pb0+2IaBKHYBQWHBO9qoZ/ZRjK9zjW1PeW68ovoFj7mDf14hURKPW16Rv3dzPNrcnwTw0BKxj0Z
# DATA L3zmDhdHwWO5oyLn5KIJH81b7TvhTTKcEqtMN46qetpEVX83Ua2eGFW/vXFUZdsPIsufToqbvj2Pnbli4ldfFj3fil51TezUqqDx
# DATA Z8m5AJ7+gbd3k/cpjsjElhvZ/EhHd94QaYU8C3EsxK6D+aVCnZvQ4D6V47g3JYi8IhvfjNU+zKUVDhwxiWgyGFqmdkHh/6/INu3p
# DATA CSpNzPsYJQ1IR6YMhwEN74DtTOhRMtAwA1NUoHwWq4GUik6oJltCSTV7fy2kJYbkZLjLMEvesUVvCcHDTIQmCi/KjhfGv/hFjCGF
# DATA 3SvjWQZB/uyIbN9klOVeVDtmg2g4OWHhuFSq+eKx7VfNl4El/2XPFj3+IT7kJX6mwGQrlzTKaGpVH7FhucReDavcYh3OUrKJyaSz
# DATA aYf/N8MLn4A2WGQQHv8j/l6kHf7z/CvmEX47fzb/vXf8t8e/nH83/+b47+nJZ/RJcQuZcQhioQTOIXsMRPwKGMXjz+mGr4//gR76
# DATA Brc9m/+BwtFP/n7+DLjEp4xBpCAd8/AqzDBM9conFlzhQTxBjtIzO8pfyR2ORmKwcJKhO0uEySL6kEpRaAQwrAzBg3pSbfRM4qhH
# DATA s/F1cMP7ehsDDQCMVnNoQ2syoQvsouGGC6VyfmhDVUf0beBsaOIO/7JwP7avWB3ug6Sv9rRsHW3IESiADeOMK7vDGm5WbFvHGr7z
# DATA eDJELxNoZ8goCWfDAOT1ZMqaPXveR+j7ue/K93nx4hc2xtOzZv8TxWE24p4yk21QcKEk00CvZQVjQccsAA1ProKrrZZyy3pROMOT
# DATA 0+Bwhm6kf46RXnMLzzLAvxqewgsb3Lc/tm80tJ9yZL+YgV2qZSkPLGbhi2o55wEnLKUSKwAgASnOX9yzEqvPOZYTFIhLU0HlQFvT
# DATA m6gzFA9vvpZtxVqiG1bSmL2i5XzbkEhovKx57LJp0uMVRx6PNSqO+XFcS0Kaa48zE/1oliZeMGL8Gw/5EZkNcS/G0njBJihYANFj
# DATA HCxG4GEEb5TaUa3WCsl6oOJ8PwoyRIhtu94UrhgxEtmrI5Q6WVtXRd2dHUn9crRCRyt0tMLzohVuONRsNLXZ1DK+SBv/LCb+Nix8
# DATA xyp0rELHKnSsQscqdKxCxyp0rELHKnSsQscqdKxCxyp0rELHKnSsQscqdKxCxyp0rELHKnSsQscqdKxCxyp0rELHKnSswkvDKmz4
# DATA 9Xqjd0ZWYRT2/ah1hViFpYXnU5MKG75X8ysHu53OJ35rt9byWg36e1BrVD+pd7yq16x6tdZBp1PIpZ7frfX6ZYwdhdVcirGrL5AN
# DATA 5aSfAPw6RYBfo+aXCH71dl7WcmwtJ/hF7SjoLYITLT5gu1EIvlrrFIPv1FaGbpJZCL1eaawJvXGm0O0Saftevd46qHdG1LXu1jsH
# DATA 9c7GOe0vwghbvtfwW4Nmo1EKpdfodbu9pSjK02MHpd1o7KA0QQs72Awb7VZ4InYw6Hf7zQJ2MKS/w6qFHQybjVbDYAe7vV69W7ew
# DATA g9VGvV07d+yg2aYG4f/9jebra7h9Yt96C3aRNsdLbzMDpZp6/TCi7iYOdiR+SwGGDbUSV12g9WFhceEFJbe7bTTqAinOu8nc83zY
# DATA AV5T/thhsnW6cQ41tOmETBEjtxjUnaBsqFjYwGJk7c0FekRXy16VZd5eWUwpJq0K3yf/pf7YM+71xMFStu6U82SN2bI2yWxPOOCg
# DATA Aw464KADDjrgoAMOOuCgAw464KADDjrgoAMOvmLAQZvvJskWL4aQ0vioOKJ//fvtyo1qZYdmluqnQy7C6zJl05ivd+SQDB90QyO7
# DATA wb+CS9cbIeDI+4/fep0KvoVRNNn7mP4bg7ZG4d65XfnBx699xFrqfI6OF2oQCP0oQezxlIciLGGZwzeIi9c9wr1Mxwu6GUK8bp7C
# DATA J37Xu/ZRNkmdF2VT+JGj170/f/n/ITILab9Wq1ZuyFUW90TXgCA1yswhxNzZ7pPOdrsz3S/7me7TksIuw1nvkottPSbsPTQN88Se
# DATA 9z6qva3tshQO9kJPh1+do5HnQQErH2bfNgNsURLgrASwor9Wn9V/j6ldUhHkNf3I6Nq8Dddj4IUJ/ZAd8hntD+GERNViKaBBEKd7
# DATA 3oN4yu4nLfguFVCEy2cTOZ6sCrdwfD/IpYwmEG1M+nwWORfNKSncLJTzowimcmDkdmATXbzSzQs6BWu1IGcMOWOobAwt9KhO9MaJ
# DATA 3pxkRl0OMZwPpb4y0SJMDP7i50nXKOLcN9oN1Azj/bEifykNNYWPTGlY6EHcoo+bRUkiC4BfhXtU43F4Qz7Ld4gODdyQQ1u7ZYlm
# DATA ysbgr4dQnYF/LFeysXkw7LsQ1Q6H+9oM90VJgT6JSvqUW81q2Be7HUUWmj+uvpe353LP8pA/XQV4l5UXp+SuPFjDT9K5KsSVt9Aq
# DATA qHTFthLgysPDRMSakhkEYwLIsQhkZYSWoiUSUcMD9kKJLJOYhzSuHcCL/AvIs6SjonqRqBSR7Zfk410AQRiqHYFo1PfZUNZnTqXR
# DATA qNnBcmHnRQFos/AmNkmeQJNjWsoBYwMWlDlj6AFLEPr5+FdnLrn7G5fcfTlgLla6Lrr3YIugIwyYDUDFsa/UvzMmfUUTVsdRLKEi
# DATA OgzFx5I+ovZNRSCT1LuazwiPodoXxb3pMJoqsECq4pJNkunzF1khZRdXZnlvcsoy+8k6Wpnql6TMfgIBIuRjN6EI2YAolibS6yha
# DATA 0GxfGFmUu9SJ42LSJ2vE8LT60aFoTunBbSqS8LhTFne4pA+Z/sbMFdPouPS7s+zo+UurmKYrUFwfbFxcHwQAt/NiBvX1OY8qG4iW
# DATA vmkM1Ovtwx/+KDoSa78bQEHLGyQjaViYHIw5NNaoG3tUUCloYUDlgFfFDvh+/FjwcQxNyAuzLPz2/IVWTNmFFVo+Cp+yzB6uLjM9
# DATA nqteUZQDcS0vL/FHYB8+hgFqQpmwAofiiGF55J4aJ9gb593l8u0zvos6IYiQYdwTyxPHprzJjA/PsXjCGGiXLfR7edwvf4lUNy2R
# DATA DyKlXIfhY6p+UoRLOR8U6QFGmpNYGyLUl3h8vAst4EgECQUMqFoN9288s0YAMLt5KIszbaSgdEX/bgttZjEhZyqmiyXMPRfG5FXw
# DATA s1lBOEebc7SVHW12lXI+NudjO+Ni40qf3DkJTsuUXGZ6GAFRuWFjGhfbC4QanBN5ruDJ0ntPYO/zJmssP7V53wzPhNXvJ4DO8lBM
# DATA d2VdyqlxJ6HOmhty2A61t8yAu3heoHbtXeuNTgTcSQA54E59twB3S7FxvlzW4LjKxpA72c0DdyE+CGNMKMhQKea8KjkQ1QO591CH
# DATA sOCza1UY+4Vt7d4hFjJ5f1GrstrL5/v8yMPoMXqi0HqKflnzWJ0f+xHdfWQ/U6+scROuRNRp0xS7aclSm15dSJ3tujscUCjez8ny
# DATA HEdHe7bks9J1lk4ADqHDxPO5pQWpgsXpDWsTmiYp0x2rztRZUJwwveKBm4I27nhxaHDfIh575e7X6tr8YrXtzGPAJRVYrVrheme1
# DATA cOqjZhp+qfbk9oo1FXrTSoadQtEq7Dtk4T+Wrm9McRzKVJFVsyezFKB3WdhOMtZPtQSyN4DIvSTGc46Qo14k6qVBf2oh5N7X13aP
# DATA /27+7PiL4y8BkZv/fhEd9y9L8W/05Qk99cvjz4+/wGWP/nlCF7/mv78COI6ufDP/6vhXBgn3dP5EKaRD4WsC7VQash0m7tKb+myZ
# DATA B56pM95fBgeB904Yy1ksEb1X+0p49ttP42gcUgfC3w6TdBga6x+e79lEfKdwJYjrbHjEdN0ELm2hiLLTIF+gUD0PnooeU0ML1yLk
# DATA 3oSABmtNePy38CQcR+7/Z+9dt+M4rnRB/9ZTpO3xAJCqinWvAilQB6KoS5uieEjKOn1IHqxEVRaQYt1UF4KwzFmS1e52j72s6Z7+
# DATA 1WvO6el1Zq35S8tii7r6FQqvME8y+9s7IjLyUoUCCICkGLJJVmVlRsZ132LH90UegREKZ80jlz00p0cmt0vVYeaCiJya56u+fhiZ
# DATA 3CVfIMFPg1COk6/IdqR/SSdI6AraHAvGEcotN3QnTignfeazmdOHcBO/yrhT2rBRzlRPBBRZLnqi8AYfqTfIXba2d6Y+LYpJQLLt
# DATA jXB8Nwfrh56+dO19bzwMFFMGjr9T2xQqzJRtIIQWJ0uwzWXP0fkmTuYafFZo57Ib46jnnPVwStaDpqU7ttHwQoQQz85gOCV7YSlz
# DATA 4YjWwtkZCzJJszrDGArP5kI7DRY7qxtANIdN4nYwBA8VmTJGUZseYm9+Tre0Br3eFOIaG3jvwINoccCCIUXG1C+twNb4o4ADFBL9
# DATA Q4eNVbI9aXoaMr7eCUd8inY8XprhDkRaYxWb1WRi1CH3yCIcSZxD/dohXznkAw6cEfTu4EPSaB43r0UdOOhMCt51XW85oKDIwpJB
# DATA 4JTdImcFNAWZwbRgJjP0B3BxAB28S50ctiR6zG3vS7iGczmDPvPo4IQ8VheIyNSUoF51nHeO885x3p0i592S2utYB7sWmeVn7mmc
# DATA RET1uH6GI8BzBHiOAM8R4DkCPEeA5wjwHAGeI8BzBHiOAM8R4DkCPEeA5wjwHAGeI8BzBHiOAM8R4DkCPEeA5wjwHAGeI8BzBHiO
# DATA AM8R4D0zBHjlUqVdKR+fAK/yXBHgZe1AL8WCZ/HFlSM6OjmNFvV7I4FQWmvGuqtaW2/UggSzWrlMA1BdwKxmvXr92K9ulrfL9crx
# DATA X12uH/vVlWZju9o+/qsrlWO/ul5er1Qbx391tfjUxrraeGpjXas+tbGul57aWMfW9XrzLDs8tq6P9uon7fDYuj7aq5+0w2Pr+miv
# DATA fuLFVXxqYx1b12c71rF1fbZjHVvXZzvW9rou1+pn2eH2uj7iq5+0w+11fcRXP2mH2+v6iK9+4sVVfGpjba/rMx5re12f8Vjb6/qM
# DATA x9pe15VS9UxNhfVjv/pJO9xe10d89ZN2uL2uj/jqJ15cxac21va6PuOxttf1GY+1va7PZKzt0EO56FUa5d1avXivUXubvsaDDo3t
# DATA eq3aynysWm3wY5V6+rEqAh2No5hjygGxyOVL9ViRpWalUk7XpFaseeVabbdc7FVqXnG3XEz0xnYtqG03MinZm8diU69EbOoSz7HY
# DATA 1JtFP6jV42zqpfVKqVyLsakn+NXBpr4drLc6EZt6rVyvV7cNm7q/vt3xixGberVUa5WLp86mzsHg/DYn6ZtIp2y2a1r0KNralIC1
# DATA /UySEN1sxWVtu+lEjQYnaCI9kznR09mOdcRZ5TV8EGy5tIy6lZYxl9DdKnUx17oMlwpa1sy2i54RfCxh128P9s6v04/4U/TUKD4o
# DATA 0Kt6CIHN2YItp4pb3IdRgZ5KNdX5a7JtZX4dZmQfqL1ePcPMNoDKBY0i3bnEiYL49nZxPtm6PVILwuFZc42D3BxXd6TqjlTdkao7
# DATA UnVHqu5I1R2puiNVd6TqjlTdkao7UvUXjFQ9shgVdsPqmrHvqNXedcH+iIA/LghjFYtstpW7+0xXLqAi+d6gHWwIdQVdlDRbLOro
# DATA moBM5GGDbJRrtXqNr8LLE9i08YbmRmfXWFGcq9+wKDVBOiqGEMQEwGwbTSk87CmykeiXurxgMGmjZB5MfME057VRGJOqDlaLuXp1
# DATA DcYRDqqsnrt1W/13fuPnP8W/Iy7mzrmdHI2rxdPOY+ulyemBKrDx8T2/H3a7/vlybtidkts/Pl/JATLufO3BLa4Ku7GmLnc0Pf2N
# DATA 6c5OMBa9yABk3vXNd88b2vhWEHZX8YZXkt3zcqHUZDb5t8LXhbT+dYb/iXB4E6VIAQKAQ04+itD88cNQSOVLhbIuEsJZcYlAKwjg
# DATA BTD1BOiQX6jmDDDxJoDnm5C5rGeQIAkBskUR0nMnRBiydPW1ReYUd3DYmWPJfmwcDUCkJeBp6elokq9dgGZB4CqBkQOwD9UAILnY
# DATA kDdcY1EEP8vFATocTp3DqTsKTl0CzMUh1jnEugzMn/lcFs8Kkp03HGGdMoZWvE4Gym4zDum2MwU0LoCZ5mG3KWKLPvhmw1aoioZ/
# DATA x2isGqyK2WiTkHRxaq0UHJ25b7d88RpUE4kWXXGJhmu4qV+J3laIaRHzFWzgATPUgwYQVDfYxskziv6EAeqluDGwfD3R+drVvQCw
# DATA WGBNKbQ5UGx51pNM5wlkK6pzAGx8akoI41rzEPKRv0GHqxPcB4mawHpBUpmHSVPNQ+rjdr+h7CKG24uQbpVq1O2/YQwpTxtSQKwD
# DATA vY8gFZM/LKwnqodCxrEoeL+C5kw90tqdArdY448pc6XgsdMQU7RCDywEqBKpzcVYhSOLgoxLIPSJ5IaMZZqVEBVmomJ6lTlLMF7U
# DATA I5tKxEuPKKnOi8X0xmQwVNwGPFcGI0aTA/rZeDqEhkbKMfCcaa61grYl/yf+XSFXgFXI9gycr+G+GlStXPw9fz+yqEQBSe0Rq/Zu
# DATA BhzI1HVjYlffMsWYiNhWOTy3wsmiZvP78bYPB9Rp21CGPs858ht0w68gguJZtr1GBWQ2qDheoLChMmgXVQkbW0MeOYaS89skwkPD
# DATA bKMA5XQDBIZOkz9pByMClNNcN0zQ6UerzJhqzGqnTTnVDSRzuoN9jvomSdYEGezHD3AWaR1noDoD9SgGqjNHXxxzdK6Z+YwDK9sb
# DATA /GkKs27MTpUVQ39PdlkhwVZRFmr0COP1KCqsZxV++flCEz2M0MFK5RC6OU6RufgqCejkStXH0WJJXs1iIslLHTXzu/wta72kj4nJ
# DATA 6m8NEJaSN+73W7o6Cn3p4nupU2YcwSebZw6Qt/Usf+F2JUjAdCKNxsp+XdmMuxp5mvtHG2NssGWDNyurTMMDM1/HdGjZkoaDk5Q9
# DATA 7FHtLhiar7iBGTdHrQBfgr4iORden4aY+Wm8bZkUKcauQxk++urFOarIKCDTxd8mq1sRfCTWO06/ylLQDMC7lYs3ekL4Tb1p2JB5
# DATA uTGWr68Yke/FvRaGAQfr+zAYDLu0Qj/gfQ/0ReR/MJqZYlwUmOQYTnjccJz4mLia6M1Yi0lKaa6yGj1dXeX8GWMf3oMeT8WZJh4G
# DATA MiHE42RaEngpSlSp0V5QsWsjMiJbk8UVu8T7Dd4YFv++rp66KJ40W+Cej6nEfYSe3BsxavZgr08uG/0U9gCHridrZm0uibOXrs0L
# DATA CFLseJOdFX9cKz455Vyc2cWZn9iAn+sunF6c2fCJJ/k4DK3aM0nzdRb8y3rnl364fH8oeTu8C06mTDCYjnWs9RA+46gYI/esS4bA
# DATA t3kYAXNpaUJjY/R/wGIQFYsTGOsbIo5l4yYkeYXVLjt+U4H7+RzEah9e3Dz+OP9ejDqbbRy3X8BRnG4Z76Wb1uEbU0wow3z1rfD1
# DATA QymmrWLifaAvmnpWDxuW2hF4pnnXX5H+UVXlAnJCaL1SJyyutHncop3WVyK+6cOqW1m2tpzIEQmwHgkGkh2JOiI7x6Yan7TjPOPy
# DATA 3dRu0xuTxaS3aeyqLsFJfVlTJbOAGAW8Z6Ej088vQbXZKxAB3PWnffKHsCEwnsQ5qk372yCnYbOL9wgsliFI9hGYmUEhLVKm4G3i
# DATA 8r2Q7B17k4wtoeB+S+1meLIfoY46dBRrJhI8fCGw2R8jYY29DvbYxIjivQplKI38ULE3gUvaH4qkToxnFEBR0jFKIol1rBUeMZQ8
# DATA aV7kaNiljxJ0TBk8TLzDliRiYk6r9iAQ+ijl+XngidrDJKPOYMrQ1kTR+xgtdDhP9o/Na7IIs6fjsIUoTziwKLNn/9fBZ7OvDv4A
# DATA VuvZtwd/nH0/e3jwuQfubPrhy9njg8/T7Nn/Mvth9h3d9/vZ9wef092zr+jhv9K9nx78MefRpx/oyb/Mfjj4LVi0UbQwaX9Kfz+e
# DATA PWYe7U/okT/TLWDS/tqju8DX/Ucq9jEV+xBPz76gan3NT1IRX9Df34OW++ATx6797DuEJMQGvSAPZjmhyNK8UyyrWrRMQYTX5W1g
# DATA 3i2/pjSEr23anFCCcXCKzLhhN1B8YYrtiqTfSJPaMzdYZLQuZNG+jodIBgWOOjvm70Xi4azJs60ROT3GbDWrxpanxxd4Yo6Td28H
# DATA fiSuX6cvPBm3A9L1J0mVTeUyd3WoNZlKrUg5dS8oV/YSg3biTNmXdgfAqfdBYk46ta/tV+pgDjspRkmWJjRuqRxwifmSxUJC6l7Q
# DATA vYC67nKaFNl3YztK5Y9FGurklKPMv/kWTLSanhb39aGVd7TXTq0/oVrX9NZH0+YvRuT2DDX5SSrypfT4kdT4mWhxmYmm6VG271Nd
# DATA KqdBUG3aKOmh85rHwltFfHicc5JJSW3YYagMf7IrbeggEXJXtmxl95ncc1+YaUe7+5PdXjRgVi6kr3tDURZDFS/DSH114JnqCvGu
# DATA 5lzm2vQHnqyabHLegrfJPzJA91iYiRnRWbawlFRFQePJYEjW1q5iwZ342+gwOWAn1kPUKkOQTf3VCseCT6G7tIVghOOXdvzSjl/6
# DATA FPmll1IpS/krSxq+Z2O7H8d0PwHL3RFJOyJpRyTtiKQdkbQjknZE0o5I2hFJOyJpRyTtiKQdkbQjknZE0o5I2hFJOyJpRyTtiKQd
# DATA kbQjknZE0o5I2hFJOyJpRyTtiKSfGSLparni12rHJJLuVDrFTu05IpI2O85LsUfb/YEQa622Wy+W71Uqxbfp+6+T/RjU1jPorZpe
# DATA qVndrVXr95qgt2rGH2uV2o12KflYr1SteWV6tFLMlxpeuUIfvEozX616Ffo//dbIN71qxQN5VilfafK1Mm6veZV1r1LC3bhc9Na9
# DATA ajNfLtlv5UzIOLdVpV3z68UsbquMuVFDfRr3SuUkQdt2fbu03coqpZoi47NZ0ipxymAp1yLwqkfTtxJnMg/8WmM7VcNyuf7kNSyX
# DATA KlENa5UTruH6+gnUsFmPation2wNK43yk9ewwkvilEa5SovkiWtYrZRPb5RrpeaT17BWrJ3eKNfWSydQw0bzhEf5KER6ooQ0kZ7o
# DATA M4tIb71aK1XW40R6Sdo8vuInifQ67fWgFhHp1f1a0GgaIr1WY7tNProh0lsn67jSPHUiPU7/zC+y7guVBD/dA+uhNBddLCRUasa9
# DATA Ht0JbGMhZEt9j6TH1Xy5HeysxUpOMPS9FZBeD/2c1D0Z/K5w6Fu2vJmcL7l/r0pmZ23ZPbWCNt85nluxmo5iPJ14FLPcTWABRwx0
# DATA LByJYfkjbgFVswLQHIezylNRsDQ9n5pN8dHAYFhRiQa2V7LToVKvKKDWZLNaXj6ZqHox2CNMVnGttT6fdC8a4Zw9Jgu8iPRsU821
# DATA ppEKdi8eHHYFMOvnulHRQB3NH3UkgI4E0JEAOhJARwLoSAAdCaAjAXQkgI4E0JEAOhLAF4wEEHNBOYobbJ3mfBz6zAHCd5RjGLbi
# DATA BekPPh22IbMlbP+3DfyYx2y5wIUIeMSGUm/qK9XtVjFXzlVzdZKRYScpIdVta2v6cXP3BX6dmYir/VwI/re+Fnsb6glL6q1d6C/s
# DATA JRDIaY0V1U+9R7Tk/Y2L9/UbRJLRFWXn3lfijP4De53tYwxxdGx17eNYT17gQ8DaVuQOXUu0qr9xkRrExy9hjLLfjuXH5+DQhIKc
# DATA /FQ0f1Q0SyVFgrfG5lzcDb29os77QVBEs3KDtC5DyMopY5qPwoF3XQ4dowlDErBMc2caNmGLF5R7P1VvXxPLP3tsDmnJZLCz0421
# DATA JBfSOscskiZxobfw/Y4ZAkWoONjgWalt/3ELOI9o7lpuJ/bTW+RE0MQekMoKqGP6rX0ZNH4Nva34WqlZPF+pFC/sFHboXhiLv8IN
# DATA m2zUr+LUQk4VKGnouLym7w7uDwd9ALb53et+b3hzEH+2WEo/+0qhWEeFqCF9GqLVHRSmv8jdQNIL+7yziTs5ArUqnwbD1awSGzRM
# DATA MoDXpDMZMBHkjqv48EqJORsHHa/JQ8qN17/8onmB5+KG5chgpHOVInbghAASYZQBz7UHyidhZHxNwainw8fR3L+gpsYDvQbYBZ4g
# DATA 3YiHcPPSxl7YJ8eqwKfKeV7en/zmN+riXrB9N5zYP4m0uLQ22SU97V0ejXh2y5F0S0+jfdxFMg9+8xv4g5uXqEL+nh+S98fdBznd
# DATA g57MmMxHXEWDobWIRD7KQrnwgL19u09kjKTOcfMifXxdQI8EgQfQh3KKezvwAnLT9NokuWNc2QxRx+fjwi65dTGhhyEzj4nKW7Nq
# DATA SYWqUcgoEnv89IgpynqOu/Y1WfVSjMTUzKFah2XjsGyysGziB60dqI0DtVkW1GYuAPlpgd1cxr4La1egTfQDG7ZFA988PQC1s0AZ
# DATA F1OALt/EB28VwzE+1wv700lwGI61ftYIJ3PBQC4r1PAkJLTkhihM6PIiCGt9zJeqzcd1gRi/D5HF/T1g4AwaHd5A25WdJh5OKkDu
# DATA j3eM2U+yesL8yGYpb1lL37ALVOQ74x2hIzhRV5hbo6bzg6UEuvXid5WWf1cp3s14sHykd5WXf1c59i5+sHKkd1WWf1cl9i5+sHqk
# DATA d1WXf1c1BbV+sXakd9WWf1ct9i5+sH6kd9WXf1c99i5+sHGkdzWWf1cjhf9+sWnepfFVzBqei65uu68/AjB1rSqE0kUjEVnahmTf
# DATA XaFWwtEZcuVEgImGhPcA2mR20nuAWhrFRJ6UUMp5lZxXY3XUAItW0GcgVQ8ZBFy0EAr3DBOYVTFSVNnxUw/ylckMLNgvE22PUKVI
# DATA TcFv0IhgUIIoU6zGo+OBLQFl/vyDCTnSVuc6LXadnKf04/SUjkrE+tRhQTm5K8rzOg0KTwt+84R5O23w0kyyzrl0sowhyCcPzUoV
# DATA XhTAjC+glX0GwFGfE7DAJeHNvShzUBtXErXU/rKc2KHeIWcaKJpASTKG1qZCaPVHDHKFwCgZQ3iazCqyr5j/lPdeBKx1KG48p3YB
# DATA hxF+Omc15fCAGqgIuZEdehqksEvvuIdMRGEF2gE3GcNP0suZIwe4fBoM/ei9CLOPMSMT2LFnCZn+dCyl2LR0xpIzlrKMpZiocmHm
# DATA Fz7MPNfIevqY6nrm03T2GVZ6HxGAPt3HyUgRxvpwhKUJGODEItuZkn/MoeZRoDCwU/DetFwMAriFDD5QLj7PoURgOWY1pEHUzX2k
# DATA V/UyZo1Eo2vwlaE2B52O598bhG3e/ewPwjGHxEcaU1vEQUQ8HjVMI7oVvBukor0OlSYg6mPeJ5WjxFC+XanLmPMXUci+wQInyTLd
# DATA HtOin07EcGMYOXB+tzUjHGpc8N5VONteL2yNBsNdDsAo+rjAb3FYHs9TDwC3GuIrOxIfhXt8tjX6Cg1ed8qNYCJmxDiCfu4OkMgy
# DATA AZuvJOANfSY1tMSeJtAreJvoTCo6HA4V8TaK4JDcBQ8b27jK1Nu+3GWPuYczEpDFffSOpn6XdnOrvD16G++ML2jeVR92jfAW7wwM
# DATA 6jyusrlFIwGzWAZY087TqMsknwx6g9FosKfwvWX68y65Hhqe+p50Yh95nYNpCxgwTIMusavoEG/UNuFwN6TpNFRQfIpleVF73mR4
# DATA fo6MYYMnRZDTJYuOXZAA1qJYoAoRfgAlNWEVtksmg21Y0pqE08Cm3lhMQ7q9gxPqWApGD8p0AB2i0ATgRXcDJp/HzKNu7MkgMfM0
# DATA WZY7mMpdMNFTZaZ9KGbsKQ2G42QjxZ46jCnodZnnvHOF+kiPSi9MkxFhVJuVTSyR1pK6eR04hpqbG1VeFESOb5SYUVjQeVFcmV/5
# DATA hK8tyWvpF1lWZvGd7Gt4u0QWTcSFJZwFvIhO9m28YXKdR9ZM1gmEjiWEsVJO9q28dYK87/kLM/7Cc9PuE8bif7zeT0RxSW9rDwaj
# DATA sc1v+W+zHw5+B0LKgz8w7+SnzHD5ycHns/8Ao+Ts8exRmuDy35jBEvSUn3izb/APk1l+M3t88DuPqS8/Ofg9/flMGC5VwfQiprX8
# DATA ngp/NPtOs1cyMSbd9g1YLh8d/CP99rWjsHz2/bYb4mmNBjCS2BTGptFgurM7YY4cgZlW6rUbToCuIaeIjSM27WvbhUwpaD2fyVtF
# DATA 4bMFMxbPDTQoMAt9PoO6kL/yBmdckCwMu96HZDGyEeWYLCMfTkuBs6axzByY0yO05Hk5tvxHPU2F8ih+MyarufWamrlQbyfJZknG
# DATA KgMpqD1MyTWhJTF0TJZLjNaJE1luqtSqLi2P/fye370bMTWRWQ2+HdD/qGbB1m35OG5EWnYEeDZFr+O3oSEMaVQ/CMjIxwY8zct9
# DATA 9g0UCxLOzw9TTJaHzLz5ZknWcnpajJaHNMLxWTod/yQ6XpNZHle1vxCh2TNT66ej1ZdS6kfR6Weg0mVeZvSAUehPcf2cBsNlRlM9
# DATA 8kPpE3PP+WqbVJqLWuZ4n9NHt4ct6Fm0mJubVWVOfFYPjwZCFCiyaRv75lxfn+vWj1HtLUNuGQt0o0qqGQb7k8PdSPXz9sjHxh6w
# DATA IB+MhRXQe38cmVCi+clyQ5Z3h2oWwhAQasKwz3tLhu0S1k4oL1CRYQwab2RtWtSQKrbaDkhH9kIyG/Z2A66F77Fpwgl2ncCxXTq2
# DATA S8d2eYpsl8uomKVcmqVs4rM2749j3T+xce8oLx3lpaO8dJSXjvLSUV46yktHeekoLx3lpaO8dJSXjvLSUV46yktHeekoLx3lpaO8
# DATA dJSXjvLSUV46yktHeekoLx3lpaO8dJSXzwzlZbla9Wv141JeNoP17c5zRHmZsfN8VPLLatmr1use9ZtXqhS7pWLNKzWKV6qNptdo
# DATA dsvNsldpJngt6d7tNB1mr7Re8crU0bVSvkl/r3vr9Xy1li+V8mUqv/brd6slKrtZ69Yr+VKx4TUbXqncyNfolmq+Qq9fz5dr+Uoj
# DATA MSa1oLHdTvMDVqjajY9KtWK+VvTKzZJXnFQrTa94r9F8u1qJl1FvNduNcrqMZtWrVYsf5cvFRr5JlSpX8yXqC6pRDTXNNxuHMGua
# DATA yqV49EpNeV0rHMFbavHw17kSXouHtiQzdyREhbH6tmvNarV6DLY8nr+aLU+WgsWWt12vBZXSEmx59XYQY8sLGu3a+nbEllfr1GFb
# DATA G7a8yna1WY7Y8pqNaqkUnDpbHk/7/GLDgKP7idg0DRXOXj6wCtC2QYw7TRqdpnNT/ZqO/+EPrfALh+0hZBs788jfrFoezsJnk+zJ
# DATA g0cj2aumSfaiYo5AsqcDkHP7yO5p1aGKxk7NPztiVGY7jY0Bo8TmpBFo3a02uIrzue+ifs3ZXbXAnDikJwyjnSOfc+RzjnzOkc85
# DATA 8jlHPufI5xz5nCOfc+RzjnzOkc+9QORz3DacRshrm4fa+NoihcYURNJDDDeUKU89wz4GadDduLjaTfE7qRavaUH2GhVz/464Nbc8
# DATA fFh7pRufZDzz1wofDsI+FXCb/gM/1AVjXt5e0cfOo7oUJvfRr7dX3kidSFcFvILPminqkslQ0KVq4ifNreQQwt3B6gUHq92B6hfk
# DATA QPVR8cKf7kFrjktGobQ0HVE3hoW5Mxi0cbbY4zihOWbLTBIoZAHO9tM+n/08nFHkv08Yqz3rIPlJo7Znn8vPxG9f4ph8FKc1+OGB
# DATA ANRhtDXspJocBmPmZkBVGA96AYBg+GitTDU+Aa/Cb8zIIriB8fPl0cnxHGCQydaMFjv7jMAzRQR40OkgMK0PNAvuIQqXqcavSB4+
# DATA PwqIeGqayIFcP7JOng5YzdM4zWqedwaVM6gy0OiiCeUAaxxgzXHtqLn22ukA2bBM18uALCnBrmAMjN3BZLAz8oe7Fqj4U8NNOwEC
# DATA S9LLbygYGkt7HRGzWIwBFHKCgMVK92tl3vOH3DmWzs9Cvj0R1OIPGN5bZCPNRiCkQPKdAnDxm7DV+UV9L7hP/eiN+ycOH8ygxe/0
# DATA x9OuPxH08n3VvD00dEhCvOORvOt2TwO2eMqYShPNOzNlDPDEajjZ99YEeRoQ321PQOi1niP1d7LvYvbHa8FozFBM2KlifnuBhWFu
# DATA o7wfkgE/HdKCDE4YjboRCdGEBU3D6YMPVjhAxOA+YYjoBNdk5JZJkfHAJD2ksYK83r4xP0TaGDrKiADSRlQ320ERojycA3v+qCW0
# DATA H6FPiUKTE0fjOdBSLRAsalwpC5cKqEAMLuXdAMB30PeYeKXfooHS8FMdxXpAfZ8zCFkDJZ01pCk2nvY1VhJ7RKPp9jZA8nlcmJMY
# DATA 02TQZfpi0QOCcTSaAsjL051mcLxUeDOQF5jNbl/hpi5H9fjjcT8sg8I5IM4BSTkgcQvTuSDOBYm7IHMdi6eNpan4OpjTYtcfMtmw
# DATA Dw/DBsceBwp3T0NBJsAimWpHo0Mq6qNAnBkL53FiA0BCV3b3wJ80FbqQJMSjrNgpLWWSXTQK94IMpMdl0Ta5tcOLb/LWZlTv7f3I
# DATA O2Le5e1p2G0bLD5VGQ40psPG6vCoRUCvqbdlt58Jq/BJWVjKAtI/RuTZ5gqjCOwyVwxLNtmclewVUt1WU+Ik4Oq9JoUAVqn6/Kok
# DATA RqiXW3cYyWo/9eqAJWxk+GEPHjqWlo26j23LgQrkJm8nB1UdZniLP82/s9UNe9tcUXyYfx8J5gGSsujOy/IxuvectO1igqZc25qy
# DATA G2+bmtAoCwzN2OgiGViWvTojHVnO/qht3FNOfhBHVfVjvB8SxFycSW3EgWQWiGM75dur3t2eaUay3qZTgRxZuXg9ZK6mdsBkQrRa
# DATA KxIl6A3Gk+6+Ir/ET7ASDRQ779UIX1fYn4gKDAQOE1mS492BwhP1hfRcg8cyoXjfQM3SymW3WIe3FRSmB8tMWYfqoNbZdmD9CB34
# DATA AfnEXY7dh6MWuYtRF8JHJcEAKi5b0CkvB5ESEgsfqhQdkmSXeJeAbWPOrYTZ3hts4xGSfoHMaRqKu2PZNFMsYDwWJ9Fd1io5Yn+t
# DATA L+wvs+Skw94D5Ceti53AdBWiCXxPvI8MBZd0ZMH7gHRmzmOUvJCMsH0Vf1IkYiTOhSVOslUkHKZ55kltMI1b0D6JrjKC54gd1VjY
# DATA UUqKSTe9jTiOmPNh35pV/GqaEHtUyzEHYvxRV+2e6tgMgghIg/OBVSs7Xexm42dE/3b2o3hhgC1A5OQLcy4Ix1jm8ToEpC5TV/BN
# DATA T3VN1o6wJq+AiA4yjdZdnhqdF5IrM9vsy7TchLVOdaS18xb4431s7mlGOHqEbH6BHub+FFtkDBovyyN/mhOsVF5+hl0Z0BCTjuwG
# DATA +xwmiOZYl36JLBwV3ZWAH3m3tAQ5EhcZa+gQkvAcsNKbqGpTVKwtoAPjRM5AzVGyViQEBTbCUdjK7Le4IpbcOlsRmyvSDRevDnQW
# DATA nEaeZhNMZachKKJGUrFE6/4uHMYh9mMJQERcYsNgAmpem0rsfwqRmDf7avbQY1ovsH99d/D3s4ez72aP0zRi/+/s0eyb/OxbEIAd
# DATA /BYEZH8FXdjBp3T9y9n39PcX9PcPs7/MfvAOPpPSUfRjkI49nH178MfZNwef0b+f403gIqM3UxkPqYSHmpjsu9lDxyb2HLBA92Xn
# DATA B3k8LYVSH7FAD4PBkPkbmWCdVTutPTEQ2wMgn3O0EYrGCkkrMFy+CzI6AlbnN5AECQVCnoPHC1nF3oK5xNzt/X1HJ2bHUJQgOGs2
# DATA sfiAnC6NWNi39nAv61mqf0lzifUnOARoZCy+iqYLRifJJ+ZPhKJg1x+TOoUFS5buoNNxdGLLjtqJc4pd8rst7DoGsgG2HxFU+z3O
# DATA tOctkC7vk3gduBIe88Ix3J/Z5QCTbq8XsPMLXcL7iOGvA2bf8NphMMmgETt00s23TmJr6elxiB3aAscj5rT7SWh3zSd2ZKX+QmyK
# DATA nJVCP2F9vvRmyJG0+Rkpc5mRdh9E6VZPf+mcBpWY3VYJDKsMjt0BPYfNh3hD0QJTSz1Y2CRa0PR3wMHeHY6FVYmbNvHHd1WuCioQ
# DATA 9nFyDMf4VJcsRyUGAiNR1ffA16XImtoRs5NMG1HrLW0TgHxqgEQ72ATY2wrJQMiwC6bAXQgnWfaAsgaY+Ah2AHavxnepMFOPEMFx
# DATA nk00v7rI0kYO2XQyCmXMBv1WMOqPHY+Y4xFzPGKnzCO2lKZZ8gTGksbxmRn5x4s9noCJ79jEHJuYYxNzbGKOTcyxiTk2Mccm5tjE
# DATA HJuYYxNzbGKOTcyxiTk2Mccm5tjEHJuYYxNzbGKOTcyxiTk2Mccm5tjEHJuYYxNzbGLPDptYq1ZOM10tyybW6VSD5nPEJmZvOx+V
# DATA RqxUq3iV9cZH+UoxX6L+aVTypVq9m6+CVqv0UalUyde8UrXslYplr1HONzzchTtKTdCAxbuu3Vlfb3RSDGMg+KoW170yvaPa8Krr
# DATA +XW6UPaadRRZ82qg8fJKKHsdr6usx4ut1ZvtZieDmKtStIi5yus1Q8xVKsbnw3a1UQ0yCqhVrQIqFrNXMz0lqlnMYOXGUZ+3+qVS
# DATA aXgV6odyzWvm6a9SqVeulqiPPHRukbt4fkPsUaQ7q7Xabq3RTDCdmQdSTGf1Y/CU8cowPGW8yCyeMppHjYa/BE+Z36nEeMo65Xaj
# DATA Vbd4ytbrnUbEU9Zutqrb1YinrNysV+qNU+cpGwaTQ1nKoF/0fUvQfFmBsgqHyQpN3h6DSltLM4GZkjXNWczTrdZ+4dXoT7nGQccY
# DATA NZf0qJSgKrxcUE21ygTWysbdTby9XOVYIIfxEraNRJ4WUHjpduVi9VugwmO36RCYo+xylF2OsstRdjnKLkfZ5Si7HGWXo+xylF2O
# DATA sstRdr1glF3K4rB4uNr+/njjXX+yW+h0B+TYwOy7vYLDWNT6l2HSnFPX+HwULspXcrNgqNKqYevz9srmkBy8+whRBt196o1XUPQr
# DATA 1CudqcCF8fGwjoVzpc5a8S4SmLJAqaUPc/nqcBYwyFCkHLvx+ZA2DqiYM1iC9+dYttyx46MeO3bHjX+sx42PQ6/1DBxD5vCdjnct
# DATA ZtkSACtT78yjyhn8Ws/K4eXn6gzfaRBuxY9bnzDTVmIyHJdiywqkRofIVU9HtCCAZxQAeYW6wt21W7n4Jjv4jCunceh4+gAotK/w
# DATA 5uQgrJk+ez49sT3Yw2nnYGfaBXyfhp3rAU500AEafns64gnqj3oa+l6died36wpskm0dkvHLabO6CpoljLqng03SbcbinCBO5HFy
# DATA ilgm2GrtctuAZ8drAScqtwO8uE022XS0bYAnX5CjnlYZzq5ydtUCsDZ7cjlcF4frclSDagHd1ungvfyyP9iD+BfEgW1/RzDWALmh
# DATA FFvp7OHEToBdi3cgVAaIvhbDhmdHn66+3wfeQqBgWExYzFu9u7OWYALq8z5QRLSjijBiSn+P0SFRo0kkA0+mFzK8bbEAmU2SRVJy
# DATA xDhCLmf04xw4e4lDgNDHBmwZIsWVlP3qofXVz0dyVV+ISLiaxaw62zVGuo5d5QUV5kgJszQhXB3h2KCjDqmretRUVX+P0YUtrGdp
# DATA QS0TDEpqfwmrVQVdBI2cp7rFkoRJdfFVyTVV9VR7jDaWb3RJpEt4T1pA+ldxtp6TIp6MBcribLLWtw18pPDpFcWLj2Vv8AEvI/Rk
# DATA L2Be0IyVEtwPBcWF1R0kjg5BfTQlKQSs8vF0ZyfgCDQII3hnQgmIwQg0FiBVYlRpaGEutA+Ciq5m4xIONI6Nq3UHABUy5accj6eh
# DATA AR4MEIL9HcMRCwQqGKdj0eTtsMPQKRPBH2JkZ0+l8gamPgJHD2girkYGOlEEScSwyog0ojKeP6Q5BwW3LLfTj8TYjWkwZ+46c3eu
# DATA uZsybZzF6yze+SbsM4JweInR94BZ3IGSCfsMY5bN76T5ZSMowFHQC5miIzcPde9N4RRMqRsGNtuZhm3QGUaKkUqj9dqegoCQ1VvS
# DATA BI6TJqQADs19pNcNp6mOPbGqf595AqDPRgNSHf5E61y2w3u0wKcwoZQd4O+MAk1fmVaZCv+QSmqTqjbNQagqpTgZGhDgMhw5ChgT
# DATA zvMnmNBU4Qs2a7tmhgzuc3oU3hGC1IB6fY5HIBBvg3uc36Q4ODV/7lBzeCGRU4hC7gejVoh8xxgJqnQ4DwyD9llAhSpKVvDeAs8W
# DATA i1GOpjFp1y5sLr6LCUzAWIlw3ZVgwnKWmwHTxp8k4m04uGYq6/HhBnCfLGrjpoajNPJeN/IDeG2ae0fJfqBM5gRzTxMT4RHsP9JA
# DATA d8c5ZscYG9ZObXSJmXQVhUFS7sMEU4mWrFlGrJK2YWkH7bDlywgq+kx0ZWqmWzRnwX3Sed39Ra28ykeKjfnF9CW6nZuc6akOiUxH
# DATA OUSSGWG8p4ef3UfFlBOC/ESZr30g8SnwT4sjjZsUR6oseDeC4C6zhCAsy3we6Eu+VU0LjVgZ45fh+KnwhgBtEQFiHSj2x+zU+jv9
# DATA wTgcp5g52BA7DOf75oAEE/dnJIJ41RyZKZpj2loHnQhPtBXmVosB4W0OYp8CM/S7mL46D4aWq4+pK/jv2k05BZboS7FgOdYsjbew
# DATA y54CU/SVcMJe2YjEFoAghRRScdaw5BSAyVMgi77WlXdCQHJro8XFblb7FIiiN0kA6RUPKdU2+Lo8pIgWjdonzJ38Y/ffLF4cemoy
# DATA tmlx/hUkOLPvZw8Pfjv7/uAPs0fewSegqKGvj+jy44PP08w4/8ZUN39mUpv43bOvmSXHo58+nX0xe3Twj6qUP4EXh679cPA7PEGv
# DATA +px++Y5e+LV38A8xph2LTMdR4zwHzMJMzGawa4UjC5FfUHrkJA1VeIE7LLb2QMq9pyyqnYARg+8i4Cx0whPNlcgko6xEwSG4013M
# DATA gHMl8Dv8Fkd/E/Mxeb2fNfuNNRinR30jTYvEIs+dDvthyVuhOcyN7OqNdvcnu72TpLvhJFtye3Yx49vsEYByj1MxcbujvTl0xE6c
# DATA 7wZO7mAbPibPMx2xRqaIcodZvnT9UU9tTUXOZziWUHQqh1rw09m2FV+CRoukGNw6Ml0Q4E7R3yyef/ONj2gdPS3am8U1d4w3Tmkf
# DATA QWlrYpuj6eoXIxZ8Nnr6JNX0Ulp6eSV9+jpapp9ptFHIZ7cWToOpxrRHGJLHyYbo/IsoiYHtid1BT5PBWGMini4pNCg7v80NZRZ0
# DATA w0gxVhzLrcF0JNwUkX7VDZej7PQS9BUXvxxvjXLxYzrYN8F1rb2N3h7Tje1pN9ApkbyFhaiiNx4GrTAY50z9I+5iFWjthhJ6DUjY
# DATA +p1gsh8LBap2MJ0u00QzFXBLGhVvkCOocQQ1jqDm5AlqDlccS/kcy9ivZ2N/H8f8flLr25HRODIaR0bjyGgcGY0jo3FkNI6MxpHR
# DATA ODIaR0bjyGgcGY0jo3FkNI6MxpHRODIaR0bjyGgcGY0jo3FkNI6MxpHRODIaR0bjyGieHTKaSjWotI9LRlPq1J4rMhqz3XxUJppK
# DATA uelVqsVdpp8pV71StfJ2pVaOd0er0yzW0vwnVWpApdr4ValcSfKfVGutajOL/4RHKV5MZX3dK1fL/7m0XvbK5SL9aXjrpY9KtabX
# DATA 9EqNsleqlehdFa+8XvmoXKrnSxUaQzDmVPOlOt2Sp290U5VuKtED1f9cXqdHy16FSqg0Pyohilz1qnRPpR5rVzVorteLaYIYqVCe
# DATA TPh8qdTslarUL3hRvQh6nkRbW+vtdb+V1VZFPUOjGJL5obhrqsVaxF1TXS9aE7gqX/YzZnO7FdRbnWNwx/BENtwxvCYs7phqueHX
# DATA Kodyx2x32p16jDuG6tNsbVvcMZX6Ohck3DEkJNb9wOKOqdW2K9VT547p0io4lDwGQaMH0a2G5cXicVGtSwf2OLhXpn+bv7DN7Qab
# DATA D1GRh1PS2HwznGwnucVZtTChq0LG/ilZWB62Kr26/ImV5imLxhDKsBY10j/GXCNDnGgxlQnLyKvJHxMalWY3YVzZ8ZyStcejimhQ
# DATA h5Xoj/pXW5hsvbJCnMtWs8RYxrsu7mNndsTcghypjSO1caQ2jtTGkdo4UhtHauNIbRypjSO1caQ2jtTmBSO10QahhvZZWXttkTZj
# DATA 8hst9fnUhXosBxmYKVo91TJrUm1cDLX02mCTeO0C1vntlUsRmhcOq1hwLn3qYYXpAvc1zlljTj64c8Pu3LB18sWdHnanhw87PTwX
# DATA a/JUThW/jpkLpLmocHOy+KniT5wAXjqw5vDmvSC4yyccZc0eE2su0i0nhzYXBF2Fyr0tuyTUIRp9UAW6TwF2Tp83VsRtQxrV9gjY
# DATA cx75SEF3/xQw597p41DzRCTsWCFlw17uRADVpwA+d5NDX6qNZIIoaU5zgnRHHujX7VPAnbsuR4kRAyRTTjXZkAucyrgy9txVnLX2
# DATA DQAdVp5oOJgsZF4iF2o6Ck4YfU5FYAx0fITJGEMGiA636oaYU7PUYRABk5gEsSDqI1B4gYAHhGrisD5Lo0KErtke7euOjqga/O4e
# DATA eAt7AUPI4xZsVJGh0e0WvCthxyyHHOgeuum1qFBU+6jKyNulH0cBNqy6+/Iki5c9fyzV0YxCCq2W56CgvGOxIZor2NXkVGCL/Z4q
# DATA gFYHVVPmyy5igyN1Ih44mfRoh1TKPMgA3Sv6uD+JyT5OvnOaAekThgIgTZ2E+EloqusBjgOqU9zitModoncOh41/zk8eO8pJZ79H
# DATA 9ruz2H90FvtRKSWfIg4Qb+abjejFPJJvhgx/rshRAHre9ziXdwGJ5BnDBz3zcBqnwQ8ZgRydNDmkDQd1XGZIK0lBu03XcazKTAdx
# DATA /Bg4RQFPlRMDiawGGUWV3QjGxtdH8jDYAJBCp0kbN73utBf2B1NyEY1N1KdJPgCIzTDodgHtDh26qxDXyf7qF7z3tgVunwwTJF0D
# DATA S2mXTFJFc8B8NvrtdjXegoHGd3FjdC2uwi6iIqh2NHlp1lhmF5t8fH4k4DSE/TGw1P0xQ6jLCtEYzz1AWI8WvZ/D0F7s3W/JChqT
# DATA eTnmreiC9+5gPNH2n4ALMfePrvUFdJCsL3AvAfmG5DVsAwDbkxihqc6wIcma/NhBYizJ4Gw1Z6vZmsEFW1/cYOt8zsmnCeH4Lm9W
# DATA 6vmsANj46LVFSgloPSZHuAfsNlk/UfAmx2EEJpjkIJoOHBa8axEYIE7hCEqbofbhMeSggW/hB3JMk2MHnbDljcndb5nIyjankkWY
# DATA gYK5uCQGJLdYAh/R4pe9PtSk749Gmk+ID5fgPYj6ZBiJ6oxjmu1S7XNjkvInFSdTkSz9Y0SIaK5wj4N2JOBy5GkVfhp0u1YLMhkg
# DATA zeY5TxP5/KqkBKiXW3cYQWk/9eqABWYUvsPuMzRmt6u3RkPEQwfKmkveTnYDr6rB3vx7dtjsYcos/jT/zm220xgjeyRWir7znLQq
# DATA 6gfRxzpaKDvQdpwPqmFBqHChzWhFPv1R2wThecNfwvGqB60eSBBJcWawWf2ylc5TaDTlntg0DUjWWPpyyAbbJYA4hiMAmWLeR2Yr
# DATA 7LW8wuTMCcRoHp6ZxiAlNdYbtAOO409gz8Lw0xacUCnZwUQEIA1UZ8BAQ9rInni/JoVbsOOrS8ZSPZMmx5ZGvCmmazSEGQhesd3N
# DATA i4iesYKuSVv2SMMTTb4jjtCN+SOkp7EM0o0hx2DjI0TLmAWJRNxB+wKszF2yfyQM6nsy15XVb3EHmj0QPC+7IAK1OgD6KFwOjC4y
# DATA GJWV8uRjY7fg2R+Ya8sOzDV/1GVQWb/b0wNzY9BhMtY+aTXGTN2Dk0cadCfumxW8zXuDEJ4x9b0J6+fs0DePypDkC5yztvIS4R4+
# DATA 8XjYFT+z8Yhk7xHH42/mj4eW4jIef0MGS0qQTVutaZfRZLEJqE4SqsWhnVXFpUdSincScB6bVEbBe5tW136OhpDMkEHYFZTjHkux
# DATA Qa8n8M9kXPSES4x+CtGDZr/4yQcqatGzP0zXlx2m69Pt7aQ8e51BrJU0C/ofDvYjCabBuAreByG5u+0pCfod2Yoy8Ml6Vyiy8MCp
# DATA TX3V8qfCjvfEY2FX+9kXYm8uK8ReD0dtzhjoIwBEi6NvLZ5dQbzenfbCdh4bhQwxrsaDtc6YDXtAC01gmX/ga17qaJ/f5tvDCBtp
# DATA RyWR8aTSJoCFjPDQE49TukHHGq24/SdpjLb9Z65I31+8OtAJhxqDW0x+sbh5659JLX3yWNAdepTVxunpcKI91xGviAttvDsIYlRo
# DATA /2P254PPZl8c/BFcZaAxo8+fzh7Nvpx9T39/wfRoX3tMdvZ49u3BH9PEaP/KNGoPZ9/Ss3/x6C8ucPY4RyXOvqJvTH1G//th9si8
# DATA xGZSo5u+mz3CJ8Wj9iVY0fB+ee8Ps78e/MGxoj0HpNwmzYFTXgeTPU27api5AV4szKs59ow4zSqAiae5AEAainACw8iQABByBgjQ
# DATA IdgNFKMrzePRhHPG8FxHtrBMUACRjoXMaUCWx1IQO9/Rp9mxPhYRZ82elhyQ06NQI23hdwc7EcUXZxjyy5M83Oc6YSSm3wwnFn3H
# DATA yXGowZRW5zYwQweiwbkbHH3a4aN14vxp7woNuLdNxgUyusjv3yW9Y9zLnDayxgMchkJHwpBFMyHuVE4r/BvFNH4fKClBJJwY5ytH
# DATA NpVsR44Cjiwyw6w+JtCjIRJ6DSirSYpbbfG8nG/EJFbZ0yJYW1x9R7Dm9P8J639NwnYMtf9CbO+djco/cY2/lMI/gr4/fXUvEzHe
# DATA dKPln63lcxq8bfGGs5LkDjGkY6bV2/soKSdnGEdTeZXUdSKETuOej40vs/XmiVzaDsYIaQUjbE1yo0lRR8cWVPXaYcdwu1Gz9z3F
# DATA ZLIkZ9tImWucVoMjK2RQcFwiaN2FblLUZDzHhPeKTw1zJpCwzYVjzqEaT4SNi7dmg/FETAX0S2Q5XFAsZmDPmkyphJ7fn3bweWQb
# DATA CSryijgB2zSj/fyg7yjbHGWbo2w7Rcq2JbTLUo7OMibxGdr1xzHrn9Sqd8RtjrjNEbc54jZH3OaI2xxxmyNuc8RtjrjNEbc54jZH
# DATA 3OaI2xxxmyNuc8RtjrjNEbc54jZH3OaI2xxxmyNuc8RtjrjNEbc54rZnhritVKu0KsXjErfVOvWg8xwRt8X3nI/K3ka2qlepNj+q
# DATA 1/KVutes5EuVcpf+KZe9Zs0rFemXilcq06d6vlzp1te9Wt1bL3rlxkeVKl31KjWvWn67VFr/KN/MVxpeuZSvJbo0WO+U29sJ0rNS
# DATA o1qvVLNIz9bTI1cuetVibbfWKN+r1N+mr/EXmLLiLGxlakG5XvMapXyp2ctXG1616TWK+VKDvlS9at2rN+nL0hUrVVI1q5VAEtf4
# DATA KF+hQc2jL+rvUgGobbdCF2JscZzJGX9Z0GnU59DcqQncCkd8wu6+TPpyRP1WajCRHKMa1OMrwBRLBcCw8eTpIrrWk4ebzfi073T4
# DATA u5a/DIfK4K+VJs0bKuOItHG8jDRtnKxIizYuqDWrtVqcNo5uqpbrMdq4BJGc0Matt9cj2rhqq16rNSLauHartd2JaOPW25X1YnDq
# DATA tHFYf4fTxlW0USAmgX5mDn8cmpmIL9Z+4VXpT4X+1Gu/sItI8MW90yNXYpJDKjDq611lxA76atfcdpNqxeKFZDBPwj255r29HO+S
# DATA zdkRU9UAedXw42W3CgpVqy+8yihejKfzKWIGifGXkFWtQ3w6yhnntFOdVKY/pZo2+TlWFE7IwmrFiOx0DJvkcjlFP1eczy9nej9n
# DATA 98ACU+SQBrKV4HjkHI+c45FzPHKOR87xyDkeOccj53jkHI+c45FzPHIvGI+csjjiAiDsU/kbsPdur8iao4a/It+BCMPdwCbm7ZWb
# DATA /ggotPyIJzdjeb3CF2havIlkutXS2ivUG61e4Tb919+0Tolffj9+DI8fftef7BbYQ1/lcl4uFWooITrel3FoPEK+BRSXEfuaai46
# DATA tuIOUbtD1MscoraPNrmz1O4s9QK85Kd7xlqOBuf0Wd+Mk9bXzblAmSO5OLKaOdQrB1YVIAufJYYdvadwmOUkb8Ao+9HhyaG/D2da
# DATA Dk8Ca6VvnZxcGgP5TUE93haOqDYYqPBq3wh0CAKHe7wM7nHLH099BZuGT/PvhEilrsWtH8jH+feSgG0PBtzR78nH5wEBOeqLI4Ig
# DATA XpoPgqh7VUAQySgb7beBQ+T37/njCAERJydpeQFBvDXgsMl0OMS5ZyQa4DCaNxJYyDHoOeQwO0fBaKkFBY9WdYijwwkcHdaH7dF+
# DATA zgv88T4vlCfHPUy04cwgKq35d3KIoWYmK5xq2A6jKczIaGxa0/EuzdyAQXJxBl2OUPsCV81mTmREwKqEXSI0DBioXfDeQUREyNQK
# DATA z4GPh08xPxAv3dacJ0+ETh014DkYmA+WHpjrNNXzCKvsAwPcQg7lg805GpFhwKuHl41eIEwkg4EjeYSFo3FDcY4QiFVADA+GbBui
# DATA wy00DQEcwN6W6LewuzuYMvTok+O7xppyZqN0bOF2ZVnh9m6IzBlgeExHFjIyOSjk8yErcDIY6qXTCUc9gJNOh54amMGIIdj4V0Ev
# DATA 2aNGjQbbIu5GAb4ybti0v0tGFdANbBiPJxmSWM3PbEQsJXnEIbk5f0iMupUxuTnyw67gpfhk1phBoe8TGCew3wbSw21ye2DkYWoa
# DATA NsyRr5aDwqwGmbBGmomQJCKwNwFh6e4L2tsTD0y8+s/+Wrmx7Fr5QHxSclDDIU1hMzCY3bCcyXWXFCEY1qzG2R0FqsdwzPoebj74
# DATA aJGYqyizxoIZrkDCJwxqjdFF5PSJhyJR4xcX6/jHACeiH3fRLRfdWia6ZU8xF91y0a2lo1hzg2CnE91i4C1DgOd7O4OBgOLp2NYz
# DATA i1+7KPaFIw2eHQFLBbWE3RQJIyoPWV+LRZvU9gxTM/WRf8+OqtooXW311lTYSy9McUoxilKqed6IsuiKCf2UObt2BMkNKdYL2UAq
# DATA c1p1z+eUV53IGww59bpQmh8g4x0kzPKBGtehQS2Lx8nUjaZm+sFUaKqkGHph97TPeyWv1ZsfxyoVahxAoMLCYER3F2qx+1OxLGVh
# DATA mUChJN1QEZc1fGFCylpmEsaPqsCHi3SrJPvKNl2iS7LEQzHPhqQPJ5KQfk6KeEIDSIwUKCNrvdloljdHEn4VxljIgRRKdJfxGvs6
# DATA SpsTj4FtOI6K+Dt+KFlXSIkXGinyHgqeIbmL5mnB40HLsfKzCFkYvDIqEniVY20d43WwpoZhX2isUCZZxAaCEBuKjKCGQ2OAdNze
# DATA l+UpwHw+ECjtXcTxdAf8tZwpEO1hKre1ryEoGa8ygp2csoW675l0AZ0TN2QbRtPLoqt/9IZnpGqc6elMz2VMT2dr/nhtzbnW4TOI
# DATA Vs0nOszpgrQZ1rXM0LdgdnKtwEI+CmSbcKyt0Oghhl1i4fvsoVs/+5Cv/Lec07n4KknQ5MLSxwJRrjnC1ZQTftaZRbngd/lbEoQ7
# DATA eVxPlmlrAGdB3rXfb4n5bfCvLr6XOu3HGXw0iClwc+sp/sJtWQJYPDq2ou2xBDn4nr/P7gvwnI1hdom37MQ56ptNQcQTd6ik4b5s
# DATA L4rvBDbCoX+PfZeCd523sybaglL3KPsMsxIhYwnGscGT3OvysR9OVppm61hqEiQn0+X7wy5KHYf3kbou25Ayvc+c3OPMjaeIpowm
# DATA 1L2guzMlcWGTlf3bwWcHv2VaMjCIPebP34K6jGnD/gJGMfxy8Fmapez/ND9+Ovtm9hhUZH/lC385+Gz2LS7lvNlXs4dMRfZbfMcN
# DATA /LqD39MfEJF9Qa8Dkdlj+vkhU5l9QwV8j98OPqFivgFZ2cEnHpXxkC78HhdBjea4y54L6xBtY9cL8RCGK9ez9zwYSf3RXezy+f0g
# DATA h7AHeaUj9h2Hvrg/UDLkoeKoNO8hAS/Dm/a5MMYmn4Zd5kalFe1zNic5lv5ESFIDpOqTMFvIWiZk0oEoSkdaZtuKlsA4a+qyxKic
# DATA HnNZO5RzmGNz5xvqCk/UFHsZ9J65kyadzMTRCZOXsZ8fjjkBAcuBM8N0VR2D2XKjduIsZlrYdEJ+zu9KUGnc2g3aU0kT6Qp3PCA/
# DATA mMiZpZjHaK9eqZbvhX3Y2n6XJjfySC7oSC9TZ4gVNgqoYCFSCPsQwWIGKstI1mTX0DcvOzXnmzjxpfa06MsWVt6xlzkL4MQsAM1b
# DATA dnTF/0IEiM5S6Z+0zl9K5R9R45+6wpf5GGu8zV72TCyf0+Ati7XYC8RHH0tEilm4vUEnnrfH3TDZpVru8L4JFl2IPE1jGTHFUc8f
# DATA csPltZBRcm6AZidYl7DVoimTJF+TNa7Me8+As42XpC3jnlOTwqPumOJ1ovBBCCLhsj1tGNAQjFFLr40DP3j53f5gT05HtFVyKWij
# DATA hgEP9e5gOgL3F3NQhdthF10F646JVkgfMd0UjAXBQGB6LnOGQBE59QfZ5FOOx8zxmDkes1PkMVtS0yzl8ixhH5+diX8cC/8JDXxH
# DATA ZOaIzByRmSMyc0RmjsjMEZk5IjNHZOaIzByRmSMyc0RmjsjMEZk5IjNHZOaIzByRmSMyc0RmjsjMEZk5IjNHZOaIzByRmSMye2aI
# DATA zMrNaq1RPi6RWafjd4rPEZFZbMf5qDxmdeqTYnW3Xm/eq6xX364nKcjKQb3VSfdksURdWd2tNRv8uQKSMfW5Sh3Ln5tNr0Q9XKkW
# DATA e6VmMU//qs8l/TlB6kU93+6Us0i9ys1UFco1qkKx/FGpUfRKJVCweeVScVJC2Lh5GH1Yo+Y3WplvqtVTdGilRg28ZF6lnF+veqV6
# DATA FSRopRp1XKnCzG/V9UNe16rUt7PZyiwStTzcAR8A/TKjvfUMIjOqS0RkRpUyRGZCxxatgGql0ygv3b/1jFeVi43oVZVS6RRfVRFG
# DATA NnlVud44xVfVynarmsVTfFWdqeh0qyon3IFHIpVjkaZJ5UQ6WqRy1XK90mzHSeWSFHKZpHJBKWi0axGpXK1dD5oVQyrXqreClkUq
# DATA V6H3NuunTion2YV52WbQaq7CHoSnd6eM7dIU889+JkkK91ZAwjz0c2n2t2oW+xvin417e7m6xD9VyT1/OZK3QmNRWFO7Z1GhyQ0S
# DATA 27zX45OKbKqRiZXD4BZzQl8/326SAGvHg15Hs8M8Dtdiq2o+MZzVVQvsuVSd427RKVqHjmPOccw5jjnHMec45hzHnOOYcxxzjmPO
# DATA ccw5jjnHMfeCccxhLoQT8vBHPrDYaYJdMLRzGxc/Nj7JcLzB80SkFJ9fxtU71sqXhb9x0Sz7sLP6U35ULdy1jxUvnUYuAhiqnPli
# DATA iqMhi2oxLi88kFe3p7L3vGEX9LLQ3eFSRIHHvHSypWPfmy+tvVyqvVKqoTq6tItSwPaU/EUMqqkZw80yAm0/CNpj8N3pZ0CSJzAE
# DATA Y4O91An2RIAM5VSegH3RJT7BGGsOOhqnGDe0WT/Ci6WrZPNplR26tYJsPqyu+rl7uZAGwX9FGdr31l5eDWlpFF+rF8+X1nJFJH3x
# DATA qsf+00Zv4+Jq7+JGqVotvnZ75SpNST5iyaWig5Thw/3U6Q7IZ+2dqxfXflGurpEH1mY8q9Vy7vZKEXfzY/qZ3i/oxvRNF6KZI12O
# DATA GbA65lqrqYPg0QbXbxWtZ6rB/++Tf0HHji/gyisbWYO5Gr4aH8TXSrXzRd2bXOqFB2uFDwdhn55l4kKptPr4SsYrO2E/HO8qUNRS
# DATA TQ8mTstKwEUIEN/vA2VC6ADwPJMeriYmTF7PijV7WtDi4XlkumWNKnmBB5xGIq+9Cnr+tUUmI688LJ6onI+hB8kYUoeONXKGBrfQ
# DATA JWtuRT3pjN9Fhevz0IXJfcgZq45S9g1dpn6IFC7KMjSN+iCaQ4pwSBGLkSKsY4oOL8LhRRwZL2IuTump4Ehcm06iBcBZWxrTUzS7
# DATA AZV4FmGMzgLHXowVgXEfiRWTQK7HpQi3Xt9vhJe5YIDei+vn1Ya5Aq6fg0evFC4j0k9wspz5kAyw96rSvIch6ZtiTJWiKxGSfrWY
# DATA BaVfsaH0G+WijaVfqs2H0rcMGlSfK06OCXlVPK3icPqxm61+s4tIoeVzzS5Witr+mI+rX+V6VmuH31nnMusZZaaw9/UBRmo3H0S8
# DATA qIxi4QzCyqFb5RfVMxEnFJwGblN83HTgI9kJsXF6N9JnrArFAbloXU4MyMm89jr0Jq94+63R1dN5qRx89EjRjkhMxN4c/ymi94zG
# DATA ZS47gkgyRRPw/FIiXEF8T6BulLGiLXkbOcNgzLTJobPs/piQZzMIwB+xWxQAL01hxp4B5AzjaTC5AYM5aA6CeRg0cdAZmxUszf+V
# DATA zRMmHRjzH6AJ9Q4Fx7a0CrJJwA7lN3j+wS3iFobzS5xfcohfErM/nWviXJPDPY6nCnEHHY8JriuBzulGKHdvGkdECA8Y88msNRo9
# DATA f8wgVwCcYswxA0KVE+S0ni+BSwOEpsEaks5FgnoBaTY27bfw0doGmPBrfiDAc4EwzCJUivVNjaEJPTYuDXN0UfeMP5qimjv823S8
# DATA Tzq3z5xe1EARFjlFQiTukVa0TEjP4mJ8Vxc63B1MBjsjf8iqehjAkFbwvuGIocekiXG1N/GZVvndwUiQdZWuS5KbCkWyZflJa8Uc
# DATA sejQWJBBtu0pGmSkCSrBJrF77E7tgYoc+HCbwp8mtBK7vk0vigg5GAYYag2xvUW1D9ts1S2sfNJ4lBYYSgEhER4bBmGg+E8M0XOL
# DATA AeEU/YXGJI6Q9YTLNo69p4ZlGyJb+Aksqe3L/F3Qpk1k2PcHYG5NNkvMhDhvbApV0UxkMguvIbyv3ox+JbNtFwy+irJBuoB/AGEv
# DATA Ko+95BbDtsGoyWES9aUp4LxD9HYwHav+UAWH1A+b9wZhmyGpGaUNBArSpaSgBswY2wPU2pBPunF2SrZLz7X+pbCJqAC4OGW6zthQ
# DATA jwFXDzrihQGHrtcbtGVxY/D4shkrTx+eG3Q6iKnrsdMY1jKGOW843SYLxXqO8ed4EfptWEDeiOewTFbSXUxezK/0wMROSocs7TGt
# DATA yUVNvAFqcEXuNYESsZoIhjJ5IUmGENheJO6orUN6vjPtdvcV34qqKYdxxjxRpd29GFMhIwuKTNjbHSh0RBKQyASlIR7tYh3KgEHG
# DATA JylqxTD98dnTji3M2dJLo0E70/lHbToflSvsKaND2zn/i8nCbkITaLJLNqpkvi9mC3t20KSfC0jVwxgkorx/zeV1kqRicYTsk+YU
# DATA SyKOZ1KKqfAbo3ljUDkLjYwgmRFjMWsGXTscGgy1ELt4lbFLhFeMXBXGJxanid5Hv+OeN8PIcob0AGR2H3a5sJHRvInuFc8ENq1k
# DATA pw9g4YWAIttXN50bdOctT7GXYedi+rJr4WcFGBfShCAUa5icU/jjsMAYhng4woweB2aZCYKzb9xVSbMhw76Hu8jOjUVbyeYGaLGN
# DATA hc6WNruQ0lNTBiXXBm5qny1l6/3YrLyI1mwv2Fbg1zar2T/PHs3+nD/43ewHZhl7PPt+9hdmF6NPB3938Mnsoc0wdvAZrqQJzv4d
# DATA l2df0MOPmKLskUdfHtLFx3T5ezCTzb7w+J6vmOPsH+W+g88VkdlDMKnRCz6jfz9XRGZcn4eo08E/gAON+c7+MvuBfqD7v3bcZs+L
# DATA LSuLHAtPg6/zlpVh3sQ+EPlwgi7OztuAiptg1aOOtMrfB8oic8hL9Ghwj6M8/iiKKllMiFgeC6nM3k5Ww9GZ2TZtJCjOms0sY2BO
# DATA j9FMYirj1MvV9eTtkkFg7r4ejEkDtURh8yCdMLWZhJcEzx+hFdn4Y9YCR2y21OCdOK/ZpmfhnUeegZkBvGkMIJ1pl1k4tvfxN05T
# DATA qPAcWE+kgmLnXLr2Pt0vmOY5zVOh810MiQnbP/dAXuzRxW6Kz2zJmTnfxkkvu6fFbrZkUxzPmbMGjmsNaFqz4xkBL0RQ6wwNgNPQ
# DATA /0up/6Np/zNU/jI/Uz1hUZ09lRV0GsxmqUYyuxl11ThdLXCcybayR9MTM/W8ED3lvLdv3rx2I6cOlqqdYR4Zzhkdkf3AOzvcDGho
# DATA BCUiNqWRGksdedB9qnXusvRmZip41NdABosbAGhZ2ALNWWQExAnOhqOgjdhI3CiwjYEcL1MICw8GRr+lzAO2CsBDJeahUE5x/cf0
# DATA mojdjIMq4/0xH6VU92w7fjPHb+b4zU6V32w5XbOU43MkA/lsLf7jGPwnZu872jNHe+ZozxztmaM9c7RnjvbM0Z452jNHe+Zozxzt
# DATA maM9c7RnjvbM0Z452jNHe+ZozxztmaM9c7RnjvbM0Z452jNHe+Zozxzt2bNDe7ZeXa/Xj0t7Vuk0OtvPEe1Zav95Keoz7lzVecwS
# DATA Jmxb1XLssFipXo73ekW4nKTbm7GOazeDWtBJ0DdVmrWaUHUl6Zuq0sVWPeTdUg/hvorqUUkeWitH1agmaeuy+MLqFl9Yab1pOKhi
# DATA DGk/r7abpUYlPXOaVZo6zV2Zc1bz/Pr2esvP5E9b1LyyMKWdUvPKFpvX0s2jh06seRXh+Dql5lXU00dqHj30RM2rlMvPxCKpVJqn
# DATA t0gq9dITLJJKs/jEi8Ru3okvkljzjrxI0LwnXSR28058kcSad+RFguY96SKplZrPxCKpVaqnt0ioFk+wSGqN+hMvErt5J75IYs07
# DATA 8iJB8550kdjNO/FFEmvekRcJmne8RWITthabXrVWu1et71bWq/fy1XovX1qve9X6vcphBKrzF8Fx2DDZ0jVsmGw0W2yYle16uVk7
# DATA DhtmMfA7JYsNs1IPmlXDhrndarXbLYsNs1STn0+XDVMl84p3ZwV71Lab4cdkh51MdDuots577BlpE7FS4b+m70mmKqS3zJq8ZVZo
# DATA IlVGNs1ipaoN84Ul13n3LP6Y9gKzkw2ju8mb3Bn5vdge3WHNVc9kbM+nb9A79ak+T98dRRHnZUjKi0oyRBIKSBWCrYY01aeadvHt
# DATA gvX1dURgjkbeyRGjjFZx2DAVe06nC83l/XRsnY6t07F1OrZOx9bp2DodW6dj63RsnY6t07F1OrZOx9Z5AmydaWrOnXBbEShidw6m
# DATA pyLH1BxUdOVcqVht1hr1CzGfRT3Gh4fxmKY4JMN8OsSVV0p4sly9oLgxL6tj7MAP6E92u/uG54opEqkmNK/eRH7/aplpEd8KXxdK
# DATA xSs4Zy6nlIfd6dgDYLOnXsTPqirNe37TK9d+Yd4WAe2IX0p9cC9gqs5VqsPL2ONfyyrJ5jK0zpk6QBgHCBMDhEkfOnboMA4d5vjo
# DATA MHORlE8TNUYLa8BByHrBcDGSAxJtOPPGgpB5dnDMzoLQUFQlE32IImMUDr56CJGgfjIm5scxyjaEETKJBEsWjyDfVNR3GjrB+WyC
# DATA Rp2DS1B9RtkMWDKEUtRN8FZ/Gb5+GCGiVZxpin3NtKZ2eFvKR2iGWBuQAIiKikmw+u7h9dXPmcqaC1ZNl+v0JWuq7SBepwBKBORI
# DATA ZLeQ6BqGwWHTJSokIp6MLpmqNw6reX1BreeS/BkRoF0m1odqkJ970r8spj9jIQZG+kEy0RwTLg9eHm0DrwPbgIfU77EPwNszDAij
# DATA fM0WOVWMFs2kJsiNJPcm5+3t0uQj43C0E1ilqd7tdEjWbk9HiG3gOXKuRgEQmsKJBvhR8WrxPMYMy81ITDSl9sVAZhxMe54VvEuD
# DATA HofFSPTlFFhPv23wnyLQJeXMteUJf6RwkSJbJiKZ7VG9piOOrSrwoSVYA39sSDGO88Q5AnMcAWfzvxA2/1GZTp4VpEg7U2Ix5clb
# DATA IWtMQUvk/WiAxPUZtYfWVi9YyH3y9OAlny90tcPQpRM5HqdBfJIG0Dxp8pMsHNJMApTY2OmUGJnIWQR/b8Ke1yZC5h2M6rnwjtfF
# DATA tDaGxhHhvhXzH9NVhgw4CCIRwfj0JzLmytxchg7zRuR2a3rFt2++eyXnXbpxI6f0sKwXVgsKyx0kluIXCdDiECihvkZSZaRGGgUD
# DATA +xmOI79BE9vxAg8nUNsLGBVviDCQhLfFZJGbViXUJNYt2gQSaF/Bo3LtuEHUsHYANr+g3wIiaD+g+ik81hzNXpquu3qbTeBZ46is
# DATA C6k54wLkkKprwFmxpnW1FZkiG9zqgGEg8QwhI4XZL9j3bECP9hUkpqplwbumeWpQc94d04LM9zp+2J2OFrFZXpdisHE1j8/yBbLA
# DATA bXntbHBng2fa4GqSuEi8i8THrLu5xvuzg9/OcxqaOqJz9j2JFJoIvMRqwjES9wasJOPg4zqEnmQ/mw5BJ1jwfoUc8X1D0UJ3tKct
# DATA gMj0oIsNtLGJtzOjMds7SwO5R7gFsjzx9eKr2vC7gWPevLCBXzFWBNjicShZ8Oo5YyVORHpPRvgowNx4VUuC9WRvjAakg2lh72be
# DATA 8L7o9A5Ym+fc8gFMNrRSsLgZbBq3nsM7z+n3izJKVkMZqsqAMxYPv6l98Q2VnMgzOOdBrXRI9g9ozJj2k6bapM13Kh2R80QZ5zTU
# DATA NnjuQFM83pVy26pac+rxrt+nOdW2bUFTmc0IAj/xu1TBNt2M/UUjOgoA3s2bB9ryOrwivwpHkykQ1RlK3KqDGmA283i2MqQ8y5TR
# DATA oGsq896QEVXMDTTJgwmjpA9ZeVIHdbt6qo+t+pxTA3VOTbo5vPSLab9vaDsv6nsx+fx2j5S+9nIibh+NJK6Y2se7g2m3zetSzNk+
# DATA LD8knsO1EnR1GeCCx/YlWcDdwX6PiyD7HHzWPsDhLRh6cNF/ONhmxakg5qd95kJUJS0iBO8P9hReuTad/cmurv4HI4azp3nvMbiJ
# DATA BLt5v0XHjTnoTNY4FePraDOkFAk7vgc/MEdqZOOCEgoki/p2dozAVN9HgJ3UedDX97YV12O0N7ioMe9KKFq1xxfwfMTVTXhfRdZR
# DATA Mb2fEfEq7AbdoZJnsuFpySKGwSdFOYiRKgwD/y5GWCQm5h72LNtBDy+wPSxFrECliD/ItPBYBbZrpuwYm/jc7H9ifoa9JTnEf1y2
# DATA /YMHdx7c7q+89JMf+3/U9UF3CwIj7E9BqjrcP/F3YO+yXq3+RO0bJ/4tFWu18k+K0X8/KZZKjWL9J17xLDpgijVHr//Ji/nfz372
# DATA s+tTYYhokQAJ26xnMClWxpyLnGfaj2iCeJeuvENSg7c5aX0Pum3ewqcHClTWSwKVQrbtDh+20d8/JPtQfx6MX2LtBaHfDbc9dfka
# DATA fdW3jMyD4+m2is/oKziSBXWgv0/JdHnppQ+ub167dvk6EqhXVlZe4jM2L6kEy47kVXOwaZWcyXZwvjNeWeNsRpwMWQEH3zmSiufA
# DATA 6nuu1Q3Jg1m58JKkWnfGBfQDwnw39vutVTyU81bIX2+uWBmoKxwUyqP0fNRbK2trOr5UCO6Hk9XS2oWXknmf8arxObIt9RC9gaTj
# DATA Xp/fHBUUtNBbOe+Wqkz2u+/kXvI87+OJnCI5X+J0h1zPv//6tIPcx1K90qzm7pKVeSPc6fvd8ys33nnrl+9cubKSG0/a4eD8rRW6
# DATA TuphJbcyDIf4R32/82BNdY9KTA1GI1I9v/mNTlQdc4H2Bd4sl8TX+V0iOcQbsdNa+vk2dMFkoI5VqP7X1eAHX+OB2ueX4GAUXv9T
# DATA OTxUCMc3/E7wDtlFOzikgNsL6K9L2Mlew52Ja96rXjHr8kU+bZPZBn1F1XUPhsyqqm/yjXR/dGorWZT34CVM4pdeIhcaYcotZjda
# DATA DfvjIWnhLRl0dv7XzmOI0QW8g45LsAH4Q4GtiTFcqNWV/MoafugG/VV5kBpSK5VxDU+OggLyCTiNeHW0cmsz/1/9/K+L+fWtwrnz
# DATA /yl/55WV+Avx38iHK/crNOwyhn915Z3+PZz2sSQJP7Oyxs8oRbzBKz3WmDXdCLmFJ8sqzfzJFk7qUk2r3sseEnrVP4vrwOV6wf0W
# DATA 2bpjcSRVDWBvjtqQBpBHBc5+WFXvxNTZQn716tparE/HVNOJ329hKvLjOQ+nB0x3qqtrNO280lK9o1xdRWMajFTt9PUNXc9bxTvy
# DATA g74ROd9yEx9KXHmnTcOyoh4P+vfC0aDfU7nh9n3kznXCHbr34wdrcuVy/54cCbKbmpwEfr5DM+DOx/XqA7rZ1GJNTxqra6yXJ7rH
# DATA +mVNLZ4n6SSchpYDLvwVzroIjbBv90D0ivQw8v05HL3lSq6QnYenpRi+MEpeuF8sJi5trKicFbkWvS+7We/3x9Mh1BV5F1Y1VaPw
# DATA H5/23KKWiaTgjMFVek3OK60lG5O9WrfuWMv2zsv0JE6tHlYz3eH29KHnrJpxlxdIPQb9tjqAatbrtLeKQcYtBXI2SLzxOT+MPfYh
# DATA qHv4aYx8uVZfYvletqqRtYR/jr0lBDa8nuLxemPQuovTNfiHJh89ONpn9ykn/nKL5yNOMmDgIJSFTI9M/4IqEhlYJHsVWx5sGfi0
# DATA zN6nNokuCPsZQlLa80cMmiFD4S6Od33kX8lyNdJvgyrbD/iiBLKU6VK4GcB28Uf7bzCw4GC0z8B24f2NFXpx329NcaDcaHIIb3JV
# DATA 2/rmqANp1LaUFcNS1dyy5p3zVuyZZh7RMfMBxMlgXABD2KouJ4cr7219cP29q1f+1vuNfLt0/fLmTf3l8n+5dCXnFQeg9DBlcuvo
# DATA 506bS4teQeJpTypPyy3we/HZKNeUosQ6LHxIA7eqpswrvDSjl0zshnNHKz61DctKLNCArd6K3Yb/Vto8SyAu5Sl8ykt4Fx9Nrxei
# DATA Xt/AYS9YlwX8VSWFtBvcz6WLzufVlODStbw6j6fNN36bMafl5eRm59ujwXBjExZXVrljvUVD9ulGf0Dv2cvD8w1BJDOWUmjk8hi5
# DATA FZZoZiDXMgtELWmK4Elt8+pS9KrBd5gpWuHjZ3xRBna82Ds5BAsm01GwJSmUGzdHU3XwWn8U63OjUszJvilfX4sPpLVi1KBqIwpx
# DATA quFq/Pbl1JUuMyEB567Q5cQkW2JeyDGxiS0lxb5QFn1yPlrTj40y6XR/MvFbu3Zd76RHLeu/Zfu8tLDT1cm8uIG9fH/fbn9cytXE
# DATA MmAbGnZnf7Kqvik7+fwR+tZyMqVSqe5lOIDoJebXDlI+ugnxQNU2HZuuxoIhGvVkfEiNtYL48HjSTRvW029c/tXV969cOXTk6Eny
# DATA krKejMarpofrTQA4rCkPAJpoVU1jdoogubWHXdgc7XBU/xr/ooZObsNZvi1f/U4+QF4Z3dQmnXthTYx5z7AJn/kE3QZbTD3I/+DR
# DATA sapETGDzuY3VyJnBfQVVn5wn39jBUNbsfdBwepf5HwCxmoJ+rjT+uTde99jtHDM1qBK1dsC64L0Hpe17TN3jIXupjyhlyyP95A/J
# DATA qEkYIjc4uH8ZXtjK1QHyuKMZ2TIx9G2+3glHvaC9gjGiiba1BXNgi+y3DW9lawsjtrW1IpWW4XtGQ4kjnGLvBacR9lsu/lcuF0vV
# DATA ZPyP/q64+N9Z/Pfzn56bjkfntsP+OTIdvOH+ZHfQr7z0s5/9jIE7hK8Wmy+yMYY9Buz4YrtiMAw06a1O4LquzSiPva1ul8TCgqgg
# DATA tinqVf0NOU36864/RmxQfw2BDzaygoDHjyfKDqL5ujudhN0FwUZ/ZMcak7HHye5IiO5iwUiuzXTUpcqIUNRVomvs15HM4H0RTxzz
# DATA qXSjaMNIMSqJT/23acsuWMvkznjb+9zlpqPZCMcOySj4MFBbe2irOJRjHgfRJ0jzWiXnZRzFc0T+ZVRH36YeZXAddLR+TlSyFU5h
# DATA N4TvsEIq7BoibXOF05xW1nR5YvoPOZip/HKk4WyIfyHvmOC4ykR7OFy09j/lp0I43hrv95DFsmpZe9zMldl/nz3yZl/NHs7+Ont8
# DATA 8OnBH2Zf0OdHs++8g7+jD1/PvvUO/mH26OATuvaVd/Dp7PHsO7rlh9m3dDt++HT2zcFnB3+in/jpb/H1vAfrHva21EApLVUdOY1Y
# DATA 6MHUXpUvY2WZsZe5NbDtMd7Q3NBRjM68SEVABoH0c3vaG471b0Efu49b/rgVhmI1IBEMGnCjrF0oiZS0c+yyMuaSckN7d7Goh8b3
# DATA LETOJyl8qv1GrEUZWh0+X2uXhmwV5WPo5jqFuIGcQVQ5Phmwmb4Hn2+D/b2lnEV02lrWz53uFHAwsZ9QB+QKr+p7qO39gY7zqTtG
# DATA AbOBaeQoGVY78EL3cP/9lDQ8uUnxyhm/e6vTttzqWPcp3/r6G7Zv/cY71y9fuvne9b+NVznl68baYb8t/lymIayeZa72jGdTz0hj
# DATA sdAKPF/H3CkJP4rumPZ5yfGPaj3LBq+KEpnYNEJEChYNcaDKnKjz6mvnowjWndi3/J2Pi7l66YH1+9prtwtrr6gLdz4u5+oVOCP2
# DATA qy0p8D9n39Bq/w9a07+FPPiSFvh3tOK/92Z/5oU/+ytJgB/oxx/oRiz+hzm6Rlc+oWsPvdlj3PEZfX5sYsks+SRa1wUmyaruBFIj
# DATA Ji1xCzJfL1bErayuVH5VIoCoCr61grTN8flz5yBqVL+aArCyyXsPz9G7Vu5k93OxVkx1w/8x+xKSjoTaQ8g6kn/SPGop9QlLSGr/
# DATA Y/wG+fd77ozv0F/0dfb97HuSgI9MwBmM9ONkyDK3Egsql7xXN1QgmG9fw/fyYeOD2jzG6DzGi/H+L1DNh8tWP5LoIvoPPj/4LaS4
# DATA GTzlqFthZA6BSBiZK2oH2SYMlMP/pjxkaqf8oCZBbNvFjGFi9cSKvNU8f8cuTvfWvnjRdsA0ayiPPZBfW/61BtxJLslb/+3cnVfW
# DATA VmkxnovWXmHrf8vT1ZfXzr22oiKuqRi1FIhcuj6QlXY4oku9+/FKAd51obDyQNJwo5/4kVvlO3omUa+tHdL0ZHvPx5a2TB4+fpGP
# DATA 5o7Hz2ExH/zT7LtcJAH0aueV/5BufoiC6DaSDLMvIAOUfKDCdV9/e/BHmmE/YHpi5tL3z61eFTTBrJUsbS3dwUrW7ba7EE+GfTVR
# DATA F3fCIWuBO+RbWlo05B436itl21CND/5IRo1dYxUNUtF+wAva0k5+zRJz0qyjSbojLX0zrIubq5oCqStxuEMkMd+Nb7ypRLdgMfLE
# DATA VCOAp4yAxVymaYnrvAdBt/G/GxtpCd3RP6qbx2ml9O/SjIPPMkbt+4PPqE94GkMtfclz64+ybrP1F2unC7HfaBpThz2SjkTRqSl7
# DATA 8EdP7sBFMxPUcHO1s0abXMXVyeBu0I+P7/xdZBIXtwuLv5NUsItMWvBS888g2allm9feyUeLcYkJoVq0urJ57drWtfeu39yoFEvF
# DATA 2/3rl9+9uvnB5q8ub13bvHr5ytb7169sKC4ZNob3/HvB+QrAF/orsVW4Ej1Jldm6+d4vL1/lHQNuhFje71y9efn61c0rW3/zwc2t
# DATA G5cvXb98k29RTmiBb93aDe6vVmCsx8u/3b95/f0bN7euXX/vv/ztRul2/93N6//19c2rW1cuv7V56W+3rrxz9Zdbl69uvn7l8hsb
# DATA DPjKuyUyWnA3k1ZY1ghxwFyFceHOKHxZbaCx8kbcTlkV9K1eq1VqqSH6N5GdkbCRqXnwB5lhNIOpLPwoz8cHJXqBrr1k5XJMbZlW
# DATA KIvwlplMMBbLC6xBmlFQiFRlGAnf0MT5nur9CDLnu4PPlTGofnmoAx4Zhp+qr7XPthptk5+PmxofP0jvWJubF+3T82jcuhOzz7H/
# DATA nL33zPvILYMRt2g3OareLXrqDiPK8XNzRb7OLd1SO16r1gbXMAhGY/Jx7gWjUUgu/MpKFMAQKEeOV+jt0wHSe8OWZPcziIRJXNUy
# DATA 1NsOkMUroQs2UhCT3Uj2GjJP0z13Vd7zLrayjEEqBUAj0zMrcY9H1ZtDXObLT9P3pjTXVyxkSS/RzCGZ80im/D/N/oUlKy5B1kIU
# DATA f4nIAy0FMkBQaF7fffCnmKiOqWMeBKkDX1X9N073g2rxjWCCfexxRmeMZS6pmagWky4wrZc9Nhq/Z7vma1QO1kNCqXyvGoR/6Lva
# DATA jIeZiXVEC57sC1JweIiKg7ZChz2KhiS731Vuxfy6LdPzShV8Q3X5k+gNVYlUs0QDJwdAmeK6EmuYOaWUo9ZHgCsE9K25keRYyok3
# DATA k3rDhAFXs+XGrZU3Nm9uvr554zK00cqdtYJ+1t4ZWf1lsM8hupyXChkm3me2ONWI658yFS2NFabptzxyEN0sDB+JAQIbDRcjW1oG
# DATA lCxLEp1febGKR7aVqof+aNxl43iwF2kJSMgSjD/LlNgyxRWT/MQjklgFfFkVIVdwGiawV8N1yemg+8IxdwiCcYnUAtn4iXaG9Y4v
# DATA truC+e+6Ss2zli/aIgElsqZ5ex2tWrXuX37NrhVCgdNM7XJy985dMXObxDt43ZAxeKj3+aMeGjkFhStcYV17qdmmPKQV01oiasmP
# DATA SdTyQdbLsMOIUNxqsts4sWplrdAVFxv+n65PXGmpzQCpt2Q9WPVjrH5dlNUcus6NWXnn2qYUAEf0re5g2+++c+1eXV9M1JoaZ+Yw
# DATA Pa57TFn35rKuUrrj1QwHXrg6VauCjGAGWFvj7tDTy44jswODWwrTPhndqy/rgiSgj0QrqDS1fjg+zLfbskuVxIGE+cGgaBVnKysW
# DATA kp9KYIz8hG84Rv44Uz3wD6IFLmg76gsWsX9k986WEJ7EJx5ZUTVLIcSWve6RLCWheuD4GhoVpK74J9iv87TDHOlm6QFdLVvSqmof
# DATA W9DGK0v3yQ2m2x7BF7QUV8Gb/Yto3i+46r/nH75Wbf1KjerXPBLsv1yCh2HadfXyzQ/eu/7LhL2U1cWaM2Og2qu+jznDcVXdvoYE
# DATA VjEcW2JCb9kaL2HYK6N4zOoq9abIZknvj+BY1FrqCTHQ5z7ESarnX0ql7nz8ICa9TVQww9ROp5by3SL60nJAjf0/e+yHi3v6yOym
# DATA 2vmXsZCN8aLYkvqEfd7H3i8v/+3GrzavvH9Zx0noQiJdhj0BQ0JtOwUSr8RBdia5hWOQmfFDJSxoRmbNv+c9tS/Z2PpBohKfsqNu
# DATA OVcqNivRHDheX68s4ZRwvqlujYi7WO5W3F+JarqwgxNuKn3835Xbx9FS6VprvPhqogH09O+M463T2qlm9j6pPtgQ7Z++tDA5OZZC
# DATA rZzveH655cnCyEU3fsUi7h90jCglx0Qeo00/SNOpUZ9neLXRssVO2dZ41y/X6nZr2uEOjhRu6G36grplLUp1tbaBeSdsZbSdvbWH
# DATA RdbanfbvYpGxGd31e9tt/7ze0WNCBCv5fy3nba8k4+lSo4IcFF7l8mLtUr/vBvflk9mrkeOgW2gIqdQofVY574PBJJ1aq3bNusIY
# DATA IiJvKHYrx2yRWYyWYPuXdfQQO9R4gL5Cgw2jncQbb29Sz914/90bkdRFlHEY29Re4piGRNCk5LWoMlzNpQIgPGmiPXHePeGJ/oWs
# DATA UZlQtBCMspatWDT3nN0OHEmQRN7Y9Fl7ZcXzVl6RGr7CWfeJWuoxuceQAFsyNFG/50SL9LG3vSJH1A4fJs7S1oaU8S9Ggz02BVN1
# DATA t5MW1iRswtnIttU9d6uExsHPdzgBdc3zVhOjs4YcusHe/I0SvQ3AZjyqnWnRzB05LaR+sGwYVhcqbHzwO2iQz0hqfWeJW2ZG3OAe
# DATA PJe1D8G7wFlTUf+gpjVdTQkLTHC9z5HZln9N1lJZaFJLBPoXzcJ54RWrddyNbGDrtmmpoJCnSN9HKdsFOQxdQJaFStWdBMmLOt96
# DATA bK4o2yZ2o7FWzJTlsJPMWtvqkHpwFVd0AIwzPPQmazdWCCcfIKSVXNHv9+/2cWTeYK+qJ1YSJ3xUu1/dSE4xa3pxqF0PRnwEcEmP
# DATA gOjyZNCEO01rOllf6X5cy+4ebpk6KI9H2De0mjK/+VcZcwQ/qQpIP6zEh1vrhxXN0J4HgcNoNRSBGbL0BmQCH2rhgm7p4WWYt5U7
# DATA a2vZRVrNTcyQtchfy3ySVYEOFKAGt+xzG6rbMM86IdVsxHm0qug7cgQTb2Wxr9M1ohNsqkqqDapasZEwz8yblQuetURiP+yISWB1
# DATA xDJPJnsDMY5bispjRTbimBuGnRB5yS1h/pDWy/3chqC9cicmXfUDMo8wOTgUdH0gJH5JGyLebD5My1MgP1IPJObucgvq/1EKVYnk
# DATA vyPJ9RcyislVPvj7SIpJqJKEOfvKZJ2ROwrTNCXHWQYaCSmmc9zFGsa0YHwLREl7VpTxk1y2SPe3x4MuSM2sDlJPmnLP4cJLSykJ
# DATA ssgH3XtM1zPeGgVdfxLeC7YmA/uwEgyB2L28pZo+7xQz6fPGWllgz/9BGcRRvp8Y8V9gh5V7lgMZ2L1nZ3z2F+gd8Voecn9/YW0j
# DATA 6sbqRcPCKq0OD68wq67PqWzy1tnH/xTidH6F42Z6vK9eUjOgH0wnIx9oDjITdESC7FoD6AIoH/R/tDcDSL+dPs7ZCplR198PRmMP
# DATA dKqe35kATHzQZxZXTgu9oBBT5CS4QJ6YF5mdmqwEm0i+aY2pnyvs+72urUqjH+S6nM3Iz31u7u/08530JI7gbc55Jq6eXAhzhzgj
# DATA 1TQzvqreFl+X1kBEbqA1sziWyCN0SOmpDEE1+nwegyqaOENN8qkZP0TN7Yr8USy4j1c0hNHKee/jB1EkRO85vHdj0ZZDvBacjJrs
# DATA WfXzXMv2IVu0j3l1wqo1ueY65sfWBpbJ71SiyHcIM3xhNnnUBsUXc+St7LSJ+/4lx9wkbMmy+FEsEBHPhIkGK2tfVCEH6ZWX8iOV
# DATA VZbtoljKU+5bpDlfinkOSr9lqXCupPdzT0HLCjiSQvsJ+3lOdjXdqwC2yJ+/J0hGg27bQCfxdHopqVMPy7nOdFJg1HPY4e8QUD74
# DATA ra5APuVbyhF4bU/ot6qM6Wj9qh7lm3TnZZibt1ZMn2M/LZKcqlXytthdsDVhG0Yvi2dFREf/jT3C+RGVyvK9EVM78/tChxosWapt
# DATA okQNolebpPm54kcsJ1y2zaYoSBgLrqUtrfNLHBHU09iY25xvwlgSMTNvfrD0kESNuV1mspQ1HLRZW/E3Jxuh78+0Zuwfs91efQd7
# DATA KvIm+SXZX0dxgtONXMLzjY+lqTlHN5gEiXQDg2kHq/pMhnWashsd+FdbSCZ8rMcOoX+4Q/Zu08eswTrKmMt5W0A00OGdB9wpuG1O
# DATA TOpfqMV/5q0P2TR6qNNUvbT59EU6GqVZOeOT1yzuJZwAPnopu7R6uuAU/VxPwF4d0bOZUyf+c/bkie7hntJLO13lzGDKtaj5lhus
# DATA KywnFvXRHn4kELRrwbKe9uyYkN2TLFqtqsU34/WNh4nO5Wuscn6AMuhTz+2SqRmVY1dyFPZ8zqGeb2BZ1VO3JzxEXYjaSVw8f4/R
# DATA 6wAY9PveVAVntLploRvPEtAC3a6zEOgkhzt+HEoWo1yzGzf/gBSmXfygkvon8r1+GrORs2PPt63DQtYKMafwK5x/F3+RxKaj9+so
# DATA +NX33ri8dePm5s3L5jzMO5dv8IpVQpQxeqBhVWWidnGQfZ5wPWR4hDwpzse7EkWJU5JPb4fyfIjtT5s9quT2pXUsTB2X6YVjIEbH
# DATA D4FJqG+cvcGonjcOSUJuqLNK6MjEfoyqlUZmMYfv7H2QdNdJWD+z8RvcA/+rVxw0Go3IIza9bJ/Svh4IlIOC7w3uhYPp2Hvn3c23
# DATA Lue86VjYCZAPuBdYnM39iYr90WIZApLSKlHg5ryPpoOJ731IUwKKnQdyjw9njwLq2mnAR8BDhg4ChVZbebF8LGM6jM58q7OHIgJy
# DATA iZXH6YR34mtU+2fxO+3oYLwz2ZNe3gPUipSfosFUNZs3QHxfLuWzmRzart/fEnRHxJW3lDW/Kk3LSS/j4H1rN2QudiuVUwF/KIHQ
# DATA 3sCU1oED9cUKUW5JkfyDHVYQ7yEifNAZVOacKi1DzAJL1OyFAEvjMd3zR+0onoC93/khYQmr82ET1ZxF96UMj3/mFAw74POt7I7K
# DATA SbGHepPXYyvtETmfn0lmTCJKxHkiUXj8T3NyChM7vqqzNRxVDMctC66N5LAwLkMIj38DbKrf3P5fMvDZ7Oz5WHKJhBZRr8ezr2QX
# DATA G0Eosqh5I+mzjK5QDgscbz5BktW0e1gWgz6TrpuhUhfntl79Hm9/Vpb6K6uvnb9dkI9rH5dycthPnl6m0Tr9U5KRPuXti+ymyjZT
# DATA un16bm1FDY1Pt1RbU0+ofMO4ikh3SvK5Y/ZOspi1ZTcUZZvH7ql40m+G9a0ARDhpTTbwVcaMRzKXrN1VZDSQHz9cZWSuWFp6gVQS
# DATA zkHdKt7xXvaqa7fOVxNmGgpO9QrWhPyysH3/rrIi4GY/5CmshludNzItQ9zoS4kmqYYj92PRDuQFidtDUvyHkRg0pX4niymWhfyl
# DATA Cuw/lvPnEvHVMysCZB7Hl4/9i7qZVOBW4oH4NMx4RlPdJG9V1zftJ3KpN0S7Scl5at1k5awwAYBdQyXJYmUqgCD6LZ7a2d9PvkUl
# DATA Sy5YAdGh4PieOzDwonwIk6oZq0bi/bzxR10Tu8l4rslHkws32XNRpxyhkXZdU0ORLCoJUSkDag3G8u9Sz5q0I3SDvmZ6wLop3SQr
# DATA Dzk1S7PedIS8lFh2g5zV/nuOIX4qZzMT8im1gfPInCdMSi4hOEB9mSUjtvxw5YaYV8ALji+e2I+y960sMUlaI5tIbjQGGmd3R5HU
# DATA sK97K7la7N9MoXTd1HJOL6f6839Q/0gXmOzXb/lg4Z9TJzl+YJH0Gf/929kXysY5al8Oh5xVcUsYR1Ru+sZGVHNO3EvteasZETvJ
# DATA jvknBUbTT303E9uacXNnm3om1Tf/NzXpz3y48uHBnw7+UQlv3T/6SENm1O2vcq6FClBWA1Knf8sz9jMq6VHajPrGnHlRqCwbc06N
# DATA qRT7a9fUgUEL4VUZCpWyjj9LURx2rhbX67pXWrsyb/g9kl8n+263Gd7sNmetMKbpnXSv/HOsxXMmRWY0+zFrPk5G5AtWG+bF7VWK
# DATA xYLgvIl9z3WiVHZk7FxdZurGnUxYAglGcuS+bEs+lZJ2SMzyv1undJMmtu6X79U8+yQVx0yJLh3KNLEtDc+v2i7XY83niuVS3tE4
# DATA uIwk32sM6bi2Znb/2T6DKYak6QKQiu4G++PVWy+rctQr7tiPFIL7E4SCl9tf1rl8dvg9sXthHGmUfj6Vbrb05voSiiMdOs4+aGdq
# DATA quPeH8vWCKehyu4fMsIkmH8+I9ctVXmToaxFPvjWuSNi+88rBZIDK1HfaL4kOXaTdLIxQ+XTWpZuMalG8fzaaF3I3fKohgoVIOh4
# DATA r+p8ZbHT+XYJWi7IwJcWR2n3SyEwH2XnhwfUIN7O3eNlrJbMQV6QAmMqy6Nk7/raCS5RZow0NjaSUTTHztTKnvnx1ScvXTvdlRCt
# DATA ALKhcKglygGf11+xjLPTWhckP1QqJgDgCu0gGOKDClRZmYKRQQXNvpLTUl6dFkd0+KcbqYvzUnHm5Ad8rpPkv+dtNSh3RqbwcFaK
# DATA +uwvSMbh46LREfGDz7RqtzESLGMwIwkm22rTi39D98qtaIHf4bZHoBXZS0vdnjoUEz+AYpsq35ltiXnaPmZuz5srQacTcICQKr+q
# DATA I4eHiatlWmQKXtSm+fEefPlat4ftPJPDOnf0I9/i4bzmMnI0xtZUTxoo12PnrNNHkOSm1BmkWLlo62rG6f24QFe3JxABYt0pt0jt
# DATA wkG0a1NQY4FNzUCO0q7YEzgPPsCV7MOmGxvsoswV3kdwOzhE8p2cSMFki047qZNq6shNFqiHheWbXndaYMXnV2Yu1Sig+R/CAMXk
# DATA TYyoorDQJ0rVYPwnHoxbxTuFkUEr4iv5ksEvOq/vsYfj/2fv3Zvbuq480fmbn+LYTuYANAA+RMsKFNhNSbTNjiRySCrpNMVGgQRI
# DATA IgIBBAeQxDCYsp3u6UwllVR3dd2a6qqe3Nx76/7tOHHiOLH7K0hf4X6Su9dj77324xyAlOxkpuN0iziv/d5rr+dviboQDUldjU9G
# DATA hOatf3+fMcnbXbyt5hQQ+QGYW/EoT9FRrtVu4x3FkHWOu4/SqHXy2S9ydy5s9h+r1Q+M6T9irJaan88oClRrqBLaQZ/CRsEtggFo
# DATA 8B6Cab2PHpQ/kzLTj8TE8Dzs8wBCJBf+8l+oDQfDUno46fYgmwUaEYTNZ++0mzEJAZwQMCEMEK4OXJwQod+4eMDj0XDQIxM3nJia
# DATA VxDljSApaacP64PQgdkGBeD+fdUiwM3sQfCOKrCP2QdM/BhgBqsDsRb2UOLsQz8vFhdjAY8+92WzQMAZKsSlOgtvBpQwBf1++rWv
# DATA 6dhks0TlKROjuvL8MNoOaJQwS8kmhgWjJH8QazPn41DvEsyVLIedTOkzN24WFeN0Ugh1OLEFunWx7xbcgHrBJ4eNDkPlNeXKPXqj
# DATA hCF/oArmMjwjnJf/zE4IM3e5Y25MjiOkjvrNzfu7e+v3b2809767vQHTCtRM7RAkZISiOyDE+6PTTnvS64zSqa81pP9Kh4NBb8bS
# DATA YypMnLAznpo+NxpJXhGGBpVzGiBGXo0H60ahJnUlNiHtQqpLL/yyc9jyOIEe4SUeu4bJsbG1H5EB73eIU/eJYks/5fBgx3uq+PAl
# DATA FFvcFq8n6c3QNhJqXZ3gUTKTGWfaj/PNqMZ/3ViDXRetkB7URfoZ5Ckj1MVbwz1zZDuL2OrPBH8JXzjaMrgxt6psNuP5RYzx/CSO
# DATA SYNm5s84Rn8Gc11AumeR/xmEnESxo16LZDGnxkLSoEbUfCcJOiZr5QexPfQKAuHE2ZbiMfrYkVg0mKGIoght89a0+2uYmwhwxU29
# DATA wP/IUjEaBz/XXA9Y/giY75Ir3lv1F+4w1hOkN7HDf+oGUrjCMUq5EsvUxE8BoWtoB47QvNcgbXglkbrRxj4K86T6Kx+Yh1aF2JAv
# DATA iPRPEb5b+CAjvB1AogeGR/nlHrz2QL3FvEHui9tE6AnpxOo7c8ryt3zOF9uGu/fkTtv6meZ3jPq9Ma2a32vT6pq5uKYe3PhG6/DA
# DATA uaN/r5CfnKksTmYI1aMQ5jMMjPgoudz58AmS/4/IMeIfAQ9FuwJY+PSfBhES+zkTAIyw7ZYMnbgwnhL1ZAWid4z6v+77jSIvQZ6b
# DATA rHHiNeimWzEBneAEZX6rj0mzhoopq8qiNE3g4FXXehYd7avuUK+gWbxr4S3+WXHP6l3reRXdClPtizVTi4+acA2layBR8DII6si1
# DATA hAggXhQ0Y7740m2T0B9vTPfox/Xp37KD/kMd24zNAiHXAwA3GXFCfXYknFWHZfkB037UVzzYK+cufEvxr0H1NqY1gFW2Dfcgkdwj
# DATA 3QE7+gJOFKPPQEewmCGnrs4DJTv/Co8HfXzgvmL9q8WkrlZlgE8IJZQ7w7b54CsjExxlEYW0O/BBAGFmcT4ec66PmMMgOBLaJQlX
# DATA nrcTApNgBKd5lvmQa3N64uVGyvw7OO+AlS33yI1rsUOTIzRyVjhQSbxJXTnI+yTwlXaNDWZEjgKASlZie7W4yuzchxEA1nkG6AsK
# DATA oEGnLmaWPpOa7QKztXRS31+khlmqq3iGRdtZprpoVwrDL4XfehB9ZFKg5hsSbPxEiAEEO4KLmBGA42IDaX8GzzJCng7sIslmfrL9
# DATA w6DqM/jXnDfgYzqHCyaA/cU+htctkXCCEBGi3gR0n3XHeVuSzR9NF2SoeBdfdUvME2uBZXhRFtrgHAlcCxZQfe642fjSIUt1EK0Z
# DATA BnlQo4SlH29YSz9dzk+aZpn3PzbUi6DmcleHg6pj3dJxoFyH9Nk29Fz/cZlwJ3Qdt2/YxeWRKBNtrmNeabE5/A+yfbxKJaY3uoVT
# DATA 5OlA617PWn3FgbcTUHuI5G3stE+VgOsiZBSHv9qNXLqGxzj3OT0GL4VMrlcNXykGAjKoX8aJTTDadOsyGOZf4c5ljbsGLGOm27XF
# DATA 2gNKr84cW6sgouR6/jF62RKGGnkaF5DM4lGjXWXkEyggdMYTjEmMew8SYUuXO9/NzDuSHWfbA4fx1aVcwjsdgJLRwZ5xIUCI8zV4
# DATA s9dJrBExGzNNm6Mjgs8OviQDRwQwX9Ed3EvTGOXTDgAaE74DxXeaEMjVJPKkA7lKHOwCxOpSofcu0hj9cWDG+hY+HOowG0LX5+Kn
# DATA 8Gbwo/aI56bWUAA+F2NjTPMgksItT+/M4mD1W5bvPrDgSZpXnz9oM4imMyF0OCqRmE0fgMpHCLJdn4USJEAHvswGB0Gmc5DOAJFI
# DATA SVQuZ+LS0aDTke4Wbk89rdL1+CCPuQoX4nyho/9Rw0bz1wyFjbJyu4XrodcBS/HgSR/yLPZbw+x0MA6N3xLzOX086E3O9HFj3anG
# DATA 50NQMaWH3X4bzWXU6LpMLwiGfpqneuJ2jZm2K4WuE721nwJHeCVdXOJ62tZd8mMccPE9XJN1b4lKjRz9mLpkIxoG74mJfpA6dW8e
# DATA QmN3cllQaYMm+qKacr8hMVxBuiqLI0tjktKVJxRqoBnJphtdkH8Smjg5COnsdVCPaY5TvsMZp+c4M2NH2NJLP8Bgp9lvzY6FjSyL
# DATA 1E20byoJ4NRBJbocCEsu8ldLO7fF13bUt5ztlORc/iX4jqeemH0pH3lqXBBxEZWGTVRXr1fylDCBLDoT/AyUKIGn4fOfgb+RTvll
# DATA kUDoiYiVs8cyL7Y8n3dP/K9fCjlCCjwIwfllatMxVh6c6Ql6SfszEfQ4EfVJps6Zw/Ok0xr1upgbg7P+ZhX83Wm1RXEDjMkfKraz
# DATA NeY4++4Is8yrr84gQkeRzPbgiYsKUgud4V3t/tKfUre/NEOzb9r8Z6nYn2PNmQ6wat9OgqfZX4rp9V3wCBlAwop+dzfUtBunW1Y9
# DATA Ao7iOqHHlGn1wMHeKuLkRmLL0aCvBOaej8MXWxqOXld/6LbHlpffIpr+sPyECDBiLYF7hhf4RqoFgUinvQcMUQavAXabtOkLhevr
# DATA Fw6i9s/p3uVWhenfleNxmKBHxBGXYYjA9woNc4Ebvj4QXdNFcBfOkDDeS74qb9uXbQGxUr9K934+3uEQ1AQwP8zT1cJQV1xlUTT2
# DATA jpbOFyJyKT/IpcBd3/XT+sTtgM/74UYqXQl4IUfKe5z/Jdc5X+xvCEQwa1RSP4NOLNjNqJgWcXPoYLcrATEWgDB6pjmtDS2gOje9
# DATA LJ3q7u+1I9IXxCZ5iAR4y0KOOOiJvuml3+48rRhmrdNX0uioZaB+ZsYfxWBF30puLAKY6GJemuIg/s5PSPwr6qu64eYBQV0G+EtF
# DATA wo00CGHdbaV6wrh+9STEHmSobxgEeBPx6+rJ8uD68vI0t+Ne+INqk5YKEQ7JGxKJjlRJSCxtBJbMcsQgEwUnrGic33zMPuk6gFOu
# DATA D14oSUqfepnOlvGPWYbnAqdFMqlkFpv66LCRvXR0iJQKCESlONKGgzmYQ5bqEpQSNWFPq5bd5pdIHZ0afhgbzjKu0H7WYxpRCK0w
# DATA jkj8axpm7stRS1t2e8OEPmWcxy0BWpMATvK5FhwJ1qk1AkMCJp8gWCwsVJQFo19LNhCJGc5z9VmG6FmoUuu1GRtoCJEPWAkf+mga
# DATA G9fieFUhSzTLTCj3QpxVZCiilyIU+QKRz05q6LRy8EaImTa/odOwOy9N0RM3nwpfTcZR3sA/arU5+accBGG5w+LFuvtOEIJWl3GX
# DATA 0dvNi8YSnIX090alA/mDu93ivK/dDAVUme/VbCShaWJwMM2QwmKWsGAmdGFm3tu7YZAEs3yIL2Rd61VVNeLsa3p5at7Q16fP+Cxz
# DATA oDwMTaJKmc3hd4Ij/l/DVEufU4o3x5zHPjc8/mjadLCJPH8STpk3g6X9mVGMiKTJfMEnwGD0iNB/XH2eH6aQP5Y1LgKUcDYULqq0
# DATA 4zcdjZ1pALcAMjvGjaIifRjlqqf4tE9z0ZJzOaZq1R5zOVAScOPAZCHhGyRtl+YcFzoMmnRm+jGCFb9i2FolPRhLyVAMoZ+yCamv
# DATA o1Wk2wLRhzwAyr4urjjrkzPEiHHioHZ8kggt3ewhjmg7KEAhjm0yX1Ic7m9O3IHeiuaxhBmJq320ribsrJ+N0pZ1M+DPJUYMiCfv
# DATA 437+ifBAYCQ9T2GJ6kOnxVRDEzP2RbIuRyv+hLTBkCTkJzrrsizHEd4vMObqrMX+1ZINElQ74AN5ZZKhh2hoXZMVz9/as/cweIhj
# DATA l6wnJhbdplgi+w793of8uQdewY6IXFdbhso4QK5/PGoJl+v9g2lBGqG6e8aD8N3dHozIf2GofthINrQjbm/tINbOqvovLTvOslgA
# DATA n4SqCf1M7bMzA6QZPxI5AsM8zBognzheUhSqYVLZ5UR6SHbzhc5PRre61CkofGg4zMTVdHjpxGOwVZeEpMpFoWJilHpCB7HDJsQy
# DATA FjMYg9hjsRhi8DCJcOlovpEszx64ukv8yvFoSYw1Yw0Sr5BpfoRrYVxrKUZOKU4yWG5wO2CXSwXxqeWrRjB6tDgSDR62LvZFUXi4
# DATA P7FXDvmPBpR+SQH/JnTfBPPjj6oitE/PvcsqeUeOZKS/wAkIMQMsVAChB0xfHL/hi3gu0TB5EalMPwNFnbHk/dOzf6kkHKwa1Uw6
# DATA cXJfQgw2rFHMbwj6OwM3kmBm33ggsxW51HFo8Ztj+6uEpc8Z+GyUwRcpbqUnrcedqvO+vS2+FLKq+t7QOwyZdqlgcWy0++5CzorQ
# DATA 3DrFMNsa61fYczMBIC6xywtSBRYvaBtRUMCSOvqG0WCs+B3KDQkJkHURlI5YJJLfl4wcyhH8gD+Y5pe9L3gOJIUgcwNPwp/m8yXl
# DATA mJomxP+J7IkomMBMT8/9WK5osFC+jngCr4s+5bx5EK1QRrhFSgetlZkIlMjIGu6k5I43+uASHdSWNJg43SFykOB5rlh/CdMefQjr
# DATA GWeGRxUc00+hIZW/vOTYXywuqluVZHHRlDANU1BVnO3oRByqr0uqrcMeQr2fqpOCOAv41YT15nKkmWVG9btgpR3AzirpO9oOmWVP
# DATA KEETRStnNYr1PO08LV1bLduk18hexeKbvS/UEt/e2t17d2djt7m9vrv7na2dO6jgp4oq3tDZlx/sbuyAwl8eiubhnVvuI78ULxj7
# DATA WByn9aUlfVG/0M2Y/pUl0u3D+htr11aX8kt/Z2fr/l5z4/6d5p2te+ub4O6cno7Hw0yVDUvNzki6vX5/4659zTzxi9x9cKu5/eDW
# DATA 3c3b9mWHkZqMelnJmVU787C19m/UQZh67zubd1TL1m/d3VCt23hn/cFdmBrFZUw6YUfubeztbN62Y91qn3XR3UM/gBmLzizk6/ZL
# DATA +87Grfe2tr7FC6L53sb6HSw2ui5YIa82KsQT82I2nLK7RWnBhUzysDUed0Yg/YzSv4OBH3VqCOfTgZ0P0OOjtFFb/Frq8m0aZ58/
# DATA r2ArwIJZu+eRUW4efDI5tO8zEHqzngQERhd23GudZA0ssiARCJb/egMBKVQJIbl6HR9J4gCf6LyQ4DEPtIAGuJL0J2eHHe0jRxda
# DATA KOZHbjQEAslquAwfWxauX00fjh72ASfj1Ut53iHAg9Fr3ARHG4bVZd2nPWEZjVdCWAGwFfwgU6K2/DquXq1zcGRQnQNrQw1+g/Eq
# DATA 61xfqx1eX2Njmh4WHT9HeVkch+gIijaXjSfto7IbbsTP9h8xw8C+Uq3bndF4u3MGO+d7T8bbk0NFt7/F0F6qJeIxXKoncOUjj6CC
# DATA X2RgLDm2hZJ9UEn2zodBlkaaFTmwMnkqgr1orPqPKJki54PWkbgfQegNQGx8gHb5DzGd36esnsWQt0/jCSJ4ZR6/ahibxgWtt+nD
# DATA vm1QI71gBAy1pl/VaxiEIgZBtWfRfIeVrjdNUXOhFvvFBYNXgaN3Mul3n9aXHrdGS73u4ZKRc5dGk/4S1lvLBuAFnvUSlMqacBwP
# DATA jga9m0ZJ0hmh3j250DVP+VnWax6pWe0ewwHdSSK1jHvZEljRjk5Vy2vDzln0yybs+Zyvh6PuY/XY/Va3MUv27u4+Xqmt8t9r9Aoc
# DATA Q6vJoO90AQlvlgyOj2+yekSt5aVJNlrKTlujDg3G0un4jHvemowHaFC3n3RgtTUxmG9teS1ZUv/UxAfttqLrrbaagr+p3qbMQlVY
# DATA pNUtOqvU7sn63WO14XpPWudZ8NUOwLeNOqPq9kBtnXPYdN2jMRv5q09OO/3q0WiQZXzHKaY3IB4p+bv/miw9hQEAQ9qSXgwoLfS6
# DATA gLV71nraPBy0z8nHYfmmeX4yGh41yZzdPetAEptry8uZ9zxTHGXRc+Al8JfiAoqWHjYRlx4VwPlYTTdULx4+rJXefuVJp9erYoax
# DATA pbLqTdLu9M/BS+lm8Al0FigkGSySr01GXfxnKWmoicL31f+pfcK77lixNaelmKWvYhTDWtWpV75iIvUJ00hV95fTCm2bhlF94IFE
# DATA WxXf9pnQHEWpdxvOK6hhBWtAhrffGTeRNyF3dq7J3kXCbrEM3G/In9BImUUJg9AdFLyy7yuStX7n3uZ9D1zxNwQQDwZAIqsfSq/T
# DATA 3yCai/D1iiEXGCtd4IYfxHjmGf7yj/be4OSETIIXaVuRD9TMp3BIVhkSOh0MtRL+IlUbogp7AV66towHFNzCV9WtN1JeaBCdgIlx
# DATA QMeBCbfg8aSvFltWzcYDgB6Cj7l69ZB/BTwiayGhckf3aBw9WDXWljaNaVDMpNc9646pnP6A23uRZoNjaNnK8tqNN968rhqkyFvb
# DATA 3phOp/OZqpTkpYH4qOu8GzQAkwagJG8CO6Ua9rt8UImJhDBdWWP/OF1ZfbO2rP63UtcHZR13VPwzDjBq7LMasAq0ozMm+gIUxWoH
# DATA yb1AySFqlpdUL5b4Rk7J7Q7oeLLmoN+Q2qv2IY6mOpXbKL7DZLM0CwS7Nz49T6eOYou0krM/mkabQY8xzke1Y6xWGJiB0tv37lR3
# DATA 39u4i1hvR4DkVj3OdvGIUyQWiF8PiBMM3coSlYHOPwgYqsYEWrCyjIIjk21c1Bnp5NQJg+am64QRNFKSc2fUHbRpL2RSQxfSlEBv
# DATA BlzgUD0jfKT91BAQkYtWwIVFlpYRUesrN2pr6ZUXGekeTs/wkGukb6ysnh2mTmI3NcZ7fwvdfLB3G+bRri/dQnt0CTV0QXXzTODw
# DATA pNnN4Iw9T6oPkq997cKR9KdJte3cvHNrGkzmtVlzubo8lZ5zak3mjDXtGN449W9UW71htw/kcd69ljcYUI86b8T3yIJBM6vVTG0V
# DATA xC3EK1KwAmACCQZ0V9Hfs86ZmufqEFkhetZR2wg3Fb4D3AW1C669pvEfZDD819UKRyL/5ptv0iOgSPBrObdD+VNr7RJVxV9hedkc
# DATA 7QGs3RecWWG+FGRLvaWG1CFLSMgEyFdIsPCv4ycasij1fFBqYnbyFTP5X8LI6xM8eBAoySOfNjQbAAr94DHYI24sV5K1tWvTXHPQ
# DATA L1B6/7AYf05KkRKXEWRIi8uI8Dnva0HR4Zk+Td7b29veTaNWhGxfmkcCa+NBfP+GcxSuXuI0GgRpoL7d17wHrr1cu2c9ZvSMHFsF
# DATA 1Fl+ryk1cHPH5IDoPI/tuxibEMwwcAwr0W0bP9SvdjgX73401sC+D1WLzKcdd8CF9FU+sm1/oO1LSAD6rR6f3a+Wa+NTSEXWeIvN
# DATA Z+CuPS6NaoNHby/XV8rl2hF6pJbK3hvqUR79cqjMG7OozMpqhBlYdZkBPiGA9sAWB8dTL3bOAAxaAmmptWHIXOd0EKTIGRdlqXrO
# DATA XqGnObuCntZX7WnmHvrvbt3ZuPXgXejT2aQ37oKYPD4aNpaBCeBFl95Yrt8AwStVlKOu/l/8XJq0h0VcQJxpDbbHbWgleZaBfrO+
# DATA pNbIEjZ9yTyqjwYGDr8K41lfgn/tPdIY1ZfCjL6icu0AfCEKQk9hrxjfe9i47FxQLJT1lkqkx7H+CdPMGAB1XbWdXXRvQt8UM3uR
# DATA CSdj2L5lFtmtR2zgSDyg8xLuxrlFGMXKgkEYYxsaKRxYV2c5mfVtOGwvqZmlmK77WClYHIpv0Msiqj3B9DDeN0rWzJyPBidL2WQI
# DATA s4MW+FiTQ6INzmBLMA6a8Yo1gyleztdHg1HHuHbEPod5dN86iHM1aPSGOYytowPXpdLoXFyiwSpT8bwcCi163R5oc3/QM9BVZvlT
# DATA Mu5lsFfzznYEqiCHmDyihU/rK7XVG5ZuxRbnwuWoDCl4YX9LMkOaTrhbay8xgge+hASnmLJdcWguW+rsHXDJAp88eaILjKl8oY0e
# DATA +RQkS07gVenj9GU4sVo12Ww31sCPNVwekahk4NI8T1fMIeoV7XuyomNixI2VBpG5pDu4AdVdsR39glHFYF40xo8cZRUR05Sdk56e
# DATA 01g8PQ+bS+6xdRYXQAMI6DaipRhKaVDN5lSRsfet5EsfjIC79j0ACw3XlxK8ZEzPRQj2XU9ADexBOXPfA/a5aBPlAF/TOgTQ6xr8
# DATA s1Yql6flsIV+OLCmrIVyTjnm/yH9k2Ey1L51/OQo9K1CkIoVsAwMnviqctaKD3ptoKpPPH8pRqepuFkYoLiyNMVzSlrHOxVFeuCU
# DATA syfdseLJ0RUEVuNff2ev6fhqpIgRd2eTfqGDgnQxgN/acwASgdgqL4KEDwQHpa8CN4xKzI8Cblp/LnXluF+5ToKhW6XqNjmIvdKA
# DATA 8SOrcOc8P7/h/zC4sp8++wM7UCJYO8YRAFR7xF/y+c8pRgtKJqfuwaQvc64fqcU3gCRGpf3SGTmBgXkNvL/4cpeAo+yNO0pY6/Zx
# DATA FYq7O99JOSYFEcXYPfoeVsfAvjYdObUCF07TtIh+2KXD12LVgBeekqXBAVejX8HOQWvHIKvxWuP2AHjg7Qe7e82drS2cEVRdmxNP
# DATA tVYgkS1RyIEqHLqUopbJBiXqR5WElr7ANsD2iOTK3BuyDNFTcHE3/bTTa++BxmDwuFPiD6j412y2qfHpqNOxCC5VgMJCGDE8+LjG
# DATA s9Z5ctgB02enXUs2MJJUu3BygfgmIEQMW4fdXnd8TsJZRXtnoHMkMUiKVKD+CegbxrONB0wpupkGfrFRYjRHL+oQHw0d00OtK+Ms
# DATA XT6hKYyTgTUJXcfsRnAk2aEvB/vSvClmUxcAjoZg5cO1Z+9eO9BQb3BORFxKfQ9lWdX+6oFeP3F4ujnLI3w3bfujolc89mvUgVxn
# DATA CEpFr9sdUNPPmuMBbSgd3CNDzuAw9T/sZs25vg3Bt43fFLcK5hZTxvMNdPPM0Bl5FR9eCRrQLU1NYZnLcm6vHEA18RnY1xN1EM5F
# DATA uIvxyqxbsYqI0Ad0IEbeKXMGGYExLUeEsEewW5WYTNv3HuvPgEm5pRYrhJjD9e3WcL3d5l93RoMhvjTqPlbsLJhGD5yT2Dv3rfM0
# DATA pBqOlOVtJkVn5EGjPajryQUQbfW0rHguJUzj4oOhG446x92nquR1deBzxEsLwxNLXvzSe4rNCwiNcdRXZ43rSg2TAK2hA4fbBX/s
# DATA YYNX4qiJuLvrHjOd1AU1TPHJDxVnYRUV0/kpgawChzK/juql6zDorjPHTq1QQcnzX4xGTYb8iS3AJg6DAPH4LgMJDstNc8TTOoqw
# DATA oGRlSTWNqFDAYVaoWqIvhsoShP8Q15UFk4kFgHstgnAsiM8HEJ7fEUPDFurnLmqhLcYvpwiz0A2JBhAyNS9fIKv4wbwIhsbB0mDx
# DATA ojawdMkowvL8ofMyEDAfImlmfwntWkQHmgDY3+h8SF88/wfkmT83SS7w5geYYuHnDmlFb7ZGIsX7Uho/c2B5SwGudtp56qBAXxSG
# DATA tM7QSkBD+D78LEtcVB3UemzgbiuGSOfg3QbuzgjVQKwcnXUuz+RNu+TpLfYvRtTAk4iQIKB4hWSX8zam3wOt0lLqgvbpVtZjyeLP
# DATA Wk9L+oUKiDsNPnewljryFXSMO5UdlMtGfKkkwtsrQuD+1d01waoRq83J2YcQ9jF/LvXoQ1dMY/Te4vg2w+mRtyXOdoB8E6Txe1Fg
# DATA YbpwgIXph1BVuBi9tmBTkF6gtgxR9NRNOKTKUjT4qAfOj/c1lu9ea7TZPx4AAhUC3/C1pryKYDcP1SwrGah51hm3wC5Tyjq944rO
# DATA EleW2ebGiCqoGtIaq2bwG6p1TbPHTSmEp6RGZRnWJhRZAzcYR82kbwKeJEBcLa7iwsdqIPVDsqjvxw5Q6COLdNySRFeOrtqQWhik
# DATA wax13EnQS00ox/mLWm7LMbeaasiCHSiwdDaHat/kDRB2KBxP/aKfhAotI4r02YLNm16lJ/0JwKl/ORXrwvMqzxTDD0DIOXWztzu+
# DATA xBAahME0hnqGqCtBkd5O11n3ZMSUjrkGVNGCh6VNPcA1gR2k0zqrmK0As9PE6WysmgVyjXOz8YOVZfWfTYlyCwYmIQdnUjX0BicI
# DATA aYmLhfGWAQAIQZ76SnaHhYO+uYDx8xgarZrRMSlRXJx3SYX0JjnCw6CRLJPor+h3ovfgQO3yEvwaHH6vobtHBpbRDwmbvav2aMPf
# DATA xEoOy/QEeNJ6B/1PQOTwHxONg7a83khWPBzREeqRSADGIggnikS8MDwUSnlLDjRs1/BrxZS1DhXbNhl3iDNLa7WUYLJG4yzvuHjQ
# DATA x43aD3c14miZsERsRlqOnmnUim5GPCGKBPI2g7iYAVO3eHGXC1plFnE/RnCgnLA1XD4St28my6JKpnd2FSsBBddMXgsEmQuomtlI
# DATA CfoOu81o22MbiBmxE98bdPsIgbpIuoLYMIoPfWUFr/Q52qpHiKLAFAVQS60teZycIePJi4KliSGMB3rqOes8HVJgq2VFdaCSS4m4
# DATA lWk54rtjB+HsEbQJd+jy4M3lZXCGhyDirEF2DsQybA4ekff7fEIs0Qm1J0Wn8qZPp2l4gXbAcXs6GXd7tXY3e9ScZEps07NZOwZ1
# DATA 6TedFfp6cn0t7/i1I72pdsfxcfcIYjoAwuwRElnFZp0hWfI3tKT7UVWcPpX5OMD9Sq0Ke0PfdDMvmfXMBXlEQTHw5Zna/+AD6Rb+
# DATA GqDH9SYZvqyIM24gBghUa3hCJiW99wVIoD5AyDzmYlAC/acmV5yZxbMgfXqYInEfTMbDybheuBiPTtUCKOH8iz1hgDFXVlZIc4i4
# DATA m+FiJD01yS55Sw9bfApQXebt+H477EHYllCOttqlsy4oJPmzSnL9jTeuXY8E1Qt6g6XUc82AuTP5RI3YeDTpw2y003gVNKI1xgCF
# DATA iuLv2WGpEix/zrtc3rFaH6cRtMRBVjvOzvtHJf2eGsT+oOSiHeEJZqyJw/MY1yPUJXrZOLRX/Sa3AFIUoDsWKCfNd+hmgGiDtFFA
# DATA PqyhiyC7D7DfHhmJtRPfNq5HKBwsRW3Vi4Z8urm9gfc7o5F/n7mf7hmGw4AFpgVa1Noe3CmtgAesfv1Rt9cTr9farQ7FtADZEvdR
# DATA 9NWxlxD1JnPaO1GoYx9ds4Cf1K2g7lUCEdJHkIR9CUtwMvKojG4SP1zwcChMV0sSjlzWXTvqARClyGLebZ30B2qrH2FONfuyqoo2
# DATA F6bD8zFqK9SUTLGPlPsvjdYIhfg1Gv8R/d6TVndcYr/MxqqgH0wrwcft9mDSazNinmKxkFUGYoE8nuwDoqUwnXaeSCmQhtHPa498
# DATA G1UZi829LdMqUIxuervVR6FDHTq9c9xY4uy5abM+2C2i8XAhLzrhyUJJobRkFvptnZdom27wTjEJrdOK7KXGJlSV9uRixcV9BCHO
# DATA cm2QKyJWMxzAqomfbTkrSz4K5pBIjU6iJLWzlEFS0VC5ndVlhQgTvtTIoVE2zG/O1GyvJesJh6jpZXHWeqTkRTowITYOTKs9Yt0O
# DATA 1biBMzAuh+9PFLsEgMmd7hCsxVze0eC0g+Azum+1RCcvSh51OsPMzfdhZ56wghUZHkwACIgO624/G2pgGjUGJUlc+Vkq0oWycvIA
# DATA oGvRLZuYMMXuqh53mnQC8E3ACtA/vc1lG+XE0JvGMLEoixQTnn5xs52WnVSRumUgdnjv7vp5o3cm/T7yQBFUdUq68ZuE0+d+wpmN
# DATA AVU8ps37wlGLc7YGCQiJSOqk8/tRXhDmzISbrGQWL6O21+aXhMsgsRrejOZTk1itV06nhsV7pp7LpUXyxvijIn2pULdHZAIjBQjf
# DATA i3ly17l8RtLw8qBVZua04z1daJy3mm0YfFbI5liRqbyDvEwzOXnMEdrwp3MMn9XjBIMosqnAMLUZM1IQTWefBTyaq4WHEmpEB+HY
# DATA rnvSxh0iMpkVmfttykmkJCoQKCZdgIRXdDBpHWZA7XqdkxaG5mugFluYXc54oBFrtQTRZnCYqp8opTHLktWS+wChnmRP0HSN1LKH
# DATA 2Co1X94qOPWNGQo7SpwGxkI568F5nGsz+DcCdf4N7Qsy6ksb1KfRydX5GwjihDJ9/RYfRJH1CCvPSZkr10RUg+dDvu9rfeQir6HR
# DATA SW9wWEoX07K3YkGXx3mCaj1KZRBDig9IFoybyQVmrJxucrBy0UCyVUVjjUCGnY8wITBn+P302b8bMGKw/X0cjuunsU1ToFI0Wg3o
# DATA tMlhkZNYfjlPw4jqW2kKEIre3A7/MndJ6BXx8fOfPP8xDAFEycXsvLjGcFGgb6BLkL0BwA55sngwWXoUCqXzI0r214f0DaUYjS2g
# DATA 3ohN55Bp9IqYZb4vSwRAHPgR56jBXyaDIqW/iuTqcJIYxb5x9gzxdCBLwcbB19inlngQUK50B5MsLTu3R5Sz7TzYUcgaMqyoLlka
# DATA 0Ol5XEdMz+b0NKGXMR0AIELiFTcZcqag5dVV2nVPOL2NeJdSk0Te5ib5OYE0a3F9bYoCBRRZvNGjSX2Y7iFmKBhSNRiwIq9/JCcp
# DATA TLrGhFXn3lK75zdwK2yqMxiwyCCGAWP/l9Sjpaej1jmD4upJoe5jHhgCsT2c9Ns9QJSY29FHVvrK7JWNoG80YrkD9s9erz/RfabE
# DATA Y8ytfqpBVylLmTyEOG845ypz2DjMV+blHPBT20VSkH9B5xEG6SJAF+fG8hsYXz96A/JKEWRWbQonf6vzHnG/hUMVOY0ZhPZj3SHv
# DATA gJapNX9FWcDUAyavIlGbXmMLxu8vM1mHUwhBERlb1hNUtyk2DBkOJRZ3pd4ZHO+S4eAJiHWDLIOEbphOozUiq0O/80QURjKAcCFK
# DATA ECQsO0WO5skp4M1qaVJbBlv984RVK5gBVShsqJQuZR8Q2D3A2SreAM9vh29Apt3yCsGxIVw45Gfscy4qdJw2EKOOnDbwJ3uCgmoC
# DATA 0u50GhFPjXaHQh9QiaWGH1V/nPkkq201d+5s3b/73eSHdKUZc3Pj/tY7W3fvbn3HXZLjGG01WlFbpftVoCMRX5LKSn5J6gxU6TaV
# DATA IK+E4xKfKQzlXg8ExRdyds9Jsxum2vO/OWsxvnG6owtO/r/3/wX5DJ3vQUI1JzIppkYb1JGgqKntaOaRjlUDX57vAlYjyMaS59+t
# DATA 2QkfzbbJ4ET7PiYeoSCSUCiOwLKHjguPKxhdyEwe3PCJFq3WhVgiIj24lE83N9Y/q7XaFCJJG8RuImF59rJ6Qj4Qmx3MzX1q42ot
# DATA 9awv5Nca+5Jxn5RIiMSAJl+tLMxd80ecbfShe/6hTgOE68dNl/Xs/yxIyWLTB8mEYl6YGUbnoEipEf0BNH1xP03w64AgyWaYZMsH
# DATA sVLVcfCROZx+T36PAEf+vk6zjH5ZxZURGTMDWj5wMrCY+3bsaTxfB1NHIgMZQFzxUoH+MUwu+8lNQsqgtM8/5YMI5ksLgV7eFcZa
# DATA r7GRRNQOI4Af4g7+APv9E8hPIk62WvLsXwh5DE9J9dYfMd/C+6TP0VgeH+Xke1EEPEuqvVYID0uOm/+uszarynWKmBoCGJvMhx84
# DATA yVMw1AmBP9gh/mNcTpSaRbvbPfu0FlaY0lqUeRD5G8yDyIXC0OIKtSuTVToGXSEEp332f2BuJfBChRw4rjctZoBRRYYFUmx5WBo0
# DATA 8hNalr5nrlqcYTmjzomSZkA8iHeadisUoUTHenLUjm46dTMh7bAGzk+GGDGApkSm9bC1JpnO4oMBnPGNfxCJTLDgDJUIkInBr6hq
# DATA 4OTa+OnYJDegcOuKjoyuUDBzhUexwrIa/ICYZDeKwSVublJol2jj7pDw9Gh0jIyXLqdsXMuGxHQxv8E2+Vn5MUu5ehKbxjGeBdFx
# DATA o0XC7KtOdCq3X0LONkqNQgw4bvB3Nu9u7MIIB8yuSOkWpp4Uxg8/Y57uMtlieTTcY8VUCvOk2AF03inhoJcZj5jPMkQILT5znv+k
# DATA AlTnH2xuuk8TJ198jJCnqV2Zdg3j8qQoZA094xh8jgi2PNhw4A5uS1Ed8HUFGNsEXwsRRhsD7QMz+Z5hEKvpjFBbi3oJ+sQTmXCo
# DATA Xtc5ynRLaBZtEQ5blxehrPY6+ji/j3hNbkJzvSiQmckpt+xOcjmvHjxO9VmeuAj6Bpnb1mGCCOx5TuGkBz4fNrt1+TxROKAwHP/T
# DATA XUVwpM09Eoxr4mnZMBeH3zlJDu/lOBUhBTnpzGrxL+l4xjX/3yKwW3VmZE46c62J4nUh8L28gQkqmHdx+AskqCKyVqgyj+OzO513
# DATA sGXXgrNzKYibV0dzjYVa3tXl/fq1VfdkmbmHAy0Qz390O/ME04qY9HW4bzudVahYAEE/LjHd86z3+LTSSo+VOddWt73O3eSiiwLq
# DATA agl5V8nD/TtpsPyz4kcJaaLeR+0Udi3Bjz4RecAD9knX8s2wxLeWyGbFME/VxSVmo2GdAiPt8ZY5uccroI0yujv6CqDQRSLLT6Ja
# DATA ubCxwAjxePx2Dn6U0Ml49WshvojxTCsmQt4M+0dUiZMW1kRVOQjFIZv7SyFwfMISzMeqbZhoMYGOU9pyFiFQErGjxAKhNtHrBIrG
# DATA 5uNp7xSboENpn/+DloXYtI5qQ8OniEwAzMNoWhHnXig7uOFeSJWD8Ei8a9Efe4S+oCf4u7Y+OplAVdv4xGiC1I5tNJuKB282y+JL
# DATA ENGbLf6klA6GnZEOkzo6HYBeBNBVOdsuZ/2ifIMI4AJcTZUZbDT3y98mgRhGBqSMmdMaaXw5zG0Av08IYY4oVorox9lplbOOU1Ls
# DATA 7vG5uOHQIcBpCW4yvmVwn9sHUE7dsUbRocox37G8peHwqgxagD3utfrCsQHLZ/Wnd1t7S0k3iBF725iSaAChoio3QI5NzmNufPyh
# DATA 7gc9dfqOaPpmdixMAwo6qBjUHgrRtVGtstGsfDPvBbbB5b+g/YIKq7GSnlyEHgedX4efZjfnNZOVOb+xlKws9zlNdf7zSDLanDcx
# DATA G1xBSSP2OoLQy9FJ1gBVeGHf1Noqahgl9bKzkfum0CCZ2S+q2O4UDgZspDNaistUfVbVKXxaaAtrpJR+HNP/FFeJQF+DFyqDqIXb
# DATA 6twxYehh8yoCoBfvmwi5mnN8nE9pQc7XSpdVC5q8sjxzdyDttvvPpIlEHQNjIZsS6ensibrUSANedf5TsNRYOYY9vPld/ANvZzYU
# DATA Hq5q5oBDAytTvbqrctBWEmSj8SvKaF9JxB2KKRUZlSPF+3S27oXRalZdluijKlJyXT/m1m/avoP/JkTXTr912EMZHzIGzQeMgfAb
# DATA FgNCTfn63bsuYIZjB9EA8shRo47JeTy0+B/opGvc1uW8AHIWDBm1NzV6DG5/FFbWiTl2GmGgy2wvclJBwmdtQMRA9HvoXVEv2wRp
# DATA woHp840mWGhjoPpWwyWm39jkXNd5M4nO2LEO7lytCEpdSG8Rvl5/kBYvTslj2eGlG0142CF/7ZqFCigsz+eMLrXYGcUgDw2DD6qm
# DATA 4groe75RriSxJs45tOIV7Z0GDSjuZozbE44+EafxSxKNQr5RyA/8mvQ016+53b7MJHp8sZxDeNDkB4L0cPnxyviaKXXFbPXiRvis
# DATA uFSW0onuNOMy6zPCM/trX5tU8xaWXKqUXAOj4Lm4cLadU0OeI1yd8QRjEB1SB1U8Naxd//Yz66vufkq9j6DL24Ygw1mObCxmDZt2
# DATA g9mPBDPYdJZy4OxZ1LVKMqsHnvsaufB1+8PJ2EF9QIN63doSQBQj17G648aDD6fRbU/xHHbTF1AF9GAWiN15y6xIdrP90m/NtYLm
# DATA 2rKF1fHunW+5ipU61zbNlTTDfUsNcDBN8VXRDJyMitiC3K4Z5ipVXGnGQLlaBDEXeL9J9y9FUoxepF60evRbpVmnmEARjpJRnXIc
# DATA FveMvgaqi+IW8ttNfruopSENwQv+ckazrPLI5w4waTCiiOhXYkvzsiPIkPF+mw3XiZfEMJXMyg/QfAtpg89UOK6+YivdjIPsAmOu
# DATA On4z7lcCPKlRjotqJfDhQZTlEU7DM45Fo8IrXCI2f3PRzjT8GOFE0wVhgIZjC4LwjPUSCs51n/s1qtIQuzlepdPE8mUaoHWKc7ZB
# DATA p9h52c2YOVdOXTOnzBDPOWTZmVWbzL75HoQUvUSpt9HHWyyTedrAoOF2DmYxbN0zTCyUnds4WvW7Rs4RfcVEj0vLAui3ifS12RR7
# DATA jCPhykGZxHt3x448WxouERZ+geVOOKPPg6AHQYSY45ayFIUxJqYhOh8hXpSGFZ1NwVls5jPbVArpchExbornJnTjjTd8cqjecZxo
# DATA nMy4Yb15k0tGgvBc0ASVUn/OdVAaUH95CBQSJkKg56NMIN0nhZs3ks0p8kBW4ybjq6CKw1baH9hnZR+w/kVOBreIDQAG2oaQOQK9
# DATA n1HMHKffzaudPdoc5DCqAVp8cOjPzQ5opZJRDVcRvtqJ99duTMYJED1/OCkYePp8WgyTG2A+mn05S0JI64EWjNOhxDZt8K7Mn+J8
# DATA EE2cor+CxVin5G2W6oZv0Qaqu6lc5aNyTINXT7pDNcIjiIrvDg03qR9XODuyjLTNGyRE71vwvakDtacu2gFyFP7VnNoeULlDKO48
# DATA v2r/UFf74zFpPx+DdEu+1gIBw8lsZEsQPtn5IhRaPOszuceFnFwSWgde9xQtKZkK6oICTsMpY7OSRJOox/JC8HvrAecqCpnNhS4s
# DATA qHqbuJSaTex+swmLtNnkAXCCIcjILRPJhyAWgDWCGBT1osNe7/H/+fzHavP+ihyKczwmZrrXYnWKvmCyKWAjKEBXQIQg4MbueTbu
# DATA nG1QjjfZidK3YVVg6yvJtzrn/AtyIvDPrV3+gegGf727df8Owpfg3bIM9NlElQgi83f7R71JW6NHIdx+Vk/6GK2M/Vci+PcIrIEC
# DATA HDDWadLrJVBB7Usevlry7Bc2DOr5TwnqgEPPjTd2xUU/+AmFkQm6TI7Zbk6K5z8BlJ5LzcZ/+st/f8b/KWJx2AMGQFGD2vD8S6kD
# DATA 4qWvr63hX/Wf/3f5+rVr5jfeX1lZXln7T8nyVzEAE/C9VtX/B53/V199FeiBIvJkNNVRYRiFpVOUkM6uC3Byo06v08oAAIeCD1dq
# DATA q7VvrNYWFvZOwb1Tvvj9iZITkvGpOu4QaIxjBxAesnsCGU9OO70hhiicAhUECDv1dDA5OV3AlxRP0W71AHNp7/Z2lfA1jzstwK9B
# DATA gyWET9o2ckbl5LT1uKNa1wGnY7APtmuqbZ0RRma2FWdwCBwBYDD1B8boeyTPOgTzfNo5mlBMOGAqAWNM+HYLgLE662QNyGC6N6s/
# DATA p+pslY1OvyLC6YRuHH0v+xPs/zevv7Hi7//V5Wt/2f9fxX/pJOuwnJDeXFhQGyEbJxfJ9qibnbVu97oo9dNVMkVfd9zWpfSvhnhz
# DATA 6QjfScs3+dvvPRnL14CretI5JAtF2dSwe3trG3NEbGE+IsT4/EGntE/5HTLcOXWNFO17FWZ1gANTPLZOy8ppIQJ3aX6e1dnjMf8F
# DATA kFhUMQfQwuNJn0AbRp1JBqdjaTR4UuZsFjr12uBJ8p//M/ypcbIPJ4xWVoQO0al626qB4LPO06EaoPUxftoH1vCHP0ycB29hIrY7
# DATA IHmUy8H32ZGSbbKaoqsniHjQ4DHVd374Q0e0mOub15MV3St+lRndzA1qwPEsu43ikoAFPi/h10njrWhReF1WIz1dWGhB4HViRlxJ
# DATA u4+7IFKVaHVVMAuDzmil5wCUfq8s/d3+cvUbrerxwcWNadX8XptW18zFNfXgxjdahwfOHf17ZXX6taUa5KrGZH0w/pCqQAwcIOgP
# DATA jnU+rVdQNTyGlAQpvEy39dh9M7m2WgZkSbUyYN4Y9m+zj/oHfU7RAaO+a6tN021Bco2bGmdNrRtaS8UrSb6vfcNAOARcvYSGrdYa
# DATA djEfYVYDNKQH/e73J0p8TZ7AOVhX2xv7O02mXPnSUrLTySaqbswXk7TwwK6iaKnRmCraBQKqwzV6jocwoA90MVhMtbDVg5D+wRGf
# DATA o8fJqHtyOs5qZtpMg9Uye8XsL323rGcYB98fSna3SpCWJEenrf5Jp31TGzuRG1DrZ0xil4zFJYdQ6ipl1+ip6YTSG3YE1YTmDCGi
# DATA 7MLwYX5p0UJamzBnlUTv2rrdtPBPrT94UgKH8pXlZDG5dv0N9e+N62t4zgGcDG6NerJfq9VoA3EshzM3e8BCDXrt5GTUUt0hMfNo
# DATA MFI9Hw4AUx/SuQH+1gTyoo8R/7dtcLpqam6BpdClDSgPXQtWT+vIwHUhJqkzycCDdXGdjmmqsY/MBsUmVP+ei3iIcaSZyBl9rXuh
# DATA tXsBYz6t4Exc8OiJwZtOnWlmYq2OpBpwnKULnjJ15o0oJzsQXoDD6EE8y/r2pght6LbUZN4Dq8VxbzAYIQGlpdBexzwngB2LuQZX
# DATA cDLNh6o5ORT+7eQCsM5aoEuvAzhwZ5qoBaVeDGrSH4cVTcvJtCLcFoEIVdSebvVOBmrDnp6pnry3C34ZuIYKiOw7g9EmkaUouQWw
# DATA yH4bdaeS8gY39YY66rW6Z9lNCXurmkV3AT1SzQLZ/m0RtqoL03zYDtyBA9UBtRWOAHpIFbW0mKwn7e7xMaFqonYf0RMVyXmkVrwl
# DATA q5AEJFNkDPaiXsK1ZHEpmTqWI26bWrr0Cw3UdJbDWoAHfATwc6SbDXkOiBMQ99fLPJVEpc5+sfS/cOdI0q8pP5RVl70xO0aOi8P4
# DATA lE0Kl+BwFuWYM9qWNg134ozzHVcrNQDZxxplqsJURO2JmhpFpDUMbGt08pjS/DUANVqPD40LlQ4QXGrfKDbkwl2UkZEcEGcJGM6Y
# DATA /rhEPO/bNSrq26TpfbtG7O7btWzYA7mulgLyafL225BI5q1G8ibs8UDFrbjY4RhS5cF6LBneGEFdWsPhEpoQqIvZkmas+aPq8CQt
# DATA 16g12yfl0kU00lJ1ok+oVru4MOtmnNRBWJPpcSuQW6merFZmlLNHQLD3uj3FG9cV6WkuA3xnt93reI+u0aOgvClQJcrhTT1XtZfy
# DATA mlWuZR1AmNxujVpqSVEcLeX/LsPwphjAdQQ0za0JKCgkllGrXXEDkfh2rFrKMyWea7lUNY1x0YJ8DuQOO+4ohqcLZKb7A2J0gEUC
# DATA VoTIW+JkIw43RLnE94oIsRwna8zffXBr9/bO5vbe5tb95t7WtzbuNx882Lzjvg4JlsngXwmAtguK29l4oJqMhVqFbg04ihJxXGof
# DATA eQjhZHugpxwzJz7FIdUbELeZoq61Dg1lHpTms9/BLQTuAlu8CX7+RwF3gAbCzzAhng0nDkKj41rwf3r2L2hjjIOC+UAWNYyH0GP3
# DATA tDu+DQr/RrKijiXRUwaI4r4yIf4aOqLhdiqRtEM7HI72AaW2ubBLoBJbDRUtJ09vLnwF+p+m3f0vVRVcrP9ZeeP6mq//vbb65l/0
# DATA P1+V/ncb+Sg799pbFrMLgJpV7VuUKAL1iSNlddpKAsMUVGzVAkp5fU1fgSJI/x5kC4j/Cz5Bve6hNoOBV4R+ZdTRv8CcaX4bGHh9
# DATA Z9w5G4J8RwVORupIOqRwJF0qOJDAYb1giqasoxzdS65Z6BWLnsukwT1uz4M6p0Hm7PX9W3e3bn+rbLNqAbhcm1JqtSFclFOpUF4t
# DATA YUclFF6EogMMXnruJegQUFTwUm23ubm7s/FuSeK4OsCuOnsdpGWI5SmwxtFSunn/2+t3N+/wqQLh0S70iYeASIg3uiJgixlI+WIZ
# DATA h0od4B11t1SeRpFml998szyrRbYlzXtwWt3aaG7vbH57fW/DgUPGo4kH1KaheMNPQ2Ec7xYch3CaefzXyYKCd3iJRF920gsIFwh8
# DATA iq4XOBU980E4ETMmQeOo03KtBW6G3Gi9jMl/iJAdtexvfHZym2vf1C2mMDDG+OYe6GvoxOry2g1Mm/bwIabUkO9C0Ntg1C4dlUEf
# DATA dg1u8aXi0ldW36RoL/lVeZ7h2F6/v3GXuKkFytJNWe1FwhUMyOKGgETQmowHEUcPPZgE2eHjhqBE6cP+yAwIPJqli8VFdrbQUYIY
# DATA GYHeG05k4DTYubY4HusrpECIj5aiPOt39VjdX//2+ubd9VvONuZxyyjIUdbKicZ3O+MxJxc39fMjkwbYL82AQyN5kChhpjqdEptJ
# DATA RAlzOiPyx6jbxhDbtK8mUnGPEvkZ6yCFqN/a1lmHnFkBshx2NWSX9Udaty+WOSHdX6/+bav6A0Aytj+bteqBol9qoU5TUuxdatDv
# DATA b+x9Z2vnWzmDb5dnkp6Ox8P60pLOom2zIQESHC9RdBrTF9JBzwwGTxDw+9tbO+jeS8HRxvVTekqJ+s1PQM7Hdsh9TAGN0MSM26gf
# DATA YVnqPFVF6FPVkga9DdWTGkpucr5VYQg0AYWmhszAq7AUcAzUPbjWujl9rQHk9PX3Jx3KhgEXx6PWCTIf5mV15JpaETiVasOHcPgr
# DATA 2rB8FZLjduyVhu6LiZzl1VZU9nt7e9u7XPLOxn95sLmzcSd1Th2jsx3ZZV3RRStKv72zdWsDyJhis0hvodOGKmFifTI+HYxYJq0n
# DATA 6S0lUCsyg4hBvvj3nfVvbzTXtzfppFHiBTpSR98yI8Eodd8BlDqzgkkxxa3YT/+mqqSXJ61Ru9OGX+i2lqr9VFtW/1tJb8bf3B4N
# DATA FLU+SMyogrTkaS1hqSODBvVR31uHOKMooa/D79uEaNOD6OCKyfaVkQYVQsxJQMPvavgvvHcDtKpKIteqIVatoXI96xj92nEHCMeM
# DATA MWJUUUU+uaOAcUz+0vUURV+1KEEX3erVqRl0QVo4NGzpimuDR9qexOuHYkdaR9AA0iuA2hWYvMYyQAdM+o+yxv4BPAAyTM0uUXfw
# DATA KVpkdPGHg/a5Gkz4/PUGPmZT1s3ucQnuvrW2iFkN4J/yhTNoNyPt0gWrlk2pLbUhpKG7NQGFbQ348xLeV8Lw1Awzusc10CuOcp3y
# DATA 6+rpkeKDqaBybTwgvRZyc4qZs8NFvqo//KHW1OL1K41GOkDLMlrq6KWamVLvbfNAfBYdetHFBbNn3SLUg6kGjE4ujnpqD+rFh+sR
# DATA +j5dKOHiLpUbb5nFrI3dDZo2pOxLrWF3iYzhS8YYXr6pOl7i9uu72hUVesCq6XKkAwbD4aaulg3gYa15pnLxrSo+a6yPRq3zWjfD
# DATA vxxBnpXf1oZ1/lvjv+pb1fhX3I+gnHKsubJK9Rm8t7988DZpxOdu8VL6OoYwdh7sbN7WoQy6MNauK4JTLpWNykrNi6+vErok8skU
# DATA gFgGwvYjQKwy2il463NyvSRM4t/Q3ahmCg+HCuSSRxQsgOGn3B6kC7MVIFivhAW0Geqt7ksNma+2aqzcBCqD/ksoMqgXDjsljqOw
# DATA cgALMHzoKLpCIcoV7WDFLFG+BBUKGVyHlDDwVtFhub3+7kZz8x78G/JTlLCaRf/aXgcE+9bo/I4OTCkRKASkHNTZsXBFYJerJIIf
# DATA D3qKQDsw2jq0iR6VOWRaq8QgGss2mBkzUoEiynEaOQ8akn0iHWnk/MW3HDVqjGUv8Uw4yUSuwrgHKPhoC4sUni+LkPjvc9n8U7D+
# DATA 9CKXbfPBxTJs4OKyWe0OEPqmc4RJQSESrspow+gW3n9cNitzH4o80EhV8Dr8i6ySh+sRRA5gzeC42Ec2QvRECTRqYkcl0xErrZTn
# DATA azxDGlerhN1WrQ6V9IGiToex3SR+E7UiH0YzbwzwvppQXGCpHQTectGx0L7xxvVdOsmLTIu75qfvDJ+3ZWHVr9++vbG723xH7Vhg
# DATA bynTF8rpRHZAT2iRRhCQP4/4cI2KZO3QWau+V/S40zZp7/WYkPbxZpKdtkbk/ZFQVgJFgc5FJkWgfsLxnvKygASxYPOtxSGAOI+R
# DATA C/nDzv2K+Y5t/rQuepZG9r16ATs8XdAJBqAs2yggOZhcJivpCDBqhoTsxG+53wQ7pHEhogUNxqeAwZxTjptmhWX5SoIf2UwOcmBq
# DATA UBJAYGsh/xWTmk+PlQNWga1g4CqC9rhIcarUYFxMpwsmHTh0qO6lwttPhSCMAsPF4qImxTpeX8rKnP1M548wn4KmYXGRpm8aEZbF
# DATA 0GnfYLdggrK4SNFhSjVdL+gU+q6u4c+0kgTLpsJrxh6Vvtyo7slW8/Mm5SmavQXVean1EPcg9PfB/d0H26AeMLJmqAmC5BwS3Ek/
# DATA JdJvPsL4vpiyp2LRX/WnclmEAWKUgQOOBuKeqaeg1UFNod7+iK9oD3AAJHS0PNAgqWcyh5KoUT/ch7A1XbM9rOi+04BXGh79mXO4
# DATA b2/df+fu5u29yDDL0cXIvAt1to1B0dFTa4Uyr1L1df2NGPfWeNwC6gVwDeHKQGjdlEv3cl6KcdCF8BC4PdMPw3ZOiwLvRMPAgbYE
# DATA JaOgp77NSvuLtk4Y5HI52M2mCxjexm87DiMIBUP04cBJrYMEv4RPKtoHkCMd6wsu9TKLk7Kk8MoUtEXNBSRFQ3tV7fD6GlsO8Lv9
# DATA lCIdIH+OZ1Eg0GjyPkSlGX9ANOEgh1ekNkGdFf0B7u2DoDjOwveV+f9zFOtLDwMqtv+urq69uebZf1fX/uL//5XZf3fP+0dK9u6D
# DATA sRCCU8jTxvU8piTVsIdaMpUBueBZvGXkr5DhwwQST8fCust3OBWeNsYeH/XHPX0BMHjqC31poptfqg0ZBP6rWIu/tfFdUFDuPrjV
# DATA 3H5wSxH65p2te+ub99OF9d3dzXfv39u4v4eRD8iIQD6CUfp3pbfr5O6xnzwcH7xefjv4HB8sNmqLX4NEzZ3aPbDoHfVaWZbcwe1I
# DATA R409dQwStRoXIoj9wegMnJGYYuXa+vjwlWI4kUa28tHXyVvJGyur5FfJTlmQ9vFh9vDh199+7eHT5eXqw6crxw+fvnl8kDIJC6x4
# DATA sukpdbTJqnU+Hj0zAtNoYY+gO6ExQsR55yrl57QlMKgImQtARKkka2vXouaJy3cQvqQemkJqpIcqpd12v5Wa86Rc60F+QDZNO9K5
# DATA E+DPP0tQnBPlbBeHwGmB9REe2/O2HlQCsCawLrD6voHW3LRmEipj/9Qt+Ks61qb0NeASCamoMPOm/YUGPy/9DKioe72Sl19U7Zjl
# DATA p9ob9vUfwi+1byCzfWs0LrMoMTItEI6YQemI9hHWsM92P1UT/0Sr3/WVqX5Sfnuu+q6w6jmJnLZV7derKwd6GVNGIT2QaLnC1a+f
# DATA 6XnpaVcVmJa1ZZqWWqqFK7gmEdAmp3H6v8QdX6/+repsrflfqwevq1tL/r3yIg075A26fE+ZgcNVQkYR4XCjXWqGFDTi8G0yzx5W
# DATA LqlZJI+ezjptEFSAEMCdedqspKP1d0Bk33svjWy/l+EGxHsUgGTuD8bvDCb9trdVwbuGR6Iec2A1Tg6mL1+qf1Hp8g5Gy6trnANb
# DATA Pu0DFBPMxkqYOdO+dXnfodXVqGA23/xiiq/WuOX7DIkuvJ6slOVmg9fLbjevtrZ4PqE8tRn+yuOIYHP0QH9IninudtC+KjUT8AyE
# DATA 9VE6w1vtOzt6Ud7e2Vjfm7ViKzLzd2x9tV7PWV8Rt7TcxWaW0ovNYqDGRl4SYmiOHnGdFb4HfWtu/I3qrri+fytQid6Cb7v9k80t
# DATA b4vmtO/B9p31vY3mrQe733U0nfqT826n12a6x7Mt51Z7JSH0CLgkZSVcjIWOSWZpilzkNoUDAWCTrgShwe1LOUmI8of9/tZe8976
# DATA /fV3jerI6AsLssxKcm3zGAc02z5yCLetwXknDu12mRUD/BcmqY3BQtJsIM6VeMeFAFuQ5FEqmKBgxjzSXMdK8s0Gkg58WIarlet5
# DATA 7IlXFjPocHhHGBc6oNFRaaWysnrDOCq5nldYbaxCURn3N6/p/Bgbf+OK60VnBr6w06oTTNWJEQgfCLYAYfGmCxaeDsua2hTD2ERK
# DATA BYaNlewvkk1ZPL3jHwKGHSkgLAZRXWxUPBQCk4q0pDzod2NAQsVjeHvr3vbWrqe2jVCWULqLJlkuR9V9l6zeskMwnfswWKCvw2PM
# DATA HSL7kK4XfFOCWZzRDANRywv2CJd4LLs8vxczKHp51cJs1bHc0rgP9g9iVTles1xOFOvMr2nfXLjlwqAQCgi63wXJhWVZkfVcwm/3
# DATA CZj7wFP34jMn1TXeCa08NKe6igO9I/QNhxGipMiKE7q2ejV6oBkgCyDJ1JMHk1eRthSqNqC0T5vNqDVw53YzD0DNZ5aRauL4o27a
# DATA KmkwMBKNu+g54yl1y84BxoXk16Kh8vjFfSXPgVcJS4kNRc1WyvsrB47zucbC26+D8Aeeiq+q915NXxXr6PuTAbIG9OKyzDDS1rex
# DATA IyV8s6JZVtKud3vmU3hfMbR10wR2lYZoxWVWr6SSrMCzbyYoVpawJC1GwoXMVJu+lpbnJiyucChHjpq5Ulf1HkQUFvo1UEbhoKpz
# DATA EHVpr2nlE0Y04rPGShkHX4y1dNLiZaWTRpRmLUPr6YItsMuR9kx4dB248xuuUW0IrfAazjVJiCTDWjjSHlXBDg7bRwKLTsro1M5H
# DATA mS2vRvbIADG3mGCTTAnJfoVTfcwAW0DPhV+Ja5oNazpOQPuKCmiosx51k9DjQO/sqy8OrKeSTObinO/6K1+JunDJY52Xoq6MtImo
# DATA 12DO+aSD+kDWcdc4W0J5Ib4uOLepszxEbVScBkcwORm0ghEQJw5T0NWCxrTk1YnLo0ZFED3QFFXDUhJdOEzPulmG/j7OZrpIsbOK
# DATA heNOK0GFQhfVLW7ZaeeprkBn2KP3u+2p3ofW7sBhK4Tp0cAQAEbSAkmIZQ0UnKy0YGXUUGh2ZJWc3c1hBUYks3lJCNmscQlCIekn
# DATA dSLc+2IAqYZA5yKZOSxEmKuzzphvopikpwCdpIYIebKj52Aa07bQt/vh2wdQHDVo387jwfwc43vr99/diBF2u6N05dRmyubk3QtX
# DATA n8Pung3agCvXtvz/lclpESk1jL7Dzi7kOcYUEMcrcrWisfrr6EKayeleikj7rHARLY7RYy075rDU+U3PPynz+1IbDoYlVb0fKhRw
# DATA zVFvv7A8PCg0H5L7vslg5jsgUSHBd+xTgAJje3I2zIzLW6efgTNRKzvqdknxXcGEyP1xY1Wnnp3DbZErQGIO43+YpoGDQuwgxT3w
# DATA iitJEPdiGD3BKrP9DyrLmcbc1ccNlIVNDjEoB0sL5p52vfc6LDM1JA1j+OOvF4pWkqEjV+oQtxv+mDAccMnlqVF/gkbFZg3cuKAI
# DATA cyK/QhJzWKmmbUZ2dr7zJX799jwHi8mwpRWKOgc26weVDBlLuVGFjoGZHJ3j10plOM2dhlA5ruaO7r2YSpfLpewIoCJuLA/eBNgR
# DATA ygiRkUYox7HG5rk6a/W7x8CFcAYs62G47zQvmtRKJyzCmzYhNKfMwtR/Ug8SPbc8P16bKMvjxERBZckyzVXJNGDYsbUVc8x1+pMz
# DATA BDst6UVjh+7Ay9A1RhdoofgIteu2gpI9dMvxiiIsq1g+MRMgziysI9Hv+Aa9DC8iKs0Zz5w64iurFF8TDFDOpQcahYXi0u1gzv6S
# DATA p0pnZXP1ltqI0co6G/gT4gCDOdSrYwRu6Jnim7nMy04VoTIJylXP4xW8kS8+6NGWO+mTqn/h8gd7bGznnhxrXBVE1YgBi4688L8H
# DATA srnj/3fWPWF8v5fqAjjD/+/NtWurPv7Lyupf8L+/kv9ee2Vpko2WDrv9JQiaGJ6PTwf9axAltjWEjOXJZKjWRLsDoaOtvoXLDHBJ
# DATA HehIwOL0vALZna41OkF/uwXjFTg8J2880GTAztWeePqaAnl/ANLgC7sBBvAxkHlBI8mAl99sv0DpRbhw5cRWUSiadoeGVJ1oNsaf
# DATA KF2vdajIXoiEcJsBkK0q7S6+6cR8SastFWSsxjUKWNJSoU43UwOvbDWRTfUpAS1owDJ4Oncx4lMrC8/4VIdK2E8DW7LUQXN8v+hi
# DATA A4L+HTCS09YI8UhWDR4J3pGQJOoGnIk2nZkWaXWXXQk33x5g0BtkJh8niQ93x7ftzsaj4LrL+ZVrg9Ock0wSKVmdGE6D7RYVd+iN
# DATA TZgNQOqKBlObsOl+wahou8+RUKY1hFqNm9QwqcS4sw3+W4nF3BnjfIPVcRhM9UDtzAbsQinBlDVOjg6nafW6ik3K7Ebzg84yjqjE
# DATA wMsrg6XQbRNLq8MpXmg7ay0sJkpCXbX2H6WkSTrawco6iyXdG0YMoc5rYyfEQnlv3Lm/CyAr4pUQD6cIi6Uyu2fvsVMsZyW0ULKX
# DATA oA/01YGR/rVqmRK/kdO64xTtSDUvwwU5F/TkwgM9mX61oCdzOBLSvZJtesV1VuZFVbGu0mASXFu75nW4Yf2ucahuLJfzrScm81IO
# DATA taD5OwQvyeZ4QBmMS/ivWFKgMHusRgAItbtbKxzGXYybU4k+x1qo5Rzu0HAXkrtFYgGfuCgN6dRBEzmWamsc4oiLRnLh1Kcah9Fp
# DATA tK852E2H2XLwgarxnZ2t+3vNjft39D028T7GdkL696nfoj5XGbTJ2MiApWuKKEG0P1ydDC54QYdZh8f7ChQV0OYVZ4ZB+SWnnVTN
# DATA a8kdJBkaEy1j36/W0WiQZQlmKDDB3iaEbTxAwPMj9K3ETJFc2PcAhh8e6U841pYwCNR9CoI57ADjS76cbcJHb50ddk8mg0nGcbkc
# DATA RZuxJzN8pTWUcjAgQB4f4PviXoPXIwW8x4VjhuQviVj8kijn0nOW9x+2D1fTPjkx+AcrxxnrQ5VsJrZRkXmLWVlM4LHd8Hotm9Et
# DATA 2FjHcVQC1/Xa9IJpqN8Tpj7xmNBA/W13mZoug3xlKgHSBaBZj/Oxu6Kk22xMp4/sWarh1LOAUmaCVDbIJk14/01IA+D43avdMumN
# DATA rRIw6xCwomqmNVJb9Doyo3EtMiEg4ILOwdhsYsZEh+v8KwTTNkUNnvTR4IdF1kb8Up1capYPKG/l6dGo1h0s9QZj8KNesuHCARyM
# DATA 4+QiBoGWMtQ1Y2ZHHcWAdFmOchu1RI2qrhjPn7rbF9Skmc8NixA20gl5Dh9PZ68+KHz+8xPdxuyFr2e2Uzxz3Y87Z+CgFpNhvQjy
# DATA UgA+oPEItNxobpjAeQokhzpC47B+AhMJNfDwwgL23QxBddpu46Ho7TJY/FqtCqU5Hg/sjUFvYTRzo6foT7uFFdd1jwqaXzZe4AQV
# DATA AsHGiu2GvJ3IjTQE7oa69PekulXaXxQfHZAhrEGx40etIWQRaw4m4+FE3xwT7lRj5cayIZrcT+oWKEJ9Pz7NGIXZP0vps3+lxLzP
# DATA PgeMbn3Kqt9/wLy8MzCJGAvpd4hhBLhHP8bcvh8B9PdNJ/Wkzsr9sfrzMRQCTz+D5JPPP3QdCbk7BEduRxgN3DBYJcIXQfFQupUE
# DATA fuwhHIbnaBJzaAcjVah9wPLse63+0anL7fIIc07yf/VSj88zig5I1CfPPve8rfd9W//QaZKO2XSlRZLhMeAGx8J1fi8fyFEwr2r5
# DATA X4dlwYNS2TEzBKoBt/v/w0lB+nudnPTFBoJXh4HjqSS6O4zEQ/u0yuJnVGfj7Wgv64AoxC4aUv5ZHZLaqpAxGYcDQWr0cBA83wjd
# DATA 8PbT6jF/Cc/KBwca54A1rxRj0SRLBsP6oKKDb5FxqkkeVCYjMedpjNEWVVmv0xk2CFUYfloEHrlJrNI0hhAPUUD2aiEXZNe2njcS
# DATA nRMcYiELv6etDzbWIgwvgR0WbFak/PyumTH7prlVd06rSI73/MAPTPvQCIlLeSEvQMCl9LRgGL4pXaQlyTwRAEENqijWDBFq3dwD
# DATA eCOkQ5iLkm4fg1sVqlbZug0zDEeGr2j1jqAFz6/IcSv1wgaQT8vds/+sduqveHN+rsiXT/wjyRgStU8/VG/9CP/9UJH2HwGlVzRe
# DATA 73gdfsl43khF7TIv1winHaxvLpL3LHhsx6MPrA21tlrx8IM9csq+ui8C/sQ/D5xX9znr94FmB52n6KaUHk66vXYqXZXs15eEMnK1
# DATA Dz6Y0Wx4KVsxadh0nV7BPUfhCCV3BzXDkmr1WxUyJanyIxzsdMFxPcGJFDSqHHqdIDQf6NW0yQezpmmrT20yPsIpP4Y7pfTr3/36
# DATA 2dfbe19/7+v3vr77t+SXE/VY2a/fYCH5Em4lGK2eaG8WcCahCDrcazSObA6m0SMGQwTgRcekkjiw4HW9CSGiUgai1ROz1KYLoTUb
# DATA G1cxLSgvFDnBULtp6WtHmPm+1KpW91u6YnqnJU5npMxdMVpuHSLxl9x8T1pZk/PaqwKt+K4xCQXOuxEqmuhm7RHZYUY0skVIe9Xq
# DATA 9yddTP1pxlsTSz8gQ5ZrCZ9tQISwO2h/jAyfVpySBHGW0qDbXwcdMRdykZ3JWbPaf0wASNYfVgDg2/YbF9x2RcC1C0xLzeQGu5RN
# DATA lRKbjyWeZt1zvJSNkXCZIc6fbI6H9Jfj05WzYFwXEFtsnuY3gm0ZU98KVl+XWF8IU2PVHOTUSKdI0WKAU3nghPRWz5cD7UlOSlwa
# DATA 2vpMnzfRX2/jmkIiAAfBWp7BKgdybg4jHJHwLZ9rMwgezGSM9AbWQxOMA/SgO25yozWJFOuGhihkjcuxmZXYYt64odZTvfU4ygdW
# DATA XK4Xm1EOpChT0GvJ7ngwHCKE0omGqczoVi1ZTzR1wCw7XcimzqknUe2shN0EES21r4UawadoH7pzqxbMLTVajeZkaBjLdkeTSnWh
# DATA mZQIRumiWhnVNkUXSqqFSph9+hzN8SAhhVRWqmjE56FTWhM90iAioHR9uRyP5oyQfdO1KxJ+p4qXSuv9M4VG7CKMzTjttHoY2ll8
# DATA DLyHr8k78Moki/s6znekkJWBGwD6SKJbKd0595WNeeXn6XbRm5P0wQAmlU+XA4psOVgsA6nqbI8/lk7+DRG3QfwAOQPxun9LyNug
# DATA RfgcYLdJvfQFCzG/Q3TtuZLNzdBJpHFDxqHauo9i06TnvqH2Zl+POkbrFM6fnnnSIbeVYERxQIoOtfMmzRukX86U1yxw+fMfg5pO
# DATA o5gzAvrzHyXPfg1CHd5ioPLoCKCGobQ6DxRzRDf0IagFQTkG6sD31cUflbip6vzts08xdyB04OeXmpkc0X8O8h0/g5u91jnA+5P2
# DATA 4+UrLZhyLC5q5t0e0e+wV3usS1OXYwpZB6lWwt+O0T7HiVgXwTiV5tilQ3b+I9VCdroe/R4//yc8scgVmDRxILuVDB7PKMO0ItqT
# DATA sbY+OpkAOdvGJyVtAVF9bzSb6thoNsviS7A/NFv8SSkdDDus9EIMcNA3NGCZZEcDRgnPFLtCrnSsENR8BKkVO702qREppoPYJ7bZ
# DATA wBWZBLAgpiMpAWHAr642wiGJTU30QxVkALjUCSPQLIVsE/yk7AyTUU+q1KLdq6Jkjq0sGIRqFX3qITTofNhpmGxCwBWjEwZ+g3/g
# DATA q8yKbXBVM2OIlNSMXR7PTN/gsFSk7dShAPgSeYSo09zj7vChMI25RlVc0VpOibeR51Tw4TT1Ph3CT2m6HF4K7+OYmegp1sYvg3Oe
# DATA ePxN9Nvj4n3TcnBwKlL5xfP3kc5+Zu0wn6PZR5H9S9HZqDaYOmSpjXkxVxUMnBG1ft9266Boajkzm6Rpzmmj9eryZSqaBDr8zZIc
# DATA /nY07HjHyBJ4ZXTtRotuV09T7RKw/alJa6JhodnEFdBsAlFpNtOIXxqRm1wXKgPb/63O+WzQftDTdzxoyBH4IKTPfoFH+Sd0el/F
# DATA gAeZc286jAEnM2GdbgXNejqBCebchRP9i+c/h0qgMLXe1CqDQ/73UDrUX0vUSvyIWwNZU7Dqj/HbD9BUhjyc4gmQpask6rMPKAsL
# DATA KKP/USQUxpZ9CmsXjUVYJ8BTgrTZAN/tbNxWYyOW4jnlSymt/O8R3XHJ+A+URV86/POM+I83V9ZW3/Txn1evvfGX+I8/bfzHjoV5
# DATA RqB+yG0OEfikIQ/iP7Kb6vxR9PCwO4ZUPNo7gBm6bL4YkBA1WmdPa7KNP44UffWIEMy+9mcfH3IpUyy2MR7XZbG4rfrKJHaqCOcd
# DATA yRgxE9yFEPXu+JzMnnUH5NWNai2lD5fT2vcG4DIL8ZIgnTzSXqzkwyp1hamIFtHWynLZYpk4kbH79dW1A4MkezQYAWaiBf7AsFPr
# DATA w0aJnEQAtEFUDGw0Wap5SvqoEHJQ5oDgSOadjXc3d/d2vpu6iC4Sy4XKPekNDkvpokZzdHwRtR9FpOLLVC7s7A735YaL6vogvRyq
# DATA aiITPE+izHeh/ttbO3fCFKxQUiH4pJmz0PWKHGQjUyfAMBdMP+CWdUDRbrXmfmRAo/yp8AEPUTblmtkmDZeuaDbMZtDTaA5hcv57
# DATA 0nrcqUatiBSgDy8CtDZvsWgDHyiCBJlBDtA6DBu+1SeEHpBPpvP00XLhL9TRYv6e0eD73e8jaIxAd8QVDK6/UJhg3/FVmanEXbhk
# DATA fHBw6+iTOHCdm3F8CwDrvouLetd1JqIydKQey5gu6hAemq12Fb1KrVPl4Dh51B886bMy/wwV/kyvteO5kuI6T1tHesXqNFUkQngQ
# DATA wEUbwSz6pueSheRI3o/RNg4smoq683eJCw8o3o6sDlv9TNDavOY4EpKmDSIftyje2VFBtdIQXxEbLi2Hybrx46g/ttDkd9uZMEk4
# DATA loIcs4T2eC67Lsl9tZIzAtu/rgMYI5mrW9VjCBO8WFmtXF+bpnF3PihpXhJ+e+v+3vrm/Y0dQOnbuL+35R4kZiFfxjKyCA0gp101
# DATA PKR8s1K7Go/BE0JzshOwlEPxMPyrO1gqfDGm9Dbe4TOquIwT+TSMg0N+A4mVQ7WEh3WO6cKejpdwj484wkNWFhpQoRfRnsNioVol
# DATA k5iKubz6o4AgosgaZLNSiyGMRNg3xR3IqC3PGhDRcmjlRnkOaFc57tyi8DwihywTIprG8KOifWTXvxw/4YUYgAX6ZbBpH/4wY59N
# DATA o1BidtNG9Phxc45MkuBFI0aQa8OsCcX4G5wMSx02Ju9EtJcaf3CfrAiLWA93NSc+KeqaTCOV048geWCuVTI42kwQN2bWAOiCrKjr
# DATA uew18rgeVJFX9yCr6eyHaV9qdkPQMczEwJx3a1wqF6GjzZskoRTLkiCjy2hkyGMdbgfvr0AW9HIxYFrxAG19Rx0h8eyoMZ/ZObKR
# DATA lueEdSZit+/ygQeOgx4H5imGAN2opj6XQUUszEyPOpfONcbDMOYlKv6ZbawwcAYS76blKZ2wrBB8ehgkU85hEFaRO4DXCwVYR5Kz
# DATA CYBYfpQyNh5NWN6CjLvRJgiMPfT6Ug8ChDzWubjMmRmiAWOapN+NnY07aT7EwjwIC37Qzjyjtrux8+3N2zox9WtIkrNE0UDk16sU
# DATA xKZZdk7+CW5vagiSQ0hCjqfucDLOagvBgbAf8aNajJ0SBwHyfexomJ1E5wq6B5845mx33glwQ8N7M5ZMk7JB8pYIQSHyYnZsoEXN
# DATA 9mROEA4LDr7P+wlbyoeNviaYLLkBGNZsIaTUeWFEYpAbXnoL39AP8b10cSClV24rZqApWpHr925tvvtg68EuTcne+s67G3vp5eDM
# DATA Rd8tpvmy9nsPaJcHC4wYv1SEzmYaOgwaFYZlf/kWcrtTo9ybAHswGOmF0Z+cHRo8HBS1kY4kHMPJ4aJQ+00TRaTBi4adEYRNZBiv
# DATA jcGRuCnRpw58FIy8DcpRTAxkrMHYAq6bx3K2vBcT875kEe8q4p0jwrwM2U5sq0AgEpUxkZ/LPQ1GSMaPygxp46OheAtm7RCg/fsn
# DATA FmFkW01fWqbYecw3CVCp9BI0in9mjHLiSBSYANe8AGpr2+iCOHqoUaIVMBDigcYm6B4fd9DRcHPbln4G7p+AK5C0sJ215D6eEEqa
# DATA gXWslre1rEA6gw5EVkeJBKTbyt/fVtILtvfMAF6h082vYJakNaTwcJdVYyrCZ6THdIiHHcpxrt8MWQf7mmyh+DSXhnEBF8Y8w8g6
# DATA xjbjbT5bauB4hfjcoRucoCmO8DMz/lTv/vJsYXE6V8JqZNRNqpd7m7v31vduS9nmtWRP0UkzIbDBSDup6aqePjivHneQ9I6y0+4Q
# DATA wDX6FN2YkNFJjTqFygcscey0kKMaPTPsC7GTY87Q3lCfGElGBV4dLfAubo4HuFrEUpiVezPYFFcARVjIgRwwyiDW/tR8dZDJUxXP
# DATA npWXe6tBCmZxZzDyhCzTllcuibzgF+Xx2Ra8KB8PIcckUi4X0booI8oEU6/uMiRCuYJZgFZeBB1sFoYX33Sj6kIQZgmARyuYbktf
# DATA VbpVoj+UyIFaJdO6uB5S8xhCIUIP6TRA3JKZUhpVXoDds73QbJ7W4AubozyjNCcSzmWR078vx/nBXrDeTC0F2/Y4mYc387Ea5+TG
# DATA XPPSFWIOKKaMhrFHopS0Rvl4Lto0Hh6uodATCOlBRgXNzcL9YAuFTu9kEBQ2OyF05bSBPolVbNkwrdWpoFEzYoScdeRr85bQkofZ
# DATA 30xgiLNYXWQRLicaaiY43OCjick3OCvOw8vmyLdBtaWTtLi95zMn2qLZJ89MRdhc6i/by4ppUDrptx63ur3WIYV8pQtxEJaXI05W
# DATA 8hSaKbULcd6pgSm7iqtbh4NBTxrWjUhSUB75Utepn/t1JeAdeIZ3LNU20z4qKtYqLnOX/TSCiSKSLZ9zgJrBg1nVEVYQOsLpQfCI
# DATA OBsoejfod48wgRC/TxG6p4BfEbz0TVNELGY2vl0uvVVcBwVXOvRcEnY66Npvn4cbpmy5jZF9GxaSG0cTfF+wM236eBM7FUXxyumS
# DATA U07YDnffFzTDjSMqIscW+kMH5hSqV9fvgMZAa7DxVHUU2Ma53eqsrb+7Ze4w6gIDEQZDYuzELU3NegMlTs+vr97a3thZ39vcuu+q
# DATA refTs9vYE6fFurU5LSL36SLOBGJQXObE40gO3AoxJIDq03EqWCkWAGn34NfK8rKJfzka9AajSLFlYVgVS66oraYVHDpjYm0ibdQT
# DATA pnU+5ZDVCkfzlQbPuGS0NFXSq8p4i8hTWqj6xkpiIU0faPD07BosE7RojcGHBsAUumP1HqsDITAWALs6Q9D4YJIFreybxR/82UK+
# DATA uEgvFrIkBuIijSoRkUu/PNPOwmYO0Bbsbt5/V6O1oObe6PvkUmR11xY6YILlqt3qgZGI2U9Ai0cACZwn9sfJaonW6o5PW2OhV4Cp
# DATA 5xLRvRVWAakkTkAVhnqG8ZNBVS8ICz6vbS0tjduJS6LGMBbt9jkiM+XqCkBWuq1fI1ZFtapJAdcNwLxQz1LNr9IMOF0iHzw3eXSM
# DATA BaDjpmOScWVIzy+8Ya3oGl1PAvjWdCbiB+k8s6oA2jYe2yRFap0tzqAJGSFUiYbJxcM+7WZMJMJjEsiT9WvLK8sP+1OZIOlsoIRS
# DATA kYQ32+duUV609LFa/mfO2OGGBMU9Y6kKe+hjnSYP3dSpAIgj4xMRdKxpLlYqv88hcfgFQRTwgLml4nLncpc646MlfG/JLhBS0cFy
# DATA oC6WJZqlWTX2N5juqVvuFFq0I/SCVrSroTOWQOV6Xiy5NSXqKX8pi6wucsriTtfMOb9g4/DAjtGy6NeaMOj6KF8tLbMOlJA1KTPT
# DATA tOwB+vKXjjCj8+1VrPZTdyCSaCiHgr23vtu8s7G9cf/Oxv09Tc+0NmcOhKi8ZFqURku4O1bj4EbxhFqXgCYysuolUId8dKED616r
# DATA ExjygNeF9neDj1GAM560ehyrS8c5IFUo6j1QMqcS4G4y/Ik+JRM1QmrORVkcB9JudZTgkDAHkZwBqDIpVzIQAxQhb/UTMYh4Dlul
# DATA saET0OoDlACPTej2voBMlfMAow7FHOQWoxkaKCXtD9LLAyrZIMPiz+Z/fzb6Uu6XLv6SGwBO526uL/F8asArOCUT8nGr16QG+K7E
# DATA olllsuCYa+Ox5UG+mhJNhECOb7L1Sy4qzsqrF7Aq6tKpmPeZ9SaGN6bl2P6hjUVZTdsOitWfHnAnd4nMDcAjksUB7LkXlVUSsZTx
# DATA EGMPpSdndxQsZY3ig/kNUpNsqNPk4FsfR8DMgwHOptDfdmvcCRZhtDlBKI1Hdy38ApcaGOOCSY9qscPhZ/l4MTgKL1nO6MyID+jr
# DATA HhbIJ/ccK14iQ0dWf3kuw+POxr0tJbujVuH21v13NnfubXhRQ+7mdkvV+909o90vyn4SzigfVI947SKwfhDic+BsZcO/atsmI/IX
# DATA xs74LTIfI/utDeH6LsP8n3Ry2kjG9TmrEo2zpKGcD0ci3tckp1yIo+oNX4CqkrM1ok6+JsGFw7QAhIUnT6WKLx61zI1yrkMwlxhZ
# DATA SmHbIdEG8BK4sOUKF4/BIBQyuQfRUQe9R9FijuUq1EdVJfHWsmfDs2dkRVAlGXFDUV5+NlNGaZk6BuwIyotJz92OU/NZ6C/RvVyc
# DATA dDN/KGbsb5+/uEQtzjh65fhwRTmsSaQK8VY0jaUVZtywC4Z8iuYu90Eq50pgyvCSaHXwbNT5PlflnCTPMxRblwfqKXQ0lyA+xQA+
# DATA bgp1m79TA/fbVW8sIqBLbM/pdKqPfkEp6wHKtyGM9cTkL5MxnXlRRJYjnpMbd72mfL7cLNEXDF1WrNXjLmWtibDqZbceVjRJdDse
# DATA elMMUET+HQsNNLG6zjtSaWH5dekaSuDQEk4uby4rTKmtQnm7lWXsOKoXBOMaoMBzpK5hpNU16nMQ+uBIGwcyNQ028Y9RJxf4J+vp
# DATA yffImcsvo3zZifVdszW4Nttc5UTPuSs0+mwSSyBvYkF1ueg41n9s14lzxPATZxzgHkXFQHBK1v1BJ3kruf7GG9euX8YbfeP+twUv
# DATA ZJ1SwZOjC4roXmmU/l0Eb7BREqEB1YPXH9aKr8tfI3zVIn0dQJ3V7gWhnsZhs+E4bMpp8hw03cOLANJpXWv479sPdveauw9u7d7e
# DATA 2dwGo5ja2g92N7hvoA6hoildfdnLMyBNZQyFFKYToJPZok04CQP+FzeozKEEpAGPg8RHLSBF1vA4irM/wmEoDDUiDj9vn+cB0Ltg
# DATA WBbeWa86v/7Iq4VQ0jTr9mXudzkfSPlSLipIJriH5EhHtyt+V0wzBRIzr6erYFfnlV6W09zkDQPuDXP2KuocOBidAGJc3/rMEzhZ
# DATA TeDxyVPfSSX7sP166e36w5r6W75YrVxDHzW3fXTqzvGdft8h3OPJUBHzs9awhOPhla0dUmsA4qKot/d27K25lAd3tr5z/92d9Tsb
# DATA zVt3t25/yygOXDB14nZ55NGmMh8U7jw6/j8jvb6bTSC03/h6f582Tb8MTffVNdeX1pEXabq/JNz012BJUtKDrKNmUf3ond9ERlCE
# DATA GGgP+awDMZv0dNDrQX0JGRlrC//L64FjWu6XZ194+RaDK1osXo59wVH/v3R9eMihLS6WLlJfPa5hf/IYDDfrH1hlZ6nS5wfNv7rS
# DATA /QoKxUIV+ZcOJxz1hpqFfy+9oS6nuL68QvxF9LRzaytDcO8CvVvoSx1qDh1FufusSPPOhRuNukhaO8/neVaCSw14jm1BAGC9gNb8
# DATA avpjDVjOtXiZVQrhv1+GYviq0OB/USoXKJW/atz0XEInYdOPOIeoq1rwBCkb9KNXxWNms0jDJ/O4xTQV7HetzcK+eqLkV1e2gUfC
# DATA 3zSmNAwlPowCN8oR8oVrkDV68PS8kWpEg3Q2ZMGcOAUckB4LRl94WTL5XEMfy3/q4kfMEW44V3rUHOlvc2fjNoSuo/F449723ndt
# DATA AFVXxwVfQonpqGMN66ZjyUVnFF+PsDlWU831vECbUUkK3nrGOd4sHeN8N58P/M7W34hCaUmKuFYdpBiPGHTb0rDurLqnfnm5ovm9
# DATA 9U1QNv6XB5sOCstlQPFIMdftjUkYwjyEDVVAjRHgtHTJs4jqTD2jOsAPVeliikgDEBG1yMEUm9PLXnYrCmdOh12rmftrtTqaG3+z
# DATA ubu3mwZb0ckxlq/a4lRjUq/VPXa6H65y6eq3bp3pRx2miUlrdHTafdxh8ZXL4qS//aPOTZ0HS4T1vpZM+hgx3bE1dgHnstVnB+wO
# DATA 6GYJ6vJwBNveevdxfXl6F9OwS/pWiqLnUsQEZKE4Otq7A2RPxoxHirkqpI4foo7nhB60JS2nTxwvEPt+cdcrhMPTHDwSI2E/PjpV
# DATA H5bwO6O01voSQVdysq+qtg57raNONN1e43Q8HtaXLDpj/doyxbjEXoZp1tugNqKdli5pxZ3Lg4WmqYpst4NEceEG7omwpDq4VKg1
# DATA n1U5MRu6nig2FXUkkKpT2oFNVeUDL1X0EAFB1PvH6crqm7Vl9b+V+gXcnaJvfOp/wClY69C2S+Ze9UsanJxQRONF2h51MSsK2Tyq
# DATA WtEzGGol4UV61npaBZsbvLSyfEaKxqdV7m96LZ36FVCw2dFp5+gRljBWYwddTW/fu4PcpVp1SFPx3+MOaJpf5Xm3gwGjsIS2G8Ur
# DATA L1GZr5Zrivr0S6PGWzrOFDMzjGqDR28v11fK5doRKq5LZe8N9YhDplWBiqOBpr+BRJ4jGu0NRduASqkbK6sUhTYaN4edUXcALjTp
# DATA 6nKmupx3uMKI22S6+7Mj+kG0o5+uwetCR7cG3gM0LeE8U1isbRofB37b+Lb2kubYa5PBx1GbkDnL+eLCfKFaMTVfQZMA7xMmyzoa
# DATA cRe4ANs0n7fI08g6G8kGVGg2+2oBJ+Wgg8Jep0NOHCJAN+urijsZdvuddA56YPIww8C8u3Vn49aDd+HlMzVyXRDZxkfDxnKKA6hJ
# DATA QXpjuX4Dad3a2rW6+n/xc2nSHuIC1lEwMVJjRwj9QOqxaJT6aGDYySqEvtWX4F97jwalvsR6XsdjlYZLN4EGyZakV4QsB+9NZ5Fj
# DATA 4qOqmo9ScoKvvv9yXG48wuX6FNYRQKEULhIvMNv3/A3nJdK9shOmTj+mLwDNkesFJJVphXrQXL3+HMrT9mxlgpbLXLVmVAc1t81r
# DATA 6kczEJqgCyP1J8rWxtypTNFWsUyZlzGNnjCXXwUYVpN/zZzJxkEKRRC1GDgeHCXEKkehIWWaZJ0qEBV7RSURz+MHMesjLhaEfVCY
# DATA n43zwWF6tm1UbY06auW4QdTSa7aUInOO6F+52T6cUXGHwHZSd8/kqrPwDngA5KSpK8+Vmc66D14p1xzOjR8Zjv4r7cnZMCtpWBZK
# DATA EwZIKsCIZmpRNFvZUbfLSK/FyeL8iS+oz4fUNPVypjKhDKEUZSy5XqFVYu0VNEigOPptgZtXr9gucxlWHvcLnHMUZOY35PGL26G3
# DATA qN97rVi8XK0mWVyFNGR+U4SHmdEziIEEcTRFYSKSy445KHgltZVT9KnQWRZ3V1O2nDx6cmJVzZgPOWhING1ecbWWitY95gT0ysVV
# DATA izF1dKIwkKjf9Ad5ZlMcsh1AGxvHt5xmlfP3ycWjzjn7cWCkgRMPESWf5ekV9o4luCGcRaA0DnthhlPrj/eXD4orFEQ9j/EXy117
# DATA M76M2bJnqN9VizWRN08xRzmNe1K85CwSyuycjzDHkH9sgnBXJUpFVtvdfHdvY+deJbHX7z3YlnmL6D79KVEBlaTXOjtst5LFZl0m
# DATA MSx/9ckllbSQYYYbHwQzJV3O+u3bG7u7zXfWN+9u3AFe79kvZF5pm4v6s2d/eP4zTsUNOZ6ffQZPPsJMjn9wM1Q/+z0l+Mbkkb8I
# DATA slG+t7e3vVtVn/4G0l0+/6CSqNcxFeXzH6kiOXn1859WEv7sA1Xhz7zaPqW6IPflRyIpOFzMSpwZz2iJzf/02e9sesrnP6n5Ygp6
# DATA 7jbfUWPVvAfOvbdAcbz57fW9DRy6/0fV+vtnf0jWtzerTpugg6rdv8W85ZwG83MYAUyb+VvVGkjKiRIHdg7zu36oU2ZSJ5evLy+r
# DATA pv9fJv85jzhef4R5QD8PGqwNE7bh2ND/Gz/5rRoRmBBMvf4TNbecYJba9zG0Smdd//u8nlHKdspHC3lpuVW/wv5+on6uXE++1b2V
# DATA 2zCjUYy1yywRb/J/pX78Dtr5I0hyXsGnWP0fYGF+qq8/4mHEBVhPQM+V1ZfYwajztHU27KHrT9A4XKHcNGNFgfb9C9WgWqWW6q9h
# DATA 8bgtw8o+UaP5I6z4A/UylqXmjT/9A0/XH57/FBOn/t5f12qN/jv25KfPfqeK+T2ORGsyHshWTj2Lxu45ZI3bACqjNzy6UoA8jAQB
# DATA JMZn/1OVjDldn/+3+dK0hylmC7a1+vlPybPfqjl5H9f2H3AmKKPs36v19Gt8QnX/7Camon32GU6vyWz8sfrzMTQBnqpnalF+CB6p
# DATA C/9h8n+Oe19CwtdL5X9dXV1bue7mf11+c2X1+l/yv34V/7366qu3O6MxxTd1EnYAwKSiaDoVhiWS7ztPkh2t5dZOFORnXJziFQoi
# DATA 4frFk7YWpmntnA2BPVygApnX1AWSKFRx06PSzaySIEPKWiRwv8+yXmkR+LoKIoc1yNgK6dKB7WbC18jPnL69ofg4oGaKjn36/O+Z
# DATA ggH5Y/rDPA4cwEiMv4AX1WlDbJDDF31KubTfhwMIydtneFx+lPpwr4JdU50v7afcE/Dxgb5gHq7hZNyALkGe1+EYejOYjOEmafMN
# DATA VOQbwqSM4JykeIPErAVGbm+EIvCUNU7ny45CdgU2h63uqHQ6yMYcI2sfVQiRX05d1kiNrw15NugvWaGpvga/j+5jcrFHWUMUWWZp
# DATA WxUsYGiRHXc+deMfwEHkCEGI1Gk3JDQQvE4f9h+OHi6nM+28z/7ZMBOwSPjY0zybOqYTZJCAIQMWlVkydZ6r1fLf1fz/AywGYNo+
# DATA xk/UKglzrw697I9hXN3K8upasoh/Zjb4l+Ha4+OWV7BpPBzruvGqb1XNyiF39Klk19Q5/mNg2JJ73Vsmfw5k0EQvgyQb+OQIpr7z
# DATA /QmYnsHxEtzTJhkDwWloQNA/whqqmQXQpIWu5hh/gYeUukuS5eE55Korm4l27pI3ONOB9Okby99AbXd/ADZE+IV2z04fdZw3rq+h
# DATA 8RoJhalW92pLlbK7e1e7a2dJG9NAIFBYN8MIHLDDjxmM9qbaJiDlq4ns/6AzGmioYBgE8z7tWJMF4jBtDzoZBQ3KbZNqJ6OZPYG9
# DATA o67s5nP7UhyyHfsvpJTRZQRc2G+ALMIq8vjdX8NegLVFUtJHxW5RL6N8QwdgHHCXR86KkkOF7JhhTIDzTGNlOhTkpc7Vi8/TJebK
# DATA lStBtgCumWQ3EB8/hlNKjKiiBurORyhWfBTw+3NQyq+kFZylgXiJrEdLANgHcIZ0+Ae+piPyBzrG47UE5klN/BAtvMnhYHya7Oyu
# DATA 44bduH1nd/2mOqAYd/4M3G/w6dmgPel1MRBdkKvh5LDXPQKYwGARqEeKjDnrIUZvmJhFShrqz9UjvZ6GLcAPJ3tMltV1mZpeWmc+
# DATA 0bhXGl4lhbvyF4F8b88NOA7UNHyheJ8PkdkBKVb9Iok2yvQ8/5H2cYJMo9GBsrsFrVttCvvzxqrW7lCGeT8/gCqrhq/BJDfHg2am
# DATA Xuy3sxJWqEMXG5RxY+UAohz1wqj1B09Kem3UJuOjcg2uVCvOhqUZtAv5vc8S1GX9nkaBxeYY4wfy738HCRgPVEW6nv8jivkfPP+5
# DATA m1ogcgYaB+3h+WyGSxgu8ngve6xejY3j6eyAJYJVuL7D9FIKZWQGZEC8PDcswrN/paFDlunX2KjM472QohjeSzBZRn2iBvgDtYb/
# DATA gJqG36dB0yP+djEPO/FB4GMHYwbrupRCfO7RqTpxasPOGan/u48hCxZcMoPSa9skD9IEi6UI5Tcld9K1LsFjeSYNL5X879n/iwqk
# DATA T/Bw/cRh9IABdPlZyRL6Y6o+/yMKN2ZUkU8U/KzqoIYdHTr8GbU6DLuLaL1d0B1gINUA/UDteRwkogxen1vjwVn3iOvyB86U42jS
# DATA WXk+f7Wqa35IV9EsCRggLCvLiUgZ6iARTg3hLr38MK2g20Ovn36Eh/sy+gXo93WGAZ1NjKB6INMAC+hqn4AOcQh7vCEyByO233H3
# DATA aSOtjXtZNY3MJmIQDrLacRsof0lWkj45TNEsoUh6p3Xmp6KAe2x3Cjom3jjuTbJTL8QG6svO+0cl/Y7qQ39QEpGSg8z4u9KkY5Qo
# DATA 7UuIAuqJLiB1Q44xd66YRhssmqx01hmfDtoVDiT2YG1k3k96wYnc0Ok9hURoUxBLofD6tRtrkcc2sfCbbxbR2Dv3d2Wb64oWqKP8
# DATA t8aAIEQ/oKab9zcN4UhQ767tD0gWriuZyoMHkaqkGuEpsC+PRf8wwCTiUyIdcNL3T0rpfrufHTzsp69jN4VxXc9Xp4dpHgFZ2viF
# DATA qW+Mn0xndNYdU1hr6QKeNI96g0n7uNcCi+ywS0bLFCNuad7IiGxeYhR9+vbkaECf8Vdm6nI+1bjK1E5CcfYb0TnjzAGRxgEbKNCd
# DATA ZW9EsYYfEjUB52feFhksH6M3gRpRIHF8MeILA4pNhdQoC+6MQIln/wyLA9cMsPy0itRx8fwfiIGHw4dV+L9io8LnLNCpNVg16rOP
# DATA yDoIr6QeiIvE0NF9ZWiRuVmKf8Ml/cmz36nKwAr0/7f3rcttJNmZ+5tPUa22ogARAC+i1B50w2qKhNRwUyQXBLtHBjGIIlAkMQ0C
# DATA XBQoiiNxY8cOR+zEbOzG7gPY4TewJzzhWdvbz9D9RpvnktfKKoAQ1TE7S8y0CFRlZWZlnjx58ly+82tt1Pob3PCMxWC1z+xuEfd8
# DATA i+1SbRD+VvnleDAqnITvvrsB6+sb8IAlT4KSNfwSMruCWEWY0I55DXhzGlIbUlApkGxnDkHQp4SzqRgsS6GNAwWtGMFVFiiJmap5
# DATA +ajcWf5SX6mYiEydd+slQCzB2maLL1kqW1o0mqefCc6ADoQhOx9Tb8Nl/Lscop8xUr18ETP3Gs72MNGQW/aeqytPFZdfV95Ek5Xh
# DATA 4Fjn11sRl1csuTCrkCErSvB9xUWp6WU5U8voXB0ui8eWw7SPtR2iYYD5u9oO491EzQmpo+fXnjguPsFyDVnKMnAxom6stjhvd8sz
# DATA sxEYPijmWcN0QJd+p7RG4DQ3kfj5YiFg7XaudoeENTh51DuPy22ZhFzBiAHWBlc4m9c4RCu4DroR/DucE/8amd2/W8yO+0RiAXU2
# DATA HbupNdpYIlejfYvFpHggWnT/GY+ofwg2t17pdOkJGpLFZnYR98QBEbIDo87kbdw7QKT4/3Q5Bvc0zKjeR1e13pR0M8lZPBzK+6Q/
# DATA EYJgdEG7GL6Ijj86OgIaOhKf0IhKekAXH5jXHsK1hw8lupCmD8r4wB3mv2FxRdLCcigDdOysY2H7cDSYCllj23A1bsa2Ia21c2Ce
# DATA kY9GmydClqlxNEV5DCJizA5SAYcicmtHo28j2C28ZZE3WZ1hn3fRnxY48wohKTkbi3KHr6Lku9qqkO6ORmr0aw8Eo6MxXQ4fHIGS
# DATA iDeqpxsbCwwQLp65hkcOjDEoYl2JQYuG8E7tFtQkntobbUVCDu9Hk9qjsvhfsPq4tPakurpaBT5lvXpTEJbYN38V97fjYXR9EPdq
# DATA j59CqX1QykNO5WltKvZYrL9Bls0OjW7cf35dw84namCdsfD4ni/kdj6Xx7mM0yZv8gtU6ZlyhgoiRodowA4g9d70TMVBTaQka7ga
# DATA tg3falMrLX6y3tByRaRdHZ3JKX2K5bedMNaWCsuAr/jSJoD0Rdote1lZ49I3pUzLgUk1iYKWLmlx/ssJDor7FCitLvy+3o43oRpw
# DATA wwvV1XZFFWldjiqWviuqoMYrsqMkoU+mC2PK2/Ti2vJ5laq62c2Ynsa3a9MgIaNp4wQaVaQwKGrmU2hUMUVof8VO6BcJmuabsKhp
# DATA 1r/waxB5V61sdzBuatMWX2kn9Pl5MhqbgUJJHqoVwiVLnxUzSIbXnS2Jfhp8HccXaKmU2CCB3IrxxA2JMke94SUmqAfPjOPxNEyC
# DATA IUT68oEkqaRTj7bD6VBGafGyrBqDaa1miqbilzKN4RUtFBR5yVtlYV2aZewcVLQR8DBZKG5+ZRMJukZmw+kw8SRJZfkF/JQIDMl4
# DATA E5RdrLvQZx9+ildmIfPC9z/+LR0ff/yf5JiBB0w0zsMBU+zMDq4+eRGLJttWZzrFz81b0JPOHF7ACznnwtad8tO1FCML+e6C9f2X
# DATA BAaAWdFYRUYiGaR6H8BxxeAHOo+PjO6Pg+H4tOJ4XIc//J3h2CJGtCoOUIavIMJd6YResZttlnW7oekSw06A6GLT2G2UtEOF+D+b
# DATA 2yEkDl6kZuQnyXZkXPv/yO1Pu7+dXHVPL6NJ/yN6Aeb7/62tP3m6bvv/ra0+Xlu99//7ifz/WjHYtqPJYAjB1AkYWiAZF2N8HL74
# DATA VkixmKKOt6MS6d8HI8rkBpaICWVtvM5zATzpjabDW/j7JWeX04F6gMIdbucByL8BF0QquNBhhwJ0ZvjNkduf3ztObP6Oo9zGk3yv
# DATA i3j0pvbu0aNxUuHANLG/7mx1N3fQDX3LUPjO9LNrkkejsY+Bj9g/k1Xzx1/DaVtHFfxB2twwxEH8+z/gonhETOvngYefngih6wow
# DATA YH74HfjIoI/+3/z438OZPnxizLrGdiihuyW819kAzZTGIO+j7cZCrrGhMtl6DU9WriLBoOVgP9lYnQesjp6cgrJ6BD0q5qR4Tzey
# DATA tppKhG50vkWl6m8vbCQoXdl3g+HQBWnTreSZ02xDGp0ytYJJ2nEytdNp+sjXT4MpFq2vf406dCCHf1NBN4JMtIX7Ayx5YpvxWvLA
# DATA qEbmb7N+fOP5rH1/Wsa+SXw8Hk+7kp0WxLCVWEXWm4rjkVhkQqIZQ07dGqtcUqrfMoy1rAEkoMvRYFrLVNCkHkTsRa3K0pRH7d4J
# DATA 7f2r5YcxJwVy+3O5V5xHk+9Qs04PEawCBayHrHlsIRKVGO4yOnj9cnwsFrh4acC9uhhfiYeG4ySB4RsOvoulolKcxaaTaJQMYNvD
# DATA g6WreRSj+OFqR+YEMHWlLBUZThQuQmf3Ft0QoyZ1iNAfpSq0EuECGn1/QKnOpmd19KNAnCWQzGkEi5Qr4miUqTe0azQ1hwDYxKMi
# DATA KnkQcCI6sRdGx8PY0DLuj5NpbeUymawcD0Yrk/OgfBKkumE1k6WiQ8iV8iUcgAw1naGtRI94Y0GFlJdUkD0c9aVKLFWKuhzSWqpg
# DATA 8lBrnqiXgLuOQpNsVfrz8FZGMZpVJs4ZrACF8rgvN8hSQDGnomschhCL4RPncP51dTbondVIZqrgj5KUyswUHeJxQu2CkzNLQ7yV
# DATA Ym1BTX0DgDN7TycMzpMrUQhbKITih21mEBdSOzhXaG/17NBco7FGPifRKjppfzy8UUFXvgS2A0Lyv0wgWScNuWWhyGmX+5lTo6c+
# DATA H2/7B59IxY5P36Ng9Xt05CNO9v3nUno2QtxgB/4N3OYxlLYQNbx8oSzGyCoiiNItJC7ZMyErYw2JKjXjtThq0OHa0lH6d/haJFqq
# DATA i+C46Qbr0lgox4/0i/QHSTQ57wL/BQ8KJlUkOnsPLPo2QYaDFYsxQE2bZ+vz4gIy698UPEbWL7O+gGwBOjdQYUghuBJsBiDHCQ4m
# DATA EQgngGhIKdVHPcAfZgd8g2X0XTjJ3ng4ZMSTchl3Y+wb8fZyWbAforkaYq5pRifu4Q4DuPwXgnqua5u93uUk6qHtYg20ZbRwdIpP
# DATA yak6RS/2vFxpxgMwEcYTs9ZPSrYxNJrYWXHuOxfjdXUWj6y80eBfbmgu/Z2xe2+aVHO4xJyrOIvk9bJFt3D2Qv4vYvH+AUJKf2fT
# DATA 9g+//zwg/yT0af7f0gKbKcIgP+Ab8uL3UAWYScEpGj0gLaBHtTIKRXu8zC2J8XtwDQAElLLpfHQQpDnRgLzPMi2FcIYQB+ya6lGz
# DATA DhCy2/XmXGg8XA29UlLhn+21akcB9chr1bUOqF0BwTrskB7RvG+yTFkrs0wKFuNqVjuO2XyW6Kud3v7xh39CB3egorRl/F+Vlr+Y
# DATA cuMLV8S0OwI6+BBUhuPed6lzGTjCIwLFiE+Q4tded6tZ32wF7+lHc/vbpvy+u/dib2dn71tLUiFkbCE2Ti4vAMlEwkucTOD04ji2
# DATA Ig61g13R2G2Z0BX5UBZpOAsJsa2f6DZe7rpK26/j6+OxEI8asqeFYj6ixq165QfYMEaFDd+zj6UwTcaYgQJMnDbFxQL8U+IrkM2o
# DATA W/95jmY6JQtqPKkPtzCkBrOa3ZFQCTEo4Ij/MJz182z+9z0iDPz4txhxQ7zSr40KbbOHuZwMw8ft7Bmp/s8yOZitKqODabvAYN7f
# DATA oFrtt5k6NM8LSoki/GOzMVASiHJ0Cq6IH8kEkKv/X1t98nTjsav//2z1Pv7/J/l8+ok6eENaz4vr6dl49HjpwYMHO5wPFbJsEJVI
# DATA J7UKrBPOn0q5URE9HNG8ADN8Mr48PUOJUEnNcxsGzqIEDALq53nUI0sBgKmgHgO2HLoJel9AO2lCTHAy/UqwxuFdwAsIEVJ9B1er
# DATA KTWbbXwAnmFZG7Cxy8lQtFWZUO9km9zZEtyGjWNJdYB4j9GKdnhA8E/vHcYTXqKUn2hQZ3t9F139hSRn4I8vbe004MSEc44Jb0nl
# DATA IiWMcGlrb7clBLF6swvfmns7WNwWQ0CZOhkPw6WDevObxlbdPoMxxhhSjFIjLh3uNlrd5t5eS8s2Pmexpf3DJsDjQya/jDrLb9ZE
# DATA y63Nl/UDDJFCLQZnTuiPr0aoyMFIKcrSxriQnAidc+Nd8wPgzDEYialkFMnBibzTE+Q8Eg8Ul15t/ry7s/ey+/x1C5s0wuaV2pbS
# DATA s0zGp2KsE848MZEzLQgKIPAQKboUxG90eAykIobwyeQsOAYTm1hHYhwuqExSYuR8KZdKMTrBY3J0FTAZykhwmYlYUlwNlJrdAaRM
# DATA wwusjKIjtw1ebyUiRA8XWD4KkpZnfIXVJnbSacOFQ7TXgJzOn9RUJ6T+QRfKUtgY9Z3GMhCaJxpSA8OY6IQZnJ+GZp2AmuGICSml
# DATA XQHgEOkmnTnjZbN+cGCL3c4LU/4BOa+oUpDv5SStG41BLYYRoPBPwXP+ltVYI6ytBiz5ALTw7nj6AsjBiSYzKngX4iihfw6h1uNf
# DATA VKfG/U0A0RU9ghM1UhJAFSMKMUO5JAZWs5EFWjbQ5to7Cr0AHhLMQiypGFM8AA8ShJpIbcj5+A3lxAadCpgPtS8ULLwrIV8mCqmA
# DATA 5rQCBuS3BWwJImitq7JTxfTbt4236LRlwQ7mS35bWC3hVJTdd9Ej0ymmqqwQZ6G+1HhE7cdqolZ6EJcxJZMWowAhCkdvV1fLR2/X
# DATA To7efnYivvzspMPpiLBsUZxB1zmHs+4VTwz0u+C5uhy034WRnkesCXCqiYlQQfEb/950iu3y+kbVbYMzfMFLi2ZERUu+rFiYL4yf
# DATA 8fm0Ui0udyP/rqrDcNK8wHaMx3IpTa0/V6J3vcxeoA7PMxaqfcJQZwrTw0p6UxWz++hf6Ui24rpDxc56UtqLi2HM0VZ6wC7OELeY
# DATA vT+5SMgDDLs8ZbhVHbFZb5qrpqzcAOcNvuG5LJ43WfFqornEzcqIOgK5/GCT5iqtRen67wHUJjF1wbn103hal5dp3No4btWONwWa
# DATA HgJ0Rynwck8uzwuq0jZW2MmtWzCHwkweUUyn8UPnDNWJWrBa9bp8uHPFWXaGaFIEy4vymesPkothdB1EGFEXAfh58GA1YLCBBxXX
# DATA /yCfZA2vwFSaSCGqGqSsN48UgcqNpAFjBTlRkKyXgzV5Y0sMPfAdSGFP4+qDyEfSPZgiZL1VlpNCMfnjARubcFOmxJMe8be11VXP
# DATA M0QA1LlHWGbFbMXtUmJsi8aS0ZcJ314yy6qfhTqVxsPoIoEcAjhb4iGLKgtGOyeCHJIzaojkoSsgQm9PcPsqpt4AIsLPoSNNSV1G
# DATA u/KSud2nt5Qbwc57Q0EKljxkOFlKZbEgFmL8EuFjOD5lps+eDrznQj5CSAPiyXYnuQrCzqfzrc0bXdkYoeO9QvAS1ela5kh0dLvU
# DATA RiwDmvkcVPj9Sd+vXv22ube781rqVC1la/3nWzu5ytYUQoESxYBPpjPQVV3GqspDUC50PpXV3Z0qPXkVgiuSYZfqspW8j/x+9R0K
# DATA HvcADsgyVnLKLFQEMSK9IaQHPem7flAGl9Kq1ZM+x/Wn6bKL1F2gAxCfrSDOY6qDQPlwRNJOIWyDjEA5q6aTE9zBw4evyw/Pyw/7
# DATA rYdfVR++qj48+KuQXPsqp+e0x6MY0UGvBDqHQDoa+EVNkZdEqCJqw8vpSfnPIRoV3jyphezmIWUQ7pP0PEq/FqMxMaXFxvq0iWYu
# DATA qtzc36/vbrukmOlgpYYbNKrU06rrAJ8x/iHDOpNtiFWtFaWchkQ1yrODbhbnrVmcwDmLOR6Z8inMYGKU00miW6VYmVwWmUOMg5PJ
# DATA CZkB/rQjxQsEbll8lvlV/tCY4iyNkFSaGG+H7m7a4nNHnN06h4NG5XB38xsxDJvPd+phJguWfUlPzSzTV3PbXAWS7vXv3edgepnP
# DATA 0XAiYUUw6Mme5XPBAxgCCf0GATODynn8Bh0nlMpBt3HQrL8syEok1kZmFMsco6hPAJejHudeN+tnqA9LsWUb5aj3SRx/JwWa1PNl
# DATA +3nnFUE9VZP1wGmjYJf20GimASf/jSkYGB9UGA7yvc2aoD/iXzAmT9HprXCMPLu9TgcWVaJdhWITIbX1uQgIwFQIXL+5HgYPy2b1
# DATA Ob2JR30+ycAgQybHwiQswwcYNSAaBJ1HDPQefF1/jbdC8jzX43wcnw5Go4yKntdfNnbnrgrQC6hPsOUjoIeuHZRveJM8LYRc8IW+
# DATA K6859MoDFbab9e3NrVZ9OzD60ME9WJRoc72A7VRk9YU4/ggelWhMK2vN810JCJU+x1oGLTq9tikNhTx+31YBoI5PZl7TWvBOtkhZ
# DATA 8UqKM3LOQ/nTk8uKxRxK82XwVHlJHvpBqwxNYXIyebNyOhwfF8JHUqnRrj7dAH0RFlKlvC0nQkJJPf14XUOHyXTnI9l4jjYBQVxs
# DATA VYInybltZsVn6MhjiPG4rXv4nTHe4EZCZg2som083ikW7/ygfGJlrTak8UGcNyTeDcmXjHSh7elDtqisXSdzv8rZhhifYzoYXcZL
# DATA nkAXIz1sNv+fk32apyNCS0XarABzhnOR4Ha/OEoeFZ5V47dgHDtKlovPCgwJ0+0Y6DGdR0VRsAaFK4+Kf2ZnhAVjTeVVserX+WjO
# DATA StznPdDJlSD198hX3rOU914HRr4HjKVn38XX72HLBCUZxCy/T6Lh9H0/QegAeJn2WgdbbmSMslxiVHi9Y3i8YfrbowdHYVj0Pio6
# DATA DgoRrKEY/EUt2KhmBig5PJWecddUSpBMLRiqBlFExqDNKLyj/iP6E36DW8zdPXyB2ABuQE7XbxAzsjaEzNeM9EInemMt0n4Df5RP
# DATA PbVVMjahjoxB4W1cqvALzwbnxUJ0OT0TS/xXqEoUhNKu1jpEXMeCAOLJezGRg14RaOzoADBpJuHRmlG3uam6LYTchqis/UDwrGdH
# DATA xxZxiusH9a1mvfV+f/Pg4Nu95vZ7TKHynrfN7jOxb74XBbbru63G5s77zf0GXds8bH2112z81WarsbdbdCvlxtTLFNu/OJocjTrL
# DATA YXi7F5gtVLSPkqODzqNnotVZosz7PyuGpUzhIK8bR8fx9V8aL2lCQGX9Pg5tGsirvwCwPOLxDv8VdSxXyp1H1ZUVGLpk5ctqZ7lK
# DATA 3zrLX6bG8Mv83r9dOz5qt1fLzzqP2kF5Rfz7Zfk/S2tR6jkJ6dU7iyZRDwKsEZhH/RLrCUuCgtS8CPER0xDkNsGk9NO4mB6vB+Tj
# DATA aN34pBasrX+WJ7IqgW6bj4u4BwCaE0V9R8mUkNwrQessVgpbS3VHmkrwHCGsdnSrqAAMH8uDtpZanvzEUVh+peyZU9INwxMAOSI7
# DATA C5fk9xs+3EJGerGVKUeULvupFLQFvklG8OD8cgrex8EOPoIY9CXo50iwoyl2GLwnyElA/IymBDwfTKNTw/R+MU4GfFTW0Z4k8mBa
# DATA 8y1I49Ss7+8dNFp7zdeUm3M6PY9GKwr1pqy669rPMrHRBJ2vOL+BNlV35jOKN+s79c2Duor2lGY9dlopaMVTKJMbiZ2uciqkkstj
# DATA cKldwRZX3umGb1akZ9AKzcUz5dbRRdeN2jvXS//GcIInnLKk9i7c7ME+BGoRcOCAgBTAR30z6nPzyyjRliA1sqi3vMUGwioI5OUe
# DATA XAs9MbrhoaDC8uYpJ57VU2CeI2RedcPxk713CsrJw0iZAULYJE4uxqMkTp1A+TrJROtPnrInCRwx1VzD9ieKg1Vcl1hoAnHkbTQT
# DATA qNgkKmMb5vIlRL1chGLEUsB3xGoY1SM6RaWWpuSC06oowVs/+4o4ZP7mqC94uvwH+GR06kRrTuw2+5PoBGwtgwTrw8yIqUIXYkeX
# DATA uWKtkou8OOd1gHcBL3Qr7IuvMUOSJUm8qWbMhCkQ+UfFGhSx5eLf4jMxPGbNM17im3rzQEgNSvk2wXP39FKw7sJ5dAGIqlyfBD2H
# DATA 7FgaJWl0XYCHgE7XNj7b+PPHTzc+I0sGXBU7EVa5SF947KhLy0FhtVQU66CwEZRxdVC9OmzWcqep5lps/Mcur083asInGYDCrPHj
# DATA AGFczoCd+8RaxYgrLVF15xqGgxYk92OqYvnfWL0WIr+faOZfvGZbPOBYBw8re1LcilJBKY38/PCwsc2PoniBX+dcWf/xsH7Qyu5X
# DATA Ii5dmG4oXRkxT2nL6RfnKFVQwNUZ3m/sAOFxAlsycLfFb9tEJt45T/c0v0L8cPdg80W9u7/Z+iq0ejSfXVMWTlk10159eswUJenB
# DATA MqBZ6Rpqj100LF0+GxDLIBJVVQnVVK4l02hIfW+vdhylHwWLolnOzO6snigSX9/c3+/SUQrFah/GF3g61wJ6E4bPMvVJSlFjvZsR
# DATA QgF6CFvl+gvdag2OECeA8Pnu6caN1DSwhiH9SlIRgDC5lAfIAJBlNkKlQe/6eD2XiF41Dg4auy/lAPCuDFoKwHw9j3qVUXzF1Sn4
# DATA 31LAXrcl6X5dSc4iIXmgNNYfnILoV/T4jmXTfUmI76R0rVLzNw6Kt6wIaKpgLtx0KnmeIUPqS0wEQXYxVsjgbQk4CO6BGKqtZw6c
# DATA VxB1jB3ZBSdhTMBC+GY8vDyPwRG4bbkIKu/INj5Oqij8BsmbqMbBiVe5UjCWAJZk5kx5nOCClJEQNBFdv1IO2MBi5q1dKVDSbtyy
# DATA s3Ijr4ZFIZWsd4odQ9OjlqGYvesLOHiFx4ORCfFIgHDMbIoa8LGabpLdq7sQJyDuA6u6WfJ5L5heBrBVtGVHOr7oTYveuanuq73D
# DATA 3RY0/GKnsdXyJEPj6h3DHc6e1HvJVn2Ubm8tEhHYaEAOCerdTS9plZ8iK/91xoOwgtinr0pyKfi0o4ugmJVBH+EI2Mmyiubc2+Z9
# DATA 4qn7hgRSWUkQoiaWf96kAV8BcDfud3kjNXKYS3t0MRPVggO2CzMwX0FJII74QNiQ/zcoEH9BvYF065ToFi4WrgNIkQa8TQagmDAx
# DATA blUADAe/BOXnaHo3Xo2iK3zvhY4gFBGLD5mjA7dQx5HqFIB3QNPjUZk9E45GfA1haW043vmxLnykqyMvVgIO2Chx8Lk7tanUkRpb
# DATA IA2VUSL8CEMEyX9cYWiE5fJofCW+cG9uXdOERiqzBnkoQIAUIcGCTn56zQKjIbkYGiAAwAXMsyFwrGuV91TwQtzUPpd0BzGdUT+Y
# DATA AnYMbatxJLZsHG6lA8oUMVXigeyNMycNgSVqStn0gwRMia1JbXkYlY7L0NKjCfaaK5jJazziYh+ITbkxT1zjjj1eD76o2QJQLdhY
# DATA /dlThVl+pm0KrBslHOOjCULsoD4I3PPDTvGPSG6SKRvSMpLy0USNVFXFZHe7A7Fiu13RheEJ2ZbNiGVxsZJNdqqIPuLoJ8xzjmoO
# DATA RS5sK+0Ib5wjzDrdfc+oLHoTc79TqglrWPLq42ed+AQdsk760n66z2jQrrm9di3unKPd8XYfyNAuhp4FIQC8tCnCiQ3/gbKbUynB
# DATA WmVv/PATFuHt7rW6jV1xEN8BbzDdtFQTUc3tkH97YDpSJfSwgEMXE4xUU4IbgHkenh0vpnDnwJnel3FKHjBxYIlyUj4AuTFid+Dp
# DATA JO0DgZwWqb91Q7bEkIQ5oMRp/cYFBwNlKOJCddhb34D0I1B8Ptctv7rDHdTM1VYIoSl8P5waN8zFP/g8FB97ApyO5c8C07HlhqgW
# DATA qeGLqOkafVnSS10DeTqRs5UhJo4wqi1afteQEIccC6AKx5HJdfKAD4DFzTc3UHVbiOsY0uWfIZ4lUacdB4RhjmLMLmM8gMmARzrg
# DATA GfFHQVk/awYSrILi8bP11Yw4FXiG496wxZqMn2RfjJqg0Fa92Tzcb1mcSXUZ30zUQrDjQoKqqn4AUriZWMAkPPEqZlIDfl117kB7
# DATA 2CmoZkIHYHx2gKS/aypgyjIuXnBwCs35jbFdpcOrmYn2zqJRmnuizhgJAJE9yIQACuOoR5g4Xg4jb6LO1GCcWcFceXLd/jY4CDw/
# DATA PHid8v+89gVSkfdw+jUrgHh5JsS3wa9icwXSexd9k+GrZRv/ZLl0Zr+I4epMPp3ko2wu+i45G9J0EGdWtKQ2udvubDpUVQUXy/OF
# DATA RFkyjhxCZj+dRP14jr09m8Mjw/FyKvFqqIQwx59eVEgU46tuf5AgbpkFtZR6EQghlP1EdgENEmmdRyNRXZ9sXkisM99jf/Nlvfuq
# DATA 8bKJLib4Oo2mxRMy1wD8zFgBdOuj0j97k8+9c85ePIY60BfDnRGfk957azl7r/dhzTJx41Y/s726bi1yOAxCtj/7xRbYsOwKnF3r
# DATA i5xd61bzP/+OoRzZXPmLNgoIqKMwez0PVZP1GJNb1cK21tfpUTFjEY0xcfVu9pr0RGw7+TUyKTZDlUJYjLlIhaxTKyPMG4ABGgCG
# DATA JjTHqSVl+7WQ4jkFYqhVW1ShusHoS6+it6AEAxqAAq56Dh96DsofVMpltscgdbCraLGvxNIpZMqKJ9w+XBj0Q8loxSUQHdR+YmmX
# DATA LEcPH7EVFsSqsghvhmAmjovNVldFELG8VEuHOi353T3VzjKnqO4pOAnLfPIpd949fnpzxAV9UV23IOGMJW69sBNoIoOhAKDWFhZg
# DATA ki1ZYUEB4c5PhLdizQtvYs6mXKzOOGCmt7F5zo5k9E+BGIB+hJlelghqXQb3QEctJWPaCnNSadGtsNubxBz9hBLJbGZJ0XmIhKID
# DATA /oz1Arlt2A1xvgWRpm67X8BS/CygrY5BHUZ1Er+LHoEkM8IQF41cuzVz+PTOpeC+jSk0RI2i/9h3x6KrGn0tv8ox0H3p+OSQO5F4
# DATA P0jyvfNzxAeJb77NQ4lhH8KTyTHKE+Gq0sYTYGt7a6eh3y2dfpV2XKmqRFwb8AkNOzmzif4QXDHNZVa9uCZN5YL63vHvhI5s9IiS
# DATA vvhlgmtwKIAB6g9GNePJ7fo3u4c7O3gH5AK5/ijflPrpEyE+W1td9cvgOct6a+/V/k69hTu/vbTnowcNLSPlCZ0p/ZZxVItJOIMT
# DATA kwn6yYkD5AkmYPYQyXB58V2KIAsJVrje9/brvN69AgdzJgPUo+PBA5pjjVnWlsuUPjNXre7H/vEctDJARlA3+HTVTVyD+QC6pN3k
# DATA 9yR1vb1+0sDrKZ07i1N2JfbQRJjUsDbD2DtIGB3dPqxAFzp6JT0pGhmTEJzHq3SDFtMEB/g8fSEGBXQq0AA9wzgSPQQ4s+PJ+CqB
# DATA 5MSstQDoGaCAaTy8rvi5ZZY6JPPAn31zLitLtuBmkYfHEiOGy5j6aq4bibWKGLaevVPm0CKDNl8um5pBqMX8NvGV0Ypo707pPE6X
# DATA kwlHHsIz2ix4yxDRYla1Xl3yo0ec8zKM3oiXRzeHqnqIXcvZuUZ1SbvdcMH0QVbhmolCLgibIWPRoNyYZr+ePPdAsik3VI4MzDsp
# DATA aiM7MyZy7HYLg9Eo9gXl4nWME2W4A3KVlo7Wrg2XcUARsLyUBiG3AHNckBwY0GWP3OIV3V2Ebd1PB2dbtFZATCkYGxIujPu7z4u5
# DATA WjGvwC7zkEHDQtRq7GVomezxy93drGG2qM7TqfTphufyLfoMYF2l4FHXH+Cqm7p1j7n9HTxfWhua0tJLX4f02ZvudNGVv2ScxHUs
# DATA BTqalDKP5otrnTPULrPYq9+QPUuXa2koPkifuaClPa+DmZ2bhS640AsoxyaadXDnkbPtMuz5mgL3id36t/Wm09Cnwd4oVpi6KGj8
# DATA cixeNBoCP04uT04GvQE6dkFcn4xRhBAt0DrAqETiAHc2SBDUJhWKbgJ1mRyP0RUUHqWEWajOz8OY2C2Yrja4QBkol8VqGa9w7Z3M
# DATA EPAPR/bKR/ia88yQUW+O0l15vtKByadIl66vWtvu+rMy6/G/00KK+ExJ5KdRv2epulMqeb8DTClTDT9TZ//TqOZNrfwfiwp+Lhn3
# DATA LhXyM5yXIODcKnQrNXwuAd+V8t3Quy+icXf11lk7+gf7nc2FTZ6jsx6MTsY+zTyHlebBhetIJEIAmruO5OyWem64b5oQfNr1GSRX
# DATA vBPFOfaCteezSfiOFeddv43eUGsSlZ1W51THoaZJq9h5yOI+MV9Wq2Nv7F0J3cCA9GvGSPv3b4pSc7NGGyACe3stjsexuKguwYLY
# DATA X+49t/ZJE4cAg5i7jd0Xe90XYoFzfUDZxcx4Ek8F9d1W87VZAxK248DlTBPt6TBJOofD0q3O//b6tHMwGMSn39zMFfHD3+vEPZTb
# DATA 53c//hbzcv0afloeDBnnIpkSsJYDMzGX4pmU20IAgP6VZVi6oytXlXcworAGUYXzhPzM1FgjLbO6Gr/79tqfZamqNciANiUi/WSU
# DATA Rs/0voYJaBMvUAvEj4Sk3KHpcX/lYJ4jRevJg29kYho9Te/U15sqJ7Z5Jyu8USEe4hG+51/AN0ejByoEILsfvqzSxsaUeqHgC30U
# DATA 8rZbvJWrj1yYcEBq1je3X4e36cqtjmULHM8sB3umAjU5mlV+UtOzt6CjkwnS4Gkd2VQqygaEAnVn1slo4eY/DZ6TVhnaoxS7iIt/
# DATA Hl3DcQszLkXBKAbc+AvKEqPzLFWWZmpnFT3zgNb8dCVVNLKUJAMl7GJ12WzwI3Hn/6WZsZVjDbLKVSFXJ+SZ+/0P//bjfwtoJ5W9
# DATA pnQw8/FdfYI5joRkVTK2LsOKKQEe/dzYNA7+VGw5k57d5QpLyD/ttyJoxubovmocvNpsbX0Vfsgsc2IlmOS/++Gf0tlS/wUzpUI6
# DATA vf9KKQTDGZM687g2j8lzlqjnmF3zhTx/1Zk6H2rXk+0k7fSTn4qoOLN6N3uOk//BSKPjOmzOTqeT71/gtwzYiUYgJM7MUeTt9U2G
# DATA uLyAYSdXG/VRjeCfIkoaHz0IQwaCCAPUsPeD42uKMb0YD0bTSrAvBgECiYN9VLSsjOIpHLI9tbKyAaJTxyU834g2gt74AvKaKUVn
# DATA fxCdjsbJdNADFeZ0TPtLT6ZFX8hkn2GP75oQ9vOrQY3lMNP0tTAvSpE/+TZzy4TDoTelucLrM3ja/8lkbDJp2dJd0nOKllFxTZOC
# DATA AfgHrw9a9Vfd/c2tryFjivRsEgfB/cNWmPem3rypxhrYwp1n314Goz4RgGOk/+xJXks4/rMythrblEzYyqder8JqIfUeD5wb8OYk
# DATA Ql/MP2QuCQqOU1Lxfj5IxCCc2uA/KZVSZmmVA2Y0eHuA+IsFM8dlpXVGKRFPXw3eNkYlKwFmBR9CXkWPyvQACAzQneKjiamcAW0g
# DATA WHt4xbkuLmI3GFE0eCmI+n1e78nlhegVRoKoB4ueZwC9hU+nhScpm6SnbgUfJfpewJh77gsNCecPLfjTihbNvAPEDs9FnaIaVnWm
# DATA zKvWIiREgovhtYwlE0ughBhizlPH4/61jauBhdSJ02OPiEf9rsQVLECprEIEplgItwhCswyAGDIjpgRU9CgpPRVYEIslhFhEtIVw
# DATA 3qZ34tHpVErcYMyC93b9TfFx/XTie/srNEyTiIF1WEN+hpOXRX9mYHw+UZlwAFo8I9yGeZDnfaZohBUA0TSaxF1GC8De8NsyPoIJ
# DATA SkwQCeKf5whIjCcfbKGYbdnFfQ8pb2P1MQhY0rwVvthrPm9sb9d3w5s5VLzydCGzkYKP5st6i7xt8Q6pmSFfLMkRYb49XHdsHTDN
# DATA aNzYF84fIjtH+5SOIAHBpxCugJKbQvtXMv1s83qjtNhQNVlhnTo7d9vT0zizoxKdMaM/9GRHwjut5OOCE34inA7XP14EWfaYYvOI
# DATA fk7fVhcfRiI4jua9fW8olPwDW7fckSkKdiHa90Qez9mz/b2DD+3aEDmyojCDCXUhgWOac7c7uSTG9RG2tArztHhbaxKNkpN4Uq7D
# DATA 5kaxgqx+46cFZVQGiWCOg6lWza0GX8CppaDLoMrSBsm9M2JmnE8DAZFmD/cdhP10+lLMdccwRFioWSLC4fhMGS/0E3CBQLwTjItn
# DATA XLJm/GaA6oWbn3rJ+ggTe/qBxImLbyXqUTzlnyZVrj95+idElDBjHgwHHRr2MWhTc2qO/4cOtWVfOiRGW7FC8pLuV2d+sl9faG/I
# DATA JHISC+/J+/8F8rbVuD8RYZs0nbLN3AUdZ8vU1uFgwzocgOnuxd7h7rZ7OPioalGrQz8jDx6lAILlZPqWkr5nQ+xTeWok/U4L6JLc
# DATA eTTGoj/uCnkQ4OGsM6Z5H3iCvwCpVaRjDk1T2mseSilEQOMRBdWHJGxc92MBOg/7rJ3uffxZmB22zJiCB3tbX9dNKjfrszxG0ePG
# DATA VD5NpQKKXHRKUg1DmOtYqOqtVgJdPzUdE1hRhX+6J2NMFoQJVgfgD8/JNYGOul2QYrrdUGY9niToyCHWH36vbE5OLwHGcB/vqExb
# DATA YCHtChmo1+0WjSchP1k34kcK2sURnTf3UQPOQMP4S5zPxhfTFeWyKS033srMnbZ3NgZk4xqBHKN4qJ0mHWQDhEmXQadiKMoSCRPL
# DATA ytCSTu5ryDjI3EKkPC9+nnV/GB3Hw5z7aGbLbwK8QbMrQLVpzn1G780pwbiU3AkOZuWy+AdKS/0ThKriZhpfDtjGuuqiSx6gm2/9
# DATA LZzFm5eU74bcSmhtK9hqyBUCtKKTKoiGKnYorI4DWsoyb+BTZN7Ar2LA+BvODn/HmeDvOOoSHd3fLlGQiTMJwPtuUxz8hN95pPkX
# DATA j2p+IynqtCDdbAhXt+m5GuAVoatFbE1dV7GCDqty2PIrM9dYTo0afwIv4s9BX8+ND5We9NJuVcWl/3D/uf/cf+4/95/7z/3n/nP/
# DATA uf/cf+4/95/7z4d+/i9ycsBvAIgOAA==
# END_REMNACUST_HELPERS_V1
REMNACUST_INSTALLER_PAYLOAD_V1
if [[ $EUID == 0 ]]; then
    bash "$directory/installer.sh" "$@"
else
    sudo bash "$directory/installer.sh" "$@"
fi
