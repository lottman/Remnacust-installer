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
HELPER_BUNDLE_SHA256='664287d5ed0f7e19350af0e7e4a6010107be55b7b93a46265a03f5bd15300683'
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
# DATA d4kKa81aow0v3Hnf+8O/D7L/jQL+b3D/dxe0s7z9D6rIH+z/f9v6v59hrYhg6qtDF3NJeJPyv1g6KJlMlqRxVP10NKIaaUxPfpji
# DATA PYL31f3l6znVt3g+n6bqy+XPkpn6jBfdjJOh+pqkv3tx4KvlIhnr+sDBHP0U+ms8mdnfuWQw5iec7O6d4a0XRQ6zkvf8+Phs/wST
# DATA M0rfTL/vn+y/ONrde3V6Nvhi//Dl/snp4MvGN9Bs/+gZtfm+D58G61rtHu19cXxCN5qTqxZPiM2HG+VPJ5U/55aDz14dPTvcH5x+
# DATA sQtsdqdk3wJS+sFGxXt+cLh/iukopfwGL3Gep6iq+M12S+Sd5kW/OWqCfXlxyVhs+I42ZOn2yLH6lJMluqVleysXvm15OQPl9NwV
# DATA CGfWyOt1wJWnWh0jtBQ4SvB3xzqmCVkSmu+0XDFK9ITEgHO+W6YU/i5+MvyoPValivdi9yeDk92vsLR81y2iQY9wweFZM/cod7Is
# DATA KuNiq7qGWJk7ikOAo+xUxJDIED1XV5wM+XKTKhG4LlMnt5VYncq7sm1rcsSXGmBGtbosV94X6T14Havblre9tUXpSlRrSv2n/On2
# DATA pnX6Ab+f1zYv7J8qH1c+LakY6b1nHOT+AmFeApUuzoT5+gO8ISFW13lIoiaGfRZ0dWS5tKkO0VDuxSjhI2KL5Qw2L9YYx9AKRnil
# DATA 9CLWI0oyQAfWc+TKMeUG1ymqePdVH1BnNw00qnRnraS7dtaRYcA7aRI+Oja3X8FbfxHXwzQdl02n8Ks1E10qG0iFNp2gkyXCjk1g
# DATA /FitIu/QEFOayswjK/6P/MZ9i/FM38wnyzFK00U8N2eUhNdi0ZGpE2ajr1Vp78t5cpmqDJ4ve8hta/E04uwdYMsP5hgfmNuZiiBU
# DATA C0XiMJnKw/PtTTzVg/1fMEj4vKiEMoJVxod2VhGKjGe7Z7t+SSoo2hsDH+7t7n2x79tygDaI+t5q3tFewH4rlcecrH81jd/M+N4Q
# DATA Z5a+XFVk1gPnxSJLV8phIqDMwnvX+oVcyGh0DBkrmIagQLj8iJdzjpeHz8rMhvxPmB8JfSqIHRqVt3MQWqRcOa/LkpSHG6WNynnj
# DATA QrNFKg6l2Z1OaLlnABAo0E2xmN4geOsl4M7dNn6G4ar2rjJ1kgNVPWUSvEkmy8mOYvKGQz5YcDN/tHwV/18wtum0A1YMw5yU5TiY
# DATA U00Hc8bfOnSO1MgDpDNY9xIQX8UPMmwWBxMzFl2BtyM/0ymEsswE+mw4tEPCAbiCPH8EvFTrbJGm/hgzbVwqycs6fd0C18kozwPr
# DATA kgUcHn+A0VvNXnfrMbiSjlbGlxlb59ywZ33cORYxiXvibYmtWLpDW4RNFav4mzBcSdfquKPrSuHVc/XWxYP76tU0W85mlI2qdpSC
# DATA u1T515ewDJ2aycW3l7XFUDnarRrNQdYHDclCiy4cd6u9cMeMdadkj1V6ip6qylOy33BtSeHWpwq5JIo62infkMbuBzMvV9iKKlU8
# DATA N1VOqQB8KmclbawYibh65oTo5gWsMfw0u/1L0PArfylK51+yxvkNqJwVOTr6CHHoYBeBopo5K7LWwiIXq9BIRJSR2iKbQ+8Aci7x
# DATA DniYLrAHUz3mQ+FWObMu3JicVOaOGRbMyc7k3OFCwVX3f+g7jZAOFMP+QDiwUJ7ZDdly4g7v6IBMAKpuB1KYWAmP4GNMW+u4KG4F
# DATA SxZxpXhJKAO2VpWyZFI20ZGDb3H1t1mE0el5XZ2JT+voImd0tlwO8LwtNnvksjFJe1yt0mOfAXI4vN7Gd8rSkPvqyqIk0iTsykXC
# DATA vp1edMVftlpIUmCdIlfNIP7MLfIKAjUv4lf38wHX4YJ4chiCH6VcRA33QckRMcJqPtrRAkdj4v7zzKvaHl8svob1OD2vsiB9+aUt
# DATA jqk1H1mprNSbl/svEXKX3i3krrQprhS1nuTV1YwTvK8UcGdddLqG+PV1eytkA+zLnOeQqd9DZKZ4tH6pIPl2pQPcRNYrsAmUL6rK
# DATA Gkulam9QqymNXskXx5BSiAaGNfXPzJFuWUncox9/LDNXMGzjGHery6/PIbqgO8fvJGWa0+tpscsWrai1ruTbqypwXQRVtP7JMI6i
# DATA nNZvKdU5u1HOjOdsx3wFvnuMyCror2Aj2BadGMM4aEQOvhLfc4nm1nlv+6LAIHSMQNoG600+RzlSw4hyIV+R+XfXFVddL3QU7gqk
# DATA z88SOYnPntrasNsWq0iGrGpytfJ1yT5AB27tc/gPHl+mfZ8Of7qTpLXPcJ0Pjsvcd6XQcgCSyhkOyvWVNxxEc3+EzNt3p5mtiD2l
# DATA AsqZZZqFuIbZ0CmYBA7Ppwt2SvNtNoMkA9vAMkEMkytIVRwEKpYfyytsUB6Qrth6iKudwRxAXN3mFzHLOSK4UxKR3H2hy4Gfgdko
# DATA lX71izUp3au9jOaJEr2MPawx8qRkxqnpyiPffJP/+XEeCLxmfIVEBY+l/EkXFC7WCBcWyuM35KunmXGTClOWuqHjZqDNuh3Rqmbp
# DATA rKz4XGUdd9evOWxeXdW0+lyrVNMonhfJlDAAIWVXw3tIpKTLxWxJ5wYMYVYeoGF+R5HuzRrKLZQBcsLxIVGQ92pNRykfNCJgzoL5
# DATA AfxSXtXnsCHRW5U/IoTqI0Ys/B1HW6j6IAjabfhTdCwHs/tpyfH9qo0gV7pYfFtzOv6tTIwMrbJ5nGVlxhtuYFK5saICQbVT1xW1
# DATA RWiwoNBV23BRH7LPHnTdUS8fatXQS37OHhMwP+FIFHsOqSAKNq7J1JXrS7vY8m+KiDNiCm/kZVSeJ0Dfb7bpv8i16/UL1Q3bL/QA
# DATA j0AF08sYveO2JKviC249SUuaQ0cKCgyiKT2N65dzlEvsFGpv76V13mrtqFamnbllQRes0B7KJ/pTDR0IXGCD9ZeKZicUuxP7x3m7
# DATA VKDBKTLJGTDanYL6ru7py/2T04PjIzUwV/aosU/0Ma4+6VUKiXE0Q/1WYFZouZgz6ixr7oNMOBcTfHfQY4y4x7BC201sP1Ukgjdr
# DATA U6UNdZ7JqQK6ZoEdwiEyNGVVnFX/rjFFDidBjKzfY8nEtne1KxITaow3clt1mndLbq81dd2ax7rQsODjbWmlA83Exdbbdnj73b0C
# DATA yHF9Ve7urI1Xtm57wElW6R0MMap7nZD9TBc7TX2pu+J5Ug55xQWg1v+RLn7LXaB71t5+yybhU9uWAWQ9u591VJzXCE51IyS1VluE
# DATA /QUiOwbMFlmKKZ+N4VXiW1jDnxR5W8am6lyj6RHmL93IxmWO5mUDlXXHG8WZv3lTr3Oky7RZUwfokSLQnFRTFyfpftkEvufqL9GU
# DATA wD7udOR0nzJwTTeAOGvdvYcK46ycADeNi0I6a+svPhoNl/E0VpfdeLlbV1d9Dvog9b3uBlV+0vU0qDOA+tyffRiw4Awgl+B6CSpW
# DATA PL/mQltRgBkhkQV0zZdKcT4ljmSwS2/lqhuqh5nrTZKUcIc99SWHga5gAHhB14WlGlERzYXJYTIkUisoX5Rf67LtE7y/fpzoe+tJ
# DATA IcZco4A4DJUDU0lISJn4GcPyo+TNTqkmBt4mRkGS+Y61gSrrKet3dObomuMGTpFHDhNSfPsx72knTrvtttdNTbV/teXuLZ2QZvrs
# DATA veqhuGiH0KaQJto9MX4ovKmZntQoM005jd7St9r+/k8OTmFLyDcQ4fsvXp59fXdPiZWVJ9/3d6d015IV/Mbrm2bL4TjJrmgbZCjr
# DATA zR5Q94teJVlBd7N5GoKVgofxqXzIArZMvASmwFf6+Sq4pBI7sPiDpOkVzf53YUb3MySgFHXcvYA3cT0Uwn3RBdH/uqyqsD4GTl7T
# DATA 4foCCU6zPJrME7m9wtyj8pHNSazfFXL1m0jPTmUZs/0fjXPxoSjvHpAGslDJtCuoBMPJkbX5ZDGPrc1k+xpc1WOtJ0OIhDa887rj
# DATA wbXTlOgFHa4H07Lyeyk8kM4UrdmlA9A6oHpqGCMoVbXe9UDBgHwNg3sbE5Ye3VqCv49ujjT1YfDwgqw2f6C0gapmoBFJ1SIIgYYs
# DATA ydrSdQdEjR4Xv8o4t951jPmVTuyCB1yyQGm91FTShCwDTVc9YH2Vv1gaMYPEanHl4UIYTJv/PzljkE+9/e7z/xuNZquxkv9f7/4h
# DATA //+7+LexsXESY4UqP1vO6MKaOLIqI3MOt9SyDtApgAmhETQOUdkYLcf23bT3pPtTuv4HJOkvh6LP6F9u9Uf0uXreyf7L49ODs+OT
# DATA A8p05wNJUgIG/Q2XV+G8lqRPxuliASb9E3OBrS4Ts/JT/tqm9X2sVpZx+iu4eYU759I098OnqtfkfoEe7jy+DZEmbM31arGYZdtP
# DATA nlyCnrAcosdad3uSm+OdM0kDzqO6YDjuvIMXu59jbcDcGQXx8Wyf1zf7weaIE3Mq3rP93WeHB0eYn07xVRUEmaVZQpWO9I0GJjOv
# DATA 9Mcl58q3lUituYhacpn/uESBWVWkPN9qLs22dTMFBlB/MB5guewykzumeqcLyoZYvYVFl9ex7hyi1xBcft9y9esUaozQ4EMu5ngQ
# DATA 8S2K+ZiAwqsVGTBdkIpo9cj3CjCcD9xS49yGWrYAOYFFOAsuM1Pd85OV58/I0jVNTMXeG/Q5nkPnUuJs5N7SxyUS7VWmym72xj3X
# DATA 6L24sJEBXeeLCF9eUjEz6S5hZ2u+ewsOOqDEhGTuD7zL+QmI96FKjOYWWQM4El2Fa4HuB+MsZUohyyoTVw/8ngRZnNVyve5ep2Dn
# DATA BNlr7PkZFdVDjwR3gGeq6D3oyP8pZt7y7xF2HI9HbmfFOC6cGyeGu/iQpwXYuygoGqUqM1pEhynjeMIjCRc1ZN/oRsWrjCsV2+Mz
# DATA 1jEttfbba27DtGjrkZdspPNLCl+ay0Fq3IlcR7ruDk2YtjBLi8iK7s1cO/Nz8+XCjUfxS+oQDC1w+WNUI6sk6AasTOay41Bv5HsT
# DATA WnWEU7NF515v/esmybnaJAXEoqe9bF0jo7r64Y5fz7tCz7g4pDK6iTWJfgeyOogoDQXUY9B/I3MbC7kOdiy5W5svp+VzKQmJZe5w
# DATA ehdVTqISt2gYzBZ4hbJMl3/EWIP6yKDsTEBhbtWrBvCKk8ehRswWEbSmTJb241NZZH/BksAawzN08cRRpuc8TibJws1utHK082MD
# DATA SNYK8pK4bWTVh8idwbrg7Et1dx3fWMXXdDrBTWnGsU0zndskHkd8mAjr+cOb2/w+R01lLKzmN2DZoozihArAC+mVVKXCgEsT6lLg
# DATA TpKRWmqWGCvXt13O0yXdQKBmBkPYl+apF/Xt0zI2GF+YOZi/guXt2xrR3h2m5n5MnbvgOCuie3evDCxbxQu5SqYUpn0dxzMBDq8P
# DATA ALat9g39Zmkc+U2EmG3WV3DhoFgRpzWkZZ1KSmDmJvuT59Z6wYm83ZcLrftjVvtghP+lVPS36pKrLpCTJOxls+9bza8cJ0+qwt12
# DATA QrGGZf01uO5NzHYiN4aUixQYPOrGWs9E9ORSxbqCXMsMBADXdftByKMc2JoU1QCGJnXvLmemhLWiA3sF0m6l93HxblO1QhfAOcPc
# DATA 3nMZnjUkHYdDq/c+FqczvcQcw7kP0+WUbDXHlycNHO20YGOb4S1dlY/r4o1tIAjvQSlv5rX4VNrMjmTljBytteroh9MPVr+V5zW/
# DATA q3+0ozf9dlFRyxMtMwVFwHhw80Tb64Uj+zJ3wPJE1h/P566qMYR2r+8N6LnKegEXf/Aa8e/7WryN4H1E2Sb69NniiOJxjBbmU+Ap
# DATA PpWxrSp2OAMipOQ7qf7uapUrqzufUCVbc5d9TjvkJf1kx288Lsxn6RGn+mNR4E+Wh9UUsyYy6zBdjvkCOnRjj2+VCp0s1i0O9zcq
# DATA 7eGiAshvBfY727+hDVohhqe6/i7dO64YbI5SSpVv45z+4DK2tnn0ISVxWfZgZJAvM9pR9uWa9shqrQK3rABbrytL7wFvsJLUbmFZ
# DATA caqq287oC8ns/2Du1X8f/t/s9+T4fVz9l2av0XL9v/Vep/eH+q/flf/3S4mq6nxA4XtykRc7XcVHgurWIhX2fJ+/N1e35V73b9V/
# DATA CVbkyzRL3qzxBlu+X6nXYtef4IPOpHTLWS72zuzky1BYidF87xrp6fcfZKbEpKvl9DX59xbA0cfBZBgF284RBctWrWCNjHyEliFS
# DATA aiz15x454ucFFTJUyJtDVYvgErhpBpabUt3k8maaj4mSWenslo1CDZ6owix8GciqmTKGxS18T3P3TXaxrO/CymaVqzU5yZArAtAJ
# DATA AuexUB4/hznepwy/+2/vfsm1vVUh73+AP799//P3f/3un4UyN9/95t3f4xX27/4JC4HrSh4Cf2Yd9MtdQS2Xf9pn6swzOZ/6iDLz
# DATA dw/OgGqNywyo9DgWIP/NAzOgxGnSrd8G5yVK677Y9gMi0gAJlEmD58SfzUVCgSwFXcHJNwktZ7jAoNqYq/osES450VMLcavpQbME
# DATA HZRIM+eMD/eechyFfyZXiuDO8fVywJZg06fB6UKZZGpnQadzuyXe6JAsrIbyw4NnAd/9HwqvXM+dsP6b939DJIWV3OETln9//zdU
# DATA E/79f4HH/0jl5/8ZXvoXPjJYUEBfiMUCkY4hoB0DzE3dKcsEFEyibhsJJ5hP4MPdgzD/Nyw8/xsk8nd/D1SDsPyGy+JjWXqgFKsw
# DATA Pda7f/fPMJWfw/e/XQsvkQxAWDXRC4L9PAf3RXFGmFx3NrKCVG/1KHebb2ET322CNbV8s/kWO7yrAeeuXf6slEvHmikHzOiegJjV
# DATA 8/ZbhlIX/rtQg/EwpRUbzDic6eI8WgJ1Msl6yKaQc773MVmWNjeChYBl+NW7f3n/dwW7+Bernup77lx/JDr+WCJuJb6aPX8i3kxP
# DATA X7jJ7pcPnRoz2l+8+0f48sv3f+3jH/wAZAazu5dnPf7YiwuxqQKAt6UVVwBQ8ca1ndBHFW374FnDlvo7n/bar2mifDsE/wxz//m7
# DATA f4H/+8Uj1ppYMV3uQvybYOOUTCVrjD2MqZ60Hwoism+Zp59vmDgPbIAnIj7/P/betbuN9DwQ9Gf+ipK8mwLUAHiV1A0KctgS282x
# DATA RGlIyu42xeAUgSJZFgggKICXpnmOEyebyYl3kszuh9k9Z3Y2Z/frnuN03Ilju+1z5heo/8L8kn1u77XeAkBJ3Z7dcScWUVXv/fLc
# DATA L/lid3DeR4i+SFdisXAZqDqvzOFocA4MXVtVaU9GPQGnPIT39C2xajF1wuXU6iOAoXUuc8ieDxATRvyFAOKfvP5n+P33r7+MYIW/
# DATA oPQjv6AsIHgSf/P6l9F3s/HHk0PfgbtcymrNgX1cKSJX1Y7gQEX2+TNFcFDB1O7cWX2j+yKHASfwkymHREhARZAodxXY0864SPY5
# DATA CX0Q5FWbPsU3hWZcsPJbaaPWKfgoMMv/TAjxF7JJnFNFcqBEsFF8R+DORNQqwMOIW3VdKdRw923S68DS1BlxpnLCLmCmfXyWFLhy
# DATA wTDhW6VAD+0rWuiA5q4oJyRO5OASajhw9uPqzh366HjFyEA0VUIZWInw0N8UIeL5w9hjh8KMemO8dE118oJXErugI9l0D6gKbEH6
# DATA OMkOVeE/AgHlYPRIqcq5FeGjIp+m616166JVx5kBR2HgxXM+HEh+UF1tkAu4IGognnq2/q5IwgB8te+MAyuYNoPiSMXheeSUPz+1
# DATA YpPRrGYokh2qU+bk0J1ztYJSw0IzRao0MOv/QKP+M5jI3yL5APRdkfSEV58DWPkp4aFfekuC5CvU+uqvrKuILx3WiOCNDruYHV22
# DATA xU9WAo3ZZyYLsNbWrOaJYrL78UYdCoXgnkV4fw47yaAdgHxc5rjMA4xHTaAf37GbPeleKAbR5LRyyr7uOjOrVe79MlxQfopffx6c
# DATA PMwb9+rfEV3xmwgzbSHIhBe/ff2vFt2AMCp3tLRzOvQLae7IVCqWZ3wRVaKheZa3k8N80JuMxRg9bjTIBIu+YqDLvMSXX+HQig4h
# DATA QG4BVpwAFVRgfgIMGBoiIuF0wHoJ+fk7Ov4/i4IL+0UcnJeaQT5X14jbPkckhvnH4Cr9NWZA4+t0o86pR5S4ez7uqF1kE5BQaIJY
# DATA yyS8PK1Czqjag1HxlBcqq7ANQSuK8pUHoOE0NIO4VWUdZXhFBlq8d6p0UQ6UYxBG3yQNCu0LyGH27ODgBpePAIymUxAa/gKRw+t/
# DATA wotmQVANc79EjoaupSJhShkaRnAEHcviTFgTM+m0C3tqNxTc15J23nx7hZ/5C5j1PzGC/ep/gt+/nLHTJqSTNWQ7ioYy3LS4Ak/8
# DATA qlzEbDGnhVUUrzZ7j/8jbivyZLCtf8GSGb60b4BtaG42DWXJPY2LMiNHF32KRrwif1FbbePQb0ePekCxZR2jwkUJdk6mhtyXINl1
# DATA Y8rRdUppml7Ew0zq9nqDc5YB+gtXU0upuf0Dbfcq5rHLB9eOJYIau7mR+hUdOLK1EEZBep7DGIuyMv4T3bZ/wdtVdvUUoYZ2HC2n
# DATA 54XCvlz5JDQbg2w4xCdQCYNcf3uWC4VOl0a9VXfoOryteXKWdiss3Hd39Pbt249wRLQ3cM8nSY8gfVf4FLGS7yvdxvgkQYmFeLex
# DATA gaeBrqg8cXGCDj4luV5NPKIiLUDXX5lYlId6UdOQKEU/nhLrxVAVhc9/oCq08Rcu+3stOzTSVKpDRemiB7JSMQQnA/D331LIYPKR
# DATA 2rfunykXKkok4crNIaAqI1huEiCqFBWVWregmsjacdQVuFRMsR1zWwy5MSXMk5843u3RxP2OhWqKxFeaj+Z+c4WEBJX4sDc45EQI
# DATA zPqU2O8wgpwz7JS3EjdFnK1ZiNOlVQrBsaTRhTCBiYdWkXEaNciLG5NqvxcyzSdYmH/3pyDIwOgttY88G2VPnUQ5HXKTqziDQLkB
# DATA cfLNZvBmyyHHi1ZJHummkACTpYocsc2xIowJz75L99pxcjzd4kkrROdrz8jY499HLnJX3DatpLLim29aJOqct7CybH3TNOjK4Zfr
# DATA s7Q5cEgsiTNvkmt/wE2wajtoVa3EvNaWcfw/dB3W7wr52GVUeFX0oJrh4Ch+CvWCUD2cjJ3NEa2IRCLWn9Kcn6Ndnu3joMyJ3f6U
# DATA sNxfOCWeDKxbyGjVXxl1e4vIxRMjUkU8XRoiFXCv3zbDgNKWhRRnE8+s3zicYNSWkubztLQdxan5K6NZWLUwhaZD+exVCJuaHdCQ
# DATA bVtLAooIeqU+6UYVR8oHBaMiUf3qDNtjRka7lzlwNJsXwN8tv6HFpJPN6Pdh/7e8tHzv3l3P/3tpDYr/wf7vm7H/2xsl/ZwvJTC0
# DATA nAMLEBl6L+XioYHShHQEHKxx9gY4hZTzYDLmshRXBIqgxXvSy+dP/dYZDC/fPqlbdgyD10/jZDy/J7lK9TbqIcnNkWfcd2iEjZpZ
# DATA Go+8oxlFphyJWWr4a9Kn324KObzInJelD4hyjG5heNmJi26TLA1oLRMNRsLGAKhWU+WUbdasvGxnCHroh55bTxYwnLst0st/CjBA
# DATA eVoA9sbdAVqyg8Kr6KkGD0zzGjhoZCIbUTdLjvsDIKw7LPMA2pnCzowHUX4yONcHhYAcHRSiZicyEnZ/oxMjum+ozJon+lSLBkM+
# DATA nY5HpQRwpCXkHF82L6OS4LjiB67TMuafDc40pD9OjTLnr8Y8UgW0FvkzsR75V1TkualO1Mw4G8LM5D3FEfzfwCz8K0rYCh2RChDN
# DATA VFyztmBaH5VOSIU7ouFUiuPRy4RXjCJKtgtyjJW3G/VU/ZjRj6JZBcuzv/TNLoAde/0717gCx6xDxQIHNm4nFMDCthqWC6Hz8tmH
# DATA zCTva+PhrBjz4VpkPDMkzrG1QGyaAZUppHkybuy2t54+e7xZ4UjH4zZ+MzazWPCPoqUBoMXy0PRo1Ca1AbQg5z0g3jaFp3lOzP9O
# DATA XOrPYR2BJWW+81dkY/NblCH9DvXLuC3Ahv4aVrbAk//mq5+y/h25739hO0RS2P/6q38fu4Eg27LWwqrKajtGFjG+ipvmPGI4UPZk
# DATA aUYc/jkmuao8Rj/G5VlepgSNZ8BroVhXVgNeEIvJIS3UW3j2k4CEx9U0slRY0LwDVyCTQRFd1x+j37wXIHuCMhXLVDaFNyTtrUj5
# DATA cChsySqAZ+RogGJ1BXRyAXEF+pE6cgWIcp52n2x/zz1PWnaqi+xsfrdYRH99vLUz5evus0de+6US1/kBJB47gko/x0P3K/tIso7c
# DATA OpRhQ8Ip42PoZb/iW3X/Pis4Si/PDSb2D3DeWbjzjzSlL6Kv/oKBGprkTp8QXCey/v5nsd9VC4GVANKRvhkFSL9CC154xSZvFauD
# DATA e0tAQHi9/DLC/B3ayCMZDnuXbRfa8R/0KiNG3kGnikmhIs2SvCFERwxQhjTIWdPA5ff5Hh/U8P2z9s7jZ9tPPoW7Sk9wvDYf7T3b
# DATA 0S+2n3307MmTZz+QYKo2Eyr3A4od0e0wfTpaxopz562rTpJIPSgBEQe1SL1h6HDgnPAiQFYaL92QgCSrIQZK4TRTN4W5v2QrQTL1
# DATA +bWYG+CpQAAstk4Ierm4RUM4ZrW0o2HpRQHehVYVl5xj85mvZrpqATj+BPXFFv3+eiwE4ypC450eUJdOz+LDo1kKsVe0JB9I0Laz
# DATA rh3EveBdUJSrWaeJFYucDphFL2lXupG2nZU0vurYR9Incy5vhyUCiIRnVprWRZL3sRahpqh1Vk9MK1rllErGm8INSq6rFCaZYzjo
# DATA iswBA9AGbEYcii44CzasckYrSNgbFQw4NCxrJguFpuFToW14ZzfubKa6c57odA6K5j8AhPxHogDJdFD1jdUVwVg8JVWbvjMchz9H
# DATA WmczSLPSoodFbxpcmsIaahciLMGHatJXsV67sYZAqeeBxMoU/TgPPQdEGUGJL1kbEQFiQh3Cr9mA2qhNCKuQ6f4/kYEh2RIS6U2+
# DATA JEWSucYjrKExrPyKMUoz0130Zj9GecGuvNRmqRJzuX0CbKHi4rQ3MIIKF+tYltpSGNa+WqCB6Ru9BD4bo3YI382VSIvWXOQcNPyG
# DATA nY6UJT0yPi6nCA00cIikf4Rl5yFO6VfqTGAVlJYan4fALJ8PRl39DJzE7J37O+NP8We28MRVdRHi+BJ3FMiBP2cLeEYQPyGM8JuI
# DATA NhIIEfFbQlL9q78ildO/ljOgOpCZEVlUKjh28tVT21ST6eFZwF9/Okkx0iv+PBolx6cmjYoTGqlsKyTakorFBgXEKkVFuiEHyXba
# DATA P6ugSFaSd9vhdV6ll/JWNx3ySkvGMHj0TBvFf1L5TjO9wB3Zj16OD96rfgfPgXG1gRbFewY/32k17vwPsQ1GMV12ikLuirTKMY6Q
# DATA imo89eAqfuCgeJgkQJdnl9Go3cThIwxp6aOoGjvqJcd5i5qcok+Q9vGPyoSsEiFTdpX3ih3IJyfULlSXBR+OBheXLP7mcTiXtBa9
# DATA yvrdVtxJut3L2Mhd9NpWvvPglpVWtFE/qLqLy83x+la+UygrGk6UNaJFE9GjQmtqGFLxE7j3B/3egMJXc8UFN5YXUhCTvtmGfmgf
# DATA ZHqyBXrxt2yjMDUq9YsM27Hlh1bCITcimBwZXDV2fTzO+o7Nu7p0ckJwUU6rf1J5md+h6PcjUt++zN+rVvb/ZB3OamW9WghLaVlD
# DATA 8HwkmSH9gbtEG8BLx69WKK4f/1494BMX0iABKUbYcMkyWO3b4WT83OZ0Dq04NxjiAW0qOFpFMSgh6+M50x2DgG87URutWydjgcEQ
# DATA NxdfxeyJyo3gK/mtWrpSLRWz4bjOVRid5IidrOyRcP2AwUmf8LssKDdB9+2K5GjUlOvrTSN/T1tYNOjQYAfVqO6/vPaYW1pHFY2O
# DATA srUXz46dXTB3pIlyUmdjnn9ApILcJWKIXxAB8QXSCkQkfEls5i/4zedITfyObBU+B4rib+HtbwjpjFL0kUgZgqzbTAwxMsjEsKsG
# DATA CZT0l6/+Ji4PpafTbWI4oFpkiWUKdBqjJC0YNkI4BIAtI0/SVxJeC4WJjevcQoWU5YX8PkXhKKEyLY+j4dlN7kNfBxShVUuyCpnF
# DATA KBe4SjNPXVD3hQRU+Kv8/otv0SlLvDzBrJZ73L9/v7wDCsR+be8IjF5l1uxmygNE74dAj6a91oFdWwiviuYTBYmpjvpnFDQN9eNE
# DATA SNZMNg6TCG8iNpBUgqlmrChuvRScdBpNWQywptvc519O6Nh9c9ZI2msGhBwBVVBSDy8omiAVjopGi8wYjMOTerSLonyUSoSIn2w0
# DATA 6BNHzCsKfMOYs3HnAYqoxM1B1gkJPKiuF35fEfC4JWQLZsleFLATZkaphOwR+cuvPsSWWQFtJUk5C9vKY0F6DYdisvIcuC4u81F5
# DATA 1tXG4Bw8fJF9Ur+BrA1USN1QQ9d7bHOg5rejvZMUMG4+jtSpw9uUTMYng1EGty47S8XxsJ+e46DWhZzlbEKs9xpi4NrxYFDMuXGk
# DATA 1FNZv2wIJEkZZccUp7blXi/aEEuKrh37eN9rFlzzrUAC80fES4PYry8fcGBZRQSXEdRMeGoqGnpUQw1Syo7xRhDOWLyAaekKumny
# DATA vl27YRXN9pcfURv8eRFquc6+U/6AjNKxWXVJUSdAo0KALtEP9Us3D7oVOzWWi8QhAgFh/ghOfZ2cUI2ERF4TASiBDuUVXA7PmdQ0
# DATA Ym5QTczbrTuF3R3FNUm2pUapIA7aeuF1lEXnyRBPLxPBOUYtRzFMA6taRuquvZEokytYVM1V7M3iO7ExxVehEjOghUbDQU+swegd
# DATA bECd9OATMS90worashdlFR+I2bgvCcKVWKIW3bFkLSgazzqkfJb4KO53MtzdVWCSChx4fRLoLIJf2wCc52rD2wMtMqJYftq8fwoU
# DATA V4HplBBTmTKhdzJtmCWPwapWOAHVz76y+D0cDHoVO9Kd/OZJ7455FzTgkIRbarXxqBBRQ8C7GanuqVqTzDiAnkmH+KPCx8jW5SnX
# DATA ZK3NcyvwZ/+cj2QITT0ZM+FcZpxfW7QGDhKBoRDQ+GgijSroymdDjvVHPhnoUTOE+ws3C2kAQ+fMXUVAQl36blye9uLi+CpTGqC0
# DATA j43xBV4GVkLTvMlQ1i9RLeScnWLhEJhHQVuLy6nlBimaqBRF9kqa5grva2iO0j5NAVeqF6hNJxrVfkakIs9Zn0KcmlcyWC2uM3QK
# DATA 2yxV1BeTfU/36dC9pB00It1bOkQRJm4yVbQ8GsWHCHsUGidA1htMuke9hCIuxscdPOTVOQ1GfsGhfEiyh9FidAio35Ji6B+jvSe7
# DATA yJX9mnko9HQ3TBP01NViWdFvzKFCMeJotexzL4mpoVcE49Tn4zQhKT1Svd2kBzXfbgV+wtYGKM/8M+RAkUX1569MKfSQXCE6jnkX
# DATA vj1VNtd6nNWw8ognibOfc4LzzQ954c9FdvvltNl9XpTP/vyrv/RnTfJrugjWocfHir40emv5wefyAmv0nLNLra2tCoC/GCWXwU7s
# DATA m8iUlv08o6stLiy9vW+6m7UXpNszK08f0Cvlyl0A1kEkw4x6QExuVqtm5nRNWpXV2dv3n1mu/tXfRBvPt2rOZmEMBgnK8PPoE2i5
# DATA oMc3YRhEjy8bmJ8kIxYlzlBdiuVCSA2JR73iIPeA5ghbZfUZtWSVshKgkuuQj1388or2tEobctRAE5pYQeFqqBMzgSYZSjGyHvRw
# DATA MSpafeNoaMzsGa5L8Cajp5lDBazN6YJLueAZjhs9krUAdqMvRhTzez+Gue8vHdxsLIXe7FXGvXrM0yy2JTvJSiy8HlKy6poQwmKy
# DATA PHSONZk2QQu48Qa5y7JfrHHgLMb0QWmcMvsO/kcT/CQsoZyqxmxEr/+BoOpfkcHFz1FX9gUVZ88x1hErFRsGz/uSqvJ7wUo/l5e/
# DATA 0tFkeEk8kgNekvAOP/I2xWoVDJ3S0qvhEiQa8zo4OeR1Vlyi/4cczf7cXho2R6LQMcY+j1WCFig6TDqvJkNLmc8v2J5AblzdiRk4
# DATA I70t15csyipRMpon2RmVjTyQWAgiV9noj2KWKhaZoFjTJl9iWDp4A/+ixR8f/6YhMktyjl9T9iwklfQjcwZN4OXgYXiC0Uab8IPJ
# DATA WAoQxxORYfFD9XoWqgqSU3YGA44l3ja42cfg0zGzZ0HgEDjVAo5kia5RlAEj6/RsERLK3HRGE9lRaA63Wl7bntcT8ST48SNAMOeU
# DATA RtOVhxfbtDhDt2negvToCFAPithaYnPhbMqtMMSTHBFFXEqzvNKDdtCVOoVxMMebbe2gIgpYYgZXtgDHzSthhQXzxAxQVvSsJE+e
# DATA xgQ+wmIs9vaUEvsS3kGY9aCIRy9lVYIlS+PKlr7Yp8qWcoFl6AzWWbE5PdYrz2bWDeJ2hfIuFVWbA6bDKdSitnWZjkZpflJR3pZ6
# DATA 9DWfdqlNEYf7e6V9mdmWqM3wp+XymWq5w03S7PDw62EHPlvhdCia7vwjNDVRnchxjbN+I0/HEsa/EksCCBZjuREfSJmNYReocjOc
# DATA 9pw+8g3id3HV03dQCUffwXV0xj008GCLkFh356DLQt5pOiOLZ8losZcdmtCni4BA4/ltdP8vzUhp5MgxS3/GJpj/yH4R2kFbG1v+
# DATA Co3ZgX5gk8wvkCEHquI/2ZwaExFfkFO3TZ98rqxv4N9/b0dKojVWgqmrGP1vEcgcZpR1IZZsZox9zJ2E295JR5h9D8rI+jdLl4bQ
# DATA XtJtY8pvRXBbEcVQitrLPku7bX1c9uUQTN/Q6QpIbzKMWugAWMmrFxXUlQPpzLlwXpYO7OkGjtP19CEFjve0OWIIEutsHlipiNFw
# DATA 1loop+Higuqpu/el5DQD7HJDYSN/K12aqAvyQocsoMU2Jsr6BMm6aut/v57Kl0eMpPm4zw1SoAvZQMU8ETqwS0oTQPM7nlVzGkH/
# DATA J9+4gJwA/pJsC75EW0VF7v9qqrW0XOl1Ni34rQR9/BlT72wQV7LWTk6si0tzC2bB730NRQ+CTeyvcEQNRwSu163qHae2MmYIrKwT
# DATA Tzy8R7LPnnVNiZ6A9DVWTE+DaSgXlD7Y+/GujMA94o6K4ClN1kSUt4764xRFo5xXfep5FwGPrijdVgsGQBwwjkbJd+FGTifaBpa8
# DATA K37mnBXk9BAFiPFk+Hj5gX+cnZNx2WZLMGLrukgKOE2cwZIWv5YL4oWApsIbZGBPBLTrzGG35VMi3W7afY4HlOohHvBKsNoGDpZL
# DATA hGLp/RmqsFpkUS3Z0Y0JuJJd27HtiSQmimd5pKIM/88sNvZ4dYrWSE6DRQnAl/Og7l9KGFk3ngvL9X5BDm4Y/Pu3RpYcmHlowv4X
# DATA RQRQdUeHjSVFRWl20Dsb3JrSjFkUpveB2inwJ553WdHC9CYKR+raC2BeOry31z4SFS9Hmn4ZvkRdTJtwqrD1ZQNVizM4FYuhmsWu
# DATA VMJ75CpKLFlAUQlX0gBJE4x5m56Vk14FAaHieGh2KjAQCUimyxLeQJTgTWCWF0IhqiRc1m0cpW8d+HOPTl7HmyceUHI7v/p7beOO
# DATA snWnuBbefU7Q3ZbXKSGeb7IomWJIbvhLojfsAJDKbDu0skahOa/0hFYtYF4rvVgm1zP3u8aSLzOGeH7GW4bg29bojmw7YLa16RaJ
# DATA GNLjh++EpJ83YI7b2HeE2nhXHfmwY3d3FX+082x7r725/bj9+NnTja1t5CJsZYA18+cb25tPTDH1xdA1KK7mZNmW7wm89BaRzfDQ
# DATA gQQznk4X+B9UHQyPPXjQWE26KBsXAbpP19Aob7XmlcS7awZk2osP289ffPhk65FaCtURmT4XHSvcMHDTDAz3+2yJotdl35VmEQ/f
# DATA J1kb0XTnyVlaD4S10jaKCzrwT+CsBg6OpeIInhspqNJo2RCsxb7iNthr2YpATxXZ0orBanEYRZLIoZlKCaMbY3LV4eC8n3adDkMm
# DATA TTZZ5taohberWnOEdQdVa0NmeDq+8VUKXYSDhTe4Ld/kcb0K3KrmlDt17W61nMrCVX6qYq2Ubny4NBrGltwC2jvWbJiYmZYXZnPh
# DATA 7fuYvVFfB4R1UaXuv2yQYvYkOp6DfVIl0VOVjhLXD1lnSamFAi+kwAqbmKoRkKWwmCRb7qmPtWraAlpelD8G5ZaFsrR5rXP0wfnr
# DATA ti3YqFW+ZTeUEbyuwe2wQrEV2boklgZqaprL4ADJmGk6+ZBMxoPYNw9+e3WL3W6pcZad0kGmZQrqOCmegRY1rOY2j6EWicBKrU+k
# DATA 45Ya8Rvb/BRsuj53E2d9sV4SjV07z3hkc2z0qOq0Ej3Xon8ttUfLkSIDIhDTO/5DVCCqQ1q+cqQY1TYdYQZrgKlyyFsVB97Zl6E6
# DATA 49hq8DC1m13rXOWtuCbOTqVQ1gCSquSd9G9VqU2M3cxzTv8mWoniCOEUPlJNtgqdkH0j8bAtGahnIkNdT5+D7b5K0K1sUQga+gsT
# DATA AtVVr0E1RtbG3rkjVT2wRSthW+vY5smVGPOvdU5QyzRMMWs4nJ7sDAAcPVZL7WgDKg345Zhrzm3U41sdsaVBuyx4QihKAVcpOu7r
# DATA hsTtSz9P8/7SJVmhmRixRgk5IOVIvkJO3+NL6bsUX1fZJYOMOT2JDTv9tfWUXBZOIslNqfKGNMKsht6MXChbvRBHVkYI2Nt4YBx4
# DATA ZZTTTZ5NTZ9xm2Out1pzjD/gl8q9GuM5fuHK2qRXL9pCwF31FfHxnurf6kI9VBfCkcLDNDc37FLdakxvRnbP8Go02sUQcT57M6aS
# DATA 7t+OnpAHOYdOnOSS3pojh8R5NJwcwoyiFztPIo7PxVk7xBGc46HACo/SPG/MJx1hA39MJzdKe5wNoi8gQA4vm0KVerlJtRnhaUpj
# DATA 7ZfJdaVZL5puvzsE3GLDR/tEqLZIraTktZtPtzd+sPH9zTbLaWDp2HAzJP+gbVGdVJ0IHAAZ5pxR2VGXGVHQEv37xpY9UnO6cU+x
# DATA 0IEnDp/rSgWaQaY0tKRNN7KKWkMfovpZRRFv8DG7YXShUGghjfJ0oyVRhoIAVlcqwp8wLDcVDor42muNEAnaPmk3b/EIMgP7dqQT
# DATA 3mufuJyCGZyk2cj4VwpRzA77F2MJjAGY+1LggHHh1O2gmoPtK1H9oF/XdcRNx0mJssGyj1I1tM5qquejDJPGq9Y8CyY7RRN733le
# DATA irbLre2tONNBj4O/i+OJMxY9yZhYEYl6hb8df6FQMR0fiEPJS2zeNJfzoZbfCU03x64K7rTnSna5ajfZzFsL5TgvI9y5rTERsXa9
# DATA qu9CHfb387V6Sr2jnVWZ5C9X9mj5jSWjq7pxNkSNRoQ3LYhEGy2m5gmPUU9AJJK+epAl67zUyIXL14NQTps8BJblwBU8RNHgdqh9
# DATA NztpHS7pKLXdPLvpMNcPh5Os1xXvWGAvSKyC6uApoU/uVPbjelcC0skysQkkN0m2RyQDvcPJd9y4nd4CFbBt2WoFqTdG4kn3cppb
# DATA pkrrK6atR2IZWyEhdLMYCdEErm7AMCr7GEE6vUg7k3Fy2CPv2q04GEQa7a3Yi5hOlu6pMYSTV6V0smofSEJeH7KOkAAUDgahBCYd
# DATA IcvtGgXJHkzGrdWlJREgc1B8a4C7+uemG/3+JhYato6eLTRQOU+vfvr6d9HrX0Uf7+09360rl5yvfho0AVLTJX8dDj7CEWrFuOif
# DATA ScyCZki/hotIEbKJmRO4BNQegi07JKyYrZeHeGOYxEblB8wl45XopbzO2GbarWOzzC+LzXk1GGVT2lO5qo0N9QYSH261wGkKmF6b
# DATA 6I1zI8k5NRg24rO8UcWSnoyV3x4NvhlqG53yEQc0YwOi2NWJ2FCh16XkODQPH1N8yDNiTyQnEKnUW9RO/pRgJW/wkqtknIGA3jZW
# DATA VdhQmpBGq470xYqH4QZ+KDAM2nTXqJe5gUC0HJmGhDMxUT7zQIwEbrcx6ZPJ0mmWI9vUHrzymivalLjEAzdTs2LiSBgcbxAmPE5N
# DATA je+Ug7dy5plAfFvr4ti2U1UT8dYMdSYF4vqtmPvdcm90gDxi7TqTQwL24RS2SUg7P2Ap9EozRnQ0o0vLAcC5acpcrQS9SX9sYlPV
# DATA wrZZcCBIBDj0FLnQ0i10u7ADFcsELJGnuIG/Si9t7+8bwmITU9Ry9NHrOIdk//8Q5zEllld25P9CxiWIdf6dI5r/+m+rYeQLQaXk
# DATA gtrBq9wYU1JguihTdXCr5YOFec18C4kInADH5LP3s1khjhuRnY1Z2fWIlRCGoNeGe45a5I0vjEN73QS2uCF3aQiibSN5IOuQPEDq
# DATA p10SBUMDBbbtYZIpFFnQvhCaMy9rHCiJCzuBX2ZpEDx5D1N0JrtHSSKj8m03mYuEpuI8Kr5Nvrhu9aN9XyMBdLrH/jfYiqRSDeQ1
# DATA FH3/WCTMV2rJm94O1CJ7DcS7gjC89brasEzZoQasqV0S44PaJa4LnMT8l13lemTeXce2Cqyyc1itTjTfH0SKalREU9U0lWeyEjgI
# DATA oVrC9qgYbbcUQx0GAEWyKUj+CVmkiD8aWiD6FLdU8COtzlgaQ3+xYs+mu2qugv+mTb1dG5oaddspSG1cw1mH3DyQQIY2OVjetQ/R
# DATA QiW5eY/OLMx4yiT4E9LB/D/AqxS4tD1KeykAXg9ZhSanpC5KCenQ8G5YnqaL6IPDrfqhfK6DodVE+qmvaBHMNMsCoomMMxRGoTSc
# DATA HZFPdkUnnoJbTavfyyOkcUv+TLXAy1tYv1ywWc4ERQJ0e5wlGsuytdGtkOWEPLzBUrlV326xVFvvbLlm37Np5HZZKLU5pZEB+kKb
# DATA wbeUrW8zyC1LGDZ0uyEOWPHEjviNUtGQEoHkv9Sc/cNO14nJTpV8eDEddxap1KIxn6cySTcZjiXwnWdYH+YP55Q2lCZpcoShOlOT
# DATA xNqnh4qFnmzPZk07CXVVfVfryOIFV9iAxcaxE9A3wIEW9rsoCYqrs/ztlayo4P0zP9qYV7ZUQGiGKtLUng9yg3RRiOSx7M/nlFwV
# DATA Wmr3ksvBhBxYHExexDVzXsgCvilF7UGGBLdlYb6tELL8Q6i/ST8BFFssqyOqdDlZnVtFw/K5kqu8ZXgxndSrLJiHuXrNYLRKb0NC
# DATA gfq8kB86JEghalB1LpOidxOQh+SC3siAN3mqmJJ5DDPZ1rAmUUyeJkObB5kVDLCqU5xxxlsS7DM4ac4jDxJ2UW/bgWcTGZIXOXLU
# DATA ZvFIJ0BoEjQ2g7EZvuoU4bdBcbc0ilNuzcGhOAkKvDZV9prwHHlLrZwijvuJix3gRSVeTIbZIkb9XeSYlDHrwrEPPheLKmDQEEM+
# DATA sF27lUW0QcquNn+teN8I730MK96Db1cqwm03TboSmpmW9nQACzHoZ50KCsyXVzhcy/kJhiQuFHigqzfL8z5z1jsaEqf1Iistpfm5
# DATA SwnwAF3ByoXSLFuObf7OuMSbtm8oIbatXSsYG8AChysdDrqXbhhaNVKShFUwK6Ukp8TVKg987AUNx3atAAGBr3z2VG94eaeV3jcl
# DATA 5dRm+ZMBXJ8NNDBCxU6NnCSnBEpm2YsR05C0DYVkpNn6uU4nw8bDKinmTzHR5m850gX6s/6OvOW+QElcgLD39kBwkJ0dt4F6uGli
# DATA Ig6VzdERgPQdpcX0S2RaBYgRSkWYTCfOoxcvth43fLpQcpCSvRXAIe6/I653a0tr1WlgYf7DF5505dmuZPq28387SwHTsNPhGp1w
# DATA blxZ6ErmvTQdVlYEUYZFp6TfjMST8beefzK7MSthqezmT17/M/z++9dfiioUY0xyyJJQPtiiu+SvdUoGFYWe1ZZvof68ZdE5s+Xr
# DATA /6txv/7iq79Gp08/aQTOLg7IaIuYrpzu0trYb4zwyvIhxgigPPMm1RVlgAf4KomPW0pGHXuiZ05Pz/oo+unIfOkNSiWNS1CgYTXK
# DATA ODBw3fz0JvSyOdoePiBzNoGKnzojc0ttbbRhVjO8chRWTyf9GOWEQVUG8cbG6HiCx+c5falY9G2r3e4OOu121arZQMvARKpUYj2y
# DATA GA0cBmj30dpXmiGtGFLx2m3tvVLdW7OhTLNHAx0dK9QhcIoY6A4Q6eUwbT3nZHuA6YGM69rqxXBdQ6k4w3WS49VCRO30IQEFVtdU
# DATA p2l3Xt+Z6Y0jc1g/5ZGZtsui6c7RFtmmVNfLykgoWikW8FbABalnRGCbaKJ43mJPNSByfyeHWLBLJAuN2wKeX7KppbL0B0vnleqU
# DATA O6+OnB0nMEOzUAmqTVWY1eLbb1goeuaZyINwYPJknKXkhQ5KYD+zTyw928F8q+V3mf2s1P2w74R9V6z7Ycc9YJnNUac/7jkw2lF6
# DATA egClNOEsiUTIxolzL1ViQEkwlKrknn20s7mxpzLN7jz+wY6fdbbGOW9MNyrl81GXOrDTn8bnMdG+2IOL4Wk2jSP8UMF/avLmybNH
# DATA 32tvfuLSVS46CPg78v4TCdudnA5zG7LNPA6KB8c01DmaGid5J8taYjCI+pb+uLVSRQgLG9sm27B2m05iu40nqd2OjaFlnh33J6e0
# DATA 4fgz6TV2t767t7nztBaZ549fPLfNkPg9/6lwAzrZ2p028LFku5aNK4r6djA5g3wb8VZseksTYd9LL5nWCpCdTF/sXgKYOd28yMaW
# DATA QtIL/JVyYxVFATwSC20659KTR6dUlV/Y638wtJimtjVhVrAJCNqnzbBJozA0P6GM2Ujefa4iXvyKEmj/kmLKfevd/XeajD47hAs1
# DATA vPzW1/YfJiy/t7ZGf+E/7+/q6tr9e+qdvL9//969b0VL3/oG/pugoSh0+a3/Pv/79q3FST5aPMz6i2n/LBpeAurory7cvn17B3hn
# DATA uAh0PIA723i+xVF7yIyXeLY8Gp+MBpPjk5DrDJRvQCsLAvwVBaeeUaOA1w+vcnes3gLTRpyTPAIBfwKslnpE8Kh+D/IFMjNAEhyK
# DATA KByDNJYqMtKdAfhRP7FP9dtm5Lx3zlhdGY1+O8m6PAaBJGoMxFIA+AM+CSBupwcTirQmjfkezVRoQhcmLRyYTgMrInBAp6dDTKyR
# DATA deGDnVmRjQ4IM4pziTFTXrAN+6bnsyWPSgDQ+bib9RtZnozHl5WiaZQ7g/gpm/9FllsLNDvK0DiZabBBn9L7JBy291TVb0YuBSVD
# DATA kq1vyN8KT5uAN8+cQXDWH07G6qNe3u3BTsrCUV+ghiy1+iZyNZkaeyHwl7YUryClSjQ6oPMhCrqRbjrNj2H54TrAka9hci/oY+b6
# DATA YMe6ffjxI8o9vo4Xh67LETuZkGQDHXvMZDaGmRlhu531s3G7LSNjsdzgFRyE2InXYcSMzChpLyscq2PWK/l9lWncFcs7tfv8tRao
# DATA GLcs1Lq4KY/dhMecFZh/qqzAQVsxb41eYP54swZEiA0mYzsVci3SbauW4/B8Wi0V3IAE1mb0eqLLK/cbS/B/yzhZyiCLZfCh2VyO
# DATA r+cZ8U56OhgLrMsVL8d26by1ScSpaXd3P47Gkz7ODC8Dlohtx5LeUYP2kn7RhvIO6qy+i0jQ0ge3lpxDMnr6pP7RYHSejLppt/58
# DATA NEA7s8hsp/0VfuE3swLXvHYmj8EcCyRRs6/dAc0l5rYuKNKh5v7Z104HJyBGGUWmYgOK6b8UOStmx45/EOVIsdYFTfOG5OhnOewt
# DATA igXLnTv2Ol47ATf1ZrhnQcruxxuc7O8z8Y9G0dKHKXBsI4JpprqfU9Q3sSSRdWkuOqlU8S+0WHliZYKLuCy8JxbjQF+rDSlbDc/j
# DATA ESehre9JVFF3oS7q5+fnlHOtrnvlsL6mx+LKOkpaTLgMEBqP1Qh95SqrVtwOvKnf3dwTPdpydQ7jSDgoxRO2Y50eXB/U19DRwQVs
# DATA 4T8abLc0+HYCYRSl38QLWueaeU5CCEobsjZLHeJmO3aVEasrShVhaSTKFBIYAlUaqkYPI7/uLD2BD7yQhFOjwRyUwKGNjtMS2x5B
# DATA y05yPx5JyHL0RuoBbTrEFERQrj9NP+ReJ7tF73x5LSOMW1v5oBbdXVrBf1bxn7VrKqYO7INoJdy1LcQHGKIqVEt3v+CvPGtj6DBH
# DATA R0nWS7tNwhiRspk0k6jaLkuBjagEtRO1aI8Pb0hXMWXxfu+rAlX6mKxg0JeFWUeFEarKT6FoJ3r+bHcPTwUZmfm+XDg44O5Oh04G
# DATA +WCu3gr5UB/BQR87OcxUyu3uuKE4ForI5jVdwwL47jPovTEZd0IyntLGsnzACS65sYbKNR7/EFHve0tLzaUlz86c22qMP0MZdNhb
# DATA x0o1T2VVq1ynFRywk5O7keSqRMUv3TBjrprxylBh0D+0NEr9s3QEdGiOZqP5n06SLtJ0g3HCyf8wSESS9VnirK1JkfNzULxk/MNW
# DATA WHeqyFEryIDwMiNY1UmvRzGaK6N4f6P+w6T+2VL9g3b94Gq1tnrvOuZkyjNp+BeK5O0OUkbWR9mYqPeuCXcd8Tp4B3OUQkXyMbFy
# DATA frZPkyERKMwTIYGy8Whv6/ubJJ4Gzgt4JzQXiR9v7W58+GTzMdFh2Snwk/T6ydbTrT1+m14MUYuAbzc/eb61w28H/fYJJ8wxTegU
# DATA NmbtxHBBx5A3o5u5Iv1X/cF5X8kFItXSAgdkOMW4fNBPlxLn8qaLUQ5g4zYV4OhbS9WaVwKrtcej5Ogo66gy9rYuRQ9a3AX++GBp
# DATA 6f7yBx+s3F27v7b0wQfLimuhUjSCQKFZs9vqk7FjJKOAsztBDjbXm4hmpceXRJsFZtbG0ztuq2I8ibg/4PdxtTEZDoEWNpGhVHua
# DATA Q9l+1t7Z3AXoC3v5eONT/PODzc3v4d+nz7b3PsYfn25u7NjMStlG5dDbYISmudR9ZIbF1iLJCC8d+Y0fFEaEWIA6spV2evZmnOu6
# DATA HRXUmqpFh2lngE7puqB9DSSFD5+4fVzJfXUkDw7s02pe04D06TaSe7/zZ9vtj589eYztX+aRugPrEV04vq6I17oi7tUcHKYjSs8N
# DATA HDEAinWpGkZxGkLcbTuixA/T0QAQaNLPI/SOpAsrISVsUNGINi9OkklO9tKdDmcfOIXniDuI5II3HAYXD/PDlt+pvnCwmsu+1YSs
# DATA M50pA2EU+LgO+9PQxuhCU8x1uds63zOHf1JH5JZ9RjxLI3/LdtTa8qJHlBpZVV43AVSio8l4QlvVR9vTPCJzSyNXstnr0FE1qi0c
# DATA 9pQz9CJH+xTOXQIETfQZbO460MtjYOt5iKfJZQS99hkXJD3y/Y/yIRL8CnYkx2SEuOCg4iuDtppiI6uOuEpxrGH7BjKwhs7g+8Cf
# DATA Yk6/YGCQvFZqihUAdvXllfrq8t7KavPuB/D/PyyEUohlpE9wNz9Eb0HoT0C4821XAY6mXljUlRMK20L42E96u4jXKSQOkquUKA7N
# DATA eSqE76vVQrCn2NJvoeWtngmAQonPGIcwF0ufu+1kHBfItH31dYMzt/trZ9W1UlplFDrD9CDvYjtpxsQCpi00jK5IqWpUhz0966Ej
# DATA IK3a4EesWc5Pku7gHB0Fc2sappmbgO8hSnY6g17TugtCcpHUVQLTsPTZTict9YDqohwbNeVqiu53FTNq1o7T4wvYOJQ7VaypKEmf
# DATA meBz9YZK2lP1iue5KeoGF1BjU6hP1tN3Y/D4BSXwltL7qhW29uJZVv1w+wEHu+kSbT02I4Z0RY5Wiiqzam4PaqTubWA2xPaEkDG+
# DATA T7QNcPtcAp9WV+YZ83M1Vi2PdUhVm0wVPw74SaTqKJWMZC7olKvEU8RbVFAVFLYqPLLtQVQ8wrZk106jYVH9TgCUcqm2oWUt85c2
# DATA fFfAo9qgqI2WOFVFg4Of+/XlA/+cTGUblu/V7q0h3wDdVefZGNvdlsW4St6XRPkJqonwRLDMuJceJ53LgI2kLGBxe2Jqgs4d+QhO
# DATA DovsW01jNm1ZRUlrhBND3Uy/m3ZlNt+OHumtiYAogsMyJhGlsleK0jOYw/lJyu2fkuSGMHCCsZDQlAYpGGHIiX9kSJSlvS5RmQ7L
# DATA Zi5OEay4kIOgqZqtwZe1EAIrw1wHGihKJGYelQOS5ItaF9YiqGOG1nZI1aivFBba57dp8Ylp1TGOg+gb8RO1Zj7rdu0iBbWdaRsW
# DATA JzvuEzq6ymFl+SS4oo3cScmXs3EHRa7SlyeIxClI5bV9oBDjmREGKx0Q0FLDMu4nCvy0sdNKMswc1luBSXivpLoVkj6hfxna2ZOa
# DATA efHwsq7ODlnlOzABSTLtLpQcpagYM2oCO96HUX3apthaS1pMZW7JkmBb4Ay2GcfwPKwck4d4tZSnRU5yZqIXUb9Dmh3MOsu6DFxL
# DATA g6MHR0d5aonJl2rRMltBuI2qOFMz1+o73GJLSQ75keLq/BERd/oLN+8iNqJxw7Ff6BMHj9yP6clNVuZ8oMNNNYqm8FjQiHAoOAtm
# DATA O5gPqtLyi/GBisYJzBwpommH1lkaqF4mEQWxi4Dvzgbd2PMkQ+NSicK5L6M5KHomFkVOVQ4d5quJysf9eMLKklRIMe6anNlyCueF
# DATA Y9Dp0zw3vLSPNoiV0Diq67wWinfBh6qfUJBKkCctbYk75kMgil/5qNBZEBym1czDUCtl4hRlG6imzXtkML/V7q3C8MKNblITwoOi
# DATA 0DtF5ZTINMiY24k0LfZNde5ZebFfyeSa6rbKwW3yGK4diEFFVHiwSd8z6Sb3LDaWnIyHk3FZWrcyfTJbw+ghkzQA9+AQdcnQzuEA
# DATA rWmwtbgkX6/TOcC1Qe9MKf50WQmrYKfkrkVk6qviN9UiP+ZCdmTVtyeFJyLpX1asr4ALsP3qPCJVmBdw8BHqCS6RkXEWQPlO5Y3O
# DATA CQyoYgFZa2hynFpoK8Hz5zdtbe1gU75WMQcjof7dMrfheKuPXuzutTeeb7X3nn1vcxuB647KX0g2UKwejnReMiUibjlNPd3Y+eGH
# DATA G9vtF7ubO9sbT0n8omSmSReIJ2hBm/RYOdk0GR9u7vnG7u4Pnu08tptTVXBM1uJoowJ51CgDKTSNM2gsi1RUXwsRT6ifNk/X1L1d
# DATA i1ae8CvSBOjB3OaGGC8Q65+T+6gRgAURVyakRJ2rYEQHg57348yjNGxmBI+hoX9aLWXTzDXa1KAhfLj96mwxMFfn8oajovuC7XTt
# DATA ZJcG6cNcXTJB8d3WIabxEept59lnVnyxGmsqcyEW9g3JqtAU9THFh2+YXKKitmaLdl3tS2Bx5KWRdyqbYsWTAW+BbJmv9WUnAXd3
# DATA mcazXtTUmCza/6AQR1g3ZtNfKvqYYlpUId1kdW7ca0ECWkqOfsWa/m52dJRStCvmCNap0wGsGeISoHg9bEzG5zqHswyFroWsfawW
# DATA H16qn7ZXRTM4XStcs9LjutNwPdCUIXQtQgOOUptoao4OlRmyd8F9goITSFMmoWiWBbU7QiV7VDoUAdG8rPF1KYK2AwgbtMw3IubR
# DATA 46LRD3hDB5VSFjb9k3uthHqoVzoSQqEZXRki4xqpw6R7CS+BgyXXwsn+bbUhtznPz0QFF8DiSrbLWRo6QJ5w1RnVUFAHaHucS/c8
# DATA /Op1bA+RhDdkFShgg7NCQBNNrfg3KVw0Tua2ZsGw56MURnB8MtZ6cxsjAr/OxHMj2iHNR2S2wXVc6Y4u20D0+J4K8WPYPXiv/cFY
# DATA Mc9gsHh1XA9vAtzY+CUAVpwzG3XGj2zTYlLmj0/gkuDQvkMnPYIKiOZIv3CZ5gUHmvgRHtBe+XzRlcgajFAfKJgX6TCKsA9IKCob
# DATA rl7wMtKTyYpCARJk321GjYAB6kA5vY6AiYN1pcYOgMVyuG4C/k2HtcakNhDML8jUlZpbeRRUCfHAl9VA5EIzAsvcsxnu7dvRhrFN
# DATA Qv0K0L+9AaBbkTFFOiQHW6CTITGGq+h3MoyGTOGio0MgULu9S+YBG8GOHM/ct1/i8DIrtldhL/k8DXmVX+VHMl+WZqPXa4bne5Ti
# DATA /Rvqez4emPUIunXjUddaEJOFuDgnEkvfYOiqaXNnpjYeMpmbjboVtw9oqJOaaRPYUfjaiTIUOnslSFJNQO74QRBdCi0cQI8W9g4g
# DATA OBGGCorjrkqx4e7HGyt37+2+eLpLdi2c4UncIBr5SQIfK0MvwOdJetHNjvF6kpgnIuQx5PSA8PyyH7M6iChgksdbnNtxb3BYie8I
# DATA 6K9WXRzKELkrWEyW6bYcodsHiOpszGgX0u+5mDJrc8rwSyxgsI6/FzMRXTIimTWrv9Yja7lJrpRT1xN4jdp3Ib0ETwHlx9d00KVL
# DATA FQedkN/I/7jozUr0EBrUxr4T8HqguAV2gnVKenFZqbl6YsnBvB0Q61JH1kW5NZPlHCxaAsveWgYOPdQJUWlFx2Db9kvJDk1j1uey
# DATA 4QB5UuewXAlZCbZiDqk1hinEwZFckpogVLqkC8UJ1YUTmlZbeQMHHYHxpC2TlNzlAfHV3aUli35g681KbBa7GS3/15/8L3fRDpD5
# DATA Ta1TDPB0OmOHuJvOdPuc5Y15Q17Ectkk8+F/s/ts+zFFIS5lVRjgvBnHod9qIEPZC5iqJPoS5TZspdew1FwWAKDugRrGAJfQREvc
# DATA oaDbarmH6fI7dcT8Pf3nZ4j4Pfh/3l1ZW3L9P5eXl1fv/sH/8/fr//nsvB8N+kBMjymWTzeNjifJqBuRvmI9epWmQ/JywgsGOISi
# DATA CJBdyqWxgTqDC4nFp3mCZkNJpPb2bp4nk3HW00/jRPtqmlQl2g80PR3iVV9Y2EMTwUhlq0M5L0cto9nGCzvPnu0pSTvHvNTl6hQA
# DATA 7UgHZVx4sb3llc0JXHTlb1nVhgpNVLXUDHcQeLuZWMivxQnXx+pZN1MM1yPoJ04wmL9KmugkQ7SiazPW55dTEvFx7/SvnQhGjbOf
# DATA js8Ho1eOfb02dtMb28iGback5ZrJOmNb8m2M2pG2zy56KcXKWIoodi99yPL2KfwFojIfu68nlMyOaDifXrSDZW1EUqwjTodbz7Ed
# DATA WL9+OraNHWJHAcS5pbEvvT+oCkd1CjQCk8lPKHwGrPrhKOsCKV6LTO751pJ28uU4dGop6FmoDqxNsnoiz1FHrButRj+OrlZWrh2l
# DATA mXx5GN1bU9oYJMYqw6oSK2acn08THUP8597du6t3DTfArUxbMSXNw4tOpV3dnUwXB7K88r4ayXRrmkYT7Wlqy3fRnOaQc38e4mhU
# DATA Y/OM5zGG4B9JFWXzlpxmPbL5zIb3yF0tbsas3zXB+bJh7GqQjuIrrngd5Xheoysqfo0GuuhEKAQSG+22okqcZUfEWl0Rn4WEK3Np
# DATA tg+eNStrS9UEOc1NpLsgakc+qgTE2oIEd9UcptD2ksm7KaL3eZ515IhjllL2PD3ECDG0MOPOMOpSk1emeT1q8sw2vdrjlntzFMcx
# DATA a7czvF9XBGmvo6urBbSCgHZOOTYkvKF5UrG2wEJgGXsJUNMCdNaj6+uFiPIOC2GHzXA1gOMoIzoZDBTRB/TcYIQGTPXlJWACUIV6
# DATA KeNeh1pqC2/3BrflNbztjHXAWl6c7mgwhPdXfFZQ6metyFV0Zfb+NBki8VqTG1W9htGahk2tPzZz1l+vZMmv7SGkZBaQ5Sdpt6by
# DATA hXaUmpQN1xHR6kZO03ES9dbIzg4A79m9etY5hTsO/5zd41WCEfe79X6aHZ8cDkbAj8KioK2v/TLporaI3o1g0VP1BqcDlwqWeMiK
# DATA 95W7d2/aucPR9kdpAptJicyGCabTqI8Hg/phdsxopq40+5SsFvYKxwIdQIVTZ215j8zZOGKX55LTob7OOB9znIQ33qkrgSXX9uDh
# DATA /+GumNhxHZRoaQGEIAdEAgtiF6uc4grBH2KA1O1Hz7a3Nx/tbT3bZu8osXx0QLdphExD1ji4h36JFpKAWbvZMVa0GDUcDNmjIMPm
# DATA lg/F9kE4SKFL0cQJiJOYyM0c6U3AcJzzbw9HOO7CgeOBYvlwBlwHp9CNetl9L6ZMqsHMfM5gsZBaiX092kKox/K0do4tlkiRFdg2
# DATA XjSk86apdglJcTJDQvnkziXhwvlYkuPXKIPdbgkuw49/6i2I2bnMNlq0NRB29NPSviXnLzrBQ0OqD2/hOO1QLtoLPlTPJG2MbRRv
# DATA LIhoBZTMVKrrONoNHklDhtHg4g2xo/JSxHj/qWksEbJhZco2aUtIiiErJqjncESh2bjUVjc+2G8ur6hdVpQcI2OG0ppa00QdJ9Yl
# DATA lAWr2NO0iKXupsXtH43ZM4+DI1AFXt8UXxCeU5S7S+Kqlho8IHJLpkwRZc3msduQVdHH7zschkZpDZI+0wm05RG0zc2pO5r080TB
# DATA kMpR3E3JTquIrl9yHOzQwIk8F7yPJA0tmZY9qenUO/TvEf0bCxNj9V8t1phSVlKGIRo9z/rdwXkFHfTlt7Zl3iAk0tWzhlGyr0Sn
# DATA N0D3IrJlhlk9Atx2OCBKCrlcjHYRyY2POqMEgLpJ7/2GOx/csGnNzbXjb7br1k2ARdoeRINztCFmvj5DExnKmIDaJeAY2QZG8ag5
# DATA 4Lus1+P4pFMXJael8JYk1pRPPN/6kB2G2dqQrbXlgPdieDxK6C5FnCNG5kSqWTTBUaFl+JKT+cU45xMbqbxUDTs6bNlprLhRADFd
# DATA RcQmvBaJe2PS9qUVP4Pbhb1AwgtH6LbNFO4UmtJuq1q8XXzTyYeYL8WMzYqJzn2f3Lqv4zBYC26U3Sms0pv1KGuEP5fvnvIYFBSw
# DATA Y/d6Hv7k+zHNENNmhnbSowlHooikvOIouzUSFA1GCZlbKqFR4/QVinOGqEdrUVdsWEkO7EfZRStu0Pmrh+IWe9Emj7omyiS27UWZ
# DATA xN54njxD/VVbSOoBFuJaDnLj9G8KmaDFFIKqd+lcu0HOfjOSIlDX84mEXKUBNSVUqksMMCo58wx/SHHMSLZuSccmR+eLVhyZvNH1
# DATA JWSUqrhq9vWbZodhhCiWIcFi4/wkA8IzhnduwAF4UZrJlyddMJ9V7/ncFD6Ln5VXhCxsA7UReFWQmmtPYA63iCcA8iuFpxnlycH5
# DATA j+DcLK2sTFufF330rIhefPSDyNov1a7tycUdqQSTllYJeESJa6QK8TB8mI9vG7vtrd2dze9WVC01VpqN/bJkwn694hzfYp58x1HO
# DATA tG9Mg7exFzo+By8BIY97mL9UvVJSlZd9W2HMQUa7LFvXJYg2bTEEF89Os2Sk+EdpLqfz9JebDcic5cUV0ErG5RUv42dZGxXlU+qa
# DATA s7gMGNTJOwkKHWlBiAKM95fqH6B47+71IqCol6iZ5baqU0EwrriMhLICTPqnsjps95GHIKkjgPK8zBk1cIsKLItNnQ0+3otiGWfV
# DATA zyBUgWvNMcFjymavcmCF9ry8NqZ2mKMWmdyYRQ/HBTPNWsmsDTqfty/xfKZdFyA+T9R7Z4DFwU29/V/DDEpnETYy8g6EnMl3tOd2
# DATA 5H90Wh4NejprLKsIRD3wRjhQWuQs1qeDs9QJjPOmGErCMzcNMLiZfkIknQXjBks7AU8r34h2giCoLJOvpvj/HwbWE3WwksYVej+B
# DATA EWqrPZ0G8f9bQ9L+N0JfDxF73QB9hxdpFlK1jGAAxVHsLEfk+NLH+I+4m5cu0pfOXXT/nLZC9E4VxJNJ/Wij/lGjuXjwXlUh/opB
# DATA oJXvNGvmqfqdqo9R/V2hUc5co+LiTMW4/klS0IE6QzGqG5YM4ROTEKbSrZbAFmS0GYKgwoQMx7iZlQPlnF9DI0Sq4d3++WdzmPYG
# DATA 6P0yHsBABuMT8p4hwYbtsQMwF0m48H7GJkIp8N/ajycAfh3EcaeyH0BsB9bKEPm1j3knDbJDA4fYBOmIxwPChf3LWKMi+LdqBU0l
# DATA uzP74s5EvjQNwUUyCzdR7wzs7mFa8a5WvoNfG+LV83bmoU9WmCbk+RWok1nUVbH5kqWaSX24oRhwrxwOW98Lspwp3JLmwo1H5K3x
# DATA Ubx/BSt3fVOgJJpvzYOQertEwxmknOfcSHMY58q2pI67R24FVlmEw5RBSdbLtsOoaeKMJ8gO+SgDHbUxvYZtWjOFGII9RKOgAslQ
# DATA obc2HzVNtyHFC5QDGbx4n2zsOIOPYgzI0k/fqZZa9fOre27AmsU9ywYTmCDpOJ3kejRuPwe3jUSJNQ2X0otjR5J2NoXwst25UiRR
# DATA medE21GACk7OaddUzCq17Xxickjvc0kfVGCHEzbFbJRh1XFa13k5TQHL9dqimWuWgtDodRfULSBVoWNLVG5H5O7MW6qiUMZHSku1
# DATA TXRiGkPEOYGdq0Vo2mZcUrE6W9ZAMy4aKhe8znFiLVINYB7qvLG9JrfqCz8sMWXVyDWK41OhTNhaW1ELrSID5CMS5wwVgqt6rYX5
# DATA PqcJH2AH1p4OVZsSIrXb7q0qqezskmWDdCWZwpqRDCXO8xO+P011yjhWPL6Ed7as1r1vTXcaGGdUX5WmdUeuC4PEU4OXKd5/0c/G
# DATA BwuPLdRjKC9i3wQH0VosbKDTV0tgL1rgNyTmliiTRZGy8CHh9BZZBVKIGCm3sL/LJQ4W0Cq9BTucnwzGC5sXaWcXA/u1tNWrWLxG
# DATA 00w7F9UOaUzDQQtpmGgL3rpM84X9LaYyDxZ+kKA1+YeXgYHFsYcvYzYN7YwpOVo3Afzer49SchicVjLtq6s+26jU8nMqaLhtDBzA
# DATA vgX3QO/kW2i5oE6woUVNR0TPSEUXTgFuXbypTosKhM2kR6d7nVm0kz1En5KzF03BX7GdkPBl/KpMNe5TojD9fYKn5RMMnAwODzzP
# DATA hgfg/bwnrqSqLeD6GhM0spLf8RAyKef43Mn8AY/yL8SdsegP66hQ0w+k6id9dDa2qmlx2vTkgww8pxYhgMmZB0OuUEtTKyfDzK86
# DATA Z5ZDq8K0Dggsc/7JG2UqVEYhLb26vpeOECySeo5wy/7KCsWskOARFtFS5gPuCIOQ7J2Syi3eEQLMM88ODtnZYx1GYjo5Gtbe+VkL
# DATA 0azkKLvAgMownjrbThjvzeRsgLZfmAtwkeQQI4AaeZR0RoPcmFaMjEFJgYn4Bgh71e2N2Y43Hhuuh5W9Ue0DpWx8o4yNnv6ccy+G
# DATA Neh2jkZhjcM5GgMnyc/La4vB9zleHOI2iRzXj/g+wLUuTa4ZDDRH4bUKyRzsJMB8w7x7pRkFDv5kuBBXozTjerizeyNebyGQQ90b
# DATA k7Gv8dgsuvialfJnYvFTpESwl9cOXF/KIc7M8m0JcVyvnRvoZJzGputi7JhyUNDW1ZZrzDy2giaskgAf1CJ5diZ/MEVuFSxvjFdv
# DATA xmLQ++qMI0fY1ztoloWIjy8K+d/nBNzv7hBPDYrBF9PfhamTmC3hKlsb63QbRg1gYbVaHj1i1v1nIupdX/xZso4SBoQJicKZ9pSM
# DATA pLanIpqDPahWLRlJ+TpNOZuc0LiEavQOlm1uWsATuolpUvCvjZ53FtTnNZDJmItFmp8RtWLtPLOMRxngdNcj1reoKYiQS/tZ6yg8
# DATA s33SxQ39W3/47+v3/0ag8zVmAJ7q/728tHx/+a7n/720cv8P/t/fyH8lTtlJPmbHaxKJXIwt32t5w9pinTe3g0yp9q5OR6P+oCSL
# DATA 78n4tHdDV+9a9HwySp8P8uyixPM77QBtlwddv03uX8rYu7DwaGNv48mz77afb+x9rOg+I3KlzPIIljAXhdyNNtCBSW9wjDLa6sLT
# DATA jU/aqo0PP93b3I3QzsXJzEdlnm5sb320ubunCy3fW32fP+1tPn3+ZIPf3uNXu1t7m+2Ptp7Y7/BR10brPav1zU+2dve2tr+r68B3
# DATA 94OqeG8tMDhd6vHmc1qG9xd292BEbYxWiorxhra/Zey/8G+evdjZ3ngSKFC3PDSkMHFYgaaI7VvY2Xy0ufV8TxcwLR0mnVeToTTy
# DATA 7Mnj9u7eiw+hyGH84FZ3QIeMDtDDB/hv1AN00rqd9m8/fEBOiIBfRhj9+vZkfFR/H96S/vOhCIMfLPLjg6F6g5yYCVLwYHH48MEi
# DATA NY829FuPN7f3tj7a2txhQxAMdZch2RLvJ/XPDvbZn7l+cLVUW7t//RJTnn28+Umg7BEZcdxb4zIUV7a01OoKl9r8ZG9ze3fr2fYu
# DATA Radr4KjI37TDSTtgiehPfkaxcxrji7G8Jio9blxI+fP0EK5qdgSUX3ytcwzvwmIz924Y+WIu6vYwyUZ5hUS1vnf/1bUdU79mGGEq
# DATA HYqsz1VD+iAzmvjxi+dPth7hQcSoMe3vbX5azH6AsfedzBRO3gM1dlyJCtoQVZtB7Y4VXoajJFBArWowFSuZInUphA1wdHi2ih41
# DATA FvXM7Q0OMeczr2Eb3U9b/Nv1O3zRz3RknHC8nFq0k3Ymo9zEvSnGzyms49b29zeebD2mVVSpETnRuSwPgTjPa8KL1G5iNVQdYz03
# DATA Ucny+yQ7il++JGd7P+G4P7AX27sbH222N3Z3N/cIBMdGI4nQ2Ab0ts8D8oJKuZgc5oPeBDjUKssWRvSFxAl8DCVkuXLN4FAJd31v
# DATA w5mxCg7ssAV00T+gqAXYZNB3ET9w1q0GXb4Gp9PG1w1gdnJELhX4FqzsDaPynSag2h8PR/0fJ5OLH/cnvR8DvNhfhmH9uDcc048q
# DATA FHrZaNypfkdGhax/Y6vIHx7JKJRSVK2KaGca+eToKLuA43uOPJsSrxggVH2DHXVyzcup6w6Irr/xuXO2Vc7ew2jl7uocV+Dxs6cb
# DATA W9shA3INzCTvpuSKacQ6f3KcdfsJPKq7n+SdLINnWSj7JtsX+SY3VA3PvqPqwHOwPIo8wtOdFmJDziwcCRs13Vu+Vl/olACqS3vV
# DATA qZYpxnEbyxrQrWz0Gmijd9OFD8JolBuL7k3LjV0rHAYKCAuM35LOUhCCBnjp3FOuDjlymbqlBpy0E8elu+xcE2FmHWtcmE7S72Iy
# DATA JUJ4+3dGGHw0R8di4wuG/sX4eDBFl0rJW1umtUbPM7eVo/UREAnbg/FHKEsOxFAt5MmSDIBkoftk+3sV7Mexzj0GYmkMYBM/UEod
# DATA Jn/xXXY44Uw6S1WU/V+s2ZHpgutEC7T76dMnW9vfcxNlmWUi4zbYAqWP0cN7vLXjDm9GZ/ambGw/AvL62Y7baWWQc+xLFCoMEZWw
# DATA Gqi8y6Cpll1CWyar4XsfddPf3/ukOs9q/WBniyxzSqZg1q1lrZtRNQHVijKct19NGsz2s702VNx8BOP49MYDIaEUW/wWLMML5069
# DATA IJEUHorluUcI7b14srFD7I4LUnBcCqCoNBfjExeC2JDGiL8KV1lf5H0uese+0AfVgoOyublhiXT7NHmVtvV6VXR5ymZx9275bSFA
# DATA ZZovQCtqnSZltVlIduQsjTsUnqB1SEiv1ua5Cj0FWIyfPROv8ojStF6WJpLanyIXhbtqtqzBIXZ1RUIK7aNui3vkdoo7KfND4bS8
# DATA pxg15QfAkqOyI3ZLqR6fbT/5NPqxBo8DtHUyakgGioXPH25tb+x8Sh9DCso2/cs9U3cUZP+Q9ZVAcaTJabPonID1CRlwiQbC5/6g
# DATA Up3uisHVnStnXplL574X/4pAftnwbSSpBKWJtYCFMEoyWtoLjhT0HtxxXYqDec+anUSoId5NDYwMbM2Ys/6g5k3Bfqb87O0+pxWq
# DATA UK+6ln7iSvpR15lCEtD8H328sf3dzccuEMLBwkn8Y086Jly0uVNN7xBrz3FHR69Q2C2NwsygLjGjgqsytvSa4QNNTxrG++p1lTCH
# DATA LHUGI0tbb1FK6vCGQ/z4vAU6ORHxtb/c9FJqdU4yMu00fSDbQo3rC28GU/XBBSloKmUFnFlQTyGCSx+/smZQPPCG+L8stvlNSADe
# DATA YjO4sLd+cDEEGPowR2d3QjOKdwjvS0+N06+7uEHlagl8vpkCdebxKKpJ7Svsrrf1xbkOjKT4nhXsVIJoS/YEZUNKklwJCaVM3ghG
# DATA ZragumG4nFpUkEA7jGiBW5iHG2XIJm0+3drd3dr+bpEndYarQyjKuH0BmQ4+Eb8ckdta7DiLGDd61S3KqvC5gOI4gxVn5CYRivI4
# DATA F+mAFDASFuyIvc3oA2Val7eI/2ZgOcW/OmvyGP5ao+9hyjPKiMh97JO8iYfVtLPLphcYQDznQEtJPmbLu4rUl3sZp2d+kmFPJmKa
# DATA aRwOuphICpp6NKDPJIvi0BhesYaISsTgCLDtO5g64jeZi8yijcP3+/YcA4ejClakDZBq72Aso+Sc4rJcjLXExhbPhoWsu5f9cXIR
# DATA lK3OyKh0kzEG5DkkzknOkagpXOF576ZNeAnRxaJubLhEoMbyaE4Gi7ciHQtxdQt1C3nnJD1NlKVsziJLOk1YaF99P/Cdt92v3sWa
# DATA a6UUCTU4z0XIvi9jOCiZCRaVfKEFkTR+I4m0o2F7wyEF1BzQPvGI0I2DHyvFMXqLDW9krSXfMaqh2ENUm0eTJ2jWk/UvYK1iH5hv
# DATA hU3AjJjUqKxs0aAqS8X0k5HrhfpTQkavT1S9uF2qtw0WnlaVkFa9x8N+mlxkp5PTsmh/2Ndg1K2g9g42MFpdYc4cHmXBpSWtbFIN
# DATA ciZ7tZyYfAIz0rurunpvqXpQrb4BsLHTxWbirIWrx9t0MAVaUwnrEODnVXVO6aM+qEbve5MRUgUnnW2vS/GJTXphdWyZXrG8L6j/
# DATA sP8Fa4WCiaTwZaMD9Bd2VaEMuNJpMcWvdGYOSvzyYmmJxLJqHHJK5NEH3gpCGgX4HGT11AWSWcRXVyyVvr52hqMIe5qlpakhtWt1
# DATA Xpqem24D4Hm0+fGzJ483dzAU697mJ3veSHjlKDKpt66uKDPO+t30gkehlDJ8FHFR15bWwp+C0OMqTg4xoqjSJNPTotXBNacRyTmg
# DATA qxzTueRzO5v/9gUwl4+BUv3u5q4hHxdssVAup5PbdUyvMYnnWGWnrWrHPX183TeKH+l7ykI6tkpYxzJw0yZy0o14rtkguQ379uTJ
# DATA Fqq+iupnDUEPGCCUqjc8Wl+K7F8BCGtqqGZnpa9Mww/VaxsLedwEE3pwnw+MOIyMKxkZkdatoMHHBWuqK2CodeuK1MjYQsV54mZq
# DATA EWVcZyvCqgYNhUtj/HCh9YWicqkAl8Tu0waxCkpJOno5K1oHOBtsuDb6osZSa8X4eXI6rcHp9d+AjtvZ3Ea4YJNxobPD20fWR3rd
# DATA MdQeBpiWjeTXSP+JVlW22aapvGOiw+hJSwpwuDRNQOnyve1nP9hmyKooK3fw1nnL91XzB/roaYXfZb9jC8IsWVcrIOuaT0YxXXzF
# DATA 5+wm8rCg3DkouSBBEk4pJHAI+kNOE9rYrohMsheENjeQZv9gx56s42Oz+cmjJ1+7mFtEP+ibUyLsFuGvpMFDhsT/dNSb5CcVJ6Il
# DATA r3dBbixLyPe36yUkoRNqJ2gQC4O0n2MuFFLqs3U1W5+3AR6rJOl5igHoYZvyFkanqWFSCQ5/8bJv2QkorlPGARVOs04gNmnJztlR
# DATA RunUWmaIlqEdLRWFuaYEYPjPWoUyAIpyhNfSivbprUhAfDtF8jb/9ZshJpwnGul0V91Qbbna1i3PR522c3fhIuXjdsl1NtCoYX8K
# DATA hUU1fZYo+sqioaoPQeG/s+DvTv82Rzg8E7/VWr2w2BJuGvJ+A6VQkwgaPAt88HQXzBQOxqXelUZ3gflKR10reD6lAITHJQZ2gFI4
# DATA 6vq+dAScHK/VCfpsyfemywWN0AV3SGBSCjSGg2Gl6h14VdZ1hnDQiKNjmYGpCjvI7ZdemFKcxfW+VqwFX0dZKogiJ/3xyMJHOFX7
# DATA ycrKTiSdzKw4dWm3GbQ+w49E5JaWsoVkfDCAwGIm2TN2RuETbfHDqGjL3Cy1bQoTZHs7m0V1pn+nMB8OBxZf5JnQBoWnwDomLkVa
# DATA JqjZG5wrP9885MdjbggGKTtLFRpQz+3xgO9gI0EfMzh7lWrZAk43dKHNfBv7nzKtTTjwgpkY7ajKElGJjZ9wTc+6Wl5fXWVVX6gk
# DATA OgWoYg7XLA/7MIfOqUQhKOrygKl9neFXc6px3RseQgMd32s5QyktzTmB4SB56YPL2/86jCGCITfewkAi9N8NjCZK9vYdGlLccreH
# DATA 7BbUi6w/oCvo2DHYNeCx2pxpmzmPWUL5PZSUuuhU4Yx8ajVGuLry7DEeit+/bRByCjwqxni9VzMtVWebosr+UIuzO37bBTJXp8HR
# DATA 6yrU8exKZmXrLOedox4LqfQCLX/Nmz+f+U3JQL9x65t3OfsC+qFIYwbzFKcjZ8BKrl6dwdqXkk03MFQQCtkD2ZqJUyIyIY/c5O9a
# DATA xoLu0J6QRdtLO2HebSvqUBQSj1x31I22vV3R281Nu9SmMM0wKhkb8/oy3NA3Pe7KG2oyX2V9lqSKJIqEqSSKMno2/Ay8TVHf9ma6
# DATA T/OaOqeXcSidhd9dYIr7ZuDzaPj8KgX3Ei0hpIKyEAe0au6rgDKHC4hA1qx9YQpav+VUCOi5Svug3fDm+/HmJ8WJUrm5XBDYNn3P
# DATA iCuN5Fnoo6wfOQMuKsZCSrGAjp2amzp4KnEjRaQ98jkMDRHhAHgAqrg3uMRAUCGpofkKvIz203Qo4NNk9IoQxWHoANfPllWKIVeQ
# DATA ZMsvuYmCXdImgR/Ph6HoF+GZ86YYf5baoyPLv2+qEcSpxgXXiufpiCIjiP1HwOajHO18+GL306Kdh8PV27StHd5oGlEdkNGFVsiW
# DATA RvTHcSCQHns9n+ZnndG48JVfk0Mu0CwWIqqpT0/gZHz45NH3arYFbzlXVYiX5bAWViQmuysnHhOsi/W8/WFhsyRH4zvYJG1leXPT
# DATA ShgLRbGo9NIj9LfLjk/GLqLNL/MGQmKANae21VoMCHZyERcxLF09jpaVHYoUmB3qG48eP3lS4UDFkzxtk2O9FcDjaNJXSfzUkZIm
# DATA ODoeHJBkvALHipyq1CB1rYIMsTAgVbSRjI5pRCiNk7F12hTwTj+hwUZ7aL2Y8XkC3w/cXjBADfp4t5xGivJRXHviD/FHW8l61Vfe
# DATA E/xMv9oBIarqseI0QISxiPTxA92was1pxi1FX1SxFUqluhTKVUfiEQl33LXmB7vGm2qUc1QAnUjpfWNz+9nup7u1SJ4IpumnZ8+3
# DATA n+3tvnj+/HrKHvLFkMtT6ZCJKkr+AI/qN0aFgoFcdMR7K2mvI71W381JVMhFl/fEwtaXkGQ4bE+xieKVDUxky7KWXRP5b/5LFrgj
# DATA My9X6e2ZeYOCs9nYe/Z061FbKYAB37ZfbG98f2PrCZqA23Y838h1m/fKFa4dbzsLZuhn4erZBwaLWc/tEsWRvopek/Y1E0NeuWfF
# DATA Rt3S9lmTKst+lEnjPDntOhZ3deY10tGmShE06bKIqAxds4Uiin2z88TqLVk5Wyng3UbRJ91SpswNf5/aSsXtVdEgg6N2UNg+i7x0
# DATA FZ/a7IQBheXeH4yLyKoG05ga5WIUc295jL81UYrsnANvVH8tqxGyf+T3SPb7jeeiWFCljcWHfJ/TWfjDjUffe/G8jSHUpjk/U6zD
# DATA IrEeFgGovIx9AHdoLUYGU1bdgiY6KBoYJeeKzS7hERzuwESE8Uw9pnH+xdjsKsiAkzDBJKLTBkudFCgt5wAlo84J6gWaZfIHKQBj
# DATA tWPKTJFIvAOZghmgFiHUJFDeNy1LkHg5BZGCMPVmoNRC8cSVRcSYHozBZWvlEjuGUvs2o14UR6gFoSU7cK69diQuSAek9GzxgBSs
# DATA VueXEPCNjW1KxpwscwscJpldD/xjaBcuuRzB0tVAKgN9YD1YgJb+9u0mcAejKYBPIluMkEcWZhbVJeDLFaoWu7DwgyfCM/4IIckF
# DATA u0SO0KwmdS67hUVq0XjwKgUSctDr1qJ+ei5BHlWWJDtGhNqHEGhbMBHXS4bO3sdW1w6ZZ6EIExa5m57hmlp13I9zcaW8xiQP+3R3
# DATA b/OpRQOq4+F0AYelYsXJQhMgWiLLrMFz8JZmyNPczgo8bSctMU74SGsnk2BJFwZrqbUGos1oWcHR5lR4VisQXzYwawYgmYLETToy
# DATA xep89pvR21wlO78F00QKP6lzxsYyDg6Nz8/P2e0MDyGArfBJxQLw4Wa+x4IQvfWlcwG/5QoJvSTZOpBssE87JvPodWXZgJ5Kz+E3
# DATA XjhnCbHM7jtYQa9VtSlyt2O+3PiCflzbflP6NBFuVqa3Xoy9O9HKrBXUNWxtu7LXc3bODnjHBpnBEEJMEx1l/Sw/KYNnjhxUOAjL
# DATA ypVz//rUF50cyyIyOS4UcYwDqUQIMlg5g+aBKIWug9JHF6IS3ubTL7Op6oxJ5pMaCIlJoIWAGzBJH1S5mloaX/443wBamL7r3PpC
# DATA KzSlcy3akyZqvOrVgLcyc0QuorE9DmWTa+b8VX1LvTwP5teYdZS4mR/BDemTrVzpmbVFklK8qP5TH95YAygN1Equ49uT3QzOXDgm
# DATA UEsAVs2CT5oSN+Dk3dHkc6jtaLAekUoRH4taLC5aDdPu1mQPVJh8+xSEKPciEx2ipuck6MMx5HwKH3fhoBbpB96EAMkfXC3cvDkI
# DATA eipWykTwJs/NRUhx3WvQV8oLrWagpB2nM1bzVm3ehOPY29nY3t14tGc8jFQU9pBC3DA1RJWWck8u6yANsehzHrzhHsyFmxCjgaoW
# DATA 2jEkosEsM7FeejEEUpa8Gq1zsGBZORYPuwSKZ8YT741q5C33pT2PeGQWI9KZjEiG1XorGkr0RGcKO2GfDt6rybPZfpU7NsfkOVhe
# DATA 25NQBofwchbYUDV8zU+a+27y7PTosJh1py+0Mi01gJlif15Xl9TldIAW0FmYRohMkyXZp8MhA24gIpC2unrtNWWjBaylwMmSA4+y
# DATA Y3Lgcq+WW3XBVYoX58WtVKcf+hty++aOHacOHae2F1cdn/VCBPUgmiOSmdrcUHiMbzBOQza6vdQi/wL4pHT4miC/4c1SKninunzu
# DATA 5lgG2Gsaquk0QOMSfRsgRq2R+oHgSsnRgqqe+9dtugf3BoO0IFCteB+mwKJa8MrQnGnd7eM2Y+GtLZoi4bnJVAITsEEgDXA+rCK6
# DATA mUfPvr+58ym6gX/0ZOvRXlydBrf0dGdfr+K0ijtZ3BzWdZaALH3b9Zgo7ZJUngktp074m8SNUuCWRjhuUtdyLDZXnNMAbvIpksCl
# DATA F2crQ0tMvaIijTClRfxZLSV+bGUdra/fkxqBsGu2htDfCmH6roQHEaGRQp+hs2vkO1F8nPbTER1JqKjuiSf30ZaKTU2wadvFGcTI
# DATA teKSgUkeZ0mPPaTVbXXMcORluR+aNskIe33dxDdZyxxu4p6sBviOfL0cMY3ysbi5exerPzSCEDd/NLkKOW4dZSNyMuljVigp4dtL
# DATA KD0/FS1Peeptil/TRES0g2Ig21jserr1dcFAxnPd4u7mdd0KuY+8ZcDlYqjch6wTdDxLbrG5rcqSUZ1zogVpnrPhSD1Z61twjBL5
# DATA lgaLU5oKuYTNNyJH0Vw2MGfuJNRTTwVhnB5trRgcr/q2Mwi5C8/jBzDNxhADqaWjs5AtrxuCT8kMfKTq6hYXShZDhJTVYoOWi64g
# DATA A/wywVzgsR4cythURq9mJP7zlmMfI46ANuTdoQMf4cg7jblslCEpWCWmhsVB+fE1WvEIgObglPxDyOdcBQewGDVbBTk1Egd6j6PA
# DATA UZrSsOlwMOgFTOHVIIxYTL9iKwAemua4gw4BOlLI3PIoDOGzuasDy5k9cwx2HIWbuRtGlBMwMRdmzJSeV3Rt3L8L0mtYlZDg2nFB
# DATA 5+U2fi7SGj77lIEuNI2qsAFT8H5SKZuVb5VbRhV0QxwjEUdskXIOJ7Jg6av9XpkWKTP/Vw5QZ6mIf+ZRVulBqXo+s2ItchB6zwEy
# DATA OMJGAWJo3ivozmWDCz0612HGhQlWIev9gQ0mrCLy7uDa9/WwD9QbH6D5DtGNxI4BPBBiMwKzCItQy8nm+QfP0rrA+WUqi5cIv6Jw
# DATA +MrpoMz1bf/ANWmrzVdLe/pNIR5qfnX9xXH/Kx3A1KMS4vPxnURechbjTZZ6SqAnjrY9yDpsRpx1oWJ2lGF+TiRMzKNEgFLDr8w+
# DATA JCbeJlKm+MZqrtUq4vGqEWTmaU/J9Stz4nsP3jD+l6R/DZ5iRWbKIck0ymxZKJNqqS8O565GFAyHdeOQWHbASCculurHiotlfPtf
# DATA pUhB+HF9Cvr/AIadagXg07C+mZAIibx0FDcNHDlORsDikL83DnMxKoTHEMzFBRt+jBI7eBGV0B37dq0mKNbamjteCdBhIsldydzu
# DATA 2DF+JIQggFXOH36cNkbHvcFhJb4TV6vXNYzF1+olp4fdhIo1/UxiNZUlhD0FQpJYP0JKPxWxV9FYZ4oxlOO/2tSH1HiyNhXlGnZ7
# DATA Fo/Gpgr05wG5stCbjrBt9jm4LutdzLFsywsHUDpGPXqFSix75hHNBS17HDWEltLcCliAzOtabsu6b2rG2Hb0k9arQjZBm3oSqNeN
# DATA LSoxiFsIwMXC5wSJrYBdXRnxVXb4HNoqMCdDVamVsokqFd2Q8pAXWTEuWNOCw7bprZT7CgZLL9YutzIIFJ+bb/ru5vbmzoalLv5a
# DATA Wac35S6MFt8aEZeqen4TUtTyCrE7VUGf57SPUI2RE86NvCfieRkbtCwq5SOrDss4rVzY/mlawB5tJ9B+vrn92I13a7QZJTTwTQQ3
# DATA RcVF4MDS/Oa0iZCW5pqnOd8BUCjqaCZzyjXuIUNEXhfPLsSZry6sFIKIt9U7tJblHtXE3krXLfCo2/b2JWipL2wxdz7bCsf4I9ld
# DATA +JvkfrZ3S83ZZw68ETv9zaQmjTfWvChMDo3RM9a8MWjbfOfST8drXP8thQKuQMBbRoex8BatxCyZ2nSwnJmyLTKgYNAF1EbyPyBh
# DATA z9w8lkAvjsgQivOsNzZGxxNc7Of0pWIFem7FW4zAo8NJvwtoPALwl/QiBLIKXeQEGAeTcUTrhnItzImAY84bOqEutowxxtuJdFaJ
# DATA 63U77hrKJVvPtZigrAZTm1PLWHFWYBESWBktRJ1aj1evPmKjzvnGIxQQopcOLxgTE2M4ONN7wzV6g2pybOYeoALPdesQKTxMAdak
# DATA Hv3BmjkdmGowTTV+buDAC/efL3CR5SdTCqomAy8Y5dBHJ4ujUffDlxB68csoMlQ9iwh8qt5Nps3esmZdYS5/OoHB5JF1OgkoBpey
# DATA ps++Pgo4Cu+cFtbJITndBag5q1UrXQT5EhSVFrX4s9fZrNl86+UvjtRPzBJ2o0kfeDNcSTwy2PQkB6hasiaORiS4Jko1Qg9GNWEf
# DATA gWmrMhxlcCWswMvc9TyRl6sF1LE0S40ViAtSGMBVTCUEqdBvZPqL4wG6GPncFsYZyMfAzo8KA1oGkK+vq044g6I2k2TFCtmvb+rB
# DATA QliL6jSBgfyRcaXoQ+02CbLabdyNdlusEHBoQN+OK4RzYMG+dfP/EKvQ/ivZYWN4+a13/N8S/HdvbY3+wn/O35Xl5dW11fvqHb9f
# DATA Xr5//+63oqVvfQP/TTB2BHT/rf8+//Nzr13dZvHU7eZy7TaRGreb+1e3s+7t5m0i7MYAH+Cq3K7dpiwV8Pr13331k6/+8vUvv/rz
# DATA 11+8/tVXf/7VT7/6yeufR69/Gb3+Hfz67Vd/Bu/gzesv8dfrz1//FipbBA828X/C5395/Y9Q+CcltWoR/P1L6OE3X/0NFHn9a/wE
# DATA nUJRaPJX2Bv8/6/g7a+/+hkM46fw92+hIrcIxX/71V/Dx1+8/mUDuicR1u3m1W2VQwUG8eBWd0BhICjpxcOXL/sP8EfUAwqr9fLl
# DATA 7bQP/zx8cJIm3YcPTtNxQhmK8nSMH0l6Rt/pC15afH2WpecYFgl+Kgkavj7PuuOTVheoyk5ap4ea0gTUcyD20tayaetkPB7WEb6f
# DATA YdVH3Ep9F/OWZePL+vNBL+tceh0IEVbPR53oZZynvaOX8XrES+6/HF/2Uu9ddnrsvCFTueZ6NDj8EWy/fOoD0sLCh0me1mEs1isM
# DATA ylJnMsu8La6OdQi88W9EZ1k+Iap3nB4OBq8iSlcDVO7xCfIkJ4BITga9bk6ocHwClHECaDHKT5FwZmYCEypHKO2G94CWTqM0yVE9
# DATA MR4gUmxEu+NJ95LqDkbdrI9hlySSLBB0SFKfYkBIGjUd9YfPUbSN5M0RWo9EP47+7SRLx9HZoAek34NFLvSA7HVGaQ+nkXV4ZjDc
# DATA I3xeTHI4L/kivm/kZ8f4jWhKLHsKzS/Cy/cuTnvUq90S7VJ+kqbjUHu4BY1Ont+wGun5VDXeCgyhXyjyIyyBhH06evhgkQvCD7oJ
# DATA eE0w3R8dERICYXUbVFDrcFl60CSN6VU2tEfzbURfWGgXPuDuyDl4sJjwbcNerfqHyFg40zGqPWzG3RVoo5+cAY2SJfVecsjL8hTp
# DATA JnidHSdy+LCHkvaenaUjvMfUllUqh/OTpbkutztM8AJH8t4vjkdQl93B83g+GL2ivaGiizAeWVScMJOGXayq1ueBpGYySzFEXQ/W
# DATA YMi0/HDvJIEtHCJNrB3a4IjDb6DV+g1ofvnhgyEUSyOsC9fjMjpJzuDH4Aylu5j574QuAKZypM+4G0Rm4kkdNCKoC2wzmcMBJQ63
# DATA bYxX7HIwwa3DykpQpa4u9Dp8+KCbnZlxM2jI/ZNxOBmPvQvjbsWHQGSqbg5T4Hsx3q4stNcKqgcH/S7caqe9eTZtEcaK55xXO7Ds
# DATA 8oIXfeXhs1E0zGBgkyEsEoCWowksymDQw+VeweV+lPQ6E1JHHvUGRP2nCdt3RwTto+4oOUeIg3Z9uMKwX/pwRN1BylvZTccYrRA4
# DATA CKBdJ3i3YOCo96XANRTIqDMAEj1DITiv+k3On57vIh64hw+OgJTHkzh0bxScLnspUOrLXAK2a3JHQXtQ8KHae2coJhEZ1tkgyP5H
# DATA yelwHen1s6RziQOK/su/RDcaP++aGvUiAiW8T4LLAembbv+A7f+A7Wdhez6Wb4Dk3zGOfzMUPxvD/38Iwb9j/D4Xer8Zdv9GkDuf
# DATA SHv6GqH/t3ODCODPxp0A6Qd5qjDohkKbLM6DHgm7K/xpTxnpmsRMc3AkDpAwdzhWJFaRLZIl6GQjQr4kwPMWgpaHSBqFgnMSp/XS
# DATA ZESh/E8BacPJ6tUIAcMkstO0Gx1Ost4YZ4DwMecpw0hf5FiFqC01PjUD7MFg9I6iB3KfIGByYNDvXTairbGi4TqY5xsxPi4coC2S
# DATA NBu1tiIFki5iGBIv0hBxU+pEFuBdz3OKYxTtpumr6E/hrKCxllIunKS9IcmqcJBRcnSEu4QESXKUji/1DD8dTEYGR8vUgNLJo9Gk
# DATA r0nNQzR2SkeNaFMSDeGS4jwmQ6RWkM5UpxDPeE40DBTAFAoDJJIAPORYJuldjrMOUTcwt3Q0Rh3/MUwhQfsLZdqGbXVO0s4rEnmS
# DATA aofEns5g/utP/rdc5opSXrILyjuDIbRD9KS1Z43oEe5/RHp5ingBE7vEmUtbWAOHeoZdpKewU0eqUZK4wl1PMoBFvbRGdCBmMUFC
# DATA mde2b0YOd2JMmw11oIRekYgcA+RgDR8+Hpz3mczDhWTLsg6cGLRY84bG55SL5EiEw1DhliOE66R80E8GOW8t2hSOiMR/laZDc6mT
# DATA Tgdp/94AL0OnQ++PsaEMIyRi4CVaTMAe2E7eiLYHVG5CuwbF0xFtGa6lvlHY6BAHfJIqIAHH5ylCm2zMU4Cm7esCKzaBw03HXG6r
# DATA upXpBRCLOMVzaEwvxRExL85GbsGIteFSjsE90BqvywAmQvcS2KFRpvxKuwkOsRF9iMCHbQ9wS0aIF1OALXJcoR/036JvfKSE2n9j
# DATA Nmc+ZDMXhzMnmfyNEftvQuu/A1LfJZqA3r9zdTi4APLlM0xfc0intA5vrrHSFVA8g16vfpgCL5wNRs38FJo+ucZ2r06TEZyG5tI6
# DATA ajiORyj6aZ4lo0q9PkyG6ai63hn0oAq/Arqsuo7wq7l8f3ixuNy4dzfiL9hWdR2tzAHkn9fPR8mweQgn8FUd5ta9Tq64mawPFyQb
# DATA r2Ns//oETUeB1kvrg6MjmFCzsbKSnl4nzRNs54rKdDEXCF2SOhz+zqs+3N3myvDimg9JLesPJ+Ma22/VsAbimisaovSlSjb471U3
# DATA ywENX8Jn6vqol16sA7Y47tfJ5K/ZSTFN9PqP4HZmR5d1uV/qNfCnQLQgXm2urQ0v1odMHDRhJQBmRsuNZfy7zjvQXB5eRDmwNN3I
# DATA Wr/CQiPw6I/dlYb5qteym6Okm01y+cwPNRgB70f9nMd07+7SOrBSObQzHFC+63VvGZvIwMiaNPQVU6tj3lxZwwQw1c/ZYqpwHKSp
# DATA faJQ0ZY7T7stVDofXBUmStO3G+AjJk00YWcQq3SvBsOkA9xgs3H3rpqN8IBwOI6AQMjrQA9miIGkqvuSDoX3jo+I91IdGL/s5BSu
# DATA xaX79gquNp6Y5qq3qVQKzj5/VmcZtuaaxwHwurJPLBKhcbiVB1XrJW7l4KBaOMPESTeXl5b+R+fQ3YNDV3K6sPvq/PfYHF08uY37
# DATA 1sFVh21VTcIbf816yeOX4a7A1VyXodJvPsT1IhCBa1fPT0bw0Fy6dpoDWv3gSg1u6VoviLUKy+8vQdtw2LLP0iZRToCmrok/0vf7
# DATA eJR1148BDDVWaWbONVla4tINmpKuUwYMqJn72Ip//+1W16DVI8y6APt/NXWP1OyWGyt3Vau8gDCu9Biw+JXd8P2lJV1lKWqsQZXr
# DATA k+XayUrtZLU2FBBeHw+GUP1kmaEfd4f8FZLJ3FANMy0jvjsdVlYaa9h17V7j7tl57W4DH6oA0ZfWZKSyJtX1HlBCcCRQ7IoD4K8A
# DATA EiizRq3eWFq9C1XXT5MLmcPyvc7JugzqcAD38xQmukqDXplvcMsMTmurMLQVWngc2vL7M4YGY1m5i8vp9k09r3LP0Ekkqw4trvoN
# DATA ujXpZlzjAqup3bvfObnOTo9r+dmxPjWUCW3duq9yQJLJeHDNPHGN7AwYo8tVwXRxyytLcJBryDBVsGZUj+4hTNcDYSRltzTzrPqI
# DATA i8TlgPvH52nap5O83LjrHeXlpbsarOhlC53c6wZJL3gt7/NarvFarhTXUq3ayhIciCAeAl7CnRDBBaIe8B++eCuCWunvNYlDZq6C
# DATA f0/Leo8Sxlwi1W8hCXzgkx5NTamse9fyuoHSoCsMnkAFj7KLtLv+WZ1kMDDvdbyU9WXc5XXMuAErjQtdAqI1WMB5UsuMgq6wFax5
# DATA 3QCSZqCAY51zBt7DvXOhHvyjbdYQ9k5O+3lz+WgUwf/K4BtdUGo/agDlAN3QXAnEKrLGbOnaXbgIXPooO56MUk1ImredhKShVjuN
# DATA 91dG5n7irBrvU7fCSsw+C+979Zf5jjaE4PeW5u6SOdZUOnympTIBJHcIc18me1EBfBfA3117lNRRBMDQLQVLhzt3NcdejtIhcIWV
# DATA 1Rqcc9iUylINdhbAhhnRdaOTjLpXFmaxsM49QvX+KcwnoyN04Z5BX0wnR7nfaNhE7r/eOcl63eI0qUgDxee1xukEmNIrm0CgN9AQ
# DATA frcPzwe8hudolm9TAx8E71SYfL4LQHYN/rcK/7uHpJW3T3Q+nQ0gmZ17XUoIdY1gsBEPGvKcm/3xCa9JZaVfjdRcynZipUi1XTe0
# DATA 3NQ/6wAGYFoIJHSRSKgBXkCN+BG1ItbHH9giyiotJHf/fbzb9Daykd/9JXwP88nG85xRWEyBOAq8OLeEktpcN1C2oKm9la/zXGJP
# DATA pMwpkogKtzSYfLvBDVwJ3kBqi40BrxxgxeSeDecjOXNTzoDMjPDHWoijtO7CKoOj8xNylkRo1QSmjKCoGlETpjK+1HMkTNhgs3WH
# DATA xm7cVVSzXL8VBitKFhmgtNfs2S2tY6k6KXCkFyPH7GVXc5AbHo8CkAP4pqyTXtlL4vNj6jqq68F4t8GbAuzlsUVE6aEvzYEmuG6U
# DATA ILsB/OAch8Q5G5F+WsEnpOmKF8LGKS68jpbmI9DcUUZDCzHLpxyQe//4ypMbwAVJjn3pCJO2U86m3qAVZiJH7pl5/16RqSy5moeJ
# DATA R9uqm1TArR5d4INwJgikyYiZQqzSXLb4rOU1gpR8FcxC+8KbbpKfpO4C759k3W7aP3Au0C1OD5j0x9dw3a60HOyCSHebN0L+wPS3
# DATA NuPq20v5ftnF9sRuSf/yHMXQ16gb4V0+Sk6z3mXzEZBYA8DLtZfxk+xQ2b4/HfQHL+PaKfyhdt07D2vZBTyc9XJrmVbmP48iS7ny
# DATA pFK+0Mqj11WfkcPd0hUWJmrWdV13sSONeEUYH9Piqo3uQ0TnHASgf+TfN6O0bp91Bu4ifpUCjliDOJX55JMAsY202uNES45DY5j1
# DATA evXR4Hw2lS009Tgd6l1XYHTNfEIgru//mgDoMYrwqD3/FlzTJ7VxACJ7yTAHqkR+2Ay0fQIJMY9PauMus2W0Fk0cjYNH5zqM42m0
# DATA 1nUDRpBeESRnAN5cXqwvE260ZEQW0cA0w2AyHk7G5JHgLxbzVGSlX0e1TYCaRfe0ZDwYXSm0G6Jl+UQrQKcP9PUfn6bdLKlYJNo9
# DATA AGvVq1Khgy1pWL2HsFekCu5tEZqkiJ3osLAXBbK7vEz2mSH+tJT/9C7lKnKu9lK6/KQWutwlWE280Y2IMUWslo/H7jzMQq6issHl
# DATA EOdclgLBUM6WrxwpGeNdi0pRFR/avJR9PFc88lmRscVzsbZK54LWsKao3NLxkFiGRS+E1T8wm+MwFCssphNW00UP889+7ukSEAnw
# DATA PwTI4SjpeQ9JpZnXR2l30km79dMBbQs/wu0I6cSo8Tu1O002+oAfyRHem6SfnRqRkcHz66QUyQJf1DDYO0fdRb6GNaWM8gUeTB/T
# DATA bgr5YYl8WVNnQQWiAoQ3PAT+9JXmNvxC19eOxlBZbaGFIPyJLk57fdJ9ol1ec3Hx/Py8cb7aGIyOF1eWlpYWxcALDYg+HFxgwaVo
# DATA Kbq3Bv9Pal888REbAMIzvYwYkJnnEdVbXsHfR4CCyGZqdWm1u/YBGj4+fEDhSsha6OnyvWj5g5PVlbP3P15ZO1teOoF/3/94+d5n
# DATA TuWjlaP/l713XXLkuO59X6UcssxuDboHhTumOcMYXkbiFklxcygxHKI+FFCFRmkAFFgFdE9rzAhKsq3tkONoh8+JowjH2duxI875
# DATA Tl1oj0mRith+ge5X8JOc9V8rMyurcGl0D7rnlhLJBgpVWXnPlSsz/7/6oC4PI4rFVdGMRsjoyRPZoYk8TeY5BclI7W/jG/PNWFRx
# DATA eyf4hffN5bvr1OYnc9VedL6V7+gxewCikNfCT8wGPCtLulWv0Wh69W7DqzWro3q15vmd+l692vb8Rr2YMWEr7EXVxVxt1716p/4j
# DATA v90a1Wr+Xrfp1Xx6vNo5or/vIOhmtVYMKhoMfM5jni484PR/q9FsVptRfnHPFH194aUIteMfNWr+uLpX8xt45V63y5FREfF8qRWX
# DATA fEOtVvVqDf/Ir9VHvu97zc6Pat3Oz95t1Lte3afqU+uM/Gp7r9H+Ua3VKSav0+9GQbAQZLtJudId+rXqeK9VpX+O8LFBl+uNztD3
# DATA 6XKzSf8c0cdSzHutXrUxWBbzxsqaqrYvUkW9hZOFj5Qn+Jaq4Qc8v7+lGsuBntre+lar2erVccF4n+gR/t+BMWgWr9RufSvyo2bU
# DATA PlA+tlvfanZb7XbzQCyMW9/qDfqdPp5gtzP9HLbqtfBAlvdvffzK/egwibwfvk3ThQ+DIdmelbu8fSyjrnAvi9IYz+oubaPb0T3t
# DATA Y7clmUx5l35LrEmvVnQ6d8QQMLeb0UjNb74bUZuOg4oEXVqaOyg7wmCcVdr7jaPjSlscYRyw2im3yfR+rX+LZqrFEMuOctvMUwWz
# DATA +ID2oRfHicJd04JVKSYn34Dxpx9jJ9GjCywP5GsB4gEsmUXitKpezLjx4KItb8QoegWqK43ZQmorC0k7z7hTnr2FOsZmw1VaKp8u
# DATA tvWfoql//Ap271EnEfdnvJN8whsgvb+Evph3+47ZArn/yTxKT+7zvoAk3cl2rXvNzXfTNDjZH6TJeGf5c3dHI3rUelbt5ft+dALp
# DATA Rf0MWvg+tgNSbHlu6d3wPn7llh3BcTTG6WzBjr0bTHc4UMMKZznjB9FJxRsEoxEq9673CAf+6b8SgMjk856y+xIJEKnfpqzesSJ1
# DATA AxpluweGKsx0FXrpfDTyXvN2JBb7wyDDy3bpkrpCQcmVW1YEbnk4+ilaBCy2f+B9iqPK/SHFSr3hIiHi8U/tVPOhekm2QsU+0o9n
# DATA 8rj+4UDlRSH92Yr0VyTeqCWTw3hworFVJluwxWZJWgY43L0YyeBkB5PnXVMUEQRq/3Ln41e+JZ7fj1+hoCE2FI2AaN3H3ep0Bt2I
# DATA bwelIIfJ8cowxRi9cJiT+XgnDnfz1Lw3H/eidIfD/Biif/Trvs7NwqOh2kS6I3JuCFz0LOhNH7+CrzepOceTA33MRc64vJLHfp4i
# DATA +j/84J192XH5Az4eQt+h3ua9Dg29HyOcn1S8Rwj4UxSGPBrYDUmefmsUsV7Gx68EnA3BPnb/QbMmHeGbji9aE8UYl/qjuP+A2hS2
# DATA nn4Yj6NkPtvZ2UUbR6TS6IiMijxSFA6472S/qqyQqGB9Q5cCZhN4uZ1PyQQbmncGEyQcZYMHWAhvDKGPt44o0u8orRUKI5v3xjEV
# DATA ZMWLjrjY7tBj/HEfqjH0903ZmLWjipoDouk4TYV+BHpHPDvZ2aXwJ7jhUxXVv0T0fiwHLoKj6CcUyX168K2gP9xRmz/5RSMymrNA
# DATA xOi4d6EI4Svi8+OfqDf+hfSAccZ/d/gGeqN+7sc/0aVE+Y/d8dDl3JXw5foJK1ny/fs0qozmYZSpaOQdIv1K7zOb5GZ3tbQ9Stja
# DATA +oao3edGu3MCtU7zTLHy452vUcW8L8mhDkY+47zRpwc6qjv540vKhusL3qeTs42s0p83yA5KgNxFRjVNbXeOEAuwg297S2+/5f14
# DATA f58/h5Vld5iCIgs4QzI5Hty9WomRSBeyCL1b/ozJVrMPfT4N9WbywgZ+le+vq23vy/e4H8gzEhZvac/UdnacCSWD4ija5xb+qfxb
# DATA rN5mwatYx5OHeQXnWzJdbPSTyRTz8OoilIepDE0oKEQEsmADfPzKsp18drT4d4kYf5QIcDFI8Hl9kN91TyzfllVRPnlj11FlguQa
# DATA uZb9si7at1RcPoaE55hsD6ltJgqras6K/NQRULVHfyX7bnJIk0GYPh6b8Z55L10s1TLdWlbUqwNzoGJ5zUK1yeuNqjs6f2CumhGa
# DATA v6meXG6gUZ/mVmyM8S36e7m7l6b5tmiZmuznTGZ9Yg75NclF72/+hmKNCkH913iH/iTvJMdR+gZl3o7JYmoIGYuv6VcWniYrCQnn
# DATA eo0TE3Rf9cCzGgQytVjp6IJdNVh0EeI9dN3uNIuxyWsip2XX+6u/8nZ01G7f1jFBpDggUwVMvt2+rZKC+otbZFmP3vwXHAVpbvxx
# DATA V9Jy44YUlDJ2sHKos5+/5OYOvu3KHXmwkh/oHav5iKSUiqQMcYMJRH7bVfeUhg8Ji2spxzDKeOCgktcluqQxcjtCW7QqBZJjynFt
# DATA Ay48RC9CHFU1pUzWgewWaxxuVBbHzu7tO2wzfvzKPXMoDM3kxg7Mvo9fkaZH6f+OfOc5IDf3WXIP2+p2ars3kOD//fv9j+l/kzf1
# DATA LDlJZuxq9YKZ59OM5YYEwIfNKAB6aPl7yHi6Wbw1f5fP7/qP31oP6ght8Fx/LI1bZoD5gUx3MNsdzD7vYLY7kP1CH8j2CtuN1Tno
# DATA Z/qgtvGc8c+FE4Aj6/j2/Smr5WFki0PARvTp7fx23lbM5+SerfPcz8upxvOEW2xHKcdfPM53XqWettwM9SIZomFWKjqy3mWt4MmF
# DATA YMTfigfVy4tX0qT7CTJX3nQy6etoKD/2nR8srH2xmUr2QOngv/UMf+F0cAZM73DR3qJyhx4MlRfsoXR2gk3F5vmp6AZkw4BPxOoa
# DATA 5akNFzQt5OPI8x6Nax68uh7mIBTmJxwP3qUUJ+m+94NpNOFzvgM+u08PqcP8XFk9CmuIWkd10pNtCIxhwt30ZjAWKKCJ0g3YUHnH
# DATA K/m4tY4AnyfmaJO1QEb2Ic6lGRme7+OYMyocTncz0cF7f27cvd4El1n9SN4R00/zKcyGbN+DLcU/ZmxSJQM4eajFhLDUVLMhczlh
# DATA CYDBPCUrYr6ohvBiHrY1ITjrzVlv51lvxRrm9HWcvs5FzbaVBuJV6e7cxxY2Sw4Cr4FvE8J5RoHn6Wm8rRsusbvPs+XqCpYcr3+w
# DATA /YFFEbUlR1/jwkYnJHYs+wR0Jisv4M5491XxieoGOOH1KBSShGaeM91VfoW9Yrz9Y7/Jm4i0hjUlnzdE4eI44P1GTbWZJJry7qN9
# DATA 6dlvchxLURUvhKkO+LZBRPVTJp7mgolmfb+1xWiKZ4R+1l4avvCqOFpVpPQ9JlLmoVcT7vDzyNXw5jv+rVr11ZuJsgrL9zTVPc01
# DATA 9/hVdRN9yO+6KdHKk6JsdZ2bahWMHsybwcyWPCKzgZ9gQyId03t5T7BKp1oNxeilq2Z+SXqe+IhfNKVxeiY5cFOCwPxJ5Zas09qh
# DATA 5Jf0DjVz5Y5lcAaYkFkdgC1NxUajNPs5pQrCL8agfJcGQ+qfxWjUXmur/WOMjSbc8tlQNANtnIodue/dDUOPz8QqsyDTw2duQ3rv
# DATA YA1FqXpiImBG2jlk08XRy0apGOLU4+CN2IVBb5vORyP+cY5lWBrU41Qb/z/MIlHeEREb0f2JezFlsUjMaxEpXeexYJtxFMgsgWHB
# DATA pjR6Isxr4gzTQkrSRDo/rXLF9voIwvdWL4cxsBexXiZnGnfwUiRcGi++1WwPgM5wdobzeYZzyUBylrOznNebw8+AYuWH9DZuHJlo
# DATA 5gWhag252VzSbMTgYnTeWBHxQTSjAp0cirRdUXpRmGDJAONWoiQgc6VE0UMsG8kl/yy2K0opqC2Lrw7rrD+nhZx1Y6cY18VlZkQq
# DATA YcFgnxL0FgOJLothJ4MBtn9Bpo/7gswbJsf0s0clJMMl5/W+p4wLSFpS7I4w7qKfSQbcMXCeW/KV4rPi5BQHvVnA3sy7KYarkRnp
# DATA TIrspL3DTrmgTzYOhDSPqcfKU4aRd4+nDLIhmlGnwSjj7WKwdJDEQ7LFMt2rhVR4Q+rNuJQ4mXLKh0KYsKg43IhkOh3K3EmMGO0v
# DATA S8ZkNc6UumAAq+CBp5VC1qTzzeCEe+L1CUUZiqsSZazTeF/5HwdRRMkK4wFL+9HsDoYaBA6xhxH7EKhazWQLBtON6Rc0RfzCJqD3
# DATA IWN4POYLIkC2rJgpC8cgVUWdEGPR9eYnUqlPZqjP2CS6JpEfRNmSBIpZUajCi4KqpqqTlcp+y2OowqOSjdAEedRJo2VGLIq0ou1I
# DATA EN6CMMbZOxnoxE5VYpJUez+A/ktImUh2Idt+SD7svDkZE/zEA/G4apcyQ8pQu8fyTrEn9VRaS50O4nTMiyPL5racqA8pb2Q+Dkbv
# DATA FMdIyUwyauvUgoz1nC9+Z+K/lvspP7g6kimgpudBJrYw907eu1rck3pXhj2wKa1A3MaHTI3nAZvHmBqQ4UslHcxnMbqNIGWdrrFS
# DATA nmT1U+lQwIUStzFZCLiuphQrU/v9SXIs9ROthJoI+kgItuoEv5lw+DPsq0RuS1ukBE3hSuCukcc2sUssvwIaP5UytjTEIwPXSnm6
# DATA kFJxU/aRjUQZJimkIscBaezICBYUZAvdME8RJidlNVkzn7BlZS07X2zmF9Da//TTimHozA4B501PbILO/3f2y9M/nn5z+q+nXyhG
# DATA zhenX9P/Pz/7jXf6BzBt6IfP6N/fLKJz/if98Jhueoz7GX7z9dmvT7/w6MvvDETnSwpULvNXgHZ+cfbrinf2t/QcPYPbQM/5ht70
# DATA FWN8/p5+EKbOV6ePz36lI/NnuuWPAuoBbMexdJ6D2Qw6ZRxfog6nR39mBdHswyihcNK4r02wfe+th9ORjM8j7hEj6RuyYTyl3mJk
# DATA eSN054hVxGmU+wzyuVAyGqnxiV6qZX7XQnWwnKjCUy3FoXWK8xvdg1w3WGdZyVwdXievOuZWmHT55fIDI9GbNne/I995RN8yYYfH
# DATA NTWsJ2pzKwZTB9jZsNi2j9jB2nvE1icKp5K7GNn4Re7BIZNFUcEwHdJ4wvnIcvvZDDPV0m5ljdREEOZQSjxb4OucX/1WOzSXtKyn
# DATA hdk5PxmOs+MsgauwBDRw55IGwEvi3Ly2wf9Kxv6Nhv6LjvzXM/BL9VzMh5zB8+y1rquA8Vg5wCie4quXpHcR5EGvG0/VSqIqPMqz
# DATA FC9V4JtIsiZTeVPxlAS2lw5PZsMxhyIHTDiDNkXwqCLLFyKpIx4xXmaOlVqopM+Q2zPln5VjcoPgKMGooFgzOsZ4gcBNeDilB7XF
# DATA oM7VHeT2ghCL4PuBGXEcTGa2W6yfTB1jxzF2HGPnKhk7m44qG01zNrWSr9nkv4zFvw2D39F2HG3H0XYcbcfRdhxtx9F2HG3H0XYc
# DATA bcfRdhxtx9F2HG3H0XYcbcfRdhxtx9F2HG3H0XYcbcfRdhxtx9F2HG3H0XYcbedZou3UmsFlaTvtQXPQf45oO4trzxsxdzh3Ve5h
# DATA V6bH72q1CgppzUYp1xutTpGbE0WdgQIb4XAjRa/PgdZbLAPS51BrEgxLZfiNVhHiU6cMX4JGaje8Rq3qgW7jN7sjv1P1aq0Stafl
# DATA N5ud3iIpp1H3Gn73R363MWx0jmq15thv+171R361Pmy0j+p+MQr9Wtjo9ZYkotmp5onwa12TiHoxgFq3FjYXiT2UsV6jXRuqXLTo
# DATA OeaBBXpO6xL0HK6xFj2HKn+BntNsdILL0HOaYTTwc3pOq9by26Gh5/Q7vUHYzek5rVbT71w9PUfV8T2uxmZcqAtBRw+3hZuWOarq
# DATA PI5UukfHlQ5bUoU1pmZ/eLAxaaf8NuXgtl1bYmKou3C0YDu4HTvERdyOmmh2jLGKMj7gnRzDIEyOb1U9eDeqni7JAqCH2/XiK7Tb
# DATA 3ZjmbVk/KeR66abCWpkM5yUYzsGK/QCLo5WiJC3z1Mq67ZqQVVejhjbdUPKa0TDxO9+VqvqM1RSfQmmfYyMWMs8uTJUYPXmBFeIo
# DATA O46y4yg7jrLjKDuOsuMoO46y4yg7jrLjKDuOsvNyUXbigdhvWPdAjX9kf5O6c1uNmGrgkt8qXBd3Dz61MD2PJN+QGbc5GJw6MsHc
# DATA oCeA3/n4lRuL71CV+kAPKOolizfmt6gDGnQX27kHChL0Ho5xSctnU350wqdz9FvLUdr3/lqdgbcOpfHBM5Q1VSgThT19A/3w2roR
# DATA f0tZYWxmk1RenNqfPZzlaabe8eNX3rFO3plkUHepUiAT3dI5H3cE3R1B3/gIevFAmDuL7s6iL54aXKm3+SycUS/V8UJrscVp2PPH
# DATA ArSozFmulqKEb+MwCrICuoVPREPZEuQiHmky6s7knLBWUuGtdKXTspueQecksD4jxnIW51OSoPQquFCnosfXY9lFxG/JYVC1y2pR
# DATA v17ZrqiC/EmpwSvhcP1jrmdurvB2W8h/RhyOiV6cWVm9WuXdGMQsjS6fixrv1h2m+7SfWlBoh0WJw53o0OQ+FnddJeiuulQO67vq
# DATA 8+q75Xg9q9zxp9V3cp+rZGb70er7pN/m9POnNaLyctBUy7mLHWqruWOIWaPlXqgJ8J/bsq75L/DWc1en5wHySed5Oc9KYpvs1je9
# DATA gFjVXPPSOefGf/72v5t0lCNu5f+UJUrR54yCaa6/qpYSeU9aOodEAmy0hKUYJlCCZy1qqJXGVAsZyhRMp1QnWV+XOma0PprETmZy
# DATA /B96rDPoH2kdWtaq5sUPLTJ7TJVbHRZXPi+7ZeYnn3XTyA9WG8cZLqukmJzRRy/pAvuCuabQvRYIoKzaeqEiyivqRQvo7/7X6gLS
# DATA lV6K520UA1XkTBfQh8cJtdGUOjZPn/LLlAlCfdJ8Ak8kDUnTfe9tGuVh5IyTIxGkoDSw4ACEDQ4j7lZRQLJ/WJVTpNUtVGk9eamY
# DATA FFxbuZhu4aLF8o//c3WxqC5GSkXkQPtJSpMR03ImaiIsl3ma02NNV9ZVlk/eNEDDCsV0EAXfAfXhybEqoqIdydLsbBYXxkHrcjyD
# DATA Ef3kpWSn6NoKKu+XL9zD/WZ1Sek+XorqoyAde7y7K+/ijnFN4DjhEbSwqWQOqWB4/QJ9XSTD/SQUKY2I1WOhMx1NAMGRElCzgV7E
# DATA 5I54Jpoc2B1r/8zUiScvnzwZ11Y6TzIC/d9/2HwEegODbJTKkGDpgI/ZrqZ4pQ+Upc1NKhixenngjec0/oyCFPvkppBPRkZ7PxLj
# DATA UQ0wZCKBYSDNBiX+5CVRiO7z0FT+adOmcj8ZzLweqn2A0sm7NYzxPcqiMbRsoBnTp5EHkwNWhA7CnwbYn6NqfIbCStkej8fxCOcN
# DATA kFNQqSBL/ZN5LGo1UEFkYRUpQK0IvYWmUkjGpQqoaASKR9M2As0Vye477yXa96g1hXj2oXyCSSpURgzQCXfiumCV8M+TsINeDnEX
# DATA B+d2rrRLuNKc5+wl8ZxdlNf9TKg7FvZfrsd2y5ybBtIZtmqSRXnITq2V5O5nVAXyORJNO08b2t73eBUU78VWsnWW91IZ0VVE78WU
# DATA q9uMOrY4XzAJ2vd8I4nNzqSK+I5EDfI4MY6L3MmkqH3KITwGlNvI/OUFXfHmmeBLIQtIwWBnhCQhK2thL6k1Sp+b62Sup3kpLfD3
# DATA 4OmaHAIaKIBx0e0xUuCWsqAG3yjNrFtGThRmdS4qaiuJeuwzIYt1JqWFeQ+sbw8bcaG3eVSoD7KZTTKLt6tCE3WSN3jRLtS5hRze
# DATA f5mMRzsIZz4683Fj89Gua24d1q3DPqHVuNJIvZp12HeF+2krRefEw6dDqrgOSjjv/UH14mODhWVO9VOO11a3LqwX5gtJ+fLYqrVF
# DATA e3nDXq1ZdX/J0V5aSlj1VMH9W/Bpr3qi7KYsu1lXPVf2npW9gitXTgulwJusEFNUpzAOuT7IQtNrr2r5SlUs6l7wy2XPqbDE1TlT
# DATA TTovL4LjkLnm79kWlae599Sp2zaVuMz0qzegiPOmgvFJoQE9vwhxLDTNmIQ6RU+fKUs1GdlviaZ6PJEZJ5vgkZ5JGYgktR+zWjVn
# DATA U4FCo2fw3Ju6I0HfYg/PnhII4QmAMdnVUx/BEpe+R9YdQ3Et875yigmEu7FAo564mSwWXD5vXO40zutavrcQHE/dR1FJl0r4fAb4
# DATA i2MlW3BAlkJKxgU24H9XEL9vTr+mf/90+hgYvscevjGW7xuw/r4+/QJQvkU64P86/TMT/36v7n58+qXHoMDfnX519n+c/vH087Nf
# DATA 0LNfqUC/VAjBL89+iWv02zdnn3n0BURCAQGCTIg4yHMAFjI38M8OBvg8WP2FvnsQHZPtwJPoaQDpWgUBQK8+HkA+ogfJLo0BoY4P
# DATA q7J3FVY36THzQHXPPd1p6T57PuXXoAlxeGRk9MV/Es3m07UIwLuQuvDCeYbNLtSeHQCwYO/rXuK6+X+LxXJ19D+2sJiwkt9aqG9l
# DATA nvnN6CSaxhFZG/r+t9QFDypDQGgn6ZYxgKwexkjo+YzHf3VGi5qYIwFuWoTbRwFSX4NFcGrzk3iATodh8Axxxna5NHkIDZ2Izy6L
# DATA KQ+DFbWQOrf+DFsY5iz9Lz9mavOJ3nuiK5q4VMkSZ8YNpnHx4WQBC7h5tVxt6yw0vKcFB9w8MQ4S6CyE7VkIGg14KcPg5XACXptR
# DATA cAU2wUYmwYUtgus1CKSKlrPDmAHPTKu6CiSglWq1/LUiihouxu6LByfeYRqE80BB/7J89QEyhsU1NkYNFhclTmTTJ5bmj9j1hLU2
# DATA lkXMplEfI78xxTaCA5pxnZW5KcGZ7KOjDBwAX8YVcC8Z7KFycj9LdWjfg4otjs8GYjnAR8cEPBUHxVZD8qcpXcp4LVWVtjLfZJGQ
# DATA I8s3muzb996LAJCTC7Jp7/4cZkiazA+H3nxCxTSTM+z84sxhBB1G0GEErxAjuPEwtNEk6aIG9bXOES4zRdjmDMFRBR1V0FEFHVXQ
# DATA UQUdVdBRBR1V0FEFHVXQUQUdVdBRBR1V0FEFHVXQUQUdVdBRBR1V0FEFHVXQUQUdVdBRBR1V0FEFHVXwmaEKRu0oHPiXpAr6nVrU
# DATA CJ4jqmB5BXojpmARntdtWPC8dtXA89rFfA37USMcLKHvtWo2fa+R0/da3ZV5mxfM2K92vJrf9ny/4XXaXre55zdrnt/wqbzoaq3t
# DATA dTolLF+71e30OsuwfIUo8z7MxfjSCy3kod828W0WAZPVqNVvL3m+Vqvlz9erOTKxs9nzdXmlyq9mLc+vzZ5vNK3416383vD9zY6F
# DATA fGzU2xd9v9+yy9vP41/fMP52fZGy5ccbmz3eatvJt2GPG2a/PKKS3+pe9P3F3Ktu8PqLQCKlkWhIpPRlFiSy3w7Ctl+ERJpHDCSy
# DATA Vq33mt0CJLLWa7RbzRwS2a+G1XBgIJGNfqvTaeSQyIEftjqDK4dETtCf72UPTvJ1DjlCeRRtYd2hZrk6tM3F9oN5rbYIC6aPvIxm
# DATA M5jWL9nDojLcDmYf2kVF+94Kxb5TWzmbESsLEdWLHoqLKCWo71FZ8mjTXNtvWVRDz84WdZund7UU80bPWrFPvuBoLQEd1+xQUPsR
# DATA JB17Gf0wjm5B9HI1pdHkQ6WU3DWmX7mQK2vLi50ppsjEHlyoJmI+1TbJKQ7BUSAdBdJRIB0F0lEgHQXSUSAdBdJRIB0F0lEgHQXy
# DATA JaNALkIcx8HhbZh61KvjjBkl+aZ81SdZkAkKufiurSiAVnWDnqa6cA8bInf83Rsfv/Ifv91n4uHdpToD/MyOhB9M5bAB3kjB7Jpw
# DATA agjnf38u4byBFs/Hl8bBZD4IWKdfTnXJeURqzlM5+oZDVYEgF6KHdCMf/iRzIKOhrUBILJzRcafv3en7c07fLznC5c7iu7P4T3IW
# DATA f6Ue55We0RdFxIQPIufHvWVYec3ocz59+Zjr0OqU0Q4yqiYKAz4gq6zOnfF4V1ESdQudsAMkF/TTQZhuzVwwipbtZlFJchxPZN2r
# DATA qlQneRVI6U1ivw3/upqnaAZlu6pcNN5WICbq9jUT+1pzWeRrVtQ7hYhX95uro27Gezvq+qKqRzthdJhGNFU/JwVWWCYF9jWTgtbS
# DATA 7K/bue/X1mT+SoVO3UpQo6WDeF7VOa0Rl3mIdGcqrVkfcS+YfZg3zZY3GXpVjCPrvZO8kds3sMi+yOdLcUfZTLoSeVLwjKZK5GHw
# DATA zb0TQTkW+iWtO8D6FTo06kfICFQGIuZ7UzEbwhhzP34MGsIsqXEcnMjAI8XJY3+mhTUO5wGNOLMoYmlwJWzxCXVwZH7haL0SBVkS
# DATA ow0EPF+8A+ulUdFZ1s6yPseyLhlNzqp2VnXBql7NVnqWlK+KrSAw+WXEr34I/p5RO8Iqdq51xHoycIlXjH6ToIujcZxNWYLG+9DQ
# DATA Vdh4Z92cCJ6544jJrBVP79nAqBRNsYyf0iOoP2WLukhwXBC7MvfR0H8vVtJHwySNf5YYyRul4B94WTAAXydKyShiCSZTKtk0yRXS
# DATA WaKIRaPULCIKshMeeYfJOIIoD88myO6rCCdDpHhwL43WNLDGMCG4s8oot7CKoNTAsVVhxZShYNuEkY77OxDmKXaA2DqhVHvAg8w7
# DATA RGMTzScBGzZUr/a91+NJgjpEz2jMrjYEJtHDGRuSvKSCDFL9aJLBbaV6WGUCSRUY88ssUOgyY2Jp2r5vgxFGyaFO4Qc40SzlJtWq
# DATA MGeLsSAL9Y84Fysy3AWR8BqdKLV87vGzB1LT8nFDb4oU+deM9V8HkGrnRGhFUoaeMi7M47NgwG0je2fZukS9L3Je0iqiEyWZhZF6
# DATA OuYuTNIoqmAiP9vLy4MdgLlxGsyMYFg+HlFeUIWlNMqEU+kpUZZhl+sI+0u4KuMITWpX6JMMvnGOzUMKYEbGYRyCBrvvvZlwk8Tw
# DATA Z5TJIAKnDMYBOr/Uis0CAYktq3N1X01ceoEq7LmloG/WUwyT1FyRQeJELmiRfTU5Kz7PPxanXnpxqjCtqvIUSPVneV/GxAKpuTnU
# DATA XsnsP9H7fEOeGAUnCh1eNFUy6gm3+84aD6GM6wnjsfQ/230DtineeU+PHUjTNJr049F238J7uN/SLUgvodk96Hbf1xSAxSAye4ao
# DATA 4bEtOaHWVnzXzfnoyhi0L978ypFo3dRqc8lgN5F64SdSF0XPPlsSwmZP71UwTMuZvXWC6RKl4/P5paMCQUE0gNkNWdQVXoPXfbZ0
# DATA lJ9HCdENcQteYWO5NsJzuVXJFzPZ2F+YHOfT3op3CIXmfE6DWZgXYAKMrVZmHtqnKbCtHyuqrZg0ZbPSrDT3JpQ8Cdr+FgHdQq0l
# DATA 6+UoOl9IGnVyHEw1yGGjMlhSou+nEXvUC2rYWZRlmlX4EpluOeGqFzyI0gLe6l9OvwB16uyz068Vg+qPjLn6/Oy/Ma7q372zvwNm
# DATA 6vR3i3CrfwatioFU4Fh9dvaP3unvz359+ufTL85+RYE+rnin/0a3/Im+/wLfvdNvTGigZq0GXv0CXCv6r2NaPQ8kW6rDeB7OBqpg
# DATA LIEdMO5ZhgiytmIeCUK4JiBXrjonzMnEpTFhpwX3SwMF5gnlUoI+TvbXCiOPeo6MPV1rEVavYwMt2kmEzsIBrGwDVDqB66ZXlUvk
# DATA 6thVkIQOS+9diqziKmZufJMr3NXAqmjUm6pNv6il2CSchMEJ7yOk+vEgcsCq88pt65yq19EMuASmUYqzoqxYj+N4AwZsy+lLj2x3
# DATA aJmoVRBrC55e74dY/mEahXEEbzQYBdSnRim8XflyiuoX4wmZQ3PJYW88z6Q/EzPsRKje/XgaLVCsNqmpq+2ZUtN7WvSqTRLhuFXO
# DATA Cri0FaAxVZcY/F8Kz9M1DfxbH/c3GvY3HfWva9CXylhMvRnkn1ZjuQr6VDGJ3jAaTWGdkOEBBLOJXJ7gdHgyG46xIitJvyVDLYTe
# DATA ccJlxh+Alka2yOoodZigGb1NBn5wRONkprMjFWkz3nqANdl0zlqKFP9xbLhA69lTancEPEwRlqgjPtMlAzHHfsVgLi4OyyBgPBGP
# DATA BZmYEHto/2HBvOB9gHoThUIB8UtYQAGoKfoHeypg5+k18vksgTxUn0ldDjDlAFMOMHV1gKnzxpGN5jKbm7rXaLVfxmjfjs3uSFKO
# DATA JOVIUo4k5UhSjiTlSFKOJOVIUo4k5UhSjiTlSFKOJOVIUo4k5UhSjiTlSFKOJOVIUo4k5UhSjiTlSFKOJOVIUo4k9cyQpFr1RqvW
# DATA viRJajAYNMP+c0SSKq48b8SRsjOl1vLq7c4ne409v9Px/GZjr1at0V/f8+mfRtejr8Uc6kedXr25yIPqtr0aqE91z692xnt+jf5p
# DATA qK8lEBRlcrXfWwaC8rsSMKU/poFbo4/qFnqp3mxZRa84SAIlKoKrokYQNaOFiDbavlfrULKbnl+vjeudPb/RVN8W4hn1eoOl8awv
# DATA 1q9q02s0m8NW1X/Xb9S8RscfNrVenMXAajZq0bIgF2tsq0Exrfs/6jbGVa/W3KN//M64Rq+hYung816tQ18Wfyi9tNNp1Wv9NS+9
# DATA COpIWohGHUljs1BHvWrbr4VF1NGA/2ejjuhrMKgWUEcDPxz0/Bx11O5RVgUGdRQG/Wa3maOOOo1m1W9eOeqId5jsselhs4RUZIuz
# DATA Tx8joSf/pWZuTwZsppHMDNZBfnjkyt+8AX2o4IRrGSecLL0tAoqssBcd8jzCyrY5eih6sCmcSFsatXIA3gXG6zWPrR+8V0KIrBK0
# DATA fYGemNCr01Mq3DZKta2Ktpg/q5PjSEKOJORIQo4k5EhCjiTkSEKOJORIQo4k5EhCjiT00pOEBoojxEevKMGV49uD78il4Ukoq4eA
# DATA /ZBxU8nMT1nAFiVfPTFXTyLqkdVlTR+6h3CZIDS4QTl0yHygjyiGcvG4CCJSv9+n4PnnbOnPb08gigRjgd7H950sve/DZBaM5Hwf
# DATA 3/VuMBvus99gZ3Dj+EZ240TdbHOG8pMs7qi0OypdPCptnWtyB6bdgenVUn7PwEFqnEkd5NU8OPEC/F6QN5+x8onUZ5SAkQhHvang
# DATA Z8jmjUbJ8fqzvuP4IR8/nqZJMtDnj6Ezbhoqjb/YijJPo+wJtM1pRExPkJQZZQnSp49b3vWy+RSdahSqFh1nhnxElo0CG6U04KF2
# DATA Qk5vFM+wiJPQ5CFjJWwBmfTT+bh3AG2YeMLnsTNzqHoAZ+8Rn9/9CC7cgoJJypruoqCd9ZOEn+jPp5DZlnPN6xS034ANkZ7IPjqP
# DATA h6g8aQOIrEMFEEFyqU6iKMx0dybpzWapmMtUjsNkFPJZV8ScEktzYJYDR6kM8NshRXl0wkLhJttM2YmyDsuk41S6VkXnNGAiN0pm
# DATA SDpd6iXHIy8YZQkfDF4rEX6Pqjc3HTm2TW+NUqvwWLC5x9YmZ5e+Oc70Kfpj1EV0zyzuM8L5XvTj+x4rquc9eR8bUiLIo8cjPpmL
# DATA s/HZvvcGqzVz3fU0oAbVgSKPUJHaIMRGIA7LHENUqv7B7DxRd845jvMxDSRGVxDbUXH+3cNRGryMmk4w5tfRQMeloyTh+/OZFC62
# DATA 1UzVaWDRiTfnvXFlFCsKF6rFzyBTz3CczCiaP5DwxL/CIZJpOLKzJDbnuYN0fDld89dFiBpZR43/wsLmaITbVjb/AJmPwhvAOS29
# DATA 0xUImudsSxE8QlGwIerlegRXoGlulBnZqJmotoduFmPeFUic3+Vu39hKSk3i+pTAX5yD3HkgbkbhZhTFGUW5SrlphZtWbDx9WDn9
# DATA uLppxX1kRY7DkejoKcUzrw14HYhScaTRZfZ8eTuH52Ex9QOmwzIXcjpH9TJA0upqrGfu2qNbvqe/eDvfPi+y9oMmwoWLOcWzsyzO
# DATA jaYV5e6mBFX2NzKhZDTbIJbq9hzxqr4XTKqFqNmZWS8SUtdETZye9HPBK7lBJPWDJpbmQm7X7rfPi2htXURXglBl/orRymppzy8N
# DATA VZpanBXFjoxm6T3qW6h1eIdmLl7xWp1ve6beemMyqTOv3lD3HMM/TbN8mkhHhyk6Sn5KI7Mw/RZuFt/I3RF/VTpsMjM1kNOY1Wrj
# DATA vunq8MbooayZ6CkDlsEwqUdYJSkzluey+jItYJsJq0yellUITPrzaYnETp0+iLQK2gaU0xfH9nb0HWd7r/fmO0P7hTS0L0rZecpC
# DATA qLwDON8gu2iA2hAaFh0MtAfb6IVKElZTaJ6qfOpzISvI/90y06gk9LptotGCVO5SntEG4rXWPupcwhbfIghXJsGgYgg6bGXNs6Ey
# DATA sEr1FDvFpWTVbvFXh/U799IY6zbYpcheRLoERn38EDYMe//lPBfTDuOiuUMTSMwCo2XLLkpVU4RMRZ9UHWTgLVzK5CkaMDQttTyq
# DATA xmox0bXjfR9rVog52XelmIvsrllUodjx+oVpE6IxqpdlFIMUx8mwPdtaLWL5VF56wlnENRFGs98wtnysbZIw/Zfjex8rQWqBTk+f
# DATA o6I4alBc2OMlk5FZ9aM4KvgkViCwCLY6ovSyZfn60mh3WuQgMtz64PBY7KB/Ov3i9KvTb85+fvoY0J/TP579mqE+oAf9nBk+n9Fv
# DATA oAv9ZhEetPDw6ddnvwZu6Oenfz777PTz09/Tj79iBtGXFY8+fXH65R498RhBe3zPN3QPvUPQQithQhQ63vI5vYFudEChZ9+i/iH0
# DATA y3idmHsTRQs7qciCIC5JR6t2p6bRIfjLWs5ZFv5VfTWDe8qizQXKNPXGaxlCbwwDUTWwJMMdR8iyrlWXcN0koWXlcnU0Id4QMEym
# DATA 5saP1IXlTKFBnHfT9+KZ8QRvmSYkUGO2F8RXZBF9XnaO0CYltnWa0F1PwOsAge/N5r3IlLx48GPsoR17shN833s3oRowMSBEKsQj
# DATA 6L1D0gNrBKzhAbMsUJtdAnweyaaPFO7DMfMYxVnHxpfAGiESW4YHra+Sq42YJe3saaGD1ifBQYPcSH+RkV5zgi45wL8crrPrGtyv
# DATA ZGzfaGi/2Mh+9QO7VMvFHMg3ul5fa7kKUFCeMohoUQDZYpxn8Lhhs6be/KfjOzdp50NOjBPRBQgCTMy/M98ES2BMW1FbQvkt42BC
# DATA qctMuiW1JnjBDI2n1IVNZhthg2BfzXCQH/lAIQ1S6u3yQT+W5X69sIVgWEyOIUaGAJRGklUGiXwiQOWKNdInwPwkA0EX40VUEb37
# DATA MyQ7Zo9HPPCoVT0QGsoxdRTYM4g2yBsMUuSddog6epCjBzl60BXSgzYbUzaEmp9v816z8X4Z2/1JTXfHDnLsIMcOcuwgxw5y7CDH
# DATA DnLsIMcOcuwgxw5y7CDHDnLsIMcOcuwgxw5y7CDHDnLsIMcOcuwgxw5y7CDHDnLsIMcOcuygZ4YdFFUH1UHtkuwgv1PvN6vPETto
# DATA cd15I37QoUky7yIssmbCZhQOqqtYM3de7ccp7H8B+9QkIQrs02aRBpY38H1FGCrc3qo2zrnd4vxQ2B7d49Fve36X/lbp327ze3R9
# DATA 5HerdK3l1fwGXWvttbt7tUZt2Oi+WwOwqN0Zthtjv97cazSHrWUxadRWRVwBjG4eFipQo+YjMvSG8Z7vVY8E0bMmG6NBr9tajkiq
# DATA LlRPinOzVh22GtV3kepGt3nUqI4b1cZeo0qfygiibtDutZYFXbs4DUjqvKYBSfOxaECUjH67XqQB+e16p9G1aUC1aqPTDAs0oFqn
# DATA WW8FOQ2oNwgbYWhoQM16u9eJchrQYNAfdPpXTQNSRslyx4dOa8nWUiMRNq7trbdCPLoZw05+bxn8YyZKyyZF2o2GuW6lsd9g/k+N
# DATA +T+L61GtYqS0cWN102K7cEIox4N07xBTY/AsqmF0WLHW3u3PXq07fVj5Vr3abLd67PbbrawOqXvBoHSUs2nUvyiVSNu88B4umFTW
# DATA itzqxXG1FC4+4b2MfhhHt8IgfbCaPZTncMWO+mqbo2T2Sh1i28mRhBxJyJGEHEnIkYQcSciRhBxJyJGEHEnIkYQcSeilJQkp0s+H
# DATA 1rGu/Dx38RxXGcMj3CA55U15pOlC2BGAZgQ6T3+8zzCfN5IxC6AvHPLm421YShK1qgAHVZKJOr6mBWmLB8WkjcpETp+0cGec3Rnn
# DATA wlEbd9TZHXW+5FHnleKDV3ME+l7MWhd8lpZdkOXTs/oo9LMmt3EdetxqcEHVofqqJMORyp3++DyJZvOs6bDyK0akubNUm7tpizT7
# DATA frUo09xcI3XNgx8kXVTvxRdeFVvWqCjLPbnAtX7o1YQ7U1tCusXLPR9Q36fwQlxPXr2ZKJHAJU+0OLtobPFuerM0esBakec+1uQX
# DATA 2WbAGAYNyycXn70pqdlAqPotXT9RZT1U2edXpfrdKMjmEI3Gwdp+kOYC1fdnIslHPUmSzOQGOdYMWZ/gEGLP8Ecd05i17/2QB7dR
# DATA dESVBh0gOtWxCpubsYLTJKkRHkoTMif3vQ94AUBMI3mA9RaVsB8NJycoaCqIeFaQrwZMq3BsX86ReukcZ7xx5DrAAXtoOJrxHPqB
# DATA ZLFRneXCz2h2Ns+mkegfsmJ2MJkPMBCnmEtJgOAihfFggCvzHuupxxinKTDG7iyz9ZQIASVhtrHA9YtyztfJWzvz1TJfnb36Utir
# DATA F9W2fsqSPbyunS/Arte2vkujERuNbECyHZvlUhTMUcjWaFxft9jPc6F3cRWy1ov1euvS1ks1nS4rb50v+mtzTCwKZftEIItynctF
# DATA rdn8OSGTRoCavBREr9v3XhfdIJoliVhNFExgonwEESGRe8kwuDFmVAiOXN1gRpHVFWvhZ7LhErJ5yKh7QG/QxJCLVZwfaCEWo+pk
# DATA 3OEvl+JJIWecMeSMoVKf6rx5zptX7DtXWlFPWdCQecAAFyejkejsl4Hdqp0EWS7ht+/dE043W0nL5PkKWn7TNOlHIWjcIkWXpJ/M
# DATA I/HlPAmf+25soM6GxjujEVQzAcfxTFDTMpJ6rOXCMZhzIz8M5oc0an5Aw7CmBVY4ADFLZLlH4R3QYQSDAZxi7CrJXZ5mnH57gvF+
# DATA JvzauaJFRONeFEIELYx6KY3IQkXmIZRFALFDaS3KWkb/XJ5RcMABVQX4QVlTUJkGmbYuoBwHf00qzlIlPk02QDiKekG6770D+wnR
# DATA pEpKmRsoEFgYoIMBEqE3EuG1IQvjLRMy5I+ZpVooLtkM1OtPqODjAXTexhHW/uL+Whj5kFWtufJMZvDgsBfZJPkjQDmSwcA7pCFL
# DATA J1H2SXqjOWVqP4BiI9dj4NWD4+BEHFM6nqoMM+3W4ezjcYCCUTGnfMlEgRv+JVbhPlCyhpDCTPlkgaq4pjoXwBoz1B/mjXg9ikC0
# DATA 0uusUs0jjYwtkAlnPnguVA3BKdOyyIxJKPExyCQs/xSP6OeK9kNxAnLYTj9I0xNWbrxLeRaw304FJIR5gcdpjs9RwJJ8eSa9F8Wc
# DATA KvETK/VLuOQOkyS03O3y1oQaGo2GA2lrxSK8HOwbbfmEVR+pj3ntwrBvxG3bsG+xy2Np4Eq/MJ4AHB+FVwD9fh3MeyUXqraOXAHj
# DATA +6OSCumVvInh3u+gaUgfQ+OabMvJhJiz3bfxKaCPDCURK0TTIE69B/AWB4upu0qi+Isx1bHgMkmQhofwrdt4mf+hMDLfMNQFdJgv
# DATA vNPHp384++zs14s8mX+h+/54+jtBvvBdTH4BFeab0z/Rx8+ZJfO44hm+zOPTr04/B67mMX7a00899ujr5zoouo1e+IuzXyq4DMXj
# DATA 7O88Zsz8DmwaUGgcVOY5wDRONLNrwRc3jRIgoNXIPROB6Tf0fE38Hoe8bRuDnIKGsXYvywvn5C4z8FH09FA4n4RrKTN3+Zb8zY4x
# DATA U5jNmZ7huikzi+VydYwZTqC567sQEqe8Hg3K94XQfjZAL+z3naXByTbRMtQGMrKxUxEwp5kGrDGeiaEgHFxmfVFtnSpjOqEwJjOe
# DATA T+yJqUPmK56CyH380ON64X3A2wPEbXuI/ZHLNpUL+xAa7VrpG2U2iWasaY69HzSGZwsMmXU1b7WdstCGnhY/Zl30HT3GDelPNKRr
# DATA nMylRvKXwyd7faP4FQziG43hGw7hVz2CS10sJzvfNvkUW8xVIGXKCc3JMkZzIo855WYUKMQM3G8sNwBP14SKNJPVWiTD8DNkWAV6
# DATA 4ihOGReDwtJYGUp5kOEijowbojBWQ2VgvQBE5gTWFvt2JcRD2WaGaQJ97I3E43aYRnweQLJdb3VTvnUa/SGFwN/P5ZEcYPznLEkt
# DATA m6GIGYlSB4txsBgHi7lCWMw5Y8ZmSPhzLdtrNc8vxal+IuPc8WEcH8bxYRwfxvFhHB/G8WEcH8bxYRwfxvFhHB/G8WEcH8bxYRwf
# DATA xvFhHB/G8WEcH8bxYRwfxvFhHB/G8WEcH8bxYRwf5pnhw7TajV6jekk+zGAwqIWD54gPU15z3ogOY2dLver5zfaw3q4f1bqN79H3
# DATA Yo702u12I1zMzmbN8ztVytD2Ua3R+h59Lz5HdbPTU1wWLkspKym4E+Gw1Aq6Eo1usYwbjVJEelG3XQ6wVqtfNsCw2q21WwsBdmrb
# DATA jWG94W83hg2pOtuLoV0oVJZbyEOrUC4Y4IpStgplKzG0C2UrMbQLZSsxtAulLoFvr6VcMMDzW8pWYmgXylZiaBfKVmJYKJRmY7st
# DATA 5YIBnt9SthLDQqFsI4aFQtlGDJs1qy13i6Xs10shqgupyv3y4N+K6iUUV6vbCBpLYWnLoGPNZt2Cjkn4qUGCWUaKDnWBn1ZrPlkA
# DATA zU7XCqDZvXgAhSR0W0+YhM0CuAjPTGw0zTMTc8/imQWNVqMeFXlmA/6fzTOjr91oUOCZRZ0w6IU5z6zda7WaLcMzC1t9P+jkPLNO
# DATA vxHUrpxnprweakODmQmJM55sSXZQWN4LvUht5mcdXqlcsuhfDLnMMftuREZsHFQkJqW9KEuCsx2RvMhTDF2t+54fDTN9Wb5LTt9O
# DATA k+PDaLOlouYmi9NWqOVVZ9tnoutI0e1ck4n8wuqhX7cWidW9fq3ohdHVlfdYDoMwOeaFGKy4VT1d56y87bLDgmfFZja3Yj+dnsSq
# DATA 3K6uZqDZeXqOR8PKrVKd5MlyzYHQHAjNgdAcCM2B0BwIzYHQHAjNgdAcCM2B0BwI7eUGoT1StTumgrutUGb4TImucJLURRzdQ0bI
# DATA 7aK6eZs6NqozO6ha8e3qQfwqP3EQ37ix+wgX+baDeLBzHE/IuiI77GQ6S16DEf8BoBjjH3E4u490C5reZtAag0B2GrVuo9tq17qt
# DATA mxyl3e/wHxWF3m3YgD+k2Xu9Jh2vv3sQJo/kHeVX7PR2Dz5l2cyd3o+rP7lzm961eyCSb7jwbQ76hn/waUTGutKCs+Ii/DcOcEfF
# DATA Y5fuVuqj0zmNeqrb+1Sih8pxW/380ySe7HBvRTkIPhwaww31oyzQ7uwElR4VR3CjVyHrMbfkVWpH8e2V1uwoRsGMYrtC3pbmQeVG
# DATA b5K00cwRr2UbX2YEOECOdj/FVoJJuDOKdw8kj4q/86o0TdxVV3zHr+4Wb8AQrOLzBu7dl9PTVNk+1cg6c/TTKas4ZZVFZRVzGNip
# DATA qzh1lQuqq6wUxb4C1ZUPIMelFUBGCet9sGaXEV55ukJe10GnY1OAroonyEsGnJhzsHTqobxHUt8LarILRDrfAtK1bBydvwZGx+YL
# DATA qj4+YP6BoijB6NQ9OYxOP7TAiGtJUA/FRFrNkuMx6S1418+70xc1YLJAz7uRFXY/PI5G1Imec2+tqu6dkAlcundzdB1Xb7RyLtHn
# DATA llr3fc1okPEoI+shCo3UnpHXISPLyOKI+V6W2mGS3GayPSxi42XJPAXLdyA4Fehvi9UIDYecTydeCzISJ0rGh5J44qlD90Ysht65
# DATA oBYzrN+x9X8oTXUqmJEuFLbI7Ny0NuqqEhhtRJt7ERRD8rHEGZ3O6Fw0OnPrwlmdzurMzrUnn5rW331GDXEk2cUN5CiqvzE6DZBs
# DATA HPfTxJLAm7OFqvTvAmpdkz7oFovad2ZQzFuUGgw1pISl5PrJeByl/ViPgWy5phFWWrBxYWPtP07Z9M598Vb1TuAzi7DLBMOoASgJ
# DATA +5cGU+ylWKK/pc67LZqoyj2LmsiflHGqbA79Y24AmSt88BnotIjDUfGT5QYRHNSRX2p7Gp8vOEHqc9HytO4wHaX91IJhB6cp2gJY
# DATA U3JfvM4O1Mb5m2zArbqrn4C4Qc3liG9+I/+6+hmuRLj7fXxYY13KwKwtPHGh2iYJBok15l2hhLHnQxq0OtqZIx2oUzLsDvZYy+qO
# DATA yks7L0o4IN4NY9q5OIO5NqVzvr32n5/9ny2TinK0Vc4qU0xJVVIFSWcnYoyRfccjE5g82pLkQYimfXuwu0KeL3p3wxDSePS0sID6
# DATA aGxU+3miyPxksFfwIJt/MjoyEUUTk2Gb0lv2vdeDSU4FnIQyKZWf7oEIg5fUqzTIGkqQPnZyqXwt1Z5LZG9jdfYW6qLkMuxlseEp
# DATA IbNgpPP5LvNkaJCYViTX9MSacy3AJoBZPI5sKNt0NOfZM80v52LRMwFJefS9u/EYeTUgay0bAlbFpjcu+TV8nSYZm+j73luAL+I1
# DATA YZz15xkKiEOSRclt5LJpbxfN39V5q1quzlX0+NT1zvBB5+mb2NsTePX/+G0drKSQ8gSLBxPwzI+BD6K6Nae8o7KQKX7m+VSgXTgt
# DATA ZP2lH9EcZN97n7psmnrflYot1RcEKOYk8XlFD+6NA+91+w6cIRR3Cc+k1Savfe979DXiikzlv7WKfOksXt9DFLL5IxpoaZJBQaQ6
# DATA j405O6CGvyd6TjkLDNqBVL9QmaaSh7Lik0lfIHejksJPEyj0OCaE8uB70C7FycCMdUsDE0gw0VCqiryMfsMSisSNM/0wFslT8MiO
# DATA 4oRaiHo4kJ7n2eg8WhfqPP7rPOaVTz1460KQDKb6S2McKjZXQLaBtGEk0yFku5eN4inlJzcO7lsAOuPpTY/1TbVHEAqqGNVFiZW7
# DATA Ju8wmknRcRZiITFLxhEuHM4j7jjwdDyRiQr1S7OtdB9XP/i9weMSmEixqdqmWxS3xuw4kQ5Zsha9cSYITRFKjuKURrdjhKLrMcvY
# DATA xkbhl6braPqpavlkC7KqM95JXRNOK1JvfaQmdxQ2nhgnWMjluQN6CsZOSPcCm7WcuUVzRZaNbXPFXJHMukMNTC3waiFhGb/FVLTM
# DATA V2puQ254Uij757GeXgSXSz7bci4X53JZQlBwXpYX38uy0oHyTBEVCkcFFkfKkc1a8EbxDEecWQmFkZigWKrRhF0w+YN8noQz9mkj
# DATA GJ5lrfLz+EnWwQ9ZleSjL3depY603N700ffC8bqOnOWzzuXLhWAk3WEZJ7FwJF3abz9B7ZC3nUz6OipK5TH3u9li9lweS8Ac1nP8
# DATA hdOjVmKGtTv32SY3VQQQ5GByYlatvpccA4d8ourOax5fmMM7RVbVa94bdH9EnSmMIRghuSX8GiZh8Zgr3CQ7ltnDDBvtPF46Zv39
# DATA WBFdNZsKMNqAbDPwcaFdRoZXL3kYLfCiirXlXszATHZAUnbM+zNKpBT7y7DkZHMuE+Zx25TLf2Ys5b8COXn2Gw9EytPfn355+vki
# DATA 4bJ0559z4CXur3hnP6drj+m/35x+6Z396uwXp1/gCdz7GLd/JQhMuv2b09+f/QPglR59+Ixu+5Pc6jiWz4HJ5mXs90/VAUTT1yPR
# DATA PDnnnmDfk93yXjaXCatsyGdurTzIDRhjBg8m7BGYyDRqgAkrNzj4ybC0MOTN82solq+LDJigMhzCsmjCSaO/boBlqUiujl4JO+DI
# DATA 6u5VxWMKuvxUfkJVQfPEB6pKogpO4BHbKtCSd0sMg4z9NUD/KEe5smAc1HLTEtw63vIu7NJDsVUMO7rC3WYIB5sGBJk+SwztN+PB
# DATA IO5jQz62LcuOm0gzwPWtk4jCoJ9TcfcvEC03qoOrzZJi63paXMuNEuEAl26sf4KxXuMtLz7EvyQemmsa3rc9um80uF94bL+2oV2q
# DATA ZSEbcszlU2s3VwG5LKQRU/KgmDBsK5UEINjxdCZD4TRF1wNO3TDoxbzwN8t0qdETh4dYYHlA1SCTeTzVY7XMjem2jMxmBB7FVCGx
# DATA /CWEvwyKf+mmiEtko2ECYtpA8R9RV48zbFgDUWhHHXve9rqAlVQ1aa9gLMiCEMeSJVIQCvIQGYCVz2xvGqV7bNVRCczH3MseWGYC
# DATA bkSU98hgW2k2OAamY2A6BuaVMDA3HmA2mslcwB6+PtP+Mpb9lgx7B8d0cEwHx3RwTAfHdHBMB8d0cEwHx3RwTAfHdHBMB8d0cEwH
# DATA x3RwTAfHdHBMB8d0cEwHx3RwTAfHdHBMB8d0cEwHx3RwzGcGjllr1SNmbl0SjtmNus8RHLOw8rwRGdNCvfnNnLJYL1LF2qUMr8vv
# DATA kuNFZFmj06q2l2Q4sJut2rDRGO81Gp7fGQrqzAKPlWlkOXisvgB9q1pxLSHVFuJaba2Ka6/X6jSDhbjWahTXTmtbce1acW131sZV
# DATA weyWxrXR6/CvxbjW/apXo/q7nbjWO1upA+1+pxX4C3FtVLdZBxrtrdSBsB2ErcX62uhusw40W1upA+1Wp9fuLcS12XnyOmAFR6E1
# DATA Wu1hq1498lvf65TwuNSh9puXg9hRX6ohdtItWxC7Rou6jc4GELtw0CxC7BpRI6zmELtmu9VsNw3Ert/pR71+DrGrd5uddu3KIXbY
# DATA Q7Unqxt6dG1Y/DqLVtdhmzO//2JcurLTtZ4vtbbE6coh8zmVzXyprXW+VD0nzANdXJVRvmY9zcBEQU25us0FOhx8alhwkv/U+XfD
# DATA hYsnVKe8jpDhpDI0inQ6VWuWUfYuR4yTFQO1iLu0CIxrr+wvWAmbs0pgjW26WGMcX87x5RxfzvHlHF/O8eUcX87x5RxfzvHlHF/O
# DATA 8eUcX87w5Vi9UaHk2OdJif6OfOXDe/T1pv5VQHNsbH78ylvq+F9oTkLisB6TzJjJ1o/i0Q6HzmQ10c/M9j+m/03uznCbBKt+UAA2
# DATA 9Y3hMDrckCbcHp/gWRL4zXIoHIz1aMYjgsGdOR1Ed9B+9UF7d8D+BT5gf1H1w2fm4H3u2Fqvhsgib3yadUIjFFkWEFge0vd1WohP
# DATA 95z+c3Zi9Tz1ndxReRXaiCUVgi0LI5Z1HM5RRbyrAD0shkC5Sm0o48CMtND7c3hjeAeDdzgHFKwXMRsssFS/oXtAk3WM0949uppA
# DATA 5F6rH4pMFCMalLoC1dtECzjLiXKu6kq8AdnPZ8pxDr0nFQJPo85FD6cyrVAq02XVw7VKSqUmB++1Db9g1e37CY10Q3VaXTa/avHt
# DATA 9wLILRqZ/jQ6DlIcqFeCosfBSI7mB6qCeiMkhDkJ7ECPg1SEKSTyxfPQs4BFUn8wnyFJ5hB0WaN8MY46lw21YSIlwRQb7iCwCcPD
# DATA lzAKjJR6kLFKgxLWChhPw6fV49ma6L0N6s0FIodexETMEtLQFQkCmBkVfpAqgEEyyhSP0dB0OJj0gXeMXojji9P2ayL5vrxmSSa+
# DATA RCfW7VCcjexs5LKNXKpVTpbKyVJdxjpeaY1fmVzVd2NuA2wkBEroSSvYUI49sLSrrlkT8TrgwOLcYQgOrMc0Qs5BpXI9Hlg/Znon
# DATA cyEn3Daq5yGC61UxZDegBIvXCche42DiS+wSwsvPibB+3kTYXMgj3FweYYmjirJfjnJ1dZzZNWZXXVStHX7xTfFM7Z6bzUUKs/6e
# DATA x7m2NM7Ny0ZZO8zohneX+9zOiXEegIm0dcnK66XRtmKtqo+OdLMQ55VA5Nfn8Si0RjT0Fs8vF/ldGYZldA+mfPSGF7D1XMqAk7n3
# DATA 4lMiSh1Kkj+khyLwuO56g+iYXdrsOJ4Zjyp0sJYIyR+mLFRnxv9JdKSZV0YC7IeqX9ddIYBrAbDo2D/LBvm+99dkKYQ876Ge0epm
# DATA yewPsTNIVNc0I1Nc2dKRcmOhFMmb2fTAlI6mGcKBi2erpmwvsBFuj67OCHdG+IKjesHacna4s8PXmdXPjmysGux0M2AfGNqCrQIP
# DATA 3A6NVaYVHuVDnZIoreQqpjzUGIFT6HVibxVGHQQ+FclODK/KiYg2NxAgSjaPBTMjh0FWaa5emp6cv5QbNiTwe6gUehZBo3Po+Mmb
# DATA 8JMn7EPFE+JNXX2nuJNlCoFPa8jJ2q1oOf9AsX32Ccp5blwQI/nhaoSkzleBSN4teO7h0qYqAyhtGqGYSsDUNDqkHDP+WfbDChKL
# DATA /jPA3Fmpz1KNzPhGum0yi2nCLCsQPFfe994I0vQEoqzJpOgeTwNmNrLVOktPlJeYRVmxBzKViMFnnky0n1xNHuxGmq/+6CaSry6Z
# DATA PZAyyq9JvslfraJIF3izLzfMAIxTMxN5IlZoXpUvWMxvrS5m3ShUMRunf74kI3stuMfQBf0OulgYOYEwWVOy2PUqR2Yh60ULQJSi
# DATA eelFAs9GyfHoRCShU1Y2RueKscgs9VCZ8wY+dJBD0ys+URGuT9q1FWKhl7lgOX6wBmac91e6xQp6REkkpxFYrDTkTEIlBs4lqUlg
# DATA eTsN44BmgWM2UAfR7ITG0znyOFbOq0C3ZIUbM5N5XnSh0TXno2VmCYcG34eYkbLPjT1gWCCMBbj2xG1zXUKvrVwv3Qff37gPpgo7
# DATA o1uErht5E2ZvZw9OFvpfzbaRYoVVI0LTbGQMo3GcTVn72nuHe8yAvQSjID2ErDSUGSeZ5tQfJ6n0r9JWpHMdBEAkwy2wlXa5PFXP
# DATA frf6vY27VTV2kX0FeX0kNVADVRhogrVpkrLuje4y0cai2KHwtvDpOIjjoCgV3zo+nMDVIxNRbWHCscLS4DA602nKevXU60oxczy2
# DATA 0fY2SNhz0bW+eaGuVcu6wzAJ0+AYDYR3J4zigbVQrZxr+g5lPUQBtoVS5kD2Xuwd257BjIYLS5s8/fls32OXn1nLVtsD+mkwRZ7z
# DATA kVC9n0J7yJ6sXNem8FIler0A7yfy0L74PsUcgdmPaLSP+1kRgfnF2Wenn5/+6fTx2a/o88/BswS28k/05+fgWJ59pi8uw2J+c/oV
# DATA /f+L0y/P/p5xl2d/y1DMPwkSk4P+PV35FfMzv2Rypnf2y7O/A0Dz7JdMx6SwT786+0cK4pf09zf0TgoBN/2cfvgj/Uz3/IFe8vj0
# DATA 67NfO0zmc+EoxbY0dFeqW1Q1j4PObokvioewHk0PKvz9EJvd4UXtA1mnQC1HAXuuAjNFMD7XwIMXrj/c9956OB3BfKHOFIWFWCuD
# DATA JlcHXsvPfGNE45e0RMTPETRtH6ruM66boLlQKFfH0ORKae7C1kJeU1cewAXiJlXtODG33+evHkS75iOIhG0ToBlnEhV4D2VnY4Qz
# DATA vwH4QSfRzNEzNym7KyBn8iopr5bHY0x1EZqpAKp7mkV8RK2PeszH+r13oyCbq+VbyrE5oFBMV0DJUV9pfM8Zc4a8WTyKlMs6ZX85
# DATA GUjhfLSI09ysSq62dMpt7WkRNTdLh0NqOrvgKuwCzdq8jDnwUiynXpspsH1LYCND4EJ2wPWZAVIvS7lg4zaftTZ1FRzOUvI50XBT
# DATA M7vQRKYM39QKxXnmHMGJMVI8TvsgDecWLz0b5b8cwKffhswQX47GV2YPolkffu9NcZz5iG9ZDBS5LB/+x2InhNiXB9UoKNRQfD0J
# DATA kU/WFOwBXvimuCXhnvLjo51nGe8j83gPl9gi2qlIoxKSK/4oRevkjRLstgrMMppDbzr0pkNvXgl6c6OxZqMp0EWM5uucAlxmBrCt
# DATA CYBDbzr0pkNvOvSmQ2869KZDbzr0pkNvOvSmQ2869KZDbzr0pkNvOvSmQ2869KZDbzr0pkNvOvSmQ2869KZDbzr0pkNvOvTmM4Pe
# DATA rDcbYat2WfRma9AedJ4j9GZp8Xkj+CaFHtOw6PVFZqzLedk/EbphN8/YWkN0qPiXWqvIL+yGg6izmMtgAtbqQ7/W/GSv4zV9r+Z7
# DATA frXLf+rNvU7DI/t4r1vfa+61u3t+reXVunvtmue36Uu9WBitTqfZjeQdxTjXGrU8zvS+PM6tWh5lIYtaFaNZb0WLKMt21/Ob7WGn
# DATA M9rzqxS99iddimyrvlejH1qdPd/v7LX3ms09v9Et1RY/6kd+iXnYawWDoLaMedhYlpSGxL6vYty2IIwNKynFOh52+v3eEiKj3/Hq
# DATA tc4nndZeg1JS73pVSlPH82vVT/aoLOoNSqHvldCKQdRutJbGrdlp53GjgK1s7lo1o1qkRfqNfqN1CVIjNz1NapRWbJEaKS797iak
# DATA xsIVkBprUScKLVJj0ArbYU5qbIe1MLBIjX6z36lfOakRe9v31pk0NOBaPi6xjc1D2pKxoYRI5cAvzYgbnW97+JdMDY/NjTwIPd5a
# DATA S4zyK5uTG3r9a1b8ls4lOEQICts+/yru5jmINk0PLAO84ApV5X4xsKK4v3IoZClPmpQn9G9d/i2sVjWaBhvZbn57KeFRjEVKs8z5
# DATA 8uVSawFrOcJxJarx3Mqg7cnltUAypWYX38bhlIqGZ7GlyZDjQDoOpONAOg6k40A6DqTjQDoOpONAOg6k40A6DqTjQA4CNO7b/p7w
# DATA FGXTMeCPZM1o5ON9fd79OFL+TMY97ihcJC7gCQkKVfUeNvrt+Ixk7I+F/VgIRM1VrVDkyvnBiIgsxJPVcXo5au9N46gf6dOIOCMH
# DATA /2EP5VHkQOYnb9zpcHc6fOPT4eUjWu6guDsovl53+5k5QH4/fihNqELj0+QES/6xHLK0wTfmyKMlmoomM5JDnXj2weKpZxwF5Z5X
# DATA nZ0eIBQ5mZkFo+iC8tlG1VJcj9zE6eZkDNeofc7bKWdvopzNO0q4KuLD6vvQX+K2H9HfNZrZNCjOBH/4vnx8HvSyTR5cUCTy9dUi
# DATA kSo3RSDydZziHOBYNwalXA8Sm2U8stypquA8OE7ng8tKU54TCHiO4oGcYE5mTIHIeGiCCwrBeIOI6tEIBhFNWBI5eMwp0USUJ9HO
# DATA vGyWvLFhlrylNUFpTNYZ8nowgq4Aa/VydKkx8QVz5lqWcFhW1BvAu0xPI6d4gYTndWDO0dCMP9QEyfqL5WQ+AptsI2N0O7hgvvxo
# DATA db5Ii1I1ZR6yZZLXkUmQ0pzUm9Cc1kM/w2BQSLdiQQIyAzn8BxYNV6loIoQyCBJkzBGhz1P090cn2rh5inXkv2xYR95P5qxh8dP5
# DATA YZ4fWm16qtWnk/EAm0aAaaBOYIrpFRoE04wUxigkU4MGsz5l3GiYzHHibd/7EBMC1lZgpQSx6w5Hwc+MUMcTqs/mXeEF8+f9Ndqz
# DATA ulOVHKL5tTfVlySH3k+TI9QBSjPNbg4jg47lTXJUaYJ5HyocdyfefILk6h4GAsEMRAWWaQTlfUhF8+LyU2w3H2zYbrhSK+UWC1nL
# DATA igzjZA718TmUKkZiPKR8Rhb+flCxwlD3LFBajqUrZbPMFuINpLpQf13Oj+uVsn1ZFBpyM9tNwt0kfONJuJtxv+Az7pWT6Wdaso33
# DATA sZgdLUJl5V0td16lBl0uYb3/Esk12+o6spXS2hwqF4IRfyvLny3si5QK00+wc0hedjLp65iok8Z3frCwrVJP8hfV5azH+AunpjC+
# DATA jwpkL8AnmPXCimMhVU+awGv/Qv4QH53m4eYZ1a17nuScNhS29cyWKqm+BcPBbKBaY6j952//SZsR/MphTaTsxIL0ZtFoxFMXBZoQ
# DATA Ra/vwv7MvEOxsoIZ0yJCqLDRjGU4H/d0cQVeOjyZDcfKmmWDlecGh7H8LJYfi5Fh2gxRM0vzy+M9jxDpUtLIFcqtNMoF54waoF6B
# DATA FsxQjq44DtIFTd1igTLUyBiOTKx6CWW1rGCc1easto2ttoX65tZO3NrJJSy2lcbhVYrvMqBpoHT0Wcwdec0L8QUN3qcvCL/OEMA5
# DATA P89ea1lYOhFbkW3LsHCtsKYhS/10+R71v3z2m694O/3xeaB7/ajpzswFs8IgB0TKyHi/CLq3kfHVfX/1+ovaUGBHVi5tElvzsIlu
# DATA fsXEt7vN6KqNF/T7u1r/d5bMClVi59vnRdsEYqKdXzknm6tWvOtro63MV7NgJrtSeZVLqnzEWzxMU8gsRBRq2J1X5UywirPanmw7
# DATA 1fJL0v/Egqqa0titjNibEsQTwp/EtmKUVt4F2KrUP8zM/hI0PmPcvivOVKPUzMjh42E8ivJ+IoZa7Qx7dVKWvDUrHdSao1y8meWB
# DATA 1QonTFzZuCJb38jULVUBvdPKCxWqz/QGWjsYXarV91Cq5mO6H9uD83BYT7ofTKAdPKUExDinGKRTXuhlzzFQ5HBXHg8jMeDzjgsp
# DATA g9A092u8sEVGx76nYHZIoRGazuZT6nqUfnBRXPom5/vLYj1bEC6eo/McwuZw/ZYZXF+c/UJ4VyBnfXP6B4XmApwLLK7PFwlc/0K3
# DATA PQagS9Bap/9mhUOfGLD1Fd2jIVtfn/369N8Npev0c7rxMb/r92f/wIQunHTwTn93+sXpv1GlCUYOuPVc2P9s3FtbN4AKTBPgXcfo
# DATA J7i+GTuGSa0Z5MmpS2L1PuoZJ6L6fcy64bJ0oWW3K4obeojGPgx66Kdkti5q2FxnIHbeizBDWAfb+ojuMhFyqK2C6Z/3DNdN2yqV
# DATA ytWxtoT2bfhPvCXbeqt1508zKm59Y7GCbROxFQjYSsMV1AKhJMbhtc4prq2jtd4PyOjEzxTrZrVSrVZ51KAMoC5q33ufBhBj9TDB
# DATA giddw2CKtWC9838W9A4QScFRZwZCgeKKHtJAgLMFZYbWudVttZlSbDxPC551bgIcN8sN79se3jUz6+Kj+svhzLvGEX3bA/pG4/nG
# DATA w/m1jOZSGwtJt310z1IbugpGViHhjPjJFLPdTiZNuoNMLZqFWDTrwTIPsJO4QgmNgfShRhNTEkYxWFKTUL92EMQj+Cv7AVhFzBYq
# DATA JgujbWAyekwDnF5gjifZFEmCi5RayKa0rDxk1gzI5H0Uf6Y08Vb0IdU5uFfoIp8p59Pm7N+YYIWP57BzJkRNA3HAJiEjs8QsyMxZ
# DATA cUrR/RMy3h7CUxaHgTrJHolhGGXYhxhnQ6xjBvBq9IW7gnTFA2xA7A+jceDxznemcE15LHIoLYfSciitK0RpnTsGbTTV2dB8vr5Z
# DATA wGUmAVuYAzh0lkNnOXSWQ2c5dJZDZzl0lkNnOXSWQ2c5dJZDZzl0lkNnOXSWQ2c5dJZDZzl0lkNnOXSWQ2c5dJZDZzl0lkNnOXSW
# DATA Q2c9M+isWqNRbV4andUYtAft5widVVh13gicxRnLcelyxgmaqeoX5ChafqeY4fVud3WOV+vdxiLIqVtjJJUKyoJLtaudbre3DC5V
# DATA l0D6ccoSVOplLYstVed48oG5TpEmFXbr7day55vNjZ7v9rqt3rLnO41Nnu9EvXbglzNhXGvUvVqttUcVu9nl6l0b1/3mnl/zPb62
# DATA J9f2fL++5zfae+2253d8O2jeMFrCc3XCTthdloOMCyvV/HbXa9R9qvB4tVcddqul4EzeLQTXvQQCi5uQRmBJa7QQWPVWq9euXQaB
# DATA VY26UWAhsGoUUDtHYNXCatjIEVi1Tstvda8egUUzoT36faNJe61GY2XRb1UYaWTE0yF6fEDOcJ+0DaeMT51gHUCqXSvLAvHmo0cl
# DATA l4k1BizcHZTMfmOKd5Qpnj+gR+3yPHDZnE97CTvsJZTVQfgJlyy2tYqJKC4EyBzRsyc+ypDLnzDD4JIVuzKGa6nHR1fUoodhFbTL
# DATA OI9VdOA3tqZf/P2cfCq+qIXksF+xsPVk9fNmnD7nNSumcKuxXqaCb4TjWld5V0/rS5V5WZ2cj86dXHIUHOfLcb4c58txvhzny3G+
# DATA HOfLcb4c58txvhzny3G+XjLOF+qCOiEfhQc29WuGJVPOCKTuttT1ZJ72I1QQrlUH8YCNTNUw7zSrMHhmQ8AK3krTBHF8U1leaF5k
# DATA 8lAfnR5Kn2xee7tkTFtzAjZhK5hcVIT+hW2NXA67whwzgdB36io+foXtGjHPvXv50X+yo0+yJX3B7sGnbKM/ymODrZaDeELZoahm
# DATA LCOqdB+OrODfQOdDzRUu1QrOMY4DOUPFpY639rBHmeaX/CIrfkpQl7oanIR6LzH2qXeMM4vK+qTfOIJUrTn3cWpnT/9Iv7y2zu7g
# DATA MqTyydN1O0/Z7qNCZESMysRBizSqN+E0IOIhVv/Bp8aY//gVE/g+4kZvNRduUF8FChtdo9aeH4O8KTfq3OCzR+X0quSayra2vXA6
# DATA lxXeZsHQZA6vp4DYXpY82xEbuj9LRzTl+5u/ka/YDEhfd//qr+Q7PUp5+vErbzHi4ZXdRyssb2V0U1eYze6zxb4jheok7p2awqXU
# DATA FJyKwoutonBRdfunqq5gHLCSIhHrs5TcZwGq2533tAw3p5QPss4hbRmvTsib+ux+rjwgscRD6x68z+2Wt3lhUWjlU4XsEGPBanv5
# DATA UzcRU61DyEdjVwrcGxKTkkKgVr1e3P6ZE5t4Dg5X83+3TE4oimJsm5tQ1hpZSk24qErWR2msTLd4wqxGst1gzBiVLKMDwsplGSzg
# DATA YwiZjeei4XDCfuqKEdCXyqgqD1cUjJKZKNpbmh7QOAjYok8GM4YrpRG70ZnApYBbbOh7vDDIeuOT6CH7eJWyxrkcoxfjnLwJwRl3
# DATA zrjbyLgrKeU4zSynmXUBq26l6XhVWlpvi2ATVWw1l1dOBK7mOdnnuhUbr0PkXnkWdObqpL+qd2JoxXF9G1TTxVOGy+wsKwisU0aO
# DATA RuzRZgAC1op5dPsruJgO0KfJp1vqgrKo5VtF/rBbXN32Y79Sq9R/QoOijtEKSXnlVKN3vc2fuMoWEcTmFtO35g8tEIBrjGw4Tjze
# DATA SrIGPNwQwxvcw9KdC6DglWLyxoeVV53nV0ceUx6Rl1I20jKJs7kROJtKq6koCbP/EhwF96WLVWpmIKxoNyiaicoH1ns7nhS10EQ1
# DATA KwCkxXbJKX0sGjAheiaIpNGJcoSa5g6FKxHgoqePcbqLh07WnLLcf/ueKS6MiGQjz/uzuaIwjeIxLvJGIwhWQSSOaRfQ7sp0VEoV
# DATA IZ+K2GZyPrWQ0iq6TjG31Cv8xnWo5nym5pwvO/9iWKj5MONMVGeibmSi2raIM1CdgbrW8HzaYq/vFRrJBAPdLB7nUKb7skzKAqgV
# DATA iwIoqfPe0jKIEFjE8R3OLvodTSVMeKyGLierhQaHFC9sOZucGD3IDRVcObomNkKColoAQUcxCKixUruPWN8SnccSb506cbzEUpU9
# DATA Cqhg/EnRgZQlo3/MjStzhaUngJyPOBwVO9lzY7ql1awis/GBoT/yuWhXWneYLtF+asFkxM4BjI7oGOW+eJ2FiRapfcmr77J0bAXj
# DATA aL6uCTnK4kNO+5v8aY3tWmSDy04C22BRNPNVZmOhjLG7WhrrJQDsOjcuCGB/9OlqArtkrBDYMYmLNCNdOe1PNIn9Q2wZpZSn80y2
# DATA e3ENnLB2qhLSxRwIZE69Ah1jE0aADRReb06GrlJMjfv73psxC6zOWWjXG8cZzx5lrwu2KzFFlDeByDVurbwyLCQGIIjodanisz0x
# DATA 2r5Ugy6Ywf/591+tzuFCbZSMZknXNBLhX/hV4348M8h7/iWnL7H2LRnVoqWaTPWp+xnVtpR1fHF4dRaLfX53wIfCaW4w7sWHc3Af
# DATA leu3ors7QUUJ/TEgY58lfOOQf5MJ+zZy9JJ1dZxtVlffC8ZSFSBlnWed1BZMcaBgK/t8RdUWOtWjaAYkluxuMk97jPFA78WgjxOg
# DATA ZYXWNYEyIBoEWX8UHeo9qSjUBgXTQJ5+9fuvF6p8wjrj2FMqPplH80jn3zuYwWHSRhPoXIn5OIjZmcMX1HHzCADoN6VB8pqEVJws
# DATA r6gcMLJ+gKMFnJ+UgRO4kDigmTwFTG8EiiINlSi0rVQ907VfMCPfXlP31CAheVheofRmaXBE4+YxpUFn5gfqKMFQCWQHUi1TsmGi
# DATA MFNGAfVykxmD4xAW7BKZn1BDnpieQfWqY+o1Mp5LxpB4tJZVc7jcLFZy7hHNf7UKN2y/p5qvH26arx8ygc9arsL5xrx1q+WwNDrE
# DATA fnA5IEIJydSQgdEmV683kucZ+ypyyzAaDDiH7X4g6GUsXk0zNHbvyD2qOqM3FasvRmf7U9nNWsrQopEgexZtI8Fckewhu1bvLtQT
# DATA O3a2qF1/1BH1hwn0swL4S6kkdUG8FAtvNkaPSiKyCXr/fPrN2d+efnH676dfn/0G3LuznwOJR//95vR3Z78WNN7vTz8/++z0Mf6e
# DATA fn36+Ow3i0Q9Oxxm5f2caXx49puzX+Gp0y/pIvP2BL1Hf//k0S1fnP09Pffns18Ap4cY9NLoeM+g9748+yX9/Q1+ZuLenxxa73nw
# DATA 1khNs3nzMuV8EKOVTmRbMIgNPzS+GVG+hzlGFkMIpR+2FGR9A78/0NtJ0qgfT5XNlc3RH3FrHycs1r+WpPeGxMtqQA6mZ3tpkDvX
# DATA zdFbLJOrQ+lJ1clXEj+QqiSSJ+Wb0RNZa47R8ZXQsnlH9VQduqCskAkj3jaOJnPH09ugzLaO1BOznvty7nrgZRa/WY8MCN27iT3P
# DATA 3diHebdE1TU5VlAfTThnnTVB//KhAxRaPB7jjA5gQlTYBkZ8ofq3BgNcblRPC7F3fiIcY8+N8084zmuk3qWG95dkAeZahvYrGNk3
# DATA GtgvMq5fz7AuVbKcAxZa72k2nasg6ZWTqhdFxKUasNxkaUTM7CER8V8YEysCxZLFWVljFSWLo2iWTPmZKOMD7QmZS7NhEmabYPI+
# DATA QB7KMlY5RpS98BDwxl1K/jjGBpOErDLs2ZKBPq8u9M4gm6cAgwUsMEqZzP78inbbpxHaD6fohEtGdHCEBAjHCpPqdGXIgpHgvvpw
# DATA VmuemaPhORqeo+FdIQ1vk9Fjo7nKpsbutdrtlzHbt2G1Oyqeo+I5Kp6j4jkqnqPiOSqeo+I5Kp6j4jkqnqPiOSqeo+I5Kp6j4jkq
# DATA nqPiOSqeo+I5Kp6j4jkqnqPiOSqeo+I5Kp6j4j0zVLxmq9arty9LxRsMulH4HFHxyivPG4HxCtS3eteixtWrdUN989vtIjdu0O90
# DATA Vd5QBGMaWU0Q9TyIRqOal01NaHtyeKrWLYTXbtT69f5CQdWavler1Ya1dvXIbzQ+2Wt5XX/Prze9bo3+VPc6+LLXrS0puUU0X7NG
# DATA oTWrw0brk3bba/t7DaoHfuMc6pwJbAETV2svzYCORe6jyFuVs97MM6BeeO+3Gv1aq15diHK9VfX8pv/JHqW1QbVlr+2Pmw2K+yd7
# DATA ta6+cukE+LVLgO64VWjQnTQwC3TXbtTrjcYGoLtw0CqC7oKw22/koLt2q9ltNQ3oLmz3qz0LdNf2636jfQ2gOzSpvfX2hsfDi3Vr
# DATA mQ/33Yh6gTioSMClxbwFVFydF8zy5bJi0MpuWXBS6RxacESW/P12WMs88BcaVD32vVXZcFLPqCWwpUk3btXFSBqzvIiQU2ELum75
# DATA VoEy0W4Rs7Y0Z8zAp1e/qutocBvUgqsyRRzazaHdHNrNod0c2s2h3RzazaHdHNrNod0c2s2h3V4ytJsNc5Nk84Gt2wJSC3HK7ZXd
# DATA 78g3XnJkLJdCniWzYCT3o0XdeDeYDfd5JrnDF3dvUA7gOCq9RznRptCYmU/59p3CO27KN/ox415kltzDdrwd3w7lIzlMZgVSfmcp
# DATA GH524ciZJojJFNAc6XCHqN0h6mWHqEvHfNxxanec+qLHqdcI317VMWtpBWwHQ69dVlnNMeunKORxHdSFUB3PVjUDX72dw10laaub
# DATA 3YQdGLkAvHoq75vU95xZUGQxjGMWoGsqbAP7/mXRCVsseC1q318tfCvjKaSYzbCGYsChasn/c6KrnzfxNRdMhP3Wsgh3rAjXNo8v
# DATA D6qgtHE8OJp05ZxIqody3V71vcCBWIihb8WwY0ewGL2VvIc3VIuKjGjQ84t7eIOtPB7GGOCFyYk+kPz2ACqb6EP4GH7GAx3aXkZm
# DATA ybTCPk1qpSN4/UcnHpQ0Ucli8PLEKBJvvdC5pNbxuXFqhirEkIKgAGHmDHWA/QRGjwpJHwdn/gTX5CibYd2dp1QswTRmi9gSAcBp
# DATA cFZg5GXUECfJPFm7ObDFAGCyoffLknGkO6J3aPZyhBnSkAEY3L772B2sEoRo533N+YCGF+dgsYPEOkt2vSXr7NYX3G69KBT2qcsD
# DATA 8YK5tRC8aPSNCpKATP3JWHRb8Q96fIwUpshahupTVxV6ThQ4rgKbuqCAtG1y6hI1qeXw1M2UEEv1D1lt0xRYRPr1FGlVwzqrtucK
# DATA 0rynR0+E5pnAqTQ/lW2xCPOs8KQg6RJ42CgxHyv7DBWMPmSRMpQQmNSkooGi0Mn3+AZjlJQluDnOH7DYq0Q5oizWMX7bTNRingNS
# DATA VEXPaBanFVZm59hoVfaChaYV7218ABukCIqsABzBWBPt97Ewtz7W9wFdUbHmbUpRqCP+lpa4Cml2i9hQEjj3Kjzlq3gn2Cwrqk7o
# DATA MWbJYQQVq33PMqoTVhYdewwqUNSXVdHVL1yM8UskYGP3Sc7SdJbmMkuzME45j6nzmJ5noD59YUqJQaaUFdMkGbNKHTeIXJ5yNJKm
# DATA slQkcV/V84o4KyoyGEF3Ds0I69NMBWPPiierd6pd8TLixShg99hKUOqO0ibVciOHiZ5vythNuICDETYwiEC2g4JtAgUTi8s2rVbd
# DATA afzcTHfRX1bfr1U6OVfV59V3axnPovnx7GPE8vy7IMfFv+W3VqNcdGEIyuUHk4g6kym7FvdwZFFbhljf8Jveob2SUWtU6YJyI34U
# DATA KQIZTUGwVW50UiG7HXt/e1QvBvg6w3iJkLGHJMOah5zqyLiHgLF1HGRD0VLVFjpdGo2ybXBwriX/PjxOOP9CGqemxdyrV4u51+hY
# DATA uXefF2qQbO5rVSZBsRRA5xnLUYo0ptwlfuFRBHwRNut66hCuCJVuIbcKbfDiGdZcnWFWg5Y8+y71qRS7eylPZacygcnzrVaqdfV2
# DATA 08q3GUwpXiZjwymezGcYciBaOipOrHjEYFgP1TyaXSkKnpmEHWFH4+gZyLvWBfLuDVSBVGQl8vXBQvaVql29Vi1lX4Wn0myiHkpR
# DATA ZDRPFaVUEPukNWI/epgGx9jKq5cGWG82Xxp4kjyz+/ALZtm7q/MrHw0Uwi95EGjrWmfSPeZUCDcC6D6hFx6RzWHMdLJwH1DDGym0
# DATA U8iqw+MkZJKfN8Q6sPeBCAUz0wpXzPKJWZXJaKCnXGdNXrTobWSbPZhduKbVVmdcPjBKxhnHQNFA03l4H1eV12Xi+R2qYaHOq8Cr
# DATA t3jPEFVUbAtkFwJNl5QjRmw3xshzXUu8w3ms+F7MjVXeGzYbecv5s4rwelEcEjnGaxDPIDFrc7z+39PHZ784/fr0CzC2Hnunfzz9
# DATA /enj0389/YLRW18sArv+B/30u9NvwNg6+2+4xRMk1+mfT7+in748+/nZrysIh8KksL6m3/7dO/sVftqjOx7T77/gNz0+/Zre/MXZ
# DATA Z4wHA7JLEcB+QV//nQKknxyz63lwqeRQP3SZY5sHJH1IFsMHSk1S4wLTeX/G6vfSoVCGRTOBLx5h+hePxQUp7RYu1AFOn4MDAIUS
# DATA fgocRt6Iyts9+0ojPwlGazFeb2FlPAxOTEwdx8v2tagO4rpBXktK5epIXqoW5ktG91W1HMUUz/SkfL/URn3z24VKuk2YF1yGKiai
# DATA hS878yMdLwf02qzots70uh/loIOcBZECkqq7LEPl4JLzMvQ22AskMsIMVTCniOH5OcHXfe97cahnx9S7yfRanFMqpQtkr/Mr42p7
# DATA ZrGVPS201/mpcGgvZw5s3xzQtK/LWQEvxWrLdVkAV2EAbDT+X3D4v57RXyrmQi5Y0K9nrFFdBQdsIfmAmmJtKGPO+/qUVbgGQvWK
# DATA k1BO59sztTWCt0CwSEgcpOZNOihOuSw4oTiV62AjMtiH7OuFPwgbcDK43qI0GFWUJUcDWhzOUXxRyMUIYy2lGsJryGGOeeIIa1PA
# DATA 7BiBeUCBissDzilq43DNxJM9ymIGsXtkXcziSaQdVbx8htCxDA2zpSI2C71Y7BADgnKUMEcJc5Swq6OEbTjkbDQH2tR0vt5pwGVm
# DATA AduYBDhSmCOFOVKYI4U5UpgjhTlSmCOFOVKYI4U5UpgjhTlSmCOFOVKYI4U5UpgjhTlSmCOFOVKYI4U5UpgjhTlSmCOFOVKYI4U9
# DATA M6SwRq8e8s+XIoW1B81B7zkihS0sPW+ECrPzxW96db8zbLa6JdpUi3rHTrSMNlXvSA5xGUkZNFiRUkhZvl9Q6imXXc23C69VyH/z
# DATA zkLoza5/haF3W3ngjW4hcElVHrhfb9kQsELg3UGn1xuUA281u1sPvQB6awiLTSBlfisHvTU7hQCiZhB06gvNgh73fL9z1GiOah3P
# DATA b59DIFtdJ9qXAJBxY9MAMmm3BQBZM+i2NgCQFa4AQNYM+4NqDiBr9ZtRp2oAZP1BvxZGFoCs2eh3u1cOINMNdC18at9vagpZ4X4z
# DATA OuoFguYmtLFiEJo3lvfjOqcWHJnWoz0syix5ZtNlgf2WskBqtuOhtr9kTdhng6jw5oJHQSwDPMfzF+NN8ptkJ8CkWuKRrBmPpGRK
# DATA eZllyUJfc+EFtQM916Le28/tklL0O2zPLeOidbvdIg0Nq8yrKWWFcquUymKNtVO8seR7MO5DhyFzGDKHIXMYMochcxgyhyFzGDKH
# DATA IXMYMochcxiylwxDhrpAoYSjqBLxMlF4u1phpzt/mpLZHWW3f/yTChyqR9FttmAr6Gjfx0+3USUPTIXm02WwjtKd3UfxYEce2n2k
# DATA g6YWChMkmPSj/QlZqLt76lUHdvAHrOqsD27sSPR2D9AVfPzKh/kxtlBwYp9acxzsI9Tvl1LEsY8170X66SlKKit50MQ43VG9FfSJ
# DATA Jf2UgEl44/ZU7d7PvgPD7oDSh8Bfpd92H/HTt6cHfCaD4kQ//gVfo3gsTU0hwSbrD0yGH0itw4SeG31ewyjP7yl9Z8p7hYTTJ3+M
# DATA 8rP3IQ5JFc9fphR9JnhQfsSJZJ/Y8gefrn4dk976UTza2aGk7iHNuzfZtAXkTWUJxYSSbOoFNSRO/T67cXcf5RXGuixxt++jjLO5
# DATA eHkNUrFErkoOqbFg91GeYSg6FGdM2Ri/qsh5LOmGdMY3buib96dzMk0eqZjfkjtxyo7uq3BEaGL9EU7d/edn/5c60whsXnzD36Uu
# DATA hiKxEPyev7smbByPtMP+AMclefljMfRP87rwqaojPJnUbXKxKqsHDgq1/0Dq2W3MYHXVs26o1JrVYotK5xOREhZCH1cHbmV04bV1
# DATA Bm7e5tVTKc6QnvcUl6/dXVg1P8+BUj+zrkl8AJXVvD2oRCEqOklmDrgkWnwGJR7RfMj0qboGmsdkrNgtRJqCPY4nNF1cFihW0uih
# DATA qJRJjhnjdCYuqTPh9CVefH2Ji5JkngXdCV5ZKfjr1+Nk3sUheBA5IL6qD04Hh3jVLBknKc3M1jJlnkXRiufnCPdVkGYWNTa2jZpZ
# DATA JmJySdaMV1gikirNK2x3/KqWBhbMppETo5epWyDgKfUkF/mwhd4fkFVWEdeTaNkj8sbyltW8ZIpZJOB6wnoYztMZS33F6r1TGvkn
# DATA op+QKKkPI2K/RujjPOXRF+iIfqHhOBPKmVAbmlCl/tWJdjnRLmv4XWl8PQtiXq/PYzC1irJVRsrru6ILZTcljDzTKEFDOx4mhRFK
# DATA EAJ6ANv37kLEBkXHmjqBzIUVfCx6QM0xGMUDKN5AdBvOB5GQmkRRqDFjF+WnmIgq4IOS04a0emWJkpaDp2wCTxknUnSsd68+rwOi
# DATA pOxGEwl8+bz6buz2EW72G/xp9Z3a3FF8If78PKBT7Ny7oEp+B4bjap38vCwKLAv26mlxfJ4V5SMbxq80mR8O88bwU4a9s4SHxiXN
# DATA J2Q8shZVvmEa7fkoiVnbqs/moadP0MNqnLPY3JTle2FsUhwOo9k2KANPkH/Ni+Xfm1H2wGNnu4UWgDaugjuZ9LJknLjCM+YZ2qbD
# DATA cTB6QHml5QM5PNw2HwHTzahGL5pwGbB4G05BeOE81eK6NEhth2mRN8OLwhlq6/Mtb9WSb6/TGC/7/pipM49N7VO2FdW5KFopZIjV
# DATA owlYFpKXLE0niwmZondF2Wzf+z4DMaL+cBJ/Mo+MgiJVUprQgZUwG2LaMQy4JiJfZ6ribiE3827qonl5Th3UvZ7k5EdUd1gFUUs1
# DATA GwypySRKI1chtlAVatQg4cnC7T+AFGTJlFW5F7DsokL+jSI1yeRsVxpyRtR7UByGn1YLbl2sBb8ejNiOUFOFyGbRwDjgDMnmU0zA
# DATA KIFB2jtRc4O+6CzKTud9j1dqkLssR54qthvl2iCKIKKIqRZZFFE2jfoxE2FF/TI9YT1DMwmfRMfbyEF77LtoBayuz8J8KFWwFVSu
# DATA 1FzUFFyado25a0Nnr0g9ZhrWD0DloYw6JgMbpjp2UHhDsghRv5BlrALKwodUqaEDeYStYmqPzTMLVXmBXBt5EM6v4fwaG/o1ijXN
# DATA uTWcW+OSa0IrXSBXplGuqmyB/gpTnKq58W48dVbGOu8GMxlXcux5ozcvc2D3tzq5qK+ZSS/varBHTnNFz3o5l/LzkdgZQt+SwUBM
# DATA gyAUu6DgkOBdLfQz20im19lR21N2lV9Et/AJb+jHKyRS6mnTM+rvZp5fl+ObGAZSMu7JeOEzd7g4Dh7KHVU5JxdN+Wjeat8Jb5Lh
# DATA lFhlunFU1dMmqvq7iWrt3Kj6nY2jKtt+EFn+dF7c9O157MwVE7/Gsuj5VvRqa2KnVgWNP0vOBfD0D7y9m7xPcUwmttzI5kc6vvOq
# DATA SCvkWYhjIXYdzC8V6tyUBveZHMe9KUHkFdn4Zqz2YS6tcOCISUSTwdAytQsK/39NtmlfT1BpYj7AKGlAOjJlOA5oeAdsZ0qPkoGG
# DATA GZiiAuWzWA2kVHRCNdkSSqrZ+2shLTEkJ6M9hlnyji16SwgeZiI0UXhRKl4Y/+xnMYYUdq9M5hkE+bMTsn2TcZZ7Ue2YDaPR9JyF
# DATA 41Kp5ovHtl81XwaW/Jc9W/T4+/iQl/ilApOtXNIoo5lVfcSG5RJ7Oaxyi3U4T8kmJpPOph3+Pwwv/AK0wSKD8Owf8d9F2uE/n37O
# DATA PMKvTr85/YN39rdnvzz9+vTLs7+nJ7+hT4pbyIxDEAslcA7ZYyDi58Aonn1GN/z+7B/ooS9x2zenf6Rw9JN/OP0GuMTHjEGkIB3z
# DATA 8HmYYZjqlU8suMKDeIIcpWcqyl/JHY5GYrBwkqE7S4TJInqfSlFoBDCsDMGDelJt9EzjqE+z8XVwww/0NgYaABit5tCG1mRCF9h1
# DATA ww0XSuXq0IaqjujbwNnQxB3+ZeF+bF+xOtz7yUDtadk62pAjUAAbxhlXdoc13KzYto41fOvhdIReJtDOkHESzkcByOvJjDV79r2P
# DATA 0Pdz35Xv8+LFL2yMp2fN/ieKw3zMPWUm26DgQklmgV7LCiaCjlkAGp5fBVdbLeWW9bRwhuenweEM3Uj/BCO95hZeZoB/OTyF1za4
# DATA b39s32hov+DIfj0Du1TLUh5YzMKn1XKuAk5YSiVWAEACUpy/uG8lVp9zLCcoEJemgsqBtqY3UWcoHt58LduKtUQ3rKQJe0XL+bYh
# DATA kdB4WfPYZbOkzyuOPB5rVBzz47iWhDTXnmQm+tE8TbxgzPg3HvIjMhvifoyl8YJNULAA/n/23q3JjSPL8+xnfYqoKivLzCIA4g4k
# DATA qaQ2RVGXLpLikFRpeiQOLQAEMkMEEBACyGS2SmtSqWu6equstT3bZms2trttY7Nm+7IPbFVxRF37Yb8A8ivMJ9nzP8fdwyNwSWQy
# DATA M0mKriqSQCDCw+9+/Lj7/xc8xMFiBN4J4I1SO6rVWiFZD1ScNwI/RoTYtmuP4YoRI5G9OkKpk7V1VdStyYHUL0crdLRCRys8K1rh
# DATA ikPNSlObVS3j87TxT2Lin4aF71iFjlXoWIWOVehYhY5V6FiFjlXoWIWOVehYhY5V6FiFjlXoWIWOVehYhY5V6FiFjlXoWIWOVehY
# DATA hY5V6FiFjlXoWIWOVfjcsAprpWq11j4hqzDodEtB4wViFWYWno9NKqyVvEqpuJff3Py41MhXGl6jRn/vVmrlj6ubXtmrl71KY29z
# DATA M5VL7VKr0u5mMXYUVn0uxq46QzaUk34C8NtMA/xqlVKG4FdtJmUtx9YSgl/QDPz2LDjR4gM2a6ngy5XNdPCblYWhm2SmQq8Wa0tC
# DATA r50odLtEmiWvWm3sVTf71LXmq5t71c2Vc7o0CyNslLxaqbFbr9UyobRr7VarPRdFeXzsoLQbjR2UJmhhB+udWrPRORI76Hdb3XoK
# DATA O9ihvztlCzvYqdcaNYMdbLXb1VbVwg6Wa9Vm5cyxg2abGoT/d1aary/h9ol9683YRdocz7zNDJRq6vVWQN1N6OckfnMBhjW1Elee
# DATA ofVhYXHmBRm3u2006gJJz7vJ3PNKsAO8uvyxw2TrdOUcqmnTCZkiRm46qCt+1lCxsIHpyNqbC/SIrpa9ivO8vbKYkk5aGb5P/kv9
# DATA sWfcy4mDmWzNZfNkidmyNMlsTzjgoAMOOuCgAw464KADDjrgoAMOOuCgAw464KADDr5kwEGb7ybJFi+GkNL4qDiiv/GrZvFCuZij
# DATA maX6aZ+LcEOmbBrzdU0OyfBBNzSyC/wruHTtPgIOvP/vf/c2i/jWCYJh4UP6bwDaGoV7Zav42odr77OWOp+j44UaBEI/ShAFnvJQ
# DATA hCUsc/gGcfFaB7iX6Xh+K0aIG+YpfOJ3vWMfZZPUeUE8hh85uOT9j9/9v4jMTNrXK+XiBbnK4p7oGhCkRpk5hJg7233U2W53pvun
# DATA fqb7uKSw5+Gsd8bFthwTdh1NwzxR8G6g2tvaLnPhYM/0dPiLczTyLChg2cPsp80Am5UEOCkBLO2v1Wf1rzO1SyqCvKYbGF2bN+B6
# DATA 9L1ORD/E+3xG+xackKhaLAW064ejgncnHLP7SQu+SwUU4fLJUI4nq8JNHd/3EymjIUQboy6fRU5EczIKNzPl/CCAqewbuR3YROev
# DATA dPOMTsFaLcgZQ84YyhpDMz2qE71xojdHmVHPhxjOLamvTLToRAZ/8VHUMoo4t412AzXDcGegyF9KQ03hI0c0LLQhbtHFzaIkEfvA
# DATA r8I9qvE4vCGf5TtEhwZuyJ6t3TJHM2Vl8NddqM7AP5Yo2dg8GPZdiGqHw32thvuipECfRCV9zK1mMeyL3Y4iC80fF9/L23O5Z7nL
# DATA n14EeJeVF8fkrtxZwk/SuSrElatoFVS6YlsJcOXufiRiTdEEgjE+5FgEstJHS9ESiajhPnuhRJZJzEMa1/bgRf5byLOM+mn1IlEp
# DATA ItsvSsY7H4IwVDt80ajvsqGsz5xKo1Gzg/nCzrMC0GbhTWySJIEmx7SUA8YGLChzxtADliD00/GvTlxyt1cuudtywFysdF1012GL
# DATA oCP0mQ1AxbGj1L9jJn0FQ1bHUSyhNDoMxceSPqL2TUUgk9RtzWeEx1Dti+LetBeMFVhgpOISD6Px0xdZKmXnV2ZJb3LMMnt3Ga1M
# DATA 9UtSZu9CgAj52IooQjYgiqWJ9DqKFjTbEUYW5S514rgYdckaMTytbrAvmlN6cBuLJDzulMUdLul9pr8xc8U0Oi791iQ+ePrSSqfp
# DATA BSiumysX100f4HZezKC+PuFRxbuipW8aA/V6O/CHPwgOxNpv+VDQ8najvjQsTA4GHBpr1A08KqgRaGFA5YBXxQ74bvhQ8HEMTUgK
# DATA Myv89vSFlk7ZuRVaMgofs8zuLi4zPZ6rXlGUA3EtKS/xR2AfPoYBakKxsAJ74ohheeS2GifYG+dtc/l2Gd9FnRBEyDDuieWJY1Pe
# DATA cMKH51g8YQC0yyn0e0ncn/8SKa9aIjcDpVyH4WOsflKESzkfFOgBRpqTWBsi1Bd5fLwLLeBABAkFDKhaDfdvPLNGADC7eSgLY22k
# DATA oHRF/+4U2sxsQk5UTOdLmHsqjMnL4GezgnCONudoyzra7CrlfGzOx3bCxcaFPrkzEpyWKbnM9DAConLDxjQutmcINTgj8lzKk6X3
# DATA nsDe503WWH5q8r4Zngmr348AnSWhmO7KupRQ445CndVX5LDta2+ZAXfxvEDt2ltv948E3EkACeBOfbcAd3OxcSW5rMFxxZUhd7Kb
# DATA B+5CfBDGmFCQoVLMeZVxIKoHEu+hDmHGZ9coMvYL29q9fSxk8v6iRnGxl69U4kfuBg/RE3Wsp+iXJY9V+bG36e4D+5lqcYmbcCGi
# DATA Tpum2E1Lltr4xYXU2a67/V0KxfuILM9BcFCwJZ+VrrN0AnAI7UdeiVuaP1KwOL1hbUjTJGW6Y9WZOguKE6ZXPHBT0MYdLw4N7lvE
# DATA Y6/c/Vpdm1+stp15DLikAquUi1zvrBZOfdREwy/Vntx2uqZCb1rJsFMoWoU9Rxb+Q+n6BhTHnkwVWTV7OBkB9C4L21HM+qmWQPYK
# DATA ELmfiPGcIOSoFwnaI787thByN/S1/OHvpz8efn74O0Dkpn+eRcf9y1z8G315TE99cfjZ4ee47NE/j+niV/z3I4Dj6Mq300eHf2+Q
# DATA cE+mj5VCOhS+htBOpSHbYeKee1OfLXPfM3XG+2t/z/eudUI5iyWi92pfCc9+u6MwGHSoA+Fv+9Go1zHWPzzfk6H4TuFKENdZ74Dp
# DATA uhFc2kIRZadBskCheh48FTykhtZZipB7HQIarDXh8d/Ck3AcuWRGYDqF8+bIzS+as4PJ7VJ0mFyQwKm5vurrR8HkrvoiCX4WQDne
# DATA fEW2I/1LY4K4rjCao8E4oNxqRXfqQDnJM5/NnAE6N5lXmemUNmzUZKovHRRZLrqi8AIfDW/od9na3pn41CjGAfVtb4TxgxysH3r6
# DATA 6q33vHgYKFIGjr9T2pQqzIRtILgWxyvQ5ubX0cUmztw2+Lxg5+YnxqHnnPVwRtaDxtKd2Gh4KVyI52cwnJG9sJK5cExr4fyMBamk
# DATA 8zLDGArPZ0M7C4qdlQ0AzWGRuBMMwaEiU8YM1CaHeDa/IFvaUb8/QXeNBbx3MINos8OCJUViypd2YI/4o4AdFOL9Q4bFarM9jfRU
# DATA ZHy9G474FG0cr0y4A0grVr5ZDROjDNkji3Akfg71a5fmyiEfcOAdQTeij2hE8zh5bcrAqDsueLd1vOWAgoKFZZ3AM3aLnBXQCDKj
# DATA acEkM+QHdHEgHbxLmRy2xXvMaR+Iu4b3cgYD5ujghDxaF0BkqkpQrjrmnWPeOebdGTLvVhy9TnSwa5lZfu4zjdPwqJ50nuEAeA6A
# DATA 5wB4DoDnAHgOgOcAeA6A5wB4DoDnAHgOgOcAeA6A5wB4DoDnAHgOgOcAeA6A5wB4DoDnAHgOgOcAeA6A5wB4DoD33ADwyqVKp1I+
# DATA OQCv8kIB8OatQK9EwbN4ceUERyen0ZJ8b2QUSmvNVHZVa5uNWpAhq5XLVADVJWQ169WbJ351s9wq1ysnf3W5fuJXV5qNVrVz8ldX
# DATA Kid+db28Wak2Tv7qavGZlXW18czKulZ9ZmVdLz2zsk61683meWZ4ql0f79VPm+Gpdn28Vz9thqfa9fFe/dSNq/jMyjrVrs+3rFPt
# DATA +nzLOtWuz7es7XZdrtXPM8Ptdn3MVz9thtvt+pivftoMt9v1MV/91I2r+MzK2m7X51zWdrs+57K22/U5l7Xdriul6rmaCpsnfvXT
# DATA Zrjdro/56qfNcLtdH/PVT924is+srO12fc5lbbfrcy5ru12fS1nbrody0as0yru1enGvUXubvqadDo1WvVZtz32sWm3wY5X67GNV
# DATA ODoaxzHH1ATEgsuX6qkgS81KpTwbk1qx5pVrtd1ysV+pecXdcjGTG61aUGs15iLZmyeiqVcSmrr4cyyaerPoB7V6mqZe2qyUyrUU
# DATA TT3DVwdNvRVstrsJTb1WrterLUNT9zdbXb+Y0NSrpVq7XDxzmjo7g/Mt3qRvPJ2y2K6x6Im3tSkOa/uZLBDdLMXNW3bTGzUavEET
# DATA 2zOZiT6727EOP6u8hg+CrbYto25ty1gIdLdCXc5al+JSTsuaWXbRNYKPJez6nWj/0ib9iD9FT5XipwV6VR8usAVLsOWZ4JbnYRKg
# DATA p7aa6v1rsmxlfh3O2X2g1np1DTPLAGovaOLpzmVOFKSXt4uLYet2SS1xh8+ra+zkZr+6g6o7qLqDqjuouoOqO6i6g6o7qLqDqjuo
# DATA uoOqO6j6SwZVTyxGpd2wvmHsO0q1d1u0PxLhj8tCrOIum23l3gHjykVUJN+POsGWoCvoomyzRaNOronIRB42yFa5VqvX+CpmeSKb
# DATA Fm9pNjpPjRXiXP2GRqkB6YgYXBBjCLNtNSXwsK9gI8kvdXlBNO4gZC5MfEE157ZRiGmoDtaLuXp1A8YRDqqsX/zgQ/Xfpa1f/Az/
# DATA jjiYexd3clSuFqedy9abhdNDVWDrkz1/EPZ6/qVybtib0LQ/vlTJQTLuUu3TDzgqPI01cbmn8fR3Jjs7QSzjIguQebe3b1wy2Ph2
# DATA EPbW8YYL2ez5VaHUZJr8W+HrAq1/neV/Eh3eTCgSgAjg0CQfQWh+/DAUqHypUNZBonNWLBGMCiJ4AU09ETrkF6o6A028MeT5xmQu
# DATA 6xokSkKQbFFAes6EREOWrr62zJziDA67CyzZT8xEAxJpGXlaejqp5BuXMbLAcZXRyIHYh0oAlFxsyRuOsQwEP8+lBTqcTp3TqTuO
# DATA Tl1GzMUp1jnFujmaP4tZFs+Lkp03HKGdsoZWOk5Gym47Lem2M4E0LoSZFmm3KbDFALzZsB2qoDG/YzVWLVbFNNqsJF0arTUjR2fu
# DATA 2y1fuYWhiboWHXHxhmu5qd/IuK0U0xLyFWzgiAn1wAACdYNlnDyr6I9ZoF6Ci6Hl68mYr6e6lyEWC60ppTYHxJZnPck4TyhbUZwD
# DATA aONTUkIY15pDyEf+oi5HJ3gIiJrIeqGnMg/TSLVIqY/T/Yayi1huL1G6VUOjTv8dY0h52pCCYh3wPqJUTPNhoZ6oHApZx6Lg/QYj
# DATA 58wj7d0JdIu1/pgyVwoeTxpSA63ggQWAKp7aXIoqnFgUZFxCoU96bvSxjFkJEWEGFdOrzFmCeFmObKsuXnJE9ercWExujKOhYhtw
# DATA XYlGrCYH9bN4MsQIjS3H0HOmutYOOlb/P/YfCFwBViHbM5h8DQ9UoerBxd/3DxKLSgYgiT181d7dgB2ZOm4MdvUtU4xBxPaQw3Ur
# DATA HC9LNr8fb/sookxrYTD0uc7RvEEn/Do8KJ5l22tVQKZBpfUChYbKol0UJSxsDbnkWErO71AXHhqyjRKU0wkQGToNf9ITjERQTrNu
# DATA GNDpJ63MmGpMtdOmnMoG6nN60QF7fbOQNVEG++kLnCWjjjNQnYF6HAPVmaMvjzm60Mx8zoWV7QX+WYRZL2WnSouhv8e7PCDBVlEW
# DATA avII6/UoFNbzKr/8YqmJHgV0sLZyCG6Ot8hceZU66GxL1cfRUpu8msXMJi911Mzv8bd57WX2mJi0/nYEt5S88WDQ1tFR6ktX3p05
# DATA ZcYefLJ5Fgh5W8/yF05XBgKmN9JorezXlc24q5WnOX+0McYG23zxZmWVaXlg5nVMhpYtaRicNNjDHtXTBYP5ShuYaXPUcvBl8BXZ
# DATA uvD6JETNn9XblkoxQ+w6kvAxUC/OUURGAZkufousbgX4yLR3nH6VpqAJwLuVK3f6Avym3DQ0ZG5urOXrKyLyXnrWwjLgoL4Pg2jY
# DATA oxb6Pq97IC+S+QermSniosgkp3TC04bj2EfF1aA3Yy1mkdIcZVV6Orpq8meMfcwedHkqZprMMLATQmacjCXBLEV1Vaq0l0Ts1oiM
# DATA yPZ4ecSu8nqDF8PiP9DRUxdlJs0WuOejKnEeISf3R6yaHe0PaMpGP4V9yKHryjo3Nldlsjcbm5dQpNhxk50Vf1IrPlvlnJ/Z+Zmf
# DATA 2oBfOF04Oz+z4YlneRwGq/ZcYr7Og7+sV37ph2sPh7Jvh1fByZQJokmsfa1H8IyTYEy/Z10yAN/mUQDm0spAY2P0v8/dICKWBhjr
# DATA GxLGspkmZLnCapUdvynH/WIGsVqHl2kef1x8L0qdzTb22y9hFM+mjNfSTerwjRETyjBffyt8/UjEtBVMOg/0RRPP6lHFUjsGZ5pX
# DATA /RX0j6IqF7AnhNorZcLySJvHLey0vpLwpo+KbmXV2PJGjqQD61PHQH1HJo7YnWOjxsedNGdcvpvYbXsxWUx6mcaO6gpM6msalcwd
# DATA xCjgNQvtmX5xAdVmrUA64J4/GdB8CAsC8TjNqDbp7wBOw2YXrxFYlCH07COQmYGQll6m4G3j8l5I9o69SMaWUPCwrVYzPFmPUEcd
# DATA uoqaiQ0evgBsDmJsWONZB8/YxIjitQplKI38UNGbwJL2h9JTZ8ozcaCo3jHZRJLKWMs9YpA8s1zkpNgljzI4pjkcJl5hy4KYmGnV
# DATA iQLBR6mZnwdO1D4qGWUGI0PbY4X3MaPQ0Zzsn9qsyQJmT+KwDS9PGFnI7On/cfjF9OvDP4JqPf3u8E/TH6aPDr/0wM6mH/4yfXL4
# DATA 5Sw9+5+nP06/p/v+MP3h8Eu6e/o1PfxvdO/nh3/KefTpR3ryz9MfD38HijaCFpL25/T3k+kT5mh/Ro/8K90CkvY3Ht0FXvefKNgn
# DATA FOwjPD39iqL1DT9JQXxFf/8ALPfhZ46u/fxPCKkTi/pBHmQ5QWRp7hT3VW1qpgDh9XgZmFfLb6kRwtc2bU6QYOycIjNu2AsUL0zR
# DATA rqj3G2moPbPBEqN1KUX7Nh6iPihw6OzUfC/pHs4bnm2VyNkRs1Wtiq2ZHl/gihln724FftJdv05fuDK2AhrrTxOVTeEyuzrUI5na
# DATA WjEzqXtJWdkrFNqpk7Kv7kbQqfcBMacxdaDtV8pgdjspoiT3JlRuM3vAxedLFgt1UntB7zLiusvbpMi+i20vlR9Lb6g3pxyn/i22
# DATA YJLW9KzY10dG3mGv3bD+lMO6xlsfbzR/OTy35ziSn+ZAvtI4fqxh/FxGcamJJunJbt9n2lTOAlBt0ijbQxcljztv5fHhcs7JTkpK
# DATA ww5LZfjjXUlDFxshd2XJVlafaXruC5l2tHsw3u0nBWbthfR1bihkMYbiVYjUNyPPRFfAu5q5zLEZRJ60mvlw3oK3zT+yQHcsZGJW
# DATA dJYlLNWrIqB4HA3J2tpVFNyx30KGyQE7sR6SVBlANuVXO4xFn0JnaRvOCMeXdnxpx5c+Q770SkPKSvOVFQ3f87HdT2K6n4Ll7kDS
# DATA DiTtQNIOJO1A0g4k7UDSDiTtQNIOJO1A0g4k7UDSDiTtQNIOJO1A0g4k7UDSDiTtQNIOJO1A0g4k7UDSDiTtQNIOJP3cgKSr5Ypf
# DATA q50QJN2tdIvd2gsEkjYrzivRo+38gIu1VtutF8t7lUrxbfr+t9l8DGqbc/BWTa/UrO7WqvW9JvBWzfRj7VKn0SllH+uXqjWvTI9W
# DATA ivlSwytX6INXaearVa9C/6ffGvmmV614gGeV8pUmXyvj9ppX2fQqJdyNy0Vv06s28+WS/VbeCZlmW1U6Nb9enMe2mlM3aohPY69U
# DATA zgLaWvVWqdWeF0p1BsZnU9IqaWSwhGsBvOpJ9a2kSeaBX2u0ZmJYLtefPoblUiWJYa1yyjHc3DyFGDbrSQwb9dONYaVRfvoYVrhJ
# DATA nFEpV6mRPHUMq5Xy2ZVyrdR8+hjWirWzK+XaZukUYthonnIpHwekJ4OQBunJeGaB9DartVJlMw3Sy2Lz+IqfBel1O5tBLQHp1f1a
# DATA 0GgakF670erQHN2A9DbJOq40zxykx9s/88us+0Ilw6f71HpolkWXcgmVmulZj84EtrHgsqW8x6bH9Xy5E+xspELOEPreCmhcD/2c
# DATA xD3r/K6w61uWvBnOl12/VyHzZG3VNbWCNt/Zn1uxko5gPL3xKGW5G8cCjhhoXzg2huWPuQRUneeAZj+cFZ7ygs3i+VRtSpcGCsPy
# DATA SjSwvDJ/O9TMKwqINdms1iyfTFTdGOwSJqu41t5cDN1LSjhnl8mSWcRsbVPJtaqRcnYvLxyeCqDWL5xGJQV1vPmogwA6CKCDADoI
# DATA oIMAOgiggwA6CKCDADoIoIMAOgjgSwYBRF1QE8Uttk5zPg595iDhO8qxDFvxsuQHnw7bktoSdv7jFn7Mo7Zc5kBEPGJLDW/qK8Xt
# DATA g2KunKvm6tRHht1sD6lu29jQj5u7L/PrTEVcH+RC8N8GutvbUk9Yvd7G5cHSXAJATo9YSfzUe2SUfLh15aF+g/RkdEXZuQ9Vd0b/
# DATA gV5nzzGGODq2vvFJKicv8yFgbStyhm5kUjXYukIJ4uOXMEZ53o7mx+fgkISCnPxUmD8KmnslBcHbYHMuPQ39cE2d90NHkdTKLRp1
# DATA WUJWThlTfRQG3m05dIwkDKmDZcydSdiYLV4g936m3r4hlv/8sjkiJeNoZ6eXSkkupHaOWiRJ4kA/wPd7pggUUDHa4lqpbf+4DZ1H
# DATA JHcjt5P66S2aRFDFjmjICihjBu0DKTR+Db2t+FqpWbxUqRQv7xR26F4Yi7/BDdts1K/j1EJOBSjb0HF5Q98dPBxGAwi2+b3bfn94
# DATA N0o/WyzNPnuhUKwjQpSQARXR+g4C01/kbijphQNe2cSd7IFal0/RcH1eiA0qJinAW5KZLJgIuOM6PlwoMbMx6npNLlJOvP7ll83L
# DATA XBe3rIkMSjpXKWIFTgCQcKNEXNc+VXMSVsbXCEZdHT5J6v5lVTU+1W2Ap8BjbDfiIty+urUfDmhiVeBT5VwvH45/+1t1cT9oPQjH
# DATA 9k/SW1zdGO/SOO1dG424dsuRdGucRvo4i6Qe/Pa3mA9uX6UI+ft+SLM/zj70032Mk3Mq8zFbUTS0GpH0j9JQLn/Ks307T6SMJM5p
# DATA 82L2+LqIHokCD6QP5RR3K/ACmqbptkn9jpnKzunq+Hxc2KNpXarTQ5GZx2TI27BiSYGqUpgTJNb46RETlPUcZ+1r0uolGPGpmUO1
# DATA TsvGadnM07JJH7R2ojZO1GZVUZuFAuRnJXZzDesuPLpCbWIQ2LItWvjm2QmonYfKuJgCdPkuPnjrKI74Yj8cTMbBUTrW+lnTOZkL
# DATA RnJZqYZnJaFlb4jShC4vk7DWx3wp2nxcF4rxB+iyOL8jFs6g0uEFtF1ZaeLipADk/nTGmPUkKyfMj2yW8pK15A1PgYp8ZzojtAcn
# DATA yQpza5J0frCUUbde/q7S6u8qpbMZD5aP9a7y6u8qp97FD1aO9a7K6u+qpN7FD1aP9a7q6u+qzkitX6kd61211d9VS72LH6wf6131
# DATA 1d9VT72LH2wc612N1d/VmNF/v9I079L6KqYNL1RXt6evPwExdT1UCNJFKxFZow31fQ8ErYSjMzSVkw5MRkjMHoBN5kl6H1JLo1SX
# DATA JyGUcl4l59V4OGqAohUMWEjVww4CDlqAwn1DArMiRgPVfP+ph/6VYQaW7JfxtieqUjRMYd6gFcEwCCJMsRqPrwe2gpT5iy8m5KCt
# DATA buq0fOrkZko/zZnScUGsz1wWlDd3Jfu8zgLhaclvnjK30xYvnQvrXIiTZQ1BPnloWqpwUSAzvgQr+xyIo74gYoErypt7yc5BbVyJ
# DATA 11LPl+XEDuUOTaahogmVJGNobSuFVn/EIldwjJIxhKfJrCL7ivmnvPYiYq1Dmcbz1i7oMGKezruacnhAFVSi3MgTeiqksEfv2MNO
# DATA RKEC7YBNxvKT9HJm5ECXT4uhHz8XYfaxZmRGO/Y8JdOfjaWUqpbOWHLG0jxjKdVVOTfzS+9mXmhkPXtNdV3zqTr7LCt9AA/AgO7j
# DATA zUiJxvpwhKYJGeBMI9uZ0PyYXc2jQGlgz8h7U3MxCuCWMnikpvhchzKO5ZTVMCuibu6jcVU3Yx6RqHSNvjKGzajb9fy9KOzw6ucg
# DATA CmN2iY+0prZ0Bwl4PEmYVnQreHdoiPa6FJqIqMe8TipHiTH49iQuMe9fRCAHRgucepZJK6ZGPxmL4cYycmB+dzQRDjEueDeUzrbX
# DATA D9ujaLjLDhiFjwv8Nrvl8TzlAHSr0X3N98Qn7h6fbY2BUoPXmXInGIsZESfSz70IG1nGoPnKBryhz1BDq9vTAL2Ct43MpKDD4VCB
# DATA txEEu+Que1jYxlVGb/tyl13mHs5IoC8eIHc0+l3Szany9ultvDK+JHk3fdg1wi3eiYzqPK6yuUUlAbNYClhj56nUpZKPo340GkX7
# DATA St9bqj+vkuui4arvSSYOsK8zmrShAcMYdPFdJYd4k7QJw91A06moMPApyvKy9LzJ8vzsGcMCzwwgp0cWHU9BAliLYoEqRfgIg9SY
# DATA h7BdMhlsw5LaJCYNbOrFYhrS7V2cUEdTMOOgVAfgEAUTgBc9CBg+j5pH2diXQmLyNFmWO6jKPZDoKTKTAQZmrClFwzibSLGnjiIF
# DATA vS71nFeuEB/JUcmFSdYjjGjzYJPaSGv1unntOMYwt9CrvMyJnF4oMaWwJPMSvzK/8ilfW5LX0i/SrEzjO93X8HKJNJqEhSXMAm5E
# DATA p/s2XjC5zSVrKusYnY7VCaOlnO5beekE+74XN8z0Cy9Oek/pi//pzn4SxCW9rRNFo9jmW/7L9MfD3wNIefhH5k5+zoTLzw6/nP53
# DATA ECWnT6aPZwGX/8IES+ApP/Om3+Ifhll+O31y+HuP0ZefHf6B/nwhhEsVML2IsZY/UOCPp99reiWDMem2b0G5fHz4D/TbNw5h+fzP
# DATA 2+7ITGsUwUhiUxiLRtFkZ3fMjByRmVbDay8cQ11DThGbidhkoG0XMqUw6vkMb5UBny2YWGZuwKDALPT5DOpSfuUd3nFBfWHY8z4i
# DATA i5GNKEeyTOZwuhc4b4zl3II5O6Al18vYmj/qairIo/TNqKzm1luq5mJ4O02aJRmrLKSg1jBlrwk1iaEjWa5QWqcOstxWW6t61DwO
# DATA 8vt+70FCaiKzGrwd4H9UsmDrtn0cN6JRdgR5NoXX8TsYIQw0ahAEZORjAZ7q5QHPDRQFCefnhzMkyyNq3mKzZF5zelZEyyMS4XiW
# DATA box/mjFewyxPOrS/FK7ZcxvWz2ZUX2lQP86Yfg5DutTLOTlgBvRn2H7OgnA5J6kezUPpE7PnfLVMKslFLHO8zukj28M2xlmkmJM7
# DATA L8q88Vk9PIoEFCh9Uwvr5hxfn+M2SKH2VoFbphzdiJJKhtH+ZHc3tvp5+zTHxhqwKB/EQgX03osTE0pGfrLcsMu7SzELYQgImjAc
# DATA 8NqSoV3C2gnlBcozjELjhaxtCw2pfKudgMbIfkhmw/5uwLHwPTZNeINdN3C0S0e7dLTLM6RdrjLErDSlWckmPm/z/iTW/VMb9w55
# DATA 6ZCXDnnpkJcOeemQlw556ZCXDnnpkJcOeemQlw556ZCXDnnpkJcOeemQlw556ZCXDnnpkJcOeemQlw556ZCXDnnpkJfPDfKyXK36
# DATA tfpJkZfNYLPVfYGQl3NWno8Lv6yWvWq97lG+eaVKsVcq1rxSo3i92mh6jWav3Cx7lWaGa0n3tmZxmP3SZsUrU0bXSvkm/b3pbdbz
# DATA 1Vq+VMqXKfza396olijsZq1Xr+RLxYbXbHilciNfo1uq+Qq9fjNfruUrjUyZ1IJGqzPLB6xQtBsfl2rFfK3olZslrziuVppeca/R
# DATA fLtaSYdRbzc7jfJsGM2qV6sWP86Xi418kyJVruZLlBcUoxpimm82jiBrmsjNcPRKTXldOxxhttTm4q9zJLw2F21Jau5IQIWp+HZq
# DATA zWq1egJaHtdfTcuTpmDR8lr1WlAprUDLq3eCFC0vaHRqm62Ellfr1mFbG1pepVVtlhNaXrNRLZWCM6flcbXPLzcM2Luf8U1TUeHs
# DATA 5adWANo2SLHTJNGzODeVr7P+P/yhFn75qDWE+cbOIvibFcujKXw2ZE8ePB5krzoL2UuCOQZkTzsgF+aRndMqQxXGTtU/22NUZjuN
# DATA jQEziC3YRqDHbrXAVVzMvkvyNWdn1RJz4oicMEQ7B59z8DkHn3PwOQefc/A5B59z8DkHn3PwOQefc/C5lwg+x2nDaYS8tnkoja8t
# DATA G9AYQSQ5xHJDc/tTz9DH0Bv0tq6s92b4TirFG7oje42CeXhPpjUfePiwcaGXrmRc8zcKH0XhgAL4kP4DH+qyMS8/XNPHzpO4FMYP
# DATA ka8frr0xcyJdBXABnzUp6qrZoaBD1eAnzVZyCuHuYPWSg9XuQPVLcqD6uHrhz/agNfslE1faLI6ol9LC3ImiDs4We+wnNMdsmSSB
# DATA QJbobD/r89kvwhlF/vuUtdrnHSQ/bdX2+efy5+q3r3BMPvHTGv3wQATqUNpadlJVDqMxczegKMRRP4AQDB+tlarGJ+CV+42JLKIb
# DATA mD5fnpwcz0EGmWzNpLHznBF6pvAAR90uHNP6QLPoHiJwqWr8iuzh8+OIiM9UEzmQ6yfWybMRq3kWp1nN886gcgbVHDW6pEI5wRon
# DATA WHNSO2qhvXY2Qjbcp+tmQJaUaFewBsZuNI52Rv5w1xIVf2a6aacAsKRx+Q0lQ2ONXsfULBZjAIGcomCxGvv1YN73h5w51pg/T/n2
# DATA VFSL32d5b+kbqTZCIQU93xkIF78JW51fNPCCh5SPXjw4dflgFi1+ZxBPev5Y1MsPVPL2kdAhdeJdj/q7Xu8sZIsnrKk01tyZCWuA
# DATA Z1rD6b63JsrTkPjueCJCr8c5Gv5O911Mf7wVjGKWYsJKFfPtRRaG2UZ5PyQDfjKkBhmcshp1I+lEMxY0FacPHqwwQMTgPmWJ6Axr
# DATA MpmWSZBpxyQ9pLWCvP6BMT+ktzE4ygQAaSuqm+WgRFEekwO7/qgmdJCoT8mAJieO4gXSUm0AFrWulKVLBVUgFpfy7kDgOxh4DF4Z
# DATA tKmgtPxUV1EPKO9zRiErUr2zljTFwtOB1kriGdFo0mpBJJ/LhZnEqCZRj/HFMg6IxtFoAiEvT2ea0fFS7s1AXmAWu32lm7oa6vGn
# DATA M/2wDAo3AXETkJkJSNrCdFMQNwVJT0EWTiyetZam4nUw02LXHzJs2McMwxbHjgOlu6elIDNikYza0eqQCn0UyGTG0nkc2wKQGCt7
# DATA ++AnTQQXkpV4lBY7oaZMfReVwl4wR+lxVbVNTu3wypu8tJnEu3WQzI6Yu9yahL2O0eJTkWFH46zbWB0etQD0Gr0tq/0MrMInZWEp
# DATA C0j/mMCzzRVWEdhlVgz3bLI4K7tXaOi2kpKGgKv3mi0EsErV51dlY4R6uXWH6Vntp16NuIdNDD+swWOMpWaj7mPbMlKO3OztNEFV
# DATA hxne4k+L72z3wn6LI4oPi++jjjnCpiy685p8TO69KGm7ksGUa1tTVuNtUxMjyhJDM1W62AwszV6dkU4sZ3/UMdNT3vwgE1WVj+l8
# DATA yIC5eCe16Q5kZ4FMbCd8e9V70DfJyMbbZCqUIytXbofMauoEDBOi1loRL0E/ise9AwW/xE+wEo0UO6/VCK8rHIxlCAxEDhO7JOPd
# DATA SOmJ+gI91+KxDBQfGKlZark8LdbubSWF6cEyU9ahOqh1vhlYP0YGvk9z4h777sNRm6aLSRZijkodA1BcdkenZjnwlFC38JHaokM9
# DATA 2VVeJWDbmPdWwmzvRy08Qr1fIHWaiuJBLItmigLGZXEa2WW1kmPm1+bS/DJNTjLsXUh+UrvYCUxWwZvA96TzyCC4JCML3vs0ZuY8
# DATA VskLyQg7UP4nBRGj7lwocbJbRdxhmjNPwwZj3ILOaWSV6XiOmVGNpRmlejHJprfhxxFzPhxYtYpfTRVin2IZsyPGH/XU6qn2zcCJ
# DATA gG1wPrRqZaWLp9n4Gd6/nYPEXxhgCRB78oWcC+AY93ncDiGpy+gKvumZtsnaMdrkdYDo0KdRu8tTovMCuTK1zb5MzU2odSojrZW3
# DATA wI8PsLiniXD0CNn8Ij3M+Sm2SAyMlzUjf5YVrFRevYZdj6iIaYzsBQfsJkjqWI9+SSwc5d0Vhx/NbqkJsicuMdaQIdTDs8NKL6Kq
# DATA RVGxtqAOjBM5kaqjZK2ICwo0wlHYnptv6YFY9tbZA7G5Itlw5Wakd8Fp5Wk2wdTuNDhFVEkqSrTO78JRDLGfigMiYYkNgzHQvDZK
# DATA 7L8JSMybfj195DHWC/Sv7w//0/TR9Pvpk1mM2P8zfTz9Nj/9DgCww98BQPZvwIUdfk7X/zL9gf7+iv7+cfrn6Y/e4RcSOoJ+AujY
# DATA o+l3h3+afnv4Bf37Jd4EFhm9mcJ4RCE80mCy76ePHE3sBaBAD2TlB/t42kqlPqFAD4NoyPxGBqzz0E5tTwzETgTlc/Y2YqCxXNJK
# DATA DJfvQh+dCKvzG6gHCUVCnp3HS6lib8FcYnb74MDhxGwfiuoIzpsmli6Qs8WIhQNrDfearqX6l1mW2GCMQ4Cmj8VXGemC0WnyxPyx
# DATA IAp2/ZiGU1iwZOlG3a7Dia1aaqfOFLvq99pYdQxkAewgAVT7fd5pz0sgPV4n8bqYSnjMhWO5P7PKAZJuvx/w5BdjCa8jhn8bMH3D
# DATA 64TBeA5G7MhKt9g6SbWlZ8cQOzIFjiPmRvfTGN01T+zYg/pLsShyXgP6KY/nKy+GHGs0P6fBXGqknQfJdqtn33TOAiVmp1Ucw2oH
# DATA x25Ez2HxIZ1QpMDEUhcWFomWJP0dMNh7w1ioSpy0sR8/UHtVEIFwgJNjOMansmQ1lBgARjJU74HXpWBNnYTsJNVGhvW2tgkAn4qw
# DATA 0Q42Ada2QjIQ5tgFE+guhON59oCyBhh8BDsAq1fxAwrMxCOEc5xrE9WvHnZpYw/ZZDwKpcyiQTsYDWLHEXMcMccRO2OO2EojzYon
# DATA MFY0js/NyD+Z7/EUTHxHE3M0MUcTczQxRxNzNDFHE3M0MUcTczQxRxNzNDFHE3M0MUcTczQxRxNzNDFHE3M0MUcTczQxRxNzNDFH
# DATA E3M0MUcTczSx54cm1q6VZ0lXq9LEut1q0HyBaGL2svNxMWKlWsWrbDY+zleK+RLlT6OSL9XqvXwVWK3Sx6VSJV/zStWyVyqWvUY5
# DATA 3/BwF+4oNYEBS2ddp7u52ejOEMYA+KoWN70yvaPa8Kqb+U26UPaadQRZ82rAeHklhL2J11U208HW6s1OszsHzFUpWmCu8mbNgLlK
# DATA xXR9aFUb1WBOALWqFUDFIns1Z6tEdR4ZrNw47vNWvlQqDa9C+VCuec08/VUq9cvVEuWRh8wtchYvTohdinRntVbbrTWaGdKZeWCG
# DATA dFY/AaeMW4bhlHEjszhlVI8aDX8FTpnfraQ4Zd1yp9GuW5yyzXq3kXDKOs12tVVNOGXlZr1Sb5w5p2wYjI+klGF80fetgPmyHGUV
# DATA dpMVmrw8hiFtY5YEZkLWmLPUTLda+6VXoz/lGjsdU2guyVEJQUV4NaeaSpVxrJXNdDfz9nKVfYHsxsvYNuJ5WoLw0unKpeK3ZAhP
# DATA 3aZdYA7Z5ZBdDtnlkF0O2eWQXQ7Z5ZBdDtnlkF0O2eWQXS8ZsktZHBaHq+MfxFs3/PFuoduLaGIDs+/DNRzGotT/CibNRXWNz0fh
# DATA onylaRYMVWo1bH1+uLY9pAneQ7gog94B5cYFBH2BcqU7EbkwPh7WtXSu1FkrXkUCKQtILX2Yy1eHs6BBhiDl2I3Ph7RxQMWcwRK9
# DATA P0fZcseOj3vs2B03/qkeNz4JXus5OIbM7jvt71pO2RIBKxPvuUeV5/C1npfDyy/UGb6zAG6lj1ufMmkrUxlOitiyHKnJIXKV0wkW
# DATA BPKMIiCvVFc4u3YrV97kCT7rymkdOq4+EAodKL05OQhrqs++T0+0on2cdg52Jj3I92nZuT7kRKMu1PA7kxFXUH/U19L36kw8v1tH
# DATA YJts65CMX942q6OgKWGUPV0skrZYi3MMP5HHm1PEMsFSa4/TBj07bgs4UdkK8OIO2WSTUcsIT74kRz2tMJxd5eyqJWJtduVyui5O
# DATA 1+W4BtUS3NbZ6L38ehDto/sXxYGWvyMaa5DcUANb6fzlxE6BrsUrEGoHiL6W0obniT5dfW8AvYVAybAYt5i3/mBnI0MCGvA6UALa
# DATA UUGYbkp/T+GQKNHUJUNPph+yvG2xgD6behbZkiPGEfZyJj8ukLMXPwSAPrZgyxBbXGmwXz8yvvr5pF/VFxIIV7M4L852jLFdx47y
# DATA kgizp4QpTXBXJzo2yKgj4qoeNVHV31O4sKXxLC2JZYagpNaX0FqV00XUyLmqW5QkVKorr8peUxVPtcZoa/kml6R3CfckBTT+Kmbr
# DATA RQni6ShQFrPJat+28JHSp1eIFx/N3ugDXoPryW7A3KBZKyV4GIqKCw936HG0C+rjCfVC0CqPJzs7AXugAYzglQnVQUQjYCwAVWJV
# DATA aYzCHOgAgIqepnEJA41946rdQUCFTPkJ++OpaKAHA4Vgf8cwYqFABeM0lpG8E3ZZOmUs+kOs7OyprbyBiY/I0UOaiKMxR50okSRi
# DATA WWV4GhEZzx9SncMAtyrb6Sdi7KZGMGfuOnN3obk7Y9o4i9dZvItN2OdE4fAqq+9Bs7iLQSYcsIzZfL6T5ssmUoCjoB8yoiO3SHXv
# DATA TWEKzgw3LGy2Mwk7wBkmAyOFRu21MwGAkIe3rAmchibMCBya+2hcN0xT7Xviof495gRgPBtFNHT4Yz3msh3epwY+gQml7AB/ZxRo
# DATA fOXskKn0DymkDg3VJjlwVc0MnCwNCHEZ9hwFrAnn+WNUaIrwZZvarsmQwUPeHoV3hIAaUK4vmBGIxFu0x/ubFINT83OHmuGFjZwC
# DATA CnkYjNoh9jumIKiS4VwwLNpnCRUqL1nBewucLe5G2ZvG0K5d2Fx8FwNMQKyEu+56MOZ+lpMB08YfZ/xtOLhmIuvx4QawT5alcVvL
# DATA UZr+XifyfczaNHtH9f1QmcyJ5p4GE+ERrD9SQffiHNMxYkPt1EaXmEk3ERh6ygOYYGqjJY8sIx6SWrC0g07Y9qUEFT4TWTlT0y3M
# DATA WfCQxrzewbJU3uQjxcb8YnyJTuc27/RUh0Qmoxw8yaww3tfFz9NHRcoJAT9R5usASnxK/NNipHGS0kqVBe9OEDxgSgjcsszzQF7y
# DATA rapaaMXKFF+G/afCDYHaIhzE2lHsxzyp9XcGURzGM2QONsSO0vm+G1HHxPmZdEHcao5Nimafth6DToUTbbm5VWOAe5ud2GdAhr6B
# DATA 6qv3wVBz9VF1Rf9dT1POgBJ9NeUsR5ul8ha67BmQoq+HY56VjajbghCkQCEVs4Z7ThGYPANY9K2evBMdJKc2aVw8zeqcASh6mzog
# DATA 3eLRS3WMvi4XKbxFo84ps5N/6vM3i4tDT41jG4vzXwDBmf4wfXT4u+kPh3+cPvYOPwOihr4+pstPDr+cJeP8C6Nu/pWhNum7p98w
# DATA Jcejnz6ffjV9fPgPKpR/BBeHrv14+Hs8Qa/6kn75nl74jXf49ynSjgXTcWicF4AszGA2o10rjCx4foH0yMk2VOECd7nb2geUe19Z
# DATA VDsBKwY/gMNZcMJjzUpkyCgPomAI7vSWE3CuB36X3+LwN6k5Jrf386bfWIVxdugbSVrSLXLd6fI8LHsrRg5zI0/1RrsH493+aeJu
# DATA eJMtTXt2UeM7PCMAco+3YuJ2h705ssROnXeDSW7UwhyT65n2WGOniJoOc//S80d9tTSVTD7DWFzRM3uoRT+dbVuZS1BpUS+GaR2Z
# DATA LnBwz+Bvlte/xcZH0o6eFfZmecwd8cYN2scYtDXY5nhj9cvhCz6fcfo0h+mVRunVB+mzH6Ol+plEmwH5/NrCWZBqTHqEkBxnE6L3
# DATA XySbGNie2I36GgZjlYnMdGlAw2DndzihTEE3RIpYMZbb0WQkbIpkfNUJl6Ps9BLkFQe/GrdGTfFTY7BvnOt69Dbjdkw3dia9QG+J
# DATA 5CUseBW9eBi0wyDOmfgn7GLlaO2F4noNqLP1u8H4IOUKVOlgnC5johkF3JZEpRPkADUOUOMANacPqDl64FhpzrGK/Xo+9vdJzO+n
# DATA tb4djMbBaByMxsFoHIzGwWgcjMbBaByMxsFoHIzGwWgcjMbBaByMxsFoHIzGwWgcjMbBaByMxsFoHIzGwWgcjMbBaByMxsFonh8Y
# DATA TaUaVDonhdGUurUXCkZjlpuPS6KplJtepVrcZfxMueqVqpW3K7VyOjva3WaxNss/qVICKtXGb0rlSpZ/Uq21q815/BMupXQwlc1N
# DATA r1wt/7vSZtkrl4v0p+Ftlj4u1Zpe0ys1yl6pVqJ3VbzyZuXjcqmeL1WoDEHMqeZLdbolT9/opirdVKIHqv+uvEmPlr0KhVBpflyC
# DATA F7nqVemeSj2VrmrQ3KwXZwExEqE8mfD5UqnZL1UpX/CiehF4nkxa25udTb89L60KPUOlGJL5odg11WItYddUN4tWBa7Kl4M5tbnT
# DATA Durt7gnYMVyRDTuG24TFjqmWG36tciQ7ptXtdOspdgzFp9luWeyYSn2TAxJ2DHUSm35gsWNqtValeubsmB61giPhMXAafZrcaigv
# DATA FsdFpW7WscfOvTL92/ylbW432HxIgjwaSWPzZniznewtnhcL47oqzFk/JQvLw1KlV5c/qdA8ZdEYoAyPoqb3T5FrpIgzKaYwYRl5
# DATA NfljXKOS7CaMK9ufU7LWeFQQDcqwEv1R/2oLk61XHhAX0mpWKMt01qXn2HMzYmFADmrjoDYOauOgNg5q46A2DmrjoDYOauOgNg5q
# DATA 46A2LxnURhuEWtpnbeO1ZaMZw290r8+nLtRjOfSBc7tWT6XMqlRbV0Lde22xSbxxGe38w7WriZoXDqtYci4DymGl6YLpa5pZY04+
# DATA uHPD7tywdfLFnR52p4ePOj28UGvyTE4Vv46aC6W5JHBzsviZ6k+cgl46tObw5v0geMAnHKXNnlBrLhlbTk9tLgh6SpW7JasklCFa
# DATA fVA5us9Adk6fN1bgtiGVamcE7TmP5khB7+AMNOfeGeBQ81h62FgpZcNe7iYC1WcgPneXXV8qjWSCqN6c6gSNHXmoX3fOQHfuthwl
# DATA hg+QTDmVZAMXOJNyZe25mzhr7RsBOrQ8GeFgspB5ib1Qk1FwyupzygNjpOMTTcaUMkByuFUnxJyapQxDFzBO9SCWRH0iCi8S8JBQ
# DATA zRzW596okKhrdkYHOqMTVIPf2we3sB+whDxuwUIVGRq9XsG7HnZNc8gB99CbbYtKRXWAqIy8XfpxFGDBqncgT3L3su/HEh1NFFJq
# DATA tVwHReUdjQ3eXNGupkkFltj3VADUOiiaUl924RscqRPx0MmkR7s0pCySDNC5oo/7Uzc5wMl33mZA4wlLAdBInZX4yYxUtwMcB1Sn
# DATA uGXSKnfIuHO0bPwLfvLYISed/Z7Y785i/8lZ7MdFSj5DHSBezDcL0cs5km+GLH+u4CgQPR94vJd3CUTynOWDnns5jbPgQyYiR6cN
# DATA h7TloE5KhrQ2Kehp020cqzLVQSZ+LJyihKfKmYLErgYpRbW7EcTG10fyMGgA2EKnoY3bXm/SDwfRhKaIxiYaUCWPIGIzDHo9SLtj
# DATA DN1Viutkfw0K3rstkdsnwwSbrqGltEsmqcIcMM9Gv92Oxlsw0PguToyOxU3YRRQExY4qL9Uay+xik4/PjwS8DeEghpa6H7OEurQQ
# DATA rfHch4T1aNn72Q3tpd79lrSgmMzLmJeiC96NKB5r+0/EhZj9o2N9GRkk7QvsJSjfUH8N2wDC9tSNUFVn2ZBsTH7qIjFWz+BsNWer
# DATA 2SODc7a+vM7WxczJZynheIMXK3V9VgJsfPTaglJCWo/hCHvQbpP2kzhvcuxGYMAkO9G047Dg3UrEAHEKR1TaDNqHy5CdBr6lH8g+
# DATA TfYddMO2F9N0v208Ky3eSpZoBorm4ooakJxicXwkjV/W+hCTgT8aaZ4QHy7Be+D1mWMkqjOOs7RLtc6NSsqflJ9MebL0jwkQ0Vzh
# DATA HAd2JOBw5Gnlfop6PSsFcwmQZvGcq4l8flW2BKiXW3eYjtJ+6tWIO8zEfYfVZ4yYvZ5eGg3hD42UNZe9newGblXR/uJ7dtjsYWQW
# DATA f1p8Z4vtNNbIHomVou+8KKlK8kHGY+0tlBVo28+HoWGJq3CpzWh5Pv1RxzjhecFf3PEqB60cyICkeGewaf2ylM5VaDThnNg2CcjG
# DATA WPJyyAbbVYg4hiMImaLeJ2Yr7LW80uTMicRoHjMzrUFKw1g/6gTsxx/DnoXhpy04QSnZzkQ4II1UZ8BCQ9rIHnt/SwNuwfavruhL
# DATA 9cw2ObY00kkxWaMlzAB4xXI3NyJ6xnK6Zm3ZYxVPUvmOWUJ3FpeQrsZSSHeG7INNlxA1Y+5IxOMO7Au0MnfJ/hE3qO9JXVdWv8UO
# DATA NGsgeF5WQURqNYL6KKYcKF3sYFRWytOXjZ2C579gbq1aMLf8UY9FZf1eXxfMnajLMNYBjWqsmbqPSR6NoDvpuVnB296LQsyMKe+N
# DATA Wz9nu765VIbUv2By1lGzREwPn7o87IifW3kkfe8xy+OvF5eH7sWlPP6aDJaZjmzSbk96rCaLRUB1klA1Dj1ZVSw96qV4JQHnsWnI
# DATA KHhvU+s6yFERkhkShT1ROe5zLxb1+yL/TMZFX1hi9FOIHDTrxU9fUEmKnv9iur1qMd2etFrZ/ux1FrFWvVkw+Cg6SHowLcZV8N4P
# DATA abrbmVBHvyNLUUY+Wa8KJRYemNqUV21/InS8py4LO9rPfyf25qqd2OvhqMM7BgZwAFHjGFiNZ1cUr3cn/bCTx0IhS4yr8uBRJ2bD
# DATA HtJCY1jm7/uaS52s89u8PZSw6e0oJDKe1LYJaCHDPfTU5TSboBOVVtr+k22Mtv1nrkjeX7kZ6Q2HWoNbTH6xuHnpn6GWPs1YkB26
# DATA lNXC6dkw0V5oj1fCQot3oyCFQvu/pv96+MX0q8M/gVUGjBl9/nz6ePqX6Q/091eMR/vGY9jZk+l3h3+aBaP9F8aoPZp+R8/+2aO/
# DATA OMDpkxyFOP2avjH6jP734/SxeYlNUqObvp8+xifFUfsLqGh4v7z3x+m/Hf7RUdFeACi32ebAW16j8b7GrhoyN8SLhbya45kRb7MK
# DATA YOJpFgCgoXAnsIwMdQACZ0AHOgTdQBFdqR6PxrxnDM91ZQnLOAXg6VhKToOyPJqC2PkOn2b7+riLOG96WrZAzg6hRqOF34t2EsQX
# DATA 7zDkl2c53Be7YdJNvxmOLXzH6THUYEqrcxuooZGM4JwNDp92dGmdOj/thmDAvRYZF9jRRfP+XRp3zPQyp42sOMJhKGQkDFkkE92d
# DATA 2tOK+Y0ijT+ESkqQdE6s85Ujm0qWI0cBexaZMKuPCfSpiASvgcFqPMNWW14vFxsxmVb2rABry6PvAGtu/D/l8V9D2E4w7L8Uy3vn
# DATA M+Sf+oi/0oB/jPH+7Id7qYjppJtR/vlqPmfBbUsnnAdJzhADHTOpbh0gpJycYRxN5FUS17EAneK+j4Uvs/TmSb/UCmK4tIIRliY5
# DATA 0TRQJ8cWVPQ6Ydew3SjZB54imazIbBspc4231eDIChkU7JcI2g8wNik0Gdcx4V7xqWHeCSS0uTDmPVTxWGhcvDQbxGMxFZAvieVw
# DATA WVHMQM8aTyiEvj+YdPF5ZBsJyvMKPwHbNKODfDRwyDaHbHPItjNEtq0wuqw00VnFJD5Hu/4kZv3TWvUO3ObAbQ7c5sBtDtzmwG0O
# DATA 3ObAbQ7c5sBtDtzmwG0O3ObAbQ7c5sBtDtzmwG0O3ObAbQ7c5sBtDtzmwG0O3ObAbQ7c5sBtzw24rVSrtCvFk4Lbat160H2BwG3p
# DATA Nefj0tvIVvUq1ebH9Vq+UvealXypUu7RP+Wy16x5pSL9UvFKZfpUz5crvfqmV6t7m0Wv3Pi4UqWrXqXmVctvl0qbH+eb+UrDK5fy
# DATA tUyWBpvdcqeVgZ6VGtV6pToPerY5W3Llolct1nZrjfJepf42fU2/wISVprCVKQXles1rlPKlZj9fbXjVptco5ksN+lL1qnWv3qQv
# DATA K0esVJmJWa0ESFzj43yFCjWPvKjfoAAQ216FLqRocbyTM/2yoNuoL8DcqQrcDkd8wu6hVPpygn4rNRgkx6oG9XQLMMFSADBsPHm6
# DATA iKz15OFmM13tu13+rvtflkNl8ddKk+oNhXFMbBw3I42NkxZpYeOCWrNaq6WxcXRTtVxPYeMyIDnBxm12NhNsXLVdr9UaCTau0263
# DATA ugk2brNT2SwGZ46NQ/s7GhtX0UaBmAT6mQX8OCQz41+s/dKr0p8K/anXfmkHkeHFvdOnqcQ4h63AiK93kxU76Ksdc3uaVCsWL2ed
# DATA eeLuyTX39nO8SrZgRUxFA/Cq4SerLhUUqlZeeJVROhhP76dIGSRmvoRd1drFp72caaadyqQy/SnVtMnPvqJwTBZWOwWy0z5s6pfL
# DATA M/i54mK+nMn9nJ0DS0yRIxLIVoLjyDmOnOPIOY6c48g5jpzjyDmOnOPIOY6c48g5jtxLxpFTFke6AwgHFP4W7L0P16TNUcIvyHco
# DATA wnA2sIn54dpdfwQVWn7Ek5vRvC7wBaoWb2Iz3Xpp4wLlRrtf+JD+G2xbp8SvvZc+hscP3/DHuwWeoa9zOL8qFWoIITneN+fQeKJ8
# DATA Cyku0+1r1FxybMUdonaHqFc5RG0fbXJnqd1Z6iV6yc/2jLUcDc7ps75zTlrfNucCpY7k0spq5lCvHFhVgix8lhh29L7SYZaTvAGr
# DATA 7CeHJ4f+ASbTcngSWisD6+TkyhrIb4rqcUsYUR0QqPBq33To6Aic7vEqusdtP574SjYNnxbfiS6Vsha3vi8fF99LHWwnijij35WP
# DATA L4ICcpIXxxRBvLpYBFHnqoggklE2OuhAh8gf7PlxooCIk5PUvKAg3o7YbTIZDnHuGRsNcBjNG4ksZAw8hxxmZy8YNbWg4FGrDnF0
# DATA OKOjw+NhZ3SQ8wI/PuCG8vS6h5k0nJtEpVX/Tk8x1NRkpVMN22E0gRmZlE17Eu9SzQ1YJBdn0OUItS9y1WzmJEYErErYJYJhQEHt
# DATA gnuHLiJRplZ6Dnw8fIL6AX9pSzNPnkqdOknAC1Aw769cMLepqufhVjmABrilHMoHm3NUIsOAWw83G91AGCSDgqP+CA1H64biHCEU
# DATA q6AYHgzZNkSGW2oaIjiAtS0Z38LebjRh6dGn13dNJeXcSunEndv1VTu3GyF2zkDDYzKylJFpgkJzPuwKHEdD3XS64agPcdLJ0FMF
# DATA E41Ygo1/FfWSfUrUKGpJdzcK8JV1wyaDXTKqoG5gy3g8TZGkYn5uJWINkscskruLi8QMt1Imd0d+2BO9FJ/MGlMo9H0M4wT2WyQ5
# DATA 3KFpD4w8VE1Dwxz5qjkozWrAhLXSTKIkkYi9iQhL70DU3p66YNLRf/7byp1V28r7MielCWo4pCpsCga1G5YzTd1lixAMax7GeToK
# DATA VY9hzOM9pvng0WJjrkJmxaIZrkTCxyxqjdKF5/SpiyIT45dX6/inICeiH3feLefdWsW7ZVcx591y3q2VvVgLnWBn491i4S0DwPO9
# DATA nSgSUTzt23pu9WuX+b5wpMGzPWAzTi2hm2LDiNqHrK+lvE1qeYbRTAPsv+eJqlooXW/3N5TbSzdMmZSiFCVU87zpypIrxvVT5t21
# DATA I/Tc6MX6IRtIZd5W3fd5y6veyBsMeet1obTYQcYrSKjlkSrXoVEtS/vJ1I0mZvrBGddUSRF6Yfd0Lnklr91f7McqFWrsQKDAwmBE
# DATA dxdqqftnfFnKwjKOQtl0Q0Fc0/KFmV7WMpNQfhQFPlykUyW7r2zTJbkkTTwU82xI4+FYNqRflCCe0gASIwWDkdXebDXLuyNxvwox
# DATA Fv3AjEp0j/UaB9pLm5MZA9tw7BXxd/xQdl1hS7xgpGj2UPAM5C6ppwWPCy3Hg58FZGHxyiRI6FXG2jrG62BNDcOBYKwQJlnERoIQ
# DATA C4qsoIZDY5B0bB1I8xRhPh8KlPYqYjzZAb+Wdwoka5hq2jrQEpSsV5nITk7YQj3wzHYBvSduyDaMxssiq3/yhmcy1DjT05meq5ie
# DATA ztb86dqaC63D51Ctmk90mNMFs2ZYzzJD34LZybEChXwUyDJhrK3Q5CGWXeLO9/lTt37+JV/5bzmnc+VV6kGzDUsfC0S45ghXU074
# DATA WWcW5YLf429ZEe7scT1ppu0IkwV518GgLea30b+68u7MaT/ewUeFOCNubj3FXzgtKwiLJ8dWtD2WgYPv+wc8fYGeszHMrvKSnUyO
# DATA BmZREP7EHQppeCDLizJ3Ao1w6O/x3KXg3eblrLG2oNQ9yj5DrYTLWJxxbPBk17p8rIeTlaZpHStVgmxluvZw2EOocfgQW9dlGVKq
# DATA 97nDPc7deEowZVSh9oLezoS6CxtW9i+HXxz+jrFkIIg94c/fAV3G2LA/gyiGXw6/mKWU/W/mx8+n306fAEX2b3zhz4dfTL/DpZw3
# DATA /Xr6iFFkv8N33MCvO/wD/QGI7Ct6HUBmT+jnR4wy+5YC+AG/HX5GwXwLWNnhZx6F8Ygu/AEXgUZz7LIXwjpE2njqBX8Iy5Xr2nsJ
# DATA RFJ/9ACrfP4gyMHtQbPSEc8dh75MfzDI0AwVR6V5DQl6Gd5kwIGxNvkk7DEblVq0z7s5aWLpjwWSGmCrPnVmS6llApMOZKB00DLb
# DATA VrQ6jPNGl2VK5ezIZZ1QzmHG5s431BWuqDP0Mox75k6qdFITR6cML+N5fhjzBgQ0B94ZpqPqCGarldqpU8x0Z9MN+Tm/J06luL0b
# DATA dCayTaQn7HhIfjDImXsxj9VevVIt3w8HsLX9HlVu7CO5rD29jM4QK2wUUMACUggH6ILFDFSWkbTJnsE3r1o1F5s46ab2rPBlSyPv
# DATA 6GXOAjg1C0Bzy44/8L8UDqLzHPRPe8xfacg/5oh/5gO+1MdU4m162XPRfM6CW5ZKsRfIHD0WjxRTuL2om963x9kw3qVY7vC6CRpd
# DATA iH2axjJixFHfH3LC5bXoo+TcANVOUJew1KKRSbJfk0dcqfeeEWeLV8SWcc6pSuFRdkzwOhnwAQQRd9m+NgyoCGLE0uvgwA9e/mAQ
# DATA 7cvpiI7aXAps1DDgot6NJiOwv5hBFbbCHrIK1h2DVmg8YtwUjAXRQGA8lzlDoEBOg2g+fMpxzBzHzHHMzpBjtuJIs9KUZwX7+PxM
# DATA /JNY+E9p4DuQmQOZOZCZA5k5kJkDmTmQmQOZOZCZA5k5kJkDmTmQmQOZOZCZA5k5kJkDmTmQmQOZOZCZA5k5kJkDmTmQmQOZOZCZ
# DATA A5k9NyCzcrNaa5RPCjLrdv1u8QUCmaVWnI/LMatTnhSru/V6c6+yWX27nkWQlYN6uzubk8USZWV1t9Zs8OcKIGPqc5Uylj83m16J
# DATA crhSLfZLzWKe/lWfS/pzBupFOd/pludBvcrNmSiUaxSFYvnjUqPolUpAsHnlUnFcgtu4eRQ+rFHzG+25b6rVZ3BopUYNXDKvUs5v
# DATA Vr1SvQoIWqlGGVeqMPmtunnE69qVems+rcyCqOUxHfAh0C812tucAzKjuCQgM4qUAZkJji1pAdVKt1FeOX/rc15VLjaSV1VKpTN8
# DATA VUWIbPKqcr1xhq+qle1UNYtn+Ko6o+h0qiqnnIHHgspxl6ahctI7WlC5arleaXbSULksQm4uVC4oBY1OLYHK1Tr1oFkxULl2vR20
# DATA Lahchd7brJ85VE52F+ZlmUEPcxWeQXh6dcrYLk0x/+xnslC4twLqzEM/N0t/q86jv8H/2djbz9XF/6lC7vurQd4KjWVuTT09SwLN
# DATA LpDY5r0unxnPpiqZVDgsbrHA9fWLVpM6sE7a6XU8O8xjdy2WqhaD4aysWmLPzcQ5PS06Q+vQMeYcY84x5hxjzjHmHGPOMeYcY84x
# DATA 5hxjzjHmHGPuJWPMoS6EY5rhj3xosVMFu2ywc1tXPjFzkmG8xfVEeik+v4yr96yWLw1/64pp9mF3/Wf8qGq4G58oLp1WLoIYqpz5
# DATA YsTRkLtqMS4vfyqv7kxk7XnLDuhXgrvDpQSBx1w6WdKx782XNn5Vql0o1RAdHdoVCaA1ofkiCtXEjOVmWYF2EASdGLw7/QwgeSJD
# DATA EBvtpW6wLx3IUE7lidgXXeITjKnkIKNxinFLm/UjvFiyShaf1nlCt1GQxYf1dT+3lwupEPwLytDe2/jVekhNo/havXiptJErYtMX
# DATA t3qsP231t66s969slarV4msfrt2kKslHLDlUZJAyfDifur2I5qz9i/Xixi/L1Q2agXVYz2q9nPtwrYi7+TH9TP+XdOPsTZeTmiNZ
# DATA jhqwHnOsVdWB82iL47eO1DNq8H989s/I2PgyrlzYmleY6+Gr6UJ8rVS7VNS5yaFe/nSj8FEUDuhZBhdKpNXHC3Ne2Q0HYbyrRFFL
# DATA NV2YOC0rDhcBIL43gMqE4ADwPEMP1zMVJq9rxYZdLajxcD0y2bJBkbzMBU4lkdezCnr+tWUmI7c8NJ4knE8wDpIxpA4da+UMLW6h
# DATA Q9ZsRV3pzLyLAtfnoQvjh+hnrDhK2Hd0mPohGnARlsE06oNoTinCKUUsV4qwjik6vQinF3FsvYiFOqVnoiNxazJOGgDv2tKanjKy
# DATA G1GJ51HG6Dx07MVYERn3kVgxGeV6XEp06/X9pvMyF4zQe3HzklowV8L1C/To1YDLivRjnCxnHpIR9l5XI+9RSvomGBOl5EqipF8t
# DATA zpPSr9hS+o1y0dbSL9UWS+lbBg2izxGniQnNqrhapeX0Uzdb+WYHMaOWzzG7Uilq+2Oxrn6V41mtHX1nncOszwlzRntfH2CkdPNB
# DATA xCvKKBZmEFoO3Sq/qJxJmFCYNHCa0uWmHR/ZTEiV041kPOOhUCYgV6zLmQI5ndfexrjJLd5+a3L1bF4qBx89GmhH1E2k3pz+KcF7
# DATA JuWykI4gPZnCBLy4SITr8O+J1I0yVrQlbytnGI2ZDk3oLLs/1cmzGQThj9QtSoCXqjBrz0ByhvU0GG7AYg6aQbBIgyYtOmNTwWb5
# DATA X/M5YZKBqfkDRkK9QsG+LT0E2RCwI/kGL764RdrCcPMSNy85Yl6Ssj/d1MRNTY6ecTxTiTuM8ajgOhLInF6icvemmYgI8IA1n0xb
# DATA o9LzYxa5guAUa44ZEaqcKKf1fXFcGiE0LdaQnVxk0AvYZmNjv4VHaxtgwtd8X4TnAiHMwlWK9k2JoQodmykNM7ooe+KPJ4jmDv82
# DATA iQ9ozB0w04sSKJ1FTkGIZHqkB1oG0nN3ET/QgQ53o3G0M/KHPFQPAxjSSt43HLH0mCQxPeyNfcYq34hGoqyrxros3FQQyZblJ6kV
# DATA c8TCoXFHhr5tX2GQsU1QdWziu8fq1D5Q5NCH2xZ+mmAldn0bLwoPOQgDLLUG396y2IcdtuqWRj5rPEoKDFJAIMKxIQhDxX9sQM9t
# DATA FoRT+AutSZwo6wnLNq29p4qlhS5b+ARWr+1L/V2Spm3ssB9EILdmkyVmQpobO6OqaCoymYW34N5Xb0a+ktm2C4KvQjZIFvAPAPYi
# DATA 8lhLbrNsG4yaHCrRQJIC5h28t9EkVvmhAg4pH7b3orDDktSs0gaAgmQpDVARE2P7kFob8kk33p0yf0rPsf610ESUA1wmZTrOWFBP
# DATA CVdHXZmFQYeu34860rhReHzZlJWnD89F3S586rrstIa1lGHOG05aZKFYz7H+HDdCvwMLyBtxHZbKSmMXw4v5lR5I7DTokKUdU5tc
# DATA lsQ7QIMruNcYg4iVRBDK5IXUM4TQ9qLujtI6pOe7k17vQPFWVEzZjRNzRZV091OkQlYWlD5hfzdS6ojUQWInKBXxaBftUAoMfXwW
# DATA USuG6U/Pnna0MGdLr6wG7Uznn7TpfFxW2DNWh7b3/C+Hhd3FSKBhl2xUSX1fTgt7ftSkXwhJ1aMIEsm+f83yOk2oWFoh+7SZYlnF
# DATA 8blIMeV+YzVvFCrvQiMjSGpELGZN1LPdocFQd2JXbrJ2iXDFaKrC+sQyaaL30e+4580wsZzRe0AyewC7XGhkVG+Se2VmAptWdqdH
# DATA sPBCSJEdqJsuRr1FzVPsZdi5qL48tfDnORiXYkLgijUk5xn9cVhgLEM8HKFGx4FpZqLg7JvpqmyzIcO+j7vIzk15W8nmhmixrYXO
# DATA ljZPISWnJixKrg3cmXW2GVvvp2blJViz/aClxK9tqtl/nj6e/mv+8PfTH5ky9mT6w/TPTBejT4d/d/jZ9JFNGDv8AldmAWf/FZen
# DATA X9HDjxlR9tijL4/o4hO6/APIZNOvPL7na2ac/YPcd/ilApk9AkmNXvAF/fulAplxfB4hTod/DwYa887+PP2RfqD7v3FssxfFlpVG
# DATA joanxdd5ycqQN7EORHM4URfnyVtEwY3R6hFHauXvQWWRGfLiPYr22MvjjxKvkkVCRPNYijJ7OxsNhzOzbdqkozhvmtmcgjk7opn4
# DATA VOKZl6vr2dtlB4G5+3YQ0wjUlgGbC+mU0WbiXhI9f7hWZOGPqQUObLZS4Z0612zbs/TOk5mBqQG8aAwhnUmPKRytA/yN0xTKPQfq
# DATA iURQ7Jyrt96j+0XTPKc5FXq/i4GYsP2zB3ixRxd7MzyzFWvmYhtnttk9K7rZiklxnDNnDZzUGtBYs5MZAS+FU+scDYCzGP9XGv6P
# DATA N/qf4+Av9XMmJyzU2TNpQWdBNptJJNPNKKvi2WiBcSbLyh5VT9TUSwJ6ynlv3717605OHSxVK8NcMrxndET2A6/scDIwQsMpkdCU
# DATA RqostedB56kec1fFm5mq4FFeQxksbQAgZWEbmLPECEgDzoajoAPfSNoosI2BHDdTdBYeDIxBW5kHbBWAQyXmoSCnOP4xvSahm7FT
# DATA JT6I+Siluqfl+GaOb+b4ZmfKN1ttrFlp4nMsA/l8Lf6TGPynZu877JnDnjnsmcOeOeyZw5457JnDnjnsmcOeOeyZw5457JnDnjns
# DATA mcOeOeyZw5457JnDnjnsmcOeOeyZw5457JnDnjnsmcOePT/Ys83qZr1+UuxZpdvotl4g7NnM+vNK6DPOXJV5TAkT2la1nDosVqqX
# DATA 07leEZaTZHszlXGdZlALuhl8U6VZqwmqK4tvqkoWW/GQd0s8hH2VxKOSPbRWTqJRzWLr5vHC6hYvrLTZNAyqFCHtF9VOs9SozNac
# DATA ZpWqTnNX6pyVPL/e2mz7c/lpy5JXFlLaGSWvbNG8Vk4ePXRqyasI4+uMkldRTx8refTQUyWvUi4/F42kUmmeXSOp1EtP0UgqzeJT
# DATA NxI7eafeSFLJO3YjQfKetpHYyTv1RpJK3rEbCZL3tI2kVmo+F42kVqmeXSOhWDxFI6k16k/dSOzknXojSSXv2I0EyXvaRmIn79Qb
# DATA SSp5x24kSN7JGokNbC02vWqttlet71Y2q3v5ar2fL23WvWp9r3IUQHVxIzgJDZMtXUPDZKPZomFWWvVys3YSGmYx8Lsli4ZZqQfN
# DATA qqFhttrtTqdt0TBLNfn5bGmYajOvzO4sZ49adjN8TJ6wk4luO9U2eY19zraJVKiYv87ek92qMLtk1uQls0ITW2Vk0SwVqlowXxpy
# DATA nVfP0o/pWeD8zYbJ3TSb3Bn5/dQa3VHJVc/MWZ6fvUGv1M/k+ezdiRdx0Q5JeVFJikhcATOBYKlhFvWpql16uWBzcxMemOPBO9lj
# DATA NCdV7Dac8T3PbhdayP10tE5H63S0TkfrdLROR+t0tE5H63S0TkfrdLROR+t0tM5ToHXOojl3wpYCKGJ1DqangmNqBhVduVgqVpu1
# DATA Rv1yas6iHuPDw3hMIw7JMJ8MceVCCU+Wq5cVG/OaOsYO/YDBeLd3YDhXjEikmFC9ehP7+9fLjEV8K3xdkIrXcc5cTikPe5PYg2Cz
# DATA p17Ez6ooLXp+2yvXfmnelgjtyLyU8mAvYFTnOsXhV1jj35gXks0ytM6ZOkEYJwiTEoSZPXTs1GGcOszJ1WEWKimfpWqM7qwhByHt
# DATA BcXFSg7YaMM7bywJmedHx+w8gIYyVDLoQwYyVuHgq0eABPWTqW4+TiHb4EaYCxIsWRxBvqmo7zQ4wcU0QTOcgyWoPiNsFiwZYlDU
# DATA SfDWfx2+fhQQ0QrOJMW+ZlJTOzot5WMkQ6wN9ADwiopJsH7j6Pjq50xkzQUrpqtl+oox1XYQt1MIJUJyJLFbqOsahsFR1SUJJAFP
# DATA JpdM1BtHxby+JNYLIX+mC9BTJh4PVSG/8NC/eaQ/YyEGpvdDz0R1TFge3Dw6Rl4HtgEXqd/nOQAvz7AgjJprtmlSxWrRDDXB3kia
# DATA 3uS8/V2qfGQcjnYCKzSVu90u9bWtyQi+DTxHk6tRAIWmcKwFfpS/WmYeMctysxITVakDMZBZB9OuZwXvatRntxh1fTkl1jPoGP2n
# DATA RHRJTeY68oQ/UrpIiS2TQGb7FK/JiH2rSnxoBWrgT00pxjFP3ERgwUTA2fwvhc1/XNLJ86IUae+UWI48eSvkEVPUEnk9GiJxA1bt
# DATA obbVD5ayT56dvOSLpa52lLp0Zo/HWYBPZgU0Txt+Mk+HdC4AJVV2ekuMVOR5gL83Yc9rE2HuHazqufSO18W0NobGMeW+FfmPcZUh
# DATA Cw4CJCIan/5YylyZm6vgMO8k026NV3z77o3rOe/qnTs5NQ5Le+FhQWm5A2Ip8yIRWhxCJdTXSqqs1EilYGQ/wziZN2iwHTfwcIxh
# DATA ewlR8Y50BrLhbTksctuKhKrEOkXbUAIdKHlUjh0niBLWCUDzCwZtKIIOAoqf0mPNUe2l6rqrl9lEnjWtyroUzZnuQI6IuhacFWta
# DATA R1vBFNngVgcMA/FnCIwUZr9o37MBPTpQkpgqlgXvlubUIOa8OqY7Mt/r+mFvMlpGs7wtwWDhahHP8iWywO3+2tngzgafa4OrSuI8
# DATA 8c4Tn7LuFhrvz49+O9dpjNQJztn3xFNoPPDiqwljbNyLeJBMi49rF3qWfjYZAidY8H6DPeIHBtFCd3QmbYjI9DEWG2lj429nojHb
# DATA OysLuSe6BdI88fXKq9rwu4Nj3tywoV8RKwC2zDhUX/DqRWMljqX3Ho/wUYS58aq2OOvJ3hhFNAZTw96de8N7MqZ3QW1ecMv7MNmQ
# DATA StHiZrFp3HoR77yo3y+DUTYaylBVBpyxePhNnStvqM2JXINzHoaVLvX9EZUZYz+pqo07fKcaI3KeDMY5LbUNzh0wxfGuhNtR0VoQ
# DATA jxv+gOpUx7YFTWS2Ewn8zO8SBdt0M/YXlegogHg3Lx5oy+voiPwmHI0nUFRnKXErDqqA2czj2sqS8tynjKKeicy7Q1ZUMTdQJQ/G
# DATA rJI+5MGTMqjX01U9tuJzURXURVXpFnDpl2O/72g7L8l7Mfn8Tp8GfT3LSdg+Wklckdrj3WjS63C7FHN2AMsPG88xtRJ1dSnggsf2
# DATA JVnAveigz0GQfQ6etQ9xeEuGHiz6j6IWD5xKYn4yYBaiCmkZEHwQ7Su9cm06++NdHf33RyxnT/XeY3ETcXbzeov2G7PTmaxxCsbX
# DATA 3mb0UtTZ8T34gRmpiY0LJBQgi/p2nhiBVD+Ag52G82Cg7+0o1mOyNrgsMTfEFa3S44t4Pvzqxr2vPOuImF7PSLgKu0FvqPozWfC0
# DATA +iKWwaeBMkpBFYaB/wAlLD0m6h7WLDtBHy+wZ1gKrEChyHyQsfBoBfbUTNkxNvjcrH+ifob9FRniPy3b/tNP73364WDtlb/6qf9H
# DATA WR/07qPDCAcTQFWHB6f+Dqxd1qvVv1Lrxpl/S8VarfxXxeS/vyqWSo1i/a+84nlkwARtjl7/Vy/nfz//+c9vT4QQ0aYOJOzwOINK
# DATA sRbzXuQ8Yz+SCuJdvf4O9Rq8zEntO+p1eAmfHihQWK+IVArZtjt82EZ//4jsQ/05il/h0Qudfi9seeryLfqqbxmZB+NJS/ln9BUc
# DATA ycJwoL9PyHR55ZX3b2/funXtNjZQr62tvcJnbF5RGyy7sq+anU3rNJnsBJe68doG72bEyZA1MPguUq94EVTfi+1eSDOYtcuvyFbr
# DATA blxAPsDNd+dg0F7HQzlvjebrzTVrB+oaO4XyCD2f5Nbaxob2LxWCh+F4vbRx+ZXsvs901Pgc2X31EL2Besf9Ab85CShoI7dy3gcq
# DATA MvPffS/3iud5n4zlFMmlEm93yPX9h69Putj7WKpXmtXcA7Iy74Q7A793ae3OO2/9+p3r19dy8bgTRpc+WKPrNDys5daG4RD/qO/3
# DATA Pt1Q2aM2pgajEQ09v/2t3qgac4D2BV4sl42vi7NE9hBvpU5r6ec7GAvGkTpWofJfR4MffI0L6oBfgoNReP3P5PBQIYzv+N3gHbKL
# DATA dnBIAbcXkF9XsZK9gTsz17xXveK8y1f4tM3cNOgrKq77MGTWVXyzb6T7k1Nb2aC8T19BJX7lFZpCw015n+lG6+EgHtIofF8KnSf/
# DATA G5dQxMgCXkHHJdgA/KHA1kSMKdT6Wn5tAz/0gsG6PEgJqZXKuIYnR0EB+wl4G/H6aO2D7fx/8PN/W8xv3i9cvPQ/5e9dWEu/EP+N
# DATA fEzlfoOEXUPxr6+9M9jDaR+rJ+Fn1jb4GTUQb3FLTyVmQydCbuHKsk41f3wfJ3UpplXvVx429Kp/lseBw/WCh22ydWOZSKoYwN4c
# DATA ddAboD8q8O6HdfVOVJ372F+9vrGRytOYYjr2B21URX485+H0gMlOdXWDqp1XWil31FRXYUyDkYqdvr6l4/lB8Z78oG/Enm+5iQ8l
# DATA rr3ToWJZU48Hg71wFA36am+4fR9N57rhDt37yacbcuXaYE+OBNlJzVYCP9+lGnDvk3r1U7rZxGJDVxora6yXZ7LH+mVDNZ6nySSc
# DATA hpYDLvwVk3XpNMKBnQPJK2aLke/P4egtR3KN7Dw8LcHwhVH2wsNiMXNpa03tWZFryfvmJ+u9QTwZYrii2YUVTZUo/MenPe9TyqSn
# DATA 4B2D6/SanFfayCZmfmu9f89qtvd+RU/i1OpRMdMZblcfes6KGWd5gYbHYNBRB1BNe53011HIuKVAkw3q3vicH8oe6xCUPfw0Sr5c
# DATA q6/QfK9Z0ZjXhH+BtSU4Nry+4ni9EbUf4HQN/qHKRw+ODnj6lJP5cpvrI04yoODQKQtMj0z/ggoSO7Co71W0PNgymNMyvU8tEl0W
# DATA +hlcUnrmDx80S4Ziuhjv+th/Jc3V9H5bFNlBwBfFkaVMl8LdALaLPzp4g4UFo9EBC9uFD7fW6MUDvz3BgXIzkqPzpqlqR9+cZCCV
# DATA 2n1lxXCvam7Z8C56a3ZNM49on3mE7iSKCyCEretwcrjy7v33b7978/rfeL+Vb1dvX9u+q79c+/dXr+e8YgSkhwmTU0c/dzscWvIK
# DATA 6p72JfLU3AK/n66Nck0NlGiHhY+o4NZVlbnATTN5ydhOOGe04qltWVZigQps/YPUbfhvrcO1BN2lPIVPeXHv4qPJ9UKS61s47AXr
# DATA soC/qjQg7QYPc7NB5/OqSnDour+6hKfNN36bMafl5TTNzndG0XBrGxbXvHBjvURD9unWIKL37Ocx8w0BkoklFCq5PEpujXs0U5Ab
# DATA cwNELKmK4Elt8+pQdKvBd5gpesDHz/iiDOx0sPdycBaMJ6Pgvmyh3Lo7mqiD1/qjWJ9blWJO1k35+ka6IK0WowpVG1HwUw3X07ev
# DATA NlzpMDM94MIWulo3yZaYF7JPbGz3kmJfKIs+Wx+t6sdGmWS6Px777V07rvdmS23ef6vmeWlppquTeWkDe/X8/rDzSSlXE8uAbWjY
# DATA nYPxuvqm7ORLx8hba5IpkZrJXpYDSF5ifu1iy0cv0z1QtE3GzkZjSRGN+lI+NIy1g3TxeJJNW9bTb1z7zc33rl8/suToSZolzXsy
# DATA Ka+aLq43IeCwoWYAGInWVTXmSRF6bj3DLmyPdtirf4t/UUUnt+Es331f/U5zgLwyuilNeu+FVTEWPcMm/Nwn6DbYYupB/gePxioS
# DATA qQ6bz22sJ5MZ3FdQ8cl58o0nGMqafQgMp3eN/4EQqwnoF2rEv/jG6x5PO2NGg6qu1nZYF7x3MWj7HqN7POxeGsBL2fZofPKHZNRk
# DATA DJE77Ny/hlnY2s0I+7iTGtk2PvQWX++Go37QWUMZUUW7fx/mwH2y37a8tfv3UWL3769JpKX4nlNX4gin2PvBWbj9VvP/lcv1Wjnr
# DATA /ysWSxXn/zuP/37xs4uTeHSxFQ4ukungDQ/Gu9Gg8srPf/5zFu4QXi0WX2RhDGsMWPHFckU0DDT0Vm/guq3NKI9nW70edQtLvIJY
# DATA pqhX9TfsadKfd/0YvkH9NYQ+2MhyAp7cnygriObr7mQc9sw3nkOYb3FviRfSH9lOyKxTcrw7EgKeuUCNLOWx5ChPRj2KsfScOt50
# DATA jSd/1LHw4okns/eJ5LUMmcnoqYYFyuRtu4ODSU1zHq91wOViSoMtdSyjjIKPArX+hwyRWWfMhSWDDvaCrdMMJ06cPtJJzomOvk09
# DATA ygo8KA39nIzbls+F5yp8h+V34fkj9nau8V6otQ0dnswPhuzxVJN37NXZkkmIvGOMMy1jPQ3ioPUkVX4qhPH9+KCPrS7rlknIyVyb
# DATA /p/Tx9706+mj6b9Nnxx+fvjH6Vf0+fH0e+/w7+jDN9PvvMO/nz4+/Iyufe0dfj59Mv2ebvlx+h3djh8+n357+MXhP9JP/PR3+HrJ
# DATA wxQARrnEQI1sKjpyZLHQhz2+Ll9iZb7xVPR+ZBttvOq5pV0d3UXujICsBsnnzqQ/jPVvwQBLlPf9uB2GYlpgtxiGya2ynmeJO6WT
# DATA 43ktCzOpuWr/AVr+0ExQC8kMlawCiv1WKkVzhn5MDNu7VGTrCB9Ft3DmiBtoxogopysDVtz3MTHc4knhSjNKZNrGvJ+7vQk0Y1I/
# DATA IQ7YULyu76G0DyLtDFR3jAJGhml5KSlW2ztD93D+/YzMAJpLpSNnJuf3ux1r7p3KPjUBv/2GPQF/453b167efff236SjPDMhTqXD
# DATA flv6ubnWsnqWge5znp15RhKLhlbg+hpzpmQmW3THZMBNjn9U7VlWgZUryTiw4UdS2mlwFlUWuKbXX7uUuLnupb7l731SzNVLn1q/
# DATA b7z2YWHjgrpw75Nyrl7BjMV+tdUL/Lfpt9Ta/zu16d+hP/gLNfDvqcX/4E3/lRv+9N+oB/iRfvyRbkTjf5Sja3TlM7r2yJs+wR1f
# DATA 0OcnxuHMPZ+49HoQLlnXmUBDitm7eB99vm6scG5ZWakmXxkvowr4gzXs7YwvXbyIrkblqwkALZum+OFFetfavfn5XKwVZ7Lhf53+
# DATA BT0ddWqP0NdR/yfJo5RSnnAPSel/gt/Q//2BM+N75Bd9nf4w/YF6wMfGKw1sfZz1a+bWUp7nkvfqlvIW8+0b+F4+qnwQmyconSd4
# DATA Md7/FaL5aNXoJz26dP2HXx7+Dr24KTw1m7d8zewnEV8zR9T2xI1ZTYf/nZlGUzrlB1UJUmszpgwzrScV5AfNS/fs4HRuHchU2/aq
# DATA zivKExfkN9YkXKvyZJvkB//x4r0LG+vUGC8mba9w/3/O09VfbVx8bU25ZWcc2RIgNtwNIL+0w25fyt1P1gqYghcKa5/KXt3kJ37k
# DATA g/I9XZMo1zaOSHo2vZdSTVsqD5/RyCd1x+Pn0JgP/2n6fS7pAXRr55b/iG5+hIDoNuoZpl+hD1D9AwWu8/q7wz9RDfsR1RM1l75/
# DATA aeWqSA7Oa8mS1tI9tGSdbjsL8WQ4UBV1eSYc0RY4Q76jpkVF7nGivla2DcX48E9k1NgxVi4jtSQADUK7t5Nf53Vzkqzj9XTHavqm
# DATA WJcnVyUFva44647oiflufOOVJ7oFjZErpioBPGU6WNRlqpa4zgsVdBv/u7U120N39Y/q5nh2UPqvkozDL+aU2g+HX1CecDXGsPQX
# DATA rlt/knY7f/zi0ely6jeqxpRhjyUjEfRMlT38kyd34KKpCaq4OdrzSpvmk+vj6EEwSJfv4qVm6i4+LCz/Tr2CHWTWgpeYf4GenVK2
# DATA feudfNIYV6gQKkXra9u3bt2/9e7tu1uVYqn44eD2tRs3t9/f/s21+7e2b167fv+929e3FHCGjeF9fy+4VIFCw2At1QrXkicpMvfv
# DATA vvvrazd5WYETIZb3OzfvXrt9c/v6/b9+/+79O9eu3r52l29RM9UC33p/N3i4XoGxng7/w8Hd2+/duXv/1u13//3fbJU+HNzYvv0f
# DATA Xt++ef/6tbe2r/7N/evv3Pz1/Ws3t1+/fu2NLVaF5SUVKS1MN7NW2LwSYq+68vViOqNEaLWBxoM3nHvKqqBv9VqtUpspon+RvjPp
# DATA bKRqHv5RahjVYAoLP8rz6UJJXqBjL1t32fG2SiqURfiBqUwwFstLrEGqURgQKcowEr6livMDxfsx+pzvD79UxqD65ZH2iswx/FR8
# DATA rcW49WQt/VLa1Pjk09llbXPzssV8Lo0P7qXscyxSz1+g5sXmthGSW7bknETvA3rqHsvO8XMLu3y9AfW+WhZbt1bBhkEwimmOsxeM
# DATA RiFN4dfWEgeG6D2yv0KvsUbYAxy25QgAK02Y3a26D/VaAbb6iuuCjRQ4breyuYbtqbM5d1PecwPrXcYglQAwItMza+kZj4o3+8HM
# DATA l5/N3jszcn3NnSyNS1RzqM95LFX+n6b/zD0rLqGvRVf8F3geqCmQAYJA8/ruw39MddWp4ZgLQeLAV1X+xbP5oFJ8JxhjsTuekxmx
# DATA 1CVVE1Vj0gHOjsseG40/sF3zDSIH6yEzqPygEoR/6LtasYeZiXZEDZ7sCxrg8BAFh9EKGfY4KZL5+a42YCyO2yo5r4aCbyku/yjj
# DATA horETLJkBM4WgDLFdSQ2UHNKMxO1ARxcIfRxzY3Uj81M4k2l3jJuwPX5/cYHa29s391+ffvONYxGa/c2CvpZe/lk/dfBAbvoct6M
# DATA yzDzPrMOqkpc/zR3oKWyQjX9jksOXTd3ho/FAIGNhouJLS0FSpYldZ1fe6mIJ7aViof+aKbLZuLBs0irg0RfgvLnPiXVTHHF7JDi
# DATA Esm0Ar6sgpArODIT2K3htmz8oPvCmDMEzrjM/gNZHUqWj/WyMNbEgsXvuknJs5ov0iIOJbKmeQ0eqVq37l+9zW4UQtHcnFkK5exd
# DATA 2GIWJomX+XohC/VQ7vNHXTRyVApXOMI69hKzbXlID0wbGa8lPyZey0/nvQzLkHDFrWezjXdfrW0UejLFxvxPxyc9aKkVA4m3bI2w
# DATA 4seC/jooKzl0nROz9s6tbQkAE9G3elHL771za6+uL2ZiTYkzdZge1zmmrHtzWUdpNuNVDYeouDp6q5yMwAdsbHB26Opl+5F5AoNb
# DATA CpMBGd3rv9IBiUMfu7EwpKn2w/5hvt3uu1RI7EhY7AxKWvH8wYo7yc/FMUbzhG/ZR/5k7vDAP8gocFnbUV9xF/snnt7ZPYQn/onH
# DATA llfNGhBSzV7nyLxBQuXAyUdoRJCy4p9gvy4aHRb0btY4oKNl97Qq2ifuaNORpfvkBpNtjzEXtAaugjf9Zxl5v+Ko/4F/+Eal9WtV
# DATA qt9wSfD85SpmGCZdN6/dff/d27/O2EvzsliDNSKVXvU95m2Q6+r2DexyFcOxLSb0fXvEyxj2yiiOebiaeVNis8yuj+Ds1MbME2Kg
# DATA L3yId7JeemVmf88nn6Z6b+MVnGNqz+4/5bul65vtB1TZ/2eP5+EyPX1sllztTZopl42ZRbEl9RnPeZ94v772N1u/2b7+3jXtJ6EL
# DATA mT01PBMwpGp7UiD+Spx2ZxIuJgZztwVRCEuSMTfmP/Ca2l/Y2PpRvBKf80Tdmlwp36x4czDx+mZthUkJb0rVqZHuLrXBKz1fSWK6
# DATA NIMz01T6+L+oaR97SyVrrfLiq5kE0NO/NxNvvfedYmavk+rTD8n66StLdzCn9lmryXd6E7o1k4WRi2z8mru4v9c+opl+TPpjpOlH
# DATA STol6ss5s9qk2WKl7H6865drdTs1nXAH5w639Fp+Qd2ykeyHtZaBeSVsbdSav7SHRtbenQweoJGxGd3z+62Of0mv6DE1wTohsJHz
# DATA WmtZf7rEqCCnidc5vFS61O+7wUP5ZNZq5MzofSSEhtRkj62avEfReHb/rVo16wlWRLq8odit7LPF9mOkBMu/PEYPsUKNB+grRrBh
# DATA spJ45+1tyrk77924k/S68DIOU4vaK5zlEA+ahLyRRIajuZIDhCtNsibOqydc0b+SNioVihqCGaxlKRbJvWinA+cWZLdvqvpsXFjz
# DATA vLULEsMLvDU/E0tdJnusG3BfiibJ95yMIgOsba/JObaji4m3cmtDyswvRtE+m4Izcbc3LWyI24S3LNtW98KlEioHP9/lXaobnree
# DATA KZ0NbLSL9hcvlOhlADbjEe25Fs3CktOd1I+WDcPDhXIbH/4eI8gX1Gt9b3W3jE/c4hy8OG8dgleB51VF/YOq1nR1prNABdfrHHPT
# DATA 8l+ysVQWmsQSjv5ltXCRe8VKHWcjG9g6bbpXUPJUNN4n+7oLcmK6gF0Waj/vOMhe1JuyY3NF2TapG421Yqosu52k1tpWh8SDo7im
# DATA HWC8w0MvsvZSgfDmA7i0si36vcGDAc7VG4FW9cRa5hiQSverW9kqZlUvdrXrwkiXAC7pEpCxPOs04UzTI520r9l83JifPZwydZoe
# DATA j/Dc0ErK4uTfZGES/KQiIPmwli5uPT6saYx7HpSH0XooHWbIvTd0FfjkCwf0gS5e1oJbu7exMT9IK7mZGrKRzNfmPslDgXYUIAYf
# DATA 2Ic7VLahnnVDitmIN9uqoO/JOU28lbt9vV0jOeamoqTSoKKVKgnzzKJaueRZq0schF0xCayMWOXJbG7Ax/GB4n2syUIcA2R4EiIv
# DATA +UDwIJJ6uZ/TEHTW7qV6V/2A1CNUDnYF3Y6E9Je1IdLJ5hO3XAXyI/VApu6u1qD+bzWgqi7576jn+jMZxTRVPvxPSS8mrkrqzHmu
# DATA TNYZTUdhms7049wHmh5STOf0FGuYGgXTSyCqt+eBMn3cy+7S/VYc9UA+szJIPWnCvYgLr6w0SJBFHvX2mOkT3x8FPX8c7gX3x5F9
# DATA ogmGQOpeXlKdPRSVMunzxlpZYs//URnEyX4/MeK/wgor5yw7MrB6z5Px6Z8x7sis5RHn91fWMqJOrG403FnNDodHR5iHri8pbJqt
# DATA 8xz/c3SniyOcNtPTefWKqgGDYDIe+ZB8kJqgPRJk1xrVF+j9IP+TtRno/u0McBhXiEc9/yAYxR6Yq57fHUNxPBow6pW3hV5Wsipy
# DATA XFx0UcyLzErNvA02Sf+mR0z9XOHA7/fsoTT5Qa7LAY78wucW/k4/35utxIkGzkXP+NWzDWFhEc/ZajrXv6relm6XVkEk00CrZrEv
# DATA kUvoiNBndgiq0udDG/8/e+/e3NZ13gv3b36K7Uu6ARoAL5JlBQrsUhJts5FEHpKKk1IoBiRAETEIINiAJJbGGV/envZMMsm003nn
# DATA TGfannwDxbUbN7GdryB9hfeTvOu5rLWeddkbIC277TlJz7GIvdde9/Ws5/p7VEe9QGtFn667kdY4LiuPwoE7TzXOUVpPzmdWE6Jt
# DATA Dtt7RSYHtxfojOrPLL/O5WyfIkf7BZ5O4GqNQ7rW+SG3Acfkr9lR5EtQM3xqjDxsoPg0h96SpY3E989Q50ZqS6TFnzuKCNcTxi5W
# DATA zC7K8EL65AVyJHNlcRFFXJ5UrujmXHIkB77fYlc4djJ5JWH8WUJQYkig3qCKzq5mehmFS8nzjwjuaNjvGHwl3E5L/p06z+c6KqQA
# DATA U49qh/8HFMrPP9YdqAayJcXJa35Ct8oe0/b88oxiIT15EXbzIDVzDvY0Szl5VNSaUwp4TeANbWOuV4TFBzD8CPpHXLmy+Gw4107+
# DATA XGhVg6ClmifyemCbNk7zueSHOCd4LNkmqyR0lGshp1VfII5Qb2PDbqO/CQJOOGxevrJ0jqNG7pQZL2WNGW3OltuyPwhdPsrNyJdx
# DATA sVeXQEmFWqI3/nxdRAgOB7mA5Ouupek5ajcwU5K6GxBxu1vSMRki5LJvUQHYhGTUx3rtQPUP4pC0Np3jDXbMzFwlaQHsgVbvzHBS
# DATA oFiOTuof1Ih/g6YPMho91W6qScg+fRpqo3TqTnfzmsO9gBCA8ZlkpdXbBULtcyUBeTrst9Gt476Obx5bBmdKH+2wy1Flyo4dvhCD
# DATA dYcprFGH9uAnXYLEJsDr6anUCcmZRNIquuYa43XBeaRz8R6zzw9AEbbVzJ0oVtPWIzs57p220Yc6n8ES3ePinoSoK2FLYvH+vcSs
# DATA Awphe5BMWTmjr1skuq6XgCboss+UZcdfbjccig4jPZODyw+Qgm3nBirxP1b2esnhkeO65wciWEicEBOqfwX979yGSDdt29da8Hvb
# DATA tzdbe/sb+5smHmZrcw9PLBNRBPKBG5Y7Y8eFSvY84jpneSjDkpu0N7Va4oDyaXMo7gfHPm1sVL75UoSFcbjMaS8DWGk3CIxUfVnc
# DATA wMjfG4HEoxscqwQT6dljuFcavsUE30k7SDh1pNaPDr6BM/CnyerwjTfesBKxmWUZyr3bJbwHxvjtPuoNp1mydXfjnc1KMs0ohQH4
# DATA Az7uisTOgwnr/tRhGQFupaiRMOmSn02Hk3byU7Ul4GLHhXyMEdzjrpraaRfjxHuILwR5tjosxWJYxnRkA8M59pBIQMU7eehO2HTP
# DATA qJbP3JJSO+hOJkrSi0uA+iLFr9Rics/yFgjLVQKZzfjQ9tuDFkFAgl65xdx8iYZWoVmG6Pyjkx4mbBeunIwOwgSh04AtrRUH/EOo
# DATA KFtUJb6QagWSHmxWCO1BZeJU1TGEXSBIzeMeIKrhmj5ujztWnwC233yVMKnVMdiEh1NULmA8/h5dMKTC5/dkHaVIsafayJsgl/a5
# DATA Ej4/Ic8YT0uEfiJWPf7LHJ9Cz+LLk60xqxywtximm6LDlJYZiHD2AQBYffDg1QiIm/Sed5xLSLUI/fri2W/Jig1KKMVRoyHpk8hU
# DATA sMACgjdGkMSG9giOxXCAmdnNUvHD3NHze3f8MS/110pv1R/U6M/y+VqFgv3o60UGrd0/yRnpIzRfxIdKZqZwfHpvtexA3e0WjDX4
# DATA gv0N3SsinBT/u0vOjl9NeVGDIpl55Ey5Tr8R7ptRRtBpjQz47DGTKJqruN0SeDQoOX5UQvguxy29pq4kiIM6WG0my8nV8kH9qsem
# DATA QcXBrMCZoDeF4/s1e0WAmP0UtzAvN8cbmZGB3ugz0ibxwMH3o8gCeYP09kAp/s1QDLWl/poOk+OF/Bkr9r+g+HPS+OqdZVGbM/f4
# DATA yDdcWF2BLe8DdxtGvtH5cPyi/HxDflEJWrDWJH+fikLCZwWzBMgeMiVz6mQUIfXOde0cnPmtsLNkwQmwQcGuzR2A8qw/hHHVdLrh
# DATA tY+GPzU1TiEjufqf+gfXnzk7KRcYpOxrsBR+VT6OJS2oWIzF2+JvjdsRTIN+ZmZAFAqHJPyQg10aa+kCfimOdwPFav8P1CF+RLGZ
# DATA Hn0KDDifm3hCn3JRFgToL6bScI4fPNkj9gpAhd3D47wk2zdzYuS0pngiKmgYNPTutprU3kDPln9a5DtTqXpuepkzy8F8/rOaH5oC
# DATA 4/36ewws/E0QyfE1kqRP8L8fP/uUeZyLzuVohF4VB5SWhH3TGw3bc3TcC2zevCOcSHbYf1Sh3X7822xsseNydxt/E8zN/1ZD+g0G
# DATA Vz59/svn/5OJt54fHdIQ1br9geJaVAXMNYDr9Me4Yz9RNX0eslG/MzEvjMrSyIkaYxf7nR0OGBQwsMwoXFnX+meqCtXOV1e/f03P
# DATA ytEJ7Rtsh/zryO72ADHQHqDXCgKfNsNZ+XtnxDmbIqrN/gJvPnRGxAdiDHl6e3axKFDOG913rhDF3pFOXF3UdaMZhSUgZSRq7tcl
# DATA 5WOXtDk6y38SUbo+i63n5SveZx8GesyAdGlVptFtaQx/Hjs9d4aPHasE0lHW3QQn3x3EfSyXjfUf+TNgxcBpugZIRe93z7LSwTLX
# DATA w0005Se17pMJqIIXsy9rXz6pfvesF0aQhtrrgbvZwsb1BS6OUHUcD7QzPdV673MyjaAbKln/wCOMlPn1iK9b0HnjoaxJPiRlx4lw
# DATA 7M9pTdGB1M6NTqpEYTe+kA07lP4qx+4W42rk+tfac0Gl6VONJ0po0e6san9l4tOxOCktCzzwacTW7X4hmOaLWH5wQQ0sbq6NF7Fa
# DATA ootc4AJjOourJK2+0sHFesbQYJ2VtNoc6akV3/nu6aNGy9/uSbAnQPFQENRifcDz5svxOPu2zoWiH+yKCShxtU63O4I/WFElPAUt
# DATA QwU3e1rRVJ6jxUE7/FIjeJjnipPjH/Ar7ST/FZrV4HJHZIoEYqXUnP0rOONguKgNEX/+ib7aJUaCYAYjTjBxrk0f/oaelQN7wJs4
# DATA dgtaET9aXDwIinEDUCSr8qUxS+Td9g67nbdXusfHXVQQqs6XtOZwHrlaZESm4qIx5et74Me/6/Egn2d8WHNX38oWT/OGi/DSsLam
# DATA ezRAeu7EWYchSFQoiEFy6oWxliLR+y5B5+IeIoAznVSEetcbWqtNjdcCjJpdCqVN5QauQtLANB5s2migiJJLvC8gdqCK5EuKSIHN
# DATA ZqOdOFKNQ25ioB4C8Dc8d5pgufsr6ks17qr93wMGFDavt6Kc50JHlPJi/BkuxsFqszY2aEX4pLpm8IvquoxcDtEWoiGpX5OHY4L8
# DATA 1n//jIHLOz18rNYUYPsBvVvxKE/QUa7d6eATxZB1j3vvp1Hr5LN/yT25cNj/Vu1+YEz/BmO11Pr8jqJAtYYqoRP0BRwUPCIYgAbl
# DATA EEzrQ/Sg/KWUmT4RC8PrcMATCJFc+JdfoDYajkrp4bTXh5QXaEQQNp/9k17GJARwQsCEMES4OnBxQhh/4+IBr8ejYZ9M3HBjal5B
# DATA 1DeGzKXdAewPghBmGxRkABioHgFuZh+Cd1SFA0xRYOLHAFhYXYi1cIQSjB/Geb68HAt49LkvmyoC7lAhLtVZeDOghCno99NXX9Wx
# DATA yWaLylsmRnXl/WG0HdApYZaSXQwrRkm+GeszJ+1QZQnmStbDTqb0mRs3i4pxuimEOpzYAt272HdLbkC94JPDToeh8ppy5V69UcKQ
# DATA P1EFaxneEU7h/2Q3hFm73Dk3JscxUkddcuve3v7GvVubrf2f7GzCsgI1UycECRkh6g4JFv/opNuZ9rvjdOZrDel/pcPhsD9n6zEV
# DATA Jk7YmU9NnxuNJK8KQ4PKOR0QM6/mg3Wj0JL6JQ4hnUJqS2/8snPZ8jyBHuEFXruGybGxtU/JgPdbxKn7XLGlX3B4sOM9VXz5Eoot
# DATA HovXkvRGaBsJta5O8CiZyYwz7af5ZlTjv26swa6LVkgP6iJHDfKUEeri7eG+ubKdTWz1Z4K/hC8cbRk8WFhVNp/x/DrGeH4ex6RB
# DATA M/PvOEZ/DnNdQLrnkf85hJxEsaN+m2Qxp8VC0qBm1HwnCTpmdOUXsTP0EgLhxNmW4jn61JFYNJihiKIIbfPWtPuvsDYR4IobeoN/
# DATA yVIxGge/0lwPWP4ImO+CO97b9efuNNYTpDexy3/mBlK4wjFKuRLL1MRPAaFraAeO0LzXIG14JZG60cYBCvOk+is3zUurQmzIAiJH
# DATA VITvFj7ICG8HkOiB4VF+uQ/F7qtSzBvkFtwhQk9IJ1bfmVOXf+Rzvtgx3L0nd9rezzW/Y9Tv9VnV/H11Vr1qflxRL65/v33YdJ7o
# DATA v9fIT840FiczhOpRCPMZBkY8TS52P3yO5P8pOUb8DeChaFcAC5/+iyBC4iBnAYARtsOSoRPnxlOinqxB9I5R/9d9v1HkJchzkzVO
# DATA vAfdnCwmoBOcoMzf6mPSrKFiyqqyKJcTOHjVtZ5FR/uqJzQq6BafWijFf1bcu3rPel5Fj8JM+2LN1eKjJlxD6RpIFPwZBHXkWkIE
# DATA EC8KmjFffOm2SeiP12f79Me12V+wg/4DHduM3QIh1wMAN2lzQn12JJxVh2X5AdN+1Fc82CvnKXxL8a9B8zamNYBVth33IJHcK90B
# DATA O/oabhSjz0BHsJghp67uAyU7/wavB3194Lli/avFpK5WZYBPCCWUu8K2++ArI7MgZRGFtDvxQQBhZnE+HnFCkJjDIDgS2i0Jvzxv
# DATA JwQmwQhO8y7zIdcW9MTLjZT5AzjvgJUt98qNa7FDkyN0cl44UEmUpKE08z4JfKVdY4OZkaMAoJKV2F4rrjI792UEgHWRCfqaAmjQ
# DATA qYuZpd9JzXaB2Vo6qR8sU8cs1VU8w7IdLFNdtCuF4ZfCbz2IPjJ5UvMNCTZ+IsQAghPBVcwJwHGxgbQ/g2cZIU8HdpFkMz/Z/mFS
# DATA 9R38r5w34FO6hwsWgP3FPoXilkg4QYgIUW8Cuk97k7wjyeaPlgsyVHyKL3skFom1wDq8KAttcI4ErgUbqL5w3Gx865ClOojWDIM8
# DATA qFPC0o8PrKWffi5OmuaZ9z811Iug5nJ3h4OqY93ScaJch/T5NvRc/3GZcCd0Hbcl7ObySJSJNtcxr7TZHP4H2T7epRLTG93CKfJ0
# DATA qHWvp+2B4sA7Cag9RIY3dtqnRsB1EdKOw7/ajVy6hsc49wU9Bi+ETK53Df9SDASkWb+IE5tgtOnRRTDMv8OTyxp3DVjGTLdri7UX
# DATA lN6dObZWQUTJ9fxT9LIlDDXyNC4gmcWzRqfKyCdQQeiMJxiTGPceZMuWLne+m5l3JTvOtk2H8dW1XMA7HYCS0cGecSFAiPM1ePP3
# DATA SawTMRszLZujI4LPmt+SgSMCmK/oDp6lWYzyaQcAjQnfheq7LQjkahF50oFcJQ52AWJ1odB7F2mM/nFgxgYWPhzaMAdCt+fip/Bh
# DATA 8KP2iOem3lAAPldjY0zzIJLCI09l5nGwupTlu5sWPEnz6osHbQbRdCaEDmclErPpA1D5CEF26PNQggTowLfZ4SDIdAHSGSASKYnK
# DATA 5UxcOhoMOjLcwuOpl1W6HjfzmKtwIy4WOvp/a9ho/p6hsFFWbrdxP/S7YCkePh5AnsVBe5SdDCeh8VtiPqePhv3pqb5urDvV5GwE
# DATA Kqb0sDfooLmMOl2X6QXB0E/rVE/coTHTdqnQdaK39lPgCC+li0tcT9u6S36MAy6Wwz1Z97ao1MjRHzOXbETD4D0x0Q9Sp+EtQmjs
# DATA SS4LKm3QRL+pptzvSAxXkH6VxZWlMUnplycUaqAZyaYbXZB/E5o4OQjp7HdRj2muU37CaakXuDNjV9jKC7/A4KTZb82JhYMsq9Rd
# DATA tCWVBHDioBJdDIQlF/mrrZ3b4ns76lvOdkpyLv8WfMdTT8y+kI88dS6IuIhKwyaqq98veUqYQBadC34GSpTA0/D5L8HfSKf8skgg
# DATA 9EbEytlrmTdbns+7J/7XL4QcIQUehOD8NrXpGCsPzvQEvaT9mQh6nIj6NFP3zOFZ0m2P+z3MjcFZf7MK/t1td0R1Q4zJHym2sz3h
# DATA OPveGPMUq69OIUJHkczO8LGLClILneFd7f7Kf6Ruf2WOZt/0+T+lYn+BPWcGwKp9uwieZn8lptd3wSNkAAkr+t3TUNNunG5d9Qg4
# DATA iuuEHlOm1QMHe6uIkweJLUfDgRKY+z4OX2xrOHpd/aHbH1tffo9o+cP6EyLAiLUE7hle4BupFgQinfYeMEQZvAbYbdKmLxSur187
# DATA iNq/omcX2xVmfJeOx2GCHhFHXIYhAt8rNMwFbvj6QnRNF8FTuEPCeC9ZVD62hW0FsVq/S/d+vt7hEtQEMD/M09XC0FBcZVE09o62
# DATA ztcicik/yKXAXd/10/rcHYDP++FBKl0KeCFHynuU/yW3uVjsbwhEMG9WUj+DTizYzaiYlvFw6GC3SwExFoAweqY5rQ0toDo3vCyd
# DATA 6um/a0ekr4lN8hAJ8JGFHHHQE33Ty6DTfVIxzFp3oKTRcdtA/cyNP4rBir6ZXF8GMNHlvDTFQfydn5D4NzRW9cDNA4K6DPCXioQb
# DATA aRDCuttL9YZx/epJiD3IUN8wCVAS8evqyerw2urqLHfgXviD6pOWChEOyZsSiY5USUgsbQSWzHLEIBMFJ6xonN98zD7pOoBLri9e
# DATA qElKn3qbzpfxj1mG5wpnRTKpZBZb+uqwkb10dYiUCghEpTjShoM5mEOW6hKUEjVhT6qW3eZCpI5ODT+MHWcZV2g/6zGNKIRWGEck
# DATA /msWZu7LUUtbdnvThD5lnMctAVqTAE7ymRYcCdapPQZDAiafIFgsrFTUBbNfSzYRiRnuc/VZhuhZqFLrdxgbaASRD9gIX/poGpvU
# DATA 4nhVIUs0z0woz0KcVWQoohciFPkCkc9Oaui0clAixExb3NBp2J0XpuiJm0+FrybjKG/iP2q3OfmnHARhecLi1brnThCCdo9xl9Hb
# DATA zYvGEpyF9PdGpQP5g7vD4ryvvQwFVJnv1RwkoWlicDDNkMJmlrBgJnRhbt7bO2GQBLN8iC9kXetVUzXi7Gt6e2re0Nenz/ksc6A8
# DATA DE2iRpnN4TLBFf+PYaqlryjFm2POY58bnn80bTrYRJ4/CafMm8PS/tIoRkTSZP7BN8Bw/D6h/7j6PD9MIX8ua1wFKOFsKFxUaccl
# DATA HY2d6QD3ADI7xo2iIn0Y5aqn+LQvctGSczmmatVeczlQEvCgabKQ8AOStksLzgtdBi26M/0YwYrfMBytkp6MlWQkptBP2YTU19Eq
# DATA 0mOB6EMeAGVfF1ec9cmZYsQ4cVA7Pk+Elm7+FEe0HRSgEMc2WSwpDo83J+5AH0XzWsKMxNU+WlcTDtbPRmnruhHw5xIjBsSTD/E8
# DATA /1x4IDCSnqewRPWh02NqoYUZ+yJZl6MNf07aYEgS8nOddVnW4wjv5xhzddpm/2rJBgmqHfCBvDPJ0EM0tK7Jiudv7dl7GDzEsUvW
# DATA ExOLblMskX2H/j6A/LlNr2JHRK6rI0N1NJHrn4zbwuX6oDkrSCNUd+94EL57O8Mx+S+M1B82kg3tiDvbu4i1s67+l5YdZ1msgG9C
# DATA 1YVBps7ZqQHSjF+JHIFhXmYNkE8cLykK1TCp7HIiPSS7+Y3uT0a3utAtKHxoOMzE1XR46cRjsFUXhKTKRaFiYpR6QgexwybEMhYz
# DATA GIPYY7EYYvAwiXDpaLGZLM+fuLpL/MrxaEmMNWMNEu+QWX6Ea2FcaylGTilOMthu8Dhgl0sF8anly0YwerQ4Eg0e9i72RVF4uL+w
# DATA lw75jwaUfksB/yZ03wTz4x9VRWifnHk/q+QdOZaR/gInIMQMsFABhB4w++b4DV/Hc4mGyYtIZfo7UNQZS97fPfuHSsLBqlHNpBMn
# DATA 9y3EYMMexfyGoL8zcCMJZvaNBzJbkUtdhxa/OXa+Slj7goHPRhl8nuJRetx+1K065e1j8aWQVdX3ht5hyLRLBYtjo92ySzk7QnPr
# DATA FMNsW6xf4szNBYC4wCkvSBVYvKFtREEBS+roG8bDieJ3KDckJEDWVVA6YpFI/kAycihH8Av+YJZf94HgOZAUgswNPAl/ms+XlGNq
# DATA mhD/J3ImomACcz09D2K5osFC+RriCbwmxpRTshltUEa4RWoHrZVZCJTIyBrupOSOd7p5gQFqSxosnB4QOUjwOlesv4Tpj76E9Yoz
# DATA w6Mqjumn0JDKX15w7s+Xl9WjSrK8bGqYhSmoKs5xdCIO1dcl1ddRH6HeT9RNQZwF/NWC/eZypJllRnVZsNIO4WSV9BNth8yyx5Sg
# DATA iaKVsxrFep50n5SurJdt0mtkr2Lxzd4XaovvbO/tv7O7udfa2djbe2979zYq+Kmhijd1tvD9vc1dUPjLS9G8vH3TfeXX4gVjH4vr
# DATA tL6yon/Uz3U3Zn9miXTnsP761SvrK/m1v727fW+/tXnvduv29t2NLXB3Tk8mk1Gm6oatZlck3dm4t3nHFjNv/Cr37t9s7dy/eWfr
# DATA li3sMFLTcT8rOatqVx6O1sH1OghT7763dVv1bOPmnU3Vu823N+7fgaVRXMa0Gw7k7ub+7tYtO9ftzmkP3T30C1ix6MpCvm6/tvc2
# DATA b767vf1D3hCtdzc3bmO10X3BCnl1UCGemDez4ZTdI0obLmSSR+3JpDsG6Wec/iVM/LhbQzifLpx8gB4fp43a8qupy7dpnH3+vIK9
# DATA AAtm7a5HRrl78Mn00JZnIPRWPQkIjK7suN9+mDWwyoJEIFj/aw0EpFA1hOTqNXwliQN8ovNCgsc80AKa4EoymJ4edrWPHP3QQjG/
# DATA cqMhEEhWw2X42LLw++X0wfjBAHAyXr6Q5x0CPBi9xg1wtGFYXdZ92huW0XglhBUAW8EfZErUll/H1at9Bo4ManBgbajB32C8yrrX
# DATA rtYOr11lY5qeFh0/R3lZHIfoCIo214037ftlN9yI3x28zwwD+0q1b3XHk53uKZycnz6e7EwPFd3+IUN7qZ6I1/BTvYFfPvIIKvhF
# DATA BsaSY1so2ReVZP9sFGRppFWREyuTpyLYi8aqf0rJFDkftI7EfQqhNwCx8RHa5T/GdH5fsHoWQ96+iCeI4J15/LJhbBrntN9mDwa2
# DATA Q430nBEw1J5+mffw43ZvQqEfSEBLnL4EfNqG00ljfdWGKAugB3QaVuTgLoZxYAQErF6n3VecZBqN0AhvPtYfQV238Yl2lndPjigG
# DATA TZKuid1u1Lr2juGK7hYgH6OPsiqZrYBR7ehEtVQbqfU3Si5bSzTH2GryA6dMmAF07cra6hvr0QP6G3QqAC+CpyD7uYih0ZV+mry7
# DATA v7+zV7XxSKlxMuLcYbI31gjMuqxu+5hJps5mUoX/3dx8Z+tecmtzd3/r7a1bG/ub+LS2/Bb+q+7S4F0qkhSp6vYc4gXNBAP+dTic
# DATA YDAssgptudbnPhlp+cBLt5Rl/drO5t0WDLs1GaprdRf/LkEn1NVbLtd01iU7UXhxwJeULanF4QItflk6aqMVDSQEMZ1lp4YaxzHh
# DATA ZZJ8QPX9aHN36+2ftH78+ur31fWspmzjTuvWu4pjcL5U93jvdHoqcprAt/t39n5ED+DPR2utdXbmbnfUnoNNDAevdjpUUwzuaSW4
# DATA Q/ksksnpBEwpQaEfmCrq+YlsIT9QkoF2baInRfV2ACZ2JSGU0rX1N2qr6v/WUnOTWUKgxlNaB3/+J6XaWsU0V/W7AhlH2pmipY8j
# DATA +ZWgA3qCHo/boxb1pqRKk1quO25pOtEwzBXUpwjXdJzH6Kst6e8YKg7EatTtjnGzHCopfazWcjg+5YvI7BogYHr71XPFKosWRsHq
# DATA H4ILmxM2+DUnGv8bjfMoEQDUglfpwCMO2EdpOUdqoa5nXSCn/dJx+s7mviJhcI5W1mprwBC8q6amnpzrGZrBs1tmKZVk3Qd3AeAc
# DATA 1P9PdZqycjlv9tZXV4GM9VD3Q80r8vmo9PrautbTlQ/WIA9rcnV1NX+GBLmfk924kmyBw1As0zGIBHYTw/bK+t3uqFRj6YeWwSUr
# DATA 0WTvANbz+0TACHxF2QWe/+KGVqqRB9wvdMIaXNNKlCxjBqp/I3ROsJUi81clVaO25uMvBhQvWRkk64Fvgbq2pMl+riCIPIx6m6Z4
# DATA 9+o6dCY8Et6PU0Jyg7iqZBVP76oSqvDa1F+UZ0B6bjwYiKIH9Xozt5zD7h6naUonMzk/XxJVTAe9J/WVR+3xijp3K0aJvTKeDlZw
# DATA ImpwuKHKBFWuLZC1h0fD/o2lcxrcTAvp6tTjVNgNfYOsJFm/Ja/4SGuTvnerR79sAWOf8/Vo3HukXrvf6r5mCZLp2jr/e4WKAKu0
# DATA ngwHN5bEEFC6ypLh8fENtoGoa3Jlmo1XFFEad2lSVk4mp316355Ohug1Zz/pwnFoYcT+1dWryYr6T0180Oko4a3dUUvx4+otupmr
# DATA wIlWt0kgVXsyG/SOFVfdf9w+y4KvdgGjddwdV3eGavrPgLPuHU3Yk6/6+KQ7qB6Nh1nGT5xq+kNShCR/+d+TlScwAeAts6I3BV59
# DATA /R4A6qsronU47JwRd7R6w7x/OB4dtYhdoUslubK6mnnvgewVvQfqgH8pUb9oC2IXcQtSBZx03QxDjeLBg1rprZced/v9KqYRXSmr
# DATA 0aibbXAGrsg3gk9gsHCrkldC8up03MP/rCQNtVBYXv0/dV6YHByPu9lJKebOUzHWX23PNLdeai7fRqqGv5pW6Pg0jH0DmXWiGVja
# DATA 1zTlWEO9x0iPVAtr2AJqtQbdSQsVEBSzxi3Zp3Bp8kMkGuipqYhD/xjiZPqpfEfVX716RT/tDQ6HU7W09OI6vLGShVunVvyVnLql
# DATA gBGXhQEM4VM27zOj/SH5oT/7MnEZUBSL0/LSPBW426+GK+aY5AFiRcLkywgwh1cQBaH9wsQ7RDhjG7kGsuOXGonhhXTXds3oDw/w
# DATA BogFsbG+wl/SyGKGEUMQ7UZNULjblTwsSuSgfp5s7GxVnPUBsB92J3ma/HjcPrOi9Fcc5KbBKeE2Fz4hvWN/L1Mwi5mwomyVGIsE
# DATA IYH3lLy8cfuuEpdcZO/PmH/4BICFQKb/WIY8fUYrbQMNYrBZxkUsiAENAEbyvM7y9Ur94cOH5I92nnbUtYZuISloaKqcjyQdjrQH
# DATA yHmqCHUVaDQUurKK2hF4hEXVo9dTJoAQGosSDBjYMNsrvJ4OFBHMqtlkCLiX8DE3r17yX4GCkk3g0Lhj+DZexmyX7UiHmllQzbTf
# DATA O+1NqJ7BkPt7nmbDY+jZ2urV66+/cU11SF27HftgNpst5ifVHo00CjQNnam0Rv/U6OfkymqXVOecKTcrMQ4ZlitrHBxbOauutTR1
# DATA pPTxzzi6vXHANugqyUx078FNZ03T5Nua1VfUKq+oUazwg5yaO10wMGat4aAhTaedQ5xNxcZ20HYEi82mFGAk+pOTs3TmWFXJJD7/
# DATA o1m0G/Qag8xVPyZqh4EPUnrr7u3q3rubdxBo+AhghKvH2R6yXurqh0u5D5cmTN3aCtWBnueIVq/mBHqwtopWC2YncFNnZBBWnA/6
# DATA Ol2ji2U8aY2UqD/s0FnIpHk4pCmB0RZUkCP1jsA5D1JDQNJmDKs2srWMfaS+dr12Nb30JiMR8uQUma9GqgS408PUySqs5nj/L2CY
# DATA 9/dvwTra/aV7aFkq4QNR0NwiCzh62OplwPudJdX7yauvnjtmpllS7TgPb9+cBYt5Zd5arq/OZNiG2pM5c00nhg9O/fvVdn/UGwB5
# DATA XPSs5U0GtKPuG/E9igbQzWo1U0cFQbPxF1n3Aa2LtNL0VNHf0+6pWufqCFl0etdVxwgPFZYBrpf6Bb+9rvE/yPj6xdUORyL/xhtv
# DATA 0CugSPDXau6A8pfWOsVUFd+P9WUL9AcSPXzDlRW+c4JsqVJqSh2yhIRMIMyGBAv/dYKUQta5np8RhVi+fKtg/pcoyWv9tv8i8NCI
# DATA fNrQbAB4kwSvwRnm+molUVz2LNcXiRmwYvBjacKI8V0ECq5VJ5GUoV8Qm5tGXViyA+mbE7i6NePnN1yjcPcSp9EgPC317YHmPXDv
# DATA 5Trd1WMed5Frq4A6y+81pQZu7piiX5z3sXMXYxOCFQaOYS16bOOX+uUu5+LTj3IHnPvQrs182nEX4pde5ivbjgf6voIEYNDu8939
# DATA crk2OYE8uI032XcLYgUnpXFt+P5bq/W1crl2hOFQpbJXQr3Ko18OlXl9HpVZW48wA+suM8A3BNAeOOIQ9eQBNxh0a0sgLbU2DJkb
# DATA GQkCPkWCoYxfzzkr9DbnVNDb+rq9zdxL/53t25s3778DYzqd9ic9UN9MjkaNVWACeNOl11fr10EhAJJ7naR3/efKtDMq4gLiTGtw
# DATA PG5BLymsAYzr9RW1R1aw6yvmVX08NLmYqjCf9RX4r31GKtb6iove6TWuo8/ORUUYpuZV44euGX/xcwrEt676iQx303/CMjMAVV03
# DATA PRMq8Mm4jaK2Wb3IgpMy98Ayi+xTLg5wBIzCKYSncWERRrGy4I3IKhy4sC7PcjLr23DYXqPVsYI4j7FSsDkU36C3RVSrh7kJvW+U
# DATA rJk5Hw0frmTTEawOun/GuhwSbbAar8A8aMYr1g2meDlfHw3HXeNXHPsc1tEt1YxzNahIgjWM7aOmG88T0TzhNUA2BfG+HAotet82
# DATA ta9pMDI0m+cvyaSfwVnNu9uFiSSPaOHb+lpt/bqlW7HNuXQxKkMGCDjfksyQBh6e1jorbA/GQkhwiinbJafmorXOPwEXrPDx48e6
# DATA wpgpAvrokU9BsuQCXpY+zl5EBJVVk82PoQqCqMLtEYHEAS7NC7PCBPZe1X4YFUbFRGKoaBKZS2Lvlro8rn7FqGIwBY11MEdZRcQ0
# DATA Zc/4J2c0F0/Owu5SbFY90frcFKEVRU8Rx8NA6i6oImMvG8mX3h8Dd+2HnxR6TV5I8JIB5edhppl6QuYJ9w2NPWCfiw5RTtYV2oeQ
# DATA caUG/7laKpdn5bCHPhaNpqyFck4MacoZr3S3arhaftLIa8eoBumEHZ19mYpskc7eK+Vo8ssxJ2gZpAebQtEPJ1iE8B8qhCteAcvZ
# DATA 8LFvSmJ7zbDfAer+2AsaYIjGipuKDKorS39UYK9VDU6IFqoWgGPPwLekREGrcCr+/L39luOwnCJQ8u0t+gu9dKWfLfyt3WchG55t
# DATA 8jzIekaYqPpX4ItciTkTw0Mb1KB+OTEIbqRMGFukhk1REi81YP7INbJ7lp/k+3+Z5ApfPPs9RxFhxiIMpoV8RZGgoee/IqACqJki
# DATA G9XWIKwf8rc9UodgCJk8SwelU3IEBPMzhEDwzz1CT7UPbiuhsTfA0yCe7r6XcmA2wupyjOBdbI6zW5T1jmlRL3DjtEyP6A+7dfi3
# DATA 2DXgZ6RkeohC0xCwcILR6jLMarzXuD+AoH3r/t5+a3d7G1cEVejm5lW9FXC8KxR3qyqHIaWo7bLIHPpVJaGtLwC+sD9s3LQjYwsV
# DATA vYU4TzNOu7z2GWguho+6Jf6Aqn/FplydnIy7XQtjWAU8WMTSxQuYWzxtnyWHXXAN6HZqySbCqeg4Jq4QSwJM2qh92Ov3JmckJFa0
# DATA izLaG4lRU6QC9WBAZxHUYTJkStHLNPqhhUqgNfqmUaFR/AQ91boxTlXrE5rCYHHYkzB0TPEJV6Od+nJwLk1JsZq6Aoi2AWsj7j37
# DATA 9EpT4x3DfRWJq/LD9GRTB+tNvX/iGM0L1kcgx9oGSVWveWzguAsJfxGZlYrbE1DT71qTIR0oHeEucRfgUvc/7GWthb4NM9CY4AHu
# DATA FawtGJv1A4x1yjAibx1fXgof260NXEu5LufxWhOaia/AgV6oZrgW4SnGX2bfil1EhD6gAzHyTunjyBiNuekihD2SwECJ63R877Ie
# DATA DziDm2qzAs4S/L7VHm10OvzX7fFwhIXGvUeKrQYTbdO5ib1730YQoiNHWJd3mBSdkReNDiOsJ+fooNselRUvpIR63HwwdaNx97j3
# DATA RNW8oS58DvtuI0ZHyQviB2fJgNCYaFV117jxhLAI0Bu6cLhf8I+9bPCXuGoiMZ96xEwndUUNU33ygeIsrMJktjglkE3gVOa3Ub1w
# DATA GybFwdy5UztUUPL8glHnj5A/sRXY7LngVxk/ZSBJYr1pjphcR1EalL0sMacRVQ5EjQmVT7RgqLRBDDzxu7Jk0hFC9gqbRiOGZOFn
# DATA 0VjcIURjd+v3LnS3rcavpwi428UFisYqzIXx9v2TWCtZuiCURnlx/CiJhpGPEzp3vJTyRUBkGBSYz3RS0K+f/zXyzF+ZTG/48CPM
# DATA M/Yrh7Sit2cjkWqGUhq/c2B7S0GydtJ94qRCOS/EdZmjHYGO8HP4syyTA2hkl2OT86FiiHRO0ocg5g/xyoiVo7vO5Zm8ZZc8vU2A
# DATA gWHl8CYiJIh8FEKyyymNOahBu7WSun5oupchTINaJghi0AUqIO40+N7BVurIV9A17jQGcSZafKkg+5YvgP2je2qCXSN2m5O4GvM4
# DATA xfzK1KuPXTGNU1gUgzwYTo+8kXG1A/jHIJf1N82uQT+c7Br0h1CZuIkqbMWmIr1BbR2i6pmbdVPVpWjwUR+cg+/phBb77fHW4HgI
# DATA MKyI/si/NeVVBLuFyo+u4rq6kzbYh0rgcVrRqZLLMuXyBKG1VUfaE9UNLqF61zJn3NRCoKJqVlZhb0KVNXDHcdRd+iGAqgPO6/I6
# DATA bnxsBvKfJcv6eewChTGySMc9SXTjGHXR7WQoDWbt426C3nJCSc9f1HJ7jgmGVUeW7ESBxbU1Uucmb4JwQOF86oJ+Jla00CjSZys2
# DATA Jb1GHw6mkFPo22lYV57XeKYYfsgGktM2h3xiIcaRIyDSCbQzQl0JivR2uU57D8dM6ZhrQFXx0UTm3+KWwB7TbZ9WzFGA1WnhcjbW
# DATA zQa5wgmK+cXaqvqfzQt4EyYmoQAAUjX0hw8R1x03CycdARRMRDodKNkdNg76rgPQ5SPotOpG1+QFdJMdSSqkD8kRXgaNZHXJRH3p
# DATA MzhUp7wEfw0Pf9rQwyNDz/gDSlDUU2e04R9iDALjafGk9S76wYDI4b8mGgd9ea2RrHlBRmPUI5EAjFUQWCqJeCFGCtTyppxoOK7h
# DATA 14opax8qtm066RJnltZqKWHFjidZ3nVxf4AHdRCeagSTNdgc2I20HL3TqBe9jHhC7ZpuHjOSoZkw9Yg3d7mgV2YTD2IEB+oJe8P1
# DATA U2xssiqaZHpnd7ESUHDP5PVAkLmAqpmDlKAPs9uNjr22gZgRO/HTYW+AeQCWSVcQm0bxoa+s4J2+QF/1DBEUgqIAaqt1JI+TM2W8
# DATA eFHEYDGF8fg7vWYmjNayojpa36VE3MtIGKKchNP3oU94QleHb6yuQrAIIOlkHA6CgN6t4fsUUrmYEEt0Qp1JMai85dO5yr5BP+C6
# DATA PZlOev1ap5e935pmSmzTq1k7BnXpD5wd+lpy7Wre9WtnekudjuPj3hHEPAGO7/tIZBWbdYpkyT/Qku5HVXH6VubrAM8r9SocDX3D
# DATA kYAX2JA6glx9earOP/hiupW/AhDK/WmGhSFEGA4Qo2SrPTwl05Y++wIpW18gZLaKhR1DlyvOyuJdkD45TJG4D6eT0XRSL9yMRydq
# DATA A5Rw/cWZMOjwa2trpDlE8PlwM5KemmSXvK1ng6xN6fh5O+xDeKNQjrY7JQiSNp9Vkmuvv37lWn7ULdAbrGVeyHFkJR+rGZuMpwNY
# DATA jU5OJDHNaI2B8KGheDk7LVXKTZVTlus7VvvjJAIZPsxqx9nZ4Kiky6lJHAxLrlURbzBjTRydxbgeoS7R28ahvepvck8gRQG6hY1S
# DATA oWZBdweE3KaDAvJhDV0V2Y2B/QfJWK2dCXdwP0LlYCnqQNC7fLu1s4nPu+Ox/5y5n94phuWABaYNWtTaPjwprYEnri7+fq/fF8Vr
# DATA nXaXYmuAbInnKPpqABKIClVFjD7ciewPwvwL+EndCxpeJRAhfRh1OJewBadjj8roLvHLJQ+MzQy1JHPyyLZrGKIuXnd67YeDoTrq
# DATA R5hY2BZWTdHhwpzQfqKGCnUlU+wjJcBOoy1CJX6Lxo9FlwMolJIAPrGOdkQrwdfu1nDa7zBstGKxkFUGYoE8nhwDQgYynXbeSCmQ
# DATA ppHtQRjVbfg2ajIGUHNL5hYjoJr0VnuAQoe6dPpneLDE3XPDpj6zR0QnheiA8hyTKkBNobRkNvotnZxzhx7wSdFuAuCLIkapAbpV
# DATA o325WXFzHwHOj9wb5BKJzYyGsGvid1vOzpKvgjUkUqMziUrtLKVRVzRUHmf1s0KECQs1cmiUDF1dKD/xK8lGwqFyeluctt9X8iJd
# DATA mBCjB6bVPrFuCFXR69Iu+tlUsUuQNaTbG4G1mOs7Gp50EYFRj62W6Ayeyfvd7ihzk97ZlaeEGYoMD6eAhkmXdW+QGfQVNQclSVz5
# DATA XVqxWclZOdmE/A3oHk5MmGJ31Yi7LboB+CGgfeg/vcNlO+UASZnOMLEoizxrnn5xq0PwQ0HPQOzwyqI8KTXQu9PBAHmgSGohyjz3
# DATA Gajn6E8Ej8DUOjFt3teOWpxTlklUdEwnRDq/T/KCQedmnWclsyiM2l6bZB1+BhhG+DCaVFgmLLh0TmGs3jP1XCw3qDfHT4v0pULd
# DATA HpEJjBQgfC8WSeDs8hkAqOokA67MTezMZ7rQOG812zD5rJDNsSJTfc28dIvxWf0D4nv/YoHps3qcYBJFSkGYpg4Dpwui6ZyzgEdz
# DATA tfBQQ43oIFzbdU/auE1EJrMi86BDiTmVRAUCxbQHeZEUHUzahxlQu373YRuhKzRaoa3Mbme80Ii1WoGoN7hM1Z8opTHLktWSe5BH
# DATA KMkeo+kaqWUfAQZrvrxVcOsbMxQOlDgNjMly9oPzOtdm8E+U2eQzOhdk1Jc2qC+ii6uTmBHO3x8Y8uArndojmj8FoRIoq8LfGfyt
# DATA fA2en/foQOsjl3kPjR/2h4eldDktezsWdHmcLLPWJ9y0WLqkKOyaSYhrrJxuhtxy0USyVUUD7kGayacAik2wEJB38g8Ghg1sf5+G
# DATA 8/pF7NAUqBSNVgMGbdDhxAhZBUcSap6GEdW30hQgFL25A/517pbQO+LT5z9//rcalSqKSQd7DDcF+ga6BNmbAByQJ4sHi6VnoVA6
# DATA P6KM1wMAZCvFaGwB9UaAZodMo1fEPPN9WcJg48SPOVEj/mXSiFMO2EjCOieTZ+wb58wQTweyFBwcRlcUSIqgXOkNp1ladh6PKXHx
# DATA WXCiCMWMsPV1zdKATu/jOmJ6t6CnCcOl4Zlv8C/uMiQORMurq7RDMDWvLOGxRUpzl/zEmJq1uHZ1hgIFVFl80KOZLZnuIcYXQa5Q
# DATA RgxFXr8kJynMPMyEVQOyqNPzGTwKu+pMBmwyiKVADIIV9Wrlybh9xpkh9KLQ8E8JHxM+OZwOOn1AtljY0Uc2+tL8nY3IxzRjuRP2
# DATA 996oP9djpuy7zK1+oTMPUKpeeQlBXgI1gZyw12HjMGmvl3jLz+/sJ+7Cqj43WQ0QpZYTxPodjO8ffQB5pwgyqw6FzBDpliPut3Cq
# DATA IrexBI2Tt7GeG5Ff/jeUChfQ4jzIT7vHlozfX0a5AGGRIRRGpC3cSFDdptgwZDiUWNyTemdwvEtGw8cg1g2zDLIaY0659pisDoPu
# DATA Y1EZyQDChShBpNzsBDmaxyeQdEFLk9oy2B6cJaxaAR/amlDYUC09QhIS2FbA2SreAO9vh29Apt3yCsG1IVw45Gfscy4adJw2EGqI
# DATA nDbwT/YEBdUEgG8y6nDdNzBgCAYqsdT0o+qP0/9lte3W7u3te3d+knxAvzRjbh7c2357+86d7ffcLTmJ0VajFbVNul8FOhLxJams
# DATA 5JcM2gsq3ZYS5JVwrBF7OZ9RPRAUv5GzO9vDTT7xfJRd75vTNif5SHd1xcn/9+E/IJ+hk57JfCWJzAyvMQh1RCpqaruaeaRr1eTw
# DATA yXcBqxEKVcnz79bshJ/SocUgSQc+MDShYpFQKK7AspciAl5XMMqRmTx44BMt2q1LsWycenIJjysXcyCrtTsUqkkHxB4iYXn2UttD
# DATA UjybIhdyG7k54im+11LP+lJ+q7EvGX9KiYRIDGjx1c7CBI5f4mqjD93zj3UuTNw/bs7YZ/+7IC+hzaEps+p64W4YnYMipU5rBZmD
# DATA lg/SBL8OCJLsho4XbDZjtQLqq7mc/p38HiEnz4casQ39soobIzJmJrTcdNIQmud27mk+XwNTRyIDGUBcQcbcphL6MvETQj/7/IYH
# DATA O4cXEayXFgK95IOccKjGRhLROswAfogn+CMc988Bu03cbLVEY93hLalKfYlJxz4kfY7GFHmak/RQEfAsqfbbYY4Ectz8gyr4GwKl
# DATA N3kSa5jFw6T//sjJIIihTghAwg7xn+J2ovyE2t3u2Re1sMGU9qJMBs7fYDJwrhSmFneo3Zms0jEoD2GGhmf/r0WQVcKZ602LaRBV
# DATA lWGFFOMe1gad/Jy2pe+ZqzZnWM+4+1BJMyAexAdNpxWqUKJjPTnqRA+depiQdlhnj0pGGDGApkSm9XC0pplOZYmBpPGD34xEJliQ
# DATA iEoEUMXgaFR19pDa5MnEZPiisO+KjtCuUFB1hWexwrIa/AGx0W4Ug0vcyKUnnrIcT4fM0YRGx8h86XrKxrVsREwX8xtsk5+XJL6U
# DATA qyexuczjqcAdN1okzL7qROcz/jUkLqb8gMSA4wF/e+vO5h7McMDsirzGYf51Dwtapo3WQ7ZAx2o23GvFNArrBBjW4LxTwkkvc1IO
# DATA vssQQbf4znn+8wpQnb+2CZq/kOlY44Q8Te3OtHsYtydFQ2sIHMfgc0S5e4IDB+7gthY1AF9XgLFN8LUQYbQx0L4wi+8ZBrGZ7hi1
# DATA taiXoE88kQmn6jWdqFf3hFbRVuGwdXmR0uqso4/zh4gbJXk3uymQmcmpt+wucjmvHbxO9V2euGmkDFipbcMEEdj7nMJJmz4fNr93
# DATA +TxROKEwHf/s7iK40haeCcZX8bRsmJDOH5wkh3dznIqQgjzszuvxr+l6xj3/PyLwX3VmZB52F9oTxftC4Ix5ExM0sOjm8DdI0ERk
# DATA r1BjHsdnTzqfYMuuBXfnShC/r67mGgu1fKrLB/Ur6+7NMvcMB1ogXv/oceYFph0xHehw3046r1KxAYJxXGC5F9nv8WWlnR6rc6Gj
# DATA bkede8jFEAXk1gryrpKH+wNpsPy74hPGH/4QtVM4tAQ/+lxnhn/2Rcgz6lZ+ENb45grZrBhuqrq8wmw07FNgpD3eMpqN/tkXFdBG
# DATA Gd0dfQX5gEQ298+jWrmws8AI8Xz82wL8KKGk8e7XQnwR45lWTIS8mfannDYBWAwu+XsTVeUgJYds7q+FwPE5SzCfqr5htvEEBo4d
# DATA +i2LECiJ2FligVCb6HUWcWPz8bR3ik3QobTP/1rLQmxaR7Wh4VNEOizmYTStiHMvuDEt90KqHIRp4lOL/thj9AV9iH/XNsYPp9DU
# DATA Dr4xmiB1YhutluLBW62y+BJE9FabPymlw1F3rMOkjk6GoBdpMKYP5npKMZQsQ0MDJ8KlFNwIKwM8TpXZbfxG/m1y6mKcQMpIPu2x
# DATA Rr3DdF/w90PCvSP6lSImc3ZSpdOCZTHBjnjgUCVAjwkeMupm8Jz7BwBTvYnG9qHGswnoycUjDdJXZQgDHHG/PRBuDlg/K0O9x9p3
# DATA SjpFjNn3xtREEwgNVbkDcm5yXnPn4y/1OOitM3bMPWFWx4I2oNiDakLtrxDdKdUqm9DKN/IKsEUuv4D2Eipsxsp9ckt6/HR+G/Yy
# DATA KWxFA0QVdJby9+a+p6XOf89bibDSC/uCCZILahqzDxIEYo4fZg1QjBeOTe2too5Rnlu7GrklhT7JrH5Rw/akcGhgI53TU9ym6rOq
# DATA zmrZRstYI8Vt3MKMmMVNIvzY8JvXAVhI1VPCObDbLi+7RFMM0ZZZsBXGVDYVYKKLG4XfMQZT8CklyShqlkihuyS5bfnVI+Z8MVGI
# DATA 0OIFF9/5lE7bYr10udKgy2urc48+Xkx2lU1aeFSnMPy0qZHezl/bC800QITnv+WMcNwoO7NzWfwHSmc26h9+1cxdblJ+8B1umRA/
# DATA kyMKDvgxUrOyRhmLV8m3RN1V2Ggbk19XJRFPKCK3uHr/Xqp7Qcha0JE1+tiY6JcURCz7XTtwUPyE4N8dtA/7qCGBpKOLwYogeIlF
# DATA 0FC7aOPOHRduxLEi6TQAKI+ghs55PbLoKejibJz+5VID7hhMGfXXZpnh/kfBgZ2IbacTBoDOjiInmzx81gE8EcxhAKMrGmWHAGE4
# DATA rH+x2QT7diw1gtUPiuU3Fk038MAsojN3rME8UzuCsp9TKUJJHAzT4s0peVI7vfSgBS+75O1es0ALhfX5nOSFNjtjQORhifDF3lIX
# DATA FX3PD8qVJNbFBadWFNG+fdCB4mHGuGPhJhVxub8g0Sjks4X0xcWkn74u5g77IovoyRFyDeFFi18I0sP1xxvj30z8K+aoF3fCF12k
# DATA qpk4IKcbF9mfERnD3/vaIJ23seRWpRQpiCHA1YWr7dwa8h7h5owfHUMQkTKt4imx7f63n1lPf/dTGn0kR4DtCDLo5cjBYla6ZQ+Y
# DATA /Ugwzy1nKweuskVDqyTzRuA5/5EDZG8wmk4czAx0R6hbSwzws+R4V3ecoPDlLHrsKRrGHvoCqoD+3wJ3PW+bFcm6TjIyLLXQDlro
# DATA yBY2x6d3se0qdupCxzRXMg/PLXXAQabFoqIbuBgVcQS5X3OMfaq60pyJcrUuYi0o3TE9vxBJMXqketHu0aVK824xgQUdJaNM9dAy
# DATA M2esgaqnuIdcusWli3oa0hD8wV/O6ZZVtvncQQXA2RGDRReJbc2LziAD//t9Nlwn/iSGqWR2foDJXEgbfKbCcZQWR+lGHCoZGHM1
# DATA 8BtxrxzgSY1pQTQrYSObUZZHuFzPuRaNyrNwi9DJVcVKRSfT8GOE9k0/CEE1nFuQrefsl1AWr/vcr1E0hwjc8SadLpYv0gGtg12w
# DATA DzpR0ovuxty1ctqau2SGeC4gy85tGplRaDLf/5JivxCHljzkxTZZpA8M/W7XYB7D1jvF9FDZmY1CVn/XyLVkkEGW9FUBk9xC+tpq
# DATA iTPGcYTloE6DOe6404xWKKNBgd1TuPIvgj8IIZi/Q/8uzDUVRuiYjuiskvijNKronBjOZjOf2a5SQJyLJ3JDvDeBL6+/7pNDVcZx
# DATA QXISgofkwMVpN6R4TtZZg407Z4uQaSa8XTRZpvTEC123JsGDvEoKyRtlIxDjcQrmkYBIZq/IC9mMm5ixgooS2+hgKN9FJje6EPKh
# DATA g4/vpz/4JjeUW8UmwDvtQOAjpVCYU80Ct/CNy92B2oznMMwB5n/AfCzMlmjlllHpVxGE3EFt0M5oxpUT/bf+YPIFg/dWEdhxgNxp
# DATA 6MM8SSWtB9o4Tq4TIx5BWZmNx/kgmoZHfwVbq06pAC31D0vREay7iYHlq3JMk1hPeiM1w2PANuiNDFerX1c4B7yMl86bJMRgXPJ9
# DATA 4gP1q67ageMUXvL4YQWx1UNA9TzveJ+5UOfjEWesBimbPOYFjomTSsPWIDzr80U5tFTX53KxSzmZSbR6v+4pfFKygtQFDZ2FS8bm
# DATA QIkJUo9lGeFyGwEHLSqZzw0vLal2W7iVWi0cfqsFm7TV4glwQlrIVWFJAMWEUCSAGINIIvUipkOf8X9+/rfq8P6G3MJz/F7mOklj
# DATA c4q+YOoyYGcozFoAvSBsyt5ZNumeblLGQDmI0o9gV2DvK8kPu2f8F2S24D+39/gPxKj4873te7cRhAaflmW41haqZjC/Qm9w1J92
# DATA NAYYJk3I6skAY85x/Mm4+1OC3OB87BCxNu33E2ig9i1PXy159i82mO35LwiwggEEjE99xcWw+DkFAwq6TO71bmaR5z8HrKULrcaf
# DATA /Jf6nzo8h324ENXpqI3OvpU2IAr82tWr+K/6n//v6rUrV8zf+HxtbXXt6p8kq9/FBEzBo1w1/yf/d/7v5ZdfhvOhiB4ZM3WsG8aW
# DATA 6cQrpEvrAUjeuNvvtjOA9aGQyrXaeu3767Wlpf0TcFqVBX82VZx3MjlR5B/h0zgiAkEvew8hj8tJtz/CwIsToAoAzKfeDqcPT5aw
# DATA kJETkv1bO1VCDT3utgGVBw2JEBRq+8j5qpOT9qOu6l0XXKnBbtepqb51xxhv2lE35SHckIAsNRgaY+yRpP0IUfqkezSlSHdAigJG
# DATA kVD7lgA5dt5NE5CFdH/eeE7UXSM7nX5HhMQJSDn6afYfcP7fuPb6mn/+11ev/PH8fxf/S6dZl/nm9MbSkjoI2SQ5T3bGvey0favf
# DATA QzmafiUz9ODHY11K/2yED1eOsExavsHf/vTxRBYDLuNx95AsB2XTwt6t7R3MfLGNWZYQufSvuqUDylqR4cmpa/xr3zsyqwPImeI5
# DATA ddJbTnYROIHz+6zOnpv5BYCDV9U0oYfH0wFBUYy70wxux9J4+LjMOTp0Qrnh4+RP/xT+qXEKEyc4WDaEbt6pKm3VM/BZ98lITdDG
# DATA BD8dAKv0wQeJ8+JNTC93Gzjxcjn4PjtSvH5WU3T1IeI4NHhO9ZMPPnBY7YW+eS1Z06Piosz4ZW6oBs5n2e0U1wQs4VkJv04ab0ar
# DATA wt9lNdOzpaU2hJMnZsaV9PeoByJGiXZXBXNL6Dxdeg1AGffSyl8erFa/364eN8+vz6rm76uz6lXz44p6cf377cOm80T/vbY+e3Wl
# DATA BpnAMRUizD8kYBATB3kBhsc6S9hLpLyCRAspFKbHeu5+kFxZLwNeptoZsG4MZrg1QHlc31N0wajvOurQ9NqQMuSGRo9T+4b2UvFO
# DATA kuW1GxgIS+AyldC01dqjHmZ7zGqA8XR/0PvZVIlzyWO4B+vqeON4Z8mMG19ZSXa72VS1jVlwkjZe2FUUtTTGVEW7JkBzuEfP8BIG
# DATA TIUehsCpHrb7AFQwPOJ79DgZ9x6eTLKaWTbTYbXNXjLnSz8t6xXGyfenkt2gEqQlydFJe/Cw27mhjZDIDaj9MyExREYYk2MrDZVy
# DATA hvTVckLtDTuDakFzphCxg2H6MHu36CHtTVizSqJPbd0eWvhPbTB8XAI3+bXVZDm5cu119d/r167iPQcgOXg06slBrVajA8QRKs7a
# DATA 7AMLNex3kofjthoOiV1KslcjHw0hUwAkqQNUsSlknZ8gqnHHoI/V1NoCS6FrG1J2vTbsnvaRASFDpFVnkYEH6+E+ndBS4xiZDYot
# DATA qP57IeIh5pFWImf2tS6C9u45zPmsgitxzrMnJm82c5aZibW6kmrAcZbOecnUnTemjPdAeAHkow9ROhs7WyJgo9dWi3kXrAnH/eFw
# DATA jASUtkJnA7O3ACIuZlBcw8U0H6ru5FD4t5JzQHBrg3a6DpDH3VmiNpQqGLSkPw4bmpWTWUW4EwIRqqgz3e4/HKoDe3KqRvLuHvhL
# DATA 4B4qILJvD8dbRJai5BYgMAcd1CVKyhs81AfqqN/unWY3JJiv6hY9BUxMtQpkk7dV2KbOTffhOPAAmmoA6igcAaCSqmplOdlIOr3j
# DATA Y8IKRX05YkIqkvO+2vGWrEJqk0yRMTiLegvXkuWVZOZYdLhvauvSX2g4prsc9gK84CuA3yPdbMh7QNyAeL5e5K0kGnXOi6X/hSdH
# DATA kn5N+aGuuhyNOTFyXhzGp2wS0wSXs6jH3NG2tll4Eufc77hbqQPIPtYo/xYmWOpM1dIoIq3Bbdvjh48oeWEDsLD1/NC8UO0ALKbO
# DATA jWJDzt1NGZnJIXGWgEyNyaVLxPO+VaOqfkSaz7dqxO6+VctGfZDrainguSZvvQXpcd5sJG/AGQ9UvoqLHU0gASDsx5LhjRGqpj0a
# DATA raBKnYaYrWjGmj+qjh6m5Rr1ZudhuXQejR9VgxgQVtcebsy6mSd1EdZk0t8KZIyqJ+uVOfXsE7zt3V5f8cZ1RXpaqwBK2uv0u96r
# DATA K/QqqG8GVIkypNPIVeulvG6Va1kXcDN32uO22lIUHUzZ1cswvSmGpR0BTXNbAgoK6XLUblfcQCRqH5uW8kyJ11puVU1jXAwknwO5
# DATA zQ41iuHpAZnp/RUxOsAiAStC5C1xciyHB6Jc4mdFhFjOkzWy792/uXdrd2tnf2v7Xmt/+4eb91r372/ddotD2mgyxFcC+PCC6nY3
# DATA 76suY6VWwVkDjqJEHJc6Rx7uOeni6S1HAopPcUr1AcRjpqhrrUtTmQcQ+uy38AjhyMBGbkK6/0aAOKDB7HeY5s8GSQcB33Gt8N89
# DATA +we0ucWhznx4jhqGPui5e9Kb3EIjdrKmriUxUoa94rEyIX4VHcTwOJVI2qETDlf7kBL2nNstUInthoqWk2c3lr4D/U/Lnv4Xqgou
# DATA 1v+svX7tqq//vbL+xh/1P9+V/ncH+Si79tqLFXMmgJpVnVuUKAL1iSNldTtKAsPEWmzlAUp57ar+BYog/fcwW0JUY/DV6fcOtVkI
# DATA vAR0kXFX/wXmPfO3AbfXTybd0xHId1ThdKyupEOKPNK1gksGXNZLpmrKpcoxy+Qyhd6q6FFMGtzjziJYeho6z/6+d/PO9q0flm2u
# DATA MIDM61CisA6EvXKCGMoWJuyKhC2MAHuALEzvvbQjAmALCtX2Wlt7u5vvlCQ6rQNXq3PyQbKJWPYFaywspVv3frRxZ+s23yoQ9O0C
# DATA uni4joTjoxsCtpjhoc9XcarUBd5VT0vlWRQ/d/WNN8rzemR70roLt9XNzdbO7taPNvY3HZBnvJp4Qm1yjdf95BrGIW7JcdSmlcf/
# DATA Orld8AlvkWhhJ2mCcAnAt+iKgEvRNx+ECzFnETQ6PG3XWuD+x53W25j8aQivUsv+xoclt7u2pO4xhWcxcjmPQP+GQayvXr2OyeAe
# DATA PMBEIbIsBKMNx53SURn0YVfgEf9UXPra+hsUhSW/Ki8yHTsb9zbvEDe1RLnH0fNDppHBQCnuCEgE7elkGHF80JNJQCQ+GgpKlD6Y
# DATA kczrwLNZOl9eZucDHb2HEQvozeBE7M2Ck2ur47m+RGKH+GwpyrNxR8/VvY0fbWzd2bjpHGOet4yCD2WrnD59rzuZcMp00z6/MsmN
# DATA /doM5DWSB4l9ZprTib6ZRJQwUzXimYx7HYymTQfgDlh28KyxDVKI+r1tn3bJyRSA2OFUQ85cf6Z1/2L5INKDjepftKt/BfjM9s9W
# DATA rdpU9Ett1FlKir0LTfq9zf33tnd/mDP5dnsmKQS11ldWdG5wm+MJ8O14i6ITlf4hHdbMZPACAb+/s72LbrcUB22cKaXnkGjf/An5
# DATA ALAf8hxToCHG3XIf9SusS92nqgp9q1rSoI+helNDyU2ut6oMATMwzNeQGSgKWwHnQD2D31o3p39rWDz9+2fTLuX4gB/H4/ZDZD5M
# DATA YXXlmlYRDpZaw5dw+SvasHoZkuMO7KWGHouJaOXdVlT3u/v7O3tc8+7mf7u/tbt5O3VuHaOzHdttXdFVK0q/s7t9cxPImGKzSG+h
# DATA k6EqYWJjOjkZjlkmrSfpTSVQKzKDOEi++Pfexo82Wxs7W3TTKPECHZyjpcxMMPbee4C9Z3YwKaa4Fwfpj6tKenncHne6HfgL3bhS
# DATA dZ5qq+r/1tIb8ZI746Gi1s3EzCpIS57WErY6MmjQHo29fYgrihL6Bvx9i3B6+hC1WzE5zDLSoELoNwlo+F0N/wvlroNWVUnkWjXE
# DATA qjVUrmddo1877gLhmDNHjJWqyCcPFJCbyQO5nqLoqzYl6KLb/Tp1g36QFg4NW7rh2vB9bU/i/UMxHe0j6ADpFUDtCkxeYxVQAqaD
# DATA 97PGQRNeABmmbpdoOPgWLTK6+sNh50xNJnz+WgNfsynrRu+4BE/fvLqMuRrgP+VzZ9JuRPqlK1Y9m1FfaiNIrndzCgrbGvDnJXyu
# DATA hOGZmWZ0F2uglxhlcOXi6u2R4oOponJtMiS9FnJzipmz00W+mx98oDW1+PulRiMdomUZLXVUqGaW1CttXojPolMvhrhkzqxbhXox
# DATA 0zDYyflRX51BvflwP8LYZ0sl3NylcuNNs5m1sbtBy4aUfaU96q2QMXzFGMPLN9TAS9x//VS7ZsIIWDVdjgzAwDXc0M2yATxsNc9U
# DATA Lr5V1WeNjfG4fVbrZfgvR3Zn5be0YZ3/rfG/6lvV+Zfcj6Cecqy7skn1GZQ7WG2+RRrxhXu8kr6GoYXd+7tbt3RwgK6MteuK4JRL
# DATA ZaOyUuvi66uELol8FAXMlwHmfQo4XEY7BaW+IldEQlr+jJ5GNVN4OVQSVQaxvSC5AGUsIV2YbQAhiCXYISZG8XRfasp8tVVj7QZQ
# DATA GfRfQpFBFTjsljgywcoBLMDwpaPoCoUOV7SDFbNE+RJUKGRwG1LCwEdFl+XOxjubra278N+Qn6I03Cz61/a7INi3x2e3dahHicAa
# DATA IJGizvmFOwKHXCUR/HjYVwTaAQfXIUf0qsyhzFolBlFStsPMmJEKFLGb08h90JDsE+lII/cvlnLUqDGWvcQr4aRIuQzjHmD7oy0s
# DATA Unm+LELiv89l85+C9aeCXLfNchfLG4Kby+bqayLKTfcIU51ChFqVMZTRTXrwqGx25gFU2dSIW1Ac/ouskoe3EXjSY8vguDhANkKM
# DATA RAk0amHHJTMQK62UF+s8AzVXq4RBV62OlPSBok6XMeokDhX1Ih8cNG8O8LlaUNxgqZ0EPnLRudC+4sYVXDqNi/yRe+ZP3zk878jC
# DATA rt+4dWtzb6/1tjqxwN5S/jKU04nsgJ7QIoBgmoE84sMtKpK1S3et+l7R424HdOyPMJM6zwlpH28k2Ul7TN4fCeVaUBToTOSHBOon
# DATA HNEp2wxIEEs2i1wcmoezM7lQPOzsrpjv2OFP62JkaeTcqwI44NmSTpsAddlOAcnBlDlZSUdEUTckECl+y+MmOCCN1xCtaDg5AWTp
# DATA nHrc5DEsy1cS/Mjmp5ATU4OaANhbC/kvmYSDeq4cEAnsBWNUEeTGeYpLpSbjfDZbMknOYUB1L8HfQSoEYRQYzpeXNSnWcfRSVuac
# DATA bjorhvkUNA3Ly7R8s4iwLKZO+wa7FRPExHmKDlOq63pDpzB29Rv+mVWSYNtUeM/Yq9KXG9Uz2Wt+36LsS/OPoLovtR7iLoTk3r+3
# DATA d38H1ANG1gw1QZByRIIu6bdE+s1HGO8WU/ZULKat/lRuizBgivKKwNVA3DONFLQ6qCnUxx9xIu0FDsCKjpYHOiT1TOZSEi3qlwcQ
# DATA xqVbtpcVPXc68FLDoz8LTvet7Xtv39m6tR+ZZjm7GKl2ru62CSg6+mqvUD5Zar6uvxHz3p5M2kC9AEYh3BkIGJxy7V4mTzEPuhKe
# DATA Andk+mXYz1lRIJroGDjQlqBmFPTUt1npYNm2CZNcLgen2QwBw724tOMwghAtRB+aTsIgJPglfFPRPoAc+VdfcqmX2ZyU+4V3pqAt
# DATA ai0g1Rvaq2qH166y5QC/O0gp0gGyAnkWBYLCJu9DVJrxB0QTmjm8IvUJ2qzoD/BsN4PqOLfgd+b/z1GdLzwMqNj+u75+9Y2rnv13
# DATA /eof/f+/M/vv3tngSMneAzAWQnAKedq4nseUehvOUFsmaCAXPIsijfwVMnyYFuPJRFh3+Qkn+NPG2OOjwaSvfwA8nfpC/zTRvi/U
# DATA hgwC/2WsxT/c/AkoKPfu32zt3L+pCH3r9vbdja176dLG3t7WO/fubt7bx8gHZEQgy8I4/cvSW3Vy9zhIHkyar5XfCj7HF8uN2vKr
# DATA kH66W7sLFr2jfjvLktt4HOmqsbeOwddW80IEcTAcn4IzElOsXFsfX75SDCfSyFY++jp5M3l9bZ38KtkpC5JZPsgePPjeW688eLK6
# DATA Wn3wZO34wZM3jpspk7DAiie7ntJAW6xa5+vRMyMwjRb2CHoSGiNE3HOuUn5BWwKDfZC5AESUSnL16pWoeeLiA4QvaYSmkhrpoUpp
# DATA rzNop+Y+Kdf6kPWQTdOOdO4EvPOfJajOifq1m0Pgp8D+CK/tRXsPKgHYE9gWWH1fR2tuWjNponF86hH8qwbWoaQ84BIJCbYwn6j9
# DATA Cw1+XlIdUFH3+yUva6o6MatPtDfsax/AX+rcpABVNJ6UWZQYmx4IR8ygdsTPCFs4YLufaon/RKvftbWZflN+a6H2LrHrOTWetlUd
# DATA 1KtrTb2NKU+Snki0XOHu1+/0uvS1qwosy9VVWpZaqoUr+E0ioE2544x/hQe+Uf0LNdha679Xm6+pRyv+s/IyTTtkQ7r4SJmBw11C
# DATA RhHhcKNdakYUNOLwbTJ7IDYuqVkkO6DOpW0QRYAQwJNF+qyko423QWTffzeNHL8X4QbEZxSAVe4NJ28DAot3VMG7hmeiHnNgNU4O
# DATA Zizfqn9R6eIORqvrVzmzt3w7AIgkWI21MB+oLXVx36H19ahgttj6YuKy9qTt+wyJIbyWrJXlYYPiZXeYl9tbvJ5QnzoMf+ZxRHA4
# DATA +qA/JM8U9zhoX5WaCXgGwvp+Osdb7b1dvSlv7W5u7M/bsRWZzzy2v9qv5eyviFta7mYzW+mbrWKgxkZeEmJojt7nNiv8DMbW2vyx
# DATA Gq74fe9moBK9Cd/2Bg+3tr0jmtO/+zu3N/Y3Wzfv7/3E0XTqT8563X6H6R6vtlxb7ZWEUBzgkpSVcDMWOiaZrSkyrNtUFARMTboS
# DATA hOy2hXJSK+VP+73t/dbdjXsb7xjVkdEXFuTOleTaZmcOaLZ95RBu24JTJg65dpEdA/wXpt6NwTXSaiDukyjjQmItSfIoFUxQMWMA
# DATA aa5jLflBA0kHvizDr7VreeyJVxcz6HB5RxgXuqDRUWmtsrZ+3TgquZ5X2GysQdEYjzev6/waO3/9kvtF5zs+t8uq02bViREIXwi2
# DATA AOHqZksW8A3rmtnEydhFSnCGnZXsL5JNWT2V8S8Bw44UEBaDdC4OKl4KgUlFWlLuD3oxYJ3iOby1fXdne89T20YoSyjdRVNHl6Pq
# DATA vgs2b9khWM4DmCzQ1+E15k6RfUm/l3xTgtmcUeT/qOUFR4Rb3LdZ4o1D5WIGRS9bXJiDO5YxG8/BQTPWlOM1y/VEsb/8lg7MD7de
# DATA mBRCAUH3uyBlsqwrsp9L+O0BAWY3PXUvvnMSeOOT0MpDa6qbaOoToR84jBClelac0JX1y9EDzQBZSEamnjyZvIu0pVD1AaV9OmxG
# DATA rYEnt5d5gGI+s4xUE+cfddNWSYOBkWjcRc8ZT6lbdi4wriS/FQ0dxwUPlDwHXiUsJTYUNVsrH6w1HedzjQ13UAfhDzwVX1blXk5f
# DATA FvvoZ9MhsgZUcFVm/ujoxziQEpasaJaVtOu9vvkUyiuGtm66wK7SEK24yuqVVJIVePeDBMXKEtakxUj4IfPvpq+k5YUJiyscypmj
# DATA bq7VVbvNiMJCFwNlFE6qugdRl/aKVj5hRCO+a6yVcfLFXEsnLd5WOplDad42tJ4u2AO7HenMhFdX013fcI9qQ2iF93CuSUKkTtbC
# DATA kfaoCk5w2D8SWHSqSad1vspsfTWyRwZItsUEm2RKSGEsnOpjBtgCei78SlzTbNjScQLaV1RAQ5v1qJuEngcqc6C+aFpPJZlkxbnf
# DATA 9Ve+EnXpgtc6b0XdGGkTUa/BnPPDLuoDWcdd4ywG5aX4vuCMrc72EK1RdRocweRK0ApGQJw4TEFXCxrTktcmbo8aVUH0QFNUDdNI
# DATA dOEwPe1lGfr7OIfpPMXBKhaOB60EFQpdVI+4ZyfdJ7oBnSmQyvc6M30Ord2Bw1YI06OBIQCMpAWSEMsaKDhZacHKqKHQ7MgqOaeb
# DATA wwqMSGbzhRCyWeMChELSTxpEePbFBFILgc5FMnNYiTBXZ90JP0QxSS8BOkmNEPJkV6/BLKZtoW8PwtJNqI46dGDXsbk4x/juxr13
# DATA NmOE3Z4o3Tj1mbIsec/C3eewu6fDDuDKdSz/f2lyWkRKDaPvsLNLeY4xBcTxklyt6Kz+OrqR5nK6FyLSPitcRItj9FjLjjksdX7X
# DATA 82/K/LHURsNRSTXvhwoFXHPU2y+sDy8KzYfkljeZxXwHJKok+I59ClBg7ExPR5lxeesOMnAmamdHvR4pviuY5nkwaazrhLoLuC1y
# DATA A0jMYf4P0zRwUIhdpHgGXnIlCeJeDKMnWGW2/0FjOcuYu/u4g7Ky6SEG5WBtwdrTqfeKwzZTU9Iwhj/+eqloJxk6cqkBcb/hHxOG
# DATA Ay65vDTqn6BTsVUDNy6owtzIL5HEHDaqaZuRnZ3vfIlfl17kYjGZr7RCUWf2Zv2gkiFjqTCqMDAwk6Nz/NVSGW5zpyNUj6u5o2ff
# DATA TKXL9VLWAlARN1aHbwDsCGVqyEgjlONYY/NPnbYHvWPgQjgzlfUwPHC6F002pRMJ4UOb5ppTWWFKPqkHid5bnh+vTWDlcWKiorJk
# DATA mRZqZBYw7NjbirnmuoPpKYKdlvSmsVPX9DJnTdAFWig+Qu26baBkL91yvKEIyyq2T8wEiCsL+0iMO35AL8KLiEZz5jOnjfjOKsX3
# DATA BAN2c+2BRmGpuHY7mfO/5KXS2dJcvaU2YrSz7ib+CXGAwRrq3TEGN/RM8c1c50WXilCZBOWq5/EK3swXX/Roy50OSNW/dPGLPTa3
# DATA Cy+ONa4KomrEgGVHXvivhvS9gP/fae8h4/u9UBfAYv+/K2trV675+C9r66t/9P/7Lv73yksr02y8ctgbrEDQxOhscjIcXIEose0R
# DATA ZF5PpiO1JzpdCB1tDyxcZoBL6kBHAhan5xXI7nTt8UP0t1syXoGjM/LGA00GnFztiad/UyDvX4E0+I3dAAP4GMhEoJFkwMtvvl+g
# DATA 9CJcunTCqSgUTadLU6puNBvjT5Su3z5UZC9EQrjFAMhWlXYHSzoxX9JqSxUZq3GNApa0VKjTr9TAK1stZEt9SkALGrAM3i5cjfjU
# DATA ysJzPtWhEvbTwJYsddAc3y+G2ICgfweM5KQ9RjySdYNHgk8kJIl6AHeiTTOmRVo9ZFfCzbcHGPQGmdnGSWrDw/Ftu/PxKLjtcn7j
# DATA 2uC04CKTREpWJ4bTYLtFxZ16YxNmA5D6RZOpTdj0vGBWtN3nSCjTGkKtxl1qmORcPNgG/1uJxdwZ43yD1XEYTHVfncwGnEIpwZQ1
# DATA To4Op2n3e4pNyuxB84POMo6oxMDLS4Ol0GMTS6vDKb7RcdZaWEwchLpq7T9KSYR0tIOVdZZLejSMGEKD18ZOiIXySty+twcgK6JI
# DATA iIdThMVSmT+yd9kplrMFWijZC9AH+qpppH+tWqZUauS07jhFO1LNi3BBzgU9OfdAT2bfLejJAo6E9Kxku15xnZV5U1WsqzSYBK9e
# DATA veINuGH9rnGqrq+W860nJhNRDrWg9aM8dZMhZRYu4X/FlgKF2SM1A0Co3dNa4TDuYtycSvQ9tkI953CHhruR3CMSC/jETWlIpw6a
# DATA yLFUW+MQR1w0knOnPdU5jE6jc83BbjrMloMPVItv727f229t3rutn7GJ9xH2E9Kyz/weDbjJoE/GRgYsXUtECaL94fJkcMkLOsy6
# DATA PN+XoKiANq84MwzKLzn9pGZeSW4jydCYaBn7frWPxsMsSzBDgQn2NiFskyECnh+hbyXmXuTKfgow/PBKf8KxtoRBoJ5TEMxhFxhf
# DATA 8uXsED56+/Sw93A6nGYcl8tRtBl7MsNXWkMpJwMC5PEFlhfPGrwfKeA9LhwzJH9JxOKXRD0XXrO8/2H/cDcdkBODf7FynLG+VMlm
# DATA YjsVWbeYlcUEHtsDr/eymd2Cg3UcRyVwXa/NKJiG+iNh6hOPCQ3U3/aUqeUyyFemESBdAJr1KB+7K0q6zcF0xsiepRpOPQsoZSZI
# DATA ZYNs0oT334I0AI7fvTot0/7EKgGzLgErqm5aI7VFryMzGrciE+QBLugCjM0WZhB0uM4/QzBtU9Xw8QANflhlbcyF6uRSs9qkPI4n
# DATA R+Nab7jSH07Aj3rFhgsHcDCOk4uYBNrK0NaclR13FQPSYznK7dQKdaq6Zjx/6u5YUJNmPjcsQthJJ+Q5fD2bv/ug8sXvT3Qbsz98
# DATA PbNd4rn7ftI9BQe1mAzrRZCXAvABjUeg5UbzwATOUyA5tBEah/UbWEhogacXNrDvZgiq004HL0XvlMHm12pVqM3xeGBvDCqF0cyN
# DATA vqI/nTY2XNcjKuh+2XiBE1QIBBsrthvyWCI30hC4G+qnfybVo9LBsvioSYawBsWOH7VHkEWsNZxORlP9cEK4U42166uGaPI4aVig
# DATA CLUTJFKHcow/sb+OTAFNC1sb7GGdgylJRyhFMkYm/DlF/peBULLJkH4iHIoGQ0GIlxnYXRg6RXibUuIZ9P3CXlP2RYx3EkA83XZG
# DATA wP0lN+FRCvndpkcniZAYIOHj8w+ffQo4Scmzr59//PwjzBIJSSU/ff4J5HxMnn2qM0amHtQ8uNC/P1CkIjnut3HEjOD0EWbqZa6D
# DATA P9bQTwjM9Bk2+2/PvgD4JmrFSzQZtgWZQsD9ZgiwJ4Net4MNCnio5Nlv1fd/wPSV/xNAzMM6brUHDDEKIEaax+GOdtrdUzSPpfwA
# DATA 4awk/tTnsTqZRrTZ1UmoevD732Fq4w8xsebHgHalZiaez1O9iEx02VtZsxvRLgubkTIU0v4nQwbtALUt6ZURh3sDvYn0I9hoDMcl
# DATA wbf0BHyR19VfJnLrPHua+jlAtUARZpEtHafP/pEyPKvp+OzZU91a6dwcuVmZt8tvEeELOva3mAn6KQDjV6hXnyXnwfGd1eEhjH9W
# DATA S2SaaZ1x/lP1z6f4MSCDQULT5x+7zrj2cCliYakUOokAwSkRRg+qWKRrVhALEkLKeM5asaAQMPSGGjysz5ZrD45OXImRZxtWtwTT
# DATA +xSzwkLm7H+dj46Ws9EdFdqB7y8zcrqk455d6kh6MAxaw7lwA0jKTTkLpqjWoenQRnhRKjumukC95g7/fzlpbf/dUKBvNBG8Owyk
# DATA VSXRw2E0Kzr3VVbhRPWe3q3okRJRid00pEC3elh13UEWbpwOBHrS00EQl2N0ZT1Iq8f8JbwrN5saK4StFxSn1CJrIENjobKQH5GB
# DATA t0VeiCbLNec6jd3PqrF+tztqEDI3/GlRrOQhsYaHWJYFiKSzv5Zygapt7/kgEa/FYUqy8rvagmfjlcIQLThhwWFF7onLmhWzJc2j
# DATA usPx+Xu8MHgKU6c0QuJSXsoLsnG5JdowDIGWLtOW1MxHtToYVlE1MMJ0BeYZQIQhHcJ8rvT4GFwT8c5iDxFYYWC7fGOFx8Yteb55
# DATA jmu2F3qDsk7umf17dVJ/w4eTLkn3tEYSmizCsCxJTHykonabl2uU6wBuUxcNfx7EvOMVCxa7WkftePiDvdrKvso8AqDGfzadogec
# DATA Sb6pRSrnLbr6pYfTXh+YH+vuZ7++IByYq8HzAcHmQ7TZhklLrdv0Ku47SnuouTesGbFOq7CrkG1M1R+RAmdLjvsWLqSgUeXQcwvh
# DATA LUE3rc2mmHlQW05r08kRLvkxPCml3/vJ906/19n/3rvfu/u9vb8g37ao19dB/Tormi7gmoWID4n2CAOHLIpCxbNG88guFTR7xGCI
# DATA INbonFQSB1q/rg8hRCXLYM56YrbabCn0CMHOVUwPyktFjmTUb9r62plssS+1ucL9ln4xvdNaG2emzFMxW24bInmePHyP21lrTPCc
# DATA qkKrAtO4niJXghHMWxiq4BFZkuKq1TYJaNXqz6Y9TJ9r5lsTSz+oSdZrCZ/tQISwO4iZVnKUNQniLDUq7ngdhNFc2FIOyGDrxOAR
# DATA gYhZn3KRRML237ixdyoi5YHAhdVMbnBK2dwv8S1Za9Cqe87LsjMScjbEypTd8dAyc/wiczaM60Zlq82znkTwYWMmEMHq6xrrS2F6
# DATA uZqDPhwZFCkrDfgwT5zQgNTzdSn2JidDCE1tfa7fqBivd3BNJRGQkGAvz2GVA11RDiMc0ZJZPtdm4WzOZYz0AdZTE8wDjKA3aXGn
# DATA NYkU+4amKGSNy7GVlfh83ryh5UCVehTlAysu14vdKAdSlKnolWRvMhyNEIbsoYZ6zehRLdlINHXATFW9TPWZ07ei6UYJuwmiwmp/
# DATA JTWDT9DGevtmLVhb6rRRaSFj2elqUql+aCYlgvO7rHZGtUMRupJqoSLzgD5HlxaQkEIqK9Wc4vPQsbOFyhCIqildWy3HI6IjZN8M
# DATA 7ZKE32nihdJ6/06hGTsP45tOuu0+hkcXXwPvYjH5BIpMs7i/8GJXClnquAOgDyW6ldKTM19hn1d/nn0EPaLJpgKAbPl0OaDIloPF
# DATA OpCqzveaZenkn4zqEuQMVl4iej1oEb4C7Rmpl75mIea3qDtbKGHjHJ1EGjcGHqqj+35smfTaN9TZHOhZx4i3wvXTK0867I4SjEgb
# DATA rehQJ2/RvEn69Vx5zYL/P/9bUOYlUvX47HfPP0me/SsIdfiIwf6jM4AahtL6InDmEd3Qx6iW/f2zr0EdCJrZL0En+zXqoz/jAfzq
# DATA QiuTI/ovQL7jd3Cr3z6DFBmk/XjxSgumHMvLmnm3V/TbHBkSG9LM5ZhC1kGqlfBvx/ElxxFfV8FYr+bapUt28SvVwt66UTEeP/8f
# DATA eGOROz1p4kB2KxlMq3GGqXm0N3BtY/xwCuRsB9+UtBVRjb3Raqlro9Uqiy/Bhtdq8yel1KjRCUcf9A0N2CbZ0ZCR9jPFrmiTFCoE
# DATA NR9BasVuv0NqRIqLIvaJ7Z7wi8xqZMRi1RKByaC9SxuykcSmJoKoCjIA/NRJV9C0i2wTGsAww8l03JcqtejwqiiZYy8LJqFaxbgU
# DATA CK87G3UbJiMXWuwa+hv8B77KrNgGv2rC+qcoqZm7PJ6ZvsFpqUj/A4cCYCHyqlK3ucfd4UthXnYdE3BHazkl3kdeU8GH09L7dAg/
# DATA peVyeCl8jnNmIhBZG78KDq7i9Q/Q95Wr990zgovTt4DRRfkVWoAU2b8QnY1qg2lAltqYgrmqYOCMqPcHdljNoqXl7IaSpjm3jdar
# DATA y8JUNQl0+DdLcvi3o2HHJ0aWwF9G12606Hb3tNQpAfu5WrQWGhZaLdwBrRYQlVYrjfh2ErnJdUM0qS9+2D2bn/gC9PRdD151DH48
# DATA 6bN/wav8c7q9F7S4OGY+MNzeSCI2SdbpVsjyyEmAMG813OhfP/8VNAKVkcUSLvl/h9qh/VqiduJT7g1kHsKmP8VvP0JTGfJwiidA
# DATA lq6SqM8+okxGoIz+G5GUG3v2BexdNBZhmwDxCtJmA+IfyCovtuIZ5Rwqrf2fESH1f/b/HJU/ytEvHP59TvzXG2tX19/w8d/Xr7z+
# DATA x/iv/9j4r10L846JOrpjQuAg7X4Q/5XdUHenouWHvQmk4tJODsyMZovFgIWo8Tp7Yov9E+JI8ZePCMPsi//p48MuZEbGPsbjOi0W
# DATA v1W9mcRuFeG8J5k6ZuB7AFHRm5yRybbugDy7Ue2l9MFqWvvpEFzmIV4aJKv3tRc7+bBLPWcqXIi0pbVctlhGTmT8QX39atMgSR8N
# DATA x4CZaoF/MOzc+rBSIjcBgGAQVQP7UpZqfpg+KoQclTlgGMlgd/Odrb393Z+kLqKTxHKieh/2h4eldFmjuTq+yNoHJNLwRRoXPgIO
# DATA 5+iGi+v2IL0kqpkiC7xIotx3oP1b27u3wxTMUFMh+KxZs9D1khzkI0snwHCXzDjgkXWe0W715nlkQqO8tYgBCVF25Z7ZIe2cbmg+
# DATA zG4w0mgOcXL+fdx+1K1GLaAE0AEFAVqfj1i0g/cVQYLMQE20bMOBbw8IoQtkq9kiY7QSxDcaaLFswtkgBr2fIWiUQHfFHQyu/1CZ
# DATA ED2wqMxU5G5cMpw4uJX0SRy4Uu7p/e1tAKz8CW7qPdcRiurQkbosH7uoY3hptjtV9Cq3TtXD44S8RskQcYrGCqbXOvBESaDdJ+0j
# DATA vWN1mjoSfzwI8KKDYDZ9y3MnQ3Ikn8doGwcWzkTb+afEhQcVpSO7wzY/F7Q6rzuOdKdpA1sR4CyJ6p0TFTQrnQgq4sCl5VlAv/Dj
# DATA aDyGsEL0OpkwpzhWjhyTio54KLshCQO1kzNKtnFNBzBHMte3q8cQJny+tl65dnWWxl0RoaZFSfit7Xv7G1v3NncBpXPz3v62e5GY
# DATA jXwRq84ydICc9tX0kOLQahzUfAwfE5qbXYCVHIqH4Z+94UphwZjC3kSHzGniIkEkszAOFvkNJFYO1RIRFjlmF3s7XiA8JhIIA375
# DATA NKFCp6MjB8RGtQoysRQLRfVEAYFElTXIZqc2QxiJdGCqa8qoTc+SEdHQaMVMeQFoZznv3KPwPiJnMhMinsbw46JjZLfFHB/npRiA
# DATA DfqUsFsC/MOMfTaLQgnaQxuxQcRNUTJJiheNHEGuDrOmFOPvcDI8ddmYvDPRUWr80QOygCxjOzzUnPjEqFs1zVTOOILkobkW1eBq
# DATA MyAOmFkHoEuyoqHnstfI43pQZV7bw6yms5+mA6mVDkEHMRMLc97tSalchI64aJKUUixLiowupZkhb3t4HJRfW11dLZeLAROLJ2j7
# DATA PXWFxLMjx/x9F8hGXF4Q1p2I3YHLBzYd50IOzFUMAbqAzXwug6pYmpseeSF9cYyHYcxbNFow21hh4Bwk3i3LUzphmSH4/ChIpp7D
# DATA IKwjdwDFCwVYR5KzCcBYfpQyNl5NWN+SjLvT5hOMPfbGUg8CBD3WubjOuRniAWOepN/N3c3baT7EyiIIK37Q3iKztre5+6OtWzox
# DATA /StIkrNE0UDk16sUxKpZdk7+Cy57agqSw/HwcYa37mg6yWpLwYVwEPEBW47dEs0g80XsapifROsSugefOOYcdz4J8EDD+zOWVIuy
# DATA wfKRCEFh8uKNbJBIzY5kQRAemxzggM8T9pQvG/2bosvkAWBYw6WQUueFQIlJbnjpbXwnBYjvpx9NKb1yXzEDVdGO3Lh7c+ud+9v3
# DATA 92hJ9jd239ncTy+WzkCM3eY0WNU++wHt8mDBEeObqtDZjENnR6PCsOwvP0Jud2aUe1NgD4ZjvTEG09NDg4eFojbSkYRjuDlcHFq/
# DATA YSKgNHjZqDuGkI8Mwx8xOBoPJfoDgn+FkbdBOYqJwYwlG3vAbfNczpf3YmLetyziXUa8c0SYFyHbiWMVCESiMSbyC7nWwQzJ+HGZ
# DATA IXFyNBKlYNUOIbXH4KFFGNpRy5eWCTsD880CVDIVgk7xnxmjHDkSBSbANgVAbW07XYCjAS1KtBIGQm1qbJLe8XEXnSS3dmztp+C6
# DATA CrgiSRv7WUvu4Q2hpBnYx+2BsKxAOpMuICtEiQSk28s/31bSC4733AB+odPNb2CepDUieAiXVWMqwnekx3SIl2iMapiSIetgi8ke
# DATA ik9zaRhXcG7MM4ysZWwz3uGztQZOY4jPH7rwCZriCD9zY2f16S/PFxZnCyWsR0bdpHq6u7V3d2P/lpRtXkn2FZ00CwIHjLSTmq7q
# DATA 5YP76lEXSe84O+mNAFxnQJGZCRmd1KwTVEbAEsduCzmr0TvDFojdHAuGJYf6xEgyOvBIaYNndGsyxN0itsK83LvBobgEKMpSDuSI
# DATA UQax9qfmq4NMnrp49ry83HsNUjCLJ8OxJ2SZvrx0QeQVvyqPz7bgZfl4KDkmkXK5iNZFGVEmmHp3lyER0iXMArTzIuiA8zD8+KEb
# DATA ERiCsEsATNrB9Fj62dKjEv1DiVyoVzKtk+vdtYghFKILkU4DxDWZKaVR5Ruwe3YUms3TGnxhc5R3lOZEwrUsCljw5Tg/UI0xMaiV
# DATA gmN7nCzCm/lYrQtyY6556RLxEhQPR9PYJ1FKWqN8PCdtGg8v11DoCYT0IKOK5mbheXCEQod9MggKm50QunL6QJ/EGrZsmNbqVNCo
# DATA GTFCzrvytXlLaMnD7I8mqMXZrC6yENcTDZMTHG7w0dTkG50Xo+Jlc+XHoNrSSZrc0fOdE+3R/JtnriJsIfWXHWXFdCidDtqP2r1+
# DATA +5DC1dKlOAjTixEnK3kKzZT6hXkeqIMpu7mrR4fDYV8a1o1IUlAf+YHXaZwHdSXgNT3DO9Zqu2lfFVVrFZe5234WwXMRydbPOLjO
# DATA 4EGt6+gwCHvh9EB4RZwOFb0bDnpHmECMy1N08QlgbwSFfmCqiMX7xo/LhY+K66DgSoeeS8JuF8MS7PvwwJQttzG2pWEjuTFAwfcF
# DATA JxNq8+K+oih+OUNy6gn74Z77gm64MVBF5NjCluigokL16sZt0BhoDTbeqo4C2zjmW5219dW3zB1GjEgksK54pKlZf6jE6cX11ds7
# DATA m7sb+1vb91y19WJ6dhs34/RY9zanR+T6XcSZQPyMy5x4HEnTbRDDGag9HWODjWIFkHYT/lpbXTWxO0fD/nAcqbZcLi9FtlxRX00v
# DATA OOzHxAlF+qgXTOt8yiGrFc7mSw1eccloaaqkd5XxFpG3tFD1TZTEQpo+0ODp1TU4LGjRmoAPDQBB9CaqHKsDIagXAPu6I9D4YJIV
# DATA reybxx/8p4WrcVFqLNxKDIBGGlUiIpcuPNfOwmYO0Bbsbd17RyPNoObe6PvkVmR11zY6YILlqtPug5GI2U/IFoHgF7hO7I+T1RKt
# DATA 1Z2ctCdCrwBLzzWieyvsAlJJPARVGOoZJo+HVb0hbPIJbWtpa9xe3BI1huDodM4QVSpXVwCy0i1djFgV1asWBYs3AK9DvUs1v0or
# DATA 4AyJfPDc5PExFoCum65JxpchPT/3prWiW3Q9CeBbM5iIH6TzzqoC6Nh4bJMUqXW2SIOEZIRQJRom5w8GdJoxkRDPSSBP1q+srq0+
# DATA GMxkgrTToRJKRRLu7ICHRXkR00dq+586c4cHEhT3jKUs7KGPdJpMdFOnCiAGjm9E0LGmuVjJXJ7D+fALglfgCXNrxe3O9a50J0cr
# DATA WG7FbhBS0cF2oCGWJZqt2TX2bzDd07DcJbRITegFrWhXQ2csgsb1ulhya2rUS/5CNlld5JTGk66Zcy5gYwjBjtG26PeaMOj2KF81
# DATA bbMu1JC1KDPbrOwBevOXjjCj821WrPZTDyCSaCyHgr27sde6vbmzee/25r19Tc+0NmcBdKu8ZHqURk+4O1bjwEzxhHoXgFUysuoF
# DATA EJN8ZKSmda/VCUx5wutC+7vJ1yjAmU/bfY4zpuscUDYU9R4qmVMJcDcYukXfkomaIbXmoi4HbDRhDiI5BVB1Uq5kIAYoQt4eJGIS
# DATA 8R62SmNDJ6DXTZQAj03Y+YGATJbrALMO1TRzq9EMDdSSDobpxcGgbIBk8WeLl5+PHJX7pYsd5Qav072b60u8mBrwEk7JhHze7reo
# DATA A74rsehWmSw45rfx2PIgn02NJkIgxzfZ+iUXVWfl1XPYFXXpVMznzHoTQ4lZOXZ+6GBRVuOOg8D1Hw8WlLtFFgYPEskiIe2BF5VV
# DATA EnGg8fBoD2Eo53QUbGWNQIT5TVKTbKzb4sBhHwPBrIMBzqew5U570g02YbQ7QSiNR3ctdATXGhjjgkWParHD6Wf5eDm4Ci9YDyFt
# DATA o/iAvu5hhXxzL7DjJTJ8ZPeXFzI87m7e3VayO2oVbm3fe3tr9+6mFzXkHm63Vn3e3Tva/aLsJ+GN8kH1iNcuJtYIQnyazlE2/Ku2
# DATA bXJGjsLYGb9H5mNkv7UhXD/lNB8Puzl9JOP6gk2JzlnSUM6HUhHlNckpF2LAetMXIMLkHI2ok69JcOMwLQC/4clTqeKLx23zoJzr
# DATA EMw1RrZS2HdItAO8BG5sucPFazAIhUxuMzrroPco2syxXKX6qqok3l72bHj2jqwIqiQjbijKy89mzAgzM8eAHUGoAXQqIqBxaj4P
# DATA uSZ6louT7uZPxZzz7fMXF2jFmUevHh9qKYc1iTQhSkXT2Fphxg27YLiqwOAlF8V+sEACY4bGRKuDZ6PO97kq5yR5n6PYujjIUKGj
# DATA uQQgKgYfgpn0AYdk4g67641FBHSJnQWdTvXVLyhlPUAoN4Sxnpj8hTKmMy+KyHLEC3LjrteUz5ebLfoNQ5cVa/WoR1mrIqx62W2H
# DATA FU0SmY+n3lQDFJH/joUGmlhdp4xUWlh+XbqGErC1hMLLW8sKU2qrUN5pZxk7juoNwbgGKPAcqd8w0+o36nMQ+uBIGwcytQw28ZdR
# DATA Jxf4J+vlyffIWcgvo3zRhfVdszUwONtc5UIveCo0cm4iXZlVtwGS0EZj63rRcWzwyO4T54rhN848wDOKioHglKz3V93kzeTa669f
# DATA uXYRb/TNez8SvJB1SgVPjh4oovulcfqXEazERkmEBlSbrz2oFf8uv0rYsEX6OoBpq90NQj2Nw2bDcdiUy+Q5aLqXF4G7077W0OW3
# DATA 7u/tt/bu39y7tbu1A0YxdbTv723y2EAdQlUrwvFgYCx6GstJmsoYxilMhUA3s0WbcJId/Bc3qCygBKQJjwPcRy0gRdbwOAK1P8Nh
# DATA KAx1Ig6db9/ngee7QF4WmlrvOr/9SNFCGGxadVuYx13OB4G+kIsKkgkeITnS0eOKPxTTTYEizfvpMrjbebWX5TK3+MCAe8OCo4o6
# DATA Bw7HDwHtbmB95glYrSawBOWt76SSftB5rfRW/UFN/Vs+X69cQR81t3906y7wnS7vEO7JdKSI+Wl7VML58OrWDqk1AHFR1NsrHSu1
# DATA kPLg9vZ7997Z3bi92bp5Z/vWD43iwAWCJ26XZx5tKovB+C6i4/9PpNd3MyGE9htf7+/Tptm3oem+vOb6wjryIk33t4T5/gpsSUrY
# DATA kHXVKqo/+mc3kBEUIQbaQz7rQswmvR32+9BeQkbG2tJ/eT1wTMv94uwLL95icEmLxYuxLzjq/xeuDw85tOXl0nnqq8c17E8eg+Fm
# DATA /QSr7DxV+uKA/5dXul9CoVioIv/WoZCj3lDzsPulN9TFFNcXV4h/Ez3twtrKEJi8QO8W+lKHmkNHUe6+K9K8c+VGoy6SVi/yeZ6V
# DATA 4EITnmNbEABY30Brfjn9sQZb51a8rDCF0OUvQjF8WVjzPyqVC5TK3zXmey6hk5DvR5wL1VUteIKUDfrRu+IRs1mk4ZM56GKaCva7
# DATA 1mZhXz1R8psr28Aj4W8aUxqGEh9GgRvlCPnCNcgaPXxy1kg1okE6H7JgQZwCDkiPBaMvvSiZfKGpj+VudfEjFgg3XCi1a470t7W7
# DATA eQtC19F4vHl3Z/8nNoCqp+OCL6DEdNSxhnXTseRiMIqvR9gcq6nmdr5Bn1FJCt56xjnebB3jfLeYD/zu9o9FpbQlRVyrDlKMRwy6
# DATA fWlYd1Y9Ur++XNH87sYWKBv/2/0tB4XlIqB4pJjr9SckDGEOxYaqoMYIcFq65FVEdaZeUR3gh6p0sUSkAYiIWuRgit3pZy+6F4Ur
# DATA p8Ou1cr9udodrc0fb+3t76XBUXTyo+WrtjhNmtRr9Y6d4Ye7XLr6bVhn+nGXaWLSHh+d9B51WXzlujhh8eCoe0Pn8BJhva/8/+19
# DATA 63Mb15XnftZf0ZbH1YAIgCBFSQ4cjEKRsMwxRXJJyo4HRFAg0CQRgQAGDUiiKW7FcbI7qaQyNan9tFWb1Oxu7WfHiR0/Eu+/QP1H
# DATA e8/jPvt2A6Qem80QiUWgH/d57rnnnsfvBJM+RkxHusYu4Fy2+uyAHYFulqAu90ew7LV3H9eXpndRDbugb6VR9EyKmARbyI6Odq4A
# DATA 2zNjxj3FXBZSxw1Rx31CDtq8PKdPLC8Q/Xx21wuEw9McPDJGQr/cPhIv5vA9pbSW+hKDr6RkjhVtHfZa7cibKrB6NB4PK/ManbFy
# DATA s0wxLr6HYZrlMiiNaKWF81JxZ8tgSdNUwWy3hURxagfuGWFJFXCpEDQfFzmpHLqeCDEVdSSQZtS0A6uq8g0nzfUQAUHE8wfhwuKd
# DATA Uln8b6FyClfP0Dc+dF/g9LEVaNsF88a6JQ0ODymi8TTsjLqY0YVsHkWp6BkMpZLwNDxuPS2CzQ0eWigfk6LxaZH7G94Mz9wKKNis
# DATA fRS1H2EJYzF20NVw5cEqSpeC6pCn4r8HEWiar/O868GAUZhH242QleepzOv5kuA+/dyo+vcyzhSzSoxKg0d3y5WFfL7URsV1Lu88
# DATA IW5xyLQoUEg00PRbyOQ5olFfELwNuJS4sLBIUWijcXMYjboDcKEJF8ux6HLa5gojrhMB16dH9MPRjr7aBq9TGd2a8B6gaUnOM4XF
# DATA 6qbxduC2jS9LL2mOvVbZhyy1CZmzrDdO1RuiFWfqLWgS4H3CZGlHI+4CF6Cb5soWaRpZayHpgAopZl8u4CSf6KBhr5MhJxYToIuV
# DATA RSGdDLv9KJyBH6gc0jAw9zdXa/ce3oeHj8XIdeHINm4Pq+UQB1CygvDtcuVt5HVLSzcr4j/j6/ykM0QCllEwPlajRwj9QCq+aJTK
# DATA aKDEySKEvlXm4V99jQalMs96XstjlYZLNoEGSZckKcIsB6+dTWPHJEcVpRwlzgmu+v7VuNw4jMv2KawggEIuSSROYLbr+ZucF0/3
# DATA 8laYOn05ewFojlQvIFOZlqkHTdXrz6A87UxXJshzma3W9OqgZrZ5nbnRDIQmaMNI/T/KNMfSqZlerqCFMifbG91hKb8IMKwqd5za
# DATA k5WDFB5BBDFwPDieEIschYacaRJHRWAq+heVRDKPG8QstzhfEHYjM7cc57LD1HJbqNoaRYJy7CBq02s2F6Jwjuhfqdk+rFGxh0B3
# DATA UnZP5dnT8A64AaSk2MvPlFVPuw9eKk8ezo0bGY7+K53J8TDOSVgWSnEGSCogiMaCKJqtuN3tMtJrdqI7d+Iz6nMhNVW9nGXNUIZQ
# DATA ejU+uV6iVQbtZTTIQHF02wIXL1+xJnMzrNzvFzjjKJhZ61DGz26HXKJu76Vi8WK1qkR3BdKQuU0xPMyUnsEYSDiOhniY8OThYwkK
# DATA Hgl15RR9augss7srOVtKDkBzYkXNmMs50RBvyr/sajUXrTjCCeiVs6s2xtTSicJAon7THeSpTbHYdgLaWDm+pTQrn75OTh9FJ+zH
# DATA gZEGVjyEl33mzy6xdjTDTcJZJJTGyV6o4ZT643q5kV2hwdTTBH+D3KU348uYLb2Hul3VWBNp8+RzlJO4J9kkp5FQpuerhDmG/GMT
# DATA hLvKUSqy0s7a/d3a9oNCoH+/93DLzFtE1+lPjgooBL3W8X6nFdxoVswEjPnXnxhTnBZizHDjgmCGpMtZXlmp7ew0311eW6+tgqx3
# DATA /jszJ7bOo/3N+bfPf81pxCE/9fk3cOczzEL5rZ1d+/xrSk6OiS9/l8ik+d7u7tZOUbz6R0jV+fyTQiAexzSazz8VRXLi7ee/KgT8
# DATA 2ieiwl87tX1FdUHezs+MhObwY1rST382Tmz+V+d/0qk1n/+y5B5T0HO3+a4Yq+YDcO69B4rjtQ+Wd2s4dP9L1Pr1+bfB8tZa0WoT
# DATA dFC0+0vMuc4pPP8CI4ApP78UrYGEonjiwM5hbtqfynSf1Mny7XJZNP1/qNztPOL4+zPMYfqXRIOlYUI3HBv6P/GVL8WIwIRg2vhf
# DATA irnl5LjUvs+hVTJj/M/Sekbp5imXLuTU5Vb9Hvv7hfi6cDt4v3svtWFKo+hrlyIRZ/J/L778Cdr5KSRoL+BdrP5bIMyv5O/PeBiR
# DATA ACsB6Lniyjw7GEVPW8fDHrr+JBqHFMpNU1YUaN9/pRpEqwSp/gGIx24ZVvaFGM1PseJPxMNYlpg3fvVbnq5vn/8Kk75+7dK1oNH/
# DATA gz351fmfRDFf40i0JuOB2cozx6KxcwJZ42rAZeSCR1cKOA8jQ4AT4/lvRcmYj/b5f54txXwyPW7GshZf/zU4/1LMyU+Qtr/FmaBs
# DATA uD8T9PQHvEN1//odTKN7/g1Or8rK/Ln48zk0Ae6Ke4Iofwoeqf9+EteOe68g4euF8r8uLi4t3Lbzv5bvLCzevsr/+jo+169fX4lG
# DATA Y4pvigJ2AMCkomg6NQxLdL6PngTbUsstnSjIzzg7xSsURIfrF0/ampmmNToegnh4jQpkWVMWSEehgp0elS7GhQAFUtYigft9HPdy
# DATA N0CuKyByWJWMrZDqHcRuZnzV9KzvWzUhxwE3E3zsq+c/Yw4G7I/5D8s4sAEjM/4OHhS7DYlBllz0FeUB/wlsQMjevsHt8rPQhXs1
# DATA xDXR+Vw95J6Ajw/0BfNwDSfjKnQJ8rwOx9CbwWQMF0mbr6AibxkmZQTnJMUbJGbNMHI7I+SBpyxxOl92FNIU2By2uqPc0SAec4ys
# DATA vlUgRH5z6uJqqHxtyLNBvskKTfE2+H10H5OLPZ41jCLzfNoWBRswtCiOW6/a8Q/gINJGECKx2w0JDQR/h3v9vdFeOZxq5z3/jRIm
# DATA gEh425Mym9imAxSQQCADEZVFMrGfC2r5hZj/nwMxgND2Ob4iqCSZe3XoZH9MxtUtlBeXghv4Z2qD/y1Je7zdMgWrxsO2Lhsv+laU
# DATA ohxKR1+Z4prYx/8ZBLbgQfeeyp8DGTTRyyCIBy47gqmP/mkCpmdwvAT3tEnMQHASGhD0j0BDJUUATSJ0Mcf4DTykxFU6We6fQK66
# DATA vJpo6yp5gzMfCJ/eKn8Ptd39AdgQ4RvaPaM+6jjfvr2ExmtkFKpa2atNUcrOzrp0146DDqaBQKCwbowROGCHHzMY7TtimcApX0xk
# DATA /+NoNJBQwTAI6nlasSoLxH7YGUQxBQ2ayyaUTkZTewJrR/zSi8/uS3bItu+T5JReMgIp7I/AFoGKHHn3D7AWgLbolPRZtlvUyyhf
# DATA 8QEYB1zlnr0iZ3EhPWYYE2Ddk1iZFgd5qXP14vN0gbmyz5VwtgCpmc5ucHz8HHYpY0QFNxBXPsNjxWcJeX8GTvlaWsFZGkiWiHtE
# DATA AiA+gDOkJT/wb9oiP5YxHm8GME9i4odo4Q32B+OjYHtnGRdsbWV1Z/kdsUEx7vwxuN/g3eNBZ9LrYiC6wa6Gk/1etw0wgQkiELcE
# DATA G7PowcdvmJl5ShrK18UtSU/DFuCHkz0mjiuyTMkvtTOf0bg3qk4lmavyd4nzvd43YDsQ0/CdkH1+isIOnGLFNzrReoWe559KHyfI
# DATA NOodKL1a0LrVobA/Z6xKnYgyzLv5AURZJXwMJrk5HjRj8WC/E+ewQhm6WKWMGwsNiHKUhFHqD57kJG2UJuN2vgS/RCuOh7kpvAvl
# DATA vW8C1GV9TaPAx2af4Afn31/ACRg3VMG6nv8XPOZ/8vxf7NQCnj1QOWgPT6YLXIbhIk320tvq5cQ4ns4ILBGswnUdpudDKCNWIAPG
# DATA wzPDIpz/Nxo6FJn+gI2KHdkLOYqSvQwhS6lPxAB/Imj4W9Q0fB0mmu7xt/N52BkvJHzsYMyArnMhxOe2j8SOUxpGx6T+7z6GLFjw
# DATA kwWUXkcneTBNsFiKofym5E6y1nm4be5Jwwsl/zv/36hA+gI31y8sQQ8EQFueNUVCd0zF63/Gw40aVZQTDXlWdFDCjg4t+YxanQy7
# DATA 82i9bdAdECDFAH0s1jwOEnEGp8+t8eC42+a63IFT5ViadFaez16t6Job0pU1SwYMEJYVp0SkDGWQCKeGsEkvPUwr0e2h0083wsN+
# DATA GP0C5PMyw4DMJkZQPZBpgA/oYp2ADnEIa7xqZA5GbL+D7tNqWBr34mLomU3EIBzEpYMOcP6cWUn4ZD9Es4Rg6VHr2E1FAdfY7pTo
# DATA mPHEQW8SHzkhNlBffNJv5+Qzog/9Qc6IlBzEyt+VJh2jRGldQhRQz+gCcjeUGFPninm0wqKJc8fR+GjQKXAgsQNrY+b9pAesyA2Z
# DATA 3tM4EeoUxOah8PbNt5c8t3Vi4Tt3snjs6saO2eaK4AViK/9SGRCMox9w07WNNcU4AtS7S/sDsoXb4kzlwIOYqqQS4SmwL49G/1DA
# DATA JMarxDpgp+8f5sJ6px839vrhHHbTMK7L+Yp6mOYRkKWVX5h4R/nJRKPj7pjCWnOncKfZ7g0mnYNeCyyywy4ZLUOMuKV5IyOyeohR
# DATA 9Ondw/aAXuO31NSlvCpxlamdhOLsNiI65swBnsaBGGigO5u9MYpV8pBRE0h+6mkjg+Vj9CYQIwosjn+M+IcCxaZCSpQFd0qgxPlv
# DATA gDiQZkDkJyoS28Xzn5MAD5sPq/B/z0aFv/CBTtBgUanPPiPrIDwSOiAuJoaO7CtDi8wsUvx3JOkvzv8kKgMr0CfaqPUpbnjGYrDq
# DATA Z3Z3Gfd8i+1SaRD+VvrxoNvPHYSnj87A+voYPGDJk6BgDb+EzC4hVhEmtGNeA96chtSGFFQIJNuZQRD0KeFsKgbLUmjjQEEtRnCV
# DATA BUpipmqe2ys25n6gr5RMRKbG6WIBEEuwtOniS5rKlhaN5ulHgjOgA2HIzsfU2nAO/86F6GeMVC87YuZew9nuxRpyy95zdeGJx+XX
# DATA +cet0Xyvu6/z682Ly/OWXJj2kCErSvB9xUWp6jk5U3PoXB3OidfmwqSPtR2iYYD5u9oOo2+i5JjU0bNrTxwXn2CuiixlDrgYUTcW
# DATA m5+1ucWp2QgMHxTzrGE6oEu/U1ojcJobSfx8sRCwdDtXu0PCGpy81T6OinWZhFzBiAHWBhc4ndc4RCu4DroR/BnOiT9FZvdni9lx
# DATA m0gsoMYmYze1RhufyNRoX2AxKR6IFt0/4hH1q2B55YFOlx6jIVlsZsOoLQ6IkB0YdSZPo/YOIsX/02QA7mmYUb2DrmrtMelm4qOo
# DATA 15P3SX8iBMHWkHYx7IiOP9rbAxraE5/QiEq6Thevm9fegmtvvSXRhTR9UMYHbjD/DfPzkhbmQhmgY2cdC+sP+92xkDVWDVfj7cg2
# DATA pO2u75hn5L3+8oGQZaocTVEcgIgYsYNUwKGIXNte/8MW7BbeZ5E3WY1hn3fRnl1w5hVCUnw0EM89fNCKH1XLQrrb66vRr14XjI7G
# DATA dC68vgdKIt6obi8tXWKAcPHMNDxyYIxBEetKDFqrB32q70JJ4q3N/kpLyOGd1qh6oyj+F5RvFhZuVcrlCvApq+vbgrDEvvlx1FmN
# DATA eq2TnahdvXkbntoCpTzkVB5Xx2KPxfLXyLLZoNGNOvdOqtj4WA2sMxYe3/NLuZ3P5HEu47TJm3yIKj1TzlBBxOgQDdgBpN4bH6k4
# DATA qJGUZA1Xw7rhW21qpcVP1htaroi0q6MzOaVPsfy2Y8baUmEZ8BU7bQJID5Nu2XPKGpe8KWVaDkyqShS05JMW55+McFDct0BpNfT7
# DATA ejvehGrADS9UV9vVKknrcqtk6btaJdR4tewoSWiT6cKY8DYdnlg+r1JVN70a09P4YnUaJGRUbZxAWyUpDIqS+RTaKpkitL9gJ/SL
# DATA BE2zJyxqmuVfuhtE3hUr2x2Mm9q0xVfaCX1+nozGZqBQkodqiXDJkmfFFJLhdWdLom8G70fREC2VEhskkFsxnrghUWa/3Ztggnrw
# DATA zNgfjMM46EGkLx9I4lIy9Wg9HPdklBYvy4oxmNZqpmgq7pRpDC9poSDPS956Ftal+Yydg4o2Ah4mC8XNr2wiQdfIbDjuxZ4kqSy/
# DATA gJ8SgSEZPUHZxboLbfbhp3hlFjIvfPf853R8fP6v5JiBB0w0zsMBU+zMDq4+eRGLKutWYxr5d8xb0JLGDF7Al3LOha074adrKUYu
# DATA 5bsL1vcfExgAZkVjFRmJZJDqvQvHFYMf6Dw+Mro/CnqDw5LjcR2e/9ZwbBEjWhEHKMNXEOGudEKvyM02y7rd0HSJYSdAdLFZ21gr
# DATA aIcK8X82t0NIHHSkauQnSXdkXPh35Pan3d8OnjQPJ61R5xV6AWb7/y0s3rq9aPv/LZRvLpSv/P9ek//fbgS27dao24Ng6hgMLZCM
# DATA izE+Hr77oZBiMUUdb0cF0r93+5TJDSwRI8raeJLlAnjQ7o97F/D3i48m4656gcIdLuYByL8BF0QquNBhhwJ0pvjNkduf3ztObP6O
# DATA o9zSrWyvi6j/uHp648YgLnFgmthf11eay+vohr5iKHyn+tltk0ejsY+Bj9gfyar5/BM4beuogq+kzQ1DHMS//wIXxStiWt8JPPz0
# DATA QAhdTwAD5vxz8JFBH/1Pn/86nOrDJ8asaWyHErpbwnsdddFMaQzyFtpuLOQaGyqTrdfwZulJSzBoOdi3lsqzgNXRm2NQVvehRfmM
# DATA FO/JShbKiUToRuN36ana06GNBKULe9Tt9VyQNl1LljnNNqTRKVMrmKQdJ1U7naSPbP00mGLR+vpT1KEDOXyrgm4EmWgL9wtY8sQ2
# DATA 47XkgVGNzN9m+djj2ax9f1vGvlG0PxiMm5Kd5sSwFVhF1h6L45FYZEKiGUBO3SqrXBKq3yKMtSwBJKBJvzuupipoEi8i9qJWZWnK
# DATA o3pfCu19Y/lhzEiBXP9M7hXHrdEj1KzTSwSrQAHrIWsedxGJSgx3ER28fjzYFwtcdBpwr4aDJ+Kl3iCOYfh63UeRVFSKs9h41OrH
# DATA Xdj28GDpah7FKL642pE5AUxdIU1FhhOFi9DZvUUzxKhJHSK0R6kKrUS4gEbf6VKqs/FRDf0oEGcJJHMawTzlitjrp+oN7RJNzSEA
# DATA NvGoiEKuB5yITuyFrf1eZGgZtwbxuDo/iUfz+93+/Og4KB4EiWZY1aSp6BBypTiBA5ChpjO0legRbyyokPKSCrKHo75UiSWeoiaH
# DATA tJZKmDzUmidqJeCuo9Aka5X+PLyVUYxmhYlzCitAoTzqyA2yEFDMqWgahyFEYvjEOZx/PTnqto+qJDOV8EdBSmVmig7xOqF2wcmZ
# DATA pSHeSrG0oKq+AcCZvacTBufBE/EQ1pALxQ/bzCAuJHZwLtDe6tmhuUpjjXxOolU0kv54eKOErnwxbAeE5D+JIVknDbllociol9uZ
# DATA UaKnPB9v+zefSMWOT9+hYPUFOvIRJ/vuHSk9GyFusAP/Am7zGEpbiBpevlAUY2Q9IojSfUhcsmdCFsYaEvXUlG5x1KDDtaWj9OfY
# DATA LRIt1UVw3HSDdWkslONHsiOdbtwaHTeB/4IHBZMqEp29B+Z9myDDwYrFGKCmzbP1eXEBmfUvCx4jy5dZX0C2AJ0bqDCkEFwKlgOQ
# DATA 4wQHkwiEI0A0pJTq/TbgD7MDvsEyOi6cZHvQ6zHiSbGIuzG2jXh7sSjYD9FcFTHXNKMT93CHAVz+oaCek+pyuz0Ztdpou1gAbRkt
# DATA HJ3iU3KqRt6LPS9XmvECTITxxrT1k5BtDI0mNlac+47FeD05ivpW3mjwLzc0l/7G2K03TaoZXGLGVZxG8nrZols4eyH/RCzeryCk
# DATA 9HObts+/eCcg/yT0af5aWmBTRRjkB3xDXvwOigAzKThFowekBfSoVkYub4+XuSUxfg+uAYCAUjadVw6CNCMakPddpqUQzhDigF1V
# DATA LdquAYTsam17JjQeLoa6FJf4Z32h0lBAPfJaZaEBaldAsA4bpEc075ssU5bKLJOCxbiYcsMxm08TfbXT22fnv0cHd6CipGX8G6Xl
# DATA zyfc+MJ5Me2OgA4+BKXeoP0ocS4DR3hEoOjzCVL82myubNeWd4Nn9GN79cNt+X1j893N9fXNDy1JhZCxhdg4mgwByUTCSxyM4PTi
# DATA OLYiDrWDXbG2sWtCV2RDWSThLCTEtn6juXZ/w1Xavh+d7A+EeLQmW5rLZyNqXKhVfoANY1TY8D39WArTZIwZKMDEaVNczME/Bb4C
# DATA 2YyatR9maKYTsqDGk3pxC0NiMCvpDQmVEIMCjvgPw1nfSed/3yHCwPOfY8QN8Uq/Niq0zR7mcjIMHxezZyTaP83kYNaqjA6m7QKD
# DATA eX+BarVfpurQPB2UEkX412ZjoCQQxdYhuCK+IhNApv5/oXzr9tJNV/9/p3wV//9aPm++oQ7ekNZzeDI+GvRvXrt+/fo650OFLBtE
# DATA JdJJrQTrhPOnUm5URA9HNC/ADB8NJodHKBEqqXlmw8BRKwaDgPp53GqTpQDAVFCPAVsO3QS9L6CdbENMcDx+T7DG3suAFxAipPoO
# DATA rlZjqjbd+AA8w7I2YGWTUU/UVRpR62Sd3NgC3IaN45pqAPEeoxbt8IDgn947jCd8jVJ+okGd7fVNdPUXkpyBP35tZX0NTkw455jw
# DATA llQuUsIIr61sbuwKQay23YRv25vr+LgthoAydTTohdd2atsfrK3U7DMYY4whxSg14rWHG2u7ze3NzV0t2/icxa5tPdwGeHzI5JdS
# DATA ZvHxgqh5d/l+bQdDpFCLwZkTOoMnfVTkYKQUZWljXEhOhM658U74BXDm6PbFVDKKZPdA3mkLcu6LF/LXHiz/sLm+eb9576NdrNII
# DATA m1dqW0rPMhocirGOOfPESM60ICiAwEOk6EIQPdbhMZCKGMIn46NgH0xsYh2JcRjSM3GBkfOlXCrF6BiPya0nAZOhjASXmYglxVVB
# DATA qdnsQso0vMDKKDpy2+D1ViJC9HCB5aMgaXnG51ltYiedNlw4RH1rkNP5japqhNQ/6IfSFDZGeYeRDITmiYbUwDAmOmEG56ehWSeg
# DATA ZjhiQkppVwB4iHSTzJxxf7u2s2OL3U6HKf+AnFdUKch+OUnr+gNQi2EEKPyT85y/ZTHWCGurAUs+AC28MRi/C+TgRJMZBZyGOEro
# DATA n0Oo9fgX1alRZxlAdEWL4ESNlARQxYhCzFAusYHVbGSBlhXUufSGQi+AlwSzEEsqwhQPwIMEocZSG3I8eEw5sUGnAuZD7QsFC++J
# DATA kC9jhVRAc1oCA/LTHNYEEbTWVdmofLL3daMXjbp8sIH5kp/mygWciqLbFz0yjXyiyBJxFmpLlUfUfq0qSqUXcRlTMmkxChCisPe0
# DATA XC7uPV042Ht650B8+d5Bg9MR4bN5cQZd5BzOulU8MdDunOfqXFA/DVt6HrEkwKkmJkIPit/496yRrxcXlypuHZzhCzotqhEFXfNl
# DATA xcJ8YfyOz6eVSnG5G/l3VRyGk+QFtmM8PpfQ1PpzJXrXy/QF6vA8Y6HaJwx1pjA9rKQ3VT69jf6VjmQrrjtU7Kwnpb0Y9iKOttID
# DATA NjxC3GL2/uRHQh5g2OUpw61qiM16k1w1YeUGOG/wDc9k8bzJiq6J6mI3KyPqCOTyg02ai7QWpeu/B1CbxNQF59Zv42ldXqZxq+O4
# DATA VRreFGh6CNAdJcfLPZ4c51ShdSywkVm2YA65qTwin0zjh84ZqhHVoFzxuny4c8VZdnpoUgTLi/KZ63TjYa91ErQwoq4F4OfB9XLA
# DATA YAPXS67/QTbJGl6BiTSRQlQ1SFlvHgkClRvJGowV5ERBsp4LFuSNFTH0wHcghT2Nqw8iH0l3Z4yQ9daznBSKyR8P2FiFmzIlGrWJ
# DATA vy2Uy553iACocTfwmXmzFrdJsbEtGktGXyZ8e8ksK34W6hQa9VrDGHII4GyJlyyqzBn1HAhyiI+oIpKHngAReluC21c+0QOICD+G
# DATA hmxL6jLqlZfM7T65pZwJdt7uCVKw5CHDyVIqiwWxEOOXCB+9wSEzffZ04D0X8hFCGhBPtjvJVRB2PplvbdboyrU+Ot4rBC9RnC5l
# DATA hkRHF0ttxDKgmc9Bhd8fdPzq1Q+3NzfWP5I6VUvZWvvhynqmsjWBUKBEMeCTyQx0FZexquchKBcan8jq7k6VnrwSwRXJsEt12Ure
# DATA R36/+g4Fj3sAB+QzVnLKNFQEMSLtHqQHPei4flAGl9Kq1YMOx/Un6bKJ1J2jAxCfrSDOY6yDQPlwRNJOLqyDjEA5q8ajA9zBw7c+
# DATA Kr51XHyrs/vWe5W3HlTe2vnHkFz7SofHtMejGNFArwQ6h0A6GvhFVZGXRKgiasPJ+KD4NkSjQs/jashuHlIG4TZJz6NktxiNiSkt
# DATA MtanTTQzUeXy1lZtY9UlxVQHKzXcoFGlllZcB/iU8Q8Z1plsQ6xqLSnlNCSqUZ4ddDM/a8niBM5ZzPHIlE1hBhOjnE4S3SrByuSy
# DATA SB1iHJxUTsgM8PWOFC8QuGXxWeZX2UNjirM0QlJpYvQO3d20xeclcXbrHA4alYcbyx+IYVi+t14LU1mwbEtyaqaZvrZXzVUg6V7/
# DATA 3rgHppfZHA1HElYEg57sWT4WPIAhkNBvEDAz6DmP36DjhFLaaa7tbNfu52QhEmsjNYplhlHUJ4BJv825183yGerDUmzZRjlqfRxF
# DATA j6RAk3i/aL/vdBHUU1VZDpw2cvbTHhpNNeBk95iCgfFFheEg+22WBO0R/4IxeYxOb7l95Nn1RTqwqCfqFXhsJKS2Dj8CAjA9BK7f
# DATA XA6Dh6Wz+ozWRP0On2RgkCGTY24UFuEDjBoQDYLGDQZ6D96vfYS3QvI81+O8Hx12+/2Ugu7V7q9tzFwUoBdQm2DLR0APXToo3/Am
# DATA eVoIueD7+q685tArD1RY366tLq/s1lYDow0N3IPFE3UuF7Cd8qy+EMcfwaNijWllrXm+KwGhkudYy6BFp9c6paGQx++LKgDU8cnM
# DATA a1oNTmWNlBWvoDgj5zyUPz25rFjMoTRfBk+Vl+ShH7TKUBUmJ5M3S4e9wX4uvCGVGvXK7SXQF+FD6ilvzbGQUBJv31zU0GEy3Xlf
# DATA Vp6hTUAQF1uV4ElybptZ8R068hhiPG7rHn5njDe4kZBZA4uoG6838vmXflA+sLJWG9J4N8oaEu+G5EtGeqnt6UW2qLRdJ3W/ytiG
# DATA GJ9j3O1PomueQBcjPWw6/5+RfZqnI0JLRdosAXOGc5Hgdj/ai2/k7laip2Ac24vn8ndzDAnTbBjoMY0befFgFR4u3cj/nZ0RFow1
# DATA pQf5il/nozkrcZ9nQCdPBKk/Q77yjKW8Zzow8hlgLN19FJ08gy0TlGQQs/wsbvXGzzoxQgdAZ+oLDax5LWWU5RKjhxcbhscbpr/d
# DATA u74Xhnnvq6LhoBDBEvLB31eDpUpqgJLDU+kdd00lBMnEgqFiEEVkANqM3Cm1H9Gf8BvcYu7u4QvEBnADcpp+hpiR1R5kvmakFzrR
# DATA G2uR9hv4o3zqqa6CsQk1ZAwKb+NShZ+72z3O51qT8ZFY4h+jKlEQSr1SbRBx7QsCiEbPxER223mgsb0dwKQZhXsLRtnmpurWEHId
# DATA orD6dcGz7u7tW8Qpru/UVrZru8+2lnd2PtzcXn2GKVSe8bbZvCv2zWfigdXaxu7a8vqz5a01urb8cPe9ze21f1zeXdvcyLuFcmWq
# DATA M/n6j/ZGe/3GXBherAPThYr6Xry307hxV9Q6TZR59nf5sJAqHGQ1Y28/OvkHo5MmBFTa7/3QpoGs8nMAyyNeb/BfUcZcqdi4UZmf
# DATA h6GL539QacxV6Ftj7geJMfxBduufLuzv1evl4t3GjXpQnBf//qD4n6S1KPGehPRqH7VGrTYEWCMwj/ol1hM+CQpS8yLER4xDkNsE
# DATA k9Jv42K6uRiQj6N1441qsLB4J0tkVQLdKh8XcQ8ANCeK+m7FY0JyLwW7R5FS2FqqO9JUgucIYbWjW0UJYPhYHrS11PLkJ47C8itl
# DATA zxyTbhjeAMgR2Vi4JL+f8eEWMtKLrUw5ojTZTyWnLfDbZAQPjidj8D4O1vEVxKAvQDv7gh2NscHgPUFOAuJna0zA88G4dWiY3oeD
# DATA uMtHZR3tSSIPpjVfgTRO27WtzZ213c3tjyg353h83OrPK9Sbomquaz9LxUYTdD7v/AbaVM2ZzSi+XVuvLe/UVLSnNOux00pOK55C
# DATA mdxI7HSlQyGVTPbBpXYea5w/1RWfzUvPoHmai7vKraOJrhvVU9dL/8xwgiecsrh6Gi63YR8CtQg4cEBACuCjPu53uPo5lGgLkBpZ
# DATA lFtcYQNhBQTyYhuuhZ4Y3fChoMLi8iEnntVTYJ4jZF51w/GTvXdyysnDSJkBQtgoioeDfhwlTqB8nWSixVu32ZMEjphqrmH7E4+D
# DATA VVw/cakJxJG30UygYJOojG2Yny8g6uVlKEYsBewjFsOoHq1DVGppSs45tYoneOtnXxGHzB/vdQRPl/8An2wdOtGaI7vOzqh1ALaW
# DATA bozlYWbExENDsaPLXLHWk5fpOOd1gL6AF7oV9sXXmCHJJ0m8qaTMhCkQ+UfFGhSx5eLf/F0xPGbJUzrxQW17R0gNSvk2wnP3eCJY
# DATA d+64NQREVS5Pgp5DdiyNktQ/ycFLQKcLS3eW3r55e+kOWTLgqtiJsMjLtIXHjpo0F+TKhbxYB7mloIirg8rVYbOWO00l02LjP3Z5
# DATA fbpREz5KARRmjR8HCONyBuzcW9YqRlxpiao70zDs7EJyP6Yqlv+N1Wsh8vuJZvbFa9bFA45l8LCyJ8WFKBWU0sjPHz5cW+VXUbzA
# DATA rzOurP/4sLazm96uWFwamm4oTRkxT2nL6RfnKFVQwJUp3m/sAOFxArtm4G6L37aJTPQ5S/c0u0L84cbO8ru15tby7nuh1aLZ7Jry
# DATA 4YRVM+nVp8dMUZIeLAOala6h9thFw9LPpwNiGUSiiiqgmsq1ZBoVqe/1csNR+lGwKJrlzOzO6o088fXlra0mHaVQrPZhfIGnczWg
# DATA njB8lqlPUooaq29GCAXoIWyV6490rVU4QhwAwufp7aUzqWlgDUOyS1IRgDC5lAfIAJBlNkJPg9715mImET1Y29lZ27gvB4B3ZdBS
# DATA AObrcatd6kdPuDgF/1sI2Ou2IN2vS/FRS0geKI11uocg+uU9vmPpdF8Q4jspXStU/ZmD4i0LAprKmQs3mUqeZ8iQ+mITQZBdjBUy
# DATA eF0CDoJ7IIZq65kD5xVEHWNHdsFJGBMwFz4e9CbHETgC1y0XQeUdWcfXSRWF3yB5E5XYPfAqV3LGEsAnmTlTHie4IGUkBE1E16+E
# DATA AzawmFlLVwqUpBu3bKzcyCthXkgli418w9D0qGUoZu9kCAevcL/bNyEeCRCOmU1eAz5WklWye3UT4gTEfWBVZ9d83gumlwFsFXXZ
# DATA kIYvetOid66q+WDz4cYuVPzu+trKricZGhfvGO5w9qTeS9bqo3R7a5GIwEYFckhQ7256Sav8FGn5r1NehBXEPn0VkkvBpx1dBMWs
# DATA dDsIR8BOlhU051407xNP3QckkMpCghA1sfzzLAn4CoC7UafJG6mRw1zao/OpqBYcsJ2bgvkKSgJxxAfChvy/QY74C+oNpFunRLdw
# DATA sXAdQIok4G3cBcWEiXGrAmA4+CUo3kPTu9E1iq7w9QsdQSgiFl8yRwduoY4j0SgA74CqB/0ieybs9fkawtLacLyzY134SFdHXswH
# DATA HLBR4OBzd2oTqSM1tkASKqNA+BGGCJL9usLQCIvF/uCJ+MKtuXBJIxqp1BLkoQABUoQECzr58QkLjIbkYmiAAAAXMM96wLFOVN5T
# DATA wQtxU3tH0h3EdLY6wRiwY2hbjVpiy8bhVjqgVBFTJR5I3zgz0hBYoqaUTV9IwJTYmlSXh1HpuAwtPZpgr5mCmbzGIy72gciUG7PE
# DATA NW7YzcXg+1VbAKoGS+Xv3VaY5UfapsC6UcIx3hshxA7qg8A9P2zk/4rkJpmyISkjKR9N1EhVVEx2s9kVK7bZFE3oHZBt2YxYFhdL
# DATA 6WSnHtFHHP2Gec5R1aHIhXUlHeGNc4RZprvvGYW1Hkfc7oRqwhqWrPL4XSc+QYesk760k2wzGrSrbqtdizvnaHe83bsytIuhZ0EI
# DATA AC9tinBiw3+g7Ob0lGCtsjV++AmL8DY2d5trG+Igvg7eYLpqqSaikush//bAdCSe0MMCDl1MMFJNCW4A5nl4eryYwp0DZ3pfxil5
# DATA wMSBJcpJ+ABkxoi9BE8naR8I5LRI/a0bsiWGJMwAJU7qN4YcDJSiiAvVYW9xCdKPwOOzuW751R3uoKautlwIVWH/cGrcMBf/4PNQ
# DATA vOoJcBqWPQtMx5Ybolqkhi+ipmv0ZUkudQ3k6UTOlnqYOMIoNm/5XUNCHHIsgCIcRybXyQM+ABY329xA0XUhrmNIl3+GeJZEmXYc
# DATA EIY5ijGbRHgAkwGPdMAz4o+Con7XDCQog+LxzmI5JU4F3uG4N6yxKuMn2RejKih0t7a9/XBr1+JMqsnYM1EKwY4LCaqi2gFI4WZi
# DATA AZPwRFfMpAbcXXXuQHvYIahmQgdgfHqApL9pKmDKMi4OOTiF5vzM2K6S4dXMRNtHrX6Se6LOGAkAkT3IhAAK41abMHG8HEbeRJ2p
# DATA wTjTgrmy5LqtVXAQuPdw56OE/+eJL5CKvIeT3SwB4uWREN+6H0fmCqR+532T4StlFf+kuXSmd8RwdSafTvJRNhd9k5wNaTqIMyta
# DATA UpvcRXc2Haqqgovl+UKiLBlHDiGzH45anWiGvT2dwyPD8XIq0TVUQpjjTx0VEsXgSbPTjRG3zIJaSnQEQghlO5FdQIVEWsetviiu
# DATA QzYvJNap/dhavl9rPli7v40uJtidtW2LJ6SuAfiZsgLo1iulf/Ymn3nnnL54DHWgL4Y7JT4nufdWM/Ze78uaZeLGrX6me3VdWORw
# DATA GISsf3rHLrFh2QU4u9b3M3atC83/7DuGcmRz5S/aKCCgjsLs9TxUTNZjTG5FC9taX6dHxYxFNMbE1bvZa9ITse3k10il2BRVCmEx
# DATA ZiIVsk6tiDBvAAZoABia0ByHlpTt10KK9xSIoVZtUYHqBqMvPWg9BSUY0AA84Krn8KV7oPxBpVxqfQxSB7uKFvsKLJ1CpqxoxPXD
# DATA hW4nlIxWXALRQe0nlnbJcvTwEVvuklhVFuFNEczEcXF7t6kiiFheqiZDna753T3VzjKjqO55cBQW+eRTbJzevH22xw/6orouQMIp
# DATA S9zqsBNoIoOhAKDWFhZgki1Z4ZICwks/EV6INV96E3M25XxlygEzuY3NcnYko38CxAD0I8z00kRQ6zK4BzpqKRnTlpuRSvNugc32
# DATA KOLoJ5RIpjNLis5DJBQd8GesF8htw26Isy2IJHXb7QKW4mcBdXUMajCqk/id9wgkqRGGuGjk2q2aw6d3LgX3bUyhIWrk/ce+lyy6
# DATA qtHX8qscA92Whk8OeSkS7wtJvi/9HPFC4ptv81Bi2IvwZHKM8kS4qrTxBNhaX1lf031Lpl+lHVeqKhHXBnxCw0bGbKI/BBdMc5lW
# DATA Lq5JU7mgvjf8O6EjG92gpC9+meAEHApggDrdftV4c7X2wcbD9XW8A3KBXH+Ub0r99IkQdxbKZb8MnrGsVzYfbK3XdnHnt5f2bPSg
# DATA oWWkPKEzpV8wjupyEk73wGSCfnLiAHmCCZg+RDJcXnyXIsilBCtc75tbNV7vXoGDOZMB6tHw4AHNsMYsa8skoc/MVKv7sX88B60U
# DATA kBHUDd4uu4lrMB9Ak7Sb3E9S19vrJwm8ntC5szhlF2IPTQuTGlanGHu7MaOj24cVaEJDr6RbeSNjEoLzeJVuUGOS4ACfpyPEoIBO
# DATA BRqgpxe1RAsBzmx/NHgSQ3Ji1loA9AxQwDjqnZT83DJNHZJ64E+/OZOVJV1ws8jDY4kRw2VMfSXTjcRaRQxbz94pM2iRQZsvl03V
# DATA INR8dp3YZbQi2rtTMo/TZDTiyEN4R5sFLxgimk8r1qtLvnGDc16Grcei8+jmUFEvsWs5O9eoJmm3G34weZBVuGbiIReEzZCxaFDO
# DATA TLNfW557INmUGypHBub1BLWRnRkTOTabuW6/H/mCcvE6xoky3AG5SktHa9eGyzigCFheSIKQW4A5LkgODOicR27xiu4uwrZup4Oz
# DATA LWrLIaYUjA0JF8b9jXv5TK2YV2CXecigYiFqrW2maJns8cvc3axhtqjO06jk6Ybn8in6DGBZheBG0x/gqqu6cIu5/nU8X1obmtLS
# DATA S1+H5Nmb7jTRlb9gnMR1LAU6mhRSj+aX1zqnqF2msVe/IXuaLtfSULyQPvOSlvasBqY2bhq64KU6oBybaNbBnUfOtsuwZ6sK3Cc2
# DATA ah/Wtp2K3gw2+5HC1EVB48cD0dFWD/hxPDk46La76NgFcX0yRhFCtEDrAKPSEge4o26MoDaJUHQTqMvkeIyuoPAoJcxCZXYexsRu
# DATA wXTVwQXKQLnMV4p4hUtvpIaAvziyVzbC14xnhpRyM5TuyvOVDkw+Rbp0fdXadteflVmPv0+XUsSnSiKvR/2epupOqOT9DjCFVDX8
# DATA VJ3961HNm1r5vxYV/Ewy7stUyE9xXoKAc+uhC6nhMwn4ZSnfDb37ZTTurt46bUd/Yb+zmbDJM3TW3f7BwKeZ57DSLLhwHYlECEAz
# DATA lxEfXVDPDfdNE4JPuz6F5PIvRXGOrWDt+XQSfsmK86bfRm+oNYnKDiszquNQ06RV7DxkUYeYL6vVsTX2roRuYED6VWOk/fs3Ram5
# DATA WaMNEIHNzV2Ox7G4qH6CBbF/2Lxn7ZMmDgEGMTfXNt7dbL4rFjiXB5SdT40n8RRQ29jd/sgsAQnbceBypon2dJgkncPh2oXO//b6
# DATA tHMwGMSne27mijj/nU7cQ7l9Pn/+S8zL9Qn8tDwYUs5FMiVgNQNmYibFMym3hQAA7SvKsHRHV64Kb2BEYRWiCmcJ+ZmqsUZaZnU1
# DATA fvfttd9LU1VrkAFtSkT6SXkaPdM7GiagTrxALRA/EpJyh6bX/YWDeY4UrQfXP5CJafQ0naqvZxVObHMqCzxTIR7iFb7nX8Bne/3r
# DATA KgQgvR2+rNLGxpToUPB9fRTy1pu/kKuPXJhwQNquLa9+FF6kKRc6ll3ieGY52DMVqMnRrPKNqp69Szo6mSANntqRTSWibEAoUHem
# DATA nYwuXf2bwT3SKkN9lGIXcfGPWydw3MKMS62gHwFu/JCyxOg8S6VrU7Wzip55QKt+upIqGvmUJAMl7GJx6WzwFXHn32hmbOVYg6xy
# DATA FcjVCXnmvjj/9vmvAtpJZaspHcxsfFefYPZbQrIqGFuXYcWUAI9+bmwaB18XW06lZ3e5whLyT/uFCJqxOZoP1nYeLO+uvBe+yCxz
# DATA YiWY5N+e/z6ZLfVPmCkV0un9M6UQDKdM6tTj2iwmz2minmN2zRby/EWn6nyoXk+2k6TTT3YqovzU4t3sOU7+ByONjuuwOT2dTrZ/
# DATA gd8yYCcagZA4M0eRt9VnKeLyJQw7mdqoV2oEfxNR0vjoQRgyEEQYoIa9E+yfUIzpcNDtj0vBlhgECCQOtlDRMt+PxnDI9pTKygaI
# DATA Th0U8Hwj6gjagyHkNVOKzk63ddgfxONuG1SY4wHtL22ZFv1SJvsUe3zThLCfXQ1qLIeppq9L86IE+ZNvM9dMOBx6U5opvD6Fp/0l
# DATA lbHJpGXXXiY9J2gZFdc0KRiAv/PRzm7tQXNreeV9yJgiPZvEQXDr4W6Y1VNv3lRjDazgzrNlL4N+hwjAMdLfuZVVE47/tIytxjYl
# DATA E7byqdersLqUeo8Hzg14cxKhX84/ZCYJCo5TUvF+3I3FIBza4D8JlVLq0yoHTL/7dAfxF3NmjsvS7hGlRDx80H261i9YCTBL+BLy
# DATA KnpVpgdAYIDmGF+NTeUMaAPB2sMrznVxEbtBn6LBC0Gr0+H1Hk+GolUYCaJezHveAfQWPp3mbiVskp6yFXyUaHsOY+65LTQknD80
# DATA 508rmjfzDhA7PBZlimJY1Zkwr1qLkBAJhr0TGUsmlkABMcSct/YHnRMbVwMfUidOjz0i6neaElcwB0+lPURgirlwhSA0iwCIITNi
# DATA SkBFj5LSU4AFsVhAiEVEWwhnrXo96h+OpcQNxizot+tviq/rt2Nf75+gYZpEDCzDGvIjnLw0+jMD47OJyoQD0OIZ4TbMgjzvM0Uj
# DATA rACIpq1R1GS0AGwN95bxEUxQYoJIEP/cQ0BiPPlgDfl0yy7ue0h5S+WbIGBJ81b47ub2vbXV1dpGeDaDileeLmQ2UvDRvF/bJW9b
# DATA vENqZsgXS3JEmG0P1w1bBEwzGjf2hfOHyM5QP6UjiEHwyYXzoOSm0P75VD/brNYoLTYUTVZYp8zGy23pYZTaUInOmNIeerMh4Z3m
# DATA s3HBCT8RToeLry6CLH1MsXpEP6dv5csPIxEcR/NevDUUSv6CtVvuyBQFeyna90Qez9iyrc2dF21aDzmyojCDCTUhgWOSc9cbmSTG
# DATA 5RG2tArztHjb7qjVjw+iUbEGmxvFCrL6jd8WlFHqxoI5dsdaNVcOvg+nlpx+BlWWNkjuSyNmxvk0EBBp9nDfQdhPpy35THcMQ4SF
# DATA kiUiHI7PmPFC3wAXCMQ7wbh4xiXbjh53Ub1w9rqXrI8wsaUvSJy4+OZbbYqn/NukysVbt/+GiBJmzIPhoEPDXgVtak7N8f/QoLps
# DATA S4PEaCtWSF7S7WrMTvaLl9obUomcxMIr8v7/gbxtNe5rImyTphO2mZdBx+kytXU4WLIOB2C6e3fz4caqezh4pWpRq0HfIw8epQCC
# DATA 5WT6lpK+Z0nsU1lqJN2nS+iS3Hk0xqIzaAp5EODhrDOmeR94gv8BUqtIxxyapqTXPDylEAGNVxRUH5Kwcd2PBei87LN2uvfxZ256
# DATA 2DJjCu5srrxfM6ncLM/yGEWPG1P5NJYKKHLRKUg1DGGu40MVb7ES6Pq26ZjAiir80zwYYLIgTLDaBX94Tq4JdNRsghTTbIYy6/Eo
# DATA RkcOsf7we2l5dDgBGMMtvKMybYGFtClkoHazmTfehPxkzRa/ktMujui8uYUacAYaxl/ifDYYjueVy6a03HgLM3fa9tEAkI2rBHKM
# DATA 4qF2mnSQDRAmXQadiqEoSiRMfFaGljQyuyHjIDMfIuV5/p20+73WftTLuI9mtuwqwBs0vQBUm2bcZ/TejCcYl5IbwcGs/Cz+gael
# DATA /glCVXEzjSZdtrGWXXTJHXTzrT2Fs/j2hPLdkFsJrW0FWw25QoBWdFIFUVHJDoXVcUDX0swb+BaZN/CrGDD+hrPD33Em+DuOukRH
# DATA 99dLFGTiTALwvlsVBz/hdx5p/sWjml1JgjotSDcbwtWteqYKeEXoYhFbU5eVL6HDqhy27MLMNZZRosafwIv4s9vRc+NDpSe9tFtU
# DATA /tp/uPpcfa4+V5+rz9Xn6nP1ufpcfa4+V5+rz9Xn6nP1ufpcfa4+V5+rz9Xn6nP1ufpcfa4+V5+rz9Xn6nP1ufpcfa4+V5+rz9Xn
# DATA 6nP1MT//F3JvyJkA2A4A
# END_REMNACUST_HELPERS_V1
REMNACUST_INSTALLER_PAYLOAD_V1
if [[ $EUID == 0 ]]; then
    bash "$directory/installer.sh" "$@"
else
    sudo bash "$directory/installer.sh" "$@"
fi
