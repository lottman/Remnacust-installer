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
HELPER_BUNDLE_SHA256='59f69a69bee237d50f35be43e25bf53de1b0eee2478604c9c0121a7d598c3fc2'
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
# DATA Zq3RAWK68773h38fZP8bBfzf4P7vLmhnefsfVJE/2P//tvV/P8NaEcHUV4cu5pLwJuV/sXRQMpksSeOo+uloRDXSmJ78MMV7BO+r
# DATA +8vXc6pv8Xw+TdWXy58lM/UZL7oZJ0P1NUl/9+LAV8tFMtb1gYM5+in013gys79zyWDMTzjZ3TvDWy+KHGYl7/nx8dn+CSZnlL6Z
# DATA ft8/2X9xtLv36vRs8MX+4cv9k9PBl41voNn+0TNq830fPg3Wtdo92vvi+IRuNCdXLZ4Qmw83yp9OKn/OLQefvTp6drg/OP1iF9js
# DATA Tsm+BaT0g42K9/zgcP8U01FK+Q1e4jxPUVXxm+2WyDvNi35z1AT78uKSsdjwHW3I0u2RY/UpJ0t0S8v2Vi582/JyBsrpuSsQzqyR
# DATA 1+uAK0+1OkZoKXCU4O+OdUwTsiQ032m5YpToCYkB53y3TCn8Xfxk+FF7rEoV78XuTwYnu19hafmuW0SDHuGCw7Nm7lHuZFlUxsVW
# DATA dQ2xMncUhwBH2amIIZEheq6uOBny5SZVInBdpk5uK7E6lXdl29bkiC81wIxqdVmuvC/Se/A6Vrctb3tri9KVqNaU+k/50+1N6/QD
# DATA fj+vbV7YP1U+rnxaUjHSe884yP0FwrwEKl2cCfP1B3hDQqyu85BETQz7LOjqyHJpUx2iodyLUcJHxBbLGWxerDGOoRWM8ErpRaxH
# DATA lGSADqznyJVjyg2uU1Tx7qs+oM5uGmhU6c5aSXftrCPDgHfSJHx0bG6/grf+Iq6HaToum07hV2smulQ2kAptOkEnS4Qdm8D4sVpF
# DATA 3qEhpjSVmUdW/B/5jfsW45m+mU+WY5Smi3huzigJr8WiI1MnzEZfq9Lel/PkMlUZPF/2kNvW4mnE2TvAlh/MMT4wtzMVQagWisRh
# DATA MpWH59ubeKoH+79gkPB5UQllBKuMD+2sIhQZz3bPdv2SVFC0NwY+3Nvd+2Lft+UAbRD1vdW8o72A/VYqjzlZ/2oav5nxvSHOLH25
# DATA qsisB86LRZaulMNEQJmF9671C7mQ0egYMlYwDUGBcPkRL+ccLw+flZkN+Z8wPxL6VBA7NCpv5yC0SLlyXpclKQ83ShuV88aFZotU
# DATA HEqzO53Qcs8AIFCgm2IxvUHw1kvAnbtt/AzDVe1dZeokB6p6yiR4k0yWkx3F5A2HfLDgZv5o+Sr+v2Bs02kHrBiGOSnLcTCnmg7m
# DATA jL916BypkQdIZ7DuJSC+ih9k2CwOJmYsugJvR36mUwhlmQn02XBoh4QDcAV5/gh4qdbZIk39MWbauFSSl3X6ugWuk1GeB9YlCzg8
# DATA /gCjt5q97tZjcCUdrYwvM7bOuWHP+rhzLGIS98TbEluxdIe2CJsqVvE3YbiSrtVxR9eVwqvn6q2LB/fVq2m2nM0oG1XtKAV3qfKv
# DATA L2EZOjWTi28va4uhcrRbNZqDrA8akoUWXTjuVnvhjhnrTskeq/QUPVWVp2S/4dqSwq1PFXJJFHW0U74hjd0PZl6usBVVqnhuqpxS
# DATA AfhUzkraWDEScfXMCdHNC1hj+Gl2+5eg4Vf+UpTOv2SN8xtQOStydPQR4tDBLgJFNXNWZK2FRS5WoZGIKCO1RTaH3gHkXOId8DBd
# DATA YA+mesyHwq1yZl24MTmpzB0zLJiTncm5w4WCq+7/0HcaIR0ohv2BcGChPLMbsuXEHd7RAZkAVN0OpDCxEh7Bx5i21nFR3AqWLOJK
# DATA 8ZJQBmytKmXJpGyiIwff4upvswij0/O6OhOf1tFFzuhsuRzgeVts9shlY5L2uFqlxz4D5HB4vY3vlKUh99WVRUmkSdiVi4R9O73o
# DATA ir9stZCkwDpFrppB/Jlb5BUEal7Er+7nA67DBfHkMAQ/SrmIGu6DkiNihNV8tKMFjsbE/eeZV7U9vlh8Detxel5lQfryS1scU2s+
# DATA slJZqTcv918i5C69W8hdaVNcKWo9yaurGSd4XyngzrrodA3x6+v2VsgG2Jc5zyFTv4fITPFo/VJB8u1KB7iJrFdgEyhfVJU1lkrV
# DATA 3qBWUxq9ki+OIaUQDQxr6p+ZI92ykrhHP/5YZq5g2MYx7laXX59DdEF3jt9JyjSn19Nily1aUWtdybdXVeC6CKpo/ZNhHEU5rd9S
# DATA qnN2o5wZz9mO+Qp89xiRVdBfwUawLToxhnHQiBx8Jb7nEs2t8972RYFB6BiBtA3Wm3yOcqSGEeVCviLz764rrrpe6CjcFUifnyVy
# DATA Ep89tbVhty1WkQxZ1eRq5euSfYAO3Nrn8B88vkz7Ph3+dCdJa5/hOh8cl7nvSqHlACSVMxyU6ytvOIjm/giZt+9OM1sRe0oFlDPL
# DATA NAtxDbOhUzAJHJ5PF+yU5ttsBkkGtoFlghgmV5CqOAhULD+WV9igPCBdsfUQVzuDOYC4us0vYpZzRHCnJCK5+0KXAz8Ds1Eq/eoX
# DATA a1K6V3sZzRMlehl7WGPkScmMU9OVR775Jv/z4zwQeM34CokKHkv5ky4oXKwRLiyUx2/IV08z4yYVpix1Q8fNQJt1O6JVzdJZWfG5
# DATA yjrurl9z2Ly6qmn1uVapplE8L5IpYQBCyq6G95BISZeL2ZLODRjCrDxAw/yOIt2bNZRbKAPkhONDoiDv1ZqOUj5oRMCcBfMD+KW8
# DATA qs9hQ6K3Kn9ECNVHjFj4O462UPVBELTb8KfoWA5m99OS4/tVG0GudLH4tuZ0/FuZGBlaZfM4y8qMN9zApHJjRQWCaqeuK2qL0GBB
# DATA oau24aI+ZJ896LqjXj7UqqGX/Jw9JmB+wpEo9hxSQRRsXJOpK9eXdrHl3xQRZ8QU3sjLqDxPgL7fbNN/kWvX6xeqG7Zf6AEegQqm
# DATA lzF6x21JVsUX3HqSljSHjhQUGERTehrXL+col9gp1N7eS+u81dpRrUw7c8uCLlihPZRP9KcaOhC4wAbrLxXNTih2J/aP83apQINT
# DATA ZJIzYLQ7BfVd3dOX+yenB8dHamCu7FFjn+hjXH3SqxQS42iG+q3ArNByMWfUWdbcB5lwLib47qDHGHGPYYW2m9h+qkgEb9amShvq
# DATA PJNTBXTNAjuEQ2Royqo4q/5dY4ocToIYWb/Hkolt72pXJCbUGG/ktuo075bcXmvqujWPdaFhwcfb0koHmomLrbft8Pa7ewWQ4/qq
# DATA 3N1ZG69s3faAk6zSOxhiVPc6IfuZLnaa+lJ3xfOkHPKKC0Ct/yNd/Ja7QPesvf2WTcKnti0DyHp2P+uoOK8RnOpGSGqttgj7C0R2
# DATA DJgtshRTPhvDq8S3sIY/KfK2jE3VuUbTI8xfupGNyxzNywYq6443ijN/86Ze50iXabOmDtAjRaA5qaYuTtL9sgl8z9VfoimBfdzp
# DATA yOk+ZeCabgBx1rp7DxXGWTkBbhoXhXTW1l98NBou42msLrvxcreurvoc9EHqe90Nqvyk62lQZwD1uT/7MGDBGUAuwfUSVKx4fs2F
# DATA tqIAM0IiC+iaL5XifEocyWCX3spVN1QPM9ebJCnhDnvqSw4DXcEA8IKuC0s1oiKaC5PDZEikVlC+KL/WZdsneH/9ONH31pNCjLlG
# DATA AXEYKgemkpCQMvEzhuVHyZudUk0MvE2MgiTzHWsDVdZT1u/ozNE1xw2cIo8cJqT49mPe006cdtttr5uaav9qy91bOiHN9Nl71UNx
# DATA 0Q6hTSFNtHti/FB4UzM9qVFmmnIavaVvtf39nxycwpaQbyDC91+8PPv67p4SKytPvu/vTumuJSv4jdc3zZbDcZJd0TbIUNabPaDu
# DATA F71KsoLuZvM0BCsFD+NT+ZAFbJl4CUyBr/TzVXBJJXZg8QdJ0yua/e/CjO5nSEAp6rh7AW/ieiiE+6ILov91WVVhfQycvKbD9QUS
# DATA nGZ5NJkncnuFuUflI5uTWL8r5Oo3kZ6dyjJm+z8a5+JDUd49IA1koZJpV1AJhpMja/PJYh5bm8n2Nbiqx1pPhhAJbXjndceDa6cp
# DATA 0Qs6XA+mZeX3UnggnSlas0sHoHVA9dQwRlCqar3rgYIB+RoG9zYmLD26tQR/H90caerD4OEFWW3+QGkDVc1AI5KqRRACDVmStaXr
# DATA DogaPS5+lXFuvesY8yud2AUPuGSB0nqpqaQJWQaarnrA+ip/sTRiBonV4srDhTCYNv9/csYgn3r73ef/NxrNVmMl/7/e/UP+/3fx
# DATA b2Nj4yTGClV+tpzRhTVxZFVG5hxuqWUdoFMAE0IjaByisjFaju27ae9J96d0/Q9I0l8ORZ/Rv9zqj+hz9byT/ZfHpwdnxycHlOnO
# DATA B5KkBAz6Gy6vwnktSZ+M08UCTPon5gJbXSZm5af8tU3r+1itLOP0V3DzCnfOpWnuh09Vr8n9Aj3ceXwbIk3YmuvVYjHLtp88uQQ9
# DATA YTlEj7Xu9iQ3xztnkgacR3XBcNx5By92P8fagLkzCuLj2T6vb/aDzREn5lS8Z/u7zw4PjjA/neKrKggyS7OEKh3pGw1MZl7pj0vO
# DATA lW8rkVpzEbXkMv9xiQKzqkh5vtVcmm3rZgoMoP5gPMBy2WUmd0z1TheUDbF6C4sur2PdOUSvIbj8vuXq1ynUGKHBh1zM8SDiWxTz
# DATA MQGFVysyYLogFdHqke8VYDgfuKXGuQ21bAFyAotwFlxmprrnJyvPn5Gla5qYir036HM8h86lxNnIvaWPSyTaq0yV3eyNe67Re3Fh
# DATA IwO6zhcRvrykYmbSXcLO1nz3Fhx0QIkJydwfeJfzExDvQ5UYzS2yBnAkugrXAt0PxlnKlEKWVSauHvg9CbI4q+V63b1Owc4JstfY
# DATA 8zMqqoceCe4Az1TRe9CR/1PMvOXfI+w4Ho/czopxXDg3Tgx38SFPC7B3UVA0SlVmtIgOU8bxhEcSLmrIvtGNilcZVyq2x2esY1pq
# DATA 7bfX3IZp0dYjL9lI55cUvjSXg9S4E7mOdN0dmjBtYZYWkRXdm7l25ufmy4Ubj+KX1CEYWuDyx6hGVknQDViZzGXHod7I9ya06gin
# DATA ZovOvd76102Sc7VJCohFT3vZukZGdfXDHb+ed4WecXFIZXQTaxL9DmR1EFEaCqjHoP9G5jYWch3sWHK3Nl9Oy+dSEhLL3OH0Lqqc
# DATA RCVu0TCYLfAKZZku/4ixBvWRQdmZgMLcqlcN4BUnj0ONmC0iaE2ZLO3Hp7LI/oIlgTWGZ+jiiaNMz3mcTJKFm91o5WjnxwaQrBXk
# DATA JXHbyKoPkTuDdcHZl+ruOr6xiq/pdIKb0oxjm2Y6t0k8jvgwEdbzhze3+X2OmspYWM1vwLJFGcUJFYAX0iupSoUBlybUpcCdJCO1
# DATA 1CwxVq5vu5ynS7qBQM0MhrAvzVMv6tunZWwwvjBzMH8Fy9u3NaK9O0zN/Zg6d8FxVkT37l4ZWLaKF3KVTClM+zqOZwIcXh8AbFvt
# DATA G/rN0jjymwgx26yv4MJBsSJOa0jLOpWUwMxN9ifPrfWCE3m7Lxda98es9sEI/0up6G/VJVddICdJ2Mtm37eaXzlOnlSFu+2EYg3L
# DATA +mtw3ZuY7URuDCkXKTB41I21nonoyaWKdQW5lhkIAK7r9oOQRzmwNSmqAQxN6t5dzkwJa0UH9gqk3Urv4+LdpmqFLoBzhrm95zI8
# DATA a0g6DodW730sTmd6iTmGcx+myynZao4vTxo42mnBxjbDW7oqH9fFG9tAEN6DUt7Ma/GptJkdycoZOVpr1dEPpx+sfivPa35X/2hH
# DATA b/rtoqKWJ1pmCoqA8eDmibbXC0f2Ze6A5YmsP57PXVVjCO1e3xvQc5X1Ai7+4DXi3/e1eBvB+4iyTfTps8URxeMYLcynwFN8KmNb
# DATA VexwBkRIyXdS/d3VKldWdz6hSrbmLvucdshL+smO33hcmM/SI071x6LAnywPqylmTWTWYboc8wV06MYe3yoVOlmsWxzub1Taw0UF
# DATA kN8K7He2f0MbtEIMT3X9Xbp3XDHYHKWUKt/GOf3BZWxt8+hDSuKy7MHIIF9mtKPsyzXtkdVaBW5ZAbZeV5beA95gJandwrLiVFW3
# DATA ndEXktn/wdyr/z78v9nvyfH7uPovzV6j5fp/671O7w/1X78r/++XElXV+YDC9+QiL3a6io8E1a1FKuz5Pn9vrm7Lve7fqv8SrMiX
# DATA aZa8WeMNtny/Uq/Frj/BB51J6ZazXOyd2cmXobASo/neNdLT7z/ITIlJV8vpa/LvLYCjj4PJMAq2nSMKlq1awRoZ+QgtQ6TUWOrP
# DATA PXLEzwsqZKiQN4eqFsElcNMMLDelusnlzTQfEyWz0tktG4UaPFGFWfgykFUzZQyLW/ie5u6b7GJZ34WVzSpXa3KSIVcEoBMEzmOh
# DATA PH4Oc7xPGX733979kmt7q0Le/wB/fvv+5+//+t0/C2VuvvvNu7/HK+zf/RMWAteVPAT+zDrol7uCWi7/tM/UmWdyPvURZebvHpwB
# DATA 1RqXGVDpcSxA/psHZkCJ06Rbvw3OS5TWfbHtB0SkARIokwbPiT+bi4QCWQq6gpNvElrOcIFBtTFX9VkiXHKipxbiVtODZgk6KJFm
# DATA zhkf7j3lOAr/TK4UwZ3j6+WALcGmT4PThTLJ1M6CTud2S7zRIVlYDeWHB88Cvvs/FF65njth/Tfv/4ZICiu5wycs//7+b6gm/Pv/
# DATA Ao//kcrP/zO89C98ZLCggL4QiwUiHUNAOwaYm7pTlgkomETdNhJOMJ/Ah7sHYf5vWHj+N0jk7/4eqAZh+Q2Xxcey9EApVmF6rHf/
# DATA 7p9hKj+H73+7Fl4iGYCwaqIXBPt5Du6L4owwue5sZAWp3upR7jbfwia+2wRravlm8y12eFcDzl27/Fkpl441Uw6Y0T0BMavn7bcM
# DATA pS78d6EG42FKKzaYcTjTxXm0BOpkkvWQTSHnfO9jsixtbgQLAcvwq3f/8v7vCnbxL1Y91ffcuf5IdPyxRNxKfDV7/kS8mZ6+cJPd
# DATA Lx86NWa0v3j3j/Dll+//2sc/+AHIDGZ3L896/LEXF2JTBQBvSyuuAKDijWs7oY8q2vbBs4Yt9Xc+7bVf00T5dgj+Geb+83f/Av/3
# DATA i0esNbFiutyF+DfBximZStYYexhTPWk/FERk3zJPP98wcR7YAE9EfP5/7L1rdxvpeSDoz/wVJXk3BagB8CqpGxTksCW2m2OJ0pCU
# DATA 3W2KwSkCRbIsEEBQAC9N8xwnTjaTE+8kmd0Ps3vO7GzO7tc9x+m4E8d22+fML1D/hfkl+9zea70FgJK6PbvjTiyiqt775blf8sXu
# DATA 4LyPEH2RrsRi4TJQdV6Zw9HgHBi6tqrSnox6Ak55CO/pW2LVYuqEy6nVRwBD61zmkD0fICaM+AsBxD95/c/w++9ffxnBCn9B6Ud+
# DATA QVlA8CT+5vUvo+9m448nh74Dd7mU1ZoD+7hSRK6qHcGBiuzzZ4rgoIKp3bmz+kb3RQ4DTuAnUw6JkICKIFHuKrCnnXGR7HMS+iDI
# DATA qzZ9im8Kzbhg5bfSRq1T8FFglv+ZEOIvZJM4p4rkQIlgo/iOwJ2JqFWAhxG36rpSqOHu26TXgaWpM+JM5YRdwEz7+CwpcOWCYcK3
# DATA SoEe2le00AHNXVFOSJzIwSXUcODsx9WdO/TR8YqRgWiqhDKwEuGhvylCxPOHsccOhRn1xnjpmurkBa8kdkFHsukeUBXYgvRxkh2q
# DATA wn8EAsrB6JFSlXMrwkdFPk3XvWrXRauOMwOOwsCL53w4kPygutogF3BB1EA89Wz9XZGEAfhq3xkHVjBtBsWRisPzyCl/fmrFJqNZ
# DATA zVAkO1SnzMmhO+dqBaWGhWaKVGlg1v+BRv1nMJG/RfIB6Lsi6QmvPgew8lPCQ7/0lgTJV6j11V9ZVxFfOqwRwRsddjE7umyLn6wE
# DATA GrPPTBZgra1ZzRPFZPfjjToUCsE9i/D+HHaSQTsA+bjMcZkHGI+aQD++Yzd70r1QDKLJaeWUfd11Zlar3PtluKD8FL/+PDh5mDfu
# DATA 1b8juuI3EWbaQpAJL377+l8tugFhVO5oaed06BfS3JGpVCzP+CKqREPzLG8nh/mgNxmLMXrcaJAJFn3FQJd5iS+/wqEVHUKA3AKs
# DATA OAEqqMD8BBgwNEREwumA9RLy83d0/H8WBRf2izg4LzWDfK6uEbd9jkgM84/BVfprzIDG1+lGnVOPKHH3fNxRu8gmIKHQBLGWSXh5
# DATA WoWcUbUHo+IpL1RWYRuCVhTlKw9Aw2loBnGryjrK8IoMtHjvVOmiHCjHIIy+SRoU2heQw+zZwcENLh8BGE2nIDT8BSKH1/+EF82C
# DATA oBrmfokcDV1LRcKUMjSM4Ag6lsWZsCZm0mkX9tRuKLivJe28+fYKP/MXMOt/YgT71f8Ev385Y6dNSCdryHYUDWW4aXEFnvhVuYjZ
# DATA Yk4LqyhebfYe/0fcVuTJYFv/giUzfGnfANvQ3GwaypJ7GhdlRo4u+hSNeEX+orbaxqHfjh71gGLLOkaFixLsnEwNuS9BsuvGlKPr
# DATA lNI0vYiHmdTt9QbnLAP0F66mllJz+wfa7lXMY5cPrh1LBDV2cyP1KzpwZGshjIL0PIcxFmVl/Ce6bf+Ct6vs6ilCDe04Wk7PC4V9
# DATA ufJJaDYG2XCIT6ASBrn+9iwXCp0ujXqr7tB1eFvz5CztVli47+7o7du3H+GIaG/gnk+SHkH6rvApYiXfV7qN8UmCEgvxbmMDTwNd
# DATA UXni4gQdfEpyvZp4REVagK6/MrEoD/WipiFRin48JdaLoSoKn/9AVWjjL1z291p2aKSpVIeK0kUPZKViCE4G4O+/pZDB5CO1b90/
# DATA Uy5UlEjClZtDQFVGsNwkQFQpKiq1bkE1kbXjqCtwqZhiO+a2GHJjSpgnP3G826OJ+x0L1RSJrzQfzf3mCgkJKvFhb3DIiRCY9Smx
# DATA 32EEOWfYKW8lboo4W7MQp0urFIJjSaMLYQITD60i4zRqkBc3JtV+L2SaT7Aw/+5PQZCB0VtqH3k2yp46iXI65CZXcQaBcgPi5JvN
# DATA 4M2WQ44XrZI80k0hASZLFTlim2NFGBOefZfutePkeLrFk1aIzteekbHHv49c5K64bVpJZcU337RI1DlvYWXZ+qZp0JXDL9dnaXPg
# DATA kFgSZ94k1/6Am2DVdtCqWol5rS3j+H/oOqzfFfKxy6jwquhBNcPBUfwU6gWhejgZO5sjWhGJRKw/pTk/R7s828dBmRO7/Slhub9w
# DATA SjwZWLeQ0aq/Mur2FpGLJ0akini6NEQq4F6/bYYBpS0LKc4mnlm/cTjBqC0lzedpaTuKU/NXRrOwamEKTYfy2asQNjU7oCHbtpYE
# DATA FBH0Sn3SjSqOlA8KRkWi+tUZtseMjHYvc+BoNi+Av1t+Q4tJJ5vR78P+b3lp+d69u57/99IaFP+D/d83Y/+3N0r6OV9KYGg5BxYg
# DATA MvReysVDA6UJ6Qg4WOPsDXAKKefBZMxlKa4IFEGL96SXz5/6rTMYXr59UrfsGAavn8bJeH5PcpXqbdRDkpsjz7jv0AgbNbM0HnlH
# DATA M4pMORKz1PDXpE+/3RRyeJE5L0sfEOUY3cLwshMX3SZZGtBaJhqMhI0BUK2myinbrFl52c4Q9NAPPbeeLGA4d1ukl/8UYIDytADs
# DATA jbsDtGQHhVfRUw0emOY1cNDIRDaibpYc9wdAWHdY5gG0M4WdGQ+i/GRwrg8KATk6KETNTmQk7P5GJ0Z031CZNU/0qRYNhnw6HY9K
# DATA CeBIS8g5vmxeRiXBccUPXKdlzD8bnGlIf5waZc5fjXmkCmgt8mdiPfKvqMhzU52omXE2hJnJe4oj+L+BWfhXlLAVOiIVIJqpuGZt
# DATA wbQ+Kp2QCndEw6kUx6OXCa8YRZRsF+QYK2836qn6MaMfRbMKlmd/6ZtdADv2+neucQWOWYeKBQ5s3E4ogIVtNSwXQuflsw+ZSd7X
# DATA xsNZMebDtch4ZkicY2uB2DQDKlNI82Tc2G1vPX32eLPCkY7HbfxmbGax4B9FSwNAi+Wh6dGoTWoDaEHOe0C8bQpP85yY/5241J/D
# DATA OgJLynznr8jG5rcoQ/od6pdxW4AN/TWsbIEn/81XP2X9O3Lf/8J2iKSw//VX/z52A0G2Za2FVZXVdowsYnwVN815xHCg7MnSjDj8
# DATA c0xyVXmMfozLs7xMCRrPgNdCsa6sBrwgFpNDWqi38OwnAQmPq2lkqbCgeQeuQCaDIrquP0a/eS9A9gRlKpapbApvSNpbkfLhUNiS
# DATA VQDPyNEAxeoK6OQC4gr0I3XkChDlPO0+2f6ee5607FQX2dn8brGI/vp4a2fK191nj7z2SyWu8wNIPHYElX6Oh+5X9pFkHbl1KMOG
# DATA hFPGx9DLfsW36v59VnCUXp4bTOwf4LyzcOcfaUpfRF/9BQM1NMmdPiG4TmT9/c9iv6sWAisBpCN9MwqQfoUWvPCKTd4qVgf3loCA
# DATA 8Hr5ZYT5O7SRRzIc9i7bLrTjP+hVRoy8g04Vk0JFmiV5Q4iOGKAMaZCzpoHL7/M9Pqjh+2ftncfPtp98CneVnuB4bT7ae7ajX2w/
# DATA ++jZkyfPfiDBVG0mVO4HFDui22H6dLSMFefOW1edJJF6UAIiDmqResPQ4cA54UWArDReuiEBSVZDDJTCaaZuCnN/yVaCZOrzazE3
# DATA wFOBAFhsnRD0cnGLhnDMamlHw9KLArwLrSouOcfmM1/NdNUCcPwJ6ost+v31WAjGVYTGOz2gLp2exYdHsxRir2hJPpCgbWddO4h7
# DATA wbugKFezThMrFjkdMIte0q50I207K2l81bGPpE/mXN4OSwQQCc+sNK2LJO9jLUJNUeusnphWtMoplYw3hRuUXFcpTDLHcNAVmQMG
# DATA oA3YjDgUXXAWbFjljFaQsDcqGHBoWNZMFgpNw6dC2/DObtzZTHXnPNHpHBTNfwAI+Y9EAZLpoOobqyuCsXhKqjZ9ZzgOf460zmaQ
# DATA ZqVFD4veNLg0hTXULkRYgg/VpK9ivXZjDYFSzwOJlSn6cR56DogyghJfsjYiAsSEOoRfswG1UZsQViHT/X8iA0OyJSTSm3xJiiRz
# DATA jUdYQ2NY+RVjlGamu+jNfozygl15qc1SJeZy+wTYQsXFaW9gBBUu1rEstaUwrH21QAPTN3oJfDZG7RC+myuRFq25yDlo+A07HSlL
# DATA emR8XE4RGmjgEEn/CMvOQ5zSr9SZwCooLTU+D4FZPh+MuvoZOInZO/d3xp/iz2zhiavqIsTxJe4okAN/zhbwjCB+QhjhNxFtJBAi
# DATA 4reEpPpXf0Uqp38tZ0B1IDMjsqhUcOzkq6e2qSbTw7OAv/50kmKkV/x5NEqOT00aFSc0UtlWSLQlFYsNCohViop0Qw6S7bR/VkGR
# DATA rCTvtsPrvEov5a1uOuSVloxh8OiZNor/pPKdZnqBO7IfvRwfvFf9Dp4D42oDLYr3DH6+02rc+R9iG4xiuuwUhdwVaZVjHCEV1Xjq
# DATA wVX8wEHxMEmALs8uo1G7icNHGNLSR1E1dtRLjvMWNTlFnyDt4x+VCVklQqbsKu8VO5BPTqhdqC4LPhwNLi5Z/M3jcC5pLXqV9but
# DATA uJN0u5exkbvota1858EtK61oo35QdReXm+P1rXynUFY0nChrRIsmokeF1tQwpOIncO8P+r0Bha/migtuLC+kICZ9sw390D7I9GQL
# DATA 9OJv2UZhalTqFxm2Y8sPrYRDbkQwOTK4auz6eJz1HZt3denkhOCinFb/pPIyv0PR70ekvn2Zv1et7P/JOpzVynq1EJbSsobg+Ugy
# DATA Q/oDd4k2gJeOX61QXD/+vXrAJy6kQQJSjLDhkmWw2rfDyfi5zekcWnFuMMQD2lRwtIpiUELWx3OmOwYB33aiNlq3TsYCgyFuLr6K
# DATA 2ROVG8FX8lu1dKVaKmbDcZ2rMDrJETtZ2SPh+gGDkz7hd1lQboLu2xXJ0agp19ebRv6etrBo0KHBDqpR3X957TG3tI4qGh1lay+e
# DATA HTu7YO5IE+WkzsY8/4BIBblLxBC/IALiC6QViEj4ktjMX/Cbz5Ga+B3ZKnwOFMXfwtvfENIZpegjkTIEWbeZGGJkkIlhVw0SKOkv
# DATA X/1NXB5KT6fbxHBAtcgSyxToNEZJWjBshHAIAFtGnqSvJLwWChMb17mFCinLC/l9isJRQmVaHkfDs5vch74OKEKrlmQVMotRLnCV
# DATA Zp66oO4LCajwV/n9F9+iU5Z4eYJZLfe4f/9+eQcUiP3a3hEYvcqs2c2UB4jeD4EeTXutA7u2EF4VzScKElMd9c8oaBrqx4mQrJls
# DATA HCYR3kRsIKkEU81YUdx6KTjpNJqyGGBNt7nPv5zQsfvmrJG01wwIOQKqoKQeXlA0QSocFY0WmTEYhyf1aBdF+SiVCBE/2WjQJ46Y
# DATA VxT4hjFn484DFFGJm4OsExJ4UF0v/L4i4HFLyBbMkr0oYCfMjFIJ2SPyl199iC2zAtpKknIWtpXHgvQaDsVk5TlwXVzmo/Ksq43B
# DATA OXj4IvukfgNZG6iQuqGGrvfY5kDNb0d7Jylg3HwcqVOHtymZjE8GowxuXXaWiuNhPz3HQa0LOcvZhFjvNcTAtePBoJhz40ipp7J+
# DATA 2RBIkjLKjilObcu9XrQhlhRdO/bxvtcsuOZbgQTmj4iXBrFfXz7gwLKKCC4jqJnw1FQ09KiGGqSUHeONIJyxeAHT0hV00+R9u3bD
# DATA KprtLz+iNvjzItRynX2n/AEZpWOz6pKiToBGhQBdoh/ql24edCt2aiwXiUMEAsL8EZz6OjmhGgmJvCYCUAIdyiu4HJ4zqWnE3KCa
# DATA mLdbdwq7O4prkmxLjVJBHLT1wusoi86TIZ5eJoJzjFqOYpgGVrWM1F17I1EmV7ComqvYm8V3YmOKr0IlZkALjYaDnliD0TvYgDrp
# DATA wSdiXuiEFbVlL8oqPhCzcV8ShCuxRC26Y8laUDSedUj5LPFR3O9kuLurwCQVOPD6JNBZBL+2ATjP1Ya3B1pkRLH8tHn/FCiuAtMp
# DATA IaYyZULvZNowSx6DVa1wAqqffWXxezgY9Cp2pDv5zZPeHfMuaMAhCbfUauNRIaKGgHczUt1TtSaZcQA9kw7xR4WPka3LU67JWpvn
# DATA VuDP/jkfyRCaejJmwrnMOL+2aA0cJAJDIaDx0UQaVdCVz4Yc6498MtCjZgj3F24W0gCGzpm7ioCEuvTduDztxcXxVaY0QGkfG+ML
# DATA vAyshKZ5k6GsX6JayDk7xcIhMI+CthaXU8sNUjRRKYrslTTNFd7X0BylfZoCrlQvUJtONKr9jEhFnrM+hTg1r2SwWlxn6BS2Waqo
# DATA Lyb7nu7ToXtJO2hEurd0iCJM3GSqaHk0ig8R9ig0ToCsN5h0j3oJRVyMjzt4yKtzGoz8gkP5kGQPo8XoEFC/JcXQP0Z7T3aRK/s1
# DATA 81Do6W6YJuipq8Wyot+YQ4VixNFq2edeElNDrwjGqc/HaUJSeqR6u0kPar7dCvyErQ1QnvlnyIEii+rPX5lS6CG5QnQc8y58e6ps
# DATA rvU4q2HlEU8SZz/nBOebH/LCn4vs9stps/u8KJ/9+Vd/6c+a5Nd0EaxDj48VfWn01vKDz+UF1ug5Z5daW1sVAH8xSi6Dndg3kSkt
# DATA +3lGV1tcWHp733Q3ay9It2dWnj6gV8qVuwCsg0iGGfWAmNysVs3M6Zq0Kquzt+8/s1z9q7+JNp5v1ZzNwhgMEpTh59En0HJBj2/C
# DATA MIgeXzYwP0lGLEqcoboUy4WQGhKPesVB7gHNEbbK6jNqySplJUAl1yEfu/jlFe1plTbkqIEmNLGCwtVQJ2YCTTKUYmQ96OFiVLT6
# DATA xtHQmNkzXJfgTUZPM4cKWJvTBZdywTMcN3okawHsRl+MKOb3fgxz3186uNlYCr3Zq4x79ZinWWxLdpKVWHg9pGTVNSGExWR56Bxr
# DATA Mm2CFnDjDXKXZb9Y48BZjOmD0jhl9h38jyb4SVhCOVWN2Yhe/wNB1b8ig4ufo67sCyrOnmOsI1YqNgye9yVV5feClX4uL3+lo8nw
# DATA kngkB7wk4R1+5G2K1SoYOqWlV8MlSDTmdXByyOusuET/Dzma/bm9NGyORKFjjH0eqwQtUHSYdF5NhpYyn1+wPYHcuLoTM3BGeluu
# DATA L1mUVaJkNE+yMyobeSCxEESustEfxSxVLDJBsaZNvsSwdPAG/kWLPz7+TUNkluQcv6bsWUgq6UfmDJrAy8HD8ASjjTbhB5OxFCCO
# DATA JyLD4ofq9SxUFSSn7AwGHEu8bXCzj8GnY2bPgsAhcKoFHMkSXaMoA0bW6dkiJJS56YwmsqPQHG61vLY9ryfiSfDjR4BgzimNpisP
# DATA L7ZpcYZu07wF6dERoB4UsbXE5sLZlFthiCc5Ioq4lGZ5pQftoCt1CuNgjjfb2kFFFLDEDK5sAY6bV8IKC+aJGaCs6FlJnjyNCXyE
# DATA xVjs7Skl9iW8gzDrQRGPXsqqBEuWxpUtfbFPlS3lAsvQGayzYnN6rFeezawbxO0K5V0qqjYHTIdTqEVt6zIdjdL8pKK8LfXoaz7t
# DATA UpsiDvf3Svsysy1Rm+FPy+Uz1XKHm6TZ4eHXww58tsLpUDTd+UdoaqI6keMaZ/1Gno4ljH8llgQQLMZyIz6QMhvDLlDlZjjtOX3k
# DATA G8Tv4qqn76ASjr6D6+iMe2jgwRYhse7OQZeFvNN0RhbPktFiLzs0oU8XAYHG89vo/l+akdLIkWOW/oxNMP+R/SK0g7Y2tvwVGrMD
# DATA /cAmmV8gQw5UxX+yOTUmIr4gp26bPvlcWd/Av//ejpREa6wEU1cx+t8ikDnMKOtCLNnMGPuYOwm3vZOOMPselJH1b5YuDaG9pNvG
# DATA lN+K4LYiiqEUtZd9lnbb+rjsyyGYvqHTFZDeZBi10AGwklcvKqgrB9KZc+G8LB3Y0w0cp+vpQwoc72lzxBAk1tk8sFIRo+GstVBO
# DATA w8UF1VN370vJaQbY5YbCRv5WujRRF+SFDllAi21MlPUJknXV1v9+PZUvjxhJ83GfG6RAF7KBinkidGCXlCaA5nc8q+Y0gv5PvnEB
# DATA OQH8JdkWfIm2iorc/9VUa2m50utsWvBbCfr4M6be2SCuZK2dnFgXl+YWzILf+xqKHgSb2F/hiBqOCFyvW9U7Tm1lzBBYWSeeeHiP
# DATA ZJ8965oSPQHpa6yYngbTUC4ofbD3410ZgXvEHRXBU5qsiShvHfXHKYpGOa/61PMuAh5dUbqtFgyAOGAcjZLvwo2cTrQNLHlX/Mw5
# DATA K8jpIQoQ48nw8fID/zg7J+OyzZZgxNZ1kRRwmjiDJS1+LRfECwFNhTfIwJ4IaNeZw27Lp0S63bT7HA8o1UM84JVgtQ0cLJcIxdL7
# DATA M1RhtciiWrKjGxNwJbu2Y9sTSUwUz/JIRRn+n1ls7PHqFK2RnAaLEoAv50Hdv5Qwsm48F5br/YIc3DD492+NLDkw89CE/S+KCKDq
# DATA jg4bS4qK0uygdza4NaUZsyhM7wO1U+BPPO+yooXpTRSO1LUXwLx0eG+vfSQqXo40/TJ8ibqYNuFUYevLBqoWZ3AqFkM1i12phPfI
# DATA VZRYsoCiEq6kAZImGPM2PSsnvQoCQsXx0OxUYCASkEyXJbyBKMGbwCwvhEJUSbis2zhK3zrw5x6dvI43Tzyg5HZ+9ffaxh1l605x
# DATA Lbz7nKC7La9TQjzfZFEyxZDc8JdEb9gBIJXZdmhljUJzXukJrVrAvFZ6sUyuZ+53jSVfZgzx/Iy3DMG3rdEd2XbAbGvTLRIxpMcP
# DATA 3wlJP2/AHLex7wi18a468mHH7u4q/mjn2fZee3P7cfvxs6cbW9vIRdjKAGvmzze2N5+YYuqLoWtQXM3Jsi3fE3jpLSKb4aEDCWY8
# DATA nS7wP6g6GB578KCxmnRRNi4CdJ+uoVHeas0riXfXDMi0Fx+2n7/48MnWI7UUqiMyfS46Vrhh4KYZGO732RJFr8u+K80iHr5Psjai
# DATA 6c6Ts7QeCGulbRQXdOCfwFkNHBxLxRE8N1JQpdGyIViLfcVtsNeyFYGeKrKlFYPV4jCKJJFDM5USRjfG5KrDwXk/7TodhkyabLLM
# DATA rVELb1e15gjrDqrWhszwdHzjqxS6CAcLb3BbvsnjehW4Vc0pd+ra3Wo5lYWr/FTFWind+HBpNIwtuQW0d6zZMDEzLS/M5sLb9zF7
# DATA o74OCOuiSt1/2SDF7El0PAf7pEqipyodJa4fss6SUgsFXkiBFTYxVSMgS2ExSbbcUx9r1bQFtLwofwzKLQtlafNa5+iD89dtW7BR
# DATA q3zLbigjeF2D22GFYiuydUksDdTUNJfBAZIx03TyIZmMB7FvHvz26ha73VLjLDulg0zLFNRxUjwDLWpYzW0eQy0SgZVan0jHLTXi
# DATA N7b5Kdh0fe4mzvpivSQau3ae8cjm2OhR1Wkleq5F/1pqj5YjRQZEIKZ3/IeoQFSHtHzlSDGqbTrCDNYAU+WQtyoOvLMvQ3XGsdXg
# DATA YWo3u9a5yltxTZydSqGsASRVyTvp36pSmxi7meec/k20EsURwil8pJpsFToh+0biYVsyUM9EhrqePgfbfZWgW9miEDT0FyYEqqte
# DATA g2qMrI29c0eqemCLVsK21rHNkysx5l/rnKCWaZhi1nA4PdkZADh6rJba0QZUGvDLMdec26jHtzpiS4N2WfCEUJQCrlJ03NcNiduX
# DATA fp7m/aVLskIzMWKNEnJAypF8hZy+x5fSdym+rrJLBhlzehIbdvpr6ym5LJxEkptS5Q1phFkNvRm5ULZ6IY6sjBCwt/HAOPDKKKeb
# DATA PJuaPuM2x1xvteYYf8AvlXs1xnP8wpW1Sa9etIWAu+or4uM91b/VhXqoLoQjhYdpbm7YpbrVmN6M7J7h1Wi0iyHifPZmTCXdvx09
# DATA IQ9yDp04ySW9NUcOifNoODmEGUUvdp5EHJ+Ls3aIIzjHQ4EVHqV53phPOsIG/phObpT2OBtEX0CAHF42hSr1cpNqM8LTlMbaL5Pr
# DATA SrNeNN1+dwi4xYaP9olQbZFaSclrN59ub/xg4/ubbZbTwNKx4WZI/kHbojqpOhE4ADLMOaOyoy4zoqAl+veNLXuk5nTjnmKhA08c
# DATA PteVCjSDTGloSZtuZBW1hj5E9bOKIt7gY3bD6EKh0EIa5elGS6IMBQGsrlSEP2FYbiocFPG11xohErR90m7e4hFkBvbtSCe81z5x
# DATA OQUzOEmzkfGvFKKYHfYvxhIYAzD3pcAB48Kp20E1B9tXovpBv67riJuOkxJlg2UfpWpondVUz0cZJo1XrXkWTHaKJva+87wUbZdb
# DATA 21txpoMeB38XxxNnLHqSMbEiEvUKfzv+QqFiOj4Qh5KX2LxpLudDLb8Tmm6OXRXcac+V7HLVbrKZtxbKcV5GuHNbYyJi7XpV34U6
# DATA 7O/na/WUekc7qzLJX67s0fIbS0ZXdeNsiBqNCG9aEIk2WkzNEx6jnoBIJH31IEvWeamRC5evB6GcNnkILMuBK3iIosHtUPtudtI6
# DATA XNJRart5dtNhrh8OJ1mvK96xwF6QWAXVwVNCn9yp7Mf1rgSkk2ViE0hukmyPSAZ6h5PvuHE7vQUqYNuy1QpSb4zEk+7lNLdMldZX
# DATA TFuPxDK2QkLoZjESoglc3YBhVPYxgnR6kXYm4+SwR961W3EwiDTaW7EXMZ0s3VNjCCevSulk1T6QhLw+ZB0hASgcDEIJTDpClts1
# DATA CpI9mIxbq0tLIkDmoPjWAHf1z003+v1NLDRsHT1baKBynl799PXvote/ij7e23u+W1cuOV/9NGgCpKZL/jocfIQj1Ipx0T+TmAXN
# DATA kH4NF5EiZBMzJ3AJqD0EW3ZIWDFbLw/xxjCJjcoPmEvGK9FLeZ2xzbRbx2aZXxab82owyqa0p3JVGxvqDSQ+3GqB0xQwvTbRG+dG
# DATA knNqMGzEZ3mjiiU9GSu/PRp8M9Q2OuUjDmjGBkSxqxOxoUKvS8lxaB4+pviQZ8SeSE4gUqm3qJ38KcFK3uAlV8k4AwG9bayqsKE0
# DATA IY1WHemLFQ/DDfxQYBi06a5RL3MDgWg5Mg0JZ2KifOaBGAncbmPSJ5Ol0yxHtqk9eOU1V7QpcYkHbqZmxcSRMDjeIEx4nJoa3ykH
# DATA b+XMM4H4ttbFsW2nqibirRnqTArE9Vsx97vl3ugAecTadSaHBOzDKWyTkHZ+wFLolWaM6GhGl5YDgHPTlLlaCXqT/tjEpqqFbbPg
# DATA QJAIcOgpcqGlW+h2YQcqlglYIk9xA3+VXtre3zeExSamqOXoo9dxDsn+/yHOY0osr+zI/4WMSxDr/DtHNP/131bDyBeCSskFtYNX
# DATA uTGmpMB0Uabq4FbLBwvzmvkWEhE4AY7JZ+9ns0IcNyI7G7Oy6xErIQxBrw33HLXIG18Yh/a6CWxxQ+7SEETbRvJA1iF5gNRPuyQK
# DATA hgYKbNvDJFMosqB9ITRnXtY4UBIXdgK/zNIgePIepuhMdo+SREbl224yFwlNxXlUfJt8cd3qR/u+RgLodI/9b7AVSaUayGso+v6x
# DATA SJiv1JI3vR2oRfYaiHcFYXjrdbVhmbJDDVhTuyTGB7VLXBc4ifkvu8r1yLy7jm0VWGXnsFqdaL4/iBTVqIimqmkqz2QlcBBCtYTt
# DATA UTHabimGOgwAimRTkPwTskgRfzS0QPQpbqngR1qdsTSG/mLFnk131VwF/02bers2NDXqtlOQ2riGsw65eSCBDG1ysLxrH6KFSnLz
# DATA Hp1ZmPGUSfAnpIP5f4BXKXBpe5T2UgC8HrIKTU5JXZQS0qHh3bA8TRfRB4db9UP5XAdDq4n0U1/RIphplgVEExlnKIxCaTg7Ip/s
# DATA ik48BbeaVr+XR0jjlvyZaoGXt7B+uWCznAmKBOj2OEs0lmVro1shywl5eIOlcqu+3WKptt7Zcs2+Z9PI7bJQanNKIwP0hTaDbylb
# DATA 32aQW5YwbOh2Qxyw4okd8RuloiElAsl/qTn7h52uE5OdKvnwYjruLFKpRWM+T2WSbjIcS+A7z7A+zB/OKW0oTdLkCEN1piaJtU8P
# DATA FQs92Z7NmnYS6qr6rtaRxQuusAGLjWMnoG+AAy3sd1ESFFdn+dsrWVHB+2d+tDGvbKmA0AxVpKk9H+QG6aIQyWPZn88puSq01O4l
# DATA l4MJObA4mLyIa+a8kAV8U4ragwwJbsvCfFshZPmHUH+TfgIotlhWR1TpcrI6t4qG5XMlV3nL8GI6qVdZMA9z9ZrBaJXehoQC9Xkh
# DATA P3RIkELUoOpcJkXvJiAPyQW9kQFv8lQxJfMYZrKtYU2imDxNhjYPMisYYFWnOOOMtyTYZ3DSnEceJOyi3rYDzyYyJC9y5KjN4pFO
# DATA gNAkaGwGYzN81SnCb4PibmkUp9yag0NxEhR4barsNeE58pZaOUUc9xMXO8CLSryYDLNFjPq7yDEpY9aFYx98LhZVwKAhhnxgu3Yr
# DATA i2iDlF1t/lrxvhHe+xhWvAffrlSE226adCU0My3t6QAWYtDPOhUUmC+vcLiW8xMMSVwo8EBXb5bnfeasdzQkTutFVlpK83OXEuAB
# DATA uoKVC6VZthzb/J1xiTdt31BCbFu7VjA2gAUOVzocdC/dMLRqpCQJq2BWSklOiatVHvjYCxqO7VoBAgJf+eyp3vDyTiu9b0rKqc3y
# DATA JwO4PhtoYISKnRo5SU4JlMyyFyOmIWkbCslIs/VznU6GjYdVUsyfYqLN33KkC/Rn/R15y32BkrgAYe/tgeAgOztuA/Vw08REHCqb
# DATA oyMA6TtKi+mXyLQKECOUijCZTpxHL15sPW74dKHkICV7K4BD3H9HXO/Wltaq08DC/IcvPOnKs13J9G3n/3aWAqZhp8M1OuHcuLLQ
# DATA lcx7aTqsrAiiDItOSb8ZiSfjbz3/ZHZjVsJS2c2fvP5n+P33r78UVSjGmOSQJaF8sEV3yV/rlAwqCj2rLd9C/XnLonNmy9f/V+N+
# DATA /cVXf41On37SCJxdHJDRFjFdOd2ltbHfGOGV5UOMEUB55k2qK8oAD/BVEh+3lIw69kTPnJ6e9VH005H50huUShqXoEDDapRxYOC6
# DATA +elN6GVztD18QOZsAhU/dUbmltraaMOsZnjlKKyeTvoxygmDqgzijY3R8QSPz3P6UrHo21a73R102u2qVbOBloGJVKnEemQxGjgM
# DATA 0O6jta80Q1oxpOK129p7pbq3ZkOZZo8GOjpWqEPgFDHQHSDSy2Haes7J9gDTAxnXtdWL4bqGUnGG6yTHq4WI2ulDAgqsrqlO0+68
# DATA vjPTG0fmsH7KIzNtl0XTnaMtsk2prpeVkVC0UizgrYALUs+IwDbRRPG8xZ5qQOT+Tg6xYJdIFhq3BTy/ZFNLZekPls4r1Sl3Xh05
# DATA O05ghmahElSbqjCrxbffsFD0zDORB+HA5Mk4S8kLHZTAfmafWHq2g/lWy+8y+1mp+2HfCfuuWPfDjnvAMpujTn/cc2C0o/T0AEpp
# DATA wlkSiZCNE+deqsSAkmAoVck9+2hnc2NPZZrdefyDHT/rbI1z3phuVMrnoy51YKc/jc9jon2xBxfD02waR/ihgv/U5M2TZ4++1978
# DATA xKWrXHQQ8Hfk/ScStjs5HeY2ZJt5HBQPjmmoczQ1TvJOlrXEYBD1Lf1xa6WKEBY2tk22Ye02ncR2G09Sux0bQ8s8O+5PTmnD8WfS
# DATA a+xufXdvc+dpLTLPH794bpsh8Xv+U+EGdLK1O23gY8l2LRtXFPXtYHIG+Tbirdj0libCvpdeMq0VIDuZvti9BDBzunmRjS2FpBf4
# DATA K+XGKooCeCQW2nTOpSePTqkqv7DX/2BoMU1ta8KsYBMQtE+bYZNGYWh+Qhmzkbz7XEW8+BUl0P4lxZT71rv77zQZfXYIF2p4+a2v
# DATA 7T9MWH5vbY3+wn/e39XVtfv31Dt5f//+vXvfipa+9Q38N0FDUejyW/99/vftW4uTfLR4mPUX0/5ZNLwE1NFfXbh9+/YO8M5wEeh4
# DATA AHe28XyLo/aQGS/xbHk0PhkNJscnIdcZKN+AVhYE+CsKTj2jRgGvH17l7li9BaaNOCd5BAL+BFgt9YjgUf0e5AtkZoAkOBRROAZp
# DATA LFVkpDsD8KN+Yp/qt83Iee+csboyGv12knV5DAJJ1BiIpQDwB3wSQNxODyYUaU0a8z2aqdCELkxaODCdBlZE4IBOT4eYWCPrwgc7
# DATA syIbHRBmFOcSY6a8YBv2Tc9nSx6VAKDzcTfrN7I8GY8vK0XTKHcG8VM2/4sstxZodpShcTLTYIM+pfdJOGzvqarfjFwKSoYkW9+Q
# DATA vxWeNgFvnjmD4Kw/nIzVR72824OdlIWjvkANWWr1TeRqMjX2QuAvbSleQUqVaHRA50MUdCPddJofw/LDdYAjX8PkXtDHzPXBjnX7
# DATA 8ONHlHt8HS8OXZcjdjIhyQY69pjJbAwzM8J2O+tn43ZbRsZiucErOAixE6/DiBmZUdJeVjhWx6xX8vsq07grlndq9/lrLVAxblmo
# DATA dXFTHrsJjzkrMP9UWYGDtmLeGr3A/PFmDYgQG0zGdirkWqTbVi3H4fm0Wiq4AQmszej1RJdX7jeW4P+WcbKUQRbL4EOzuRxfzzPi
# DATA nfR0MBZYlyteju3SeWuTiFPT7u5+HI0nfZwZXgYsEduOJb2jBu0l/aIN5R3UWX0XkaClD24tOYdk9PRJ/aPB6DwZddNu/flogHZm
# DATA kdlO+yv8wm9mBa557UwegzkWSKJmX7sDmkvMbV1QpEPN/bOvnQ5OQIwyikzFBhTTfylyVsyOHf8gypFirQua5g3J0c9y2FsUC5Y7
# DATA d+x1vHYCburNcM+ClN2PNzjZ32fiH42ipQ9T4NhGBNNMdT+nqG9iSSLr0lx0UqniX2ix8sTKBBdxWXhPLMaBvlYbUrYanscjTkJb
# DATA 35Ooou5CXdTPz88p51pd98phfU2PxZV1lLSYcBkgNB6rEfrKVVatuB14U7+7uSd6tOXqHMaRcFCKJ2zHOj24PqivoaODC9jCfzTY
# DATA bmnw7QTCKEq/iRe0zjXznIQQlDZkbZY6xM127CojVleUKsLSSJQpJDAEqjRUjR5Gft1ZegIfeCEJp0aDOSiBQxsdpyW2PYKWneR+
# DATA PJKQ5eiN1APadIgpiKBcf5p+yL1Odove+fJaRhi3tvJBLbq7tIL/rOI/a9dUTB3YB9FKuGtbiA8wRFWolu5+wV951sbQYY6OkqyX
# DATA dpuEMSJlM2kmUbVdlgIbUQlqJ2rRHh/ekK5iyuL93lcFqvQxWcGgLwuzjgojVJWfQtFO9PzZ7h6eCjIy8325cHDA3Z0OnQzywVy9
# DATA FfKhPoKDPnZymKmU291xQ3EsFJHNa7qGBfDdZ9B7YzLuhGQ8pY1l+YATXHJjDZVrPP4hot73lpaaS0uenTm31Rh/hjLosLeOlWqe
# DATA yqpWuU4rOGAnJ3cjyVWJil+6YcZcNeOVocKgf2hplPpn6Qjo0BzNRvM/nSRdpOkG44ST/2GQiCTrs8RZW5Mi5+egeMn4h62w7lSR
# DATA o1aQAeFlRrCqk16PYjRXRvH+Rv2HSf2zpfoH7frB1Wpt9d51zMmUZ9LwLxTJ2x2kjKyPsjFR710T7jridfAO5iiFiuRjYuX8bJ8m
# DATA QyJQmCdCAmXj0d7W9zdJPA2cF/BOaC4SP97a3fjwyeZjosOyU+An6fWTradbe/w2vRiiFgHfbn7yfGuH3w767RNOmGOa0ClszNqJ
# DATA 4YKOIW9GN3NF+q/6g/O+kgtEqqUFDshwinH5oJ8uJc7lTRejHMDGbSrA0beWqjWvBFZrj0fJ0VHWUWXsbV2KHrS4C/zxwdLS/eUP
# DATA Pli5u3Z/bemDD5YV10KlaASBQrNmt9UnY8dIRgFnd4IcbK43Ec1Kjy+JNgvMrI2nd9xWxXgScX/A7+NqYzIcAi1sIkOp9jSHsv2s
# DATA vbO5C9AX9vLxxqf45webm9/Dv0+fbe99jD8+3dzYsZmVso3KobfBCE1zqfvIDIutRZIRXjryGz8ojAixAHVkK+307M0413U7Kqg1
# DATA VYsO084AndJ1QfsaSAofPnH7uJL76kgeHNin1bymAenTbST3fufPttsfP3vyGNu/zCN1B9YjunB8XRGvdUXcqzk4TEeUnhs4YgAU
# DATA 61I1jOI0hLjbdkSJH6ajASDQpJ9H6B1JF1ZCStigohFtXpwkk5zspTsdzj5wCs8RdxDJBW84DC4e5octv1N94WA1l32rCVlnOlMG
# DATA wijwcR32p6GN0YWmmOtyt3W+Zw7/pI7ILfuMeJZG/pbtqLXlRY8oNbKqvG4CqERHk/GEtqqPtqd5ROaWRq5ks9eho2pUWzjsKWfo
# DATA RY72KZy7BAia6DPY3HWgl8fA1vMQT5PLCHrtMy5IeuT7H+VDJPgV7EiOyQhxwUHFVwZtNcVGVh1xleJYw/YNZGANncH3gT/FnH7B
# DATA wCB5rdQUKwDs6ssr9dXlvZXV5t0P4P9/WAilEMtIn+BufojegtCfgHDn264CHE29sKgrJxS2hfCxn/R2Ea9TSBwkVylRHJrzVAjf
# DATA V6uFYE+xpd9Cy1s9EwCFEp8xDmEulj5328k4LpBp++rrBmdu99fOqmultMoodIbpQd7FdtKMiQVMW2gYXZFS1agOe3rWQ0dAWrXB
# DATA j1iznJ8k3cE5Ogrm1jRMMzcB30OU7HQGvaZ1F4TkIqmrBKZh6bOdTlrqAdVFOTZqytUU3e8qZtSsHafHF7BxKHeqWFNRkj4zwefq
# DATA DZW0p+oVz3NT1A0uoMamUJ+sp+/G4PELSuAtpfdVK2ztxbOs+uH2Aw520yXaemxGDOmKHK0UVWbV3B7USN3bwGyI7QkhY3yfaBvg
# DATA 9rkEPq2uzDPm52qsWh7rkKo2mSp+HPCTSNVRKhnJXNApV4mniLeooCoobFV4ZNuDqHiEbcmunUbDovqdACjlUm1Dy1rmL234roBH
# DATA tUFRGy1xqooGBz/368sH/jmZyjYs36vdW0O+AbqrzrMxtrsti3GVvC+J8hNUE+GJYJlxLz1OOpcBG0lZwOL2xNQEnTvyEZwcFtm3
# DATA msZs2rKKktYIJ4a6mX437cpsvh090lsTAVEEh2VMIkplrxSlZzCH85OU2z8lyQ1h4ARjIaEpDVIwwpAT/8iQKEt7XaIyHZbNXJwi
# DATA WHEhB0FTNVuDL2shBFaGuQ40UJRIzDwqByTJF7UurEVQxwyt7ZCqUV8pLLTPb9PiE9OqYxwH0TfiJ2rNfNbt2kUKajvTNixOdtwn
# DATA dHSVw8rySXBFG7mTki9n4w6KXKUvTxCJU5DKa/tAIcYzIwxWOiCgpYZl3E8U+Gljp5VkmDmstwKT8F5JdSskfUL/MrSzJzXz4uFl
# DATA XZ0dssp3YAKSZNpdKDlKUTFm1AR2vA+j+rRNsbWWtJjK3JIlwbbAGWwzjuF5WDkmD/FqKU+LnOTMRC+ifoc0O5h1lnUZuJYGRw+O
# DATA jvLUEpMv1aJltoJwG1Vxpmau1Xe4xZaSHPIjxdX5IyLu9Bdu3kVsROOGY7/QJw4euR/Tk5uszPlAh5tqFE3hsaAR4VBwFsx2MB9U
# DATA peUX4wMVjROYOVJE0w6tszRQvUwiCmIXAd+dDbqx50mGxqUShXNfRnNQ9EwsipyqHDrMVxOVj/vxhJUlqZBi3DU5s+UUzgvHoNOn
# DATA eW54aR9tECuhcVTXeS0U74IPVT+hIJUgT1raEnfMh0AUv/JRobMgOEyrmYehVsrEKco2UE2b98hgfqvdW4XhhRvdpCaEB0Whd4rK
# DATA KZFpkDG3E2la7Jvq3LPyYr+SyTXVbZWD2+QxXDsQg4qo8GCTvmfSTe5ZbCw5GQ8n47K0bmX6ZLaG0UMmaQDuwSHqkqGdwwFa02Br
# DATA cUm+XqdzgGuD3plS/OmyElbBTsldi8jUV8VvqkV+zIXsyKpvTwpPRNK/rFhfARdg+9V5RKowL+DgI9QTXCIj4yyA8p3KG50TGFDF
# DATA ArLW0OQ4tdBWgufPb9ra2sGmfK1iDkZC/btlbsPxVh+92N1rbzzfau89+97mNgLXHZW/kGygWD0c6bxkSkTccpp6urHzww83ttsv
# DATA djd3tjeekvhFyUyTLhBP0II26bFysmkyPtzc843d3R8823lsN6eq4JisxdFGBfKoUQZSaBpn0FgWqai+FiKeUD9tnq6pe7sWrTzh
# DATA V6QJ0IO5zQ0xXiDWPyf3USMACyKuTEiJOlfBiA4GPe/HmUdp2MwIHkND/7RayqaZa7SpQUP4cPvV2WJgrs7lDUdF9wXb6drJLg3S
# DATA h7m6ZILiu61DTOMj1NvOs8+s+GI11lTmQizsG5JVoSnqY4oP3zC5REVtzRbtutqXwOLISyPvVDbFiicD3gLZMl/ry04C7u4yjWe9
# DATA qKkxWbT/QSGOsG7Mpr9U9DHFtKhCusnq3LjXggS0lBz9ijX93ezoKKVoV8wRrFOnA1gzxCVA8XrYmIzPdQ5nGQpdC1n7WC0+vFQ/
# DATA ba+KZnC6Vrhmpcd1p+F6oClD6FqEBhylNtHUHB0qM2TvgvsEBSeQpkxC0SwLaneESvaodCgConlZ4+tSBG0HEDZomW9EzKPHRaMf
# DATA 8IYOKqUsbPon91oJ9VCvdCSEQjO6MkTGNVKHSfcSXgIHS66Fk/3bakNuc56fiQougMWVbJezNHSAPOGqM6qhoA7Q9jiX7nn41evY
# DATA HiIJb8gqUMAGZ4WAJppa8W9SuGiczG3NgmHPRymM4PhkrPXmNkYEfp2J50a0Q5qPyGyD67jSHV22gejxPRXix7B78F77g7FinsFg
# DATA 8eq4Ht4EuLHxSwCsOGc26owf2abFpMwfn8AlwaF9h056BBUQzZF+4TLNCw408SM8oL3y+aIrkTUYoT5QMC/SYRRhH5BQVDZcveBl
# DATA pCeTFYUCJMi+24waAQPUgXJ6HQETB+tKjR0Ai+Vw3QT8mw5rjUltIJhfkKkrNbfyKKgS4oEvq4HIhWYElrlnM9zbt6MNY5uE+hWg
# DATA f3sDQLciY4p0SA62QCdDYgxX0e9kGA2ZwkVHh0CgdnuXzAM2gh05nrlvv8ThZVZsr8Je8nka8iq/yo9kvizNRq/XDM/3KMX7N9T3
# DATA fDww6xF068ajrrUgJgtxcU4klr7B0FXT5s5MbTxkMjcbdStuH9BQJzXTJrCj8LUTZSh09kqQpJqA3PGDILoUWjiAHi3sHUBwIgwV
# DATA FMddlWLD3Y83Vu7e233xdJfsWjjDk7hBNPKTBD5Whl6Az5P0opsd4/UkMU9EyGPI6QHh+WU/ZnUQUcAkj7c4t+Pe4LAS3xHQX626
# DATA OJQhclewmCzTbTlCtw8Q1dmY0S6k33MxZdbmlOGXWMBgHX8vZiK6ZEQya1Z/rUfWcpNcKaeuJ/Aate9CegmeAsqPr+mgS5cqDjoh
# DATA v5H/cdGbleghNKiNfSfg9UBxC+wE65T04rJSc/XEkoN5OyDWpY6si3JrJss5WLQElr21DBx6qBOi0oqOwbbtl5Idmsasz2XDAfKk
# DATA zmG5ErISbMUcUmsMU4iDI7kkNUGodEkXihOqCyc0rbbyBg46AuNJWyYpucsD4qu7S0sW/cDWm5XYLHYzWv6vP/lf7qIdIPObWqcY
# DATA 4Ol0xg5xN53p9jnLG/OGvIjlsknmw/9m99n2Y4pCXMqqMMB5M45Dv9VAhrIXMFVJ9CXKbdhKr2GpuSwAQN0DNYwBLqGJlrhDQbfV
# DATA cg/T5XfqiPl7+s/PEPF78P+8u7K25Pp/Li8vr979g//n79f/89l5Pxr0gZgeUyyfbhodT5JRNyJ9xXr0Kk2H5OWEFwxwCEURILuU
# DATA S2MDdQYXEotP8wTNhpJI7e3dPE8m46ynn8aJ9tU0qUq0H2h6OsSrvrCwhyaCkcpWh3JejlpGs40Xdp4921OSdo55qcvVKQDakQ7K
# DATA uPBie8srmxO46MrfsqoNFZqoaqkZ7iDwdjOxkF+LE66P1bNuphiuR9BPnGAwf5U00UmGaEXXZqzPL6ck4uPe6V87EYwaZz8dnw9G
# DATA rxz7em3spje2kQ3bTknKNZN1xrbk2xi1I22fXfRSipWxFFHsXvqQ5e1T+AtEZT52X08omR3RcD69aAfL2oikWEecDreeYzuwfv10
# DATA bBs7xI4CiHNLY196f1AVjuoUaAQmk59Q+AxY9cNR1gVSvBaZ3POtJe3ky3Ho1FLQs1AdWJtk9USeo45YN1qNfhxdraxcO0oz+fIw
# DATA uremtDFIjFWGVSVWzDg/nyY6hvjPvbt3V+8aboBbmbZiSpqHF51Ku7o7mS4OZHnlfTWS6dY0jSba09SW76I5zSHn/jzE0ajG5hnP
# DATA YwzBP5IqyuYtOc16ZPOZDe+Ru1rcjFm/a4LzZcPY1SAdxVdc8TrK8bxGV1T8Gg100YlQCCQ22m1FlTjLjoi1uiI+CwlX5tJsHzxr
# DATA VtaWqglymptId0HUjnxUCYi1BQnuqjlMoe0lk3dTRO/zPOvIEccspex5eogRYmhhxp1h1KUmr0zzetTkmW16tcct9+YojmPWbmd4
# DATA v64I0l5HV1cLaAUB7ZxybEh4Q/OkYm2BhcAy9hKgpgXorEfX1wsR5R0Wwg6b4WoAx1FGdDIYKKIP6LnBCA2Y6stLwASgCvVSxr0O
# DATA tdQW3u4NbstreNsZ64C1vDjd0WAI76/4rKDUz1qRq+jK7P1pMkTitSY3qnoNozUNm1p/bOasv17Jkl/bQ0jJLCDLT9JuTeUL7Sg1
# DATA KRuuI6LVjZym4yTqrZGdHQDes3v1rHMKdxz+ObvHqwQj7nfr/TQ7PjkcjIAfhUVBW1/7ZdJFbRG9G8Gip+oNTgcuFSzxkBXvK3fv
# DATA 3rRzh6Ptj9IENpMSmQ0TTKdRHw8G9cPsmNFMXWn2KVkt7BWOBTqACqfO2vIembNxxC7PJadDfZ1xPuY4CW+8U1cCS67twcP/w10x
# DATA seM6KNHSAghBDogEFsQuVjnFFYI/xACp24+ebW9vPtrberbN3lFi+eiAbtMImYascXAP/RItJAGzdrNjrGgxajgYskdBhs0tH4rt
# DATA g3CQQpeiiRMQJzGRmznSm4DhOOffHo5w3IUDxwPF8uEMuA5OoRv1svteTJlUg5n5nMFiIbUS+3q0hVCP5WntHFsskSIrsG28aEjn
# DATA TVPtEpLiZIaE8smdS8KF87Ekx69RBrvdElyGH//UWxCzc5lttGhrIOzop6V9S85fdIKHhlQf3sJx2qFctBd8qJ5J2hjbKN5YENEK
# DATA KJmpVNdxtBs8koYMo8HFG2JH5aWI8f5T01giZMPKlG3SlpAUQ1ZMUM/hiEKzcamtbnyw31xeUbusKDlGxgylNbWmiTpOrEsoC1ax
# DATA p2kRS91Ni9s/GrNnHgdHoAq8vim+IDynKHeXxFUtNXhA5JZMmSLKms1jtyGroo/fdzgMjdIaJH2mE2jLI2ibm1N3NOnniYIhlaO4
# DATA m5KdVhFdv+Q42KGBE3kueB9JGloyLXtS06l36N8j+jcWJsbqv1qsMaWspAxDNHqe9buD8wo66Mtvbcu8QUikq2cNo2RfiU5vgO5F
# DATA ZMsMs3oEuO1wQJQUcrkY7SKSGx91RgkAdZPe+w13Prhh05qba8ffbNetmwCLtD2IBudoQ8x8fYYmMpQxAbVLwDGyDYziUXPAd1mv
# DATA x/FJpy5KTkvhLUmsKZ94vvUhOwyztSFba8sB78XweJTQXYo4R4zMiVSzaIKjQsvwJSfzi3HOJzZSeakadnTYstNYcaMAYrqKiE14
# DATA LRL3xqTtSyt+BrcLe4GEF47QbZsp3Ck0pd1WtXi7+KaTDzFfihmbFROd+z65dV/HYbAW3Ci7U1ilN+tR1gh/Lt895TEoKGDH7vU8
# DATA /Mn3Y5ohps0M7aRHE45EEUl5xVF2ayQoGowSMrdUQqPG6SsU5wxRj9airtiwkhzYj7KLVtyg81cPxS32ok0edU2USWzbizKJvfE8
# DATA eYb6q7aQ1AMsxLUc5Mbp3xQyQYspBFXv0rl2g5z9ZiRFoK7nEwm5SgNqSqhUlxhgVHLmGf6Q4piRbN2Sjk2OzhetODJ5o+tLyChV
# DATA cdXs6zfNDsMIUSxDgsXG+UkGhGcM79yAA/CiNJMvT7pgPqve87kpfBY/K68IWdgGaiPwqiA1157AHG4RTwDkVwpPM8qTg/MfwblZ
# DATA WlmZtj4v+uhZEb346AeRtV+qXduTiztSCSYtrRLwiBLXSBXiYfgwH982dttbuzub362oWmqsNBv7ZcmE/XrFOb7FPPmOo5xp35gG
# DATA b2MvdHwOXgJCHvcwf6l6paQqL/u2wpiDjHZZtq5LEG3aYggunp1myUjxj9JcTufpLzcbkDnLiyuglYzLK17Gz7I2Ksqn1DVncRkw
# DATA qJN3EhQ60oIQBRjvL9U/QPHe3etFQFEvUTPLbVWngmBccRkJZQWY9E9lddjuIw9BUkcA5XmZM2rgFhVYFps6G3y8F8UyzqqfQagC
# DATA 15pjgseUzV7lwArteXltTO0wRy0yuTGLHo4LZpq1klkbdD5vX+L5TLsuQHyeqPfOAIuDm3r7v4YZlM4ibGTkHQg5k+9oz+3I/+i0
# DATA PBr0dNZYVhGIeuCNcKC0yFmsTwdnqRMY500xlIRnbhpgcDP9hEg6C8YNlnYCnla+Ee0EQVBZJl9N8f8/DKwn6mAljSv0fgIj1FZ7
# DATA Og3i/7eGpP1vhL4eIva6AfoOL9IspGoZwQCKo9hZjsjxpY/xH3E3L12kL5276P45bYXonSqIJ5P60Ub9o0Zz8eC9qkL8FYNAK99p
# DATA 1sxT9TtVH6P6u0KjnLlGxcWZinH9k6SgA3WGYlQ3LBnCJyYhTKVbLYEtyGgzBEGFCRmOcTMrB8o5v4ZGiFTDu/3zz+Yw7Q3Q+2U8
# DATA gIEMxifkPUOCDdtjB2AuknDh/YxNhFLgv7UfTwD8OojjTmU/gNgOrJUh8msf804aZIcGDrEJ0hGPB4QL+5exRkXwb9UKmkp2Z/bF
# DATA nYl8aRqCi2QWbqLeGdjdw7TiXa18B782xKvn7cxDn6wwTcjzK1Ans6irYvMlSzWT+nBDMeBeORy2vhdkOVO4Jc2FG4/IW+OjeP8K
# DATA Vu76pkBJNN+aByH1domGM0g5z7mR5jDOlW1JHXeP3AqssgiHKYOSrJdth1HTxBlPkB3yUQY6amN6Ddu0ZgoxBHuIRkEFkqFCb20+
# DATA appuQ4oXKAcyePE+2dhxBh/FGJCln75TLbXq51f33IA1i3uWDSYwQdJxOsn1aNx+Dm4biRJrGi6lF8eOJO1sCuFlu3OlSKIyz4m2
# DATA owAVnJzTrqmYVWrb+cTkkN7nkj6owA4nbIrZKMOq47Su83KaApbrtUUz1ywFodHrLqhbQKpCx5ao3I7I3Zm3VEWhjI+Ulmqb6MQ0
# DATA hohzAjtXi9C0zbikYnW2rIFmXDRULnid48RapBrAPNR5Y3tNbtUXflhiyqqRaxTHp0KZsLW2ohZaRQbIRyTOGSoEV/VaC/N9ThM+
# DATA wA6sPR2qNiVEarfdW1VS2dklywbpSjKFNSMZSpznJ3x/muqUcax4fAnvbFmte9+a7jQwzqi+Kk3rjlwXBomnBi9TvP+in40PFh5b
# DATA qMdQXsS+CQ6itVjYQKevlsBetMBvSMwtUSaLImXhQ8LpLbIKpBAxUm5hf5dLHCygVXoLdjg/GYwXNi/Szi4G9mtpq1exeI2mmXYu
# DATA qh3SmIaDFtIw0Ra8dZnmC/tbTGUeLPwgQWvyDy8DA4tjD1/GbBraGVNytG4C+L1fH6XkMDitZNpXV322Uanl51TQcNsYOIB9C+6B
# DATA 3sm30HJBnWBDi5qOiJ6Rii6cAty6eFOdFhUIm0mPTvc6s2gne4g+JWcvmoK/Yjsh4cv4VZlq3KdEYfr7BE/LJxg4GRweeJ4ND8D7
# DATA eU9cSVVbwPU1JmhkJb/jIWRSzvG5k/kDHuVfiDtj0R/WUaGmH0jVT/robGxV0+K06ckHGXhOLUIAkzMPhlyhlqZWToaZX3XOLIdW
# DATA hWkdEFjm/JM3ylSojEJaenV9Lx0hWCT1HOGW/ZUVilkhwSMsoqXMB9wRBiHZOyWVW7wjBJhnnh0csrPHOozEdHI0rL3zsxaiWclR
# DATA doEBlWE8dbadMN6bydkAbb8wF+AiySFGADXyKOmMBrkxrRgZg5ICE/ENEPaq2xuzHW88NlwPK3uj2gdK2fhGGRs9/TnnXgxr0O0c
# DATA jcIah3M0Bk6Sn5fXFoPvc7w4xG0SOa4f8X2Aa12aXDMYaI7CaxWSOdhJgPmGefdKMwoc/MlwIa5Gacb1cGf3RrzeQiCHujcmY1/j
# DATA sVl08TUr5c/E4qdIiWAvrx24vpRDnJnl2xLiuF47N9DJOI1N18XYMeWgoK2rLdeYeWwFTVglAT6oRfLsTP5gitwqWN4Yr96MxaD3
# DATA 1RlHjrCvd9AsCxEfXxTyv88JuN/dIZ4aFIMvpr8LUycxW8JVtjbW6TaMGsDCarU8esSs+89E1Lu++LNkHSUMCBMShTPtKRlJbU9F
# DATA NAd7UK1aMpLydZpyNjmhcQnV6B0s29y0gCd0E9Ok4F8bPe8sqM9rIJMxF4s0PyNqxdp5ZhmPMsDprkesb1FTECGX9rPWUXhm+6SL
# DATA G/q3/vDf1+//jUDna8wAPNX/e3lp+f7yXc//e2nl/h/8v7+R/0qcspN8zI7XJBK5GFu+1/KGtcU6b24HmVLtXZ2ORv1BSRbfk/Fp
# DATA 74au3rXo+WSUPh/k2UWJ53faAdouD7p+m9y/lLF3YeHRxt7Gk2ffbT/f2PtY0X1G5EqZ5REsYS4KuRttoAOT3uAYZbTVhacbn7RV
# DATA Gx9+ure5G6Gdi5OZj8o83dje+mhzd08XWr63+j5/2tt8+vzJBr+9x692t/Y22x9tPbHf4aOujdZ7Vuubn2zt7m1tf1fXge/uB1Xx
# DATA 3lpgcLrU483ntAzvL+zuwYjaGK0UFeMNbX/L2H/h3zx7sbO98SRQoG55aEhh4rACTRHbt7Cz+Whz6/meLmBaOkw6ryZDaeTZk8ft
# DATA 3b0XH0KRw/jBre6ADhkdoIcP8N+oB+ikdTvt3374gJwQAb+MMPr17cn4qP4+vCX950MRBj9Y5McHQ/UGOTETpODB4vDhg0VqHm3o
# DATA tx5vbu9tfbS1ucOGIBjqLkOyJd5P6p8d7LM/c/3gaqm2dv/6JaY8+3jzk0DZIzLiuLfGZSiubGmp1RUutfnJ3ub27taz7V2KTtfA
# DATA UZG/aYeTdsAS0Z/8jGLnNMYXY3lNVHrcuJDy5+khXNXsCCi/+FrnGN6FxWbu3TDyxVzU7WGSjfIKiWp97/6razumfs0wwlQ6FFmf
# DATA q4b0QWY08eMXz59sPcKDiFFj2t/b/LSY/QBj7zuZKZy8B2rsuBIVtCGqNoPaHSu8DEdJoIBa1WAqVjJF6lIIG+Do8GwVPWos6pnb
# DATA Gxxizmdewza6n7b4t+t3+KKf6cg44Xg5tWgn7UxGuYl7U4yfU1jHre3vbzzZekyrqFIjcqJzWR4CcZ7XhBep3cRqqDrGem6ikuX3
# DATA SXYUv3xJzvZ+wnF/YC+2dzc+2mxv7O5u7hEIjo1GEqGxDehtnwfkBZVyMTnMB70JcKhVli2M6AuJE/gYSshy5ZrBoRLu+t6GM2MV
# DATA HNhhC+iif0BRC7DJoO8ifuCsWw26fA1Op42vG8Ds5IhcKvAtWNkbRuU7TUC1Px6O+j9OJhc/7k96PwZ4sb8Mw/pxbzimH1Uo9LLR
# DATA uFP9jowKWf/GVpE/PJJRKKWoWhXRzjTyydFRdgHH9xx5NiVeMUCo+gY76uSal1PXHRBdf+Nz52yrnL2H0crd1TmuwONnTze2tkMG
# DATA 5BqYSd5NyRXTiHX+5Djr9hN4VHc/yTtZBs+yUPZNti/yTW6oGp59R9WB52B5FHmEpzstxIacWTgSNmq6t3ytvtApAVSX9qpTLVOM
# DATA 4zaWNaBb2eg10EbvpgsfhNEoNxbdm5Ybu1Y4DBQQFhi/JZ2lIAQN8NK5p1wdcuQydUsNOGknjkt32bkmwsw61rgwnaTfxWRKhPD2
# DATA 74ww+GiOjsXGFwz9i/HxYIoulZK3tkxrjZ5nbitH6yMgErYH449QlhyIoVrIkyUZAMlC98n29yrYj2OdewzE0hjAJn6glDpM/uK7
# DATA 7HDCmXSWqij7v1izI9MF14kWaPfTp0+2tr/nJsoyy0TGbbAFSh+jh/d4a8cd3ozO7E3Z2H4E5PWzHbfTyiDn2JcoVBgiKmE1UHmX
# DATA QVMtu4S2TFbD9z7qpr+/90l1ntX6wc4WWeaUTMGsW8taN6NqAqoVZThvv5o0mO1ne22ouPkIxvHpjQdCQim2+C1YhhfOnXpBIik8
# DATA FMtzjxDae/FkY4fYHRek4LgUQFFpLsYnLgSxIY0RfxWusr7I+1z0jn2hD6oFB2Vzc8MS6fZp8ipt6/Wq6PKUzeLu3fLbQoDKNF+A
# DATA VtQ6Tcpqs5DsyFkadyg8QeuQkF6tzXMVegqwGD97Jl7lEaVpvSxNJLU/RS4Kd9VsWYND7OqKhBTaR90W98jtFHdS5ofCaXlPMWrK
# DATA D4AlR2VH7JZSPT7bfvJp9GMNHgdo62TUkAwUC58/3Nre2PmUPoYUlG36l3um7ijI/iHrK4HiSJPTZtE5AesTMuASDYTP/UGlOt0V
# DATA g6s7V868MpfOfS/+FYH8suHbSFIJShNrAQthlGS0tBccKeg9uOO6FAfznjU7iVBDvJsaGBnYmjFn/UHNm4L9TPnZ231OK1ShXnUt
# DATA /cSV9KOuM4UkoPk/+nhj+7ubj10ghIOFk/jHnnRMuGhzp5reIdae446OXqGwWxqFmUFdYkYFV2Vs6TXDB5qeNIz31esqYQ5Z6gxG
# DATA lrbeopTU4Q2H+PF5C3RyIuJrf7nppdTqnGRk2mn6QLaFGtcX3gym6oMLUtBUygo4s6CeQgSXPn5lzaB44A3xf1ls85uQALzFZnBh
# DATA b/3gYggw9GGOzu6EZhTvEN6XnhqnX3dxg8rVEvh8MwXqzONRVJPaV9hdb+uLcx0YSfE9K9ipBNGW7AnKhpQkuRISSpm8EYzMbEF1
# DATA w3A5tagggXYY0QK3MA83ypBN2ny6tbu7tf3dIk/qDFeHUJRx+wIyHXwifjkit7XYcRYxbvSqW5RV4XMBxXEGK87ITSIU5XEu0gEp
# DATA YCQs2BF7m9EHyrQubxH/zcByin911uQx/LVG38OUZ5QRkfvYJ3kTD6tpZ5dNLzCAeM6BlpJ8zJZ3Fakv9zJOz/wkw55MxDTTOBx0
# DATA MZEUNPVoQJ9JFsWhMbxiDRGViMERYNt3MHXEbzIXmUUbh+/37TkGDkcVrEgbINXewVhGyTnFZbkYa4mNLZ4NC1l3L/vj5CIoW52R
# DATA UekmYwzIc0ick5wjUVO4wvPeTZvwEqKLRd3YcIlAjeXRnAwWb0U6FuLqFuoW8s5JepooS9mcRZZ0mrDQvvp+4Dtvu1+9izXXSikS
# DATA anCei5B9X8ZwUDITLCr5QgsiafxGEmlHw/aGQwqoOaB94hGhGwc/Vopj9BYb3shaS75jVEOxh6g2jyZP0Kwn61/AWsU+MN8Km4AZ
# DATA MalRWdmiQVWWiuknI9cL9aeEjF6fqHpxu1RvGyw8rSohrXqPh/00uchOJ6dl0f6wr8GoW0HtHWxgtLrCnDk8yoJLS1rZpBrkTPZq
# DATA OTH5BGakd1d19d5S9aBafQNgY6eLzcRZC1ePt+lgCrSmEtYhwM+r6pzSR31Qjd73JiOkCk46216X4hOb9MLq2DK9YnlfUP9h/wvW
# DATA CgUTSeHLRgfoL+yqQhlwpdNiil/pzByU+OXF0hKJZdU45JTIow+8FYQ0CvA5yOqpCySziK+uWCp9fe0MRxH2NEtLU0Nq1+q8ND03
# DATA 3QbA82jz42dPHm/uYCjWvc1P9ryR8MpRZFJvXV1RZpz1u+kFj0IpZfgo4qKuLa2FPwWhx1WcHGJEUaVJpqdFq4NrTiOSc0BXOaZz
# DATA yed2Nv/tC2AuHwOl+t3NXUM+LthioVxOJ7frmF5jEs+xyk5b1Y57+vi6bxQ/0veUhXRslbCOZeCmTeSkG/Fcs0FyG/btyZMtVH0V
# DATA 1c8agh4wQChVb3i0vhTZvwIQ1tRQzc5KX5mGH6rXNhbyuAkm9OA+HxhxGBlXMjIirVtBg48L1lRXwFDr1hWpkbGFivPEzdQiyrjO
# DATA VoRVDRoKl8b44ULrC0XlUgEuid2nDWIVlJJ09HJWtA5wNthwbfRFjaXWivHz5HRag9PrvwEdt7O5jXDBJuNCZ4e3j6yP9LpjqD0M
# DATA MC0bya+R/hOtqmyzTVN5x0SH0ZOWFOBwaZqA0uV7289+sM2QVVFW7uCt85bvq+YP9NHTCr/LfscWhFmyrlZA1jWfjGK6+IrP2U3k
# DATA YUG5c1ByQYIknFJI4BD0h5wmtLFdEZlkLwhtbiDN/sGOPVnHx2bzk0dPvnYxt4h+0DenRNgtwl9Jg4cMif/pqDfJTypOREte74Lc
# DATA WJaQ72/XS0hCJ9RO0CAWBmk/x1wopNRn62q2Pm8DPFZJ0vMUA9DDNuUtjE5Tw6QSHP7iZd+yE1Bcp4wDKpxmnUBs0pKds6OM0qm1
# DATA zBAtQztaKgpzTQnA8J+1CmUAFOUIr6UV7dNbkYD4dorkbf7rN0NMOE800umuuqHacrWtW56POm3n7sJFysftkutsoFHD/hQKi2r6
# DATA LFH0lUVDVR+Cwn9nwd+d/m2OcHgmfqu1emGxJdw05P0GSqEmETR4Fvjg6S6YKRyMS70rje4C85WOulbwfEoBCI9LDOwApXDU9X3p
# DATA CDg5XqsT9NmS702XCxqhC+6QwKQUaAwHw0rVO/CqrOsM4aARR8cyA1MVdpDbL70wpTiL632tWAu+jrJUEEVO+uORhY9wqvaTlZWd
# DATA SDqZWXHq0m4zaH2GH4nILS1lC8n4YACBxUyyZ+yMwifa4odR0Za5WWrbFCbI9nY2i+pM/05hPhwOLL7IM6ENCk+BdUxcirRMULM3
# DATA OFd+vnnIj8fcEAxSdpYqNKCe2+MB38FGgj5mcPYq1bIFnG7oQpv5NvY/ZVqbcOAFMzHaUZUlohIbP+GannW1vL66yqq+UEl0ClDF
# DATA HK5ZHvZhDp1TiUJQ1OUBU/s6w6/mVOO6NzyEBjq+13KGUlqacwLDQfLSB5e3/3UYQwRDbryFgUTovxsYTZTs7Ts0pLjlbg/ZLagX
# DATA WX9AV9CxY7BrwGO1OdM2cx6zhPJ7KCl10anCGfnUaoxwdeXZYzwUv3/bIOQUeFSM8XqvZlqqzjZFlf2hFmd3/LYLZK5Og6PXVajj
# DATA 2ZXMytZZzjtHPRZS6QVa/po3fz7zm5KBfuPWN+9y9gX0Q5HGDOYpTkfOgJVcvTqDtS8lm25gqCAUsgeyNROnRGRCHrnJ37WMBd2h
# DATA PSGLtpd2wrzbVtShKCQeue6oG217u6K3m5t2qU1hmmFUMjbm9WW4oW963JU31GS+yvosSRVJFAlTSRRl9Gz4GXibor7tzXSf5jV1
# DATA Ti/jUDoLv7vAFPfNwOfR8PlVCu4lWkJIBWUhDmjV3FcBZQ4XEIGsWfvCFLR+y6kQ0HOV9kG74c33481PihOlcnO5ILBt+p4RVxrJ
# DATA s9BHWT9yBlxUjIWUYgEdOzU3dfBU4kaKSHvkcxgaIsIB8ABUcW9wiYGgQlJD8xV4Ge2n6VDAp8noFSGKw9ABrp8tqxRDriDJll9y
# DATA EwW7pE0CP54PQ9EvwjPnTTH+LLVHR5Z/31QjiFONC64Vz9MRRUYQ+4+AzUc52vnwxe6nRTsPh6u3aVs7vNE0ojogowutkC2N6I/j
# DATA QCA99no+zc86o3HhK78mh1ygWSxEVFOfnsDJ+PDJo+/VbAvecq6qEC/LYS2sSEx2V048JlgX63n7w8JmSY7Gd7BJ2sry5qaVMBaK
# DATA YlHppUfob5cdn4xdRJtf5g2ExABrTm2rtRgQ7OQiLmJYunocLSs7FCkwO9Q3Hj1+8qTCgYonedomx3orgMfRpK+S+KkjJU1wdDw4
# DATA IMl4BY4VOVWpQepaBRliYUCqaCMZHdOIUBonY+u0KeCdfkKDjfbQejHj8wS+H7i9YIAa9PFuOY0U5aO49sQf4o+2kvWqr7wn+Jl+
# DATA tQNCVNVjxWmACGMR6eMHumHVmtOMW4q+qGIrlEp1KZSrjsQjEu64a80Pdo031SjnqAA6kdL7xub2s91Pd2uRPBFM00/Pnm8/29t9
# DATA 8fz59ZQ95Ishl6fSIRNVlPwBHtVvjAoFA7noiPdW0l5Heq2+m5OokIsu74mFrS8hyXDYnmITxSsbmMiWZS27JvLf/JcscEdmXq7S
# DATA 2zPzBgVns7H37OnWo7ZSAAO+bb/Y3vj+xtYTNAG37Xi+kes275UrXDvedhbM0M/C1bMPDBazntsliiN9Fb0m7Wsmhrxyz4qNuqXt
# DATA syZVlv0ok8Z5ctp1LO7qzGuko02VImjSZRFRGbpmC0UU+2bnidVbsnK2UsC7jaJPuqVMmRv+PrWViturokEGR+2gsH0WeekqPrXZ
# DATA CQMKy70/GBeRVQ2mMTXKxSjm3vIYf2uiFNk5B96o/lpWI2T/yO+R7Pcbz0WxoEobiw/5Pqez8Icbj7734nkbQ6hNc36mWIdFYj0s
# DATA AlB5GfsA7tBajAymrLoFTXRQNDBKzhWbXcIjONyBiQjjmXpM4/yLsdlVkAEnYYJJRKcNljopUFrOAUpGnRPUCzTL5A9SAMZqx5SZ
# DATA IpF4BzIFM0AtQqhJoLxvWpYg8XIKIgVh6s1AqYXiiSuLiDE9GIPL1soldgyl9m1GvSiOUAtCS3bgXHvtSFyQDkjp2eIBKVitzi8h
# DATA 4Bsb25SMOVnmFjhMMrse+MfQLlxyOYKlq4FUBvrAerAALf3t203gDkZTAJ9EthghjyzMLKpLwJcrVC12YeEHT4Rn/BFCkgt2iRyh
# DATA WU3qXHYLi9Si8eBVCiTkoNetRf30XII8qixJdowItQ8h0LZgIq6XDJ29j62uHTLPQhEmLHI3PcM1teq4H+fiSnmNSR726e7e5lOL
# DATA BlTHw+kCDkvFipOFJkC0RJZZg+fgLc2Qp7mdFXjaTlpinPCR1k4mwZIuDNZSaw1Em9GygqPNqfCsViC+bGDWDEAyBYmbdGSK1fns
# DATA N6O3uUp2fgumiRR+UueMjWUcHBqfn5+z2xkeQgBb4ZOKBeDDzXyPBSF660vnAn7LFRJ6SbJ1INlgn3ZM5tHryrIBPZWew2+8cM4S
# DATA Ypndd7CCXqtqU+Rux3y58QX9uLb9pvRpItysTG+9GHt3opVZK6hr2Np2Za/n7Jwd8I4NMoMhhJgmOsr6WX5SBs8cOahwEJaVK+f+
# DATA 9akvOjmWRWRyXCjiGAdSiRBksHIGzQNRCl0HpY8uRCW8zadfZlPVGZPMJzUQEpNACwE3YJI+qHI1tTS+/HG+AbQwfde59YVWaErn
# DATA WrQnTdR41asBb2XmiFxEY3scyibXzPmr+pZ6eR7MrzHrKHEzP4Ib0idbudIza4skpXhR/ac+vLEGUBqolVzHtye7GZy5cEyglgCs
# DATA mgWfNCVuwMm7o8nnUNvRYD0ilSI+FrVYXLQapt2tyR6oMPn2KQhR7kUmOkRNz0nQh2PI+RQ+7sJBLdIPvAkBkj+4Wrh5cxD0VKyU
# DATA ieBNnpuLkOK616CvlBdazUBJO05nrOat2rwJx7G3s7G9u/Foz3gYqSjsIYW4YWqIKi3lnlzWQRpi0ec8eMM9mAs3IUYDVS20Y0hE
# DATA g1lmYr30YgikLHk1WudgwbJyLB52CRTPjCfeG9XIW+5Lex7xyCxGpDMZkQyr9VY0lOiJzhR2wj4dvFeTZ7P9KndsjslzsLy2J6EM
# DATA DuHlLLChavianzT33eTZ6dFhMetOX2hlWmoAM8X+vK4uqcvpAC2gszCNEJkmS7JPh0MG3EBEIG119dprykYLWEuBkyUHHmXH5MDl
# DATA Xi236oKrFC/Oi1upTj/0N+T2zR07Th06Tm0vrjo+64UI6kE0RyQztbmh8BjfYJyGbHR7qUX+BfBJ6fA1QX7Dm6VU8E51+dzNsQyw
# DATA 1zRU02mAxiX6NkCMWiP1A8GVkqMFVT33r9t0D+4NBmlBoFrxPkyBRbXglaE507rbx23GwltbNEXCc5OpBCZgg0Aa4HxYRXQzj559
# DATA f3PnU3QD/+jJ1qO9uDoNbunpzr5exWkVd7K4OazrLAFZ+rbrMVHaJak8E1pOnfA3iRulwC2NcNykruVYbK44pwHc5FMkgUsvzlaG
# DATA lph6RUUaYUqL+LNaSvzYyjpaX78nNQJh12wNob8VwvRdCQ8iQiOFPkNn18h3ovg47acjOpJQUd0TT+6jLRWbmmDTtosziJFrxSUD
# DATA kzzOkh57SKvb6pjhyMtyPzRtkhH2+rqJb7KWOdzEPVkN8B35ejliGuVjcXP3LlZ/aAQhbv5ochVy3DrKRuRk0sesUFLCt5dQen4q
# DATA Wp7y1NsUv6aJiGgHxUC2sdj1dOvrgoGM57rF3c3ruhVyH3nLgMvFULkPWSfoeJbcYnNblSWjOudEC9I8Z8ORerLWt+AYJfItDRan
# DATA NBVyCZtvRI6iuWxgztxJqKeeCsI4PdpaMThe9W1nEHIXnscPYJqNIQZSS0dnIVteNwSfkhn4SNXVLS6ULIYIKavFBi0XXUEG+GWC
# DATA ucBjPTiUsamMXs1I/Octxz5GHAFtyLtDBz7CkXcac9koQ1KwSkwNi4Py42u04hEAzcEp+YeQz7kKDmAxarYKcmokDvQeR4GjNKVh
# DATA 0+Fg0AuYwqtBGLGYfsVWADw0zXEHHQJ0pJC55VEYwmdzVweWM3vmGOw4CjdzN4woJ2BiLsyYKT2v6Nq4fxek17AqIcG144LOy238
# DATA XKQ1fPYpA11oGlVhA6bg/aRSNivfKreMKuiGOEYijtgi5RxOZMHSV/u9Mi1SZv6vHKDOUhH/zKOs0oNS9XxmxVrkIPSeA2RwhI0C
# DATA xNC8V9CdywYXenSuw4wLE6xC1vsDG0xYReTdwbXv62EfqDc+QPMdohuJHQN4IMRmBGYRFqGWk83zD56ldYHzy1QWLxF+ReHwldNB
# DATA mevb/oFr0labr5b29JtCPNT86vqL4/5XOoCpRyXE5+M7ibzkLMabLPWUQE8cbXuQddiMOOtCxewow/ycSJiYR4kApYZfmX1ITLxN
# DATA pEzxjdVcq1XE41UjyMzTnpLrV+bE9x68YfwvSf8aPMWKzJRDkmmU2bJQJtVSXxzOXY0oGA7rxiGx7ICRTlws1Y8VF8v49r9KkYLw
# DATA 4/oU9P8BDDvVCsCnYX0zIRESeekobho4cpyMgMUhf28c5mJUCI8hmIsLNvwYJXbwIiqhO/btWk1QrLU1d7wSoMNEkruSud2xY/xI
# DATA CEEAq5w//DhtjI57g8NKfCeuVq9rGIuv1UtOD7sJFWv6mcRqKksIewqEJLF+hJR+KmKvorHOFGMox3+1qQ+p8WRtKso17PYsHo1N
# DATA FejPA3JloTcdYdvsc3Bd1ruYY9mWFw6gdIx69AqVWPbMI5oLWvY4aggtpbkVsACZ17XclnXf1Iyx7egnrVeFbII29SRQrxtbVGIQ
# DATA txCAi4XPCRJbAbu6MuKr7PA5tFVgToaqUitlE1UquiHlIS+yYlywpgWHbdNbKfcVDJZerF1uZRAoPjff9N3N7c2dDUtd/LWyTm/K
# DATA XRgtvjUiLlX1/CakqOUVYneqgj7PaR+hGiMnnBt5T8TzMjZoWVTKR1YdlnFaubD907SAPdpOoP18c/uxG+/WaDNKaOCbCG6KiovA
# DATA gaX5zWkTIS3NNU9zvgOgUNTRTOaUa9xDhoi8Lp5diDNfXVgpBBFvq3doLcs9qom9la5b4FG37e1L0FJf2GLufLYVjvFHsrvwN8n9
# DATA bO+WmrPPHHgjdvqbSU0ab6x5UZgcGqNnrHlj0Lb5zqWfjte4/lsKBVyBgLeMDmPhLVqJWTK16WA5M2VbZEDBoAuojeR/QMKeuXks
# DATA gV4ckSEU51lvbIyOJ7jYz+lLxQr03Iq3GIFHh5N+F9B4BOAv6UUIZBW6yAkwDibjiNYN5VqYEwHHnDd0Ql1sGWOMtxPprBLX63bc
# DATA NZRLtp5rMUFZDaY2p5ax4qzAIiSwMlqIOrUer159xEad841HKCBELx1eMCYmxnBwpveGa/QG1eTYzD1ABZ7r1iFSeJgCrEk9+oM1
# DATA czow1WCaavzcwIEX7j9f4CLLT6YUVE0GXjDKoY9OFkej7ocvIfTil1FkqHoWEfhUvZtMm71lzbrCXP50AoPJI+t0ElAMLmVNn319
# DATA FHAU3jktrJNDcroLUHNWq1a6CPIlKCotavFnr7NZs/nWy18cqZ+YJexGkz7wZriSeGSw6UkOULVkTRyNSHBNlGqEHoxqwj4C01Zl
# DATA OMrgSliBl7nreSIvVwuoY2mWGisQF6QwgKuYSghSod/I9BfHA3Qx8rktjDOQj4GdHxUGtAwgX19XnXAGRW0myYoVsl/f1IOFsBbV
# DATA aQID+SPjStGH2m0SZLXbuBvttlgh4NCAvh1XCOfAgn3r5v8hVqH9V7LDxvDyW+/4vyX4797aGv2F/5y/K8vLq2ur99U7fr+8fP/+
# DATA 3W9FS9/6Bv6bYOwI6P5b/33+5+deu7rN4qnbzeXabSI1bjf3r25n3dvN20TYjQE+wFW5XbtNWSrg9eu/++onX/3l619+9eevv3j9
# DATA q6/+/KuffvWT1z+PXv8yev07+PXbr/4M3sGb11/ir9efv/4tVLYIHmzi/4TP//L6H6HwT0pq1SL4+5fQw2+++hso8vrX+Ak6haLQ
# DATA 5K+wN/j/X8HbX3/1MxjGT+Hv30JFbhGK//arv4aPv3j9ywZ0TyKs282r2yqHCgziwa3ugMJAUNKLhy9f9h/gj6gHFFbr5cvbaR/+
# DATA efjgJE26Dx+cpuOEMhTl6Rg/kvSMvtMXvLT4+ixLzzEsEvxUEjR8fZ51xyetLlCVnbRODzWlCajnQOylrWXT1sl4PKwjfD/Dqo+4
# DATA lfou5i3Lxpf154Ne1rn0OhAirJ6POtHLOE97Ry/j9YiX3H85vuyl3rvs9Nh5Q6ZyzfVocPgj2H751AekhYUPkzytw1isVxiUpc5k
# DATA lnlbXB3rEHjj34jOsnxCVO84PRwMXkWUrgao3OMT5ElOAJGcDHrdnFDh+AQo4wTQYpSfIuHMzAQmVI5Q2g3vAS2dRmmSo3piPECk
# DATA 2Ih2x5PuJdUdjLpZH8MuSSRZIOiQpD7FgJA0ajrqD5+jaBvJmyO0Hol+HP3bSZaOo7NBD0i/B4tc6AHZ64zSHk4j6/DMYLhH+LyY
# DATA 5HBe8kV838jPjvEb0ZRY9hSaX4SX712c9qhXuyXapfwkTceh9nALGp08v2E10vOparwVGEK/UORHWAIJ+3T08MEiF4QfdBPwmmC6
# DATA PzoiJATC6jaooNbhsvSgSRrTq2xoj+bbiL6w0C58wN2Rc/BgMeHbhr1a9Q+RsXCmY1R72Iy7K9BGPzkDGiVL6r3kkJflKdJN8Do7
# DATA TuTwYQ8l7T07S0d4j6ktq1QO5ydLc11ud5jgBY7kvV8cj6Auu4Pn8XwwekV7Q0UXYTyyqDhhJg27WFWtzwNJzWSWYoi6HqzBkGn5
# DATA 4d5JAls4RJpYO7TBEYffQKv1G9D88sMHQyiWRlgXrsdldJKcwY/BGUp3MfPfCV0ATOVIn3E3iMzEkzpoRFAX2GYyhwNKHG7bGK/Y
# DATA 5WCCW4eVlaBKXV3odfjwQTc7M+Nm0JD7J+NwMh57F8bdig+ByFTdHKbA92K8XVlorxVUDw76XbjVTnvzbNoijBXPOa92YNnlBS/6
# DATA ysNno2iYwcAmQ1gkAC1HE1iUwaCHy72Cy/0o6XUmpI486g2I+k8Ttu+OCNpH3VFyjhAH7fpwhWG/9OGIuoOUt7KbjjFaIXAQQLtO
# DATA 8G7BwFHvS4FrKJBRZwAkeoZCcF71m5w/Pd9FPHAPHxwBKY8ncejeKDhd9lKg1Je5BGzX5I6C9qDgQ7X3zlBMIjKss0GQ/Y+S0+E6
# DATA 0utnSecSBxT9l3+JbjR+3jU16kUESnifBJcD0jfd/gHb/wHbz8L2fCzfAMm/Yxz/Zih+Nob//xCCf8f4fS70fjPs/o0gdz6R9vQ1
# DATA Qv9v5wYRwJ+NOwHSD/JUYdANhTZZnAc9EnZX+NOeMtI1iZnm4EgcIGHucKxIrCJbJEvQyUaEfEmA5y0ELQ+RNAoF5yRO66XJiEL5
# DATA nwLShpPVqxEChklkp2k3OpxkvTHOAOFjzlOGkb7IsQpRW2p8agbYg8HoHUUP5D5BwOTAoN+7bERbY0XDdTDPN2J8XDhAWyRpNmpt
# DATA RQokXcQwJF6kIeKm1IkswLue5xTHKNpN01fRn8JZQWMtpVw4SXtDklXhIKPk6Ah3CQmS5CgdX+oZfjqYjAyOlqkBpZNHo0lfk5qH
# DATA aOyUjhrRpiQawiXFeUyGSK0gnalOIZ7xnGgYKIApFAZIJAF4yLFM0rscZx2ibmBu6WiMOv5jmEKC9hfKtA3b6pyknVck8iTVDok9
# DATA ncH815/8b7nMFaW8ZBeUdwZDaIfoSWvPGtEj3P+I9PIU8QImdokzl7awBg71DLtIT2GnjlSjJHGFu55kAIt6aY3oQMxigoQyr23f
# DATA jBzuxJg2G+pACb0iETkGyMEaPnw8OO8zmYcLyZZlHTgxaLHmDY3PKRfJkQiHocItRwjXSfmgnwxy3lq0KRwRif8qTYfmUiedDtL+
# DATA vQFehk6H3h9jQxlGSMTAS7SYgD2wnbwRbQ+o3IR2DYqnI9oyXEt9o7DRIQ74JFVAAo7PU4Q22ZinAE3b1wVWbAKHm4653FZ1K9ML
# DATA IBZxiufQmF6KI2JenI3cghFrw6Ucg3ugNV6XAUyE7iWwQ6NM+ZV2ExxiI/oQgQ/bHuCWjBAvpgBb5LhCP+i/Rd/4SAm1/8ZsznzI
# DATA Zi4OZ04y+Rsj9t+E1n8HpL5LNAG9f+fqcHAB5MtnmL7mkE5pHd5cY6UroHgGvV79MAVeOBuMmvkpNH1yje1enSYjOA3NpXXUcByP
# DATA UPTTPEtGlXp9mAzTUXW9M+hBFX4FdFl1HeFXc/n+8GJxuXHvbsRfsK3qOlqZA8g/r5+PkmHzEE7gqzrMrXudXHEzWR8uSDZex9j+
# DATA 9QmajgKtl9YHR0cwoWZjZSU9vU6aJ9jOFZXpYi4QuiR1OPydV324u82V4cU1H5Ja1h9OxjW236phDcQ1VzRE6UuVbPDfq26WAxq+
# DATA hM/U9VEvvVgHbHHcr5PJX7OTYpro9R/B7cyOLutyv9Rr4E+BaEG82lxbG16sD5k4aMJKAMyMlhvL+Hedd6C5PLyIcmBpupG1foWF
# DATA RuDRH7srDfNVr2U3R0k3m+TymR9qMALej/o5j+ne3aV1YKVyaGc4oHzX694yNpGBkTVp6CumVse8ubKGCWCqn7PFVOE4SFP7RKGi
# DATA LXeedluodD64KkyUpm83wEdMmmjCziBW6V4NhkkHuMFm4+5dNRvhAeFwHAGBkNeBHswQA0lV9yUdCu8dHxHvpTowftnJKVyLS/ft
# DATA FVxtPDHNVW9TqRScff6szjJszTWPA+B1ZZ9YJELjcCsPqtZL3MrBQbVwhomTbi4vLf2PzqG7B4eu5HRh99X577E5unhyG/etg6sO
# DATA 26qahDf+mvWSxy/DXYGruS5Dpd98iOtFIALXrp6fjOChuXTtNAe0+sGVGtzStV4QaxWW31+CtuGwZZ+lTaKcAE1dE3+k7/fxKOuu
# DATA HwMYaqzSzJxrsrTEpRs0JV2nDBhQM/exFf/+262uQatHmHUB9v9q6h6p2S03Vu6qVnkBYVzpMWDxK7vh+0tLuspS1FiDKtcny7WT
# DATA ldrJam0oILw+Hgyh+skyQz/uDvkrJJO5oRpmWkZ8dzqsrDTWsOvavcbds/Pa3QY+VAGiL63JSGVNqus9oITgSKDYFQfAXwEkUGaN
# DATA Wr2xtHoXqq6fJhcyh+V7nZN1GdThAO7nKUx0lQa9Mt/glhmc1lZhaCu08Di05fdnDA3GsnIXl9Ptm3pe5Z6hk0hWHVpc9Rt0a9LN
# DATA uMYFVlO7d79zcp2dHtfys2N9aigT2rp1X+WAJJPx4Jp54hrZGTBGl6uC6eKWV5bgINeQYapgzage3UOYrgfCSMpuaeZZ9REXicsB
# DATA 94/P07RPJ3m5cdc7ystLdzVY0csWOrnXDZJe8Fre57Vc47VcKa6lWrWVJTgQQTwEvIQ7IYILRD3gP3zxVgS10t9rEofMXAX/npb1
# DATA HiWMuUSq30IS+MAnPZqaUln3ruV1A6VBVxg8gQoeZRdpd/2zOslgYN7reCnry7jL65hxA1YaF7oERGuwgPOklhkFXWErWPO6ASTN
# DATA QAHHOucMvId750I9+EfbrCHsnZz28+by0SiC/5XBN7qg1H7UAMoBuqG5EohVZI3Z0rW7cBG49FF2PBmlmpA0bzsJSUOtdhrvr4zM
# DATA /cRZNd6nboWVmH0W3vfqL/MdbQjB7y3N3SVzrKl0+ExLZQJI7hDmvkz2ogL4LoC/u/YoqaMIgKFbCpYOd+5qjr0cpUPgCiurNTjn
# DATA sCmVpRrsLIANM6LrRicZda8szGJhnXuE6v1TmE9GR+jCPYO+mE6Ocr/RsIncf71zkvW6xWlSkQaKz2uN0wkwpVc2gUBvoCH8bh+e
# DATA D3gNz9Es36YGPgjeqTD5fBeA7Br8bxX+dw9JK2+f6Hw6G0AyO/e6lBDqGsFgIx405Dk3++MTXpPKSr8aqbmU7cRKkWq7bmi5qX/W
# DATA AQzAtBBI6CKRUAO8gBrxI2pFrI8/sEWUVVpI7v77eLfpbWQjv/tL+B7mk43nOaOwmAJxFHhxbgkltbluoGxBU3srX+e5xJ5ImVMk
# DATA ERVuaTD5doMbuBK8gdQWGwNeOcCKyT0bzkdy5qacAZkZ4Y+1EEdp3YVVBkfnJ+QsidCqCUwZQVE1oiZMZXyp50iYsMFm6w6N3bir
# DATA qGa5fisMVpQsMkBpr9mzW1rHUnVS4EgvRo7Zy67mIDc8HgUgB/BNWSe9spfE58fUdVTXg/FugzcF2Mtji4jSQ1+aA01w3ShBdgP4
# DATA wTkOiXM2Iv20gk9I0xUvhI1TXHgdLc1HoLmjjIYWYpZPOSD3/vGVJzeAC5Ic+9IRJm2nnE29QSvMRI7cM/P+vSJTWXI1DxOPtlU3
# DATA qYBbPbrAB+FMEEiTETOFWKW5bPFZy2sEKfkqmIX2hTfdJD9J3QXeP8m63bR/4FygW5weMOmPr+G6XWk52AWR7jZvhPyB6W9txtW3
# DATA l/L9sovtid2S/uU5iqGvUTfCu3yUnGa9y+YjILEGgJdrL+Mn2aGyfX866A9exrVT+EPtunce1rILeDjr5dYyrcx/HkWWcuVJpXyh
# DATA lUevqz4jh7ulKyxM1Kzruu5iRxrxijA+psVVG92HiM45CED/yL9vRmndPusM3EX8KgUcsQZxKvPJJwFiG2m1x4mWHIfGMOv16qPB
# DATA +WwqW2jqcTrUu67A6Jr5hEBc3/81AdBjFOFRe/4tuKZPauMARPaSYQ5UifywGWj7BBJiHp/Uxl1my2gtmjgaB4/OdRjH02it6waM
# DATA IL0iSM4AvLm8WF8m3GjJiCyigWmGwWQ8nIzJI8FfLOapyEq/jmqbADWL7mnJeDC6Umg3RMvyiVaATh/o6z8+TbtZUrFItHsA1qpX
# DATA pUIHW9Kweg9hr0gV3NsiNEkRO9FhYS8KZHd5mewzQ/xpKf/pXcpV5FztpXT5SS10uUuwmnijGxFjilgtH4/deZiFXEVlg8shzrks
# DATA BYKhnC1fOVIyxrsWlaIqPrR5Kft4rnjksyJji+dibZXOBa1hTVG5peMhsQyLXgirf2A2x2EoVlhMJ6ymix7mn/3c0yUgEuB/CJDD
# DATA UdLzHpJKM6+P0u6kk3brpwPaFn6E2xHSiVHjd2p3mmz0AT+SI7w3ST87NSIjg+fXSSmSBb6oYbB3jrqLfA1rShnlCzyYPqbdFPLD
# DATA Evmyps6CCkQFCG94CPzpK81t+IWurx2NobLaQgtB+BNdnPb6pPtEu7zm4uL5+XnjfLUxGB0vriwtLS2KgRcaEH04uMCCS9FSdG8N
# DATA /p/UvnjiIzYAhGd6GTEgM88jqre8gr+PAAWRzdTq0mp37QM0fHz4gMKVkLXQ0+V70fIHJ6srZ+9/vLJ2trx0Av++//Hyvc+cykcr
# DATA R/8ve++65Mhx3fu+Sjlkmd0adA8Kd0xzhjG8jMQtkuLmUGI4RH0ooAqN0gAosArontaYEZRkW9shx9EOnxNHEY6zt2NHnPOdutAe
# DATA kyIVsf0C3a/gJznrv1ZmVlbh0ugedM8tJZINFKqy8p4rV2b+f/VBXR5GFIurohmNkNGTJ7JDE3mazHMKkpHa38Y35puxqOL2TvAL
# DATA 75vLd9epzU/mqr3ofCvf0WP2AEQhr4WfmA14VpZ0q16j0fTq3YZXa1ZH9WrN8zv1vXq17fmNejFjwlbYi6qLudque/VO/Ud+uzWq
# DATA 1fy9btOr+fR4tXNEf99B0M1qrRhUNBj4nMc8XXjA6f9Wo9msNqP84p4p+vrCSxFqxz9q1Pxxda/mN/DKvW6XI6Mi4vlSKy75hlqt
# DATA 6tUa/pFfq4983/eanR/Vup2fvduod726T9Wn1hn51fZeo/2jWqtTTF6n342CYCHIdpNypTv0a9XxXqtK/xzhY4Mu1xudoe/T5WaT
# DATA /jmij6WY91q9amOwLOaNlTVVbV+kinoLJwsfKU/wLVXDD3h+f0s1lgM9tb31rVaz1avjgvE+0SP8vwNj0Cxeqd36VuRHzah9oHxs
# DATA t77V7Lba7eaBWBi3vtUb9Dt9PMFuZ/o5bNVr4YEs79/6+JX70WESeT98m6YLHwZDsj0rd3n7WEZd4V4WpTGe1V3aRreje9rHbksy
# DATA mfIu/ZZYk16t6HTuiCFgbjejkZrffDeiNh0HFQm6tDR3UHaEwTirtPcbR8eVtjjCOGC1U26T6f1a/xbNVIshlh3ltpmnCmbxAe1D
# DATA L44ThbumBatSTE6+AeNPP8ZOokcXWB7I1wLEA1gyi8RpVb2YcePBRVveiFH0ClRXGrOF1FYWknaecac8ewt1jM2Gq7RUPl1s6z9F
# DATA U//4Fezeo04i7s94J/mEN0B6fwl9Me/2HbMFcv+TeZSe3Od9AUm6k+1a95qb76ZpcLI/SJPxzvLn7o5G9Kj1rNrL9/3oBNKL+hm0
# DATA 8H1sB6TY8tzSu+F9/MotO4LjaIzT2YIdezeY7nCghhXOcsYPopOKNwhGI1TuXe8RDvzTfyUAkcnnPWX3JRIgUr9NWb1jReoGNMp2
# DATA DwxVmOkq9NL5aOS95u1ILPaHQYaX7dIldYWCkiu3rAjc8nD0U7QIWGz/wPsUR5X7Q4qVesNFQsTjn9qp5kP1kmyFin2kH8/kcf3D
# DATA gcqLQvqzFemvSLxRSyaH8eBEY6tMtmCLzZK0DHC4ezGSwckOJs+7pigiCNT+5c7Hr3xLPL8fv0JBQ2woGgHRuo+71ekMuhHfDkpB
# DATA DpPjlWGKMXrhMCfz8U4c7uapeW8+7kXpDof5MUT/6Nd9nZuFR0O1iXRH5NwQuOhZ0Js+fgVfb1JzjicH+piLnHF5JY/9PEX0f/jB
# DATA O/uy4/IHfDyEvkO9zXsdGno/Rjg/qXiPEPCnKAx5NLAbkjz91ihivYyPXwk4G4J97P6DZk06wjcdX7QmijEu9Udx/wG1KWw9/TAe
# DATA R8l8trOzizaOSKXRERkVeaQoHHDfyX5VWSFRwfqGLgXMJvByO5+SCTY07wwmSDjKBg+wEN4YQh9vHVGk31FaKxRGNu+NYyrIihcd
# DATA cbHdocf44z5UY+jvm7Ixa0cVNQdE03GaCv0I9I54drKzS+FPcMOnKqp/iej9WA5cBEfRTyiS+/TgW0F/uKM2f/KLRmQ0Z4GI0XHv
# DATA QhHCV8Tnxz9Rb/wL6QHjjP/u8A30Rv3cj3+iS4nyH7vjocu5K+HL9RNWsuT792lUGc3DKFPRyDtE+pXeZzbJze5qaXuUsLX1DVG7
# DATA z4125wRqneaZYuXHO1+jinlfkkMdjHzGeaNPD3RUd/LHl5QN1xe8TydnG1mlP2+QHZQAuYuMapra7hwhFmAH3/aW3n7L+/H+Pn8O
# DATA K8vuMAVFFnCGZHI8uHu1EiORLmQRerf8GZOtZh/6fBrqzeSFDfwq319X296X73E/kGckLN7Snqnt7DgTSgbFUbTPLfxT+bdYvc2C
# DATA V7GOJw/zCs63ZLrY6CeTKebh1UUoD1MZmlBQiAhkwQb4+JVlO/nsaPHvEjH+KBHgYpDg8/ogv+ueWL4tq6J88sauo8oEyTVyLftl
# DATA XbRvqbh8DAnPMdkeUttMFFbVnBX5qSOgao/+Svbd5JAmgzB9PDbjPfNeuliqZbq1rKhXB+ZAxfKahWqT1xtVd3T+wFw1IzR/Uz25
# DATA 3ECjPs2t2BjjW/T3cncvTfNt0TI12c+ZzPrEHPJrkove3/wNxRoVgvqv8Q79Sd5JjqP0Dcq8HZPF1BAyFl/Tryw8TVYSEs71Gicm
# DATA 6L7qgWc1CGRqsdLRBbtqsOgixHvout1pFmOT10ROy673V3/l7eio3b6tY4JIcUCmCph8u31bJQX1F7fIsh69+S84CtLc+OOupOXG
# DATA DSkoZexg5VBnP3/JzR1825U78mAlP9A7VvMRSSkVSRniBhOI/Lar7ikNHxIW11KOYZTxwEElr0t0SWPkdoS2aFUKJMeU49oGXHiI
# DATA XoQ4qmpKmawD2S3WONyoLI6d3dt32Gb8+JV75lAYmsmNHZh9H78iTY/S/x35znNAbu6z5B621e3Udm8gwf/79/sf0/8mb+pZcpLM
# DATA 2NXqBTPPpxnLDQmAD5tRAPTQ8veQ8XSzeGv+Lp/f9R+/tR7UEdrguf5YGrfMAPMDme5gtjuYfd7BbHcg+4U+kO0Vthurc9DP9EFt
# DATA 4znjnwsnAEfW8e37U1bLw8gWh4CN6NPb+e28rZjPyT1b57mfl1ON5wm32I5Sjr94nO+8Sj1tuRnqRTJEw6xUdGS9y1rBkwvBiL8V
# DATA D6qXF6+kSfcTZK686WTS19FQfuw7P1hY+2IzleyB0sF/6xn+wungDJje4aK9ReUOPRgqL9hD6ewEm4rN81PRDciGAZ+I1TXKUxsu
# DATA aFrIx5HnPRrXPHh1PcxBKMxPOB68SylO0n3vB9Nowud8B3x2nx5Sh/m5snoU1hC1juqkJ9sQGMOEu+nNYCxQQBOlG7Ch8o5X8nFr
# DATA HQE+T8zRJmuBjOxDnEszMjzfxzFnVDic7maig/f+3Lh7vQkus/qRvCOmn+ZTmA3Zvgdbin/M2KRKBnDyUIsJYampZkPmcsISAIN5
# DATA SlbEfFEN4cU8bGtCcNabs97Os96KNczp6zh9nYuabSsNxKvS3bmPLWyWHAReA98mhPOMAs/T03hbN1xid59ny9UVLDle/2D7A4si
# DATA akuOvsaFjU5I7Fj2CehMVl7AnfHuq+IT1Q1wwutRKCQJzTxnuqv8CnvFePvHfpM3EWkNa0o+b4jCxXHA+42aajNJNOXdR/vSs9/k
# DATA OJaiKl4IUx3wbYOI6qdMPM0FE836fmuL0RTPCP2svTR84VVxtKpI6XtMpMxDrybc4eeRq+HNd/xbteqrNxNlFZbvaap7mmvu8avq
# DATA JvqQ33VTopUnRdnqOjfVKhg9mDeDmS15RGYDP8GGRDqm9/KeYJVOtRqK0UtXzfyS9DzxEb9oSuP0THLgpgSB+ZPKLVmntUPJL+kd
# DATA aubKHcvgDDAhszoAW5qKjUZp9nNKFYRfjEH5Lg2G1D+L0ai91lb7xxgbTbjls6FoBto4FTty37sbhh6fiVVmQaaHz9yG9N7BGopS
# DATA 9cREwIy0c8imi6OXjVIxxKnHwRuxC4PeNp2PRvzjHMuwNKjHqTb+f5hForwjIjai+xP3YspikZjXIlK6zmPBNuMokFkCw4JNafRE
# DATA mNfEGaaFlKSJdH5a5Yrt9RGE761eDmNgL2K9TM407uClSLg0Xnyr2R4AneHsDOfzDOeSgeQsZ2c5rzeHnwHFyg/pbdw4MtHMC0LV
# DATA GnKzuaTZiMHF6LyxIuKDaEYFOjkUabui9KIwwZIBxq1ESUDmSomih1g2kkv+WWxXlFJQWxZfHdZZf04LOevGTjGui8vMiFTCgsE+
# DATA JegtBhJdFsNOBgNs/4JMH/cFmTdMjulnj0pIhkvO631PGReQtKTYHWHcRT+TDLhj4Dy35CvFZ8XJKQ56s4C9mXdTDFcjM9KZFNlJ
# DATA e4edckGfbBwIaR5Tj5WnDCPvHk8ZZEM0o06DUcbbxWDpIImHZItlulcLqfCG1JtxKXEy5ZQPhTBhUXG4Ecl0OpS5kxgx2l+WjMlq
# DATA nCl1wQBWwQNPK4WsSeebwQn3xOsTijIUVyXKWKfxvvI/DqKIkhXGA5b2o9kdDDUIHGIPI/YhULWayRYMphvTL2iK+IVNQO9DxvB4
# DATA zBdEgGxZMVMWjkGqijohxqLrzU+kUp/MUJ+xSXRNIj+IsiUJFLOiUIUXBVVNVScrlf2Wx1CFRyUboQnyqJNGy4xYFGlF25EgvAVh
# DATA jLN3MtCJnarEJKn2fgD9l5AykexCtv2QfNh5czIm+IkH4nHVLmWGlKF2j+WdYk/qqbSWOh3E6ZgXR5bNbTlRH1LeyHwcjN4pjpGS
# DATA mWTU1qkFGes5X/zOxH8t91N+cHUkU0BNz4NMbGHunbx3tbgn9a4Me2BTWoG4jQ+ZGs8DNo8xNSDDl0o6mM9idBtByjpdY6U8yeqn
# DATA 0qGACyVuY7IQcF1NKVam9vuT5FjqJ1oJNRH0kRBs1Ql+M+HwZ9hXidyWtkgJmsKVwF0jj21il1h+BTR+KmVsaYhHBq6V8nQhpeKm
# DATA 7CMbiTJMUkhFjgPS2JERLCjIFrphniJMTspqsmY+YcvKWna+2MwvoLX/6acVw9CZHQLOm57YBJ3/7+yXp388/eb0X0+/UIycL06/
# DATA pv9/fvYb7/QPYNrQD5/Rv79ZROf8T/rhMd30GPcz/Obrs1+ffuHRl98ZiM6XFKhc5q8A7fzi7NcV7+xv6Tl6BreBnvMNvekrxvj8
# DATA Pf0gTJ2vTh+f/UpH5s90yx8F1APYjmPpPAezGXTKOL5EHU6P/swKotmHUULhpHFfm2D73lsPpyMZn0fcI0bSN2TDeEq9xcjyRujO
# DATA EauI0yj3GeRzoWQ0UuMTvVTL/K6F6mA5UYWnWopD6xTnN7oHuW6wzrKSuTq8Tl51zK0w6fLL5QdGojdt7n5HvvOIvmXCDo9ralhP
# DATA 1OZWDKYOsLNhsW0fsYO194itTxROJXcxsvGL3INDJouigmE6pPGE85Hl9rMZZqql3coaqYkgzKGUeLbA1zm/+q12aC5pWU8Ls3N+
# DATA Mhxnx1kCV2EJaODOJQ2Al8S5eW2D/5WM/RsN/Rcd+a9n4JfquZgPOYPn2WtdVwHjsXKAUTzFVy9J7yLIg143nqqVRFV4lGcpXqrA
# DATA N5FkTabypuIpCWwvHZ7MhmMORQ6YcAZtiuBRRZYvRFJHPGK8zBwrtVBJnyG3Z8o/K8fkBsFRglFBsWZ0jPECgZvwcEoPaotBnas7
# DATA yO0FIRbB9wMz4jiYzGy3WD+ZOsaOY+w4xs5VMnY2HVU2muZsaiVfs8l/GYt/Gwa/o+042o6j7TjajqPtONqOo+042o6j7TjajqPt
# DATA ONqOo+042o6j7TjajqPtONqOo+042o6j7TjajqPtONqOo+042o6j7TjazrNE26k1g8vSdtqD5qD/HNF2FteeN2LucO6q3MOuTI/f
# DATA 1WoVFNKajVKuN1qdIjcnijoDBTbC4UaKXp8DrbdYBqTPodYkGJbK8ButIsSnThm+BI3UbniNWtUD3cZvdkd+p+rVWiVqT8tvNju9
# DATA RVJOo+41/O6P/G5j2Ogc1WrNsd/2veqP/Gp92Ggf1f1iFPq1sNHrLUlEs1PNE+HXuiYR9WIAtW4tbC4SeyhjvUa7NlS5aNFzzAML
# DATA 9JzWJeg5XGMteg5V/gI9p9noBJeh5zTDaODn9JxWreW3Q0PP6Xd6g7Cb03NarabfuXp6jqrje1yNzbhQF4KOHm4LNy1zVNV5HKl0
# DATA j44rHbakCmtMzf7wYGPSTvltysFtu7bExFB34WjBdnA7doiLuB010ewYYxVlfMA7OYZBmBzfqnrwblQ9XZIFQA+368VXaLe7Mc3b
# DATA sn5SyPXSTYW1MhnOSzCcgxX7ARZHK0VJWuaplXXbNSGrrkYNbbqh5DWjYeJ3vitV9RmrKT6F0j7HRixknl2YKjF68gIrxFF2HGXH
# DATA UXYcZcdRdhxlx1F2HGXHUXYcZcdRdhxl5+Wi7MQDsd+w7oEa/8j+JnXnthox1cAlv1W4Lu4efGpheh5JviEzbnMwOHVkgrlBTwC/
# DATA 8/ErNxbfoSr1gR5Q1EsWb8xvUQc06C62cw8UJOg9HOOSls+m/OiET+fot5ajtO/9tToDbx1K44NnKGuqUCYKe/oG+uG1dSP+lrLC
# DATA 2Mwmqbw4tT97OMvTTL3jx6+8Y528M8mg7lKlQCa6pXM+7gi6O4K+8RH04oEwdxbdnUVfPDW4Um/zWTijXqrjhdZii9Ow548FaFGZ
# DATA s1wtRQnfxmEUZAV0C5+IhrIlyEU80mTUnck5Ya2kwlvpSqdlNz2DzklgfUaM5SzOpyRB6VVwoU5Fj6/HsouI35LDoGqX1aJ+vbJd
# DATA UQX5k1KDV8Lh+sdcz9xc4e22kP+MOBwTvTizsnq1yrsxiFkaXT4XNd6tO0z3aT+1oNAOixKHO9GhyX0s7rpK0F11qRzWd9Xn1XfL
# DATA 8XpWueNPq+/kPlfJzPaj1fdJv83p509rROXloKmWcxc71FZzxxCzRsu9UBPgP7dlXfNf4K3nrk7PA+STzvNynpXENtmtb3oBsaq5
# DATA 5qVzzo3//O1/N+koR9zK/ylLlKLPGQXTXH9VLSXynrR0DokE2GgJSzFMoATPWtRQK42pFjKUKZhOqU6yvi51zGh9NImdzOT4P/RY
# DATA Z9A/0jq0rFXNix9aZPaYKrc6LK58XnbLzE8+66aRH6w2jjNcVkkxOaOPXtIF9gVzTaF7LRBAWbX1QkWUV9SLFtDf/a/VBaQrvRTP
# DATA 2ygGqsiZLqAPjxNqoyl1bJ4+5ZcpE4T6pPkEnkgakqb73ts0ysPIGSdHIkhBaWDBAQgbHEbcraKAZP+wKqdIq1uo0nryUjEpuLZy
# DATA Md3CRYvlH//n6mJRXYyUisiB9pOUJiOm5UzURFgu8zSnx5qurKssn7xpgIYViukgCr4D6sOTY1VERTuSpdnZLC6Mg9bleAYj+slL
# DATA yU7RtRVU3i9fuIf7zeqS0n28FNVHQTr2eHdX3sUd45rAccIjaGFTyRxSwfD6Bfq6SIb7SShSGhGrx0JnOpoAgiMloGYDvYjJHfFM
# DATA NDmwO9b+makTT14+eTKurXSeZAT6v/+w+Qj0BgbZKJUhwdIBH7NdTfFKHyhLm5tUMGL18sAbz2n8GQUp9slNIZ+MjPZ+JMajGmDI
# DATA RALDQJoNSvzJS6IQ3eehqfzTpk3lfjKYeT1U+wClk3drGON7lEVjaNlAM6ZPIw8mB6wIHYQ/DbA/R9X4DIWVsj0ej+MRzhsgp6BS
# DATA QZb6J/NY1GqggsjCKlKAWhF6C02lkIxLFVDRCBSPpm0EmiuS3XfeS7TvUWsK8exD+QSTVKiMGKAT7sR1wSrhnydhB70c4i4Ozu1c
# DATA aZdwpTnP2UviObsor/uZUHcs7L9cj+2WOTcNpDNs1SSL8pCdWivJ3c+oCuRzJJp2nja0ve/xKijei61k6yzvpTKiq4jeiylXtxl1
# DATA bHG+YBK07/lGEpudSRXxHYka5HFiHBe5k0lR+5RDeAwot5H5ywu64s0zwZdCFpCCwc4ISUJW1sJeUmuUPjfXyVxP81Ja4O/B0zU5
# DATA BDRQAOOi22OkwC1lQQ2+UZpZt4ycKMzqXFTUVhL12GdCFutMSgvzHljfHjbiQm/zqFAfZDObZBZvV4Um6iRv8KJdqHMLObz/MhmP
# DATA dhDOfHTm48bmo13X3DqsW4d9QqtxpZF6Neuw7wr301aKzomHT4dUcR2UcN77g+rFxwYLy5zqpxyvrW5dWC/MF5Ly5bFVa4v28oa9
# DATA WrPq/pKjvbSUsOqpgvu34NNe9UTZTVl2s656ruw9K3sFV66cFkqBN1khpqhOYRxyfZCFptde1fKVqljUveCXy55TYYmrc6aadF5e
# DATA BMchc83fsy0qT3PvqVO3bSpxmelXb0AR500F45NCA3p+EeJYaJoxCXWKnj5Tlmoyst8STfV4IjNONsEjPZMyEElqP2a1as6mAoVG
# DATA z+C5N3VHgr7FHp49JRDCEwBjsqunPoIlLn2PrDuG4lrmfeUUEwh3Y4FGPXEzWSy4fN643Gmc17V8byE4nrqPopIulfD5DPAXx0q2
# DATA 4IAshZSMC2zA/64gft+cfk3//un0MTB8jz18YyzfN2D9fX36BaB8i3TA/3X6Zyb+/V7d/fj0S49Bgb87/ers/zj94+nnZ7+gZ79S
# DATA gX6pEIJfnv0S1+i3b84+8+gLiIQCAgSZEHGQ5wAsZG7gnx0M8Hmw+gt99yA6JtuBJ9HTANK1CgKAXn08gHxED5JdGgNCHR9WZe8q
# DATA rG7SY+aB6p57utPSffZ8yq9BE+LwyMjoi/8kms2naxGAdyF14YXzDJtdqD07AGDB3te9xHXz/xaL5erof2xhMWElv7VQ38o885vR
# DATA STSNI7I29P1vqQseVIaA0E7SLWMAWT2MkdDzGY//6owWNTFHAty0CLePAqS+Bovg1OYn8QCdDsPgGeKM7XJp8hAaOhGfXRZTHgYr
# DATA aiF1bv0ZtjDMWfpffszU5hO990RXNHGpkiXOjBtM4+LDyQIWcPNqudrWWWh4TwsOuHliHCTQWQjbsxA0GvBShsHL4QS8NqPgCmyC
# DATA jUyCC1sE12sQSBUtZ4cxA56ZVnUVSEAr1Wr5a0UUNVyM3RcPTrzDNAjngYL+ZfnqA2QMi2tsjBosLkqcyKZPLM0fsesJa20si5hN
# DATA oz5GfmOKbQQHNOM6K3NTgjPZR0cZOAC+jCvgXjLYQ+Xkfpbq0L4HFVscnw3EcoCPjgl4Kg6KrYbkT1O6lPFaqiptZb7JIiFHlm80
# DATA 2bfvvRcBICcXZNPe/TnMkDSZHw69+YSKaSZn2PnFmcMIOoygwwheIUZw42Foo0nSRQ3qa50jXGaKsM0ZgqMKOqqgowo6qqCjCjqq
# DATA oKMKOqqgowo6qqCjCjqqoKMKOqqgowo6qqCjCjqqoKMKOqqgowo6qqCjCjqqoKMKOqqgowo6quAzQxWM2lE48C9JFfQ7tagRPEdU
# DATA wfIK9EZMwSI8r9uw4HntqoHntYv5GvajRjhYQt9r1Wz6XiOn77W6K/M2L5ixX+14Nb/t+X7D67S9bnPPb9Y8v+FTedHVWtvrdEpY
# DATA vnar2+l1lmH5ClHmfZiL8aUXWshDv23i2ywCJqtRq99e8nytVsufr1dzZGJns+fr8kqVX81anl+bPd9oWvGvW/m94fubHQv52Ki3
# DATA L/p+v2WXt5/Hv75h/O36ImXLjzc2e7zVtpNvwx43zH55RCW/1b3o+4u5V93g9ReBREoj0ZBI6cssSGS/HYRtvwiJNI8YSGStWu81
# DATA uwVIZK3XaLeaOSSyXw2r4cBAIhv9VqfTyCGRAz9sdQZXDomcoD/fyx6c5OsccoTyKNrCukPNcnVom4vtB/NabREWTB95Gc1mMK1f
# DATA sodFZbgdzD60i4r2vRWKfae2cjYjVhYiqhc9FBdRSlDfo7Lk0aa5tt+yqIaenS3qNk/vainmjZ61Yp98wdFaAjqu2aGg9iNIOvYy
# DATA +mEc3YLo5WpKo8mHSim5a0y/ciFX1pYXO1NMkYk9uFBNxHyqbZJTHIKjQDoKpKNAOgqko0A6CqSjQDoKpKNAOgqko0A6CuRLRoFc
# DATA hDiOg8PbMPWoV8cZM0ryTfmqT7IgExRy8V1bUQCt6gY9TXXhHjZE7vi7Nz5+5T9+u8/Ew7tLdQb4mR0JP5jKYQO8kYLZNeHUEM7/
# DATA /lzCeQMtno8vjYPJfBCwTr+c6pLziNScp3L0DYeqAkEuRA/pRj78SeZARkNbgZBYOKPjTt+70/fnnL5fcoTLncV3Z/Gf5Cz+Sj3O
# DATA Kz2jL4qICR9Ezo97y7DymtHnfPryMdeh1SmjHWRUTRQGfEBWWZ074/GuoiTqFjphB0gu6KeDMN2auWAULdvNopLkOJ7IuldVqU7y
# DATA KpDSm8R+G/51NU/RDMp2VblovK1ATNTtayb2teayyNesqHcKEa/uN1dH3Yz3dtT1RVWPdsLoMI1oqn5OCqywTArsayYFraXZX7dz
# DATA 36+tyfyVCp26laBGSwfxvKpzWiMu8xDpzlRasz7iXjD7MG+aLW8y9KoYR9Z7J3kjt29gkX2Rz5fijrKZdCXypOAZTZXIw+CbeyeC
# DATA ciz0S1p3gPUrdGjUj5ARqAxEzPemYjaEMeZ+/Bg0hFlS4zg4kYFHipPH/kwLaxzOAxpxZlHE0uBK2OIT6uDI/MLReiUKsiRGGwh4
# DATA vngH1kujorOsnWV9jmVdMpqcVe2s6oJVvZqt9CwpXxVbQWDyy4hf/RD8PaN2hFXsXOuI9WTgEq8Y/SZBF0fjOJuyBI33oaGrsPHO
# DATA ujkRPHPHEZNZK57es4FRKZpiGT+lR1B/yhZ1keC4IHZl7qOh/16spI+GSRr/LDGSN0rBP/CyYAC+TpSSUcQSTKZUsmmSK6SzRBGL
# DATA RqlZRBRkJzzyDpNxBFEenk2Q3VcRToZI8eBeGq1pYI1hQnBnlVFuYRVBqYFjq8KKKUPBtgkjHfd3IMxT7ACxdUKp9oAHmXeIxiaa
# DATA TwI2bKhe7Xuvx5MEdYie0ZhdbQhMooczNiR5SQUZpPrRJIPbSvWwygSSKjDml1mg0GXGxNK0fd8GI4ySQ53CD3CiWcpNqlVhzhZj
# DATA QRbqH3EuVmS4CyLhNTpRavnc42cPpKbl44beFCnyrxnrvw4g1c6J0IqkDD1lXJjHZ8GA20b2zrJ1iXpf5LykVUQnSjILI/V0zF2Y
# DATA pFFUwUR+tpeXBzsAc+M0mBnBsHw8orygCktplAmn0lOiLMMu1xH2l3BVxhGa1K7QJxl84xybhxTAjIzDOAQNdt97M+EmieHPKJNB
# DATA BE4ZjAN0fqkVmwUCEltW5+q+mrj0AlXYc0tB36ynGCapuSKDxIlc0CL7anJWfJ5/LE699OJUYVpV5SmQ6s/yvoyJBVJzc6i9ktl/
# DATA ovf5hjwxCk4UOrxoqmTUE273nTUeQhnXE8Zj6X+2+wZsU7zznh47kKZpNOnHo+2+hfdwv6VbkF5Cs3vQ7b6vKQCLQWT2DFHDY1ty
# DATA Qq2t+K6b89GVMWhfvPmVI9G6qdXmksFuIvXCT6Quip59tiSEzZ7eq2CYljN76wTTJUrH5/NLRwWCgmgAsxuyqCu8Bq/7bOkoP48S
# DATA ohviFrzCxnJthOdyq5IvZrKxvzA5zqe9Fe8QCs35nAazMC/ABBhbrcw8tE9TYFs/VlRbMWnKZqVZae5NKHkStP0tArqFWkvWy1F0
# DATA vpA06uQ4mGqQw0ZlsKRE308j9qgX1LCzKMs0q/AlMt1ywlUveBClBbzVv5x+AerU2WenXysG1R8Zc/X52X9jXNW/e2d/B8zU6e8W
# DATA 4Vb/DFoVA6nAsfrs7B+909+f/fr0z6dfnP2KAn1c8U7/jW75E33/Bb57p9+Y0EDNWg28+gW4VvRfx7R6Hki2VIfxPJwNVMFYAjtg
# DATA 3LMMEWRtxTwShHBNQK5cdU6Yk4lLY8JOC+6XBgrME8qlBH2c7K8VRh71HBl7utYirF7HBlq0kwidhQNY2QaodALXTa8ql8jVsasg
# DATA CR2W3rsUWcVVzNz4Jle4q4FV0ag3VZt+UUuxSTgJgxPeR0j140HkgFXnldvWOVWvoxlwCUyjFGdFWbEex/EGDNiW05ce2e7QMlGr
# DATA INYWPL3eD7H8wzQK4wjeaDAKqE+NUni78uUU1S/GEzKH5pLD3nieSX8mZtiJUL378TRaoFhtUlNX2zOlpve06FWbJMJxq5wVcGkr
# DATA QGOqLjH4vxSep2sa+Lc+7m807G866l/XoC+VsZh6M8g/rcZyFfSpYhK9YTSawjohwwMIZhO5PMHp8GQ2HGNFVpJ+S4ZaCL3jhMuM
# DATA PwAtjWyR1VHqMEEzepsM/OCIxslMZ0cq0ma89QBrsumctRQp/uPYcIHWs6fU7gh4mCIsUUd8pksGYo79isFcXByWQcB4Ih4LMjEh
# DATA 9tD+w4J5wfsA9SYKhQLil7CAAlBT9A/2VMDO02vk81kCeag+k7ocYMoBphxg6uoAU+eNIxvNZTY3da/Rar+M0b4dm92RpBxJypGk
# DATA HEnKkaQcScqRpBxJypGkHEnKkaQcScqRpBxJypGkHEnKkaQcScqRpBxJypGkHEnKkaQcScqRpBxJypGkHEnqmSFJteqNVq19SZLU
# DATA YDBohv3niCRVXHneiCNlZ0qt5dXbnU/2Gnt+p+P5zcZerVqjv77n0z+NrkdfiznUjzq9enORB9VtezVQn+qeX+2M9/wa/dNQX0sg
# DATA KMrkar+3DATldyVgSn9MA7dGH9Ut9FK92bKKXnGQBEpUBFdFjSBqRgsRbbR9r9ahZDc9v14b1zt7fqOpvi3EM+r1BkvjWV+sX9Wm
# DATA 12g2h62q/67fqHmNjj9sar04i4HVbNSiZUEu1thWg2Ja93/UbYyrXq25R//4nXGNXkPF0sHnvVqHviz+UHppp9Oq1/prXnoR1JG0
# DATA EI06ksZmoY561bZfC4uoowH/z0Yd0ddgUC2gjgZ+OOj5Oeqo3aOsCgzqKAz6zW4zRx11Gs2q37xy1BHvMNlj08NmCanIFmefPkZC
# DATA T/5LzdyeDNhMI5kZrIP88MiVv3kD+lDBCdcyTjhZelsEFFlhLzrkeYSVbXP0UPRgUziRtjRq5QC8C4zXax5bP3ivhBBZJWj7Aj0x
# DATA oVenp1S4bZRqWxVtMX9WJ8eRhBxJyJGEHEnIkYQcSciRhBxJyJGEHEnIkYQcSeilJwkNFEeIj15RgivHtwffkUvDk1BWDwH7IeOm
# DATA kpmfsoAtSr56Yq6eRNQjq8uaPnQP4TJBaHCDcuiQ+UAfUQzl4nERRKR+v0/B88/Z0p/fnkAUCcYCvY/vO1l634fJLBjJ+T6+691g
# DATA Ntxnv8HO4MbxjezGibrZ5gzlJ1ncUWl3VLp4VNo61+QOTLsD06ul/J6Bg9Q4kzrIq3lw4gX4vSBvPmPlE6nPKAEjEY56U8HPkM0b
# DATA jZLj9Wd9x/FDPn48TZNkoM8fQ2fcNFQaf7EVZZ5G2RNom9OImJ4gKTPKEqRPH7e862XzKTrVKFQtOs4M+YgsGwU2SmnAQ+2EnN4o
# DATA nmERJ6HJQ8ZK2AIy6afzce8A2jDxhM9jZ+ZQ9QDO3iM+v/sRXLgFBZOUNd1FQTvrJwk/0Z9PIbMt55rXKWi/ARsiPZF9dB4PUXnS
# DATA BhBZhwogguRSnURRmOnuTNKbzVIxl6kch8ko5LOuiDkllubALAeOUhngt0OK8uiEhcJNtpmyE2UdlknHqXStis5pwERulMyQdLrU
# DATA S45HXjDKEj4YvFYi/B5Vb246cmyb3hqlVuGxYHOPrU3OLn1znOlT9Meoi+ieWdxnhPO96Mf3PVZUz3vyPjakRJBHj0d8Mhdn47N9
# DATA 7w1Wa+a662lADaoDRR6hIrVBiI1AHJY5hqhU/YPZeaLunHMc52MaSIyuILaj4vy7h6M0eBk1nWDMr6OBjktHScL35zMpXGyrmarT
# DATA wKITb85748ooVhQuVIufQaae4TiZUTR/IOGJf4VDJNNwZGdJbM5zB+n4crrmr4sQNbKOGv+Fhc3RCLetbP4BMh+FN4BzWnqnKxA0
# DATA z9mWIniEomBD1Mv1CK5A09woM7JRM1FtD90sxrwrkDi/y92+sZWUmsT1KYG/OAe580DcjMLNKIozinKVctMKN63YePqwcvpxddOK
# DATA +8iKHIcj0dFTimdeG/A6EKXiSKPL7Pnydg7Pw2LqB0yHZS7kdI7qZYCk1dVYz9y1R7d8T3/xdr59XmTtB02ECxdzimdnWZwbTSvK
# DATA 3U0JquxvZELJaLZBLNXtOeJVfS+YVAtRszOzXiSkromaOD3p54JXcoNI6gdNLM2F3K7db58X0dq6iK4Eocr8FaOV1dKeXxqqNLU4
# DATA K4odGc3Se9S3UOvwDs1cvOK1Ot/2TL31xmRSZ169oe45hn+aZvk0kY4OU3SU/JRGZmH6LdwsvpG7I/6qdNhkZmogpzGr1cZ909Xh
# DATA jdFDWTPRUwYsg2FSj7BKUmYsz2X1ZVrANhNWmTwtqxCY9OfTEomdOn0QaRW0DSinL47t7eg7zvZe7813hvYLaWhflLLzlIVQeQdw
# DATA vkF20QC1ITQsOhhoD7bRC5UkrKbQPFX51OdCVpD/u2WmUUnoddtEowWp3KU8ow3Ea6191LmELb5FEK5MgkHFEHTYyppnQ2Vgleop
# DATA dopLyard4q8O63fupTHWbbBLkb2IdAmM+vghbBj2/st5LqYdxkVzhyaQmAVGy5ZdlKqmCJmKPqk6yMBbuJTJUzRgaFpqeVSN1WKi
# DATA a8f7PtasEHOy70oxF9lds6hCseP1C9MmRGNUL8soBimOk2F7trVaxPKpvPSEs4hrIoxmv2Fs+VjbJGH6L8f3PlaC1AKdnj5HRXHU
# DATA oLiwx0smI7PqR3FU8EmsQGARbHVE6WXL8vWl0e60yEFkuPXB4bHYQf90+sXpV6ffnP389DGgP6d/PPs1Q31AD/o5M3w+o99AF/rN
# DATA Ijxo4eHTr89+DdzQz0//fPbZ6eenv6cff8UMoi8rHn364vTLPXriMYL2+J5v6B56h6CFVsKEKHS85XN6A93ogELPvkX9Q+iX8Tox
# DATA 9yaKFnZSkQVBXJKOVu1OTaND8Je1nLMs/Kv6agb3lEWbC5Rp6o3XMoTeGAaiamBJhjuOkGVdqy7huklCy8rl6mhCvCFgmEzNjR+p
# DATA C8uZQoM476bvxTPjCd4yTUigxmwviK/IIvq87ByhTUps6zShu56A1wEC35vNe5EpefHgx9hDO/ZkJ/i+925CNWBiQIhUiEfQe4ek
# DATA B9YIWMMDZlmgNrsE+DySTR8p3Idj5jGKs46NL4E1QiS2DA9aXyVXGzFL2tnTQgetT4KDBrmR/iIjveYEXXKAfzlcZ9c1uF/J2L7R
# DATA 0H6xkf3qB3aplos5kG90vb7WchWgoDxlENGiALLFOM/gccNmTb35T8d3btLOh5wYJ6ILEASYmH9nvgmWwJi2oraE8lvGwYRSl5l0
# DATA S2pN8IIZGk+pC5vMNsIGwb6a4SA/8oFCGqTU2+WDfizL/XphC8GwmBxDjAwBKI0kqwwS+USAyhVrpE+A+UkGgi7Gi6gievdnSHbM
# DATA Ho944FGreiA0lGPqKLBnEG2QNxikyDvtEHX0IEcPcvSgK6QHbTambAg1P9/mvWbj/TK2+5Oa7o4d5NhBjh3k2EGOHeTYQY4d5NhB
# DATA jh3k2EGOHeTYQY4d5NhBjh3k2EGOHeTYQY4d5NhBjh3k2EGOHeTYQY4d5NhBjh3k2EHPDDsoqg6qg9ol2UF+p95vVp8jdtDiuvNG
# DATA /KBDk2TeRVhkzYTNKBxUV7Fm7rzaj1PY/wL2qUlCFNinzSINLG/g+4owVLi9VW2cc7vF+aGwPbrHo9/2/C79rdK/3eb36PrI71bp
# DATA Wsur+Q261tprd/dqjdqw0X23BmBRuzNsN8Z+vbnXaA5by2LSqK2KuAIY3TwsVKBGzUdk6A3jPd+rHgmiZ002RoNet7UckVRdqJ4U
# DATA 52atOmw1qu8i1Y1u86hRHTeqjb1GlT6VEUTdoN1rLQu6dnEakNR5TQOS5mPRgCgZ/Xa9SAPy2/VOo2vTgGrVRqcZFmhAtU6z3gpy
# DATA GlBvEDbC0NCAmvV2rxPlNKDBoD/o9K+aBqSMkuWOD53Wkq2lRiJsXNtbb4V4dDOGnfzeMvjHTJSWTYq0Gw1z3Upjv8H8nxrzfxbX
# DATA o1rFSGnjxuqmxXbhhFCOB+neIabG4FlUw+iwYq2925+9Wnf6sPKterXZbvXY7bdbWR1S94JB6Shn06h/USqRtnnhPVwwqawVudWL
# DATA 42opXHzCexn9MI5uhUH6YDV7KM/hih311TZHyeyVOsS2kyMJOZKQIwk5kpAjCTmSkCMJOZKQIwk5kpAjCTmS0EtLElKknw+tY135
# DATA ee7iOa4yhke4QXLKm/JI04WwIwDNCHSe/nifYT5vJGMWQF845M3H27CUJGpVAQ6qJBN1fE0L0hYPikkblYmcPmnhzji7M86Fozbu
# DATA qLM76nzJo84rxQev5gj0vZi1LvgsLbsgy6dn9VHoZ01u4zr0uNXggqpD9VVJhiOVO/3xeRLN5lnTYeVXjEhzZ6k2d9MWafb9alGm
# DATA ublG6poHP0i6qN6LL7wqtqxRUZZ7coFr/dCrCXemtoR0i5d7PqC+T+GFuJ68ejNRIoFLnmhxdtHY4t30Zmn0gLUiz32syS+yzYAx
# DATA DBqWTy4+e1NSs4FQ9Vu6fqLKeqiyz69K9btRkM0hGo2Dtf0gzQWq789Eko96kiSZyQ1yrBmyPsEhxJ7hjzqmMWvf+yEPbqPoiCoN
# DATA OkB0qmMVNjdjBadJUiM8lCZkTu57H/ACgJhG8gDrLSphPxpOTlDQVBDxrCBfDZhW4di+nCP10jnOeOPIdYAD9tBwNOM59APJYqM6
# DATA y4Wf0exsnk0j0T9kxexgMh9gIE4xl5IAwUUK48EAV+Y91lOPMU5TYIzdWWbrKRECSsJsY4HrF+Wcr5O3duarZb46e/WlsFcvqm39
# DATA lCV7eF07X4Bdr219l0YjNhrZgGQ7NsulKJijkK3RuL5usZ/nQu/iKmStF+v11qWtl2o6XVbeOl/01+aYWBTK9olAFuU6l4tas/lz
# DATA QiaNADV5KYhet++9LrpBNEsSsZoomMBE+QgiQiL3kmFwY8yoEBy5usGMIqsr1sLPZMMlZPOQUfeA3qCJIRerOD/QQixG1cm4w18u
# DATA xZNCzjhjyBlDpT7VefOcN6/Yd660op6yoCHzgAEuTkYj0dkvA7tVOwmyXMJv37snnG62kpbJ8xW0/KZp0o9C0LhFii5JP5lH4st5
# DATA Ej733dhAnQ2Nd0YjqGYCjuOZoKZlJPVYy4VjMOdGfhjMD2nU/ICGYU0LrHAAYpbIco/CO6DDCAYDOMXYVZK7PM04/fYE4/1M+LVz
# DATA RYuIxr0ohAhaGPVSGpGFisxDKIsAYofSWpS1jP65PKPggAOqCvCDsqagMg0ybV1AOQ7+mlScpUp8mmyAcBT1gnTfewf2E6JJlZQy
# DATA N1AgsDBABwMkQm8kwmtDFsZbJmTIHzNLtVBcshmo159QwccD6LyNI6z9xf21MPIhq1pz5ZnM4MFhL7JJ8keAciSDgXdIQ5ZOouyT
# DATA 9EZzytR+AMVGrsfAqwfHwYk4pnQ8VRlm2q3D2cfjAAWjYk75kokCN/xLrMJ9oGQNIYWZ8skCVXFNdS6ANWaoP8wb8XoUgWil11ml
# DATA mkcaGVsgE8588FyoGoJTpmWRGZNQ4mOQSVj+KR7RzxXth+IE5LCdfpCmJ6zceJfyLGC/nQpICPMCj9Mcn6OAJfnyTHovijlV4idW
# DATA 6pdwyR0mSWi52+WtCTU0Gg0H0taKRXg52Dfa8gmrPlIf89qFYd+I27Zh32KXx9LAlX5hPAE4PgqvAPr9Opj3Si5UbR25Asb3RyUV
# DATA 0it5E8O930HTkD6GxjXZlpMJMWe7b+NTQB8ZSiJWiKZBnHoP4C0OFlN3lUTxF2OqY8FlkiAND+Fbt/Ey/0NhZL5hqAvoMF94p49P
# DATA /3D22dmvF3ky/0L3/fH0d4J84buY/AIqzDenf6KPnzNL5nHFM3yZx6dfnX4OXM1j/LSnn3rs0dfPdVB0G73wF2e/VHAZisfZ33nM
# DATA mPkd2DSg0DiozHOAaZxoZteCL24aJUBAq5F7JgLTb+j5mvg9DnnbNgY5BQ1j7V6WF87JXWbgo+jpoXA+CddSZu7yLfmbHWOmMJsz
# DATA PcN1U2YWy+XqGDOcQHPXdyEkTnk9GpTvC6H9bIBe2O87S4OTbaJlqA1kZGOnImBOMw1YYzwTQ0E4uMz6oto6VcZ0QmFMZjyf2BNT
# DATA h8xXPAWR+/ihx/XC+4C3B4jb9hD7I5dtKhf2ITTatdI3ymwSzVjTHHs/aAzPFhgy62reajtloQ09LX7Muug7eowb0p9oSNc4mUuN
# DATA 5C+HT/b6RvErGMQ3GsM3HMKvegSXulhOdr5t8im2mKtAypQTmpNljOZEHnPKzShQiBm431huAJ6uCRVpJqu1SIbhZ8iwCvTEUZwy
# DATA LgaFpbEylPIgw0UcGTdEYayGysB6AYjMCawt9u1KiIeyzQzTBPrYG4nH7TCN+DyAZLve6qZ86zT6QwqBv5/LIznA+M9Zklo2QxEz
# DATA EqUOFuNgMQ4Wc4WwmHPGjM2Q8Odattdqnl+KU/1Exrnjwzg+jOPDOD6M48M4Pozjwzg+jOPDOD6M48M4Pozjwzg+jOPDOD6M48M4
# DATA Pozjwzg+jOPDOD6M48M4Pozjwzg+jOPDOD7MM8OHabUbvUb1knyYwWBQCwfPER+mvOa8ER3GzpZ61fOb7WG9XT+qdRvfo+/FHOm1
# DATA 2+1GuJidzZrnd6qUoe2jWqP1PfpefI7qZqenuCxcllJWUnAnwmGpFXQlGt1iGTcapYj0om67HGCtVr9sgGG1W2u3FgLs1LYbw3rD
# DATA 324MG1J1thdDu1CoLLeQh1ahXDDAFaVsFcpWYmgXylZiaBfKVmJoF0pdAt9eS7lggOe3lK3E0C6UrcTQLpStxLBQKM3GdlvKBQM8
# DATA v6VsJYaFQtlGDAuFso0YNmtWW+4WS9mvl0JUF1KV++XBvxXVSyiuVrcRNJbC0pZBx5rNugUdk/BTgwSzjBQd6gI/rdZ8sgCana4V
# DATA QLN78QAKSei2njAJmwVwEZ6Z2GiaZybmnsUzCxqtRj0q8swG/D+bZ0Zfu9GgwDOLOmHQC3OeWbvXajVbhmcWtvp+0Ml5Zp1+I6hd
# DATA Oc9MeT3UhgYzExJnPNmS7KCwvBd6kdrMzzq8Urlk0b8Ycplj9t2IjNg4qEhMSntRlgRnOyJ5kacYulr3PT8aZvqyfJecvp0mx4fR
# DATA ZktFzU0Wp61Qy6vOts9E15Gi27kmE/mF1UO/bi0Sq3v9WtELo6sr77EcBmFyzAsxWHGrerrOWXnbZYcFz4rNbG7Ffjo9iVW5XV3N
# DATA QLPz9ByPhpVbpTrJk+WaA6E5EJoDoTkQmgOhORCaA6E5EJoDoTkQmgOhORDayw1Ce6Rqd0wFd1uhzPCZEl3hJKmLOLqHjJDbRXXz
# DATA NnVsVGd2ULXi29WD+FV+4iC+cWP3ES7ybQfxYOc4npB1RXbYyXSWvAYj/gNAMcY/4nB2H+kWNL3NoDUGgew0at1Gt9WudVs3OUq7
# DATA 3+E/Kgq927ABf0iz93pNOl5/9yBMHsk7yq/Y6e0efMqymTu9H1d/cuc2vWv3QCTfcOHbHPQN/+DTiIx1pQVnxUX4bxzgjorHLt2t
# DATA 1Eencxr1VLf3qUQPleO2+vmnSTzZ4d6KchB8ODSGG+pHWaDd2QkqPSqO4EavQtZjbsmr1I7i2yut2VGMghnFdoW8Lc2Dyo3eJGmj
# DATA mSNeyza+zAhwgBztfoqtBJNwZxTvHkgeFX/nVWmauKuu+I5f3S3egCFYxecN3Lsvp6epsn2qkXXm6KdTVnHKKovKKuYwsFNXceoq
# DATA F1RXWSmKfQWqKx9AjksrgIwS1vtgzS4jvPJ0hbyug07HpgBdFU+Qlww4Medg6dRDeY+kvhfUZBeIdL4FpGvZODp/DYyOzRdUfXzA
# DATA /ANFUYLRqXtyGJ1+aIER15KgHoqJtJolx2PSW/Cun3enL2rAZIGedyMr7H54HI2oEz3n3lpV3TshE7h07+boOq7eaOVcos8tte77
# DATA mtEg41FG1kMUGqk9I69DRpaRxRHzvSy1wyS5zWR7WMTGy5J5CpbvQHAq0N8WqxEaDjmfTrwWZCROlIwPJfHEU4fujVgMvXNBLWZY
# DATA v2Pr/1Ca6lQwI10obJHZuWlt1FUlMNqINvciKIbkY4kzOp3RuWh05taFszqd1Zmda08+Na2/+4wa4kiyixvIUVR/Y3QaINk47qeJ
# DATA JYE3ZwtV6d8F1LomfdAtFrXvzKCYtyg1GGpICUvJ9ZPxOEr7sR4D2XJNI6y0YOPCxtp/nLLpnfvireqdwGcWYZcJhlEDUBL2Lw2m
# DATA 2EuxRH9LnXdbNFGVexY1kT8p41TZHPrH3AAyV/jgM9BpEYej4ifLDSI4qCO/1PY0Pl9wgtTnouVp3WE6SvupBcMOTlO0BbCm5L54
# DATA nR2ojfM32YBbdVc/AXGDmssR3/xG/nX1M1yJcPf7+LDGupSBWVt44kK1TRIMEmvMu0IJY8+HNGh1tDNHOlCnZNgd7LGW1R2Vl3Ze
# DATA lHBAvBvGtHNxBnNtSud8e+0/P/s/WyYV5WirnFWmmJKqpAqSzk7EGCP7jkcmMHm0JcmDEE379mB3hTxf9O6GIaTx6GlhAfXR2Kj2
# DATA 80SR+clgr+BBNv9kdGQiiiYmwzalt+x7rweTnAo4CWVSKj/dAxEGL6lXaZA1lCB97ORS+VqqPZfI3sbq7C3URcll2Mtiw1NCZsFI
# DATA 5/Nd5snQIDGtSK7piTXnWoBNALN4HNlQtulozrNnml/OxaJnApLy6Ht34zHyakDWWjYErIpNb1zya/g6TTI20fe9twBfxGvCOOvP
# DATA MxQQhySLktvIZdPeLpq/q/NWtVydq+jxqeud4YPO0zextyfw6v/x2zpYSSHlCRYPJuCZHwMfRHVrTnlHZSFT/MzzqUC7cFrI+ks/
# DATA ojnIvvc+ddk09b4rFVuqLwhQzEni84oe3BsH3uv2HThDKO4SnkmrTV773vfoa8QVmcp/axX50lm8vocoZPNHNNDSJIOCSHUeG3N2
# DATA QA1/T/ScchYYtAOpfqEyTSUPZcUnk75A7kYlhZ8mUOhxTAjlwfegXYqTgRnrlgYmkGCioVQVeRn9hiUUiRtn+mEskqfgkR3FCbUQ
# DATA 9XAgPc+z0Xm0LtR5/Nd5zCufevDWhSAZTPWXxjhUbK6AbANpw0imQ8h2LxvFU8pPbhzctwB0xtObHuubao8gFFQxqosSK3dN3mE0
# DATA k6LjLMRCYpaMI1w4nEfcceDpeCITFeqXZlvpPq5+8HuDxyUwkWJTtU23KG6N2XEiHbJkLXrjTBCaIpQcxSmNbscIRddjlrGNjcIv
# DATA TdfR9FPV8skWZFVnvJO6JpxWpN76SE3uKGw8MU6wkMtzB/QUjJ2Q7gU2azlzi+aKLBvb5oq5Ipl1hxqYWuDVQsIyfoupaJmv1NyG
# DATA 3PCkUPbPYz29CC6XfLblXC7O5bKEoOC8LC++l2WlA+WZIioUjgosjpQjm7XgjeIZjjizEgojMUGxVKMJu2DyB/k8CWfs00YwPMta
# DATA 5efxk6yDH7IqyUdf7rxKHWm5vemj74XjdR05y2edy5cLwUi6wzJOYuFIurTffoLaIW87mfR1VJTKY+53s8XsuTyWgDms5/gLp0et
# DATA xAxrd+6zTW6qCCDIweTErFp9LzkGDvlE1Z3XPL4wh3eKrKrXvDfo/og6UxhDMEJyS/g1TMLiMVe4SXYss4cZNtp5vHTM+vuxIrpq
# DATA NhVgtAHZZuDjQruMDK9e8jBa4EUVa8u9mIGZ7ICk7Jj3Z5RIKfaXYcnJ5lwmzOO2KZf/zFjKfwVy8uw3HoiUp78//fL080XCZenO
# DATA P+fAS9xf8c5+Ttce03+/Of3SO/vV2S9Ov8ATuPcxbv9KEJh0+zenvz/7B8ArPfrwGd32J7nVcSyfA5PNy9jvn6oDiKavR6J5cs49
# DATA wb4nu+W9bC4TVtmQz9xaeZAbMMYMHkzYIzCRadQAE1ZucPCTYWlhyJvn11AsXxcZMEFlOIRl0YSTRn/dAMtSkVwdvRJ2wJHV3auK
# DATA xxR0+an8hKqC5okPVJVEFZzAI7ZVoCXvlhgGGftrgP5RjnJlwTio5aYluHW85V3YpYdiqxh2dIW7zRAONg0IMn2WGNpvxoNB3MeG
# DATA fGxblh03kWaA61snEYVBP6fi7l8gWm5UB1ebJcXW9bS4lhslwgEu3Vj/BGO9xltefIh/STw01zS8b3t032hwv/DYfm1Du1TLQjbk
# DATA mMun1m6uAnJZSCOm5EExYdhWKglAsOPpTIbCaYquB5y6YdCLeeFvlulSoycOD7HA8oCqQSbzeKrHapkb020Zmc0IPIqpQmL5Swh/
# DATA GRT/0k0Rl8hGwwTEtIHiP6KuHmfYsAai0I469rztdQErqWrSXsFYkAUhjiVLpCAU5CEyACuf2d40SvfYqqMSmI+5lz2wzATciCjv
# DATA kcG20mxwDEzHwHQMzCthYG48wGw0k7mAPXx9pv1lLPstGfYOjungmA6O6eCYDo7p4JgOjungmA6O6eCYDo7p4JgOjungmA6O6eCY
# DATA Do7p4JgOjungmA6O6eCYDo7p4JgOjungmA6O6eCYzwwcs9aqR8zcuiQcsxt1nyM4ZmHleSMypoV685s5ZbFepIq1Sxlel98lx4vI
# DATA skanVW0vyXBgN1u1YaMx3ms0PL8zFNSZBR4r08hy8Fh9AfpWteJaQqotxLXaWhXXXq/VaQYLca3VKK6d1rbi2rXi2u6sjauC2S2N
# DATA a6PX4V+Lca37Va9G9Xc7ca13tlIH2v1OK/AX4tqobrMONNpbqQNhOwhbi/W10d1mHWi2tlIH2q1Or91biGuz8+R1wAqOQmu02sNW
# DATA vXrkt77XKeFxqUPtNy8HsaO+VEPspFu2IHaNFnUbnQ0gduGgWYTYNaJGWM0hds12q9luGohdv9OPev0cYlfvNjvt2pVD7LCHak9W
# DATA N/To2rD4dRatrsM2Z37/xbh0ZadrPV9qbYnTlUPmcyqb+VJb63ypek6YB7q4KqN8zXqagYmCmnJ1mwt0OPjUsOAk/6nz74YLF0+o
# DATA TnkdIcNJZWgU6XSq1iyj7F2OGCcrBmoRd2kRGNde2V+wEjZnlcAa23Sxxji+nOPLOb6c48s5vpzjyzm+nOPLOb6c48s5vpzjyzm+
# DATA nOHLsXqjQsmxz5MS/R35yof36OtN/auA5tjY/PiVt9Txv9CchMRhPSaZMZOtH8WjHQ6dyWqin5ntf0z/m9yd4TYJVv2gAGzqG8Nh
# DATA dLghTbg9PsGzJPCb5VA4GOvRjEcEgztzOojuoP3qg/bugP0LfMD+ouqHz8zB+9yxtV4NkUXe+DTrhEYosiwgsDyk7+u0EJ/uOf3n
# DATA 7MTqeeo7uaPyKrQRSyoEWxZGLOs4nKOKeFcBelgMgXKV2lDGgRlpoffn8MbwDgbvcA4oWC9iNlhgqX5D94Am6xinvXt0NYHIvVY/
# DATA FJkoRjQodQWqt4kWcJYT5VzVlXgDsp/PlOMcek8qBJ5GnYseTmVaoVSmy6qHa5WUSk0O3msbfsGq2/cTGumG6rS6bH7V4tvvBZBb
# DATA NDL9aXQcpDhQrwRFj4ORHM0PVAX1RkgIcxLYgR4HqQhTSOSL56FnAYuk/mA+Q5LMIeiyRvliHHUuG2rDREqCKTbcQWAThocvYRQY
# DATA KfUgY5UGJawVMJ6GT6vHszXRexvUmwtEDr2IiZglpKErEgQwMyr8IFUAg2SUKR6joelwMOkD7xi9EMcXp+3XRPJ9ec2STHyJTqzb
# DATA oTgb2dnIZRu5VKucLJWTpbqMdbzSGr8yuarvxtwG2EgIlNCTVrChHHtgaVddsybidcCBxbnDEBxYj2mEnINK5Xo8sH7M9E7mQk64
# DATA bVTPQwTXq2LIbkAJFq8TkL3GwcSX2CWEl58TYf28ibC5kEe4uTzCEkcVZb8c5erqOLNrzK66qFo7/OKb4pnaPTebixRm/T2Pc21p
# DATA nJuXjbJ2mNEN7y73uZ0T4zwAE2nrkpXXS6NtxVpVHx3pZiHOK4HIr8/jUWiNaOgtnl8u8rsyDMvoHkz56A0vYOu5lAEnc+/Fp0SU
# DATA OpQkf0gPReBx3fUG0TG7tNlxPDMeVehgLRGSP0xZqM6M/5PoSDOvjATYD1W/rrtCANcCYNGxf5YN8n3vr8lSCHneQz2j1c2S2R9i
# DATA Z5CormlGpriypSPlxkIpkjez6YEpHU0zhAMXz1ZN2V5gI9weXZ0R7ozwBUf1grXl7HBnh68zq58d2Vg12OlmwD4wtAVbBR64HRqr
# DATA TCs8yoc6JVFayVVMeagxAqfQ68TeKow6CHwqkp0YXpUTEW1uIECUbB4LZkYOg6zSXL00PTl/KTdsSOD3UCn0LIJG59DxkzfhJ0/Y
# DATA h4onxJu6+k5xJ8sUAp/WkJO1W9Fy/oFi++wTlPPcuCBG8sPVCEmdrwKRvFvw3MOlTVUGUNo0QjGVgKlpdEg5Zvyz7IcVJBb9Z4C5
# DATA s1KfpRqZ8Y1022QW04RZViB4rrzvvRGk6QlEWZNJ0T2eBsxsZKt1lp4oLzGLsmIPZCoRg888mWg/uZo82I00X/3RTSRfXTJ7IGWU
# DATA X5N8k79aRZEu8GZfbpgBGKdmJvJErNC8Kl+wmN9aXcy6UahiNk7/fElG9lpwj6EL+h10sTByAmGypmSx61WOzELWixaAKEXz0osE
# DATA no2S49GJSEKnrGyMzhVjkVnqoTLnDXzoIIemV3yiIlyftGsrxEIvc8Fy/GANzDjvr3SLFfSIkkhOI7BYaciZhEoMnEtSk8DydhrG
# DATA Ac0Cx2ygDqLZCY2nc+RxrJxXgW7JCjdmJvO86EKja85Hy8wSDg2+DzEjZZ8be8CwQBgLcO2J2+a6hF5buV66D76/cR9MFXZGtwhd
# DATA N/ImzN7OHpws9L+abSPFCqtGhKbZyBhG4zibsva19w73mAF7CUZBeghZaSgzTjLNqT9OUulfpa1I5zoIgEiGW2Ar7XJ5qp79bvV7
# DATA G3erauwi+wry+khqoAaqMNAEa9MkZd0b3WWijUWxQ+Ft4dNxEMdBUSq+dXw4gatHJqLawoRjhaXBYXSm05T16qnXlWLmeGyj7W2Q
# DATA sOeia33zQl2rlnWHYRKmwTEaCO9OGMUDa6FaOdf0Hcp6iAJsC6XMgey92Du2PYMZDReWNnn689m+xy4/s5attgf002CKPOcjoXo/
# DATA hfaQPVm5rk3hpUr0egHeT+ShffF9ijkCsx/RaB/3syIC84uzz04/P/3T6eOzX9Hnn4NnCWzln+jPz8GxPPtMX1yGxfzm9Cv6/xen
# DATA X579PeMuz/6WoZh/EiQmB/17uvIr5md+yeRM7+yXZ38HgObZL5mOSWGffnX2jxTEL+nvb+idFAJu+jn98Ef6me75A73k8enXZ792
# DATA mMznwlGKbWnorlS3qGoeB53dEl8UD2E9mh5U+PshNrvDi9oHsk6BWo4C9lwFZopgfK6BBy9cf7jvvfVwOoL5Qp0pCguxVgZNrg68
# DATA lp/5xojGL2mJiJ8jaNo+VN1nXDdBc6FQro6hyZXS3IWthbymrjyAC8RNqtpxYm6/z189iHbNRxAJ2yZAM84kKvAeys7GCGd+A/CD
# DATA TqKZo2duUnZXQM7kVVJeLY/HmOoiNFMBVPc0i/iIWh/1mI/1e+9GQTZXy7eUY3NAoZiugJKjvtL4njPmDHmzeBQpl3XK/nIykML5
# DATA aBGnuVmVXG3plNva0yJqbpYOh9R0dsFV2AWatXkZc+ClWE69NlNg+5bARobAheyA6zMDpF6WcsHGbT5rbeoqOJyl5HOi4aZmdqGJ
# DATA TBm+qRWK88w5ghNjpHic9kEazi1eejbKfzmAT78NmSG+HI2vzB5Esz783pviOPMR37IYKHJZPvyPxU4IsS8PqlFQqKH4ehIin6wp
# DATA 2AO88E1xS8I95cdHO88y3kfm8R4usUW0U5FGJSRX/FGK1skbJdhtFZhlNIfedOhNh968EvTmRmPNRlOgixjN1zkFuMwMYFsTAIfe
# DATA dOhNh9506E2H3nToTYfedOhNh9506E2H3nToTYfedOhNh9506E2H3nToTYfedOhNh9506E2H3nToTYfedOhNh9506M1nBr1ZbzbC
# DATA Vu2y6M3WoD3oPEfozdLi80bwTQo9pmHR64vMWJfzsn8idMNunrG1huhQ8S+1VpFf2A0HUWcxl8EErNWHfq35yV7Ha/pezff8apf/
# DATA 1Jt7nYZH9vFet77X3Gt39/xay6t199o1z2/Tl3qxMFqdTrMbyTuKca41anmc6X15nFu1PMpCFrUqRrPeihZRlu2u5zfbw05ntOdX
# DATA KXrtT7oU2VZ9r0Y/tDp7vt/Za+81m3t+o1uqLX7Uj/wS87DXCgZBbRnzsLEsKQ2JfV/FuG1BGBtWUop1POz0+70lREa/49VrnU86
# DATA rb0GpaTe9aqUpo7n16qf7FFZ1BuUQt8roRWDqN1oLY1bs9PO40YBW9nctWpGtUiL9Bv9RusSpEZueprUKK3YIjVSXPrdTUiNhSsg
# DATA NdaiThRapMagFbbDnNTYDmthYJEa/Wa/U79yUiP2tu+tM2lowLV8XGIbm4e0JWNDCZHKgV+aETc63/bwL5kaHpsbeRB6vLWWGOVX
# DATA Nic39PrXrPgtnUtwiBAUtn3+VdzNcxBtmh5YBnjBFarK/WJgRXF/5VDIUp40KU/o37r8W1itajQNNrLd/PZSwqMYi5RmmfPly6XW
# DATA AtZyhONKVOO5lUHbk8trgWRKzS6+jcMpFQ3PYkuTIceBdBxIx4F0HEjHgXQcSMeBdBxIx4F0HEjHgXQcSMeBHARo3Lf9PeEpyqZj
# DATA wB/JmtHIx/v6vPtxpPyZjHvcUbhIXMATEhSq6j1s9NvxGcnYHwv7sRCImqtaociV84MREVmIJ6vj9HLU3pvGUT/SpxFxRg7+wx7K
# DATA o8iBzE/euNPh7nT4xqfDy0e03EFxd1B8ve72M3OA/H78UJpQhcanyQmW/GM5ZGmDb8yRR0s0FU1mJIc68eyDxVPPOArKPa86Oz1A
# DATA KHIyMwtG0QXls42qpbgeuYnTzckYrlH7nLdTzt5EOZt3lHBVxIfV96G/xG0/or9rNLNpUJwJ/vB9+fg86GWbPLigSOTrq0UiVW6K
# DATA QOTrOMU5wLFuDEq5HiQ2y3hkuVNVwXlwnM4Hl5WmPCcQ8BzFAznBnMyYApHx0AQXFILxBhHVoxEMIpqwJHLwmFOiiShPop152Sx5
# DATA Y8MseUtrgtKYrDPk9WAEXQHW6uXoUmPiC+bMtSzhsKyoN4B3mZ5GTvECCc/rwJyjoRl/qAmS9RfLyXwENtlGxuh2cMF8+dHqfJEW
# DATA pWrKPGTLJK8jkyClOak3oTmth36GwaCQbsWCBGQGcvgPLBquUtFECGUQJMiYI0Kfp+jvj060cfMU68h/2bCOvJ/MWcPip/PDPD+0
# DATA 2vRUq08n4wE2jQDTQJ3AFNMrNAimGSmMUUimBg1mfcq40TCZ48TbvvchJgSsrcBKCWLXHY6CnxmhjidUn827wgvmz/trtGd1pyo5
# DATA RPNrb6ovSQ69nyZHqAOUZprdHEYGHcub5KjSBPM+VDjuTrz5BMnVPQwEghmICizTCMr7kIrmxeWn2G4+2LDdcKVWyi0WspYVGcbJ
# DATA HOrjcyhVjMR4SPmMLPz9oGKFoe5ZoLQcS1fKZpktxBtIdaH+upwf1ytl+7IoNORmtpuEu0n4xpNwN+N+wWfcKyfTz7RkG+9jMTta
# DATA hMrKu1ruvEoNulzCev8lkmu21XVkK6W1OVQuBCP+VpY/W9gXKRWmn2DnkLzsZNLXMVEnje/8YGFbpZ7kL6rLWY/xF05NYXwfFche
# DATA gE8w64UVx0KqnjSB1/6F/CE+Os3DzTOqW/c8yTltKGzrmS1VUn0LhoPZQLXGUPvP3/6TNiP4lcOaSNmJBenNotGIpy4KNCGKXt+F
# DATA /Zl5h2JlBTOmRYRQYaMZy3A+7uniCrx0eDIbjpU1ywYrzw0OY/lZLD8WI8O0GaJmluaXx3seIdKlpJErlFtplAvOGTVAvQItmKEc
# DATA XXEcpAuausUCZaiRMRyZWPUSympZwTirzVltG1ttC/XNrZ24tZNLWGwrjcOrFN9lQNNA6eizmDvymhfiCxq8T18Qfp0hgHN+nr3W
# DATA srB0IrYi25Zh4VphTUOW+unyPep/+ew3X/F2+uPzQPf6UdOdmQtmhUEOiJSR8X4RdG8j46v7/ur1F7WhwI6sXNoktuZhE938iolv
# DATA d5vRVRsv6Pd3tf7vLJkVqsTOt8+LtgnERDu/ck42V61419dGW5mvZsFMdqXyKpdU+Yi3eJimkFmIKNSwO6/KmWAVZ7U92Xaq5Zek
# DATA /4kFVTWlsVsZsTcliCeEP4ltxSitvAuwVal/mJn9JWh8xrh9V5ypRqmZkcPHw3gU5f1EDLXaGfbqpCx5a1Y6qDVHuXgzywOrFU6Y
# DATA uLJxRba+kalbqgJ6p5UXKlSf6Q20djC6VKvvoVTNx3Q/tgfn4bCedD+YQDt4SgmIcU4xSKe80MueY6DI4a48HkZiwOcdF1IGoWnu
# DATA 13hhi4yOfU/B7JBCIzSdzafU9Sj94KK49E3O95fFerYgXDxH5zmEzeH6LTO4vjj7hfCuQM765vQPCs0FOBdYXJ8vErj+hW57DECX
# DATA oLVO/80Khz4xYOsrukdDtr4++/XpvxtK1+nndONjftfvz/6BCV046eCd/u70i9N/o0oTjBxw67mw/9m4t7ZuABWYJsC7jtFPcH0z
# DATA dgyTWjPIk1OXxOp91DNORPX7mHXDZelCy25XFDf0EI19GPTQT8lsXdSwuc5A7LwXYYawDrb1Ed1lIuRQWwXTP+8Zrpu2VSqVq2Nt
# DATA Ce3b8J94S7b1VuvOn2ZU3PrGYgXbJmIrELCVhiuoBUJJjMNrnVNcW0drvR+Q0YmfKdbNaqVarfKoQRlAXdS+9z4NIMbqYYIFT7qG
# DATA wRRrwXrn/yzoHSCSgqPODIQCxRU9pIEAZwvKDK1zq9tqM6XYeJ4WPOvcBDhulhvetz28a2bWxUf1l8OZd40j+rYH9I3G842H82sZ
# DATA zaU2FpJu++iepTZ0FYysQsIZ8ZMpZrudTJp0B5laNAuxaNaDZR5gJ3GFEhoD6UONJqYkjGKwpCahfu0giEfwV/YDsIqYLVRMFkbb
# DATA wGT0mAY4vcAcT7IpkgQXKbWQTWlZecisGZDJ+yj+TGnirehDqnNwr9BFPlPOp83ZvzHBCh/PYedMiJoG4oBNQkZmiVmQmbPilKL7
# DATA J2S8PYSnLA4DdZI9EsMwyrAPMc6GWMcM4NXoC3cF6YoH2IDYH0bjwOOd70zhmvJY5FBaDqXlUFpXiNI6dwzaaKqzofl8fbOAy0wC
# DATA tjAHcOgsh85y6CyHznLoLIfOcugsh85y6CyHznLoLIfOcugsh85y6CyHznLoLIfOcugsh85y6CyHznLoLIfOcugsh85y6CyHznpm
# DATA 0Fm1RqPavDQ6qzFoD9rPETqrsOq8ETiLM5bj0uWMEzRT1S/IUbT8TjHD693u6hyv1ruNRZBTt8ZIKhWUBZdqVzvdbm8ZXKougfTj
# DATA lCWo1MtaFluqzvHkA3OdIk0q7NbbrWXPN5sbPd/tdVu9Zc93Gps834l67cAvZ8K41qh7tVprjyp2s8vVuzau+809v+Z7fG1Pru35
# DATA fn3Pb7T32m3P7/h20LxhtITn6oSdsLssBxkXVqr57a7XqPtU4fFqrzrsVkvBmbxbCK57CQQWNyGNwJLWaCGw6q1Wr127DAKrGnWj
# DATA wEJg1Sigdo7AqoXVsJEjsGqdlt/qXj0Ci2ZCe/T7RpP2Wo3GyqLfqjDSyIinQ/T4gJzhPmkbThmfOsE6gFS7VpYF4s1Hj0ouE2sM
# DATA WLg7KJn9xhTvKFM8f0CP2uV54LI5n/YSdthLKKuD8BMuWWxrFRNRXAiQOaJnT3yUIZc/YYbBJSt2ZQzXUo+PrqhFD8MqaJdxHqvo
# DATA wG9sTb/4+zn5VHxRC8lhv2Jh68nq5804fc5rVkzhVmO9TAXfCMe1rvKuntaXKvOyOjkfnTu55Cg4zpfjfDnOl+N8Oc6X43w5zpfj
# DATA fDnOl+N8Oc6X43y9ZJwv1AV1Qj4KD2zq1wxLppwRSN1tqevJPO1HqCBcqw7iARuZqmHeaVZh8MyGgBW8laYJ4vimsrzQvMjkoT46
# DATA PZQ+2bz2dsmYtuYEbMJWMLmoCP0L2xq5HHaFOWYCoe/UVXz8Cts1Yp579/Kj/2RHn2RL+oLdg0/ZRn+UxwZbLQfxhLJDUc1YRlTp
# DATA PhxZwb+BzoeaK1yqFZxjHAdyhopLHW/tYY8yzS/5RVb8lKAudTU4CfVeYuxT7xhnFpX1Sb9xBKlac+7j1M6e/pF+eW2d3cFlSOWT
# DATA p+t2nrLdR4XIiBiViYMWaVRvwmlAxEOs/oNPjTH/8Ssm8H3Ejd5qLtygvgoUNrpGrT0/BnlTbtS5wWePyulVyTWVbW174XQuK7zN
# DATA gqHJHF5PAbG9LHm2IzZ0f5aOaMr3N38jX7EZkL7u/tVfyXd6lPL041feYsTDK7uPVljeyuimrjCb3WeLfUcK1UncOzWFS6kpOBWF
# DATA F1tF4aLq9k9VXcE4YCVFItZnKbnPAlS3O+9pGW5OKR9knUPaMl6dkDf12f1ceUBiiYfWPXif2y1v88Ki0MqnCtkhxoLV9vKnbiKm
# DATA WoeQj8auFLg3JCYlhUCter24/TMnNvEcHK7m/26ZnFAUxdg2N6GsNbKUmnBRlayP0liZbvGEWY1ku8GYMSpZRgeElcsyWMDHEDIb
# DATA z0XD4YT91BUjoC+VUVUerigYJTNRtLc0PaBxELBFnwxmDFdKI3ajM4FLAbfY0Pd4YZD1xifRQ/bxKmWNczlGL8Y5eROCM+6ccbeR
# DATA cVdSynGaWU4z6wJW3UrT8aq0tN4WwSaq2Gour5wIXM1zss91KzZeh8i98izozNVJf1XvxNCK4/o2qKaLpwyX2VlWEFinjByN2KPN
# DATA AASsFfPo9ldwMR2gT5NPt9QFZVHLt4r8Ybe4uu3HfqVWqf+EBkUdoxWS8sqpRu96mz9xlS0iiM0tpm/NH1ogANcY2XCceLyVZA14
# DATA uCGGN7iHpTsXQMErxeSNDyuvOs+vjjymPCIvpWykZRJncyNwNpVWU1ESZv8lOAruSxer1MxAWNFuUDQTlQ+s93Y8KWqhiWpWAEiL
# DATA 7ZJT+lg0YEL0TBBJoxPlCDXNHQpXIsBFTx/jdBcPnaw5Zbn/9j1TXBgRyUae92dzRWEaxWNc5I1GEKyCSBzTLqDdlemolCpCPhWx
# DATA zeR8aiGlVXSdYm6pV/iN61DN+UzNOV92/sWwUPNhxpmozkTdyES1bRFnoDoDda3h+bTFXt8rNJIJBrpZPM6hTPdlmZQFUCsWBVBS
# DATA 572lZRAhsIjjO5xd9DuaSpjwWA1dTlYLDQ4pXthyNjkxepAbKrhydE1shARFtQCCjmIQUGOldh+xviU6jyXeOnXieImlKnsUUMH4
# DATA k6IDKUtG/5gbV+YKS08AOR9xOCp2sufGdEurWUVm4wNDf+Rz0a607jBdov3UgsmInQMYHdExyn3xOgsTLVL7klffZenYCsbRfF0T
# DATA cpTFh5z2N/nTGtu1yAaXnQS2waJo5qvMxkIZY3e1NNZLANh1blwQwP7o09UEdslYIbBjEhdpRrpy2p9oEvuH2DJKKU/nmWz34ho4
# DATA Ye1UJaSLORDInHoFOsYmjAAbKLzenAxdpZga9/e9N2MWWJ2z0K43jjOePcpeF2xXYooobwKRa9xaeWVYSAxAENHrUsVne2K0fakG
# DATA XTCD//Pvv1qdw4XaKBnNkq5pJMK/8KvG/XhmkPf8S05fYu1bMqpFSzWZ6lP3M6ptKev44vDqLBb7/O6AD4XT3GDciw/n4D4q129F
# DATA d3eCihL6Y0DGPkv4xiH/JhP2beToJevqONusrr4XjKUqQMo6zzqpLZjiQMFW9vmKqi10qkfRDEgs2d1knvYY44Hei0EfJ0DLCq1r
# DATA AmVANAiy/ig61HtSUagNCqaBPP3q918vVPmEdcaxp1R8Mo/mkc6/dzCDw6SNJtC5EvNxELMzhy+o4+YRANBvSoPkNQmpOFleUTlg
# DATA ZP0ARws4PykDJ3AhcUAzeQqY3ggURRoqUWhbqXqma79gRr69pu6pQULysLxC6c3S4IjGzWNKg87MD9RRgqESyA6kWqZkw0RhpowC
# DATA 6uUmMwbHISzYJTI/oYY8MT2D6lXH1GtkPJeMIfFoLavmcLlZrOTcI5r/ahVu2H5PNV8/3DRfP2QCn7VchfONeetWy2FpdIj94HJA
# DATA hBKSqSEDo02uXm8kzzP2VeSWYTQYcA7b/UDQy1i8mmZo7N6Re1R1Rm8qVl+Mzvanspu1lKFFI0H2LNpGgrki2UN2rd5dqCd27GxR
# DATA u/6oI+oPE+hnBfCXUknqgngpFt5sjB6VRGQT9P759Juzvz394vTfT78++w24d2c/BxKP/vvN6e/Ofi1ovN+ffn722elj/D39+vTx
# DATA 2W8WiXp2OMzK+znT+PDsN2e/wlOnX9JF5u0Jeo/+/smjW744+3t67s9nvwBODzHopdHxnkHvfXn2S/r7G/zMxL0/ObTe8+CtkZpm
# DATA 8+ZlyvkgRiudyLZgEBt+aHwzonwPc4wshhBKP2wpyPoGfn+gt5OkUT+eKpsrm6M/4tY+Tlisfy1J7w2Jl9WAHEzP9tIgd66bo7dY
# DATA JleH0pOqk68kfiBVSSRPyjejJ7LWHKPjK6Fl847qqTp0QVkhE0a8bRxN5o6nt0GZbR2pJ2Y99+Xc9cDLLH6zHhkQuncTe567sQ/z
# DATA bomqa3KsoD6acM46a4L+5UMHKLR4PMYZHcCEqLANjPhC9W8NBrjcqJ4WYu/8RDjGnhvnn3Cc10i9Sw3vL8kCzLUM7Vcwsm80sF9k
# DATA XL+eYV2qZDkHLLTe02w6V0HSKydVL4qISzVgucnSiJjZQyLivzAmVgSKJYuzssYqShZH0SyZ8jNRxgfaEzKXZsMkzDbB5H2APJRl
# DATA rHKMKHvhIeCNu5T8cYwNJglZZdizJQN9Xl3onUE2TwEGC1hglDKZ/fkV7bZPI7QfTtEJl4zo4AgJEI4VJtXpypAFI8F99eGs1jwz
# DATA R8NzNDxHw7tCGt4mo8dGc5VNjd1rtdsvY7Zvw2p3VDxHxXNUPEfFc1Q8R8VzVDxHxXNUPEfFc1Q8R8VzVDxHxXNUPEfFc1Q8R8Vz
# DATA VDxHxXNUPEfFc1Q8R8VzVDxHxXNUPEfFe2aoeM1WrVdvX5aKNxh0o/A5ouKVV543AuMVqG/1rkWNq1frhvrmt9tFbtyg3+mqvKEI
# DATA xjSymiDqeRCNRjUvm5rQ9uTwVK1bCK/dqPXr/YWCqjV9r1arDWvt6pHfaHyy1/K6/p5fb3rdGv2p7nXwZa9bW1Jyi2i+Zo1Ca1aH
# DATA jdYn7bbX9vcaVA/8xjnUORPYAiau1l6aAR2L3EeRtypnvZlnQL3w3m81+rVWvboQ5Xqr6vlN/5M9SmuDaste2x83GxT3T/ZqXX3l
# DATA 0gnwa5cA3XGr0KA7aWAW6K7dqNcbjQ1Ad+GgVQTdBWG338hBd+1Ws9tqGtBd2O5Xexboru3X/Ub7GkB3aFJ76+0Nj4cX69YyH+67
# DATA EfUCcVCRgEuLeQuouDovmOXLZcWgld2y4KTSObTgiCz5++2wlnngLzSoeux7q7LhpJ5RS2BLk27cqouRNGZ5ESGnwhZ03fKtAmWi
# DATA 3SJmbWnOmIFPr35V19HgNqgFV2WKOLSbQ7s5tJtDuzm0m0O7ObSbQ7s5tJtDuzm0m0O7vWRoNxvmJsnmA1u3BaQW4pTbK7vfkW+8
# DATA 5MhYLoU8S2bBSO5Hi7rxbjAb7vNMcocv7t6gHMBxVHqPcqJNoTEzn/LtO4V33JRv9GPGvcgsuYfteDu+HcpHcpjMCqT8zlIw/OzC
# DATA kTNNEJMpoDnS4Q5Ru0PUyw5Rl475uOPU7jj1RY9TrxG+vapj1tIK2A6GXrussppj1k9RyOM6qAuhOp6taga+ejuHu0rSVje7CTsw
# DATA cgF49VTeN6nvObOgyGIYxyxA11TYBvb9y6ITtljwWtS+v1r4VsZTSDGbYQ3FgEPVkv/nRFc/b+JrLpgI+61lEe5YEa5tHl8eVEFp
# DATA 43hwNOnKOZFUD+W6vep7gQOxEEPfimHHjmAxeit5D2+oFhUZ0aDnF/fwBlt5PIwxwAuTE30g+e0BVDbRh/Ax/IwHOrS9jMySaYV9
# DATA mtRKR/D6j048KGmiksXg5YlRJN56oXNJreNz49QMVYghBUEBwswZ6gD7CYweFZI+Ds78Ca7JUTbDujtPqViCacwWsSUCgNPgrMDI
# DATA y6ghTpJ5snZzYIsBwGRD75cl40h3RO/Q7OUIM6QhAzC4ffexO1glCNHO+5rzAQ0vzsFiB4l1lux6S9bZrS+43XpRKOxTlwfiBXNr
# DATA IXjR6BsVJAGZ+pOx6LbiH/T4GClMkbUM1aeuKvScKHBcBTZ1QQFp2+TUJWpSy+GpmykhluofstqmKbCI9Osp0qqGdVZtzxWkeU+P
# DATA ngjNM4FTaX4q22IR5lnhSUHSJfCwUWI+VvYZKhh9yCJlKCEwqUlFA0Whk+/xDcYoKUtwc5w/YLFXiXJEWaxj/LaZqMU8B6Soip7R
# DATA LE4rrMzOsdGq7AULTSve2/gANkgRFFkBOIKxJtrvY2FufazvA7qiYs3blKJQR/wtLXEV0uwWsaEkcO5VeMpX8U6wWVZUndBjzJLD
# DATA CCpW+55lVCesLDr2GFSgqC+roqtfuBjjl0jAxu6TnKXpLM1llmZhnHIeU+cxPc9AffrClBKDTCkrpkkyZpU6bhC5POVoJE1lqUji
# DATA vqrnFXFWVGQwgu4cmhHWp5kKxp4VT1bvVLviZcSLUcDusZWg1B2lTarlRg4TPd+UsZtwAQcjbGAQgWwHBdsECiYWl21arbrT+LmZ
# DATA 7qK/rL5fq3RyrqrPq+/WMp5F8+PZx4jl+XdBjot/y2+tRrnowhCUyw8mEXUmU3Yt7uHIorYMsb7hN71DeyWj1qjSBeVG/ChSBDKa
# DATA gmCr3OikQnY79v72qF4M8HWG8RIhYw9JhjUPOdWRcQ8BY+s4yIaipaotdLo0GmXb4OBcS/59eJxw/oU0Tk2LuVevFnOv0bFy7z4v
# DATA 1CDZ3NeqTIJiKYDOM5ajFGlMuUv8wqMI+CJs1vXUIVwRKt1CbhXa4MUzrLk6w6wGLXn2XepTKXb3Up7KTmUCk+dbrVTr6u2mlW8z
# DATA mFK8TMaGUzyZzzDkQLR0VJxY8YjBsB6qeTS7UhQ8Mwk7wo7G0TOQd60L5N0bqAKpyErk64OF7CtVu3qtWsq+Ck+l2UQ9lKLIaJ4q
# DATA Sqkg9klrxH70MA2OsZVXLw2w3my+NPAkeWb34RfMsndX51c+GiiEX/Ig0Na1zqR7zKkQbgTQfUIvPCKbw5jpZOE+oIY3UminkFWH
# DATA x0nIJD9viHVg7wMRCmamFa6Y5ROzKpPRQE+5zpq8aNHbyDZ7MLtwTautzrh8YJSMM46BooGm8/A+riqvy8TzO1TDQp1XgVdv8Z4h
# DATA qqjYFsguBJouKUeM2G6Mkee6lniH81jxvZgbq7w3bDbylvNnFeH1ojgkcozXIJ5BYtbmeP2/p4/PfnH69ekXYGw99k7/ePr708en
# DATA /3r6BaO3vlgEdv0P+ul3p9+AsXX233CLJ0iu0z+ffkU/fXn287NfVxAOhUlhfU2//bt39iv8tEd3PKbff8Fvenz6Nb35i7PPGA8G
# DATA ZJcigP2Cvv47BUg/OWbX8+BSyaF+6DLHNg9I+pAshg+UmqTGBabz/ozV76VDoQyLZgJfPML0Lx6LC1LaLVyoA5w+BwcACiX8FDiM
# DATA vBGVt3v2lUZ+EozWYrzewsp4GJyYmDqOl+1rUR3EdYO8lpTK1ZG8VC3Ml4zuq2o5iime6Un5fqmN+ua3C5V0mzAvuAxVTEQLX3bm
# DATA RzpeDui1WdFtnel1P8pBBzkLIgUkVXdZhsrBJedl6G2wF0hkhBmqYE4Rw/Nzgq/73vfiUM+OqXeT6bU4p1RKF8he51fG1fbMYit7
# DATA Wmiv81Ph0F7OHNi+OaBpX5ezAl6K1ZbrsgCuwgDYaPy/4PB/PaO/VMyFXLCgX89Yo7oKDthC8gE1xdpQxpz39SmrcA2E6hUnoZzO
# DATA t2dqawRvgWCRkDhIzZt0UJxyWXBCcSrXwUZksA/Z1wt/EDbgZHC9RWkwqihLjga0OJyj+KKQixHGWko1hNeQwxzzxBHWpoDZMQLz
# DATA gAIVlwecU9TG4ZqJJ3uUxQxi98i6mMWTSDuqePkMoWMZGmZLRWwWerHYIQYE5ShhjhLmKGFXRwnbcMjZaA60qel8vdOAy8wCtjEJ
# DATA cKQwRwpzpDBHCnOkMEcKc6QwRwpzpDBHCnOkMEcKc6QwRwpzpDBHCnOkMEcKc6QwRwpzpDBHCnOkMEcKc6QwRwpzpDBHCntmSGGN
# DATA Xj3kny9FCmsPmoPec0QKW1h63ggVZueL3/TqfmfYbHVLtKkW9Y6daBltqt6RHOIykjJosCKlkLJ8v6DUUy67mm8XXquQ/+adhdCb
# DATA Xf8KQ++28sAb3ULgkqo8cL/esiFghcC7g06vNygH3mp2tx56AfTWEBabQMr8Vg56a3YKAUTNIOjUF5oFPe75fueo0RzVOp7fPodA
# DATA trpOtC8BIOPGpgFk0m4LALJm0G1tACArXAGArBn2B9UcQNbqN6NO1QDI+oN+LYwsAFmz0e92rxxAphvoWvjUvt/UFLLC/WZ01AsE
# DATA zU1oY8UgNG8s78d1Ti04Mq1He1iUWfLMpssC+y1lgdRsx0Ntf8masM8GUeHNBY+CWAZ4jucvxpvkN8lOgEm1xCNZMx5JyZTyMsuS
# DATA hb7mwgtqB3quRb23n9slpeh32J5bxkXrdrtFGhpWmVdTygrlVimVxRprp3hjyfdg3IcOQ+YwZA5D5jBkDkPmMGQOQ+YwZA5D5jBk
# DATA DkPmMGQvGYYMdYFCCUdRJeJlovB2tcJOd/40JbM7ym7/+CcVOFSPottswVbQ0b6Pn26jSh6YCs2ny2AdpTu7j+LBjjy0+0gHTS0U
# DATA Jkgw6Uf7E7JQd/fUqw7s4A9Y1Vkf3NiR6O0eoCv4+JUP82NsoeDEPrXmONhHqN8vpYhjH2vei/TTU5RUVvKgiXG6o3or6BNL+ikB
# DATA k/DG7anavZ99B4bdAaUPgb9Kv+0+4qdvTw/4TAbFiX78C75G8ViamkKCTdYfmAw/kFqHCT03+ryGUZ7fU/rOlPcKCadP/hjlZ+9D
# DATA HJIqnr9MKfpM8KD8iBPJPrHlDz5d/TomvfWjeLSzQ0ndQ5p3b7JpC8ibyhKKCSXZ1AtqSJz6fXbj7j7KK4x1WeJu30cZZ3Px8hqk
# DATA YolclRxSY8HuozzDUHQozpiyMX5VkfNY0g3pjG/c0DfvT+dkmjxSMb8ld+KUHd1X4YjQxPojnLr7z8/+L3WmEdi8+Ia/S10MRWIh
# DATA +D1/d03YOB5ph/0Bjkvy8sdi6J/mdeFTVUd4Mqnb5GJVVg8cFGr/gdSz25jB6qpn3VCpNavFFpXOJyIlLIQ+rg7cyujCa+sM3LzN
# DATA q6dSnCE97ykuX7u7sGp+ngOlfmZdk/gAKqt5e1CJQlR0kswccEm0+AxKPKL5kOlTdQ00j8lYsVuINAV7HE9ourgsUKyk0UNRKZMc
# DATA M8bpTFxSZ8LpS7z4+hIXJck8C7oTvLJS8Nevx8m8i0PwIHJAfFUfnA4O8apZMk5SmpmtZco8i6IVz88R7qsgzSxqbGwbNbNMxOSS
# DATA rBmvsEQkVZpX2O74VS0NLJhNIydGL1O3QMBT6kku8mELvT8gq6wirifRskfkjeUtq3nJFLNIwPWE9TCcpzOW+orVe6c08k9EPyFR
# DATA Uh9GxH6N0Md5yqMv0BH9QsNxJpQzoTY0oUr9qxPtcqJd1vC70vh6FsS8Xp/HYGoVZauMlNd3RRfKbkoYeaZRgoZ2PEwKI5QgBPQA
# DATA tu/dhYgNio41dQKZCyv4WPSAmmMwigdQvIHoNpwPIiE1iaJQY8Yuyk8xEVXAByWnDWn1yhIlLQdP2QSeMk6k6FjvXn1eB0RJ2Y0m
# DATA EvjyefXd2O0j3Ow3+NPqO7W5o/hC/Pl5QKfYuXdBlfwODMfVOvl5WRRYFuzV0+L4PCvKRzaMX2kyPxzmjeGnDHtnCQ+NS5pPyHhk
# DATA Lap8wzTa81ESs7ZVn81DT5+gh9U4Z7G5Kcv3wtikOBxGs21QBp4g/5oXy783o+yBx852Cy0AbVwFdzLpZck4cYVnzDO0TYfjYPSA
# DATA 8krLB3J4uG0+AqabUY1eNOEyYPE2nILwwnmqxXVpkNoO0yJvhheFM9TW51veqiXfXqcxXvb9MVNnHpvap2wrqnNRtFLIEKtHE7As
# DATA JC9Zmk4WEzJF74qy2b73fQZiRP3hJP5kHhkFRaqkNKEDK2E2xLRjGHBNRL7OVMXdQm7m3dRF8/KcOqh7PcnJj6jusAqilmo2GFKT
# DATA SZRGrkJsoSrUqEHCk4XbfwApyJIpq3IvYNlFhfwbRWqSydmuNOSMqPegOAw/rRbculgLfj0YsR2hpgqRzaKBccAZks2nmIBRAoO0
# DATA d6LmBn3RWZSdzvser9Qgd1mOPFVsN8q1QRRBRBFTLbIoomwa9WMmwor6ZXrCeoZmEj6JjreRg/bYd9EKWF2fhflQqmArqFypuagp
# DATA uDTtGnPXhs5ekXrMNKwfgMpDGXVMBjZMdeyg8IZkEaJ+IctYBZSFD6lSQwfyCFvF1B6bZxaq8gK5NvIgnF/D+TU29GsUa5pzazi3
# DATA xiXXhFa6QK5Mo1xV2QL9FaY4VXPj3XjqrIx13g1mMq7k2PNGb17mwO5vdXJRXzOTXt7VYI+c5oqe9XIu5ecjsTOEviWDgZgGQSh2
# DATA QcEhwbta6Ge2kUyvs6O2p+wqv4hu4RPe0I9XSKTU06Zn1N/NPL8uxzcxDKRk3JPxwmfucHEcPJQ7qnJOLpry0bzVvhPeJMMpscp0
# DATA 46iqp01U9XcT1dq5UfU7G0dVtv0gsvzpvLjp2/PYmSsmfo1l0fOt6NXWxE6tChp/lpwL4OkfeHs3eZ/imExsuZHNj3R851WRVsiz
# DATA EMdC7DqYXyrUuSkN7jM5jntTgsgrsvHNWO3DXFrhwBGTiCaDoWVqFxT+/5ps076eoNLEfIBR0oB0ZMpwHNDwDtjOlB4lAw0zMEUF
# DATA ymexGkip6IRqsiWUVLP310JaYkhORnsMs+QdW/SWEDzMRGii8KJUvDD+2c9iDCnsXpnMMwjyZydk+ybjLPei2jEbRqPpOQvHpVLN
# DATA F49tv2q+DCz5L3u26PH38SEv8UsFJlu5pFFGM6v6iA3LJfZyWOUW63Cekk1MJp1NO/x/GF74BWiDRQbh2T/iv4u0w38+/Zx5hF+d
# DATA fnP6B+/sb89+efr16Zdnf09PfkOfFLeQGYcgFkrgHLLHQMTPgVE8+4xu+P3ZP9BDX+K2b07/SOHoJ/9w+g1wiY8Zg0hBOubh8zDD
# DATA MNUrn1hwhQfxBDlKz1SUv5I7HI3EYOEkQ3eWCJNF9D6VotAIYFgZggf1pNromcZRn2bj6+CGH+htDDQAMFrNoQ2tyYQusOuGGy6U
# DATA ytWhDVUd0beBs6GJO/zLwv3YvmJ1uPeTgdrTsnW0IUegADaMM67sDmu4WbFtHWv41sPpCL1MoJ0h4yScjwKQ15MZa/bsex+h7+e+
# DATA K9/nxYtf2BhPz5r9TxSH+Zh7yky2QcGFkswCvZYVTAQdswA0PL8KrrZayi3raeEMz0+Dwxm6kf4JRnrNLbzMAP9yeAqvbXDf/ti+
# DATA 0dB+wZH9egZ2qZalPLCYhU+r5VwFnLCUSqwAgASkOH9x30qsPudYTlAgLk0FlQNtTW+izlA8vPlathVriW5YSRP2ipbzbUMiofGy
# DATA 5rHLZkmfVxx5PNaoOObHcS0Jaa49yUz0o3maeMGY8W885EdkNsT9GEvjBZugYAH8/+y9W5MbR5bn2c/6FFFVVpaZRQDEHUhSSW2K
# DATA oi5dJMUhqdL0SBxaAAhkhgggIASQyWyV1qRS13T1Vllre7bN1mxsd9vGZs32ZR/YquKIuvbDfgHkV5hPsud/jruHR+CSyGRmkhRd
# DATA VSSBQISH3/34cff/L3iIg8UIvBPAG6V2VKu1QrIeqDhvBH6MCLFt1x7DFSNGInt1hFIna+uqqFuTA6lfjlboaIWOVnhWtMIVh5qV
# DATA pjarWsbnaeOfxMQ/DQvfsQodq9CxCh2r0LEKHavQsQodq9CxCh2r0LEKHavQsQodq9CxCh2r0LEKHavQsQodq9CxCh2r0LEKHavQ
# DATA sQodq9CxCh2r8LlhFdZK1WqtfUJWYdDploLGC8QqzCw8H5tUWCt5lVJxL7+5+XGpka80vEaN/t6t1MofVze9slcve5XG3uZmKpfa
# DATA pVal3c1i7Cis+lyMXXWGbCgn/QTgt5kG+NUqpQzBr9pMylqOrSUEv6AZ+O1ZcKLFB2zWUsGXK5vp4DcrC0M3yUyFXi3WloReO1Ho
# DATA dok0S1612tirbvapa81XN/eqmyvndGkWRtgoebVSY7deq2VCadfarVZ7Lory+NhBaTcaOyhN0MIO1ju1ZqNzJHbQ77a69RR2sEN/
# DATA d8oWdrBTrzVqBjvYarerraqFHSzXqs3KmWMHzTY1CP/vrDRfX8LtE/vWm7GLtDmeeZsZKNXU662AupvQz0n85gIMa2olrjxD68PC
# DATA 4swLMm5322jUBZKed5O555VgB3h1+WOHydbpyjlU06YTMkWM3HRQV/ysoWJhA9ORtTcX6BFdLXsV53l7ZTElnbQyfJ/8l/pjz7iX
# DATA Ewcz2ZrL5skSs2VpktmecMBBBxx0wEEHHHTAQQccdMBBBxx0wEEHHHTAQQccfMmAgzbfTZItXgwhpfFRcUR/41fN4oVyMUczS/XT
# DATA PhfhhkzZNObrmhyS4YNuaGQX+Fdw6dp9BBx4/9//7m0W8a0TBMPCh/TfALQ1CvfKVvG1D9feZy11PkfHCzUIhH6UIAo85aEIS1jm
# DATA 8A3i4rUOcC/T8fxWjBA3zFP4xO96xz7KJqnzgngMP3Jwyfsfv/t/EZmZtK9XysULcpXFPdE1IEiNMnMIMXe2+6iz3e5M90/9TPdx
# DATA SWHPw1nvjIttOSbsOpqGeaLg3UC1t7Vd5sLBnunp8BfnaORZUMCyh9lPmwE2KwlwUgJY2l+rz+pfZ2qXVAR5TTcwujZvwPXoe52I
# DATA foj3+Yz2LTghUbVYCmjXD0cF7044ZveTFnyXCijC5ZOhHE9WhZs6vu8nUkZDiDZGXT6LnIjmZBRuZsr5QQBT2TdyO7CJzl/p5hmd
# DATA grVakDOGnDGUNYZmelQneuNEb44yo54PMZxbUl+ZaNGJDP7io6hlFHFuG+0GaobhzkCRv5SGmsJHjmhYaEPcooubRUki9oFfhXtU
# DATA 43F4Qz7Ld4gODdyQPVu7ZY5mysrgr7tQnYF/LFGysXkw7LsQ1Q6H+1oN90VJgT6JSvqYW81i2Be7HUUWmj8uvpe353LPcpc/vQjw
# DATA LisvjsldubOEn6RzVYgrV9EqqHTFthLgyt39SMSaogkEY3zIsQhkpY+WoiUSUcN99kKJLJOYhzSu7cGL/LeQZxn10+pFolJEtl+U
# DATA jHc+BGGodviiUd9lQ1mfOZVGo2YH84WdZwWgzcKb2CRJAk2OaSkHjA1YUOaMoQcsQein41+duORur1xyt+WAuVjpuuiuwxZBR+gz
# DATA G4CKY0epf8dM+gqGrI6jWEJpdBiKjyV9RO2bikAmqduazwiPodoXxb1pLxgrsMBIxSUeRuOnL7JUys6vzJLe5Jhl9u4yWpnql6TM
# DATA 3oUAEfKxFVGEbEAUSxPpdRQtaLYjjCzKXerEcTHqkjVieFrdYF80p/TgNhZJeNwpiztc0vtMf2Pmiml0XPqtSXzw9KWVTtMLUFw3
# DATA Vy6umz7A7byYQX19wqOKd0VL3zQG6vV24A9/EByItd/yoaDl7UZ9aViYHAw4NNaoG3hUUCPQwoDKAa+KHfDd8KHg4xiakBRmVvjt
# DATA 6QstnbJzK7RkFD5mmd1dXGZ6PFe9oigH4lpSXuKPwD58DAPUhGJhBfbEEcPyyG01TrA3ztvm8u0yvos6IYiQYdwTyxPHprzhhA/P
# DATA sXjCAGiXU+j3krg//yVSXrVEbgZKuQ7Dx1j9pAiXcj4o0AOMNCexNkSoL/L4eBdawIEIEgoYULUa7t94Zo0AYHbzUBbG2khB6Yr+
# DATA 3Sm0mdmEnKiYzpcw91QYk5fBz2YF4RxtztGWdbTZVcr52JyP7YSLjQt9cmckOC1TcpnpYQRE5YaNaVxszxBqcEbkuZQnS+89gb3P
# DATA m6yx/NTkfTM8E1a/HwE6S0Ix3ZV1KaHGHYU6q6/IYdvX3jID7uJ5gdq1t97uHwm4kwASwJ36bgHu5mLjSnJZg+OKK0PuZDcP3IX4
# DATA IIwxoSBDpZjzKuNAVA8k3kMdwozPrlFk7Be2tXv7WMjk/UWN4mIvX6nEj9wNHqIn6lhP0S9LHqvyY2/T3Qf2M9XiEjfhQkSdNk2x
# DATA m5YstfGLC6mzXXf7uxSK9xFZnoPgoGBLPitdZ+kE4BDaj7wStzR/pGBxesPakKZJynTHqjN1FhQnTK944KagjTteHBrct4jHXrn7
# DATA tbo2v1htO/MYcEkFVikXud5ZLZz6qImGX6o9ue10TYXetJJhp1C0CnuOLPyH0vUNKI49mSqyavZwMgLoXRa2o5j1Uy2B7BUgcj8R
# DATA 4zlByFEvErRHfndsIeRu6Gv5w99Pfzz8/PB3gMhN/zyLjvuXufg3+vKYnvri8LPDz3HZo38e08Wv+O9HAMfRlW+njw7/3iDhnkwf
# DATA K4V0KHwNoZ1KQ7bDxD33pj5b5r5n6oz31/6e713rhHIWS0Tv1b4Snv12R2Ew6FAHwt/2o1GvY6x/eL4nQ/GdwpUgrrPeAdN1I7i0
# DATA hSLKToNkgUL1PHgqeEgNrbMUIfc6BDRYa8Ljv4Un4ThyyYzAdArnzZGbXzRnB5PbpegwuSCBU3N91dePgsld9UUS/CyAcrz5imxH
# DATA +pfGBHFdYTRHg3FAudWK7tSBcpJnPps5A3RuMq8y0ylt2KjJVF86KLJcdEXhBT4a3tDvsrW9M/GpUYwD6tveCOMHOVg/9PTVW+95
# DATA 8TBQpAwcf6e0KVWYCdtAcC2OV6DNza+ji02cuW3wecHOzU+MQ8856+GMrAeNpTux0fBSuBDPz2A4I3thJXPhmNbC+RkLUknnZYYx
# DATA FJ7PhnYWFDsrGwCawyJxJxiCQ0WmjBmoTQ7xbH5BtrSjfn+C7hoLeO9gBtFmhwVLisSUL+3AHvFHATsoxPuHDIvVZnsa6anI+Ho3
# DATA HPEp2jhemXAHkFasfLMaJkYZskcW4Uj8HOrXLs2VQz7gwDuCbkQf0YjmcfLalIFRd1zwbut4ywEFBQvLOoFn7BY5K6ARZEbTgklm
# DATA yA/o4kA6eJcyOWyL95jTPhB3De/lDAbM0cEJebQugMhUlaBcdcw7x7xzzLszZN6tOHqd6GDXMrP83Gcap+FRPek8wwHwHADPAfAc
# DATA AM8B8BwAzwHwHADPAfAcAM8B8BwAzwHwHADPAfAcAM8B8BwAzwHwHADPAfAcAM8B8BwAzwHwHADPAfAcAO+5AeCVS5VOpXxyAF7l
# DATA hQLgzVuBXomCZ/HiygmOTk6jJfneyCiU1pqp7KrWNhu1IENWK5epAKpLyGrWqzdP/OpmuVWuV07+6nL9xK+uNButaufkr65UTvzq
# DATA enmzUm2c/NXV4jMr62rjmZV1rfrMyrpeemZlnWrXm83zzPBUuz7eq582w1Pt+nivftoMT7Xr4736qRtX8ZmVdapdn29Zp9r1+ZZ1
# DATA ql2fb1nb7bpcq59nhtvt+pivftoMt9v1MV/9tBlut+tjvvqpG1fxmZW13a7Puaztdn3OZW2363Mua7tdV0rVczUVNk/86qfNcLtd
# DATA H/PVT5vhdrs+5qufunEVn1lZ2+36nMvabtfnXNZ2uz6XsrZdD+WiV2mUd2v14l6j9jZ9TTsdGq16rdqe+1i12uDHKvXZx6pwdDSO
# DATA Y46pCYgFly/VU0GWmpVKeTYmtWLNK9dqu+Viv1LzirvlYiY3WrWg1mrMRbI3T0RTryQ0dfHnWDT1ZtEPavU0Tb20WSmVaymaeoav
# DATA Dpp6K9hsdxOaeq1cr1dbhqbub7a6fjGhqVdLtXa5eOY0dXYG51u8Sd94OmWxXWPRE29rUxzW9jNZILpZipu37KY3ajR4gya2ZzIT
# DATA fXa3Yx1+VnkNHwRbbVtG3dqWsRDoboW6nLUuxaWcljWz7KJrBB9L2PU70f6lTfoRf4qeKsVPC/SqPlxgC5ZgyzPBLc/DJEBPbTXV
# DATA +9dk2cr8Opyz+0Ct9eoaZpYB1F7QxNOdy5woSC9vFxfD1u2SWuIOn1fX2MnNfnUHVXdQdQdVd1B1B1V3UHUHVXdQdQdVd1B1B1V3
# DATA UPWXDKqeWIxKu2F9w9h3lGrvtmh/JMIfl4VYxV0228q9A8aVi6hIvh91gi1BV9BF2WaLRp1cE5GJPGyQrXKtVq/xVczyRDYt3tJs
# DATA dJ4aK8S5+g2NUgPSETG4IMYQZttqSuBhX8FGkl/q8oJo3EHIXJj4gmrObaMQ01AdrBdz9eoGjCMcVFm/+MGH6r9LW7/4Gf4dcTD3
# DATA Lu7kqFwtTjuXrTcLp4eqwNYne/4g7PX8S+XcsDehaX98qZKDZNyl2qcfcFR4Gmvick/j6e9MdnaCWMZFFiDzbm/fuGSw8e0g7K3j
# DATA DRey2fOrQqnJNPm3wtcFWv86y/8kOryZUCQAEcChST6C0Pz4YShQ+VKhrINE56xYIhgVRPACmnoidMgvVHUGmnhjyPONyVzWNUiU
# DATA hCDZooD0nAmJhixdfW2ZOcUZHHYXWLKfmIkGJNIy8rT0dFLJNy5jZIHjKqORA7EPlQAoudiSNxxjGQh+nksLdDidOqdTdxyduoyY
# DATA i1Osc4p1czR/FrMsnhclO284QjtlDa10nIyU3XZa0m1nAmlcCDMt0m5TYIsBeLNhO1RBY37HaqxarIpptFlJujRaa0aOzty3W75y
# DATA C0MTdS064uIN13JTv5FxWymmJeQr2MARE+qBAQTqBss4eVbRH7NAvQQXQ8vXkzFfT3UvQywWWlNKbQ6ILc96knGeULaiOAfQxqek
# DATA hDCuNYeQj/xFXY5O8BAQNZH1Qk9lHqaRapFSH6f7DWUXsdxeonSrhkad/jvGkPK0IQXFOuB9RKmY5sNCPVE5FLKORcH7DUbOmUfa
# DATA uxPoFmv9MWWuFDyeNKQGWsEDCwBVPLW5FFU4sSjIuIRCn/Tc6GMZsxIiwgwqpleZswTxshzZVl285Ijq1bmxmNwYR0PFNuC6Eo1Y
# DATA TQ7qZ/FkiBEaW46h50x1rR10rP5/7D8QuAKsQrZnMPkaHqhC1YOLv+8fJBaVDEASe/iqvbsBOzJ13Bjs6lumGIOI7SGH61Y4XpZs
# DATA fj/e9lFEmdbCYOhznaN5g074dXhQPMu216qATINK6wUKDZVFuyhKWNgacsmxlJzfoS48NGQbJSinEyAydBr+pCcYiaCcZt0woNNP
# DATA Wpkx1Zhqp005lQ3U5/SiA/b6ZiFrogz20xc4S0YdZ6A6A/U4BqozR18ec3ShmfmcCyvbC/yzCLNeyk6VFkN/j3d5QIKtoizU5BHW
# DATA 61EorOdVfvnFUhM9CuhgbeUQ3BxvkbnyKnXQ2Zaqj6OlNnk1i5lNXuqomd/jb/Pay+wxMWn97QhuKXnjwaCto6PUl668O3PKjD34
# DATA ZPMsEPK2nuUvnK4MBExvpNFa2a8rm3FXK09z/mhjjA22+eLNyirT8sDM65gMLVvSMDhpsIc9qqcLBvOVNjDT5qjl4MvgK7J14fVJ
# DATA iJo/q7ctlWKG2HUk4WOgXpyjiIwCMl38FlndCvCRae84/SpNQROAdytX7vQF+E25aWjI3NxYy9dXROS99KyFZcBBfR8G0bBHLfR9
# DATA XvdAXiTzD1YzU8RFkUlO6YSnDcexj4qrQW/GWswipTnKqvR0dNXkzxj7mD3o8lTMNJlhYCeEzDgZS4JZiuqqVGkviditERmR7fHy
# DATA iF3l9QYvhsV/oKOnLspMmi1wz0dV4jxCTu6PWDU72h/QlI1+CvuQQ9eVdW5srspkbzY2L6FIseMmOyv+pFZ8tso5P7PzMz+1Ab9w
# DATA unB2fmbDE8/yOAxW7bnEfJ0Hf1mv/NIP1x4OZd8Or4KTKRNEk1j7Wo/gGSfBmH7PumQAvs2jAMyllYHGxuh/n7tBRCwNMNY3JIxl
# DATA M03IcoXVKjt+U477xQxitQ4v0zz+uPhelDqbbey3X8Ionk0Zr6Wb1OEbIyaUYb7+Vvj6kYhpK5h0HuiLJp7Vo4qldgzONK/6K+gf
# DATA RVUuYE8ItVfKhOWRNo9b2Gl9JeFNHxXdyqqx5Y0cSQfWp46B+o5MHLE7x0aNjztpzrh8N7Hb9mKymPQyjR3VFZjU1zQqmTuIUcBr
# DATA Ftoz/eICqs1agXTAPX8yoPkQFgTicZpRbdLfAZyGzS5eI7AoQ+jZRyAzAyEtvUzB28blvZDsHXuRjC2h4GFbrWZ4sh6hjjp0FTUT
# DATA Gzx8AdgcxNiwxrMOnrGJEcVrFcpQGvmhojeBJe0PpafOlGfiQFG9Y7KJJJWxlnvEIHlmuchJsUseZXBMczhMvMKWBTEx06oTBYKP
# DATA UjM/D5yofVQyygxGhrbHCu9jRqGjOdk/tVmTBcyexGEbXp4wspDZ0//j8Ivp14d/BNV6+t3hn6Y/TB8dfumBnU0//GX65PDLWXr2
# DATA P09/nH5P9/1h+sPhl3T39Gt6+N/o3s8P/5Tz6NOP9OSfpz8e/g4UbQQtJO3P6e8n0yfM0f6MHvlXugUk7W88ugu87j9RsE8o2Ed4
# DATA evoVResbfpKC+Ir+/gFY7sPPHF37+Z8QUicW9YM8yHKCyNLcKe6r2tRMAcLr8TIwr5bfUiOEr23anCDB2DlFZtywFyhemKJdUe83
# DATA 0lB7ZoMlRutSivZtPER9UODQ2an5XtI9nDc82yqRsyNmq1oVWzM9vsAVM87e3Qr8pLt+nb5wZWwFNNafJiqbwmV2dahHMrW1YmZS
# DATA 95KyslcotFMnZV/djaBT7wNiTmPqQNuvlMHsdlJESe5NqNxm9oCLz5csFuqk9oLeZcR1l7dJkX0X214qP5beUG9OOU79W2zBJK3p
# DATA WbGvj4y8w167Yf0ph3WNtz7eaP5yeG7PcSQ/zYF8pXH8WMP4uYziUhNN0pPdvs+0qZwFoNqkUbaHLkoed97K48PlnJOdlJSGHZbK
# DATA 8Me7koYuNkLuypKtrD7T9NwXMu1o92C8208KzNoL6evcUMhiDMWrEKlvRp6JroB3NXOZYzOIPGk18+G8BW+bf2SB7ljIxKzoLEtY
# DATA qldFQPE4GpK1tasouGO/hQyTA3ZiPSSpMoBsyq92GIs+hc7SNpwRji/t+NKOL32GfOmVhpSV5isrGr7nY7ufxHQ/BcvdgaQdSNqB
# DATA pB1I2oGkHUjagaQdSNqBpB1I2oGkHUjagaQdSNqBpB1I2oGkHUjagaQdSNqBpB1I2oGkHUjagaQdSNqBpB1I+rkBSVfLFb9WOyFI
# DATA ulvpFru1FwgkbVacV6JH2/kBF2uttlsvlvcqleLb9P1vs/kY1Dbn4K2aXqlZ3a1V63tN4K2a6cfapU6jU8o+1i9Va16ZHq0U86WG
# DATA V67QB6/SzFerXoX+T7818k2vWvEAzyrlK02+VsbtNa+y6VVKuBuXi96mV23myyX7rbwTMs22qnRqfr04j201p27UEJ/GXqmcBbS1
# DATA 6q1Sqz0vlOoMjM+mpFXSyGAJ1wJ41ZPqW0mTzAO/1mjNxLBcrj99DMulShLDWuWUY7i5eQoxbNaTGDbqpxvDSqP89DGscJM4o1Ku
# DATA UiN56hhWK+WzK+Vaqfn0MawVa2dXyrXN0inEsNE85VI+DkhPBiEN0pPxzALpbVZrpcpmGqSXxebxFT8L0ut2NoNaAtKr+7Wg0TQg
# DATA vXaj1aE5ugHpbZJ1XGmeOUiPt3/ml1n3hUqGT/ep9dAsiy7lEio107MenQlsY8FlS3mPTY/r+XIn2NlIhZwh9L0V0Lge+jmJe9b5
# DATA XWHXtyx5M5wvu36vQubJ2qpragVtvrM/t2IlHcF4euNRynI3jgUcMdC+cGwMyx9zCag6zwHNfjgrPOUFm8XzqdqULg0UhuWVaGB5
# DATA Zf52qJlXFBBrslmtWT6ZqLox2CVMVnGtvbkYupeUcM4ukyWziNnappJrVSPl7F5eODwVQK1fOI1KCup481EHAXQQQAcBdBBABwF0
# DATA EEAHAXQQQAcBdBBABwF0EMCXDAKIuqAmiltsneZ8HPrMQcJ3lGMZtuJlyQ8+HbYltSXs/Mct/JhHbbnMgYh4xJYa3tRXitsHxVw5
# DATA V83VqY8Mu9keUt22saEfN3df5teZirg+yIXgvw10t7elnrB6vY3Lg6W5BICcHrGS+Kn3yCj5cOvKQ/0G6cnoirJzH6rujP4Dvc6e
# DATA YwxxdGx945NUTl7mQ8DaVuQM3cikarB1hRLExy9hjPK8Hc2Pz8EhCQU5+akwfxQ090oKgrfB5lx6Gvrhmjrvh44iqZVbNOqyhKyc
# DATA Mqb6KAy823LoGEkYUgfLmDuTsDFbvEDu/Uy9fUMs//llc0RKxtHOTi+VklxI7Ry1SJLEgX6A7/dMESigYrTFtVLb/nEbOo9I7kZu
# DATA J/XTWzSJoIod0ZAVUMYM2gdSaPwaelvxtVKzeKlSKV7eKezQvTAWf4MbttmoX8ephZwKULah4/KGvjt4OIwGEGzze7f9/vBulH62
# DATA WJp99kKhWEeEKCEDKqL1HQSmv8jdUNILB7yyiTvZA7Uun6Lh+rwQG1RMUoC3JDNZMBFwx3V8uFBiZmPU9ZpcpJx4/csvm5e5Lm5Z
# DATA ExmUdK5SxAqcACDhRom4rn2q5iSsjK8RjLo6fJLU/cuqanyq2wBPgcfYbsRFuH11az8c0MSqwKfKuV4+HP/2t+riftB6EI7tn6S3
# DATA uLox3qVx2rs2GnHtliPp1jiN9HEWST347W8xH9y+ShHy9/2QZn+cfein+xgn51TmY7aiaGg1IukfpaFc/pRn+3aeSBlJnNPmxezx
# DATA dRE9EgUeSB/KKe5W4AU0TdNtk/odM5Wd09Xx+biwR9O6VKeHIjOPyZC3YcWSAlWlMCdIrPHTIyYo6znO2tek1Usw4lMzh2qdlo3T
# DATA spmnZZM+aO1EbZyozaqiNgsFyM9K7OYa1l14dIXaxCCwZVu08M2zE1A7D5VxMQXo8l188NZRHPHFfjiYjIOjdKz1s6ZzMheM5LJS
# DATA Dc9KQsveEKUJXV4mYa2P+VK0+bguFOMP0GVxfkcsnEGlwwtou7LSxMVJAcj96Ywx60lWTpgf2SzlJWvJG54CFfnOdEZoD06SFebW
# DATA JOn8YCmjbr38XaXV31VKZzMeLB/rXeXV31VOvYsfrBzrXZXV31VJvYsfrB7rXdXV31WdkVq/UjvWu2qrv6uWehc/WD/Wu+qrv6ue
# DATA ehc/2DjWuxqrv6sxo/9+pWnepfVVTBteqK5uT19/AmLqeqgQpItWIrJGG+r7HghaCUdnaConHZiMkJg9AJvMk/Q+pJZGqS5PQijl
# DATA vErOq/Fw1ABFKxiwkKqHHQQctACF+4YEZkWMBqr5/lMP/SvDDCzZL+NtT1SlaJjCvEErgmEQRJhiNR5fD2wFKfMXX0zIQVvd1Gn5
# DATA 1MnNlH6aM6XjglifuSwob+5K9nmdBcLTkt88ZW6nLV46F9a5ECfLGoJ88tC0VOGiQGZ8CVb2ORBHfUHEAleUN/eSnYPauBKvpZ4v
# DATA y4kdyh2aTENFEypJxtDaVgqt/ohFruAYJWMIT5NZRfYV80957UXEWocyjeetXdBhxDyddzXl8IAqqES5kSf0VEhhj96xh52IQgXa
# DATA AZuM5Sfp5czIgS6fFkM/fi7C7GPNyIx27HlKpj8bSylVLZ2x5IylecZSqqtybuaX3s280Mh69prquuZTdfZZVvoAHoAB3cebkRKN
# DATA 9eEITRMywJlGtjOh+TG7mkeB0sCekfem5mIUwC1l8EhN8bkOZRzLKathVkTd3Efjqm7GPCJR6Rp9ZQybUbfr+XtR2OHVz0EUxuwS
# DATA H2lNbekOEvB4kjCt6Fbw7tAQ7XUpNBFRj3mdVI4SY/DtSVxi3r+IQA6MFjj1LJNWTI1+MhbDjWXkwPzuaCIcYlzwbiidba8ftkfR
# DATA cJcdMAofF/htdsvjecoB6Faj+5rviU/cPT7bGgOlBq8z5U4wFjMiTqSfexE2soxB85UNeEOfoYZWt6cBegVvG5lJQYfDoQJvIwh2
# DATA yV32sLCNq4ze9uUuu8w9nJFAXzxA7mj0u6SbU+Xt09t4ZXxJ8m76sGuEW7wTGdV5XGVzi0oCZrEUsMbOU6lLJR9H/Wg0ivaVvrdU
# DATA f14l10XDVd+TTBxgX2c0aUMDhjHo4rtKDvEmaROGu4GmU1Fh4FOU5WXpeZPl+dkzhgWeGUBOjyw6noIEsBbFAlWK8BEGqTEPYbtk
# DATA MtiGJbVJTBrY1IvFNKTbuzihjqZgxkGpDsAhCiYAL3oQMHweNY+ysS+FxORpsix3UJV7INFTZCYDDMxYU4qGcTaRYk8dRQp6Xeo5
# DATA r1whPpKjkguTrEcY0ebBJrWR1up189pxjGFuoVd5mRM5vVBiSmFJ5iV+ZX7lU762JK+lX6RZmcZ3uq/h5RJpNAkLS5gF3IhO9228
# DATA YHKbS9ZU1jE6HasTRks53bfy0gn2fS9umOkXXpz0ntIX/9Od/SSIS3pbJ4pGsc23/Jfpj4e/B5Dy8I/MnfycCZefHX45/e8gSk6f
# DATA TB/PAi7/hQmWwFN+5k2/xT8Ms/x2+uTw9x6jLz87/AP9+UIIlypgehFjLX+gwB9Pv9f0SgZj0m3fgnL5+PAf6LdvHMLy+Z+33ZGZ
# DATA 1iiCkcSmMBaNosnO7pgZOSIzrYbXXjiGuoacIjYTsclA2y5kSmHU8xneKgM+WzCxzNyAQYFZ6PMZ1KX8yju844L6wrDnfUQWIxtR
# DATA jmSZzOF0L3DeGMu5BXN2QEuul7E1f9TVVJBH6ZtRWc2tt1TNxfB2mjRLMlZZSEGtYcpeE2oSQ0eyXKG0Th1kua22VvWoeRzk9/3e
# DATA g4TURGY1eDvA/6hkwdZt+zhuRKPsCPJsCq/jdzBCGGjUIAjIyMcCPNXLA54bKAoSzs8PZ0iWR9S8xWbJvOb0rIiWRyTC8SzdGP80
# DATA Y7yGWZ50aH8pXLPnNqyfzai+0qB+nDH9HIZ0qZdzcsAM6M+w/ZwF4XJOUj2ah9InZs/5aplUkotY5nid00e2h22Ms0gxJ3delHnj
# DATA s3p4FAkoUPqmFtbNOb4+x22QQu2tArdMOboRJZUMo/3J7m5s9fP2aY6NNWBRPoiFCui9FycmlIz8ZLlhl3eXYhbCEBA0YTjgtSVD
# DATA u4S1E8oLlGcYhcYLWdsWGlL5VjsBjZH9kMyG/d2AY+F7bJrwBrtu4GiXjnbpaJdnSLtcZYhZaUqzkk183ub9Saz7pzbuHfLSIS8d
# DATA 8tIhLx3y0iEvHfLSIS8d8tIhLx3y0iEvHfLSIS8d8tIhLx3y0iEvHfLSIS8d8tIhLx3y0iEvHfLSIS8d8tIhL58b5GW5WvVr9ZMi
# DATA L5vBZqv7AiEv56w8Hxd+WS171Xrdo3zzSpVir1SseaVG8Xq10fQazV65WfYqzQzXku5tzeIw+6XNilemjK6V8k36e9PbrOertXyp
# DATA lC9T+LW/vVEtUdjNWq9eyZeKDa/Z8ErlRr5Gt1TzFXr9Zr5cy1camTKpBY1WZ5YPWKFoNz4u1Yr5WtErN0tecVytNL3iXqP5drWS
# DATA DqPebnYa5dkwmlWvVi1+nC8XG/kmRapczZcoLyhGNcQ032wcQdY0kZvh6JWa8rp2OMJsqc3FX+dIeG0u2pLU3JGAClPx7dSa1Wr1
# DATA BLQ8rr+alidNwaLlteq1oFJagZZX7wQpWl7Q6NQ2Wwktr9atw7Y2tLxKq9osJ7S8ZqNaKgVnTsvjap9fbhiwdz/jm6aiwtnLT60A
# DATA tG2QYqdJomdxbipfZ/1/+EMt/PJRawjzjZ1F8DcrlkdT+GzInjx4PMhedRaylwRzDMiedkAuzCM7p1WGKoydqn+2x6jMdhobA2YQ
# DATA W7CNQI/daoGruJh9l+Rrzs6qJebEETlhiHYOPufgcw4+5+BzDj7n4HMOPufgcw4+5+BzDj7n4HMvEXyO04bTCHlt81AaX1s2oDGC
# DATA SHKI5Ybm9qeeoY+hN+htXVnvzfCdVIo3dEf2GgXz8J5Maz7w8GHjQi9dybjmbxQ+isIBBfAh/Qc+1GVjXn64po+dJ3EpjB8iXz9c
# DATA e2PmRLoK4AI+a1LUVbNDQYeqwU+areQUwt3B6iUHq92B6pfkQPVx9cKf7UFr9ksmrrRZHFEvpYW5E0UdnC322E9ojtkySQKBLNHZ
# DATA ftbns1+EM4r89ylrtc87SH7aqu3zz+XP1W9f4Zh84qc1+uGBCNShtLXspKocRmPmbkBRiKN+ACEYPlorVY1PwCv3GxNZRDcwfb48
# DATA OTmegwwy2ZpJY+c5I/RM4QGOul04pvWBZtE9ROBS1fgV2cPnxxERn6kmciDXT6yTZyNW8yxOs5rnnUHlDKo5anRJhXKCNU6w5qR2
# DATA 1EJ77WyEbLhP182ALCnRrmANjN1oHO2M/OGuJSr+zHTTTgFgSePyG0qGxhq9jqlZLMYAAjlFwWI19uvBvO8POXOsMX+e8u2pqBa/
# DATA z/Le0jdSbYRCCnq+MxAufhO2Or9o4AUPKR+9eHDq8sEsWvzOIJ70/LGolx+o5O0joUPqxLse9Xe93lnIFk9YU2msuTMT1gDPtIbT
# DATA fW9NlKch8d3xRIRej3M0/J3uu5j+eCsYxSzFhJUq5tuLLAyzjfJ+SAb8ZEgNMjhlNepG0olmLGgqTh88WGGAiMF9yhLRGdZkMi2T
# DATA INOOSXpIawV5/QNjfkhvY3CUCQDSVlQ3y0GJojwmB3b9UU3oIFGfkgFNThzFC6Sl2gAsal0pS5cKqkAsLuXdgcB3MPAYvDJoU0Fp
# DATA +amuoh5Q3ueMQlakemctaYqFpwOtlcQzotGk1YJIPpcLM4lRTaIe44tlHBCNo9EEQl6ezjSj46Xcm4G8wCx2+0o3dTXU409n+mEZ
# DATA FG4C4iYgMxOQtIXppiBuCpKegiycWDxrLU3F62Cmxa4/ZNiwjxmGLY4dB0p3T0tBZsQiGbWj1SEV+iiQyYyl8zi2BSAxVvb2wU+a
# DATA CC4kK/EoLXZCTZn6LiqFvWCO0uOqapuc2uGVN3lpM4l36yCZHTF3uTUJex2jxaciw47GWbexOjxqAeg1eltW+xlYhU/KwlIWkP4x
# DATA gWebK6wisMusGO7ZZHFWdq/Q0G0lJQ0BV+81WwhglarPr8rGCPVy6w7Ts9pPvRpxD5sYfliDxxhLzUbdx7ZlpBy52dtpgqoOM7zF
# DATA nxbf2e6F/RZHFB8W30cdc4RNWXTnNfmY3HtR0nYlgynXtqasxtumJkaUJYZmqnSxGViavTojnVjO/qhjpqe8+UEmqiof0/mQAXPx
# DATA TmrTHcjOApnYTvj2qvegb5KRjbfJVChHVq7cDpnV1AkYJkSttSJegn4Uj3sHCn6Jn2AlGil2XqsRXlc4GMsQGIgcJnZJxruR0hP1
# DATA BXquxWMZKD4wUrPUcnlarN3bSgrTg2WmrEN1UOt8M7B+jAx8n+bEPfbdh6M2TReTLMQclToGoLjsjk7NcuApoW7hI7VFh3qyq7xK
# DATA wLYx762E2d6PWniEer9A6jQVxYNYFs0UBYzL4jSyy2olx8yvzaX5ZZqcZNi7kPykdrETmKyCN4HvSeeRQXBJRha892nMzHmskheS
# DATA EXag/E8KIkbduVDiZLeKuMM0Z56GDca4BZ3TyCrT8RwzoxpLM0r1YpJNb8OPI+Z8OLBqFb+aKsQ+xTJmR4w/6qnVU+2bgRMB2+B8
# DATA aNXKShdPs/EzvH87B4m/MMASIPbkCzkXwDHu87gdQlKX0RV80zNtk7VjtMnrANGhT6N2l6dE5wVyZWqbfZmam1DrVEZaK2+BHx9g
# DATA cU8T4egRsvlFepjzU2yRGBgva0b+LCtYqbx6DbseURHTGNkLDthNkNSxHv2SWDjKuysOP5rdUhNkT1xirCFDqIdnh5VeRFWLomJt
# DATA QR0YJ3IiVUfJWhEXFGiEo7A9N9/SA7HsrbMHYnNFsuHKzUjvgtPK02yCqd1pcIqoklSUaJ3fhaMYYj8VB0TCEhsGY6B5bZTYfxOQ
# DATA mDf9evrIY6wX6F/fH/6n6aPp99Mnsxix/2f6ePptfvodAGCHvwOA7N+ACzv8nK7/ZfoD/f0V/f3j9M/TH73DLyR0BP0E0LFH0+8O
# DATA /zT99vAL+vdLvAksMnozhfGIQnikwWTfTx85mtgLQIEeyMoP9vG0lUp9QoEeBtGQ+Y0MWOehndqeGIidCMrn7G3EQGO5pJUYLt+F
# DATA PjoRVuc3UA8SioQ8O4+XUsXegrnE7PbBgcOJ2T4U1RGcN00sXSBnixELB9Ya7jVdS/UvsyyxwRiHAE0fi68y0gWj0+SJ+WNBFOz6
# DATA MQ2nsGDJ0o26XYcTW7XUTp0pdtXvtbHqGMgC2EECqPb7vNOel0B6vE7idTGV8JgLx3J/ZpUDJN1+P+DJL8YSXkcM/zZg+obXCYPx
# DATA HIzYkZVusXWSakvPjiF2ZAocR8yN7qcxumue2LEH9ZdiUeS8BvRTHs9XXgw51mh+ToO51Eg7D5LtVs++6ZwFSsxOqziG1Q6O3Yie
# DATA w+JDOqFIgYmlLiwsEi1J+jtgsPeGsVCVOGljP36g9qogAuEAJ8dwjE9lyWooMQCMZKjeA69LwZo6CdlJqo0M621tEwA+FWGjHWwC
# DATA rG2FZCDMsQsm0F0Ix/PsAWUNMPgIdgBWr+IHFJiJRwjnONcmql897NLGHrLJeBRKmUWDdjAaxI4j5jhijiN2xhyxlUaaFU9grGgc
# DATA n5uRfzLf4ymY+I4m5mhijibmaGKOJuZoYo4m5mhijibmaGKOJuZoYo4m5mhijibmaGKOJuZoYo4m5mhijibmaGKOJuZoYo4m5mhi
# DATA jibmaGLPD02sXSvPkq5WpYl1u9Wg+QLRxOxl5+NixEq1ilfZbHycrxTzJcqfRiVfqtV7+SqwWqWPS6VKvuaVqmWvVCx7jXK+4eEu
# DATA 3FFqAgOWzrpOd3Oz0Z0hjAHwVS1uemV6R7XhVTfzm3Sh7DXrCLLm1YDx8koIexOvq2ymg63Vm51mdw6Yq1K0wFzlzZoBc5WK6frQ
# DATA qjaqwZwAalUrgIpF9mrOVonqPDJYuXHc5618qVQaXoXyoVzzmnn6q1Tql6slyiMPmVvkLF6cELsU6c5qrbZbazQzpDPzwAzprH4C
# DATA Thm3DMMp40ZmccqoHjUa/gqcMr9bSXHKuuVOo123OGWb9W4j4ZR1mu1qq5pwysrNeqXeOHNO2TAYH0kpw/ii71sB82U5yirsJis0
# DATA eXkMQ9rGLAnMhKwxZ6mZbrX2S69Gf8o1djqm0FySoxKCivBqTjWVKuNYK5vpbubt5Sr7AtmNl7FtxPO0BOGl05VLxW/JEJ66TbvA
# DATA HLLLIbscssshuxyyyyG7HLLLIbscssshuxyyyyG7XjJkl7I4LA5Xxz+It274491CtxfRxAZm34drOIxFqf8VTJqL6hqfj8JF+UrT
# DATA LBiq1GrY+vxwbXtIE7yHcFEGvQPKjQsI+gLlSncicmF8PKxr6Vyps1a8igRSFpBa+jCXrw5nQYMMQcqxG58PaeOAijmDJXp/jrLl
# DATA jh0f99ixO278Uz1ufBK81nNwDJndd9rftZyyJQJWJt5zjyrP4Ws9L4eXX6gzfGcB3Eoftz5l0lamMpwUsWU5UpND5CqnEywI5BlF
# DATA QF6prnB27VauvMkTfNaV0zp0XH0gFDpQenNyENZUn32fnmhF+zjtHOxMepDv07JzfciJRl2o4XcmI66g/qivpe/VmXh+t47ANtnW
# DATA IRm/vG1WR0FTwih7ulgkbbEW5xh+Io83p4hlgqXWHqcNenbcFnCishXgxR2yySajlhGefEmOelphOLvK2VVLxNrsyuV0XZyuy3EN
# DATA qiW4rbPRe/n1INpH9y+KAy1/RzTWILmhBrbS+cuJnQJdi1cg1A4QfS2lDc8Tfbr63gB6C4GSYTFuMW/9wc5GhgQ04HWgBLSjgjDd
# DATA lP6ewiFRoqlLhp5MP2R522IBfTb1LLIlR4wj7OVMflwgZy9+CAB9bMGWIba40mC/fmR89fNJv6ovJBCuZnFenO0YY7uOHeUlEWZP
# DATA CVOa4K5OdGyQUUfEVT1qoqq/p3BhS+NZWhLLDEFJrS+htSqni6iRc1W3KEmoVFdelb2mKp5qjdHW8k0uSe8S7kkKaPxVzNaLEsTT
# DATA UaAsZpPVvm3hI6VPrxAvPpq90Qe8BteT3YC5QbNWSvAwFBUXHu7Q42gX1McT6oWgVR5PdnYC9kADGMErE6qDiEbAWACqxKrSGIU5
# DATA 0AEAFT1N4xIGGvvGVbuDgAqZ8hP2x1PRQA8GCsH+jmHEQoEKxmksI3kn7LJ0ylj0h1jZ2VNbeQMTH5GjhzQRR2OOOlEiScSyyvA0
# DATA IjKeP6Q6hwFuVbbTT8TYTY1gztx15u5Cc3fGtHEWr7N4F5uwz4nC4VVW34NmcReDTDhgGbP5fCfNl02kAEdBP2RER26R6t6bwhSc
# DATA GW5Y2GxnEnaAM0wGRgqN2mtnAgAhD29ZEzgNTZgRODT30bhumKba98RD/XvMCcB4Nopo6PDHesxlO7xPDXwCE0rZAf7OKND4ytkh
# DATA U+kfUkgdGqpNcuCqmhk4WRoQ4jLsOQpYE87zx6jQFOHLNrVdkyGDh7w9Cu8IATWgXF8wIxCJt2iP9zcpBqfm5w41wwsbOQUU8jAY
# DATA tUPsd0xBUCXDuWBYtM8SKlResoL3Fjhb3I2yN42hXbuwufguBpiAWAl33fVgzP0sJwOmjT/O+NtwcM1E1uPDDWCfLEvjtpajNP29
# DATA TuT7mLVp9o7q+6EymRPNPQ0mwiNYf6SC7sU5pmPEhtqpjS4xk24iMPSUBzDB1EZLHllGPCS1YGkHnbDtSwkqfCaycqamW5iz4CGN
# DATA eb2DZam8yUeKjfnF+BKdzm3e6akOiUxGOXiSWWG8r4ufp4+KlBMCfqLM1wGU+JT4p8VI4ySllSoL3p0geMCUELhlmeeBvORbVbXQ
# DATA ipUpvgz7T4UbArVFOIi1o9iPeVLr7wyiOIxnyBxsiB2l8303oo6J8zPpgrjVHJsUzT5tPQadCifacnOrxgD3Njuxz4AMfQPVV++D
# DATA oebqo+qK/rueppwBJfpqylmONkvlLXTZMyBFXw/HPCsbUbcFIUiBQipmDfecIjB5BrDoWz15JzpITm3SuHia1TkDUPQ2dUC6xaOX
# DATA 6hh9XS5SeItGnVNmJ//U528WF4eeGsc2Fue/AIIz/WH66PB30x8O/zh97B1+BkQNfX1Ml58cfjlLxvkXRt38K0Nt0ndPv2FKjkc/
# DATA fT79avr48B9UKP8ILg5d+/Hw93iCXvUl/fI9vfAb7/DvU6QdC6bj0DgvAFmYwWxGu1YYWfD8AumRk22owgXucre1Dyj3vrKodgJW
# DATA DH4Ah7PghMealciQUR5EwRDc6S0n4FwP/C6/xeFvUnNMbu/nTb+xCuPs0DeStKRb5LrT5XlY9laMHOZGnuqNdg/Gu/3TxN3wJlua
# DATA 9uyixnd4RgDkHm/FxO0Oe3NkiZ067waT3KiFOSbXM+2xxk4RNR3m/qXnj/pqaSqZfIaxuKJn9lCLfjrbtjKXoNKiXgzTOjJd4OCe
# DATA wd8sr3+LjY+kHT0r7M3ymDvijRu0jzFoa7DN8cbql8MXfD7j9GkO0yuN0qsP0mc/Rkv1M4k2A/L5tYWzINWY9AghOc4mRO+/SDYx
# DATA sD2xG/U1DMYqE5np0oCGwc7vcEKZgm6IFLFiLLejyUjYFMn4qhMuR9npJcgrDn41bo2a4qfGYN841/XobcbtmG7sTHqB3hLJS1jw
# DATA KnrxMGiHQZwz8U/YxcrR2gvF9RpQZ+t3g/FByhWo0sE4XcZEMwq4LYlKJ8gBahygxgFqTh9Qc/TAsdKcYxX79Xzs75OY309rfTsY
# DATA jYPROBiNg9E4GI2D0TgYjYPROBiNg9E4GI2D0TgYjYPROBiNg9E4GI2D0TgYjYPROBiNg9E4GI2D0TgYjYPROBiNg9E8PzCaSjWo
# DATA dE4Koyl1ay8UjMYsNx+XRFMpN71KtbjL+Jly1StVK29XauV0drS7zWJtln9SpQRUqo3flMqVLP+kWmtXm/P4J1xK6WAqm5teuVr+
# DATA d6XNslcuF+lPw9ssfVyqNb2mV2qUvVKtRO+qeOXNysflUj1fqlAZgphTzZfqdEuevtFNVbqpRA9U/115kx4texUKodL8uAQvctWr
# DATA 0j2Veipd1aC5WS/OAmIkQnky4fOlUrNfqlK+4EX1IvA8mbS2NzubfnteWhV6hkoxJPNDsWuqxVrCrqluFq0KXJUvB3Nqc6cd1Nvd
# DATA E7BjuCIbdgy3CYsdUy03/FrlSHZMq9vp1lPsGIpPs92y2DGV+iYHJOwY6iQ2/cBix9RqrUr1zNkxPWoFR8Jj4DT6NLnVUF4sjotK
# DATA 3axjj517Zfq3+Uvb3G6w+ZAEeTSSxubN8GY72Vs8LxbGdVWYs35KFpaHpUqvLn9SoXnKojFAGR5FTe+fItdIEWdSTGHCMvJq8se4
# DATA RiXZTRhXtj+nZK3xqCAalGEl+qP+1RYmW688IC6k1axQlumsS8+x52bEwoAc1MZBbRzUxkFtHNTGQW0c1MZBbRzUxkFtHNTGQW1e
# DATA MqiNNgi1tM/axmvLRjOG3+hen09dqMdy6APndq2eSplVqbauhLr32mKTeOMy2vmHa1cTNS8cVrHkXAaUw0rTBdPXNLPGnHxw54bd
# DATA uWHr5Is7PexODx91enih1uSZnCp+HTUXSnNJ4OZk8TPVnzgFvXRozeHN+0HwgE84Sps9odZcMracntpcEPSUKndLVkkoQ7T6oHJ0
# DATA n4HsnD5vrMBtQyrVzgjacx7NkYLewRlozr0zwKHmsfSwsVLKhr3cTQSqz0B87i67vlQayQRRvTnVCRo78lC/7pyB7txtOUoMHyCZ
# DATA cirJBi5wJuXK2nM3cdbaNwJ0aHkywsFkIfMSe6Emo+CU1eeUB8ZIxyeajCllgORwq06IOTVLGYYuYJzqQSyJ+kQUXiTgIaGaOazP
# DATA vVEhUdfsjA50RieoBr+3D25hP2AJedyChSoyNHq9gnc97JrmkAPuoTfbFpWK6gBRGXm79OMowIJV70Ce5O5l348lOpoopNRquQ6K
# DATA yjsaG7y5ol1Nkwosse+pAKh1UDSlvuzCNzhSJ+Khk0mPdmlIWSQZoHNFH/enbnKAk++8zYDGE5YCoJE6K/GTGaluBzgOqE5xy6RV
# DATA 7pBx52jZ+Bf85LFDTjr7PbHfncX+k7PYj4uUfIY6QLyYbxail3Mk3wxZ/lzBUSB6PvB4L+8SiOQ5ywc993IaZ8GHTESOThsOactB
# DATA nZQMaW1S0NOm2zhWZaqDTPxYOEUJT5UzBYldDVKKancjiI2vj+Rh0ACwhU5DG7e93qQfDqIJTRGNTTSgSh5BxGYY9HqQdscYuqsU
# DATA 18n+GhS8d1sit0+GCTZdQ0tpl0xShTlgno1+ux2Nt2Cg8V2cGB2Lm7CLKAiKHVVeqjWW2cUmH58fCXgbwkEMLXU/Zgl1aSFa47kP
# DATA CevRsvezG9pLvfstaUExmZcxL0UXvBtRPNb2n4gLMftHx/oyMkjaF9hLUL6h/hq2AYTtqRuhqs6yIdmY/NRFYqyewdlqzlazRwbn
# DATA bH15na2LmZPPUsLxBi9W6vqsBNj46LUFpYS0HsMR9qDdJu0ncd7k2I3AgEl2omnHYcG7lYgB4hSOqLQZtA+XITsNfEs/kH2a7Dvo
# DATA hm0vpul+23hWWryVLNEMFM3FFTUgOcXi+Egav6z1ISYDfzTSPCE+XIL3wOszx0hUZxxnaZdqnRuVlD8pP5nyZOkfEyCiucI5DuxI
# DATA wOHI08r9FPV6VgrmEiDN4jlXE/n8qmwJUC+37jAdpf3UqxF3mIn7DqvPGDF7Pb00GsIfGilrLns72Q3cqqL9xffssNnDyCz+tPjO
# DATA FttprJE9EitF33lRUpXkg4zH2lsoK9C2nw9DwxJX4VKb0fJ8+qOOccLzgr+441UOWjmQAUnxzmDT+mUpnavQaMI5sW0SkI2x5OWQ
# DATA DbarEHEMRxAyRb1PzFbYa3mlyZkTidE8ZmZag5SGsX7UCdiPP4Y9C8NPW3CCUrKdiXBAGqnOgIWGtJE99v6WBtyC7V9d0ZfqmW1y
# DATA bGmkk2KyRkuYAfCK5W5uRPSM5XTN2rLHKp6k8h2zhO4sLiFdjaWQ7gzZB5suIWrG3JGIxx3YF2hl7pL9I25Q35O6rqx+ix1o1kDw
# DATA vKyCiNRqBPVRTDlQutjBqKyUpy8bOwXPf8HcWrVgbvmjHovK+r2+Lpg7UZdhrAMa1VgzdR+TPBpBd9Jzs4K3vReFmBlT3hu3fs52
# DATA fXOpDKl/weSso2aJmB4+dXnYET+38kj63mOWx18vLg/di0t5/DUZLDMd2aTdnvRYTRaLgOokoWocerKqWHrUS/FKAs5j05BR8N6m
# DATA 1nWQoyIkMyQKe6Jy3OdeLOr3Rf6ZjIu+sMTopxA5aNaLn76gkhQ9/8V0e9Viuj1ptbL92essYq16s2DwUXSQ9GBajKvgvR/SdLcz
# DATA oY5+R5aijHyyXhVKLDwwtSmv2v5E6HhPXRZ2tJ//TuzNVTux18NRh3cMDOAAosYxsBrPrihe7076YSePhUKWGFflwaNOzIY9pIXG
# DATA sMzf9zWXOlnnt3l7KGHT21FIZDypbRPQQoZ76KnLaTZBJyqttP0n2xht+89ckby/cjPSGw61BreY/GJx89I/Qy19mrEgO3Qpq4XT
# DATA s2GivdAer4SFFu9GQQqF9n9N//Xwi+lXh38CqwwYM/r8+fTx9C/TH+jvrxiP9o3HsLMn0+8O/zQLRvsvjFF7NP2Onv2zR39xgNMn
# DATA OQpx+jV9Y/QZ/e/H6WPzEpukRjd9P32MT4qj9hdQ0fB+ee+P0387/KOjor0AUG6zzYG3vEbjfY1dNWRuiBcLeTXHMyPeZhXAxNMs
# DATA AEBD4U5gGRnqAATOgA50CLqBIrpSPR6Nec8YnuvKEpZxCsDTsZScBmV5NAWx8x0+zfb1cRdx3vS0bIGcHUKNRgu/F+0kiC/eYcgv
# DATA z3K4L3bDpJt+Mxxb+I7TY6jBlFbnNlBDIxnBORscPu3o0jp1ftoNwYB7LTIusKOL5v27NO6Y6WVOG1lxhMNQyEgYskgmuju1pxXz
# DATA G0UafwiVlCDpnFjnK0c2lSxHjgL2LDJhVh8T6FMRCV4Dg9V4hq22vF4uNmIyrexZAdaWR98B1tz4f8rjv4awnWDYfymW985nyD/1
# DATA EX+lAf8Y4/3ZD/dSEdNJN6P889V8zoLblk44D5KcIQY6ZlLdOkBIOTnDOJrIqySuYwE6xX0fC19m6c2TfqkVxHBpBSMsTXKiaaBO
# DATA ji2o6HXCrmG7UbIPPEUyWZHZNlLmGm+rwZEVMijYLxG0H2BsUmgyrmPCveJTw7wTSGhzYcx7qOKx0Lh4aTaIx2IqIF8Sy+GyopiB
# DATA njWeUAh9fzDp4vPINhKU5xV+ArZpRgf5aOCQbQ7Z5pBtZ4hsW2F0WWmis4pJfI52/UnM+qe16h24zYHbHLjNgdscuM2B2xy4zYHb
# DATA HLjNgdscuM2B2xy4zYHbHLjNgdscuM2B2xy4zYHbHLjNgdscuM2B2xy4zYHbHLjNgdueG3BbqVZpV4onBbfVuvWg+wKB29Jrzsel
# DATA t5Gt6lWqzY/rtXyl7jUr+VKl3KN/ymWvWfNKRfql4pXK9KmeL1d69U2vVvc2i1658XGlSle9Ss2rlt8ulTY/zjfzlYZXLuVrmSwN
# DATA NrvlTisDPSs1qvVKdR70bHO25MpFr1qs7dYa5b1K/W36mn6BCStNYStTCsr1mtco5UvNfr7a8KpNr1HMlxr0pepV6169SV9Wjlip
# DATA MhOzWgmQuMbH+QoVah55Ub9BASC2vQpdSNHieCdn+mVBt1FfgLlTFbgdjviE3UOp9OUE/VZqMEiOVQ3q6RZggqUAYNh48nQRWevJ
# DATA w81mutp3u/xd978sh8rir5Um1RsK45jYOG5GGhsnLdLCxgW1ZrVWS2Pj6KZquZ7CxmVAcoKN2+xsJti4arteqzUSbFyn3W51E2zc
# DATA ZqeyWQzOHBuH9nc0Nq6ijQIxCfQzC/hxSGbGv1j7pVelPxX6U6/90g4iw4t7p09TiXEOW4ERX+8mK3bQVzvm9jSpVixezjrzxN2T
# DATA a+7t53iVbMGKmIoG4FXDT1ZdKihUrbzwKqN0MJ7eT5EySMx8CbuqtYtPeznTTDuVSWX6U6ppk599ReGYLKx2CmSnfdjUL5dn8HPF
# DATA xXw5k/s5OweWmCJHJJCtBMeRcxw5x5FzHDnHkXMcOceRcxw5x5FzHDnHkXMcuZeMI6csjnQHEA4o/C3Yex+uSZujhF+Q71CE4Wxg
# DATA E/PDtbv+CCq0/IgnN6N5XeALVC3exGa69dLGBcqNdr/wIf032LZOiV97L30Mjx++4Y93CzxDX+dwflUq1BBCcrxvzqHxRPkWUlym
# DATA 29eoueTYijtE7Q5Rr3KI2j7a5M5Su7PUS/SSn+0ZazkanNNnfeectL5tzgVKHcmlldXMoV45sKoEWfgsMezofaXDLCd5A1bZTw5P
# DATA Dv0DTKbl8CS0VgbWycmVNZDfFNXjljCiOiBQ4dW+6dDRETjd41V0j9t+PPGVbBo+Lb4TXSplLW59Xz4uvpc62E4UcUa/Kx9fBAXk
# DATA JC+OKYJ4dbEIos5VEUEko2x00IEOkT/Y8+NEAREnJ6l5QUG8HbHbZDIc4twzNhrgMJo3ElnIGHgOOczOXjBqakHBo1Yd4uhwRkeH
# DATA x8PO6CDnBX58wA3l6XUPM2k4N4lKq/6dnmKoqclKpxq2w2gCMzIpm/Yk3qWaG7BILs6gyxFqX+Sq2cxJjAhYlbBLBMOAgtoF9w5d
# DATA RKJMrfQc+Hj4BPUD/tKWZp48lTp1koAXoGDeX7lgblNVz8OtcgANcEs5lA8256hEhgG3Hm42uoEwSAYFR/0RGo7WDcU5QihWQTE8
# DATA GLJtiAy31DREcABrWzK+hb3daMLSo0+v75pKyrmV0ok7t+urdm43QuycgYbHZGQpI9MEheZ82BU4joa66XTDUR/ipJOhpwomGrEE
# DATA G/8q6iX7lKhR1JLubhTgK+uGTQa7ZFRB3cCW8XiaIknF/NxKxBokj1kkdxcXiRlupUzujvywJ3opPpk1plDo+xjGCey3SHK4Q9Me
# DATA GHmomoaGOfJVc1Ca1YAJa6WZREkiEXsTEZbegai9PXXBpKP//LeVO6u2lfdlTkoT1HBIVdgUDGo3LGeaussWIRjWPIzzdBSqHsOY
# DATA x3tM88GjxcZchcyKRTNciYSPWdQapQvP6VMXRSbGL6/W8U9BTkQ/7rxbzru1infLrmLOu+W8Wyt7sRY6wc7Gu8XCWwaA53s7USSi
# DATA eNq39dzq1y7zfeFIg2d7wGacWkI3xYYRtQ9ZX0t5m9TyDKOZBth/zxNVtVC63u5vKLeXbpgyKUUpSqjmedOVJVeM66fMu2tH6LnR
# DATA i/VDNpDKvK267/OWV72RNxjy1utCabGDjFeQUMsjVa5Do1qW9pOpG03M9IMzrqmSIvTC7ulc8kpeu7/Yj1Uq1NiBQIGFwYjuLtRS
# DATA 98/4spSFZRyFsumGgrim5QszvaxlJqH8KAp8uEinSnZf2aZLckmaeCjm2ZDGw7FsSL8oQTylASRGCgYjq73ZapZ3R+J+FWIs+oEZ
# DATA lege6zUOtJc2JzMGtuHYK+Lv+KHsusKWeMFI0eyh4BnIXVJPCx4XWo4HPwvIwuKVSZDQq4y1dYzXwZoahgPBWCFMsoiNBCEWFFlB
# DATA DYfGIOnYOpDmKcJ8PhQo7VXEeLIDfi3vFEjWMNW0daAlKFmvMpGdnLCFeuCZ7QJ6T9yQbRiNl0VW/+QNz2SocaanMz1XMT2drfnT
# DATA tTUXWofPoVo1n+gwpwtmzbCeZYa+BbOTYwUK+SiQZcJYW6HJQyy7xJ3v86du/fxLvvLfck7nyqvUg2Yblj4WiHDNEa6mnPCzzizK
# DATA Bb/H37Ii3NnjetJM2xEmC/Kug0FbzG+jf3Xl3ZnTfryDjwpxRtzceoq/cFpWEBZPjq1oeywDB9/3D3j6Aj1nY5hd5SU7mRwNzKIg
# DATA /Ik7FNLwQJYXZe4EGuHQ3+O5S8G7zctZY21BqXuUfYZaCZexOOPY4MmudflYDycrTdM6VqoE2cp07eGwh1Dj8CG2rssypFTvc4d7
# DATA nLvxlGDKqELtBb2dCXUXNqzsXw6/OPwdY8lAEHvCn78DuoyxYX8GUQy/HH4xSyn738yPn0+/nT4Biuzf+MKfD7+YfodLOW/69fQR
# DATA o8h+h++4gV93+Af6AxDZV/Q6gMye0M+PGGX2LQXwA347/IyC+RawssPPPArjEV34Ay4CjebYZS+EdYi08dQL/hCWK9e19xKIpP7o
# DATA AVb5/EGQg9uDZqUjnjsOfZn+YJChGSqOSvMaEvQyvMmAA2Nt8knYYzYqtWifd3PSxNIfCyQ1wFZ96syWUssEJh3IQOmgZbataHUY
# DATA 540uy5TK2ZHLOqGcw4zNnW+oK1xRZ+hlGPfMnVTppCaOThlexvP8MOYNCGgOvDNMR9URzFYrtVOnmOnOphvyc35PnEpxezfoTGSb
# DATA SE/Y8ZD8YJAz92Ieq716pVq+Hw5ga/s9qtzYR3JZe3oZnSFW2CiggAWkEA7QBYsZqCwjaZM9g29etWouNnHSTe1Z4cuWRt7Ry5wF
# DATA cGoWgOaWHX/gfykcROc56J/2mL/SkH/MEf/MB3ypj6nE2/Sy56L5nAW3LJViL5A5eiweKaZwe1E3vW+Ps2G8S7Hc4XUTNLoQ+zSN
# DATA ZcSIo74/5ITLa9FHybkBqp2gLmGpRSOTZL8mj7hS7z0jzhaviC3jnFOVwqPsmOB1MuADCCLusn1tGFARxIil18GBH7z8wSDal9MR
# DATA HbW5FNioYcBFvRtNRmB/MYMqbIU9ZBWsOwat0HjEuCkYC6KBwHguc4ZAgZwG0Xz4lOOYOY6Z45idIcdsxZFmpSnPCvbx+Zn4J7Hw
# DATA n9LAdyAzBzJzIDMHMnMgMwcycyAzBzJzIDMHMnMgMwcycyAzBzJzIDMHMnMgMwcycyAzBzJzIDMHMnMgMwcycyAzBzJzIDMHMntu
# DATA QGblZrXWKJ8UZNbt+t3iCwQyS604H5djVqc8KVZ36/XmXmWz+nY9iyArB/V2dzYniyXKyupurdngzxVAxtTnKmUsf242vRLlcKVa
# DATA 7JeaxTz9qz6X9OcM1ItyvtMtz4N6lZszUSjXKArF8selRtErlYBg88ql4rgEt3HzKHxYo+Y32nPfVKvP4NBKjRq4ZF6lnN+seqV6
# DATA FRC0Uo0yrlRh8lt184jXtSv11nxamQVRy2M64EOgX2q0tzkHZEZxSUBmFCkDMhMcW9ICqpVuo7xy/tbnvKpcbCSvqpRKZ/iqihDZ
# DATA 5FXleuMMX1Ur26lqFs/wVXVG0elUVU45A48FleMuTUPlpHe0oHLVcr3S7KShclmE3FyoXFAKGp1aApWrdepBs2Kgcu16O2hbULkK
# DATA vbdZP3OonOwuzMsygx7mKjyD8PTqlLFdmmL+2c9koXBvBdSZh35ulv5WnUd/g/+zsbefq4v/U4Xc91eDvBUay9yaenqWBJpdILHN
# DATA e10+M55NVTKpcFjcYoHr6xetJnVgnbTT63h2mMfuWixVLQbDWVm1xJ6biXN6WnSG1qFjzDnGnGPMOcacY8w5xpxjzDnGnGPMOcac
# DATA Y8w5xtxLxphDXQjHNMMf+dBipwp22WDntq58YuYkw3iL64n0Unx+GVfvWS1fGv7WFdPsw+76z/hR1XA3PlFcOq1cBDFUOfPFiKMh
# DATA d9ViXF7+VF7dmcja85Yd0K8Ed4dLCQKPuXSypGPfmy9t/KpUu1CqITo6tCsSQGtC80UUqokZy82yAu0gCDoxeHf6GUDyRIYgNtpL
# DATA 3WBfOpChnMoTsS+6xCcYU8lBRuMU45Y260d4sWSVLD6t84RuoyCLD+vrfm4vF1Ih+BeUob238av1kJpG8bV68VJpI1fEpi9u9Vh/
# DATA 2upvXVnvX9kqVavF1z5cu0lVko9YcqjIIGX4cD51exHNWfsX68WNX5arGzQD67Ce1Xo59+FaEXfzY/qZ/i/pxtmbLic1R7IcNWA9
# DATA 5lirqgPn0RbHbx2pZ9Tg//jsn5Gx8WVcubA1rzDXw1fThfhaqXapqHOTQ7386Ubhoygc0LMMLpRIq48X5ryyGw7CeFeJopZqujBx
# DATA WlYcLgJAfG8AlQnBAeB5hh6uZypMXteKDbtaUOPhemSyZYMieZkLnEoir2cV9Pxry0xGbnloPEk4n2AcJGNIHTrWyhla3EKHrNmK
# DATA utKZeRcFrs9DF8YP0c9YcZSw7+gw9UM04CIsg2nUB9GcUoRTiliuFGEdU3R6EU4v4th6EQt1Ss9ER+LWZJw0AN61pTU9ZWQ3ohLP
# DATA o4zReejYi7EiMu4jsWIyyvW4lOjW6/tN52UuGKH34uYltWCuhOsX6NGrAZcV6cc4Wc48JCPsva5G3qOU9E0wJkrJlURJv1qcJ6Vf
# DATA saX0G+WiraVfqi2W0rcMGkSfI04TE5pVcbVKy+mnbrbyzQ5iRi2fY3alUtT2x2Jd/SrHs1o7+s46h1mfE+aM9r4+wEjp5oOIV5RR
# DATA LMwgtBy6VX5ROZMwoTBp4DSly007PrKZkCqnG8l4xkOhTECuWJczBXI6r72NcZNbvP3W5OrZvFQOPno00I6om0i9Of1TgvdMymUh
# DATA HUF6MoUJeHGRCNfh3xOpG2WsaEveVs4wGjMdmtBZdn+qk2czCMIfqVuUAC9VYdaegeQM62kw3IDFHDSDYJEGTVp0xqaCzfK/5nPC
# DATA JANT8weMhHqFgn1begiyIWBH8g1efHGLtIXh5iVuXnLEvCRlf7qpiZuaHD3jeKYSdxjjUcF1JJA5vUTl7k0zERHgAWs+mbZGpefH
# DATA LHIFwSnWHDMiVDlRTuv74rg0QmharCE7ucigF7DNxsZ+C4/WNsCEr/m+CM8FQpiFqxTtmxJDFTo2UxpmdFH2xB9PEM0d/m0SH9CY
# DATA O2CmFyVQOoucghDJ9EgPtAyk5+4ifqADHe5G42hn5A95qB4GMKSVvG84YukxSWJ62Bv7jFW+EY1EWVeNdVm4qSCSLctPUivmiIVD
# DATA 444Mfdu+wiBjm6Dq2MR3j9WpfaDIoQ+3Lfw0wUrs+jZeFB5yEAZYag2+vWWxDzts1S2NfNZ4lBQYpIBAhGNDEIaK/9iAntssCKfw
# DATA F1qTOFHWE5ZtWntPFUsLXbbwCaxe25f6uyRN29hhP4hAbs0mS8yENDd2RlXRVGQyC2/Bva/ejHwls20XBF+FbJAs4B8A7EXksZbc
# DATA Ztk2GDU5VKKBJAXMO3hvo0ms8kMFHFI+bO9FYYclqVmlDQAFyVIaoCImxvYhtTbkk268O2X+lJ5j/WuhiSgHuEzKdJyxoJ4Sro66
# DATA MguDDl2/H3WkcaPw+LIpK08fnou6XfjUddlpDWspw5w3nLTIQrGeY/05boR+BxaQN+I6LJWVxi6GF/MrPZDYadAhSzumNrksiXeA
# DATA BldwrzEGESuJIJTJC6lnCKHtRd0dpXVIz3cnvd6B4q2omLIbJ+aKKunup0iFrCwofcL+bqTUEamDxE5QKuLRLtqhFBj6+CyiVgzT
# DATA n5497WhhzpZeWQ3amc4/adP5uKywZ6wObe/5Xw4Lu4uRQMMu2aiS+r6cFvb8qEm/EJKqRxEkkn3/muV1mlCxtEL2aTPFsorjc5Fi
# DATA yv3Gat4oVN6FRkaQ1IhYzJqoZ7tDg6HuxK7cZO0S4YrRVIX1iWXSRO+j33HPm2FiOaP3gGT2AHa50Mio3iT3yswENq3sTo9g4YWQ
# DATA IjtQN12Meouap9jLsHNRfXlq4c9zMC7FhMAVa0jOM/rjsMBYhng4Qo2OA9PMRMHZN9NV2WZDhn0fd5Gdm/K2ks0N0WJbC50tbZ5C
# DATA Sk5NWJRcG7gz62wztt5PzcpLsGb7QUuJX9tUs/88fTz91/zh76c/MmXsyfSH6Z+ZLkafDv/u8LPpI5swdvgFrswCzv4rLk+/oocf
# DATA M6LssUdfHtHFJ3T5B5DJpl95fM/XzDj7B7nv8EsFMnsEkhq94Av690sFMuP4PEKcDv8eDDTmnf15+iP9QPd/49hmL4otK40cDU+L
# DATA r/OSlSFvYh2I5nCiLs6Tt4iCG6PVI47Uyt+DyiIz5MV7FO2xl8cfJV4li4SI5rEUZfZ2NhoOZ2bbtElHcd40szkFc3ZEM/GpxDMv
# DATA V9ezt8sOAnP37SCmEagtAzYX0imjzcS9JHr+cK3Iwh9TCxzYbKXCO3Wu2bZn6Z0nMwNTA3jRGEI6kx5TOFoH+BunKZR7DtQTiaDY
# DATA OVdvvUf3i6Z5TnMq9H4XAzFh+2cP8GKPLvZmeGYr1szFNs5ss3tWdLMVk+I4Z84aOKk1oLFmJzMCXgqn1jkaAGcx/q80/B9v9D/H
# DATA wV/q50xOWKizZ9KCzoJsNpNIpptRVsWz0QLjTJaVPaqeqKmXBPSU896+e/fWnZw6WKpWhrlkeM/oiOwHXtnhZGCEhlMioSmNVFlq
# DATA z4POUz3mroo3M1XBo7yGMljaAEDKwjYwZ4kRkAacDUdBB76RtFFgGwM5bqboLDwYGIO2Mg/YKgCHSsxDQU5x/GN6TUI3Y6dKfBDz
# DATA UUp1T8vxzRzfzPHNzpRvttpYs9LE51gG8vla/Ccx+E/N3nfYM4c9c9gzhz1z2DOHPXPYM4c9c9gzhz1z2DOHPXPYM4c9c9gzhz1z
# DATA 2DOHPXPYM4c9c9gzhz1z2DOHPXPYM4c9c9gzhz17frBnm9XNev2k2LNKt9FtvUDYs5n155XQZ5y5KvOYEia0rWo5dVisVC+nc70i
# DATA LCfJ9mYq4zrNoBZ0M/imSrNWE1RXFt9UlSy24iHvlngI+yqJRyV7aK2cRKOaxdbN44XVLV5YabNpGFQpQtovqp1mqVGZrTnNKlWd
# DATA 5q7UOSt5fr212fbn8tOWJa8spLQzSl7ZonmtnDx66NSSVxHG1xklr6KePlby6KGnSl6lXH4uGkml0jy7RlKpl56ikVSaxaduJHby
# DATA Tr2RpJJ37EaC5D1tI7GTd+qNJJW8YzcSJO9pG0mt1HwuGkmtUj27RkKxeIpGUmvUn7qR2Mk79UaSSt6xGwmS97SNxE7eqTeSVPKO
# DATA 3UiQvJM1EhvYWmx61Vptr1rfrWxW9/LVej9f2qx71fpe5SiA6uJGcBIaJlu6hobJRrNFw6y06uVm7SQ0zGLgd0sWDbNSD5pVQ8Ns
# DATA tdudTtuiYZZq8vPZ0jDVZl6Z3VnOHrXsZviYPGEnE912qm3yGvucbROpUDF/nb0nu1VhdsmsyUtmhSa2ysiiWSpUtWC+NOQ6r56l
# DATA H9OzwPmbDZO7aTa5M/L7qTW6o5KrnpmzPD97g16pn8nz2bsTL+KiHZLyopIUkbgCZgLBUsMs6lNVu/RywebmJjwwx4N3ssdoTqrY
# DATA bTjje57dLrSQ++lonY7W6WidjtbpaJ2O1ulonY7W6WidjtbpaJ2O1ulonadA65xFc+6ELQVQxOocTE8Fx9QMKrpysVSsNmuN+uXU
# DATA nEU9xoeH8ZhGHJJhPhniyoUSnixXLys25jV1jB36AYPxbu/AcK4YkUgxoXr1Jvb3r5cZi/hW+LogFa/jnLmcUh72JrEHwWZPvYif
# DATA VVFa9Py2V6790rwtEdqReSnlwV7AqM51isOvsMa/MS8km2VonTN1gjBOECYlCDN76Nipwzh1mJOrwyxUUj5L1RjdWUMOQtoLiouV
# DATA HLDRhnfeWBIyz4+O2XkADWWoZNCHDGSswsFXjwAJ6idT3XycQrbBjTAXJFiyOIJ8U1HfaXCCi2mCZjgHS1B9RtgsWDLEoKiT4K3/
# DATA Onz9KCCiFZxJin3NpKZ2dFrKx0iGWBvoAeAVFZNg/cbR8dXPmciaC1ZMV8v0FWOq7SBupxBKhORIYrdQ1zUMg6OqSxJIAp5MLpmo
# DATA N46KeX1JrBdC/kwXoKdMPB6qQn7hoX/zSH/GQgxM74eeieqYsDy4eXSMvA5sAy5Sv89zAF6eYUEYNdds06SK1aIZaoK9kTS9yXn7
# DATA u1T5yDgc7QRWaCp3u13qa1uTEXwbeI4mV6MACk3hWAv8KH+1zDxiluVmJSaqUgdiILMOpl3PCt7VqM9uMer6ckqsZ9Ax+k+J6JKa
# DATA zHXkCX+kdJESWyaBzPYpXpMR+1aV+NAK1MCfmlKMY564icCCiYCz+V8Km/+4pJPnRSnS3imxHHnyVsgjpqgl8no0ROIGrNpDbasf
# DATA LGWfPDt5yRdLXe0odenMHo+zAJ/MCmieNvxkng7pXABKquz0lhipyPMAf2/Cntcmwtw7WNVz6R2vi2ltDI1jyn0r8h/jKkMWHARI
# DATA RDQ+/bGUuTI3V8Fh3kmm3Rqv+PbdG9dz3tU7d3JqHJb2wsOC0nIHxFLmRSK0OIRKqK+VVFmpkUrByH6GcTJv0GA7buDhGMP2EqLi
# DATA HekMZMPbcljkthUJVYl1irahBDpQ8qgcO04QJawTgOYXDNpQBB0EFD+lx5qj2kvVdVcvs4k8a1qVdSmaM92BHBF1LTgr1rSOtoIp
# DATA ssGtDhgG4s8QGCnMftG+ZwN6dKAkMVUsC94tzalBzHl1THdkvtf1w95ktIxmeVuCwcLVIp7lS2SB2/21s8GdDT7XBleVxHninSc+
# DATA Zd0tNN6fH/12rtMYqROcs++Jp9B44MVXE8bYuBfxIJkWH9cu9Cz9bDIETrDg/QZ7xA8MooXu6EzaEJHpYyw20sbG385EY7Z3VhZy
# DATA T3QLpHni65VXteF3B8e8uWFDvyJWAGyZcai+4NWLxkocS+89HuGjCHPjVW1x1pO9MYpoDKaGvTv3hvdkTO+C2rzglvdhsiGVosXN
# DATA YtO49SLeeVG/XwajbDSUoaoMOGPx8Js6V95QmxO5Buc8DCtd6vsjKjPGflJVG3f4TjVG5DwZjHNaahucO2CK410Jt6OitSAeN/wB
# DATA 1amObQuayGwnEviZ3yUKtulm7C8q0VEA8W5ePNCW19ER+U04Gk+gqM5S4lYcVAGzmce1lSXluU8ZRT0TmXeHrKhibqBKHoxZJX3I
# DATA gydlUK+nq3psxeeiKqiLqtIt4NIvx37f0XZekvdi8vmdPg36epaTsH20krgitce70aTX4XYp5uwAlh82nmNqJerqUsAFj+1LsoB7
# DATA 0UGfgyD7HDxrH+Lwlgw9WPQfRS0eOJXE/GTALEQV0jIg+CDaV3rl2nT2x7s6+u+PWM6e6r3H4ibi7Ob1Fu03ZqczWeMUjK+9zeil
# DATA qLPje/ADM1ITGxdIKEAW9e08MQKpfgAHOw3nwUDf21Gsx2RtcFlibogrWqXHF/F8+NWNe1951hExvZ6RcBV2g95Q9Wey4Gn1RSyD
# DATA TwNllIIqDAP/AUpYekzUPaxZdoI+XmDPsBRYgUKR+SBj4dEK7KmZsmNs8LlZ/0T9DPsrMsR/Wrb9p5/e+/TDwdorf/VT/4+yPujd
# DATA R4cRDiaAqg4PTv0dWLusV6t/pdaNM/+WirVa+a+KyX9/VSyVGsX6X3nF88iACdocvf6vXs7/fv7zn9+eCCGiTR1I2OFxBpViLea9
# DATA yHnGfiQVxLt6/R3qNXiZk9p31OvwEj49UKCwXhGpFLJtd/iwjf7+EdmH+nMUv8KjFzr9Xtjy1OVb9FXfMjIPxpOW8s/oKziSheFA
# DATA f5+Q6fLKK+/f3r5169ptbKBeW1t7hc/YvKI2WHZlXzU7m9ZpMtkJLnXjtQ3ezYiTIWtg8F2kXvEiqL4X272QZjBrl1+RrdbduIB8
# DATA gJvvzsGgvY6Hct4azdeba9YO1DV2CuURej7JrbWNDe1fKgQPw/F6aePyK9l9n+mo8Tmy++ohegP1jvsDfnMSUNBGbuW8D1Rk5r/7
# DATA Xu4Vz/M+Gcspkksl3u6Q6/sPX590sfexVK80q7kHZGXeCXcGfu/S2p133vr1O9evr+XicSeMLn2wRtdpeFjLrQ3DIf5R3+99uqGy
# DATA R21MDUYjGnp++1u9UTXmAO0LvFguG18XZ4nsId5KndbSz3cwFowjdaxC5b+OBj/4GhfUAb8EB6Pw+p/J4aFCGN/xu8E7ZBft4JAC
# DATA bi8gv65iJXsDd2auea96xXmXr/Bpm7lp0FdUXPdhyKyr+GbfSPcnp7ayQXmfvoJK/MorNIWGm/I+043Ww0E8pFH4vhQ6T/43LqGI
# DATA kQW8go5LsAH4Q4GtiRhTqPW1/NoGfugFg3V5kBJSK5VxDU+OggL2E/A24vXR2gfb+f/g5/+2mN+8X7h46X/K37uwln4h/hv5mMr9
# DATA Bgm7huJfX3tnsIfTPlZPws+sbfAzaiDe4paeSsyGToTcwpVlnWr++D5O6lJMq96vPGzoVf8sjwOH6wUP22TrxjKRVDGAvTnqoDdA
# DATA f1Tg3Q/r6p2oOvexv3p9YyOVpzHFdOwP2qiK/HjOw+kBk53q6gZVO6+0Uu6oqa7CmAYjFTt9fUvH84PiPflB34g933ITH0pce6dD
# DATA xbKmHg8Ge+EoGvTV3nD7PprOdcMduveTTzfkyrXBnhwJspOarQR+vks14N4n9eqndLOJxYauNFbWWC/PZI/1y4ZqPE+TSTgNLQdc
# DATA +Csm69JphAM7B5JXzBYj35/D0VuO5BrZeXhaguELo+yFh8Vi5tLWmtqzIteS981P1nuDeDLEcEWzCyuaKlH4j0973qeUSU/BOwbX
# DATA 6TU5r7SRTcz81nr/ntVs7/2KnsSp1aNipjPcrj70nBUzzvICDY/BoKMOoJr2Oumvo5BxS4EmG9S98Tk/lD3WISh7+GmUfLlWX6H5
# DATA XrOiMa8J/wJrS3BseH3F8Xojaj/A6Rr8Q5WPHhwd8PQpJ/PlNtdHnGRAwaFTFpgemf4FFSR2YFHfq2h5sGUwp2V6n1okuiz0M7ik
# DATA 9MwfPmiWDMV0Md71sf9Kmqvp/bYosoOAL4ojS5kuhbsBbBd/dPAGCwtGowMWtgsfbq3Riwd+e4ID5WYkR+dNU9WOvjnJQCq1+8qK
# DATA 4V7V3LLhXfTW7JpmHtE+8wjdSRQXQAhb1+HkcOXd++/ffvfm9b/xfivfrt6+tn1Xf7n2769ez3nFCEgPEyanjn7udji05BXUPe1L
# DATA 5Km5BX4/XRvlmhoo0Q4LH1HBrasqc4GbZvKSsZ1wzmjFU9uyrMQCFdj6B6nb8N9ah2sJukt5Cp/y4t7FR5PrhSTXt3DYC9ZlAX9V
# DATA aUDaDR7mZoPO51WV4NB1f3UJT5tv/DZjTsvLaZqd74yi4dY2LK554cZ6iYbs061BRO/Zz2PmGwIkE0soVHJ5lNwa92imIDfmBohY
# DATA UhXBk9rm1aHoVoPvMFP0gI+f8UUZ2Olg7+XgLBhPRsF92UK5dXc0UQev9UexPrcqxZysm/L1jXRBWi1GFao2ouCnGq6nb19tuNJh
# DATA ZnrAhS10tW6SLTEvZJ/Y2O4lxb5QFn22PlrVj40yyXR/PPbbu3Zc782W2rz/Vs3z0tJMVyfz0gb26vn9YeeTUq4mlgHb0LA7B+N1
# DATA 9U3ZyZeOkbfWJFMiNZO9LAeQvMT82sWWj16me6Bom4ydjcaSIhr1pXxoGGsH6eLxJJu2rKffuPabm+9dv35kydGTNEua92RSXjVd
# DATA XG9CwGFDzQAwEq2rasyTIvTceoZd2B7tsFf/Fv+iik5uw1m++776neYAeWV0U5r03gurYix6hk34uU/QbbDF1IP8Dx6NVSRSHTaf
# DATA 21hPJjO4r6Dik/PkG08wlDX7EBhO7xr/AyFWE9Av1Ih/8Y3XPZ52xowGVV2t7bAueO9i0PY9Rvd42L00gJey7dH45A/JqMkYInfY
# DATA uX8Ns7C1mxH2cSc1sm186C2+3g1H/aCzhjKiinb/PsyB+2S/bXlr9++jxO7fX5NIS/E9p67EEU6x94OzcPut5v8rl+u1ctb/VyyW
# DATA Ks7/dx7//eJnFyfx6GIrHFwk08EbHox3o0HllZ///Ocs3CG8Wiy+yMIY1hiw4ovlimgYaOit3sB1W5tRHs+2ej3qFpZ4BbFMUa/q
# DATA b9jTpD/v+jF8g/prCH2wkeUEPLk/UVYQzdfdyTjsmW88hzDf4t4SL6Q/sp2QWafkeHckBDxzgRpZymPJUZ6MehRj6Tl1vOkaT/6o
# DATA Y+HFE09m7xPJaxkyk9FTDQuUydt2BweTmuY8XuuAy8WUBlvqWEYZBR8Fav0PGSKzzpgLSwYd7AVbpxlOnDh9pJOcEx19m3qUFXhQ
# DATA Gvo5GbctnwvPVfgOy+/C80fs7VzjvVBrGzo8mR8M2eOpJu/Yq7MlkxB5xxhnWsZ6GsRB60mq/FQI4/vxQR9bXdYtk5CTuTb9P6eP
# DATA venX00fTf5s+Ofz88I/Tr+jz4+n33uHf0Ydvpt95h38/fXz4GV372jv8fPpk+j3d8uP0O7odP3w+/fbwi8N/pJ/46e/w9ZKHKQCM
# DATA comBGtlUdOTIYqEPe3xdvsTKfOOp6P3INtp41XNLuzq6i9wZAVkNks+dSX8Y69+CAZYo7/txOwzFtMBuMQyTW2U9zxJ3SifH81oW
# DATA ZlJz1f4DtPyhmaAWkhkqWQUU+61UiuYM/ZgYtnepyNYRPopu4cwRN9CMEVFOVwasuO9jYrjFk8KVZpTItI15P3d7E2jGpH5CHLCh
# DATA eF3fQ2kfRNoZqO4YBYwM0/JSUqy2d4bu4fz7GZkBNJdKR85Mzu93O9bcO5V9agJ++w17Av7GO7evXb377u2/SUd5ZkKcSof9tvRz
# DATA c61l9SwD3ec8O/OMJBYNrcD1NeZMyUy26I7JgJsc/6jas6wCK1eScWDDj6S00+AsqixwTa+/dilxc91Lfcvf+6SYq5c+tX7feO3D
# DATA wsYFdeHeJ+VcvYIZi/1qqxf4b9NvqbX/d2rTv0N/8Bdq4N9Ti//Bm/4rN/zpv1EP8CP9+CPdiMb/KEfX6MpndO2RN32CO76gz0+M
# DATA w5l7PnHp9SBcsq4zgYYUs3fxPvp83Vjh3LKyUk2+Ml5GFfAHa9jbGV+6eBFdjcpXEwBaNk3xw4v0rrV78/O5WCvOZMP/Ov0Lejrq
# DATA 1B6hr6P+T5JHKaU84R6S0v8Ev6H/+wNnxvfIL/o6/WH6A/WAj41XGtj6OOvXzK2lPM8l79Ut5S3m2zfwvXxU+SA2T1A6T/BivP8r
# DATA RPPRqtFPenTp+g+/PPwdenFTeGo2b/ma2U8ivmaOqO2JG7OaDv87M42mdMoPqhKk1mZMGWZaTyrID5qX7tnB6dw6kKm27VWdV5Qn
# DATA LshvrEm4VuXJNskP/uPFexc21qkxXkzaXuH+/5ynq7/auPjamnLLzjiyJUBsuBtAfmmH3b6Uu5+sFTAFLxTWPpW9uslP/MgH5Xu6
# DATA JlGubRyR9Gx6L6WatlQePqORT+qOx8+hMR/+0/T7XNID6NbOLf8R3fwIAdFt1DNMv0IfoPoHClzn9XeHf6Ia9iOqJ2ouff/SylWR
# DATA HJzXkiWtpXtoyTrddhbiyXCgKuryTDiiLXCGfEdNi4rc40R9rWwbivHhn8iosWOsXEZqSQAahHZvJ7/O6+YkWcfr6Y7V9E2xLk+u
# DATA Sgp6XXHWHdET8934xitPdAsaI1dMVQJ4ynSwqMtULXGdFyroNv53a2u2h+7qH9XN8eyg9F8lGYdfzCm1Hw6/oDzhaoxh6S9ct/4k
# DATA 7Xb++MWj0+XUb1SNKcMeS0Yi6Jkqe/gnT+7ARVMTVHFztOeVNs0n18fRg2CQLt/FS83UXXxYWP6degU7yKwFLzH/Aj07pWz71jv5
# DATA pDGuUCFUitbXtm/dun/r3dt3tyrFUvHDwe1rN25uv7/9m2v3b23fvHb9/nu3r28p4Awbw/v+XnCpAoWGwVqqFa4lT1Jk7t9999fX
# DATA bvKyAidCLO93bt69dvvm9vX7f/3+3ft3rl29fe0u36JmqgW+9f5u8HC9AmM9Hf6Hg7u337tz9/6t2+/++7/ZKn04uLF9+z+8vn3z
# DATA /vVrb21f/Zv719+5+ev7125uv3792htbrArLSypSWphuZq2weSXEXnXl68V0RonQagONB28495RVQd/qtVqlNlNE/yJ9Z9LZSNU8
# DATA /KPUMKrBFBZ+lOfThZK8QMdetu6y422VVCiL8ANTmWAslpdYg1SjMCBSlGEkfEsV5weK92P0Od8ffqmMQfXLI+0VmWP4qfhai3Hr
# DATA yVr6pbSp8cmns8va5uZli/lcGh/cS9nnWKSev0DNi81tIyS3bMk5id4H9NQ9lp3j5xZ2+XoD6n21LLZurYINg2AU0xxnLxiNQprC
# DATA r60lDgzRe2R/hV5jjbAHOGzLEQBWmjC7W3Uf6rUCbPUV1wUbKXDcbmVzDdtTZ3PuprznBta7jEEqAWBEpmfW0jMeFW/2g5kvP5u9
# DATA d2bk+po7WRqXqOZQn/NYqvw/Tf+Ze1ZcQl+Lrvgv8DxQUyADBIHm9d2H/5jqqlPDMReCxIGvqvyLZ/NBpfhOMMZidzwnM2KpS6om
# DATA qsakA5wdlz02Gn9gu+YbRA7WQ2ZQ+UElCP/Qd7ViDzMT7YgaPNkXNMDhIQoOoxUy7HFSJPPzXW3AWBy3VXJeDQXfUlz+UcYNFYmZ
# DATA ZMkInC0AZYrrSGyg5pRmJmoDOLhC6OOaG6kfm5nEm0q9ZdyA6/P7jQ/W3ti+u/369p1rGI3W7m0U9LP28sn6r4MDdtHlvBmXYeZ9
# DATA Zh1Ulbj+ae5AS2WFavodlxy6bu4MH4sBAhsNFxNbWgqULEvqOr/2UhFPbCsVD/3RTJfNxINnkVYHib4E5c99SqqZ4orZIcUlkmkF
# DATA fFkFIVdwZCawW8Nt2fhB94UxZwiccZn9B7I6lCwf62VhrIkFi991k5JnNV+kRRxKZE3zGjxStW7dv3qb3SiEork5sxTK2buwxSxM
# DATA Ei/z9UIW6qHc54+6aOSoFK5whHXsJWbb8pAemDYyXkt+TLyWn857GZYh4Ypbz2Yb775a2yj0ZIqN+Z+OT3rQUisGEm/ZGmHFjwX9
# DATA dVBWcug6J2btnVvbEgAmom/1opbfe+fWXl1fzMSaEmfqMD2uc0xZ9+ayjtJsxqsaDlFxdfRWORmBD9jY4OzQ1cv2I/MEBrcUJgMy
# DATA utd/pQMShz52Y2FIU+2H/cN8u913qZDYkbDYGZS04vmDFXeSn4tjjOYJ37KP/Mnc4YF/kFHgsrajvuIu9k88vbN7CE/8E48tr5o1
# DATA IKSavc6ReYOEyoGTj9CIIGXFP8F+XTQ6LOjdrHFAR8vuaVW0T9zRpiNL98kNJtseYy5oDVwFb/rPMvJ+xVH/A//wjUrr16pUv+GS
# DATA 4PnLVcwwTLpuXrv7/ru3f52xl+ZlsQZrRCq96nvM2yDX1e0b2OUqhmNbTOj79oiXMeyVURzzcDXzpsRmmV0fwdmpjZknxEBf+BDv
# DATA ZL30ysz+nk8+TfXexis4x9Se3X/Kd0vXN9sPqLL/zx7Pw2V6+tgsudqbNFMuGzOLYkvqM57zPvF+fe1vtn6zff29a9pPQhcye2p4
# DATA JmBI1fakQPyVOO3OJFxMDOZuC6IQliRjbsx/4DW1v7Cx9aN4JT7nibo1uVK+WfHmYOL1zdoKkxLelKpTI91daoNXer6SxHRpBmem
# DATA qfTxf1HTPvaWStZa5cVXMwmgp39vJt567zvFzF4n1acfkvXTV5buYE7ts1aT7/QmdGsmCyMX2fg1d3F/r31EM/2Y9MdI04+SdErU
# DATA l3NmtUmzxUrZ/XjXL9fqdmo64Q7OHW7ptfyCumUj2Q9rLQPzStjaqDV/aQ+NrL07GTxAI2Mzuuf3Wx3/kl7RY2qCdUJgI+e11rL+
# DATA dIlRQU4Tr3N4qXSp33eDh/LJrNXImdH7SAgNqckeWzV5j6Lx7P5btWrWE6yIdHlDsVvZZ4vtx0gJln95jB5ihRoP0FeMYMNkJfHO
# DATA 29uUc3feu3En6XXhZRymFrVXOMshHjQJeSOJDEdzJQcIV5pkTZxXT7iifyVtVCoUNQQzWMtSLJJ70U4Hzi3Ibt9U9dm4sOZ5axck
# DATA hhd4a34mlrpM9lg34L4UTZLvORlFBljbXpNzbEcXE2/l1oaUmV+Mon02BWfibm9a2BC3CW9Ztq3uhUslVA5+vsu7VDc8bz1TOhvY
# DATA aBftL14o0csAbMYj2nMtmoUlpzupHy0bhocL5TY+/D1GkC+o1/re6m4Zn7jFOXhx3joErwLPq4r6B1Wt6epMZ4EKrtc55qblv2Rj
# DATA qSw0iSUc/ctq4SL3ipU6zkY2sHXadK+g5KlovE/2dRfkxHQBuyzUft5xkL2oN2XH5oqybVI3GmvFVFl2O0mtta0OiQdHcU07wHiH
# DATA h15k7aUC4c0HcGllW/R7gwcDnKs3Aq3qibXMMSCV7le3slXMql7sateFkS4BXNIlIGN51mnCmaZHOmlfs/m4MT97OGXqND0e4bmh
# DATA lZTFyb/JwiT4SUVA8mEtXdx6fFjTGPc8KA+j9VA6zJB7b+gq8MkXDugDXbysBbd2b2NjfpBWcjM1ZCOZr819kocC7ShADD6wD3eo
# DATA bEM964YUsxFvtlVB35Nzmngrd/t6u0ZyzE1FSaVBRStVEuaZRbVyybNWlzgIu2ISWBmxypPZ3ICP4wPF+1iThTgGyPAkRF7ygeBB
# DATA JPVyP6ch6KzdS/Wu+gGpR6gc7Aq6HQnpL2tDpJPNJ265CuRH6oFM3V2tQf3fakBVXfLfUc/1ZzKKaap8+J+SXkxcldSZ81yZrDOa
# DATA jsI0nenHuQ80PaSYzukp1jA1CqaXQFRvzwNl+riX3aX7rTjqgXxmZZB60oR7ERdeWWmQIIs86u0x0ye+Pwp6/jjcC+6PI/tEEwyB
# DATA 1L28pDp7KCpl0ueNtbLEnv+jMoiT/X5ixH+FFVbOWXZkYPWeJ+PTP2PckVnLI87vr6xlRJ1Y3Wi4s5odDo+OMA9dX1LYNFvnOf7n
# DATA 6E4XRzhtpqfz6hVVAwbBZDzyIfkgNUF7JMiuNaov0PtB/idrM9D92xngMK4Qj3r+QTCKPTBXPb87huJ4NGDUK28LvaxkVeS4uOii
# DATA mBeZlZp5G2yS/k2PmPq5woHf79lDafKDXJcDHPmFzy38nX6+N1uJEw2ci57xq2cbwsIinrPVdK5/Vb0t3S6tgkimgVbNYl8il9AR
# DATA oc/sEFSlz4c2/n/23n25rey6E87ffIrT3XYOwAbAi9RqGTLcoSh2N8cSySEpdxwKQYEEKMINAjAOIIlhY6ptf5lkyi6nkkp9NZWq
# DATA ZMZvIHe6444v7VeQXuF7km+vy9577cs5ACm1k8zEmWkR5+yz73vtdf0t1VEv0FrRp9tupDWOy8qjcOAuU41zlNaTy5nVhGibw+5B
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
# DATA frSjdti9rdbd+7ub3zVrEs/SlrtNID30AkeRaEM8+aR9n5d+8v9v72ub27iuNOczf0VHHm8DEgCCFCUncDAORcEyE4rkkpQdD4ig
# DATA QKBJIgYBDBqQxEjciu3JTlJOJTWp/bRVM1Ozu7WfFSdOZDt2/gL5j/a83dv3dt9ugBDlzWSExCLQL/f13HPPPS/PSWlAspoo75va
# DATA feLvOR7NzDHHfDp6WDhVPj3D2qVc1YiApfPsUMuXC/Gu6GYaKdpkB5gnqV1a6a7Uhnz0kk6RgW+2RE2zGJz+goxMdq7LpDExboSK
# DATA b2lnL8PsMr8Z5dIGmyyzy0vK6vcasiVOyRkGMIvwpXf6Jp1KjHgXFa4RBhhAzHcHvR7W57HFu7TwH94o4TK5XJ2x6+rNV3Oaz67G
# DATA 2GXZoq7cOJM8Lly/nnvix201Csp52u5ELDO5R0ZnAvQemGbymT3b4/zGoTkU35mmnJeeB8vptTctcaPptXc5A8vlDTcvYk+YWaue
# DATA zEqXoR9O+vwnNdyWQce+l2UhksK15YfKmf31NGvWpQY8xQZm4J2/gHVnPjuHyrQntcRSAmfmrbsKA8a8Oe1eGT8yjB/fdMK/VEZn
# DATA 5vtjupqMbBVYTNCPgtNSYCb5qVSAGYkPUO4LcTVaLl5dPgqQM/yiXcrt5ImE0Aq0Eo99NqvsNTF4fFr1FfKGPx1aY0Y8DQFOcIEm
# DATA LFzVmXGmoRf1hKVpt3FOZgiLRUZsj0Op1W8fD0bTvQzvru/U1hBigZwcave3996PAv26Kn79Esp2y2ygpTqFeWB0BkR+QjDLG6ih
# DATA VM8LtJmU+ehVqoM4NOloJ9HZYjV2tn5oFMokacRfq2Bad2Sr3ZZq5HatehovL1Vzc391PaFLI8Pq7BCjrOrt9sZ8TuqhPq0KBZQE
# DATA 8FgdPGUWSe2uZlQFopLJx5giQcZMnsLYEZqa0wuvuhWZM6fgAWDmvg/U0az9cH13b9dPLEVW3QirSVe9MPuz9C7dQ6v7SSo3XVJX
# DATA o6CPUSA80WuN2sfdh4GcbKUs8gv1Bv128KZK4G6ool/zJn2K7A+iGruY1qTVl0CBALX9nNnkYITLPvJClfrSVDK6YZf0ATaKnklH
# DATA k2AL2VH8sSvI9kxsA0cx80I/xaEUaJ9Qg7aojvATy1spej676wXGi2oOPjBGInq5fQwv5ui9fAZItZVrDB6RrQPaOuy12oETh7p6
# DATA PB4PK4sREnnlZpljsVwP4zSrZVAaRTi2Lh1S0oRaMNttIaY8sQNMjfC5Crr+AM2HRXQcHAYcPQhiKqlPKl7d8lfQVeUbtg+GPyTg
# DATA Gnj+0F9afqNUhv8tVZ7g1TOK4fDjL/TYlFDBtlloBixuFUeDXpr/Q7ykwdERR94+8TujLqXzZStaUemABkOlP3zin7QeF9E2jA8t
# DATA lU9YB/m4KP31b/pn8Qo4KLJ9HLQ/oBLGMHbYVX/t/l2SLoHqiKfSv4cBGiKuybxHg4GjsEjWQJCVF7nMa/kScJ9+blT9OxUPTSlF
# DATA R6XBB2+VK0v5fKlNdo1cPvYE3JLQfigQJBps+i1i8hJ5G10A3oZcCi4sLXO05GjcHAaj7gBdvfzlcghdTttcccTrarLgGDcVeQKP
# DATA dvzVNqE+UVHYCS8XnpbkPHP4dtQ02Q7ibZPLyptfMAJ06mlLbcIGUuuNJ/oNaMWZfgubhOldcLIihzjpghQQNS0uW6Qpa62FFAX+
# DATA KDF7vsCofKKDhgVYhUZZTIAvVpZBOhl2+4E/Az9QbIUG5t7W3dqdB/fw4RMYuS4e2cbtYbXs0wAqVuB/u1z5NvG6lZWbFfjP+Lo4
# DATA 6QyJgFW0lovVRCNE/koVV9RUZTTQ4mQRQzQri/hvdI0HpbIoKmDLs5qHSzWBBykqSVGEWQ5dO5vGjlmOKio5Cs4Jcc3+y3ENizEu
# DATA 2/e1QkAfuSSRxAAE4h7qyXlxdC9vwSnwl7MXgJBJ9VYzlWmZetBUlf8MytPOdGWCOpfZak2nDmpmc9hZPOqGUS9tuDNBIqa83xXZ
# DATA 5DHnvVfVCWdLq6OjCa7WbbqTU7BsqCtoNmH2ms288WYJ6LvZkldyvo6+RpplROBq3deq9GIEUcwAIuR67jPMzFjOO6LEiEwvk1Gg
# DATA WXJxMurJHTkIFBE0mzYvlKj0tq19/eiUAvQi0AZ0iCxKQCUxr0kYFJHvRL+4JBaL4vH4ahd04Qk0MkamWETyhacxQrS6Tdov5Zxh
# DATA CJamA7jt3OKTME+odqnJYK0hsscj6rHqa/fETpHJRT2mMg33C2U7MYEI3B1ECTRyi8Xc9GTNp2fpDz4dRmhIlL3eDvR3UkocAYE8
# DATA qjqTk2GYc4JfU7ms3KCvBtY2/Tb5ZNAPgbyarbDd7Qr8sYjxvawWBr6l8yV7Oz3M+jWYAXJTiq6z0ygF9r6gB46JiGrar6perAUF
# DATA W9GFfoKktIq3J6/nQr8aM95FQ69AzKcNsRwV6Ls2zvFLqQ59jk5NmQta1hnUocCpdGvnmfA4z8ioLw4sHB8lQ9XG4y16kTlaZbCt
# DATA jAYZWLbxtuDF+SuOOKQJruH2jp5xFOSXQZiZ7VDcPd57pba+XK3GoiH9a7wphp+t1mIZA4nKDp+Oqg76F/kcH/GjyjkG39CIZ3dX
# DATA bYpGVl/R9ScmlhwKO7MuxOxqow24EhN90WqRXfXlGdG0plg7fgLgXTvqpjQrn75OnnwQnIoDEcVbWVFhzs02fzbH2om25ySoT8Ik
# DATA keyFHk5lnaiXG9kVGiJA2rHSIHfl030VsxWJX/GuRog7afOkSjaN5Ar9KZvkIjwoEHWhYU2yGDWb1KRmE9dhsyktwjkOu0f9CYH+
# DATA 5fBrq1faXb+3V9u5X/Ci3+882DaToPN1/pPjAgqepAm53oST2GmkZkm6vrDsvZCWw1Uj3s2UNdFrhV5gI8DCWTSkdNlxKOB0sQKO
# DATA E+e/8c7/fPHT88/O/3D+Ffz7uXfx4cVHcOEZ/Hx+8d/PP/Pw+sVH8Nj51+e/P//i/MuLX138EzyK93/tnX+Bd57Ry1+ePy955/8b
# DATA nnkGxT2/+Ajffnb+eyz/4kPrOQ//jxU/P//0/Bk8+dXFJ1j5P8Ijn59/6a1urxfh6tdQFtb07E1s18cXv8CC4Pqn8P1X8OsZtCDW
# DATA 4GfUYCj//I/nf6KXqYBS/JjL+tPVtbXa7m7z7dX1DRmQf4OyvoZGfQZ/v8DSZuq3VPpnevlzeJ4r9cziLn5JI/LO3t72bjEal4IH
# DATA j39NvfgYivxKvv8SrvNrH0KFv3KP3jMcPc8cqNhwXHyiOvBn+PkhPIVT9C8wcPwYNvYL3XxrzC4+SYwZRXU034axat7HwI87aKxZ
# DATA f3d1r0ZD939SJo86CO3+A/5U0/4VjgBcRMp7hv1lCwd1DhtBl4xOlm+Xy9D0/6WKVSNOv59Bw6HHiQYrY2DUcGpojES/Pv/txScw
# DATA t0yDlyFLj5pHg0aD+Sdp1W+pv5/B16Xb3g+6d1IbFqWedLQrben8Fr78Edv5MTz3vEB3qfovkTCfq9/PZBiJACse6pbDyqL4+wWP
# DATA WyfDHnniJRpHFCpNs5jF/+AaoFVAqr9D4rFbRpV9BqP5MVX8ITxMZcG8yatfynR9efFLpPR4AUSjf6ae/PL8j1DM5zQSrcl4YLby
# DATA LGZF3D0NYQevIe9VbJDcl1AHRWwStTTn/wol4zQ9Ay7xPME4HCtFJvOPRIG4En+esazh6z9753+AOfkp0faXNBNfwFNfAfk8P/8d
# DATA 3eG6f4XsDMr6gqZXURlwtU+gSGgC3oV7QJQfYZDAwt+8+vx/+Yx7IGecvtw6yvC5vbJCf+ET+7u8vLJ0W12T628sLd/+G6/8TQzA
# DATA BNVbUOV/0vm/du3aWjAacyhu4IkPkIo9smzLrL8LHnk7ytCl/Kg4CoGCdrsndGZUGlf1mwtifZm6hmcU9X0QLhAEIVpMet0DTy6j
# DATA AK8eGenCIqlRXznVX4FLDlGGX+AC5UCgCuTzasGyGzX5Yljw6NQgimSM3ArDXu46Ct8FArmUsMzDVreHZyPhw1UfhI3PkA0CO/sp
# DATA sTzF7rZrIGwjcwW2+vziH4WhIjcWdigiF8oDtDd8jQ/C5sdSmSWmPSd+ClV8hEXBU1/Q7v3MjyOTGzI1dD5X96Un6OaHfcFEfpga
# DATA q4pdggNRazjG3gwmY7zIBj2NanzL8CohHGnWvbcHnawsYrERciAplxjjSPkKRhTYHLa6o9zxIBwLnEN0q8DJY8ypC6u+drdj5yb1
# DATA ptg04G10/eo+5AAcOhAaReZFJQIFG4jpdGayXrUj5NBHrE14ebD5Dhm4in77+/390X7Zn6oG5TMJyTZIJLILKxESpAaP5DWUD1Fi
# DATA FgkRxAs6Ejy/+BkSA8qQn9IrQCXJPMNDA0kAe5UMAV8qL6941+nP1Ab/e5L2ZPcXCtaNRylDNR76VlSSJQlrz03pEcSKn6P86N3v
# DATA 3tGp3nbgVE6ORl44iLMjnPrgHybofYK+1+ihOgkFs1Sh2KJ9AWmopAmgyYQOc0zf0EkSrvLx/+AUlep5PdHWVY4VET7gP75V/g4Z
# DATA vPoDdCPAb+T6EPTJbPHt2yvkv0KMQlererUFpezubqhgjtDrUMYiwrTshhSjia44Y8FNfxOWCapiYCL7PwlGA4Vqz7Eb8jyvWJ2w
# DATA 6MDvDIKQ49vNZeMrP8OpPcG1A7+ixWf3JRtdxPVJckonGaFQ+Htki0hFMfH7d7gWkLb40PYs2zPyKsrXfADHgVa5Y6/IWVwoGjOy
# DATA N1j3FKyzbVO5yrl68Xm6xFzZx1w86qAQz0dJPM1+iruUMaLADeDKMzrlPEscP2bglN9IKyShEMsSYY9JAMUHNLpZ8oP85i3yJ8qI
# DATA 9JqH86TC8EPvYDA+9nZ2V2nB1tbu7q6+CRuUpEg5QQ88unsy6Ex6XcJMMdjVcHLQ67YR0TZBBHAL2JhFDy5+I8zMUdJQvQ63FD0N
# DATA W5jqgk2sYVhRZSp+GfnzGo37VjVWSeaq/LeEuiHaN3A7gGn4GmSfj0jY+Uipv0gn5xJ6Lj5Wbo5oEnUOVLRayHrdYUt8bKxKnQAF
# DATA mVwilQ2UVaLHcJKb40EzhAf7nTBHFarg9ionh1pqYBy8IoxSf/Aop2ijNBm38yX8Ba04Geam8C6S977wSLX2OY+CnOJdgh8ex3+B
# DATA B/KvWIP57OKfSOvw4cWv7Sw4jj1Qx2gMT6cLXIZ1KU32irbV+cQ4mc4AzUUKQyIWM7HoYxmhxsMxHp4Zwef8f/LQkcj0O2pUGJO9
# DATA iKNo2csQsrQ2Bwb4Q6DhL0nx8bmfaLrD5dblZGu8kHCzxTFDus75iODQPoYdpzQMTthG032ICRvxpwgovU6Uj8h0saBSDAsF5yFU
# DATA tS7ibQt641J5as//L+mzPqPN9TNL0EMB0JZnTZEwPqbw+p/ocKNHleREQ56FDiqE7KEln3Grk0G5DtOEjQ+HAiQM0E9gzdMgMWeI
# DATA 9bk1Hpx021JXfOB0OZa5Qywcs1cLXYtHdWbNkoFYR2WFKUFpQxUnJlmMbNJLj9RMdHsY62c8yMt+mPx+1PMqGY5KfMmocpgURw7o
# DATA sE5QpTnENV6l4Db2TCcY2sPu46pfGvfCou+YTYLLHYSlww5y/pxZif/owCfbEbD0oHUSz5qE18Q4mOiY8cRhbxIex6LssL7wtN/O
# DATA qWegD/1BzgiWHoTa5Z0nnWLIeV1iIGDP6AJxN5IYU+dKeLSGTQtzJ8H4eNApCMxADIHNTFHND1jBWyoTtXEixCvJQ+Htm99ecdxG
# DATA fub9F688KL/xRhaPvbu5a7a5ArwAtvI/aHuGcfRDbrq+ua4Zh0dmAGUOIbZwG85UMcwpU5VUYiATceeLIKUUhpb5KrMO3On7Rzm/
# DATA 3umHjf2+f4O6aXhAqPkKepSRGJMgaNdQeEf7wQWjk+6YI9tzT/BOs90bTDqHvRaazYddtiz7FI/P88aWfv2QJHzhd4/aA35N3tJT
# DATA l/KqSgHA7eSEA/FGBCeS5MbROBQDjUQEZm+MYrU8ZNSEkp9+2ki2/JBcPmBEkcXJj5H80PkbuJASJ2yfEit1/hskDm2bZSqC7eLi
# DATA ZyzAf0m2XNp/fis2jq/kQAc0WNTqs2dsrMRH/BgymAn3pvoq6DczixT/QiT92fkfoTI0Sn0Y2dg+pg3PWAxW/cLu5onQsdgul4YR
# DATA sKUfD7r93KH/5IMzNJE/RCd4dvcoWMOvsjuUCFaPcq8Kr0GHbkNqIwoqeIrtzCAIupRwNhWjoct2MKRajPhKC7bKgAYs3dgvNm58
# DATA L7pSMsEDG0+WC4hpRaVNF1/SVLa8aCKefgycgXyIfYk/4Nb6N+jvDZ9CDYjqVUfMNKE0270wQoe099yo8MTj6uviw9Zosdc9iFLB
# DATA LsLlRUsuTHvIkBVVnhjNRbnqG2qmblB8hX8DXrvhJ8Ms7CgtI+9MXNth9A1KDlkdPbv2JOaH5d2oEku5gVyMqZuKzc/a3OLUxDmG
# DATA o5B51jBjUJTrOa8RPM2NVKoXWAhUepSizUHCUR6NVvskKNaZeBt1jXiJSDxS4HReEyNa4Drk1fAnPCd+RMzuTxazkzaxWMCNTYZv
# DATA RxpteiJTo32JxaR5IBmYf09H1Ofe6tr9mlb3hmTXhs1sGLThgIiJ7Eln8jho71JSk3+YDNCH0EOdSYf8Cdtj1s2Ex0Gvp+6z/gQE
# DATA wdaQdzHqSBSCuL+PNLQPH98ITLzGF6+Z117Ha6+/Li006IOTE0mD5a+fX1S0cMNXMXp2gky//qDfHYOscdeINtgJbEPa3saueUbe
# DATA 768egixTlYCq4gBFxEC82DyJRpba9vvvtXC3cD5LvMlqjIS9QHv20FkfhKTweADPPbjfCj+olkG62+/r0a9eA0bHY3rDv7aPSiLZ
# DATA qG6vrMwxQLR4ZhoeNTDGoMC6gkFr9bBP9T0sCd7a6q+1QA7vtEbV60X4n1e+WVi6VSmXK8inrK7vAGHBvvmToHM36LVOd4N29eZt
# DATA fGoblfIhHgaqY9hjqfx1tmw2eHSDzp3TKjU+1AMbGwtH+MlckSczBZ0oqAaOFhmSSs+UMzSOAMU4IHwIq/fGxzoUcqQkWcMftG6E
# DATA S5haafgpekPLX5R3dQoW4UxfVihGKEh8OjILv1KnzVwHw2SkxQ1tjUveVDKtxCZWFYBm8kmL809GNCjxt1BpNXSHb8RcPvWAG67C
# DATA cW1Xq6Ssy62Spe9qlUjj1bIDpbFNpp9pwiV4eGo5JitV3fRqTHfwy9VpkJBRtXECbZWUMAglyym0VTJFaHfBsehPFjTNnoioaZY/
# DATA dzeYvCtWYlYcN71pw1feCV3OuILVaEAbsxtxiVELk2fFFJKRdWdLoq95PwiCIVkqFTyQp7ZiOnFjTud+uzdBtGsPPTMOBmM/9HoY
# DATA 7C8HkrCUzJJd98c9Fagpy7JiDKa1mjmgUjplGsNLkVCQlyVvPYvr0nzGTpfIG4EMk4Xx6FY2saBrJOEd90JHPm+RX9BPifHQjJ6Q
# DATA 7GLdxTa7IJScMgubF76++BkfHy/+mR0z6IBJxnk8YMLOHEsBw67eUGXdakwj/6Z5C1vSmMFVey4Paty6E87UlmJkLgdrtL7/mPFA
# DATA KIGnqMhYJIOXH3bxuGLwgyjlnAL4CLze4KgUc4v3z//VcGyBEa3AAcpwXSTEuyj3ZBBPjC66Xd90iRGfRHKxWd9cL0QOFfB/Mbdj
# DATA VCx2pGqk0kr3q1z6z+iFODl81DyatEadl+gFmO3/t7R86/ay7f+3VL65VH7l//cN+f/tBWjbbo26PcRTCNHQgnkjBebnwdvvgRRL
# DATA 2VRlOyqw/r3b56SjaIkYcYLh0ywXwMN2f9y7hL9feDwZd/ULHJNyOQ9A+Y3QQErBRQ47HEU1xW+O3f7c3nGw+ccc5VZuZXtdBP2H
# DATA 1SfXrw/CkkQPwv66sdZc3SCv+DVD4TvVz26HPRqNfQx9xH7PVs2LD/G0HQU5PFc2N4q4gH9/jRfhFZjWNz0HPz0EoesRwkCdf4o+
# DATA MhQy8PHFr/ypPnwwZk1jO1T5IBTC33GXzJTGIG+T7cYCr7KBdMV6jW+WHrWAQavBvrVSngWvkt8co7K6jy2KWL9VT/SoVclS2RBe
# DATA uB6j8Xv8VO3x0AaDiwr7oNvrxXEao1qyzGm2IY1PmZGCSdlxUrXTSfrI1k+jKZasrx+RDh3J4UsdAwRkElm4X8CSB9uM05KHRjU2
# DATA f5vlU49ns/b9dRn7RsHBYDBuKnaag2EriIqsPYbjESwykGgGmP69KiqXhOq3iGOtSkAJaNLvjqupCprEiwS/GqmyIsrjeq+E9r6w
# DATA /DBmpECpfyb3ipPW6APSrPNLjKzCgBS+aB73CIwOhrtIDl4/HhzAAodOI/TdcPAIXuoNwhCHr9f9IFCKSjiLjUetftjFbY8OlnHN
# DATA I4zii6sdhRPg1BXSVGQ0UbQIY7s3NANGTekQsT1aVWjlbMc0EJ0uZ+UcH9fIj4Kg1lAy5xHMc1qj/X6q3tAu0dQcImabjAoUcs2T
# DATA nKmwF7YOeoGhZdwehOPq4iQcLR50+4ujE6946CWaYVWTpqIj1KXiBA9AhprO0FaSR7yxoHxOoQ1kj0d9pRJLPMVN9nktlSjPtTVP
# DATA 3ErMykBCk6pV+fPIVsaBtBUhzimsgITyoKM2yILHgcHQNAlDCGD44Bwuvx4dd9vHVZaZSvSjoKQyM3EUvM7AfZR9iKUh2UqpNLip
# DATA viHGob2nMwzv4SN4iGrI+fDDNjPAhcQOLgXaW704NFd5rInPKTSaRtIfj26UyJUvxO2A83xMQswrzUNuWSgy6pV2ZpToKM/F2/7d
# DATA JVKJ49PXEnD8e/GRAp72ppKejYi7P3O47/lXMobKFqKHVy4UYYysR4Ao4w/BJXsmVGGiIdFPTemWBDHGuLZylP6UusWipb6Ijpvx
# DATA 2GEeC+34kexIpxu2RidN5L/oQSGkSkRn74F51yYoiNCwGD3StDm2Pic0qLD+VeAxqnyVSgxlC9S5oQpDCcElb9VDOQ44mAIhHSGo
# DATA Kfnxoqqi53XFAd9gGZ04omx70OsJiFGxSLsxtY15e7EI7IdprkqwixGjg3u0w2DWjiFQz2l1td2ejFptsl0sobaMF06UjVpxqkbe
# DATA mZlCrTTjBZwI441p6ych2xgaTWosnPtOYLweHQd9wXKX4LFWt2doLt2NsVtvmlQzuMSMqziN5KNlS27h4oX8U1i8zzHC9VObts8/
# DATA e9Nj/yTyaf5cWWBTRRjiB3JDXfwai0AzKTpFkwekhfWqV0Yub4+XuSUJPhetAUSB0zadl46DNiPal/NdoSUfzxBwwK7qFu3UEEX6
# DATA bm1nJoAtKYa7FJbkZ32p0tB4T+paZamBalcEsfcbrEc075ssU5UqLJODxaSYciNmNp8m+kZOb8/Of0sO7khFScv4F1rLn0+48fmL
# DATA MO0xAR19CEq9QfuDxLkMHeEJJqQvJ0j4tdVc26mt7nlP+cfO3fd21PfNrbe3Nja23rMkFQbHB7FxNBki3IzCADkc4ekl5thKUPQx
# DATA gJH1zT0TXyQbbySJOaJQ9qM3muv3NuNK2x8EpwcDEI/WVUtz+WzYk0u1yo2CYoyKGL6nH0txmowxQwUYnDbhYg7/KcgVzHfXrP0w
# DATA QzOdkAUj0K8XtzAkBrOS3hBfCzEk4MB/FM76Zjr/+5oADy5+RhE3zCvd2ijfNnuYy8kwfFzOnpFo/zSTg1mrNjqYtgsK5v0FqdU+
# DATA SdWhOTqoJAr/L83GwHlgiq0jdEV8SSaATP3/UvnW7ZWbcf3/G+VX8f/fyOe1b+mDN2agHp6Ojwf9mwvXrl3bkNTdmGiHqUQ5qZVw
# DATA nUiqb07jTQkECHIN0waMBpOjY5IItdQ8s2HguBWiQUD/PGm12VKA2C6kx8Ath2+i3hfBV3YwJjgcvwOssXcV8AIgQurv6Go15mrT
# DATA jQ/IMyxrA1U2GfWgrtKIW6fqlMYW8DZuHAu6Acx7jFoihwfC/3XeEUjxBc5OTQZ1sdc3ydUfJDkjBcHC2sY6nphozik3O6tclITh
# DATA L6xtbe6BIFbbQTitvZ2tDXrcFkNQmToa9PyF3drOu+trNfsMJkBwRDFajbjwYHN9r7mztbUXyTYuZ7GF7Qc7mCED83ymlFl8uAQ1
# DATA 763eq+1SiBRpMSR5SmfwqE+KHIqU4hyOAvXKSSV8yZx5Ki+gM0e3D1MpwLDdQ3WnDeTchxfyC/dXf9jc2LrXvPP+HlVphM1rtS1n
# DATA aBoNjmCsQ0k+M1IzDQSFOIUEFl/wgodReAysim0MnwyPvQM0scE6gnEY8jNhQZJnKLlUidEhHZNbjzwhQxUJjmuMz29McVVUaja7
# DATA mFCRLogyio/cdv4KK00pebjg8tGo1DLji6I2MbL1iXZGXDigPpXFWjVC6R+ih9IUNkZ5R4EKhJaJxiz2OCZRzhxJUcWzzljteMQM
# DATA OknNzQOim2TynHs7td1dW+yOdZhTkKh5JZWC6lcspWV/gGoxigDFf3KO87cqxhrhyGogkg+ii28Oxm8jOcSiyYwCnvg0SuSfw4kr
# DATA 6C+pU4POKuJoQ4vwRE2UhGjlBEQuUC6hAdcO6+Rhd0C6OFVBXUpvaPQCfAmYBSypgLK8IA8CQg2VNuRk8DBgryYgWDQfRr5QuPAe
# DATA gXwZaqQCntMSGpAf56gmjKC1rqpG5ZO9rxu9aNTVg+j6dNJ6nCsXaCqK8b5EI9PIJ4osMWfhtlRlRO3XqlCqpILHZUxziE5pGKKw
# DATA /7hcLu4/Xjrcf/zGIXz5zmFDMpLRs3k4gy6XGwt2J2RisN05x9UbXv2J34rmkUpCqHpmIvwg/Ka/Z418vbi8UonXIUn+sNNQDRS0
# DATA 4EqMRykD5R2XTyuXEudu7N9ViTGcJC+wHePpuYSm1p1J1blepi/QGM8zFqp9wtBnCtPDSnlT5dPb6F7pRLZwPUbFsfWktRfDXiDR
# DATA VtGADY8Jily8P+URXwYYd3nOf60bYrPeJFdNWLkR0R99wzNZvGyy0DWoLownZiUdgVp+uElLkdaijPvvIR4qM3Xg3NHbdFpXl3nc
# DATA 6jRulYYzC2I0BOSOkpPlHk5OcrrQOhXYyCwbmENuKo/IJzN5knOGbkTVK1ecLh/xuZJEWz0yKaLlRfvMdbrhsNc69VoUUdfC/Afe
# DATA tbInYAPXSnH/g2ySNbwCE5liQVQ1SDnaPBIEqjaSdRwrTItEZH3DW1I31mDoke/0gn6Ox9WVJYNId3dMWSusZyUvnJA/HbCpinjW
# DATA pGDUZv62VC473mEC4MZdp2cWzVriTQqNbdFYMtFlTnGhmGXFzUJjhQa91jDENCI0W/CSRZU5o55DIIfwmCtieegREqGzJbR95RM9
# DATA wIjwE2zIjqIuo151ydzuk1vKGbDzdg9IwZKHDCdLpSwGYmHGrxA+eoMjYfri6SB7LqYkxUxAjoSXiqtQWolkysVZoyvX++R4rxG8
# DATA oLiolBlynV0uu5nIgGZKFx1+f9hxq1ff29na3Hhf6VQtZWvth2sbmcrWBEKBFsWQTyaTUFbijFU/j0G52Hg8JVjRZ/GpiiavxHBF
# DATA KuxSX7byd7Lfb3SHg8cdgAPqGSs/bRoqAoxIu4cZgg87cT8og0tFqtXDjsT1J+mySdSd4wOQnK0wzmMcBYHK4YilnZxfRxmB09aN
# DATA R4e0g/uvv198/aT4emfv9Xcqr9+vvL779z679pWOTniPJzGiQV4JfA7BjFT4i6tiLwlfR9T6k/Fh8dsYjYo9D6u+uHkoGUTapDyP
# DATA kt0SNCahtMBYnzbRzESVq9vbtc27cVJMdbDSw40aVW5pJe4AnzL+vqBMs21IVK0lrZzGXFXas4Nv5mctGU7gGCaJiHt4ZMqmMIOJ
# DATA cVo3hW6VYGVqWaQOMQ1OKicUBvjNjpQsELxl8VnhV9lDY4qzPEJKaWL0jtzdIovPFXF26xyOGpUHm6vvwjCs3tmo+aksWLUlOTXT
# DATA TF87d81VoOg++r15B00vszkajhSsCAU92bN8AjxAIJDIbxAxM/g5h99gzAmltNtc392p3cupQhTWRmoUywyjGJ0AJv12iw8aZvkC
# DATA 9WEptmyjHLc+DIIPlECTeL9ovx/rIqqnqqocPG3k7KcdNJpqwMnuMQcD04saw0H12ywJ2wP/ojF5TE5vuQPi2fVlPrDoJ+oVfGwE
# DATA UltHHkEBmB9C128pR8DD0ll9RmuCfkdOMjjImMw1N/KL+EFGjYgGXuO64M57P6i9T7d89jyPxvkgOOr2+ykF3andW9+cuShEL+A2
# DATA 4ZZPgB5R6ah8o5vsaQFywXeju+pajF5loPz6Tu3u6tpe7a5ntKFBezA8UZdyEdspL+oLOP4AjwojTCtrzctdBQiVPMdaBi0+vdY5
# DATA V4g6fl9WAaCPT2Zq46r3RNXIiTELmjNK2lP105HOTsQczvRn8FR1SR36UauMVVF+QnWzdNQbHOT860qpUa/cXkF9ET2kn3LWHIKE
# DATA knj75nIEHcZVovgplWdoEwjExVYl0DsJVmeYWekdPvIYYjxt6w5+Z4w3upGwWYOKqBuvN/L5Kz8oH1qJ6w1pvBtkDYlzQ3LlI55r
# DATA e3qRLSpt10ndrzK2IcHnGHf7k2DBEehiZIhO5/8zsk/zdMRoqUSbJWTOeC4Cbvej/fB67q1K8BiNY/vhjfxbOYGEaTYM9JjG9Tw8
# DATA WMWHS9fzf2snhUZjTel+vuLW+USclbnPU6STR0DqT4mvPBUp72kUGPkUMZbe+iA4fYpbJirJMGb5adjqjZ92QoIOwM7UlxpU83rK
# DATA KKslxg8vNwyPN8qAvX9t3/fzzleh4agQoRLy3t9VvZVKaoBSjKfyO/E1lRAkEwuGiyEUkQFqM3JPuP2E/kTf8JZwdwdfYDZAG1Cs
# DATA 6WeEGVmFqwWF9MInemMt8n6Df7RPPddVMDahhopBkW1cqfBzb3VP8rnWZHwMS/wnpEoEQqlXqg0mrgMggGD0FCay284jje3vIibN
# DATA yN9fMso2N9V4Db7UAYXVrwHPemv/wCJOuL5bW9up7T3dXt3dfW9r5+5TyujyVLbN5luwbz6FB+7WNvfWVzeerm6v87XVB3vvbO2s
# DATA //0qZj7KxwuVynRn8vUf7Y/2+40bvn+5DkwXKur74f5u4/pbUOs0Uebp3+b9QqpwkNWM/YPg9PtGJ00IqLTfB75NA1nl5xCWB15v
# DATA yF8o40ap2LheWVzEoQsXv1dp3Kjwt8aN7yXG8HvZrX+8dLBfr5eLbzWu173iIvz7veJ/U9aixHsK0qt93Bq12hhgTcA8+hesJ3oS
# DATA FaTmRYyPGPsotwGTit6mxXRz2WMfR+vGt6re0vIbWSKrFujuynHRk7yYIUd9t8IxI7mXvL3jQCtsLdUdayrRc4Sx2smtooQwfCIP
# DATA 2lpqdfKDo7D6ytlxx6wbxjcQckQ1Fi+p72dyuO0hYu+4qR1RmuKnkoss8DtsBPdOJmP0PvY26BXCoC9gO/vAjsbUYPSeYCcB+Nka
# DATA M/C8N24dGab34SDsylE5ivZkkWendn9zdQ2zSu3Utrd21/e2dt7n3Lvj8Umrv6hRb4q6uXH7WSo2GtD5Yuw30qZuzmxG8Z3aRm11
# DATA t6ajPZVZT5xWcpHiyVe5lmCnKx2BVDI5QJfaRapx8UlU8dmi8gxa5Ll4S7t1NMl1o/ok7qV/ZjjBM05ZWH3ir7ZxH0K1CDpwYEAK
# DATA 4qM+7Hek+hsk0RYwOzqUW1wTA2EFBfJiG6/5jhhd/wFQYXH1SHJPR1NgniP8M37TcPwU752cdvIwUmagEDYKwuGgHwaJE6hcZ5lo
# DATA +dZt8STBI6aea9z+4HG0ikdPzDWBNPI2mgkWbBKVsQ3r/LWIejkPxcBSoD5SMYLq0ToipVZEyblYrfCEbP3iKxIj84f7HeDp6h/k
# DATA k62jWLTmyK6zM2odoq2lG1J5lL4y8dAQdnSV/tl6cp6OS14H7At6oVthX3JNGJJ6ksWbSspMmAKRe1SsQYEtl/7m34LhMUue0ol3
# DATA azu7IDVo5duIzt3jCbDu3ElriIiqUp4CPcdkXRFKUv80hy8hnS6tvLHy7Zu3V95gSwZehZ2IipynLTJ23KQbXq5cyMM6yK14RVod
# DATA XG4UNmu501QyLTbuY5fTp5s04aMUQGHR+EmAMC1nxM69Za1iwpVWqLozDcPuHuYaFKoS+d9YvRYiv5toZl+8Zl0y4FSGDKt4UlyK
# DATA UlEpTfz8wYP1u/IqiRf0dcaV9V8f1Hb30tsVwqWh6YbSVBHzJ7DrqF+SSFZDAVemeL+JA4TDCWzBwN2G37aJDPqcpXuaXSH+YHN3
# DATA 9e1ac3t17x3fatFsdk31cMKqmfTqi8ZMU1I0WAY0K18j7XEcDSt6Ph0QyyASXVSB1FRxS6ZRkf5eLzdiSj8OFiWznJmCW7+RZ76+
# DATA ur3d5KMUidUujC/0dK563BOBzzL1SVpRY/XNCKFAPYStcv1RVGsVjxCHiPD55PbKmdI0iIYh2SWlCCCYXM4DZADIChvhp1HvenM5
# DATA k4jur+/urm/eUwMguzJqKRDz9aTVLvWDR1Kchv8teOJ1W1Du16XwuAWSB0ljne4Rin55h+9YOt0XQHxnpWuFqz+LoXirgpCmcubC
# DATA zSfyGMgMGVJfaCIIiouxRgavK8BBdA+kUO1o5tB5hVDHxJEdOIlgAub8h4Pe5CRAR+C65SKovSPr9DqrougbJm/iEruHTuVKzlgC
# DATA 9KQwZ87jhBeUjESgieT6lXDARhYza+lagZJ041aNVRt5xc+DVLLcyDcMTY9ehjB7p0M8ePkH3b4J8ciAcMJs8hHgYyVZpbhXNzFO
# DATA AO4jqzpbcHkvmF4GuFXUVUMaruhNi96lqub9rQebe1jx2xvra3uOZGhSfMxwR7On9F6qVhel21uLQgQ2KlBDQnp300ta56dIS1Ke
# DATA 8iKuIPHpq7Bcij7t5CIIs9LtEByBOFlWyJx72bxPMnXvskCqCvF80sTKz7Mk4CsC7gadpmykRqJ5ZY/Op6JaSMB2bgrmKyoJ4IiP
# DATA hI3piL0c8xfSGyi3ToVuEcfCjQFSJAFvwy4qJkyMWx0AI8EvXvEOmd6NrnF0hatf5AjCEbH0kjk6eIt0HIlGIXgHVj3oF8UzYb8v
# DATA 1wiW1objnR3rwkW6UeTFoicBGwUJPo9PbSJ1ZIQtkITKKDB+hCGCZL+uMTT8YrE/eARfpDWXLmnEI5VagjoUEEAKSLCokx+fisBo
# DATA SC6GBggBcBHzrIcc61TnPQVeSJvam4ruMKaz1fHGiB3D22rQgi2bhlvrgFJFTJ14IH3jzEhDYImaSjZ9IQFTYWtyXQ5GFcVlRNKj
# DATA CfaaKZipazLisA8EptyYJa5Jw24ue9+t2gJQ1Vspf+e2xiw/jmwKohtlHOP9EUHskD4I3fP9Rv4vSG5SKRuSMpL20SSNVEXHZDeb
# DATA XVixzSY0oXfItmUzYhkultLJTj8SHXGiN8xzjq6ORC6qK+kIb5wjzDLj+55RWOthIO1OqCasYckqT96NxSdEIeusL+0k20wG7Wq8
# DATA 1XGLu6SMj3m7d1Vol0DPohCAXtoc4SSGf0/bzfkpYK2qNW74CYvwNrf2muubcBDfQG+wqGqlJuKS6778dsB0JJ6IhgUduoRglJoS
# DATA 3QDM8/D0eDGNO4fO9K6MU+qASQPLlJPwAciMEbsCTydlH/DUtCj9bTxkC4bEzwAlTuo3hhIMlKKI8/Vhb3kF04/g47O5brnVHfFB
# DATA TV1tOR+rov7R1MTDXNyDL0Pxsicg1rDsWRA6ttwQ9SI1fBEjuiZfluRSj4A8Y5GzpR4ljjCKzVt+15gQhx0LsIiYI1PcyQM/CBY3
# DATA 29xg0XUQ1ymkyz1DMktQph0HRGGOMGaTgA5gKuCRD3hG/JFXjN41AwnKqHh8Y7mcEqeC70jcG9VYVfGT4otRBQrdq+3sPNjesziT
# DATA bjL1DEph2HGQoCq6HYgUbiYWMAkPumImNZDu6nMH2cOOUDXjxwDGpwdIupumA6Ys4+JQglN4zs+M7SoZXi1MtH3c6ie5J+mMiQAI
# DATA 2YNNCKgwbrUZE8fJYdRN0pkajDMtmCtLrtu+iw4Cdx7svp/w/zx1BVKx93CymyVEvDwG8a37k8BcgdzvvGsyXKXcpT9pLp3pHTFc
# DATA ndmnk32UzUXfZGdDng7mzJqW9CZ32Z0tClXVwcXqfKFQlowjB8jsR6NWJ5hhb0/n8MRwnJwKukZKCHP8uaMgUQweNTvdkHDLLKil
# DATA REcwhFC1k9gFVsikddLqQ3EdtnkRsU7tx/bqvVrz/vq9HXIxoe6s71g8IXUN4M+UFcC3Xir9izf5zDvn9MVjqANdMdwp8TnJvbea
# DATA sfc6X45YJm3c+me6V9elRY4Yg1D1T+/YHBuWXUBs1/puxq51qfmffcfQjmxx+Ys3Cgyo4zD7aB4qJusxJrcSCduRvi4aFTMW0RiT
# DATA uN7NXpOOiO1Yfo1Uik1RpTAWYyZSoejUigTzhmCABoChCc1xZEnZbi0kvKdBDCPVFheobwj60v3WY1SCIQ3gA3H1HL10B5U/pJRL
# DATA rU9A6nBXicS+gkinmCkrGEn9eKHb8RWjhUsoOuj9xNIuWY4eLmLLzYlVZRHeFMEMjos7e00dQSTyUjUZ6rTgdvfUO8uMorrjwZFf
# DATA lJNPsfHk5u2zfXnQFdV1CRJOWeJWh2OBJioYCgFqbWEBJ9mSFeYUEK78RHgp1jz3JhbblPOVKQfM5DY2y9mRjf4JEAPUjwjTSxNB
# DATA rcvoHhhTS6mYttyMVJqPF9hsjwKJfiKJZDqz5Og8QkKJAv6M9YK5bcQNcbYFkaRuu13IUtwsoK6PQQ1BdYLfeYdAkhphSItGrd2q
# DATA OXzRzqXhvo0pNESNvPvYd8Wiqx79SH5VYxC1peGSQ65E4n0hyffKzxEvJL65Ng8thr0IT2bHKEeEq04bz4Ct9bWN9ahvyfSrvOMq
# DATA VSXh2qBPqN/ImE3yh5CCeS7TyqU1aSoX9PeGeyeMyUbXOemLWyY4RYcCHKBOt1813rxbe3fzwcYG3UG5QK0/zjelf7pEiDeWymW3
# DATA DJ6xrNe27m9v1PZo57eX9mz0EEHLKHkiypR+yTiq+SSc7qHJBN3kJAHyDBMwfYhUuDx8VyLIXIIVrfet7Zqsd6fAIZzJAPVoOPCA
# DATA ZlhjlrVlktBnZqrV3dg/joNWCsgI6QZvl+OJaygfQJO1m9JPVtfb6ycJvJ7QuYs4ZRdiD02LkhpWpxh7u6Ggo9uHFWxCI1pJt/JG
# DATA xiQC53Eq3bDGJMEhPk8HxCCPTwURQE8vaEELEc7sYDR4FGJyYtFaIPQMUsA46J2W3NwyTR2SeuBPvzmTlSVdcLPIw2GJgeEypr6S
# DATA 6UZirSKBrRfvlBm0yKjNV8umahBqPrtO6jJZEe3dKZnHaTIaSeQhvhOZBS8ZIppPK9apS75+XXJe+q2H0Hlyc6jol8S1XJxrdJMi
# DATA txt5MHmQ1bhm8FAchM2QsXhQzkyzX1udezDZVDxUjg3MGwlqYzszJXJsNnPdfj9wBeXSdYoTFbgDdpVWjtZxG67ggBJgeSEJQm4B
# DATA 5sRBcnBAbzjkFqfoHkfYjtoZw9mG2nKEKYVjw8KFcX/zTj5TK+YU2FUeMqwYRK31rRQtkz1+mbubNcwW1TkalTzdyFw+Jp8BKqvg
# DATA XW+6A1yjqi7dYql/g86X1oamtfTK1yF59uY7TXLlLxgn8SiWghxNCqlH8/m1zilql2ns1W3InqbLtTQUL6TPnNPSntXA1MZNQxec
# DATA qwPasYlnHd151GzHGfZsVaH7xGbtvdpOrKLXvK1+oDF1SdD48QA62uohPw4nh4fddpccuzCuT8UoYogWah1wVFpwgDvuhgRqkwhF
# DATA N4G6TI4n6Aoaj1LBLFRm52FC7BZMVx1doAyUy3ylSFek9EZqCPiLI3tlI3zNeGZIKTdD6a49X/nA5FKkK9fXSNse92cV1uPu01yK
# DATA +FRJ5JtRv6epuhMqebcDTCFVDT9VZ//NqOZNrfxfigp+Jhn3KhXyU5yXMODceuhSavhMAr4q5buhd59H4x7XW6ft6C/sdzYTNnmG
# DATA zrrbPxy4NPMSVpoFFx5FIjEC0MxlhMeX1HPjfdOE4NKuTyG5/JUozqkVoj2fTsJXrDhvum30hlqTqeyoMqM6jjRNkYpdhizoMPMV
# DATA tTq1xt6VyA0MSb9qjLR7/+YotXjWaANEYGtrT+JxLC4aPSGC2Pe37lj7pIlDQEHMzfXNt7eab8MCl/KQsvOp8SSOAmqbezvvmyUQ
# DATA YcccuGLTxHs6TlKUw2HhUud/e33aORgM4ot6buaKOP+3KHEP5/b59OITysv1If60PBhSzkUqJWA1A2ZiJsUzK7dBAMD2FVVYekxX
# DATA rgtvUERhFaMKZwn5maqxJloWdTV9d+2130lTVUcgA5Epkegn5WnyTO9EMAF15gV6gbiRkLQ7NL/uLhzNc6xoPbz2rkpME03TE/31
# DATA rCKJbZ6oAs90iAe8IvfcC/hsv39NhwCkt8OVVdrYmBId8r4bHYWc9eYv5eqjFiYekHZqq3ff9y/TlEsdy+Y4nlkO9kIFenIiVvmt
# DATA ajR7czo6mSANjtqJTSWibFAo0HemnYzmrv417w5rlbE+TrFLuPgnrVM8blHGpZbXDxA3fshZYqI8S6WFqdpZTc8yoFU3XSkVjXpK
# DATA kYEWdqm4dDb4krjzbyJmbOVYw6xyFczViXnmPjv/8uKXHu+kqtWcDmY2vhudYA5aIFkVjK3LsGIqgEc3NzaNg98UW06l5/hyxSXk
# DATA nvZLEbRgczTvr+/eX91be8d/kVmWxEo4yf96/ttkttQ/UqZUTKf3c04h6E+Z1KnHtVlMntNEvZjZNVvIcxedqvPheh3ZTpJOP9mp
# DATA iPJTi49nz4nlfzDS6MQdNqen08n2L3BbBuxEIxgSZ+Yocrb6LEVcnsOwk6mNeqlG8NcIJU2OHowhg0GEHmnYO97BKceYDgfd/rjk
# DATA bcMgYCCxt02KlsV+MMZDtqNUUTZgdOqgQOcbqMNrD4aY10wrOjvd1lF/EI67bVRhjge8v7RVWvS5TPYp9vimCWE/uxrUWA5TTV9z
# DATA 86IE+bNvs9TMOBzRpjRTeH0KT/sqlbGppGULV0nPCVomxTVPCgXg776/u1e739xeXfsBZkxRnk1wENx+sOdn9dSZN9VYA2u082zb
# DATA y6DfYQKIGenfuJVVE43/tIytxjalErbKqdepsJpLvScDFw94iyVCn88/ZCYJCo9TSvF+0g1hEI5s8J+ESin1aZ0Dpt99vEv4izkz
# DATA x2Vp75hTIh7d7z5e7xesBJgleol4Fb+q0gMQMEBzTK+GpnIGtYFo7ZEVF3dxgd2gz9HgBa/V6ch6DydDaBVFgugX8453EL1FTqe5
# DATA WwmbpKNsDR8Fbc9RzL20hYdE8ofm3GlF82beAWaHJ1AmFCOqzoR51VqEjEgw7J2qWDJYAgXCEIu9dTDonNq4GvSQPnE67BFBv9NU
# DATA uII5fCrtIQZTzPlrDKFZREAMlRFTASo6lJSOAiyIxQJBLBLagj9r1RtB/2isJG40ZmG/4/6m9Hr0dujq/SMyTLOIQWVYQ35Mk5dG
# DATA f2ZgfDZRmXAAkXjGuA2zIM+7TNEEK4CiaWsUNAUtgFojvRV8BBOUmCES4J87BEhMJx+qIZ9u2aV9jyhvpXwTBSxl3vLf3tq5s373
# DATA bm3TP5tBxatOFyobKfpo3qvtsbct3WE1M+aLZTnCz7aHRw1bRkwzHjfxhXOHyM5QP6cjCFHwyfmLqOTm0P7FVD/brNZoLTYWzVbY
# DATA WJmNq23pUZDaUIXOmNIefrOh4J0Ws3HBGT8RT4fLLy+CLH1MqXpCP+dv5fmHkQlOonkv3xoOJX/B2i13ZI6CnYv2HZHHM7Zse2v3
# DATA RZvWI46sKcxgQk1M4Jjk3PVGJolJeYwtrcM8Ld62N2r1w8NgVKzh5saxgqJ+k7eBMkrdEJhjdxyp5sred/HUkoueIZWlDZJ7ZcQs
# DATA OJ8GAiLPHu07BPsZa0s+0x3DEGGxZIUIR+MzFrzQb6ELBOGdUFy84JLtBA+7pF44+6aXrIswqaUvSJy0+BZbbY6n/OukyuVbt/+K
# DATA iBJnzIHhEIWGvQzajDi1xP9jg+qqLQ0Wo61YIXUpaldjdrJfnmtvSCVyFgtfkfd/BPK21bjfEGGbNJ2wzVwFHafL1NbhYMU6HKDp
# DATA 7u2tB5t344eDl6oWtRr0Hfbg0QogXE6mbynre1Zgn8pSI0V9mkOXFJ9HYyw6gybIgwgPZ50xzfvIE9wPsFpFOebwNCW95vEpjQho
# DATA vKKh+oiEjetuLMDYyy5rZ/w+/cxND1sWTMHdrbUf1EwqN8uzPEbJ48ZUPo2VAopddApKDcOY6/RQxVmsArq+bTomiKKK/jQPB5Qs
# DATA iBKsdtEfXpJrIh01myjFNJu+yno8CsmRA9YffS+tjo4mCGO4TXd0pi20kDZBBmo3m3njTcxP1mzJK7nIxZGcN7dJAy5Aw/QLzmeD
# DATA 4XhRu2wqy42zMHOnbR8PENm4yiDHJB5GTpMxZAOCSVdBpzAURYWESc+q0JJGZjdUHGTmQ6w8z7+Zdr/XOgh6GffJzJZdBXqDphdA
# DATA atOM+4Lem/GE4FJKIySYVZ6lP/i00j9hqCptpsGkKzbWchxdcpfcfGuP8Sy+M+F8N+xWwmtbw1ZjrhCklSipAlRUskNhozighTTz
# DATA Br3F5g36CgMm32h25DvNhHynUVfo6O56mYJMnEkE3o9XJcFP9F1GWn7JqGZXkqBOC9LNhnCNVz1TBbIiomIJWzMqK18ih1U1bNmF
# DATA mWsso8QIf4Iu0s9uJ5obFyo966XjReUX/ubV59Xn1efV59Xn1efV59Xn1efV59Xn1efV59Xn1efV59Xn1Wfez/8DpziWJgDYDgA=
# END_REMNACUST_HELPERS_V1
REMNACUST_INSTALLER_PAYLOAD_V1
if [[ $EUID == 0 ]]; then
    bash "$directory/installer.sh" "$@"
else
    sudo bash "$directory/installer.sh" "$@"
fi
