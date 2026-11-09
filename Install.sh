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
HELPER_BUNDLE_SHA256='39914b96b22508f6febf25af6a1a4a949f89fdfbbc708fb55ec3681686a3b2d0'
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
# DATA d4kKa81ao9PY8O687/3h3wfZ/0YB/ze4/7sL2lne/gdV5A/2/79t/d/PsFZEMPXVoYu5JLxJ+V8sHZRMJkvSOKp+OhpRjTSmJz9M
# DATA 8R7B++r+8vWc6ls8n09T9eXyZ8lMfcaLbsbJUH1N0t+9OPDVcpGMdX3gYI5+Cv01nszs71wyGPMTTnb3zvDWiyKHWcl7fnx8tn+C
# DATA yRmlb6bf90/2Xxzt7r06PRt8sX/4cv/kdPBl4xtotn/0jNp834dPg3Wtdo/2vjg+oRvNyVWLJ8Tmw43yp5PKn3PLwWevjp4d7g9O
# DATA v9gFNrtTsm8BKf1go+I9PzjcP8V0lFJ+g5c4z1NUVfxmuyXyTvOi3xw1wb68uGQsNnxHG7J0e+RYfcrJEt3Ssr2VC9+2vJyBcnru
# DATA CoQza+T1OuDKU62OEVoKHCX4u2Md04QsCc13Wq4YJXpCYsA53y1TCn8XPxl+1B6rUsV7sfuTwcnuV1havusW0aBHuODwrJl7lDtZ
# DATA FpVxsVVdQ6zMHcUhwFF2KmJIZIieqytOhny5SZUIXJepk9tKrE7lXdm2NTniSw0wo1pdlivvi/QevI7Vbcvb3tqidCWqNaX+U/50
# DATA e9M6/YDfz2ubF/ZPlY8rn5ZUjPTeMw5yf4EwL4FKF2fCfP0B3pAQq+s8JFETwz4LujqyXNpUh2go92KU8BGxxXIGmxdrjGNoBSO8
# DATA UnoR6xElGaAD6zly5Zhyg+sUVbz7qg+os5sGGlW6s1bSXTvryDDgnTQJHx2b26/grb+I62GajsumU/jVmokulQ2kQptO0MkSYccm
# DATA MH6sVpF3aIgpTWXmkRX/R37jvsV4pm/mk+UYpekinpszSsJrsejI1Amz0deqtPflPLlMVQbPlz3ktrV4GnH2DrDlB3OMD8ztTEUQ
# DATA qoUicZhM5eH59iae6sH+LxgkfF5UQhnBKuNDO6sIRcaz3bNdvyQVFO2NgQ/3dve+2PdtOUAbRH1vNe9oL2C/lcpjTta/msZvZnxv
# DATA iDNLX64qMuuB82KRpSvlMBFQZuG9a/1CLmQ0OoaMFUxDUCBcfsTLOcfLw2dlZkP+J8yPhD4VxA6Nyts5CC1SrpzXZUnKw43SRuW8
# DATA caHZIhWH0uxOJ7TcMwAIFOimWExvELz1EnDnbhs/w3BVe1eZOsmBqp4yCd4kk+VkRzF5wyEfLLiZP1q+iv8vGNt02gErhmFOynIc
# DATA zKmmgznjbx06R2rkAdIZrHsJiK/iBxk2i4OJGYuuwNuRn+kUQllmAn02HNoh4QBcQZ4/Al6qdbZIU3+MmTYuleRlnb5ugetklOeB
# DATA dckCDo8/wOitZq+79RhcSUcr48uMrXNu2LM+7hyLmMQ98bbEVizdoS3CpopV/E0YrqRrddzRdaXw6rl66+LBffVqmi1nM8pGVTtK
# DATA wV2q/OtLWIZOzeTi28vaYqgc7VaN5iDrg4ZkoUUXjrvVXrhjxrpTsscqPUVPVeUp2W+4tqRw61OFXBJFHe2Ub0hj94OZlytsRZUq
# DATA npsqp1QAPpWzkjZWjERcPXNCdPMC1hh+mt3+JWj4lb8UpfMvWeP8BlTOihwdfYQ4dLCLQFHNnBVZa2GRi1VoJCLKSG2RzaF3ADmX
# DATA eAc8TBfYg6ke86Fwq5xZF25MTipzxwwL5mRncu5woeCq+z/0nUZIB4phfyAcWCjP7IZsOXGHd3RAJgBVtwMpTKyER/Axpq11XBS3
# DATA giWLuFK8JJQBW6tKWTIpm+jIwbe4+tsswuj0vK7OxKd1dJEzOlsuB3jeFps9ctmYpD2uVumxzwA5HF5v4ztlach9dWVREmkSduUi
# DATA Yd9OL7riL1stJCmwTpGrZhB/5hZ5BYGaF/Gr+/mA63BBPDkMwY9SLqKG+6DkiBhhNR/taIGjMXH/eeZVbY8vFl/DepyeV1mQvvzS
# DATA FsfUmo+sVFbqzcv9lwi5S+8WclfaFFeKWk/y6mrGCd5XCrizLjpdQ/z6ur0VsgH2Zc5zyNTvITJTPFq/VJB8u9IBbiLrFdgEyhdV
# DATA ZY2lUrU3qNWURq/ki2NIKUQDw5r6Z+ZIt6wk7tGPP5aZKxi2cYy71eXX5xBd0J3jd5Iyzen1tNhli1bUWlfy7VUVuC6CKlr/ZBhH
# DATA UU7rt5TqnN0oZ8ZztmO+At89RmQV9FewEWyLToxhHDQiB1+J77lEc+u8t31RYBA6RiBtg/Umn6McqWFEuZCvyPy764qrrhc6CncF
# DATA 0udniZzEZ09tbdhti1UkQ1Y1uVr5umQfoAO39jn8B48v075Phz/dSdLaZ7jOB8dl7rtSaDkASeUMB+X6yhsOork/Qubtu9PMVsSe
# DATA UgHlzDLNQlzDbOgUTAKH59MFO6X5NptBkoFtYJkghskVpCoOAhXLj+UVNigPSFdsPcTVzmAOIK5u84uY5RwR3CmJSO6+0OXAz8Bs
# DATA lEq/+sWalO7VXkbzRIlexh7WGHlSMuPUdOWRb77J//w4DwReM75CooLHUv6kCwoXa4QLC+XxG/LV08y4SYUpS93QcTPQZt2OaFWz
# DATA dFZWfK6yjrvr1xw2r65qWn2uVappFM+LZEoYgJCyq+E9JFLS5WK2pHMDhjArD9Awv6NI92YN5RbKADnh+JAoyHu1pqOUDxoRMGfB
# DATA /AB+Ka/qc9iQ6K3KHxFC9REjFv6Ooy1UfRAE7Tb8KTqWg9n9tOT4ftVGkCtdLL6tOR3/ViZGhlbZPM6yMuMNNzCp3FhRgaDaqeuK
# DATA 2iI0WFDoqm24qA/ZZw+67qiXD7Vq6CU/Z48JmJ9wJIo9h1QQBRvXZOrK9aVdbPk3RcQZMYU38jIqzxOg7zfb9F/k2vX6heqG7Rd6
# DATA gEeggulljN5xW5JV8QW3nqQlzaEjBQUG0ZSexvXLOcoldgq1t/fSOm+1dlQr087csqALVmgP5RP9qYYOBC6wwfpLRbMTit2J/eO8
# DATA XSrQ4BSZ5AwY7U5BfVf39OX+yenB8ZEamCt71Ngn+hhXn/QqhcQ4mqF+KzArtFzMGXWWNfdBJpyLCb476DFG3GNYoe0mtp8qEsGb
# DATA tanShjrP5FQBXbPADuEQGZqyKs6qf9eYIoeTIEbW77FkYtu72hWJCTXGG7mtOs27JbfXmrpuzWNdaFjw8ba00oFm4mLrbTu8/e5e
# DATA AeS4vip3d9bGK1u3PeAkq/QOhhjVvU7IfqaLnaa+1F3xPCmHvOICUOv/SBe/5S7QPWtvv2WT8KltywCynt3POirOawSnuhGSWqst
# DATA wv4CkR0DZossxZTPxvAq8S2s4U+KvC1jU3Wu0fQI85duZOMyR/Oygcq6443izN+8qdc50mXarKkD9EgRaE6qqYuTdL9sAt9z9Zdo
# DATA SmAfdzpyuk8ZuKYbQJy17t5DhXFWToCbxkUhnbX1Fx+Nhst4GqvLbrzcraurPgd9kPped4MqP+l6GtQZQH3uzz4MWHAGkEtwvQQV
# DATA K55fc6GtKMCMkMgCuuZLpTifEkcy2KW3ctUN1cPM9SZJSrjDnvqSw0BXMAC8oOvCUo2oiObC5DAZEqkVlC/Kr3XZ9gneXz9O9L31
# DATA pBBjrlFAHIbKgakkJKRM/Ixh+VHyZqdUEwNvE6MgyXzH2kCV9ZT1OzpzdM1xA6fII4cJKb79mPe0E6fddtvrpqbav9py95ZOSDN9
# DATA 9l71UFy0Q2hTSBPtnhg/FN7UTE9qlJmmnEZv6Vttf/8nB6ewJeQbiPD9Fy/Pvr67p8TKypPv+7tTumvJCn7j9U2z5XCcZFe0DTKU
# DATA 9WYPqPtFr5KsoLvZPA3BSsHD+FQ+ZAFbJl4CU+Ar/XwVXFKJHVj8QdL0imb/uzCj+xkSUIo67l7Am7geCuG+6ILof11WVVgfAyev
# DATA 6XB9gQSnWR5N5oncXmHuUfnI5iTW7wq5+k2kZ6eyjNn+j8a5+FCUdw9IA1moZNoVVILh5MjafLKYx9Zmsn0Nruqx1pMhREIb3nnd
# DATA 8eDaaUr0gg7Xg2lZ+b0UHkhnitbs0gFoHVA9NYwRlKpa73qgYEC+hsG9jQlLj24twd9HN0ea+jB4eEFWmz9Q2kBVM9CIpGoRhEBD
# DATA lmRt6boDokaPi19lnFvvOsb8Sid2wQMuWaC0XmoqaUKWgaarHrC+yl8sjZhBYrW48nAhDKbN/5+cMcin3n73+f+NRrPVWMn/r3f/
# DATA kP//Xfzb2Ng4ibFClZ8tZ3RhTRxZlZE5h1tqWQfoFMCE0Agah6hsjJZj+27ae9L9KV3/A5L0l0PRZ/Qvt/oj+lw972T/5fHpwdnx
# DATA yQFluvOBJCkBg/6Gy6twXkvSJ+N0sQCT/om5wFaXiVn5KX9t0/o+VivLOP0V3LzCnXNpmvvhU9Vrcr9AD3ce34ZIE7bmerVYzLLt
# DATA J08uQU9YDtFjrbs9yc3xzpmkAedRXTAcd97Bi93PsTZg7oyC+Hi2z+ub/WBzxIk5Fe/Z/u6zw4MjzE+n+KoKgszSLKFKR/pGA5OZ
# DATA V/rjknPl20qk1lxELbnMf1yiwKwqUp5vNZdm27qZAgOoPxgPsFx2mckdU73TBWVDrN7CosvrWHcO0WsILr9vufp1CjVGaPAhF3M8
# DATA iPgWxXxMQOHVigyYLkhFtHrkewUYzgduqXFuQy1bgJzAIpwFl5mp7vnJyvNnZOmaJqZi7w36HM+hcylxNnJv6eMSifYqU2U3e+Oe
# DATA a/ReXNjIgK7zRYQvL6mYmXSXsLM1370FBx1QYkIy9wfe5fwExPtQJUZzi6wBHImuwrVA94NxljKlkGWViasHfk+CLM5quV53r1Ow
# DATA c4LsNfb8jIrqoUeCO8AzVfQedOT/FDNv+fcIO47HI7ezYhwXzo0Tw118yNMC7F0UFI1SlRktosOUcTzhkYSLGrJvdKPiVcaViu3x
# DATA GeuYllr77TW3YVq09chLNtL5JYUvzeUgNe5EriNdd4cmTFuYpUVkRfdmrp35ufly4caj+CV1CIYWuPwxqpFVEnQDViZz2XGoN/K9
# DATA Ca06wqnZonOvt/51k+RcbZICYtHTXraukVFd/XDHr+ddoWdcHFIZ3cSaRL8DWR1ElIYC6jHov5G5jYVcBzuW3K3Nl9PyuZSExDJ3
# DATA OL2LKidRiVs0DGYLvEJZpss/YqxBfWRQdiagMLfqVQN4xcnjUCNmiwhaUyZL+/GpLLK/YElgjeEZunjiKNNzHieTZOFmN1o52vmx
# DATA ASRrBXlJ3Day6kPkzmBdcPaluruOb6ziazqd4KY049immc5tEo8jPkyE9fzhzW1+n6OmMhZW8xuwbFFGcUIF4IX0SqpSYcClCXUp
# DATA cCfJSC01S4yV69su5+mSbiBQM4Mh7Evz1Iv69mkZG4wvzBzMX8Hy9m2NaO8OU3M/ps5dcJwV0b27VwaWreKFXCVTCtO+juOZAIfX
# DATA BwDbVvuGfrM0jvwmQsw26yu4cFCsiNMa0rJOJSUwc5P9yXNrveBE3u7Lhdb9Mat9MML/Uir6W3XJVRfISRL2stn3reZXjpMnVeFu
# DATA O6FYw7L+Glz3JmY7kRtDykUKDB51Y61nInpyqWJdQa5lBgKA67r9IORRDmxNimoAQ5O6d5czU8Ja0YG9Amm30vu4eLepWqEL4Jxh
# DATA bu+5DM8ako7DodV7H4vTmV5ijuHch+lySraa48uTBo52WrCxzfCWrsrHdfHGNhCE96CUN/NafCptZkeyckaO1lp19MPpB6vfyvOa
# DATA 39U/2tGbfruoqOWJlpmCImA8uHmi7fXCkX2ZO2B5IuuP53NX1RhCu9f3BvRcZb2Aiz94jfj3fS3eRvA+omwTffpscUTxOEYL8ynw
# DATA FJ/K2FYVO5wBEVLynVR/d7XKldWdT6iSrbnLPqcd8pJ+suM3Hhfms/SIU/2xKPAny8NqilkTmXWYLsd8AR26sce3SoVOFusWh/sb
# DATA lfZwUQHktwL7ne3f0AatEMNTXX+X7h1XDDZHKaXKt3FOf3AZW9s8+pCSuCx7MDLIlxntKPtyTXtktVaBW1aArdeVpfeAN1hJarew
# DATA rDhV1W1n9IVk9n8w9+q/D/9v9nty/D6u/kuz12i5/t96r9P7Q/3X78r/+6VEVXU+oPA9uciLna7iI0F1a5EKe77P35ur23Kv+7fq
# DATA vwQr8mWaJW/WeIMt36/Ua7HrT/BBZ1K65SwXe2d28mUorMRovneN9PT7DzJTYtLVcvqa/HsL4OjjYDKMgm3niIJlq1awRkY+QssQ
# DATA KTWW+nOPHPHzggoZKuTNoapFcAncNAPLTalucnkzzcdEyax0dstGoQZPVGEWvgxk1UwZw+IWvqe5+ya7WNZ3YWWzytWanGTIFQHo
# DATA BIHzWCiPn8Mc71OG3/23d7/k2t6qkPc/wJ/fvv/5+79+989CmZvvfvPu7/EK+3f/hIXAdSUPgT+zDvrlrqCWyz/tM3XmmZxPfUSZ
# DATA +bsHZ0C1xmUGVHocC5D/5oEZUOI06dZvg/MSpXVfbPsBEWmABMqkwXPiz+YioUCWgq7g5JuEljNcYFBtzFV9lgiXnOiphbjV9KBZ
# DATA gg5KpJlzxod7TzmOwj+TK0Vw5/h6OWBLsOnT4HShTDK1s6DTud0Sb3RIFlZD+eHBs4Dv/g+FV67nTlj/zfu/IZLCSu7wCcu/v/8b
# DATA qgn//r/A43+k8vP/DC/9Cx8ZLCigL8RigUjHENCOAeam7pRlAgomUbeNhBPMJ/Dh7kGY/xsWnv8NEvm7vweqQVh+w2XxsSw9UIpV
# DATA mB7r3b/7Z5jKz+H7366Fl0gGIKya6AXBfp6D+6I4I0yuOxtZQaq3epS7zbewie82wZpavtl8ix3e1YBz1y5/VsqlY82UA2Z0T0DM
# DATA 6nn7LUOpC/9dqMF4mNKKDWYcznRxHi2BOplkPWRTyDnf+5gsS5sbwULAMvzq3b+8/7uCXfyLVU/1PXeuPxIdfywRtxJfzZ4/EW+m
# DATA py/cZPfLh06NGe0v3v0jfPnl+7/28Q9+ADKD2d3Lsx5/7MWF2FQBwNvSiisAqHjj2k7oo4q2ffCsYUv9nU977dc0Ub4dgn+Guf/8
# DATA 3b/A//3iEWtNrJgudyH+TbBxSqaSNcYexlRP2g8FEdm3zNPPN0ycBzbA/8feu3a3kZ4Hgv7MX1GSd1OAGgCvkrpBQQ5bYrs5ligN
# DATA SdndphicIlAkywIBBAXw0jTPceJkMznxTpLZ/TC758zO5ux+3XOcjjtxbLd9zvwC9V+YX7LP7b3WWwAoqduzO+7EIqrqvV+e+2VR
# DATA 0Ge+2B2c9xGiL9KVWCxcBqrOK3M4GpwDQ9dWVdqTUU/AKQ/hPX1LrFpMnXA5tfoIYGidyxyy5wPEhBF/IYD4J6//GX7//esvI1jh
# DATA Lyj9yC8oCwiexN+8/mX03Wz88eTQd+Aul7Jac2AfV4rIVbUjOFCRff5MERxUMLU7d1bf6L7IYcAJ/GTKIRESUBEkyl0F9rQzLpJ9
# DATA TkIfBHnVpk/xTaEZF6z8VtqodQo+CszyPxNC/IVsEudUkRwoEWwU3xG4MxG1CvAw4lZdVwo13H2b9DqwNHVGnKmcsAuYaR+fJQWu
# DATA XDBM+FYp0EP7ihY6oLkrygmJEzm4hBoOnP24unOHPjpeMTIQTZVQBlYiPPQ3RYh4/jD22KEwo94YL11TnbzglcQu6Eg23QOqAluQ
# DATA Pk6yQ1X4j0BAORg9UqpybkX4qMin6bpX7bpo1XFmwFEYePGcDweSH1RXG+QCLogaiKeerb8rkjAAX+0748AKps2gOFJxeB455c9P
# DATA rdhkNKsZimSH6pQ5OXTnXK2g1LDQTJEqDcz6P9Co/wwm8rdIPgB9VyQ94dXnAFZ+Snjol96SIPkKtb76K+sq4kuHNSJ4o8MuZkeX
# DATA bfGTlUBj9pnJAqy1Nat5opjsfrxRh0IhuGcR3p/DTjJoByAflzku8wDjURPox3fsZk+6F4pBNDmtnLKvu87MapV7vwwXlJ/i158H
# DATA Jw/zxr36d0RX/CbCTFsIMuHFb1//q0U3IIzKHS3tnA79Qpo7MpWK5RlfRJVoaJ7l7eQwH/QmYzFGjxsNMsGirxjoMi/x5Vc4tKJD
# DATA CJBbgBUnQAUVmJ8AA4aGiEg4HbBeQn7+jo7/z6Lgwn4RB+elZpDP1TXits8RiWH+MbhKf40Z0Pg63ahz6hEl7p6PO2oX2QQkFJog
# DATA 1jIJL0+rkDOq9mBUPOWFyipsQ9CKonzlAWg4Dc0gblVZRxlekYEW750qXZQD5RiE0TdJg0L7AnKYPTs4uMHlIwCj6RSEhr9A5PD6
# DATA n/CiWRBUw9wvkaOha6lImFKGhhEcQceyOBPWxEw67cKe2g0F97WknTffXuFn/gJm/U+MYL/6n+D3L2fstAnpZA3ZjqKhDDctrsAT
# DATA vyoXMVvMaWEVxavN3uP/iNuKPBls61+wZIYv7RtgG5qbTUNZck/joszI0UWfohGvyF/UVts49NvRox5QbFnHqHBRgp2TqSH3JUh2
# DATA 3ZhydJ1SmqYX8TCTur3e4JxlgP7C1dRSam7/QNu9inns8sG1Y4mgxm5upH5FB45sLYRRkJ7nMMairIz/RLftX/B2lV09RaihHUfL
# DATA 6XmhsC9XPgnNxiAbDvEJVMIg19+e5UKh06VRb9Udug5va56cpd0KC/fdHb19+/YjHBHtDdzzSdIjSN8VPkWs5PtKtzE+SVBiId5t
# DATA bOBpoCsqT1ycoINPSa5XE4+oSAvQ9VcmFuWhXtQ0JErRj6fEejFUReHzH6gKbfyFy/5eyw6NNJXqUFG66IGsVAzByQD8/bcUMph8
# DATA pPat+2fKhYoSSbhycwioygiWmwSIKkVFpdYtqCaydhx1BS4VU2zH3BZDbkwJ8+Qnjnd7NHG/Y6GaIvGV5qO531whIUElPuwNDjkR
# DATA ArM+JfY7jCDnDDvlrcRNEWdrFuJ0aZVCcCxpdCFMYOKhVWScRg3y4sak2u+FTPMJFubf/SkIMjB6S+0jz0bZUydRTofc5CrOIFBu
# DATA QJx8sxm82XLI8aJVkke6KSTAZKkiR2xzrAhjwrPv0r12nBxPt3jSCtH52jMy9vj3kYvcFbdNK6ms+OabFok65y2sLFvfNA26cvjl
# DATA +ixtDhwSS+LMm+TaH3ATrNoOWlUrMa+1ZRz/D12H9btCPnYZFV4VPahmODiKn0K9IFQPJ2Nnc0QrIpGI9ac05+dol2f7OChzYrc/
# DATA JSz3F06JJwPrFjJa9VdG3d4icvHEiFQRT5eGSAXc67fNMKC0ZSHF2cQz6zcOJxi1paT5PC1tR3Fq/spoFlYtTKHpUD57FcKmZgc0
# DATA ZNvWkoAigl6pT7pRxZHyQcGoSFS/OsP2mJHR7mUOHM3mBfB3y29oMelkM/p92P8tLy3fu3fX8/9eWoPif7D/+2bs//ZGST/nSwkM
# DATA LefAAkSG3ku5eGigNCEdAQdrnL0BTiHlPJiMuSzFFYEiaPGe9PL5U791BsPLt0/qlh3D4PXTOBnP70muUr2Nekhyc+QZ9x0aYaNm
# DATA lsYj72hGkSlHYpYa/pr06bebQg4vMudl6QOiHKNbGF524qLbJEsDWstEg5GwMQCq1VQ5ZZs1Ky/bGYIe+qHn1pMFDOdui/TynwIM
# DATA UJ4WgL1xd4CW7KDwKnqqwQPTvAYOGpnIRtTNkuP+AAjrDss8gHamsDPjQZSfDM71QSEgRweFqNmJjITd3+jEiO4bKrPmiT7VosGQ
# DATA T6fjUSkBHGkJOceXzcuoJDiu+IHrtIz5Z4MzDemPU6PM+asxj1QBrUX+TKxH/hUVeW6qEzUzzoYwM3lPcQT/NzAL/4oStkJHpAJE
# DATA MxXXrC2Y1kelE1Lhjmg4leJ49DLhFaOIku2CHGPl7UY9VT9m9KNoVsHy7C99swtgx17/zjWuwDHrULHAgY3bCQWwsK2G5ULovHz2
# DATA ITPJ+9p4OCvGfLgWGc8MiXNsLRCbZkBlCmmejBu77a2nzx5vVjjS8biN34zNLBb8o2hpAGixPDQ9GrVJbQAtyHkPiLdN4WmeE/O/
# DATA E5f6c1hHYEmZ7/wV2dj8FmVIv0P9Mm4LsKG/hpUt8OS/+eqnrH9H7vtf2A6RFPa//urfx24gyLastbCqstqOkUWMr+KmOY8YDpQ9
# DATA WZoRh3+OSa4qj9GPcXmWlylB4xnwWijWldWAF8RickgL9Rae/SQg4XE1jSwVFjTvwBXIZFBE1/XH6DfvBcieoEzFMpVN4Q1JeytS
# DATA PhwKW7IK4Bk5GqBYXQGdXEBcgX6kjlwBopyn3Sfb33PPk5ad6iI7m98tFtFfH2/tTPm6++yR136pxHV+AInHjqDSz/HQ/co+kqwj
# DATA tw5l2JBwyvgYetmv+Fbdv88KjtLLc4OJ/QOcdxbu/CNN6Yvoq79goIYmudMnBNeJrL//Wex31UJgJYB0pG9GAdKv0IIXXrHJW8Xq
# DATA 4N4SEBBeL7+MMH+HNvJIhsPeZduFdvwHvcqIkXfQqWJSqEizJG8I0REDlCENctY0cPl9vscHNXz/rL3z+Nn2k0/hrtITHK/NR3vP
# DATA dvSL7WcfPXvy5NkPJJiqzYTK/YBiR3Q7TJ+OlrHi3HnrqpMkUg9KQMRBLVJvGDocOCe8CJCVxks3JCDJaoiBUjjN1E1h7i/ZSpBM
# DATA fX4t5gZ4KhAAi60Tgl4ubtEQjlkt7WhYelGAd6FVxSXn2Hzmq5muWgCOP0F9sUW/vx4LwbiK0HinB9Sl07P48GiWQuwVLckHErTt
# DATA rGsHcS94FxTlatZpYsUipwNm0UvalW6kbWclja869pH0yZzL22GJACLhmZWmdZHkfaxFqClqndUT04pWOaWS8aZwg5LrKoVJ5hgO
# DATA uiJzwAC0AZsRh6ILzoINq5zRChL2RgUDDg3LmslCoWn4VGgb3tmNO5up7pwnOp2DovkPACH/kShAMh1UfWN1RTAWT0nVpu8Mx+HP
# DATA kdbZDNKstOhh0ZsGl6awhtqFCEvwoZr0VazXbqwhUOp5ILEyRT/OQ88BUUZQ4kvWRkSAmFCH8Gs2oDZqE8IqZLr/T2RgSLaERHqT
# DATA L0mRZK7xCGtoDCu/YozSzHQXvdmPUV6wKy+1WarEXG6fAFuouDjtDYygwsU6lqW2FIa1rxZoYPpGL4HPxqgdwndzJdKiNRc5Bw2/
# DATA YacjZUmPjI/LKUIDDRwi6R9h2XmIU/qVOhNYBaWlxuchMMvng1FXPwMnMXvn/s74U/yZLTxxVV2EOL7EHQVy4M/ZAp4RxE8II/wm
# DATA oo0EQkT8lpBU/+qvSOX0r+UMqA5kZkQWlQqOnXz11DbVZHp4FvDXn05SjPSKP49GyfGpSaPihEYq2wqJtqRisUEBsUpRkW7IQbKd
# DATA 9s8qKJKV5N12eJ1X6aW81U2HvNKSMQwePdNG8Z9UvtNML3BH9qOX44P3qt/Bc2BcbaBF8Z7Bz3dajTv/Q2yDUUyXnaKQuyKtcowj
# DATA pKIaTz24ih84KB4mCdDl2WU0ajdx+AhDWvooqsaOeslx3qImp+gTpH38ozIhq0TIlF3lvWIH8skJtQvVZcGHo8HFJYu/eRzOJa1F
# DATA r7J+txV3km73MjZyF722le88uGWlFW3UD6ru4nJzvL6V7xTKioYTZY1o0UT0qNCaGoZU/ATu/UG/N6Dw1VxxwY3lhRTEpG+2oR/a
# DATA B5mebIFe/C3bKEyNSv0iw3Zs+aGVcMiNCCZHBleNXR+Ps75j864unZwQXJTT6p9UXuZ3KPr9iNS3L/P3qpX9P1mHs1pZrxbCUlrW
# DATA EDwfSWZIf+Au0Qbw0vGrFYrrx79XD/jEhTRIQIoRNlyyDFb7djgZP7c5nUMrzg2GeECbCo5WUQxKyPp4znTHIODbTtRG69bJWGAw
# DATA xM3FVzF7onIj+Ep+q5auVEvFbDiucxVGJzliJyt7JFw/YHDSJ/wuC8pN0H27IjkaNeX6etPI39MWFg06NNhBNar7L6895pbWUUWj
# DATA o2ztxbNjZxfMHWminNTZmOcfEKkgd4kY4hdEQHyBtAIRCV8Sm/kLfvM5UhO/I1uFz4Gi+Ft4+xtCOqMUfSRShiDrNhNDjAwyMeyq
# DATA QQIl/eWrv4nLQ+npdJsYDqgWWWKZAp3GKEkLho0QDgFgy8iT9JWE10JhYuM6t1AhZXkhv09ROEqoTMvjaHh2k/vQ1wFFaNWSrEJm
# DATA McoFrtLMUxfUfSEBFf4qv//iW3TKEi9PMKvlHvfv3y/vgAKxX9s7AqNXmTW7mfIA0fsh0KNpr3Vg1xbCq6L5REFiqqP+GQVNQ/04
# DATA EZI1k43DJMKbiA0klWCqGSuKWy8FJ51GUxYDrOk29/mXEzp235w1kvaaASFHQBWU1MMLiiZIhaOi0SIzBuPwpB7toigfpRIh4icb
# DATA DfrEEfOKAt8w5mzceYAiKnFzkHVCAg+q64XfVwQ8bgnZglmyFwXshJlRKiF7RP7yqw+xZVZAW0lSzsK28liQXsOhmKw8B66Ly3xU
# DATA nnW1MTgHD19kn9RvIGsDFVI31ND1HtscqPntaO8kBYybjyN16vA2JZPxyWCUwa3LzlJxPOyn5ziodSFnOZsQ672GGLh2PBgUc24c
# DATA KfVU1i8bAklSRtkxxaltudeLNsSSomvHPt73mgXXfCuQwPwR8dIg9uvLBxxYVhHBZQQ1E56aioYe1VCDlLJjvBGEMxYvYFq6gm6a
# DATA vG/XblhFs/3lR9QGf16EWq6z75Q/IKN0bFZdUtQJ0KgQoEv0Q/3SzYNuxU6N5SJxiEBAmD+CU18nJ1QjIZHXRABKoEN5BZfDcyY1
# DATA jZgbVBPzdutOYXdHcU2SbalRKoiDtl54HWXReTLE08tEcI5Ry1EM08CqlpG6a28kyuQKFlVzFXuz+E5sTPFVqMQMaKHRcNATazB6
# DATA BxtQJz34RMwLnbCituxFWcUHYjbuS4JwJZaoRXcsWQuKxrMOKZ8lPor7nQx3dxWYpAIHXp8EOovg1zYA57na8PZAi4wolp82758C
# DATA xVVgOiXEVKZM6J1MG2bJY7CqFU5A9bOvLH4PB4NexY50J7950rtj3gUNOCThllptPCpE1BDwbkaqe6rWJDMOoGfSIf6o8DGydXnK
# DATA NVlr89wK/Nk/5yMZQlNPxkw4lxnn1xatgYNEYCgEND6aSKMKuvLZkGP9kU8GetQM4f7CzUIawNA5c1cRkFCXvhuXp724OL7KlAYo
# DATA 7WNjfIGXgZXQNG8ylPVLVAs5Z6dYOATmUdDW4nJquUGKJipFkb2SprnC+xqao7RPU8CV6gVq04lGtZ8Rqchz1qcQp+aVDFaL6wyd
# DATA wjZLFfXFZN/TfTp0L2kHjUj3lg5RhImbTBUtj0bxIcIehcYJkPUGk+5RL6GIi/FxBw95dU6DkV9wKB+S7GG0GB0C6rekGPrHaO/J
# DATA LnJlv2YeCj3dDdMEPXW1WFb0G3OoUIw4Wi373EtiaugVwTj1+ThNSEqPVG836UHNt1uBn7C1Acoz/ww5UGRR/fkrUwo9JFeIjmPe
# DATA hW9Plc21Hmc1rDziSeLs55zgfPNDXvhzkd1+OW12nxflsz//6i/9WZP8mi6CdejxsaIvjd5afvC5vMAaPefsUmtrqwLgL0bJZbAT
# DATA +yYypWU/z+hqiwtLb++b7mbtBen2zMrTB/RKuXIXgHUQyTCjHhCTm9WqmTldk1Zldfb2/WeWq3/1N9HG862as1kYg0GCMvw8+gRa
# DATA LujxTRgG0ePLBuYnyYhFiTNUl2K5EFJD4lGvOMg9oDnCVll9Ri1ZpawEqOQ65GMXv7yiPa3Shhw10IQmVlC4GurETKBJhlKMrAc9
# DATA XIyKVt84Ghoze4brErzJ6GnmUAFrc7rgUi54huNGj2QtgN3oixHF/N6PYe77Swc3G0uhN3uVca8e8zSLbclOshILr4eUrLomhLCY
# DATA LA+dY02mTdACbrxB7rLsF2scOIsxfVAap8y+g//RBD8JSyinqjEb0et/IKj6V2Rw8XPUlX1BxdlzjHXESsWGwfO+pKr8XrDSz+Xl
# DATA r3Q0GV4Sj+SAlyS8w4+8TbFaBUOntPRquASJxrwOTg55nRWX6P8hR7M/t5eGzZEodIyxz2OVoAWKDpPOq8nQUubzC7YnkBtXd2IG
# DATA zkhvy/Uli7JKlIzmSXZGZSMPJBaCyFU2+qOYpYpFJijWtMmXGJYO3sC/aPHHx79piMySnOPXlD0LSSX9yJxBE3g5eBieYLTRJvxg
# DATA MpYCxPFEZFj8UL2ehaqC5JSdwYBjibcNbvYx+HTM7FkQOAROtYAjWaJrFGXAyDo9W4SEMjed0UR2FJrDrZbXtuf1RDwJfvwIEMw5
# DATA pdF05eHFNi3O0G2atyA9OgLUgyK2lthcOJtyKwzxJEdEEZfSLK/0oB10pU5hHMzxZls7qIgClpjBlS3AcfNKWGHBPDEDlBU9K8mT
# DATA pzGBj7AYi709pcS+hHcQZj0o4tFLWZVgydK4sqUv9qmypVxgGTqDdVZsTo/1yrOZdYO4XaG8S0XV5oDpcAq1qG1dpqNRmp9UlLel
# DATA Hn3Np11qU8Th/l5pX2a2JWoz/Gm5fKZa7nCTNDs8/HrYgc9WOB2Kpjv/CE1NVCdyXOOs38jTsYTxr8SSAILFWG7EB1JmY9gFqtwM
# DATA pz2nj3yD+F1c9fQdVMLRd3AdnXEPDTzYIiTW3TnospB3ms7I4lkyWuxlhyb06SIg0Hh+G93/SzNSGjlyzNKfsQnmP7JfhHbQ1saW
# DATA v0JjdqAf2CTzC2TIgar4TzanxkTEF+TUbdMnnyvrG/j339uRkmiNlWDqKkb/WwQyhxllXYglmxljH3Mn4bZ30hFm34Mysv7N0qUh
# DATA tJd025jyWxHcVkQxlKL2ss/Sblsfl305BNM3dLoC0psMoxY6AFby6kUFdeVAOnMunJelA3u6geN0PX1IgeM9bY4YgsQ6mwdWKmI0
# DATA nLUWymm4uKB66u59KTnNALvcUNjI30qXJuqCvNAhC2ixjYmyPkGyrtr636+n8uURI2k+7nODFOhCNlAxT4QO7JLSBND8jmfVnEbQ
# DATA /8k3LiAngL8k24Iv0VZRkfu/mmotLVd6nU0LfitBH3/G1DsbxJWstZMT6+LS3IJZ8HtfQ9GDYBP7KxxRwxGB63WreseprYwZAivr
# DATA xBMP75Hss2ddU6InIH2NFdPTYBrKBaUP9n68KyNwj7ijInhKkzUR5a2j/jhF0SjnVZ963kXAoytKt9WCARAHjKNR8l24kdOJtoEl
# DATA 74qfOWcFOT1EAWI8GT5efuAfZ+dkXLbZEozYui6SAk4TZ7Ckxa/lgnghoKnwBhnYEwHtOnPYbfmUSLebdp/jAaV6iAe8Eqy2gYPl
# DATA EqFYen+GKqwWWVRLdnRjAq5k13ZseyKJieJZHqkow/8zi409Xp2iNZLTYFEC8OU8qPuXEkbWjefCcr1fkIMbBv/+rZElB2YemrD/
# DATA RREBVN3RYWNJUVGaHfTOBremNGMWhel9oHYK/InnXVa0ML2JwpG69gKYlw7v7bWPRMXLkaZfhi9RF9MmnCpsfdlA1eIMTsViqGax
# DATA K5XwHrmKEksWUFTClTRA0gRj3qZn5aRXQUCoOB6anQoMRAKS6bKENxAleBOY5YVQiCoJl3UbR+lbB/7co5PX8eaJB5Tczq/+Xtu4
# DATA o2zdKa6Fd58TdLfldUqI55ssSqYYkhv+kugNOwCkMtsOraxRaM4rPaFVC5jXSi+WyfXM/a6x5MuMIZ6f8ZYh+LY1uiPbDphtbbpF
# DATA Iob0+OE7IennDZjjNvYdoTbeVUc+7NjdXcUf7Tzb3mtvbj9uP372dGNrG7kIWxlgzfz5xvbmE1NMfTF0DYqrOVm25XsCL71FZDM8
# DATA dCDBjKfTBf4HVQfDYw8eNFaTLsrGRYDu0zU0yluteSXx7poBmfbiw/bzFx8+2XqklkJ1RKbPRccKNwzcNAPD/T5bouh12XelWcTD
# DATA 90nWRjTdeXKW1gNhrbSN4oIO/BM4q4GDY6k4gudGCqo0WjYEa7GvuA32WrYi0FNFtrRisFocRpEkcmimUsLoxphcdTg476ddp8OQ
# DATA SZNNlrk1auHtqtYcYd1B1dqQGZ6Ob3yVQhfhYOENbss3eVyvAreqOeVOXbtbLaeycJWfqlgrpRsfLo2GsSW3gPaONRsmZqblhdlc
# DATA ePs+Zm/U1wFhXVSp+y8bpJg9iY7nYJ9USfRUpaPE9UPWWVJqocALKbDCJqZqBGQpLCbJlnvqY62atoCWF+WPQblloSxtXuscfXD+
# DATA um0LNmqVb9kNZQSva3A7rFBsRbYuiaWBmprmMjhAMmaaTj4kk/Eg9s2D317dYrdbapxlp3SQaZmCOk6KZ6BFDau5zWOoRSKwUusT
# DATA 6bilRvzGNj8Fm67P3cRZX6yXRGPXzjMe2RwbPao6rUTPtehfS+3RcqTIgAjE9I7/EBWI6pCWrxwpRrVNR5jBGmCqHPJWxYF39mWo
# DATA zji2GjxM7WbXOld5K66Js1MplDWApCp5J/1bVWoTYzfznNO/iVaiOEI4hY9Uk61CJ2TfSDxsSwbqmchQ19PnYLuvEnQrWxSChv7C
# DATA hEB11WtQjZG1sXfuSFUPbNFK2NY6tnlyJcb8a50T1DINU8waDqcnOwMAR4/VUjvagEoDfjnmmnMb9fhWR2xp0C4LnhCKUsBVio77
# DATA uiFx+9LP07y/dElWaCZGrFFCDkg5kq+Q0/f4UvouxddVdskgY05PYsNOf209JZeFk0hyU6q8IY0wq6E3IxfKVi/EkZURAvY2HhgH
# DATA XhnldJNnU9Nn3OaY663WHOMP+KVyr8Z4jl+4sjbp1Yu2EHBXfUV8vKf6t7pQD9WFcKTwMM3NDbtUtxrTm5HdM7wajXYxRJzP3oyp
# DATA pPu3oyfkQc6hEye5pLfmyCFxHg0nhzCj6MXOk4jjc3HWDnEE53gosMKjNM8b80lH2MAf08mN0h5ng+gLCJDDy6ZQpV5uUm1GeJrS
# DATA WPtlcl1p1oum2+8OAbfY8NE+EaotUispee3m0+2NH2x8f7PNchpYOjbcDMk/aFtUJ1UnAgdAhjlnVHbUZUYUtET/vrFlj9ScbtxT
# DATA LHTgicPnulKBZpApDS1p042sotbQh6h+VlHEG3zMbhhdKBRaSKM83WhJlKEggNWVivAnDMtNhYMivvZaI0SCtk/azVs8gszAvh3p
# DATA hPfaJy6nYAYnaTYy/pVCFLPD/sVYAmMA5r4UOGBcOHU7qOZg+0pUP+jXdR1x03FSomyw7KNUDa2zmur5KMOk8ao1z4LJTtHE3nee
# DATA l6Ltcmt7K8500OPg7+J44oxFTzImVkSiXuFvx18oVEzHB+JQ8hKbN83lfKjld0LTzbGrgjvtuZJdrtpNNvPWQjnOywh3bmtMRKxd
# DATA r+q7UIf9/XytnlLvaGdVJvnLlT1afmPJ6KpunA1RoxHhTQsi0UaLqXnCY9QTEImkrx5kyTovNXLh8vUglNMmD4FlOXAFD1E0uB1q
# DATA 381OWodLOkptN89uOsz1w+Ek63XFOxbYCxKroDp4SuiTO5X9uN6VgHSyTGwCyU2S7RHJQO9w8h03bqe3QAVsW7ZaQeqNkXjSvZzm
# DATA lqnS+opp65FYxlZICN0sRkI0gasbMIzKPkaQTi/SzmScHPbIu3YrDgaRRnsr9iKmk6V7agzh5FUpnazaB5KQ14esIyQAhYNBKIFJ
# DATA R8hyu0ZBsgeTcWt1aUkEyBwU3xrgrv656Ua/v4mFhq2jZwsNVM7Tq5++/l30+lfRx3t7z3fryiXnq58GTYDUdMlfh4OPcIRaMS76
# DATA ZxKzoBnSr+EiUoRsYuYELgG1h2DLDgkrZuvlId4YJrFR+QFzyXgleimvM7aZduvYLPPLYnNeDUbZlPZUrmpjQ72BxIdbLXCaAqbX
# DATA Jnrj3EhyTg2Gjfgsb1SxpCdj5bdHg2+G2kanfMQBzdiAKHZ1IjZU6HUpOQ7Nw8cUH/KM2BPJCUQq9Ra1kz8lWMkbvOQqGWcgoLeN
# DATA VRU2lCak0aojfbHiYbiBHwoMgzbdNeplbiAQLUemIeFMTJTPPBAjgdttTPpksnSa5cg2tQevvOaKNiUu8cDN1KyYOBIGxxuECY9T
# DATA U+M75eCtnHkmEN/Wuji27VTVRLw1Q51Jgbh+K+Z+t9wbHSCPWLvO5JCAfTiFbRLSzg9YCr3SjBEdzejScgBwbpoyVytBb9Ifm9hU
# DATA tbBtFhwIEgEOPUUutHQL3S7sQMUyAUvkKW7gr9JL2/v7hrDYxBS1HH30Os4h2f8/xHlMieWVHfm/kHEJYp1/54jmv/7bahj5QlAp
# DATA uaB28Co3xpQUmC7KVB3cavlgYV4z30IiAifAMfns/WxWiONGZGdjVnY9YiWEIei14Z6jFnnjC+PQXjeBLW7IXRqCaNtIHsg6JA+Q
# DATA +mmXRMHQQIFte5hkCkUWtC+E5szLGgdK4sJO4JdZGgRP3sMUncnuUZLIqHzbTeYioak4j4pvky+uW/1o39dIAJ3usf8NtiKpVAN5
# DATA DUXfPxYJ85Va8qa3A7XIXgPxriAMb72uNixTdqgBa2qXxPigdonrAicx/2VXuR6Zd9exrQKr7BxWqxPN9weRohoV0VQ1TeWZrAQO
# DATA QqiWsD0qRtstxVCHAUCRbAqSf0IWKeKPhhaIPsUtFfxIqzOWxtBfrNiz6a6aq+C/aVNv14amRt12ClIb13DWITcPJJChTQ6Wd+1D
# DATA tFBJbt6jMwsznjIJ/oR0MP8P8CoFLm2P0l4KgNdDVqHJKamLUkI6NLwblqfpIvrgcKt+KJ/rYGg1kX7qK1oEM82ygGgi4wyFUSgN
# DATA Z0fkk13RiafgVtPq9/IIadySP1Mt8PIW1i8XbJYzQZEA3R5nicaybG10K2Q5IQ9vsFRu1bdbLNXWO1uu2fdsGrldFkptTmlkgL7Q
# DATA ZvAtZevbDHLLEoYN3W6IA1Y8sSN+o1Q0pEQg+S81Z/+w03VislMlH15Mx51FKrVozOepTNJNhmMJfOcZ1of5wzmlDaVJmhxhqM7U
# DATA JLH26aFioSfbs1nTTkJdVd/VOrJ4wRU2YLFx7AT0DXCghf0uSoLi6ix/eyUrKnj/zI825pUtFRCaoYo0teeD3CBdFCJ5LPvzOSVX
# DATA hZbaveRyMCEHFgeTF3HNnBeygG9KUXuQIcFtWZhvK4Qs/xDqb9JPAMUWy+qIKl1OVudW0bB8ruQqbxleTCf1KgvmYa5eMxit0tuQ
# DATA UKA+L+SHDglSiBpUncuk6N0E5CG5oDcy4E2eKqZkHsNMtjWsSRSTp8nQ5kFmBQOs6hRnnPGWBPsMTprzyIOEXdTbduDZRIbkRY4c
# DATA tVk80gkQmgSNzWBshq86RfhtUNwtjeKUW3NwKE6CAq9Nlb0mPEfeUiuniON+4mIHeFGJF5NhtohRfxc5JmXMunDsg8/FogoYNMSQ
# DATA D2zXbmURbZCyq81fK943wnsfw4r34NuVinDbTZOuhGampT0dwEIM+lmnggLz5RUO13J+giGJCwUe6OrN8rzPnPWOhsRpvchKS2l+
# DATA 7lICPEBXsHKhNMuWY5u/My7xpu0bSohta9cKxgawwOFKh4PupRuGVo2UJGEVzEopySlxtcoDH3tBw7FdK0BA4CufPdUbXt5ppfdN
# DATA STm1Wf5kANdnAw2MULFTIyfJKYGSWfZixDQkbUMhGWm2fq7TybDxsEqK+VNMtPlbjnSB/qy/I2+5L1ASFyDsvT0QHGRnx22gHm6a
# DATA mIhDZXN0BCB9R2kx/RKZVgFihFIRJtOJ8+jFi63HDZ8ulBykZG8FcIj774jr3drSWnUaWJj/8IUnXXm2K5m+7fzfzlLANOx0uEYn
# DATA nBtXFrqSeS9Nh5UVQZRh0SnpNyPxZPyt55/MbsxKWCq7+ZPX/wy///71l6IKxRiTHLIklA+26C75a52SQUWhZ7XlW6g/b1l0zmz5
# DATA +v9q3K+/+Oqv0enTTxqBs4sDMtoipiunu7Q29hsjvLJ8iDECKM+8SXVFGeABvkri45aSUcee6JnT07M+in46Ml96g1JJ4xIUaFiN
# DATA Mg4MXDc/vQm9bI62hw/InE2g4qfOyNxSWxttmNUMrxyF1dNJP0Y5YVCVQbyxMTqe4PF5Tl8qFn3bare7g067XbVqNtAyMJEqlViP
# DATA LEYDhwHafbT2lWZIK4ZUvHZbe69U99ZsKNPs0UBHxwp1CJwiBroDRHo5TFvPOdkeYHog47q2ejFc11AqznCd5Hi1EFE7fUhAgdU1
# DATA 1Wnandd3ZnrjyBzWT3lkpu2yaLpztEW2KdX1sjISilaKBbwVcEHqGRHYJpoonrfYUw2I3N/JIRbsEslC47aA55dsaqks/cHSeaU6
# DATA 5c6rI2fHCczQLFSCalMVZrX49hsWip55JvIgHJg8GWcpeaGDEtjP7BNLz3Yw32r5XWY/K3U/7Dth3xXrfthxD1hmc9Tpj3sOjHaU
# DATA nh5AKU04SyIRsnHi3EuVGFASDKUquWcf7Wxu7KlMszuPf7DjZ52tcc4b041K+XzUpQ7s9KfxeUy0L/bgYniaTeMIP1Twn5q8efLs
# DATA 0ffam5+4dJWLDgL+jrz/RMJ2J6fD3IZsM4+D4sExDXWOpsZJ3smylhgMor6lP26tVBHCwsa2yTas3aaT2G7jSWq3Y2NomWfH/ckp
# DATA bTj+THqN3a3v7m3uPK1F5vnjF89tMyR+z38q3IBOtnanDXws2a5l44qivh1MziDfRrwVm97SRNj30kumtQJkJ9MXu5cAZk43L7Kx
# DATA pZD0An+l3FhFUQCPxEKbzrn05NEpVeUX9vofDC2mqW1NmBVsAoL2aTNs0igMzU8oYzaSd5+riBe/ogTav6SYct96d/+dJqPPDuFC
# DATA DS+/9bX9hwnL762t0V/4z/u7urp2/556J+/v379371vR0re+gf8maCgKXX7rv8//vn1rcZKPFg+z/mLaP4uGl4A6+qsLt2/f3gHe
# DATA GS4CHQ/gzjaeb3HUHjLjJZ4tj8Yno8Hk+CTkOgPlG9DKggB/RcGpZ9Qo4PXDq9wdq7fAtBHnJI9AwJ8Aq6UeETyq34N8gcwMkASH
# DATA IgrHII2liox0ZwB+1E/sU/22GTnvnTNWV0aj306yLo9BIIkaA7EUAP6ATwKI2+nBhCKtSWO+RzMVmtCFSQsHptPAiggc0OnpEBNr
# DATA ZF34YGdWZKMDwoziXGLMlBdsw77p+WzJoxIAdD7uZv1Glifj8WWlaBrlziB+yuZ/keXWAs2OMjROZhps0Kf0PgmH7T1V9ZuRS0HJ
# DATA kGTrG/K3wtMm4M0zZxCc9YeTsfqol3d7sJOycNQXqCFLrb6JXE2mxl4I/KUtxStIqRKNDuh8iIJupJtO82NYfrgOcORrmNwL+pi5
# DATA Ptixbh9+/Ihyj6/jxaHrcsROJiTZQMceM5mNYWZG2G5n/WzcbsvIWCw3eAUHIXbidRgxIzNK2ssKx+qY9Up+X2Uad8XyTu0+f60F
# DATA KsYtC7UubspjN+ExZwXmnyorcNBWzFujF5g/3qwBEWKDydhOhVyLdNuq5Tg8n1ZLBTcggbUZvZ7o8sr9xhL83zJOljLIYhl8aDaX
# DATA 4+t5RryTng7GAutyxcuxXTpvbRJxatrd3Y+j8aSPM8PLgCVi27Gkd9SgvaRftKG8gzqr7yIStPTBrSXnkIyePql/NBidJ6Nu2q0/
# DATA Hw3Qziwy22l/hV/4zazANa+dyWMwxwJJ1Oxrd0BzibmtC4p0qLl/9rXTwQmIUUaRqdiAYvovRc6K2bHjH0Q5Uqx1QdO8ITn6WQ57
# DATA i2LBcueOvY7XTsBNvRnuWZCy+/EGJ/v7TPyjUbT0YQoc24hgmqnu5xT1TSxJZF2ai04qVfwLLVaeWJngIi4L74nFONDXakPKVsPz
# DATA eMRJaOt7ElXUXaiL+vn5OeVcq+teOayv6bG4so6SFhMuA4TGYzVCX7nKqhW3A2/qdzf3RI+2XJ3DOBIOSvGE7VinB9cH9TV0dHAB
# DATA W/iPBtstDb6dQBhF6Tfxgta5Zp6TEILShqzNUoe42Y5dZcTqilJFWBqJMoUEhkCVhqrRw8ivO0tP4AMvJOHUaDAHJXBoo+O0xLZH
# DATA 0LKT3I9HErIcvZF6QJsOMQURlOtP0w+518lu0TtfXssI49ZWPqhFd5dW8J9V/GftmoqpA/sgWgl3bQvxAYaoCtXS3S/4K8/aGDrM
# DATA 0VGS9dJukzBGpGwmzSSqtstSYCMqQe1ELdrjwxvSVUxZvN/7qkCVPiYrGPRlYdZRYYSq8lMo2omeP9vdw1NBRma+LxcODri706GT
# DATA QT6Yq7dCPtRHcNDHTg4zlXK7O24ojoUisnlN17AAvvsMem9Mxp2QjKe0sSwfcIJLbqyhco3HP0TU+97SUnNpybMz57Ya489QBh32
# DATA 1rFSzVNZ1SrXaQUH7OTkbiS5KlHxSzfMmKtmvDJUGPQPLY1S/ywdAR2ao9lo/qeTpIs03WCccPI/DBKRZH2WOGtrUuT8HBQvGf+w
# DATA FdadKnLUCjIgvMwIVnXS61GM5soo3t+o/zCpf7ZU/6BdP7hara3eu445mfJMGv6FInm7g5SR9VE2Juq9a8JdR7wO3sEcpVCRfEys
# DATA nJ/t02RIBArzREigbDza2/r+JomngfMC3gnNReLHW7sbHz7ZfEx0WHYK/CS9frL1dGuP36YXQ9Qi4NvNT55v7fDbQb99wglzTBM6
# DATA hY1ZOzFc0DHkzehmrkj/VX9w3ldygUi1tMABGU4xLh/006XEubzpYpQD2LhNBTj61lK15pXAau3xKDk6yjqqjL2tS9GDFneBPz5Y
# DATA Wrq//MEHK3fX7q8tffDBsuJaqBSNIFBo1uy2+mTsGMko4OxOkIPN9SaiWenxJdFmgZm18fSO26oYTyLuD/h9XG1MhkOghU1kKNWe
# DATA 5lC2n7V3NncB+sJePt74FP/8YHPze/j36bPtvY/xx6ebGzs2s1K2UTn0NhihaS51H5lhsbVIMsJLR37jB4URIRagjmylnZ69Gee6
# DATA bkcFtaZq0WHaGaBTui5oXwNJ4cMnbh9Xcl8dyYMD+7Sa1zQgfbqN5N7v/Nl2++NnTx5j+5d5pO7AekQXjq8r4rWuiHs1B4fpiNJz
# DATA A0cMgGJdqoZRnIYQd9uOKPHDdDQABJr08wi9I+nCSkgJG1Q0os2Lk2SSk710p8PZB07hOeIOIrngDYfBxcP8sOV3qi8crOaybzUh
# DATA 60xnykAYBT6uw/40tDG60BRzXe62zvfM4Z/UEbllnxHP0sjfsh21trzoEaVGVpXXTQCV6GgyntBW9dH2NI/I3NLIlWz2OnRUjWoL
# DATA hz3lDL3I0T6Fc5cAQRN9Bpu7DvTyGNh6HuJpchlBr33GBUmPfP+jfIgEv4IdyTEZIS44qPjKoK2m2MiqI65SHGvYvoEMrKEz+D7w
# DATA p5jTLxgYJK+VmmIFgF19eaW+ury3stq8+wH8/w8LoRRiGekT3M0P0VsQ+hMQ7nzbVYCjqRcWdeWEwrYQPvaT3i7idQqJg+QqJYpD
# DATA c54K4ftqtRDsKbb0W2h5q2cCoFDiM8YhzMXS5247GccFMm1ffd3gzO3+2ll1rZRWGYXOMD3Iu9hOmjGxgGkLDaMrUqoa1WFPz3ro
# DATA CEirNvgRa5bzk6Q7OEdHwdyahmnmJuB7iJKdzqDXtO6CkFwkdZXANCx9ttNJSz2guijHRk25mqL7XcWMmrXj9PgCNg7lThVrKkrS
# DATA Zyb4XL2hkvZUveJ5boq6wQXU2BTqk/X03Rg8fkEJvKX0vmqFrb14llU/3H7AwW66RFuPzYghXZGjlaLKrJrbgxqpexuYDbE9IWSM
# DATA 7xNtA9w+l8Cn1ZV5xvxcjVXLYx1S1SZTxY8DfhKpOkolI5kLOuUq8RTxFhVUBYWtCo9sexAVj7At2bXTaFhUvxMApVyqbWhZy/yl
# DATA Dd8V8Kg2KGqjJU5V0eDg5359+cA/J1PZhuV7tXtryDdAd9V5NsZ2t2UxrpL3JVF+gmoiPBEsM+6lx0nnMmAjKQtY3J6YmqBzRz6C
# DATA k8Mi+1bTmE1bVlHSGuHEUDfT76Zdmc23o0d6ayIgiuCwjElEqeyVovQM5nB+knL7pyS5IQycYCwkNKVBCkYYcuIfGRJlaa9LVKbD
# DATA spmLUwQrLuQgaKpma/BlLYTAyjDXgQaKEomZR+WAJPmi1oW1COqYobUdUjXqK4WF9vltWnxiWnWM4yD6RvxErZnPul27SEFtZ9qG
# DATA xcmO+4SOrnJYWT4Jrmgjd1Ly5WzcQZGr9OUJInEKUnltHyjEeGaEwUoHBLTUsIz7iQI/bey0kgwzh/VWYBLeK6luhaRP6F+Gdvak
# DATA Zl48vKyrs0NW+Q5MQJJMuwslRykqxoyawI73YVSftim21pIWU5lbsiTYFjiDbcYxPA8rx+QhXi3laZGTnJnoRdTvkGYHs86yLgPX
# DATA 0uDowdFRnlpi8qVatMxWEG6jKs7UzLX6DrfYUpJDfqS4On9ExJ3+ws27iI1o3HDsF/rEwSP3Y3pyk5U5H+hwU42iKTwWNCIcCs6C
# DATA 2Q7mg6q0/GJ8oKJxAjNHimjaoXWWBqqXSURB7CLgu7NBN/Y8ydC4VKJw7stoDoqeiUWRU5VDh/lqovJxP56wsiQVUoy7Jme2nMJ5
# DATA 4Rh0+jTPDS/tow1iJTSO6jqvheJd8KHqJxSkEuRJS1vijvkQiOJXPip0FgSHaTXzMNRKmThF2QaqafMeGcxvtXurMLxwo5vUhPCg
# DATA KPROUTklMg0y5nYiTYt9U517Vl7sVzK5prqtcnCbPIZrB2JQERUebNL3TLrJPYuNJSfj4WRcltatTJ/M1jB6yCQNwD04RF0ytHM4
# DATA QGsabC0uydfrdA5wbdA7U4o/XVbCKtgpuWsRmfqq+E21yI+5kB1Z9e1J4YlI+pcV6yvgAmy/Oo9IFeYFHHyEeoJLZGScBVC+U3mj
# DATA cwIDqlhA1hqaHKcW2krw/PlNW1s72JSvVczBSKh/t8xtON7qoxe7e+2N51vtvWff29xG4Lqj8heSDRSrhyOdl0yJiFtOU083dn74
# DATA 4cZ2+8Xu5s72xlMSvyiZadIF4gla0CY9Vk42TcaHm3u+sbv7g2c7j+3mVBUck7U42qhAHjXKQApN4wwayyIV1ddCxBPqp83TNXVv
# DATA 16KVJ/yKNAF6MLe5IcYLxPrn5D5qBGBBxJUJKVHnKhjRwaDn/TjzKA2bGcFjaOifVkvZNHONNjVoCB9uvzpbDMzVubzhqOi+YDtd
# DATA O9mlQfowV5dMUHy3dYhpfIR623n2mRVfrMaaylyIhX1Dsio0RX1M8eEbJpeoqK3Zol1X+xJYHHlp5J3KpljxZMBbIFvma33ZScDd
# DATA XabxrBc1NSaL9j8oxBHWjdn0l4o+ppgWVUg3WZ0b91qQgJaSo1+xpr+bHR2lFO2KOYJ16nQAa4a4BCheDxuT8bnO4SxDoWshax+r
# DATA xYeX6qftVdEMTtcK16z0uO40XA80ZQhdi9CAo9QmmpqjQ2WG7F1wn6DgBNKUSSiaZUHtjlDJHpUORUA0L2t8XYqg7QDCBi3zjYh5
# DATA 9Lho9APe0EGllIVN/+ReK6Ee6pWOhFBoRleGyLhG6jDpXsJL4GDJtXCyf1ttyG3O8zNRwQWwuJLtcpaGDpAnXHVGNRTUAdoe59I9
# DATA D796HdtDJOENWQUK2OCsENBEUyv+TQoXjZO5rVkw7PkohREcn4y13tzGiMCvM/HciHZI8xGZbXAdV7qjyzYQPb6nQvwYdg/ea38w
# DATA VswzGCxeHdfDmwA3Nn4JgBXnzEad8SPbtJiU+eMTuCQ4tO/QSY+gAqI50i9cpnnBgSZ+hAe0Vz5fdCWyBiPUBwrmRTqMIuwDEorK
# DATA hqsXvIz0ZLKiUIAE2XebUSNggDpQTq8jYOJgXamxA2CxHK6bgH/TYa0xqQ0E8wsydaXmVh4FVUI88GU1ELnQjMAy92yGe/t2tGFs
# DATA k1C/AvRvbwDoVmRMkQ7JwRboZEiM4Sr6nQyjIVO46OgQCNRu75J5wEawI8cz9+2XOLzMiu1V2Es+T0Ne5Vf5kcyXpdno9Zrh+R6l
# DATA eP+G+p6PB2Y9gm7deNS1FsRkIS7OicTSNxi6atrcmamNh0zmZqNuxe0DGuqkZtoEdhS+dqIMhc5eCZJUE5A7fhBEl0ILB9Cjhb0D
# DATA CE6EoYLiuKtSbLj78cbK3Xu7L57ukl0LZ3gSN4hGfpLAx8rQC/B5kl50s2O8niTmiQh5DDk9IDy/7MesDiIKmOTxFud23BscVuI7
# DATA AvqrVReHMkTuChaTZbotR+j2AaI6GzPahfR7LqbM2pwy/BILGKzj78VMRJeMSGbN6q/1yFpukivl1PUEXqP2XUgvwVNA+fE1HXTp
# DATA UsVBJ+Q38j8uerMSPYQGtbHvBLweKG6BnWCdkl5cVmqunlhyMG8HxLrUkXVRbs1kOQeLlsCyt5aBQw91QlRa0THYtv1SskPTmPW5
# DATA bDhAntQ5LFdCVoKtmENqjWEKcXAkl6QmCJUu6UJxQnXhhKbVVt7AQUdgPGnLJCV3eUB8dXdpyaIf2HqzEpvFbkbL//Un/8tdtANk
# DATA flPrFAM8nc7YIe6mM90+Z3lj3pAXsVw2yXz43+w+235MUYhLWRUGOG/Gcei3GshQ9gKmKom+RLkNW+k1LDWXBQCoe6CGMcAlNNES
# DATA dyjotlruYbr8Th0xf0//+Rkifg/+n3dX1pZc/8/l5eXVu3/w//z9+n8+O+9Hgz4Q02OK5dNNo+NJMupGpK9Yj16l6ZC8nPCCAQ6h
# DATA KAJkl3JpbKDO4EJi8WmeoNlQEqm9vZvnyWSc9fTTONG+miZVifYDTU+HeNUXFvbQRDBS2epQzstRy2i28cLOs2d7StLOMS91uToF
# DATA QDvSQRkXXmxveWVzAhdd+VtWtaFCE1UtNcMdBN5uJhbya3HC9bF61s0Uw/UI+okTDOavkiY6yRCt6NqM9fnllER83Dv9ayeCUePs
# DATA p+PzweiVY1+vjd30xjayYdspSblmss7Ylnwbo3ak7bOLXkqxMpYiit1LH7K8fQp/gajMx+7rCSWzIxrOpxftYFkbkRTriNPh1nNs
# DATA B9avn45tY4fYUQBxbmnsS+8PqsJRnQKNwGTyEwqfAat+OMq6QIrXIpN7vrWknXw5Dp1aCnoWqgNrk6yeyHPUEetGq9GPo6uVlWtH
# DATA aSZfHkb31pQ2BomxyrCqxIoZ5+fTRMcQ/7l39+7qXcMNcCvTVkxJ8/CiU2lXdyfTxYEsr7yvRjLdmqbRRHua2vJdNKc55Nyfhzga
# DATA 1dg843mMIfhHUkXZvCWnWY9sPrPhPXJXi5sx63dNcL5sGLsapKP4iiteRzme1+iKil+jgS46EQqBxEa7ragSZ9kRsVZXxGch4cpc
# DATA mu2DZ83K2lI1QU5zE+kuiNqRjyoBsbYgwV01hym0vWTyborofZ5nHTnimKWUPU8PMUIMLcy4M4y61OSVaV6PmjyzTa/2uOXeHMVx
# DATA zNrtDO/XFUHa6+jqagGtIKCdU44NCW9onlSsLbAQWMZeAtS0AJ316Pp6IaK8w0LYYTNcDeA4yohOBgNF9AE9NxihAVN9eQmYAFSh
# DATA Xsq416GW2sLbvcFteQ1vO2MdsJYXpzsaDOH9FZ8VlPpZK3IVXZm9P02GSLzW5EZVr2G0pmFT64/NnPXXK1nya3sIKZkFZPlJ2q2p
# DATA fKEdpSZlw3VEtLqR03ScRL01srMDwHt2r551TuGOwz9n93iVYMT9br2fZscnh4MR8KOwKGjra79MuqgtoncjWPRUvcHpwKWCJR6y
# DATA 4n3l7t2bdu5wtP1RmsBmUiKzYYLpNOrjwaB+mB0zmqkrzT4lq4W9wrFAB1Dh1Flb3iNzNo7Y5bnkdKivM87HHCfhjXfqSmDJtT14
# DATA +H+4KyZ2XAclWloAIcgBkcCC2MUqp7hC8IcYIHX70bPt7c1He1vPttk7SiwfHdBtGiHTkDUO7qFfooUkYNZudowVLUYNB0P2KMiw
# DATA ueVDsX0QDlLoUjRxAuIkJnIzR3oTMBzn/NvDEY67cOB4oFg+nAHXwSl0o15234spk2owM58zWCykVmJfj7YQ6rE8rZ1jiyVSZAW2
# DATA jRcN6bxpql1CUpzMkFA+uXNJuHA+luT4Ncpgt1uCy/Djn3oLYnYus40WbQ2EHf20tG/J+YtO8NCQ6sNbOE47lIv2gg/VM0kbYxvF
# DATA GwsiWgElM5XqOo52g0fSkGE0uHhD7Ki8FDHef2oaS4RsWJmyTdoSkmLIignqORxRaDYutdWND/abyytqlxUlx8iYobSm1jRRx4l1
# DATA CWXBKvY0LWKpu2lx+0dj9szj4AhUgdc3xReE5xTl7pK4qqUGD4jckilTRFmzeew2ZFX08fsOh6FRWoOkz3QCbXkEbXNz6o4m/TxR
# DATA MKRyFHdTstMqouuXHAc7NHAizwXvI0lDS6ZlT2o69Q79e0T/xsLEWP1XizWmlJWUYYhGz7N+d3BeQQd9+a1tmTcIiXT1rGGU7CvR
# DATA 6Q3QvYhsmWFWjwC3HQ6IkkIuF6NdRHLjo84oAaBu0nu/4c4HN2xac3Pt+JvtunUTYJG2B9HgHG2Ima/P0ESGMiagdgk4RraBUTxq
# DATA Dvgu6/U4PunURclpKbwliTXlE8+3PmSHYbY2ZGttOeC9GB6PErpLEeeIkTmRahZNcFRoGb7kZH4xzvnERiovVcOODlt2GituFEBM
# DATA VxGxCa9F4t6YtH1pxc/gdmEvkPDCEbptM4U7haa026oWbxffdPIh5ksxY7NionPfJ7fu6zgM1oIbZXcKq/RmPcoa4c/lu6c8BgUF
# DATA 7Ni9noc/+X5MM8S0maGd9GjCkSgiKa84ym6NBEWDUULmlkpo1Dh9heKcIerRWtQVG1aSA/tRdtGKG3T+6qG4xV60yaOuiTKJbXtR
# DATA JrE3nifPUH/VFpJ6gIW4loPcOP2bQiZoMYWg6l06126Qs9+MpAjU9XwiIVdpQE0JleoSA4xKzjzDH1IcM5KtW9KxydH5ohVHJm90
# DATA fQkZpSqumn39ptlhGCGKZUiw2Dg/yYDwjOGdG3AAXpRm8uVJF8xn1Xs+N4XP4mflFSEL20BtBF4VpObaE5jDLeIJgPxK4WlGeXJw
# DATA /iM4N0srK9PW50UfPSuiFx/9ILL2S7Vre3JxRyrBpKVVAh5R4hqpQjwMH+bj28Zue2t3Z/O7FVVLjZVmY78smbBfrzjHt5gn33GU
# DATA M+0b0+Bt7IWOz8FLQMjjHuYvVa+UVOVl31YYc5DRLsvWdQmiTVsMwcWz0ywZKf5RmsvpPP3lZgMyZ3lxBbSScXnFy/hZ1kZF+ZS6
# DATA 5iwuAwZ18k6CQkdaEKIA4/2l+gco3rt7vQgo6iVqZrmt6lQQjCsuI6GsAJP+qawO233kIUjqCKA8L3NGDdyiAstiU2eDj/eiWMZZ
# DATA 9TMIVeBac0zwmLLZqxxYoT0vr42pHeaoRSY3ZtHDccFMs1Yya4PO5+1LPJ9p1wWIzxP13hlgcXBTb//XMIPSWYSNjLwDIWfyHe25
# DATA HfkfnZZHg57OGssqAlEPvBEOlBY5i/Xp4Cx1AuO8KYaS8MxNAwxupp8QSWfBuMHSTsDTyjeinSAIKsvkqyn+/4eB9UQdrKRxhd5P
# DATA YITaak+nQfz/1pC0/43Q10PEXjdA3+FFmoVULSMYQHEUO8sROb70Mf4j7uali/SlcxfdP6etEL1TBfFkUj/aqH/UaC4evFdViL9i
# DATA EGjlO82aeap+p+pjVH9XaJQz16i4OFMxrn+SFHSgzlCM6oYlQ/jEJISpdKslsAUZbYYgqDAhwzFuZuVAOefX0AiRani3f/7ZHKa9
# DATA AXq/jAcwkMH4hLxnSLBhe+wAzEUSLryfsYlQCvy39uMJgF8Hcdyp7AcQ24G1MkR+7WPeSYPs0MAhNkE64vGAcGH/MtaoCP6tWkFT
# DATA ye7MvrgzkS9NQ3CRzMJN1DsDu3uYVryrle/g14Z49bydeeiTFaYJeX4F6mQWdVVsvmSpZlIfbigG3CuHw9b3gixnCrekuXDjEXlr
# DATA fBTvX8HKXd8UKInmW/MgpN4u0XAGKec5N9IcxrmyLanj7pFbgVUW4TBlUJL1su0wapo44wmyQz7KQEdtTK9hm9ZMIYZgD9EoqEAy
# DATA VOitzUdN021I8QLlQAYv3icbO87goxgDsvTTd6qlVv386p4bsGZxz7LBBCZIOk4nuR6N28/BbSNRYk3DpfTi2JGknU0hvGx3rhRJ
# DATA VOY50XYUoIKTc9o1FbNKbTufmBzS+1zSBxXY4YRNMRtlWHWc1nVeTlPAcr22aOaapSA0et0FdQtIVejYEpXbEbk785aqKJTxkdJS
# DATA bROdmMYQcU5g52oRmrYZl1SszpY10IyLhsoFr3OcWItUA5iHOm9sr8mt+sIPS0xZNXKN4vhUKBO21lbUQqvIAPmIxDlDheCqXmth
# DATA vs9pwgfYgbWnQ9WmhEjttnurSio7u2TZIF1JprBmJEOJ8/yE709TnTKOFY8v4Z0tq3XvW9OdBsYZ1Velad2R68Ig8dTgZYr3X/Sz
# DATA 8cHCYwv1GMqL2DfBQbQWCxvo9NUS2IsW+A2JuSXKZFGkLHxIOL1FVoEUIkbKLezvcomDBbRKb8EO5yeD8cLmRdrZxcB+LW31Khav
# DATA 0TTTzkW1QxrTcNBCGibagrcu03xhf4upzIOFHyRoTf7hZWBgcezhy5hNQztjSo7WTQC/9+ujlBwGp5VM++qqzzYqtfycChpuGwMH
# DATA sG/BPdA7+RZaLqgTbGhR0xHRM1LRhVOAWxdvqtOiAmEz6dHpXmcW7WQP0afk7EVT8FdsJyR8Gb8qU437lChMf5/gafkEAyeDwwPP
# DATA s+EBeD/viSupagu4vsYEjazkdzyETMo5Pncyf8Cj/AtxZyz6wzoq1PQDqfpJH52NrWpanDY9+SADz6lFCGBy5sGQK9TS1MrJMPOr
# DATA zpnl0KowrQMCy5x/8kaZCpVRSEuvru+lIwSLpJ4j3LK/skIxKyR4hEW0lPmAO8IgJHunpHKLd4QA88yzg0N29liHkZhOjoa1d37W
# DATA QjQrOcouMKAyjKfOthPGezM5G6DtF+YCXCQ5xAigRh4lndEgN6YVI2NQUmAivgHCXnV7Y7bjjceG62Flb1T7QCkb3yhjo6c/59yL
# DATA YQ26naNRWONwjsbASfLz8tpi8H2OF4e4TSLH9SO+D3CtS5NrBgPNUXitQjIHOwkw3zDvXmlGgYM/GS7E1SjNuB7u7N6I11sI5FD3
# DATA xmTsazw2iy6+ZqX8mVj8FCkR7OW1A9eXcogzs3xbQhzXa+cGOhmnsem6GDumHBS0dbXlGjOPraAJqyTAB7VInp3JH0yRWwXLG+PV
# DATA m7EY9L4648gR9vUOmmUh4uOLQv73OQH3uzvEU4Ni8MX0d2HqJGZLuMrWxjrdhlEDWFitlkePmHX/mYh61xd/lqyjhAFhQqJwpj0l
# DATA I6ntqYjmYA+qVUtGUr5OU84mJzQuoRq9g2WbmxbwhG5imhT8a6PnnQX1eQ1kMuZikeZnRK1YO88s41EGON31iPUtagoi5NJ+1joK
# DATA z2yfdHFD/9Yf/vv6/b8R6HyNGYCn+n8vLy3fX77r+X8vrdz/g//3N/JfiVN2ko/Z8ZpEIhdjy/da3rC2WOfN7SBTqr2r09GoPyjJ
# DATA 4nsyPu3d0NW7Fj2fjNLngzy7KPH8TjtA2+VB12+T+5cy9i4sPNrY23jy7Lvt5xt7Hyu6z4hcKbM8giXMRSF3ow10YNIbHKOMtrrw
# DATA dOOTtmrjw0/3NncjtHNxMvNRmacb21sfbe7u6ULL91bf5097m0+fP9ngt/f41e7W3mb7o60n9jt81LXRes9qffOTrd29re3v6jrw
# DATA 3f2gKt5bCwxOl3q8+ZyW4f2F3T0YURujlaJivKHtbxn7L/ybZy92tjeeBArULQ8NKUwcVqApYvsWdjYfbW4939MFTEuHSefVZCiN
# DATA PHvyuL279+JDKHIYP7jVHdAhowP08AH+G/UAnbRup/3bDx+QEyLglxFGv749GR/V34e3pP98KMLgB4v8+GCo3iAnZoIUPFgcPnyw
# DATA SM2jDf3W483tva2PtjZ32BAEQ91lSLbE+0n9s4N99meuH1wt1dbuX7/ElGcfb34SKHtERhz31rgMxZUtLbW6wqU2P9nb3N7dera9
# DATA S9HpGjgq8jftcNIOWCL6k59R7JzG+GIsr4lKjxsXUv48PYSrmh0B5Rdf6xzDu7DYzL0bRr6Yi7o9TLJRXiFRre/df3Vtx9SvGUaY
# DATA Soci63PVkD7IjCZ+/OL5k61HeBAxakz7e5ufFrMfYOx9JzOFk/dAjR1XooI2RNVmULtjhZfhKAkUUKsaTMVKpkhdCmEDHB2eraJH
# DATA jUU9c3uDQ8z5zGvYRvfTFv92/Q5f9DMdGSccL6cW7aSdySg3cW+K8XMK67i1/f2NJ1uPaRVVakROdC7LQyDO85rwIrWbWA1Vx1jP
# DATA TVSy/D7JjuKXL8nZ3k847g/sxfbuxkeb7Y3d3c09AsGx0UgiNLYBve3zgLygUi4mh/mgNwEOtcqyhRF9IXECH0MJWa5cMzhUwl3f
# DATA 23BmrIIDO2wBXfQPKGoBNhn0XcQPnHWrQZevwem08XUDmJ0ckUsFvgUre8OofKcJqPbHw1H/x8nk4sf9Se/HAC/2l2FYP+4Nx/Sj
# DATA CoVeNhp3qt+RUSHr39gq8odHMgqlFFWrItqZRj45Osou4PieI8+mxCsGCFXfYEedXPNy6roDoutvfO6cbZWz9zBaubs6xxV4/Ozp
# DATA xtZ2yIBcAzPJuym5Yhqxzp8cZ91+Ao/q7id5J8vgWRbKvsn2Rb7JDVXDs++oOvAcLI8ij/B0p4XYkDMLR8JGTfeWr9UXOiWA6tJe
# DATA daplinHcxrIGdCsbvQba6N104YMwGuXGonvTcmPXCoeBAsIC47eksxSEoAFeOveUq0OOXKZuqQEn7cRx6S4710SYWccaF6aT9LuY
# DATA TIkQ3v6dEQYfzdGx2PiCoX8xPh5M0aVS8taWaa3R88xt5Wh9BETC9mD8EcqSAzFUC3myJAMgWeg+2f5eBftxrHOPgVgaA9jED5RS
# DATA h8lffJcdTjiTzlIVZf8Xa3ZkuuA60QLtfvr0ydb299xEWWaZyLgNtkDpY/TwHm/tuMOb0Zm9KRvbj4C8frbjdloZ5Bz7EoUKQ0Ql
# DATA rAYq7zJoqmWX0JbJavjeR9309/c+qc6zWj/Y2SLLnJIpmHVrWetmVE1AtaIM5+1Xkwaz/WyvDRU3H8E4Pr3xQEgoxRa/BcvwwrlT
# DATA L0gkhYdiee4RQnsvnmzsELvjghQclwIoKs3F+MSFIDakMeKvwlXWF3mfi96xL/RBteCgbG5uWCLdPk1epW29XhVdnrJZ3L1bflsI
# DATA UJnmC9CKWqdJWW0Wkh05S+MOhSdoHRLSq7V5rkJPARbjZ8/EqzyiNK2XpYmk9qfIReGumi1rcIhdXZGQQvuo2+IeuZ3iTsr8UDgt
# DATA 7ylGTfkBsOSo7IjdUqrHZ9tPPo1+rMHjAG2djBqSgWLh84db2xs7n9LHkIKyTf9yz9QdBdk/ZH0lUBxpctosOidgfUIGXKKB8Lk/
# DATA qFSnu2JwdefKmVfm0rnvxb8ikF82fBtJKkFpYi1gIYySjJb2giMFvQd3XJfiYN6zZicRaoh3UwMjA1sz5qw/qHlTsJ8pP3u7z2mF
# DATA KtSrrqWfuJJ+1HWmkAQ0/0cfb2x/d/OxC4RwsHAS/9iTjgkXbe5U0zvE2nPc0dErFHZLozAzqEvMqOCqjC29ZvhA05OG8b56XSXM
# DATA IUudwcjS1luUkjq84RA/Pm+BTk5EfO0vN72UWp2TjEw7TR/ItlDj+sKbwVR9cEEKmkpZAWcW1FOI4NLHr6wZFA+8If4vi21+ExKA
# DATA t9gMLuytH1wMAYY+zNHZndCM4h3C+9JT4/TrLm5QuVoCn2+mQJ15PIpqUvsKu+ttfXGuAyMpvmcFO5Ug2pI9QdmQkiRXQkIpkzeC
# DATA kZktqG4YLqcWFSTQDiNa4Bbm4UYZskmbT7d2d7e2v1vkSZ3h6hCKMm5fQKaDT8QvR+S2FjvOIsaNXnWLsip8LqA4zmDFGblJhKI8
# DATA zkU6IAWMhAU7Ym8z+kCZ1uUt4r8ZWE7xr86aPIa/1uh7mPKMMiJyH/skb+JhNe3ssukFBhDPOdBSko/Z8q4i9eVexumZn2TYk4mY
# DATA ZhqHgy4mkoKmHg3oM8miODSGV6whohIxOAJs+w6mjvhN5iKzaOPw/b49x8DhqIIVaQOk2jsYyyg5p7gsF2MtsbHFs2Eh6+5lf5xc
# DATA BGWrMzIq3WSMAXkOiXOScyRqCld43rtpE15CdLGoGxsuEaixPJqTweKtSMdCXN1C3ULeOUlPE2Upm7PIkk4TFtpX3w985233q3ex
# DATA 5lopRUINznMRsu/LGA5KZoJFJV9oQSSN30gi7WjY3nBIATUHtE88InTj4MdKcYzeYsMbWWvJd4xqKPYQ1ebR5Ama9WT9C1ir2Afm
# DATA W2ETMCMmNSorWzSoylIx/WTkeqH+lJDR6xNVL26X6m2DhadVJaRV7/GwnyYX2enktCzaH/Y1GHUrqL2DDYxWV5gzh0dZcGlJK5tU
# DATA g5zJXi0nJp/AjPTuqq7eW6oeVKtvAGzsdLGZOGvh6vE2HUyB1lTCOgT4eVWdU/qoD6rR+95khFTBSWfb61J8YpNeWB1bplcs7wvq
# DATA P+x/wVqhYCIpfNnoAP2FXVUoA650WkzxK52ZgxK/vFhaIrGsGoecEnn0gbeCkEYBPgdZPXWBZBbx1RVLpa+vneEowp5maWlqSO1a
# DATA nZem56bbAHgebX787MnjzR0Mxbq3+cmeNxJeOYpM6q2rK8qMs343veBRKKUMH0Vc1LWltfCnIPS4ipNDjCiqNMn0tGh1cM1pRHIO
# DATA 6CrHdC753M7mv30BzOVjoFS/u7lryMcFWyyUy+nkdh3Ta0ziOVbZaavacU8fX/eN4kf6nrKQjq0S1rEM3LSJnHQjnms2SG7Dvj15
# DATA soWqr6L6WUPQAwYIpeoNj9aXIvtXAMKaGqrZWekr0/BD9drGQh43wYQe3OcDIw4j40pGRqR1K2jwccGa6goYat26IjUytlBxnriZ
# DATA WkQZ19mKsKpBQ+HSGD9caH2hqFwqwCWx+7RBrIJSko5ezorWAc4GG66Nvqix1Foxfp6cTmtwev03oON2NrcRLthkXOjs8PaR9ZFe
# DATA dwy1hwGmZSP5NdJ/olWVbbZpKu+Y6DB60pICHC5NE1C6fG/72Q+2GbIqysodvHXe8n3V/IE+elrhd9nv2IIwS9bVCsi65pNRTBdf
# DATA 8Tm7iTwsKHcOSi5IkIRTCgkcgv6Q04Q2tisik+wFoc0NpNk/2LEn6/jYbH7y6MnXLuYW0Q/65pQIu0X4K2nwkCHxPx31JvlJxYlo
# DATA yetdkBvLEvL97XoJSeiE2gkaxMIg7eeYC4WU+mxdzdbnbYDHKkl6nmIAetimvIXRaWqYVILDX7zsW3YCiuuUcUCF06wTiE1asnN2
# DATA lFE6tZYZomVoR0tFYa4pARj+s1ahDICiHOG1tKJ9eisSEN9OkbzNf/1miAnniUY63VU3VFuutnXL81Gn7dxduEj5uF1ynQ00atif
# DATA QmFRTZ8lir6yaKjqQ1D47yz4u9O/zREOz8RvtVYvLLaEm4a830Ap1CSCBs8CHzzdBTOFg3Gpd6XRXWC+0lHXCp5PKQDhcYmBHaAU
# DATA jrq+Lx0BJ8drdYI+W/K96XJBI3TBHRKYlAKN4WBYqXoHXpV1nSEcNOLoWGZgqsIOcvulF6YUZ3G9rxVrwddRlgqiyEl/PLLwEU7V
# DATA frKyshNJJzMrTl3abQatz/AjEbmlpWwhGR8MILCYSfaMnVH4RFv8MCraMjdLbZvCBNnezmZRnenfKcyHw4HFF3kmtEHhKbCOiUuR
# DATA lglq9gbnys83D/nxmBuCQcrOUoUG1HN7POA72EjQxwzOXqVatoDTDV1oM9/G/qdMaxMOvGAmRjuqskRUYuMnXNOzrpbXV1dZ1Rcq
# DATA iU4BqpjDNcvDPsyhcypRCIq6PGBqX2f41ZxqXPeGh9BAx/dazlBKS3NOYDhIXvrg8va/DmOIYMiNtzCQCP13A6OJkr19h4YUt9zt
# DATA IbsF9SLrD+gKOnYMdg14rDZn2mbOY5ZQfg8lpS46VTgjn1qNEa6uPHuMh+L3bxuEnAKPijFe79VMS9XZpqiyP9Ti7I7fdoHM1Wlw
# DATA 9LoKdTy7klnZOst556jHQiq9QMtf8+bPZ35TMtBv3PrmXc6+gH4o0pjBPMXpyBmwkqtXZ7D2pWTTDQwVhEL2QLZm4pSITMgjN/m7
# DATA lrGgO7QnZNH20k6Yd9uKOhSFxCPXHXWjbW9X9HZz0y61KUwzjErGxry+DDf0TY+78oaazFdZnyWpIokiYSqJooyeDT8Db1PUt72Z
# DATA 7tO8ps7pZRxKZ+F3F5jivhn4PBo+v0rBvURLCKmgLMQBrZr7KqDM4QIikDVrX5iC1m85FQJ6rtI+aDe8+X68+UlxolRuLhcEtk3f
# DATA M+JKI3kW+ijrR86Ai4qxkFIsoGOn5qYOnkrcSBFpj3wOQ0NEOAAegCruDS4xEFRIami+Ai+j/TQdCvg0Gb0iRHEYOsD1s2WVYsgV
# DATA JNnyS26iYJe0SeDH82Eo+kV45rwpxp+l9ujI8u+bagRxqnHBteJ5OqLICGL/EbD5KEc7H77Y/bRo5+Fw9TZta4c3mkZUB2R0oRWy
# DATA pRH9cRwIpMdez6f5WWc0Lnzl1+SQCzSLhYhq6tMTOBkfPnn0vZptwVvOVRXiZTmshRWJye7KiccE62I9b39Y2CzJ0fgONklbWd7c
# DATA tBLGQlEsKr30CP3tsuOTsYto88u8gZAYYM2pbbUWA4KdXMRFDEtXj6NlZYciBWaH+sajx0+eVDhQ8SRP2+RYbwXwOJr0VRI/daSk
# DATA CY6OBwckGa/AsSKnKjVIXasgQywMSBVtJKNjGhFK42RsnTYFvNNPaLDRHlovZnyewPcDtxcMUIM+3i2nkaJ8FNee+EP80VayXvWV
# DATA 9wQ/0692QIiqeqw4DRBhLCJ9/EA3rFpzmnFL0RdVbIVSqS6FctWReETCHXet+cGu8aYa5RwVQCdSet/Y3H62++luLZIngmn66dnz
# DATA 7Wd7uy+eP7+esod8MeTyVDpkooqSP8Cj+o1RoWAgFx3x3kra60iv1XdzEhVy0eU9sbD1JSQZDttTbKJ4ZQMT2bKsZddE/pv/kgXu
# DATA yMzLVXp7Zt6g4Gw29p493XrUVgpgwLftF9sb39/YeoIm4LYdzzdy3ea9coVrx9vOghn6Wbh69oHBYtZzu0RxpK+i16R9zcSQV+5Z
# DATA sVG3tH3WpMqyH2XSOE9Ou47FXZ15jXS0qVIETbosIipD12yhiGLf7DyxektWzlYKeLdR9Em3lClzw9+ntlJxe1U0yOCoHRS2zyIv
# DATA XcWnNjthQGG59wfjIrKqwTSmRrkYxdxbHuNvTZQiO+fAG9Vfy2qE7B/5PZL9fuO5KBZUaWPxId/ndBb+cOPR9148b2MItWnOzxTr
# DATA sEish0UAKi9jH8AdWouRwZRVt6CJDooGRsm5YrNLeASHOzARYTxTj2mcfzE2uwoy4CRMMInotMFSJwVKyzlAyahzgnqBZpn8QQrA
# DATA WO2YMlMkEu9ApmAGqEUINQmU903LEiReTkGkIEy9GSi1UDxxZRExpgdjcNlaucSOodS+zagXxRFqQWjJDpxrrx2JC9IBKT1bPCAF
# DATA q9X5JQR8Y2ObkjEny9wCh0lm1wP/GNqFSy5HsHQ1kMpAH1gPFqClv327CdzBaArgk8gWI+SRhZlFdQn4coWqxS4s/OCJ8Iw/Qkhy
# DATA wS6RIzSrSZ3LbmGRWjQevEqBhBz0urWon55LkEeVJcmOEaH2IQTaFkzE9ZKhs/ex1bVD5lkowoRF7qZnuKZWHffjXFwprzHJwz7d
# DATA 3dt8atGA6ng4XcBhqVhxstAEiJbIMmvwHLylGfI0t7MCT9tJS4wTPtLaySRY0oXBWmqtgWgzWlZwtDkVntUKxJcNzJoBSKYgcZOO
# DATA TLE6n/1m9DZXyc5vwTSRwk/qnLGxjIND4/Pzc3Y7w0MIYCt8UrEAfLiZ77EgRG996VzAb7lCQi9Jtg4kG+zTjsk8el1ZNqCn0nP4
# DATA jRfOWUIss/sOVtBrVW2K3O2YLze+oB/Xtt+UPk2Em5XprRdj7060MmsFdQ1b267s9ZydswPesUFmMIQQ00RHWT/LT8rgmSMHFQ7C
# DATA snLl3L8+9UUnx7KITI4LRRzjQCoRggxWzqB5IEqh66D00YWohLf59MtsqjpjkvmkBkJiEmgh4AZM0gdVrqaWxpc/zjeAFqbvOre+
# DATA 0ApN6VyL9qSJGq96NeCtzByRi2hsj0PZ5Jo5f1XfUi/Pg/k1Zh0lbuZHcEP6ZCtXemZtkaQUL6r/1Ic31gBKA7WS6/j2ZDeDMxeO
# DATA CdQSgFWz4JOmxA04eXc0+RxqOxqsR6RSxMeiFouLVsO0uzXZAxUm3z4FIcq9yESHqOk5CfpwDDmfwsddOKhF+oE3IUDyB1cLN28O
# DATA gp6KlTIRvMlzcxFSXPca9JXyQqsZKGnH6YzVvFWbN+E49nY2tnc3Hu0ZDyMVhT2kEDdMDVGlpdyTyzpIQyz6nAdvuAdz4SbEaKCq
# DATA hXYMiWgwy0ysl14MgZQlr0brHCxYVo7Fwy6B4pnxxHujGnnLfWnPIx6ZxYh0JiOSYbXeioYSPdGZwk7Yp4P3avJstl/ljs0xeQ6W
# DATA 1/YklMEhvJwFNlQNX/OT5r6bPDs9Oixm3ekLrUxLDWCm2J/X1SV1OR2gBXQWphEi02RJ9ulwyIAbiAikra5ee03ZaAFrKXCy5MCj
# DATA 7JgcuNyr5VZdcJXixXlxK9Xph/6G3L65Y8epQ8ep7cVVx2e9EEE9iOaIZKY2NxQe4xuM05CNbi+1yL8APikdvibIb3izlAreqS6f
# DATA uzmWAfaahmo6DdC4RN8GiFFrpH4guFJytKCq5/51m+7BvcEgLQhUK96HKbCoFrwyNGdad/u4zVh4a4umSHhuMpXABGwQSAOcD6uI
# DATA bubRs+9v7nyKbuAfPdl6tBdXp8EtPd3Z16s4reJOFjeHdZ0lIEvfdj0mSrsklWdCy6kT/iZxoxS4pRGOm9S1HIvNFec0gJt8iiRw
# DATA 6cXZytASU6+oSCNMaRF/VkuJH1tZR+vr96RGIOyarSH0t0KYvivhQURopNBn6Owa+U4UH6f9dERHEiqqe+LJfbSlYlMTbNp2cQYx
# DATA cq24ZGCSx1nSYw9pdVsdMxx5We6Hpk0ywl5fN/FN1jKHm7gnqwG+I18vR0yjfCxu7t7F6g+NIMTNH02uQo5bR9mInEz6mBVKSvj2
# DATA EkrPT0XLU556m+LXNBER7aAYyDYWu55ufV0wkPFct7i7eV23Qu4jbxlwuRgq9yHrBB3PkltsbquyZFTnnGhBmudsOFJP1voWHKNE
# DATA vqXB4pSmQi5h843IUTSXDcyZOwn11FNBGKdHWysGx6u+7QxC7sLz+AFMszHEQGrp6Cxky+uG4FMyAx+purrFhZLFECFltdig5aIr
# DATA yAC/TDAXeKwHhzI2ldGrGYn/vOXYx4gjoA15d+jARzjyTmMuG2VIClaJqWFxUH58jVY8AqA5OCX/EPI5V8EBLEbNVkFOjcSB3uMo
# DATA cJSmNGw6HAx6AVN4NQgjFtOv2AqAh6Y57qBDgI4UMrc8CkP4bO7qwHJmzxyDHUfhZu6GEeUETMyFGTOl5xVdG/fvgvQaViUkuHZc
# DATA 0Hm5jZ+LtIbPPmWgC02jKmzAFLyfVMpm5VvlllEF3RDHSMQRW6Scw4ksWPpqv1emRcrM/5UD1Fkq4p95lFV6UKqez6xYixyE3nOA
# DATA DI6wUYAYmvcKunPZ4EKPznWYcWGCVch6f2CDCauIvDu49n097AP1xgdovkN0I7FjAA+E2IzALMIi1HKyef7Bs7QucH6ZyuIlwq8o
# DATA HL5yOihzfds/cE3aavPV0p5+U4iHml9df3Hc/0oHMPWohPh8fCeRl5zFeJOlnhLoiaNtD7IOmxFnXaiYHWWYnxMJE/MoEaDU8Cuz
# DATA D4mJt4mUKb6xmmu1ini8agSZedpTcv3KnPjegzeM/yXpX4OnWJGZckgyjTJbFsqkWuqLw7mrEQXDYd04JJYdMNKJi6X6seJiGd/+
# DATA VylSEH5cn4L+P4Bhp1oB+DSsbyYkQiIvHcVNA0eOkxGwOOTvjcNcjArhMQRzccGGH6PEDl5EJXTHvl2rCYq1tuaOVwJ0mEhyVzK3
# DATA O3aMHwkhCGCV84cfp43RcW9wWInvxNXqdQ1j8bV6yelhN6FiTT+TWE1lCWFPgZAk1o+Q0k9F7FU01pliDOX4rzb1ITWerE1FuYbd
# DATA nsWjsakC/XlAriz0piNsm30Orst6F3Ms2/LCAZSOUY9eoRLLnnlEc0HLHkcNoaU0twIWIPO6ltuy7puaMbYd/aT1qpBN0KaeBOp1
# DATA Y4tKDOIWAnCx8DlBYitgV1dGfJUdPoe2CszJUFVqpWyiSkU3pDzkRVaMC9a04LBteivlvoLB0ou1y60MAsXn5pu+u7m9ubNhqYu/
# DATA VtbpTbkLo8W3RsSlqp7fhBS1vELsTlXQ5zntI1Rj5IRzI++JeF7GBi2LSvnIqsMyTisXtn+aFrBH2wm0n29uP3bj3RptRgkNfBPB
# DATA TVFxETiwNL85bSKkpbnmac53ABSKOprJnHKNe8gQkdfFswtx5qsLK4Ug4m31Dq1luUc1sbfSdQs86ra9fQla6gtbzJ3PtsIx/kh2
# DATA F/4muZ/t3VJz9pkDb8ROfzOpSeONNS8Kk0Nj9Iw1bwzaNt+59NPxGtd/S6GAKxDwltFhLLxFKzFLpjYdLGembIsMKBh0AbWR/A9I
# DATA 2DM3jyXQiyMyhOI8642N0fEEF/s5falYgZ5b8RYj8Ohw0u8CGo8A/CW9CIGsQhc5AcbBZBzRuqFcC3Mi4Jjzhk6oiy1jjPF2Ip1V
# DATA 4nrdjruGcsnWcy0mKKvB1ObUMlacFViEBFZGC1Gn1uPVq4/YqHO+8QgFhOilwwvGxMQYDs703nCN3qCaHJu5B6jAc906RAoPU4A1
# DATA qUd/sGZOB6YaTFONnxs48ML95wtcZPnJlIKqycALRjn00cniaNT98CWEXvwyigxVzyICn6p3k2mzt6xZV5jLn05gMHlknU4CisGl
# DATA rOmzr48CjsI7p4V1ckhOdwFqzmrVShdBvgRFpUUt/ux1Nms233r5iyP1E7OE3WjSB94MVxKPDDY9yQGqlqyJoxEJrolSjdCDUU3Y
# DATA R2DaqgxHGVwJK/Aydz1P5OVqAXUszVJjBeKCFAZwFVMJQSr0G5n+4niALkY+t4VxBvIxsPOjwoCWAeTr66oTzqCozSRZsUL265t6
# DATA sBDWojpNYCB/ZFwp+lC7TYKsdht3o90WKwQcGtC34wrhHFiwb938P8QqtP9KdtgYXn7rHf+3BP/dW1ujv/Cf83dleXl1bfW+esfv
# DATA l5fv37/7rWjpW9/AfxOMHQHdf+u/z//83GtXt1k8dbu5XLtNpMbt5v7V7ax7u3mbCLsxwAe4KrdrtylLBbx+/Xdf/eSrv3z9y6/+
# DATA /PUXr3/11Z9/9dOvfvL659HrX0avfwe/fvvVn8E7ePP6S/z1+vPXv4XKFsGDTfyf8PlfXv8jFP5JSa1aBH//Enr4zVd/A0Ve/xo/
# DATA QadQFJr8FfYG//8rePvrr34Gw/gp/P1bqMgtQvHffvXX8PEXr3/ZgO5JhHW7eXVb5VCBQTy41R1QGAhKevHw5cv+A/wR9YDCar18
# DATA eTvtwz8PH5ykSffhg9N0nFCGojwd40eSntF3+oKXFl+fZek5hkWCn0qChq/Ps+74pNUFqrKT1umhpjQB9RyIvbS1bNo6GY+HdYTv
# DATA Z1j1EbdS38W8Zdn4sv580Ms6l14HQoTV81Enehnnae/oZbwe8ZL7L8eXvdR7l50eO2/IVK65Hg0OfwTbL5/6gLSw8GGSp3UYi/UK
# DATA g7LUmcwyb4urYx0Cb/wb0VmWT4jqHaeHg8GriNLVAJV7fII8yQkgkpNBr5sTKhyfAGWcAFqM8lMknJmZwITKEUq74T2gpdMoTXJU
# DATA T4wHiBQb0e540r2kuoNRN+tj2CWJJAsEHZLUpxgQkkZNR/3hcxRtI3lzhNYj0Y+jfzvJ0nF0NugB6fdgkQs9IHudUdrDaWQdnhkM
# DATA 9wifF5Mczku+iO8b+dkxfiOaEsueQvOL8PK9i9Me9Wq3RLuUn6TpONQebkGjk+c3rEZ6PlWNtwJD6BeK/AhLIGGfjh4+WOSC8INu
# DATA Al4TTPdHR4SEQFjdBhXUOlyWHjRJY3qVDe3RfBvRFxbahQ+4O3IOHiwmfNuwV6v+ITIWznSMag+bcXcF2ugnZ0CjZEm9lxzysjxF
# DATA ugleZ8eJHD7soaS9Z2fpCO8xtWWVyuH8ZGmuy+0OE7zAkbz3i+MR1GV38DyeD0avaG+o6CKMRxYVJ8ykYRerqvV5IKmZzFIMUdeD
# DATA NRgyLT/cO0lgC4dIE2uHNjji8BtotX4Dml9++GAIxdII68L1uIxOkjP4MThD6S5m/juhC4CpHOkz7gaRmXhSB40I6gLbTOZwQInD
# DATA bRvjFbscTHDrsLISVKmrC70OHz7oZmdm3Awacv9kHE7GY+/CuFvxIRCZqpvDFPhejLcrC+21gurBQb8Lt9ppb55NW4Sx4jnn1Q4s
# DATA u7zgRV95+GwUDTMY2GQIiwSg5WgCizIY9HC5V3C5HyW9zoTUkUe9AVH/acL23RFB+6g7Ss4R4qBdH64w7Jc+HFF3kPJWdtMxRisE
# DATA DgJo1wneLRg46n0pcA0FMuoMgETPUAjOq36T86fnu4gH7uGDIyDl8SQO3RsFp8teCpT6MpeA7ZrcUdAeFHyo9t4ZiklEhnU2CLL/
# DATA UXI6XEd6/SzpXOKAov/yL9GNxs+7pka9iEAJ75PgckD6pts/YPs/YPtZ2J6P5Rsg+XeM498Mxc/G8P8fQvDvGL/Phd5vht2/EeTO
# DATA J9Kevkbo/+3cIAL4s3EnQPpBnioMuqHQJovzoEfC7gp/2lNGuiYx0xwciQMkzB2OFYlVZItkCTrZiJAvCfC8haDlIZJGoeCcxGm9
# DATA NBlRKP9TQNpwsno1QsAwiew07UaHk6w3xhkgfMx5yjDSFzlWIWpLjU/NAHswGL2j6IHcJwiYHBj0e5eNaGusaLgO5vlGjI8LB2iL
# DATA JM1Gra1IgaSLGIbEizRE3JQ6kQV41/Oc4hhFu2n6KvpTOCtorKWUCydpb0iyKhxklBwd4S4hQZIcpeNLPcNPB5ORwdEyNaB08mg0
# DATA 6WtS8xCNndJRI9qUREO4pDiPyRCpFaQz1SnEM54TDQMFMIXCAIkkAA85lkl6l+OsQ9QNzC0djVHHfwxTSND+Qpm2YVudk7TzikSe
# DATA pNohsaczmP/6k/8tl7milJfsgvLOYAjtED1p7VkjeoT7H5FeniJewMQucebSFtbAoZ5hF+kp7NSRapQkrnDXkwxgUS+tER2IWUyQ
# DATA UOa17ZuRw50Y02ZDHSihVyQixwA5WMOHjwfnfSbzcCHZsqwDJwYt1ryh8TnlIjkS4TBUuOUI4TopH/STQc5bizaFIyLxX6Xp0Fzq
# DATA pNNB2r83wMvQ6dD7Y2wowwiJGHiJFhOwB7aTN6LtAZWb0K5B8XREW4ZrqW8UNjrEAZ+kCkjA8XmK0CYb8xSgafu6wIpN4HDTMZfb
# DATA qm5legHEIk7xHBrTS3FEzIuzkVswYm24lGNwD7TG6zKAidC9BHZolCm/0m6CQ2xEHyLwYdsD3JIR4sUUYIscV+gH/bfoGx8pofbf
# DATA mM2ZD9nMxeHMSSZ/Y8T+m9D674DUd4kmoPfvXB0OLoB8+QzT1xzSKa3Dm2usdAUUz6DXqx+mwAtng1EzP4WmT66x3avTZASnobm0
# DATA jhqO4xGKfppnyahSrw+TYTqqrncGPajCr4Auq64j/Gou3x9eLC437t2N+Au2VV1HK3MA+ef181EybB7CCXxVh7l1r5MrbibrwwXJ
# DATA xusY278+QdNRoPXS+uDoCCbUbKyspKfXSfME27miMl3MBUKXpA6Hv/OqD3e3uTK8uOZDUsv6w8m4xvZbNayBuOaKhih9qZIN/nvV
# DATA zXJAw5fwmbo+6qUX64Atjvt1MvlrdlJME73+I7id2dFlXe6Xeg38KRAtiFeba2vDi/UhEwdNWAmAmdFyYxn/rvMONJeHF1EOLE03
# DATA stavsNAIPPpjd6Vhvuq17OYo6WaTXD7zQw1GwPtRP+cx3bu7tA6sVA7tDAeU73rdW8YmMjCyJg19xdTqmDdX1jABTPVztpgqHAdp
# DATA ap8oVLTlztNuC5XOB1eFidL07Qb4iEkTTdgZxCrdq8Ew6QA32GzcvatmIzwgHI4jIBDyOtCDGWIgqeq+pEPhveMj4r1UB8YvOzmF
# DATA a3Hpvr2Cq40nprnqbSqVgrPPn9VZhq255nEAvK7sE4tEaBxu5UHVeolbOTioFs4wcdLN5aWl/9E5dPfg0JWcLuy+Ov89NkcXT27j
# DATA vnVw1WFbVZPwxl+zXvL4ZbgrcDXXZaj0mw9xvQhE4NrV85MRPDSXrp3mgFY/uFKDW7rWC2KtwvL7S9A2HLbss7RJlBOgqWvij/T9
# DATA Ph5l3fVjAEONVZqZc02Wlrh0g6ak65QBA2rmPrbi33+71TVo9QizLsD+X03dIzW75cbKXdUqLyCMKz0GLH5lN3x/aUlXWYoaa1Dl
# DATA +mS5drJSO1mtDQWE18eDIVQ/WWbox90hf4VkMjdUw0zLiO9Oh5WVxhp2XbvXuHt2XrvbwIcqQPSlNRmprEl1vQeUEBwJFLviAPgr
# DATA gATKrFGrN5ZW70LV9dPkQuawfK9zsi6DOhzA/TyFia7SoFfmG9wyg9PaKgxthRYeh7b8/oyhwVhW7uJyun1Tz6vcM3QSyapDi6t+
# DATA g25NuhnXuMBqavfud06us9PjWn52rE8NZUJbt+6rHJBkMh5cM09cIzsDxuhyVTBd3PLKEhzkGjJMFawZ1aN7CNP1QBhJ2S3NPKs+
# DATA 4iJxOeD+8Xma9ukkLzfuekd5eemuBit62UIn97pB0gtey/u8lmu8livFtVSrtrIEByKIh4CXcCdEcIGoB/yHL96KoFb6e03ikJmr
# DATA 4N/Tst6jhDGXSPVbSAIf+KRHU1Mq6961vG6gNOgKgydQwaPsIu2uf1YnGQzMex0vZX0Zd3kdM27ASuNCl4BoDRZwntQyo6ArbAVr
# DATA XjeApBko4FjnnIH3cO9cqAf/aJs1hL2T037eXD4aRfC/MvhGF5TajxpAOUA3NFcCsYqsMVu6dhcuApc+yo4no1QTkuZtJyFpqNVO
# DATA 4/2VkbmfOKvG+9StsBKzz8L7Xv1lvqMNIfi9pbm7ZI41lQ6faalMAMkdwtyXyV5UAN8F8HfXHiV1FAEwdEvB0uHOXc2xl6N0CFxh
# DATA ZbUG5xw2pbJUg50FsGFGdN3oJKPulYVZLKxzj1C9fwrzyegIXbhn0BfTyVHuNxo2kfuvd06yXrc4TSrSQPF5rXE6Aab0yiYQ6A00
# DATA hN/tw/MBr+E5muXb1MAHwTsVJp/vApBdg/+twv/uIWnl7ROdT2cDSGbnXpcSQl0jGGzEg4Y852Z/fMJrUlnpVyM1l7KdWClSbdcN
# DATA LTf1zzqAAZgWAgldJBJqgBdQI35ErYj18Qe2iLJKC8ndfx/vNr2NbOR3fwnfw3yy8TxnFBZTII4CL84toaQ21w2ULWhqb+XrPJfY
# DATA EylziiSiwi0NJt9ucANXgjeQ2mJjwCsHWDG5Z8P5SM7clDMgMyP8sRbiKK27sMrg6PyEnCURWjWBKSMoqkbUhKmML/UcCRM22Gzd
# DATA obEbdxXVLNdvhcGKkkUGKO01e3ZL61iqTgoc6cXIMXvZ1RzkhsejAOQAvinrpFf2kvj8mLqO6now3m3wpgB7eWwRUXroS3OgCa4b
# DATA JchuAD84xyFxzkakn1bwCWm64oWwcYoLr6Ol+Qg0d5TR0ELM8ikH5N4/vvLkBnBBkmNfOsKk7ZSzqTdohZnIkXtm3r9XZCpLruZh
# DATA 4tG26iYVcKtHF/ggnAkCaTJiphCrNJctPmt5jSAlXwWz0L7wppvkJ6m7wPsnWbeb9g+cC3SL0wMm/fE1XLcrLQe7INLd5o2QPzD9
# DATA rc24+vZSvl92sT2xW9K/PEcx9DXqRniXj5LTrHfZfAQk1gDwcu1l/CQ7VLbvTwf9wcu4dgp/qF33zsNadgEPZ73cWqaV+c+jyFKu
# DATA PKmUL7Ty6HXVZ+Rwt3SFhYmadV3XXexII14Rxse0uGqj+xDROQcB6B/5980ordtnnYG7iF+lgCPWIE5lPvkkQGwjrfY40ZLj0Bhm
# DATA vV59NDifTWULTT1Oh3rXFRhdM58QiOv7vyYAeowiPGrPvwXX9EltHIDIXjLMgSqRHzYDbZ9AQszjk9q4y2wZrUUTR+Pg0bkO43ga
# DATA rXXdgBGkVwTJGYA3lxfry4QbLRmRRTQwzTCYjIeTMXkk+IvFPBVZ6ddRbROgZtE9LRkPRlcK7YZoWT7RCtDpA339x6dpN0sqFol2
# DATA D8Ba9apU6GBLGlbvIewVqYJ7W4QmKWInOizsRYHsLi+TfWaIPy3lP71LuYqcq72ULj+phS53CVYTb3QjYkwRq+XjsTsPs5CrqGxw
# DATA OcQ5l6VAMJSz5StHSsZ416JSVMWHNi9lH88Vj3xWZGzxXKyt0rmgNawpKrd0PCSWYdELYfUPzOY4DMUKi+mE1XTRw/yzn3u6BEQC
# DATA /A8BcjhKet5DUmnm9VHanXTSbv10QNvCj3A7QjoxavxO7U6TjT7gR3KE9ybpZ6dGZGTw/DopRbLAFzUM9s5Rd5GvYU0po3yBB9PH
# DATA tJtCflgiX9bUWVCBqADhDQ+BP32luQ2/0PW1ozFUVltoIQh/oovTXp90n2iX11xcPD8/b5yvNgaj48WVpaWlRTHwQgOiDwcXWHAp
# DATA WorurcH/k9oXT3zEBoDwTC8jBmTmeUT1llfw9xGgILKZWl1a7a59gIaPDx9QuBKyFnq6fC9a/uBkdeXs/Y9X1s6Wl07g3/c/Xr73
# DATA mVP56P9l712XHDmue99XKYcss1uD7kHhjmnOMIaXkbhFUtwcSgyHqA8FVKFRGgAFVgHd0xozgpJsazvkONrhc+IownH2duyIc75T
# DATA F9pjUqQitl+g+xX8JGf918rMyipcGt2D7rmlRLKBQlVW3nPlysz/rzaoD+ryMKJYXBXNaISMnjyRHZrI02SeU5CM1P42vjHfjEUV
# DATA t3eCX3jfXL67Tm1+MlftRedb+Y4eswcgCnkt/MRswLOypFv1Go2mV+82vFqzOqpXa57fqe/Vq23Pb9SLGRO2wl5UXczVdt2rd+o/
# DATA 8tutUa3m73WbXs2nx6udI/r7DoJuVmvFoKLBwOc85unCA07/txrNZrUZ5Rf3TNHXF16KUDv+UaPmj6t7Nb+BV+51uxwZFRHPl1px
# DATA yTfUalWv1vCP/Fp95Pu+1+z8qNbt/OzdRr3r1X2qPrXOyK+29xrtH9VanWLyOv1uFAQLQbablCvdoV+rjvdaVfrnCB8bdLne6Ax9
# DATA ny43m/TPEX0sxbzX6lUbg2Uxb6ysqWr7IlXUWzhZ+Eh5gm+pGn7A8/tbqrEc6KntrW+1mq1eHReM94ke4f8dGINm8Urt1rciP2pG
# DATA 7QPlY7v1rWa31W43D8TCuPWt3qDf6eMJdjvTz2GrXgsPZHn/1sev3I8Ok8j74ds0XfgwGJLtWbnL28cy6gr3siiN8azu0ja6Hd3T
# DATA PnZbksmUd+m3xJr0akWnc0cMAXO7GY3U/Oa7EbXpOKhI0KWluYOyIwzGWaW93zg6rrTFEcYBq51ym0zv1/q3aKZaDLHsKLfNPFUw
# DATA iw9oH3pxnCjcNS1YlWJy8g0Yf/oxdhI9usDyQL4WIB7AklkkTqvqxYwbDy7a8kaMolegutKYLaS2spC084w75dlbqGNsNlylpfLp
# DATA Ylv/KZr6x69g9x51EnF/xjvJJ7wB0vtL6It5t++YLZD7n8yj9OQ+7wtI0p1s17rX3Hw3TYOT/UGajHeWP3d3NKJHrWfVXr7vRyeQ
# DATA XtTPoIXvYzsgxZbnlt4N7+NXbtkRHEdjnM4W7Ni7wXSHAzWscJYzfhCdVLxBMBqhcu96j3Dgn/4rAYhMPu8puy+RAJH6bcrqHStS
# DATA N6BRtntgqMJMV6GXzkcj7zVvR2KxPwwyvGyXLqkrFJRcuWVF4JaHo5+iRcBi+wfepziq3B9SrNQbLhIiHv/UTjUfqpdkK1TsI/14
# DATA Jo/rHw5UXhTSn61If0XijVoyOYwHJxpbZbIFW2yWpGWAw92LkQxOdjB53jVFEUGg9i93Pn7lW+L5/fgVChpiQ9EIiNZ93K1OZ9CN
# DATA +HZQCnKYHK8MU4zRC4c5mY934nA3T81783EvSnc4zI8h+ke/7uvcLDwaqk2kOyLnhsBFz4Le9PEr+HqTmnM8OdDHXOSMyyt57Ocp
# DATA ov/DD97Zlx2XP+DjIfQd6m3e69DQ+zHC+UnFe4SAP0VhyKOB3ZDk6bdGEetlfPxKwNkQ7GP3HzRr0hG+6fiiNVGMcak/ivsPqE1h
# DATA 6+mH8ThK5rOdnV20cUQqjY7IqMgjReGA+072q8oKiQrWN3QpYDaBl9v5lEywoXlnMEHCUTZ4gIXwxhD6eOuIIv2O0lqhMLJ5bxxT
# DATA QVa86IiL7Q49xh/3oRpDf9+UjVk7qqg5IJqO01ToR6B3xLOTnV0Kf4IbPlVR/UtE78dy4CI4in5CkdynB98K+sMdtfmTXzQiozkL
# DATA RIyOexeKEL4iPj/+iXrjX0gPGGf8d4dvoDfq5378E11KlP/YHQ9dzl0JX66fsJIl379Po8poHkaZikbeIdKv9D6zSW52V0vbo4St
# DATA rW+I2n1utDsnUOs0zxQrP975GlXM+5Ic6mDkM84bfXqgo7qTP76kbLi+4H06OdvIKv15g+ygBMhdZFTT1HbnCLEAO/i2t/T2W96P
# DATA 9/f5c1hZdocpKLKAMyST48Hdq5UYiXQhi9C75c+YbDX70OfTUG8mL2zgV/n+utr2vnyP+4E8I2HxlvZMbWfHmVAyKI6ifW7hn8q/
# DATA xeptFryKdTx5mFdwviXTxUY/mUwxD68uQnmYytCEgkJEIAs2wMevLNvJZ0eLf5eI8UeJABeDBJ/XB/ld98TybVkV5ZM3dh1VJkiu
# DATA kWvZL+uifUvF5WNIeI7J9pDaZqKwquasyE8dAVV79Fey7yaHNBmE6eOxGe+Z99LFUi3TrWVFvTowByqW1yxUm7zeqLqj8wfmqhmh
# DATA +ZvqyeUGGvVpbsXGGN+iv5e7e2mab4uWqcl+zmTWJ+aQX5Nc9P7mbyjWqBDUf4136E/yTnIcpW9Q5u2YLKaGkLH4mn5l4WmykpBw
# DATA rtc4MUH3VQ88q0EgU4uVji7YVYNFFyHeQ9ftTrMYm7wmclp2vb/6K29HR+32bR0TRIoDMlXA5Nvt2yopqL+4RZb16M1/wVGQ5sYf
# DATA dyUtN25IQSljByuHOvv5S27u4Nuu3JEHK/mB3rGaj0hKqUjKEDeYQOS3XXVPafiQsLiWcgyjjAcOKnldoksaI7cjtEWrUiA5phzX
# DATA NuDCQ/QixFFVU8pkHchuscbhRmVx7OzevsM248ev3DOHwtBMbuzA7Pv4FWl6lP7vyHeeA3JznyX3sK1up7Z7Awn+37/f/5j+N3lT
# DATA z5KTZMauVi+YeT7NWG5IAHzYjAKgh5a/h4ynm8Vb83f5/K7/+K31oI7QBs/1x9K4ZQaYH8h0B7PdwezzDma7A9kv9IFsr7DdWJ2D
# DATA fqYPahvPGf9cOAE4so5v35+yWh5GtjgEbESf3s5v523FfE7u2TrP/bycajxPuMV2lHL8xeN851XqacvNUC+SIRpmpaIj613WCp5c
# DATA CEb8rXhQvbx4JU26nyBz5U0nk76OhvJj3/nBwtoXm6lkD5QO/lvP8BdOB2fA9A4X7S0qd+jBUHnBHkpnJ9hUbJ6fim5ANgz4RKyu
# DATA UZ7acEHTQj6OPO/RuObBq+thDkJhfsLx4F1KcZLuez+YRhM+5zvgs/v0kDrMz5XVo7CGqHVUJz3ZhsAYJtxNbwZjgQKaKN2ADZV3
# DATA vJKPW+sI8HlijjZZC2RkH+JcmpHh+T6OOaPC4XQ3Ex289+fG3etNcJnVj+QdMf00n8JsyPY92FL8Y8YmVTKAk4daTAhLTTUbMpcT
# DATA lgAYzFOyIuaLaggv5mFbE4Kz3pz1dp71VqxhTl/H6etc1GxbaSBele7OfWxhs+Qg8Br4NiGcZxR4np7G27rhErv7PFuurmDJ8foH
# DATA 2x9YFFFbcvQ1Lmx0QmLHsk9AZ7LyAu6Md18Vn6hugBNej0IhSWjmOdNd5VfYK8bbP/abvIlIa1hT8nlDFC6OA95v1FSbSaIp7z7a
# DATA l579JsexFFXxQpjqgG8bRFQ/ZeJpLpho1vdbW4ymeEboZ+2l4QuviqNVRUrfYyJlHno14Q4/j1wNb77j36pVX72ZKKuwfE9T3dNc
# DATA c49fVTfRh/yumxKtPCnKVte5qVbB6MG8GcxsySMyG/gJNiTSMb2X9wSrdKrVUIxeumrml6TniY/4RVMap2eSAzclCMyfVG7JOq0d
# DATA Sn5J71AzV+5YBmeACZnVAdjSVGw0SrOfU6og/GIMyndpMKT+WYxG7bW22j/G2GjCLZ8NRTPQxqnYkfve3TD0+EysMgsyPXzmNqT3
# DATA DtZQlKonJgJmpJ1DNl0cvWyUiiFOPQ7eiF0Y9LbpfDTiH+dYhqVBPU618f/DLBLlHRGxEd2fuBdTFovEvBaR0nUeC7YZR4HMEhgW
# DATA bEqjJ8K8Js4wLaQkTaTz0ypXbK+PIHxv9XIYA3sR62VypnEHL0XCpfHiW832AOgMZ2c4n2c4lwwkZzk7y3m9OfwMKFZ+SG/jxpGJ
# DATA Zl4QqtaQm80lzUYMLkbnjRURH0QzKtDJoUjbFaUXhQmWDDBuJUoCMldKFD3EspFc8s9iu6KUgtqy+OqwzvpzWshZN3aKcV1cZkak
# DATA EhYM9ilBbzGQ6LIYdjIYYPsXZPq4L8i8YXJMP3tUQjJccl7ve8q4gKQlxe4I4y76mWTAHQPnuSVfKT4rTk5x0JsF7M28m2K4GpmR
# DATA zqTITto77JQL+mTjQEjzmHqsPGUYefd4yiAbohl1Gowy3i4GSwdJPCRbLNO9WkiFN6TejEuJkymnfCiECYuKw41IptOhzJ3EiNH+
# DATA smRMVuNMqQsGsAoeeFopZE063wxOuCden1CUobgqUcY6jfeV/3EQRZSsMB6wtB/N7mCoQeAQexixD4Gq1Uy2YDDdmH5BU8QvbAJ6
# DATA HzKGx2O+IAJky4qZsnAMUlXUCTEWXW9+IpX6ZIb6jE2iaxL5QZQtSaCYFYUqvCioaqo6WanstzyGKjwq2QhNkEedNFpmxKJIK9qO
# DATA BOEtCGOcvZOBTuxUJSZJtfcD6L+ElIlkF7Lth+TDzpuTMcFPPBCPq3YpM6QMtXss7xR7Uk+ltdTpIE7HvDiybG7LifqQ8kbm42D0
# DATA TnGMlMwko7ZOLchYz/nidyb+a7mf8oOrI5kCanoeZGILc+/kvavFPal3ZdgDm9IKxG18yNR4HrB5jKkBGb5U0sF8FqPbCFLW6Ror
# DATA 5UlWP5UOBVwocRuThYDrakqxMrXfnyTHUj/RSqiJoI+EYKtO8JsJhz/DvkrktrRFStAUrgTuGnlsE7vE8iug8VMpY0tDPDJwrZSn
# DATA CykVN2Uf2UiUYZJCKnIckMaOjGBBQbbQDfMUYXJSVpM18wlbVtay88VmfgGt/U8/rRiGzuwQcN70xCbo/H9nvzz94+k3p/96+oVi
# DATA 5Hxx+jX9//Oz33infwDThn74jP79zSI653/SD4/ppse4n+E3X5/9+vQLj778zkB0vqRA5TJ/BWjnF2e/rnhnf0vP0TO4DfScb+hN
# DATA XzHG5+/pB2HqfHX6+OxXOjJ/plv+KKAewHYcS+c5mM2gU8bxJepwevRnVhDNPowSCieN+9oE2/feejgdyfg84h4xkr4hG8ZT6i1G
# DATA ljdCd45YRZxGuc8gnwslo5Ean+ilWuZ3LVQHy4kqPNVSHFqnOL/RPch1g3WWlczV4XXyqmNuhUmXXy4/MBK9aXP3O/KdR/QtE3Z4
# DATA XFPDeqI2t2IwdYCdDYtt+4gdrL1HbH2icCq5i5GNX+QeHDJZFBUM0yGNJ5yPLLefzTBTLe1W1khNBGEOpcSzBb7O+dVvtUNzSct6
# DATA Wpid85PhODvOErgKS0ADdy5pALwkzs1rG/yvZOzfaOi/6Mh/PQO/VM/FfMgZPM9e67oKGI+VA4ziKb56SXoXQR70uvFUrSSqwqM8
# DATA S/FSBb6JJGsylTcVT0lge+nwZDYccyhywIQzaFMEjyqyfCGSOuIR42XmWKmFSvoMuT1T/lk5JjcIjhKMCoo1o2OMFwjchIdTelBb
# DATA DOpc3UFuLwixCL4fmBHHwWRmu8X6ydQxdhxjxzF2rpKxs+mostE0Z1Mr+ZpN/stY/Nsw+B1tx9F2HG3H0XYcbcfRdhxtx9F2HG3H
# DATA 0XYcbcfRdhxtx9F2HG3H0XYcbcfRdhxtx9F2HG3H0XYcbcfRdhxtx9F2HG3H0XaeJdpOrRlclrbTHjQH/eeItrO49rwRc4dzV+Ue
# DATA dmV6/K5Wq6CQ1myUcr3R6hS5OVHUGSiwEQ43UvT6HGi9xTIgfQ61JsGwVIbfaBUhPnXK8CVopHbDa9SqHug2frM78jtVr9YqUXta
# DATA frPZ6S2Schp1r+F3f+R3G8NG56hWa479tu9Vf+RX68NG+6juF6PQr4WNXm9JIpqdap4Iv9Y1iagXA6h1a2FzkdhDGes12rWhykWL
# DATA nmMeWKDntC5Bz+Eaa9FzqPIX6DnNRie4DD2nGUYDP6fntGotvx0aek6/0xuE3Zye02o1/c7V03NUHd/jamzGhboQdPRwW7hpmaOq
# DATA zuNIpXt0XOmwJVVYY2r2hwcbk3bKb1MObtu1JSaGugtHC7aD27FDXMTtqIlmxxirKOMD3skxDMLk+FbVg3ej6umSLAB6uF0vvkK7
# DATA 3Y1p3pb1k0Kul24qrJXJcF6C4Rys2A+wOFopStIyT62s264JWXU1amjTDSWvGQ0Tv/NdqarPWE3xKZT2OTZiIfPswlSJ0ZMXWCGO
# DATA suMoO46y4yg7jrLjKDuOsuMoO46y4yg7jrLjKDsvF2UnHoj9hnUP1PhH9jepO7fViKkGLvmtwnVx9+BTC9PzSPINmXGbg8GpIxPM
# DATA DXoC+J2PX7mx+A5VqQ/0gKJesnhjfos6oEF3sZ17oCBB7+EYl7R8NuVHJ3w6R7+1HKV976/VGXjrUBofPENZU4UyUdjTN9APr60b
# DATA 8beUFcZmNknlxan92cNZnmbqHT9+5R3r5J1JBnWXKgUy0S2d83FH0N0R9I2PoBcPhLmz6O4s+uKpwZV6m8/CGfVSHS+0Fluchj1/
# DATA LECLypzlailK+DYOoyAroFv4RDSULUEu4pEmo+5MzglrJRXeSlc6LbvpGXROAuszYixncT4lCUqvggt1Knp8PZZdRPyWHAZVu6wW
# DATA 9euV7YoqyJ+UGrwSDtc/5nrm5gpvt4X8Z8ThmOjFmZXVq1XejUHM0ujyuajxbt1huk/7qQWFdliUONyJDk3uY3HXVYLuqkvlsL6r
# DATA Pq++W47Xs8odf1p9J/e5Sma2H62+T/ptTj9/WiMqLwdNtZy72KG2mjuGmDVa7oWaAP+5Leua/wJvPXd1eh4gn3Sel/OsJLbJbn3T
# DATA C4hVzTUvnXNu/Odv/7tJRzniVv5PWaIUfc4omOb6q2opkfekpXNIJMBGS1iKYQIleNaihlppTLWQoUzBdEp1kvV1qWNG66NJ7GQm
# DATA x/+hxzqD/pHWoWWtal780CKzx1S51WFx5fOyW2Z+8lk3jfxgtXGc4bJKiskZffSSLrAvmGsK3WuBAMqqrRcqoryiXrSA/u5/rS4g
# DATA XemleN5GMVBFznQBfXicUBtNqWPz9Cm/TJkg1CfNJ/BE0pA03ffeplEeRs44ORJBCkoDCw5A2OAw4m4VBST7h1U5RVrdQpXWk5eK
# DATA ScG1lYvpFi5aLP/4P1cXi+pipFREDrSfpDQZMS1noibCcpmnOT3WdGVdZfnkTQM0rFBMB1HwHVAfnhyrIirakSzNzmZxYRy0Lscz
# DATA GNFPXkp2iq6toPJ++cI93G9Wl5Tu46WoPgrSsce7u/Iu7hjXBI4THkELm0rmkAqG1y/Q10Uy3E9CkdKIWD0WOtPRBBAcKQE1G+hF
# DATA TO6IZ6LJgd2x9s9MnXjy8smTcW2l8yQj0P/9h81HoDcwyEapDAmWDviY7WqKV/pAWdrcpIIRq5cH3nhO488oSLFPbgr5ZGS09yMx
# DATA HtUAQyYSGAbSbFDiT14Sheg+D03lnzZtKveTwczrodoHKJ28W8MY36MsGkPLBpoxfRp5MDlgRegg/GmA/TmqxmcorJTt8Xgcj3De
# DATA ADkFlQqy1D+Zx6JWAxVEFlaRAtSK0FtoKoVkXKqAikageDRtI9Bckey+816ifY9aU4hnH8onmKRCZcQAnXAnrgtWCf88CTvo5RB3
# DATA cXBu50q7hCvNec5eEs/ZRXndz4S6Y2H/5Xpst8y5aSCdYasmWZSH7NRaSe5+RlUgnyPRtPO0oe19j1dB8V5sJVtneS+VEV1F9F5M
# DATA ubrNqGOL8wWToH3PN5LY7EyqiO9I1CCPE+O4yJ1MitqnHMJjQLmNzF9e0BVvngm+FLKAFAx2RkgSsrIW9pJao/S5uU7mepqX0gJ/
# DATA D56uySGggQIYF90eIwVuKQtq8I3SzLpl5ERhVueioraSqMc+E7JYZ1JamPfA+vawERd6m0eF+iCb2SSzeLsqNFEneYMX7UKdW8jh
# DATA /ZfJeLSDcOajMx83Nh/tuubWYd067BNajSuN1KtZh31XuJ+2UnROPHw6pIrroITz3h9ULz42WFjmVD/leG1168J6Yb6QlC+PrVpb
# DATA tJc37NWaVfeXHO2lpYRVTxXcvwWf9qonym7Kspt11XNl71nZK7hy5bRQCrzJCjFFdQrjkOuDLDS99qqWr1TFou4Fv1z2nApLXJ0z
# DATA 1aTz8iI4Dplr/p5tUXmae0+dum1TictMv3oDijhvKhifFBrQ84sQx0LTjEmoU/T0mbJUk5H9lmiqxxOZcbIJHumZlIFIUvsxq1Vz
# DATA NhUoNHoGz72pOxL0Lfbw7CmBEJ4AGJNdPfURLHHpe2TdMRTXMu8rp5hAuBsLNOqJm8liweXzxuVO47yu5XsLwfHUfRSVdKmEz2eA
# DATA vzhWsgUHZCmkZFxgA/53BfH75vRr+vdPp4+B4Xvs4Rtj+b4B6+/r0y8A5VukA/6v0z8z8e/36u7Hp196DAr83elXZ//H6R9PPz/7
# DATA BT37lQr0S4UQ/PLsl7hGv31z9plHX0AkFBAgyISIgzwHYCFzA//sYIDPg9Vf6LsH0THZDjyJngaQrlUQAPTq4wHkI3qQ7NIYEOr4
# DATA sCp7V2F1kx4zD1T33NOdlu6z51N+DZoQh0dGRl/8J9FsPl2LALwLqQsvnGfY7ELt2QEAC/a+7iWum/+3WCxXR/9jC4sJK/mthfpW
# DATA 5pnfjE6iaRyRtaHvf0td8KAyBIR2km4ZA8jqYYyEns94/FdntKiJORLgpkW4fRQg9TVYBKc2P4kH6HQYBs8QZ2yXS5OH0NCJ+Oyy
# DATA mPIwWFELqXPrz7CFYc7S//Jjpjaf6L0nuqKJS5UscWbcYBoXH04WsICbV8vVts5Cw3tacMDNE+Mggc5C2J6FoNGAlzIMXg4n4LUZ
# DATA BVdgE2xkElzYIrheg0CqaDk7jBnwzLSqq0ACWqlWy18roqjhYuy+eHDiHaZBOA8U9C/LVx8gY1hcY2PUYHFR4kQ2fWJp/ohdT1hr
# DATA Y1nEbBr1MfIbU2wjOKAZ11mZmxKcyT46ysAB8GVcAfeSwR4qJ/ezVIf2PajY4vhsIJYDfHRMwFNxUGw1JH+a0qWM11JVaSvzTRYJ
# DATA ObJ8o8m+fe+9CAA5uSCb9u7PYYakyfxw6M0nVEwzOcPOL84cRtBhBB1G8AoxghsPQxtNki5qUF/rHOEyU4RtzhAcVdBRBR1V0FEF
# DATA HVXQUQUdVdBRBR1V0FEFHVXQUQUdVdBRBR1V0FEFHVXQUQUdVdBRBR1V0FEFHVXQUQUdVdBRBR1V0FEFnxmqYNSOwoF/Saqg36lF
# DATA jeA5ogqWV6A3YgoW4XndhgXPa1cNPK9dzNewHzXCwRL6Xqtm0/caOX2v1V2Zt3nBjP1qx6v5bc/3G16n7XWbe36z5vkNn8qLrtba
# DATA XqdTwvK1W91Or7MMy1eIMu/DXIwvvdBCHvptE99mETBZjVr99pLna7Va/ny9miMTO5s9X5dXqvxq1vL82uz5RtOKf93K7w3f3+xY
# DATA yMdGvX3R9/stu7z9PP71DeNv1xcpW368sdnjrbadfBv2uGH2yyMq+a3uRd9fzL3qBq+/CCRSGomGREpfZkEi++0gbPtFSKR5xEAi
# DATA a9V6r9ktQCJrvUa71cwhkf1qWA0HBhLZ6Lc6nUYOiRz4YaszuHJI5AT9+V724CRf55AjlEfRFtYdaparQ9tcbD+Y12qLsGD6yMto
# DATA NoNp/ZI9LCrD7WD2oV1UtO+tUOw7tZWzGbGyEFG96KG4iFKC+h6VJY82zbX9lkU19OxsUbd5eldLMW/0rBX75AuO1hLQcc0OBbUf
# DATA QdKxl9EP4+gWRC9XUxpNPlRKyV1j+pULubK2vNiZYopM7MGFaiLmU22TnOIQHAXSUSAdBdJRIB0F0lEgHQXSUSAdBdJRIB0F0lEg
# DATA XzIK5CLEcRwc3oapR706zphRkm/KV32SBZmgkIvv2ooCaFU36GmqC/ewIXLH373x8Sv/8dt9Jh7eXaozwM/sSPjBVA4b4I0UzK4J
# DATA p4Zw/vfnEs4baPF8fGkcTOaDgHX65VSXnEek5jyVo284VBUIciF6SDfy4U8yBzIa2gqExMIZHXf63p2+P+f0/ZIjXO4svjuL/yRn
# DATA 8VfqcV7pGX1RREz4IHJ+3FuGldeMPufTl4+5Dq1OGe0go2qiMOADssrq3BmPdxUlUbfQCTtAckE/HYTp1swFo2jZbhaVJMfxRNa9
# DATA qkp1kleBlN4k9tvwr6t5imZQtqvKReNtBWKibl8zsa81l0W+ZkW9U4h4db+5OupmvLejri+qerQTRodpRFP1c1JghWVSYF8zKWgt
# DATA zf66nft+bU3mr1To1K0ENVo6iOdVndMacZmHSHem0pr1EfeC2Yd502x5k6FXxTiy3jvJG7l9A4vsi3y+FHeUzaQrkScFz2iqRB4G
# DATA 39w7EZRjoV/SugOsX6FDo36EjEBlIGK+NxWzIYwx9+PHoCHMkhrHwYkMPFKcPPZnWljjcB7QiDOLIpYGV8IWn1AHR+YXjtYrUZAl
# DATA MdpAwPPFO7BeGhWdZe0s63Ms65LR5KxqZ1UXrOrVbKVnSfmq2AoCk19G/OqH4O8ZtSOsYudaR6wnA5d4xeg3Cbo4GsfZlCVovA8N
# DATA XYWNd9bNieCZO46YzFrx9J4NjErRFMv4KT2C+lO2qIsExwWxK3MfDf33YiV9NEzS+GeJkbxRCv6BlwUD8HWilIwilmAypZJNk1wh
# DATA nSWKWDRKzSKiIDvhkXeYjCOI8vBsguy+inAyRIoH99JoTQNrDBOCO6uMcgurCEoNHFsVVkwZCrZNGOm4vwNhnmIHiK0TSrUHPMi8
# DATA QzQ20XwSsGFD9Wrfez2eJKhD9IzG7GpDYBI9nLEhyUsqyCDVjyYZ3Faqh1UmkFSBMb/MAoUuMyaWpu37NhhhlBzqFH6AE81SblKt
# DATA CnO2GAuyUP+Ic7Eiw10QCa/RiVLL5x4/eyA1LR839KZIkX/NWP91AKl2ToRWJGXoKePCPD4LBtw2sneWrUvU+yLnJa0iOlGSWRip
# DATA p2PuwiSNogom8rO9vDzYAZgbp8HMCIbl4xHlBVVYSqNMOJWeEmUZdrmOsL+EqzKO0KR2hT7J4Bvn2DykAGZkHMYhaLD73psJN0kM
# DATA f0aZDCJwymAcoPNLrdgsEJDYsjpX99XEpReowp5bCvpmPcUwSc0VGSRO5IIW2VeTs+Lz/GNx6qUXpwrTqipPgVR/lvdlTCyQmptD
# DATA 7ZXM/hO9zzfkiVFwotDhRVMlo55wu++s8RDKuJ4wHkv/s903YJvinff02IE0TaNJPx5t9y28h/st3YL0Eprdg273fU0BWAwis2eI
# DATA Gh7bkhNqbcV33ZyProxB++LNrxyJ1k2tNpcMdhOpF34idVH07LMlIWz29F4Fw7Sc2VsnmC5ROj6fXzoqEBREA5jdkEVd4TV43WdL
# DATA R/l5lBDdELfgFTaWayM8l1uVfDGTjf2FyXE+7a14h1Bozuc0mIV5ASbA2Gpl5qF9mgLb+rGi2opJUzYrzUpzb0LJk6DtbxHQLdRa
# DATA sl6OovOFpFEnx8FUgxw2KoMlJfp+GrFHvaCGnUVZplmFL5HplhOuesGDKC3grf7l9AtQp84+O/1aMaj+yJirz8/+G+Oq/t07+ztg
# DATA pk5/twi3+mfQqhhIBY7VZ2f/6J3+/uzXp38+/eLsVxTo44p3+m90y5/o+y/w3Tv9xoQGatZq4NUvwLWi/zqm1fNAsqU6jOfhbKAK
# DATA xhLYAeOeZYggayvmkSCEawJy5apzwpxMXBoTdlpwvzRQYJ5QLiXo42R/rTDyqOfI2NO1FmH1OjbQop1E6CwcwMo2QKUTuG56VblE
# DATA ro5dBUnosPTepcgqrmLmxje5wl0NrIpGvana9Itaik3CSRic8D5Cqh8PIgesOq/cts6peh3NgEtgGqU4K8qK9TiON2DAtpy+9Mh2
# DATA h5aJWgWxtuDp9X6I5R+mURhH8EaDUUB9apTC25Uvp6h+MZ6QOTSXHPbG80z6MzHDToTq3Y+n0QLFapOautqeKTW9p0Wv2iQRjlvl
# DATA rIBLWwEaU3WJwf+l8Dxd08C/9XF/o2F/01H/ugZ9qYzF1JtB/mk1lqugTxWT6A2j0RTWCRkeQDCbyOUJTocns+EYK7KS9Fsy1ELo
# DATA HSdcZvwBaGlki6yOUocJmtHbZOAHRzROZjo7UpE2460HWJNN56ylSPEfx4YLtJ49pXZHwMMUYYk64jNdMhBz7FcM5uLisAwCxhPx
# DATA WJCJCbGH9h8WzAveB6g3USgUEL+EBRSAmqJ/sKcCdp5eI5/PEshD9ZnU5QBTDjDlAFNXB5g6bxzZaC6zual7jVb7ZYz27djsjiTl
# DATA SFKOJOVIUo4k5UhSjiTlSFKOJOVIUo4k5UhSjiTlSFKOJOVIUo4k5UhSjiTlSFKOJOVIUo4k5UhSjiTlSFKOJOVIUs8MSapVb7Rq
# DATA 7UuSpAaDQTPsP0ckqeLK80YcKTtTai2v3u58stfY8zsdz2829mrVGv31PZ/+aXQ9+lrMoX7U6dWbizyobturgfpU9/xqZ7zn1+if
# DATA hvpaAkFRJlf7vWUgKL8rAVP6Yxq4NfqobqGX6s2WVfSKgyRQoiK4KmoEUTNaiGij7Xu1DiW76fn12rje2fMbTfVtIZ5RrzdYGs/6
# DATA Yv2qNr1GszlsVf13/UbNa3T8YVPrxVkMrGajFi0LcrHGthoU07r/o25jXPVqzT36x++Ma/QaKpYOPu/VOvRl8YfSSzudVr3WX/PS
# DATA i6COpIVo1JE0Ngt11Ku2/VpYRB0N+H826oi+BoNqAXU08MNBz89RR+0eZVVgUEdh0G92mznqqNNoVv3mlaOOeIfJHpseNktIRbY4
# DATA +/QxEnryX2rm9mTAZhrJzGAd5IdHrvzNG9CHCk64lnHCydLbIqDICnvRIc8jrGybo4eiB5vCibSlUSsH4F1gvF7z2PrBeyWEyCpB
# DATA 2xfoiQm9Oj2lwm2jVNuqaIv5szo5jiTkSEKOJORIQo4k5EhCjiTkSEKOJORIQo4k5EhCLz1JaKA4Qnz0ihJcOb49+I5cGp6EsnoI
# DATA 2A8ZN5XM/JQFbFHy1RNz9SSiHlld1vShewiXCUKDG5RDh8wH+ohiKBePiyAi9ft9Cp5/zpb+/PYEokgwFuh9fN/J0vs+TGbBSM73
# DATA 8V3vBrPhPvsNdgY3jm9kN07UzTZnKD/J4o5Ku6PSxaPS1rkmd2DaHZheLeX3DBykxpnUQV7NgxMvwO8FefMZK59IfUYJGIlw1JsK
# DATA foZs3miUHK8/6zuOH/Lx42maJAN9/hg646ah0viLrSjzNMqeQNucRsT0BEmZUZYgffq45V0vm0/RqUahatFxZshHZNkosFFKAx5q
# DATA J+T0RvEMizgJTR4yVsIWkEk/nY97B9CGiSd8Hjszh6oHcPYe8fndj+DCLSiYpKzpLgraWT9J+In+fAqZbTnXvE5B+w3YEOmJ7KPz
# DATA eIjKkzaAyDpUABEkl+okisJMd2eS3myWirlM5ThMRiGfdUXMKbE0B2Y5cJTKAL8dUpRHJywUbrLNlJ0o67BMOk6la1V0TgMmcqNk
# DATA hqTTpV5yPPKCUZbwweC1EuH3qHpz05Fj2/TWKLUKjwWbe2xtcnbpm+NMn6I/Rl1E98ziPiOc70U/vu+xonrek/exISWCPHo84pO5
# DATA OBuf7XtvsFoz111PA2pQHSjyCBWpDUJsBOKwzDFEpeofzM4Tdeec4zgf00BidAWxHRXn3z0cpcHLqOkEY34dDXRcOkoSvj+fSeFi
# DATA W81UnQYWnXhz3htXRrGicKFa/Awy9QzHyYyi+QMJT/wrHCKZhiM7S2JznjtIx5fTNX9dhKiRddT4Lyxsjka4bWXzD5D5KLwBnNPS
# DATA O12BoHnOthTBIxQFG6JerkdwBZrmRpmRjZqJanvoZjHmXYHE+V3u9o2tpNQkrk8J/MU5yJ0H4mYUbkZRnFGUq5SbVrhpxcbTh5XT
# DATA j6ubVtxHVuQ4HImOnlI889qA14EoFUcaXWbPl7dzeB4WUz9gOixzIadzVC8DJK2uxnrmrj265Xv6i7fz7fMiaz9oIly4mFM8O8vi
# DATA 3GhaUe5uSlBlfyMTSkazDWKpbs8Rr+p7waRaiJqdmfUiIXVN1MTpST8XvJIbRFI/aGJpLuR27X77vIjW1kV0JQhV5q8YrayW9vzS
# DATA UKWpxVlR7Mholt6jvoVah3do5uIVr9X5tmfqrTcmkzrz6g11zzH80zTLp4l0dJiio+SnNDIL02/hZvGN3B3xV6XDJjNTAzmNWa02
# DATA 7puuDm+MHsqaiZ4yYBkMk3qEVZIyY3kuqy/TAraZsMrkaVmFwKQ/n5ZI7NTpg0iroG1AOX1xbG9H33G293pvvjO0X0hD+6KUnacs
# DATA hMo7gPMNsosGqA2hYdHBQHuwjV6oJGE1heapyqc+F7KC/N8tM41KQq/bJhotSOUu5RltIF5r7aPOJWzxLYJwZRIMKoagw1bWPBsq
# DATA A6tUT7FTXEpW7RZ/dVi/cy+NsW6DXYrsRaRLYNTHD2HDsPdfznMx7TAumjs0gcQsMFq27KJUNUXIVPRJ1UEG3sKlTJ6iAUPTUsuj
# DATA aqwWE1073vexZoWYk31XirnI7ppFFYodr1+YNiEao3pZRjFIcZwM27Ot1SKWT+WlJ5xFXBNhNPsNY8vH2iYJ0385vvexEqQW6PT0
# DATA OSqKowbFhT1eMhmZVT+Ko4JPYgUCi2CrI0ovW5avL412p0UOIsOtDw6PxQ76p9MvTr86/ebs56ePAf05/ePZrxnqA3rQz5nh8xn9
# DATA BrrQbxbhQQsPn3599mvghn5++uezz04/P/09/fgrZhB9WfHo0xenX+7RE48RtMf3fEP30DsELbQSJkSh4y2f0xvoRgcUevYt6h9C
# DATA v4zXibk3UbSwk4osCOKSdLRqd2oaHYK/rOWcZeFf1VczuKcs2lygTFNvvJYh9MYwEFUDSzLccYQs61p1CddNElpWLldHE+INAcNk
# DATA am78SF1YzhQaxHk3fS+eGU/wlmlCAjVme0F8RRbR52XnCG1SYlunCd31BLwOEPjebN6LTMmLBz/GHtqxJzvB9713E6oBEwNCpEI8
# DATA gt47JD2wRsAaHjDLArXZJcDnkWz6SOE+HDOPUZx1bHwJrBEisWV40PoqudqIWdLOnhY6aH0SHDTIjfQXGek1J+iSA/zL4Tq7rsH9
# DATA Ssb2jYb2i43sVz+wS7VczIF8o+v1tZarAAXlKYOIFgWQLcZ5Bo8bNmvqzX86vnOTdj7kxDgRXYAgwMT8O/NNsATGtBW1JZTfMg4m
# DATA lLrMpFtSa4IXzNB4Sl3YZLYRNgj21QwH+ZEPFNIgpd4uH/RjWe7XC1sIhsXkGGJkCEBpJFllkMgnAlSuWCN9AsxPMhB0MV5EFdG7
# DATA P0OyY/Z4xAOPWtUDoaEcU0eBPYNog7zBIEXeaYeoowc5epCjB10hPWizMWVDqPn5Nu81G++Xsd2f1HR37CDHDnLsIMcOcuwgxw5y
# DATA 7CDHDnLsIMcOcuwgxw5y7CDHDnLsIMcOcuwgxw5y7CDHDnLsIMcOcuwgxw5y7CDHDnLsIMcOembYQVF1UB3ULskO8jv1frP6HLGD
# DATA FtedN+IHHZok8y7CImsmbEbhoLqKNXPn1X6cwv4XsE9NEqLAPm0WaWB5A99XhKHC7a1q45zbLc4Phe3RPR79tud36W+V/u02v0fX
# DATA R363StdaXs1v0LXWXru7V2vUho3uuzUAi9qdYbsx9uvNvUZz2FoWk0ZtVcQVwOjmYaECNWo+IkNvGO/5XvVIED1rsjEa9Lqt5Yik
# DATA 6kL1pDg3a9Vhq1F9F6ludJtHjeq4UW3sNar0qYwg6gbtXmtZ0LWL04CkzmsakDQfiwZEyei360UakN+udxpdmwZUqzY6zbBAA6p1
# DATA mvVWkNOAeoOwEYaGBtSst3udKKcBDQb9Qad/1TQgZZQsd3zotJZsLTUSYePa3norxKObMezk95bBP2aitGxSpN1omOtWGvsN5v/U
# DATA mP+zuB7VKkZKGzdWNy22CyeEcjxI9w4xNQbPohpGhxVr7d3+7NW604eVb9WrzXarx26/3crqkLoXDEpHOZtG/YtSibTNC+/hgkll
# DATA rcitXhxXS+HiE97L6IdxdCsM0ger2UN5DlfsqK+2OUpmr9Qhtp0cSciRhBxJyJGEHEnIkYQcSciRhBxJyJGEHEnIkYReWpKQIv18
# DATA aB3rys9zF89xlTE8wg2SU96UR5ouhB0BaEag8/TH+wzzeSMZswD6wiFvPt6GpSRRqwpwUCWZqONrWpC2eFBM2qhM5PRJC3fG2Z1x
# DATA Lhy1cUed3VHnSx51Xik+eDVHoO/FrHXBZ2nZBVk+PauPQj9rchvXocetBhdUHaqvSjIcqdzpj8+TaDbPmg4rv2JEmjtLtbmbtkiz
# DATA 71eLMs3NNVLXPPhB0kX1XnzhVbFljYqy3JMLXOuHXk24M7UlpFu83PMB9X0KL8T15NWbiRIJXPJEi7OLxhbvpjdLowesFXnuY01+
# DATA kW0GjGHQsHxy8dmbkpoNhKrf0vUTVdZDlX1+VarfjYJsDtFoHKztB2kuUH1/JpJ81JMkyUxukGPNkPUJDiH2DH/UMY1Z+94PeXAb
# DATA RUdUadABolMdq7C5GSs4TZIa4aE0IXNy3/uAFwDENJIHWG9RCfvRcHKCgqaCiGcF+WrAtArH9uUcqZfOccYbR64DHLCHhqMZz6Ef
# DATA SBYb1Vku/IxmZ/NsGon+IStmB5P5AANxirmUBAguUhgPBrgy77GeeoxxmgJj7M4yW0+JEFASZhsLXL8o53ydvLUzXy3z1dmrL4W9
# DATA elFt66cs2cPr2vkC7Hpt67s0GrHRyAYk27FZLkXBHIVsjcb1dYv9PBd6F1cha71Yr7cubb1U0+my8tb5or82x8SiULZPBLIo17lc
# DATA 1JrNnxMyaQSoyUtB9Lp973XRDaJZkojVRMEEJspHEBESuZcMgxtjRoXgyNUNZhRZXbEWfiYbLiGbh4y6B/QGTQy5WMX5gRZiMapO
# DATA xh3+cimeFHLGGUPOGCr1qc6b57x5xb5zpRX1lAUNmQcMcHEyGonOfhnYrdpJkOUSfvvePeF0s5W0TJ6voOU3TZN+FILGLVJ0SfrJ
# DATA PBJfzpPwue/GBupsaLwzGkE1E3AczwQ1LSOpx1ouHIM5N/LDYH5Io+YHNAxrWmCFAxCzRJZ7FN4BHUYwGMApxq6S3OVpxum3Jxjv
# DATA Z8KvnStaRDTuRSFE0MKol9KILFRkHkJZBBA7lNairGX0z+UZBQccUFWAH5Q1BZVpkGnrAspx8Nek4ixV4tNkA4SjqBek+947sJ8Q
# DATA TaqklLmBAoGFAToYIBF6IxFeG7Iw3jIhQ/6YWaqF4pLNQL3+hAo+HkDnbRxh7S/ur4WRD1nVmivPZAYPDnuRTZI/ApQjGQy8Qxqy
# DATA dBJln6Q3mlOm9gMoNnI9Bl49OA5OxDGl46nKMNNuHc4+HgcoGBVzypdMFLjhX2IV7gMlawgpzJRPFqiKa6pzAawxQ/1h3ojXowhE
# DATA K73OKtU80sjYAplw5oPnQtUQnDIti8yYhBIfg0zC8k/xiH6uaD8UJyCH7fSDND1h5ca7lGcB++1UQEKYF3ic5vgcBSzJl2fSe1HM
# DATA qRI/sVK/hEvuMElCy90ub02oodFoOJC2VizCy8G+0ZZPWPWR+pjXLgz7Rty2DfsWuzyWBq70C+MJwPFReAXQ79fBvFdyoWrryBUw
# DATA vj8qqZBeyZsY7v0Omob0MTSuybacTIg5230bnwL6yFASsUI0DeLUewBvcbCYuqskir8YUx0LLpMEaXgI37qNl/kfCiPzDUNdQIf5
# DATA wjt9fPqHs8/Ofr3Ik/kXuu+Pp78T5AvfxeQXUGG+Of0TffycWTKPK57hyzw+/er0c+BqHuOnPf3UY4++fq6Dotvohb84+6WCy1A8
# DATA zv7OY8bM78CmAYXGQWWeA0zjRDO7Fnxx0ygBAlqN3DMRmH5Dz9fE73HI27YxyCloGGv3srxwTu4yAx9FTw+F80m4ljJzl2/J3+wY
# DATA M4XZnOkZrpsys1guV8eY4QSau74LIXHK69GgfF8I7WcD9MJ+31kanGwTLUNtICMbOxUBc5ppwBrjmRgKwsFl1hfV1qkyphMKYzLj
# DATA +cSemDpkvuIpiNzHDz2uF94HvD1A3LaH2B+5bFO5sA+h0a6VvlFmk2jGmubY+0FjeLbAkFlX81bbKQtt6GnxY9ZF39Fj3JD+REO6
# DATA xslcaiR/OXyy1zeKX8EgvtEYvuEQftUjuNTFcrLzbZNPscVcBVKmnNCcLGM0J/KYU25GgULMwP3GcgPwdE2oSDNZrUUyDD9DhlWg
# DATA J47ilHExKCyNlaGUBxku4si4IQpjNVQG1gtAZE5gbbFvV0I8lG1mmCbQx95IPG6HacTnASTb9VY35Vun0R9SCPz9XB7JAcZ/zpLU
# DATA shmKmJEodbAYB4txsJgrhMWcM2ZshoQ/17K9VvP8UpzqJzLOHR/G8WEcH8bxYRwfxvFhHB/G8WEcH8bxYRwfxvFhHB/G8WEcH8bx
# DATA YRwfxvFhHB/G8WEcH8bxYRwfxvFhHB/G8WEcH8bxYZ4ZPkyr3eg1qpfkwwwGg1o4eI74MOU1543oMHa21Kue32wP6+36Ua3b+B59
# DATA L+ZIr91uN8LF7GzWPL9TpQxtH9Uare/R9+JzVDc7PcVl4bKUspKCOxEOS62gK9HoFsu40ShFpBd12+UAa7X6ZQMMq91au7UQYKe2
# DATA 3RjWG/52Y9iQqrO9GNqFQmW5hTy0CuWCAa4oZatQthJDu1C2EkO7ULYSQ7tQ6hL49lrKBQM8v6VsJYZ2oWwlhnahbCWGhUJpNrbb
# DATA Ui4Y4PktZSsxLBTKNmJYKJRtxLBZs9pyt1jKfr0UorqQqtwvD/6tqF5CcbW6jaCxFJa2DDrWbNYt6JiEnxokmGWk6FAX+Gm15pMF
# DATA 0Ox0rQCa3YsHUEhCt/WESdgsgIvwzMRG0zwzMfcsnlnQaDXqUZFnNuD/2Twz+tqNBgWeWdQJg16Y88zavVar2TI8s7DV94NOzjPr
# DATA 9BtB7cp5ZsrroTY0mJmQOOPJlmQHheW90IvUZn7W4ZXKJYv+xZDLHLPvRmTExkFFYlLai7IkONsRyYs8xdDVuu/50TDTl+W75PTt
# DATA NDk+jDZbKmpusjhthVpedbZ9JrqOFN3ONZnIL6we+nVrkVjd69eKXhhdXXmP5TAIk2NeiMGKW9XTdc7K2y47LHhWbGZzK/bT6Ums
# DATA yu3qagaanafneDSs3CrVSZ4s1xwIzYHQHAjNgdAcCM2B0BwIzYHQHAjNgdAcCM2B0F5uENojVbtjKrjbCmWGz5ToCidJXcTRPWSE
# DATA 3C6qm7epY6M6s4OqFd+uHsSv8hMH8Y0bu49wkW87iAc7x/GErCuyw06ms+Q1GPEfAIox/hGHs/tIt6DpbQatMQhkp1HrNrqtdq3b
# DATA uslR2v0O/1FR6N2GDfhDmr3Xa9Lx+rsHYfJI3lF+xU5v9+BTls3c6f24+pM7t+lduwci+YYL3+agb/gHn0ZkrCstOCsuwn/jAHdU
# DATA PHbpbqU+Op3TqKe6vU8leqgct9XPP03iyQ73VpSD4MOhMdxQP8oC7c5OUOlRcQQ3ehWyHnNLXqV2FN9eac2OYhTMKLYr5G1pHlRu
# DATA 9CZJG80c8Vq28WVGgAPkaPdTbCWYhDujePdA8qj4O69K08RddcV3/Opu8QYMwSo+b+DefTk9TZXtU42sM0c/nbKKU1ZZVFYxh4Gd
# DATA uopTV7mguspKUewrUF35AHJcWgFklLDeB2t2GeGVpyvkdR10OjYF6Kp4grxkwIk5B0unHsp7JPW9oCa7QKTzLSBdy8bR+WtgdGy+
# DATA oOrjA+YfKIoSjE7dk8Po9EMLjLiWBPVQTKTVLDkek96Cd/28O31RAyYL9LwbWWH3w+NoRJ3oOffWqureCZnApXs3R9dx9UYr5xJ9
# DATA bql139eMBhmPMrIeotBI7Rl5HTKyjCyOmO9lqR0myW0m28MiNl6WzFOwfAeCU4H+tliN0HDI+XTitSAjcaJkfCiJJ546dG/EYuid
# DATA C2oxw/odW/+H0lSnghnpQmGLzM5Na6OuKoHRRrS5F0ExJB9LnNHpjM5FozO3LpzV6azO7Fx78qlp/d1n1BBHkl3cQI6i+huj0wDJ
# DATA xnE/TSwJvDlbqEr/LqDWNemDbrGofWcGxbxFqcFQQ0pYSq6fjMdR2o/1GMiWaxphpQUbFzbW/uOUTe/cF29V7wQ+swi7TDCMGoCS
# DATA sH9pMMVeiiX6W+q826KJqtyzqIn8SRmnyubQP+YGkLnCB5+BTos4HBU/WW4QwUEd+aW2p/H5ghOkPhctT+sO01HaTy0YdnCaoi2A
# DATA NSX3xevsQG2cv8kG3Kq7+gmIG9RcjvjmN/Kvq5/hSoS738eHNdalDMzawhMXqm2SYJBYY94VShh7PqRBq6OdOdKBOiXD7mCPtazu
# DATA qLy086KEA+LdMKadizOYa1M659tr//nZ/9kyqShHW+WsMsWUVCVVkHR2IsYY2Xc8MoHJoy1JHoRo2rcHuyvk+aJ3NwwhjUdPCwuo
# DATA j8ZGtZ8nisxPBnsFD7L5J6MjE1E0MRm2Kb1l33s9mORUwEkok1L56R6IMHhJvUqDrKEE6WMnl8rXUu25RPY2VmdvoS5KLsNeFhue
# DATA EjILRjqf7zJPhgaJaUVyTU+sOdcCbAKYxePIhrJNR3OePdP8ci4WPROQlEffuxuPkVcDstayIWBVbHrjkl/D12mSsYm+770F+CJe
# DATA E8ZZf56hgDgkWZTcRi6b9nbR/F2dt6rl6lxFj09d7wwfdJ6+ib09gVf/j9/WwUoKKU+weDABz/wY+CCqW3PKOyoLmeJnnk8F2oXT
# DATA QtZf+hHNQfa996nLpqn3XanYUn1BgGJOEp9X9ODeOPBet+/AGUJxl/BMWm3y2ve+R18jrshU/luryJfO4vU9RCGbP6KBliYZFESq
# DATA 89iYswNq+Hui55SzwKAdSPULlWkqeSgrPpn0BXI3Kin8NIFCj2NCKA++B+1SnAzMWLc0MIEEEw2lqsjL6DcsoUjcONMPY5E8BY/s
# DATA KE6ohaiHA+l5no3Oo3WhzuO/zmNe+dSDty4EyWCqvzTGoWJzBWQbSBtGMh1CtnvZKJ5SfnLj4L4FoDOe3vRY31R7BKGgilFdlFi5
# DATA a/IOo5kUHWchFhKzZBzhwuE84o4DT8cTmahQvzTbSvdx9YPfGzwugYkUm6ptukVxa8yOE+mQJWvRG2eC0BSh5ChOaXQ7Rii6HrOM
# DATA bWwUfmm6jqafqpZPtiCrOuOd1DXhtCL11kdqckdh44lxgoVcnjugp2DshHQvsFnLmVs0V2TZ2DZXzBXJrDvUwNQCrxYSlvFbTEXL
# DATA fKXmNuSGJ4Wyfx7r6UVwueSzLedycS6XJQQF52V58b0sKx0ozxRRoXBUYHGkHNmsBW8Uz3DEmZVQGIkJiqUaTdgFkz/I50k4Y582
# DATA guFZ1io/j59kHfyQVUk++nLnVepIy+1NH30vHK/ryFk+61y+XAhG0h2WcRILR9Kl/fYT1A5528mkr6OiVB5zv5stZs/lsQTMYT3H
# DATA Xzg9aiVmWLtzn21yU0UAQQ4mJ2bV6nvJMXDIJ6ruvObxhTm8U2RVvea9QfdH1JnCGIIRklvCr2ESFo+5wk2yY5k9zLDRzuOlY9bf
# DATA jxXRVbOpAKMNyDYDHxfaZWR49ZKH0QIvqlhb7sUMzGQHJGXHvD+jREqxvwxLTjbnMmEet025/GfGUv4rkJNnv/FApDz9/emXp58v
# DATA Ei5Ld/45B17i/op39nO69pj++83pl97Zr85+cfoFnsC9j3H7V4LApNu/Of392T8AXunRh8/otj/JrY5j+RyYbF7Gfv9UHUA0fT0S
# DATA zZNz7gn2Pdkt72VzmbDKhnzm1sqD3IAxZvBgwh6BiUyjBpiwcoODnwxLC0PePL+GYvm6yIAJKsMhLIsmnDT66wZYlork6uiVsAOO
# DATA rO5eVTymoMtP5SdUFTRPfKCqJKrgBB6xrQItebfEMMjYXwP0j3KUKwvGQS03LcGt4y3vwi49FFvFsKMr3G2GcLBpQJDps8TQfjMe
# DATA DOI+NuRj27LsuIk0A1zfOokoDPo5FXf/AtFyozq42iwptq6nxbXcKBEOcOnG+icY6zXe8uJD/Eviobmm4X3bo/tGg/uFx/ZrG9ql
# DATA WhayIcdcPrV2cxWQy0IaMSUPignDtlJJAIIdT2cyFE5TdD3g1A2DXswLf7NMlxo9cXiIBZYHVA0ymcdTPVbL3Jhuy8hsRuBRTBUS
# DATA y19C+Mug+JduirhENhomIKYNFP8RdfU4w4Y1EIV21LHnba8LWElVk/YKxoIsCHEsWSIFoSAPkQFY+cz2plG6x1YdlcB8zL3sgWUm
# DATA 4EZEeY8MtpVmg2NgOgamY2BeCQNz4wFmo5nMBezh6zPtL2PZb8mwd3BMB8d0cEwHx3RwTAfHdHBMB8d0cEwHx3RwTAfHdHBMB8d0
# DATA cEwHx3RwTAfHdHBMB8d0cEwHx3RwTAfHdHBMB8d0cEwHx3xm4Ji1Vj1i5tYl4ZjdqPscwTELK88bkTEt1JvfzCmL9SJVrF3K8Lr8
# DATA LjleRJY1Oq1qe0mGA7vZqg0bjfFeo+H5naGgzizwWJlGloPH6gvQt6oV1xJSbSGu1daquPZ6rU4zWIhrrUZx7bS2FdeuFdd2Z21c
# DATA FcxuaVwbvQ7/Woxr3a96Naq/24lrvbOVOtDud1qBvxDXRnWbdaDR3kodCNtB2Fqsr43uNutAs7WVOtBudXrt3kJcm50nrwNWcBRa
# DATA o9UeturVI7/1vU4Jj0sdar95OYgd9aUaYifdsgWxa7So2+hsALELB80ixK4RNcJqDrFrtlvNdtNA7PqdftTr5xC7erfZadeuHGKH
# DATA PVR7srqhR9eGxa+zaHUdtjnz+y/GpSs7Xev5UmtLnK4cMp9T2cyX2lrnS9VzwjzQxVUZ5WvW0wxMFNSUq9tcoMPBp4YFJ/lPnX83
# DATA XLh4QnXK6wgZTipDo0inU7VmGWXvcsQ4WTFQi7hLi8C49sr+gpWwOasE1timizXG8eUcX87x5RxfzvHlHF/O8eUcX87x5RxfzvHl
# DATA HF/O8eUMX47VGxVKjn2elOjvyFc+vEdfb+pfBTTHxubHr7yljv+F5iQkDusxyYyZbP0oHu1w6ExWE/3MbP9j+t/k7gy3SbDqBwVg
# DATA U98YDqPDDWnC7fEJniWB3yyHwsFYj2Y8IhjcmdNBdAftVx+0dwfsX+AD9hdVP3xmDt7njq31aogs8sanWSc0QpFlAYHlIX1fp4X4
# DATA dM/pP2cnVs9T38kdlVehjVhSIdiyMGJZx+EcVcS7CtDDYgiUq9SGMg7MSAu9P4c3hncweIdzQMF6EbPBAkv1G7oHNFnHOO3do6sJ
# DATA RO61+qHIRDGiQakrUL1NtICznCjnqq7EG5D9fKYc59B7UiHwNOpc9HAq0wqlMl1WPVyrpFRqcvBe2/ALVt2+n9BIN1Sn1WXzqxbf
# DATA fi+A3KKR6U+j4yDFgXolKHocjORofqAqqDdCQpiTwA70OEhFmEIiXzwPPQtYJPUH8xmSZA5BlzXKF+Ooc9lQGyZSEkyx4Q4CmzA8
# DATA fAmjwEipBxmrNChhrYDxNHxaPZ6tid7boN5cIHLoRUzELCENXZEggJlR4QepAhgko0zxGA1Nh4NJH3jH6IU4vjhtvyaS78trlmTi
# DATA S3Ri3Q7F2cjORi7byKVa5WSpnCzVZazjldb4lclVfTfmNsBGQqCEnrSCDeXYA0u76po1Ea8DDizOHYbgwHpMI+QcVCrX44H1Y6Z3
# DATA Mhdywm2jeh4iuF4VQ3YDSrB4nYDsNQ4mvsQuIbz8nAjr502EzYU8ws3lEZY4qij75ShXV8eZXWN21UXV2uEX3xTP1O652VykMOvv
# DATA eZxrS+PcvGyUtcOMbnh3uc/tnBjnAZhIW5esvF4abSvWqvroSDcLcV4JRH59Ho9Ca0RDb/H8cpHflWFYRvdgykdveAFbz6UMOJl7
# DATA Lz4lotShJPlDeigCj+uuN4iO2aXNjuOZ8ahCB2uJkPxhykJ1ZvyfREeaeWUkwH6o+nXdFQK4FgCLjv2zbJDve39NlkLI8x7qGa1u
# DATA lsz+EDuDRHVNMzLFlS0dKTcWSpG8mU0PTOlomiEcuHi2asr2Ahvh9ujqjHBnhC84qhesLWeHOzt8nVn97MjGqsFONwP2gaEt2Crw
# DATA wO3QWGVa4VE+1CmJ0kquYspDjRE4hV4n9lZh1EHgU5HsxPCqnIhocwMBomTzWDAzchhklebqpenJ+Uu5YUMCv4dKoWcRNDqHjp+8
# DATA CT95wj5UPCHe1NV3ijtZphD4tIacrN2KlvMPFNtnn6Cc58YFMZIfrkZI6nwViOTdguceLm2qMoDSphGKqQRMTaNDyjHjn2U/rCCx
# DATA 6D8DzJ2V+izVyIxvpNsms5gmzLICwXPlfe+NIE1PIMqaTIru8TRgZiNbrbP0RHmJWZQVeyBTiRh85slE+8nV5MFupPnqj24i+eqS
# DATA 2QMpo/ya5Jv81SqKdIE3+3LDDMA4NTORJ2KF5lX5gsX81upi1o1CFbNx+udLMrLXgnsMXdDvoIuFkRMIkzUli12vcmQWsl60AEQp
# DATA mpdeJPBslByPTkQSOmVlY3SuGIvMUg+VOW/gQwc5NL3iExXh+qRdWyEWepkLluMHa2DGeX+lW6ygR5REchqBxUpDziRUYuBckpoE
# DATA lrfTMA5oFjhmA3UQzU5oPJ0jj2PlvAp0S1a4MTOZ50UXGl1zPlpmlnBo8H2IGSn73NgDhgXCWIBrT9w21yX02sr10n3w/Y37YKqw
# DATA M7pF6LqRN2H2dvbgZKH/1WwbKVZYNSI0zUbGMBrH2ZS1r713uMcM2EswCtJDyEpDmXGSaU79cZJK/yptRTrXQQBEMtwCW2mXy1P1
# DATA 7Her39u4W1VjF9lXkNdHUgM1UIWBJlibJinr3uguE20sih0KbwufjoM4DopS8a3jwwlcPTIR1RYmHCssDQ6jM52mrFdPva4UM8dj
# DATA G21vg4Q9F13rmxfqWrWsOwyTMA2O0UB4d8IoHlgL1cq5pu9Q1kMUYFsoZQ5k78Xese0ZzGi4sLTJ05/P9j12+Zm1bLU9oJ8GU+Q5
# DATA HwnV+ym0h+zJynVtCi9VotcL8H4iD+2L71PMEZj9iEb7uJ8VEZhfnH12+vnpn04fn/2KPv8cPEtgK/9Ef34OjuXZZ/riMizmN6df
# DATA 0f+/OP3y7O8Zd3n2twzF/JMgMTno39OVXzE/80smZ3pnvzz7OwA0z37JdEwK+/Srs3+kIH5Jf39D76QQcNPP6Yc/0s90zx/oJY9P
# DATA vz77tcNkPheOUmxLQ3elukVV8zjo7Jb4ongI69H0oMLfD7HZHV7UPpB1CtRyFLDnKjBTBONzDTx44frDfe+th9MRzBfqTFFYiLUy
# DATA aHJ14LX8zDdGNH5JS0T8HEHT9qHqPuO6CZoLhXJ1DE2ulOYubC3kNXXlAVwgblLVjhNz+33+6kG0az6CSNg2AZpxJlGB91B2NkY4
# DATA 8xuAH3QSzRw9c5OyuwJyJq+S8mp5PMZUF6GZCqC6p1nER9T6qMd8rN97NwqyuVq+pRybAwrFdAWUHPWVxvecMWfIm8WjSLmsU/aX
# DATA k4EUzkeLOM3NquRqS6fc1p4WUXOzdDikprMLrsIu0KzNy5gDL8Vy6rWZAtu3BDYyBC5kB1yfGSD1spQLNm7zWWtTV8HhLCWfEw03
# DATA NbMLTWTK8E2tUJxnzhGcGCPF47QP0nBu8dKzUf7LAXz6bcgM8eVofGX2IJr14ffeFMeZj/iWxUCRy/Lhfyx2Qoh9eVCNgkINxdeT
# DATA EPlkTcEe4IVvilsS7ik/Ptp5lvE+Mo/3cIktop2KNCohueKPUrRO3ijBbqvALKM59KZDbzr05pWgNzcaazaaAl3EaL7OKcBlZgDb
# DATA mgA49KZDbzr0pkNvOvSmQ2869KZDbzr0pkNvOvSmQ2869KZDbzr0pkNvOvSmQ2869KZDbzr0pkNvOvSmQ2869KZDbzr0pkNvPjPo
# DATA zXqzEbZql0VvtgbtQec5Qm+WFp83gm9S6DENi15fZMa6nJf9E6EbdvOMrTVEh4p/qbWK/MJuOIg6i7kMJmCtPvRrzU/2Ol7T92q+
# DATA 51e7/Kfe3Os0PLKP97r1veZeu7vn11perbvXrnl+m77Ui4XR6nSa3UjeUYxzrVHL40zvy+PcquVRFrKoVTGa9Va0iLJsdz2/2R52
# DATA OqM9v0rRa3/Spci26ns1+qHV2fP9zl57r9nc8xvdUm3xo37kl5iHvVYwCGrLmIeNZUlpSOz7KsZtC8LYsJJSrONhp9/vLSEy+h2v
# DATA Xut80mntNSgl9a5XpTR1PL9W/WSPyqLeoBT6XgmtGETtRmtp3Jqddh43CtjK5q5VM6pFWqTf6DdalyA1ctPTpEZpxRapkeLS725C
# DATA aixcAamxFnWi0CI1Bq2wHeakxnZYCwOL1Og3+536lZMasbd9b51JQwOu5eMS29g8pC0ZG0qIVA780oy40fm2h3/J1PDY3MiD0OOt
# DATA tcQov7I5uaHXv2bFb+lcgkOEoLDt86/ibp6DaNP0wDLAC65QVe4XAyuK+yuHQpbypEl5Qv/W5d/CalWjabCR7ea3lxIexVikNMuc
# DATA L18utRawliMcV6Iaz60M2p5cXgskU2p28W0cTqloeBZbmgw5DqTjQDoOpONAOg6k40A6DqTjQDoOpONAOg6k40A6DuQgQOO+7e8J
# DATA T1E2HQP+SNaMRj7e1+fdjyPlz2Tc447CReICnpCgUFXvYaPfjs9Ixv5Y2I+FQNRc1QpFrpwfjIjIQjxZHaeXo/beNI76kT6NiDNy
# DATA 8B/2UB5FDmR+8sadDnenwzc+HV4+ouUOiruD4ut1t5+ZA+T344fShCo0Pk1OsOQfyyFLG3xjjjxaoqloMiM51IlnHyyeesZRUO55
# DATA 1dnpAUKRk5lZMIouKJ9tVC3F9chNnG5OxnCN2ue8nXL2JsrZvKOEqyI+rL4P/SVu+xH9XaOZTYPiTPCH78vH50Ev2+TBBUUiX18t
# DATA EqlyUwQiX8cpzgGOdWNQyvUgsVnGI8udqgrOg+N0PrisNOU5gYDnKB7ICeZkxhSIjIcmuKAQjDeIqB6NYBDRhCWRg8ecEk1EeRLt
# DATA zMtmyRsbZslbWhOUxmSdIa8HI+gKsFYvR5caE18wZ65lCYdlRb0BvMv0NHKKF0h4XgfmHA3N+ENNkKy/WE7mI7DJNjJGt4ML5suP
# DATA VueLtChVU+YhWyZ5HZkEKc1JvQnNaT30MwwGhXQrFiQgM5DDf2DRcJWKJkIogyBBxhwR+jxFf390oo2bp1hH/suGdeT9ZM4aFj+d
# DATA H+b5odWmp1p9OhkPsGkEmAbqBKaYXqFBMM1IYYxCMjVoMOtTxo2GyRwn3va9DzEhYG0FVkoQu+5wFPzMCHU8ofps3hVeMH/eX6M9
# DATA qztVySGaX3tTfUly6P00OUIdoDTT7OYwMuhY3iRHlSaY96HCcXfizSdIru5hIBDMQFRgmUZQ3odUNC8uP8V288GG7YYrtVJusZC1
# DATA rMgwTuZQH59DqWIkxkPKZ2Th7wcVKwx1zwKl5Vi6UjbLbCHeQKoL9dfl/LheKduXRaEhN7PdJNxNwjeehLsZ9ws+4145mX6mJdt4
# DATA H4vZ0SJUVt7VcudVatDlEtb7L5Fcs62uI1sprc2hciEY8bey/NnCvkipMP0EO4fkZSeTvo6JOml85wcL2yr1JH9RXc56jL9wagrj
# DATA +6hA9gJ8glkvrDgWUvWkCbz2L+QP8dFpHm6eUd2650nOaUNhW89sqZLqWzAczAaqNYbaf/72n7QZwa8c1kTKTixIbxaNRjx1UaAJ
# DATA UfT6LuzPzDsUKyuYMS0ihAobzViG83FPF1fgpcOT2XCsrFk2WHlucBjLz2L5sRgZps0QNbM0vzze8wiRLiWNXKHcSqNccM6oAeoV
# DATA aMEM5eiK4yBd0NQtFihDjYzhyMSql1BWywrGWW3OatvYaluob27txK2dXMJiW2kcXqX4LgOaBkpHn8Xckde8EF/Q4H36gvDrDAGc
# DATA 8/PstZaFpROxFdm2DAvXCmsastRPl+9R/8tnv/mKt9Mfnwe614+a7sxcMCsMckCkjIz3i6B7Gxlf3fdXr7+oDQV2ZOXSJrE1D5vo
# DATA 5ldMfLvbjK7aeEG/v6v1f2fJrFAldr59XrRNICba+ZVzsrlqxbu+NtrKfDULZrIrlVe5pMpHvMXDNIXMQkShht15Vc4Eqzir7cm2
# DATA Uy2/JP1PLKiqKY3dyoi9KUE8IfxJbCtGaeVdgK1K/cPM7C9B4zPG7bviTDVKzYwcPh7GoyjvJ2Ko1c6wVydlyVuz0kGtOcrFm1ke
# DATA WK1wwsSVjSuy9Y1M3VIV0DutvFCh+kxvoLWD0aVafQ+laj6m+7E9OA+H9aT7wQTawVNKQIxzikE65YVe9hwDRQ535fEwEgM+77iQ
# DATA MghNc7/GC1tkdOx7CmaHFBqh6Ww+pa5H6QcXxaVvcr6/LNazBeHiOTrPIWwO12+ZwfXF2S+EdwVy1jenf1BoLsC5wOL6fJHA9S90
# DATA 22MAugStdfpvVjj0iQFbX9E9GrL19dmvT//dULpOP6cbH/O7fn/2D0zowkkH7/R3p1+c/htVmmDkgFvPhf3Pxr21dQOowDQB3nWM
# DATA foLrm7FjmNSaQZ6cuiRW76OecSKq38esGy5LF1p2u6K4oYdo7MOgh35KZuuihs11BmLnvQgzhHWwrY/oLhMhh9oqmP55z3DdtK1S
# DATA qVwda0to34b/xFuyrbdad/40o+LWNxYr2DYRW4GArTRcQS0QSmIcXuuc4to6Wuv9gIxO/EyxblYr1WqVRw3KAOqi9r33aQAxVg8T
# DATA LHjSNQymWAvWO/9nQe8AkRQcdWYgFCiu6CENBDhbUGZonVvdVpspxcbztOBZ5ybAcbPc8L7t4V0zsy4+qr8czrxrHNG3PaBvNJ5v
# DATA PJxfy2gutbGQdNtH9yy1oatgZBUSzoifTDHb7WTSpDvI1KJZiEWzHizzADuJK5TQGEgfajQxJWEUgyU1CfVrB0E8gr+yH4BVxGyh
# DATA YrIw2gYmo8c0wOkF5niSTZEkuEiphWxKy8pDZs2ATN5H8WdKE29FH1Kdg3uFLvKZcj5tzv6NCVb4eA47Z0LUNBAHbBIyMkvMgsyc
# DATA FacU3T8h4+0hPGVxGKiT7JEYhlGGfYhxNsQ6ZgCvRl+4K0hXPMAGxP4wGgce73xnCteUxyKH0nIoLYfSukKU1rlj0EZTnQ3N5+ub
# DATA BVxmErCFOYBDZzl0lkNnOXSWQ2c5dJZDZzl0lkNnOXSWQ2c5dJZDZzl0lkNnOXSWQ2c5dJZDZzl0lkNnOXSWQ2c5dJZDZzl0lkNn
# DATA OXTWM4POqjUa1eal0VmNQXvQfo7QWYVV543AWZyxHJcuZ5ygmap+QY6i5XeKGV7vdlfneLXebSyCnLo1RlKpoCy4VLva6XZ7y+BS
# DATA dQmkH6csQaVe1rLYUnWOJx+Y6xRpUmG33m4te77Z3Oj5bq/b6i17vtPY5PlO1GsHfjkTxrVG3avVWntUsZtdrt61cd1v7vk13+Nr
# DATA e3Jtz/fre36jvddue37Ht4PmDaMlPFcn7ITdZTnIuLBSzW93vUbdpwqPV3vVYbdaCs7k3UJw3UsgsLgJaQSWtEYLgVVvtXrt2mUQ
# DATA WNWoGwUWAqtGAbVzBFYtrIaNHIFV67T8VvfqEVg0E9qj3zeatNdqNFYW/VaFkUZGPB2ixwfkDPdJ23DK+NQJ1gGk2rWyLBBvPnpU
# DATA cplYY8DC3UHJ7DemeEeZ4vkDetQuzwOXzfm0l7DDXkJZHYSfcMliW6uYiOJCgMwRPXviowy5/AkzDC5ZsStjuJZ6fHRFLXoYVkG7
# DATA jPNYRQd+Y2v6xd/Pyafii1pIDvsVC1tPVj9vxulzXrNiCrca62Uq+EY4rnWVd/W0vlSZl9XJ+ejcySVHwXG+HOfLcb4c58txvhzn
# DATA y3G+HOfLcb4c58txvhzn6yXjfKEuqBPyUXhgU79mWDLljEDqbktdT+ZpP0IF4Vp1EA/YyFQN806zCoNnNgSs4K00TRDHN5XlheZF
# DATA Jg/10emh9MnmtbdLxrQ1J2ATtoLJRUXoX9jWyOWwK8wxEwh9p67i41fYrhHz3LuXH/0nO/okW9IX7B58yjb6ozw22Go5iCeUHYpq
# DATA xjKiSvfhyAr+DXQ+1FzhUq3gHOM4kDNUXOp4aw97lGl+yS+y4qcEdamrwUmo9xJjn3rHOLOorE/6jSNI1ZpzH6d29vSP9Mtr6+wO
# DATA LkMqnzxdt/OU7T4qREbEqEwctEijehNOAyIeYvUffGqM+Y9fMYHvI270VnPhBvVVoLDRNWrt+THIm3Kjzg0+e1ROr0quqWxr2wun
# DATA c1nhbRYMTebwegqI7WXJsx2xofuzdERTvr/5G/mKzYD0dfev/kq+06OUpx+/8hYjHl7ZfbTC8lZGN3WF2ew+W+w7UqhO4t6pKVxK
# DATA TcGpKLzYKgoXVbd/quoKxgErKRKxPkvJfRagut15T8twc0r5IOsc0pbx6oS8qc/u58oDEks8tO7B+9xueZsXFoVWPlXIDjEWrLaX
# DATA P3UTMdU6hHw0dqXAvSExKSkEatXrxe2fObGJ5+BwNf93y+SEoijGtrkJZa2RpdSEi6pkfZTGynSLJ8xqJNsNxoxRyTI6IKxclsEC
# DATA PoaQ2XguGg4n7KeuGAF9qYyq8nBFwSiZiaK9pekBjYOALfpkMGO4UhqxG50JXAq4xYa+xwuDrDc+iR6yj1cpa5zLMXoxzsmbEJxx
# DATA 54y7jYy7klKO08xymlkXsOpWmo5XpaX1tgg2UcVWc3nlROBqnpN9rlux8TpE7pVnQWeuTvqreieGVhzXt0E1XTxluMzOsoLAOmXk
# DATA aMQebQYgYK2YR7e/govpAH2afLqlLiiLWr5V5A+7xdVtP/YrtUr9JzQo6hitkJRXTjV619v8iatsEUFsbjF9a/7QAgG4xsiG48Tj
# DATA rSRrwMMNMbzBPSzduQAKXikmb3xYedV5fnXkMeUReSllIy2TOJsbgbOptJqKkjD7L8FRcF+6WKVmBsKKdoOimah8YL2340lRC01U
# DATA swJAWmyXnNLHogETomeCSBqdKEeoae5QuBIBLnr6GKe7eOhkzSnL/bfvmeLCiEg28rw/mysK0yge4yJvNIJgFUTimHYB7a5MR6VU
# DATA EfKpiG0m51MLKa2i6xRzS73Cb1yHas5nas75svMvhoWaDzPORHUm6kYmqm2LOAPVGahrDc+nLfb6XqGRTDDQzeJxDmW6L8ukLIBa
# DATA sSiAkjrvLS2DCIFFHN/h7KLf0VTChMdq6HKyWmhwSPHClrPJidGD3FDBlaNrYiMkKKoFEHQUg4AaK7X7iPUt0Xks8dapE8dLLFXZ
# DATA o4AKxp8UHUhZMvrH3LgyV1h6Asj5iMNRsZM9N6ZbWs0qMhsfGPojn4t2pXWH6RLtpxZMRuwcwOiIjlHui9dZmGiR2pe8+i5Lx1Yw
# DATA jubrmpCjLD7ktL/Jn9bYrkU2uOwksA0WRTNfZTYWyhi7q6WxXgLArnPjggD2R5+uJrBLxgqBHZO4SDPSldP+RJPYP8SWUUp5Os9k
# DATA uxfXwAlrpyohXcyBQObUK9AxNmEE2EDh9eZk6CrF1Li/770Zs8DqnIV2vXGc8exR9rpguxJTRHkTiFzj1sorw0JiAIKIXpcqPtsT
# DATA o+1LNeiCGfyff//V6hwu1EbJaJZ0TSMR/oVfNe7HM4O8519y+hJr35JRLVqqyVSfup9RbUtZxxeHV2ex2Od3B3wonOYG4158OAf3
# DATA Ubl+K7q7E1SU0B8DMvZZwjcO+TeZsG8jRy9ZV8fZZnX1vWAsVQFS1nnWSW3BFAcKtrLPV1RtoVM9imZAYsnuJvO0xxgP9F4M+jgB
# DATA WlZoXRMoA6JBkPVH0aHek4pCbVAwDeTpV7//eqHKJ6wzjj2l4pN5NI90/r2DGRwmbTSBzpWYj4OYnTl8QR03jwCAflMaJK9JSMXJ
# DATA 8orKASPrBzhawPlJGTiBC4kDmslTwPRGoCjSUIlC20rVM137BTPy7TV1Tw0SkoflFUpvlgZHNG4eUxp0Zn6gjhIMlUB2INUyJRsm
# DATA CjNlFFAvN5kxOA5hwS6R+Qk15InpGVSvOqZeI+O5ZAyJR2tZNYfLzWIl5x7R/FercMP2e6r5+uGm+fohE/is5Sqcb8xbt1oOS6ND
# DATA 7AeXAyKUkEwNGRhtcvV6I3mesa8itwyjwYBz2O4Hgl7G4tU0Q2P3jtyjqjN6U7H6YnS2P5XdrKUMLRoJsmfRNhLMFckesmv17kI9
# DATA sWNni9r1Rx1Rf5hAPyuAv5RKUhfES7HwZmP0qCQim6D3z6ffnP3t6Ren/3769dlvwL07+zmQePTfb05/d/ZrQeP9/vTzs89OH+Pv
# DATA 6denj89+s0jUs8NhVt7PmcaHZ785+xWeOv2SLjJvT9B79PdPHt3yxdnf03N/PvsFcHqIQS+NjvcMeu/Ls1/S39/gZybu/cmh9Z4H
# DATA b43UNJs3L1POBzFa6US2BYPY8EPjmxHle5hjZDGEUPphS0HWN/D7A72dJI368VTZXNkc/RG39nHCYv1rSXpvSLysBuRgeraXBrlz
# DATA 3Ry9xTK5OpSeVJ18JfEDqUoieVK+GT2RteYYHV8JLZt3VE/VoQvKCpkw4m3jaDJ3PL0NymzrSD0x67kv564HXmbxm/XIgNC9m9jz
# DATA 3I19mHdLVF2TYwX10YRz1lkT9C8fOkChxeMxzugAJkSFbWDEF6p/azDA5Ub1tBB75yfCMfbcOP+E47xG6l1qeH9JFmCuZWi/gpF9
# DATA o4H9IuP69QzrUiXLOWCh9Z5m07kKkl45qXpRRFyqActNlkbEzB4SEf+FMbEiUCxZnJU1VlGyOIpmyZSfiTI+0J6QuTQbJmG2CSbv
# DATA A+ShLGOVY0TZCw8Bb9yl5I9jbDBJyCrDni0Z6PPqQu8MsnkKMFjAAqOUyezPr2i3fRqh/XCKTrhkRAdHSIBwrDCpTleGLBgJ7qsP
# DATA Z7XmmTkanqPhORreFdLwNhk9NpqrbGrsXqvdfhmzfRtWu6PiOSqeo+I5Kp6j4jkqnqPiOSqeo+I5Kp6j4jkqnqPiOSqeo+I5Kp6j
# DATA 4jkqnqPiOSqeo+I5Kp6j4jkqnqPiOSqeo+I5Kt4zQ8Vrtmq9evuyVLzBoBuFzxEVr7zyvBEYr0B9q3ctaly9WjfUN7/dLnLjBv1O
# DATA V+UNRTCmkdUEUc+DaDSqednUhLYnh6dq3UJ47UatX+8vFFSt6Xu1Wm1Ya1eP/Ebjk72W1/X3/HrT69boT3Wvgy973dqSkltE8zVr
# DATA FFqzOmy0Pmm3vba/16B64DfOoc6ZwBYwcbX20gzoWOQ+irxVOevNPAPqhfd+q9GvterVhSjXW1XPb/qf7FFaG1Rb9tr+uNmguH+y
# DATA V+vqK5dOgF+7BOiOW4UG3UkDs0B37Ua93mhsALoLB60i6C4Iu/1GDrprt5rdVtOA7sJ2v9qzQHdtv+432tcAukOT2ltvb3g8vFi3
# DATA lvlw342oF4iDigRcWsxbQMXVecEsXy4rBq3slgUnlc6hBUdkyd9vh7XMA3+hQdVj31uVDSf1jFoCW5p041ZdjKQxy4sIORW2oOuW
# DATA bxUoE+0WMWtLc8YMfHr1q7qOBrdBLbgqU8Sh3RzazaHdHNrNod0c2s2h3RzazaHdHNrNod0c2u0lQ7vZMDdJNh/Yui0gtRCn3F7Z
# DATA /Y584yVHxnIp5FkyC0ZyP1rUjXeD2XCfZ5I7fHH3BuUAjqPSe5QTbQqNmfmUb98pvOOmfKMfM+5FZsk9bMfb8e1QPpLDZFYg5XeW
# DATA guFnF46caYKYTAHNkQ53iNodol52iLp0zMcdp3bHqS96nHqN8O1VHbOWVsB2MPTaZZXVHLN+ikIe10FdCNXxbFUz8NXbOdxVkra6
# DATA 2U3YgZELwKun8r5Jfc+ZBUUWwzhmAbqmwjaw718WnbDFgtei9v3VwrcynkKK2QxrKAYcqpb8Pye6+nkTX3PBRNhvLYtwx4pwbfP4
# DATA 8qAKShvHg6NJV86JpHoo1+1V3wsciIUY+lYMO3YEi9FbyXt4Q7WoyIgGPb+4hzfYyuNhjAFemJzoA8lvD6CyiT6Ej+FnPNCh7WVk
# DATA lkwr7NOkVjqC13904kFJE5UsBi9PjCLx1gudS2odnxunZqhCDCkIChBmzlAH2E9g9KiQ9HFw5k9wTY6yGdbdeUrFEkxjtogtEQCc
# DATA BmcFRl5GDXGSzJO1mwNbDAAmG3q/LBlHuiN6h2YvR5ghDRmAwe27j93BKkGIdt7XnA9oeHEOFjtIrLNk11uyzm59we3Wi0Jhn7o8
# DATA EC+YWwvBi0bfqCAJyNSfjEW3Ff+gx8dIYYqsZag+dVWh50SB4yqwqQsKSNsmpy5Rk1oOT91MCbFU/5DVNk2BRaRfT5FWNayzanuu
# DATA IM17evREaJ4JnErzU9kWizDPCk8Kki6Bh40S87Gyz1DB6EMWKUMJgUlNKhooCp18j28wRklZgpvj/AGLvUqUI8piHeO3zUQt5jkg
# DATA RVX0jGZxWmFldo6NVmUvWGha8d7GB7BBiqDICsARjDXRfh8Lc+tjfR/QFRVr3qYUhTrib2mJq5Bmt4gNJYFzr8JTvop3gs2youqE
# DATA HmOWHEZQsdr3LKM6YWXRscegAkV9WRVd/cLFGL9EAjZ2n+QsTWdpLrM0C+OU85g6j+l5BurTF6aUGGRKWTFNkjGr1HGDyOUpRyNp
# DATA KktFEvdVPa+Is6IigxF059CMsD7NVDD2rHiyeqfaFS8jXowCdo+tBKXuKG1SLTdymOj5pozdhAs4GGEDgwhkOyjYJlAwsbhs02rV
# DATA ncbPzXQX/WX1/Vqlk3NVfV59t5bxLJofzz5GLM+/C3Jc/Ft+azXKRReGoFx+MImoM5mya3EPRxa1ZYj1Db/pHdorGbVGlS4oN+JH
# DATA kSKQ0RQEW+VGJxWy27H3t0f1YoCvM4yXCBl7SDKsecipjox7CBhbx0E2FC1VbaHTpdEo2wYH51ry78PjhPMvpHFqWsy9erWYe42O
# DATA lXv3eaEGyea+VmUSFEsBdJ6xHKVIY8pd4hceRcAXYbOupw7hilDpFnKr0AYvnmHN1RlmNWjJs+9Sn0qxu5fyVHYqE5g832qlWldv
# DATA N618m8GU4mUyNpziyXyGIQeipaPixIpHDIb1UM2j2ZWi4JlJ2BF2NI6egbxrXSDv3kAVSEVWIl8fLGRfqdrVa9VS9lV4Ks0m6qEU
# DATA RUbzVFFKBbFPWiP2o4dpcIytvHppgPVm86WBJ8kzuw+/YJa9uzq/8tFAIfySB4G2rnUm3WNOhXAjgO4TeuER2RzGTCcL9wE1vJFC
# DATA O4WsOjxOQib5eUOsA3sfiFAwM61wxSyfmFWZjAZ6ynXW5EWL3ka22YPZhWtabXXG5QOjZJxxDBQNNJ2H93FVeV0mnt+hGhbqvAq8
# DATA eov3DFFFxbZAdiHQdEk5YsR2Y4w817XEO5zHiu/F3FjlvWGzkbecP6sIrxfFIZFjvAbxDBKzNsfr/z19fPaL069PvwBj67F3+sfT
# DATA 358+Pv3X0y8YvfXFIrDrf9BPvzv9Boyts/+GWzxBcp3++fQr+unLs5+f/bqCcChMCutr+u3fvbNf4ac9uuMx/f4LftPj06/pzV+c
# DATA fcZ4MCC7FAHsF/T13ylA+skxu54Hl0oO9UOXObZ5QNKHZDF8oNQkNS4wnfdnrH4vHQplWDQT+OIRpn/xWFyQ0m7hQh3g9Dk4AFAo
# DATA 4afAYeSNqLzds6808pNgtBbj9RZWxsPgxMTUcbxsX4vqIK4b5LWkVK6O5KVqYb5kdF9Vy1FM8UxPyvdLbdQ3v12opNuEecFlqGIi
# DATA WviyMz/S8XJAr82KbutMr/tRDjrIWRApIKm6yzJUDi45L0Nvg71AIiPMUAVzihienxN83fe+F4d6dky9m0yvxTmlUrpA9jq/Mq62
# DATA ZxZb2dNCe52fCof2cubA9s0BTfu6nBXwUqy2XJcFcBUGwEbj/wWH/+sZ/aViLuSCBf16xhrVVXDAFpIPqCnWhjLmvK9PWYVrIFSv
# DATA OAnldL49U1sjeAsEi4TEQWrepIPilMuCE4pTuQ42IoN9yL5e+IOwASeD6y1Kg1FFWXI0oMXhHMUXhVyMMNZSqiG8hhzmmCeOsDYF
# DATA zI4RmAcUqLg84JyiNg7XTDzZoyxmELtH1sUsnkTaUcXLZwgdy9AwWypis9CLxQ4xIChHCXOUMEcJuzpK2IZDzkZzoE1N5+udBlxm
# DATA FrCNSYAjhTlSmCOFOVKYI4U5UpgjhTlSmCOFOVKYI4U5UpgjhTlSmCOFOVKYI4U5UpgjhTlSmCOFOVKYI4U5UpgjhTlSmCOFOVLY
# DATA M0MKa/TqIf98KVJYe9Ac9J4jUtjC0vNGqDA7X/ymV/c7w2arW6JNtah37ETLaFP1juQQl5GUQYMVKYWU5fsFpZ5y2dV8u/Bahfw3
# DATA 7yyE3uz6Vxh6t5UH3ugWApdU5YH79ZYNASsE3h10er1BOfBWs7v10Augt4aw2ARS5rdy0FuzUwggagZBp77QLOhxz/c7R43mqNbx
# DATA /PY5BLLVdaJ9CQAZNzYNIJN2WwCQNYNuawMAWeEKAGTNsD+o5gCyVr8ZdaoGQNYf9GthZAHImo1+t3vlADLdQNfCp/b9pqaQFe43
# DATA o6NeIGhuQhsrBqF5Y3k/rnNqwZFpPdrDosySZzZdFthvKQukZjseavtL1oR9NogKby54FMQywHM8fzHeJL9JdgJMqiUeyZrxSEqm
# DATA lJdZliz0NRdeUDvQcy3qvf3cLilFv8P23DIuWrfbLdLQsMq8mlJWKLdKqSzWWDvFG0u+B+M+dBgyhyFzGDKHIXMYMochcxgyhyFz
# DATA GDKHIXMYMoche8kwZKgLFEo4iioRLxOFt6sVdrrzpymZ3VF2+8c/qcChehTdZgu2go72ffx0G1XywFRoPl0G6yjd2X0UD3bkod1H
# DATA OmhqoTBBgkk/2p+Qhbq7p151YAd/wKrO+uDGjkRv9wBdwcevfJgfYwsFJ/apNcfBPkL9filFHPtY816kn56ipLKSB02M0x3VW0Gf
# DATA WNJPCZiEN25P1e797Dsw7A4ofQj8Vfpt9xE/fXt6wGcyKE7041/wNYrH0tQUEmyy/sBk+IHUOkzoudHnNYzy/J7Sd6a8V0g4ffLH
# DATA KD97H+KQVPH8ZUrRZ4IH5UecSPaJLX/w6erXMemtH8WjnR1K6h7SvHuTTVtA3lSWUEwoyaZeUEPi1O+zG3f3UV5hrMsSd/s+yjib
# DATA i5fXIBVL5KrkkBoLdh/lGYaiQ3HGlI3xq4qcx5JuSGd844a+eX86J9PkkYr5LbkTp+zovgpHhCbWH+HU3X9+9n+pM43A5sU3/F3q
# DATA YigSC8Hv+btrwsbxSDvsD3Bckpc/FkP/NK8Ln6o6wpNJ3SYXq7J64KBQ+w+knt3GDFZXPeuGSq1ZLbaodD4RKWEh9HF14FZGF15b
# DATA Z+DmbV49leIM6XlPcfna3YVV8/McKPUz65rEB1BZzduDShSiopNk5oBLosVnUOIRzYdMn6proHlMxordQqQp2ON4QtPFZYFiJY0e
# DATA ikqZ5JgxTmfikjoTTl/ixdeXuChJ5lnQneCVlYK/fj1O5l0cggeRA+Kr+uB0cIhXzZJxktLMbC1T5lkUrXh+jnBfBWlmUWNj26iZ
# DATA ZSIml2TNeIUlIqnSvMJ2x69qaWDBbBo5MXqZugUCnlJPcpEPW+j9AVllFXE9iZY9Im8sb1nNS6aYRQKuJ6yH4TydsdRXrN47pZF/
# DATA IvoJiZL6MCL2a4Q+zlMefYGO6BcajjOhnAm1oQlV6l+daJcT7bKG35XG17Mg5vX6PAZTqyhbZaS8viu6UHZTwsgzjRI0tONhUhih
# DATA BCGgB7B97y5EbFB0rKkTyFxYwceiB9Qcg1E8gOINRLfhfBAJqUkUhRozdlF+iomoAj4oOW1Iq1eWKGk5eMom8JRxIkXHevfq8zog
# DATA SspuNJHAl8+r78ZuH+Fmv8GfVt+pzR3FF+LPzwM6xc69C6rkd2A4rtbJz8uiwLJgr54Wx+dZUT6yYfxKk/nhMG8MP2XYO0t4aFzS
# DATA fELGI2tR5Rum0Z6Pkpi1rfpsHnr6BD2sxjmLzU1ZvhfGJsXhMJptgzLwBPnXvFj+vRllDzx2tltoAWjjKriTSS9LxokrPGOeoW06
# DATA HAejB5RXWj6Qw8Nt8xEw3Yxq9KIJlwGLt+EUhBfOUy2uS4PUdpgWeTO8KJyhtj7f8lYt+fY6jfGy74+ZOvPY1D5lW1Gdi6KVQoZY
# DATA PZqAZSF5ydJ0spiQKXpXlM32ve8zECPqDyfxJ/PIKChSJaUJHVgJsyGmHcOAayLydaYq7hZyM++mLpqX59RB3etJTn5EdYdVELVU
# DATA s8GQmkyiNHIVYgtVoUYNEp4s3P4DSEGWTFmVewHLLirk3yhSk0zOdqUhZ0S9B8Vh+Gm14NbFWvDrwYjtCDVViGwWDYwDzpBsPsUE
# DATA jBIYpL0TNTfoi86i7HTe93ilBrnLcuSpYrtRrg2iCCKKmGqRRRFl06gfMxFW1C/TE9YzNJPwSXS8jRy0x76LVsDq+izMh1IFW0Hl
# DATA Ss1FTcGladeYuzZ09orUY6Zh/QBUHsqoYzKwYapjB4U3JIsQ9QtZxiqgLHxIlRo6kEfYKqb22DyzUJUXyLWRB+H8Gs6vsaFfo1jT
# DATA nFvDuTUuuSa00gVyZRrlqsoW6K8wxamaG+/GU2dlrPNuMJNxJceeN3rzMgd2f6uTi/qamfTyrgZ75DRX9KyXcyk/H4mdIfQtGQzE
# DATA NAhCsQsKDgne1UI/s41kep0dtT1lV/lFdAuf8IZ+vEIipZ42PaP+bub5dTm+iWEgJeOejBc+c4eL4+Ch3FGVc3LRlI/mrfad8CYZ
# DATA TolVphtHVT1toqq/m6jWzo2q39k4qrLtB5HlT+fFTd+ex85cMfFrLIueb0WvtiZ2alXQ+LPkXABP/8Dbu8n7FMdkYsuNbH6k4zuv
# DATA irRCnoU4FmLXwfxSoc5NaXCfyXHcmxJEXpGNb8ZqH+bSCgeOmEQ0GQwtU7ug8P/XZJv29QSVJuYDjJIGpCNThuOAhnfAdqb0KBlo
# DATA mIEpKlA+i9VASkUnVJMtoaSavb8W0hJDcjLaY5gl79iit4TgYSZCE4UXpeKF8c9+FmNIYffKZJ5BkD87Ids3GWe5F9WO2TAaTc9Z
# DATA OC6Var54bPtV82VgyX/Zs0WPv48PeYlfKjDZyiWNMppZ1UdsWC6xl8Mqt1iH85RsYjLpbNrh/8Pwwi9AGywyCM/+Ef9dpB3+8+nn
# DATA zCP86vSb0z94Z3979svTr0+/PPt7evIb+qS4hcw4BLFQAueQPQYifg6M4tlndMPvz/6BHvoSt31z+kcKRz/5h9NvgEt8zBhECtIx
# DATA D5+HGYapXvnEgis8iCfIUXqmovyV3OFoJAYLJxm6s0SYLKL3qRSFRgDDyhA8qCfVRs80jvo0G18HN/xAb2OgAYDRag5taE0mdIFd
# DATA N9xwoVSuDm2o6oi+DZwNTdzhXxbux/YVq8O9nwzUnpatow05AgWwYZxxZXdYw82KbetYw7ceTkfoZQLtDBkn4XwUgLyezFizZ9/7
# DATA CH0/9135Pi9e/MLGeHrW7H+iOMzH3FNmsg0KLpRkFui1rGAi6JgFoOH5VXC11VJuWU8LZ3h+GhzO0I30TzDSa27hZQb4l8NTeG2D
# DATA +/bH9o2G9guO7NczsEu1LOWBxSx8Wi3nKuCEpVRiBQAkIMX5i/tWYvU5x3KCAnFpKqgcaGt6E3WG4uHN17KtWEt0w0qasFe0nG8b
# DATA EgmNlzWPXTZL+rziyOOxRsUxP45rSUhz7Ulmoh/N08QLxox/4yE/IrMh7sdYGv//2Xu3JjeOLM+zn/UpoqqsLDOLAIg7kKSS2hRF
# DATA XbpIikNSpemROLQAEMgMEUBACCCT2SqtSaWu6eqtstb2bJut2djuto3Nmu3LPrBVxRF17Yf9AsivMJ9kz/8cdw+PwCWRycwkKbqq
# DATA SAKBCA+/+/Hj7v9fyiZIWQDBQxwsRuCdAN4otaNarRWS9UDFeSPwY0SIbbv2GK4YMRLZqyOUOllbV0XdmhxI/XK0QkcrdLTCs6IV
# DATA rjjUrDS1WdUyPk8b/yQm/mlY+I5V6FiFjlXoWIWOVehYhY5V6FiFjlXoWIWOVehYhY5V6FiFjlXoWIWOVehYhY5V6FiFjlXoWIWO
# DATA VehYhY5V6FiFjlXoWIXPDauwVqpWa+0TsgqDTrcUNF4gVmFm4fnYpMJayauUinv5zc2PS418peE1avT3bqVW/ri66ZW9etmrNPY2
# DATA N1O51C61Ku1uFmNHYdXnYuyqM2RDOeknAL/NNMCvVillCH7VZlLWcmwtIfgFzcBvz4ITLT5gs5YKvlzZTAe/WVkYuklmKvRqsbYk
# DATA 9NqJQrdLpFnyqtXGXnWzT11rvrq5V91cOadLszDCRsmrlRq79VotE0q71m612nNRlMfHDkq70dhBaYIWdrDeqTUbnSOxg3631a2n
# DATA sIMd+rtTtrCDnXqtUTPYwVa7XW1VLexguVZtVs4cO2i2qUH4f2el+foSbp/Yt96MXaTN8czbzECppl5vBdTdhH5O4jcXYFhTK3Hl
# DATA GVofFhZnXpBxu9tGoy6Q9LybzD2vBDvAq8sfO0y2TlfOoZo2nZApYuSmg7riZw0VCxuYjqy9uUCP6GrZqzjP2yuLKemkleH75L/U
# DATA H3vGvZw4mMnWXDZPlpgtS5PM9oQDDjrgoAMOOuCgAw464KADDjrgoAMOOuCgAw464OBLBhy0+W6SbPFiCCmNj4oj+hu/ahYvlIs5
# DATA mlmqn/a5CDdkyqYxX9fkkAwfdEMju8C/gkvX7iPgwPv//ndvs4hvnSAYFj6k/wagrVG4V7aKr3249j5rqfM5Ol6oQSD0owRR4CkP
# DATA RVjCModvEBevdYB7mY7nt2KEuGGewid+1zv2UTZJnRfEY/iRg0ve//jd/4vIzKR9vVIuXpCrLO6JrgFBapSZQ4i5s91Hne12Z7p/
# DATA 6me6j0sKex7OemdcbMsxYdfRNMwTBe8Gqr2t7TIXDvZMT4e/OEcjz4IClj3MftoMsFlJgJMSwNL+Wn1W/zpTu6QiyGu6gdG1eQOu
# DATA R9/rRPRDvM9ntG/BCYmqxVJAu344Knh3wjG7n7Tgu1RAES6fDOV4sirc1PF9P5EyGkK0MeryWeRENCejcDNTzg8CmMq+kduBTXT+
# DATA SjfP6BSs1YKcMeSMoawxNNOjOtEbJ3pzlBn1fIjh3JL6ykSLTmTwFx9FLaOIc9toN1AzDHcGivylNNQUPnJEw0Ib4hZd3CxKErEP
# DATA /CrcoxqPwxvyWb5DdGjghuzZ2i1zNFNWBn/dheoM/GOJko3Ng2Hfhah2ONzXargvSgr0SVTSx9xqFsO+2O0ostD8cfG9vD2Xe5a7
# DATA /OlFgHdZeXFM7sqdJfwknatCXLmKVkGlK7aVAFfu7kci1hRNIBjjQ45FICt9tBQtkYga7rMXSmSZxDykcW0PXuS/hTzLqJ9WLxKV
# DATA IrL9omS88yEIQ7XDF436LhvK+sypNBo1O5gv7DwrAG0W3sQmSRJockxLOWBswIIyZww9YAlCPx3/6sQld3vlkrstB8zFStdFdx22
# DATA CDpCn9kAVBw7Sv07ZtJXMGR1HMUSSqPDUHws6SNq31QEMknd1nxGeAzVvijuTXvBWIEFRiou8TAaP32RpVJ2fmWW9CbHLLN3l9HK
# DATA VL8kZfYuBIiQj62IImQDoliaSK+jaEGzHWFkUe5SJ46LUZesEcPT6gb7ojmlB7exSMLjTlnc4ZLeZ/obM1dMo+PSb03ig6cvrXSa
# DATA XoDiurlycd30AW7nxQzq6xMeVbwrWvqmMVCvtwN/+IPgQKz9lg8FLW836kvDwuRgwKGxRt3Ao4IagRYGVA54VeyA74YPBR/H0ISk
# DATA MLPCb09faOmUnVuhJaPwMcvs7uIy0+O56hVFORDXkvISfwT24WMYoCYUCyuwJ44Ylkduq3GCvXHeNpdvl/Fd1AlBhAzjnlieODbl
# DATA DSd8eI7FEwZAu5xCv5fE/fkvkfKqJXIzUMp1GD7G6idFuJTzQYEeYKQ5ibUhQn2Rx8e70AIORJBQwICq1XD/xjNrBACzm4eyMNZG
# DATA CkpX9O9Ooc3MJuRExXS+hLmnwpi8DH42KwjnaHOOtqyjza5SzsfmfGwnXGxc6JM7I8FpmZLLTA8jICo3bEzjYnuGUIMzIs+lPFl6
# DATA 7wnsfd5kjeWnJu+b4Zmw+v0I0FkSiumurEsJNe4o1Fl9RQ7bvvaWGXAXzwvUrr31dv9IwJ0EkADu1HcLcDcXG1eSyxocV1wZcie7
# DATA eeAuxAdhjAkFGSrFnFcZB6J6IPEe6hBmfHaNImO/sK3d28dCJu8vahQXe/lKJX7kbvAQPVHHeop+WfJYlR97m+4+sJ+pFpe4CRci
# DATA 6rRpit20ZKmNX1xIne2629+lULyPyPIcBAcFW/JZ6TpLJwCH0H7klbil+SMFi9Mb1oY0TVKmO1adqbOgOGF6xQM3BW3c8eLQ4L5F
# DATA PPbK3a/VtfnFatuZx4BLKrBKucj1zmrh1EdNNPxS7cltp2sq9KaVDDuFolXYc2ThP5Sub0Bx7MlUkVWzh5MRQO+ysB3FrJ9qCWSv
# DATA AJH7iRjPCUKOepGgPfK7Ywshd0Nfyx/+fvrj4eeHvwNEbvrnWXTcv8zFv9GXx/TUF4efHX6Oyx7985gufsV/PwI4jq58O310+PcG
# DATA Cfdk+lgppEPhawjtVBqyHSbuuTf12TL3PVNnvL/293zvWieUs1gieq/2lfDstzsKg0GHOhD+th+Neh1j/cPzPRmK7xSuBHGd9Q6Y
# DATA rhvBpS0UUXYaJAsUqufBU8FDamidpQi51yGgwVoTHv8tPAnHkUtmBKZTOG+O3PyiOTuY3C5Fh8kFCZya66u+fhRM7qovkuBnAZTj
# DATA zVdkO9K/NCaI6wqjORqMA8qtVnSnDpSTPPPZzBmgc5N5lZlOacNGTab60kGR5aIrCi/w0fCGfpet7Z2JT41iHFDf9kYYP8jB+qGn
# DATA r956z4uHgSJl4Pg7pU2pwkzYBoJrcbwCbW5+HV1s4sxtg88Ldm5+Yhx6zlkPZ2Q9aCzdiY2Gl8KFeH4GwxnZCyuZC8e0Fs7PWJBK
# DATA Oi8zjKHwfDa0s6DYWdkA0BwWiTvBEBwqMmXMQG1yiGfzC7KlHfX7E3TXWMB7BzOINjssWFIkpnxpB/aIPwrYQSHeP2RYrDbb00hP
# DATA RcbXu+GIT9HG8cqEO4C0YuWb1TAxypA9sghH4udQv3ZprhzyAQfeEXQj+ohGNI+T16YMjLrjgndbx1sOKChYWNYJPGO3yFkBjSAz
# DATA mhZMMkN+QBcH0sG7lMlhW7zHnPaBuGt4L2cwYI4OTsijdQFEpqoE5apj3jnmnWPenSHzbsXR60QHu5aZ5ec+0zgNj+pJ5xkOgOcA
# DATA eA6A5wB4DoDnAHgOgOcAeA6A5wB4DoDnAHgOgOcAeA6A5wB4DoDnAHgOgOcAeA6A5wB4DoDnAHgOgOcAeA6A5wB4zw0Ar1yqdCrl
# DATA kwPwKi8UAG/eCvRKFDyLF1dOcHRyGi3J90ZGobTWTGVXtbbZqAUZslq5TAVQXUJWs169eeJXN8utcr1y8leX6yd+daXZaFU7J391
# DATA pXLiV9fLm5Vq4+SvrhafWVlXG8+srGvVZ1bW9dIzK+tUu95snmeGp9r18V79tBmeatfHe/XTZniqXR/v1U/duIrPrKxT7fp8yzrV
# DATA rs+3rFPt+nzL2m7X5Vr9PDPcbtfHfPXTZrjdro/56qfNcLtdH/PVT924is+srO12fc5lbbfrcy5ru12fc1nb7bpSqp6rqbB54lc/
# DATA bYbb7fqYr37aDLfb9TFf/dSNq/jMytpu1+dc1na7Pueyttv1uZS17XooF71Ko7xbqxf3GrW36Wva6dBo1WvV9tzHqtUGP1apzz5W
# DATA haOjcRxzTE1ALLh8qZ4KstSsVMqzMakVa165VtstF/uVmlfcLRczudGqBbVWYy6SvXkimnoloamLP8eiqTeLflCrp2nqpc1KqVxL
# DATA 0dQzfHXQ1FvBZrub0NRr5Xq92jI0dX+z1fWLCU29Wqq1y8Uzp6mzMzjf4k36xtMpi+0ai554W5visLafyQLRzVLcvGU3vVGjwRs0
# DATA sT2Tmeizux3r8LPKa/gg2GrbMurWtoyFQHcr1OWsdSku5bSsmWUXXSP4WMKu34n2L23Sj/hT9FQpflqgV/XhAluwBFueCW55HiYB
# DATA emqrqd6/JstW5tfhnN0Haq1X1zCzDKD2giae7lzmREF6ebu4GLZul9QSd/i8usZObvarO6i6g6o7qLqDqjuouoOqO6i6g6o7qLqD
# DATA qjuouoOqv2RQ9cRiVNoN6xvGvqNUe7dF+yMR/rgsxCrustlW7h0wrlxERfL9qBNsCbqCLso2WzTq5JqITORhg2yVa7V6ja9iliey
# DATA afGWZqPz1FghztVvaJQakI6IwQUxhjDbVlMCD/sKNpL8UpcXROMOQubCxBdUc24bhZiG6mC9mKtXN2Ac4aDK+sUPPlT/Xdr6xc/w
# DATA 74iDuXdxJ0flanHauWy9WTg9VAW2PtnzB2Gv518q54a9CU3740uVHCTjLtU+/YCjwtNYE5d7Gk9/Z7KzE8QyLrIAmXd7+8Ylg41v
# DATA B2FvHW+4kM2eXxVKTabJvxW+LtD611n+J9HhzYQiAYgADk3yEYTmxw9DgcqXCmUdJDpnxRLBqCCCF9DUE6FDfqGqM9DEG0Oeb0zm
# DATA sq5BoiQEyRYFpOdMSDRk6epry8wpzuCwu8CS/cRMNCCRlpGnpaeTSr5xGSMLHFcZjRyIfagEQMnFlrzhGMtA8PNcWqDD6dQ5nbrj
# DATA 6NRlxFycYp1TrJuj+bOYZfG8KNl5wxHaKWtopeNkpOy205JuOxNI40KYaZF2mwJbDMCbDduhChrzO1Zj1WJVTKPNStKl0VozcnTm
# DATA vt3ylVsYmqhr0REXb7iWm/qNjNtKMS0hX8EGjphQDwwgUDdYxsmziv6YBeoluBhavp6M+XqqexlisdCaUmpzQGx51pOM84SyFcU5
# DATA gDY+JSWEca05hHzkL+pydIKHgKiJrBd6KvMwjVSLlPo43W8ou4jl9hKlWzU06vTfMYaUpw0pKNYB7yNKxTQfFuqJyqGQdSwK3m8w
# DATA cs480t6dQLdY648pc6Xg8aQhNdAKHlgAqOKpzaWowolFQcYlFPqk50Yfy5iVEBFmUDG9ypwliJflyLbq4iVHVK/OjcXkxjgaKrYB
# DATA 15VoxGpyUD+LJ0OM0NhyDD1nqmvtoGP1/2P/gcAVYBWyPYPJ1/BAFaoeXPx9/yCxqGQAktjDV+3dDdiRqePGYFffMsUYRGwPOVy3
# DATA wvGyZPP78baPIsq0FgZDn+sczRt0wq/Dg+JZtr1WBWQaVFovUGioLNpFUcLC1pBLjqXk/A514aEh2yhBOZ0AkaHT8Cc9wUgE5TTr
# DATA hgGdftLKjKnGVDttyqlsoD6nFx2w1zcLWRNlsJ++wFky6jgD1RmoxzFQnTn68pijC83M51xY2V7gn0WY9VJ2qrQY+nu8ywMSbBVl
# DATA oSaPsF6PQmE9r/LLL5aa6FFAB2srh+DmeIvMlVepg862VH0cLbXJq1nMbPJSR838Hn+b115mj4lJ629HcEvJGw8GbR0dpb505d2Z
# DATA U2bswSebZ4GQt/Usf+F0ZSBgeiON1sp+XdmMu1p5mvNHG2NssM0Xb1ZWmZYHZl7HZGjZkobBSYM97FE9XTCYr7SBmTZHLQdfBl+R
# DATA rQuvT0LU/Fm9bakUM8SuIwkfA/XiHEVkFJDp4rfI6laAj0x7x+lXaQqaALxbuXKnL8Bvyk1DQ+bmxlq+viIi76VnLSwDDur7MIiG
# DATA PWqh7/O6B/IimX+wmpkiLopMckonPG04jn1UXA16M9ZiFinNUValp6OrJn/G2MfsQZenYqbJDAM7IWTGyVgSzFJUV6VKe0nEbo3I
# DATA iGyPl0fsKq83eDEs/gMdPXVRZtJsgXs+qhLnEXJyf8Sq2dH+gKZs9FPYhxy6rqxzY3NVJnuzsXkJRYodN9lZ8Se14rNVzvmZnZ/5
# DATA qQ34hdOFs/MzG554lsdhsGrPJebrPPjLeuWXfrj2cCj7dngVnEyZIJrE2td6BM84Ccb0e9YlA/BtHgVgLq0MNDZG//vcDSJiaYCx
# DATA viFhLJtpQpYrrFbZ8Zty3C9mEKt1eJnm8cfF96LU2Wxjv/0SRvFsyngt3aQO3xgxoQzz9bfC149ETFvBpPNAXzTxrB5VLLVjcKZ5
# DATA 1V9B/yiqcgF7Qqi9UiYsj7R53MJO6ysJb/qo6FZWjS1v5Eg6sD51DNR3ZOKI3Tk2anzcSXPG5buJ3bYXk8Wkl2nsqK7ApL6mUcnc
# DATA QYwCXrPQnukXF1Bt1gqkA+75kwHNh7AgEI/TjGqT/g7gNGx28RqBRRlCzz4CmRkIaellCt42Lu+FZO/Yi2RsCQUP22o1w5P1CHXU
# DATA oauomdjg4QvA5iDGhjWedfCMTYwoXqtQhtLIDxW9CSxpfyg9daY8EweK6h2TTSSpjLXcIwbJM8tFTopd8iiDY5rDYeIVtiyIiZlW
# DATA nSgQfJSa+XngRO2jklFmMDK0PVZ4HzMKHc3J/qnNmixg9iQO2/DyhJGFzJ7+H4dfTL8+/COo1tPvDv80/WH66PBLD+xs+uEv0yeH
# DATA X87Ss/95+uP0e7rvD9MfDr+ku6df08P/Rvd+fvinnEeffqQn/zz98fB3oGgjaCFpf05/P5k+YY72Z/TIv9ItIGl/49Fd4HX/iYJ9
# DATA QsE+wtPTryha3/CTFMRX9PcPwHIffubo2s//hJA6sagf5EGWE0SW5k5xX9WmZgoQXo+XgXm1/JYaIXxt0+YECcbOKTLjhr1A8cIU
# DATA 7Yp6v5GG2jMbLDFal1K0b+Mh6oMCh85OzfeS7uG84dlWiZwdMVvVqtia6fEFrphx9u5W4Cfd9ev0hStjK6Cx/jRR2RQus6tDPZKp
# DATA rRUzk7qXlJW9QqGdOin76m4EnXofEHMaUwfafqUMZreTIkpyb0LlNrMHXHy+ZLFQJ7UX9C4jrru8TYrsu9j2Uvmx9IZ6c8px6t9i
# DATA CyZpTc+KfX1k5B322g3rTzmsa7z18Ubzl8Nze44j+WkO5CuN48caxs9lFJeaaJKe7PZ9pk3lLADVJo2yPXRR8rjzVh4fLuec7KSk
# DATA NOywVIY/3pU0dLERcleWbGX1mabnvpBpR7sH491+UmDWXkhf54ZCFmMoXoVIfTPyTHQFvKuZyxybQeRJq5kP5y142/wjC3THQiZm
# DATA RWdZwlK9KgKKx9GQrK1dRcEd+y1kmBywE+shSZUBZFN+tcNY9Cl0lrbhjHB8aceXdnzpM+RLrzSkrDRfWdHwPR/b/SSm+ylY7g4k
# DATA 7UDSDiTtQNIOJO1A0g4k7UDSDiTtQNIOJO1A0g4k7UDSDiTtQNIOJO1A0g4k7UDSDiTtQNIOJO1A0g4k7UDSDiTtQNLPDUi6Wq74
# DATA tdoJQdLdSrfYrb1AIGmz4rwSPdrOD7hYa7XderG8V6kU36bvf5vNx6C2OQdv1fRKzepurVrfawJv1Uw/1i51Gp1S9rF+qVrzyvRo
# DATA pZgvNbxyhT54lWa+WvUq9H/6rZFvetWKB3hWKV9p8rUybq95lU2vUsLduFz0Nr1qM18u2W/lnZBptlWlU/PrxXlsqzl1o4b4NPZK
# DATA 5SygrVVvlVrteaFUZ2B8NiWtkkYGS7gWwKueVN9KmmQe+LVGayaG5XL96WNYLlWSGNYqpxzDzc1TiGGznsSwUT/dGFYa5aePYYWb
# DATA xBmVcpUayVPHsFopn10p10rNp49hrVg7u1KubZZOIYaN5imX8nFAejIIaZCejGcWSG+zWitVNtMgvSw2j6/4WZBet7MZ1BKQXt2v
# DATA BY2mAem1G60OzdENSG+TrONK88xBerz9M7/Mui9UMny6T62HZll0KZdQqZme9ehMYBsLLlvKe2x6XM+XO8HORirkDKHvrYDG9dDP
# DATA Sdyzzu8Ku75lyZvhfNn1exUyT9ZWXVMraPOd/bkVK+kIxtMbj1KWu3Es4IiB9oVjY1j+mEtA1XkOaPbDWeEpL9gsnk/VpnRpoDAs
# DATA r0QDyyvzt0PNvKKAWJPNas3yyUTVjcEuYbKKa+3NxdC9pIRzdpksmUXM1jaVXKsaKWf38sLhqQBq/cJpVFJQx5uPOgiggwA6CKCD
# DATA ADoIoIMAOgiggwA6CKCDADoIoIMAvmQQQNQFNVHcYus05+PQZw4SvqMcy7AVL0t+8OmwLaktYec/buHHPGrLZQ5ExCO21PCmvlLc
# DATA Pijmyrlqrk59ZNjN9pDqto0N/bi5+zK/zlTE9UEuBP9toLu9LfWE1ettXB4szSUA5PSIlcRPvUdGyYdbVx7qN0hPRleUnftQdWf0
# DATA H+h19hxjiKNj6xufpHLyMh8C1rYiZ+hGJlWDrSuUID5+CWOU5+1ofnwODkkoyMlPhfmjoLlXUhC8DTbn0tPQD9fUeT90FEmt3KJR
# DATA lyVk5ZQx1Udh4N2WQ8dIwpA6WMbcmYSN2eIFcu9n6u0bYvnPL5sjUjKOdnZ6qZTkQmrnqEWSJA70A3y/Z4pAARWjLa6V2vaP29B5
# DATA RHI3cjupn96iSQRV7IiGrIAyZtA+kELj19Dbiq+VmsVLlUrx8k5hh+6Fsfgb3LDNRv06Ti3kVICyDR2XN/TdwcNhNIBgm9+77feH
# DATA d6P0s8XS7LMXCsU6IkQJGVARre8gMP1F7oaSXjjglU3cyR6odfkUDdfnhdigYpICvCWZyYKJgDuu48OFEjMbo67X5CLlxOtfftm8
# DATA zHVxy5rIoKRzlSJW4AQACTdKxHXtUzUnYWV8jWDU1eGTpO5fVlXjU90GeAo8xnYjLsLtq1v74YAmVgU+Vc718uH4t79VF/eD1oNw
# DATA bP8kvcXVjfEujdPetdGIa7ccSbfGaaSPs0jqwW9/i/ng9lWKkL/vhzT74+xDP93HODmnMh+zFUVDqxFJ/ygN5fKnPNu380TKSOKc
# DATA Ni9mj6+L6JEo8ED6UE5xtwIvoGmabpvU75ip7Jyujs/HhT2a1qU6PRSZeUyGvA0rlhSoKoU5QWKNnx4xQVnPcda+Jq1eghGfmjlU
# DATA 67RsnJbNPC2b9EFrJ2rjRG1WFbVZKEB+VmI317DuwqMr1CYGgS3booVvnp2A2nmojIspQJfv4oO3juKIL/bDwWQcHKVjrZ81nZO5
# DATA YCSXlWp4VhJa9oYoTejyMglrfcyXos3HdaEYf4Aui/M7YuEMKh1eQNuVlSYuTgpA7k9njFlPsnLC/MhmKS9ZS97wFKjId6YzQntw
# DATA kqwwtyZJ5wdLGXXr5e8qrf6uUjqb8WD5WO8qr/6ucupd/GDlWO+qrP6uSupd/GD1WO+qrv6u6ozU+pXasd5VW/1dtdS7+MH6sd5V
# DATA X/1d9dS7+MHGsd7VWP1djRn99ytN8y6tr2La8EJ1dXv6+hMQU9dDhSBdtBKRNdpQ3/dA0Eo4OkNTOenAZITE7AHYZJ6k9yG1NEp1
# DATA eRJCKedVcl6Nh6MGKFrBgIVUPewg4KAFKNw3JDArYjRQzfefeuhfGWZgyX4Zb3uiKkXDFOYNWhEMgyDCFKvx+HpgK0iZv/hiQg7a
# DATA 6qZOy6dObqb005wpHRfE+sxlQXlzV7LP6ywQnpb85ilzO23x0rmwzoU4WdYQ5JOHpqUKFwUy40uwss+BOOoLIha4ory5l+wc1MaV
# DATA eC31fFlO7FDu0GQaKppQSTKG1rZSaPVHLHIFxygZQ3iazCqyr5h/ymsvItY6lGk8b+2CDiPm6byrKYcHVEElyo08oadCCnv0jj3s
# DATA RBQq0A7YZCw/SS9nRg50+bQY+vFzEWYfa0ZmtGPPUzL92VhKqWrpjCVnLM0zllJdlXMzv/Ru5oVG1rPXVNc1n6qzz7LSB/AADOg+
# DATA 3oyUaKwPR2iakAHONLKdCc2P2dU8CpQG9oy8NzUXowBuKYNHaorPdSjjWE5ZDbMi6uY+Gld1M+YRiUrX6Ctj2Iy6Xc/fi8IOr34O
# DATA ojBml/hIa2pLd5CAx5OEaUW3gneHhmivS6GJiHrM66RylBiDb0/iEvP+RQRyYLTAqWeZtGJq9JOxGG4sIwfmd0cT4RDjgndD6Wx7
# DATA /bA9ioa77IBR+LjAb7NbHs9TDkC3Gt3XfE984u7x2dYYKDV4nSl3grGYEXEi/dyLsJFlDJqvbMAb+gw1tLo9DdAreNvITAo6HA4V
# DATA eBtBsEvusoeFbVxl9LYvd9ll7uGMBPriAXJHo98l3Zwqb5/exivjS5J304ddI9zinciozuMqm1tUEjCLpYA1dp5KXSr5OOpHo1G0
# DATA r/S9pfrzKrkuGq76nmTiAPs6o0kbGjCMQRffVXKIN0mbMNwNNJ2KCgOfoiwvS8+bLM/PnjEs8MwAcnpk0fEUJIC1KBaoUoSPMEiN
# DATA eQjbJZPBNiypTWLSwKZeLKYh3d7FCXU0BTMOSnUADlEwAXjRg4Dh86h5lI19KSQmT5NluYOq3AOJniIzGWBgxppSNIyziRR76ihS
# DATA 0OtSz3nlCvGRHJVcmGQ9wog2DzapjbRWr5vXjmMMcwu9ysucyOmFElMKSzIv8SvzK5/ytSV5Lf0izco0vtN9DS+XSKNJWFjCLOBG
# DATA dLpv4wWT21yyprKO0elYnTBayum+lZdOsO97ccNMv/DipPeUvvif7uwnQVzS2zpRNIptvuW/TH88/D2AlId/ZO7k50y4/Ozwy+l/
# DATA B1Fy+mT6eBZw+S9MsASe8jNv+i3+YZjlt9Mnh7/3GH352eEf6M8XQrhUAdOLGGv5AwX+ePq9plcyGJNu+xaUy8eH/0C/feMQls//
# DATA vO2OzLRGEYwkNoWxaBRNdnbHzMgRmWk1vPbCMdQ15BSxmYhNBtp2IVMKo57P8FYZ8NmCiWXmBgwKzEKfz6Au5Vfe4R0X1BeGPe8j
# DATA shjZiHIky2QOp3uB88ZYzi2YswNacr2MrfmjrqaCPErfjMpqbr2lai6Gt9OkWZKxykIKag1T9ppQkxg6kuUKpXXqIMtttbWqR83j
# DATA IL/v9x4kpCYyq8HbAf5HJQu2btvHcSMaZUeQZ1N4Hb+DEcJAowZBQEY+FuCpXh7w3EBRkHB+fjhDsjyi5i02S+Y1p2dFtDwiEY5n
# DATA 6cb4pxnjNczypEP7S+GaPbdh/WxG9ZUG9eOM6ecwpEu9nJMDZkB/hu3nLAiXc5Lq0TyUPjF7zlfLpJJcxDLH65w+sj1sY5xFijm5
# DATA 86LMG5/Vw6NIQIHSN7Wwbs7x9TlugxRqbxW4ZcrRjSipZBjtT3Z3Y6uft09zbKwBi/JBLFRA7704MaFk5CfLDbu8uxSzEIaAoAnD
# DATA Aa8tGdolrJ1QXqA8wyg0XsjattCQyrfaCWiM7IdkNuzvBhwL32PThDfYdQNHu3S0S0e7PEPa5SpDzEpTmpVs4vM2709i3T+1ce+Q
# DATA lw556ZCXDnnpkJcOeemQlw556ZCXDnnpkJcOeemQlw556ZCXDnnpkJcOeemQlw556ZCXDnnpkJcOeemQlw556ZCXDnn53CAvy9Wq
# DATA X6ufFHnZDDZb3RcIeTln5fm48Mtq2avW6x7lm1eqFHulYs0rNYrXq42m12j2ys2yV2lmuJZ0b2sWh9kvbVa8MmV0rZRv0t+b3mY9
# DATA X63lS6V8mcKv/e2NaonCbtZ69Uq+VGx4zYZXKjfyNbqlmq/Q6zfz5Vq+0siUSS1otDqzfMAKRbvxcalWzNeKXrlZ8orjaqXpFfca
# DATA zberlXQY9Xaz0yjPhtGserVq8eN8udjINylS5Wq+RHlBMaohpvlm4wiyponcDEev1JTXtcMRZkttLv46R8Jrc9GWpOaOBFSYim+n
# DATA 1qxWqyeg5XH91bQ8aQoWLa9VrwWV0gq0vHonSNHygkanttlKaHm1bh22taHlVVrVZjmh5TUb1VIpOHNaHlf7/HLDgL37Gd80FRXO
# DATA Xn5qBaBtgxQ7TRI9i3NT+Trr/8MfauGXj1pDmG/sLIK/WbE8msJnQ/bkweNB9qqzkL0kmGNA9rQDcmEe2TmtMlRh7FT9sz1GZbbT
# DATA 2Bgwg9iCbQR67FYLXMXF7LskX3N2Vi0xJ47ICUO0c/A5B59z8DkHn3PwOQefc/A5B59z8DkHn3PwOQefe4ngc5w2nEbIa5uH0vja
# DATA sgGNEUSSQyw3NLc/9Qx9DL1Bb+vKem+G76RSvKE7stcomIf3ZFrzgYcPGxd66UrGNX+j8FEUDiiAD+k/8KEuG/PywzV97DyJS2H8
# DATA EPn64dobMyfSVQAX8FmToq6aHQo6VA1+0mwlpxDuDlYvOVjtDlS/JAeqj6sX/mwPWrNfMnGlzeKIeiktzJ0o6uBsscd+QnPMlkkS
# DATA CGSJzvazPp/9IpxR5L9PWat93kHy01Ztn38uf65++wrH5BM/rdEPD0SgDqWtZSdV5TAaM3cDikIc9QMIwfDRWqlqfAJeud+YyCK6
# DATA genz5cnJ8RxkkMnWTBo7zxmhZwoPcNTtwjGtDzSL7iECl6rGr8gePj+OiPhMNZEDuX5inTwbsZpncZrVPO8MKmdQzVGjSyqUE6xx
# DATA gjUntaMW2mtnI2TDfbpuBmRJiXYFa2DsRuNoZ+QPdy1R8Wemm3YKAEsal99QMjTW6HVMzWIxBhDIKQoWq7FfD+Z9f8iZY43585Rv
# DATA T0W1+H2W95a+kWojFFLQ852BcPGbsNX5RQMveEj56MWDU5cPZtHidwbxpOePRb38QCVvHwkdUife9ai/6/XOQrZ4wppKY82dmbAG
# DATA eKY1nO57a6I8DYnvjici9Hqco+HvdN/F9MdbwShmKSasVDHfXmRhmG2U90My4CdDapDBKatRN5JONGNBU3H64MEKA0QM7lOWiM6w
# DATA JpNpmQSZdkzSQ1oryOsfGPNDehuDo0wAkLaiulkOShTlMTmw649qQgeJ+pQMaHLiKF4gLdUGYFHrSlm6VFAFYnEp7w4EvoOBx+CV
# DATA QZsKSstPdRX1gPI+ZxSyItU7a0lTLDwdaK0knhGNJq0WRPK5XJhJjGoS9RhfLOOAaByNJhDy8nSmGR0v5d4M5AVmsdtXuqmroR5/
# DATA OtMPy6BwExA3AZmZgKQtTDcFcVOQ9BRk4cTiWWtpKl4HMy12/SHDhn3MMGxx7DhQuntaCjIjFsmoHa0OqdBHgUxmLJ3HsS0AibGy
# DATA tw9+0kRwIVmJR2mxE2rK1HdRKewFc5QeV1Xb5NQOr7zJS5tJvFsHyeyIucutSdjrGC0+FRl2NM66jdXhUQtAr9HbstrPwCp8UhaW
# DATA soD0jwk821xhFYFdZsVwzyaLs7J7hYZuKylpCLh6r9lCAKtUfX5VNkaol1t3mJ7VfurViHvYxPDDGjzGWGo26j62LSPlyM3eThNU
# DATA dZjhLf60+M52L+y3OKL4sPg+6pgjbMqiO6/Jx+Tei5K2KxlMubY1ZTXeNjUxoiwxNFOli83A0uzVGenEcvZHHTM95c0PMlFV+ZjO
# DATA hwyYi3dSm+5AdhbIxHbCt1e9B32TjGy8TaZCObJy5XbIrKZOwDAhaq0V8RL0o3jcO1DwS/wEK9FIsfNajfC6wsFYhsBA5DCxSzLe
# DATA jZSeqC/Qcy0ey0DxgZGapZbL02Lt3lZSmB4sM2UdqoNa55uB9WNk4Ps0J+6x7z4ctWm6mGQh5qjUMQDFZXd0apYDTwl1Cx+pLTrU
# DATA k13lVQK2jXlvJcz2ftTCI9T7BVKnqSgexLJopihgXBankV1WKzlmfm0uzS/T5CTD3oXkJ7WLncBkFbwJfE86jwyCSzKy4L1PY2bO
# DATA Y5W8kIywA+V/UhAx6s6FEie7VcQdpjnzNGwwxi3onEZWmY7nmBnVWJpRqheTbHobfhwx58OBVav41VQh9imWMTti/FFPrZ5q3wyc
# DATA CNgG50OrVla6eJqNn+H92zlI/IUBlgCxJ1/IuQCOcZ/H7RCSuoyu4JueaZusHaNNXgeIDn0atbs8JTovkCtT2+zL1NyEWqcy0lp5
# DATA C/z4AIt7mghHj5DNL9LDnJ9ii8TAeFkz8mdZwUrl1WvY9YiKmMbIXnDAboKkjvXol8TCUd5dcfjR7JaaIHviEmMNGUI9PDus9CKq
# DATA WhQVawvqwDiRE6k6StaKuKBAIxyF7bn5lh6IZW+dPRCbK5INV25GehecVp5mE0ztToNTRJWkokTr/C4cxRD7qTggEpbYMBgDzWuj
# DATA xP6bgMS86dfTRx5jvUD/+v7wP00fTb+fPpnFiP0/08fTb/PT7wAAO/wdAGT/BlzY4ed0/S/TH+jvr+jvH6d/nv7oHX4hoSPoJ4CO
# DATA PZp+d/in6beHX9C/X+JNYJHRmymMRxTCIw0m+376yNHEXgAK9EBWfrCPp61U6hMK9DCIhsxvZMA6D+3U9sRA7ERQPmdvIwYayyWt
# DATA xHD5LvTRibA6v4F6kFAk5Nl5vJQq9hbMJWa3Dw4cTsz2oaiO4LxpYukCOVuMWDiw1nCv6Vqqf5lliQ3GOARo+lh8lZEuGJ0mT8wf
# DATA C6Jg149pOIUFS5Zu1O06nNiqpXbqTLGrfq+NVcdAFsAOEkC13+ed9rwE0uN1Eq+LqYTHXDiW+zOrHCDp9vsBT34xlvA6Yvi3AdM3
# DATA vE4YjOdgxI6sdIutk1RbenYMsSNT4DhibnQ/jdFd88SOPai/FIsi5zWgn/J4vvJiyLFG83MazKVG2nmQbLd69k3nLFBidlrFMax2
# DATA cOxG9BwWH9IJRQpMLHVhYZFoSdLfAYO9N4yFqsRJG/vxA7VXBREIBzg5hmN8KktWQ4kBYCRD9R54XQrW1EnITlJtZFhva5sA8KkI
# DATA G+1gE2BtKyQDYY5dMIHuQjieZw8oa4DBR7ADsHoVP6DATDxCOMe5NlH96mGXNvaQTcajUMosGrSD0SB2HDHHEXMcsTPmiK000qx4
# DATA AmNF4/jcjPyT+R5PwcR3NDFHE3M0MUcTczQxRxNzNDFHE3M0MUcTczQxRxNzNDFHE3M0MUcTczQxRxNzNDFHE3M0MUcTczQxRxNz
# DATA NDFHE3M0MUcTe35oYu1aeZZ0tSpNrNutBs0XiCZmLzsfFyNWqlW8ymbj43ylmC9R/jQq+VKt3stXgdUqfVwqVfI1r1Qte6Vi2WuU
# DATA 8w0Pd+GOUhMYsHTWdbqbm43uDGEMgK9qcdMr0zuqDa+6md+kC2WvWUeQNa8GjJdXQtibeF1lMx1srd7sNLtzwFyVogXmKm/WDJir
# DATA VEzXh1a1UQ3mBFCrWgFULLJXc7ZKVOeRwcqN4z5v5Uul0vAqlA/lmtfM01+lUr9cLVEeecjcImfx4oTYpUh3Vmu13VqjmSGdmQdm
# DATA SGf1E3DKuGUYThk3MotTRvWo0fBX4JT53UqKU9YtdxrtusUp26x3GwmnrNNsV1vVhFNWbtYr9caZc8qGwfhIShnGF33fCpgvy1FW
# DATA YTdZocnLYxjSNmZJYCZkjTlLzXSrtV96NfpTrrHTMYXmkhyVEFSEV3OqqVQZx1rZTHczby9X2RfIbryMbSOepyUIL52uXCp+S4bw
# DATA 1G3aBeaQXQ7Z5ZBdDtnlkF0O2eWQXQ7Z5ZBdDtnlkF0O2fWSIbuUxWFxuDr+Qbx1wx/vFrq9iCY2MPs+XMNhLEr9r2DSXFTX+HwU
# DATA LspXmmbBUKVWw9bnh2vbQ5rgPYSLMugdUG5cQNAXKFe6E5EL4+NhXUvnSp214lUkkLKA1NKHuXx1OAsaZAhSjt34fEgbB1TMGSzR
# DATA +3OULXfs+LjHjt1x45/qceOT4LWeg2PI7L7T/q7llC0RsDLxnntUeQ5f63k5vPxCneE7C+BW+rj1KZO2MpXhpIgty5GaHCJXOZ1g
# DATA QSDPKALySnWFs2u3cuVNnuCzrpzWoePqA6HQgdKbk4Owpvrs+/REK9rHaedgZ9KDfJ+WnetDTjTqQg2/MxlxBfVHfS19r87E87t1
# DATA BLbJtg7J+OVtszoKmhJG2dPFImmLtTjH8BN5vDlFLBMstfY4bdCz47aAE5WtAC/ukE02GbWM8ORLctTTCsPZVc6uWiLWZlcup+vi
# DATA dF2Oa1AtwW2djd7LrwfRPrp/URxo+TuisQbJDTWwlc5fTuwU6Fq8AqF2gOhrKW14nujT1fcG0FsIlAyLcYt56w92NjIkoAGvAyWg
# DATA HRWE6ab09xQOiRJNXTL0ZPohy9sWC+izqWeRLTliHGEvZ/LjAjl78UMA6GMLtgyxxZUG+/Uj46ufT/pVfSGBcDWL8+Jsxxjbdewo
# DATA L4kwe0qY0gR3daJjg4w6Iq7qURNV/T2FC1saz9KSWGYISmp9Ca1VOV1EjZyrukVJQqW68qrsNVXxVGuMtpZvckl6l3BPUkDjr2K2
# DATA XpQgno4CZTGbrPZtCx8pfXqFePHR7I0+4DW4nuwGzA2atVKCh6GouPBwhx5Hu6A+nlAvBK3yeLKzE7AHGsAIXplQHUQ0AsYCUCVW
# DATA lcYozIEOAKjoaRqXMNDYN67aHQRUyJSfsD+eigZ6MFAI9ncMIxYKVDBOYxnJO2GXpVPGoj/Eys6e2sobmPiIHD2kiTgac9SJEkki
# DATA llWGpxGR8fwh1TkMcKuynX4ixm5qBHPmrjN3F5q7M6aNs3idxbvYhH1OFA6vsvoeNIu7GGTCAcuYzec7ab5sIgU4CvohIzpyi1T3
# DATA 3hSm4Mxww8JmO5OwA5xhMjBSaNReOxMACHl4y5rAaWjCjMChuY/GdcM01b4nHurfY04AxrNRREOHP9ZjLtvhfWrgE5hQyg7wd0aB
# DATA xlfODplK/5BC6tBQbZIDV9XMwMnSgBCXYc9RwJpwnj9GhaYIX7ap7ZoMGTzk7VF4RwioAeX6ghmBSLxFe7y/STE4NT93qBle2Mgp
# DATA oJCHwagdYr9jCoIqGc4Fw6J9llCh8pIVvLfA2eJulL1pDO3ahc3FdzHABMRKuOuuB2PuZzkZMG38ccbfhoNrJrIeH24A+2RZGre1
# DATA HKXp73Ui38esTbN3VN8PlcmcaO5pMBEewfojFXQvzjEdIzbUTm10iZl0E4GhpzyACaY2WvLIMuIhqQVLO+iEbV9KUOEzkZUzNd3C
# DATA nAUPaczrHSxL5U0+UmzML8aX6HRu805PdUhkMsrBk8wK431d/Dx9VKScEPATZb4OoMSnxD8tRhonKa1UWfDuBMEDpoTALcs8D+Ql
# DATA 36qqhVasTPFl2H8q3BCoLcJBrB3FfsyTWn9nEMVhPEPmYEPsKJ3vuxF1TJyfSRfErebYpGj2aesx6FQ40ZabWzUGuLfZiX0GZOgb
# DATA qL56Hww1Vx9VV/Tf9TTlDCjRV1POcrRZKm+hy54BKfp6OOZZ2Yi6LQhBChRSMWu45xSByTOARd/qyTvRQXJqk8bF06zOGYCit6kD
# DATA 0i0evVTH6OtykcJbNOqcMjv5pz5/s7g49NQ4trE4/wUQnOkP00eHv5v+cPjH6WPv8DMgaujrY7r85PDLWTLOvzDq5l8ZapO+e/oN
# DATA U3I8+unz6VfTx4f/oEL5R3Bx6NqPh7/HE/SqL+mX7+mF33iHf58i7VgwHYfGeQHIwgxmM9q1wsiC5xdIj5xsQxUucJe7rX1AufeV
# DATA RbUTsGLwAzicBSc81qxEhozyIAqG4E5vOQHneuB3+S0Of5OaY3J7P2/6jVUYZ4e+kaQl3SLXnS7Pw7K3YuQwN/JUb7R7MN7tnybu
# DATA hjfZ0rRnFzW+wzMCIPd4KyZud9ibI0vs1Hk3mORGLcwxuZ5pjzV2iqjpMPcvPX/UV0tTyeQzjMUVPbOHWvTT2baVuQSVFvVimNaR
# DATA 6QIH9wz+Znn9W2x8JO3oWWFvlsfcEW/coH2MQVuDbY43Vr8cvuDzGadPc5heaZRefZA++zFaqp9JtBmQz68tnAWpxqRHCMlxNiF6
# DATA /0WyiYHtid2or2EwVpnITJcGNAx2focTyhR0Q6SIFWO5HU1GwqZIxledcDnKTi9BXnHwq3Fr1BQ/NQb7xrmuR28zbsd0Y2fSC/SW
# DATA SF7CglfRi4dBOwzinIl/wi5WjtZeKK7XgDpbvxuMD1KuQJUOxukyJppRwG1JVDpBDlDjADUOUHP6gJqjB46V5hyr2K/nY3+fxPx+
# DATA WuvbwWgcjMbBaByMxsFoHIzGwWgcjMbBaByMxsFoHIzGwWgcjMbBaByMxsFoHIzGwWgcjMbBaByMxsFoHIzGwWgcjMbBaByM5vmB
# DATA 0VSqQaVzUhhNqVt7oWA0Zrn5uCSaSrnpVarFXcbPlKteqVp5u1Irp7Oj3W0Wa7P8kyoloFJt/KZUrmT5J9Vau9qcxz/hUkoHU9nc
# DATA 9MrV8r8rbZa9crlIfxreZunjUq3pNb1So+yVaiV6V8Urb1Y+Lpfq+VKFyhDEnGq+VKdb8vSNbqrSTSV6oPrvypv0aNmrUAiV5scl
# DATA eJGrXpXuqdRT6aoGzc16cRYQIxHKkwmfL5Wa/VKV8gUvqheB58mktb3Z2fTb89Kq0DNUiiGZH4pdUy3WEnZNdbNoVeCqfDmYU5s7
# DATA 7aDe7p6AHcMV2bBjuE1Y7JhqueHXKkeyY1rdTreeYsdQfJrtlsWOqdQ3OSBhx1AnsekHFjumVmtVqmfOjulRKzgSHgOn0afJrYby
# DATA YnFcVOpmHXvs3CvTv81f2uZ2g82HJMijkTQ2b4Y328ne4nmxMK6rwpz1U7KwPCxVenX5kwrNUxaNAcrwKGp6/xS5Roo4k2IKE5aR
# DATA V5M/xjUqyW7CuLL9OSVrjUcF0aAMK9Ef9a+2MNl65QFxIa1mhbJMZ116jj03IxYG5KA2DmrjoDYOauOgNg5q46A2DmrjoDYOauOg
# DATA Ng5q85JBbbRBqKV91jZeWzaaMfxG9/p86kI9lkMfOLdr9VTKrEq1dSXUvdcWm8Qbl9HOP1y7mqh54bCKJecyoBxWmi6YvqaZNebk
# DATA gzs37M4NWydf3Olhd3r4qNPDC7Umz+RU8euouVCaSwI3J4ufqf7EKeilQ2sOb94Pggd8wlHa7Am15pKx5fTU5oKgp1S5W7JKQhmi
# DATA 1QeVo/sMZOf0eWMFbhtSqXZG0J7zaI4U9A7OQHPunQEONY+lh42VUjbs5W4iUH0G4nN32fWl0kgmiOrNqU7Q2JGH+nXnDHTnbstR
# DATA YvgAyZRTSTZwgTMpV9aeu4mz1r4RoEPLkxEOJguZl9gLNRkFp6w+pzwwRjo+0WRMKQMkh1t1QsypWcowdAHjVA9iSdQnovAiAQ8J
# DATA 1cxhfe6NCom6Zmd0oDM6QTX4vX1wC/sBS8jjFixUkaHR6xW862HXNIcccA+92baoVFQHiMrI26UfRwEWrHoH8iR3L/t+LNHRRCGl
# DATA Vst1UFTe0djgzRXtappUYIl9TwVArYOiKfVlF77BkToRD51MerRLQ8oiyQCdK/q4P3WTA5x8520GNJ6wFACN1FmJn8xIdTvAcUB1
# DATA ilsmrXKHjDtHy8a/4CePHXLS2e+J/e4s9p+cxX5cpOQz1AHixXyzEL2cI/lmyPLnCo4C0fOBx3t5l0Akz1k+6LmX0zgLPmQicnTa
# DATA cEhbDuqkZEhrk4KeNt3GsSpTHWTix8IpSniqnClI7GqQUlS7G0FsfH0kD4MGgC10Gtq47fUm/XAQTWiKaGyiAVXyCCI2w6DXg7Q7
# DATA xtBdpbhO9teg4L3bErl9Mkyw6RpaSrtkkirMAfNs9NvtaLwFA43v4sToWNyEXURBUOyo8lKtscwuNvn4/EjA2xAOYmip+zFLqEsL
# DATA 0RrPfUhYj5a9n93QXurdb0kLism8jHkpuuDdiOKxtv9EXIjZPzrWl5FB0r7AXoLyDfXXsA0gbE/dCFV1lg3JxuSnLhJj9QzOVnO2
# DATA mj0yOGfry+tsXcycfJYSjjd4sVLXZyXAxkevLSglpPUYjrAH7TZpP4nzJsduBAZMshNNOw4L3q1EDBCncESlzaB9uAzZaeBb+oHs
# DATA 02TfQTdsezFN99vGs9LirWSJZqBoLq6oAckpFsdH0vhlrQ8xGfijkeYJ8eESvAdenzlGojrjOEu7VOvcqKT8SfnJlCdL/5gAEc0V
# DATA znFgRwIOR55W7qeo17NSMJcAaRbPuZrI51dlS4B6uXWH6Sjtp16NuMNM3HdYfcaI2evppdEQ/tBIWXPZ28lu4FYV7S++Z4fNHkZm
# DATA 8afFd7bYTmON7JFYKfrOi5KqJB9kPNbeQlmBtv18GBqWuAqX2oyW59MfdYwTnhf8xR2vctDKgQxIincGm9YvS+lchUYTzoltk4Bs
# DATA jCUvh2ywXYWIYziCkCnqfWK2wl7LK03OnEiM5jEz0xqkNIz1o07Afvwx7FkYftqCE5SS7UyEA9JIdQYsNKSN7LH3tzTgFmz/6oq+
# DATA VM9sk2NLI50UkzVawgyAVyx3cyOiZyyna9aWPVbxJJXvmCV0Z3EJ6WoshXRnyD7YdAlRM+aORDzuwL5AK3OX7B9xg/qe1HVl9Vvs
# DATA QLMGgudlFUSkViOoj2LKgdLFDkZlpTx92dgpeP4L5taqBXPLH/VYVNbv9XXB3Im6DGMd0KjGmqn7mOTRCLqTnpsVvO29KMTMmPLe
# DATA uPVztuubS2VI/QsmZx01S8T08KnLw474uZVH0vceszz+enF56F5cyuOvyWCZ6cgm7fakx2qyWARUJwlV49CTVcXSo16KVxJwHpuG
# DATA jIL3NrWugxwVIZkhUdgTleM+92JRvy/yz2Rc9IUlRj+FyEGzXvz0BZWk6PkvpturFtPtSauV7c9eZxFr1ZsFg4+ig6QH02JcBe/9
# DATA kKa7nQl19DuyFGXkk/WqUGLhgalNedX2J0LHe+qysKP9/Hdib67aib0ejjq8Y2AABxA1joHVeHZF8Xp30g87eSwUssS4Kg8edWI2
# DATA 7CEtNIZl/r6vudTJOr/N20MJm96OQiLjSW2bgBYy3ENPXU6zCTpRaaXtP9nGaNt/5ork/ZWbkd5wqDW4xeQXi5uX/hlq6dOMBdmh
# DATA S1ktnJ4NE+2F9nglLLR4NwpSKLT/a/qvh19Mvzr8E1hlwJjR58+nj6d/mf5Af3/FeLRvPIadPZl+d/inWTDaf2GM2qPpd/Tsnz36
# DATA iwOcPslRiNOv6Rujz+h/P04fm5fYJDW66fvpY3xSHLW/gIqG98t7f5z+2+EfHRXtBYBym20OvOU1Gu9r7Kohc0O8WMirOZ4Z8Tar
# DATA ACaeZgEAGgp3AsvIUAcgcAZ0oEPQDRTRlerxaMx7xvBcV5awjFMAno6l5DQoy6MpiJ3v8Gm2r4+7iPOmp2UL5OwQajRa+L1oJ0F8
# DATA 8Q5DfnmWw32xGybd9Jvh2MJ3nB5DDaa0OreBGhrJCM7Z4PBpR5fWqfPTbggG3GuRcYEdXTTv36Vxx0wvc9rIiiMchkJGwpBFMtHd
# DATA qT2tmN8o0vhDqKQESefEOl85sqlkOXIUsGeRCbP6mECfikjwGhisxjNsteX1crERk2llzwqwtjz6DrDmxv9THv81hO0Ew/5Lsbx3
# DATA PkP+qY/4Kw34xxjvz364l4qYTroZ5Z+v5nMW3LZ0wnmQ5Awx0DGT6tYBQsrJGcbRRF4lcR0L0Cnu+1j4MktvnvRLrSCGSysYYWmS
# DATA E00DdXJsQUWvE3YN242SfeApksmKzLaRMtd4Ww2OrJBBwX6JoP0AY5NCk3EdE+4VnxrmnUBCmwtj3kMVj4XGxUuzQTwWUwH5klgO
# DATA lxXFDPSs8YRC6PuDSRefR7aRoDyv8BOwTTM6yEcDh2xzyDaHbDtDZNsKo8tKE51VTOJztOtPYtY/rVXvwG0O3ObAbQ7c5sBtDtzm
# DATA wG0O3ObAbQ7c5sBtDtzmwG0O3ObAbQ7c5sBtDtzmwG0O3ObAbQ7c5sBtDtzmwG0O3ObAbQ7c9tyA20q1SrtSPCm4rdatB90XCNyW
# DATA XnM+Lr2NbFWvUm1+XK/lK3WvWcmXKuUe/VMue82aVyrSLxWvVKZP9Xy50qtverW6t1n0yo2PK1W66lVqXrX8dqm0+XG+ma80vHIp
# DATA X8tkabDZLXdaGehZqVGtV6rzoGebsyVXLnrVYm231ijvVepv09f0C0xYaQpbmVJQrte8Rilfavbz1YZXbXqNYr7UoC9Vr1r36k36
# DATA snLESpWZmNVKgMQ1Ps5XqFDzyIv6DQoAse1V6EKKFsc7OdMvC7qN+gLMnarA7XDEJ+weSqUvJ+i3UoNBcqxqUE+3ABMsBQDDxpOn
# DATA i8haTx5uNtPVvtvl77r/ZTlUFn+tNKneUBjHxMZxM9LYOGmRFjYuqDWrtVoaG0c3Vcv1FDYuA5ITbNxmZzPBxlXb9VqtkWDjOu12
# DATA q5tg4zY7lc1icObYOLS/o7FxFW0UiEmgn1nAj0MyM/7F2i+9Kv2p0J967Zd2EBle3Dt9mkqMc9gKjPh6N1mxg77aMbenSbVi8XLW
# DATA mSfunlxzbz/Hq2QLVsRUNACvGn6y6lJBoWrlhVcZpYPx9H6KlEFi5kvYVa1dfNrLmWbaqUwq059STZv87CsKx2RhtVMgO+3Dpn65
# DATA PIOfKy7my5ncz9k5sMQUOSKBbCU4jpzjyDmOnOPIOY6c48g5jpzjyDmOnOPIOY6c48i9ZBw5ZXGkO4BwQOFvwd77cE3aHCX8gnyH
# DATA IgxnA5uYH67d9UdQoeVHPLkZzesCX6Bq8SY2062XNi5QbrT7hQ/pv8G2dUr82nvpY3j88A1/vFvgGfo6h/OrUqGGEJLjfXMOjSfK
# DATA t5DiMt2+Rs0lx1bcIWp3iHqVQ9T20SZ3ltqdpV6il/xsz1jL0eCcPus756T1bXMuUOpILq2sZg71yoFVJcjCZ4lhR+8rHWY5yRuw
# DATA yn5yeHLoH2AyLYcnobUysE5OrqyB/KaoHreEEdUBgQqv9k2Hjo7A6R6vonvc9uOJr2TT8GnxnehSKWtx6/vycfG91MF2oogz+l35
# DATA +CIoICd5cUwRxKuLRRB1rooIIhllo4MOdIj8wZ4fJwqIODlJzQsK4u2I3SaT4RDnnrHRAIfRvJHIQsbAc8hhdvaCUVMLCh616hBH
# DATA hzM6OjwedkYHOS/w4wNuKE+ve5hJw7lJVFr17/QUQ01NVjrVsB1GE5iRSdm0J/Eu1dyARXJxBl2OUPsiV81mTmJEwKqEXSIYBhTU
# DATA Lrh36CISZWql58DHwyeoH/CXtjTz5KnUqZMEvAAF8/7KBXObqnoebpUDaIBbyqF8sDlHJTIMuPVws9ENhEEyKDjqj9BwtG4ozhFC
# DATA sQqK4cGQbUNkuKWmIYIDWNuS8S3s7UYTlh59en3XVFLOrZRO3LldX7VzuxFi5ww0PCYjSxmZJig058OuwHE01E2nG476ECedDD1V
# DATA MNGIJdj4V1Ev2adEjaKWdHejAF9ZN2wy2CWjCuoGtozH0xRJKubnViLWIHnMIrm7uEjMcCtlcnfkhz3RS/HJrDGFQt/HME5gv0WS
# DATA wx2a9sDIQ9U0NMyRr5qD0qwGTFgrzSRKEonYm4iw9A5E7e2pCyYd/ee/rdxZta28L3NSmqCGQ6rCpmBQu2E509RdtgjBsOZhnKej
# DATA UPUYxjzeY5oPHi025ipkViya4UokfMyi1ihdeE6fuigyMX55tY5/CnIi+nHn3XLerVW8W3YVc94t591a2Yu10Al2Nt4tFt4yADzf
# DATA 24kiEcXTvq3nVr92me8LRxo82wM249QSuik2jKh9yPpaytuklmcYzTTA/nueqKqF0vV2f0O5vXTDlEkpSlFCNc+briy5Ylw/Zd5d
# DATA O0LPjV6sH7KBVOZt1X2ft7zqjbzBkLdeF0qLHWS8goRaHqlyHRrVsrSfTN1oYqYfnHFNlRShF3ZP55JX8tr9xX6sUqHGDgQKLAxG
# DATA dHehlrp/xpelLCzjKJRNNxTENS1fmOllLTMJ5UdR4MNFOlWy+8o2XZJL0sRDMc+GNB6OZUP6RQniKQ0gMVIwGFntzVazvDsS96sQ
# DATA Y9EPzKhE91ivcaC9tDmZMbANx14Rf8cPZdcVtsQLRopmDwXPQO6SelrwuNByPPhZQBYWr0yChF5lrK1jvA7W1DAcCMYKYZJFbCQI
# DATA saDICmo4NAZJx9aBNE8R5vOhQGmvIsaTHfBreadAsoappq0DLUHJepWJ7OSELdQDz2wX0HvihmzDaLwssvonb3gmQ40zPZ3puYrp
# DATA 6WzNn66tudA6fA7VqvlEhzldMGuG9Swz9C2YnRwrUMhHgSwTxtoKTR5i2SXufJ8/devnX/KV/5ZzOldepR4027D0sUCEa45wNeWE
# DATA n3VmUS74Pf6WFeHOHteTZtqOMFmQdx0M2mJ+G/2rK+/OnPbjHXxUiDPi5tZT/IXTsoKweHJsRdtjGTj4vn/A0xfoORvD7Cov2cnk
# DATA aGAWBeFP3KGQhgeyvChzJ9AIh/4ez10K3m1ezhprC0rdo+wz1Eq4jMUZxwZPdq3Lx3o4WWma1rFSJchWpmsPhz2EGocPsXVdliGl
# DATA ep873OPcjacEU0YVai/o7Uyou7BhZf9y+MXh7xhLBoLYE/78HdBljA37M4hi+OXwi1lK2f9mfvx8+u30CVBk/8YX/nz4xfQ7XMp5
# DATA 06+njxhF9jt8xw38usM/0B+AyL6i1wFk9oR+fsQos28pgB/w2+FnFMy3gJUdfuZRGI/owh9wEWg0xy57IaxDpI2nXvCHsFy5rr2X
# DATA QCT1Rw+wyucPghzcHjQrHfHccejL9AeDDM1QcVSa15Cgl+FNBhwYa5NPwh6zUalF+7ybkyaW/lggqQG26lNntpRaJjDpQAZKBy2z
# DATA bUWrwzhvdFmmVM6OXNYJ5RxmbO58Q13hijpDL8O4Z+6kSic1cXTK8DKe54cxb0BAc+CdYTqqjmC2WqmdOsVMdzbdkJ/ze+JUitu7
# DATA QWci20R6wo6H5AeDnLkX81jt1SvV8v1wAFvb71Hlxj6Sy9rTy+gMscJGAQUsIIVwgC5YzEBlGUmb7Bl886pVc7GJk25qzwpftjTy
# DATA jl7mLIBTswA0t+z4A/9L4SA6z0H/tMf8lYb8Y474Zz7gS31MJd6mlz0XzecsuGWpFHuBzNFj8UgxhduLuul9e5wN412K5Q6vm6DR
# DATA hdinaSwjRhz1/SEnXF6LPkrODVDtBHUJSy0amST7NXnElXrvGXG2eEVsGeecqhQeZccEr5MBH0AQcZfta8OAiiBGLL0ODvzg5Q8G
# DATA 0b6cjuiozaXARg0DLurdaDIC+4sZVGEr7CGrYN0xaIXGI8ZNwVgQDQTGc5kzBArkNIjmw6ccx8xxzBzH7Aw5ZiuONCtNeVawj8/P
# DATA xD+Jhf+UBr4DmTmQmQOZOZCZA5k5kJkDmTmQmQOZOZCZA5k5kJkDmTmQmQOZOZCZA5k5kJkDmTmQmQOZOZCZA5k5kJkDmTmQmQOZ
# DATA OZDZcwMyKzertUb5pCCzbtfvFl8gkFlqxfm4HLM65UmxuluvN/cqm9W361kEWTmot7uzOVksUVZWd2vNBn+uADKmPlcpY/lzs+mV
# DATA KIcr1WK/1Czm6V/1uaQ/Z6BelPOdbnke1KvcnIlCuUZRKJY/LjWKXqkEBJtXLhXHJbiNm0fhwxo1v9Ge+6ZafQaHVmrUwCXzKuX8
# DATA ZtUr1auAoJVqlHGlCpPfqptHvK5dqbfm08osiFoe0wEfAv1So73NOSAziksCMqNIGZCZ4NiSFlCtdBvllfO3PudV5WIjeVWlVDrD
# DATA V1WEyCavKtcbZ/iqWtlOVbN4hq+qM4pOp6pyyhl4LKgcd2kaKie9owWVq5brlWYnDZXLIuTmQuWCUtDo1BKoXK1TD5oVA5Vr19tB
# DATA 24LKVei9zfqZQ+Vkd2Felhn0MFfhGYSnV6eM7dIU889+JguFeyugzjz0c7P0t+o8+hv8n429/Vxd/J8q5L6/GuSt0Fjm1tTTsyTQ
# DATA 7AKJbd7r8pnxbKqSSYXD4hYLXF+/aDWpA+uknV7Hs8M8dtdiqWoxGM7KqiX23Eyc09OiM7QOHWPOMeYcY84x5hxjzjHmHGPOMeYc
# DATA Y84x5hxjzjHmXjLGHOpCOKYZ/siHFjtVsMsGO7d15RMzJxnGW1xPpJfi88u4es9q+dLwt66YZh9213/Gj6qGu/GJ4tJp5SKIocqZ
# DATA L0YcDbmrFuPy8qfy6s5E1p637IB+Jbg7XEoQeMylkyUd+958aeNXpdqFUg3R0aFdkQBaE5ovolBNzFhulhVoB0HQicG7088Akicy
# DATA BLHRXuoG+9KBDOVUnoh90SU+wZhKDjIapxi3tFk/woslq2TxaZ0ndBsFWXxYX/dze7mQCsG/oAztvY1frYfUNIqv1YuXShu5IjZ9
# DATA cavH+tNWf+vKev/KVqlaLb724dpNqpJ8xJJDRQYpw4fzqduLaM7av1gvbvyyXN2gGViH9azWy7kP14q4mx/Tz/R/STfO3nQ5qTmS
# DATA 5agB6zHHWlUdOI+2OH7rSD2jBv/HZ/+MjI0v48qFrXmFuR6+mi7E10q1S0Wdmxzq5U83Ch9F4YCeZXChRFp9vDDnld1wEMa7ShS1
# DATA VNOFidOy4nARAOJ7A6hMCA4AzzP0cD1TYfK6VmzY1YIaD9cjky0bFMnLXOBUEnk9q6DnX1tmMnLLQ+NJwvkE4yAZQ+rQsVbO0OIW
# DATA OmTNVtSVzsy7KHB9Hrowfoh+xoqjhH1Hh6kfogEXYRlMoz6I5pQinFLEcqUI65ii04twehHH1otYqFN6JjoStybjpAHwri2t6Skj
# DATA uxGVeB5ljM5Dx16MFZFxH4kVk1Gux6VEt17fbzovc8EIvRc3L6kFcyVcv0CPXg24rEg/xsly5iEZYe91NfIepaRvgjFRSq4kSvrV
# DATA 4jwp/Yotpd8oF20t/VJtsZS+ZdAg+hxxmpjQrIqrVVpOP3WzlW92EDNq+RyzK5Witj8W6+pXOZ7V2tF31jnM+pwwZ7T39QFGSjcf
# DATA RLyijGJhBqHl0K3yi8qZhAmFSQOnKV1u2vGRzYRUOd1IxjMeCmUCcsW6nCmQ03ntbYyb3OLttyZXz+alcvDRo4F2RN1E6s3pnxK8
# DATA Z1IuC+kI0pMpTMCLi0S4Dv+eSN0oY0Vb8rZyhtGY6dCEzrL7U508m0EQ/kjdogR4qQqz9gwkZ1hPg+EGLOagGQSLNGjSojM2FWyW
# DATA /zWfEyYZmJo/YCTUKxTs29JDkA0BO5Jv8OKLW6QtDDcvcfOSI+YlKfvTTU3c1OToGcczlbjDGI8KriOBzOklKndvmomIAA9Y88m0
# DATA NSo9P2aRKwhOseaYEaHKiXJa3xfHpRFC02IN2clFBr2AbTY29lt4tLYBJnzN90V4LhDCLFylaN+UGKrQsZnSMKOLsif+eIJo7vBv
# DATA k/iAxtwBM70ogdJZ5BSESKZHeqBlID13F/EDHehwNxpHOyN/yEP1MIAhreR9wxFLj0kS08Pe2Ges8o1oJMq6aqzLwk0FkWxZfpJa
# DATA MUcsHBp3ZOjb9hUGGdsEVccmvnusTu0DRQ59uG3hpwlWYte38aLwkIMwwFJr8O0ti33YYatuaeSzxqOkwCAFBCIcG4IwVPzHBvTc
# DATA ZkE4hb/QmsSJsp6wbNPae6pYWuiyhU9g9dq+1N8ladrGDvtBBHJrNlliJqS5sTOqiqYik1l4C+599WbkK5ltuyD4KmSDZAH/AGAv
# DATA Io+15DbLtsGoyaESDSQpYN7BextNYpUfKuCQ8mF7Lwo7LEnNKm0AKEiW0gAVMTG2D6m1IZ90490p86f0HOtfC01EOcBlUqbjjAX1
# DATA lHB11JVZGHTo+v2oI40bhceXTVl5+vBc1O3Cp67LTmtYSxnmvOGkRRaK9Rzrz3Ej9DuwgLwR12GprDR2MbyYX+mBxE6DDlnaMbXJ
# DATA ZUm8AzS4gnuNMYhYSQShTF5IPUMIbS/q7iitQ3q+O+n1DhRvRcWU3TgxV1RJdz9FKmRlQekT9ncjpY5IHSR2glIRj3bRDqXA0Mdn
# DATA EbVimP707GlHC3O29Mpq0M50/kmbzsdlhT1jdWh7z/9yWNhdjAQadslGldT35bSw50dN+oWQVD2KIJHs+9csr9OEiqUVsk+bKZZV
# DATA HJ+LFFPuN1bzRqHyLjQygqRGxGLWRD3bHRoMdSd25SZrlwhXjKYqrE8skyZ6H/2Oe94ME8sZvQckswewy4VGRvUmuVdmJrBpZXd6
# DATA BAsvhBTZgbrpYtRb1DzFXoadi+rLUwt/noNxKSYErlhDcp7RH4cFxjLEwxFqdByYZiYKzr6Zrso2GzLs+7iL7NyUt5VsbogW21ro
# DATA bGnzFFJyasKi5NrAnVlnm7H1fmpWXoI12w9aSvzappr95+nj6b/mD38//ZEpY0+mP0z/zHQx+nT4d4efTR/ZhLHDL3BlFnD2X3F5
# DATA +hU9/JgRZY89+vKILj6hyz+ATDb9yuN7vmbG2T/IfYdfKpDZI5DU6AVf0L9fKpAZx+cR4nT492CgMe/sz9Mf6Qe6/xvHNntRbFlp
# DATA 5Gh4Wnydl6wMeRPrQDSHE3VxnrxFFNwYrR5xpFb+HlQWmSEv3qNoj708/ijxKlkkRDSPpSizt7PRcDgz26ZNOorzppnNKZizI5qJ
# DATA TyWeebm6nr1ddhCYu28HMY1AbRmwuZBOGW0m7iXR84drRRb+mFrgwGYrFd6pc822PUvvPJkZmBrAi8YQ0pn0mMLROsDfOE2h3HOg
# DATA nkgExc65eus9ul80zXOaU6H3uxiICds/e4AXe3SxN8MzW7FmLrZxZpvds6KbrZgUxzlz1sBJrQGNNTuZEfBSOLXO0QA4i/F/peH/
# DATA eKP/OQ7+Uj9ncsJCnT2TFnQWZLOZRDLdjLIqno0WGGeyrOxR9URNvSSgp5z39t27t+7k1MFStTLMJcN7RkdkP/DKDicDIzScEglN
# DATA aaTKUnsedJ7qMXdVvJmpCh7lNZTB0gYAUha2gTlLjIA04Gw4CjrwjaSNAtsYyHEzRWfhwcAYtJV5wFYBOFRiHgpyiuMf02sSuhk7
# DATA VeKDmI9Sqntajm/m+GaOb3amfLPVxpqVJj7HMpDP1+I/icF/ava+w5457JnDnjnsmcOeOeyZw5457JnDnjnsmcOeOeyZw5457JnD
# DATA njnsmcOeOeyZw5457JnDnjnsmcOeOeyZw5457JnDnjns2fODPdusbtbrJ8WeVbqNbusFwp7NrD+vhD7jzFWZx5QwoW1Vy6nDYqV6
# DATA OZ3rFWE5SbY3UxnXaQa1oJvBN1WatZqgurL4pqpksRUPebfEQ9hXSTwq2UNr5SQa1Sy2bh4vrG7xwkqbTcOgShHSflHtNEuNymzN
# DATA aVap6jR3pc5ZyfPrrc22P5eftix5ZSGlnVHyyhbNa+Xk0UOnlryKML7OKHkV9fSxkkcPPVXyKuXyc9FIKpXm2TWSSr30FI2k0iw+
# DATA dSOxk3fqjSSVvGM3EiTvaRuJnbxTbySp5B27kSB5T9tIaqXmc9FIapXq2TUSisVTNJJao/7UjcRO3qk3klTyjt1IkLynbSR28k69
# DATA kaSSd+xGguSdrJHYwNZi06vWanvV+m5ls7qXr9b7+dJm3avW9ypHAVQXN4KT0DDZ0jU0TDaaLRpmpVUvN2snoWEWA79bsmiYlXrQ
# DATA rBoaZqvd7nTaFg2zVJOfz5aGqTbzyuzOcvaoZTfDx+QJO5notlNtk9fY52ybSIWK+evsPdmtCrNLZk1eMis0sVVGFs1SoaoF86Uh
# DATA 13n1LP2YngXO32yY3E2zyZ2R30+t0R2VXPXMnOX52Rv0Sv1Mns/enXgRF+2QlBeVpIjEFTATCJYaZlGfqtqllws2NzfhgTkevJM9
# DATA RnNSxW7DGd/z7HahhdxPR+t0tE5H63S0TkfrdLROR+t0tE5H63S0TkfrdLROR+s8BVrnLJpzJ2wpgCJW52B6KjimZlDRlYulYrVZ
# DATA a9Qvp+Ys6jE+PIzHNOKQDPPJEFculPBkuXpZsTGvqWPs0A8YjHd7B4ZzxYhEignVqzexv3+9zFjEt8LXBal4HefM5ZTysDeJPQg2
# DATA e+pF/KyK0qLnt71y7ZfmbYnQjsxLKQ/2AkZ1rlMcfoU1/o15IdksQ+ucqROEcYIwKUGY2UPHTh3GqcOcXB1moZLyWarG6M4achDS
# DATA XlBcrOSAjTa888aSkHl+dMzOA2goQyWDPmQgYxUOvnoESFA/merm4xSyDW6EuSDBksUR5JuK+k6DE1xMEzTDOViC6jPCZsGSIQZF
# DATA nQRv/dfh60cBEa3gTFLsayY1taPTUj5GMsTaQA8Ar6iYBOs3jo6vfs5E1lywYrpapq8YU20HcTuFUCIkRxK7hbquYRgcVV2SQBLw
# DATA ZHLJRL1xVMzrS2K9EPJnugA9ZeLxUBXyCw/9m0f6MxZiYHo/9ExUx4Tlwc2jY+R1YBtwkfp9ngPw8gwLwqi5ZpsmVawWzVAT7I2k
# DATA 6U3O29+lykfG4WgnsEJTudvtUl/bmozg28BzNLkaBVBoCsda4Ef5q2XmEbMsNysxUZU6EAOZdTDtelbwrkZ9dotR15dTYj2DjtF/
# DATA SkSX1GSuI0/4I6WLlNgyCWS2T/GajNi3qsSHVqAG/tSUYhzzxE0EFkwEnM3/Utj8xyWdPC9KkfZOieXIk7dCHjFFLZHXoyESN2DV
# DATA Hmpb/WAp++TZyUu+WOpqR6lLZ/Z4nAX4ZFZA87ThJ/N0SOcCUFJlp7fESEWeB/h7E/a8NhHm3sGqnkvveF1Ma2NoHFPuW5H/GFcZ
# DATA suAgQCKi8emPpcyVubkKDvNOMu3WeMW37964nvOu3rmTU+OwtBceFpSWOyCWMi8SocUhVEJ9raTKSo1UCkb2M4yTeYMG23EDD8cY
# DATA tpcQFe9IZyAb3pbDIretSKhKrFO0DSXQgZJH5dhxgihhnQA0v2DQhiLoIKD4KT3WHNVeqq67eplN5FnTqqxL0ZzpDuSIqGvBWbGm
# DATA dbQVTJENbnXAMBB/hsBIYfaL9j0b0KMDJYmpYlnwbmlODWLOq2O6I/O9rh/2JqNlNMvbEgwWrhbxLF8iC9zur50N7mzwuTa4qiTO
# DATA E+888SnrbqHx/vzot3Odxkid4Jx9TzyFxgMvvpowxsa9iAfJtPi4dqFn6WeTIXCCBe832CN+YBAtdEdn0oaITB9jsZE2Nv52Jhqz
# DATA vbOykHuiWyDNE1+vvKoNvzs45s0NG/oVsQJgy4xD9QWvXjRW4lh67/EIH0WYG69qi7Oe7I1RRGMwNezduTe8J2N6F9TmBbe8D5MN
# DATA qRQtbhabxq0X8c6L+v0yGGWjoQxVZcAZi4ff1LnyhtqcyDU452FY6VLfH1GZMfaTqtq4w3eqMSLnyWCc01Lb4NwBUxzvSrgdFa0F
# DATA 8bjhD6hOdWxb0ERmO5HAz/wuUbBNN2N/UYmOAoh38+KBtryOjshvwtF4AkV1lhK34qAKmM08rq0sKc99yijqmci8O2RFFXMDVfJg
# DATA zCrpQx48KYN6PV3VYys+F1VBXVSVbgGXfjn2+46285K8F5PP7/Rp0NeznITto5XEFak93o0mvQ63SzFnB7D8sPEcUytRV5cCLnhs
# DATA X5IF3IsO+hwE2efgWfsQh7dk6MGi/yhq8cCpJOYnA2YhqpCWAcEH0b7SK9emsz/e1dF/f8Ry9lTvPRY3EWc3r7dovzE7nckap2B8
# DATA 7W1GL0WdHd+DH5iRmti4QEIBsqhv54kRSPUDONhpOA8G+t6OYj0ma4PLEnNDXNEqPb6I58Ovbtz7yrOOiOn1jISrsBv0hqo/kwVP
# DATA qy9iGXwaKKMUVGEY+A9QwtJjou5hzbIT9PECe4alwAoUiswHGQuPVmBPzZQdY4PPzfon6mfYX5Eh/tOy7T/99N6nHw7WXvmrn/p/
# DATA lPVB7z46jHAwAVR1eHDq78DaZb1a/Su1bpz5t1Ss1cp/VUz++6tiqdQo1v/KK55HBkzQ5uj1f/Vy/vfzn//89kQIEW3qQMIOjzOo
# DATA FGsx70XOM/YjqSDe1evvUK/By5zUvqNeh5fw6YEChfWKSKWQbbvDh23094/IPtSfo/gVHr3Q6ffClqcu36Kv+paReTCetJR/Rl/B
# DATA kSwMB/r7hEyXV155//b2rVvXbmMD9dra2it8xuYVtcGyK/uq2dm0TpPJTnCpG69t8G5GnAxZA4PvIvWKF0H1vdjuhTSDWbv8imy1
# DATA 7sYF5APcfHcOBu11PJTz1mi+3lyzdqCusVMoj9DzSW6tbWxo/1IheBiO10sbl1/J7vtMR43Pkd1XD9EbqHfcH/Cbk4CCNnIr532g
# DATA IjP/3fdyr3ie98lYTpFcKvF2h1zff/j6pIu9j6V6pVnNPSAr8064M/B7l9buvPPWr9+5fn0tF487YXTpgzW6TsPDWm5tGA7xj/p+
# DATA 79MNlT1qY2owGtHQ89vf6o2qMQdoX+DFctn4ujhLZA/xVuq0ln6+g7FgHKljFSr/dTT4wde4oA74JTgYhdf/TA4PFcL4jt8N3iG7
# DATA aAeHFHB7Afl1FSvZG7gzc8171SvOu3yFT9vMTYO+ouK6D0NmXcU3+0a6Pzm1lQ3K+/QVVOJXXqEpNNyU95lutB4O4iGNwvel0Hny
# DATA v3EJRYws4BV0XIINwB8KbE3EmEKtr+XXNvBDLxisy4OUkFqpjGt4chQUsJ+AtxGvj9Y+2M7/Bz//t8X85v3CxUv/U/7ehbX0C/Hf
# DATA yMdU7jdI2DUU//raO4M9nPaxehJ+Zm2Dn1ED8Ra39FRiNnQi5BauLOtU88f3cVKXYlr1fuVhQ6/6Z3kcOFwveNgmWzeWiaSKAezN
# DATA UQe9AfqjAu9+WFfvRNW5j/3V6xsbqTyNKaZjf9BGVeTHcx5OD5jsVFc3qNp5pZVyR011FcY0GKnY6etbOp4fFO/JD/pG7PmWm/hQ
# DATA 4to7HSqWNfV4MNgLR9Ggr/aG2/fRdK4b7tC9n3y6IVeuDfbkSJCd1Gwl8PNdqgH3PqlXP6WbTSw2dKWxssZ6eSZ7rF82VON5mkzC
# DATA aWg54MJfMVmXTiMc2DmQvGK2GPn+HI7eciTXyM7D0xIMXxhlLzwsFjOXttbUnhW5lrxvfrLeG8STIYYrml1Y0VSJwn982vM+pUx6
# DATA Ct4xuE6vyXmljWxi5rfW+/esZnvvV/QkTq0eFTOd4Xb1oeesmHGWF2h4DAYddQDVtNdJfx2FjFsKNNmg7o3P+aHssQ5B2cNPo+TL
# DATA tfoKzfeaFY15TfgXWFuCY8PrK47XG1H7AU7X4B+qfPTg6ICnTzmZL7e5PuIkAwoOnbLA9Mj0L6ggsQOL+l5Fy4Mtgzkt0/vUItFl
# DATA oZ/BJaVn/vBBs2Qopovxro/9V9JcTe+3RZEdBHxRHFnKdCncDWC7+KODN1hYMBodsLBd+HBrjV488NsTHCg3Izk6b5qqdvTNSQZS
# DATA qd1XVgz3quaWDe+it2bXNPOI9plH6E6iuABC2LoOJ4cr795///a7N6//jfdb+Xb19rXtu/rLtX9/9XrOK0ZAepgwOXX0c7fDoSWv
# DATA oO5pXyJPzS3w++naKNfUQIl2WPiICm5dVZkL3DSTl4zthHNGK57almUlFqjA1j9I3Yb/1jpcS9BdylP4lBf3Lj6aXC8kub6Fw16w
# DATA Lgv4q0oD0m7wMDcbdD6vqgSHrvurS3jafOO3GXNaXk7T7HxnFA23tmFxzQs31ks0ZJ9uDSJ6z34eM98QIJlYQqGSy6Pk1rhHMwW5
# DATA MTdAxJKqCJ7UNq8ORbcafIeZogd8/IwvysBOB3svB2fBeDIK7ssWyq27o4k6eK0/ivW5VSnmZN2Ur2+kC9JqMapQtREFP9VwPX37
# DATA asOVDjPTAy5soat1k2yJeSH7xMZ2Lyn2hbLos/XRqn5slEmm++Ox396143pvttTm/bdqnpeWZro6mZc2sFfP7w87n5RyNbEM2IaG
# DATA 3TkYr6tvyk6+dIy8tSaZEqmZ7GU5gOQl5tcutnz0Mt0DRdtk7Gw0lhTRqC/lQ8NYO0gXjyfZtGU9/ca139x87/r1I0uOnqRZ0rwn
# DATA k/Kq6eJ6EwIOG2oGgJFoXVVjnhSh59Yz7ML2aIe9+rf4F1V0chvO8t331e80B8gro5vSpPdeWBVj0TNsws99gm6DLaYe5H/waKwi
# DATA keqw+dzGejKZwX0FFZ+cJ994gqGs2YfAcHrX+B8IsZqAfqFG/ItvvO7xtDNmNKjqam2HdcF7F4O27zG6x8PupQG8lG2Pxid/SEZN
# DATA xhC5w879a5iFrd2MsI87qZFt40Nv8fVuOOoHnTWUEVW0+/dhDtwn+23LW7t/HyV2//6aRFqK7zl1JY5wir0fnIXbbzX/X7lcr5Wz
# DATA /r9isVRx/r/z+O8XP7s4iUcXW+HgIpkO3vBgvBsNKq/8/Oc/Z+EO4dVi8UUWxrDGgBVfLFdEw0BDb/UGrtvajPJ4ttXrUbewxCuI
# DATA ZYp6VX/Dnib9edeP4RvUX0Pog40sJ+DJ/Ymygmi+7k7GYc984zmE+Rb3lngh/ZHthMw6Jce7IyHgmQvUyFIeS47yZNSjGEvPqeNN
# DATA 13jyRx0LL554MnufSF7LkJmMnmpYoEzetjs4mNQ05/FaB1wupjTYUscyyij4KFDrf8gQmXXGXFgy6GAv2DrNcOLE6SOd5Jzo6NvU
# DATA o6zAg9LQz8m4bflceK7Cd1h+F54/Ym/nGu+FWtvQ4cn8YMgeTzV5x16dLZmEyDvGONMy1tMgDlpPUuWnQhjfjw/62OqybpmEnMy1
# DATA 6f85fexNv54+mv7b9Mnh54d/nH5Fnx9Pv/cO/44+fDP9zjv8++njw8/o2tfe4efTJ9Pv6ZYfp9/R7fjh8+m3h18c/iP9xE9/h6+X
# DATA PEwBYJRLDNTIpqIjRxYLfdjj6/IlVuYbT0XvR7bRxqueW9rV0V3kzgjIapB87kz6w1j/FgywRHnfj9thKKYFdothmNwq63mWuFM6
# DATA OZ7XsjCTmqv2H6DlD80EtZDMUMkqoNhvpVI0Z+jHxLC9S0W2jvBRdAtnjriBZoyIcroyYMV9HxPDLZ4UrjSjRKZtzPu525tAMyb1
# DATA E+KADcXr+h5K+yDSzkB1xyhgZJiWl5Jitb0zdA/n38/IDKC5VDpyZnJ+v9ux5t6p7FMT8Ntv2BPwN965fe3q3Xdv/006yjMT4lQ6
# DATA 7Leln5trLatnGeg+59mZZySxaGgFrq8xZ0pmskV3TAbc5PhH1Z5lFVi5kowDG34kpZ0GZ1FlgWt6/bVLiZvrXupb/t4nxVy99Kn1
# DATA +8ZrHxY2LqgL9z4p5+oVzFjsV1u9wH+bfkut/b9Tm/4d+oO/UAP/nlr8D970X7nhT/+NeoAf6ccf6UY0/kc5ukZXPqNrj7zpE9zx
# DATA BX1+YhzO3POJS68H4ZJ1nQk0pJi9i/fR5+vGCueWlZVq8pXxMqqAP1jD3s740sWL6GpUvpoA0LJpih9epHet3Zufz8VacSYb/tfp
# DATA X9DTUaf2CH0d9X+SPEop5Qn3kJT+J/gN/d8fODO+R37R1+kP0x+oB3xsvNLA1sdZv2ZuLeV5LnmvbilvMd++ge/lo8oHsXmC0nmC
# DATA F+P9XyGaj1aNftKjS9d/+OXh79CLm8JTs3nL18x+EvE1c0RtT9yY1XT435lpNKVTflCVILU2Y8ow03pSQX7QvHTPDk7n1oFMtW2v
# DATA 6ryiPHFBfmNNwrUqT7ZJfvAfL967sLFOjfFi0vYK9//nPF391cbF19aUW3bGkS0BYsPdAPJLO+z2pdz9ZK2AKXihsPap7NVNfuJH
# DATA Pijf0zWJcm3jiKRn03sp1bSl8vAZjXxSdzx+Do358J+m3+eSHkC3dm75j+jmRwiIbqOeYfoV+gDVP1DgOq+/O/wT1bAfUT1Rc+n7
# DATA l1auiuTgvJYsaS3dQ0vW6bazEE+GA1VRl2fCEW2BM+Q7alpU5B4n6mtl21CMD/9ERo0dY+UyUksC0CC0ezv5dV43J8k6Xk93rKZv
# DATA inV5clVS0OuKs+6InpjvxjdeeaJb0Bi5YqoSwFOmg0VdpmqJ67xQQbfxv1tbsz10V/+obo5nB6X/Ksk4/GJOqf1w+AXlCVdjDEt/
# DATA 4br1J2m388cvHp0up36jakwZ9lgyEkHPVNnDP3lyBy6amqCKm6M9r7RpPrk+jh4Eg3T5Ll5qpu7iw8Ly79Qr2EFmLXiJ+Rfo2Sll
# DATA 27feySeNcYUKoVK0vrZ969b9W+/evrtVKZaKHw5uX7txc/v97d9cu39r++a16/ffu319SwFn2Bje9/eCSxUoNAzWUq1wLXmSInP/
# DATA 7ru/vnaTlxU4EWJ5v3Pz7rXbN7ev3//r9+/ev3Pt6u1rd/kWNVMt8K33d4OH6xUY6+nwPxzcvf3enbv3b91+99//zVbpw8GN7dv/
# DATA 4fXtm/evX3tr++rf3L/+zs1f3792c/v169fe2GJVWF5SkdLCdDNrhc0rIfaqK18vpjNKhFYbaDx4w7mnrAr6Vq/VKrWZIvoX6TuT
# DATA zkaq5uEfpYZRDaaw8KM8ny6U5AU69rJ1lx1vq6RCWYQfmMoEY7G8xBqkGoUBkaIMI+Fbqjg/ULwfo8/5/vBLZQyqXx5pr8gcw0/F
# DATA 11qMW0/W0i+lTY1PPp1d1jY3L1vM59L44F7KPsci9fwFal5sbhshuWVLzkn0PqCn7rHsHD+3sMvXG1Dvq2WxdWsVbBgEo5jmOHvB
# DATA aBTSFH5tLXFgiN4j+yv0GmuEPcBhW44AsNKE2d2q+1CvFWCrr7gu2EiB43Yrm2vYnjqbczflPTew3mUMUgkAIzI9s5ae8ah4sx/M
# DATA fPnZ7L0zI9fX3MnSuEQ1h/qcx1Ll/2n6z9yz4hL6WnTFf4HngZoCGSAINK/vPvzHVFedGo65ECQOfFXlXzybDyrFd4IxFrvjOZkR
# DATA S11SNVE1Jh3g7LjssdH4A9s13yBysB4yg8oPKkH4h76rFXuYmWhH1ODJvqABDg9RcBitkGGPkyKZn+9qA8biuK2S82oo+Jbi8o8y
# DATA bqhIzCRLRuBsAShTXEdiAzWnNDNRG8DBFUIf19xI/djMJN5U6i3jBlyf3298sPbG9t3t17fvXMNotHZvo6CftZdP1n8dHLCLLufN
# DATA uAwz7zProKrE9U9zB1oqK1TT77jk0HVzZ/hYDBDYaLiY2NJSoGRZUtf5tZeKeGJbqXjoj2a6bCYePIu0Okj0JSh/7lNSzRRXzA4p
# DATA LpFMK+DLKgi5giMzgd0absvGD7ovjDlD4IzL7D+Q1aFk+VgvC2NNLFj8rpuUPKv5Ii3iUCJrmtfgkap16/7V2+xGIRTNzZmlUM7e
# DATA hS1mYZJ4ma8XslAP5T5/1EUjR6VwhSOsYy8x25aH9MC0kfFa8mPitfx03suwDAlX3Ho223j31dpGoSdTbMz/dHzSg5ZaMZB4y9YI
# DATA K34s6K+DspJD1zkxa+/c2pYAMBF9qxe1/N47t/bq+mIm1pQ4U4fpcZ1jyro3l3WUZjNe1XCIiqujt8rJCHzAxgZnh65eth+ZJzC4
# DATA pTAZkNG9/isdkDj0sRsLQ5pqP+wf5tvtvkuFxI6Exc6gpBXPH6y4k/xcHGM0T/iWfeRP5g4P/IOMApe1HfUVd7F/4umd3UN44p94
# DATA bHnVrAEh1ex1jswbJFQOnHyERgQpK/4J9uui0WFB72aNAzpadk+ron3ijjYdWbpPbjDZ9hhzQWvgKnjTf5aR9yuO+h/4h29UWr9W
# DATA pfoNlwTPX65ihmHSdfPa3fffvf3rjL00L4s1WCNS6VXfY94Gua5u38AuVzEc22JC37dHvIxhr4zimIermTclNsvs+gjOTm3MPCEG
# DATA +sKHeCfrpVdm9vd88mmq9zZewTmm9uz+U75bur7ZfkCV/X/2eB4u09PHZsnV3qSZctmYWRRbUp/xnPeJ9+trf7P1m+3r713TfhK6
# DATA kNlTwzMBQ6q2JwXir8RpdybhYmIwd1sQhbAkGXNj/gOvqf2Fja0fxSvxOU/UrcmV8s2KNwcTr2/WVpiU8KZUnRrp7lIbvNLzlSSm
# DATA SzM4M02lj/+Lmvaxt1Sy1iovvppJAD39ezPx1nvfKWb2Oqk+/ZCsn76ydAdzap+1mnynN6FbM1kYucjGr7mL+3vtI5rpx6Q/Rpp+
# DATA lKRTor6cM6tNmi1Wyu7Hu365VrdT0wl3cO5wS6/lF9QtG8l+WGsZmFfC1kat+Ut7aGTt3cngARoZm9E9v9/q+Jf0ih5TE6wTAhs5
# DATA r7WW9adLjApymnidw0ulS/2+GzyUT2atRs6M3kdCaEhN9tiqyXsUjWf336pVs55gRaTLG4rdyj5bbD9GSrD8y2P0ECvUeIC+YgQb
# DATA JiuJd97eppy7896NO0mvCy/jMLWovcJZDvGgScgbSWQ4mis5QLjSJGvivHrCFf0raaNSoaghmMFalmKR3It2OnBuQXb7pqrPxoU1
# DATA z1u7IDG8wFvzM7HUZbLHugH3pWiSfM/JKDLA2vaanGM7uph4K7c2pMz8YhTtsyk4E3d708KGuE14y7JtdS9cKqFy8PNd3qW64Xnr
# DATA mdLZwEa7aH/xQoleBmAzHtGea9EsLDndSf1o2TA8XCi38eHvMYJ8Qb3W91Z3y/jELc7Bi/PWIXgVeF5V1D+oak1XZzoLVHC9zjE3
# DATA Lf8lG0tloUks4ehfVgsXuVes1HE2soGt06Z7BSVPReN9sq+7ICemC9hlofbzjoPsRb0pOzZXlG2TutFYK6bKsttJaq1tdUg8OIpr
# DATA 2gHGOzz0ImsvFQhvPoBLK9ui3xs8GOBcvRFoVU+sZY4BqXS/upWtYlb1Yle7Lox0CeCSLgEZy7NOE840PdJJ+5rNx4352cMpU6fp
# DATA 8QjPDa2kLE7+TRYmwU8qApIPa+ni1uPDmsa450F5GK2H0mGG3HtDV4FPvnBAH+jiZS24tXsbG/ODtJKbqSEbyXxt7pM8FGhHAWLw
# DATA gX24Q2Ub6lk3pJiNeLOtCvqenNPEW7nb19s1kmNuKkoqDSpaqZIwzyyqlUuetbrEQdgVk8DKiFWezOYGfBwfKN7HmizEMUCGJyHy
# DATA kg8EDyKpl/s5DUFn7V6qd9UPSD1C5WBX0O1ISH9ZGyKdbD5xy1UgP1IPZOruag3q/1YDquqS/456rj+TUUxT5cP/lPRi4qqkzpzn
# DATA ymSd0XQUpulMP859oOkhxXROT7GGqVEwvQSienseKNPHvewu3W/FUQ/kMyuD1JMm3Iu48MpKgwRZ5FFvj5k+8f1R0PPH4V5wfxzZ
# DATA J5pgCKTu5SXV2UNRKZM+b6yVJfb8H5VBnOz3EyP+K6ywcs6yIwOr9zwZn/4Z447MWh5xfn9lLSPqxOpGw53V7HB4dIR56PqSwqbZ
# DATA Os/xP0d3ujjCaTM9nVevqBowCCbjkQ/JB6kJ2iNBdq1RfYHeD/I/WZuB7t/OAIdxhXjU8w+CUeyBuer53TEUx6MBo155W+hlJasi
# DATA x8VFF8W8yKzUzNtgk/RvesTUzxUO/H7PHkqTH+S6HODIL3xu4e/0873ZSpxo4Fz0jF892xAWFvGcraZz/avqbel2aRVEMg20ahb7
# DATA ErmEjgh9Zofg/8/euze3dZ33wv2bn2L7km6ABsCLZFmBAruURNtsJJGHpOKkFIoBCVBEDAIINiCJpXHGl7enPZNMMu103jnTmbYn
# DATA 30Bx7cZNbOcrSF/h/STvei5rrWdd9gZIy257TtJzLGLvtdd9Peu5/h5efQzaUB31Aq0VfbruRlrjuKw8CgfuPNU4R2k9OZ9ZTYi2
# DATA OWzvFZkc3F6gM6o/s/w6l7N9ihztF3g6gas1Dula54fcBhyTv2ZHkS9BzfCpMfKwgeLTHHpLljYS3z9DnRupLZEWf+4oIlxPGLtY
# DATA MbsowwvpkxfIkcyVxUUUcXlSuaKbc8mRHPh+i13h2MnklYTxZwlBiSGBeoMqOrua6WUULiXPPyK4o2G/Y/CVcDst+XfqPJ/rqJAC
# DATA TD2qHf4fUCg//1h3oBrIlhQnr/kJ3Sp7TNvzyzOKhfTkRdjNg9TMOdjTLOXkUVFrTingNYE3tI25XhEWH8DwI+gfceXK4rPhXDv5
# DATA c6FVDYKWap7I64Ft2jjN55If4pzgsWSbrJLQUa6FnFZ9gThCvY0Nu43+Jgg44bB5+crSOY4auVNmvJQ1ZrQ5W27L/iB0+Sg3I1/G
# DATA xV5dAiUVaone+PN1ESE4HOQCkq+7lqbnqN3ATEnqbkDE7W5Jx2SIkMu+RQVgE5JRH+u1A9U/iEPS2nSON9gxM3OVpAWwB1q9M8NJ
# DATA gWI5Oql/UCP+DZo+yGj0VLupJiH79GmojdKpO93Naw73AkIAxmeSlVZvFwi1z5UE5Omw30a3jvs6vnlsGZwpfbTDLkeVKTt2+EIM
# DATA 1h2msEYd2oOfdAkSmwCvp6dSJyRnEkmr6JprjNcF55HOxXvMPj8ARdhWM3eiWE1bj+zkuHfaRh/qfAZLdI+LexKiroQticX79xKz
# DATA DiiE7UEyZeWMvm6R6LpeApqgyz5Tlh1/ud1wKDqM9EwOLj9ACradG6jE/1jZ6yWHR47rnh+IYCFxQkyo/hX0v3MbIt20bV9rwe9t
# DATA 395s7e1v7G+aeJitzT08sUxEEcgHbljujB0XKtnziOuc5aEMS27S3tRqiQPKp82huB8c+7SxUfnmSxEWxuEyp70MYKXdIDBS9WVx
# DATA AyN/bwQSj25wrBJMpGeP4V5p+BYTfCftIOHUkVo/OvgGzsCfJqvDN954w0rEZpZlKPdul/AeGOO3+6g3nGbJ1t2NdzYryTSjFAbg
# DATA D/i4KxI7Dyas+1OHZQS4laJGwqRLfjYdTtrJT9WWgIsdF/IxRnCPu2pqp12ME+8hvhDk2eqwFIthGdORDQzn2EMiARXv5KE7YdM9
# DATA o1o+c0tK7aA7mShJLy4B6osUv1KLyT3LWyAsVwlkNuND228PWgQBCXrlFnPzJRpahWYZovOPTnqYsF24cjI6CBOETgO2tFYc8A+h
# DATA omxRlfhCqhVIerBZIbQHlYlTVccQdoEgNY97gKiGa/q4Pe5YfQLYfvNVwqRWx2ATHk5RuYDx+Ht0wZAKn9+TdZQixZ5qI2+CXNrn
# DATA Svj8hDxjPC0R+olY9fgvc3wKPYsvT7bGrHLA3mKYbooOU1pmIMLZBwBg9cGDVyMgbtJ73nEuIdUi9OuLZ78lKzYooRRHjYakTyJT
# DATA wQILCN4YQRIb2iM4FsMBZmY3S8UPc0fP793xx7zUXyu9VX9Qoz/L52sVCvajrxcZtHb/JGekj9B8ER8qmZnC8em91bIDdbdbMNbg
# DATA C/Y3dK+IcFL87y45O3415UUNimTmkTPlOv1GuG9GGUGnNTLgs8dMomiu4nZL4NGg5PhRCeG7HLf0mrqSIA7qYLWZLCdXywf1qx6b
# DATA BhUHswJngt4Uju/X7BUBYvZT3MK83BxvZEYGeqPPSJvEAwffjyIL5A3S2wOl+DdDMdSW+ms6TI4X8mes2P+C4s9J46t3lkVtztzj
# DATA I99wYXUFtrwP3G0Y+Ubnw/GL8vMN+UUlaMFak/x9KgoJnxXMEiB7yJTMqZNRhNQ717VzcOa3ws6SBSfABgW7NncAyrP+EMZV0+mG
# DATA 1z4a/tTUOIWM5Op/6h9cf+bspFxgkLKvwVL4Vfk4lrSgYjEWb4u/NW5HMA36mZkBUSgckvBDDnZprKUL+KU43g0Uq/0/UIf4EcVm
# DATA evQpMOB8buIJfcpFWRCgv5hKwzl+8GSP2CsAFXYPj/OSbN/MiZHTmuKJqKBh0NC722pSewM9W/5pke9Mpeq56WXOLAfz+c9qfmgK
# DATA jPfr7zGw8DdBJMfXSJI+wf9+/OxT5nEuOpejEXpVHFBaEvZNbzRsz9FxL7B5845wItlh/1GFdvvxb7OxxY7L3W38TTA3/1sN6TcY
# DATA XPn0+S+f/08m3np+dEhDVOv2B4prURUw1wCu0x/jjv1E1fR5yEb9zsS8MCpLIydqjF3sd3Y4YFDAwDKjcGVd65+pKlQ7X139/jU9
# DATA K0cntG+wHfKvI7vbA8RAe4BeKwh82gxn5e+dEedsiqg2+wu8+dAZER+IMeTp7dnFokA5b3TfuUIUe0c6cXVR141mFJaAlJGouV+X
# DATA lI9d0uboLP9JROn6LLael694n30Y6DED0qVVmUa3pTH8eez03Bk+dqwSSEdZdxOcfHcQ97FcNtZ/5M+AFQOn6RogFb3fPctKB8tc
# DATA DzfRlJ/Uuk8moApezL6sffmk+t2zXhhBGmqvB+5mCxvXF7g4QtVxPNDO9FTrvc/JNIJuqGT9A48wUubXI75uQeeNh7Im+ZCUHSfC
# DATA sT+nNUUHUjs3OqkShd34QjbsUPqrHLtbjKuR619rzwWVpk81niihRbuzqv2ViU/H4qS0LPDApxFbt/uFYJovYvnBBTWwuLk2XsRq
# DATA iS5ygQuM6SyukrT6SgcX6xlDg3VW0mpzpKdWfOe7p48aLX+7J8GeAMVDQVCL9QHPmy/H4+zbOheKfrArJqDE1Trd7gj+YEWV8BS0
# DATA DBXc7GlFU3mOFgft8EuN4GGeK06Of8CvtJP8V2hWg8sdkSkSiJVSc/av4IyD4aI2RPz5J/pqlxgJghmMOMHEuTZ9+Bt6Vg7sAW/i
# DATA 2C1oRfxocfEgKMYNQJGsypfGLJF32zvsdt5e6R4fd1FBqDpf0prDeeRqkRGZiovGlK/vgR//rseDfJ7xYc1dfStbPM0bLsJLw9qa
# DATA 7tEA6bkTZx2GIFGhIAbJqRfGWopE77sEnYt7iADOdFIR6l1vaK02NV4LMGp2KZQ2lRu4CkkD03iwaaOBIkou8b6A2IEqki8pIgU2
# DATA m4124kg1DrmJgXoIwN/w3GmC5e6vqC/VuKv2fw8YUNi83opyngsdUcqL8We4GAerzdrYoBXhk+qawS+q6zJyOURbiIakfk0ejgny
# DATA W//9MwYu7/TwsVpTgO0H9G7FozxBR7l2p4NPFEPWPe69n0atk8/+JffkwmH/W7X7gTH9G4zVUuvzO4oC1RqqhE7QF3BQ8IhgABqU
# DATA QzCtD9GD8pdSZvpELAyvwwFPIERy4V9+gdpoOCqlh9NeH1JeoBFB2Hz2T3oZkxDACQETwhDh6sDFCWH8jYsHvB6Phn0yccONqXkF
# DATA Ud8YMpd2B7A/CEKYbVCQAWCgegS4mX0I3lEVDjBFgYkfA2BhdSHWwhFKMH4Y5/nycizg0ee+bKoIuEOFuFRn4c2AEqag309ffVXH
# DATA JpstKm+ZGNWV94fRdkCnhFlKdjGsGCX5ZqzPnLRDlSWYK1kPO5nSZ27cLCrG6aYQ6nBiC3TvYt8tuQH1gk8OOx2GymvKlXv1RglD
# DATA /kQVrGV4RziF/5PdEGbtcufcmBzHSB11ya17e/sb925ttvZ/srMJywrUTJ0QJGSEqDskWPyjk25n2u+O05mvNaT/lQ6Hw/6crcdU
# DATA mDhhZz41fW40krwqDA0q53RAzLyaD9aNQkvqlziEdAqpLb3xy85ly/MEeoQXeO0aJsfG1j4lA95vEafuc8WWfsHhwY73VPHlSyi2
# DATA eCxeS9IboW0k1Lo6waNkJjPOtJ/mm1GN/7qxBrsuWiE9qIscNchTRqiLt4f75sp2NrHVnwn+Er5wtGXwYGFV2XzG8+sY4/l5HJMG
# DATA zcy/4xj9Ocx1AemeR/7nEHISxY76bZLFnBYLSYOaUfOdJOiY0ZVfxM7QSwiEE2dbiufoU0di0WCGIooitM1b0+6/wtpEgCtu6A3+
# DATA JUvFaBz8SnM9YPkjYL4L7nhv15+701hPkN7ELv+ZG0jhCsco5UosUxM/BYSuoR04QvNeg7ThlUTqRhsHKMyT6q/cNC+tCrEhC4gc
# DATA URG+W/ggI7wdQKIHhkf55T4Uu69KMW+QW3CHCD0hnVh9Z05d/pHP+WLHcPee3Gl7P9f8jlG/12dV8/fVWfWq+XFFvbj+/fZh03mi
# DATA /14jPznTWJzMEKpHIcxnGBjxNLnY/fA5kv+n5BjxN4CHol0BLHz6L4IIiYOcBQBG2A5Lhk6cG0+JerIG0TtG/V/3/UaRlyDPTdY4
# DATA 8R50c7KYgE5wgjJ/q49Js4aKKavKolxO4OBV13oWHe2rntCooFt8aqEU/1lx7+o963kVPQoz7Ys1V4uPmnANpWsgUfBnENSRawkR
# DATA QLwoaMZ88aXbJqE/Xp/t0x/XZn/BDvoPdGwzdguEXA8A3KTNCfXZkXBWHZblB0z7UV/xYK+cp/Atxb8GzduY1gBW2Xbcg0Ryr3QH
# DATA 7OhruFGMPgMdwWKGnLq6D5Ts/Bu8HvT1geeK9a8Wk7palQE+IZRQ7grb7oOvjMyClEUU0u7EBwGEmcX5eMQJQWIOg+BIaLck/PK8
# DATA nRCYBCM4zbvMh1xb0BMvN1LmD+C8A1a23Cs3rsUOTY7QyXnhQCVRkobSzPsk8JV2jQ1mRo4CgEpWYnutuMrs3JcRANZFJuhrCqBB
# DATA py5mln4nNdsFZmvppH6wTB2zVFfxDMt2sEx10a4Uhl8Kv/Ug+sjkSc03JNj4iRADCE4EVzEnAMfFBtL+DJ5lhDwd2EWSzfxk+4dJ
# DATA 1Xfwv3LegE/pHi5YAPYX+xSKWyLhBCEiRL0J6D7tTfKOJJs/Wi7IUPEpvuyRWCTWAuvwoiy0wTkSuBZsoPrCcbPxrUOW6iBaMwzy
# DATA oE4JSz8+sJZ++rk4aZpn3v/UUC+CmsvdHQ6qjnVLx4lyHdLn29Bz/cdlwp3QddyWsJvLI1Em2lzHvNJmc/gfZPt4l0pMb3QLp8jT
# DATA oda9nrYHigPvJKD2EBne2GmfGgHXRUg7Dv9qN3LpGh7j3Bf0GLwQMrneNfxLMRCQZv0iTmyC0aZHF8Ew/w5PLmvcNWAZM92uLdZe
# DATA UHp35thaBREl1/NP0cuWMNTI07iAZBbPGp0qI59ABaEznmBMYtx7kC1butz5bmbelew42zYdxlfXcgHvdABKRgd7xoUAIc7X4M3f
# DATA J7FOxGzMtGyOjgg+a35LBo4IYL6iO3iWZjHKpx0ANCZ8F6rvtiCQq0XkSQdylTjYBYjVhULvXaQx+seBGRtY+HBowxwI3Z6Ln8KH
# DATA wY/aI56bekMB+FyNjTHNg0gKjzyVmcfB6lKW725a8CTNqy8etBlE05kQOpyVSMymD0DlIwTZoc9DCRKgA99mh4Mg0wVIZ4BIpCQq
# DATA lzNx6Wgw6MhwC4+nXlbpetzMY67CjbhY6Oj/rWGj+XuGwkZZud3G/dDvgqV4+HgAeRYH7VF2MpyExm+J+Zw+Gvanp/q6se5Uk7MR
# DATA qJjSw96gg+Yy6nRdphcEQz+tUz1xh8ZM26VC14ne2k+BI7yULi5xPW3rLvkxDrhYDvdk3duiUiNHf8xcshENg/fERD9InYa3CKGx
# DATA J7ksqLRBE/2mmnK/IzFcQfpVFleWxiSlX55QqIFmJJtudEH+TWji5CCks99FPaa5TvkJp6Ve4M6MXWErL/wCg5NmvzUnFg6yrFJ3
# DATA 0ZZUEsCJg0p0MRCWXOSvtnZui+/tqG852ynJufxb8B1PPTH7Qj7y1Lkg4iIqDZuorn6/5ClhAll0LvgZKFECT8PnvwR/I53yyyKB
# DATA 0BsRK2evZd5seT7vnvhfvxByhBR4EILz29SmY6w8ONMT9JL2ZyLocSLq00zdM4dnSbc97vcwNwZn/c0q+He33RHVDTEmf6TYzvaE
# DATA 4+x7Y8xTrL46hQgdRTI7w8cuKkgtdIZ3tfsr/5G6/ZU5mn3T5/+Uiv0F9pwZAKv27SJ4mv2VmF7fBY+QASSs6HdPQ027cbp11SPg
# DATA KK4TekyZVg8c7K0iTh4kthwNB0pg7vs4fLGt4eh19Yduf2x9+T2i5Q/rT4gAI9YSuGd4gW+kWhCIdNp7wBBl8Bpgt0mbvlC4vn7t
# DATA IGr/ip5dbFeY8V06HocJekQccRmGCHyv0DAXuOHrC9E1XQRP4Q4J471kUfnYFrYVxGr9Lt37+XqHS1ATwPwwT1cLQ0NxlUXR2Dva
# DATA Ol+LyKX8IJcCd33XT+tzdwA+74cHqXQp4IUcKe9R/pfc5mKxvyEQwbxZSf0MOrFgN6NiWsbDoYPdLgXEWADC6JnmtDa0gOrc8LJ0
# DATA qqf/rh2RviY2yUMkwEcWcsRBT/RNL4NO90nFMGvdgZJGx20D9TM3/igGK/pmcn0ZwESX89IUB/F3fkLi39BY1QM3DwjqMsBfKhJu
# DATA pEEI624v1RvG9asnIfYgQ33DJEBJxK+rJ6vDa6urs9yBe+EPqk9aKkQ4JG9KJDpSJSGxtBFYMssRg0wUnLCicX7zMfuk6wAuub54
# DATA oSYpfeptOl/GP2YZniucFcmkklls6avDRvbS1SFSKiAQleJIGw7mYA5ZqktQStSEPaladpsLkTo6NfwwdpxlXKH9rMc0ohBaYRyR
# DATA +K9ZmLkvRy1t2e1NE/qUcR63BGhNAjjJZ1pwJFin9hgMCZh8gmCxsFJRF8x+LdlEJGa4z9VnGaJnoUqt32FsoBFEPmAjfOmjaWxS
# DATA i+NVhSzRPDOhPAtxVpGhiF6IUOQLRD47qaHTykGJEDNtcUOnYXdemKInbj4VvpqMo7yJ/6jd5uSfchCE5QmLV+ueO0EI2j3GXUZv
# DATA Ny8aS3AW0t8blQ7kD+4Oi/O+9jIUUGW+V3OQhKaJwcE0QwqbWcKCmdCFuXlv74RBEszyIb6Qda1XTdWIs6/p7al5Q1+fPuezzIHy
# DATA MDSJGmU2h8sEV/w/hqmWvqIUb445j31ueP7RtOlgE3n+JJwybw5L+0ujGBFJk/kH3wDD8fuE/uPq8/wwhfy5rHEVoISzoXBRpR2X
# DATA dDR2pgPcA8jsGDeKivRhlKue4tO+yEVLzuWYqlV7zeVAScCDpslCwg9I2i4tOC90GbTozvRjBCt+w3C0SnoyVpKRmEI/ZRNSX0er
# DATA SI8Fog95AJR9XVxx1idnihHjxEHt+DwRWrr5UxzRdlCAQhzbZLGkODzenLgDfRTNawkzElf7aF1NOFg/G6Wt60bAn0uMGBBPPsTz
# DATA /HPhgcBIep7CEtWHTo+phRZm7ItkXY42/DlpgyFJyM911mVZjyO8n2PM1Wmb/aslGySodsAH8s4kQw/R0LomK56/tWfvYfAQxy5Z
# DATA T0wsuk2xRPYd+vsA8uc2vYodEbmujgzV0USufzJuC5frg+asII1Q3b3jQfju7QzH5L8wUn/YSDa0I+5s7yLWzrr6X1p2nGWxAr4J
# DATA VRcGmTpnpwZIM34lcgSGeZk1QD5xvKQoVMOkssuJ9JDs5je6Pxnd6kK3oPCh4TATV9PhpROPwVZdEJIqF4WKiVHqCR3EDpsQy1jM
# DATA YAxij8ViiMHDJMKlo8Vmsjx/4uou8SvHoyUx1ow1SLxDZvkRroVxraUYOaU4yWC7weOAXS4VxKeWLxvB6NHiSDR42LvYF0Xh4f7C
# DATA XjrkPxpQ+i0F/JvQfRPMj39UFaF9cub9rJJ35FhG+gucgBAzwEIFEHrA7JvjN3wdzyUaJi8ilenvQFFnLHl/9+wfKgkHq0Y1k06c
# DATA 3LcQgw17FPMbgv7OwI0kmNk3HshsRS51HVr85tj5KmHtCwY+G2XweYpH6XH7UbfqlLePxZdCVlXfG3qHIdMuFSyOjXbLLuXsCM2t
# DATA UwyzbbF+iTM3FwDiAqe8IFVg8Ya2EQUFLKmjbxgPJ4rfodyQkABZV0HpiEUi+QPJyKEcwS/4g1l+3QeC50BSCDI38CT8aT5fUo6p
# DATA aUL8n8iZiIIJzPX0PIjligYL5WuIJ/CaGFNOyWa0QRnhFqkdtFZmIVAiI2u4k5I73unmBQaoLWmwcHpA5CDB61yx/hKmP/oS1ivO
# DATA DI+qOKafQkMqf3nBuT9fXlaPKsnysqlhFqagqjjH0Yk4VF+XVF9HfYR6P1E3BXEW8FcL9pvLkWaWGdVlwUo7hJNV0k+0HTLLHlOC
# DATA JopWzmoU63nSfVK6sl62Sa+RvYrFN3tfqC2+s723/87u5l5rZ2Nv773t3duo4KeGKt7U2cL39zZ3QeEvL0Xz8vZN95VfixeMfSyu
# DATA 0/rKiv5RP9fdmP2ZJdKdw/rrV6+sr+TX/vbu9r391ua9263b23c3tsDdOT2ZTEaZqhu2ml2RdGfj3uYdW8y88avcu3+ztXP/5p2t
# DATA W7aww0hNx/2s5KyqXXk4WgfX6yBMvfve1m3Vs42bdzZV7zbf3rh/B5ZGcRnTbjiQu5v7u1u37Fy3O6c9dPfQL2DFoisL+br92t7b
# DATA vPnu9vYPeUO03t3cuI3VRvcFK+TVQYV4Yt7MhlN2jyhtuJBJHrUnk+4YpJ9x+pcw8eNuDeF8unDyAXp8nDZqy6+mLt+mcfb58wr2
# DATA AiyYtbseGeXuwSfTQ1uegdBb9SQgMLqy4377YdbAKgsSgWD9rzUQkELVEJKr1/CVJA7wic4LCR7zQAtogivJYHp62NU+cvRDC8X8
# DATA yo2GQCBZDZfhY8vC75fTB+MHA8DJePlCnncI8GD0GjfA0YZhdVn3aW9YRuOVEFYAbAV/kClRW34dV6/2GTgyqMGBtaEGf4PxKute
# DATA u1o7vHaVjWl6WnT8HOVlcRyiIyjaXDfetO+X3XAjfnfwPjMM7CvVvtUdT3a6p3Byfvp4sjM9VHT7hwztpXoiXsNP9QZ++cgjqOAX
# DATA GRhLjm2hZF9Ukv2zUZClkVZFTqxMnopgLxqr/iklU+R80DoS9ymE3gDExkdol/8Y0/l9wepZDHn7Ip4ggnfm8cuGsWmc036bPRjY
# DATA DjXSc0bAUHv6Zd7Dj9u9CYV+IAEtcfoS8GkbTieN9VUboiyAHtBpWJGDuxjGgREQsHqddl9xkmk0QiO8+Vh/BHXdxifaWd49OaIY
# DATA NEm6Jna7UevaO4YruluAfIw+yqpktgJGtaMT1VJtpNbfKLlsLdEcY6vJD5wyYQbQtStrq2+sRw/ob9CpALwInoLs5yKGRlf6afLu
# DATA /v7OXtXGI6XGyYhzh8neWCMw67K67WMmmTqbSRX+d3Pzna17ya3N3f2tt7dubexv4tPa8lv4r7pLg3epSFKkqttziBc0Ewz41+Fw
# DATA gsGwyCq05Vqf+2Sk5QMv3VKW9Ws7m3dbMOzWZKiu1V38uwSdUFdvuVzTWZfsROHFAV9StqQWhwu0+GXpqI1WNJAQxHSWnRpqHMeE
# DATA l0nyAdX3o83drbd/0vrx66vfV9ezmrKNO61b7yqOwflS3eO90+mpyGkC3+7f2fsRPYA/H6211tmZu91Rew42MRy82ulQTTG4p5Xg
# DATA DuWzSCanEzClBIV+YKqo5yeyhfxASQbatYmeFNXbAZjYlYRQStfW36itqv9bS81NZgmBGk9pHfz5n5RqaxXTXNXvCmQcaWeKlj6O
# DATA 5FeCDugJejxuj1rUm5IqTWq57ril6UTDMFdQnyJc03Eeo6+2pL9jqDgQq1G3O8bNcqik9LFay+H4lC8is2uAgOntV88VqyxaGAWr
# DATA fwgubE7Y4NecaPxvNM6jRABQC16lA484YB+l5RyphbqedYGc9kvH6Tub+4qEwTlaWautAUPwrpqaenKuZ2gGz26ZpVSSdR/cBYBz
# DATA UP8/1WnKyuW82VtfXQUy1kPdDzWvyOej0utr61pPVz5YgzysydXV1fwZEuR+TnbjSrIFDkOxTMcgEthNDNsr63e7o1KNpR9aBpes
# DATA RJO9A1jP7xMBI/AVZRd4/osbWqlGHnC/0AlrcE0rUbKMGaj+jdA5wVaKzF+VVI3amo+/GFC8ZGWQrAe+Berakib7uYIg8jDqbZri
# DATA 3avr0JnwSHg/TgnJDeKqklU8vatKqMJrU39RngHpufFgIIoe1OvN3HIOu3ucpimdzOT8fElUMR30ntRXHrXHK+rcrRgl9sp4OljB
# DATA iajB4YYqE1S5tkDWHh4N+zeWzmlwMy2kq1OPU2E39A2ykmT9lrziI61N+t6tHv2yBYx9ztejce+Reu1+q/uaJUima+v87xUqAqzS
# DATA ejIc3FgSQ0DpKkuGx8c32AairsmVaTZeUURp3KVJWTmZnPbpfXs6GaLXnP2kC8ehhRH7V1evJivqPzXxQaejhLd2Ry3Fj6u36Gau
# DATA Aida3SaBVO3JbNA7Vlx1/3H7LAu+2gWM1nF3XN0Zquk/A866dzRhT77q45PuoHo0HmYZP3Gq6Q9JEZL85X9PVp7ABIC3zIreFHj1
# DATA 9XsAqK+uiNbhsHNG3NHqDfP+4Xh01CJ2hS6V5Mrqaua9B7JX9B6oA/6lRP2iLYhdxC1IFXDSdTMMNYoHD2qlt1563O33q5hGdKWs
# DATA RqNutsEZuCLfCD6BwcKtSl4JyavTcQ//s5I01EJhefX/1HlhcnA87mYnpZg7T8VYf7U909x6qbl8G6ka/mpaoePTMPYNZNaJZmBp
# DATA X9OUYw31HiM9Ui2sYQuo1Rp0Jy1UQFDMGrdkn8KlyQ+RaKCnpiIO/WOIk+mn8h1Vf/XqFf20NzgcTtXS0ovr8MZKFm6dWvFXcuqW
# DATA AkZcFgYwhE/ZvM+M9ofkh/7sy8RlQFEsTstL81Tgbr8arphjkgeIFQmTLyPAHF5BFIT2CxPvEOGMbeQayI5faiSGF9Jd2zWjPzzA
# DATA GyAWxMb6Cn9JI4sZRgxBtBs1QeFuV/KwKJGD+nmysbNVcdYHwH7YneRp8uNx+8yK0l9xkJsGp4TbXPiE9I79vUzBLGbCirJVYiwS
# DATA hATeU/Lyxu27Slxykb0/Y/7hEwAWApn+Yxny9BmttA00iMFmGRexIAY0ABjJ8zrL1yv1hw8fkj/aedpR1xq6haSgoalyPpJ0ONIe
# DATA IOepItRVoNFQ6MoqakfgERZVj15PmQBCaCxKMGBgw2yv8Ho6UEQwq2aTIeBewsfcvHrJfwUKSjaBQ+OO4dt4GbNdtiMdamZBNdN+
# DATA 77Q3oXoGQ+7veZoNj6Fna6tXr7/+xjXVIXXtduyD2Wy2mJ9UezTSKNA0dKbSGv1To5+TK6tdUp1zptysxDhkWK6scXBs5ay61tLU
# DATA kdLHP+Po9sYB26CrJDPRvQc3nTVNk29rVl9Rq7yiRrHCD3Jq7nTBwJi1hoOGNJ12DnE2FRvbQdsRLDabUoCR6E9OztKZY1Ulk/j8
# DATA j2bRbtBrDDJX/ZioHQY+SOmtu7ere+9u3kGg4SOAEa4eZ3vIeqmrHy7lPlyaMHVrK1QHep4jWr2aE+jB2ipaLZidwE2dkUFYcT7o
# DATA 63SNLpbxpDVSov6wQ2chk+bhkKYERltQQY7UOwLnPEgNAUmbMazayNYy9pH62vXa1fTSm4xEyJNTZL4aqRLgTg9TJ6uwmuP9v4Bh
# DATA 3t+/Beto95fuoWWphA9EQXOLLODoYauXAe93llTvJ6++eu6YmWZJteM8vH1zFizmlXlrub46k2Ebak/mzDWdGD449e9X2/1RbwDk
# DATA cdGzljcZ0I66b8T3KBpAN6vVTB0VBM3GX2TdB7Qu0krTU0V/T7unap2rI2TR6V1XHSM8VFgGuF7qF/z2usb/IOPrF1c7HIn8G2+8
# DATA Qa+AIsFfq7kDyl9a6xRTVXw/1pct0B9I9PANV1b4zgmypUqpKXXIEhIygTAbEiz81wlSClnnen5GFGL58q2C+V+iJK/12/6LwEMj
# DATA 8mlDswHgTRK8BmeY66uVRHHZs1xfJGbAisGPpQkjxncRKLhWnURShn5BbG4adWHJDqRvTuDq1oyf33CNwt1LnEaD8LTUtwea98C9
# DATA l+t0V4953EWurQLqLL/XlBq4uWOKfnHex85djE0IVhg4hrXosY1f6pe7nItPP8odcO5DuzbzacddiF96ma9sOx7o+woSgEG7z3f3
# DATA y+Xa5ATy4DbeZN8tiBWclMa14ftvrdbXyuXaEYZDlcpeCfUqj345VOb1eVRmbT3CDKy7zADfEEB74IhD1JMH3GDQrS2BtNTaMGRu
# DATA ZCQI+BQJhjJ+Pees0NucU0Fv6+v2NnMv/Xe2b2/evP8OjOl02p/0QH0zORo1VoEJ4E2XXl+tXweFAEjudZLe9Z8r086oiAuIM63B
# DATA 8bgFvaSwBjCu11fUHlnBrq+YV/Xx0ORiqsJ81lfgv/YZqVjrKy56p9e4jj47FxVhmJpXjR+6ZvzFzykQ37rqJzLcTf8Jy8wAVHXd
# DATA 9EyowCfjNoraZvUiC07K3APLLLJPuTjAETAKpxCexoVFGMXKgjciq3Dgwro8y8msb8Nhe41WxwriPMZKweZQfIPeFlGtHuYm9L5R
# DATA smbmfDR8uJJNR7A66P4Z63JItMFqvALzoBmvWDeY4uV8fTQcd41fcexzWEe3VDPO1aAiCdYwto+abjxPRPOE1wDZFMT7cii06H3b
# DATA 1L6mwcjQbJ6/JJN+Bmc1724XJpI8ooVv62u19euWbsU259LFqAwZIOB8SzJDGnh4WuussD0YCyHBKaZsl5yai9Y6/wRcsMLHjx/r
# DATA CmOmCOijRz4FyZILeFn6OHsREVRWTTY/hioIogq3RwQSB7g0L8wKE9h7VfthVBgVE4mhoklkLom9W+ryuPoVo4rBFDTWwRxlFRHT
# DATA lD3jn5zRXDw5C7tLsVn1ROtzU4RWFD1FHA8Dqbugioy9bCRfen8M3LUfflLoNXkhwUsGlJ+HmWbqCZkn3Dc09oB9LjpEOVlXaB9C
# DATA xpUa/OdqqVyelcMe+lg0mrIWyjkxpClnvNLdquFq+Ukjrx2jGqQTdnT2ZSqyRTp7r5SjyS/HnKBlkB5sCkU/nGARwn+oEK54BSxn
# DATA w8e+KYntNcN+B6j7Yy9ogCEaK24qMqiuLP1Rgb1WNTghWqhaAI49A9+SEgWtwqn48/f2W47DcopAybe36C/00pV+tvC3dp+FbHi2
# DATA yfMg6xlhoupfgS9yJeZMDA9tUIP65cQguJEyYWyRGjZFSbzUgPkj18juWX6S7/9lkit88ez3HEWEGYswmBbyFUWChp7/ioAKoGaK
# DATA bFRbg7B+yN/2SB2CIWTyLB2UTskREMzPEALBP/cIPdU+uK2Ext4AT4N4uvteyoHZCKvLMYJ3sTnOblHWO6ZFvcCN0zI9oj/s1uHf
# DATA YteAn5GS6SEKTUPAwglGq8swq/Fe4/4Agvat+3v7rd3tbVwRVKGbm1f1VsDxrlDcraochpSitssic+hXlYS2vgD4wv6wcdOOjC1U
# DATA 9BbiPM047fLaZ6C5GD7qlvgDqv4Vm3J1cjLudi2MYRXwYBFLFy9gbvG0fZYcdsE1oNupJZsIp6LjmLhCLAkwaaP2Ya/fm5yRkFjR
# DATA LspobyRGTZEK1IMBnUVQh8mQKUUv0+iHFiqB1uibRoVG8RP0VOvGOFWtT2gKg8VhT8LQMcUnXI126svBuTQlxWrqCiDaBqyNuPfs
# DATA 0ytNjXcM91UkrsoP05NNHaw39f6JYzQvWB+BHGsbJFW95rGB4y4k/EVkVipuT0BNv2tNhnSgdIS7xF2AS93/sJe1Fvo2zEBjgge4
# DATA V7C2YGzWDzDWKcOIvHV8eSl8bLc2cC3lupzHa01oJr4CB3qhmuFahKcYf5l9K3YREfqADsTIO6WPI2M05qaLEPZIAgMlrtPxvct6
# DATA POAMbqrNCjhL8PtWe7TR6fBft8fDERYa9x4pthpMtE3nJvbufRtBiI4cYV3eYVJ0Rl40Ooywnpyjg257VFa8kBLqcfPB1I3G3ePe
# DATA E1XzhrrwOey7jRgdJS+IH5wlA0JjolXVXePGE8IiQG/owuF+wT/2ssFf4qqJxHzqETOd1BU1TPXJB4qzsAqT2eKUQDaBU5nfRvXC
# DATA bZgUB3PnTu1QQcnzC0adP0L+xFZgs+eCX2X8lIEkifWmOWJyHUVpUPayxJxGVDkQNSZUPtGCodIGMfDE78qSSUcI2StsGo0YkoWf
# DATA RWNxhxCN3a3fu9Ddthq/niLgbhcXKBqrMBfG2/dPYq1k6YJQGuXF8aMkGkY+Tujc8VLKFwGRYVBgPtNJQb9+/tfIM39lMr3hw48w
# DATA z9ivHNKK3p6NRKoZSmn8zoHtLQXJ2kn3iZMK5bwQ12WOdgQ6ws/hz7JMDqCRXY5NzoeKIdI5SR+CmD/EKyNWju46l2fyll3y9DYB
# DATA BoaVw5uIkCDyUQjJLqc05qAG7dZK6vqh6V6GMA1qmSCIQReogLjT4HsHW6kjX0HXuNMYxJlo8aWC7Fu+APaP7qkJdo3YbU7iaszj
# DATA FPMrU68+dsU0TmFRDPJgOD3yRsbVDuAfg1zW3zS7Bv1wsmvQH0Jl4iaqsBWbivQGtXWIqmdu1k1Vl6LBR31wDr6nE1rst8dbg+Mh
# DATA wLAi+iP/1pRXEewWKj+6iuvqTtpgHyqBx2lFp0ouy5TLE4TWVh1pT1Q3uITqXcuccVMLgYqqWVmFvQlV1sAdx1F36YcAqg44r8vr
# DATA uPGxGch/lizr57ELFMbIIh33JNGNY9RFt5OhNJi1j7sJessJJT1/UcvtOSYYVh1ZshMFFtfWSJ2bvAnCAYXzqQv6mVjRQqNIn63Y
# DATA lPQafTiYQk6hb6dhXXle45li+CEbSE7bHPKJhRhHjoBIJ9DOCHUlKNLb5TrtPRwzpWOuAVXFRxOZf4tbAntMt31aMUcBVqeFy9lY
# DATA NxvkCico5hdrq+p/Ni/gTZiYhAIASNXQHz5EXHfcLJx0BFAwEel0oGR32Djouw5Al4+g06obXZMX0E12JKmQPiRHeBk0ktUlE/Wl
# DATA z+BQnfIS/DU8/GlDD48MPeMPKEFRT53Rhn+IMQiMp8WT1rvoBwMih/+aaBz05bVGsuYFGY1Rj0QCMFZBYKkk4oUYKVDLm3Ki4biG
# DATA XyumrH2o2LbppEucWVqrpYQVO55kedfF/QEe1EF4qhFM1mBzYDfScvROo170MuIJtWu6ecxIhmbC1CPe3OWCXplNPIgRHKgn7A3X
# DATA T7Gxyapokumd3cVKQME9k9cDQeYCqmYOUoI+zG43OvbaBmJG7MRPh70B5gFYJl1BbBrFh76ygnf6An3VM0RQCIoCqK3WkTxOzpTx
# DATA 4kURg8UUxuPv9JqZMFrLiupofZcScS8jYYhyEk7fhz7hCV0dvrG6CsEigKSTcTgIAnq3hu9TSOViQizRCXUmxaDylk/nKvsG/YDr
# DATA 9mQ66fVrnV72fmuaKbFNr2btGNSlP3B26GvJtat516+d6S11Oo6Pe0cQ8wQ4vu8jkVVs1imSJf9AS7ofVcXpW5mvAzyv1KtwNPQN
# DATA RwJeYEPqCHL15ak6/+CL6Vb+CkAo96cZFoYQYThAjJKt9vCUTFv67AukbH2BkNkqFnYMXa44K4t3QfrkMEXiPpxORtNJvXAzHp2o
# DATA DVDC9RdnwqDDr62tkeYQwefDzUh6apJd8raeDbI2pePn7bAP4Y1COdrulCBI2nxWSa69/vqVa/lRt0BvsJZ5IceRlXysZmwyng5g
# DATA NTo5kcQ0ozUGwoeG4uXstFQpN1VOWa7vWO2Pkwhk+DCrHWdng6OSLqcmcTAsuVZFvMGMNXF0FuN6hLpEbxuH9qq/yT2BFAXoFjZK
# DATA hZoF3R0QcpsOCsiHNXRVZDcG9h8kY7V2JtzB/QiVg6WoA0Hv8u3WziY+747H/nPmfnqnGJYDFpg2aFFr+/CktAaeuLr4+71+XxSv
# DATA ddpdiq0BsiWeo+irAUggKlQVMfpwJ7I/CPMv4Cd1L2h4lUCE9GHU4VzCFpyOPSqju8QvlzwwNjPUkszJI9uuYYi6eN3ptR8Ohuqo
# DATA H2FiYVtYNUWHC3NC+4kaKtSVTLGPlAA7jbYIlfgtGj8WXQ6gUEoC+MQ62hGtBF+7W8Npv8Ow0YrFQlYZiAXyeHIMCBnIdNp5I6VA
# DATA mka2B2FUt+HbqMkYQM0tmVuMgGrSW+0BCh3q0umf4cESd88Nm/rMHhGdFKIDynNMqgA1hdKS2ei3dHLOHXrAJ0W7CYAvihilBuhW
# DATA jfblZsXNfQQ4P3JvkEskNjMawq6J3205O0u+CtaQSI3OJCq1s5RGXdFQeZzVzwoRJizUyKFRMnR1ofzEryQbCYfK6W1x2n5fyYt0
# DATA YUKMHphW+8S6IVRFr0u76GdTxS5B1pBubwTWYq7vaHjSRQRGPbZaojN4Ju93u6PMTXpnV54SZigyPJwCGiZd1r1BZtBX1ByUJHHl
# DATA d2nFZiVn5WQT8jegezgxYYrdVSPutugG4IeA9qH/9A6X7ZQDJGU6w8SiLPKsefrFrQ7BDwU9A7HDK4vypNRA704HA+SBIqmFKPPc
# DATA Z6Ceoz8RPAJT68S0eV87anFOWSZR0TGdEOn8PskLBp2bdZ6VzKIwanttknX4GWAY4cNoUmGZsODSOYWxes/Uc7HcoN4cPy3Slwp1
# DATA e0QmMFKA8L1YJIGzy2cAoKqTDLgyN7Ezn+lC47zVbMPks0I2x4pM9TXz0i3GZ/UPiO/9iwWmz+pxgkkUKQVhmjoMnC6IpnPOAh7N
# DATA 1cJDDTWig3Bt1z1p4zYRmcyKzIMOJeZUEhUIFNMe5EVSdDBpH2ZA7frdh22ErtBohbYyu53xQiPWagWi3uAyVX+ilMYsS1ZL7kEe
# DATA oSR7jKZrpJZ9BBis+fJWwa1vzFA4UOI0MCbL2Q/O61ybwT9RZpPP6FyQUV/aoL6ILq5OYkY4f39gyIOvdGqPaP4UhEqgrAp/Z/C3
# DATA 8jV4ft6jA62PXOY9NH7YHx6W0uW07O1Y0OVxssxan3DTYumSorBrJiGusXK6GXLLRRPJVhUNuAdpJp8CKDbBQkDeyT8YGDaw/X0a
# DATA zusXsUNToFI0Wg0YtEGHEyNkFRxJqHkaRlTfSlOAUPTmDvjXuVtC74hPn//8+d9qVKooJh3sMdwU6BvoEmRvAnBAniweLJaehULp
# DATA /IgyXg8AkK0Uo7EF1BsBmh0yjV4R88z3ZQmDjRM/5kSN+JdJI045YCMJ65xMnrFvnDNDPB3IUnBwGF1RICmCcqU3nGZp2Xk8psTF
# DATA Z8GJIhQzwtbXNUsDOr2P64jp3YKeJgyXhme+wb+4y5A4EC2vrtIOwdS8soTHFinNXfITY2rW4trVGQoUUGXxQY9mtmS6hxhfBLlC
# DATA GTEUef2SnKQw8zATVg3Iok7PZ/Ao7KozGbDJIJYCMQhW1KuVJ+P2GWeG0ItCwz8lfEz45HA66PQB2WJhRx/Z6EvzdzYiH9OM5U7Y
# DATA 33uj/lyPmbLvMrf6hc48QKl65SUEeQnUBHLCXoeNw6S9XuItP7+zn7gLq/rcZDVAlFpOEOt3ML5/9AHknSLIrDoUMkOkW46438Kp
# DATA itzGEjRO3sZ6bkR++d9QKlxAi/MgP+0eWzJ+fxnlAoRFhlAYkbZwI0F1m2LDkOFQYnFP6p3B8S4ZDR+DWDfMMshqjDnl2mOyOgy6
# DATA j0VlJAMIF6IEkXKzE+RoHp9A0gUtTWrLYHtwlrBqBXxoa0JhQ7X0CElIYFsBZ6t4A7y/Hb4BmXbLKwTXhnDhkJ+xz7lo0HHaQKgh
# DATA ctrAP9kTFFQTAL7JqMN138CAIRioxFLTj6o/Tv+X1bZbu7e37935SfIB/dKMuXlwb/vt7Tt3tt9zt+QkRluNVtQ26X4V6EjEl6Sy
# DATA kl8yaC+odFtKkFfCsUbs5XxG9UBQ/EbO7mwPN/nE81F2vW9O25zkI93VFSf/34f/gHyGTnom85UkMjO8xiDUEamoqe1q5pGuVZPD
# DATA J98FrEYoVCXPv1uzE35KhxaDJB34wNCEikVCobgCy16KCHhdwShHZvLggU+0aLcuxbJx6sklPK5czIGs1u5QqCYdEHuIhOXZS20P
# DATA SfFsilzIbeTmiKf4Xks960v5rca+ZPwpJRIiMaDFVzsLEzh+iauNPnTPP9a5MHH/uDljn/3vgryENoemzKrrhbthdA6KlDqtFWQO
# DATA Wj5IE/w6IEiyGzpesNmM1Qqor+Zy+nfye4ScPB9qxDb0yypujMiYmdBy00lDaJ7buaf5fA1MHYkMZABxBRlzm0roy8RPCP3s8xse
# DATA 7BxeRLBeWgj0kg9ywqEaG0lE6zAD+CGe4I9w3D8H7DZxs9USjXWHt6Qq9SUmHfuQ9DkaU+RpTtJDRcCzpNpvhzkSyHHzD6rgbwiU
# DATA 3uRJrGEWD5P++yMngyCGOiEACTvEf4rbifITane7Z1/UwgZT2osyGTh/g8nAuVKYWtyhdmeySsegPIQZGp79vxZBVglnrjctpkFU
# DATA VYYVUox7WBt08nPalr5nrtqcYT3j7kMlzYB4EB80nVaoQomO9eSoEz106mFC2mGdPSoZYcQAmhKZ1sPRmmY6lSUGksYPfjMSmWBB
# DATA IioRQBWDo1HV2UNqkycTk+GLwr4rOkK7QkHVFZ7FCstq8AfERrtRDC5xI5eeeMpyPB0yRxMaHSPzpespG9eyETFdzG+wTX5ekvhS
# DATA rp7E5jKPpwJ33GiRMPuqE53P+NeQuJjyAxIDjgf87a07m3swwwGzK/Iah/nXPSxomTZaD9kCHavZcK8V0yisE2BYg/NOCSe9zEk5
# DATA +C5DBN3iO+f5zytAdf7aJmj+QqZjjRPyNLU70+5h3J4UDa0hcByDzxHl7gkOHLiD21rUAHxdAcY2wddChNHGQPvCLL5nGMRmumPU
# DATA 1qJegj7xRCacqtd0ol7dE1pFW4XD1uVFSquzjj7OHyJulOTd7KZAZian3rK7yOW8dvA61Xd54qaRMmCltg0TRGDvcwonbfp82Pze
# DATA 5fNE4YTCdPyzu4vgSlt4JhhfxdOyYUI6f3CSHN7NcSpCCvKwO6/Hv6brGff8/4jAf9WZkXnYXWhPFO8LgTPmTUzQwKKbw98gQROR
# DATA vUKNeRyfPel8gi27FtydK0H8vrqaayzU8qkuH9SvrLs3y9wzHGiBeP2jx5kXmHbEdKDDfTvpvErFBgjGcYHlXmS/x5eVdnqszoWO
# DATA uh117iEXQxSQWyvIu0oe7g+kwfLvik8Yf/hD1E7h0BL86HOdGf7ZFyHPqFv5QVjjmytks2K4qeryCrPRsE+BkfZ4y2g2+mdfVEAb
# DATA ZXR39BXkAxLZ3D+PauXCzgIjxPPxbwvwo4SSxrtfC/FFjGdaMRHyZtqfctoEYDG45O9NVJWDlByyub8WAsfnLMF8qvqG2cYTGDh2
# DATA 6LcsQqAkYmeJBUJtotdZxI3Nx9PeKTZBh9I+/2stC7FpHdWGhk8R6bCYh9G0Is694Ma03AupchCmiU8t+mOP0Rf0If5d2xg/nEJT
# DATA O/jGaILUiW20WooHb7XK4ksQ0Vtt/qSUDkfdsQ6TOjoZgl6kwZg+mOspxVCyDA0NnAiXUnAjrAzwOFVmt/Eb+bfJqYtxAikj+bTH
# DATA GvUO033B3w8J947oV4qYzNlJlU4LlsUEO+KBQ5UAPSZ4yKibwXPuHwBM9SYa24cazyagJxePNEhflSEMcMT99kC4OWD9rAz1Hmvf
# DATA KekUMWbfG1MTTSA0VOUOyLnJec2dj7/U46C3ztgx94RZHQvagGIPqgm1v0J0p1SrbEIr38grwBa5/ALaS6iwGSv3yS3p8dP5bdjL
# DATA pLAVDRBV0FnK35v7npY6/z1vJcJKL+wLJkguqGnMPkgQiDl+mDVAMV44NrW3ijpGeW7tauSWFPoks/pFDduTwqGBjXROT3Gbqs+q
# DATA OqtlGy1jjRS3cQszYhY3ifBjw29eB2AhVU8J58Buu7zsEk0xRFtmwVYYU9lUgIkubhR+xxhMwaeUJKOoWSKF7pLktuVXj5jzxUQh
# DATA QosXXHznUzpti/XS5UqDLq+tzj36eDHZVTZp4VGdwvDTpkZ6O39tLzTTABGe/5YzwnGj7MzOZfEfKJ3ZqH/4VTN3uUn5wXe4ZUL8
# DATA TI4oOODHSM3KGmUsXiXfEnVXYaNtTH5dlUQ8oYjc4ur9e6nuBSFrQUfW6GNjol9SELHsd+3AQfETgn930D7so4YEko4uBiuC4CUW
# DATA QUPtoo07d1y4EceKpNMAoDyCGjrn9ciip6CLs3H6l0sNuGMwZdRfm2WG+x8FB3Yitp1OGAA6O4qcbPLwWQfwRDCHAYyuaJQdAoTh
# DATA sP7FZhPs27HUCFY/KJbfWDTdwAOziM7csQbzTO0Iyn5OpQglcTBMizen5Ent9NKDFrzskrd7zQItFNbnc5IX2uyMAZGHJcIXe0td
# DATA VPQ9PyhXklgXF5xaUUT79kEHiocZ446Fm1TE5f6CRKOQzxbSFxeTfvq6mDvsiyyiJ0fINYQXLX4hSA/XH2+MfzPxr5ijXtwJX3SR
# DATA qmbigJxuXGR/RmQMf+9rg3TexpJblVKkIIYAVxeutnNryHuEmzN+dAxBRMq0iqfEtvvffmY9/d1PafSRHAG2I8iglyMHi1nplj1g
# DATA 9iPBPLecrRy4yhYNrZLMG4Hn/EcOkL3BaDpxMDPQHaFuLTHAz5LjXd1xgsKXs+ixp2gYe+gLqAL6fwvc9bxtViTrOsnIsNRCO2ih
# DATA I1vYHJ/exbar2KkLHdNcyTw8t9QBB5kWi4pu4GJUxBHkfs0x9qnqSnMmytW6iLWgdMf0/EIkxeiR6kW7R5cqzbvFBBZ0lIwy1UPL
# DATA zJyxBqqe4h5y6RaXLuppSEPwB385p1tW2eZzBxUAZ0cMFl0ktjUvOoMM/O/32XCd+JMYppLZ+QEmcyFt8JkKx1FaHKUbcahkYMzV
# DATA wG/EvXKAJzWmBdGshI1sRlke4XI951o0Ks/CLUInVxUrFZ1Mw48R2jf9IATVcG5Btp6zX0JZvO5zv0bRHCJwx5t0uli+SAe0DnbB
# DATA PuhESS+6G3PXymlr7pIZ4rmALDu3aWRGocl8/0uK/UIcWvKQF9tkkT4w9Ltdg3kMW+8U00NlZzYKWf1dI9eSQQZZ0lcFTHIL6Wur
# DATA Jc4YxxGWgzoN5rjjTjNaoYwGBXZP4cq/CP4ghGD+Dv27MNdUGKFjOqKzSuKP0qiic2I4m818ZrtKAXEunsgN8d4Evrz+uk8OVRnH
# DATA BclJCB6SAxen3ZDiOVlnDTbunC1CppnwdtFkmdITL3TdmgQP8iopJG+UjUCMxymYRwIimb0iL2QzbmLGCipKbKODoXwXmdzoQsiH
# DATA Dj6+n/7gm9xQbhWbAO+0A4GPlEJhTjUL3MI3LncHajOewzAHmP8B87EwW6KVW0alX0UQcge1QTujGVdO9N/6g8kXDN5bRWDHAXKn
# DATA oQ/zJJW0HmjjOLlOjHgEZWU2HueDaBoe/RVsrTqlArTUPyxFR7DuJgaWr8oxTWI96Y3UDI8B26A3Mlytfl3hHPAyXjpvkhCDccn3
# DATA iQ/Ur7pqB45TeMnjhxXEVg8B1fO8433mQp2PR5yxGqRs8pgXOCZOKg1bg/Cszxfl0FJdn8vFLuVkJtHq/bqn8EnJClIXNHQWLhmb
# DATA AyUmSD2WZYTLbQQctKhkPje8tKTabeFWarVw+K0WbNJWiyfACWkhV4UlARQTQpEAYgwiidSLmA59xv/5+d+qw/sbcgvP8XuZ6ySN
# DATA zSn6gqnLgJ2hMGsB9IKwKXtn2aR7ukkZA+UgSj+CXYG9ryQ/7J7xX5DZgv/c3uM/EKPiz/e2791GEBp8WpbhWluomsH8Cr3BUX/a
# DATA 0RhgmDQhqycDjDnH8Sfj7k8JcoPzsUPE2rTfT6CB2rc8fbXk2b/YYLbnvyDACgYQMD71FRfD4ucUDCjoMrnXu5lFnv8csJYutBp/
# DATA 8l/qf+rwHPbhQlSnozY6+1bagCjwa1ev4r/qf/6/q9euXDF/4/O1tdW1q3+SrH4XEzAFj3LV/J/83/m/l19+Gc6HInpkzNSxbhhb
# DATA phOvkC6tByB5426/284A1odCKtdq67Xvr9eWlvZPwGlVFvzZVHHeyeREkX+ET+OICAS97D2EPC4n3f4IAy9OgCoAMJ96O5w+PFnC
# DATA QkZOSPZv7VQJNfS42wZUHjQkQlCo7SPnq05O2o+6qnddcKUGu12npvrWHWO8aUfdlIdwQwKy1GBojLFHkvYjROmT7tGUIt0BKQoY
# DATA RULtWwLk2Hk3TUAW0v154zlRd43sdPodERInIOXop9l/wPl/49rra/75X1+98sfz/138L51mXeab0xtLS+ogZJPkPNkZ97LT9q1+
# DATA D+Vo+pXM0IMfj3Up/bMRPlw5wjJp+QZ/+9PHE1kMuIzH3UOyHJRNC3u3tncw88U2ZllC5NK/6pYOKGtFhienrvGvfe/IrA4gZ4rn
# DATA 1ElvOdlF4ATO77M6e27mFwAOXlXThB4eTwcERTHuTjO4HUvj4eMy5+jQCeWGj5M//VP4p8YpTJzgYNkQunmnqrRVz8Bn3ScjNUEb
# DATA E/x0AKzSBx8kzos3Mb3cbeDEy+Xg++xI8fpZTdHVh4jj0OA51U8++MBhtRf65rVkTY+KizLjl7mhGjifZbdTXBOwhGcl/DppvBmt
# DATA Cn+X1UzPlpbaEE6emBlX0t+jHogYJdpdFcwtofN06TUAZdxLK395sFr9frt63Dy/Pquav6/OqlfNjyvqxfXvtw+bzhP999r67NWV
# DATA GmQCx1SIMP+QgEFMHOQFGB7rLGEvkfIKEi2kUJge67n7QXJlvQx4mWpnwLoxmOHWAOVxfU/RBaO+66hD02tDypAbGj1O7RvaS8U7
# DATA SZbXbmAgLIHLVELTVmuPepjtMasBxtP9Qe9nUyXOJY/hHqyr443jnSUzbnxlJdntZlPVNmbBSdp4YVdR1NIYUxXtmgDN4R49w0sY
# DATA MBV6GAKnetjuA1DB8Ijv0eNk3Ht4MslqZtlMh9U2e8mcL/20rFcYJ9+fSnaDSpCWJEcn7cHDbueGNkIiN6D2z4TEEBlhTI6tNFTK
# DATA GdJXywm1N+wMqgXNmULEDobpw+zdooe0N2HNKok+tXV7aOE/tcHwcQnc5NdWk+XkyrXX1X+vX7uK9xyA5ODRqCcHtVqNDhBHqDhr
# DATA sw8s1LDfSR6O22o4JHYpyV6NfDSETAGQpA5QxaaQdX6CqMYdgz5WU2sLLIWubUjZ9dqwe9pHBoQMkVadRQYerIf7dEJLjWNkNii2
# DATA oPrvhYiHmEdaiZzZ17oI2rvnMOezCq7EOc+emLzZzFlmJtbqSqoBx1k65yVTd96YMt4D4QWQjz5E6WzsbImAjV5bLeZdsCYc94fD
# DATA MRJQ2gqdDczeAoi4mEFxDRfTfKi6k0Ph30rOAcGtDdrpOkAed2eJ2lCqYNCS/jhsaFZOZhXhTghEqKLOdLv/cKgO7MmpGsm7e+Av
# DATA gXuogMi+PRxvEVmKkluAwBx0UJcoKW/wUB+oo367d5rdkGC+qlv0FDAx1SqQTd5WYZs6N92H48ADaKoBqKNwBIBKqqqV5WQj6fSO
# DATA jwkrFPXliAmpSM77asdbsgqpTTJFxuAs6i1cS5ZXkplj0eG+qa1Lf6HhmO5y2Avwgq8Afo90syHvAXED4vl6kbeSaNQ5L5b+F54c
# DATA Sfo15Ye66nI05sTIeXEYn7JJTBNczqIec0fb2mbhSZxzv+NupQ4g+1ij/FuYYKkzVUujiLQGt22PHz6i5IUNwMLW80PzQrUDsJg6
# DATA N4oNOXc3ZWQmh8RZAjI1JpcuEc/7Vo2q+hFpPt+qEbv7Vi0b9UGuq6WA55q89Rakx3mzkbwBZzxQ+SoudjSBBICwH0uGN0aomvZo
# DATA tIIqdRpitqIZa/6oOnqYlmvUm52H5dJ5NH5UDWJAWF17uDHrZp7URViTSX8rkDGqnqxX5tSzT/C2d3t9xRvXFelprQIoaa/T73qv
# DATA rtCroL4ZUCXKkE4jV62X8rpVrmVdwM3caY/baktRdDBlVy/D9KYYlnYENM1tCSgopMtRu11xA5GofWxayjMlXmu5VTWNcTGQfA7k
# DATA NjvUKIanB2Sm91fE6ACLBKwIkbfEybEcHohyiZ8VEWI5T9bIvnf/5t6t3a2d/a3te6397R9u3mvdv7912y0OaaPJEF8J4MMLqtvd
# DATA vK+6jJVaBWcNOIoScVzqHHm456SLp7ccCSg+xSnVBxCPmaKutS5NZR5A6LPfwiOEIwMbuQnp/hsB4oAGs99hmj8bJB0EfMe1wn/3
# DATA 7B/Q5haHOvPhOWoY+qDn7klvcguN2MmaupbESBn2isfKhPhVdBDD41QiaYdOOFztQ0rYc263QCW2GypaTp7dWPoO9D8te/pfqCq4
# DATA WP+z9vq1q77+98r6G3/U/3xX+t8d5KPs2msvVsyZAGpWdW5RogjUJ46U1e0oCQwTa7GVByjltav6FyiC9N/DbAlRjcFXp9871GYh
# DATA 8BLQRcZd/ReY98zfBtxeP5l0T0cg31GF07G6kg4p8kjXCi4ZcFkvmaoplyrHLJPLFHqrokcxaXCPO4tg6WnoPPv73s0727d+WLa5
# DATA wgAyr0OJwjoQ9soJYihbmLArErYwAuwBsjC999KOCIAtKFTba23t7W6+U5LotA5crc7JB8kmYtkXrLGwlG7d+9HGna3bfKtA0LcL
# DATA 6OLhOhKOj24I2GKGhz5fxalSF3hXPS2VZ1H83NU33ijP65HtSesu3FY3N1s7u1s/2tjfdECe8WriCbXJNV73k2sYh7glx1GbVh7/
# DATA 6+R2wSe8RaKFnaQJwiUA36IrAi5F33wQLsScRdDo8LRda4H7H3dab2PypyG8Si37Gx+W3O7akrrHFJ7FyOU8Av0bBrG+evU6JoN7
# DATA 8AAThciyEIw2HHdKR2XQh12BR/xTcelr629QFJb8qrzIdOxs3Nu8Q9zUEuUeR88PmUYGA6W4IyARtKeTYcTxQU8mAZH4aCgoUfpg
# DATA RjKvA89m6Xx5mZ0PdPQeRiygN4MTsTcLTq6tjuf6Eokd4rOlKM/GHT1X9zZ+tLF1Z+Omc4x53jIKPpStcvr0ve5kwinTTfv8yiQ3
# DATA 9mszkNdIHiT2mWlOJ/pmElHCTNWIZzLudTCaNh2AO2DZwbPGNkgh6ve2fdolJ1MAYodTDTlz/ZnW/Yvlg0gPNqp/0a7+FeAz2z9b
# DATA tWpT0S+1UWcpKfYuNOn3Nvff2979Yc7k2+2ZpBDUWl9Z0bnBbY4nwLfjLYpOVPqHdFgzk8ELBPz+zvYuut1SHLRxppSeQ6J98yfk
# DATA A8B+yHNMgYYYd8t91K+wLnWfqir0rWpJgz6G6k0NJTe53qoyBMzAMF9DZqAobAWcA/UMfmvdnP6tYfH0759Nu5TjA34cj9sPkfkw
# DATA hdWVa1pFOFhqDV/C5a9ow+plSI47sJcaeiwmopV3W1Hd7+7v7+xxzbub/+3+1u7m7dS5dYzOdmy3dUVXrSj9zu72zU0gY4rNIr2F
# DATA ToaqhImN6eRkOGaZtJ6kN5VArcgM4iD54t97Gz/abG3sbNFNo8QLdHCOljIzwdh77wH2ntnBpJjiXhykP64q6eVxe9zpduAvdONK
# DATA 1Xmqrar/W0tvxEvujIeKWjcTM6sgLXlaS9jqyKBBezT29iGuKEroG/D3LcLp6UPUbsXkMMtIgwqh3ySg4Xc1/C+Uuw5aVSWRa9UQ
# DATA q9ZQuZ51jX7tuAuEY84cMVaqIp88UEBuJg/keoqir9qUoItu9+vUDfpBWjg0bOmGa8P3tT2J9w/FdLSPoAOkVwC1KzB5jVVACZgO
# DATA 3s8aB014AWSYul2i4eBbtMjo6g+HnTM1mfD5aw18zaasG73jEjx98+oy5mqA/5TPnUm7EemXrlj1bEZ9qY0gud7NKShsa8Cfl/C5
# DATA EoZnZprRXayBXmKUwZWLq7dHig+misq1yZD0WsjNKWbOThf5bn7wgdbU4u+XGo10iJZltNRRoZpZUq+0eSE+i069GOKSObNuFerF
# DATA TMNgJ+dHfXUG9ebD/Qhjny2VcHOXyo03zWbWxu4GLRtS9pX2qLdCxvAVYwwv31ADL3H/9VPtmgkjYNV0OTIAA9dwQzfLBvCw1TxT
# DATA ufhWVZ81Nsbj9lmtl+G/HNmdld/ShnX+t8b/qm9V519yP4J6yrHuyibVZ1DuYLX5FmnEF+7xSvoahhZ27+9u3dLBAboy1q4rglMu
# DATA lY3KSq2Lr68SuiTyURQwXwaY9yngcBntFJT6ilwRCWn5M3oa1Uzh5VBJVBnE9oLkApSxhHRhtgGEIJZgh5gYxdN9qSnz1VaNtRtA
# DATA ZdB/CUUGVeCwW+LIBCsHsADDl46iKxQ6XNEOVswS5UtQoZDBbUgJAx8VXZY7G+9strbuwn9DforScLPoX9vvgmDfHp/d1qEeJQJr
# DATA gESKOucX7ggccpVE8ONhXxFoBxxchxzRqzKHMmuVGERJ2Q4zY0YqUMRuTiP3QUOyT6Qjjdy/WMpRo8ZY9hKvhJMi5TKMe4Dtj7aw
# DATA SOX5sgiJ/z6XzX8K1p8Kct02y10sbwhuLpurr4koN90jTHUKEWpVxlBGN+nBo7LZmQdQZVMjbkFx+C+ySh7eRuBJjy2D4+IA2Qgx
# DATA EiXQqIUdl8xArLRSXqzzDNRcrRIGXbU6UtIHijpdxqiTOFTUi3xw0Lw5wOdqQXGDpXYS+MhF50L7ihtXcOk0LvJH7pk/fefwvCML
# DATA u37j1q3Nvb3W2+rEAntL+ctQTieyA3pCiwCCaQbyiA+3qEjWLt216ntFj7sd0LE/wkzqPCekfbyRZCftMXl/JJRrQVGgM5EfEqif
# DATA cESnbDMgQSzZLHJxaB7OzuRC8bCzu2K+Y4c/rYuRpZFzrwrggGdLOm0C1GU7BSQHU+ZkJR0RRd2QQKT4LY+b4IA0XkO0ouHkBJCl
# DATA c+pxk8ewLF9J8CObn0JOTA1qAmBvLeS/ZBIO6rlyQCSwF4xRRZAb5ykulZqM89lsySQ5hwHVvQR/B6kQhFFgOF9e1qRYx9FLWZlz
# DATA uumsGOZT0DQsL9PyzSLCspg67RvsVkwQE+cpOkyprusNncLY1W/4Z1ZJgm1T4T1jr0pfblTPZK/5fYuyL80/guq+1HqIuxCSe//e
# DATA 3v0dUA8YWTPUBEHKEQm6pN8S6TcfYbxbTNlTsZi2+lO5LcKAKcorAlcDcc80UtDqoKZQH3/EibQXOAArOloe6JDUM5lLSbSoXx5A
# DATA GJdu2V5W9NzpwEsNj/4sON23tu+9fWfr1n5kmuXsYqTaubrbJqDo6Ku9Qvlkqfm6/kbMe3syaQP1AhiFcGcgYHDKtXuZPMU86Ep4
# DATA CtyR6ZdhP2dFgWiiY+BAW4KaUdBT32alg2XbJkxyuRycZjMEDPfi0o7DCEK0EH1oOgmDkOCX8E1F+wBy5F99yaVeZnNS7hfemYK2
# DATA qLWAVG9or6odXrvKlgP87iClSAfICuRZFAgKm7wPUWnGHxBNaObwitQnaLOiP8Cz3Qyq49yC35n/P0d1vvAwoGL77/r61Teuevbf
# DATA 9at/9P//zuy/e2eDIyV7D8BYCMEp5Gnjeh5T6m04Q22ZoIFc8CyKNPJXyPBhWownE2Hd5Sec4E8bY4+PBpO+/gHwdOoL/dNE+75Q
# DATA GzII/JexFv9w8yegoNy7f7O1c/+mIvSt29t3N7bupUsbe3tb79y7u3lvHyMfkBGBLAvj9C9Lb9XJ3eMgeTBpvlZ+K/gcXyw3asuv
# DATA Qvrpbu0uWPSO+u0sS27jcaSrxt46Bl9bzQsRxMFwfArOSEyxcm19fPlKMZxII1v56OvkzeT1tXXyq2SnLEhm+SB78OB7b73y4Mnq
# DATA avXBk7XjB0/eOG6mTMICK57sekoDbbFqna9Hz4zANFrYI+hJaIwQcc+5SvkFbQkM9kHmAhBRKsnVq1ei5omLDxC+pBGaSmqkhyql
# DATA vc6gnZr7pFzrQ9ZDNk070rkT8M5/lqA6J+rXbg6BnwL7I7y2F+09qARgT2BbYPV9Ha25ac2kicbxqUfwrxpYh5LygEskJNjCfKL2
# DATA LzT4eUl1QEXd75e8rKnqxKw+0d6wr30Af6lzkwJU0XhSZlFibHogHDGD2hE/I2zhgO1+qiX+E61+19Zm+k35rYXau8Su59R42lZ1
# DATA UK+uNfU2pjxJeiLRcoW7X7/T69LXriqwLFdXaVlqqRau4DeJgDbljjP+FR74RvUv1GBrrf9ebb6mHq34z8rLNO2QDeniI2UGDncJ
# DATA GUWEw412qRlR0IjDt8nsgdi4pGaR7IA6l7ZBFAFCAE8W6bOSjjbeBpF9/900cvxehBsQn1EAVrk3nLwNCCzeUQXvGp6JesyB1Tg5
# DATA mLF8q/5FpYs7GK2uX+XM3vLtACCSYDXWwnygttTFfYfW16OC2WLri4nL2pO27zMkhvBaslaWhw2Kl91hXm5v8XpCfeow/JnHEcHh
# DATA 6IP+kDxT3OOgfVVqJuAZCOv76Rxvtfd29aa8tbu5sT9vx1ZkPvPY/mq/lrO/Im5puZvNbKVvtoqBGht5SYihOXqf26zwMxhba/PH
# DATA arji972bgUr0JnzbGzzc2vaOaE7/7u/c3tjfbN28v/cTR9OpPznrdfsdpnu82nJttVcSQnGAS1JWws1Y6JhktqbIsG5TURAwNelK
# DATA ELLbFspJrZQ/7fe291t3N+5tvGNUR0ZfWJA7V5Jrm505oNn2lUO4bQtOmTjk2kV2DPBfmHo3BtdIq4G4T6KMC4m1JMmjVDBBxYwB
# DATA pLmOteQHDSQd+LIMv9au5bEnXl3MoMPlHWFc6IJGR6W1ytr6deOo5HpeYbOxBkVjPN68rvNr7Pz1S+4Xne/43C6rTptVJ0YgfCHY
# DATA AoSrmy1ZwDesa2YTJ2MXKcEZdlayv0g2ZfVUxr8EDDtSQFgM0rk4qHgpBCYVaUm5P+jFgHWK5/DW9t2d7T1PbRuhLKF0F00dXY6q
# DATA +y7YvGWHYDkPYLJAX4fXmDtF9iX9XvJNCWZzRpH/o5YXHBFucd9miTcOlYsZFL1scWEO7ljGbDwHB81YU47XLNcTxf7yWzowP9x6
# DATA YVIIBQTd74KUybKuyH4u4bcHBJjd9NS9+M5J4I1PQisPraluoqlPhH7gMEKU6llxQlfWL0cPNANkIRmZevJk8i7SlkLVB5T26bAZ
# DATA tQae3F7mAYr5zDJSTZx/1E1bJQ0GRqJxFz1nPKVu2bnAuJL8VjR0HBc8UPIceJWwlNhQ1GytfLDWdJzPNTbcQR2EP/BUfFmVezl9
# DATA Weyjn02HyBpQwVWZ+aOjH+NASliyollW0q73+uZTKK8Y2rrpArtKQ7TiKqtXUklW4N0PEhQrS1iTFiPhh8y/m76SlhcmLK5wKGeO
# DATA urlWV+02IwoLXQyUUTip6h5EXdorWvmEEY34rrFWxskXcy2dtHhb6WQOpXnb0Hq6YA/sdqQzE15dTXd9wz2qDaEV3sO5JgmROlkL
# DATA R9qjKjjBYf9IYNGpJp3W+Sqz9dXIHhkg2RYTbJIpIYWxcKqPGWAL6LnwK3FNs2FLxwloX1EBDW3Wo24Seh6ozIH6omk9lWSSFed+
# DATA 11/5StSlC17rvBV1Y6RNRL0Gc84Pu6gPZB13jbMYlJfi+4IztjrbQ7RG1WlwBJMrQSsYAXHiMAVdLWhMS16buD1qVAXRA01RNUwj
# DATA 0YXD9LSXZejv4xym8xQHq1g4HrQSVCh0UT3inp10n+gGdKZAKt/rzPQ5tHYHDlshTI8GhgAwkhZIQixroOBkpQUro4ZCsyOr5Jxu
# DATA DiswIpnNF0LIZo0LEApJP2kQ4dkXE0gtBDoXycxhJcJcnXUn/BDFJL0E6CQ1QsiTXb0Gs5i2hb49CEs3oTrq0IFdx+biHOO7G/fe
# DATA 2YwRdnuidOPUZ8qy5D0Ld5/D7p4OO4Ar17H8/6XJaREpNYy+w84u5TnGFBDHS3K1orP66+hGmsvpXohI+6xwES2O0WMtO+aw1Pld
# DATA z78p88dSGw1HJdW8HyoUcM1Rb7+wPrwoNB+SW95kFvMdkKiS4Dv2KUCBsTM9HWXG5a07yMCZqJ0d9Xqk+K5gmufBpLGuE+ou4LbI
# DATA DSAxh/k/TNPAQSF2keIZeMmVJIh7MYyeYJXZ/geN5Sxj7u7jDsrKpocYlIO1BWtPp94rDttMTUnDGP7466WinWToyKUGxP2Gf0wY
# DATA Drjk8tKof4JOxVYN3LigCnMjv0QSc9iopm1Gdna+8yV+XXqRi8VkvtIKRZ3Zm/WDSoaMpcKowsDATI7O8VdLZbjNnY5QPa7mjp59
# DATA M5Uu10tZC0BF3FgdvgGwI5SpISONUI5jjc0/ddoe9I6BC+HMVNbD8MDpXjTZlE4khA9tmmtOZYUp+aQeJHpveX68NoGVx4mJisqS
# DATA ZVqokVnAsGNvK+aa6w6mpwh2WtKbxk5d08ucNUEXaKH4CLXrtoGSvXTL8YYiLKvYPjETIK4s7CMx7vgBvQgvIhrNmc+cNuI7qxTf
# DATA EwzYzbUHGoWl4trtZM7/kpdKZ0tz9ZbaiNHOupv4J8QBBmuod8cY3NAzxTdznRddKkJlEpSrnscreDNffNGjLXc6IFX/0sUv9tjc
# DATA Lrw41rgqiKoRA5YdeeG/GtL3Av5/p72HjO/3Ql0Ai/3/rqytXbnm47+sra/+0f/vu/jfKy+tTLPxymFvsAJBE6OzyclwcAWixLZH
# DATA kHk9mY7Unuh0IXS0PbBwmQEuqQMdCVicnlcgu9O1xw/R327JeAWOzsgbDzQZcHK1J57+TYG8fwXS4Dd2AwzgYyATgUaSAS+/+X6B
# DATA 0otw6dIJp6JQNJ0uTam60WyMP1G6fvtQkb0QCeEWAyBbVdodLOnEfEmrLVVkrMY1CljSUqFOv1IDr2y1kC31KQEtaMAyeLtwNeJT
# DATA KwvP+VSHSthPA1uy1EFzfL8YYgOC/h0wkpP2GPFI1g0eCT6RkCTqAdyJNs2YFmn1kF0JN98eYNAbZGYbJ6kND8e37c7Ho+C2y/mN
# DATA a4PTgotMEilZnRhOg+0WFXfqjU2YDUDqF02mNmHT84JZ0XafI6FMawi1GnepYZJz8WAb/G8lFnNnjPMNVsdhMNV9dTIbcAqlBFPW
# DATA ODk6nKbd7yk2KbMHzQ86yziiEgMvLw2WQo9NLK0Op/hGx1lrYTFxEOqqtf8oJRHS0Q5W1lku6dEwYggNXhs7IRbKK3H73h6ArIgi
# DATA IR5OERZLZf7I3mWnWM4WaKFkL0Af6Kumkf61aplSqZHTuuMU7Ug1L8IFORf05NwDPZl9t6AnCzgS0rOS7XrFdVbmTVWxrtJgErx6
# DATA 9Yo34Ib1u8apur5azreemExEOdSC1o/y1E2GlFm4hP8VWwoUZo/UDAChdk9rhcO4i3FzKtH32Ar1nMMdGu5Gco9ILOATN6UhnTpo
# DATA IsdSbY1DHHHRSM6d9lTnMDqNzjUHu+kwWw4+UC2+vbt9b7+1ee+2fsYm3kfYT0jLPvN7NOAmgz4ZGxmwdC0RJYj2h8uTwSUv6DDr
# DATA 8nxfgqIC2rzizDAov+T0k5p5JbmNJENjomXs+9U+Gg+zLMEMBSbY24SwTYYIeH6EvpWYe5Er+ynA8MMr/QnH2hIGgXpOQTCHXWB8
# DATA yZezQ/jo7dPD3sPpcJpxXC5H0WbsyQxfaQ2lnAwIkMcXWF48a/B+pID3uHDMkPwlEYtfEvVceM3y/of9w910QE4M/sXKccb6UiWb
# DATA ie1UZN1iVhYTeGwPvN7LZnYLDtZxHJXAdb02o2Aa6o+EqU88JjRQf9tTppbLIF+ZRoB0AWjWo3zsrijpNgfTGSN7lmo49SyglJkg
# DATA lQ2ySRPefwvSADh+9+q0TPsTqwTMugSsqLppjdQWvY7MaNyKTJAHuKALMDZbmEHQ4Tr/DMG0TVXDxwM0+GGVtTEXqpNLzWqT8jie
# DATA HI1rveFKfzgBP+oVGy4cwME4Ti5iEmgrQ1tzVnbcVQxIj+Uot1Mr1KnqmvH8qbtjQU2a+dywCGEnnZDn8PVs/u6Dyhe/P9FtzP7w
# DATA 9cx2iefu+0n3FBzUYjKsF0FeCsAHNB6BlhvNAxM4T4Hk0EZoHNZvYCGhBZ5e2MC+myGoTjsdvBS9UwabX6tVoTbH44G9MagURjM3
# DATA +or+dNrYcF2PqKD7ZeMFTlAhEGys2G7IY4ncSEPgbqif/plUj0oHy+KjJhnCGhQ7ftQeQRax1nA6GU31wwnhTjXWrq8aosnjpGGB
# DATA ItROkEgdyjH+xP46MgU0LWxtsId1DqYkHaEUyRiZ8OcU+V8GQskmQ/qJcCgaDAUhXmZgd2HoFOFtSoln0PcLe03ZFzHeSQDxdNsZ
# DATA AfeX3IRHKeR3mx6dJEJigISPzz989ingJCXPvn7+8fOPMEskJJX89PknkPMxefapzhiZelDz4EL//kCRiuS438YRM4LTR5ipl7kO
# DATA /lhDPyEw02fY7L89+wLgm6gVL9Fk2BZkCgH3myHAngx63Q42KOChkme/Vd//AdNX/k8AMQ/ruNUeMMQogBhpHoc72ml3T9E8lvID
# DATA hLOS+FOfx+pkGtFmVyeh6sHvf4epjT/ExJofA9qVmpl4Pk/1IjLRZW9lzW5EuyxsRspQSPufDBm0A9S2pFdGHO4N9CbSj2CjMRyX
# DATA BN/SE/BFXld/mcit8+xp6ucA1QJFmEW2dJw++0fK8Kym47NnT3VrpXNz5GZl3i6/RYQv6NjfYibopwCMX6FefZacB8d3VoeHMP5Z
# DATA LZFppnXG+U/VP5/ix4AMBglNn3/sOuPaw6WIhaVS6CQCBKdEGD2oYpGuWUEsSAgp4zlrxYJCwNAbavCwPluuPTg6cSVGnm1Y3RJM
# DATA 71PMCguZs/91PjpazkZ3VGgHvr/MyOmSjnt2qSPpwTBoDefCDSApN+UsmKJah6ZDG+FFqeyY6gL1mjv8/+Wktf13Q4G+0UTw7jCQ
# DATA VpVED4fRrOjcV1mFE9V7ereiR0pEJXbTkALd6mHVdQdZuHE6EOhJTwdBXI7RlfUgrR7zl/Cu3GxqrBC2XlCcUousgQyNhcpCfkQG
# DATA 3hZ5IZos15zrNHY/q8b63e6oQcjc8KdFsZKHxBoeYlkWIJLO/lrKBaq2veeDRLwWhynJyu9qC56NVwpDtOCEBYcVuScua1bMljSP
# DATA 6g7H5+/xwuApTJ3SCIlLeSkvyMbllmjDMARaukxbUjMf1epgWEXVwAjTFZhnABGGdAjzudLjY3BNxDuLPURghYHt8o0VHhu35Pnm
# DATA Oa7ZXugNyjq5Z/bv1Un9DR9OuiTd0xpJaLIIw7IkMfGRitptXq5RrgO4TV00/HkQ845XLFjsah214+EP9mor+yrzCIAa/9l0ih5w
# DATA JvmmFqmct+jqlx5Oe31gfqy7n/36gnBgrgbPBwSbD9FmGyYttW7Tq7jvKO2h5t6wZsQ6rcKuQrYxVX9ECpwtOe5buJCCRpVDzy2E
# DATA twTdtDabYuZBbTmtTSdHuOTH8KSUfu8n3zv9Xmf/e+9+7+739v6CfNuiXl8H9eusaLqAaxYiPiTaIwwcsigKFc8azSO7VNDsEYMh
# DATA glijc1JJHGj9uj6EEJUsgznridlqs6XQIwQ7VzE9KC8VOZJRv2nra2eyxb7U5gr3W/rF9E5rbZyZMk/FbLltiOR58vA9bmetMcFz
# DATA qgqtCkzjeopcCUYwb2GogkdkSYqrVtskoFWrP5v2MH2umW9NLP2gJlmvJXy2AxHC7iBmWslR1iSIs9SouON1EEZzYUs5IIOtE4NH
# DATA BCJmfcpFEgnbf+PG3qmIlAcCF1YzucEpZXO/xLdkrUGr7jkvy85IyNkQK1N2x0PLzPGLzNkwrhuVrTbPehLBh42ZQASrr2usL4Xp
# DATA 5WoO+nBkUKSsNODDPHFCA1LP16XYm5wMITS19bl+o2K83sE1lURAQoK9PIdVDnRFOYxwREtm+VybhbM5lzHSB1hPTTAPMILepMWd
# DATA 1iRS7BuaopA1LsdWVuLzefOGlgNV6lGUD6y4XC92oxxIUaaiV5K9yXA0QhiyhxrqNaNHtWQj0dQBM1X1MtVnTt+Kphsl7CaICqv9
# DATA ldQMPkEb6+2btWBtqdNGpYWMZaerSaX6oZmUCM7vstoZ1Q5F6EqqhYrMA/ocXVpAQgqprFRzis9Dx84WKkMgqqZ0bbUcj4iOkH0z
# DATA tEsSfqeJF0rr/TuFZuw8jG866bb7GB5dfA28i8XkEygyzeL+wotdKWSp4w6APpToVkpPznyFfV79efYR9IgmmwoAsuXT5YAiWw4W
# DATA 60CqOt9rlqWTfzKqS5AzWHmJ6PWgRfgKtGekXvqahZjfou5soYSNc3QSadwYeKiO7vuxZdJr31Bnc6BnHSPeCtdPrzzpsDtKMCJt
# DATA tKJDnbxF8ybp13PlNQv+//xvQZmXSNXjs989/yR59q8g1OEjBvuPzgBqGErri8CZR3RDH6Na9vfPvgZ1IGhmvwSd7Neoj/6MB/Cr
# DATA C61Mjui/APmO38GtfvsMUmSQ9uPFKy2Yciwva+bdXtFvc2RIbEgzl2MKWQepVsK/HceXHEd8XQVjvZprly7Zxa9UC3vrRsV4/Px/
# DATA 4I1F7vSkiQPZrWQwrcYZpubR3sC1jfHDKZCzHXxT0lZENfZGq6WujVarLL4EG16rzZ+UUqNGJxx90Dc0YJtkR0NG2s8Uu6JNUqgQ
# DATA 1HwEqRW7/Q6pESkuitgntnvCLzKrkRGLVUsEJoP2Lm3IRhKbmgiiKsgA8FMnXUHTLrJNaADDDCfTcV+q1KLDq6Jkjr0smIRqFeNS
# DATA ILzubNRtmIxcaLFr6G/wH/gqs2Ib/KoJ65+ipGbu8nhm+ganpSL9DxwKgIXIq0rd5h53hy+Fedl1TMAdreWUeB95TQUfTkvv0yH8
# DATA lJbL4aXwOc6ZiUBkbfwqOLiK1z9A31eu3nfPCC5O3wJGF+VXaAFSZP9CdDaqDaYBWWpjCuaqgoEzot4f2GE1i5aWsxtKmubcNlqv
# DATA LgtT1STQ4d8syeHfjoYdnxhZAn8ZXbvRotvd01KnBOznatFaaFhotXAHtFpAVFqtNOLbSeQm1w3RpL74YfdsfuIL0NN3PXjVMfjx
# DATA pM/+Ba/yz+n2XtDi4pj5wHB7I4nYJFmnWyHLIycBwrzVcKN//fxX0AhURhZLuOT/HWqH9muJ2olPuTeQeQib/hS//QhNZcjDKZ4A
# DATA WbpKoj77iDIZgTL6b0RSbuzZF7B30ViEbQLEK0ibDYh/IKu82IpnlHOotPZ/RoTU/9n/c1T+KEe/cPj3OfFfb6xdXX/Dx39fv/L6
# DATA H+O//mPjv3YtzDsm6uiOCYGDtPtB/Fd2Q92dipYf9iaQiks7OTAzmi0WAxaixuvsiS32T4gjxV8+IgyzL/6njw+7kBkZ+xiP67RY
# DATA /Fb1ZhK7VYTznmTqmIHvAURFb3JGJtu6A/LsRrWX0gerae2nQ3CZh3hpkKze117s5MMu9ZypcCHSltZy2WIZOZHxB/X1q02DJH00
# DATA HANmqgX+wbBz68NKidwEAIJBVA3sS1mq+WH6qBByVOaAYSSD3c13tvb2d3+SuohOEsuJ6n3YHx6W0mWN5ur4ImsfkEjDF2lc+Ag4
# DATA nKMbLq7bg/SSqGaKLPAiiXLfgfZvbe/eDlMwQ02F4LNmzULXS3KQjyydAMNdMuOAR9Z5RrvVm+eRCY3y1iIGJETZlXtmh7RzuqH5
# DATA MLvBSKM5xMn593H7UbcatYASQAcUBGh9PmLRDt5XBAkyAzXRsg0Hvj0ghC6QrWaLjNFKEN9ooMWyCWeDGPR+hqBRAt0VdzC4/kNl
# DATA QvTAojJTkbtxyXDi4FbSJ3HgSrmn97e3AbDyJ7ip91xHKKpDR+qyfOyijuGl2e5U0avcOlUPjxPyGiVDxCkaK5he68ATJYF2n7SP
# DATA 9I7VaepI/PEgwIsOgtn0Lc+dDMmRfB6jbRxYOBNt558SFx5UlI7sDtv8XNDqvO440p2mDWxFgLMkqndOVNCsdCKoiAOXlmcB/cKP
# DATA o/EYwgrR62TCnOJYOXJMKjrioeyGJAzUTs4o2cY1HcAcyVzfrh5DmPD52nrl2tVZGndFhJoWJeG3tu/tb2zd29wFlM7Ne/vb7kVi
# DATA NvJFrDrL0AFy2lfTQ4pDq3FQ8zF8TGhudgFWcigehn/2hiuFBWMKexMdMqeJiwSRzMI4WOQ3kFg5VEtEWOSYXezteIHwmEggDPjl
# DATA 04QKnY6OHBAb1SrIxFIsFNUTBQQSVdYgm53aDGEk0oGprimjNj1LRkRDoxUz5QWgneW8c4/C+4icyUyIeBrDj4uOkd0Wc3ycl2IA
# DATA NuhTwm4J8A8z9tksCiVoD23EBhE3RckkKV40cgS5OsyaUoy/w8nw1GVj8s5ER6nxRw/IArKM7fBQc+ITo27VNFM54wiSh+ZaVIOr
# DATA zYA4YGYdgC7Jioaey14jj+tBlXltD7Oazn6aDqRWOgQdxEwszHm3J6VyETrioklSSrEsKTK6lGaGvO3hcVB+bXV1tVwuBkwsnqDt
# DATA 99QVEs+OHPP3XSAbcXlBWHcidgcuH9h0nAs5MFcxBOgCNvO5DKpiaW565IX0xTEehjFv0WjBbGOFgXOQeLcsT+mEZYbg86MgmXoO
# DATA g7CO3AEULxRgHUnOJgBj+VHK2Hg1YX1LMu5Om08w9tgbSz0IEPRY5+I652aIB4x5kn43dzdvp/kQK4sgrPhBe4vM2t7m7o+2bunE
# DATA 9K8gSc4SRQORX69SEKtm2Tn5L7jsqSlIDsfDxxneuqPpJKstBRfCQcQHbDl2SzSDzBexq2F+Eq1L6B584phz3PkkwAMN789YUi3K
# DATA BstHIgSFyYs3skEiNTuSBUF4bHKAAz5P2FO+bPRvii6TB4BhDZdCSp0XAiUmueGlt/GdFCC+n340pfTKfcUMVEU7cuPuza137m/f
# DATA 36Ml2d/YfWdzP71YOgMxdpvTYFX77Ae0y4MFR4xvqkJnMw6dHY0Kw7K//Ai53ZlR7k2BPRiO9cYYTE8PDR4WitpIRxKO4eZwcWj9
# DATA homA0uBlo+4YQj4yDH/E4Gg8lOgPCP4VRt4G5SgmBjOWbOwBt81zOV/ei4l537KIdxnxzhFhXoRsJ45VIBCJxpjIL+RaBzMk48dl
# DATA hsTJ0UiUglU7hNQeg4cWYWhHLV9aJuwMzDcLUMlUCDrFf2aMcuRIFJgA2xQAtbXtdAGOBrQo0UoYCLWpsUl6x8dddJLc2rG1n4Lr
# DATA KuCKJG3sZy25hzeEkmZgH7cHwrIC6Uy6gKwQJRKQbi//fFtJLzjecwP4hU43v4F5ktaI4CFcVo2pCN+RHtMhXqIxqmFKhqyDLSZ7
# DATA KD7NpWFcwbkxzzCylrHNeIfP1ho4jSE+f+jCJ2iKI/zMjZ3Vp788X1icLZSwHhl1k+rp7tbe3Y39W1K2eSXZV3TSLAgcMNJOarqq
# DATA lw/uq0ddJL3j7KQ3AnCdAUVmJmR0UrNOUBkBSxy7LeSsRu8MWyB2cywYlhzqEyPJ6MAjpQ2e0a3JEHeL2Arzcu8Gh+ISoChLOZAj
# DATA RhnE2p+arw4yeeri2fPycu81SMEsngzHnpBl+vLSBZFX/Ko8PtuCl+XjoeSYRMrlIloXZUSZYOrdXYZESJcwC9DOi6ADzsPw44du
# DATA RGAIwi4BMGkH02PpZ0uPSvQPJXKhXsm0Tq531yKGUIguRDoNENdkppRGlW/A7tlRaDZPa/CFzVHeUZoTCdeyKGDBl+P8QDXGxKBW
# DATA Co7tcbIIb+ZjtS7IjbnmpUvES1A8HE1jn0QpaY3y8Zy0aTy8XEOhJxDSg4wqmpuF58ERCh32ySAobHZC6MrpA30Sa9iyYVqrU0Gj
# DATA ZsQIOe/K1+YtoSUPsz+aoBZns7rIQlxPNExOcLjBR1OTb3RejIqXzZUfg2pLJ2lyR893TrRH82+euYqwhdRfdpQV06F0Omg/avf6
# DATA 7UMKV0uX4iBML0acrOQpNFPqF+Z5oA6m7OauHh0Oh31pWDciSUF95Adep3Ee1JWA1/QM71ir7aZ9VVStVVzmbvtZBM9FJFs/4+A6
# DATA gwe1rqPDIOyF0wPhFXE6VPRuOOgdYQIxLk/RxSeAvREU+oGpIhbvGz8uFz4qroOCKx16Lgm7XQxLsO/DA1O23MbYloaN5MYABd8X
# DATA nEyozYv7iqL45QzJqSfsh3vuC7rhxkAVkWMLW6KDigrVqxu3QWOgNdh4qzoKbOOYb3XW1lffMncYMSKRwLrikaZm/aESpxfXV2/v
# DATA bO5u7G9t33PV1ovp2W3cjNNj3ducHpHrdxFnAvEzLnPicSRNt0EMZ6D2dIwNNooVQNpN+GttddXE7hwN+8NxpNpyubwU2XJFfTW9
# DATA 4LAfEycU6aNeMK3zKYesVjibLzV4xSWjpamS3lXGW0Te0kLVN1ESC2n6QIOnV9fgsKBFawI+NAAE0ZuocqwOhKBeAOzrjkDjg0lW
# DATA tLJvHn/wnxauxkWpsXArMQAaaVSJiFy68Fw7C5s5QFuwt3XvHY00g5p7o++TW5HVXdvogAmWq067D0YiZj8hWwSCX+A6sT9OVku0
# DATA Vndy0p4IvQIsPdeI7q2wC0gl8RBUYahnmDweVvWGsMkntK2lrXF7cUvUGIKj0zlDVKlcXQHISrd0MWJVVK9aFCzeALwO9S7V/Cqt
# DATA gDMk8sFzk8fHWAC6bromGV+G9Pzcm9aKbtH1JIBvzWAifpDOO6sKoGPjsU1SpNbZIg0SkhFClWiYnD8Y0GnGREI8J4E8Wb+yurb6
# DATA YDCTCdJOh0ooFUm4swMeFuVFTB+p7X/qzB0eSFDcM5aysIc+0mky0U2dKoAYOL4RQcea5mIlc3kO58MvCF6BJ8ytFbc717vSnRyt
# DATA YLkVu0FIRQfbgYZYlmi2ZtfYv8F0T8Nyl9AiNaEXtKJdDZ2xCBrX62LJralRL/kL2WR1kVMaT7pmzrmAjSEEO0bbot9rwqDbo3zV
# DATA tM26UEPWosxss7IH6M1fOsKMzrdZsdpPPYBIorEcCvbuxl7r9ubO5r3bm/f2NT3T2pwF0K3ykulRGj3h7liNAzPFE+pdAFbJyKoX
# DATA QEzykZGa1r1WJzDlCa8L7e8mX6MAZz5t9znOmK5zQNlQ1HuoZE4lwN1g6BZ9SyZqhtSai7ocsNGEOYjkFEDVSbmSgRigCHl7kIhJ
# DATA xHvYKo0NnYBeN1ECPDZh5wcCMlmuA8w6VNPMrUYzNFBLOhimFweDsgGSxZ8tXn4+clTuly52lBu8Tvduri/xYmrASzglE/J5u9+i
# DATA DviuxKJbZbLgmN/GY8uDfDY1mgiBHN9k65dcVJ2VV89hV9SlUzGfM+tNDCVm5dj5oYNFWY07DgLXfzxYUO4WWRg8SCSLhLQHXlRW
# DATA ScSBxsOjPYShnNNRsJU1AhHmN0lNsrFuiwOHfQwEsw4GOJ/CljvtSTfYhNHuBKE0Ht210BFca2CMCxY9qsUOp5/l4+XgKrxgPYS0
# DATA jeID+rqHFfLNvcCOl8jwkd1fXsjwuLt5d1vJ7qhVuLV97+2t3bubXtSQe7jdWvV5d+9o94uyn4Q3ygfVI167mFgjCPFpOkfZ8K/a
# DATA tskZOQpjZ/wemY+R/daGcP2U03w87Ob0kYzrCzYlOmdJQzkfSkWU1ySnXIgB601fgAiTczSiTr4mwY3DtAD8hidPpYovHrfNg3Ku
# DATA QzDXGNlKYd8h0Q7wErix5Q4Xr8EgFDK5zeisg96jaDPHcpXqq6qSeHvZs+HZO7IiqJKMuKEoLz+bMSPMzBwDdgShBtCpiIDGqfk8
# DATA 5JroWS5Oups/FXPOt89fXKAVZx69enyopRzWJNKEKBVNY2uFGTfsguGqAoOXXBT7wQIJjBkaE60Ono063+eqnJPkfY5i6+IgQ4WO
# DATA 5hKAqBh8CGbSBxySiTvsrjcWEdAldhZ0OtVXv6CU9QCh3BDGemLyF8qYzrwoIssRL8iNu15TPl9utug3DF1WrNWjHmWtirDqZbcd
# DATA VjRJZD6eelMNUET+OxYaaGJ1nTJSaWH5dekaSsDWEgovby0rTKmtQnmnnWXsOKo3BOMaoMBzpH7DTKvfqM9B6IMjbRzI1DLYxF9G
# DATA nVzgn6yXJ98jZyG/jPJFF9Z3zdbA4GxzlQu94KnQyLmJdGVW3QZIQhuNretFx7HBI7tPnCuG3zjzAM8oKgaCU7LeX3WTN5Nrr79+
# DATA 5dpFvNE37/1I8ELWKRU8OXqgiO6XxulfRrASGyURGlBtvvagVvy7/Cphwxbp6wCmrXY3CPU0DpsNx2FTLpPnoOleXgTuTvtaQ5ff
# DATA ur+339q7f3Pv1u7WDhjF1NG+v7fJYwN1CFWtCMeDgbHoaSwnaSpjGKcwFQLdzBZtwkl28F/coLKAEpAmPA5wH7WAFFnD4wjU/gyH
# DATA oTDUiTh0vn2fB57vAnlZaGq96/z2I0ULYbBp1W1hHnc5HwT6Qi4qSCZ4hORIR48r/lBMNwWKNO+ny+Bu59Velsvc4gMD7g0Ljirq
# DATA HDgcPwS0u4H1mSdgtZrAEpS3vpNK+kHntdJb9Qc19W/5fL1yBX3U3P7RrbvAd7q8Q7gn05Ei5qftUQnnw6tbO6TWAMRFUW+vdKzU
# DATA QsqD29vv3Xtnd+P2Zuvmne1bPzSKAxcInrhdnnm0qSwG47uIjv8/kV7fzYQQ2m98vb9Pm2bfhqb78prrC+vIizTd3xLm+yuwJSlh
# DATA Q9ZVq6j+6J/dQEZQhBhoD/msCzGb9HbY70N7CRkZa0v/5fXAMS33i7MvvHiLwSUtFi/GvuCo/1+4Pjzk0JaXS+eprx7XsD95DIab
# DATA 9ROssvNU6YsD/l9e6X4JhWKhivxbh0KOekPNw+6X3lAXU1xfXCH+TfS0C2srQ2DyAr1b6Esdag4dRbn7rkjzzpUbjbpIWr3I53lW
# DATA ggtNeI5tQQBgfQOt+eX0xxpsnVvxssIUQpe/CMXwZWHN/6hULlAqf9eY77mETkK+H3EuVFe14AlSNuhH74pHzGaRhk/moItpKtjv
# DATA WpuFffVEyW+ubAOPhL9pTGkYSnwYBW6UI+QL1yBr9PDJWSPViAbpfMiCBXEKOCA9Foy+9KJk8oWmPpa71cWPWCDccKHUrjnS39bu
# DATA 5i0IXUfj8ebdnf2f2ACqno4LvoAS01HHGtZNx5KLwSi+HmFzrKaa2/kGfUYlKXjrGed4s3WM891iPvC72z8WldKWFHGtOkgxHjHo
# DATA 9qVh3Vn1SP36ckXzuxtboGz8b/e3HBSWi4DikWKu15+QMIQ5FBuqghojwGnpklcR1Zl6RXWAH6rSxRKRBiAiapGDKXann73oXhSu
# DATA nA67Viv352p3tDZ/vLW3v5cGR9HJj5av2uI0aVKv1Tt2hh/ucunqt2Gd6cddpolJe3x00nvUZfGV6+KExYOj7g2dw+v/b+9bn9u4
# DATA rjz3s/6KtjyuBkQABClKcuBgFIqEZY4pkktSdjwgggKBJokIBDBoQBJNcSuOk91JJZWpSe2nrdqkZndrPztO7PiReP8F6j/aex73
# DATA 2bcbIPXYbIZILAL9uM9zzz33PH7HCOt9M5j0MWI60jV2Aeey1WcH7Ah0swR1uT+CZa+9+7i+NL2LatgFfSuNomdSxCTYQnZ0tHMF
# DATA 2J4ZM+4p5rKQOm6IOu4TctDm5Tl9YnmB6Oezu14gHJ7m4JExEvrl9pF4MYfvKaW11JcYfCUlc6xo67DXakfeVIHVo/F4WJnX6IyV
# DATA m2WKcfE9DNMsl0FpRCstnJeKO1sGS5qmCma7LSSKUztwzwhLqoBLhaD5uMhJ5dD1RIipqCOBNKOmHVhVlW84aa6HCAginj8IFxbv
# DATA lMrifwuVU7h6hr7xofsCp4+tQNsumDfWLWlweEgRjadhZ9TFjC5k8yhKRc9gKJWEp+Fx62kRbG7w0EL5mBSNT4vc3/BmeOZWQMFm
# DATA 7aOo/QhLGIuxg66GKw9WUboUVIc8Ff89iEDTfJ3nXQ8GjMI82m6ErDxPZV7PlwT36edG1b+XcaaYVWJUGjy6W64s5POlNiquc3nn
# DATA CXGLQ6ZFgUKigabfQibPEY36guBtwKXEhYVFikIbjZvDaNQdgAtNuFiORZfTNlcYcZ0IuD49oh+OdvTVNnidyujWhPcATUtyniks
# DATA VjeNtwO3bXxZeklz7LXKPmSpTcicZb1xqt4QrThTb0GTAO8TJks7GnEXuADdNFe2SNPIWgtJB1RIMftyASf5RAcNe50MObGYAF2s
# DATA LArpZNjtR+EM/EDlkIaBub+5Wrv38D48fCxGrgtHtnF7WC2HOICSFYRvlytvI69bWrpZEf8ZX+cnnSESsIyC8bEaPULoB1LxRaNU
# DATA RgMlThYh9K0yD//qazQolXnW81oeqzRcsgk0SLokSRFmOXjtbBo7JjmqKOUocU5w1fevxuXGYVy2T2EFARRySSJxArNdz9/kvHi6
# DATA l7fC1OnL2QtAc6R6AZnKtEw9aKpefwblaWe6MkGey2y1plcHNbPN68yNZiA0QRtG6v9RpjmWTs30cgUtlDnZ3ugOS/lFgGFVuePU
# DATA nqwcpPAIIoiB48HxhFjkKDTkTJM4KgJT0b+oJJJ53CBmucX5grAbmbnlOJcdppbbQtXWKBKUYwdRm16zuRCFc0T/Ss32YY2KPQS6
# DATA k7J7Ks+ehnfADSAlxV5+pqx62n3wUnnycG7cyHD0X+lMjodxTsKyUIozQFIBQTQWRNFsxe1ul5FesxPduROfUZ8Lqanq5SxrhjKE
# DATA 0qvxyfUSrTJoL6NBBoqj2xa4ePmKNZmbYeV+v8AZR8HMWocyfnY75BJ1ey8VixerVSW6K5CGzG2K4WGm9AzGQMJxNMTDhCcPH0tQ
# DATA 8EioK6foU0Nnmd1dydlScgCaEytqxlzOiYZ4U/5lV6u5aMURTkCvnF21MaaWThQGEvWb7iBPbYrFthPQxsrxLaVZ+fR1cvooOmE/
# DATA Dow0sOIhvOwzf3aJtaMZbhLOIqE0TvZCDafUH9fLjewKDaaeJvgb5C69GV/GbOk91O2qxppImyefo5zEPckmOY2EMj1fJcwx5B+b
# DATA INxVjlKRlXbW7u/Wth8UAv37vYdbZt4iuk5/clRAIei1jvc7reBGs2ImYMy//sSY4rQQY4YbFwQzJF3O8spKbWen+e7y2nptFWS9
# DATA 89+ZObF1Hu1vzr99/mtOIw75qc+/gTufYRbKb+3s2udfU3JyTHz5u0Qmzfd2d7d2iuLVP0KqzuefFALxOKbRfP6pKJITbz//VSHg
# DATA 1z4RFf7aqe0rqgvydn5mJDSHH9OSfvqzcWLzvzr/k06t+fyXJfeYgp67zXfFWDUfgHPvPVAcr32wvFvDoftfotavz78NlrfWilab
# DATA oIOi3V9iznVO4fkXGAFM+fmlaA0kFMUTB3YOc9P+VKb7pE6Wb5fLoun/Q+Vu5xHH359hDtO/JBosDRO64djQ/4mvfClGBCYE08b/
# DATA UswtJ8el9n0OrZIZ43+W1jNKN0+5dCGnLrfq99jfL8TXhdvB+917qQ1TGkVfuxSJOJP/e/HlT9DOTyFBewHvYvXfAmF+JX9/xsOI
# DATA BFgJQM8VV+bZwSh62joe9tD1J9E4pFBumrKiQPv+K9UgWiVI9Q9APHbLsLIvxGh+ihV/Ih7GssS88avf8nR9+/xXmPT1a5euBY3+
# DATA H+zJr87/JIr5GkeiNRkPzFaeORaNnRPIGlcDLiMXPLpSwHkYGQKcGM9/K0rGfLTP//NsKeaT6XEzlrX4+q/B+ZdiTn6CtP0tzgRl
# DATA w/2ZoKc/4B2q+9fvYBrd829welVW5s/Fn8+hCXBX3BNE+VPwSP33k7h23HsFCV8vlP91cXFp4bad/7V8Z2Hx9lX+19fxuX79+ko0
# DATA GlN8UxSwAwAmFUXTqWFYovN99CTYllpu6URBfsbZKV6hIDpcv3jS1sw0rdHxEMTDa1Qgy5qyQDoKFez0qHQxLgQokLIWCdzv47iX
# DATA uwFyXQGRw6pkbIVU7yB2M+Orpmd936oJOQ64meBjXz3/GXMwYH/Mf1jGgQ0YmfF38KDYbUgMsuSirygP+E9gA0L29g1ul5+FLtyr
# DATA Ia6JzufqIfcEfHygL5iHazgZV6FLkOd1OIbeDCZjuEjafAUVecswKSM4JyneIDFrhpHbGSEPPGWJ0/myo5CmwOaw1R3ljgbxmGNk
# DATA 9a0CIfKbUxdXQ+VrQ54N8k1WaIq3we+j+5hc7PGsYRSZ59O2KNiAoUVx3HrVjn8AB5E2ghCJ3W5IaCD4O9zr7432yuFUO+/5b5Qw
# DATA AUTC256U2cQ2HaCABAIZiKgskon9XFDLL8T8/xyIAYS2z/EVQSXJ3KtDJ/tjMq5uoby4FNzAP1Mb/G9J2uPtlilYNR62ddl40bei
# DATA FOVQOvrKFNfEPv7PILAFD7r3VP4cyKCJXgZBPHDZEUx99E8TMD2D4yW4p01iBoKT0ICgfwQaKikCaBKhiznGb+AhJa7SyXL/BHLV
# DATA 5dVEW1fJG5z5QPj0Vvl7qO3uD8CGCN/Q7hn1Ucf59u0lNF4jo1DVyl5tilJ2dtalu3YcdDANBAKFdWOMwAE7/JjBaN8RywRO+WIi
# DATA +x9Ho4GECoZBUM/TilVZIPbDziCKKWjQXDahdDKa2hNYO+KXXnx2X7JDtn2fJKf0khFIYX8EtghU5Mi7f4C1ALRFp6TPst2iXkb5
# DATA ig/AOOAq9+wVOYsL6THDmADrnsTKtDjIS52rF5+nC8yVfa6EswVIzXR2g+Pj57BLGSMquIG48hkeKz5LyPszcMrX0grO0kCyRNwj
# DATA EgDxAZwhLfmBf9MW+bGM8XgzgHkSEz9EC2+wPxgfBds7y7hgayurO8vviA2KceePwf0G7x4POpNeFwPRDXY1nOz3um2ACUwQgbgl
# DATA 2JhFDz5+w8zMU9JQvi5uSXoatgA/nOwxcVyRZUp+qZ35jMa9UXUqyVyVv0uc7/W+AduBmIbvhOzzUxR24BQrvtGJ1iv0PP9U+jhB
# DATA plHvQOnVgtatDoX9OWNV6kSUYd7NDyDKKuFjMMnN8aAZiwf7nTiHFcrQxSpl3FhoQJSjJIxSf/AkJ2mjNBm38yX4JVpxPMxN4V0o
# DATA 730ToC7raxoFPjb7BD84//4CTsC4oQrW9fy/4DH/k+f/YqcW8OyBykF7eDJd4DIMF2myl95WLyfG8XRGYIlgFa7rMD0fQhmxAhkw
# DATA Hp4ZFuH8v9HQocj0B2xU7MheyFGU7GUIWUp9Igb4E0HD36Km4esw0XSPv53Pw854IeFjB2MGdJ0LIT63fSR2nNIwOib1f/cxZMGC
# DATA nyyg9Do6yYNpgsVSDOU3JXeStc7DbXNPGl4o+d/5/0YF0he4uX5hCXogANryrCkSumMqXv8zHm7UqKKcaMizooMSdnRoyWfU6mTY
# DATA nUfrbYPugAApBuhjseZxkIgzOH1ujQfH3TbX5Q6cKsfSpLPyfPZqRdfckK6sWTJggLCsOCUiZSiDRDg1hE166WFaiW4PnX66ER72
# DATA w+gXIJ+XGQZkNjGC6oFMA3xAF+sEdIhDWONVI3MwYvsddJ9Ww9K4FxdDz2wiBuEgLh10gPPnzErCJ/shmiUES49ax24qCrjGdqdE
# DATA x4wnDnqT+MgJsYH64pN+OyefEX3oD3JGpOQgVv6uNOkYJUrrEqKAekYXkLuhxJg6V8yjFRZNnDuOxkeDToEDiR1YGzPvJz1gRW7I
# DATA 9J7GiVCnIDYPhbdvvr3kua0TC9+5k8VjVzd2zDZXBC8QW/mXyoBgHP2Am65trCnGEaDeXdofkC3cFmcqBx7EVCWVCE+BfXk0+ocC
# DATA JjFeJdYBO33/MBfWO/24sdcP57CbhnFdzlfUwzSPgCyt/MLEO8pPJhodd8cU1po7hTvNdm8w6Rz0WmCRHXbJaBlixC3NGxmR1UOM
# DATA ok/vHrYH9Bq/paYu5VWJq0ztJBRntxHRMWcO8DQOxEAD3dnsjVGskoeMmkDyU08bGSwfozeBGFFgcfxjxD8UKDYVUqIsuFMCJc5/
# DATA A8SBNAMiP1GR2C6e/5wEeNh8WIX/ezYq/IUPdIIGi0p99hlZB+GR0AFxMTF0ZF8ZWmRmkeK/I0l/cf4nURlYgT7RRq1PccMzFoNV
# DATA P7O7y7jnW2yXSoPwt9KPB91+7iA8fXQG1tfH4AFLngQFa/glZHYJsYowoR3zGvDmNKQ2pKBCINnODIKgTwlnUzFYlkIbBwpqMYKr
# DATA LFASM1Xz3F6xMfcDfaVkIjI1ThcLgFiCpU0XX9JUtrRoNE8/EpwBHQhDdj6m1oZz+HcuRD9jpHrZETP3Gs52L9aQW/aeqwtPPC6/
# DATA zj9ujeZ73X2dX29eXJ635MK0hwxZUYLvKy5KVc/JmZpD5+pwTrw2FyZ9rO0QDQPM39V2GH0TJcekjp5de+K4+ARzVWQpc8DFiLqx
# DATA 2PyszS1OzUZg+KCYZw3TAV36ndIagdPcSOLni4WApdu52h0S1uDkrfZxVKzLJOQKRgywNrjA6bzGIVrBddCN4M9wTvwpMrs/W8yO
# DATA 20RiATU2GbupNdr4RKZG+wKLSfFAtOj+EY+oXwXLKw90uvQYDcliMxtGbXFAhOzAqDN5GrV3ECn+nyYDcE/DjOoddFVrj0k3Ex9F
# DATA vZ68T/oTIQi2hrSLYUd0/NHeHtDQnviERlTSdbp43bz2Flx76y2JLqTpgzI+cIP5b5ifl7QwF8oAHTvrWFh/2O+Ohayxargab0e2
# DATA IW13fcc8I+/1lw+ELFPlaIriAETEiB2kAg5F5Nr2+h+2YLfwPou8yWoM+7yL9uyCM68QkuKjgXju4YNW/KhaFtLdXl+NfvW6YHQ0
# DATA pnPh9T1QEvFGdXtp6RIDhItnpuGRA2MMilhXYtBaPehTfRdKEm9t9ldaQg7vtEbVG0Xxv6B8s7Bwq1IuV4BPWV3fFoQl9s2Po85q
# DATA 1Gud7ETt6s3b8NQWKOUhp/K4OhZ7LJa/RpbNBo1u1Ll3UsXGx2pgnbHw+J5fyu18Jo9zGadN3uRDVOmZcoYKIkaHaMAOIPXe+EjF
# DATA QY2kJGu4GtYN32pTKy1+st7QckWkXR2dySl9iuW3HTPWlgrLgK/YaRNAeph0y55T1rjkTSnTcmBSVaKgJZ+0OP9khIPivgVKq6Hf
# DATA 19vxJlQDbnihutquVklal1slS9/VKqHGq2VHSUKbTBfGhLfp8MTyeZWquunVmJ7GF6vTICGjauME2ipJYVCUzKfQVskUof0FO6Ff
# DATA JGiaPWFR0yz/0t0g8q5Y2e5g3NSmLb7STujz82Q0NgOFkjxUS4RLljwrppAMrztbEn0zeD+KhmiplNgggdyK8cQNiTL77d4EE9SD
# DATA Z8b+YBzGQQ8ifflAEpeSqUfr4bgno7R4WVaMwbRWM0VTcadMY3hJCwV5XvLWs7AuzWfsHFS0EfAwWShufmUTCbpGZsNxL/YkSWX5
# DATA BfyUCAzJ6AnKLtZdaLMPP8Urs5B54bvnP6fj4/N/JccMPGCicR4OmGJndnD1yYtYVFm3GtPIv2PegpY0ZvACvpRzLmzdCT9dSzFy
# DATA Kd9dsL7/mMAAMCsaq8hIJINU7104rhj8QOfxkdH9UdAbHJYcj+vw/LeGY4sY0Yo4QBm+ggh3pRN6RW62WdbthqZLDDsBoovN2sZa
# DATA QTtUiP+zuR1C4qAjVSM/Sboj48K/I7c/7f528KR5OGmNOq/QCzDb/29h8dbtRdv/b6F8c6F85f/3mvz/diOwbbdG3R4EU8dgaIFk
# DATA XIzx8fDdD4UUiynqeDsqkP6926dMbmCJGFHWxpMsF8CDdn/cu4C/X3w0GXfVCxTucDEPQP4NuCBSwYUOOxSgM8Vvjtz+/N5xYvN3
# DATA HOWWbmV7XUT9x9XTGzcGcYkD08T+ur7SXF5HN/QVQ+E71c9umzwajX0MfMT+SFbN55/AaVtHFXwlbW4Y4iD+/Re4KF4R0/pO4OGn
# DATA B0LoegIYMOefg48M+uh/+vzX4VQfPjFmTWM7lNDdEt7rqItmSmOQt9B2YyHX2FCZbL2GN0tPWoJBy8G+tVSeBayO3hyDsroPLcpn
# DATA pHhPVrJQTiRCNxq/S0/Vng5tJChd2KNur+eCtOlassxptiGNTplawSTtOKna6SR9ZOunwRSL1tefog4dyOFbFXQjyERbuF/Akie2
# DATA Ga8lD4xqZP42y8cez2bt+9sy9o2i/cFg3JTsNCeGrcAqsvZYHI/EIhMSzQBy6lZZ5ZJQ/RZhrGUJIAFN+t1xNVVBk3gRsRe1KktT
# DATA HtX7UmjvG8sPY0YK5Ppncq84bo0eoWadXiJYBQpYD1nzuItIVGK4i+jg9ePBvljgotOAezUcPBEv9QZxDMPX6z6KpKJSnMXGo1Y/
# DATA 7sK2hwdLV/MoRvHF1Y7MCWDqCmkqMpwoXITO7i2aIUZN6hChPUpVaCXCBTT6TpdSnY2PauhHgThLIJnTCOYpV8ReP1VvaJdoag4B
# DATA sIlHRRRyPeBEdGIvbO33IkPLuDWIx9X5STya3+/250fHQfEgSDTDqiZNRYeQK8UJHIAMNZ2hrUSPeGNBhZSXVJA9HPWlSizxFDU5
# DATA pLVUwuSh1jxRKwF3HYUmWav05+GtjGI0K0ycU1gBCuVRR26QhYBiTkXTOAwhEsMnzuH868lRt31UJZmphD8KUiozU3SI1wm1C07O
# DATA LA3xVoqlBVX1DQDO7D2dMDgPnoiHsIZcKH7YZgZxIbGDc4H2Vs8OzVUaa+RzEq2ikfTHwxsldOWLYTsgJP9JDMk6acgtC0VGvdzO
# DATA jBI95fl427/5RCp2fPoOBasv0JGPONl370jp2Qhxgx34F3Cbx1DaQtTw8oWiGCPrEUGU7kPikj0TsjDWkKinpnSLowYdri0dpT/H
# DATA bpFoqS6C46YbrEtjoRw/kh3pdOPW6LgJ/Bc8KJhUkejsPTDv2wQZDlYsxgA1bZ6tz4sLyKx/WfAYWb7M+gKyBejcQIUhheBSsByA
# DATA HCc4mEQgHAGiIaVU77cBf5gd8A2W0XHhJNuDXo8RT4pF3I2xbcTbi0XBfojmqoi5phmduIc7DODyDwX1nFSX2+3JqNVG28UCaMto
# DATA 4egUn5JTNfJe7Hm50owXYCKMN6atn4RsY2g0sbHi3HcsxuvJUdS38kaDf7mhufQ3xm69aVLN4BIzruI0ktfLFt3C2Qv5J2LxfgUh
# DATA pZ/btH3+xTsB+SehT/PX0gKbKsIgP+Ab8uJ3UASYScEpGj0gLaBHtTJyeXu8zC2J8XtwDQAElLLpvHIQpBnRgLzvMi2FcIYQB+yq
# DATA atF2DSBkV2vbM6HxcDHUpbjEP+sLlYYC6pHXKgsNULsCgnXYID2ied9kmbJUZpkULMbFlBuO2Xya6Kud3j47/z06uAMVJS3j3ygt
# DATA fz7hxhfOi2l3BHTwISj1Bu1HiXMZOMIjAkWfT5Di12ZzZbu2vBs8ox/bqx9uy+8bm+9urq9vfmhJKoSMLcTG0WQISCYSXuJgBKcX
# DATA x7EVcagd7Iq1jV0TuiIbyiIJZyEhtvUbzbX7G67S9v3oZH8gxKM12dJcPhtR40Kt8gNsGKPChu/px1KYJmPMQAEmTpviYg7+KfAV
# DATA yGbUrP0wQzOdkAU1ntSLWxgSg1lJb0iohBgUcMR/GM76Tjr/+w4RBp7/HCNuiFf6tVGhbfYwl5Nh+LiYPSPR/mkmB7NWZXQwbRcY
# DATA zPsLVKv9MlWH5umglCjCvzYbAyWBKLYOwRXxFZkAMvX/C+Vbt5duuvr/O+Wr+P/X8nnzDXXwhrSew5Px0aB/89r169fXOR8qZNkg
# DATA KpFOaiVYJ5w/lXKjIno4onkBZvhoMDk8QolQSc0zGwaOWjEYBNTP41abLAUApoJ6DNhy6CbofQHtZBtiguPxe4I19l4GvIAQIdV3
# DATA cLUaU7XpxgfgGZa1ASubjHqirtKIWifr5MYW4DZsHNdUA4j3GLVohwcE//TeYTzha5TyEw3qbK9voqu/kOQM/PFrK+trcGLCOceE
# DATA t6RykRJGeG1lc2NXCGK17SZ8295cx8dtMQSUqaNBL7y2U9v+YG2lZp/BGGMMKUapEa893FjbbW5vbu5q2cbnLHZt6+E2wONDJr+U
# DATA MouPF0TNu8v3azsYIoVaDM6c0Bk86aMiByOlKEsb40JyInTOjXfCL4AzR7cvppJRJLsH8k5bkHNfvJC/9mD5h831zfvNex/tYpVG
# DATA 2LxS21J6ltHgUIx1zJknRnKmBUEBBB4iRReC6LEOj4FUxBA+GR8F+2BiE+tIjMOQnokLjJwv5VIpRsd4TG49CZgMZSS4zEQsKa4K
# DATA Ss1mF1Km4QVWRtGR2wavtxIRoocLLB8FScszPs9qEzvptOHCIepbg5zOb1RVI6T+QT+UprAxyjuMZCA0TzSkBoYx0QkzOD8NzToB
# DATA NcMRE1JKuwLAQ6SbZOaM+9u1nR1b7HY6TPkH5LyiSkH2y0la1x+AWgwjQOGfnOf8LYuxRlhbDVjyAWjhjcH4XSAHJ5rMKOA0xFFC
# DATA /xxCrce/qE6NOssAoitaBCdqpCSAKkYUYoZyiQ2sZiMLtKygzqU3FHoBvCSYhVhSEaZ4AB4kCDWW2pDjwWPKiQ06FTAfal8oWHhP
# DATA hHwZK6QCmtMSGJCf5rAmiKC1rspG5ZO9rxu9aNTlgw3Ml/w0Vy7gVBTdvuiRaeQTRZaIs1Bbqjyi9mtVUSq9iMuYkkmLUYAQhb2n
# DATA 5XJx7+nCwd7TOwfiy/cOGpyOCJ/NizPoIudw1q3iiYF25zxX54L6adjS84glAU41MRF6UPzGv2eNfL24uFRx6+AMX9BpUY0o6Jov
# DATA KxbmC+N3fD6tVIrL3ci/q+IwnCQvsB3j8bmEptafK9G7XqYvUIfnGQvVPmGoM4XpYSW9qfLpbfSvdCRbcd2hYmc9Ke3FsBdxtJUe
# DATA sOER4haz9yc/EvIAwy5PGW5VQ2zWm+SqCSs3wHmDb3gmi+dNVnRNVBe7WRlRRyCXH2zSXKS1KF3/PYDaJKYuOLd+G0/r8jKNWx3H
# DATA rdLwpkDTQ4DuKDle7vHkOKcKrWOBjcyyBXPITeUR+WQaP3TOUI2oBuWK1+XDnSvOstNDkyJYXpTPXKcbD3utk6CFEXUtAD8PrpcD
# DATA Bhu4XnL9D7JJ1vAKTKSJFKKqQcp680gQqNxI1mCsICcKkvVcsCBvrIihB74DKexpXH0Q+Ui6O2OErLee5aRQTP54wMYq3JQp0ahN
# DATA /G2hXPa8QwRAjbuBz8ybtbhNio1t0Vgy+jLh20tmWfGzUKfQqNcaxpBDAGdLvGRRZc6o50CQQ3xEFZE89ASI0NsS3L7yiR5ARPgx
# DATA NGRbUpdRr7xkbvfJLeVMsPN2T5CCJQ8ZTpZSWSyIhRi/RPjoDQ6Z6bOnA++5kI8Q0oB4st1JroKw88l8a7NGV6710fFeIXiJ4nQp
# DATA MyQ6ulhqI5YBzXwOKvz+oONXr364vbmx/pHUqVrK1toPV9Yzla0JhAIligGfTGagq7iMVT0PQbnQ+ERWd3eq9OSVCK5Ihl2qy1by
# DATA PvL71XcoeNwDOCCfsZJTpqEiiBFp9yA96EHH9YMyuJRWrR50OK4/SZdNpO4cHYD4bAVxHmMdBMqHI5J2cmEdZATKWTUeHeAOHr71
# DATA UfGt4+Jbnd233qu89aDy1s4/huTaVzo8pj0exYgGeiXQOQTS0cAvqoq8JEIVURtOxgfFtyEaFXoeV0N285AyCLdJeh4lu8VoTExp
# DATA kbE+baKZiSqXt7ZqG6suKaY6WKnhBo0qtbTiOsCnjH/IsM5kG2JVa0kppyFRjfLsoJv5WUsWJ3DOYo5HpmwKM5gY5XSS6FYJViaX
# DATA ReoQ4+CkckJmgK93pHiBwC2LzzK/yh4aU5ylEZJKE6N36O6mLT4vibNb53DQqDzcWP5ADMPyvfVamMqCZVuSUzPN9LW9aq4CSff6
# DATA 98Y9ML3M5mg4krAiGPRkz/Kx4AEMgYR+g4CZQc95/AYdJ5TSTnNtZ7t2PycLkVgbqVEsM4yiPgFM+m3OvW6Wz1AflmLLNspR6+Mo
# DATA eiQFmsT7Rft9p4ugnqrKcuC0kbOf9tBoqgEnu8cUDIwvKgwH2W+zJGiP+BeMyWN0esvtI8+uL9KBRT1Rr8BjIyG1dfgREIDpIXD9
# DATA 5nIYPCyd1We0Jup3+CQDgwyZHHOjsAgfYNSAaBA0bjDQe/B+7SO8FZLnuR7n/eiw2++nFHSvdn9tY+aiAL2A2gRbPgJ66NJB+YY3
# DATA ydNCyAXf13flNYdeeaDC+nZtdXllt7YaGG1o4B4snqhzuYDtlGf1hTj+CB4Va0wra83zXQkIlTzHWgYtOr3WKQ2FPH5fVAGgjk9m
# DATA XtNqcCprpKx4BcUZOeeh/OnJZcViDqX5MniqvCQP/aBVhqowOZm8WTrsDfZz4Q2p1KhXbi+BvggfUk95a46FhJJ4++aihg6T6c77
# DATA svIMbQKCuNiqBE+Sc9vMiu/QkccQ43Fb9/A7Y7zBjYTMGlhE3Xi9kc+/9IPygZW12pDGu1HWkHg3JF8y0kttTy+yRaXtOqn7VcY2
# DATA xPgc425/El3zBLoY6WHT+f+M7NM8HRFaKtJmCZgznIsEt/vRXnwjd7cSPQXj2F48l7+bY0iYZsNAj2ncyIsHq/Bw6Ub+7+yMsGCs
# DATA KT3IV/w6H81Zifs8Azp5Ikj9GfKVZyzlPdOBkc8AY+nuo+jkGWyZoCSDmOVncas3ftaJEToAOlNfaGDNaymjLJcYPbzYMDzeMP3t
# DATA 3vW9MMx7XxUNB4UIlpAP/r4aLFVSA5QcnkrvuGsqIUgmFgwVgygiA9Bm5E6p/Yj+hN/gFnN3D18gNoAbkNP0M8SMrPYg8zUjvdCJ
# DATA 3liLtN/AH+VTT3UVjE2oIWNQeBuXKvzc3e5xPteajI/EEv8YVYmCUOqVaoOIa18QQDR6Jiay284Dje3tACbNKNxbMMo2N1W3hpDr
# DATA EIXVrwuedXdv3yJOcX2ntrJd2322tbyz8+Hm9uozTKHyjLfN5l2xbz4TD6zWNnbXltefLW+t0bXlh7vvbW6v/ePy7trmRt4tlCtT
# DATA ncnXf7Q32us35sLwYh2YLlTU9+K9ncaNu6LWaaLMs7/Lh4VU4SCrGXv70ck/GJ00IaDSfu+HNg1klZ8DWB7xeoP/ijLmSsXGjcr8
# DATA PAxdPP+DSmOuQt8acz9IjOEPslv/dGF/r14vF+82btSD4rz49wfF/yStRYn3JKRX+6g1arUhwBqBedQvsZ7wSVCQmhchPmIcgtwm
# DATA mJR+GxfTzcWAfBytG29Ug4XFO1kiqxLoVvm4iHsAoDlR1HcrHhOSeynYPYqUwtZS3ZGmEjxHCKsd3SpKAMPH8qCtpZYnP3EUll8p
# DATA e+aYdMPwBkCOyMbCJfn9jA+3kJFebGXKEaXJfio5bYHfJiN4cDwZg/dxsI6vIAZ9AdrZF+xojA0G7wlyEhA/W2MCng/GrUPD9D4c
# DATA xF0+KutoTxJ5MK35CqRx2q5tbe6s7W5uf0S5Ocfj41Z/XqHeFFVzXftZKjaaoPN55zfQpmrObEbx7dp6bXmnpqI9pVmPnVZyWvEU
# DATA yuRGYqcrHQqpZLIPLrXzWOP8qa74bF56Bs3TXNxVbh1NdN2onrpe+meGEzzhlMXV03C5DfsQqEXAgQMCUgAf9XG/w9XPoURbgNTI
# DATA otziChsIKyCQF9twLfTE6IYPBRUWlw858ayeAvMcIfOqG46f7L2TU04eRsoMEMJGUTwc9OMocQLl6yQTLd66zZ4kcMRUcw3bn3gc
# DATA rOL6iUtNII68jWYCBZtEZWzD/HwBUS8vQzFiKWAfsRhG9WgdolJLU3LOqVU8wVs/+4o4ZP54ryN4uvwH+GTr0InWHNl1dkatA7C1
# DATA dGMsDzMjJh4aih1d5oq1nrxMxzmvA/QFvNCtsC++xgxJPkniTSVlJkyByD8q1qCILRf/5u+K4TFLntKJD2rbO0JqUMq3EZ67xxPB
# DATA unPHrSEgqnJ5EvQcsmNplKT+SQ5eAjpdWLqz9PbN20t3yJIBV8VOhEVepi08dtSkuSBXLuTFOsgtBUVcHVSuDpu13GkqmRYb/7HL
# DATA 69ONmvBRCqAwa/w4QBiXM2Dn3rJWMeJKS1TdmYZhZxeS+zFVsfxvrF4Lkd9PNLMvXrMuHnAsg4eVPSkuRKmglEZ+/vDh2iq/iuIF
# DATA fp1xZf3Hh7Wd3fR2xeLS0HRDacqIeUpbTr84R6mCAq5M8X5jBwiPE9g1A3db/LZNZKLPWbqn2RXiDzd2lt+tNbeWd98LrRbNZteU
# DATA DyesmkmvPj1mipL0YBnQrHQNtccuGpZ+Ph0QyyASVVQB1VSuJdOoSH2vlxuO0o+CRdEsZ2Z3Vm/kia8vb2016SiFYrUP4ws8nasB
# DATA 9YThs0x9klLUWH0zQihAD2GrXH+ka63CEeIAED5Pby+dSU0DaxiSXZKKAITJpTxABoAssxF6GvSuNxcziejB2s7O2sZ9OQC8K4OW
# DATA AjBfj1vtUj96wsUp+N9CwF63Bel+XYqPWkLyQGms0z0E0S/v8R1Lp/uCEN9J6Vqh6s8cFG9ZENBUzly4yVTyPEOG1BebCILsYqyQ
# DATA wesScBDcAzFUW88cOK8g6hg7sgtOwpiAufDxoDc5jsARuG65CCrvyDq+Tqoo/AbJm6jE7oFXuZIzlgA+ycyZ8jjBBSkjIWgiun4l
# DATA HLCBxcxaulKgJN24ZWPlRl4J80IqWWzkG4amRy1DMXsnQzh4hfvdvgnxSIBwzGzyGvCxkqyS3aubECcg7gOrOrvm814wvQxgq6jL
# DATA hjR80ZsWvXNVzQebDzd2oeJ319dWdj3J0Lh4x3CHsyf1XrJWH6XbW4tEBDYqkEOCenfTS1rlp0jLf53yIqwg9umrkFwKPu3oIihm
# DATA pdtBOAJ2sqygOfeieZ946j4ggVQWEoSoieWfZ0nAVwDcjTpN3kiNHObSHp1PRbXggO3cFMxXUBKIIz4QNuT/DXLEX1BvIN06JbqF
# DATA i4XrAFIkAW/jLigmTIxbFQDDwS9B8R6a3o2uUXSFr1/oCEIRsfiSOTpwC3UciUYBeAdUPegX2TNhr8/XEJbWhuOdHevCR7o68mI+
# DATA 4ICNAgefu1ObSB2psQWSUBkFwo8wRJDs1xWGRlgs9gdPxBduzYVLGtFIpZYgDwUIkCIkWNDJj09YYDQkF0MDBAC4gHnWA451ovKe
# DATA Cl6Im9o7ku4gprPVCcaAHUPbatQSWzYOt9IBpYqYKvFA+saZkYbAEjWlbPpCAqbE1qS6PIxKx2Vo6dEEe80UzOQ1HnGxD0Sm3Jgl
# DATA rnHDbi4G36/aAlA1WCp/77bCLD/SNgXWjRKO8d4IIXZQHwTu+WEj/1ckN8mUDUkZSflookaqomKym82uWLHNpmhC74Bsy2bEsrhY
# DATA Sic79Yg+4ug3zHOOqg5FLqwr6QhvnCPMMt19zyis9TjididUE9awZJXH7zrxCTpknfSlnWSb0aBddVvtWtw5R7vj7d6VoV0MPQtC
# DATA AHhpU4QTG/4DZTenpwRrla3xw09YhLexudtc2xAH8XXwBtNVSzURlVwP+bcHpiPxhB4WcOhigpFqSnADMM/D0+PFFO4cONP7Mk7J
# DATA AyYOLFFOwgcgM0bsJXg6SftAIKdF6m/dkC0xJGEGKHFSvzHkYKAURVyoDnuLS5B+BB6fzXXLr+5wBzV1teVCqAr7h1Pjhrn4B5+H
# DATA 4lVPgNOw7FlgOrbcENUiNXwRNV2jL0tyqWsgTydyttTDxBFGsXnL7xoS4pBjARThODK5Th7wAbC42eYGiq4LcR1DuvwzxLMkyrTj
# DATA gDDMUYzZJMIDmAx4pAOeEX8UFPW7ZiBBGRSPdxbLKXEq8A7HvWGNVRk/yb4YVUGhu7Xt7YdbuxZnUk3GnolSCHZcSFAV1Q5ACjcT
# DATA C5iEJ7piJjXg7qpzB9rDDkE1EzoA49MDJP1NUwFTlnFxyMEpNOdnxnaVDK9mJto+avWT3BN1xkgAiOxBJgRQGLfahInj5TDyJupM
# DATA DcaZFsyVJddtrYKDwL2HOx8l/D9PfIFU5D2c7GYJEC+PhPjW/TgyVyD1O++bDF8pq/gnzaUzvSOGqzP5dJKPsrnom+RsSNNBnFnR
# DATA ktrkLrqz6VBVFVwszxcSZck4cgiZ/XDU6kQz7O3pHB4ZjpdTia6hEsIcf+qokCgGT5qdboy4ZRbUUqIjEEIo24nsAiok0jpu9UVx
# DATA HbJ5IbFO7cfW8v1a88Ha/W10McHurG1bPCF1DcDPlBVAt14p/bM3+cw75/TFY6gDfTHcKfE5yb23mrH3el/WLBM3bvUz3avrwiKH
# DATA wyBk/dM7dokNyy7A2bW+n7FrXWj+Z98xlCObK3/RRgEBdRRmr+ehYrIeY3IrWtjW+jo9KmYsojEmrt7NXpOeiG0nv0YqxaaoUgiL
# DATA MROpkHVqRYR5AzBAA8DQhOY4tKRsvxZSvKdADLVqiwpUNxh96UHrKSjBgAbgAVc9hy/dA+UPKuVS62OQOthVtNhXYOkUMmVFI64f
# DATA LnQ7oWS04hKIDmo/sbRLlqOHj9hyl8SqsghvimAmjovbu00VQcTyUjUZ6nTN7+6pdpYZRXXPg6OwyCefYuP05u2zPX7QF9V1ARJO
# DATA WeJWh51AExkMBQC1trAAk2zJCpcUEF76ifBCrPnSm5izKecrUw6YyW1slrMjGf0TIAagH2GmlyaCWpfBPdBRS8mYttyMVJp3C2y2
# DATA RxFHP6FEMp1ZUnQeIqHogD9jvUBuG3ZDnG1BJKnbbhewFD8LqKtjUINRncTvvEcgSY0wxEUj127VHD69cym4b2MKDVEj7z/2vWTR
# DATA VY2+ll/lGOi2NHxyyEuReF9I8n3p54gXEt98m4cSw16EJ5NjlCfCVaWNJ8DW+sr6mu5bMv0q7bhSVYm4NuATGjYyZhP9Ibhgmsu0
# DATA cnFNmsoF9b3h3wkd2egGJX3xywQn4FAAA9Tp9qvGm6u1DzYerq/jHZAL5PqjfFPqp0+EuLNQLvtl8IxlvbL5YGu9tos7v720Z6MH
# DATA DS0j5QmdKf2CcVSXk3C6ByYT9JMTB8gTTMD0IZLh8uK7FEEuJVjhet/cqvF69woczJkMUI+GBw9ohjVmWVsmCX1mplrdj/3jOWil
# DATA gIygbvB22U1cg/kAmqTd5H6Sut5eP0ng9YTOncUpuxB7aFqY1LA6xdjbjRkd3T6sQBMaeiXdyhsZkxCcx6t0gxqTBAf4PB0hBgV0
# DATA KtAAPb2oJVoIcGb7o8GTGJITs9YCoGeAAsZR76Tk55Zp6pDUA3/6zZmsLOmCm0UeHkuMGC5j6iuZbiTWKmLYevZOmUGLDNp8uWyq
# DATA BqHms+vELqMV0d6dknmcJqMRRx7CO9oseMEQ0XxasV5d8o0bnPMybD0WnUc3h4p6iV3L2blGNUm73fCDyYOswjUTD7kgbIaMRYNy
# DATA Zpr92vLcA8mm3FA5MjCvJ6iN7MyYyLHZzHX7/cgXlIvXMU6U4Q7IVVo6Wrs2XMYBRcDyQhKE3ALMcUFyYEDnPHKLV3R3EbZ1Ox2c
# DATA bVFbDjGlYGxIuDDub9zLZ2rFvAK7zEMGFQtRa20zRctkj1/m7mYNs0V1nkYlTzc8l0/RZwDLKgQ3mv4AV13VhVvM9a/j+dLa0JSW
# DATA Xvo6JM/edKeJrvwF4ySuYynQ0aSQejS/vNY5Re0yjb36DdnTdLmWhuKF9JmXtLRnNTC1cdPQBS/VAeXYRLMO7jxytl2GPVtV4D6x
# DATA Ufuwtu1U9Gaw2Y8Upi4KGj8eiI62esCP48nBQbfdRccuiOuTMYoQogVaBxiVljjAHXVjBLVJhKKbQF0mx2N0BYVHKWEWKrPzMCZ2
# DATA C6arDi5QBsplvlLEK1x6IzUE/MWRvbIRvmY8M6SUm6F0V56vdGDyKdKl66vWtrv+rMx6/H26lCI+VRJ5Per3NFV3QiXvd4AppKrh
# DATA p+rsX49q3tTK/7Wo4GeScV+mQn6K8xIEnFsPXUgNn0nAL0v5bujdL6Nxd/XWaTv6C/udzYRNnqGz7vYPBj7NPIeVZsGF60gkQgCa
# DATA uYz46IJ6brhvmhB82vUpJJd/KYpzbAVrz6eT8EtWnDf9NnpDrUlUdliZUR2HmiatYuchizrEfFmtjq2xdyV0AwPSrxoj7d+/KUrN
# DATA zRptgAhsbu5yPI7FRfUTLIj9w+Y9a580cQgwiLm5tvHuZvNdscC5PKDsfGo8iaeA2sbu9kdmCUjYjgOXM020p8Mk6RwO1y50/rfX
# DATA p52DwSA+3XMzV8T573TiHsrt8/nzX2Jerk/gp+XBkHIukikBqxkwEzMpnkm5LQQAaF9RhqU7unJVeAMjCqsQVThLyM9UjTXSMqur
# DATA 8btvr/1emqpagwxoUyLST8rT6Jne0TABdeIFaoH4kZCUOzS97i8czHOkaD24/oFMTKOn6VR9PatwYptTWeCZCvEQr/A9/wI+2+tf
# DATA VyEA6e3wZZU2NqZEh4Lv66OQt978hVx95MKEA9J2bXn1o/AiTbnQsewSxzPLwZ6pQE2OZpVvVPXsXdLRyQRp8NSObCoRZQNCgboz
# DATA 7WR06erfDO6RVhnqoxS7iIt/3DqB4xZmXGoF/Qhw44eUJUbnWSpdm6qdVfTMA1r105VU0cinJBkoYReLS2eDr4g7/0YzYyvHGmSV
# DATA q0CuTsgz98X5t89/FdBOKltN6WBm47v6BLPfEpJVwdi6DCumBHj0c2PTOPi62HIqPbvLFZaQf9ovRNCMzdF8sLbzYHl35b3wRWaZ
# DATA EyvBJP/2/PfJbKl/wkypkE7vnymFYDhlUqce12YxeU4T9Ryza7aQ5y86VedD9XqynSSdfrJTEeWnFu9mz3HyPxhpdFyHzenpdLL9
# DATA C/yWATvRCITEmTmKvK0+SxGXL2HYydRGvVIj+JuIksZHD8KQgSDCADXsnWD/hGJMh4Nuf1wKtsQgQCBxsIWKlvl+NIZDtqdUVjZA
# DATA dOqggOcbUUfQHgwhr5lSdHa6rcP+IB5326DCHA9of2nLtOiXMtmn2OObJoT97GpQYzlMNX1dmhclyJ98m7lmwuHQm9JM4fUpPO0v
# DATA qYxNJi279jLpOUHLqLimScEA/J2PdnZrD5pbyyvvQ8YU6dkkDoJbD3fDrJ5686Yaa2AFd54texn0O0QAjpH+zq2smnD8p2VsNbYp
# DATA mbCVT71ehdWl1Hs8cG7Am5MI/XL+ITNJUHCckor3424sBuHQBv9JqJRSn1Y5YPrdpzuIv5gzc1yWdo8oJeLhg+7TtX7BSoBZwpeQ
# DATA V9GrMj0AAgM0x/hqbCpnQBsI1h5eca6Li9gN+hQNXghanQ6v93gyFK3CSBD1Yt7zDqC38Ok0dythk/SUreCjRNtzGHPPbaEh4fyh
# DATA OX9a0byZd4DY4bEoUxTDqs6EedVahIRIMOydyFgysQQKiCHmvLU/6JzYuBr4kDpxeuwRUb/TlLiCOXgq7SECU8yFKwShWQRADJkR
# DATA UwIqepSUngIsiMUCQiwi2kI4a9XrUf9wLCVuMGZBv11/U3xdvx37ev8EDdMkYmAZ1pAf4eSl0Z8ZGJ9NVCYcgBbPCLdhFuR5nyka
# DATA YQVANG2NoiajBWBruLeMj2CCEhNEgvjnHgIS48kHa8inW3Zx30PKWyrfBAFLmrfCdze3762trtY2wrMZVLzydCGzkYKP5v3aLnnb
# DATA 4h1SM0O+WJIjwmx7uG7YImCa0bixL5w/RHaG+ikdQQyCTy6cByU3hfbPp/rZZrVGabGhaLLCOmU2Xm5LD6PUhkp0xpT20JsNCe80
# DATA n40LTviJcDpcfHURZOljitUj+jl9K19+GIngOJr34q2hUPIXrN1yR6Yo2EvRvifyeMaWbW3uvGjTesiRFYUZTKgJCRyTnLveyCQx
# DATA Lo+wpVWYp8XbdketfnwQjYo12NwoVpDVb/y2oIxSNxbMsTvWqrly8H04teT0M6iytEFyXxoxM86ngYBIs4f7DsJ+Om3JZ7pjGCIs
# DATA lCwR4XB8xowX+ga4QCDeCcbFMy7ZdvS4i+qFs9e9ZH2EiS19QeLExTffalM85d8mVS7euv03RJQwYx4MBx0a9ipoU3Nqjv+HBtVl
# DATA WxokRluxQvKSbldjdrJfvNTekErkJBZekff/D+Rtq3FfE2GbNJ2wzbwMOk6Xqa3DwZJ1OADT3bubDzdW3cPBK1WLWg36HnnwKAUQ
# DATA LCfTt5T0PUtin8pSI+k+XUKX5M6jMRadQVPIgwAPZ50xzfvAE/wPkFpFOubQNCW95uEphQhovKKg+pCEjet+LEDnZZ+1072PP3PT
# DATA w5YZU3Bnc+X9mknlZnmWxyh63JjKp7FUQJGLTkGqYQhzHR+qeIuVQNe3TccEVlThn+bBAJMFYYLVLvjDc3JNoKNmE6SYZjOUWY9H
# DATA MTpyiPWH30vLo8MJwBhu4R2VaQsspE0hA7WbzbzxJuQna7b4lZx2cUTnzS3UgDPQMP4S57PBcDyvXDal5cZbmLnTto8GgGxcJZBj
# DATA FA+106SDbIAw6TLoVAxFUSJh4rMytKSR2Q0ZB5n5ECnP8++k3e+19qNexn00s2VXAd6g6QWg2jTjPqP3ZjzBuJTcCA5m5WfxDzwt
# DATA 9U8QqoqbaTTpso217KJL7qCbb+0pnMW3J5TvhtxKaG0r2GrIFQK0opMqiIpKdiisjgO6lmbewLfIvIFfxYDxN5wd/o4zwd9x1CU6
# DATA ur9eoiATZxKA992qOPgJv/NI8y8e1exKEtRpQbrZEK5u1TNVwCtCF4vYmrqsfAkdVuWwZRdmrrGMEjX+BF7En92OnhsfKj3ppd2i
# DATA 8tf+w9Xn6nP1ufpcfa4+V5+rz9Xn6nP1ufpcfa4+V5+rz9Xn6nP1ufpcfa4+V5+rz9Xn6nP1ufpcfa4+V5+rz9Xn6nP1ufpcfa4+
# DATA V5+rj/n5v8P/fjcA2A4A
# END_REMNACUST_HELPERS_V1
REMNACUST_INSTALLER_PAYLOAD_V1
if [[ $EUID == 0 ]]; then
    bash "$directory/installer.sh" "$@"
else
    sudo bash "$directory/installer.sh" "$@"
fi
