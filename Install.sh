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
HELPER_BUNDLE_SHA256='e31d25e37863a82221d4fafd1db7fe784dedfc4e24d974cd0e3543d0c38ea17b'
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
# DATA oGyDPNmSjrex7W8MG91uc9gJm2G9vtXqxPVWr99oxK243YziYTMI+nEctLeGvVG/0xrVG0Gw1egMW81OJ97qRd3eBuY/bpDTeENd
# DATA 1LMh9ylumJt7NqiaIvzQam31tlTO5IaBow3D9kYRUEMwjIJ6GI26rWgY1/u9oDtqNuCtftjptPqdaFTvtXvDVtyrx41uPAxa3VEQ
# DATA dTbU7TfUr77qtAiEXr9VAEA3jhtBKwjicBjBdIdbQbTVi6Nht9nsh41uZ9iIonbQaHQbjQaWsgqiZrsVtEdhPexuRVuRC4B9114R
# DATA DFudXqcAiLg37LXbQRNG2eoN+/GoE3S7YT9oxq12CBOO2s1OazgajqIg3Opv1aOgH261+v2gPWy1G/1hDoiCgl9FwDR6sAeLUBJt
# DATA deqNGOhjBIvS6rWH3agbd1uddqs9wkuWonowqgONxK1+AxDRHAGu4qjRaLV68SgMXWiY/QyGdMXmOkganULq6LeAMvr1VjuOus2g
# DATA 0xn26u1oq9ECNDW7QSNsbrVGvWZ3a9jtBhFQMWCm3ey2o36v1+iHUcuFhO65G4gQXgNJu9ctRMnWsN9oRnixVNiB/RH1AaThVtTt
# DATA d3qtYSeq15u9oDcM691+E1Zxq9MJ+80AGsWtTtiLwgJAsjUQ9LuFJBKFcT0cNvudUTgKwtZW0AnrW12ghd7WsF7vdYewe4ejsNNt
# DATA AjDBVn0LSDWs93rDYa/X74S5jQKqMoBAx0WLoYClbPQKwOj14yFwBACl0RgOo3ajGTaiLuzSoNtrhXG7Ux+2m0EMaALy7Gz1umG9
# DATA 1az3h/1m3I360QoY858Ng+k6qmg32s0CGGAdRq3hcBh0O9B9vT+K+6Nmu9cchY36qN0ebXXCGFaj3uv3R6PRsB/0m/3eVnur1Y3b
# DATA 9Wa36cJAt++NQMu5ATt6HSQd4JIFkABRxMNev90AvgQUEg2bYdjqdZqdNmyJrS3gl7BlYGM0u2HYaPTjfguAbva7re7WaAjstACS
# DATA DKyu9WtSuF+HMOmtraDVbgL998IuzLoXd+vDTqvZivvwe6sDoPQ7zcYQEBpuBe1o2Om0O82wHcHe6q2BYhACMxunl2ugAUrrF1Jq
# DATA ozsc9UcgKOoBiBLAew8wAXwzaoX1oDts9+NGpwM8ZBjVgVT78Va31653g85w2AiDuFF3wSGFfyBJmcnidt2+bXeKFghIrgGMIWzA
# DATA /7qddrsbtttxpx2M4m6nV+/EjQh466jf6MSwSaOo2diK++16Y6vVazbifpSDRZnGxSAAz2kVwRB3toIR8CPgC73uFmwGoNRepws4
# DATA agHVhK12tw8IiFCuAfcaRbCXomEAFBv0gf2Oui4MXL10QPJ8HS4ajcKd2293Oo1WPww7rTjsd4G1N+rxVgOIp1Vvt0PQBkDaN7ud
# DATA UT1u1rdGra0Y+Hor7OFNdHleaptd64RdG1a3kKk3UcjGMHAYdFth0GwBzbajACRbrxvF/Q7s2y7I93a3HfRbIOy6wG7iZhTBS2Gj
# DATA sx6QgbnHct0a1QtJtg8KTj0OtrYawbANPG0LuG0j6jTgh35nGDYAI0Ciwy3gL41eGISjejfsggrSrLe3kIrvASlK0cRex+thixbt
# DATA oHa/3gF0xMMQ6LcbgRhuNoJRqwtECpu4C2jrd+tdgA4kdbcBjA+hjtuNXrMerLCV4gKG6zhdc6vfLgIpALnTBDV+FPbasE3aHdge
# DATA 7S7edQi4A2EIPCjow4JFrRGoUr1mKxgFIIthDkGv0b0PpNk9wrDVBrZVtK877TDsgYwbdtthZ2srHsWtsN0fhXgdI3K7VoSq7XBU
# DATA D/tAylsoDWC5msMoarSjMMfyFuO1wri91S0avtHvAVGAvAXZOmw0O0A2IbB+QAOIpV49HG2BBgkEMmpHzTgY9vswZr8FEnnYrfda
# DATA OXpZjm4Gl8tgHq3jtEAORTrJqBU0Wqigh7CJgsaoswUqTxB0G2EDFKXRCNZqK+oDVM02CLBG2AdVOtzqNGBfdepbOaWRnUSbsBbr
# DATA dYIOaOAFgNT7YTBsRR0YKwQyiRpBBzhGc9Rp9gNgHq1uAFhpDoFw6lvAWoGCY7IiGqPh1lYUb23omw8ImA2+2QmJkb5e88W7RIW1
# DATA Zq3RaW94d973/vDvg+x/o4D/G9z/3QXtLG//gyryB/v/37b+72dYKyKY+urQxVwS3qT8L5YOSiaTJWkcVT8djahGGtOTH6Z4j+B9
# DATA dX/5ek71LZ7Pp6n6cvmzZKY+40U342Sovibp714c+Gq5SMa6PnAwRz+F/hpPZvZ3LhmM+Qknu3tneOtFkcOs5D0/Pj7bP8HkjNI3
# DATA 0+/7J/svjnb3Xp2eDb7YP3y5f3I6+LLxDTTbP3pGbb7vw6fBula7R3tfHJ/QjebkqsUTYvPhRvnTSeXPueXgs1dHzw73B6df7AKb
# DATA 3SnZt4CUfrBR8Z4fHO6fYjpKKb/BS5znKaoqfrPdEnmnedFvjppgX15cMhYbvqMNWbo9cqw+5WSJbmnZ3sqFb1tezkA5PXcFwpk1
# DATA 8nodcOWpVscILQWOEvzdsY5pQpaE5jstV4wSPSEx4JzvlimFv4ufDD9qj1Wp4r3Y/cngZPcrLC3fdYto0CNccHjWzD3KnSyLyrjY
# DATA qq4hVuaO4hDgKDsVMSQyRM/VFSdDvtykSgSuy9TJbSVWp/KubNuaHPGlBphRrS7LlfdFeg9ex+q25W1vbVG6EtWaUv8pf7q9aZ1+
# DATA wO/ntc0L+6fKx5VPSypGeu8ZB7m/QJiXQKWLM2G+/gBvSIjVdR6SqIlhnwVdHVkubapDNJR7MUr4iNhiOYPNizXGMbSCEV4pvYj1
# DATA iJIM0IH1HLlyTLnBdYoq3n3VB9TZTQONKt1ZK+munXVkGPBOmoSPjs3tV/DWX8T1ME3HZdMp/GrNRJfKBlKhTSfoZImwYxMYP1ar
# DATA yDs0xJSmMvPIiv8jv3HfYjzTN/PJcozSdBHPzRkl4bVYdGTqhNnoa1Xa+3KeXKYqg+fLHnLbWjyNOHsH2PKDOcYH5namIgjVQpE4
# DATA TKby8Hx7E0/1YP8XDBI+LyqhjGCV8aGdVYQi49nu2a5fkgqK9sbAh3u7e1/s+7YcoA2ivread7QXsN9K5TEn619N4zczvjfEmaUv
# DATA VxWZ9cB5scjSlXKYCCiz8N61fiEXMhodQ8YKpiEoEC4/4uWc4+XhszKzIf8T5kdCnwpih0bl7RyEFilXzuuyJOXhRmmjct640GyR
# DATA ikNpdqcTWu4ZAAQKdFMspjcI3noJuHO3jZ9huKq9q0yd5EBVT5kEb5LJcrKjmLzhkA8W3MwfLV/F/xeMbTrtgBXDMCdlOQ7mVNPB
# DATA nPG3Dp0jNfIA6QzWvQTEV/GDDJvFwcSMRVfg7cjPdAqhLDOBPhsO7ZBwAK4gzx8BL9U6W6SpP8ZMG5dK8rJOX7fAdTLK88C6ZAGH
# DATA xx9g9Faz1916DK6ko5XxZcbWOTfsWR93jkVM4p54W2Irlu7QFmFTxSr+JgxX0rU67ui6Unj1XL118eC+ejXNlrMZZaOqHaXgLlX+
# DATA 9SUsQ6dmcvHtZW0xVI52q0ZzkPVBQ7LQogvH3Wov3DFj3SnZY5Weoqeq8pTsN1xbUrj1qUIuiaKOdso3pLH7wczLFbaiShXPTZVT
# DATA KgCfyllJGytGIq6eOSG6eQFrDD/Nbv8SNPzKX4rS+ZescX4DKmdFjo4+Qhw62EWgqGbOiqy1sMjFKjQSEWWktsjm0DuAnEu8Ax6m
# DATA C+zBVI/5ULhVzqwLNyYnlbljhgVzsjM5d7hQcNX9H/pOI6QDxbA/EA4slGd2Q7acuMM7OiATgKrbgRQmVsIj+BjT1jouilvBkkVc
# DATA KV4SyoCtVaUsmZRNdOTgW1z9bRZhdHpeV2fi0zq6yBmdLZcDPG+LzR65bEzSHler9NhngBwOr7fxnbI05L66siiJNAm7cpGwb6cX
# DATA XfGXrRaSFFinyFUziD9zi7yCQM2L+NX9fMB1uCCeHIbgRykXUcN9UHJEjLCaj3a0wNGYuP8886q2xxeLr2E9Ts+rLEhffmmLY2rN
# DATA R1YqK/Xm5f5LhNyldwu5K22KK0WtJ3l1NeME7ysF3FkXna4hfn3d3grZAPsy5zlk6vcQmSkerV8qSL5d6QA3kfUKbALli6qyxlKp
# DATA 2hvUakqjV/LFMaQUooFhTf0zc6RbVhL36Mcfy8wVDNs4xt3q8utziC7ozvE7SZnm9Hpa7LJFK2qtK/n2qgpcF0EVrX8yjKMop/Vb
# DATA SnXObpQz4znbMV+B7x4jsgr6K9gItkUnxjAOGpGDr8T3XKK5dd7bvigwCB0jkLbBepPPUY7UMKJcyFdk/t11xVXXCx2FuwLp87NE
# DATA TuKzp7Y27LbFKpIhq5pcrXxdsg/QgVv7HP6Dx5dp36fDn+4kae0zXOeD4zL3XSm0HICkcoaDcn3lDQfR3B8h8/bdaWYrYk+pgHJm
# DATA mWYhrmE2dAomgcPz6YKd0nybzSDJwDawTBDD5ApSFQeBiuXH8goblAekK7Ye4mpnMAcQV7f5RcxyjgjulEQkd1/ocuBnYDZKpV/9
# DATA Yk1K92ovo3miRC9jD2uMPCmZcWq68sg33+R/fpwHAq8ZXyFRwWMpf9IFhYs1woWF8vgN+eppZtykwpSlbui4GWizbke0qlk6Kys+
# DATA V1nH3fVrDptXVzWtPtcq1TSK50UyJQxASNnV8B4SKelyMVvSuQFDmJUHaJjfUaR7s4ZyC2WAnHB8SBTkvVrTUcoHjQiYs2B+AL+U
# DATA V/U5bEj0VuWPCKH6iBELf8fRFqo+CIJ2G/4UHcvB7H5acny/aiPIlS4W39acjn8rEyNDq2weZ1mZ8YYbmFRurKhAUO3UdUVtERos
# DATA KHTVNlzUh+yzB1131MuHWjX0kp+zxwTMTzgSxZ5DKoiCjWsydeX60i62/Jsi4oyYwht5GZXnCdD3m236L3Ltev1CdcP2Cz3AI1DB
# DATA 9DJG77gtyar4gltP0pLm0JGCAoNoSk/j+uUc5RI7hdrbe2mdt1o7qpVpZ25Z0AUrtIfyif5UQwcCF9hg/aWi2QnF7sT+cd4uFWhw
# DATA ikxyBox2p6C+q3v6cv/k9OD4SA3MlT1q7BN9jKtPepVCYhzNUL8VmBVaLuaMOsua+yATzsUE3x30GCPuMazQdhPbTxWJ4M3aVGlD
# DATA nWdyqoCuWWCHcIgMTVkVZ9W/a0yRw0kQI+v3WDKx7V3tisSEGuON3Fad5t2S22tNXbfmsS40LPh4W1rpQDNxsfW2Hd5+d68Aclxf
# DATA lbs7a+OVrdsecJJVegdDjOpeJ2Q/08VOU1/qrnielENecQGo9X+ki99yF+ietbffskn41LZlAFnP7mcdFec1glPdCEmt1RZhf4HI
# DATA jgGzRZZiymdjeJX4FtbwJ0XelrGpOtdoeoT5SzeycZmjedlAZd3xRnHmb97U6xzpMm3W1AF6pAg0J9XUxUm6XzaB77n6SzQlsI87
# DATA HTndpwxc0w0gzlp376HCOCsnwE3jopDO2vqLj0bDZTyN1WU3Xu7W1VWfgz5Ifa+7QZWfdD0N6gygPvdnHwYsOAPIJbhegooVz6+5
# DATA 0FYUYEZIZAFd86VSnE+JIxns0lu56obqYeZ6kyQl3GFPfclhoCsYAF7QdWGpRlREc2FymAyJ1ArKF+XXumz7BO+vHyf63npSiDHX
# DATA KCAOQ+XAVBISUiZ+xrD8KHmzU6qJgbeJUZBkvmNtoMp6yvodnTm65riBU+SRw4QU337Me9qJ02677XVTU+1fbbl7SyekmT57r3oo
# DATA LtohtCmkiXZPjB8Kb2qmJzXKTFNOo7f0rba//5ODU9gS8g1E+P6Ll2df391TYmXlyff93SndtWQFv/H6ptlyOE6yK9oGGcp6swfU
# DATA /aJXSVbQ3WyehmCl4GF8Kh+ygC0TL4Ep8JV+vgouqcQOLP4gaXpFs/9dmNH9DAkoRR13L+BNXA+FcF90QfS/LqsqrI+Bk9d0uL5A
# DATA gtMsjybzRG6vMPeofGRzEut3hVz9JtKzU1nGbP9H41x8KMq7B6SBLFQy7QoqwXByZG0+WcxjazPZvgZX9VjryRAioQ3vvO54cO00
# DATA JXpBh+vBtKz8XgoPpDNFa3bpALQOqJ4axghKVa13PVAwIF/D4N7GhKVHt5bg76ObI019GDy8IKvNHyhtoKoZaERStQhCoCFLsrZ0
# DATA 3QFRo8fFrzLOrXcdY36lE7vgAZcsUFovNZU0IctA01UPWF/lL5ZGzCCxWlx5uBAG0+b/T84Y5FNvv/v8/0aj2Wqs5P/Xu3/I//8u
# DATA /m1sbJzEWKHKz5YzurAmjqzKyJzDLbWsA3QKYEJoBI1DVDZGy7F9N+096f6Urv8BSfrLoegz+pdb/RF9rp53sv/y+PTg7PjkgDLd
# DATA +UCSlIBBf8PlVTivJemTcbpYgEn/xFxgq8vErPyUv7ZpfR+rlWWc/gpuXuHOuTTN/fCp6jW5X6CHO49vQ6QJW3O9Wixm2faTJ5eg
# DATA JyyH6LHW3Z7k5njnTNKA86guGI477+DF7udYGzB3RkF8PNvn9c1+sDnixJyK92x/99nhwRHmp1N8VQVBZmmWUKUjfaOBycwr/XHJ
# DATA ufJtJVJrLqKWXOY/LlFgVhUpz7eaS7Nt3UyBAdQfjAdYLrvM5I6p3umCsiFWb2HR5XWsO4foNQSX37dc/TqFGiM0+JCLOR5EfIti
# DATA Piag8GpFBkwXpCJaPfK9AgznA7fUOLehli1ATmARzoLLzFT3/GTl+TOydE0TU7H3Bn2O59C5lDgbubf0cYlEe5Wpspu9cc81ei8u
# DATA bGRA1/kiwpeXVMxMukvY2Zrv3oKDDigxIZn7A+9yfgLifagSo7lF1gCORFfhWqD7wThLmVLIssrE1QO/J0EWZ7Vcr7vXKdg5QfYa
# DATA e35GRfXQI8Ed4Jkqeg868n+Kmbf8e4Qdx+OR21kxjgvnxonhLj7kaQH2LgqKRqnKjBbRYco4nvBIwkUN2Te6UfEq40rF9viMdUxL
# DATA rf32mtswLdp65CUb6fySwpfmcpAadyLXka67QxOmLczSIrKiezPXzvzcfLlw41H8kjoEQwtc/hjVyCoJugErk7nsONQb+d6EVh3h
# DATA 1GzRuddb/7pJcq42SQGx6GkvW9fIqK5+uOPX867QMy4OqYxuYk2i34GsDiJKQwH1GPTfyNzGQq6DHUvu1ubLaflcSkJimTuc3kWV
# DATA k6jELRoGswVeoSzT5R8x1qA+Mig7E1CYW/WqAbzi5HGoEbNFBK0pk6X9+FQW2V+wJLDG8AxdPHGU6TmPk0mycLMbrRzt/NgAkrWC
# DATA vCRuG1n1IXJnsC44+1LdXcc3VvE1nU5wU5pxbNNM5zaJxxEfJsJ6/vDmNr/PUVMZC6v5DVi2KKM4oQLwQnolVakw4NKEuhS4k2Sk
# DATA lpolxsr1bZfzdEk3EKiZwRD2pXnqRX37tIwNxhdmDuavYHn7tka0d4epuR9T5y44zoro3t0rA8tW8UKukimFaV/H8UyAw+sDgG2r
# DATA fUO/WRpHfhMhZpv1FVw4KFbEaQ1pWaeSEpi5yf7kubVecCJv9+VC6/6Y1T4Y4X8pFf2tuuSqC+QkCXvZ7PtW8yvHyZOqcLedUKxh
# DATA WX8NrnsTs53IjSHlIgUGj7qx1jMRPblUsa4g1zIDAcB13X4Q8igHtiZFNYChSd27y5kpYa3owF6BtFvpfVy821St0AVwzjC391yG
# DATA Zw1Jx+HQ6r2PxelMLzHHcO7DdDklW83x5UkDRzst2NhmeEtX5eO6eGMbCMJ7UMqbeS0+lTazI1k5I0drrTr64fSD1W/lec3v6h/t
# DATA 6E2/XVTU8kTLTEERMB7cPNH2euHIvswdsDyR9cfzuatqDKHd63sDeq6yXsDFH7xG/Pu+Fm8jeB9Rtok+fbY4ongco4X5FHiKT2Vs
# DATA q4odzoAIKflOqr+7WuXK6s4nVMnW3GWf0w55ST/Z8RuPC/NZesSp/lgU+JPlYTXFrInMOkyXY76ADt3Y41ulQieLdYvD/Y1Ke7io
# DATA APJbgf3O9m9og1aI4amuv0v3jisGm6OUUuXbOKc/uIytbR59SElclj0YGeTLjHaUfbmmPbJaq8AtK8DW68rSe8AbrCS1W1hWnKrq
# DATA tjP6QjL7P5h79d+H/zf7PTl+H1f/pdlrtFz/b73X6f2h/ut35f/9UqKqOh9Q+J5c5MVOV/GRoLq1SIU93+fvzdVtudf9W/VfghX5
# DATA Ms2SN2u8wZbvV+q12PUn+KAzKd1ylou9Mzv5MhRWYjTfu0Z6+v0HmSkx6Wo5fU3+vQVw9HEwGUbBtnNEwbJVK1gjIx+hZYiUGkv9
# DATA uUeO+HlBhQwV8uZQ1SK4BG6ageWmVDe5vJnmY6JkVjq7ZaNQgyeqMAtfBrJqpoxhcQvf09x9k10s67uwslnlak1OMuSKAHSCwHks
# DATA lMfPYY73KcPv/tu7X3Jtb1XI+x/gz2/f//z9X7/7Z6HMzXe/eff3eIX9u3/CQuC6kofAn1kH/XJXUMvln/aZOvNMzqc+osz83YMz
# DATA oFrjMgMqPY4FyH/zwAwocZp067fBeYnSui+2/YCINEACZdLgOfFnc5FQIEtBV3DyTULLGS4wqDbmqj5LhEtO9NRC3Gp60CxBByXS
# DATA zDnjw72nHEfhn8mVIrhzfL0csCXY9GlwulAmmdpZ0Oncbok3OiQLq6H88OBZwHf/h8Ir13MnrP/m/d8QSWEld/iE5d/f/w3VhH//
# DATA X+DxP1L5+X+Gl/6FjwwWFNAXYrFApGMIaMcAc1N3yjIBBZOo20bCCeYT+HD3IMz/DQvP/waJ/N3fA9UgLL/hsvhYlh4oxSpMj/Xu
# DATA 3/0zTOXn8P1v18JLJAMQVk30gmA/z8F9UZwRJtedjawg1Vs9yt3mW9jEd5tgTS3fbL7FDu9qwLlrlz8r5dKxZsoBM7onIGb1vP2W
# DATA odSF/y7UYDxMacUGMw5nujiPlkCdTLIesinknO99TJalzY1gIWAZfvXuX97/XcEu/sWqp/qeO9cfiY4/lohbia9mz5+IN9PTF26y
# DATA ++VDp8aM9hfv/hG+/PL9X/v4Bz8AmcHs7uVZjz/24kJsqgDgbWnFFQBUvHFtJ/RRRds+eNawpf7Op732a5oo3w7BP8Pcf/7uX+D/
# DATA fvGItSZWTJe7EP8m2DglU8kaYw9jqifth4KI7Fvm6ecbJs4DG+D/Y+9du9tIzwNBf+avKMm7KUANgFdJ3aAghy2x3RxLlIak7G5T
# DATA DE4RKJJlgQCCAnhpmuc4cbKZnHgnyex+mN1zZmdzdr/uOU7HnTi22z5nfoH6L8wv2ef2XustAJTU7dkdd2IRVfXeL8/9sijoM1/s
# DATA Ds77CNEX6UosFi4DVeeVORwNzoGha6sq7cmoJ+CUh/CeviVWLaZOuJxafQQwtM5lDtnzAWLCiL8QQPyT1/8Mv//+9ZcRrPAXlH7k
# DATA F5QFBE/ib17/MvpuNv54cug7cJdLWa05sI8rReSq2hEcqMg+f6YIDiqY2p07q290X+Qw4AR+MuWQCAmoCBLlrgJ72hkXyT4noQ+C
# DATA vGrTp/im0IwLVn4rbdQ6BR8FZvmfCSH+QjaJc6pIDpQINorvCNyZiFoFeBhxq64rhRruvk16HViaOiPOVE7YBcy0j8+SAlcuGCZ8
# DATA qxTooX1FCx3Q3BXlhMSJHFxCDQfOflzduUMfHa8YGYimSigDKxEe+psiRDx/GHvsUJhRb4yXrqlOXvBKYhd0JJvuAVWBLUgfJ9mh
# DATA KvxHIKAcjB4pVTm3InxU5NN03at2XbTqODPgKAy8eM6HA8kPqqsNcgEXRA3EU8/W3xVJGICv9p1xYAXTZlAcqTg8j5zy56dWbDKa
# DATA 1QxFskN1ypwcunOuVlBqWGimSJUGZv0faNR/BhP5WyQfgL4rkp7w6nMAKz8lPPRLb0mQfIVaX/2VdRXxpcMaEbzRYRezo8u2+MlK
# DATA oDH7zGQB1tqa1TxRTHY/3qhDoRDcswjvz2EnGbQDkI/LHJd5gPGoCfTjO3azJ90LxSCanFZO2dddZ2a1yr1fhgvKT/Hrz4OTh3nj
# DATA Xv07oit+E2GmLQSZ8OK3r//VohsQRuWOlnZOh34hzR2ZSsXyjC+iSjQ0z/J2cpgPepOxGKPHjQaZYNFXDHSZl/jyKxxa0SEEyC3A
# DATA ihOgggrMT4ABQ0NEJJwOWC8hP39Hx/9nUXBhv4iD81IzyOfqGnHb54jEMP8YXKW/xgxofJ1u1Dn1iBJ3z8cdtYtsAhIKTRBrmYSX
# DATA p1XIGVV7MCqe8kJlFbYhaEVRvvIANJyGZhC3qqyjDK/IQIv3TpUuyoFyDMLom6RBoX0BOcyeHRzc4PIRgNF0CkLDXyByeP1PeNEs
# DATA CKph7pfI0dC1VCRMKUPDCI6gY1mcCWtiJp12YU/thoL7WtLOm2+v8DN/AbP+J0awX/1P8PuXM3bahHSyhmxH0VCGmxZX4IlflYuY
# DATA Lea0sIri1Wbv8X/EbUWeDLb1L1gyw5f2DbANzc2moSy5p3FRZuTook/RiFfkL2qrbRz67ehRDyi2rGNUuCjBzsnUkPsSJLtuTDm6
# DATA TilN04t4mEndXm9wzjJAf+Fqaik1t3+g7V7FPHb54NqxRFBjNzdSv6IDR7YWwihIz3MYY1FWxn+i2/YveLvKrp4i1NCOo+X0vFDY
# DATA lyufhGZjkA2H+AQqYZDrb89yodDp0qi36g5dh7c1T87SboWF++6O3r59+xGOiPYG7vkk6RGk7wqfIlbyfaXbGJ8kKLEQ7zY28DTQ
# DATA FZUnLk7Qwack16uJR1SkBej6KxOL8lAvahoSpejHU2K9GKqi8PkPVIU2/sJlf69lh0aaSnWoKF30QFYqhuBkAP7+WwoZTD5S+9b9
# DATA M+VCRYkkXLk5BFRlBMtNAkSVoqJS6xZUE1k7jroCl4optmNuiyE3poR58hPHuz2auN+xUE2R+Erz0dxvrpCQoBIf9gaHnAiBWZ8S
# DATA +x1GkHOGnfJW4qaIszULcbq0SiE4ljS6ECYw8dAqMk6jBnlxY1Lt90Km+QQL8+/+FAQZGL2l9pFno+ypkyinQ25yFWcQKDcgTr7Z
# DATA DN5sOeR40SrJI90UEmCyVJEjtjlWhDHh2XfpXjtOjqdbPGmF6HztGRl7/PvIRe6K26aVVFZ8802LRJ3zFlaWrW+aBl05/HJ9ljYH
# DATA DoklceZNcu0PuAlWbQetqpWY19oyjv+HrsP6XSEfu4wKr4oeVDMcHMVPoV4QqoeTsbM5ohWRSMT6U5rzc7TLs30clDmx258SlvsL
# DATA p8STgXULGa36K6NubxG5eGJEqoinS0OkAu7122YYUNqykOJs4pn1G4cTjNpS0nyelrajODV/ZTQLqxam0HQon70KYVOzAxqybWtJ
# DATA QBFBr9Qn3ajiSPmgYFQkql+dYXvMyGj3MgeOZvMC+LvlN7SYdLIZ/T7s/5aXlu/du+v5fy+tQfE/2P99M/Z/e6Okn/OlBIaWc2AB
# DATA IkPvpVw8NFCakI6AgzXO3gCnkHIeTMZcluKKQBG0eE96+fyp3zqD4eXbJ3XLjmHw+mmcjOf3JFep3kY9JLk58oz7Do2wUTNL45F3
# DATA NKPIlCMxSw1/Tfr0200hhxeZ87L0AVGO0S0MLztx0W2SpQGtZaLBSNgYANVqqpyyzZqVl+0MQQ/90HPryQKGc7dFevlPAQYoTwvA
# DATA 3rg7QEt2UHgVPdXggWleAweNTGQj6mbJcX8AhHWHZR5AO1PYmfEgyk8G5/qgEJCjg0LU7ERGwu5vdGJE9w2VWfNEn2rRYMin0/Go
# DATA lACOtISc48vmZVQSHFf8wHVaxvyzwZmG9MepUeb81ZhHqoDWIn8m1iP/ioo8N9WJmhlnQ5iZvKc4gv8bmIV/RQlboSNSAaKZimvW
# DATA Fkzro9IJqXBHNJxKcTx6mfCKUUTJdkGOsfJ2o56qHzP6UTSrYHn2l77ZBbBjr3/nGlfgmHWoWODAxu2EAljYVsNyIXRePvuQmeR9
# DATA bTycFWM+XIuMZ4bEObYWiE0zoDKFNE/Gjd321tNnjzcrHOl43MZvxmYWC/5RtDQAtFgemh6N2qQ2gBbkvAfE26bwNM+J+d+JS/05
# DATA rCOwpMx3/opsbH6LMqTfoX4ZtwXY0F/DyhZ48t989VPWvyP3/S9sh0gK+19/9e9jNxBkW9ZaWFVZbcfIIsZXcdOcRwwHyp4szYjD
# DATA P8ckV5XH6Me4PMvLlKDxDHgtFOvKasALYjE5pIV6C89+EpDwuJpGlgoLmnfgCmQyKKLr+mP0m/cCZE9QpmKZyqbwhqS9FSkfDoUt
# DATA WQXwjBwNUKyugE4uIK5AP1JHrgBRztPuk+3vuedJy051kZ3N7xaL6K+Pt3amfN199shrv1TiOj+AxGNHUOnneOh+ZR9J1pFbhzJs
# DATA SDhlfAy97Fd8q+7fZwVH6eW5wcT+Ac47C3f+kab0RfTVXzBQQ5Pc6ROC60TW3/8s9rtqIbASQDrSN6MA6VdowQuv2OStYnVwbwkI
# DATA CK+XX0aYv0MbeSTDYe+y7UI7/oNeZcTIO+hUMSlUpFmSN4ToiAHKkAY5axq4/D7f44Mavn/W3nn8bPvJp3BX6QmO1+ajvWc7+sX2
# DATA s4+ePXny7AcSTNVmQuV+QLEjuh2mT0fLWHHuvHXVSRKpByUg4qAWqTcMHQ6cE14EyErjpRsSkGQ1xEApnGbqpjD3l2wlSKY+vxZz
# DATA AzwVCIDF1glBLxe3aAjHrJZ2NCy9KMC70KriknNsPvPVTFctAMefoL7Yot9fj4VgXEVovNMD6tLpWXx4NEsh9oqW5AMJ2nbWtYO4
# DATA F7wLinI16zSxYpHTAbPoJe1KN9K2s5LGVx37SPpkzuXtsEQAkfDMStO6SPI+1iLUFLXO6olpRaucUsl4U7hByXWVwiRzDAddkTlg
# DATA ANqAzYhD0QVnwYZVzmgFCXujggGHhmXNZKHQNHwqtA3v7MadzVR3zhOdzkHR/AeAkP9IFCCZDqq+sboiGIunpGrTd4bj8OdI62wG
# DATA aVZa9LDoTYNLU1hD7UKEJfhQTfoq1ms31hAo9TyQWJmiH+eh54AoIyjxJWsjIkBMqEP4NRtQG7UJYRUy3f8nMjAkW0IivcmXpEgy
# DATA 13iENTSGlV8xRmlmuove7McoL9iVl9osVWIut0+ALVRcnPYGRlDhYh3LUlsKw9pXCzQwfaOXwGdj1A7hu7kSadGai5yDht+w05Gy
# DATA pEfGx+UUoYEGDpH0j7DsPMQp/UqdCayC0lLj8xCY5fPBqKufgZOYvXN/Z/wp/swWnriqLkIcX+KOAjnw52wBzwjiJ4QRfhPRRgIh
# DATA In5LSKp/9VekcvrXcgZUBzIzIotKBcdOvnpqm2oyPTwL+OtPJylGesWfR6Pk+NSkUXFCI5VthURbUrHYoIBYpahIN+Qg2U77ZxUU
# DATA yUrybju8zqv0Ut7qpkNeackYBo+eaaP4TyrfaaYXuCP70cvxwXvV7+A5MK420KJ4z+DnO63Gnf8htsEopstOUchdkVY5xhFSUY2n
# DATA HlzFDxwUD5ME6PLsMhq1mzh8hCEtfRRVY0e95DhvUZNT9AnSPv5RmZBVImTKrvJesQP55ITaheqy4MPR4OKSxd88DueS1qJXWb/b
# DATA ijtJt3sZG7mLXtvKdx7cstKKNuoHVXdxuTle38p3CmVFw4myRrRoInpUaE0NQyp+Avf+oN8bUPhqrrjgxvJCCmLSN9vQD+2DTE+2
# DATA QC/+lm0UpkalfpFhO7b80Eo45EYEkyODq8auj8dZ37F5V5dOTgguymn1Tyov8zsU/X5E6tuX+XvVyv6frMNZraxXC2EpLWsIno8k
# DATA M6Q/cJdoA3jp+NUKxfXj36sHfOJCGiQgxQgbLlkGq307nIyf25zOoRXnBkM8oE0FR6soBiVkfTxnumMQ8G0naqN162QsMBji5uKr
# DATA mD1RuRF8Jb9VS1eqpWI2HNe5CqOTHLGTlT0Srh8wOOkTfpcF5Sbovl2RHI2acn29aeTvaQuLBh0a7KAa1f2X1x5zS+uootFRtvbi
# DATA 2bGzC+aONFFO6mzM8w+IVJC7RAzxCyIgvkBagYiEL4nN/AW/+Rypid+RrcLnQFH8Lbz9DSGdUYo+EilDkHWbiSFGBpkYdtUggZL+
# DATA 8tXfxOWh9HS6TQwHVIsssUyBTmOUpAXDRgiHALBl5En6SsJroTCxcZ1bqJCyvJDfpygcJVSm5XE0PLvJfejrgCK0aklWIbMY5QJX
# DATA aeapC+q+kIAKf5Xff/EtOmWJlyeY1XKP+/fvl3dAgdiv7R2B0avMmt1MeYDo/RDo0bTXOrBrC+FV0XyiIDHVUf+MgqahfpwIyZrJ
# DATA xmES4U3EBpJKMNWMFcWtl4KTTqMpiwHWdJv7/MsJHbtvzhpJe82AkCOgCkrq4QVFE6TCUdFokRmDcXhSj3ZRlI9SiRDxk40GfeKI
# DATA eUWBbxhzNu48QBGVuDnIOiGBB9X1wu8rAh63hGzBLNmLAnbCzCiVkD0if/nVh9gyK6CtJClnYVt5LEiv4VBMVp4D18VlPirPutoY
# DATA nIOHL7JP6jeQtYEKqRtq6HqPbQ7U/Ha0d5ICxs3HkTp1eJuSyfhkMMrg1mVnqTge9tNzHNS6kLOcTYj1XkMMXDseDIo5N46Ueirr
# DATA lw2BJCmj7Jji1Lbc60UbYknRtWMf73vNgmu+FUhg/oh4aRD79eUDDiyriOAygpoJT01FQ49qqEFK2THeCMIZixcwLV1BN03et2s3
# DATA rKLZ/vIjaoM/L0It19l3yh+QUTo2qy4p6gRoVAjQJfqhfunmQbdip8ZykThEICDMH8Gpr5MTqpGQyGsiACXQobyCy+E5k5pGzA2q
# DATA iXm7daewu6O4Jsm21CgVxEFbL7yOsug8GeLpZSI4x6jlKIZpYFXLSN21NxJlcgWLqrmKvVl8Jzam+CpUYga00Gg46Ik1GL2DDaiT
# DATA Hnwi5oVOWFFb9qKs4gMxG/clQbgSS9SiO5asBUXjWYeUzxIfxf1Ohru7CkxSgQOvTwKdRfBrG4DzXG14e6BFRhTLT5v3T4HiKjCd
# DATA EmIqUyb0TqYNs+QxWNUKJ6D62VcWv4eDQa9iR7qT3zzp3THvggYcknBLrTYeFSJqCHg3I9U9VWuSGQfQM+kQf1T4GNm6POWarLV5
# DATA bgX+7J/zkQyhqSdjJpzLjPNri9bAQSIwFAIaH02kUQVd+WzIsf7IJwM9aoZwf+FmIQ1g6Jy5qwhIqEvfjcvTXlwcX2VKA5T2sTG+
# DATA wMvASmiaNxnK+iWqhZyzUywcAvMoaGtxObXcIEUTlaLIXknTXOF9Dc1R2qcp4Er1ArXpRKPaz4hU5DnrU4hT80oGq8V1hk5hm6WK
# DATA +mKy7+k+HbqXtINGpHtLhyjCxE2mipZHo/gQYY9C4wTIeoNJ96iXUMTF+LiDh7w6p8HILziUD0n2MFqMDgH1W1IM/WO092QXubJf
# DATA Mw+Fnu6GaYKeulosK/qNOVQoRhytln3uJTE19IpgnPp8nCYkpUeqt5v0oObbrcBP2NoA5Zl/hhwosqj+/JUphR6SK0THMe/Ct6fK
# DATA 5lqPsxpWHvEkcfZzTnC++SEv/LnIbr+cNrvPi/LZn3/1l/6sSX5NF8E69PhY0ZdGby0/+FxeYI2ec3aptbVVAfAXo+Qy2Il9E5nS
# DATA sp9ndLXFhaW39013s/aCdHtm5ekDeqVcuQvAOohkmFEPiMnNatXMnK5Jq7I6e/v+M8vVv/qbaOP5Vs3ZLIzBIEEZfh59Ai0X9Pgm
# DATA DIPo8WUD85NkxKLEGapLsVwIqSHxqFcc5B7QHGGrrD6jlqxSVgJUch3ysYtfXtGeVmlDjhpoQhMrKFwNdWIm0CRDKUbWgx4uRkWr
# DATA bxwNjZk9w3UJ3mT0NHOogLU5XXApFzzDcaNHshbAbvTFiGJ+78cw9/2lg5uNpdCbvcq4V495msW2ZCdZiYXXQ0pWXRNCWEyWh86x
# DATA JtMmaAE33iB3WfaLNQ6cxZg+KI1TZt/B/2iCn4QllFPVmI3o9T8QVP0rMrj4OerKvqDi7DnGOmKlYsPgeV9SVX4vWOnn8vJXOpoM
# DATA L4lHcsBLEt7hR96mWK2CoVNaejVcgkRjXgcnh7zOikv0/5Cj2Z/bS8PmSBQ6xtjnsUrQAkWHSefVZGgp8/kF2xPIjas7MQNnpLfl
# DATA +pJFWSVKRvMkO6OykQcSC0HkKhv9UcxSxSITFGva5EsMSwdv4F+0+OPj3zREZknO8WvKnoWkkn5kzqAJvBw8DE8w2mgTfjAZSwHi
# DATA eCIyLH6oXs9CVUFyys5gwLHE2wY3+xh8Omb2LAgcAqdawJEs0TWKMmBknZ4tQkKZm85oIjsKzeFWy2vb83oingQ/fgQI5pzSaLry
# DATA 8GKbFmfoNs1bkB4dAepBEVtLbC6cTbkVhniSI6KIS2mWV3rQDrpSpzAO5nizrR1URAFLzODKFuC4eSWssGCemAHKip6V5MnTmMBH
# DATA WIzF3p5SYl/COwizHhTx6KWsSrBkaVzZ0hf7VNlSLrAMncE6Kzanx3rl2cy6QdyuUN6lompzwHQ4hVrUti7T0SjNTyrK21KPvubT
# DATA LrUp4nB/r7QvM9sStRn+tFw+Uy13uEmaHR5+PezAZyucDkXTnX+EpiaqEzmucdZv5OlYwvhXYkkAwWIsN+IDKbMx7AJVbobTntNH
# DATA vkH8Lq56+g4q4eg7uI7OuIcGHmwREuvuHHRZyDtNZ2TxLBkt9rJDE/p0ERBoPL+N7v+lGSmNHDlm6c/YBPMf2S9CO2hrY8tfoTE7
# DATA 0A9skvkFMuRAVfwnm1NjIuILcuq26ZPPlfUN/Pvv7UhJtMZKMHUVo/8tApnDjLIuxJLNjLGPuZNw2zvpCLPvQRlZ/2bp0hDaS7pt
# DATA TPmtCG4rohhKUXvZZ2m3rY/LvhyC6Rs6XQHpTYZRCx0AK3n1ooK6ciCdORfOy9KBPd3AcbqePqTA8Z42RwxBYp3NAysVMRrOWgvl
# DATA NFxcUD11976UnGaAXW4obORvpUsTdUFe6JAFtNjGRFmfIFlXbf3v11P58oiRNB/3uUEKdCEbqJgnQgd2SWkCaH7Hs2pOI+j/5BsX
# DATA kBPAX5JtwZdoq6jI/V9NtZaWK73OpgW/laCPP2PqnQ3iStbayYl1cWluwSz4va+h6EGwif0VjqjhiMD1ulW949RWxgyBlXXiiYf3
# DATA SPbZs64p0ROQvsaK6WkwDeWC0gd7P96VEbhH3FERPKXJmojy1lF/nKJolPOqTz3vIuDRFaXbasEAiAPG0Sj5LtzI6UTbwJJ3xc+c
# DATA s4KcHqIAMZ4MHy8/8I+zczIu22wJRmxdF0kBp4kzWNLi13JBvBDQVHiDDOyJgHadOey2fEqk2027z/GAUj3EA14JVtvAwXKJUCy9
# DATA P0MVVossqiU7ujEBV7JrO7Y9kcRE8SyPVJTh/5nFxh6vTtEayWmwKAH4ch7U/UsJI+vGc2G53i/IwQ2Df//WyJIDMw9N2P+iiACq
# DATA 7uiwsaSoKM0OemeDW1OaMYvC9D5QOwX+xPMuK1qY3kThSF17AcxLh/f22kei4uVI0y/Dl6iLaRNOFba+bKBqcQanYjFUs9iVSniP
# DATA XEWJJQsoKuFKGiBpgjFv07Ny0qsgIFQcD81OBQYiAcl0WcIbiBK8CczyQihElYTLuo2j9K0Df+7Ryet488QDSm7nV3+vbdxRtu4U
# DATA 18K7zwm62/I6JcTzTRYlUwzJDX9J9IYdAFKZbYdW1ig055We0KoFzGulF8vkeuZ+11jyZcYQz894yxB82xrdkW0HzLY23SIRQ3r8
# DATA 8J2Q9PMGzHEb+45QG++qIx927O6u4o92nm3vtTe3H7cfP3u6sbWNXIStDLBm/nxje/OJKaa+GLoGxdWcLNvyPYGX3iKyGR46kGDG
# DATA 0+kC/4Oqg+GxBw8aq0kXZeMiQPfpGhrlrda8knh3zYBMe/Fh+/mLD59sPVJLoToi0+eiY4UbBm6ageF+ny1R9Lrsu9Is4uH7JGsj
# DATA mu48OUvrgbBW2kZxQQf+CZzVwMGxVBzBcyMFVRotG4K12FfcBnstWxHoqSJbWjFYLQ6jSBI5NFMpYXRjTK46HJz3067TYcikySbL
# DATA 3Bq18HZVa46w7qBqbcgMT8c3vkqhi3Cw8Aa35Zs8rleBW9Wccqeu3a2WU1m4yk9VrJXSjQ+XRsPYkltAe8eaDRMz0/LCbC68fR+z
# DATA N+rrgLAuqtT9lw1SzJ5Ex3OwT6okeqrSUeL6IessKbVQ4IUUWGETUzUCshQWk2TLPfWxVk1bQMuL8seg3LJQljavdY4+OH/dtgUb
# DATA tcq37IYygtc1uB1WKLYiW5fE0kBNTXMZHCAZM00nH5LJeBD75sFvr26x2y01zrJTOsi0TEEdJ8Uz0KKG1dzmMdQiEVip9Yl03FIj
# DATA fmObn4JN1+du4qwv1kuisWvnGY9sjo0eVZ1Wouda9K+l9mg5UmRABGJ6x3+ICkR1SMtXjhSj2qYjzGANMFUOeaviwDv7MlRnHFsN
# DATA HqZ2s2udq7wV18TZqRTKGkBSlbyT/q0qtYmxm3nO6d9EK1EcIZzCR6rJVqETsm8kHrYlA/VMZKjr6XOw3VcJupUtCkFDf2FCoLrq
# DATA NajGyNrYO3ekqge2aCVsax3bPLkSY/61zglqmYYpZg2H05OdAYCjx2qpHW1ApQG/HHPNuY16fKsjtjRolwVPCEUp4CpFx33dkLh9
# DATA 6edp3l+6JCs0EyPWKCEHpBzJV8jpe3wpfZfi6yq7ZJAxpyexYae/tp6Sy8JJJLkpVd6QRpjV0JuRC2WrF+LIyggBexsPjAOvjHK6
# DATA ybOp6TNuc8z1VmuO8Qf8UrlXYzzHL1xZm/TqRVsIuKu+Ij7eU/1bXaiH6kI4UniY5uaGXapbjenNyO4ZXo1GuxgizmdvxlTS/dvR
# DATA E/Ig59CJk1zSW3PkkDiPhpNDmFH0YudJxPG5OGuHOIJzPBRY4VGa5435pCNs4I/p5EZpj7NB9AUEyOFlU6hSLzepNiM8TWms/TK5
# DATA rjTrRdPtd4eAW2z4aJ8I1RaplZS8dvPp9sYPNr6/2WY5DSwdG26G5B+0LaqTqhOBAyDDnDMqO+oyIwpaon/f2LJHak437ikWOvDE
# DATA 4XNdqUAzyJSGlrTpRlZRa+hDVD+rKOINPmY3jC4UCi2kUZ5utCTKUBDA6kpF+BOG5abCQRFfe60RIkHbJ+3mLR5BZmDfjnTCe+0T
# DATA l1Mwg5M0Gxn/SiGK2WH/YiyBMQBzXwocMC6cuh1Uc7B9Jaof9Ou6jrjpOClRNlj2UaqG1llN9XyUYdJ41ZpnwWSnaGLvO89L0Xa5
# DATA tb0VZzrocfB3cTxxxqInGRMrIlGv8LfjLxQqpuMDcSh5ic2b5nI+1PI7oenm2FXBnfZcyS5X7SabeWuhHOdlhDu3NSYi1q5X9V2o
# DATA w/5+vlZPqXe0syqT/OXKHi2/sWR0VTfOhqjRiPCmBZFoo8XUPOEx6gmIRNJXD7JknZcauXD5ehDKaZOHwLIcuIKHKBrcDrXvZiet
# DATA wyUdpbabZzcd5vrhcJL1uuIdC+wFiVVQHTwl9Mmdyn5c70pAOlkmNoHkJsn2iGSgdzj5jhu301ugArYtW60g9cZIPOleTnPLVGl9
# DATA xbT1SCxjKySEbhYjIZrA1Q0YRmUfI0inF2lnMk4Oe+RduxUHg0ijvRV7EdPJ0j01hnDyqpROVu0DScjrQ9YREoDCwSCUwKQjZLld
# DATA oyDZg8m4tbq0JAJkDopvDXBX/9x0o9/fxELD1tGzhQYq5+nVT1//Lnr9q+jjvb3nu3XlkvPVT4MmQGq65K/DwUc4Qq0YF/0ziVnQ
# DATA DOnXcBEpQjYxcwKXgNpDsGWHhBWz9fIQbwyT2Kj8gLlkvBK9lNcZ20y7dWyW+WWxOa8Go2xKeypXtbGh3kDiw60WOE0B02sTvXFu
# DATA JDmnBsNGfJY3qljSk7Hy26PBN0Nto1M+4oBmbEAUuzoRGyr0upQch+bhY4oPeUbsieQEIpV6i9rJnxKs5A1ecpWMMxDQ28aqChtK
# DATA E9Jo1ZG+WPEw3MAPBYZBm+4a9TI3EIiWI9OQcCYmymceiJHA7TYmfTJZOs1yZJvag1dec0WbEpd44GZqVkwcCYPjDcKEx6mp8Z1y
# DATA 8FbOPBOIb2tdHNt2qmoi3pqhzqRAXL8Vc79b7o0OkEesXWdySMA+nMI2CWnnByyFXmnGiI5mdGk5ADg3TZmrlaA36Y9NbKpa2DYL
# DATA DgSJAIeeIhdauoVuF3agYpmAJfIUN/BX6aXt/X1DWGxiilqOPnod55Ds/x/iPKbE8sqO/F/IuASxzr9zRPNf/201jHwhqJRcUDt4
# DATA lRtjSgpMF2WqDm61fLAwr5lvIRGBE+CYfPZ+NivEcSOyszErux6xEsIQ9Npwz1GLvPGFcWivm8AWN+QuDUG0bSQPZB2SB0j9tEui
# DATA YGigwLY9TDKFIgvaF0Jz5mWNAyVxYSfwyywNgifvYYrOZPcoSWRUvu0mc5HQVJxHxbfJF9etfrTvaySATvfY/wZbkVSqgbyGou8f
# DATA i4T5Si1509uBWmSvgXhXEIa3Xlcblik71IA1tUtifFC7xHWBk5j/sqtcj8y769hWgVV2DqvVieb7g0hRjYpoqpqm8kxWAgchVEvY
# DATA HhWj7ZZiqMMAoEg2Bck/IYsU8UdDC0Sf4pYKfqTVGUtj6C9W7Nl0V81V8N+0qbdrQ1OjbjsFqY1rOOuQmwcSyNAmB8u79iFaqCQ3
# DATA 79GZhRlPmQR/QjqY/wd4lQKXtkdpLwXA6yGr0OSU1EUpIR0a3g3L03QRfXC4VT+Uz3UwtJpIP/UVLYKZZllANJFxhsIolIazI/LJ
# DATA rujEU3CrafV7eYQ0bsmfqRZ4eQvrlws2y5mgSIBuj7NEY1m2NroVspyQhzdYKrfq2y2WauudLdfsezaN3C4LpTanNDJAX2gz+Jay
# DATA 9W0GuWUJw4ZuN8QBK57YEb9RKhpSIpD8l5qzf9jpOjHZqZIPL6bjziKVWjTm81Qm6SbDsQS+8wzrw/zhnNKG0iRNjjBUZ2qSWPv0
# DATA ULHQk+3ZrGknoa6q72odWbzgChuw2Dh2AvoGONDCfhclQXF1lr+9khUVvH/mRxvzypYKCM1QRZra80FukC4KkTyW/fmckqtCS+1e
# DATA cjmYkAOLg8mLuGbOC1nAN6WoPciQ4LYszLcVQpZ/CPU36SeAYotldUSVLierc6toWD5XcpW3DC+mk3qVBfMwV68ZjFbpbUgoUJ8X
# DATA 8kOHBClEDarOZVL0bgLykFzQGxnwJk8VUzKPYSbbGtYkisnTZGjzILOCAVZ1ijPOeEuCfQYnzXnkQcIu6m078GwiQ/IiR47aLB7p
# DATA BAhNgsZmMDbDV50i/DYo7pZGccqtOTgUJ0GB16bKXhOeI2+plVPEcT9xsQO8qMSLyTBbxKi/ixyTMmZdOPbB52JRBQwaYsgHtmu3
# DATA sog2SNnV5q8V7xvhvY9hxXvw7UpFuO2mSVdCM9PSng5gIQb9rFNBgfnyCodrOT/BkMSFAg909WZ53mfOekdD4rReZKWlND93KQEe
# DATA oCtYuVCaZcuxzd8Zl3jT9g0lxLa1awVjA1jgcKXDQffSDUOrRkqSsApmpZTklLha5YGPvaDh2K4VICDwlc+e6g0v77TS+6aknNos
# DATA fzKA67OBBkao2KmRk+SUQMksezFiGpK2oZCMNFs/1+lk2HhYJcX8KSba/C1HukB/1t+Rt9wXKIkLEPbeHggOsrPjNlAPN01MxKGy
# DATA OToCkL6jtJh+iUyrADFCqQiT6cR59OLF1uOGTxdKDlKytwI4xP13xPVubWmtOg0szH/4wpOuPNuVTN92/m9nKWAadjpcoxPOjSsL
# DATA Xcm8l6bDyoogyrDolPSbkXgy/tbzT2Y3ZiUsld38yet/ht9///pLUYVijEkOWRLKB1t0l/y1TsmgotCz2vIt1J+3LDpntnz9fzXu
# DATA 11989dfo9OknjcDZxQEZbRHTldNdWhv7jRFeWT7EGAGUZ96kuqIM8ABfJfFxS8moY0/0zOnpWR9FPx2ZL71BqaRxCQo0rEYZBwau
# DATA m5/ehF42R9vDB2TOJlDxU2dkbqmtjTbMaoZXjsLq6aQfo5wwqMog3tgYHU/w+DynLxWLvm21291Bp92uWjUbaBmYSJVKrEcWo4HD
# DATA AO0+WvtKM6QVQypeu629V6p7azaUafZooKNjhToEThED3QEivRymreecbA8wPZBxXVu9GK5rKBVnuE5yvFqIqJ0+JKDA6prqNO3O
# DATA 6zszvXFkDuunPDLTdlk03TnaItuU6npZGQlFK8UC3gq4IPWMCGwTTRTPW+ypBkTu7+QQC3aJZKFxW8DzSza1VJb+YOm8Up1y59WR
# DATA s+MEZmgWKkG1qQqzWnz7DQtFzzwTeRAOTJ6Ms5S80EEJ7Gf2iaVnO5hvtfwus5+Vuh/2nbDvinU/7LgHLLM56vTHPQdGO0pPD6CU
# DATA JpwlkQjZOHHupUoMKAmGUpXcs492Njf2VKbZncc/2PGzztY4543pRqV8PupSB3b60/g8JtoXe3AxPM2mcYQfKvhPTd48efboe+3N
# DATA T1y6ykUHAX9H3n8iYbuT02FuQ7aZx0Hx4JiGOkdT4yTvZFlLDAZR39Ift1aqCGFhY9tkG9Zu00lst/EktduxMbTMs+P+5JQ2HH8m
# DATA vcbu1nf3Nnee1iLz/PGL57YZEr/nPxVuQCdbu9MGPpZs17JxRVHfDiZnkG8j3opNb2ki7HvpJdNaAbKT6YvdSwAzp5sX2dhSSHqB
# DATA v1JurKIogEdioU3nXHry6JSq8gt7/Q+GFtPUtibMCjYBQfu0GTZpFIbmJ5QxG8m7z1XEi19RAu1fUky5b727/06T0WeHcKGGl9/6
# DATA 2v7DhOX31tboL/zn/V1dXbt/T72T9/fv37v3rWjpW9/AfxM0FIUuv/Xf53/fvrU4yUeLh1l/Me2fRcNLQB391YXbt2/vAO8MF4GO
# DATA B3BnG8+3OGoPmfESz5ZH45PRYHJ8EnKdgfINaGVBgL+i4NQzahTw+uFV7o7VW2DaiHOSRyDgT4DVUo8IHtXvQb5AZgZIgkMRhWOQ
# DATA xlJFRrozAD/qJ/apftuMnPfOGasro9FvJ1mXxyCQRI2BWAoAf8AnAcTt9GBCkdakMd+jmQpN6MKkhQPTaWBFBA7o9HSIiTWyLnyw
# DATA Myuy0QFhRnEuMWbKC7Zh3/R8tuRRCQA6H3ezfiPLk/H4slI0jXJnED9l87/IcmuBZkcZGiczDTboU3qfhMP2nqr6zciloGRIsvUN
# DATA +VvhaRPw5pkzCM76w8lYfdTLuz3YSVk46gvUkKVW30SuJlNjLwT+0pbiFaRUiUYHdD5EQTfSTaf5MSw/XAc48jVM7gV9zFwf7Fi3
# DATA Dz9+RLnH1/Hi0HU5YicTkmygY4+ZzMYwMyNst7N+Nm63ZWQslhu8goMQO/E6jJiRGSXtZYVjdcx6Jb+vMo27Ynmndp+/1gIV45aF
# DATA Whc35bGb8JizAvNPlRU4aCvmrdELzB9v1oAIscFkbKdCrkW6bdVyHJ5Pq6WCG5DA2oxeT3R55X5jCf5vGSdLGWSxDD40m8vx9Twj
# DATA 3klPB2OBdbni5dgunbc2iTg17e7ux9F40seZ4WXAErHtWNI7atBe0i/aUN5BndV3EQla+uDWknNIRk+f1D8ajM6TUTft1p+PBmhn
# DATA FpnttL/CL/xmVuCa187kMZhjgSRq9rU7oLnE3NYFRTrU3D/72ungBMQoo8hUbEAx/ZciZ8Xs2PEPohwp1rqgad6QHP0sh71FsWC5
# DATA c8dex2sn4KbeDPcsSNn9eIOT/X0m/tEoWvowBY5tRDDNVPdzivomliSyLs1FJ5Uq/oUWK0+sTHARl4X3xGIc6Gu1IWWr4Xk84iS0
# DATA 9T2JKuou1EX9/Pyccq7Vda8c1tf0WFxZR0mLCZcBQuOxGqGvXGXVituBN/W7m3uiR1uuzmEcCQeleMJ2rNOD64P6Gjo6uIAt/EeD
# DATA 7ZYG304gjKL0m3hB61wzz0kIQWlD1mapQ9xsx64yYnVFqSIsjUSZQgJDoEpD1ehh5NedpSfwgReScGo0mIMSOLTRcVpi2yNo2Unu
# DATA xyMJWY7eSD2gTYeYggjK9afph9zrZLfonS+vZYRxaysf1KK7Syv4zyr+s3ZNxdSBfRCthLu2hfgAQ1SFaunuF/yVZ20MHeboKMl6
# DATA abdJGCNSNpNmElXbZSmwEZWgdqIW7fHhDekqpize731VoEofkxUM+rIw66gwQlX5KRTtRM+f7e7hqSAjM9+XCwcH3N3p0MkgH8zV
# DATA WyEf6iM46GMnh5lKud0dNxTHQhHZvKZrWADffQa9NybjTkjGU9pYlg84wSU31lC5xuMfIup9b2mpubTk2ZlzW43xZyiDDnvrWKnm
# DATA qaxqleu0ggN2cnI3klyVqPilG2bMVTNeGSoM+oeWRql/lo6ADs3RbDT/00nSRZpuME44+R8GiUiyPkuctTUpcn4OipeMf9gK604V
# DATA OWoFGRBeZgSrOun1KEZzZRTvb9R/mNQ/W6p/0K4fXK3WVu9dx5xMeSYN/0KRvN1Bysj6KBsT9d414a4jXgfvYI5SqEg+JlbOz/Zp
# DATA MiQChXkiJFA2Hu1tfX+TxNPAeQHvhOYi8eOt3Y0Pn2w+JjosOwV+kl4/2Xq6tcdv04shahHw7eYnz7d2+O2g3z7hhDmmCZ3Cxqyd
# DATA GC7oGPJmdDNXpP+qPzjvK7lApFpa4IAMpxiXD/rpUuJc3nQxygFs3KYCHH1rqVrzSmC19niUHB1lHVXG3tal6EGLu8AfHywt3V/+
# DATA 4IOVu2v315Y++GBZcS1UikYQKDRrdlt9MnaMZBRwdifIweZ6E9Gs9PiSaLPAzNp4esdtVYwnEfcH/D6uNibDIdDCJjKUak9zKNvP
# DATA 2jubuwB9YS8fb3yKf36wufk9/Pv02fbex/jj082NHZtZKduoHHobjNA0l7qPzLDYWiQZ4aUjv/GDwogQC1BHttJOz96Mc123o4Ja
# DATA U7XoMO0M0CldF7SvgaTw4RO3jyu5r47kwYF9Ws1rGpA+3UZy73f+bLv98bMnj7H9yzxSd2A9ogvH1xXxWlfEvZqDw3RE6bmBIwZA
# DATA sS5VwyhOQ4i7bUeU+GE6GgACTfp5hN6RdGElpIQNKhrR5sVJMsnJXrrT4ewDp/AccQeRXPCGw+DiYX7Y8jvVFw5Wc9m3mpB1pjNl
# DATA IIwCH9dhfxraGF1oirkud1vne+bwT+qI3LLPiGdp5G/ZjlpbXvSIUiOryusmgEp0NBlPaKv6aHuaR2RuaeRKNnsdOqpGtYXDnnKG
# DATA XuRon8K5S4CgiT6DzV0HenkMbD0P8TS5jKDXPuOCpEe+/1E+RIJfwY7kmIwQFxxUfGXQVlNsZNURVymONWzfQAbW0Bl8H/hTzOkX
# DATA DAyS10pNsQLArr68Ul9d3ltZbd79AP7/h4VQCrGM9Anu5ofoLQj9CQh3vu0qwNHUC4u6ckJhWwgf+0lvF/E6hcRBcpUSxaE5T4Xw
# DATA fbVaCPYUW/ottLzVMwFQKPEZ4xDmYulzt52M4wKZtq++bnDmdn/trLpWSquMQmeYHuRdbCfNmFjAtIWG0RUpVY3qsKdnPXQEpFUb
# DATA /Ig1y/lJ0h2co6Ngbk3DNHMT8D1EyU5n0Gtad0FILpK6SmAalj7b6aSlHlBdlGOjplxN0f2uYkbN2nF6fAEbh3KnijUVJekzE3yu
# DATA 3lBJe6pe8Tw3Rd3gAmpsCvXJevpuDB6/oATeUnpftcLWXjzLqh9uP+BgN12ircdmxJCuyNFKUWVWze1BjdS9DcyG2J4QMsb3ibYB
# DATA bp9L4NPqyjxjfq7GquWxDqlqk6nixwE/iVQdpZKRzAWdcpV4iniLCqqCwlaFR7Y9iIpH2Jbs2mk0LKrfCYBSLtU2tKxl/tKG7wp4
# DATA VBsUtdESp6pocPBzv7584J+TqWzD8r3avTXkG6C76jwbY7vbshhXyfuSKD9BNRGeCJYZ99LjpHMZsJGUBSxuT0xN0LkjH8HJYZF9
# DATA q2nMpi2rKGmNcGKom+l3067M5tvRI701ERBFcFjGJKJU9kpRegZzOD9Juf1TktwQBk4wFhKa0iAFIww58Y8MibK01yUq02HZzMUp
# DATA ghUXchA0VbM1+LIWQmBlmOtAA0WJxMyjckCSfFHrwloEdczQ2g6pGvWVwkL7/DYtPjGtOsZxEH0jfqLWzGfdrl2koLYzbcPiZMd9
# DATA QkdXOawsnwRXtJE7KflyNu6gyFX68gSROAWpvLYPFGI8M8JgpQMCWmpYxv1EgZ82dlpJhpnDeiswCe+VVLdC0if0L0M7e1IzLx5e
# DATA 1tXZIat8ByYgSabdhZKjFBVjRk1gx/swqk/bFFtrSYupzC1ZEmwLnME24xieh5Vj8hCvlvK0yEnOTPQi6ndIs4NZZ1mXgWtpcPTg
# DATA 6ChPLTH5Ui1aZisIt1EVZ2rmWn2HW2wpySE/UlydPyLiTn/h5l3ERjRuOPYLfeLgkfsxPbnJypwPdLipRtEUHgsaEQ4FZ8FsB/NB
# DATA VVp+MT5Q0TiBmSNFNO3QOksD1cskoiB2EfDd2aAbe55kaFwqUTj3ZTQHRc/EosipyqHDfDVR+bgfT1hZkgopxl2TM1tO4bxwDDp9
# DATA mueGl/bRBrESGkd1nddC8S74UPUTClIJ8qSlLXHHfAhE8SsfFToLgsO0mnkYaqVMnKJsA9W0eY8M5rfavVUYXrjRTWpCeFAUeqeo
# DATA nBKZBhlzO5Gmxb6pzj0rL/YrmVxT3VY5uE0ew7UDMaiICg826Xsm3eSexcaSk/FwMi5L61amT2ZrGD1kkgbgHhyiLhnaORygNQ22
# DATA Fpfk63U6B7g26J0pxZ8uK2EV7JTctYhMfVX8plrkx1zIjqz69qTwRCT9y4r1FXABtl+dR6QK8wIOPkI9wSUyMs4CKN+pvNE5gQFV
# DATA LCBrDU2OUwttJXj+/KatrR1sytcq5mAk1L9b5jYcb/XRi9299sbzrfbes+9tbiNw3VH5C8kGitXDkc5LpkTELaeppxs7P/xwY7v9
# DATA YndzZ3vjKYlflMw06QLxBC1okx4rJ5sm48PNPd/Y3f3Bs53HdnOqCo7JWhxtVCCPGmUghaZxBo1lkYrqayHiCfXT5umaurdr0coT
# DATA fkWaAD2Y29wQ4wVi/XNyHzUCsCDiyoSUqHMVjOhg0PN+nHmUhs2M4DE09E+rpWyauUabGjSED7dfnS0G5upc3nBUdF+wna6d7NIg
# DATA fZirSyYovts6xDQ+Qr3tPPvMii9WY01lLsTCviFZFZqiPqb48A2TS1TU1mzRrqt9CSyOvDTyTmVTrHgy4C2QLfO1vuwk4O4u03jW
# DATA i5oak0X7HxTiCOvGbPpLRR9TTIsqpJuszo17LUhAS8nRr1jT382OjlKKdsUcwTp1OoA1Q1wCFK+Hjcn4XOdwlqHQtZC1j9Xiw0v1
# DATA 0/aqaAana4VrVnpcdxquB5oyhK5FaMBRahNNzdGhMkP2LrhPUHACacokFM2yoHZHqGSPSociIJqXNb4uRdB2AGGDlvlGxDx6XDT6
# DATA AW/ooFLKwqZ/cq+VUA/1SkdCKDSjK0NkXCN1mHQv4SVwsORaONm/rTbkNuf5majgAlhcyXY5S0MHyBOuOqMaCuoAbY9z6Z6HX72O
# DATA 7SGS8IasAgVscFYIaKKpFf8mhYvGydzWLBj2fJTCCI5PxlpvbmNE4NeZeG5EO6T5iMw2uI4r3dFlG4ge31Mhfgy7B++1Pxgr5hkM
# DATA Fq+O6+FNgBsbvwTAinNmo874kW1aTMr88QlcEhzad+ikR1AB0RzpFy7TvOBAEz/CA9orny+6ElmDEeoDBfMiHUYR9gEJRWXD1Qte
# DATA RnoyWVEoQILsu82oETBAHSin1xEwcbCu1NgBsFgO103Av+mw1pjUBoL5BZm6UnMrj4IqIR74shqIXGhGYJl7NsO9fTvaMLZJqF8B
# DATA +rc3AHQrMqZIh+RgC3QyJMZwFf1OhtGQKVx0dAgEard3yTxgI9iR45n79kscXmbF9irsJZ+nIa/yq/xI5svSbPR6zfB8j1K8f0N9
# DATA z8cDsx5Bt2486loLYrIQF+dEYukbDF01be7M1MZDJnOzUbfi9gENdVIzbQI7Cl87UYZCZ68ESaoJyB0/CKJLoYUD6NHC3gEEJ8JQ
# DATA QXHcVSk23P14Y+Xuvd0XT3fJroUzPIkbRCM/SeBjZegF+DxJL7rZMV5PEvNEhDyGnB4Qnl/2Y1YHEQVM8niLczvuDQ4r8R0B/dWq
# DATA i0MZIncFi8ky3ZYjdPsAUZ2NGe1C+j0XU2ZtThl+iQUM1vH3YiaiS0Yks2b113pkLTfJlXLqegKvUfsupJfgKaD8+JoOunSp4qAT
# DATA 8hv5Hxe9WYkeQoPa2HcCXg8Ut8BOsE5JLy4rNVdPLDmYtwNiXerIuii3ZrKcg0VLYNlby8ChhzohKq3oGGzbfinZoWnM+lw2HCBP
# DATA 6hyWKyErwVbMIbXGMIU4OJJLUhOESpd0oTihunBC02orb+CgIzCetGWSkrs8IL66u7Rk0Q9svVmJzWI3o+X/+pP/5S7aATK/qXWK
# DATA AZ5OZ+wQd9OZbp+zvDFvyItYLptkPvxvdp9tP6YoxKWsCgOcN+M49FsNZCh7AVOVRF+i3Iat9BqWmssCANQ9UMMY4BKaaIk7FHRb
# DATA LfcwXX6njpi/p//8DBG/B//PuytrS67/5/Ly8urdP/h//n79P5+d96NBH4jpMcXy6abR8SQZdSPSV6xHr9J0SF5OeMEAh1AUAbJL
# DATA uTQ2UGdwIbH4NE/QbCiJ1N7ezfNkMs56+mmcaF9Nk6pE+4Gmp0O86gsLe2giGKlsdSjn5ahlNNt4YefZsz0laeeYl7pcnQKgHemg
# DATA jAsvtre8sjmBi678LavaUKGJqpaa4Q4CbzcTC/m1OOH6WD3rZorhegT9xAkG81dJE51kiFZ0bcb6/HJKIj7unf61E8GocfbT8flg
# DATA 9Mqxr9fGbnpjG9mw7ZSkXDNZZ2xLvo1RO9L22UUvpVgZSxHF7qUPWd4+hb9AVOZj9/WEktkRDefTi3awrI1IinXE6XDrObYD69dP
# DATA x7axQ+wogDi3NPal9wdV4ahOgUZgMvkJhc+AVT8cZV0gxWuRyT3fWtJOvhyHTi0FPQvVgbVJVk/kOeqIdaPV6MfR1crKtaM0ky8P
# DATA o3trShuDxFhlWFVixYzz82miY4j/3Lt7d/Wu4Qa4lWkrpqR5eNGptKu7k+niQJZX3lcjmW5N02iiPU1t+S6a0xxy7s9DHI1qbJ7x
# DATA PMYQ/COpomzektOsRzaf2fAeuavFzZj1uyY4XzaMXQ3SUXzFFa+jHM9rdEXFr9FAF50IhUBio91WVImz7IhYqyvis5BwZS7N9sGz
# DATA ZmVtqZogp7mJdBdE7chHlYBYW5DgrprDFNpeMnk3RfQ+z7OOHHHMUsqep4cYIYYWZtwZRl1q8so0r0dNntmmV3vccm+O4jhm7XaG
# DATA 9+uKIO11dHW1gFYQ0M4px4aENzRPKtYWWAgsYy8BalqAznp0fb0QUd5hIeywGa4GcBxlRCeDgSL6gJ4bjNCAqb68BEwAqlAvZdzr
# DATA UEtt4e3e4La8hredsQ5Yy4vTHQ2G8P6KzwpK/awVuYquzN6fJkMkXmtyo6rXMFrTsKn1x2bO+uuVLPm1PYSUzAKy/CTt1lS+0I5S
# DATA k7LhOiJa3chpOk6i3hrZ2QHgPbtXzzqncMfhn7N7vEow4n633k+z45PDwQj4UVgUtPW1XyZd1BbRuxEseqre4HTgUsESD1nxvnL3
# DATA 7k07dzja/ihNYDMpkdkwwXQa9fFgUD/MjhnN1JVmn5LVwl7hWKADqHDqrC3vkTkbR+zyXHI61NcZ52OOk/DGO3UlsOTaHjz8P9wV
# DATA EzuugxItLYAQ5IBIYEHsYpVTXCH4QwyQuv3o2fb25qO9rWfb7B0llo8O6DaNkGnIGgf30C/RQhIwazc7xooWo4aDIXsUZNjc8qHY
# DATA PggHKXQpmjgBcRITuZkjvQkYjnP+7eEIx104cDxQLB/OgOvgFLpRL7vvxZRJNZiZzxksFlIrsa9HWwj1WJ7WzrHFEimyAtvGi4Z0
# DATA 3jTVLiEpTmZIKJ/cuSRcOB9LcvwaZbDbLcFl+PFPvQUxO5fZRou2BsKOflrat+T8RSd4aEj14S0cpx3KRXvBh+qZpI2xjeKNBRGt
# DATA gJKZSnUdR7vBI2nIMBpcvCF2VF6KGO8/NY0lQjasTNkmbQlJMWTFBPUcjig0G5fa6sYH+83lFbXLipJjZMxQWlNrmqjjxLqEsmAV
# DATA e5oWsdTdtLj9ozF75nFwBKrA65viC8JzinJ3SVzVUoMHRG7JlCmirNk8dhuyKvr4fYfD0CitQdJnOoG2PIK2uTl1R5N+nigYUjmK
# DATA uynZaRXR9UuOgx0aOJHngveRpKEl07InNZ16h/49on9jYWKs/qvFGlPKSsowRKPnWb87OK+gg7781rbMG4REunrWMEr2lej0Buhe
# DATA RLbMMKtHgNsOB0RJIZeL0S4iufFRZ5QAUDfpvd9w54MbNq25uXb8zXbdugmwSNuDaHCONsTM12doIkMZE1C7BBwj28AoHjUHfJf1
# DATA ehyfdOqi5LQU3pLEmvKJ51sfssMwWxuytbYc8F4Mj0cJ3aWIc8TInEg1iyY4KrQMX3IyvxjnfGIjlZeqYUeHLTuNFTcKIKariNiE
# DATA 1yJxb0zavrTiZ3C7sBdIeOEI3baZwp1CU9ptVYu3i286+RDzpZixWTHRue+TW/d1HAZrwY2yO4VVerMeZY3w5/LdUx6DggJ27F7P
# DATA w598P6YZYtrM0E56NOFIFJGUVxxlt0aCosEoIXNLJTRqnL5Ccc4Q9Wgt6ooNK8mB/Si7aMUNOn/1UNxiL9rkUddEmcS2vSiT2BvP
# DATA k2eov2oLST3AQlzLQW6c/k0hE7SYQlD1Lp1rN8jZb0ZSBOp6PpGQqzSgpoRKdYkBRiVnnuEPKY4ZydYt6djk6HzRiiOTN7q+hIxS
# DATA FVfNvn7T7DCMEMUyJFhsnJ9kQHjG8M4NOAAvSjP58qQL5rPqPZ+bwmfxs/KKkIVtoDYCrwpSc+0JzOEW8QRAfqXwNKM8OTj/EZyb
# DATA pZWVaevzoo+eFdGLj34QWful2rU9ubgjlWDS0ioBjyhxjVQhHoYP8/FtY7e9tbuz+d2KqqXGSrOxX5ZM2K9XnONbzJPvOMqZ9o1p
# DATA 8Db2Qsfn4CUg5HEP85eqV0qq8rJvK4w5yGiXZeu6BNGmLYbg4tlplowU/yjN5XSe/nKzAZmzvLgCWsm4vOJl/Cxro6J8Sl1zFpcB
# DATA gzp5J0GhIy0IUYDx/lL9AxTv3b1eBBT1EjWz3FZ1KgjGFZeRUFaASf9UVoftPvIQJHUEUJ6XOaMGblGBZbGps8HHe1Es46z6GYQq
# DATA cK05JnhM2exVDqzQnpfXxtQOc9Qikxuz6OG4YKZZK5m1Qefz9iWez7TrAsTniXrvDLA4uKm3/2uYQekswkZG3oGQM/mO9tyO/I9O
# DATA y6NBT2eNZRWBqAfeCAdKi5zF+nRwljqBcd4UQ0l45qYBBjfTT4iks2DcYGkn4GnlG9FOEASVZfLVFP//w8B6og5W0rhC7ycwQm21
# DATA p9Mg/n9rSNr/RujrIWKvG6Dv8CLNQqqWEQygOIqd5YgcX/oY/xF389JF+tK5i+6f01aI3qmCeDKpH23UP2o0Fw/eqyrEXzEItPKd
# DATA Zs08Vb9T9TGqvys0yplrVFycqRjXP0kKOlBnKEZ1w5IhfGISwlS61RLYgow2QxBUmJDhGDezcqCc82tohEg1vNs//2wO094AvV/G
# DATA AxjIYHxC3jMk2LA9dgDmIgkX3s/YRCgF/lv78QTAr4M47lT2A4jtwFoZIr/2Me+kQXZo4BCbIB3xeEC4sH8Za1QE/1atoKlkd2Zf
# DATA 3JnIl6YhuEhm4SbqnYHdPUwr3tXKd/BrQ7x63s489MkK04Q8vwJ1Mou6KjZfslQzqQ83FAPulcNh63tBljOFW9JcuPGIvDU+ivev
# DATA YOWubwqURPOteRBSb5doOIOU85wbaQ7jXNmW1HH3yK3AKotwmDIoyXrZdhg1TZzxBNkhH2Wgozam17BNa6YQQ7CHaBRUIBkq9Nbm
# DATA o6bpNqR4gXIggxfvk40dZ/BRjAFZ+uk71VKrfn51zw1Ys7hn2WACEyQdp5Ncj8bt5+C2kSixpuFSenHsSNLOphBetjtXiiQq85xo
# DATA OwpQwck57ZqKWaW2nU9MDul9LumDCuxwwqaYjTKsOk7rOi+nKWC5Xls0c81SEBq97oK6BaQqdGyJyu2I3J15S1UUyvhIaam2iU5M
# DATA Y4g4J7BztQhN24xLKlZnyxpoxkVD5YLXOU6sRaoBzEOdN7bX5FZ94YclpqwauUZxfCqUCVtrK2qhVWSAfETinKFCcFWvtTDf5zTh
# DATA A+zA2tOhalNCpHbbvVUllZ1dsmyQriRTWDOSocR5fsL3p6lOGceKx5fwzpbVuvet6U4D44zqq9K07sh1YZB4avAyxfsv+tn4YOGx
# DATA hXoM5UXsm+AgWouFDXT6agnsRQv8hsTcEmWyKFIWPiSc3iKrQAoRI+UW9ne5xMECWqW3YIfzk8F4YfMi7exiYL+WtnoVi9dommnn
# DATA otohjWk4aCENE23BW5dpvrC/xVTmwcIPErQm//AyMLA49vBlzKahnTElR+smgN/79VFKDoPTSqZ9ddVnG5Vafk4FDbeNgQPYt+Ae
# DATA 6J18Cy0X1Ak2tKjpiOgZqejCKcCtizfVaVGBsJn06HSvM4t2sofoU3L2oin4K7YTEr6MX5Wpxn1KFKa/T/C0fIKBk8HhgefZ8AC8
# DATA n/fElVS1BVxfY4JGVvI7HkIm5RyfO5k/4FH+hbgzFv1hHRVq+oFU/aSPzsZWNS1Om558kIHn1CIEMDnzYMgVamlq5WSY+VXnzHJo
# DATA VZjWAYFlzj95o0yFyiikpVfX99IRgkVSzxFu2V9ZoZgVEjzCIlrKfMAdYRCSvVNSucU7QoB55tnBITt7rMNITCdHw9o7P2shmpUc
# DATA ZRcYUBnGU2fbCeO9mZwN0PYLcwEukhxiBFAjj5LOaJAb04qRMSgpMBHfAGGvur0x2/HGY8P1sLI3qn2glI1vlLHR059z7sWwBt3O
# DATA 0SiscThHY+Ak+Xl5bTH4PseLQ9wmkeP6Ed8HuNalyTWDgeYovFYhmYOdBJhvmHevNKPAwZ8MF+JqlGZcD3d2b8TrLQRyqHtjMvY1
# DATA HptFF1+zUv5MLH6KlAj28tqB60s5xJlZvi0hjuu1cwOdjNPYdF2MHVMOCtq62nKNmcdW0IRVEuCDWiTPzuQPpsitguWN8erNWAx6
# DATA X51x5Aj7egfNshDx8UUh//ucgPvdHeKpQTH4Yvq7MHUSsyVcZWtjnW7DqAEsrFbLo0fMuv9MRL3riz9L1lHCgDAhUTjTnpKR1PZU
# DATA RHOwB9WqJSMpX6cpZ5MTGpdQjd7Bss1NC3hCNzFNCv610fPOgvq8BjIZc7FI8zOiVqydZ5bxKAOc7nrE+hY1BRFyaT9rHYVntk+6
# DATA uKF/6w//ff3+3wh0vsYMwFP9v5eXlu8v3/X8v5dW7v/B//sb+a/EKTvJx+x4TSKRi7Hley1vWFus8+Z2kCnV3tXpaNQflGTxPRmf
# DATA 9m7o6l2Lnk9G6fNBnl2UeH6nHaDt8qDrt8n9Sxl7FxYebextPHn23fbzjb2PFd1nRK6UWR7BEuaikLvRBjow6Q2OUUZbXXi68Ulb
# DATA tfHhp3ubuxHauTiZ+ajM043trY82d/d0oeV7q+/zp73Np8+fbPDbe/xqd2tvs/3R1hP7HT7q2mi9Z7W++cnW7t7W9nd1HfjuflAV
# DATA 760FBqdLPd58Tsvw/sLuHoyojdFKUTHe0Pa3jP0X/s2zFzvbG08CBeqWh4YUJg4r0BSxfQs7m482t57v6QKmpcOk82oylEaePXnc
# DATA 3t178SEUOYwf3OoO6JDRAXr4AP+NeoBOWrfT/u2HD8gJEfDLCKNf356Mj+rvw1vSfz4UYfCDRX58MFRvkBMzQQoeLA4fPlik5tGG
# DATA fuvx5vbe1kdbmztsCIKh7jIkW+L9pP7ZwT77M9cPrpZqa/evX2LKs483PwmUPSIjjntrXIbiypaWWl3hUpuf7G1u7249296l6HQN
# DATA HBX5m3Y4aQcsEf3Jzyh2TmN8MZbXRKXHjQspf54ewlXNjoDyi691juFdWGzm3g0jX8xF3R4m2SivkKjW9+6/urZj6tcMI0ylQ5H1
# DATA uWpIH2RGEz9+8fzJ1iM8iBg1pv29zU+L2Q8w9r6TmcLJe6DGjitRQRuiajOo3bHCy3CUBAqoVQ2mYiVTpC6FsAGODs9W0aPGop65
# DATA vcEh5nzmNWyj+2mLf7t+hy/6mY6ME46XU4t20s5klJu4N8X4OYV13Nr+/saTrce0iio1Iic6l+UhEOd5TXiR2k2shqpjrOcmKll+
# DATA n2RH8cuX5GzvJxz3B/Zie3fjo832xu7u5h6B4NhoJBEa24De9nlAXlApF5PDfNCbAIdaZdnCiL6QOIGPoYQsV64ZHCrhru9tODNW
# DATA wYEdtoAu+gcUtQCbDPou4gfOutWgy9fgdNr4ugHMTo7IpQLfgpW9YVS+0wRU++PhqP/jZHLx4/6k92OAF/vLMKwf94Zj+lGFQi8b
# DATA jTvV78iokPVvbBX5wyMZhVKKqlUR7UwjnxwdZRdwfM+RZ1PiFQOEqm+wo06ueTl13QHR9Tc+d862ytl7GK3cXZ3jCjx+9nRjaztk
# DATA QK6BmeTdlFwxjVjnT46zbj+BR3X3k7yTZfAsC2XfZPsi3+SGquHZd1QdeA6WR5FHeLrTQmzImYUjYaOme8vX6gudEkB1aa861TLF
# DATA OG5jWQO6lY1eA230brrwQRiNcmPRvWm5sWuFw0ABYYHxW9JZCkLQAC+de8rVIUcuU7fUgJN24rh0l51rIsysY40L00n6XUymRAhv
# DATA /84Ig4/m6FhsfMHQvxgfD6boUil5a8u01uh55rZytD4CImF7MP4IZcmBGKqFPFmSAZAsdJ9sf6+C/TjWucdALI0BbOIHSqnD5C++
# DATA yw4nnElnqYqy/4s1OzJdcJ1ogXY/ffpka/t7bqIss0xk3AZboPQxeniPt3bc4c3ozN6Uje1HQF4/23E7rQxyjn2JQoUhohJWA5V3
# DATA GTTVsktoy2Q1fO+jbvr7e59U51mtH+xskWVOyRTMurWsdTOqJqBaUYbz9qtJg9l+tteGipuPYByf3nggJJRii9+CZXjh3KkXJJLC
# DATA Q7E89wihvRdPNnaI3XFBCo5LARSV5mJ84kIQG9IY8VfhKuuLvM9F79gX+qBacFA2NzcskW6fJq/Stl6vii5P2Szu3i2/LQSoTPMF
# DATA aEWt06SsNgvJjpylcYfCE7QOCenV2jxXoacAi/GzZ+JVHlGa1svSRFL7U+SicFfNljU4xK6uSEihfdRtcY/cTnEnZX4onJb3FKOm
# DATA /ABYclR2xG4p1eOz7SefRj/W4HGAtk5GDclAsfD5w63tjZ1P6WNIQdmmf7ln6o6C7B+yvhIojjQ5bRadE7A+IQMu0UD43B9UqtNd
# DATA Mbi6c+XMK3Pp3PfiXxHILxu+jSSVoDSxFrAQRklGS3vBkYLegzuuS3Ew71mzkwg1xLupgZGBrRlz1h/UvCnYz5Sfvd3ntEIV6lXX
# DATA 0k9cST/qOlNIApr/o483tr+7+dgFQjhYOIl/7EnHhIs2d6rpHWLtOe7o6BUKu6VRmBnUJWZUcFXGll4zfKDpScN4X72uEuaQpc5g
# DATA ZGnrLUpJHd5wiB+ft0AnJyK+9pebXkqtzklGpp2mD2RbqHF94c1gqj64IAVNpayAMwvqKURw6eNX1gyKB94Q/5fFNr8JCcBbbAYX
# DATA 9tYPLoYAQx/m6OxOaEbxDuF96alx+nUXN6hcLYHPN1OgzjweRTWpfYXd9ba+ONeBkRTfs4KdShBtyZ6gbEhJkishoZTJG8HIzBZU
# DATA NwyXU4sKEmiHES1wC/NwowzZpM2nW7u7W9vfLfKkznB1CEUZty8g08En4pcjcluLHWcR40avukVZFT4XUBxnsOKM3CRCUR7nIh2Q
# DATA AkbCgh2xtxl9oEzr8hbx3wwsp/hXZ00ew19r9D1MeUYZEbmPfZI38bCadnbZ9AIDiOccaCnJx2x5V5H6ci/j9MxPMuzJREwzjcNB
# DATA FxNJQVOPBvSZZFEcGsMr1hBRiRgcAbZ9B1NH/CZzkVm0cfh+355j4HBUwYq0AVLtHYxllJxTXJaLsZbY2OLZsJB197I/Ti6CstUZ
# DATA GZVuMsaAPIfEOck5EjWFKzzv3bQJLyG6WNSNDZcI1Fgezclg8VakYyGubqFuIe+cpKeJspTNWWRJpwkL7avvB77ztvvVu1hzrZQi
# DATA oQbnuQjZ92UMByUzwaKSL7QgksZvJJF2NGxvOKSAmgPaJx4RunHwY6U4Rm+x4Y2steQ7RjUUe4hq82jyBM16sv4FrFXsA/OtsAmY
# DATA EZMalZUtGlRlqZh+MnK9UH9KyOj1iaoXt0v1tsHC06oS0qr3eNhPk4vsdHJaFu0P+xqMuhXU3sEGRqsrzJnDoyy4tKSVTapBzmSv
# DATA lhOTT2BGendVV+8tVQ+q1TcANna62EyctXD1eJsOpkBrKmEdAvy8qs4pfdQH1eh9bzJCquCks+11KT6xSS+sji3TK5b3BfUf9r9g
# DATA rVAwkRS+bHSA/sKuKpQBVzotpviVzsxBiV9eLC2RWFaNQ06JPPrAW0FIowCfg6yeukAyi/jqiqXS19fOcBRhT7O0NDWkdq3OS9Nz
# DATA 020API82P3725PHmDoZi3dv8ZM8bCa8cRSb11tUVZcZZv5te8CiUUoaPIi7q2tJa+FMQelzFySFGFFWaZHpatDq45jQiOQd0lWM6
# DATA l3xuZ/PfvgDm8jFQqt/d3DXk44ItFsrldHK7juk1JvEcq+y0Ve24p4+v+0bxI31PWUjHVgnrWAZu2kROuhHPNRskt2HfnjzZQtVX
# DATA Uf2sIegBA4RS9YZH60uR/SsAYU0N1eys9JVp+KF6bWMhj5tgQg/u84ERh5FxJSMj0roVNPi4YE11BQy1bl2RGhlbqDhP3Ewtoozr
# DATA bEVY1aChcGmMHy60vlBULhXgkth92iBWQSlJRy9nResAZ4MN10Zf1FhqrRg/T06nNTi9/hvQcTub2wgXbDIudHZ4+8j6SK87htrD
# DATA ANOykfwa6T/Rqso22zSVd0x0GD1pSQEOl6YJKF2+t/3sB9sMWRVl5Q7eOm/5vmr+QB89rfC77HdsQZgl62oFZF3zySimi6/4nN1E
# DATA HhaUOwclFyRIwimFBA5Bf8hpQhvbFZFJ9oLQ5gbS7B/s2JN1fGw2P3n05GsXc4voB31zSoTdIvyVNHjIkPifjnqT/KTiRLTk9S7I
# DATA jWUJ+f52vYQkdELtBA1iYZD2c8yFQkp9tq5m6/M2wGOVJD1PMQA9bFPewug0NUwqweEvXvYtOwHFdco4oMJp1gnEJi3ZOTvKKJ1a
# DATA ywzRMrSjpaIw15QADP9Zq1AGQFGO8Fpa0T69FQmIb6dI3ua/fjPEhPNEI53uqhuqLVfbuuX5qNN27i5cpHzcLrnOBho17E+hsKim
# DATA zxJFX1k0VPUhKPx3Fvzd6d/mCIdn4rdaqxcWW8JNQ95voBRqEkGDZ4EPnu6CmcLBuNS70uguMF/pqGsFz6cUgPC4xMAOUApHXd+X
# DATA joCT47U6QZ8t+d50uaARuuAOCUxKgcZwMKxUvQOvyrrOEA4acXQsMzBVYQe5/dILU4qzuN7XirXg6yhLBVHkpD8eWfgIp2o/WVnZ
# DATA iaSTmRWnLu02g9Zn+JGI3NJStpCMDwYQWMwke8bOKHyiLX4YFW2Zm6W2TWGCbG9ns6jO9O8U5sPhwOKLPBPaoPAUWMfEpUjLBDV7
# DATA g3Pl55uH/HjMDcEgZWepQgPquT0e8B1sJOhjBmevUi1bwOmGLrSZb2P/U6a1CQdeMBOjHVVZIiqx8ROu6VlXy+urq6zqC5VEpwBV
# DATA zOGa5WEf5tA5lSgERV0eMLWvM/xqTjWue8NDaKDjey1nKKWlOScwHCQvfXB5+1+HMUQw5MZbGEiE/ruB0UTJ3r5DQ4pb7vaQ3YJ6
# DATA kfUHdAUdOwa7BjxWmzNtM+cxSyi/h5JSF50qnJFPrcYIV1eePcZD8fu3DUJOgUfFGK/3aqal6mxTVNkfanF2x2+7QObqNDh6XYU6
# DATA nl3JrGyd5bxz1GMhlV6g5a958+czvykZ6DduffMuZ19APxRpzGCe4nTkDFjJ1aszWPtSsukGhgpCIXsgWzNxSkQm5JGb/F3LWNAd
# DATA 2hOyaHtpJ8y7bUUdikLikeuOutG2tyt6u7lpl9oUphlGJWNjXl+GG/qmx115Q03mq6zPklSRRJEwlURRRs+Gn4G3Kerb3kz3aV5T
# DATA 5/QyDqWz8LsLTHHfDHweDZ9fpeBeoiWEVFAW4oBWzX0VUOZwARHImrUvTEHrt5wKAT1XaR+0G958P978pDhRKjeXCwLbpu8ZcaWR
# DATA PAt9lPUjZ8BFxVhIKRbQsVNzUwdPJW6kiLRHPoehISIcAA9AFfcGlxgIKiQ1NF+Bl9F+mg4FfJqMXhGiOAwd4PrZskox5AqSbPkl
# DATA N1GwS9ok8OP5MBT9Ijxz3hTjz1J7dGT59001gjjVuOBa8TwdUWQEsf8I2HyUo50PX+x+WrTzcLh6m7a1wxtNI6oDMrrQCtnSiP44
# DATA DgTSY6/n0/ysMxoXvvJrcsgFmsVCRDX16QmcjA+fPPpezbbgLeeqCvGyHNbCisRkd+XEY4J1sZ63PyxsluRofAebpK0sb25aCWOh
# DATA KBaVXnqE/nbZ8cnYRbT5Zd5ASAyw5tS2WosBwU4u4iKGpavH0bKyQ5ECs0N949HjJ08qHKh4kqdtcqy3AngcTfoqiZ86UtIER8eD
# DATA A5KMV+BYkVOVGqSuVZAhFgakijaS0TGNCKVxMrZOmwLe6Sc02GgPrRczPk/g+4HbCwaoQR/vltNIUT6Ka0/8If5oK1mv+sp7gp/p
# DATA VzsgRFU9VpwGiDAWkT5+oBtWrTnNuKXoiyq2QqlUl0K56kg8IuGOu9b8YNd4U41yjgqgEym9b2xuP9v9dLcWyRPBNP307Pn2s73d
# DATA F8+fX0/ZQ74YcnkqHTJRRckf4FH9xqhQMJCLjnhvJe11pNfquzmJCrno8p5Y2PoSkgyH7Sk2UbyygYlsWdayayL/zX/JAndk5uUq
# DATA vT0zb1BwNht7z55uPWorBTDg2/aL7Y3vb2w9QRNw247nG7lu8165wrXjbWfBDP0sXD37wGAx67ldojjSV9Fr0r5mYsgr96zYqFva
# DATA PmtSZdmPMmmcJ6ddx+KuzrxGOtpUKYImXRYRlaFrtlBEsW92nli9JStnKwW82yj6pFvKlLnh71Nbqbi9KhpkcNQOCttnkZeu4lOb
# DATA nTCgsNz7g3ERWdVgGlOjXIxi7i2P8bcmSpGdc+CN6q9lNUL2j/weyX6/8VwUC6q0sfiQ73M6C3+48eh7L563MYTaNOdninVYJNbD
# DATA IgCVl7EP4A6txchgyqpb0EQHRQOj5Fyx2SU8gsMdmIgwnqnHNM6/GJtdBRlwEiaYRHTaYKmTAqXlHKBk1DlBvUCzTP4gBWCsdkyZ
# DATA KRKJdyBTMAPUIoSaBMr7pmUJEi+nIFIQpt4MlFoonriyiBjTgzG4bK1cYsdQat9m1IviCLUgtGQHzrXXjsQF6YCUni0ekILV6vwS
# DATA Ar6xsU3JmJNlboHDJLPrgX8M7cIllyNYuhpIZaAPrAcL0NLfvt0E7mA0BfBJZIsR8sjCzKK6BHy5QtViFxZ+8ER4xh8hJLlgl8gR
# DATA mtWkzmW3sEgtGg9epUBCDnrdWtRPzyXIo8qSZMeIUPsQAm0LJuJ6ydDZ+9jq2iHzLBRhwiJ30zNcU6uO+3EurpTXmORhn+7ubT61
# DATA aEB1PJwu4LBUrDhZaAJES2SZNXgO3tIMeZrbWYGn7aQlxgkfae1kEizpwmAttdZAtBktKzjanArPagXiywZmzQAkU5C4SUemWJ3P
# DATA fjN6m6tk57dgmkjhJ3XO2FjGwaHx+fk5u53hIQSwFT6pWAA+3Mz3WBCit750LuC3XCGhlyRbB5IN9mnHZB69riwb0FPpOfzGC+cs
# DATA IZbZfQcr6LWqNkXudsyXG1/Qj2vbb0qfJsLNyvTWi7F3J1qZtYK6hq1tV/Z6zs7ZAe/YIDMYQohpoqOsn+UnZfDMkYMKB2FZuXLu
# DATA X5/6opNjWUQmx4UijnEglQhBBitn0DwQpdB1UProQlTC23z6ZTZVnTHJfFIDITEJtBBwAybpgypXU0vjyx/nG0AL03edW19ohaZ0
# DATA rkV70kSNV70a8FZmjshFNLbHoWxyzZy/qm+pl+fB/BqzjhI38yO4IX2ylSs9s7ZIUooX1X/qwxtrAKWBWsl1fHuym8GZC8cEagnA
# DATA qlnwSVPiBpy8O5p8DrUdDdYjUiniY1GLxUWrYdrdmuyBCpNvn4IQ5V5kokPU9JwEfTiGnE/h4y4c1CL9wJsQIPmDq4WbNwdBT8VK
# DATA mQje5Lm5CCmuew36Snmh1QyUtON0xmreqs2bcBx7OxvbuxuP9oyHkYrCHlKIG6aGqNJS7sllHaQhFn3Ogzfcg7lwE2I0UNVCO4ZE
# DATA NJhlJtZLL4ZAypJXo3UOFiwrx+Jhl0DxzHjivVGNvOW+tOcRj8xiRDqTEcmwWm9FQ4me6ExhJ+zTwXs1eTbbr3LH5pg8B8trexLK
# DATA 4BBezgIbqoav+Ulz302enR4dFrPu9IVWpqUGMFPsz+vqkrqcDtACOgvTCJFpsiT7dDhkwA1EBNJWV6+9pmy0gLUUOFly4FF2TA5c
# DATA 7tVyqy64SvHivLiV6vRDf0Nu39yx49Sh49T24qrjs16IoB5Ec0QyU5sbCo/xDcZpyEa3l1rkXwCflA5fE+Q3vFlKBe9Ul8/dHMsA
# DATA e01DNZ0GaFyibwPEqDVSPxBcKTlaUNVz/7pN9+DeYJAWBKoV78MUWFQLXhmaM627fdxmLLy1RVMkPDeZSmACNgikAc6HVUQ38+jZ
# DATA 9zd3PkU38I+ebD3ai6vT4Jae7uzrVZxWcSeLm8O6zhKQpW+7HhOlXZLKM6Hl1Al/k7hRCtzSCMdN6lqOxeaKcxrATT5FErj04mxl
# DATA aImpV1SkEaa0iD+rpcSPrayj9fV7UiMQds3WEPpbIUzflfAgIjRS6DN0do18J4qP0346oiMJFdU98eQ+2lKxqQk2bbs4gxi5Vlwy
# DATA MMnjLOmxh7S6rY4Zjrws90PTJhlhr6+b+CZrmcNN3JPVAN+Rr5cjplE+Fjd372L1h0YQ4uaPJlchx62jbEROJn3MCiUlfHsJpeen
# DATA ouUpT71N8WuaiIh2UAxkG4tdT7e+LhjIeK5b3N28rlsh95G3DLhcDJX7kHWCjmfJLTa3VVkyqnNOtCDNczYcqSdrfQuOUSLf0mBx
# DATA SlMhl7D5RuQomssG5sydhHrqqSCM06OtFYPjVd92BiF34Xn8AKbZGGIgtXR0FrLldUPwKZmBj1Rd3eJCyWKIkLJabNBy0RVkgF8m
# DATA mAs81oNDGZvK6NWMxH/ecuxjxBHQhrw7dOAjHHmnMZeNMiQFq8TUsDgoP75GKx4B0Byckn8I+Zyr4AAWo2arIKdG4kDvcRQ4SlMa
# DATA Nh0OBr2AKbwahBGL6VdsBcBD0xx30CFARwqZWx6FIXw2d3VgObNnjsGOo3Azd8OIcgIm5sKMmdLziq6N+3dBeg2rEhJcOy7ovNzG
# DATA z0Vaw2efMtCFplEVNmAK3k8qZbPyrXLLqIJuiGMk4ogtUs7hRBYsfbXfK9MiZeb/ygHqLBXxzzzKKj0oVc9nVqxFDkLvOUAGR9go
# DATA QAzNewXduWxwoUfnOsy4MMEqZL0/sMGEVUTeHVz7vh72gXrjAzTfIbqR2DGAB0JsRmAWYRFqOdk8/+BZWhc4v0xl8RLhVxQOXzkd
# DATA lLm+7R+4Jm21+WppT78pxEPNr66/OO5/pQOYelRCfD6+k8hLzmK8yVJPCfTE0bYHWYfNiLMuVMyOMszPiYSJeZQIUGr4ldmHxMTb
# DATA RMoU31jNtVpFPF41gsw87Sm5fmVOfO/BG8b/kvSvwVOsyEw5JJlGmS0LZVIt9cXh3NWIguGwbhwSyw4Y6cTFUv1YcbGMb/+rFCkI
# DATA P65PQf8fwLBTrQB8GtY3ExIhkZeO4qaBI8fJCFgc8vfGYS5GhfAYgrm4YMOPUWIHL6ISumPfrtUExVpbc8crATpMJLkrmdsdO8aP
# DATA hBAEsMr5w4/Txui4NzisxHfiavW6hrH4Wr3k9LCbULGmn0msprKEsKdASBLrR0jppyL2KhrrTDGGcvxXm/qQGk/WpqJcw27P4tHY
# DATA VIH+PCBXFnrTEbbNPgfXZb2LOZZteeEASseoR69QiWXPPKK5oGWPo4bQUppbAQuQeV3LbVn3Tc0Y245+0npVyCZoU08C9bqxRSUG
# DATA cQsBuFj4nCCxFbCrKyO+yg6fQ1sF5mSoKrVSNlGlohtSHvIiK8YFa1pw2Da9lXJfwWDpxdrlVgaB4nPzTd/d3N7c2bDUxV8r6/Sm
# DATA 3IXR4lsj4lJVz29CilpeIXanKujznPYRqjFywrmR90Q8L2ODlkWlfGTVYRmnlQvbP00L2KPtBNrPN7cfu/FujTajhAa+ieCmqLgI
# DATA HFia35w2EdLSXPM05zsACkUdzWROucY9ZIjI6+LZhTjz1YWVQhDxtnqH1rLco5rYW+m6BR51296+BC31hS3mzmdb4Rh/JLsLf5Pc
# DATA z/ZuqTn7zIE3Yqe/mdSk8caaF4XJoTF6xpo3Bm2b71z66XiN67+lUMAVCHjL6DAW3qKVmCVTmw6WM1O2RQYUDLqA2kj+ByTsmZvH
# DATA EujFERlCcZ71xsboeIKL/Zy+VKxAz614ixF4dDjpdwGNRwD+kl6EQFahi5wA42AyjmjdUK6FORFwzHlDJ9TFljHGeDuRzipxvW7H
# DATA XUO5ZOu5FhOU1WBqc2oZK84KLEICK6OFqFPr8erVR2zUOd94hAJC9NLhBWNiYgwHZ3pvuEZvUE2OzdwDVOC5bh0ihYcpwJrUoz9Y
# DATA M6cDUw2mqcbPDRx44f7zBS6y/GRKQdVk4AWjHProZHE06n74EkIvfhlFhqpnEYFP1bvJtNlb1qwrzOVPJzCYPLJOJwHF4FLW9NnX
# DATA RwFH4Z3Twjo5JKe7ADVntWqliyBfgqLSohZ/9jqbNZtvvfzFkfqJWcJuNOkDb4YriUcGm57kAFVL1sTRiATXRKlG6MGoJuwjMG1V
# DATA hqMMroQVeJm7nifycrWAOpZmqbECcUEKA7iKqYQgFfqNTH9xPEAXI5/bwjgD+RjY+VFhQMsA8vV11QlnUNRmkqxYIfv1TT1YCGtR
# DATA nSYwkD8yrhR9qN0mQVa7jbvRbosVAg4N6NtxhXAOLNi3bv4fYhXafyU7bAwvv/WO/1uC/+6trdFf+M/5u7K8vLq2el+94/fLy/fv
# DATA 3/1WtPStb+C/CcaOgO6/9d/nf37utavbLJ663Vyu3SZS43Zz/+p21r3dvE2E3RjgA1yV27XblKUCXr/+u69+8tVfvv7lV3/++ovX
# DATA v/rqz7/66Vc/ef3z6PUvo9e/g1+//erP4B28ef0l/nr9+evfQmWL4MEm/k/4/C+v/xEK/6SkVi2Cv38JPfzmq7+BIq9/jZ+gUygK
# DATA Tf4Ke4P//xW8/fVXP4Nh/BT+/i1U5Bah+G+/+mv4+IvXv2xA9yTCut28uq1yqMAgHtzqDigMBCW9ePjyZf8B/oh6QGG1Xr68nfbh
# DATA n4cPTtKk+/DBaTpOKENRno7xI0nP6Dt9wUuLr8+y9BzDIsFPJUHD1+dZd3zS6gJV2Unr9FBTmoB6DsRe2lo2bZ2Mx8M6wvczrPqI
# DATA W6nvYt6ybHxZfz7oZZ1LrwMhwur5qBO9jPO0d/QyXo94yf2X48te6r3LTo+dN2Qq11yPBoc/gu2XT31AWlj4MMnTOozFeoVBWepM
# DATA Zpm3xdWxDoE3/o3oLMsnRPWO08PB4FVE6WqAyj0+QZ7kBBDJyaDXzQkVjk+AMk4ALUb5KRLOzExgQuUIpd3wHtDSaZQmOaonxgNE
# DATA io1odzzpXlLdwaib9THskkSSBYIOSepTDAhJo6aj/vA5iraRvDlC65Hox9G/nWTpODob9ID0e7DIhR6Qvc4o7eE0sg7PDIZ7hM+L
# DATA SQ7nJV/E94387Bi/EU2JZU+h+UV4+d7FaY96tVuiXcpP0nQcag+3oNHJ8xtWIz2fqsZbgSH0C0V+hCWQsE9HDx8sckH4QTcBrwmm
# DATA +6MjQkIgrG6DCmodLksPmqQxvcqG9mi+jegLC+3CB9wdOQcPFhO+bdirVf8QGQtnOka1h824uwJt9JMzoFGypN5LDnlZniLdBK+z
# DATA 40QOH/ZQ0t6zs3SE95jaskrlcH6yNNfldocJXuBI3vvF8Qjqsjt4Hs8Ho1e0N1R0EcYji4oTZtKwi1XV+jyQ1ExmKYao68EaDJmW
# DATA H+6dJLCFQ6SJtUMbHHH4DbRavwHNLz98MIRiaYR14XpcRifJGfwYnKF0FzP/ndAFwFSO9Bl3g8hMPKmDRgR1gW0mczigxOG2jfGK
# DATA XQ4muHVYWQmq1NWFXocPH3SzMzNuBg25fzIOJ+Oxd2HcrfgQiEzVzWEKfC/G25WF9lpB9eCg34Vb7bQ3z6YtwljxnPNqB5ZdXvCi
# DATA rzx8NoqGGQxsMoRFAtByNIFFGQx6uNwruNyPkl5nQurIo96AqP80YfvuiKB91B0l5whx0K4PVxj2Sx+OqDtIeSu76RijFQIHAbTr
# DATA BO8WDBz1vhS4hgIZdQZAomcoBOdVv8n50/NdxAP38MERkPJ4EofujYLTZS8FSn2ZS8B2Te4oaA8KPlR77wzFJCLDOhsE2f8oOR2u
# DATA I71+lnQucUDRf/mX6Ebj511To15EoIT3SXA5IH3T7R+w/R+w/Sxsz8fyDZD8O8bxb4biZ2P4/w8h+HeM3+dC7zfD7t8IcucTaU9f
# DATA I/T/dm4QAfzZuBMg/SBPFQbdUGiTxXnQI2F3hT/tKSNdk5hpDo7EARLmDseKxCqyRbIEnWxEyJcEeN5C0PIQSaNQcE7itF6ajCiU
# DATA /ykgbThZvRohYJhEdpp2o8NJ1hvjDBA+5jxlGOmLHKsQtaXGp2aAPRiM3lH0QO4TBEwODPq9y0a0NVY0XAfzfCPGx4UDtEWSZqPW
# DATA VqRA0kUMQ+JFGiJuSp3IArzreU5xjKLdNH0V/SmcFTTWUsqFk7Q3JFkVDjJKjo5wl5AgSY7S8aWe4aeDycjgaJkaUDp5NJr0Nal5
# DATA iMZO6agRbUqiIVxSnMdkiNQK0pnqFOIZz4mGgQKYQmGARBKAhxzLJL3LcdYh6gbmlo7GqOM/hikkaH+hTNuwrc5J2nlFIk9S7ZDY
# DATA 0xnMf/3J/5bLXFHKS3ZBeWcwhHaInrT2rBE9wv2PSC9PES9gYpc4c2kLa+BQz7CL9BR26kg1ShJXuOtJBrCol9aIDsQsJkgo89r2
# DATA zcjhToxps6EOlNArEpFjgBys4cPHg/M+k3m4kGxZ1oETgxZr3tD4nHKRHIlwGCrccoRwnZQP+skg561Fm8IRkfiv0nRoLnXS6SDt
# DATA 3xvgZeh06P0xNpRhhEQMvESLCdgD28kb0faAyk1o16B4OqItw7XUNwobHeKAT1IFJOD4PEVok415CtC0fV1gxSZwuOmYy21VtzK9
# DATA AGIRp3gOjemlOCLmxdnILRixNlzKMbgHWuN1GcBE6F4COzTKlF9pN8EhNqIPEfiw7QFuyQjxYgqwRY4r9IP+W/SNj5RQ+2/M5syH
# DATA bObicOYkk78xYv9NaP13QOq7RBPQ+3euDgcXQL58hulrDumU1uHNNVa6Aopn0OvVD1PghbPBqJmfQtMn19ju1WkygtPQXFpHDcfx
# DATA CEU/zbNkVKnXh8kwHVXXO4MeVOFXQJdV1xF+NZfvDy8Wlxv37kb8BduqrqOVOYD88/r5KBk2D+EEvqrD3LrXyRU3k/XhgmTjdYzt
# DATA X5+g6SjQeml9cHQEE2o2VlbS0+ukeYLtXFGZLuYCoUtSh8PfedWHu9tcGV5c8yGpZf3hZFxj+60a1kBcc0VDlL5UyQb/vepmOaDh
# DATA S/hMXR/10ot1wBbH/TqZ/DU7KaaJXv8R3M7s6LIu90u9Bv4UiBbEq821teHF+pCJgyasBMDMaLmxjH/XeQeay8OLKAeWphtZ61dY
# DATA aAQe/bG70jBf9Vp2c5R0s0kun/mhBiPg/aif85ju3V1aB1Yqh3aGA8p3ve4tYxMZGFmThr5ianXMmytrmACm+jlbTBWOgzS1TxQq
# DATA 2nLnabeFSueDq8JEafp2A3zEpIkm7Axile7VYJh0gBtsNu7eVbMRHhAOxxEQCHkd6MEMMZBUdV/SofDe8RHxXqoD45ednMK1uHTf
# DATA XsHVxhPTXPU2lUrB2efP6izD1lzzOABeV/aJRSI0DrfyoGq9xK0cHFQLZ5g46eby0tL/6By6e3DoSk4Xdl+d/x6bo4snt3HfOrjq
# DATA sK2qSXjjr1kvefwy3BW4musyVPrNh7heBCJw7er5yQgemkvXTnNAqx9cqcEtXesFsVZh+f0laBsOW/ZZ2iTKCdDUNfFH+n4fj7Lu
# DATA +jGAocYqzcy5JktLXLpBU9J1yoABNXMfW/Hvv93qGrR6hFkXYP+vpu6Rmt1yY+WuapUXEMaVHgMWv7Ibvr+0pKssRY01qHJ9slw7
# DATA WamdrNaGAsLr48EQqp8sM/Tj7pC/QjKZG6phpmXEd6fDykpjDbuu3WvcPTuv3W3gQxUg+tKajFTWpLreA0oIjgSKXXEA/BVAAmXW
# DATA qNUbS6t3oer6aXIhc1i+1zlZl0EdDuB+nsJEV2nQK/MNbpnBaW0VhrZCC49DW35/xtBgLCt3cTndvqnnVe4ZOolk1aHFVb9Btybd
# DATA jGtcYDW1e/c7J9fZ6XEtPzvWp4Yyoa1b91UOSDIZD66ZJ66RnQFjdLkqmC5ueWUJDnINGaYK1ozq0T2E6XogjKTslmaeVR9xkbgc
# DATA cP/4PE37dJKXG3e9o7y8dFeDFb1soZN73SDpBa/lfV7LNV7LleJaqlVbWYIDEcRDwEu4EyK4QNQD/sMXb0VQK/29JnHIzFXw72lZ
# DATA 71HCmEuk+i0kgQ980qOpKZV171peN1AadIXBE6jgUXaRdtc/q5MMBua9jpeyvoy7vI4ZN2ClcaFLQLQGCzhPaplR0BW2gjWvG0DS
# DATA DBRwrHPOwHu4dy7Ug3+0zRrC3slpP28uH40i+F8ZfKMLSu1HDaAcoBuaK4FYRdaYLV27CxeBSx9lx5NRqglJ87aTkDTUaqfx/srI
# DATA 3E+cVeN96lZYidln4X2v/jLf0YYQ/N7S3F0yx5pKh8+0VCaA5A5h7stkLyqA7wL4u2uPkjqKABi6pWDpcOeu5tjLUToErrCyWoNz
# DATA DptSWarBzgLYMCO6bnSSUffKwiwW1rlHqN4/hflkdIQu3DPoi+nkKPcbDZvI/dc7J1mvW5wmFWmg+LzWOJ0AU3plEwj0BhrC7/bh
# DATA +YDX8BzN8m1q4IPgnQqTz3cByK7B/1bhf/eQtPL2ic6nswEks3OvSwmhrhEMNuJBQ55zsz8+4TWprPSrkZpL2U6sFKm264aWm/pn
# DATA HcAATAuBhC4SCTXAC6gRP6JWxPr4A1tEWaWF5O6/j3eb3kY28ru/hO9hPtl4njMKiykQR4EX55ZQUpvrBsoWNLW38nWeS+yJlDlF
# DATA ElHhlgaTbze4gSvBG0htsTHglQOsmNyz4XwkZ27KGZCZEf5YC3GU1l1YZXB0fkLOkgitmsCUERRVI2rCVMaXeo6ECRtstu7Q2I27
# DATA imqW67fCYEXJIgOU9po9u6V1LFUnBY70YuSYvexqDnLD41EAcgDflHXSK3tJfH5MXUd1PRjvNnhTgL08togoPfSlOdAE140SZDeA
# DATA H5zjkDhnI9JPK/iENF3xQtg4xYXX0dJ8BJo7ymhoIWb5lANy7x9feXIDuCDJsS8dYdJ2ytnUG7TCTOTIPTPv3ysylSVX8zDxaFt1
# DATA kwq41aMLfBDOBIE0GTFTiFWayxaftbxGkJKvglloX3jTTfKT1F3g/ZOs2037B84FusXpAZP++Bqu25WWg10Q6W7zRsgfmP7WZlx9
# DATA eynfL7vYntgt6V+eoxj6GnUjvMtHyWnWu2w+AhJrAHi59jJ+kh0q2/eng/7gZVw7hT/UrnvnYS27gIezXm4t08r851FkKVeeVMoX
# DATA Wnn0uuozcrhbusLCRM26rusudqQRrwjjY1pctdF9iOicgwD0j/z7ZpTW7bPOwF3Er1LAEWsQpzKffBIgtpFWe5xoyXFoDLNerz4a
# DATA nM+msoWmHqdDvesKjK6ZTwjE9f1fEwA9RhEeteffgmv6pDYOQGQvGeZAlcgPm4G2TyAh5vFJbdxltozWoomjcfDoXIdxPI3Wum7A
# DATA CNIrguQMwJvLi/Vlwo2WjMgiGphmGEzGw8mYPBL8xWKeiqz066i2CVCz6J6WjAejK4V2Q7Qsn2gF6PSBvv7j07SbJRWLRLsHYK16
# DATA VSp0sCUNq/cQ9opUwb0tQpMUsRMdFvaiQHaXl8k+M8SflvKf3qVcRc7VXkqXn9RCl7sEq4k3uhExpojV8vHYnYdZyFVUNrgc4pzL
# DATA UiAYytnylSMlY7xrUSmq4kObl7KP54pHPisytngu1lbpXNAa1hSVWzoeEsuw6IWw+gdmcxyGYoXFdMJquuhh/tnPPV0CIgH+hwA5
# DATA HCU97yGpNPP6KO1OOmm3fjqgbeFHuB0hnRg1fqd2p8lGH/AjOcJ7k/SzUyMyMnh+nZQiWeCLGgZ756i7yNewppRRvsCD6WPaTSE/
# DATA LJEva+osqEBUgPCGh8CfvtLchl/o+trRGCqrLbQQhD/RxWmvT7pPtMtrLi6en583zlcbg9Hx4srS0tKiGHihAdGHgwssuBQtRffW
# DATA 4P9J7YsnPmIDQHimlxEDMvM8onrLK/j7CFAQ2UytLq121z5Aw8eHDyhcCVkLPV2+Fy1/cLK6cvb+xytrZ8tLJ/Dv+x8v3/vMqXz0
# DATA /7L3rkuOHNe976uUQ5bZrUH3oHDHNGcYw8tI3CIpbg4lhkPUhwKq0CgNgAKrgO5pjRlBSba1HXIc7fA5cRThOHs7dsQ536kL7TEp
# DATA UhHbL9D9Cn6Ss/5rZWZlFS6N7kH33FIi2UChKivvuXJl5v9XG9QHdXkYUSyuimY0QkZPnsgOTeRpMs8pSEZqfxvfmG/GoorbO8Ev
# DATA vG8u312nNj+Zq/ai8618R4/ZAxCFvBZ+YjbgWVnSrXqNRtOrdxterVkd1as1z+/U9+rVtuc36sWMCVthL6ou5mq77tU79R/57dao
# DATA VvP3uk2v5tPj1c4R/X0HQTertWJQ0WDgcx7zdOEBp/9bjWaz2ozyi3um6OsLL0WoHf+oUfPH1b2a38Ar97pdjoyKiOdLrbjkG2q1
# DATA qldr+Ed+rT7yfd9rdn5U63Z+9m6j3vXqPlWfWmfkV9t7jfaPaq1OMXmdfjcKgoUg203Kle7Qr1XHe60q/XOEjw26XG90hr5Pl5tN
# DATA +ueIPpZi3mv1qo3Bspg3VtZUtX2RKuotnCx8pDzBt1QNP+D5/S3VWA701PbWt1rNVq+OC8b7RI/w/w6MQbN4pXbrW5EfNaP2gfKx
# DATA 3fpWs9tqt5sHYmHc+lZv0O/08QS7nennsFWvhQeyvH/r41fuR4dJ5P3wbZoufBgMyfas3OXtYxl1hXtZlMZ4VndpG92O7mkfuy3J
# DATA ZMq79FtiTXq1otO5I4aAud2MRmp+892I2nQcVCTo0tLcQdkRBuOs0t5vHB1X2uII44DVTrlNpvdr/Vs0Uy2GWHaU22aeKpjFB7QP
# DATA vThOFO6aFqxKMTn5Bow//Rg7iR5dYHkgXwsQD2DJLBKnVfVixo0HF215I0bRK1BdacwWUltZSNp5xp3y7C3UMTYbrtJS+XSxrf8U
# DATA Tf3jV7B7jzqJuD/jneQT3gDp/SX0xbzbd8wWyP1P5lF6cp/3BSTpTrZr3Wtuvpumwcn+IE3GO8ufuzsa0aPWs2ov3/ejE0gv6mfQ
# DATA wvexHZBiy3NL74b38Su37AiOozFOZwt27N1gusOBGlY4yxk/iE4q3iAYjVC5d71HOPBP/5UARCaf95Tdl0iASP02ZfWOFakb0Cjb
# DATA PTBUYaar0Evno5H3mrcjsdgfBhletkuX1BUKSq7csiJwy8PRT9EiYLH9A+9THFXuDylW6g0XCRGPf2qnmg/VS7IVKvaRfjyTx/UP
# DATA ByovCunPVqS/IvFGLZkcxoMTja0y2YItNkvSMsDh7sVIBic7mDzvmqKIIFD7lzsfv/It8fx+/AoFDbGhaARE6z7uVqcz6EZ8OygF
# DATA OUyOV4YpxuiFw5zMxztxuJun5r35uBelOxzmxxD9o1/3dW4WHg3VJtIdkXND4KJnQW/6+BV8vUnNOZ4c6GMucsbllTz28xTR/+EH
# DATA 7+zLjssf8PEQ+g71Nu91aOj9GOH8pOI9QsCfojDk0cBuSPL0W6OI9TI+fiXgbAj2sfsPmjXpCN90fNGaKMa41B/F/QfUprD19MN4
# DATA HCXz2c7OLto4IpVGR2RU5JGicMB9J/tVZYVEBesbuhQwm8DL7XxKJtjQvDOYIOEoGzzAQnhjCH28dUSRfkdprVAY2bw3jqkgK150
# DATA xMV2hx7jj/tQjaG/b8rGrB1V1BwQTcdpKvQj0Dvi2cnOLoU/wQ2fqqj+JaL3YzlwERxFP6FI7tODbwX94Y7a/MkvGpHRnAUiRse9
# DATA C0UIXxGfH/9EvfEvpAeMM/67wzfQG/VzP/6JLiXKf+yOhy7nroQv109YyZLv36dRZTQPo0xFI+8Q6Vd6n9kkN7urpe1RwtbWN0Tt
# DATA PjfanROodZpnipUf73yNKuZ9SQ51MPIZ540+PdBR3ckfX1I2XF/wPp2cbWSV/rxBdlAC5C4yqmlqu3OEWIAdfNtbevst78f7+/w5
# DATA rCy7wxQUWcAZksnx4O7VSoxEupBF6N3yZ0y2mn3o82moN5MXNvCrfH9dbXtfvsf9QJ6RsHhLe6a2s+NMKBkUR9E+t/BP5d9i9TYL
# DATA XsU6njzMKzjfkulio59MppiHVxehPExlaEJBISKQBRvg41eW7eSzo8W/S8T4o0SAi0GCz+uD/K57Yvm2rIryyRu7jioTJNfIteyX
# DATA ddG+peLyMSQ8x2R7SG0zUVhVc1bkp46Aqj36K9l3k0OaDML08diM98x76WKplunWsqJeHZgDFctrFqpNXm9U3dH5A3PVjND8TfXk
# DATA cgON+jS3YmOMb9Hfy929NM23RcvUZD9nMusTc8ivSS56f/M3FGtUCOq/xjv0J3knOY7SNyjzdkwWU0PIWHxNv7LwNFlJSDjXa5yY
# DATA oPuqB57VIJCpxUpHF+yqwaKLEO+h63anWYxNXhM5LbveX/2Vt6Ojdvu2jgkixQGZKmDy7fZtlRTUX9wiy3r05r/gKEhz44+7kpYb
# DATA N6SglLGDlUOd/fwlN3fwbVfuyIOV/EDvWM1HJKVUJGWIG0wg8tuuuqc0fEhYXEs5hlHGAweVvC7RJY2R2xHaolUpkBxTjmsbcOEh
# DATA ehHiqKopZbIOZLdY43Cjsjh2dm/fYZvx41fumUNhaCY3dmD2ffyKND1K/3fkO88BubnPknvYVrdT272BBP/v3+9/TP+bvKlnyUky
# DATA Y1erF8w8n2YsNyQAPmxGAdBDy99DxtPN4q35u3x+13/81npQR2iD5/pjadwyA8wPZLqD2e5g9nkHs92B7Bf6QLZX2G6szkE/0we1
# DATA jeeMfy6cABxZx7fvT1ktDyNbHAI2ok9v57fztmI+J/dsned+Xk41nifcYjtKOf7icb7zKvW05WaoF8kQDbNS0ZH1LmsFTy4EI/5W
# DATA PKheXrySJt1PkLnyppNJX0dD+bHv/GBh7YvNVLIHSgf/rWf4C6eDM2B6h4v2FpU79GCovGAPpbMTbCo2z09FNyAbBnwiVtcoT224
# DATA oGkhH0ee92hc8+DV9TAHoTA/4XjwLqU4Sfe9H0yjCZ/zHfDZfXpIHebnyupRWEPUOqqTnmxDYAwT7qY3g7FAAU2UbsCGyjteycet
# DATA dQT4PDFHm6wFMrIPcS7NyPB8H8ecUeFwupuJDt77c+Pu9Sa4zOpH8o6YfppPYTZk+x5sKf4xY5MqGcDJQy0mhKWmmg2ZywlLAAzm
# DATA KVkR80U1hBfzsK0JwVlvzno7z3or1jCnr+P0dS5qtq00EK9Kd+c+trBZchB4DXybEM4zCjxPT+Nt3XCJ3X2eLVdXsOR4/YPtDyyK
# DATA qC05+hoXNjohsWPZJ6AzWXkBd8a7r4pPVDfACa9HoZAkNPOc6a7yK+wV4+0f+03eRKQ1rCn5vCEKF8cB7zdqqs0k0ZR3H+1Lz36T
# DATA 41iKqnghTHXAtw0iqp8y8TQXTDTr+60tRlM8I/Sz9tLwhVfF0aoipe8xkTIPvZpwh59HroY33/Fv1aqv3kyUVVi+p6nuaa65x6+q
# DATA m+hDftdNiVaeFGWr69xUq2D0YN4MZrbkEZkN/AQbEumY3st7glU61WooRi9dNfNL0vPER/yiKY3TM8mBmxIE5k8qt2Sd1g4lv6R3
# DATA qJkrdyyDM8CEzOoAbGkqNhql2c8pVRB+MQbluzQYUv8sRqP2WlvtH2NsNOGWz4aiGWjjVOzIfe9uGHp8JlaZBZkePnMb0nsHayhK
# DATA 1RMTATPSziGbLo5eNkrFEKceB2/ELgx623Q+GvGPcyzD0qAep9r4/2EWifKOiNiI7k/ciymLRWJei0jpOo8F24yjQGYJDAs2pdET
# DATA YV4TZ5gWUpIm0vlplSu210cQvrd6OYyBvYj1MjnTuIOXIuHSePGtZnsAdIazM5zPM5xLBpKznJ3lvN4cfgYUKz+kt3HjyEQzLwhV
# DATA a8jN5pJmIwYXo/PGiogPohkV6ORQpO2K0ovCBEsGGLcSJQGZKyWKHmLZSC75Z7FdUUpBbVl8dVhn/Tkt5KwbO8W4Li4zI1IJCwb7
# DATA lKC3GEh0WQw7GQyw/QsyfdwXZN4wOaafPSohGS45r/c9ZVxA0pJid4RxF/1MMuCOgfPckq8UnxUnpzjozQL2Zt5NMVyNzEhnUmQn
# DATA 7R12ygV9snEgpHlMPVaeMoy8ezxlkA3RjDoNRhlvF4OlgyQeki2W6V4tpMIbUm/GpcTJlFM+FMKERcXhRiTT6VDmTmLEaH9ZMiar
# DATA cabUBQNYBQ88rRSyJp1vBifcE69PKMpQXJUoY53G+8r/OIgiSlYYD1jaj2Z3MNQgcIg9jNiHQNVqJlswmG5Mv6Ap4hc2Ab0PGcPj
# DATA MV8QAbJlxUxZOAapKuqEGIuuNz+RSn0yQ33GJtE1ifwgypYkUMyKQhVeFFQ1VZ2sVPZbHkMVHpVshCbIo04aLTNiUaQVbUeC8BaE
# DATA Mc7eyUAndqoSk6Ta+wH0X0LKRLIL2fZD8mHnzcmY4CceiMdVu5QZUobaPZZ3ij2pp9Ja6nQQp2NeHFk2t+VEfUh5I/NxMHqnOEZK
# DATA ZpJRW6cWZKznfPE7E/+13E/5wdWRTAE1PQ8ysYW5d/Le1eKe1Lsy7IFNaQXiNj5kajwP2DzG1IAMXyrpYD6L0W0EKet0jZXyJKuf
# DATA SocCLpS4jclCwHU1pViZ2u9PkmOpn2gl1ETQR0KwVSf4zYTDn2FfJXJb2iIlaApXAneNPLaJXWL5FdD4qZSxpSEeGbhWytOFlIqb
# DATA so9sJMowSSEVOQ5IY0dGsKAgW+iGeYowOSmryZr5hC0ra9n5YjO/gNb+p59WDENndgg4b3piE3T+v7Nfnv7x9JvTfz39QjFyvjj9
# DATA mv7/+dlvvNM/gGlDP3xG//5mEZ3zP+mHx3TTY9zP8Juvz359+oVHX35nIDpfUqBymb8CtPOLs19XvLO/pefoGdwGes439KavGOPz
# DATA 9/SDMHW+On189isdmT/TLX8UUA9gO46l8xzMZtAp4/gSdTg9+jMriGYfRgmFk8Z9bYLte289nI5kfB5xjxhJ35AN4yn1FiPLG6E7
# DATA R6wiTqPcZ5DPhZLRSI1P9FIt87sWqoPlRBWeaikOrVOc3+ge5LrBOstK5urwOnnVMbfCpMsvlx8Yid60ufsd+c4j+pYJOzyuqWE9
# DATA UZtbMZg6wM6GxbZ9xA7W3iO2PlE4ldzFyMYvcg8OmSyKCobpkMYTzkeW289mmKmWditrpCaCMIdS4tkCX+f86rfaobmkZT0tzM75
# DATA yXCcHWcJXIUloIE7lzQAXhLn5rUN/lcy9m809F905L+egV+q52I+5AyeZ691XQWMx8oBRvEUX70kvYsgD3rdeKpWElXhUZ6leKkC
# DATA 30SSNZnKm4qnJLC9dHgyG445FDlgwhm0KYJHFVm+EEkd8YjxMnOs1EIlfYbcnin/rByTGwRHCUYFxZrRMcYLBG7Cwyk9qC0Gda7u
# DATA ILcXhFgE3w/MiONgMrPdYv1k6hg7jrHjGDtXydjZdFTZaJqzqZV8zSb/ZSz+bRj8jrbjaDuOtuNoO46242g7jrbjaDuOtuNoO462
# DATA 42g7jrbjaDuOtuNoO46242g7jrbjaDuOtuNoO46242g7jrbjaDuOtuNoO88SbafWDC5L22kPmoP+c0TbWVx73oi5w7mrcg+7Mj1+
# DATA V6tVUEhrNkq53mh1itycKOoMFNgIhxspen0OtN5iGZA+h1qTYFgqw2+0ihCfOmX4EjRSu+E1alUPdBu/2R35napXa5WoPS2/2ez0
# DATA Fkk5jbrX8Ls/8ruNYaNzVKs1x37b96o/8qv1YaN9VPeLUejXwkavtyQRzU41T4Rf65pE1IsB1Lq1sLlI7KGM9Rrt2lDlokXPMQ8s
# DATA 0HNal6DncI216DlU+Qv0nGajE1yGntMMo4Gf03NatZbfDg09p9/pDcJuTs9ptZp+5+rpOaqO73E1NuNCXQg6ergt3LTMUVXncaTS
# DATA PTqudNiSKqwxNfvDg41JO+W3KQe37doSE0PdhaMF28Ht2CEu4nbURLNjjFWU8QHv5BgGYXJ8q+rBu1H1dEkWAD3crhdfod3uxjRv
# DATA y/pJIddLNxXWymQ4L8FwDlbsB1gcrRQlaZmnVtZt14Ssuho1tOmGkteMhonf+a5U1WespvgUSvscG7GQeXZhqsToyQusEEfZcZQd
# DATA R9lxlB1H2XGUHUfZcZQdR9lxlB1H2XGUnZeLshMPxH7Dugdq/CP7m9Sd22rEVAOX/Fbhurh78KmF6Xkk+YbMuM3B4NSRCeYGPQH8
# DATA zsev3Fh8h6rUB3pAUS9ZvDG/RR3QoLvYzj1QkKD3cIxLWj6b8qMTPp2j31qO0r731+oMvHUojQ+eoaypQpko7Okb6IfX1o34W8oK
# DATA YzObpPLi1P7s4SxPM/WOH7/yjnXyziSDukuVApnols75uCPo7gj6xkfQiwfC3Fl0dxZ98dTgSr3NZ+GMeqmOF1qLLU7Dnj8WoEVl
# DATA znK1FCV8G4dRkBXQLXwiGsqWIBfxSJNRdybnhLWSCm+lK52W3fQMOieB9RkxlrM4n5IEpVfBhToVPb4eyy4ifksOg6pdVov69cp2
# DATA RRXkT0oNXgmH6x9zPXNzhbfbQv4z4nBM9OLMyurVKu/GIGZpdPlc1Hi37jDdp/3UgkI7LEoc7kSHJvexuOsqQXfVpXJY31WfV98t
# DATA x+tZ5Y4/rb6T+1wlM9uPVt8n/Tannz+tEZWXg6Zazl3sUFvNHUPMGi33Qk2A/9yWdc1/gbeeuzo9D5BPOs/LeVYS22S3vukFxKrm
# DATA mpfOOTf+87f/3aSjHHEr/6csUYo+ZxRMc/1VtZTIe9LSOSQSYKMlLMUwgRI8a1FDrTSmWshQpmA6pTrJ+rrUMaP10SR2MpPj/9Bj
# DATA nUH/SOvQslY1L35okdljqtzqsLjyedktMz/5rJtGfrDaOM5wWSXF5Iw+ekkX2BfMNYXutUAAZdXWCxVRXlEvWkB/979WF5Cu9FI8
# DATA b6MYqCJnuoA+PE6ojabUsXn6lF+mTBDqk+YTeCJpSJrue2/TKA8jZ5wciSAFpYEFByBscBhxt4oCkv3DqpwirW6hSuvJS8Wk4NrK
# DATA xXQLFy2Wf/yfq4tFdTFSKiIH2k9SmoyYljNRE2G5zNOcHmu6sq6yfPKmARpWKKaDKPgOqA9PjlURFe1IlmZns7gwDlqX4xmM6Ccv
# DATA JTtF11ZQeb984R7uN6tLSvfxUlQfBenY491deRd3jGsCxwmPoIVNJXNIBcPrF+jrIhnuJ6FIaUSsHgud6WgCCI6UgJoN9CImd8Qz
# DATA 0eTA7lj7Z6ZOPHn55Mm4ttJ5khHo//7D5iPQGxhko1SGBEsHfMx2NcUrfaAsbW5SwYjVywNvPKfxZxSk2Cc3hXwyMtr7kRiPaoAh
# DATA EwkMA2k2KPEnL4lCdJ+HpvJPmzaV+8lg5vVQ7QOUTt6tYYzvURaNoWUDzZg+jTyYHLAidBD+NMD+HFXjMxRWyvZ4PI5HOG+AnIJK
# DATA BVnqn8xjUauBCiILq0gBakXoLTSVQjIuVUBFI1A8mrYRaK5Idt95L9G+R60pxLMP5RNMUqEyYoBOuBPXBauEf56EHfRyiLs4OLdz
# DATA pV3CleY8Zy+J5+yivO5nQt2xsP9yPbZb5tw0kM6wVZMsykN2aq0kdz+jKpDPkWjaedrQ9r7Hq6B4L7aSrbO8l8qIriJ6L6Zc3WbU
# DATA scX5gknQvucbSWx2JlXEdyRqkMeJcVzkTiZF7VMO4TGg3EbmLy/oijfPBF8KWUAKBjsjJAlZWQt7Sa1R+txcJ3M9zUtpgb8HT9fk
# DATA ENBAAYyLbo+RAreUBTX4Rmlm3TJyojCrc1FRW0nUY58JWawzKS3Me2B9e9iIC73No0J9kM1sklm8XRWaqJO8wYt2oc4t5PD+y2Q8
# DATA 2kE489GZjxubj3Zdc+uwbh32Ca3GlUbq1azDvivcT1spOicePh1SxXVQwnnvD6oXHxssLHOqn3K8trp1Yb0wX0jKl8dWrS3ayxv2
# DATA as2q+0uO9tJSwqqnCu7fgk971RNlN2XZzbrqubL3rOwVXLlyWigF3mSFmKI6hXHI9UEWml57VctXqmJR94JfLntOhSWuzplq0nl5
# DATA ERyHzDV/z7aoPM29p07dtqnEZaZfvQFFnDcVjE8KDej5RYhjoWnGJNQpevpMWarJyH5LNNXjicw42QSP9EzKQCSp/ZjVqjmbChQa
# DATA PYPn3tQdCfoWe3j2lEAITwCMya6e+giWuPQ9su4YimuZ95VTTCDcjQUa9cTNZLHg8nnjcqdxXtfyvYXgeOo+ikq6VMLnM8BfHCvZ
# DATA ggOyFFIyLrAB/7uC+H1z+jX9+6fTx8DwPfbwjbF834D19/XpF4DyLdIB/9fpn5n493t19+PTLz0GBf7u9Kuz/+P0j6efn/2Cnv1K
# DATA BfqlQgh+efZLXKPfvjn7zKMvIBIKCBBkQsRBngOwkLmBf3YwwOfB6i/03YPomGwHnkRPA0jXKggAevXxAPIRPUh2aQwIdXxYlb2r
# DATA sLpJj5kHqnvu6U5L99nzKb8GTYjDIyOjL/6TaDafrkUA3oXUhRfOM2x2ofbsAIAFe1/3EtfN/1sslquj/7GFxYSV/NZCfSvzzG9G
# DATA J9E0jsja0Pe/pS54UBkCQjtJt4wBZPUwRkLPZzz+qzNa1MQcCXDTItw+CpD6GiyCU5ufxAN0OgyDZ4gztsulyUNo6ER8dllMeRis
# DATA qIXUufVn2MIwZ+l/+TFTm0/03hNd0cSlSpY4M24wjYsPJwtYwM2r5WpbZ6HhPS044OaJcZBAZyFsz0LQaMBLGQYvhxPw2oyCK7AJ
# DATA NjIJLmwRXK9BIFW0nB3GDHhmWtVVIAGtVKvlrxVR1HAxdl88OPEO0yCcBwr6l+WrD5AxLK6xMWqwuChxIps+sTR/xK4nrLWxLGI2
# DATA jfoY+Y0pthEc0IzrrMxNCc5kHx1l4AD4Mq6Ae8lgD5WT+1mqQ/seVGxxfDYQywE+OibgqTgothqSP03pUsZrqaq0lfkmi4QcWb7R
# DATA ZN++914EgJxckE179+cwQ9Jkfjj05hMqppmcYecXZw4j6DCCDiN4hRjBjYehjSZJFzWor3WOcJkpwjZnCI4q6KiCjiroqIKOKuio
# DATA go4q6KiCjiroqIKOKuiogo4q6KiCjiroqIKOKuiogo4q6KiCjiroqIKOKuiogo4q6KiCjiroqILPDFUwakfhwL8kVdDv1KJG8BxR
# DATA Bcsr0BsxBYvwvG7Dgue1qwae1y7ma9iPGuFgCX2vVbPpe42cvtfqrszbvGDGfrXj1fy25/sNr9P2us09v1nz/IZP5UVXa22v0ylh
# DATA +dqtbqfXWYblK0SZ92EuxpdeaCEP/baJb7MImKxGrX57yfO1Wi1/vl7NkYmdzZ6vyytVfjVreX5t9nyjacW/buX3hu9vdizkY6Pe
# DATA vuj7/ZZd3n4e//qG8bfri5QtP97Y7PFW206+DXvcMPvlEZX8Vvei7y/mXnWD118EEimNREMipS+zIJH9dhC2/SIk0jxiIJG1ar3X
# DATA 7BYgkbVeo91q5pDIfjWshgMDiWz0W51OI4dEDvyw1RlcOSRygv58L3twkq9zyBHKo2gL6w41y9WhbS62H8xrtUVYMH3kZTSbwbR+
# DATA yR4WleF2MPvQLira91Yo9p3aytmMWFmIqF70UFxEKUF9j8qSR5vm2n7Lohp6drao2zy9q6WYN3rWin3yBUdrCei4ZoeC2o8g6djL
# DATA 6IdxdAuil6spjSYfKqXkrjH9yoVcWVte7EwxRSb24EI1EfOptklOcQiOAukokI4C6SiQjgLpKJCOAukokI4C6SiQjgLpKJAvGQVy
# DATA EeI4Dg5vw9SjXh1nzCjJN+WrPsmCTFDIxXdtRQG0qhv0NNWFe9gQuePv3vj4lf/47T4TD+8u1RngZ3Yk/GAqhw3wRgpm14RTQzj/
# DATA +3MJ5w20eD6+NA4m80HAOv1yqkvOI1JznsrRNxyqCgS5ED2kG/nwJ5kDGQ1tBUJi4YyOO33vTt+fc/p+yREudxbfncV/krP4K/U4
# DATA r/SMvigiJnwQOT/uLcPKa0af8+nLx1yHVqeMdpBRNVEY8AFZZXXujMe7ipKoW+iEHSC5oJ8OwnRr5oJRtGw3i0qS43gi615VpTrJ
# DATA q0BKbxL7bfjX1TxFMyjbVeWi8bYCMVG3r5nY15rLIl+zot4pRLy631wddTPe21HXF1U92gmjwzSiqfo5KbDCMimwr5kUtJZmf93O
# DATA fb+2JvNXKnTqVoIaLR3E86rOaY24zEOkO1NpzfqIe8Hsw7xptrzJ0KtiHFnvneSN3L6BRfZFPl+KO8pm0pXIk4JnNFUiD4Nv7p0I
# DATA yrHQL2ndAdav0KFRP0JGoDIQMd+bitkQxpj78WPQEGZJjePgRAYeKU4e+zMtrHE4D2jEmUURS4MrYYtPqIMj8wtH65UoyJIYbSDg
# DATA +eIdWC+Nis6ydpb1OZZ1yWhyVrWzqgtW9Wq20rOkfFVsBYHJLyN+9UPw94zaEVaxc60j1pOBS7xi9JsEXRyN42zKEjTeh4auwsY7
# DATA 6+ZE8MwdR0xmrXh6zwZGpWiKZfyUHkH9KVvURYLjgtiVuY+G/nuxkj4aJmn8s8RI3igF/8DLggH4OlFKRhFLMJlSyaZJrpDOEkUs
# DATA GqVmEVGQnfDIO0zGEUR5eDZBdl9FOBkixYN7abSmgTWGCcGdVUa5hVUEpQaOrQorpgwF2yaMdNzfgTBPsQPE1gml2gMeZN4hGpto
# DATA PgnYsKF6te+9Hk8S1CF6RmN2tSEwiR7O2JDkJRVkkOpHkwxuK9XDKhNIqsCYX2aBQpcZE0vT9n0bjDBKDnUKP8CJZik3qVaFOVuM
# DATA BVmof8S5WJHhLoiE1+hEqeVzj589kJqWjxt6U6TIv2as/zqAVDsnQiuSMvSUcWEenwUDbhvZO8vWJep9kfOSVhGdKMksjNTTMXdh
# DATA kkZRBRP52V5eHuwAzI3TYGYEw/LxiPKCKiylUSacSk+Jsgy7XEfYX8JVGUdoUrtCn2TwjXNsHlIAMzIO4xA02H3vzYSbJIY/o0wG
# DATA EThlMA7Q+aVWbBYISGxZnav7auLSC1Rhzy0FfbOeYpik5ooMEidyQYvsq8lZ8Xn+sTj10otThWlVladAqj/L+zImFkjNzaH2Smb/
# DATA id7nG/LEKDhR6PCiqZJRT7jdd9Z4CGVcTxiPpf/Z7huwTfHOe3rsQJqm0aQfj7b7Ft7D/ZZuQXoJze5Bt/u+pgAsBpHZM0QNj23J
# DATA CbW24rtuzkdXxqB98eZXjkTrplabSwa7idQLP5G6KHr22ZIQNnt6r4JhWs7srRNMlygdn88vHRUICqIBzG7Ioq7wGrzus6Wj/DxK
# DATA iG6IW/AKG8u1EZ7LrUq+mMnG/sLkOJ/2VrxDKDTncxrMwrwAE2BstTLz0D5NgW39WFFtxaQpm5Vmpbk3oeRJ0Pa3COgWai1ZL0fR
# DATA +ULSqJPjYKpBDhuVwZISfT+N2KNeUMPOoizTrMKXyHTLCVe94EGUFvBW/3L6BahTZ5+dfq0YVH9kzNXnZ/+NcVX/7p39HTBTp79b
# DATA hFv9M2hVDKQCx+qzs3/0Tn9/9uvTP59+cfYrCvRxxTv9N7rlT/T9F/junX5jQgM1azXw6hfgWtF/HdPqeSDZUh3G83A2UAVjCeyA
# DATA cc8yRJC1FfNIEMI1Ably1TlhTiYujQk7LbhfGigwTyiXEvRxsr9WGHnUc2Ts6VqLsHodG2jRTiJ0Fg5gZRug0glcN72qXCJXx66C
# DATA JHRYeu9SZBVXMXPjm1zhrgZWRaPeVG36RS3FJuEkDE54HyHVjweRA1adV25b51S9jmbAJTCNUpwVZcV6HMcbMGBbTl96ZLtDy0St
# DATA glhb8PR6P8TyD9MojCN4o8EooD41SuHtypdTVL8YT8gcmksOe+N5Jv2ZmGEnQvXux9NogWK1SU1dbc+Umt7ToldtkgjHrXJWwKWt
# DATA AI2pusTg/1J4nq5p4N/6uL/RsL/pqH9dg75UxmLqzSD/tBrLVdCnikn0htFoCuuEDA8gmE3k8gSnw5PZcIwVWUn6LRlqIfSOEy4z
# DATA /gC0NLJFVkepwwTN6G0y8IMjGicznR2pSJvx1gOsyaZz1lKk+I9jwwVaz55SuyPgYYqwRB3xmS4ZiDn2KwZzcXFYBgHjiXgsyMSE
# DATA 2EP7DwvmBe8D1JsoFAqIX8ICCkBN0T/YUwE7T6+Rz2cJ5KH6TOpygCkHmHKAqasDTJ03jmw0l9nc1L1Gq/0yRvt2bHZHknIkKUeS
# DATA ciQpR5JyJClHknIkKUeSciQpR5JyJClHknIkKUeSciQpR5JyJClHknIkKUeSciQpR5JyJClHknIkKUeSciSpZ4Yk1ao3WrX2JUlS
# DATA g8GgGfafI5JUceV5I46UnSm1lldvdz7Za+z5nY7nNxt7tWqN/vqeT/80uh59LeZQP+r06s1FHlS37dVAfap7frUz3vNr9E9DfS2B
# DATA oCiTq/3eMhCU35WAKf0xDdwafVS30Ev1ZssqesVBEihREVwVNYKoGS1EtNH2vVqHkt30/HptXO/s+Y2m+rYQz6jXGyyNZ32xflWb
# DATA XqPZHLaq/rt+o+Y1Ov6wqfXiLAZWs1GLlgW5WGNbDYpp3f9RtzGuerXmHv3jd8Y1eg0VSwef92od+rL4Q+mlnU6rXuuveelFUEfS
# DATA QjTqSBqbhTrqVdt+LSyijgb8Pxt1RF+DQbWAOhr44aDn56ijdo+yKjCoozDoN7vNHHXUaTSrfvPKUUe8w2SPTQ+bJaQiW5x9+hgJ
# DATA PfkvNXN7MmAzjWRmsA7ywyNX/uYN6EMFJ1zLOOFk6W0RUGSFveiQ5xFWts3RQ9GDTeFE2tKolQPwLjBer3ls/eC9EkJklaDtC/TE
# DATA hF6dnlLhtlGqbVW0xfxZnRxHEnIkIUcSciQhRxJyJCFHEnIkIUcSciQhRxJyJKGXniQ0UBwhPnpFCa4c3x58Ry4NT0JZPQTsh4yb
# DATA SmZ+ygK2KPnqibl6ElGPrC5r+tA9hMsEocENyqFD5gN9RDGUi8dFEJH6/T4Fzz9nS39+ewJRJBgL9D6+72TpfR8ms2Ak5/v4rneD
# DATA 2XCf/QY7gxvHN7IbJ+pmmzOUn2RxR6XdUeniUWnrXJM7MO0OTK+W8nsGDlLjTOogr+bBiRfg94K8+YyVT6Q+owSMRDjqTQU/QzZv
# DATA NEqO15/1HccP+fjxNE2SgT5/DJ1x01Bp/MVWlHkaZU+gbU4jYnqCpMwoS5A+fdzyrpfNp+hUo1C16Dgz5COybBTYKKUBD7UTcnqj
# DATA eIZFnIQmDxkrYQvIpJ/Ox70DaMPEEz6PnZlD1QM4e4/4/O5HcOEWFExS1nQXBe2snyT8RH8+hcy2nGtep6D9BmyI9ET20Xk8ROVJ
# DATA G0BkHSqACJJLdRJFYaa7M0lvNkvFXKZyHCajkM+6IuaUWJoDsxw4SmWA3w4pyqMTFgo32WbKTpR1WCYdp9K1KjqnARO5UTJD0ulS
# DATA LzkeecEoS/hg8FqJ8HtUvbnpyLFtemuUWoXHgs09tjY5u/TNcaZP0R+jLqJ7ZnGfEc73oh/f91hRPe/J+9iQEkEePR7xyVycjc/2
# DATA vTdYrZnrrqcBNagOFHmEitQGITYCcVjmGKJS9Q9m54m6c85xnI9pIDG6gtiOivPvHo7S4GXUdIIxv44GOi4dJQnfn8+kcLGtZqpO
# DATA A4tOvDnvjSujWFG4UC1+Bpl6huNkRtH8gYQn/hUOkUzDkZ0lsTnPHaTjy+mavy5C1Mg6avwXFjZHI9y2svkHyHwU3gDOaemdrkDQ
# DATA PGdbiuARioINUS/XI7gCTXOjzMhGzUS1PXSzGPOuQOL8Lnf7xlZSahLXpwT+4hzkzgNxMwo3oyjOKMpVyk0r3LRi4+nDyunH1U0r
# DATA 7iMrchyOREdPKZ55bcDrQJSKI40us+fL2zk8D4upHzAdlrmQ0zmqlwGSVldjPXPXHt3yPf3F2/n2eZG1HzQRLlzMKZ6dZXFuNK0o
# DATA dzclqLK/kQklo9kGsVS354hX9b1gUi1Ezc7MepGQuiZq4vSknwteyQ0iqR80sTQXcrt2v31eRGvrIroShCrzV4xWVkt7fmmo0tTi
# DATA rCh2ZDRL71HfQq3DOzRz8YrX6nzbM/XWG5NJnXn1hrrnGP5pmuXTRDo6TNFR8lMamYXpt3Cz+Ebujvir0mGTmamBnMasVhv3TVeH
# DATA N0YPZc1ETxmwDIZJPcIqSZmxPJfVl2kB20xYZfK0rEJg0p9PSyR26vRBpFXQNqCcvji2t6PvONt7vTffGdovpKF9UcrOUxZC5R3A
# DATA +QbZRQPUhtCw6GCgPdhGL1SSsJpC81TlU58LWUH+75aZRiWh120TjRakcpfyjDYQr7X2UecStvgWQbgyCQYVQ9BhK2ueDZWBVaqn
# DATA 2CkuJat2i786rN+5l8ZYt8EuRfYi0iUw6uOHsGHY+y/nuZh2GBfNHZpAYhYYLVt2UaqaImQq+qTqIANv4VImT9GAoWmp5VE1VouJ
# DATA rh3v+1izQszJvivFXGR3zaIKxY7XL0ybEI1RvSyjGKQ4Tobt2dZqEcun8tITziKuiTCa/Yax5WNtk4Tpvxzf+1gJUgt0evocFcVR
# DATA g+LCHi+ZjMyqH8VRwSexAoFFsNURpZcty9eXRrvTIgeR4dYHh8diB/3T6RenX51+c/bz08eA/pz+8ezXDPUBPejnzPD5jH4DXeg3
# DATA i/CghYdPvz77NXBDPz/989lnp5+f/p5+/BUziL6sePTpi9Mv9+iJxwja43u+oXvoHYIWWgkTotDxls/pDXSjAwo9+xb1D6FfxuvE
# DATA 3JsoWthJRRYEcUk6WrU7NY0OwV/Wcs6y8K/qqxncUxZtLlCmqTdeyxB6YxiIqoElGe44QpZ1rbqE6yYJLSuXq6MJ8YaAYTI1N36k
# DATA LixnCg3ivJu+F8+MJ3jLNCGBGrO9IL4ii+jzsnOENimxrdOE7noCXgcIfG8270Wm5MWDH2MP7diTneD73rsJ1YCJASFSIR5B7x2S
# DATA HlgjYA0PmGWB2uwS4PNINn2kcB+Omccozjo2vgTWCJHYMjxofZVcbcQsaWdPCx20PgkOGuRG+ouM9JoTdMkB/uVwnV3X4H4lY/tG
# DATA Q/vFRvarH9ilWi7mQL7R9fpay1WAgvKUQUSLAsgW4zyDxw2bNfXmPx3fuUk7H3JinIguQBBgYv6d+SZYAmPaitoSym8ZBxNKXWbS
# DATA Lak1wQtmaDylLmwy2wgbBPtqhoP8yAcKaZBSb5cP+rEs9+uFLQTDYnIMMTIEoDSSrDJI5BMBKleskT4B5icZCLoYL6KK6N2fIdkx
# DATA ezzigUet6oHQUI6po8CeQbRB3mCQIu+0Q9TRgxw9yNGDrpAetNmYsiHU/Hyb95qN98vY7k9qujt2kGMHOXaQYwc5dpBjBzl2kGMH
# DATA OXaQYwc5dpBjBzl2kGMHOXaQYwc5dpBjBzl2kGMHOXaQYwc5dpBjBzl2kGMHOXaQYwc9M+ygqDqoDmqXZAf5nXq/WX2O2EGL684b
# DATA 8YMOTZJ5F2GRNRM2o3BQXcWaufNqP05h/wvYpyYJUWCfNos0sLyB7yvCUOH2VrVxzu0W54fC9ugej37b87v0t0r/dpvfo+sjv1ul
# DATA ay2v5jfoWmuv3d2rNWrDRvfdGoBF7c6w3Rj79eZeozlsLYtJo7Yq4gpgdPOwUIEaNR+RoTeM93yveiSInjXZGA163dZyRFJ1oXpS
# DATA nJu16rDVqL6LVDe6zaNGddyoNvYaVfpURhB1g3avtSzo2sVpQFLnNQ1Imo9FA6Jk9Nv1Ig3Ib9c7ja5NA6pVG51mWKAB1TrNeivI
# DATA aUC9QdgIQ0MDatbbvU6U04AGg/6g079qGpAySpY7PnRaS7aWGomwcW1vvRXi0c0YdvJ7y+AfM1FaNinSbjTMdSuN/Qbzf2rM/1lc
# DATA j2oVI6WNG6ubFtuFE0I5HqR7h5gag2dRDaPDirX2bn/2at3pw8q36tVmu9Vjt99uZXVI3QsGpaOcTaP+RalE2uaF93DBpLJW5FYv
# DATA jqulcPEJ72X0wzi6FQbpg9XsoTyHK3bUV9scJbNX6hDbTo4k5EhCjiTkSEKOJORIQo4k5EhCjiTkSEKOJORIQi8tSUiRfj60jnXl
# DATA 57mL57jKGB7hBskpb8ojTRfCjgA0I9B5+uN9hvm8kYxZAH3hkDcfb8NSkqhVBTiokkzU8TUtSFs8KCZtVCZy+qSFO+PszjgXjtq4
# DATA o87uqPMljzqvFB+8miPQ92LWuuCztOyCLJ+e1UehnzW5jevQ41aDC6oO1VclGY5U7vTH50k0m2dNh5VfMSLNnaXa3E1bpNn3q0WZ
# DATA 5uYaqWse/CDponovvvCq2LJGRVnuyQWu9UOvJtyZ2hLSLV7u+YD6PoUX4nry6s1EiQQueaLF2UVji3fTm6XRA9aKPPexJr/INgPG
# DATA MGhYPrn47E1JzQZC1W/p+okq66HKPr8q1e9GQTaHaDQO1vaDNBeovj8TST7qSZJkJjfIsWbI+gSHEHuGP+qYxqx974c8uI2iI6o0
# DATA 6ADRqY5V2NyMFZwmSY3wUJqQObnvfcALAGIayQOst6iE/Wg4OUFBU0HEs4J8NWBahWP7co7US+c4440j1wEO2EPD0Yzn0A8ki43q
# DATA LBd+RrOzeTaNRP+QFbODyXyAgTjFXEoCBBcpjAcDXJn3WE89xjhNgTF2Z5mtp0QIKAmzjQWuX5Rzvk7e2pmvlvnq7NWXwl69qLb1
# DATA U5bs4XXtfAF2vbb1XRqN2GhkA5Lt2CyXomCOQrZG4/q6xX6eC72Lq5C1XqzXW5e2XqrpdFl563zRX5tjYlEo2ycCWZTrXC5qzebP
# DATA CZk0AtTkpSB63b73uugG0SxJxGqiYAIT5SOICIncS4bBjTGjQnDk6gYziqyuWAs/kw2XkM1DRt0DeoMmhlys4vxAC7EYVSfjDn+5
# DATA FE8KOeOMIWcMlfpU581z3rxi37nSinrKgobMAwa4OBmNRGe/DOxW7STIcgm/fe+ecLrZSlomz1fQ8pumST8KQeMWKbok/WQeiS/n
# DATA Sfjcd2MDdTY03hmNoJoJOI5ngpqWkdRjLReOwZwb+WEwP6RR8wMahjUtsMIBiFkiyz0K74AOIxgM4BRjV0nu8jTj9NsTjPcz4dfO
# DATA FS0iGveiECJoYdRLaUQWKjIPoSwCiB1Ka1HWMvrn8oyCAw6oKsAPypqCyjTItHUB5Tj4a1JxlirxabIBwlHUC9J97x3YT4gmVVLK
# DATA 3ECBwMIAHQyQCL2RCK8NWRhvmZAhf8ws1UJxyWagXn9CBR8PoPM2jrD2F/fXwsiHrGrNlWcygweHvcgmyR8BypEMBt4hDVk6ibJP
# DATA 0hvNKVP7ARQbuR4Drx4cByfimNLxVGWYabcOZx+PAxSMijnlSyYK3PAvsQr3gZI1hBRmyicLVMU11bkA1pih/jBvxOtRBKKVXmeV
# DATA ah5pZGyBTDjzwXOhaghOmZZFZkxCiY9BJmH5p3hEP1e0H4oTkMN2+kGanrBy413Ks4D9diogIcwLPE5zfI4CluTLM+m9KOZUiZ9Y
# DATA qV/CJXeYJKHlbpe3JtTQaDQcSFsrFuHlYN9oyyes+kh9zGsXhn0jbtuGfYtdHksDV/qF8QTg+Ci8Auj362DeK7lQtXXkChjfH5VU
# DATA SK/kTQz3fgdNQ/oYGtdkW04mxJztvo1PAX1kKIlYIZoGceo9gLc4WEzdVRLFX4ypjgWXSYI0PIRv3cbL/A+FkfmGoS6gw3zhnT4+
# DATA /cPZZ2e/XuTJ/Avd98fT3wnyhe9i8guoMN+c/ok+fs4smccVz/BlHp9+dfo5cDWP8dOefuqxR18/10HRbfTCX5z9UsFlKB5nf+cx
# DATA Y+Z3YNOAQuOgMs8BpnGimV0LvrhplAABrUbumQhMv6Hna+L3OORt2xjkFDSMtXtZXjgnd5mBj6Knh8L5JFxLmbnLt+RvdoyZwmzO
# DATA 9AzXTZlZLJerY8xwAs1d34WQOOX1aFC+L4T2swF6Yb/vLA1OtomWoTaQkY2dioA5zTRgjfFMDAXh4DLri2rrVBnTCYUxmfF8Yk9M
# DATA HTJf8RRE7uOHHtcL7wPeHiBu20Psj1y2qVzYh9Bo10rfKLNJNGNNc+z9oDE8W2DIrKt5q+2UhTb0tPgx66Lv6DFuSH+iIV3jZC41
# DATA kr8cPtnrG8WvYBDfaAzfcAi/6hFc6mI52fm2yafYYq4CKVNOaE6WMZoTecwpN6NAIWbgfmO5AXi6JlSkmazWIhmGnyHDKtATR3HK
# DATA uBgUlsbKUMqDDBdxZNwQhbEaKgPrBSAyJ7C22LcrIR7KNjNME+hjbyQet8M04vMAku16q5vyrdPoDykE/n4uj+QA4z9nSWrZDEXM
# DATA SJQ6WIyDxThYzBXCYs4ZMzZDwp9r2V6reX4pTvUTGeeOD+P4MI4P4/gwjg/j+DCOD+P4MI4P4/gwjg/j+DCOD+P4MI4P4/gwjg/j
# DATA +DCOD+P4MI4P4/gwjg/j+DCOD+P4MI4P4/gwzwwfptVu9BrVS/JhBoNBLRw8R3yY8przRnQYO1vqVc9vtof1dv2o1m18j74Xc6TX
# DATA brcb4WJ2Nmue36lShraPao3W9+h78Tmqm52e4rJwWUpZScGdCIelVtCVaHSLZdxolCLSi7rtcoC1Wv2yAYbVbq3dWgiwU9tuDOsN
# DATA f7sxbEjV2V4M7UKhstxCHlqFcsEAV5SyVShbiaFdKFuJoV0oW4mhXSh1CXx7LeWCAZ7fUrYSQ7tQthJDu1C2EsNCoTQb220pFwzw
# DATA /JaylRgWCmUbMSwUyjZi2KxZbblbLGW/XgpRXUhV7pcH/1ZUL6G4Wt1G0FgKS1sGHWs26xZ0TMJPDRLMMlJ0qAv8tFrzyQJodrpW
# DATA AM3uxQMoJKHbesIkbBbARXhmYqNpnpmYexbPLGi0GvWoyDMb8P9snhl97UaDAs8s6oRBL8x5Zu1eq9VsGZ5Z2Or7QSfnmXX6jaB2
# DATA 5Twz5fVQGxrMTEic8WRLsoPC8l7oRWozP+vwSuWSRf9iyGWO2XcjMmLjoCIxKe1FWRKc7YjkRZ5i6Grd9/xomOnL8l1y+naaHB9G
# DATA my0VNTdZnLZCLa862z4TXUeKbueaTOQXVg/9urVIrO71a0UvjK6uvMdyGITJMS/EYMWt6uk6Z+Vtlx0WPCs2s7kV++n0JFbldnU1
# DATA A83O03M8GlZuleokT5ZrDoTmQGgOhOZAaA6E5kBoDoTmQGgOhOZAaA6E5kBoLzcI7ZGq3TEV3G2FMsNnSnSFk6Qu4ugeMkJuF9XN
# DATA 29SxUZ3ZQdWKb1cP4lf5iYP4xo3dR7jItx3Eg53jeELWFdlhJ9NZ8hqM+A8AxRj/iMPZfaRb0PQ2g9YYBLLTqHUb3Va71m3d5Cjt
# DATA fof/qCj0bsMG/CHN3us16Xj93YMweSTvKL9ip7d78CnLZu70flz9yZ3b9K7dA5F8w4Vvc9A3/INPIzLWlRacFRfhv3GAOyoeu3S3
# DATA Uh+dzmnUU93epxI9VI7b6uefJvFkh3srykHw4dAYbqgfZYF2Zyeo9Kg4ghu9ClmPuSWvUjuKb6+0ZkcxCmYU2xXytjQPKjd6k6SN
# DATA Zo54Ldv4MiPAAXK0+ym2EkzCnVG8eyB5VPydV6Vp4q664jt+dbd4A4ZgFZ83cO++nJ6myvapRtaZo59OWcUpqywqq5jDwE5dxamr
# DATA XFBdZaUo9hWornwAOS6tADJKWO+DNbuM8MrTFfK6DjodmwJ0VTxBXjLgxJyDpVMP5T2S+l5Qk10g0vkWkK5l4+j8NTA6Nl9Q9fEB
# DATA 8w8URQlGp+7JYXT6oQVGXEuCeigm0mqWHI9Jb8G7ft6dvqgBkwV63o2ssPvhcTSiTvSce2tVde+ETODSvZuj67h6o5VziT631Lrv
# DATA a0aDjEcZWQ9RaKT2jLwOGVlGFkfM97LUDpPkNpPtYREbL0vmKVi+A8GpQH9brEZoOOR8OvFakJE4UTI+lMQTTx26N2Ix9M4FtZhh
# DATA /Y6t/0NpqlPBjHShsEVm56a1UVeVwGgj2tyLoBiSjyXO6HRG56LRmVsXzup0Vmd2rj351LT+7jNqiCPJLm4gR1H9jdFpgGTjuJ8m
# DATA lgTenC1UpX8XUOua9EG3WNS+M4Ni3qLUYKghJSwl10/G4yjtx3oMZMs1jbDSgo0LG2v/ccqmd+6Lt6p3Ap9ZhF0mGEYNQEnYvzSY
# DATA Yi/FEv0tdd5t0URV7lnURP6kjFNlc+gfcwPIXOGDz0CnRRyOip8sN4jgoI78UtvT+HzBCVKfi5andYfpKO2nFgw7OE3RFsCakvvi
# DATA dXagNs7fZANu1V39BMQNai5HfPMb+dfVz3Alwt3v48Ma61IGZm3hiQvVNkkwSKwx7woljD0f0qDV0c4c6UCdkmF3sMdaVndUXtp5
# DATA UcIB8W4Y087FGcy1KZ3z7bX//Oz/bJlUlKOtclaZYkqqkipIOjsRY4zsOx6ZwOTRliQPQjTt24PdFfJ80bsbhpDGo6eFBdRHY6Pa
# DATA zxNF5ieDvYIH2fyT0ZGJKJqYDNuU3rLvvR5McirgJJRJqfx0D0QYvKRepUHWUIL0sZNL5Wup9lwiexurs7dQFyWXYS+LDU8JmQUj
# DATA nc93mSdDg8S0IrmmJ9acawE2AczicWRD2aajOc+eaX45F4ueCUjKo+/djcfIqwFZa9kQsCo2vXHJr+HrNMnYRN/33gJ8Ea8J46w/
# DATA z1BAHJIsSm4jl017u2j+rs5b1XJ1rqLHp653hg86T9/E3p7Aq//Hb+tgJYWUJ1g8mIBnfgx8ENWtOeUdlYVM8TPPpwLtwmkh6y/9
# DATA iOYg+9771GXT1PuuVGypviBAMSeJzyt6cG8ceK/bd+AMobhLeCatNnnte9+jrxFXZCr/rVXkS2fx+h6ikM0f0UBLkwwKItV5bMzZ
# DATA ATX8PdFzyllg0A6k+oXKNJU8lBWfTPoCuRuVFH6aQKHHMSGUB9+DdilOBmasWxqYQIKJhlJV5GX0G5ZQJG6c6YexSJ6CR3YUJ9RC
# DATA 1MOB9DzPRufRulDn8V/nMa986sFbF4JkMNVfGuNQsbkCsg2kDSOZDiHbvWwUTyk/uXFw3wLQGU9veqxvqj2CUFDFqC5KrNw1eYfR
# DATA TIqOsxALiVkyjnDhcB5xx4Gn44lMVKhfmm2l+7j6we8NHpfARIpN1Tbdorg1ZseJdMiSteiNM0FoilByFKc0uh0jFF2PWcY2Ngq/
# DATA NF1H009VyydbkFWd8U7qmnBakXrrIzW5o7DxxDjBQi7PHdBTMHZCuhfYrOXMLZorsmxsmyvmimTWHWpgaoFXCwnL+C2momW+UnMb
# DATA csOTQtk/j/X0Irhc8tmWc7k4l8sSgoLzsrz4XpaVDpRniqhQOCqwOFKObNaCN4pnOOLMSiiMxATFUo0m7ILJH+TzJJyxTxvB8Cxr
# DATA lZ/HT7IOfsiqJB99ufMqdaTl9qaPvheO13XkLJ91Ll8uBCPpDss4iYUj6dJ++wlqh7ztZNLXUVEqj7nfzRaz5/JYAuawnuMvnB61
# DATA EjOs3bnPNrmpIoAgB5MTs2r1veQYOOQTVXde8/jCHN4psqpe896g+yPqTGEMwQjJLeHXMAmLx1zhJtmxzB5m2Gjn8dIx6+/Hiuiq
# DATA 2VSA0QZkm4GPC+0yMrx6ycNogRdVrC33YgZmsgOSsmPen1EipdhfhiUnm3OZMI/bplz+M2Mp/xXIybPfeCBSnv7+9MvTzxcJl6U7
# DATA /5wDL3F/xTv7OV17TP/95vRL7+xXZ784/QJP4N7HuP0rQWDS7d+c/v7sHwCv9OjDZ3Tbn+RWx7F8Dkw2L2O/f6oOIJq+HonmyTn3
# DATA BPue7Jb3srlMWGVDPnNr5UFuwBgzeDBhj8BEplEDTFi5wcFPhqWFIW+eX0OxfF1kwASV4RCWRRNOGv11AyxLRXJ19ErYAUdWd68q
# DATA HlPQ5afyE6oKmic+UFUSVXACj9hWgZa8W2IYZOyvAfpHOcqVBeOglpuW4Nbxlndhlx6KrWLY0RXuNkM42DQgyPRZYmi/GQ8GcR8b
# DATA 8rFtWXbcRJoBrm+dRBQG/ZyKu3+BaLlRHVxtlhRb19PiWm6UCAe4dGP9E4z1Gm958SH+JfHQXNPwvu3RfaPB/cJj+7UN7VItC9mQ
# DATA Yy6fWru5CshlIY2YkgfFhGFbqSQAwY6nMxkKpym6HnDqhkEv5oW/WaZLjZ44PMQCywOqBpnM46keq2VuTLdlZDYj8CimConlLyH8
# DATA ZVD8SzdFXCIbDRMQ0waK/4i6epxhwxqIQjvq2PO21wWspKpJewVjQRaEOJYskYJQkIfIAKx8ZnvTKN1jq45KYD7mXvbAMhNwI6K8
# DATA RwbbSrPBMTAdA9MxMK+EgbnxALPRTOYC9vD1mfaXsey3ZNg7OKaDYzo4poNjOjimg2M6OKaDYzo4poNjOjimg2M6OKaDYzo4poNj
# DATA Ojimg2M6OKaDYzo4poNjOjimg2M6OKaDYzo4poNjPjNwzFqrHjFz65JwzG7UfY7gmIWV543ImBbqzW/mlMV6kSrWLmV4XX6XHC8i
# DATA yxqdVrW9JMOB3WzVho3GeK/R8PzOUFBnFnisTCPLwWP1Behb1YprCam2ENdqa1Vce71WpxksxLVWo7h2WtuKa9eKa7uzNq4KZrc0
# DATA ro1eh38txrXuV70a1d/txLXe2UodaPc7rcBfiGujus060GhvpQ6E7SBsLdbXRnebdaDZ2kodaLc6vXZvIa7NzpPXASs4Cq3Rag9b
# DATA 9eqR3/pep4THpQ6137wcxI76Ug2xk27Zgtg1WtRtdDaA2IWDZhFi14gaYTWH2DXbrWa7aSB2/U4/6vVziF292+y0a1cOscMeqj1Z
# DATA 3dCja8Pi11m0ug7bnPn9F+PSlZ2u9XyptSVOVw6Zz6ls5kttrfOl6jlhHujiqozyNetpBiYKasrVbS7Q4eBTw4KT/KfOvxsuXDyh
# DATA OuV1hAwnlaFRpNOpWrOMsnc5YpysGKhF3KVFYFx7ZX/BSticVQJrbNPFGuP4co4v5/hyji/n+HKOL+f4co4v5/hyji/n+HKOL+f4
# DATA coYvx+qNCiXHPk9K9HfkKx/eo6839a8CmmNj8+NX3lLH/0JzEhKH9Zhkxky2fhSPdjh0JquJfma2/zH9b3J3htskWPWDArCpbwyH
# DATA 0eGGNOH2+ATPksBvlkPhYKxHMx4RDO7M6SC6g/arD9q7A/Yv8AH7i6ofPjMH73PH1no1RBZ549OsExqhyLKAwPKQvq/TQny65/Sf
# DATA sxOr56nv5I7Kq9BGLKkQbFkYsazjcI4q4l0F6GExBMpVakMZB2akhd6fwxvDOxi8wzmgYL2I2WCBpfoN3QOarGOc9u7R1QQi91r9
# DATA UGSiGNGg1BWo3iZawFlOlHNVV+INyH4+U45z6D2pEHgadS56OJVphVKZLqserlVSKjU5eK9t+AWrbt9PaKQbqtPqsvlVi2+/F0Bu
# DATA 0cj0p9FxkOJAvRIUPQ5GcjQ/UBXUGyEhzElgB3ocpCJMIZEvnoeeBSyS+oP5DEkyh6DLGuWLcdS5bKgNEykJpthwB4FNGB6+hFFg
# DATA pNSDjFUalLBWwHgaPq0ez9ZE721Qby4QOfQiJmKWkIauSBDAzKjwg1QBDJJRpniMhqbDwaQPvGP0QhxfnLZfE8n35TVLMvElOrFu
# DATA h+JsZGcjl23kUq1yslROluoy1vFKa/zK5Kq+G3MbYCMhUEJPWsGGcuyBpV11zZqI1wEHFucOQ3BgPaYRcg4qlevxwPox0zuZCznh
# DATA tlE9DxFcr4ohuwElWLxOQPYaBxNfYpcQXn5OhPXzJsLmQh7h5vIISxxVlP1ylKur48yuMbvqomrt8Itvimdq99xsLlKY9fc8zrWl
# DATA cW5eNsraYUY3vLvc53ZOjPMATKStS1ZeL422FWtVfXSkm4U4rwQivz6PR6E1oqG3eH65yO/KMCyjezDloze8gK3nUgaczL0XnxJR
# DATA 6lCS/CE9FIHHddcbRMfs0mbH8cx4VKGDtURI/jBloToz/k+iI828MhJgP1T9uu4KAVwLgEXH/lk2yPe9vyZLIeR5D/WMVjdLZn+I
# DATA nUGiuqYZmeLKlo6UGwulSN7MpgemdDTNEA5cPFs1ZXuBjXB7dHVGuDPCFxzVC9aWs8OdHb7OrH52ZGPVYKebAfvA0BZsFXjgdmis
# DATA Mq3wKB/qlERpJVcx5aHGCJxCrxN7qzDqIPCpSHZieFVORLS5gQBRsnksmBk5DLJKc/XS9OT8pdywIYHfQ6XQswganUPHT96Enzxh
# DATA HyqeEG/q6jvFnSxTCHxaQ07WbkXL+QeK7bNPUM5z44IYyQ9XIyR1vgpE8m7Bcw+XNlUZQGnTCMVUAqam0SHlmPHPsh9WkFj0nwHm
# DATA zkp9lmpkxjfSbZNZTBNmWYHgufK+90aQpicQZU0mRfd4GjCzka3WWXqivMQsyoo9kKlEDD7zZKL95GryYDfSfPVHN5F8dcnsgZRR
# DATA fk3yTf5qFUW6wJt9uWEGYJyamcgTsULzqnzBYn5rdTHrRqGK2Tj98yUZ2WvBPYYu6HfQxcLICYTJmpLFrlc5MgtZL1oAohTNSy8S
# DATA eDZKjkcnIgmdsrIxOleMRWaph8qcN/ChgxyaXvGJinB90q6tEAu9zAXL8YM1MOO8v9ItVtAjSiI5jcBipSFnEioxcC5JTQLL22kY
# DATA BzQLHLOBOohmJzSezpHHsXJeBbolK9yYmczzoguNrjkfLTNLODT4PsSMlH1u7AHDAmEswLUnbpvrEnpt5XrpPvj+xn0wVdgZ3SJ0
# DATA 3cibMHs7e3Cy0P9qto0UK6waEZpmI2MYjeNsytrX3jvcYwbsJRgF6SFkpaHMOMk0p/44SaV/lbYinesgACIZboGttMvlqXr2u9Xv
# DATA bdytqrGL7CvI6yOpgRqowkATrE2TlHVvdJeJNhbFDoW3hU/HQRwHRan41vHhBK4emYhqCxOOFZYGh9GZTlPWq6deV4qZ47GNtrdB
# DATA wp6LrvXNC3WtWtYdhkmYBsdoILw7YRQPrIVq5VzTdyjrIQqwLZQyB7L3Yu/Y9gxmNFxY2uTpz2f7Hrv8zFq22h7QT4Mp8pyPhOr9
# DATA FNpD9mTlujaFlyrR6wV4P5GH9sX3KeYIzH5Eo33cz4oIzC/OPjv9/PRPp4/PfkWffw6eJbCVf6I/PwfH8uwzfXEZFvOb06/o/1+c
# DATA fnn294y7PPtbhmL+SZCYHPTv6cqvmJ/5JZMzvbNfnv0dAJpnv2Q6JoV9+tXZP1IQv6S/v6F3Ugi46ef0wx/pZ7rnD/SSx6dfn/3a
# DATA YTKfC0cptqWhu1Ldoqp5HHR2S3xRPIT1aHpQ4e+H2OwOL2ofyDoFajkK2HMVmCmC8bkGHrxw/eG+99bD6QjmC3WmKCzEWhk0uTrw
# DATA Wn7mGyMav6QlIn6OoGn7UHWfcd0EzYVCuTqGJldKcxe2FvKauvIALhA3qWrHibn9Pn/1INo1H0EkbJsAzTiTqMB7KDsbI5z5DcAP
# DATA Oolmjp65SdldATmTV0l5tTweY6qL0EwFUN3TLOIjan3UYz7W770bBdlcLd9Sjs0BhWK6AkqO+krje86YM+TN4lGkXNYp+8vJQArn
# DATA o0Wc5mZVcrWlU25rT4uouVk6HFLT2QVXYRdo1uZlzIGXYjn12kyB7VsCGxkCF7IDrs8MkHpZygUbt/mstamr4HCWks+Jhpua2YUm
# DATA MmX4plYozjPnCE6MkeJx2gdpOLd46dko/+UAPv02ZIb4cjS+MnsQzfrwe2+K48xHfMtioMhl+fA/FjshxL48qEZBoYbi60mIfLKm
# DATA YA/wwjfFLQn3lB8f7TzLeB+Zx3u4xBbRTkUalZBc8UcpWidvlGC3VWCW0Rx606E3HXrzStCbG401G02BLmI0X+cU4DIzgG1NABx6
# DATA 06E3HXrToTcdetOhNx1606E3HXrToTcdetOhNx1606E3HXrToTcdetOhNx1606E3HXrToTcdetOhNx1606E3HXrToTefGfRmvdkI
# DATA W7XLojdbg/ag8xyhN0uLzxvBNyn0mIZFry8yY13Oy/6J0A27ecbWGqJDxb/UWkV+YTccRJ3FXAYTsFYf+rXmJ3sdr+l7Nd/zq13+
# DATA U2/udRoe2cd73fpec6/d3fNrLa/W3WvXPL9NX+rFwmh1Os1uJO8oxrnWqOVxpvflcW7V8igLWdSqGM16K1pEWba7nt9sDzud0Z5f
# DATA pei1P+lSZFv1vRr90Ors+X5nr73XbO75jW6ptvhRP/JLzMNeKxgEtWXMw8aypDQk9n0V47YFYWxYSSnW8bDT7/eWEBn9jlevdT7p
# DATA tPYalJJ616tSmjqeX6t+skdlUW9QCn2vhFYMonajtTRuzU47jxsFbGVz16oZ1SIt0m/0G61LkBq56WlSo7Rii9RIcel3NyE1Fq6A
# DATA 1FiLOlFokRqDVtgOc1JjO6yFgUVq9Jv9Tv3KSY3Y2763zqShAdfycYltbB7SlowNJUQqB35pRtzofNvDv2RqeGxu5EHo8dZaYpRf
# DATA 2Zzc0Otfs+K3dC7BIUJQ2Pb5V3E3z0G0aXpgGeAFV6gq94uBFcX9lUMhS3nSpDyhf+vyb2G1qtE02Mh289tLCY9iLFKaZc6XL5da
# DATA C1jLEY4rUY3nVgZtTy6vBZIpNbv4Ng6nVDQ8iy1NhhwH0nEgHQfScSAdB9JxIB0H0nEgHQfScSAdB9JxIB0HchCgcd/294SnKJuO
# DATA AX8ka0YjH+/r8+7HkfJnMu5xR+EicQFPSFCoqvew0W/HZyRjfyzsx0Igaq5qhSJXzg9GRGQhnqyO08tRe28aR/1In0bEGTn4D3so
# DATA jyIHMj95406Hu9PhG58OLx/RcgfF3UHx9brbz8wB8vvxQ2lCFRqfJidY8o/lkKUNvjFHHi3RVDSZkRzqxLMPFk894ygo97zq7PQA
# DATA ocjJzCwYRReUzzaqluJ65CZONydjuEbtc95OOXsT5WzeUcJVER9W34f+Erf9iP6u0cymQXEm+MP35ePzoJdt8uCCIpGvrxaJVLkp
# DATA ApGv4xTnAMe6MSjlepDYLOOR5U5VBefBcTofXFaa8pxAwHMUD+QEczJjCkTGQxNcUAjGG0RUj0YwiGjCksjBY06JJqI8iXbmZbPk
# DATA jQ2z5C2tCUpjss6Q14MRdAVYq5ejS42JL5gz17KEw7Ki3gDeZXoaOcULJDyvA3OOhmb8oSZI1l8sJ/MR2GQbGaPbwQXz5Uer80Va
# DATA lKop85Atk7yOTIKU5qTehOa0HvoZBoNCuhULEpAZyOE/sGi4SkUTIZRBkCBjjgh9nqK/PzrRxs1TrCP/ZcM68n4yZw2Ln84P8/zQ
# DATA atNTrT6djAfYNAJMA3UCU0yv0CCYZqQwRiGZGjSY9SnjRsNkjhNv+96HmBCwtgIrJYhddzgKfmaEOp5QfTbvCi+YP++v0Z7Vnark
# DATA EM2vvam+JDn0fpocoQ5Qmml2cxgZdCxvkqNKE8z7UOG4O/HmEyRX9zAQCGYgKrBMIyjvQyqaF5efYrv5YMN2w5VaKbdYyFpWZBgn
# DATA c6iPz6FUMRLjIeUzsvD3g4oVhrpngdJyLF0pm2W2EG8g1YX663J+XK+U7cui0JCb2W4S7ibhG0/C3Yz7BZ9xr5xMP9OSbbyPxexo
# DATA ESor72q58yo16HIJ6/2XSK7ZVteRrZTW5lC5EIz4W1n+bGFfpFSYfoKdQ/Kyk0lfx0SdNL7zg4VtlXqSv6guZz3GXzg1hfF9VCB7
# DATA AT7BrBdWHAupetIEXvsX8of46DQPN8+obt3zJOe0obCtZ7ZUSfUtGA5mA9UaQ+0/f/tP2ozgVw5rImUnFqQ3i0Yjnroo0IQoen0X
# DATA 9mfmHYqVFcyYFhFChY1mLMP5uKeLK/DS4clsOFbWLBusPDc4jOVnsfxYjAzTZoiaWZpfHu95hEiXkkauUG6lUS44Z9QA9Qq0YIZy
# DATA dMVxkC5o6hYLlKFGxnBkYtVLKKtlBeOsNme1bWy1LdQ3t3bi1k4uYbGtNA6vUnyXAU0DpaPPYu7Ia16IL2jwPn1B+HWGAM75efZa
# DATA y8LSidiKbFuGhWuFNQ1Z6qfL96j/5bPffMXb6Y/PA93rR013Zi6YFQY5IFJGxvtF0L2NjK/u+6vXX9SGAjuycmmT2JqHTXTzKya+
# DATA 3W1GV228oN/f1fq/s2RWqBI73z4v2iYQE+38yjnZXLXiXV8bbWW+mgUz2ZXKq1xS5SPe4mGaQmYholDD7rwqZ4JVnNX2ZNupll+S
# DATA /icWVNWUxm5lxN6UIJ4Q/iS2FaO08i7AVqX+YWb2l6DxGeP2XXGmGqVmRg4fD+NRlPcTMdRqZ9irk7LkrVnpoNYc5eLNLA+sVjhh
# DATA 4srGFdn6RqZuqQronVZeqFB9pjfQ2sHoUq2+h1I1H9P92B6ch8N60v1gAu3gKSUgxjnFIJ3yQi97joEih7vyeBiJAZ93XEgZhKa5
# DATA X+OFLTI69j0Fs0MKjdB0Np9S16P0g4vi0jc5318W69mCcPEcnecQNofrt8zg+uLsF8K7Ajnrm9M/KDQX4FxgcX2+SOD6F7rtMQBd
# DATA gtY6/TcrHPrEgK2v6B4N2fr67Nen/24oXaef042P+V2/P/sHJnThpIN3+rvTL07/jSpNMHLArefC/mfj3tq6AVRgmgDvOkY/wfXN
# DATA 2DFMas0gT05dEqv3Uc84EdXvY9YNl6ULLbtdUdzQQzT2YdBDPyWzdVHD5joDsfNehBnCOtjWR3SXiZBDbRVM/7xnuG7aVqlUro61
# DATA JbRvw3/iLdnWW607f5pRcesbixVsm4itQMBWGq6gFgglMQ6vdU5xbR2t9X5ARid+plg3q5VqtcqjBmUAdVH73vs0gBirhwkWPOka
# DATA BlOsBeud/7Ogd4BICo46MxAKFFf0kAYCnC0oM7TOrW6rzZRi43la8KxzE+C4WW543/bwrplZFx/VXw5n3jWO6Nse0Dcazzcezq9l
# DATA NJfaWEi67aN7ltrQVTCyCglnxE+mmO12MmnSHWRq0SzEolkPlnmAncQVSmgMpA81mpiSMIrBkpqE+rWDIB7BX9kPwCpitlAxWRht
# DATA A5PRYxrg9AJzPMmmSBJcpNRCNqVl5SGzZkAm76P4M6WJt6IPqc7BvUIX+Uw5nzZn/8YEK3w8h50zIWoaiAM2CRmZJWZBZs6KU4ru
# DATA n5Dx9hCesjgM1En2SAzDKMM+xDgbYh0zgFejL9wVpCseYANifxiNA493vjOFa8pjkUNpOZSWQ2ldIUrr3DFoo6nOhubz9c0CLjMJ
# DATA 2MIcwKGzHDrLobMcOsuhsxw6y6GzHDrLobMcOsuhsxw6y6GzHDrLobMcOsuhsxw6y6GzHDrLobMcOsuhsxw6y6GzHDrLobMcOuuZ
# DATA QWfVGo1q89LorMagPWg/R+iswqrzRuAszliOS5czTtBMVb8gR9HyO8UMr3e7q3O8Wu82FkFO3RojqVRQFlyqXe10u71lcKm6BNKP
# DATA U5agUi9rWWypOseTD8x1ijSpsFtvt5Y932xu9Hy31231lj3faWzyfCfqtQO/nAnjWqPu1WqtParYzS5X79q47jf3/Jrv8bU9ubbn
# DATA +/U9v9Hea7c9v+PbQfOG0RKeqxN2wu6yHGRcWKnmt7teo+5ThcerveqwWy0FZ/JuIbjuJRBY3IQ0Aktao4XAqrdavXbtMgisatSN
# DATA AguBVaOA2jkCqxZWw0aOwKp1Wn6re/UILJoJ7dHvG03aazUaK4t+q8JIIyOeDtHjA3KG+6RtOGV86gTrAFLtWlkWiDcfPSq5TKwx
# DATA YOHuoGT2G1O8o0zx/AE9apfngcvmfNpL2GEvoawOwk+4ZLGtVUxEcSFA5oiePfFRhlz+hBkGl6zYlTFcSz0+uqIWPQyroF3Geayi
# DATA A7+xNf3i7+fkU/FFLSSH/YqFrSernzfj9DmvWTGFW431MhV8IxzXusq7elpfqszL6uR8dO7kkqPgOF+O8+U4X47z5ThfjvPlOF+O
# DATA 8+U4X47z5ThfjvP1knG+UBfUCfkoPLCpXzMsmXJGIHW3pa4n87QfoYJwrTqIB2xkqoZ5p1mFwTMbAlbwVpomiOObyvJC8yKTh/ro
# DATA 9FD6ZPPa2yVj2poTsAlbweSiIvQvbGvkctgV5pgJhL5TV/HxK2zXiHnu3cuP/pMdfZIt6Qt2Dz5lG/1RHhtstRzEE8oORTVjGVGl
# DATA +3BkBf8GOh9qrnCpVnCOcRzIGSoudby1hz3KNL/kF1nxU4K61NXgJNR7ibFPvWOcWVTWJ/3GEaRqzbmPUzt7+kf65bV1dgeXIZVP
# DATA nq7becp2HxUiI2JUJg5apFG9CacBEQ+x+g8+Ncb8x6+YwPcRN3qruXCD+ipQ2Ogatfb8GORNuVHnBp89KqdXJddUtrXthdO5rPA2
# DATA C4Ymc3g9BcT2suTZjtjQ/Vk6oinf3/yNfMVmQPq6+1d/Jd/pUcrTj195ixEPr+w+WmF5K6ObusJsdp8t9h0pVCdx79QULqWm4FQU
# DATA XmwVhYuq2z9VdQXjgJUUiVifpeQ+C1Dd7rynZbg5pXyQdQ5py3h1Qt7UZ/dz5QGJJR5a9+B9bre8zQuLQiufKmSHGAtW28ufuomY
# DATA ah1CPhq7UuDekJiUFAK16vXi9s+c2MRzcLia/7tlckJRFGPb3ISy1shSasJFVbI+SmNlusUTZjWS7QZjxqhkGR0QVi7LYAEfQ8hs
# DATA PBcNhxP2U1eMgL5URlV5uKJglMxE0d7S9IDGQcAWfTKYMVwpjdiNzgQuBdxiQ9/jhUHWG59ED9nHq5Q1zuUYvRjn5E0Izrhzxt1G
# DATA xl1JKcdpZjnNrAtYdStNx6vS0npbBJuoYqu5vHIicDXPyT7Xrdh4HSL3yrOgM1cn/VW9E0MrjuvboJounjJcZmdZQWCdMnI0Yo82
# DATA AxCwVsyj21/BxXSAPk0+3VIXlEUt3yryh93i6rYf+5Vapf4TGhR1jFZIyiunGr3rbf7EVbaIIDa3mL41f2iBAFxjZMNx4vFWkjXg
# DATA 4YYY3uAelu5cAAWvFJM3Pqy86jy/OvKY8oi8lLKRlkmczY3A2VRaTUVJmP2X4Ci4L12sUjMDYUW7QdFMVD6w3tvxpKiFJqpZASAt
# DATA tktO6WPRgAnRM0EkjU6UI9Q0dyhciQAXPX2M0108dLLmlOX+2/dMcWFEJBt53p/NFYVpFI9xkTcaQbAKInFMu4B2V6ajUqoI+VTE
# DATA NpPzqYWUVtF1irmlXuE3rkM15zM153zZ+RfDQs2HGWeiOhN1IxPVtkWcgeoM1LWG59MWe32v0EgmGOhm8TiHMt2XZVIWQK1YFEBJ
# DATA nfeWlkGEwCKO73B20e9oKmHCYzV0OVktNDikeGHL2eTE6EFuqODK0TWxERIU1QIIOopBQI2V2n3E+pboPJZ469SJ4yWWquxRQAXj
# DATA T4oOpCwZ/WNuXJkrLD0B5HzE4ajYyZ4b0y2tZhWZjQ8M/ZHPRbvSusN0ifZTCyYjdg5gdETHKPfF6yxMtEjtS159l6VjKxhH83VN
# DATA yFEWH3La3+RPa2zXIhtcdhLYBouima8yGwtljN3V0lgvAWDXuXFBAPujT1cT2CVjhcCOSVykGenKaX+iSewfYssopTydZ7Ldi2vg
# DATA hLVTlZAu5kAgc+oV6BibMAJsoPB6czJ0lWJq3N/33oxZYHXOQrveOM549ih7XbBdiSmivAlErnFr5ZVhITEAQUSvSxWf7YnR9qUa
# DATA dMEM/s+//2p1Dhdqo2Q0S7qmkQj/wq8a9+OZQd7zLzl9ibVvyagWLdVkqk/dz6i2pazji8Ors1js87sDPhROc4NxLz6cg/uoXL8V
# DATA 3d0JKkrojwEZ+yzhG4f8m0zYt5Gjl6yr42yzuvpeMJaqACnrPOuktmCKAwVb2ecrqrbQqR5FMyCxZHeTedpjjAd6LwZ9nAAtK7Su
# DATA CZQB0SDI+qPoUO9JRaE2KJgG8vSr33+9UOUT1hnHnlLxyTyaRzr/3sEMDpM2mkDnSszHQczOHL6gjptHAEC/KQ2S1ySk4mR5ReWA
# DATA kfUDHC3g/KQMnMCFxAHN5ClgeiNQFGmoRKFtpeqZrv2CGfn2mrqnBgnJw/IKpTdLgyMaN48pDTozP1BHCYZKIDuQapmSDROFmTIK
# DATA qJebzBgch7Bgl8j8hBryxPQMqlcdU6+R8VwyhsSjtayaw+VmsZJzj2j+q1W4Yfs91Xz9cNN8/ZAJfNZyFc435q1bLYel0SH2g8sB
# DATA EUpIpoYMjDa5er2RPM/YV5FbhtFgwDls9wNBL2PxapqhsXtH7lHVGb2pWH0xOtufym7WUoYWjQTZs2gbCeaKZA/ZtXp3oZ7YsbNF
# DATA 7fqjjqg/TKCfFcBfSiWpC+KlWHizMXpUEpFN0Pvn02/O/vb0i9N/P/367Dfg3p39HEg8+u83p787+7Wg8X5/+vnZZ6eP8ff069PH
# DATA Z79ZJOrZ4TAr7+dM48Oz35z9Ck+dfkkXmbcn6D36+yePbvni7O/puT+f/QI4PcSgl0bHewa99+XZL+nvb/AzE/f+5NB6z4O3Rmqa
# DATA zZuXKeeDGK10ItuCQWz4ofHNiPI9zDGyGEIo/bClIOsb+P2B3k6SRv14qmyubI7+iFv7OGGx/rUkvTckXlYDcjA920uD3Llujt5i
# DATA mVwdSk+qTr6S+IFUJZE8Kd+Mnshac4yOr4SWzTuqp+rQBWWFTBjxtnE0mTue3gZltnWknpj13Jdz1wMvs/jNemRA6N5N7Hnuxj7M
# DATA uyWqrsmxgvpowjnrrAn6lw8doNDi8RhndAATosI2MOIL1b81GOByo3paiL3zE+EYe26cf8JxXiP1LjW8vyQLMNcytF/ByL7RwH6R
# DATA cf16hnWpkuUcsNB6T7PpXAVJr5xUvSgiLtWA5SZLI2JmD4mI/8KYWBEolizOyhqrKFkcRbNkys9EGR9oT8hcmg2TMNsEk/cB8lCW
# DATA scoxouyFh4A37lLyxzE2mCRklWHPlgz0eXWhdwbZPAUYLGCBUcpk9udXtNs+jdB+OEUnXDKigyMkQDhWmFSnK0MWjAT31YezWvPM
# DATA HA3P0fAcDe8KaXibjB4bzVU2NXav1W6/jNm+DavdUfEcFc9R8RwVz1HxHBXPUfEcFc9R8RwVz1HxHBXPUfEcFc9R8RwVz1HxHBXP
# DATA UfEcFc9R8RwVz1HxHBXPUfEcFc9R8RwV75mh4jVbtV69fVkq3mDQjcLniIpXXnneCIxXoL7VuxY1rl6tG+qb324XuXGDfqer8oYi
# DATA GNPIaoKo50E0GtW8bGpC25PDU7VuIbx2o9av9xcKqtb0vVqtNqy1q0d+o/HJXsvr+nt+vel1a/SnutfBl71ubUnJLaL5mjUKrVkd
# DATA NlqftNte299rUD3wG+dQ50xgC5i4WntpBnQsch9F3qqc9WaeAfXCe7/V6Nda9epClOutquc3/U/2KK0Nqi17bX/cbFDcP9mrdfWV
# DATA SyfAr10CdMetQoPupIFZoLt2o15vNDYA3YWDVhF0F4TdfiMH3bVbzW6raUB3Ybtf7Vmgu7Zf9xvtawDdoUntrbc3PB5erFvLfLjv
# DATA RtQLxEFFAi4t5i2g4uq8YJYvlxWDVnbLgpNK59CCI7Lk77fDWuaBv9Cg6rHvrcqGk3pGLYEtTbpxqy5G0pjlRYScClvQdcu3CpSJ
# DATA douYtaU5YwY+vfpVXUeD26AWXJUp4tBuDu3m0G4O7ebQbg7t5tBuDu3m0G4O7ebQbg7t9pKh3WyYmySbD2zdFpBaiFNur+x+R77x
# DATA kiNjuRTyLJkFI7kfLerGu8FsuM8zyR2+uHuDcgDHUek9yok2hcbMfMq37xTecVO+0Y8Z9yKz5B624+34digfyWEyK5DyO0vB8LML
# DATA R840QUymgOZIhztE7Q5RLztEXTrm445Tu+PUFz1OvUb49qqOWUsrYDsYeu2yymqOWT9FIY/roC6E6ni2qhn46u0c7ipJW93sJuzA
# DATA yAXg1VN536S+58yCIothHLMAXVNhG9j3L4tO2GLBa1H7/mrhWxlPIcVshjUUAw5VS/6fE139vImvuWAi7LeWRbhjRbi2eXx5UAWl
# DATA jePB0aQr50RSPZTr9qrvBQ7EQgx9K4YdO4LF6K3kPbyhWlRkRIOeX9zDG2zl8TDGAC9MTvSB5LcHUNlEH8LH8DMe6ND2MjJLphX2
# DATA aVIrHcHrPzrxoKSJShaDlydGkXjrhc4ltY7PjVMzVCGGFAQFCDNnqAPsJzB6VEj6ODjzJ7gmR9kM6+48pWIJpjFbxJYIAE6DswIj
# DATA L6OGOEnmydrNgS0GAJMNvV+WjCPdEb1Ds5cjzJCGDMDg9t3H7mCVIEQ772vOBzS8OAeLHSTWWbLrLVlnt77gdutFobBPXR6IF8yt
# DATA heBFo29UkARk6k/GotuKf9DjY6QwRdYyVJ+6qtBzosBxFdjUBQWkbZNTl6hJLYenbqaEWKp/yGqbpsAi0q+nSKsa1lm1PVeQ5j09
# DATA eiI0zwROpfmpbItFmGeFJwVJl8DDRon5WNlnqGD0IYuUoYTApCYVDRSFTr7HNxijpCzBzXH+gMVeJcoRZbGO8dtmohbzHJCiKnpG
# DATA szitsDI7x0arshcsNK14b+MD2CBFUGQF4AjGmmi/j4W59bG+D+iKijVvU4pCHfG3tMRVSLNbxIaSwLlX4SlfxTvBZllRdUKPMUsO
# DATA I6hY7XuWUZ2wsujYY1CBor6siq5+4WKMXyIBG7tPcpamszSXWZqFccp5TJ3H9DwD9ekLU0oMMqWsmCbJmFXquEHk8pSjkTSVpSKJ
# DATA +6qeV8RZUZHBCLpzaEZYn2YqGHtWPFm9U+2KlxEvRgG7x1aCUneUNqmWGzlM9HxTxm7CBRyMsIFBBLIdFGwTKJhYXLZptepO4+dm
# DATA uov+svp+rdLJuao+r75by3gWzY9nHyOW598FOS7+Lb+1GuWiC0NQLj+YRNSZTNm1uIcji9oyxPqG3/QO7ZWMWqNKF5Qb8aNIEcho
# DATA CoKtcqOTCtnt2Pvbo3oxwNcZxkuEjD0kGdY85FRHxj0EjK3jIBuKlqq20OnSaJRtg4NzLfn34XHC+RfSODUt5l69Wsy9RsfKvfu8
# DATA UINkc1+rMgmKpQA6z1iOUqQx5S7xC48i4IuwWddTh3BFqHQLuVVogxfPsObqDLMatOTZd6lPpdjdS3kqO5UJTJ5vtVKtq7ebVr7N
# DATA YErxMhkbTvFkPsOQA9HSUXFixSMGw3qo5tHsSlHwzCTsCDsaR89A3rUukHdvoAqkIiuRrw8Wsq9U7eq1ain7KjyVZhP1UIoio3mq
# DATA KKWC2CetEfvRwzQ4xlZevTTAerP50sCT5Jndh18wy95dnV/5aKAQfsmDQFvXOpPuMadCuBFA9wm98IhsDmOmk4X7gBreSKGdQlYd
# DATA Hichk/y8IdaBvQ9EKJiZVrhilk/MqkxGAz3lOmvyokVvI9vswezCNa22OuPygVEyzjgGigaazsP7uKq8LhPP71ANC3VeBV69xXuG
# DATA qKJiWyC7EGi6pBwxYrsxRp7rWuIdzmPF92JurPLesNnIW86fVYTXi+KQyDFeg3gGiVmb4/X/nj4++8Xp16dfgLH12Dv94+nvTx+f
# DATA /uvpF4ze+mIR2PU/6KffnX4DxtbZf8MtniC5Tv98+hX99OXZz89+XUE4FCaF9TX99u/e2a/w0x7d8Zh+/wW/6fHp1/TmL84+YzwY
# DATA kF2KAPYL+vrvFCD95Jhdz4NLJYf6ocsc2zwg6UOyGD5QapIaF5jO+zNWv5cOhTIsmgl88QjTv3gsLkhpt3ChDnD6HBwAKJTwU+Aw
# DATA 8kZU3u7ZVxr5STBai/F6CyvjYXBiYuo4XravRXUQ1w3yWlIqV0fyUrUwXzK6r6rlKKZ4pifl+6U26pvfLlTSbcK84DJUMREtfNmZ
# DATA H+l4OaDXZkW3dabX/SgHHeQsiBSQVN1lGSoHl5yXobfBXiCREWaogjlFDM/PCb7ue9+LQz07pt5NptfinFIpXSB7nV8ZV9szi63s
# DATA aaG9zk+FQ3s5c2D75oCmfV3OCngpVluuywK4CgNgo/H/gsP/9Yz+UjEXcsGCfj1jjeoqOGALyQfUFGtDGXPe16eswjUQqlechHI6
# DATA 356prRG8BYJFQuIgNW/SQXHKZcEJxalcBxuRwT5kXy/8QdiAk8H1FqXBqKIsORrQ4nCO4otCLkYYaynVEF5DDnPME0dYmwJmxwjM
# DATA AwpUXB5wTlEbh2smnuxRFjOI3SPrYhZPIu2o4uUzhI5laJgtFbFZ6MVihxgQlKOEOUqYo4RdHSVswyFnoznQpqbz9U4DLjML2MYk
# DATA wJHCHCnMkcIcKcyRwhwpzJHCHCnMkcIcKcyRwhwpzJHCHCnMkcIcKcyRwhwpzJHCHCnMkcIcKcyRwhwpzJHCHCnMkcIcKeyZIYU1
# DATA evWQf74UKaw9aA56zxEpbGHpeSNUmJ0vftOr+51hs9Ut0aZa1Dt2omW0qXpHcojLSMqgwYqUQsry/YJST7nsar5deK1C/pt3FkJv
# DATA dv0rDL3bygNvdAuBS6rywP16y4aAFQLvDjq93qAceKvZ3XroBdBbQ1hsAinzWznordkpBBA1g6BTX2gW9Ljn+52jRnNU63h++xwC
# DATA 2eo60b4EgIwbmwaQSbstAMiaQbe1AYCscAUAsmbYH1RzAFmr34w6VQMg6w/6tTCyAGTNRr/bvXIAmW6ga+FT+35TU8gK95vRUS8Q
# DATA NDehjRWD0LyxvB/XObXgyLQe7WFRZskzmy4L7LeUBVKzHQ+1/SVrwj4bRIU3FzwKYhngOZ6/GG+S3yQ7ASbVEo9kzXgkJVPKyyxL
# DATA FvqaCy+oHei5FvXefm6XlKLfYXtuGRet2+0WaWhYZV5NKSuUW6VUFmusneKNJd+DcR86DJnDkDkMmcOQOQyZw5A5DJnDkDkMmcOQ
# DATA OQyZw5C9ZBgy1AUKJRxFlYiXicLb1Qo73fnTlMzuKLv9459U4FA9im6zBVtBR/s+frqNKnlgKjSfLoN1lO7sPooHO/LQ7iMdNLVQ
# DATA mCDBpB/tT8hC3d1Trzqwgz9gVWd9cGNHord7gK7g41c+zI+xhYIT+9Sa42AfoX6/lCKOfax5L9JPT1FSWcmDJsbpjuqtoE8s6acE
# DATA TMIbt6dq9372HRh2B5Q+BP4q/bb7iJ++PT3gMxkUJ/rxL/gaxWNpagoJNll/YDL8QGodJvTc6PMaRnl+T+k7U94rJJw++WOUn70P
# DATA cUiqeP4ypegzwYPyI04k+8SWP/h09euY9NaP4tHODiV1D2nevcmmLSBvKksoJpRkUy+oIXHq99mNu/sorzDWZYm7fR9lnM3Fy2uQ
# DATA iiVyVXJIjQW7j/IMQ9GhOGPKxvhVRc5jSTekM75xQ9+8P52TafJIxfyW3IlTdnRfhSNCE+uPcOruPz/7v9SZRmDz4hv+LnUxFImF
# DATA 4Pf83TVh43ikHfYHOC7Jyx+LoX+a14VPVR3hyaRuk4tVWT1wUKj9B1LPbmMGq6uedUOl1qwWW1Q6n4iUsBD6uDpwK6MLr60zcPM2
# DATA r55KcYb0vKe4fO3uwqr5eQ6U+pl1TeIDqKzm7UElClHRSTJzwCXR4jMo8YjmQ6ZP1TXQPCZjxW4h0hTscTyh6eKyQLGSRg9FpUxy
# DATA zBinM3FJnQmnL/Hi60tclCTzLOhO8MpKwV+/HifzLg7Bg8gB8VV9cDo4xKtmyThJaWa2linzLIpWPD9HuK+CNLOosbFt1MwyEZNL
# DATA sma8whKRVGleYbvjV7U0sGA2jZwYvUzdAgFPqSe5yIct9P6ArLKKuJ5Eyx6RN5a3rOYlU8wiAdcT1sNwns5Y6itW753SyD8R/YRE
# DATA SX0YEfs1Qh/nKY++QEf0Cw3HmVDOhNrQhCr1r060y4l2WcPvSuPrWRDzen0eg6lVlK0yUl7fFV0ouylh5JlGCRra8TApjFCCENAD
# DATA 2L53FyI2KDrW1AlkLqzgY9EDao7BKB5A8Qai23A+iITUJIpCjRm7KD/FRFQBH5ScNqTVK0uUtBw8ZRN4yjiRomO9e/V5HRAlZTea
# DATA SODL59V3Y7ePcLPf4E+r79TmjuIL8efnAZ1i594FVfI7MBxX6+TnZVFgWbBXT4vj86woH9kwfqXJ/HCYN4afMuydJTw0Lmk+IeOR
# DATA tajyDdNoz0dJzNpWfTYPPX2CHlbjnMXmpizfC2OT4nAYzbZBGXiC/GteLP/ejLIHHjvbLbQAtHEV3MmklyXjxBWeMc/QNh2Og9ED
# DATA yistH8jh4bb5CJhuRjV60YTLgMXbcArCC+epFtelQWo7TIu8GV4UzlBbn295q5Z8e53GeNn3x0ydeWxqn7KtqM5F0UohQ6weTcCy
# DATA kLxkaTpZTMgUvSvKZvve9xmIEfWHk/iTeWQUFKmS0oQOrITZENOOYcA1Efk6UxV3C7mZd1MXzctz6qDu9SQnP6K6wyqIWqrZYEhN
# DATA JlEauQqxhapQowYJTxZu/wGkIEumrMq9gGUXFfJvFKlJJme70pAzot6D4jD8tFpw62It+PVgxHaEmipENosGxgFnSDafYgJGCQzS
# DATA 3omaG/RFZ1F2Ou97vFKD3GU58lSx3SjXBlEEEUVMtciiiLJp1I+ZCCvql+kJ6xmaSfgkOt5GDtpj30UrYHV9FuZDqYKtoHKl5qKm
# DATA 4NK0a8xdGzp7Reox07B+ACoPZdQxGdgw1bGDwhuSRYj6hSxjFVAWPqRKDR3II2wVU3tsnlmoygvk2siDcH4N59fY0K9RrGnOreHc
# DATA GpdcE1rpArkyjXJVZQv0V5jiVM2Nd+OpszLWeTeYybiSY88bvXmZA7u/1clFfc1MenlXgz1ymit61su5lJ+PxM4Q+pYMBmIaBKHY
# DATA BQWHBO9qoZ/ZRjK9zo7anrKr/CK6hU94Qz9eIZFST5ueUX838/y6HN/EMJCScU/GC5+5w8Vx8FDuqMo5uWjKR/NW+054kwynxCrT
# DATA jaOqnjZR1d9NVGvnRtXvbBxV2faDyPKn8+Kmb89jZ66Y+DWWRc+3oldbEzu1Kmj8WXIugKd/4O3d5H2KYzKx5UY2P9LxnVdFWiHP
# DATA QhwLsetgfqlQ56Y0uM/kOO5NCSKvyMY3Y7UPc2mFA0dMIpoMhpapXVD4/2uyTft6gkoT8wFGSQPSkSnDcUDDO2A7U3qUDDTMwBQV
# DATA KJ/FaiClohOqyZZQUs3eXwtpiSE5Ge0xzJJ3bNFbQvAwE6GJwotS8cL4Zz+LMaSwe2UyzyDIn52Q7ZuMs9yLasdsGI2m5ywcl0o1
# DATA Xzy2/ar5MrDkv+zZosffx4e8xC8VmGzlkkYZzazqIzYsl9jLYZVbrMN5SjYxmXQ27fD/YXjhF6ANFhmEZ/+I/y7SDv/59HPmEX51
# DATA +s3pH7yzvz375enXp1+e/T09+Q19UtxCZhyCWCiBc8geAxE/B0bx7DO64fdn/0APfYnbvjn9I4Wjn/zD6TfAJT5mDCIF6ZiHz8MM
# DATA w1SvfGLBFR7EE+QoPVNR/krucDQSg4WTDN1ZIkwW0ftUikIjgGFlCB7Uk2qjZxpHfZqNr4MbfqC3MdAAwGg1hza0JhO6wK4bbrhQ
# DATA KleHNlR1RN8GzoYm7vAvC/dj+4rV4d5PBmpPy9bRhhyBAtgwzriyO6zhZsW2dazhWw+nI/QygXaGjJNwPgpAXk9mrNmz732Evp/7
# DATA rnyfFy9+YWM8PWv2P1Ec5mPuKTPZBgUXSjIL9FpWMBF0zALQ8PwquNpqKbesp4UzPD8NDmfoRvonGOk1t/AyA/zL4Sm8tsF9+2P7
# DATA RkP7BUf26xnYpVqW8sBiFj6tlnMVcMJSKrECABKQ4vzFfSux+pxjOUGBuDQVVA60Nb2JOkPx8OZr2VasJbphJU3YK1rOtw2JhMbL
# DATA mscumyV9XnHk8Vij4pgfx7UkpLn2JDPRj+Zp4gVjxr/xkB+R2RD3YyyN///svVuTG0eW59nP+hRRVVaWmUUAxB1IUkltiqIuXSTF
# DATA IanS9EgcWgAIZIYIICAEkMlsldakUtd09VZZa3u2zdZsbHfbxmbN9mUf2KriiLr2w34B5FeYT7Lnf467h0fgkshkZpIUXVUkgUCE
# DATA h9/9+HH3/y9lE6QsgOAhDhYj8E4Ab5TaUa3WCsl6oOK8EfgxIsS2XXsMV4wYiezVEUqdrK2rom5NDqR+OVqhoxU6WuFZ0QpXHGpW
# DATA mtqsahmfp41/EhP/NCx8xyp0rELHKnSsQscqdKxCxyp0rELHKnSsQscqdKxCxyp0rELHKnSsQscqdKxCxyp0rELHKnSsQscqdKxC
# DATA xyp0rELHKnSswueGVVgrVau19glZhUGnWwoaLxCrMLPwfGxSYa3kVUrFvfzm5selRr7S8Bo1+nu3Uit/XN30yl697FUae5ubqVxq
# DATA l1qVdjeLsaOw6nMxdtUZsqGc9BOA32Ya4FerlDIEv2ozKWs5tpYQ/IJm4LdnwYkWH7BZSwVfrmymg9+sLAzdJDMVerVYWxJ67USh
# DATA 2yXSLHnVamOvutmnrjVf3dyrbq6c06VZGGGj5NVKjd16rZYJpV1rt1rtuSjK42MHpd1o7KA0QQs7WO/Umo3OkdhBv9vq1lPYwQ79
# DATA 3Slb2MFOvdaoGexgq92utqoWdrBcqzYrZ44dNNvUIPy/s9J8fQm3T+xbb8Yu0uZ45m1moFRTr7cC6m5CPyfxmwswrKmVuPIMrQ8L
# DATA izMvyLjdbaNRF0h63k3mnleCHeDV5Y8dJlunK+dQTZtOyBQxctNBXfGzhoqFDUxH1t5coEd0texVnOftlcWUdNLK8H3yX+qPPeNe
# DATA ThzMZGsumydLzJalSWZ7wgEHHXDQAQcdcNABBx1w0AEHHXDQAQcdcNABBx1w8CUDDtp8N0m2eDGElMZHxRH9jV81ixfKxRzNLNVP
# DATA +1yEGzJl05iva3JIhg+6oZFd4F/BpWv3EXDg/X//u7dZxLdOEAwLH9J/A9DWKNwrW8XXPlx7n7XU+RwdL9QgEPpRgijwlIciLGGZ
# DATA wzeIi9c6wL1Mx/NbMULcME/hE7/rHfsom6TOC+Ix/MjBJe9//O7/RWRm0r5eKRcvyFUW90TXgCA1yswhxNzZ7qPOdrsz3T/1M93H
# DATA JYU9D2e9My625Ziw62ga5omCdwPV3tZ2mQsHe6anw1+co5FnQQHLHmY/bQbYrCTASQlgaX+tPqt/naldUhHkNd3A6Nq8Adej73Ui
# DATA +iHe5zPat+CERNViKaBdPxwVvDvhmN1PWvBdKqAIl0+GcjxZFW7q+L6fSBkNIdoYdfksciKak1G4mSnnBwFMZd/I7cAmOn+lm2d0
# DATA CtZqQc4YcsZQ1hia6VGd6I0TvTnKjHo+xHBuSX1lokUnMviLj6KWUcS5bbQbqBmGOwNF/lIaagofOaJhoQ1xiy5uFiWJ2Ad+Fe5R
# DATA jcfhDfks3yE6NHBD9mztljmaKSuDv+5CdQb+sUTJxubBsO9CVDsc7ms13BclBfokKuljbjWLYV/sdhRZaP64+F7enss9y13+9CLA
# DATA u6y8OCZ35c4SfpLOVSGuXEWroNIV20qAK3f3IxFriiYQjPEhxyKQlT5aipZIRA332QslskxiHtK4tgcv8t9CnmXUT6sXiUoR2X5R
# DATA Mt75EISh2uGLRn2XDWV95lQajZodzBd2nhWANgtvYpMkCTQ5pqUcMDZgQZkzhh6wBKGfjn914pK7vXLJ3ZYD5mKl66K7DlsEHaHP
# DATA bAAqjh2l/h0z6SsYsjqOYgml0WEoPpb0EbVvKgKZpG5rPiM8hmpfFPemvWCswAIjFZd4GI2fvshSKTu/Mkt6k2OW2bvLaGWqX5Iy
# DATA excCRMjHVkQRsgFRLE2k11G0oNmOMLIod6kTx8WoS9aI4Wl1g33RnNKD21gk4XGnLO5wSe8z/Y2ZK6bRcem3JvHB05dWOk0vQHHd
# DATA XLm4bvoAt/NiBvX1CY8q3hUtfdMYqNfbgT/8QXAg1n7Lh4KWtxv1pWFhcjDg0FijbuBRQY1ACwMqB7wqdsB3w4eCj2NoQlKYWeG3
# DATA py+0dMrOrdCSUfiYZXZ3cZnp8Vz1iqIciGtJeYk/AvvwMQxQE4qFFdgTRwzLI7fVOMHeOG+by7fL+C7qhCBChnFPLE8cm/KGEz48
# DATA x+IJA6BdTqHfS+L+/JdIedUSuRko5ToMH2P1kyJcyvmgQA8w0pzE2hChvsjj411oAQciSChgQNVquH/jmTUCgNnNQ1kYayMFpSv6
# DATA d6fQZmYTcqJiOl/C3FNhTF4GP5sVhHO0OUdb1tFmVynnY3M+thMuNi70yZ2R4LRMyWWmhxEQlRs2pnGxPUOowRmR51KeLL33BPY+
# DATA b7LG8lOT983wTFj9fgToLAnFdFfWpYQadxTqrL4ih21fe8sMuIvnBWrX3nq7fyTgTgJIAHfquwW4m4uNK8llDY4rrgy5k908cBfi
# DATA gzDGhIIMlWLOq4wDUT2QeA91CDM+u0aRsV/Y1u7tYyGT9xc1iou9fKUSP3I3eIieqGM9Rb8seazKj71Ndx/Yz1SLS9yECxF12jTF
# DATA blqy1MYvLqTOdt3t71Io3kdkeQ6Cg4It+ax0naUTgENoP/JK3NL8kYLF6Q1rQ5omKdMdq87UWVCcML3igZuCNu54cWhw3yIee+Xu
# DATA 1+ra/GK17cxjwCUVWKVc5HpntXDqoyYafqn25LbTNRV600qGnULRKuw5svAfStc3oDj2ZKrIqtnDyQigd1nYjmLWT7UEsleAyP1E
# DATA jOcEIUe9SNAe+d2xhZC7oa/lD38//fHw88PfASI3/fMsOu5f5uLf6MtjeuqLw88OP8dlj/55TBe/4r8fARxHV76dPjr8e4OEezJ9
# DATA rBTSofA1hHYqDdkOE/fcm/psmfueqTPeX/t7vnetE8pZLBG9V/tKePbbHYXBoEMdCH/bj0a9jrH+4fmeDMV3CleCuM56B0zXjeDS
# DATA FoooOw2SBQrV8+Cp4CE1tM5ShNzrENBgrQmP/xaehOPIJTMC0ymcN0duftGcHUxul6LD5IIETs31VV8/CiZ31RdJ8LMAyvHmK7Id
# DATA 6V8aE8R1hdEcDcYB5VYrulMHykme+WzmDNC5ybzKTKe0YaMmU33poMhy0RWFF/hoeEO/y9b2zsSnRjEOqG97I4wf5GD90NNXb73n
# DATA xcNAkTJw/J3SplRhJmwDwbU4XoE2N7+OLjZx5rbB5wU7Nz8xDj3nrIczsh40lu7ERsNL4UI8P4PhjOyFlcyFY1oL52csSCWdlxnG
# DATA UHg+G9pZUOysbABoDovEnWAIDhWZMmagNjnEs/kF2dKO+v0Jumss4L2DGUSbHRYsKRJTvrQDe8QfBeygEO8fMixWm+1ppKci4+vd
# DATA cMSnaON4ZcIdQFqx8s1qmBhlyB5ZhCPxc6hfuzRXDvmAA+8IuhF9RCOax8lrUwZG3XHBu63jLQcUFCws6wSesVvkrIBGkBlNCyaZ
# DATA IT+giwPp4F3K5LAt3mNO+0DcNbyXMxgwRwcn5NG6ACJTVYJy1THvHPPOMe/OkHm34uh1ooNdy8zyc59pnIZH9aTzDAfAcwA8B8Bz
# DATA ADwHwHMAPAfAcwA8B8BzADwHwHMAPAfAcwA8B8BzADwHwHMAPAfAcwA8B8BzADwHwHMAPAfAcwA8B8BzALznBoBXLlU6lfLJAXiV
# DATA FwqAN28FeiUKnsWLKyc4OjmNluR7I6NQWmumsqta22zUggxZrVymAqguIatZr9488aub5Va5Xjn5q8v1E7+60my0qp2Tv7pSOfGr
# DATA 6+XNSrVx8ldXi8+srKuNZ1bWteozK+t66ZmVdapdbzbPM8NT7fp4r37aDE+16+O9+mkzPNWuj/fqp25cxWdW1ql2fb5lnWrX51vW
# DATA qXZ9vmVtt+tyrX6eGW6362O++mkz3G7Xx3z102a43a6P+eqnblzFZ1bWdrs+57K22/U5l7Xdrs+5rO12XSlVz9VU2Dzxq582w+12
# DATA fcxXP22G2+36mK9+6sZVfGZlbbfrcy5ru12fc1nb7fpcytp2PZSLXqVR3q3Vi3uN2tv0Ne10aLTqtWp77mPVaoMfq9RnH6vC0dE4
# DATA jjmmJiAWXL5UTwVZalYq5dmY1Io1r1yr7ZaL/UrNK+6Wi5ncaNWCWqsxF8nePBFNvZLQ1MWfY9HUm0U/qNXTNPXSZqVUrqVo6hm+
# DATA OmjqrWCz3U1o6rVyvV5tGZq6v9nq+sWEpl4t1drl4pnT1NkZnG/xJn3j6ZTFdo1FT7ytTXFY289kgehmKW7espveqNHgDZrYnslM
# DATA 9NndjnX4WeU1fBBstW0ZdWtbxkKguxXqcta6FJdyWtbMsouuEXwsYdfvRPuXNulH/Cl6qhQ/LdCr+nCBLViCLc8EtzwPkwA9tdVU
# DATA 71+TZSvz63DO7gO11qtrmFkGUHtBE093LnOiIL28XVwMW7dLaok7fF5dYyc3+9UdVN1B1R1U3UHVHVTdQdUdVN1B1R1U3UHVHVTd
# DATA QdVfMqh6YjEq7Yb1DWPfUaq926L9kQh/XBZiFXfZbCv3DhhXLqIi+X7UCbYEXUEXZZstGnVyTUQm8rBBtsq1Wr3GVzHLE9m0eEuz
# DATA 0XlqrBDn6jc0Sg1IR8TgghhDmG2rKYGHfQUbSX6pywuicQchc2HiC6o5t41CTEN1sF7M1asbMI5wUGX94gcfqv8ubf3iZ/h3xMHc
# DATA u7iTo3K1OO1ctt4snB6qAluf7PmDsNfzL5Vzw96Epv3xpUoOknGXap9+wFHhaayJyz2Np78z2dkJYhkXWYDMu71945LBxreDsLeO
# DATA N1zIZs+vCqUm0+TfCl8XaP3rLP+T6PBmQpEARACHJvkIQvPjh6FA5UuFsg4SnbNiiWBUEMELaOqJ0CG/UNUZaOKNIc83JnNZ1yBR
# DATA EoJkiwLScyYkGrJ09bVl5hRncNhdYMl+YiYakEjLyNPS00kl37iMkQWOq4xGDsQ+VAKg5GJL3nCMZSD4eS4t0OF06pxO3XF06jJi
# DATA Lk6xzinWzdH8WcyyeF6U7LzhCO2UNbTScTJSdttpSbedCaRxIcy0SLtNgS0G4M2G7VAFjfkdq7FqsSqm0WYl6dJorRk5OnPfbvnK
# DATA LQxN1LXoiIs3XMtN/UbGbaWYlpCvYANHTKgHBhCoGyzj5FlFf8wC9RJcDC1fT8Z8PdW9DLFYaE0ptTkgtjzrScZ5QtmK4hxAG5+S
# DATA EsK41hxCPvIXdTk6wUNA1ETWCz2VeZhGqkVKfZzuN5RdxHJ7idKtGhp1+u8YQ8rThhQU64D3EaVimg8L9UTlUMg6FgXvNxg5Zx5p
# DATA 706gW6z1x5S5UvB40pAaaAUPLABU8dTmUlThxKIg4xIKfdJzo49lzEqICDOomF5lzhLEy3JkW3XxkiOqV+fGYnJjHA0V24DrSjRi
# DATA NTmon8WTIUZobDmGnjPVtXbQsfr/sf9A4AqwCtmeweRreKAKVQ8u/r5/kFhUMgBJ7OGr9u4G7MjUcWOwq2+ZYgwitoccrlvheFmy
# DATA +f1420cRZVoLg6HPdY7mDTrh1+FB8SzbXqsCMg0qrRcoNFQW7aIoYWFryCXHUnJ+h7rw0JBtlKCcToDI0Gn4k55gJIJymnXDgE4/
# DATA aWXGVGOqnTblVDZQn9OLDtjrm4WsiTLYT1/gLBl1nIHqDNTjGKjOHH15zNGFZuZzLqxsL/DPIsx6KTtVWgz9Pd7lAQm2irJQk0dY
# DATA r0ehsJ5X+eUXS030KKCDtZVDcHO8RebKq9RBZ1uqPo6W2uTVLGY2eamjZn6Pv81rL7PHxKT1tyO4peSNB4O2jo5SX7ry7swpM/bg
# DATA k82zQMjbepa/cLoyEDC9kUZrZb+ubMZdrTzN+aONMTbY5os3K6tMywMzr2MytGxJw+CkwR72qJ4uGMxX2sBMm6OWgy+Dr8jWhdcn
# DATA IWr+rN62VIoZYteRhI+BenGOIjIKyHTxW2R1K8BHpr3j9Ks0BU0A3q1cudMX4DflpqEhc3NjLV9fEZH30rMWlgEH9X0YRMMetdD3
# DATA ed0DeZHMP1jNTBEXRSY5pROeNhzHPiquBr0ZazGLlOYoq9LT0VWTP2PsY/agy1Mx02SGgZ0QMuNkLAlmKaqrUqW9JGK3RmREtsfL
# DATA I3aV1xu8GBb/gY6euigzabbAPR9VifMIObk/YtXsaH9AUzb6KexDDl1X1rmxuSqTvdnYvIQixY6b7Kz4k1rx2Srn/MzOz/zUBvzC
# DATA 6cLZ+ZkNTzzL4zBYtecS83Ue/GW98ks/XHs4lH07vApOpkwQTWLtaz2CZ5wEY/o965IB+DaPAjCXVgYaG6P/fe4GEbE0wFjfkDCW
# DATA zTQhyxVWq+z4TTnuFzOI1Tq8TPP44+J7UepstrHffgmjeDZlvJZuUodvjJhQhvn6W+HrRyKmrWDSeaAvmnhWjyqW2jE407zqr6B/
# DATA FFW5gD0h1F4pE5ZH2jxuYaf1lYQ3fVR0K6vGljdyJB1YnzoG6jsyccTuHBs1Pu6kOePy3cRu24vJYtLLNHZUV2BSX9OoZO4gRgGv
# DATA WWjP9IsLqDZrBdIB9/zJgOZDWBCIx2lGtUl/B3AaNrt4jcCiDKFnH4HMDIS09DIFbxuX90Kyd+xFMraEgodttZrhyXqEOurQVdRM
# DATA bPDwBWBzEGPDGs86eMYmRhSvVShDaeSHit4ElrQ/lJ46U56JA0X1jskmklTGWu4Rg+SZ5SInxS55lMExzeEw8QpbFsTETKtOFAg+
# DATA Ss38PHCi9lHJKDMYGdoeK7yPGYWO5mT/1GZNFjB7EodteHnCyEJmT/+Pwy+mXx/+EVTr6XeHf5r+MH10+KUHdjb98Jfpk8MvZ+nZ
# DATA /zz9cfo93feH6Q+HX9Ld06/p4X+jez8//FPOo08/0pN/nv54+DtQtBG0kLQ/p7+fTJ8wR/szeuRf6RaQtL/x6C7wuv9EwT6hYB/h
# DATA 6elXFK1v+EkK4iv6+wdguQ8/c3Tt539CSJ1Y1A/yIMsJIktzp7ivalMzBQivx8vAvFp+S40QvrZpc4IEY+cUmXHDXqB4YYp2Rb3f
# DATA SEPtmQ2WGK1LKdq38RD1QYFDZ6fme0n3cN7wbKtEzo6YrWpVbM30+AJXzDh7dyvwk+76dfrClbEV0Fh/mqhsCpfZ1aEeydTWiplJ
# DATA 3UvKyl6h0E6dlH11N4JOvQ+IOY2pA22/Ugaz20kRJbk3oXKb2QMuPl+yWKiT2gt6lxHXXd4mRfZdbHup/Fh6Q7055Tj1b7EFk7Sm
# DATA Z8W+PjLyDnvthvWnHNY13vp4o/nL4bk9x5H8NAfylcbxYw3j5zKKS000SU92+z7TpnIWgGqTRtkeuih53Hkrjw+Xc052UlIadlgq
# DATA wx/vShq62Ai5K0u2svpM03NfyLSj3YPxbj8pMGsvpK9zQyGLMRSvQqS+GXkmugLe1cxljs0g8qTVzIfzFrxt/pEFumMhE7Oisyxh
# DATA qV4VAcXjaEjW1q6i4I79FjJMDtiJ9ZCkygCyKb/aYSz6FDpL23BGOL6040s7vvQZ8qVXGlJWmq+saPiej+1+EtP9FCx3B5J2IGkH
# DATA knYgaQeSdiBpB5J2IGkHknYgaQeSdiBpB5J2IGkHknYgaQeSdiBpB5J2IGkHknYgaQeSdiBpB5J2IGkHknYg6ecGJF0tV/xa7YQg
# DATA 6W6lW+zWXiCQtFlxXokebecHXKy12m69WN6rVIpv0/e/zeZjUNucg7dqeqVmdbdWre81gbdqph9rlzqNTin7WL9UrXllerRSzJca
# DATA XrlCH7xKM1+tehX6P/3WyDe9asUDPKuUrzT5Whm317zKplcp4W5cLnqbXrWZL5fst/JOyDTbqtKp+fXiPLbVnLpRQ3wae6VyFtDW
# DATA qrdKrfa8UKozMD6bklZJI4MlXAvgVU+qbyVNMg/8WqM1E8Nyuf70MSyXKkkMa5VTjuHm5inEsFlPYtion24MK43y08ewwk3ijEq5
# DATA So3kqWNYrZTPrpRrpebTx7BWrJ1dKdc2S6cQw0bzlEv5OCA9GYQ0SE/GMwukt1mtlSqbaZBeFpvHV/wsSK/b2QxqCUiv7teCRtOA
# DATA 9NqNVofm6Aakt0nWcaV55iA93v6ZX2bdFyoZPt2n1kOzLLqUS6jUTM96dCawjQWXLeU9Nj2u58udYGcjFXKG0PdWQON66Ock7lnn
# DATA d4Vd37LkzXC+7Pq9Cpkna6uuqRW0+c7+3IqVdATj6Y1HKcvdOBZwxED7wrExLH/MJaDqPAc0++Gs8JQXbBbPp2pTujRQGJZXooHl
# DATA lfnboWZeUUCsyWa1ZvlkourGYJcwWcW19uZi6F5Swjm7TJbMImZrm0quVY2Us3t54fBUALV+4TQqKajjzUcdBNBBAB0E0EEAHQTQ
# DATA QQAdBNBBAB0E0EEAHQTQQQBfMggg6oKaKG6xdZrzcegzBwnfUY5l2IqXJT/4dNiW1Jaw8x+38GMeteUyByLiEVtqeFNfKW4fFHPl
# DATA XDVXpz4y7GZ7SHXbxoZ+3Nx9mV9nKuL6IBeC/zbQ3d6WesLq9TYuD5bmEgByesRK4qfeI6Pkw60rD/UbpCejK8rOfai6M/oP9Dp7
# DATA jjHE0bH1jU9SOXmZDwFrW5EzdCOTqsHWFUoQH7+EMcrzdjQ/PgeHJBTk5KfC/FHQ3CspCN4Gm3PpaeiHa+q8HzqKpFZu0ajLErJy
# DATA ypjqozDwbsuhYyRhSB0sY+5MwsZs8QK59zP19g2x/OeXzREpGUc7O71USnIhtXPUIkkSB/oBvt8zRaCAitEW10pt+8dt6DwiuRu5
# DATA ndRPb9Ekgip2RENWQBkzaB9IofFr6G3F10rN4qVKpXh5p7BD98JY/A1u2Gajfh2nFnIqQNmGjssb+u7g4TAaQLDN7932+8O7UfrZ
# DATA Ymn22QuFYh0RooQMqIjWdxCY/iJ3Q0kvHPDKJu5kD9S6fIqG6/NCbFAxSQHeksxkwUTAHdfx4UKJmY1R12tykXLi9S+/bF7murhl
# DATA TWRQ0rlKEStwAoCEGyXiuvapmpOwMr5GMOrq8ElS9y+rqvGpbgM8BR5juxEX4fbVrf1wQBOrAp8q53r5cPzb36qL+0HrQTi2f5Le
# DATA 4urGeJfGae/aaMS1W46kW+M00sdZJPXgt7/FfHD7KkXI3/dDmv1x9qGf7mOcnFOZj9mKoqHViKR/lIZy+VOe7dt5ImUkcU6bF7PH
# DATA 10X0SBR4IH0op7hbgRfQNE23Tep3zFR2TlfH5+PCHk3rUp0eisw8JkPehhVLClSVwpwgscZPj5igrOc4a1+TVi/BiE/NHKp1WjZO
# DATA y2aelk36oLUTtXGiNquK2iwUID8rsZtrWHfh0RVqE4PAlm3RwjfPTkDtPFTGxRSgy3fxwVtHccQX++FgMg6O0rHWz5rOyVwwkstK
# DATA NTwrCS17Q5QmdHmZhLU+5kvR5uO6UIw/QJfF+R2xcAaVDi+g7cpKExcnBSD3pzPGrCdZOWF+ZLOUl6wlb3gKVOQ70xmhPThJVphb
# DATA k6Tzg6WMuvXyd5VWf1cpnc14sHysd5VXf1c59S5+sHKsd1VWf1cl9S5+sHqsd1VXf1d1Rmr9Su1Y76qt/q5a6l38YP1Y76qv/q56
# DATA 6l38YONY72qs/q7GjP77laZ5l9ZXMW14obq6PX39CYip66FCkC5aicgabajveyBoJRydoamcdGAyQmL2AGwyT9L7kFoapbo8CaGU
# DATA 8yo5r8bDUQMUrWDAQqoedhBw0AIU7hsSmBUxGqjm+0899K8MM7Bkv4y3PVGVomEK8watCIZBEGGK1Xh8PbAVpMxffDEhB211U6fl
# DATA Uyc3U/ppzpSOC2J95rKgvLkr2ed1FghPS37zlLmdtnjpXFjnQpwsawjyyUPTUoWLApnxJVjZ50Ac9QURC1xR3txLdg5q40q8lnq+
# DATA LCd2KHdoMg0VTagkGUNrWym0+iMWuYJjlIwhPE1mFdlXzD/ltRcRax3KNJ63dkGHEfN03tWUwwOqoBLlRp7QUyGFPXrHHnYiChVo
# DATA B2wylp+klzMjB7p8Wgz9+LkIs481IzPasecpmf5sLKVUtXTGkjOW5hlLqa7KuZlfejfzQiPr2Wuq65pP1dlnWekDeAAGdB9vRko0
# DATA 1ocjNE3IAGca2c6E5sfsah4FSgN7Rt6bmotRALeUwSM1xec6lHEsp6yGWRF1cx+Nq7oZ84hEpWv0lTFsRt2u5+9FYYdXPwdRGLNL
# DATA fKQ1taU7SMDjScK0olvBu0NDtNel0EREPeZ1UjlKjMG3J3GJef8iAjkwWuDUs0xaMTX6yVgMN5aRA/O7o4lwiHHBu6F0tr1+2B5F
# DATA w112wCh8XOC32S2P5ykHoFuN7mu+Jz5x9/hsawyUGrzOlDvBWMyIOJF+7kXYyDIGzVc24A19hhpa3Z4G6BW8bWQmBR0Ohwq8jSDY
# DATA JXfZw8I2rjJ625e77DL3cEYCffEAuaPR75JuTpW3T2/jlfElybvpw64RbvFOZFTncZXNLSoJmMVSwBo7T6UulXwc9aPRKNpX+t5S
# DATA /XmVXBcNV31PMnGAfZ3RpA0NGMagi+8qOcSbpE0Y7gaaTkWFgU9Rlpel502W52fPGBZ4ZgA5PbLoeAoSwFoUC1QpwkcYpMY8hO2S
# DATA yWAbltQmMWlgUy8W05Bu7+KEOpqCGQelOgCHKJgAvOhBwPB51DzKxr4UEpOnybLcQVXugURPkZkMMDBjTSkaxtlEij11FCnodann
# DATA vHKF+EiOSi5Msh5hRJsHm9RGWqvXzWvHMYa5hV7lZU7k9EKJKYUlmZf4lfmVT/nakryWfpFmZRrf6b6Gl0uk0SQsLGEWcCM63bfx
# DATA gsltLllTWcfodKxOGC3ldN/KSyfY9724YaZfeHHSe0pf/E939pMgLultnSgaxTbf8l+mPx7+HkDKwz8yd/JzJlx+dvjl9L+DKDl9
# DATA Mn08C7j8FyZYAk/5mTf9Fv8wzPLb6ZPD33uMvvzs8A/05wshXKqA6UWMtfyBAn88/V7TKxmMSbd9C8rl48N/oN++cQjL53/edkdm
# DATA WqMIRhKbwlg0iiY7u2Nm5IjMtBpee+EY6hpyithMxCYDbbuQKYVRz2d4qwz4bMHEMnMDBgVmoc9nUJfyK+/wjgvqC8Oe9xFZjGxE
# DATA OZJlMofTvcB5YyznFszZAS25XsbW/FFXU0EepW9GZTW33lI1F8PbadIsyVhlIQW1hil7TahJDB3JcoXSOnWQ5bbaWtWj5nGQ3/d7
# DATA DxJSE5nV4O0A/6OSBVu37eO4EY2yI8izKbyO38EIYaBRgyAgIx8L8FQvD3huoChIOD8/nCFZHlHzFpsl85rTsyJaHpEIx7N0Y/zT
# DATA jPEaZnnSof2lcM2e27B+NqP6SoP6ccb0cxjSpV7OyQEzoD/D9nMWhMs5SfVoHkqfmD3nq2VSSS5imeN1Th/ZHrYxziLFnNx5UeaN
# DATA z+rhUSSgQOmbWlg35/j6HLdBCrW3Ctwy5ehGlFQyjPYnu7ux1c/bpzk21oBF+SAWKqD3XpyYUDLyk+WGXd5dilkIQ0DQhOGA15YM
# DATA 7RLWTigvUJ5hFBovZG1baEjlW+0ENEb2QzIb9ncDjoXvsWnCG+y6gaNdOtqlo12eIe1ylSFmpSnNSjbxeZv3J7Hun9q4d8hLh7x0
# DATA yEuHvHTIS4e8dMhLh7x0yEuHvHTIS4e8dMhLh7x0yEuHvHTIS4e8dMhLh7x0yEuHvHTIS4e8dMhLh7x0yEuHvHxukJflatWv1U+K
# DATA vGwGm63uC4S8nLPyfFz4ZbXsVet1j/LNK1WKvVKx5pUaxevVRtNrNHvlZtmrNDNcS7q3NYvD7Jc2K16ZMrpWyjfp701vs56v1vKl
# DATA Ur5M4df+9ka1RGE3a716JV8qNrxmwyuVG/ka3VLNV+j1m/lyLV9pZMqkFjRanVk+YIWi3fi4VCvma0Wv3Cx5xXG10vSKe43m29VK
# DATA Oox6u9lplGfDaFa9WrX4cb5cbOSbFKlyNV+ivKAY1RDTfLNxBFnTRG6Go1dqyuva4QizpTYXf50j4bW5aEtSc0cCKkzFt1NrVqvV
# DATA E9DyuP5qWp40BYuW16rXgkppBVpevROkaHlBo1PbbCW0vFq3Dtva0PIqrWqznNDymo1qqRScOS2Pq31+uWHA3v2Mb5qKCmcvP7UC
# DATA 0LZBip0miZ7Fual8nfX/4Q+18MtHrSHMN3YWwd+sWB5N4bMhe/Lg8SB71VnIXhLMMSB72gG5MI/snFYZqjB2qv7ZHqMy22lsDJhB
# DATA bME2Aj12qwWu4mL2XZKvOTurlpgTR+SEIdo5+JyDzzn4nIPPOficg885+JyDzzn4nIPPOficg8+9RPA5ThtOI+S1zUNpfG3ZgMYI
# DATA Iskhlhua2596hj6G3qC3dWW9N8N3Uine0B3ZaxTMw3syrfnAw4eNC710JeOav1H4KAoHFMCH9B/4UJeNefnhmj52nsSlMH6IfP1w
# DATA 7Y2ZE+kqgAv4rElRV80OBR2qBj9ptpJTCHcHq5ccrHYHql+SA9XH1Qt/tget2S+ZuNJmcUS9lBbmThR1cLbYYz+hOWbLJAkEskRn
# DATA +1mfz34Rzijy36es1T7vIPlpq7bPP5c/V799hWPyiZ/W6IcHIlCH0tayk6pyGI2ZuwFFIY76AYRg+GitVDU+Aa/cb0xkEd3A9Pny
# DATA 5OR4DjLIZGsmjZ3njNAzhQc46nbhmNYHmkX3EIFLVeNXZA+fH0dEfKaayIFcP7FOno1YzbM4zWqedwaVM6jmqNElFcoJ1jjBmpPa
# DATA UQvttbMRsuE+XTcDsqREu4I1MHajcbQz8oe7lqj4M9NNOwWAJY3LbygZGmv0OqZmsRgDCOQUBYvV2K8H874/5Myxxvx5yrenolr8
# DATA Pst7S99ItREKKej5zkC4+E3Y6vyigRc8pHz04sGpywezaPE7g3jS88eiXn6gkrePhA6pE+961N/1emchWzxhTaWx5s5MWAM80xpO
# DATA 9701UZ6GxHfHExF6Pc7R8He672L6461gFLMUE1aqmG8vsjDMNsr7IRnwkyE1yOCU1agbSSeasaCpOH3wYIUBIgb3KUtEZ1iTybRM
# DATA gkw7JukhrRXk9Q+M+SG9jcFRJgBIW1HdLAclivKYHNj1RzWhg0R9SgY0OXEUL5CWagOwqHWlLF0qqAKxuJR3BwLfwcBj8MqgTQWl
# DATA 5ae6inpAeZ8zClmR6p21pCkWng60VhLPiEaTVgsi+VwuzCRGNYl6jC+WcUA0jkYTCHl5OtOMjpdybwbyArPY7Svd1NVQjz+d6Ydl
# DATA ULgJiJuAzExA0hamm4K4KUh6CrJwYvGstTQVr4OZFrv+kGHDPmYYtjh2HCjdPS0FmRGLZNSOVodU6KNAJjOWzuPYFoDEWNnbBz9p
# DATA IriQrMSjtNgJNWXqu6gU9oI5So+rqm1yaodX3uSlzSTerYNkdsTc5dYk7HWMFp+KDDsaZ93G6vCoBaDX6G1Z7WdgFT4pC0tZQPrH
# DATA BJ5trrCKwC6zYrhnk8VZ2b1CQ7eVlDQEXL3XbCGAVao+vyobI9TLrTtMz2o/9WrEPWxi+GENHmMsNRt1H9uWkXLkZm+nCao6zPAW
# DATA f1p8Z7sX9lscUXxYfB91zBE2ZdGd1+Rjcu9FSduVDKZc25qyGm+bmhhRlhiaqdLFZmBp9uqMdGI5+6OOmZ7y5geZqKp8TOdDBszF
# DATA O6lNdyA7C2RiO+Hbq96DvklGNt4mU6EcWblyO2RWUydgmBC11op4CfpRPO4dKPglfoKVaKTYea1GeF3hYCxDYCBymNglGe9GSk/U
# DATA F+i5Fo9loPjASM1Sy+VpsXZvKylMD5aZsg7VQa3zzcD6MTLwfZoT99h3H47aNF1MshBzVOoYgOKyOzo1y4GnhLqFj9QWHerJrvIq
# DATA AdvGvLcSZns/auER6v0CqdNUFA9iWTRTFDAui9PILquVHDO/Npfml2lykmHvQvKT2sVOYLIK3gS+J51HBsElGVnw3qcxM+exSl5I
# DATA RtiB8j8piBh150KJk90q4g7TnHkaNhjjFnROI6tMx3PMjGoszSjVi0k2vQ0/jpjz4cCqVfxqqhD7FMuYHTH+qKdWT7VvBk4EbIPz
# DATA oVUrK108zcbP8P7tHCT+wgBLgNiTL+RcAMe4z+N2CEldRlfwTc+0TdaO0SavA0SHPo3aXZ4SnRfIlalt9mVqbkKtUxlprbwFfnyA
# DATA xT1NhKNHyOYX6WHOT7FFYmC8rBn5s6xgpfLqNex6REVMY2QvOGA3QVLHevRLYuEo7644/Gh2S02QPXGJsYYMoR6eHVZ6EVUtioq1
# DATA BXVgnMiJVB0la0VcUKARjsL23HxLD8Syt84eiM0VyYYrNyO9C04rT7MJpnanwSmiSlJRonV+F45iiP1UHBAJS2wYjIHmtVFi/01A
# DATA Yt706+kjj7FeoH99f/ifpo+m30+fzGLE/p/p4+m3+el3AIAd/g4Asn8DLuzwc7r+l+kP9PdX9PeP0z9Pf/QOv5DQEfQTQMceTb87
# DATA /NP028Mv6N8v8SawyOjNFMYjCuGRBpN9P33kaGIvAAV6ICs/2MfTVir1CQV6GERD5jcyYJ2Hdmp7YiB2Iiifs7cRA43lklZiuHwX
# DATA +uhEWJ3fQD1IKBLy7DxeShV7C+YSs9sHBw4nZvtQVEdw3jSxdIGcLUYsHFhruNd0LdW/zLLEBmMcAjR9LL7KSBeMTpMn5o8FUbDr
# DATA xzScwoIlSzfqdh1ObNVSO3Wm2FW/18aqYyALYAcJoNrv8057XgLp8TqJ18VUwmMuHMv9mVUOkHT7/YAnvxhLeB0x/NuA6RteJwzG
# DATA czBiR1a6xdZJqi09O4bYkSlwHDE3up/G6K55Ysce1F+KRZHzGtBPeTxfeTHkWKP5OQ3mUiPtPEi2Wz37pnMWKDE7reIYVjs4diN6
# DATA DosP6YQiBSaWurCwSLQk6e+Awd4bxkJV4qSN/fiB2quCCIQDnBzDMT6VJauhxAAwkqF6D7wuBWvqJGQnqTYyrLe1TQD4VISNdrAJ
# DATA sLYVkoEwxy6YQHchHM+zB5Q1wOAj2AFYvYofUGAmHiGc41ybqH71sEsbe8gm41EoZRYN2sFoEDuOmOOIOY7YGXPEVhppVjyBsaJx
# DATA fG5G/sl8j6dg4juamKOJOZqYo4k5mpijiTmamKOJOZqYo4k5mpijiTmamKOJOZqYo4k5mpijiTmamKOJOZqYo4k5mpijiTmamKOJ
# DATA OZqYo4k9PzSxdq08S7palSbW7VaD5gtEE7OXnY+LESvVKl5ls/FxvlLMlyh/GpV8qVbv5avAapU+LpUq+ZpXqpa9UrHsNcr5hoe7
# DATA cEepCQxYOus63c3NRneGMAbAV7W46ZXpHdWGV93Mb9KFstesI8iaVwPGyysh7E28rrKZDrZWb3aa3TlgrkrRAnOVN2sGzFUqputD
# DATA q9qoBnMCqFWtACoW2as5WyWq88hg5cZxn7fypVJpeBXKh3LNa+bpr1KpX66WKI88ZG6Rs3hxQuxSpDurtdpurdHMkM7MAzOks/oJ
# DATA OGXcMgynjBuZxSmjetRo+CtwyvxuJcUp65Y7jXbd4pRt1ruNhFPWabarrWrCKSs365V648w5ZcNgfCSlDOOLvm8FzJflKKuwm6zQ
# DATA 5OUxDGkbsyQwE7LGnKVmutXaL70a/SnX2OmYQnNJjkoIKsKrOdVUqoxjrWymu5m3l6vsC2Q3Xsa2Ec/TEoSXTlcuFb8lQ3jqNu0C
# DATA c8guh+xyyC6H7HLILofscsguh+xyyC6H7HLILofsesmQXcrisDhcHf8g3rrhj3cL3V5EExuYfR+u4TAWpf5XMGkuqmt8PgoX5StN
# DATA s2CoUqth6/PDte0hTfAewkUZ9A4oNy4g6AuUK92JyIXx8bCupXOlzlrxKhJIWUBq6cNcvjqcBQ0yBCnHbnw+pI0DKuYMluj9OcqW
# DATA O3Z83GPH7rjxT/W48UnwWs/BMWR232l/13LKlghYmXjPPao8h6/1vBxefqHO8J0FcCt93PqUSVuZynBSxJblSE0OkaucTrAgkGcU
# DATA AXmlusLZtVu58iZP8FlXTuvQcfWBUOhA6c3JQVhTffZ9eqIV7eO0c7Az6UG+T8vO9SEnGnWhht+ZjLiC+qO+lr5XZ+L53ToC22Rb
# DATA h2T88rZZHQVNCaPs6WKRtMVanGP4iTzenCKWCZZae5w26NlxW8CJylaAF3fIJpuMWkZ48iU56mmF4ewqZ1ctEWuzK5fTdXG6Lsc1
# DATA qJbgts5G7+XXg2gf3b8oDrT8HdFYg+SGGthK5y8ndgp0LV6BUDtA9LWUNjxP9OnqewPoLQRKhsW4xbz1BzsbGRLQgNeBEtCOCsJ0
# DATA U/p7CodEiaYuGXoy/ZDlbYsF9NnUs8iWHDGOsJcz+XGBnL34IQD0sQVbhtjiSoP9+pHx1c8n/aq+kEC4msV5cbZjjO06dpSXRJg9
# DATA JUxpgrs60bFBRh0RV/Woiar+nsKFLY1naUksMwQltb6E1qqcLqJGzlXdoiShUl15VfaaqniqNUZbyze5JL1LuCcpoPFXMVsvShBP
# DATA R4GymE1W+7aFj5Q+vUK8+Gj2Rh/wGlxPdgPmBs1aKcHDUFRceLhDj6NdUB9PqBeCVnk82dkJ2AMNYASvTKgOIhoBYwGoEqtKYxTm
# DATA QAcAVPQ0jUsYaOwbV+0OAipkyk/YH09FAz0YKAT7O4YRCwUqGKexjOSdsMvSKWPRH2JlZ09t5Q1MfESOHtJEHI056kSJJBHLKsPT
# DATA iMh4/pDqHAa4VdlOPxFjNzWCOXPXmbsLzd0Z08ZZvM7iXWzCPicKh1dZfQ+axV0MMuGAZczm8500XzaRAhwF/ZARHblFqntvClNw
# DATA ZrhhYbOdSdgBzjAZGCk0aq+dCQCEPLxlTeA0NGFG4NDcR+O6YZpq3xMP9e8xJwDj2SiiocMf6zGX7fA+NfAJTChlB/g7o0DjK2eH
# DATA TKV/SCF1aKg2yYGrambgZGlAiMuw5yhgTTjPH6NCU4Qv29R2TYYMHvL2KLwjBNSAcn3BjEAk3qI93t+kGJyanzvUDC9s5BRQyMNg
# DATA 1A6x3zEFQZUM54Jh0T5LqFB5yQreW+BscTfK3jSGdu3C5uK7GGACYiXcddeDMfeznAyYNv4442/DwTUTWY8PN4B9siyN21qO0vT3
# DATA OpHvY9am2Tuq74fKZE409zSYCI9g/ZEKuhfnmI4RG2qnNrrETLqJwNBTHsAEUxsteWQZ8ZDUgqUddMK2LyWo8JnIypmabmHOgoc0
# DATA 5vUOlqXyJh8pNuYX40t0Ord5p6c6JDIZ5eBJZoXxvi5+nj4qUk4I+IkyXwdQ4lPinxYjjZOUVqoseHeC4AFTQuCWZZ4H8pJvVdVC
# DATA K1am+DLsPxVuCNQW4SDWjmI/5kmtvzOI4jCeIXOwIXaUzvfdiDomzs+kC+JWc2xSNPu09Rh0Kpxoy82tGgPc2+zEPgMy9A1UX70P
# DATA hpqrj6or+u96mnIGlOirKWc52iyVt9Blz4AUfT0c86xsRN0WhCAFCqmYNdxzisDkGcCib/XkneggObVJ4+JpVucMQNHb1AHpFo9e
# DATA qmP0dblI4S0adU6ZnfxTn79ZXBx6ahzbWJz/AgjO9Ifpo8PfTX84/OP0sXf4GRA19PUxXX5y+OUsGedfGHXzrwy1Sd89/YYpOR79
# DATA 9Pn0q+njw39QofwjuDh07cfD3+MJetWX9Mv39MJvvMO/T5F2LJiOQ+O8AGRhBrMZ7VphZMHzC6RHTrahChe4y93WPqDc+8qi2glY
# DATA MfgBHM6CEx5rViJDRnkQBUNwp7ecgHM98Lv8Foe/Sc0xub2fN/3GKoyzQ99I0pJuketOl+dh2Vsxcpgbeao32j0Y7/ZPE3fDm2xp
# DATA 2rOLGt/hGQGQe7wVE7c77M2RJXbqvBtMcqMW5phcz7THGjtF1HSY+5eeP+qrpalk8hnG4oqe2UMt+uls28pcgkqLejFM68h0gYN7
# DATA Bn+zvP4tNj6SdvSssDfLY+6IN27QPsagrcE2xxurXw5f8PmM06c5TK80Sq8+SJ/9GC3VzyTaDMjn1xbOglRj0iOE5DibEL3/ItnE
# DATA wPbEbtTXMBirTGSmSwMaBju/wwllCrohUsSKsdyOJiNhUyTjq064HGWnlyCvOPjVuDVqip8ag33jXNejtxm3Y7qxM+kFekskL2HB
# DATA q+jFw6AdBnHOxD9hFytHay8U12tAna3fDcYHKVegSgfjdBkTzSjgtiQqnSAHqHGAGgeoOX1AzdEDx0pzjlXs1/Oxv09ifj+t9e1g
# DATA NA5G42A0DkbjYDQORuNgNA5G42A0DkbjYDQORuNgNA5G42A0DkbjYDQORuNgNA5G42A0DkbjYDQORuNgNA5G42A0Dkbz/MBoKtWg
# DATA 0jkpjKbUrb1QMBqz3HxcEk2l3PQq1eIu42fKVa9UrbxdqZXT2dHuNou1Wf5JlRJQqTZ+UypXsvyTaq1dbc7jn3AppYOpbG565Wr5
# DATA 35U2y165XKQ/DW+z9HGp1vSaXqlR9kq1Er2r4pU3Kx+XS/V8qUJlCGJONV+q0y15+kY3VemmEj1Q/XflTXq07FUohErz4xK8yFWv
# DATA SvdU6ql0VYPmZr04C4iRCOXJhM+XSs1+qUr5ghfVi8DzZNLa3uxs+u15aVXoGSrFkMwPxa6pFmsJu6a6WbQqcFW+HMypzZ12UG93
# DATA T8CO4Yps2DHcJix2TLXc8GuVI9kxrW6nW0+xYyg+zXbLYsdU6psckLBjqJPY9AOLHVOrtSrVM2fH9KgVHAmPgdPo0+RWQ3mxOC4q
# DATA dbOOPXbulenf5i9tc7vB5kMS5NFIGps3w5vtZG/xvFgY11VhzvopWVgeliq9uvxJheYpi8YAZXgUNb1/ilwjRZxJMYUJy8iryR/j
# DATA GpVkN2Fc2f6ckrXGo4JoUIaV6I/6V1uYbL3ygLiQVrNCWaazLj3HnpsRCwNyUBsHtXFQGwe1cVAbB7VxUBsHtXFQGwe1cVAbB7V5
# DATA yaA22iDU0j5rG68tG80YfqN7fT51oR7LoQ+c27V6KmVWpdq6Eurea4tN4o3LaOcfrl1N1LxwWMWScxlQDitNF0xf08wac/LBnRt2
# DATA 54atky/u9LA7PXzU6eGFWpNncqr4ddRcKM0lgZuTxc9Uf+IU9NKhNYc37wfBAz7hKG32hFpzydhyempzQdBTqtwtWSWhDNHqg8rR
# DATA fQayc/q8sQK3DalUOyNoz3k0Rwp6B2egOffOAIeax9LDxkopG/ZyNxGoPgPxubvs+lJpJBNE9eZUJ2jsyEP9unMGunO35SgxfIBk
# DATA yqkkG7jAmZQra8/dxFlr3wjQoeXJCAeThcxL7IWajIJTVp9THhgjHZ9oMqaUAZLDrToh5tQsZRi6gHGqB7Ek6hNReJGAh4Rq5rA+
# DATA 90aFRF2zMzrQGZ2gGvzePriF/YAl5HELFqrI0Oj1Ct71sGuaQw64h95sW1QqqgNEZeTt0o+jAAtWvQN5kruXfT+W6GiikFKr5Too
# DATA Ku9obPDminY1TSqwxL6nAqDWQdGU+rIL3+BInYiHTiY92qUhZZFkgM4VfdyfuskBTr7zNgMaT1gKgEbqrMRPZqS6HeA4oDrFLZNW
# DATA uUPGnaNl41/wk8cOOens98R+dxb7T85iPy5S8hnqAPFivlmIXs6RfDNk+XMFR4Ho+cDjvbxLIJLnLB/03MtpnAUfMhE5Om04pC0H
# DATA dVIypLVJQU+bbuNYlakOMvFj4RQlPFXOFCR2NUgpqt2NIDa+PpKHQQPAFjoNbdz2epN+OIgmNEU0NtGAKnkEEZth0OtB2h1j6K5S
# DATA XCf7a1Dw3m2J3D4ZJth0DS2lXTJJFeaAeTb67XY03oKBxndxYnQsbsIuoiAodlR5qdZYZhebfHx+JOBtCAcxtNT9mCXUpYVojec+
# DATA JKxHy97Pbmgv9e63pAXFZF7GvBRd8G5E8VjbfyIuxOwfHevLyCBpX2AvQfmG+mvYBhC2p26EqjrLhmRj8lMXibF6BmerOVvNHhmc
# DATA s/XldbYuZk4+SwnHG7xYqeuzEmDjo9cWlBLSegxH2IN2m7SfxHmTYzcCAybZiaYdhwXvViIGiFM4otJm0D5chuw08C39QPZpsu+g
# DATA G7a9mKb7beNZafFWskQzUDQXV9SA5BSL4yNp/LLWh5gM/NFI84T4cAneA6/PHCNRnXGcpV2qdW5UUv6k/GTKk6V/TICI5grnOLAj
# DATA AYcjTyv3U9TrWSmYS4A0i+dcTeTzq7IlQL3cusN0lPZTr0bcYSbuO6w+Y8Ts9fTSaAh/aKSsueztZDdwq4r2F9+zw2YPI7P40+I7
# DATA W2ynsUb2SKwUfedFSVWSDzIea2+hrEDbfj4MDUtchUttRsvz6Y86xgnPC/7ijlc5aOVABiTFO4NN65eldK5CownnxLZJQDbGkpdD
# DATA NtiuQsQxHEHIFPU+MVthr+WVJmdOJEbzmJlpDVIaxvpRJ2A//hj2LAw/bcEJSsl2JsIBaaQ6AxYa0kb22PtbGnALtn91RV+qZ7bJ
# DATA saWRTorJGi1hBsArlru5EdEzltM1a8seq3iSynfMErqzuIR0NZZCujNkH2y6hKgZc0ciHndgX6CVuUv2j7hBfU/qurL6LXagWQPB
# DATA 87IKIlKrEdRHMeVA6WIHo7JSnr5s7BQ8/wVza9WCueWPeiwq6/f6umDuRF2GsQ5oVGPN1H1M8mgE3UnPzQre9l4UYmZMeW/c+jnb
# DATA 9c2lMqT+BZOzjpolYnr41OVhR/zcyiPpe49ZHn+9uDx0Ly7l8ddksMx0ZJN2e9JjNVksAqqThKpx6MmqYulRL8UrCTiPTUNGwXub
# DATA WtdBjoqQzJAo7InKcZ97sajfF/lnMi76whKjn0LkoFkvfvqCSlL0/BfT7VWL6fak1cr2Z6+ziLXqzYLBR9FB0oNpMa6C935I093O
# DATA hDr6HVmKMvLJelUosfDA1Ka8avsToeM9dVnY0X7+O7E3V+3EXg9HHd4xMIADiBrHwGo8u6J4vTvph508FgpZYlyVB486MRv2kBYa
# DATA wzJ/39dc6mSd3+btoYRNb0chkfGktk1ACxnuoacup9kEnai00vafbGO07T9zRfL+ys1IbzjUGtxi8ovFzUv/DLX0acaC7NClrBZO
# DATA z4aJ9kJ7vBIWWrwbBSkU2v81/dfDL6ZfHf4JrDJgzOjz59PH079Mf6C/v2I82jcew86eTL87/NMsGO2/MEbt0fQ7evbPHv3FAU6f
# DATA 5CjE6df0jdFn9L8fp4/NS2ySGt30/fQxPimO2l9ARcP75b0/Tv/t8I+OivYCQLnNNgfe8hqN9zV21ZC5IV4s5NUcz4x4m1UAE0+z
# DATA AAANhTuBZWSoAxA4AzrQIegGiuhK9Xg05j1jeK4rS1jGKQBPx1JyGpTl0RTEznf4NNvXx13EedPTsgVydgg1Gi38XrSTIL54hyG/
# DATA PMvhvtgNk276zXBs4TtOj6EGU1qd20ANjWQE52xw+LSjS+vU+Wk3BAPutci4wI4umvfv0rhjppc5bWTFEQ5DISNhyCKZ6O7UnlbM
# DATA bxRp/CFUUoKkc2KdrxzZVLIcOQrYs8iEWX1MoE9FJHgNDFbjGbba8nq52IjJtLJnBVhbHn0HWHPj/ymP/xrCdoJh/6VY3jufIf/U
# DATA R/yVBvxjjPdnP9xLRUwn3Yzyz1fzOQtuWzrhPEhyhhjomEl16wAh5eQM42gir5K4jgXoFPd9LHyZpTdP+qVWEMOlFYywNMmJpoE6
# DATA ObagotcJu4btRsk+8BTJZEVm20iZa7ytBkdWyKBgv0TQfoCxSaHJuI4J94pPDfNOIKHNhTHvoYrHQuPipdkgHoupgHxJLIfLimIG
# DATA etZ4QiH0/cGki88j20hQnlf4CdimGR3ko4FDtjlkm0O2nSGybYXRZaWJziom8Tna9Scx65/WqnfgNgduc+A2B25z4DYHbnPgNgdu
# DATA c+A2B25z4DYHbnPgNgduc+A2B25z4DYHbnPgNgduc+A2B25z4DYHbnPgNgduc+A2B257bsBtpVqlXSmeFNxW69aD7gsEbkuvOR+X
# DATA 3ka2qlepNj+u1/KVutes5EuVco/+KZe9Zs0rFemXilcq06d6vlzp1Te9Wt3bLHrlxseVKl31KjWvWn67VNr8ON/MVxpeuZSvZbI0
# DATA 2OyWO60M9KzUqNYr1XnQs83ZkisXvWqxtltrlPcq9bfpa/oFJqw0ha1MKSjXa16jlC81+/lqw6s2vUYxX2rQl6pXrXv1Jn1ZOWKl
# DATA ykzMaiVA4hof5ytUqHnkRf0GBYDY9ip0IUWL452c6ZcF3UZ9AeZOVeB2OOITdg+l0pcT9FupwSA5VjWop1uACZYCgGHjydNFZK0n
# DATA Dzeb6Wrf7fJ33f+yHCqLv1aaVG8ojGNi47gZaWyctEgLGxfUmtVaLY2No5uq5XoKG5cByQk2brOzmWDjqu16rdZIsHGddrvVTbBx
# DATA m53KZjE4c2wc2t/R2LiKNgrEJNDPLODHIZkZ/2Ltl16V/lToT732SzuIDC/unT5NJcY5bAVGfL2brNhBX+2Y29OkWrF4OevME3dP
# DATA rrm3n+NVsgUrYioagFcNP1l1qaBQtfLCq4zSwXh6P0XKIDHzJeyq1i4+7eVMM+1UJpXpT6mmTX72FYVjsrDaKZCd9mFTv1yewc8V
# DATA F/PlTO7n7BxYYoockUC2EhxHznHkHEfOceQcR85x5BxHznHkHEfOceQcR85x5F4yjpyyONIdQDig8Ldg7324Jm2OEn5BvkMRhrOB
# DATA TcwP1+76I6jQ8iOe3IzmdYEvULV4E5vp1ksbFyg32v3Ch/TfYNs6JX7tvfQxPH74hj/eLfAMfZ3D+VWpUEMIyfG+OYfGE+VbSHGZ
# DATA bl+j5pJjK+4QtTtEvcohavtokztL7c5SL9FLfrZnrOVocE6f9Z1z0vq2ORcodSSXVlYzh3rlwKoSZOGzxLCj95UOs5zkDVhlPzk8
# DATA OfQPMJmWw5PQWhlYJydX1kB+U1SPW8KI6oBAhVf7pkNHR+B0j1fRPW778cRXsmn4tPhOdKmUtbj1ffm4+F7qYDtRxBn9rnx8ERSQ
# DATA k7w4pgji1cUiiDpXRQSRjLLRQQc6RP5gz48TBUScnKTmBQXxdsRuk8lwiHPP2GiAw2jeSGQhY+A55DA7e8GoqQUFj1p1iKPDGR0d
# DATA Hg87o4OcF/jxATeUp9c9zKTh3CQqrfp3eoqhpiYrnWrYDqMJzMikbNqTeJdqbsAiuTiDLkeofZGrZjMnMSJgVcIuEQwDCmoX3Dt0
# DATA EYkytdJz4OPhE9QP+EtbmnnyVOrUSQJegIJ5f+WCuU1VPQ+3ygE0wC3lUD7YnKMSGQbcerjZ6AbCIBkUHPVHaDhaNxTnCKFYBcXw
# DATA YMi2ITLcUtMQwQGsbcn4FvZ2owlLjz69vmsqKedWSifu3K6v2rndCLFzBhoek5GljEwTFJrzYVfgOBrqptMNR32Ik06GniqYaMQS
# DATA bPyrqJfsU6JGUUu6u1GAr6wbNhnsklEFdQNbxuNpiiQV83MrEWuQPGaR3F1cJGa4lTK5O/LDnuil+GTWmEKh72MYJ7DfIsnhDk17
# DATA YOShahoa5shXzUFpVgMmrJVmEiWJROxNRFh6B6L29tQFk47+899W7qzaVt6XOSlNUMMhVWFTMKjdsJxp6i5bhGBY8zDO01Goegxj
# DATA Hu8xzQePFhtzFTIrFs1wJRI+ZlFrlC48p09dFJkYv7xaxz8FORH9uPNuOe/WKt4tu4o575bzbq3sxVroBDsb7xYLbxkAnu/tRJGI
# DATA 4mnf1nOrX7vM94UjDZ7tAZtxagndFBtG1D5kfS3lbVLLM4xmGmD/PU9U1ULperu/odxeumHKpBSlKKGa501Xllwxrp8y764doedG
# DATA L9YP2UAq87bqvs9bXvVG3mDIW68LpcUOMl5BQi2PVLkOjWpZ2k+mbjQx0w/OuKZKitALu6dzySt57f5iP1apUGMHAgUWBiO6u1BL
# DATA 3T/jy1IWlnEUyqYbCuKali/M9LKWmYTyoyjw4SKdKtl9ZZsuySVp4qGYZ0MaD8eyIf2iBPGUBpAYKRiMrPZmq1neHYn7VYix6Adm
# DATA VKJ7rNc40F7anMwY2IZjr4i/44ey6wpb4gUjRbOHgmcgd0k9LXhcaDke/CwgC4tXJkFCrzLW1jFeB2tqGA4EY4UwySI2EoRYUGQF
# DATA NRwag6Rj60Capwjz+VCgtFcR48kO+LW8UyBZw1TT1oGWoGS9ykR2csIW6oFntgvoPXFDtmE0XhZZ/ZM3PJOhxpmezvRcxfR0tuZP
# DATA 19ZcaB0+h2rVfKLDnC6YNcN6lhn6FsxOjhUo5KNAlgljbYUmD7HsEne+z5+69fMv+cp/yzmdK69SD5ptWPpYIMI1R7iacsLPOrMo
# DATA F/wef8uKcGeP60kzbUeYLMi7DgZtMb+N/tWVd2dO+/EOPirEGXFz6yn+wmlZQVg8Obai7bEMHHzfP+DpC/ScjWF2lZfsZHI0MIuC
# DATA 8CfuUEjDA1lelLkTaIRDf4/nLgXvNi9njbUFpe5R9hlqJVzG4oxjgye71uVjPZysNE3rWKkSZCvTtYfDHkKNw4fYui7LkFK9zx3u
# DATA ce7GU4Ipowq1F/R2JtRd2LCyfzn84vB3jCUDQewJf/4O6DLGhv0ZRDH8cvjFLKXsfzM/fj79dvoEKLJ/4wt/Pvxi+h0u5bzp19NH
# DATA jCL7Hb7jBn7d4R/oD0BkX9HrADJ7Qj8/YpTZtxTAD/jt8DMK5lvAyg4/8yiMR3ThD7gINJpjl70Q1iHSxlMv+ENYrlzX3ksgkvqj
# DATA B1jl8wdBDm4PmpWOeO449GX6g0GGZqg4Ks1rSNDL8CYDDoy1ySdhj9mo1KJ93s1JE0t/LJDUAFv1qTNbSi0TmHQgA6WDltm2otVh
# DATA nDe6LFMqZ0cu64RyDjM2d76hrnBFnaGXYdwzd1Klk5o4OmV4Gc/zw5g3IKA58M4wHVVHMFut1E6dYqY7m27Iz/k9cSrF7d2gM5Ft
# DATA Ij1hx0Pyg0HO3It5rPbqlWr5fjiAre33qHJjH8ll7elldIZYYaOAAhaQQjhAFyxmoLKMpE32DL551aq52MRJN7VnhS9bGnlHL3MW
# DATA wKlZAJpbdvyB/6VwEJ3noH/aY/5KQ/4xR/wzH/ClPqYSb9PLnovmcxbcslSKvUDm6LF4pJjC7UXd9L49zobxLsVyh9dN0OhC7NM0
# DATA lhEjjvr+kBMur0UfJecGqHaCuoSlFo1Mkv2aPOJKvfeMOFu8IraMc05VCo+yY4LXyYAPIIi4y/a1YUBFECOWXgcHfvDyB4NoX05H
# DATA dNTmUmCjhgEX9W40GYH9xQyqsBX2kFWw7hi0QuMR46ZgLIgGAuO5zBkCBXIaRPPhU45j5jhmjmN2hhyzFUealaY8K9jH52fin8TC
# DATA f0oD34HMHMjMgcwcyMyBzBzIzIHMHMjMgcwcyMyBzBzIzIHMHMjMgcwcyMyBzBzIzIHMHMjMgcwcyMyBzBzIzIHMHMjMgcwcyOy5
# DATA AZmVm9Vao3xSkFm363eLLxDILLXifFyOWZ3ypFjdrdebe5XN6tv1LIKsHNTb3dmcLJYoK6u7tWaDP1cAGVOfq5Sx/LnZ9EqUw5Vq
# DATA sV9qFvP0r/pc0p8zUC/K+U63PA/qVW7ORKFcoygUyx+XGkWvVAKCzSuXiuMS3MbNo/BhjZrfaM99U60+g0MrNWrgknmVcn6z6pXq
# DATA VUDQSjXKuFKFyW/VzSNe167UW/NpZRZELY/pgA+BfqnR3uYckBnFJQGZUaQMyExwbEkLqFa6jfLK+Vuf86pysZG8qlIqneGrKkJk
# DATA k1eV640zfFWtbKeqWTzDV9UZRadTVTnlDDwWVI67NA2Vk97RgspVy/VKs5OGymURcnOhckEpaHRqCVSu1qkHzYqByrXr7aBtQeUq
# DATA 9N5m/cyhcrK7MC/LDHqYq/AMwtOrU8Z2aYr5Zz+ThcK9FVBnHvq5WfpbdR79Df7Pxt5+ri7+TxVy318N8lZoLHNr6ulZEmh2gcQ2
# DATA 73X5zHg2VcmkwmFxiwWur1+0mtSBddJOr+PZYR67a7FUtRgMZ2XVEntuJs7padEZWoeOMecYc44x5xhzjjHnGHOOMecYc44x5xhz
# DATA jjHnGHMvGWMOdSEc0wx/5EOLnSrYZYOd27ryiZmTDOMtrifSS/H5ZVy9Z7V8afhbV0yzD7vrP+NHVcPd+ERx6bRyEcRQ5cwXI46G
# DATA 3FWLcXn5U3l1ZyJrz1t2QL8S3B0uJQg85tLJko59b7608atS7UKphujo0K5IAK0JzRdRqCZmLDfLCrSDIOjE4N3pZwDJExmC2Ggv
# DATA dYN96UCGcipPxL7oEp9gTCUHGY1TjFvarB/hxZJVsvi0zhO6jYIsPqyv+7m9XEiF4F9Qhvbexq/WQ2oaxdfqxUuljVwRm7641WP9
# DATA aau/dWW9f2WrVK0WX/tw7SZVST5iyaEig5Thw/nU7UU0Z+1frBc3flmubtAMrMN6Vuvl3IdrRdzNj+ln+r+kG2dvupzUHMly1ID1
# DATA mGOtqg6cR1scv3WknlGD/+Ozf0bGxpdx5cLWvMJcD19NF+Jrpdqlos5NDvXypxuFj6JwQM8yuFAirT5emPPKbjgI410lilqq6cLE
# DATA aVlxuAgA8b0BVCYEB4DnGXq4nqkweV0rNuxqQY2H65HJlg2K5GUucCqJvJ5V0POvLTMZueWh8SThfIJxkIwhdehYK2docQsdsmYr
# DATA 6kpn5l0UuD4PXRg/RD9jxVHCvqPD1A/RgIuwDKZRH0RzShFOKWK5UoR1TNHpRTi9iGPrRSzUKT0THYlbk3HSAHjXltb0lJHdiEo8
# DATA jzJG56FjL8aKyLiPxIrJKNfjUqJbr+83nZe5YITei5uX1IK5Eq5foEevBlxWpB/jZDnzkIyw97oaeY9S0jfBmCglVxIl/WpxnpR+
# DATA xZbSb5SLtpZ+qbZYSt8yaBB9jjhNTGhWxdUqLaefutnKNzuIGbV8jtmVSlHbH4t19ascz2rt6DvrHGZ9Tpgz2vv6ACOlmw8iXlFG
# DATA sTCD0HLoVvlF5UzChMKkgdOULjft+MhmQqqcbiTjGQ+FMgG5Yl3OFMjpvPY2xk1u8fZbk6tn81I5+OjRQDuibiL15vRPCd4zKZeF
# DATA dATpyRQm4MVFIlyHf0+kbpSxoi15WznDaMx0aEJn2f2pTp7NIAh/pG5RArxUhVl7BpIzrKfBcAMWc9AMgkUaNGnRGZsKNsv/ms8J
# DATA kwxMzR8wEuoVCvZt6SHIhoAdyTd48cUt0haGm5e4eckR85KU/emmJm5qcvSM45lK3GGMRwXXkUDm9BKVuzfNRESAB6z5ZNoalZ4f
# DATA s8gVBKdYc8yIUOVEOa3vi+PSCKFpsYbs5CKDXsA2Gxv7LTxa2wATvub7IjwXCGEWrlK0b0oMVejYTGmY0UXZE388QTR3+LdJfEBj
# DATA 7oCZXpRA6SxyCkIk0yM90DKQnruL+IEOdLgbjaOdkT/koXoYwJBW8r7hiKXHJInpYW/sM1b5RjQSZV011mXhpoJItiw/Sa2YIxYO
# DATA jTsy9G37CoOMbYKqYxPfPVan9oEihz7ctvDTBCux69t4UXjIQRhgqTX49pbFPuywVbc08lnjUVJgkAICEY4NQRgq/mMDem6zIJzC
# DATA X2hN4kRZT1i2ae09VSwtdNnCJ7B6bV/q75I0bWOH/SACuTWbLDET0tzYGVVFU5HJLLwF9756M/KVzLZdEHwVskGygH8AsBeRx1py
# DATA m2XbYNTkUIkGkhQw7+C9jSaxyg8VcEj5sL0XhR2WpGaVNgAUJEtpgIqYGNuH1NqQT7rx7pT5U3qO9a+FJqIc4DIp03HGgnpKuDrq
# DATA yiwMOnT9ftSRxo3C48umrDx9eC7qduFT12WnNaylDHPecNIiC8V6jvXnuBH6HVhA3ojrsFRWGrsYXsyv9EBip0GHLO2Y2uSyJN4B
# DATA GlzBvcYYRKwkglAmL6SeIYS2F3V3lNYhPd+d9HoHireiYspunJgrqqS7nyIVsrKg9An7u5FSR6QOEjtBqYhHu2iHUmDo47OIWjFM
# DATA f3r2tKOFOVt6ZTVoZzr/pE3n47LCnrE6tL3nfzks7C5GAg27ZKNK6vtyWtjzoyb9QkiqHkWQSPb9a5bXaULF0grZp80UyyqOz0WK
# DATA Kfcbq3mjUHkXGhlBUiNiMWuinu0ODYa6E7tyk7VLhCtGUxXWJ5ZJE72Pfsc9b4aJ5YzeA5LZA9jlQiOjepPcKzMT2LSyOz2ChRdC
# DATA iuxA3XQx6i1qnmIvw85F9eWphT/PwbgUEwJXrCE5z+iPwwJjGeLhCDU6DkwzEwVn30xXZZsNGfZ93EV2bsrbSjY3RIttLXS2tHkK
# DATA KTk1YVFybeDOrLPN2Ho/NSsvwZrtBy0lfm1Tzf7z9PH0X/OHv5/+yJSxJ9Mfpn9muhh9Ovy7w8+mj2zC2OEXuDILOPuvuDz9ih5+
# DATA zIiyxx59eUQXn9DlH0Amm37l8T1fM+PsH+S+wy8VyOwRSGr0gi/o3y8VyIzj8whxOvx7MNCYd/bn6Y/0A93/jWObvSi2rDRyNDwt
# DATA vs5LVoa8iXUgmsOJujhP3iIKboxWjzhSK38PKovMkBfvUbTHXh5/lHiVLBIimsdSlNnb2Wg4nJlt0yYdxXnTzOYUzNkRzcSnEs+8
# DATA XF3P3i47CMzdt4OYRqC2DNhcSKeMNhP3kuj5w7UiC39MLXBgs5UK79S5ZtuepXeezAxMDeBFYwjpTHpM4Wgd4G+cplDuOVBPJIJi
# DATA 51y99R7dL5rmOc2p0PtdDMSE7Z89wIs9utib4ZmtWDMX2zizze5Z0c1WTIrjnDlr4KTWgMaancwIeCmcWudoAJzF+L/S8H+80f8c
# DATA B3+pnzM5YaHOnkkLOguy2UwimW5GWRXPRguMM1lW9qh6oqZeEtBTznv77t1bd3LqYKlaGeaS4T2jI7IfeGWHk4ERGk6JhKY0UmWp
# DATA PQ86T/WYuyrezFQFj/IaymBpAwApC9vAnCVGQBpwNhwFHfhG0kaBbQzkuJmis/BgYAzayjxgqwAcKjEPBTnF8Y/pNQndjJ0q8UHM
# DATA RynVPS3HN3N8M8c3O1O+2WpjzUoTn2MZyOdr8Z/E4D81e99hzxz2zGHPHPbMYc8c9sxhzxz2zGHPHPbMYc8c9sxhzxz2zGHPHPbM
# DATA Yc8c9sxhzxz2zGHPHPbMYc8c9sxhzxz2zGHPHPbs+cGebVY36/WTYs8q3Ua39QJhz2bWn1dCn3HmqsxjSpjQtqrl1GGxUr2czvWK
# DATA sJwk25upjOs0g1rQzeCbKs1aTVBdWXxTVbLYioe8W+Ih7KskHpXsobVyEo1qFls3jxdWt3hhpc2mYVClCGm/qHaapUZltuY0q1R1
# DATA mrtS56zk+fXWZtufy09blryykNLOKHlli+a1cvLooVNLXkUYX2eUvIp6+ljJo4eeKnmVcvm5aCSVSvPsGkmlXnqKRlJpFp+6kdjJ
# DATA O/VGkkresRsJkve0jcRO3qk3klTyjt1IkLynbSS1UvO5aCS1SvXsGgnF4ikaSa1Rf+pGYifv1BtJKnnHbiRI3tM2Ejt5p95IUsk7
# DATA diNB8k7WSGxga7HpVWu1vWp9t7JZ3ctX6/18abPuVet7laMAqosbwUlomGzpGhomG80WDbPSqpebtZPQMIuB3y1ZNMxKPWhWDQ2z
# DATA 1W53Om2Lhlmqyc9nS8NUm3lldmc5e9Sym+Fj8oSdTHTbqbbJa+xztk2kQsX8dfae7FaF2SWzJi+ZFZrYKiOLZqlQ1YL50pDrvHqW
# DATA fkzPAudvNkzuptnkzsjvp9bojkquembO8vzsDXqlfibPZ+9OvIiLdkjKi0pSROIKmAkESw2zqE9V7dLLBZubm/DAHA/eyR6jOali
# DATA t+GM73l2u9BC7qejdTpap6N1Olqno3U6WqejdTpap6N1Olqno3U6WqejdZ4CrXMWzbkTthRAEatzMD0VHFMzqOjKxVKx2qw16pdT
# DATA cxb1GB8exmMacUiG+WSIKxdKeLJcvazYmNfUMXboBwzGu70Dw7liRCLFhOrVm9jfv15mLOJb4euCVLyOc+ZySnnYm8QeBJs99SJ+
# DATA VkVp0fPbXrn2S/O2RGhH5qWUB3sBozrXKQ6/whr/xryQbJahdc7UCcI4QZiUIMzsoWOnDuPUYU6uDrNQSfksVWN0Zw05CGkvKC5W
# DATA csBGG955Y0nIPD86ZucBNJShkkEfMpCxCgdfPQIkqJ9MdfNxCtkGN8JckGDJ4gjyTUV9p8EJLqYJmuEcLEH1GWGzYMkQg6JOgrf+
# DATA 6/D1o4CIVnAmKfY1k5ra0WkpHyMZYm2gB4BXVEyC9RtHx1c/ZyJrLlgxXS3TV4yptoO4nUIoEZIjid1CXdcwDI6qLkkgCXgyuWSi
# DATA 3jgq5vUlsV4I+TNdgJ4y8XioCvmFh/7NI/0ZCzEwvR96JqpjwvLg5tEx8jqwDbhI/T7PAXh5hgVh1FyzTZMqVotmqAn2RtL0Juft
# DATA 71LlI+NwtBNYoanc7Xapr21NRvBt4DmaXI0CKDSFYy3wo/zVMvOIWZablZioSh2Igcw6mHY9K3hXoz67xajryymxnkHH6D8loktq
# DATA MteRJ/yR0kVKbJkEMtuneE1G7FtV4kMrUAN/akoxjnniJgILJgLO5n8pbP7jkk6eF6VIe6fEcuTJWyGPmKKWyOvREIkbsGoPta1+
# DATA sJR98uzkJV8sdbWj1KUzezzOAnwyK6B52vCTeTqkcwEoqbLTW2KkIs8D/L0Je16bCHPvYFXPpXe8Lqa1MTSOKfetyH+MqwxZcBAg
# DATA EdH49MdS5srcXAWHeSeZdmu84tt3b1zPeVfv3MmpcVjaCw8LSssdEEuZF4nQ4hAqob5WUmWlRioFI/sZxsm8QYPtuIGHYwzbS4iK
# DATA d6QzkA1vy2GR21YkVCXWKdqGEuhAyaNy7DhBlLBOAJpfMGhDEXQQUPyUHmuOai9V1129zCbyrGlV1qVoznQHckTUteCsWNM62gqm
# DATA yAa3OmAYiD9DYKQw+0X7ng3o0YGSxFSxLHi3NKcGMefVMd2R+V7XD3uT0TKa5W0JBgtXi3iWL5EFbvfXzgZ3NvhcG1xVEueJd574
# DATA lHW30Hh/fvTbuU5jpE5wzr4nnkLjgRdfTRhj417Eg2RafFy70LP0s8kQOMGC9xvsET8wiBa6ozNpQ0Smj7HYSBsbfzsTjdneWVnI
# DATA PdEtkOaJr1de1YbfHRzz5oYN/YpYAbBlxqH6glcvGitxLL33eISPIsyNV7XFWU/2xiiiMZga9u7cG96TMb0LavOCW96HyYZUihY3
# DATA i03j1ot450X9fhmMstFQhqoy4IzFw2/qXHlDbU7kGpzzMKx0qe+PqMwY+0lVbdzhO9UYkfNkMM5pqW1w7oApjncl3I6K1oJ43PAH
# DATA VKc6ti1oIrOdSOBnfpco2Kabsb+oREcBxLt58UBbXkdH5DfhaDyBojpLiVtxUAXMZh7XVpaU5z5lFPVMZN4dsqKKuYEqeTBmlfQh
# DATA D56UQb2eruqxFZ+LqqAuqkq3gEu/HPt9R9t5Sd6Lyed3+jTo61lOwvbRSuKK1B7vRpNeh9ulmLMDWH7YeI6plairSwEXPLYvyQLu
# DATA RQd9DoLsc/CsfYjDWzL0YNF/FLV44FQS85MBsxBVSMuA4INoX+mVa9PZH+/q6L8/Yjl7qvcei5uIs5vXW7TfmJ3OZI1TML72NqOX
# DATA os6O78EPzEhNbFwgoQBZ1LfzxAik+gEc7DScBwN9b0exHpO1wWWJuSGuaJUeX8Tz4Vc37n3lWUfE9HpGwlXYDXpD1Z/JgqfVF7EM
# DATA Pg2UUQqqMAz8Byhh6TFR97Bm2Qn6eIE9w1JgBQpF5oOMhUcrsKdmyo6xwedm/RP1M+yvyBD/adn2n35679MPB2uv/NVP/T/K+qB3
# DATA Hx1GOJgAqjo8OPV3YO2yXq3+lVo3zvxbKtZq5b8qJv/9VbFUahTrf+UVzyMDJmhz9Pq/ejn/+/nPf357IoSINnUgYYfHGVSKtZj3
# DATA IucZ+5FUEO/q9Xeo1+BlTmrfUa/DS/j0QIHCekWkUsi23eHDNvr7R2Qf6s9R/AqPXuj0e2HLU5dv0Vd9y8g8GE9ayj+jr+BIFoYD
# DATA /X1Cpssrr7x/e/vWrWu3sYF6bW3tFT5j84raYNmVfdXsbFqnyWQnuNSN1zZ4NyNOhqyBwXeResWLoPpebPdCmsGsXX5Ftlp34wLy
# DATA AW6+OweD9joeynlrNF9vrlk7UNfYKZRH6Pkkt9Y2NrR/qRA8DMfrpY3Lr2T3faajxufI7quH6A3UO+4P+M1JQEEbuZXzPlCRmf/u
# DATA e7lXPM/7ZCynSC6VeLtDru8/fH3Sxd7HUr3SrOYekJV5J9wZ+L1La3feeevX71y/vpaLx50wuvTBGl2n4WEttzYMh/hHfb/36YbK
# DATA HrUxNRiNaOj57W/1RtWYA7Qv8GK5bHxdnCWyh3grdVpLP9/BWDCO1LEKlf86Gvzga1xQB/wSHIzC638mh4cKYXzH7wbvkF20g0MK
# DATA uL2A/LqKlewN3Jm55r3qFeddvsKnbeamQV9Rcd2HIbOu4pt9I92fnNrKBuV9+goq8Suv0BQabsr7TDdaDwfxkEbh+1LoPPnfuIQi
# DATA RhbwCjouwQbgDwW2JmJModbX8msb+KEXDNblQUpIrVTGNTw5CgrYT8DbiNdHax9s5/+Dn//bYn7zfuHipf8pf+/CWvqF+G/kYyr3
# DATA GyTsGop/fe2dwR5O+1g9CT+ztsHPqIF4i1t6KjEbOhFyC1eWdar54/s4qUsxrXq/8rChV/2zPA4crhc8bJOtG8tEUsUA9uaog94A
# DATA /VGBdz+sq3ei6tzH/ur1jY1UnsYU07E/aKMq8uM5D6cHTHaqqxtU7bzSSrmjproKYxqMVOz09S0dzw+K9+QHfSP2fMtNfChx7Z0O
# DATA FcuaejwY7IWjaNBXe8Pt+2g61w136N5PPt2QK9cGe3IkyE5qthL4+S7VgHuf1Kuf0s0mFhu60lhZY708kz3WLxuq8TxNJuE0tBxw
# DATA 4a+YrEunEQ7sHEheMVuMfH8OR285kmtk5+FpCYYvjLIXHhaLmUtba2rPilxL3jc/We8N4skQwxXNLqxoqkThPz7teZ9SJj0F7xhc
# DATA p9fkvNJGNjHzW+v9e1azvfcrehKnVo+Kmc5wu/rQc1bMOMsLNDwGg446gGra66S/jkLGLQWabFD3xuf8UPZYh6Ds4adR8uVafYXm
# DATA e82Kxrwm/AusLcGx4fUVx+uNqP0Ap2vwD1U+enB0wNOnnMyX21wfcZIBBYdOWWB6ZPoXVJDYgUV9r6LlwZbBnJbpfWqR6LLQz+CS
# DATA 0jN/+KBZMhTTxXjXx/4raa6m99uiyA4CviiOLGW6FO4GsF380cEbLCwYjQ5Y2C58uLVGLx747QkOlJuRHJ03TVU7+uYkA6nU7isr
# DATA hntVc8uGd9Fbs2uaeUT7zCN0J1FcACFsXYeTw5V3779/+92b1//G+618u3r72vZd/eXav796PecVIyA9TJicOvq52+HQkldQ97Qv
# DATA kafmFvj9dG2Ua2qgRDssfEQFt66qzAVumslLxnbCOaMVT23LshILVGDrH6Ruw39rHa4l6C7lKXzKi3sXH02uF5Jc38JhL1iXBfxV
# DATA pQFpN3iYmw06n1dVgkPX/dUlPG2+8duMOS0vp2l2vjOKhlvbsLjmhRvrJRqyT7cGEb1nP4+ZbwiQTCyhUMnlUXJr3KOZgtyYGyBi
# DATA SVUET2qbV4eiWw2+w0zRAz5+xhdlYKeDvZeDs2A8GQX3ZQvl1t3RRB281h/F+tyqFHOybsrXN9IFabUYVajaiIKfarievn214UqH
# DATA mekBF7bQ1bpJtsS8kH1iY7uXFPtCWfTZ+mhVPzbKJNP98dhv79pxvTdbavP+WzXPS0szXZ3MSxvYq+f3h51PSrmaWAZsQ8PuHIzX
# DATA 1TdlJ186Rt5ak0yJ1Ez2shxA8hLzaxdbPnqZ7oGibTJ2NhpLimjUl/KhYawdpIvHk2zasp5+49pvbr53/fqRJUdP0ixp3pNJedV0
# DATA cb0JAYcNNQPASLSuqjFPitBz6xl2YXu0w179W/yLKjq5DWf57vvqd5oD5JXRTWnSey+sirHoGTbh5z5Bt8EWUw/yP3g0VpFIddh8
# DATA bmM9mczgvoKKT86TbzzBUNbsQ2A4vWv8D4RYTUC/UCP+xTde93jaGTMaVHW1tsO64L2LQdv3GN3jYffSAF7Ktkfjkz8koyZjiNxh
# DATA 5/41zMLWbkbYx53UyLbxobf4ejcc9YPOGsqIKtr9+zAH7pP9tuWt3b+PErt/f00iLcX3nLoSRzjF3g/Owu23mv+vXK7Xyln/X7FY
# DATA qjj/33n894ufXZzEo4utcHCRTAdveDDejQaVV37+85+zcIfwarH4IgtjWGPAii+WK6JhoKG3egPXbW1GeTzb6vWoW1jiFcQyRb2q
# DATA v2FPk/6868fwDeqvIfTBRpYT8OT+RFlBNF93J+OwZ77xHMJ8i3tLvJD+yHZCZp2S492REPDMBWpkKY8lR3ky6lGMpefU8aZrPPmj
# DATA joUXTzyZvU8kr2XITEZPNSxQJm/bHRxMaprzeK0DLhdTGmypYxllFHwUqPU/ZIjMOmMuLBl0sBdsnWY4ceL0kU5yTnT0bepRVuBB
# DATA aejnZNy2fC48V+E7LL8Lzx+xt3ON90KtbejwZH4wZI+nmrxjr86WTELkHWOcaRnraRAHrSep8lMhjO/HB31sdVm3TEJO5tr0/5w+
# DATA 9qZfTx9N/2365PDzwz9Ov6LPj6ffe4d/Rx++mX7nHf799PHhZ3Tta+/w8+mT6fd0y4/T7+h2/PD59NvDLw7/kX7ip7/D10sepgAw
# DATA yiUGamRT0ZEji4U+7PF1+RIr842novcj22jjVc8t7eroLnJnBGQ1SD53Jv1hrH8LBliivO/H7TAU0wK7xTBMbpX1PEvcKZ0cz2tZ
# DATA mEnNVfsP0PKHZoJaSGaoZBVQ7LdSKZoz9GNi2N6lIltH+Ci6hTNH3EAzRkQ5XRmw4r6PieEWTwpXmlEi0zbm/dztTaAZk/oJccCG
# DATA 4nV9D6V9EGlnoLpjFDAyTMtLSbHa3hm6h/PvZ2QG0FwqHTkzOb/f7Vhz71T2qQn47TfsCfgb79y+dvXuu7f/Jh3lmQlxKh3229LP
# DATA zbWW1bMMdJ/z7Mwzklg0tALX15gzJTPZojsmA25y/KNqz7IKrFxJxoENP5LSToOzqLLANb3+2qXEzXUv9S1/75Nirl761Pp947UP
# DATA CxsX1IV7n5Rz9QpmLParrV7gv02/pdb+36lN/w79wV+ogX9PLf4Hb/qv3PCn/0Y9wI/04490Ixr/oxxdoyuf0bVH3vQJ7viCPj8x
# DATA Dmfu+cSl14NwybrOBBpSzN7F++jzdWOFc8vKSjX5yngZVcAfrGFvZ3zp4kV0NSpfTQBo2TTFDy/Su9buzc/nYq04kw3/6/Qv6Omo
# DATA U3uEvo76P0kepZTyhHtISv8T/Ib+7w+cGd8jv+jr9IfpD9QDPjZeaWDr46xfM7eW8jyXvFe3lLeYb9/A9/JR5YPYPEHpPMGL8f6v
# DATA EM1Hq0Y/6dGl6z/88vB36MVN4anZvOVrZj+J+Jo5orYnbsxqOvzvzDSa0ik/qEqQWpsxZZhpPakgP2heumcHp3PrQKbatld1XlGe
# DATA uCC/sSbhWpUn2yQ/+I8X713YWKfGeDFpe4X7/3Oerv5q4+Jra8otO+PIlgCx4W4A+aUddvtS7n6yVsAUvFBY+1T26iY/8SMflO/p
# DATA mkS5tnFE0rPpvZRq2lJ5+IxGPqk7Hj+Hxnz4T9Pvc0kPoFs7t/xHdPMjBES3Uc8w/Qp9gOofKHCd198d/olq2I+onqi59P1LK1dF
# DATA cnBeS5a0lu6hJet021mIJ8OBqqjLM+GItsAZ8h01LSpyjxP1tbJtKMaHfyKjxo6xchmpJQFoENq9nfw6r5uTZB2vpztW0zfFujy5
# DATA KinodcVZd0RPzHfjG6880S1ojFwxVQngKdPBoi5TtcR1Xqig2/jfra3ZHrqrf1Q3x7OD0n+VZBx+MafUfjj8gvKEqzGGpb9w3fqT
# DATA tNv54xePTpdTv1E1pgx7LBmJoGeq7OGfPLkDF01NUMXN0Z5X2jSfXB9HD4JBunwXLzVTd/FhYfl36hXsILMWvMT8C/TslLLtW+/k
# DATA k8a4QoVQKVpf27516/6td2/f3aoUS8UPB7ev3bi5/f72b67dv7V989r1++/dvr6lgDNsDO/7e8GlChQaBmupVriWPEmRuX/33V9f
# DATA u8nLCpwIsbzfuXn32u2b29fv//X7d+/fuXb19rW7fIuaqRb41vu7wcP1Coz1dPgfDu7efu/O3fu3br/77/9mq/Th4Mb27f/w+vbN
# DATA +9evvbV99W/uX3/n5q/vX7u5/fr1a29ssSosL6lIaWG6mbXC5pUQe9WVrxfTGSVCqw00Hrzh3FNWBX2r12qV2kwR/Yv0nUlnI1Xz
# DATA 8I9Sw6gGU1j4UZ5PF0ryAh172brLjrdVUqEswg9MZYKxWF5iDVKNwoBIUYaR8C1VnB8o3o/R53x/+KUyBtUvj7RXZI7hp+JrLcat
# DATA J2vpl9Kmxiefzi5rm5uXLeZzaXxwL2WfY5F6/gI1Lza3jZDcsiXnJHof0FP3WHaOn1vY5esNqPfVsti6tQo2DIJRTHOcvWA0CmkK
# DATA v7aWODBE75H9FXqNNcIe4LAtRwBYacLsbtV9qNcKsNVXXBdspMBxu5XNNWxPnc25m/KeG1jvMgapBIARmZ5ZS894VLzZD2a+/Gz2
# DATA 3pmR62vuZGlcoppDfc5jqfL/NP1n7llxCX0tuuK/wPNATYEMEASa13cf/mOqq04Nx1wIEge+qvIvns0HleI7wRiL3fGczIilLqma
# DATA qBqTDnB2XPbYaPyB7ZpvEDlYD5lB5QeVIPxD39WKPcxMtCNq8GRf0ACHhyg4jFbIsMdJkczPd7UBY3HcVsl5NRR8S3H5Rxk3VCRm
# DATA kiUjcLYAlCmuI7GBmlOamagN4OAKoY9rbqR+bGYSbyr1lnEDrs/vNz5Ye2P77vbr23euYTRau7dR0M/ayyfrvw4O2EWX82Zchpn3
# DATA mXVQVeL6p7kDLZUVqul3XHLourkzfCwGCGw0XExsaSlQsiyp6/zaS0U8sa1UPPRHM102Ew+eRVodJPoSlD/3KalmiitmhxSXSKYV
# DATA 8GUVhFzBkZnAbg23ZeMH3RfGnCFwxmX2H8jqULJ8rJeFsSYWLH7XTUqe1XyRFnEokTXNa/BI1bp1/+ptdqMQiubmzFIoZ+/CFrMw
# DATA SbzM1wtZqIdynz/qopGjUrjCEdaxl5hty0N6YNrIeC35MfFafjrvZViGhCtuPZttvPtqbaPQkyk25n86PulBS60YSLxla4QVPxb0
# DATA 10FZyaHrnJi1d25tSwCYiL7Vi1p+751be3V9MRNrSpypw/S4zjFl3ZvLOkqzGa9qOETF1dFb5WQEPmBjg7NDVy/bj8wTGNxSmAzI
# DATA 6F7/lQ5IHPrYjYUhTbUf9g/z7XbfpUJiR8JiZ1DSiucPVtxJfi6OMZonfMs+8idzhwf+QUaBy9qO+oq72D/x9M7uITzxTzy2vGrW
# DATA gJBq9jpH5g0SKgdOPkIjgpQV/wT7ddHosKB3s8YBHS27p1XRPnFHm44s3Sc3mGx7jLmgNXAVvOk/y8j7FUf9D/zDNyqtX6tS/YZL
# DATA gucvVzHDMOm6ee3u++/e/nXGXpqXxRqsEan0qu8xb4NcV7dvYJerGI5tMaHv2yNexrBXRnHMw9XMmxKbZXZ9BGenNmaeEAN94UO8
# DATA k/XSKzP7ez75NNV7G6/gHFN7dv8p3y1d32w/oMr+P3s8D5fp6WOz5Gpv0ky5bMwsii2pz3jO+8T79bW/2frN9vX3rmk/CV3I7Knh
# DATA mYAhVduTAvFX4rQ7k3AxMZi7LYhCWJKMuTH/gdfU/sLG1o/ilficJ+rW5Er5ZsWbg4nXN2srTEp4U6pOjXR3qQ1e6flKEtOlGZyZ
# DATA ptLH/0VN+9hbKllrlRdfzSSAnv69mXjrve8UM3udVJ9+SNZPX1m6gzm1z1pNvtOb0K2ZLIxcZOPX3MX9vfYRzfRj0h8jTT9K0ilR
# DATA X86Z1SbNFitl9+Ndv1yr26nphDs4d7il1/IL6paNZD+stQzMK2Fro9b8pT00svbuZPAAjYzN6J7fb3X8S3pFj6kJ1gmBjZzXWsv6
# DATA 0yVGBTlNvM7hpdKlft8NHsons1YjZ0bvIyE0pCZ7bNXkPYrGs/tv1apZT7Ai0uUNxW5lny22HyMlWP7lMXqIFWo8QF8xgg2TlcQ7
# DATA b29Tzt1578adpNeFl3GYWtRe4SyHeNAk5I0kMhzNlRwgXGmSNXFePeGK/pW0UalQ1BDMYC1LsUjuRTsdOLcgu31T1WfjwprnrV2Q
# DATA GF7grfmZWOoy2WPdgPtSNEm+52QUGWBte03OsR1dTLyVWxtSZn4xivbZFJyJu71pYUPcJrxl2ba6Fy6VUDn4+S7vUt3wvPVM6Wxg
# DATA o120v3ihRC8DsBmPaM+1aBaWnO6kfrRsGB4ulNv48PcYQb6gXut7q7tlfOIW5+DFeesQvAo8ryrqH1S1pqsznQUquF7nmJuW/5KN
# DATA pbLQJJZw9C+rhYvcK1bqOBvZwNZp072Ckqei8T7Z112QE9MF7LJQ+3nHQfai3pQdmyvKtkndaKwVU2XZ7SS11rY6JB4cxTXtAOMd
# DATA HnqRtZcKhDcfwKWVbdHvDR4McK7eCLSqJ9Yyx4BUul/dylYxq3qxq10XRroEcEmXgIzlWacJZ5oe6aR9zebjxvzs4ZSp0/R4hOeG
# DATA VlIWJ/8mC5PgJxUByYe1dHHr8WFNY9zzoDyM1kPpMEPuvaGrwCdfOKAPdPGyFtzavY2N+UFayc3UkI1kvjb3SR4KtKMAMfjAPtyh
# DATA sg31rBtSzEa82VYFfU/OaeKt3O3r7RrJMTcVJZUGFa1USZhnFtXKJc9aXeIg7IpJYGXEKk9mcwM+jg8U72NNFuIYIMOTEHnJB4IH
# DATA kdTL/ZyGoLN2L9W76gekHqFysCvodiSkv6wNkU42n7jlKpAfqQcydXe1BvV/qwFVdcl/Rz3Xn8kopqny4X9KejFxVVJnznNlss5o
# DATA OgrTdKYf5z7Q9JBiOqenWMPUKJheAlG9PQ+U6eNedpfut+KoB/KZlUHqSRPuRVx4ZaVBgizyqLfHTJ/4/ijo+eNwL7g/juwTTTAE
# DATA UvfykursoaiUSZ831soSe/6PyiBO9vuJEf8VVlg5Z9mRgdV7noxP/4xxR2Ytjzi/v7KWEXVidaPhzmp2ODw6wjx0fUlh02yd5/if
# DATA oztdHOG0mZ7Oq1dUDRgEk/HIh+SD1ATtkSC71qi+QO8H+Z+szUD3b2eAw7hCPOr5B8Eo9sBc9fzuGIrj0YBRr7wt9LKSVZHj4qKL
# DATA Yl5kVmrmbbBJ+jc9YurnCgd+v2cPpckPcl0OcOQXPrfwd/r53mwlTjRwLnrGr55tCAuLeM5W07n+VfW2dLu0CiKZBlo1i32JXEJH
# DATA hD6zQ/D/Z+/dl9vKrjvh/M2nON1t5wBsALxIrZYhwx2KYndzLJEcknLHoRAUSIAi3CAA4wCSGDam2vaXSabsciqp1FdTqUpm/AZy
# DATA pzvu+NJ+BekVvif59rrsvde+nAOQUjvJTJyZFnHOPvu+117X3+LVx6AN1VEv0FrRp9tupDWOy8qjcOAuU41zlNaTy5nVhGibw+5B
# DATA kcnB7QU6o/ozy69zOdvnyNF+iacTuFrjkK51fshtwDH5S3YU+S2oGT4zRh42UHyWQ2/J0kbi++eocyO1JdLiLxxFhOsJYxcrZhdl
# DATA eCF98gI5krmyuIgiLk8qV3RzLjmSA99vsSscO5m8lTD+LCEoMSRQb1BFZ1czvYzCpeT5JwR3NOx3DL4Sbqcl/06d53MdFVKAqUe1
# DATA w/8DCuWXP9YdqAayJcXJa35Ct8oe0/b88oxiIT15EXbzKDVzDvY0Szl5VNSaUwp4TeANbWOuV4TFBzD8CPpH3Lix+Gw4107+XGhV
# DATA g6ClmifyemCbNk7zueSHOCd4LNkmqyR0lGshp1VfII5Qb2PDbqO/CQJOOGxevrJ0jqNG7pQZL2WNGW3OltuyPwhdPsrNyJdxsVeX
# DATA QEmFWqI3/nxdRQgOB7mA5Ouupek5ajcwU5K6GxBxu1vSMRki5LJvUQHYhGTUx3rtQPUP4pC0Nl3iDXbKzFwlaQHsgVbvzHBSoFiO
# DATA Turv1Yh/iaYPMho9126qScg+fRZqo3TqTnfzmsO9gBCA8ZlkpdXbBULtcyUBeTrst9Gt476Obx5bBmdKH+2wy1Flyp4dvhCDdYcp
# DATA rFGH9uAnXYLEJsDr6bnUCcmZRNIquuYa43XBeaRz8R6zzw9AEbbVzJ0pVtPWIzs57p230Yc6n8ES3ePinoSoK2FLYvH+vcasAwph
# DATA e5BMWTmjr1skuq6XgCboss+UZcdfbjccig4jPZODyw+Qgm3nBirxP1b2esPhkeO650ciWEicEBOqfwP979yGSDdt29da8J3de1ut
# DATA g8ONwy0TD7O9dYAnlokoAvnADcudseNCJXsecZ2zPJRhyU3am1otcUD5tDkU94NjnzY2Kt98KcLCOFzmvJcBrLQbBEaqvixuYOTv
# DATA jUDi0Q2OVYKJ9Owx3CsN32KC76QdJJw6UutHB9/AGfjjZHX47rvvWonYzLIM5d7vEt4DY/x2n/SG0yzZfrDxwVYlmWaUwgD8AZ92
# DATA RWLnwYR1f+qwjAC3UtRImHTJD6fDSTv5gdoScLHjQj7FCO5xV03ttItx4j3EF4I8Wx2WYjEsYzqygeEce0gkoOKdPHQnbLpnVMtn
# DATA bkmpHXQnEyXpxSVAfZHiV2oxuWd5C4TlKoHMZnxo++1BiyAgQa/cYm6+REOr0CxDdP7JWQ8TtgtXTkYHYYLQacCW1ooD/iFUlC2q
# DATA El9ItQJJDzYrhPagMnGq6hjCLhCk5mkPENVwTZ+2xx2rTwDbb75KmNTqGGzCwykqFzAef4cuGFLh8xuyjlKk2HNt5E2QS/tCCZ8/
# DATA Ic8YT0uEfiJWPf7zHJ9Cz+LLk60xqxywtximm6LDlJYZiHD2CQBYffLoGxEQN+k97ziXkGoR+vXli1+RFRuUUIqjRkPSTyJTwQIL
# DATA CN4YQRIb2hM4FsMBZmY3S8UPc0fP793xx7zU3y69V39Uoz/Ll2sVCvajrxcZtHb/JGekH6H5Ij5UMjOF49N7q2UH6m63YKzBF+xv
# DATA 6F4R4aT4311zdvxqyosaFMnMI2fKdfqNcN+MMoJOa2TAZ4+ZRNFcxe2WwKNByfGjEsJ3OW7pNXUlQRzU0WozWU5ulo/qNz02DSoO
# DATA ZgXOBL0pHN8v2CsCxOznuIV5uTneyIwM9EafkzaJBw6+H0UWyDuktwdK8S+GYqgt9Zd0mBwv5M9Zsf8lxZ+TxlfvLIvanLnHR77h
# DATA wuoKbHkfuNsw8o3Oh+MX5ecb8otK0IK1Jvn7VBQSPiuYJUD2kCmZUyejCKl3rmvn4MJvhZ0lC06ADQp2be4AlGf9IYyrptMNr300
# DATA /KmpcQoZydX/1D+4/szZSbnCIGVfg6Xwq/JxLGlBxWIs3hZ/a9yOYBr0MzMDolA4JOGHHOzSWEtX8EtxvBsoVvu/ow7xRxSb6dGn
# DATA wIDzhYkn9CkXZUGA/mIqDef4wZMDYq8AVNg9PM5Lsn0zJ0ZOa4onooKGQUPvbqtJ7Q30bPmnRb4zlarnppc5sxzM5z+p+aEpMN6v
# DATA v8HAwl8GkRxfIUn6Cf73xy8+Yx7nqnM5GqFXxRGlJWHf9EbD9hwd9wKbN+8IJ5Id9h9VaLcf/zYbW+y43N3G3wRz87/VkH6JwZXP
# DATA X/785f9g4q3nR4c0RLVuv6e4FlUBcw3gOv1j3LE/UTV9EbJRvzYxL4zK0siJGmMX+709DhgUMLDMKNxY1/pnqgrVzjdXv3VLz8rJ
# DATA Ge0bbIf868ju9ggx0B6h1woCnzbDWfk7Z8Q5myKqzf4Sbz50RsQHYgx5ent2sShQzhvdd64Qxd6RTlxd1HWjGYUlIGUkau7XJeVj
# DATA l7Q5Ost/FFG6Pout5+V3vM8+DfSYAenSqkyj29IY/jx2eu4MHztWCaSjrLsFTr57iPtYLhvrP/JnwIqB03QNkIo+7l5kpaNlroeb
# DATA aMpPat1nE1AFL2Zf1r58Uv3uWS+MIA211wN3s4WN6wtcHKHqOB5oZ3qq9d6XZBpBN1Sy/oFHGCnz6xFft6DzxkNZk3xIyo4T4dif
# DATA 05qiA6mdG51UicJufCEbdij9VY7dLcbVyPWvteeCStOnGk+U0KLdWdX+ysSnY3FSWhZ44NOIrdv9QjDNV7H84IIaWNxcGy9itUQX
# DATA ucAFxnQWV0lafaWDi/WMocE6K2m1OdJTK77z3dNHjZa/3pNgT4DioSCoxfqA582X43H2dZ0LRT/YFRNQ4mqdbncEf7CiSngKWoYK
# DATA bva0oqk8R4uDdviNRvAwzxUnxz/gb7ST/O/QrAaXOyJTJBArpebsn8EZB8NFbYj4y5/oq11iJAhmMOIEE+fa9OFv6Fk5sge8iWO3
# DATA oBXxo8XFg6AYNwBFsiq/NWaJvNveYbfz9kr39LSLCkLV+ZLWHM4jV4uMyFRcNKZ8fQ/8+Fc9HuTzjA9r7upb2eJ53nARXhrW1nSP
# DATA BkjPnTjrMASJCgUxSE69MNZSJHrfJehc3EMEcKaTilDvekNrtanxWoBRs0uhtKncwFVIGpjGg00bDRRRcon3FcQOVJH8liJSYLPZ
# DATA aCeOVOOQmxiohwD8Dc+dJlju/or6Uo27av/3gAGFzeutKOe50BGlvBh/gotxtNqsjQ1aET6prhn8orouI5dDtIVoSOrX5PGYIL/1
# DATA 3z9k4PJODx+rNQXYfkDvVjzKM3SUa3c6+EQxZN3T3sdp1Dr54n/lnlw47H+tdj8wpn+FsVpqfX5NUaBaQ5XQCfoSDgoeEQxAg3II
# DATA pvUpelD+XMpMPxELw+twxBMIkVz4l1+gNhqOSunxtNeHlBdoRBA2n8OzXsYkBHBCwIQwRLg6cHFCGH/j4gGvx6Nhn0zccGNqXkHU
# DATA N4bMpd0B7A+CEGYbFGQAGKgeAW5mH4J3VIUDTFFg4scAWFhdiLVwhBKMH8Z5ubwcC3j0uS+bKgLuUCEu1Vl4M6CEKej30298Q8cm
# DATA my0qb5kY1ZX3h9F2QKeEWUp2MawYJflmrM+ctEOVJZgrWQ87mdJnbtwsKsbpphDqcGILdO9i3y25AfWCTw47HYbKa8qVe/VGCUP+
# DATA RBWsZXhHOIX/nd0QZu1y59yYHMdIHXXJ7Z2Dw42dza3W4ff3tmBZgZqpE4KEjBB1hwSLf3LW7Uz73XE687WG9L/S8XDYn7P1mAoT
# DATA J+zMp6bPjUaSV4WhQeWcDoiZV/PBulFoSf0Sh5BOIbWlN37ZuWx5nkCP8BqvXcPk2Nja52TA+xXi1H2h2NIvOTzY8Z4qvnwJxRaP
# DATA xdtJeie0jYRaVyd4lMxkxpn2s3wzqvFfN9Zg10UrpAd1kaMGecoIdfH2cN9c2c4mtvozwV/CF462DB4srCqbz3h+FWM8v4hj0qCZ
# DATA +dccoz+HuS4g3fPI/xxCTqLYSb9NspjTYiFpUDNqvpMEHTO68ovYGXoDgXDibEvxHH3mSCwazFBEUYS2eWva/WdYmwhwxR29wX/L
# DATA UjEaB3+nuR6w/BEw3xV3vLfrL91prCdIb2KX/8wNpHCFY5RyJZapiZ8CQtfQDhyhea9B2vBKInWjjSMU5kn1V26al1aF2JAFRI6o
# DATA CN8tfJAR3g4g0QPDo/zyEIo9VKWYN8gtuEeEnpBOrL4zpy7/yOd8sWe4e0/utL2fa37HqN/bs6r5++asetP8uKFe3P5W+7jpPNF/
# DATA r5GfnGksTmYI1aMQ5jMMjHieXO1++ALJ/3NyjPgrwEPRrgAWPv1nQYTEUc4CACNshyVDJy6Np0Q9WYPoHaP+r/t+o8hLkOcma5x4
# DATA D7o5WUxAJzhBmb/Vx6RZQ8WUVWVRLidw8KprPYuO9lVPaFTQLT61UIr/rLh39YH1vIoehZn2xZqrxUdNuIbSNZAo+DMI6si1hAgg
# DATA XhQ0Y7740m2T0B9vzw7pj1uzP2MH/Uc6thm7BUKuBwBu0uaE+uxIOKsOy/IDpv2or3iwV85T+JbiX4PmbUxrAKtsO+5BIrlXugN2
# DATA 9BXcKEafgY5gMUNOXd0HSnb+JV4P+vrAc8X6V4tJXa3KAJ8QSih3hW33wVdGZkHKIgppd+KDAMLM4nw84YQgMYdBcCS0WxJ+ed5O
# DATA CEyCEZzmXeZDri3oiZcbKfN7cN4BK1vulRvXYocmR+jkvHCgkihJQ2nmfRL4SrvGBjMjJwFAJSuxvVZcZXbuywgA6yIT9BUF0KBT
# DATA FzNLv5aa7QKztXRSP1qmjlmqq3iGZTtYprpoVwrDL4XfehB9ZPKk5hsSbPxEiAEEJ4KrmBOA42IDaX8GzzJCng7sIslmfrL9w6Tq
# DATA O/ifOW/AZ3QPFywA+4t9BsUtkXCCEBGi3gR0n/cmeUeSzR8tF2So+BRf90gsEmuBdXhRFtrgHAlcCzZQfeG42fjWIUt1EK0ZBnlQ
# DATA p4SlHx9YSz/9XJw0zTPvf2aoF0HN5e4OB1XHuqXjRLkO6fNt6Ln+4zLhTug6bkvYzeWRKBNtrmNeabM5/A+yfbxLJaY3uoVT5OlQ
# DATA 617P2wPFgXcSUHuIDG/stE+NgOsipB2Hf7UbuXQNj3HuC3oMXgmZXO8a/qUYCEizfhUnNsFo06OrYJj/AU8ua9w1YBkz3a4t1l5Q
# DATA enfm2FoFESXX88/Qy5Yw1MjTuIBkFs8anSojn0AFoTOeYExi3HuQLVu63PluZt6V7DjbNh3GV9dyBe90AEpGB3vGhQAhztfgzd8n
# DATA sU7EbMy0bI6OCD5rfk0GjghgvqI7eJZmMcqnHQA0JnwXqu+2IJCrReRJB3KVONgFiNWVQu9dpDH6x4EZG1j4cGjDHAjdnoufwofB
# DATA j9ojnpt6QwH4XI2NMc2DSAqPPJWZx8HqUpbvblrwJM2rLx60GUTTmRA6nJVIzKYPQOUjBNmhz0MJEqADX2eHgyDTBUhngEikJCqX
# DATA M3HpaDDoyHALj6deVul63MxjrsKNuFjo6P+tYaP5e4bCRlm53cb90O+CpXj4dAB5FgftUXY2nITGb4n5nD4Z9qfn+rqx7lSTixGo
# DATA mNLj3qCD5jLqdF2mFwRDP61TPXGHxkzbtULXid7aT4EjvJYuLnE9besu+TEOuFgO92Td26JSI0d/zFyyEQ2D98REP0idhrcIobEn
# DATA uSyotEETfVVNud+RGK4g/SqLK0tjktIvTyjUQDOSTTe6IP8mNHFyENLZ76Ie01yn/ITTUi9wZ8ausJXXfoHBSbPfmhMLB1lWqbto
# DATA SyoJ4MxBJboaCEsu8ldbO7fF93bUt5ztlORc/jX4jqeemH0lH3nqXBBxEZWGTVRXv1/ylDCBLDoX/AyUKIGn4cufg7+RTvllkUDo
# DATA jYiVs9cyb7Y8n3dP/K9fCTlCCjwIwfl1atMxVh6c6Ql6SfszEfQ4EfVppu6Z44uk2x73e5gbg7P+ZhX8u9vuiOqGGJM/Umxne8Jx
# DATA 9r0x5ilWX51DhI4imZ3hUxcVpBY6w7va/ZV/S93+yhzNvunzv0vF/gJ7zgyAVft2ETzN/kpMr++CR8gAElb0u6ehpt043brqEXAU
# DATA 1wk9pkyrBw72VhEnDxJbjoYDJTD3fRy+2NZw9Lr6Q7c/tr78HtHyh/UnRIARawncM7zAN1ItCEQ67T1giDJ4DbDbpE1fKFxfv3IQ
# DATA tf+Gnl1tV5jxXTsehwl6RBxxGYYIfK/QMBe44esL0TVdBE/hDgnjvWRR+dgWthXEav1Duvfz9Q6XoCaA+WGerhaGhuIqi6Kxd7R1
# DATA vhKRS/lBLgXu+q6f1hfuAHzeDw9S6VrACzlS3pP8L7nNxWJ/QyCCebOS+hl0YsFuRsW0jIdDB7tdC4ixAITRM81pbWgB1bnjZelU
# DATA T/9VOyJ9RWySh0iAjyzkiIOe6JteBp3us4ph1roDJY2O2wbqZ278UQxW9DvJ7WUAE13OS1McxN/5CYl/SWNVD9w8IKjLAH+pSLiR
# DATA BiGsu71UbxjXr56E2IMM9Q2TACURv66erA5vra7OcgfuhT+oPmmpEOGQvCmR6EiVhMTSRmDJLEcMMlFwworG+c3H7JOuA7jk+uKF
# DATA mqT0qbfpfBn/lGV4rnBWJJNKZrGlrw4b2UtXh0ipgEBUiiNtOJiDOWSpLkEpURP2rGrZbS5E6ujU8MPYcZZxhfazHtOIQmiFcUTi
# DATA v2Zh5r4ctbRlt7dM6FPGedwSoDUJ4CRfaMGRYJ3aYzAkYPIJgsXCSkVdMPu1ZAuRmOE+V59liJ6FKrV+h7GBRhD5gI3wpY+msUkt
# DATA jlcVskTzzITyLMRZRYYiei1CkS8Q+eykhk4rByVCzLTFDZ2G3Xltip64+VT4ajKO8hb+o3abk3/KQRCWJyxerXvuBCFo9xh3Gb3d
# DATA vGgswVlIf29UOpA/uDsszvvay1BAlflezUESmiYGB9MMKWxmCQtmQhfm5r29HwZJMMuH+ELWtV41VSPOvqa3p+YNfX36nM8yB8rD
# DATA 0CRqlNkcLhNc8f8Qplr6HaV4c8x57HPD84+mTQebyPMn4ZR5c1janxvFiEiazD/4BhiOPyb0H1ef54cp5M9ljasAJZwNhYsq7bik
# DATA o7EzHeAeQGbHuFFUpA+jXPUUn/ZlLlpyLsdUrdprLgdKAh40TRYSfkDSdmnBeaHLoEV3ph8jWPEbhqNV0pOxkozEFPopm5D6OlpF
# DATA eiwQfcgDoOzr4oqzPjlTjBgnDmrHF4nQ0s2f4oi2gwIU4tgmiyXF4fHmxB3oo2heS5iRuNpH62rCwfrZKG1ddwL+XGLEgHjyKZ7n
# DATA nwoPBEbS8xSWqD50ekwttDBjXyTrcrThL0gbDElCfqqzLst6HOH9EmOuztvsXy3ZIEG1Az6QdyYZeoiG1jVZ8fytPXsPg4c4dsl6
# DATA YmLRbYolsu/Q30eQP7fpVeyIyHV1ZKiOJnL9k3FbuFwfNWcFaYTq7h0Pwndvbzgm/4WR+sNGsqEdcW93H7F21tX/0rLjLIsV8E2o
# DATA ujDI1Dk7N0Ca8SuRIzDMy6wB8onjJUWhGiaVXU6kh2Q3X+n+ZHSrK92CwoeGw0xcTYeXTjwGW3VFSKpcFComRqkndBA7bEIsYzGD
# DATA MYg9FoshBg+TCJdOFpvJ8vyJq7vErxyPlsRYM9Yg8Q6Z5Ue4Fsa1lmLklOIkg+0GjwN2uVQQn1q+bgSjR4sj0eBh72JfFIWH+wt7
# DATA 7ZD/aEDp1xTwb0L3TTA//lFVhPbZhfezSt6RYxnpL3ACQswACxVA6AGzV8dv+CqeSzRMXkQq01+Dos5Y8v72xd9XEg5WjWomnTi5
# DATA ryEGG/Yo5jcE/Z2BG0kws288kNmKXOo6tPjNsfNVwtoXDHw2yuDLFI/S0/aTbtUpbx+LL4Wsqr439A5Dpl0qWBwb7ZZdytkRmlun
# DATA GGbbYv0aZ24uAMQVTnlBqsDiDW0jCgpYUkffMB5OFL9DuSEhAbKugtIRi0TyR5KRQzmCX/AHs/y6jwTPgaQQZG7gSfjTfL6kHFPT
# DATA hPg/kTMRBROY6+l5FMsVDRbKtxFP4G0xppySzWiDMsItUjtorcxCoERG1nAnJXe8080rDFBb0mDh9IDIQYLXuWL9JUx/9CWsV5wZ
# DATA HlVxTD+FhlT+8opzf7m8rB5VkuVlU8MsTEFVcY6jE3Govi6pvo76CPV+pm4K4izgrxbsN5cjzSwzqsuClXYIJ6ukn2g7ZJY9pQRN
# DATA FK2c1SjW86z7rHRjvWyTXiN7FYtv9r5QW3xv9+Dwg/2tg9bexsHBR7v791DBTw1VvKmzhR8ebO2Dwl9eiublvbvuK78WLxj7VFyn
# DATA 9ZUV/aN+qbsx+xNLpDvH9Xdu3lhfya/9/f3dncPW1s691r3dBxvb4O6cnk0mo0zVDVvNrki6t7Gzdd8WM2/8Kg8e3m3tPbx7f3vT
# DATA FnYYqem4n5WcVbUrD0fr6HYdhKkPP9q+p3q2cff+lurd1vsbD+/D0iguY9oNB/Jg63B/e9POdbtz3kN3D/0CViy6spCv26/to627
# DATA H+7ufpc3ROvDrY17WG10X7BCXh1UiCfmzWw4ZfeI0oYLmeRRezLpjkH6Gad/DhM/7tYQzqcLJx+gx8dpo7b8jdTl2zTOPn9ewV6A
# DATA BbP2wCOj3D34ZHpsyzMQequeBARGV3babz/OGlhlQSIQrP/tBgJSqBpCcvU2vpLEAT7ReSHBYx5oAU1wJRlMz4+72keOfmihmF+5
# DATA 0RAIJKvhMnxsWfj9Zvpo/GgAOBlvXsnzDgEejF7jDjjaMKwu6z7tDctovBLCCoCt4A8yJWrLr+Pq1b4ARwY1OLA21OBvMF5l3Vs3
# DATA a8e3brIxTU+Ljp+jvCyOQ3QERZvrxpv247IbbsTvjj5mhoF9pdqb3fFkr3sOJ+cHTyd702NFt7/L0F6qJ+I1/FRv4JePPIIKfpGB
# DATA seTYFkr2RSU5vBgFWRppVeTEyuSpCPaiseqfUzJFzgetI3GfQ+gNQGz8CO3yP8Z0fl+yehZD3r6MJ4jgnXn6pmFsGpe032aPBrZD
# DATA jfSSETDUnn6T9/DTdm9CoR9IQEucvgR82obTSWN91YYoC6AHdBpW5OABhnFgBASsXqfdV5xkGo3QCG8+1h9BXffwiXaWd0+OKAZN
# DATA kq6J3W7UuvZO4YruFiAfo4+yKpmtgFHt5Ey1VBup9TdKLltLNMfYavJtp0yYAXTtxtrqu+vRA/pLdCoAL4LnIPu5iKHRlX6efHh4
# DATA uHdQtfFIqXEy4txhsjfWCMy6rG77lEmmzmZShf/d3fpgeyfZ3No/3H5/e3PjcAuf1pbfw3/VXRq8S0WSIlXdgUO8oJlgwL8IhxMM
# DATA hkVWoS3X+txnIy0feOmWsqxf29t60IJhtyZDda3u498l6IS6esvlms66ZCcKLw74krIltThcoMUvSydttKKBhCCms+zUUOM4JrxM
# DATA kk+ovu9t7W+///3Wn76z+i11Pasp27jf2vxQcQzOl+oe751Pz0VOE/j28P7B9+gB/PlkrbXOztztjtpzsInh4NXOh2qKwT2tBHco
# DATA n0UyOZ2BKSUo9G1TRT0/kS3kB0oy0K5N9KSo3g7AxK4khFK6tv5ubVX931pqbjJLCNR4Suvgz/+sVFurmOaqflcg40g7U7T0aSS/
# DATA EnRAT9DTcXvUot6UVGlSy3XHLU0nGoa5gvoU4ZqO8xh9tSX9HUPFgViNut0xbpZjJaWP1VoOx+d8EZldAwRMb796rlhl0cIoWP1T
# DATA cGFzwga/4kTjf6VxHiUCgFrwKh14xAH7UVrOkVqo61kXyGm/dJp+sHWoSBico5W12howBB+qqaknl3qGZvBs0yylkqz74C4AnIP6
# DATA /6lOU1Yu583e+uoqkLEe6n6oeUU+n5TeWVvXerry0RrkYU1urq7mz5Ag93OyG1eSbXAYimU6BpHAbmLYXlm/2x2Vaiz90DK4ZCWa
# DATA 7B3Aen6TCBiB31F2gZc/u6OVauQB9zOdsAbXtBIly5iB6l8InRNspcj8VUnVqK35+IsBxUtWBsl64Fugri1psp8rCCIPo96mKd69
# DATA ug6dCY+E99OUkNwgripZxdO7qoQqvDb1F+UZkJ47jwai6FG93swt57C7p2ma0slMLi+XRBXTQe9ZfeVJe7yizt2KUWKvjKeDFZyI
# DATA GhxuqDJBlWsLZO3hybB/Z+mSBjfTQro69TgVdkPfIStJ1m/JKz7S2qTv3erRL1vA2Od8PRr3nqjX7re6r1mCZLq2zv/eoCLAKq0n
# DATA w8GdJTEElK6yZHh6eodtIOqaXJlm4xVFlMZdmpSVs8l5n963p5Mhes3ZT7pwHFoYsX9z9Wayov5TEx90Okp4a3fUUvxpdZNu5ipw
# DATA otVdEkjVnswGvVPFVfefti+y4Kt9wGgdd8fVvaGa/gvgrHsnE/bkqz496w6qJ+NhlvETp5r+kBQhyZ//t2TlGUwAeMus6E2BV1+/
# DATA B4D66opoHQ87F8Qdrd4x7x+PRyctYlfoUklurK5m3nsge0XvgTrgX0rUL9qC2EXcglQBJ103w1CjePSoVnrvjafdfr+KaURXymo0
# DATA 6mYbXIAr8p3gExgs3KrklZB8Yzru4X9WkoZaKCyv/p86L0wOTsfd7KwUc+epGOuvtmeaWy81l28jVcNfTSt0fBrGvoHMOtEMLO1r
# DATA mnKsod5jpEeqhTVsAbVag+6khQoIilnjluxTuDT5IRIN9NRUxKF/CnEy/VS+o+pv3ryhn/YGx8OpWlp6cRveWMnCrVMr/kpO3VLA
# DATA iMvCAIbwGZv3mdH+lPzQX/w2cRlQFIvT8tI8Fbjbr4Yr5pjkAWJFwuTLCDCHVxAFof3MxDtEOGMbuQay4281EsNr6a7tmtEfHuEN
# DATA EAtiY32Fv6SRxQwjhiDajZqgcLcbeViUyEH9NNnY26446wNgP+xO8jz503H7worSv+MgNw1OCbe58Anpnfp7mYJZzIQVZavEWCQI
# DATA CdxR8vLGvQdKXHKRvT9n/uEnACwEMv2PZcjT57TSNtAgBptlXMSCGNAAYCTP6yxfr9QfPn5M/miXaUdda+gWkoKGpsr5SNLhSHuA
# DATA XKaKUFeBRkOhG6uoHYFHWFQ9eidlAgihsSjBgIENs73C6+lAEcGsmk2GgHsJH3Pz6iX/FSgo2QQOjTuGb+NlzHbZjnSomQXVTPu9
# DATA 896E6hkMub+XaTY8hZ6trd68/c67t1SH1LXbsQ9ms9liflLt0UijQNPQmUpr9E+Nfk6urHZJdc6ZcrMS45BhubLG0amVs+paS1NH
# DATA Sh//jKPbG0dsg66SzET3Htx01jRNvq1ZfUWt8ooaxQo/yKm50wUDY9YaDhrSdNo5xtlUbGwHbUew2GxKAUaiPzm7SGeOVZVM4vM/
# DATA mkW7Qa8xyFz1Y6J2GPggpZsP7lUPPty6j0DDJwAjXD3NDpD1Ulc/XMp9uDRh6tZWqA70PEe0ejUn0IO1VbRaMDuBmzojg7DifNDX
# DATA 6RZdLONJa6RE/WGHzkImzcMhTQmMtqCCHKl3BM55lBoCkjZjWLWRrWXsI/W127Wb6bU3GYmQZ+fIfDVSJcCdH6dOVmE1x4d/BsN8
# DATA eLgJ62j3l+6hZamED0RBc4ss4Ohxq5cB73eRVB8m3/jGpWNmmiXVjvPw3t1ZsJg35q3l+upMhm2oPZkz13Ri+ODUv1Vt90e9AZDH
# DATA Rc9a3mRAO+q+Ed+jaADdrFYzdVQQNBt/kXUf0LpIK01PFf09756rda6OkEWnd111jPBQYRngeqlf8NvrGv+DjK9fXO1wJPLvvvsu
# DATA vQKKBH+t5g4of2mtU0xV8f1YX7ZAfyDRwyuurPCdE2RLlVJT6pAlJGQCYTYkWPivE6QUss71/IwoxPLlWwXzv0RJXuu3/ReBh0bk
# DATA 04ZmA8CbJHgNzjC3VyuJ4rJnub5IzIAVgx9LE0aM7yJQcK06iaQM/ZLY3DTqwpIdSd+cwNWtGT+/4RqFu5c4jQbhaalvjzTvgXsv
# DATA 1+muHvO4i1xbBdRZfq8pNXBzpxT94ryPnbsYmxCsMHAMa9FjG7/Ur3c5F59+lDvg3Id2bebTTrsQv/QmX9l2PND3FSQAg3af7+43
# DATA y7XJGeTBbXyHfbcgVnBSGteGH7+3Wl8rl2snGA5VKnsl1Ks8+uVQmXfmUZm19QgzsO4yA3xDAO2BIw5RTx5wg0G3tgTSUmvDkLmR
# DATA kSDgUyQYyvj1nLNCb3NOBb2tr9vbzL30P9i9t3X34QcwpvNpf9ID9c3kZNRYBSaAN116e7V+GxQCILnXSXrXf65MO6MiLiDOtAbH
# DATA YxN6SWENYFyvr6g9soJdXzGv6uOhycVUhfmsr8B/7TNSsdZXXPROr3EdfXYpKsIwNa8aP3TN+ItfUiC+ddVPZLib/hOWmQGo6rrp
# DATA mVCBT8ZtFLXN6kUWnJS5R5ZZZJ9ycYAjYBROITyNC4swipUFb0RW4cCFdX2Wk1nfhsP2Gq2OFcR5jJWCzaH4Br0tolo9zE3ofaNk
# DATA zcz5aPh4JZuOYHXQ/TPW5ZBog9V4BeZBM16xbjDFy/n6ZDjuGr/i2Oewjm6pZpyrQUUSrGFsHzXdeJ6I5gmvAbIpiPflUGjR+7ap
# DATA fU2DkaHZPH9JJv0Mzmre3S5MJHlEC9/W12rrty3dim3OpatRGTJAwPmWZIY08PC01llhezAWQoJTTNmuOTVXrXX+CbhihU+fPtUV
# DATA xkwR0EePfAqSJRfwuvRx9joiqKyabH4MVRBEFW6PCCQOcGlemBUmsPeq9sOoMComEkNFk8hcEnu31OVx9StGFYMpaKyDOcoqIqYp
# DATA e8Y/u6C5eHYRdpdis+qJ1uemCK0oeoo4HgZSd0EVGXvZSL704Ri4az/8pNBr8kqClwwovwwzzdQTMk+4b2jsAftcdIhysq7QPoSM
# DATA KzX4z81SuTwrhz30sWg0ZS2Uc2JIU854pbtVw9Xyk0ZeO0Y1SCfs6OzLVGSbdPZeKUeTX445QcsgPdgUin44wSKE/1AhXPEKWM6G
# DATA T31TEttrhv0OUPenXtAAQzRW3FRkUF1Z+qMCe61qcEK0ULUAHHsGviUlClqFU/FfPjpsOQ7LKQIl39umv9BLV/rZwt/afRay4dkm
# DATA L4OsZ4SJqn8FvsiVmDMxPLRBDeqXE4PgRsqEsUVq2BQl8UYD5o9cI7sX+Um+/6dJrvDli99wFBFmLMJgWshXFAkaevk3BFQANVNk
# DATA o9oahPVD/rYn6hAMIZNn6ah0To6AYH6GEAj+eUDoqfbBPSU09gZ4GsTT/Y9SDsxGWF2OEXyAzXF2i7LeMS3qBW6clukR/WG3Dv8W
# DATA uwb8jJRMD1FoGgIWTjBaXYZZjfca9wcQtDcfHhy29nd3cUVQhW5uXtVbAce7QnG3qnIYUoraLovMoV9VEtr6AuAL+8PGTTsytlDR
# DATA W4jzNOO0y2ufgeZi+KRb4g+o+rdsytXJ2bjbtTCGVcCDRSxdvIC5xfP2RXLcBdeAbqeWbCGcio5j4gqxJMCkjdrHvX5vckFCYkW7
# DATA KKO9kRg1RSpQDwZ0FkEdJkOmFL1Mox9aqARao1eNCo3iJ+ip1o1xqlqf0BQGi8OehKFjik+4Gu3Ul4NzaUqK1dQVQLQNWBtx79mn
# DATA N5oa7xjuq0hclR+mJ5s6Wm/q/RPHaF6wPgI51jZIqnrNYwPHXUj4i8isVNyegJp+15oM6UDpCHeJuwCXuv9hL2st9G2YgcYED3Cv
# DATA YG3B2KwfYKxThhF56/jyWvjYbm3gWsp1OY/XmtBMfAWO9EI1w7UITzH+MvtW7CIi9AEdiJF3Sh9HxmjMTRch7JEEBkpcp+P7gPV4
# DATA wBncVZsVcJbg92Z7tNHp8F/3xsMRFhr3nii2Gky0Tecm9u59G0GIjhxhXd5hUnRGXjQ6jLCeXKKDbntUVryQEupx88HUjcbd094z
# DATA VfOGuvA57LuNGB0lL4gfnCUDQmOiVdVd48YTwiJAb+jC4X7BP/aywV/iqonEfOoRM53UFTVM9cknirOwCpPZ4pRANoFTmd9G9cpt
# DATA mBQHc+dO7VBByfMLRp0/Qv7EVmCz54JfZfyUgSSJ9aY5YnIdRWlQ9rLEnEZUORA1JlQ+0YKh0gYx8MTvypJJRwjZK2wajRiShZ9F
# DATA Y3GHEI3drd+70N22Gr+eIuBuFxcoGqswF8bb909irWTpilAa5cXxoyQaRj5O6NzxUsoXAZFhUGA+10lBv3r5l8gz/85kesOHP8I8
# DATA Y3/jkFb09mwkUs1QSuN3DmxvKUjWzrrPnFQol4W4LnO0I9ARfg5/lmVyAI3scmpyPlQMkc5J+hDE/CFeGbFydNe5PJO37JKntwkw
# DATA MKwc3kSEBJGPQkh2OaUxBzVot1ZS1w9N9zKEaVDLBEEMukAFxJ0G3zvYSh35CrrGncYgzkSLLxVk3/IFsH9wT02wa8RucxJXYx6n
# DATA mF+ZevVjV0zjFBbFIA+G0yNvZFztAP4xyGX9qtk16IeTXYP+ECoTN1GFrdhUpDeorUNUPXOzbqq6FA0+6YNz8I5OaHHYHm8PTocA
# DATA w4roj/xbU15FsFuo/Ogqrqs7aYN9qAQepxWdKrksUy5PEFpbdaQ9Ud3gEqp3LXPGTS0EKqpmZRX2JlRZA3ccR92lHwKoOuC8Lq/j
# DATA xsdmIP9Zsqyfxy5QGCOLdNyTRDeOURfdTobSYNY+7SboLSeU9PxFLbfnmGBYdWTJThRYXFsjdW7yJggHFM6nLuhnYkULjSJ9tmJT
# DATA 0mv08WAKOYW+noZ15XmNZ4rhh2wgOW1zyCcWYhw5AiKdQDsj1JWgSG+X67z3eMyUjrkGVBWfTGT+LW4J7DHd9nnFHAVYnRYuZ2Pd
# DATA bJAbnKCYX6ytqv/ZvIB3YWISCgAgVUN/+Bhx3XGzcNIRQMFEpNOBkt1h46DvOgBdPoFOq250TV5AN9mRpEL6kJzgZdBIVpdM1Jc+
# DATA g0N1ykvw1/D4Bw09PDL0jD+hBEU9dUYb/iHGIDCeFk9a76IfDIgc/muicdCXtxvJmhdkNEY9EgnAWAWBpZKIF2KkQC3fkRMNxzX8
# DATA WjFl7WPFtk0nXeLM0lotJazY8STLuy4eDvCgDsJTjWCyBpsDu5GWo3ca9aKXEU+oXdPNY0YyNBOmHvHmLhf0ymziQYzgQD1hb7h+
# DATA io1NVkWTTO/sLlYCCu6ZvB4IMhdQNXOQEvRhdrvRsdc2EDNiJ34w7A0wD8Ay6Qpi0yg+9JUVvNMX6KueIYJCUBRAbbWO5HFypowX
# DATA L4oYLKYwHn+n18yE0VpWVEfru5SIexkJQ5STcP4x9AlP6Orw3dVVCBYBJJ2Mw0EQ0Ls1/JhCKhcTYolOqDMpBpW3fDpX2Sv0A67b
# DATA s+mk1691etnHrWmmxDa9mrVTUJd+29mhbye3buZdv3amt9XpOD3tnUDME+D4foxEVrFZ50iW/AMt6X5UFadvZb4O8LxSr8LR0Dcc
# DATA CXiFDakjyNWX5+r8gy+mW/lbAKHcn2ZYGEKE4QAxSrbaw1MybemzL5Cy9QVCZqtY2DF0ueKsLN4F6bPjFIn7cDoZTSf1ws14cqY2
# DATA QAnXX5wJgw6/trZGmkMEnw83I+mpSXbJ23o2yNqUjp+34z6ENwrlaLtTgiBp81klufXOOzdu5UfdAr3BWuaFHEdW8qmascl4OoDV
# DATA 6OREEtOM1hgIHxqKl7PTUqXcVDllub5TtT/OIpDhw6x2ml0MTkq6nJrEwbDkWhXxBjPWxNFFjOsR6hK9bRzaq/4m9wRSFKBb2CgV
# DATA ahZ0d0DIbTooIB/W0FWR3RjYf5CM1dqZcA/3I1QOlqIOBL3Lt9t7W/i8Ox77z5n76Z1jWA5YYNqgRa0dwpPSGnji6uIf9/p9UbzW
# DATA aXcptgbIlniOoq8GIIGoUFXE6MOdyP4gzL+An9S9oOFVAhHSh1GHcwlbcDr2qIzuEr9c8sDYzFBLMiePbLuGIeridafXfjwYqqN+
# DATA gomFbWHVFB0uzAntJ2qoUFcyxT5SAuw02iJU4rdo/Fh0OYBCKQngE+toR7QSfO02h9N+h2GjFYuFrDIQC+Tx5BgQMpDptPNGSoE0
# DATA jWwPwqhuw7dRkzGAmk2ZW4yAatLN9gCFDnXp9C/wYIm7545NfWaPiE4K0QHlOSZVgJpCacls9E2dnHOPHvBJ0W4C4IsiRqkBulWj
# DATA fblZcXOfAM6P3BvkEonNjIawa+J3W87Okq+CNSRSozOJSu0spVFXNFQeZ/WzQoQJCzVyaJQMXV0oP/FbyUbCoXJ6W5y3P1byIl2Y
# DATA EKMHptU+sW4IVdHr0i764VSxS5A1pNsbgbWY6zsZnnURgVGPrZboDJ7Jx93uKHOT3tmVp4QZigwPp4CGSZd1b5AZ9BU1ByVJXPld
# DATA WrFZyVk52YT8DegeTkyYYnfViLstugH4IaB96D+9w2U75QBJmc4wsSiLPGuefnG7Q/BDQc9A7PDKojwpNdD708EAeaBIaiHKPPc5
# DATA qOfoTwSPwNQ6MW3eV45anFOWSVR0TCdEOr+f5AWDzs06z0pmURi1vTbJOvwMMIzwYTSpsExYcO2cwli9Z+q5Wm5Qb46fF+lLhbo9
# DATA IhMYKUD4XiySwNnlMwBQ1UkGXJmb2JnPdKFx3mq2YfJZIZtjRab6mnnpFuOz+nvE9/7ZAtNn9TjBJIqUgjBNHQZOF0TTOWcBj+Zq
# DATA 4aGGGtFBuLbrnrRxj4hMZkXmQYcScyqJCgSKaQ/yIik6mLSPM6B2/e7jNkJXaLRCW5ndznihEWu1AlFvcJmqP1FKY5YlqyU7kEco
# DATA yZ6i6RqpZR8BBmu+vFVw6xszFA6UOA2MyXL2g/M612bwj5TZ5HM6F2TUlzaoL6OLq5OYEc7f7xny4Hc6tUc0fwpCJVBWhb81+Fv5
# DATA Gjw/79GR1kcu8x4aP+4Pj0vpclr2dizo8jhZZq1PuGmxdElR2DWTENdYOd0MueWiiWSrigbcgzSTzwEUm2AhIO/k7w0MG9j+Pgvn
# DATA 9cvYoSlQKRqtBgzaoMOJEbIKjiTUPA0jqm+lKUAoenMH/IvcLaF3xGcvf/ryrzUqVRSTDvYYbgr0DXQJsjcBOCBPFg8WS89CoXR+
# DATA QhmvBwDIVorR2ALqjQDNDplGr4h55vuyhMHGiR9zokb8y6QRpxywkYR1TibP2DfOmSGeDmQpODiMriiQFEG50htOs7TsPB5T4uKL
# DATA 4EQRihlh6+uapQGd3sd1xPRuQU8ThkvDM9/gX9xlSByIlldXaYdgal5ZwmOLlOYu+YkxNWtx6+YMBQqosvigRzNbMt1DjC+CXKGM
# DATA GIq8/pacpDDzMBNWDciiTs/n8CjsqjMZsMkglgIxCFbUq5Vn4/YFZ4bQi0LDPyd8TPjkeDro9AHZYmFHH9noG/N3NiIf04zlTtjf
# DATA eaP+Qo+Zsu8yt/qlzjxAqXrlJQR5CdQEcsJeh43DpL1e4i0/v7OfuAur+sJkNUCUWk4Q63cwvn/0AeSdIsisOhQyQ6RbjrjfwqmK
# DATA 3MYSNE7exnpuRH75X1IqXECL8yA/7R5bMn5/GeUChEWGUBiRtnAjQXWbYsOQ4VBicU/qncHxLhkNn4JYN8wyyGqMOeXaY7I6DLpP
# DATA RWUkAwgXogSRcrMz5GienkHSBS1Nastge3CRsGoFfGhrQmFDtfQISUhgWwFnq3gDvL8dvgGZdssrBNeGcOGQn7HPuWjQcdpAqCFy
# DATA 2sA/2RMUVBMAvsmow3XfwIAhGKjEUtOPqj9O/5fVdlv793Z37n8/+YR+acbcPNjZfX/3/v3dj9wtOYnRVqMVtU26XwU6EvElqazk
# DATA lwzaCyrdlhLklXCsEXs5n1E9EBRfydmd7eEmn3g+yq73zXmbk3yk+7ri5P/79O+Rz9BJz2S+kkRmhtcYhDoiFTW1Xc080rVqcvjk
# DATA u4DVCIWq5Pl3a3bCT+nQYpCkIx8YmlCxSCgUV2DZSxEBrysY5chMHjzwiRbt1qVYNk49uYTHlYs5kNXaHQrVpANiD5GwPHup7SEp
# DATA nk2RC7mN3BzxFN9rqWd9Kb/V2JeMP6VEQiQGtPhqZ2ECx9/iaqMP3csf61yYuH/cnLEv/ndBXkKbQ1Nm1fXC3TA6B0VKndYKMgct
# DATA H6UJfh0QJNkNHS/YbMZqBdRXczn9K/k9Qk6eTzViG/plFTdGZMxMaLnppCE0z+3c03y+DaaORAYygLiCjLlNJfTbxE8I/eKLOx7s
# DATA HF5EsF5aCPSSD3LCoRobSUTrMAP4IZ7gH+G4fwrYbeJmqyUa6w5vSVXqt5h07FPS52hMkec5SQ8VAc+Sar8d5kggx83fq4K/JFB6
# DATA kyexhlk8TPrvHzkZBDHUCQFI2CH+M9xOlJ9Qu9u9+LIWNpjSXpTJwPkbTAbOlcLU4g61O5NVOgblIczQ8OL/tQiySjhzvWkxDaKq
# DATA MqyQYtzD2qCTX9C29D1z1eYM6xl3HytpBsSD+KDptEIVSnSsJyed6KFTDxPSDuvsUckIIwbQlMi0Ho7WNNOpLDGQNH7wm5HIBAsS
# DATA UYkAqhgcjarOHlKbPJuYDF8U9l3REdoVCqqu8CxWWFaDPyA22o1icIkbufTEU5bj6ZA5mtDoGJkvXU/ZuJaNiOlifoNt8vOSxJdy
# DATA 9SQ2l3k8FbjjRouE2Ved6HzGv4DExZQfkBhwPODvb9/fOoAZDphdkdc4zL/uYUHLtNF6yBboWM2Ge62YRmGdAMManHdKOOllTsrB
# DATA dxki6BbfOS9/WgGq85c2QfOXMh1rnJCnqd2Zdg/j9qRoaA2B4xh8Tih3T3DgwB3c1qIG4OsKMLYJvhYijDYG2hdm8T3DIDbTHaO2
# DATA FvUS9IknMuFUva0T9eqe0CraKhy2Li9SWp119HH+FHGjJO9mNwUyMzn1lt1FLue1g9epvssTN42UASu1bZggAnufUzhp0+fD5vcu
# DATA nycKJxSm45/cXQRX2sIzwfgqnpYNE9L5g5Pk8EGOUxFSkMfdeT3+BV3PuOf/ewT+q86MzOPuQnuieF8InDFvYoIGFt0c/gYJmojs
# DATA FWrM4/jsSecTbNm14O5cCeL31dVcY6GWT3X5qH5j3b1Z5p7hQAvE6x89zrzAtCOmAx3u20nnVSo2QDCOKyz3Ivs9vqy002N1LnTU
# DATA 7ahzD7kYooDcWkHeVfJwvycNln9X/ITxhz9F7RQOLcGPvtCZ4V98GfKMupVvhzV+Z4VsVgw3VV1eYTYa9ikw0h5vGc1G/+LLCmij
# DATA jO6OvoJ8QCKb+xdRrVzYWWCEeD7+ZQF+lFDSePdrIb6I8UwrJkLeTPtzTpsALAaX/I2JqnKQkkM29xdC4PiCJZjPVN8w23gCA8cO
# DATA /YpFCJRE7CyxQKhN9DqLuLH5eNo7xSboUNqXf6llITato9rQ8CkiHRbzMJpWxLkX3JiWeyFVDsI08alFf+wx+oI+xr9rG+PHU2hq
# DATA D98YTZA6sY1WS/HgrVZZfAkieqvNn5TS4ag71mFSJ2dD0Is0GNMHcz2lGEqWoaGBE+FSCm6ElQEep8rsNn4j/zY5dTFOIGUkn/ZY
# DATA o95hui/4+zHh3hH9ShGTOTur0mnBsphgRzxwqBKgxwQPGXUzeM79A4Cp3kRj+1Dj2QT05OKRBumrMoQBjrjfHgg3B6yflaHeY+07
# DATA JZ0ixux7Y2qiCYSGqtwBOTc5r7nz8Zd6HPTWGTvmnjCrY0EbUOxBNaH2V4julGqVTWjlO3kF2CKXX0B7CRU2Y+U+uSU9fjq/DXuZ
# DATA FLaiAaIKOkv5e3Pf01Lnv+etRFjphX3BBMkFNY3ZBwkCMcePswYoxgvHpvZWUccoz61djdySQp9kVr+oYXtSODSwkc7pKW5T9VlV
# DATA Z7Vso2WskeI2bmFGzOImEX5s+Op1ABZS9ZxwDuy2y8su0RRDtGUWbIUxlU0FmOjiTuF3jMEUfEpJMoqaJVLoLkluW371iDlfTBQi
# DATA tHjBxXc+pdO2WC9drjTo8trq3KOPF5NdZZMWHtUpDD9taqS389f2SjMNEOH5bzkjHDfKzuxcFv+B0pmN+odfNXOXm5QffIdbJsTP
# DATA 5IiCA36M1KysUcbiVfItUXcVNtrG5NdVScQTisgtrt6/l+peELIWdGSNPjYm+iUFEct+144cFD8h+HcH7eM+akgg6ehisCIIXmIR
# DATA NNQu2rh/34UbcaxIOg0AyiOooXNejyx6Cro4G6d/udSAOwZTRv21WWa4/1FwYCdi2+mEAaCzo8jJJg+fdQBPBHMYwOiKRtkhQBgO
# DATA 619sNsG+HUuNYPWDYvmNRdMNPDCL6MwdazAv1I6g7OdUilASB8O0eHNKntROLz1owcsuebvXLNBCYX0+J3mlzc4YEHlYInyxt9RF
# DATA Rd/zg3IliXVxwakVRbRvH3SgeJgx7li4SUVc7q9INAr5bCF9cTHpp6+LucO+yiJ6coRcQ3jR4heC9HD98cb4NxP/ijnqxZ3wRRep
# DATA aiYOyOnGVfZnRMbw9742SOdtLLlVKUUKYghwdeFqO7eGvEe4OeNHxxBEpEyreEpsu//tZ9bT3/2URh/JEWA7ggx6OXKwmJVu2QNm
# DATA PxLMc8vZyoGrbNHQKsm8EXjOf+QA2RuMphMHMwPdEerWEgP8LDne1R0nKHw5ix57ioaxh76AKqD/t8Bdz9tmRbKuk4wMSy20gxY6
# DATA soXN8eldbLuKnbrQMc2VzMNzSx1wkGmxqOgGLkZFHEHu1xxjn6quNGeiXK2LWAtKd0zPr0RSjB6pXrR7dKnSvFtMYEFHyShTPbTM
# DATA zBlroOop7iGXbnHpop6GNAR/8JdzumWVbT53UAFwdsRg0UViW/OqM8jA/36fDdeJP4lhKpmdH2AyF9IGn6lwHKXFUboTh0oGxlwN
# DATA /E7cKwd4UmNaEM1K2MhmlOURLtdzrkWj8izcInRyVbFS0ck0/BihfdMPQlAN5xZk6zn7JZTF6z73axTNIQJ3vEmni+WrdEDrYBfs
# DATA g06U9Lq7MXetnLbmLpkhngvIsnObRmYUmsz3v6TYL8ShJQ95sU0W6QNDv9s1mMew9c4xPVR2YaOQ1d81ci0ZZJAlfVXAJLeQvrZa
# DATA 4oxxHGE5qNNgjjvuNKMVymhQYPcUrvyL4A9CCOav0b8Lc02FETqmIzqrJP4ojSo6J4az2cxntqsUEOfiidwR703gyzvv+ORQlXFc
# DATA kJyE4CE5cHHaDSmek3XWYOPO2SJkmglvF02WKT3xQtetSfAgr5JC8kbZCMR4nIJ5JCCS2SvyQjbjJmasoKLENjoYyneRyY0uhHzo
# DATA 4OP76Q9e5YZyq9gCeKc9CHykFApzqlngFr5zvTtQm/EchjnA/A+Yj4XZEq3cMir9KoKQO6gN2hnNuHKi/9bvTb5g8N4qAjsOkDsN
# DATA fZgnqaT1QBvHyXVixCMoK7PxOB9E0/Dor2Br1SkVoKX+YSk6gnU3MbB8VY5pEutJb6RmeAzYBr2R4Wr16wrngJfx0nmThBiMS75P
# DATA fKB+1VU7cJzCSx4/rCC2egionucd7zMX6nw84YzVIGWTx7zAMXFSadgahGd9viiHlur6XC52KScziVbv1z2FT0pWkLqgobNwydgc
# DATA KDFB6rEsI1xuI+CgRSXzueGlJdVuC7dSq4XDb7Vgk7ZaPAFOSAu5KiwJoJgQigQQYxBJpF7EdOgz/k8v/1od3l+SW3iO38tcJ2ls
# DATA TtEXTF0G7AyFWQugF4RNObjIJt3zLcoYKAdR+h7sCux9Jflu94L/gswW/OfuAf+BGBX/5WB35x6C0ODTsgzX2kbVDOZX6A1O+tOO
# DATA xgDDpAlZPRlgzDmOPxl3f0CQG5yPHSLWpv1+Ag3UvubpqyUv/pcNZnv5MwKsYAAB41NfcTEsfkrBgIIuk3u9m1nk5U8Ba+lKq/FH
# DATA /6H+pw7PcR8uRHU6aqOLr6UNiAK/dfMm/qv+5/+7euvGDfM3Pl9bW127+UfJ6h9iAqbgUa6a/6P/O//35ptvwvlQRI+MmTrWDWPL
# DATA dOIV0qX1ACRv3O132xnA+lBI5Vptvfat9drS0uEZOK3Kgj+cKs47mZwp8o/waRwRgaCXvceQx+Ws2x9h4MUZUAUA5lNvh9PHZ0tY
# DATA yMgJyeHmXpVQQ0+7bUDlQUMiBIXaPnK+6uSs/aSretcFV2qw23Vqqm/dMcabdtRNeQw3JCBLDYbGGHsiaT9ClD7rnkwp0h2QooBR
# DATA JNS+JUCOnXfTBGQhPZw3njN118hOp38gQuIEpJz8IPs3OP/v3npnzT//66s3/vP8/yH+l06zLvPN6Z2lJXUQsklymeyNe9l5e7Pf
# DATA QzmafiUz9ODHY11K/2SED1dOsExavsPf/uDpRBYDLuNp95gsB2XTwsHm7h5mvtjFLEuIXPoX3dIRZa3I8OTUNf617x2Z1QHkTPGc
# DATA OuktJ7sInMD5fVZnz838AsDBq2qa0MPT6YCgKMbdaQa3Y2k8fFrmHB06odzwafLHfwz/1DiFiRMcLBtCN+9UlbbqGfis+2ykJmhj
# DATA gp8OgFX65JPEefEdTC93Dzjxcjn4PjtRvH5WU3T1MeI4NHhO9ZNPPnFY7YW+eTtZ06Piosz4ZW6oBs5n2e0U1wQs4UUJv04a34lW
# DATA hb/LaqZnS0ttCCdPzIwr6e9JD0SMEu2uCuaW0Hm69BqAMu6NlT8/Wq1+q109bV7enlXN3zdn1Zvmxw314va32sdN54n+e2199o2V
# DATA GmQCx1SIMP+QgEFMHOQFGJ7qLGFvkPIKEi2kUJge67n7dnJjvQx4mWpnwLoxmOH2AOVxfU/RBaO+66hD02tDypA7Gj1O7RvaS8U7
# DATA SZbXbmAgLIHLVELTVmuPepjtMasBxtPDQe+HUyXOJU/hHqyr443jnSUzbnxlJdnvZlPVNmbBSdp4YVdR1NIYUxXtmgDN4R69wEsY
# DATA MBV6GAKnetjuA1DB8ITv0dNk3Ht8NslqZtlMh9U2e8OcL/20rFcYJ9+fSnaDSpCWJCdn7cHjbueONkIiN6D2z4TEEBlhTI6tNFTK
# DATA GdJXywm1N+wMqgXNmULEDobpw+zdooe0N2HNKok+tXV7aOE/tcHwaQnc5NdWk+Xkxq131H9v37qJ9xyA5ODRqCdHtVqNDhBHqDhr
# DATA cwgs1LDfSR6P22o4JHYpyV6NfDSETAGQpA5QxaaQdX6CqMYdgz5WU2sLLIWubUjZ9dqwe9onBoQMkVadRQYerIf7dEJLjWNkNii2
# DATA oPrvhYiHmEdaiZzZ17oI2ruXMOezCq7EJc+emLzZzFlmJtbqSqoBx1m65CVTd96YMt4D4QWQjz5E6WzsbYuAjV5bLeYDsCac9ofD
# DATA MRJQ2gqdDczeAoi4mEFxDRfTfKi6k0Ph30suAcGtDdrpOkAed2eJ2lCqYNCS/jhsaFZOZhXhTghEqKLOdLv/eKgO7Nm5GsmHB+Av
# DATA gXuogMi+PxxvE1mKkluAwBx0UJcoKW/wUB+ok367d57dkWC+qlv0FDAx1SqQTd5WYZu6NN2H48ADaKoBqKNwAoBKqqqV5WQj6fRO
# DATA TwkrFPXliAmpSM7HasdbsgqpTTJFxuAs6i1cS5ZXkplj0eG+qa1Lf6HhmO5y2Avwgq8Afo90syHvAXED4vl6nbeSaNQ5L5b+F54c
# DATA Sfo15Ye66nI05sTIeXEYn7JJTBNczqIec0fb2mbhSZxzv+NupQ4g+1ij/FuYYKkzVUujiLQGt22PHz+h5IUNwMLW80PzQrUDsJg6
# DATA N4oNuXQ3ZWQmh8RZAjI1JpcuEc/7Xo2q+h5pPt+rEbv7Xi0b9UGuq6WA55q89x6kx/lOI3kXznig8lVc7GgCCQBhP5YMb4xQNe3R
# DATA aAVV6jTEbEUz1vxRdfQ4LdeoN3uPy6XLaPyoGsSAsLoOcGPWzTypi7Amk/5WIGNUPVmvzKnnkOBtH/T6ijeuK9LTWgVQ0l6n3/Ve
# DATA 3aBXQX0zoEqUIZ1Grlov5XWrXMu6gJu51x631Zai6GDKrl6G6U0xLO0EaJrbElBQSJejdrviBiJR+9i0lGdKvNZyq2oa42Ig+RzI
# DATA PXaoUQxPD8hM7y+I0QEWCVgRIm+Jk2M5PBDlEj8rIsRynqyR/eDh3YPN/e29w+3dndbh7ne3dloPH27fc4tD2mgyxFcC+PCC6va3
# DATA HqouY6VWwVkDjqJEHJc6Rx7uOeni6S1HAopPcUr1AcRjpqhrrUtTmQcQ+uJX8AjhyMBGbkK6/0qAOKDB7NeY5s8GSQcB33Gt8N++
# DATA +Hu0ucWhznx4jhqGPui5e9abbKIRO1lT15IYKcNe8ViZEH8DHcTwOJVI2qETDlf7kBL2XNotUInthoqWk2d3lv4A+p+WPf2vVRVc
# DATA rP9Ze+fWTV//e2P93f/U//yh9L97yEfZtdderJgzAdSs6tyiRBGoTxwpq9tREhgm1mIrD1DKWzf1L1AE6b+H2RKiGoOvTr93rM1C
# DATA 4CWgi4y7+i8w75m/Dbi9fjLpno9AvqMKp2N1JR1T5JGuFVwy4LJeMlVTLlWOWSaXKfRWRY9i0uCedhbB0tPQefb3zt37u5vfLdtc
# DATA YQCZ16FEYR0Ie+UEMZQtTNgVCVsYAfYAWZjee2lHBMAWFKodtLYP9rc+KEl0WgeuVufkg2QTsewL1lhYSrd3vrdxf/se3yoQ9O0C
# DATA uni4joTjoxsCtpjhoS9XcarUBd5VT0vlWRQ/d/Xdd8vzemR70noAt9Xdrdbe/vb3Ng63HJBnvJp4Qm1yjXf85BrGIW7JcdSmlcf/
# DATA Orld8AlvkWhhJ2mCcAnAt+iKgEvRNx+ECzFnETQ6PG3XWuD+x53W25j8aQivUsv+xoclt7u2pO4xhWcxcjmPQP+GQayv3ryNyeAe
# DATA PcJEIbIsBKMNx53SSRn0YTfgEf9UXPra+rsUhSW/Ki8yHXsbO1v3iZtaotzj6Pkh08hgoBR3BCSC9nQyjDg+6MkkIBIfDQUlSh/M
# DATA SOZ14NksXS4vs/OBjt7DiAX0ZnAi9mbBybXV8VxfI7FDfLYU5dm4r+dqZ+N7G9v3N+46x5jnLaPgQ9kqp08/6E4mnDLdtM+vTHJj
# DATA vzYDeY3kQWKfmeZ0om8mESXMVI14JuNeB6Np0wG4A5YdPGtsgxSifm/b511yMgUgdjjVkDPXn2ndv1g+iPRoo/pn7epfAD6z/bNV
# DATA qzYV/VIbdZaSYu9Kk76zdfjR7v53cybfbs8khaDW+sqKzg1uczwBvh1vUXSi0j+kw5qZDF4g4Pf3dvfR7ZbioI0zpfQcEu2bPyEf
# DATA APZDnmMKNMS4W+6jfoV1qftUVaFvVUsa9DFUb2ooucn1VpUhYAaG+RoyA0VhK+AcqGfwW+vm9G8Ni6d//3DapRwf8ON03H6MzIcp
# DATA rK5c0yrCwVJr+BIuf0UbVq9DctyBvdHQYzERrbzbiur+8PBw74Br3t/6rw+397fupc6tY3S2Y7utK7pqRen39nfvbgEZU2wW6S10
# DATA MlQlTGxMJ2fDMcuk9SS9qwRqRWYQB8kX/z7a+N5Wa2Nvm24aJV6gg3O0lJkJxt77CLD3zA4mxRT34ij906qSXp62x51uB/5CN65U
# DATA nafaqvq/tfROvOTeeKiodTMxswrSkqe1hK2ODBq0R2NvH+OKooS+AX9vEk5PH6J2KyaHWUYaVAj9JgENv6vhf6HcbdCqKolcq4ZY
# DATA tYbK9axr9GunXSAcc+aIsVIV+eSBAnIzeSDXUxR91aYEXXS7X6du0A/SwqFhSzdcG36s7Um8fyimo30CHSC9AqhdgclrrAJKwHTw
# DATA cdY4asILIMPU7RINB9+iRUZXfzzsXKjJhM/fbuBrNmXd6Z2W4Ol3bi5jrgb4T/nSmbQ7kX7pilXPZtSX2giS692dgsK2Bvx5CZ8r
# DATA YXhmphndxRroJUYZXLm4enui+GCqqFybDEmvhdycYubsdJHv5iefaE0t/n6j0UiHaFlGSx0Vqpkl9UqbF+Kz6NSLIS6ZM+tWoV7M
# DATA NAx2cnnSV2dQbz7cjzD22VIJN3ep3PiO2cza2N2gZUPKvtIe9VbIGL5ijOHlO2rgJe6/fqpdM2EErJouRwZg4Bru6GbZAB62mmcq
# DATA F9+q6rPGxnjcvqj1MvyXI7uz8nvasM7/1vhf9a3q/BvuR1BPOdZd2aT6DModrTbfI434wj1eSd/G0MLuw/3tTR0coCtj7boiOOVS
# DATA 2ais1Lr4+iqhSyIfRQHzZYB5nwMOl9FOQanfkSsiIS1/Tk+jmim8HCqJKoPYXpBcgDKWkC7MNoAQxBLsEBOjeLovNWW+2qqxdgeo
# DATA DPovocigChx3SxyZYOUAFmD40lF0hUKHK9rBilmifAkqFDK4DSlh4KOiy3Jv44Ot1vYD+G/IT1Eabhb9a4ddEOzb44t7OtSjRGAN
# DATA kEhR5/zCHYFDrpIIfjrsKwLtgIPrkCN6VeZQZq0Sgygp22FmzEgFitjNaeQ+aEj2iXSkkfsXSzlq1BjLXuKVcFKkXIdxD7D90RYW
# DATA qTxfFiHx3+ey+U/B+lNBrttmuYvlDcHNZXP1NRHlpnuCqU4hQq3KGMroJj14UjY78wiqbGrELSgO/0VWycPbCDzpsWVwXBwgGyFG
# DATA ogQatbDjkhmIlVbKi3WegZqrVcKgq1ZHSvpAUafLGHUSh4p6kQ8OmjcH+FwtKG6w1E4CH7noXGhfceMKLp3GRf7IA/On7xyed2Rh
# DATA 129sbm4dHLTeVycW2FvKX4ZyOpEd0BNaBBBMM5BHfLhFRbL26a5V3yt63O2Ajv0JZlLnOSHt450kO2uPyfsjoVwLigJdiPyQQP2E
# DATA IzplmwEJYslmkYtD83B2JheKh53dFfMdO/xpXYwsjZx7VQAHPFvSaROgLtspIDmYMicr6Ygo6oYEIsVvedwEB6TxGqIVDSdngCyd
# DATA U4+bPIZl+UqCH9n8FHJialATAHtrIf8Nk3BQz5UDIoG9YIwqgty4THGp1GRczmZLJsk5DKjuJfg7SoUgjALD5fKyJsU6jl7KypzT
# DATA TWfFMJ+CpmF5mZZvFhGWxdRp32C3YoKYuEzRYUp1XW/oFMaufsM/s0oSbJsK7xl7Vfpyo3ome83vW5R9af4RVPel1kM8gJDchzsH
# DATA D/dAPWBkzVATBClHJOiSfkuk33yE8W4xZU/FYtrqT+W2CAOmKK8IXA3EPdNIQauDmkJ9/BEn0l7gAKzoaHmgQ1LPZC4l0aJ+eQRh
# DATA XLple1nRc6cDbzQ8+rPgdG/u7rx/f3vzMDLNcnYxUu1S3W0TUHT01V6hfLLUfF1/I+a9PZm0gXoBjEK4MxAwOOXavUyeYh50JTwF
# DATA 7sj0y7Cfs6JANNExcKAtQc0o6Klvs9LRsm0TJrlcDk6zGQKGe3Fpx2EEIVqIPjSdhEFI8Ev4pqJ9ADnyr77kUi+zOSn3C+9MQVvU
# DATA WkCqN7RX1Y5v3WTLAX53lFKkA2QF8iwKBIVN3oeoNOMPiCY0c3hF6hO0WdEf4NluBtVxbsE/mP8/R3W+9jCgYvvv+vrNd2969t/1
# DATA m//p//8Hs/8eXAxOlOw9AGMhBKeQp43reUypt+EMtWWCBnLBsyjSyF8hw4dpMZ5NhHWXn3CCP22MPT0ZTPr6B8DTqS/0TxPt+1pt
# DATA yCDwX8da/N2t74OC8uDh3dbew7uK0Lfu7T7Y2N5JlzYODrY/2HmwtXOIkQ/IiECWhXH656X36uTucZQ8mjTfLr8XfI4vlhu15W9A
# DATA +ulu7QFY9E767SxL7uFxpKvG3joGX1vNCxHEwXB8Ds5ITLFybX18+UoxnEgjW/no6+Q7yTtr6+RXyU5ZkMzyUfbo0Tffe+vRs9XV
# DATA 6qNna6ePnr172kyZhAVWPNn1lAbaYtU6X4+eGYFptLBH0JPQGCHinnOV8gvaEhjsg8wFIKJUkps3b0TNE1cfIHxJIzSV1EgPVUp7
# DATA nUE7NfdJudaHrIdsmnakcyfgnf8sQXVO1K/dHAI/BfZHeG0v2ntQCcCewLbA6vsOWnPTmkkTjeNTj+BfNbAOJeUBl0hIsIX5RO1f
# DATA aPDzkuqAirrfL3lZU9WJWX2mvWHf/gT+UucmBaii8aTMosTY9EA4Yga1I35G2MIR2/1US/wnWv1urc30m/J7C7V3jV3PqfG0reqo
# DATA Xl1r6m1MeZL0RKLlCne/fqfXpa9dVWBZbq7SstRSLVzBbxIBbcodZ/wrPPCN6p+pwdZa/63afFs9WvGflZdp2iEb0tVHygwc7hIy
# DATA igiHG+1SM6KgEYdvk9kDsXFJzSLZAXUubYMoAoQAnizSZyUdbbwPIvvhh2nk+L0ONyA+owCssjOcvA8ILN5RBe8anol6zIHVODmY
# DATA sXyt/kWlqzsYra7f5Mze8u0AIJJgNdbCfKC21NV9h9bXo4LZYuuLicvak7bvMySG8HayVpaHDYqX3WFeb2/xekJ96jD8iccRweHo
# DATA g/6QPFPc46B9VWom4BkI68fpHG+1j/b1ptzc39o4nLdjKzKfeWx/td/O2V8Rt7TczWa20qutYqDGRl4SYmhOPuY2K/wMxtba+lM1
# DATA XPF7526gEr0L3/YGj7d3vSOa07+He/c2Drdadx8efN/RdOpPLnrdfofpHq+2XFvtlYRQHOCSlJVwMxY6JpmtKTKs21QUBExNuhKE
# DATA 7LaFclIr5U/7zu5h68HGzsYHRnVk9IUFuXMlubbZmQOabV85hNu24JSJQ65dZccA/4Wpd2NwjbQaiPskyriQWEuSPEoFE1TMGECa
# DATA 61hLvt1A0oEvy/Br7VYee+LVxQw6XN4RxoUuaHRUWqusrd82jkqu5xU2G2tQNMbjzes6v8bO377mftH5ji/tsuq0WXViBMIXgi1A
# DATA uLrZkgV8w7pmNnEydpESnGFnJfuLZFNWT2X8S8CwIwWExSCdi4OKl0JgUpGWlIeDXgxYp3gON3cf7O0eeGrbCGUJpbto6uhyVN13
# DATA xeYtOwTLeQSTBfo6vMbcKbIv6feSb0owmzOK/B+1vOCIcIv7Nku8cahczKDoZYsLc3DHMmbjOThqxppyvGa5nij2l9/Skfnh1guT
# DATA Qigg6H4XpEyWdUX2cwm/PSLA7Kan7sV3TgJvfBJaeWhNdRNNfSL0A4cRolTPihO6sX49eqAZIAvJyNSTJ5N3kbYUqj6gtE+Hzag1
# DATA 8OT2Mg9QzGeWkWri/KNu2ippMDASjbvoOeMpdcvOBcaV5LeioeO44JGS58CrhKXEhqJma+WjtabjfK6x4Y7qIPyBp+Kbqtyb6Zti
# DATA H/1wOkTWgAquyswfHf0YB1LCkhXNspJ2vdc3n0J5xdDWTRfYVRqiFVdZvZJKsgLvvp2gWFnCmrQYCT9k/t30rbS8MGFxhUM5c9TN
# DATA tbpqtxlRWOhioIzCSVX3IOrS3tLKJ4xoxHeNtTJOvphr6aTF20oncyjN24bW0wV7YLcjnZnw6mq66xvuUW0IrfAezjVJiNTJWjjS
# DATA HlXBCQ77RwKLTjXptM5Xma2vRvbIAMm2mGCTTAkpjIVTfcwAW0DPhV+Ja5oNWzpNQPuKCmhosx51k9DzQGWO1BdN66kkk6w497v+
# DATA yleiLl3xWuetqBsjbSLqNZhzftxFfSDruGucxaC8FN8XnLHV2R6iNapOgyOYXAlawQiIE8cp6GpBY1ry2sTtUaMqiB5oiqphGoku
# DATA HKfnvSxDfx/nMF2mOFjFwvGglaBCoYvqEffsrPtMN6AzBVL5Xmemz6G1O3DYCmF6NDAEgJG0QBJiWQMFJystWBk1FJodWSXndHNY
# DATA gRHJbL4QQjZrXIFQSPpJgwjPvphAaiHQuUhmDisR5uqsO+GHKCbpJUAnqRFCnuzrNZjFtC307VFYugnVUYeO7Do2F+cYP9zY+WAr
# DATA RtjtidKNU58py5L3LNx9Drt7PuwArlzH8v/XJqdFpNQw+g47u5TnGFNAHK/J1YrO6q+jG2kup3slIu2zwkW0OEaPteyYw1Lndz3/
# DATA pswfS200HJVU836oUMA1R739wvrwotB8SG55k1nMd0CiSoLv2KcABcbO9HyUGZe37iADZ6J2dtLrkeK7gmmeB5PGuk6ou4DbIjeA
# DATA xBzm/zhNAweF2EWKZ+ANV5Ig7sUweoJVZvsfNJazjLm7jzsoK5seY1AO1hasPZ16rzhsMzUlDWP446+XinaSoSPXGhD3G/4xYTjg
# DATA kstLo/4JOhVbNXDjgirMjfwGScxho5q2GdnZ+c6X+HXpRS4Wk/lKKxR1Zm/WDyoZMpYKowoDAzM5OsffLJXhNnc6QvW4mjt69moq
# DATA Xa6XshaAirixOnwXYEcoU0NGGqEcxxqbf+q8PeidAhfCmamsh+GR071osimdSAgf2jTXnMoKU/JJPUj03vL8eG0CK48TExWVJcu0
# DATA UCOzgGHH3lbMNdcdTM8R7LSkN42duqaXOWuCLtBC8RFq120DJXvpluMNRVhWsX1iJkBcWdhHYtzxA3oVXkQ0mjOfOW3Ed1YpvicY
# DATA sJtrDzQKS8W128mc/yUvlc6W5uottRGjnXW38E+IAwzWUO+OMbihZ4pv5jqvulSEyiQoVz2PV/BmvviiR1vudECq/qWrX+yxuV14
# DATA caxxVRBVIwYsO/LCfzSk7wX8/857jxnf77W6ABb7/91YW7txy8d/WVtf/U//vz/E/956Y2WajVeOe4MVCJoYXUzOhoMbECW2O4LM
# DATA 68l0pPZEpwuho+2BhcsMcEkd6EjA4vS8Atmdrj1+jP52S8YrcHRB3nigyYCTqz3x9G8K5P0LkAZf2Q0wgI+BTAQaSQa8/Ob7BUov
# DATA wqVrJ5yKQtF0ujSl6kazMf5E6frtY0X2QiSETQZAtqq0+1jSifmSVluqyFiNaxSwpKVCnX6lBl7ZaiFb6lMCWtCAZfB24WrEp1YW
# DATA nvOpDpWwnwa2ZKmD5vh+McQGBP07YCRn7THikawbPBJ8IiFJ1AO4E22aMS3S6iG7Em6+PcCgN8jMNk5SGx6Ob9udj0fBbZfzG9cG
# DATA pwUXmSRSsjoxnAbbLSru1BubMBuA1C+aTG3CpucFs6LtPidCmdYQajXuUsMk5+LBNvjfSizmzhjnG6yOw2Cqh+pkNuAUSgmmrHFy
# DATA dDhNu99TbFJmD5ofdJZxRCUGXl4bLIUem1haHU7xSsdZa2ExcRDqqrX/KCUR0tEOVtZZLunRMGIIDV4bOyEWyitxb+cAQFZEkRAP
# DATA pwiLpTJ/ZB+yUyxnC7RQslegD/RV00j/WrVMqdTIad1xinakmtfhgpwLenLpgZ7M/rCgJws4EtKzku16xXVW5k1Vsa7SYBK8efOG
# DATA N+CG9bvGqbq9Ws63nphMRDnUgtaP8tRNhpRZuIT/FVsKFGZP1AwAoXZPa4XDuItxcyrR99gK9ZzDHRruRnKPSCzgEzelIZ06aCLH
# DATA Um2NQxxx0UgunfZU5zA6jc41B7vpMFsOPlAtvr+/u3PY2tq5p5+xifcJ9hPSss/8Hg24yaBPxkYGLF1LRAmi/eH6ZHDJCzrMujzf
# DATA 16CogDavODMMyi85/aRm3kruIcnQmGgZ+361T8bDLEswQ4EJ9jYhbJMhAp6foG8l5l7kyn4AMPzwSn/CsbaEQaCeUxDMcRcYX/Ll
# DATA 7BA+evv8uPd4OpxmHJfLUbQZezLDV1pDKScDAuTxBZYXzxq8HyngPS4cMyR/ScTil0Q9V16zvP9h/3A3HZETg3+xcpyxvlTJZmI7
# DATA FVm3mJXFBB7bA6/3spndgoN1GkclcF2vzSiYhvojYeoTjwkN1N/2lKnlMshXphEgXQCa9SQfuytKus3BdMbInqUaTj0LKGUmSGWD
# DATA bNKE99+CNACO3706LdP+xCoBsy4BK6puWiO1Ra8jMxq3IhPkAS7oAozNNmYQdLjOP0EwbVPV8OkADX5YZW3MherkUrPapDyOZyfj
# DATA Wm+40h9OwI96xYYLB3AwjpOLmATaytDWnJUddxUD0mM5yu3UCnWqumY8f+ruWFCTZj43LELYSSfkOXw9m7/7oPLF7090G7M/fD2z
# DATA XeK5+37SPQcHtZgM60WQlwLwAY1HoOVG88AEzlMgObQRGof1G1hIaIGnFzaw72YIqtNOBy9F75TB5tdqVajN8XhgbwwqhdHMjb6i
# DATA P502NlzXIyroftl4gRNUCAQbK7Yb8lgiN9IQuBvqp38m1aPS0bL4qEmGsAbFjp+0R5BFrDWcTkZT/XBCuFONtdurhmjyOGlYoAi1
# DATA EyRSh3KMP7G/jkwBTQtbG+xhnYMpSUcoRTJGJvw5Rf6XgVCyyZB+IhyKBkNBiJcZ2F0YOkV4m1LiGfT9wl5T9kWMdxJAPN12RsD9
# DATA JTfhUQr53aYnZ4mQGCDh48tPX3wGOEnJi69e/vjljzBLJCSV/OzlTyDnY/LiM50xMvWg5sGF/uOBIhXJab+NI2YEpx9hpl7mOvhj
# DATA Df2EwEyfY7P/8uJLgG+iVrxEk2FbkCkE3G+GAHsy6HU72KCAh0pe/Ep9/3tMX/k/AMQ8rGOzPWCIUQAx0jwOd7TT7p6jeSzlBwhn
# DATA JfGnvojVyTSiza5OQtWD3/8aUxt/iok1fwxoV2pm4vk81YvIRJe9lTW7Ee2ysBkpQyHtfzJk0A5Q25JeGXG4N9CbSD+CjcZwXBJ8
# DATA S0/Al3ld/Xkit86L56mfA1QLFGEW2dJp+uIfKMOzmo7PXzzXrZUuzZGblXm7/AoRvqBjf42ZoJ8DMH6FevV5chkc31kdHsL4Z7VE
# DATA ppnWGec/U/98hh8DMhgkNH35Y9cZ1x4uRSwslUInESA4JcLoQRWLdM0KYkFCSBnPWSsWFAKG3lCDh/XZcu3ByZkrMfJsw+qWYHqf
# DATA Y1ZYyJz9z/PR0XI2uqNCO/L9ZUZOl3Tcs0sdSQ+GQWs4F24ASbkpZ8EU1To0HdoIL0plx1QXqNfc4f9PJ63tvxoK9EoTwbvDQFpV
# DATA Ej0cRrOic19lFU5U7+ndih4pEZXYTUMKdKuHVdcdZOHG6UCgJz0dBHE5RlfWo7R6yl/Cu3KzqbFC2HpBcUotsgYyNBYqC/kRGXhb
# DATA 5IVoslxzrtPY/awa63e7owYhc8OfFsVKHhJreIhlWYBIOvtrKReo2vaeDxLxWhymJCt/oC14Nl4pDNGCExYcVuSeuKxZMVvSPKo7
# DATA HJ+/xwuDpzB1SiMkLuWlvCAbl1uiDcMQaOkybUnNfFSrg2EVVQMjTFdgngFEGNIhzOdKj0/BNRHvLPYQgRUGtss3Vnhs3JLnm+e4
# DATA ZnuhNyjr5J7Zv1Mn9Zd8OOmSdE9rJKHJIgzLksTERypqt3m5RrkO4DZ10fDnQcw7XrFgsat11I6HP9irreyrzCMAavxn0yl6xJnk
# DATA m1qkct6iq196PO31gfmx7n726yvCgbkaPB8QbD5Em22YtNS6Ta/ivqO0h5p7w5oR67QKuwrZxlT9ESlwtuS4b+FCChpVDj23EN4S
# DATA dNPabIqZB7XltDadnOCSn8KTUvrN73/z/Judw29++M0H3zz4M/Jti3p9HdVvs6LpCq5ZiPiQaI8wcMiiKFQ8azSP7FJBs0cMhghi
# DATA jc5JJXGg9ev6EEJUsgzmrCdmq82WQo8Q7FzF9KC8VORIRv2mra+dyRb7Upsr3G/pF9M7rbVxZso8FbPltiGS58nD97SdtcYEz6kq
# DATA tCowjespciUYwbyFoQoekSUprlptk4BWrf5w2sP0uWa+NbH0g5pkvZbw2Q5ECLuDmGklR1mTIM5So+KO10EYzYUt5YAMtk4MnhCI
# DATA mPUpF0kkbP+NG3unIlIeCFxYzeQGp5TN/RLfkrUGrbrnvCw7IyFnQ6xM2R0PLTPHLzJnw7huVLbaPOtJBB82ZgIRrL6usb4Upper
# DATA OejDkUGRstKAD/PECQ1IPV+XYm9yMoTQ1Nbn+o2K8XoH11QSAQkJ9vIcVjnQFeUwwhEtmeVzbRbO5lzGSB9gPTXBPMAIepMWd1qT
# DATA SLFvaIpC1rgcW1mJz+fNG1oOVKknUT6w4nK92I1yIEWZit5KDibD0QhhyB5rqNeMHtWSjURTB8xU1ctUnzl9K5pulLCbICqs9ldS
# DATA M/gMbaz37taCtaVOG5UWMpadriaV6odmUiI4v8tqZ1Q7FKErqRYqMo/oc3RpAQkppLJSzSk+Dx07W6gMgaia0q3VcjwiOkL2zdCu
# DATA SfidJl4rrffvFJqxyzC+6azb7mN4dPE18CEWk0+gyDSL+wsvdqWQpY47APpQolspPbnwFfZ59efZR9AjmmwqAMiWT5cDimw5WKwD
# DATA qep8r1mWTv7RqC5BzmDlJaLXgxbhd6A9I/XSVyzE/Ap1ZwslbJyjk0jjxsBjdXQ/ji2TXvuGOpsDPesY8Va4fnrlSYfdUYIRaaMV
# DATA HerkLZo3Sb+YK69Z8P+Xfw3KvESqHl/8+uVPkhf/DEIdPmKw/+gMoIahtL4InHlEN/RjVMv+5sVXoA4EzexvQSf7FeqjP+cB/M2V
# DATA ViZH9F+AfMfv4Fa/fQEpMkj78fqVFkw5lpc1826v6Pc5MiQ2pJnLMYWsg1Qr4d+O40uOI76ugrFezbVLl+ziV6qFvXWjYjx+/t/w
# DATA xiJ3etLEgexWMphW4wxT82hv4NrG+PEUyNkevilpK6Iae6PVUtdGq1UWX4INr9XmT0qpUaMTjj7oGxqwTbKTISPtZ4pd0SYpVAhq
# DATA PoLUit1+h9SIFBdF7BPbPeEXmdXIiMWqJQKTQXuXNmQjiU1NBFEVZAD4qZOuoGkX2SY0gGGGk+m4L1Vq0eFVUTLHXhZMQrWKcSkQ
# DATA Xncx6jZMRi602DX0N/gPfJVZsQ1+1YT1T1FSM3d5PDN9g9NSkf4HDgXAQuRVpW5zj7vDl8K87Dom4I7Wckq8j7ymgg+npffpEH5K
# DATA y+XwUvgc58xEILI2fhUcXMXrb6PvK1fvu2cEF6dvAaOL8ndoAVJk/0p0NqoNpgFZamMK5qqCgTOi3h/ZYTWLlpazG0qa5tw2Wq8u
# DATA C1PVJNDh3yzJ4d+Ohh2fGFkCfxldu9Gi293TUqcE7Odq0VpoWGi1cAe0WkBUWq004ttJ5CbXDdGkvvhu92J+4gvQ03c9eNUx+PGk
# DATA L/4XXuVf0O29oMXFMfOB4fZOErFJsk63QpZHTgKEeavhRv/q5d9AI1AZWSzhkv9XqB3aryVqJz7n3kDmIWz6M/z2R2gqQx5O8QTI
# DATA 0lUS9dmPKJMRKKP/SiTlxp59CXsXjUXYJkC8grTZgPgHssqLrXhBOYdKa/9nREj9n/0/R+WPcvRrh38vjv9aW725vrbq47+v/2f8
# DATA 1791/Ne+hXnHRB3dMSFwkHY/iP/K7qi7U9Hy494EUnFpJwdmRrPFYsBC1HidPbHF/glxpPjrR4Rh9sV/9/FhVzIjYx/jcZ0Wi9+q
# DATA 3kxit4pw3pNMXcXxgmd2vgeAFb3JBRlw6w7ksxvjXkofraa1HwzBgR6ip0HO+lj7tJNHu9R6psKhSNtdy2WLbOTEyR/V1282Da70
# DATA yXAMCKoWBgiD0K1HK6V1E3AIBl81sDZlqeaO6aNCAFKZEYZxDfa3Ptg+ONz/furiO0lkJ6r3cX94XEqXNbar45msPUIiDV+lceEx
# DATA 4PCRbvC4bg+STaLSKbLAi6TN/QDa39zdvxcmZIaaCqFozZqFjpjkLh9ZOgGNu2TGAY+sK412sjfPIxMa5bRFREiIuSv3zB7p6nRD
# DATA 80F3g5FGM4qTK/DT9pNuNWoPJbgOKAhA+3zEoh18qMgT5Alqop0bjn97QHhdIGnNFhmjlSdeaaDFkgrnhhj0fogQUgLrFXcwBAJA
# DATA ZUIQwaIyb5G7ccmM4qBY0idxGEu5pw93dwG+8vu4qQ9ctyiqQ8ftsrTsYpDhFdruVNHH3LpYD08T8iEls8Q5mi6YeuswFCWPdp+1
# DATA T/SO1UnriAx7gOBFB8Fs+pbnXIbkSD6P0TYOM5yJtvNPiQsWKkpHdodtfi6EdV53HFlP0wa2KcBZEtU7JypoVroUVMSBS8uzgH7h
# DATA x9HoDGGT6HUyYVxxbB45BhYd/1B2AxQGaidnlHrjlg5njuSxb1dPIWj4cm29cuvmLI07JkJNi5Lwzd2dw43tna19wOzc2jncdS8S
# DATA s5GvYuNZhg6QC7+aHlIjWv2Dmo/hU8J2swuwkkPxMBi0N1wpLBhT35tYkTlNXCWkZBZGxSK/gcTKoVoi3iLHCGNvxysEy0TCYsBL
# DATA nyZUaHh0HIHYqFZdJpZioRifKDyQqLIGue3UZgjjko5MdU0Zw+nZNSL6Gq2mKS8A9CznnXsU3kfkWmYCxtMYmlx0jOzEmOPxvBSD
# DATA s0EPE3ZSgH+Yzc9mUWBBe2gjFom4YUqmTPFikyM41mEOlWI0Hk6Npy4bk4UmOkqNRnpE9pBlbIeHmhOtGHWyppnKGUeQSjTXvhpc
# DATA bQbSAfPsAJBJVjT0XPYaeVwPuMxre5jVdC7UdCB11CEEIeZlYc67PSmVi7ASF02ZUorlTJGxpjQz5HsPj4Pya6urq+VyMXxi8QTt
# DATA fqSukHiu5Jj37wK5icsLgrwTsTty+cCm42rIYbqKIUCHsJnPZVAVS3OTJS+kPY7xMEtL97c+2Ngk3pLSnB98zfffolegxlBgcwwG
# DATA 6iKb6gAp8FByssvZzK4L3FbhTGiA4OlohMLynE7k9ZSOQm4PXcDauT29arhp2WBRPO4KZU1r3FVsH8gK2nOjrt0RtU9HsQdeOeTu
# DATA LV6AcV+bA1GQH/jvubYZEzRGe4G1G+/Moras54mAQyjIVLdAhLNRYLWkrZEwozVHweHNFl5GhmEIR6K8tGgLIPD4qEwLMtLWJ9IG
# DATA OZlUxW6oUzlMlBMpYK60RVRR/nX1qgLK1yycXEcwed1CiR8Kf2rdiRxmXhwUcqmTLkfbHYFhlQf8FJkiVdUCGAPudra/3vB6EYfn
# DATA sbxA6D80r3vmDFDLvY7E47Jvy4tFqkdp/GKucdeISJcU1FNM4mXhns8cHh/m2DuUi3RlnsQRSBtXkDQWlzIcP++jMB/NFaWPUPKA
# DATA ORU/PXpGeQVImogDbl9HlLCDslrGcWmucOHJnQuIFq8oVlxLpFhUnFhQlHh9YkShcPAaZIyryxc5bol2eywtKIksLoVEUEIkkoQV
# DATA OTD/ha+btn5m6qUipXmMO7jmdTvZpmHHUJU5h6+cvV4Ii4qZXt1li2pB/FnXZ8lMrG0YUkuMq+2+5NasZmohvs/DGWH+RLtrYf7R
# DATA IvYCd9OD7Q/2Nw63d3daB7sP9ze3UifQVjtPcfjRiCBuLFFXa2vL0yN/vSS1H0GaDYKFcoyWeLtB5VaPziVdsyA/DHb6G40FqHbO
# DATA BOBxMunfHmwfPNg43PwwtCCCbp3bV3QZNzddMNojjFaHEGEXX33/QUUsPbTRCCBZoAUtJ6InIFtfdNuoA21Z04yDdRRmdKOPZGr0
# DATA HEZoHbkgXKVFmFaSau+5+2nOqpPyMrM5DPyx1AMex7NAFdc59zRA4jYyIm/tb91L83FLFxGafCScRWbtYGv/e9vmFL6FDEWWqPsf
# DATA zV5VQobSli+6zTOIg1NTkByPh08zVF6PppOsthRwNkeRwKrl2MFpBukkYxrW+Zmpr2HC9xmCnLtKa2HUA50zjwGaW4onh01ARyJE
# DATA Ws0D8RCCph3Jgsi2NuPeEZ8n7CkzVvo3QbbIA8C5ApZCTiUPV0RMcsPLGet7/gNoHv1oyuuB+4ppnYt25MaDu9sfPNx9eEBLcrix
# DATA /8HWYXq1HIFi7DZR4KoOhA9ol5drCxkHqiLFCMJ6JILQeAJYKxI/QtlvZnxkpsAIK1aA2xtMz4+NOgMt1khHEgZGYww2aP2OgRXR
# DATA iOCj7hhwFDLEFELEMTyUGGQHGiNjtgaPI8y2bVhy7AG3vbBW4j+IMsKxBL4ObYQ4VoFdUTTGRH6heDWYIQnKVlO8qgbUnpyMRClY
# DATA tWPIlzl4bGF799TyKfkbzxYsLvSIC0Gn+M+MoYMdw5xqrGILgPeX7XQBOCW0KCFAObtIUwN+9k5Pu6ie2d6ztZ9DPCiAdSZt7Gct
# DATA 2cEbQrFzsI/bA+GuCDlCuwBXGCUSHg/pnW+rfQmO91xUPKGByG9gnvpAM6SOdMFUhO9Ij+kQL9HDs2FKhqyDLSZ7KD7NpWFcwaXx
# DATA eWSdgHF49A6frTWIxMKkd2FcXJ6YPxeQyugA5ms9Zq+HgX4rOVR00iwIHDBy8tF0VS8f3FdPukh6x9lZbwSItQOCO9KCVofxJwPL
# DATA Uuy2kLMavTNsgdjNsSDWV2g8iGR4hzCPNoQbtyZD3C1iKyxoJrCH4hpIo0s5OJ7G9sPGnppv/THJ3+Mp6fMS2jfIT0s8GY49W6Xp
# DATA yxtXtC/5VXl8tkUEzwcZzfEsLJeLaF2UEWWCqXd3GbILX8O7jnZeBHJ/HjA+P3RhdsLMZjKrBO1geiyDV+lRif6h7KjUK5kr2Q2Z
# DATA WsSfGCB7kE5D3ijy9pW+ia/A7tlRaDZPO8IJ1115R2lOJFzLIhQAX47z0V8YaJJaKTi2C1pBXsnUxo1eA4SAQGbYAk6ilHTq9C1D
# DATA 2sM8vFxDoScQ0oM0pZqbhefBEQqj4MmvVri+CqErpw/0Saxhy4Zp54gKmmQjvrzzrnztJSqczQLjhkWKcDarC9fL9USxZwSHG3yE
# DATA qjXh5JkP/ICpdW1BfgweIjrzsTt6vnOiPZp/88z1J1nIi8SOsmI6lE4H7SftXr99TBgwaZ4++rWIk/lqauoXJk+kDqYcO64eHQ+H
# DATA femfbkSSgvoouLpO4zyqKwGv6fmvY622m/ZVUbXW/yd3288iIKlGim53LhixxoAsr2vIFcCS4Jy7eEWcDxW9Gw56J5iVm8sTZNcZ
# DATA AFoGhb5tqoiBaMWPy5WPiuvn70qHnmf/fhcNvPZ9eGDKltsY29KwkVxgjeD7gpMJtXlgKlFo/JwhOfWE/XDPfUE3XGCRInJssUA1
# DATA UkehenXj3veNjxDfqo4C20S7W521DYC3zB3CMEh47a54pKlZf6jE6cX11bt7W2QNcdXWi+nZLRiF02Pd25weUTx1EWcCoBQuc+Jx
# DATA JE23QcQIoPY0cAU2ihWoyx7Zm7XVVQOIcTLsD8eRaqWdWGy5or6aXjCWhgHfiPRRL5jW+ZRDViuczTcavOKS0dJUSe8qE3Qhb2mh
# DATA 6psoiYU0faDB06trwE3RaDuBUBRAV+xNVDlWBwJSFpgQuyPQ+GDmUq3sm8cf/LvFgHWhXy2GaQzVVRpVIiKXLjzXzsJmDtAWHGzv
# DATA fKDhW1Fzb/R9ciuyumsX4xjBctVp98FIxOwnmAYRURLXicNaslqitbqTs/ZE6BVg6blGjBmFXUAqicegCkM9w+TpsKo3hM3oqG0t
# DATA bZ0MB7dEjXEtO50LhGrO1RWArLSpixGronrVIgS2BoBgqnep5ldpBZwhUSibEcrd4ELBAtB10zUZ7jOk55eBZZtbdF1l0L1J9zIS
# DATA Tui8s6oAOjYe2yRFanWe6KA1fCFUiYbJ5aMBnWbMzstzEsiT9Rura6uPBjOZdfx8qIRSSq5Egz3iYTWpK0/U9j935g4PJCjuOUGR
# DATA 9JWtYLY+duWlCgBYhm9E0LGmuQmIuDxj5OAXhFnIE+bWitud613pTk5WsNyK3SCkooPtQEMsyxQxZtfYv8F1hYblLqGFP8ZgYkW7
# DATA GjoNMDSu18WSW1OjXvLXssnsTuCTrplzLmCBecCO0bYp5TRh0O2R3zJtsy7UkLUo3fms7GXJ4i8dYQZzI7XPtTeUJFyR7N05FOzD
# DATA jYPWva29rZ17WzuHmp5pbc4CkNF5GeopN72IGqzG0Y7jWeqvgFVsZNUrwBD7cMNNG6WKy2WXqi60v1t8jUKOsGm7z+BddJ0DdKWi
# DATA 3kMlcyoB7g57LOlbMlEzJP3V33IzeCTMQSTnkKmMlCsZiAGKkLcHiZhEvIet0tjQCeh1EyXAU+M0dSTyEMl1gFmHapq51WiGBmpJ
# DATA B8P06gjLFnWo+LPFy8+HY8790gVkdhHh6N7NDcldTA14jdhecvhv91vUAT8iV3SrTBYc89t4KHp5lEyNJtA+J8TXhvcWVWfl1UvY
# DATA FXUZm8vnzAblQolZOXZ+ZuwPBqCmHQfW+t8egTd3iyyMyGvJMeYS9KBOSgJcKY455sH25pyOgq2sYX0xaWhqMnh3W+yo5QMLmnUw
# DATA sRrk+dVpT7rBJox2J+ZPJumuxWPkWgNjXLDoUS12OP0sHy8HV+EV66H0VSg+YMh4WCHf3AvseJluLbL7ywsZHve3Huwq2R21Cpu7
# DATA O+9v7z/Y8sA33MNd91zH6by7d7T7hacEPY3zQTHvcMxWGSBlNJ2jbPhXbdvkNJeFEBR+j8zHyH5rQ7h+yrkzH3dz+kjG9QWbEp2z
# DATA pKGcj08qymuSUy5MrOJNX+DPnHM0orGyJmusw7QApqUnT6WKLx63zYNyblwt1xjZSmHfIXst8BK4seUOF6/BIBQyuc3orIPeo2gz
# DATA hxe5varY6zQPylXckRVBlSRwBYGlGIBP1HLre0Dri1m9H4F9haAdIqBxaj4PDjZ6liUJucpUzDnfPn9xhVacefTq8fGLc1iTSBOi
# DATA 1HRAgnYQu0HCjItewIFEgcErGklVOEoeKeebQKuDZ6PO97mKR2LMVWxdHbm3MCRDovoWI/rCTPoovjKUwO56YxEBXWJnQadTffUL
# DATA SlkP0n4ZwljXX7vQSHlgHJYjXpAbd72mfL7cbNFXRACTPv8hq15222FFk4S7117vuhoRBxBD2DGQV04ZqbSw/Lp0DaVsUTLqOG8t
# DATA K0yprUJ5r51l7DiqNwSDBaLAc6J+w0yr36jPQTzBE20cyNQy2GzaRp1c4J8cxNQGHjkL+WWUr7qwvmu2zrbFNlcnuGOxU6HjvxPp
# DATA yqy6DdHfqR8KQo5jgyd2nzhXDL9x5gGeUUQYxF9lvb/oJt9Jbr3zzo1bV/FG39r5nuCFrFMqeHL0QBHdL43TP4+EgTdKIjSg2nz7
# DATA Ua34d/kblHClSF8HsSS1BwFiknHYbDgOm3KZPAdN9/KijGm0r3U+sM2HB4etg4d3Dzb3t/cwRGh/6+HBFo8N1CFUtSIcjwbGovdq
# DATA 4TBk9/RCYGQ8O8clOTy7W7xsuWL9KEzv/B/WTLOAapGWMZ6LLmpXKbKxM8SEBdKUAkzhRDunEy0VwkTvB4yXdQwXCSQ21I69fX2f
# DATA Pwp+fbUo6sWkzJwAuZy5CRE5uDNHuiPNI+5A04OgdE+CEwa1IJLGnJEoGXlna5MP8n99uG0jnLiaFh9QcKdY0NEn6ow4HD8GyPqB
# DATA 9dEndPSaSAjgRpIEMwmj9mAqHnXeLr1Xf1RT/5Yv1ys30FnO7Xh50e90eWePTqYjdauct0clzFjm1a09Y2uwc9Q14pWOlVpoVe7t
# DATA frSjdti9rdbd+7ub3zVrEs/SlrtNID30AkeRaEM8+eT/397XNrdxXWnOZ/6KjjzeBiQABClKTuBgHIqCZSYUySUpOx4QQYFAk0QM
# DATA Ahg0IImRuBXbk52knEpqUvtpq2amZndrPytOnMh27PwF8h/tebu37+2+3QAhypvJCIlFoF/u67nnnntenhPdT0s/mdKAZDVR3je1
# DATA +8TfczyamWOO+XT0sHCqfHqGtUu5qhEBS+fZoZYvF+Jd0c00UrTJDjBPUru00l2pDfnoJZ0iA99siZpmMTj9BRmZ7FyXSWNi3AgV
# DATA 39LOXobZZX4zyqUNNllml5eU1e81ZEuckjMMYBbhS+/0TTqVGPEuKlwjDDCAmO8Oej2sz2OLd2nhP7xRwmVyuTpj19Wbr+Y0n12N
# DATA scuyRV25cSZ5XLh+PffEj9tqFJTztN2JWGZyj4zOBOg9MM3kM3u2x/mNQ3MovjNNOS89D5bTa29a4kbTa+9yBpbLG25exJ4ws1Y9
# DATA mZUuQz+c9PlPargtg459L8tCJIVryw+VM/vradasSw14ig3MwDt/AevOfHYOlWlPaomlBM7MW3cVBox5c9q9Mn5kGD++6YR/qYzO
# DATA zPfHdDUZ2SqwmKAfBaelwEzyU6kAMxIfoNwX4mq0XLy6fBQgZ/hFu5TbyRMJoRVoJR77bFbZa2Lw+LTqK+QNfzq0xox4GgKc4AJN
# DATA WLiqM+NMQy/qCUvTbuOczBAWi4zYHodSq98+HoymexneXd+prSHEAjk51O5v770fBfp1Vfz6JZTtltlAS3UK88DoDIj8hGCWN1BD
# DATA qZ4XaDMp89GrVAdxaNLRTqKzxWrsbP3QKJRJ0oi/VsG07shWuy3VyO1a9TReXqrm5v7qekKXRobV2SFGWdXb7Y35nNRDfVoVCigJ
# DATA 4LE6eMosktpdzagKRCWTjzFFgoyZPIWxIzQ1pxdedSsyZ07BA8DMfR+oo1n74fru3q6fWIqsuhFWk656YfZn6V26h1b3k1RuuqSu
# DATA RkEfo0B4otcatY+7DwM52UpZ5BfqDfrt4E2VwN1QRb/mTfoU2R9ENXYxrUmrL4ECAWr7ObPJwQiXfeSFKvWlqWR0wy7pA2wUPZOO
# DATA JsEWsqP4Y1eQ7ZnYBo5i5oV+ikMp0D6hBm1RHeEnlrdS9Hx21wuMF9UcfGCMRPRy+xhezNF7+QyQaivXGDwiWwe0ddhrtQMnDnX1
# DATA eDweVhYjJPLKzTLHYrkexmlWy6A0inBsXTqkpAm1YLbbQkx5YgeYGuFzFXT9AZoPi+g4OAw4ehDEVFKfVLy65a+gq8o3bB8Mf0jA
# DATA NfD8ob+0/EapDP9bqjzBq2cUw+HHX+ixKaGCbbPQDFjcKo4GvTT/h3hJg6Mjjrx94ndGXUrny1a0otIBDYZKf/jEP2k9LqJtGB9a
# DATA Kp+wDvJxUfrr3/TP4hVwUGT7OGh/QCWMYeywq/7a/bskXQLVEU+lfw8DNERck3mPBgNHYZGsgSArL3KZ1/Il4D793Kj6dyoemlKK
# DATA jkqDD94qV5by+VKb7Bq5fOwJuCWh/VAgSDTY9FvE5CXyNroAvA25FFxYWuZoydG4OQxG3QG6evnL5RC6nLa54ojX1WTBMW4q8gQe
# DATA 7firbUJ9oqKwE14uPC3Jeebw7ahpsh3E2yaXlTe/YATo1NOW2oQNpNYbT/Qb0Ioz/RY2CdO74GRFDnHSBSkgalpctkhT1loLKQr8
# DATA UWL2fIFR+UQHDQuwCo2ymABfrCyDdDLs9gN/Bn6g2AoNzL2tu7U7D+7hwycwcl08so3bw2rZpwFUrMD/drnybeJ1Kys3K/Cf8XVx
# DATA 0hkSAatoLReriUaI/JUqrqipymigxckihmhWFvHf6BoPSmVRVMCWZzUPl2oCD1JUkqIIsxy6djaNHbMcVVRyFJwT4pr9l+MaFmNc
# DATA tu9rhYA+ckkiiQEIxD3Uk/Pi6F7eglPgL2cvACGT6q1mKtMy9aCpKv8ZlKed6coEdS6z1ZpOHdTM5rCzeNQNo17acGeCREx5vyuy
# DATA yWPOe6+qE86WVkdHE1yt23Qnp2DZUFfQbMLsNZt5480S0HezJa/kfB19jTTLiMDVuq9V6cUIopgBRMj13GeYmbGcd0SJEZleJqNA
# DATA s+TiZNSTO3IQKCJoNm1eKFHpbVv7+tEpBehFoA3oEFmUgEpiXpMwKCLfiX5xSSwWxePx1S7owhNoZIxMsYjkC09jhGh1m7RfyjnD
# DATA ECxNB3DbucUnYZ5Q7VKTwVpDZI9H1GPV1+6JnSKTi3pMZRruF8p2YgIRuDuIEmjkFou56cmaT8/SH3w6jNCQKHu9HejvpJQ4AgJ5
# DATA VHUmJ8Mw5wS/pnJZuUFfDaxt+m3yyaAfAnk1W2G72xX4YxHje1ktDHxL50v2dnqY9WswA+SmFF1np1EK7H1BDxwTEdW0X1W9WAsK
# DATA tqIL/QRJaRVvT17PhX41ZryLhl6BmE8bYjkq0HdtnOOXUh36HJ2aMhe0rDOoQ4FT6dbOM+FxnpFRXxxYOD5KhqqNx1v0InO0ymBb
# DATA GQ0ysGzjbcGL81cccUgTXMPtHT3jKMgvgzAz26G4e7z3Sm19uVqNRUP613hTDD9brcUyBhKVHT4dVR30L/I5PuJHlXMMvqERz+6u
# DATA 2hSNrL6i609MLDkUdmZdiNnVRhtwJSb6otUiu+rLM6JpTbF2/ATAu3bUTWlWPn2dPPkgOBUHIoq3sqLCnJtt/myOtRNtz0lQn4RJ
# DATA ItkLPZzKOlEvN7IrNESAtGOlQe7Kp/sqZisSv+JdjRB30uZJlWwayRX6UzbJRXhQIOpCw5pkMWo2qUnNJq7DZlNahHMcdo/6EwL9
# DATA y+HXVq+0u35vr7Zzv+BFv995sG0mQefr/CfHBRQ8SRNyvQknsdNIzZJ0fWHZeyEth6tGvJspa6LXCr3ARoCFs2hI6bLjUMDpYgUc
# DATA J85/453/+eKn55+d/+H8K/j3c+/iw4uP4MIz+Pn84r+ff+bh9YuP4LHzr89/f/7F+ZcXv7r4J3gU7//aO/8C7zyjl788f17yzv83
# DATA PPMMint+8RG+/ez891j+xYfWcx7+Hyt+fv7p+TN48quLT7Dyf4RHPj//0lvdXi/C1a+hLKzp2ZvYro8vfoEFwfVP4fuv4NczaEGs
# DATA wc+owVD++R/P/0QvUwGl+DGX9aera2u13d3m26vrGzIg/wZlfQ2N+gz+foGlzdRvqfTP9PLn8DxX6pnFXfySRuSdvb3t3WI0LgUP
# DATA Hv+aevExFPmVfP8lXOfXPoQKf+UevWc4ep45ULHhuPhEdeDP8PNDeAqn6F9g4PgxbOwXuvnWmF18khgziupovg1j1byPgR930Fiz
# DATA /u7qXo2G7v+kTB51ENr9B/yppv0rHAG4iJT3DPvLFg7qHDaCLhmdLN8ul6Hp/0sVq0acfj+DhkOPEw1WxsCo4dTQGIl+ff7bi09g
# DATA bpkGL0OWHjWPBo0G80/Sqt9Sfz+Dr0u3vR9076Q2LEo96WhX2tL5LXz5I7bzY3jueYHuUvVfImE+V7+fyTASAVY81C2HlUXx9wse
# DATA t06GPfLESzSOKFSaZjGL/8E1QKuAVH+HxGO3jCr7DEbzY6r4Q3iYyoJ5k1e/lOn68uKXSOnxAohG/0w9+eX5H6GYz2kkWpPxwGzl
# DATA WcyKuHsawg5eQ96r2CC5L6EOitgkamnO/xVKxml6BlzieYJxOFaKTOYfiQJxJf48Y1nD13/2zv8Ac/JTou0vaSa+gKe+AvJ5fv47
# DATA usN1/wrZGZT1BU2vojLgap9AkdAEvAv3gCg/wiCBhb959fn/8hn3QM44fbl1lOFze2WF/sIn9nd5eWXptrom199YWr79N175mxiA
# DATA Caq3oMr/pPN/7dq1tWA05lDcwBMfIBV7ZNmWWX8XPPJ2lKFL+VFxFAIF7XZP6MyoNK7qNxfE+jJ1Dc8o6vsgXCAIQrSY9LoHnlxG
# DATA AV49MtKFRVKjvnKqvwKXHKIMv8AFyoFAFcjn1YJlN2ryxbDg0alBFMkYuRWGvdx1FL4LBHIpYZmHrW4Pz0bCh6s+CBufIRsEdvZT
# DATA YnmK3W3XQNhG5gps9fnFPwpDRW4s7FBELpQHaG/4Gh+EzY+lMktMe078FKr4CIuCp76g3fuZH0cmN2Rq6Hyu7ktP0M0P+4KJ/DA1
# DATA VhW7BAei1nCMvRlMxniRDXoa1fiW4VVCONKse28POllZxGIj5EBSLjHGkfIVjCiwOWx1R7njQTgWOIfoVoGTx5hTF1Z97W7Hzk3q
# DATA TbFpwNvo+tV9yAE4dCA0isyLSgQKNhDT6cxkvWpHyKGPWJvw8mDzHTJwFf329/v7o/2yP1UNymcSkm2QSGQXViIkSA0eyWsoH6LE
# DATA LBIiiBd0JHh+8TMkBpQhP6VXgEqSeYaHBpIA9ioZAr5UXl7xrtOfqQ3+9yTtye4vFKwbj1KGajz0ragkSxLWnpvSI4gVP0f50bvf
# DATA vaNTve3AqZwcjbxwEGdHOPXBP0zQ+wR9r9FDdRIKZqlCsUX7AtJQSRNAkwkd5pi+oZMkXOXj/8EpKtXzeqKtqxwrInzAf3yr/B0y
# DATA ePUH6EaA38j1IeiT2eLbt1fIf4UYha5W9WoLStnd3VDBHKHXoYxFhGnZDSlGE11xxoKb/iYsE1TFwET2fxKMBgrVnmM35HlesTph
# DATA 0YHfGQQhx7eby8ZXfoZTe4JrB35Fi8/uSza6iOuT5JROMkKh8PfIFpGKYuL373AtIG3xoe1ZtmfkVZSv+QCOA61yx16Rs7hQNGZk
# DATA b7DuKVhn26ZylXP14vN0ibmyj7l41EEhno+SeJr9FHcpY0SBG8CVZ3TKeZY4fszAKb+RVkhCIZYlwh6TAIoPaHSz5Af5zVvkT5QR
# DATA 6TUP50mF4YfewWB87O3srtKCra3d3V19EzYoSZFygh54dPdk0Jn0uoSZYrCr4eSg120jom2CCOAWsDGLHlz8RpiZo6Sheh1uKXoa
# DATA tjDVBZtYw7CiylT8MvLnNRr3rWqsksxV+W8JdUO0b+B2ANPwNcg+H5Gw85FSf5FOziX0XHys3BzRJOocqGi1kPW6w5b42FiVOgEK
# DATA MrlEKhsoq0SP4SQ3x4NmCA/2O2GOKlTB7VVODrXUwDh4RRil/uBRTtFGaTJu50v4C1pxMsxN4V0k733hkWrtcx4FOcW7BD88jv8C
# DATA D+RfsQbz2cU/kdbhw4tf21lwHHugjtEYnk4XuAzrUprsFW2r84lxMp0BmosUhkQsZmLRxzJCjYdjPDwzgs/5/+ShI5Hpd9SoMCZ7
# DATA EUfRspchZGltDgzwh0DDX5Li43M/0XSHy63LydZ4IeFmi2OGdJ3zEcGhfQw7TmkYnLCNpvsQEzbiTxFQep0oH5HpYkGlGBYKzkOo
# DATA al3E2xb0xqXy1J7/X9JnfUab62eWoIcCoC3PmiJhfEzh9T/R4UaPKsmJhjwLHVQI2UNLPuNWJ4NyHaYJGx8OBUgYoJ/AmqdBYs4Q
# DATA 63NrPDjptqWu+MDpcixzh1g4Zq8WuhaP6syaJQOxjsoKU4LShipOTLIY2aSXHqmZ6PYw1s94kJf9MPn9qOdVMhyV+JJR5TApjhzQ
# DATA YZ2gSnOIa7xKwW3smU4wtIfdx1W/NO6FRd8xmwSXOwhLhx3k/DmzEv/RgU+2I2DpQesknjUJr4lxMNEx44nD3iQ8jkXZYX3hab+d
# DATA U89AH/qDnBEsPQi1yztPOsWQ87rEQMCe0QXibiQxps6V8GgNmxbmToLx8aBTEJiBGAKbmaKaH7CCt1QmauNEiFeSh8LbN7+94riN
# DATA /Mz7L155UH7jjSwee3dz12xzBXgBbOV/0PYM4+iH3HR9c10zDo/MAMocQmzhNpypYphTpiqpxEAm4s4XQUopDC3zVWYduNP3j3J+
# DATA vdMPG/t9/wZ10/CAUPMV9CgjMSZB0K6h8I72gwtGJ90xR7bnnuCdZrs3mHQOey00mw+7bFn2KR6f540t/fohSfjC7x61B/yavKWn
# DATA LuVVlQKA28kJB+KNCE4kyY2jcSgGGokIzN4YxWp5yKgJJT/9tJFs+SG5fMCIIouTHyP5ofM3cCElTtg+JVbq/DdIHNo2y1QE28XF
# DATA z1iA/5JsubT//FZsHF/JgQ5osKjVZ8/YWImP+DFkMBPuTfVV0G9mFin+hUj6s/M/QmVolPowsrF9TBuesRis+oXdzROhY7FdLg0j
# DATA YEs/HnT7uUP/yQdnaCJ/iE7w7O5RsIZfZXcoEawe5V4VXoMO3YbURhRU8BTbmUEQdCnhbCpGQ5ftYEi1GPGVFmyVAQ1YurFfbNz4
# DATA XnSlZIIHNp4sFxDTikqbLr6kqWx50UQ8/Rg4A/kQ+xJ/wK31b9DfGz6FGhDVq46YaUJptnthhA5p77lR4YnH1dfFh63RYq97EKWC
# DATA XYTLi5ZcmPaQISuqPDGai3LVN9RM3aD4Cv8GvHbDT4ZZ2FFaRt6ZuLbD6BuUHLI6enbtScwPy7tRJZZyA7kYUzcVm5+1ucWpiXMM
# DATA RyHzrGHGoCjXc14jeJobqVQvsBCo9ChFm4OEozwarfZJUKwz8TbqGvESkXikwOm8Jka0wHXIq+FPeE78iJjdnyxmJ21isYAbmwzf
# DATA jjTa9ESmRvsSi0nzQDIw/56OqM+91bX7Na3uDcmuDZvZMGjDARET2ZPO5HHQ3qWkJv8wGaAPoYc6kw75E7bHrJsJj4NeT91n/QkI
# DATA gq0h72LUkSgEcX8faWgfPr4RmHiNL14zr72O115/XVpo0AcnJ5IGy18/v6ho4YavYvTsBJl+/UG/OwZZ464RbbAT2Ia0vY1d84y8
# DATA 3189BFmmKgFVxQGKiIF4sXkSjSy17fffa+Fu4XyWeJPVGAl7gfbsobM+CEnh8QCee3C/FX5QLYN0t9/Xo1+9BoyOx/SGf20flUSy
# DATA Ud1eWZljgGjxzDQ8amCMQYF1BYPW6mGf6ntYEry11V9rgRzeaY2q14vwP698s7B0q1IuV5BPWV3fAcKCffMnQedu0Gud7gbt6s3b
# DATA +NQ2KuVDPAxUx7DHUvnrbNls8OgGnTunVWp8qAc2NhaO8JO5Ik9mCjpRUA0cLTIklZ4pZ2gcAYpxQPgQVu+Nj3Uo5EhJsoY/aN0I
# DATA lzC10vBT9IaWvyjv6hQswpm+rFCMUJD4dGQWfqVOm7kOhslIixvaGpe8qWRaiU2sKgDN5JMW55+MaFDib6HSaugO34i5fOoBN1yF
# DATA 49quVklZl1slS9/VKpHGq2UHSmObTD/ThEvw8NRyTFaquunVmO7gl6vTICGjauME2iopYRBKllNoq2SK0O6CY9GfLGiaPRFR0yx/
# DATA 7m4weVesxKw4bnrThq+8E7qccQWr0YA2ZjfiEqMWJs+KKSQj686WRF/zfhAEQ7JUKnggT23FdOLGnM79dm+CaNceemYcDMZ+6PUw
# DATA 2F8OJGEpmSW77o97KlBTlmXFGExrNXNApXTKNIaXIqEgL0veehbXpfmMnS6RNwIZJgvj0a1sYkHXSMI77oWOfN4iv6CfEuOhGT0h
# DATA 2cW6i212QSg5ZRY2L3x98TM+Pl78Mztm0AGTjPN4wISdOZYChl29ocq61ZhG/k3zFrakMYOr9lwe1Lh1J5ypLcXIXA7WaH3/MeOB
# DATA UAJPUZGxSAYvP+ziccXgB1HKOQXwEXi9wVEp5hbvn/+r4dgCI1qBA5ThukiId1HuySCeGF10u77pEiM+ieRis765XogcKuD/Ym7H
# DATA qFjsSNVIpZXuV7n0n9ELcXL4qHk0aY06L9ELMNv/b2n51u1l2/9vqXxzqfzK/+8b8v/bC9C23Rp1e4inEKKhBfNGCszPg7ffAymW
# DATA sqnKdlRg/Xu3z0lH0RIx4gTDp1kugIft/rh3CX+/8Hgy7uoXOCblch6A8huhgZSCixx2OIpqit8cu/25veNg8485yq3cyva6CPoP
# DATA q0+uXx+EJYkehP11Y625ukFe8WuGwneqn90OezQa+xj6iP2erZoXH+JpOwpyeK5sbhRxAf/+Gi/CKzCtb3oOfnoIQtcjhIE6/xR9
# DATA ZChk4OOLX/lTffhgzJrGdqjyQSiEv+MumSmNQd4m240FXmUD6Yr1Gt8sPWoBg1aDfWulPAteJb85RmV1H1sUsX6rnuhRq5KlsiG8
# DATA cD1G4/f4qdrjoQ0GFxX2QbfXi+M0RrVkmdNsQxqfMiMFk7LjpGqnk/SRrZ9GUyxZXz8iHTqSw5c6BgjIJLJwv4AlD7YZpyUPjWps
# DATA /jbLpx7PZu376zL2jYKDwWDcVOw0B8NWEBVZewzHI1hkINEMMP17VVQuCdVvEcdalYAS0KTfHVdTFTSJFwl+NVJlRZTH9V4J7X1h
# DATA +WHMSIFS/0zuFSet0QekWeeXGFmFASl80TzuERgdDHeRHLx+PDiABQ6dRui74eARvNQbhCEOX6/7QaAUlXAWG49a/bCL2x4dLOOa
# DATA RxjFF1c7CifAqSukqchoomgRxnZvaAaMmtIhYnu0qtDK2Y5pIDpdzso5Pq6RHwVBraFkziOY57RG+/1UvaFdoqk5RMw2GRUo5Jon
# DATA OVNhL2wd9AJDy7g9CMfVxUk4Wjzo9hdHJ17x0Es0w6omTUVHqEvFCR6ADDWdoa0kj3hjQfmcQhvIHo/6SiWWeIqb7PNaKlGea2ue
# DATA uJWYlYGEJlWr8ueRrYwDaStCnFNYAQnlQUdtkAWPA4OhaRKGEMDwwTlcfj067raPqywzlehHQUllZuIoeJ2B+yj7EEtDspVSaXBT
# DATA fUOMQ3tPZxjew0fwENWQ8+GHbWaAC4kdXAq0t3pxaK7yWBOfU2g0jaQ/Ht0okStfiNsB5/mYhJhXmofcslBk1CvtzCjRUZ6Lt/27
# DATA S6QSx6evJeD49+IjBTztTSU9GxF3f+Zw3/OvZAyVLUQPr1wowhhZjwBRxh+CS/ZMqMJEQ6KfmtItCWKMcW3lKP0pdYtFS30RHTfj
# DATA scM8FtrxI9mRTjdsjU6ayH/Rg0JIlYjO3gPzrk1QEKFhMXqkaXNsfU5oUGH9q8BjVPkqlRjKFqhzQxWGEoJL3qqHchxwMAVCOkJQ
# DATA U/LjRVVFz+uKA77BMjpxRNn2oNcTEKNikXZjahvz9mIR2A/TXJVgFyNGB/doh8GsHUOgntPqars9GbXaZLtYQm0ZL5woG7XiVI28
# DATA MzOFWmnGCzgRxhvT1k9CtjE0mtRYOPedwHg9Og76guUuwWOtbs/QXLobY7feNKlmcIkZV3EayUfLltzCxQv5p7B4n2OE66c2bZ9/
# DATA 9qbH/knk0/y5ssCmijDED+SGuvg1FoFmUnSKJg9IC+tVr4xc3h4vc0sSfC5aA4gCp206Lx0HbUa0L+e7Qks+niHggF3VLdqpIYr0
# DATA 3drOTABbUgx3KSzJz/pSpaHxntS1ylID1a4IYu83WI9o3jdZpipVWCYHi0kx5UbMbD5N9I2c3p6d/5Yc3JGKkpbxL7SWP59w4/MX
# DATA YdpjAjr6EJR6g/YHiXMZOsITTEhfTpDwa6u5tlNb3fOe8o+du+/tqO+bW29vbWxsvWdJKgyOD2LjaDJEuBmFAXI4wtNLzLGVoOhj
# DATA ACPrm3smvkg23kgSc0Sh7EdvNNfvbcaVtj8ITg8GIB6tq5bm8tmwJ5dqlRsFxRgVMXxPP5biNBljhgowOG3CxRz+U5ArmO+uWfth
# DATA hmY6IQtGoF8vbmFIDGYlvSG+FmJIwIH/KJz1zXT+9zUBHlz8jCJumFe6tVG+bfYwl5Nh+LicPSPR/mkmB7NWbXQwbRcUzPsLUqt9
# DATA kqpDc3RQSRT+X5qNgfPAFFtH6Ir4kkwAmfr/pfKt2ys34/r/N8qv4v+/kc9r39IHb8xAPTwdHw/6NxeuXbu2Iam7MdEOU4lyUivh
# DATA OpFU35zGmxIIEOQapg0YDSZHxyQRaql5ZsPAcStEg4D+edJqs6UAsV1Ij4FbDt9EvS+Cr+xgTHA4fgdYY+8q4AVAhNTf0dVqzNWm
# DATA Gx+QZ1jWBqpsMupBXaURt07VKY0t4G3cOBZ0A5j3GLVEDg+E/+u8I5DiC5ydmgzqYq9vkqs/SHJGCoKFtY11PDHRnFNudla5KAnD
# DATA X1jb2twDQay2g3BaeztbG/S4LYagMnU06PkLu7Wdd9fXavYZTIDgiGK0GnHhweb6XnNna2svkm1czmIL2w92MEMG5vlMKbP4cAlq
# DATA 3lu9V9ulECnSYkjylM7gUZ8UORQpxTkcBeqVk0r4kjnzVF5AZ45uH6ZSgGG7h+pOG8i5Dy/kF+6v/rC5sXWveef9ParSCJvXalvO
# DATA 0DQaHMFYh5J8ZqRmGggKcQoJLL7gBQ+j8BhYFdsYPhkeewdoYoN1BOMw5GfCgiTPUHKpEqNDOia3HnlChioSHNcYn9+Y4qqo1Gx2
# DATA MaEiXRBlFB+57fwVVppS8nDB5aNRqWXGF0VtYmTrE+2MuHBAfSqLtWqE0j9ED6UpbIzyjgIVCC0TjVnscUyinDmSoopnnbHa8YgZ
# DATA dJKamwdEN8nkOfd2aru7ttgd6zCnIFHzSioF1a9YSsv+ANViFAGK/+Qc529VjDXCkdVAJB9EF98cjN9GcohFkxkFPPFplMg/hxNX
# DATA 0F9SpwadVcTRhhbhiZooCdHKCYhcoFxCA64d1snD7oB0caqCupTe0OgF+BIwC1hSAWV5QR4EhBoqbcjJ4GHAXk1AsGg+jHyhcOE9
# DATA Avky1EgFPKclNCA/zlFNGEFrXVWNyid7Xzd60airB9H16aT1OFcu0FQU432JRqaRTxRZYs7CbanKiNqvVaFUSQWPy5jmEJ3SMERh
# DATA /3G5XNx/vHS4//iNQ/jyncOGZCSjZ/NwBl0uNxbsTsjEYLtzjqs3vPoTvxXNI5WEUPXMRPhB+E1/zxr5enF5pRKvQ5L8YaehGiho
# DATA wZUYj1IGyjsun1YuJc7d2L+rEmM4SV5gO8bTcwlNrTuTqnO9TF+gMZ5nLFT7hKHPFKaHlfKmyqe30b3SiWzheoyKY+tJay+GvUCi
# DATA raIBGx4TFLl4f8ojvgww7vKc/1o3xGa9Sa6asHIjoj/6hmeyeNlkoWtQXRhPzEo6ArX8cJOWIq1FGfffQzxUZurAuaO36bSuLvO4
# DATA 1WncKg1nFsRoCMgdJSfLPZyc5HShdSqwkVk2MIfcVB6RT2byJOcM3YiqV644XT7icyWJtnpkUkTLi/aZ63TDYa916rUooq6F+Q+8
# DATA a2VPwAauleL+B9kka3gFJjLFgqhqkHK0eSQIVG0k6zhWmBaJyPqGt6RurMHQI9/pBf0cj6srSwaR7u6YslZYz0peOCF/OmBTFfGs
# DATA ScGozfxtqVx2vMMEwI27Ts8smrXEmxQa26KxZKLLnOJCMcuKm4XGCg16rWGIaURotuAliypzRj2HQA7hMVfE8tAjJEJnS2j7yid6
# DATA gBHhJ9iQHUVdRr3qkrndJ7eUM2Dn7R6QgiUPGU6WSlkMxMKMXyF89AZHwvTF00H2XExJipmAHAkvFVehtBLJlIuzRleu98nxXiN4
# DATA QXFRKTPkOrtcdjORAc2ULjr8/rDjVq++t7O1ufG+0qlaytbaD9c2MpWtCYQCLYohn0wmoazEGat+HoNysfF4SrCiz+JTFU1eieGK
# DATA VNilvmzl72S/3+gOB487AAfUM1Z+2jRUBBiRdg8zBB924n5QBpeKVKuHHYnrT9Jlk6g7xwcgOVthnMc4CgKVwxFLOzm/jjICp60b
# DATA jw5pB/dff7/4+knx9c7e6+9UXr9feX3373127SsdnfAeT2JEg7wS+ByCGanwF1fFXhK+jqj1J+PD4rcxGhV7HlZ9cfNQMoi0SXke
# DATA JbslaExCaYGxPm2imYkqV7e3a5t346SY6mClhxs1qtzSStwBPmX8fUGZZtuQqFpLWjmNuaq0ZwffzM9aMpzAMUwSEffwyJRNYQYT
# DATA 47RuCt0qwcrUskgdYhqcVE4oDPCbHSlZIHjL4rPCr7KHxhRneYSU0sToHbm7RRafK+Ls1jkcNSoPNlffhWFYvbNR81NZsGpLcmqm
# DATA mb527pqrQNF99HvzDppeZnM0HClYEQp6smf5BHiAQCCR3yBiZvBzDr/BmBNKabe5vrtTu5dThSisjdQolhlGMToBTPrtFh80zPIF
# DATA 6sNSbNlGOW59GAQfKIEm8X7Rfj/WRVRPVVU5eNrI2U87aDTVgJPdYw4Gphc1hoPqt1kStgf+RWPymJzecgfEs+vLfGDRT9Qr+NgI
# DATA pLaOPIICMD+Ert9SjoCHpbP6jNYE/Y6cZHCQMZlrbuQX8YOMGhENvMZ1wZ33flB7n2757HkejfNBcNTt91MKulO7t745c1GIXsBt
# DATA wi2fAD2i0lH5RjfZ0wLkgu9Gd9W1GL3KQPn1ndrd1bW92l3PaEOD9mB4oi7lIrZTXtQXcPwBHhVGmFbWmpe7ChAqeY61DFp8eq1z
# DATA rhB1/L6sAkAfn8zUxlXviaqRE2MWNGeUtKfqpyOdnYg5nOnP4Knqkjr0o1YZq6L8hOpm6ag3OMj515VSo165vYL6InpIP+WsOQQJ
# DATA JfH2zeUIOoyrRPFTKs/QJhCIi61KoHcSrM4ws9I7fOQxxHja1h38zhhvdCNhswYVUTdeb+TzV35QPrQS1xvSeDfIGhLnhuTKRzzX
# DATA 9vQiW1TarpO6X2VsQ4LPMe72J8GCI9DFyBCdzv9nZJ/m6YjRUok2S8ic8VwE3O5H++H13FuV4DEax/bDG/m3cgIJ02wY6DGN63l4
# DATA sIoPl67n/9ZOCo3GmtL9fMWt84k4K3Ofp0gnj4DUnxJfeSpS3tMoMPIpYiy99UFw+hS3TFSSYczy07DVGz/thAQdgJ2pLzWo5vWU
# DATA UVZLjB9ebhgeb5QBe//avu/nna9Cw1EhQiXkvb+reiuV1AClGE/ld+JrKiFIJhYMF0MoIgPUZuSecPsJ/Ym+4S3h7g6+wGyANqBY
# DATA 088IM7IKVwsK6YVP9MZa5P0G/2ifeq6rYGxCDRWDItu4UuHn3uqe5HOtyfgYlvhPSJUIhFKvVBtMXAdAAMHoKUxkt51HGtvfRUya
# DATA kb+/ZJRtbqrxGnypAwqrXwOe9db+gUWccH23trZT23u6vbq7+97Wzt2nlNHlqWybzbdg33wKD9ytbe6tr248Xd1e52urD/be2dpZ
# DATA //tVzHyUjxcqlenO5Os/2h/t9xs3fP9yHZguVNT3w/3dxvW3oNZposzTv837hVThIKsZ+wfB6feNTpoQUGm/D3ybBrLKzyEsD7ze
# DATA kL9Qxo1SsXG9sriIQxcufq/SuFHhb40b30uM4feyW/946WC/Xi8X32pcr3vFRfj3e8X/pqxFifcUpFf7uDVqtTHAmoB59C9YT/Qk
# DATA KkjNixgfMfZRbgMmFb1Ni+nmssc+jtaNb1W9peU3skRWLdDdleOiJ3kxQ476boVjRnIveXvHgVbYWqo71lSi5whjtZNbRQlh+EQe
# DATA tLXU6uQHR2H1lbPjjlk3jG8g5IhqLF5S38/kcNtDxN5xUzuiNMVPJRdZ4HfYCO6dTMbofext0CuEQV/AdvaBHY2pweg9wU4C8LM1
# DATA ZuB5b9w6Mkzvw0HYlaNyFO3JIs9O7f7m6hpmldqpbW/tru9t7bzPuXfH45NWf1Gj3hR1c+P2s1RsNKDzxdhvpE3dnNmM4ju1jdrq
# DATA bk1Heyqznjit5CLFk69yLcFOVzoCqWRygC61i1Tj4pOo4rNF5Rm0yHPxlnbraJLrRvVJ3Ev/zHCCZ5yysPrEX23jPoRqEXTgwIAU
# DATA xEd92O9I9TdIoi1gdnQot7gmBsIKCuTFNl7zHTG6/gOgwuLqkeSejqbAPEf4Z/ym4fgp3js57eRhpMxAIWwUhMNBPwwSJ1C5zjLR
# DATA 8q3b4kmCR0w917j9weNoFY+emGsCaeRtNBMs2CQqYxvW+WsR9XIeioGlQH2kYgTVo3VESq2IknOxWuEJ2frFVyRG5g/3O8DT1T/I
# DATA J1tHsWjNkV1nZ9Q6RFtLN6TyKH1l4qEh7Ogq/bP15Dwdl7wO2Bf0QrfCvuSaMCT1JIs3lZSZMAUi96hYgwJbLv3NvwXDY5Y8pRPv
# DATA 1nZ2QWrQyrcRnbvHE2DduZPWEBFVpTwFeo7JuiKUpP5pDl9COl1aeWPl2zdvr7zBlgy8CjsRFTlPW2TsuEk3vFy5kId1kFvxirQ6
# DATA uNwobNZyp6lkWmzcxy6nTzdpwkcpgMKi8ZMAYVrOiJ17y1rFhCutUHVnGobdPcw1KFQl8r+xei1EfjfRzL54zbpkwKkMGVbxpLgU
# DATA paJSmvj5gwfrd+VVEi/o64wr678+qO3upbcrhEtD0w2lqSLmT2DXUb8kkayGAq5M8X4TBwiHE9iCgbsNv20TGfQ5S/c0u0L8webu
# DATA 6tu15vbq3ju+1aLZ7Jrq4YRVM+nVF42ZpqRosAxoVr5G2uM4Glb0fDoglkEkuqgCqanilkyjIv29Xm7ElH4cLEpmOTMFt34jz3x9
# DATA dXu7yUcpEqtdGF/o6Vz1uCcCn2Xqk7SixuqbEUKBeghb5fqjqNYqHiEOEeHzye2VM6VpEA1DsktKEUAwuZwHyACQFTbCT6Pe9eZy
# DATA JhHdX9/dXd+8pwZAdmXUUiDm60mrXeoHj6Q4Df9b8MTrtqDcr0vhcQskD5LGOt0jFP3yDt+xdLovgPjOStcKV38WQ/FWBSFN5cyF
# DATA m0/kMZAZMqS+0EQQFBdjjQxeV4CD6B5IodrRzKHzCqGOiSM7cBLBBMz5Dwe9yUmAjsB1y0VQe0fW6XVWRdE3TN7EJXYPncqVnLEE
# DATA 6ElhzpzHCS8oGYlAE8n1K+GAjSxm1tK1AiXpxq0aqzbyip8HqWS5kW8Ymh69DGH2Tod48PIPun0T4pEB4YTZ5CPAx0qySnGvbmKc
# DATA ANxHVnW24PJeML0McKuoq4Y0XNGbFr1LVc37Ww8297DitzfW1/YcydCk+JjhjmZP6b1UrS5Kt7cWhQhsVKCGhPTuppe0zk+RlqQ8
# DATA 5UVcQeLTV2G5FH3ayUUQZqXbITgCcbKskDn3snmfZOreZYFUFeL5pImVn2dJwFcE3A06TdlIjUTzyh6dT0W1kIDt3BTMV1QSwBEf
# DATA CRvTEXs55i+kN1BunQrdIo6FGwOkSALehl1UTJgYtzoARoJfvOIdMr0bXePoCle/yBGEI2LpJXN08BbpOBKNQvAOrHrQL4pnwn5f
# DATA rhEsrQ3HOzvWhYt0o8iLRU8CNgoSfB6f2kTqyAhbIAmVUWD8CEMEyX5dY2j4xWJ/8Ai+SGsuXdKIRyq1BHUoIIAUkGBRJz8+FYHR
# DATA kFwMDRAC4CLmWQ851qnOewq8kDa1NxXdYUxnq+ONETuGt9WgBVs2DbfWAaWKmDrxQPrGmZGGwBI1lWz6QgKmwtbkuhyMKorLiKRH
# DATA E+w1UzBT12TEYR8ITLkxS1yTht1c9r5btQWgqrdS/s5tjVl+HNkURDfKOMb7I4LYIX0Quuf7jfxfkNykUjYkZSTto0kaqYqOyW42
# DATA u7Bim01oQu+QbctmxDJcLKWTnX4kOuJEb5jnHF0diVxUV9IR3jhHmGXG9z2jsNbDQNqdUE1Yw5JVnrwbi0+IQtZZX9pJtpkM2tV4
# DATA q+MWd0kZH/N276rQLoGeRSEAvbQ5wkkM/562m/NTwFpVa9zwExbhbW7tNdc34SC+gd5gUdVKTcQl13357YDpSDwRDQs6dAnBKDUl
# DATA ugGY5+Hp8WIadw6d6V0Zp9QBkwaWKSfhA5AZI3YFnk7KPuCpaVH623jIFgyJnwFKnNRvDCUYKEUR5+vD3vIKph/Bx2dz3XKrO+KD
# DATA mrracj5WRf2jqYmHubgHX4biZU9ArGHZsyB0bLkh6kVq+CJGdE2+LMmlHgF5xiJnSz1KHGEUm7f8rjEhDjsWYBExR6a4kwd+ECxu
# DATA trnBousgrlNIl3uGZJagTDsOiMIcYcwmAR3AVMAjH/CM+COvGL1rBhKUUfH4xnI5JU4F35G4N6qxquInxRejChS6V9vZebC9Z3Em
# DATA 3WTqGZTCsOMgQVV0OxAp3EwsYBIedMVMaiDd1ecOsocdoWrGjwGMTw+QdDdNB0xZxsWhBKfwnJ8Z21UyvFqYaPu41U9yT9IZEwEQ
# DATA sgebEFBh3GozJo6Tw6ibpDM1GGdaMFeWXLd9Fx0E7jzYfT/h/3nqCqRi7+FkN0uIeHkM4lv3J4G5ArnfeddkuEq5S3/SXDrTO2K4
# DATA OrNPJ/som4u+yc6GPB3MmTUt6U3usjtbFKqqg4vV+UKhLBlHDpDZj0atTjDD3p7O4YnhODkVdI2UEOb4c0dBohg8ana6IeGWWVBL
# DATA iY5gCKFqJ7ELrJBJ66TVh+I6bPMiYp3aj+3Ve7Xm/fV7O+RiQt1Z37F4QuoawJ8pK4BvvVT6F2/ymXfO6YvHUAe6YrhT4nOSe281
# DATA Y+91vhyxTNq49c90r65LixwxBqHqn96xOTYsu4DYrvXdjF3rUvM/+46hHdni8hdvFBhQx2H20TxUTNZjTG4lErYjfV00KmYsojEm
# DATA cb2bvSYdEdux/BqpFJuiSmEsxkykQtGpFQnmDcEADQBDE5rjyJKy3VpIeE+DGEaqLS5Q3xD0pfutx6gEQxrAB+LqOXrpDip/SCmX
# DATA Wp+A1OGuEol9BZFOMVNWMJL68UK34ytGC5dQdND7iaVdshw9XMSWmxOryiK8KYIZHBd39po6gkjkpWoy1GnB7e6pd5YZRXXHgyO/
# DATA KCefYuPJzdtn+/KgK6rrEiScssStDscCTVQwFALU2sICTrIlK8wpIFz5ifBSrHnuTSy2KecrUw6YyW1slrMjG/0TIAaoHxGmlyaC
# DATA WpfRPTCmllIxbbkZqTQfL7DZHgUS/UQSyXRmydF5hIQSBfwZ6wVz24gb4mwLIknddruQpbhZQF0fgxqC6gS/8w6BJDXCkBaNWrtV
# DATA c/iinUvDfRtTaIgaefex74pFVz36kfyqxiBqS8Mlh1yJxPtCku+VnyNeSHxzbR5aDHsRnsyOUY4IV502ngFb62sb61HfkulXecdV
# DATA qkrCtUGfUL+RMZvkDyEF81ymlUtr0lQu6O8N904Yk42uc9IXt0xwig4FOECdbr9qvHm39u7mg40NuoNygVp/nG9K/3SJEG8slctu
# DATA GTxjWa9t3d/eqO3Rzm8v7dnoIYKWUfJElCn9knFU80k43UOTCbrJSQLkGSZg+hCpcHn4rkSQuQQrWu9b2zVZ706BQziTAerRcOAB
# DATA zbDGLGvLJKHPzFSru7F/HAetFJAR0g3eLscT11A+gCZrN6WfrK63108SeD2hcxdxyi7EHpoWJTWsTjH2dkNBR7cPK9iERrSSbuWN
# DATA jEkEzuNUumGNSYJDfJ4OiEEenwoigJ5e0IIWIpzZwWjwKMTkxKK1QOgZpIBx0Dstubllmjok9cCffnMmK0u64GaRh8MSA8NlTH0l
# DATA 043EWkUCWy/eKTNokVGbr5ZN1SDUfHad1GWyItq7UzKP02Q0kshDfCcyC14yRDSfVqxTl3z9uuS89FsPofPk5lDRL4lruTjX6CZF
# DATA bjfyYPIgq3HN4KE4CJshY/GgnJlmv7Y692CyqXioHBuYNxLUxnZmSuTYbOa6/X7gCsql6xQnKnAH7CqtHK3jNlzBASXA8kIShNwC
# DATA zImD5OCA3nDILU7RPY6wHbUzhrMNteUIUwrHhoUL4/7mnXymVswpsKs8ZFgxiFrrWylaJnv8Mnc3a5gtqnM0Knm6kbl8TD4DVFbB
# DATA u950B7hGVV26xVL/Bp0vrQ1Na+mVr0Py7M13muTKXzBO4lEsBTmaFFKP5vNrnVPULtPYq9uQPU2Xa2koXkifOaelPauBqY2bhi44
# DATA Vwe0YxPPOrrzqNmOM+zZqkL3ic3ae7WdWEWveVv9QGPqkqDx4wF0tNVDfhxODg+77S45dmFcn4pRxBAt1DrgqLTgAHfcDQnUJhGK
# DATA bgJ1mRxP0BU0HqWCWajMzsOE2C2Yrjq6QBkol/lKka5I6Y3UEPAXR/bKRvia8cyQUm6G0l17vvKByaVIV66vkbY97s8qrMfdp7kU
# DATA 8amSyDejfk9TdSdU8m4HmEKqGn6qzv6bUc2bWvm/FBX8TDLuVSrkpzgvYcC59dCl1PCZBHxVyndD7z6Pxj2ut07b0V/Y72wmbPIM
# DATA nXW3fzhwaeYlrDQLLjyKRGIEoJnLCI8vqefG+6YJwaVdn0Jy+StRnFMrRHs+nYSvWHHedNvoDbUmU9lRZUZ1HGmaIhW7DFnQYeYr
# DATA anVqjb0rkRsYkn7VGGn3/s1RavGs0QaIwNbWnsTjWFw0ekIEse9v3bH2SROHgIKYm+ubb28134YFLuUhZedT40kcBdQ293beN0sg
# DATA wo45cMWmifd0nKQoh8PCpc7/9vq0czAYxBf13MwVcf5vUeIezu3z6cUnlJfrQ/xpeTCknItUSsBqBszETIpnVm6DAIDtK6qw9Jiu
# DATA XBfeoIjCKkYVzhLyM1VjTbQs6mr67tprv5Omqo5ABiJTItFPytPkmd6JYALqzAv0AnEjIWl3aH7dXTia51jRenjtXZWYJpqmJ/rr
# DATA WUUS2zxRBZ7pEA94Re65F/DZfv+aDgFIb4crq7SxMSU65H03Ogo5681fytVHLUw8IO3UVu++71+mKZc6ls1xPLMc7IUK9ORErPJb
# DATA 1Wj25nR0MkEaHLUTm0pE2aBQoO9MOxnNXf1r3h3WKmN9nGKXcPFPWqd43KKMSy2vHyBu/JCzxER5lkoLU7Wzmp5lQKtuulIqGvWU
# DATA IgMt7FJx6WzwJXHn30TM2MqxhlnlKpirE/PMfXb+5cUvPd5JVas5HcxsfDc6wRy0QLIqGFuXYcVUAI9ubmwaB78ptpxKz/HlikvI
# DATA Pe2XImjB5mjeX9+9v7q39o7/IrMsiZVwkv/1/LfJbKl/pEypmE7v55xC0J8yqVOPa7OYPKeJejGza7aQ5y46VefD9TqynSSdfrJT
# DATA EeWnFh/PnhPL/2Ck0Yk7bE5Pp5PtX+C2DNiJRjAkzsxR5Gz1WYq4PIdhJ1Mb9VKN4K8RSpocPRhDBoMIPdKwd7yDU44xHQ66/XHJ
# DATA 24ZBwEBib5sULYv9YIyHbEepomzA6NRBgc43UIfXHgwxr5lWdHa6raP+IBx326jCHA94f2mrtOhzmexT7PFNE8J+djWosRymmr7m
# DATA 5kUJ8mffZqmZcTiiTWmm8PoUnvZVKmNTScsWrpKeE7RMimueFArA331/d692v7m9uvYDzJiiPJvgILj9YM/P6qkzb6qxBtZo59m2
# DATA l0G/wwQQM9K/cSurJhr/aRlbjW1KJWyVU69TYTWXek8GLh7wFkuEPp9/yEwSFB6nlOL9pBvCIBzZ4D8JlVLq0zoHTL/7eJfwF3Nm
# DATA jsvS3jGnRDy633283i9YCTBL9BLxKn5VpQcgYIDmmF4NTeUMagPR2iMrLu7iArtBn6PBC16r05H1Hk6G0CqKBNEv5h3vIHqLnE5z
# DATA txI2SUfZGj4K2p6jmHtpCw+J5A/NudOK5s28A8wOT6BMKEZUnQnzqrUIGZFg2DtVsWSwBAqEIRZ762DQObVxNeghfeJ02COCfqep
# DATA cAVz+FTaQwymmPPXGEKziIAYKiOmAlR0KCkdBVgQiwWCWCS0BX/WqjeC/tFYSdxozMJ+x/1N6fXo7dDV+0dkmGYRg8qwhvyYJi+N
# DATA /szA+GyiMuEAIvGMcRtmQZ53maIJVgBF09YoaApaALVGeiv4CCYoMUMkwD93CJCYTj5UQz7dskv7HlHeSvkmCljKvOW/vbVzZ/3u
# DATA 3dqmfzaDiledLlQ2UvTRvFfbY29busNqZswXy3KEn20Pjxq2jJhmPG7iC+cOkZ2hfk5HEKLgk/MXUcnNof2LqX62Wa3RWmwsmq2w
# DATA sTIbV9vSoyC1oQqdMaU9/GZDwTstZuOCM34ing6XX14EWfqYUvWEfs7fyvMPIxOcRPNevjUcSv6CtVvuyBwFOxftOyKPZ2zZ9tbu
# DATA izatRxxZU5jBhJqYwDHJueuNTBKT8hhbWod5Wrxtb9Tqh4fBqFjDzY1jBUX9Jm8DZZS6ITDH7jhSzZW97+KpJRc9QypLGyT3yohZ
# DATA cD4NBESePdp3CPYz1pZ8pjuGIcJiyQoRjsZnLHih30IXCMI7obh4wSXbCR52Sb1w9k0vWRdhUktfkDhp8S222hxP+ddJlcu3bv8V
# DATA ESXOmAPDIQoNexm0GXFqif/HBtVVWxosRluxQupS1K7G7GS/PNfekErkLBa+Iu//CORtq3G/IcI2aTphm7kKOk6Xqa3DwYp1OEDT
# DATA 3dtbDzbvxg8HL1UtajXoO+zBoxVAuJxM31LW96zAPpWlRor6NIcuKT6Pxlh0Bk2QBxEezjpjmveRJ7gfYLWKcszhaUp6zeNTGhHQ
# DATA eEVD9REJG9fdWICxl13Wzvh9+pmbHrYsmIK7W2s/qJlUbpZneYySx42pfBorBRS76BSUGoYx1+mhirNYBXR923RMEEUV/WkeDihZ
# DATA ECVY7aI/vCTXRDpqNlGKaTZ9lfV4FJIjB6w/+l5aHR1NEMZwm+7oTFtoIW2CDNRuNvPGm5ifrNmSV3KRiyM5b26TBlyAhukXnM8G
# DATA w/GidtlUlhtnYeZO2z4eILJxlUGOSTyMnCZjyAYEk66CTmEoigoJk55VoSWNzG6oOMjMh1h5nn8z7X6vdRD0Mu6TmS27CvQGTS+A
# DATA 1KYZ9wW9N+MJwaWURkgwqzxLf/BppX/CUFXaTINJV2ys5Ti65C65+dYe41l8Z8L5btithNe2hq3GXCFIK1FSBaioZIfCRnFAC2nm
# DATA DXqLzRv0FQZMvtHsyHeaCflOo67Q0d31MgWZOJMIvB+vSoKf6LuMtPySUc2uJEGdFqSbDeEar3qmCmRFRMUStmZUVr5EDqtq2LIL
# DATA M9dYRokR/gRdpJ/dTjQ3LlR61kvHi8ov/M2rz6vPq8+rz6vPq8+rz6vPq8+rz6vPq8+rz6vPq8+rz6vPq8+8n/8HyexSLQDYDgA=
# END_REMNACUST_HELPERS_V1
REMNACUST_INSTALLER_PAYLOAD_V1
if [[ $EUID == 0 ]]; then
    bash "$directory/installer.sh" "$@"
else
    sudo bash "$directory/installer.sh" "$@"
fi
