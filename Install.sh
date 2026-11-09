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
HELPER_BUNDLE_SHA256='f42a68f868ef28998a84f26da52f39d268d11c2ee57edfa597690f47c4132bfb'
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
# DATA oGyDPNmSjrex7W802lF92A+G7XArbHdb3UY9jBrtYa8XRc12PdrqBvVeN2iNenE7GI26YS+ED8N6rzlq9Yf1ZnsD8x83yGm8oS7q
# DATA 2ZD7FDfMzT0bVE0Rfmi1tnpbKmdyw8DR7vUbvVEE1BAMowCAGHVb0TCu93tBd9RswFv9sNNp9TvRqN5r94atuFePG914GLS6oyDq
# DATA bKjbb6hffdVpEQi9fqsAgG4cN4JWEMThMNoa9oZbQbTVi6Nht9nsh41uZ9iIonbQaHQbjQaWsgoAP62gPQrrYXcr2opcAOy79opg
# DATA 2Or0OgVAxL1hr90OmjDKVm/Yj0edoNsN+0EzbrVDmHDUbnZaw9FwFAXhVn+rHgX9cKvV7wftYavd6A9zQBQU/CoCptGDPViEkmir
# DATA U2/E3eZwBIvS6rWH3agbd1uddqs9wkuWonowqjcBZ61+AxDRHAGu4qjRaLV68SgMXWiY/QyGdMXmOkganULq6LeAMvr1VjuOus2g
# DATA 0xn26u1oqwHkutXsBo2wuQUU2uxuDbvdIGp1YsBMu9ltR/1er9EPo5YLCd1zNxAhvAaSdq9biJKtYb/RjPBiqbATD5tRH0AabkXd
# DATA fqfXGnaier3ZC3rDsN7tN2EVtzqdsN8MoFHc6oS9KCwAJFsDQb9bSCJRGNfDYbPfGYWjIGxtBZ2wvtUFWuhtDeuwV4eNRjwchZ1u
# DATA E4AJtupbQKphvdcbwp7ud8LcRgFVGUCg46LFUMBSNnoFYPT68bDfaQEojcZwGLUbzbARdWGXBt1eC3hEpz5sN4MY0ATk2dnqdcN6
# DATA q1nvD/vNuBv1oxUw5j8bBtN1VNFutJsFMMA6jFrD4TDodqD7en8U90fNNrCmsFEftdujrU4Yw2rUe/3+aDQCLtdv9ntb7a1WN27X
# DATA m92mCwPdvjcCLecG7Oh1kHTq9SL6BKKIh71+uwF8CSgkGjbDsNXrNDtt2BJbW8MW8Io2bIxmNwwbjX7cbwHQzT7w263RsDNsFUCS
# DATA gdW1fk0K9+sQJr21FbTaTaD/XtiFWffibn3YaTVbcR9+b3UAlH6n2RgCQsOtoB0NO512pxmCEGi1e2ugGITAzMbp5RpogNL6hZTa
# DATA 6A5H/VGnE9eDKB4C3nuACeCbUSusB91hux83Oh3gIcOoDqTaj7e6vXa9G3SGw0YYxI26Cw4p/ANJykwWt+v2bbtTtEBAcg1gDGED
# DATA /tfttNvdsN2OOyDS4m6nV+/EjQh466jf6MSwSUH0Nbbifrve2Gr1mo24H+VgUaZxMQjAc1pFMMSdrWAE/Aj4Qq+7BZsBKLXX6QKO
# DATA WkA1Yavd7QMCIpRrwL1GEeylaBgAxQYgn0EeujBw9dIByfN1uGg0Cnduv93pNFr9MOy04rDfBdbeqMdbDSCeVr3dDofAqUb9Zrcz
# DATA qsfN+taotRUDX2+FPbyJLs9LbbNrnbBrw+oWMvUmCtkYBg6DbisMmi2g2XYUgGTrdaO434F9C7pHt91tB/0WCLsusJu4GUXwUtjo
# DATA rAdkYO6xXLdG9UKS7dcbQT0OtrYaoBEBT9sCbtuIOg34od8Zhg3ACJDocAv4S6MXBuGo3g27oII06+0tpOJ7QIpSNLHX8XrYokU7
# DATA qN2vdwAd8TAE+u1GIIabjWDU6gKRwibuAtr63XoXoANJ3W0A40Oo43aj16wHK2yluIDhOk7X3Oq3i0AKQO40QY0fhb02bJN2B7ZH
# DATA u4t3HQLuQBgCDwr6sGBRawSqVK/ZCkYByGKYQ9BrdO8DaXaPMGz2QTktAKfVDIetra02jDgC9bHb7IHaOAJi2eqC2jiCgcNh2Os1
# DATA O43uaNgYArY6sH6gvdSBnkfNnMK0GK8Vxu2tbhFbafR7QBQgb0G2DhvNDirSwPoBDSCWevVwtAUaJBDIqB0142DY70fQsgUSedit
# DATA 91o5elmObgaXy2AereO0QA5FOsmoFTRasGU7IWyioDHqbIHKEwTdRtgARQm09lG4FfUBqmYbBFgj7IMqHW51GrCvOvWtHA7YSbQJ
# DATA a7FeJ+iABl4ASL0fBsNW1IGxQiCTqBF0gGM0R51mPwDm0eoGgJUmrEe7vgWsFSg4BlWtFzVGw62tKN7a0DcfEDAbfLMTEiN9veaL
# DATA d4kKa80aTGXDu/O+94d/H2T/GwX83+D+7y5oZ3n7H1SRP9j//7b1fz/DWhHB1FeHLuaS8Cblf7F0UDKZLEnjqPrpaEQ10pie/DDF
# DATA ewTvq/vL13Oqb/F8Pk3Vl8ufJTP1GS+6GSdD9TVJf/fiwFfLRTLW9YGDOfop9Nd4MrO/c8lgzE842d07w1svihxmJe/58fHZ/gkm
# DATA Z5S+mX7fP9l/cbS79+r0bPDF/uHL/ZPTwZeNb6DZ/tEzavN9Hz4N1rXaPdr74viEbjQnVy2eEJsPN8qfTip/zi0Hn706ena4Pzj9
# DATA YhfY7E7JvgWk9IONivf84HD/FNNRSvkNXuI8T1FV8Zvtlsg7zYt+c9QE+/LikrHY8B1tyNLtkWP1KSdLdEvL9lYufNvycgbK6bkr
# DATA EM6skdfrgCtPtTpGaClwlODvjnVME7IkNN9puWKU6AmJAed8t0wp/F38ZPhRe6xKFe/F7k8GJ7tfYWn5rltEgx7hgsOzZu5R7mRZ
# DATA VMbFVnUNsTJ3FIcAR9mpiCGRIXqurjgZ8uUmVSJwXaZObiuxOpV3ZdvW5IgvNcCManVZrrwv0nvwOla3LW97a4vSlajWlPpP+dPt
# DATA Tev0A34/r21e2D9VPq58WlIx0nvPOMj9BcK8BCpdnAnz9Qd4Q0KsrvOQRE0M+yzo6shyaVMdoqHci1HCR8QWyxlsXqwxjqEVjPBK
# DATA 6UWsR5RkgA6s58iVY8oNrlNU8e6rPqDObhpoVOnOWkl37awjw4B30iR8dGxuv4K3/iKuh2k6LptO4VdrJrpUNpAKbTpBJ0uEHZvA
# DATA +LFaRd6hIaY0lZlHVvwf+Y37FuOZvplPlmOUpot4bs4oCa/FoiNTJ8xGX6vS3pfz5DJVGTxf9pDb1uJpxNk7wJYfzDE+MLczFUGo
# DATA ForEYTKVh+fbm3iqB/u/YJDweVEJZQSrjA/trCIUGc92z3b9klRQtDcGPtzb3fti37flAG0Q9b3VvKO9gP1WKo85Wf9qGr+Z8b0h
# DATA zix9uarIrAfOi0WWrpTDRECZhfeu9Qu5kNHoGDJWMA1BgXD5ES/nHC8Pn5WZDfmfMD8S+lQQOzQqb+cgtEi5cl6XJSkPN0oblfPG
# DATA hWaLVBxKszud0HLPACBQoJtiMb1B8NZLwJ27bfwMw1XtXWXqJAeqesokeJNMlpMdxeQNh3yw4Gb+aPkq/r9gbNNpB6wYhjkpy3Ew
# DATA p5oO5oy/degcqZEHSGew7iUgvoofZNgsDiZmLLoCb0d+plMIZZkJ9NlwaIeEA3AFef4IeKnW2SJN/TFm2rhUkpd1+roFrpNRngfW
# DATA JQs4PP4Ao7eave7WY3AlHa2MLzO2zrlhz/q4cyxiEvfE2xJbsXSHtgibKlbxN2G4kq7VcUfXlcKr5+qtiwf31atptpzNKBtV7SgF
# DATA d6nyry9hGTo1k4tvL2uLoXK0WzWag6wPGpKFFl047lZ74Y4Z607JHqv0FD1Vladkv+HaksKtTxVySRR1tFO+IY3dD2ZerrAVVap4
# DATA bqqcUgH4VM5K2lgxEnH1zAnRzQtYY/hpdvuXoOFX/lKUzr9kjfMbUDkrcnT0EeLQwS4CRTVzVmSthUUuVqGRiCgjtUU2h94B5Fzi
# DATA HfAwXWAPpnrMh8KtcmZduDE5qcwdMyyYk53JucOFgqvu/9B3GiEdKIb9gXBgoTyzG7LlxB3e0QGZAFTdDqQwsRIewceYttZxUdwK
# DATA liziSvGSUAZsrSplyaRsoiMH3+Lqb7MIo9PzujoTn9bRRc7obLkc4HlbbPbIZWOS9rhapcc+A+RweL2N75SlIffVlUVJpEnYlYuE
# DATA fTu96Iq/bLWQpMA6Ra6aQfyZW+QVBGpexK/u5wOuwwXx5DAEP0q5iBrug5IjYoTVfLSjBY7GxP3nmVe1Pb5YfA3rcXpeZUH68ktb
# DATA HFNrPrJSWak3L/dfIuQuvVvIXWlTXClqPcmrqxkneF8p4M666HQN8evr9lbIBtiXOc8hU7+HyEzxaP1SQfLtSge4iaxXYBMoX1SV
# DATA NZZK1d6gVlMavZIvjiGlEA0Ma+qfmSPdspK4Rz/+WGauYNjGMe5Wl1+fQ3RBd47fSco0p9fTYpctWlFrXcm3V1XgugiqaP2TYRxF
# DATA Oa3fUqpzdqOcGc/ZjvkKfPcYkVXQX8FGsC06MYZx0IgcfCW+5xLNrfPe9kWBQegYgbQN1pt8jnKkhhHlQr4i8++uK666Xugo3BVI
# DATA n58lchKfPbW1YbctVpEMWdXkauXrkn2ADtza5/AfPL5M+z4d/nQnSWuf4TofHJe570qh5QAklTMclOsrbziI5v4ImbfvTjNbEXtK
# DATA BZQzyzQLcQ2zoVMwCRyeTxfslObbbAZJBraBZYIYJleQqjgIVCw/llfYoDwgXbH1EFc7gzmAuLrNL2KWc0RwpyQiuftClwM/A7NR
# DATA Kv3qF2tSuld7Gc0TJXoZe1hj5EnJjFPTlUe++Sb/8+M8EHjN+AqJCh5L+ZMuKFysES4slMdvyFdPM+MmFaYsdUPHzUCbdTuiVc3S
# DATA WVnxuco67q5fc9i8uqpp9blWqaZRPC+SKWEAQsquhveQSEmXi9mSzg0Ywqw8QMP8jiLdmzWUWygD5ITjQ6Ig79WajlI+aETAnAXz
# DATA A/ilvKrPYUOityp/RAjVR4xY+DuOtlD1QRC02/Cn6FgOZvfTkuP7VRtBrnSx+LbmdPxbmRgZWmXzOMvKjDfcwKRyY0UFgmqnritq
# DATA i9BgQaGrtuGiPmSfPei6o14+1Kqhl/ycPSZgfsKRKPYcUkEUbFyTqSvXl3ax5d8UEWfEFN7Iy6g8T4C+32zTf5Fr1+sXqhu2X+gB
# DATA HoEKppcxesdtSVbFF9x6kpY0h44UFBhEU3oa1y/nKJfYKdTe3kvrvNXaUa1MO3PLgi5YoT2UT/SnGjoQuMAG6y8VzU4odif2j/N2
# DATA qUCDU2SSM2C0OwX1Xd3Tl/snpwfHR2pgruxRY5/oY1x90qsUEuNohvqtwKzQcjFn1FnW3AeZcC4m+O6gxxhxj2GFtpvYfqpIBG/W
# DATA pkob6jyTUwV0zQI7hENkaMqqOKv+XWOKHE6CGFm/x5KJbe9qVyQm1Bhv5LbqNO+W3F5r6ro1j3WhYcHH29JKB5qJi6237fD2u3sF
# DATA kOP6qtzdWRuvbN32gJOs0jsYYlT3OiH7mS52mvpSd8XzpBzyigtArf8jXfyWu0D3rL39lk3Cp7YtA8h6dj/rqDivEZzqRkhqrbYI
# DATA +wtEdgyYLbIUUz4bw6vEt7CGPynytoxN1blG0yPMX7qRjcsczcsGKuuON4ozf/OmXudIl2mzpg7QI0WgOammLk7S/bIJfM/VX6Ip
# DATA gX3c6cjpPmXgmm4Acda6ew8Vxlk5AW4aF4V01tZffDQaLuNprC678XK3rq76HPRB6nvdDar8pOtpUGcA9bk/+zBgwRlALsH1ElSs
# DATA eH7NhbaiADNCIgvomi+V4nxKHMlgl97KVTdUDzPXmyQp4Q576ksOA13BAPCCrgtLNaIimguTw2RIpFZQvii/1mXbJ3h//TjR99aT
# DATA Qoy5RgFxGCoHppKQkDLxM4blR8mbnVJNDLxNjIIk8x1rA1XWU9bv6MzRNccNnCKPHCak+PZj3tNOnHbbba+bmmr/asvdWzohzfTZ
# DATA e9VDcdEOoU0hTbR7YvxQeFMzPalRZppyGr2lb7X9/Z8cnMKWkG8gwvdfvDz7+u6eEisrT77v707priUr+I3XN82Ww3GSXdE2yFDW
# DATA mz2g7he9SrKC7mbzNAQrBQ/jU/mQBWyZeAlMga/081VwSSV2YPEHSdMrmv3vwozuZ0hAKeq4ewFv4noohPuiC6L/dVlVYX0MnLym
# DATA w/UFEpxmeTSZJ3J7hblH5SObk1i/K+TqN5GencoyZvs/GufiQ1HePSANZKGSaVdQCYaTI2vzyWIeW5vJ9jW4qsdaT4YQCW1453XH
# DATA g2unKdELOlwPpmXl91J4IJ0pWrNLB6B1QPXUMEZQqmq964GCAfkaBvc2Jiw9urUEfx/dHGnqw+DhBVlt/kBpA1XNQCOSqkUQAg1Z
# DATA krWl6w6IGj0ufpVxbr3rGPMrndgFD7hkgdJ6qamkCVkGmq56wPoqf7E0YgaJ1eLKw4UwmDb/f3LGIJ96+93n/zcazVZjJf+/3v1D
# DATA /v938W9jY+MkxgpVfrac0YU1cWRVRuYcbqllHaBTABNCI2gcorIxWo7tu2nvSfendP0PSNJfDkWf0b/c6o/oc/W8k/2Xx6cHZ8cn
# DATA B5TpzgeSpAQM+hsur8J5LUmfjNPFAkz6J+YCW10mZuWn/LVN6/tYrSzj9Fdw8wp3zqVp7odPVa/J/QI93Hl8GyJN2Jrr1WIxy7af
# DATA PLkEPWE5RI+17vYkN8c7Z5IGnEd1wXDceQcvdj/H2oC5Mwri49k+r2/2g80RJ+ZUvGf7u88OD44wP53iqyoIMkuzhCod6RsNTGZe
# DATA 6Y9LzpVvK5FacxG15DL/cYkCs6pIeb7VXJpt62YKDKD+YDzActllJndM9U4XlA2xeguLLq9j3TlEryG4/L7l6tcp1BihwYdczPEg
# DATA 4lsU8zEBhVcrMmC6IBXR6pHvFWA4H7ilxrkNtWwBcgKLcBZcZqa65ycrz5+RpWuamIq9N+hzPIfOpcTZyL2lj0sk2qtMld3sjXuu
# DATA 0XtxYSMDus4XEb68pGJm0l3CztZ89xYcdECJCcncH3iX8xMQ70OVGM0tsgZwJLoK1wLdD8ZZypRCllUmrh74PQmyOKvlet29TsHO
# DATA CbLX2PMzKqqHHgnuAM9U0XvQkf9TzLzl3yPsOB6P3M6KcVw4N04Md/EhTwuwd1FQNEpVZrSIDlPG8YRHEi5qyL7RjYpXGVcqtsdn
# DATA rGNaau2319yGadHWIy/ZSOeXFL40l4PUuBO5jnTdHZowbWGWFpEV3Zu5dubn5suFG4/il9QhGFrg8seoRlZJ0A1Ymcxlx6HeyPcm
# DATA tOoIp2aLzr3e+tdNknO1SQqIRU972bpGRnX1wx2/nneFnnFxSGV0E2sS/Q5kdRBRGgqox6D/RuY2FnId7FhytzZfTsvnUhISy9zh
# DATA 9C6qnEQlbtEwmC3wCmWZLv+IsQb1kUHZmYDC3KpXDeAVJ49DjZgtImhNmSztx6eyyP6CJYE1hmfo4omjTM95nEyShZvdaOVo58cG
# DATA kKwV5CVx28iqD5E7g3XB2Zfq7jq+sYqv6XSCm9KMY5tmOrdJPI74MBHW84c3t/l9jprKWFjNb8CyRRnFCRWAF9IrqUqFAZcm1KXA
# DATA nSQjtdQsMVaub7ucp0u6gUDNDIawL81TL+rbp2VsML4wczB/BcvbtzWivTtMzf2YOnfBcVZE9+5eGVi2ihdylUwpTPs6jmcCHF4f
# DATA AGxb7Rv6zdI48psIMdusr+DCQbEiTmtIyzqVlMDMTfYnz631ghN5uy8XWvfHrPbBCP9Lqehv1SVXXSAnSdjLZt+3ml85Tp5Uhbvt
# DATA hGINy/prcN2bmO1EbgwpFykweNSNtZ6J6MmlinUFuZYZCACu6/aDkEc5sDUpqgEMTereXc5MCWtFB/YKpN1K7+Pi3aZqhS6Ac4a5
# DATA vecyPGtIOg6HVu99LE5neok5hnMfpssp2WqOL08aONppwcY2w1u6Kh/XxRvbQBDeg1LezGvxqbSZHcnKGTlaa9XRD6cfrH4rz2t+
# DATA V/9oR2/67aKilidaZgqKgPHg5om21wtH9mXugOWJrD+ez11VYwjtXt8b0HOV9QIu/uA14t/3tXgbwfuIsk306bPFEcXjGC3Mp8BT
# DATA fCpjW1XscAZESMl3Uv3d1SpXVnc+oUq25i77nHbIS/rJjt94XJjP0iNO9ceiwJ8sD6spZk1k1mG6HPMFdOjGHt8qFTpZrFsc7m9U
# DATA 2sNFBZDfCux3tn9DG7RCDE91/V26d1wx2ByllCrfxjn9wWVsbfPoQ0risuzByCBfZrSj7Ms17ZHVWgVuWQG2XleW3gPeYCWp3cKy
# DATA 4lRVt53RF5LZ/8Hcq/8+/L/Z78nx+7j6L81eo+X6f+u9Tu8P9V+/K//vlxJV1fmAwvfkIi92uoqPBNWtRSrs+T5/b65uy73u36r/
# DATA EqzIl2mWvFnjDbZ8v1Kvxa4/wQedSemWs1zsndnJl6GwEqP53jXS0+8/yEyJSVfL6Wvy7y2Ao4+DyTAKtp0jCpatWsEaGfkILUOk
# DATA 1Fjqzz1yxM8LKmSokDeHqhbBJXDTDCw3pbrJ5c00HxMls9LZLRuFGjxRhVn4MpBVM2UMi1v4nubum+xiWd+Flc0qV2tykiFXBKAT
# DATA BM5joTx+DnO8Txl+99/e/ZJre6tC3v8Af377/ufv//rdPwtlbr77zbu/xyvs3/0TFgLXlTwE/sw66Je7glou/7TP1Jlncj71EWXm
# DATA 7x6cAdUalxlQ6XEsQP6bB2ZAidOkW78NzkuU1n2x7QdEpAESKJMGz4k/m4uEAlkKuoKTbxJaznCBQbUxV/VZIlxyoqcW4lbTg2YJ
# DATA OiiRZs4ZH+495TgK/0yuFMGd4+vlgC3Bpk+D04UyydTOgk7ndku80SFZWA3lhwfPAr77PxReuZ47Yf037/+GSAorucMnLP/+/m+o
# DATA Jvz7/wKP/5HKz/8zvPQvfGSwoIC+EIsFIh1DQDsGmJu6U5YJKJhE3TYSTjCfwIe7B2H+b1h4/jdI5O/+HqgGYfkNl8XHsvRAKVZh
# DATA eqx3/+6fYSo/h+9/uxZeIhmAsGqiFwT7eQ7ui+KMMLnubGQFqd7qUe4238ImvtsEa2r5ZvMtdnhXA85du/xZKZeONVMOmNE9ATGr
# DATA 5+23DKUu/HehBuNhSis2mHE408V5tATqZJL1kE0h53zvY7IsbW4ECwHL8Kt3//L+7wp28S9WPdX33Ln+SHT8sUTcSnw1e/5EvJme
# DATA vnCT3S8fOjVmtL9494/w5Zfv/9rHP/gByAxmdy/PevyxFxdiUwUAb0srrgCg4o1rO6GPKtr2wbOGLfV3Pu21X9NE+XYI/hnm/vN3
# DATA /wL/94tHrDWxYrrchfg3wcYpmUrWGHsYUz1pPxREZN8yTz/fMHEe2ABPRHz+f+y9a3cb6Xkg6M/8FSV5NwWoAfAqqRsU5LAltptj
# DATA idKQlN1tisEpAkWyLBBAUAAvTfMcJ042kxPvJJndD7N7zuxszu7XPcfpuBPHdtvnzC9Q/4X5Jfvc3mu9BYCSuj27404soqre++W5
# DATA X/LF7uC8jxB9ka7EYuEyUHVemcPR4BwYuraq0p6MegJOeQjv6Vti1WLqhMup1UcAQ+tc5pA9HyAmjPgLAcQ/ef3P8PvvX38ZwQp/
# DATA QelHfkFZQPAk/ub1L6PvZuOPJ4e+A3e5lNWaA/u4UkSuqh3BgYrs82eK4KCCqd25s/pG90UOA07gJ1MOiZCAiiBR7iqwp51xkexz
# DATA EvogyKs2fYpvCs24YOW30katU/BRYJb/mRDiL2STOKeK5ECJYKP4jsCdiahVgIcRt+q6Uqjh7tuk14GlqTPiTOWEXcBM+/gsKXDl
# DATA gmHCt0qBHtpXtNABzV1RTkicyMEl1HDg7MfVnTv00fGKkYFoqoQysBLhob8pQsTzh7HHDoUZ9cZ46Zrq5AWvJHZBR7LpHlAV2IL0
# DATA cZIdqsJ/BALKweiRUpVzK8JHRT5N171q10WrjjMDjsLAi+d8OJD8oLraIBdwQdRAPPVs/V2RhAH4at8ZB1YwbQbFkYrD88gpf35q
# DATA xSajWc1QJDtUp8zJoTvnagWlhoVmilRpYNb/gUb9ZzCRv0XyAei7IukJrz4HsPJTwkO/9JYEyVeo9dVfWVcRXzqsEcEbHXYxO7ps
# DATA i5+sBBqzz0wWYK2tWc0TxWT34406FArBPYvw/hx2kkE7APm4zHGZBxiPmkA/vmM3e9K9UAyiyWnllH3ddWZWq9z7Zbig/BS//jw4
# DATA eZg37tW/I7riNxFm2kKQCS9++/pfLboBYVTuaGnndOgX0tyRqVQsz/giqkRD8yxvJ4f5oDcZizF63GiQCRZ9xUCXeYkvv8KhFR1C
# DATA gNwCrDgBKqjA/AQYMDRERMLpgPUS8vN3dPx/FgUX9os4OC81g3yurhG3fY5IDPOPwVX6a8yAxtfpRp1Tjyhx93zcUbvIJiCh0ASx
# DATA lkl4eVqFnFG1B6PiKS9UVmEbglYU5SsPQMNpaAZxq8o6yvCKDLR471TpohwoxyCMvkkaFNoXkMPs2cHBDS4fARhNpyA0/AUih9f/
# DATA hBfNgqAa5n6JHA1dS0XClDI0jOAIOpbFmbAmZtJpF/bUbii4ryXtvPn2Cj/zFzDrf2IE+9X/BL9/OWOnTUgna8h2FA1luGlxBZ74
# DATA VbmI2WJOC6soXm32Hv9H3FbkyWBb/4IlM3xp3wDb0NxsGsqSexoXZUaOLvoUjXhF/qK22sah344e9YBiyzpGhYsS7JxMDbkvQbLr
# DATA xpSj65TSNL2Ih5nU7fUG5ywD9BeuppZSc/sH2u5VzGOXD64dSwQ1dnMj9Ss6cGRrIYyC9DyHMRZlZfwnum3/grer7OopQg3tOFpO
# DATA zwuFfbnySWg2BtlwiE+gEga5/vYsFwqdLo16q+7QdXhb8+Qs7VZYuO/u6O3btx/hiGhv4J5Pkh5B+q7wKWIl31e6jfFJghIL8W5j
# DATA A08DXVF54uIEHXxKcr2aeERFWoCuvzKxKA/1oqYhUYp+PCXWi6EqCp//QFVo4y9c9vdadmikqVSHitJFD2SlYghOBuDvv6WQweQj
# DATA tW/dP1MuVJRIwpWbQ0BVRrDcJEBUKSoqtW5BNZG146grcKmYYjvmthhyY0qYJz9xvNujifsdC9UUia80H8395goJCSrxYW9wyIkQ
# DATA mPUpsd9hBDln2ClvJW6KOFuzEKdLqxSCY0mjC2ECEw+tIuM0apAXNybVfi9kmk+wMP/uT0GQgdFbah95NsqeOolyOuQmV3EGgXID
# DATA 4uSbzeDNlkOOF62SPNJNIQEmSxU5YptjRRgTnn2X7rXj5Hi6xZNWiM7XnpGxx7+PXOSuuG1aSWXFN9+0SNQ5b2Fl2fqmadCVwy/X
# DATA Z2lz4JBYEmfeJNf+gJtg1XbQqlqJea0t4/h/6Dqs3xXyscuo8KroQTXDwVH8FOoFoXo4GTubI1oRiUSsP6U5P0e7PNvHQZkTu/0p
# DATA Ybm/cEo8GVi3kNGqvzLq9haRiydGpIp4ujREKuBev22GAaUtCynOJp5Zv3E4wagtJc3naWk7ilPzV0azsGphCk2H8tmrEDY1O6Ah
# DATA 27aWBBQR9Ep90o0qjpQPCkZFovrVGbbHjIx2L3PgaDYvgL9bfkOLSSeb0e/D/m95afnevbue//fSGhT/g/3fN2P/tzdK+jlfSmBo
# DATA OQcWIDL0XsrFQwOlCekIOFjj7A1wCinnwWTMZSmuCBRBi/ekl8+f+q0zGF6+fVK37BgGr5/GyXh+T3KV6m3UQ5KbI8+479AIGzWz
# DATA NB55RzOKTDkSs9Tw16RPv90UcniROS9LHxDlGN3C8LITF90mWRrQWiYajISNAVCtpsop26xZednOEPTQDz23nixgOHdbpJf/FGCA
# DATA 8rQA7I27A7RkB4VX0VMNHpjmNXDQyEQ2om6WHPcHQFh3WOYBtDOFnRkPovxkcK4PCgE5OihEzU5kJOz+RidGdN9QmTVP9KkWDYZ8
# DATA Oh2PSgngSEvIOb5sXkYlwXHFD1ynZcw/G5xpSH+cGmXOX415pApoLfJnYj3yr6jIc1OdqJlxNoSZyXuKI/i/gVn4V5SwFToiFSCa
# DATA qbhmbcG0PiqdkAp3RMOpFMejlwmvGEWUbBfkGCtvN+qp+jGjH0WzCpZnf+mbXQA79vp3rnEFjlmHigUObNxOKICFbTUsF0Ln5bMP
# DATA mUne18bDWTHmw7XIeGZInGNrgdg0AypTSPNk3Nhtbz199nizwpGOx238ZmxmseAfRUsDQIvloenRqE1qA2hBzntAvG0KT/OcmP+d
# DATA uNSfwzoCS8p856/Ixua3KEP6HeqXcVuADf01rGyBJ//NVz9l/Tty3//CdoiksP/1V/8+dgNBtmWthVWV1XaMLGJ8FTfNecRwoOzJ
# DATA 0ow4/HNMclV5jH6My7O8TAkaz4DXQrGurAa8IBaTQ1qot/DsJwEJj6tpZKmwoHkHrkAmgyK6rj9Gv3kvQPYEZSqWqWwKb0jaW5Hy
# DATA 4VDYklUAz8jRAMXqCujkAuIK9CN15AoQ5TztPtn+nnuetOxUF9nZ/G6xiP76eGtnytfdZ4+89kslrvMDSDx2BJV+jofuV/aRZB25
# DATA dSjDhoRTxsfQy37Ft+r+fVZwlF6eG0zsH+C8s3DnH2lKX0Rf/QUDNTTJnT4huE5k/f3PYr+rFgIrAaQjfTMKkH6FFrzwik3eKlYH
# DATA 95aAgPB6+WWE+Tu0kUcyHPYu2y604z/oVUaMvINOFZNCRZoleUOIjhigDGmQs6aBy+/zPT6o4ftn7Z3Hz7affAp3lZ7geG0+2nu2
# DATA o19sP/vo2ZMnz34gwVRtJlTuBxQ7otth+nS0jBXnzltXnSSRelACIg5qkXrD0OHAOeFFgKw0XrohAUlWQwyUwmmmbgpzf8lWgmTq
# DATA 82sxN8BTgQBYbJ0Q9HJxi4ZwzGppR8PSiwK8C60qLjnH5jNfzXTVAnD8CeqLLfr99VgIxlWExjs9oC6dnsWHR7MUYq9oST6QoG1n
# DATA XTuIe8G7oChXs04TKxY5HTCLXtKudCNtOytpfNWxj6RP5lzeDksEEAnPrDStiyTvYy1CTVHrrJ6YVrTKKZWMN4UblFxXKUwyx3DQ
# DATA FZkDBqAN2Iw4FF1wFmxY5YxWkLA3KhhwaFjWTBYKTcOnQtvwzm7c2Ux15zzR6RwUzX8ACPmPRAGS6aDqG6srgrF4Sqo2fWc4Dn+O
# DATA tM5mkGalRQ+L3jS4NIU11C5EWIIP1aSvYr12Yw2BUs8DiZUp+nEeeg6IMoISX7I2IgLEhDqEX7MBtVGbEFYh0/1/IgNDsiUk0pt8
# DATA SYokc41HWENjWPkVY5RmprvozX6M8oJdeanNUiXmcvsE2ELFxWlvYAQVLtaxLLWlMKx9tUAD0zd6CXw2Ru0QvpsrkRatucg5aPgN
# DATA Ox0pS3pkfFxOERpo4BBJ/wjLzkOc0q/UmcAqKC01Pg+BWT4fjLr6GTiJ2Tv3d8af4s9s4Ymr6iLE8SXuKJADf84W8IwgfkIY4TcR
# DATA bSQQIuK3hKT6V39FKqd/LWdAdSAzI7KoVHDs5Kuntqkm08OzgL/+dJJipFf8eTRKjk9NGhUnNFLZVki0JRWLDQqIVYqKdEMOku20
# DATA f1ZBkawk77bD67xKL+WtbjrklZaMYfDomTaK/6TynWZ6gTuyH70cH7xX/Q6eA+NqAy2K9wx+vtNq3PkfYhuMYrrsFIXcFWmVYxwh
# DATA FdV46sFV/MBB8TBJgC7PLqNRu4nDRxjS0kdRNXbUS47zFjU5RZ8g7eMflQlZJUKm7CrvFTuQT06oXaguCz4cDS4uWfzN43AuaS16
# DATA lfW7rbiTdLuXsZG76LWtfOfBLSutaKN+UHUXl5vj9a18p1BWNJwoa0SLJqJHhdbUMKTiJ3DvD/q9AYWv5ooLbiwvpCAmfbMN/dA+
# DATA yPRkC/Tib9lGYWpU6hcZtmPLD62EQ25EMDkyuGrs+nic9R2bd3Xp5ITgopxW/6TyMr9D0e9HpL59mb9Xrez/yTqc1cp6tRCW0rKG
# DATA 4PlIMkP6A3eJNoCXjl+tUFw//r16wCcupEECUoyw4ZJlsNq3w8n4uc3pHFpxbjDEA9pUcLSKYlBC1sdzpjsGAd92ojZat07GAoMh
# DATA bi6+itkTlRvBV/JbtXSlWipmw3GdqzA6yRE7Wdkj4foBg5M+4XdZUG6C7tsVydGoKdfXm0b+nrawaNChwQ6qUd1/ee0xt7SOKhod
# DATA ZWsvnh07u2DuSBPlpM7GPP+ASAW5S8QQvyAC4gukFYhI+JLYzF/wm8+Rmvgd2Sp8DhTF38Lb3xDSGaXoI5EyBFm3mRhiZJCJYVcN
# DATA EijpL1/9TVweSk+n28RwQLXIEssU6DRGSVowbIRwCABbRp6kryS8FgoTG9e5hQopywv5fYrCUUJlWh5Hw7Ob3Ie+DihCq5ZkFTKL
# DATA US5wlWaeuqDuCwmo8Ff5/RffolOWeHmCWS33uH//fnkHFIj92t4RGL3KrNnNlAeI3g+BHk17rQO7thBeFc0nChJTHfXPKGga6seJ
# DATA kKyZbBwmEd5EbCCpBFPNWFHceik46TSashhgTbe5z7+c0LH75qyRtNcMCDkCqqCkHl5QNEEqHBWNFpkxGIcn9WgXRfkolQgRP9lo
# DATA 0CeOmFcU+IYxZ+POAxRRiZuDrBMSeFBdL/y+IuBxS8gWzJK9KGAnzIxSCdkj8pdffYgtswLaSpJyFraVx4L0Gg7FZOU5cF1c5qPy
# DATA rKuNwTl4+CL7pH4DWRuokLqhhq732OZAzW9HeycpYNx8HKlTh7cpmYxPBqMMbl12lorjYT89x0GtCznL2YRY7zXEwLXjwaCYc+NI
# DATA qaeyftkQSJIyyo4pTm3LvV60IZYUXTv28b7XLLjmW4EE5o+IlwaxX18+4MCyigguI6iZ8NRUNPSohhqklB3jjSCcsXgB09IVdNPk
# DATA fbt2wyqa7S8/ojb48yLUcp19p/wBGaVjs+qSok6ARoUAXaIf6pduHnQrdmosF4lDBALC/BGc+jo5oRoJibwmAlACHcoruByeM6lp
# DATA xNygmpi3W3cKuzuKa5JsS41SQRy09cLrKIvOkyGeXiaCc4xajmKYBla1jNRdeyNRJlewqJqr2JvFd2Jjiq9CJWZAC42Gg55Yg9E7
# DATA 2IA66cEnYl7ohBW1ZS/KKj4Qs3FfEoQrsUQtumPJWlA0nnVI+SzxUdzvZLi7q8AkFTjw+iTQWQS/tgE4z9WGtwdaZESx/LR5/xQo
# DATA rgLTKSGmMmVC72TaMEseg1WtcAKqn31l8Xs4GPQqdqQ7+c2T3h3zLmjAIQm31GrjUSGihoB3M1LdU7UmmXEAPZMO8UeFj5Gty1Ou
# DATA yVqb51bgz/45H8kQmnoyZsK5zDi/tmgNHCQCQyGg8dFEGlXQlc+GHOuPfDLQo2YI9xduFtIAhs6Zu4qAhLr03bg87cXF8VWmNEBp
# DATA HxvjC7wMrISmeZOhrF+iWsg5O8XCITCPgrYWl1PLDVI0USmK7JU0zRXe19AcpX2aAq5UL1CbTjSq/YxIRZ6zPoU4Na9ksFpcZ+gU
# DATA tlmqqC8m+57u06F7STtoRLq3dIgiTNxkqmh5NIoPEfYoNE6ArDeYdI96CUVcjI87eMircxqM/IJD+ZBkD6PF6BBQvyXF0D9Ge092
# DATA kSv7NfNQ6OlumCboqavFsqLfmEOFYsTRatnnXhJTQ68IxqnPx2lCUnqkertJD2q+3Qr8hK0NUJ75Z8iBIovqz1+ZUughuUJ0HPMu
# DATA fHuqbK71OKth5RFPEmc/5wTnmx/ywp+L7PbLabP7vCif/flXf+nPmuTXdBGsQ4+PFX1p9Nbyg8/lBdboOWeXWltbFQB/MUoug53Y
# DATA N5EpLft5RldbXFh6e990N2svSLdnVp4+oFfKlbsArINIhhn1gJjcrFbNzOmatCqrs7fvP7Nc/au/iTaeb9WczcIYDBKU4efRJ9By
# DATA QY9vwjCIHl82MD9JRixKnKG6FMuFkBoSj3rFQe4BzRG2yuozaskqZSVAJdchH7v45RXtaZU25KiBJjSxgsLVUCdmAk0ylGJkPejh
# DATA YlS0+sbR0JjZM1yX4E1GTzOHClib0wWXcsEzHDd6JGsB7EZfjCjm934Mc99fOrjZWAq92auMe/WYp1lsS3aSlVh4PaRk1TUhhMVk
# DATA eegcazJtghZw4w1yl2W/WOPAWYzpg9I4ZfYd/I8m+ElYQjlVjdmIXv8DQdW/IoOLn6Ou7Asqzp5jrCNWKjYMnvclVeX3gpV+Li9/
# DATA paPJ8JJ4JAe8JOEdfuRtitUqGDqlpVfDJUg05nVwcsjrrLhE/w85mv25vTRsjkShY4x9HqsELVB0mHReTYaWMp9fsD2B3Li6EzNw
# DATA Rnpbri9ZlFWiZDRPsjMqG3kgsRBErrLRH8UsVSwyQbGmTb7EsHTwBv5Fiz8+/k1DZJbkHL+m7FlIKulH5gyawMvBw/AEo4024QeT
# DATA sRQgjiciw+KH6vUsVBUkp+wMBhxLvG1ws4/Bp2Nmz4LAIXCqBRzJEl2jKANG1unZIiSUuemMJrKj0Bxutby2Pa8n4knw40eAYM4p
# DATA jaYrDy+2aXGGbtO8BenREaAeFLG1xObC2ZRbYYgnOSKKuJRmeaUH7aArdQrjYI4329pBRRSwxAyubAGOm1fCCgvmiRmgrOhZSZ48
# DATA jQl8hMVY7O0pJfYlvIMw60ERj17KqgRLlsaVLX2xT5Ut5QLL0Bmss2JzeqxXns2sG8TtCuVdKqo2B0yHU6hFbesyHY3S/KSivC31
# DATA 6Gs+7VKbIg7390r7MrMtUZvhT8vlM9Vyh5uk2eHh18MOfLbC6VA03flHaGqiOpHjGmf9Rp6OJYx/JZYEECzGciM+kDIbwy5Q5WY4
# DATA 7Tl95BvE7+Kqp++gEo6+g+vojHto4MEWIbHuzkGXhbzTdEYWz5LRYi87NKFPFwGBxvPb6P5fmpHSyJFjlv6MTTD/kf0itIO2Nrb8
# DATA FRqzA/3AJplfIEMOVMV/sjk1JiK+IKdumz75XFnfwL//3o6URGusBFNXMfrfIpA5zCjrQizZzBj7mDsJt72TjjD7HpSR9W+WLg2h
# DATA vaTbxpTfiuC2IoqhFLWXfZZ22/q47MshmL6h0xWQ3mQYtdABsJJXLyqoKwfSmXPhvCwd2NMNHKfr6UMKHO9pc8QQJNbZPLBSEaPh
# DATA rLVQTsPFBdVTd+9LyWkG2OWGwkb+Vro0URfkhQ5ZQIttTJT1CZJ11db/fj2VL48YSfNxnxukQBeygYp5InRgl5QmgOZ3PKvmNIL+
# DATA T75xATkB/CXZFnyJtoqK3P/VVGtpudLrbFrwWwn6+DOm3tkgrmStnZxYF5fmFsyC3/saih4Em9hf4Ygajghcr1vVO05tZcwQWFkn
# DATA nnh4j2SfPeuaEj0B6WusmJ4G01AuKH2w9+NdGYF7xB0VwVOarIkobx31xymKRjmv+tTzLgIeXVG6rRYMgDhgHI2S78KNnE60DSx5
# DATA V/zMOSvI6SEKEOPJ8PHyA/84Oyfjss2WYMTWdZEUcJo4gyUtfi0XxAsBTYU3yMCeCGjXmcNuy6dEut20+xwPKNVDPOCVYLUNHCyX
# DATA CMXS+zNUYbXIolqyoxsTcCW7tmPbE0lMFM/ySEUZ/p9ZbOzx6hStkZwGixKAL+dB3b+UMLJuPBeW6/2CHNww+PdvjSw5MPPQhP0v
# DATA igig6o4OG0uKitLsoHc2uDWlGbMoTO8DtVPgTzzvsqKF6U0UjtS1F8C8dHhvr30kKl6ONP0yfIm6mDbhVGHrywaqFmdwKhZDNYtd
# DATA qYT3yFWUWLKAohKupAGSJhjzNj0rJ70KAkLF8dDsVGAgEpBMlyW8gSjBm8AsL4RCVEm4rNs4St868OcenbyON088oOR2fvX32sYd
# DATA ZetOcS28+5yguy2vU0I832RRMsWQ3PCXRG/YASCV2XZoZY1Cc17pCa1awLxWerFMrmfud40lX2YM8fyMtwzBt63RHdl2wGxr0y0S
# DATA MaTHD98JST9vwBy3se8ItfGuOvJhx+7uKv5o59n2Xntz+3H78bOnG1vbyEXYygBr5s83tjefmGLqi6FrUFzNybIt3xN46S0im+Gh
# DATA AwlmPJ0u8D+oOhgee/CgsZp0UTYuAnSfrqFR3mrNK4l31wzItBcftp+/+PDJ1iO1FKojMn0uOla4YeCmGRju99kSRa/LvivNIh6+
# DATA T7I2ounOk7O0HghrpW0UF3Tgn8BZDRwcS8URPDdSUKXRsiFYi33FbbDXshWBniqypRWD1eIwiiSRQzOVEkY3xuSqw8F5P+06HYZM
# DATA mmyyzK1RC29XteYI6w6q1obM8HR846sUuggHC29wW77J43oVuFXNKXfq2t1qOZWFq/xUxVop3fhwaTSMLbkFtHes2TAxMy0vzObC
# DATA 2/cxe6O+Dgjrokrdf9kgxexJdDwH+6RKoqcqHSWuH7LOklILBV5IgRU2MVUjIEthMUm23FMfa9W0BbS8KH8Myi0LZWnzWufog/PX
# DATA bVuwUat8y24oI3hdg9thhWIrsnVJLA3U1DSXwQGSMdN08iGZjAexbx789uoWu91S4yw7pYNMyxTUcVI8Ay1qWM1tHkMtEoGVWp9I
# DATA xy014je2+SnYdH3uJs76Yr0kGrt2nvHI5tjoUdVpJXquRf9aao+WI0UGRCCmd/yHqEBUh7R85Ugxqm06wgzWAFPlkLcqDryzL0N1
# DATA xrHV4GFqN7vWucpbcU2cnUqhrAEkVck76d+qUpsYu5nnnP5NtBLFEcIpfKSabBU6IftG4mFbMlDPRIa6nj4H232VoFvZohA09Bcm
# DATA BKqrXoNqjKyNvXNHqnpgi1bCttaxzZMrMeZf65yglmmYYtZwOD3ZGQA4eqyW2tEGVBrwyzHXnNuox7c6YkuDdlnwhFCUAq5SdNzX
# DATA DYnbl36e5v2lS7JCMzFijRJyQMqRfIWcvseX0ncpvq6ySwYZc3oSG3b6a+spuSycRJKbUuUNaYRZDb0ZuVC2eiGOrIwQsLfxwDjw
# DATA yiinmzybmj7jNsdcb7XmGH/AL5V7NcZz/MKVtUmvXrSFgLvqK+LjPdW/1YV6qC6EI4WHaW5u2KW61ZjejOye4dVotIsh4nz2Zkwl
# DATA 3b8dPSEPcg6dOMklvTVHDonzaDg5hBlFL3aeRByfi7N2iCM4x0OBFR6led6YTzrCBv6YTm6U9jgbRF9AgBxeNoUq9XKTajPC05TG
# DATA 2i+T60qzXjTdfncIuMWGj/aJUG2RWknJazefbm/8YOP7m22W08DSseFmSP5B26I6qToROAAyzDmjsqMuM6KgJfr3jS17pOZ0455i
# DATA oQNPHD7XlQo0g0xpaEmbbmQVtYY+RPWziiLe4GN2w+hCodBCGuXpRkuiDAUBrK5UhD9hWG4qHBTxtdcaIRK0fdJu3uIRZAb27Ugn
# DATA vNc+cTkFMzhJs5HxrxSimB32L8YSGAMw96XAAePCqdtBNQfbV6L6Qb+u64ibjpMSZYNlH6VqaJ3VVM9HGSaNV615Fkx2iib2vvO8
# DATA FG2XW9tbcaaDHgd/F8cTZyx6kjGxIhL1Cn87/kKhYjo+EIeSl9i8aS7nQy2/E5pujl0V3GnPlexy1W6ymbcWynFeRrhzW2MiYu16
# DATA Vd+FOuzv52v1lHpHO6syyV+u7NHyG0tGV3XjbIgajQhvWhCJNlpMzRMeo56ASCR99SBL1nmpkQuXrwehnDZ5CCzLgSt4iKLB7VD7
# DATA bnbSOlzSUWq7eXbTYa4fDidZryvescBekFgF1cFTQp/cqezH9a4EpJNlYhNIbpJsj0gGeoeT77hxO70FKmDbstUKUm+MxJPu5TS3
# DATA TJXWV0xbj8QytkJC6GYxEqIJXN2AYVT2MYJ0epF2JuPksEfetVtxMIg02luxFzGdLN1TYwgnr0rpZNU+kIS8PmQdIQEoHAxCCUw6
# DATA QpbbNQqSPZiMW6tLSyJA5qD41gB39c9NN/r9TSw0bB09W2igcp5e/fT176LXv4o+3tt7vltXLjlf/TRoAqSmS/46HHyEI9SKcdE/
# DATA k5gFzZB+DReRImQTMydwCag9BFt2SFgxWy8P8cYwiY3KD5hLxivRS3mdsc20W8dmmV8Wm/NqMMqmtKdyVRsb6g0kPtxqgdMUML02
# DATA 0RvnRpJzajBsxGd5o4olPRkrvz0afDPUNjrlIw5oxgZEsasTsaFCr0vJcWgePqb4kGfEnkhOIFKpt6id/CnBSt7gJVfJOAMBvW2s
# DATA qrChNCGNVh3pixUPww38UGAYtOmuUS9zA4FoOTINCWdionzmgRgJ3G5j0ieTpdMsR7apPXjlNVe0KXGJB26mZsXEkTA43iBMeJya
# DATA Gt8pB2/lzDOB+LbWxbFtp6om4q0Z6kwKxPVbMfe75d7oAHnE2nUmhwTswylsk5B2fsBS6JVmjOhoRpeWA4Bz05S5Wgl6k/7YxKaq
# DATA hW2z4ECQCHDoKXKhpVvodmEHKpYJWCJPcQN/lV7a3t83hMUmpqjl6KPXcQ7J/v8hzmNKLK/syP+FjEsQ6/w7RzT/9d9Ww8gXgkrJ
# DATA BbWDV7kxpqTAdFGm6uBWywcL85r5FhIROAGOyWfvZ7NCHDciOxuzsusRKyEMQa8N9xy1yBtfGIf2uglscUPu0hBE20byQNYheYDU
# DATA T7skCoYGCmzbwyRTKLKgfSE0Z17WOFASF3YCv8zSIHjyHqboTHaPkkRG5dtuMhcJTcV5VHybfHHd6kf7vkYC6HSP/W+wFUmlGshr
# DATA KPr+sUiYr9SSN70dqEX2Goh3BWF463W1YZmyQw1YU7skxge1S1wXOIn5L7vK9ci8u45tFVhl57BanWi+P4gU1aiIpqppKs9kJXAQ
# DATA QrWE7VEx2m4phjoMAIpkU5D8E7JIEX80tED0KW6p4EdanbE0hv5ixZ5Nd9VcBf9Nm3q7NjQ16rZTkNq4hrMOuXkggQxtcrC8ax+i
# DATA hUpy8x6dWZjxlEnwJ6SD+X+AVylwaXuU9lIAvB6yCk1OSV2UEtKh4d2wPE0X0QeHW/VD+VwHQ6uJ9FNf0SKYaZYFRBMZZyiMQmk4
# DATA OyKf7IpOPAW3mla/l0dI45b8mWqBl7ewfrlgs5wJigTo9jhLNJZla6NbIcsJeXiDpXKrvt1iqbbe2XLNvmfTyO2yUGpzSiMD9IU2
# DATA g28pW99mkFuWMGzodkMcsOKJHfEbpaIhJQLJf6k5+4edrhOTnSr58GI67ixSqUVjPk9lkm4yHEvgO8+wPswfziltKE3S5AhDdaYm
# DATA ibVPDxULPdmezZp2Euqq+q7WkcULrrABi41jJ6BvgAMt7HdREhRXZ/nbK1lRwftnfrQxr2ypgNAMVaSpPR/kBumiEMlj2Z/PKbkq
# DATA tNTuJZeDCTmwOJi8iGvmvJAFfFOK2oMMCW7LwnxbIWT5h1B/k34CKLZYVkdU6XKyOreKhuVzJVd5y/BiOqlXWTAPc/WawWiV3oaE
# DATA AvV5IT90SJBC1KDqXCZF7yYgD8kFvZEBb/JUMSXzGGayrWFNopg8TYY2DzIrGGBVpzjjjLck2Gdw0pxHHiTsot62A88mMiQvcuSo
# DATA zeKRToDQJGhsBmMzfNUpwm+D4m5pFKfcmoNDcRIUeG2q7DXhOfKWWjlFHPcTFzvAi0q8mAyzRYz6u8gxKWPWhWMffC4WVcCgIYZ8
# DATA YLt2K4tog5Rdbf5a8b4R3vsYVrwH365UhNtumnQlNDMt7ekAFmLQzzoVFJgvr3C4lvMTDElcKPBAV2+W533mrHc0JE7rRVZaSvNz
# DATA lxLgAbqClQulWbYc2/ydcYk3bd9QQmxbu1YwNoAFDlc6HHQv3TC0aqQkCatgVkpJTomrVR742Asaju1aAQICX/nsqd7w8k4rvW9K
# DATA yqnN8icDuD4baGCEip0aOUlOCZTMshcjpiFpGwrJSLP1c51Oho2HVVLMn2Kizd9ypAv0Z/0dect9gZK4AGHv7YHgIDs7bgP1cNPE
# DATA RBwqm6MjAOk7Sovpl8i0ChAjlIowmU6cRy9ebD1u+HSh5CAleyuAQ9x/R1zv1pbWqtPAwvyHLzzpyrNdyfRt5/92lgKmYafDNTrh
# DATA 3Liy0JXMe2k6rKwIogyLTkm/GYkn4289/2R2Y1bCUtnNn7z+Z/j996+/FFUoxpjkkCWhfLBFd8lf65QMKgo9qy3fQv15y6JzZsvX
# DATA /1fjfv3FV3+NTp9+0gicXRyQ0RYxXTndpbWx3xjhleVDjBFAeeZNqivKAA/wVRIft5SMOvZEz5yenvVR9NOR+dIblEoal6BAw2qU
# DATA cWDguvnpTehlc7Q9fEDmbAIVP3VG5pba2mjDrGZ45Sisnk76McoJg6oM4o2N0fEEj89z+lKx6NtWu90ddNrtqlWzgZaBiVSpxHpk
# DATA MRo4DNDuo7WvNENaMaTitdvae6W6t2ZDmWaPBjo6VqhD4BQx0B0g0sth2nrOyfYA0wMZ17XVi+G6hlJxhuskx6uFiNrpQwIKrK6p
# DATA TtPuvL4z0xtH5rB+yiMzbZdF052jLbJNqa6XlZFQtFIs4K2AC1LPiMA20UTxvMWeakDk/k4OsWCXSBYatwU8v2RTS2XpD5bOK9Up
# DATA d14dOTtOYIZmoRJUm6owq8W337BQ9MwzkQfhwOTJOEvJCx2UwH5mn1h6toP5VsvvMvtZqfth3wn7rlj3w457wDKbo05/3HNgtKP0
# DATA 9ABKacJZEomQjRPnXqrEgJJgKFXJPftoZ3NjT2Wa3Xn8gx0/62yNc96YblTK56MudWCnP43PY6J9sQcXw9NsGkf4oYL/1OTNk2eP
# DATA vtfe/MSlq1x0EPB35P0nErY7OR3mNmSbeRwUD45pqHM0NU7yTpa1xGAQ9S39cWulihAWNrZNtmHtNp3EdhtPUrsdG0PLPDvuT05p
# DATA w/Fn0mvsbn13b3PnaS0yzx+/eG6bIfF7/lPhBnSytTtt4GPJdi0bVxT17WByBvk24q3Y9JYmwr6XXjKtFSA7mb7YvQQwc7p5kY0t
# DATA haQX+CvlxiqKAngkFtp0zqUnj06pKr+w1/9gaDFNbWvCrGATELRPm2GTRmFofkIZs5G8+1xFvPgVJdD+JcWU+9a7++80GX12CBdq
# DATA ePmtr+0/TFh+b22N/sJ/3t/V1bX799Q7eX///r1734qWvvUN/DdBQ1Ho8lv/ff737VuLk3y0eJj1F9P+WTS8BNTRX124ffv2DvDO
# DATA cBHoeAB3tvF8i6P2kBkv8Wx5ND4ZDSbHJyHXGSjfgFYWBPgrCk49o0YBrx9e5e5YvQWmjTgneQQC/gRYLfWI4FH9HuQLZGaAJDgU
# DATA UTgGaSxVZKQ7A/CjfmKf6rfNyHnvnLG6Mhr9dpJ1eQwCSdQYiKUA8Ad8EkDcTg8mFGlNGvM9mqnQhC5MWjgwnQZWROCATk+HmFgj
# DATA 68IHO7MiGx0QZhTnEmOmvGAb9k3PZ0selQCg83E36zeyPBmPLytF0yh3BvFTNv+LLLcWaHaUoXEy02CDPqX3SThs76mq34xcCkqG
# DATA JFvfkL8VnjYBb545g+CsP5yM1Ue9vNuDnZSFo75ADVlq9U3kajI19kLgL20pXkFKlWh0QOdDFHQj3XSaH8Pyw3WAI1/D5F7Qx8z1
# DATA wY51+/DjR5R7fB0vDl2XI3YyIckGOvaYyWwMMzPCdjvrZ+N2W0bGYrnBKzgIsROvw4gZmVHSXlY4VsesV/L7KtO4K5Z3avf5ay1Q
# DATA MW5ZqHVxUx67CY85KzD/VFmBg7Zi3hq9wPzxZg2IEBtMxnYq5Fqk21Ytx+H5tFoquAEJrM3o9USXV+43luD/lnGylEEWy+BDs7kc
# DATA X88z4p30dDAWWJcrXo7t0nlrk4hT0+7ufhyNJ32cGV4GLBHbjiW9owbtJf2iDeUd1Fl9F5GgpQ9uLTmHZPT0Sf2jweg8GXXTbv35
# DATA aIB2ZpHZTvsr/MJvZgWuee1MHoM5FkiiZl+7A5pLzG1dUKRDzf2zr50OTkCMMopMxQYU038pclbMjh3/IMqRYq0LmuYNydHPcthb
# DATA FAuWO3fsdbx2Am7qzXDPgpTdjzc42d9n4h+NoqUPU+DYRgTTTHU/p6hvYkki69JcdFKp4l9osfLEygQXcVl4TyzGgb5WG1K2Gp7H
# DATA I05CW9+TqKLuQl3Uz8/PKedaXffKYX1Nj8WVdZS0mHAZIDQeqxH6ylVWrbgdeFO/u7knerTl6hzGkXBQiidsxzo9uD6or6GjgwvY
# DATA wn802G5p8O0EwihKv4kXtM4185yEEJQ2ZG2WOsTNduwqI1ZXlCrC0kiUKSQwBKo0VI0eRn7dWXoCH3ghCadGgzkogUMbHacltj2C
# DATA lp3kfjySkOXojdQD2nSIKYigXH+afsi9TnaL3vnyWkYYt7byQS26u7SC/6ziP2vXVEwd2AfRSrhrW4gPMERVqJbufsFfedbG0GGO
# DATA jpKsl3abhDEiZTNpJlG1XZYCG1EJaidq0R4f3pCuYsri/d5XBar0MVnBoC8Ls44KI1SVn0LRTvT82e4engoyMvN9uXBwwN2dDp0M
# DATA 8sFcvRXyoT6Cgz52cpiplNvdcUNxLBSRzWu6hgXw3WfQe2My7oRkPKWNZfmAE1xyYw2Vazz+IaLe95aWmktLnp05t9UYf4Yy6LC3
# DATA jpVqnsqqVrlOKzhgJyd3I8lViYpfumHGXDXjlaHCoH9oaZT6Z+kI6NAczUbzP50kXaTpBuOEk/9hkIgk67PEWVuTIufnoHjJ+Iet
# DATA sO5UkaNWkAHhZUawqpNej2I0V0bx/kb9h0n9s6X6B+36wdVqbfXedczJlGfS8C8UydsdpIysj7IxUe9dE+464nXwDuYohYrkY2Ll
# DATA /GyfJkMiUJgnQgJl49He1vc3STwNnBfwTmguEj/e2t348MnmY6LDslPgJ+n1k62nW3v8Nr0YohYB325+8nxrh98O+u0TTphjmtAp
# DATA bMzaieGCjiFvRjdzRfqv+oPzvpILRKqlBQ7IcIpx+aCfLiXO5U0XoxzAxm0qwNG3lqo1rwRWa49HydFR1lFl7G1dih60uAv88cHS
# DATA 0v3lDz5Yubt2f23pgw+WFddCpWgEgUKzZrfVJ2PHSEYBZ3eCHGyuNxHNSo8viTYLzKyNp3fcVsV4EnF/wO/jamMyHAItbCJDqfY0
# DATA h7L9rL2zuQvQF/by8can+OcHm5vfw79Pn23vfYw/Pt3c2LGZlbKNyqG3wQhNc6n7yAyLrUWSEV468hs/KIwIsQB1ZCvt9OzNONd1
# DATA OyqoNVWLDtPOAJ3SdUH7GkgKHz5x+7iS++pIHhzYp9W8pgHp020k937nz7bbHz978hjbv8wjdQfWI7pwfF0Rr3VF3Ks5OExHlJ4b
# DATA OGIAFOtSNYziNIS423ZEiR+mowEg0KSfR+gdSRdWQkrYoKIRbV6cJJOc7KU7Hc4+cArPEXcQyQVvOAwuHuaHLb9TfeFgNZd9qwlZ
# DATA ZzpTBsIo8HEd9qehjdGFppjrcrd1vmcO/6SOyC37jHiWRv6W7ai15UWPKDWyqrxuAqhER5PxhLaqj7aneUTmlkauZLPXoaNqVFs4
# DATA 7Cln6EWO9imcuwQImugz2Nx1oJfHwNbzEE+Tywh67TMuSHrk+x/lQyT4FexIjskIccFBxVcGbTXFRlYdcZXiWMP2DWRgDZ3B94E/
# DATA xZx+wcAgea3UFCsA7OrLK/XV5b2V1ebdD+D/f1gIpRDLSJ/gbn6I3oLQn4Bw59uuAhxNvbCoKycUtoXwsZ/0dhGvU0gcJFcpURya
# DATA 81QI31erhWBPsaXfQstbPRMAhRKfMQ5hLpY+d9vJOC6Qafvq6wZnbvfXzqprpbTKKHSG6UHexXbSjIkFTFtoGF2RUtWoDnt61kNH
# DATA QFq1wY9Ys5yfJN3BOToK5tY0TDM3Ad9DlOx0Br2mdReE5CKpqwSmYemznU5a6gHVRTk2asrVFN3vKmbUrB2nxxewcSh3qlhTUZI+
# DATA M8Hn6g2VtKfqFc9zU9QNLqDGplCfrKfvxuDxC0rgLaX3VSts7cWzrPrh9gMOdtMl2npsRgzpihytFFVm1dwe1Ejd28BsiO0JIWN8
# DATA n2gb4Pa5BD6trswz5udqrFoe65CqNpkqfhzwk0jVUSoZyVzQKVeJp4i3qKAqKGxVeGTbg6h4hG3Jrp1Gw6L6nQAo5VJtQ8ta5i9t
# DATA +K6AR7VBURstcaqKBgc/9+vLB/45mco2LN+r3VtDvgG6q86zMba7LYtxlbwvifITVBPhiWCZcS89TjqXARtJWcDi9sTUBJ078hGc
# DATA HBbZt5rGbNqyipLWCCeGupl+N+3KbL4dPdJbEwFRBIdlTCJKZa8UpWcwh/OTlNs/JckNYeAEYyGhKQ1SMMKQE//IkChLe12iMh2W
# DATA zVycIlhxIQdBUzVbgy9rIQRWhrkONFCUSMw8KgckyRe1LqxFUMcMre2QqlFfKSy0z2/T4hPTqmMcB9E34idqzXzW7dpFCmo70zYs
# DATA TnbcJ3R0lcPK8klwRRu5k5IvZ+MOilylL08QiVOQymv7QCHGMyMMVjogoKWGZdxPFPhpY6eVZJg5rLcCk/BeSXUrJH1C/zK0syc1
# DATA 8+LhZV2dHbLKd2ACkmTaXSg5SlExZtQEdrwPo/q0TbG1lrSYytySJcG2wBlsM47heVg5Jg/xailPi5zkzEQvon6HNDuYdZZ1GbiW
# DATA BkcPjo7y1BKTL9WiZbaCcBtVcaZmrtV3uMWWkhzyI8XV+SMi7vQXbt5FbETjhmO/0CcOHrkf05ObrMz5QIebahRN4bGgEeFQcBbM
# DATA djAfVKXlF+MDFY0TmDlSRNMOrbM0UL1MIgpiFwHfnQ26sedJhsalEoVzX0ZzUPRMLIqcqhw6zFcTlY/78YSVJamQYtw1ObPlFM4L
# DATA x6DTp3lueGkfbRAroXFU13ktFO+CD1U/oSCVIE9a2hJ3zIdAFL/yUaGzIDhMq5mHoVbKxCnKNlBNm/fIYH6r3VuF4YUb3aQmhAdF
# DATA oXeKyimRaZAxtxNpWuyb6tyz8mK/ksk11W2Vg9vkMVw7EIOKqPBgk75n0k3uWWwsORkPJ+OytG5l+mS2htFDJmkA7sEh6pKhncMB
# DATA WtNga3FJvl6nc4Brg96ZUvzpshJWwU7JXYvI1FfFb6pFfsyF7Miqb08KT0TSv6xYXwEXYPvVeUSqMC/g4CPUE1wiI+MsgPKdyhud
# DATA ExhQxQKy1tDkOLXQVoLnz2/a2trBpnytYg5GQv27ZW7D8VYfvdjda28832rvPfve5jYC1x2Vv5BsoFg9HOm8ZEpE3HKaerqx88MP
# DATA N7bbL3Y3d7Y3npL4RclMky4QT9CCNumxcrJpMj7c3PON3d0fPNt5bDenquCYrMXRRgXyqFEGUmgaZ9BYFqmovhYinlA/bZ6uqXu7
# DATA Fq084VekCdCDuc0NMV4g1j8n91EjAAsirkxIiTpXwYgOBj3vx5lHadjMCB5DQ/+0WsqmmWu0qUFD+HD71dliYK7O5Q1HRfcF2+na
# DATA yS4N0oe5umSC4rutQ0zjI9TbzrPPrPhiNdZU5kIs7BuSVaEp6mOKD98wuURFbc0W7bral8DiyEsj71Q2xYonA94C2TJf68tOAu7u
# DATA Mo1nvaipMVm0/0EhjrBuzKa/VPQxxbSoQrrJ6ty414IEtJQc/Yo1/d3s6CilaFfMEaxTpwNYM8QlQPF62JiMz3UOZxkKXQtZ+1gt
# DATA PrxUP22vimZwula4ZqXHdafheqApQ+hahAYcpTbR1BwdKjNk74L7BAUnkKZMQtEsC2p3hEr2qHQoAqJ5WePrUgRtBxA2aJlvRMyj
# DATA x0WjH/CGDiqlLGz6J/daCfVQr3QkhEIzujJExjVSh0n3El4CB0uuhZP922pDbnOen4kKLoDFlWyXszR0gDzhqjOqoaAO0PY4l+55
# DATA +NXr2B4iCW/IKlDABmeFgCaaWvFvUrhonMxtzYJhz0cpjOD4ZKz15jZGBH6diedGtEOaj8hsg+u40h1dtoHo8T0V4sewe/Be+4Ox
# DATA Yp7BYPHquB7eBLix8UsArDhnNuqMH9mmxaTMH5/AJcGhfYdOegQVEM2RfuEyzQsONPEjPKC98vmiK5E1GKE+UDAv0mEUYR+QUFQ2
# DATA XL3gZaQnkxWFAiTIvtuMGgED1IFyeh0BEwfrSo0dAIvlcN0E/JsOa41JbSCYX5CpKzW38iioEuKBL6uByIVmBJa5ZzPc27ejDWOb
# DATA hPoVoH97A0C3ImOKdEgOtkAnQ2IMV9HvZBgNmcJFR4dAoHZ7l8wDNoIdOZ65b7/E4WVWbK/CXvJ5GvIqv8qPZL4szUav1wzP9yjF
# DATA +zfU93w8MOsRdOvGo661ICYLcXFOJJa+wdBV0+bOTG08ZDI3G3Urbh/QUCc10yawo/C1E2UodPZKkKSagNzxgyC6FFo4gB4t7B1A
# DATA cCIMFRTHXZViw92PN1bu3tt98XSX7Fo4w5O4QTTykwQ+VoZegM+T9KKbHeP1JDFPRMhjyOkB4fllP2Z1EFHAJI+3OLfj3uCwEt8R
# DATA 0F+tujiUIXJXsJgs0205QrcPENXZmNEupN9zMWXW5pThl1jAYB1/L2YiumREMmtWf61H1nKTXCmnrifwGrXvQnoJngLKj6/poEuX
# DATA Kg46Ib+R/3HRm5XoITSojX0n4PVAcQvsBOuU9OKyUnP1xJKDeTsg1qWOrItyaybLOVi0BJa9tQwceqgTotKKjsG27ZeSHZrGrM9l
# DATA wwHypM5huRKyEmzFHFJrDFOIgyO5JDVBqHRJF4oTqgsnNK228gYOOgLjSVsmKbnLA+Kru0tLFv3A1puV2Cx2M1r+rz/5X+6iHSDz
# DATA m1qnGODpdMYOcTed6fY5yxvzhryI5bJJ5sP/ZvfZ9mOKQlzKqjDAeTOOQ7/VQIayFzBVSfQlym3YSq9hqbksAEDdAzWMAS6hiZa4
# DATA Q0G31XIP0+V36oj5e/rPzxDxe/D/vLuytuT6fy4vL6/e/YP/5+/X//PZeT8a9IGYHlMsn24aHU+SUTcifcV69CpNh+TlhBcMcAhF
# DATA ESC7lEtjA3UGFxKLT/MEzYaSSO3t3TxPJuOsp5/GifbVNKlKtB9oejrEq76wsIcmgpHKVodyXo5aRrONF3aePdtTknaOeanL1SkA
# DATA 2pEOyrjwYnvLK5sTuOjK37KqDRWaqGqpGe4g8HYzsZBfixOuj9WzbqYYrkfQT5xgMH+VNNFJhmhF12aszy+nJOLj3ulfOxGMGmc/
# DATA HZ8PRq8c+3pt7KY3tpEN205JyjWTdca25NsYtSNtn130UoqVsRRR7F76kOXtU/gLRGU+dl9PKJkd0XA+vWgHy9qIpFhHnA63nmM7
# DATA sH79dGwbO8SOAohzS2Nfen9QFY7qFGgEJpOfUPgMWPXDUdYFUrwWmdzzrSXt5Mtx6NRS0LNQHVibZPVEnqOOWDdajX4cXa2sXDtK
# DATA M/nyMLq3prQxSIxVhlUlVsw4P58mOob4z727d1fvGm6AW5m2YkqahxedSru6O5kuDmR55X01kunWNI0m2tPUlu+iOc0h5/48xNGo
# DATA xuYZz2MMwT+SKsrmLTnNemTzmQ3vkbta3IxZv2uC82XD2NUgHcVXXPE6yvG8RldU/BoNdNGJUAgkNtptRZU4y46ItboiPgsJV+bS
# DATA bB88a1bWlqoJcpqbSHdB1I58VAmItQUJ7qo5TKHtJZN3U0Tv8zzryBHHLKXseXqIEWJoYcadYdSlJq9M83rU5JlterXHLffmKI5j
# DATA 1m5neL+uCNJeR1dXC2gFAe2ccmxIeEPzpGJtgYXAMvYSoKYF6KxH19cLEeUdFsIOm+FqAMdRRnQyGCiiD+i5wQgNmOrLS8AEoAr1
# DATA Usa9DrXUFt7uDW7La3jbGeuAtbw43dFgCO+v+Kyg1M9akavoyuz9aTJE4rUmN6p6DaM1DZtaf2zmrL9eyZJf20NIySwgy0/Sbk3l
# DATA C+0oNSkbriOi1Y2cpuMk6q2RnR0A3rN79axzCncc/jm7x6sEI+536/00Oz45HIyAH4VFQVtf+2XSRW0RvRvBoqfqDU4HLhUs8ZAV
# DATA 7yt37960c4ej7Y/SBDaTEpkNE0ynUR8PBvXD7JjRTF1p9ilZLewVjgU6gAqnztryHpmzccQuzyWnQ32dcT7mOAlvvFNXAkuu7cHD
# DATA /8NdMbHjOijR0gIIQQ6IBBbELlY5xRWCP8QAqduPnm1vbz7a23q2zd5RYvnogG7TCJmGrHFwD/0SLSQBs3azY6xoMWo4GLJHQYbN
# DATA LR+K7YNwkEKXookTECcxkZs50puA4Tjn3x6OcNyFA8cDxfLhDLgOTqEb9bL7XkyZVIOZ+ZzBYiG1Evt6tIVQj+Vp7RxbLJEiK7Bt
# DATA vGhI501T7RKS4mSGhPLJnUvChfOxJMevUQa73RJchh//1FsQs3OZbbRoayDs6KelfUvOX3SCh4ZUH97CcdqhXLQXfKieSdoY2yje
# DATA WBDRCiiZqVTXcbQbPJKGDKPBxRtiR+WliPH+U9NYImTDypRt0paQFENWTFDP4YhCs3GprW58sN9cXlG7rCg5RsYMpTW1pok6TqxL
# DATA KAtWsadpEUvdTYvbPxqzZx4HR6AKvL4pviA8pyh3l8RVLTV4QOSWTJkiyprNY7chq6KP33c4DI3SGiR9phNoyyNom5tTdzTp54mC
# DATA IZWjuJuSnVYRXb/kONihgRN5LngfSRpaMi17UtOpd+jfI/o3FibG6r9arDGlrKQMQzR6nvW7g/MKOujLb23LvEFIpKtnDaNkX4lO
# DATA b4DuRWTLDLN6BLjtcECUFHK5GO0ikhsfdUYJAHWT3vsNdz64YdOam2vH32zXrZsAi7Q9iAbnaEPMfH2GJjKUMQG1S8Axsg2M4lFz
# DATA wHdZr8fxSacuSk5L4S1JrCmfeL71ITsMs7UhW2vLAe/F8HiU0F2KOEeMzIlUs2iCo0LL8CUn84txzic2UnmpGnZ02LLTWHGjAGK6
# DATA iohNeC0S98ak7Usrfga3C3uBhBeO0G2bKdwpNKXdVrV4u/imkw8xX4oZmxUTnfs+uXVfx2GwFtwou1NYpTfrUdYIfy7fPeUxKChg
# DATA x+71PPzJ92OaIabNDO2kRxOORBFJecVRdmskKBqMEjK3VEKjxukrFOcMUY/Woq7YsJIc2I+yi1bcoPNXD8Ut9qJNHnVNlEls24sy
# DATA ib3xPHmG+qu2kNQDLMS1HOTG6d8UMkGLKQRV79K5doOc/WYkRaCu5xMJuUoDakqoVJcYYFRy5hn+kOKYkWzdko5Njs4XrTgyeaPr
# DATA S8goVXHV7Os3zQ7DCFEsQ4LFxvlJBoRnDO/cgAPwojSTL0+6YD6r3vO5KXwWPyuvCFnYBmoj8KogNdeewBxuEU8A5FcKTzPKk4Pz
# DATA H8G5WVpZmbY+L/roWRG9+OgHkbVfql3bk4s7UgkmLa0S8IgS10gV4mH4MB/fNnbbW7s7m9+tqFpqrDQb+2XJhP16xTm+xTz5jqOc
# DATA ad+YBm9jL3R8Dl4CQh73MH+peqWkKi/7tsKYg4x2WbauSxBt2mIILp6dZslI8Y/SXE7n6S83G5A5y4sroJWMyytexs+yNirKp9Q1
# DATA Z3EZMKiTdxIUOtKCEAUY7y/VP0Dx3t3rRUBRL1Ezy21Vp4JgXHEZCWUFmPRPZXXY7iMPQVJHAOV5mTNq4BYVWBabOht8vBfFMs6q
# DATA n0GoAteaY4LHlM1e5cAK7Xl5bUztMEctMrkxix6OC2aatZJZG3Q+b1/i+Uy7LkB8nqj3zgCLg5t6+7+GGZTOImxk5B0IOZPvaM/t
# DATA yP/otDwa9HTWWFYRiHrgjXCgtMhZrE8HZ6kTGOdNMZSEZ24aYHAz/YRIOgvGDZZ2Ap5WvhHtBEFQWSZfTfH/PwysJ+pgJY0r9H4C
# DATA I9RWezoN4v+3hqT9b4S+HiL2ugH6Di/SLKRqGcEAiqPYWY7I8aWP8R9xNy9dpC+du+j+OW2F6J0qiCeT+tFG/aNGc/HgvapC/BWD
# DATA QCvfadbMU/U7VR+j+rtCo5y5RsXFmYpx/ZOkoAN1hmJUNywZwicmIUylWy2BLchoMwRBhQkZjnEzKwfKOb+GRohUw7v988/mMO0N
# DATA 0PtlPICBDMYn5D1Dgg3bYwdgLpJw4f2MTYRS4L+1H08A/DqI405lP4DYDqyVIfJrH/NOGmSHBg6xCdIRjweEC/uXsUZF8G/VCppK
# DATA dmf2xZ2JfGkagotkFm6i3hnY3cO04l2tfAe/NsSr5+3MQ5+sME3I8ytQJ7Ooq2LzJUs1k/pwQzHgXjkctr4XZDlTuCXNhRuPyFvj
# DATA o3j/Clbu+qZASTTfmgch9XaJhjNIOc+5keYwzpVtSR13j9wKrLIIhymDkqyXbYdR08QZT5Ad8lEGOmpjeg3btGYKMQR7iEZBBZKh
# DATA Qm9tPmqabkOKFygHMnjxPtnYcQYfxRiQpZ++Uy216udX99yANYt7lg0mMEHScTrJ9Wjcfg5uG4kSaxoupRfHjiTtbArhZbtzpUii
# DATA Ms+JtqMAFZyc066pmFVq2/nE5JDe55I+qMAOJ2yK2SjDquO0rvNymgKW67VFM9csBaHR6y6oW0CqQseWqNyOyN2Zt1RFoYyPlJZq
# DATA m+jENIaIcwI7V4vQtM24pGJ1tqyBZlw0VC54nePEWqQawDzUeWN7TW7VF35YYsqqkWsUx6dCmbC1tqIWWkUGyEckzhkqBFf1Wgvz
# DATA fU4TPsAOrD0dqjYlRGq33VtVUtnZJcsG6UoyhTUjGUqc5yd8f5rqlHGseHwJ72xZrXvfmu40MM6ovipN645cFwaJpwYvU7z/op+N
# DATA DxYeW6jHUF7EvgkOorVY2ECnr5bAXrTAb0jMLVEmiyJl4UPC6S2yCqQQMVJuYX+XSxwsoFV6C3Y4PxmMFzYv0s4uBvZraatXsXiN
# DATA ppl2Lqod0piGgxbSMNEWvHWZ5gv7W0xlHiz8IEFr8g8vAwOLYw9fxmwa2hlTcrRuAvi9Xx+l5DA4rWTaV1d9tlGp5edU0HDbGDiA
# DATA fQvugd7Jt9ByQZ1gQ4uajoiekYounALcunhTnRYVCJtJj073OrNoJ3uIPiVnL5qCv2I7IeHL+FWZatynRGH6+wRPyycYOBkcHnie
# DATA DQ/A+3lPXElVW8D1NSZoZCW/4yFkUs7xuZP5Ax7lX4g7Y9Ef1lGhph9I1U/66GxsVdPitOnJBxl4Ti1CAJMzD4ZcoZamVk6GmV91
# DATA ziyHVoVpHRBY5vyTN8pUqIxCWnp1fS8dIVgk9Rzhlv2VFYpZIcEjLKKlzAfcEQYh2TsllVu8IwSYZ54dHLKzxzqMxHRyNKy987MW
# DATA olnJUXaBAZVhPHW2nTDem8nZAG2/MBfgIskhRgA18ijpjAa5Ma0YGYOSAhPxDRD2qtsbsx1vPDZcDyt7o9oHStn4RhkbPf05514M
# DATA a9DtHI3CGodzNAZOkp+X1xaD73O8OMRtEjmuH/F9gGtdmlwzGGiOwmsVkjnYSYD5hnn3SjMKHPzJcCGuRmnG9XBn90a83kIgh7o3
# DATA JmNf47FZdPE1K+XPxOKnSIlgL68duL6UQ5yZ5dsS4rheOzfQyTiNTdfF2DHloKCtqy3XmHlsBU1YJQE+qEXy7Ez+YIrcKljeGK/e
# DATA jMWg99UZR46wr3fQLAsRH18U8r/PCbjf3SGeGhSDL6a/C1MnMVvCVbY21uk2jBrAwmq1PHrErPvPRNS7vvizZB0lDAgTEoUz7SkZ
# DATA SW1PRTQHe1CtWjKS8nWacjY5oXEJ1egdLNvctIAndBPTpOBfGz3vLKjPayCTMReLND8jasXaeWYZjzLA6a5HrG9RUxAhl/az1lF4
# DATA Zvukixv6t/7w39fv/41A52vMADzV/3t5afn+8l3P/3tp5f4f/L+/kf9KnLKTfMyO1yQSuRhbvtfyhrXFOm9uB5lS7V2djkb9QUkW
# DATA 35Pxae+Grt616PlklD4f5NlFied32gHaLg+6fpvcv5Sxd2Hh0cbexpNn320/39j7WNF9RuRKmeURLGEuCrkbbaADk97gGGW01YWn
# DATA G5+0VRsffrq3uRuhnYuTmY/KPN3Y3vpoc3dPF1q+t/o+f9rbfPr8yQa/vcevdrf2NtsfbT2x3+Gjro3We1brm59s7e5tbX9X14Hv
# DATA 7gdV8d5aYHC61OPN57QM7y/s7sGI2hitFBXjDW1/y9h/4d88e7GzvfEkUKBueWhIYeKwAk0R27ews/loc+v5ni5gWjpMOq8mQ2nk
# DATA 2ZPH7d29Fx9CkcP4wa3ugA4ZHaCHD/DfqAfopHU77d9++ICcEAG/jDD69e3J+Kj+Prwl/edDEQY/WOTHB0P1BjkxE6TgweLw4YNF
# DATA ah5t6Lceb27vbX20tbnDhiAY6i5DsiXeT+qfHeyzP3P94Gqptnb/+iWmPPt485NA2SMy4ri3xmUormxpqdUVLrX5yd7m9u7Ws+1d
# DATA ik7XwFGRv2mHk3bAEtGf/Ixi5zTGF2N5TVR63LiQ8ufpIVzV7Agov/ha5xjehcVm7t0w8sVc1O1hko3yColqfe/+q2s7pn7NMMJU
# DATA OhRZn6uG9EFmNPHjF8+fbD3Cg4hRY9rf2/y0mP0AY+87mSmcvAdq7LgSFbQhqjaD2h0rvAxHSaCAWtVgKlYyRepSCBvg6PBsFT1q
# DATA LOqZ2xscYs5nXsM2up+2+Lfrd/iin+nIOOF4ObVoJ+1MRrmJe1OMn1NYx63t72882XpMq6hSI3Kic1keAnGe14QXqd3Eaqg6xnpu
# DATA opLl90l2FL98Sc72fsJxf2Avtnc3Ptpsb+zubu4RCI6NRhKhsQ3obZ8H5AWVcjE5zAe9CXCoVZYtjOgLiRP4GErIcuWawaES7vre
# DATA hjNjFRzYYQvoon9AUQuwyaDvIn7grFsNunwNTqeNrxvA7OSIXCrwLVjZG0blO01AtT8ejvo/TiYXP+5Pej8GeLG/DMP6cW84ph9V
# DATA KPSy0bhT/Y6MCln/xlaRPzySUSilqFoV0c408snRUXYBx/cceTYlXjFAqPoGO+rkmpdT1x0QXX/jc+dsq5y9h9HK3dU5rsDjZ083
# DATA trZDBuQamEneTckV04h1/uQ46/YTeFR3P8k7WQbPslD2TbYv8k1uqBqefUfVgedgeRR5hKc7LcSGnFk4EjZqurd8rb7QKQFUl/aq
# DATA Uy1TjOM2ljWgW9noNdBG76YLH4TRKDcW3ZuWG7tWOAwUEBYYvyWdpSAEDfDSuadcHXLkMnVLDThpJ45Ld9m5JsLMOta4MJ2k38Vk
# DATA SoTw9u+MMPhojo7FxhcM/Yvx8WCKLpWSt7ZMa42eZ24rR+sjIBK2B+OPUJYciKFayJMlGQDJQvfJ9vcq2I9jnXsMxNIYwCZ+oJQ6
# DATA TP7iu+xwwpl0lqoo+79YsyPTBdeJFmj306dPtra/5ybKMstExm2wBUofo4f3eGvHHd6MzuxN2dh+BOT1sx2308og59iXKFQYIiph
# DATA NVB5l0FTLbuEtkxWw/c+6qa/v/dJdZ7V+sHOFlnmlEzBrFvLWjejagKqFWU4b7+aNJjtZ3ttqLj5CMbx6Y0HQkIptvgtWIYXzp16
# DATA QSIpPBTLc48Q2nvxZGOH2B0XpOC4FEBRaS7GJy4EsSGNEX8VrrK+yPtc9I59oQ+qBQdlc3PDEun2afIqbev1qujylM3i7t3y20KA
# DATA yjRfgFbUOk3KarOQ7MhZGncoPEHrkJBerc1zFXoKsBg/eyZe5RGlab0sTSS1P0UuCnfVbFmDQ+zqioQU2kfdFvfI7RR3UuaHwml5
# DATA TzFqyg+AJUdlR+yWUj0+237yafRjDR4HaOtk1JAMFAufP9za3tj5lD6GFJRt+pd7pu4oyP4h6yuB4kiT02bROQHrEzLgEg2Ez/1B
# DATA pTrdFYOrO1fOvDKXzn0v/hWB/LLh20hSCUoTawELYZRktLQXHCnoPbjjuhQH8541O4lQQ7ybGhgZ2JoxZ/1BzZuC/Uz52dt9TitU
# DATA oV51Lf3ElfSjrjOFJKD5P/p4Y/u7m49dIISDhZP4x550TLhoc6ea3iHWnuOOjl6hsFsahZlBXWJGBVdlbOk1wweanjSM99XrKmEO
# DATA WeoMRpa23qKU1OENh/jxeQt0ciLia3+56aXU6pxkZNpp+kC2hRrXF94MpuqDC1LQVMoKOLOgnkIElz5+Zc2geOAN8X9ZbPObkAC8
# DATA xWZwYW/94GIIMPRhjs7uhGYU7xDel54ap193cYPK1RL4fDMF6szjUVST2lfYXW/ri3MdGEnxPSvYqQTRluwJyoaUJLkSEkqZvBGM
# DATA zGxBdcNwObWoIIF2GNECtzAPN8qQTdp8urW7u7X93SJP6gxXh1CUcfsCMh18In45Ire12HEWMW70qluUVeFzAcVxBivOyE0iFOVx
# DATA LtIBKWAkLNgRe5vRB8q0Lm8R/83Acop/ddbkMfy1Rt/DlGeUEZH72Cd5Ew+raWeXTS8wgHjOgZaSfMyWdxWpL/cyTs/8JMOeTMQ0
# DATA 0zgcdDGRFDT1aECfSRbFoTG8Yg0RlYjBEWDbdzB1xG8yF5lFG4fv9+05Bg5HFaxIGyDV3sFYRsk5xWW5GGuJjS2eDQtZdy/74+Qi
# DATA KFudkVHpJmMMyHNInJOcI1FTuMLz3k2b8BKii0Xd2HCJQI3l0ZwMFm9FOhbi6hbqFvLOSXqaKEvZnEWWdJqw0L76fuA7b7tfvYs1
# DATA 10opEmpwnouQfV/GcFAyEywq+UILImn8RhJpR8P2hkMKqDmgfeIRoRsHP1aKY/QWG97IWku+Y1RDsYeoNo8mT9CsJ+tfwFrFPjDf
# DATA CpuAGTGpUVnZokFVlorpJyPXC/WnhIxen6h6cbtUbxssPK0qIa16j4f9NLnITienZdH+sK/BqFtB7R1sYLS6wpw5PMqCS0ta2aQa
# DATA 5Ez2ajkx+QRmpHdXdfXeUvWgWn0DYGOni83EWQtXj7fpYAq0phLWIcDPq+qc0kd9UI3e9yYjpApOOttel+ITm/TC6tgyvWJ5X1D/
# DATA Yf8L1goFE0nhy0YH6C/sqkIZcKXTYopf6cwclPjlxdISiWXVOOSUyKMPvBWENArwOcjqqQsks4ivrlgqfX3tDEcR9jRLS1NDatfq
# DATA vDQ9N90GwPNo8+NnTx5v7mAo1r3NT/a8kfDKUWRSb11dUWac9bvpBY9CKWX4KOKiri2thT8FocdVnBxiRFGlSaanRauDa04jknNA
# DATA Vzmmc8nndjb/7QtgLh8DpfrdzV1DPi7YYqFcTie365heYxLPscpOW9WOe/r4um8UP9L3lIV0bJWwjmXgpk3kpBvxXLNBchv27cmT
# DATA LVR9FdXPGoIeMEAoVW94tL4U2b8CENbUUM3OSl+Zhh+q1zYW8rgJJvTgPh8YcRgZVzIyIq1bQYOPC9ZUV8BQ69YVqZGxhYrzxM3U
# DATA Isq4zlaEVQ0aCpfG+OFC6wtF5VIBLondpw1iFZSSdPRyVrQOcDbYcG30RY2l1orx8+R0WoPT678BHbezuY1wwSbjQmeHt4+sj/S6
# DATA Y6g9DDAtG8mvkf4Trapss01TecdEh9GTlhTgcGmagNLle9vPfrDNkFVRVu7grfOW76vmD/TR0wq/y37HFoRZsq5WQNY1n4xiuviK
# DATA z9lN5GFBuXNQckGCJJxSSOAQ9IecJrSxXRGZZC8IbW4gzf7Bjj1Zx8dm85NHT752MbeIftA3p0TYLcJfSYOHDIn/6ag3yU8qTkRL
# DATA Xu+C3FiWkO9v10tIQifUTtAgFgZpP8dcKKTUZ+tqtj5vAzxWSdLzFAPQwzblLYxOU8OkEhz+4mXfshNQXKeMAyqcZp1AbNKSnbOj
# DATA jNKptcwQLUM7WioKc00JwPCftQplABTlCK+lFe3TW5GA+HaK5G3+6zdDTDhPNNLprrqh2nK1rVuejzpt5+7CRcrH7ZLrbKBRw/4U
# DATA Cotq+ixR9JVFQ1UfgsJ/Z8Hfnf5tjnB4Jn6rtXphsSXcNOT9BkqhJhE0eBb44OkumCkcjEu9K43uAvOVjrpW8HxKAQiPSwzsAKVw
# DATA 1PV96Qg4OV6rE/TZku9NlwsaoQvukMCkFGgMB8NK1TvwqqzrDOGgEUfHMgNTFXaQ2y+9MKU4i+t9rVgLvo6yVBBFTvrjkYWPcKr2
# DATA k5WVnUg6mVlx6tJuM2h9hh+JyC0tZQvJ+GAAgcVMsmfsjMIn2uKHUdGWuVlq2xQmyPZ2NovqTP9OYT4cDiy+yDOhDQpPgXVMXIq0
# DATA TFCzNzhXfr55yI/H3BAMUnaWKjSgntvjAd/BRoI+ZnD2KtWyBZxu6EKb+Tb2P2Vam3DgBTMx2lGVJaISGz/hmp51tby+usqqvlBJ
# DATA dApQxRyuWR72YQ6dU4lCUNTlAVP7OsOv5lTjujc8hAY6vtdyhlJamnMCw0Hy0geXt/91GEMEQ268hYFE6L8bGE2U7O07NKS45W4P
# DATA 2S2oF1l/QFfQsWOwa8BjtTnTNnMes4TyeygpddGpwhn51GqMcHXl2WM8FL9/2yDkFHhUjPF6r2Zaqs42RZX9oRZnd/y2C2SuToOj
# DATA 11Wo49mVzMrWWc47Rz0WUukFWv6aN38+85uSgX7j1jfvcvYF9EORxgzmKU5HzoCVXL06g7UvJZtuYKggFLIHsjUTp0RkQh65yd+1
# DATA jAXdoT0hi7aXdsK821bUoSgkHrnuqBtte7uit5ubdqlNYZphVDI25vVluKFvetyVN9Rkvsr6LEkVSRQJU0kUZfRs+Bl4m6K+7c10
# DATA n+Y1dU4v41A6C7+7wBT3zcDn0fD5VQruJVpCSAVlIQ5o1dxXAWUOFxCBrFn7whS0fsupENBzlfZBu+HN9+PNT4oTpXJzuSCwbfqe
# DATA EVcaybPQR1k/cgZcVIyFlGIBHTs1N3XwVOJGikh75HMYGiLCAfAAVHFvcImBoEJSQ/MVeBntp+lQwKfJ6BUhisPQAa6fLasUQ64g
# DATA yZZfchMFu6RNAj+eD0PRL8Iz500x/iy1R0eWf99UI4hTjQuuFc/TEUVGEPuPgM1HOdr58MXup0U7D4ert2lbO7zRNKI6IKMLrZAt
# DATA jeiP40AgPfZ6Ps3POqNx4Su/JodcoFksRFRTn57AyfjwyaPv1WwL3nKuqhAvy2EtrEhMdldOPCZYF+t5+8PCZkmOxnewSdrK8uam
# DATA lTAWimJR6aVH6G+XHZ+MXUSbX+YNhMQAa05tq7UYEOzkIi5iWLp6HC0rOxQpMDvUNx49fvKkwoGKJ3naJsd6K4DH0aSvkvipIyVN
# DATA cHQ8OCDJeAWOFTlVqUHqWgUZYmFAqmgjGR3TiFAaJ2PrtCngnX5Cg4320Hox4/MEvh+4vWCAGvTxbjmNFOWjuPbEH+KPtpL1qq+8
# DATA J/iZfrUDQlTVY8VpgAhjEenjB7ph1ZrTjFuKvqhiK5RKdSmUq47EIxLuuGvND3aNN9Uo56gAOpHS+8bm9rPdT3drkTwRTNNPz55v
# DATA P9vbffH8+fWUPeSLIZen0iETVZT8AR7Vb4wKBQO56Ij3VtJeR3qtvpuTqJCLLu+Jha0vIclw2J5iE8UrG5jIlmUtuyby3/yXLHBH
# DATA Zl6u0tsz8wYFZ7Ox9+zp1qO2UgADvm2/2N74/sbWEzQBt+14vpHrNu+VK1w73nYWzNDPwtWzDwwWs57bJYojfRW9Ju1rJoa8cs+K
# DATA jbql7bMmVZb9KJPGeXLadSzu6sxrpKNNlSJo0mURURm6ZgtFFPtm54nVW7JytlLAu42iT7qlTJkb/j61lYrbq6JBBkftoLB9Fnnp
# DATA Kj612QkDCsu9PxgXkVUNpjE1ysUo5t7yGH9rohTZOQfeqP5aViNk/8jvkez3G89FsaBKG4sP+T6ns/CHG4++9+J5G0OoTXN+pliH
# DATA RWI9LAJQeRn7AO7QWowMpqy6BU10UDQwSs4Vm13CIzjcgYkI45l6TOP8i7HZVZABJ2GCSUSnDZY6KVBazgFKRp0T1As0y+QPUgDG
# DATA aseUmSKReAcyBTNALUKoSaC8b1qWIPFyCiIFYerNQKmF4okri4gxPRiDy9bKJXYMpfZtRr0ojlALQkt24Fx77UhckA5I6dniASlY
# DATA rc4vIeAbG9uUjDlZ5hY4TDK7HvjH0C5ccjmCpauBVAb6wHqwAC397dtN4A5GUwCfRLYYIY8szCyqS8CXK1QtdmHhB0+EZ/wRQpIL
# DATA dokcoVlN6lx2C4vUovHgVQok5KDXrUX99FyCPKosSXaMCLUPIdC2YCKulwydvY+trh0yz0IRJixyNz3DNbXquB/n4kp5jUke9unu
# DATA 3uZTiwZUx8PpAg5LxYqThSZAtESWWYPn4C3NkKe5nRV42k5aYpzwkdZOJsGSLgzWUmsNRJvRsoKjzanwrFYgvmxg1gxAMgWJm3Rk
# DATA itX57Dejt7lKdn4LpokUflLnjI1lHBwan5+fs9sZHkIAW+GTigXgw818jwUheutL5wJ+yxUSekmydSDZYJ92TObR68qyAT2VnsNv
# DATA vHDOEmKZ3Xewgl6ralPkbsd8ufEF/bi2/ab0aSLcrExvvRh7d6KVWSuoa9jadmWv5+ycHfCODTKDIYSYJjrK+ll+UgbPHDmocBCW
# DATA lSvn/vWpLzo5lkVkclwo4hgHUokQZLByBs0DUQpdB6WPLkQlvM2nX2ZT1RmTzCc1EBKTQAsBN2CSPqhyNbU0vvxxvgG0MH3XufWF
# DATA VmhK51q0J03UeNWrAW9l5ohcRGN7HMom18z5q/qWenkezK8x6yhxMz+CG9InW7nSM2uLJKV4Uf2nPryxBlAaqJVcx7cnuxmcuXBM
# DATA oJYArJoFnzQlbsDJu6PJ51Db0WA9IpUiPha1WFy0GqbdrckeqDD59ikIUe5FJjpETc9J0IdjyPkUPu7CQS3SD7wJAZI/uFq4eXMQ
# DATA 9FSslIngTZ6bi5Diutegr5QXWs1ASTtOZ6zmrdq8Ccext7OxvbvxaM94GKko7CGFuGFqiCot5Z5c1kEaYtHnPHjDPZgLNyFGA1Ut
# DATA tGNIRINZZmK99GIIpCx5NVrnYMGyciwedgkUz4wn3hvVyFvuS3se8cgsRqQzGZEMq/VWNJToic4UdsI+HbxXk2ez/Sp3bI7Jc7C8
# DATA tiehDA7h5SywoWr4mp80993k2enRYTHrTl9oZVpqADPF/ryuLqnL6QAtoLMwjRCZJkuyT4dDBtxARCBtdfXaa8pGC1hLgZMlBx5l
# DATA x+TA5V4tt+qCqxQvzotbqU4/9Dfk9s0dO04dOk5tL646PuuFCOpBNEckM7W5ofAY32Cchmx0e6lF/gXwSenwNUF+w5ulVPBOdfnc
# DATA zbEMsNc0VNNpgMYl+jZAjFoj9QPBlZKjBVU996/bdA/uDQZpQaBa8T5MgUW14JWhOdO628dtxsJbWzRFwnOTqQQmYINAGuB8WEV0
# DATA M4+efX9z51N0A//oydajvbg6DW7p6c6+XsVpFXeyuDms6ywBWfq26zFR2iWpPBNaTp3wN4kbpcAtjXDcpK7lWGyuOKcB3ORTJIFL
# DATA L85WhpaYekVFGmFKi/izWkr82Mo6Wl+/JzUCYddsDaG/FcL0XQkPIkIjhT5DZ9fId6L4OO2nIzqSUFHdE0/uoy0Vm5pg07aLM4iR
# DATA a8UlA5M8zpIee0ir2+qY4cjLcj80bZIR9vq6iW+yljncxD1ZDfAd+Xo5YhrlY3Fz9y5Wf2gEIW7+aHIVctw6ykbkZNLHrFBSwreX
# DATA UHp+Klqe8tTbFL+miYhoB8VAtrHY9XTr64KBjOe6xd3N67oVch95y4DLxVC5D1kn6HiW3GJzW5UlozrnRAvSPGfDkXqy1rfgGCXy
# DATA LQ0WpzQVcgmbb0SOorlsYM7cSainngrCOD3aWjE4XvVtZxByF57HD2CajSEGUktHZyFbXjcEn5IZ+EjV1S0ulCyGCCmrxQYtF11B
# DATA BvhlgrnAYz04lLGpjF7NSPznLcc+RhwBbci7Qwc+wpF3GnPZKENSsEpMDYuD8uNrtOIRAM3BKfmHkM+5Cg5gMWq2CnJqJA70HkeB
# DATA ozSlYdPhYNALmMKrQRixmH7FVgA8NM1xBx0CdKSQueVRGMJnc1cHljN75hjsOAo3czeMKCdgYi7MmCk9r+jauH8XpNewKiHBteOC
# DATA zstt/FykNXz2KQNdaBpVYQOm4P2kUjYr3yq3jCrohjhGIo7YIuUcTmTB0lf7vTItUmb+rxygzlIR/8yjrNKDUvV8ZsVa5CD0ngNk
# DATA cISNAsTQvFfQncsGF3p0rsOMCxOsQtb7AxtMWEXk3cG17+thH6g3PkDzHaIbiR0DeCDEZgRmERahlpPN8w+epXWB88tUFi8RfkXh
# DATA 8JXTQZnr2/6Ba9JWm6+W9vSbQjzU/Or6i+P+VzqAqUclxOfjO4m85CzGmyz1lEBPHG17kHXYjDjrQsXsKMP8nEiYmEeJAKWGX5l9
# DATA SEy8TaRM8Y3VXKtVxONVI8jM056S61fmxPcevGH8L0n/GjzFisyUQ5JplNmyUCbVUl8czl2NKBgO68YhseyAkU5cLNWPFRfL+Pa/
# DATA SpGC8OP6FPT/AQw71QrAp2F9MyEREnnpKG4aOHKcjIDFIX9vHOZiVAiPIZiLCzb8GCV28CIqoTv27VpNUKy1NXe8EqDDRJK7krnd
# DATA sWP8SAhBAKucP/w4bYyOe4PDSnwnrlavaxiLr9VLTg+7CRVr+pnEaipLCHsKhCSxfoSUfipir6KxzhRjKMd/takPqfFkbSrKNez2
# DATA LB6NTRXozwNyZaE3HWHb7HNwXda7mGPZlhcOoHSMevQKlVj2zCOaC1r2OGoILaW5FbAAmde13JZ139SMse3oJ61XhWyCNvUkUK8b
# DATA W1RiELcQgIuFzwkSWwG7ujLiq+zwObRVYE6GqlIrZRNVKroh5SEvsmJcsKYFh23TWyn3FQyWXqxdbmUQKD433/Tdze3NnQ1LXfy1
# DATA sk5vyl0YLb41Ii5V9fwmpKjlFWJ3qoI+z2kfoRojJ5wbeU/E8zI2aFlUykdWHZZxWrmw/dO0gD3aTqD9fHP7sRvv1mgzSmjgmwhu
# DATA ioqLwIGl+c1pEyEtzTVPc74DoFDU0UzmlGvcQ4aIvC6eXYgzX11YKQQRb6t3aC3LPaqJvZWuW+BRt+3tS9BSX9hi7ny2FY7xR7K7
# DATA 8DfJ/Wzvlpqzzxx4I3b6m0lNGm+seVGYHBqjZ6x5Y9C2+c6ln47XuP5bCgVcgYC3jA5j4S1aiVkytelgOTNlW2RAwaALqI3kf0DC
# DATA nrl5LIFeHJEhFOdZb2yMjie42M/pS8UK9NyKtxiBR4eTfhfQeATgL+lFCGQVusgJMA4m44jWDeVamBMBx5w3dEJdbBljjLcT6awS
# DATA 1+t23DWUS7aeazFBWQ2mNqeWseKswCIksDJaiDq1Hq9efcRGnfONRyggRC8dXjAmJsZwcKb3hmv0BtXk2Mw9QAWe69YhUniYAqxJ
# DATA PfqDNXM6MNVgmmr83MCBF+4/X+Aiy0+mFFRNBl4wyqGPThZHo+6HLyH04pdRZKh6FhH4VL2bTJu9Zc26wlz+dAKDySPrdBJQDC5l
# DATA TZ99fRRwFN45LayTQ3K6C1BzVqtWugjyJSgqLWrxZ6+zWbP51stfHKmfmCXsRpM+8Ga4knhksOlJDlC1ZE0cjUhwTZRqhB6MasI+
# DATA AtNWZTjK4EpYgZe563kiL1cLqGNplhorEBekMICrmEoIUqHfyPQXxwN0MfK5LYwzkI+BnR8VBrQMIF9fV51wBkVtJsmKFbJf39SD
# DATA hbAW1WkCA/kj40rRh9ptEmS127gb7bZYIeDQgL4dVwjnwIJ96+b/IVah/Veyw8bw8lvv+L8l+O/e2hr9hf+cvyvLy6trq/fVO36/
# DATA vHz//t1vRUvf+gb+m2DsCOj+W/99/ufnXru6zeKp283l2m0iNW43969uZ93bzdtE2I0BPsBVuV27TVkq4PXrv/vqJ1/95etffvXn
# DATA r794/auv/vyrn371k9c/j17/Mnr9O/j126/+DN7Bm9df4q/Xn7/+LVS2CB5s4v+Ez//y+h+h8E9KatUi+PuX0MNvvvobKPL61/gJ
# DATA OoWi0OSvsDf4/1/B219/9TMYxk/h799CRW4Riv/2q7+Gj794/csGdE8irNvNq9sqhwoM4sGt7oDCQFDSi4cvX/Yf4I+oBxRW6+XL
# DATA 22kf/nn44CRNug8fnKbjhDIU5ekYP5L0jL7TF7y0+PosS88xLBL8VBI0fH2edccnrS5QlZ20Tg81pQmo50Dspa1l09bJeDysI3w/
# DATA w6qPuJX6LuYty8aX9eeDXta59DoQIqyejzrRyzhPe0cv4/WIl9x/Ob7spd677PTYeUOmcs31aHD4I9h++dQHpIWFD5M8rcNYrFcY
# DATA lKXOZJZ5W1wd6xB449+IzrJ8QlTvOD0cDF5FlK4GqNzjE+RJTgCRnAx63ZxQ4fgEKOME0GKUnyLhzMwEJlSOUNoN7wEtnUZpkqN6
# DATA YjxApNiIdseT7iXVHYy6WR/DLkkkWSDokKQ+xYCQNGo66g+fo2gbyZsjtB6Jfhz920mWjqOzQQ9IvweLXOgB2euM0h5OI+vwzGC4
# DATA R/i8mORwXvJFfN/Iz47xG9GUWPYUml+El+9dnPaoV7sl2qX8JE3HofZwCxqdPL9hNdLzqWq8FRhCv1DkR1gCCft09PDBIheEH3QT
# DATA 8Jpguj86IiQEwuo2qKDW4bL0oEka06tsaI/m24i+sNAufMDdkXPwYDHh24a9WvUPkbFwpmNUe9iMuyvQRj85AxolS+q95JCX5SnS
# DATA TfA6O07k8GEPJe09O0tHeI+pLatUDucnS3NdbneY4AWO5L1fHI+gLruD5/F8MHpFe0NFF2E8sqg4YSYNu1hVrc8DSc1klmKIuh6s
# DATA wZBp+eHeSQJbOESaWDu0wRGH30Cr9RvQ/PLDB0MolkZYF67HZXSSnMGPwRlKdzHz3wldAEzlSJ9xN4jMxJM6aERQF9hmMocDShxu
# DATA 2xiv2OVggluHlZWgSl1d6HX48EE3OzPjZtCQ+yfjcDIeexfG3YoPgchU3RymwPdivF1ZaK8VVA8O+l241U5782zaIowVzzmvdmDZ
# DATA 5QUv+srDZ6NomMHAJkNYJAAtRxNYlMGgh8u9gsv9KOl1JqSOPOoNiPpPE7bvjgjaR91Rco4QB+36cIVhv/ThiLqDlLeym44xWiFw
# DATA EEC7TvBuwcBR70uBayiQUWcAJHqGQnBe9ZucPz3fRTxwDx8cASmPJ3Ho3ig4XfZSoNSXuQRs1+SOgvag4EO1985QTCIyrLNBkP2P
# DATA ktPhOtLrZ0nnEgcU/Zd/iW40ft41NepFBEp4nwSXA9I33f4B2/8B28/C9nws3wDJv2Mc/2YofjaG//8Qgn/H+H0u9H4z7P6NIHc+
# DATA kfb0NUL/b+cGEcCfjTsB0g/yVGHQDYU2WZwHPRJ2V/jTnjLSNYmZ5uBIHCBh7nCsSKwiWyRL0MlGhHxJgOctBC0PkTQKBeckTuul
# DATA yYhC+Z8C0oaT1asRAoZJZKdpNzqcZL0xzgDhY85ThpG+yLEKUVtqfGoG2IPB6B1FD+Q+QcDkwKDfu2xEW2NFw3UwzzdifFw4QFsk
# DATA aTZqbUUKJF3EMCRepCHiptSJLMC7nucUxyjaTdNX0Z/CWUFjLaVcOEl7Q5JV4SCj5OgIdwkJkuQoHV/qGX46mIwMjpapAaWTR6NJ
# DATA X5Oah2jslI4a0aYkGsIlxXlMhkitIJ2pTiGe8ZxoGCiAKRQGSCQBeMixTNK7HGcdom5gbulojDr+Y5hCgvYXyrQN2+qcpJ1XJPIk
# DATA 1Q6JPZ3B/Nef/G+5zBWlvGQXlHcGQ2iH6ElrzxrRI9z/iPTyFPECJnaJM5e2sAYO9Qy7SE9hp45UoyRxhbueZACLemmN6EDMYoKE
# DATA Mq9t34wc7sSYNhvqQAm9IhE5BsjBGj58PDjvM5mHC8mWZR04MWix5g2NzykXyZEIh6HCLUcI10n5oJ8Mct5atCkcEYn/Kk2H5lIn
# DATA nQ7S/r0BXoZOh94fY0MZRkjEwEu0mIA9sJ28EW0PqNyEdg2KpyPaMlxLfaOw0SEO+CRVQAKOz1OENtmYpwBN29cFVmwCh5uOudxW
# DATA dSvTCyAWcYrn0JheiiNiXpyN3IIRa8OlHIN7oDVelwFMhO4lsEOjTPmVdhMcYiP6EIEP2x7glowQL6YAW+S4Qj/ov0Xf+EgJtf/G
# DATA bM58yGYuDmdOMvkbI/bfhNZ/B6S+SzQBvX/n6nBwAeTLZ5i+5pBOaR3eXGOlK6B4Br1e/TAFXjgbjJr5KTR9co3tXp0mIzgNzaV1
# DATA 1HAcj1D00zxLRpV6fZgM01F1vTPoQRV+BXRZdR3hV3P5/vBicblx727EX7Ct6jpamQPIP6+fj5Jh8xBO4Ks6zK17nVxxM1kfLkg2
# DATA XsfY/vUJmo4CrZfWB0dHMKFmY2UlPb1OmifYzhWV6WIuELokdTj8nVd9uLvNleHFNR+SWtYfTsY1tt+qYQ3ENVc0ROlLlWzw36tu
# DATA lgMavoTP1PVRL71YB2xx3K+TyV+zk2Ka6PUfwe3Mji7rcr/Ua+BPgWhBvNpcWxterA+ZOGjCSgDMjJYby/h3nXeguTy8iHJgabqR
# DATA tX6FhUbg0R+7Kw3zVa9lN0dJN5vk8pkfajAC3o/6OY/p3t2ldWClcmhnOKB81+veMjaRgZE1aegrplbHvLmyhglgqp+zxVThOEhT
# DATA +0Shoi13nnZbqHQ+uCpMlKZvN8BHTJpows4gVuleDYZJB7jBZuPuXTUb4QHhcBwBgZDXgR7MEANJVfclHQrvHR8R76U6MH7ZySlc
# DATA i0v37RVcbTwxzVVvU6kUnH3+rM4ybM01jwPgdWWfWCRC43ArD6rWS9zKwUG1cIaJk24uLy39j86huweHruR0YffV+e+xObp4chv3
# DATA rYOrDtuqmoQ3/pr1kscvw12Bq7kuQ6XffIjrRSAC166en4zgobl07TQHtPrBlRrc0rVeEGsVlt9fgrbhsGWfpU2inABNXRN/pO/3
# DATA 8Sjrrh8DGGqs0syca7K0xKUbNCVdpwwYUDP3sRX//tutrkGrR5h1Afb/auoeqdktN1buqlZ5AWFc6TFg8Su74ftLS7rKUtRYgyrX
# DATA J8u1k5XayWptKCC8Ph4MofrJMkM/7g75KySTuaEaZlpGfHc6rKw01rDr2r3G3bPz2t0GPlQBoi+tyUhlTarrPaCE4Eig2BUHwF8B
# DATA JFBmjVq9sbR6F6qunyYXMofle52TdRnU4QDu5ylMdJUGvTLf4JYZnNZWYWgrtPA4tOX3ZwwNxrJyF5fT7Zt6XuWeoZNIVh1aXPUb
# DATA dGvSzbjGBVZTu3e/c3KdnR7X8rNjfWooE9q6dV/lgCST8eCaeeIa2RkwRpergunilleW4CDXkGGqYM2oHt1DmK4HwkjKbmnmWfUR
# DATA F4nLAfePz9O0Tyd5uXHXO8rLS3c1WNHLFjq51w2SXvBa3ue1XOO1XCmupVq1lSU4EEE8BLyEOyGCC0Q94D988VYEtdLfaxKHzFwF
# DATA /56W9R4ljLlEqt9CEvjAJz2amlJZ967ldQOlQVcYPIEKHmUXaXf9szrJYGDe63gp68u4y+uYcQNWGhe6BERrsIDzpJYZBV1hK1jz
# DATA ugEkzUABxzrnDLyHe+dCPfhH26wh7J2c9vPm8tEogv+VwTe6oNR+1ADKAbqhuRKIVWSN2dK1u3ARuPRRdjwZpZqQNG87CUlDrXYa
# DATA 76+MzP3EWTXep26FlZh9Ft736i/zHW0Iwe8tzd0lc6ypdPhMS2UCSO4Q5r5M9qIC+C6Av7v2KKmjCIChWwqWDnfuao69HKVD4Aor
# DATA qzU457AplaUa7CyADTOi60YnGXWvLMxiYZ17hOr9U5hPRkfowj2DvphOjnK/0bCJ3H+9c5L1usVpUpEGis9rjdMJMKVXNoFAb6Ah
# DATA /G4fng94Dc/RLN+mBj4I3qkw+XwXgOwa/G8V/ncPSStvn+h8OhtAMjv3upQQ6hrBYCMeNOQ5N/vjE16Tykq/Gqm5lO3ESpFqu25o
# DATA ual/1gEMwLQQSOgikVADvIAa8SNqRayPP7BFlFVaSO7++3i36W1kI7/7S/ge5pON5zmjsJgCcRR4cW4JJbW5bqBsQVN7K1/nucSe
# DATA SJlTJBEVbmkw+XaDG7gSvIHUFhsDXjnAisk9G85HcuamnAGZGeGPtRBHad2FVQZH5yfkLInQqglMGUFRNaImTGV8qedImLDBZusO
# DATA jd24q6hmuX4rDFaULDJAaa/Zs1tax1J1UuBIL0aO2cuu5iA3PB4FIAfwTVknvbKXxOfH1HVU14PxboM3BdjLY4uI0kNfmgNNcN0o
# DATA QXYD+ME5DolzNiL9tIJPSNMVL4SNU1x4HS3NR6C5o4yGFmKWTzkg9/7xlSc3gAuSHPvSESZtp5xNvUErzESO3DPz/r0iU1lyNQ8T
# DATA j7ZVN6mAWz26wAfhTBBIkxEzhViluWzxWctrBCn5KpiF9oU33SQ/Sd0F3j/Jut20f+BcoFucHjDpj6/hul1pOdgFke42b4T8gelv
# DATA bcbVt5fy/bKL7Yndkv7lOYqhr1E3wrt8lJxmvcvmIyCxBoCXay/jJ9mhsn1/OugPXsa1U/hD7bp3HtayC3g46+XWMq3Mfx5FlnLl
# DATA SaV8oZVHr6s+I4e7pSssTNSs67ruYkca8YowPqbFVRvdh4jOOQhA/8i/b0Zp3T7rDNxF/CoFHLEGcSrzyScBYhtptceJlhyHxjDr
# DATA 9eqjwflsKlto6nE61LuuwOia+YRAXN//NQHQYxThUXv+LbimT2rjAET2kmEOVIn8sBlo+wQSYh6f1MZdZstoLZo4GgePznUYx9No
# DATA resGjCC9IkjOALy5vFhfJtxoyYgsooFphsFkPJyMySPBXyzmqchKv45qmwA1i+5pyXgwulJoN0TL8olWgE4f6Os/Pk27WVKxSLR7
# DATA ANaqV6VCB1vSsHoPYa9IFdzbIjRJETvRYWEvCmR3eZnsM0P8aSn/6V3KVeRc7aV0+UktdLlLsJp4oxsRY4pYLR+P3XmYhVxFZYPL
# DATA Ic65LAWCoZwtXzlSMsa7FpWiKj60eSn7eK545LMiY4vnYm2VzgWtYU1RuaXjIbEMi14Iq39gNsdhKFZYTCespose5p/93NMlIBLg
# DATA fwiQw1HS8x6SSjOvj9LupJN266cD2hZ+hNsR0olR43dqd5ps9AE/kiO8N0k/OzUiI4Pn10kpkgW+qGGwd466i3wNa0oZ5Qs8mD6m
# DATA 3RTywxL5sqbOggpEBQhveAj86SvNbfiFrq8djaGy2kILQfgTXZz2+qT7RLu85uLi+fl543y1MRgdL64sLS0tioEXGhB9OLjAgkvR
# DATA UnRvDf6f1L544iM2AIRnehkxIDPPI6q3vIK/jwAFkc3U6tJqd+0DNHx8+IDClZC10NPle9HyByerK2fvf7yydra8dAL/vv/x8r3P
# DATA nMpHK0f/L3vvuuTIcd37vko5ZJndGnQPCndMc4YxvIzELZLi5lBiOER9KKAKjdIAKLAK6J7WmBGUZFvbIcfRDp8TRxGOs7djR5zz
# DATA nbrQHpMiFbH9At2v4Cc5679WZlZW4dLoHnTPLSWSDRSqsvKeK1dm/n/1QV0eRhSLq6IZjZDRkyeyQxN5msxzCpKR2t/GN+absaji
# DATA 9k7wC++by3fXqc1P5qq96Hwr39Fj9gBEIa+Fn5gNeFaWdKteo9H06t2GV2tWR/VqzfM79b16te35jXoxY8JW2Iuqi7narnv1Tv1H
# DATA frs1qtX8vW7Tq/n0eLVzRH/fQdDNaq0YVDQY+JzHPF14wOn/VqPZrDaj/OKeKfr6wksRasc/atT8cXWv5jfwyr1ulyOjIuL5Uisu
# DATA +YZarerVGv6RX6uPfN/3mp0f1bqdn73bqHe9uk/Vp9YZ+dX2XqP9o1qrU0xep9+NgmAhyHaTcqU79GvV8V6rSv8c4WODLtcbnaHv
# DATA 0+Vmk/45oo+lmPdavWpjsCzmjZU1VW1fpIp6CycLHylP8C1Vww94fn9LNZYDPbW99a1Ws9Wr44LxPtEj/L8DY9AsXqnd+lbkR82o
# DATA faB8bLe+1ey22u3mgVgYt77VG/Q7fTzBbmf6OWzVa+GBLO/f+viV+9FhEnk/fJumCx8GQ7I9K3d5+1hGXeFeFqUxntVd2ka3o3va
# DATA x25LMpnyLv2WWJNereh07oghYG43o5Ga33w3ojYdBxUJurQ0d1B2hME4q7T3G0fHlbY4wjhgtVNuk+n9Wv8WzVSLIZYd5baZpwpm
# DATA 8QHtQy+OE4W7pgWrUkxOvgHjTz/GTqJHF1geyNcCxANYMovEaVW9mHHjwUVb3ohR9ApUVxqzhdRWFpJ2nnGnPHsLdYzNhqu0VD5d
# DATA bOs/RVP/+BXs3qNOIu7PeCf5hDdAen8JfTHv9h2zBXL/k3mUntznfQFJupPtWveam++maXCyP0iT8c7y5+6ORvSo9azay/f96ATS
# DATA i/oZtPB9bAek2PLc0rvhffzKLTuC42iM09mCHXs3mO5woIYVznLGD6KTijcIRiNU7l3vEQ78038lAJHJ5z1l9yUSIFK/TVm9Y0Xq
# DATA BjTKdg8MVZjpKvTS+WjkvebtSCz2h0GGl+3SJXWFgpIrt6wI3PJw9FO0CFhs/8D7FEeV+0OKlXrDRULE45/aqeZD9ZJshYp9pB/P
# DATA 5HH9w4HKi0L6sxXpr0i8UUsmh/HgRGOrTLZgi82StAxwuHsxksHJDibPu6YoIgjU/uXOx698Szy/H79CQUNsKBoB0bqPu9XpDLoR
# DATA 3w5KQQ6T45VhijF64TAn8/FOHO7mqXlvPu5F6Q6H+TFE/+jXfZ2bhUdDtYl0R+TcELjoWdCbPn4FX29Sc44nB/qYi5xxeSWP/TxF
# DATA 9H/4wTv7suPyB3w8hL5Dvc17HRp6P0Y4P6l4jxDwpygMeTSwG5I8/dYoYr2Mj18JOBuCfez+g2ZNOsI3HV+0JooxLvVHcf8BtSls
# DATA Pf0wHkfJfLazs4s2jkil0REZFXmkKBxw38l+VVkhUcH6hi4FzCbwcjufkgk2NO8MJkg4ygYPsBDeGEIfbx1RpN9RWisURjbvjWMq
# DATA yIoXHXGx3aHH+OM+VGPo75uyMWtHFTUHRNNxmgr9CPSOeHays0vhT3DDpyqqf4no/VgOXARH0U8okvv04FtBf7ijNn/yi0ZkNGeB
# DATA iNFx70IRwlfE58c/UW/8C+kB44z/7vAN9Eb93I9/okuJ8h+746HLuSvhy/UTVrLk+/dpVBnNwyhT0cg7RPqV3mc2yc3uaml7lLC1
# DATA 9Q1Ru8+NducEap3mmWLlxztfo4p5X5JDHYx8xnmjTw90VHfyx5eUDdcXvE8nZxtZpT9vkB2UALmLjGqa2u4cIRZgB9/2lt5+y/vx
# DATA /j5/DivL7jAFRRZwhmRyPLh7tRIjkS5kEXq3/BmTrWYf+nwa6s3khQ38Kt9fV9vel+9xP5BnJCze0p6p7ew4E0oGxVG0zy38U/m3
# DATA WL3NglexjicP8wrOt2S62Ognkynm4dVFKA9TGZpQUIgIZMEG+PiVZTv57Gjx7xIx/igR4GKQ4PP6IL/rnli+LauifPLGrqPKBMk1
# DATA ci37ZV20b6m4fAwJzzHZHlLbTBRW1ZwV+akjoGqP/kr23eSQJoMwfTw24z3zXrpYqmW6tayoVwfmQMXymoVqk9cbVXd0/sBcNSM0
# DATA f1M9udxAoz7NrdgY41v093J3L03zbdEyNdnPmcz6xBzya5KL3t/8DcUaFYL6r/EO/UneSY6j9A3KvB2TxdQQMhZf068sPE1WEhLO
# DATA 9RonJui+6oFnNQhkarHS0QW7arDoIsR76LrdaRZjk9dETsuu91d/5e3oqN2+rWOCSHFApgqYfLt9WyUF9Re3yLIevfkvOArS3Pjj
# DATA rqTlxg0pKGXsYOVQZz9/yc0dfNuVO/JgJT/QO1bzEUkpFUkZ4gYTiPy2q+4pDR8SFtdSjmGU8cBBJa9LdElj5HaEtmhVCiTHlOPa
# DATA Blx4iF6EOKpqSpmsA9kt1jjcqCyOnd3bd9hm/PiVe+ZQGJrJjR2YfR+/Ik2P0v8d+c5zQG7us+QettXt1HZvIMH/+/f7H9P/Jm/q
# DATA WXKSzNjV6gUzz6cZyw0JgA+bUQD00PL3kPF0s3hr/i6f3/Ufv7Ue1BHa4Ln+WBq3zADzA5nuYLY7mH3ewWx3IPuFPpDtFbYbq3PQ
# DATA z/RBbeM5458LJwBH1vHt+1NWy8PIFoeAjejT2/ntvK2Yz8k9W+e5n5dTjecJt9iOUo6/eJzvvEo9bbkZ6kUyRMOsVHRkvctawZML
# DATA wYi/FQ+qlxevpEn3E2SuvOlk0tfRUH7sOz9YWPtiM5XsgdLBf+sZ/sLp4AyY3uGivUXlDj0YKi/YQ+nsBJuKzfNT0Q3IhgGfiNU1
# DATA ylMbLmhayMeR5z0a1zx4dT3MQSjMTzgevEspTtJ97wfTaMLnfAd8dp8eUof5ubJ6FNYQtY7qpCfbEBjDhLvpzWAsUEATpRuwofKO
# DATA V/Jxax0BPk/M0SZrgYzsQ5xLMzI838cxZ1Q4nO5mooP3/ty4e70JLrP6kbwjpp/mU5gN2b4HW4p/zNikSgZw8lCLCWGpqWZD5nLC
# DATA EgCDeUpWxHxRDeHFPGxrQnDWm7PezrPeijXM6es4fZ2Lmm0rDcSr0t25jy1slhwEXgPfJoTzjALP09N4WzdcYnefZ8vVFSw5Xv9g
# DATA +wOLImpLjr7GhY1OSOxY9gnoTFZewJ3x7qviE9UNcMLrUSgkCc08Z7qr/Ap7xXj7x36TNxFpDWtKPm+IwsVxwPuNmmozSTTl3Uf7
# DATA 0rPf5DiWoipeCFMd8G2DiOqnTDzNBRPN+n5ri9EUzwj9rL00fOFVcbSqSOl7TKTMQ68m3OHnkavhzXf8W7XqqzcTZRWW72mqe5pr
# DATA 7vGr6ib6kN91U6KVJ0XZ6jo31SoYPZg3g5kteURmAz/BhkQ6pvfynmCVTrUaitFLV838kvQ88RG/aErj9Exy4KYEgfmTyi1Zp7VD
# DATA yS/pHWrmyh3L4AwwIbM6AFuaio1GafZzShWEX4xB+S4NhtQ/i9GovdZW+8cYG0245bOhaAbaOBU7ct+7G4Yen4lVZkGmh8/chvTe
# DATA wRqKUvXERMCMtHPIpoujl41SMcSpx8EbsQuD3jadj0b84xzLsDSox6k2/n+YRaK8IyI2ovsT92LKYpGY1yJSus5jwTbjKJBZAsOC
# DATA TWn0RJjXxBmmhZSkiXR+WuWK7fURhO+tXg5jYC9ivUzONO7gpUi4NF58q9keAJ3h7Azn8wznkoHkLGdnOa83h58BxcoP6W3cODLR
# DATA zAtC1Rpys7mk2YjBxei8sSLig2hGBTo5FGm7ovSiMMGSAcatRElA5kqJoodYNpJL/llsV5RSUFsWXx3WWX9OCznrxk4xrovLzIhU
# DATA woLBPiXoLQYSXRbDTgYDbP+CTB/3BZk3TI7pZ49KSIZLzut9TxkXkLSk2B1h3EU/kwy4Y+A8t+QrxWfFySkOerOAvZl3UwxXIzPS
# DATA mRTZSXuHnXJBn2wcCGkeU4+Vpwwj7x5PGWRDNKNOg1HG28Vg6SCJh2SLZbpXC6nwhtSbcSlxMuWUD4UwYVFxuBHJdDqUuZMYMdpf
# DATA lozJapwpdcEAVsEDTyuFrEnnm8EJ98TrE4oyFFclylin8b7yPw6iiJIVxgOW9qPZHQw1CBxiDyP2IVC1mskWDKYb0y9oiviFTUDv
# DATA Q8bweMwXRIBsWTFTFo5Bqoo6Icai681PpFKfzFCfsUl0TSI/iLIlCRSzolCFFwVVTVUnK5X9lsdQhUclG6EJ8qiTRsuMWBRpRduR
# DATA ILwFYYyzdzLQiZ2qxCSp9n4A/ZeQMpHsQrb9kHzYeXMyJviJB+Jx1S5lhpShdo/lnWJP6qm0ljodxOmYF0eWzW05UR9S3sh8HIze
# DATA KY6Rkplk1NapBRnrOV/8zsR/LfdTfnB1JFNATc+DTGxh7p28d7W4J/WuDHtgU1qBuI0PmRrPAzaPMTUgw5dKOpjPYnQbQco6XWOl
# DATA PMnqp9KhgAslbmOyEHBdTSlWpvb7k+RY6idaCTUR9JEQbNUJfjPh8GfYV4nclrZICZrClcBdI49tYpdYfgU0fiplbGmIRwaulfJ0
# DATA IaXipuwjG4kyTFJIRY4D0tiRESwoyBa6YZ4iTE7KarJmPmHLylp2vtjML6C1/+mnFcPQmR0Czpue2ASd/+/sl6d/PP3m9F9Pv1CM
# DATA nC9Ov6b/f372G+/0D2Da0A+f0b+/WUTn/E/64THd9Bj3M/zm67Nfn37h0ZffGYjOlxSoXOavAO384uzXFe/sb+k5ega3gZ7zDb3p
# DATA K8b4/D39IEydr04fn/1KR+bPdMsfBdQD2I5j6TwHsxl0yji+RB1Oj/7MCqLZh1FC4aRxX5tg+95bD6cjGZ9H3CNG0jdkw3hKvcXI
# DATA 8kbozhGriNMo9xnkc6FkNFLjE71Uy/yuhepgOVGFp1qKQ+sU5ze6B7lusM6ykrk6vE5edcytMOnyy+UHRqI3be5+R77ziL5lwg6P
# DATA a2pYT9TmVgymDrCzYbFtH7GDtfeIrU8UTiV3MbLxi9yDQyaLooJhOqTxhPOR5fazGWaqpd3KGqmJIMyhlHi2wNc5v/qtdmguaVlP
# DATA C7NzfjIcZ8dZAldhCWjgziUNgJfEuXltg/+VjP0bDf0XHfmvZ+CX6rmYDzmD59lrXVcB47FygFE8xVcvSe8iyINeN56qlURVeJRn
# DATA KV6qwDeRZE2m8qbiKQlsLx2ezIZjDkUOmHAGbYrgUUWWL0RSRzxivMwcK7VQSZ8ht2fKPyvH5AbBUYJRQbFmdIzxAoGb8HBKD2qL
# DATA QZ2rO8jtBSEWwfcDM+I4mMxst1g/mTrGjmPsOMbOVTJ2Nh1VNprmbGolX7PJfxmLfxsGv6PtONqOo+042o6j7TjajqPtONqOo+04
# DATA 2o6j7TjajqPtONqOo+042o6j7TjajqPtONqOo+042o6j7TjajqPtONqOo+042s6zRNupNYPL0nbag+ag/xzRdhbXnjdi7nDuqtzD
# DATA rkyP39VqFRTSmo1SrjdanSI3J4o6AwU2wuFGil6fA623WAakz6HWJBiWyvAbrSLEp04ZvgSN1G54jVrVA93Gb3ZHfqfq1Volak/L
# DATA bzY7vUVSTqPuNfzuj/xuY9joHNVqzbHf9r3qj/xqfdhoH9X9YhT6tbDR6y1JRLNTzRPh17omEfViALVuLWwuEnsoY71GuzZUuWjR
# DATA c8wDC/Sc1iXoOVxjLXoOVf4CPafZ6ASXoec0w2jg5/ScVq3lt0NDz+l3eoOwm9NzWq2m37l6eo6q43tcjc24UBeCjh5uCzctc1TV
# DATA eRypdI+OKx22pAprTM3+8GBj0k75bcrBbbu2xMRQd+FowXZwO3aIi7gdNdHsGGMVZXzAOzmGQZgc36p68G5UPV2SBUAPt+vFV2i3
# DATA uzHN27J+Usj10k2FtTIZzkswnIMV+wEWRytFSVrmqZV12zUhq65GDW26oeQ1o2Hid74rVfUZqyk+hdI+x0YsZJ5dmCoxevICK8RR
# DATA dhxlx1F2HGXHUXYcZcdRdhxlx1F2HGXHUXYcZeflouzEA7HfsO6BGv/I/iZ157YaMdXAJb9VuC7uHnxqYXoeSb4hM25zMDh1ZIK5
# DATA QU8Av/PxKzcW36Eq9YEeUNRLFm/Mb1EHNOgutnMPFCToPRzjkpbPpvzohE/n6LeWo7Tv/bU6A28dSuODZyhrqlAmCnv6BvrhtXUj
# DATA /paywtjMJqm8OLU/ezjL00y948evvGOdvDPJoO5SpUAmuqVzPu4IujuCvvER9OKBMHcW3Z1FXzw1uFJv81k4o16q44XWYovTsOeP
# DATA BWhRmbNcLUUJ38ZhFGQFdAufiIayJchFPNJk1J3JOWGtpMJb6UqnZTc9g85JYH1GjOUszqckQelVcKFORY+vx7KLiN+Sw6Bql9Wi
# DATA fr2yXVEF+ZNSg1fC4frHXM/cXOHttpD/jDgcE704s7J6tcq7MYhZGl0+FzXerTtM92k/taDQDosShzvRocl9LO66StBddakc1nfV
# DATA 59V3y/F6VrnjT6vv5D5Xycz2o9X3Sb/N6edPa0Tl5aCplnMXO9RWc8cQs0bLvVAT4D+3ZV3zX+Ct565OzwPkk87zcp6VxDbZrW96
# DATA AbGquealc86N//ztfzfpKEfcyv8pS5SizxkF01x/VS0l8p60dA6JBNhoCUsxTKAEz1rUUCuNqRYylCmYTqlOsr4udcxofTSJnczk
# DATA +D/0WGfQP9I6tKxVzYsfWmT2mCq3OiyufF52y8xPPuumkR+sNo4zXFZJMTmjj17SBfYFc02hey0QQFm19UJFlFfUixbQ3/2v1QWk
# DATA K70Uz9soBqrImS6gD48TaqMpdWyePuWXKROE+qT5BJ5IGpKm+97bNMrDyBknRyJIQWlgwQEIGxxG3K2igGT/sCqnSKtbqNJ68lIx
# DATA Kbi2cjHdwkWL5R//5+piUV2MlIrIgfaTlCYjpuVM1ERYLvM0p8earqyrLJ+8aYCGFYrpIAq+A+rDk2NVREU7kqXZ2SwujIPW5XgG
# DATA I/rJS8lO0bUVVN4vX7iH+83qktJ9vBTVR0E69nh3V97FHeOawHHCI2hhU8kcUsHw+gX6ukiG+0koUhoRq8dCZzqaAIIjJaBmA72I
# DATA yR3xTDQ5sDvW/pmpE09ePnkyrq10nmQE+r//sPkI9AYG2SiVIcHSAR+zXU3xSh8oS5ubVDBi9fLAG89p/BkFKfbJTSGfjIz2fiTG
# DATA oxpgyEQCw0CaDUr8yUuiEN3noan806ZN5X4ymHk9VPsApZN3axjje5RFY2jZQDOmTyMPJgesCB2EPw2wP0fV+AyFlbI9Ho/jEc4b
# DATA IKegUkGW+ifzWNRqoILIwipSgFoRegtNpZCMSxVQ0QgUj6ZtBJorkt133ku071FrCvHsQ/kEk1SojBigE+7EdcEq4Z8nYQe9HOIu
# DATA Ds7tXGmXcKU5z9lL4jm7KK/7mVB3LOy/XI/tljk3DaQzbNUki/KQnVoryd3PqArkcySadp42tL3v8Soo3outZOss76UyoquI3osp
# DATA V7cZdWxxvmAStO/5RhKbnUkV8R2JGuRxYhwXuZNJUfuUQ3gMKLeR+csLuuLNM8GXQhaQgsHOCElCVtbCXlJrlD4318lcT/NSWuDv
# DATA wdM1OQQ0UADjottjpMAtZUENvlGaWbeMnCjM6lxU1FYS9dhnQhbrTEoL8x5Y3x424kJv86hQH2Qzm2QWb1eFJuokb/CiXahzCzm8
# DATA /zIZj3YQznx05uPG5qNd19w6rFuHfUKrcaWRejXrsO8K99NWis6Jh0+HVHEdlHDe+4PqxccGC8uc6qccr61uXVgvzBeS8uWxVWuL
# DATA 9vKGvVqz6v6So720lLDqqYL7t+DTXvVE2U1ZdrOueq7sPSt7BVeunBZKgTdZIaaoTmEccn2QhabXXtXylapY1L3gl8ueU2GJq3Om
# DATA mnReXgTHIXPN37MtKk9z76lTt20qcZnpV29AEedNBeOTQgN6fhHiWGiaMQl1ip4+U5ZqMrLfEk31eCIzTjbBIz2TMhBJaj9mtWrO
# DATA pgKFRs/guTd1R4K+xR6ePSUQwhMAY7Krpz6CJS59j6w7huJa5n3lFBMId2OBRj1xM1ksuHzeuNxpnNe1fG8hOJ66j6KSLpXw+Qzw
# DATA F8dKtuCALIWUjAtswP+uIH7fnH5N//7p9DEwfI89fGMs3zdg/X19+gWgfIt0wP91+mcm/v1e3f349EuPQYG/O/3q7P84/ePp52e/
# DATA oGe/UoF+qRCCX579Etfot2/OPvPoC4iEAgIEmRBxkOcALGRu4J8dDPB5sPoLffcgOibbgSfR0wDStQoCgF59PIB8RA+SXRoDQh0f
# DATA VmXvKqxu0mPmgeqee7rT0n32fMqvQRPi8MjI6Iv/JJrNp2sRgHchdeGF8wybXag9OwBgwd7XvcR18/8Wi+Xq6H9sYTFhJb+1UN/K
# DATA PPOb0Uk0jSOyNvT9b6kLHlSGgNBO0i1jAFk9jJHQ8xmP/+qMFjUxRwLctAi3jwKkvgaL4NTmJ/EAnQ7D4BnijO1yafIQGjoRn10W
# DATA Ux4GK2ohdW79GbYwzFn6X37M1OYTvfdEVzRxqZIlzowbTOPiw8kCFnDzarna1lloeE8LDrh5Yhwk0FkI27MQNBrwUobBy+EEvDaj
# DATA 4Apsgo1MggtbBNdrEEgVLWeHMQOemVZ1FUhAK9Vq+WtFFDVcjN0XD068wzQI54GC/mX56gNkDItrbIwaLC5KnMimTyzNH7HrCWtt
# DATA LIuYTaM+Rn5jim0EBzTjOitzU4Iz2UdHGTgAvowr4F4y2EPl5H6W6tC+BxVbHJ8NxHKAj44JeCoOiq2G5E9TupTxWqoqbWW+ySIh
# DATA R5ZvNNm3770XASAnF2TT3v05zJA0mR8OvfmEimkmZ9j5xZnDCDqMoMMIXiFGcONhaKNJ0kUN6mudI1xmirDNGYKjCjqqoKMKOqqg
# DATA owo6qqCjCjqqoKMKOqqgowo6qqCjCjqqoKMKOqqgowo6qqCjCjqqoKMKOqqgowo6qqCjCjqqoKMKOqrgM0MVjNpROPAvSRX0O7Wo
# DATA ETxHVMHyCvRGTMEiPK/bsOB57aqB57WL+Rr2o0Y4WELfa9Vs+l4jp++1uivzNi+YsV/teDW/7fl+w+u0vW5zz2/WPL/hU3nR1Vrb
# DATA 63RKWL52q9vpdZZh+QpR5n2Yi/GlF1rIQ79t4tssAiarUavfXvJ8rVbLn69Xc2RiZ7Pn6/JKlV/NWp5fmz3faFrxr1v5veH7mx0L
# DATA +dioty/6fr9ll7efx7++Yfzt+iJly483Nnu81baTb8MeN8x+eUQlv9W96PuLuVfd4PUXgURKI9GQSOnLLEhkvx2Ebb8IiTSPGEhk
# DATA rVrvNbsFSGSt12i3mjkksl8Nq+HAQCIb/Van08ghkQM/bHUGVw6JnKA/38senOTrHHKE8ijawrpDzXJ1aJuL7QfzWm0RFkwfeRnN
# DATA ZjCtX7KHRWW4Hcw+tIuK9r0Vin2ntnI2I1YWIqoXPRQXUUpQ36Oy5NGmubbfsqiGnp0t6jZP72op5o2etWKffMHRWgI6rtmhoPYj
# DATA SDr2MvphHN2C6OVqSqPJh0opuWtMv3IhV9aWFztTTJGJPbhQTcR8qm2SUxyCo0A6CqSjQDoKpKNAOgqko0A6CqSjQDoKpKNAOgrk
# DATA S0aBXIQ4joPD2zD1qFfHGTNK8k35qk+yIBMUcvFdW1EAreoGPU114R42RO74uzc+fuU/frvPxMO7S3UG+JkdCT+YymEDvJGC2TXh
# DATA 1BDO//5cwnkDLZ6PL42DyXwQsE6/nOqS84jUnKdy9A2HqgJBLkQP6UY+/EnmQEZDW4GQWDij407fu9P355y+X3KEy53Fd2fxn+Qs
# DATA /ko9zis9oy+KiAkfRM6Pe8uw8prR53z68jHXodUpox1kVE0UBnxAVlmdO+PxrqIk6hY6YQdILuingzDdmrlgFC3bzaKS5DieyLpX
# DATA ValO8iqQ0pvEfhv+dTVP0QzKdlW5aLytQEzU7Wsm9rXmssjXrKh3ChGv7jdXR92M93bU9UVVj3bC6DCNaKp+TgqssEwK7GsmBa2l
# DATA 2V+3c9+vrcn8lQqdupWgRksH8byqc1ojLvMQ6c5UWrM+4l4w+zBvmi1vMvSqGEfWeyd5I7dvYJF9kc+X4o6ymXQl8qTgGU2VyMPg
# DATA m3sngnIs9Etad4D1K3Ro1I+QEagMRMz3pmI2hDHmfvwYNIRZUuM4OJGBR4qTx/5MC2sczgMacWZRxNLgStjiE+rgyPzC0XolCrIk
# DATA RhsIeL54B9ZLo6KzrJ1lfY5lXTKanFXtrOqCVb2arfQsKV8VW0Fg8suIX/0Q/D2jdoRV7FzriPVk4BKvGP0mQRdH4zibsgSN96Gh
# DATA q7Dxzro5ETxzxxGTWSue3rOBUSmaYhk/pUdQf8oWdZHguCB2Ze6jof9erKSPhkka/ywxkjdKwT/wsmAAvk6UklHEEkymVLJpkiuk
# DATA s0QRi0apWUQUZCc88g6TcQRRHp5NkN1XEU6GSPHgXhqtaWCNYUJwZ5VRbmEVQamBY6vCiilDwbYJIx33dyDMU+wAsXVCqfaAB5l3
# DATA iMYmmk8CNmyoXu17r8eTBHWIntGYXW0ITKKHMzYkeUkFGaT60SSD20r1sMoEkiow5pdZoNBlxsTStH3fBiOMkkOdwg9wolnKTapV
# DATA Yc4WY0EW6h9xLlZkuAsi4TU6UWr53ONnD6Sm5eOG3hQp8q8Z678OINXOidCKpAw9ZVyYx2fBgNtG9s6ydYl6X+S8pFVEJ0oyCyP1
# DATA dMxdmKRRVMFEfraXlwc7AHPjNJgZwbB8PKK8oApLaZQJp9JToizDLtcR9pdwVcYRmtSu0CcZfOMcm4cUwIyMwzgEDXbfezPhJonh
# DATA zyiTQQROGYwDdH6pFZsFAhJbVufqvpq49AJV2HNLQd+spxgmqbkig8SJXNAi+2pyVnyefyxOvfTiVGFaVeUpkOrP8r6MiQVSc3Oo
# DATA vZLZf6L3+YY8MQpOFDq8aKpk1BNu9501HkIZ1xPGY+l/tvsGbFO8854eO5CmaTTpx6PtvoX3cL+lW5BeQrN70O2+rykAi0Fk9gxR
# DATA w2NbckKtrfium/PRlTFoX7z5lSPRuqnV5pLBbiL1wk+kLoqefbYkhM2e3qtgmJYze+sE0yVKx+fzS0cFgoJoALMbsqgrvAav+2zp
# DATA KD+PEqIb4ha8wsZybYTncquSL2aysb8wOc6nvRXvEArN+ZwGszAvwAQYW63MPLRPU2BbP1ZUWzFpymalWWnuTSh5ErT9LQK6hVpL
# DATA 1stRdL6QNOrkOJhqkMNGZbCkRN9PI/aoF9SwsyjLNKvwJTLdcsJVL3gQpQW81b+cfgHq1Nlnp18rBtUfGXP1+dl/Y1zVv3tnfwfM
# DATA 1OnvFuFW/wxaFQOpwLH67OwfvdPfn/369M+nX5z9igJ9XPFO/41u+RN9/wW+e6ffmNBAzVoNvPoFuFb0X8e0eh5ItlSH8TycDVTB
# DATA WAI7YNyzDBFkbcU8EoRwTUCuXHVOmJOJS2PCTgvulwYKzBPKpQR9nOyvFUYe9RwZe7rWIqxexwZatJMInYUDWNkGqHQC102vKpfI
# DATA 1bGrIAkdlt67FFnFVczc+CZXuKuBVdGoN1WbflFLsUk4CYMT3kdI9eNB5IBV55Xb1jlVr6MZcAlMoxRnRVmxHsfxBgzYltOXHtnu
# DATA 0DJRqyDWFjy93g+x/MM0CuMI3mgwCqhPjVJ4u/LlFNUvxhMyh+aSw954nkl/JmbYiVC9+/E0WqBYbVJTV9szpab3tOhVmyTCcauc
# DATA FXBpK0Bjqi4x+L8UnqdrGvi3Pu5vNOxvOupf16AvlbGYejPIP63GchX0qWISvWE0msI6IcMDCGYTuTzB6fBkNhxjRVaSfkuGWgi9
# DATA 44TLjD8ALY1skdVR6jBBM3qbDPzgiMbJTGdHKtJmvPUAa7LpnLUUKf7j2HCB1rOn1O4IeJgiLFFHfKZLBmKO/YrBXFwclkHAeCIe
# DATA CzIxIfbQ/sOCecH7APUmCoUC4pewgAJQU/QP9lTAztNr5PNZAnmoPpO6HGDKAaYcYOrqAFPnjSMbzWU2N3Wv0Wq/jNG+HZvdkaQc
# DATA ScqRpBxJypGkHEnKkaQcScqRpBxJypGkHEnKkaQcScqRpBxJypGkHEnKkaQcScqRpBxJypGkHEnKkaQcScqRpBxJ6pkhSbXqjVat
# DATA fUmS1GAwaIb954gkVVx53ogjZWdKreXV251P9hp7fqfj+c3GXq1ao7++59M/ja5HX4s51I86vXpzkQfVbXs1UJ/qnl/tjPf8Gv3T
# DATA UF9LICjK5Gq/twwE5XclYEp/TAO3Rh/VLfRSvdmyil5xkARKVARXRY0gakYLEW20fa/WoWQ3Pb9eG9c7e36jqb4txDPq9QZL41lf
# DATA rF/VptdoNoetqv+u36h5jY4/bGq9OIuB1WzUomVBLtbYVoNiWvd/1G2Mq16tuUf/+J1xjV5DxdLB571ah74s/lB6aafTqtf6a156
# DATA EdSRtBCNOpLGZqGOetW2XwuLqKMB/89GHdHXYFAtoI4Gfjjo+TnqqN2jrAoM6igM+s1uM0cddRrNqt+8ctQR7zDZY9PDZgmpyBZn
# DATA nz5GQk/+S83cngzYTCOZGayD/PDIlb95A/pQwQnXMk44WXpbBBRZYS865HmElW1z9FD0YFM4kbY0auUAvAuM12seWz94r4QQWSVo
# DATA +wI9MaFXp6dUuG2UalsVbTF/VifHkYQcSciRhBxJyJGEHEnIkYQcSciRhBxJyJGEHEnopScJDRRHiI9eUYIrx7cH35FLw5NQVg8B
# DATA +yHjppKZn7KALUq+emKunkTUI6vLmj50D+EyQWhwg3LokPlAH1EM5eJxEUSkfr9PwfPP2dKf355AFAnGAr2P7ztZet+HySwYyfk+
# DATA vuvdYDbcZ7/BzuDG8Y3sxom62eYM5SdZ3FFpd1S6eFTaOtfkDky7A9OrpfyegYPUOJM6yKt5cOIF+L0gbz5j5ROpzygBIxGOelPB
# DATA z5DNG42S4/VnfcfxQz5+PE2TZKDPH0Nn3DRUGn+xFWWeRtkTaJvTiJieICkzyhKkTx+3vOtl8yk61ShULTrODPmILBsFNkppwEPt
# DATA hJzeKJ5hESehyUPGStgCMumn83HvANow8YTPY2fmUPUAzt4jPr/7EVy4BQWTlDXdRUE76ycJP9GfTyGzLeea1ylovwEbIj2RfXQe
# DATA D1F50gYQWYcKIILkUp1EUZjp7kzSm81SMZepHIfJKOSzrog5JZbmwCwHjlIZ4LdDivLohIXCTbaZshNlHZZJx6l0rYrOacBEbpTM
# DATA kHS61EuOR14wyhI+GLxWIvweVW9uOnJsm94apVbhsWBzj61Nzi59c5zpU/THqIvonlncZ4TzvejH9z1WVM978j42pESQR49HfDIX
# DATA Z+Ozfe8NVmvmuutpQA2qA0UeoSK1QYiNQByWOYaoVP2D2Xmi7pxzHOdjGkiMriC2o+L8u4ejNHgZNZ1gzK+jgY5LR0nC9+czKVxs
# DATA q5mq08CiE2/Oe+PKKFYULlSLn0GmnuE4mVE0fyDhiX+FQyTTcGRnSWzOcwfp+HK65q+LEDWyjhr/hYXN0Qi3rWz+ATIfhTeAc1p6
# DATA pysQNM/ZliJ4hKJgQ9TL9QiuQNPcKDOyUTNRbQ/dLMa8K5A4v8vdvrGVlJrE9SmBvzgHufNA3IzCzSiKM4pylXLTCjet2Hj6sHL6
# DATA cXXTivvIihyHI9HRU4pnXhvwOhCl4kijy+z58nYOz8Ni6gdMh2Uu5HSO6mWApNXVWM/ctUe3fE9/8Xa+fV5k7QdNhAsXc4pnZ1mc
# DATA G00ryt1NCarsb2RCyWi2QSzV7TniVX0vmFQLUbMzs14kpK6Jmjg96eeCV3KDSOoHTSzNhdyu3W+fF9HauoiuBKHK/BWjldXSnl8a
# DATA qjS1OCuKHRnN0nvUt1Dr8A7NXLzitTrf9ky99cZkUmdevaHuOYZ/mmb5NJGODlN0lPyURmZh+i3cLL6RuyP+qnTYZGZqIKcxq9XG
# DATA fdPV4Y3RQ1kz0VMGLINhUo+wSlJmLM9l9WVawDYTVpk8LasQmPTn0xKJnTp9EGkVtA0opy+O7e3oO872Xu/Nd4b2C2loX5Sy85SF
# DATA UHkHcL5BdtEAtSE0LDoYaA+20QuVJKym0DxV+dTnQlaQ/7tlplFJ6HXbRKMFqdylPKMNxGutfdS5hC2+RRCuTIJBxRB02MqaZ0Nl
# DATA YJXqKXaKS8mq3eKvDut37qUx1m2wS5G9iHQJjPr4IWwY9v7LeS6mHcZFc4cmkJgFRsuWXZSqpgiZij6pOsjAW7iUyVM0YGhaanlU
# DATA jdViomvH+z7WrBBzsu9KMRfZXbOoQrHj9QvTJkRjVC/LKAYpjpNhe7a1WsTyqbz0hLOIayKMZr9hbPlY2yRh+i/H9z5WgtQCnZ4+
# DATA R0Vx1KC4sMdLJiOz6kdxVPBJrEBgEWx1ROlly/L1pdHutMhBZLj1weGx2EH/dPrF6Ven35z9/PQxoD+nfzz7NUN9QA/6OTN8PqPf
# DATA QBf6zSI8aOHh06/Pfg3c0M9P/3z22ennp7+nH3/FDKIvKx59+uL0yz164jGC9vieb+geeoeghVbChCh0vOVzegPd6IBCz75F/UPo
# DATA l/E6MfcmihZ2UpEFQVySjlbtTk2jQ/CXtZyzLPyr+moG95RFmwuUaeqN1zKE3hgGompgSYY7jpBlXasu4bpJQsvK5epoQrwhYJhM
# DATA zY0fqQvLmUKDOO+m78Uz4wneMk1IoMZsL4ivyCL6vOwcoU1KbOs0obuegNcBAt+bzXuRKXnx4MfYQzv2ZCf4vvduQjVgYkCIVIhH
# DATA 0HuHpAfWCFjDA2ZZoDa7BPg8kk0fKdyHY+YxirOOjS+BNUIktgwPWl8lVxsxS9rZ00IHrU+Cgwa5kf4iI73mBF1ygH85XGfXNbhf
# DATA ydi+0dB+sZH96gd2qZaLOZBvdL2+1nIVoKA8ZRDRogCyxTjP4HHDZk29+U/Hd27SzoecGCeiCxAEmJh/Z74JlsCYtqK2hPJbxsGE
# DATA UpeZdEtqTfCCGRpPqQubzDbCBsG+muEgP/KBQhqk1Nvlg34sy/16YQvBsJgcQ4wMASiNJKsMEvlEgMoVa6RPgPlJBoIuxouoInr3
# DATA Z0h2zB6PeOBRq3ogNJRj6iiwZxBtkDcYpMg77RB19CBHD3L0oCukB202pmwINT/f5r1m4/0ytvuTmu6OHeTYQY4d5NhBjh3k2EGO
# DATA HeTYQY4d5NhBjh3k2EGOHeTYQY4d5NhBjh3k2EGOHeTYQY4d5NhBjh3k2EGOHeTYQY4d5NhBzww7KKoOqoPaJdlBfqfeb1afI3bQ
# DATA 4rrzRvygQ5Nk3kVYZM2EzSgcVFexZu682o9T2P8C9qlJQhTYp80iDSxv4PuKMFS4vVVtnHO7xfmhsD26x6Pf9vwu/a3Sv93m9+j6
# DATA yO9W6VrLq/kNutbaa3f3ao3asNF9twZgUbszbDfGfr2512gOW8ti0qitirgCGN08LFSgRs1HZOgN4z3fqx4JomdNNkaDXre1HJFU
# DATA XaieFOdmrTpsNarvItWNbvOoUR03qo29RpU+lRFE3aDday0LunZxGpDUeU0DkuZj0YAoGf12vUgD8tv1TqNr04Bq1UanGRZoQLVO
# DATA s94KchpQbxA2wtDQgJr1dq8T5TSgwaA/6PSvmgakjJLljg+d1pKtpUYibFzbW2+FeHQzhp383jL4x0yUlk2KtBsNc91KY7/B/J8a
# DATA 838W16NaxUhp48bqpsV24YRQjgfp3iGmxuBZVMPosGKtvdufvVp3+rDyrXq12W712O23W1kdUveCQekoZ9Oof1EqkbZ54T1cMKms
# DATA FbnVi+NqKVx8wnsZ/TCOboVB+mA1eyjP4Yod9dU2R8nslTrEtpMjCTmSkCMJOZKQIwk5kpAjCTmSkCMJOZKQIwk5ktBLSxJSpJ8P
# DATA rWNd+Xnu4jmuMoZHuEFyypvySNOFsCMAzQh0nv54n2E+byRjFkBfOOTNx9uwlCRqVQEOqiQTdXxNC9IWD4pJG5WJnD5p4c44uzPO
# DATA haM27qizO+p8yaPOK8UHr+YI9L2YtS74LC27IMunZ/VR6GdNbuM69LjV4IKqQ/VVSYYjlTv98XkSzeZZ02HlV4xIc2epNnfTFmn2
# DATA /WpRprm5RuqaBz9Iuqjeiy+8KrasUVGWe3KBa/3Qqwl3praEdIuXez6gvk/hhbievHozUSKBS55ocXbR2OLd9GZp9IC1Is99rMkv
# DATA ss2AMQwalk8uPntTUrOBUPVbun6iynqoss+vSvW7UZDNIRqNg7X9IM0Fqu/PRJKPepIkmckNcqwZsj7BIcSe4Y86pjFr3/shD26j
# DATA 6IgqDTpAdKpjFTY3YwWnSVIjPJQmZE7uex/wAoCYRvIA6y0qYT8aTk5Q0FQQ8awgXw2YVuHYvpwj9dI5znjjyHWAA/bQcDTjOfQD
# DATA yWKjOsuFn9HsbJ5NI9E/ZMXsYDIfYCBOMZeSAMFFCuPBAFfmPdZTjzFOU2CM3Vlm6ykRAkrCbGOB6xflnK+Tt3bmq2W+Onv1pbBX
# DATA L6pt/ZQle3hdO1+AXa9tfZdGIzYa2YBkOzbLpSiYo5Ct0bi+brGf50Lv4ipkrRfr9dalrZdqOl1W3jpf9NfmmFgUyvaJQBblOpeL
# DATA WrP5c0ImjQA1eSmIXrfvvS66QTRLErGaKJjARPkIIkIi95JhcGPMqBAcubrBjCKrK9bCz2TDJWTzkFH3gN6giSEXqzg/0EIsRtXJ
# DATA uMNfLsWTQs44Y8gZQ6U+1XnznDev2HeutKKesqAh84ABLk5GI9HZLwO7VTsJslzCb9+7J5xutpKWyfMVtPymadKPQtC4RYouST+Z
# DATA R+LLeRI+993YQJ0NjXdGI6hmAo7jmaCmZST1WMuFYzDnRn4YzA9p1PyAhmFNC6xwAGKWyHKPwjugwwgGAzjF2FWSuzzNOP32BOP9
# DATA TPi1c0WLiMa9KIQIWhj1UhqRhYrMQyiLAGKH0lqUtYz+uTyj4IADqgrwg7KmoDINMm1dQDkO/ppUnKVKfJpsgHAU9YJ033sH9hOi
# DATA SZWUMjdQILAwQAcDJEJvJMJrQxbGWyZkyB8zS7VQXLIZqNefUMHHA+i8jSOs/cX9tTDyIatac+WZzODBYS+ySfJHgHIkg4F3SEOW
# DATA TqLsk/RGc8rUfgDFRq7HwKsHx8GJOKZ0PFUZZtqtw9nH4wAFo2JO+ZKJAjf8S6zCfaBkDSGFmfLJAlVxTXUugDVmqD/MG/F6FIFo
# DATA pddZpZpHGhlbIBPOfPBcqBqCU6ZlkRmTUOJjkElY/ike0c8V7YfiBOSwnX6Qpies3HiX8ixgv50KSAjzAo/THJ+jgCX58kx6L4o5
# DATA VeInVuqXcMkdJkloudvlrQk1NBoNB9LWikV4Odg32vIJqz5SH/PahWHfiNu2Yd9il8fSwJV+YTwBOD4KrwD6/TqY90ouVG0duQLG
# DATA 90clFdIreRPDvd9B05A+hsY12ZaTCTFnu2/jU0AfGUoiVoimQZx6D+AtDhZTd5VE8RdjqmPBZZIgDQ/hW7fxMv9DYWS+YagL6DBf
# DATA eKePT/9w9tnZrxd5Mv9C9/3x9HeCfOG7mPwCKsw3p3+ij58zS+ZxxTN8mcenX51+DlzNY/y0p5967NHXz3VQdBu98Bdnv1RwGYrH
# DATA 2d95zJj5Hdg0oNA4qMxzgGmcaGbXgi9uGiVAQKuReyYC02/o+Zr4PQ552zYGOQUNY+1elhfOyV1m4KPo6aFwPgnXUmbu8i35mx1j
# DATA pjCbMz3DdVNmFsvl6hgznEBz13chJE55PRqU7wuh/WyAXtjvO0uDk22iZagNZGRjpyJgTjMNWGM8E0NBOLjM+qLaOlXGdEJhTGY8
# DATA n9gTU4fMVzwFkfv4ocf1wvuAtweI2/YQ+yOXbSoX9iE02rXSN8psEs1Y0xx7P2gMzxYYMutq3mo7ZaENPS1+zLroO3qMG9KfaEjX
# DATA OJlLjeQvh0/2+kbxKxjENxrDNxzCr3oEl7pYTna+bfIptpirQMqUE5qTZYzmRB5zys0oUIgZuN9YbgCergkVaSartUiG4WfIsAr0
# DATA xFGcMi4GhaWxMpTyIMNFHBk3RGGshsrAegGIzAmsLfbtSoiHss0M0wT62BuJx+0wjfg8gGS73uqmfOs0+kMKgb+fyyM5wPjPWZJa
# DATA NkMRMxKlDhbjYDEOFnOFsJhzxozNkPDnWrbXap5filP9RMa548M4Pozjwzg+jOPDOD6M48M4Pozjwzg+jOPDOD6M48M4Pozjwzg+
# DATA jOPDOD6M48M4Pozjwzg+jOPDOD6M48M4Pozjwzg+zDPDh2m1G71G9ZJ8mMFgUAsHzxEfprzmvBEdxs6WetXzm+1hvV0/qnUb36Pv
# DATA xRzptdvtRriYnc2a53eqlKHto1qj9T36XnyO6manp7gsXJZSVlJwJ8JhqRV0JRrdYhk3GqWI9KJuuxxgrVa/bIBhtVtrtxYC7NS2
# DATA G8N6w99uDBtSdbYXQ7tQqCy3kIdWoVwwwBWlbBXKVmJoF8pWYmgXylZiaBdKXQLfXku5YIDnt5StxNAulK3E0C6UrcSwUCjNxnZb
# DATA ygUDPL+lbCWGhULZRgwLhbKNGDZrVlvuFkvZr5dCVBdSlfvlwb8V1Usorla3ETSWwtKWQceazboFHZPwU4MEs4wUHeoCP63WfLIA
# DATA mp2uFUCze/EACknotp4wCZsFcBGemdhommcm5p7FMwsarUY9KvLMBvw/m2dGX7vRoMAzizph0Atznlm712o1W4ZnFrb6ftDJeWad
# DATA fiOoXTnPTHk91IYGMxMSZzzZkuygsLwXepHazM86vFK5ZNG/GHKZY/bdiIzYOKhITEp7UZYEZzsieZGnGLpa9z0/Gmb6snyXnL6d
# DATA JseH0WZLRc1NFqetUMurzrbPRNeRotu5JhP5hdVDv24tEqt7/VrRC6OrK++xHAZhcswLMVhxq3q6zll522WHBc+KzWxuxX46PYlV
# DATA uV1dzUCz8/Qcj4aVW6U6yZPlmgOhORCaA6E5EJoDoTkQmgOhORCaA6E5EJoDoTkQ2ssNQnukandMBXdboczwmRJd4SSpizi6h4yQ
# DATA 20V18zZ1bFRndlC14tvVg/hVfuIgvnFj9xEu8m0H8WDnOJ6QdUV22Ml0lrwGI/4DQDHGP+Jwdh/pFjS9zaA1BoHsNGrdRrfVrnVb
# DATA NzlKu9/hPyoKvduwAX9Is/d6TTpef/cgTB7JO8qv2OntHnzKspk7vR9Xf3LnNr1r90Ak33Dh2xz0Df/g04iMdaUFZ8VF+G8c4I6K
# DATA xy7drdRHp3Ma9VS396lED5Xjtvr5p0k82eHeinIQfDg0hhvqR1mg3dkJKj0qjuBGr0LWY27Jq9SO4tsrrdlRjIIZxXaFvC3Ng8qN
# DATA 3iRpo5kjXss2vswIcIAc7X6KrQSTcGcU7x5IHhV/51VpmrirrviOX90t3oAhWMXnDdy7L6enqbJ9qpF15uinU1ZxyiqLyirmMLBT
# DATA V3HqKhdUV1kpin0FqisfQI5LK4CMEtb7YM0uI7zydIW8roNOx6YAXRVPkJcMODHnYOnUQ3mPpL4X1GQXiHS+BaRr2Tg6fw2Mjs0X
# DATA VH18wPwDRVGC0al7chidfmiBEdeSoB6KibSaJcdj0lvwrp93py9qwGSBnncjK+x+eByNqBM9595aVd07IRO4dO/m6Dqu3mjlXKLP
# DATA LbXu+5rRIONRRtZDFBqpPSOvQ0aWkcUR870stcMkuc1ke1jExsuSeQqW70BwKtDfFqsRGg45n068FmQkTpSMDyXxxFOH7o1YDL1z
# DATA QS1mWL9j6/9QmupUMCNdKGyR2blpbdRVJTDaiDb3IiiG5GOJMzqd0blodObWhbM6ndWZnWtPPjWtv/uMGuJIsosbyFFUf2N0GiDZ
# DATA OO6niSWBN2cLVenfBdS6Jn3QLRa178ygmLcoNRhqSAlLyfWT8ThK+7EeA9lyTSOstGDjwsbaf5yy6Z374q3qncBnFmGXCYZRA1AS
# DATA 9i8NpthLsUR/S513WzRRlXsWNZE/KeNU2Rz6x9wAMlf44DPQaRGHo+Inyw0iOKgjv9T2ND5fcILU56Llad1hOkr7qQXDDk5TtAWw
# DATA puS+eJ0dqI3zN9mAW3VXPwFxg5rLEd/8Rv519TNciXD3+/iwxrqUgVlbeOJCtU0SDBJrzLtCCWPPhzRodbQzRzpQp2TYHeyxltUd
# DATA lZd2XpRwQLwbxrRzcQZzbUrnfHvtPz/7P1smFeVoq5xVppiSqqQKks5OxBgj+45HJjB5tCXJgxBN+/Zgd4U8X/TuhiGk8ehpYQH1
# DATA 0dio9vNEkfnJYK/gQTb/ZHRkIoomJsM2pbfse68Hk5wKOAllUio/3QMRBi+pV2mQNZQgfezkUvlaqj2XyN7G6uwt1EXJZdjLYsNT
# DATA QmbBSOfzXebJ0CAxrUiu6Yk151qATQCzeBzZULbpaM6zZ5pfzsWiZwKS8uh7d+Mx8mpA1lo2BKyKTW9c8mv4Ok0yNtH3vbcAX8Rr
# DATA wjjrzzMUEIcki5LbyGXT3i6av6vzVrVcnavo8anrneGDztM3sbcn8Or/8ds6WEkh5QkWDybgmR8DH0R1a055R2UhU/zM86lAu3Ba
# DATA yPpLP6I5yL73PnXZNPW+KxVbqi8IUMxJ4vOKHtwbB97r9h04QyjuEp5Jq01e+9736GvEFZnKf2sV+dJZvL6HKGTzRzTQ0iSDgkh1
# DATA HhtzdkANf0/0nHIWGLQDqX6hMk0lD2XFJ5O+QO5GJYWfJlDocUwI5cH3oF2Kk4EZ65YGJpBgoqFUFXkZ/YYlFIkbZ/phLJKn4JEd
# DATA xQm1EPVwID3Ps9F5tC7UefzXecwrn3rw1oUgGUz1l8Y4VGyugGwDacNIpkPIdi8bxVPKT24c3LcAdMbTmx7rm2qPIBRUMaqLEit3
# DATA Td5hNJOi4yzEQmKWjCNcOJxH3HHg6XgiExXql2Zb6T6ufvB7g8clMJFiU7VNtyhujdlxIh2yZC1640wQmiKUHMUpjW7HCEXXY5ax
# DATA jY3CL03X0fRT1fLJFmRVZ7yTuiacVqTe+khN7ihsPDFOsJDLcwf0FIydkO4FNms5c4vmiiwb2+aKuSKZdYcamFrg1ULCMn6LqWiZ
# DATA r9TchtzwpFD2z2M9vQgul3y25VwuzuWyhKDgvCwvvpdlpQPlmSIqFI4KLI6UI5u14I3iGY44sxIKIzFBsVSjCbtg8gf5PAln7NNG
# DATA MDzLWuXn8ZOsgx+yKslHX+68Sh1pub3po++F43UdOctnncuXC8FIusMyTmLhSLq0336C2iFvO5n0dVSUymPud7PF7Lk8loA5rOf4
# DATA C6dHrcQMa3fus01uqgggyMHkxKxafS85Bg75RNWd1zy+MId3iqyq17w36P6IOlMYQzBCckv4NUzC4jFXuEl2LLOHGTbaebx0zPr7
# DATA sSK6ajYVYLQB2Wbg40K7jAyvXvIwWuBFFWvLvZiBmeyApOyY92eUSCn2l2HJyeZcJszjtimX/8xYyn8FcvLsNx6IlKe/P/3y9PNF
# DATA wmXpzj/nwEvcX/HOfk7XHtN/vzn90jv71dkvTr/AE7j3MW7/ShCYdPs3p78/+wfAKz368Bnd9ie51XEsnwOTzcvY75+qA4imr0ei
# DATA eXLOPcG+J7vlvWwuE1bZkM/cWnmQGzDGDB5M2CMwkWnUABNWbnDwk2FpYcib59dQLF8XGTBBZTiEZdGEk0Z/3QDLUpFcHb0SdsCR
# DATA 1d2riscUdPmp/ISqguaJD1SVRBWcwCO2VaAl75YYBhn7a4D+UY5yZcE4qOWmJbh1vOVd2KWHYqsYdnSFu80QDjYNCDJ9lhjab8aD
# DATA QdzHhnxsW5YdN5FmgOtbJxGFQT+n4u5fIFpuVAdXmyXF1vW0uJYbJcIBLt1Y/wRjvcZbXnyIf0k8NNc0vG97dN9ocL/w2H5tQ7tU
# DATA y0I25JjLp9ZurgJyWUgjpuRBMWHYVioJQLDj6UyGwmmKrgecumHQi3nhb5bpUqMnDg+xwPKAqkEm83iqx2qZG9NtGZnNCDyKqUJi
# DATA +UsIfxkU/9JNEZfIRsMExLSB4j+irh5n2LAGotCOOva87XUBK6lq0l7BWJAFIY4lS6QgFOQhMgArn9neNEr32KqjEpiPuZc9sMwE
# DATA 3Igo75HBttJscAxMx8B0DMwrYWBuPMBsNJO5gD18fab9ZSz7LRn2Do7p4JgOjungmA6O6eCYDo7p4JgOjungmA6O6eCYDo7p4JgO
# DATA jungmA6O6eCYDo7p4JgOjungmA6O6eCYDo7p4JgOjungmM8MHLPWqkfM3LokHLMbdZ8jOGZh5XkjMqaFevObOWWxXqSKtUsZXpff
# DATA JceLyLJGp1VtL8lwYDdbtWGjMd5rNDy/MxTUmQUeK9PIcvBYfQH6VrXiWkKqLcS12loV116v1WkGC3Gt1Siunda24tq14trurI2r
# DATA gtktjWuj1+Ffi3Gt+1WvRvV3O3Gtd7ZSB9r9TivwF+LaqG6zDjTaW6kDYTsIW4v1tdHdZh1otrZSB9qtTq/dW4hrs/PkdcAKjkJr
# DATA tNrDVr165Le+1ynhcalD7TcvB7GjvlRD7KRbtiB2jRZ1G50NIHbhoFmE2DWiRljNIXbNdqvZbhqIXb/Tj3r9HGJX7zY77dqVQ+yw
# DATA h2pPVjf06Nqw+HUWra7DNmd+/8W4dGWnaz1fam2J05VD5nMqm/lSW+t8qXpOmAe6uCqjfM16moGJgppydZsLdDj41LDgJP+p8++G
# DATA CxdPqE55HSHDSWVoFOl0qtYso+xdjhgnKwZqEXdpERjXXtlfsBI2Z5XAGtt0scY4vpzjyzm+nOPLOb6c48s5vpzjyzm+nOPLOb6c
# DATA 48s5vpzhy7F6o0LJsc+TEv0d+cqH9+jrTf2rgObY2Pz4lbfU8b/QnITEYT0mmTGTrR/Fox0Onclqop+Z7X9M/5vcneE2CVb9oABs
# DATA 6hvDYXS4IU24PT7BsyTwm+VQOBjr0YxHBIM7czqI7qD96oP27oD9C3zA/qLqh8/MwfvcsbVeDZFF3vg064RGKLIsILA8pO/rtBCf
# DATA 7jn95+zE6nnqO7mj8iq0EUsqBFsWRizrOJyjinhXAXpYDIFyldpQxoEZaaH35/DG8A4G73AOKFgvYjZYYKl+Q/eAJusYp717dDWB
# DATA yL1WPxSZKEY0KHUFqreJFnCWE+Vc1ZV4A7Kfz5TjHHpPKgSeRp2LHk5lWqFUpsuqh2uVlEpNDt5rG37Bqtv3Exrphuq0umx+1eLb
# DATA 7wWQWzQy/Wl0HKQ4UK8ERY+DkRzND1QF9UZICHMS2IEeB6kIU0jki+ehZwGLpP5gPkOSzCHoskb5Yhx1Lhtqw0RKgik23EFgE4aH
# DATA L2EUGCn1IGOVBiWsFTCehk+rx7M10Xsb1JsLRA69iImYJaShKxIEMDMq/CBVAINklCkeo6HpcDDpA+8YvRDHF6ft10TyfXnNkkx8
# DATA iU6s26E4G9nZyGUbuVSrnCyVk6W6jHW80hq/Mrmq78bcBthICJTQk1awoRx7YGlXXbMm4nXAgcW5wxAcWI9phJyDSuV6PLB+zPRO
# DATA 5kJOuG1Uz0ME16tiyG5ACRavE5C9xsHEl9glhJefE2H9vImwuZBHuLk8whJHFWW/HOXq6jiza8yuuqhaO/zim+KZ2j03m4sUZv09
# DATA j3NtaZybl42ydpjRDe8u97mdE+M8ABNp65KV10ujbcVaVR8d6WYhziuByK/P41FojWjoLZ5fLvK7MgzL6B5M+egNL2DruZQBJ3Pv
# DATA xadElDqUJH9ID0Xgcd31BtExu7TZcTwzHlXoYC0Rkj9MWajOjP+T6Egzr4wE2A9Vv667QgDXAmDRsX+WDfJ976/JUgh53kM9o9XN
# DATA ktkfYmeQqK5pRqa4sqUj5cZCKZI3s+mBKR1NM4QDF89WTdleYCPcHl2dEe6M8AVH9YK15exwZ4evM6ufHdlYNdjpZsA+MLQFWwUe
# DATA uB0aq0wrPMqHOiVRWslVTHmoMQKn0OvE3iqMOgh8KpKdGF6VExFtbiBAlGweC2ZGDoOs0ly9ND05fyk3bEjg91Ap9CyCRufQ8ZM3
# DATA 4SdP2IeKJ8SbuvpOcSfLFAKf1pCTtVvRcv6BYvvsE5Tz3LggRvLD1QhJna8Ckbxb8NzDpU1VBlDaNEIxlYCpaXRIOWb8s+yHFSQW
# DATA /WeAubNSn6UamfGNdNtkFtOEWVYgeK68770RpOkJRFmTSdE9ngbMbGSrdZaeKC8xi7JiD2QqEYPPPJloP7maPNiNNF/90U0kX10y
# DATA eyBllF+TfJO/WkWRLvBmX26YARinZibyRKzQvCpfsJjfWl3MulGoYjZO/3xJRvZacI+hC/oddLEwcgJhsqZksetVjsxC1osWgChF
# DATA 89KLBJ6NkuPRiUhCp6xsjM4VY5FZ6qEy5w186CCHpld8oiJcn7RrK8RCL3PBcvxgDcw47690ixX0iJJITiOwWGnImYRKDJxLUpPA
# DATA 8nYaxgHNAsdsoA6i2QmNp3PkcaycV4FuyQo3ZibzvOhCo2vOR8vMEg4Nvg8xI2WfG3vAsEAYC3DtidvmuoReW7leug++v3EfTBV2
# DATA RrcIXTfyJszezh6cLPS/mm0jxQqrRoSm2cgYRuM4m7L2tfcO95gBewlGQXoIWWkoM04yzak/TlLpX6WtSOc6CIBIhltgK+1yeaqe
# DATA /W71ext3q2rsIvsK8vpIaqAGqjDQBGvTJGXdG91loo1FsUPhbeHTcRDHQVEqvnV8OIGrRyai2sKEY4WlwWF0ptOU9eqp15Vi5nhs
# DATA o+1tkLDnomt980Jdq5Z1h2ESpsExGgjvThjFA2uhWjnX9B3KeogCbAulzIHsvdg7tj2DGQ0XljZ5+vPZvscuP7OWrbYH9NNgijzn
# DATA I6F6P4X2kD1Zua5N4aVK9HoB3k/koX3xfYo5ArMf0Wgf97MiAvOLs89OPz/90+njs1/R55+DZwls5Z/oz8/BsTz7TF9chsX85vQr
# DATA +v8Xp1+e/T3jLs/+lqGYfxIkJgf9e7ryK+ZnfsnkTO/sl2d/B4Dm2S+Zjklhn3519o8UxC/p72/onRQCbvo5/fBH+pnu+QO95PHp
# DATA 12e/dpjM58JRim1p6K5Ut6hqHged3RJfFA9hPZoeVPj7ITa7w4vaB7JOgVqOAvZcBWaKYHyugQcvXH+47731cDqC+UKdKQoLsVYG
# DATA Ta4OvJaf+caIxi9piYifI2jaPlTdZ1w3QXOhUK6OocmV0tyFrYW8pq48gAvETaracWJuv89fPYh2zUcQCdsmQDPOJCrwHsrOxghn
# DATA fgPwg06imaNnblJ2V0DO5FVSXi2Px5jqIjRTAVT3NIv4iFof9ZiP9XvvRkE2V8u3lGNzQKGYroCSo77S+J4z5gx5s3gUKZd1yv5y
# DATA MpDC+WgRp7lZlVxt6ZTb2tMiam6WDofUdHbBVdgFmrV5GXPgpVhOvTZTYPuWwEaGwIXsgOszA6RelnLBxm0+a23qKjicpeRzouGm
# DATA ZnahiUwZvqkVivPMOYITY6R4nPZBGs4tXno2yn85gE+/DZkhvhyNr8weRLM+/N6b4jjzEd+yGChyWT78j8VOCLEvD6pRUKih+HoS
# DATA Ip+sKdgDvPBNcUvCPeXHRzvPMt5H5vEeLrFFtFORRiUkV/xRitbJGyXYbRWYZTSH3nToTYfevBL05kZjzUZToIsYzdc5BbjMDGBb
# DATA EwCH3nToTYfedOhNh9506E2H3nToTYfedOhNh9506E2H3nToTYfedOhNh9506E2H3nToTYfedOhNh9506E2H3nToTYfedOjNZwa9
# DATA WW82wlbtsujN1qA96DxH6M3S4vNG8E0KPaZh0euLzFiX87J/InTDbp6xtYboUPEvtVaRX9gNB1FnMZfBBKzVh36t+clex2v6Xs33
# DATA /GqX/9Sbe52GR/bxXre+19xrd/f8WsurdffaNc9v05d6sTBanU6zG8k7inGuNWp5nOl9eZxbtTzKQha1Kkaz3ooWUZbtruc328NO
# DATA Z7TnVyl67U+6FNlWfa9GP7Q6e77f2WvvNZt7fqNbqi1+1I/8EvOw1woGQW0Z87CxLCkNiX1fxbhtQRgbVlKKdTzs9Pu9JURGv+PV
# DATA a51POq29BqWk3vWqlKaO59eqn+xRWdQblELfK6EVg6jdaC2NW7PTzuNGAVvZ3LVqRrVIi/Qb/UbrEqRGbnqa1Cit2CI1Ulz63U1I
# DATA jYUrIDXWok4UWqTGoBW2w5zU2A5rYWCRGv1mv1O/clIj9rbvrTNpaMC1fFxiG5uHtCVjQwmRyoFfmhE3Ot/28C+ZGh6bG3kQery1
# DATA lhjlVzYnN/T616z4LZ1LcIgQFLZ9/lXczXMQbZoeWAZ4wRWqyv1iYEVxf+VQyFKeNClP6N+6/FtYrWo0DTay3fz2UsKjGIuUZpnz
# DATA 5cul1gLWcoTjSlTjuZVB25PLa4FkSs0uvo3DKRUNz2JLkyHHgXQcSMeBdBxIx4F0HEjHgXQcSMeBdBxIx4F0HEjHgRwEaNy3/T3h
# DATA KcqmY8AfyZrRyMf7+rz7caT8mYx73FG4SFzAExIUquo9bPTb8RnJ2B8L+7EQiJqrWqHIlfODERFZiCer4/Ry1N6bxlE/0qcRcUYO
# DATA /sMeyqPIgcxP3rjT4e50+Manw8tHtNxBcXdQfL3u9jNzgPx+/FCaUIXGp8kJlvxjOWRpg2/MkUdLNBVNZiSHOvHsg8VTzzgKyj2v
# DATA Ojs9QChyMjMLRtEF5bONqqW4HrmJ083JGK5R+5y3U87eRDmbd5RwVcSH1fehv8RtP6K/azSzaVCcCf7wffn4POhlmzy4oEjk66tF
# DATA IlVuikDk6zjFOcCxbgxKuR4kNst4ZLlTVcF5cJzOB5eVpjwnEPAcxQM5wZzMmAKR8dAEFxSC8QYR1aMRDCKasCRy8JhTookoT6Kd
# DATA edkseWPDLHlLa4LSmKwz5PVgBF0B1url6FJj4gvmzLUs4bCsqDeAd5meRk7xAgnP68Cco6EZf6gJkvUXy8l8BDbZRsbodnDBfPnR
# DATA 6nyRFqVqyjxkyySvI5MgpTmpN6E5rYd+hsGgkG7FggRkBnL4DywarlLRRAhlECTImCNCn6fo749OtHHzFOvIf9mwjryfzFnD4qfz
# DATA wzw/tNr0VKtPJ+MBNo0A00CdwBTTKzQIphkpjFFIpgYNZn3KuNEwmePE2773ISYErK3ASgli1x2Ogp8ZoY4nVJ/Nu8IL5s/7a7Rn
# DATA dacqOUTza2+qL0kOvZ8mR6gDlGaa3RxGBh3Lm+So0gTzPlQ47k68+QTJ1T0MBIIZiAos0wjK+5CK5sXlp9huPtiw3XClVsotFrKW
# DATA FRnGyRzq43MoVYzEeEj5jCz8/aBihaHuWaC0HEtXymaZLcQbSHWh/rqcH9crZfuyKDTkZrabhLtJ+MaTcDfjfsFn3Csn08+0ZBvv
# DATA YzE7WoTKyrta7rxKDbpcwnr/JZJrttV1ZCultTlULgQj/laWP1vYFykVpp9g55C87GTS1zFRJ43v/GBhW6We5C+qy1mP8RdOTWF8
# DATA HxXIXoBPMOuFFcdCqp40gdf+hfwhPjrNw80zqlv3PMk5bShs65ktVVJ9C4aD2UC1xlD7z9/+kzYj+JXDmkjZiQXpzaLRiKcuCjQh
# DATA il7fhf2ZeYdiZQUzpkWEUGGjGctwPu7p4gq8dHgyG46VNcsGK88NDmP5WSw/FiPDtBmiZpbml8d7HiHSpaSRK5RbaZQLzhk1QL0C
# DATA LZihHF1xHKQLmrrFAmWokTEcmVj1EspqWcE4q81ZbRtbbQv1za2duLWTS1hsK43DqxTfZUDTQOnos5g78poX4gsavE9fEH6dIYBz
# DATA fp691rKwdCK2ItuWYeFaYU1Dlvrp8j3qf/nsN1/xdvrj80D3+lHTnZkLZoVBDoiUkfF+EXRvI+Or+/7q9Re1ocCOrFzaJLbmYRPd
# DATA /IqJb3eb0VUbL+j3d7X+7yyZFarEzrfPi7YJxEQ7v3JONleteNfXRluZr2bBTHal8iqXVPmIt3iYppBZiCjUsDuvyplgFWe1Pdl2
# DATA quWXpP+JBVU1pbFbGbE3JYgnhD+JbcUorbwLsFWpf5iZ/SVofMa4fVecqUapmZHDx8N4FOX9RAy12hn26qQseWtWOqg1R7l4M8sD
# DATA qxVOmLiycUW2vpGpW6oCeqeVFypUn+kNtHYwulSr76FUzcd0P7YH5+GwnnQ/mEA7eEoJiHFOMUinvNDLnmOgyOGuPB5GYsDnHRdS
# DATA BqFp7td4YYuMjn1PweyQQiM0nc2n1PUo/eCiuPRNzveXxXq2IFw8R+c5hM3h+i0zuL44+4XwrkDO+ub0DwrNBTgXWFyfLxK4/oVu
# DATA ewxAl6C1Tv/NCoc+MWDrK7pHQ7a+Pvv16b8bStfp53TjY37X78/+gQldOOngnf7u9IvTf6NKE4wccOu5sP/ZuLe2bgAVmCbAu47R
# DATA T3B9M3YMk1ozyJNTl8TqfdQzTkT1+5h1w2XpQstuVxQ39BCNfRj00E/JbF3UsLnOQOy8F2GGsA629RHdZSLkUFsF0z/vGa6btlUq
# DATA latjbQnt2/CfeEu29Vbrzp9mVNz6xmIF2yZiKxCwlYYrqAVCSYzDa51TXFtHa70fkNGJnynWzWqlWq3yqEEZQF3Uvvc+DSDG6mGC
# DATA BU+6hsEUa8F65/8s6B0gkoKjzgyEAsUVPaSBAGcLygytc6vbajOl2HieFjzr3AQ4bpYb3rc9vGtm1sVH9ZfDmXeNI/q2B/SNxvON
# DATA h/NrGc2lNhaSbvvonqU2dBWMrELCGfGTKWa7nUyadAeZWjQLsWjWg2UeYCdxhRIaA+lDjSamJIxisKQmoX7tIIhH8Ff2A7CKmC1U
# DATA TBZG28Bk9JgGOL3AHE+yKZIEFym1kE1pWXnIrBmQyfso/kxp4q3oQ6pzcK/QRT5TzqfN2b8xwQofz2HnTIiaBuKATUJGZolZkJmz
# DATA 4pSi+ydkvD2EpywOA3WSPRLDMMqwDzHOhljHDODV6At3BemKB9iA2B9G48Djne9M4ZryWORQWg6l5VBaV4jSOncM2miqs6H5fH2z
# DATA gMtMArYwB3DoLIfOcugsh85y6CyHznLoLIfOcugsh85y6CyHznLoLIfOcugsh85y6CyHznLoLIfOcugsh85y6CyHznLoLIfOcugs
# DATA h856ZtBZtUaj2rw0OqsxaA/azxE6q7DqvBE4izOW49LljBM0U9UvyFG0/E4xw+vd7uocr9a7jUWQU7fGSCoVlAWXalc73W5vGVyq
# DATA LoH045QlqNTLWhZbqs7x5ANznSJNKuzW261lzzebGz3f7XVbvWXPdxqbPN+Jeu3AL2fCuNaoe7Vaa48qdrPL1bs2rvvNPb/me3xt
# DATA T67t+X59z2+099ptz+/4dtC8YbSE5+qEnbC7LAcZF1aq+e2u16j7VOHxaq867FZLwZm8WwiuewkEFjchjcCS1mghsOqtVq9duwwC
# DATA qxp1o8BCYNUooHaOwKqF1bCRI7BqnZbf6l49AotmQnv0+0aT9lqNxsqi36ow0siIp0P0+ICc4T5pG04ZnzrBOoBUu1aWBeLNR49K
# DATA LhNrDFi4OyiZ/cYU7yhTPH9Aj9rleeCyOZ/2EnbYSyirg/ATLllsaxUTUVwIkDmiZ098lCGXP2GGwSUrdmUM11KPj66oRQ/DKmiX
# DATA cR6r6MBvbE2/+Ps5+VR8UQvJYb9iYevJ6ufNOH3Oa1ZM4VZjvUwF3wjHta7yrp7Wlyrzsjo5H507ueQoOM6X43w5zpfjfDnOl+N8
# DATA Oc6X43w5zpfjfDnOl+N8vWScL9QFdUI+Cg9s6tcMS6acEUjdbanryTztR6ggXKsO4gEbmaph3mlWYfDMhoAVvJWmCeL4prK80LzI
# DATA 5KE+Oj2UPtm89nbJmLbmBGzCVjC5qAj9C9sauRx2hTlmAqHv1FV8/ArbNWKee/fyo/9kR59kS/qC3YNP2UZ/lMcGWy0H8YSyQ1HN
# DATA WEZU6T4cWcG/gc6HmitcqhWcYxwHcoaKSx1v7WGPMs0v+UVW/JSgLnU1OAn1XmLsU+8YZxaV9Um/cQSpWnPu49TOnv6Rfnltnd3B
# DATA ZUjlk6frdp6y3UeFyIgYlYmDFmlUb8JpQMRDrP6DT40x//ErJvB9xI3eai7coL4KFDa6Rq09PwZ5U27UucFnj8rpVck1lW1te+F0
# DATA Liu8zYKhyRxeTwGxvSx5tiM2dH+WjmjK9zd/I1+xGZC+7v7VX8l3epTy9ONX3mLEwyu7j1ZY3sropq4wm91ni31HCtVJ3Ds1hUup
# DATA KTgVhRdbReGi6vZPVV3BOGAlRSLWZym5zwJUtzvvaRluTikfZJ1D2jJenZA39dn9XHlAYomH1j14n9stb/PCotDKpwrZIcaC1fby
# DATA p24iplqHkI/GrhS4NyQmJYVArXq9uP0zJzbxHByu5v9umZxQFMXYNjehrDWylJpwUZWsj9JYmW7xhFmNZLvBmDEqWUYHhJXLMljA
# DATA xxAyG89Fw+GE/dQVI6AvlVFVHq4oGCUzUbS3ND2gcRCwRZ8MZgxXSiN2ozOBSwG32ND3eGGQ9cYn0UP28SpljXM5Ri/GOXkTgjPu
# DATA nHG3kXFXUspxmllOM+sCVt1K0/GqtLTeFsEmqthqLq+cCFzNc7LPdSs2XofIvfIs6MzVSX9V78TQiuP6Nqimi6cMl9lZVhBYp4wc
# DATA jdijzQAErBXz6PZXcDEdoE+TT7fUBWVRy7eK/GG3uLrtx36lVqn/hAZFHaMVkvLKqUbveps/cZUtIojNLaZvzR9aIADXGNlwnHi8
# DATA lWQNeLghhje4h6U7F0DBK8XkjQ8rrzrPr448pjwiL6VspGUSZ3MjcDaVVlNREmb/JTgK7ksXq9TMQFjRblA0E5UPrPd2PClqoYlq
# DATA VgBIi+2SU/pYNGBC9EwQSaMT5Qg1zR0KVyLARU8f43QXD52sOWW5//Y9U1wYEclGnvdnc0VhGsVjXOSNRhCsgkgc0y6g3ZXpqJQq
# DATA Qj4Vsc3kfGohpVV0nWJuqVf4jetQzflMzTlfdv7FsFDzYcaZqM5E3chEtW0RZ6A6A3Wt4fm0xV7fKzSSCQa6WTzOoUz3ZZmUBVAr
# DATA FgVQUue9pWUQIbCI4zucXfQ7mkqY8FgNXU5WCw0OKV7YcjY5MXqQGyq4cnRNbIQERbUAgo5iEFBjpXYfsb4lOo8l3jp14niJpSp7
# DATA FFDB+JOiAylLRv+YG1fmCktPADkfcTgqdrLnxnRLq1lFZuMDQ3/kc9GutO4wXaL91ILJiJ0DGB3RMcp98ToLEy1S+5JX32Xp2ArG
# DATA 0XxdE3KUxYec9jf50xrbtcgGl50EtsGiaOarzMZCGWN3tTTWSwDYdW5cEMD+6NPVBHbJWCGwYxIXaUa6ctqfaBL7h9gySilP55ls
# DATA 9+IaOGHtVCWkizkQyJx6BTrGJowAGyi83pwMXaWYGvf3vTdjFlids9CuN44znj3KXhdsV2KKKG8CkWvcWnllWEgMQBDR61LFZ3ti
# DATA tH2pBl0wg//z779ancOF2igZzZKuaSTCv/Crxv14ZpD3/EtOX2LtWzKqRUs1mepT9zOqbSnr+OLw6iwW+/zugA+F09xg3IsP5+A+
# DATA KtdvRXd3gooS+mNAxj5L+MYh/yYT9m3k6CXr6jjbrK6+F4ylKkDKOs86qS2Y4kDBVvb5iqotdKpH0QxILNndZJ72GOOB3otBHydA
# DATA ywqtawJlQDQIsv4oOtR7UlGoDQqmgTz96vdfL1T5hHXGsadUfDKP5pHOv3cwg8OkjSbQuRLzcRCzM4cvqOPmEQDQb0qD5DUJqThZ
# DATA XlE5YGT9AEcLOD8pAydwIXFAM3kKmN4IFEUaKlFoW6l6pmu/YEa+vabuqUFC8rC8QunN0uCIxs1jSoPOzA/UUYKhEsgOpFqmZMNE
# DATA YaaMAurlJjMGxyEs2CUyP6GGPDE9g+pVx9RrZDyXjCHxaC2r5nC5Wazk3COa/2oVbth+TzVfP9w0Xz9kAp+1XIXzjXnrVsthaXSI
# DATA /eByQIQSkqkhA6NNrl5vJM8z9lXklmE0GHAO2/1A0MtYvJpmaOzekXtUdUZvKlZfjM72p7KbtZShRSNB9izaRoK5ItlDdq3eXagn
# DATA duxsUbv+qCPqDxPoZwXwl1JJ6oJ4KRbebIwelURkE/T++fSbs789/eL030+/PvsNuHdnPwcSj/77zenvzn4taLzfn35+9tnpY/w9
# DATA /fr08dlvFol6djjMyvs50/jw7Ddnv8JTp1/SRebtCXqP/v7Jo1u+OPt7eu7PZ78ATg8x6KXR8Z5B73159kv6+xv8zMS9Pzm03vPg
# DATA rZGaZvPmZcr5IEYrnci2YBAbfmh8M6J8D3OMLIYQSj9sKcj6Bn5/oLeTpFE/niqbK5ujP+LWPk5YrH8tSe8NiZfVgBxMz/bSIHeu
# DATA m6O3WCZXh9KTqpOvJH4gVUkkT8o3oyey1hyj4yuhZfOO6qk6dEFZIRNGvG0cTeaOp7dBmW0dqSdmPffl3PXAyyx+sx4ZELp3E3ue
# DATA u7EP826JqmtyrKA+mnDOOmuC/uVDByi0eDzGGR3AhKiwDYz4QvVvDQa43KieFmLv/EQ4xp4b559wnNdIvUsN7y/JAsy1DO1XMLJv
# DATA NLBfZFy/nmFdqmQ5Byy03tNsOldB0isnVS+KiEs1YLnJ0oiY2UMi4r8wJlYEiiWLs7LGKkoWR9EsmfIzUcYH2hMyl2bDJMw2weR9
# DATA gDyUZaxyjCh74SHgjbuU/HGMDSYJWWXYsyUDfV5d6J1BNk8BBgtYYJQymf35Fe22TyO0H07RCZeM6OAICRCOFSbV6cqQBSPBffXh
# DATA rNY8M0fDczQ8R8O7QhreJqPHRnOVTY3da7XbL2O2b8Nqd1Q8R8VzVDxHxXNUPEfFc1Q8R8VzVDxHxXNUPEfFc1Q8R8VzVDxHxXNU
# DATA PEfFc1Q8R8VzVDxHxXNUPEfFc1Q8R8VzVDxHxXtmqHjNVq1Xb1+WijcYdKPwOaLilVeeNwLjFahv9a5FjatX64b65rfbRW7coN/p
# DATA qryhCMY0spog6nkQjUY1L5ua0Pbk8FStWwiv3aj16/2Fgqo1fa9Wqw1r7eqR32h8stfyuv6eX2963Rr9qe518GWvW1tScotovmaN
# DATA QmtWh43WJ+221/b3GlQP/MY51DkT2AImrtZemgEdi9xHkbcqZ72ZZ0C98N5vNfq1Vr26EOV6q+r5Tf+TPUprg2rLXtsfNxsU90/2
# DATA al195dIJ8GuXAN1xq9CgO2lgFuiu3ajXG40NQHfhoFUE3QVht9/IQXftVrPbahrQXdjuV3sW6K7t1/1G+xpAd2hSe+vtDY+HF+vW
# DATA Mh/uuxH1AnFQkYBLi3kLqLg6L5jly2XFoJXdsuCk0jm04Igs+fvtsJZ54C80qHrse6uy4aSeUUtgS5Nu3KqLkTRmeREhp8IWdN3y
# DATA rQJlot0iZm1pzpiBT69+VdfR4DaoBVdliji0m0O7ObSbQ7s5tJtDuzm0m0O7ObSbQ7s5tJtDu71kaDcb5ibJ5gNbtwWkFuKU2yu7
# DATA 35FvvOTIWC6FPEtmwUjuR4u68W4wG+7zTHKHL+7eoBzAcVR6j3KiTaExM5/y7TuFd9yUb/Rjxr3ILLmH7Xg7vh3KR3KYzAqk/M5S
# DATA MPzswpEzTRCTKaA50uEOUbtD1MsOUZeO+bjj1O449UWPU68Rvr2qY9bSCtgOhl67rLKaY9ZPUcjjOqgLoTqerWoGvno7h7tK0lY3
# DATA uwk7MHIBePVU3jep7zmzoMhiGMcsQNdU2Ab2/cuiE7ZY8FrUvr9a+FbGU0gxm2ENxYBD1ZL/50RXP2/iay6YCPutZRHuWBGubR5f
# DATA HlRBaeN4cDTpyjmRVA/lur3qe4EDsRBD34phx45gMXoreQ9vqBYVGdGg5xf38AZbeTyMMcALkxN9IPntAVQ20YfwMfyMBzq0vYzM
# DATA kmmFfZrUSkfw+o9OPChpopLF4OWJUSTeeqFzSa3jc+PUDFWIIQVBAcLMGeoA+wmMHhWSPg7O/AmuyVE2w7o7T6lYgmnMFrElAoDT
# DATA 4KzAyMuoIU6SebJ2c2CLAcBkQ++XJeNId0Tv0OzlCDOkIQMwuH33sTtYJQjRzvua8wENL87BYgeJdZbsekvW2a0vuN16USjsU5cH
# DATA 4gVzayF40egbFSQBmfqTsei24h/0+BgpTJG1DNWnrir0nChwXAU2dUEBadvk1CVqUsvhqZspIZbqH7LapimwiPTrKdKqhnVWbc8V
# DATA pHlPj54IzTOBU2l+KttiEeZZ4UlB0iXwsFFiPlb2GSoYfcgiZSghMKlJRQNFoZPv8Q3GKClLcHOcP2CxV4lyRFmsY/y2majFPAek
# DATA qIqe0SxOK6zMzrHRquwFC00r3tv4ADZIERRZATiCsSba72Nhbn2s7wO6omLN25SiUEf8LS1xFdLsFrGhJHDuVXjKV/FOsFlWVJ3Q
# DATA Y8ySwwgqVvueZVQnrCw69hhUoKgvq6KrX7gY45dIwMbuk5yl6SzNZZZmYZxyHlPnMT3PQH36wpQSg0wpK6ZJMmaVOm4QuTzlaCRN
# DATA ZalI4r6q5xVxVlRkMILuHJoR1qeZCsaeFU9W71S74mXEi1HA7rGVoNQdpU2q5UYOEz3flLGbcAEHI2xgEIFsBwXbBAomFpdtWq26
# DATA 0/i5me6iv6y+X6t0cq6qz6vv1jKeRfPj2ceI5fl3QY6Lf8tvrUa56MIQlMsPJhF1JlN2Le7hyKK2DLG+4Te9Q3slo9ao0gXlRvwo
# DATA UgQymoJgq9zopEJ2O/b+9qheDPB1hvESIWMPSYY1DznVkXEPAWPrOMiGoqWqLXS6NBpl2+DgXEv+fXiccP6FNE5Ni7lXrxZzr9Gx
# DATA cu8+L9Qg2dzXqkyCYimAzjOWoxRpTLlL/MKjCPgibNb11CFcESrdQm4V2uDFM6y5OsOsBi159l3qUyl291Keyk5lApPnW61U6+rt
# DATA ppVvM5hSvEzGhlM8mc8w5EC0dFScWPGIwbAeqnk0u1IUPDMJO8KOxtEzkHetC+TdG6gCqchK5OuDhewrVbt6rVrKvgpPpdlEPZSi
# DATA yGieKkqpIPZJa8R+9DANjrGVVy8NsN5svjTwJHlm9+EXzLJ3V+dXPhoohF/yINDWtc6ke8ypEG4E0H1CLzwim8OY6WThPqCGN1Jo
# DATA p5BVh8dJyCQ/b4h1YO8DEQpmphWumOUTsyqT0UBPuc6avGjR28g2ezC7cE2rrc64fGCUjDOOgaKBpvPwPq4qr8vE8ztUw0KdV4FX
# DATA b/GeIaqo2BbILgSaLilHjNhujJHnupZ4h/NY8b2YG6u8N2w28pbzZxXh9aI4JHKM1yCeQWLW5nj9v6ePz35x+vXpF2BsPfZO/3j6
# DATA +9PHp/96+gWjt75YBHb9D/rpd6ffgLF19t9wiydIrtM/n35FP3159vOzX1cQDoVJYX1Nv/27d/Yr/LRHdzym33/Bb3p8+jW9+Yuz
# DATA zxgPBmSXIoD9gr7+OwVIPzlm1/PgUsmhfugyxzYPSPqQLIYPlJqkxgWm8/6M1e+lQ6EMi2YCXzzC9C8eiwtS2i1cqAOcPgcHAAol
# DATA /BQ4jLwRlbd79pVGfhKM1mK83sLKeBicmJg6jpfta1EdxHWDvJaUytWRvFQtzJeM7qtqOYopnulJ+X6pjfrmtwuVdJswL7gMVUxE
# DATA C1925kc6Xg7otVnRbZ3pdT/KQQc5CyIFJFV3WYbKwSXnZehtsBdIZIQZqmBOEcPzc4Kv+9734lDPjql3k+m1OKdUShfIXudXxtX2
# DATA zGIre1por/NT4dBezhzYvjmgaV+XswJeitWW67IArsIA2Gj8v+Dwfz2jv1TMhVywoF/PWKO6Cg7YQvIBNcXaUMac9/Upq3ANhOoV
# DATA J6GczrdnamsEb4FgkZA4SM2bdFCccllwQnEq18FGZLAP2dcLfxA24GRwvUVpMKooS44GtDico/iikIsRxlpKNYTXkMMc88QR1qaA
# DATA 2TEC84ACFZcHnFPUxuGaiSd7lMUMYvfIupjFk0g7qnj5DKFjGRpmS0VsFnqx2CEGBOUoYY4S5ihhV0cJ23DI2WgOtKnpfL3TgMvM
# DATA ArYxCXCkMEcKc6QwRwpzpDBHCnOkMEcKc6QwRwpzpDBHCnOkMEcKc6QwRwpzpDBHCnOkMEcKc6QwRwpzpDBHCnOkMEcKc6QwRwp7
# DATA ZkhhjV495J8vRQprD5qD3nNECltYet4IFWbni9/06n5n2Gx1S7SpFvWOnWgZbarekRziMpIyaLAipZCyfL+g1FMuu5pvF16rkP/m
# DATA nYXQm13/CkPvtvLAG91C4JKqPHC/3rIhYIXAu4NOrzcoB95qdrceegH01hAWm0DK/FYOemt2CgFEzSDo1BeaBT3u+X7nqNEc1Tqe
# DATA 3z6HQLa6TrQvASDjxqYBZNJuCwCyZtBtbQAgK1wBgKwZ9gfVHEDW6jejTtUAyPqDfi2MLABZs9Hvdq8cQKYb6Fr41L7f1BSywv1m
# DATA dNQLBM1NaGPFIDRvLO/HdU4tODKtR3tYlFnyzKbLAvstZYHUbMdDbX/JmrDPBlHhzQWPglgGeI7nL8ab5DfJToBJtcQjWTMeScmU
# DATA 8jLLkoW+5sILagd6rkW9t5/bJaXod9ieW8ZF63a7RRoaVplXU8oK5VYplcUaa6d4Y8n3YNyHDkPmMGQOQ+YwZA5D5jBkDkPmMGQO
# DATA Q+YwZA5D5jBkLxmGDHWBQglHUSXiZaLwdrXCTnf+NCWzO8pu//gnFThUj6LbbMFW0NG+j59uo0oemArNp8tgHaU7u4/iwY48tPtI
# DATA B00tFCZIMOlH+xOyUHf31KsO7OAPWNVZH9zYkejtHqAr+PiVD/NjbKHgxD615jjYR6jfL6WIYx9r3ov001OUVFbyoIlxuqN6K+gT
# DATA S/opAZPwxu2p2r2ffQeG3QGlD4G/Sr/tPuKnb08P+EwGxYl+/Au+RvFYmppCgk3WH5gMP5Bahwk9N/q8hlGe31P6zpT3CgmnT/4Y
# DATA 5WfvQxySKp6/TCn6TPCg/IgTyT6x5Q8+Xf06Jr31o3i0s0NJ3UOad2+yaQvIm8oSigkl2dQLakic+n124+4+yiuMdVnibt9HGWdz
# DATA 8fIapGKJXJUcUmPB7qM8w1B0KM6YsjF+VZHzWNIN6Yxv3NA370/nZJo8UjG/JXfilB3dV+GI0MT6I5y6+8/P/i91phHYvPiGv0td
# DATA DEViIfg9f3dN2DgeaYf9AY5L8vLHYuif5nXhU1VHeDKp2+RiVVYPHBRq/4HUs9uYweqqZ91QqTWrxRaVziciJSyEPq4O3Mrowmvr
# DATA DNy8zaunUpwhPe8pLl+7u7Bqfp4DpX5mXZP4ACqreXtQiUJUdJLMHHBJtPgMSjyi+ZDpU3UNNI/JWLFbiDQFexxPaLq4LFCspNFD
# DATA USmTHDPG6UxcUmfC6Uu8+PoSFyXJPAu6E7yyUvDXr8fJvItD8CByQHxVH5wODvGqWTJOUpqZrWXKPIuiFc/PEe6rIM0samxsGzWz
# DATA TMTkkqwZr7BEJFWaV9ju+FUtDSyYTSMnRi9Tt0DAU+pJLvJhC70/IKusIq4n0bJH5I3lLat5yRSzSMD1hPUwnKczlvqK1XunNPJP
# DATA RD8hUVIfRsR+jdDHecqjL9AR/ULDcSaUM6E2NKFK/asT7XKiXdbwu9L4ehbEvF6fx2BqFWWrjJTXd0UXym5KGHmmUYKGdjxMCiOU
# DATA IAT0ALbv3YWIDYqONXUCmQsr+Fj0gJpjMIoHULyB6DacDyIhNYmiUGPGLspPMRFVwAclpw1p9coSJS0HT9kEnjJOpOhY7159XgdE
# DATA SdmNJhL48nn13djtI9zsN/jT6ju1uaP4Qvz5eUCn2Ll3QZX8DgzH1Tr5eVkUWBbs1dPi+Dwrykc2jF9pMj8c5o3hpwx7ZwkPjUua
# DATA T8h4ZC2qfMM02vNRErO2VZ/NQ0+foIfVOGexuSnL98LYpDgcRrNtUAaeIP+aF8u/N6PsgcfOdgstAG1cBXcy6WXJOHGFZ8wztE2H
# DATA 42D0gPJKywdyeLhtPgKmm1GNXjThMmDxNpyC8MJ5qsV1aZDaDtMib4YXhTPU1udb3qol316nMV72/TFTZx6b2qdsK6pzUbRSyBCr
# DATA RxOwLCQvWZpOFhMyRe+Kstm+930GYkT94ST+ZB4ZBUWqpDShAythNsS0YxhwTUS+zlTF3UJu5t3URfPynDqoez3JyY+o7rAKopZq
# DATA NhhSk0mURq5CbKEq1KhBwpOF238AKciSKatyL2DZRYX8G0VqksnZrjTkjKj3oDgMP60W3LpYC349GLEdoaYKkc2igXHAGZLNp5iA
# DATA UQKDtHei5gZ90VmUnc77Hq/UIHdZjjxVbDfKtUEUQUQRUy2yKKJsGvVjJsKK+mV6wnqGZhI+iY63kYP22HfRClhdn4X5UKpgK6hc
# DATA qbmoKbg07Rpz14bOXpF6zDSsH4DKQxl1TAY2THXsoPCGZBGifiHLWAWUhQ+pUkMH8ghbxdQem2cWqvICuTbyIJxfw/k1NvRrFGua
# DATA c2s4t8Yl14RWukCuTKNcVdkC/RWmOFVz49146qyMdd4NZjKu5NjzRm9e5sDub3VyUV8zk17e1WCPnOaKnvVyLuXnI7EzhL4lg4GY
# DATA BkEodkHBIcG7WuhntpFMr7OjtqfsKr+IbuET3tCPV0ik1NOmZ9TfzTy/Lsc3MQykZNyT8cJn7nBxHDyUO6pyTi6a8tG81b4T3iTD
# DATA KbHKdOOoqqdNVPV3E9XauVH1OxtHVbb9ILL86by46dvz2JkrJn6NZdHzrejV1sROrQoaf5acC+DpH3h7N3mf4phMbLmRzY90fOdV
# DATA kVbIsxDHQuw6mF8q1LkpDe4zOY57U4LIK7LxzVjtw1xa4cARk4gmg6FlahcU/v+abNO+nqDSxHyAUdKAdGTKcBzQ8A7YzpQeJQMN
# DATA MzBFBcpnsRpIqeiEarIllFSz99dCWmJITkZ7DLPkHVv0lhA8zERoovCiVLww/tnPYgwp7F6ZzDMI8mcnZPsm4yz3otoxG0aj6TkL
# DATA x6VSzRePbb9qvgws+S97tujx9/EhL/FLBSZbuaRRRjOr+ogNyyX2cljlFutwnpJNTCadTTv8fxhe+AVog0UG4dk/4r+LtMN/Pv2c
# DATA eYRfnX5z+gfv7G/Pfnn69emXZ39PT35DnxS3kBmHIBZK4Byyx0DEz4FRPPuMbvj92T/QQ1/itm9O/0jh6Cf/cPoNcImPGYNIQTrm
# DATA 4fMwwzDVK59YcIUH8QQ5Ss9UlL+SOxyNxGDhJEN3lgiTRfQ+laLQCGBYGYIH9aTa6JnGUZ9m4+vghh/obQw0ADBazaENrcmELrDr
# DATA hhsulMrVoQ1VHdG3gbOhiTv8y8L92L5idbj3k4Ha07J1tCFHoAA2jDOu7A5ruFmxbR1r+NbD6Qi9TKCdIeMknI8CkNeTGWv27Hsf
# DATA oe/nvivf58WLX9gYT8+a/U8Uh/mYe8pMtkHBhZLMAr2WFUwEHbMANDy/Cq62Wsot62nhDM9Pg8MZupH+CUZ6zS28zAD/cngKr21w
# DATA 3/7YvtHQfsGR/XoGdqmWpTywmIVPq+VcBZywlEqsAIAEpDh/cd9KrD7nWE5QIC5NBZUDbU1vos5QPLz5WrYVa4luWEkT9oqW821D
# DATA IqHxsuaxy2ZJn1cceTzWqDjmx3EtCWmuPclM9KN5mnjBmPFvPORHZDbE/RhL4wWboGAB/P/svVuTG0eW59nP+hRRVVaWmUUAxB1I
# DATA UkltiqIuXSTFIanS9EgcWgAIZIYIICAEkMlsldakUtd09VZZa3u2zdZsbHfbxmbN9mUf2KriiLr2w34B5FeYT7Lnf467h0fgkshk
# DATA ZpIUXVUkgUCEh9/9+HH3/y94iIPFCLwTwBuldlSrtUKyHqg4bwR+jAixbdcewxUjRiJ7dYRSJ2vrqqhbkwOpX45W6GiFjlZ4VrTC
# DATA FYealaY2q1rG52njn8TEPw0L37EKHavQsQodq9CxCh2r0LEKHavQsQodq9CxCh2r0LEKHavQsQodq9CxCh2r0LEKHavQsQodq9Cx
# DATA Ch2r0LEKHavQsQodq/C5YRXWStVqrX1CVmHQ6ZaCxgvEKswsPB+bVFgreZVScS+/uflxqZGvNLxGjf7erdTKH1c3vbJXL3uVxt7m
# DATA ZiqX2qVWpd3NYuworPpcjF11hmwoJ/0E4LeZBvjVKqUMwa/aTMpajq0lBL+gGfjtWXCixQds1lLBlyub6eA3KwtDN8lMhV4t1paE
# DATA XjtR6HaJNEtetdrYq272qWvNVzf3qpsr53RpFkbYKHm1UmO3XqtlQmnX2q1Wey6K8vjYQWk3GjsoTdDCDtY7tWajcyR20O+2uvUU
# DATA drBDf3fKFnawU681agY72Gq3q62qhR0s16rNypljB802NQj/76w0X1/C7RP71puxi7Q5nnmbGSjV1OutgLqb0M9J/OYCDGtqJa48
# DATA Q+vDwuLMCzJud9to1AWSnneTueeVYAd4dfljh8nW6co5VNOmEzJFjNx0UFf8rKFiYQPTkbU3F+gRXS17Fed5e2UxJZ20Mnyf/Jf6
# DATA Y8+4lxMHM9may+bJErNlaZLZnnDAQQccdMBBBxx0wEEHHHTAQQccdMBBBxx0wEEHHHzJgIM2302SLV4MIaXxUXFEf+NXzeKFcjFH
# DATA M0v10z4X4YZM2TTm65ockuGDbmhkF/hXcOnafQQceP/f/+5tFvGtEwTDwof03wC0NQr3ylbxtQ/X3mctdT5Hxws1CIR+lCAKPOWh
# DATA CEtY5vAN4uK1DnAv0/H8VowQN8xT+MTvesc+yiap84J4DD9ycMn7H7/7fxGZmbSvV8rFC3KVxT3RNSBIjTJzCDF3tvuos93uTPdP
# DATA /Uz3cUlhz8NZ74yLbTkm7Dqahnmi4N1Atbe1XebCwZ7p6fAX52jkWVDAsofZT5sBNisJcFICWNpfq8/qX2dql1QEeU03MLo2b8D1
# DATA 6HudiH6I9/mM9i04IVG1WApo1w9HBe9OOGb3kxZ8lwoowuWToRxPVoWbOr7vJ1JGQ4g2Rl0+i5yI5mQUbmbK+UEAU9k3cjuwic5f
# DATA 6eYZnYK1WpAzhpwxlDWGZnpUJ3rjRG+OMqOeDzGcW1JfmWjRiQz+4qOoZRRxbhvtBmqG4c5Akb+UhprCR45oWGhD3KKLm0VJIvaB
# DATA X4V7VONxeEM+y3eIDg3ckD1bu2WOZsrK4K+7UJ2BfyxRsrF5MOy7ENUOh/taDfdFSYE+iUr6mFvNYtgXux1FFpo/Lr6Xt+dyz3KX
# DATA P70I8C4rL47JXbmzhJ+kc1WIK1fRKqh0xbYS4Mrd/UjEmqIJBGN8yLEIZKWPlqIlElHDffZCiSyTmIc0ru3Bi/y3kGcZ9dPqRaJS
# DATA RLZflIx3PgRhqHb4olHfZUNZnzmVRqNmB/OFnWcFoM3Cm9gkSQJNjmkpB4wNWFDmjKEHLEHop+Nfnbjkbq9ccrflgLlY6brorsMW
# DATA QUfoMxuAimNHqX/HTPoKhqyOo1hCaXQYio8lfUTtm4pAJqnbms8Ij6HaF8W9aS8YK7DASMUlHkbjpy+yVMrOr8yS3uSYZfbuMlqZ
# DATA 6pekzN6FABHysRVRhGxAFEsT6XUULWi2I4wsyl3qxHEx6pI1Ynha3WBfNKf04DYWSXjcKYs7XNL7TH9j5oppdFz6rUl88PSllU7T
# DATA C1BcN1curps+wO28mEF9fcKjindFS980Bur1duAPfxAciLXf8qGg5e1GfWlYmBwMODTWqBt4VFAj0MKAygGvih3w3fCh4OMYmpAU
# DATA Zlb47ekLLZ2ycyu0ZBQ+ZpndXVxmejxXvaIoB+JaUl7ij8A+fAwD1IRiYQX2xBHD8shtNU6wN87b5vLtMr6LOiGIkGHcE8sTx6a8
# DATA 4YQPz7F4wgBol1Po95K4P/8lUl61RG4GSrkOw8dY/aQIl3I+KNADjDQnsTZEqC/y+HgXWsCBCBIKGFC1Gu7feGaNAGB281AWxtpI
# DATA QemK/t0ptJnZhJyomM6XMPdUGJOXwc9mBeEcbc7RlnW02VXK+dicj+2Ei40LfXJnJDgtU3KZ6WEEROWGjWlcbM8QanBG5LmUJ0vv
# DATA PYG9z5ussfzU5H0zPBNWvx8BOktCMd2VdSmhxh2FOquvyGHb194yA+7ieYHatbfe7h8JuJMAEsCd+m4B7uZi40pyWYPjiitD7mQ3
# DATA D9yF+CCMMaEgQ6WY8yrjQFQPJN5DHcKMz65RZOwXtrV7+1jI5P1FjeJiL1+pxI/cDR6iJ+pYT9EvSx6r8mNv090H9jPV4hI34UJE
# DATA nTZNsZuWLLXxiwups113+7sUivcRWZ6D4KBgSz4rXWfpBOAQ2o+8Erc0f6RgcXrD2pCmScp0x6ozdRYUJ0yveOCmoI07Xhwa3LeI
# DATA x165+7W6Nr9YbTvzGHBJBVYpF7neWS2c+qiJhl+qPbntdE2F3rSSYadQtAp7jiz8h9L1DSiOPZkqsmr2cDIC6F0WtqOY9VMtgewV
# DATA IHI/EeM5QchRLxK0R353bCHkbuhr+cPfT388/Pzwd4DITf88i477l7n4N/rymJ764vCzw89x2aN/HtPFr/jvRwDH0ZVvp48O/94g
# DATA 4Z5MHyuFdCh8DaGdSkO2w8Q996Y+W+a+Z+qM99f+nu9d64RyFktE79W+Ep79dkdhMOhQB8Lf9qNRr2Osf3i+J0PxncKVIK6z3gHT
# DATA dSO4tIUiyk6DZIFC9Tx4KnhIDa2zFCH3OgQ0WGvC47+FJ+E4csmMwHQK582Rm180ZweT26XoMLkggVNzfdXXj4LJXfVFEvwsgHK8
# DATA +YpsR/qXxgRxXWE0R4NxQLnViu7UgXKSZz6bOQN0bjKvMtMpbdioyVRfOiiyXHRF4QU+Gt7Q77K1vTPxqVGMA+rb3gjjBzlYP/T0
# DATA 1VvvefEwUKQMHH+ntClVmAnbQHAtjlegzc2vo4tNnLlt8HnBzs1PjEPPOevhjKwHjaU7sdHwUrgQz89gOCN7YSVz4ZjWwvkZC1JJ
# DATA 52WGMRSez4Z2FhQ7KxsAmsMicScYgkNFpowZqE0O8Wx+Qba0o35/gu4aC3jvYAbRZocFS4rElC/twB7xRwE7KMT7hwyL1WZ7Gump
# DATA yPh6NxzxKdo4XplwB5BWrHyzGiZGGbJHFuFI/Bzq1y7NlUM+4MA7gm5EH9GI5nHy2pSBUXdc8G7reMsBBQULyzqBZ+wWOSugEWRG
# DATA 04JJZsgP6OJAOniXMjlsi/eY0z4Qdw3v5QwGzNHBCXm0LoDIVJWgXHXMO8e8c8y7M2TerTh6nehg1zKz/NxnGqfhUT3pPMMB8BwA
# DATA zwHwHADPAfAcAM8B8BwAzwHwHADPAfAcAM8B8BwAzwHwHADPAfAcAM8B8BwAzwHwHADPAfAcAM8B8BwAzwHwHADvuQHglUuVTqV8
# DATA cgBe5YUC4M1bgV6Jgmfx4soJjk5OoyX53sgolNaaqeyq1jYbtSBDViuXqQCqS8hq1qs3T/zqZrlVrldO/upy/cSvrjQbrWrn5K+u
# DATA VE786np5s1JtnPzV1eIzK+tq45mVda36zMq6XnpmZZ1q15vN88zwVLs+3qufNsNT7fp4r37aDE+16+O9+qkbV/GZlXWqXZ9vWafa
# DATA 9fmWdapdn29Z2+26XKufZ4bb7fqYr37aDLfb9TFf/bQZbrfrY776qRtX8ZmVtd2uz7ms7XZ9zmVtt+tzLmu7XVdK1XM1FTZP/Oqn
# DATA zXC7XR/z1U+b4Xa7Puarn7pxFZ9ZWdvt+pzL2m7X51zWdrs+l7K2XQ/loldplHdr9eJeo/Y2fU07HRqteq3anvtYtdrgxyr12ceq
# DATA cHQ0jmOOqQmIBZcv1VNBlpqVSnk2JrVizSvXarvlYr9S84q75WImN1q1oNZqzEWyN09EU68kNHXx51g09WbRD2r1NE29tFkplWsp
# DATA mnqGrw6aeivYbHcTmnqtXK9XW4am7m+2un4xoalXS7V2uXjmNHV2BudbvEnfeDplsV1j0RNva1Mc1vYzWSC6WYqbt+ymN2o0eIMm
# DATA tmcyE312t2MdflZ5DR8EW21bRt3alrEQ6G6Fupy1LsWlnJY1s+yiawQfS9j1O9H+pU36EX+KnirFTwv0qj5cYAuWYMszwS3PwyRA
# DATA T2011fvXZNnK/Dqcs/tArfXqGmaWAdRe0MTTncucKEgvbxcXw9btklriDp9X19jJzX51B1V3UHUHVXdQdQdVd1B1B1V3UHUHVXdQ
# DATA dQdVd1D1lwyqnliMSrthfcPYd5Rq77ZofyTCH5eFWMVdNtvKvQPGlYuoSL4fdYItQVfQRdlmi0adXBORiTxskK1yrVav8VXM8kQ2
# DATA Ld7SbHSeGivEufoNjVID0hExuCDGEGbbakrgYV/BRpJf6vKCaNxByFyY+IJqzm2jENNQHawXc/XqBowjHFRZv/jBh+q/S1u/+Bn+
# DATA HXEw9y7u5KhcLU47l603C6eHqsDWJ3v+IOz1/Evl3LA3oWl/fKmSg2TcpdqnH3BUeBpr4nJP4+nvTHZ2gljGRRYg825v37hksPHt
# DATA IOyt4w0Xstnzq0KpyTT5t8LXBVr/Osv/JDq8mVAkABHAoUk+gtD8+GEoUPlSoayDROesWCIYFUTwApp6InTIL1R1Bpp4Y8jzjclc
# DATA 1jVIlIQg2aKA9JwJiYYsXX1tmTnFGRx2F1iyn5iJBiTSMvK09HRSyTcuY2SB4yqjkQOxD5UAKLnYkjccYxkIfp5LC3Q4nTqnU3cc
# DATA nbqMmItTrHOKdXM0fxazLJ4XJTtvOEI7ZQ2tdJyMlN12WtJtZwJpXAgzLdJuU2CLAXizYTtUQWN+x2qsWqyKabRZSbo0WmtGjs7c
# DATA t1u+cgtDE3UtOuLiDddyU7+RcVsppiXkK9jAERPqgQEE6gbLOHlW0R+zQL0EF0PL15MxX091L0MsFlpTSm0OiC3PepJxnlC2ojgH
# DATA 0ManpIQwrjWHkI/8RV2OTvAQEDWR9UJPZR6mkWqRUh+n+w1lF7HcXqJ0q4ZGnf47xpDytCEFxTrgfUSpmObDQj1RORSyjkXB+w1G
# DATA zplH2rsT6BZr/TFlrhQ8njSkBlrBAwsAVTy1uRRVOLEoyLiEQp/03OhjGbMSIsIMKqZXmbME8bIc2VZdvOSI6tW5sZjcGEdDxTbg
# DATA uhKNWE0O6mfxZIgRGluOoedMda0ddKz+f+w/ELgCrEK2ZzD5Gh6oQtWDi7/vHyQWlQxAEnv4qr27ATsyddwY7OpbphiDiO0hh+tW
# DATA OF6WbH4/3vZRRJnWwmDoc52jeYNO+HV4UDzLtteqgEyDSusFCg2VRbsoSljYGnLJsZSc36EuPDRkGyUopxMgMnQa/qQnGImgnGbd
# DATA MKDTT1qZMdWYaqdNOZUN1Of0ogP2+mYha6IM9tMXOEtGHWegOgP1OAaqM0dfHnN0oZn5nAsr2wv8swizXspOlRZDf493eUCCraIs
# DATA 1OQR1utRKKznVX75xVITPQroYG3lENwcb5G58ip10NmWqo+jpTZ5NYuZTV7qqJnf42/z2svsMTFp/e0Ibil548GgraOj1JeuvDtz
# DATA yow9+GTzLBDytp7lL5yuDARMb6TRWtmvK5txVytPc/5oY4wNtvnizcoq0/LAzOuYDC1b0jA4abCHPaqnCwbzlTYw0+ao5eDL4Cuy
# DATA deH1SYiaP6u3LZVihth1JOFjoF6co4iMAjJd/BZZ3QrwkWnvOP0qTUETgHcrV+70BfhNuWloyNzcWMvXV0TkvfSshWXAQX0fBtGw
# DATA Ry30fV73QF4k8w9WM1PERZFJTumEpw3HsY+Kq0FvxlrMIqU5yqr0dHTV5M8Y+5g96PJUzDSZYWAnhMw4GUuCWYrqqlRpL4nYrREZ
# DATA ke3x8ohd5fUGL4bFf6Cjpy7KTJotcM9HVeI8Qk7uj1g1O9of0JSNfgr7kEPXlXVubK7KZG82Ni+hSLHjJjsr/qRWfLbKOT+z8zM/
# DATA tQG/cLpwdn5mwxPP8jgMVu25xHydB39Zr/zSD9ceDmXfDq+CkykTRJNY+1qP4BknwZh+z7pkAL7NowDMpZWBxsbof5+7QUQsDTDW
# DATA NySMZTNNyHKF1So7flOO+8UMYrUOL9M8/rj4XpQ6m23st1/CKJ5NGa+lm9ThGyMmlGG+/lb4+pGIaSuYdB7oiyae1aOKpXYMzjSv
# DATA +ivoH0VVLmBPCLVXyoTlkTaPW9hpfSXhTR8V3cqqseWNHEkH1qeOgfqOTByxO8dGjY87ac64fDex2/Zispj0Mo0d1RWY1Nc0Kpk7
# DATA iFHAaxbaM/3iAqrNWoF0wD1/MqD5EBYE4nGaUW3S3wGchs0uXiOwKEPo2UcgMwMhLb1MwdvG5b2Q7B17kYwtoeBhW61meLIeoY46
# DATA dBU1Exs8fAHYHMTYsMazDp6xiRHFaxXKUBr5oaI3gSXtD6WnzpRn4kBRvWOyiSSVsZZ7xCB5ZrnISbFLHmVwTHM4TLzClgUxMdOq
# DATA EwWCj1IzPw+cqH1UMsoMRoa2xwrvY0ahoznZP7VZkwXMnsRhG16eMLKQ2dP/4/CL6deHfwTVevrd4Z+mP0wfHX7pgZ1NP/xl+uTw
# DATA y1l69j9Pf5x+T/f9YfrD4Zd09/Rrevjf6N7PD/+U8+jTj/Tkn6c/Hv4OFG0ELSTtz+nvJ9MnzNH+jB75V7oFJO1vPLoLvO4/UbBP
# DATA KNhHeHr6FUXrG36SgviK/v4BWO7Dzxxd+/mfEFInFvWDPMhygsjS3Cnuq9rUTAHC6/EyMK+W31IjhK9t2pwgwdg5RWbcsBcoXpii
# DATA XVHvN9JQe2aDJUbrUor2bTxEfVDg0Nmp+V7SPZw3PNsqkbMjZqtaFVszPb7AFTPO3t0K/KS7fp2+cGVsBTTWnyYqm8JldnWoRzK1
# DATA tWJmUveSsrJXKLRTJ2Vf3Y2gU+8DYk5j6kDbr5TB7HZSREnuTajcZvaAi8+XLBbqpPaC3mXEdZe3SZF9F9teKj+W3lBvTjlO/Vts
# DATA wSSt6Vmxr4+MvMNeu2H9KYd1jbc+3mj+cnhuz3EkP82BfKVx/FjD+LmM4lITTdKT3b7PtKmcBaDapFG2hy5KHnfeyuPD5ZyTnZSU
# DATA hh2WyvDHu5KGLjZC7sqSraw+0/TcFzLtaPdgvNtPCszaC+nr3FDIYgzFqxCpb0aeia6AdzVzmWMziDxpNfPhvAVvm39kge5YyMSs
# DATA 6CxLWKpXRUDxOBqStbWrKLhjv4UMkwN2Yj0kqTKAbMqvdhiLPoXO0jacEY4v7fjSji99hnzplYaUleYrKxq+52O7n8R0PwXL3YGk
# DATA HUjagaQdSNqBpB1I2oGkHUjagaQdSNqBpB1I2oGkHUjagaQdSNqBpB1I2oGkHUjagaQdSNqBpB1I2oGkHUjagaQdSPq5AUlXyxW/
# DATA VjshSLpb6Ra7tRcIJG1WnFeiR9v5ARdrrbZbL5b3KpXi2/T9b7P5GNQ25+Ctml6pWd2tVet7TeCtmunH2qVOo1PKPtYvVWtemR6t
# DATA FPOlhleu0Aev0sxXq16F/k+/NfJNr1rxAM8q5StNvlbG7TWvsulVSrgbl4vepldt5ssl+628EzLNtqp0an69OI9tNadu1BCfxl6p
# DATA nAW0teqtUqs9L5TqDIzPpqRV0shgCdcCeNWT6ltJk8wDv9ZozcSwXK4/fQzLpUoSw1rllGO4uXkKMWzWkxg26qcbw0qj/PQxrHCT
# DATA OKNSrlIjeeoYVivlsyvlWqn59DGsFWtnV8q1zdIpxLDRPOVSPg5ITwYhDdKT8cwC6W1Wa6XKZhqkl8Xm8RU/C9LrdjaDWgLSq/u1
# DATA oNE0IL12o9WhOboB6W2SdVxpnjlIj7d/5pdZ94VKhk/3qfXQLIsu5RIqNdOzHp0JbGPBZUt5j02P6/lyJ9jZSIWcIfS9FdC4Hvo5
# DATA iXvW+V1h17cseTOcL7t+r0Lmydqqa2oFbb6zP7diJR3BeHrjUcpyN44FHDHQvnBsDMsfcwmoOs8BzX44KzzlBZvF86nalC4NFIbl
# DATA lWhgeWX+dqiZVxQQa7JZrVk+mai6MdglTFZxrb25GLqXlHDOLpMls4jZ2qaSa1Uj5exeXjg8FUCtXziNSgrqePNRBwF0EEAHAXQQ
# DATA QAcBdBBABwF0EEAHAXQQQAcBdBDAlwwCiLqgJopbbJ3mfBz6zEHCd5RjGbbiZckPPh22JbUl7PzHLfyYR225zIGIeMSWGt7UV4rb
# DATA B8VcOVfN1amPDLvZHlLdtrGhHzd3X+bXmYq4PsiF4L8NdLe3pZ6wer2Ny4OluQSAnB6xkvip98go+XDrykP9BunJ6Iqycx+q7oz+
# DATA A73OnmMMcXRsfeOTVE5e5kPA2lbkDN3IpGqwdYUSxMcvYYzyvB3Nj8/BIQkFOfmpMH8UNPdKCoK3weZcehr64Zo674eOIqmVWzTq
# DATA soSsnDKm+igMvNty6BhJGFIHy5g7k7AxW7xA7v1MvX1DLP/5ZXNESsbRzk4vlZJcSO0ctUiSxIF+gO/3TBEooGK0xbVS2/5xGzqP
# DATA SO5Gbif101s0iaCKHdGQFVDGDNoHUmj8Gnpb8bVSs3ipUile3ins0L0wFn+DG7bZqF/HqYWcClC2oePyhr47eDiMBhBs83u3/f7w
# DATA bpR+tliaffZCoVhHhCghAyqi9R0Epr/I3VDSCwe8sok72QO1Lp+i4fq8EBtUTFKAtyQzWTARcMd1fLhQYmZj1PWaXKSceP3LL5uX
# DATA uS5uWRMZlHSuUsQKnAAg4UaJuK59quYkrIyvEYy6OnyS1P3Lqmp8qtsAT4HH2G7ERbh9dWs/HNDEqsCnyrlePhz/9rfq4n7QehCO
# DATA 7Z+kt7i6Md6lcdq7Nhpx7ZYj6dY4jfRxFkk9+O1vMR/cvkoR8vf9kGZ/nH3op/sYJ+dU5mO2omhoNSLpH6WhXP6UZ/t2nkgZSZzT
# DATA 5sXs8XURPRIFHkgfyinuVuAFNE3TbZP6HTOVndPV8fm4sEfTulSnhyIzj8mQt2HFkgJVpTAnSKzx0yMmKOs5ztrXpNVLMOJTM4dq
# DATA nZaN07KZp2WTPmjtRG2cqM2qojYLBcjPSuzmGtZdeHSF2sQgsGVbtPDNsxNQOw+VcTEF6PJdfPDWURzxxX44mIyDo3Ss9bOmczIX
# DATA jOSyUg3PSkLL3hClCV1eJmGtj/lStPm4LhTjD9BlcX5HLJxBpcMLaLuy0sTFSQHI/emMMetJVk6YH9ks5SVryRueAhX5znRGaA9O
# DATA khXm1iTp/GApo269/F2l1d9VSmczHiwf613l1d9VTr2LH6wc612V1d9VSb2LH6we613V1d9VnZFav1I71rtqq7+rlnoXP1g/1rvq
# DATA q7+rnnoXP9g41rsaq7+rMaP/fqVp3qX1VUwbXqiubk9ffwJi6nqoEKSLViKyRhvq+x4IWglHZ2gqJx2YjJCYPQCbzJP0PqSWRqku
# DATA T0Io5bxKzqvxcNQARSsYsJCqhx0EHLQAhfuGBGZFjAaq+f5TD/0rwwws2S/jbU9UpWiYwrxBK4JhEESYYjUeXw9sBSnzF19MyEFb
# DATA 3dRp+dTJzZR+mjOl44JYn7ksKG/uSvZ5nQXC05LfPGVupy1eOhfWuRAnyxqCfPLQtFThokBmfAlW9jkQR31BxAJXlDf3kp2D2rgS
# DATA r6WeL8uJHcodmkxDRRMqScbQ2lYKrf6IRa7gGCVjCE+TWUX2FfNPee1FxFqHMo3nrV3QYcQ8nXc15fCAKqhEuZEn9FRIYY/esYed
# DATA iEIF2gGbjOUn6eXMyIEunxZDP34uwuxjzciMdux5SqY/G0spVS2dseSMpXnGUqqrcm7ml97NvNDIevaa6rrmU3X2WVb6AB6AAd3H
# DATA m5ESjfXhCE0TMsCZRrYzofkxu5pHgdLAnpH3puZiFMAtZfBITfG5DmUcyymrYVZE3dxH46puxjwiUekafWUMm1G36/l7Udjh1c9B
# DATA FMbsEh9pTW3pDhLweJIwrehW8O7QEO11KTQRUY95nVSOEmPw7UlcYt6/iEAOjBY49SyTVkyNfjIWw41l5MD87mgiHGJc8G4onW2v
# DATA H7ZH0XCXHTAKHxf4bXbL43nKAehWo/ua74lP3D0+2xoDpQavM+VOMBYzIk6kn3sRNrKMQfOVDXhDn6GGVrenAXoFbxuZSUGHw6EC
# DATA byMIdsld9rCwjauM3vblLrvMPZyRQF88QO5o9Lukm1Pl7dPbeGV8SfJu+rBrhFu8ExnVeVxlc4tKAmaxFLDGzlOpSyUfR/1oNIr2
# DATA lb63VH9eJddFw1Xfk0wcYF9nNGlDA4Yx6OK7Sg7xJmkThruBplNRYeBTlOVl6XmT5fnZM4YFnhlATo8sOp6CBLAWxQJVivARBqkx
# DATA D2G7ZDLYhiW1SUwa2NSLxTSk27s4oY6mYMZBqQ7AIQomAC96EDB8HjWPsrEvhcTkabIsd1CVeyDRU2QmAwzMWFOKhnE2kWJPHUUK
# DATA el3qOa9cIT6So5ILk6xHGNHmwSa1kdbqdfPacYxhbqFXeZkTOb1QYkphSeYlfmV+5VO+tiSvpV+kWZnGd7qv4eUSaTQJC0uYBdyI
# DATA TvdtvGBym0vWVNYxOh2rE0ZLOd238tIJ9n0vbpjpF16c9J7SF//Tnf0kiEt6WyeKRrHNt/yX6Y+HvweQ8vCPzJ38nAmXnx1+Of3v
# DATA IEpOn0wfzwIu/4UJlsBTfuZNv8U/DLP8dvrk8Pceoy8/O/wD/flCCJcqYHoRYy1/oMAfT7/X9EoGY9Jt34Jy+fjwH+i3bxzC8vmf
# DATA t92RmdYogpHEpjAWjaLJzu6YGTkiM62G1144hrqGnCI2E7HJQNsuZEph1PMZ3ioDPlswsczcgEGBWejzGdSl/Mo7vOOC+sKw531E
# DATA FiMbUY5kmczhdC9w3hjLuQVzdkBLrpexNX/U1VSQR+mbUVnNrbdUzcXwdpo0SzJWWUhBrWHKXhNqEkNHslyhtE4dZLmttlb1qHkc
# DATA 5Pf93oOE1ERmNXg7wP+oZMHWbfs4bkSj7AjybAqv43cwQhho1CAIyMjHAjzVywOeGygKEs7PD2dIlkfUvMVmybzm9KyIlkckwvEs
# DATA 3Rj/NGO8hlmedGh/KVyz5zasn82ovtKgfpwx/RyGdKmXc3LADOjPsP2cBeFyTlI9mofSJ2bP+WqZVJKLWOZ4ndNHtodtjLNIMSd3
# DATA XpR547N6eBQJKFD6phbWzTm+PsdtkELtrQK3TDm6ESWVDKP9ye5ubPXz9mmOjTVgUT6IhQrovRcnJpSM/GS5YZd3l2IWwhAQNGE4
# DATA 4LUlQ7uEtRPKC5RnGIXGC1nbFhpS+VY7AY2R/ZDMhv3dgGPhe2ya8Aa7buBol4526WiXZ0i7XGWIWWlKs5JNfN7m/Ums+6c27h3y
# DATA 0iEvHfLSIS8d8tIhLx3y0iEvHfLSIS8d8tIhLx3y0iEvHfLSIS8d8tIhLx3y0iEvHfLSIS8d8tIhLx3y0iEvHfLSIS+fG+RluVr1
# DATA a/WTIi+bwWar+wIhL+esPB8Xflkte9V63aN880qVYq9UrHmlRvF6tdH0Gs1euVn2Ks0M15Lubc3iMPulzYpXpoyulfJN+nvT26zn
# DATA q7V8qZQvU/i1v71RLVHYzVqvXsmXig2v2fBK5Ua+RrdU8xV6/Wa+XMtXGpkyqQWNVmeWD1ihaDc+LtWK+VrRKzdLXnFcrTS94l6j
# DATA +Xa1kg6j3m52GuXZMJpVr1YtfpwvFxv5JkWqXM2XKC8oRjXENN9sHEHWNJGb4eiVmvK6djjCbKnNxV/nSHhtLtqS1NyRgApT8e3U
# DATA mtVq9QS0PK6/mpYnTcGi5bXqtaBSWoGWV+8EKVpe0OjUNlsJLa/WrcO2NrS8SqvaLCe0vGajWioFZ07L42qfX24YsHc/45umosLZ
# DATA y0+tALRtkGKnSaJncW4qX2f9f/hDLfzyUWsI842dRfA3K5ZHU/hsyJ48eDzIXnUWspcEcwzInnZALswjO6dVhiqMnap/tseozHYa
# DATA GwNmEFuwjUCP3WqBq7iYfZfka87OqiXmxBE5YYh2Dj7n4HMOPufgcw4+5+BzDj7n4HMOPufgcw4+5+BzLxF8jtOG0wh5bfNQGl9b
# DATA NqAxgkhyiOWG5vannqGPoTfobV1Z783wnVSKN3RH9hoF8/CeTGs+8PBh40IvXcm45m8UPorCAQXwIf0HPtRlY15+uKaPnSdxKYwf
# DATA Il8/XHtj5kS6CuACPmtS1FWzQ0GHqsFPmq3kFMLdweolB6vdgeqX5ED1cfXCn+1Ba/ZLJq60WRxRL6WFuRNFHZwt9thPaI7ZMkkC
# DATA gSzR2X7W57NfhDOK/Pcpa7XPO0h+2qrt88/lz9VvX+GYfOKnNfrhgQjUobS17KSqHEZj5m5AUYijfgAhGD5aK1WNT8Ar9xsTWUQ3
# DATA MH2+PDk5noMMMtmaSWPnOSP0TOEBjrpdOKb1gWbRPUTgUtX4FdnD58cREZ+pJnIg10+sk2cjVvMsTrOa551B5QyqOWp0SYVygjVO
# DATA sOakdtRCe+1shGy4T9fNgCwp0a5gDYzdaBztjPzhriUq/sx0004BYEnj8htKhsYavY6pWSzGAAI5RcFiNfbrwbzvDzlzrDF/nvLt
# DATA qagWv8/y3tI3Um2EQgp6vjMQLn4Ttjq/aOAFDykfvXhw6vLBLFr8ziCe9PyxqJcfqOTtI6FD6sS7HvV3vd5ZyBZPWFNprLkzE9YA
# DATA z7SG031vTZSnIfHd8USEXo9zNPyd7ruY/ngrGMUsxYSVKubbiywMs43yfkgG/GRIDTI4ZTXqRtKJZixoKk4fPFhhgIjBfcoS0RnW
# DATA ZDItkyDTjkl6SGsFef0DY35Ib2NwlAkA0lZUN8tBiaI8Jgd2/VFN6CBRn5IBTU4cxQukpdoALGpdKUuXCqpALC7l3YHAdzDwGLwy
# DATA aFNBafmprqIeUN7njEJWpHpnLWmKhacDrZXEM6LRpNWCSD6XCzOJUU2iHuOLZRwQjaPRBEJens40o+Ol3JuBvMAsdvtKN3U11ONP
# DATA Z/phGRRuAuImIDMTkLSF6aYgbgqSnoIsnFg8ay1NxetgpsWuP2TYsI8Zhi2OHQdKd09LQWbEIhm1o9UhFfookMmMpfM4tgUgMVb2
# DATA 9sFPmgguJCvxKC12Qk2Z+i4qhb1gjtLjqmqbnNrhlTd5aTOJd+sgmR0xd7k1CXsdo8WnIsOOxlm3sTo8agHoNXpbVvsZWIVPysJS
# DATA FpD+MYFnmyusIrDLrBju2WRxVnav0NBtJSUNAVfvNVsIYJWqz6/Kxgj1cusO07PaT70acQ+bGH5Yg8cYS81G3ce2ZaQcudnbaYKq
# DATA DjO8xZ8W39nuhf0WRxQfFt9HHXOETVl05zX5mNx7UdJ2JYMp17amrMbbpiZGlCWGZqp0sRlYmr06I51Yzv6oY6anvPlBJqoqH9P5
# DATA kAFz8U5q0x3IzgKZ2E749qr3oG+SkY23yVQoR1au3A6Z1dQJGCZErbUiXoJ+FI97Bwp+iZ9gJRopdl6rEV5XOBjLEBiIHCZ2Sca7
# DATA kdIT9QV6rsVjGSg+MFKz1HJ5Wqzd20oK04NlpqxDdVDrfDOwfowMfJ/mxD323YejNk0XkyzEHJU6BqC47I5OzXLgKaFu4SO1RYd6
# DATA squ8SsC2Me+thNnej1p4hHq/QOo0FcWDWBbNFAWMy+I0sstqJcfMr82l+WWanGTYu5D8pHaxE5isgjeB70nnkUFwSUYWvPdpzMx5
# DATA rJIXkhF2oPxPCiJG3blQ4mS3irjDNGeehg3GuAWd08gq0/EcM6MaSzNK9WKSTW/DjyPmfDiwahW/mirEPsUyZkeMP+qp1VPtm4ET
# DATA AdvgfGjVykoXT7PxM7x/OweJvzDAEiD25As5F8Ax7vO4HUJSl9EVfNMzbZO1Y7TJ6wDRoU+jdpenROcFcmVqm32ZmptQ61RGWitv
# DATA gR8fYHFPE+HoEbL5RXqY81NskRgYL2tG/iwrWKm8eg27HlER0xjZCw7YTZDUsR79klg4yrsrDj+a3VITZE9cYqwhQ6iHZ4eVXkRV
# DATA i6JibUEdGCdyIlVHyVoRFxRohKOwPTff0gOx7K2zB2JzRbLhys1I74LTytNsgqndaXCKqJJUlGid34WjGGI/FQdEwhIbBmOgeW2U
# DATA 2H8TkJg3/Xr6yGOsF+hf3x/+p+mj6ffTJ7MYsf9n+nj6bX76HQBgh78DgOzfgAs7/Jyu/2X6A/39Ff394/TP0x+9wy8kdAT9BNCx
# DATA R9PvDv80/fbwC/r3S7wJLDJ6M4XxiEJ4pMFk308fOZrYC0CBHsjKD/bxtJVKfUKBHgbRkPmNDFjnoZ3anhiInQjK5+xtxEBjuaSV
# DATA GC7fhT46EVbnN1APEoqEPDuPl1LF3oK5xOz2wYHDidk+FNURnDdNLF0gZ4sRCwfWGu41XUv1L7MsscEYhwBNH4uvMtIFo9Pkiflj
# DATA QRTs+jENp7BgydKNul2HE1u11E6dKXbV77Wx6hjIAthBAqj2+7zTnpdAerxO4nUxlfCYC8dyf2aVAyTdfj/gyS/GEl5HDP82YPqG
# DATA 1wmD8RyM2JGVbrF1kmpLz44hdmQKHEfMje6nMbprntixB/WXYlHkvAb0Ux7PV14MOdZofk6DudRIOw+S7VbPvumcBUrMTqs4htUO
# DATA jt2InsPiQzqhSIGJpS4sLBItSfo7YLD3hrFQlThpYz9+oPaqIALhACfHcIxPZclqKDEAjGSo3gOvS8GaOgnZSaqNDOttbRMAPhVh
# DATA ox1sAqxthWQgzLELJtBdCMfz7AFlDTD4CHYAVq/iBxSYiUcI5zjXJqpfPezSxh6yyXgUSplFg3YwGsSOI+Y4Yo4jdsYcsZVGmhVP
# DATA YKxoHJ+bkX8y3+MpmPiOJuZoYo4m5mhijibmaGKOJuZoYo4m5mhijibmaGKOJuZoYo4m5mhijibmaGKOJuZoYo4m5mhijibmaGKO
# DATA JuZoYo4m5mhizw9NrF0rz5KuVqWJdbvVoPkC0cTsZefjYsRKtYpX2Wx8nK8U8yXKn0YlX6rVe/kqsFqlj0ulSr7mlaplr1Qse41y
# DATA vuHhLtxRagIDls66Tndzs9GdIYwB8FUtbnpleke14VU385t0oew16wiy5tWA8fJKCHsTr6tspoOt1ZudZncOmKtStMBc5c2aAXOV
# DATA iun60Ko2qsGcAGpVK4CKRfZqzlaJ6jwyWLlx3OetfKlUGl6F8qFc85p5+qtU6perJcojD5lb5CxenBC7FOnOaq22W2s0M6Qz88AM
# DATA 6ax+Ak4ZtwzDKeNGZnHKqB41Gv4KnDK/W0lxyrrlTqNdtzhlm/VuI+GUdZrtaquacMrKzXql3jhzTtkwGB9JKcP4ou9bAfNlOcoq
# DATA 7CYrNHl5DEPaxiwJzISsMWepmW619kuvRn/KNXY6ptBckqMSgorwak41lSrjWCub6W7m7eUq+wLZjZexbcTztAThpdOVS8VvyRCe
# DATA uk27wByyyyG7HLLLIbscssshuxyyyyG7HLLLIbscssshu14yZJeyOCwOV8c/iLdu+OPdQrcX0cQGZt+HaziMRan/FUyai+oan4/C
# DATA RflK0ywYqtRq2Pr8cG17SBO8h3BRBr0Dyo0LCPoC5Up3InJhfDysa+lcqbNWvIoEUhaQWvowl68OZ0GDDEHKsRufD2njgIo5gyV6
# DATA f46y5Y4dH/fYsTtu/FM9bnwSvNZzcAyZ3Xfa37WcsiUCVibec48qz+FrPS+Hl1+oM3xnAdxKH7c+ZdJWpjKcFLFlOVKTQ+QqpxMs
# DATA COQZRUBeqa5wdu1WrrzJE3zWldM6dFx9IBQ6UHpzchDWVJ99n55oRfs47RzsTHqQ79Oyc33IiUZdqOF3JiOuoP6or6Xv1Zl4freO
# DATA wDbZ1iEZv7xtVkdBU8Ioe7pYJG2xFucYfiKPN6eIZYKl1h6nDXp23BZworIV4MUdsskmo5YRnnxJjnpaYTi7ytlVS8Ta7MrldF2c
# DATA rstxDaoluK2z0Xv59SDaR/cvigMtf0c01iC5oQa20vnLiZ0CXYtXINQOEH0tpQ3PE326+t4AeguBkmExbjFv/cHORoYENOB1oAS0
# DATA o4Iw3ZT+nsIhUaKpS4aeTD9kedtiAX029SyyJUeMI+zlTH5cIGcvfggAfWzBliG2uNJgv35kfPXzSb+qLyQQrmZxXpztGGO7jh3l
# DATA JRFmTwlTmuCuTnRskFFHxFU9aqKqv6dwYUvjWVoSywxBSa0vobUqp4uokXNVtyhJqFRXXpW9piqeao3R1vJNLknvEu5JCmj8VczW
# DATA ixLE01GgLGaT1b5t4SOlT68QLz6avdEHvAbXk92AuUGzVkrwMBQVFx7u0ONoF9THE+qFoFUeT3Z2AvZAAxjBKxOqg4hGwFgAqsSq
# DATA 0hiFOdABABU9TeMSBhr7xlW7g4AKmfIT9sdT0UAPBgrB/o5hxEKBCsZpLCN5J+yydMpY9IdY2dlTW3kDEx+Ro4c0EUdjjjpRIknE
# DATA ssrwNCIynj+kOocBblW200/E2E2NYM7cdebuQnN3xrRxFq+zeBebsM+JwuFVVt+DZnEXg0w4YBmz+XwnzZdNpABHQT9kREdukere
# DATA m8IUnBluWNhsZxJ2gDNMBkYKjdprZwIAIQ9vWRM4DU2YETg099G4bpim2vfEQ/17zAnAeDaKaOjwx3rMZTu8Tw18AhNK2QH+zijQ
# DATA +MrZIVPpH1JIHRqqTXLgqpoZOFkaEOIy7DkKWBPO88eo0BThyza1XZMhg4e8PQrvCAE1oFxfMCMQibdoj/c3KQan5ucONcMLGzkF
# DATA FPIwGLVD7HdMQVAlw7lgWLTPEipUXrKC9xY4W9yNsjeNoV27sLn4LgaYgFgJd931YMz9LCcDpo0/zvjbcHDNRNbjww1gnyxL47aW
# DATA ozT9vU7k+5i1afaO6vuhMpkTzT0NJsIjWH+kgu7FOaZjxIbaqY0uMZNuIjD0lAcwwdRGSx5ZRjwktWBpB52w7UsJKnwmsnKmpluY
# DATA s+AhjXm9g2WpvMlHio35xfgSnc5t3umpDolMRjl4kllhvK+Ln6ePipQTAn6izNcBlPiU+KfFSOMkpZUqC96dIHjAlBC4ZZnngbzk
# DATA W1W10IqVKb4M+0+FGwK1RTiItaPYj3lS6+8MojiMZ8gcbIgdpfN9N6KOifMz6YK41RybFM0+bT0GnQon2nJzq8YA9zY7sc+ADH0D
# DATA 1Vfvg6Hm6qPqiv67nqacASX6aspZjjZL5S102TMgRV8PxzwrG1G3BSFIgUIqZg33nCIweQaw6Fs9eSc6SE5t0rh4mtU5A1D0NnVA
# DATA usWjl+oYfV0uUniLRp1TZif/1OdvFheHnhrHNhbnvwCCM/1h+ujwd9MfDv84fewdfgZEDX19TJefHH45S8b5F0bd/CtDbdJ3T79h
# DATA So5HP30+/Wr6+PAfVCj/CC4OXfvx8Pd4gl71Jf3yPb3wG+/w71OkHQum49A4LwBZmMFsRrtWGFnw/ALpkZNtqMIF7nK3tQ8o976y
# DATA qHYCVgx+AIez4ITHmpXIkFEeRMEQ3OktJ+BcD/wuv8Xhb1JzTG7v502/sQrj7NA3krSkW+S60+V5WPZWjBzmRp7qjXYPxrv908Td
# DATA 8CZbmvbsosZ3eEYA5B5vxcTtDntzZImdOu8Gk9yohTkm1zPtscZOETUd5v6l54/6amkqmXyGsbiiZ/ZQi34627Yyl6DSol4M0zoy
# DATA XeDgnsHfLK9/i42PpB09K+zN8pg74o0btI8xaGuwzfHG6pfDF3w+4/RpDtMrjdKrD9JnP0ZL9TOJNgPy+bWFsyDVmPQIITnOJkTv
# DATA v0g2MbA9sRv1NQzGKhOZ6dKAhsHO73BCmYJuiBSxYiy3o8lI2BTJ+KoTLkfZ6SXIKw5+NW6NmuKnxmDfONf16G3G7Zhu7Ex6gd4S
# DATA yUtY8Cp68TBoh0GcM/FP2MXK0doLxfUaUGfrd4PxQcoVqNLBOF3GRDMKuC2JSifIAWocoMYBak4fUHP0wLHSnGMV+/V87O+TmN9P
# DATA a307GI2D0TgYjYPROBiNg9E4GI2D0TgYjYPROBiNg9E4GI2D0TgYjYPROBiNg9E4GI2D0TgYjYPROBiNg9E4GI2D0TgYjYPRPD8w
# DATA mko1qHROCqMpdWsvFIzGLDcfl0RTKTe9SrW4y/iZctUrVStvV2rldHa0u81ibZZ/UqUEVKqN35TKlSz/pFprV5vz+CdcSulgKpub
# DATA Xrla/nelzbJXLhfpT8PbLH1cqjW9pldqlL1SrUTvqnjlzcrH5VI9X6pQGYKYU82X6nRLnr7RTVW6qUQPVP9deZMeLXsVCqHS/LgE
# DATA L3LVq9I9lXoqXdWguVkvzgJiJEJ5MuHzpVKzX6pSvuBF9SLwPJm0tjc7m357XloVeoZKMSTzQ7FrqsVawq6pbhatClyVLwdzanOn
# DATA HdTb3ROwY7giG3YMtwmLHVMtN/xa5Uh2TKvb6dZT7BiKT7PdstgxlfomByTsGOokNv3AYsfUaq1K9czZMT1qBUfCY+A0+jS51VBe
# DATA LI6LSt2sY4+de2X6t/lL29xusPmQBHk0ksbmzfBmO9lbPC8WxnVVmLN+ShaWh6VKry5/UqF5yqIxQBkeRU3vnyLXSBFnUkxhwjLy
# DATA avLHuEYl2U0YV7Y/p2St8aggGpRhJfqj/tUWJluvPCAupNWsUJbprEvPsedmxMKAHNTGQW0c1MZBbRzUxkFtHNTGQW0c1MZBbRzU
# DATA xkFtXjKojTYItbTP2sZry0Yzht/oXp9PXajHcugD53atnkqZVam2roS699pik3jjMtr5h2tXEzUvHFax5FwGlMNK0wXT1zSzxpx8
# DATA cOeG3blh6+SLOz3sTg8fdXp4odbkmZwqfh01F0pzSeDmZPEz1Z84Bb10aM3hzftB8IBPOEqbPaHWXDK2nJ7aXBD0lCp3S1ZJKEO0
# DATA +qBydJ+B7Jw+b6zAbUMq1c4I2nMezZGC3sEZaM69M8Ch5rH0sLFSyoa93E0Eqs9AfO4uu75UGskEUb051QkaO/JQv+6cge7cbTlK
# DATA DB8gmXIqyQYucCblytpzN3HW2jcCdGh5MsLBZCHzEnuhJqPglNXnlAfGSMcnmowpZYDkcKtOiDk1SxmGLmCc6kEsifpEFF4k4CGh
# DATA mjmsz71RIVHX7IwOdEYnqAa/tw9uYT9gCXncgoUqMjR6vYJ3Peya5pAD7qE32xaViuoAURl5u/TjKMCCVe9AnuTuZd+PJTqaKKTU
# DATA arkOiso7Ghu8uaJdTZMKLLHvqQCodVA0pb7swjc4UifioZNJj3ZpSFkkGaBzRR/3p25ygJPvvM2AxhOWAqCROivxkxmpbgc4DqhO
# DATA ccukVe6Qcedo2fgX/OSxQ046+z2x353F/pOz2I+LlHyGOkC8mG8WopdzJN8MWf5cwVEgej7weC/vEojkOcsHPfdyGmfBh0xEjk4b
# DATA DmnLQZ2UDGltUtDTpts4VmWqg0z8WDhFCU+VMwWJXQ1Simp3I4iNr4/kYdAAsIVOQxu3vd6kHw6iCU0RjU00oEoeQcRmGPR6kHbH
# DATA GLqrFNfJ/hoUvHdbIrdPhgk2XUNLaZdMUoU5YJ6NfrsdjbdgoPFdnBgdi5uwiygIih1VXqo1ltnFJh+fHwl4G8JBDC11P2YJdWkh
# DATA WuO5Dwnr0bL3sxvaS737LWlBMZmXMS9FF7wbUTzW9p+ICzH7R8f6MjJI2hfYS1C+of4atgGE7akboarOsiHZmPzURWKsnsHZas5W
# DATA s0cG52x9eZ2ti5mTz1LC8QYvVur6rATY+Oi1BaWEtB7DEfag3SbtJ3He5NiNwIBJdqJpx2HBu5WIAeIUjqi0GbQPlyE7DXxLP5B9
# DATA muw76IZtL6bpftt4Vlq8lSzRDBTNxRU1IDnF4vhIGr+s9SEmA3800jwhPlyC98DrM8dIVGccZ2mXap0blZQ/KT+Z8mTpHxMgornC
# DATA OQ7sSMDhyNPK/RT1elYK5hIgzeI5VxP5/KpsCVAvt+4wHaX91KsRd5iJ+w6rzxgxez29NBrCHxopay57O9kN3Kqi/cX37LDZw8gs
# DATA /rT4zhbbaayRPRIrRd95UVKV5IOMx9pbKCvQtp8PQ8MSV+FSm9HyfPqjjnHC84K/uONVDlo5kAFJ8c5g0/plKZ2r0GjCObFtEpCN
# DATA seTlkA22qxBxDEcQMkW9T8xW2Gt5pcmZE4nRPGZmWoOUhrF+1AnYjz+GPQvDT1twglKynYlwQBqpzoCFhrSRPfb+lgbcgu1fXdGX
# DATA 6pltcmxppJNiskZLmAHwiuVubkT0jOV0zdqyxyqepPIds4TuLC4hXY2lkO4M2QebLiFqxtyRiMcd2BdoZe6S/SNuUN+Tuq6sfosd
# DATA aNZA8LysgojUagT1UUw5ULrYwaislKcvGzsFz3/B3Fq1YG75ox6Lyvq9vi6YO1GXYawDGtVYM3UfkzwaQXfSc7OCt70XhZgZU94b
# DATA t37Odn1zqQypf8HkrKNmiZgePnV52BE/t/JI+t5jlsdfLy4P3YtLefw1GSwzHdmk3Z70WE0Wi4DqJKFqHHqyqlh61EvxSgLOY9OQ
# DATA UfDeptZ1kKMiJDMkCnuictznXizq90X+mYyLvrDE6KcQOWjWi5++oJIUPf/FdHvVYro9abWy/dnrLGKterNg8FF0kPRgWoyr4L0f
# DATA 0nS3M6GOfkeWoox8sl4VSiw8MLUpr9r+ROh4T10WdrSf/07szVU7sdfDUYd3DAzgAKLGMbAaz64oXu9O+mEnj4VClhhX5cGjTsyG
# DATA PaSFxrDM3/c1lzpZ57d5eyhh09tRSGQ8qW0T0EKGe+ipy2k2QScqrbT9J9sYbfvPXJG8v3Iz0hsOtQa3mPxicfPSP0MtfZqxIDt0
# DATA KauF07Nhor3QHq+EhRbvRkEKhfZ/Tf/18IvpV4d/AqsMGDP6/Pn08fQv0x/o768Yj/aNx7CzJ9PvDv80C0b7L4xRezT9jp79s0d/
# DATA cYDTJzkKcfo1fWP0Gf3vx+lj8xKbpEY3fT99jE+Ko/YXUNHwfnnvj9N/O/yjo6K9AFBus82Bt7xG432NXTVkbogXC3k1xzMj3mYV
# DATA wMTTLABAQ+FOYBkZ6gAEzoAOdAi6gSK6Uj0ejXnPGJ7ryhKWcQrA07GUnAZleTQFsfMdPs329XEXcd70tGyBnB1CjUYLvxftJIgv
# DATA 3mHIL89yuC92w6SbfjMcW/iO02OowZRW5zZQQyMZwTkbHD7t6NI6dX7aDcGAey0yLrCji+b9uzTumOllThtZcYTDUMhIGLJIJro7
# DATA tacV8xtFGn8IlZQg6ZxY5ytHNpUsR44C9iwyYVYfE+hTEQleA4PVeIattrxeLjZiMq3sWQHWlkffAdbc+H/K47+GsJ1g2H8plvfO
# DATA Z8g/9RF/pQH/GOP92Q/3UhHTSTej/PPVfM6C25ZOOA+SnCEGOmZS3TpASDk5wziayKskrmMBOsV9HwtfZunNk36pFcRwaQUjLE1y
# DATA ommgTo4tqOh1wq5hu1GyDzxFMlmR2TZS5hpvq8GRFTIo2C8RtB9gbFJoMq5jwr3iU8O8E0hoc2HMe6jisdC4eGk2iMdiKiBfEsvh
# DATA sqKYgZ41nlAIfX8w6eLzyDYSlOcVfgK2aUYH+WjgkG0O2eaQbWeIbFthdFlporOKSXyOdv1JzPqnteoduM2B2xy4zYHbHLjNgdsc
# DATA uM2B2xy4zYHbHLjNgdscuM2B2xy4zYHbHLjNgdscuM2B2xy4zYHbHLjNgdscuM2B2xy4zYHbnhtwW6lWaVeKJwW31br1oPsCgdvS
# DATA a87HpbeRrepVqs2P67V8pe41K/lSpdyjf8plr1nzSkX6peKVyvSpni9XevVNr1b3NoteufFxpUpXvUrNq5bfLpU2P84385WGVy7l
# DATA a5ksDTa75U4rAz0rNar1SnUe9GxztuTKRa9arO3WGuW9Sv1t+pp+gQkrTWErUwrK9ZrXKOVLzX6+2vCqTa9RzJca9KXqVetevUlf
# DATA Vo5YqTITs1oJkLjGx/kKFWoeeVG/QQEgtr0KXUjR4ngnZ/plQbdRX4C5UxW4HY74hN1DqfTlBP1WajBIjlUN6ukWYIKlAGDYePJ0
# DATA EVnrycPNZrrad7v8Xfe/LIfK4q+VJtUbCuOY2DhuRhobJy3SwsYFtWa1Vktj4+imarmewsZlQHKCjdvsbCbYuGq7Xqs1Emxcp91u
# DATA dRNs3GanslkMzhwbh/Z3NDauoo0CMQn0Mwv4cUhmxr9Y+6VXpT8V+lOv/dIOIsOLe6dPU4lxDluBEV/vJit20Fc75vY0qVYsXs46
# DATA 88Tdk2vu7ed4lWzBipiKBuBVw09WXSooVK288CqjdDCe3k+RMkjMfAm7qrWLT3s500w7lUll+lOqaZOffUXhmCysdgpkp33Y1C+X
# DATA Z/BzxcV8OZP7OTsHlpgiRySQrQTHkXMcOceRcxw5x5FzHDnHkXMcOceRcxw5x5FzHLmXjCOnLI50BxAOKPwt2Hsfrkmbo4RfkO9Q
# DATA hOFsYBPzw7W7/ggqtPyIJzejeV3gC1Qt3sRmuvXSxgXKjXa/8CH9N9i2Tolfey99DI8fvuGPdws8Q1/ncH5VKtQQQnK8b86h8UT5
# DATA FlJcptvXqLnk2Io7RO0OUa9yiNo+2uTOUruz1Ev0kp/tGWs5GpzTZ33nnLS+bc4FSh3JpZXVzKFeObCqBFn4LDHs6H2lwywneQNW
# DATA 2U8OTw79A0ym5fAktFYG1snJlTWQ3xTV45YwojogUOHVvunQ0RE43eNVdI/bfjzxlWwaPi2+E10qZS1ufV8+Lr6XOthOFHFGvysf
# DATA XwQF5CQvjimCeHWxCKLOVRFBJKNsdNCBDpE/2PPjRAERJyepeUFBvB2x22QyHOLcMzYa4DCaNxJZyBh4DjnMzl4wampBwaNWHeLo
# DATA cEZHh8fDzugg5wV+fMAN5el1DzNpODeJSqv+nZ5iqKnJSqcatsNoAjMyKZv2JN6lmhuwSC7OoMsRal/kqtnMSYwIWJWwSwTDgILa
# DATA BfcOXUSiTK30HPh4+AT1A/7SlmaePJU6dZKAF6Bg3l+5YG5TVc/DrXIADXBLOZQPNueoRIYBtx5uNrqBMEgGBUf9ERqO1g3FOUIo
# DATA VkExPBiybYgMt9Q0RHAAa1syvoW93WjC0qNPr++aSsq5ldKJO7frq3ZuN0LsnIGGx2RkKSPTBIXmfNgVOI6Guul0w1Ef4qSToacK
# DATA JhqxBBv/Kuol+5SoUdSS7m4U4Cvrhk0Gu2RUQd3AlvF4miJJxfzcSsQaJI9ZJHcXF4kZbqVM7o78sCd6KT6ZNaZQ6PsYxgnst0hy
# DATA uEPTHhh5qJqGhjnyVXNQmtWACWulmURJIhF7ExGW3oGovT11waSj//y3lTurtpX3ZU5KE9RwSFXYFAxqNyxnmrrLFiEY1jyM83QU
# DATA qh7DmMd7TPPBo8XGXIXMikUzXImEj1nUGqULz+lTF0Umxi+v1vFPQU5EP+68W867tYp3y65izrvlvFsre7EWOsHOxrvFwlsGgOd7
# DATA O1Ekonjat/Xc6tcu833hSINne8BmnFpCN8WGEbUPWV9LeZvU8gyjmQbYf88TVbVQut7ubyi3l26YMilFKUqo5nnTlSVXjOunzLtr
# DATA R+i50Yv1QzaQyrytuu/zlle9kTcY8tbrQmmxg4xXkFDLI1WuQ6NalvaTqRtNzPSDM66pkiL0wu7pXPJKXru/2I9VKtTYgUCBhcGI
# DATA 7i7UUvfP+LKUhWUchbLphoK4puULM72sZSah/CgKfLhIp0p2X9mmS3JJmngo5tmQxsOxbEi/KEE8pQEkRgoGI6u92WqWd0fifhVi
# DATA LPqBGZXoHus1DrSXNiczBrbh2Cvi7/ih7LrClnjBSNHsoeAZyF1STwseF1qOBz8LyMLilUmQ0KuMtXWM18GaGoYDwVghTLKIjQQh
# DATA FhRZQQ2HxiDp2DqQ5inCfD4UKO1VxHiyA34t7xRI1jDVtHWgJShZrzKRnZywhXrgme0Cek/ckG0YjZdFVv/kDc9kqHGmpzM9VzE9
# DATA na3507U1F1qHz6FaNZ/oMKcLZs2wnmWGvgWzk2MFCvkokGXCWFuhyUMsu8Sd7/Onbv38S77y33JO58qr1INmG5Y+FohwzRGuppzw
# DATA s84sygW/x9+yItzZ43rSTNsRJgvyroNBW8xvo3915d2Z0368g48KcUbc3HqKv3BaVhAWT46taHssAwff9w94+gI9Z2OYXeUlO5kc
# DATA DcyiIPyJOxTS8ECWF2XuBBrh0N/juUvBu83LWWNtQal7lH2GWgmXsTjj2ODJrnX5WA8nK03TOlaqBNnKdO3hsIdQ4/Ahtq7LMqRU
# DATA 73OHe5y78ZRgyqhC7QW9nQl1Fzas7F8Ovzj8HWPJQBB7wp+/A7qMsWF/BlEMvxx+MUsp+9/Mj59Pv50+AYrs3/jCnw+/mH6HSzlv
# DATA +vX0EaPIfofvuIFfd/gH+gMQ2Vf0OoDMntDPjxhl9i0F8AN+O/yMgvkWsLLDzzwK4xFd+AMuAo3m2GUvhHWItPHUC/4QlivXtfcS
# DATA iKT+6AFW+fxBkIPbg2alI547Dn2Z/mCQoRkqjkrzGhL0MrzJgANjbfJJ2GM2KrVon3dz0sTSHwskNcBWferMllLLBCYdyEDpoGW2
# DATA rWh1GOeNLsuUytmRyzqhnMOMzZ1vqCtcUWfoZRj3zJ1U6aQmjk4ZXsbz/DDmDQhoDrwzTEfVEcxWK7VTp5jpzqYb8nN+T5xKcXs3
# DATA 6Exkm0hP2PGQ/GCQM/diHqu9eqVavh8OYGv7Parc2EdyWXt6GZ0hVtgooIAFpBAO0AWLGagsI2mTPYNvXrVqLjZx0k3tWeHLlkbe
# DATA 0cucBXBqFoDmlh1/4H8pHETnOeif9pi/0pB/zBH/zAd8qY+pxNv0suei+ZwFtyyVYi+QOXosHimmcHtRN71vj7NhvEux3OF1EzS6
# DATA EPs0jWXEiKO+P+SEy2vRR8m5AaqdoC5hqUUjk2S/Jo+4Uu89I84Wr4gt45xTlcKj7JjgdTLgAwgi7rJ9bRhQEcSIpdfBgR+8/MEg
# DATA 2pfTER21uRTYqGHARb0bTUZgfzGDKmyFPWQVrDsGrdB4xLgpGAuigcB4LnOGQIGcBtF8+JTjmDmOmeOYnSHHbMWRZqUpzwr28fmZ
# DATA +Cex8J/SwHcgMwcycyAzBzJzIDMHMnMgMwcycyAzBzJzIDMHMnMgMwcycyAzBzJzIDMHMnMgMwcycyAzBzJzIDMHMnMgMwcycyAz
# DATA BzJ7bkBm5Wa11iifFGTW7frd4gsEMkutOB+XY1anPClWd+v15l5ls/p2PYsgKwf1dnc2J4slysrqbq3Z4M8VQMbU5yplLH9uNr0S
# DATA 5XClWuyXmsU8/as+l/TnDNSLcr7TLc+DepWbM1Eo1ygKxfLHpUbRK5WAYPPKpeK4BLdx8yh8WKPmN9pz31Srz+DQSo0auGRepZzf
# DATA rHqlehUQtFKNMq5UYfJbdfOI17Ur9dZ8WpkFUctjOuBDoF9qtLc5B2RGcUlAZhQpAzITHFvSAqqVbqO8cv7W57yqXGwkr6qUSmf4
# DATA qooQ2eRV5XrjDF9VK9upahbP8FV1RtHpVFVOOQOPBZXjLk1D5aR3tKBy1XK90uykoXJZhNxcqFxQChqdWgKVq3XqQbNioHLtejto
# DATA W1C5Cr23WT9zqJzsLszLMoMe5io8g/D06pSxXZpi/tnPZKFwbwXUmYd+bpb+Vp1Hf4P/s7G3n6uL/1OF3PdXg7wVGsvcmnp6lgSa
# DATA XSCxzXtdPjOeTVUyqXBY3GKB6+sXrSZ1YJ200+t4dpjH7losVS0Gw1lZtcSem4lzelp0htahY8w5xpxjzDnGnGPMOcacY8w5xpxj
# DATA zDnGnGPMOcbcS8aYQ10IxzTDH/nQYqcKdtlg57aufGLmJMN4i+uJ9FJ8fhlX71ktXxr+1hXT7MPu+s/4UdVwNz5RXDqtXAQxVDnz
# DATA xYijIXfVYlxe/lRe3ZnI2vOWHdCvBHeHSwkCj7l0sqRj35svbfyqVLtQqiE6OrQrEkBrQvNFFKqJGcvNsgLtIAg6MXh3+hlA8kSG
# DATA IDbaS91gXzqQoZzKE7EvusQnGFPJQUbjFOOWNutHeLFklSw+rfOEbqMgiw/r635uLxdSIfgXlKG9t/Gr9ZCaRvG1evFSaSNXxKYv
# DATA bvVYf9rqb11Z71/ZKlWrxdc+XLtJVZKPWHKoyCBl+HA+dXsRzVn7F+vFjV+Wqxs0A+uwntV6OffhWhF382P6mf4v6cbZmy4nNUey
# DATA HDVgPeZYq6oD59EWx28dqWfU4P/47J+RsfFlXLmwNa8w18NX04X4Wql2qahzk0O9/OlG4aMoHNCzDC6USKuPF+a8shsOwnhXiaKW
# DATA arowcVpWHC4CQHxvAJUJwQHgeYYermcqTF7Xig27WlDj4XpksmWDInmZC5xKIq9nFfT8a8tMRm55aDxJOJ9gHCRjSB061soZWtxC
# DATA h6zZirrSmXkXBa7PQxfGD9HPWHGUsO/oMPVDNOAiLINp1AfRnFKEU4pYrhRhHVN0ehFOL+LYehELdUrPREfi1mScNADetaU1PWVk
# DATA N6ISz6OM0Xno2IuxIjLuI7FiMsr1uJTo1uv7TedlLhih9+LmJbVgroTrF+jRqwGXFenHOFnOPCQj7L2uRt6jlPRNMCZKyZVESb9a
# DATA nCelX7Gl9Bvloq2lX6otltK3DBpEnyNOExOaVXG1Ssvpp2628s0OYkYtn2N2pVLU9sdiXf0qx7NaO/rOOodZnxPmjPa+PsBI6eaD
# DATA iFeUUSzMILQculV+UTmTMKEwaeA0pctNOz6ymZAqpxvJeMZDoUxArliXMwVyOq+9jXGTW7z91uTq2bxUDj56NNCOqJtIvTn9U4L3
# DATA TMplIR1BejKFCXhxkQjX4d8TqRtlrGhL3lbOMBozHZrQWXZ/qpNnMwjCH6lblAAvVWHWnoHkDOtpMNyAxRw0g2CRBk1adMamgs3y
# DATA v+ZzwiQDU/MHjIR6hYJ9W3oIsiFgR/INXnxxi7SF4eYlbl5yxLwkZX+6qYmbmhw943imEncY41HBdSSQOb1E5e5NMxER4AFrPpm2
# DATA RqXnxyxyBcEp1hwzIlQ5UU7r++K4NEJoWqwhO7nIoBewzcbGfguP1jbAhK/5vgjPBUKYhasU7ZsSQxU6NlMaZnRR9sQfTxDNHf5t
# DATA Eh/QmDtgphclUDqLnIIQyfRID7QMpOfuIn6gAx3uRuNoZ+QPeageBjCklbxvOGLpMUlietgb+4xVvhGNRFlXjXVZuKkgki3LT1Ir
# DATA 5oiFQ+OODH3bvsIgY5ug6tjEd4/VqX2gyKEPty38NMFK7Po2XhQechAGWGoNvr1lsQ87bNUtjXzWeJQUGKSAQIRjQxCGiv/YgJ7b
# DATA LAin8BdakzhR1hOWbVp7TxVLC1228AmsXtuX+rskTdvYYT+IQG7NJkvMhDQ3dkZV0VRkMgtvwb2v3ox8JbNtFwRfhWyQLOAfAOxF
# DATA 5LGW3GbZNhg1OVSigSQFzDt4b6NJrPJDBRxSPmzvRWGHJalZpQ0ABclSGqAiJsb2IbU25JNuvDtl/pSeY/1roYkoB7hMynScsaCe
# DATA Eq6OujILgw5dvx91pHGj8PiyKStPH56Lul341HXZaQ1rKcOcN5y0yEKxnmP9OW6EfgcWkDfiOiyVlcYuhhfzKz2Q2GnQIUs7pja5
# DATA LIl3gAZXcK8xBhEriSCUyQupZwih7UXdHaV1SM93J73egeKtqJiyGyfmiirp7qdIhawsKH3C/m6k1BGpg8ROUCri0S7aoRQY+vgs
# DATA olYM05+ePe1oYc6WXlkN2pnOP2nT+bissGesDm3v+V8OC7uLkUDDLtmokvq+nBb2/KhJvxCSqkcRJJJ9/5rldZpQsbRC9mkzxbKK
# DATA 43ORYsr9xmreKFTehUZGkNSIWMyaqGe7Q4Oh7sSu3GTtEuGK0VSF9Yll0kTvo99xz5thYjmj94Bk9gB2udDIqN4k98rMBDat7E6P
# DATA YOGFkCI7UDddjHqLmqfYy7BzUX15auHPczAuxYTAFWtIzjP647DAWIZ4OEKNjgPTzETB2TfTVdlmQ4Z9H3eRnZvytpLNDdFiWwud
# DATA LW2eQkpOTViUXBu4M+tsM7beT83KS7Bm+0FLiV/bVLP/PH08/df84e+nPzJl7Mn0h+mfmS5Gnw7/7vCz6SObMHb4Ba7MAs7+Ky5P
# DATA v6KHHzOi7LFHXx7RxSd0+QeQyaZfeXzP18w4+we57/BLBTJ7BJIaveAL+vdLBTLj+DxCnA7/Hgw05p39efoj/UD3f+PYZi+KLSuN
# DATA HA1Pi6/zkpUhb2IdiOZwoi7Ok7eIghuj1SOO1Mrfg8oiM+TFexTtsZfHHyVeJYuEiOaxFGX2djYaDmdm27RJR3HeNLM5BXN2RDPx
# DATA qcQzL1fXs7fLDgJz9+0gphGoLQM2F9Ipo83EvSR6/nCtyMIfUwsc2Gylwjt1rtm2Z+mdJzMDUwN40RhCOpMeUzhaB/gbpymUew7U
# DATA E4mg2DlXb71H94umeU5zKvR+FwMxYftnD/Bijy72ZnhmK9bMxTbObLN7VnSzFZPiOGfOGjipNaCxZiczAl4Kp9Y5GgBnMf6vNPwf
# DATA b/Q/x8Ff6udMTlios2fSgs6CbDaTSKabUVbFs9EC40yWlT2qnqiplwT0lPPevnv31p2cOliqVoa5ZHjP6IjsB17Z4WRghIZTIqEp
# DATA jVRZas+DzlM95q6KNzNVwaO8hjJY2gBAysI2MGeJEZAGnA1HQQe+kbRRYBsDOW6m6Cw8GBiDtjIP2CoAh0rMQ0FOcfxjek1CN2On
# DATA SnwQ81FKdU/L8c0c38zxzc6Ub7baWLPSxOdYBvL5WvwnMfhPzd532DOHPXPYM4c9c9gzhz1z2DOHPXPYM4c9c9gzhz1z2DOHPXPY
# DATA M4c9c9gzhz1z2DOHPXPYM4c9c9gzhz1z2DOHPXPYM4c9e36wZ5vVzXr9pNizSrfRbb1A2LOZ9eeV0GecuSrzmBImtK1qOXVYrFQv
# DATA p3O9IiwnyfZmKuM6zaAWdDP4pkqzVhNUVxbfVJUstuIh75Z4CPsqiUcle2itnESjmsXWzeOF1S1eWGmzaRhUKULaL6qdZqlRma05
# DATA zSpVneau1DkreX69tdn25/LTliWvLKS0M0pe2aJ5rZw8eujUklcRxtcZJa+inj5W8uihp0pepVx+LhpJpdI8u0ZSqZeeopFUmsWn
# DATA biR28k69kaSSd+xGguQ9bSOxk3fqjSSVvGM3EiTvaRtJrdR8LhpJrVI9u0ZCsXiKRlJr1J+6kdjJO/VGkkresRsJkve0jcRO3qk3
# DATA klTyjt1IkLyTNRIb2FpsetVaba9a361sVvfy1Xo/X9qse9X6XuUogOriRnASGiZbuoaGyUazRcOstOrlZu0kNMxi4HdLFg2zUg+a
# DATA VUPDbLXbnU7bomGWavLz2dIw1WZemd1Zzh617Gb4mDxhJxPddqpt8hr7nG0TqVAxf529J7tVYXbJrMlLZoUmtsrIolkqVLVgvjTk
# DATA Oq+epR/Ts8D5mw2Tu2k2uTPy+6k1uqOSq56Zszw/e4NeqZ/J89m7Ey/ioh2S8qKSFJG4AmYCwVLDLOpTVbv0csHm5iY8MMeDd7LH
# DATA aE6q2G0443ue3S60kPvpaJ2O1ulonY7W6WidjtbpaJ2O1ulonY7W6WidjtbpaJ2nQOucRXPuhC0FUMTqHExPBcfUDCq6crFUrDZr
# DATA jfrl1JxFPcaHh/GYRhySYT4Z4sqFEp4sVy8rNuY1dYwd+gGD8W7vwHCuGJFIMaF69Sb296+XGYv4Vvi6IBWv45y5nFIe9iaxB8Fm
# DATA T72In1VRWvT8tleu/dK8LRHakXkp5cFewKjOdYrDr7DGvzEvJJtlaJ0zdYIwThAmJQgze+jYqcM4dZiTq8MsVFI+S9UY3VlDDkLa
# DATA C4qLlRyw0YZ33lgSMs+Pjtl5AA1lqGTQhwxkrMLBV48ACeonU918nEK2wY0wFyRYsjiCfFNR32lwgotpgmY4B0tQfUbYLFgyxKCo
# DATA k+Ct/zp8/SggohWcSYp9zaSmdnRaysdIhlgb6AHgFRWTYP3G0fHVz5nImgtWTFfL9BVjqu0gbqcQSoTkSGK3UNc1DIOjqksSSAKe
# DATA TC6ZqDeOinl9SawXQv5MF6CnTDweqkJ+4aF/80h/xkIMTO+HnonqmLA8uHl0jLwObAMuUr/PcwBenmFBGDXXbNOkitWiGWqCvZE0
# DATA vcl5+7tU+cg4HO0EVmgqd7td6mtbkxF8G3iOJlejAApN4VgL/Ch/tcw8YpblZiUmqlIHYiCzDqZdzwre1ajPbjHq+nJKrGfQMfpP
# DATA ieiSmsx15Al/pHSRElsmgcz2KV6TEftWlfjQCtTAn5pSjGOeuInAgomAs/lfCpv/uKST50Up0t4psRx58lbII6aoJfJ6NETiBqza
# DATA Q22rHyxlnzw7eckXS13tKHXpzB6PswCfzAponjb8ZJ4O6VwASqrs9JYYqcjzAH9vwp7XJsLcO1jVc+kdr4tpbQyNY8p9K/If4ypD
# DATA FhwESEQ0Pv2xlLkyN1fBYd5Jpt0ar/j23RvXc97VO3dyahyW9sLDgtJyB8RS5kUitDiESqivlVRZqZFKwch+hnEyb9BgO27g4RjD
# DATA 9hKi4h3pDGTD23JY5LYVCVWJdYq2oQQ6UPKoHDtOECWsE4DmFwzaUAQdBBQ/pceao9pL1XVXL7OJPGtalXUpmjPdgRwRdS04K9a0
# DATA jraCKbLBrQ4YBuLPEBgpzH7RvmcDenSgJDFVLAveLc2pQcx5dUx3ZL7X9cPeZLSMZnlbgsHC1SKe5Utkgdv9tbPBnQ0+1wZXlcR5
# DATA 4p0nPmXdLTTenx/9dq7TGKkTnLPviafQeODFVxPG2LgX8SCZFh/XLvQs/WwyBE6w4P0Ge8QPDKKF7uhM2hCR6WMsNtLGxt/ORGO2
# DATA d1YWck90C6R54uuVV7XhdwfHvLlhQ78iVgBsmXGovuDVi8ZKHEvvPR7howhz41VtcdaTvTGKaAymhr0794b3ZEzvgtq84Jb3YbIh
# DATA laLFzWLTuPUi3nlRv18Go2w0lKGqDDhj8fCbOlfeUJsTuQbnPAwrXer7Iyozxn5SVRt3+E41RuQ8GYxzWmobnDtgiuNdCbejorUg
# DATA Hjf8AdWpjm0LmshsJxL4md8lCrbpZuwvKtFRAPFuXjzQltfREflNOBpPoKjOUuJWHFQBs5nHtZUl5blPGUU9E5l3h6yoYm6gSh6M
# DATA WSV9yIMnZVCvp6t6bMXnoiqoi6rSLeDSL8d+39F2XpL3YvL5nT4N+nqWk7B9tJK4IrXHu9Gk1+F2KebsAJYfNp5jaiXq6lLABY/t
# DATA S7KAe9FBn4Mg+xw8ax/i8JYMPVj0H0UtHjiVxPxkwCxEFdIyIPgg2ld65dp09se7Ovrvj1jOnuq9x+Im4uzm9RbtN2anM1njFIyv
# DATA vc3opaiz43vwAzNSExsXSChAFvXtPDECqX4ABzsN58FA39tRrMdkbXBZYm6IK1qlxxfxfPjVjXtfedYRMb2ekXAVdoPeUPVnsuBp
# DATA 9UUsg08DZZSCKgwD/wFKWHpM1D2sWXaCPl5gz7AUWIFCkfkgY+HRCuypmbJjbPC5Wf9E/Qz7KzLEf1q2/aef3vv0w8HaK3/1U/+P
# DATA sj7o3UeHEQ4mgKoOD079HVi7rFerf6XWjTP/loq1Wvmvisl/f1UslRrF+l95xfPIgAnaHL3+r17O/37+85/fngghok0dSNjhcQaV
# DATA Yi3mvch5xn4kFcS7ev0d6jV4mZPad9Tr8BI+PVCgsF4RqRSybXf4sI3+/hHZh/pzFL/Coxc6/V7Y8tTlW/RV3zIyD8aTlvLP6Cs4
# DATA koXhQH+fkOnyyivv396+devabWygXltbe4XP2LyiNlh2ZV81O5vWaTLZCS5147UN3s2IkyFrYPBdpF7xIqi+F9u9kGYwa5dfka3W
# DATA 3biAfICb787BoL2Oh3LeGs3Xm2vWDtQ1dgrlEXo+ya21jQ3tXyoED8Pxemnj8ivZfZ/pqPE5svvqIXoD9Y77A35zElDQRm7lvA9U
# DATA ZOa/+17uFc/zPhnLKZJLJd7ukOv7D1+fdLH3sVSvNKu5B2Rl3gl3Bn7v0tqdd9769TvXr6/l4nEnjC59sEbXaXhYy60NwyH+Ud/v
# DATA fbqhskdtTA1GIxp6fvtbvVE15gDtC7xYLhtfF2eJ7CHeSp3W0s93MBaMI3WsQuW/jgY/+BoX1AG/BAej8PqfyeGhQhjf8bvBO2QX
# DATA 7eCQAm4vIL+uYiV7A3dmrnmvesV5l6/waZu5adBXVFz3Ycisq/hm30j3J6e2skF5n76CSvzKKzSFhpvyPtON1sNBPKRR+L4UOk/+
# DATA Ny6hiJEFvIKOS7AB+EOBrYkYU6j1tfzaBn7oBYN1eZASUiuVcQ1PjoIC9hPwNuL10doH2/n/4Of/tpjfvF+4eOl/yt+7sJZ+If4b
# DATA +ZjK/QYJu4biX197Z7CH0z5WT8LPrG3wM2og3uKWnkrMhk6E3MKVZZ1q/vg+TupSTKverzxs6FX/LI8Dh+sFD9tk68YykVQxgL05
# DATA 6qA3QH9U4N0P6+qdqDr3sb96fWMjlacxxXTsD9qoivx4zsPpAZOd6uoGVTuvtFLuqKmuwpgGIxU7fX1Lx/OD4j35Qd+IPd9yEx9K
# DATA XHunQ8Wyph4PBnvhKBr01d5w+z6aznXDHbr3k0835Mq1wZ4cCbKTmq0Efr5LNeDeJ/Xqp3SzicWGrjRW1lgvz2SP9cuGajxPk0k4
# DATA DS0HXPgrJuvSaYQDOweSV8wWI9+fw9FbjuQa2Xl4WoLhC6PshYfFYubS1prasyLXkvfNT9Z7g3gyxHBFswsrmipR+I9Pe96nlElP
# DATA wTsG1+k1Oa+0kU3M/NZ6/57VbO/9ip7EqdWjYqYz3K4+9JwVM87yAg2PwaCjDqCa9jrpr6OQcUuBJhvUvfE5P5Q91iEoe/hplHy5
# DATA Vl+h+V6zojGvCf8Ca0twbHh9xfF6I2o/wOka/EOVjx4cHfD0KSfz5TbXR5xkQMGhUxaYHpn+BRUkdmBR36toebBlMKdlep9aJLos
# DATA 9DO4pPTMHz5olgzFdDHe9bH/Spqr6f22KLKDgC+KI0uZLoW7AWwXf3TwBgsLRqMDFrYLH26t0YsHfnuCA+VmJEfnTVPVjr45yUAq
# DATA tfvKiuFe1dyy4V301uyaZh7RPvMI3UkUF0AIW9fh5HDl3fvv33735vW/8X4r367evrZ9V3+59u+vXs95xQhIDxMmp45+7nY4tOQV
# DATA 1D3tS+SpuQV+P10b5ZoaKNEOCx9Rwa2rKnOBm2bykrGdcM5oxVPbsqzEAhXY+gep2/DfWodrCbpLeQqf8uLexUeT64Uk17dw2AvW
# DATA ZQF/VWlA2g0e5maDzudVleDQdX91CU+bb/w2Y07Ly2mane+MouHWNiyueeHGeomG7NOtQUTv2c9j5hsCJBNLKFRyeZTcGvdopiA3
# DATA 5gaIWFIVwZPa5tWh6FaD7zBT9ICPn/FFGdjpYO/l4CwYT0bBfdlCuXV3NFEHr/VHsT63KsWcrJvy9Y10QVotRhWqNqLgpxqup29f
# DATA bbjSYWZ6wIUtdLVuki0xL2Sf2NjuJcW+UBZ9tj5a1Y+NMsl0fzz227t2XO/Nltq8/1bN89LSTFcn89IG9ur5/WHnk1KuJpYB29Cw
# DATA OwfjdfVN2cmXjpG31iRTIjWTvSwHkLzE/NrFlo9epnugaJuMnY3GkiIa9aV8aBhrB+ni8SSbtqyn37j2m5vvXb9+ZMnRkzRLmvdk
# DATA Ul41XVxvQsBhQ80AMBKtq2rMkyL03HqGXdge7bBX/xb/oopObsNZvvu++p3mAHlldFOa9N4Lq2IseoZN+LlP0G2wxdSD/A8ejVUk
# DATA Uh02n9tYTyYzuK+g4pPz5BtPMJQ1+xAYTu8a/wMhVhPQL9SIf/GN1z2edsaMBlVdre2wLnjvYtD2PUb3eNi9NICXsu3R+OQPyajJ
# DATA GCJ32Ll/DbOwtZsR9nEnNbJtfOgtvt4NR/2gs4Yyoop2/z7Mgftkv215a/fvo8Tu31+TSEvxPaeuxBFOsfeDs3D7reb/K5frtXLW
# DATA /1cslirO/3ce//3iZxcn8ehiKxxcJNPBGx6Md6NB5ZWf//znLNwhvFosvsjCGNYYsOKL5YpoGGjord7AdVubUR7Ptno96haWeAWx
# DATA TFGv6m/Y06Q/7/oxfIP6awh9sJHlBDy5P1FWEM3X3ck47JlvPIcw3+LeEi+kP7KdkFmn5Hh3JAQ8c4EaWcpjyVGejHoUY+k5dbzp
# DATA Gk/+qGPhxRNPZu8TyWsZMpPRUw0LlMnbdgcHk5rmPF7rgMvFlAZb6lhGGQUfBWr9Dxkis86YC0sGHewFW6cZTpw4faSTnBMdfZt6
# DATA lBV4UBr6ORm3LZ8Lz1X4DsvvwvNH7O1c471Qaxs6PJkfDNnjqSbv2KuzJZMQeccYZ1rGehrEQetJqvxUCOP78UEfW13WLZOQk7k2
# DATA /T+nj73p19NH03+bPjn8/PCP06/o8+Pp997h39GHb6bfeYd/P318+Bld+9o7/Hz6ZPo93fLj9Du6HT98Pv328IvDf6Sf+Onv8PWS
# DATA hykAjHKJgRrZVHTkyGKhD3t8Xb7Eynzjqej9yDbaeNVzS7s6uovcGQFZDZLPnUl/GOvfggGWKO/7cTsMxbTAbjEMk1tlPc8Sd0on
# DATA x/NaFmZSc9X+A7T8oZmgFpIZKlkFFPutVIrmDP2YGLZ3qcjWET6KbuHMETfQjBFRTlcGrLjvY2K4xZPClWaUyLSNeT93exNoxqR+
# DATA QhywoXhd30NpH0TaGajuGAWMDNPyUlKstneG7uH8+xmZATSXSkfOTM7vdzvW3DuVfWoCfvsNewL+xju3r129++7tv0lHeWZCnEqH
# DATA /bb0c3OtZfUsA93nPDvzjCQWDa3A9TXmTMlMtuiOyYCbHP+o2rOsAitXknFgw4+ktNPgLKoscE2vv3YpcXPdS33L3/ukmKuXPrV+
# DATA 33jtw8LGBXXh3iflXL2CGYv9aqsX+G/Tb6m1/3dq079Df/AXauDfU4v/wZv+Kzf86b9RD/Aj/fgj3YjG/yhH1+jKZ3TtkTd9gju+
# DATA oM9PjMOZez5x6fUgXLKuM4GGFLN38T76fN1Y4dyyslJNvjJeRhXwB2vY2xlfungRXY3KVxMAWjZN8cOL9K61e/PzuVgrzmTD/zr9
# DATA C3o66tQeoa+j/k+SRymlPOEektL/BL+h//sDZ8b3yC/6Ov1h+gP1gI+NVxrY+jjr18ytpTzPJe/VLeUt5ts38L18VPkgNk9QOk/w
# DATA Yrz/K0Tz0arRT3p06foPvzz8HXpxU3hqNm/5mtlPIr5mjqjtiRuzmg7/OzONpnTKD6oSpNZmTBlmWk8qyA+al+7ZwencOpCptu1V
# DATA nVeUJy7Ib6xJuFblyTbJD/7jxXsXNtapMV5M2l7h/v+cp6u/2rj42ppyy844siVAbLgbQH5ph92+lLufrBUwBS8U1j6VvbrJT/zI
# DATA B+V7uiZRrm0ckfRsei+lmrZUHj6jkU/qjsfPoTEf/tP0+1zSA+jWzi3/Ed38CAHRbdQzTL9CH6D6Bwpc5/V3h3+iGvYjqidqLn3/
# DATA 0spVkRyc15IlraV7aMk63XYW4slwoCrq8kw4oi1whnxHTYuK3ONEfa1sG4rx4Z/IqLFjrFxGakkAGoR2bye/zuvmJFnH6+mO1fRN
# DATA sS5PrkoKel1x1h3RE/Pd+MYrT3QLGiNXTFUCeMp0sKjLVC1xnRcq6Db+d2trtofu6h/VzfHsoPRfJRmHX8wptR8Ov6A84WqMYekv
# DATA XLf+JO12/vjFo9Pl1G9UjSnDHktGIuiZKnv4J0/uwEVTE1Rxc7TnlTbNJ9fH0YNgkC7fxUvN1F18WFj+nXoFO8isBS8x/wI9O6Vs
# DATA +9Y7+aQxrlAhVIrW17Zv3bp/693bd7cqxVLxw8Htazdubr+//Ztr929t37x2/f57t69vKeAMG8P7/l5wqQKFhsFaqhWuJU9SZO7f
# DATA fffX127ysgInQizvd27evXb75vb1+3/9/t37d65dvX3tLt+iZqoFvvX+bvBwvQJjPR3+h4O7t9+7c/f+rdvv/vu/2Sp9OLixffs/
# DATA vL598/71a29tX/2b+9ffufnr+9dubr9+/dobW6wKy0sqUlqYbmatsHklxF515evFdEaJ0GoDjQdvOPeUVUHf6rVapTZTRP8ifWfS
# DATA 2UjVPPyj1DCqwRQWfpTn04WSvEDHXrbusuNtlVQoi/ADU5lgLJaXWINUozAgUpRhJHxLFecHivdj9DnfH36pjEH1yyPtFZlj+Kn4
# DATA Wotx68la+qW0qfHJp7PL2ubmZYv5XBof3EvZ51iknr9AzYvNbSMkt2zJOYneB/TUPZad4+cWdvl6A+p9tSy2bq2CDYNgFNMcZy8Y
# DATA jUKawq+tJQ4M0Xtkf4VeY42wBzhsyxEAVpowu1t1H+q1Amz1FdcFGylw3G5lcw3bU2dz7qa85wbWu4xBKgFgRKZn1tIzHhVv9oOZ
# DATA Lz+bvXdm5PqaO1kal6jmUJ/zWKr8P03/mXtWXEJfi674L/A8UFMgAwSB5vXdh/+Y6qpTwzEXgsSBr6r8i2fzQaX4TjDGYnc8JzNi
# DATA qUuqJqrGpAOcHZc9Nhp/YLvmG0QO1kNmUPlBJQj/0He1Yg8zE+2IGjzZFzTA4SEKDqMVMuxxUiTz811twFgct1VyXg0F31Jc/lHG
# DATA DRWJmWTJCJwtAGWK60hsoOaUZiZqAzi4QujjmhupH5uZxJtKvWXcgOvz+40P1t7Yvrv9+vadaxiN1u5tFPSz9vLJ+q+DA3bR5bwZ
# DATA l2HmfWYdVJW4/mnuQEtlhWr6HZccum7uDB+LAQIbDRcTW1oKlCxL6jq/9lIRT2wrFQ/90UyXzcSDZ5FWB4m+BOXPfUqqmeKK2SHF
# DATA JZJpBXxZBSFXcGQmsFvDbdn4QfeFMWcInHGZ/QeyOpQsH+tlYayJBYvfdZOSZzVfpEUcSmRN8xo8UrVu3b96m90ohKK5ObMUytm7
# DATA sMUsTBIv8/VCFuqh3OePumjkqBSucIR17CVm2/KQHpg2Ml5Lfky8lp/OexmWIeGKW89mG+++Wtso9GSKjfmfjk960FIrBhJv2Rph
# DATA xY8F/XVQVnLoOidm7Z1b2xIAJqJv9aKW33vn1l5dX8zEmhJn6jA9rnNMWffmso7SbMarGg5RcXX0VjkZgQ/Y2ODs0NXL9iPzBAa3
# DATA FCYDMrrXf6UDEoc+dmNhSFPth/3DfLvdd6mQ2JGw2BmUtOL5gxV3kp+LY4zmCd+yj/zJ3OGBf5BR4LK2o77iLvZPPL2zewhP/BOP
# DATA La+aNSCkmr3OkXmDhMqBk4/QiCBlxT/Bfl00Oizo3axxQEfL7mlVtE/c0aYjS/fJDSbbHmMuaA1cBW/6zzLyfsVR/wP/8I1K69eq
# DATA VL/hkuD5y1XMMEy6bl67+/67t3+dsZfmZbEGa0Qqvep7zNsg19XtG9jlKoZjW0zo+/aIlzHslVEc83A186bEZpldH8HZqY2ZJ8RA
# DATA X/gQ72S99MrM/p5PPk313sYrOMfUnt1/yndL1zfbD6iy/88ez8NlevrYLLnamzRTLhszi2JL6jOe8z7xfn3tb7Z+s339vWvaT0IX
# DATA MntqeCZgSNX2pED8lTjtziRcTAzmbguiEJYkY27Mf+A1tb+wsfWjeCU+54m6NblSvlnx5mDi9c3aCpMS3pSqUyPdXWqDV3q+ksR0
# DATA aQZnpqn08X9R0z72lkrWWuXFVzMJoKd/bybeeu87xcxeJ9WnH5L101eW7mBO7bNWk+/0JnRrJgsjF9n4NXdxf699RDP9mPTHSNOP
# DATA knRK1JdzZrVJs8VK2f141y/X6nZqOuEOzh1u6bX8grplI9kPay0D80rY2qg1f2kPjay9Oxk8QCNjM7rn91sd/5Je0WNqgnVCYCPn
# DATA tday/nSJUUFOE69zeKl0qd93g4fyyazVyJnR+0gIDanJHls1eY+i8ez+W7Vq1hOsiHR5Q7Fb2WeL7cdICZZ/eYweYoUaD9BXjGDD
# DATA ZCXxztvblHN33rtxJ+l14WUcpha1VzjLIR40CXkjiQxHcyUHCFeaZE2cV0+4on8lbVQqFDUEM1jLUiySe9FOB84tyG7fVPXZuLDm
# DATA eWsXJIYXeGt+Jpa6TPZYN+C+FE2S7zkZRQZY216Tc2xHFxNv5daGlJlfjKJ9NgVn4m5vWtgQtwlvWbat7oVLJVQOfr7Lu1Q3PG89
# DATA Uzob2GgX7S9eKNHLAGzGI9pzLZqFJac7qR8tG4aHC+U2Pvw9RpAvqNf63upuGZ+4xTl4cd46BK8Cz6uK+gdVrenqTGeBCq7XOeam
# DATA 5b9kY6ksNIklHP3LauEi94qVOs5GNrB12nSvoOSpaLxP9nUX5MR0Abss1H7ecZC9qDdlx+aKsm1SNxprxVRZdjtJrbWtDokHR3FN
# DATA O8B4h4deZO2lAuHNB3BpZVv0e4MHA5yrNwKt6om1zDEgle5Xt7JVzKpe7GrXhZEuAVzSJSBjedZpwpmmRzppX7P5uDE/ezhl6jQ9
# DATA HuG5oZWUxcm/ycIk+ElFQPJhLV3cenxY0xj3PCgPo/VQOsyQe2/oKvDJFw7oA128rAW3dm9jY36QVnIzNWQjma/NfZKHAu0oQAw+
# DATA sA93qGxDPeuGFLMRb7ZVQd+Tc5p4K3f7ertGcsxNRUmlQUUrVRLmmUW1csmzVpc4CLtiElgZscqT2dyAj+MDxftYk4U4BsjwJERe
# DATA 8oHgQST1cj+nIeis3Uv1rvoBqUeoHOwKuh0J6S9rQ6STzSduuQrkR+qBTN1drUH932pAVV3y31HP9WcyimmqfPifkl5MXJXUmfNc
# DATA mawzmo7CNJ3px7kPND2kmM7pKdYwNQqml0BUb88DZfq4l92l+6046oF8ZmWQetKEexEXXllpkCCLPOrtMdMnvj8Kev443AvujyP7
# DATA RBMMgdS9vKQ6eygqZdLnjbWyxJ7/ozKIk/1+YsR/hRVWzll2ZGD1nifj0z9j3JFZyyPO76+sZUSdWN1ouLOaHQ6PjjAPXV9S2DRb
# DATA 5zn+5+hOF0c4baan8+oVVQMGwWQ88iH5IDVBeyTIrjWqL9D7Qf4nazPQ/dsZ4DCuEI96/kEwij0wVz2/O4bieDRg1CtvC72sZFXk
# DATA uLjoopgXmZWaeRtskv5Nj5j6ucKB3+/ZQ2nyg1yXAxz5hc8t/J1+vjdbiRMNnIue8atnG8LCIp6z1XSuf1W9Ld0urYJIpoFWzWJf
# DATA IpfQEaHP7BBUpc+HNv5/9t69ua3rvBfu3/wU25d0AzQAXiTLChTYpSTaZiOJPCQVJ6VQDEiAImIQQLABSSyNM768Pe2ZZJJpp/PO
# DATA mc60PfkGims3bmI7X0H6Cu8neddzWWs967I3QFp223OSnmMRe6+97utZz/X3qI56gdaKPl13I61xXFYehQN3nmqco7SenM+sJkTb
# DATA HLb3ikwObi/QGdWfWX6dy9k+RY72CzydwNUah3St80NuA47JX7OjyJegZvjUGHnYQPFpDr0lSxuJ75+hzo3UlkiLP3cUEa4njF2s
# DATA mF2U4YX0yQvkSObK4iKKuDypXNHNueRIDny/xa5w7GTySsL4s4SgxJBAvUEVnV3N9DIKl5LnHxHc0bDfMfhKuJ2W/Dt1ns91VEgB
# DATA ph7VDv8PKJSff6w7UA1kS4qT1/yEbpU9pu355RnFQnryIuzmQWrmHOxplnLyqKg1pxTwmsAb2sZcrwiLD2D4EfSPuHJl8dlwrp38
# DATA udCqBkFLNU/k9cA2bZzmc8kPcU7wWLJNVknoKNdCTqu+QByh3saG3UZ/EwSccNi8fGXpHEeN3CkzXsoaM9qcLbdlfxC6fJSbkS/j
# DATA Yq8ugZIKtURv/Pm6iBAcDnIBydddS9Nz1G5gpiR1NyDidrekYzJEyGXfogKwCcmoj/XageofxCFpbTrHG+yYmblK0gLYA63emeGk
# DATA QLEcndQ/qBH/Bk0fZDR6qt1Uk5B9+jTURunUne7mNYd7ASEA4zPJSqu3C4Ta50oC8nTYb6Nbx30d3zy2DM6UPtphl6PKlB07fCEG
# DATA 6w5TWKMO7cFPugSJTYDX01OpE5IziaRVdM01xuuC80jn4j1mnx+AImyrmTtRrKatR3Zy3Dttow91PoMlusfFPQlRV8KWxOL9e4lZ
# DATA BxTC9iCZsnJGX7dIdF0vAU3QZZ8py46/3G44FB1GeiYHlx8gBdvODVTif6zs9ZLDI8d1zw9EsJA4ISZU/wr637kNkW7atq+14Pe2
# DATA b2+29vY39jdNPMzW5h6eWCaiCOQDNyx3xo4Llex5xHXO8lCGJTdpb2q1xAHl0+ZQ3A+OfdrYqHzzpQgL43CZ014GsNJuEBip+rK4
# DATA gZG/NwKJRzc4Vgkm0rPHcK80fIsJvpN2kHDqSK0fHXwDZ+BPk9XhG2+8YSViM8sylHu3S3gPjPHbfdQbTrNk6+7GO5uVZJpRCgPw
# DATA B3zcFYmdBxPW/anDMgLcSlEjYdIlP5sOJ+3kp2pLwMWOC/kYI7jHXTW10y7GifcQXwjybHVYisWwjOnIBoZz7CGRgIp38tCdsOme
# DATA US2fuSWldtCdTJSkF5cA9UWKX6nF5J7lLRCWqwQym/Gh7bcHLYKABL1yi7n5Eg2tQrMM0flHJz1M2C5cORkdhAlCpwFbWisO+IdQ
# DATA UbaoSnwh1QokPdisENqDysSpqmMIu0CQmsc9QFTDNX3cHnesPgFsv/kqYVKrY7AJD6eoXMB4/D26YEiFz+/JOkqRYk+1kTdBLu1z
# DATA JXx+Qp4xnpYI/USsevyXOT6FnsWXJ1tjVjlgbzFMN0WHKS0zEOHsAwCw+uDBqxEQN+k97ziXkGoR+vXFs9+SFRuUUIqjRkPSJ5Gp
# DATA YIEFBG+MIIkN7REci+EAM7ObpeKHuaPn9+74Y17qr5Xeqj+o0Z/l87UKBfvR14sMWrt/kjPSR2i+iA+VzEzh+PTeatmButstGGvw
# DATA BfsbuldEOCn+d5ecHb+a8qIGRTLzyJlynX4j3DejjKDTGhnw2WMmUTRXcbsl8GhQcvyohPBdjlt6TV1JEAd1sNpMlpOr5YP6VY9N
# DATA g4qDWYEzQW8Kx/dr9ooAMfspbmFebo43MiMDvdFnpE3igYPvR5EF8gbp7YFS/JuhGGpL/TUdJscL+TNW7H9B8eek8dU7y6I2Z+7x
# DATA kW+4sLoCW94H7jaMfKPz4fhF+fmG/KIStGCtSf4+FYWEzwpmCZA9ZErm1MkoQuqd69o5OPNbYWfJghNgg4JdmzsA5Vl/COOq6XTD
# DATA ax8Nf2pqnEJGcvU/9Q+uP3N2Ui4wSNnXYCn8qnwcS1pQsRiLt8XfGrcjmAb9zMyAKBQOSfghB7s01tIF/FIc7waK1f4fqEP8iGIz
# DATA PfoUGHA+N/GEPuWiLAjQX0yl4Rw/eLJH7BWACruHx3lJtm/mxMhpTfFEVNAwaOjdbTWpvYGeLf+0yHemUvXc9DJnloP5/Gc1PzQF
# DATA xvv19xhY+JsgkuNrJEmf4H8/fvYp8zgXncvRCL0qDigtCfumNxq25+i4F9i8eUc4keyw/6hCu/34t9nYYsfl7jb+Jpib/62G9BsM
# DATA rnz6/JfP/ycTbz0/OqQhqnX7A8W1qAqYawDX6Y9xx36iavo8ZKN+Z2JeGJWlkRM1xi72OzscMChgYJlRuLKu9c9UFaqdr65+/5qe
# DATA laMT2jfYDvnXkd3tAWKgPUCvFQQ+bYaz8vfOiHM2RVSb/QXefOiMiA/EGPL09uxiUaCcN7rvXCGKvSOduLqo60YzCktAykjU3K9L
# DATA yscuaXN0lv8konR9FlvPy1e8zz4M9JgB6dKqTKPb0hj+PHZ67gwfO1YJpKOsuwlOvjuI+1guG+s/8mfAioHTdA2Qit7vnmWlg2Wu
# DATA h5toyk9q3ScTUAUvZl/WvnxS/e5ZL4wgDbXXA3ezhY3rC1wcoeo4Hmhneqr13udkGkE3VLL+gUcYKfPrEV+3oPPGQ1mTfEjKjhPh
# DATA 2J/TmqIDqZ0bnVSJwm58IRt2KP1Vjt0txtXI9a+154JK06caT5TQot1Z1f7KxKdjcVJaFnjg04it2/1CMM0XsfzgghpY3FwbL2K1
# DATA RBe5wAXGdBZXSVp9pYOL9YyhwTorabU50lMrvvPd00eNlr/dk2BPgOKhIKjF+oDnzZfjcfZtnQtFP9gVE1Diap1udwR/sKJKeApa
# DATA hgpu9rSiqTxHi4N2+KVG8DDPFSfHP+BX2kn+KzSrweWOyBQJxEqpOftXcMbBcFEbIv78E321S4wEwQxGnGDiXJs+/A09Kwf2gDdx
# DATA 7Ba0In60uHgQFOMGoEhW5Utjlsi77R12O2+vdI+Pu6ggVJ0vac3hPHK1yIhMxUVjytf3wI9/1+NBPs/4sOauvpUtnuYNF+GlYW1N
# DATA 92iA9NyJsw5DkKhQEIPk1AtjLUWi912CzsU9RABnOqkI9a43tFabGq8FGDW7FEqbyg1chaSBaTzYtNFAESWXeF9A7EAVyZcUkQKb
# DATA zUY7caQah9zEQD0E4G947jTBcvdX1Jdq3FX7vwcMKGxeb0U5z4WOKOXF+DNcjIPVZm1s0IrwSXXN4BfVdRm5HKItRENSvyYPxwT5
# DATA rf/+GQOXd3r4WK0pwPYDerfiUZ6go1y708EniiHrHvfeT6PWyWf/knty4bD/rdr9wJj+DcZqqfX5HUWBag1VQifoCzgoeEQwAA3K
# DATA IZjWh+hB+UspM30iFobX4YAnECK58C+/QG00HJXSw2mvDykv0IggbD77J72MSQjghIAJYYhwdeDihDD+xsUDXo9Hwz6ZuOHG1LyC
# DATA qG8MmUu7A9gfBCHMNijIADBQPQLczD4E76gKB5iiwMSPAbCwuhBr4QglGD+M83x5ORbw6HNfNlUE3KFCXKqz8GZACVPQ76evvqpj
# DATA k80WlbdMjOrK+8NoO6BTwiwluxhWjJJ8M9ZnTtqhyhLMlayHnUzpMzduFhXjdFMIdTixBbp3se+W3IB6wSeHnQ5D5TXlyr16o4Qh
# DATA f6IK1jK8I5zC/8luCLN2uXNuTI5jpI665Na9vf2Ne7c2W/s/2dmEZQVqpk4IEjJC1B0SLP7RSbcz7XfH6czXGtL/SofDYX/O1mMq
# DATA TJywM5+aPjcaSV4VhgaVczogZl7NB+tGoSX1SxxCOoXUlt74Zeey5XkCPcILvHYNk2Nja5+SAe+3iFP3uWJLv+DwYMd7qvjyJRRb
# DATA PBavJemN0DYSal2d4FEykxln2k/zzajGf91Yg10XrZAe1EWOGuQpI9TF28N9c2U7m9jqzwR/CV842jJ4sLCqbD7j+XWM8fw8jkmD
# DATA ZubfcYz+HOa6gHTPI/9zCDmJYkf9NsliTouFpEHNqPlOEnTM6MovYmfoJQTCibMtxXP0qSOxaDBDEUUR2uatafdfYW0iwBU39Ab/
# DATA kqViNA5+pbkesPwRMN8Fd7y368/daawnSG9il//MDaRwhWOUciWWqYmfAkLX0A4coXmvQdrwSiJ1o40DFOZJ9VdumpdWhdiQBUSO
# DATA qAjfLXyQEd4OINEDw6P8ch+K3VelmDfILbhDhJ6QTqy+M6cu/8jnfLFjuHtP7rS9n2t+x6jf67Oq+fvqrHrV/LiiXlz/fvuw6TzR
# DATA f6+Rn5xpLE5mCNWjEOYzDIx4mlzsfvgcyf9Tcoz4G8BD0a4AFj79F0GExEHOAgAjbIclQyfOjadEPVmD6B2j/q/7fqPIS5DnJmuc
# DATA eA+6OVlMQCc4QZm/1cekWUPFlFVlUS4ncPCqaz2LjvZVT2hU0C0+tVCK/6y4d/We9byKHoWZ9sWaq8VHTbiG0jWQKPgzCOrItYQI
# DATA IF4UNGO++NJtk9Afr8/26Y9rs79gB/0HOrYZuwVCrgcAbtLmhPrsSDirDsvyA6b9qK94sFfOU/iW4l+D5m1MawCrbDvuQSK5V7oD
# DATA dvQ13ChGn4GOYDFDTl3dB0p2/g1eD/r6wHPF+leLSV2tygCfEEood4Vt98FXRmZByiIKaXfigwDCzOJ8POKEIDGHQXAktFsSfnne
# DATA TghMghGc5l3mQ64t6ImXGynzB3DeAStb7pUb12KHJkfo5LxwoJIoSUNp5n0S+Eq7xgYzI0cBQCUrsb1WXGV27ssIAOsiE/Q1BdCg
# DATA UxczS7+Tmu0Cs7V0Uj9Ypo5Zqqt4hmU7WKa6aFcKwy+F33oQfWTypOYbEmz8RIgBBCeCq5gTgONiA2l/Bs8yQp4O7CLJZn6y/cOk
# DATA 6jv4XzlvwKd0DxcsAPuLfQrFLZFwghARot4EdJ/2JnlHks0fLRdkqPgUX/ZILBJrgXV4URba4BwJXAs2UH3huNn41iFLdRCtGQZ5
# DATA UKeEpR8fWEs//VycNM0z739qqBdBzeXuDgdVx7ql40S5Dunzbei5/uMy4U7oOm5L2M3lkSgTba5jXmmzOfwPsn28SyWmN7qFU+Tp
# DATA UOteT9sDxYF3ElB7iAxv7LRPjYDrIqQdh3+1G7l0DY9x7gt6DF4ImVzvGv6lGAhIs34RJzbBaNOji2CYf4cnlzXuGrCMmW7XFmsv
# DATA KL07c2ytgoiS6/mn6GVLGGrkaVxAMotnjU6VkU+ggtAZTzAmMe49yJYtXe58NzPvSnacbZsO46truYB3OgAlo4M940KAEOdr8Obv
# DATA k1gnYjZmWjZHRwSfNb8lA0cEMF/RHTxLsxjl0w4AGhO+C9V3WxDI1SLypAO5ShzsAsTqQqH3LtIY/ePAjA0sfDi0YQ6Ebs/FT+HD
# DATA 4EftEc9NvaEAfK7GxpjmQSSFR57KzONgdSnLdzcteJLm1RcP2gyi6UwIHc5KJGbTB6DyEYLs0OehBAnQgW+zw0GQ6QKkM0AkUhKV
# DATA y5m4dDQYdGS4hcdTL6t0PW7mMVfhRlwsdPT/1rDR/D1DYaOs3G7jfuh3wVI8fDyAPIuD9ig7GU5C47fEfE4fDfvTU33dWHeqydkI
# DATA VEzpYW/QQXMZdbou0wuCoZ/WqZ64Q2Om7VKh60Rv7afAEV5KF5e4nrZ1l/wYB1wsh3uy7m1RqZGjP2Yu2YiGwXtioh+kTsNbhNDY
# DATA k1wWVNqgiX5TTbnfkRiuIP0qiytLY5LSL08o1EAzkk03uiD/JjRxchDS2e+iHtNcp/yE01IvcGfGrrCVF36BwUmz35oTCwdZVqm7
# DATA aEsqCeDEQSW6GAhLLvJXWzu3xfd21Lec7ZTkXP4t+I6nnph9IR956lwQcRGVhk1UV79f8pQwgSw6F/wMlCiBp+HzX4K/kU75ZZFA
# DATA 6I2IlbPXMm+2PJ93T/yvXwg5Qgo8CMH5bWrTMVYenOkJekn7MxH0OBH1aabumcOzpNse93uYG4Oz/mYV/Lvb7ojqhhiTP1JsZ3vC
# DATA cfa9MeYpVl+dQoSOIpmd4WMXFaQWOsO72v2V/0jd/soczb7p839Kxf4Ce84MgFX7dhE8zf5KTK/vgkfIABJW9LunoabdON266hFw
# DATA FNcJPaZMqwcO9lYRJw8SW46GAyUw930cvtjWcPS6+kO3P7a+/B7R8of1J0SAEWsJ3DO8wDdSLQhEOu09YIgyeA2w26RNXyhcX792
# DATA ELV/Rc8utivM+C4dj8MEPSKOuAxDBL5XaJgL3PD1heiaLoKncIeE8V6yqHxsC9sKYrV+l+79fL3DJagJYH6Yp6uFoaG4yqJo7B1t
# DATA na9F5FJ+kEuBu77rp/W5OwCf98ODVLoU8EKOlPco/0tuc7HY3xCIYN6spH4GnViwm1ExLePh0MFulwJiLABh9ExzWhtaQHVueFk6
# DATA 1dN/145IXxOb5CES4CMLOeKgJ/qml0Gn+6RimLXuQEmj47aB+pkbfxSDFX0zub4MYKLLeWmKg/g7PyHxb2is6oGbBwR1GeAvFQk3
# DATA 0iCEdbeX6g3j+tWTEHuQob5hEqAk4tfVk9XhtdXVWe7AvfAH1SctFSIckjclEh2pkpBY2ggsmeWIQSYKTljROL/5mH3SdQCXXF+8
# DATA UJOUPvU2nS/jH7MMzxXOimRSySy29NVhI3vp6hApFRCISnGkDQdzMIcs1SUoJWrCnlQtu82FSB2dGn4YO84yrtB+1mMaUQitMI5I
# DATA /NcszNyXo5a27PamCX3KOI9bArQmAZzkMy04EqxTewyGBEw+QbBYWKmoC2a/lmwiEjPc5+qzDNGzUKXW7zA20AgiH7ARvvTRNDap
# DATA xfGqQpZonplQnoU4q8hQRC9EKPIFIp+d1NBp5aBEiJm2uKHTsDsvTNETN58KX03GUd7Ef9Ruc/JPOQjC8oTFq3XPnSAE7R7jLqO3
# DATA mxeNJTgL6e+NSgfyB3eHxXlfexkKqDLfqzlIQtPE4GCaIYXNLGHBTOjC3Ly3d8IgCWb5EF/IutarpmrE2df09tS8oa9Pn/NZ5kB5
# DATA GJpEjTKbw2WCK/4fw1RLX1GKN8ecxz43PP9o2nSwiTx/Ek6ZN4el/aVRjIikyfyDb4Dh+H1C/3H1eX6YQv5c1rgKUMLZULio0o5L
# DATA Oho70wHuAWR2jBtFRfowylVP8Wlf5KIl53JM1aq95nKgJOBB02Qh4QckbZcWnBe6DFp0Z/oxghW/YThaJT0ZK8lITKGfsgmpr6NV
# DATA pMcC0Yc8AMq+Lq4465MzxYhx4qB2fJ4ILd38KY5oOyhAIY5tslhSHB5vTtyBPormtYQZiat9tK4mHKyfjdLWdSPgzyVGDIgnH+J5
# DATA /rnwQGAkPU9hiepDp8fUQgsz9kWyLkcb/py0wZAk5Oc667KsxxHezzHm6rTN/tWSDRJUO+ADeWeSoYdoaF2TFc/f2rP3MHiIY5es
# DATA JyYW3aZYIvsO/X0A+XObXsWOiFxXR4bqaCLXPxm3hcv1QXNWkEao7t7xIHz3doZj8l8YqT9sJBvaEXe2dxFrZ139Ly07zrJYAd+E
# DATA qguDTJ2zUwOkGb8SOQLDvMwaIJ84XlIUqmFS2eVEekh28xvdn4xudaFbUPjQcJiJq+nw0onHYKsuCEmVi0LFxCj1hA5ih02IZSxm
# DATA MAaxx2IxxOBhEuHS0WIzWZ4/cXWX+JXj0ZIYa8YaJN4hs/wI18K41lKMnFKcZLDd4HHALpcK4lPLl41g9GhxJBo87F3si6LwcH9h
# DATA Lx3yHw0o/ZYC/k3ovgnmxz+qitA+OfN+Vsk7ciwj/QVOQIgZYKECCD1g9s3xG76O5xINkxeRyvR3oKgzlry/e/YPlYSDVaOaSSdO
# DATA 7luIwYY9ivkNQX9n4EYSzOwbD2S2Ipe6Di1+c+x8lbD2BQOfjTL4PMWj9Lj9qFt1ytvH4kshq6rvDb3DkGmXChbHRrtll3J2hObW
# DATA KYbZtli/xJmbCwBxgVNekCqweEPbiIICltTRN4yHE8XvUG5ISICsq6B0xCKR/IFk5FCO4Bf8wSy/7gPBcyApBJkbeBL+NJ8vKcfU
# DATA NCH+T+RMRMEE5np6HsRyRYOF8jXEE3hNjCmnZDPaoIxwi9QOWiuzECiRkTXcSckd73TzAgPUljRYOD0gcpDgda5YfwnTH30J6xVn
# DATA hkdVHNNPoSGVv7zg3J8vL6tHlWR52dQwC1NQVZzj6EQcqq9Lqq+jPkK9n6ibgjgL+KsF+83lSDPLjOqyYKUdwskq6SfaDplljylB
# DATA E0UrZzWK9TzpPildWS/bpNfIXsXim70v1Bbf2d7bf2d3c6+1s7G399727m1U8FNDFW/qbOH7e5u7oPCXl6J5efum+8qvxQvGPhbX
# DATA aX1lRf+on+tuzP7MEunOYf31q1fWV/Jrf3t3+95+a/Pe7dbt7bsbW+DunJ5MJqNM1Q1bza5IurNxb/OOLWbe+FXu3b/Z2rl/887W
# DATA LVvYYaSm435WclbVrjwcrYPrdRCm3n1v67bq2cbNO5uqd5tvb9y/A0ujuIxpNxzI3c393a1bdq7bndMeunvoF7Bi0ZWFfN1+be9t
# DATA 3nx3e/uHvCFa725u3MZqo/uCFfLqoEI8MW9mwym7R5Q2XMgkj9qTSXcM0s84/UuY+HG3hnA+XTj5AD0+Thu15VdTl2/TOPv8eQV7
# DATA ARbM2l2PjHL34JPpoS3PQOitehIQGF3Zcb/9MGtglQWJQLD+1xoISKFqCMnVa/hKEgf4ROeFBI95oAU0wZVkMD097GofOfqhhWJ+
# DATA 5UZDIJCshsvwsWXh98vpg/GDAeBkvHwhzzsEeDB6jRvgaMOwuqz7tDcso/FKCCsAtoI/yJSoLb+Oq1f7DBwZ1ODA2lCDv8F4lXWv
# DATA Xa0dXrvKxjQ9LTp+jvKyOA7RERRtrhtv2vfLbrgRvzt4nxkG9pVq3+qOJzvdUzg5P3082ZkeKrr9Q4b2Uj0Rr+GnegO/fOQRVPCL
# DATA DIwlx7ZQsi8qyf7ZKMjSSKsiJ1YmT0WwF41V/5SSKXI+aB2J+xRCbwBi4yO0y3+M6fy+YPUshrx9EU8QwTvz+GXD2DTOab/NHgxs
# DATA hxrpOSNgqD39Mu/hx+3ehEI/kICWOH0J+LQNp5PG+qoNURZAD+g0rMjBXQzjwAgIWL1Ou684yTQaoRHefKw/grpu4xPtLO+eHFEM
# DATA miRdE7vdqHXtHcMV3S1APkYfZVUyWwGj2tGJaqk2UutvlFy2lmiOsdXkB06ZMAPo2pW11TfWowf0N+hUAF4ET0H2cxFDoyv9NHl3
# DATA f39nr2rjkVLjZMS5w2RvrBGYdVnd9jGTTJ3NpAr/u7n5zta95Nbm7v7W21u3NvY38Wlt+S38V92lwbtUJClS1e05xAuaCQb863A4
# DATA wWBYZBXacq3PfTLS8oGXbinL+rWdzbstGHZrMlTX6i7+XYJOqKu3XK7prEt2ovDigC8pW1KLwwVa/LJ01EYrGkgIYjrLTg01jmPC
# DATA yyT5gOr70ebu1ts/af349dXvq+tZTdnGndatdxXH4Hyp7vHe6fRU5DSBb/fv7P2IHsCfj9Za6+zM3e6oPQebGA5e7XSophjc00pw
# DATA h/JZJJPTCZhSgkI/MFXU8xPZQn6gJAPt2kRPiurtAEzsSkIopWvrb9RW1f+tpeYms4RAjae0Dv78T0q1tYpprup3BTKOtDNFSx9H
# DATA 8itBB/QEPR63Ry3qTUmVJrVcd9zSdKJhmCuoTxGu6TiP0Vdb0t8xVByI1ajbHeNmOVRS+lit5XB8yheR2TVAwPT2q+eKVRYtjILV
# DATA PwQXNids8GtONP43GudRIgCoBa/SgUccsI/Sco7UQl3PukBO+6Xj9J3NfUXC4BytrNXWgCF4V01NPTnXMzSDZ7fMUirJug/uAsA5
# DATA qP+f6jRl5XLe7K2vrgIZ66Huh5pX5PNR6fW1da2nKx+sQR7W5Orqav4MCXI/J7txJdkCh6FYpmMQCewmhu2V9bvdUanG0g8tg0tW
# DATA osneAazn94mAEfiKsgs8/8UNrVQjD7hf6IQ1uKaVKFnGDFT/RuicYCtF5q9KqkZtzcdfDChesjJI1gPfAnVtSZP9XEEQeRj1Nk3x
# DATA 7tV16Ex4JLwfp4TkBnFVySqe3lUlVOG1qb8oz4D03HgwEEUP6vVmbjmH3T1O05ROZnJ+viSqmA56T+orj9rjFXXuVowSe2U8Hazg
# DATA RNTgcEOVCapcWyBrD4+G/RtL5zS4mRbS1anHqbAb+gZZSbJ+S17xkdYmfe9Wj37ZAsY+5+vRuPdIvXa/1X3NEiTTtXX+9woVAVZp
# DATA PRkObiyJIaB0lSXD4+MbbANR1+TKNBuvKKI07tKkrJxMTvv0vj2dDNFrzn7ShePQwoj9q6tXkxX1n5r4oNNRwlu7o5bix9VbdDNX
# DATA gROtbpNAqvZkNugdK666/7h9lgVf7QJG67g7ru4M1fSfAWfdO5qwJ1/18Ul3UD0aD7OMnzjV9IekCEn+8r8nK09gAsBbZkVvCrz6
# DATA +j0A1FdXROtw2Dkj7mj1hnn/cDw6ahG7QpdKcmV1NfPeA9kreg/UAf9Son7RFsQu4hakCjjpuhmGGsWDB7XSWy897vb7VUwjulJW
# DATA o1E32+AMXJFvBJ/AYOFWJa+E5NXpuIf/WUkaaqGwvPp/6rwwOTged7OTUsydp2Ksv9qeaW691Fy+jVQNfzWt0PFpGPsGMutEM7C0
# DATA r2nKsYZ6j5EeqRbWsAXUag26kxYqIChmjVuyT+HS5IdINNBTUxGH/jHEyfRT+Y6qv3r1in7aGxwOp2pp6cV1eGMlC7dOrfgrOXVL
# DATA ASMuCwMYwqds3mdG+0PyQ3/2ZeIyoCgWp+WleSpwt18NV8wxyQPEioTJlxFgDq8gCkL7hYl3iHDGNnINZMcvNRLDC+mu7ZrRHx7g
# DATA DRALYmN9hb+kkcUMI4Yg2o2aoHC3K3lYlMhB/TzZ2NmqOOsDYD/sTvI0+fG4fWZF6a84yE2DU8JtLnxCesf+XqZgFjNhRdkqMRYJ
# DATA QgLvKXl54/ZdJS65yN6fMf/wCQALgUz/sQx5+oxW2gYaxGCzjItYEAMaAIzkeZ3l65X6w4cPyR/tPO2oaw3dQlLQ0FQ5H0k6HGkP
# DATA kPNUEeoq0GgodGUVtSPwCIuqR6+nTAAhNBYlGDCwYbZXeD0dKCKYVbPJEHAv4WNuXr3kvwIFJZvAoXHH8G28jNku25EONbOgmmm/
# DATA d9qbUD2DIff3PM2Gx9CztdWr119/45rqkLp2O/bBbDZbzE+qPRppFGgaOlNpjf6p0c/JldUuqc45U25WYhwyLFfWODi2clZda2nq
# DATA SOnjn3F0e+OAbdBVkpno3oObzpqmybc1q6+oVV5Ro1jhBzk1d7pgYMxaw0FDmk47hzibio3toO0IFptNKcBI9CcnZ+nMsaqSSXz+
# DATA R7NoN+g1BpmrfkzUDgMfpPTW3dvVvXc37yDQ8BHACFePsz1kvdTVD5dyHy5NmLq1FaoDPc8RrV7NCfRgbRWtFsxO4KbOyCCsOB/0
# DATA dbpGF8t40hopUX/YobOQSfNwSFMCoy2oIEfqHYFzHqSGgKTNGFZtZGsZ+0h97XrtanrpTUYi5MkpMl+NVAlwp4epk1VYzfH+X8Aw
# DATA 7+/fgnW0+0v30LJUwgeioLlFFnD0sNXLgPc7S6r3k1dfPXfMTLOk2nEe3r45Cxbzyry1XF+dybANtSdz5ppODB+c+ver7f6oNwDy
# DATA uOhZy5sMaEfdN+J7FA2gm9Vqpo4KgmbjL7LuA1oXaaXpqaK/p91Ttc7VEbLo9K6rjhEeKiwDXC/1C357XeN/kPH1i6sdjkT+jTfe
# DATA oFdAkeCv1dwB5S+tdYqpKr4f68sW6A8keviGKyt85wTZUqXUlDpkCQmZQJgNCRb+6wQphaxzPT8jCrF8+VbB/C9Rktf6bf9F4KER
# DATA +bSh2QDwJglegzPM9dVKorjsWa4vEjNgxeDH0oQR47sIFFyrTiIpQ78gNjeNurBkB9I3J3B1a8bPb7hG4e4lTqNBeFrq2wPNe+De
# DATA y3W6q8c87iLXVgF1lt9rSg3c3DFFvzjvY+cuxiYEKwwcw1r02MYv9ctdzsWnH+UOOPehXZv5tOMuxC+9zFe2HQ/0fQUJwKDd57v7
# DATA 5XJtcgJ5cBtvsu8WxApOSuPa8P23Vutr5XLtCMOhSmWvhHqVR78cKvP6PCqzth5hBtZdZoBvCKA9cMQh6skDbjDo1pZAWmptGDI3
# DATA MhIEfIoEQxm/nnNW6G3OqaC39XV7m7mX/jvbtzdv3n8HxnQ67U96oL6ZHI0aq8AE8KZLr6/Wr4NCACT3Oknv+s+VaWdUxAXEmdbg
# DATA eNyCXlJYAxjX6ytqj6xg11fMq/p4aHIxVWE+6yvwX/uMVKz1FRe902tcR5+di4owTM2rxg9dM/7i5xSIb131Exnupv+EZWYAqrpu
# DATA eiZU4JNxG0Vts3qRBSdl7oFlFtmnXBzgCBiFUwhP48IijGJlwRuRVThwYV2e5WTWt+GwvUarYwVxHmOlYHMovkFvi6hWD3MTet8o
# DATA WTNzPho+XMmmI1gddP+MdTkk2mA1XoF50IxXrBtM8XK+PhqOu8avOPY5rKNbqhnnalCRBGsY20dNN54nonnCa4BsCuJ9ORRa9L5t
# DATA al/TYGRoNs9fkkk/g7Oad7cLE0ke0cK39bXa+nVLt2Kbc+liVIYMEHC+JZkhDTw8rXVW2B6MhZDgFFO2S07NRWudfwIuWOHjx491
# DATA hTFTBPTRI5+CZMkFvCx9nL2ICCqrJpsfQxUEUYXbIwKJA1yaF2aFCey9qv0wKoyKicRQ0SQyl8TeLXV5XP2KUcVgChrrYI6yiohp
# DATA yp7xT85oLp6chd2l2Kx6ovW5KUIrip4ijoeB1F1QRcZeNpIvvT8G7toPPyn0mryQ4CUDys/DTDP1hMwT7hsae8A+Fx2inKwrtA8h
# DATA 40oN/nO1VC7PymEPfSwaTVkL5ZwY0pQzXulu1XC1/KSR145RDdIJOzr7MhXZIp29V8rR5JdjTtAySA82haIfTrAI4T9UCFe8Apaz
# DATA 4WPflMT2mmG/A9T9sRc0wBCNFTcVGVRXlv6owF6rGpwQLVQtAMeegW9JiYJW4VT8+Xv7LcdhOUWg5Ntb9Bd66Uo/W/hbu89CNjzb
# DATA 5HmQ9YwwUfWvwBe5EnMmhoc2qEH9cmIQ3EiZMLZIDZuiJF5qwPyRa2T3LD/J9/8yyRW+ePZ7jiLCjEUYTAv5iiJBQ89/RUAFUDNF
# DATA NqqtQVg/5G97pA7BEDJ5lg5Kp+QICOZnCIHgn3uEnmof3FZCY2+Ap0E83X0v5cBshNXlGMG72BxntyjrHdOiXuDGaZke0R926/Bv
# DATA sWvAz0jJ9BCFpiFg4QSj1WWY1XivcX8AQfvW/b391u72Nq4IqtDNzat6K+B4VyjuVlUOQ0pR22WROfSrSkJbXwB8YX/YuGlHxhYq
# DATA egtxnmacdnntM9BcDB91S/wBVf+KTbk6ORl3uxbGsAp4sIilixcwt3jaPksOu+Aa0O3Ukk2EU9FxTFwhlgSYtFH7sNfvTc5ISKxo
# DATA F2W0NxKjpkgF6sGAziKow2TIlKKXafRDC5VAa/RNo0Kj+Al6qnVjnKrWJzSFweKwJ2HomOITrkY79eXgXJqSYjV1BRBtA9ZG3Hv2
# DATA 6ZWmxjuG+yoSV+WH6cmmDtabev/EMZoXrI9AjrUNkqpe89jAcRcS/iIyKxW3J6Cm37UmQzpQOsJd4i7Ape5/2MtaC30bZqAxwQPc
# DATA K1hbMDbrBxjrlGFE3jq+vBQ+tlsbuJZyXc7jtSY0E1+BA71QzXAtwlOMv8y+FbuICH1AB2LkndLHkTEac9NFCHskgYES1+n43mU9
# DATA HnAGN9VmBZwl+H2rPdrodPiv2+PhCAuNe48UWw0m2qZzE3v3vo0gREeOsC7vMCk6Iy8aHUZYT87RQbc9KiteSAn1uPlg6kbj7nHv
# DATA iap5Q134HPbdRoyOkhfED86SAaEx0arqrnHjCWERoDd04XC/4B972eAvcdVEYj71iJlO6ooapvrkA8VZWIXJbHFKIJvAqcxvo3rh
# DATA NkyKg7lzp3aooOT5BaPOHyF/Yiuw2XPBrzJ+ykCSxHrTHDG5jqI0KHtZYk4jqhyIGhMqn2jBUGmDGHjid2XJpCOE7BU2jUYMycLP
# DATA orG4Q4jG7tbvXehuW41fTxFwt4sLFI1VmAvj7fsnsVaydEEojfLi+FESDSMfJ3TueCnli4DIMCgwn+mkoF8//2vkmb8ymd7w4UeY
# DATA Z+xXDmlFb89GItUMpTR+58D2loJk7aT7xEmFcl6I6zJHOwId4efwZ1kmB9DILscm50PFEOmcpA9BzB/ilRErR3edyzN5yy55epsA
# DATA A8PK4U1ESBD5KIRkl1Mac1CDdmsldf3QdC9DmAa1TBDEoAtUQNxp8L2DrdSRr6Br3GkM4ky0+FJB9i1fAPtH99QEu0bsNidxNeZx
# DATA ivmVqVcfu2Iap7AoBnkwnB55I+NqB/CPQS7rb5pdg3442TXoD6EycRNV2IpNRXqD2jpE1TM366aqS9Hgoz44B9/TCS322+OtwfEQ
# DATA YFgR/ZF/a8qrCHYLlR9dxXV1J22wD5XA47SiUyWXZcrlCUJrq460J6obXEL1rmXOuKmFQEXVrKzC3oQqa+CO46i79EMAVQec1+V1
# DATA 3PjYDOQ/S5b189gFCmNkkY57kujGMeqi28lQGszax90EveWEkp6/qOX2HBMMq44s2YkCi2trpM5N3gThgML51AX9TKxooVGkz1Zs
# DATA SnqNPhxMIafQt9Owrjyv8Uwx/JANJKdtDvnEQowjR0CkE2hnhLoSFOntcp32Ho6Z0jHXgKrio4nMv8UtgT2m2z6tmKMAq9PC5Wys
# DATA mw1yhRMU84u1VfU/mxfwJkxMQgEApGroDx8irjtuFk46AiiYiHQ6ULI7bBz0XQegy0fQadWNrskL6CY7klRIH5IjvAwayeqSifrS
# DATA Z3CoTnkJ/hoe/rShh0eGnvEHlKCop85owz/EGATG0+JJ6130gwGRw39NNA768lojWfOCjMaoRyIBGKsgsFQS8UKMFKjlTTnRcFzD
# DATA rxVT1j5UbNt00iXOLK3VUsKKHU+yvOvi/gAP6iA81Qgma7A5sBtpOXqnUS96GfGE2jXdPGYkQzNh6hFv7nJBr8wmHsQIDtQT9obr
# DATA p9jYZFU0yfTO7mIloOCeyeuBIHMBVTMHKUEfZrcbHXttAzEjduKnw94A8wAsk64gNo3iQ19ZwTt9gb7qGSIoBEUB1FbrSB4nZ8p4
# DATA 8aKIwWIK4/F3es1MGK1lRXW0vkuJuJeRMEQ5CafvQ5/whK4O31hdhWARQNLJOBwEAb1bw/cppHIxIZbohDqTYlB5y6dzlX2DfsB1
# DATA ezKd9Pq1Ti97vzXNlNimV7N2DOrSHzg79LXk2tW869fO9JY6HcfHvSOIeQIc3/eRyCo26xTJkn+gJd2PquL0rczXAZ5X6lU4GvqG
# DATA IwEvsCF1BLn68lSdf/DFdCt/BSCU+9MMC0OIMBwgRslWe3hKpi199gVStr5AyGwVCzuGLleclcW7IH1ymCJxH04no+mkXrgZj07U
# DATA Bijh+oszYdDh19bWSHOI4PPhZiQ9NckueVvPBlmb0vHzdtiH8EahHG13ShAkbT6rJNdef/3KtfyoW6A3WMu8kOPISj5WMzYZTwew
# DATA Gp2cSGKa0RoD4UND8XJ2WqqUmyqnLNd3rPbHSQQyfJjVjrOzwVFJl1OTOBiWXKsi3mDGmjg6i3E9Ql2it41De9Xf5J5AigJ0Cxul
# DATA Qs2C7g4IuU0HBeTDGroqshsD+w+SsVo7E+7gfoTKwVLUgaB3+XZrZxOfd8dj/zlzP71TDMsBC0wbtKi1fXhSWgNPXF38/V6/L4rX
# DATA Ou0uxdYA2RLPUfTVACQQFaqKGH24E9kfhPkX8JO6FzS8SiBC+jDqcC5hC07HHpXRXeKXSx4YmxlqSebkkW3XMERdvO702g8HQ3XU
# DATA jzCxsC2smqLDhTmh/UQNFepKpthHSoCdRluESvwWjR+LLgdQKCUBfGId7YhWgq/dreG032HYaMViIasMxAJ5PDkGhAxkOu28kVIg
# DATA TSPbgzCq2/Bt1GQMoOaWzC1GQDXprfYAhQ516fTP8GCJu+eGTX1mj4hOCtEB5TkmVYCaQmnJbPRbOjnnDj3gk6LdBMAXRYxSA3Sr
# DATA Rvtys+LmPgKcH7k3yCUSmxkNYdfE77acnSVfBWtIpEZnEpXaWUqjrmioPM7qZ4UIExZq5NAoGbq6UH7iV5KNhEPl9LY4bb+v5EW6
# DATA MCFGD0yrfWLdEKqi16Vd9LOpYpcga0i3NwJrMdd3NDzpIgKjHlst0Rk8k/e73VHmJr2zK08JMxQZHk4BDZMu694gM+grag5Kkrjy
# DATA u7Ris5KzcrIJ+RvQPZyYMMXuqhF3W3QD8ENA+9B/eofLdsoBkjKdYWJRFnnWPP3iVofgh4KegdjhlUV5Umqgd6eDAfJAkdRClHnu
# DATA M1DP0Z8IHoGpdWLavK8dtTinLJOo6JhOiHR+n+QFg87NOs9KZlEYtb02yTr8DDCM8GE0qbBMWHDpnMJYvWfquVhuUG+OnxbpS4W6
# DATA PSITGClA+F4sksDZ5TMAUNVJBlyZm9iZz3Shcd5qtmHyWSGbY0Wm+pp56Rbjs/oHxPf+xQLTZ/U4wSSKlIIwTR0GThdE0zlnAY/m
# DATA auGhhhrRQbi26560cZuITGZF5kGHEnMqiQoEimkP8iIpOpi0DzOgdv3uwzZCV2i0QluZ3c54oRFrtQJRb3CZqj9RSmOWJasl9yCP
# DATA UJI9RtM1Uss+AgzWfHmr4NY3ZigcKHEaGJPl7Afnda7N4J8os8lndC7IqC9tUF9EF1cnMSOcvz8w5MFXOrVHNH8KQiVQVoW/M/hb
# DATA +Ro8P+/RgdZHLvMeGj/sDw9L6XJa9nYs6PI4WWatT7hpsXRJUdg1kxDXWDndDLnloolkq4oG3IM0k08BFJtgISDv5B8MDBvY/j4N
# DATA 5/WL2KEpUCkarQYM2qDDiRGyCo4k1DwNI6pvpSlAKHpzB/zr3C2hd8Snz3/+/G81KlUUkw72GG4K9A10CbI3ATggTxYPFkvPQqF0
# DATA fkQZrwcAyFaK0dgC6o0AzQ6ZRq+Ieeb7soTBxokfc6JG/MukEaccsJGEdU4mz9g3zpkhng5kKTg4jK4okBRBudIbTrO07DweU+Li
# DATA s+BEEYoZYevrmqUBnd7HdcT0bkFPE4ZLwzPf4F/cZUgciJZXV2mHYGpeWcJji5TmLvmJMTVrce3qDAUKqLL4oEczWzLdQ4wvglyh
# DATA jBiKvH5JTlKYeZgJqwZkUafnM3gUdtWZDNhkEEuBGAQr6tXKk3H7jDND6EWh4Z8SPiZ8cjgddPqAbLGwo49s9KX5OxuRj2nGcifs
# DATA 771Rf67HTNl3mVv9QmceoFS98hKCvARqAjlhr8PGYdJeL/GWn9/ZT9yFVX1ushogSi0niPU7GN8/+gDyThFkVh0KmSHSLUfcb+FU
# DATA RW5jCRonb2M9NyK//G8oFS6gxXmQn3aPLRm/v4xyAcIiQyiMSFu4kaC6TbFhyHAosbgn9c7geJeMho9BrBtmGWQ1xpxy7TFZHQbd
# DATA x6IykgGEC1GCSLnZCXI0j08g6YKWJrVlsD04S1i1Aj60NaGwoVp6hCQksK2As1W8Ad7fDt+ATLvlFYJrQ7hwyM/Y51w06DhtINQQ
# DATA OW3gn+wJCqoJAN9k1OG6b2DAEAxUYqnpR9Ufp//Latut3dvb9+78JPmAfmnG3Dy4t/329p072++5W3ISo61GK2qbdL8KdCTiS1JZ
# DATA yS8ZtBdUui0lyCvhWCP2cj6jeiAofiNnd7aHm3zi+Si73jenbU7yke7qipP/78N/QD5DJz2T+UoSmRleYxDqiFTU1HY180jXqsnh
# DATA k+8CViMUqpLn363ZCT+lQ4tBkg58YGhCxSKhUFyBZS9FBLyuYJQjM3nwwCdatFuXYtk49eQSHlcu5kBWa3coVJMOiD1EwvLspbaH
# DATA pHg2RS7kNnJzxFN8r6We9aX8VmNfMv6UEgmRGNDiq52FCRy/xNVGH7rnH+tcmLh/3Jyxz/53QV5Cm0NTZtX1wt0wOgdFSp3WCjIH
# DATA LR+kCX4dECTZDR0v2GzGagXUV3M5/Tv5PUJOng81Yhv6ZRU3RmTMTGi56aQhNM/t3NN8vgamjkQGMoC4goy5TSX0ZeInhH72+Q0P
# DATA dg4vIlgvLQR6yQc54VCNjSSidZgB/BBP8Ec47p8Ddpu42WqJxrrDW1KV+hKTjn1I+hyNKfI0J+mhIuBZUu23wxwJ5Lj5B1XwNwRK
# DATA b/Ik1jCLh0n//ZGTQRBDnRCAhB3iP8XtRPkJtbvdsy9qYYMp7UWZDJy/wWTgXClMLe5QuzNZpWNQHsIMDc/+X4sgq4Qz15sW0yCq
# DATA KsMKKcY9rA06+TltS98zV23OsJ5x96GSZkA8iA+aTitUoUTHenLUiR469TAh7bDOHpWMMGIATYlM6+FoTTOdyhIDSeMHvxmJTLAg
# DATA EZUIoIrB0ajq7CG1yZOJyfBFYd8VHaFdoaDqCs9ihWU1+ANio90oBpe4kUtPPGU5ng6ZowmNjpH50vWUjWvZiJgu5jfYJj8vSXwp
# DATA V09ic5nHU4E7brRImH3Vic5n/GtIXEz5AYkBxwP+9tadzT2Y4YDZFXmNw/zrHha0TButh2yBjtVsuNeKaRTWCTCswXmnhJNe5qQc
# DATA fJchgm7xnfP85xWgOn9tEzR/IdOxxgl5mtqdafcwbk+KhtYQOI7B54hy9wQHDtzBbS1qAL6uAGOb4GshwmhjoH1hFt8zDGIz3TFq
# DATA a1EvQZ94IhNO1Ws6Ua/uCa2ircJh6/IipdVZRx/nDxE3SvJudlMgM5NTb9ld5HJeO3id6rs8cdNIGbBS24YJIrD3OYWTNn0+bH7v
# DATA 8nmicEJhOv7Z3UVwpS08E4yv4mnZMCGdPzhJDu/mOBUhBXnYndfjX9P1jHv+f0Tgv+rMyDzsLrQniveFwBnzJiZoYNHN4W+QoInI
# DATA XqHGPI7PnnQ+wZZdC+7OlSB+X13NNRZq+VSXD+pX1t2bZe4ZDrRAvP7R48wLTDtiOtDhvp10XqViAwTjuMByL7Lf48tKOz1W50JH
# DATA 3Y4695CLIQrIrRXkXSUP9wfSYPl3xSeMP/whaqdwaAl+9LnODP/si5Bn1K38IKzxzRWyWTHcVHV5hdlo2KfASHu8ZTQb/bMvKqCN
# DATA Mro7+gryAYls7p9HtXJhZ4ER4vn4twX4UUJJ492vhfgixjOtmAh5M+1POW0CsBhc8vcmqspBSg7Z3F8LgeNzlmA+VX3DbOMJDBw7
# DATA 9FsWIVASsbPEAqE20ess4sbm42nvFJugQ2mf/7WWhdi0jmpDw6eIdFjMw2haEedecGNa7oVUOQjTxKcW/bHH6Av6EP+ubYwfTqGp
# DATA HXxjNEHqxDZaLcWDt1pl8SWI6K02f1JKh6PuWIdJHZ0MQS/SYEwfzPWUYihZhoYGToRLKbgRVgZ4nCqz2/iN/Nvk1MU4gZSRfNpj
# DATA jXqH6b7g74eEe0f0K0VM5uykSqcFy2KCHfHAoUqAHhM8ZNTN4Dn3DwCmehON7UONZxPQk4tHGqSvyhAGOOJ+eyDcHLB+VoZ6j7Xv
# DATA lHSKGLPvjamJJhAaqnIH5NzkvObOx1/qcdBbZ+yYe8KsjgVtQLEH1YTaXyG6U6pVNqGVb+QVYItcfgHtJVTYjJX75Jb0+On8Nuxl
# DATA UtiKBogq6Czl7819T0ud/563EmGlF/YFEyQX1DRmHyQIxBw/zBqgGC8cm9pbRR2jPLd2NXJLCn2SWf2ihu1J4dDARjqnp7hN1WdV
# DATA ndWyjZaxRorbuIUZMYubRPix4TevA7CQqqeEc2C3XV52iaYYoi2zYCuMqWwqwEQXNwq/Ywym4FNKklHULJFCd0ly2/KrR8z5YqIQ
# DATA ocULLr7zKZ22xXrpcqVBl9dW5x59vJjsKpu08KhOYfhpUyO9nb+2F5ppgAjPf8sZ4bhRdmbnsvgPlM5s1D/8qpm73KT84DvcMiF+
# DATA JkcUHPBjpGZljTIWr5JvibqrsNE2Jr+uSiKeUERucfX+vVT3gpC1oCNr9LEx0S8piFj2u3bgoPgJwb87aB/2UUMCSUcXgxVB8BKL
# DATA oKF20cadOy7ciGNF0mkAUB5BDZ3zemTRU9DF2Tj9y6UG3DGYMuqvzTLD/Y+CAzsR204nDACdHUVONnn4rAN4IpjDAEZXNMoOAcJw
# DATA WP9iswn27VhqBKsfFMtvLJpu4IFZRGfuWIN5pnYEZT+nUoSSOBimxZtT8qR2eulBC152ydu9ZoEWCuvzOckLbXbGgMjDEuGLvaUu
# DATA KvqeH5QrSayLC06tKKJ9+6ADxcOMccfCTSricn9BolHIZwvpi4tJP31dzB32RRbRkyPkGsKLFr8QpIfrjzfGv5n4V8xRL+6EL7pI
# DATA VTNxQE43LrI/IzKGv/e1QTpvY8mtSilSEEOAqwtX27k15D3CzRk/OoYgImVaxVNi2/1vP7Oe/u6nNPpIjgDbEWTQy5GDxax0yx4w
# DATA +5FgnlvOVg5cZYuGVknmjcBz/iMHyN5gNJ04mBnojlC3lhjgZ8nxru44QeHLWfTYUzSMPfQFVAH9vwXuet42K5J1nWRkWGqhHbTQ
# DATA kS1sjk/vYttV7NSFjmmuZB6eW+qAg0yLRUU3cDEq4ghyv+YY+1R1pTkT5WpdxFpQumN6fiGSYvRI9aLdo0uV5t1iAgs6SkaZ6qFl
# DATA Zs5YA1VPcQ+5dItLF/U0pCH4g7+c0y2rbPO5gwqAsyMGiy4S25oXnUEG/vf7bLhO/EkMU8ns/ACTuZA2+EyF4ygtjtKNOFQyMOZq
# DATA 4DfiXjnAkxrTgmhWwkY2oyyPcLmecy0alWfhFqGTq4qVik6m4ccI7Zt+EIJqOLcgW8/ZL6EsXve5X6NoDhG44006XSxfpANaB7tg
# DATA H3SipBfdjblr5bQ1d8kM8VxAlp3bNDKj0GS+/yXFfiEOLXnIi22ySB8Y+t2uwTyGrXeK6aGyMxuFrP6ukWvJIIMs6asCJrmF9LXV
# DATA EmeM4wjLQZ0Gc9xxpxmtUEaDAruncOVfBH8QQjB/h/5dmGsqjNAxHdFZJfFHaVTROTGczWY+s12lgDgXT+SGeG8CX15/3SeHqozj
# DATA guQkBA/JgYvTbkjxnKyzBht3zhYh00x4u2iyTOmJF7puTYIHeZUUkjfKRiDG4xTMIwGRzF6RF7IZNzFjBRUlttHBUL6LTG50IeRD
# DATA Bx/fT3/wTW4ot4pNgHfagcBHSqEwp5oFbuEbl7sDtRnPYZgDzP+A+ViYLdHKLaPSryIIuYPaoJ3RjCsn+m/9weQLBu+tIrDjALnT
# DATA 0Id5kkpaD7RxnFwnRjyCsjIbj/NBNA2P/gq2Vp1SAVrqH5aiI1h3EwPLV+WYJrGe9EZqhseAbdAbGa5Wv65wDngZL503SYjBuOT7
# DATA xAfqV121A8cpvOTxwwpiq4eA6nne8T5zoc7HI85YDVI2ecwLHBMnlYatQXjW54tyaKmuz+Vil3Iyk2j1ft1T+KRkBakLGjoLl4zN
# DATA gRITpB7LMsLlNgIOWlQynxteWlLttnArtVo4/FYLNmmrxRPghLSQq8KSAIoJoUgAMQaRROpFTIc+4//8/G/V4f0NuYXn+L3MdZLG
# DATA 5hR9wdRlwM5QmLUAekHYlL2zbNI93aSMgXIQpR/BrsDeV5Ifds/4L8hswX9u7/EfiFHx53vb924jCA0+LctwrS1UzWB+hd7gqD/t
# DATA aAwwTJqQ1ZMBxpzj+JNx96cEucH52CFibdrvJ9BA7Vuevlry7F9sMNvzXxBgBQMIGJ/6ioth8XMKBhR0mdzr3cwiz38OWEsXWo0/
# DATA +S/1P3V4DvtwIarTURudfSttQBT4tatX8V/1P//f1WtXrpi/8fna2ura1T9JVr+LCZiCR7lq/k/+7/zfyy+/DOdDET0yZupYN4wt
# DATA 04lXSJfWA5C8cbffbWcA60MhlWu19dr312tLS/sn4LQqC/5sqjjvZHKiyD/Cp3FEBIJe9h5CHpeTbn+EgRcnQBUAmE+9HU4fnixh
# DATA ISMnJPu3dqqEGnrcbQMqDxoSISjU9pHzVScn7Udd1bsuuFKD3a5TU33rjjHetKNuykO4IQFZajA0xtgjSfsRovRJ92hKke6AFAWM
# DATA IqH2LQFy7LybJiAL6f688Zyou0Z2Ov2OCIkTkHL00+w/4Py/ce31Nf/8r69e+eP5/y7+l06zLvPN6Y2lJXUQsklynuyMe9lp+1a/
# DATA h3I0/Upm6MGPx7qU/tkIH64cYZm0fIO//enjiSwGXMbj7iFZDsqmhb1b2zuY+WIbsywhculfdUsHlLUiw5NT1/jXvndkVgeQM8Vz
# DATA 6qS3nOwicALn91mdPTfzCwAHr6ppQg+PpwOCohh3pxncjqXx8HGZc3TohHLDx8mf/in8U+MUJk5wsGwI3bxTVdqqZ+Cz7pORmqCN
# DATA CX46AFbpgw8S58WbmF7uNnDi5XLwfXakeP2spujqQ8RxaPCc6icffOCw2gt981qypkfFRZnxy9xQDZzPstsprglYwrMSfp003oxW
# DATA hb/LaqZnS0ttCCdPzIwr6e9RD0SMEu2uCuaW0Hm69BqAMu6llb88WK1+v109bp5fn1XN31dn1avmxxX14vr324dN54n+e2199upK
# DATA DTKBYypEmH9IwCAmDvICDI91lrCXSHkFiRZSKEyP9dz9ILmyXga8TLUzYN0YzHBrgPK4vqfoglHfddSh6bUhZcgNjR6n9g3tpeKd
# DATA JMtrNzAQlsBlKqFpq7VHPcz2mNUA4+n+oPezqRLnksdwD9bV8cbxzpIZN76ykux2s6lqG7PgJG28sKsoammMqYp2TYDmcI+e4SUM
# DATA mAo9DIFTPWz3AahgeMT36HEy7j08mWQ1s2ymw2qbvWTOl35a1iuMk+9PJbtBJUhLkqOT9uBht3NDGyGRG1D7Z0JiiIwwJsdWGirl
# DATA DOmr5YTaG3YG1YLmTCFiB8P0YfZu0UPam7BmlUSf2ro9tPCf2mD4uARu8muryXJy5drr6r/Xr13Few5AcvBo1JODWq1GB4gjVJy1
# DATA 2QcWatjvJA/HbTUcEruUZK9GPhpCpgBIUgeoYlPIOj9BVOOOQR+rqbUFlkLXNqTsem3YPe0jA0KGSKvOIgMP1sN9OqGlxjEyGxRb
# DATA UP33QsRDzCOtRM7sa10E7d1zmPNZBVfinGdPTN5s5iwzE2t1JdWA4yyd85KpO29MGe+B8ALIRx+idDZ2tkTARq+tFvMuWBOO+8Ph
# DATA GAkobYXOBmZvAURczKC4hotpPlTdyaHwbyXngODWBu10HSCPu7NEbShVMGhJfxw2NCsns4pwJwQiVFFnut1/OFQH9uRUjeTdPfCX
# DATA wD1UQGTfHo63iCxFyS1AYA46qEuUlDd4qA/UUb/dO81uSDBf1S16CpiYahXIJm+rsE2dm+7DceABNNUA1FE4AkAlVdXKcrKRdHrH
# DATA x4QVivpyxIRUJOd9teMtWYXUJpkiY3AW9RauJcsrycyx6HDf1Nalv9BwTHc57AV4wVcAv0e62ZD3gLgB8Xy9yFtJNOqcF0v/C0+O
# DATA JP2a8kNddTkac2LkvDiMT9kkpgkuZ1GPuaNtbbPwJM6533G3UgeQfaxR/i1MsNSZqqVRRFqD27bHDx9R8sIGYGHr+aF5odoBWEyd
# DATA G8WGnLubMjKTQ+IsAZkak0uXiOd9q0ZV/Yg0n2/ViN19q5aN+iDX1VLAc03eegvS47zZSN6AMx6ofBUXO5pAAkDYjyXDGyNUTXs0
# DATA WkGVOg0xW9GMNX9UHT1MyzXqzc7Dcuk8Gj+qBjEgrK493Jh1M0/qIqzJpL8VyBhVT9Yrc+rZJ3jbu72+4o3rivS0VgGUtNfpd71X
# DATA V+hVUN8MqBJlSKeRq9ZLed0q17Iu4GbutMdttaUoOpiyq5dhelMMSzsCmua2BBQU0uWo3a64gUjUPjYt5ZkSr7XcqprGuBhIPgdy
# DATA mx1qFMPTAzLT+ytidIBFAlaEyFvi5FgOD0S5xM+KCLGcJ2tk37t/c+/W7tbO/tb2vdb+9g8377Xu39+67RaHtNFkiK8E8OEF1e1u
# DATA 3lddxkqtgrMGHEWJOC51jjzcc9LF01uOBBSf4pTqA4jHTFHXWpemMg8g9Nlv4RHCkYGN3IR0/40AcUCD2e8wzZ8Nkg4CvuNa4b97
# DATA 9g9oc4tDnfnwHDUMfdBz96Q3uYVG7GRNXUtipAx7xWNlQvwqOojhcSqRtEMnHK72ISXsObdboBLbDRUtJ89uLH0H+p+WPf0vVBVc
# DATA rP9Ze/3aVV//e2X9jT/qf74r/e8O8lF27bUXK+ZMADWrOrcoUQTqE0fK6naUBIaJtdjKA5Ty2lX9CxRB+u9htoSoxuCr0+8darMQ
# DATA eAnoIuOu/gvMe+ZvA26vn0y6pyOQ76jC6VhdSYcUeaRrBZcMuKyXTNWUS5VjlsllCr1V0aOYNLjHnUWw9DR0nv197+ad7Vs/LNtc
# DATA YQCZ16FEYR0Ie+UEMZQtTNgVCVsYAfYAWZjee2lHBMAWFKrttbb2djffKUl0WgeuVufkg2QTsewL1lhYSrfu/WjjztZtvlUg6NsF
# DATA dPFwHQnHRzcEbDHDQ5+v4lSpC7yrnpbKsyh+7uobb5Tn9cj2pHUXbqubm62d3a0fbexvOiDPeDXxhNrkGq/7yTWMQ9yS46hNK4//
# DATA dXK74BPeItHCTtIE4RKAb9EVAZeibz4IF2LOImh0eNqutcD9jzuttzH50xBepZb9jQ9LbndtSd1jCs9i5HIegf4Ng1hfvXodk8E9
# DATA eICJQmRZCEYbjjulozLow67AI/6puPS19TcoCkt+VV5kOnY27m3eIW5qiXKPo+eHTCODgVLcEZAI2tPJMOL4oCeTgEh8NBSUKH0w
# DATA I5nXgWezdL68zM4HOnoPIxbQm8GJ2JsFJ9dWx3N9icQO8dlSlGfjjp6rexs/2ti6s3HTOcY8bxkFH8pWOX36Xncy4ZTppn1+ZZIb
# DATA +7UZyGskDxL7zDSnE30ziShhpmrEMxn3OhhNmw7AHbDs4FljG6QQ9XvbPu2SkykAscOphpy5/kzr/sXyQaQHG9W/aFf/CvCZ7Z+t
# DATA WrWp6JfaqLOUFHsXmvR7m/vvbe/+MGfy7fZMUghqra+s6NzgNscT4NvxFkUnKv1DOqyZyeAFAn5/Z3sX3W4pDto4U0rPIdG++RPy
# DATA AWA/5DmmQEOMu+U+6ldYl7pPVRX6VrWkQR9D9aaGkptcb1UZAmZgmK8hM1AUtgLOgXoGv7VuTv/WsHj698+mXcrxAT+Ox+2HyHyY
# DATA wurKNa0iHCy1hi/h8le0YfUyJMcd2EsNPRYT0cq7rajud/f3d/a45t3N/3Z/a3fzdurcOkZnO7bbuqKrVpR+Z3f75iaQMcVmkd5C
# DATA J0NVwsTGdHIyHLNMWk/Sm0qgVmQGcZB88e+9jR9ttjZ2tuimUeIFOjhHS5mZYOy99wB7z+xgUkxxLw7SH1eV9PK4Pe50O/AXunGl
# DATA 6jzVVtX/raU34iV3xkNFrZuJmVWQljytJWx1ZNCgPRp7+xBXFCX0Dfj7FuH09CFqt2JymGWkQYXQbxLQ8Lsa/hfKXQetqpLItWqI
# DATA VWuoXM+6Rr923AXCMWeOGCtVkU8eKCA3kwdyPUXRV21K0EW3+3XqBv0gLRwatnTDteH72p7E+4diOtpH0AHSK4DaFZi8xiqgBEwH
# DATA 72eNgya8ADJM3S7RcPAtWmR09YfDzpmaTPj8tQa+ZlPWjd5xCZ6+eXUZczXAf8rnzqTdiPRLV6x6NqO+1EaQXO/mFBS2NeDPS/hc
# DATA CcMzM83oLtZALzHK4MrF1dsjxQdTReXaZEh6LeTmFDNnp4t8Nz/4QGtq8fdLjUY6RMsyWuqoUM0sqVfavBCfRadeDHHJnFm3CvVi
# DATA pmGwk/OjvjqDevPhfoSxz5ZKuLlL5cabZjNrY3eDlg0p+0p71FshY/iKMYaXb6iBl7j/+ql2zYQRsGq6HBmAgWu4oZtlA3jYap6p
# DATA XHyrqs8aG+Nx+6zWy/BfjuzOym9pwzr/W+N/1beq8y+5H0E95Vh3ZZPqMyh3sNp8izTiC/d4JX0NQwu793e3bungAF0Za9cVwSmX
# DATA ykZlpdbF11cJXRL5KAqYLwPM+xRwuIx2Ckp9Ra6IhLT8GT2Naqbwcqgkqgxie0FyAcpYQrow2wBCEEuwQ0yM4um+1JT5aqvG2g2g
# DATA Mui/hCKDKnDYLXFkgpUDWIDhS0fRFQodrmgHK2aJ8iWoUMjgNqSEgY+KLsudjXc2W1t34b8hP0VpuFn0r+13QbBvj89u61CPEoE1
# DATA QCJFnfMLdwQOuUoi+PGwrwi0Aw6uQ47oVZlDmbVKDKKkbIeZMSMVKGI3p5H7oCHZJ9KRRu5fLOWoUWMse4lXwkmRchnGPcD2R1tY
# DATA pPJ8WYTEf5/L5j8F608FuW6b5S6WNwQ3l83V10SUm+4RpjqFCLUqYyijm/TgUdnszAOosqkRt6A4/BdZJQ9vI/Ckx5bBcXGAbIQY
# DATA iRJo1MKOS2YgVlopL9Z5BmquVgmDrlodKekDRZ0uY9RJHCrqRT44aN4c4HO1oLjBUjsJfOSic6F9xY0ruHQaF/kj98yfvnN43pGF
# DATA Xb9x69bm3l7rbXVigb2l/GUopxPZAT2hRQDBNAN5xIdbVCRrl+5a9b2ix90O6NgfYSZ1nhPSPt5IspP2mLw/Esq1oCjQmcgPCdRP
# DATA OKJTthmQIJZsFrk4NA9nZ3KheNjZXTHfscOf1sXI0si5VwVwwLMlnTYB6rKdApKDKXOyko6Iom5IIFL8lsdNcEAaryFa0XByAsjS
# DATA OfW4yWNYlq8k+JHNTyEnpgY1AbC3FvJfMgkH9Vw5IBLYC8aoIsiN8xSXSk3G+Wy2ZJKcw4DqXoK/g1QIwigwnC8va1Ks4+ilrMw5
# DATA 3XRWDPMpaBqWl2n5ZhFhWUyd9g12KyaIifMUHaZU1/WGTmHs6jf8M6skwbap8J6xV6UvN6pnstf8vkXZl+YfQXVfaj3EXQjJvX9v
# DATA 7/4OqAeMrBlqgiDliARd0m+J9JuPMN4tpuypWExb/ancFmHAFOUVgauBuGcaKWh1UFOojz/iRNoLHIAVHS0PdEjqmcylJFrULw8g
# DATA jEu3bC8reu504KWGR38WnO5b2/fevrN1az8yzXJ2MVLtXN1tE1B09NVeoXyy1HxdfyPmvT2ZtIF6AYxCuDMQMDjl2r1MnmIedCU8
# DATA Be7I9Muwn7OiQDTRMXCgLUHNKOipb7PSwbJtEya5XA5OsxkChntxacdhBCFaiD40nYRBSPBL+KaifQA58q++5FIvszkp9wvvTEFb
# DATA 1FpAqje0V9UOr11lywF+d5BSpANkBfIsCgSFTd6HqDTjD4gmNHN4ReoTtFnRH+DZbgbVcW7B78z/n6M6X3gYULH9d3396htXPfvv
# DATA +tU/+v9/Z/bfvbPBkZK9B2AshOAU8rRxPY8p9TacobZM0EAueBZFGvkrZPgwLcaTibDu8hNO8KeNscdHg0lf/wB4OvWF/mmifV+o
# DATA DRkE/stYi3+4+RNQUO7dv9nauX9TEfrW7e27G1v30qWNvb2td+7d3by3j5EPyIhAloVx+pelt+rk7nGQPJg0Xyu/FXyOL5YbteVX
# DATA If10t3YXLHpH/XaWJbfxONJVY28dg6+t5oUI4mA4PgVnJKZYubY+vnylGE6kka189HXyZvL62jr5VbJTFiSzfJA9ePC9t1558GR1
# DATA tfrgydrxgydvHDdTJmGBFU92PaWBtli1ztejZ0ZgGi3sEfQkNEaIuOdcpfyCtgQG+yBzAYgoleTq1StR88TFBwhf0ghNJTXSQ5XS
# DATA XmfQTs19Uq71Ieshm6Yd6dwJeOc/S1CdE/VrN4fAT4H9EV7bi/YeVAKwJ7AtsPq+jtbctGbSROP41CP4Vw2sQ0l5wCUSEmxhPlH7
# DATA Fxr8vKQ6oKLu90te1lR1YlafaG/Y1z6Av9S5SQGqaDwpsygxNj0QjphB7YifEbZwwHY/1RL/iVa/a2sz/ab81kLtXWLXc2o8bas6
# DATA qFfXmnobU54kPZFoucLdr9/pdelrVxVYlqurtCy1VAtX8JtEQJtyxxn/Cg98o/oXarC11n+vNl9Tj1b8Z+VlmnbIhnTxkTIDh7uE
# DATA jCLC4Ua71IwoaMTh22T2QGxcUrNIdkCdS9sgigAhgCeL9FlJRxtvg8i+/24aOX4vwg2IzygAq9wbTt4GBBbvqIJ3Dc9EPebAapwc
# DATA zFi+Vf+i0sUdjFbXr3Jmb/l2ABBJsBprYT5QW+rivkPr61HBbLH1xcRl7Unb9xkSQ3gtWSvLwwbFy+4wL7e3eD2hPnUY/szjiOBw
# DATA 9EF/SJ4p7nHQvio1E/AMhPX9dI632nu7elPe2t3c2J+3Yysyn3lsf7Vfy9lfEbe03M1mttI3W8VAjY28JMTQHL3PbVb4GYyttflj
# DATA NVzx+97NQCV6E77tDR5ubXtHNKd/93dub+xvtm7e3/uJo+nUn5z1uv0O0z1ebbm22isJoTjAJSkr4WYsdEwyW1NkWLepKAiYmnQl
# DATA CNltC+WkVsqf9nvb+627G/c23jGqI6MvLMidK8m1zc4c0Gz7yiHctgWnTBxy7SI7BvgvTL0bg2uk1UDcJ1HGhcRakuRRKpigYsYA
# DATA 0lzHWvKDBpIOfFmGX2vX8tgTry5m0OHyjjAudEGjo9JaZW39unFUcj2vsNlYg6IxHm9e1/k1dv76JfeLznd8bpdVp82qEyMQvhBs
# DATA AcLVzZYs4BvWNbOJk7GLlOAMOyvZXySbsnoq418Chh0pICwG6VwcVLwUApOKtKTcH/RiwDrFc3hr++7O9p6nto1QllC6i6aOLkfV
# DATA fRds3rJDsJwHMFmgr8NrzJ0i+5J+L/mmBLM5o8j/UcsLjgi3uG+zxBuHysUMil62uDAHdyxjNp6Dg2asKcdrluuJYn/5LR2YH269
# DATA MCmEAoLud0HKZFlXZD+X8NsDAsxueupefOck8MYnoZWH1lQ30dQnQj9wGCFK9aw4oSvrl6MHmgGykIxMPXkyeRdpS6HqA0r7dNiM
# DATA WgNPbi/zAMV8ZhmpJs4/6qatkgYDI9G4i54znlK37FxgXEl+Kxo6jgseKHkOvEpYSmwoarZWPlhrOs7nGhvuoA7CH3gqvqzKvZy+
# DATA LPbRz6ZDZA2o4KrM/NHRj3EgJSxZ0Swradd7ffMplFcMbd10gV2lIVpxldUrqSQr8O4HCYqVJaxJi5HwQ+bfTV9JywsTFlc4lDNH
# DATA 3Vyrq3abEYWFLgbKKJxUdQ+iLu0VrXzCiEZ811gr4+SLuZZOWrytdDKH0rxtaD1dsAd2O9KZCa+upru+4R7VhtAK7+Fck4RInayF
# DATA I+1RFZzgsH8ksOhUk07rfJXZ+mpkjwyQbIsJNsmUkMJYONXHDLAF9Fz4lbim2bCl4wS0r6iAhjbrUTcJPQ9U5kB90bSeSjLJinO/
# DATA 6698JerSBa913oq6MdImol6DOeeHXdQHso67xlkMykvxfcEZW53tIVqj6jQ4gsmVoBWMgDhxmIKuFjSmJa9N3B41qoLogaaoGqaR
# DATA 6MJhetrLMvT3cQ7TeYqDVSwcD1oJKhS6qB5xz066T3QDOlMgle91ZvocWrsDh60QpkcDQwAYSQskIZY1UHCy0oKVUUOh2ZFVck43
# DATA hxUYkczmCyFks8YFCIWknzSI8OyLCaQWAp2LZOawEmGuzroTfohikl4CdJIaIeTJrl6DWUzbQt8ehKWbUB116MCuY3NxjvHdjXvv
# DATA bMYIuz1RunHqM2VZ8p6Fu89hd0+HHcCV61j+/9LktIiUGkbfYWeX8hxjCojjJbla0Vn9dXQjzeV0L0SkfVa4iBbH6LGWHXNY6vyu
# DATA 59+U+WOpjYajkmreDxUKuOaot19YH14Umg/JLW8yi/kOSFRJ8B37FKDA2JmejjLj8tYdZOBM1M6Oej1SfFcwzfNg0ljXCXUXcFvk
# DATA BpCYw/wfpmngoBC7SPEMvORKEsS9GEZPsMps/4PGcpYxd/dxB2Vl00MMysHagrWnU+8Vh22mpqRhDH/89VLRTjJ05FID4n7DPyYM
# DATA B1xyeWnUP0GnYqsGblxQhbmRXyKJOWxU0zYjOzvf+RK/Lr3IxWIyX2mFos7szfpBJUPGUmFUYWBgJkfn+KulMtzmTkeoHldzR8++
# DATA mUqX66WsBaAibqwO3wDYEcrUkJFGKMexxuafOm0PesfAhXBmKutheOB0L5psSicSwoc2zTWnssKUfFIPEr23PD9em8DK48RERWXJ
# DATA Mi3UyCxg2LG3FXPNdQfTUwQ7LelNY6eu6WXOmqALtFB8hNp120DJXrrleEMRllVsn5gJEFcW9pEYd/yAXoQXEY3mzGdOG/GdVYrv
# DATA CQbs5toDjcJSce12Mud/yUuls6W5ekttxGhn3U38E+IAgzXUu2MMbuiZ4pu5zosuFaEyCcpVz+MVvJkvvujRljsdkKp/6eIXe2xu
# DATA F14ca1wVRNWIAcuOvPBfDel7Af+/095Dxvd7oS6Axf5/V9bWrlzz8V/W1lf/6P/3XfzvlZdWptl45bA3WIGgidHZ5GQ4uAJRYtsj
# DATA yLyeTEdqT3S6EDraHli4zACX1IGOBCxOzyuQ3ena44fob7dkvAJHZ+SNB5oMOLnaE0//pkDevwJp8Bu7AQbwMZCJQCPJgJfffL9A
# DATA 6UW4dOmEU1Eomk6XplTdaDbGnyhdv32oyF6IhHCLAZCtKu0OlnRivqTVlioyVuMaBSxpqVCnX6mBV7ZayJb6lIAWNGAZvF24GvGp
# DATA lYXnfKpDJeyngS1Z6qA5vl8MsQFB/w4YyUl7jHgk6waPBJ9ISBL1AO5Em2ZMi7R6yK6Em28PMOgNMrONk9SGh+PbdufjUXDb5fzG
# DATA tcFpwUUmiZSsTgynwXaLijv1xibMBiD1iyZTm7DpecGsaLvPkVCmNYRajbvUMMm5eLAN/rcSi7kzxvkGq+MwmOq+OpkNOIVSgilr
# DATA nBwdTtPu9xSblNmD5gedZRxRiYGXlwZLoccmllaHU3yj46y1sJg4CHXV2n+UkgjpaAcr6yyX9GgYMYQGr42dEAvllbh9bw9AVkSR
# DATA EA+nCIulMn9k77JTLGcLtFCyF6AP9FXTSP9atUyp1Mhp3XGKdqSaF+GCnAt6cu6Bnsy+W9CTBRwJ6VnJdr3iOivzpqpYV2kwCV69
# DATA esUbcMP6XeNUXV8t51tPTCaiHGpB60d56iZDyixcwv+KLQUKs0dqBoBQu6e1wmHcxbg5leh7bIV6zuEODXcjuUckFvCJm9KQTh00
# DATA kWOptsYhjrhoJOdOe6pzGJ1G55qD3XSYLQcfqBbf3t2+t9/avHdbP2MT7yPsJ6Rln/k9GnCTQZ+MjQxYupaIEkT7w+XJ4JIXdJh1
# DATA eb4vQVEBbV5xZhiUX3L6Sc28ktxGkqEx0TL2/WofjYdZlmCGAhPsbULYJkMEPD9C30rMvciV/RRg+OGV/oRjbQmDQD2nIJjDLjC+
# DATA 5MvZIXz09ulh7+F0OM04LpejaDP2ZIavtIZSTgYEyOMLLC+eNXg/UsB7XDhmSP6SiMUviXouvGZ5/8P+4W46ICcG/2LlOGN9qZLN
# DATA xHYqsm4xK4sJPLYHXu9lM7sFB+s4jkrgul6bUTAN9UfC1CceExqov+0pU8tlkK9MI0C6ADTrUT52V5R0m4PpjJE9SzWcehZQykyQ
# DATA ygbZpAnvvwVpABy/e3Vapv2JVQJmXQJWVN20RmqLXkdmNG5FJsgDXNAFGJstzCDocJ1/hmDapqrh4wEa/LDK2pgL1cmlZrVJeRxP
# DATA jsa13nClP5yAH/WKDRcO4GAcJxcxCbSVoa05KzvuKgakx3KU26kV6lR1zXj+1N2xoCbNfG5YhLCTTshz+Ho2f/dB5Yvfn+g2Zn/4
# DATA ema7xHP3/aR7Cg5qMRnWiyAvBeADGo9Ay43mgQmcp0ByaCM0Dus3sJDQAk8vbGDfzRBUp50OXoreKYPNr9WqUJvj8cDeGFQKo5kb
# DATA fUV/Om1suK5HVND9svECJ6gQCDZWbDfksURupCFwN9RP/0yqR6WDZfFRkwxhDYodP2qPIItYazidjKb64YRwpxpr11cN0eRx0rBA
# DATA EWonSKQO5Rh/Yn8dmQKaFrY22MM6B1OSjlCKZIxM+HOK/C8DoWSTIf1EOBQNhoIQLzOwuzB0ivA2pcQz6PuFvabsixjvJIB4uu2M
# DATA gPtLbsKjFPK7TY9OEiExQMLH5x8++xRwkpJnXz//+PlHmCUSkkp++vwTyPmYPPtUZ4xMPah5cKF/f6BIRXLcb+OIGcHpI8zUy1wH
# DATA f6yhnxCY6TNs9t+efQHwTdSKl2gybAsyhYD7zRBgTwa9bgcbFPBQybPfqu//gOkr/yeAmId13GoPGGIUQIw0j8Md7bS7p2geS/kB
# DATA wllJ/KnPY3UyjWizq5NQ9eD3v8PUxh9iYs2PAe1KzUw8n6d6EZnosreyZjeiXRY2I2UopP1PhgzaAWpb0isjDvcGehPpR7DRGI5L
# DATA gm/pCfgir6u/TOTWefY09XOAaoEizCJbOk6f/SNleFbT8dmzp7q10rk5crMyb5ffIsIXdOxvMRP0UwDGr1CvPkvOg+M7q8NDGP+s
# DATA lsg00zrj/Kfqn0/xY0AGg4Smzz92nXHt4VLEwlIpdBIBglMijB5UsUjXrCAWJISU8Zy1YkEhYOgNNXhYny3XHhyduBIjzzasbgmm
# DATA 9ylmhYXM2f86Hx0tZ6M7KrQD319m5HRJxz271JH0YBi0hnPhBpCUm3IWTFGtQ9OhjfCiVHZMdYF6zR3+/3LS2v67oUDfaCJ4dxhI
# DATA q0qih8NoVnTuq6zCieo9vVvRIyWiErtpSIFu9bDquoMs3DgdCPSkp4MgLsfoynqQVo/5S3hXbjY1VghbLyhOqUXWQIbGQmUhPyID
# DATA b4u8EE2Wa851GrufVWP9bnfUIGRu+NOiWMlDYg0PsSwLEElnfy3lAlXb3vNBIl6Lw5Rk5Xe1Bc/GK4UhWnDCgsOK3BOXNStmS5pH
# DATA dYfj8/d4YfAUpk5phMSlvJQXZONyS7RhGAItXaYtqZmPanUwrKJqYITpCswzgAhDOoT5XOnxMbgm4p3FHiKwwsB2+cYKj41b8nzz
# DATA HNdsL/QGZZ3cM/v36qT+hg8nXZLuaY0kNFmEYVmSmPhIRe02L9co1wHcpi4a/jyIeccrFix2tY7a8fAHe7WVfZV5BECN/2w6RQ84
# DATA k3xTi1TOW3T1Sw+nvT4wP9bdz359QTgwV4PnA4LNh2izDZOWWrfpVdx3lPZQc29YM2KdVmFXIduYqj8iBc6WHPctXEhBo8qh5xbC
# DATA W4JuWptNMfOgtpzWppMjXPJjeFJKv/eT751+r7P/vXe/d/d7e39Bvm1Rr6+D+nVWNF3ANQsRHxLtEQYOWRSFimeN5pFdKmj2iMEQ
# DATA QazROakkDrR+XR9CiEqWwZz1xGy12VLoEYKdq5gelJeKHMmo37T1tTPZYl9qc4X7Lf1ieqe1Ns5Mmadittw2RPI8efget7PWmOA5
# DATA VYVWBaZxPUWuBCOYtzBUwSOyJMVVq20S0KrVn017mD7XzLcmln5Qk6zXEj7bgQhhdxAzreQoaxLEWWpU3PE6CKO5sKUckMHWicEj
# DATA AhGzPuUiiYTtv3Fj71REygOBC6uZ3OCUsrlf4luy1qBV95yXZWck5GyIlSm746Fl5vhF5mwY143KVptnPYngw8ZMIILV1zXWl8L0
# DATA cjUHfTgyKFJWGvBhnjihAann61LsTU6GEJra+ly/UTFe7+CaSiIgIcFensMqB7qiHEY4oiWzfK7NwtmcyxjpA6ynJpgHGEFv0uJO
# DATA axIp9g1NUcgal2MrK/H5vHlDy4Eq9SjKB1Zcrhe7UQ6kKFPRK8neZDgaIQzZQw31mtGjWrKRaOqAmap6meozp29F040SdhNEhdX+
# DATA SmoGn6CN9fbNWrC21Gmj0kLGstPVpFL90ExKBOd3We2MaocidCXVQkXmAX2OLi0gIYVUVqo5xeehY2cLlSEQVVO6tlqOR0RHyL4Z
# DATA 2iUJv9PEC6X1/p1CM3YexjeddNt9DI8uvgbexWLyCRSZZnF/4cWuFLLUcQdAH0p0K6UnZ77CPq/+PPsIekSTTQUA2fLpckCRLQeL
# DATA dSBVne81y9LJPxnVJcgZrLxE9HrQInwF2jNSL33NQsxvUXe2UMLGOTqJNG4MPFRH9/3YMum1b6izOdCzjhFvheunV5502B0lGJE2
# DATA WtGhTt6ieZP067nymgX/f/63oMxLpOrx2e+ef5I8+1cQ6vARg/1HZwA1DKX1ReDMI7qhj1Et+/tnX4M6EDSzX4JO9mvUR3/GA/jV
# DATA hVYmR/RfgHzH7+BWv30GKTJI+/HilRZMOZaXNfNur+i3OTIkNqSZyzGFrINUK+HfjuNLjiO+roKxXs21S5fs4leqhb11o2I8fv4/
# DATA 8MYid3rSxIHsVjKYVuMMU/Nob+DaxvjhFMjZDr4paSuiGnuj1VLXRqtVFl+CDa/V5k9KqVGjE44+6BsasE2yoyEj7WeKXdEmKVQI
# DATA aj6C1IrdfofUiBQXRewT2z3hF5nVyIjFqiUCk0F7lzZkI4lNTQRRFWQA+KmTrqBpF9kmNIBhhpPpuC9VatHhVVEyx14WTEK1inEp
# DATA EF53Nuo2TEYutNg19Df4D3yVWbENftWE9U9RUjN3eTwzfYPTUpH+Bw4FwELkVaVuc4+7w5fCvOw6JuCO1nJKvI+8poIPp6X36RB+
# DATA Ssvl8FL4HOfMRCCyNn4VHFzF6x+g7ytX77tnBBenbwGji/IrtAApsn8hOhvVBtOALLUxBXNVwcAZUe8P7LCaRUvL2Q0lTXNuG61X
# DATA l4WpahLo8G+W5PBvR8OOT4wsgb+Mrt1o0e3uaalTAvZztWgtNCy0WrgDWi0gKq1WGvHtJHKT64ZoUl/8sHs2P/EF6Om7HrzqGPx4
# DATA 0mf/glf553R7L2hxccx8YLi9kURskqzTrZDlkZMAYd5quNG/fv4raAQqI4slXPL/DrVD+7VE7cSn3BvIPIRNf4rffoSmMuThFE+A
# DATA LF0lUZ99RJmMQBn9NyIpN/bsC9i7aCzCNgHiFaTNBsQ/kFVebMUzyjlUWvs/I0Lq/+z/OSp/lKNfOPz7nPivN9aurr/h47+vX3n9
# DATA j/Ff/7HxX7sW5h0TdXTHhMBB2v0g/iu7oe5ORcsPexNIxaWdHJgZzRaLAQtR43X2xBb7J8SR4i8fEYbZF//Tx4ddyIyMfYzHdVos
# DATA fqt6M4ndKsJ5TzJ1zMD3AKKiNzkjk23dAXl2o9pL6YPVtPbTIbjMQ7w0SFbvay928mGXes5UuBBpS2u5bLGMnMj4g/r61aZBkj4a
# DATA jgEz1QL/YNi59WGlRG4CAMEgqgb2pSzV/DB9VAg5KnPAMJLB7uY7W3v7uz9JXUQnieVE9T7sDw9L6bJGc3V8kbUPSKThizQufAQc
# DATA ztENF9ftQXpJVDNFFniRRLnvQPu3tndvhymYoaZC8FmzZqHrJTnIR5ZOgOEumXHAI+s8o93qzfPIhEZ5axEDEqLsyj2zQ9o53dB8
# DATA mN1gpNEc4uT8+7j9qFuNWkAJoAMKArQ+H7FoB+8rggSZgZpo2YYD3x4QQhfIVrNFxmgliG800GLZhLNBDHo/Q9Aoge6KOxhc/6Ey
# DATA IXpgUZmpyN24ZDhxcCvpkzhwpdzT+9vbAFj5E9zUe64jFNWhI3VZPnZRx/DSbHeq6FVunaqHxwl5jZIh4hSNFUyvdeCJkkC7T9pH
# DATA esfqNHUk/ngQ4EUHwWz6ludOhuRIPo/RNg4snIm280+JCw8qSkd2h21+Lmh1Xncc6U7TBrYiwFkS1TsnKmhWOhFUxIFLy7OAfuHH
# DATA 0XgMYYXodTJhTnGsHDkmFR3xUHZDEgZqJ2eUbOOaDmCOZK5vV48hTPh8bb1y7eosjbsiQk2LkvBb2/f2N7bube4CSufmvf1t9yIx
# DATA G/kiVp1l6AA57avpIcWh1Tio+Rg+JjQ3uwArORQPwz97w5XCgjGFvYkOmdPERYJIZmEcLPIbSKwcqiUiLHLMLvZ2vEB4TCQQBvzy
# DATA aUKFTkdHDoiNahVkYikWiuqJAgKJKmuQzU5thjAS6cBU15RRm54lI6Kh0YqZ8gLQznLeuUfhfUTOZCZEPI3hx0XHyG6LOT7OSzEA
# DATA G/QpYbcE+IcZ+2wWhRK0hzZig4ibomSSFC8aOYJcHWZNKcbf4WR46rIxeWeio9T4owdkAVnGdnioOfGJUbdqmqmccQTJQ3MtqsHV
# DATA ZkAcMLMOQJdkRUPPZa+Rx/Wgyry2h1lNZz9NB1IrHYIOYiYW5rzbk1K5CB1x0SQppViWFBldSjND3vbwOCi/trq6Wi4XAyYWT9D2
# DATA e+oKiWdHjvn7LpCNuLwgrDsRuwOXD2w6zoUcmKsYAnQBm/lcBlWxNDc98kL64hgPw5i3aLRgtrHCwDlIvFuWp3TCMkPw+VGQTD2H
# DATA QVhH7gCKFwqwjiRnE4Cx/ChlbLyasL4lGXenzScYe+yNpR4ECHqsc3GdczPEA8Y8Sb+bu5u303yIlUUQVvygvUVmbW9z90dbt3Ri
# DATA +leQJGeJooHIr1cpiFWz7Jz8F1z21BQkh+Ph4wxv3dF0ktWWggvhIOIDthy7JZpB5ovY1TA/idYldA8+ccw57nwS4IGG92csqRZl
# DATA g+UjEYLC5MUb2SCRmh3JgiA8NjnAAZ8n7ClfNvo3RZfJA8Cwhkshpc4LgRKT3PDS2/hOChDfTz+aUnrlvmIGqqIduXH35tY797fv
# DATA 79GS7G/svrO5n14snYEYu81psKp99gPa5cGCI8Y3VaGzGYfOjkaFYdlffoTc7swo96bAHgzHemMMpqeHBg8LRW2kIwnHcHO4OLR+
# DATA w0RAafCyUXcMIR8Zhj9icDQeSvQHBP8KI2+DchQTgxlLNvaA2+a5nC/vxcS8b1nEu4x454gwL0K2E8cqEIhEY0zkF3KtgxmS8eMy
# DATA Q+LkaCRKwaodQmqPwUOLMLSjli8tE3YG5psFqGQqBJ3iPzNGOXIkCkyAbQqA2tp2ugBHA1qUaCUMhNrU2CS94+MuOklu7djaT8F1
# DATA FXBFkjb2s5bcwxtCSTOwj9sDYVmBdCZdQFaIEglIt5d/vq2kFxzvuQH8Qqeb38A8SWtE8BAuq8ZUhO9Ij+kQL9EY1TAlQ9bBFpM9
# DATA FJ/m0jCu4NyYZxhZy9hmvMNnaw2cxhCfP3ThEzTFEX7mxs7q01+eLyzOFkpYj4y6SfV0d2vv7sb+LSnbvJLsKzppFgQOGGknNV3V
# DATA ywf31aMukt5xdtIbAbjOgCIzEzI6qVknqIyAJY7dFnJWo3eGLRC7ORYMSw71iZFkdOCR0gbP6NZkiLtFbIV5uXeDQ3EJUJSlHMgR
# DATA owxi7U/NVweZPHXx7Hl5ufcapGAWT4ZjT8gyfXnpgsgrflUen23By/LxUHJMIuVyEa2LMqJMMPXuLkMipEuYBWjnRdAB52H48UM3
# DATA IjAEYZcAmLSD6bH0s6VHJfqHErlQr2RaJ9e7axFDKEQXIp0GiGsyU0qjyjdg9+woNJunNfjC5ijvKM2JhGtZFLDgy3F+oBpjYlAr
# DATA Bcf2OFmEN/OxWhfkxlzz0iXiJSgejqaxT6KUtEb5eE7aNB5erqHQEwjpQUYVzc3C8+AIhQ77ZBAUNjshdOX0gT6JNWzZMK3VqaBR
# DATA M2KEnHfla/OW0JKH2R9NUIuzWV1kIa4nGiYnONzgo6nJNzovRsXL5sqPQbWlkzS5o+c7J9qj+TfPXEXYQuovO8qK6VA6HbQftXv9
# DATA 9iGFq6VLcRCmFyNOVvIUmin1C/M8UAdTdnNXjw6Hw740rBuRpKA+8gOv0zgP6krAa3qGd6zVdtO+KqrWKi5zt/0sgucikq2fcXCd
# DATA wYNa19FhEPbC6YHwijgdKno3HPSOMIEYl6fo4hPA3ggK/cBUEYv3jR+XCx8V10HBlQ49l4TdLoYl2PfhgSlbbmNsS8NGcmOAgu8L
# DATA TibU5sV9RVH8cobk1BP2wz33Bd1wY6CKyLGFLdFBRYXq1Y3boDHQGmy8VR0FtnHMtzpr66tvmTuMGJFIYF3xSFOz/lCJ04vrq7d3
# DATA Nnc39re277lq68X07DZuxumx7m1Oj8j1u4gzgfgZlznxOJKm2yCGM1B7OsYGG8UKIO0m/LW2umpid46G/eE4Um25XF6KbLmivppe
# DATA cNiPiROK9FEvmNb5lENWK5zNlxq84pLR0lRJ7yrjLSJvaaHqmyiJhTR9oMHTq2twWNCiNQEfGgCC6E1UOVYHQlAvAPZ1R6DxwSQr
# DATA Wtk3jz/4TwtX46LUWLiVGACNNKpERC5deK6dhc0coC3Y27r3jkaaQc290ffJrcjqrm10wATLVafdByMRs5+QLQLBL3Cd2B8nqyVa
# DATA qzs5aU+EXgGWnmtE91bYBaSSeAiqMNQzTB4Pq3pD2OQT2tbS1ri9uCVqDMHR6ZwhqlSurgBkpVu6GLEqqlctChZvAF6HepdqfpVW
# DATA wBkS+eC5yeNjLABdN12TjC9Den7uTWtFt+h6EsC3ZjARP0jnnVUF0LHx2CYpUutskQYJyQihSjRMzh8M6DRjIiGek0CerF9ZXVt9
# DATA MJjJBGmnQyWUiiTc2QEPi/Iipo/U9j915g4PJCjuGUtZ2EMf6TSZ6KZOFUAMHN+IoGNNc7GSuTyH8+EXBK/AE+bWitud613pTo5W
# DATA sNyK3SCkooPtQEMsSzRbs2vs32C6p2G5S2iRmtALWtGuhs5YBI3rdbHk1tSol/yFbLK6yCmNJ10z51zAxhCCHaNt0e81YdDtUb5q
# DATA 2mZdqCFrUWa2WdkD9OYvHWFG59usWO2nHkAk0VgOBXt3Y691e3Nn897tzXv7mp5pbc4C6FZ5yfQojZ5wd6zGgZniCfUuAKtkZNUL
# DATA ICb5yEhN616rE5jyhNeF9neTr1GAM5+2+xxnTNc5oGwo6j1UMqcS4G4wdIu+JRM1Q2rNRV0O2GjCHERyCqDqpFzJQAxQhLw9SMQk
# DATA 4j1slcaGTkCvmygBHpuw8wMBmSzXAWYdqmnmVqMZGqglHQzTi4NB2QDJ4s8WLz8fOSr3Sxc7yg1ep3s315d4MTXgJZySCfm83W9R
# DATA B3xXYtGtMllwzG/jseVBPpsaTYRAjm+y9Usuqs7Kq+ewK+rSqZjPmfUmhhKzcuz80MGirMYdB4HrPx4sKHeLLAweJJJFQtoDLyqr
# DATA JOJA4+HRHsJQzuko2MoagQjzm6Qm2Vi3xYHDPgaCWQcDnE9hy532pBtswmh3glAaj+5a6AiuNTDGBYse1WKH08/y8XJwFV6wHkLa
# DATA RvEBfd3DCvnmXmDHS2T4yO4vL2R43N28u61kd9Qq3Nq+9/bW7t1NL2rIPdxurfq8u3e0+0XZT8Ib5YPqEa9dTKwRhPg0naNs+Fdt
# DATA 2+SMHIWxM36PzMfIfmtDuH7KaT4ednP6SMb1BZsSnbOkoZwPpSLKa5JTLsSA9aYvQITJORpRJ1+T4MZhWgB+w5OnUsUXj9vmQTnX
# DATA IZhrjGylsO+QaAd4CdzYcoeL12AQCpncZnTWQe9RtJljuUr1VVVJvL3s2fDsHVkRVElG3FCUl5/NmBFmZo4BO4JQA+hUREDj1Hwe
# DATA ck30LBcn3c2fijnn2+cvLtCKM49ePT7UUg5rEmlClIqmsbXCjBt2wXBVgcFLLor9YIEExgyNiVYHz0ad73NVzknyPkexdXGQoUJH
# DATA cwlAVAw+BDPpAw7JxB121xuLCOgSOws6neqrX1DKeoBQbghjPTH5C2VMZ14UkeWIF+TGXa8pny83W/Qbhi4r1upRj7JWRVj1stsO
# DATA K5okMh9PvakGKCL/HQsNNLG6ThmptLD8unQNJWBrCYWXt5YVptRWobzTzjJ2HNUbgnENUOA5Ur9hptVv1Ocg9MGRNg5kahls4i+j
# DATA Ti7wT9bLk++Rs5BfRvmiC+u7ZmtgcLa5yoVe8FRo5NxEujKrbgMkoY3G1vWi49jgkd0nzhXDb5x5gGcUFQPBKVnvr7rJm8m111+/
# DATA cu0i3uib934keCHrlAqeHD1QRPdL4/QvI1iJjZIIDag2X3tQK/5dfpWwYYv0dQDTVrsbhHoah82G47Apl8lz0HQvLwJ3p32toctv
# DATA 3d/bb+3dv7l3a3drB4xi6mjf39vksYE6hKpWhOPBwFj0NJaTNJUxjFOYCoFuZos24SQ7+C9uUFlACUgTHge4j1pAiqzhcQRqf4bD
# DATA UBjqRBw6377PA893gbwsNLXedX77kaKFMNi06rYwj7ucDwJ9IRcVJBM8QnKko8cVfyimmwJFmvfTZXC382ovy2Vu8YEB94YFRxV1
# DATA DhyOHwLa3cD6zBOwWk1gCcpb30kl/aDzWumt+oOa+rd8vl65gj5qbv/o1l3gO13eIdyT6UgR89P2qITz4dWtHVJrAOKiqLdXOlZq
# DATA IeXB7e337r2zu3F7s3XzzvatHxrFgQsET9wuzzzaVBaD8V1Ex/+fSK/vZkII7Te+3t+nTbNvQ9N9ec31hXXkRZrubwnz/RXYkpSw
# DATA IeuqVVR/9M9uICMoQgy0h3zWhZhNejvs96G9hIyMtaX/8nrgmJb7xdkXXrzF4JIWixdjX3DU/y9cHx5yaMvLpfPUV49r2J88BsPN
# DATA +glW2Xmq9MUB/y+vdL+EQrFQRf6tQyFHvaHmYfdLb6iLKa4vrhD/JnrahbWVITB5gd4t9KUONYeOotx9V6R558qNRl0krV7k8zwr
# DATA wYUmPMe2IACwvoHW/HL6Yw22zq14WWEKoctfhGL4srDmf1QqFyiVv2vM91xCJyHfjzgXqqta8AQpG/Sjd8UjZrNIwydz0MU0Fex3
# DATA rc3Cvnqi5DdXtoFHwt80pjQMJT6MAjfKEfKFa5A1evjkrJFqRIN0PmTBgjgFHJAeC0ZfelEy+UJTH8vd6uJHLBBuuFBq1xzpb2t3
# DATA 8xaErqPxePPuzv5PbABVT8cFX0CJ6ahjDeumY8nFYBRfj7A5VlPN7XyDPqOSFLz1jHO82TrG+W4xH/jd7R+LSmlLirhWHaQYjxh0
# DATA +9Kw7qx6pH59uaL53Y0tUDb+t/tbDgrLRUDxSDHX609IGMIcig1VQY0R4LR0yauI6ky9ojrAD1XpYolIAxARtcjBFLvTz150LwpX
# DATA Toddq5X7c7U7Wps/3trb30uDo+jkR8tXbXGaNKnX6h07ww93uXT127DO9OMu08SkPT466T3qsvjKdXHC4sFR94bO4SXCel/5/9v7
# DATA 1uc2rivP/ay/oi2PqwERAEGKkhw4GIUiYZljiuSSlB0PiKBAoEkiAgEMGpBEU9yK42R3UkllalL7aas2qdnd2s+OEzt+JN5/gfqP
# DATA 9p7HffbtBkg9NpshEotAP+7z3HPPPY/fCSZ9jJiOdI1dwLls9dkBOwLdLEFd7o9g2WvvPq4vTe+iGnZB30qj6JkUMQm2kB0d7VwB
# DATA tmfGjHuKuSykjhuijvuEHLR5eU6fWF4g+vnsrhcIh6c5eGSMhH65fSRezOF7Smkt9SUGX0nJHCvaOuy12pE3VWD1aDweVuY1OmPl
# DATA ZpliXHwPwzTLZVAa0UoL56XizpbBkqapgtluC4ni1A7cM8KSKuBSIWg+LnJSOXQ9EWIq6kggzahpB1ZV5RtOmushAoKI5w/ChcU7
# DATA pbL430LlFK6eoW986L7A6WMr0LYL5o11SxocHlJE42nYGXUxowvZPIpS0TMYSiXhaXjceloEmxs8tFA+JkXj0yL3N7wZnrkVULBZ
# DATA +yhqP8ISxmLsoKvhyoNVlC4F1SFPxX8PItA0X+d514MBozCPthshK89TmdfzJcF9+rlR9e9lnClmlRiVBo/ulisL+XypjYrrXN55
# DATA QtzikGlRoJBooOm3kMlzRKO+IHgbcClxYWGRotBG4+YwGnUH4EITLpZj0eW0zRVGXCcCrk+P6IejHX21DV6nMro14T1A05KcZwqL
# DATA 1U3j7cBtG1+WXtIce62yD1lqEzJnWW+cqjdEK87UW9AkwPuEydKORtwFLkA3zZUt0jSy1kLSARVSzL5cwEk+0UHDXidDTiwmQBcr
# DATA i0I6GXb7UTgDP1A5pGFg7m+u1u49vA8PH4uR68KRbdweVsshDqBkBeHb5crbyOuWlm5WxH/G1/lJZ4gELKNgfKxGjxD6gVR80SiV
# DATA 0UCJk0UIfavMw7/6Gg1KZZ71vJbHKg2XbAINki5JUoRZDl47m8aOSY4qSjlKnBNc9f2rcblxGJftU1hBAIVckkicwGzX8zc5L57u
# DATA 5a0wdfpy9gLQHKleQKYyLVMPmqrXn0F52pmuTJDnMlut6dVBzWzzOnOjGQhN0IaR+n+UaY6lUzO9XEELZU62N7rDUn4RYFhV7ji1
# DATA JysHKTyCCGLgeHA8IRY5Cg050ySOisBU9C8qiWQeN4hZbnG+IOxGZm45zmWHqeW2ULU1igTl2EHUptdsLkThHNG/UrN9WKNiD4Hu
# DATA pOyeyrOn4R1wA0hJsZefKauedh+8VJ48nBs3Mhz9VzqT42Gck7AslOIMkFRAEI0FUTRbcbvbZaTX7ER37sRn1OdCaqp6OcuaoQyh
# DATA 9Gp8cr1Eqwzay2iQgeLotgUuXr5iTeZmWLnfL3DGUTCz1qGMn90OuUTd3kvF4sVqVYnuCqQhc5tieJgpPYMxkHAcDfEw4cnDxxIU
# DATA PBLqyin61NBZZndXcraUHIDmxIqaMZdzoiHelH/Z1WouWnGEE9ArZ1dtjKmlE4WBRP2mO8hTm2Kx7QS0sXJ8S2lWPn2dnD6KTtiP
# DATA AyMNrHgIL/vMn11i7WiGm4SzSCiNk71Qwyn1x/VyI7tCg6mnCf4GuUtvxpcxW3oPdbuqsSbS5snnKCdxT7JJTiOhTM9XCXMM+ccm
# DATA CHeVo1RkpZ21+7u17QeFQP9+7+GWmbeIrtOfHBVQCHqt4/1OK7jRrJgJGPOvPzGmOC3EmOHGBcEMSZezvLJS29lpvru8tl5bBVnv
# DATA /HdmTmydR/ub82+f/5rTiEN+6vNv4M5nmIXyWzu79vnXlJwcE1/+LpFJ873d3a2donj1j5Cq8/knhUA8jmk0n38qiuTE289/VQj4
# DATA tU9Ehb92avuK6oK8nZ8ZCc3hx7Skn/5snNj8r87/pFNrPv9lyT2moOdu810xVs0H4Nx7DxTHax8s79Zw6P6XqPXr82+D5a21otUm
# DATA 6KBo95eYc51TeP4FRgBTfn4pWgMJRfHEgZ3D3LQ/lek+qZPl2+WyaPr/ULnbecTx92eYw/QviQZLw4RuODb0f+IrX4oRgQnBtPG/
# DATA FHPLyXGpfZ9Dq2TG+J+l9YzSzVMuXcipy636Pfb3C/F14XbwfvdeasOURtHXLkUizuT/Xnz5E7TzU0jQXsC7WP23QJhfyd+f8TAi
# DATA AVYC0HPFlXl2MIqeto6HPXT9STQOKZSbpqwo0L7/SjWIVglS/QMQj90yrOwLMZqfYsWfiIexLDFv/Oq3PF3fPv8VJn392qVrQaP/
# DATA B3vyq/M/iWK+xpFoTcYDs5VnjkVj5wSyxtWAy8gFj64UcB5GhgAnxvPfipIxH+3z/zxbivlketyMZS2+/mtw/qWYk58gbX+LM0HZ
# DATA cH8m6OkPeIfq/vU7mEb3/BucXpWV+XPx53NoAtwV9wRR/hQ8Uv/9JK4d915BwtcL5X9dXFxauG3nfy3fWVi8fZX/9XV8rl+/vhKN
# DATA xhTfFAXsAIBJRdF0ahiW6HwfPQm2pZZbOlGQn3F2ilcoiA7XL560NTNNa3Q8BPHwGhXIsqYskI5CBTs9Kl2MCwEKpKxFAvf7OO7l
# DATA boBcV0DksCoZWyHVO4jdzPiq6Vnft2pCjgNuJvjYV89/xhwM2B/zH5ZxYANGZvwdPCh2GxKDLLnoK8oD/hPYgJC9fYPb5WehC/dq
# DATA iGui87l6yD0BHx/oC+bhGk7GVegS5HkdjqE3g8kYLpI2X0FF3jJMygjOSYo3SMyaYeR2RsgDT1nidL7sKKQpsDlsdUe5o0E85hhZ
# DATA fatAiPzm1MXVUPnakGeDfJMVmuJt8PvoPiYXezxrGEXm+bQtCjZgaFEct1614x/AQaSNIERitxsSGgj+Dvf6e6O9cjjVznv+GyVM
# DATA AJHwtidlNrFNBygggUAGIiqLZGI/F9TyCzH/PwdiAKHtc3xFUEky9+rQyf6YjKtbKC8uBTfwz9QG/1uS9ni7ZQpWjYdtXTZe9K0o
# DATA RTmUjr4yxTWxj/8zCGzBg+49lT8HMmiil0EQD1x2BFMf/dMETM/geAnuaZOYgeAkNCDoH4GGSooAmkToYo7xG3hIiat0stw/gVx1
# DATA eTXR1lXyBmc+ED69Vf4earv7A7Ahwje0e0Z91HG+fXsJjdfIKFS1slebopSdnXXprh0HHUwDgUBh3RgjcMAOP2Yw2nfEMoFTvpjI
# DATA /sfRaCChgmEQ1PO0YlUWiP2wM4hiCho0l00onYym9gTWjvilF5/dl+yQbd8nySm9ZARS2B+BLQIVOfLuH2AtAG3RKemzbLeol1G+
# DATA 4gMwDrjKPXtFzuJCeswwJsC6J7EyLQ7yUufqxefpAnNlnyvhbAFSM53d4Pj4OexSxogKbiCufIbHis8S8v4MnPK1tIKzNJAsEfeI
# DATA BEB8AGdIS37g37RFfixjPN4MYJ7ExA/RwhvsD8ZHwfbOMi7Y2srqzvI7YoNi3PljcL/Bu8eDzqTXxUB0g10NJ/u9bhtgAhNEIG4J
# DATA NmbRg4/fMDPzlDSUr4tbkp6GLcAPJ3tMHFdkmZJfamc+o3FvVJ1KMlfl7xLne71vwHYgpuE7Ifv8FIUdOMWKb3Si9Qo9zz+VPk6Q
# DATA adQ7UHq1oHWrQ2F/zliVOhFlmHfzA4iySvgYTHJzPGjG4sF+J85hhTJ0sUoZNxYaEOUoCaPUHzzJSdooTcbtfAl+iVYcD3NTeBfK
# DATA e98EqMv6mkaBj80+wQ/Ov7+AEzBuqIJ1Pf8veMz/5Pm/2KkFPHugctAenkwXuAzDRZrspbfVy4lxPJ0RWCJYhes6TM+HUEasQAaM
# DATA h2eGRTj/bzR0KDL9ARsVO7IXchQlexlCllKfiAH+RNDwt6hp+DpMNN3jb+fzsDNeSPjYwZgBXedCiM9tH4kdpzSMjkn9330MWbDg
# DATA JwsovY5O8mCaYLEUQ/lNyZ1krfNw29yThhdK/nf+v1GB9AVurl9Ygh4IgLY8a4qE7piK1/+Mhxs1qignGvKs6KCEHR1a8hm1Ohl2
# DATA 59F626A7IECKAfpYrHkcJOIMTp9b48Fxt811uQOnyrE06aw8n71a0TU3pCtrlgwYICwrTolIGcogEU4NYZNeephWottDp59uhIf9
# DATA MPoFyOdlhgGZTYygeiDTAB/QxToBHeIQ1njVyByM2H4H3afVsDTuxcXQM5uIQTiISwcd4Pw5s5LwyX6IZgnB0qPWsZuKAq6x3SnR
# DATA MeOJg94kPnJCbKC++KTfzslnRB/6g5wRKTmIlb8rTTpGidK6hCigntEF5G4oMabOFfNohUUT546j8dGgU+BAYgfWxsz7SQ9YkRsy
# DATA vadxItQpiM1D4e2bby95buvEwnfuZPHY1Y0ds80VwQvEVv6lMiAYRz/gpmsba4pxBKh3l/YHZAu3xZnKgQcxVUklwlNgXx6N/qGA
# DATA SYxXiXXATt8/zIX1Tj9u7PXDOeymYVyX8xX1MM0jIEsrvzDxjvKTiUbH3TGFteZO4U6z3RtMOge9Flhkh10yWoYYcUvzRkZk9RCj
# DATA 6NO7h+0BvcZvqalLeVXiKlM7CcXZbUR0zJkDPI0DMdBAdzZ7YxSr5CGjJpD81NNGBsvH6E0gRhRYHP8Y8Q8Fik2FlCgL7pRAifPf
# DATA AHEgzYDIT1QktovnPycBHjYfVuH/no0Kf+EDnaDBolKffUbWQXgkdEBcTAwd2VeGFplZpPjvSNJfnP9JVAZWoE+0UetT3PCMxWDV
# DATA z+zuMu75Ftul0iD8rfTjQbefOwhPH52B9fUxeMCSJ0HBGn4JmV1CrCJMaMe8Brw5DakNKagQSLYzgyDoU8LZVAyWpdDGgYJajOAq
# DATA C5TETNU8t1dszP1AXymZiEyN08UCIJZgadPFlzSVLS0azdOPBGdAB8KQnY+pteEc/p0L0c8YqV52xMy9hrPdizXklr3n6sITj8uv
# DATA 849bo/led1/n15sXl+ctuTDtIUNWlOD7iotS1XNypubQuTqcE6/NhUkfaztEwwDzd7UdRt9EyTGpo2fXnjguPsFcFVnKHHAxom4s
# DATA Nj9rc4tTsxEYPijmWcN0QJd+p7RG4DQ3kvj5YiFg6XaudoeENTh5q30cFesyCbmCEQOsDS5wOq9xiFZwHXQj+DOcE3+KzO7PFrPj
# DATA NpFYQI1Nxm5qjTY+kanRvsBiUjwQLbp/xCPqV8HyygOdLj1GQ7LYzIZRWxwQITsw6kyeRu0dRIr/p8kA3NMwo3oHXdXaY9LNxEdR
# DATA ryfvk/5ECIKtIe1i2BEdf7S3BzS0Jz6hEZV0nS5eN6+9BdfeekuiC2n6oIwP3GD+G+bnJS3MhTJAx846FtYf9rtjIWusGq7G25Ft
# DATA SNtd3zHPyHv95QMhy1Q5mqI4ABExYgepgEMRuba9/oct2C28zyJvshrDPu+iPbvgzCuEpPhoIJ57+KAVP6qWhXS311ejX70uGB2N
# DATA 6Vx4fQ+URLxR3V5ausQA4eKZaXjkwBiDItaVGLRWD/pU34WSxFub/ZWWkMM7rVH1RlH8LyjfLCzcqpTLFeBTVte3BWGJffPjqLMa
# DATA 9VonO1G7evM2PLUFSnnIqTyujsUei+WvkWWzQaMbde6dVLHxsRpYZyw8vueXcjufyeNcxmmTN/kQVXqmnKGCiNEhGrADSL03PlJx
# DATA UCMpyRquhnXDt9rUSoufrDe0XBFpV0dnckqfYvltx4y1pcIy4Ct22gSQHibdsueUNS55U8q0HJhUlShoySctzj8Z4aC4b4HSauj3
# DATA 9Xa8CdWAG16orrarVZLW5VbJ0ne1SqjxatlRktAm04Ux4W06PLF8XqWqbno1pqfxxeo0SMio2jiBtkpSGBQl8ym0VTJFaH/BTugX
# DATA CZpmT1jUNMu/dDeIvCtWtjsYN7Vpi6+0E/r8PBmNzUChJA/VEuGSJc+KKSTD686WRN8M3o+iIVoqJTZIILdiPHFDosx+uzfBBPXg
# DATA mbE/GIdx0INIXz6QxKVk6tF6OO7JKC1elhVjMK3VTNFU3CnTGF7SQkGel7z1LKxL8xk7BxVtBDxMFoqbX9lEgq6R2XDciz1JUll+
# DATA AT8lAkMyeoKyi3UX2uzDT/HKLGRe+O75z+n4+PxfyTEDD5honIcDptiZHVx98iIWVdatxjTy75i3oCWNGbyAL+WcC1t3wk/XUoxc
# DATA yncXrO8/JjAAzIrGKjISySDVexeOKwY/0Hl8ZHR/FPQGhyXH4zo8/63h2CJGtCIOUIavIMJd6YRekZttlnW7oekSw06A6GKztrFW
# DATA 0A4V4v9sboeQOOhI1chPku7IuPDvyO1Pu78dPGkeTlqjziv0Asz2/1tYvHV70fb/WyjfXChf+f+9Jv+/3Qhs261RtwfB1DEYWiAZ
# DATA F2N8PHz3QyHFYoo63o4KpH/v9imTG1giRpS18STLBfCg3R/3LuDvFx9Nxl31AoU7XMwDkH8DLohUcKHDDgXoTPGbI7c/v3ec2Pwd
# DATA R7mlW9leF1H/cfX0xo1BXOLANLG/rq80l9fRDX3FUPhO9bPbJo9GYx8DH7E/klXz+Sdw2tZRBV9JmxuGOIh//wUuilfEtL4TePjp
# DATA gRC6ngAGzPnn4CODPvqfPv91ONWHT4xZ09gOJXS3hPc66qKZ0hjkLbTdWMg1NlQmW6/hzdKTlmDQcrBvLZVnAaujN8egrO5Di/IZ
# DATA Kd6TlSyUE4nQjcbv0lO1p0MbCUoX9qjb67kgbbqWLHOabUijU6ZWMEk7Tqp2Okkf2fppMMWi9fWnqEMHcvhWBd0IMtEW7hew5Ilt
# DATA xmvJA6Mamb/N8rHHs1n7/raMfaNofzAYNyU7zYlhK7CKrD0WxyOxyIREM4CculVWuSRUv0UYa1kCSECTfndcTVXQJF5E7EWtytKU
# DATA R/W+FNr7xvLDmJECuf6Z3CuOW6NHqFmnlwhWgQLWQ9Y87iISlRjuIjp4/XiwLxa46DTgXg0HT8RLvUEcw/D1uo8iqagUZ7HxqNWP
# DATA u7Dt4cHS1TyKUXxxtSNzApi6QpqKDCcKF6Gze4tmiFGTOkRoj1IVWolwAY2+06VUZ+OjGvpRIM4SSOY0gnnKFbHXT9Ub2iWamkMA
# DATA bOJREYVcDzgRndgLW/u9yNAybg3icXV+Eo/m97v9+dFxUDwIEs2wqklT0SHkSnECByBDTWdoK9Ej3lhQIeUlFWQPR32pEks8RU0O
# DATA aS2VMHmoNU/USsBdR6FJ1ir9eXgroxjNChPnFFaAQnnUkRtkIaCYU9E0DkOIxPCJczj/enLUbR9VSWYq4Y+ClMrMFB3idULtgpMz
# DATA S0O8lWJpQVV9A4Aze08nDM6DJ+IhrCEXih+2mUFcSOzgXKC91bNDc5XGGvmcRKtoJP3x8EYJXfli2A4IyX8SQ7JOGnLLQpFRL7cz
# DATA o0RPeT7e9m8+kYodn75DweoLdOQjTvbdO1J6NkLcYAf+BdzmMZS2EDW8fKEoxsh6RBCl+5C4ZM+ELIw1JOqpKd3iqEGHa0tH6c+x
# DATA WyRaqovguOkG69JYKMePZEc63bg1Om4C/wUPCiZVJDp7D8z7NkGGgxWLMUBNm2fr8+ICMutfFjxGli+zvoBsATo3UGFIIbgULAcg
# DATA xwkOJhEIR4BoSCnV+23AH2YHfINldFw4yfag12PEk2IRd2NsG/H2YlGwH6K5KmKuaUYn7uEOA7j8Q0E9J9XldnsyarXRdrEA2jJa
# DATA ODrFp+RUjbwXe16uNOMFmAjjjWnrJyHbGBpNbKw49x2L8XpyFPWtvNHgX25oLv2NsVtvmlQzuMSMqziN5PWyRbdw9kL+iVi8X0FI
# DATA 6ec2bZ9/8U5A/kno0/y1tMCmijDID/iGvPgdFAFmUnCKRg9IC+hRrYxc3h4vc0ti/B5cAwABpWw6rxwEaUY0IO+7TEshnCHEAbuq
# DATA WrRdAwjZ1dr2TGg8XAx1KS7xz/pCpaGAeuS1ykID1K6AYB02SI9o3jdZpiyVWSYFi3Ex5YZjNp8m+mqnt8/Of48O7kBFScv4N0rL
# DATA n0+48YXzYtodAR18CEq9QftR4lwGjvCIQNHnE6T4tdlc2a4t7wbP6Mf26ofb8vvG5rub6+ubH1qSCiFjC7FxNBkCkomElzgYwenF
# DATA cWxFHGoHu2JtY9eErsiGskjCWUiIbf1Gc+3+hqu0fT862R8I8WhNtjSXz0bUuFCr/AAbxqiw4Xv6sRSmyRgzUICJ06a4mIN/CnwF
# DATA shk1az/M0EwnZEGNJ/XiFobEYFbSGxIqIQYFHPEfhrO+k87/vkOEgec/x4gb4pV+bVRomz3M5WQYPi5mz0i0f5rJwaxVGR1M2wUG
# DATA 8/4C1Wq/TNWheTooJYrwr83GQEkgiq1DcEV8RSaATP3/QvnW7aWbrv7/Tvkq/v+1fN58Qx28Ia3n8GR8NOjfvHb9+vV1zocKWTaI
# DATA SqSTWgnWCedPpdyoiB6OaF6AGT4aTA6PUCJUUvPMhoGjVgwGAfXzuNUmSwGAqaAeA7Ycugl6X0A72YaY4Hj8nmCNvZcBLyBESPUd
# DATA XK3GVG268QF4hmVtwMomo56oqzSi1sk6ubEFuA0bxzXVAOI9Ri3a4QHBP713GE/4GqX8RIM62+ub6OovJDkDf/zayvoanJhwzjHh
# DATA LalcpIQRXlvZ3NgVglhtuwnftjfX8XFbDAFl6mjQC6/t1LY/WFup2WcwxhhDilFqxGsPN9Z2m9ubm7tatvE5i13bergN8PiQyS+l
# DATA zOLjBVHz7vL92g6GSKEWgzMndAZP+qjIwUgpytLGuJCcCJ1z453wC+DM0e2LqWQUye6BvNMW5NwXL+SvPVj+YXN9837z3ke7WKUR
# DATA Nq/UtpSeZTQ4FGMdc+aJkZxpQVAAgYdI0YUgeqzDYyAVMYRPxkfBPpjYxDoS4zCkZ+ICI+dLuVSK0TEek1tPAiZDGQkuMxFLiquC
# DATA UrPZhZRpeIGVUXTktsHrrUSE6OECy0dB0vKMz7PaxE46bbhwiPrWIKfzG1XVCKl/0A+lKWyM8g4jGQjNEw2pgWFMdMIMzk9Ds05A
# DATA zXDEhJTSrgDwEOkmmTnj/nZtZ8cWu50OU/4BOa+oUpD9cpLW9QegFsMIUPgn5zl/y2KsEdZWA5Z8AFp4YzB+F8jBiSYzCjgNcZTQ
# DATA P4dQ6/EvqlOjzjKA6IoWwYkaKQmgihGFmKFcYgOr2cgCLSuoc+kNhV4ALwlmIZZUhCkegAcJQo2lNuR48JhyYoNOBcyH2hcKFt4T
# DATA IV/GCqmA5rQEBuSnOawJImitq7JR+WTv60YvGnX5YAPzJT/NlQs4FUW3L3pkGvlEkSXiLNSWKo+o/VpVlEov4jKmZNJiFCBEYe9p
# DATA uVzce7pwsPf0zoH48r2DBqcjwmfz4gy6yDmcdat4YqDdOc/VuaB+Grb0PGJJgFNNTIQeFL/x71kjXy8uLlXcOjjDF3RaVCMKuubL
# DATA ioX5wvgdn08rleJyN/LvqjgMJ8kLbMd4fC6hqfXnSvSul+kL1OF5xkK1TxjqTGF6WElvqnx6G/0rHclWXHeo2FlPSnsx7EUcbaUH
# DATA bHiEuMXs/cmPhDzAsMtThlvVEJv1JrlqwsoNcN7gG57J4nmTFV0T1cVuVkbUEcjlB5s0F2ktStd/D6A2iakLzq3fxtO6vEzjVsdx
# DATA qzS8KdD0EKA7So6Xezw5zqlC61hgI7NswRxyU3lEPpnGD50zVCOqQbnidflw54qz7PTQpAiWF+Uz1+nGw17rJGhhRF0LwM+D6+WA
# DATA wQaul1z/g2ySNbwCE2kihahqkLLePBIEKjeSNRgryImCZD0XLMgbK2Loge9ACnsaVx9EPpLuzhgh661nOSkUkz8esLEKN2VKNGoT
# DATA f1solz3vEAFQ427gM/NmLW6TYmNbNJaMvkz49pJZVvws1Ck06rWGMeQQwNkSL1lUmTPqORDkEB9RRSQPPQEi9LYEt698ogcQEX4M
# DATA DdmW1GXUKy+Z231ySzkT7LzdE6RgyUOGk6VUFgtiIcYvET56g0Nm+uzpwHsu5COENCCebHeSqyDsfDLf2qzRlWt9dLxXCF6iOF3K
# DATA DImOLpbaiGVAM5+DCr8/6PjVqx9ub26sfyR1qpaytfbDlfVMZWsCoUCJYsAnkxnoKi5jVc9DUC40PpHV3Z0qPXklgiuSYZfqspW8
# DATA j/x+9R0KHvcADshnrOSUaagIYkTaPUgPetBx/aAMLqVVqwcdjutP0mUTqTtHByA+W0Gcx1gHgfLhiKSdXFgHGYFyVo1HB7iDh299
# DATA VHzruPhWZ/et9ypvPai8tfOPIbn2lQ6PaY9HMaKBXgl0DoF0NPCLqiIviVBF1IaT8UHxbYhGhZ7H1ZDdPKQMwm2SnkfJbjEaE1Na
# DATA ZKxPm2hmosrlra3axqpLiqkOVmq4QaNKLa24DvAp4x8yrDPZhljVWlLKaUhUozw76GZ+1pLFCZyzmOORKZvCDCZGOZ0kulWClcll
# DATA kTrEODipnJAZ4OsdKV4gcMvis8yvsofGFGdphKTSxOgdurtpi89L4uzWORw0Kg83lj8Qw7B8b70WprJg2Zbk1EwzfW2vmqtA0r3+
# DATA vXEPTC+zORqOJKwIBj3Zs3wseABDIKHfIGBm0HMev0HHCaW001zb2a7dz8lCJNZGahTLDKOoTwCTfptzr5vlM9SHpdiyjXLU+jiK
# DATA HkmBJvF+0X7f6SKop6qyHDht5OynPTSaasDJ7jEFA+OLCsNB9tssCdoj/gVj8hid3nL7yLPri3RgUU/UK/DYSEhtHX4EBGB6CFy/
# DATA uRwGD0tn9RmtifodPsnAIEMmx9woLMIHGDUgGgSNGwz0Hrxf+whvheR5rsd5Pzrs9vspBd2r3V/bmLkoQC+gNsGWj4AeunRQvuFN
# DATA 8rQQcsH39V15zaFXHqiwvl1bXV7Zra0GRhsauAeLJ+pcLmA75Vl9IY4/gkfFGtPKWvN8VwJCJc+xlkGLTq91SkMhj98XVQCo45OZ
# DATA 17QanMoaKSteQXFGznkof3pyWbGYQ2m+DJ4qL8lDP2iVoSpMTiZvlg57g/1ceEMqNeqV20ugL8KH1FPemmMhoSTevrmoocNkuvO+
# DATA rDxDm4AgLrYqwZPk3Daz4jt05DHEeNzWPfzOGG9wIyGzBhZRN15v5PMv/aB8YGWtNqTxbpQ1JN4NyZeM9FLb04tsUWm7Tup+lbEN
# DATA MT7HuNufRNc8gS5Geth0/j8j+zRPR4SWirRZAuYM5yLB7X60F9/I3a1ET8E4thfP5e/mGBKm2TDQYxo38uLBKjxcupH/OzsjLBhr
# DATA Sg/yFb/OR3NW4j7PgE6eCFJ/hnzlGUt5z3Rg5DPAWLr7KDp5BlsmKMkgZvlZ3OqNn3VihA6AztQXGljzWsooyyVGDy82DI83TH+7
# DATA d30vDPPeV0XDQSGCJeSDv68GS5XUACWHp9I77ppKCJKJBUPFIIrIALQZuVNqP6I/4Te4xdzdwxeIDeAG5DT9DDEjqz3IfM1IL3Si
# DATA N9Yi7TfwR/nUU10FYxNqyBgU3salCj93t3ucz7Um4yOxxD9GVaIglHql2iDi2hcEEI2eiYnstvNAY3s7gEkzCvcWjLLNTdWtIeQ6
# DATA RGH164Jn3d3bt4hTXN+prWzXdp9tLe/sfLi5vfoMU6g8422zeVfsm8/EA6u1jd215fVny1trdG354e57m9tr/7i8u7a5kXcL5cpU
# DATA Z/L1H+2N9vqNuTC8WAemCxX1vXhvp3Hjrqh1mijz7O/yYSFVOMhqxt5+dPIPRidNCKi03/uhTQNZ5ecAlke83uC/ooy5UrFxozI/
# DATA D0MXz/+g0pir0LfG3A8SY/iD7NY/Xdjfq9fLxbuNG/WgOC/+/UHxP0lrUeI9CenVPmqNWm0IsEZgHvVLrCd8EhSk5kWIjxiHILcJ
# DATA JqXfxsV0czEgH0frxhvVYGHxTpbIqgS6VT4u4h4AaE4U9d2Kx4TkXgp2jyKlsLVUd6SpBM8RwmpHt4oSwPCxPGhrqeXJTxyF5VfK
# DATA njkm3TC8AZAjsrFwSX4/48MtZKQXW5lyRGmyn0pOW+C3yQgeHE/G4H0crOMriEFfgHb2BTsaY4PBe4KcBMTP1piA54Nx69AwvQ8H
# DATA cZePyjrak0QeTGu+Ammctmtbmztru5vbH1FuzvH4uNWfV6g3RdVc136Wio0m6Hze+Q20qZozm1F8u7ZeW96pqWhPadZjp5WcVjyF
# DATA MrmR2OlKh0IqmeyDS+081jh/qis+m5eeQfM0F3eVW0cTXTeqp66X/pnhBE84ZXH1NFxuwz4EahFw4ICAFMBHfdzvcPVzKNEWIDWy
# DATA KLe4wgbCCgjkxTZcCz0xuuFDQYXF5UNOPKunwDxHyLzqhuMne+/klJOHkTIDhLBRFA8H/ThKnED5OslEi7dusycJHDHVXMP2Jx4H
# DATA q7h+4lITiCNvo5lAwSZRGdswP19A1MvLUIxYCthHLIZRPVqHqNTSlJxzahVP8NbPviIOmT/e6wieLv8BPtk6dKI1R3adnVHrAGwt
# DATA 3RjLw8yIiYeGYkeXuWKtJy/Tcc7rAH0BL3Qr7IuvMUOST5J4U0mZCVMg8o+KNShiy8W/+btieMySp3Tig9r2jpAalPJthOfu8USw
# DATA 7txxawiIqlyeBD2H7FgaJal/koOXgE4Xlu4svX3z9tIdsmTAVbETYZGXaQuPHTVpLsiVC3mxDnJLQRFXB5Wrw2Ytd5pKpsXGf+zy
# DATA +nSjJnyUAijMGj8OEMblDNi5t6xVjLjSElV3pmHY2YXkfkxVLP8bq9dC5PcTzeyL16yLBxzL4GFlT4oLUSoopZGfP3y4tsqvoniB
# DATA X2dcWf/xYW1nN71dsbg0NN1QmjJintKW0y/OUaqggCtTvN/YAcLjBHbNwN0Wv20Tmehzlu5pdoX4w42d5Xdrza3l3fdCq0Wz2TXl
# DATA wwmrZtKrT4+ZoiQ9WAY0K11D7bGLhqWfTwfEMohEFVVANZVryTQqUt/r5Yaj9KNgUTTLmdmd1Rt54uvLW1tNOkqhWO3D+AJP52pA
# DATA PWH4LFOfpBQ1Vt+MEArQQ9gq1x/pWqtwhDgAhM/T20tnUtPAGoZkl6QiAGFyKQ+QASDLbISeBr3rzcVMInqwtrOztnFfDgDvyqCl
# DATA AMzX41a71I+ecHEK/rcQsNdtQbpfl+KjlpA8UBrrdA9B9Mt7fMfS6b4gxHdSulao+jMHxVsWBDSVMxduMpU8z5Ah9cUmgiC7GCtk
# DATA 8LoEHAT3QAzV1jMHziuIOsaO7IKTMCZgLnw86E2OI3AErlsugso7so6vkyoKv0HyJiqxe+BVruSMJYBPMnOmPE5wQcpICJqIrl8J
# DATA B2xgMbOWrhQoSTdu2Vi5kVfCvJBKFhv5hqHpUctQzN7JEA5e4X63b0I8EiAcM5u8BnysJKtk9+omxAmI+8Cqzq75vBdMLwPYKuqy
# DATA IQ1f9KZF71xV88Hmw41dqPjd9bWVXU8yNC7eMdzh7Em9l6zVR+n21iIRgY0K5JCg3t30klb5KdLyX6e8CCuIffoqJJeCTzu6CIpZ
# DATA 6XYQjoCdLCtozr1o3ieeug9IIJWFBCFqYvnnWRLwFQB3o06TN1Ijh7m0R+dTUS04YDs3BfMVlATiiA+EDfl/gxzxF9QbSLdOiW7h
# DATA YuE6gBRJwNu4C4oJE+NWBcBw8EtQvIemd6NrFF3h6xc6glBELL5kjg7cQh1HolEA3gFVD/pF9kzY6/M1hKW14Xhnx7rwka6OvJgP
# DATA OGCjwMHn7tQmUkdqbIEkVEaB8CMMEST7dYWhERaL/cET8YVbc+GSRjRSqSXIQwECpAgJFnTy4xMWGA3JxdAAAQAuYJ71gGOdqLyn
# DATA ghfipvaOpDuI6Wx1gjFgx9C2GrXElo3DrXRAqSKmSjyQvnFmpCGwRE0pm76QgCmxNakuD6PScRlaejTBXjMFM3mNR1zsA5EpN2aJ
# DATA a9ywm4vB96u2AFQNlsrfu60wy4+0TYF1o4RjvDdCiB3UB4F7ftjI/xXJTTJlQ1JGUj6aqJGqqJjsZrMrVmyzKZrQOyDbshmxLC6W
# DATA 0slOPaKPOPoN85yjqkORC+tKOsIb5wizTHffMwprPY643QnVhDUsWeXxu058gg5ZJ31pJ9lmNGhX3Va7FnfO0e54u3dlaBdDz4IQ
# DATA AF7aFOHEhv9A2c3pKcFaZWv88BMW4W1s7jbXNsRBfB28wXTVUk1EJddD/u2B6Ug8oYcFHLqYYKSaEtwAzPPw9HgxhTsHzvS+jFPy
# DATA gIkDS5ST8AHIjBF7CZ5O0j4QyGmR+ls3ZEsMSZgBSpzUbww5GChFEReqw97iEqQfgcdnc93yqzvcQU1dbbkQqsL+4dS4YS7+weeh
# DATA eNUT4DQsexaYji03RLVIDV9ETdfoy5Jc6hrI04mcLfUwcYRRbN7yu4aEOORYAEU4jkyukwd8ACxutrmBoutCXMeQLv8M8SyJMu04
# DATA IAxzFGM2ifAAJgMe6YBnxB8FRf2uGUhQBsXjncVySpwKvMNxb1hjVcZPsi9GVVDobm17++HWrsWZVJOxZ6IUgh0XElRFtQOQws3E
# DATA Aibhia6YSQ24u+rcgfawQ1DNhA7A+PQASX/TVMCUZVwccnAKzfmZsV0lw6uZibaPWv0k90SdMRIAInuQCQEUxq02YeJ4OYy8iTpT
# DATA g3GmBXNlyXVbq+AgcO/hzkcJ/88TXyAVeQ8nu1kCxMsjIb51P47MFUj9zvsmw1fKKv5Jc+lM74jh6kw+neSjbC76Jjkb0nQQZ1a0
# DATA pDa5i+5sOlRVBRfL84VEWTKOHEJmPxy1OtEMe3s6h0eG4+VUomuohDDHnzoqJIrBk2anGyNumQW1lOgIhBDKdiK7gAqJtI5bfVFc
# DATA h2xeSKxT+7G1fL/WfLB2fxtdTLA7a9sWT0hdA/AzZQXQrVdK/+xNPvPOOX3xGOpAXwx3SnxOcu+tZuy93pc1y8SNW/1M9+q6sMjh
# DATA MAhZ//SOXWLDsgtwdq3vZ+xaF5r/2XcM5cjmyl+0UUBAHYXZ63momKzHmNyKFra1vk6PihmLaIyJq3ez16QnYtvJr5FKsSmqFMJi
# DATA zEQqZJ1aEWHeAAzQADA0oTkOLSnbr4UU7ykQQ63aogLVDUZfetB6CkowoAF4wFXP4Uv3QPmDSrnU+hikDnYVLfYVWDqFTFnRiOuH
# DATA C91OKBmtuASig9pPLO2S5ejhI7bcJbGqLMKbIpiJ4+L2blNFELG8VE2GOl3zu3uqnWVGUd3z4Cgs8smn2Di9eftsjx/0RXVdgIRT
# DATA lrjVYSfQRAZDAUCtLSzAJFuywiUFhJd+IrwQa770JuZsyvnKlANmchub5exIRv8EiAHoR5jppYmg1mVwD3TUUjKmLTcjlebdApvt
# DATA UcTRTyiRTGeWFJ2HSCg64M9YL5Dbht0QZ1sQSeq22wUsxc8C6uoY1GBUJ/E77xFIUiMMcdHItVs1h0/vXAru25hCQ9TI+499L1l0
# DATA VaOv5Vc5BrotDZ8c8lIk3heSfF/6OeKFxDff5qHEsBfhyeQY5YlwVWnjCbC1vrK+pvuWTL9KO65UVSKuDfiEho2M2UR/CC6Y5jKt
# DATA XFyTpnJBfW/4d0JHNrpBSV/8MsEJOBTAAHW6/arx5mrtg42H6+t4B+QCuf4o35T66RMh7iyUy34ZPGNZr2w+2Fqv7eLOby/t2ehB
# DATA Q8tIeUJnSr9gHNXlJJzugckE/eTEAfIEEzB9iGS4vPguRZBLCVa43je3arzevQIHcyYD1KPhwQOaYY1Z1pZJQp+ZqVb3Y/94Dlop
# DATA ICOoG7xddhPXYD6AJmk3uZ+krrfXTxJ4PaFzZ3HKLsQemhYmNaxOMfZ2Y0ZHtw8r0ISGXkm38kbGJATn8SrdoMYkwQE+T0eIQQGd
# DATA CjRATy9qiRYCnNn+aPAkhuTErLUA6BmggHHUOyn5uWWaOiT1wJ9+cyYrS7rgZpGHxxIjhsuY+kqmG4m1ihi2nr1TZtAigzZfLpuq
# DATA Qaj57Dqxy2hFtHenZB6nyWjEkYfwjjYLXjBENJ9WrFeXfOMG57wMW49F59HNoaJeYtdydq5RTdJuN/xg8iCrcM3EQy4ImyFj0aCc
# DATA mWa/tjz3QLIpN1SODMzrCWojOzMmcmw2c91+P/IF5eJ1jBNluANylZaO1q4Nl3FAEbC8kAQhtwBzXJAcGNA5j9ziFd1dhG3dTgdn
# DATA W9SWQ0wpGBsSLoz7G/fymVoxr8Au85BBxULUWttM0TLZ45e5u1nDbFGdp1HJ0w3P5VP0GcCyCsGNpj/AVVd14RZz/et4vrQ2NKWl
# DATA l74OybM33WmiK3/BOInrWAp0NCmkHs0vr3VOUbtMY69+Q/Y0Xa6loXghfeYlLe1ZDUxt3DR0wUt1QDk20ayDO4+cbZdhz1YVuE9s
# DATA 1D6sbTsVvRls9iOFqYuCxo8HoqOtHvDjeHJw0G130bEL4vpkjCKEaIHWAUalJQ5wR90YQW0SoegmUJfJ8RhdQeFRSpiFyuw8jInd
# DATA gumqgwuUgXKZrxTxCpfeSA0Bf3Fkr2yErxnPDCnlZijdlecrHZh8inTp+qq17a4/K7Mef58upYhPlURej/o9TdWdUMn7HWAKqWr4
# DATA qTr716OaN7Xyfy0q+Jlk3JepkJ/ivAQB59ZDF1LDZxLwy1K+G3r3y2jcXb112o7+wn5nM2GTZ+isu/2DgU8zz2GlWXDhOhKJEIBm
# DATA LiM+uqCeG+6bJgSfdn0KyeVfiuIcW8Ha8+kk/JIV502/jd5QaxKVHVZmVMehpkmr2HnIog4xX1arY2vsXQndwID0q8ZI+/dvilJz
# DATA s0YbIAKbm7scj2NxUf0EC2L/sHnP2idNHAIMYm6ubby72XxXLHAuDyg7nxpP4imgtrG7/ZFZAhK248DlTBPt6TBJOofDtQud/+31
# DATA aedgMIhP99zMFXH+O524h3L7fP78l5iX6xP4aXkwpJyLZErAagbMxEyKZ1JuCwEA2leUYemOrlwV3sCIwipEFc4S8jNVY420zOpq
# DATA /O7ba7+XpqrWIAPalIj0k/I0eqZ3NExAnXiBWiB+JCTlDk2v+wsH8xwpWg+ufyAT0+hpOlVfzyqc2OZUFnimQjzEK3zPv4DP9vrX
# DATA VQhAejt8WaWNjSnRoeD7+ijkrTd/IVcfuTDhgLRdW179KLxIUy50LLvE8cxysGcqUJOjWeUbVT17l3R0MkEaPLUjm0pE2YBQoO5M
# DATA Oxlduvo3g3ukVYb6KMUu4uIft07guIUZl1pBPwLc+CFlidF5lkrXpmpnFT3zgFb9dCVVNPIpSQZK2MXi0tngK+LOv9HM2MqxBlnl
# DATA KpCrE/LMfXH+7fNfBbSTylZTOpjZ+K4+wey3hGRVMLYuw4opAR793Ng0Dr4utpxKz+5yhSXkn/YLETRjczQfrO08WN5deS98kVnm
# DATA xEowyb89/30yW+qfMFMqpNP7Z0ohGE6Z1KnHtVlMntNEPcfsmi3k+YtO1flQvZ5sJ0mnn+xURPmpxbvZc5z8D0YaHddhc3o6nWz/
# DATA Ar9lwE40AiFxZo4ib6vPUsTlSxh2MrVRr9QI/iaipPHRgzBkIIgwQA17J9g/oRjT4aDbH5eCLTEIEEgcbKGiZb4fjeGQ7SmVlQ0Q
# DATA nToo4PlG1BG0B0PIa6YUnZ1u67A/iMfdNqgwxwPaX9oyLfqlTPYp9vimCWE/uxrUWA5TTV+X5kUJ8iffZq6ZcDj0pjRTeH0KT/tL
# DATA KmOTScuuvUx6TtAyKq5pUjAAf+ejnd3ag+bW8sr7kDFFejaJg+DWw90wq6fevKnGGljBnWfLXgb9DhGAY6S/cyurJhz/aRlbjW1K
# DATA JmzlU69XYXUp9R4PnBvw5iRCv5x/yEwSFBynpOL9uBuLQTi0wX8SKqXUp1UOmH736Q7iL+bMHJel3SNKiXj4oPt0rV+wEmCW8CXk
# DATA VfSqTA+AwADNMb4am8oZ0AaCtYdXnOviInaDPkWDF4JWp8PrPZ4MRaswEkS9mPe8A+gtfDrN3UrYJD1lK/go0fYcxtxzW2hIOH9o
# DATA zp9WNG/mHSB2eCzKFMWwqjNhXrUWISESDHsnMpZMLIECYog5b+0POic2rgY+pE6cHntE1O80Ja5gDp5Ke4jAFHPhCkFoFgEQQ2bE
# DATA lICKHiWlpwALYrGAEIuIthDOWvV61D8cS4kbjFnQb9ffFF/Xb8e+3j9BwzSJGFiGNeRHOHlp9GcGxmcTlQkHoMUzwm2YBXneZ4pG
# DATA WAEQTVujqMloAdga7i3jI5igxASRIP65h4DEePLBGvLpll3c95Dylso3QcCS5q3w3c3te2urq7WN8GwGFa88XchspOCjeb+2S962
# DATA eIfUzJAvluSIMNserhu2CJhmNG7sC+cPkZ2hfkpHEIPgkwvnQclNof3zqX62Wa1RWmwomqywTpmNl9vSwyi1oRKdMaU99GZDwjvN
# DATA Z+OCE34inA4XX10EWfqYYvWIfk7fypcfRiI4jua9eGsolPwFa7fckSkK9lK074k8nrFlW5s7L9q0HnJkRWEGE2pCAsck5643MkmM
# DATA yyNsaRXmafG23VGrHx9Eo2INNjeKFWT1G78tKKPUjQVz7I61aq4cfB9OLTn9DKosbZDcl0bMjPNpICDS7OG+g7CfTlvyme4YhggL
# DATA JUtEOByfMeOFvgEuEIh3gnHxjEu2HT3uonrh7HUvWR9hYktfkDhx8c232hRP+bdJlYu3bv8NESXMmAfDQYeGvQra1Jya4/+hQXXZ
# DATA lgaJ0VaskLyk29WYnewXL7U3pBI5iYVX5P3/A3nbatzXRNgmTSdsMy+DjtNlautwsGQdDsB09+7mw41V93DwStWiVoO+Rx48SgEE
# DATA y8n0LSV9z5LYp7LUSLpPl9AlufNojEVn0BTyIMDDWWdM8z7wBP8DpFaRjjk0TUmveXhKIQIaryioPiRh47ofC9B52WftdO/jz9z0
# DATA sGXGFNzZXHm/ZlK5WZ7lMYoeN6byaSwVUOSiU5BqGMJcx4cq3mIl0PVt0zGBFVX4p3kwwGRBmGC1C/7wnFwT6KjZBCmm2Qxl1uNR
# DATA jI4cYv3h99Ly6HACMIZbeEdl2gILaVPIQO1mM2+8CfnJmi1+JaddHNF5cws14Aw0jL/E+WwwHM8rl01pufEWZu607aMBIBtXCeQY
# DATA xUPtNOkgGyBMugw6FUNRlEiY+KwMLWlkdkPGQWY+RMrz/Dtp93ut/aiXcR/NbNlVgDdoegGoNs24z+i9GU8wLiU3goNZ+Vn8A09L
# DATA /ROEquJmGk26bGMtu+iSO+jmW3sKZ/HtCeW7IbcSWtsKthpyhQCt6KQKoqKSHQqr44CupZk38C0yb+BXMWD8DWeHv+NM8HccdYmO
# DATA 7q+XKMjEmQTgfbcqDn7C7zzS/ItHNbuSBHVakG42hKtb9UwV8IrQxSK2pi4rX0KHVTls2YWZayyjRI0/gRfxZ7ej58aHSk96abeo
# DATA /LX/cPW5+lx9rj5Xn6vP1efqc/W5+lx9rj5Xn6vP1efqc/W5+lx9rj5Xn6vP1efqc/W5+lx9rj5Xn6vP1efqc/W5+lx9rj5Xn6vP
# DATA 1efqY37+L3rUmXEA2A4A
# END_REMNACUST_HELPERS_V1
REMNACUST_INSTALLER_PAYLOAD_V1
if [[ $EUID == 0 ]]; then
    bash "$directory/installer.sh" "$@"
else
    sudo bash "$directory/installer.sh" "$@"
fi
