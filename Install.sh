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
HELPER_BUNDLE_SHA256='0d612a9910bc126f112b8175e133a1ce10a878ae216d5f316cdbeb1029410529'
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
# DATA /zn09S+UIaOGfP+3MiCmzvwX6utX8Onn7//393/z/q/f/10N6OLfYf2Xq3g8I5E/XeD1sqQhfsf3P3ZbzW6u/k+j1278of7Pd/EP
# DATA C5RtkCdb0vE2dvyNZrcXBtvNUdTqjfrtZqu13W1Gw3az1wriIBr2+hF83w67rVEQhc121G91++1GJ4r6jShuNvobmP+4QU7jDXVR
# DATA z4bcp7hhbu7ZoGqK8AMM0NtWOZMbBo52r9/ojSKghmAYBfUwGnVb0TCu93tBd9RswFv9sNNp9TvRqN5r94atuFePG914GLS6AFpn
# DATA Q91+Q/3qq06LQOj1WwUAdOO4EbSCIA6H0fawN9wOou1eHA27zWY/bHQ7w0YUtYNGo9toNLCUVRA1262gPQrrYXc72o5cAOy79opg
# DATA 2O70OgVAxL1hr90OmjDKdm/Yj0edoNsN+0EzbrVDmHDUbnZaw9FwFAXhdn+7HgX9cLvV7wftYavd6A9zQBQU/CoCptGDPViEkmi7
# DATA U2/E3eZwBIvS6rWH3agbd1uddqs9wkuWonowqjcBZ61+AxDRHAGu4qjRaLV68SgMXWiY/QyGdMXmOkganULq6LeAMvr1VjsGcgw6
# DATA nWGv3o62Gy1AU7MbNMLmdmvUa3a3h91uELU6MWCm3ewCtfZ6jX4YtVxI6J67gQjhNZC0e91ClGwP+41mhBdLhZ142Iz6ANJwO+r2
# DATA O73WsBPV681e0BuG9W6/Cau43emE/WYAjeJWJ+xFYQEg2RoI+t1CEonCuB4Om/3OKBwFYWs76IT17S7QQm97WK/3usNGIx6Owg5s
# DATA 23o92K5vA6mG9V5vOOz1+p0wt1FAVQYQ6LhoMRQtwGOvAIwOICEctYDyRv1epw046DZbvX47Chvb3U5zFMad/rC1DevTA5INGjEA
# DATA 2w3rURPIt9np1PNgzH82DKbrqKLdaDcLYAAQRq3hcBh0O9B1vT+K+6NmuweDN+qjdnu03QljWI16r98fjUbDftBv9nvb7e1WN27X
# DATA m92mCwPdvjcCLecG7Oh12KjDmhZAEvbjXm+7CwykiVQZBv1ed7vdbsfDfgT7ow2CrzuKt2ENmkEYBr3+aLsd92GX421fo6hfAEkG
# DATA Vtc6KFrF+3UIk97eDmDJgP57YRdm3Yu79WGn1WzFffi91dkeAgttNoaA0HA7gGXrdNqdZtiOYG/11kAxCIGZjdPLNdAApfULKbXR
# DATA HY76o04nrgdRPAS897a3h8A3o1ZYD7rDdj9udDrAQ4ZRHUi1H293e4CooDMcNsIgbuRIhBT+gSRlJovbdfu23SlaoKgfNYAxhA34
# DATA X7fTbndDWJxOOxjF3U6v3olBmEVAyY1ODJs0ipqN7bjfrje2W71mI+5HOViUaVwMwjbs/KIt0+y3gZX2+8CtYpAgMd75Bnw96G7H
# DATA jX4/GvWG3aAdN3pRawQrVQfm3w9bPWD7/W26Es6FgauXDkier8NFo4hKYDe0O51Gqx+GnVYc9rvA2hv1eLsBxNOqt9vhEDjVqN/s
# DATA dkb1uFnfHrW2Y+DrrbCHN9Hlealtdq0Tdm1Y3UKm3kQhG8PAYdBthUGzBTTbjgKQbL1uFPc7sG+7IN/b3XbQb4Gw6wLni5tRBC+F
# DATA jc56QAbmHss1qAGmUESy/XojqMfB9nYjGLbbjeY2cNtG1GnAD/3OMGwARoBEh9vAXxqgN4WjejfsggrSrLe3kYrvASlK0cRex+th
# DATA ixbtoHa/3gF0xMMQ6LcbgRhuNoJRqwtECpsY+Ey33613ATqQ1MBMRiFCHbcbvWYd9tE9S2UKGK7juc3tfrsIpADkThPU+FHYa8M2
# DATA aXdge7S7eNch4A6EIfCgoA8LBlQMqlSv2QpGAcgQmEPQa3TvA2l2jzBsdRr1on29DXTZbrVCYPVBp12H9ah3RiDpWriXQZeIYlQC
# DATA 4hbosKAxtFqgJg3rne0QtBR4q9lwwVmM1wrj9na3iK00+j0gCpC3IFuHjWYHyCYMwxagAcRSrx6OtkGDBAIZtaNmHMDmj6Al7Plw
# DATA 2K33Wjl6WY5uBpfLYB6t47RADkU6yQjkK6rvnRA2UdAYwfwi0GS7jbABitJoBGu1HQEviZugudcbIbCgDmCsAfuqU9/OKY3sJNqE
# DATA tVivE3RAAy8ApN4Pg2Er6sBYIZBJ1Ag6wDGao06zHwDzaHUDwEpzCIRTB8WgBRQcg6rWixqj4TaslGJwngCzwTc7ITHS12u+eJeo
# DATA sNasNWBQ78773h/+fZD9bxTwf4P7v7ugneXtf1BF/mD//9vW//0Ma0UEU18duphLwpuU/8XSQclksiSNo+qnoxHVSGN68sMU7xG8
# DATA r+4vX8+pvsXz+TRVXy5/lszUZ7zoZpwM1dck/d2LA18tF8lY1wcO5uin0F/jycz+ziWDMT/hZG//DG+9KHKYlbxnx8dnByeYnFH6
# DATA Zvp9/+TgxdHe/qvTs8EXB89fHpycDr5sfAPNDo6eUpvv+/BpsK7V3tH+F8cndKM5uWrxhNh8uFH+dFL5c245+OzV0dPnB4PTL/aA
# DATA ze6W7FtASj/YqHjPDp8fnGI6Sim/wUuc5ymqKn6z3RJ5p3nRb46aYF9eXDIWG76jDVm6PXKsPuVkiW5p2d7KhW9bXs5AOT13BcKZ
# DATA NfJ6HXDlqVbHCC0FjhL83bGOaUKWhOY7LVeMEj0hMeCc75Yphb+Lnww/ao9VqeK92PvJ4GTvKywt33WLaNAjXHB41sw9yp0si8q4
# DATA 2KquIVbmjuIQ4Cg7FTEkMkTP1RUnQ77cpEoErsvUyW0lVqfyrmzbmhzxpQaYUa0uy5X3RXoPXsfqtuUdb21RuhLVmlL/KX+6s2md
# DATA fsDv57XNC/unyseVT0sqRnrvGQe5v0CYl0ClizNhvv4Ab0iI1XUekqiJYZ8FXR1ZLm2qQzSUezFK+IjYYjmDzYs1xjG0ghFeKb2I
# DATA 9YiSDNCB9Ry5cky5wXWKKt591QfU2U0DjSrdWSvprp11ZBjwTpqEj47N7Vfw1l/E9TBNx2XTKfxqzUSXygZSoU0n6GSJsGsTGD9W
# DATA q8g7NMSUpjLzyIr/I79x32I81TfzyXKM0nQRz80ZJeG1WHRk6oTZ6GtV2vtynlymKoPnyx5y21o8jTh7B9jygznGh+Z2piII1UKR
# DATA OEym8vB8ZxNP9WD/FwwSPi8qoYxglfGhnVWEIuPp3tmeX5IKivbGwIf7e/tfHPi2HKANor63mne0F7DfSuUxJ+tfTeM3M743xJml
# DATA L1cVmfXAebHI0pVymAgos/DetX4hFzIaHUPGCqYhKBAuP+LlnOPl4bMysyH/E+ZHQp8KYodG5e0chBYpV87rsiTl4UZpo3LeuNBs
# DATA kYpDaXanE1ruGQAECnRTLKY3CN56Cbhzt42fYbiqvatMneRAVU+ZBG+SyXKyq5i84ZAPFtzMHy1fxf8XjG067YAVwzAnZTkO5lTT
# DATA wZzxtw6dIzXyAOkM1r0ExFfxgwybxcHEjEVX4O3Kz3QKoSwzgT4bDu2QcACuIM8fAS/VOlukqT/GTBuXSvKyTl+3wHUyyvPAumQB
# DATA h8cfYPRWs9fdfgyupKOV8WXG1jk37Fkfd45FTOKeeFtiK5bu0BZhU8Uq/iYMV9K1Ou7oulJ49Vy9dfHgvno1zZazGWWjqh2l4C5V
# DATA /vUlLEOnZnLx7WVtMVSOdqtGc5D1QUOy0KILx91qL9wxY90p2WOVnqKnqvKU7DdcW1K49alCLomijnbKN6Sx+8HMyxW2okoVz02V
# DATA UyoAn8pZSRsrRiKunjkhunkBaww/zW7/EjT8yl+K0vmXrHF+AypnRY6OPkIcOthFoKhmzoqstbDIxSo0EhFlpLbI5tA7gJxLvAMe
# DATA pgvswVSP+VC4Vc6sCzcmJ5W5Y4YFc7IzOXe4UHDV/R/6TiOkA8WwPxAOLJRndkO2nLjDOzogE4Cq24EUJlbCI/gY09Y6LopbwZJF
# DATA XCleEsqArVWlLJmUTXTk4Ftc/R0WYXR6Xldn4tM6usgZnS2XAzxvi80euWxM0h5Xq/TYZ4AcDq+38Z2yNOS+urIoiTQJu3KRsG+n
# DATA F13xl60WkhRYp8hVM4g/c4u8gkDNi/jV/XzAdbggnhyG4EcpF1HDfVByRIywmo92tcDRmLj/PPOqtscXi69hPU7PqyxIX35pi2Nq
# DATA zUdWKiv15uX+S4TcpXcLuSttiitFrSd5dTXjBO8rBdxZF52uIX593d4K2QD7Muc5ZOr3EJkpHq1fKki+XekAN5H1CmwC5YuqssZS
# DATA qdob1GpKo1fyxTGkFKKBYU39M3OkW1YS9+jHH8vMFQw7OMbd6vLrc4gu6M7xO0mZ5vR6WuyyRStqrSv59qoKXBdBFa1/MoyjKKf1
# DATA W0p1zm6UM+M52zFfge8eI7IK+ivYCLZFJ8YwDhqRg6/E91yiuXXe27koMAgdI5C2wXqTz1GO1DCiXMhXZP7ddcVV1wsdhbsC6fOz
# DATA RE7is6e2Nuy2xSqSIauaXK18XbIP0IFb+xz+g8eXad+nw5/uJmntM1znw+My910ptByApHKGg3J95Q0H0dwfIfMO3GlmK2JPqYBy
# DATA ZplmIa5hNnQKJoHD8+mC3dJ8h80gycA2sEwQw+QKUhUHgYrlx/IKG5QHpCu2HuJqZzAHEFe3+UXMco4I7pREJHdf6HLgZ2A2SqVf
# DATA /WJNSvdqL6N5okQvYw9rjGyVzDg1XXnkm2/yPz/OA4HXjK+QqOCxlD/pgsLFGuHCQnn8hnz1NDNuUmHKUjd03Ay0WbcrWtUsnZUV
# DATA n6us4+76NYfNq6uaVp9rlWoaxfMimRIGIKTsangPiZR0uZgt6dyAIczKAzTM7yjSvVlDuYUyQE44PiQK8l6t6Sjlg0YEzFkwP4Rf
# DATA yqv6HDYkeqvyR4RQfcSIhb/raAtVHwRBuw1/io7lYHY/LTm+X7UR5EoXi29rTse/lYmRoVU2j7OszHjDDUwqN1ZUIKh267qitggN
# DATA FhS6ahsu6kP22YOuO+rlQ60aesnP2WMC5icciWLPIRVEwcY1mbpyfWkXW/5NEXFGTOGNvIzK8wTo+80O/Re5dr1+obph+4Ue4BGo
# DATA YHoZo3fclmRVfMGtJ2lJc+hIQYFBNKWncf1yjnKJnULt7b20zlutHdXKtDO3LOiCFdpDuaU/1dCBwAU2WH+paHZCsTuxf5y3SwUa
# DATA nCKTnAGj3Smo7+qevjw4OT08PlIDc2WPGvtEH+Pqk16lkBhHM9RvBWaFlos5o86y5j7IhHMxwXcHPcaIewwrtN3E9lNFInizNlXa
# DATA UOeZnCqgaxbYIRwiQ1NWxVn17xpT5HASxMj6PZZMbHtXuyIxocZ4I3dUp3m35M5aU9eteawLDQs+3pZWOtBMXGy9HYe3390rgBzX
# DATA V+Xuztp4Zeu2B5xkld7BEKO61wnZz3Sx29SXuiueJ+WQV1wAav0f6eK33AW6Z+3tt2wSPrVtGUDWs/tZR8V5jeBUN0JSa7VF2F8g
# DATA smPAbJGlmPLZGF4lvoU1/EmRt2Vsqs41mh5h/tKNbFzmaF42UFl3vFGc+Zs39TpHukybNXWAHikCzUk1dXGS7pdN4Huu/hJNCezj
# DATA TkdO9ykD13QDiLPW3XuoMM7KCXDTuCiks7b+4qPRcBlPY3XZjZe7dXXV56APUt/rblDlJ11PgzoDqM/92YcBC84Acgmul6BixfNr
# DATA LrQVBZgREllA13ypFOdT4kgGu/RWrrqhepi53iRJCXfYE19yGOgKBoAXdF1YqhEV0VyYHCZDIrWC8kX5tS7bPsH768eJvreeFGLM
# DATA NQqIw1A5MJWEhJSJnzEsP0re7JZqYuBtYhQkme9aG6iynrJ+R2eOrjlu4BR55DAhxbcf85524rTbbnvd1FT7V1vu3tIJaabP3qse
# DATA iot2CG0KaaLdE+OHwpua6UmNMtOU0+gtfasdHPzk8BS2hHwDEX7w4uXZ13f3lFhZefJ9f29Kdy1ZwW+8vmm2HI6T7Iq2QYay3uwB
# DATA db/oVZIVdDebpyFYKXgYn8qHLGDLxEtgCnyln6+CSyqxA4s/SJpe0ex/F2Z0P0MCSlHH3Qt4E9dDIdwXXRD9r8uqCutj4OQ1Ha4v
# DATA kOA0y6PJPJHbK8w9Kh/ZnMT6XSFXv4n07FSWMdv/0TgXH4ry7gFpIAuVTLuCSjCcHFmbTxbz2NpMtq/BVT3WejKESGjDO687Hlw7
# DATA TYle0OF6MC0rv5fCA+lM0ZpdOgCtA6qnhjGCUlXrXQ8UDMjXMLi3MWHp0a0l+Pvo5khTHwYPL8hq8wdKG6hqBhqRVC2CEGjIkqwt
# DATA XXdA1Ohx8auMc+tdx5hf6cQueMAlC5TWS00lTcgy0HTVA9ZX+YulETNIrBZXHi6EwbT5/5MzBvnU2+8+/7/RaLYaK/n/9e4f8v+/
# DATA i38bGxsnMVao8rPljC6siSOrMjLncEst6wCdApgQGkHjEJWN0XJs3017T7o/pet/QJL+cij6jP7lVn9En6vnnRy8PD49PDs+OaRM
# DATA dz6QJCVg0N9weRXOa0m6NU4XCzDpt8wFtrpMzMpP+Wub1vexWlnG6a/g5hXunEvT3A+fql6T+wV6uPP4NkSasDXXq8Vilu1sbV2C
# DATA nrAcosdad3uSm+OdM0kDzqO6YDjuvMMXe59jbcDcGQXx8eyc1zf7weaIE3Mq3tODvafPD48wP53iqyoIMkuzhCod6RsNTGZe6Y9L
# DATA zpVvK5FacxG15DL/cYkCs6pIeb7VXJrt6GYKDKD+YDzActllJndM9U4XlA2xeguLLq9j3TlEryG4/L7l6tcp1BihwYdczPEw4lsU
# DATA 8zEBhVcrMmC6IBXR6pHvFWA4H7ilxrkNtWwBcgKLcBZcZqa65ycrz5+SpWuamIq9N+hzPIfOpcTZyL2lj0sk2qtMld3sjXuu0Xtx
# DATA YSMDus4XEb68pGJm0l3CztZ89xYcdECJCcncH3iX8xMQ70OVGM0tsgZwJLoK1wLdD8ZZypRCllUmrh74PQmyOKvlet27TsHOCbLX
# DATA 2PNTKqqHHgnuAM9U0XvQkf9TzLzl3yPsOB6P3M6KcVw4N04Md/EhTwuwd1FQNEpVZrSIDlPG8YRHEi5qyL7RjYpXGVcqtsdnrGNa
# DATA au131tyGadHWIy/ZSOeXFL40l4PUuBO5jnTdHZowbWGWFpEV3Zu5dubn5suFG4/il9QhGFrg8seoRlZJ0A1Ymcxlx6HeyPcmtOoI
# DATA p2aLzr3e+tdNknO1SQqIRU972bpGRnX1w12/nneFnnFxSGV0E2sS/Q5kdRBRGgqox6D/RuY2FnId7FpytzZfTsvnUhISy9zh9C6q
# DATA nEQlbtEwmC3wCmWZLv+IsQb1kUHZnYDC3KpXDeAVJ49DjZgtImhNmSztx6eyyP6CJYE1hmfo4omjTM95nEyShZvdaOVo58cGkKwV
# DATA 5CVx28iqD5E7g3XB2Zfq7jq+sYqv6XSCm9KMY5tmOrdJPI74MBHW84c3d/h9jprKWFjNb8CyRRnFCRWAF9IrqUqFAZcm1KXAnSQj
# DATA tdQsMVaub7ucp0u6gUDNDIawL81TL+rbp2VsML4wczB/BcvbtzWivTtMzf2YOnfBcVZE9+5eGVi2ihdylUwpTPs6jmcCHF4fAGxb
# DATA 7Rv6zdI48psIMdusr+DCQbEiTmtIyzqVlMDMTfYnz631ghN5uy8XWvfHrPbBCP9Lqehv1SVXXSAnSdjLZt+3ml85Tp5UhbvthGIN
# DATA y/prcN2bmO1EbgwpFykweNSNtZ6J6MmlinUFuZYZCACu686DkEc5sDUpqgEMTereXc5MCWtFB/YKpN1K7+Pi3aZqhS6Ac4a5vecy
# DATA PGtIOg6HVu99LE5neok5hnMfpssp2WqOL08aONppwcY2w1u6Kh/XxRvbQBDeg1LezGvxqbSZXcnKGTlaa9XRD6cfrH4rz2t+V/9o
# DATA V2/6naKilidaZgqKgPHg5ol21gtH9mXuguWJrD+ez11VYwjtXt8b0HOV9QIu/uA14t/3tXgbwfuIsk306bPFEcXjGC3MJ8BTfCpj
# DATA W1XscAZESMl3Uv3d1SpXVnc+oUq25i77nHbIS/rJrt94XJjP0iNO9ceiwJ8sD6spZk1k1mG6HPMFdOjGHt8qFTpZrFsc7m9U2sdF
# DATA BZDfCux3tn9DG7RCDE90/V26d1wx2ByllCrfxjn9wWVsbfPoQ0risuzByCBfZrSr7Ms17ZHVWgVuWQG2XleW3gPeYCWp3cKy4lRV
# DATA t53RF5LZ/8Hcq/8+/L/Z78nx+7j6L81eo+X6f+u9Tu8P9V+/K//vlxJV1fmAwvfkIi92uoqPBNWtRSrs+T5/b65uy73u36r/EqzI
# DATA l2mWvFnjDbZ8v1Kvxa4/wQedSemWs1zsndnNl6GwEqP53jXS0+8/yEyJSVfL6Wvy7y2Ao4+DyTAKdpwjCpatWsEaGfkILUOk1Fjq
# DATA zz1yxM8LKmSokDeHqhbBJXDTDCw3pbrJ5c00HxMls9LZLRuFGmypwix8GciqmTKGxS18T3P3TXaxrO/CymaVqzU5yZArAtAJAuex
# DATA UB4/hznepwy/+2/vfsm1vVUh73+AP799//P3f/3un4UyN9/95t3f4xX27/4JC4HrSh4Cf2Yd9MtdQS2Xf9pn6swzOZ/6iDLzdw/O
# DATA gGqNywyo9DgWIP/NAzOgxGnSrd8G5yVK677Y8QMi0gAJlEmD58SfzUVCgSwFXcHJNwktZ7jAoNqYq/osES450VMLcavpQbMEHZRI
# DATA M+eMD/eechyFfyZXiuDO8fVywJZg06fB6UKZZGpnQadzuyXe6JAsrIbyw4NnAd/9HwqvXM+dsP6b939DJIWV3OETln9//zdUE/79
# DATA f4HH/0jl5/8ZXvoXPjJYUEBfiMUCkY4hoB0DzE3dKcsEFEyibhsJJ5hP4MPdgzD/Nyw8/xsk8nd/D1SDsPyGy+JjWXqgFKswPda7
# DATA f/fPMJWfw/e/XQsvkQxAWDXRC4L9PAf3RXFGmFx3NrKCVG/1KHebb2ET322CNbV8s/kWO7yrAeeuXf6slEvHmikHzOiegJjV885b
# DATA hlIX/rtQg/EwpRUbzDic6eI8WgJ1Msl6yKaQc773MVmWNjeChYBl+NW7f3n/dwW7+Bernup77lx/JDr+WCJuJb6aPX8i3kxPX7jJ
# DATA 7pcPnRoz2l+8+0f48sv3f+3jH/wAZAazu5dnPf7YiwuxqQKAt6UVVwBQ8ca1ndBHFW374FnDlvo7n/bar2mifDsE/wxz//m7f4H/
# DATA +8Uj1ppYMV3uQvybYOOUTCVrjD2MqZ60Hwoism+Zp59vmDgPbIAtEZ/ZVpTeTJGjb9GW2Pr/2Hv35jiy605Qf+NTJKkJZyW7UAD4
# DATA aqnIogZNotWwSIADgFK3QLimUJUASixUlSqrSEIQImTLXo/D2rE9u3/MbsTsrGP3342Q25LdltRSxH4C9leYT7L3PO695z4yqwCy
# DATA W54daTxNVObN+77nnHsevxMcBvycZuZwMnqlLnRt/Ul7NhkwOaUuvGdOifiKpBMqp2cfCAzOc1lA9mKEGDniL5gQ/+TNP6m//+7N
# DATA 54ma4V9i+pFfYBYQ2Im/efNZ8u3+9KPZoR/AXa5lFWOgGFdE5MokggMW2afXiOCgwdRu3Lh1pfPCmwEG8JOKTcIioBZIdLiKWtPu
# DATA NBT7nIQ+QPKypi/xVciMSyK/lXFqreBHkVH+V2SIv+BFopwqnAMlUQtFZ0SdmQRrVfQwoVrdUArd3X0peh0IS51VZ+og7IAz7cNv
# DATA ToHLBwwSvtUCeWhfy0IHOHYtOYFwwhsXWcOBsx7nN27gSycqhjtipBLMwIqCh3mnBREvHkb2XRUm1pvCoWvqnRc9ktAEbsmmu0E1
# DATA sAXa4zg7VI3+YQrIG2OARlXKraheavGp2vZqQhfFN84ICIWBJs95ccD5Qc1no4LJBUoDaeXe+ttQhFH0VZ4Zh1aQbKaKgxQH+5FS
# DATA /vxUYJPhqOYYkh2pk8fkyJ0L1QJaw6CaUCqNjPo/Ya//VA3kb0B8UPJdKHqqR58qsvJT5EOfeVMC4qv66ou/FEcRHjpXI6Q3Bnax
# DATA f3TW5jhZBhqTe6YfuVqLUS2CYrL70fqyKhSje0Lw/lStJJF2ReTTssBl6mA6aSr58R2H2aPtBTGIZqe1U4p1N5lZRblvlPGC8l38
# DATA 5tPo4NW4Ya3+A8oVv0kg0xaQTPXgt2/+RcgNQKMKx0q7YEA/i+aOTqUmIuNDVgmO5v2i3TksRoPZlJ3R00YDXbDwLQBdFiWx/JqH
# DATA 1gyEAIYFCJwADSqwuACmLjQoRKrdoeaLxc/f4fb/WRKd2F+m0XHpERQLNQ287VNgYpB/TB2lv4IMaHScLtU4tggady/GHayL5AIS
# DATA gyZIjU7Cy9PK4oz+ejQJd3nwsYZtiHpRlM+8IhpORXOEW13WMYbXuKPhudOlQz1QASCMvkuaKrTPJIeuZwcHlzh8SGCMnALU8BfA
# DATA HN78Ixw0QUENzf0cbjR4LLUIU3qhIQaH1LEMZ0IMzKbTDtZUVhRd15J6rr68fJ/5czXqfyQG+8X/pP7+bM5KW0gn0WWJoqEdN8Wt
# DATA wFO/6hAxqeYUXEXf1eav8X+GZYU7mVrWPyfNDB3aK3AbHJuUoYTe04YoE3N02SdbxGv8L1irJQ/9evJwoCS2fteacEGDXaCrIbXF
# DATA TPaedeXoOaWMTM/qYRJ1B4PRK9IB+hNX11NpbvsHxu+V3WPXDi4cTwTdd3sizSPccOhrwRcFbnkBZyzMyviPeNr+GU5X2dHTghr4
# DATA cbSclpeCdTn3RWhyBll3hE8lJYwK8267YAkdD41+qs/QRXxZi87LvFcj5b67otevX38IPcK1Ued81hkgpe/xPYW95IfatjE96YDG
# DATA gqPbyMHTUlcwnrg8wYBPca5Xi0cUygJ4/LWLRTnUix4GoxT9uALrxUoVwes/SBXG+Qum/b2WhEaqlDo0Shf+QC8VK3ASAf/GWyoZ
# DATA bD5Seer+CXOhgkZSHbkFFFRlAstlAKJKWVGpdwuYicSKg63AlWLCeuxpseJGBcyTnzjebdHifqcsNSUcK01bc795E5UEtfRwMDqk
# DATA RAh09Snx3yEGuSDslDcTl2WcrXmM05VVAnAsrnQpLmDCptVinGEN/ODSotrvRUzzBRa6v/tDYGZg7ZYmRp6csisHUS6HXOYozhFQ
# DATA LiGcfLUZvMlzyImi1ZpHPCmowCStIiG2OV6EKfLZdxleO+0cV3s8GYPoYvVZHXv6+8hF7qrbqkpqL77FhoWqzkULa8/Wq6ZB1wG/
# DATA 9D1pmyObRGicaZFc/wOqgkzbUa9qreYVS0b4fxA6bJ4F+di5V3BUTKeacXAUP4V6oFSPJ2Mnd0SBSMRq/Yrq/Bzt/FtuB+1O7Lan
# DATA leX+xGn1ZGTeYk6r/szo0xsyF0+NiB/C7jIUKeC9ft1EA0prZlGcXDz7w8bhDFBbSqov8tJ69E3NnxlzhdUTE1Qdy2evIWzqEtCQ
# DATA fFtLAEWYvWKbeKLCntJGAVQk/D6b43tMzGj3rFA3mo3X6n63dkWPSSeb0e/D/0+Ji+/f8vz/1lZv/yH/+1fm/7c36QwLOpTqQks5
# DATA sBQjg+ilgiM0QJuQT9QN1gZ7KzoFkvNoNqWyiCuiioDHe2dQLJ76rTsan719Urf+seq8+TXtTBePJNep3iYDELkJecZ9Bk7YYJnF
# DATA /vAzHFFiy6GapQ5/zYb4t5tCDg4y5WUZKkY5hbAwOOx4i26jLk3JWhYNhmFjFKnWQ6WUbWJUXrYzID34hxnbgCcwnrstMdN/qmiA
# DATA jrRQ3BtWR8mSXVBeJU8MeSCZ19JBqxNZT3r9zvFwpATrLuk8lOyMsDPTUVKcjF6ZjYJEDjcKSrMz7gmFv+GOYdu3+pgsT/iqnozG
# DATA tDudiEoGcMQppBxf8i6jk+C46gf6pmXdPxuUaci8rESZ82djEa0CeIv8KXuP/AsY8txUJ3pklA1hbvKesAf/t7os/Ato2IKG0AQI
# DATA biquW1s0rY9OJ6ThjrA7tbA/ZprgiCGiZDvQY9x8u15X2sesfRTcKkif/bnvdqGuY29+5zpXQJ8NVKy6gU3bHQSwkF7DfCBMXj65
# DATA yWzyvjZszpp1H64nNjKDcY7FBJFrhvoYIc0708Zue/PJ9qONGiEdT9vwzvrMQsE/SlZHii2WQ9ODUxt/rUgL3LxHeLfN1a9Fdsz/
# DATA jrfUn6t5VFdSunf+Cn1sfgs6pN+BfRmWRV1Df61mNriT/+aLn5L9HW7f/0x+iGiw//UX/zF1gSDbPNd8VeXZdpwsUniUNu1+BDhQ
# DATA imRpJgT/nKJelX8mP4bpWVvDBI0v1V0L1Lo8G+oBXjEJ0kI/Vb/9JCDxfjWtLlVNaNFVR6DPnUK5bjiFuHkPIHsGOhXhKpurJ6jt
# DATA rXH5OBQ2ZxWAPXI0ArW6JjoFk7hAfsSGXAUi76fdx1vfcfeT0Z2aIjsb3w6LmLePNncq3u5uP/TqL9W4Lk4gYdshVfo5bLpfyS1J
# DATA NnKxKeOOhBX9I+olH9Gpev99MnCUHp5LDOzv1X4n5c4/4JB+mXzx50TUwCW3ekDqOKH39z+x/66eCPhIUTq0N4MC6Vfgwasekctb
# DATA TTRwd1UJEF4rnyWQv8M4eXTG48FZ26V29A9EleFF3mGn+pKCRZoleUNQjhiBDmlUkKWByu/TOT6ow/Pt9s6j7a3Hn6izir/U9tp4
# DATA uLe9Yx5sbX+4/fjx9vcYTFVeQvl8qGJHeDpsm46VseaceXHUURNpOsUk4qCe6CdEHQ6cHR4SZG3xMhUxSRIVEVGKp5m6LM39jLwE
# DATA 0dXn1+xuALsCCDD7OgHppeJChnDcanFF49qLgN7FZhWmnLD57Fs7XD0BhD+BbZFHvz8fS1FcRVV5d6CkS6dljuExVwr2VxSaDxBo
# DATA 2/2eBHEPogtCvZrYTWRYpHTApHrJe9wM1+3MpI1VhzY6Q3Tn8laYEUAYnllbWldQ30dWhLqW1sk8UVU0o5RKNprCBSU3nwSDLAAO
# DATA usZjAADaiM+II9FFR0GOVU5vmQl7vVIdjnVLjGQpqFq9CupWz2TlzmLqM+epTheQaP6TopD/gBIgug7qtuFzLTCGuyST8p29cfhj
# DATA xHm2nbQzzXZYiKaBqQnm0IQQQQnaVLOhxnrtpYYC5V4EEhlTzM9F5DkllCGV+JysEYliTGBD+DU5UFuzCXIVdN3/R3QwRF9CFL0x
# DATA liQUmevUwzo4w/JfKaA0k9yFT/ZT0Bfs8kPjlsqYy+0TdS3UtzgTDQykwuU6wlObC6u5zwIZGN/hQ3XPBtQOvnfTR2hFa65QDhp6
# DATA QkFH2pMeLj7uTVFV0IAuov1RTTt1saJd/mamZkFbqeH3WF2WX40mPfNb3STmr9zf2niKP5XKE9fUhYzjc1hRJQ78GXnAE4P4CXKE
# DATA 3yS4kEoQ4bglENW/+Es0Of1L+QXUAJlZlUWtBn3HWD29THUeHuwF+OuHsxyQXuHPo0nn+NSmUXGgkcqWgtGWNBabKsBeKRrpBgMk
# DATA 2/nwZQ1Uspy8W8LrvMjP+KmpOhaV1pmqzkNk2iT9k9q3mvlrWJH95Pn04L3sW7APbKiNqpGjZ+D1jVbjxr9JJRmFdNk5KLlrXCth
# DATA HIEU1Xji0VV4QaB4kCTAlKeQ0aTdhO4DDWmZragrOxp0josWVllhT+D64R+dCVknQsbsKu+FDfArB2pXfc4TPp6MXp+R+pv64RzS
# DATA evKiP+y10m6n1ztLrd7FzG3tW/evibSijeWDzJ1cqo7mt/atoCxbOEHXCB5NKI+yrGloSM1P4D4cDQcjhK+mD5dcLC+QIGZDuwzD
# DATA 2Drw8HgJzORvSqcw3Sv9Fzq2Q80PRMIhFxGMtwzMGoU+HveHjs+7PnS8Q2BSTrM/qT0vbiD6/QTNt8+L97La/p/cU3u1di8LYCmF
# DATA NwSNh5MZ4j/qLOEC0NTRo5uI60d/3zqgHRezIClRDLnhqnBYHUo4GT+3Oe5DgXMDEA/gU0FoFSEoIdnjKdMdkYCvO6iN4tRxX1Rn
# DATA 8DaXnqcUiUqVwCP+W9d0rmsKs+G4wVWATnJEQVayJ/R9xOFkiPydJ5SqwPN2jno0rMqN9caev2c8LBq4aaCBLFn2H154l1ucR41G
# DATA h9naw70jswsWjjaRd+p8zvP3wFTgdgkc4hcoQPwSZAUUEj7Ha+Yv6MmnIE38Dn0VPlUSxd+op79BpjPJIUYiJwpyT15i8CIDlxgK
# DATA 1UCFknnzxV+n5VB6Jt0mwAHVE6GWCeQ0YklGMWyVcEAAW1afZI6keswSJlRucgsFKcuD/D6hchRZmdHHYfdklfuqrQNEaDWarCCz
# DATA GOYC12nmsQlsPkhABX+Vn3+OLToljZenmDV6j/fff7+8AQRiv5AronqvM2v2+joCxKwHU4+mnOvIqi3FZ8XcE5mJ6YaGLxE0Dezj
# DATA KEjWbTYOmwhvxj6QWIKkZviQw3oRnLRKpgwB1kyd+/SXAx27b/caantth+BGgB9orYcHisZMhVDRcJKJgxE8qSe7aMlHm0RQ+OlP
# DATA RkO8EdOMqnvDlLJxFxGJqCTMgecJBDz1uZn4fS3Aw5KgL5jQvWhix5cZbRKSPfKnX79IhVsBLiVqOYNlpb6AvAZdsVl5DtwQl8Wk
# DATA PHG0AZyDus+6T2w3krUBC+kTauV679oc+fLryd5JrjhuMU30roPT1JlNT0aTvjp1/Zc5Bx4O81fQqXsszlI2IbJ7jQG4djoahTk3
# DATA jrR5qj8s6wJqUib9Y8SpbbnHCxdEaNFNYB+te13QNd8LJDJ+YLzYif3ltQMCltVCcJlATYKnkaJVi7qrUUnZcd6I0hlxF7A1natm
# DATA mrRuFy6sol3+8i0qyZ+HUEvf7DvlD9ApHarVhxRsAtgrIOiMfmgeunnQBXZqygeJIAIVw/yB2vXLGIRqNST8GAVABjrkR+pweMGk
# DATA thJ7gurs3i7OFDR3lNY52ZbupaY44OsFx5EnnQaDd3oeCIwxaTmGYexYJpzUXX8jNibXoKgeK/ubpTdS64qvoRL7ShaajEcD9gbD
# DATA Z2oBltEOPmP3QgdWVOpetFd8BLNxnxOEa7VEPbkhdC2gGu930fjM+Cjue3Tc3dVkEgsceG0i6QzJr3QAp7FKentgVEaI5Wfc+yuo
# DATA uAam00pM7coE0cm4YEIfA58KOAHdzr72+D0cjQY1iXTHf9Ogd6e0CoZwcMItPduwVVCoQeLdTHTz+FkT3TiUPJOP4Y8abSNpy9Oh
# DATA ycaa535Ar/19PuEuNM1g7IALHnFxIWQN6CQQQxag4adFGtXUlfYGb+sPfTHQk2aQ9wcnC2QAK+cs/AmThGVuu3F2OkjD/tUqKsC0
# DATA j43pazgMZITGcaOjrF8iC3LOVng4RMYRWGthOo3eIAcXlVBlr7VprvK+Du4o7dNc8Ur9AKzpKKPK38BU+Hd/iBCn8hE5qylOMclf
# DATA dQYDecs0SjwrvZAnU02/sTn5zsYYnierMpwBzgjwkBplQnUK8a1Tq4KvtRbXUP8f6r71K7CQf/GXbOf5pXOvMncm0xbcylBvp0qB
# DATA Ks/FVgDjPN2wIA7+r61PiZ1mR9RHg2ik65iryn5iVPCgMQVyqyUXpN2D0ax3NOggyGR63IVznS3oI/MLQi9CZSYA5BjUq9+iLewf
# DATA kr3HuyWDUvt/NOkZTTSbdBawGlkNvN5pC0+J/cLMCEDzF9O8g4YJEPR7nYH68u1m4CfkYAEq3D+FSzfcyv3xa+8R0yXXbgB93lXv
# DATA nmg3c9PPLG4vo0HC6Bcc4GLjg+v/p6yu/rxqdJ+GKumff/EX/qhRZY9nX5xo+FkzdMIsLf3wL7aROXpKCbVu377FPO31pHMWbUQS
# DATA HxIu5e85TW1SYW7tG7a5eWuB5kw78/gCAnHO3Qkgs0tn3McWQHixs1W3Y7pAQ9Kt+cv3X8mU8MVfJ+tPN+vOYgHsBONQ/Dz5WNUc
# DATA uC5Y5Al2XeAFLE46E9KezrHWsrNGzPKKhNiRZyLGMqiVLIZYkyglcr5itJTPUP3yWtwWpa0EbqkJDiywMVuBzA6gib5hJJ+MBjAZ
# DATA NWOxcoxSdvTEtBivypqmFrB6Gw/C6FQueb7y1nQmJkBW+myCMOf7qRr7/urB5foStCZnGdbqEQ0zrItXkux2cDy4ZOZ6TarJdJlx
# DATA xZxUDVAQN1ogd1r2wy8OnMmo7pThKfPP4H+2eC9xpWyl5baRvPl7pKp/iT4mPwfz4C+xOAXLkVlcWxUBL/Bz/JSeM1f6OT/8lQHQ
# DATA oSnx5Cn1EPWV8JKWKdWzYIWwlpkNVyAxnNfhybFAu3CK/h+MrfszOTXkgYVoOdYlkaygghQddrovZmPhv0APyIWCT9yyA5M4J6Mv
# DATA fc+Jo3VuaPDIkkmkrQoUb00ooZOfI8K0aq0AUrGmFF9SNXXqifovODnS9m9aubokzfoFJgwDUcn8pMtQU11f1Y/xCQCsNtUfJLkj
# DATA Jh4NhLtFP7ILgeBaIf267CsqYslEDgSp3rb82ufq1dzac6RwhJ4s4Juk2Lb2QnWfd1oWwoX2up1TRf8oNoZrLa9uL/gLr2bw8kOe
# DATA w9QzC4R1iguyWzUtS350pNgRaBpb7HriUNBrcSrIqTJC/oqjPDeddliY3plpNNWddPrQwApC2+KqWNQW9EoIdDRP26LKsrkZ1epV
# DATA d+GHUIy0/55tZp9RLlhnEdV0manMGDOaK9chBWGbOmnMayiDe3CZ7LvVkLc0mnkCINXL0nipxt5uMIMqUU/a4jAdTfLipKaDTk3v
# DATA 6748U6+wCvhrZUK6yaWqTTSp5V6s9XTHq8TRweY33Y68FqhCCCq8eA/tl2BVJXjn/rBR5FPOZlBLOQ8GafNc4Au06QP6BH7cjGd/
# DATA x5d0guhZmnlmHyzhmH3oG5N4EPxcyDEmNc05LDRIv417ZOVlZ7Iy6B9aBNgVxVTTxV2V/y9zuTIMk6Bbf0aeqP9A4SEmTt34nPoa
# DATA C3VJV5LGf5G3NxIsfomx7VJm+VQ7Ian//kcJGIVzrPVz5ykoY4DIHPYx+UTKSd2II9kzqU57N59AEkJVhue/WTo1yAo7vTZkPtdC
# DATA uABWA2XyoP+jvNc222WfN0H1glbbYb3BEGvBDSByeK9oqssb0hlzsF9WD+RwI9vporpLke1dNUZAYhF780BkZAb/YTFRTsXhhJqh
# DATA u+elZDcr2uUigsOdl5u04BP8wCA34GRbT22zg3heTRCE/51OG4iXS/tynypEvA9eQH2hQnYgS3IV6h7gBJgt6Av+X3wfC4yF+AtU
# DATA BX4OLpv6CvCrSqdxPtL3yMPit4x9+TOS6MkvsGSundRgr8/sKZhHv/cNFT2IVrF/k4BFHEuAmbfM205t7dMRmVkHVj2+RrzOnpNR
# DATA ibkEzVYC2tRyGkyJZTb2frrLPXC3uGMpeYKDtcD6Yqs/ykFdSunlK/c7K33Mh9xsFvhBEW4e9pLOwqVib4wrMCqTf+bsFbj9AQtg
# DATA H9L49vLxj5yV435J7y3VY3FcOBOeEc7UlIZvy+0RLEBj4XWMM0AB2o1pkXX5kkivl/eewgbF74APeCXIeqU2liuEQun9ORbBeiKk
# DATA lv7RpQW4klXbkW5VDA3jOWBpsOX/mVTJ3v0dQSsxdjLUCny+COv+jNF0XVgb0vX9AuP8AAP9t1a/HBl5bMD+Gy0E4OeOKR9KsqXW
# DATA rqC3N6g2bSAUEqb3AusJ7idekF3oaHsZuys27eG4l3bv7Y2wKMXzlsa/7L1EH0wpONXICbUBFtY5NxVxoZp3XanF18g1nghdQGiL
# DATA LKkAtQnWy8+MyskyA4RQ33hwdBofCZUm1bqEK6gSvAHMC8YIwDXVYd2CXvpOkj/35OR7cPI4EIxP5xd/Z1z9Qd/uFDcKvU+Ruksd
# DATA nlbs+Z6bnDAHdYmfobwhcTC193psZq1dd1HtCc5axMuYWxGe53PXu07aMNuHdPGLN3fBdzEyDUl3aHI56oVCDLozxM8EaawFmaM6
# DATA 9h1FN5xVR2fsuB+epx/ubG/ttTe2HrUfbT9Z39yCW4Q0EIiRP13f2nhsi+k3Vq4BFTblDBchOOqhN4nkjQhxNJD4tdoIcJA5HB5a
# DATA 8KixHnSoL2elui/XYC+vtRbVzrtzpsS0Zx+0nz774PHmQz0VuiH0AA/jS1w0vCo/y/0hOeSYedl3tVl4hx+irg1luledl/lyBN3L
# DATA uGouGfyjyF6NbBxh9ojuGy6os4lJCtaikHlJ9lrSOOiZJ1vGWJiF3QhFIkdmKhWMLs3JdYOjV8O85zQY8+ySYpn7RT2+XFndUdYd
# DATA ZGJB5gR8XvkoxQ7CwdIVTstXuV3PI6eqWXGmLtyl5l0ZHOUnGnKmdOHjpcE/uOQU4NqRtcNCh4pg1ObS27cxf6G+DArrskrTflkn
# DATA 2fuL7T4H+2hewl8ZbiX6PuakxqWWgruQJivkaat7gA7T7JktonQfGXO1IFoe2CGRcuGozXVemFSFav/12oI2GjNw2QklBm++oHrI
# DATA yNhKpC2JtIFGmqYy0EF0cKoWHzqz6Sj1vaTf3twi6y112JKZLXhYtqAx0HlOW1ixHtsizluoAiv1SOGGW7rHV/YDCvy8PnXzh/3y
# DATA XgkovYkh8sTm1NpW9W5Fea6F/xVmj5ajRVaMgD0Q6R+UAsEc0vKNIyG4bz6BRN6KpvImb9UceicPQzZn2xryUNnMrthXRSutc8xX
# DATA KZW1hCSzxlvnVJX6ychqnlIWPLZKhD1Uu/ChrrIVNIJunniHbXFHPbcZbLp6DDKKF6lb2aQgNfQnJkaqM69C3Ueyxt64wZ96ZAtn
# DATA QnrwSC/tWgpp6LonYGUa55A8Xe2e/ktF4PBnVupOHDFpqL8c/9SFHX18TyTyPmiXYUjEwBrokxC/wFTE0W/md1UQnClJBs2OVWuU
# DATA iANcDvUrGPs+PeO2S/l1RpEp6ODpaWwo9rFthuRe4RhQr+KTK8oI8yq6mrhQNnuxG1mZICCX8cDGMXMvqz2/7Zf+xW2BsV5rLdD/
# DATA SHgutWod6uiBq2vjVj3QiUjU7gu8x3umf9GE/pEtxQHT4zI3VexK3bpPVxO75wR3WutiTDifvxiVovvXk8cYSE8IkrOCs3wTgEpa
# DATA JOPZoRpR8mzncUIwZZS8hOPhCRZGzfAkL4rGYtoRinOArHqTfEBJMYZMAnjzkntUabAffzYHpac05UCZXper9UCFh72x4i2SPsod
# DATA oetCs5LW12482Vr/3vp3N9qkp1FTR86cMf0HLotuJHOASBRlWHBEZVudR4TYLebvS3v28JfVzj1hoQNPHb7QkYpUA5fS2JQ2XYAZ
# DATA PYc+RfWTqwLfoG12SZClGMKSYXmm0hKwpSiBNR+F9CdOy+0HByG/9mpDRgK+TybanQOjbMe+DqkMMCDQBjAWiOlwkvcnNsyUhWLC
# DATA LXg9ZXwQxbnPmA7YSFZTD5g5yOcSzA/m8bIBHnVitTApLoVqZbF51kN9NVE0wcYxeh5MMlMVBSF6wZoy8lgGbc6NUyQMfA5Gcfpi
# DATA BpniVYTBv+BvJ2wqVszAJBGiPkMU5wXvDz39DkLfAqvKvFOOFX119WqS67dRylF6SnXmNqcoxMrvMj+SPB726Fv1tHnHxOySyF9u
# DATA 7DH6G6Gjy1y4ETajoeCNE8Kgq2GGongfzQBYI+mbB0mzTlMNt3B+exBL7VPEyDJvuCBQFpxwxyaEtZsvq0M6yWW0ay8fF+bH4aw/
# DATA 6HGQsLpeoFoFzMEVCDA3avvpco9x+XiayAWSqkTfI9SB3qAcRC58qTdBAbctm62o9EZMvNM7q4pO1dmN2bVVexfXUAndDAEhLX53
# DATA Q3Wjtg9A2vnrvDubdg4HGGS8mUaxtMHfioKpcWeZlhpjtfMyzKqr1wE15MtjshEigYLOAJWA3CvozV1HrPDRbNq6tbrKCmTKDSA6
# DATA uGv+3HCTAFzGQ0Pa6MlDQ4YCJm9+lXy0t/d0d1mH6Xzx06gLkA0k/ExjsBBQLzsX/ROqWcAN6dfqICJQOF7mmC4paQ/IlkTGZVf2
# DATA cqQ7oknkaH5At2Q4EoOc5hnqzHvLUC3dl9kPPYuCjXJ9OmW39aFeB+HD/SyymyKu1xbEcmEmuaAFQzI+EZTL3vXorPz2bPBqrG1y
# DATA SltcsRlJiFLXJiKpwqCHOYJwHD6n+IBGRNFJDh4rf7disA4wz0zRoCnXOUkjuOaSq2puyFVwpZmjfRGwIC7+RXBhMK671rxMFURA
# DATA g3gYjOpiwU6LCFQE1duYDdFl6bRfwLWpPXrhVRf6lLjCA1VTF9BAjAbkdcKiBNV1/04Jw5YS8ERgfsXBkb5TmQX+tV2dK4G4sSz2
# DATA fLfcEx0Rj8i6TuIQk321C9uopF2csASt4oiBHc1pUgQAOCdNu6uVsDduj1xsMqNsm0cHokKAI09hWC2eQrcJidfMAxAqTw59f5Gf
# DATA SRTcS9JiC60qgn/MPC4Sv84BZVotr/3I/xmdS4Dr/AdHNf/ln1Z7kQ+wtfiASgwvF2qLC1SrMnUD11o+WVjUzTfIx+DgPGMc38/m
# DATA IT03EpmUWvv1sJcQIPEbxz3HLHLlA+PIXpehLS7yMHaBrW2oDyQbkkdI/exTbGBogMK2Pe70NYsMrC/I5uzDOuFFUWEH/2aeBcHT
# DATA 95BEZ5OclORzKl92m8CJZSpKJ+P75HPo1jDZ9y0SSk73rv8N8iKpZZH0jmzvn7KG+VxPedNbgXoi54CjK5DDi8dZQ7iyqy/UnMqS
# DATA AJMqS1wEN4nFD7tOeUl3dwPxFZllZ7OKRsy9P8oUda9QpqobKc8mZ3AYQlZy7dFQddf0hTpOAEKxKSr+sVikhT/sWgSEi2oKYkuz
# DATA OVNj5S8y7Em5q+4a+C9b1dvVYaRRt55Aa+M6zjri5gHjOUpxsLxpn6LFSlL1npwZjLhiEPQK5GD6/4qvIn5re5IPckV4PWYVG5zW
# DATA umgjpCPDu+hETZfRR7ub+YhGF1GEOdZ+miMakplmGS4c6zhj0AqlqH4oPskPHYwF9zNjfi8HiqOa/JEahZc3sX65aLWUEAsV6LKf
# DATA JRbLsrkxtaDnBP+4wlS5n77dZOm63tl0zT9nVeJ2GaLcgtrIiHxh3OBb2te3Gb0tMxodhN3gDVjfiR31G2bkQSMC6n+xOvmHzFoK
# DATA OV+1fngln3ZXsNSKdZ/HMp1eZzxl/D/PsT5+P1xQ21Caq8pRhpqEVZxyAH/UBHuSkc1GdmLpKntX80jqBVfZAMWmqYNrHLmBBusd
# DATA aoLSbF68vdYVBdE/i7ONRXVLAUOzUpGR9nySG5WLYiKP8D9fUHMV1NQedM5GMwxgcTh5yGsWPJABvyll7dELCSzL0mJLwWL5B+r7
# DATA DfxTkWJxZXVUle5N1qSYMbR8oRwzbwk5ZnKblQF82KPXjIJ2egsSwyv0YEAMTEiAJJQt5FL0bkB6UC/o9UzdTZ7oS8kijpnka1hn
# DATA ZJMnnbG8g8zDRMxMpjdK/IuKfSInzUX0QXxdNMt24PlExvRFjh61GW7pjhI0kRrbzsgLX1ah/LYs7pphcTqsOdoVJ0+DV6dO4hMf
# DATA Iy2pSK3ihJ+43EE9qKUrnXF/BcCPVwiaMyVbOLRB+2JFgwiNAfKB/NpFMtUGGrva9LbmvUO+95Ga8YF6d66Bfnt5p8cI1Ti1pyM1
# DATA EaNhv1sDhfnaTYJreXUCyMxBgfvm82Z5+mtK/oddouxm6KWlLT93MA+gYldq5mLZpkVgm78yrvBm/BtKhG2xaoGzgZrg+EeHo96Z
# DATA i8are4qasBok5+QcnTBb5fjPHnY61CsAAiJvae/p1uDwVpXetyV51/aLxyN1fNbBwQgMO3UMkqzAiybdi1XToLYNlGRo2fq5yapD
# DATA zsM6N+hPId/obwnpAuJZf4fRcr8ETVxEsPfWgHmQTBLcADtclZqIEMMJHUGJvpM8zEKFrlWKMapSCeQUSovk2bPNRw1fLuRUrOhv
# DATA pegQtd/l0Lvbq7ezKrKw+OaLD7q2vcsJz2UadGcq1DBkVmBrEy5sKAseyWKQ5+PaTWaUcdUp2jcTjmT8rRefTGHMWlnKq/mTN/+k
# DATA /v67N5+zKRRwJwmyJJYWNwyX/LXJTKHB+Mls+Rbmz2tCzpmvX/9fbfj1L7/4Kwj69HNnwOjSiI425HTlcpexxn5lgle/GANGQK0z
# DATA OS5sxi/4BfSV8z+3tI469VTP+FmD7FH4p6PzxSeglbQhQZGKdS/TSMdN9dVVmGlzrD20QRasAgw/y8TMhdnaWsNENTRzCLVncp9M
# DATA CuSgOpF6Y31yPIPt8xTf1IR822q3e6Nuu52JLxvgGdjhT2qp6VkKDg4j8Pto7WvLkDEMadh6ab3XpnsxGky4ezQy6FixBtVNEcDv
# DATA 6oi83HpKOQcVp1diXE+aF+PfWknF6a6TI7AeE2qru6QksGUjddp6F42dqa4cLofLp9QzW3cZwu4CdaFvSnavrAzD03KxqtrUXV1f
# DATA ZFPI7ol7JqUL+FQthWe/06Fex/lyH8Vzi08KuzX1DAtsNXASsUW7AUKlDXqA3Y8euVgW/4HSRS1zKMZw5IIR1ryDBiRXb2Pgh0Qy
# DATA KvG6ucmcyLAzPS4CN+L0RBC4ub1E7NOEGqkgdrqTEiCxD/6wDKqOn9Ad0x0D/6ZF4B989eRfNkqMHxg0BvmbgoHxt0Q2DhHWMSOw
# DATA N/dZOamjMDRNPiTJkKREkA8JC0EqraPucDpwWJhjE/bobWlaYtQYoQsYZeiqpYpjq65knKH44c7G+p7OR7zz6Hs7fm7iOmVGss3o
# DATA xOBHPWxAJslNX6V4NYAWXAEIR9M4ghc1+E+dnzzefvid9sbHrtjpcstIOCjtEpTwe7PTcSEJ/9xNo1UUkKy8AE/sTtHt91vsTwnm
# DATA qOG0dTMDBqQWto2uc+027td2G/Zbu51aP9SifzycneKCw5+dQWN389t7GztP6on9/dGzp9JLi57TPzWqwKTku9FW13x07etPa/py
# DATA 4gg6xBGlXFKT4qiRUb+Tn5EoGpHKSfzaPVNU+HTjdX8q7LUeLlpOldW0gPSQHdhxn3NLnhiX6bC5N39vRVVzGTFya+AyEXXfm+Oy
# DATA hyg9P8G86iD9fqoBQX6FadY/Q8i9ry3yv9PO5EeH6qiMz772pf0PEtbfvX0b/1X/8/69dev2+3f1M37+/vt3734tWf3aV/C/GXjI
# DATA qia/9j/m/75+bWVWTFYO+8OVfPgyGZ8p1jG8tXT9+vWdvNNTWxy3h7qWrj/dJLgi9F/Gy2qRTE8mo9nxSSxmSJVvqFqWmKxr0VX/
# DATA BlMKHCw4pL2pfqpuq3hl5J/q5nKi7pj6JxA+/feoWEL/Crh7qCKae4BwqYtMTGOKsOg/oU39t7zBes+cvrrKKfN01u9RH5hG6D7g
# DATA XUoRNnVBVLS0O1ADSowJkS585jZlJHw1aL56mjTArPtXjPJ0DIlV+j31QuY8IW8L5HkcVWP9s5ekR2N1PmMMJVWkt5j2+sNGv+hM
# DATA p2e10CfMHUH6hPweExHPo6qd9MErm8TH0RDTO3UIr/hUf99MXOGPu8RL3+B/azRsJMs0ciKu/eF4NtUvzfRujXZy0gr7mkTQJeh3
# DATA rFDkoVH4Bb1pc/EaiOh4OVGMegwafpCbTotjNf3qOKgtX4fkbqqNufMDDZv61R8/wNzz9+Dg4HE5ougaVOlARJMdzPq4b3vYbveH
# DATA /Wm7zT0jfeTohdoIqQNUYvWrdEM04WXQV8efmfM7a5/Ac1L0GtyAC6NJsvFoYG5yU167Ca8pKzT9qbNCR53kvDl6pp517BygiDWa
# DATA TWUq7Hpi6tY1p/HxtFoa1QE19bb3ZqBrN99vrKr/twaDxQzCUAZ+NJtr6cUiPd7JT0dTpnWFvsSSQz4tbSeh1MS7ux8l09kQRgaH
# DATA AUqkMqJmcNTAtcS/cEFpBU1W5xUQVfGF+xXvQ/T2+nj5w9HkVWfSy3vLTycjcLBL7HLKt+oveGdn4ILmziZ1WGCCGC78wu3QQvp9
# DATA cUBBwrTnTx47g8qAGgLQFbPzK6R/04Iq+1s7gVGYMEbMC/gkjjHCUUQqrrDrzo0bch4vHKRRsxjuXuCy++k6JXv8EQeGg07tg1zd
# DATA 2CZI0+znfk5Z37cUdfWluQj5o5p/oNm9FT5GugjTQmsirgT4Nmtw2Sw+joeUhHh5j+FU3Yl6vfzq1SvMubdsWiU8Y9tiOLOOdRoS
# DATA bisKDdtqAkGCtVsCsARO6rc39tiAuJYt4BWqNkq4w3bE7oH5AUMVbh2YwBb8x5DtliHfDgJIqPbHW57Y13SbRIagzUC359mB3GzX
# DATA rhXm1k1tgxGmmDJLDGC/ckVZ8iDxv51nIPGJF4hwujeQg1TdvSbHeYlTE7NlJ7kj9STmMnspu4jxmSIJImrQqDKMucdJ1ujtL69m
# DATA oHG3b36zntxZvQn/uQX/uX2BxfSGvZ/cjDctrReKhugPstLVDwK15y0MbubkqNMf5L0mcoxEO4vaQWQyViuyELWoWaae7NHmjRlp
# DATA Kibv9z4r6pNhjkpKnph7YCkDH4FTVbSbPN3e3YNdgd51fhAbdE7d7k7HFFJj7Q9hruYaBo8fqY0+dRK66ZTrvWlD31gQis6rug4F
# DATA 4NmPVOuN2bQb096UVtYvRpTglCpr6Fzz6feB9b63utpcXfUc7KmuxvRHoHyPhymZ5risrpW+aUU77ORkb3QKXaLml27YPme2v9xV
# DATA 1envC1Pa8GU+UXJoAf6yxQ9nnR7IdKNph5I/AjpGpz8kVbtxo4Wbn8PiObcj1EJGYy2OCnQFvstM1KzOBgMEp65N0v315e93ln+0
# DATA uvzN9vLB+a36rbsXKSXTnivDP9Mib2+UE7M+6k9Reu9ZnO+E5sHbmJNcfYjBNSLna/u0M0YBhe5EIKCsP9zb/O4GatbVzUvdncBP
# DATA Jn20ubv+weONRyiH9U/VfRIfP958srlHT/PXYzCfwNONj59u7tDT0bB9QtmDbBUmn4+dO/bYMOD5tndzZ2T4Yjh6NdR6gUTXtERI
# DATA FKcASKja6WHiZFp09kZS3LiNBQh2bDWreyXgs/Z00jk66nd1Gbmsq8n9FjUBf3xzdfX9tW9+8+ad2+/fXv3mN9f0rQVLYQ8iheaN
# DATA bnOIXp4J90Lt3RncYAuziOBPe3yGsllkZG3YvdO2LkaDSIcjep5mjdl4rGRhC4ml6zM3lK3t9s7GrqK+ai0frX8C/3xvY+M78O+T
# DATA 7a29j+CPTzbWd+RlpWyhCtXaaAI+ydh8YrtFbjKdCRw6DJg/CHoEXAAbktZKM3rbz3umHo3mjZ8lh3l3BNH4pqA8Bpy7iHbcPszk
# DATA vt6SBwdyt9rH2CGzu61O3m98e6v90fbjR1D/WZHoM3APDV0v6bgCX+uxItfc4CAPU/7K0hFLoMiIbGgU5WSE1ZZQGt/PJyPFQDvD
# DATA IoGwUDywjKUhSUUj2Xh90pkV6Cje7VLahVP1O6EGEj7gDeeCC5v5Qctv1Bw4NZtrvrsIzzPuKUthNPm4iAcS4cKYQhV+ytTsMp0z
# DATA 5/6kt8g1uUc8Fyt/yXb03NKkJ5gaW398zyLHJEez6QyXaghmqCJBP1OrV5LX69hWtUYr6HbFHnpWgGMOJW1RAk3yI7W495S8PFXX
# DATA euriaecsUa0OiRd0Bgh6kBRjEPg17egco/flksOKzy3barJzsN7iOsW1oe3rcIG1cgadB3qVUt4JS4P4sTZA3FTEbnnt5vKttb2b
# DATA t5p3vqn+7/sBhkTKPX0Mq/kBhEmq9piEO+92NeFomokFJwFkYZtAH4edwS7wdcQCAnEVs+aBH1MN+X2WBShXqbBcgcuxGYkihQxM
# DATA mcY4F2mfe+3ONA3EtH39dh2dGoO5E9+KXF59xAyxLfCzVGYLmQli2gKP8BqXypJltaYvBxABibM2+gEZxYuTTm/0CiIkCzEMW81l
# DATA yPcYNDvd0aApzgKLXKh1ZUQe0j7LdOL8nZK6MLlIXcfYQtxhzfaaDPv485laONA71cRQtKbPDvCpfoIl5VC94kVhi7qoCrpvmvXx
# DATA fPrxG959QSu8ufS+roXc3GiUmZ9nIBJZWK3RNn2zakhX5Shyc9lZc1vQPXVPA11DZAgI9/EbKNuo2z6VgF+3bi7S56e6r0Yf64iq
# DATA UkzlABb1J4qqk5xTsbmkk48SDRFOUWAqCJYq3rOtURJuYanZlflDhNTvIL+Ua7WtLCv8ftrqvSYeWQPhKoU6VcPgqT/3l9cO/H1S
# DATA eW1Yu1u/exvuDaq5bJGFkXHGpMbV+r5OUpyAmQh2BOmMB/lxp3sWcQ7lCQyXJ8UqcN9hcOTsMLy+1Q1nMy5lmK2Hb2Jgmxn28h6P
# DATA 5uvJQ7M0iRKK1GaZoopSO2ol+Us1hlcnOdV/ipob5MAdAIECLyCQYPhCjvdHokT9fNBDKdO5stmDE5IVl3IgNdWjtfyyHmNgZZzr
# DATA wBBFhqCmXjkkid/oeSErgt5m4GYIUo1+i3jY/n0bJx8vrQbcOcq+gT9hbfa1qVcWCcx2tm41Of3jIbKj80LNLO0EV7VROLkIC3Lb
# DATA QMguc3iiTBzROS/khgKOZ3sY/egAiZbulo270eSnDY3WOuO+c/XWZFI911rdGmqfILAOAgzQzLxyeLas9w6GIzg0AUQyEyfVOcrB
# DATA MGbNBBLoxJo+pQ+6sZKGed2FLkkti9qDbeIxNA6RXPMQjpYOMSlQz4zyIth30LIDKXjJlgFzaXn06OioyIWafLWerJEXhFupBtia
# DATA O1ffohpbWnNIPxFQ6I9QuDNvqHqXsaGMGwe9wVeEmrmf4i83S5vzAjc3fhHGAEBBq8JBVBpI87AYVcXpZ+cDDUOqLnNoiMYVukfa
# DATA QP2wkyB6X6Lu3f1RL/VC6MCrluFH97k3B2FIZqhyyggzzTcTlff70YyMJTmLYtQ0RvEViGMGfTB547z4w3wI7pO1WD+yezQX+u4C
# DATA PzI/kyKWwBBiXBK3z4dKKH7hs0JnQqCbopoHsVrK1Cna608Pm9bIcn5R77Wge/FKN7AKvoOC0jsH4xTrNNCL3YHYZv+mZWpZh++f
# DATA 8+Ca+rTyxm1SHy4cioFFNC7abOj5smNcGrlBzqbj2bQsn12ZPZm8YUyXURsAa3AItmRVz+EIvGmgtrQkUbHTuKJro8FLbfgzZRlP
# DATA QuYnryfo46yBq+qJDzbRPxLfy0Ghb+3wrCbeKl4A9WeLqFTVuNQNPgE7wRlcZJwJ0EFjRaN7ojpUE0RWdI23Uwt8JWj89KRtvB2k
# DATA 5CuKORwJ7O/C3YaAZh8+291rrz/dbO9tf2djC4jrjk7ciD5QZB5OTEI2rSJuOVU9Wd/5/gfrW+1nuxs7W+tPUP2idaadnhKeVA3G
# DATA pUckozNifLy6p+u7u9/b3nkkq9OfQJ/E5BinAv5pWAZIaIZnYF9WsKg5Fqye0H/KO13TtHbBVnnkryATQOh2myoivoBX/wLjZq0C
# DATA LMq4+ixKLNMnAGVh2fN+2vckDXkZgW1o5Z9WS/s00xdtrNAKPlR/Nl8NTJ9TeXujwvMC9fRklk/L9NVYXTFB37vFJsb+IettF/0f
# DATA CWC1OlkqCxYW9q3IqtkUtlERvDjunIGhti5Vu671JTI5/NDqO7W3sL6TqbsFXMt8qy9FR7irSzKeeFDXfRKy/0EAoGwqk/KXhl3T
# DATA lxZdyFSZLcx7BSXAqSTYL7L09/pHRznCfNGN4B42OlJzBrxESbweN0a3cpO8mruCx4LnPtWTrx7qP2U4STM6XIFTre247jDc0Dvt
# DATA 4lxPwIGj1NsZq8NNZbvsHXBfoKDM2ZhCKZnnG+32UOsetQ2FSTRNa3pRyqAlcrJly3QiUuo9TBr+oZ7gRsVcjU1/515opR7YlY5Y
# DATA UGgm51bIuADpsNM7Uw/VDRZjKmf71/WCXKcERzONqgDFtW6X0lN0lXhCn875DBR1im1PC26eup9dpLKLqLxBr0AmG5QOQ1XRNIZ/
# DATA m7vG8GSqax4NezrJVQ+OT6bGbi45orqvk/DcSHbQ8pHYZXADV3qTs7YSevwYhPSRWj313ATCkWGeyGB4dNzQdhNUcqYIK4yZnDrT
# DATA h9K1GI350xN1SKBr38KdnqgPgM2hfeEMFNZ+tx7CBh2UjxdiqERnWPoAxTxrh0GFfYBKUV5w/YCmEX/ZdDCIDMHrLi9qSAzABkp5
# DATA hZhMHNzTZuwIWSyn6xbpsJrWWpfaCIph9FJX6m7lSVAlwgMdVkuRg2qYlrl7M97a15N165sE9hUl/w5Git2yjikxWCTkgY6OxIDT
# DATA Mez2AQYacbKTQyWg9gZndAdsRBtyQpLfforj06yvvZp78esq5lV+lB/yeEmbDeG+fdjfkxzO39ic8+nIzkc0nh22urGC2PTL4ZhQ
# DATA LX2Jruuq7ZmprDzmMjefdevbvmJD3dwOG8mO5tcOvFJs75UwST0APuMHUXbJsnCEPQruHWFwrAxlFkdNlXLD3Y/Wb965u/vsyS76
# DATA tVBqKw6DaBQnHfWyNvaQTU/y173+MRxPVPMkyDzGlBdR/X4+TMkchBIw6uPFze14MDqspTeY9GeZy0OJIveYi/E0XectdP0AWJ3k
# DATA jLKQeU7FtFubU4YeQgHLdfy1mMvoOhPUWZP5614iphv1SgU2PVOPwfrOohfzKSX50TEd9fBQpdHo6ysFXodhvCgPgUNt6kc/34sU
# DATA F2Qn+k1JK+5VaqGWSHOwaAN4dVmGq4uO50bPOTVpHTXtrTV1Q481glJaGBEtfb+07tBWJl6XdUeJJ8uERxYLZY715AzNBKWBz+EH
# DATA +ia0zDehqq91IHM0hhl22hpqyd07IDy6s7oq5Acdj2wnu5ms/bef/C93wA+Q7pvGphi505lUJRxIOjegc16c5SXvIiIYE92H/3h3
# DATA e+sRwi+XXlWI4FztxmGeGiKDaRtIqkT5EvQ25KXXEGYuQQCweSUNA7KnqqLF4VCq2aw8dnRtwRDLf9X/81NjfPXxn+/ffP/Wqhv/
# DATA uba2dvvmH+I/f7/xn9uvhsloqITpKYIY9fLkeNaZ9BK0V9xLXuT5GKOc4IApHoIoAuiXcmZ9oF6qAwnFo5GgeMPjtFIihJOfEBKB
# DATA ictUR3E40j/6Y0469/aRoSeD/LX9MZv2B+bXtGNiPW2OFxNHmp+OgVQsLe2Bi2Gi0/yBnpjg3nC20qWd7e09raknsFBTbhmR4wwc
# DATA R7b0bGvTK1sguenxv2WfNjSmU7b0cHtrb2f7cfvpzjbA4rm1zY5ercjcbY2eXyNM/mQEfdnd3Nu4ai0FieJP1j9uw+ftDz7Z29gF
# DATA P0Ubu2JewnMl1eLY23sbH8MEpGm6/2zYnx4sPRICltXD425kBRNO89I63BJbw3z6ajR5ASy7wU46PQCpn+gJWvoAfaVap0q86KNN
# DATA mcst7XPKu4MlYGMtdYeDbG1LG6/z7i54ArbMMeEjklSt5Qr2SpFTDW66RF6O2E1gHi0lhiztbxI068HS9zrAfj44i3RMzYVei40P
# DATA Nz+G2dm3M7EFM4HhhwfPIX/qAPJF6EeKvx3CUjwfSjmVUAt6NImmBGzqopUKM9cNEB7cFEgYV+XgZJJ7gJuiib5D7stBWHCeuYpu
# DATA ZwxenG2SOulhRQZMah3/KzMwaTmdF9yJ7zDOloZKNPrjtlMSkzz1u1NpebFBFXC37L8e5IjVspogaDa+6BdtXJ9up5i6j2eYRRLv
# DATA EP59RaLUrSdcrMtBr5tPoR41f8N8Kp1tUscASUndoa3MpI1TSwrmPFWJGkxxgvAtatYPJ/2eugrWE4wCxaetVRNkTgCQeirwN0u9
# DATA 8DXaivB6CD4KptIs+XFyfvPmhWO05TcPkru3tTUQLgO1cabV2n1KjGmE3jH85+6dO7fu2Nso1VI1Y1qbDIwGS7u2Yx4udGTt5jd0
# DATA T6q9uRpN8Oeqr90Bd65DSrp7CL3RlS3Sn0dIVvgT7XPZOe0P0Oe4P76L4ZJpMyX/AouK2R+nrgXzKD2nDy+SAvZrco7FL8BBHIJY
# DATA WUAnp/FWUkv7/SO82p/jPR8uTqQlkDGgYlRiSfUAKb9UYppAaZtf6szfxoMJVtVuptjyYsiFLWLWeZF5JDolnAKYIOHETLvjpIdV
# DATA ntvqTa8RGcC2KvvN5+ZI0U7yrujD+TpHTn2RnJ8vgReOqueUQFnVExwnFmszq7iXHA066jbHROdecnGxlGDCb75YQDX0mZIDQEd5
# DATA MhrpS4e6T4wm4EC3vLaqLqFgwj/jft9TX+klvD4YXefH6ml3apCiaXJ6k9FYPT+nvQJaZzEj58m5XfvTzhguT3U+UdmF6q2t2H71
# DATA b+2YzdtznvIL2YUc3VL6xUneq+tEvV1tpqfACRD0TCWn+bSTDG6jn6civC/vLve7p+qMq/+8vEuzpHo87C0P8/7xyeFoslzApICv
# DATA uXzY6YG1Ep9N1KTn+gkMRx0qNcVjcvy4eefOZRt3NCrDSd5Ri4kZBMcdyGOzPB2Nlg/7x8RmlrVnCWaJVmsFfVENqA9OnbmlNbJ7
# DATA 44hC7kt2h347Z38ssBOuvFLnTEsuZOfV/4GcYUAbu6BRNQowZg7ABJbYL1sHZQbgI6mi1G0lhG5tPNzb3N6i6Dz2vHVIt60EXZNu
# DATA E7iMeQgeuoqz9vrH8KFQFEBn0B8KFAZu+RhqFNBBxAwGFzslnKQoxxUgyCkOR8k296CH057acNRRKB9PPe3wFDxRz3vvpZjCOJoS
# DATA 0+ksFNIzsW96G2CslueTdHwB2YqhybaN4kKfCxwqyb6URRRZPoYTMk4/bUsMPJz01Wq3mJfByx96E2JXri+dZqUFTMIOl7bNybYB
# DATA hEFVpNvwJo7yfRVsPaNNtc35mmRQhvVgwxnQOnv+3ADYN/gGwN1oUPEG+/F5uZm8/+lhrCKzIWPeFlrrUIvGM8as53CCqIZUarOX
# DATA Huw3127qVdaSHDFjotJGWjNCHWW0RpalZnFgZBHhboGTOzyaUmQogXPgBzS/OTxAPqcld1fE1TU1qEMYFo8pWsqqLVK3IvGhz993
# DATA CAZJW606Q5ITcMkTVTdVp89oZ1h0NA2pHaW9HP0EQ3b9nADoYx1H8Zz5Pog0OGVG96mHs9zF/x7hf1O+xIj2s/CLirKcqw/Y6Kv+
# DATA sDd6VQOACP7b+NKvIxPpmVGrXlKsTncwgvA29KVXo3qoeNvhCCUp0LIA2krCJz7pTjqKqBcNczu52spHF6yquoVW/GqrLk6CmqSt
# DATA UTJ6BT7spFfqg4sW3ofBuqlujOSDpa/UheJ3fQD+BHTJykkpcCq8KUmN5JMuNj/oB2SXNubrLwJAn42PJx08SwklZ+IxoWsAuIBp
# DATA aCM65Oj+My1oxyY6IVxDwjKX7caaiy8JeWISciEXIu6lRdvnAr+F6lVrAYIX9NCtmyTcCplS1pWFp4tOOsaw06GYs1gpyrnfQFiB
# DATA izRO1qILJRtVs3S1FnmO4M+1O6fUB00FJGg26xXYhxaAQ42HMMYhVTkFy4vRTn40I1SUhMvr22WvjkrH0aSDrr9aAdk4fQGqwTHY
# DATA dFvYFDn5IpjCUf91K23gXlyOgYd7mKZHPYtlCnV7WKbQGo2Z9C3mrfHWNR2kmXBKGPwJW8YChyMa2uDMOYGjgkK4OE2n+c6XFwqd
# DATA iteW0OlmAeuW81baqyJC6qGZ5wpKTbusX/XNWPUQNDSoo268OukrGTRVz1zsC/WgNJs2DTrw5NbPadsErznkzyuCzt6Rr4GO1UCw
# DATA a8/UGK7h9UBJYrn6Nac8xtr/UbI6Wr15s2p+ng0hyCd59uH3ErFeul4ZVEgN6SSvwsCprosMsaULUTd88g9PG7vtzd2djW/X9Fe6
# DATA rzga+bBkwP534RjfYpx0xL9snTBK2RRkbKcMfVBAsUspdf3pJl9GZ3phBoy9e+2ml3W3rI6aDm92Pavcu5j6puh2QP+IE4LCYLq/
# DATA uvxN0PTduVhR3Oo5OAlQXVklBYYZ555gZo7Z8JRnh1yQihghdXRRHuABcQmqUVNldu+U5OO9JOV+Zn4Wr5o61oTLDwxoNtZ56GJr
# DATA Xv41pFdZ4Cv0/rKTHoeos9WKhPKWsy/aFgfh46ozEV8k84TTwbBzlaf/SxhB6Sji/m7ehuA9+Y7WXGbfYGOeydxM1gK2FFyJBxrz
# DATA IHgLnY5e5g5G01U5FGOANy0xuJypgpWegZ+NMFSoXze/EkMFUlCeJt9i8f8/DmwG6nAlwyvMeqo7UVuvaRXF/9fGpP13yL4eAPe6
# DATA BPuOT9I8pir8sRSLQxg3R/v43Of4D6mZ5y7T58Zddv8Ul4JNUDXgk53lo/XlDxvNlYP3Ms34a5aB1r7VrNtf2bcyn6P6q4K9nDtH
# DATA 4eRUclx/J2nqgI2BRtVFyAP6RCKE/ehai2kL3LmJgoDtBH0YqZqbBxonog7+sPiFd/oXH81hPhhBINZ0pDoymp5gIBfqOGTwmKK5
# DATA IMLF1zO1YLnqKm5CyiLk12EcN2r7EcZ2IGYGxa99yP1qmR04zqQWLyadjpAXDs9Sw4rUfzOB34veDfLgzmW+OAzmRTwKN1n2HO7u
# DATA cVoO9NdhrF8a4zXjdsZhdlZcJqTxBdLJPOkqrL5kquZKHy4qCHqiyBu2ORfoxBWckubSpXvkzfFRun+uZu7iskSJjeDmDoKW7hJj
# DATA Z1RyXnAh7WZcKOOZ3u6euBWZZZbABnlnOBu3x5h2mbCJteu9c3bhnfaycpLKUTg+KZA6h8VoMFPTSxA3jQZ7F5DOZ1pUMO0jzZC4
# DATA R/hVE6Z5enIhMKNMonsEiboxgaiaIqdEdywxgOECfh5UhKIiKmnL1tYYeMyb5xmS2W6Nph+C72AkOCgAgGJoO+T3j7e+U4N2DK+f
# DATA Q6CDKWAhS82C6eeFBHpCGcuE2tuZwdMBerOJXUzZQ9MrFjZWY1Ymp+tG3NBRr7WwNYyTk12iwDmnEjM33937OMvizfpVODLUo80d
# DATA d07jlRCih1dRLZDGnJpguvQDpFIwsjX5lIUr12swyy69rsh55eLEVpiPK0ytd1YRppvOKgGmeB1yDmxwwCN8IJ6fChvg7FPbW48/
# DATA 8fNP2d9bH0C2KIc+VZwbHyK7Km3V5DCm6+XDC9/gqUXOAv8ZjmpZtfxduuLiKCTRnb/o7oigYC62IzxiJ3D2jeRdI98SB5GdvRWg
# DATA aLZw8w/lTjRA614PeKHwatHD6Ah1W54eLX/DQifz5uqe9Ae9CW8a3n+VnMWyZMlBQnGMu8CeA7oZ60ug906Bx2dC7WP0huLfDgYc
# DATA 8A54iBBawVvp9sGNZABpanyAywICnVndUxOpLgZnzrIWkXU1g9EcFXvWcNOUBpOIX8hZpK/4qn00AhlZX8wLZt6RNie5AQjA385i
# DATA 6xK+eKAEGR+jHLUUDAdYYlkg1KrLGBUM97dmBScjkNstNErWYhsOnNrjG47PlENM0QV+hZDbch0IuXb31jduW6AZ+CwQ931aBp0b
# DATA d/qTAhPBFzGgduEcwnBvdY3uNUTfjHBbMvAbVbHAThRoTmTlJUcsRDrwta8E1wdgcQ6UYgDWZ9CRczeFN/lPjw4he1Abh94GR7IW
# DATA /ukccQn8NsX8uAj+tsiuEKPwHY/VI94UaKon0b8Gf0/akGvQ7le0l5vnVc2SoD9Qw1A7kT2ei2R5Gb+mVLEMAvSKEsuAptzZfnio
# DATA RScaVjIOdqVFRMqcSfY2+ZIQLx1jA21a9CbCFnewf6hEgp/BZnVdULWKAmvRWWsPMoOPN+10T9qMaCxGhOpZWPOrzO8OVce1V85w
# DATA uHe4XfSQz+LGlnSfPKkP9i0+5mr97s2L1O929bbjYetvvEV/BwtOypUuIi5QtStk6E/VH9wq7QkUiSDOFwpjzLbqWqM4SUNpzujs
# DATA HBJHNThUjUW1Z8O+iXwM4Cr0UnEHdKhpryl1YJR2pRRNo0xXIkqhQ6PqMhWVTo4QxaVYVSFjfnUnSCe1eAd1h2rA57F6PCa3EnbB
# DATA LPabNxEZcD/1os4OO8XJ8yH77iTL+ez5EHHnHFoKG5GqARUdonODfALg13k3Sc1mNWVgXFQCNANZJNkujSU6sQA3Abealqlv/05T
# DATA o8Y6GwIxr9AiAbFkrDzkz23V6hXRMioE/9WFQJFR9F9zgMx4NuxOZwRA0T3pTIpWeu+Pfnz/QS1LvdrAxDLNizH4DGKrqnqowysF
# DATA reSYxgAjq5ybKrhM1bAYA/DhUNhO4p967sYBOLxiyXnuky5+pPrAWbavM1Lvv0EtBqGVwe9/7/xetH7o8GgCMlcHMg7CgO5DwiRU
# DATA auhnpmKKj2BYXn5W+DfN0m3ibRU+6JbEXXKnsQ8g8TlDp9S1YVCs8Es8Kfy3Jd3UbTxVLXWq+H2dyZcDnWCbMy4D+6kf0oZ+Zpsp
# DATA 0v6aJoWzo1dtHc2G+FAmm7vpLj0F1yy/B35P0SJHJnqkBPT35eYL5B9K84ax+cvwm+E4dJ/h32W47gIJp96pIzYtLYpemVhWw97q
# DATA lASxaaVBDXs5zKIYEV2ZTvroMAdv7+Nb3lxNF2gV5wOLHcAOpEGRSgc+fQ9skfJzfCc/gyK47vjpvlOjD2JK5VvJzQrluBmzvr04
# DATA NWbxCtf0AlcwQ1hnYjzVDsMeq/HQXUmYcXA+dTNxbmI4CbEHcLhA0osqZDPYjBFSHHRJZs7b6Jw6cbtF/VDPMcbY5Ip/NYFZm+Aq
# DATA ab6ICxNc5vHEaBFdSnydcZ88QZpfnvA7nUCsS69tK48Jt+bUOqWj1oqgVCgX+/jVasG+PaMgGCNMmMYBtxkZjkjXYSpOV0bjqXVJ
# DATA SOP42JDohADVj6PNAPA4i/lGNPYqNghovCTmPoCH0J+V6J31yl3pDAENDmOjELcCr+q6QylbTp6iY4FO3ZR74TF6Yffd4gHivRT7
# DATA ySkEgZg14K+J8TSeE46+YpyRA77nJKG/Fo4ZsHa2wnl2VJGECeY5ccbgKObk8jjAkTVqilLY6UI604TpJSqsIwVBTxlonedsYL1S
# DATA FiyUzPbRQZSNIZbDDZslyZAJEm0lXgqAk1SijTxA0O4926ERoaalS9E6a7FK08rDj7yjRCxzt7vpIwP68EkWhwi7Sef9klTn9zZv
# DATA pVtALrHJbYlcgq7dRVdJJFrNshT2Mj51LmVCQI57YKllsgHuEsORt7085SLZYgvNc4TPoQ6YPx29BDgco/clDC7xgENyHS4vASLq
# DATA 4BKjr71jwrRsuepNwWqwB9BXYLtZ5qhdXAB+21ejn+lP89JNYdqGLUZ9biUSPIGzaXIxaTkOhCGcEi0LeYOtzXMPzLJKSYvjAjnf
# DATA FHt6s8uI2FFmOFqigO9WdGbZXl8g5KahAiucIe2d4i2kBxki1lILd/xdqb+Cw3V05J3YkZhRwsMqdl14fP2YiyJJ09C2/a+lJd5P
# DATA JX4G6dxr5FF6CV+EubWFvgpO5F9W7u0L7jOGJZkBt4JJiKEwens2WNda4OjDnhwxP58yd6QsWwjP0dvjDz3HKLHLNSug2V7B7yo3
# DATA uVGc03g1pmLh071BZ1hK8zRRrAtatwDBXNJxMH7aRKE0DkRBbiho0jGrGBsfGEvYlDIZjfuoWQJsnAZoTRDDrYY/NbxjoydTfoFV
# DATA Wgk5Qa1cl3SwjLsVQgj52bLjE7gMPoENgDROyfOj4aJ6Spe/hDthPFTnOXSA55v23yv3J2EgFx/Uhf+s9cc2B+0yoiIQpoX6gWaf
# DATA MXGT/jhwQIkpbco8T2xtKGPqfoCHDERmXIMgdjBYj+FP1DFQCZEgt0GhfNm8acFVUKNly9kRL8t5f3zRgIi2pTDNuEPSsXg9ub36
# DATA zbtyyIYzH6UG7+j50GAcPR0VjHOE8fGqoWT5qBrnyO2XJLQhGoo/YYqq3fVQUbRLFpD4SUUMYu1bTQxD/DEDKmSJD6JiQ0LUql8k
# DATA IQOYSHyR27dvcfBiwurS5Pqku9ztqCrUcL3allXx6w7lBnOcos0vO5N+B1ejNjeAUm0T7irPy0Xi9qeKZx2lBv8Bk1KxdZfS1VaO
# DATA RK1U2H3M6du2ewlOkb4v8XbXL/2rlkM+UrUuKQdiA23KztfqaBbSqeP9Ju2ERTYHQUIAhZh3nJwetlrecjhJvmSz7iH0J8FRpfej
# DATA /kF4viR3xo44FYUhlEUDYpsVU9ynSvAIhVkRKnoaYbDg8nLamQAfBT9koh/I7ZEvmD3WhJ3lqyGKEzXJXYrcPswNxHR6CSH2SIkL
# DATA 0CTxxiozEfVHbUMd1jjsB+QLGJzvIUDliBciTpxwPsFZ5Z7A+0zkeoXPooKrL6IA4FziCydlZriTfDB2zJSOo4PVl+vec/myi0uN
# DATA 3rv2kSgy4/PhlwDNCMQACge77Ho1uKHqDCqvaXDRCi4Bf+jUlsUODi9VyTQveNuizi6wxtE2hQ+LI42WCnlLS//WQ7SUQupg1DUB
# DATA 4YwsedQdTgdktlUv2+xoqNuHZ2nokGOKmuxHocuhKcN+hw93Ntb3tJvhzqPv7cxzQQQl+V2tJHdd3T2XQdv+79tf0HXevKzjIEwZ
# DATA YJbrmZNeZrhOjSNcQelVSc9hvtobH9viZ+AeFI91h/B5sEA50xZX4rTJ6V472Beuf4h+GjX8XSE6rxzgg2NI9MERMbNFE1vqQxiP
# DATA ITLeFaWupaJYjyvjMm/Ah1LuUlcNE/RAU6YoPoXY1GLWlRZlYYzAI17Kx0Z7eFY511zZarNUod8W2hypXTPGo6XglX99vYwD1CVU
# DATA rmw02xpJd7JQzRqKGfesQ/6LviK2oQ+dg7XSrldf3uHW769xFk5a2XnyPXTuaYi9/WBoo1CtbIYAO5X6dpBFrdj4cd0moFncPOhv
# DATA 1p5vPpcpJnxfg2rdiHX6jfGneZunegNV7JGqiazcC285ieUTWT6ZkV6UsX5/V5bMtxs0V9igjJBSL4y/dDXyzD1B9VJZ7N6wlhIW
# DATA dXc6QMrcLzQG1bIS6FC5OB+lWghnAvIsTa9yUKXeC1xeG6DbfJGfFTXJIWMcozR0MDLMjmp+uKzuVZDIyW3chsGoHtTm6erqXoei
# DATA +ZdsfpbJKarRliJplRgxsCSnjcwW1kD0dH2jr+GvxsbW9sbWXj0xv/Y2njzd+8Q82Ph4c3evKlFROamkA+BZ3mgBFbmnOFjjOkEY
# DATA WCYVg07U5VJQhl0D7C8dOypZeN1gHZCOnhiAPfkStLoCW0DNF8jZQQQ+Sv8OLEmlBYCKB4H4KMx6r6RMOweWhCRTmks/XSrWSile
# DATA bRZXL8Gr8e582R/NinbE2Tx6yZEx6ahUjZcyk4MKvXMDFGoXBcPcZeNlhiJhcuIvtfsF1u28sq4yuM4lbVjfFoQjTbRTCX3j1A6K
# DATA pkBW87xoXKxtSBpmEFOXtAYTQTgdlO5yhG53Zd4S5BEIHFongltyPYkGYgCFOggsCFiNG9VdDmO2wI4VyAcjDMw5pwhUrNXHEpLR
# DATA ShYmKOyf9tajPDzWPBjgifhx2c4e8vUFfm1xGBWnCj/+OTL3uKnabZiHdts9VSUfO6sk0L3P2UzaNOa7ojih89PUu0zY2JuJhD5z
# DATA z1vTHYZ6bY9KU5yRi6CTpKIzyrir8M6wZD7Um/yqIgShpkq33EgYd8ByvTUX7Da4q7vXWKMVR9jHBsYXxcCGeMtVJmJcWDqptryK
# DATA IHzZRV+ClZOmKQ/j8ZI0yo/K4FZ9dbUa/j5SkvIBVgqP8xY8QukW3XEln0qkJCffG6Z2u1LSN3zvJRAj4Fgn6xmKMTRo3Hc8fsVB
# DATA EKhA6y9SPo69ZTrvqAcB79Nl9kml74DHpHXh9Gx+oFIJoyr6U9GIQXE6qOj2MjdaWQQJy/KYPHnCZHCrlR+ru5j/KSRsixfuD1GJ
# DATA HXxQ1UCgkCkbqBN/pFO4UdlYHjfMuKaxi1tmCcJrOHJ/yqZNhHr/5k1M7c05toUEUBbc4wAVgQzZLM9Hlu6wNONlEYl0WW4rCSpO
# DATA krEM9cMvhSzkSgQBRgg78FuROhyS3xdvT8u4eSc6zuuJyVNOAWcLNAZXH/d08aFzffPD5cVC5CPq9sHxC6bvKnVk87Qn8zUo70SL
# DATA EtFh6J3fcGTpMhHac5fO3tIZzJ05xlvaXz3wkgA6PsoIL4ktIUdaNRVa9W98w+h2wjO44H71iKjF7Ki8F8VRWX2LDyCHH/VfQ9iB
# DATA 6vEyLamA2Xg5Anh/UMqtoKVyoph4kXS6k1Fh0bMnFjM8uM1+BTdM3eyl779X7hvMh7BzOaayRW1djm3Lw8yAisqAkaUViCGP4vaf
# DATA yE4iOSDuSrlPQesgaprw9VpsAzNn1BjER7q4NRlAJKW9CplDh7oUyZ2882BurKUsAA3sc45HnABeSungk0eTPl7QqspAbXOn90ci
# DATA LvYY4uDQIdaWVZKx5iJ0Vfs8XjkVn6ys2oonZgkKSgzeciRU737ruuLW46EkFXhk0fLWXfJyd118ns3ZcijeehtNIH+X0nntfLEg
# DATA 4X53m7hU72sPpr8KlYOYj1xWNjflXvkL6H1Lzj/dad71wZ+ndCvRB5AQHuxpDzwWAwOwiFGlHGSZUNaVz1PF3kSBs+xa5m0smVEk
# DATA 4BOmigVyOXP65kvl/4Ud8SXl/p2b/3dtde39tTte/t/Vm+/f+UP+36/if35SXv27mF4uP28XruRFNFsvJE1X35uf09PBJfP21pOn
# DATA s0n+FFASStL45l3FeIto6t4z8xiSpqsD9HB9b/3x9rfbT9f3PtJM2SpmrekuNWejrZh0ZzA6Jl8zcCnSdejMtjc5ra3MbvtkfWvz
# DATA w43dPZv+Fhwa8RWY2h6v09O79AgjjHRC3Lu3w+S5AJkvakfz3ObWt8036r37Qn9493akc6bUo42nOA3fWNrdUz1qb60/QYe/hkl6
# DATA QaR56Y+3n+1srT+OFFgWGZK4MIq/karIfW1n4+HG5tM9U8DWdNjpvpiNuZLtx4/au3vPPgDkkvT+td4INxluoAf34b/JoDM8bl3P
# DATA h9cf3MckgAiYkU9b1xFITT3FYKAH7Ot+f4V+3h/rJyAmW0/I+yvjB/dXsHrwZN98tLG1t/nh5sYOhUl0R6fjPvAUBMDR6DcIfnP7
# DATA /Yvn31db46ONjyNljxA5+e5tKrO3/Z2NrdJSt25SqY2P9za2dje3t3YR6qABvcLIhm5RUN5H+qd4eYz/Tl9P+TGKUGnjNZd/lR+q
# DATA o9o/Umw5vVC7vzvoqLvirppsulrZW5bRfxY6lKYdgm35QFtzQbaqAbZYiWV6kz569vTx5kPYiH+8u73V/s7GJ46uPw6n5UJpcd9h
# DATA Jgi3rxm1AQnNAqFsHZ5NA3cBhjOLgvR5YT4LoHa1BWyXzvsn8YFY9IWRP8rF0528O0O3eFqniMU/mMfNre+uP958hLOobkFIWfEb
# DATA PT1I4jzMOS8o3OZKzhyEfIjlZmQ69WvtG3ixT58/x/AYfFHRsWdbu+sfbrTXd3c39pAEp5mDgCsJvcwzBIJ6HAgXrneETHhNY+Lp
# DATA CHYDjQth7Hd8OJm5uYIPZNpgPOjfxKzBUGUU/AZewCScU2hCo5FeUETUZCrgiBrxxINeN2rfaipW++PxZPjjzuz1j4ezwY8Vvdhf
# DATA U9368WA8xT8yVeh5o3Ej+xb3Cu5ljc1QeD/iXriAwZkJ1ypmR0f912r7vgKBWt99LRHKrrCiEWTBdm+E8uml952zrLz3HiQ379xa
# DATA 4Ag82n6yvrkVy9piiBnW2JhAVvAxro9aLTrs/d6wo37qs98puv2++s0TVQb0dZkTqrsnz6hE0uLM3zTcqhTXvGfVlpCs6e7ahX6D
# DATA u0SxOqmbLw8xgsmGspZ0a2D8Rppl2WUnPkqjQakXoJc6vjrvABZbb3K4LZmaGmqnnTgpVcv2NYV+22393ztMNkyHush2popswguw
# DATA D05J/IVn/UM1lQXebUEx+/r26uoclo0TtPvJk8ebW99xPQnjKNbViNNzGpOLsr71UInX2ztuo7VRQQ53cDlGZDXS0Zc3GXXoqsTn
# DATA rsLdXmS2vrezif47JUOw89YS8yb8DAuMTnv72cTObG3vtdWHGw9VPz65dEfQqn51APCFe6jqe/Z4fQevO6UY3m2yUAicZKYgktJY
# DATA lWVwlM1B5ti8G/JAH2RBglB7cuPqwvZp50VucdItrDviTd25U35akFDZ6gNqhbXjoESddmSxqXG7QgMUmwSNHm0aq0V6pt+eI9ik
# DATA 1JEF50uYidwskKHHijqrdsnw2HIOTfgPMoX2Ua9FLVI94Ury+Hzc9vINIBxBKBFqywNi1+RxBB5R1kZERDF4/cHm1ro6OPAyZj1q
# DATA C7x3bC4TyOtK4sg7pxF0URNKRSUWxF/XAJ/iyNlHbpyUfT4PWd0/jaiVeLz5ZHMvxFLn3pahqXeOpvlk7uhimOvohmv73B+O6t4Q
# DATA 5O9TcIlvDwmAtIatmq/ML/rI/DTfVIgEOP6HH61vfXvjUQjjXhLr55yppreJTbZWx4CqWdg1w8KabiCZa88TRqf4hsZfhsb7ts+l
# DATA yiwFTHv05g2l6NjdAjKLofC1v9b00Ag1MrttA64tWLk58LH4wdJIOee+LkeBLcUErso4Ra0euCL/LwMQv4wIQEtsO3fpsMGA5kQy
# DATA E78Tel+R20K0m82PeCihz5ezbs3dHqENSx5hd77FG+c4EJOicxY4EUTZFq8J6Ia0JrkWU0qNO2dQBrgVATMJRbUTLxhooKuTgyxy
# DATA GyXKxnU+2dzd3dz6dngndbrL8Egt3W9fQWZxGp5PCN3ZxcwwuWt1s6Crgt8Bi8OGZHC8TvPK2gEu4AI+U4o3fIHAGPwU+N8cLqfv
# DATA r86cPFL/SgRmVXzSGWAiSmhjXwDBGpxoRl0B5AW05YFZhVwKa/w9n8s0f9kZpFkFQKOtpnE46p3VsaqHI3xNkI2YMMIr1nATSChu
# DATA +w6GDvyNx8KjaEP3/ba9bHzjSQ0+JDBI+uwd9GXSeYW50F9PjcZGqmfjStbds+G08zqqW1V8WE3j5dWskT5G9Dmozum8yjgu3TnC
# DATA i55NKXix0EWqbqi4RKFG+mjMB4GnIp+ycHUNbAtF9yQ/7Wg/4YJUlriboNC+fn/g5yFx33oHa6GZ0iLU6FXBSvZ97sNByUigqIAp
# DATA dVTS8A410o6F7Ypdipg5VP14R1TNuOAdYR+9yVZPeK77PYzlATMU+XMbV3JEZYOARZz/gGuFbexDZQeumtSarKRqUJfFYuaX1evF
# DATA 2tNKRq9NML14uSH4aYOUpwb/VT+HzX7aed0/nZ2WwblL7HYPtp0nnGsyxiZdIWjfamY615RsAyh37qzeuruaHWTZFYiNjPNkzDec
# DATA PVqmKjhdDgQ2mwBe39L7lMJS9Ua1dt/L9BA/cOJQBz1E9oLt5oankrwiIlUI1yQaq0JWIRfeTY9QPWx0lfwFTUGc1lA3yuMTw+fG
# DATA 7EZJn79eXUW1rO4H7xL+6RPvbA5yx+UnSGO4nZ+TVvriwumOFuxxlMJSg2bXbFGZnqpuK8LzcOOj7cePNnbaAMK48fGe1xOaOYhE
# DATA qHnz6qoyU0Rap15oowxtRZjU26u346+i1OM87RyOZlNjScZfK6KBi0Yf00TkaMjnbbqQfm5n4989U5fLR0pS/fbGrhUfHZyOgnen
# DATA F74NPlND8HcDHRDKyya8z2xf94m+jww9YyFuW62sIx24rRNu0o10odGAuK3W7fHjTTB9heZnQ0EPiCCUmjc8WV9nWztXJKxpqJom
# DATA auQtVsEfsgvJhbzbBAl66jwfWHUYer4RM0KrW2DBhwlr6iNgpXVxROrobKGx76iaevLD2WjKnp+ZIQ3BobHRurnAYKugS+yUJ0ms
# DATA plKcl4H3irEBzicbrgM1m7H0XBF/np1WVVj9/RXkuJ2NLaALUoyL7R1aPvQ+MvOu5kIt0VQrbOkxyH9sVeVlljKVt00MxjbXpAmH
# DATA K9NEjC7f2dr+3hZRVi1ZuZ0X+63Y19UfmK1nDH5nw65UhAldVyui61pMR1GtvqJ9dhl9WFTvHNVcoCIJhhRTOERjR6uUNjJsk0T2
# DATA QGlzCW3293bkYJ0AiI2PHz7+0tXcrPqBwIkSZTcrf2nYeCHxXx0NZsWJkGfMfAd6Y55COr89x8GAd2hNuJWzh0E+LBQHaaNRv8XA
# DATA 7kCF2gAfwvmYilztgo5apqIFKeHVcJppptOGZMGtk/uhPjjtd3k6ZGdKVg5OzGjSwUzDuGuFG6JwtMOpWgaITfBlbMB/bivif5Jz
# DATA 9hneQqa2uj8jEfVtheZt8eM3R03Ia6dZjOhfmJQzHtYc+5qPtjjlxaTbds6uOkjFtF1ynC01ashXwbllgkltlhj6OGjblDM7gV9E
# DATA lf/OhL87+1uQBT5qdxMd49mLqy3VSYO7n8n1yLGBNAoKrAvyzcLj8nyzxnYxybvq3iewtKejKerUKJwPgBc5CRM3pG5yIssSv2+6
# DATA t6AJBCCPkUxygcZ4NK5l3obXZd0AFoeNODaWOZwqWEGqv/TAlPIs+u5L5Vqcn5ca1bl9RWcgH6v45Sdl4JGFQ4/m/V0sO7CXJZg3
# DATA hkkS7Dk7g/IJl/hBEvoyN0t9m+IC2d7ORmjO9M8UYGbjsJMVGgkuUHwIZGOiUpRAO5o7OB5gkyu5qf8y12xA/25PRzXGDYQAILX3
# DATA alnZBFY7uuBivo3/T5nVJg5SYQeGK2qSE6Q2iLNuRp2Vf6+Psv6epSTcBWBijn9ZDpGxgM2pxCAogEU9V/tlol/NSue6K25CSx3f
# DATA azldKS3d6x/nBVBqjr9oFCedm3fu1srr/zKcIaLwJG/hIBH73yWcJkrW9h06Ulxzlwf9FvSD/nCER9DxY5BfqJ9Zc65v5iJuCeXn
# DATA 0KY2dHte+RkxXPPx/D4eclC2dAg5VXdUSFV+t25ryua7ovL6YI3NhfKBvs0E2aPTmI3BraqGDc//yM7sMul5F/iOlFRmgta+5MVf
# DATA zP2mpKNfuffNuxx9wH4Qj8xynnA4vAfU1Yr+qslQz+jVvlRsuoSjAkvIHsk2lzitImPxKMtk/4yOBVFFXCWL8ZeWIIaOF3UMIsIT
# DATA 1x1zo/S3C6PdMlc5hPkpVK+4b3TX5+7G3pl+165oyXzRH5ImlTVRqExFVZS1s8FrdbcJ7W1Xs33ax9g4PvRhrTBSPZbY2hvivu34
# DATA IhY+/5MgvMRoCLEgT8QBzpr7KGLMoQKskLVzHwzB2LecDyJ2rtI2cDW88X608XE4UCy3UAgC+abvWXWl1TyzfNQfJk6HQ8NYzCgW
# DATA sbFjdZWdxxKXMkTKni/gaAgMR5EHJRUPRmcAbxXTGtq36i5j4jQdCRgziUww7DKygZdfrulEP64iSeovqYrAL2kDyY8XwxDGRXju
# DATA vDkkUsP6cMvS35e1CMJQ0yC04mk+QaA99v8oAdONs50Pnu1+Evp5OLd6KdtK7JkqoTqio4vNkNRGDKdpBHSQop5Pi5fdyTR4S48x
# DATA IFfJLE4GA371WO2MDx5D2oe1RTR0AZiRc7VYJFmCmhfxe+uDYLGqEY8vs0hXz8jQVn1BiOLaID+CeLv+8cnUZbTFWdEASqxozamT
# DATA 0kUx2NnrNIsnCyYoo/4ha4EpoL7x8NHjx4xnPyvyNgbWC9CVo9mQcSLMluIqCBtQbZDO9KbaVhhUpTtpvqrMXuw00OhMjrFHmBKd
# DATA +tZtI9yf+QUOG+2xeDDn9Uy9P3BbAfQQiPFuOZWE+lGYe7wfwh9trevVb2lN4DX+1Y4oUXWLNacCFIxZpQ8vKNNd3anGLYVvdLGb
# DATA lBK5NBctgyL3xPjUqtGiWuMcFoAgUoPMvfvJroHlRppmfm0/3dre23329OlFxRrSweDDU+uiiypo/hQfNU+sCQVh1smpERQsxVQd
# DATA DpgpR3ut39udqJmLKe+phcWbmGY47k+xAeqV9b3N7S3SteyKPKcLH7LIGZl7uEpPz9wTFB3N+t72k82HbW0AVvy2/Wxr/bvrm4/B
# DATA BVz68Xwlx23RIxccO1p2Uszgn8HRkxsGionf7RLDkTmKXpXymLEjL5+zsFK3tNxr/MmaD59pgyerjmO4qnOPkYECKmXQaMtCoTJ2
# DATA zJZCFnu1/UTmLZ45aRTwTiPbk65pV+aGv05tbeL2PjEkg1A7EFNNiJeu4dO4nRChEOH9UdA6MjXYynQvV5KUWitS+NsIpXCdc+iN
# DATA bq8lKkH/R3oOYr9fecGGBV3aenzw+wWDhT9Yf/idZ0/bgG9VFfxMWUoCYT2uAhgBTB9Y6hS5A28xdJgS3waW6KhqYNJ5pa/ZJXcE
# DATA 53ZgEWE8V4+qm3+I4C5ywtq0CgbW3TosdXMlaTkbqDPpnoBdoFmmf+ACqq8SU6ZCI/EOdAq2g0aFUGcUs69al8B4OYFKgS/1tqNY
# DATA Q7jjyhAxqsEY3GstH2LHUWpfXtRDdYSeEJyygyCnaC2qHeDS89UDXDDLFtcQ0IlNpSRjd5Y9Bc4lmUIP/G0oC5ccjmjpLJLwwGxY
# DATA jxaAp7883UjuOq9C8olii1Xy8MTMk7qYfLlK1bAJwR88FZ6NR4hpLigkcgJuNblz2AUXqSfT0YtciZCjQa+eDPNXjMBXZxYlMSL0
# DATA OsRI25JFpy/pOkUfi6YdMU+wCItZ28tfwpyKb9yXC91KaY5RH/bJ7t7GEyED6u3hNKE2S03gZIELEE6RcGvwAry5Gow0X111o3HK
# DATA VlKoceJb2gSZREu6NNhorQ0RbSZrmo42K+lZPRC+JDFrRiiZpsRN3DLh57T3m8nbHCWZBYNkIs2f9D4jZxmHh6avXr2isDPYhIps
# DATA xXcqFFAvLhd7zAzRm1/cF+pvPkIsL3FODxAb5G6HHAODHk+bkqfyV+pvOHDOFEKZ3Xcwg16telH4bKd0uOEB/nEh46bMbkLerF1v
# DATA PYy9G8nNeTNovpDWdu2v56ycBLwjh8wohBDJREf9Yb84KaNnjh6UbxDCyzU/hM3vS1+4c2TmveOgiOMciCVilEFkFlqEogRNR7WP
# DATA LkVFvk27n0eTOeD49Ep3BNUkqoZIGDAneaNydT01vv5xsQ60IMnXK/EGZ6iicaPa4yrqNOtZJFqZbkQuo5ERh7zIdbv/gkR0RRHN
# DATA RTJvK1E1P1AnZIi+cqV7VqokuXho/tMvrmwB5ArqJcfx7cVuImcuHWOqxQSrLuiTkcQtOXl3MvkCZjvsrCekIuJjaMWiollcdheD
# DATA PdAY5nIXxCT38BIdk6YXFOjjGHK+hA+rcFBPzA9ahIjIH50tWLwFBHosVnqJoEVe+BbBxU2r0VgpD1rNUkmJ05nqces6L3Pj2NtZ
# DATA 39pdf7hnI4w0RHbMIG4vNSiVlt6e3KsDV0Sqz0X4hrsxly4jjEY+FWzHioiWs8zlevnrsRJlMapR7IMgT7Gz6IziTRdPODe6krdc
# DATA l/Yi6pF5F5HubII6rNZbyVBsJ3qpuRO06fC9Ov+2y2+SwkNWIChv/EkQXj8+ncE1VHff3CftebdJUAa4Wey84xucmZbuwFy1P82r
# DATA K+pS0kBBdJaqBJEqXZLcHY4YcAkVAdfVM3NvJBujYC0lTkIPPOkfYwCXe7TcT5dco3g4Lqolq970l7zt2zN2nDtynF5emHVKesQT
# DATA EbWDmBsRj1TehuJ9vEI/rdjotlJP/APgi9LxYwL3DW+U/IG3q8vHbrdl5HqNXbWNRmRclG8jwqjoqQ8EVyqOBqZ6at/U6W7cS3RS
# DATA UKB6eB4qaFE9emRwzDjvcrvNmXixRBUanssMJTIASQKxg4txFbbNPNz+7sbOJxAG/uHjzYd7aVZFt8xw5x+vcFjhSoaLQ7bOEpJl
# DATA TrvpE+bE4Y/nUsvKAX+VvJELXDMMx039Ws7FFsI5jfCm+WnbdBSYlSUqjyhrI2xpVn9mpcKPNNbh/Pot6R7wdU1aCP2l4EvfOd9B
# DATA WGmk2Wds71r9TpIe58N8gltSfajPiaf3MZ6KTSOwGd/FOcLIhb4lq0vytN8ZUIS0Pq2OGw4/LI9DMy4Z8aivy8QmG53DZcKTdQff
# DATA UayXo6bRMRaXD+8i84dhEBzmDy5XscCto/4Eg0yGkLKHS/j+EtrOj0XL08N6i+J/aRERJSgGXBvDpqu9rwMHGS90i5pbNHQrFj7y
# DATA loDLIVTuA7IJOpEl18jdVmfJyBYcaKDNcxYcpCcxv0FgFOu3DFmsqCoWErZYjxxDc1nHnLGjUk//CpRxprf1EBwve9sRxMKFF4kD
# DATA qPIxBCC1fPIy5svrQvBpnYHPVF3b4lLJZLCSMgsrFCG6zAzgzQwyhqemc6BjIxkVDAgcPy8C+4hxRKwh744d+AyHnxnOJVkG58dk
# DATA TA1xg/LxNVrpRBHN0SnGh2DMuQYHEBc1aYKsROKA6HFQOHJVhjYdjkaDiCu87oRVi5lH5AVAXTM37mhAgEEKWVgfBRA+G7sGWM6u
# DATA meOw4xjc7NmwqpyIizlfxmzpRVXXNvw70F6rWYkprp0QdJpuG+fCtcFvXzIwhaqkCkmYoucTS8mrfKvcMyqwDRFGIvRYiHLOTWRJ
# DATA 2Kv9VkkWKXP/1wFQL3NW/yxirDKd0t/5lxUxyVHqvQDJIISNgGKYu1c0nEuSC9M7N2DGpQmikHh+IMmEKMLPDi78WA+5oa68gRbb
# DATA RJdSO0b4QOyaERlFXIVaLjYv3nnS1kX2L0lZNEXwFpTD504DZaFv+weuS1t9sa9MpF+F8FD3PzdvnPC/0g5UbpXYPR+eMfKSMxlX
# DATA meoKoCdC2x71u+RG3O+pD/tH/XyCphzxkxGgdPdr8zeJxdsEyRSeiOparZCPZ1aRWeQDrdevLcjvPXpD/J+T/jVoiDUeKUGSGZbZ
# DATA EiwTv9JvnJu77lEUDuvSkFgSMNLBxdLtCFwsG9v/IgcJwsf1Cez/EQ5b6QXgy7C+mxAribx0FJcFjpx2JuqKQ1nfj0FWD+AxmHNR
# DATA wYaPUSLBi7CEadj3a7WgWLdvu/1lgA6LJHfOY7shMX4YQlCRVUrufJw3JseD0WEtvZFm2UUdsPhag87pYa+DxZp+JrG6zhJCkQIx
# DATA TayPkDLMWe0VOutUOEM58atNs0ltJGtTS67xsGeOaGxqoD+PyJVBbzrKtvn74KKsdXbHkp4XDqF0nHrMDJV49iyimot69jhmCKOl
# DATA uRbxAFk0tFzqui/rxth27JPiUZBNUEpPTPV6qZASo7wFCVzK95yosBXxqysTvso2nyNbRcZkpSo9U1Ko0uiGmCQ6vIpRwbpRHLZt
# DATA a6W3ryhYevh1uZdBpPjC96Zvb2xt7KwLc/GXenW66u3CWvFFj6hU5sVNcFERFSIb1aDPC/pH6MowCOdS0RPpohcb8CwqvUdmzpWx
# DATA qlzc/6kKsMf4CbSfbmw9cvFurTWjRAa+jOImNFxENiyOb0GfCK5poXHa/R0hhWyOJjGn3OIec0SkefH8QpzxmsLaIAh8Wz8Db1lq
# DATA UQ/srWzdTI96bW9dop76fC2mxud74dh4JNmEv0jua7laesz+5cDrsdPeXGnSRmMtysJ401g7Y93rg/HNdw59NV+j799SKeAqBLxp
# DATA dC4W3qSVuCVjnQ6Xs0OWKgMEgw5YG+r/lAj70s1jqeTFCTpCUZ71xvrkeAaT/RTf1ATQcyvdJAaeHM6GPcXGE0X+OoMEiKxmFwUS
# DATA xtFsmuC8gV4LciJAn4uGSagLNQPGeLvDjdXS5WWJuwZ6ydZToyYo+4KkzcoyAmdFTUJHzYxRolZ+R7O3PCGnzsX6wxIQsJcuTRgJ
# DATA E1O1capbgzm6wme8bRbuoCbPy2ITaT6MAGv8Hf4DXxa4YbJommp43YCOB+efDnB45UdXCvyMOx445eBLJ4ujNferNzH24pfRYqj+
# DATA zSrwSrsbD5uiZe28qrH8cKY6UyRidyJRjE5l3ex9sxWgF94+DebJETndCag7s1UvnQR+E1WVhlb8+fNs52yx+fInh7/v2CnsJbOh
# DATA upvBTMKWgapnhaKqJXPiWESic6JNI/jDmibkFqialfGkr46EAF6mphdBXs4C1rE6z4wVwQUJOnCeYglmKvg3XPrD/ii5GO65LcAZ
# DATA KKbqOj8JOrSmSL45ribhDKjabJIVAdlvTurBUtyK6lQBQP5wcUX0oXYbFVntNqxGu81eCNA1Jd9Oa8hz1IR97fL/A66C6691h43x
# DATA 2dfe8f9W1f/u3r6N/6r/Of/eXFu7dfvW+/oZPV9be//9O19LVr/2FfxvBtgRqvmv/Y/5Pz/32vl1Uk9db67Vr6Oocb25f36937ve
# DATA vI6C3VTRB3VUrtevY5YK9fjN337xky/+4s1nX/zZm1+++dUXf/bFT7/4yZufJ28+S978Tv312y/+VD1TT958Dn+9+fTNb9XHQuCB
# DATA Kv5P9fqf3/yDKvyTkq/qifr3L1QLv/nir1WRN7+GV6pRVVRV+StoTf3fr9TTX3/xM9WNn6p//0Z9SDWq4r/94q/Uy1+8+ayhmkcV
# DATA 1vXm+XWdQ0V14v613ghhIDDpxYPnz4f34Y9koCSs1vPn1/Oh+s+D+yd5p/fg/mk+7WCGoiKfwkvUnuF7fAOHFh6/7OevABZJ/ak1
# DATA aPD4Vb83PWn1lFTZzZfxR11bApYLJezlrTVb18l0Ol4G+v4SPn1ItSzvQt6y/vRs+elo0O+eeQ2wELZcTLrJ87TIB0fP03sJTbn/
# DATA cHo2yL1n/dNj5wm6yjXvJaPDH6jl51dDxbSg8GGnyJdVX8QjAGVZJjHLPg1nR2wCr//ryct+MUOpd5ofjkYvEkxXo6Tc4xO4k5wo
# DATA RnIyGvQKZIXTEyUZdxRbTIpTEJzpMgEJlRPQdqvnii2dJnmnAPPEdARMsZHsTme9M/x2NOn1hwC7xEiySqADkfoUACGx17jVHzwF
# DATA 1TaIN0fgPZL8OPl3s34+TV6OBkr0u79Che6jv84kH8Aw+l0ameruEfxe6RRqvxQr8LxRvDyGdyhTQtlTVf2Kevje69MBtiprwlUq
# DATA TvJ8GqsPlqDRLYpLfoZ2Pv0ZLQVA6AdFfgAlQLDPJw/ur1BB9QeeBDgmkO4PtwgqgeBzSSqwdnVYBqpK7NOL/lj25uvAvqDQrnoB
# DATA q8P74P5Kh04btCq+P4SLhTMca9qDatxVUXUMOy+VjNLvLA86hzQtT0BuUo/7xx3efNBCSX3bL/MJnGOsS5Qq1P7p54UptzvuwAFO
# DATA +LlfHLagKbsD+/HVaPIC1waLrqj+8KTCgEk07MGnen7uc2omOxVjsPXAF0SZ1h7snXTUEo5BJjYBbWqLq7+VrDZsqOrXHtwfq2J5
# DATA At+q43GWnHReqj9GL0G7C5n/TvAAQCpHfA2rgWIm7NRRI1HfqmszusMpSVydtikcsbPRDJYOPtaKKn10VavjB/d7/Ze230QaCn9n
# DATA HM6mU+/AuEvxgRIydTOHubr3At4uT7RXC5gHR8OeOtVOfYss2orqK+xzmu3ItPMDmvSbD7YnybivOjYbq0lSpOVopiZlNBrAdN+E
# DATA 6X7YGXRnaI48GoxQ+s875N+dILVPepPOK6A44NcHM6zWy2yOpDfKaSl7+RTQCtUNQsmuMzhbquNg90XgGgQy6o6UiN4HJTjN+mX2
# DATA nxnvCmy4B/ePlCgPO3Hsnii1u+RUgNaXbglQr80dpepTBR/otXe6YhORwTfrSNn/qHM6vgfy+stO9ww6lPy//5xcqv+0arrXK0CU
# DATA 4DwxL1dM3zb7B27/B24/j9vTtrwCk3/HPP5qLH4+h//viMG/Y/6+EHu/HHf/Spg77Ug5fMPQ//WcICT483mnovSjItccdF2zTVLn
# DATA qRaRu2v+KYcMck3HDnN0xAGQauxqW6FahZeIp6DbnyDzRQWeNxE4PSjSaBZcoDptkHcmCOV/qpi22lmDOjJgNYj+ad5LDmf9wRRG
# DATA APSxoCGrnj4r4BOUtnT/9AigBcvRu1oeKHyBgMSB0XBw1kg2p1qG60Keb+D4MHGKbaGm2Zq1tSjQ6QGHQfUidhEWZRnFAjjrRYE4
# DATA Rslunr9Ifqj2CjhraePCST4Yo64KOpl0jo5glUAg6Rzl0zMzwk9Gs4nl0Tw0JekUyWQ2NKLmITg75ZNGssGJhmBKYRyzMUgrIGfq
# DATA XQh7vEAZRhWAFAojEJIUeSigTGdwNu13UbpRY8snU7DxH6shdMD/Qru2QV3dk7z7AlWeaNpBtafTmf/2k/+t4LGClhf9goruaKzq
# DATA QXlSrFkjeQjrn6BdHhEv1MDOYORcF3wBXX0JTeSnaqWOdKWocVVnvdNXtGiQ11EOhCwmICjT3A5tz9WZmOJiq29UCTMjCQYG8MYa
# DATA P/j/2HvbJkeOK7/3q5RD1rJHBDCownM3Z+Thk0QvSdEcSgyHqBcFoNAoDYACq4Duac1OBCV5V3Zo48qxN+JuhCNshyPufU9pRXuW
# DATA EqkI+wt0f4X9JPf8z8nMyio8NLqnu+cpJZINFKqy8jlPnsz8/95Ojmdi5iEjZWfZgGoMdqyVoib1VG7JYIRTVKmVo4cbRFLRx0km
# DATA RYs9hSmb+A+iaJ436nAwgO0/SdAYBgO+foiAYigkQniJM5NGD4ST1bwPE75vyaVGt0cpFxny0rQoBDpHhMeR7iSo+nyA3iZeSBIo
# DATA aLu5UI4tqXJzNVetVbfK6CEZi0jiMQVmsmLEk5dCQb5HMTYblzKIe2A33lA6GA/HS6iE0lifKx2GiGLNexOdj+w9QJGkGBcj6ltU
# DATA daX34PwW/yZVSln7l57m7DbY7DTD2dFMvjFj/zK2/hWY+kWjiez97z3qJw/JfPkF8DV9rqVVuvIYDz0iiyeZTKr9iObCcZLuZ1MK
# DATA evwY4T6ahinVhv36AVY4DlO4fvaPwnSvWp2H8yi9dTBIJvSIXCK77NYB+q99vzN/eNuvtVue/IKwbh1glzl1+cfV4zSc7/epBj6o
# DATA UtqGj8NHEkw8owYSLw6g7V9dYuso2XpRNRmNKEH7tSCIpo/D/THCecT3DMEC4UZSpco/eDCjtrsfzB8+lkpSiWfz5aIi+7cqeAJj
# DATA zSOOonqXvrMmfx8N44yG4RP6mV89mkQPD2i0OJxVecvf/iACJvrg59Q649FJVbUvfZnmp2S0YFzdbzbnDw/mYhzsU05Qn+n5NR9/
# DATA D6QE9v35Qy+jKc3Qs/JvJaPRecwWxZym9OrLqjTTcBgvM/WzfKlQDKQ8qscSp3arfkBTqYzCmSfMuz4oZeM+JjAqT2qmiencya88
# DATA sqJJ3dQskx1TK9VBBfVTtlCxlzuLhnew6PyzRysJ5eTbAUgVU0HsU8lgVBk+SubhgGaD+7VWS6dGzQGpcozIQMiqZA/GGIHUo8WL
# DATA XClK16SKlC7qClO+dzmlZnFSvPqImjZqzH6jVKh8F9V9+VnXZSqaxxIP6q/3fspTJB7GqVX+7JZ1EUWZ/OzWSh3mmfS+X69/t1Dp
# DATA 2lTpNtQuvP7W7u04r7qoubWOVXF1ZWvoRJTiX7EuSvxVdANqmgcqqvxZKnF1tROhZlfNxil92a8/LgRHtvrPHunI1R+bDLFywe/W
# DATA KWyqbPEvon22nGiYeszzI9O+D9N4eHBI3VCtwSkrNJN6Xe6ucZLMM5s6Aw6mg1DK7d8OtUmhjkBdoPJ/tLWMdOr8WtDSoUoGUryi
# DATA QxrFH9kBd+p180jdqzXpkcdjvzIOKuNGZa668OoimdPjY196P3kd5lcwkyWgCkjLGO+m872g1sSrK+1a6+i40qrhyy3q0etNFVOV
# DATA J7cOJmQJUZWA2xURkF+pS2CyRqVaqzda9OjBNHyo0uC3B+MDFal+Qu1zSgltcKSD3SLnS3daaVDUAs54RM3vnhM1ikvQQnYW381v
# DATA bsib6SWeynUKsVEOsPgkt4zHyGCdtHZnMH4cTw8r2dGhqTVMQjuw2quqIOFykTyWOXGF9xnIiK6aCnBxflCnilzBhGkPT3pVr40+
# DATA 3UREBik7pHPranngYnc5jf2L4yiacU32a61SVfbrLdOtmGxbV3Mf19h7IXnZkbxsSl4Gq3mpcy2oU4VYOw7RXKKYIO4X2HrAf6Th
# DATA BWpo5b+P2R1ybi6U2+mmt3uhjFzKq38HJvDPyqbHvrFUDkrN8nEN3qBHEE/gG0fxw2h48Isq+2Ao3QdolFUfpXwA4gblNDJ6Qxdt
# DATA ugWkk0OWIegRQsGTj2tk0iS6c6wKM7CNsiv2evQfs2cNfe9yOsv2/VHq0b+b+jduoBy+VyPLgV7DaeUuVps1eZE2W9QQ5O5RfLhM
# DATA I2NI5lcHIXtDrXBq3SDN2ydSVevya9VU4vy60C0970sbrSmDv5Q1rXperfnu9XVaPcwdUjEKOzcmO1Op+17p/lp2LPlFHnWGxbso
# DATA 61Byj3YoyzSa06xwr1Ghek6FslevUMlSt5HH6HFtEKbDR9bIYo06bR7qy7UwW6YjHOE+x77Ybo7Ke735Pmb/1cE4ngxXk8m31OA+
# DATA r9SmS5qUPrINBL5CAeF3u/L0JA+PsS3ftgZ6a9vUevO5RZ1sk/5t0L9tmFalcuL6WSgA9tkVm8sGQ90MMAik1BtKmvdni7HkyV4w
# DATA u+XptGwqiWDVantcM37Tcl2nboCShU7C3OIpa0Ay0Az8GFox6uMDQoSv0hrkOl20bb7q2YNfp47rlJ54sUsdpcxUPY7uXgqthKE2
# DATA j2vwLRhrL7jOeok38WLOqomox5aamG8XaIHB2hbIYclmwEeFzkrMPbuf91Sd21IHVMp4/Gium1FabaEh3dHxmA9Lorfap0kZ96I6
# DATA RvuUlMWJSSOPhDXZtl6wsWstbTWr5hdIt6J9kWss7aaduvoB7qryAo56S+7HnMSPdjA3SnMU6jlo3hQPokd2lpTnY7o56uYh425N
# DATA CoWml4eWEWWiXt9hmJBnvRDTDZoP7lBJCnXDM98CfINNt9og7DGl2F979d0MtGIsvbk1MKufMhrcZ4ePSn4DaiDhYdk7Iqbtlrpp
# DATA CiiQSWRarDPd9uqkckPT7Icl21a3pJWxtWQXlLtwMQhUkJ5MCvHIvm/Ns/wm95TSFPKMLjtvhmE2jooZ/NNxPBxGs58VGtC/Ejxg
# DATA OFs8pub2yPjBHrLpbs+NMD/I39c8p+nbWdnd1LBLbrdwdnIMN/RjrI1IKY/CaTw52X+LTKyExuXKZ6+9H/f13vcPklny2WuVKf3h
# DATA cIttnvJySONwPMmsbAp2r4/Kl/Ko5JUqO61K9rp+p1eY3XITVpOo85rrQXF05BgHauKTh9iwh/t1RucOBmC5ynfzWFqtz6oDLYyv
# DATA 6oaCW4NnKrv5J6nHzr3VpZnohupQm8eTSTVNjs+3spVNvYjmptR1N9rMf0Inbtp/U3XQC7jwOLxyK3jMP+mCoy5yEs4zskrUB3sC
# DATA bddAHpgX48piKNMyzot9xKYwju5UGRfbbK3HNYpB9Ih7cunA9/3bVZ/HRstHZBkNYjMky8V8ueATCeXMkjkV79KvYtlmjTWL42nh
# DATA Ikkf6WF3nS0rNVp3dKZCP/4302gYh3uWidambu3Wo41OB9vT0Gij71VehWJrUTbJ6ujElUVOUWC6K9lk1xmen26cf5YaZQMzVzsr
# DATA i/NJ43RpcV/Nc6MLGWPaWN0cH/vl66eQDSw2FGeIO2bLisGweVoejLSPsWVZKfrBu/Zcyq6eQcl81mbsar1oNrhecB5WtJW7MT7s
# DATA lhHXC4/qvbxwChOKQNx0aqpZHB52T/3OyeVOZM38hztyqkom3XNe0syqaTRcDqJhdZpwschXah3r1sQ48O9Vvrcvmz7oQzhCuwln
# DATA 8TR3GeXj/AEvisRrftHRkNM5ui1KM6zoxaiyw0PsYy5NZX5YLl9ZqbN6BbYC1NywT/PTB2a2Ub7p8ePCiqHetYUdgvTHezidzHjt
# DATA E/vy9m/fPj4+rh03akl6eDuo1+u31QYvbCB6M3mIG+te3Ws36R9e9kWN92QDIH3ni550ZPn3lJ/zA3we0RDEe6Ya9caw2cPGx7tv
# DATA sFwJ7xb6wG97fm/cCI66PwyaR359TP/t/tBv/6Lw8CgYNUYNeRhRLK6KZjRCRk+fyC5N5GkyzylIJmp/G9+Yb8aiits/wS+8by7f
# DATA Xac2P5mr9qLzfr6jx+wBiIa8Fn5iNuBZWdKre81my2v0ml7Qqk8a9cDzu41qo97x/GajmDHD9rAf1VdztdPwGt3GT/xOexIEfrXX
# DATA 8gKfHq93j+jv+wi6VQ+KQUWjkc95zNOFB5z+7zRbrXoryi9WTdE3Vl6KULv+UTPwp/Vq4Dfxymqvx5FREfF8qRWXfEMQ1L2g6R/5
# DATA QWPi+77X6v4k6HV/8UGz0fMaPlWfoDvx651qs/OToN0tJq876EVhuBJkp0W50hv7QX1abdfpnyN8bNLlRrM79n263GrRP0f0sRTz
# DATA frtfb47Wxby5saaq7YtUUfdxsvCR8gTvqxp+wPP7fdVYDvTUdv877Va738AF432iR/h/B8agWb0S7H8n8qNW1DlQPrb977R67U6n
# DATA dSAWxv53+qNBd4An2O1MPw/bjWB4IMv7+5+9dj86TCLvx+/RdOGTcEy2Z+Uebx/LqCusZlEa41ndpe10O7qnGnZbksmUd+n7Yk16
# DATA QdHp3BVDwNxuRiM1v/lBRG06DisSdGlp7qDsCINxVunUmkfHlY44wjhgtVNul+n9Vv8WzVSLIZYd5baZpwpm9QHtQy+OE4W75gWr
# DATA UkxOvgHjzyDGTqJHF1geyNcCxANYMovEaVW/mHHjwUVb3ohR9ArUNxqzhdRWVpJ2nnGnPHsrdYzNhuu0VB6vtvWfo6l/9hp271En
# DATA EQ8WvJN8xhsgvX8NfTHvzl2zBbL2+TJKT+7zvoAk3ctuWfeam++laXhSG6XJdG/9c/cmE3rUelbt5fvr6ATSi/oZtPAatgNSbHlu
# DATA 6b3uffbavh3BaTTF6WzBjn0Qzvc4UMMKZznjB9FJxRuFkwkq9y3vEQ78038lAJHJ5z1l9yUSIFK/R1m9Z0XqdWiU3TowVGGmq9BL
# DATA l5OJ931vT2JRG4cZXnaLLqkrFJRc2bcisO/h6KdoEbDY/oH3GEeVB2OKlXrDRULE44/tVPOhekm2QsU+0o9n8rj+4UDlRSH92Yb0
# DATA VyTeqCWzw3h0orFVJluwxWZNWkY43L0ayfBkD5PnW6YoIgjU/uu9z177jnh+P3uNgobYUDQBorWGu9XpDLoR3w5KQY6T441hijF6
# DATA 4TBny+lePLyVp+bD5bQfpXsc5mcQ/aNfazo3C48O1SbSPZFzQ+CiZ0Fv+uw1fL1NzTmeHehjLnLG5bU89ssU0f/xx+/XZMflj/h4
# DATA CH2Hepv3JjT0fopwflbxHiHgxygMeTS0G5I8/c4kYr2Mz14LORvCGnb/QbMmneCbji9aE8UYlwaTePCA2hS2nn4ST6Nkudjbu4U2
# DATA jkil0REZFXmkKBxw38l+VVkhUcH6hi4FzCbwcjufkhk2NO+NZkg4ygYPsBDeFEIf7xxRpN9XWisURrbsT2MqyIoXHXGx3aXH+GMN
# DATA qjH0923ZmLWnipoDouk4TYV+AnpHvDjZu0Xhz3DDYxXVf43o/VQOXIRH0c8okjV68J1wMN5Tmz/5RRMymrNQxOi4d6EI4Svi89Of
# DATA qTf+K+kB44z/7vEN9Eb93E9/pkuJ8h+746HLeUvCl+snrGTJ99doVJksh1GmopF3iPQrvc9sklvc09L2KGFr6xuidp8b7d4J1DrN
# DATA M8XKj3d+nyrmfUkOdTDyGeeNHh/oqO7lj68pG64veJ9OzlVklf68Q3ZQAuQuMqppart3hFiAHXzHW3v7vvfTWo0/Dyvr7jAFRRZw
# DATA hmRyPLh7tRIjkS5kEXq3/BmTrWYf+nI+1JvJCxv4Vb6/qba9r9/jfiDPSFi8pT1T29lxJpQMiqOoxi38sfxbrN5mwatYx5OHeQXn
# DATA WzJdbPSTyRTz8OYilIepDE0oKEQEsmIDfPbaup18drT4d4kYf5QIcDFI8Hl9kN91Tyzf1lVRPnlj11FlguQauZb9si3a+youn0HC
# DATA c0q2h9Q2E4VNNWdDfuoIqNqjv5J9NzukySBMH4/NeM+8ly6WapluLRvq1YE5ULG+ZqHa5PVG1R2dPzBXzQjN31RPLjfQqE9zKzbG
# DATA +Bb9vdzdS9N8T7RMTfZzJrM+MYf8fclF72/+hmKNCkH913SP/iTvJ8dR+hZl3p7JYmoIGYuv6VcWniYrCQnneo0TE3Rf/cCzGgQy
# DATA tVjp6IJdNVh0EeI9dN3uNIuxyWsip+WW91d/5e3pqN25o2OCSHFApgqYfLtzRyUF9Re3yLIevflfcRSkufHHW5KW11+XglLGDlYO
# DATA dfbzl9zcwbdbckcerOQHesd6PiIppSIpQ9xgApHfbql7SsOHhMW1lGMYZTxwUMnrEl3TGLkdoS1alQLJMeW4tQEXHqIXIY6qmlIm
# DATA 60BuFWscblQWx96tO3fZZvzstXfNoTA0k9f3YPZ99po0PUr/9+Q7zwG5uS+Sd7Gtbi+49ToS/L//UPuM/jd7W8+Sk2TBrlYvXHg+
# DATA zVhelwD4sBkFQA+tfw8ZT7eLt+bv8vld/+cfrQd1hHZ4bjCVxi0zwPxApjuY7Q5mn3cw2x3IfqkPZHuF7cbqHPRzfVDbeM7458IJ
# DATA wIl1fPv+nNXyMLLFQ8BG9Ont/HbeVszn5J6v89wvyqnG84RbbEcpx188znffoJ623Az1IhmiYVYqurLeZa3gyYVwwt+KB9XLi1fS
# DATA pAcJMlfedDIb6GgoP/bdH62sfbGZSvZA6eC/9Qx/4XRwBszvctHuU7lDD4bKC/ZQujjBpmLz/Fx0A7JxyCdidY3y1IYLmhbyceRl
# DATA n8Y1D15dD3MQCvNzjgfvUoqTtOb9aB7N+JzviM/u00PqMD9XVo/CGqPWUZ30ZBsCY5hwN70ZjAUKaKZ0A3ZU3vFKPm6tI8DniTna
# DATA ZC2QkX2Ic2lGhuevccwZFQ6nu5no4H20NO5eb4bLrH4k74jpp+UcZkNW82BL8Y8Zm1TJCE4eajFDWGqq2ZC5nLAEwGiZkhWxXFVD
# DATA eDkP25oQnPXmrLfzrLdiDXP6Ok5f56Jm20YD8bp0d+5jC5slB4HXwLcJ4TyjwPPsNN62DZfY3efZcnUFS47XP9j+wKKI2pKjr3Fh
# DATA oxMSO5Z9AjqTlRdwb3rrDfGJ6gY44/UoFJKEZp4z3VV+hb1ivP2j1uJNRFrDmpLPG6JwcRryfqOW2kwSzXn3UU169tscx1JUxQth
# DATA qgO+7RBR/ZSJp7lgotmota8wmuIZoZ+1l4YvvCGOVhUpfY+JlHnojYQ7/DxyAd58198P6m/cTpRVWL6npe5pbbnHr6ub6EN+122J
# DATA Vp4UZavr3FSrYPRg3gwWtuQRmQ38BBsS6ZTey3uCVTrVaihGL10180vS88RH/KI5jdMLyYHbEgTmTyq3ZJ3WDiW/pHeomSt3LYMz
# DATA xITM6gBsaSo2GqXZLylVEH4xBuUHNBhS/yxGo/ZaW+0fY2w045bPhqIZaONU7Miad2849PhMrDILMj185jak9z7WUJSqJyYCZqRd
# DATA QjZdHL1slIohTj0O3ohdGPS2+XIy4R+XWIalQT1OtfH/4ywS5R0RsRHdn7gfUxaLxLwWkdJ1Hgu2GUeBzBIYFmxKoyfCvCbOMC2k
# DATA JM2k89MqV2yvTyB8b/VyGAP7EetlcqZxBy9FwqXx8lvN9gDoDGdnOJ9nOJcMJGc5O8t5uzn8HChWfkJv48aRiWZeOFStITebS5qN
# DATA GFyMzhsrIj6IFlSgs0ORtitKLwoTLBlh3EqUBGSulCh6iGUjueSfxXZFKQW1ZfGNcYP157SQs27sFOOGuMyMSCUsGOxTgt5iKNFl
# DATA MexkNML2L8j0cV+QeePkmH72qIRkuOS8rnnKuICkJcXuCOMu+plkxB0D57klXyk+K05OcdBbhOzNvJdiuJqYkc6kyE7a++yUCwdk
# DATA 40BI85h6rDxlGHmrPGWQDdGMOg0nGW8Xg6WDJB6SLZbpXm1IhTem3oxLiZMpp3wohBmLisONSKbTocydxIjR/rJkSlbjQqkLhrAK
# DATA HnhaKWRLOt8OT7gn3p5QlKG4KlHGOo33lf9xFEWUrGE8Ymk/mt3BUIPAIfYwYh8CVauFbMFgujH9gqaIX9gE9D5hDI/HfEEEyJYV
# DATA M2XhGKSqqBNiLLr+8kQq9ckC9RmbRLck8uMoW5NAMSsKVXhVUNVUdbJS2W95DFV4VLIJmiCPOmm0zohFkVa0HQnCWziMcfZOBjqx
# DATA U5WYJNXej6H/MqRMJLuQbT8kH3bekowJfuKBeFy1S5khZajdU3mn2JN6Kq2lTkdxOuXFkXVzW07UJ5Q3Mh8Ho3eOY6RkJhm1dWpB
# DATA xnrOF78z8V/L/ZQfXB3JFFDT8zATW5h7J+8DLe5JvSvDHtiUViBu40OmxvOAzWNMDcjwpZIOl4sY3UaYsk7XVClPsvqpdCjgQonb
# DATA mCwEXFdTio2p/etZciz1E62Emgj6SAi26gS/nXD4C+yrRG5LW6QEzeFK4K6RxzaxSyy/Aho/lTK2NMQTA9dKebqQUnFT9pGNRBkm
# DATA KaQixwFp7MgIVxRkC90wTxFmJ2U1WTOfsGVlLTtfbOaX0Np//LhiGDqLQ8B50xOboPP/nf369I+n357+z9OvFCPnq9Nv6P9fnv3O
# DATA O/0nMG3ohy/o39+tonP+G/3whG56gvsZfvPN2W9Pv/Loy+8NROdrClQu81eAdn519tuKd/Yf6Dl6BreBnvMtvelPjPH5O/pBmDp/
# DATA On1y9hsdmb/QLX8UUA9gO46l8wLMZtAp4/gSdTh9+rMoiGYfRgmFk8YDbYLVvHcezicyPk+4R4ykb8jG8Zx6i4nljdCdI1YR51Hu
# DATA M8jnQslkosYneqmW+d0K1cFyogpPtRSH1inOb3QPctNgnXUlc314nbzqmFth0uWXyw9MRG/a3P2+fOcR/YoJOzyuqWE9UZtbMZg6
# DATA wM6OxXb1iB2svUdsfaJwKrmLkY1f5B4cMlkUFQzTMY0nnI8st58tMFMt7VbWSE0EYQ6lxIsVvs751W+zQ3NNy3pWmJ3zk+E4O84S
# DATA uA5LQAN3LmkAvCLOzRsb/K9l7N9p6L/oyH8zA79Uz9V8yBk8z1/rug4Yj5UDjOIpvnpNeldBHvS66VytJKrCozxL8VIFvokkazKV
# DATA NxVPSWB76fhkMZ5yKHLAhDNoVwSPKrJ8IZI64gnjZZZYqYVK+gK5vVD+WTkmNwqPEowKijWjY4wXCNyEh1N6UFsM6lzdQW4vCLEI
# DATA vh+YEcfhbGG7xQbJ3DF2HGPHMXauk7Gz66iy0zRnVyv5hk3+y1j8V2HwO9qOo+042o6j7TjajqPtONqOo+042o6j7TjajqPtONqO
# DATA o+042o6j7TjajqPtONqOo+042o6j7TjajqPtONqOo+042o6j7TxPtJ2gFV6WttMZtUaDF4i2s7r2vBNzh3NX5R52ZXr8rna7oJDW
# DATA apZyvdnuFrk5UdQdKbARDjdS9AYcaKPNMiADDjWQYFgqw2+2ixCfBmX4GjRSp+k1g7oHuo3f6k38bt0L2iVqT9tvtbr9VVJOs+E1
# DATA /d5P/F5z3OweBUFr6nd8r/4Tv94YNztHDb8YhUEwbPb7axLR6tbzRPhBzySiUQwg6AXD1iqxhzLWa3aCscpFi55jHlih57QvQc/h
# DATA GmvRc6jyF+g5rWY3vAw9pzWMRn5Oz2kHbb8zNPScQbc/GvZyek673fK710/PUXW8ytXYjAsNIejo4bZw0zpHVYPHkUrv6LjSZUuq
# DATA sMbUGowPdibtlN+mHNy2a0tMDHUXjhZcDW7HDnEVt6Mmml1jrKKMD3gnxzgcJsf7dQ/ejbqnS7IA6OF2vfoK7XY3pnlH1k8KuV66
# DATA qbBWJsN5CYZzsGE/wOpopShJ6zy1sm67JWTV1aihTTeUvGY0TfzOd6WqPmMzxadQ2ufYiIXMswtTJUZPXmCFOMqOo+w4yo6j7DjK
# DATA jqPsOMqOo+w4yo6j7DjKjqPsvFqUnXgk9hvWPVDjH9nfpO7cUSOmGrjktwrXxVsHjy1MzyPJN2TGHQ4Gp45MMK/TE8DvfPba66vv
# DATA UJX6QA8o6iWrN+a3qAMadBfbuQcKEvQhjnFJy2dTfnLCp3P0W8tRqnn/Xp2Btw6l8cEzlDVVKBOFqr6Bfvj+thH/irLC2Mwmqbw4
# DATA VVs8XORppt7xs9fet07emWRQd6lSIBPd0jkfdwTdHUHf+Qh68UCYO4vuzqKvnhrcqLf5PJxRL9XxQmuxxWnY88cCtKjMWa6WooRv
# DATA 42EUZgV0C5+IhrIlyEU80mTUnck5Ya2kwlvpSqdldz2DzklgfUaM5SzOpyRB6VVwoc5Fj6/PsouI35rDoGqX1ap+vbJdUQX5k1KD
# DATA V8Lh+sdcz9xc4e22kP+MOBwTvTizsnqzyrsxiFkaXT4XNd6tO0z3aT+1otAOixKHO9GhyX0s7rpJ0F11qRzWD9TnzXfL8XpWueNP
# DATA m+/kPlfJzA6izfdJv83p509bROXloKmWcxc71FZzxxCzRcu9UBPgP7dlXfNf4K3nrk7PA+STzvNynpXENtmtb3oBsaq55qVLzo1/
# DATA +cf/bNJRjriV/3OWKEWfMwnnuf6qWkrkPWnpEhIJsNESlmKYQQmetaihVhpTLWQoUzifU51kfV3qmNH6aBI7W8jxf+ixLqB/pHVo
# DATA WauaFz+0yOwxVW51WFz5vOyWmZ981k0jP1htHGe4rJJickYfvaQL7AvmmkL3WiCAsmrrhYoor6gXLaC//R+bC0hXeime91AMVJEz
# DATA XUCfHCfURlPq2Dx9yi9TJgj1ScsZPJE0JM1r3ns0ysPImSZHIkhBaWDBAQgbHEbcraKAZP+wKqdIq1uo0nr6UjEpuLFyMd3CRYvl
# DATA 7//b5mJRXYyUisiBDpKUJiOm5czURFgu8zSnz5qurKssn7x5iIY1FNNBFHxH1Icnx6qIinYkS7OzWVwYB63L8QJG9NOXkp2iGyuo
# DATA vF++cA/3u80lpft4KapPw3Tq8e6uvIs7xjWB4wyPoIVNJXNIBcPrF+jrIhnuZ0OR0ohYPRY609EMEBwpATUb6EdM7ogXosmB3bH2
# DATA z0ydePryyZNxY6XzNCPQ//NPu49Ab2GQjVIZEiwd8Cnb1RSv9IGytLlJhRNWLw+96ZLGn0mYYp/cHPLJyGjvJ2I8qgGGTCQwDKTZ
# DATA oMSfviQK0X0Rmso/7NpU7iejhddHtQ9ROnm3hjG+T1k0hZYNNGMGNPJgcsCK0OHw5yH256gan6GwUrbH42k8wXkD5BRUKshS/3wZ
# DATA i1oNVBBZWEUKUCtCX0FTKSTjUgVUNALFo2kbgeaKZPfdDxPte9SaQjz7UD7BJBUqIwbohDtxXbBK+Odp2EGvhriLg3M7V9olXGnO
# DATA c/aKeM4uyut+LtQdC/svt2O7Zc5NA+kCWzXJojxkp9ZGcvdzqgL5AommnacNbe97vA6K92oruXKW91oZ0U1E79WUq9uMOrY4XzAJ
# DATA qnm+kcRmZ1JFfEeiBnmcGMdF7mRS1D7lEJ4Cym1k/vKCrnjLTPClkAWkYLAzQpKQlbWw19Qapc/NdTLX07yUFviH8HTNDgENFMC4
# DATA 6PYYKXBLWVCDb5Rm1r6RE4VZnYuK2kqiHvtMyGJdSGlh3gPr28NGXOhtHhXqg2xmk8zi7arQRJ3lDV60C3VuIYdrr5LxaAfhzEdn
# DATA Pu5sPtp1za3DunXYp7QaNxqp17MO+4FwP22l6Jx4+GxIFTdBCee9P6hefGywsMypfsrx2urWlfXCfCEpXx7btLZoL2/YqzWb7i85
# DATA 2ktLCZueKrh/Cz7tTU+U3ZRlN+um58res7JXcOPKaaEUeJMVYorqNIyHXB9koen7b2j5SlUs6l7wy2XPqbDE1TlTTTovL4LjkLnm
# DATA 79kWlae599Sp2zaVuMz0q3egiPOmgulJoQG9uAhxLDQtmIQ6R0+fKUs1mdhvieZ6PJEZJ5vgkZ5JGYgktR+zWrVkU4FCo2fw3Nu6
# DATA I0HfYg/PnhII4QmAMdnVU5/CEpe+R9Ydh+Ja5n3lFBMId2OBRj1xO1ktuHzeuN5pnNe1fG8hOJ66j6KSLpXw+Qzwl8dKtuCALIWU
# DATA TAtswP+sIH7fnn5D//759AkwfE88fGMs37dg/X1z+hWgfKt0wP9x+hcm/v1B3f3k9GuPQYG/P/3T2f91+sfTL89+Rc/+SQX6tUII
# DATA fn32a1yj3749+8KjLyASCggQZELEQZ4DsJC5gX9xMMAXweov9N2j6JhsB55Ez0NI1yoIAHr16QjyEX1IdmkMCHV8WJW9p7C6SZ+Z
# DATA B6p77utOS/fZyzm/Bk2IwyMjYyD+k2ixnG9FAN6D1IU3XGbY7ELt2QEAC/a+7iVumv+3WizXR/9jC4sJK/mthfpW5pnfjk6ieRyR
# DATA taHvf0dd8KAyBIR2kl4xBpDVwxgJvVzw+K/OaFETcyTAXYvw6lGA1NdgEZza/CweodNhGDxDnLFdLk0eQkMn4rPLYsrDYEUtpM5t
# DATA sMAWhiVL/8uPmdp8ovee6IomLlWyxJlxg2lcfDhbwQLuXi032zorDe9ZwQF3T4yDBDoL4eosBI0GvJRh8Go4AW/MKLgGm2Ank+DC
# DATA FsHNGgRSRcvZYcyA56ZVXQcS0Eq1Wv7aEEUNF2P3xYMT7zANh8tQQf+yfPUBMobFNTZGDRYXJU5k0yeW5o/Y9YS1NpZFzObRACO/
# DATA McV2ggOacZ2VuSnBmeyjowwcAV/GFbCajKqonNzPUh2qeVCxxfHZUCwH+OiYgKfioNhqSP48pUsZr6Wq0lbmmywScmT5RpN9Ne/D
# DATA CAA5uSCb9u4vYYakyfJw7C1nVEwLOcPOL84cRtBhBB1G8BoxgjsPQztNki5qUN/oHOEyU4SrnCE4qqCjCjqqoKMKOqqgowo6qqCj
# DATA CjqqoKMKOqqgowo6qqCjCjqqoKMKOqqgowo6qqCjCjqqoKMKOqqgowo6qqCjCjqqoKMKPjdUwagTDUf+JamCfjeImuELRBUsr0Dv
# DATA xBQswvN6TQue16kbeF6nmK/DQdQcjtbQ99qBTd9r5vS9dm9j3uYFM/XrXS/wO57vN71ux+u1qn4r8PymT+VFV4OO1+2WsHyddq/b
# DATA 767D8hWizPswV+NLL7SQh37HxLdVBEzWo/ags+b5IAjy5xv1HJnY3e35hrxS5VcryPNrt+ebLSv+DSu/d3x/q2shH5uNzkXf77ft
# DATA 8vbz+Dd2jL9dX6Rs+fHmbo+3O3bybdjjjtkvj6jkt3sXfX8x9+o7vP4ikEhpJBoSKX2ZBYkcdMJhxy9CIs0jBhIZ1Bv9Vq8AiQz6
# DATA zU67lUMiB/VhfTgykMjmoN3tNnNI5Mgftruja4dEztCfV7MHJ/k6hxyhPIquYN0hsFwd2uZi+8G8VluEBdNHXkazGUzr1+xhURlu
# DATA B1ODdlHRvrdCse/UVs5uxMpCRPWih+IiSgnqe1SWPNo112pti2ro2dmibvP0rpZi3uhZK/bJFxytJaDjlh0Kaj+CpKOa0Q/TaB+i
# DATA l5spjSYfKqXkbjH9yoVc2Vpe7EwxRSb24Eo1EfMp2CWnOARHgXQUSEeBdBRIR4F0FEhHgXQUSEeBdBRIR4F0FMhXjAK5CnGchod3
# DATA YOpRr44zZpTk2/JVn2RBJijk4ge2ogBa1ev0NNWFd7Ehcs+/9fpnr/2ff6wx8fDeWp0BfmZPwg/nctgAb6RgbplwAoTzv7+UcN5C
# DATA i+fjS9NwthyFrNMvp7rkPCI157kcfcOhqlCQC9FDupEPf5I5kNHQViAkFs7ouNP37vT9Oafv1xzhcmfx3Vn8pzmLv1GP81rP6Isi
# DATA YsIHkfPj3jKsfN/ocz57+Zib0OqU0Q4yqiYKIz4gq6zOven0lqIk6hY6YwdILuingzDdmrlgFC07raKS5DSeybpXXalO8iqQ0pvE
# DATA fhv+dTNP0QzKdlW5aLytQEzU7Wsm9kFrXeQDK+rdQsTrtdbmqJvx3o66vqjq0d4wOkwjmqqfkwIrLJMC+5pJQXtt9jfs3PeDLZm/
# DATA UaFTtxLUaOkgXlR1TmvEZR4i3ZlKa9ZH3AtmH+ZNi/VNhl4V48h6/yRv5PYNLLIv8vlS3FG2kK5EnhQ8o6kSeRh8c/9EUI6Ffknr
# DATA DrB+hQ6N+hEyApWBiPneXMyGYYy5Hz8GDWGW1DgOT2TgkeLksT/TwhqHy5BGnEUUsTS4Erb4nDo4Mr9wtF6JgqyJ0Q4Cni/fgfXS
# DATA qOgsa2dZn2NZl4wmZ1U7q7pgVW9mKz1PylfFVhCa/DLiVz8Gf8+oHWEVO9c6Yj0ZuMQrRr9J0MXRNM7mLEHjfWLoKmy8s25OBM/c
# DATA ccRk1oqn92xgVIrmWMZP6RHUn7JFXSQ4rohdmfto6H83VtJH4ySNf5EYyRul4B96WTgCXydKyShiCSZTKtk8yRXSWaKIRaPULCIK
# DATA sxMeecfJNIIoD88myO6rCCdDpHhwL43WNLDGMCG4s8oot7CKoNTAsVVhw5ShYNsMIx339yHMU+wAsXVCqfaAB5l3iMYmWs5CNmyo
# DATA XtW8N+NZgjpEz2jMrjYEZtHDBRuSvKSCDFL9aJLBbaV6WGUCSRWY8sssUOg6Y2Jt2v7aBiNMkkOdwo9xolnKTapVYc4WY0EW6h9x
# DATA LlZkuAsi4TU5UWr53ONnD6Sm5eOG3hQp8q8Z67+OINXOidCKpAw9ZVyYx2fBgNtG9i6ybYn6SOS8pFVEJ0oyCyP1fMpdmKRRVMFE
# DATA fraflwc7AHPjNFwYwbB8PKK8oApLaZQJp9JToizDLtcJ9pdwVcYRmtSu0CcZfOMcm4cUwIKMw3gIGmzNezvhJonhzyiTQQROGYwj
# DATA dH6pFZsVAhJbVufqvpq49ENV2EtLQd+spxgmqbkig8SJXNAi+2pyVnyefyxOvfTiVGFaVecpkOrP8r6MiQVSc3OovZLZf6r3+YY8
# DATA MQlPFDq8aKpk1BNe7TsDHkIZ1zOMp9L/XO0bsE3x7od67ECa5tFsEE+u9i28h/sd3YL0Eprdg17t+1oCsBhFZs8QNTy2JWfU2orv
# DATA ur2cXBuD9uWbXzkSrZta7S4Z7CZSL/1E6qLo2edLQtjs6b0Ohmk5s6+cYLpG6fh8fumkQFAQDWB2QxZ1hbfgdZ8vHeUXUUJ0R9yC
# DATA V9hYro3wXG5V8sVMNmork+N82lvxDqHQnM9pMAvzQkyAsdXKzEMHNAW29WNFtRWTpmxRmpXm3oSSJ0Hb3yKgW6i1ZL0cRecLSaNO
# DATA TsO5BjnsVAZrSvSjNGKPekENO4uyTLMKXyHTLSdc9cMHUVrAW/33069AnTr74vQbxaD6I2Ouvjz7j4yr+mfv7G+BmTr9/Src6r+A
# DATA VsVAKnCsvjj7e+/0D2e/Pf3L6Vdnv6FAn1S80/9Ft/yZvv8K373Tb01ooGZtBl79Clwr+q9jWr0IJFuqw3gezgaqYCyBHTLuWYYI
# DATA srZiHgmGcE1Arlx1TpiTiUtjxk4L7pdGCswzlEsJ+jjZXyuMPOo5MvZ0bUVYvYkNtGgnEToLB7CyDVDpBG6aXlUuketjV0ESelh6
# DATA 71pkFVcxc+PbXOGuB1ZFo95cbfpFLcUm4WQYnvA+QqofDyIHrDqv3K6cU/UmmgGXwDxKcVaUFetxHG/EgG05femR7Q4tE7UKYm3B
# DATA 0+v9EMs/TKNhHMEbDUYB9alRCm9Xvpyi+sV4RubQUnLYmy4z6c/EDDsRqvcgnkcrFKtdaupme6bU9J4VvWqXRDhulbMCLm0FaEzV
# DATA JQb/V8LzdEMD/5WP+zsN+7uO+jc16EtlLKbeDPLPqrFcB32qmERvHE3msE7I8ACC2UQuT3A6PlmMp1iRlaTvy1ALoXeccFnwB6Cl
# DATA kS2yOkodJmhG75GBHx7ROJnp7EhF2oy3HmBNNl2yliLFfxobLtB29pTaHQEPU4Ql6ojPdMlAzLHfMJiLi8MyCBhPxGNBJiZEFe1/
# DATA WDAveB+g3kShUED8EhZQAGqK/sGeCth5eo18uUggDzVgUpcDTDnAlANMXR9g6rxxZKe5zO6m7g1a7Zcx2q/GZnckKUeSciQpR5Jy
# DATA JClHknIkKUeSciQpR5JyJClHknIkKUeSciQpR5JyJClHknIkKUeSciQpR5JyJClHknIkKUeSciQpR5J6bkhS7UazHXQuSZIajUat
# DATA 4eAFIkkVV5534kjZmRK0vUan+3m1WfW7Xc9vNatBPaC/vufTP82eR1+LOTSIuv1Ga5UH1et4AahPDc+vd6dVP6B/muprCQRFmVwf
# DATA 9NeBoPyeBEzpj2ng1uijhoVearTaVtErDpJAiYrgqqgZRq1oJaLNju8FXUp2y/MbwbTRrfrNlvq2Es+o3x+tjWdjtX7VW16z1Rq3
# DATA 6/4HfjPwml1/3NJ6cRYDq9UMonVBrtbYdpNi2vB/0mtO617QqtI/fnca0GuoWLr4XA269GX1h9JLu912IxhseelFUEfSQjTqSBqb
# DATA hTrq1zt+MCyijkb8Pxt1RF/DUb2AOhr5w1Hfz1FHnT5lVWhQR8Nw0Oq1ctRRt9mq+61rRx3xDpMqmx42S0hFtjj79DESevJfaub2
# DATA ZMBmGsnMYBvkh0eu/M070IcKTri2ccLJ0tsqoMgKe9UhzyOsbJujh6IHu8KJtKURlAPwLjBeb3ls++C9EUJklaDtC/TEhN6cnlLh
# DATA dlCqHVW0xfzZnBxHEnIkIUcSciQhRxJyJCFHEnIkIUcSciQhRxJyJKFXniQ0UhwhPnpFCa4c3xl9Ty6NT4ayegjYDxk3lcz8lIVs
# DATA UfLVE3P1JKIeWV3W9KF3ES4ThEavUw4dMh/oU4qhXDwugojU7/cpeP45W/vzezOIIsFYoPfxfSdr7/skWYQTOd/Hd30QLsY19hvs
# DATA jV4/fj17/UTdbHOG8pMs7qi0OypdPCptnWtyB6bdgenNUn7PwUFqnEkd5dU8PPFC/F6QN1+w8onUZ5SAkQhHvangZ8jmTSbJ8faz
# DATA vtP4IR8/nqdJMtLnj6Ezbhoqjb/YirJMo+wptM1pRExPkJQFZQnSp49b3vOy5RydajRULTrODPmILBsFNkppwEPthJzeJF5gESeh
# DATA yUPGStgCMhmky2n/ANow8YzPY2fmUPUIzt4jPr/7KVy4BQWTlDXdRUE7GyQJPzFYziGzLeeatylovwUbIj2RfXQeD1F50kYQWYcK
# DATA IILkUp1F0TDT3ZmkN1ukYi5TOY6TyZDPuiLmlFiaA7McOEplhN8OKcqTExYKN9lmyk6UdVgmHafStSo6pwETuUmyQNLpUj85nnjh
# DATA JEv4YPBWifB3qXpz05Fj2/TWKLUKjwWb+2xtcnbpm+NMn6I/Rl1E98ziPhOc70U/XvNYUT3vyQfYkBJBHj2e8MlcnI3Pat5brNbM
# DATA ddfTgBpUB4o8QkVqwyE2AnFY5hiiUvUPF+eJunPOcZyPaSAxuoLYjorz7x6O0uBl1HTCKb+OBjouHSUJP1gupHCxrWauTgOLTrw5
# DATA 740rk1hRuFAtfgGZeobjZEbR/IGEJ/4VDpFMw4mdJbE5zx2m08vpmr8pQtTIOmr8FxY2RyO8amXzj5H5KLwRnNPSO12DoHnOthTB
# DATA IxQFG6JerkdwDZrmRpmRjZqZanvoZjHmXYPE+T3u9o2tpNQkbk4J/OU5yJ0H4mYUbkZRnFGUq5SbVrhpxc7Th43Tj+ubVtxHVuQ4
# DATA HImOnlI899qAN4EoFUcaXWbPl7d3eB4WUz9gOixzIadz1C8DJK1vxnrmrj265Yf6i7f33fMiaz9oIly4mFM8u+vi3GxZUe7tSlBl
# DATA fyMTSiaLHWKpbs8Rr+p7waRaiZqdmY0iIXVL1MTpST8XvJI7RFI/aGJpLuR2ba1zXkSDbRHdCEKV+StGK6ulvbg0VGlqcVYUOzKa
# DATA pe9S30Ktwzs0c/GK1+5+1zP11puSSZ15jaa65xj+aZrl00Q6OkzRUfJTGpmF6bdws/hG7o74q9Jhk5mpgZzGrFYbD0xXhzdGD2XN
# DATA RE8ZsAyGST3CKkmZsTyX1ZdpAdtMWGXytKxCYNKfT0skdur0QaRV0HagnL48trej7zjbe7s33xnaL6WhfVHKzjMWQuUdwPkG2VUD
# DATA 1IbQsOhgqD3YRi9UkrCZQvNM5VNfCFlB/u8VM41KQq9XTTRakcpdyzPaQbzW2kedS9jiWwThyiQcVQxBh62sZTZWBlapnmKnuJSs
# DATA 2i3+xrhx9900xroNdimyF5EugVEfP4QNw95/Oc/FtMO4aO7QBBKzwGjdsotS1RQhU9EnVQcZeAuXMnmKBgxNSy2PqrFaTHTteN/H
# DATA mhViTvZdKeYiu2sWVSh2vH5h2oRojOplGcUgxXEybM+2VotYPpWXnnAWcUuE0ex3jC0fa5slTP/l+N7HSpBaoNPT56gojhoWF/Z4
# DATA yWRiVv0ojgo+iRUILIJtjii9bF2+vjLanRY5iAy3ATg8FjvoH06/Ov3T6bdnvzx9AujP6R/PfstQH9CDfskMny/oN9CFfrcKD1p5
# DATA +PSbs98CN/TL07+cfXH65ekf6MffMIPo64pHn746/bpKTzxB0B7f8y3dQ+8QtNBGmBCFjrd8SW+gGx1Q6Pm3qH8M/TJeJ+beRNHC
# DATA TiqyIIhL0tGq3alpdAj+spZzloV/VV/N4J6yaHOBMk298VaG0FvjUFQNLMlwxxGyrGvVJdw0SWhduVwfTYg3BIyTubnxU3VhPVNo
# DATA FOfd9LvxwniCr5gmJFBjthfEV2QRfV51jtAuJXblNKF7noDXAQKvLpb9yJS8ePBj7KGderITvOZ9kFANmBkQIhXiEfTeIemBNQLW
# DATA 8IBZFqrNLiE+T2TTRwr34ZR5jOKsY+NLYI0QiS3Dg7ZXyc1GzJp29qzQQduT4KBBbqS/yEivOUGXHOBfDdfZTQ3u1zK27zS0X2xk
# DATA v/6BXarlag7kG11vrrVcBygoTxlEtCiAbDXOC3jcsFlTb/7T8V2atPMhJ8aJ6AIEASbm35lvgiUwpq2oLaH8lmk4o9RlJt2SWhO8
# DATA YIamc+rCZoudsEGwrxY4yI98oJBGKfV2+aAfy3K/XthCMCwmxxAjQwBKI8kqg0Q+EaByxRrpE2B+kpGgi/Eiqoje/QWSHbPHIx55
# DATA 1KoeCA3lmDoK7BlEG+QNBinyTjtEHT3I0YMcPega6UG7jSk7Qs3Pt3lv2Hi/jO3+tKa7Ywc5dpBjBzl2kGMHOXaQYwc5dpBjBzl2
# DATA kGMHOXaQYwc5dpBjBzl2kGMHOXaQYwc5dpBjBzl2kGMHOXaQYwc5dpBjBzl20HPDDorqo/oouCQ7yO82Bq36C8QOWl133okfdGiS
# DATA zLsIi6yZYSsajuqbWDN33xjEKex/AfsEkhAF9umwSAPLG/i+IgwVbm/Xm+fcbnF+KGyP7vHot6rfo791+rfX+iFdn/i9Ol1re4Hf
# DATA pGvtaqdXDZrBuNn7IACwqNMdd5pTv9GqNlvj9rqYNINNEVcAo9uHhQrUDHxEht4wrfpe/UgQPVuyMRr1e+31iKT6SvWkOLeC+rjd
# DATA rH+AVDd7raNmfdqsN6vNOn0qI4h6YaffXhd0cHEakNR5TQOS5mPRgCgZg06jSAPyO41us2fTgIJ6s9saFmhAQbfVaIc5Dag/GjaH
# DATA Q0MDajU6/W6U04BGo8GoO7huGpAyStY7PnRaS7aWGomwca263Qrx6GYMO/m9ZfCPmSitmxRpNxrmupVmrcn8n4D5P6vrUe1ipLRx
# DATA Y3XTYrtwQijHw7R6iKkxeBb1YXRYsdbe7c9e0Js/rHynUW912n12+92qbA6pd8GgdJSzeTS4KJVI27zwHq6YVNaK3ObFcbUULj7h
# DATA akY/TKP9YZg+2MweynO4Ykd9s81RMnulDrHt5EhCjiTkSEKOJORIQo4k5EhCjiTkSEKOJORIQo4k9MqShBTp5xPrWFd+nrt4jquM
# DATA 4RFukJzypjzSdCHsCEAzAp1nMK0xzOetZMoC6CuHvPl4G5aSRK0qxEGVZKaOr2lB2uJBMWmjMpHTJy3cGWd3xrlw1MYddXZHnS95
# DATA 1Hmj+OD1HIF+N2atCz5Lyy7I8ulZfRT6eZPbuAk9bjW4oOpQfVWS4Ujl3mB6nkSzedZ0WPkVI9LcXavN3bJFmn2/XpRpbm2RuubB
# DATA D5IuqvfiC2+ILWtUlOWeXOBaP/RGwp2pLSHd5uWej6nvU3ghridv3E6USOCaJ9qcXTS2eLe9RRo9YK3Icx9r8YtsM2AKg4blk4vP
# DATA 3pbU7CBU/Y6un6iyHqrsi6tS/UEUZkuIRuNg7SBMc4Hq+wuR5KOeJEkWcoMca4asT3gIsWf4o45pzKp5P+bBbRIdUaVBB4hOdarC
# DATA 5mas4DRJaoSH0oTMyZr3MS8AiGkkD7DeohL2o+HkBAVNBREvCvLVgGkVju3LOVIvXeKMN45chzhgDw1HM55DP5AsNqqzXPgZzc6W
# DATA 2TwS/UNWzA5nyxEG4hRzKQkQXKRhPBrhyrLPeuoxxmkKjLE762w9JUJASVjsLHD9spzzdfLWzny1zFdnr74S9upFta2fsWQPr2vn
# DATA C7Dbta3v0WjERiMbkGzHZrkUBXMUsi0a1zct9vNC6F1ch6z1ar2+cmnrtZpOl5W3zhf9tTkmFoWyfSKQRbnO5aLWbP6ckEkjQE1e
# DATA CqLX1bw3RTeIZkkiVhOFM5gon0JESOReMgxujBkVgiNXN5hRZHXFWviZbLiEbB4y6h7QGzQx5GIV50daiMWoOhl3+KuleFLIGWcM
# DATA OWOo1Kc6b57z5hX7zo1W1DMWNGQeMMDFyWQiOvtlYLdqJ2GWS/jVvHeF081W0jp5voKW3zxNBtEQNG6RokvSz5eR+HKehs99LzZQ
# DATA Z0PjXdAIqpmA03ghqGkZST3WcuEYLLmRH4bLQxo1P6ZhWNMCKxyAmCWy3KPwDugwwtEITjF2leQuTzNOvzfDeL8Qfu1S0SKiaT8a
# DATA QgRtGPVTGpGFisxDKIsAYofSVpS1jP65PKPggEOqCvCDsqagMg0ybV1AOQ7+mlScpUp8mmyA4STqh2nNex/2E6JJlZQyN1QgsGGI
# DATA DgZIhP5EhNfGLIy3TsiQP2aWaqG4ZDNQrz+ngo9H0HmbRlj7iwdbYeRjVrXmyjNbwIPDXmST5E8B5UhGI++QhiydRNkn6U2WlKmD
# DATA EIqNXI+BVw+PwxNxTOl4qjLMtFuHs4/HAQpGxZzyJRMFbviXWIX7QMkaQgoz5ZMFquKa6lwAayxQf5g34vUpAtFGr7NKNY80MrZA
# DATA Jpz54LlQNQSnTMsiMyahxMcgk7D8UzyhnyvaD8UJyGE7gzBNT1i58R7lWch+OxWQEOYFHqc5PkchS/LlmfRhFHOqxE+s1C/hkjtM
# DATA kqHlbpe3JtTQaDQcSVsrFuHlYN9oyyes+kh9zPcvDPtG3K4a9i12eSwNXOkXxjOA46PhNUC/3wTzXsmFqq0j18D4/rSkQnotb2K4
# DATA 9/toGtLH0Lgm23IyIeZc7dv4FNCnhpKIFaJ5GKfeA3iLw9XUXSdR/OWY6lhwmSRMh4fwrdt4mf+qMDLfMtQFdJivvNMnp/909sXZ
# DATA b1d5Mv+d7vvj6e8F+cJ3MfkFVJhvT/9MH79klsyTimf4Mk9O/3T6JXA1T/BTVT/1xKOvX+qg6DZ64a/Ofq3gMhSPs7/1mDHze7Bp
# DATA QKFxUJkXANM408yuFV/cPEqAgFYj90IEpt/S8zXxexzytm0Mcgoaxtq9LC+ck7vMwEfR00PhcjbcSpm5x7fkb3aMmcJszvQMN02Z
# DATA WS2X62PMcALNXT+AkDjl9WRUvm8I7WcD9MJ+30UanlwlWobaQEY2dioC5jTTgDXGMzEUhIPLbC+qK6fKmE5oGJMZzyf2xNQh8xVP
# DATA QeQ+fuhxvfA+5u0B4rY9xP7IdZvKhX0IjXat9I0ym0UL1jTH3g8aw7MVhsy2mrfZTllpQ8+KH7Mt+o4e44b0pxrSNU7mUiP5q+GT
# DATA vblR/BoG8Z3G8B2H8OsewaUulpOdb5t8hi3mOpAy5YTmZBmjOZHHnHIzChViBu43lhuAp2tGRZrJai2SYfgZMqwCPXEUp4yLQWFp
# DATA rAylPMxwEUfGDVEYq6EysF4AInMCa4t9uxLioWwzwzSBPvYn4nE7TCM+DyDZrre6Kd86jf6QQuDv5/JIDjD+c5akls1QxIxEqYPF
# DATA OFiMg8VcIyzmnDFjNyT8uZbtjZrnl+JUP5Vx7vgwjg/j+DCOD+P4MI4P4/gwjg/j+DCOD+P4MI4P4/gwjg/j+DCOD+P4MI4P4/gw
# DATA jg/j+DCOD+P4MI4P4/gwjg/j+DCOD/Pc8GHanWa/Wb8kH2Y0GgXD0QvEhymvOe9Eh7GzpVH3/FZn3Og0joJe84f0vZgj/U6n0xyu
# DATA Zmcr8PxunTK0cxQ02z+k78XnqG52+4rLwmUpZSUFdyIclqCgK9HsFcu42SxFpB/1OuUAg6Bx2QCH9V7Qaa8E2A2uNoaNpn+1MWxK
# DATA 1bm6GNqFQmV5BXloFcoFA9xQylahXEkM7UK5khjahXIlMbQLpSGBX11LuWCA57eUK4mhXShXEkO7UK4khoVCaTWvtqVcMMDzW8qV
# DATA xLBQKFcRw0KhXEUMW4HVlnvFUvYbpRDVhVTlfnnwb0eNEoqr3WuGzbWwtHXQsVarYUHHJPzUIMEsI0WHusJPC1pPF0Cr27MCaPUu
# DATA HkAhCb32UyZhtwAuwjMTG03zzMTcs3hmYbPdbERFntmI/2fzzOhrLxoVeGZRdxj2hznPrNNvt1ttwzMbtgd+2M15Zt1BMwyunWem
# DATA vB5qQ4OZCYkznmxJdlBY3gu9SG3mZ11eqVyz6F8Mucwx+0FERmwcViQmpb0oa4KzHZG8yFMMXa37nh8NM31Zv0tO306T48Not6Wi
# DATA 1i6L01ao5VVn22ei60jR7RzIRH5l9dBvWIvE6l4/KHphdHXlPZbjcJgc80IMVtzqnq5zVt722GHBs2Izm9uwn05PYlVu1zcz0Ow8
# DATA PcejYeVWqU7yZDlwIDQHQnMgNAdCcyA0B0JzIDQHQnMgNAdCcyA0B0J7tUFoj1Ttjqng7iiUGT5ToiucJHURR/eQEXK7qG7eoY6N
# DATA 6sweqlZ8p34Qv8FPHMSvv37rES7ybQfxaO84npF1RXbYyXyRfB9G/MeAYkx/wuHceqRb0PwOg9YYBLLXDHrNXrsT9Nq3OUq3vsd/
# DATA VBT6d2AD/phm741AOl7/1sEweSTvKL9ir3/r4DHLZu71f1r/2d079K5bByL5hgvf5aBf9w8eR2SsKy04Ky7Cf+MA91Q8btHdSn10
# DATA vqRRT3V7jyV6qBx31M8/T+LZHvdWlIPgw6ExvK5+lAXavb2w0qfiCF/vV8h6zC15ldpJfGejNTuJUTCT2K6Qd6R5ULnRmyRtNHPE
# DATA a9nGlxkBDpCj3c+xlWA23JvEtw4kj4q/86o0TdxVV3zXr98q3oAhWMXnLdxbk9PTVNkea2SdOfrplFWcssqqsoo5DOzUVZy6ygXV
# DATA VTaKYl+D6srHkOPSCiCThPU+WLPLCK88WyGvm6DTsSlAV8UT5CUjTsw5WDr1UN4jqe8FNdkVIp1vAenaNo7O3wKjY/MFVR8fMP9A
# DATA UZRgdOqeHEanH1phxLUlqIdiIm1myfGY9A686+fd6YsaMFmg593ICrufHEcT6kTPuTeoq3tnZAKX7t0dXcfVG62cS/SFpdb9tWY0
# DATA yHiUkfUQDY3UnpHXISPLyOKI+V6W2mGS3G6yPSxi42XJMgXLdyQ4Fehvi9UIDYecTydeCzISZ0rGh5J44qlD90Ysht65ohYzbty1
# DATA 9X8oTQ0qmIkuFLbI7Ny0NuqqEpjsRJt7GRRD8rHEGZ3O6Fw1OnPrwlmdzurMzrUnn5nW331GDXEk2cUN5CiqvzE6DZBsGg/SxJLA
# DATA W7KFqvTvQmpdswHoFqvad2ZQzFuUGgw1pISl5AbJdBqlg1iPgWy5phFWWrBxYWftP07Z/O598Vb1T+Azi7DLBMOoASgJ+5cGU+yl
# DATA WKO/pc67rZqoyj2LmsiflHGqbA79Y24AmSt88BnotIjDUfGT5QYRHNSRX2t7Gp8vOEHqc9HytO4wHaX91IphB6cp2gJYU3JfvM0O
# DATA 1Mb522zAbbprkIC4Qc3liG9+K/+6+RmuRLj7I3zYYl3KwKwtPHGh2iYJBokt5l2hhLHnQxq0OtqZIx2oUzLsDvZYy+qOyks7L0o4
# DATA IN4NY9q5OIO5NqVLvj34ly/+77ZJRTnaKmeVKaakKqmCpIsTMcbIvuORCUwebUnyIETTvirsriHPF717wyGk8ehpYQEN0Nio9vNE
# DATA kfnJYK/gQTb/ZHRkIoomJsM2pbfUvDfDWU4FnA1lUio/vQsiDF7SqNMgayhB+tjJpfK1VHsukb3NzdlbqIuSy7CXxYanhCzCic7n
# DATA e8yToUFiXpFc0xNrzrUQmwAW8TSyoWzzyZJnzzS/XIpFzwQk5dH37sVT5NWIrLVsDFgVm9645Af4Ok8yNtFr3juAL+I1wzgbLDMU
# DATA EIcki5JXkcumvV00fzfnrWq5OlfR41PXu8AHnadvY29P6DX+zz82wEoaUp5g8WAGnvkx8EFUt5aUd1QWMsXPPJ8KtAenhay/DCKa
# DATA g9S8j6jLpqn3PanYUn1BgGJOEp9X9ODeOPDetO/AGUJxl/BMWm3yqnk/pK8RV2Qq/yuryJfO4u09RCGbP6WBliYZFESq89iYsyNq
# DATA +FXRc8pZYNAOpPqFyjSXPJQVn0z6ArkblRR+mlChxzEhlAc/hHYpTgZmrFsamkDCmYZSVeRl9BuWUCRunOmHsUiegkd2FCfUQtTD
# DATA ofQ8z0fn0b5Q5/HvljGvfOrBWxeCZDDVXxrjULG5ArINpA0jmQ4h271sEs8pP7lxcN8C0BlPb/qsb6o9glBQxaguSqzcNXmH0UKK
# DATA jrMQC4lZMo1w4XAZcceBp+OZTFSoX1pcSfdx/YPfWzwugYkUm6ptukVxayyOE+mQJWvRG2eC0BSh5ChOaXQ7Rii6HrOMbWwUfmm6
# DATA jqafqpZPtiCrOuOd1DXhtCL11kdqckdh44lpgoVcnjugp2DshHQvsFnLmVs0V2TZ2DZXzBXJrLvUwNQCrxYSlvFbTEXLfKXmNuaG
# DATA J4VSO4/19DK4XPLZlnO5OJfLGoKC87K8/F6WjQ6U54qoUDgqsDpSTmzWgjeJFzjizEoojMQExVKNJuyCyR/k8yScsc8awfA8a5Wf
# DATA x0+yDn7IqiQffbn7BnWk5famj74Xjtd15SyfdS5fLoQT6Q7LOImVI+nSfgcJaoe87WQ20FFRKo+5380Ws+fyWAPmsJ7jL5wetRIz
# DATA Du7eZ5vcVBFAkMPZiVm1+mFyDBzyiao73/f4whLeKbKqvu+9RfdH1JnCGIIRklvC38ckLJ5yhZtlxzJ7WGCjncdLx6y/Hyuiq2ZT
# DATA AUYbkm0GPi60y8jw6icPoxVeVLG2vBszMJMdkJQdy8GCEinF/iosOdmcy4R53Dbl8r8wlvJ/Ajl59jsPRMrTP5x+ffrlKuGydOdf
# DATA cuAl7q94Z7+ka0/ov9+efu2d/ebsV6df4Qnc+wS3/0kQmHT7t6d/OPtPgFd69OELuu3PcqvjWL4AJpuXsd8/VQcQTV+PRPPknHuC
# DATA mie75b1sKRNW2ZDP3Fp5kBswxgweTNgjMJNp1AgTVm5w8JNhaWHMm+e3UCzfFBkwQWU4hGXRhJNGf9MAy1KRXB+9EnbAkdXdq4rH
# DATA FHT5qfyEqoLmiY9VlUQVnMEjdqVAS94tMQ4z9tcA/aMc5cqCcVDLXUvwyvGW92CXHoqtYtjRFe42h3CwaUCQ6bPE0H47Ho3iATbk
# DATA Y9uy7LiJNANc3zqLKAz6ORV3/wrRcqc6uNksKbauZ8W13CkRDnDpxvqnGOs13vLiQ/wr4qG5oeH9qkf3nQb3C4/tNza0S7UsZEOO
# DATA uXxm7eY6IJeFNGJKHhYThm2lkgAEO50vZCicp+h6wKkbh/2YF/4WmS41euLwEAssD6gaZDKPp3qslrkx3ZaR2YzAk5gqJJa/hPCX
# DATA QfEv3RVxiWw0TEBMGyj+E+rqcYYNayAK7ahjz9teV7CSqiZVC8aCLAhxLFkiBaEgD5EBWPnMqvMorbJVRyWwnHIve2CZCbgRUa6S
# DATA wbbRbHAMTMfAdAzMa2Fg7jzA7DSTuYA9fHOm/WUs+ysy7B0c08ExHRzTwTEdHNPBMR0c08ExHRzTwTEdHNPBMR0c08ExHRzTwTEd
# DATA HNPBMR0c08ExHRzTwTEdHNPBMR0c08ExHRzTwTGfGzhm0G5EzNy6JByzF/VeIDhmYeV5JzKmhXrzWzllsVGkinVKGd6Q3yXHi8iy
# DATA Zrdd76zJcGA328G42ZxWm03P744FdWaBx8o0shw81liBvtWtuJaQaitxrbc3xbXfb3db4Upcg4Di2m1fVVx7Vlw73a1xVTC7tXFt
# DATA 9rv8azGuDb/uBVR/ryauje6V1IHOoNsO/ZW4NutXWQeanSupA8NOOGyv1tdm7yrrQKt9JXWg0+72O/2VuLa6T18HrOAotGa7M243
# DATA 6kd++4fdEh6XOtRB63IQO+pLNcROumULYtdsU7fR3QFiNxy1ihC7ZtQc1nOIXavTbnVaBmI36A6i/iCH2DV6rW4nuHaIHfZQVWV1
# DATA Q4+uTYtfZ9Hqumxz5vdfjEtXdro28qXWtjhdOWQ+p7KbL7W9zZeq54R5oKurMsrXrKcZmCioKVevtUKHg08NC07ynwb/brhw8Yzq
# DATA lNcVMpxUhmaRTqdqzTrK3uWIcbJioBZx1xaBce2V/QUbYXNWCWyxTVdrjOPLOb6c48s5vpzjyzm+nOPLOb6c48s5vpzjyzm+nOPL
# DATA Gb4cqzcqlBz7PCnR35OvfHiPvt7Wvwpojo3Nz157Rx3/G5qTkDisxyQzZrINoniyx6EzWU30M7PaZ/S/2b0FbpNg1Q8KwKa+MRxG
# DATA hzukCbfHJ3jWBH67HAoHYz2a8YhgcGdOB9EdtN980N4dsH+JD9hfVP3wuTl4nzu2tqshssgbn2ad0QhFlgUElsf0fZsW4rM9p/+C
# DATA nVg9T30nd1RehzZiSYXgioURyzoO56gi3lOAHhZDoFylNpRxYEZa6KMlvDG8g8E7XAIK1o+YDRZaqt/QPaDJOsZp7126mkDkXqsf
# DATA ikwUIxqUugLV20QLOMuJcq7qSrwB2c9nynEOvS8VAk+jzkUP5zKtUCrTZdXDrUpKpSYH77UNv2DV7fsJjXRjdVpdNr9q8e0PQ8gt
# DATA Gpn+NDoOUxyoV4Kix+FEjuaHqoJ6EySEOQnsQI/DVIQpJPLF89CLkEVSf7RcIEnmEHRZo3w1jjqXDbVhJiXBFBvuILAJw8OXYRQa
# DATA KfUwY5UGJawVMp6GT6vHiy3Rew/UmwtEDr2IiZglpKErEgQwMyr8MFUAg2SSKR6joelwMOkD7xi9EMcXp+23RPIjec2aTHyFTqzb
# DATA oTgb2dnIZRu5VKucLJWTpbqMdbzRGr82uaofxNwG2EgIldCTVrChHHtgaVfdsCbiTcCBxbnDEBxYj2mEnINK5XY8sH7M9E7mQk64
# DATA bdbPQwQ36mLI7kAJFq8TkL3GwcSX2CWEl58TYf28ibC5kEe4tT7CEkcVZb8c5frmOLNrzK66qFp7/OLb4pm6dW42FynM+nse52Bt
# DATA nFuXjbJ2mNENH6z3uZ0T4zwAE2nrkpXXa6NtxVpVHx3pViHOG4HIby7jydAa0dBbvLhc5A9kGJbRPZzz0RtewNZzKQNO5t6LT4ko
# DATA dShJ/pgeisDjuueNomN2abPjeGE8qtDBWiMkf5iyUJ0Z/2fRkWZeGQmwH6t+XXeFAK6FwKJj/ywb5DXv35OlMOR5D/WMVjdLZv8Q
# DATA O4NEdU0zMsWVLR0pNxZKkbyZTQ9M6WiaIRy4eLFpyvYSG+H26OqMcGeErziqV6wtZ4c7O3ybWf38yMaqwU43A/aBoS3YKvDA7dBY
# DATA ZVrhUT7UKYnSSq5iykONETiFXif2VmHUQeBzkezE8KqciGhzIwGiZMtYMDNyGGST5uql6cn5S7lhQwK/j0qhZxE0Og8dP3kXfvKM
# DATA fah4Qrypm+8Ud7JMIfBpCzlZuxUt5x8ots8/QTnPjQtiJD/ZjJDU+SoQyXsFzz1c2lRlAKVNIxRTCZiaRoeUY8Y/y35YQWLRf0aY
# DATA Oyv1WaqRGd9It80WMU2YZQWC58o1760wTU8gyprMiu7xNGRmI1uti/REeYlZlBV7IFOJGHzmyUz7ydXkwW6k+eqPbiL56pLZAymj
# DATA /Jbkm/zVKop0gTf7csMMwTg1M5GnYoXmVfmCxfzO5mLWjUIVs3H650systeCewxd0O+ji4WREwqTNSWLXa9yZBayXrQARCmal14k
# DATA 8GySHE9ORBI6ZWVjdK4Yi8xSD5U5b+BDBzk2veJTFeH2pN1YIRZ6mQuW48dbYMZ5f6VbrKBHlERyGoHFSkPObKjEwLkkNQksb6fD
# DATA OKRZ4JQN1FG0OKHxdIk8jpXzKtQtWeHGzGSeF11odM35aJlZwqHB9yFmpOxzYw8YFghjAa49ddvcltAbK9dL98H3d+6DqcIu6Bah
# DATA 60bejNnb2YOTlf5Xs22kWGHViNA0GxnjaBpnc9a+9t7nHjNkL8EkTA8hKw1lxlmmOfXHSSr9q7QV6VxHIRDJcAtcSbtcn6rnv1v9
# DATA 4c7dqhq7yL6CvD6SGqqBahhqgrVpkrLuje4y0cai2KHwtvDpOIjjoCgV3zo+nMHVIxNRbWHCscLS4DA603nKevXU60oxczyuou3t
# DATA kLAXomt9+0Jdq5Z1h2EyTMNjNBDenTCJR9ZCtXKu6TuU9RCF2BZKmQPZe7F3bHsGMxouLG3yDJaLmscuP7OWrbYHDNJwjjznI6F6
# DATA P4X2kD1duW5N4aVK9GYB3k/loX35fYo5AnMQ0WgfD7IiAvOrsy9Ovzz98+mTs9/Q51+CZwls5Z/pzy/BsTz7Ql9ch8X89vRP9P+v
# DATA Tr8++zvGXZ79B4Zi/lmQmBz0H+jKb5if+TWTM72zX5/9LQCaZ79mOiaFffqns7+nIH5Nf39H76QQcNMv6Yc/0s90zz/RS56cfnP2
# DATA W4fJfCEcpdiWhu5KdYuq5nHQ2b74ongI69P0oMLfD7HZHV7UAZB1CtRyFLLnKjRTBONzDT144QbjmvfOw/kE5gt1pigsxFoZNLk6
# DATA 8FZ+5lsTGr+kJSJ+jqBp+1B1n3HTBM2VQrk+hiZXSnMXthbymrryAK4QN6lqx4m5/T5/9SDatZxAJOwqAZpxJlGB91B2NkY48xuC
# DATA H3QSLRw9c5eyuwZyJq+S8mp5PMVUF6GZCqC6p0XER9QGqMd8rN/7IAqzpVq+pRxbAgrFdAWUHPWVxvecMWfIW8STSLmsU/aXk4E0
# DATA XE5WcZq7VcnNlk65rT0rouZu6XBITWcXXIddoFmblzEHXonl1BszBa7eEtjJELiQHXBzZoDUy1Iu2LjN561NXQeHs5R8TjTc1Mwu
# DATA NJEpwze1QnGeOUdwYkwUj9M+SMO5xUvPRvkvB/DptyEzxJej8ZXZg2gxgN97VxxnPuJbFgNFLsuH/6nYCUPsy4NqFBRqKL6ehMgn
# DATA awr2AC98U9ySYVX58dHOs4z3kXm8h0tsEe1UpFEJyRV/lKJ18kYJdluFZhnNoTcdetOhN68FvbnTWLPTFOgiRvNNTgEuMwO4qgmA
# DATA Q2869KZDbzr0pkNvOvSmQ2869KZDbzr0pkNvOvSmQ2869KZDbzr0pkNvOvSmQ2869KZDbzr0pkNvOvSmQ2869KZDbzr05nOD3my0
# DATA msN2cFn0ZnvUGXVfIPRmafF5J/gmhR7TsOgNRGasx3k5OBG6YS/P2KApOlT8S9Au8gt7w1HUXc1lMAGDxtgPWp9Xu17L9wLf8+s9
# DATA /tNoVbtNj+zjaq9RbVU7vaoftL2gV+0Ent+hL41iYbS73VYvkncU4xw0gzzO9L48zu0gj7KQRa2K0Wq0o1WUZafn+a3OuNudVP06
# DATA Ra/zeY8i225UA/qh3a36frfaqbZaVb/ZK9UWPxpEfol52G+HozBYxzxsrktKU2I/UDHuWBDGppWUYh0fdgeD/hoio9/1GkH38267
# DATA 2qSUNHpendLU9fyg/nmVyqLRpBT6XgmtGEadZntt3FrdTh43CtjK5p5VM+pFWqTfHDTblyA1ctPTpEZpxRapkeIy6O1CaixcAakx
# DATA iLrR0CI1hu1hZ5iTGjvDYBhapEa/Neg2rp3UiL3t1W0mDQ24lo9LbGPzkLZkbCghUjnySzPiZve7Hv4lU8NjcyMPQo+31hKj/Mrm
# DATA 5I5e/8CK39q5BIcIQWHb51/H3TwH0abpgWWAF1yhqtwvBlYU91cOhSzlSYvyhP5tyL+F1apmy2AjO63vriU8irFIaZY5X75cai1g
# DATA rUc4bkQ1nlsZtD25vhZIpgR28e0cTqloeBZbmgw5DqTjQDoOpONAOg6k40A6DqTjQDoOpONAOg6k40A6DuQoROO+41eFpyibjgF/
# DATA JGtGIx/v6/Pux5HyZzLucU/hInEBT0hQqKrvYqPfns9IxsFU2I+FQNRc1QpFrpwfjIjIQjxZHaeXo/bePI4GkT6NiDNy8B/2UR5F
# DATA DmR+8sadDnenw3c+HV4+ouUOiruD4tt1t5+bA+T344fShCo0Ps1OsOQfyyFLG3xjjjxaoqloMhM51IlnH6yeesZRUO551dnpEUKR
# DATA k5lZOIkuKJ9tVC3F9chNnG5OpnCN2ue8nXL2LsrZvKOEqyI+bL4P/SVu+wn93aKZTYPiQvCHH8nHF0Ev2+TBBUUi39wsEqlyUwQi
# DATA 38QpzhGOdWNQyvUgsVnGI8udqgrOg+N0PrisNOU5gYDnJB7JCeZkwRSIjIcmuKAQjDeKqB5NYBDRhCWRg8ecEk1EeRrtzMtmyVs7
# DATA Zsk7WhOUxmSdIW+GE+gKsFYvR5caE18wZ65lCYdlRb0RvMv0NHKKF0h4XgfmHA3N+ENNkKy/WE7mI7DZVWSMbgcXzJefbM4XaVGq
# DATA piyHbJnkdWQWpjQn9WY0p/XQzzAYFNKtWJCAzEAO/4FFw1UqmgmhDIIEGXNE6PMc/f3RiTZunmEd+bc71pGPkiVrWPx8eZjnh1ab
# DATA nmv16WQ6wqYRYBqoE5hjeoUGwTQjhTEakqlBg9mAMm4yTpY48VbzPsGEgLUVWClB7LrDSfgLI9TxlOqzeVd4wfz5aIv2rO5UJYdo
# DATA fu3N9SXJoY/S5Ah1gNJMs5vDyKBjeZMcVZpwOYAKx72Zt5whubqHgUAwA1GBZZpAeR9S0by4/Azbzcc7thuu1Eq5xULWsiLDNFlC
# DATA fXwJpYqJGA8pn5GFvx9UrOFQ9yxQWo6lK2WzzBbiDaW6UH9dzo+blbJ9VRQacjPbTcLdJHznSbibcb/kM+6Nk+nnWrKN97GYHS1C
# DATA ZeVdLXffoAZdLmG9/xLJNdvqurKV0tocKhfCCX8ry5+t7IuUCjNIsHNIXnYyG+iYqJPGd3+0sq1ST/JX1eWsx/gLp6Ywvk8KZC/A
# DATA J5j1wopjQ6qeNIHX/oX8IT46zcPNc6pb9yLJOe0obOuZLVVSfQuGg9lAtcVQ+5d//AdtRvArx4FI2YkF6S2iyYSnLgo0IYpeP4D9
# DATA mXmHYmWFC6ZFDKHCRjOW8XLa18UVeun4ZDGeKmuWDVaeGxzG8rNYfixGhmkzRM0szS+P9zxCpEtJI1cot9IoF5wzaoB6BVowQzm6
# DATA 4jhMVzR1iwXKUCNjODKx6hWU1bKCcVabs9p2ttpW6ptbO3FrJ5ew2DYah9cpvsuAppHS0Wcxd+Q1L8QXNHifvSD8NkMA5/w8e61l
# DATA ZelEbEW2LYeFa4U1DVnqp8vvUv/LZ7/5irc3mJ4HutePmu7MXDArDHJApIyM94ugexsZX6/5m9df1IYCO7JyaZfYmodNdPMrJr69
# DATA q4yu2nhBv3+g9X8XyaJQJfa+e160TSAm2vmVc7K5bsW7sTXaynw1C2ayK5VXuaTKR7zFwzSFzEJEoYbdfUPOBKs4q+3JtlMtvyT9
# DATA TyyoqjmN3cqIvS1BPCX8SWwrRmnlXYCtSv3jzOwvQeMzxu0H4kw1Ss2MHD4ex5Mo7ydiqNUusFcnZclbs9JBrTnKxZtZHlitcMLE
# DATA lY0rsvWNTN1SFdA7rbyhQvWZ3kBrB6NLtfoeStVySvdje3AeDutJD8IZtIPnlIAY5xTDdM4Lvew5Booc7srjcSQGfN5xIWUQmuZ+
# DATA jRe2yOioeQpmhxQaoelsOaeuR+kHF8Wlb3O+vyrWswXh4jk6zyFsDtc/MoPrq7NfCe8K5KxvT/9JobkA5wKL68tVAtd/p9ueANAl
# DATA aK3T/2WFQ58YsPUnukdDtr45++3pPxtK1+mXdOMTftcfzv4TE7pw0sE7/f3pV6f/iypNOHHArRfC/mfj3tq6AVRgmgDvOkU/wfXN
# DATA 2DFMas0gT05dEqv3Uc84E9XvY9YNl6ULLbtdUdzQQzT2cdhHPyWzdVHD5joDsfN+hBnCNtjWp3SXiZBDbRVM/7xnuGnaVqlUro+1
# DATA JbRvw3/iLdnWW607f55RcesbixXsKhFboYCtNFxBLRBKYhxe65ziunK01kchGZ34mWLdqlfq9TqPGpQB1EXVvI9oADFWDxMseNI1
# DATA DudYC9Y7/xdh/wCRFBx1ZiAUKK7oIQ0EOFtQZmidW902mynFxvOs4FnnJsBxs9zwftXDu2ZmXXxUfzWceTc4ol/1gL7TeL7zcH4j
# DATA o7nUxkLSbR/d89SGroORVUg4I34yxWy3k0mT7jBTi2ZDLJr1YZmH2ElcoYTGQPpQo4kpCZMYLKnZUL92FMYT+CsHIVhFzBYqJguj
# DATA bWgyekoDnF5gjmfZHEmCi5RayK60rDxk1gzI5H0Uf6Y08Vb0MdU5uFfoIp8p59Pm7N+YYYWP57BLJkTNQ3HAJkNGZolZkJmz4pSi
# DATA +ydkvD2EpywehuokeySGYZRhH2KcjbGOGcKrMRDuCtIVj7ABcTCOpqHHO9+ZwjXnscihtBxKy6G0rhGlde4YtNNUZ0fz+eZmAZeZ
# DATA BFzBHMChsxw6y6GzHDrLobMcOsuhsxw6y6GzHDrLobMcOsuhsxw6y6GzHDrLobMcOsuhsxw6y6GzHDrLobMcOsuhsxw6y6GzHDrr
# DATA uUFnBc1mvXVpdFZz1Bl1XiB0VmHVeSdwFmcsx6XHGSdoprpfkKNo+91ihjd6vc05Xm/0mqsgp17ASCoVlAWX6tS7vV5/HVyqIYEM
# DATA 4pQlqNTL2hZbqsHx5ANz3SJNathrdNrrnm+1dnq+1++1++ue7zZ3eb4b9TuhX86EadBseEHQrlLFbvW4egfTht+q+oHv8bWqXKv6
# DATA fqPqNzvVTsfzu74dNG8YLeG5usPusLcuBxkXVqr5nZ7XbPhU4fFqrz7u1UvBmbxbCa53CQQWNyGNwJLWaCGwGu12vxNcBoFVj3pR
# DATA aCGwAgqokyOwgmF92MwRWEG37bd714/AoplQlX7fadIeBDRWFv1WhZFGRjwdoscH5Az3SdtwyvjUCdYBpNq1si4Qbzl5VHKZWGPA
# DATA yt1hyew3pnhXmeL5A3rULs8D1835tJewy15CWR2En3DNYlu7mIjiQoDMET174qMMufwJMwyuWbErY7jWenx0RS16GDZBu4zzWEUH
# DATA fmNr+sXfz8mn4ovaSA77FQtbTzY/b8bpc16zYQq3GetlKvhOOK5tlXfztL5UmdfVyeXk3MklR8Fxvhzny3G+HOfLcb4c58txvhzn
# DATA y3G+HOfLcb4c5+sV43yhLqgT8tHwwKZ+LbBkyhmB1N2Rup4s00GECsK16iAesZGpGubdVh0Gz2IMWME7aZogjm8rywvNi0we6qPT
# DATA Q+mTzWvvlIxpa07AJmwFk4uK0L+wrZHL4ZYwx0wg9J26is9eY7tGzHPv3fzoP9nRJ9mavuDWwWO20R/lscFWy1E8o+xQVDOWEVW6
# DATA D0dW8G+h86HmCpdqBecYp6GcoeJSx1v72KNM80t+kRU/JahLXQ1OQn2YGPvUO8aZRWV90m8cQarWnPs4tVPVP9Iv399md3AZUvnk
# DATA 6bqTp+zWo0JkRIzKxEGLNKo34TQg4iFW/8FjY8x/9poJvIa40VvNhdeprwKFja5Ra8+PQd6WG3Vu8NmjcnpVck1l29peOJ3rCm+3
# DATA YGgyh9dTQGwvS57tiQ09WKQTmvL9zd/IV2wGpK+3/uqv5Ds9Snn62WvvMOLhtVuPNljeyuimrjBb3GeLfU8K1UncOzWFS6kpOBWF
# DATA l1tF4aLq9s9UXcE4YCVFItZnKbkvQlS3ux9qGW5OKR9kXULaMt6ckLf12f1ceUBiiYe2PXif2y1v88Ki0ManCtkhxoLV9vKnbiOm
# DATA WoeQj8ZuFLg3JCYlhUCteru4/XMnNvECHK7m/14xOaEoinHV3ISy1shaasJFVbI+TWNlusUzZjWS7QZjxqhkGR0QVi7LYAEfQ8hs
# DATA uhQNhxP2U1eMgL5URlV5uKJglMxE0d7S9IDGQcgWfTJaMFwpjdiNzgQuBdxiQ9/jhUHWG59FD9nHq5Q1zuUYvRzn5E0Izrhzxt1O
# DATA xl1JKcdpZjnNrAtYdRtNx+vS0npPBJuoYqu5vHIicDXPyT43rdh4EyL3yrOgM1cn/Q29E0MrjuvboJounjJcZmdZQWCdMnIyYY82
# DATA AxCwVsyj21/BxXSAPk0+7asLyqKWbxX5w25xddtP/UpQafyMBkUdow2S8sqpRu96jz9xlS0iiM0tpm/NH1ohAAeMbDhOPN5KsgU8
# DATA 3BTDG9zD0p0roOCNYvLGh5VXnRdXRx5THpGXUjbSOomzpRE4m0urqSgJs38bHoX3pYtVamYgrGg3KJqJygfWezueFbXQRDUrBKTF
# DATA dskpfSwaMCF6JoikyYlyhJrmDoUrEeCip49xuouHTtacstx/Nc8UF0ZEspGXg8VSUZgm8RQXeaMRBKsgEse0C2h3ZToqpYqQT0Vs
# DATA MzmfWkhpFV2nmFvqFX7jOlRzPlNzzpedfzks1HyYcSaqM1F3MlFtW8QZqM5A3Wp4Pmux1w8LjWSGgW4RT3Mo031ZJmUB1IpFAZTU
# DATA ee9oGUQILOL4DmcX/Y6mMkx4rIYuJ6uFhocUL2w5m50YPcgdFVw5uiY2QoKiWgBBRzEIqLFSu49Y3xKdxxpvnTpxvMZSlT0KqGD8
# DATA SdGBlCWjf8yNK3OFpSeAnI84HBU72XNjuqXNrCKz8YGhP/K5aFdad5gu0X5qxWTEzgGMjugY5b54m4WJFql9yZvvsnRsBeNovm4J
# DATA OcriQ0772/xpi+1aZIPLTgLbYFE0801mY6GMsbtaGuslAOw6Ny4IYH/0eDOBXTJWCOyYxEWaka6c9ieaxP4JtoxSytNlJtu9uAbO
# DATA WDtVCeliDgQyp16BjrEJI8QGCq+/JENXKabGg5r3dswCq0sW2vWmccazR9nrgu1KTBHlTSByjVsrrwwLiQEIInpdqvhsT422L9Wg
# DATA C2bwv/zdnzbncKE2SkazpGsaifAv/KrxIF4Y5D3/ktOXWPuWjGrRUk3m+tT9gmpbyjq+OLy6iMU+vzfiQ+E0N5j248MluI/K9VvR
# DATA 3Z2gooT+GJKxzxK+8ZB/kwn7VeToJevqNNutrn4YTqUqQMo6zzqpLZjiQMFW9vmKqi10qifRAkgs2d1knvYY44Hei0EfJ0DLCq1r
# DATA BmVANAiy/ig61HtSUagNCqaBPPvq9+8uVPmEdcaxp1R8voyWkc6/9zGDw6SNJtC5EvNxGLMzhy+o4+YRANBvS4PkNQmpOFleUTlg
# DATA ZP0IRws4PykDZ3AhcUALeQqY3ggURRoqUWhXUvVM137BjHxvS91Tg4TkYXmF0luk4RGNm8eUBp2ZH6ujBGMlkB1KtUzJhomGmTIK
# DATA qJebLRgch7Bgl8j8hBryzPQMqledUq+R8VwyhsSjtayaw+UWsZJzj2j+q1W4Yfs903z9ZNd8/YQJfNZyFc435q1bLYel0SH2g8sB
# DATA EUpIpoYMjDa5er2RPM/YV5FbhtFoxDls9wNhP2PxapqhsXtH7lHVGb2pWH0xOtufy27WUoYWjQTZs2gbCeaKZA/ZtXp3oZ7YsbNF
# DATA 7fqjjmgwTqCfFcJfSiWpC+KVWHizMXpUEpFN0Psvp9+e/YfTr07/+fSbs9+Be3f2SyDx6L/fnv7+7LeCxvvD6ZdnX5w+wd/Tb06f
# DATA nP1ulahnh8OsvF8yjQ/Pfnv2Gzx1+jVdZN6eoPfo7589uuWrs7+j5/5y9ivg9BCDfhodVw167+uzX9Pf3+FnJu792aH1XgRvjdQ0
# DATA mzcvU84HMVrpTLYFg9jwY+ObEeV7mGNkMQyh9MOWgqxv4PcHejtJGg3iubK5siX6I27t04TF+reS9N6SeFkNyMH0bC8NcuemOXqr
# DATA ZXJ9KD2pOvlK4sdSlUTypHwzeiJrzTE6vhZaNu+onqtDF5QVMmHE26bRbOl4ejuU2ZUj9cSs576cux54mcVv1icDQvduYs9zN/ZJ
# DATA 3i1RdU2OFdRHE85ZZ03Qv3zoAIUWT6c4owOYEBW2gRFfqP5twQCXG9WzQuydnwjH2HPj/FOO8xqpd6nh/RVZgLmRof0aRvadBvaL
# DATA jOs3M6xLlSzngIXWe5ZN5zpIeuWk6kURcamGLDdZGhEze0hE/FfGxIpAsWRxVtZYRcniKFokc34myvhAe0Lm0mKcDLNdMHkfIw9l
# DATA GascI8peeAh44y4lfxpjg0lCVhn2bMlAn1cXemeYLVOAwUIWGKVMZn9+Rbvt0wjth1N0wiUjOjhCAoRjhUl1ujJk4URwXwM4qzXP
# DATA zNHwHA3P0fCukYa3y+ix01xlV2P3Ru32y5jtV2G1Oyqeo+I5Kp6j4jkqnqPiOSqeo+I5Kp6j4jkqnqPiOSqeo+I5Kp6j4jkqnqPi
# DATA OSqeo+I5Kp6j4jkqnqPiOSqeo+I5Kp6j4j03VLxWO+g3Opel4o1GvWj4AlHxyivPO4HxCtS3Rs+ixjXqDUN98zudIjduNOj2VN5Q
# DATA BGMaWU0QjTyIZrOel00gtD05PBX0CuF1msGgMVgpqKDle0EQjINO/chvNj+vtr2eX/UbLa8X0J96tYsv1V6wpuRW0XytgEJr1cfN
# DATA 9uedjtfxq02qB37zHOqcCWwFExd01mZA1yL3UeStytlo5RnQKLz3O81B0G7UV6LcaNc9v+V/XqW0Nqm2VDv+tNWkuH9eDXr6yqUT
# DATA 4AeXAN1xq9CgO2lgFuiu02w0ms0dQHfDUbsIuguHvUEzB9112q1eu2VAd8POoN63QHcdv+E3OzcAukOTqm63NzweXqxby3y4H0TU
# DATA C8RhRQIuLeatoOIavGCWL5cVg1Z2y4qTSufQiiOy5O+3w1rngb/QoOqx763OhpN6Ri2BrU26cauuRtKY5UWEnApb0HXrtwqUiXar
# DATA mLW1OWMGPr36Vd9Gg9uhFlyXKeLQbg7t5tBuDu3m0G4O7ebQbg7t5tBuDu3m0G4O7faKod1smJskmw9s3RGQ2hCn3F679T35xkuO
# DATA jOVSyLNkEU7kfrSo1z8IF+MazyT3+OKt1ykHcByV3qOcaHNozCznfPte4R235Rv9mHEvskjexXa8Pd8O5VM5TGYFUn5nKRh+duXI
# DATA mSaIyRTQHOlwh6jdIep1h6hLx3zccWp3nPqix6m3CN9e1zFraQVsB0OvXVZZzTHrZyjkcRPUhaE6nq1qBr56e4e3lKStbnYzdmDk
# DATA AvDqqbxvUt9zZkGRxTCNWYCupbAN7PuXRSdsseC1qJq/WfhWxlNIMZthDcWAQ9WS/+dEVz9v4msumAj77XUR7loRDnaPLw+qoLRx
# DATA PDiadOWcSKqHct1e9b3AgViJoW/FsGtHsBi9jbyHt1SLioxo0IuLe3iLrTwexhjghcmJPpD83ggqm+hD+Bh+xgMd2l5GZsm8wj5N
# DATA aqUTeP0nJx6UNFHJYvDyxCgSb73QuaTW8blxaoYqxCEFQQHCzBnrAAcJjB4Vkj4OzvwJrslRtsC6O0+pWIJpyhaxJQKA0+CswMjL
# DATA qEOcJPNk7ebAFgOAyYbeL0umke6I3qfZyxFmSGMGYHD7HmB3sEoQop33NecDGl6eg8UOEuss2e2WrLNbX3K79aJQ2GcuD8QL5tZC
# DATA 8KrRNylIAjL1J2PRbcU/6PMxUpgiWxmqz1xV6AVR4LgObOqKAtJVk1PXqEmth6fupoRYqn/IapumwCLSb6ZIqxrWWbU9V5DmPT16
# DATA IrTMBE6l+alsi0WYZw1PCpIuoYeNEsupss9QwehDFilDCYFJTSoaKAqd/C7fYIySsgQ3x/ljFnuVKEeUxTrG75mJWsxzQIqq6Bkt
# DATA 4rTCyuwcG63KXrDQtOK9jQ9ggxRBkRWAIxhbov0RFua2x/o+oCsq1rxNKRrqiL+jJa6GNLtFbCgJnHsVnvJVvBNslhVVJ/QYi+Qw
# DATA gopVzbOM6oSVRacegwoU9WVTdPULV2P8CgnY2H2SszSdpbnO0iyMU85j6jym5xmoz16YUmKQKWXFNEmmrFLHDSKXp5xMpKmsFUms
# DATA qXpeEWdFRQYj6M6hGWF9mqlg7FnxZPVOtSteRrwYBexdthKUuqO0SbXcyGGi55szdhMu4HCCDQwikO2gYLtAwcTisk2rTXcaPzfT
# DATA XfSXzfdrlU7OVfV5891axrNofjz/GLE8/y7IcfH3/fZmlIsuDEG5/GgWUWcyZ9diFUcWtWWI9Q2/5R3aKxlBs04XlBvx00gRyGgK
# DATA gq1yk5MK2e3Y+9unejHC1wXGS4SMPSQZ1jzkVEfGPQSMreMwG4uWqrbQ6dJkkl0FB+dG8u+T44Tzb0jj1LyYe416MfeaXSv37vNC
# DATA DZLNfa3KJCiWAui8YDlKkcaUu8QvPImAL8JmXU8dwhWh0ivIrUIbvHiGtTZnmNWgJc9+QH0qxe7dlKeyc5nA5PkWlGpdo9Oy8m0B
# DATA U4qXydhwimfLBYYciJZOihMrHjEY1kM1j2ZXioJnJmFH2NE4eQ7yrn2BvHsLVSAVWYl8fbCQfaVq1wjqpeyr8FSaTdRDKYqM5qmi
# DATA lApin7RG7EcfpuExtvLqpQHWm82XBp4mz+w+/IJZ9sHm/MpHA4XwSx6E2rrWmfQucyqEGwF0n9ALj8jmMGY6WbgPqOFNFNppyKrD
# DATA 02TIJD9vjHVg72MRCmamFa6Y5ROzKpPRQE+5zpq8aNFXkW32YHbhmhZszrh8YJSMM46BooGm8/A+riqvy8zzu1TDhjqvQq/R5j1D
# DATA VFGxLZBdCDRdUo4Ysd0YI891LfEOl7HiezE3Vnlv2GzkLefPK8LrZXFI5BivUbyAxKzN8fp/T5+c/er0m9OvwNh64p3+8fQPp09O
# DATA /+fpV4ze+moV2PVf6affn34LxtbZf8QtniC5Tv9y+if66euzX579toJwKEwK6xv67Z+9s9/gpyrd8YR+/xW/6cnpN/Tmr86+YDwY
# DATA kF2KAPYr+vrPFCD95Jhd/z97b9fkxnHme861PkXZE47uNgEQhXeQamopinqZkWQekrb2rKVVFIBCo0QABVUB3WzLipCtmTMzMY7j
# DATA iN2J2IiJszuxcS72Zi809uhYli3NxX6B7q8wn2Sf//NkZmXhrdGvbJIpmyRQqMrK93zyycz/73lwqWRQP3SZI5sHJH1IGsEHSk1S
# DATA 4wKTWXfK6vfSoVCGhVOBL+5j+heNxAUp7RYu1D5On4MDAIUSfgocRt6Iyts9u0ojPw6GazFe97Ey3gsOTUwdx8v2tagO4qpBXktK
# DATA 5fJIXqoWZktGj1S1HEYUz+Rw/n6pjfrmd3KV9CJhXnAZqpiIFr7szA91vBzQa7Oiu3Cm16MwAx1kLIgEkFTdZRkqB5ecl6K3wV4g
# DATA kRFmqII5RQzPzyG+lry3o56eHVPvJtNrcU6plC6QvU6ujKvtmcVW9qzQXienwqG9nDlw8eaApn2dzQp4KVZbrsoCuAwDYKPx/5TD
# DATA /9WM/lIxF3LBgn5ds0Z1GRywheQDaoq1oZQ57+tTVuAaCNUrTsJ8Ot+Zqq0RvAWCRUKiIDFv0kFxymXBCcWpXAcbkcEes68X/iBs
# DATA wEnheguTYFhQlhwNaFFvhuILe1yMMNYSqiG8htzLME8cYW0KmB0jMA8oUHF5wDlFbRyumWhcpCxmELtH1sU0GofaUcXLZwgdy9Aw
# DATA Wwpis9CLxQ4xIChHCXOUMEcJuzxK2IZDzkZzoE1N56udBpxlFnARkwBHCnOkMEcKc6QwRwpzpDBHCnOkMEcKc6QwRwpzpDBHCnOk
# DATA MEcKc6QwRwpzpDBHCnOkMEcKc6QwRwpzpDBHCnOkMEcKc6Swa0MKq3WqPf75TKSwZr/e7zxHpLCFpeeNUGF2vvh1r+q3BvVGe442
# DATA 1aDesRUuo01VW5JDXEZSBjVWpBRSlu/nlHrmy67i24XXyOW/eWcu9Hrbv8TQ240s8Fo7F7ikKgvcrzZsCFgu8Ha/1en05wNv1NsX
# DATA HnoO9FYTFptAyvxGBnqrt3IBhPUgaFUXmgU97vl+a79WH1Zant88gUC2uk40zwAg48amAWTSbnMAsnrQbmwAIMtdAYCs3uv2yxmA
# DATA rNGth62yAZB1+91KL7QAZPVat92+dACZbqBr4VMlv64pZLn7zeioFwjqm9DG8kFo3ljWj+ucWnBkWo92sCiz5JlNlwVKDWWBVGzH
# DATA Q6W0ZE3YZ4Mo9+acR0EsAzzH8xfjTfLrZCfApFrikawYj6Rkyvwyy5KFvvrCCyq39VyLem8/s0vmot9ie24ZF63dbudpaFhlXk0p
# DATA y5VbYa4s1lg7+RvnfA/GfegwZA5D5jBkDkPmMGQOQ+YwZA5D5jBkDkPmMGQOQ/aSYchQFyiU3jAshLxM1NstF9jpzp8mZHaH6e7P
# DATA PyrAobof7rIFW0BH+wA/7aJK3jYVmk+XwTpKtnc+i/rb8tDOZzpoaqEwQYJxNyyNyULdKapX3baDv82qzvrgxrZEb+c2uoIPtx5n
# DATA x9h6ghP73JrjYB+hfr+UIo59rHkv0k9PUVJZyYMmxsm26q2gTyzppwSMezd2J2r3fvpjGHa3KX0I/FX6beczfnp3cpvPZFCc6Mcf
# DATA 8DWKx9LU5BJssv62yfDbUuswoedGn9UwyvM3lb4z5b1CwumTP0b52XuMQ1L585cJRZ8JHpQfUSzZJ7b87c9Xv45Jb90wGm5vU1KL
# DATA SPPOTTZtAXlTWUIxoSSbekENiVNfYjfuzmdZhbEuS9zt+yjjbC5eVoNULJGrkkNqLNj5LMswFB2KM6JsjF5V5DyWdEM6oxs39M2l
# DATA yYxMk89UzG/JnThlR/cVOCI0sf4Ap+7+44t/Umcagc2Lbvg71MVQJBaCL/o7a8LG8Ug77Ic4LsnLH4uhf57Vhc9VHeHJpG6Ti1VZ
# DATA PXA7V/tvSz3bxQxWVz3rhkKlXs63qGQ2FilhIfRxdeBWRhdeW2fgZm1ePZXgDOlJT3H52t2FVfOzHJjrZ9Y1iYdQWc3ag0oUoqKT
# DATA ZOaAS6LFZ1CiIc2HTJ+qa6B5TMaKnVykKdiDaEzTxWWBYiWNHgrnMskxY5zOxBl1Jpy+xIuvL3Faksx10J3glZWcv349TuY9HIIH
# DATA kQPiq/rgdLCHV03jUZzQzGwtU+Y6ilY8P0e4L4M0s6ixcdGomWUiJmdkzXi5JSKp0rzCdscva2lgwWwaOTF6mboFAp5STzKRD1vo
# DATA /QlZZQVxPYmWPSJvLG9ZzYsnmEUCriesh8EsmbLUV6TeO6GRfyz6CbGS+jAi9muEPk5SHn2BjujnGo4zoZwJtaEJNde/OtEuJ9pl
# DATA Db8rja/rIOb1+iwCUysvW2WkvN4SXSi7KWHkmYQxGtrBIM6NUIIQ0ANYybsLERsUHWvqBDIXVvCx8Ak1x2AY9aF4A9FtOB9EQmoc
# DATA hj2NGTstP8VEVAEflJw2pNULS5S0HDxlE3jKKJaiY7179XkdECVhN5pI4Mvn1Xdjt49ws+/xp9V3anNH8YX48/OATrFz75Qq+S0Y
# DATA jqt18rOyyLEs2KunxfF5VpSNbBi/kni2N8gawycMe2cJD41Lmo3JeGQtqmzDNNrzfhyxtlWXzUNPn6CH1ThjsbkJy/fC2KQ47IXT
# DATA i6AMnCP/6qfLvzfC9InHznYLLQBtXAV3MullyThxhafMM7RNh4Ng+ITySssHcni4bTYEpptRjV445jJg8TacgvB6s0SL69IgdTFM
# DATA i6wZnhbOUFmfb1mrlnx7ncZ42ffHTJ1ZZGqfsq2ozoXhSiFDrB6NwbKQvGRpOllMSBW9K0ynJe+vGYgRdgfj6NNZaBQUqZLShA6s
# DATA hOkA045BwDUR+TpVFfcCcjPrpk6blyfUQd3rSU5+QHWHVRC1VLPBkJpMojRyFWILVaFGDRKeLNzuE0hBzpmyKvcCll1UyL9hqCaZ
# DATA nO1KQ86Ievfzw/CzasGN07Xg14Mh2xFqqhDaLBoYB5wh6WyCCRglMEg6h2pu0BWdRdnpXPJ4pQa5y3LkiWK7Ua71wxAiiphqkUUR
# DATA ppOwGzERVtQvk0PWMzST8HF4cBE5aI99p62A5fVZmA2lCraCypWYi5qCS9OuEXdt6OwVqcdMw7oBqDyUUQdkYMNUxw4Kb0AWIeoX
# DATA soxVQFn4kCo1dCD3sVVM7bG5tlCVF8i1kQXh/BrOr7GhXyNf05xbw7k1zrgmtNIFcmka5arK5uivMMWpmhvvxjNnZazzbjCTcSXH
# DATA njd68zIHdn+rk4v6mpn08q4Ge+Q0V/Ssl3MpOx+JnSH0Le73xTQIemIX5BwSvKuFfmYbyfQ622p7yo7yi+gWPuYN/XiFREo9bXpG
# DATA /d3M86tyfBPDQELGPRkvfOYOF0fBU7mjLOfkwgkfzVvtO+FNMpwSq0w3jqp62kRVfzdRrZwYVb+1cVRl2w8iy59Oipu+PYuduWLi
# DATA V1sWPd+KXmVN7NSqoPFnybkAnv6Bt3eT9ymOyMSWG9n8SEZ3XhVphSwLcSzEroPZpVydm9DgPpXjuDcliKwiG9+M1T7MpRUOHDGJ
# DATA aDLYs0ztnML/fybbtKsnqDQx72OUNCAdmTIcBDS8A7YzoUfJQMMMTFGBslmsBlIqOqGabAkl1ez9tZCWGJLjYZFhlrxji97SAw8z
# DATA FpoovCgFrxf94hcRhhR2r4xnKQT500OyfeNRmnlR7ZgNwuHkhIXjuVLNFo9tv2q2DCz5L3u26PEH+JCV+JkCk61c0ijDqVV9xIbl
# DATA Ens5rHKLdThLyCYmk86mHf43hhd+DdpgnkF4/Bv8vUg7/Oejr5hH+Kej749+7x3/zfGXR98dfXv8X+jJ7+mT4hYy4xDEQgmcQ/YY
# DATA iPgVMIrHX9ANvzv+B3roW9z2/dG/UTj6yd8ffQ9c4jeMQaQgHfPweZhhmOqVTSy4woN4ghylZwrKX8kdjkZisHCSoTtLhMkiekCl
# DATA KDQCGFaG4EE9qTZ6JlHYpdn4OrjhQ72NgQYARqs5tKE1mdAFdtVww4VSuTy0oaoj+jZwNjRxh39ZuB/bV6wO91HcV3taLhxtyBHI
# DATA gQ2jlCu7wxpuVmwXjjW8/3QyRC8TaGfIKO7NhgHI6/GUNXtK3gfo+7nvyvZ58eIXNsbTs2b/E8VhNuKeMpVtUHChxNNAr2UFY0HH
# DATA LAANT66Cq62W+Zb1rHCGJ6fB4QzdSH+OkV5zC88ywL8cnsIrG9wvfmzfaGg/5ch+NQO7VMu5PLCYhc+q5VwGnHAulVgBAAlIcf6i
# DATA rpVYfc5xPkGBuDQVVA60Nb2JOkXx8OZr2VasJbphJY3ZKzqfbxsSCY2XNYtdOo27vOLI47FGxTE/jmtJj+ba49REP5wlsReMGP/G
# DATA Q35IZkPUjbA0nrMJchZA+BQHixF4L4Q3Su2oVmuFZD1Qcb4XBikixLZddwpXjBiJ7NURSp2sraui7swOpX45WqGjFTpa4WXRCjcc
# DATA ajaa2mxqGV+ljX8WE/8iLHzHKnSsQscqdKxCxyp0rELHKnSsQscqdKxCxyp0rELHKnSsQscqdKxCxyp0rELHKnSsQscqdKxCxyp0
# DATA rELHKnSsQscqdKzCa8MqrPu1Wr17RlZh2Ov7YfM5YhXOLTyfmlRY972qX94vttuf+s1itek16/T3oFqvfFprexWvUfGqzf12O5dL
# DATA Xb9T7fbnMXYUVmMpxq62QDaUk34C8GvnAX71qj9H8Ku1srKWY2sZwS9shUF3EZxo8QFb9VzwlWo7H3y7ujJ0k8xc6LVyfU3o9TOF
# DATA bpdIy/dqteZ+rT2irrVYa+/X2hvntL8II2z6Xt1vDhr1+lwo3Xq30+kuRVGeHjso7UZjB6UJWtjBRq/eavZOxA4G/U6/kcMO9ujv
# DATA XsXCDvYa9WbdYAc73W6tU7Owg5V6rVW9dOyg2aYG4f+9jebra7h9Yt96C3aRNsfn3mYGSjX1eiuk7iYKChK/pQDDulqJqyzQ+rCw
# DATA uPCCObe7bTTqAsnPu8nc83zYAV5D/thhsnW6cQ7VtemETBEjNx/UnWDeULGwgfnI2psL9Iiulr3Ky7y9spiST1oFvk/+S/2xZ9zr
# DATA iYNz2VqYz5M1ZsvaJLM94YCDDjjogIMOOOiAgw446ICDDjjogIMOOOiAgw44+JIBB22+myRbvBhCSuOj4oj+zo9b5RuVcoFmluqn
# DATA Ay7CHZmyaczXfTkkwwfd0Mhu8K/g0nVHCDj0/r//w2uX8a0XhpPSh/TfGLQ1CvfObvm1D7c+YC11PkfHCzUIhH6UIEo85aEIS1jm
# DATA 8A3i4nUOcS/T8YJOihB3zFP4xO96xz7KJqnzwnQKP3J4y/uPX/+/iMxC2rerlfINucrinugaEKRGmTmEmDvbfdLZbnem+0U/031a
# DATA Uth1OOs952Jbjwl7F03DPFHy3kO1t7VdlsLBnunp8OfnaORlUMDmD7NfNANsURLgrASwvL9Wn9V/l6ldUhHkNf3Q6Nq8Addj4PVi
# DATA +iE94DPaD+CERNViKaBBECUl71E0ZfeTFnyXCijC5bOJHE9WhZs7vh9kUkYTiDbGfT6LnInmzCncLJTzkxCmcmDkdmATXb3SzTM6
# DATA BWu1IGcMOWNo3hha6FGd6I0TvTnJjLoeYjgPpL4y0aIXG/zFJ3HHKOI8NNoN1AyjvbEifykNNYWPTGhY6ELcoo+bRUkiDYBfhXtU
# DATA 43F4Qz7Ld4gODdyQQ1u7ZYlmysbgr8dQnYF/LFOysXkw7LsQ1Q6H+9oM90VJgT6JSvqUW81q2Be7HUUWmj+uvpe353LP8pg/PQ/w
# DATA LisvTsldebSGn6RzVYgr99AqqHTFthLgyuODWMSa4hkEYwLIsQhkZYSWoiUSUcMD9kKJLJOYhzSu7cOL/AvIsySjvHqRqBSR7Rdn
# DATA 410AQRiqHYFo1PfZUNZnTqXRqNnBcmHnRQFos/AmNkmWQJNjWsoBYwMWlDlj6AFLEPp8/Kszl9zDjUvuoRwwFytdF927sEXQEQbM
# DATA BqDi2FPq3ymTvsIJq+MollAeHYbiY0kfUfumIpBJ6l3NZ4THUO2L4t50GE4VWCBRcUkn8fT8RZZL2dWVWdabnLLMfrKOVqb6JSmz
# DATA n0CACPnYiSlCNiCKpYn0OooWNNsTRhblLnXiuBj3yRoxPK1+eCCaU3pwm4okPO6UxR0u6QOmvzFzxTQ6Lv3OLD08f2nl0/QcFNf7
# DATA GxfX+wHA7byYQX19xqNKB6KlbxoD9Xp78Ic/CQ/F2u8EUNDyBvFIGhYmB2MOjTXqxh4VVAJaGFA54FWxA74fPRV8HEMTssKcF347
# DATA f6HlU3ZlhZaNwqcss8ery0yP56pXFOVAXMvKS/wR2IePYYCaUCqswKE4YlgeuavGCfbGeXe5fPuM76JOCCJkGPfE8sSxKW8y48Nz
# DATA LJ4wBtrlAvq9LO7Xv0Qqm5bI+6FSrsPwMVU/KcKlnA8K9QAjzUmsDRHqiz0+3oUWcCiChAIGVK2G+zeeWSMAmN08lEWpNlJQuqJ/
# DATA dwFtZjEhZyqmqyXMnQtj8jL42awgnKPNOdrmHW12lXI+NudjO+Ni40qf3CUJTsuUXGZ6GAFRuWFjGhfbM4QaXBJ5LufJ0ntPYO/z
# DATA JmssP7V43wzPhNXvJ4DOslBMd2VdyqhxJ6HOGhty2A60t8yAu3heoHbtbXdHJwLuJIAMcKe+W4C7pdg4Xy5rcFx5Y8id7OaBuxAf
# DATA hDEmFGSoFHNezTkQ1QOZ91CHsOCza5YZ+4Vt7d4BFjJ5f1GzvNrL5/v8yOPwKXqinvUU/bLmsRo/9jbdfWg/UyuvcROuRNRp0xS7
# DATA aclSmz6/kDrbdXcwoFC8T8jyHIeHJVvyWek6SycAh9BB7Pnc0oJEweL0hrUJTZOU6Y5VZ+osKE6YXvHATUEbd7w4NLhvEY+9cvdr
# DATA dW1+sdp25jHgkgqsWilzvbNaOPVRMw2/VHtyu/maCr1pJcNOoWgV9gJZ+E+l6xtTHIcyVWTV7MksAehdFrbjlPVTLYHsDSByL4jx
# DATA nCHkqBcJu0nQn1oIuff0teLx3x59f/yr418DInf0+0V03L8sxb/Rl6/pqS+Pvzj+FS579M/XdPF3/PdXAMfRlW+Pvjr+O4OE++bo
# DATA a6WQDoWvCbRTach2mLhrb+qzZR54ps54fxXsB979XiRnsUT0Xu0r4dlvP4nCcY86EP52ECfDnrH+4fmeTcR3CleCuM6Gh0zXjeHS
# DATA FoooOw2yBQrV8+Cp8Ck1tN5ahNzrENBgrQmP/xaehOPIZTMC0ylcNUduedFcHkxuQNFhckEGp+b6qq+fBJO7F4gk+GUA5XjzFdmO
# DATA 9C+NCeK6wmiOBuOAcpsV3YUD5STPAjZzxujcZF5lplPasFGTqZF0UGS56IrCC3w0vKHfZWt7bxZQo5iG1Le9EaVPCrB+6Ol7D37q
# DATA pZNQkTJw/J3SplRhZmwDwbU43YA2t7yOrjZxlrbB64KdW54Yh55z1sMlWQ8aS3dmo+GlcCFencFwSfbCRubCKa2FqzMWpJIuywxj
# DATA KFzPhnYZFDsrGwCawyJxL5yAQ0WmjBmoTQ7xbH5FtnTj0WiG7hoLeO9gBtFlhwVLiqSUL93QHvGTkB0U4v1DhqVqsz2N9FRkfL0f
# DATA JXyKNk03JtwBpJUq36yGiVGG7JNFmIifQ/3ap7lyxAcceEfQe/EnNKJ5nLwuZWDcn5a8hzreckBBwcLmncALdoucFdAIMqNpwSQz
# DATA 5Ad0cSAdPKBMjrriPea0j8Vdw3s5wzFzdHBCHq0LIDJVJShXHfPOMe8c8+4SmXcbjl5nOti1ziy/8pnGRXhUzzrPcAA8B8BzADwH
# DATA wHMAPAfAcwA8B8BzADwHwHMAPAfAcwA8B8BzADwHwHMAPAfAcwA8B8BzADwHwHMAPAfAcwA8B8BzADwHwLs2ALyKX+1VK2cH4FWf
# DATA KwDeshXojSh4Fi+ukuHo5DRalu/NOYXSeiuXXbV6u1kP58hqlQoVQG0NWc16dfvMr25VOpVG9eyvrjTO/Opqq9mp9c7+6mr1zK9u
# DATA VNrVWvPsr66Vn1lZ15rPrKzrtWdW1g3/mZV1rl23W1eZ4bl2fbpXnzfDc+36dK8+b4bn2vXpXn3uxlV+ZmWda9dXW9a5dn21ZZ1r
# DATA 11db1na7rtQbV5nhdrs+5avPm+F2uz7lq8+b4Xa7PuWrz924ys+srO12fcVlbbfrKy5ru11fcVnb7brq167UVGif+dXnzXC7XZ/y
# DATA 1efNcLtdn/LV525c5WdW1na7vuKyttv1FZe13a6vpKxt10Ol7FWblUG9Ud5v1t+mr3mnQ7PTqNe6Sx+r1Zr8WLWx+FgNjo7macwx
# DATA NQGx4PJ+Ixek36pWK4sxqZfrXqVeH1TKo2rdKw8q5bnc6NTDeqe5FMneOhNNvZrR1MWfY9HUW+UgrDfyNHW/XfUr9RxNfY6vDpp6
# DATA J2x3+xlNvV5pNGodQ1MP2p1+UM5o6jW/3q2UL52mzs7gYoc36RtPpyy2ayx65m1ticPafmYeiG6W4pYtu+mNGk3eoIntmcxEX9zt
# DATA 2ICfVV7DB8E225bRsLZlrAS6W6GuZ61LcSmnZd0su+gawccSBkEvPrjVph/xp+ypUvy8RK8awQW2Ygm2shDc+jzMAvTUVlO9f02W
# DATA rcyvkyW7D9Rar65hZhlA7QXNPN2FuRMF+eXt8mrYul1Sa9zhy+oaO7nZr+6g6g6q7qDqDqruoOoOqu6g6g6q7qDqDqruoOoOqv6S
# DATA QdUzi1FpN2zvGPuOUu09FO2PTPjjthCruMtmW3l4yLhyERUpjuJeuCvoCroo22zRqLNrIjJRhA2yW6nXG3W+ilmeyKalu5qNzlNj
# DATA hThXv6FRakA6IgYXxBTCbLstCTwaKdhI9ktDXhBPewiZCxNfUM25bZRSGqrD7XKhUduBcYSDKts3f/6h+u/W7l/+AP8mHMxHN/cK
# DATA VK4Wp53L1luE00NVYPez/WAcDYfBrUphMpzRtD+9VS1AMu5W/fOfc1R4Gmvi8pHG0z+a7e2FqYyLLEDmPbz73i2Dje+G0XAbb7gx
# DATA nz0/Lvktpsm/Fb0u0PrXWf4n0+GdC0UCEAEcmuQjCM2Pn0QClfdLFR0kOmfFEsGoIIIX0NQToUN+oaoz0MSbQp5vSuayrkGiJATJ
# DATA FgWk50zINGTp6mvrzCnO4Ki/wpL9zEw0IJE2J09LT2eVfOc2RhY4ruY0ciD2oRIAJRdb8oZjLAPBDwt5gQ6nU+d06k6jUzcn5uIU
# DATA 65xi3RLNn9Usi+uiZOdNErRT1tDKx8lI2d3NS7rtzSCNC2GmVdptCmwxBm826kYqaMzvWI1Vi1UxjXZeki6P1lqQozP3DSp3HmBo
# DATA oq5FR1y84Vpu6mcybivFtIx8BRs4ZkI9MIBA3WAZp8gq+lMWqJfgUmj5ejLm66nubYjFQmtKqc0BseVZTzLOE8pWFOcQ2viUlAjG
# DATA teYQ8pG/uM/RCZ8CoiayXuipzMM0Uq1S6uN0v6HsIpbby5Ru1dCo0//IGFKeNqSgWAe8jygV03xYqCcqhyLWsSh5P8PIufBIdzCD
# DATA brHWH1PmSsnjSUNuoBU8sABQxVNbyFGFM4uCjEso9EnPjT6WMSsRIsygYnqVOUuQrsuRu6qLlxxRvTo3FpMb03ii2AZcV+KE1eSg
# DATA fpbOJhihseUYes5U17phz+r/p8ETgSvAKmR7BpOvyaEqVD24BAfBYWZRyQAksYev2nscsiNTx43BroFlijGI2B5yuG5F03XJ5vfj
# DATA bZ/ElGkdDIYB1zmaN+iEvwsPimfZ9loVkGlQeb1AoaGyaBdFCQtbEy45lpILetSFR4ZsowTldAJEhk7Dn/QEIxOU06wbBnQGWSsz
# DATA phpT7bQpp7KB+pxhfMhe33nImiiDvfgCZ9mo4wxUZ6CexkB15ujLY46uNDOvubCyvcC/iDAb5uxUaTH093TAAxJsFWWhZo+wXo9C
# DATA YV1X+eXnS030JKCDtZVDcHO8RebOq9RBz7dUfRwtt8mrVZ7b5KWOmgVD/rasvSweE5PW343hlpI3Ho67OjpKfenOTxZOmbEHn2ye
# DATA FULe1rP8hdM1BwHTG2m0VvbrymYcaOVpzh9tjLHBtly8WVllWh6YeR2ziWVLGgYnDfawR/V0wWC+8gZm3hy1HHxz+Ir5uvD6LELN
# DATA X9TblkqxQOw6kfAxVi8uUESSkEyXoENWtwJ8zLV3nH6VpqAJwIPqnUcjAX5TbhoaMjc31vINFBF5Pz9rYRlwUN8nYTwZUgv9gNc9
# DATA kBfZ/IPVzBRxUWSSczrhecNxGqDiatCbsRbnkdIcZVV6Orpq8meMfcwedHkqZprMMLATQmacjCXBLEV1Vaq010TsQUJGZHe6PmL3
# DATA eL3BS2HxH+roqYsyk2YL3AtQlTiPkJMHCatmxwdjmrLRT9EIcui6si6NzT2Z7C3G5iUUKXbcZGfFn9WKn69yzs/s/MznNuBXThcu
# DATA z89seOLzPA6DVbuWmK+r4C/rlV/64f7Tiezb4VVwMmXCeJZqX+sJPOMsGNPvWZcMwLd1EoDZ3xhobIz+D7gbRMTyAGN9Q8ZYNtOE
# DATA ea6wWmXHb8pxv5pBrNbhZZrHH1ffi1Jns4399msYxYsp47V0kzp8Y8SEMsy334pePxExbQWTzwN90cSzdlKx1E/BmeZVfwX9o6jK
# DATA BewJofZKmbA+0uZxCzutr2S86ZOiW900tryRI+vARtQxUN8xF0fszrFR49NenjMu303s7nopWUx6mcaO6gZM6vsalcwdRBLymoX2
# DATA TD+/gGqzViAd8DCYjWk+hAWBdJpnVJv09wCnYbOL1wgsyhB69gRkZiCkpZcpeXdxeT8ie8deJGNLKHzaVasZnqxHqKMOfUXNxAaP
# DATA QAA2hyk2rPGsg2dsYkTxWoUylJIgUvQmsKSDifTUc+WZOVBU75htIsllrOUeMUieRS5yVuySR3M4piUcJl5hmwcxMdOqF4eCj1Iz
# DATA Pw+cqANUMsoMRoZ2pwrvY0ahkznZL9qsyQJmz9KoCy9PFFvI7KP/dvzl0R+O/xFU66M/Hf/m6Lujr45/64GdTT/829E3x79dpGf/
# DATA 09H3R3+m+/7+6Lvj39LdR3+gh/+d7v3V8W8KHn36np78/dH3x78GRRtBC0n7V/T3N0ffMEf7C3rkX+kWkLT/6NFd4HX/hoL9hoL9
# DATA Ck8f/Y6i9Ud+koL4Hf39HbDcx184uvb1nxBSJxaPwiLIcoLI0twp7qu61EwBwhvyMjCvlj9QI0SgbdqCIMHYOUVm3GQYKl6Yol1R
# DATA 75doqD2zwTKjdS1F+yEeoj4odOjs3Hwv6x6uGp5tlcjlEbNVrUqtmR5f4IqZzt/dCYOsu36dvnBl7IQ01l8kKpvCZXZ1pEcytbVi
# DATA YVL3krKyNyi0Cydl3xvE0KkPADGnMXWs7VfKYHY7KaIk9yZUbgt7wMXnSxYLdVL74fA24jrgbVJk36W2lypIpTfUm1NOU/9WWzBZ
# DATA a3pW7OsTI++w125YP+ewrvHWpxvNXw7P7RWO5Bc5kG80jp9qGL+SUVxqokl6ttv3mTaVywBUmzTK9tBVyePOW3l8uJwLspOS0rDH
# DATA UhnBdCBp6GMj5ECWbGX1mabngZBpk8HhdDDKCszaCxno3FDIYgzFmxCp3489E10B72rmMsdmHHvSapbDeUveXf6RBbpTIROzorMs
# DATA YaleFQGl03hC1tZAUXCnQQcZJgfsxHrIUmUA2ZRf3SgVfQqdpV04Ixxf2vGlHV/6EvnSGw0pG81XNjR8r8Z2P4vpfgGWuwNJO5C0
# DATA A0k7kLQDSTuQtANJO5C0A0k7kLQDSTuQtANJO5C0A0k7kLQDSTuQtANJO5C0A0k7kLQDSTuQtANJO5C0A0k7kPS1AUnXKtWgXj8j
# DATA SLpf7Zf79ecIJG1WnDeiR9v5ARdrvT5olCv71Wr5bfr+i/l8DOvtJXirlue3aoN6rbHfAt6qlX+s6/eaPX/+sZFfq3sVerRaLvpN
# DATA r1KlD161VazVvCr9n35rFltereoBnuUXqy2+VsHtda/a9qo+7sblstf2aq1ixbffyjsh82yraq8eNMrL2FZL6kYd8Wnu+5V5QFun
# DATA 0fE73WWh1BZgfDYlrZpHBku4FsCrkVXfap5kHgb1ZmchhpVK4/wxrPjVLIb16gXHsN2+gBi2GlkMm42LjWG1WTl/DKvcJC6plGvU
# DATA SM4dw1q1cnmlXPdb549hvVy/vFKut/0LiGGzdcGlfBqQngxCGqQn45kF0mvX6n61nQfpzWPz+EowD9Lr99phPQPpNYJ62GwZkF63
# DATA 2enRHN2A9NpkHVdblw7S4+2fxXXWfak6x6f73HpokUWXcwn5rfysR2cC21hw2VLeY9PjdrHSC/d2ciHPEfreCmlcj4KCxH3e+V1l
# DATA 17cseTOcb379XoXMk7VN19RK2nxnf27VSjqC8fTGo5zlbhwLOGKgfeHYGFY85RJQbZkDmv1wVnjKC7aI51O1KV8aKAzLK9HE8sry
# DATA 7VALrygh1mSzWrN8MlF1Y7BLmKziere9GrqXlXDBLpM1s4jF2qaSa1Uj5exeXzg8FUCtXzmNygrqdPNRBwF0EEAHAXQQQAcBdBBA
# DATA BwF0EEAHAXQQQAcBdBDAlwwCiLqgJoq7bJ0WAhz6LEDCNymwDFv5tuQHnw7bldoS9f7XXfxYRG25zYGIeMSuGt7UV4rbz8uFSqFW
# DATA aFAfGfXne0h1286OftzcfZtfZyri9rgQgf821t3ernrC6vV2bo/X5hIAcnrEyuKn3iOj5NPdO0/1G6QnoyvKzn2qujP6D/Q6e44x
# DATA wdGx7Z3Pcjl5mw8Ba1uRM3RnLlXj3TuUID5+CWOU5+1ofnwODkkoyclPhfmjoLlXUhC8HTbn8tPQD7fUeT90FFmt3KVRlyVk5ZQx
# DATA 1Udh4D2UQ8dIwoQ6WMbcmYRN2eIFcu8H6u07YvkvL5sTUjKN9/aGuZQUImrnqEWSJA705/j+kSkCBVSMd7lWats/7ULnEcndKezl
# DATA fnqLJhFUsWMaskLKmHH3UAqNX0NvK7/mt8q3qtXy7b3SHt0LY/FnuOEuG/XbOLVQUAHKNnRc3tF3h08n8RiCbcHwYTCaPI7zz5b9
# DATA xWdvlMoNRIgSMqYi2t5DYPqL3A0lvWjMK5u4kz1Q2/IpnmwvC7FJxSQF+EAykwUTAXfcxocbPjMb477X4iLlxOtfftS6zXVx15rI
# DATA oKQL1TJW4AQACTdKzHXtczUnYWV8jWDU1eGzrO7fVlXjc90GeAo8xXYjLsK793YPojFNrEp8qpzr5dPpL3+pLh6EnSfR1P5Jeot7
# DATA O9MBjdPe/STh2i1H0q1xGunjLJJ68MtfYj549x5FKDgIIpr9cfahnx5hnFxSmU/ZiuKJ1Yikf5SGcvtznu3beSJlJHHOmxeLx9dF
# DATA 9EgUeCB9KKe4O6EX0jRNt03qd8xUdklXx+fjoiFN63KdHorMPCZD3o4VSwpUlcKSILHGT4+YoKznOGtfk1YvwYhPzRyqdVo2Tstm
# DATA mZZN/qC1E7VxojabitqsFCC/LLGb+1h34dEVahPj0JZt0cI3z05A7SpUxsUUoMuP8cHbRnGkN0fReDYNT9Kx1s+azslcMJLLSjV8
# DATA XhJa9oYoTejKOglrfcyXos3HdaEYf4gui/M7ZuEMKh1eQBvIShMXJwUg9+czxqwnWTlhfmSzlJesJW94ClTmO/MZoT04WVaYW7Ok
# DATA 84P+nLr1+nf5m7/Lz2czHqyc6l2Vzd9Vyb2LH6ye6l3Vzd9Vzb2LH6yd6l21zd9VW5Bav1M/1bvqm7+rnnsXP9g41bsam7+rkXsX
# DATA P9g81buam7+ruaD/fqdl3qX1VUwbXqmubk9fXwAxdT1UCNJFKxFZow31fU8ErYSjMzSVkw5MRkjMHoBN5kn6CFJLSa7LkxD8glct
# DATA eHUejpqgaIVjFlL1sIOAgxag8MiQwKyI0UC13H/qoX9lmIEl+2W87ZmqFA1TmDdoRTAMgghTrMbT64FtIGX+/IsJOWirmzqtnzq5
# DATA mdKLOVM6LYj1mcuC8uaubJ/XZSA8LfnNC+Z22uKlS2GdK3GyrCHIJw9NSxUuCmTG12Blr4E46nMiFrihvLmX7RzUxpV4LfV8WU7s
# DATA UO7QZBoqmlBJMobWXaXQGiQscgXHKBlDeJrMKrKvmH/Kay8i1jqRaTxv7YIOI+bpvKupgAdUQWXKjTyhp0KKhvSOfexEFCrQHthk
# DATA LD9JL2dGDnT5tBj66XMRZh9rRs5px16lZPqzsZRy1dIZS85YWmYs5boq52Z+6d3MK42sZ6+prms+VeeAZaUP4QEY0328GSnTWJ8k
# DATA aJqQAZ5rZHszmh+zqzkJlQb2grw3NRejAG4pg8dqis91aM6xnLMaFkXUzX00rupmzCMSla7RV8awGff7XrAfRz1e/RzHUcou8URr
# DATA akt3kIHHs4RpRbeS94iGaK9PoYmIesrrpHKUGIPvUOKS8v5FBHJotMCpZ5l1Umr0s6kYbiwjB+Z3TxPhEOOS957S2fZGUTeJJwN2
# DATA wCh8XBh02S2P5ykHoFuN7mu5Jz5z9wRsa4yVGrzOlEfhVMyINJN+HsbYyDIFzVc24E0Chhpa3Z4G6JW8u8hMCjqaTBR4G0GwS+62
# DATA h4VtXGX0diB32WXu4YwE+uIxckej3yXdnCrvgN7GK+Nrkvd+ALtGuMV7sVGdx1U2t6gkYBZLAWvsPJW6VPJpPIqTJD5Q+t5S/XmV
# DATA XBcNV31PMnGMfZ3xrAsNGMagi+8qO8SbpU0Y7gaaTkWFgU9Rltel502W52fPGBZ4FgA5Q7LoeAoSwloUC1QpwscYpKY8hA3IZLAN
# DATA S2qTmDSwqZeKaUi393FCHU3BjINSHYBDFEwAXvQkZPg8ah5l40gKicnTZFnuoSoPQaKnyMzGGJixphRP0vlEij11EinodannvHKF
# DATA +EiOSi7M5j3CiDYPNrmNtFavW9SOYwxzK73K65zI+YUSUwprMi/zK/Mrz/laX15Lv0izMo3vYl/DyyXSaDIWljALuBFd7Nt4weQh
# DATA l6yprFN0OlYnjJZysW/lpRPs+17dMPMvvDkbntMX/+LOfjLEJb2tF8dJavMt/+Xo++O/BZDy+B+ZO/krJlx+cfzbo/8BouTRN0df
# DATA LwIu/4UJlsBTfuEdfYt/GGb57dE3x3/rMfryi+O/pz9fCuFSBUwvYqzldxT410d/1vRKBmPSbd+Ccvn18T/Qb390CMvrP297JDOt
# DATA JIaRxKYwFo3i2d5gyowckZlWw+swmkJdQ04Rm4nYbKxtFzKlMOoFDG+VAZ8tmFRmbsCgwCwM+AzqWn7lI95xQX1hNPQ+IYuRjShH
# DATA sszmcLoXuGqM5dKCuTygJdfL1Jo/6moqyKP8zais5tYHquZieLtImiUZqyykoNYwZa8JNYmJI1luUFoXDrK8q7ZWDal5HBYPguGT
# DATA jNREZjV4O8D/qGTB1u0GOG5Eo2wCeTaF1wl6GCEMNGochmTkYwGe6uUhzw0UBQnn5ycLJMsTat5qs2RZc3pWRMsTEuF4lm6MP88Y
# DATA r2GWZx3aXwrX7JUN65czqm80qJ9mTL+CIV3q5ZIcMAP6M2w/l0G4XJJUj+ah9InZc4FaJpXkIpYFXucMkO1RF+MsUszJXRZl3vis
# DATA Hk5iAQVK39TBujnHN+C4jXOovU3gljlHN6KkkmG0P9ndja1+3gHNsbEGLMoHqVABvZ+mmQklIz9Zbtjl3aeYRTAEBE0YjXltydAu
# DATA Ye1E8gLlGUah8ULWXQsNqXyrvZDGyFFEZsPBIORYBB6bJrzBrh862qWjXTra5SXSLjcZYjaa0mxkE1+1eX8W6/7cxr1DXjrkpUNe
# DATA OuSlQ1465KVDXjrkpUNeOuSlQ1465KVDXjrkpUNeOuSlQ1465KVDXjrkpUNeOuSlQ1465KVDXjrkpUNeOuTltUFeVmq1oN44K/Ky
# DATA FbY7/ecIeblk5fm08Mtaxas1Gh7lm+dXy0O/XPf8ZvndWrPlNVvDSqviVVtzXEu6t7OIwxz57apXoYyu+8UW/d322o1irV70/WKF
# DATA wq//4r2aT2G36sNGteiXm16r6fmVZrFOt9SKVXp9u1ipF6vNuTKph81Ob5EPWKVoNz/16+VivexVWr5XntaqLa+832y9Xavmw2h0
# DATA W71mZTGMVs2r18qfFivlZrFFkarUij7lBcWojpgWW80TyJomcgscPb8lr+tGCWZLXS7+BkfC63LR+lJzEwEV5uLbq7dqtdoZaHlc
# DATA fzUtT5qCRcvrNOph1d+AltfohTlaXtjs1dudjJZX7zdgWxtaXrVTa1UyWl6rWfP98NJpeVzti+sNA/buz/mmqahw9vJzKwBtG+TY
# DATA aZLoRZybytdF/x/+UAu/fdIawnJjZxX8zYrlyRQ+G7InD54OsldbhOxlwZwCsqcdkCvzyM5plaEKY6fqn+0xqrCdxsaAGcRWbCPQ
# DATA Y7da4CqvZt9l+Vqws2qNOXFCThiinYPPOficg885+JyDzzn4nIPPOficg885+JyDzzn43EsEn+O04TRCUds8lMbX1g1ojCCSHGK5
# DATA oaX9qWfoY+gNhrt3tocLfCeV4h3dkb1GwTz9SKY1P/fwYefGMF/JuObvlD6JozEF8CH9Bz7UbWNefrilj51ncSlNnyJfP9x6Y+FE
# DATA ugrgBj5rUtQ9s0NBh6rBT5qt5BTC3cHqNQer3YHql+RA9Wn1wp/tQWv2S2autEUc0TCnhbkXxz2cLfbYT2iO2TJJAoGs0dl+1uez
# DATA n4czivz3BWu1LztIftGq7cvP5S/Vb9/gmHzmpzX64aEI1KG0teykqhxGY+ZxSFFI41EIIRg+WitVjU/AK/cbE1lENzB/vjw7OV6A
# DATA DDLZmllj5zkj9EzhAY77fTim9YFm0T1E4FLV+BXzh89PIyK+UE3kQG6QWSfPRqzmWZxmNc87g8oZVEvU6LIK5QRrnGDNWe2olfba
# DATA 5QjZcJ+umwFZUqJdwRoYg3ga7yXBZGCJij8z3bQLAFjSuPyGkqGxRq9TahaLMYBALlCwWI39ejAfBRPOHGvMX6Z8eyGqxR+wvLf0
# DATA jVQboZCCnu8ShIvfhK3OLxp74VPKRy8dX7h8MIsWvzNOZ8NgKurlhyp5B0johDrxvkf93XB4GbLFM9ZUmmruzIw1wOdaw8W+ty7K
# DATA 05D47nkiQq/HORr+LvZdTH98ECYpSzFhpYr59iILw2yjYhCRAT+bUIMML1iNupl1onMWNBVnAB6sMEDE4L5gieg51mQ2LZMg845J
# DATA ekhrBXmjQ2N+SG9jcJQZANJWVDfLQZmiPCYHdv1RTegwU5+SAU1OHKUrpKW6ACxqXSlLlwqqQCwu5T2CwHc49hi8Mu5SQWn5qb6i
# DATA HlDeF4xCVqx6Zy1pioWnQ62VxDOiZNbpQCSfy4WZxKgm8ZDxxTIOiMZRMoOQl6czzeh4KfdmKC8wi92B0k3dDPX44kw/LIPCTUDc
# DATA BGRhApK3MN0UxE1B8lOQlROLZ62lqXgdzLQYBBOGDQeYYdji2GmodPe0FOScWCSjdrQ6pEIfhTKZsXQep7YAJMbK4QH4STPBhcxL
# DATA PEqLnVFTpr6LSmE/XKL0uKnaJqd2cudNXtrM4t05zGZHzF3uzKJhz2jxqciwo3HRbawOj1oAeo3eltV+Blbhk7KwlAWkf8zg2eYK
# DATA qwgMmBXDPZsszsruFRq6raTkIeDqvWYLAaxS9flV2RihXm7dYXpW+6lXY+5hM8MPa/AYY6nZqPvYtoyVI3f+dpqgqsMMb/Gn1Xd2
# DATA h9GowxHFh9X3UcccY1MW3XlfPmb33pS03ZnDlGtbU1bjbVMTI8oaQzNXutgMLM1enZHOLOcg6ZnpKW9+kImqysd8PsyBuXgntekO
# DATA ZGeBTGxnfHvNezIyyZiPt8lUKEdW7zyMmNXUCxkmRK21Kl6CUZxOh4cKfomfYCUaKXZeqxFeVzSeyhAYihwmdkmmg1jpiQYCPdfi
# DATA sQwUHxupWWq5PC3W7m0lhenBMlPWoTqodbUZ2DhFBn5Ac+Ih++6jpEvTxSwLMUeljgEoLrujU7MceEqoW/hEbdGhnuwerxKwbcx7
# DATA K2G2j+IOHqHeL5Q6TUXxJJVFM0UB47K4iOyyWskp86u9Nr9Mk5MM+wkkP6ld7IUmq+BN4HvyeWQQXJKRJe8DGjMLHqvkRWSEHSr/
# DATA k4KIUXculDjZrSLuMM2Zp2GDMW5h7yKyynQ8p8yo5tqMUr2YZNPb8OOIOR+NrVrFr6YKcUCxTNkREyRDtXqqfTNwImAbXACtWlnp
# DATA 4mk2fob3b+8w8xeGWALEnnwh5wI4xn0et0NI6jK6gm96pm2yfoo2+S5AdOjTqN0VKdFFgVyZ2mZfpuYm1DqVkdbKWxikh1jc00Q4
# DATA eoRsfpEe5vwUWyQFxsuakT/LCuZXNq9h78ZUxDRGDsNDdhNkdWxIv2QWjvLuisOPZrfUBNkTlxlryBDq4dlhpRdR1aKoWFtQB8aJ
# DATA nFjVUbJWxAUFGmESdZfmW34glr119kBsrkg23Hk/1rvgtPI0m2BqdxqcIqokFSVa53fpJIbYi+KAyFhik3AKNK+NEvvvAhLzjv5w
# DATA 9JXHWC/Qv/58/F+Ovjr689E3ixix/+fo66Nvi0d/AgDs+NcAkP07cGHHv6Lr/3b0Hf39O/r7+6PfH33vHX8poSPobwAd++roT8e/
# DATA Ofr2+Ev697d4E1hk9GYK4ysK4SsNJvvz0VeOJvYcUKDHsvKDfTxdpVKfUaAnYTxhfiMD1nlop7YnBmIvhvI5exsx0FguaSWGy3eh
# DATA j86E1fkN1INEIiHPzuO1VLG3YC4xu3186HBitg9FdQRXTRPLF8jlYsSisbWGe1/XUv3LIktsPMUhQNPH4quMdGFykTyxYCqIgkGQ
# DATA 0nAKC5Ys3bjfdzixTUvtwpli94JhF6uOoSyAHWaA6mDEO+15CWTI6yReH1MJj7lwLPdnVjlA0h2NQp78YizhdcToFyHTN7xeFE6X
# DATA YMROrHSrrZNcW3p2DLETU+A4Ym50v4jRXfPETj2ovxSLIlc1oF/weL7xYsipRvMrGsylRtp5kG23evZN5zJQYnZaxTGsdnAMYnoO
# DATA iw/5hCIFJpa6sLBItCbp74DBPpykQlXipE2D9Inaq4IIRGOcHMMxPpUlm6HEADCSoXofvC4Fa+plZCepNjKsd7VNAPhUjI12sAmw
# DATA thWRgbDELphBdyGaLrMHlDXA4CPYAVi9Sp9QYCYeEZzjXJuofg2xSxt7yGbTJJIyi8fdMBmnjiPmOGKOI3bJHLGNRpoNT2BsaBxf
# DATA mZF/Nt/jBZj4jibmaGKOJuZoYo4m5mhijibmaGKOJuZoYo4m5mhijibmaGKOJuZoYo4m5mhijibmaGKOJuZoYo4m5mhijibmaGKO
# DATA JuZoYteHJtatVxZJV5vSxPr9Wth6jmhi9rLzaTFifr3qVdvNT4vVctGn/GlWi369MSzWgNXyP/X9arHu+bWK55crXrNSbHq4C3f4
# DATA LWDA8lnX67fbzf4CYQyAr1q57VXoHbWmV2sX23Sh4rUaCLLu1YHx8nyE3cbrqu18sPVGq9fqLwFzVcsWmKvSrhswl1/O14dOrVkL
# DATA lwRQr1kBVC2yV2uxStSWkcEqzdM+b+VLtdr0qpQPlbrXKtJfvj+q1HzKIw+ZW+YsXp0QuxTpzlq9Pqg3W3OkM/PAAumscQZOGbcM
# DATA wynjRmZxyqgeNZvBBpyyoF/Nccr6lV6z27A4Ze1Gv5lxynqtbq1TyzhllVaj2mheOqdsEk5PpJRhfNH3bYD5shxlVXaTlVq8PIYh
# DATA bWeRBGZC1piz3Ey3Vv+RV6c/lTo7HXNoLslRCUFFeDOnmkqVcaxVzHR37u2VGvsC2Y03Z9uI52kNwkunq5CL35ohPHebdoE5ZJdD
# DATA djlkl0N2OWSXQ3Y5ZJdDdjlkl0N2OWSXQ3a9ZMguZXFYHK5ecJjuvhdMB6X+MKaJDcy+D7dwGItS/2OYNDfVNT4fhYvylaZZMFSp
# DATA 1bD1+eHW3QlN8J7CRRkODyk3biDoG5Qr/ZnIhfHxsL6lc6XOWvEqEkhZQGrpw1yBOpwFDTIEKcduAj6kjQMq5gyW6P05ypY7dnza
# DATA Y8fuuPGLetz4LHita3AMmd132t+1nrIlAlYm3kuPKi/ha12Xw8vP1Rm+ywBu5Y9bXzBpa64ynBWxZTlSs0PkKqczLAjkGUVAXqmu
# DATA cHYNqnfe5Ak+68ppHTquPhAKHSu9OTkIa6rPQUBPdOIDnHYO92ZDyPdp2bkR5ETjPtTwe7OEK2iQjLT0vToTz+/WEbhLtnVExi9v
# DATA m9VR0JQwyp4+Fkk7rMU5hZ/I480pYplgqXXIaYOeHbcFnKjshHhxj2yyWdIxwpMvyVFPKwxnVzm7ao1Ym125nK6L03U5rUG1Brd1
# DATA OXovfz2OD9D9i+JAJ9gTjTVIbqiBzb96ObELoGvxCoTaAaKv5bTheaJPV386ht5CqGRYjFvM236ytzNHAhrzOlAG2lFBmG5Kf8/h
# DATA kCjR1CVDT2YUsbxtuYQ+m3oW2ZIjxhH2cmY/rpCzFz8EgD62YMsEW1xpsN8+Mb76+axf1RcyCFervCzOdoyxXceO8poIs6eEKU1w
# DATA V2c6NsioE+KqHjVR1d9zuLC18fTXxHKOoKTWl9BaldNF1Mi5qluUJFSqO6/KXlMVT7XGaGv5Zpekd4n2JQU0/ipm600J4nwUKIvZ
# DATA ZLVvW/hI6dMrxEuAZm/0Ae/D9WQ3YG7QrJUSPo1ExYWHO/Q42gX16Yx6IWiVp7O9vZA90ABG8MqE6iDiBBgLQJVYVRqjMAc6BqBi
# DATA qGlcwkBj37hqdxBQIVN+xv54KhrowUAhONgzjFgoUME4TWUk70V9lk6Ziv4QKzt7aitvaOIjcvSQJuJoLFEnyiSJWFYZnkZExgsm
# DATA VOcwwG3KdnpBjN3cCObMXWfurjR3F0wbZ/E6i3e1CXtNFA7vsfoeNIv7GGSiMcuYLec7ab5sJgWYhKOIER2FVap7bwpTcGG4YWGz
# DATA vVnUA84wGxgpNGqvvRkAhDy8zZvAeWjCgsChuY/GdcM01b4nHup/ypwAjGdJTENHMNVjLtvhI2rgM5hQyg4I9pJQ4ysXh0ylf0gh
# DATA 9WioNsmBq2ph4GRpQIjLsOcoZE04L5iiQlOEb9vUdk2GDJ/y9ii8IwLUgHJ9xYxAJN7ifd7fpBicmp870QwvbOQUUMjTMOlG2O+Y
# DATA g6BKhnPBsGifJVSovGQl7y1wtrgbZW8aQ7sGsLn4LgaYgFgJd9274ZT7WU4GTJtgOudvw8E1E1mPDzeAfbIujXe1HKXp73UiP8Cs
# DATA TbN3VN8PlcmCaO5pMBEewfojFfQwLTAdIzXUTm10iZn0PgJDT3kIE0xttOSRJeEhqQNLO+xF3UBKUOEzkZULNd3CnIVPacwbHq5L
# DATA 5ft8pNiYX4wv0em8yzs91SGRWVKAJ5kVxke6+Hn6qEg5EeAnynwdQ4lPiX9ajDROUl6psuQ9CsMnTAmBW5Z5HshLvlVVC61YmePL
# DATA sP9UuCFQW4SDWDuKg5QntcHeOE6jdIHMwYbYSTrfj2PqmDg/sy6IW82pSdHs09Zj0IVwoi03t2oMcG+zE/sSyNDvofrqfTDUXANU
# DATA XdF/19OUS6BE38s5y9FmqbyFLnsJpOh3oynPyhLqtiAEKVBIxazhnlMEJi8BFv1gKO9EB8mpzRoXT7N6lwCKvksdkG7x6KV6Rl+X
# DATA ixTeoqR3wezkF33+ZnFx6KlpamNx/hkQnKPvjr46/vXRd8f/ePS1d/wFEDX09Wu6/M3xbxfJOP/CqJt/ZahN/u6jPzIlx6OffnX0
# DATA u6Ovj/9BhfJfwcWha98f/y2eoFf9ln75M73wj97x3+VIOxZMx6FxngOyMIPZjHatMLLg+QXSoyDbUIUL3Odu6wBQ7gNlUe2FrBj8
# DATA BA5nwQlPNSuRIaM8iIIhuDdcT8B5Nwz6/BaHv8nNMbm9XzX9xiqMy0PfSNKybpHrTp/nYfO3YuQwN/JULxkcTgeji8Td8CZbmvYM
# DATA UON7PCMAco+3YuJ2h705scQunHeDSW7cwRyT65n2WGOniJoOc/8yDJKRWprKJp9RKq7ohT3Uop/Otq3MJai0qBfDtI5MFzi4F/A3
# DATA 6+vfauMja0fPCnuzPuaOeOMG7VMM2hpsc7qx+uXwBV/NOH2Rw/RGo/Tmg/Tlj9FS/UyizYB8dW3hMkg1Jj1CSE7nE6L3X2SbGNie
# DATA GMQjDYOxykRmujSgYbALepxQpqAbIkWqGMvdeJYImyIbX3XC5Sg7vQR5xcFvxq1RU/zcGBwY57oevc24ndKNvdkw1FsieQkLXkUv
# DATA nYTdKEwLJv4Zu1g5WoeRuF5D6myDfjg9zLkCVToYp8uYaEYBdyVR+QQ5QI0D1DhAzcUDak4eODaac2xiv16N/X0W8/u81reD0TgY
# DATA jYPROBiNg9E4GI2D0TgYjYPROBiNg9E4GI2D0TgYjYPROBiNg9E4GI2D0TgYjYPROBiNg9E4GI2D0TgYjYPROBjN9YHRVGthtXdW
# DATA GI3frz9XMBqz3HxaEk210vKqtfKA8TOVmufXqm9X65V8dnT7rXJ9kX9SowRUa82f+ZXqPP+kVu/WWsv4J1xK+WCq7bZXqVX+k9+u
# DATA eJVKmf40vbb/qV9veS3Pb1Y8v+7Tu6pepV39tOI3in6VyhDEnFrRb9AtRfpGN9XoJp8eqP2nSpserXhVCqHa+tSHF7nm1eieaiOX
# DATA rlrYajfKi4AYiVCRTPii77dGfo3yBS9qlIHnmUtrt91rB91laVXoGSrFiMwPxa6plesZu6bWLlsVuCZfDpfU5l43bHT7Z2DHcEU2
# DATA 7BhuExY7plZpBvXqieyYTr/Xb+TYMRSfVrdjsWOqjTYHJOwY6iTaQWixY+r1TrV26eyYIbWCE+ExcBp9nt1qKC8Wx0WlbtGxx869
# DATA Cv3b+pFtbjfZfMiCPBlJY/NmeLOd7C1eFgvjuiotWT8lC8vDUqXXkD+50Dxl0RigDI+ipvfPkWukiOdSTGHCMvLq8se4RiXZLRhX
# DATA tj/Ht9Z4VBBNyjCf/qh/tYXJ1isPiCtpNRuUZT7r8nPspRmxMiAHtXFQGwe1cVAbB7VxUBsHtXFQGwe1cVAbB7VxUJuXDGqjDUIt
# DATA 7bO189q60YzhN7rX51MX6rEC+sClXaunUmZVqt07ke69dtkk3rmNdv7h1r1MzQuHVSw5lzHlsNJ0wfQ1z6wxJx/cuWF3btg6+eJO
# DATA D7vTwyedHl6pNXkpp4pfR82F0lwWuDlZ/Ez1Jy5ALx1ac3jzQRg+4ROO0mbPqDWXjS0XpzYXhkOlyt2RVRLKEK0+qBzdlyA7p88b
# DATA K3DbhEq1l0B7zqM5Ujg8vATNuXfGONQ8lR42VUrZsJf7mUD1JYjPPWbXl0ojmSCqN6c6QWNHEerXvUvQnXsoR4nhAyRTTiXZwAUu
# DATA pVxZe+59nLUOjAAdWp6McDBZyLzEXqhZEl6w+pzywBjp+EyTMacMkB1u1Qkxp2Ypw9AFTHM9iCVRn4nCiwQ8JFTnDutzb1TK1DV7
# DATA yaHO6AzVEAwPwC0chSwhj1uwUEWGxnBY8t6N+qY5FIB7GC62RaWiOkZUEm9APyYhFqyGh/Ikdy8HQSrR0UQhpVbLdVBU3tHY4M0V
# DATA 7WqaVGCJfV8FQK2Doin1ZQDfYKJOxEMnkx7t05CySjJA54o+7k/d5Bgn33mbAY0nLAVAI/W8xM/cSPUwxHFAdYpbJq1yh4w7J8vG
# DATA P+cnjx1y0tnvmf3uLPYXzmI/LVLyGeoA8WK+WYhez5F8M2L5cwVHgej52OO9vGsgklcsH3Tt5TQugw+ZiRxdNBzSloM6KxnS2qSg
# DATA p00PcazKVAeZ+LFwihKeqswVJHY1SCmq3Y0gNr6eyMOgAWALnYY23vWGs1E0jmc0RTQ20ZgqeQwRm0k4HELaHWPoQCmuk/01Lnk/
# DATA 6YjcPhkm2HQNLaUBmaQKc8A8G/12OxpvwUDjuzgxOhbvwy6iICh2VHmp1lhmF5t8fH4k5G0Ihym01IOUJdSlhWiN5xEkrJN172c3
# DATA tJd791vSglIyL1Neii5578XpVNt/Ii7E7B8d69vIIGlfYC9B+Yb6a9gGELanboSqOsuGzMfkRReJsXoGZ6s5W80eGZyz9eV1tq5m
# DATA Tj5LCcf3eLFS12clwMZHry0oJaT1GI6wD+02aT+Z86bAbgQGTLITTTsOS96DTAwQp3BEpc2gfbgM2WkQWPqB7NNk30E/6nopTfe7
# DATA xrPS4a1kmWagaC5uqAHJKRbHR9b4Za0PMRkHSaJ5Qny4BO+B12eJkajOOC7SLtU6Nyopf1J+MuXJ0j9mQERzhXMc2JGQw5Gnlfsp
# DATA Hg6tFCwlQJrFc64m8vlV2RKgXm7dYTpK+6lXY+4wM/cdVp8xYg6Hemk0gj80Vtbc/O1kN3Crig9W37PHZg8js/jT6js7bKexRnYi
# DATA Voq+86akKssHGY+1t1BWoG0/H4aGNa7CtTaj5fkMkp5xwvOCv7jjVQ5aOTAHkuKdwab1y1I6V6Fkxjlx1yRgPsaSlxM22O5BxDFK
# DATA IGSKep+ZrbDXikqTsyASo0XMzLQGKQ1jo7gXsh9/CnsWhp+24ASlZDsT4YA0Up0hCw1pI3vq/YIG3JLtX93Ql+qZbXJsaeSTYrJG
# DATA S5gB8Irlbm5E9IzldJ23ZU9VPFnlO2UJPVpdQroaSyE9mrAPNl9C1Iy5IxGPO7Av0MockP0jbtDAk7qurH6LHWjWQPC8rIKI1GoM
# DATA 9VFMOVC62MGorJTzl42dgutfMA82LZgHQTJkUdlgONIF8yjuM4x1TKMaa6YeYJJHI+hefm5W8u7uxxFmxpT3xq1fsF3fXCoT6l8w
# DATA OeupWSKmh+cuDzviV1YeWd97yvL4q9XloXtxKY+/IoNloSObdbuzIavJYhFQnSRUjUNPVhVLj3opXknAeWwaMkre29S6DgtUhGSG
# DATA xNFQVI5H3IvFo5HIP5NxMRKWGP0UIQfNevH5CypL0fUvpoebFtPDWacz35+9ziLWqjcLx5/Eh1kPpsW4St4HEU13ezPq6PdkKcrI
# DATA J+tVoczCA1Ob8qobzISOd+6ysKN9/TuxNzftxF6Pkh7vGBjDAUSNY2w1noEoXg9mo6hXxEIhS4yr8uBRJ2XDHtJCU1jmHwSaS52t
# DATA 89u8PZSw6e0oJDKe1LYJaCHDPXTuclpM0JlKK2//yTZG2/4zVyTv77wf6w2HWoNbTH6xuHnpn6GWAc1YkB26lNXC6eUw0Z5rj1fG
# DATA QksHcZhDof1fR/96/OXR745/A1YZMGb0+VdHXx/929F39PfvGI/2R49hZ98c/en4N4tgtH9mjNpXR3+iZ3/v0V8c4NE3BQrx6A/0
# DATA jdFn9L/vj742L7FJanTTn4++xifFUfs3UNHwfnnv90f/fvyPjor2HEC5zTYH3vIaTw80dtWQuSFeLOTVAs+MeJtVCBNPswAADYU7
# DATA gWVkqAMQOAM60AnoBoroSvU4mfKeMTzXlyUs4xSAp2MtOQ3K8mgKYuc7fJrt6+Mu4qrpafMFcnkINRotgmG8lyG+eIchv3yew32z
# DATA H2Xd9JvR1MJ3XBxDDaa0OreBGhrLCM7Z4PBpJ5fWhfPT3hMMuNch4wI7umjeP6Bxx0wvC9rISmMchkJGwpBFMtHdqT2tmN8o0vhT
# DATA qKSEWefEOl8FsqlkOTIJ2bPIhFl9TGBERSR4DQxW0wW22vp6udqImWtlzwqwtj76DrDmxv8LHv81hO0Mw/5Lsbx3NUP+hY/4Gw34
# DATA pxjvL3+4l4qYT7oZ5a9X87kMbls+4TxIcoYY6JhJdecQIRXkDGMyk1dJXKcCdEpHARa+zNKbJ/1SJ0zh0goTLE1yommgzo4tqOj1
# DATA or5hu1GyDz1FMtmQ2ZYoc4231eDIChkU7JcIu08wNik0Gdcx4V7xqWHeCSS0uSjlPVTpVGhcvDQbplMxFZAvmeVwW1HMQM+aziiE
# DATA UTCe9fE5sY0E5XmFn4BtmuSwGI8dss0h2xyy7RKRbRuMLhtNdDYxia/Qrj+LWX9eq96B2xy4zYHbHLjNgdscuM2B2xy4zYHbHLjN
# DATA gdscuM2B2xy4zYHbHLjNgdscuM2B2xy4zYHbHLjNgdscuM2B2xy4zYHbHLjt2oDb/Hq1Wy2fFdxW7zfC/nMEbsuvOZ+W3ka2qlet
# DATA tT5t1IvVhteqFv1qZUj/VCpeq+75Zfql6vkV+tQoVqrDRturN7x22as0P63W6KpXrXu1ytu+3/602CpWm17FL9bnsjRs9yu9zhz0
# DATA zG/WGtXaMuhZe7HkKmWvVq4P6s3KfrXxNn3Nv8CElaewVSgFlUbda/pFvzUq1ppereU1y0W/SV9qXq3hNVr0ZeOI+dWFmNV9QOKa
# DATA nxarVKhF5EXjPQoAsR1W6UKOFsc7OfMvC/vNxgrMnarA3SjhE3ZPpdJXMvSb32SQHKsaNPItwARLAcCw8eTpMrLWk4dbrXy17/f5
# DATA u+5/WQ6VxV+rLao3FMYpsXHcjDQ2TlqkhY0L661avZ7HxtFNtUojh42bA8kJNq7da2fYuFq3Ua83M2xcr9vt9DNsXLtXbZfDS8fG
# DATA of2djI2raqNATAL9zAp+HJI551+s/8ir0Z8q/WnUf2QHMceLe2dEU4lpAVuBEV/vfVbsoK92zO1pUr1cvj3vzBN3T6G1f1DgVbIV
# DATA K2IqGoBXTT7bdKmgVLPywqsm+WA8vZ8iZ5CY+RJ2VWsXn/Zy5pl2KpMq9Meva5OffUXRlCysbg5kp33Y1C9XFvBz5dV8OZP7BTsH
# DATA 1pgiJySQrQTHkXMcOceRcxw5x5FzHDnHkXMcOceRcxw5x5FzHLmXjCOnLI58BxCNKfxd2Hsfbkmbo4TfkO9QhOFsYBPzw63HQQIV
# DATA Wn7Ek5vRvG7wBaoWb2Iz3ba/c4NyozsqfUj/je9ap8Tv/zR/DI8ffi+YDko8Q9/mcH7sl+oIITvet+TQeKZ8Cyku0+1r1Fx2bMUd
# DATA onaHqDc5RG0fbXJnqd1Z6jV6yc/2jLUcDS7os75LTlo/NOcCpY4U8spq5lCvHFhVgix8lhh29IHSYZaTvCGr7GeHJyfBISbTcngS
# DATA Witj6+TkxhrIb4rqcUcYUT0QqPDqwHTo6Aic7vEmusfdIJ0FSjYNn1bfiS6Vsha3fiAfV99LHWwvjjmjfyIfnwcF5CwvTimCeG+1
# DATA CKLOVRFBJKMsOexBhygY7wdppoCIk5PUvKAg3o3ZbTKbTHDuGRsNcBjNS0QWMgWeQw6zsxeMmlpY8qhVRzg6PKejw+NhLzkseGGQ
# DATA HnJDOb/u4Vwarkyi0qp/F6cYamqy0qmG7ZDMYEZmZdOdpQOquSGL5OIMuhyhDkSums2czIiAVQm7RDAMKKgBuHfoIjJlaqXnwMfD
# DATA Z6gf8Jd2NPPkXOrUWQKeg4L5YOOCeUhVvQi3yiE0wC3lUD7YXKASmYTcerjZ6AbCIBkUHPVHaDhaNxTnCKFYBcXwcMK2ITLcUtMQ
# DATA wQGsbcn4Fg0H8YylR8+v75pLypWV0pk7t3c37dzei7BzBhoes8RSRqYJCs35sCtwGk900+lHyQjipLOJpwomTliCjX8V9ZIDSlQS
# DATA d6S7S0J8Zd2w2XhARhXUDWwZj/MUSS7mV1Yi1iB5yiJ5vLpIzHArZfI4CaKh6KUEZNaYQqHvUxgnsN9iyeEeTXtg5KFqGhpmEqjm
# DATA oDSrARPWSjOZkkQm9iYiLMNDUXs7d8Hko3/928qjTdvKBzInpQlqNKEqbAoGtRuWM03dZYsQDGsexnk6ClWPScrjPab54NFiY65C
# DATA ZqWiGa5Ewqcsao3Shef03EUxF+OXV+v4RZAT0Y8775bzbm3i3bKrmPNuOe/Wxl6slU6wy/FusfCWAeAF3l4ciyie9m1dW/3adb4v
# DATA HGnwbA/YglNL6KbYMKL2IetrOW+TWp5hNNMY++95oqoWSre7ox3l9tINUyalKEUJ1TxvurLsinH9VHh3bYKeG73YKGIDqcLbqkcB
# DATA b3nVG3nDCW+9LvmrHWS8goRaHqtynRjVsryfTN1oYqYfXHBN+YrQC7und8vzve5otR/LL9XZgUCBRWFCd5fqufsXfFnKwjKOQtl0
# DATA Q0Hc1/KFc72sZSah/CgKfLhIp0p2X9mmS3ZJmngk5tmExsOpbEi/KUGc0wASIwWDkdXebDXLx4m4X4UYi35gQSV6yHqNY+2lLciM
# DATA gW049ooEe0Eku66wJV4wUjR7KHkGcpfV05LHhVbgwc8CsrB4ZRYk9CpTbR3jdbCmJtFYMFYIkyxiI0GIBUVWUMOhMUg6dg6leYow
# DATA XwAFSnsVMZ3tgV/LOwWyNUw1bR1rCUrWq8xkJ2dsoR56ZruA3hM3YRtG42WR1S+84ZkNNc70dKbnJqanszVfXFtzpXV4DdWq+USH
# DATA OV2waIYNLTP0LZidHCtQyJNQlglTbYVmD7HsEne+10/d+vpLvvLfck7nzqvUg843LH0sEOGaI1wtOeFnnVmUC8GQv82LcM8f15Nm
# DATA 2o0xWZB3HY67Yn4b/as7P1k47cc7+KgQF8TNraf4C6dlA2Hx7NiKtsfm4OAHwSFPX6DnbAyze7xkJ5OjsVkUhD9xj0KaHMryosyd
# DATA QCOcBPs8dyl5D3k5a6otKHWPss9QK+EyFmccGzzza10B1sPJStO0jo0qwXxluv90MkSoafQUW9dlGVKq95XDPa7ceMowZVSh9sPh
# DATA 3oy6CxtW9i/HXx7/mrFkIIh9w5//BHQZY8N+D6IYfjn+cpFS9r+bH3919O3RN0CR/Ttf+P3xl0d/wqWCd/SHo68YRfZrfMcN/Lrj
# DATA v6c/AJH9jl4HkNk39PNXjDL7lgL4Dr8df0HBfAtY2fEXHoXxFV34e1wEGs2xy54L6xBp46kX/CEsV65r7y0QSYPkCVb5gnFYgNuD
# DATA ZqUJzx0ngUx/MMjQDBVHpXkNCXoZ3mzMgbE2+SwaMhuVWnTAuzlpYhlMBZIaYqs+dWZrqWUCkw5loHTQMttWtDqMq0aXzZXK5ZHL
# DATA epGcw0zNnW+oK1xRF+hlGPfMnVTppCYmFwwv43l+lPIGBDQH3hmmo+oIZpuV2oVTzHRn04/4uWAoTqW0Owh7M9kmMhR2PCQ/GOTM
# DATA vZjHaq+eXy+OojFs7WBIlRv7SG5rTy+jM8QKS0IKWEAK0RhdsJiByjKSNjk0+OZNq+ZqEyff1J4Vvmxt5B29zFkAF2YBaG7Z6Qf+
# DATA l8JBdJWD/kWP+RsN+acc8S99wJf6mEu8TS+7Fs3nMrhluRR7oczRU/FIMYXbi/v5fXucDdMBxXKP103Q6CLs0zSWESOORsGEEy6v
# DATA RR8l5waodoK6hKUWjUyS/Zo84kq994w4W7ohtoxzTlUKj7JjhtfJgA8giLjLDrRhQEWQIpZeDwd+8PIn4/hATkf01OZSYKMmIRf1
# DATA IJ4lYH8xgyrqRENkFaw7Bq3QeMS4KRgLooHAeC5zhkCBnMbxcviU45g5jpnjmF0ix2zDkWajKc8G9vHVmfhnsfDPaeA7kJkDmTmQ
# DATA mQOZOZCZA5k5kJkDmTmQmQOZOZCZA5k5kJkDmTmQmQOZOZCZA5k5kJkDmTmQmQOZOZCZA5k5kJkDmTmQmQOZXRuQWaVVqzcrZwWZ
# DATA 9ftBv/wcgcxyK86n5Zg1KE/KtUGj0dqvtmtvN+YRZJWw0e0v5mTZp6ysDeqtJn+uAjKmPtcoY/lzq+X5lMPVWnnkt8pF+ld99vXn
# DATA OagX5XyvX1kG9aq0FqJQqVMUypVP/WbZ830g2LyKX576cBu3TsKHNetBs7v0TfXGAg7Nb9bBJfOqlWK75vmNGiBofp0yzq8y+a3W
# DATA PuF13Wqjs5xWZkHUipgOBBDolxrttZeAzCguGciMImVAZoJjy1pArdpvVjbO38aSV1XKzexVVd+/xFdVhcgmr6o0mpf4qnrFTlWr
# DATA fImvajCKTqeqesEZeCqoHHdpGionvaMFlatVGtVWLw+Vm0fILYXKhX7Y7NUzqFy91whbVQOV6za6YdeCylXpva3GpUPlZHdhUZYZ
# DATA 9DBX5RmEp1enjO3SEvPPfmYeCvdWSJ15FBQW6W+1ZfQ3+D+b+weFhvg/VcijYDPIW6m5zq2pp2dZoPMLJLZ5r8tnwbOpSiYXDotb
# DATA rHB9/WWnRR1YL+/0Op0d5rG7FktVq8FwVlatsecW4pyfFl2idegYc44x5xhzjjHnGHOOMecYc44x5xhzjjHnGHOOMfeSMeZQF6Ip
# DATA zfCTAFrsVMFuG+zc7p3PzJxkku5yPZFeis8v4+pHVsuXhr97xzT7qL/9A35UNdydzxSXTisXQQxVznwx4mjCXbUYl7c/l1f3ZrL2
# DATA vGsH9GPB3eFShsBjLp0s6dj3Fv2dH/v1G34d0dGh3ZEAOjOaL6JQTcxYbpYVaMdh2EvBu9PPAJInMgSp0V7qhwfSgUzkVJ6IfdEl
# DATA PsGYSw4yGqcYd7VZn+DFklWy+LTNE7qdkiw+bG8Hhf1CRIUQ3FCG9v7Oj7cjahrl1xrlW/5OoYxNX9zqsf60O9q9sz26s+vXauXX
# DATA Ptx6n6okH7HkUJFByvDhfOoPY5qzjm42yjs/qtR2aAbWYz2r7Urhw60y7ubH9DOjH9GNizfdzmqOZDlqwHbKsVZVB86jXY7fNlLP
# DATA qMH/+OKfkLHpbVy5sbusMLejV/OF+Jpfv1XWucmh3v58p/RJHI3pWQYXSqTVxxtLXtmPxlE6UKKofl0XJk7LisNFAIg/HUNlQnAA
# DATA eJ6hh9tzFaaoa8WOXS2o8XA9MtmyQ5G8zQVOJVHUswp6/rV1JiO3PDSeLJzPMA6SMaQOHWvlDC1uoUPWbEVd6cy8iwLX56FL06fo
# DATA Z6w4StiPdJj6IRpwEZbBNOqDaE4pwilFrFeKsI4pOr0Ipxdxar2IlTqll6Ij8WA2zRoA79rSmp4yshtRiesoY3QVOvZirIiMeyJW
# DATA zJxyPS5luvX6ftN5mQtG6L3cvqUWzJVw/Qo9ejXgsiL9FCfLmYdkhL231ch7kpK+CcZEKbuSKenXysuk9Ku2lH6zUra19P36ail9
# DATA y6BB9DniNDGhWRVXq7ycfu5mK9/sIBbU8jlmd6plbX+s1tWvcTxr9ZPvbHCYjSVhLmjv6wOMlG4+iHhHGcXCDELLoVvlF5UzGRMK
# DATA kwZOU77ctONjPhNy5fReNp7xUCgTkDvW5bkCuZjXPsS4yS3efmt29XJeKgcfPRpoE+omcm/O/5ThPbNyWUlHkJ5MYQKeXyTCu/Dv
# DATA idSNMla0JW8rZxiNmR5N6Cy7P9fJsxkE4Y/cLUqAl6owa89Acob1NBhuwGIOmkGwSoMmLzpjU8EW+V/LOWGSgbn5A0ZCvULBvi09
# DATA BNkQsBP5Bs+/uEXewnDzEjcvOWFekrM/3dTETU1OnnE8U4k7jPGo4DoSyJxhpnL3ppmICPCANZ9MW6PSC1IWuYLgFGuOGRGqgiin
# DATA jQJxXBohNC3WMD+5mEMvYJuNjf0WHq1tgAlf8wMRnguFMAtXKdo3JYYqdGqmNMzoouxJP50hmnv82yw9pDF3zEwvSqB0FgUFIZLp
# DATA kR5oGUjP3UX6RAc6GcTTeC8JJjxUT0IY0kreN0pYekySmB/2pgFjld+LE1HWVWPdPNxUEMmW5SepFXPEwqFxR4a+7UBhkLFNUHVs
# DATA 4rvH6tQBUOTQh7sr/DTBSgwCGy8KDzkIAyy1Bt/euthHPbbq1kZ+3niUFBikgECEU0MQhor/1ICeuywIp/AXWpM4U9YTlm1ee08V
# DATA SwddtvAJrF47kPq7Jk13scN+HIPcOp8sMRPy3NgFVUVTkcksfAD3vnoz8pXMtgEIvgrZIFnAPwDYi8hjLbnLsm0wagqoRGNJCph3
# DATA 8N7Gs1Tlhwo4ony4ux9HPZakZpU2ABQkS2mAipkYO4LU2oRPuvHulOVTeo71XwtNRDnAZVKm44wF9ZxwddyXWRh06EajuCeNG4XH
# DATA l01ZefrwXNzvw6euy05rWEsZFrzJrEMWivUc689xIwx6sIC8hOuwVFYauxhezK/0QGKnQYcs7ZTa5LokPgIaXMG9phhErCSCUCYv
# DATA pJ4hgrYXdXeU1gk9358Nh4eKt6Jiym6clCuqpHuUIxWysqD0CQeDWKkjUgeJnaBUxMkA7VAKDH38PKJWDNMXz552tDBnS2+sBu1M
# DATA 5xfadD4tK+wZq0Pbe/7Xw8IeYyTQsEs2qqS+r6eFXR816edCUvUkgkS271+zvC4SKpZXyL5opti84vhSpJhyv7GaNwqVd6GRESQ1
# DATA IhWzJh7a7tBwojuxO++zdolwxWiqwvrEMmmi99HvuOfNKLOc0XtAMnsMu1xoZFRvsntlZgKbVnanx7DwIkiRHaqbbsbDVc1T7GXY
# DATA uai+PLUIljkY12JC4Io1JOcF/XFYYCxDPElQo9PQNDNRcA7MdFW22ZBhP8JdZOfmvK1kc0O02NZCZ0ubp5CSUzMWJdcG7sI624Kt
# DATA 96JZeRnW7CDsKPFrm2r2vx19ffSvxeO/PfqeKWPfHH139Humi9Gn4785/uLoK5swdvwlriwCzv5vXD76HT38NSPKvvboy1d08Ru6
# DATA /B3IZEe/8/iePzDj7B/kvuPfKpDZVyCp0Qu+pH9/q0BmHJ+vEKfjvwMDjXlnvz/6nn6g+//o2GbPiy0rjRwNT4uv85KVIW9iHYjm
# DATA cKIuzpO3mIKbotUjjtTKfwqVRWbIi/co3mcvT5BkXiWLhIjmsRZl9vZ8NBzOzLZps47iqmlmSwrm8ohm4lNJF16urs/fLjsIzN0P
# DATA w5RGoK4M2FxIF4w2E/eS6PnDtSILf0wtcGCzjQrvwrlmdz1L7zybGZgawIvGENKZDZnC0TnE3zhNodxzoJ5IBMXOuffgp3S/aJoX
# DATA NKdC73cxEBO2f/YBL/bo4nCBZ7ZhzVxt4yw2u2dFN9swKY5z5qyBs1oDGmt2NiPgpXBqXaEBcBnj/0bD/+lG/ysc/KV+LuSEhTp7
# DATA Ji3oMshmC4lkuhllVboYLTDOZFnZo+qJmnpLQE8F7+3Hjx88KqiDpWplmEuG94wmZD/wyg4nAyM0nBIZTSlRZak9DzpP9Zi7Kd7M
# DATA VAWP8hrKYHkDACmLusCcZUZAHnA2ScIefCN5o8A2BgrcTNFZeDAwxl1lHrBVAA6VmIeCnOL4p/SajG7GTpX0MOWjlOqejuObOb6Z
# DATA 45tdKt9ss7Fmo4nPqQzkq7X4z2LwX5i977BnDnvmsGcOe+awZw575rBnDnvmsGcOe+awZw575rBnDnvmsGcOe+awZw575rBnDnvm
# DATA sGcOe+awZw575rBnDnvmsGcOe3Z9sGftWrvROCv2rNpv9jvPEfZsYf15I/QZZ67KPKaECW2rVskdFvMblXyuV4XlJNneymVcrxXW
# DATA w/4cvqnaqtcF1TWPb6pJFlvxkHdLPIR9lcWjOn9orZJFozaPrVvGC2tYvDC/3TIMqhwh7S9rvZbfrC7WnFaNqk5rIHXOSl7Q6LS7
# DATA wVJ+2rrkVYSUdknJq1g0r42TRw9dWPKqwvi6pORV1dOnSh49dK7kVSuVa9FIqtXW5TWSasM/RyOptsrnbiR28i68keSSd+pGguSd
# DATA t5HYybvwRpJL3qkbCZJ33kZS91vXopHUq7XLayQUi3M0knqzce5GYifvwhtJLnmnbiRI3nkbiZ28C28kueSdupEgeWdrJDawtdzy
# DATA avX6fq0xqLZr+8VaY1T02w2v1tivngRQXd0IzkLDZEvX0DDZaLZomNVOo9Kqn4WGWQ6Dvm/RMKuNsFUzNMxOt9vrdS0apl+Xny+X
# DATA hqk288rsznL2qGU3w8fkCTuZ6LZTrc1r7Eu2TeRCxfx18Z75rQqLS2YtXjIrtbBVRhbNcqGqBfO1ITd49Sz/mJ4FLt9smN1Ns8m9
# DATA JBjl1uhOSq56Zsny/OINeqV+Ic8X7868iKt2SMqLfCkicQUsBIKlhkXUp6p2+eWCdrsND8zp4J3sMVqSKnYbLvieF7cLreR+Olqn
# DATA o3U6WqejdTpap6N1Olqno3U6WqejdTpap6N1OlrnBdA6F9Gce1FHARSxOgfTU8ExNYOKrtz0y7VWvdm4nZuzqMf48DAe04hDMsxn
# DATA E1y54ePJSu22YmPeV8fYoR8wng6Gh4ZzxYhEignVqzexv3+7wljEt6LXBan4Ls6ZyynlyXCWehBs9tSL+FkVpVXP3/Uq9R+Zt2VC
# DATA OzIvpTzYDxnVuU1x+DHW+HeWhWSzDK1zpk4QxgnC5ARhFg8dO3UYpw5zdnWYlUrKl6kaoztryEFIe0FxsZIDNtrwzhtLQub66Jhd
# DATA BdBQhkoGfchAxiocfPUEkKB+MtfNpzlkG9wIS0GCvsUR5JvK+k6DE1xNEzTDOViC6jPCZsGSCQZFnQRv+6+j108CIlrBmaTY10xq
# DATA 6ienpXKKZIi1gR4AXlExCbbfOzm++jkTWXPBiulmmb5hTLUdxO0UQomQHMnsFuq6JlF4UnXJAsnAk9klE/XmSTFvrIn1Ssif6QL0
# DATA lInHQ1XIzz30bxnpz1iIoen90DNRHROWBzePnpHXgW3ARRqMeA7AyzMsCKPmml2aVLFaNENNsDeSpjcF72BAlY+Mw2QvtEJTudvv
# DATA U1/bmSXwbeA5mlwlIRSaoqkW+FH+apl5pCzLzUpMVKUOxUBmHUy7npW8e/GI3WLU9RWUWM+4Z/SfMtElNZnryRNBonSRMlsmg8yO
# DATA KF6zhH2rSnxoA2rgi6YU45gnbiKwYiLgbP6XwuY/LenkuihF2jsl1iNP3op4xBS1RF6PhkjcmFV7qG2NwrXsk2cnL/l8qaudpC49
# DATA t8fjMsAniwKaFw0/WaZDuhSAkis7vSVGKvIywN+bsOe1ibD0Dlb1XHvH62JaG0PjlHLfivzHuMqIBQcBEhGNz2AqZa7MzU1wmI+y
# DATA abfGK779+L13C969R48KahyW9sLDgtJyB8RS5kUitDiBSmiglVRZqZFKwch+Rmk2b9BgO27g0RTD9hqi4iPpDGTD23pY5F0rEqoS
# DATA 6xTdhRLoWMmjcuw4QZSwXgiaXzjuQhF0HFL8lB5rgWovVdeBXmYTeda8KutaNGe+Azkh6lpwVqxpHW0FU2SDWx0wDMWfITBSmP2i
# DATA fc8GdHKoJDFVLEveA82pQcx5dUx3ZIHXD6LhLFlHs3wowWDhahXP8iWywO3+2tngzgZfaoOrSuI88c4Tn7PuVhrv10e/nes0RuoM
# DATA 5xx44ik0Hnjx1UQpNu7FPEjmxce1C32efjabACdY8n6GPeKHBtFCd/RmXYjIjDAWG2lj429nojHbOxsLuWe6BdI88fXOq9rwe4Rj
# DATA 3tywoV+RKgC2zDhUX/DqTWMlTqX3nib4KMLceFVXnPVkbyQxjcHUsAdLb/ipjOl9UJtX3PIBTDakUrS4WWwat97EO2/q98tgNB8N
# DATA ZagqA85YPPym3p031OZErsEFD8NKn/r+mMqMsZ9U1aY9vlONEQVPBuOCltoG5w6Y4nQg4fZUtFbE471gTHWqZ9uCJjJ3Mwn8ud8l
# DATA CrbpZuwvKtEkhHg3Lx5oy+vkiPwsSqYzKKqzlLgVB1XAbOZxbWVJee5TknhoIvOTCSuqmBuokodTVkmf8OBJGTQc6qqeWvG5qQrq
# DATA pqp0K7j067Hfj7Sdl+W9mHxBb0SDvp7lZGwfrSSuSO3pIJ4Ne9wuxZwdw/LDxnNMrURdXQq45LF9SRbwMD4ccRBkn4NnHUAc3pKh
# DATA B4v+k7jDA6eSmJ+NmYWoQloHBB/HB0qvXJvOwXSgo/9BwnL2VO89FjcRZzevt2i/MTudyRqnYALtbUYvRZ0d34MfmJGa2bhAQgGy
# DATA qG/niRFI9WM42Gk4D8f63p5iPWZrg+sS8564olV6AhHPh1/duPeVZx0R0+sZGVdhEA4nqj+TBU+rL2IZfBoo4xxUYRIGT1DC0mOi
# DATA 7mHNsheO8AJ7hqXAChSKzAcZC49WYE/NlB1jg8/N+ifqZzTakCH+Ytn2n3/+0ecfjrde+YsX/T/K+nD4MTqMaDwDVHVyeOHvwNpl
# DATA o1b7C7VuPPevX67XK39Rzv77i7LvN8uNv/DKV5EBM7Q5ev1fvJz//fCHP3w4E0JElzqQqMfjDCrFVsp7kYuM/cgqiHfv3Xeo1+Bl
# DATA Tmrf8bDHS/j0QInCekWkUsi23ePDNvr7J2Qf6s9x+gqPXuj0h1HHU5cf0Fd9S2IeTGcd5Z/RV3AkC8OB/j4j0+WVVz54ePfBg/sP
# DATA sYF6a2vrFT5j84raYNmXfdXsbNqmyWQvvNVPt3Z4NyNOhmyBwXeTesWboPre7A4jmsFs3X5Ftlr30xLyAW6+R4fj7jYeKnhbNF9v
# DATA bVk7ULfYKVRE6MUst7Z2drR/qRQ+jabb/s7tV+b3feajxufIPlYP0RuodzwY85uzgMIucqvg/VxFZvm7Pyq84nneZ1M5RXLL5+0O
# DATA hVHw9PVZH3sf/Ua1VSs8ISvzUbQ3Doa3th6989Zfv/Puu1uFdNqL4ls/36LrNDxsFbYm0QT/qO8ffb6jskdtTA2ThIaeX/5Sb1RN
# DATA OUD7Ai+Wy8bX1Vkie4h3c6e19PM9jAXTWB2rUPmvo8EPvsYFdcgvwcEovP4HcnioFKWPgn74DtlFezikgNtLyK97WMnewZ1z17xX
# DATA vfKyy3f4tM3SNOgrKq4HMGS2VXzn30j3Z6e25oPyPn8FlfiVV2gKDTflx0w32o7G6YRG4Y+l0Hnyv3MLRYws4BV0XIINwB9KbE2k
# DATA mEJtbxW3dvDDMBxvy4OUkLpfwTU8mYQl7CfgbcTbydbP7xb/l6D4i3Kx/XHp5q3/qfjRja38C/FfEmAq9zMk7D6Kf3vrnfE+TvtY
# DATA PQk/s7XDz6iBeJdbei4xOzoRcgtXlm2q+dOPcVKXYlrzfuxhQ6/6Z30cOFwvfNolWzeViaSKAezNpIfeAP1RiXc/bKt3oup8jP3V
# DATA 2zs7uTxNKabTYNxFVeTHCx5OD5jsVFd3qNp5/ka5o6a6CmMaJip2+vqujufPyx/JD/pG7PmWm/hQ4tY7PSqWLfV4ON6Pkng8UnvD
# DATA 7ftoOteP9ujezz7fkSv3x/tyJMhO6nwlCIp9qgEffdaofU43m1js6EpjZY318rnssX7ZUY3nPJmE09BywIW/YrIunUY0tnMge8Vi
# DATA MfL9BRy95UhukZ2HpyUYvpDMX3haLs9d2t1Se1bkWva+5cn66TidTTBc0ezCiqZKFP7j054fU8qkp+Adg9v0moLn78wnZnlr/fgj
# DATA q9l+9GN6EqdWT4qZznC7+tBzVsw4y0s0PIbjnjqAatrrbLSNQsYtJZpsUPfG5/xQ9liHoOzhp1HylXpjg+Z734rGsib8l1hbgmPD
# DATA GymO1xtx9wlO1+Afqnz0YHLI06eCzJe7XB9xkgEFh05ZYHpk+pdUkNiBRX2vouXBlsGclul9apHottDP4JLSM3/4oFkyFNPFdBBg
# DATA /5U0V9P77VJkxyFfFEeWMl1Kj0PYLkFy+AYLC8bJIQvbRU93t+jF46A7w4FyM5Kj86apak/fnGUgldrHyorhXtXcsuPd9LbsmmYe
# DATA 0T7zGN1JnJZACNvW4RRw5Scff/DwJ++/+5+9X8q3ew/v332sv9z/n++9W/DKMZAeJkxOHf3c73Fo2SuoezqQyFNzC4NRvjbKNTVQ
# DATA oh2WPqGC21ZV5gY3zewlUzvhnNGKp7ZrWYklKrDtn+duw39bPa4l6C7lKXwqinsXH02ul7Jc38VhL1iXJfxVowFpED4tLAZdLKoq
# DATA waHr/uoWnjbf+G3GnJaX0zS72Eviye5dWFzLwk31Eg3Zp7vjmN5zUMTMNwJIJpVQqOSKKLkt7tFMQe4sDRCxpCqCJ7XNq0PRrQbf
# DATA YaboAR8/44sysPPBflSAs2A6S8KPZQvl7uNkpg5e649ife5WywVZN+XrO/mCtFqMKlRtRMFPNdnO377ZcKXDnOsBV7bQzbpJtsS8
# DATA iH1iU7uXFPtCWfTz9dGqfmyUSaYH02nQHdhx/Wix1Jb9t2me+2szXZ3MyxvYm+f3h73P/EJdLAO2oWF3jqfb6puyk2+dIm+tSaZE
# DATA aiF7WQ4ge4n5tY8tH8O57oGibTJ2MRpriigZSfnQMNYN88XjSTbtWk+/cf9n7//03XdPLDl6kmZJy57Myquui+tNCDjsqBkARqJt
# DATA VY15UoSeW8+wS3eTPfbqP+BfVNHJbTjL93Ggfqc5QFEZ3ZQmvffCqhirnmETfukTdBtsMfUg/4NHUxWJXIfN5za2s8kM7iup+BQ8
# DATA +cYTDGXNPgWG07vP/0CI1QT0l2rEv/nG6x5PO1NGg6qu1nZYl7yfYNAOPEb3eNi9NIaXsuvR+BRMyKiZM0QesXP/PmZhW+/H2Med
# DATA 1ciu8aF3+Ho/SkZhbwtlRBXt449hDnxM9tuut/Xxxyixjz/ekkhL8V1TV2KCU+yj8DLcfpv5/yq1cq3uz/n/4BV0/r+r+O8vf3Bz
# DATA liY3O9H4JpkO3uRwOojH1Vd++MMfsnCH8Gqx+CILY1hjwIovliviSaiht3oD10NtRnk82xoOqVtY4xXEMkWjpr9hT5P+PAhS+Ab1
# DATA 1wj6YInlBDy7P1FWEM3XwWwaDc03nkOYb+lwjRcySGwn5LxTcjpIhIBnLlAjy3ksOcqzZEgxlp5Tx5uu8eSPOhZePPFk9j6TvJYh
# DATA Mxs91bBAmXzX7uBgUtOcx+sccrmY0mBLHcsoSfhJqNb/kCEy60y5sPR7fzrZS4Je+DOoHegXL8bFjEuUNzJcYRfZNs2N0sxdJN3r
# DATA koTo29SjrN2DctTPyYhveWt4lsN3WB4bnnliV+gW76La2tHhycxiwr5SNe3HLp9dmb7IO6Y4DTPVEygOWk9v5adSlH6cHo6wSWbb
# DATA MiY5mVtH/+fR197RH46+Ovr3o2+Of3X8j0e/o89fH/3ZO/4b+vDHoz95x3939PXxF3TtD97xr46+Ofoz3fL90Z/odvzwq6Nvj788
# DATA /q/0Ez/9J3y95WHyAHNeYqDGRBUdOexYGsGS35YvqTL8eBL7cWybe7xeuqudJP1VjpCQ7A3J595sNEn1b+EYi5sfB2k3isQowT4z
# DATA DLC7FT1DE0dMr8AzYpZ0UrPc0RP0GRMztS1lc1uyJyj2u7kULTEaMKXsDqjIthE+im7lnBM30FwTUc5XBqzVH2BKucvTyY3mosi0
# DATA nWU/94czqM3kfkIcsBV5W99DaR/H2o2o7khCho1pYSopVtuvQ/dw/v2ADAiaheUjZ6b1H/d71qw9l31q6v7wDXvq/sY7D+/fe/yT
# DATA h/85H+WFqXQuHfbb8s8ttbPVs4yCX/LswjOSWDS0EtfXlDNlbppGd8zG3OT4R9WeZf1YOaGM6xseKKW6BjdTdYVTe/u1W5mD7KPc
# DATA t+JHn5ULDf9z6/ed1z4s7dxQFz76rFJoVDHXsV9t9QL//ehbau3/g9r0r9Ef/Bs18D9Ti//OO/pXbvhH/049wPf04/d0Ixr/VwW6
# DATA Rle+oGtfeUff4I4v6fM3xlXNPZ84A/9/9t69ua3ryhPtv/kpjp2kD0AB4EO0rECB3ZRE22xLFK9I2UkoNAokQBIRCCA4gCQ2jS4/
# DATA Jt3pG1d8k0rdmuqq7p7UvR9AUay24tjOV5C+wv0kd6/Xfh8AlB89NdPpGYs4Z5/9XHvttdfjt7oAeVKQSVCHkfZ6bMBpIZsV1GLW
# DATA VPK1zdNPcsV7KXiFZtWlJWA1PK+6AtjZS81BZ0m1ldbj87z8ynIwDf/Xs0+B0ymm9gh4neJ/NDw1UjUnyCHV+J/CO+B/v8TJ+ALm
# DATA S/189uWzLxUHfKL12ZDwPvM1oqXU0VmvJD+qsZ4Zixfh9+qs9YHePIXVeQoNQ/uPoZuP5u2+4ejE+p9/8vxD4OJ68VgPYGmpUcNC
# DATA WmrsqK3DGyEOD/4bXMDVOOkFE4Fj1dFr6O0ep8q9y9W6XZ3M1ild0m19bGwpX3gh/2Rd3wXPx9+Se3+3VL9QLKjNuGT2XqXxD2X1
# DATA dLG49HrKCt1ABU4VgqteD4CbjlBhrGb3LK3A5b1SSSfk5Wte4Sd7q3WhJDVrxRlD98dbdbY2EQ9Gd5QN7ST4HWzm57959kXJcADZ
# DATA 7bjzH6nCj6AiVUxxhmePgQcwf1CVy1z/+fnHisK+AvIEylW/P7FmlcAKYzuZxrpSh50s47anEL7s9JhQp0/CjL2AE/JntbXUkic4
# DATA qM9YtlE9fv6xEmrsHrOyiY0JgF5oczt6G2NzNKzzcbpzbX29rNOHy0MBrktqvhmcGEvDL7RZqSKwGZEweQXgK81ggZYVWcJzNHGo
# DATA YvhvrRZy6EN5yYWz8FD6PQ3j+UeRVfvy+UdqTpCM4Vj6FGnrY9q38fMLT6crzjtFxmrCntBEQtUByT7/OKES8FBTAi83dju22uom
# DATA Whj177V77vrmG6kVu7hbmf5bcQW7Sl+Cp55/BJxdjWx9e7NsNuMcBMEjKqTr29uN7Vu3d2sXl1eW7/Zub9zcWn93/Z2Nxvb61saN
# DATA xp3bN2qcqgaF4QfN++3qRcB26KXOLkzNl6ozjd1bb29soUECB0GS9+bW7sbtrfUbjb99d7exs3Ht9sYuFuE7bgWLNo7bDwsXQVh3
# DATA 67/b2719Z2e3sX371o9/Ulu527u5fvunV9e3Gjc23ly/9pPGjc2ttxsbW+tXb2xcryGeLBpjaLXgoupLYbEVQn08a4nhOsPwtSKg
# DATA 4eENakGWKtSvS6+8cvGVYIn+nXinYTZEms9/RRSmKFjVBS/pe3dRTAPSe3L6RZXdPKNgiXBPExMIi6tTpEFFUXAgqi6DkPC5Ipwv
# DATA Vb+fAM/54vknLAzym0eiT4kIftxfy4xXMFb4qitqnE1Cg7guPM0NAFdjr+7I52Dejpu20Ux9oCHophmrTff21Fd1BKzD73JZvriu
# DATA NtigVrDsZ4N2e5ipO8799nDYUVf4NDWqD0KKRE2HWGf74D3cOaDgAcSo0H6xwkOT/TY4CZPSA4UUUPnW/FkDx9Zw5raonZtgKdMC
# DATA KVUAJ7L6JnVvPNxv1KDpHy+FZYOT6zNksupcUpSjeM4TIvnfPPsdclZ4BLwWWPGnoHlQW0EJIFBpWUo//7XDqp3jGBeB+oBPef6y
# DATA cB54xDvtEZjJs8hkZERLTIm8maTC8FxOUGj8EuWaP0HnQHrwDpUveUDwj/rNtn4QM2EfqQ2v5At1wMFHqjo4rWDCnpglic87u27k
# DATA 922emeej4HPVl1/TucGdCIZFJ7C/ACyKSyeKQDkrwUWtBwquDiDr6oKKjwWXeE3UNa1ALMT5xl56fX13/er6zgacRmm9WJFvbcNL
# DATA 4e32KaroSkmgbPTa0xZUXnF5FT1o1VoBmf4ZVw5YNzLDJySAgIwGD40sTQuqJEvFOj9LnI4b2Yr7IX/q67K+eOAt0mKQwEtg/ZGn
# DATA ONsUnmjfKlwRbxfgY66CnkCwTdveDbfJZUSV62Q4IaCM8zwXyK5kDM9iUAZrWju/rS01PGv7wlhIoaSkabTew6gKVvn592yx0iG0
# DATA zsCIitObu2Nyh4QGwm4HIX7U7OOfsjQUZAVPsMPSe+rZOn0kB1PR01riZ6S1nMQaAwMmqOIK/rSh31ZarHTpig33P+mPe2ixrYH6
# DATA TU4VVv8wFYBUZQ1HPcfBpJvb61QBXETf7Pb3m93N7fuX5KHXazU4TcPqc5kxlu71Y+lSOPFM4QBHzkG7rGSExAPFIk6HkJetR8YL
# DATA DBSpjHtK6C4sSkVkCgA/LjjSeP+gfhiL27yLa0JFQr4yyOzi+GGFTPIDUoype8LnqCN/Gj0e8AWdAldEjnqMLPZjvN7ZHCIh/cQT
# DATA S6tmHQjOtpcZiR0SPAMvfkJDB9VU/Abk17zTIYe7WeeAdMvmtNztF2a0bmdVOSqgp+0J3AWtg6uSPPsdnbyPseu/xBd/4rF+xqv6
# DATA J1wJvL9cgxuGHtfWxu67t26/7clLsSmWlBx9Hi//ztCBssDFi+AfS4LjAYnQDfvE8wR7FoozPK6ClozMEtpHIOqqGHxBAnruR+gD
# DATA W10IPIPOJg731lrBiKgdeq5iaWJ9IR/gtf9tgvdwup4+0cZa273TUdnoWxRKUu/jnfdp8vbGT2rvrN+4syF6EvXA88bBm4DOcW1f
# DATA CkhfCXHymEMXLgZRhyJVw5RhRHv+JdrUPkVh6yvSSnyAF3XrcsW6WdLmwMXrT+kclxJ0Z5XRELtzXMPc+4rp6dQJ9q6p6s//k699
# DATA qC2lqbXWC596A1Bf/0JfvMVrXvXMtpNK3ISxny5M9X12PLT58u26r1s3WRByYRo/Qxb3T6IjCvgY8WMY01c0dDWoTyK3WrNtwVLW
# DATA yI6bq69cskfT6hxBxGJNvAAqXKRoPGktMzBawtLhfty0B5vs4HjcuwebDMXobvNkv9WsikUP8y1YsQXFUrKf+vp06lGF4pALWJ8z
# DATA Ln5/3H5If2lbDUWbNmAg6kg13rl8ee/3R6HnLlvNupSQhFjegORW1NmC4zKMBMy/eEYPwEINH6ifcIINjCVx5611NXM7d27uGK4L
# DATA WsaBY9SeIwqENGhUc9F0Brs5lwIEicbYxNF6goT+mPYoEZTaCPqwJlMsDHfJHgdEPJCfsEM+xQtpkqQXqIcX0Knf66WsyX1EHGjQ
# DATA 0ph5L9Ep0gPbdkoRcLOXCZ3ARZDS94th/wGKgkHfbaeFIqlN0NnZlrpzTSVqHZrlQ/RvLSZJwVudIrjo9R/kG0rEDIBiPHQ7KtHk
# DATA rpwwqa8sGQaPC1YbP/8FnCAfKa71hcVuMfFiDWdwKWaHQCtwjBTlBZO1ehowCyBwsXNEx/Ivfi9ZQqNegqJ/GhXmqVes0eE0ooAt
# DATA YxOuwMBW6rw3HuEVirWugJcFewKP2v5DcefO9BOWbZyCWlrRJItqJ6JaW+qgfmAXU1GAoYeHGFm7TiXofAAqLX9H3+nd60FEvoZ2
# DATA 5S9SL4CIx/2jmk9iFnmhql0Ww10BeCQrQGe5rzTBSZOTjvZXOI/F+PTgyDgOHz7Bu6E1lPzhbyGkCbziDtA8pO5yy/mQSgL4MuSH
# DATA GBY6xDA7yL0BkQFjZrCiPVleRJFL68VivEpruB6FFM19LfolHgWiKIAe7NlhITxtQGeHHdWzIbrpctV1ivCEVpHti7uGCZDjLvEY
# DATA uFvOSuhv8qhyyrcWS+x1DkkksCZini/92QAdxx5nCknJEIepZ/ASQo3sUWIRGj2VxzG0W2nd4a7yAdEREAeqgm73KUegL0O4w8ZY
# DATA XSSB8pA/8Gh3vg31//KByiz5vynO9UclFKur8vN/NFyMVJWKmeNdWUln6joKomnAx5EHag5JorN7xRo4p6BrAmFujwelGyhms/Tm
# DATA ftbvQs40a4L4S13vEjxYmOuQUBJ5v3sfswFljWG72xx17rcbo74dCwWCgFMWTaphOJUj0pe1tDJFnv8VC8TG34+E+MdgYcWZRUUG
# DATA WO/xMv7sj3Du0K3lEc73Y8uMKIOVTYPMKjwOZ3cYj65PVN3qto53/A+AneZ32BXT3blaYArotcejYRPAIogSRCOh5FqNFwNIQTD/
# DATA xjYDiIFHPQjjpVxJ3eZpe5glkK01aR6OAKu838MksegWeoUBWSjQnBBVdEPaUhNzsDH8TU5M+a5y2jzp2kepeUHPKfSjnPtd7nv1
# DATA uh4SsUHPWUq0Xt3fCLlLHHE1jepXuTV3X1oLYa6BFmWhLhFXaEbtgYcgrz6Ge6iOeiHaij9ddmO0cVzmPgob7iwVhKS0mpxNjCZE
# DATA bA63dqaZHNxeoDOqP7P8OleyfYQS7VPcnSDVald20fmhtAHb5BfsKPIFqBkeayMPGyge5/BbsrTR9f1T1LmR2hJ58RNHEeF6wpjF
# DATA itlFGZhIdl5wj2SpLH5FsQ5PKjft5Fxwbg58vsWOcOxk8r2EkWsJe4nBhDq9Mjq76ull/C51n79PQEn9bksjMyE5Lfhn6iyf6+gl
# DATA BYR6VDv8N1AoP/9QOlAO7pYUYS/yhLTKHtNm//KMYiGZvIi4uZfqOQd7muGcPCpqzSkFsibIhqYx1yvCIAtoeQT9Iy5enH82nGMn
# DATA fy5E1WDxUpGJvB6YprXTfC77IckJHttik1ESOsq1UNKqzhGBKGSsxW30N0GoCkfMy1eWznDUyJ0y7aUsaNN6b7kt+4OQ8lFpxn4Z
# DATA v/ZKCbypUEv0xp+v81yCw0HOcfN111L3HLUbmGNJnQ2I1d0uSEyGFazZNXgCbELS6mNZO1D9w3XItjad4Ql2yMJcKWkAYIKodyY4
# DATA KVAsRyf1OzXiP6Dpg4xGj8RNNQnFp8ehNkqSfrrEqzf3HJcAjOwkK62QCwTp594E7N1hvo2Sjvs6TjymDM6UbO2wy1FlyrYZvnUN
# DATA lg5TQKSE9uAnbQLTJqjs8YmtE7JnElmr1TXXGC8FZ7HO+XvMPj8AYthUM3esRE1Tj93JYeekiT7U+QKW1T0u7t0QpRK2JE6n3xeY
# DATA dcAvbPaSMStn5LhFput6CQhDt/tM+Xn85XbDoWgz0jN7cPkBUkB2bqAS/2PuXi85MnJc93zXChaydogO8r+I/nduQ6SbNu2LFnzr
# DATA 1vWNxs7u+u6GjofZ3NjBHctMFCGA4ITlzphxoZI9j7nOWB7KzeSm+02NljjgfGIORXpw7NPaRuWbL62wMA6XOelkAEjtBoGRqi+L
# DATA Gxj5e30h8fgGxyrBRHr2GO6VAL/o4DvbDhJOHan1o4Ov4Qz8dbLcf/XVV82NWM+yHQR+u01IEYwO3L7f6Y+zZPPm+psbpWScUfID
# DATA 8Ad80LZSQvdGrPtTm2UAiJdWjYRml/x83B81k58pkoCDHRfyAcZ+D9tqasdtjDDvIDIRZOhq8S0WwzLGAxNSzrGHxAJK3s5Dd8K6
# DATA u0flfuaWtLWD7mTiTXr+G6AcpPiVWkzuWd4CYblScGfTPrTdZq9B4JGgV26wNF+goZVoliGu/+C4g6neLVdOxhVhhtCqAUmL4oB/
# DATA WCrKBlWJL2y1At0eTD4J8aDSEa5qGwIVWKzmQQew2HBNHzSHLaNPANtvvkqY1OoYbMLDmVYuEDx+iy4YtsLnz2QdpUixR2LkTVBK
# DATA e6Iunx+RZ4ynJUI/EaMe/3WOT6Fn8eXJFrQrByYuhgan+DAldAYmnL0H0Ffv3f1+BP7N9p53nEtItQj9evrsM7JigxJKSdRoSPoo
# DATA MhV8YYGLN0aQxIZ2n+KQMae7Xip+mDt6fu+OP+alfqHwevVuhf4snq2UKNiPvp5n0OL+Sc5IH6D5Ij5UMjOF4xPaapiBuuQWjDX4
# DATA gv0N3SMinBT/uxecHb+a4rwGRTLz2DPlOv1GpG/GJ0GnNTLgs8dMoniuknYL4NGg7vGDAgJ/OW7pFXUkQRzU3nI9WUzWinvVNU9M
# DATA g4qDWYE9QW+mju/37BUB1+xHSMK83BxvpEcGeqNPSZvEAwffj2kWyCuktwdO8R+aYyiS+gVtJscL+VNW7D+l+HPS+AplGbznzN0+
# DATA 9hsurI7AhveBS4aRbySTjl+Un6/bX5SCFow1yadTq5Dls4L5BeweMidz6mT8IfXOde3snfqtsLPklB1ggoJdmztA7Bl/CO2q6XTD
# DATA ax8Nf2pqnEL65up/6m9cf+bMpJxjkHZfg6Xwq/IRMGlBrcWYvy3+VrsdwTTIMz0DVqFwSJYfckClsZbO4ZfieDdQrPY/og7xA4rN
# DATA 9PhTYMB5ouMJfc5F+ROgv5iEw9l+8GSHxCuAI3Y3j/OSbN8siZHTmpKJqKAW0NC722hSOz2ZLX+32O90peq57mXOLAfz+W9qfmgK
# DATA tPfrnzGw8A9BJMdXyJI+wv9++OwxyzjnncvBAL0q9iihCfum12qm5+i4F9i8mSKcSHagP6rQkB//1oRtUVwutfE3wdz8DzWkP2Bw
# DATA 5aPnv37+z8y8ZX4kpCGqdfsLxbWoClhqANfpD5FiP1I1PQnFqM91zAvjudRyosbYxX57mwMGLQBZFhQuror+mapCtfPa8g8vyawc
# DATA HBPdYDvkX0d2t7uInnYXvVYQMrUezspvnRHnEEVUm/0UTz50RsQH1hjy9PbsYjFFOa9137mXKPaOdOLqoq4b9SgsASkjUXO/anM+
# DATA dkmbobP8VytK1xexZV6+ZDp7P9BjBqxLVJlatyXo/zx2eu4MHztWCm5HWXsDnHy3ETGyWNTWf5TPQBQDp+kKYBzda59mhb1Froeb
# DATA qNufVNoPR6AKns++LL58tvrds17oizTUXg3czeY2rs9xcISq43igne6p6L3PyDSCbqhk/QOPMFLmVyO+bkHntYeysHxI544T4dif
# DATA 04riA6mZG0nHRGE3/iUbKJT+KsbOFu1q5PrXmn1BpelTQSIlnGl3VsVfmeR0LE5Kyyke+DRi43Y/F8DzeSw/uKAaUDfXxotYLdFF
# DATA nuICozuLq2RbfW0HF+MZQ4N1VtJoc2xPrTjlu7uPGi1+uzvB7AAlQ0FQi/EBz5svx+Ps29oXin+wKybgy1Va7fYA/mBFleUpaAQq
# DATA ONnTknB5jhYH7fBLteBhnitOjn/AJ+Ik/yWa1eBwR2SKBGKl1Jz9EZxxMFzUhIg//0iOdhsjwRIGI04wcalNNn9NZmXPbPA6jt2A
# DATA VsS3FhcPgmLcABRbVPlCmyXyTntH3M6jlfbhYRsVhKrzBdEczmJX84xIVzxtTPn6HvjxJxkPynnahzV39c3d4lHecBGYGtZWd48G
# DATA SM+dOOswBIkKBTFITr0w1kIket9l6FzcQwRwppOKUO86fWO1qfBagFGzTaG0qU3AZUg3mMaDTWs1vKLkMu9zXDtQRfIFRaQAsZlo
# DATA J45U45CbGKiHBRUc7jthWC59RX2phm1F/x0QQIF4vRXlDBkSUcqL8Te4GHvL9cpQoxXhk/KKxi+qShl7Oay2EA1J/RodDQksXP7+
# DATA OUOetzr4WK0pAP4D7reSUR6io1yz1cInSiBrH3bupVHr5LN/z925sNl/qagfBNN/wlgttT6fUxSoaKgS2kFPYaPgFsEANCiHYFrv
# DATA owflr+0700fWwvA67PEEQiQX/uUXqAz6g0K6P+50IVkGGhEsm8/ucSdjFgI4IWBC6CNcHbg4YQIA7eIBr4eDfpdM3HBiiqxg1TeE
# DATA nKftHtAHgQ+zDQpyB/RUjwBxswvBO6rCHiY30PFjAEmsDsRKOEIbxh/Geba4GAt49KUvk2QCzlDrulTly5sGJUxBv59+//sSm6xJ
# DATA 1D5lYlzXPj+0tgM6ZZml7C6GFeNNvh7rM6f7UGUJ5squh51M6TM3bhYV43RSWOpwEgukd7HvFtyAektODjsdhsoL58o9eqOMIX+i
# DATA pqxleEY4hf8nOyH02uXOuTY5DpE7SsnNrZ3d9a1rG43dn2xvwLICN1M7BBkZYfH2CVD/4LjdGnfbw3Tiaw3pf4X9fr87g/SYC5Mk
# DATA 7Myn8OdaLcmrQvOgYk4HrJlX88G6UWhJ/bI2Ie1CaksIv+gctjxPoEf4Bo9dLeSY2NpHZMD7DHHqniix9CmHBzveU9MPX0KxxW1x
# DATA IUmvhLaRUOvqBI+SmUw70z7ON6Nq/3VtDXZdtEJ+ULWy26BMGeEuHg139ZHtELHRn1nyJXzhaMvgwdyqstmC51cxwfNJHJMGzcyf
# DATA c4z+DOF6Cuuexf5nMHK6ih10m3QXc1qcyhrUjOrvbIaOuWD5RWwPvYRAOHGxZfocPXZuLAJmaEVRhLZ5Y9r9I6xNBLjiihD4F3wr
# DATA RuPglyL1gOWPgPnOSfEe1Z+501hNkN/EDv+JG0jhXo7xlmtjmer4KWB0NXHgCM17NdKGlxJbN1rbw8s8qf6Kdf3SqBBrdgEru1RE
# DATA 7rZ8kBHeDsDUA8Oj/eUuFLujSrFskFtwmxg9IZ0YfWdOXf6Wz/liW0v33r3T9H6m+R2jfi9PyvrvtUl5Tf+4qF5c/mFzv+48kb9X
# DATA yE9ONxZnM4TqMRXmMwyMeJSc73x4guz/ETlG/BPgoYgrgIFP/ziIkNjLWQAQhM2w7NCJM+0pUU1WIHpHq/+rvt8oyhLkuckaJ6ZB
# DATA N5uLDugEJyj9t/qYNGuomDKqLMoCBQ5eVdGzSLSvekKjgm7xroVS/GfJPat3jOdVdCtMxBdrphYfNeECpashUfBnENSRawmxgHjx
# DATA ohnzxbfdNgn98fJkl/64NPkpO+jfldhm7BZccj0AcJ1wJ9RnR8JZJSzLD5j2o77iwV45T+Fbin8NmjcxrQGssum4B4nkHukO2NFX
# DATA cKJofQY6gsUMOVV1Hqi78x/weJDjA/cV618NJnW5bAf4hFBCuStsug++Mnb+pCyikHYnPgggzAzOx31OJRJzGARHQkOS8MvzdkJg
# DATA Eozg1O8yH3JtTk+83EiZv4DzDljZco/cuBY7NDlCJ2eFAxWskjSUet4nga+0a2zQM3IQAFSyEttrxVVm576MALDOM0FfUQANOnWx
# DATA sPS5rdmeYra2ndT3FqljhusqmWHRDJa5LtqVwvBLy289iD7SGVbzDQkmfiLEAIIdwVXMCMBxsYHEn8GzjJCnA7tIspmfbP8wqXIG
# DATA /5HzBjymc3jKArC/2GMobpiEE4SIEPU6oPukM8rbkmz+aLggQ9N38YtuiXliLbAOL8pCDM6RwLWAgKpzx83GSYcs1UG0ZhjkQZ2y
# DATA LP34wFj66ef8rGmWef+x5l4ENZdLHQ6qjnFLx4lyHdJn29Bz/cfthDuh67gpYYjLY1E62lxiXonYHPkHxT6mUhvTG93CKfK0L7rX
# DATA k2ZPSeCtBNQeVm44dtqnRsB1ERKWw7/iRm67hsck9zk9Bs+FTC5Uw7+UAAEJ2s/jxGYJ2vToPBjm3+HOZY27AJax0O3aYs0BJdSZ
# DATA Y2u1mCi5nj9GL1vCUCNP4yksc/qs0a7S9xOoIHTGswSTmPQe5Nm2Xe58NzPvSHacbeuO4Cu1nMM7HYCS0cGecSHgEudr8GbTSawT
# DATA MRszLZujI4LP6t+SgSMCmK/4Du6lSYzziQOAYMK3ofp2AwK5GsSeJJCrwMEuwKzOFXrvIo3RPw7MWM/Ah0MbekNIey5+Cm8GP2qP
# DATA ZG7qDQXgczUmxjQPIinc8lRmlgQrpYzcXTfgSSKrzx+0GUTT6RA6nJVIzKYPQOUjBJmhz0IJskAHvs0OB0Gmc7DOAJFI3ahcycTl
# DATA o8GgI8Oduj1lWW3X43qecBUS4nyho/+7ho3m0wyFjbJyu4n00G2Dpbj/oAcZGnvNQXbcH4XGbxvzOb3f745P5Lgx7lSj0wGomNL9
# DATA Tq+F5jLqdNVOLwiGflqnauIOjYW2FwpdJ35rPgWJ8IV0cYnraVt12Y92wMVySJNVj0RtjRz9MXHZRjQM3rsm+kHqNLx5GI3ZyUWL
# DATA S2s00a+rKfc7EsMVpF9F68gSTFL6JcdgY0xJPyUISnwph+1uu5m1OS91dWGm46UHLvtasrYcaBr13bqnCHfYOdAOoWoP9++3KW2k
# DATA ImxS3HMXfDfQ6ZlnfjgxkWv4U0evcZvF/F5JvBlFmOnYMv7QiS5zdV/w2YWksFwqJotJYS0p88VPPS8GE422lIIdXDkzhtMP2wyG
# DATA kLKnS8kMRjumiJ9M4Gm04LoqOdjOo+YRIpJyHZWhBe5cTT3hVjCUwaOJklmpz6shkDJXFnTVUMPsdVzIRUxNC2h95rouqLqKqopy
# DATA 4X7wuPg6vni92jxpXVp7rzk8ubSmHuI5ceSBMpnZEeRRDZJv9EUlC2s1eOmv/3hAQMQFU7mb/NY8t1P/FdKj44NhpdM3eaSWyKtL
# DATA /wppjY+NBgOoG29OLU7pps1AEaWi5hNszEfCQOLiYuhuhy5sC57PzJnxONM+aPhHeTDsPzz1fpbpUj+0HdQs97bQ1c14uJHT2ySg
# DATA RoMmNrdXDThYYDTqfI4YcQccy7PdwZTBuqOuG2j4dhFbp/l3BOMjqBCwFBtJidXlojcXMtJSFLzCf12zmF0s0odYx0rR3kZLek3B
# DATA OaUkGqeXTt8m9qaxr9Q0YsjQAX/QHZQyu/Ak8jZpZuCg55+AmQ9pQJKSiZ3m33w8WUAHWa1QdHJMNyw42vCkdeu1M3U0TPru/O90
# DATA +3JUG/QPLXFbHWAkESP2Wo0EKCPnCeWe7gCvlQi6J3qejSJX9yTyzp7COGQDHwnDewyOYfz6H5YNvfIs+RmrrC1KVQRe4Q6qMOxF
# DATA KhfaoWwK8/0A/bGLuG7XpQ1g1tUpmJjYh7pUqgUTw80HnV4P7NFRkmLWbqbVYex8wM9xcuUMkuO89mL4DdKz+jyj1W/mi4u119iP
# DATA hVcFc+Ph4TMBO7bf5EIrF/Jje233EHlalCOQh6GuK4QZHlTs9Loz+0TPTOgDjd0+4iehFg9brkYc1ucimNxWixEqOj8lTd8y1D8/
# DATA ympOyjkkXzbi107GREuj2QJP8G4kIx5nBfRdbY0HLX1IhW/E/XJZWrKlCDXWCrkjVESPkzlx4HGvI7HeFn330Eh9pmwkpCkRypAI
# DATA cY864gnMvCX1CfOMqaDqzsomkYY6y1nCqnLXJ6FQOkd8xVzkGuuAM7HnokuvL9j7Lm5jew36wyNMVGLoq0K3MBfUZTqp67o7kYu6
# DATA vCyGbu/+FjnX9qCQz5JBKztWBNQrsZu8XMqB+TkTUwiHUQqkkFCYSh10FMqIwyAoT9Cl8pGS+0gJ4QqIhXBQpUCyCYU1tz3XOwFj
# DATA 9j/HFlGWyot6pRny6EJ7GszSqPC/AU6X1OD7vMrz13gsYZDUsNlRK3KHmn2HWkUsZXZ9dfFkbB9tyWYPWdv+mRyNq3FX10f4HU2B
# DATA +rDEzkloXJK3RCmeu4FAGNsGYO1l5NtYNAKTnq6SMdTEVFJTrTEx48jSN24agcUy32pdMDBVu0rpoimphM5jB+/6fPC+uZjyTQmb
# DATA jGtNo6gF7AFPsAXfAipB6jlwnAt9gToXYHlE/Sw0XlC3W/DcewIvh5mw+uCeE8SwPv81RLJJMnmDMUtvLBQmY/BhYstDU/AcS6rn
# DATA wiS1TemY3OXb9NNEFEaAaSBQb4mUo6R2ZC4YZ+q82j9N2s1ht4MyFvPijM7odrNlVddHtMeBusM3R4zg2FGVd07a6qsTkI6z42ar
# DATA /8DFm62EMAuu3+jSf6bX6NIMn1Hd5/8pXUbnoDk9AHYaNYvg+YwuxTxGXVhSG5qEXUjd3VCRAGG3rmoEdteFN4i5aVUD6AZzrbA3
# DATA Evsk93vqDtb1MzzESMPRFsiHbn9Mffk9ouUP60+IASOKNxzUHqQSOa1YuQ4kLkUzZYhH4YDc/9B+glZQ9VdOrrZP6Nn5qEKP74WR
# DATA XpihRwzdrsAQSQxl+S5OAXiQA9F1ig2ewhkSIgnZRe3HprCpIFbrdwkcwcc7HILCAPMBxFzNAA3FdUOKojoR6XxlYeLkw6dMAYJw
# DATA IwCfuAPwZb9qFB7CEe+inhDIoaeW8PBErAu7ucGFTcUSvfmNRct4zRXMTstTSluwFVRTTFY2ffUTP8cwmrRn1CLuPMFoeqH8IVNy
# DATA h3ge5eLEN4WlXUHwL8obp86/z9TTP0n83Fckg3lAmvjIIOU6ST98j+Feq/2wpCXBNpoGmxqheiZsTiwbzmvJ5UXIgYP/meIYbmCj
# DATA 0OX76fNfSg7YP9BY1QM3fS264IDxJoKSI7kzqm4vS4mko6gmYcoMzlAHkwAlT8iisty/tLw8yR24h9qh+iQqUUTx9qbEBvUuJeRN
# DATA UQsc8IsRP+JoTo2SpKfKTzVhR7zgkmv9hqrJdpoQMp3tmnLIridc4WSaK4UtiTbkXDKAdHQuWZlAET9dibs1J1XGTJ4nDlwxswZ6
# DATA UVqWgKphCpaRohpz5AN7qY6f47+IFJxosRxvSiPLb2iWrG5nIM1nCfCaBNJ7ncqtlNDIm0NQNmLOVEJzx0qtumD2K8kGJhADYUF9
# DATA liHoO3qCdVsMaT0AwA5shCUK9OgeVeIw66G8Ncu73d4LcTmUEbS/kRuXf9vyZVVB/C8GJUKo//n987Us9Y35J8W9/q0QY07/tYH/
# DATA KGpz0qY7ia/sHRav1t13FiMApZjcw3sjD0TIEltsmALUaBCMgTssUmm1OhnefgsWtr2l29QMhTHtRdoFYrbR7LW9IG5esGK6IjYE
# DATA lidnmxC0yt9zAz2X5UHzJGqUlStcJjji/yXMEI4Qp54XOoeK8fyjR74Dqe2FQalT8UOT2D5PXv611rpgVxuwlwr8g0+A/vAegVa7
# DATA ysL5zScVrgI0fAbBKaoR5JKOOlB3gHuQLqU5vvxW1vsEZ45glZ7mJvnKlZjKZXPM5SCgwoO6NnPzA5ZL55wXOgwadGb60FYlv2HY
# DATA WgWZjKVkYE2hn2kcua+jsqTHFhA1Ba4UfUXf9GTlzhQjNK8DNvsksVSAs6c4okohXI04JO98uZx5vDlwGbIV9WsbHTeuUxJFUDhY
# DATA u2pIOWHquhLI5za0MVw638f9/CsrcIYTQHjaUNRNOj2mFhpvb/wksg3+n3jDT0jVDLltqUl1jbTrcTQDZwgVdNJkWABbDLK4diAH
# DATA MmWSfzLx0KqwFQ8mwHNTZsxbxxWgmminO3MZJLdk+nsv3WwpIcyt2Ll/V9WWoTrqKPWPhk0LKWCvPpmS/brqnvFws+9s94cUdjNQ
# DATA fxgAJnR/3751GyGiV9X/UtfPFSvgk1B1oZepfXainaXiRyI7sjouUiUX3IAQRtJUeyJGAUpscfNrnZ8Myn6uU9DyN2F0lHx/Ew+J
# DATA PYyXmgvSMBc8nZlR6l06SBzWPowxqKuYNwxfi8H7EH6eFQ7mm8ni7ImrusyvGAf5Qn8M1w9jkg/MNhWOrRBjpwTvFZAbPA7E5cIU
# DATA B9DiiwJvebw4AmIY9i72xTRUw8Bd6UWRKqM4aN8STuV/lv/vi8KO6kwtroAb5twmfezn4GGgzYS/efa7UsIYa1G1pwPv9C1AB7Lv
# DATA Mm5012krD3/PXLn62rMyZ38VsPY58fosF3Dtul52ypvH1pfWXVV9r/kdIv25XHA6pJ9bdiGHIkRaJ+g902L1BfbcTNzSc+zy+BlP
# DATA aN5TCdq4p0wRSR19w7A/UvIOuSeqvVSVKvbUD4pLVn+QZdUSwPAewS/4g0l+3XuWzIGsEO7cIJPwp/lySTGmpglhqyN7IoqBOTNA
# DATA eQ9N3BUrCqaWAocDX5gaqAvMmHJK1qMN2sBMkdpBa6UXAm9kZGo/xI07Il4a73T9HAMUMx0snAyIvC94nUvGGUP3Rw5hWXEWeFTF
# DATA Mf0UWmn5y3PO/dnionpUShYXdQ2TMHN6ydmODlCW+rqg+jroojv/sTopSLKAvxpAb65EmhlhVMqCCbgPO6sgT8TImWUPKK84gexl
# DATA FYIoO24/LFxcLS7o3AcoXsVg+bwvFIlv39rZffP2xk5je31n591bt6+jgp8a8oIkrMJ3djZuY6yEdSjql9evuq/8WjwMwUPrOK0u
# DATA LcmP6pl0Y/I3hkm39quvrF1cXcqv/Y3bt7Z2Gxtb1xvXb91c34Qo/fR4NBpkqm4gNbMi6fb61sYNU0y/8avcuXO1sX3n6o3Na6aw
# DATA I0iNh92s4KyqWXnYWnuXq3CZeuvdzeuqZ+tXb2yo3m28sX7nBiyNkjLG7XAgNzd2b29eM3PdbJ100JdEXsCKRVd2da0Y1PbuxtW3
# DATA bt16mwmi8dbG+nWsNkoXrJBXGxUCFJmYtaTsblEiuFBIHjRHo/awh3F2fwcTP2xXEIW6DTu/iMFxtcri91NXbpP0kPx5CXsBRsfK
# DATA TY+Ncvfgk/G+Kc/5+xrVJGAwUtlht3mU1bDKKflrsf4LNcRRVTWE7OoCvrKZA3zCzACBHoAX0ARjYOd+Wxzw6IdcivmVG+eI+Y8E
# DATA 5dVPiQS/X07vDu/2AN715XO59SEuqdZrXAEvHs4GxbpPc8JyEikbeR3w2OEPMiWy5OaYbgbNUzBcq8GBtaECf4PxKmtfWqvsX1pj
# DATA Y5pMi8A+UUCR4ygdSf7GdeNJe6/oouTwu717LDCwI1bzWns42m6fwM752YPR9nhf8e23GZFe9cR6DT/VG/jlA+aS1+s7sO7k7OrY
# DATA FgrmRSnZPR3Qn8Gq2BP7KWj22M8RMYolxeIjTCBAmj8DIPcIEGMAGfYDdCj+8NlT1EmTehaRmp7G85oyZR6+rAWb2hnR2+Ruz3So
# DATA lp4xcKui6ZeZhh80OyNCLEEGWpAQtc5Juz8e1VaXTUixFSmAse6KHdxE9BEKIVSr12p2lSSZRoFFwpOP9UdQ13V8IhgP7s6xikGT
# DATA pGtinx61rp1DOKLbUxJ2YWi9KpktgVHt4Fi1VBmo9ddKLlNLACgBRLec/Mgp45nqf1RLVi6uLL+6Gt2gf0CnAvAieAR3PzfRTXSl
# DATA HyVv7e5u75QNjI4OeOtxynu7N8YIzLqsdvOQWaYk4S3D/65uvLm5lVzbuL27+cbmtfXdDXxaWXwd/1VnafAutXJrq+p2HOYFzQQD
# DATA /n04nGAwfGW1tOWiz304kPuBlyU8y7qV7Y2bDRh2Y9RXx+pt/LsAnVBHb7FYkWThZqLw4IAvKcl3g1EuGvyycNBEKxrcEKzpLDo1
# DATA VBh+Bw+T5D2q752N25tv/KTx41eWf6iOZzVl6zca195SEoPzpTrHOyfjEysVL3y7e2OH3enhz/srjVX2FG+2FM0BEcPGq5z01RSD
# DATA 71sBzlDei2RyOgZTSlDoR7oKC0slQFbrjI6TDLRrI5kU1dsemNjVDaGQrqy+WllW/7eS6pPMMAI1nsIqhKU/LFRWSrq5st8VSJTb
# DATA zBQvfRBJCw4dkAl6MGwOGtSbgipNarn2sCF8oqaFK6hPMa7xME/QVyTpUwwVB2Y1aLeHSCz76pY+VGvZH57wQaSpBhiYkF8191pl
# DATA QO4JY/F98I9z0K7AvgjRIP8k6Uls4Eq14GXa8Ahf/0FazLm1UNezNrDTbuEwfXNjV7Ew2EdLK5UVEAjeUlNTTc5khibw7JpeSnWz
# DATA 7oK7AEgO6v9D/jY8jovFvNlbXV4GNtZB3Q81r9jn/cIrK6uipyvurdSBztaWl/NnyGL39sl5a4ePTfsI3QSHIf8MlSuQIWIgr6zb
# DATA bg8KFb790DK4bMVOZMxr8D5iTP85sdAvv6SkmM8/viJKNQrd+VjyLOOalqJsGROn/wcllQFbKQp/ZVI1ijUff3EevIK5g2Qd8C1Q
# DATA x5Ztsp95EUQZRr1NUzx7pQ4ddo2X98OUEhAAHFCyjLt3WV2q8NiUL4oTYD1X7vasonvVaj23nCPuHqZpSjszOTtbsKoY9zoPq0v3
# DATA m8Mlte+WtBJ7aTjuLeFEVGBzQ5UJqlwbcNfuH/S7VxbOaHATuaSrXY9TYQj6CllJsm7DPuIjrY263qke/bIBgn3O14Nh57567X4r
# DATA fc0SZNOVVf73IhUBUWk16feuLFhDwNtVlvQPD6+wDUQdk0vjbLikmNKwTZOydDw66dL75njUR68580kbtkMDgSbXlteSJfWfivVB
# DATA q6Uub82WWoofl6/RyVwGSbR8iy6kiiazXudQSdXdB83TLPjqNgCmDNvD8nZfTf8pSNadgxF78pUfHLd75YNhP8v4iVNNt0+KkOTv
# DATA /iFZeggTAN4yS0IUePR1OxCsp46Ixn6/dUrS0fIV/f5oODhokLhCh0pycXk5894D25v2HrgD/qWu+tNIELuIJEgVTCbuMNQo7t6t
# DATA FF5/6UG72y0jrsNSUY1GnWy9U/BzvhJ8AoOFU5W8EpLvj4cd/M9SUlMLheXV/1P7hdnB4bCdHRdi7jwlbf0Ve6Y+9VJ9+NZSNfzl
# DATA tETbp6btGyisE8/A0r6mKcca6j1GfqRaWMEWUKvVa48aqICggDhuyTyFQ5MfItNAT03FHLqHEITTTe13VP3a2kV52unt98dqaenF
# DATA ZXhjgxXZdYrir+DUbV8w4ndhwPB8zOZ9FrTfJyf3Z18krgCK1+K0uDBLBe72q+Zec3TOS2tFgo5RXgQ8gijC7WMdTBGRjE1Y3KcY
# DATA t8oAot9Id03XtP5wD0+AWIQc6yv8JY0sZhiOBKF01ATF0l3MS6GCEtSvkvXtzZKzPoBRze4kj5IfD5un5ir9JUfQSU4VOM0tn5DO
# DATA oU/LEbCbHGj332KgE8Qbbqn78vr1m+q65Cak+5Tlh48ADxvu9B/a8VSf0kqbKIYY2rt2EQsCTANc3Dyvs3y9Urd/dET+aGdpSx1r
# DATA 6BaSgoamzGl00/5APEDOUsWoy8CjodDFZdSOwCMsqh69kjIDhLjbvgD+IIAUvB73FBPMytmoD+la4GNuHgLw6a9AQakj9M9cw7f2
# DATA Mma7bMt2qJkE1Yy7nZPOiOrp9bm/Z2nWP4SerSyvXX7l1UuqQ+rYbZkHk8lkPj+p5mAgycto6MylJWmNJO0jV1azpJIquVgvxSRk
# DATA WK6stndo7llV0dJUkdPHP2NQxtoe26DLdGeicw9OOmOaJt/WrLqkVnlJjWKJH+TU3GqDgTFr9Hs123Ta2sfZVGJsC21HCK7EWAxK
# DATA kOiOjk/TiWNVJZP47I8m0W7Qa8RGVP0YKQoDH6T02s3r5Z23Nm5gfqwDyH5VPsx2UPRSRz8cyl04NGHqVpaoDvQ8xySLak6gByvL
# DATA aLVgcQKJOiODsJJ80NfpEh0sw1FjoK76/Rbthcw2D4c8JTDaggpyoN5RTpm9VDOQtB5LsRQhLW0fqa5crqylL0xkdIU8PkHhq5aq
# DATA C9zJPtUmFjA1x7s/hWHe2b0G62joS3poRCrLB2JKc/Ms4OCo0clA9jtNyneS73//zDEzTZJyy3l4/eokWMyLs9ZydXlih20omsyZ
# DATA a9oxvHGqPyw3u4NOD9jjvHstbzKgHXXeWN/j1QC6WS5naqtgrjf8RdZ9AJknrTQ9Vfz3pH2i1rk8QBGd3rXVNsJNhWVA6qV+wW+v
# DATA a/wPCr5+cUXhyORfffVVegUcCf5azh1Q/tIap5iykvuxvmyO/kB+0q+5spbvnMW2VCk1pQ5bQkZmJUYKGRb+6wQphaJzNT+RL4l8
# DATA +VbB/C/xJi/6bf9F4KER+bQmYgB4kwSvwRnm8nIpUVL2JNcXiQWw6Tm7bBNGTO6iXHaiOiErhSMzPSUxN426sGR7tm9O4OpWj+/f
# DATA cI1C6iVJo0Yw8OrbPZE9kPZyne6iOIKRY2sKd7a/F04N0twhRb8472P7LiYmBCsMEsNKdNvGD/UXO5yn736Cc1T7PrRrs5x22Ib4
# DATA pZf5yDbjgb4vIQPoNbt8dr9crIyO1eVhWHuNfbcgVnBUGFb6915frq4Ui5UDDIcqFL0S6lUe/3K4zCuzuMzKakQYWHWFAT4hBGIN
# DATA op48VAidlM0wSMOttUDmRkbCBZ8iwfCOX83ZK/Q2Z1fQ2+qqOc3cQ//NW9c3rt55E8Z0Mu6OOqC+GR0MassgBDDRpZeXq5dBIQA3
# DATA 9yrd3uXPpXFrME0KiAutwfa4Br2ksAYwrleXFI0sYdeX9KvqsK9TiJdhPqtL8F/zjFSs1SU36YzXuESfnVkVYZiaV40fuqb9xc8o
# DATA yt+46id2uJv8CcvMuOlVaXpiqcBHwyZetfXqRRaclLl7Rlhkn3JrA0eQLpxCuBvnvsIoURa8EVmFAwfWi4ucLPrWHLFXa3XMRZzH
# DATA WJpCHEpuELKIavXSUhJ8o+6amfNR/2gpGw9gddD9M9blkGmD1XgJ5kEEr1g3mOPlfH3QH7a1X3Hsc8RUdkrV41INKpJgDWN0VHfj
# DATA eSKaJzwGyKZgvS+Glxah27r4mgYjQ7N5/pKMuhns1byz3TKR5DEtfFtdqaxeNnwrRpwL5+MyZICA/W2zGdLAw9NKa4ntwVgIGc50
# DATA zvaCU3PeWmfvgHNW+ODBA6kwZoqAPnrs02JZ9gK+KH+cfBMRVEZNNjuGKgiiCskjgrcDUpoXZgW//Kr9MCqMionEUNEkspTE3i1V
# DATA e7v6FaOKQRfU1sEcZRUx05Q94x+e0lw8PA27S7FZ1UT0uSlmBLF6ijgeOhPUnCoy9rKx5dI7Q5Cu/fCTqV6T57p42QHlZ2GC5GpC
# DATA 5gn3DY09EJ+nbaKcZMFEh5AouAL/WSsUi5Ni2EMf6EY469R7TgzGyhmv7W5Vc7X8pJEXx6ga6YQdnX2RimySzt4r5WjyizEnaDtI
# DATA D4hC8Q8nWESwYzAdXgksZ/0HvimJ7TX9bgu4+wMvaIAzizgCawGrK9r+qCBeqxqcEC1ULdgpDcAfGnbF376723AcllPM73V9k/5C
# DATA L13bzxb+FvdZgFU2TXr50FU5SuUjvwJf5FLMmRgemqAG9cuJQXAjZcLYIjVsipJ4qQbzR66R7dNi7t3+v+ucoE+f/ZmjiDDRNgbT
# DATA QprtSNDQ808IqABqpshGRRqE9UP+tgdqEyg6abcKe4UTcgQE8zOEQPDPHUr6Yx5cV5fGTg93g/X09rspB2ZjNiiOEbyJzXFS1qJQ
# DATA TIN6gYTT0D2iPwzp8G+LasDPSN3pIQpNMhfBDkarSz+rMK1xfyDx27U7O7uN27du4YqgCl2fvKq3VhapJYq7VZUj7DBquwwyh7wS
# DATA kFkLPQz7w8ZNMzK2UNFbiPPU4zTLa55xZpsCf0DVfy+5JdkqR8fDdttgJJYhjRGmgMIDmFs8aZ4m+21wDWi3KskGwqlIHBNXiCUB
# DATA g23Q3O90O6NTuiSWxEUZ7Y0kqClWgXow4LMI6jDqM6foZAKtaKASaI2+blRoFD9Bploagz5GGM3UYHGgSRg6rAQejWbqi8G+1CWt
# DATA 1ZQKINoGrI1Ie+bpxbrg8cJ5FYmr8sP07KYgHwzTTzy12Jz1UW4usUFS1SueGDhsd5sMh0bFzQ6oyLvGqE8bSiLcbdwFONT9DztZ
# DATA Y65vw8TJOniAewVrC8ZmeVCh5EggraziyxdK6+bWBq6lXJfzeAWTf8RXYE8Wqh6uRbiL8ZemW4uKiNEHfCDG3hF84WMyRn+BStyQ
# DATA sUfybqrrOm3fm6zHA8ngqiJWwFmC39eag/VWi/+6PuwPsNCwc1+J1WCirTsnsXfumwhCdOQI6/JR0JsD+6CRMMJqcoYOus1BUclC
# DATA 6lKPxGen9rq2rg58DvtuIkZHwQviB2fJgNHoaFV11rjxhLAI0Bs6cLhf8I85bPCXddREYj5lxMwnpaKarj55T0kWRmEymZ8T2E3g
# DATA VOa3UT53Gzoz58y5UxRqcfL8glHnj1A+MRVUNaA4+FXGdxncJLHeNOeaXMWrNCh7+cacRlQ5EDVmqXyiBUOlDWLgWb9LCxMJDoSk
# DATA qyb7awzJwk/+Or9DiACDy3sXF9xU49czDRXcxQWKxirMxAj3/ZNYK1k4J5RGcX78KBsNIx+EdOZ4KVOxBZGhUWDIkwcidp7/gvHo
# DATA mY/SQ5iBr55/4rBW9PasJbaaoZDGzxwgb/siWTluP3Qy+J5NxXWZoR2BjvBz+LNo57QUZJdDnbOppJl0Tq7SIOYP8cpIlKOzzpWZ
# DATA vGW3ZXqTRQrDyuFN5JJgpVG1bnY5pcGcjtqtpdT1Q5NehjANapkgiEEKlOC6U+NzB1upolxBx7jTGMSZyPWFEzrkXsD+xd01AdVY
# DATA 1EY2V47Zw/TjMb8y9epD95rGmVengzxoSY+8kXG1A/hHK38vobx83aSw9MNJCkt/WCoTN7+qqVhXJARq6rCqnrgJM1VdigcfdME5
# DATA eEvysO42h5u9wz7AsCL6I/8WzgtpDVH50VZSV3vUBPtQATxOSwnETUH2AiuYpj9C3G7VkeZIdYNLqN419B7XtRCoqJqVZaBNqLIC
# DATA 7jiOukseAmI74LwuriLhYzPq0aVkUZ7HDlAYI1/puCeJNI5RF+1WhrfBrHnYTtBbzlLS8xeV3J5DGBJ0ZMFMFFhcGwO1b/ImCAcU
# DATA zqcU9LMJooVGsT5TsS7pNXrUG0Mq7G+nYak8r/FMCfyQaiSnbQ75xEKMI0dApCNoZ4C6ErzSm+U66RwNmdOx1ICq4oORnTaeWypQ
# DATA 7iCTOQdWp4HLWVvVBHKxRMgN/GJlWf2P+/jyyy9fhYlJKACAVA3d/hGCxiOxcEYTQMFEpNOeursD4aDvOgBd3odOq260K6qyhTBH
# DATA t82FZJMc4GFQS5YXdNSX7EHIYFSAv/r7P6vJ8MjQM3yP8mp31B6t+ZsYg8B4Wrzbehv9YODK4b8mHgd9uVBLVrwgI8rMSxdgrILA
# DATA UumKF2KkjDFhjjXRsF3Dr5VQ1txXYtt41CbJLK1UUsKKHY6yvOPiTg83ai/c1Qgmq7E5sBtpMXqmUS86GcmE4pquHzOSoZ4w9YiJ
# DATA uzilV5qIezGGA/WEveH6KTY2WbaaZH5nqFhdUJBm8npgsbmAq+mNlKAPs9uNljm2gZmROPGzfqeHSQYWSVcQm0brQ19ZwZQ+R19l
# DATA hggKQXEARWotW8bJmTJevChisDWF8fg7WTMdRmtEUYnWdzkR9zIShmhPwsk96BPu0OX+q8vLECwCSDoZh4MgoHejf89KFjrzEkt8
# DATA Qu1Ja1B5y1eh5r5OP+C4PR6POt1Kq5Pda4wzSOHGq1k5BHXpjxwKvZBcWss7fs1Mb6rdcXjYOYCYJ8DxvYdMVolZJ8iW/A1t8/2o
# DATA Kk5OZT4OcL9Sr8LR0DdBktWZBCkR5OrLE7X/wRfTrfx7AKHcHWdYGEKEYQMxSrai4TGZtmTvW0jZcoCQ2SoWdgxdLjkri2dB+nA/
# DATA RebeH48G40guMvuLg2NFAAVcf2tPaHT4lZUV0hwi+HxIjKSnprtLHumZIGtdOr7f9rsQ3mgpR5utAgRJ689KyaVXXrl4KT/qFvgN
# DATA 1jIr5Diykg/UjI2G4x6sRisnkphmtMJA+NBQvJyZljIlvsopy/UdKvo4jkCG97PKYXbaOyhIOTWJvX7BtSriCaatiYPTmNRjqUuE
# DATA bBzeq/4m9wRSFKBb2CC11Czo7oCQ27RR4H5YQVdFdmNg/0EyVosz4TbSI1QOlqIWBL3bbze3N/B5ezj0n7P00znBsBywwDRBi1rZ
# DATA hSeFFfDEleL3Ot2uVbzSarYptgbYlvUcr74CQAJRoaqI1oc7kf1BmP8UeVJ6QcMrBVdIH0Yd9iWQ4HjocRnpEr9c8MDY9FALdsIf
# DATA u+0Khqhbr1ud5lGvr7b6ASyLVVg1RZtr5dLFy2t+ooYSdSVT4mNb3QIP3MRTTiV+i9qPRcoBFErBAj4xjnbEK8HX7lp/3G0xbLQS
# DATA sVBUBmaBMp49BoQMZD7tvLFvgTSNfn5GlNuoyRhAzTU7cRlnZbzW7OGlQx063VPcWNbZc8XkVTNbRJJCtEB5jkkVoKbwtqQJHXBi
# DATA u23FbbbpAe8UcRMAXxRrlALQrRrt2sSKxH0AOD82bZBLJDYz6APVxM+2HMqyXwVrSKwm6zUH2XHf3hQFUBqo/o979nZWP0vEmLBQ
# DATA LYdH2aGrI0+VEUW/+V6ynnConJDFSfOeui/SgQkxemBa7ZLohlAVnTZR0c/HSlyCrCHtzgCsxVzfQf+4jQiMMrZKclvNHXgYJ/fa
# DATA 7UHmZtQzK08JMxQb7o8BDbMiCdM1+oqag4LNXPkdxAnzQEU5WYf8DegeTkKYEnfViNsNOgH4IaB9yJ/e5jKdcoCkdGeYWRStJG6e
# DATA fnGzRfBDQc8SOy8zW3xhqm0N9O1xr4cyUCS1EKW1+xTUc/Qngkdgap2YNu8rRy3O+dBsVHRMJ0Q6v4/ygkFpEFOSg7KS2SqM2t66
# DATA Vo3DzwDDCB+yGG28GF6yldWMdPRiNlOo3jP1nC/xqDfHj6bpSy11e+ROoG8Blu8FpmiCpEedXu5OdeUMAFTFhEGsi1RUjlNOD1kd
# DATA WXfd12hPTzXOG802TD4rZHOsyFRfPS+XY3xW/4L43h/PMX1GjxNMop1GWk1Ti4HTLabp7LNARnO18FBDhfggHNtV77ZxnZhMZq7M
# DATA vRZl/VQ3KrhQjDuQF0nxwaS5nwG367aPmghdIWiFpjJDznigkWi1BFFvcJiqP/GWxiJLVkm2II9Qkj1A0zVyyy4CDFb8+9aUU1+b
# DATA oXCgJGlgTJZDD87rXJvBv1Jmk09pX5BR37ZBPY0uriQxI5y/vzDkwZeS2iOaPwWhEiirwm80/la+Bs/Pe7Qn+shFpqHhUbe/X0gX
# DATA 06JHsaDL40yclS7hpsXSJUVh13S2XW3ldNPvFqdNJFtVBHAPclg+AlBsgoWApJZ/0TBsYPt7HM7r09immaJS1FoNGLRGh7NGyCo4
# DATA uqHmaRhRfWubAixFb+6Af59LEkIRj5//6vkvBZUqikkHNIZEgb6BLkP2JgAH5N3Fg8WSWZh6Oz+gdNo9AGQrxHjsFO6NAM0Om0av
# DATA iFnm+6INg40TPySxu4B/STiHn1bR88zVeUQj3zh7hmQ6uEvBxmF0RQtJEZQrnf44S4vO4yFlRT4NdhShmBG2vtRsG9DpfVxHTO/m
# DATA 9DRhuDTc8zX+xV2GxIFoeXWVdgim5pUlPLZIae6SJ3Fo0eLS2gQvFFDl9I3unYSY+kL4HmJ8EeQKZcRQ7PULcpKyk80LIIvaPZ/C
# DATA o7CrzmQAkUEsBWIQLKlXSw+HzVPODCGLQsM/IXxM+GR/3Gt1Adlibkcfu9GXZlM2Ih/TjOVO2G+9UT+RMVNqX5ZWn0rmAcoDbB9C
# DATA kJdATSBnA3bEOMwI7CXe8pNH+4m7sKonOqsBotRy9lm/g3H6kQ3IlGKxWbUp7AyRbjmSfqdOVeQ0tkHj7NNY5sZKXv8HyrMLaHEe
# DATA 5KehsQXt95dRLkBYZAiFsdIWrieoblNiGAoc6lrcsfXO4HiXDPoP4FrXzzJImYw55ZpDsjr02g+syugOYLkQJYiUmx2jRPPgGJIu
# DATA yG1SLIPN3mnCqhXwoa1YChuqpUNIQha2FUi2SjbA89uRG1BoN7JCcGxYLhz2Z+xzbjXoOG0g1BA5beCf7AkKqgkA32TU4apvYMAQ
# DATA DFRiqelH1R+n/8sqtxq3r9/auvGT5D36JYK5frB1641bN27cetclyVGMt2qtqGnS/SrQkVhfksrK/pJBe0Gl21AXeXU5FsRezmdU
# DATA DS6KX8vZne3hOll5Psqu981Jk5N8pLel4uT/e/93KGdI0jM7X0lip50XDEKJSEVNbVuERzpWdQ6ffBewCqFQFTz/bhEn/JQODQZJ
# DATA 2vOBoQkViy6F1hFY9FJEwOsSRjmykAcPfKZF1LoQy8Ypk0t4XLmYA1ml2aJQTdogZhNZlmds30kyb6XIhdxGbgJ6iu813LO6kN9q
# DATA 7EvGn1JXQmQGtPiKsjCB4xe42uhD9/xDyYWJ9OPmjH32P6bkJTQ5NO2sul64G0bn4JVS0lpB5qDFvTTBrwOGZHdD4gXr9VitgPqq
# DATA D6c/kd8j5OR5XxDb0C9remPExvSEFutOGkL93Mw9zecFMHUkdiADXFdQMDephL5I/ITQz55c8WDn8CCC9ZJLoJd8kBMOVdhIYrUO
# DATA M4Af4g7+AMf9K8Bus062SiJYd3hKqlJfYNKx90mfI5gij3KSHioGniXlbjPMkUCOm39RBf9AoPQ6T2IFs3jo9N8fOBkEMdQJAUjY
# DATA If4xkhPlJxR3u2dPK2GDKdGinQycv8Fk4FwpTC1SqKFMVulolIcwQ8Oz/9sgyKrLmetNi2kQVZVhhRTjHtYGnXxCZOl75iriDOsZ
# DATA to/UbQauB/FB026FKtTVsZoctKKbTj1MSDss2aOSAUYMoCmReT1srXEmqSwxkDS+8euRyAQDElGKAKpoHI2yZA+pjB6OdIYvCvsu
# DATA SYR2iYKqSzyLJb6rwR8QG+1GMbjMjVx64inLcXfYOZrQ6BiZL6mnqF3LBiR0sbzBNvlZSeILuXoSk8s8ngrccaNFxuyrTiSf8e8h
# DATA cTHlByQBHDf4G5s3NnZghgNh18prHOZf97Cg7bTRMmQDdKxmwz1WdKOwToBhDc47BZz0Iifl4LMMEXSnnznPf1UCrvMLk6D5qZ2O
# DATA Nc7I09RQpqFhJE+KhhYIHMfgc0C5e4INB+7gphY1AF9XgLFN8LV1hRFjoHmhF98zDGIz7SFqa1EvQZ94VyacqguSqFd6QqtoqnDE
# DATA urxIabXX0cf5fcSNsmU3QxQozOTUW3QXuZjXDh6ncpYnbhopDVZq2tBBBOY8p3DSui+Hze5dvkwUTihMx7+5VARH2twzwfgqnpYN
# DATA E9L5g7PZ4c0cpyLkIEftWT3+PR3PSPP/GIH/qrIgc9Seiyam04WFM+ZNTNDAvMThE0jQRIRWqDFP4jM7nXewEdeCs3MpiN9XR3OF
# DATA L7W8q4t71Yur7skycw8HWiBe/+h25gUmihj3JNy3lc6q1CKAYBznWO556D2+rETpsTrn2upm1Lmb3BqiBbm1hLKrLcP9hTRY/lnx
# DATA EeMPv4/aKRxagh89kczwz56GMqO08qOwxteWyGbFcFPlxSUWo4FOQZD2ZMtoNvpnT0ugjdK6O/oK8gFZ2dyfRLVyYWdBEOL5+I85
# DATA 5FFCSWPql0v8NMEzLekIeT3tjzhtAogYXPLPOqrKQUoOxdzfWxeOJ3yDeaz6htnGExg4dugzvkLgTcTMEl8IxUQvWcS1zcfT3ikx
# DATA QUJpn/9C7kJsWke1oZZTrHRYLMMIr4hLL0iYRnohVQ7CNPGuRX/sIfqCHuHflfXh0Ria2sY3WhOkdmyt0VAyeKNRtL6EK3qjyZ8U
# DATA 0v6gPZQwqYPjPuhFaozpg7meUgwly9DQwIlwKQU3wsqAjFNmcRu/sf/WOXUxTiBlJJ/mUFDvMN0X/H1EuHfEv1LEZM6Oy7RbsCwm
# DATA 2LEeOFwJ0GOCh4y6GTzn/qE/Snk8UCcjxTUD4lRnJGA/1JtsBIpz65Gg9pUZ0wCnoNvsWX4P2CBrR73H4kxle0kM2RlH10QzCg2V
# DATA uQP2ZOW85s7HX8o46K0zGZiMQi+XQXHAexDqDcWBIUo65TLb1IpX8gqwiS6/gLgNTW3GXARtGvUE7Pw2zOkytRVBjJrSWUrom/ue
# DATA ljr/PZMSgadP7QtmTJ5S05CdkiAyc3iU1UBTPnVsiramdYwS35rVyC1pKZj06k9r2OwUjhWspTN6imSqPitLmssmmspqKZJxA1Nk
# DATA Tm8S8cj6X78OAEcqnxDwgSG7vHQTdWuIpsycrTDIsq4AM19cmfodgzIFn1LWjGnNEm90lyS3Lb96BKGfzhQizHnOxXc+pd02Xy9d
# DATA MTXo8sryzK2PJ5VZZZ0nHvUrjEeta6S3s9f2XDMNmOH5bzlFHDfK3u1cFv+B0pmBAYBfFX246xwgfKgbqcRP7Yg3CfwYuVlRYMfi
# DATA VfIpUXU1OGJ08usqJdYTCtGdXr1/LlW9qGS5+dg1+mCZ6KgUhDD7XdtzYP0sTUC719zvosoEspDOhzOCaCYGUkNR0fqNGy7+iGNW
# DATA krwAeEFBlZ3zemDgVNDnWUcB2EsNQGQwZdRfk3aG+x9FC3ZCuJ1OaEQ6M4qc9PLwWQsARjCpAYxu2ihbhBDDcf7zzSYYvGO5EozC
# DATA 0Fp+beJ0IxH0IjpzxyrNU0URlA6dShFsYq+fTidOW0g100sPGvCyTe7vFYO8MLU+X5I8F7EzKEQeuAgf7A11UNH3/KBYSmJdnHNq
# DATA rSLi7AcdmD7MmHRs+U1FfPDPyTSmytnWdYyL2Y77Uswd9nkW0b1YWOlisgzykvILSfiZhWNzeCRzTfzBn5T0dp+Nsm1qkuXW7IIf
# DATA EK0XZsyodzmyCRNeNPiF1WnuZXwG8wY0vRP+fcxWqJNY53TjPJsucnHyN7SY3fN2i73/KBEMIiVwdfMtMz7h5rS3IAMtkcqw5Knq
# DATA zaY2n5l4BvdTXvcwE4LpCN46ihFuwfeDhuEa5iPrRtBw9mfgEDxtaKVk1gg8F0dy8+z0BuORgwyCThdVY28CIZ3cC6uOqxe+nER5
# DATA GcX8GE42hdWhl7uFLp9HZtMu8E7KNSw1FwXNtWWnNse7dz5ytSh1rm2aq24I9y11wMHfxaJWN3AxStYW5H7NMGmq6mbxNle3ZK0F
# DATA JXWm5+diKVpbVp1GPVKqMOtothCvo2yUuR7an2aMNdBfTe8hl25w6Wk9DXkI/uAvZ3TLqBR9kacEEPSINCNFYqR53hnk9AZ+n/XZ
# DATA iD/lZBTKD5Cnp/IGX1Jy3MGtrXQlDggNtw018Ctx3yMQtLUBxWrWBsesR+U4y7F8xrGoFbtTSYR2ripWmLYztZBJmOb0g3Biw7kF
# DATA hcEMegkVDFVfpNfq9BBnPN6k08XieTogmuY5+yDpoL7pbsxcK6etmUummeccF/SZTaOEDU3me5lShBui7VIcgEUm8/SBAe7NGswS
# DATA 2DonmAQrOzWx1urvCjnQ9EBYLyxbYNAN5K+NhrXHOFqyGNSpkdUdp6HBEuVtmGLdtQIW5kFZhEDTz9GLDTNqhXFIuiOSOxN/FAYl
# DATA yfzhEJv+zHSVwv5c1JQr1nsd3vPKKz47VGUcRysn7XnIDlw0es2KZ+TW1QjAM0iEDFDh6SJsmZIwz3Xc6jQW9lEylb1RzgVrPE7B
# DATA PBYQyV8WeWE346afLKH2xzTa69vvIpMbXQj7oZMFwE/y8HVOKLeKDQCx2obwTkoUMaOaOU7hKy92Boqx0hGYg8wGgfAxt1giGjtt
# DATA pygj1LqDTSEud9phFb3U/qKzIoOP2jRI5wCfVPOHWTeVtBqoGDmFUIx5BGXtnEPOB9FkQ/IVkFaVEh4a7h+Woi1YddMf26+KMfVo
# DATA NekM1AwPAcGhM9BSrVancKZ7Oyo8b5IQaXLB9/wPdMpStQM6asUC4IclRJAPYePzYgB84ULtj/uclxtu2RQXYKG1OAlDTA1W/ED+
# DATA VQ7t8dWZUuxCTv4VsVlUPYVPSqadqsVDJ+GSsY3TRj6pxnKpcLn1QIK2KpktDS8sqHYbSEqNBg6/0QAibTR4ApzAHXLIWLDgcELA
# DATA FcDFQbyU6jShQ/b4vz3/pdq8fyDn9xzvnpmu4Nic4i+YoA3EGQomt+BsEBxm5zQbtU82KC+iPYjCO0AV2PtS8nb7lP+C/B38560d
# DATA /gOROP5259bWdYTawadFOyhtE1UzmEWi0zvojluCdIapIbJq0sPIehx/Mmz/jIBFOOs8xOWNu90EGqh8y9NXSZ79uwnZe/4xwXIw
# DATA TIKOHCi5SB2/opBHiy9TEIGbP+X5rwBR6lyr8Vf/a/5P7bL9LpycahtVBqffShsQFH9pbQ3/Vf/z/12+dPGi/hufr6wsr6z9VbL8
# DATA XUzAGBzsVfN/9b/n/15++WXYSIo7kilXQv8w1E7y0JDSrQOYgcN2t93MAOWIIkxXKquVH65WFhZ2j8GH1y7487ES0ZPRsTonEE2O
# DATA A0QQA7RzBGltjtvdAcahHAP7AJxC9bY/PjpewEL6QpHsXtsuE4jqYbsJIEVoRoUYWdNHTt+dHDfvt1Xv2uBZDlbLVkX1rT3E8NuW
# DATA OlL34SgFoK1eX5uiD+xDAhFbH7YPxhT4D8BZIFESiOECAOnOOpIC/pHuzhrPsTqU7E6n3xHHceJzDn6W/Sfs/1cvvbLi7//V5Yv/
# DATA tf+/i/+l46zNAnZ6ZWFBbYRslJwl28NOdtK81u3ghZt+JRMMaMBtXUj/ZoAPlw6wTFq8wt/+7MHILgbiyIP2PpkYirqFnWu3tjER
# DATA yC1MOoVArn/fLuxREo8Md05V4MB9Z9GsCphvSjiVHMCc+yPwief3WZUdWfMLgKivqqlDDw/HPULmGLbHGZyOhWH/QZFTlkh+vf6D
# DATA 5K//Gv6pcEYXJ1babgi93lNV2uhx4LP2w4GaoPURftoDmeq99xLnxWuYbe86iOzFYvB9dqAuBVlF8dUjhLWo8ZzKk/fec2Tyub65
# DATA kKzIqLgoS4iZG7mC81l0O8U1gex4WsCvk9pr0arwd1HN9GRhoQnR9YmecXVNvN+Bu0iBqKuEqTYkbZmsAWjtXlr6u73l8g+b5cP6
# DATA 2eVJWf+9Nimv6R8X1YvLP2zu150n8vfK6uT7SxVIjI6ZIWH+IR+FNXGQJqF/KEnTXiItF+SdSKEwPZa5+1FycbUI8KGKMmDdGNtx
# DATA s4cXdzmn6IBR37XUpuk0IYPKFQHTU3RDtDSdkuzy4gQHtypwGEto2irNQQeTX2YVgLy60+v8fKzufckDOAeranvjeCfJhBtfWkpu
# DATA t7OxahuTAiVNPLDLeCcTyK2SOGZAc0ijp3gIA8REByMCVQ+bXcBt6B/wOXqYDDtHx6OsopdNd1iR2Ut6f8nToqwwTr4/lewEliAv
# DATA SQ6Om72jduuKWCtRGlD0M6L7ih1wTW69NFRKodJVywm118wMqgXNmUKEUobpw2TmVg+JNmHNSons2qrZtPCfSq//oABRAyvLyWJy
# DATA 8dIr6r+XL63hOQeYQbg1qslepVKhDcQBO87a7III1e+2kqNhUw2H7mcH/aEa+aAPiRMgZx+ArI2V2KTWAWGFNRhbRa0tiBRSW5+S
# DATA DTaBepoHGpMNgWedRQYZrIN0OqKlxjGyGBRbUPl7LuZhzSOtRM7si9KCaPcM5nxSwpU449mzJm8ycZaZmbU6kiogcRbOeMnUmTeE
# DATA Zasi4wXMky4ELa1vb1rxK52mWsybYHY47Pb7Q2SgRAqtdUxmAwDBmFByBRdTf6i6k8PhX0/OANCuCWrsKiBAtyeJIihVMGhJPg4b
# DATA mhSTSclypgQmVFJ7utk96qsNe3yiRvLWDjhWIA1NYbJv9IebxJai7BYQQXstVDranDd4KBvqoNvsnGRXbGxj1S16ChChahXIeG+q
# DATA ME2d6e7DduAB1NUA1FY4AHwpVdXSYrKetDqHhwSdiop1hMhULOeeonjDViHTS6bYGOxFIeFKsriUTBzTD/dNkS79hRZmOsuBFuAF
# DATA HwH8HvlmzT4HrBMQ99c3eSpZjTr7xfD/qTvHZv3C+aGuqj0avWPseXEEn6LO0xMczlY9+ow2tU3CnTjjfEdqpQ6g+FihdGSYb6o1
# DATA VkujmLRg/TaHR/cpl2MNoMFlfmheqHbAWVP7RokhZy5RRmayT5IlAHVjru0CybyvV6iqd0hF+nqFxN3XK9mgC/e6Sgrwtsnrr0O2
# DATA oNdqyauwxwPdsJJiByPIhwj0WNCyMSL3NAeDJdS90xCzJRGs+aPy4CgtVqg320fFwlnUu1ANokfQZTtImFU9T+ogrNg5kEuQQKua
# DATA rJZm1LNLaL83O10lG1cV62ksA0Zrp9Vte68u0qugvglwJUoYTyNXrRfyulWsZG2AEd1uDpuKpChYmpLNF2F6U4zSOwCe5rYEHBSy
# DATA BylqV9JABMQAm7bvMwVea5tUhce4kFC+BHKdPW+UwNMBNtP5exJ0QEQCUYTYW+KknA43RLHAz6YxYnuejDV+587VnWu3N7d3N29t
# DATA NXZvvb2x1bhzZ/O6WxyyaJPFvhSgqU+p7vbGHdVlrNRoQisgURRI4lL7yIOBJ6U9veXASOtTnFLZgLjNFHettGkq8/BSn30GjxCd
# DATA DYzpOsL9nyxMC7SsfY5ZD03MeBD/Hlcf/+bZ79A4F0d+89FKKhj4IXP3sDO6htbuZEUdS9ZIGQWMx8qM+PvoSYbbqUC3HdrhcLT3
# DATA KX/RmSGBUowaSnJPnlxZ+A70Pw2z+79RVfB0/c/KK5fWfP3vxdVX/0v/813pf7dRjjJrL+6umEIC1Kxq3+KNIlCfOLesdkvdwDDP
# DATA GJuDgFNeWpNfoAiSv/vZAoI8g1NPt7Mv9iNwJ5Aiw7b8BXZA/bfG+pcno/bJAO53VOF4qI6kfYq7klrBdwMO6wVdNaWW5RBu8q1C
# DATA t1Z0PSYN7mFrHmhBQRI0v7eu3rh17e2iSZ0GCIItypvWgqBfzpdDydMsAyRBLSPeIAAt03svC4uFNwaFKjuNzZ3bG28WbLBeB71X
# DATA UhRC7o1YMgpjVSykm1vvrN/YvM6nCsTAu/g2HswlwRpJQyAWM1r22TJOlTrA2+ppoTiJwgkvv/pqcVaPTE8aN+G0urrR2L69+c76
# DATA 7oaDeY1HE0+oyTXyip9rRHvOLTge3bTy+F8n1Q0+YRKJFnZySFi+A/gWfRZwKbr6g3AhZiyCgOUTuVYCP0HutJAxOd4QfKfc/bWz
# DATA S253TUnpMQWnMZA7j0B+wyBWl9cuY268u3cxb4pdFkLx+sNW4aAI+rCL8Ih/Kil9ZfVVikGzvyrOMx3b61sbN0iaWqBU7OgiYmfV
# DATA wTAx7gjcCJrjUT/iISGTSbgsPjgM3ih9bCc7zQXPZuFscZG9FCR2EUMb0O3BiVecBDvXVMdz/QJ5LuKzpTjP+g2Zq631d9Y3b6xf
# DATA dbYxz1tGoZd2q5xNfqc9GnEGed0+v9K5nv3aNAI4sgcbCk43J3nPmUUUMHE3wrsMOy2MJU574DdYdOC9sQ1SiPq9bZ60yRsVcOlh
# DATA V0MKYX+mpX+x9Bjp3nr5p83y3wNctfmzUSnXFf9ShDpJSbF3rknf2th999btt3Mm35BnkkJIb3VpSVKlm5RXAPfHJIreVvLD9mzT
# DATA k8ELBPL+9q3b6J9LUeDa69J2MbLa139CegTsh72PKcwSo465j/IK61LnqapCTlXDGmQbqjcVvLnZ660qQ/wQDHLWbAaKAingHKhn
# DATA 8Ft0c/JbUALl98/HbUp5Aj8Oh80jFD50YXXk6lYRHZdaw5dw+CvesPwiLMcd2Es1GYuO52Vqm1b3W7u72ztc8+2N/+PO5u2N66lz
# DATA 6mid7dCQdUmqVpx++/atqxvAxpSYRXoLyQ2rLhPr49Fxf8h30mqSXlUXasVmEBbKv/69u/7ORmN9e5NOGnW9QE/oaCk9EwxF+C5A
# DATA EWoKJsUU92Iv/XFZ3V4eNIetdgv+Qn+vVO2nyrL6v5X0Srzk9rCvuHU90bMKtyVPawmkjgIatEdjb+7jiuINfR3+vkawRV2IWS7p
# DATA lG4ZaVAh8J0uaPhdBf8L5S6DVlXdyEU1xKo1VK5nba1fO2wD45gxRwwdq9gnDxSArMlVuZri1VcRJeiim90qdYN+kBYODVvScKV/
# DATA T+xJTD8U/NE8gA6QXgHUriDk1ZYBI2Hcu5fV9urwAtgwdbtAw8G3aJGR6vf7rVM1mfD5hRq+ZlPWlc5hAZ6+traIqSvgP8UzZ9Ku
# DATA RPolFaueTagvlQHkGrw6BoVtBeTzAj5Xl+GJnmb0K6uhOxkltOXi6u2BkoOpomJl1Ce9FkpzSpgz00VOnu+9J5pa/P1SrZb20bKM
# DATA ljoqVNFL6pXWL6zPolNvDXFB71m3CvViIqjgydlBV+1BIT6kRxj7ZKGAxF0o1l7TxCzG7hotG3L2peags0TG8CVtDC9eUQMvcP/l
# DATA qfhwwghYNV2MDECDVVyRZtkAHraaZyq3vlXVZ7X14bB5Wulk+C/HtWfF18Wwzv9W+F/1rer8S+5HUE8x1l27SfUZlNtbrr9OGvG5
# DATA e7yUXsAYxPad25vXJIpAKmPtumI4xUJRq6zUuvj6KkuXRM6MFuqZxil+BLBkWjsFpb4kn0UCnv6UnkY1U3g4lBJVBqHOINcCJXAh
# DATA XZhpABGZbexHzBPj6b7UlPlqq9rKFeAy6L+EVwZVYL9d4BAGcw/gCwwfOoqvUIxxSRysWCTKv0GFlwxuw75h4KNph+X2+psbjc2b
# DATA 8N9QnqKs5Hz1r+y24WLfHJ5el5iQAkFVQF5JSYGGFIFDLtMV/LDfVQzawUqX2CR6VeSYZ1GJQTiV6TALZqQCRSjrNHIe1GzxiXSk
# DATA kfMXSzlq1JjIXuCVcDLGvIjgHqQ6QFtYpPL8uwhd/30pm/+0RH8qyHWbpH+xNCpIXCZ1YR0xftoHmPkVQtnKDCmN/tS9+0VNmXtQ
# DATA ZV3wxqA4/BdFJQ9tJHC5x5bBcbGHYoQ1EnWhUQs7LOiBmNtKcb7OM251uUyQfOXyQN0+8KrTZsg+G4WLepEPHZE3B/hcLSgSWGom
# DATA gbdcdC7EqVz7jNve5VY6zR39p+9FnrdlgerXr13b2NlpvKF2LIi3lM4N7+nEdkBPaPBPMOtCHvPhFhXLuk1nrfpe8eN2C3Ts9zGx
# DATA PM8JaR+vJNlxc0jeHwmlnlAc6NRKlwncz/JYp+Q7cINYMEn14sBEnKzKBSJir3glfMc2f1q1RpZG9r0qgAOeLEgWCajLdApYDmYQ
# DATA ygoSOkXdsHFZ8VseN4EhCbBDtKL+6BiAtnPqcXPp8F2+lOBHJl2HPTEVqAlwzuWS/5LOvyhz5aBNYC8YoYuwOc5SXCo1GWeTyYLO
# DATA +Q4Dqnr5DvdS6yKMF4azxUVhxRJwb9+VOcWdJAnRn4KmYXGRlm8SuSxbUye+wW7FhEVxlqLDlOq6EHQKY1e/4Z9JKQnIpsQ0Y45K
# DATA /96ontm95vcNSkY1ewuq81L0EDchdvfO1s6dbVAP6LtmqAmCDCw25JS8JdavP8LAuJiyp2QgfuVTmyzCyCpKswJHA0nPNFLQ6qCm
# DATA ULY/omSaAxxgJR0tD3TI1jPpQ8lqUV7uQbyXtGwOK3rudOClmsd/5pzua7e23rixeW03Ms327GJI25k620ag6OgqWqH0utR8Vb6x
# DATA 5r05GjWBewHeQkgZiJ+ccu1eYlNrHqQSngJ3ZPIy7OdkWsSa1TFwoC1AzXjRU99mhb1F0yZMcrEY7GY9BIwL49KOwwhiuRB/qDv5
# DATA k5DhF/BNSXwAOUSwuuByL02clAqHKdPiLWotIPMd2qsq+5fW2HKA3+2lFOkASZI8iwIhg5P3ISrN+APiCfUcWZH6BG2W5APc2/Wg
# DATA Ok61+J35/3P45zceBjTd/ru6uvbqmmf/XV37L///78z+u3PaO1B37x4YCyE4hTxtXM9jykQOe6hp56sgFzwDqo3yFQp8mCXk4ciy
# DATA 7vITzncoxtjDg96oKz8AnE99IT91WPA3akOGC/+LWIvf3vgJKCh37lxtbN+5qhh94/qtm+ubW+nC+s7O5ptbNze2djHyAQURSDox
# DATA TP+u8HqV3D32kruj+oXi68Hn+GKxVln8PmTjbldugkXvoNvMsuQ6bkc6asypo+HG1bwQQ+z1hyfgjMQcK9fWx4evfQ0n1shWPvo6
# DATA eS15ZWWV/CrZKQtye97N7t79wevfu/twebl89+HK4d2Hrx7WU2ZhgRXP7npKA22wap2PR8+MwDzaskfQk9AYYQVI5yrl57QlMCoI
# DATA mQvgilJK1tYuRs0T5x8gfEkj1JVUSA9VSDutXjPV50mx0oUkkGyadm7nTmQ8/1mA6pzwYEMcFtAK0Ed4bM/be1AJAE1gW2D1fQWt
# DATA uWlFZ83G8alH8K8aWItyFIFLJOQbw/Sq5i80+Hk5hkBF3e0WvCSyascsPxRv2AvvwV9q36SAaTQcFfkqMdQ9sBwxg9oRaCNsYY/t
# DATA fqol/hOtfpdWJvKm+Ppc7b0A1XOmQLFV7VXLK3UhY0obJROJliukfnkn69IVVxVYlrVlWpZKKpcr+E1XQJOByBn/Eg98vfxTNdhK
# DATA 4x/K9Qvq0ZL/rLhI0w7Joc4/UhbgkErIKGI53IhLzYCCRhy5zU6miI3b3CySLFFSi2voEWAE8GSePqvb0fobcGXffSuNbL9vwg2I
# DATA 9yggsGz1R28AVIu3VcG7hmeiGnNg1U4Oeizfqn9R4fwORsura5zo3H7bAywlWI2VMD2qKXV+36HV1ejFbL71xTxuzVHT9xmyhnAh
# DATA WSnamw2KF91hvhht8XpCfWoz/I0nEcHm6IL+kDxT3O0gvioVHfAMjPVeOsNb7d3bQpTXbm+s786i2JKd3j1GX80LOfQVcUvLJTZN
# DATA Sl9vFQM1NsqSEENzcI/bLPEzGFtj48dquNbvrauBSvQqfNvpHW3e8rZoTv/ubF9f391oXL2z8xNH0ymfnHba3RbzPV5te23FKwkx
# DATA O8AlKSsgMU51TNKkaSWcN4k4CJabdCUIWG4K5WSayp/2rVu7jZvrW+tvatWR1hdOSSVss2uTrDrg2eaVw7hNC06ZODbbeSgG5C/M
# DATA RBzDdaTVQIAoq4yLnbVgs0dbwQQVM1iQSB0ryY9qyDrwZRF+rVzKE0+8ulhAh8M7IrjQAY2OSiulldXL2lHJ9bzCZmMNWo3xePO6
# DATA zq+x85dfkF4k/fOZWVbJIlYlQSB8YYkFiGs3WTDIcFjXxOSRxi5SvjfsrC3+Itu0q6cy/iGgxZEpjEXjvFsbFQ+FwKRiW1Lu9Dox
# DATA BJ7pc3jt1s3tWzue2jbCWcLbXTSTdjGq7jtn80YcguXcg8kCfR0eY+4UmZf0e8E3JWjijOY9iFpecERI4r7NEk8cKhczKHrJ88KU
# DATA 5LEE4rgP9uqxphyvWa4nChLmt7Snf7j1wqQQCgi63wUZpO26IvRcwG/3CFm77ql78Z2TzxyfhFYeWlNpoi47Qh44ghBlvlaS0MXV
# DATA F+MHIgAZ7EbmnjyZTEViKVR9wNs+bTat1sCd28k85DFfWEauifOPummjpMHASDTuoueMp9QtOgcYV5LfimDMccE9dZ8DrxK+JdYU
# DATA N1sp7q3UHedzAZHbq8LlDzwVX1blXk5ftujo5+M+igZUcNnOe9KSxziQApYsichK2vVOV38K5ZVAW9VdYFdpiFZcZvVKarMVePej
# DATA BK+VBaxJrpHww05HnH4vLc7NWNzLoT1z1M2Vqmq3HlFYSDFQRuGkqnMQdWnfE+UTRjTiu9pKESffmmvbSYvJSlJZFGaRofF0wR4Y
# DATA cqQ9Ex5ddXd9QxoVQ2iJaTjXJGFlkpbLkXhUBTs47B9dWCTzptM6H2WmvgrZIwPI2+kMm+6UkNHZcqqPGWCn8HPLr8Q1zYYtHSag
# DATA fUUFNLRZjbpJyDxQmT31Rd14KtkpZpzzXb7ylagL5zzWmRSlMdImol6DJeejNuoDWcdd4XQHxYU4XXACW4c8rNaoOgFH0EkVRMEI
# DATA iBP7KehqQWNa8NpE8qhQFcQPhKMKniPxhf30pJNl6O/jbKazFAerRDgetLqoUOiiesQ9O24/lAYkTyKV77Qmsg+N3YHDVgjTo4Yh
# DATA AIykBTchvmvgxcncFswdNbw0O3eVnN3NYQX6SmYSixCyWe0cjMLmnzSIcO9bE0gtBDoXW5jDSixzddYe8UO8JskSoJPUACFPbssa
# DATA TGLaFvp2Lyxdh+qoQ3tmHevzS4xvrW+9uRFj7GZHSePUZ8ox5T0Lqc8Rd0/6LcCVaxn5/4XZ6TRWqgV9R5xdyHOMmcIcX1CqtTor
# DATA X0cJaaakey4m7YvC03hxjB/L3TFHpM7vev5JmT+WyqA/KKjm/VChQGqOevuF9eFBIXJIbnmdV813QKJKgu/YpwAvjK3xySDTLm/t
# DATA XgbORM3soNMhxXcJs173RrVVyS88h9siN4DMHOZ/P00DB4XYQYp74CX3JkHSixb0LFGZ7X/QWM4y5lIfd9CubLyPQTlYW7D2tOu9
# DATA 4kBmakpq2vDHXy9MoyTNR15oQNxv+EeH4YBLLi+N+ifoVGzVwI0LqtAn8kt0Yw4bFd6m787Od/6NX0rPc7DoFFmiUJRE56wfVHfI
# DATA WM6MMgwMzOToHL9WKMJp7nSE6nE1d/Ts66l0uV5KbwAq4tpy/1WAHaGUDhlphHIca0yiqpNmr3MIUginsDIehntO96JZqSTjED40
# DATA Wb855xUmJLT1INFzy/PjNZmuPEnMqqhoi0xzNTIJBHbsbUkfc+3e+ATBTgtCNGbq6l6KrRG6QFuKj1C7bhoomEO3GG8oIrJa5BMz
# DATA AeLKAh1Z445v0PPIIlajOfOZ00acsgpxmmBkb6490CgsTK/dTObsL3mpJK2aq7cUI0Yza2/gnxAHGKyhUMcQ3NAzJTdzneddKkJl
# DATA sjhXNU9W8GZ++kGPttxxj1T9C+c/2GNzO/fiGOOqxVT1NWDRuS/8rwEJ7vj/nXSOGN/vG3UBnO7/d3Fl5eIlH/9lZXX5v/z/vov/
# DATA fe+lpXE2XNrv9JYgaGJwOjru9y5ClNitAeSdTzgzKoSONnsGLjPAJXWgIwGL0/MKZHe65vAI/e0WtFfg4JS88UCTATtXPPHkNwXy
# DATA /j3cBr+2G2AAHwMpCwRJBrz8ZvsF2l6ECy+cmSoKRdNq05SqE83E+BOn6zb3FdsLkRCuMQCyUaXdwJJOzJdttaWKtNW4QgFLciuU
# DATA PC0V8MpWC9lQnxLQggCWwdu5q7E+NXfhGZ9KqIT5NLAl2zpoju+3hliDoH8HjOS4OUQ8klWNR4JPbEgS9QDORJOPTK60MmT3hptv
# DATA D9DoDXYKHCf7DQ/Ht+3OxqPgtov5jYvBac5FphspWZ0YToPtFiV36rVNmA1A6hdNppiw6fmUWRG7z4GlTKtZajXuUk1n8eLB1vjf
# DATA UizmThvna6yOw2CqO2pn1mAX2jeYouDkSDhNs9tRYlJmNpofdJZxRCUGXr4wWAo91rG0Ek7xtbazaGExwxDqqsV/lLINSbSDuess
# DATA FmQ0jBhCgxdjJ8RCeSWub+0AyIpVJMTDmYbFUpo9srfYKZbTChoo2XPwB/qqrm//olqmnGvktO44RTu3mm/CBTkX9OTMAz2ZfLeg
# DATA J3M4EtKzgul6yXVWZqIqGVdpMAmurV30Blwzftc4VZeXi/nWE52yKIdb0PpRQrtRn1IQF/C/FkmBwuy+mgFg1O5uLXEY93TcnFL0
# DATA PbZCPedwh5pLSO4WiQV8IlFq1ilBEzmWamMc4oiLWnLmtKc6h9FptK852E3CbDn4QLX4xu1bW7uNja3r8oxNvPexn5C/feL3qMdN
# DATA Bn3SNjIQ6RpWlCDaH16cDS54QYdZm+f7BTgqoM0ryQyD8gtOP6mZ7yXXkWUIJlrGvl/Ng2E/yxLMUKCDvXUI26iPgOcH6FuJSRq5
# DATA sp8BDD+8kk841pYwCNRzCoLZb4PgS76cLcJHb57sd47G/XHGcbkcRZuxJzN8JRpKezIgQB5fYHnrWY3pkQLe45djhuQvWLH4Baue
# DATA c69Z3v+wf0hNe+TE4B+sHGcshyrZTEynIusWs7LowGOz4YWW9exO2ViHcVQC1/Vaj4J5qD8S5j7xmNBA/W12mVoujXylGwHWBaBZ
# DATA 9/Oxu6KsW29MZ4zsWSpw6lnAKTOLVdbIJk14/w1IA+D43avdMu6OjBIwaxOwouqmMVIb9Doyo3ErdiY9wAWdQ7DZxFSDjtT5Nwim
# DATA ravqP+ihwQ+rrAy5UJVcapbrlPDx+GBY6fSXuv0R+FEvmXDhAA7GcXKxJoFIGdqasbLDthJAOnyPcju1RJ0qr2jPn6o7FtSk6c+1
# DATA iBB20gl5Dl9PZlMfVD7/+YluY+aHr2c2SzyT7kftE3BQi91hvQjyQgA+IHgEcm/UD3TgPAWSQxuhcVjewEJCCzy9QMC+myGoTlst
# DATA PBS9XQbEL2pVqM3xeGBvDCqF0cy1ruI/rSY2XJURTel+UXuBE1QIBBsrsRsSXqI0UrNwN9RPf0+qR4W9ReujOhnCahQ7ftAcQBax
# DATA Rn88Gozl4Yhwp2orl5c10+Rx0rBAEWomyMoxyjH+JP46dwpo2rK1AQ1LDqYkHeAtkjEy4c8xyr8MhJKN+vQT4VAEDAUhXiZgd2Ho
# DATA FMvblBLPoO8X9prSNGK8kwXE025mBNxfcBMepZDfbXxwnFg3BsgM+fz9Z48BJyl59tXzD59/gOkkIfvk4+cfQXLI5NljSS2ZelDz
# DATA 4EJ/r6dYRXLYbeKIGcHpA0zpy1IHfyzQTwjM9Ck2+x/PngJ8E7XiZaQM24JMIeB+0wfYk16n3cIGLXio5Nln6vu/YJ7LfwYQ87CO
# DATA a80eQ4wCiJHIONzRVrN9guaxlB8gnJWNP/UkVifziCa7OlmqHvz+c8yB/D5m4PwQ0K7UzMQTf6oXkYkueiurqRHtskCMlKGQ6J8M
# DATA GUQBiizplb4Od3pCRPIICI3huGzwLZmAp3ld/XVik86zR6mfLFQuFGG62cJh+uxfKBW0mo5Pnz2S1gpnestNikwunyHCF3Tsl5gy
# DATA +hEA45eoV58mZ8H2nVThIYx/UknsfNSSmv6x+ucxfgzIYJD59PmHrjOu2VyKWRguhU4iwHAKhNGDKhbbNSuIBQkhZTxnrVhQCBh6
# DATA Qw0e1mfKNXsHx+6NkWcbVrcA0/sI08dCiu0/zkZHyyF0R4W25/vLDJwuSdyzyx1JD4ZBazgXbgBJsW7Pgi4qOjQJbYQXhaJjqgvU
# DATA a+7w/7uT//ZPmgN9rYlg6tCQVqVEhsNoVrTvy6zCieo9vVPRYyVWJYZoSIFu9LDquIN03TgdCPQk00EQl0N0Zd1Ly4f8Jbwr1uuC
# DATA FcLWC4pTapA1kKGxUFnIj8jA2yAvRJ0Om3Odxs5n1Vi33R7UCJkb/jQoVvYmMYaHWJYFiKQzvxZygapN73kjkazFYUp25TfFgmfi
# DATA lcIQLdhhwWZF6YnL6hUzJfWjqiPx+TQ+NXgKU6fUQuZSXMgLsnGlJSIYhkBLF4kkRfgol3v9MqoGBpiuQD8DiDDkQ5jPlR4fgmsi
# DATA nlnsIQIrDGKXb6zwxLgFzzfPcc32Qm/wrpO7Z3+rduofeHPSIenu1khCk3kElgUbEx+5qCHzYoVyHcBp6qLhz4KYd7xiwWJXaSmK
# DATA hz/Yq63oq8wjAGr8Z90puscp5+typXLeoqtfuj/udEH4Me5+5utzwoG5GjwfEGw2RJtpmLTU0qZXcddR2kPNnX5FX+tEhV2GbGOq
# DATA /sgtcLLguG/hQlo8qhh6biG8JeimxWyKmQfFcloZjw5wyQ/hSSH9wU9+cPKD1u4P3vrBzR/s/JR826JeX3vVy6xoOodrFiI+JOIR
# DATA Bg5ZFIWKe43mkV0qaPZIwLCCWKNzUkocaP2qbEKISraDOauJJrXJQugRgp0r6R4UF6Y5klG/ifTFmWy+L8Vc4X5Lv5jfidbGmSn9
# DATA 1Jottw0reZ69+R40s8aQ4DlVhUYFJrieVq4EfTFvYKiCx2TpFlcuN+mCVi7/fNzB9Ll6voVZ+kFNdr2G8ZkORBi7g5hpbo52TRZz
# DATA tjUq7ngdhNFc2FIOyGDrRO8+gYgZn3IriYTpv3Zjb5WslAcWLqwIucEuZXO/jW/JWoNG1XNetjtjQ86GWJl2dzy0zBy/yByCcd2o
# DATA TLV51pMIPmzMBGKJ+lJjdSFML1dx0IcjgyJlpQYf5omzNCDVfF2KOcnJEEJTW53pN2qN19u4upIISEhAyzNE5UBXlCMIR7RkRs41
# DATA WTjrMwUj2cAyNcE8wAg6owZ3WlikRTc0RaFoXIytrI3P580bWg5UqftRObDkSr3YjWJwi9IVfS/ZGfUHA4QhOxKo14weVZL1RLgD
# DATA ZqrqZKrPnL4VTTfqspsgKqz4K6kZfIg21utXK8HaUqe1SgsFy1ZbWKX6IUJKBOd3UVFGuUURujbXQkXmHn2OLi1wQwq5rK3mtD4P
# DATA HTsbqAyBqJrCpeViPCI6wvb10F6Q8TtNfKO83j9TaMbOwvim43azi+HR04+Bt7CY/QSKjLO4v/B8RwpZ6rgDoA8lvpXSk1NfYZ9X
# DATA f559BD2iyaYCgGz5fDngyEaCxTqQq872muXbyb9q1SXcM1h5iej1oEX4ErRnpF76ii8xn6HubK6EjTN0EmncGLivtu692DLJ2tfU
# DATA 3uzJrGPE29T1k5UnHXZLXYxIG634UCtv0bxJ+v3M+5oB/3/+S1DmJbbq8dnnzz9Knv0RLnX4iMH+ozOAGobC6jxw5hHd0Ieolv3z
# DATA s69AHQia2S9AJ/sV6qM/5QF8cq6Vybn6z8G+42dwo9s8hRQZpP345pUWzDkWF0V4N0f0GxwZEhvSxJWYQtHBVivh347jS44jvlTB
# DATA WK/62KVDdv4j1cDeulExnjz/n3hikTs9aeLg7lbQmFbDDFPziDdwZX14NAZ2to1vCmJFVGOvNRrq2Gg0itaXYMNrNPmTQqrV6ISj
# DATA D/qGGpBJdtBnpP1MiStikkKFoMgRpFZsd1ukRqS4KBKf2O4Jv8isRkYsVi0RmAzau8SQjSw21RFEZbgDwE9JuoKmXRSb0ACGGU7G
# DATA w66tUosOr4w3c+zllEkolzEuBcLrTgftms7IhRa7mnyD/8BXmbm2wa+KZf1TnFTPXZ7MTN/gtJRs/wOHA2Ah8qpSp7kn3eFLy7zs
# DATA OiYgRcs9Jd5HXlNLDqel9/kQfkrL5chS+BznTEcgsjZ+GRxcrdc/Qt9Xrt53zwgOTt8CRgfll2gBUmz/XHw2qg2mARluowvmqoJB
# DATA MqLe75lh1actLWc3tHmac9qIXt0uTFXThQ7/5psc/u1o2PGJvkvgL61r11p0Qz0NtUvAfq4WrYGGhUYDKaDRAKbSaKQR305iN7lu
# DATA iDr1xdvt09mJL0BP3/bgVYfgx5M++3c8yp/Q6T2nxcUx84Hh9koSsUmyTrdElkdOAoR5q+FE/+r5J9AIVEYWSzjk/wS1Q/uVRFHi
# DATA I+4NZB7Cpv//9r71uY3ryjOf+Ve05fE2IAHgQ5ScwME4FAnLnEgkB6TseEEEBQJNEjEIYNCgJEbiVuxMdmYqqUzN1H7aqpmp2d3a
# DATA z4onThQ7dv4F6j/aex732bcbDYryJFlxJhbQuH2f55577nn8zmf47idoKkMZTsgEKNKVAvHaJ5TJCJTRf2ck5caePQfaRWMRtgkQ
# DATA r3DbrEH8A1nlDVI8o5xDheU/jwipP+8/S+WP9+grh3/Pjv9aXlpdXU3gv6/cXH4d//WfG//V0DDvmKgjmhACB2n3E/Ff8Tvi7BS8
# DATA /KA/hVRc0smBhdE4XwxYEjVeZk9ss3+CHyn+8hFhmH3xjz4+bC4zMvbRH9epsfi16k0ldisZznumUFeyvOBZnO8DYEV/ekYG3KoF
# DATA +WzHuBfC/aWw8qMRONBD9DTcsz6WPu3k0W5qPUPDoUjaXYtFjWxkxck3qyurLYUr3R1NAEFVwwBhELr2aKW0bgYcgsJXTVib4lBK
# DATA x/RSJgCpmRGGcQ0a9bubu3uNj0Ib38lEdqJ6jwajg0J4XWK7Wp7J0iPE0/A8jRseA5YcaQePy/Yg2SQqnTwLnCdt7l1of327sZFM
# DATA yAw1ZULRqjVLOmKSu7xn6Qxo3AU1DnikXWmkk7167plQr6RtRIQkMXdNmtkhXZ1saDbobmKk3ozi5Ar8qPMwKnvtoQTXAQUBaJ+3
# DATA mLeDDwR7gjxBLbRzw/bvDAmvC25a53nGqO8TLzXQ7JsK54YY9v8GIaQMrFekYAgEgMqMiwgWNfMW2YRLZhQLxZJe8cNYmjS9t70N
# DATA 8JUfIVHv2m5RVIeM2+Xbso1Bhkdop1dGH3PtYj06DMiHlMwSJ2i6YO4tw1DEfTR63OlKipVJ64gNO4DgWRtBEX3bcS5DdmQ+9/E2
# DATA DjM8N9pO3yU2WKhR2kMduvmZENZp3bHuepI3sE0B9pJRvbWjEs2aLgUlY8OFxfME/8KXvdEZhk2i34sN44pl80gxsMj4h6IdoDAU
# DATA lBxT6o3bMpzZk8e+Uz6EoOEnyyul26vnod8xEWrKy8LXt7f21ja36g3A7Kxv7W3bB4ki5HlsPNehA+TCL6aH1Iha/yDmY/SIsN30
# DATA AiymcDwMBu2PFjML+tT3KlZkRhPzhJScJ6NiUd5AZmVxLSPeIsUIo0/HOYJlPGEx4KVPE2poeGQcgUGoWl1mLEWuGB8vPJBRZQVy
# DATA 2wliSMYlNVV1LTOG07FrePQ1Uk1TzAH0bM479yh5HpFrmQoYD31oct4xshNjisfzgg/OBj1M2EkB/mExPz73AgvqTeuxSPgNU2bK
# DATA FCc22YNjncyhko3Gw6nxxGGjstB4RynRSJtkD7mO7fBQU6IVvU7WNFMp40ikEk21ryaONgXpgHl2AMgkzhp6qniNMq4DXOa0PYor
# DATA MhdqODR11EkIQszLwpJ3Z1ooZmEl5k2ZUvDlTDFjTWlmyPceHifKLy8tLRWL2fCJ2RO0/aE4Qvy5kn3evzlyExdzgrwTs2vacmDL
# DATA cjXkMF0hEKBD2LkrZVAVCzOTJefSHvtkmIWFe/W7a+skW1Ka891XfP7lPQIlhgKbYzBQF8VUC0iBh5KSXU5nds1xWiVnQgIEn47H
# DATA eFme0Ym0ntJWSO2hDVg7s6fzhpsWFRbFUWQoa9qTSIh9cFeQnhtV6Y4ofTqyPfCKSele4wUo97UZEAXpgf+Oa5syQWO0F1i78czM
# DATA akt7nhhwCBmZ6nJEOCsFVtu0NRJmtJQoOLxZw8uYYRiGI1FaWrQcCDwuKlNOQVr7ROogJ5Wq2A51KiYT5XgKqCMtjyrKPa5e9oLy
# DATA ii8nl7mYXPWlxA2FP9TuRJYwb2wUcqkzXY42ewaGVRrwk2eKRFU5MAZsctbf3nB64Yfn0bJA0n9oVvfUHqCW+z0Tj0v/WswXqe7l
# DATA 8flc4y4RkW5yUEcxiYeFvT9TZHyYY2dT5unKrBtH4rYxx00j/y3D8vNuJvPRzHn7SN48YE6Nrw4/o7wCdJvwA25f5iqhB6W1jJPC
# DATA zMuFc+/McbV4yWvFpa4Uea8TOa8SV3eNyLwcXMEdY/77RYpboiaPhZw3kfy3EA9KiIkkoa8cmP/C1U1rPzPxo2ClaYI7uOZFvXhd
# DATA iWOoypwhV55fLYRFSU2v7LJGtSD5LHJFMhVrmwypJcFVd9+U1rRmKpfc5+CMsHwi3bUw/2iWeIHUdH/zbmNtb3N7q727/aCxXg+t
# DATA QFvpPMXhR2OCuNFMXaytLk+P3PUyuf0Y0mwQLJRltMTTDSrXenQuaZsF+WGC0t+o5eDaKROA20mlf7u/uXt/bW/9/aQFEXTr3L7g
# DATA y0jcdMBIjzBaHUKEzb/67oOSsfTQRi0ByQItyHsiegKy9UW2jTrQtjbNWFhHyYxu9JKZGj1FEFpBKQhXKY/QSrfaDZueZqw6KS9j
# DATA ncPAHUs1IeM4FqjsOmfuBkjcRkbkeqO+Eabjlua5NLlIOHlmbbfe+GBT7cI3UaCIA3H+o9mrTMhQ0vJFp3kMcXBiCoKDyehRjMrr
# DATA 8ek0riwkJJumJ7Dqum/jtBLpJH0a1tmZqS9hwncFgpSzSmphxAOZM48BmttCJgcioC2RRFpNA/EwLpp6JDmRbXXGvSbvJ+wpC1by
# DATA O0G2mBuAcwUsJCWVNFwRY5JrTs5Y1/MfQPPoS8s8HrivmNY5iyLX7t/ZvPtg+8EuLcneWuNufS+cL0egMXadKHBJBsIneJeTawsF
# DATA B6oixAjCqieCUHkCaCsSP8K737nykTkFQViIAtze8PTkQKkz0GKNfCRgYDTGYIPW31GwIhIRfBxNAEchRkwhRBzDTYlBdqAxUmZr
# DATA 8DjCbNtKJMcecNu5tRJ/IsoIyxJ4FdoIY1sl7IpGY8zkc8WrwQyZoGwVIatKQO1pd2yUglU7gHyZwyMN27sjlk/cv3FvweJCj7gQ
# DATA dIo/xgwdbBnmRGMlXQC8v3SnM8ApoUUTApSzi7Qk4Gf/8DBC9czmjq79BOJBAawz6GA/K8EWnhBCnAM67gwNd0XIERoBXKGXSTgy
# DATA pLO/tfYlsb1nouIZGoj0BmapD6RAat0umIvwGekIHcaP6OFZUyWTooMuZvbQeDWVh3EFT5TPI+sElMOjs/l0rYlILEx6l4yLS7vm
# DATA zwSkUjqA2VqP86sRoN8M9gSfVAsCG4ycfCRflcsH59XDCFnvJD7ujwGxdkhwR/Ki1WP8yYRlyXdamLPqPTN0Ad/JkRPrK2k88GR4
# DATA hzCPDoQbt6cjpBaDFHKaCfSmuATS6EIKjqey/bCxp+Jaf1Tyd39K+rSE9jXy0zKejCaOrVL15Y057UtuVY6crRHB00FGUzwLi8Us
# DATA XucVRJlhSuouQnbhS3jXEeV5IPdnAePzQxtmJ5nZzMwqQRRMj83gVXpUoH8oOyr1ysyVbIdM5fEnBsge5NOQN4q8fU3fxJcQ9/Qo
# DATA pJgnHeEM113zjJKSSHIts1AA3Huci/7CQJPUSsa2zWkFeSlTGzd6CRACAplhCzhdpUynTtcyJD3Mk4dr8tKTuKQn0pRKaRaeJ7ZQ
# DATA Mgqe/GoN11fj0pXSB3rF17AWw6RzRAlNsh5f3llHvvQSNZzNEsYNjRRhEasN18v1eLFnDAk38RKq1gwnz3TgB0ytqwvyY/AQkZmP
# DATA 7dHzmePt0eyTZ6Y/SS4vEj3KkupQeDrsPOz0B50DwoAJ0/TRV3KdTFdTU78weSJ1MOTYcfHoYDQamP7p6kqSUR8FV1dpnM2quOC1
# DATA HP91rFV3U/+UVa32/0kl+3MPSKq6RXd6Z4xYo0CWVyTkCmBJcM5dPCJORoLfjYb9Lmbl5vIE2XUMgJaJQt9VVfhAtPzbZe6tYvv5
# DATA 27dDx7O/EaGBV/+e3DBFLW1MdGkgJBtYI/F+xs6E2hwwFS80fsqQrHqS/bD3fUY3bGCRLHassUAlUkemenVt4yPlI8SnqqXAVtHu
# DATA WmetA+C1cIcwDCa8dmQ8ktxsMBLX6fz66u2dOllDbLV1Pj27BqOweix7m9IjiqfOkkwAlMIWThyJpGU3iBgB1J4ErsBGsQJx2KN4
# DATA s7y0pAAxuqPBaOKp1rQTGySX1VfVC8bSUOAbnj7KBZM6n2JS1ErO5hs1XnFT0JJcSVKVCrowT2lD1TcVNxbS9IEGT66uAjdFo+0U
# DATA QlEAXbE/FeVYHQhIWWBCjMag8cHMpVLZN0s++KPFgLWhXzWGqQ/V1TSqeK5csvBMOwubOUBbsLu5dVfCt6LmXun7TFJkddc2xjGC
# DATA 5arXGYCRiMVPMA0ioiSuE4e1xJVAanWnx52poVeApecaMWYUqIBUEkegCkM9w/TRqCwJQmd0lLaWjkyGgyRRYVzLXu8MoZpTdQVw
# DATA V1qXxUhUEb1qEwJbDUAwxW+hlFdpBawhUSibupTbwYWGCEDHTaQy3MfIz58kLNvcou0qg+5NspeecELrN60KoG3jiE3mlVrsJ9po
# DATA NfcSKq6GwZP9Ie1mzM7Lc5K4T1ZvLi0v7Q/PzazjJyNxKaXkSjTYJg+rRV15KMj/xJo73JCguOcERaavbAmz9bErL1UAwDJ8IoKO
# DATA NUxNQMTlGSMH3yDMQp4wu1Ykd653MZp2F7HcoiYQUtEBOdAQi2aKGEU1+jO4rtCw7CXU8McYTCx4V02mAYbG5bpodqtqlEt+JUSm
# DATA KYF3uhTOuYAG5gE7RkenlJOMQbZHfstEZhHUELcp3fl50cmSxW9alxnMjdQ5kd5QJuPyZO9O4WDvr+22N+o79a2N+tae5GdSm5MD
# DATA MjotQz3lpjeiBst+tGN/lvo5sIrVXXUOGGIXbrilo1RxufRSVQ3tb52PUcgRdtoZMHgXHecAXSm490jcOcUF7h32WJKnZCBmyPRX
# DATA f9PO4BGwBBGcQKYyUq7EcA0QjLwzDIxJxHNYK40Vn4Bet/AGeKicpppGHiJzHWDWoZpWajVSoIFawuEonB9hWaMOZb+Wv/xsOObU
# DATA N21AZhsRjs7d1JDcfGrAS8T2ksN/Z9CmDrgRuUa3imTBUd+Vh6KTR0nVqALtU0J8dXhvVnX6vvoEqKJqxubyPtNBuVDivOjbP+fs
# DATA Dwagpj0L1vo/H4E3lURyI/Jqdoy5BB2ok4IBruTHHHNge1N2RwYpS1hfTBoaqgzeUZsdtVxgQbUOKlaDPL96nWmUIEJvd3z+ZCbf
# DATA 1XiMXGvCGJdYdK8WOzn9fD++njgK56yH0lfh9QFDxpMV8smdg+LNdGse6i/mMjw26ve3xd0dtQrr21vvbTbu1x3wDXtzVx3Xcdrv
# DATA 9hltv+EoQQ/9cpDPOxyzVSaQMlrWVlbyq7RtcprLTAgKt0fqZRS/pSFcPuXcmUdRSh/JuJ6zKaNzmjUU0/FJjfKS5RQzE6s405fw
# DATA Z07ZGt5YWZU11hJaANPSuU+FQi6edNSDYmpcLdfoIaVk3yF7LcgSSNgmhRs/g0EoKeS2vLMOeo8sYk4e5PqoYq/TNChX44wsGVzJ
# DATA BK4gsBQF8IlabnkOSH0xq/c9sK8QtEMM1M/NZ8HBeveyyULmmYoZ+9uVL+ZoxZpHpx4XvzhFNPE0YZQ6HdJFOxG7QZcZG72AA4kS
# DATA Bi9vJFXmKHmknG8CrQ6OjTrd58ofiTFTsTU/cm9mSIaJ6puN6Asz6aL4mqEEmuqVRQR0ib2cTqfy6Dc4ZTWR9ksxxqp824ZGSgPj
# DATA 0BJxTmnc9ppy5XJFoi+JAGb6/CdF9aLdDiuaTLh76fUuqzHiAHwIOwryyipjKi20vG66hlK2KDPqOG0tS8yptUJ5pxPH7DgqCYLB
# DATA AvHC0xXfYabFd9TnIJ5gVxoHYrEMOpu2Uidn+CcnYmoTHjm5/DKK8y6s65ots22xzdUK7si3K2T8d2C6MotuQ/R36IaCkOPY8KGm
# DATA E+uI4V+seYBnFBEG8Vdx/8dR8JfB7Vu3bt6exxu9vvWBIQtpp1Tw5OiDInpQmIQ/9ISB1wpGaEC5dWO/kv29+BeUcCVLXwexJJX7
# DATA CcQk5bBZsxw2zWVyHDTtw4syphFdy3xg6w9299q7D+7srjc2dzBEqFF/sFvnsYE6hKoWjGN/qCx6LxcOQ3ZPJwTGjGfnuCRLZreL
# DATA F7VULB8l0zv/yZppcqgWaRn9uei8dpUsGztDTGggTfMCkznR1u5ES4VhoncDxosyhosuJDrUjr19XZ8/Cn59uSjqfLfMlAC5lLlJ
# DATA InJwZ5qyI60md6DlQFDaO8EKg8qJpDFjJOKOvFVf54381w82dYSTPyNYapcgFXGOZU+4PkmWI47LaDJtM6doM1uIk3G1ROyll0iV
# DATA 59oi0uXEhHLb3SrnyZeTDK3JK9IyEt0o+7brCiXn4wFNxAdUGy6ZB3g9mXLZ8x4v9cb2h1uCbDfq7Tv3tte/X98QsyX4NIiaWCt4
# DATA f4PhE784Vhl/Zkr9e1puyhSKSdKFTgonjyb3PU/RzAR0xMR1YWZjxfT0a3P5saEswYMnb1t6XHKHorpp5G/j4+EyGe/SavflPaR7
# DATA GQ8KrX/5sjjlsUb9EVmgsnd3jk38Kmwyl7exzG3NybLJvKKUf2/CSUL5OuNIrKL4MDh7B68sRjCMjOWII4gupl9HgwG0F5A5vLLw
# DATA J2+x8Nljrs4SdvW2rUva1q7GEmYd/1duuUkevdevF56EriFH4jzPOp2QZSaFGn1hANeCWfag/KkgL285uoRWPNPO88qTZHld+mZl
# DATA dTRd+uazvsxv1XkZY0NulXsyZV2G8jgZEJBUf1vWHvu3LPMRV67MQlhP/tfTTF1zTXiKgcwAQ38J08/ljCAyDR+34uQLzkxqdxXW
# DATA jcsmvHttGcmwjHzT2QBTGZ2ZDJDo6nRi68ccQV9HrqVgUFKpVPQZDh6Qvg2ujq3gNlfU0XOG07RP8528kSCUgdLwkUNnjVwqRo/P
# DATA aqGE5Qhn427kBNtgVAUfosLCVd0Zc009B/RZangbBCVHzCwwYnseKp1h93g0me2CuLHZqK8D/gJ6QNTv7+x9pKMA+zK4fQ5NvGVT
# DATA UFKdBEQwBiNEfoQ3KxqQotjOS/QZNf3gcqoiPBTpKA/SfIEcje0fGJUSSRrB2TLS1h/2avelpn2y5Ujd+tIGun1/bTOhaEOra378
# DATA UdID9wdTuicNIPK3JiqoMBqyvHjyKqJOXq6ojFJFe5CxRAybmbyFkZc0dmcQX3UvMldOYgeIlfsrQR3t+g82d/d2w8RWJNUNs5p0
# DATA 1QuxP0vv0j+0hp+kctNfdU1HhEwi5olBZ9I97j+M+GbLdaHTaDAadqN3ZHZ3Q532ZnA6xLD/SLfYh5wnnSFHEURgCqC0JwcT2Pba
# DATA RZXbS1PJqI7N6SBsVJ1LR5NgC9kh/s4TYHsm8IGnmsviQrk4C3hOyElblFf4U8uVSZfPHnqJwKTao4+NmdAvd4/FiwV8r5iBYG0l
# DATA IhNF+OgQfR0POt3IC1JdO55Ox9VFDVNevblEgVq+wrDMchtUJhrk1qdDStpXS2a/LTiVJ3b0qRFbVwW/IEHzcRm8CscRhRYKMRXV
# DATA J9WgaTkzqKaKjuI9HCOqjSh/GC6vvF1ZEv+3XH0CT88xwMPV1BPTgTeeOFAHJG6VJ6NBmnOEW9Po6IjCcp+EvUkfc/2Sia0sdUCj
# DATA sdQfPglPOo/LYDiGQstLJ6SDfFzm8YY3w3O3AYqY7B5H3Y+xhqmYOxhquH5/A6VLQXXIU/G/hxHgAFzjddeTAbOwiKZCISsvUp3X
# DATA ihXBfYaFSe0vZbA05hudVEYfv7tUXS4WK12EFSgUnRLiJ477FxUKiQa6fguZPIfl6geCtwGXEg+WVyiUcjJtj6NJfwR+YOHKUiyG
# DATA nHa4wow35WKJa9xMWAq42tFH2776RIZoJ1xgaFmS60yx3bprfBy4fePH0tWfAQRUXmpLbULWU+uNJ+oN0Ytz9RZ0CXK/wGJpbzke
# DATA Alegu+bKFmnKWmsj6aggKWZfLmqqmBigYR6WcVMWE6CH1RUhnYz7wyjMwQ8kW8GJubu9Ub/z4C4UPhEz14cr27Q7ri2FOIGSFYTf
# DATA Xqp+G3nd6urNqvif8XHxtDdGApahXD5Wo2cInZmqvpCq6mSkxMkyxG9WF+G/+hlNSnWRVcCW2zVNl+wCTZKuSVKEWQ8+O5/FjkmO
# DATA Kks5StwTXM3+q/EbcxiX7RhbRRSQQpJIHHQB1309uS6e4RUtrAX6cP4S+DKprmymMi1TD5qq8s+hPO3NVibIe5mt1vTqoHKbw87d
# DATA kByCxLSx0BimGJOCV/mQn8SIhiOz0VbWJkensFt38JeCxGwDXUG7LVav3S4ab1YEfbc7/EohVKHZQLMEF1xrhkqVXtb4xYQugn7p
# DATA IWHQTPm+w0oMbXo5nUSKJZdPJwP+hS8CZUDUxsMLJCp1bCtHQLylCHph3AO8RJY52hKZ12kclYHv6G9UE4lFbrC+PAV9YAOtjJkp
# DATA l4F8RWkIH63toPZLem4YgqXpHW57voQozCPkXWqmWGuK7PnQI5Zj7Z/Y+TOpqsdYJxtUaHBkOzFRCvwDBAlU+8xC4nq05mNZ/AdK
# DATA xxoqCVPb2ygAXkpx4RHQ3ap3ejKOC15kbKyXlBv40QDixu8mn4yGsSCvdifu9vuMjcxi/CCrh1Fo6XzR3o6FSb8mVgB9mPRz8ijF
# DATA qN+XdM8x4VJN+1UtcHpQshVd4ESISiu3P0W1FupVx3inp14inM+aYr4q4GdlnKOXUr39PIOasRa4rTOoQyJXqd5eZsFdnpHRnos6
# DATA 7M6SoWqj+Wa9yCV6ZbCtjA4ZQLduX+Dh5RvWHNJE3vC7TuecBf5mEGZmPyR3d0cv1dbztWpsGtS/ul0xnHCVFsuYSFB2hHhV9dA/
# DATA y+dQJNSNU4C+oRHPHq48FI2Uv6zrTywsehv28m7E7Gb1AVx1RF+wWmQ3PT8jmtUV68RPoL8rL96UbhXT98mTj6MzdiDCYCwrZMx7
# DATA 2BbPL7F39PGcRPxJmCSSo1DTKa0TzaVWdoOGCJB2rTTIXTp8X8VqafHLHaqG40lbJ1mzaSSX0FDZJKfBooSoKzrWRotRu41dardh
# DATA H7bb3CNY47h/NDxFRMACfOwMKrubd/fqjfulQH9//8GOmSGdntM/BaqgFHAOkettcRM702qWpOsLyd4Ll/b7JHFh9wzy09ehFe3F
# DATA CcqV0cNoPIkO+48zXD9tjFkrv6xC48uV0dHTPXEVjjGVtwtTnC7ViB5d/HNw8YcXP7n4/OI3F1+J//4uePHJi0/Fg2fi6/MX//3i
# DATA 8wCev/hUFLv4+uLXF19cfPnily/+ThSF3/8xuPgCfnmGL3958bwSXPxvUeaZqO75i0/h7WcXv4b6X3xilQvg/6Hh5xefXTwTJb96
# DATA 8XNo/G9Fkd9dfBms7WyWxdOvRV3Q0rN3oF8/ffEPUJF4/pn4/Evx7ZnogdPhZ9hhUf/Fby9+jy9jBRX3lk3q27X19frubvu9tc17
# DATA PCH/Jur6WnTqc/HvF1BbrnFzo3/Al38nylOjgVndi1/gjLy/t7ezW9bzUgpE8a9xFD8VVX7Fn38hntNrn4gGf+mfvWcwe4E5Uc50
# DATA vPi5HMAfxNdPRClYon8RE0fFoLNfqO5bc/bi54k5w4iT9ntirtr3ISjlDtiKNj9Y26vj1P2flMXDAYp+/wa+ymX/CmZAPATKewbj
# DATA JQMLDg46gY+MQS7dXloSXf9fslo54/j9mei4GHGiw9IWqTuOHXVI9OuLX734uVhbosF5yDLA7uGk4WT+nnv1Kxzv5+Lj8u3g+/07
# DATA qR3TaTE9/UrbOr8SH34L/fypKPe8hL9i818CYT6X35/xNCIBVgNQbcfVRXY3jB53TsYDdARMdA4plLtmMYv/QS2IXglS/Q8gHrtn
# DATA 2NjnYjZ/ig1/IgpjXWLd+NUvebm+fPELoHS3AqTRP+BIfnHxW1HN73AmOqfTkdnL83SmLNkgek9pDi3kh4t/FTXDMj0TXOJ5gnF4
# DATA dgov5m+RAmEn/n3GthYf/ym4+I1Yk58gbX+JK/GFKPWVIJ/nF/+Bv1DbvwR2Jur6ApdXUpngaj8XVYouwK/iN0GUn1bg0PjWn/Hf
# DATA dCBEibNX28aS+Lu9uor/ij/n35WV1eXb8hk/f3t55fa3gqVvYgJOQYMlmvzW/59/165dW48mUwrFjQJ28wFhlvOKavMxqeiiR0FD
# DATA 2rKkqxQFGmDQbv8Er4VSqSq/U0WkEpPP4BoiP4/iBYzEAaPIoH8Q8GOQ0WWRiapMS2bqyZn6KDjRGMT0BaqQhUxZIV1JS5ZpqE0P
# DATA 41KAFwPWFQuJehjHg8J1kK9LCHLJYZmHnf4Arj/M62qhONA/B1YjWMZPkK1IlrJTF/I0MDDBup6/+FtmWsDxmOWwWANnLvLfr6Gg
# DATA OGBI8rFEoefIs0QTn0JVotQXeEI+C11kckNuFYMvNEMeCXjywVggkR+kxqrBkMSdpzOewmhGp1N4SDY7hWp8y3AcQRxpUq93R72s
# DATA LGLODHmQlCuEcSTdATUFtsed/qRwPIqnDOegfypR8hhz6eJaqDzqyH9JvslmC/E2eHf1H1KMDd75jCqLrPUQFRuI6Xgtsl61Y6zB
# DATA DayLeHnigBsTcBV+D/eH+5P9pXCmppPkfpQfgEj4pJNimjiZA5SJQAYDqZSlMHGEo9j9/MXPgBhATvsMXxFUkswzPDaQBGBUyRDw
# DATA 5aWV1eA6/jOzw/+epD0+YZmCVefhJJedF2MrS+kNBaLnpoQmju6/BxktuN+/o1K9NcTFG32JgnjksiNY+uhvTsHBBNyrwQn1NGbM
# DATA UoliCyYEoKGKIoA2EbpYY/wEfpDiKd3wD85Ab15UC209pXAQ5gPh41tL30Gb1nAEngLwCb0boiFaJr59exVdVJBRqGblqLZFLbu7
# DATA 92S8Rhz0MGMRYlr2Y4xJB2+bKeOmvyO2CWhbxEIOfxxNRhLVnsIzuDztWJWw6CDsjaKY4tvNbRNKV8KZI4G9I77pzWePJRtdxPeX
# DATA 5JReMgLB69fAFoGKHBH3P2AvAG3RxehZtvPjVdSv+ADMA+5yz1lRsLiQnjM0KVi/ybBX22xylWv18us0x1rZV0m4ToCgTNc1uDF+
# DATA BqeUMaOCG4gnz/Am8Swh4ufglN9ILzihEMkS8YBIAMQHsKtZ8gN/pyPyx9JO9GYA6yTD8OPgYDQ9Dhq7a7hh6+sbu2vviAOKU6Sc
# DATA gJMd/noy6p0O+oiZYrCr8enBoN8FRNsEEYifBBuz6MHHb5iZeWoay9fFT5Kexh1IdUFW1Diuyjolv9Quu0bn3qg5jWTuyn9LXOn1
# DATA uQHHgViGr4Xs8ykKO59KFRPqvXxCz4ufSk9GsHp6J0rvFjRQ98jY7sxVpReBIFNIpLIRdVWwGCxyezpqx6LgsBcXsEGZHKpGyaGW
# DATA W5B6UBJGZTh6VJC0UTmddosV+CZ6cTIuzOBdKO99EaD66nc0C3xT9gl+cOX9B7j0fkVawmcv/g5v9uLab2fB8ZyBKgxjfDZb4DIM
# DATA SGmylz5WLyfG8XJGYBGSGBJOWMRiCHXECg/HKJwbwefif9LUocj0H9ip2JG9kKMo2csQspTGREzwJ4KGv0Tlwu/CRNc9XrU+P1rj
# DATA hYQnLcwZ0HUhhBxJ3WNx4lTG0QmZYfoPIWEjfGUBZdDT+YhMLwqsxTBCUB5C2eoi/GxBb8yVp/bi/6LO6HM8XD+3BD0QAG151hQJ
# DATA 3TkVr/8eLzdqVlFONORZMUCJkD225DPqdTLu1mN9sPHhQIAUE/RjsedxkogzOGPuTEcn/S635U6cqscyKbAVIX+zYmhu4GbWKhmI
# DATA dVhXnBJ3NpahYJzFyCa99GDMxLDHzjjdOC67MLr2yPIyGY5MfEmocpAUhy/oYp+A2nAMe7yG8WvkfI4wtIf9x7WwMh3E5dCzmgiX
# DATA O4orhz3g/AWzkfDRQYj2GcHSo86JmzUJnrH9LzEwo8Th4DQ+dgLpoL34bNgtyDJiDMNRwYiHHsXKq50WHcPEaV9CrN/AGAJyN5QY
# DATA U9eKebSCTYsLJ9H0eNQrMZKAg8BmpqimAlZ8lsxEbdwI4UnyUnj75rdXPT8DPwv+S7A0Wnr77Sweu7G1a/a5KniBOMp/o2wGxtUP
# DATA uOnm1qZiHAGq2qXJAdnCbXGncjCnTFVShbBK2GNPQ0pJDC3zVWIdcNIPjwphszeMW/vD8AYO03BykOsVDTAjMSRBUN6f4h3l6hZN
# DATA TvpTCl4vPIFf2t3B6LR3OOiAZXzcJ+NxiCH3tG5kzFeFOOELvXvUHdFr/JZaupRXZQoA6iclHHA7EZ1wkhtP50AMNBIRmKMxqlXy
# DATA kNESSH6qtJFs+SF6dYgZBRbHXyb8ReVvoEoqlLB9RjjUxT8DcSj7J1GROC5e/IwE+C/RXornz6/YjvAVX+gEDZaV+uwZGQShSOgg
# DATA g5lwb3KsDHCTW6T4FyTpzy9+KxoDw88n2o71UzzwjM1gtc/s7jJBOBbbpdogyLXyo1F/WDgMn3x8Dmboh+DnTh4dJWv6ZXaHCsLq
# DATA Ye5V5jXgs21IbUhBpUCynRyCoE8JZ1MxGJNsH0JsxQihNBJDTkIDGrByY7/cuvE9/aRigge2nqyUIHEk1jZbfElT2dKm0Tz9WHAG
# DATA dBMOOcSAehvewH9vhBhNgFQvB2KmCcXVHsQaHdI+c3XlieLy4+LDzmRx0D/QqWAXxeNFSy5MK2TIijJPjOKi1PQNuVI3MIQivCFe
# DATA uxEmIynsQCwj74yr7TDGJmqOSR2dX3viuFoFN2rIUm4AFyPqxmqLebtbnpk4x/AFMu8aZpiJ9C6nPQK3uYlM9SI2AtauU7R5SFjn
# DATA 0eh0T6Jyk4i31VSIlwC2wxXO5jUO0Qqug54Dv4d74qfI7H5vMTvuE4kF1NlkhLbWaGOJTI32HJtJ8UA04v4ar6jPg7X1+3Wl7o3R
# DATA diwOs3HUFRdESGSPOpPHUXcXk5r8zekI3AQD0Jn00GWwOyXdTHwcDQbyd9KfCEGwM6ZTDAeiowz394GG9sVfaMQeXqOH18xnb8Gz
# DATA t97iHhr0QcmJuMP8b1hclLRwI5RheHaCzLD5YNifClljwwgoaES2IW3v3q55R94frh0KWabGMVPlEYiIETuqBRxwzK3tDz/swGnh
# DATA LYu8yeoMR7aI/uyBP74QkuLjkSj34H4n/ri2JKS7/aGa/do1wehoTm+E1/ZBScQH1e3V1UtMEG6eXNMjJ8aYFLGvxKR1BjCm5h7U
# DATA JN7aHq53hBze60xq18vi/4Klm6XlW9WlpSrwKWvoDUFY4tz8cdTbiAads92oW7t5G0rtgFI+hstAbSrOWKx/kyybLZrdqHfnrIad
# DATA j9XEOnPhiTC5VHBJrrgSicZAASFjVOmZcoaCCsAwBkAIIfXe9FhFO06kJGu4fDaNiAhTKy2+st7QcgmlUx3jQSjTlxVtETPYngq+
# DATA go84aDPXwTgZTHFDWeOSP0qZlsMPazKzbrKkxflPJzgp7lugtBr7IzQcr0414YY3sKvt6lSkdblTsfRdnQpqvDp2LDT0yXQlTXj9
# DATA js8s32OpqpvdjOnxPV+bBgkZTRs30E5FCoOiZr6FdiqmCO2v2AnwJEHTHAmLmmb9lx4GkXfVSswK86YObfGRTkKfvy3DMRrQxuQp
# DATA XCFgwuRdMYVkeN/ZkuibwfejaIyWSokAFMijGG/ckNN52B2cAtp1AJ4ZB6NpGAcDiOfnC0lcSWbJbobTgYzF5G1ZNSbT2s0UM8mD
# DATA Mo3hFS0UFHnLW2VhX5pl7HSJdBDwNFkwjn5lEwm6RhLe6SD25PNm+QX8lAjyzBgJyi7Wr9BnH0qSV2Yh88LXL35G18cX/0SOGXjB
# DATA ROM8XDDFyeykgCFvbtFk0+pMq/iO+RP0pJXDG3uGk7TfSxmO7oTDsqUYuZQTM1jff0SQH5jAk1VkJJKJlx/24bpi8AOdck5ieETB
# DATA YHRUcTzfw4t/NRxbxIxWxQXKcA9EUDudezJyE6Ozbjc0XWLY7w9dbDa3NkvaoUL8P5vbIfAVBlIzUmml+y4u/3l7+qW4vx0+ah+d
# DATA dia9V+gFmO3/t7xy6/aK7f+3vHRzeem1/9835P+3F4FtuzPpDwAyIQZDC+SNZCSfB+99KKRYzKbKx1GJ9O/9ISUdBUvEhBIMn2W5
# DATA AB52h9PBHP5+8fHptK9eoLCT+TwA+Tug/0gFFzrsUKDUDL85cvvze8eJw99xlFu9le11EQ0f1p5cvz6KKxwgKM7Xe+vttXvoeb5u
# DATA KHxn+tk1yKPROMfAR+zXZNV88QnctnUgwXNpc8OoBvHff4SH4hWxrO8EHn56KISuR4D0dPEZ+MigW/5PX/wynOnDJ+asbRyHMh+E
# DATA BPE77qOZ0pjkHbTdWPhUNlYuW6/hzcqjjmDQcrJvrS7lgaSkN6egrB5Cj4rpkPyeRpaXEkD1Ruf3qFT98djGe9OVfdwfDFwoRt1K
# DATA ljnNNqTRLVMrmKQdJ1U7naSPbP00mGLR+vop6tCBHL5UcTaCTLSF+yUseeKY8VrywKhG5m+zfhxxPmvfn5exbxIdjEbTtmSnBTFt
# DATA JVaRdafieiQ2mZBoRpD+vcYql4TqtwxzLWsACeh02J/WUhU0iRcRYVWrsjTlUbtXQntfWH4YOSmQ28/lXnHSmXyMmnV6icBTCHMi
# DATA ZM3jHuLNiekuo4PXj0YHYoOLQQO63Xj0SLw0GMUxTN+g/3EkFZXiLjaddIZxH449vFi6mkcxiy+vdmROAEtXSlOR4ULhJnROb9EN
# DATA MWtShwj9UapCK2c7ZHro9Skr5/S4jn4UNZkgg2awSGmN9oepekO7RlNzCLBsPCuikmsB50wVZ2HnYBAZWsadUTytLZ7Gk8WD/nBx
# DATA chKUD4NEN6xm0lR0CKxUPoULkKGmM7SV6BFvbKiQUmgLsoervlSJJUpRl0PaSxXMc22tE/USEi+g0CRblf48fJRRrGyViXMGK0Ch
# DATA POrJA7IUUOyv6BqHIURi+sQ9nL89Ou53j2skM1XwS0lKZWbiKPE6YfNh9iGShvgoxdrEj/ITwBjaZzoh7R4+EoWwhUIovthmBvEg
# DATA cYJzhfZRzw7NNZpr5HMScKaV9MfDHyroyhfDcUCpPE5jyCtNU25ZKDLa5X5m1Oipz8fb/t0nUrHj09cc1Ptr9pESPO0dKT0bUW1/
# DATA oJDai694DqUtRE0vPyiLObKKCKJ0C4lH9krIylhDokrNGBYHCjpcWzpKf4bDItFSPQTHTTc+l+ZCOX4kB9Lrx53JSRv4L3hQMKki
# DATA 0dlnYNF3CDLos9iMAWraPEefF/2TWf+a4DGyfplKDGQL0LmBCkMKwZVgLQA5TnAwiTM6AdxS9OMFVcUg6LMDvsEyei5obHc0GDBO
# DATA UbmMpzH2jXh7uSzYD9FcDZEVNaMTv+EJA4k5xoJ6zmpr3e7ppNNF28UyaMto4+hs1JJTtYre5BNypxkvwEIYb8zaPwnZxtBoYmfF
# DATA ve9EzNej42jIcO0cPNbpDwzNpb8zdu9Nk2oGl8i5i9NIXm9bdAtnL+SfiM37HKJIP7Np++LzdwLyT0Kf5t9JC2yqCIP8gH+QD7+G
# DATA KsBMCk7R6AFpwbmqnVEo2vNlHkkMwYV7AIDelE3nlUOd5QT08r7LtBTCHUJcsGuqR406AEVv1Bu5MLS4GhpSXOGvzeVqS0E6yWfV
# DATA 5RaoXQGnPmyRHtH83WSZslZmmRQsxtUstRyz+SzRVzu9Pbv4FTq4AxUlLeNfKC1/MeHGFy6KZXcEdPAhqAxG3Y8T9zJwhEckkCHf
# DATA IMW37fZ6o762FzylL42NDxvy89b2e9v37m1/aEkqhH8vxMbJ6RgQZSTMx+EEbi+OYyuizTsYIptbeyaESDakSBJWRALp6zfam3e3
# DATA XKXt96Ozg5EQjzZlTwvFbGSTuXrlBzoxZoUN37OvpbBMxpyBAkzcNsXDAvynxE8An6Rd/0GGZjohC2pcr5e3MCQmMwNzJVRCDAo4
# DATA 4n8YzvpOOv/7GkEFXvwMI26IV/q1UaFt9jC3k2H4mM+ekYEZ4zc5mK0qo4Npu8Bg3n9AtdrPU3VongFKiSL8Y7MxUKqXcucIXBFf
# DATA kQkgU/+/vHTr9upNV///9tLr+P9v5O/NN9TFGzJQj8+mx6PhzYVr167d49TdkEuHqEQ6qVVgn3Cqb0rjjTkCEFUNMgNMRqdHxygR
# DATA Kqk5t2HguBODQUB9Pel0yVIA+Cmox4Ajh34EvS8AnDQgJjievi9Y4+Aq4AWECKk+g6vVlJpNNz4Az7CsDdjY6WQg2qpMqHeyTe5s
# DATA CX6Gg2NBdYB4j9GKdnhAiF/vL4wavkDZqdGgzvb6Nrr6C0nOyDKwsH5vE25MuOaYm51ULlLCCBfWt7f2hCBWbwBk1V5j+x4Wt8UQ
# DATA UKZORoNwYbfe+GBzvW7fwRjrDSlGqREXHmxt7rUb29t7WrbxOYst7DxoQBIMSOWZUmf54bJoeW/tbn0XQ6RQi8H5UXqjR0NU5GCk
# DATA FKVpZDRXyhsRcnLMM34BnDn6Q7GUjP3aP5S/dAU5D8ULxYX7az9o39u+277z0R42aYTNK7UtJWGajI7EXMecX2YiV1oQFEARIh58
# DATA KYge6vAYsSt2IHwyPg4OwMQm9pGYhzGViUucH0PKpVKMjvGa3HkUMBnKSHDYY3R/I4qrgVKz3YecifiAlVF05bZTVFiZSNHDBbaP
# DATA Ap7mFV9ktYmRkI+1M+zCIdqTWaxlJ6T+QRdKU9gY9R1FMhCaFxqy2MOc6LQ4nIWKVp3g2OGKGfWSmpsHSDfJ/Dh3G/XdXVvsdgZM
# DATA WUbkuqJKQY7LyVo5HIFaDCNA4T8Fz/1bVmPNsLYasOQDAOJbo+l7QA5ONJlRwZMQZwn9cyg3Bf6L6tSotwZQ2aJHcKNGSgJAcsQa
# DATA ZyiX2EBkF/vkYX+EujjZQJNrbyn0AnhJMAuxpSJM5AI8SBBqLLUhgL9HXk2CYMF8qH2hYOM9EvJlrJAKaE0rYEB+XMCWIILWeio7
# DATA VUyOvmmMotWUBcH16aTzuLBUwqUou2PRM9MqJqqsEGehvtR4Ru3XaqJWTgUP2xjXEJzSIERh//HSUnn/8fLh/uO3D8WH7xy2OOkY
# DATA li2KO+jKUmvBHgQvDPS74Hl6I2g+CTt6HbEmQKMnJkIFxXf897xVbJZXVqtuG5zHDwYtmhEVLfhy32FWQH7H59NKtbjcjfy7qg7D
# DATA SfIC2zEeyyU0tf5kqd79MnuDOjzP2Kj2DUPdKUwPK+lNVUzvo3+nI9mK5w4VO/tJaS/Gg4ijrfSEjY8RbZy9P7lIyBMMpzyluFYd
# DATA sVlvkqsmrNwA2g++4Zksng9ZMTTRXOzmXkUdgdx+cEhzldamdP33APKUmLrg3PptvK3LxzRvTZy3asub6FBPAbqjFHi7x6cnBVVp
# DATA EytsZdYtmENhJo8oJpN1onOG6kQtWKp6XT7cteJcWgM0KYLlRfnM9frxeNA5CzoYUdeBFAfBtaWAwQauVVz/g2ySNbwCE8lghahq
# DATA kLI+PBIEKg+STZgryHyEZH0jWJY/rIupB74ziIYFmldfIgwk3d0pJqawynLqNyZ/vGBjE25ipGjSJf62vLTkeYcIgDp3Hcssmq24
# DATA XYqNY9HYMvoxZbGQzLLqZ6FOpdGgM44hUwiulnjJosqC0c6hIIf4mBoieegREKG3J3h8FRMjgIjwE+hIQ1KX0a58ZB73ySPlXLDz
# DATA 7kCQgiUPGU6WUlksiIUYv0T4GIyOmOmzpwOfuZB1FJL9eHJaSq6CmSOSWRXzRlduDtHxXiF4iep0LTnSmc2XwIxlQDNriwq/P+z5
# DATA 1asfNra37n0kdaqWsrX+g/V7mcrWBEKBEsWATybzTFZdxqrKQ1AudB5uCVb0mbtUevEqBFckwy7VYytFJ/n96l8oeNwDOCDLWClo
# DATA 01ARxIx0B5AE+LDn+kEZXEqrVg97HNefpMs2UneBLkB8t4I4j6kOAuXLEUk7hbAJMgJlpptODvEED9/6qPzWSfmt3t5b71fful99
# DATA a/e/huTaVzk6oTMexYgWeiXQPQSSTsE3aoq8JEIVURueTg/L34ZoVBh5XAvZzUPKINwn6XmUHBajMTGlRcb+tIkmF1Wu7ezUtzZc
# DATA Ukx1sFLTDRpV6mnVdYBPmf+QkZzJNiThuZVyGtJRKc8O+rGYt2ZxA4cwSUDcgytTNoUZTIwyt0l0qwQrk9sidYpxclI5ITPAb3am
# DATA eIPATxafZX6VPTWmOEszJJUmxujQ3U1bfK6Is1v3cNCoPNha+0BMw9qde/UwlQXLviSXZpbpq7Fh7gJJ9/r7FkLD53M0nEhYEQx6
# DATA slf5RPAAhkBCv0HAzKByHr9Bxwmlstve3G3U7xZkJRJrIzWKJccs6hvA6bDboYuGWT9DfViKLdsoR72Po+hjKdAk3i/b7ztDBPVU
# DATA TdYDt42CXdpDo6kGnOwRUzAwvqgwHOS4zZqgP+K/YEyeotNb4QB5dnOFLiyqRLMKxSZCautxERCAqRC4fnM9DB6WzuozehMNe3yT
# DATA gUmGfK2FSViGP2DUgGgQtK4ztnvw/fpH+FNInud6ng+io/5wmFLRnfrdza3cVQF6AfUJjnwE9NC1g/INfyRPCyEXfFf/Kp859MoT
# DATA FTYb9Y219b36RmD0oYVnsCjR5HoB26nI6gtx/RE8KtaYVtae518lIFTyHmsZtOj22qR0IPL6Pa8CQF2fzOzFteCJbJFyX5YUZ+TM
# DATA pvKrJ2MdizmUzM/gqfKRvPSDVhmawhSE8sfK0WB0UAivS6VGs3p7FfRFWEiV8rYcCwkl8fbNFQ0dRk2C+MmNZ2gTEMTFViXgOwlW
# DATA Z5hZ8R268hhiPB7rHn5nzDe4kZBZA6toGq+3isUrvygfWrnpDWm8H2VNifdA8qUcvtTx9DJHVNqpk3peZRxDjM8x7Q9PowVPoIuR
# DATA BDqd/+dkn+btiNBSkTYrwJzhXiS43Q/34+uFd6vRYzCO7cc3iu8WGBKm3TLQY1rXi6JgDQpXrhf/ws77DMaayv1i1a/z0ZyVuM9T
# DATA oJNHgtSfIl95ylLeUx0Y+RQwlt79ODp7CkcmKMkgZvlp3BlMn/ZihA6AwTSXW9jyZsosyy1GhVdahscbJrnev7YfhkXvq6LjoBDB
# DATA GorBX9aC1WpqgJLDU+kdd08lBMnEhqFqEEVkBNqMwhPqP6I/4Sf4ibm7hy8QG8ADyOn6OWJG1gaQ356RXuhGb+xFOm/gH+VTT22V
# DATA jEOoJWNQ+BiXKvzCu/2TYqFzOj0WW/zHqEoUhNKs1lpEXAeCAKLJU7GQ/W4RaGx/FzBpJuH+slG3eai6LYTchqiseU3wrHf3Dyzi
# DATA FM936+uN+t7TnbXd3Q+3GxtPMWvKUz422++Kc/OpKLBR39rbXLv3dG1nk56tPdh7f7ux+V/XILtQ0a2UG1ODKTZ/uD/ZH7ZuhOF8
# DATA A5gtVDT34/3d1vV3RauzRJmnf1EMS6nCQVY39g+is78yBmlCQKV9PwhtGsiqvwCwPOL1Fv8r6rhRKbeuVxcXYerixe9VWzeq9Kl1
# DATA 43uJOfxedu8fLx/sN5tL5Xdb15tBeVH893vl/yatRYn3JKRX97gz6XQhwBqBedQ3sZ+wJChIzYcQHzENQW4TTEq/jZvp5kpAPo7W
# DATA D2/UguWVt7NEViXQbfB1MeDUlzFFfXfiKSG5V4K940gpbC3VHWkqwXOEsNrRraICMHwsD9paannzE1dh+ZES4E5JNwxvAOSI7Cw8
# DATA kp/P+XI7AMTeaVs5orTZT6WgLfANMoIHJ6dT8D4O7uEriEFfgn4OBTuaYofBe4KcBMTXzpSA54Np58gwvY9HcZ+vyjrak0SeRv3+
# DATA 1to6ZG5q1He2dzf3thsfUXrd6fSkM1xUqDdl1V3XfpaKjSbofNH5DrSpupPPKN6o36uv7dZVtKc067HTSkErnkKZz0icdJUjIZWc
# DATA HoBL7SK2uPhEN3y+KD2DFmkt3lVuHW103ag9cb30zw0neMIpi2tPwrUunEOgFgEHDghIAXzUh8MeN38DJdoSJEAX9ZbX2UBYBYG8
# DATA 3IVnoSdGN3wgqLC8dsTppfUSmPeI8JzeNBw/2XunoJw8jJQZIIRNong8GsZR4gbKz0kmWrl1mz1J4Iqp1hqOP1EcrOK6xKUWEGfe
# DATA RjOBik2iMo5hlaIWUC8vQzFiK+AYsRpG9egcoVJLU3LBaVWU4KOffUUcMn+43xM8Xf4H+GTnyInWnNht9iadQ7C19GOsDzNUJgqN
# DATA xYkuMzxbJS8zcM7rAGMBL3Qr7IufMUOSJUm8qaashCkQ+WfFmhRx5OK/xXfF9Jg1zxjEB/XGrpAalPJtgvfu6alg3YWTzhgQVbk+
# DATA CXoOCbE0StLwrAAvAZ0ur769+u2bt1ffJksGPBUnEVZ5mb7w3FGXbgSFpVJR7IPCalDG3UH16rBZy52mmmmx8V+7vD7dqAmfpAAK
# DATA s8aPA4RxOwN27i1rFyOutETVzTUNu3uQz4+piuV/Y/daiPx+osm/ec22eMKxDp5W9qSYi1JBKY38/MGDzQ1+FcUL/JhzZ/31g/ru
# DATA Xnq/YvFobLqhtGXE/Ik4deQ3zhWroICrM7zf2AHC4wS2YOBui++2iUyMOUv3lF8h/mBrd+29entnbe/90OpRPrumLJywaia9+vSc
# DATA KUrSk2VAs9Iz1B67aFi6fDoglkEkqqoSqqlcS6bRkPrcXGo5Sj8KFkWznJllW71RJL6+trPTpqsUitU+jC/wdK4FNBKGzzL1SUpR
# DATA Y43NCKEAPYStcv2hbrUGV4hDQPh8cnv1XGoaWMOQHJJUBCBMLuUBMgBkmY1QadC73lzJJKL7m7u7m1t35QTwqQxaCsB8Pel0K8Po
# DATA EVen4H9LAXvdlqT7dSU+7gjJA6WxXv8IRL+ix3csne5LQnwnpWuVmj93ULxlRUBTBXPjFhN5DHiFDKkvNhEE2cVYIYM3JeAguAdi
# DATA qLZeOXBeQdQxdmQXnIQxAQvhw9Hg9CQCR+Cm5SKovCOb+DqpovATJG+iGvuHXuVKwdgCWJKZM+VxggdSRkLQRHT9SjhgA4vJW7tS
# DATA oCTduGVn5UFeDYtCKllpFVuGpkdtQ7F6Z2O4eIUH/aEJ8UiAcMxsihrwsZpskt2r2xAnIH4HVnW+4PNeML0M4Khoyo60fNGbFr1z
# DATA U+372w+29qDh9+5tru95kqFx9Y7hDldP6r1kqz5Kt48WiQhsNCCnBPXuppe0yk+Rloc85UXYQezTVyW5FHza0UVQrEq/h3AE7GRZ
# DATA RXPuvHmfeOk477asJAhRE8tfz5OArwC4G/XafJAaueSlPbqYimrBAduFGZivoCQQV3wgbEj5GxSIv6DeQLp1SnQLFwvXAaRIAt7G
# DATA fVBMmBi3KgCGg1+C8h00vRtDo+gK37jQEYQiYvElc3bgJ9RxJDoF4B3Q9GhYZs+E/SE/Q1haG443P9aFj3R15MViwAEbJQ4+d5c2
# DATA kTpSYwskoTJKhB9hiCDZrysMjbBcHo4eiQ/cm7lrmtBMpdYgLwUIkCIkWNDJT89YYDQkF0MDBAC4gHk2AI51pvKeCl6Ih9o7ku4g
# DATA prPTC6aAHUPHatQRRzZOt9IBpYqYKvFA+sGZkYbAEjWlbPpSAqbE1qS2PIxKx2Vo6dEEe80UzOQznnFxDkSm3JglrnHHbq4E363Z
# DATA AlAtWF36zm2FWX6sbQqsGyUc4/0JQuygPgjc88NW8Y9IbpIpG5IykvLRRI1UVcVkt9t9sWPbbdGFwSHZls2IZfGwkk52qoi+4ug3
# DATA zHuOag5FLmwr6Qhv3CPMOt1zz6is8zDifidUE9a0ZNXH7zrxCTpknfSlvWSf0aBdc3vtWtw5Lbvj7d6XoV0MPQtCAHhpU4QTG/4D
# DATA ZTenUoK1yt744Scswtva3mtvbomL+D3wBtNNSzUR1dwM+bsHpiNRQk8LOHQxwUg1JbgBmPfh2fFiCncOnOl9GafkBRMnlign4QOQ
# DATA GSN2BZ5O0j4QyGWR+ls3ZEtMSZgBSpzUb4w5GChFEReqy97KKqQfgeL5XLf86g53UlN3WyGEpnB8uDRumIt/8nkqXvUCOB3LXgWm
# DATA Y8sNUW1SwxdR0zX6siS3ugbydCJnKwNMHGFUW7T8riEhDjkWQBWOI5Pr5AF/ABaXb22g6qYQ1zGky79CvEqiTjsOCMMcxZydRngB
# DATA kwGPdMEz4o+Csn7XDCRYAsXj2ytLKXEq8A7HvWGLNRk/yb4YNUGhe/VG48HOnsWZVJdxZKIWgh0XElRV9QOQws3EAibhiaGYSQ14
# DATA uOregfawI1DNhA7A+OwASX/XVMCUZVwcc3AKrfm5cVwlw6uZiXaPO8Mk90SdMRIAInuQCQEUxp0uYeJ4OYz8EXWmBuNMC+bKkut2
# DATA NsBB4M6D3Y8S/p9nvkAq8h5ODrMCiJfHQnzr/zgydyCNu+hbDF8tG/hPmktn+kAMV2fy6SQfZXPTt8nZkJaDOLOiJXXIzXuy6VBV
# DATA FVws7xcSZcm4cgiZ/WjS6UU5zvZ0Do8Mx8upxNBQCWHOPw1USBSjR+1eP0bcMgtqKTEQCCGU/UR2AQ0SaZ10hqK6Htm8kFhnjmNn
# DATA 7W69fX/zbgNdTHA4mw2LJ6TuAfiasgPop1dK/+xNnvvknL15DHWgL4Y7JT4nefbWMs5e78uaZeLBrb6me3XNLXI4DEK2P3tglziw
# DATA 7AqcU+u7GafWXOuf/8RQjmyu/EUHBQTUUZi9XoeqyXqMxa1qYVvr6/SsmLGIxpy4ejd7T3oitp38GqkUm6JKISzGTKRC1qmVEeYN
# DATA wAANAEMTmuPIkrL9WkjxngIx1KotqlD9wOhL9zuPQQkGNAAFXPUcvnQHlD+olEttj0Hq4FTRYl+JpVPIlBVNuH140O+FktGKRyA6
# DATA qPPE0i5Zjh4+YitcEqvKIrwZgpm4Ljb22iqCiOWlWjLUacHv7qlOlpyiuqfgJCzzzafcenLz9vk+F/RFdc1Bwilb3BqwE2gig6EA
# DATA oNYWFmCRLVnhkgLCld8I52LNlz7EnEO5WJ1xwUweY3nujmT0T4AYgH6EmV6aCGo9BvdARy0lY9oKOam06FbY7k4ijn5CiWQ2s6To
# DATA PERC0QF/xn6B3DbshphvQySp2+4XsBQ/C2iqa1CLUZ3E96JHIEmNMMRNI/duzZw+fXIpuG9jCQ1Ro+i/9l2x6KpmX8uvcg50X1o+
# DATA OeRKJN6Xknyv/B7xUuKb7/BQYtjL8GRyjPJEuKq08QTY2ly/t6nHlky/SieuVFUirg34hIatjNVEfwiumNYyrV7ck6ZyQX1u+U9C
# DATA Rza6Tklf/DLBGTgUwAT1+sOa8eZG/YOtB/fu4S8gF8j9R/mm1FefCPH28tKSXwbP2Nbr2/d37tX38OS3t3Y+etDQMlKe0JnS54yj
# DATA upyE0z80maCfnDhAnmACZk+RDJcXn6UIcinBCvf79k6d97tX4GDOZIB6tDx4QDn2mGVtOU3oMzPV6n7sH89FKwVkBHWDt5fcxDWY
# DATA D6BN2k0eJ6nr7f2TBF5P6NxZnLIrsaemg0kNazOMvf2Y0dHtywp0oaV30q2ikTEJwXm8SjdoMUlwgM/TE2JQQLcCDdAziDqihwBn
# DATA djAZPYohOTFrLQB6BihgGg3OKn5umaYOSb3wp/+Yy8qSLrhZ5OGxxIjpMpa+mulGYu0ihq1n75QcWmTQ5sttUzMItZjdJg4ZrYj2
# DATA 6ZTM43Q6mXDkIbyjzYJzhogW06r16pKvX+ecl2HnoRg8ujlU1UvsWs7ONapL2u2GCyYvsgrXTBRyQdgMGYsm5dw0+3XlvQeSTbmh
# DATA cmRgvpegNrIzYyLHdrvQHw4jX1AuPsc4UYY7IFdp6Wjt2nAZBxQBy0tJEHILMMcFyYEJveGRW7yiu4uwrfvp4GyL1gqIKQVzQ8KF
# DATA 8fvWnWKmVswrsMs8ZNCwELU2t1O0TPb8ZZ5u1jRbVOfpVPJ2w2v5GH0GsK5ScL3tD3DVTc3dY27/Ht4vrQNNaemlr0Py7k2/tNGV
# DATA v2TcxHUsBTqalFKv5pfXOqeoXWaxV78he5Yu19JQvJQ+85KW9qwOpnZuFrrgpQagHJto1cGdR662y7DzNQXuE1v1D+sNp6E3g+1h
# DATA pDB1UdD40UgMtDMAfhyfHh72u3107IK4PhmjCCFaoHWAWemIC9xxP0ZQm0QougnUZXI8RldQeJQSZqGan4cxsVswXU1wgTJQLovV
# DATA Mj7h2lupIeAvj+yVjfCV886QUm+G0l15vtKFyadIl66vWtvu+rMy6/GP6VKK+FRJ5JtRv6epuhMqeb8DTClVDT9TZ//NqOZNrfwf
# DATA iwo+l4x7lQr5Gc5LEHBuFZpLDZ9JwFelfDf07pfRuLt667QT/aX9znJhk2forPvDw5FPM89hpVlw4ToSiRCActcRH8+p54bfTROC
# DATA T7s+g+SKV6I4x16w9nw2CV+x4rztt9Ebak2isqNqTnUcapq0ip2nLOoR82W1OvbGPpXQDQxIv2bMtP/8pig1N2u0ASKwvb3H8TgW
# DATA F9UlWBD7q+071jlp4hBgEHN7c+u97fZ7YoNzfUDZxdR4Ek8F9a29xkdmDUjYjgOXs0x0psMi6RwOC3Pd/+39aedgMIhPj9zMFXHx
# DATA bzpxD+X2+ezFzzEv1yfw1fJgSLkXyZSAtQyYiVyKZ1JuCwEA+leWYemOrlxV3sKIwhpEFeYJ+ZmpsUZaZnU1fvadtd9JU1VrkAFt
# DATA SkT6SSmNnuk9DRPQJF6gNogfCUm5Q9Pr/srBPEeK1sNrH8jENHqZnqiP51VObPNEVniuQjzEK/ybfwOf7w+vqRCA9H74skobB1Ni
# DATA QMF39VXI225xLlcfuTHhgtSor218FM7TlbmuZZe4nlkO9kwFanE0q3yjplfvko5OJkiDp3VkU4koGxAK1C+zbkaXbv7N4A5plaE9
# DATA SrGLuPgnnTO4bmHGpU4wjAA3fkxZYnSepcrCTO2somee0JqfrqSKRpaSZKCEXawunQ2+Iu78z5oZWznWIKtcFXJ1Qp65zy++fPGL
# DATA gE5S2WtKB5OP7+obzEFHSFYl4+gyrJgS4NHPjU3j4DfFllPp2d2usIX8yz4XQTM2R/v+5u79tb3198OXWWVOrASL/K8Xv0pmS/0t
# DATA ZkqFdHp/TykEwxmLOvO6lsfkOUvUc8yu2UKev+pUnQ+168l2knT6yU5FVJxZvZs9x8n/YKTRcR02Z6fTyfYv8FsG7EQjEBJn5ijy
# DATA 9vo8RVy+hGEnUxv1So3gbyJKGl89CEMGgggD1LD3goMzijEdj/rDaSXYEZMAgcTBDipaFofRFC7ZnlpZ2QDRqaMS3m9EG0F3NIa8
# DATA ZkrR2et3joajeNrvggpzOqLzpSvTol/KZJ9ij2+bEPb51aDGdphp+ro0L0qQP/k2c8uEw6EPpVzh9Sk87atUxiaTli1cJT0naBkV
# DATA 17QoGIC/+9HuXv1+e2dt/fuQMUV6NomL4M6DvTBrpN68qcYeWMeTZ8feBsMeEYBjpH/7VlZLOP+zMrYax5RM2Mq3Xq/C6lLqPZ44
# DATA N+DNSYR+Of+QXBIUXKek4v2kH4tJOLLBfxIqpdTSKgfMsP94F/EXC2aOy8reMaVEPLrff7w5LFkJMCv4EvIqelWmB0BggPYUX41N
# DATA 5QxoA8HawzvOdXERp8GQosFLQafX4/0en45FrzASRL1Y9LwD6C18Oy3cStgkPXUr+CjR9wLG3HNfaEo4f2jBn1a0aOYdIHZ4IuoU
# DATA 1bCqM2FetTYhIRKMB2cylkxsgRJiiDlvHYx6ZzauBhZSN06PPSIa9toSV7AApdIKEZhiIVwnCM0yAGLIjJgSUNGjpPRUYEEslhBi
# DATA EdEWwrxN34uGR1MpcYMxC8bt+pvi6/rt2Df6R2iYJhED67Cm/BgXL43+zMD4bKIy4QC0eEa4DXmQ532maIQVANG0M4najBaAveHR
# DATA Mj6CCUpMEAniP3cQkBhvPthCMd2yi+ceUt7q0k0QsKR5K3xvu3Fnc2OjvhWe51DxytuFzEYKPpp363vkbYu/kJoZ8sWSHBFm28N1
# DATA x1YA04zmjX3h/CGyOdqndAQxCD6FcBGU3BTav5jqZ5vVG6XFhqrJCuvU2branh5FqR2V6Iwp/aE3WxLeaTEbF5zwE+F2uPLqIsjS
# DATA 5xSbR/Rz+rR0+WkkguNo3vl7Q6HkL9m65Y5MUbCXon1P5HHOnu1s775s1wbIkRWFGUyoDQkck5y72cokMa6PsKVVmKfF2/YmnWF8
# DATA GE3KdTjcKFaQ1W/8tqCMSj8WzLE/1aq5peC7cGsp6DKosrRBcq+MmBnn00BApNXDcwdhP52+FDPdMQwRFmqWiHA4P1PGC30DXCAQ
# DATA 7wTj4hmXrBE97KN64fyb3rI+wsSeviRx4uZb7HQpnvLPkypXbt3+MyJKWDEPhoMODXsVtKk5Ncf/Q4easi8tEqOtWCH5SPerlZ/s
# DATA Vy51NqQSOYmFr8n7T4G8bTXuN0TYJk0nbDNXQcfpMrV1OVi1Lgdguntv+8HWhns5eKVqUatD3yEPHqUAgu1k+paSvmdVnFNZaiQ9
# DATA pkvoktx1NOaiN2oLeRDg4aw7pvk78AR/AVKrSMccWqak1zyUUoiAxisKqg9J2HjuxwJ0XvZZO93f8WthdtgyYwrubq9/v25SuVmf
# DATA 5TGKHjem8mkqFVDkolOSahjCXMdCVW+1Euj6tumYwIoq/Kd9OMJkQZhgtQ/+8JxcE+io3QYppt0OZdbjSYyOHGL/4efK2uToFGAM
# DATA d/AXlWkLLKRtIQN12+2i8SbkJ2t3+JWCdnFE580d1IAz0DB+E/ez0Xi6qFw2peXGW5l50naPR4BsXCOQYxQPtdOkg2yAMOky6FRM
# DATA RVkiYWJZGVrSyhyGjIPMLETK8+I7ab8POgfRION3NLNlNwHeoOkVoNo043dG780owbiU3AkOZuWy+A+UlvonCFXFwzQ67bONdclF
# DATA l9xFN9/6Y7iLN04p3w25ldDeVrDVkCsEaEUnVRANVexQWB0HtJBm3sC3yLyBH8WE8SdcHf6MK8GfcdYlOrq/XaIgE2cSgPfdpjj4
# DATA CT/zTPM3ntXsRhLUaUG62RCubtO5GuAdoatFbE1dV7GCDqty2rIrM/dYRo0afwIf4td+T6+ND5We9NJuVcWFb73+e/33+u/13+u/
# DATA 13+v/17/vf57/ff67/Xf67/Xf6//Xv+9/nv9d9m//wcllw84ACgPAA==
# END_REMNACUST_HELPERS_V1
REMNACUST_INSTALLER_PAYLOAD_V1
if [[ $EUID == 0 ]]; then
    bash "$directory/installer.sh" "$@"
else
    sudo bash "$directory/installer.sh" "$@"
fi
