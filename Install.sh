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
HELPER_BUNDLE_SHA256='1cc2a90936fbb8c5292385b975e496ea44d6e3e194166917d8f59c31404ad020'
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
# DATA Zg2Ex4Z3533vD/8+yP43Cvi/wf3fXdDO8vY/qCJ/sP//bev/foa1IoKprw5dzCXhTcr/YumgZDJZksZR9dPRiGqkMT35YYr3CN5X
# DATA 95ev51Tf4vl8mqovlz9LZuozXnQzTobqa5L+7sWBr5aLZKzrAwdz9FPor/FkZn/nksGYn3Cyu3eGt14UOcxK3vPj47P9E0zOKH0z
# DATA /b5/sv/iaHfv1enZ4Iv9w5f7J6eDLxvfQLP9o2fU5vs+fBqsa7V7tPfF8QndaE6uWjwhNh9ulD+dVP6cWw4+e3X07HB/cPrFLrDZ
# DATA nZJ9C0jpBxsV7/nB4f4ppqOU8hu8xHmeoqriN9stkXeaF/3mqAn25cUlY7HhO9qQpdsjx+pTTpbolpbtrVz4tuXlDJTTc1cgnFkj
# DATA r9cBV55qdYzQUuAowd8d65gmZElovtNyxSjRExIDzvlumVL4u/jJ8KP2WJUq3ovdnwxOdr/C0vJdt4gGPcIFh2fN3KPcybKojIut
# DATA 6hpiZe4oDgGOslMRQyJD9FxdcTLky02qROC6TJ3cVmJ1Ku/Ktq3JEV9qgBnV6rJceV+k9+B1rG5b3vbWFqUrUa0p9Z/yp9ub1ukH
# DATA /H5e27ywf6p8XPm0pGKk955xkPsLhHkJVLo4E+brD/CGhFhd5yGJmhj2WdDVkeXSpjpEQ7kXo4SPiC2WM9i8WGMcQysY4ZXSi1iP
# DATA KMkAHVjPkSvHlBtcp6ji3Vd9QJ3dNNCo0p21ku7aWUeGAe+kSfjo2Nx+BW/9RVwP03RcNp3Cr9ZMdKlsIBXadIJOlgg7NoHxY7WK
# DATA vENDTGkqM4+s+D/yG/ctxjN9M58sxyhNF/HcnFESXotFR6ZOmI2+VqW9L+fJZaoyeL7sIbetxdOIs3eALT+YY3xgbmcqglAtFInD
# DATA ZCoPz7c38VQP9n/BIOHzohLKCFYZH9pZRSgynu2e7folqaBobwx8uLe798W+b8sB2iDqe6t5R3sB+61UHnOy/tU0fjPje0OcWfpy
# DATA VZFZD5wXiyxdKYeJgDIL713rF3Iho9ExZKxgGoIC4fIjXs45Xh4+KzMb8j9hfiT0qSB2aFTezkFokXLlvC5LUh5ulDYq540LzRap
# DATA OJRmdzqh5Z4BQKBAN8VieoPgrZeAO3fb+BmGq9q7ytRJDlT1lEnwJpksJzuKyRsO+WDBzfzR8lX8f8HYptMOWDEMc1KW42BONR3M
# DATA GX/r0DlSIw+QzmDdS0B8FT/IsFkcTMxYdAXejvxMpxDKMhPos+HQDgkH4Ary/BHwUq2zRZr6Y8y0cakkL+v0dQtcJ6M8D6xLFnB4
# DATA /AFGbzV73a3H4Eo6WhlfZmydc8Oe9XHnWMQk7om3JbZi6Q5tETZVrOJvwnAlXavjjq4rhVfP1VsXD+6rV9NsOZtRNqraUQruUuVf
# DATA X8IydGomF99e1hZD5Wi3ajQHWR80JAstunDcrfbCHTPWnZI9VukpeqoqT8l+w7UlhVufKuSSKOpop3xDGrsfzLxcYSuqVPHcVDml
# DATA AvCpnJW0sWIk4uqZE6KbF7DG8NPs9i9Bw6/8pSidf8ka5zegclbk6OgjxKGDXQSKauasyFoLi1ysQiMRUUZqi2wOvQPIucQ74GG6
# DATA wB5M9ZgPhVvlzLpwY3JSmTtmWDAnO5NzhwsFV93/oe80QjpQDPsD4cBCeWY3ZMuJO7yjAzIBqLodSGFiJTyCjzFtreOiuBUsWcSV
# DATA 4iWhDNhaVcqSSdlERw6+xdXfZhFGp+d1dSY+raOLnNHZcjnA87bY7JHLxiTtcbVKj30GyOHwehvfKUtD7qsri5JIk7ArFwn7dnrR
# DATA FX/ZaiFJgXWKXDWD+DO3yCsI1LyIX93PB1yHC+LJYQh+lHIRNdwHJUfECKv5aEcLHI2J+88zr2p7fLH4Gtbj9LzKgvTll7Y4ptZ8
# DATA ZKWyUm9e7r9EyF16t5C70qa4UtR6kldXM07wvlLAnXXR6Rri19ftrZANsC9znkOmfg+RmeLR+qWC5NuVDnATWa/AJlC+qCprLJWq
# DATA vUGtpjR6JV8cQ0ohGhjW1D8zR7plJXGPfvyxzFzBsI1j3K0uvz6H6ILuHL+TlGlOr6fFLlu0ota6km+vqsB1EVTR+ifDOIpyWr+l
# DATA VOfsRjkznrMd8xX47jEiq6C/go1gW3RiDOOgETn4SnzPJZpb573tiwKD0DECaRusN/kc5UgNI8qFfEXm311XXHW90FG4K5A+P0vk
# DATA JD57amvDblusIhmyqsnVytcl+wAduLXP4T94fJn2fTr86U6S1j7DdT44LnPflULLAUgqZzgo11fecBDN/REyb9+dZrYi9pQKKGeW
# DATA aRbiGmZDp2ASODyfLtgpzbfZDJIMbAPLBDFMriBVcRCoWH4sr7BBeUC6YushrnYGcwBxdZtfxCzniOBOSURy94UuB34GZqNU+tUv
# DATA 1qR0r/YymidK9DL2sMbIk5IZp6Yrj3zzTf7nx3kg8JrxFRIVPJbyJ11QuFgjXFgoj9+Qr55mxk0qTFnqho6bgTbrdkSrmqWzsuJz
# DATA lXXcXb/msHl1VdPqc61STaN4XiRTwgCElF0N7yGRki4XsyWdGzCEWXmAhvkdRbo3ayi3UAbICceHREHeqzUdpXzQiIA5C+YH8Et5
# DATA VZ/DhkRvVf6IEKqPGLHwdxxtoeqDIGi34U/RsRzM7qclx/erNoJc6WLxbc3p+LcyMTK0yuZxlpUZb7iBSeXGigoE1U5dV9QWocGC
# DATA Qldtw0V9yD570HVHvXyoVUMv+Tl7TMD8hCNR7DmkgijYuCZTV64v7WLLvykizogpvJGXUXmeAH2/2ab/Iteu1y9UN2y/0AM8AhVM
# DATA L2P0jtuSrIovuPUkLWkOHSkoMIim9DSuX85RLrFTqL29l9Z5q7WjWpl25pYFXbBCeyif6E81dCBwgQ3WXyqanVDsTuwf5+1SgQan
# DATA yCRnwGh3Cuq7uqcv909OD46P1MBc2aPGPtHHuPqkVykkxtEM9VuBWaHlYs6os6y5DzLhXEzw3UGPMeIewwptN7H9VJEI3qxNlTbU
# DATA eSanCuiaBXYIh8jQlFVxVv27xhQ5nAQxsn6PJRPb3tWuSEyoMd7IbdVp3i25vdbUdWse60LDgo+3pZUONBMXW2/b4e139wogx/VV
# DATA ubuzNl7Zuu0BJ1mldzDEqO51QvYzXew09aXuiudJOeQVF4Ba/0e6+C13ge5Ze/stm4RPbVsGkPXsftZRcV4jONWNkNRabRH2F4js
# DATA GDBbZCmmfDaGV4lvYQ1/UuRtGZuqc42mR5i/dCMblzmalw1U1h1vFGf+5k29zpEu02ZNHaBHikBzUk1dnKT7ZRP4nqu/RFMC+7jT
# DATA kdN9ysA13QDirHX3HiqMs3IC3DQuCumsrb/4aDRcxtNYXXbj5W5dXfU56IPU97obVPlJ19OgzgDqc3/2YcCCM4BcguslqFjx/JoL
# DATA bUUBZoREFtA1XyrF+ZQ4ksEuvZWrbqgeZq43SVLCHfbUlxwGuoIB4AVdF5ZqREU0FyaHyZBIraB8UX6ty7ZP8P76caLvrSeFGHON
# DATA AuIwVA5MJSEhZeJnDMuPkjc7pZoYeJsYBUnmO9YGqqynrN/RmaNrjhs4RR45TEjx7ce8p5047bbbXjc11f7Vlru3dEKa6bP3qofi
# DATA oh1Cm0KaaPfE+KHwpmZ6UqPMNOU0ekvfavv7Pzk4hS0h30CE7794efb13T0lVlaefN/fndJdS1bwG69vmi2H4yS7om2Qoaw3e0Dd
# DATA L3qVZAXdzeZpCFYKHsan8iEL2DLxEpgCX+nnq+CSSuzA4g+Splc0+9+FGd3PkIBS1HH3At7E9VAI90UXRP/rsqrC+hg4eU2H6wsk
# DATA OM3yaDJP5PYKc4/KRzYnsX5XyNVvIj07lWXM9n80zsWHorx7QBrIQiXTrqASDCdH1uaTxTy2NpPta3BVj7WeDCES2vDO644H105T
# DATA ohd0uB5My8rvpfBAOlO0ZpcOQOuA6qlhjKBU1XrXAwUD8jUM7m1MWHp0awn+Pro50tSHwcMLstr8gdIGqpqBRiRViyAEGrIka0vX
# DATA HRA1elz8KuPcetcx5lc6sQsecMkCpfVSU0kTsgw0XfWA9VX+YmnEDBKrxZWHC2Ewbf7/5IxBPvX2u8//bzSarcZK/n+9+4f8/+/i
# DATA 38bGxkmMFar8bDmjC2viyKqMzDncUss6QKcAJoRG0DhEZWO0HNt3096T7k/p+h+QpL8cij6jf7nVH9Hn6nkn+y+PTw/Ojk8OKNOd
# DATA DyRJCRj0N1xehfNakj4Zp4sFmPRPzAW2ukzMyk/5a5vW97FaWcbpr+DmFe6cS9PcD5+qXpP7BXq48/g2RJqwNderxWKWbT95cgl6
# DATA wnKIHmvd7UlujnfOJA04j+qC4bjzDl7sfo61AXNnFMTHs31e3+wHmyNOzKl4z/Z3nx0eHGF+OsVXVRBklmYJVTrSNxqYzLzSH5ec
# DATA K99WIrXmImrJZf7jEgVmVZHyfKu5NNvWzRQYQP3BeIDlsstM7pjqnS4oG2L1FhZdXse6c4heQ3D5fcvVr1OoMUKDD7mY40HEtyjm
# DATA YwIKr1ZkwHRBKqLVI98rwHA+cEuNcxtq2QLkBBbhLLjMTHXPT1aePyNL1zQxFXtv0Od4Dp1LibORe0sfl0i0V5kqu9kb91yj9+LC
# DATA RgZ0nS8ifHlJxcyku4SdrfnuLTjogBITkrk/8C7nJyDehyoxmltkDeBIdBWuBbofjLOUKYUsq0xcPfB7EmRxVsv1unudgp0TZK+x
# DATA 52dUVA89EtwBnqmi96Aj/6eYecu/R9hxPB65nRXjuHBunBju4kOeFmDvoqBolKrMaBEdpozjCY8kXNSQfaMbFa8yrlRsj89Yx7TU
# DATA 2m+vuQ3Toq1HXrKRzi8pfGkuB6lxJ3Id6bo7NGHawiwtIiu6N3PtzM/Nlws3HsUvqUMwtMDlj1GNrJKgG7AymcuOQ72R701o1RFO
# DATA zRade731r5sk52qTFBCLnvaydY2M6uqHO3497wo94+KQyugm1iT6HcjqIKI0FFCPQf+NzG0s5DrYseRubb6cls+lJCSWucPpXVQ5
# DATA iUrcomEwW+AVyjJd/hFjDeojg7IzAYW5Va8awCtOHocaMVtE0JoyWdqPT2WR/QVLAmsMz9DFE0eZnvM4mSQLN7vRytHOjw0gWSvI
# DATA S+K2kVUfIncG64KzL9XddXxjFV/T6QQ3pRnHNs10bpN4HPFhIqznD29u8/scNZWxsJrfgGWLMooTKgAvpFdSlQoDLk2oS4E7SUZq
# DATA qVlirFzfdjlPl3QDgZoZDGFfmqde1LdPy9hgfGHmYP4Klrdva0R7d5ia+zF17oLjrIju3b0ysGwVL+QqmVKY9nUczwQ4vD4A2Lba
# DATA N/SbpXHkNxFitllfwYWDYkWc1pCWdSopgZmb7E+eW+sFJ/J2Xy607o9Z7YMR/pdS0d+qS666QE6SsJfNvm81v3KcPKkKd9sJxRqW
# DATA 9dfgujcx24ncGFIuUmDwqBtrPRPRk0sV6wpyLTMQAFzX7Qchj3Jga1JUAxia1L27nJkS1ooO7BVIu5Xex8W7TdUKXQDnDHN7z2V4
# DATA 1pB0HA6t3vtYnM70EnMM5z5Ml1Oy1RxfnjRwtNOCjW2Gt3RVPq6LN7aBILwHpbyZ1+JTaTM7kpUzcrTWqqMfTj9Y/Vae1/yu/tGO
# DATA 3vTbRUUtT7TMFBQB48HNE22vF47sy9wByxNZfzyfu6rGENq9vjeg5yrrBVz8wWvEv+9r8TaC9xFlm+jTZ4sjiscxWphPgaf4VMa2
# DATA qtjhDIiQku+k+rurVa6s7nxClWzNXfY57ZCX9JMdv/G4MJ+lR5zqj0WBP1keVlPMmsisw3Q55gvo0I09vlUqdLJYtzjc36i0h4sK
# DATA IL8V2O9s/4Y2aIUYnur6u3TvuGKwOUopVb6Nc/qDy9ja5tGHlMRl2YORQb7MaEfZl2vaI6u1CtyyAmy9riy9B7zBSlK7hWXFqapu
# DATA O6MvJLP/g7lX/334f7Pfk+P3cfVfmr1Gy/X/1nud3h/qv35X/t8vJaqq8wGF78lFXux0FR8JqluLVNjzff7eXN2We92/Vf8lWJEv
# DATA 0yx5s8YbbPl+pV6LXX+CDzqT0i1nudg7s5MvQ2ElRvO9a6Sn33+QmRKTrpbT1+TfWwBHHweTYRRsO0cULFu1gjUy8hFahkipsdSf
# DATA e+SInxdUyFAhbw5VLYJL4KYZWG5KdZPLm2k+JkpmpbNbNgo1eKIKs/BlIKtmyhgWt/A9zd032cWyvgsrm1Wu1uQkQ64IQCcInMdC
# DATA efwc5nifMvzuv737Jdf2VoW8/wH+/Pb9z9//9bt/FsrcfPebd3+PV9i/+ycsBK4reQj8mXXQL3cFtVz+aZ+pM8/kfOojyszfPTgD
# DATA qjUuM6DS41iA/DcPzIASp0m3fhuclyit+2LbD4hIAyRQJg2eE382FwkFshR0BSffJLSc4QKDamOu6rNEuORETy3EraYHzRJ0UCLN
# DATA nDM+3HvKcRT+mVwpgjvH18sBW4JNnwanC2WSqZ0Fnc7tlnijQ7KwGsoPD54FfPd/KLxyPXfC+m/e/w2RFFZyh09Y/v3931BN+Pf/
# DATA BR7/I5Wf/2d46V/4yGBBAX0hFgtEOoaAdgwwN3WnLBNQMIm6bSScYD6BD3cPwvzfsPD8b5DI3/09UA3C8hsui49l6YFSrML0WO/+
# DATA 3T/DVH4O3/92LbxEMgBh1UQvCPbzHNwXxRlhct3ZyApSvdWj3G2+hU18twnW1PLN5lvs8K4GnLt2+bNSLh1rphwwo3sCYlbP228Z
# DATA Sl3470INxsOUVmww43Cmi/NoCdTJJOshm0LO+d7HZFna3AgWApbhV+/+5f3fFeziX6x6qu+5c/2R6PhjibiV+Gr2/Il4Mz194Sa7
# DATA Xz50asxof/HuH+HLL9//tY9/8AOQGczuXp71+GMvLsSmCgDellZcAUDFG9d2Qh9VtO2DZw1b6u982mu/pony7RD8M8z95+/+Bf7v
# DATA F49Ya2LFdLkL8W+CjVMylawx9jCmetJ+KIjIvmWefr5h4jywAZ6I+Pz/2HvX7jbS80DQn/krSvJuClAD4FVSNyjIYUtsN8cSpSEp
# DATA u9sUg1MEimRZIICgAF6a5jlOnGwmJ95JMrsfZvec2dmc3a97jtNxJ47tts+ZX6D+C/NL9rm913oLACV1e3bHnVhEVb33y3O/5Ivd
# DATA wXkfIfoiXYnFwmWg6rwyh6PBOTB0bVWlPRn1BJzyEN7Tt8SqxdQJl1OrjwCG1rnMIXs+QEwY8RcCiH/y+p/h99+//jKCFf6C0o/8
# DATA grKA4En8zetfRt/Nxh9PDn0H7nIpqzUH9nGliFxVO4IDFdnnzxTBQQVTu3Nn9Y3uixwGnMBPphwSIQEVQaLcVWBPO+Mi2eck9EGQ
# DATA V236FN8UmnHBym+ljVqn4KPALP8zIcRfyCZxThXJgRLBRvEdgTsTUasADyNu1XWlUMPdt0mvA0tTZ8SZygm7gJn28VlS4MoFw4Rv
# DATA lQI9tK9ooQOau6KckDiRg0uo4cDZj6s7d+ij4xUjA9FUCWVgJcJDf1OEiOcPY48dCjPqjfHSNdXJC15J7IKOZNM9oCqwBenjJDtU
# DATA hf8IBJSD0SOlKudWhI+KfJque9Wui1YdZwYchYEXz/lwIPlBdbVBLuCCqIF46tn6uyIJA/DVvjMOrGDaDIojFYfnkVP+/NSKTUaz
# DATA mqFIdqhOmZNDd87VCkoNC80UqdLArP8DjfrPYCJ/i+QD0HdF0hNefQ5g5aeEh37pLQmSr1Drq7+yriK+dFgjgjc67GJ2dNkWP1kJ
# DATA NGafmSzAWluzmieKye7HG3UoFIJ7FuH9Oewkg3YA8nGZ4zIPMB41gX58x272pHuhGEST08op+7rrzKxWuffLcEH5KX79eXDyMG/c
# DATA q39HdMVvIsy0hSATXvz29b9adAPCqNzR0s7p0C+kuSNTqVie8UVUiYbmWd5ODvNBbzIWY/S40SATLPqKgS7zEl9+hUMrOoQAuQVY
# DATA cQJUUIH5CTBgaIiIhNMB6yXk5+/o+P8sCi7sF3FwXmoG+VxdI277HJEY5h+Dq/TXmAGNr9ONOqceUeLu+bijdpFNQEKhCWItk/Dy
# DATA tAo5o2oPRsVTXqiswjYErSjKVx6AhtPQDOJWlXWU4RUZaPHeqdJFOVCOQRh9kzQotC8gh9mzg4MbXD4CMJpOQWj4C0QOr/8JL5oF
# DATA QTXM/RI5GrqWioQpZWgYwRF0LIszYU3MpNMu7KndUHBfS9p58+0VfuYvYNb/xAj2q/8Jfv9yxk6bkE7WkO0oGspw0+IKPPGrchGz
# DATA xZwWVlG82uw9/o+4rciTwbb+BUtm+NK+Abahudk0lCX3NC7KjBxd9Cka8Yr8RW21jUO/HT3qAcWWdYwKFyXYOZkacl+CZNeNKUfX
# DATA KaVpehEPM6nb6w3OWQboL1xNLaXm9g+03auYxy4fXDuWCGrs5kbqV3TgyNZCGAXpeQ5jLMrK+E902/4Fb1fZ1VOEGtpxtJyeFwr7
# DATA cuWT0GwMsuEQn0AlDHL97VkuFDpdGvVW3aHr8LbmyVnarbBw393R27dvP8IR0d7APZ8kPYL0XeFTxEq+r3Qb45MEJRbi3cYGnga6
# DATA ovLExQk6+JTkejXxiIq0AF1/ZWJRHupFTUOiFP14SqwXQ1UUPv+BqtDGX7js77Xs0EhTqQ4VpYseyErFEJwMwN9/SyGDyUdq37p/
# DATA plyoKJGEKzeHgKqMYLlJgKhSVFRq3YJqImvHUVfgUjHFdsxtMeTGlDBPfuJ4t0cT9zsWqikSX2k+mvvNFRISVOLD3uCQEyEw61Ni
# DATA v8MIcs6wU95K3BRxtmYhTpdWKQTHkkYXwgQmHlpFxmnUIC9uTKr9Xsg0n2Bh/t2fgiADo7fUPvJslD11EuV0yE2u4gwC5QbEyTeb
# DATA wZsthxwvWiV5pJtCAkyWKnLENseKMCY8+y7da8fJ8XSLJ60Qna89I2OPfx+5yF1x27SSyopvvmmRqHPewsqy9U3ToCuHX67P0ubA
# DATA IbEkzrxJrv0BN8Gq7aBVtRLzWlvG8f/QdVi/K+Rjl1HhVdGDaoaDo/gp1AtC9XAydjZHtCISiVh/SnN+jnZ5to+DMid2+1PCcn/h
# DATA lHgysG4ho1V/ZdTtLSIXT4xIFfF0aYhUwL1+2wwDSlsWUpxNPLN+43CCUVtKms/T0nYUp+avjGZh1cIUmg7ls1chbGp2QEO2bS0J
# DATA KCLolfqkG1UcKR8UjIpE9aszbI8ZGe1e5sDRbF4Af7f8hhaTTjaj34f93/LS8r17dz3/76U1KP4H+79vxv5vb5T0c76UwNByDixA
# DATA ZOi9lIuHBkoT0hFwsMbZG+AUUs6DyZjLUlwRKIIW70kvnz/1W2cwvHz7pG7ZMQxeP42T8fye5CrV26iHJDdHnnHfoRE2amZpPPKO
# DATA ZhSZciRmqeGvSZ9+uynk8CJzXpY+IMoxuoXhZScuuk2yNKC1TDQYCRsDoFpNlVO2WbPysp0h6KEfem49WcBw7rZIL/8pwADlaQHY
# DATA G3cHaMkOCq+ipxo8MM1r4KCRiWxE3Sw57g+AsO6wzANoZwo7Mx5E+cngXB8UAnJ0UIianchI2P2NTozovqEya57oUy0aDPl0Oh6V
# DATA EsCRlpBzfNm8jEqC44ofuE7LmH82ONOQ/jg1ypy/GvNIFdBa5M/EeuRfUZHnpjpRM+NsCDOT9xRH8H8Ds/CvKGErdEQqQDRTcc3a
# DATA gml9VDohFe6IhlMpjkcvE14xiijZLsgxVt5u1FP1Y0Y/imYVLM/+0je7AHbs9e9c4wocsw4VCxzYuJ1QAAvbalguhM7LZx8yk7yv
# DATA jYezYsyHa5HxzJA4x9YCsWkGVKaQ5sm4sdveevrs8WaFIx2P2/jN2MxiwT+KlgaAFstD06NRm9QG0IKc94B42xSe5jkx/ztxqT+H
# DATA dQSWlPnOX5GNzW9RhvQ71C/jtgAb+mtY2QJP/puvfsr6d+S+/4XtEElh/+uv/n3sBoJsy1oLqyqr7RhZxPgqbprziOFA2ZOlGXH4
# DATA 55jkqvIY/RiXZ3mZEjSeAa+FYl1ZDXhBLCaHtFBv4dlPAhIeV9PIUmFB8w5cgUwGRXRdf4x+816A7AnKVCxT2RTekLS3IuXDobAl
# DATA qwCekaMBitUV0MkFxBXoR+rIFSDKedp9sv099zxp2akusrP53WIR/fXx1s6Ur7vPHnntl0pc5weQeOwIKv0cD92v7CPJOnLrUIYN
# DATA CaeMj6GX/Ypv1f37rOAovTw3mNg/wHln4c4/0pS+iL76CwZqaJI7fUJwncj6+5/FflctBFYCSEf6ZhQg/QoteOEVm7xVrA7uLQEB
# DATA 4fXyywjzd2gjj2Q47F22XWjHf9CrjBh5B50qJoWKNEvyhhAdMUAZ0iBnTQOX3+d7fFDD98/aO4+fbT/5FO4qPcHx2ny092xHv9h+
# DATA 9tGzJ0+e/UCCqdpMqNwPKHZEt8P06WgZK86dt646SSL1oAREHNQi9Yahw4FzwosAWWm8dEMCkqyGGCiF00zdFOb+kq0EydTn12Ju
# DATA gKcCAbDYOiHo5eIWDeGY1dKOhqUXBXgXWlVcco7NZ76a6aoF4PgT1Bdb9PvrsRCMqwiNd3pAXTo9iw+PZinEXtGSfCBB2866dhD3
# DATA gndBUa5mnSZWLHI6YBa9pF3pRtp2VtL4qmMfSZ/MubwdlgggEp5ZaVoXSd7HWoSaotZZPTGtaJVTKhlvCjcoua5SmGSO4aArMgcM
# DATA QBuwGXEouuAs2LDKGa0gYW9UMODQsKyZLBSahk+FtuGd3bizmerOeaLTOSia/wAQ8h+JAiTTQdU3VlcEY/GUVG36znAc/hxpnc0g
# DATA zUqLHha9aXBpCmuoXYiwBB+qSV/Feu3GGgKlngcSK1P04zz0HBBlBCW+ZG1EBIgJdQi/ZgNqozYhrEKm+/9EBoZkS0ikN/mSFEnm
# DATA Go+whsaw8ivGKM1Md9Gb/RjlBbvyUpulSszl9gmwhYqL097ACCpcrGNZakthWPtqgQamb/QS+GyM2iF8N1ciLVpzkXPQ8Bt2OlKW
# DATA 9Mj4uJwiNNDAIZL+EZadhzilX6kzgVVQWmp8HgKzfD4YdfUzcBKzd+7vjD/Fn9nCE1fVRYjjS9xRIAf+nC3gGUH8hDDCbyLaSCBE
# DATA xG8JSfWv/opUTv9azoDqQGZGZFGp4NjJV09tU02mh2cBf/3pJMVIr/jzaJQcn5o0Kk5opLKtkGhLKhYbFBCrFBXphhwk22n/rIIi
# DATA WUnebYfXeZVeylvddMgrLRnD4NEzbRT/SeU7zfQCd2Q/ejk+eK/6HTwHxtUGWhTvGfx8p9W48z/ENhjFdNkpCrkr0irHOEIqqvHU
# DATA g6v4gYPiYZIAXZ5dRqN2E4ePMKSlj6Jq7KiXHOctanKKPkHaxz8qE7JKhEzZVd4rdiCfnFC7UF0WfDgaXFyy+JvH4VzSWvQq63db
# DATA cSfpdi9jI3fRa1v5zoNbVlrRRv2g6i4uN8frW/lOoaxoOFHWiBZNRI8KralhSMVP4N4f9HsDCl/NFRfcWF5IQUz6Zhv6oX2Q6ckW
# DATA 6MXfso3C1KjULzJsx5YfWgmH3IhgcmRw1dj18TjrOzbv6tLJCcFFOa3+SeVlfoei349Iffsyf69a2f+TdTirlfVqISylZQ3B85Fk
# DATA hvQH7hJtAC8dv1qhuH78e/WAT1xIgwSkGGHDJctgtW+Hk/Fzm9M5tOLcYIgHtKngaBXFoISsj+dMdwwCvu1EbbRunYwFBkPcXHwV
# DATA sycqN4Kv5Ldq6Uq1VMyG4zpXYXSSI3ayskfC9QMGJ33C77Kg3ATdtyuSo1FTrq83jfw9bWHRoEODHVSjuv/y2mNuaR1VNDrK1l48
# DATA O3Z2wdyRJspJnY15/gGRCnKXiCF+QQTEF0grEJHwJbGZv+A3nyM18TuyVfgcKIq/hbe/IaQzStFHImUIsm4zMcTIIBPDrhokUNJf
# DATA vvqbuDyUnk63ieGAapEllinQaYyStGDYCOEQALaMPElfSXgtFCY2rnMLFVKWF/L7FIWjhMq0PI6GZze5D30dUIRWLckqZBajXOAq
# DATA zTx1Qd0XElDhr/L7L75Fpyzx8gSzWu5x//798g4oEPu1vSMwepVZs5spDxC9HwI9mvZaB3ZtIbwqmk8UJKY66p9R0DTUjxMhWTPZ
# DATA OEwivInYQFIJppqxorj1UnDSaTRlMcCabnOffzmhY/fNWSNprxkQcgRUQUk9vKBoglQ4KhotMmMwDk/q0S6K8lEqESJ+stGgTxwx
# DATA ryjwDWPOxp0HKKISNwdZJyTwoLpe+H1FwOOWkC2YJXtRwE6YGaUSskfkL7/6EFtmBbSVJOUsbCuPBek1HIrJynPgurjMR+VZVxuD
# DATA c/DwRfZJ/QayNlAhdUMNXe+xzYGa3472TlLAuPk4UqcOb1MyGZ8MRhncuuwsFcfDfnqOg1oXcpazCbHea4iBa8eDQTHnxpFST2X9
# DATA siGQJGWUHVOc2pZ7vWhDLCm6duzjfa9ZcM23AgnMHxEvDWK/vnzAgWUVEVxGUDPhqalo6FENNUgpO8YbQThj8QKmpSvopsn7du2G
# DATA VTTbX35EbfDnRajlOvtO+QMySsdm1SVFnQCNCgG6RD/UL9086Fbs1FguEocIBIT5Izj1dXJCNRISeU0EoAQ6lFdwOTxnUtOIuUE1
# DATA MW+37hR2dxTXJNmWGqWCOGjrhddRFp0nQzy9TATnGLUcxTANrGoZqbv2RqJMrmBRNVexN4vvxMYUX4VKzIAWGg0HPbEGo3ewAXXS
# DATA g0/EvNAJK2rLXpRVfCBm474kCFdiiVp0x5K1oGg865DyWeKjuN/JcHdXgUkqcOD1SaCzCH5tA3Ceqw1vD7TIiGL5afP+KVBcBaZT
# DATA QkxlyoTeybRhljwGq1rhBFQ/+8ri93Aw6FXsSHfymye9O+Zd0IBDEm6p1cajQkQNAe9mpLqnak0y4wB6Jh3ijwofI1uXp1yTtTbP
# DATA rcCf/XM+kiE09WTMhHOZcX5t0Ro4SASGQkDjo4k0qqArnw051h/5ZKBHzRDuL9wspAEMnTN3FQEJdem7cXnai4vjq0xpgNI+NsYX
# DATA eBlYCU3zJkNZv0S1kHN2ioVDYB4FbS0up5YbpGiiUhTZK2maK7yvoTlK+zQFXKleoDadaFT7GZGKPGd9CnFqXslgtbjO0Clss1RR
# DATA X0z2Pd2nQ/eSdtCIdG/pEEWYuMlU0fJoFB8i7FFonABZbzDpHvUSirgYH3fwkFfnNBj5BYfyIckeRovRIaB+S4qhf4z2nuwiV/Zr
# DATA 5qHQ090wTdBTV4tlRb8xhwrFiKPVss+9JKaGXhGMU5+P04Sk9Ej1dpMe1Hy7FfgJWxugPPPPkANFFtWfvzKl0ENyheg45l349lTZ
# DATA XOtxVsPKI54kzn7OCc43P+SFPxfZ7ZfTZvd5UT7786/+0p81ya/pIliHHh8r+tLoreUHn8sLrNFzzi61trYqAP5ilFwGO7FvIlNa
# DATA 9vOMrra4sPT2vulu1l6Qbs+sPH1Ar5QrdwFYB5EMM+oBMblZrZqZ0zVpVVZnb99/Zrn6V38TbTzfqjmbhTEYJCjDz6NPoOWCHt+E
# DATA YRA9vmxgfpKMWJQ4Q3UplgshNSQe9YqD3AOaI2yV1WfUklXKSoBKrkM+dvHLK9rTKm3IUQNNaGIFhauhTswEmmQoxch60MPFqGj1
# DATA jaOhMbNnuC7Bm4yeZg4VsDanCy7lgmc4bvRI1gLYjb4YUczv/Rjmvr90cLOxFHqzVxn36jFPs9iW7CQrsfB6SMmqa0IIi8ny0DnW
# DATA ZNoELeDGG+Quy36xxoGzGNMHpXHK7Dv4H03wk7CEcqoasxG9/geCqn9FBhc/R13ZF1ScPcdYR6xUbBg870uqyu8FK/1cXv5KR5Ph
# DATA JfFIDnhJwjv8yNsUq1UwdEpLr4ZLkGjM6+DkkNdZcYn+H3I0+3N7adgciULHGPs8VglaoOgw6byaDC1lPr9gewK5cXUnZuCM9LZc
# DATA X7Ioq0TJaJ5kZ1Q28kBiIYhcZaM/ilmqWGSCYk2bfIlh6eAN/IsWf3z8m4bILMk5fk3Zs5BU0o/MGTSBl4OH4QlGG23CDyZjKUAc
# DATA T0SGxQ/V61moKkhO2RkMOJZ42+BmH4NPx8yeBYFD4FQLOJIlukZRBoys07NFSChz0xlNZEehOdxqeW17Xk/Ek+DHjwDBnFMaTVce
# DATA XmzT4gzdpnkL0qMjQD0oYmuJzYWzKbfCEE9yRBRxKc3ySg/aQVfqFMbBHG+2tYOKKGCJGVzZAhw3r4QVFswTM0BZ0bOSPHkaE/gI
# DATA i7HY21NK7Et4B2HWgyIevZRVCZYsjStb+mKfKlvKBZahM1hnxeb0WK88m1k3iNsVyrtUVG0OmA6nUIva1mU6GqX5SUV5W+rR13za
# DATA pTZFHO7vlfZlZluiNsOflstnquUON0mzw8Ovhx34bIXToWi684/Q1ER1Isc1zvqNPB1LGP9KLAkgWIzlRnwgZTaGXaDKzXDac/rI
# DATA N4jfxVVP30ElHH0H19EZ99DAgy1CYt2dgy4LeafpjCyeJaPFXnZoQp8uAgKN57fR/b80I6WRI8cs/RmbYP4j+0VoB21tbPkrNGYH
# DATA +oFNMr9Ahhyoiv9kc2pMRHxBTt02ffK5sr6Bf/+9HSmJ1lgJpq5i9L9FIHOYUdaFWLKZMfYxdxJueycdYfY9KCPr3yxdGkJ7SbeN
# DATA Kb8VwW1FFEMpai/7LO229XHZl0MwfUOnKyC9yTBqoQNgJa9eVFBXDqQz58J5WTqwpxs4TtfThxQ43tPmiCFIrLN5YKUiRsNZa6Gc
# DATA hosLqqfu3peS0wywyw2FjfytdGmiLsgLHbKAFtuYKOsTJOuqrf/9eipfHjGS5uM+N0iBLmQDFfNE6MAuKU0Aze94Vs1pBP2ffOMC
# DATA cgL4S7It+BJtFRW5/6up1tJypdfZtOC3EvTxZ0y9s0FcyVo7ObEuLs0tmAW/9zUUPQg2sb/CETUcEbhet6p3nNrKmCGwsk488fAe
# DATA yT571jUlegLS11gxPQ2moVxQ+mDvx7syAveIOyqCpzRZE1HeOuqPUxSNcl71qeddBDy6onRbLRgAccA4GiXfhRs5nWgbWPKu+Jlz
# DATA VpDTQxQgxpPh4+UH/nF2TsZlmy3BiK3rIingNHEGS1r8Wi6IFwKaCm+QgT0R0K4zh92WT4l0u2n3OR5Qqod4wCvBahs4WC4RiqX3
# DATA Z6jCapFFtWRHNybgSnZtx7YnkpgonuWRijL8P7PY2OPVKVojOQ0WJQBfzoO6fylhZN14LizX+wU5uGHw798aWXJg5qEJ+18UEUDV
# DATA HR02lhQVpdlB72xwa0ozZlGY3gdqp8CfeN5lRQvTmygcqWsvgHnp8N5e+0hUvBxp+mX4EnUxbcKpwtaXDVQtzuBULIZqFrtSCe+R
# DATA qyixZAFFJVxJAyRNMOZtelZOehUEhIrjodmpwEAkIJkuS3gDUYI3gVleCIWoknBZt3GUvnXgzz06eR1vnnhAye386u+1jTvK1p3i
# DATA Wnj3OUF3W16nhHi+yaJkiiG54S+J3rADQCqz7dDKGoXmvNITWrWAea30Yplcz9zvGku+zBji+RlvGYJvW6M7su2A2damWyRiSI8f
# DATA vhOSft6AOW5j3xFq41115MOO3d1V/NHOs+299ub24/bjZ083traRi7CVAdbMn29sbz4xxdQXQ9eguJqTZVu+J/DSW0Q2w0MHEsx4
# DATA Ol3gf1B1MDz24EFjNemibFwE6D5dQ6O81ZpXEu+uGZBpLz5sP3/x4ZOtR2opVEdk+lx0rHDDwE0zMNzvsyWKXpd9V5pFPHyfZG1E
# DATA 050nZ2k9ENZK2ygu6MA/gbMaODiWiiN4bqSgSqNlQ7AW+4rbYK9lKwI9VWRLKwarxWEUSSKHZioljG6MyVWHg/N+2nU6DJk02WSZ
# DATA W6MW3q5qzRHWHVStDZnh6fjGVyl0EQ4W3uC2fJPH9Spwq5pT7tS1u9VyKgtX+amKtVK68eHSaBhbcgto71izYWJmWl6YzYW372P2
# DATA Rn0dENZFlbr/skGK2ZPoeA72SZVET1U6Slw/ZJ0lpRYKvJACK2xiqkZAlsJikmy5pz7WqmkLaHlR/hiUWxbK0ua1ztEH56/btmCj
# DATA VvmW3VBG8LoGt8MKxVZk65JYGqipaS6DAyRjpunkQzIZD2LfPPjt1S12u6XGWXZKB5mWKajjpHgGWtSwmts8hlokAiu1PpGOW2rE
# DATA b2zzU7Dp+txNnPXFekk0du0845HNsdGjqtNK9FyL/rXUHi1HigyIQEzv+A9RgagOafnKkWJU23SEGawBpsohb1UceGdfhuqMY6vB
# DATA w9Rudq1zlbfimjg7lUJZA0iqknfSv1WlNjF2M885/ZtoJYojhFP4SDXZKnRC9o3Ew7ZkoJ6JDHU9fQ62+ypBt7JFIWjoL0wIVFe9
# DATA BtUYWRt7545U9cAWrYRtrWObJ1dizL/WOUEt0zDFrOFwerIzAHD0WC21ow2oNOCXY645t1GPb3XElgbtsuAJoSgFXKXouK8bErcv
# DATA /TzN+0uXZIVmYsQaJeSAlCP5Cjl9jy+l71J8XWWXDDLm9CQ27PTX1lNyWTiJJDelyhvSCLMaejNyoWz1QhxZGSFgb+OBceCVUU43
# DATA eTY1fcZtjrneas0x/oBfKvdqjOf4hStrk169aAsBd9VXxMd7qn+rC/VQXQhHCg/T3NywS3WrMb0Z2T3Dq9FoF0PE+ezNmEq6fzt6
# DATA Qh7kHDpxkkt6a44cEufRcHIIM4pe7DyJOD4XZ+0QR3COhwIrPErzvDGfdIQN/DGd3CjtcTaIvoAAObxsClXq5SbVZoSnKY21XybX
# DATA lWa9aLr97hBwiw0f7ROh2iK1kpLXbj7d3vjBxvc32yyngaVjw82Q/IO2RXVSdSJwAGSYc0ZlR11mREFL9O8bW/ZIzenGPcVCB544
# DATA fK4rFWgGmdLQkjbdyCpqDX2I6mcVRbzBx+yG0YVCoYU0ytONlkQZCgJYXakIf8Kw3FQ4KOJrrzVCJGj7pN28xSPIDOzbkU54r33i
# DATA cgpmcJJmI+NfKUQxO+xfjCUwBmDuS4EDxoVTt4NqDravRPWDfl3XETcdJyXKBss+StXQOqupno8yTBqvWvMsmOwUTex953kp2i63
# DATA trfiTAc9Dv4ujifOWPQkY2JFJOoV/nb8hULFdHwgDiUvsXnTXM6HWn4nNN0cuyq4054r2eWq3WQzby2U47yMcOe2xkTE2vWqvgt1
# DATA 2N/P1+op9Y52VmWSv1zZo+U3loyu6sbZEDUaEd60IBJttJiaJzxGPQGRSPrqQZas81IjFy5fD0I5bfIQWJYDV/AQRYPbofbd7KR1
# DATA uKSj1Hbz7KbDXD8cTrJeV7xjgb0gsQqqg6eEPrlT2Y/rXQlIJ8vEJpDcJNkekQz0DiffceN2egtUwLZlqxWk3hiJJ93LaW6ZKq2v
# DATA mLYeiWVshYTQzWIkRBO4ugHDqOxjBOn0Iu1Mxslhj7xrt+JgEGm0t2IvYjpZuqfGEE5eldLJqn0gCXl9yDpCAlA4GIQSmHSELLdr
# DATA FCR7MBm3VpeWRIDMQfGtAe7qn5tu9PubWGjYOnq20EDlPL366evfRa9/FX28t/d8t65ccr76adAESE2X/HU4+AhHqBXjon8mMQua
# DATA If0aLiJFyCZmTuASUHsItuyQsGK2Xh7ijWESG5UfMJeMV6KX8jpjm2m3js0yvyw259VglE1pT+WqNjbUG0h8uNUCpylgem2iN86N
# DATA JOfUYNiIz/JGFUt6MlZ+ezT4ZqhtdMpHHNCMDYhiVydiQ4Vel5Lj0Dx8TPEhz4g9kZxApFJvUTv5U4KVvMFLrpJxBgJ621hVYUNp
# DATA QhqtOtIXKx6GG/ihwDBo012jXuYGAtFyZBoSzsRE+cwDMRK43cakTyZLp1mObFN78MprrmhT4hIP3EzNiokjYXC8QZjwODU1vlMO
# DATA 3sqZZwLxba2LY9tOVU3EWzPUmRSI67di7nfLvdEB8oi160wOCdiHU9gmIe38gKXQK80Y0dGMLi0HAOemKXO1EvQm/bGJTVUL22bB
# DATA gSAR4NBT5EJLt9Dtwg5ULBOwRJ7iBv4qvbS9v28Ii01MUcvRR6/jHJL9/0Ocx5RYXtmR/wsZlyDW+XeOaP7rv62GkS8ElZILagev
# DATA cmNMSYHpokzVwa2WDxbmNfMtJCJwAhyTz97PZoU4bkR2NmZl1yNWQhiCXhvuOWqRN74wDu11E9jihtylIYi2jeSBrEPyAKmfdkkU
# DATA DA0U2LaHSaZQZEH7QmjOvKxxoCQu7AR+maVB8OQ9TNGZ7B4liYzKt91kLhKaivOo+Db54rrVj/Z9jQTQ6R7732Arkko1kNdQ9P1j
# DATA kTBfqSVvejtQi+w1EO8KwvDW62rDMmWHGrCmdkmMD2qXuC5wEvNfdpXrkXl3HdsqsMrOYbU60Xx/ECmqURFNVdNUnslK4CCEagnb
# DATA o2K03VIMdRgAFMmmIPknZJEi/mhogehT3FLBj7Q6Y2kM/cWKPZvuqrkK/ps29XZtaGrUbacgtXENZx1y80ACGdrkYHnXPkQLleTm
# DATA PTqzMOMpk+BPSAfz/wCvUuDS9ijtpQB4PWQVmpySuiglpEPDu2F5mi6iDw636ofyuQ6GVhPpp76iRTDTLAuIJjLOUBiF0nB2RD7Z
# DATA FZ14Cm41rX4vj5DGLfkz1QIvb2H9csFmORMUCdDtcZZoLMvWRrdClhPy8AZL5VZ9u8VSbb2z5Zp9z6aR22Wh1OaURgboC20G31K2
# DATA vs0gtyxh2NDthjhgxRM74jdKRUNKBJL/UnP2DztdJyY7VfLhxXTcWaRSi8Z8nsok3WQ4lsB3nmF9mD+cU9pQmqTJEYbqTE0Sa58e
# DATA KhZ6sj2bNe0k1FX1Xa0jixdcYQMWG8dOQN8AB1rY76IkKK7O8rdXsqKC98/8aGNe2VIBoRmqSFN7PsgN0kUhkseyP59TclVoqd1L
# DATA LgcTcmBxMHkR18x5IQv4phS1BxkS3JaF+bZCyPIPof4m/QRQbLGsjqjS5WR1bhUNy+dKrvKW4cV0Uq+yYB7m6jWD0Sq9DQkF6vNC
# DATA fuiQIIWoQdW5TIreTUAekgt6IwPe5KliSuYxzGRbw5pEMXmaDG0eZFYwwKpOccYZb0mwz+CkOY88SNhFvW0Hnk1kSF7kyFGbxSOd
# DATA AKFJ0NgMxmb4qlOE3wbF3dIoTrk1B4fiJCjw2lTZa8Jz5C21coo47icudoAXlXgxGWaLGPV3kWNSxqwLxz74XCyqgEFDDPnAdu1W
# DATA FtEGKbva/LXifSO89zGseA++XakIt9006UpoZlra0wEsxKCfdSooMF9e4XAt5ycYkrhQ4IGu3izP+8xZ72hInNaLrLSU5ucuJcAD
# DATA dAUrF0qzbDm2+TvjEm/avqGE2LZ2rWBsAAscrnQ46F66YWjVSEkSVsGslJKcElerPPCxFzQc27UCBAS+8tlTveHlnVZ635SUU5vl
# DATA TwZwfTbQwAgVOzVykpwSKJllL0ZMQ9I2FJKRZuvnOp0MGw+rpJg/xUSbv+VIF+jP+jvylvsCJXEBwt7bA8FBdnbcBurhpomJOFQ2
# DATA R0cA0neUFtMvkWkVIEYoFWEynTiPXrzYetzw6ULJQUr2VgCHuP+OuN6tLa1Vp4GF+Q9feNKVZ7uS6dvO/+0sBUzDTodrdMK5cWWh
# DATA K5n30nRYWRFEGRadkn4zEk/G33r+yezGrISlsps/ef3P8PvvX38pqlCMMckhS0L5YIvukr/WKRlUFHpWW76F+vOWRefMlq//r8b9
# DATA +ouv/hqdPv2kETi7OCCjLWK6crpLa2O/McIry4cYI4DyzJtUV5QBHuCrJD5uKRl17ImeOT0966PopyPzpTcolTQuQYGG1SjjwMB1
# DATA 89Ob0MvmaHv4gMzZBCp+6ozMLbW10YZZzfDKUVg9nfRjlBMGVRnEGxuj4wken+f0pWLRt612uzvotNtVq2YDLQMTqVKJ9chiNHAY
# DATA oN1Ha19phrRiSMVrt7X3SnVvzYYyzR4NdHSsUIfAKWKgO0Ckl8O09ZyT7QGmBzKua6sXw3UNpeIM10mOVwsRtdOHBBRYXVOdpt15
# DATA fWemN47MYf2UR2baLoumO0dbZJtSXS8rI6FopVjAWwEXpJ4RgW2iieJ5iz3VgMj9nRxiwS6RLDRuC3h+yaaWytIfLJ1XqlPuvDpy
# DATA dpzADM1CJag2VWFWi2+/YaHomWciD8KByZNxlpIXOiiB/cw+sfRsB/Otlt9l9rNS98O+E/Zdse6HHfeAZTZHnf6458BoR+npAZTS
# DATA hLMkEiEbJ869VIkBJcFQqpJ79tHO5saeyjS78/gHO37W2RrnvDHdqJTPR13qwE5/Gp/HRPtiDy6Gp9k0jvBDBf+pyZsnzx59r735
# DATA iUtXuegg4O/I+08kbHdyOsxtyDbzOCgeHNNQ52hqnOSdLGuJwSDqW/rj1koVISxsbJtsw9ptOontNp6kdjs2hpZ5dtyfnNKG48+k
# DATA 19jd+u7e5s7TWmSeP37x3DZD4vf8p8IN6GRrd9rAx5LtWjauKOrbweQM8m3EW7HpLU2EfS+9ZForQHYyfbF7CWDmdPMiG1sKSS/w
# DATA V8qNVRQF8EgstOmcS08enVJVfmGv/8HQYpra1oRZwSYgaJ82wyaNwtD8hDJmI3n3uYp48StKoP1Liin3rXf332ky+uwQLtTw8ltf
# DATA 23+YsPze2hr9hf+8v6ura/fvqXfy/v79e/e+FS196xv4b4KGotDlt/77/O/btxYn+WjxMOsvpv2zaHgJqKO/unD79u0d4J3hItDx
# DATA AO5s4/kWR+0hM17i2fJofDIaTI5PQq4zUL4BrSwI8FcUnHpGjQJeP7zK3bF6C0wbcU7yCAT8CbBa6hHBo/o9yBfIzABJcCiicAzS
# DATA WKrISHcG4Ef9xD7Vb5uR8945Y3VlNPrtJOvyGASSqDEQSwHgD/gkgLidHkwo0po05ns0U6EJXZi0cGA6DayIwAGdng4xsUbWhQ92
# DATA ZkU2OiDMKM4lxkx5wTbsm57PljwqAUDn427Wb2R5Mh5fVoqmUe4M4qds/hdZbi3Q7ChD42SmwQZ9Su+TcNjeU1W/GbkUlAxJtr4h
# DATA fys8bQLePHMGwVl/OBmrj3p5twc7KQtHfYEastTqm8jVZGrshcBf2lK8gpQq0eiAzoco6Ea66TQ/huWH6wBHvobJvaCPmeuDHev2
# DATA 4cePKPf4Ol4cui5H7GRCkg107DGT2RhmZoTtdtbPxu22jIzFcoNXcBBiJ16HETMyo6S9rHCsjlmv5PdVpnFXLO/U7vPXWqBi3LJQ
# DATA 6+KmPHYTHnNWYP6psgIHbcW8NXqB+ePNGhAhNpiM7VTItUi3rVqOw/NptVRwAxJYm9HriS6v3G8swf8t42QpgyyWwYdmczm+nmfE
# DATA O+npYCywLle8HNul89YmEaem3d39OBpP+jgzvAxYIrYdS3pHDdpL+kUbyjuos/ouIkFLH9xacg7J6OmT+keD0Xky6qbd+vPRAO3M
# DATA IrOd9lf4hd/MClzz2pk8BnMskETNvnYHNJeY27qgSIea+2dfOx2cgBhlFJmKDSim/1LkrJgdO/5BlCPFWhc0zRuSo5/lsLcoFix3
# DATA 7tjreO0E3NSb4Z4FKbsfb3Cyv8/EPxpFSx+mwLGNCKaZ6n5OUd/EkkTWpbnopFLFv9Bi5YmVCS7isvCeWIwDfa02pGw1PI9HnIS2
# DATA vidRRd2Fuqifn59TzrW67pXD+poeiyvrKGkx4TJAaDxWI/SVq6xacTvwpn53c0/0aMvVOYwj4aAUT9iOdXpwfVBfQ0cHF7CF/2iw
# DATA 3dLg2wmEUZR+Ey9onWvmOQkhKG3I2ix1iJvt2FVGrK4oVYSlkShTSGAIVGmoGj2M/Lqz9AQ+8EISTo0Gc1AChzY6TktsewQtO8n9
# DATA eCQhy9EbqQe06RBTEEG5/jT9kHud7Ba98+W1jDBubeWDWnR3aQX/WcV/1q6pmDqwD6KVcNe2EB9giKpQLd39gr/yrI2hwxwdJVkv
# DATA 7TYJY0TKZtJMomq7LAU2ohLUTtSiPT68IV3FlMX7va8KVOljsoJBXxZmHRVGqCo/haKd6Pmz3T08FWRk5vty4eCAuzsdOhnkg7l6
# DATA K+RDfQQHfezkMFMpt7vjhuJYKCKb13QNC+C7z6D3xmTcCcl4ShvL8gEnuOTGGirXePxDRL3vLS01l5Y8O3NuqzH+DGXQYW8dK9U8
# DATA lVWtcp1WcMBOTu5GkqsSFb90w4y5asYrQ4VB/9DSKPXP0hHQoTmajeZ/Okm6SNMNxgkn/8MgEUnWZ4mztiZFzs9B8ZLxD1th3aki
# DATA R60gA8LLjGBVJ70exWiujOL9jfoPk/pnS/UP2vWDq9Xa6r3rmJMpz6ThXyiStztIGVkfZWOi3rsm3HXE6+AdzFEKFcnHxMr52T5N
# DATA hkSgME+EBMrGo72t72+SeBo4L+Cd0Fwkfry1u/Hhk83HRIdlp8BP0usnW0+39vhtejFELQK+3fzk+dYOvx302yecMMc0oVPYmLUT
# DATA wwUdQ96MbuaK9F/1B+d9JReIVEsLHJDhFOPyQT9dSpzLmy5GOYCN21SAo28tVWteCazWHo+So6Oso8rY27oUPWhxF/jjg6Wl+8sf
# DATA fLByd+3+2tIHHywrroVK0QgChWbNbqtPxo6RjALO7gQ52FxvIpqVHl8SbRaYWRtP77itivEk4v6A38fVxmQ4BFrYRIZS7WkOZftZ
# DATA e2dzF6Av7OXjjU/xzw82N7+Hf58+2977GH98urmxYzMrZRuVQ2+DEZrmUveRGRZbiyQjvHTkN35QGBFiAerIVtrp2Ztxrut2VFBr
# DATA qhYdpp0BOqXrgvY1kBQ+fOL2cSX31ZE8OLBPq3lNA9Kn20ju/c6fbbc/fvbkMbZ/mUfqDqxHdOH4uiJe64q4V3NwmI4oPTdwxAAo
# DATA 1qVqGMVpCHG37YgSP0xHA0CgST+P0DuSLqyElLBBRSPavDhJJjnZS3c6nH3gFJ4j7iCSC95wGFw8zA9bfqf6wsFqLvtWE7LOdKYM
# DATA hFHg4zrsT0MbowtNMdflbut8zxz+SR2RW/YZ8SyN/C3bUWvLix5RamRVed0EUImOJuMJbVUfbU/ziMwtjVzJZq9DR9WotnDYU87Q
# DATA ixztUzh3CRA00WewuetAL4+BrechniaXEfTaZ1yQ9Mj3P8qHSPAr2JEckxHigoOKrwzaaoqNrDriKsWxhu0byMAaOoPvA3+KOf2C
# DATA gUHyWqkpVgDY1ZdX6qvLeyurzbsfwP//sBBKIZaRPsHd/BC9BaE/AeHOt10FOJp6YVFXTihsC+FjP+ntIl6nkDhIrlKiODTnqRC+
# DATA r1YLwZ5iS7+Flrd6JgAKJT5jHMJcLH3utpNxXCDT9tXXDc7c7q+dVddKaZVR6AzTg7yL7aQZEwuYttAwuiKlqlEd9vSsh46AtGqD
# DATA H7FmOT9JuoNzdBTMrWmYZm4Cvoco2ekMek3rLgjJRVJXCUzD0mc7nbTUA6qLcmzUlKsput9VzKhZO06PL2DjUO5UsaaiJH1mgs/V
# DATA GyppT9UrnuemqBtcQI1NoT5ZT9+NweMXlMBbSu+rVtjai2dZ9cPtBxzspku09diMGNIVOVopqsyquT2okbq3gdkQ2xNCxvg+0TbA
# DATA 7XMJfFpdmWfMz9VYtTzWIVVtMlX8OOAnkaqjVDKSuaBTrhJPEW9RQVVQ2KrwyLYHUfEI25JdO42GRfU7AVDKpdqGlrXMX9rwXQGP
# DATA aoOiNlriVBUNDn7u15cP/HMylW1Yvle7t4Z8A3RXnWdjbHdbFuMqeV8S5SeoJsITwTLjXnqcdC4DNpKygMXtiakJOnfkIzg5LLJv
# DATA NY3ZtGUVJa0RTgx1M/1u2pXZfDt6pLcmAqIIDsuYRJTKXilKz2AO5ycpt39KkhvCwAnGQkJTGqRghCEn/pEhUZb2ukRlOiybuThF
# DATA sOJCDoKmarYGX9ZCCKwMcx1ooCiRmHlUDkiSL2pdWIugjhla2yFVo75SWGif36bFJ6ZVxzgOom/ET9Sa+azbtYsU1HambVic7LhP
# DATA 6Ogqh5Xlk+CKNnInJV/Oxh0UuUpfniASpyCV1/aBQoxnRhisdEBASw3LuJ8o8NPGTivJMHNYbwUm4b2S6lZI+oT+ZWhnT2rmxcPL
# DATA ujo7ZJXvwAQkybS7UHKUomLMqAnseB9G9WmbYmstaTGVuSVLgm2BM9hmHMPzsHJMHuLVUp4WOcmZiV5E/Q5pdjDrLOsycC0Njh4c
# DATA HeWpJSZfqkXLbAXhNqriTM1cq+9wiy0lOeRHiqvzR0Tc6S/cvIvYiMYNx36hTxw8cj+mJzdZmfOBDjfVKJrCY0EjwqHgLJjtYD6o
# DATA SssvxgcqGicwc6SIph1aZ2mgeplEFMQuAr47G3Rjz5MMjUslCue+jOag6JlYFDlVOXSYryYqH/fjCStLUiHFuGtyZsspnBeOQadP
# DATA 89zw0j7aIFZC46iu81oo3gUfqn5CQSpBnrS0Je6YD4EofuWjQmdBcJhWMw9DrZSJU5RtoJo275HB/Fa7twrDCze6SU0ID4pC7xSV
# DATA UyLTIGNuJ9K02DfVuWflxX4lk2uq2yoHt8ljuHYgBhVR4cEmfc+km9yz2FhyMh5OxmVp3cr0yWwNo4dM0gDcg0PUJUM7hwO0psHW
# DATA 4pJ8vU7nANcGvTOl+NNlJayCnZK7FpGpr4rfVIv8mAvZkVXfnhSeiKR/WbG+Ai7A9qvziFRhXsDBR6gnuERGxlkA5TuVNzonMKCK
# DATA BWStoclxaqGtBM+f37S1tYNN+VrFHIyE+nfL3IbjrT56sbvX3ni+1d579r3NbQSuOyp/IdlAsXo40nnJlIi45TT1dGPnhx9ubLdf
# DATA 7G7ubG88JfGLkpkmXSCeoAVt0mPlZNNkfLi55xu7uz94tvPYbk5VwTFZi6ONCuRRowyk0DTOoLEsUlF9LUQ8oX7aPF1T93YtWnnC
# DATA r0gToAdzmxtivECsf07uo0YAFkRcmZASda6CER0Met6PM4/SsJkRPIaG/mm1lE0z12hTg4bw4fars8XAXJ3LG46K7gu207WTXRqk
# DATA D3N1yQTFd1uHmMZHqLedZ59Z8cVqrKnMhVjYNySrQlPUxxQfvmFyiYrami3adbUvgcWRl0beqWyKFU8GvAWyZb7Wl50E3N1lGs96
# DATA UVNjsmj/g0IcYd2YTX+p6GOKaVGFdJPVuXGvBQloKTn6FWv6u9nRUUrRrpgjWKdOB7BmiEuA4vWwMRmf6xzOMhS6FrL2sVp8eKl+
# DATA 2l4VzeB0rXDNSo/rTsP1QFOG0LUIDThKbaKpOTpUZsjeBfcJCk4gTZmEolkW1O4IlexR6VAERPOyxtelCNoOIGzQMt+ImEePi0Y/
# DATA 4A0dVEpZ2PRP7rUS6qFe6UgIhWZ0ZYiMa6QOk+4lvAQOllwLJ/u31Ybc5jw/ExVcAIsr2S5naegAecJVZ1RDQR2g7XEu3fPwq9ex
# DATA PUQS3pBVoIANzgoBTTS14t+kcNE4mduaBcOej1IYwfHJWOvNbYwI/DoTz41ohzQfkdkG13GlO7psA9HjeyrEj2H34L32B2PFPIPB
# DATA 4tVxPbwJcGPjlwBYcc5s1Bk/sk2LSZk/PoFLgkP7Dp30CCogmiP9wmWaFxxo4kd4QHvl80VXImswQn2gYF6kwyjCPiChqGy4esHL
# DATA SE8mKwoFSJB9txk1AgaoA+X0OgImDtaVGjsAFsvhugn4Nx3WGpPaQDC/IFNXam7lUVAlxANfVgORC80ILHPPZri3b0cbxjYJ9StA
# DATA //YGgG5FxhTpkBxsgU6GxBiuot/JMBoyhYuODoFA7fYumQdsBDtyPHPffonDy6zYXoW95PM05FV+lR/JfFmajV6vGZ7vUYr3b6jv
# DATA +Xhg1iPo1o1HXWtBTBbi4pxILH2DoaumzZ2Z2njIZG426lbcPqChTmqmTWBH4WsnylDo7JUgSTUBueMHQXQptHAAPVrYO4DgRBgq
# DATA KI67KsWGux9vrNy9t/vi6S7ZtXCGJ3GDaOQnCXysDL0AnyfpRTc7xutJYp6IkMeQ0wPC88t+zOogooBJHm9xbse9wWElviOgv1p1
# DATA cShD5K5gMVmm23KEbh8gqrMxo11Iv+diyqzNKcMvsYDBOv5ezER0yYhk1qz+Wo+s5Sa5Uk5dT+A1at+F9BI8BZQfX9NBly5VHHRC
# DATA fiP/46I3K9FDaFAb+07A64HiFtgJ1inpxWWl5uqJJQfzdkCsSx1ZF+XWTJZzsGgJLHtrGTj0UCdEpRUdg23bLyU7NI1Zn8uGA+RJ
# DATA ncNyJWQl2Io5pNYYphAHR3JJaoJQ6ZIuFCdUF05oWm3lDRx0BMaTtkxScpcHxFd3l5Ys+oGtNyuxWexmtPxff/K/3EU7QOY3tU4x
# DATA wNPpjB3ibjrT7XOWN+YNeRHLZZPMh//N7rPtxxSFuJRVYYDzZhyHfquBDGUvYKqS6EuU27CVXsNSc1kAgLoHahgDXEITLXGHgm6r
# DATA 5R6my+/UEfP39J+fIeL34P95d2VtyfX/XF5eXr37B//P36//57PzfjToAzE9plg+3TQ6niSjbkT6ivXoVZoOycsJLxjgEIoiQHYp
# DATA l8YG6gwuJBaf5gmaDSWR2tu7eZ5MxllPP40T7atpUpVoP9D0dIhXfWFhD00EI5WtDuW8HLWMZhsv7Dx7tqck7RzzUperUwC0Ix2U
# DATA ceHF9pZXNidw0ZW/ZVUbKjRR1VIz3EHg7WZiIb8WJ1wfq2fdTDFcj6CfOMFg/ippopMM0YquzVifX05JxMe90792Ihg1zn46Ph+M
# DATA Xjn29drYTW9sIxu2nZKUaybrjG3JtzFqR9o+u+ilFCtjKaLYvfQhy9un8BeIynzsvp5QMjui4Xx60Q6WtRFJsY44HW49x3Zg/frp
# DATA 2DZ2iB0FEOeWxr70/qAqHNUp0AhMJj+h8Bmw6oejrAukeC0yuedbS9rJl+PQqaWgZ6E6sDbJ6ok8Rx2xbrQa/Ti6Wlm5dpRm8uVh
# DATA dG9NaWOQGKsMq0qsmHF+Pk10DPGfe3fvrt413AC3Mm3FlDQPLzqVdnV3Ml0cyPLK+2ok061pGk20p6kt30VzmkPO/XmIo1GNzTOe
# DATA xxiCfyRVlM1bcpr1yOYzG94jd7W4GbN+1wTny4axq0E6iq+44nWU43mNrqj4NRroohOhEEhstNuKKnGWHRFrdUV8FhKuzKXZPnjW
# DATA rKwtVRPkNDeR7oKoHfmoEhBrCxLcVXOYQttLJu+miN7nedaRI45ZStnz9BAjxNDCjDvDqEtNXpnm9ajJM9v0ao9b7s1RHMes3c7w
# DATA fl0RpL2Orq4W0AoC2jnl2JDwhuZJxdoCC4Fl7CVATQvQWY+urxciyjsshB02w9UAjqOM6GQwUEQf0HODERow1ZeXgAlAFeqljHsd
# DATA aqktvN0b3JbX8LYz1gFreXG6o8EQ3l/xWUGpn7UiV9GV2fvTZIjEa01uVPUaRmsaNrX+2MxZf72SJb+2h5CSWUCWn6TdmsoX2lFq
# DATA UjZcR0SrGzlNx0nUWyM7OwC8Z/fqWecU7jj8c3aPVwlG3O/W+2l2fHI4GAE/CouCtr72y6SL2iJ6N4JFT9UbnA5cKljiISveV+7e
# DATA vWnnDkfbH6UJbCYlMhsmmE6jPh4M6ofZMaOZutLsU7Ja2CscC3QAFU6dteU9MmfjiF2eS06H+jrjfMxxEt54p64Ellzbg4f/h7ti
# DATA Ysd1UKKlBRCCHBAJLIhdrHKKKwR/iAFStx89297efLS39WybvaPE8tEB3aYRMg1Z4+Ae+iVaSAJm7WbHWNFi1HAwZI+CDJtbPhTb
# DATA B+EghS5FEycgTmIiN3OkNwHDcc6/PRzhuAsHjgeK5cMZcB2cQjfqZfe9mDKpBjPzOYPFQmol9vVoC6Eey9PaObZYIkVWYNt40ZDO
# DATA m6baJSTFyQwJ5ZM7l4QL52NJjl+jDHa7JbgMP/6ptyBm5zLbaNHWQNjRT0v7lpy/6AQPDak+vIXjtEO5aC/4UD2TtDG2UbyxIKIV
# DATA UDJTqa7jaDd4JA0ZRoOLN8SOyksR4/2nprFEyIaVKdukLSEphqyYoJ7DEYVm41Jb3fhgv7m8onZZUXKMjBlKa2pNE3WcWJdQFqxi
# DATA T9MilrqbFrd/NGbPPA6OQBV4fVN8QXhOUe4uiataavCAyC2ZMkWUNZvHbkNWRR+/73AYGqU1SPpMJ9CWR9A2N6fuaNLPEwVDKkdx
# DATA NyU7rSK6fslxsEMDJ/Jc8D6SNLRkWvakplPv0L9H9G8sTIzVf7VYY0pZSRmGaPQ863cH5xV00Jff2pZ5g5BIV88aRsm+Ep3eAN2L
# DATA yJYZZvUIcNvhgCgp5HIx2kUkNz7qjBIA6ia99xvufHDDpjU3146/2a5bNwEWaXsQDc7Rhpj5+gxNZChjAmqXgGNkGxjFo+aA77Je
# DATA j+OTTl2UnJbCW5JYUz7xfOtDdhhma0O21pYD3ovh8SihuxRxjhiZE6lm0QRHhZbhS07mF+OcT2yk8lI17OiwZaex4kYBxHQVEZvw
# DATA WiTujUnbl1b8DG4X9gIJLxyh2zZTuFNoSrutavF28U0nH2K+FDM2KyY6931y676Ow2AtuFF2p7BKb9ajrBH+XL57ymNQUMCO3et5
# DATA +JPvxzRDTJsZ2kmPJhyJIpLyiqPs1khQNBglZG6phEaN01cozhmiHq1FXbFhJTmwH2UXrbhB568eilvsRZs86pook9i2F2USe+N5
# DATA 8gz1V20hqQdYiGs5yI3TvylkghZTCKrepXPtBjn7zUiKQF3PJxJylQbUlFCpLjHAqOTMM/whxTEj2bolHZscnS9acWTyRteXkFGq
# DATA 4qrZ12+aHYYRoliGBIuN85MMCM8Y3rkBB+BFaSZfnnTBfFa953NT+Cx+Vl4RsrAN1EbgVUFqrj2BOdwingDIrxSeZpQnB+c/gnOz
# DATA tLIybX1e9NGzInrx0Q8ia79Uu7YnF3ekEkxaWiXgESWukSrEw/BhPr5t7La3dnc2v1tRtdRYaTb2y5IJ+/WKc3yLefIdRznTvjEN
# DATA 3sZe6PgcvASEPO5h/lL1SklVXvZthTEHGe2ybF2XINq0xRBcPDvNkpHiH6W5nM7TX242IHOWF1dAKxmXV7yMn2VtVJRPqWvO4jJg
# DATA UCfvJCh0pAUhCjDeX6p/gOK9u9eLgKJeomaW26pOBcG44jISygow6Z/K6rDdRx6CpI4AyvMyZ9TALSqwLDZ1Nvh4L4plnFU/g1AF
# DATA rjXHBI8pm73KgRXa8/LamNphjlpkcmMWPRwXzDRrJbM26HzevsTzmXZdgPg8Ue+dARYHN/X2fw0zKJ1F2MjIOxByJt/RntuR/9Fp
# DATA eTTo6ayxrCIQ9cAb4UBpkbNYnw7OUicwzptiKAnP3DTA4Gb6CZF0FowbLO0EPK18I9oJgqCyTL6a4v9/GFhP1MFKGlfo/QRGqK32
# DATA dBrE/28NSfvfCH09ROx1A/QdXqRZSNUyggEUR7GzHJHjSx/jP+JuXrpIXzp30f1z2grRO1UQTyb1o436R43m4sF7VYX4KwaBVr7T
# DATA rJmn6neqPkb1d4VGOXONioszFeP6J0lBB+oMxahuWDKET0xCmEq3WgJbkNFmCIIKEzIc42ZWDpRzfg2NEKmGd/vnn81h2hug98t4
# DATA AAMZjE/Ie4YEG7bHDsBcJOHC+xmbCKXAf2s/ngD4dRDHncp+ALEdWCtD5Nc+5p00yA4NHGITpCMeDwgX9i9jjYrg36oVNJXszuyL
# DATA OxP50jQEF8ks3ES9M7C7h2nFu1r5Dn5tiFfP25mHPllhmpDnV6BOZlFXxeZLlmom9eGGYsC9cjhsfS/IcqZwS5oLNx6Rt8ZH8f4V
# DATA rNz1TYGSaL41D0Lq7RINZ5BynnMjzWGcK9uSOu4euRVYZREOUwYlWS/bDqOmiTOeIDvkowx01Mb0GrZpzRRiCPYQjYIKJEOF3tp8
# DATA 1DTdhhQvUA5k8OJ9srHjDD6KMSBLP32nWmrVz6/uuQFrFvcsG0xggqTjdJLr0bj9HNw2EiXWNFxKL44dSdrZFMLLdudKkURlnhNt
# DATA RwEqODmnXVMxq9S284nJIb3PJX1QgR1O2BSzUYZVx2ld5+U0BSzXa4tmrlkKQqPXXVC3gFSFji1RuR2RuzNvqYpCGR8pLdU20Ylp
# DATA DBHnBHauFqFpm3FJxepsWQPNuGioXPA6x4m1SDWAeajzxvaa3Kov/LDElFUj1yiOT4UyYWttRS20igyQj0icM1QIruq1Fub7nCZ8
# DATA gB1YezpUbUqI1G67t6qksrNLlg3SlWQKa0YylDjPT/j+NNUp41jx+BLe2bJa97413WlgnFF9VZrWHbkuDBJPDV6meP9FPxsfLDy2
# DATA UI+hvIh9ExxEa7GwgU5fLYG9aIHfkJhbokwWRcrCh4TTW2QVSCFipNzC/i6XOFhAq/QW7HB+MhgvbF6knV0M7NfSVq9i8RpNM+1c
# DATA VDukMQ0HLaRhoi146zLNF/a3mMo8WPhBgtbkH14GBhbHHr6M2TS0M6bkaN0E8Hu/PkrJYXBaybSvrvpso1LLz6mg4bYxcAD7FtwD
# DATA vZNvoeWCOsGGFjUdET0jFV04Bbh18aY6LSoQNpMene51ZtFO9hB9Ss5eNAV/xXZCwpfxqzLVuE+JwvT3CZ6WTzBwMjg88DwbHoD3
# DATA 8564kqq2gOtrTNDISn7HQ8iknONzJ/MHPMq/EHfGoj+so0JNP5Cqn/TR2diqpsVp05MPMvCcWoQAJmceDLlCLU2tnAwzv+qcWQ6t
# DATA CtM6ILDM+SdvlKlQGYW09Or6XjpCsEjqOcIt+ysrFLNCgkdYREuZD7gjDEKyd0oqt3hHCDDPPDs4ZGePdRiJ6eRoWHvnZy1Es5Kj
# DATA 7AIDKsN46mw7Ybw3k7MB2n5hLsBFkkOMAGrkUdIZDXJjWjEyBiUFJuIbIOxVtzdmO954bLgeVvZGtQ+UsvGNMjZ6+nPOvRjWoNs5
# DATA GoU1DudoDJwkPy+vLQbf53hxiNskclw/4vsA17o0uWYw0ByF1yokc7CTAPMN8+6VZhQ4+JPhQlyN0ozr4c7ujXi9hUAOdW9Mxr7G
# DATA Y7Po4mtWyp+JxU+REsFeXjtwfSmHODPLtyXEcb12bqCTcRqbrouxY8pBQVtXW64x89gKmrBKAnxQi+TZmfzBFLlVsLwxXr0Zi0Hv
# DATA qzOOHGFf76BZFiI+vijkf58TcL+7Qzw1KAZfTH8Xpk5itoSrbG2s020YNYCF1Wp59IhZ95+JqHd98WfJOkoYECYkCmfaUzKS2p6K
# DATA aA72oFq1ZCTl6zTlbHJC4xKq0TtYtrlpAU/oJqZJwb82et5ZUJ/XQCZjLhZpfkbUirXzzDIeZYDTXY9Y36KmIEIu7Weto/DM9kkX
# DATA N/Rv/eG/r9//G4HO15gBeKr/9/LS8v3lu57/99LK/T/4f38j/5U4ZSf5mB2vSSRyMbZ8r+UNa4t13twOMqXauzodjfqDkiy+J+PT
# DATA 3g1dvWvR88kofT7Is4sSz++0A7RdHnT9Nrl/KWPvwsKjjb2NJ8++236+sfexovuMyJUyyyNYwlwUcjfaQAcmvcExymirC083Pmmr
# DATA Nj78dG9zN0I7FyczH5V5urG99dHm7p4utHxv9X3+tLf59PmTDX57j1/tbu1ttj/aemK/w0ddG633rNY3P9na3dva/q6uA9/dD6ri
# DATA vbXA4HSpx5vPaRneX9jdgxG1MVopKsYb2v6Wsf/Cv3n2Ymd740mgQN3y0JDCxGEFmiK2b2Fn89Hm1vM9XcC0dJh0Xk2G0sizJ4/b
# DATA u3svPoQih/GDW90BHTI6QA8f4L9RD9BJ63bav/3wATkhAn4ZYfTr25PxUf19eEv6z4ciDH6wyI8PhuoNcmImSMGDxeHDB4vUPNrQ
# DATA bz3e3N7b+mhrc4cNQTDUXYZkS7yf1D872Gd/5vrB1VJt7f71S0x59vHmJ4GyR2TEcW+Ny1Bc2dJSqytcavOTvc3t3a1n27sUna6B
# DATA oyJ/0w4n7YAloj/5GcXOaYwvxvKaqPS4cSHlz9NDuKrZEVB+8bXOMbwLi83cu2Hki7mo28MkG+UVEtX63v1X13ZM/ZphhKl0KLI+
# DATA Vw3pg8xo4scvnj/ZeoQHEaPGtL+3+Wkx+wHG3ncyUzh5D9TYcSUqaENUbQa1O1Z4GY6SQAG1qsFUrGSK1KUQNsDR4dkqetRY1DO3
# DATA NzjEnM+8hm10P23xb9fv8EU/05FxwvFyatFO2pmMchP3phg/p7COW9vf33iy9ZhWUaVG5ETnsjwE4jyvCS9Su4nVUHWM9dxEJcvv
# DATA k+wofvmSnO39hOP+wF5s7258tNne2N3d3CMQHBuNJEJjG9DbPg/ICyrlYnKYD3oT4FCrLFsY0RcSJ/AxlJDlyjWDQyXc9b0NZ8Yq
# DATA OLDDFtBF/4CiFmCTQd9F/MBZtxp0+RqcThtfN4DZyRG5VOBbsLI3jMp3moBqfzwc9X+cTC5+3J/0fgzwYn8ZhvXj3nBMP6pQ6GWj
# DATA caf6HRkVsv6NrSJ/eCSjUEpRtSqinWnkk6Oj7AKO7znybEq8YoBQ9Q121Mk1L6euOyC6/sbnztlWOXsPo5W7q3NcgcfPnm5sbYcM
# DATA yDUwk7ybkiumEev8yXHW7SfwqO5+kneyDJ5loeybbF/km9xQNTz7jqoDz8HyKPIIT3daiA05s3AkbNR0b/lafaFTAqgu7VWnWqYY
# DATA x20sa0C3stFroI3eTRc+CKNRbiy6Ny03dq1wGCggLDB+SzpLQQga4KVzT7k65Mhl6pYacNJOHJfusnNNhJl1rHFhOkm/i8mUCOHt
# DATA 3xlh8NEcHYuNLxj6F+PjwRRdKiVvbZnWGj3P3FaO1kdAJGwPxh+hLDkQQ7WQJ0syAJKF7pPt71WwH8c69xiIpTGATfxAKXWY/MV3
# DATA 2eGEM+ksVVH2f7FmR6YLrhMt0O6nT59sbX/PTZRllomM22ALlD5GD+/x1o47vBmd2Zuysf0IyOtnO26nlUHOsS9RqDBEVMJqoPIu
# DATA g6ZadgltmayG733UTX9/75PqPKv1g50tsswpmYJZt5a1bkbVBFQrynDefjVpMNvP9tpQcfMRjOPTGw+EhFJs8VuwDC+cO/WCRFJ4
# DATA KJbnHiG09+LJxg6xOy5IwXEpgKLSXIxPXAhiQxoj/ipcZX2R97noHftCH1QLDsrm5oYl0u3T5FXa1utV0eUpm8Xdu+W3hQCVab4A
# DATA rah1mpTVZiHZkbM07lB4gtYhIb1am+cq9BRgMX72TLzKI0rTelmaSGp/ilwU7qrZsgaH2NUVCSm0j7ot7pHbKe6kzA+F0/KeYtSU
# DATA HwBLjsqO2C2leny2/eTT6McaPA7Q1smoIRkoFj5/uLW9sfMpfQwpKNv0L/dM3VGQ/UPWVwLFkSanzaJzAtYnZMAlGgif+4NKdbor
# DATA Bld3rpx5ZS6d+178KwL5ZcO3kaQSlCbWAhbCKMloaS84UtB7cMd1KQ7mPWt2EqGGeDc1MDKwNWPO+oOaNwX7mfKzt/ucVqhCvepa
# DATA +okr6UddZwpJQPN/9PHG9nc3H7tACAcLJ/GPPemYcNHmTjW9Q6w9xx0dvUJhtzQKM4O6xIwKrsrY0muGDzQ9aRjvq9dVwhyy1BmM
# DATA LG29RSmpwxsO8ePzFujkRMTX/nLTS6nVOcnItNP0gWwLNa4vvBlM1QcXpKCplBVwZkE9hQguffzKmkHxwBvi/7LY5jchAXiLzeDC
# DATA 3vrBxRBg6MMcnd0JzSjeIbwvPTVOv+7iBpWrJfD5ZgrUmcejqCa1r7C73tYX5zowkuJ7VrBTCaIt2ROUDSlJciUklDJ5IxiZ2YLq
# DATA huFyalFBAu0wogVuYR5ulCGbtPl0a3d3a/u7RZ7UGa4OoSjj9gVkOvhE/HJEbmux4yxi3OhVtyirwucCiuMMVpyRm0QoyuNcpANS
# DATA wEhYsCP2NqMPlGld3iL+m4HlFP/qrMlj+GuNvocpzygjIvexT/ImHlbTzi6bXmAA8ZwDLSX5mC3vKlJf7mWcnvlJhj2ZiGmmcTjo
# DATA YiIpaOrRgD6TLIpDY3jFGiIqEYMjwLbvYOqI32QuMos2Dt/v23MMHI4qWJE2QKq9g7GMknOKy3Ix1hIbWzwbFrLuXvbHyUVQtjoj
# DATA o9JNxhiQ55A4JzlHoqZwhee9mzbhJUQXi7qx4RKBGsujORks3op0LMTVLdQt5J2T9DRRlrI5iyzpNGGhffX9wHfedr96F2uulVIk
# DATA 1OA8FyH7vozhoGQmWFTyhRZE0viNJNKOhu0NhxRQc0D7xCNCNw5+rBTH6C02vJG1lnzHqIZiD1FtHk2eoFlP1r+AtYp9YL4VNgEz
# DATA YlKjsrJFg6osFdNPRq4X6k8JGb0+UfXidqneNlh4WlVCWvUeD/tpcpGdTk7Lov1hX4NRt4LaO9jAaHWFOXN4lAWXlrSySTXImezV
# DATA cmLyCcxI767q6r2l6kG1+gbAxk4Xm4mzFq4eb9PBFGhNJaxDgJ9X1Tmlj/qgGr3vTUZIFZx0tr0uxSc26YXVsWV6xfK+oP7D/hes
# DATA FQomksKXjQ7QX9hVhTLgSqfFFL/SmTko8cuLpSUSy6pxyCmRRx94KwhpFOBzkNVTF0hmEV9dsVT6+toZjiLsaZaWpobUrtV5aXpu
# DATA ug2A59Hmx8+ePN7cwVCse5uf7Hkj4ZWjyKTeurqizDjrd9MLHoVSyvBRxEVdW1oLfwpCj6s4OcSIokqTTE+LVgfXnEYk54Cuckzn
# DATA ks/tbP7bF8BcPgZK9bubu4Z8XLDFQrmcTm7XMb3GJJ5jlZ22qh339PF13yh+pO8pC+nYKmEdy8BNm8hJN+K5ZoPkNuzbkydbqPoq
# DATA qp81BD1ggFCq3vBofSmyfwUgrKmhmp2VvjINP1SvbSzkcRNM6MF9PjDiMDKuZGREWreCBh8XrKmugKHWrStSI2MLFeeJm6lFlHGd
# DATA rQirGjQULo3xw4XWF4rKpQJcErtPG8QqKCXp6OWsaB3gbLDh2uiLGkutFePnyem0BqfXfwM6bmdzG+GCTcaFzg5vH1kf6XXHUHsY
# DATA YFo2kl8j/SdaVdlmm6byjokOoyctKcDh0jQBpcv3tp/9YJshq6Ks3MFb5y3fV80f6KOnFX6X/Y4tCLNkXa2ArGs+GcV08RWfs5vI
# DATA w4Jy56DkggRJOKWQwCHoDzlNaGO7IjLJXhDa3ECa/YMde7KOj83mJ4+efO1ibhH9oG9OibBbhL+SBg8ZEv/TUW+Sn1SciJa83gW5
# DATA sSwh39+ul5CETqidoEEsDNJ+jrlQSKnP1tVsfd4GeKySpOcpBqCHbcpbGJ2mhkklOPzFy75lJ6C4ThkHVDjNOoHYpCU7Z0cZpVNr
# DATA mSFahna0VBTmmhKA4T9rFcoAKMoRXksr2qe3IgHx7RTJ2/zXb4aYcJ5opNNddUO15WpbtzwfddrO3YWLlI/bJdfZQKOG/SkUFtX0
# DATA WaLoK4uGqj4Ehf/Ogr87/dsc4fBM/FZr9cJiS7hpyPsNlEJNImjwLPDB010wUzgYl3pXGt0F5isdda3g+ZQCEB6XGNgBSuGo6/vS
# DATA EXByvFYn6LMl35suFzRCF9whgUkp0BgOhpWqd+BVWdcZwkEjjo5lBqYq7CC3X3phSnEW1/tasRZ8HWWpIIqc9McjCx/hVO0nKys7
# DATA kXQys+LUpd1m0PoMPxKRW1rKFpLxwQACi5lkz9gZhU+0xQ+joi1zs9S2KUyQ7e1sFtWZ/p3CfDgcWHyRZ0IbFJ4C65i4FGmZoGZv
# DATA cK78fPOQH4+5IRik7CxVaEA9t8cDvoONBH3M4OxVqmULON3QhTbzbex/yrQ24cALZmK0oypLRCU2fsI1PetqeX11lVV9oZLoFKCK
# DATA OVyzPOzDHDqnEoWgqMsDpvZ1hl/NqcZ1b3gIDXR8r+UMpbQ05wSGg+SlDy5v/+swhgiG3HgLA4nQfzcwmijZ23doSHHL3R6yW1Av
# DATA sv6ArqBjx2DXgMdqc6Zt5jxmCeX3UFLqolOFM/Kp1Rjh6sqzx3gofv+2Qcgp8KgY4/VezbRUnW2KKvtDLc7u+G0XyFydBkevq1DH
# DATA syuZla2znHeOeiyk0gu0/DVv/nzmNyUD/catb97l7AvohyKNGcxTnI6cASu5enUGa19KNt3AUEEoZA9kayZOiciEPHKTv2sZC7pD
# DATA e0IWbS/thHm3rahDUUg8ct1RN9r2dkVvNzftUpvCNMOoZGzM68twQ9/0uCtvqMl8lfVZkiqSKBKmkijK6NnwM/A2RX3bm+k+zWvq
# DATA nF7GoXQWfneBKe6bgc+j4fOrFNxLtISQCspCHNCqua8CyhwuIAJZs/aFKWj9llMhoOcq7YN2w5vvx5ufFCdK5eZyQWDb9D0jrjSS
# DATA Z6GPsn7kDLioGAspxQI6dmpu6uCpxI0UkfbI5zA0RIQD4AGo4t7gEgNBhaSG5ivwMtpP06GAT5PRK0IUh6EDXD9bVimGXEGSLb/k
# DATA Jgp2SZsEfjwfhqJfhGfOm2L8WWqPjiz/vqlGEKcaF1wrnqcjiowg9h8Bm49ytPPhi91Pi3YeDldv07Z2eKNpRHVARhdaIVsa0R/H
# DATA gUB67PV8mp91RuPCV35NDrlAs1iIqKY+PYGT8eGTR9+r2Ra85VxVIV6Ww1pYkZjsrpx4TLAu1vP2h4XNkhyN72CTtJXlzU0rYSwU
# DATA xaLSS4/Q3y47Phm7iDa/zBsIiQHWnNpWazEg2MlFXMSwdPU4WlZ2KFJgdqhvPHr85EmFAxVP8rRNjvVWAI+jSV8l8VNHSprg6Hhw
# DATA QJLxChwrcqpSg9S1CjLEwoBU0UYyOqYRoTROxtZpU8A7/YQGG+2h9WLG5wl8P3B7wQA16OPdchopykdx7Yk/xB9tJetVX3lP8DP9
# DATA ageEqKrHitMAEcYi0scPdMOqNacZtxR9UcVWKJXqUihXHYlHJNxx15of7BpvqlHOUQF0IqX3jc3tZ7uf7tYieSKYpp+ePd9+trf7
# DATA 4vnz6yl7yBdDLk+lQyaqKPkDPKrfGBUKBnLREe+tpL2O9Fp9NydRIRdd3hMLW19CkuGwPcUmilc2MJEty1p2TeS/+S9Z4I7MvFyl
# DATA t2fmDQrOZmPv2dOtR22lAAZ8236xvfH9ja0naAJu2/F8I9dt3itXuHa87SyYoZ+Fq2cfGCxmPbdLFEf6KnpN2tdMDHnlnhUbdUvb
# DATA Z02qLPtRJo3z5LTrWNzVmddIR5sqRdCkyyKiMnTNFooo9s3OE6u3ZOVspYB3G0WfdEuZMjf8fWorFbdXRYMMjtpBYfss8tJVfGqz
# DATA EwYUlnt/MC4iqxpMY2qUi1HMveUx/tZEKbJzDrxR/bWsRsj+kd8j2e83notiQZU2Fh/yfU5n4Q83Hn3vxfM2hlCb5vxMsQ6LxHpY
# DATA BKDyMvYB3KG1GBlMWXULmuigaGCUnCs2u4RHcLgDExHGM/WYxvkXY7OrIANOwgSTiE4bLHVSoLScA5SMOieoF2iWyR+kAIzVjikz
# DATA RSLxDmQKZoBahFCTQHnftCxB4uUURArC1JuBUgvFE1cWEWN6MAaXrZVL7BhK7duMelEcoRaEluzAufbakbggHZDSs8UDUrBanV9C
# DATA wDc2tikZc7LMLXCYZHY98I+hXbjkcgRLVwOpDPSB9WABWvrbt5vAHYymAD6JbDFCHlmYWVSXgC9XqFrswsIPngjP+COEJBfsEjlC
# DATA s5rUuewWFqlF48GrFEjIQa9bi/rpuQR5VFmS7BgRah9CoG3BRFwvGTp7H1tdO2SehSJMWORueoZratVxP87FlfIakzzs0929zacW
# DATA DaiOh9MFHJaKFScLTYBoiSyzBs/BW5ohT3M7K/C0nbTEOOEjrZ1MgiVdGKyl1hqINqNlBUebU+FZrUB82cCsGYBkChI36cgUq/PZ
# DATA b0Zvc5Xs/BZMEyn8pM4ZG8s4ODQ+Pz9ntzM8hAC2wicVC8CHm/keC0L01pfOBfyWKyT0kmTrQLLBPu2YzKPXlWUDeio9h9944Zwl
# DATA xDK772AFvVbVpsjdjvly4wv6cW37TenTRLhZmd56MfbuRCuzVlDXsLXtyl7P2Tk74B0bZAZDCDFNdJT1s/ykDJ45clDhICwrV879
# DATA 61NfdHIsi8jkuFDEMQ6kEiHIYOUMmgeiFLoOSh9diEp4m0+/zKaqMyaZT2ogJCaBFgJuwCR9UOVqaml8+eN8A2hh+q5z6wut0JTO
# DATA tWhPmqjxqlcD3srMEbmIxvY4lE2umfNX9S318jyYX2PWUeJmfgQ3pE+2cqVn1hZJSvGi+k99eGMNoDRQK7mOb092Mzhz4ZhALQFY
# DATA NQs+aUrcgJN3R5PPobajwXpEKkV8LGqxuGg1TLtbkz1QYfLtUxCi3ItMdIianpOgD8eQ8yl83IWDWqQfeBMCJH9wtXDz5iDoqVgp
# DATA E8GbPDcXIcV1r0FfKS+0moGSdpzOWM1btXkTjmNvZ2N7d+PRnvEwUlHYQwpxw9QQVVrKPbmsgzTEos958IZ7MBduQowGqlpox5CI
# DATA BrPMxHrpxRBIWfJqtM7BgmXlWDzsEiieGU+8N6qRt9yX9jzikVmMSGcyIhlW661oKNETnSnshH06eK8mz2b7Ve7YHJPnYHltT0IZ
# DATA HMLLWWBD1fA1P2nuu8mz06PDYtadvtDKtNQAZor9eV1dUpfTAVpAZ2EaITJNlmSfDocMuIGIQNrq6rXXlI0WsJYCJ0sOPMqOyYHL
# DATA vVpu1QVXKV6cF7dSnX7ob8jtmzt2nDp0nNpeXHV81gsR1INojkhmanND4TG+wTgN2ej2Uov8C+CT0uFrgvyGN0up4J3q8rmbYxlg
# DATA r2moptMAjUv0bYAYtUbqB4IrJUcLqnruX7fpHtwbDNKCQLXifZgCi2rBK0NzpnW3j9uMhbe2aIqE5yZTCUzABoE0wPmwiuhmHj37
# DATA /ubOp+gG/tGTrUd7cXUa3NLTnX29itMq7mRxc1jXWQKy9G3XY6K0S1J5JrScOuFvEjdKgVsa4bhJXcux2FxxTgO4yadIApdenK0M
# DATA LTH1ioo0wpQW8We1lPixlXW0vn5PagTCrtkaQn8rhOm7Eh5EhEYKfYbOrpHvRPFx2k9HdCShoronntxHWyo2NcGmbRdnECPXiksG
# DATA JnmcJT32kFa31THDkZflfmjaJCPs9XUT32Qtc7iJe7Ia4Dvy9XLENMrH4ubuXaz+0AhC3PzR5CrkuHWUjcjJpI9ZoaSEby+h9PxU
# DATA tDzlqbcpfk0TEdEOioFsY7Hr6dbXBQMZz3WLu5vXdSvkPvKWAZeLoXIfsk7Q8Sy5xea2KktGdc6JFqR5zoYj9WStb8ExSuRbGixO
# DATA aSrkEjbfiBxFc9nAnLmTUE89FYRxerS1YnC86tvOIOQuPI8fwDQbQwyklo7OQra8bgg+JTPwkaqrW1woWQwRUlaLDVouuoIM8MsE
# DATA c4HHenAoY1MZvZqR+M9bjn2MOALakHeHDnyEI+805rJRhqRglZgaFgflx9doxSMAmoNT8g8hn3MVHMBi1GwV5NRIHOg9jgJHaUrD
# DATA psPBoBcwhVeDMGIx/YqtAHhomuMOOgToSCFzy6MwhM/mrg4sZ/bMMdhxFG7mbhhRTsDEXJgxU3pe0bVx/y5Ir2FVQoJrxwWdl9v4
# DATA uUhr+OxTBrrQNKrCBkzB+0mlbFa+VW4ZVdANcYxEHLFFyjmcyIKlr/Z7ZVqkzPxfOUCdpSL+mUdZpQel6vnMirXIQeg9B8jgCBsF
# DATA iKF5r6A7lw0u9OhchxkXJliFrPcHNpiwisi7g2vf18M+UG98gOY7RDcSOwbwQIjNCMwiLEItJ5vnHzxL6wLnl6ksXiL8isLhK6eD
# DATA Mte3/QPXpK02Xy3t6TeFeKj51fUXx/2vdABTj0qIz8d3EnnJWYw3WeopgZ442vYg67AZcdaFitlRhvk5kTAxjxIBSg2/MvuQmHib
# DATA SJniG6u5VquIx6tGkJmnPSXXr8yJ7z14w/hfkv41eIoVmSmHJNMos2WhTKqlvjicuxpRMBzWjUNi2QEjnbhYqh8rLpbx7X+VIgXh
# DATA x/Up6P8DGHaqFYBPw/pmQiIk8tJR3DRw5DgZAYtD/t44zMWoEB5DMBcXbPgxSuzgRVRCd+zbtZqgWGtr7nglQIeJJHclc7tjx/iR
# DATA EIIAVjl/+HHaGB33BoeV+E5crV7XMBZfq5ecHnYTKtb0M4nVVJYQ9hQISWL9CCn9VMReRWOdKcZQjv9qUx9S48naVJRr2O1ZPBqb
# DATA KtCfB+TKQm86wrbZ5+C6rHcxx7ItLxxA6Rj16BUqseyZRzQXtOxx1BBaSnMrYAEyr2u5Leu+qRlj29FPWq8K2QRt6kmgXje2qMQg
# DATA biEAFwufEyS2AnZ1ZcRX2eFzaKvAnAxVpVbKJqpUdEPKQ15kxbhgTQsO26a3Uu4rGCy9WLvcyiBQfG6+6bub25s7G5a6+Gtlnd6U
# DATA uzBafGtEXKrq+U1IUcsrxO5UBX2e0z5CNUZOODfynojnZWzQsqiUj6w6LOO0cmH7p2kBe7SdQPv55vZjN96t0WaU0MA3EdwUFReB
# DATA A0vzm9MmQlqaa57mfAdAoaijmcwp17iHDBF5XTy7EGe+urBSCCLeVu/QWpZ7VBN7K123wKNu29uXoKW+sMXc+WwrHOOPZHfhb5L7
# DATA 2d4tNWefOfBG7PQ3k5o03ljzojA5NEbPWPPGoG3znUs/Ha9x/bcUCrgCAW8ZHcbCW7QSs2Rq08FyZsq2yICCQRdQG8n/gIQ9c/NY
# DATA Ar04IkMozrPe2BgdT3Cxn9OXihXouRVvMQKPDif9LqDxCMBf0osQyCp0kRNgHEzGEa0byrUwJwKOOW/ohLrYMsYYbyfSWSWu1+24
# DATA ayiXbD3XYoKyGkxtTi1jxVmBRUhgZbQQdWo9Xr36iI065xuPUECIXjq8YExMjOHgTO8N1+gNqsmxmXuACjzXrUOk8DAFWJN69Adr
# DATA 5nRgqsE01fi5gQMv3H++wEWWn0wpqJoMvGCUQx+dLI5G3Q9fQujFL6PIUPUsIvCpejeZNnvLmnWFufzpBAaTR9bpJKAYXMqaPvv6
# DATA KOAovHNaWCeH5HQXoOasVq10EeRLUFRa1OLPXmezZvOtl784Uj8xS9iNJn3gzXAl8chg05McoGrJmjgakeCaKNUIPRjVhH0Epq3K
# DATA cJTBlbACL3PX80RerhZQx9IsNVYgLkhhAFcxlRCkQr+R6S+OB+hi5HNbGGcgHwM7PyoMaBlAvr6uOuEMitpMkhUrZL++qQcLYS2q
# DATA 0wQG8kfGlaIPtdskyGq3cTfabbFCwKEBfTuuEM6BBfvWzf9DrEL7r2SHjeHlt97xf0vw3721NfoL/zl/V5aXV9dW76t3/H55+f79
# DATA u9+Klr71Dfw3wdgR0P23/vv8z8+9dnWbxVO3m8u120Rq3G7uX93Ourebt4mwGwN8gKtyu3abslTA69d/99VPvvrL17/86s9ff/H6
# DATA V1/9+Vc//eonr38evf5l9Pp38Ou3X/0ZvIM3r7/EX68/f/1bqGwRPNjE/wmf/+X1P0Lhn5TUqkXw9y+hh9989TdQ5PWv8RN0CkWh
# DATA yV9hb/D/v4K3v/7qZzCMn8Lfv4WK3CIU/+1Xfw0ff/H6lw3onkRYt5tXt1UOFRjEg1vdAYWBoKQXD1++7D/AH1EPKKzWy5e30z78
# DATA 8/DBSZp0Hz44TccJZSjK0zF+JOkZfacveGnx9VmWnmNYJPipJGj4+jzrjk9aXaAqO2mdHmpKE1DPgdhLW8umrZPxeFhH+H6GVR9x
# DATA K/VdzFuWjS/rzwe9rHPpdSBEWD0fdaKXcZ72jl7G6xEvuf9yfNlLvXfZ6bHzhkzlmuvR4PBHsP3yqQ9ICwsfJnlah7FYrzAoS53J
# DATA LPO2uDrWIfDGvxGdZfmEqN5xejgYvIooXQ1QuccnyJOcACI5GfS6OaHC8QlQxgmgxSg/RcKZmQlMqByhtBveA1o6jdIkR/XEeIBI
# DATA sRHtjifdS6o7GHWzPoZdkkiyQNAhSX2KASFp1HTUHz5H0TaSN0doPRL9OPq3kywdR2eDHpB+Dxa50AOy1xmlPZxG1uGZwXCP8Hkx
# DATA yeG85Iv4vpGfHeM3oimx7Ck0vwgv37s47VGvdku0S/lJmo5D7eEWNDp5fsNqpOdT1XgrMIR+ociPsAQS9uno4YNFLgg/6CbgNcF0
# DATA f3RESAiE1W1QQa3DZelBkzSmV9nQHs23EX1hoV34gLsj5+DBYsK3DXu16h8iY+FMx6j2sBl3V6CNfnIGNEqW1HvJIS/LU6Sb4HV2
# DATA nMjhwx5K2nt2lo7wHlNbVqkczk+W5rrc7jDBCxzJe784HkFddgfP4/lg9Ir2hoouwnhkUXHCTBp2sapanweSmsksxRB1PViDIdPy
# DATA w72TBLZwiDSxdmiDIw6/gVbrN6D55YcPhlAsjbAuXI/L6CQ5gx+DM5TuYua/E7oAmMqRPuNuEJmJJ3XQiKAusM1kDgeUONy2MV6x
# DATA y8EEtw4rK0GVurrQ6/Dhg252ZsbNoCH3T8bhZDz2Loy7FR8Ckam6OUyB78V4u7LQXiuoHhz0u3Crnfbm2bRFGCuec17twLLLC170
# DATA lYfPRtEwg4FNhrBIAFqOJrAog0EPl3sFl/tR0utMSB151BsQ9Z8mbN8dEbSPuqPkHCEO2vXhCsN+6cMRdQcpb2U3HWO0QuAggHad
# DATA 4N2CgaPelwLXUCCjzgBI9AyF4LzqNzl/er6LeOAePjgCUh5P4tC9UXC67KVAqS9zCdiuyR0F7UHBh2rvnaGYRGRYZ4Mg+x8lp8N1
# DATA pNfPks4lDij6L/8S3Wj8vGtq1IsIlPA+CS4HpG+6/QO2/wO2n4Xt+Vi+AZJ/xzj+zVD8bAz//yEE/47x+1zo/WbY/RtB7nwi7elr
# DATA hP7fzg0igD8bdwKkH+SpwqAbCm2yOA96JOyu8Kc9ZaRrEjPNwZE4QMLc4ViRWEW2SJagk40I+ZIAz1sIWh4iaRQKzkmc1kuTEYXy
# DATA PwWkDSerVyMEDJPITtNudDjJemOcAcLHnKcMI32RYxWittT41AywB4PRO4oeyH2CgMmBQb932Yi2xoqG62Ceb8T4uHCAtkjSbNTa
# DATA ihRIuohhSLxIQ8RNqRNZgHc9zymOUbSbpq+iP4WzgsZaSrlwkvaGJKvCQUbJ0RHuEhIkyVE6vtQz/HQwGRkcLVMDSiePRpO+JjUP
# DATA 0dgpHTWiTUk0hEuK85gMkVpBOlOdQjzjOdEwUABTKAyQSALwkGOZpHc5zjpE3cDc0tEYdfzHMIUE7S+UaRu21TlJO69I5EmqHRJ7
# DATA OoP5rz/533KZK0p5yS4o7wyG0A7Rk9aeNaJHuP8R6eUp4gVM7BJnLm1hDRzqGXaRnsJOHalGSeIKdz3JABb10hrRgZjFBAllXtu+
# DATA GTnciTFtNtSBEnpFInIMkIM1fPh4cN5nMg8Xki3LOnBi0GLNGxqfUy6SIxEOQ4VbjhCuk/JBPxnkvLVoUzgiEv9Vmg7NpU46HaT9
# DATA ewO8DJ0OvT/GhjKMkIiBl2gxAXtgO3kj2h5QuQntGhRPR7RluJb6RmGjQxzwSaqABByfpwhtsjFPAZq2rwus2AQONx1zua3qVqYX
# DATA QCziFM+hMb0UR8S8OBu5BSPWhks5BvdAa7wuA5gI3Utgh0aZ8ivtJjjERvQhAh+2PcAtGSFeTAG2yHGFftB/i77xkRJq/43ZnPmQ
# DATA zVwczpxk8jdG7L8Jrf8OSH2XaAJ6/87V4eACyJfPMH3NIZ3SOry5xkpXQPEMer36YQq8cDYYNfNTaPrkGtu9Ok1GcBqaS+uo4Tge
# DATA oeineZaMKvX6MBmmo+p6Z9CDKvwK6LLqOsKv5vL94cXicuPe3Yi/YFvVdbQyB5B/Xj8fJcPmIZzAV3WYW/c6ueJmsj5ckGy8jrH9
# DATA 6xM0HQVaL60Pjo5gQs3Gykp6ep00T7CdKyrTxVwgdEnqcPg7r/pwd5srw4trPiS1rD+cjGtsv1XDGohrrmiI0pcq2eC/V90sBzR8
# DATA CZ+p66NeerEO2OK4XyeTv2YnxTTR6z+C25kdXdblfqnXwJ8C0YJ4tbm2NrxYHzJx0ISVAJgZLTeW8e8670BzeXgR5cDSdCNr/QoL
# DATA jcCjP3ZXGuarXstujpJuNsnlMz/UYAS8H/VzHtO9u0vrwErl0M5wQPmu171lbCIDI2vS0FdMrY55c2UNE8BUP2eLqcJxkKb2iUJF
# DATA W+487bZQ6XxwVZgoTd9ugI+YNNGEnUGs0r0aDJMOcIPNxt27ajbCA8LhOAICIa8DPZghBpKq7ks6FN47PiLeS3Vg/LKTU7gWl+7b
# DATA K7jaeGKaq96mUik4+/xZnWXYmmseB8Dryj6xSITG4VYeVK2XuJWDg2rhDBMn3VxeWvofnUN3Dw5dyenC7qvz32NzdPHkNu5bB1cd
# DATA tlU1CW/8Neslj1+GuwJXc12GSr/5ENeLQASuXT0/GcFDc+naaQ5o9YMrNbila70g1iosv78EbcNhyz5Lm0Q5AZq6Jv5I3+/jUdZd
# DATA PwYw1FilmTnXZGmJSzdoSrpOGTCgZu5jK/79t1tdg1aPMOsC7P/V1D1Ss1turNxVrfICwrjSY8DiV3bD95eWdJWlqLEGVa5Plmsn
# DATA K7WT1dpQQHh9PBhC9ZNlhn7cHfJXSCZzQzXMtIz47nRYWWmsYde1e427Z+e1uw18qAJEX1qTkcqaVNd7QAnBkUCxKw6AvwJIoMwa
# DATA tXpjafUuVF0/TS5kDsv3OifrMqjDAdzPU5joKg16Zb7BLTM4ra3C0FZo4XFoy+/PGBqMZeUuLqfbN/W8yj1DJ5GsOrS46jfo1qSb
# DATA cY0LrKZ2737n5Do7Pa7lZ8f61FAmtHXrvsoBSSbjwTXzxDWyM2CMLlcF08UtryzBQa4hw1TBmlE9uocwXQ+EkZTd0syz6iMuEpcD
# DATA 7h+fp2mfTvJy4653lJeX7mqwopctdHKvGyS94LW8z2u5xmu5UlxLtWorS3AggngIeAl3QgQXiHrAf/jirQhqpb/XJA6ZuQr+PS3r
# DATA PUoYc4lUv4Uk8IFPejQ1pbLuXcvrBkqDrjB4AhU8yi7S7vpndZLBwLzX8VLWl3GX1zHjBqw0LnQJiNZgAedJLTMKusJWsOZ1A0ia
# DATA gQKOdc4ZeA/3zoV68I+2WUPYOznt583lo1EE/yuDb3RBqf2oAZQDdENzJRCryBqzpWt34SJw6aPseDJKNSFp3nYSkoZa7TTeXxmZ
# DATA +4mzarxP3QorMfssvO/VX+Y72hCC31uau0vmWFPp8JmWygSQ3CHMfZnsRQXwXQB/d+1RUkcRAEO3FCwd7tzVHHs5SofAFVZWa3DO
# DATA YVMqSzXYWQAbZkTXjU4y6l5ZmMXCOvcI1funMJ+MjtCFewZ9MZ0c5X6jYRO5/3rnJOt1i9OkIg0Un9capxNgSq9sAoHeQEP43T48
# DATA H/AanqNZvk0NfBC8U2Hy+S4A2TX43yr87x6SVt4+0fl0NoBkdu51KSHUNYLBRjxoyHNu9scnvCaVlX41UnMp24mVItV23dByU/+s
# DATA AxiAaSGQ0EUioQZ4ATXiR9SKWB9/YIsoq7SQ3P338W7T28hGfveX8D3MJxvPc0ZhMQXiKPDi3BJKanPdQNmCpvZWvs5ziT2RMqdI
# DATA Iirc0mDy7QY3cCV4A6ktNga8coAVk3s2nI/kzE05AzIzwh9rIY7SugurDI7OT8hZEqFVE5gygqJqRE2YyvhSz5EwYYPN1h0au3FX
# DATA Uc1y/VYYrChZZIDSXrNnt7SOpeqkwJFejByzl13NQW54PApADuCbsk56ZS+Jz4+p66iuB+PdBm8KsJfHFhGlh740B5rgulGC7Abw
# DATA g3McEudsRPppBZ+QpiteCBunuPA6WpqPQHNHGQ0txCyfckDu/eMrT24AFyQ59qUjTNpOOZt6g1aYiRy5Z+b9e0WmsuRqHiYebatu
# DATA UgG3enSBD8KZIJAmI2YKsUpz2eKzltcIUvJVMAvtC2+6SX6Sugu8f5J1u2n/wLlAtzg9YNIfX8N1u9JysAsi3W3eCPkD09/ajKtv
# DATA L+X7ZRfbE7sl/ctzFENfo26Ed/koOc16l81HQGINAC/XXsZPskNl+/500B+8jGun8Ifade88rGUX8HDWy61lWpn/PIos5cqTSvlC
# DATA K49eV31GDndLV1iYqFnXdd3FjjTiFWF8TIurNroPEZ1zEID+kX/fjNK6fdYZuIv4VQo4Yg3iVOaTTwLENtJqjxMtOQ6NYdbr1UeD
# DATA 89lUttDU43Sod12B0TXzCYG4vv9rAqDHKMKj9vxbcE2f1MYBiOwlwxyoEvlhM9D2CSTEPD6pjbvMltFaNHE0Dh6d6zCOp9Fa1w0Y
# DATA QXpFkJwBeHN5sb5MuNGSEVlEA9MMg8l4OBmTR4K/WMxTkZV+HdU2AWoW3dOS8WB0pdBuiJblE60AnT7Q1398mnazpGKRaPcArFWv
# DATA SoUOtqRh9R7CXpEquLdFaJIidqLDwl4UyO7yMtlnhvjTUv7Tu5SryLnaS+nyk1rocpdgNfFGNyLGFLFaPh678zALuYrKBpdDnHNZ
# DATA CgRDOVu+cqRkjHctKkVVfGjzUvbxXPHIZ0XGFs/F2iqdC1rDmqJyS8dDYhkWvRBW/8BsjsNQrLCYTlhNFz3MP/u5p0tAJMD/ECCH
# DATA o6TnPSSVZl4fpd1JJ+3WTwe0LfwItyOkE6PG79TuNNnoA34kR3hvkn52akRGBs+vk1IkC3xRw2DvHHUX+RrWlDLKF3gwfUy7KeSH
# DATA JfJlTZ0FFYgKEN7wEPjTV5rb8AtdXzsaQ2W1hRaC8Ce6OO31SfeJdnnNxcXz8/PG+WpjMDpeXFlaWloUAy80IPpwcIEFl6Kl6N4a
# DATA /D+pffHER2wACM/0MmJAZp5HVG95BX8fAQoim6nVpdXu2gdo+PjwAYUrIWuhp8v3ouUPTlZXzt7/eGXtbHnpBP59/+Ple585lY9W
# DATA jv5f9t51yZHjuvd9lXLIMrs16B4U7pjmDGN4GYlbJMXNocRwiPpQQBUapQFQYBXQPa0xIyjJtrZDjqMdPieOIhxnb8eOOOc7daE9
# DATA JkUqYvsFul/BT3LWf63MrKzCpdE96J5bSiQbKFRl5T1Xrsz8/+qDujyMKBZXRTMaIaMnT2SHJvI0mecUJCO1v41vzDdjUcXtneAX
# DATA 3jeX765Tm5/MVXvR+Va+o8fsAYhCXgs/MRvwrCzpVr1Go+nVuw2v1qyO6tWa53fqe/Vq2/Mb9WLGhK2wF1UXc7Vd9+qd+o/8dmtU
# DATA q/l73aZX8+nxaueI/r6DoJvVWjGoaDDwOY95uvCA0/+tRrNZbUb5xT1T9PWFlyLUjn/UqPnj6l7Nb+CVe90uR0ZFxPOlVlzyDbVa
# DATA 1as1/CO/Vh/5vu81Oz+qdTs/e7dR73p1n6pPrTPyq+29RvtHtVanmLxOvxsFwUKQ7SblSnfo16rjvVaV/jnCxwZdrjc6Q9+ny80m
# DATA /XNEH0sx77V61cZgWcwbK2uq2r5IFfUWThY+Up7gW6qGH/D8/pZqLAd6anvrW61mq1fHBeN9okf4fwfGoFm8Urv1rciPmlH7QPnY
# DATA bn2r2W21280DsTBufas36Hf6eILdzvRz2KrXwgNZ3r/18Sv3o8Mk8n74Nk0XPgyGZHtW7vL2sYy6wr0sSmM8q7u0jW5H97SP3ZZk
# DATA MuVd+i2xJr1a0encEUPA3G5GIzW/+W5EbToOKhJ0aWnuoOwIg3FWae83jo4rbXGEccBqp9wm0/u1/i2aqRZDLDvKbTNPFcziA9qH
# DATA XhwnCndNC1almJx8A8affoydRI8usDyQrwWIB7BkFonTqnox48aDi7a8EaPoFaiuNGYLqa0sJO0840559hbqGJsNV2mpfLrY1n+K
# DATA pv7xK9i9R51E3J/xTvIJb4D0/hL6Yt7tO2YL5P4n8yg9uc/7ApJ0J9u17jU3303T4GR/kCbjneXP3R2N6FHrWbWX7/vRCaQX9TNo
# DATA 4fvYDkix5bmld8P7+JVbdgTH0RinswU79m4w3eFADSuc5YwfRCcVbxCMRqjcu94jHPin/0oAIpPPe8ruSyRApH6bsnrHitQNaJTt
# DATA HhiqMNNV6KXz0ch7zduRWOwPgwwv26VL6goFJVduWRG45eHop2gRsNj+gfcpjir3hxQr9YaLhIjHP7VTzYfqJdkKFftIP57J4/qH
# DATA A5UXhfRnK9JfkXijlkwO48GJxlaZbMEWmyVpGeBw92Ikg5MdTJ53TVFEEKj9y52PX/mWeH4/foWChthQNAKidR93q9MZdCO+HZSC
# DATA HCbHK8MUY/TCYU7m45043M1T89583IvSHQ7zY4j+0a/7OjcLj4ZqE+mOyLkhcNGzoDd9/Aq+3qTmHE8O9DEXOePySh77eYro//CD
# DATA d/Zlx+UP+HgIfYd6m/c6NPR+jHB+UvEeIeBPURjyaGA3JHn6rVHEehkfvxJwNgT72P0HzZp0hG86vmhNFGNc6o/i/gNqU9h6+mE8
# DATA jpL5bGdnF20ckUqjIzIq8khROOC+k/2qskKigvUNXQqYTeDldj4lE2xo3hlMkHCUDR5gIbwxhD7eOqJIv6O0ViiMbN4bx1SQFS86
# DATA 4mK7Q4/xx32oxtDfN2Vj1o4qag6IpuM0FfoR6B3x7GRnl8Kf4IZPVVT/EtH7sRy4CI6in1Ak9+nBt4L+cEdt/uQXjchozgIRo+Pe
# DATA hSKEr4jPj3+i3vgX0gPGGf/d4Rvojfq5H/9ElxLlP3bHQ5dzV8KX6yesZMn379OoMpqHUaaikXeI9Cu9z2ySm93V0vYoYWvrG6J2
# DATA nxvtzgnUOs0zxcqPd75GFfO+JIc6GPmM80afHuio7uSPLykbri94n07ONrJKf94gOygBchcZ1TS13TlCLMAOvu0tvf2W9+P9ff4c
# DATA VpbdYQqKLOAMyeR4cPdqJUYiXcgi9G75MyZbzT70+TTUm8kLG/hVvr+utr0v3+N+IM9IWLylPVPb2XEmlAyKo2ifW/in8m+xepsF
# DATA r2IdTx7mFZxvyXSx0U8mU8zDq4tQHqYyNKGgEBHIgg3w8SvLdvLZ0eLfJWL8USLAxSDB5/VBftc9sXxbVkX55I1dR5UJkmvkWvbL
# DATA umjfUnH5GBKeY7I9pLaZKKyqOSvyU0dA1R79ley7ySFNBmH6eGzGe+a9dLFUy3RrWVGvDsyBiuU1C9Umrzeq7uj8gblqRmj+pnpy
# DATA uYFGfZpbsTHGt+jv5e5emubbomVqsp8zmfWJOeTXJBe9v/kbijUqBPVf4x36k7yTHEfpG5R5OyaLqSFkLL6mX1l4mqwkJJzrNU5M
# DATA 0H3VA89qEMjUYqWjC3bVYNFFiPfQdbvTLMYmr4mcll3vr/7K29FRu31bxwSR4oBMFTD5dvu2SgrqL26RZT16819wFKS58cddScuN
# DATA G1JQytjByqHOfv6Smzv4tit35MFKfqB3rOYjklIqkjLEDSYQ+W1X3VMaPiQsrqUcwyjjgYNKXpfoksbI7Qht0aoUSI4px7UNuPAQ
# DATA vQhxVNWUMlkHsluscbhRWRw7u7fvsM348Sv3zKEwNJMbOzD7Pn5Fmh6l/zvyneeA3NxnyT1sq9up7d5Agv/37/c/pv9N3tSz5CSZ
# DATA savVC2aeTzOWGxIAHzajAOih5e8h4+lm8db8XT6/6z9+az2oI7TBc/2xNG6ZAeYHMt3BbHcw+7yD2e5A9gt9INsrbDdW56Cf6YPa
# DATA xnPGPxdOAI6s49v3p6yWh5EtDgEb0ae389t5WzGfk3u2znM/L6cazxNusR2lHH/xON95lXracjPUi2SIhlmp6Mh6l7WCJxeCEX8r
# DATA HlQvL15Jk+4nyFx508mkr6Oh/Nh3frCw9sVmKtkDpYP/1jP8hdPBGTC9w0V7i8odejBUXrCH0tkJNhWb56eiG5ANAz4Rq2uUpzZc
# DATA 0LSQjyPPezSuefDqepiDUJifcDx4l1KcpPveD6bRhM/5DvjsPj2kDvNzZfUorCFqHdVJT7YhMIYJd9ObwViggCZKN2BD5R2v5OPW
# DATA OgJ8npijTdYCGdmHOJdmZHi+j2POqHA43c1EB+/9uXH3ehNcZvUjeUdMP82nMBuyfQ+2FP+YsUmVDODkoRYTwlJTzYbM5YQlAAbz
# DATA lKyI+aIawot52NaE4Kw3Z72dZ70Va5jT13H6Ohc121YaiFelu3MfW9gsOQi8Br5NCOcZBZ6np/G2brjE7j7PlqsrWHK8/sH2BxZF
# DATA 1JYcfY0LG52Q2LHsE9CZrLyAO+PdV8UnqhvghNejUEgSmnnOdFf5FfaK8faP/SZvItIa1pR83hCFi+OA9xs11WaSaMq7j/alZ7/J
# DATA cSxFVbwQpjrg2wYR1U+ZeJoLJpr1/dYWoymeEfpZe2n4wqviaFWR0veYSJmHXk24w88jV8Ob7/i3atVXbybKKizf01T3NNfc41fV
# DATA TfQhv+umRCtPirLVdW6qVTB6MG8GM1vyiMwGfoINiXRM7+U9wSqdajUUo5eumvkl6XniI37RlMbpmeTATQkC8yeVW7JOa4eSX9I7
# DATA 1MyVO5bBGWBCZnUAtjQVG43S7OeUKgi/GIPyXRoMqX8Wo1F7ra32jzE2mnDLZ0PRDLRxKnbkvnc3DD0+E6vMgkwPn7kN6b2DNRSl
# DATA 6omJgBlp55BNF0cvG6ViiFOPgzdiFwa9bTofjfjHOZZhaVCPU238/zCLRHlHRGxE9yfuxZTFIjGvRaR0nceCbcZRILMEhgWb0uiJ
# DATA MK+JM0wLKUkT6fy0yhXb6yMI31u9HMbAXsR6mZxp3MFLkXBpvPhWsz0AOsPZGc7nGc4lA8lZzs5yXm8OPwOKlR/S27hxZKKZF4Sq
# DATA NeRmc0mzEYOL0XljRcQH0YwKdHIo0nZF6UVhgiUDjFuJkoDMlRJFD7FsJJf8s9iuKKWgtiy+Oqyz/pwWctaNnWJcF5eZEamEBYN9
# DATA StBbDCS6LIadDAbY/gWZPu4LMm+YHNPPHpWQDJec1/ueMi4gaUmxO8K4i34mGXDHwHluyVeKz4qTUxz0ZgF7M++mGK5GZqQzKbKT
# DATA 9g475YI+2TgQ0jymHitPGUbePZ4yyIZoRp0Go4y3i8HSQRIPyRbLdK8WUuENqTfjUuJkyikfCmHCouJwI5LpdChzJzFitL8sGZPV
# DATA OFPqggGsggeeVgpZk843gxPuidcnFGUorkqUsU7jfeV/HEQRJSuMByztR7M7GGoQOMQeRuxDoGo1ky0YTDemX9AU8QubgN6HjOHx
# DATA mC+IANmyYqYsHINUFXVCjEXXm59IpT6ZoT5jk+iaRH4QZUsSKGZFoQovCqqaqk5WKvstj6EKj0o2QhPkUSeNlhmxKNKKtiNBeAvC
# DATA GGfvZKATO1WJSVLt/QD6LyFlItmFbPsh+bDz5mRM8BMPxOOqXcoMKUPtHss7xZ7UU2ktdTqI0zEvjiyb23KiPqS8kfk4GL1THCMl
# DATA M8morVMLMtZzvvidif9a7qf84OpIpoCangeZ2MLcO3nvanFP6l0Z9sCmtAJxGx8yNZ4HbB5jakCGL5V0MJ/F6DaClHW6xkp5ktVP
# DATA pUMBF0rcxmQh4LqaUqxM7fcnybHUT7QSaiLoIyHYqhP8ZsLhz7CvErktbZESNIUrgbtGHtvELrH8Cmj8VMrY0hCPDFwr5elCSsVN
# DATA 2Uc2EmWYpJCKHAeksSMjWFCQLXTDPEWYnJTVZM18wpaVtex8sZlfQGv/008rhqEzOwScNz2xCTr/39kvT/94+s3pv55+oRg5X5x+
# DATA Tf///Ow33ukfwLShHz6jf3+ziM75n/TDY7rpMe5n+M3XZ78+/cKjL78zEJ0vKVC5zF8B2vnF2a8r3tnf0nP0DG4DPecbetNXjPH5
# DATA e/pBmDpfnT4++5WOzJ/plj8KqAewHcfSeQ5mM+iUcXyJOpwe/ZkVRLMPo4TCSeO+NsH2vbceTkcyPo+4R4ykb8iG8ZR6i5HljdCd
# DATA I1YRp1HuM8jnQslopMYneqmW+V0L1cFyogpPtRSH1inOb3QPct1gnWUlc3V4nbzqmFth0uWXyw+MRG/a3P2OfOcRfcuEHR7X1LCe
# DATA qM2tGEwdYGfDYts+Ygdr7xFbnyicSu5iZOMXuQeHTBZFBcN0SOMJ5yPL7WczzFRLu5U1UhNBmEMp8WyBr3N+9Vvt0FzSsp4WZuf8
# DATA ZDjOjrMErsIS0MCdSxoAL4lz89oG/ysZ+zca+i868l/PwC/VczEfcgbPs9e6rgLGY+UAo3iKr16S3kWQB71uPFUriarwKM9SvFSB
# DATA byLJmkzlTcVTEtheOjyZDcccihww4QzaFMGjiixfiKSOeMR4mTlWaqGSPkNuz5R/Vo7JDYKjBKOCYs3oGOMFAjfh4ZQe1BaDOld3
# DATA kNsLQiyC7wdmxHEwmdlusX4ydYwdx9hxjJ2rZOxsOqpsNM3Z1Eq+ZpP/Mhb/Ngx+R9txtB1H23G0HUfbcbQdR9txtB1H23G0HUfb
# DATA cbQdR9txtB1H23G0HUfbcbQdR9txtB1H23G0HUfbcbQdR9txtB1H23G0nWeJtlNrBpel7bQHzUH/OaLtLK49b8Tc4dxVuYddmR6/
# DATA q9UqKKQ1G6Vcb7Q6RW5OFHUGCmyEw40UvT4HWm+xDEifQ61JMCyV4TdaRYhPnTJ8CRqp3fAataoHuo3f7I78TtWrtUrUnpbfbHZ6
# DATA i6ScRt1r+N0f+d3GsNE5qtWaY7/te9Uf+dX6sNE+qvvFKPRrYaPXW5KIZqeaJ8KvdU0i6sUAat1a2Fwk9lDGeo12bahy0aLnmAcW
# DATA 6DmtS9BzuMZa9Byq/AV6TrPRCS5Dz2mG0cDP6TmtWstvh4ae0+/0BmE3p+e0Wk2/c/X0HFXH97gam3GhLgQdPdwWblrmqKrzOFLp
# DATA Hh1XOmxJFdaYmv3hwcaknfLblIPbdm2JiaHuwtGC7eB27BAXcTtqotkxxirK+IB3cgyDMDm+VfXg3ah6uiQLgB5u14uv0G53Y5q3
# DATA Zf2kkOulmwprZTKcl2A4Byv2AyyOVoqStMxTK+u2a0JWXY0a2nRDyWtGw8TvfFeq6jNWU3wKpX2OjVjIPLswVWL05AVWiKPsOMqO
# DATA o+w4yo6j7DjKjqPsOMqOo+w4yo6j7DjKzstF2YkHYr9h3QM1/pH9TerObTViqoFLfqtwXdw9+NTC9DySfENm3OZgcOrIBHODngB+
# DATA 5+NXbiy+Q1XqAz2gqJcs3pjfog5o0F1s5x4oSNB7OMYlLZ9N+dEJn87Rby1Had/7a3UG3jqUxgfPUNZUoUwU9vQN9MNr60b8LWWF
# DATA sZlNUnlxan/2cJanmXrHj195xzp5Z5JB3aVKgUx0S+d83BF0dwR94yPoxQNh7iy6O4u+eGpwpd7ms3BGvVTHC63FFqdhzx8L0KIy
# DATA Z7laihK+jcMoyAroFj4RDWVLkIt4pMmoO5NzwlpJhbfSlU7LbnoGnZPA+owYy1mcT0mC0qvgQp2KHl+PZRcRvyWHQdUuq0X9emW7
# DATA ogryJ6UGr4TD9Y+5nrm5wtttIf8ZcTgmenFmZfVqlXdjELM0unwuarxbd5ju035qQaEdFiUOd6JDk/tY3HWVoLvqUjms76rPq++W
# DATA 4/WscsefVt/Jfa6Sme1Hq++TfpvTz5/WiMrLQVMt5y52qK3mjiFmjZZ7oSbAf27Luua/wFvPXZ2eB8gnneflPCuJbbJb3/QCYlVz
# DATA zUvnnBv/+dv/btJRjriV/1OWKEWfMwqmuf6qWkrkPWnpHBIJsNESlmKYQAmetaihVhpTLWQoUzCdUp1kfV3qmNH6aBI7mcnxf+ix
# DATA zqB/pHVoWauaFz+0yOwxVW51WFz5vOyWmZ981k0jP1htHGe4rJJickYfvaQL7AvmmkL3WiCAsmrrhYoor6gXLaC/+1+rC0hXeime
# DATA t1EMVJEzXUAfHifURlPq2Dx9yi9TJgj1SfMJPJE0JE33vbdplIeRM06ORJCC0sCCAxA2OIy4W0UByf5hVU6RVrdQpfXkpWJScG3l
# DATA YrqFixbLP/7P1cWiuhgpFZED7ScpTUZMy5moibBc5mlOjzVdWVdZPnnTAA0rFNNBFHwH1Icnx6qIinYkS7OzWVwYB63L8QxG9JOX
# DATA kp2iayuovF++cA/3m9Ulpft4KaqPgnTs8e6uvIs7xjWB44RH0MKmkjmkguH1C/R1kQz3k1CkNCJWj4XOdDQBBEdKQM0GehGTO+KZ
# DATA aHJgd6z9M1Mnnrx88mRcW+k8yQj0f/9h8xHoDQyyUSpDgqUDPma7muKVPlCWNjepYMTq5YE3ntP4MwpS7JObQj4ZGe39SIxHNcCQ
# DATA iQSGgTQblPiTl0Qhus9DU/mnTZvK/WQw83qo9gFKJ+/WMMb3KIvG0LKBZkyfRh5MDlgROgh/GmB/jqrxGQorZXs8HscjnDdATkGl
# DATA giz1T+axqNVABZGFVaQAtSL0FppKIRmXKqCiESgeTdsINFcku++8l2jfo9YU4tmH8gkmqVAZMUAn3InrglXCP0/CDno5xF0cnNu5
# DATA 0i7hSnOes5fEc3ZRXvczoe5Y2H+5Htstc24aSGfYqkkW5SE7tVaSu59RFcjnSDTtPG1oe9/jVVC8F1vJ1lneS2VEVxG9F1OubjPq
# DATA 2OJ8wSRo3/ONJDY7kyriOxI1yOPEOC5yJ5Oi9imH8BhQbiPzlxd0xZtngi+FLCAFg50RkoSsrIW9pNYofW6uk7me5qW0wN+Dp2ty
# DATA CGigAMZFt8dIgVvKghp8ozSzbhk5UZjVuaiorSTqsc+ELNaZlBbmPbC+PWzEhd7mUaE+yGY2ySzergpN1Ene4EW7UOcWcnj/ZTIe
# DATA 7SCc+ejMx43NR7uuuXVYtw77hFbjSiP1atZh3xXup60UnRMPnw6p4joo4bz3B9WLjw0WljnVTzleW926sF6YLyTly2Or1hbt5Q17
# DATA tWbV/SVHe2kpYdVTBfdvwae96omym7LsZl31XNl7VvYKrlw5LZQCb7JCTFGdwjjk+iALTa+9quUrVbGoe8Evlz2nwhJX50w16by8
# DATA CI5D5pq/Z1tUnubeU6du21TiMtOv3oAizpsKxieFBvT8IsSx0DRjEuoUPX2mLNVkZL8lmurxRGacbIJHeiZlIJLUfsxq1ZxNBQqN
# DATA nsFzb+qOBH2LPTx7SiCEJwDGZFdPfQRLXPoeWXcMxbXM+8opJhDuxgKNeuJmslhw+bxxudM4r2v53kJwPHUfRSVdKuHzGeAvjpVs
# DATA wQFZCikZF9iA/11B/L45/Zr+/dPpY2D4Hnv4xli+b8D6+/r0C0D5FumA/+v0z0z8+726+/Hplx6DAn93+tXZ/3H6x9PPz35Bz36l
# DATA Av1SIQS/PPslrtFv35x95tEXEAkFBAgyIeIgzwFYyNzAPzsY4PNg9Rf67kF0TLYDT6KnAaRrFQQAvfp4APmIHiS7NAaEOj6syt5V
# DATA WN2kx8wD1T33dKel++z5lF+DJsThkZHRF/9JNJtP1yIA70LqwgvnGTa7UHt2AMCCva97ievm/y0Wy9XR/9jCYsJKfmuhvpV55jej
# DATA k2gaR2Rt6PvfUhc8qAwBoZ2kW8YAsnoYI6HnMx7/1RktamKOBLhpEW4fBUh9DRbBqc1P4gE6HYbBM8QZ2+XS5CE0dCI+uyymPAxW
# DATA 1ELq3PozbGGYs/S//JipzSd674muaOJSJUucGTeYxsWHkwUs4ObVcrWts9DwnhYccPPEOEigsxC2ZyFoNOClDIOXwwl4bUbBFdgE
# DATA G5kEF7YIrtcgkCpazg5jBjwzreoqkIBWqtXy14ooargYuy8enHiHaRDOAwX9y/LVB8gYFtfYGDVYXJQ4kU2fWJo/YtcT1tpYFjGb
# DATA Rn2M/MYU2wgOaMZ1VuamBGeyj44ycAB8GVfAvWSwh8rJ/SzVoX0PKrY4PhuI5QAfHRPwVBwUWw3Jn6Z0KeO1VFXaynyTRUKOLN9o
# DATA sm/fey8CQE4uyKa9+3OYIWkyPxx68wkV00zOsPOLM4cRdBhBhxG8QozgxsPQRpOkixrU1zpHuMwUYZszBEcVdFRBRxV0VEFHFXRU
# DATA QUcVdFRBRxV0VEFHFXRUQUcVdFRBRxV0VEFHFXRUQUcVdFRBRxV0VEFHFXRUQUcVdFRBRxV0VMFnhioYtaNw4F+SKuh3alEjeI6o
# DATA guUV6I2YgkV4XrdhwfPaVQPPaxfzNexHjXCwhL7Xqtn0vUZO32t1V+ZtXjBjv9rxan7b8/2G12l73eae36x5fsOn8qKrtbbX6ZSw
# DATA fO1Wt9PrLMPyFaLM+zAX40svtJCHftvEt1kETFajVr+95PlarZY/X6/myMTOZs/X5ZUqv5q1PL82e77RtOJft/J7w/c3OxbysVFv
# DATA X/T9fssubz+Pf33D+Nv1RcqWH29s9nirbSffhj1umP3yiEp+q3vR9xdzr7rB6y8CiZRGoiGR0pdZkMh+OwjbfhESaR4xkMhatd5r
# DATA dguQyFqv0W41c0hkvxpWw4GBRDb6rU6nkUMiB37Y6gyuHBI5QX++lz04ydc55AjlUbSFdYea5erQNhfbD+a12iIsmD7yMprNYFq/
# DATA ZA+LynA7mH1oFxXteysU+05t5WxGrCxEVC96KC6ilKC+R2XJo01zbb9lUQ09O1vUbZ7e1VLMGz1rxT75gqO1BHRcs0NB7UeQdOxl
# DATA 9MM4ugXRy9WURpMPlVJy15h+5UKurC0vdqaYIhN7cKGaiPlU2ySnOARHgXQUSEeBdBRIR4F0FEhHgXQUSEeBdBRIR4F0FMiXjAK5
# DATA CHEcB4e3YepRr44zZpTkm/JVn2RBJijk4ru2ogBa1Q16murCPWyI3PF3b3z8yn/8dp+Jh3eX6gzwMzsSfjCVwwZ4IwWza8KpIZz/
# DATA /bmE8wZaPB9fGgeT+SBgnX451SXnEak5T+XoGw5VBYJciB7SjXz4k8yBjIa2AiGxcEbHnb53p+/POX2/5AiXO4vvzuI/yVn8lXqc
# DATA V3pGXxQREz6InB/3lmHlNaPP+fTlY65Dq1NGO8iomigM+ICssjp3xuNdRUnULXTCDpBc0E8HYbo1c8EoWrabRSXJcTyRda+qUp3k
# DATA VSClN4n9Nvzrap6iGZTtqnLReFuBmKjb10zsa81lka9ZUe8UIl7db66Ouhnv7ajri6oe7YTRYRrRVP2cFFhhmRTY10wKWkuzv27n
# DATA vl9bk/krFTp1K0GNlg7ieVXntEZc5iHSnam0Zn3EvWD2Yd40W95k6FUxjqz3TvJGbt/AIvsiny/FHWUz6UrkScEzmiqRh8E3904E
# DATA 5Vjol7TuAOtX6NCoHyEjUBmImO9NxWwIY8z9+DFoCLOkxnFwIgOPFCeP/ZkW1jicBzTizKKIpcGVsMUn1MGR+YWj9UoUZEmMNhDw
# DATA fPEOrJdGRWdZO8v6HMu6ZDQ5q9pZ1QWrejVb6VlSviq2gsDklxG/+iH4e0btCKvYudYR68nAJV4x+k2CLo7GcTZlCRrvQ0NXYeOd
# DATA dXMieOaOIyazVjy9ZwOjUjTFMn5Kj6D+lC3qIsFxQezK3EdD/71YSR8NkzT+WWIkb5SCf+BlwQB8nSglo4glmEypZNMkV0hniSIW
# DATA jVKziCjITnjkHSbjCKI8PJsgu68inAyR4sG9NFrTwBrDhODOKqPcwiqCUgPHVoUVU4aCbRNGOu7vQJin2AFi64RS7QEPMu8QjU00
# DATA nwRs2FC92vdejycJ6hA9ozG72hCYRA9nbEjykgoySPWjSQa3lephlQkkVWDML7NAocuMiaVp+74NRhglhzqFH+BEs5SbVKvCnC3G
# DATA gizUP+JcrMhwF0TCa3Si1PK5x88eSE3Lxw29KVLkXzPWfx1Aqp0ToRVJGXrKuDCPz4IBt43snWXrEvW+yHlJq4hOlGQWRurpmLsw
# DATA SaOogon8bC8vD3YA5sZpMDOCYfl4RHlBFZbSKBNOpadEWYZdriPsL+GqjCM0qV2hTzL4xjk2DymAGRmHcQga7L73ZsJNEsOfUSaD
# DATA CJwyGAfo/FIrNgsEJLasztV9NXHpBaqw55aCvllPMUxSc0UGiRO5oEX21eSs+Dz/WJx66cWpwrSqylMg1Z/lfRkTC6Tm5lB7JbP/
# DATA RO/zDXliFJwodHjRVMmoJ9zuO2s8hDKuJ4zH0v9s9w3YpnjnPT12IE3TaNKPR9t9C+/hfku3IL2EZveg231fUwAWg8jsGaKGx7bk
# DATA hFpb8V0356MrY9C+ePMrR6J1U6vNJYPdROqFn0hdFD37bEkImz29V8EwLWf21gmmS5SOz+eXjgoEBdEAZjdkUVd4DV732dJRfh4l
# DATA RDfELXiFjeXaCM/lViVfzGRjf2FynE97K94hFJrzOQ1mYV6ACTC2Wpl5aJ+mwLZ+rKi2YtKUzUqz0tybUPIkaPtbBHQLtZasl6Po
# DATA fCFp1MlxMNUgh43KYEmJvp9G7FEvqGFnUZZpVuFLZLrlhKte8CBKC3irfzn9AtSps89Ov1YMqj8y5urzs//GuKp/987+Dpip098t
# DATA wq3+GbQqBlKBY/XZ2T96p78/+/Xpn0+/OPsVBfq44p3+G93yJ/r+C3z3Tr8xoYGatRp49Qtwrei/jmn1PJBsqQ7jeTgbqIKxBHbA
# DATA uGcZIsjainkkCOGagFy56pwwJxOXxoSdFtwvDRSYJ5RLCfo42V8rjDzqOTL2dK1FWL2ODbRoJxE6Cwewsg1Q6QSum15VLpGrY1dB
# DATA EjosvXcpsoqrmLnxTa5wVwOrolFvqjb9opZik3ASBie8j5Dqx4PIAavOK7etc6peRzPgEphGKc6KsmI9juMNGLAtpy89st2hZaJW
# DATA QawteHq9H2L5h2kUxhG80WAUUJ8apfB25cspql+MJ2QOzSWHvfE8k/5MzLAToXr342m0QLHapKautmdKTe9p0as2SYTjVjkr4NJW
# DATA gMZUXWLwfyk8T9c08G993N9o2N901L+uQV8qYzH1ZpB/Wo3lKuhTxSR6w2g0hXVChgcQzCZyeYLT4clsOMaKrCT9lgy1EHrHCZcZ
# DATA fwBaGtkiq6PUYYJm9DYZ+MERjZOZzo5UpM146wHWZNM5aylS/Mex4QKtZ0+p3RHwMEVYoo74TJcMxBz7FYO5uDgsg4DxRDwWZGJC
# DATA 7KH9hwXzgvcB6k0UCgXEL2EBBaCm6B/sqYCdp9fI57ME8lB9JnU5wJQDTDnA1NUBps4bRzaay2xu6l6j1X4Zo307NrsjSTmSlCNJ
# DATA OZKUI0k5kpQjSTmSlCNJOZKUI0k5kpQjSTmSlCNJOZKUI0k5kpQjSTmSlCNJOZKUI0k5kpQjSTmSlCNJOZLUM0OSatUbrVr7kiSp
# DATA wWDQDPvPEUmquPK8EUfKzpRay6u3O5/sNfb8Tsfzm429WrVGf33Pp38aXY++FnOoH3V69eYiD6rb9mqgPtU9v9oZ7/k1+qehvpZA
# DATA UJTJ1X5vGQjK70rAlP6YBm6NPqpb6KV6s2UVveIgCZSoCK6KGkHUjBYi2mj7Xq1DyW56fr02rnf2/EZTfVuIZ9TrDZbGs75Yv6pN
# DATA r9FsDltV/12/UfMaHX/Y1HpxFgOr2ahFy4JcrLGtBsW07v+o2xhXvVpzj/7xO+MavYaKpYPPe7UOfVn8ofTSTqdVr/XXvPQiqCNp
# DATA IRp1JI3NQh31qm2/FhZRRwP+n406oq/BoFpAHQ38cNDzc9RRu0dZFRjUURj0m91mjjrqNJpVv3nlqCPeYbLHpofNElKRLc4+fYyE
# DATA nvyXmrk9GbCZRjIzWAf54ZErf/MG9KGCE65lnHCy9LYIKLLCXnTI8wgr2+booejBpnAibWnUygF4Fxiv1zy2fvBeCSGyStD2BXpi
# DATA Qq9OT6lw2yjVtiraYv6sTo4jCTmSkCMJOZKQIwk5kpAjCTmSkCMJOZKQIwk5ktBLTxIaKI4QH72iBFeObw++I5eGJ6GsHgL2Q8ZN
# DATA JTM/ZQFblHz1xFw9iahHVpc1fegewmWC0OAG5dAh84E+ohjKxeMiiEj9fp+C55+zpT+/PYEoEowFeh/fd7L0vg+TWTCS831817vB
# DATA bLjPfoOdwY3jG9mNE3WzzRnKT7K4o9LuqHTxqLR1rskdmHYHpldL+T0DB6lxJnWQV/PgxAvwe0HefMbKJ1KfUQJGIhz1poKfIZs3
# DATA GiXH68/6juOHfPx4mibJQJ8/hs64aag0/mIryjyNsifQNqcRMT1BUmaUJUifPm5518vmU3SqUahadJwZ8hFZNgpslNKAh9oJOb1R
# DATA PMMiTkKTh4yVsAVk0k/n494BtGHiCZ/Hzsyh6gGcvUd8fvcjuHALCiYpa7qLgnbWTxJ+oj+fQmZbzjWvU9B+AzZEeiL76DweovKk
# DATA DSCyDhVABMmlOomiMNPdmaQ3m6ViLlM5DpNRyGddEXNKLM2BWQ4cpTLAb4cU5dEJC4WbbDNlJ8o6LJOOU+laFZ3TgIncKJkh6XSp
# DATA lxyPvGCUJXwweK1E+D2q3tx05Ng2vTVKrcJjweYeW5ucXfrmONOn6I9RF9E9s7jPCOd70Y/ve6yonvfkfWxIiSCPHo/4ZC7Oxmf7
# DATA 3hus1sx119OAGlQHijxCRWqDEBuBOCxzDFGp+gez80TdOec4zsc0kBhdQWxHxfl3D0dp8DJqOsGYX0cDHZeOkoTvz2dSuNhWM1Wn
# DATA gUUn3pz3xpVRrChcqBY/g0w9w3Eyo2j+QMIT/wqHSKbhyM6S2JznDtLx5XTNXxchamQdNf4LC5ujEW5b2fwDZD4KbwDntPROVyBo
# DATA nrMtRfAIRcGGqJfrEVyBprlRZmSjZqLaHrpZjHlXIHF+l7t9YyspNYnrUwJ/cQ5y54G4GYWbURRnFOUq5aYVblqx8fRh5fTj6qYV
# DATA 95EVOQ5HoqOnFM+8NuB1IErFkUaX2fPl7Ryeh8XUD5gOy1zI6RzVywBJq6uxnrlrj275nv7i7Xz7vMjaD5oIFy7mFM/Osjg3mlaU
# DATA u5sSVNnfyISS0WyDWKrbc8Sr+l4wqRaiZmdmvUhIXRM1cXrSzwWv5AaR1A+aWJoLuV273z4vorV1EV0JQpX5K0Yrq6U9vzRUaWpx
# DATA VhQ7Mpql96hvodbhHZq5eMVrdb7tmXrrjcmkzrx6Q91zDP80zfJpIh0dpugo+SmNzML0W7hZfCN3R/xV6bDJzNRATmNWq437pqvD
# DATA G6OHsmaipwxYBsOkHmGVpMxYnsvqy7SAbSasMnlaViEw6c+nJRI7dfog0ipoG1BOXxzb29F3nO293pvvDO0X0tC+KGXnKQuh8g7g
# DATA fIPsogFqQ2hYdDDQHmyjFypJWE2hearyqc+FrCD/d8tMo5LQ67aJRgtSuUt5RhuI11r7qHMJW3yLIFyZBIOKIeiwlTXPhsrAKtVT
# DATA 7BSXklW7xV8d1u/cS2Os22CXInsR6RIY9fFD2DDs/ZfzXEw7jIvmDk0gMQuMli27KFVNETIVfVJ1kIG3cCmTp2jA0LTU8qgaq8VE
# DATA 1473faxZIeZk35ViLrK7ZlGFYsfrF6ZNiMaoXpZRDFIcJ8P2bGu1iOVTeekJZxHXRBjNfsPY8rG2ScL0X47vfawEqQU6PX2OiuKo
# DATA QXFhj5dMRmbVj+Ko4JNYgcAi2OqI0suW5etLo91pkYPIcOuDw2Oxg/7p9IvTr06/Ofv56WNAf07/ePZrhvqAHvRzZvh8Rr+BLvSb
# DATA RXjQwsOnX5/9Grihn5/++eyz089Pf08//ooZRF9WPPr0xemXe/TEYwTt8T3f0D30DkELrYQJUeh4y+f0BrrRAYWefYv6h9Av43Vi
# DATA 7k0ULeykIguCuCQdrdqdmkaH4C9rOWdZ+Ff11QzuKYs2FyjT1BuvZQi9MQxE1cCSDHccIcu6Vl3CdZOElpXL1dGEeEPAMJmaGz9S
# DATA F5YzhQZx3k3fi2fGE7xlmpBAjdleEF+RRfR52TlCm5TY1mlCdz0BrwMEvjeb9yJT8uLBj7GHduzJTvB9792EasDEgBCpEI+g9w5J
# DATA D6wRsIYHzLJAbXYJ8Hkkmz5SuA/HzGMUZx0bXwJrhEhsGR60vkquNmKWtLOnhQ5anwQHDXIj/UVGes0JuuQA/3K4zq5rcL+SsX2j
# DATA of1iI/vVD+xSLRdzIN/oen2t5SpAQXnKIKJFAWSLcZ7B44bNmnrzn47v3KSdDzkxTkQXIAgwMf/OfBMsgTFtRW0J5beMgwmlLjPp
# DATA ltSa4AUzNJ5SFzaZbYQNgn01w0F+5AOFNEipt8sH/ViW+/XCFoJhMTmGGBkCUBpJVhkk8okAlSvWSJ8A85MMBF2MF1FF9O7PkOyY
# DATA PR7xwKNW9UBoKMfUUWDPINogbzBIkXfaIeroQY4e5OhBV0gP2mxM2RBqfr7Ne83G+2Vs9yc13R07yLGDHDvIsYMcO8ixgxw7yLGD
# DATA HDvIsYMcO8ixgxw7yLGDHDvIsYMcO8ixgxw7yLGDHDvIsYMcO8ixgxw7yLGDHDvIsYOeGXZQVB1UB7VLsoP8Tr3frD5H7KDFdeeN
# DATA +EGHJsm8i7DImgmbUTiormLN3Hm1H6ew/wXsU5OEKLBPm0UaWN7A9xVhqHB7q9o453aL80Nhe3SPR7/t+V36W6V/u83v0fWR363S
# DATA tZZX8xt0rbXX7u7VGrVho/tuDcCidmfYboz9enOv0Ry2lsWkUVsVcQUwunlYqECNmo/I0BvGe75XPRJEz5psjAa9bms5Iqm6UD0p
# DATA zs1addhqVN9Fqhvd5lGjOm5UG3uNKn0qI4i6QbvXWhZ07eI0IKnzmgYkzceiAVEy+u16kQbkt+udRtemAdWqjU4zLNCAap1mvRXk
# DATA NKDeIGyEoaEBNevtXifKaUCDQX/Q6V81DUgZJcsdHzqtJVtLjUTYuLa33grx6GYMO/m9ZfCPmSgtmxRpNxrmupXGfoP5PzXm/yyu
# DATA R7WKkdLGjdVNi+3CCaEcD9K9Q0yNwbOohtFhxVp7tz97te70YeVb9Wqz3eqx22+3sjqk7gWD0lHOplH/olQibfPCe7hgUlkrcqsX
# DATA x9VSuPiE9zL6YRzdCoP0wWr2UJ7DFTvqq22OktkrdYhtJ0cSciQhRxJyJCFHEnIkIUcSciQhRxJyJCFHEnIkoZeWJKRIPx9ax7ry
# DATA 89zFc1xlDI9wg+SUN+WRpgthRwCaEeg8/fE+w3zeSMYsgL5wyJuPt2EpSdSqAhxUSSbq+JoWpC0eFJM2KhM5fdLCnXF2Z5wLR23c
# DATA UWd31PmSR51Xig9ezRHoezFrXfBZWnZBlk/P6qPQz5rcxnXocavBBVWH6quSDEcqd/rj8ySazbOmw8qvGJHmzlJt7qYt0uz71aJM
# DATA c3ON1DUPfpB0Ub0XX3hVbFmjoiz35ALX+qFXE+5MbQnpFi/3fEB9n8ILcT159WaiRAKXPNHi7KKxxbvpzdLoAWtFnvtYk19kmwFj
# DATA GDQsn1x89qakZgOh6rd0/USV9VBln1+V6nejIJtDNBoHa/tBmgtU35+JJB/1JEkykxvkWDNkfYJDiD3DH3VMY9a+90Me3EbREVUa
# DATA dIDoVMcqbG7GCk6TpEZ4KE3InNz3PuAFADGN5AHWW1TCfjScnKCgqSDiWUG+GjCtwrF9OUfqpXOc8caR6wAH7KHhaMZz6AeSxUZ1
# DATA lgs/o9nZPJtGon/IitnBZD7AQJxiLiUBgosUxoMBrsx7rKceY5ymwBi7s8zWUyIElITZxgLXL8o5Xydv7cxXy3x19upLYa9eVNv6
# DATA KUv28Lp2vgC7Xtv6Lo1GbDSyAcl2bJZLUTBHIVujcX3dYj/Phd7FVchaL9brrUtbL9V0uqy8db7or80xsSiU7ROBLMp1Lhe1ZvPn
# DATA hEwaAWryUhC9bt97XXSDaJYkYjVRMIGJ8hFEhETuJcPgxphRIThydYMZRVZXrIWfyYZLyOYho+4BvUETQy5WcX6ghViMqpNxh79c
# DATA iieFnHHGkDOGSn2q8+Y5b16x71xpRT1lQUPmAQNcnIxGorNfBnardhJkuYTfvndPON1sJS2T5yto+U3TpB+FoHGLFF2SfjKPxJfz
# DATA JHzuu7GBOhsa74xGUM0EHMczQU3LSOqxlgvHYM6N/DCYH9Ko+QENw5oWWOEAxCyR5R6Fd0CHEQwGcIqxqyR3eZpx+u0JxvuZ8Gvn
# DATA ihYRjXtRCBG0MOqlNCILFZmHUBYBxA6ltShrGf1zeUbBAQdUFeAHZU1BZRpk2rqAchz8Nak4S5X4NNkA4SjqBem+9w7sJ0STKill
# DATA bqBAYGGADgZIhN5IhNeGLIy3TMiQP2aWaqG4ZDNQrz+hgo8H0HkbR1j7i/trYeRDVrXmyjOZwYPDXmST5I8A5UgGA++QhiydRNkn
# DATA 6Y3mlKn9AIqNXI+BVw+OgxNxTOl4qjLMtFuHs4/HAQpGxZzyJRMFbviXWIX7QMkaQgoz5ZMFquKa6lwAa8xQf5g34vUoAtFKr7NK
# DATA NY80MrZAJpz54LlQNQSnTMsiMyahxMcgk7D8UzyinyvaD8UJyGE7/SBNT1i58S7lWcB+OxWQEOYFHqc5PkcBS/LlmfReFHOqxE+s
# DATA 1C/hkjtMktByt8tbE2poNBoOpK0Vi/BysG+05RNWfaQ+5rULw74Rt23DvsUuj6WBK/3CeAJwfBReAfT7dTDvlVyo2jpyBYzvj0oq
# DATA pFfyJoZ7v4OmIX0MjWuyLScTYs5238angD4ylESsEE2DOPUewFscLKbuKoniL8ZUx4LLJEEaHsK3buNl/ofCyHzDUBfQYb7wTh+f
# DATA /uHss7NfL/Jk/oXu++Pp7wT5wncx+QVUmG9O/0QfP2eWzOOKZ/gyj0+/Ov0cuJrH+GlPP/XYo6+f66DoNnrhL85+qeAyFI+zv/OY
# DATA MfM7sGlAoXFQmecA0zjRzK4FX9w0SoCAViP3TASm39DzNfF7HPK2bQxyChrG2r0sL5yTu8zAR9HTQ+F8Eq6lzNzlW/I3O8ZMYTZn
# DATA eobrpswslsvVMWY4geau70JInPJ6NCjfF0L72QC9sN93lgYn20TLUBvIyMZORcCcZhqwxngmhoJwcJn1RbV1qozphMKYzHg+sSem
# DATA DpmveAoi9/FDj+uF9wFvDxC37SH2Ry7bVC7sQ2i0a6VvlNkkmrGmOfZ+0BieLTBk1tW81XbKQht6WvyYddF39Bg3pD/RkK5xMpca
# DATA yV8On+z1jeJXMIhvNIZvOIRf9QgudbGc7Hzb5FNsMVeBlCknNCfLGM2JPOaUm1GgEDNwv7HcADxdEyrSTFZrkQzDz5BhFeiJozhl
# DATA XAwKS2NlKOVBhos4Mm6IwlgNlYH1AhCZE1hb7NuVEA9lmxmmCfSxNxKP22Ea8XkAyXa91U351mn0hxQCfz+XR3KA8Z+zJLVshiJm
# DATA JEodLMbBYhws5gphMeeMGZsh4c+1bK/VPL8Up/qJjHPHh3F8GMeHcXwYx4dxfBjHh3F8GMeHcXwYx4dxfBjHh3F8GMeHcXwYx4dx
# DATA fBjHh3F8GMeHcXwYx4dxfBjHh3F8GMeHcXyYZ4YP02o3eo3qJfkwg8GgFg6eIz5Mec15IzqMnS31quc328N6u35U6za+R9+LOdJr
# DATA t9uNcDE7mzXP71QpQ9tHtUbre/S9+BzVzU5PcVm4LKWspOBOhMNSK+hKNLrFMm40ShHpRd12OcBarX7ZAMNqt9ZuLQTYqW03hvWG
# DATA v90YNqTqbC+GdqFQWW4hD61CuWCAK0rZKpStxNAulK3E0C6UrcTQLpS6BL69lnLBAM9vKVuJoV0oW4mhXShbiWGhUJqN7baUCwZ4
# DATA fkvZSgwLhbKNGBYKZRsxbNasttwtlrJfL4WoLqQq98uDfyuql1BcrW4jaCyFpS2DjjWbdQs6JuGnBglmGSk61AV+Wq35ZAE0O10r
# DATA gGb34gEUktBtPWESNgvgIjwzsdE0z0zMPYtnFjRajXpU5JkN+H82z4y+dqNBgWcWdcKgF+Y8s3av1Wq2DM8sbPX9oJPzzDr9RlC7
# DATA cp6Z8nqoDQ1mJiTOeLIl2UFheS/0IrWZn3V4pXLJon8x5DLH7LsRGbFxUJGYlPaiLAnOdkTyIk8xdLXue340zPRl+S45fTtNjg+j
# DATA zZaKmpssTluhlledbZ+JriNFt3NNJvILq4d+3VokVvf6taIXRldX3mM5DMLkmBdisOJW9XSds/K2yw4LnhWb2dyK/XR6Eqtyu7qa
# DATA gWbn6TkeDSu3SnWSJ8s1B0JzIDQHQnMgNAdCcyA0B0JzIDQHQnMgNAdCcyC0lxuE9kjV7pgK7rZCmeEzJbrCSVIXcXQPGSG3i+rm
# DATA berYqM7soGrFt6sH8av8xEF848buI1zk2w7iwc5xPCHriuywk+kseQ1G/AeAYox/xOHsPtItaHqbQWsMAtlp1LqNbqtd67ZucpR2
# DATA v8N/VBR6t2ED/pBm7/WadLz+7kGYPJJ3lF+x09s9+JRlM3d6P67+5M5tetfugUi+4cK3Oegb/sGnERnrSgvOiovw3zjAHRWPXbpb
# DATA qY9O5zTqqW7vU4keKsdt9fNPk3iyw70V5SD4cGgMN9SPskC7sxNUelQcwY1ehazH3JJXqR3Ft1das6MYBTOK7Qp5W5oHlRu9SdJG
# DATA M0e8lm18mRHgADna/RRbCSbhzijePZA8Kv7Oq9I0cVdd8R2/ulu8AUOwis8buHdfTk9TZftUI+vM0U+nrOKUVRaVVcxhYKeu4tRV
# DATA LqiuslIU+wpUVz6AHJdWABklrPfBml1GeOXpCnldB52OTQG6Kp4gLxlwYs7B0qmH8h5JfS+oyS4Q6XwLSNeycXT+Ghgdmy+o+viA
# DATA +QeKogSjU/fkMDr90AIjriVBPRQTaTVLjsekt+BdP+9OX9SAyQI970ZW2P3wOBpRJ3rOvbWqundCJnDp3s3RdVy90cq5RJ9bat33
# DATA NaNBxqOMrIcoNFJ7Rl6HjCwjiyPme1lqh0lym8n2sIiNlyXzFCzfgeBUoL8tViM0HHI+nXgtyEicKBkfSuKJpw7dG7EYeueCWsyw
# DATA fsfW/6E01algRrpQ2CKzc9PaqKtKYLQRbe5FUAzJxxJndDqjc9HozK0LZ3U6qzM71558alp/9xk1xJFkFzeQo6j+xug0QLJx3E8T
# DATA SwJvzhaq0r8LqHVN+qBbLGrfmUExb1FqMNSQEpaS6yfjcZT2Yz0GsuWaRlhpwcaFjbX/OGXTO/fFW9U7gc8swi4TDKMGoCTsXxpM
# DATA sZdiif6WOu+2aKIq9yxqIn9SxqmyOfSPuQFkrvDBZ6DTIg5HxU+WG0RwUEd+qe1pfL7gBKnPRcvTusN0lPZTC4YdnKZoC2BNyX3x
# DATA OjtQG+dvsgG36q5+AuIGNZcjvvmN/OvqZ7gS4e738WGNdSkDs7bwxIVqmyQYJNaYd4USxp4PadDqaGeOdKBOybA72GMtqzsqL+28
# DATA KOGAeDeMaefiDObalM759tp/fvZ/tkwqytFWOatMMSVVSRUknZ2IMUb2HY9MYPJoS5IHIZr27cHuCnm+6N0NQ0jj0dPCAuqjsVHt
# DATA 54ki85PBXsGDbP7J6MhEFE1Mhm1Kb9n3Xg8mORVwEsqkVH66ByIMXlKv0iBrKEH62Mml8rVUey6RvY3V2Vuoi5LLsJfFhqeEzIKR
# DATA zue7zJOhQWJakVzTE2vOtQCbAGbxOLKhbNPRnGfPNL+ci0XPBCTl0ffuxmPk1YCstWwIWBWb3rjk1/B1mmRsou97bwG+iNeEcdaf
# DATA ZyggDkkWJbeRy6a9XTR/V+etark6V9HjU9c7wwedp29ib0/g1f/jt3WwkkLKEyweTMAzPwY+iOrWnPKOykKm+JnnU4F24bSQ9Zd+
# DATA RHOQfe996rJp6n1XKrZUXxCgmJPE5xU9uDcOvNftO3CGUNwlPJNWm7z2ve/R14grMpX/1irypbN4fQ9RyOaPaKClSQYFkeo8Nubs
# DATA gBr+nug55SwwaAdS/UJlmkoeyopPJn2B3I1KCj9NoNDjmBDKg+9BuxQnAzPWLQ1MIMFEQ6kq8jL6DUsoEjfO9MNYJE/BIzuKE2oh
# DATA 6uFAep5no/NoXajz+K/zmFc+9eCtC0EymOovjXGo2FwB2QbShpFMh5DtXjaKp5Sf3Di4bwHojKc3PdY31R5BKKhiVBclVu6avMNo
# DATA JkXHWYiFxCwZR7hwOI+448DT8UQmKtQvzbbSfVz94PcGj0tgIsWmaptuUdwas+NEOmTJWvTGmSA0RSg5ilMa3Y4Riq7HLGMbG4Vf
# DATA mq6j6aeq5ZMtyKrOeCd1TTitSL31kZrcUdh4YpxgIZfnDugpGDsh3Qts1nLmFs0VWTa2zRVzRTLrDjUwtcCrhYRl/BZT0TJfqbkN
# DATA ueFJoeyfx3p6EVwu+WzLuVycy2UJQcF5WV58L8tKB8ozRVQoHBVYHClHNmvBG8UzHHFmJRRGYoJiqUYTdsHkD/J5Es7Yp41geJa1
# DATA ys/jJ1kHP2RVko++3HmVOtJye9NH3wvH6zpyls86ly8XgpF0h2WcxMKRdGm//QS1Q952MunrqCiVx9zvZovZc3ksAXNYz/EXTo9a
# DATA iRnW7txnm9xUEUCQg8mJWbX6XnIMHPKJqjuveXxhDu8UWVWveW/Q/RF1pjCGYITklvBrmITFY65wk+xYZg8zbLTzeOmY9fdjRXTV
# DATA bCrAaAOyzcDHhXYZGV695GG0wIsq1pZ7MQMz2QFJ2THvzyiRUuwvw5KTzblMmMdtUy7/mbGU/wrk5NlvPBApT39/+uXp54uEy9Kd
# DATA f86Bl7i/4p39nK49pv9+c/qld/ars1+cfoEncO9j3P6VIDDp9m9Of3/2D4BXevThM7rtT3Kr41g+Byabl7HfP1UHEE1fj0Tz5Jx7
# DATA gn1Pdst72VwmrLIhn7m18iA3YIwZPJiwR2Ai06gBJqzc4OAnw9LCkDfPr6FYvi4yYILKcAjLogknjf66AZalIrk6eiXsgCOru1cV
# DATA jyno8lP5CVUFzRMfqCqJKjiBR2yrQEveLTEMMvbXAP2jHOXKgnFQy01LcOt4y7uwSw/FVjHs6Ap3myEcbBoQZPosMbTfjAeDuI8N
# DATA +di2LDtuIs0A17dOIgqDfk7F3b9AtNyoDq42S4qt62lxLTdKhANcurH+CcZ6jbe8+BD/knhorml43/bovtHgfuGx/dqGdqmWhWzI
# DATA MZdPrd1cBeSykEZMyYNiwrCtVBKAYMfTmQyF0xRdDzh1w6AX88LfLNOlRk8cHmKB5QFVg0zm8VSP1TI3ptsyMpsReBRThcTylxD+
# DATA Mij+pZsiLpGNhgmIaQPFf0RdPc6wYQ1EoR117Hnb6wJWUtWkvYKxIAtCHEuWSEEoyENkAFY+s71plO6xVUclMB9zL3tgmQm4EVHe
# DATA I4NtpdngGJiOgekYmFfCwNx4gNloJnMBe/j6TPvLWPZbMuwdHNPBMR0c08ExHRzTwTEdHNPBMR0c08ExHRzTwTEdHNPBMR0c08Ex
# DATA HRzTwTEdHNPBMR0c08ExHRzTwTEdHNPBMR0c08Exnxk4Zq1Vj5i5dUk4ZjfqPkdwzMLK80ZkTAv15jdzymK9SBVrlzK8Lr9LjheR
# DATA ZY1Oq9pekuHAbrZqw0ZjvNdoeH5nKKgzCzxWppHl4LH6AvStasW1hFRbiGu1tSquvV6r0wwW4lqrUVw7rW3FtWvFtd1ZG1cFs1sa
# DATA 10avw78W41r3q16N6u924lrvbKUOtPudVuAvxLVR3WYdaLS3UgfCdhC2Futro7vNOtBsbaUOtFudXru3ENdm58nrgBUchdZotYet
# DATA evXIb32vU8LjUofab14OYkd9qYbYSbdsQewaLeo2OhtA7MJBswixa0SNsJpD7JrtVrPdNBC7fqcf9fo5xK7ebXbatSuH2GEP1Z6s
# DATA bujRtWHx6yxaXYdtzvz+i3Hpyk7Xer7U2hKnK4fM51Q286W21vlS9ZwwD3RxVUb5mvU0AxMFNeXqNhfocPCpYcFJ/lPn3w0XLp5Q
# DATA nfI6QoaTytAo0ulUrVlG2bscMU5WDNQi7tIiMK69sr9gJWzOKoE1tulijXF8OceXc3w5x5dzfDnHl3N8OceXc3w5x5dzfDnHl3N8
# DATA OcOXY/VGhZJjnycl+jvylQ/v0deb+lcBzbGx+fErb6njf6E5CYnDekwyYyZbP4pHOxw6k9VEPzPb/5j+N7k7w20SrPpBAdjUN4bD
# DATA 6HBDmnB7fIJnSeA3y6FwMNajGY8IBnfmdBDdQfvVB+3dAfsX+ID9RdUPn5mD97lja70aIou88WnWCY1QZFlAYHlI39dpIT7dc/rP
# DATA 2YnV89R3ckflVWgjllQItiyMWNZxOEcV8a4C9LAYAuUqtaGMAzPSQu/P4Y3hHQze4RxQsF7EbLDAUv2G7gFN1jFOe/foagKRe61+
# DATA KDJRjGhQ6gpUbxMt4CwnyrmqK/EGZD+fKcc59J5UCDyNOhc9nMq0QqlMl1UP1yoplZocvNc2/IJVt+8nNNIN1Wl12fyqxbffCyC3
# DATA aGT60+g4SHGgXgmKHgcjOZofqArqjZAQ5iSwAz0OUhGmkMgXz0PPAhZJ/cF8hiSZQ9BljfLFOOpcNtSGiZQEU2y4g8AmDA9fwigw
# DATA UupBxioNSlgrYDwNn1aPZ2ui9zaoNxeIHHoREzFLSENXJAhgZlT4QaoABskoUzxGQ9PhYNIH3jF6IY4vTtuvieT78polmfgSnVi3
# DATA Q3E2srORyzZyqVY5WSonS3UZ63ilNX5lclXfjbkNsJEQKKEnrWBDOfbA0q66Zk3E64ADi3OHITiwHtMIOQeVyvV4YP2Y6Z3MhZxw
# DATA 26iehwiuV8WQ3YASLF4nIHuNg4kvsUsILz8nwvp5E2FzIY9wc3mEJY4qyn45ytXVcWbXmF11UbV2+MU3xTO1e242FynM+nse59rS
# DATA ODcvG2XtMKMb3l3uczsnxnkAJtLWJSuvl0bbirWqPjrSzUKcVwKRX5/Ho9Aa0dBbPL9c5HdlGJbRPZjy0RtewNZzKQNO5t6LT4ko
# DATA dShJ/pAeisDjuusNomN2abPjeGY8qtDBWiIkf5iyUJ0Z/yfRkWZeGQmwH6p+XXeFAK4FwKJj/ywb5PveX5OlEPK8h3pGq5slsz/E
# DATA ziBRXdOMTHFlS0fKjYVSJG9m0wNTOppmCAcunq2asr3ARrg9ujoj3BnhC47qBWvL2eHODl9nVj87srFqsNPNgH1gaAu2CjxwOzRW
# DATA mVZ4lA91SqK0kquY8lBjBE6h14m9VRh1EPhUJDsxvConItrcQIAo2TwWzIwcBlmluXppenL+Um7YkMDvoVLoWQSNzqHjJ2/CT56w
# DATA DxVPiDd19Z3iTpYpBD6tISdrt6Ll/APF9tknKOe5cUGM5IerEZI6XwUiebfguYdLm6oMoLRphGIqAVPT6JByzPhn2Q8rSCz6zwBz
# DATA Z6U+SzUy4xvptskspgmzrEDwXHnfeyNI0xOIsiaTons8DZjZyFbrLD1RXmIWZcUeyFQiBp95MtF+cjV5sBtpvvqjm0i+umT2QMoo
# DATA vyb5Jn+1iiJd4M2+3DADME7NTOSJWKF5Vb5gMb+1uph1o1DFbJz++ZKM7LXgHkMX9DvoYmHkBMJkTcli16scmYWsFy0AUYrmpRcJ
# DATA PBslx6MTkYROWdkYnSvGIrPUQ2XOG/jQQQ5Nr/hERbg+addWiIVe5oLl+MEamHHeX+kWK+gRJZGcRmCx0pAzCZUYOJekJoHl7TSM
# DATA A5oFjtlAHUSzExpP58jjWDmvAt2SFW7MTOZ50YVG15yPlpklHBp8H2JGyj439oBhgTAW4NoTt811Cb22cr10H3x/4z6YKuyMbhG6
# DATA buRNmL2dPThZ6H8120aKFVaNCE2zkTGMxnE2Ze1r7x3uMQP2EoyC9BCy0lBmnGSaU3+cpNK/SluRznUQAJEMt8BW2uXyVD373er3
# DATA Nu5W1dhF9hXk9ZHUQA1UYaAJ1qZJyro3ustEG4tih8LbwqfjII6DolR86/hwAlePTES1hQnHCkuDw+hMpynr1VOvK8XM8dhG29sg
# DATA Yc9F1/rmhbpWLesOwyRMg2M0EN6dMIoH1kK1cq7pO5T1EAXYFkqZA9l7sXdsewYzGi4sbfL057N9j11+Zi1bbQ/op8EUec5HQvV+
# DATA Cu0he7JyXZvCS5Xo9QK8n8hD++L7FHMEZj+i0T7uZ0UE5hdnn51+fvqn08dnv6LPPwfPEtjKP9Gfn4NjefaZvrgMi/nN6Vf0/y9O
# DATA vzz7e8Zdnv0tQzH/JEhMDvr3dOVXzM/8ksmZ3tkvz/4OAM2zXzIdk8I+/ersHymIX9Lf39A7KQTc9HP64Y/0M93zB3rJ49Ovz37t
# DATA MJnPhaMU29LQXaluUdU8Djq7Jb4oHsJ6ND2o8PdDbHaHF7UPZJ0CtRwF7LkKzBTB+FwDD164/nDfe+vhdATzhTpTFBZirQyaXB14
# DATA LT/zjRGNX9ISET9H0LR9qLrPuG6C5kKhXB1DkyuluQtbC3lNXXkAF4ibVLXjxNx+n796EO2ajyAStk2AZpxJVOA9lJ2NEc78BuAH
# DATA nUQzR8/cpOyugJzJq6S8Wh6PMdVFaKYCqO5pFvERtT7qMR/r996Ngmyulm8px+aAQjFdASVHfaXxPWfMGfJm8ShSLuuU/eVkIIXz
# DATA 0SJOc7MqudrSKbe1p0XU3CwdDqnp7IKrsAs0a/My5sBLsZx6babA9i2BjQyBC9kB12cGSL0s5YKN23zW2tRVcDhLyedEw03N7EIT
# DATA mTJ8UysU55lzBCfGSPE47YM0nFu89GyU/3IAn34bMkN8ORpfmT2IZn34vTfFceYjvmUxUOSyfPgfi50QYl8eVKOgUEPx9SREPllT
# DATA sAd44ZviloR7yo+Pdp5lvI/M4z1cYotopyKNSkiu+KMUrZM3SrDbKjDLaA696dCbDr15JejNjcaajaZAFzGar3MKcJkZwLYmAA69
# DATA 6dCbDr3p0JsOvenQmw696dCbDr3p0JsOvenQmw696dCbDr3p0JsOvenQmw696dCbDr3p0JsOvenQmw696dCbDr3p0JvPDHqz3myE
# DATA rdpl0ZutQXvQeY7Qm6XF543gmxR6TMOi1xeZsS7nZf9E6IbdPGNrDdGh4l9qrSK/sBsOos5iLoMJWKsP/Vrzk72O1/S9mu/51S7/
# DATA qTf3Og2P7OO9bn2vudfu7vm1llfr7rVrnt+mL/ViYbQ6nWY3kncU41xr1PI40/vyOLdqeZSFLGpVjGa9FS2iLNtdz2+2h53OaM+v
# DATA UvTan3Qpsq36Xo1+aHX2fL+z195rNvf8RrdUW/yoH/kl5mGvFQyC2jLmYWNZUhoS+76KcduCMDaspBTreNjp93tLiIx+x6vXOp90
# DATA WnsNSkm961UpTR3Pr1U/2aOyqDcohb5XQisGUbvRWhq3Zqedx40CtrK5a9WMapEW6Tf6jdYlSI3c9DSpUVqxRWqkuPS7m5AaC1dA
# DATA aqxFnSi0SI1BK2yHOamxHdbCwCI1+s1+p37lpEbsbd9bZ9LQgGv5uMQ2Ng9pS8aGEiKVA780I250vu3hXzI1PDY38iD0eGstMcqv
# DATA bE5u6PWvWfFbOpfgECEobPv8q7ib5yDaND2wDPCCK1SV+8XAiuL+yqGQpTxpUp7Qv3X5t7Ba1WgabGS7+e2lhEcxFinNMufLl0ut
# DATA BazlCMeVqMZzK4O2J5fXAsmUml18G4dTKhqexZYmQ44D6TiQjgPpOJCOA+k4kI4D6TiQjgPpOJCOA+k4kI4DOQjQuG/7e8JTlE3H
# DATA gD+SNaORj/f1effjSPkzGfe4o3CRuIAnJChU1XvY6LfjM5KxPxb2YyEQNVe1QpEr5wcjIrIQT1bH6eWovTeNo36kTyPijBz8hz2U
# DATA R5EDmZ+8cafD3enwjU+Hl49ouYPi7qD4et3tZ+YA+f34oTShCo1PkxMs+cdyyNIG35gjj5ZoKprMSA514tkHi6eecRSUe151dnqA
# DATA UORkZhaMogvKZxtVS3E9chOnm5MxXKP2OW+nnL2JcjbvKOGqiA+r70N/idt+RH/XaGbToDgT/OH78vF50Ms2eXBBkcjXV4tEqtwU
# DATA gcjXcYpzgGPdGJRyPUhslvHIcqeqgvPgOJ0PLitNeU4g4DmKB3KCOZkxBSLjoQkuKATjDSKqRyMYRDRhSeTgMadEE1GeRDvzslny
# DATA xoZZ8pbWBKUxWWfI68EIugKs1cvRpcbEF8yZa1nCYVlRbwDvMj2NnOIFEp7XgTlHQzP+UBMk6y+Wk/kIbLKNjNHt4IL58qPV+SIt
# DATA StWUeciWSV5HJkFKc1JvQnNaD/0Mg0Eh3YoFCcgM5PAfWDRcpaKJEMogSJAxR4Q+T9HfH51o4+Yp1pH/smEdeT+Zs4bFT+eHeX5o
# DATA tempVp9OxgNsGgGmgTqBKaZXaBBMM1IYo5BMDRrM+pRxo2Eyx4m3fe9DTAhYW4GVEsSuOxwFPzNCHU+oPpt3hRfMn/fXaM/qTlVy
# DATA iObX3lRfkhx6P02OUAcozTS7OYwMOpY3yVGlCeZ9qHDcnXjzCZKrexgIBDMQFVimEZT3IRXNi8tPsd18sGG74UqtlFssZC0rMoyT
# DATA OdTH51CqGInxkPIZWfj7QcUKQ92zQGk5lq6UzTJbiDeQ6kL9dTk/rlfK9mVRaMjNbDcJd5PwjSfhbsb9gs+4V06mn2nJNt7HYna0
# DATA CJWVd7XceZUadLmE9f5LJNdsq+vIVkprc6hcCEb8rSx/trAvUipMP8HOIXnZyaSvY6JOGt/5wcK2Sj3JX1SXsx7jL5yawvg+KpC9
# DATA AJ9g1gsrjoVUPWkCr/0L+UN8dJqHm2dUt+55knPaUNjWM1uqpPoWDAezgWqNofafv/0nbUbwK4c1kbITC9KbRaMRT10UaEIUvb4L
# DATA +zPzDsXKCmZMiwihwkYzluF83NPFFXjp8GQ2HCtrlg1WnhscxvKzWH4sRoZpM0TNLM0vj/c8QqRLSSNXKLfSKBecM2qAegVaMEM5
# DATA uuI4SBc0dYsFylAjYzgyseollNWygnFWm7PaNrbaFuqbWztxayeXsNhWGodXKb7LgKaB0tFnMXfkNS/EFzR4n74g/DpDAOf8PHut
# DATA ZWHpRGxFti3DwrXCmoYs9dPle9T/8tlvvuLt9Mfnge71o6Y7MxfMCoMcECkj4/0i6N5Gxlf3/dXrL2pDgR1ZubRJbM3DJrr5FRPf
# DATA 7jajqzZe0O/vav3fWTIrVImdb58XbROIiXZ+5Zxsrlrxrq+NtjJfzYKZ7ErlVS6p8hFv8TBNIbMQUahhd16VM8Eqzmp7su1Uyy9J
# DATA /xMLqmpKY7cyYm9KEE8IfxLbilFaeRdgq1L/MDP7S9D4jHH7rjhTjVIzI4ePh/EoyvuJGGq1M+zVSVny1qx0UGuOcvFmlgdWK5ww
# DATA cWXjimx9I1O3VAX0TisvVKg+0xto7WB0qVbfQ6maj+l+bA/Ow2E96X4wgXbwlBIQ45xikE55oZc9x0CRw115PIzEgM87LqQMQtPc
# DATA r/HCFhkd+56C2SGFRmg6m0+p61H6wUVx6Zuc7y+L9WxBuHiOznMIm8P1W2ZwfXH2C+FdgZz1zekfFJoLcC6wuD5fJHD9C932GIAu
# DATA QWud/psVDn1iwNZXdI+GbH199uvTfzeUrtPP6cbH/K7fn/0DE7pw0sE7/d3pF6f/RpUmGDng1nNh/7Nxb23dACowTYB3HaOf4Ppm
# DATA 7BgmtWaQJ6cuidX7qGeciOr3MeuGy9KFlt2uKG7oIRr7MOihn5LZuqhhc52B2HkvwgxhHWzrI7rLRMihtgqmf94zXDdtq1QqV8fa
# DATA Etq34T/xlmzrrdadP82ouPWNxQq2TcRWIGArDVdQC4SSGIfXOqe4to7Wej8goxM/U6yb1Uq1WuVRgzKAuqh9730aQIzVwwQLnnQN
# DATA gynWgvXO/1nQO0AkBUedGQgFiit6SAMBzhaUGVrnVrfVZkqx8TwteNa5CXDcLDe8b3t418ysi4/qL4cz7xpH9G0P6BuN5xsP59cy
# DATA mkttLCTd9tE9S23oKhhZhYQz4idTzHY7mTTpDjK1aBZi0awHyzzATuIKJTQG0ocaTUxJGMVgSU1C/dpBEI/gr+wHYBUxW6iYLIy2
# DATA gcnoMQ1weoE5nmRTJAkuUmohm9Ky8pBZMyCT91H8mdLEW9GHVOfgXqGLfKacT5uzf2OCFT6ew86ZEDUNxAGbhIzMErMgM2fFKUX3
# DATA T8h4ewhPWRwG6iR7JIZhlGEfYpwNsY4ZwKvRF+4K0hUPsAGxP4zGgcc735nCNeWxyKG0HErLobSuEKV17hi00VRnQ/P5+mYBl5kE
# DATA bGEO4NBZDp3l0FkOneXQWQ6d5dBZDp3l0FkOneXQWQ6d5dBZDp3l0FkOneXQWQ6d5dBZDp3l0FkOneXQWQ6d5dBZDp3l0FkOnfXM
# DATA oLNqjUa1eWl0VmPQHrSfI3RWYdV5I3AWZyzHpcsZJ2imql+Qo2j5nWKG17vd1TlerXcbiyCnbo2RVCooCy7Vrna63d4yuFRdAunH
# DATA KUtQqZe1LLZUnePJB+Y6RZpU2K23W8uebzY3er7b67Z6y57vNDZ5vhP12oFfzoRxrVH3arXWHlXsZperd21c95t7fs33+NqeXNvz
# DATA /fqe32jvtdue3/HtoHnDaAnP1Qk7YXdZDjIurFTz212vUfepwuPVXnXYrZaCM3m3EFz3EggsbkIagSWt0UJg1VutXrt2GQRWNepG
# DATA gYXAqlFA7RyBVQurYSNHYNU6Lb/VvXoEFs2E9uj3jSbttRqNlUW/VWGkkRFPh+jxATnDfdI2nDI+dYJ1AKl2rSwLxJuPHpVcJtYY
# DATA sHB3UDL7jSneUaZ4/oAetcvzwGVzPu0l7LCXUFYH4SdcstjWKiaiuBAgc0TPnvgoQy5/wgyDS1bsyhiupR4fXVGLHoZV0C7jPFbR
# DATA gd/Ymn7x93PyqfiiFpLDfsXC1pPVz5tx+pzXrJjCrcZ6mQq+EY5rXeVdPa0vVeZldXI+OndyyVFwnC/H+XKcL8f5cpwvx/lynC/H
# DATA +XKcL8f5cpwvx/l6yThfqAvqhHwUHtjUrxmWTDkjkLrbUteTedqPUEG4Vh3EAzYyVcO806zC4JkNASt4K00TxPFNZXmheZHJQ310
# DATA eih9snnt7ZIxbc0J2IStYHJREfoXtjVyOewKc8wEQt+pq/j4FbZrxDz37uVH/8mOPsmW9AW7B5+yjf4ojw22Wg7iCWWHopqxjKjS
# DATA fTiygn8DnQ81V7hUKzjHOA7kDBWXOt7awx5lml/yi6z4KUFd6mpwEuq9xNin3jHOLCrrk37jCFK15tzHqZ09/SP98to6u4PLkMon
# DATA T9ftPGW7jwqRETEqEwct0qjehNOAiIdY/QefGmP+41dM4PuIG73VXLhBfRUobHSNWnt+DPKm3Khzg88eldOrkmsq29r2wulcVnib
# DATA BUOTObyeAmJ7WfJsR2zo/iwd0ZTvb/5GvmIzIH3d/au/ku/0KOXpx6+8xYiHV3YfrbC8ldFNXWE2u88W+44UqpO4d2oKl1JTcCoK
# DATA L7aKwkXV7Z+quoJxwEqKRKzPUnKfBahud97TMtycUj7IOoe0Zbw6IW/qs/u58oDEEg+te/A+t1ve5oVFoZVPFbJDjAWr7eVP3URM
# DATA tQ4hH41dKXBvSExKCoFa9Xpx+2dObOI5OFzN/90yOaEoirFtbkJZa2QpNeGiKlkfpbEy3eIJsxrJdoMxY1SyjA4IK5dlsICPIWQ2
# DATA nouGwwn7qStGQF8qo6o8XFEwSmaiaG9pekDjIGCLPhnMGK6URuxGZwKXAm6xoe/xwiDrjU+ih+zjVcoa53KMXoxz8iYEZ9w5424j
# DATA 466klOM0s5xm1gWsupWm41Vpab0tgk1UsdVcXjkRuJrnZJ/rVmy8DpF75VnQmauT/qreiaEVx/VtUE0XTxkus7OsILBOGTkasUeb
# DATA AQhYK+bR7a/gYjpAnyafbqkLyqKWbxX5w25xdduP/UqtUv8JDYo6Risk5ZVTjd71Nn/iKltEEJtbTN+aP7RAAK4xsuE48XgryRrw
# DATA cEMMb3APS3cugIJXiskbH1ZedZ5fHXlMeUReStlIyyTO5kbgbCqtpqIkzP5LcBTcly5WqZmBsKLdoGgmKh9Y7+14UtRCE9WsAJAW
# DATA 2yWn9LFowITomSCSRifKEWqaOxSuRICLnj7G6S4eOllzynL/7XumuDAiko0878/misI0ise4yBuNIFgFkTimXUC7K9NRKVWEfCpi
# DATA m8n51EJKq+g6xdxSr/Ab16Ga85mac77s/IthoebDjDNRnYm6kYlq2yLOQHUG6lrD82mLvb5XaCQTDHSzeJxDme7LMikLoFYsCqCk
# DATA zntLyyBCYBHHdzi76Hc0lTDhsRq6nKwWGhxSvLDlbHJi9CA3VHDl6JrYCAmKagEEHcUgoMZK7T5ifUt0Hku8derE8RJLVfYooILx
# DATA J0UHUpaM/jE3rswVlp4Acj7icFTsZM+N6ZZWs4rMxgeG/sjnol1p3WG6RPupBZMROwcwOqJjlPvidRYmWqT2Ja++y9KxFYyj+bom
# DATA 5CiLDzntb/KnNbZrkQ0uOwlsg0XRzFeZjYUyxu5qaayXALDr3LgggP3Rp6sJ7JKxQmDHJC7SjHTltD/RJPYPsWWUUp7OM9nuxTVw
# DATA wtqpSkgXcyCQOfUKdIxNGAE2UHi9ORm6SjE17u97b8YssDpnoV1vHGc8e5S9LtiuxBRR3gQi17i18sqwkBiAIKLXpYrP9sRo+1IN
# DATA umAG/+fff7U6hwu1UTKaJV3TSIR/4VeN+/HMIO/5l5y+xNq3ZFSLlmoy1afuZ1TbUtbxxeHVWSz2+d0BHwqnucG4Fx/OwX1Urt+K
# DATA 7u4EFSX0x4CMfZbwjUP+TSbs28jRS9bVcbZZXX0vGEtVgJR1nnVSWzDFgYKt7PMVVVvoVI+iGZBYsrvJPO0xxgO9F4M+ToCWFVrX
# DATA BMqAaBBk/VF0qPekolAbFEwDefrV779eqPIJ64xjT6n4ZB7NI51/72AGh0kbTaBzJebjIGZnDl9Qx80jAKDflAbJaxJScbK8onLA
# DATA yPoBjhZwflIGTuBC4oBm8hQwvREoijRUotC2UvVM137BjHx7Td1Tg4TkYXmF0pulwRGNm8eUBp2ZH6ijBEMlkB1ItUzJhonCTBkF
# DATA 1MtNZgyOQ1iwS2R+Qg15YnoG1auOqdfIeC4ZQ+LRWlbN4XKzWMm5RzT/1SrcsP2ear5+uGm+fsgEPmu5Cucb89atlsPS6BD7weWA
# DATA CCUkU0MGRptcvd5Inmfsq8gtw2gw4By2+4Ggl7F4Nc3Q2L0j96jqjN5UrL4Yne1PZTdrKUOLRoLsWbSNBHNFsofsWr27UE/s2Nmi
# DATA dv1RR9QfJtDPCuAvpZLUBfFSLLzZGD0qicgm6P3z6Tdnf3v6xem/n3599htw785+DiQe/feb09+d/VrQeL8//fzss9PH+Hv69enj
# DATA s98sEvXscJiV93Om8eHZb85+hadOv6SLzNsT9B79/ZNHt3xx9vf03J/PfgGcHmLQS6PjPYPe+/Lsl/T3N/iZiXt/cmi958FbIzXN
# DATA 5s3LlPNBjFY6kW3BIDb80PhmRPke5hhZDCGUfthSkPUN/P5AbydJo348VTZXNkd/xK19nLBY/1qS3hsSL6sBOZie7aVB7lw3R2+x
# DATA TK4OpSdVJ19J/ECqkkielG9GT2StOUbHV0LL5h3VU3XogrJCJox42ziazB1Pb4My2zpST8x67su564GXWfxmPTIgdO8m9jx3Yx/m
# DATA 3RJV1+RYQX004Zx11gT9y4cOUGjxeIwzOoAJUWEbGPGF6t8aDHC5UT0txN75iXCMPTfOP+E4r5F6lxreX5IFmGsZ2q9gZN9oYL/I
# DATA uH49w7pUyXIOWGi9p9l0roKkV06qXhQRl2rAcpOlETGzh0TEf2FMrAgUSxZnZY1VlCyOolky5WeijA+0J2QuzYZJmG2CyfsAeSjL
# DATA WOUYUfbCQ8Abdyn54xgbTBKyyrBnSwb6vLrQO4NsngIMFrDAKGUy+/Mr2m2fRmg/nKITLhnRwRESIBwrTKrTlSELRoL76sNZrXlm
# DATA jobnaHiOhneFNLxNRo+N5iqbGrvXardfxmzfhtXuqHiOiueoeI6K56h4jornqHiOiueoeI6K56h4jornqHiOiueoeI6K56h4jorn
# DATA qHiOiueoeI6K56h4jornqHiOiueoeI6K98xQ8ZqtWq/eviwVbzDoRuFzRMUrrzxvBMYrUN/qXYsaV6/WDfXNb7eL3LhBv9NVeUMR
# DATA jGlkNUHU8yAajWpeNjWh7cnhqVq3EF67UevX+wsFVWv6Xq1WG9ba1SO/0fhkr+V1/T2/3vS6NfpT3evgy163tqTkFtF8zRqF1qwO
# DATA G61P2m2v7e81qB74jXOocyawBUxcrb00AzoWuY8ib1XOejPPgHrhvd9q9GutenUhyvVW1fOb/id7lNYG1Za9tj9uNijun+zVuvrK
# DATA pRPg1y4BuuNWoUF30sAs0F27Ua83GhuA7sJBqwi6C8Juv5GD7tqtZrfVNKC7sN2v9izQXduv+432NYDu0KT21tsbHg8v1q1lPtx3
# DATA I+oF4qAiAZcW8xZQcXVeMMuXy4pBK7tlwUmlc2jBEVny99thLfPAX2hQ9dj3VmXDST2jlsCWJt24VRcjaczyIkJOhS3ouuVbBcpE
# DATA u0XM2tKcMQOfXv2qrqPBbVALrsoUcWg3h3ZzaDeHdnNoN4d2c2g3h3ZzaDeHdnNoN4d2e8nQbjbMTZLNB7ZuC0gtxCm3V3a/I994
# DATA yZGxXAp5lsyCkdyPFnXj3WA23OeZ5A5f3L1BOYDjqPQe5USbQmNmPuXbdwrvuCnf6MeMe5FZcg/b8XZ8O5SP5DCZFUj5naVg+NmF
# DATA I2eaICZTQHOkwx2idoeolx2iLh3zccep3XHqix6nXiN8e1XHrKUVsB0MvXZZZTXHrJ+ikMd1UBdCdTxb1Qx89XYOd5WkrW52E3Zg
# DATA 5ALw6qm8b1Lfc2ZBkcUwjlmArqmwDez7l0UnbLHgtah9f7XwrYynkGI2wxqKAYeqJf/Pia5+3sTXXDAR9lvLItyxIlzbPL48qILS
# DATA xvHgaNKVcyKpHsp1e9X3AgdiIYa+FcOOHcFi9FbyHt5QLSoyokHPL+7hDbbyeBhjgBcmJ/pA8tsDqGyiD+Fj+BkPdGh7GZkl0wr7
# DATA NKmVjuD1H514UNJEJYvByxOjSLz1QueSWsfnxqkZqhBDCoIChJkz1AH2Exg9KiR9HJz5E1yTo2yGdXeeUrEE05gtYksEAKfBWYGR
# DATA l1FDnCTzZO3mwBYDgMmG3i9LxpHuiN6h2csRZkhDBmBw++5jd7BKEKKd9zXnAxpenIPFDhLrLNn1lqyzW19wu/WiUNinLg/EC+bW
# DATA QvCi0TcqSAIy9Sdj0W3FP+jxMVKYImsZqk9dVeg5UeC4CmzqggLStsmpS9SklsNTN1NCLNU/ZLVNU2AR6ddTpFUN66zanitI854e
# DATA PRGaZwKn0vxUtsUizLPCk4KkS+Bho8R8rOwzVDD6kEXKUEJgUpOKBopCJ9/jG4xRUpbg5jh/wGKvEuWIsljH+G0zUYt5DkhRFT2j
# DATA WZxWWJmdY6NV2QsWmla8t/EBbJAiKLICcARjTbTfx8Lc+ljfB3RFxZq3KUWhjvhbWuIqpNktYkNJ4Nyr8JSv4p1gs6yoOqHHmCWH
# DATA EVSs9j3LqE5YWXTsMahAUV9WRVe/cDHGL5GAjd0nOUvTWZrLLM3COOU8ps5jep6B+vSFKSUGmVJWTJNkzCp13CByecrRSJrKUpHE
# DATA fVXPK+KsqMhgBN05NCOsTzMVjD0rnqzeqXbFy4gXo4DdYytBqTtKm1TLjRwmer4pYzfhAg5G2MAgAtkOCrYJFEwsLtu0WnWn8XMz
# DATA 3UV/WX2/VunkXFWfV9+tZTyL5sezjxHL8++CHBf/lt9ajXLRhSEolx9MIupMpuxa3MORRW0ZYn3Db3qH9kpGrVGlC8qN+FGkCGQ0
# DATA BcFWudFJhex27P3tUb0Y4OsM4yVCxh6SDGsecqoj4x4CxtZxkA1FS1Vb6HRpNMq2wcG5lvz78Djh/AtpnJoWc69eLeZeo2Pl3n1e
# DATA qEGyua9VmQTFUgCdZyxHKdKYcpf4hUcR8EXYrOupQ7giVLqF3Cq0wYtnWHN1hlkNWvLsu9SnUuzupTyVncoEJs+3WqnW1dtNK99m
# DATA MKV4mYwNp3gyn2HIgWjpqDix4hGDYT1U82h2pSh4ZhJ2hB2No2cg71oXyLs3UAVSkZXI1wcL2VeqdvVatZR9FZ5Ks4l6KEWR0TxV
# DATA lFJB7JPWiP3oYRocYyuvXhpgvdl8aeBJ8szuwy+YZe+uzq98NFAIv+RBoK1rnUn3mFMh3Aig+4ReeEQ2hzHTycJ9QA1vpNBOIasO
# DATA j5OQSX7eEOvA3gciFMxMK1wxyydmVSajgZ5ynTV50aK3kW32YHbhmlZbnXH5wCgZZxwDRQNN5+F9XFVel4nnd6iGhTqvAq/e4j1D
# DATA VFGxLZBdCDRdUo4Ysd0YI891LfEO57HiezE3Vnlv2GzkLefPKsLrRXFI5BivQTyDxKzN8fp/Tx+f/eL069MvwNh67J3+8fT3p49P
# DATA //X0C0ZvfbEI7Pof9NPvTr8BY+vsv+EWT5Bcp38+/Yp++vLs52e/riAcCpPC+pp++3fv7Ff4aY/ueEy//4Lf9Pj0a3rzF2efMR4M
# DATA yC5FAPsFff13CpB+csyu58GlkkP90GWObR6Q9CFZDB8oNUmNC0zn/Rmr30uHQhkWzQS+eITpXzwWF6S0W7hQBzh9Dg4AFEr4KXAY
# DATA eSMqb/fsK438JBitxXi9hZXxMDgxMXUcL9vXojqI6wZ5LSmVqyN5qVqYLxndV9VyFFM805Py/VIb9c1vFyrpNmFecBmqmIgWvuzM
# DATA j3S8HNBrs6LbOtPrfpSDDnIWRApIqu6yDJWDS87L0NtgL5DICDNUwZwihufnBF/3ve/FoZ4dU+8m02txTqmULpC9zq+Mq+2ZxVb2
# DATA tNBe56fCob2cObB9c0DTvi5nBbwUqy3XZQFchQGw0fh/weH/ekZ/qZgLuWBBv56xRnUVHLCF5ANqirWhjDnv61NW4RoI1StOQjmd
# DATA b8/U1gjeAsEiIXGQmjfpoDjlsuCE4lSug43IYB+yrxf+IGzAyeB6i9JgVFGWHA1ocThH8UUhFyOMtZRqCK8hhznmiSOsTQGzYwTm
# DATA AQUqLg84p6iNwzUTT/YoixnE7pF1MYsnkXZU8fIZQscyNMyWitgs9GKxQwwIylHCHCXMUcKujhK24ZCz0RxoU9P5eqcBl5kFbGMS
# DATA 4EhhjhTmSGGOFOZIYY4U5khhjhTmSGGOFOZIYY4U5khhjhTmSGGOFOZIYY4U5khhjhTmSGGOFOZIYY4U5khhjhTmSGGOFPbMkMIa
# DATA vXrIP1+KFNYeNAe954gUtrD0vBEqzM4Xv+nV/c6w2eqWaFMt6h070TLaVL0jOcRlJGXQYEVKIWX5fkGpp1x2Nd8uvFYh/807C6E3
# DATA u/4Vht5t5YE3uoXAJVV54H69ZUPACoF3B51eb1AOvNXsbj30AuitISw2gZT5rRz01uwUAoiaQdCpLzQLetzz/c5RozmqdTy/fQ6B
# DATA bHWdaF8CQMaNTQPIpN0WAGTNoNvaAEBWuAIAWTPsD6o5gKzVb0adqgGQ9Qf9WhhZALJmo9/tXjmATDfQtfCpfb+pKWSF+83oqBcI
# DATA mpvQxopBaN5Y3o/rnFpwZFqP9rAos+SZTZcF9lvKAqnZjofa/pI1YZ8NosKbCx4FsQzwHM9fjDfJb5KdAJNqiUeyZjySkinlZZYl
# DATA C33NhRfUDvRci3pvP7dLStHvsD23jIvW7XaLNDSsMq+mlBXKrVIqizXWTvHGku/BuA8dhsxhyByGzGHIHIbMYcgchsxhyByGzGHI
# DATA HIbMYcheMgwZ6gKFEo6iSsTLROHtaoWd7vxpSmZ3lN3+8U8qcKgeRbfZgq2go30fP91GlTwwFZpPl8E6Snd2H8WDHXlo95EOmloo
# DATA TJBg0o/2J2Sh7u6pVx3YwR+wqrM+uLEj0ds9QFfw8Ssf5sfYQsGJfWrNcbCPUL9fShHHPta8F+mnpyiprORBE+N0R/VW0CeW9FMC
# DATA JuGN21O1ez/7Dgy7A0ofAn+Vftt9xE/fnh7wmQyKE/34F3yN4rE0NYUEm6w/MBl+ILUOE3pu9HkNozy/p/SdKe8VEk6f/DHKz96H
# DATA OCRVPH+ZUvSZ4EH5ESeSfWLLH3y6+nVMeutH8Whnh5K6hzTv3mTTFpA3lSUUE0qyqRfUkDj1++zG3X2UVxjrssTdvo8yzubi5TVI
# DATA xRK5KjmkxoLdR3mGoehQnDFlY/yqIuexpBvSGd+4oW/en87JNHmkYn5L7sQpO7qvwhGhifVHOHX3n5/9X+pMI7B58Q1/l7oYisRC
# DATA 8Hv+7pqwcTzSDvsDHJfk5Y/F0D/N68Knqo7wZFK3ycWqrB44KNT+A6lntzGD1VXPuqFSa1aLLSqdT0RKWAh9XB24ldGF19YZuHmb
# DATA V0+lOEN63lNcvnZ3YdX8PAdK/cy6JvEBVFbz9qAShajoJJk54JJo8RmUeETzIdOn6hpoHpOxYrcQaQr2OJ7QdHFZoFhJo4eiUiY5
# DATA ZozTmbikzoTTl3jx9SUuSpJ5FnQneGWl4K9fj5N5F4fgQeSA+Ko+OB0c4lWzZJykNDNby5R5FkUrnp8j3FdBmlnU2Ng2amaZiMkl
# DATA WTNeYYlIqjSvsN3xq1oaWDCbRk6MXqZugYCn1JNc5MMWen9AVllFXE+iZY/IG8tbVvOSKWaRgOsJ62E4T2cs9RWr905p5J+IfkKi
# DATA pD6MiP0aoY/zlEdfoCP6hYbjTChnQm1oQpX6Vyfa5US7rOF3pfH1LIh5vT6PwdQqylYZKa/vii6U3ZQw8kyjBA3teJgURihBCOgB
# DATA bN+7CxEbFB1r6gQyF1bwsegBNcdgFA+geAPRbTgfREJqEkWhxoxdlJ9iIqqAD0pOG9LqlSVKWg6esgk8ZZxI0bHevfq8DoiSshtN
# DATA JPDl8+q7sdtHuNlv8KfVd2pzR/GF+PPzgE6xc++CKvkdGI6rdfLzsiiwLNirp8XxeVaUj2wYv9JkfjjMG8NPGfbOEh4alzSfkPHI
# DATA WlT5hmm056MkZm2rPpuHnj5BD6txzmJzU5bvhbFJcTiMZtugDDxB/jUvln9vRtkDj53tFloA2rgK7mTSy5Jx4grPmGdomw7HwegB
# DATA 5ZWWD+TwcNt8BEw3oxq9aMJlwOJtOAXhhfNUi+vSILUdpkXeDC8KZ6itz7e8VUu+vU5jvOz7Y6bOPDa1T9lWVOeiaKWQIVaPJmBZ
# DATA SF6yNJ0sJmSK3hVls33v+wzEiPrDSfzJPDIKilRJaUIHVsJsiGnHMOCaiHydqYq7hdzMu6mL5uU5dVD3epKTH1HdYRVELdVsMKQm
# DATA kyiNXIXYQlWoUYOEJwu3/wBSkCVTVuVewLKLCvk3itQkk7NdacgZUe9BcRh+Wi24dbEW/HowYjtCTRUim0UD44AzJJtPMQGjBAZp
# DATA 70TNDfqisyg7nfc9XqlB7rIcearYbpRrgyiCiCKmWmRRRNk06sdMhBX1y/SE9QzNJHwSHW8jB+2x76IVsLo+C/OhVMFWULlSc1FT
# DATA cGnaNeauDZ29IvWYaVg/AJWHMuqYDGyY6thB4Q3JIkT9QpaxCigLH1Klhg7kEbaKqT02zyxU5QVybeRBOL+G82ts6Nco1jTn1nBu
# DATA jUuuCa10gVyZRrmqsgX6K0xxqubGu/HUWRnrvBvMZFzJseeN3rzMgd3f6uSivmYmvbyrwR45zRU96+Vcys9HYmcIfUsGAzENglDs
# DATA goJDgne10M9sI5leZ0dtT9lVfhHdwie8oR+vkEipp03PqL+beX5djm9iGEjJuCfjhc/c4eI4eCh3VOWcXDTlo3mrfSe8SYZTYpXp
# DATA xlFVT5uo6u8mqrVzo+p3No6qbPtBZPnTeXHTt+exM1dM/BrLoudb0autiZ1aFTT+LDkXwNM/8PZu8j7FMZnYciObH+n4zqsirZBn
# DATA IY6F2HUwv1Soc1Ma3GdyHPemBJFXZOObsdqHubTCgSMmEU0GQ8vULij8/zXZpn09QaWJ+QCjpAHpyJThOKDhHbCdKT1KBhpmYIoK
# DATA lM9iNZBS0QnVZEsoqWbvr4W0xJCcjPYYZsk7tugtIXiYidBE4UWpeGH8s5/FGFLYvTKZZxDkz07I9k3GWe5FtWM2jEbTcxaOS6Wa
# DATA Lx7bftV8GVjyX/Zs0ePv40Ne4pcKTLZySaOMZlb1ERuWS+zlsMot1uE8JZuYTDqbdvj/MLzwC9AGiwzCs3/Efxdph/98+jnzCL86
# DATA /eb0D97Z35798vTr0y/P/p6e/IY+KW4hMw5BLJTAOWSPgYifA6N49hnd8Puzf6CHvsRt35z+kcLRT/7h9BvgEh8zBpGCdMzD52GG
# DATA YapXPrHgCg/iCXKUnqkofyV3OBqJwcJJhu4sESaL6H0qRaERwLAyBA/qSbXRM42jPs3G18ENP9DbGGgAYLSaQxtakwldYNcNN1wo
# DATA latDG6o6om8DZ0MTd/iXhfuxfcXqcO8nA7WnZetoQ45AAWwYZ1zZHdZws2LbOtbwrYfTEXqZQDtDxkk4HwUgrycz1uzZ9z5C3899
# DATA V77Pixe/sDGenjX7nygO8zH3lJlsg4ILJZkFei0rmAg6ZgFoeH4VXG21lFvW08IZnp8GhzN0I/0TjPSaW3iZAf7l8BRe2+C+/bF9
# DATA o6H9giP79QzsUi1LeWAxC59Wy7kKOGEplVgBAAlIcf7ivpVYfc6xnKBAXJoKKgfamt5EnaF4ePO1bCvWEt2wkibsFS3n24ZEQuNl
# DATA zWOXzZI+rzjyeKxRccyP41oS0lx7kpnoR/M08YIx4994yI/IbIj7MZbGCzZBwQL4/9l7tyY3jizPs5/1KaKqrCwziwCIO5CkktoU
# DATA RV26SIpDUqXpkTi0ABDIDBFAQAggk9kqrUmlrunqrbLW9mybrdnY7raNzZrtyz6wVcURde2H/QLIrzCfZM//HHcPj8AlkcnMJCm6
# DATA qkgCgQgPv/vx4+7/X/AQB4sReCeAN0rtqFZrhWQ9UHHeCPwYEWLbrj2GK0aMRPbqCKVO1tZVUbcmB1K/HK3Q0QodrfCsaIUrDjUr
# DATA TW1WtYzP08Y/iYl/Gha+YxU6VqFjFTpWoWMVOlahYxU6VqFjFTpWoWMVOlahYxU6VqFjFTpWoWMVOlahYxU6VqFjFTpWoWMVOlah
# DATA YxU6VqFjFTpW4XPDKqyVqtVa+4SswqDTLQWNF4hVmFl4PjapsFbyKqXiXn5z8+NSI19peI0a/b1bqZU/rm56Za9e9iqNvc3NVC61
# DATA S61Ku5vF2FFY9bkYu+oM2VBO+gnAbzMN8KtVShmCX7WZlLUcW0sIfkEz8Nuz4ESLD9ispYIvVzbTwW9WFoZukpkKvVqsLQm9dqLQ
# DATA 7RJplrxqtbFX3exT15qvbu5VN1fO6dIsjLBR8mqlxm69VsuE0q61W632XBTl8bGD0m40dlCaoIUdrHdqzUbnSOyg32116ynsYIf+
# DATA 7pQt7GCnXmvUDHaw1W5XW1ULO1iuVZuVM8cOmm1qEP7fWWm+voTbJ/atN2MXaXM88zYzUKqp11sBdTehn5P4zQUY1tRKXHmG1oeF
# DATA xZkXZNzuttGoCyQ97yZzzyvBDvDq8scOk63TlXOopk0nZIoYuemgrvhZQ8XCBqYja28u0CO6WvYqzvP2ymJKOmll+D75L/XHnnEv
# DATA Jw5msjWXzZMlZsvSJLM94YCDDjjogIMOOOiAgw446ICDDjjogIMOOOiAgw44+JIBB22+myRbvBhCSuOj4oj+xq+axQvlYo5mluqn
# DATA fS7CDZmyaczXNTkkwwfd0Mgu8K/g0rX7CDjw/r//3dss4lsnCIaFD+m/AWhrFO6VreJrH669z1rqfI6OF2oQCP0oQRR4ykMRlrDM
# DATA 4RvExWsd4F6m4/mtGCFumKfwid/1jn2UTVLnBfEYfuTgkvc/fvf/IjIzaV+vlIsX5CqLe6JrQJAaZeYQYu5s91Fnu92Z7p/6me7j
# DATA ksKeh7PeGRfbckzYdTQN80TBu4Fqb2u7zIWDPdPT4S/O0cizoIBlD7OfNgNsVhLgpASwtL9Wn9W/ztQuqQjymm5gdG3egOvR9zoR
# DATA /RDv8xntW3BComqxFNCuH44K3p1wzO4nLfguFVCEyydDOZ6sCjd1fN9PpIyGEG2MunwWORHNySjczJTzgwCmsm/kdmATnb/SzTM6
# DATA BWu1IGcMOWMoawzN9KhO9MaJ3hxlRj0fYji3pL4y0aITGfzFR1HLKOLcNtoN1AzDnYEifykNNYWPHNGw0Ia4RRc3i5JE7AO/Cveo
# DATA xuPwhnyW7xAdGrghe7Z2yxzNlJXBX3ehOgP/WKJkY/Ng2Hchqh0O97Ua7ouSAn0SlfQxt5rFsC92O4osNH9cfC9vz+We5S5/ehHg
# DATA XVZeHJO7cmcJP0nnqhBXrqJVUOmKbSXAlbv7kYg1RRMIxviQYxHISh8tRUskoob77IUSWSYxD2lc24MX+W8hzzLqp9WLRKWIbL8o
# DATA Ge98CMJQ7fBFo77LhrI+cyqNRs0O5gs7zwpAm4U3sUmSBJoc01IOGBuwoMwZQw9YgtBPx786ccndXrnkbssBc7HSddFdhy2CjtBn
# DATA NgAVx45S/46Z9BUMWR1HsYTS6DAUH0v6iNo3FYFMUrc1nxEeQ7UvinvTXjBWYIGRiks8jMZPX2SplJ1fmSW9yTHL7N1ltDLVL0mZ
# DATA vQsBIuRjK6II2YAolibS6yha0GxHGFmUu9SJ42LUJWvE8LS6wb5oTunBbSyS8LhTFne4pPeZ/sbMFdPouPRbk/jg6UsrnaYXoLhu
# DATA rlxcN32A23kxg/r6hEcV74qWvmkM1OvtwB/+IDgQa7/lQ0HL24360rAwORhwaKxRN/CooEaghQGVA14VO+C74UPBxzE0ISnMrPDb
# DATA 0xdaOmXnVmjJKHzMMru7uMz0eK56RVEOxLWkvMQfgX34GAaoCcXCCuyJI4blkdtqnGBvnLfN5dtlfBd1QhAhw7gnlieOTXnDCR+e
# DATA Y/GEAdAup9DvJXF//kukvGqJ3AyUch2Gj7H6SREu5XxQoAcYaU5ibYhQX+Tx8S60gAMRJBQwoGo13L/xzBoBwOzmoSyMtZGC0hX9
# DATA u1NoM7MJOVExnS9h7qkwJi+Dn80KwjnanKMt62izq5TzsTkf2wkXGxf65M5IcFqm5DLTwwiIyg0b07jYniHU4IzIcylPlt57Anuf
# DATA N1lj+anJ+2Z4Jqx+PwJ0loRiuivrUkKNOwp1Vl+Rw7avvWUG3MXzArVrb73dPxJwJwEkgDv13QLczcXGleSyBscVV4bcyW4euAvx
# DATA QRhjQkGGSjHnVcaBqB5IvIc6hBmfXaPI2C9sa/f2sZDJ+4saxcVevlKJH7kbPERP1LGeol+WPFblx96muw/sZ6rFJW7ChYg6bZpi
# DATA Ny1ZauMXF1Jnu+72dykU7yOyPAfBQcGWfFa6ztIJwCG0H3klbmn+SMHi9Ia1IU2TlOmOVWfqLChOmF7xwE1BG3e8ODS4bxGPvXL3
# DATA a3VtfrHaduYx4JIKrFIucr2zWjj1URMNv1R7ctvpmgq9aSXDTqFoFfYcWfgPpesbUBx7MlVk1ezhZATQuyxsRzHrp1oC2StA5H4i
# DATA xnOCkKNeJGiP/O7YQsjd0Nfyh7+f/nj4+eHvAJGb/nkWHfcvc/Fv9OUxPfXF4WeHn+OyR/88potf8d+PAI6jK99OHx3+vUHCPZk+
# DATA VgrpUPgaQjuVhmyHiXvuTX22zH3P1Bnvr/0937vWCeUslojeq30lPPvtjsJg0KEOhL/tR6Nex1j/8HxPhuI7hStBXGe9A6brRnBp
# DATA C0WUnQbJAoXqefBU8JAaWmcpQu51CGiw1oTHfwtPwnHkkhmB6RTOmyM3v2jODia3S9FhckECp+b6qq8fBZO76osk+FkA5XjzFdmO
# DATA 9C+NCeK6wmiOBuOAcqsV3akD5STPfDZzBujcZF5lplPasFGTqb50UGS56IrCC3w0vKHfZWt7Z+JToxgH1Le9EcYPcrB+6Omrt97z
# DATA 4mGgSBk4/k5pU6owE7aB4Focr0Cbm19HF5s4c9vg84Kdm58Yh55z1sMZWQ8aS3dio+GlcCGen8FwRvbCSubCMa2F8zMWpJLOywxj
# DATA KDyfDe0sKHZWNgA0h0XiTjAEh4pMGTNQmxzi2fyCbGlH/f4E3TUW8N7BDKLNDguWFIkpX9qBPeKPAnZQiPcPGRarzfY00lOR8fVu
# DATA OOJTtHG8MuEOIK1Y+WY1TIwyZI8swpH4OdSvXZorh3zAgXcE3Yg+ohHN4+S1KQOj7rjg3dbxlgMKChaWdQLP2C1yVkAjyIymBZPM
# DATA kB/QxYF08C5lctgW7zGnfSDuGt7LGQyYo4MT8mhdAJGpKkG56ph3jnnnmHdnyLxbcfQ60cGuZWb5uc80TsOjetJ5hgPgOQCeA+A5
# DATA AJ4D4DkAngPgOQCeA+A5AJ4D4DkAngPgOQCeA+A5AJ4D4DkAngPgOQCeA+A5AJ4D4DkAngPgOQCeA+A5AN5zA8ArlyqdSvnkALzK
# DATA CwXAm7cCvRIFz+LFlRMcnZxGS/K9kVEorTVT2VWtbTZqQYasVi5TAVSXkNWsV2+e+NXNcqtcr5z81eX6iV9daTZa1c7JX12pnPjV
# DATA 9fJmpdo4+aurxWdW1tXGMyvrWvWZlXW99MzKOtWuN5vnmeGpdn28Vz9thqfa9fFe/bQZnmrXx3v1Uzeu4jMr61S7Pt+yTrXr8y3r
# DATA VLs+37K223W5Vj/PDLfb9TFf/bQZbrfrY776aTPcbtfHfPVTN67iMytru12fc1nb7fqcy9pu1+dc1na7rpSq52oqbJ741U+b4Xa7
# DATA PuarnzbD7XZ9zFc/deMqPrOyttv1OZe13a7Puaztdn0uZW27HspFr9Io79bqxb1G7W36mnY6NFr1WrU997FqtcGPVeqzj1Xh6Ggc
# DATA xxxTExALLl+qp4IsNSuV8mxMasWaV67VdsvFfqXmFXfLxUxutGpBrdWYi2RvnoimXklo6uLPsWjqzaIf1Oppmnpps1Iq11I09Qxf
# DATA HTT1VrDZ7iY09Vq5Xq+2DE3d32x1/WJCU6+Wau1y8cxp6uwMzrd4k77xdMpiu8aiJ97Wpjis7WeyQHSzFDdv2U1v1GjwBk1sz2Qm
# DATA +uxuxzr8rPIaPgi22raMurUtYyHQ3Qp1OWtdiks5LWtm2UXXCD6WsOt3ov1Lm/Qj/hQ9VYqfFuhVfbjAFizBlmeCW56HSYCe2mqq
# DATA 96/JspX5dThn94Fa69U1zCwDqL2giac7lzlRkF7eLi6GrdsltcQdPq+usZOb/eoOqu6g6g6q7qDqDqruoOoOqu6g6g6q7qDqDqru
# DATA oOovGVQ9sRiVdsP6hrHvKNXebdH+SIQ/LguxirtstpV7B4wrF1GRfD/qBFuCrqCLss0WjTq5JiITedggW+VarV7jq5jliWxavKXZ
# DATA 6Dw1Vohz9RsapQakI2JwQYwhzLbVlMDDvoKNJL/U5QXRuIOQuTDxBdWc20YhpqE6WC/m6tUNGEc4qLJ+8YMP1X+Xtn7xM/w74mDu
# DATA XdzJUblanHYuW28WTg9Vga1P9vxB2Ov5l8q5YW9C0/74UiUHybhLtU8/4KjwNNbE5Z7G09+Z7OwEsYyLLEDm3d6+cclg49tB2FvH
# DATA Gy5ks+dXhVKTafJvha8LtP51lv9JdHgzoUgAIoBDk3wEofnxw1Cg8qVCWQeJzlmxRDAqiOAFNPVE6JBfqOoMNPHGkOcbk7msa5Ao
# DATA CUGyRQHpORMSDVm6+toyc4ozOOwusGQ/MRMNSKRl5Gnp6aSSb1zGyALHVUYjB2IfKgFQcrElbzjGMhD8PJcW6HA6dU6n7jg6dRkx
# DATA F6dY5xTr5mj+LGZZPC9Kdt5whHbKGlrpOBkpu+20pNvOBNK4EGZapN2mwBYD8GbDdqiCxvyO1Vi1WBXTaLOSdGm01owcnblvt3zl
# DATA FoYm6lp0xMUbruWmfiPjtlJMS8hXsIEjJtQDAwjUDZZx8qyiP2aBegkuhpavJ2O+nupehlgstKaU2hwQW571JOM8oWxFcQ6gjU9J
# DATA CWFcaw4hH/mLuhyd4CEgaiLrhZ7KPEwj1SKlPk73G8ouYrm9ROlWDY06/XeMIeVpQwqKdcD7iFIxzYeFeqJyKGQdi4L3G4ycM4+0
# DATA dyfQLdb6Y8pcKXg8aUgNtIIHFgCqeGpzKapwYlGQcQmFPum50ccyZiVEhBlUTK8yZwniZTmyrbp4yRHVq3NjMbkxjoaKbcB1JRqx
# DATA mhzUz+LJECM0thxDz5nqWjvoWP3/2H8gcAVYhWzPYPI1PFCFqgcXf98/SCwqGYAk9vBVe3cDdmTquDHY1bdMMQYR20MO161wvCzZ
# DATA /H687aOIMq2FwdDnOkfzBp3w6/CgeJZtr1UBmQaV1gsUGiqLdlGUsLA15JJjKTm/Q114aMg2SlBOJ0Bk6DT8SU8wEkE5zbphQKef
# DATA tDJjqjHVTptyKhuoz+lFB+z1zULWRBnspy9wlow6zkB1BupxDFRnjr485uhCM/M5F1a2F/hnEWa9lJ0qLYb+Hu/ygARbRVmoySOs
# DATA 16NQWM+r/PKLpSZ6FNDB2sohuDneInPlVeqgsy1VH0dLbfJqFjObvNRRM7/H3+a1l9ljYtL62xHcUvLGg0FbR0epL115d+aUGXvw
# DATA yeZZIORtPctfOF0ZCJjeSKO1sl9XNuOuVp7m/NHGGBts88WblVWm5YGZ1zEZWrakYXDSYA97VE8XDOYrbWCmzVHLwZfBV2TrwuuT
# DATA EDV/Vm9bKsUMsetIwsdAvThHERkFZLr4LbK6FeAj095x+lWagiYA71au3OkL8Jty09CQubmxlq+viMh76VkLy4CD+j4MomGPWuj7
# DATA vO6BvEjmH6xmpoiLIpOc0glPG45jHxVXg96MtZhFSnOUVenp6KrJnzH2MXvQ5amYaTLDwE4ImXEylgSzFNVVqdJeErFbIzIi2+Pl
# DATA EbvK6w1eDIv/QEdPXZSZNFvgno+qxHmEnNwfsWp2tD+gKRv9FPYhh64r69zYXJXJ3mxsXkKRYsdNdlb8Sa34bJVzfmbnZ35qA37h
# DATA dOHs/MyGJ57lcRis2nOJ+ToP/rJe+aUfrj0cyr4dXgUnUyaIJrH2tR7BM06CMf2edckAfJtHAZhLKwONjdH/PneDiFgaYKxvSBjL
# DATA ZpqQ5QqrVXb8phz3ixnEah1epnn8cfG9KHU229hvv4RRPJsyXks3qcM3Rkwow3z9rfD1IxHTVjDpPNAXTTyrRxVL7RicaV71V9A/
# DATA iqpcwJ4Qaq+UCcsjbR63sNP6SsKbPiq6lVVjyxs5kg6sTx0D9R2ZOGJ3jo0aH3fSnHH5bmK37cVkMellGjuqKzCpr2lUMncQo4DX
# DATA LLRn+sUFVJu1AumAe/5kQPMhLAjE4zSj2qS/AzgNm128RmBRhtCzj0BmBkJaepmCt43LeyHZO/YiGVtCwcO2Ws3wZD1CHXXoKmom
# DATA Nnj4ArA5iLFhjWcdPGMTI4rXKpShNPJDRW8CS9ofSk+dKc/EgaJ6x2QTSSpjLfeIQfLMcpGTYpc8yuCY5nCYeIUtC2JiplUnCgQf
# DATA pWZ+HjhR+6hklBmMDG2PFd7HjEJHc7J/arMmC5g9icM2vDxhZCGzp//H4RfTrw//CKr19LvDP01/mD46/NIDO5t++Mv0yeGXs/Ts
# DATA f57+OP2e7vvD9IfDL+nu6df08L/RvZ8f/inn0acf6ck/T388/B0o2ghaSNqf099Ppk+Yo/0ZPfKvdAtI2t94dBd43X+iYJ9QsI/w
# DATA 9PQritY3/CQF8RX9/QOw3IefObr28z8hpE4s6gd5kOUEkaW5U9xXtamZAoTX42VgXi2/pUYIX9u0OUGCsXOKzLhhL1C8MEW7ot5v
# DATA pKH2zAZLjNalFO3beIj6oMChs1PzvaR7OG94tlUiZ0fMVrUqtmZ6fIErZpy9uxX4SXf9On3hytgKaKw/TVQ2hcvs6lCPZGprxcyk
# DATA 7iVlZa9QaKdOyr66G0Gn3gfEnMbUgbZfKYPZ7aSIktybULnN7AEXny9ZLNRJ7QW9y4jrLm+TIvsutr1Ufiy9od6ccpz6t9iCSVrT
# DATA s2JfHxl5h712w/pTDusab3280fzl8Nye40h+mgP5SuP4sYbxcxnFpSaapCe7fZ9pUzkLQLVJo2wPXZQ87ryVx4fLOSc7KSkNOyyV
# DATA 4Y93JQ1dbITclSVbWX2m6bkvZNrR7sF4t58UmLUX0te5oZDFGIpXIVLfjDwTXQHvauYyx2YQedJq5sN5C942/8gC3bGQiVnRWZaw
# DATA VK+KgOJxNCRra1dRcMd+CxkmB+zEekhSZQDZlF/tMBZ9Cp2lbTgjHF/a8aUdX/oM+dIrDSkrzVdWNHzPx3Y/iel+Cpa7A0k7kLQD
# DATA STuQtANJO5C0A0k7kLQDSTuQtANJO5C0A0k7kLQDSTuQtANJO5C0A0k7kLQDSTuQtANJO5C0A0k7kLQDSTuQ9HMDkq6WK36tdkKQ
# DATA dLfSLXZrLxBI2qw4r0SPtvMDLtZabbdeLO9VKsW36fvfZvMxqG3OwVs1vVKzulur1veawFs104+1S51Gp5R9rF+q1rwyPVop5ksN
# DATA r1yhD16lma9WvQr9n35r5JteteIBnlXKV5p8rYzba15l06uUcDcuF71Nr9rMl0v2W3knZJptVenU/HpxHttqTt2oIT6NvVI5C2hr
# DATA 1VulVnteKNUZGJ9NSaukkcESrgXwqifVt5ImmQd+rdGaiWG5XH/6GJZLlSSGtcopx3Bz8xRi2KwnMWzUTzeGlUb56WNY4SZxRqVc
# DATA pUby1DGsVspnV8q1UvPpY1gr1s6ulGubpVOIYaN5yqV8HJCeDEIapCfjmQXS26zWSpXNNEgvi83jK34WpNftbAa1BKRX92tBo2lA
# DATA eu1Gq0NzdAPS2yTruNI8c5Aeb//ML7PuC5UMn+5T66FZFl3KJVRqpmc9OhPYxoLLlvIemx7X8+VOsLORCjlD6HsroHE99HMS96zz
# DATA u8Kub1nyZjhfdv1ehcyTtVXX1ArafGd/bsVKOoLx9MajlOVuHAs4YqB94dgYlj/mElB1ngOa/XBWeMoLNovnU7UpXRooDMsr0cDy
# DATA yvztUDOvKCDWZLNas3wyUXVjsEuYrOJae3MxdC8p4ZxdJktmEbO1TSXXqkbK2b28cHgqgFq/cBqVFNTx5qMOAugggA4C6CCADgLo
# DATA IIAOAugggA4C6CCADgLoIIAvGQQQdUFNFLfYOs35OPSZg4TvKMcybMXLkh98OmxLakvY+Y9b+DGP2nKZAxHxiC01vKmvFLcPirly
# DATA rpqrUx8ZdrM9pLptY0M/bu6+zK8zFXF9kAvBfxvobm9LPWH1ehuXB0tzCQA5PWIl8VPvkVHy4daVh/oN0pPRFWXnPlTdGf0Hep09
# DATA xxji6Nj6xiepnLzMh4C1rcgZupFJ1WDrCiWIj1/CGOV5O5ofn4NDEgpy8lNh/iho7pUUBG+Dzbn0NPTDNXXeDx1FUiu3aNRlCVk5
# DATA ZUz1URh4t+XQMZIwpA6WMXcmYWO2eIHc+5l6+4ZY/vPL5oiUjKOdnV4qJbmQ2jlqkSSJA/0A3++ZIlBAxWiLa6W2/eM2dB6R3I3c
# DATA Tuqnt2gSQRU7oiEroIwZtA+k0Pg19Lbia6Vm8VKlUry8U9ihe2Es/gY3bLNRv45TCzkVoGxDx+UNfXfwcBgNINjm9277/eHdKP1s
# DATA sTT77IVCsY4IUUIGVETrOwhMf5G7oaQXDnhlE3eyB2pdPkXD9XkhNqiYpABvSWayYCLgjuv4cKHEzMao6zW5SDnx+pdfNi9zXdyy
# DATA JjIo6VyliBU4AUDCjRJxXftUzUlYGV8jGHV1+CSp+5dV1fhUtwGeAo+x3YiLcPvq1n44oIlVgU+Vc718OP7tb9XF/aD1IBzbP0lv
# DATA cXVjvEvjtHdtNOLaLUfSrXEa6eMsknrw299iPrh9lSLk7/shzf44+9BP9zFOzqnMx2xF0dBqRNI/SkO5/CnP9u08kTKSOKfNi9nj
# DATA 6yJ6JAo8kD6UU9ytwAtomqbbJvU7Zio7p6vj83Fhj6Z1qU4PRWYekyFvw4olBapKYU6QWOOnR0xQ1nOcta9Jq5dgxKdmDtU6LRun
# DATA ZTNPyyZ90NqJ2jhRm1VFbRYKkJ+V2M01rLvw6Aq1iUFgy7Zo4ZtnJ6B2HirjYgrQ5bv44K2jOOKL/XAwGQdH6VjrZ03nZC4YyWWl
# DATA Gp6VhJa9IUoTurxMwlof86Vo83FdKMYfoMvi/I5YOINKhxfQdmWliYuTApD70xlj1pOsnDA/slnKS9aSNzwFKvKd6YzQHpwkK8yt
# DATA SdL5wVJG3Xr5u0qrv6uUzmY8WD7Wu8qrv6ucehc/WDnWuyqrv6uSehc/WD3Wu6qrv6s6I7V+pXasd9VWf1ct9S5+sH6sd9VXf1c9
# DATA 9S5+sHGsdzVWf1djRv/9StO8S+urmDa8UF3dnr7+BMTU9VAhSBetRGSNNtT3PRC0Eo7O0FROOjAZITF7ADaZJ+l9SC2NUl2ehFDK
# DATA eZWcV+PhqAGKVjBgIVUPOwg4aAEK9w0JzIoYDVTz/ace+leGGViyX8bbnqhK0TCFeYNWBMMgiDDFajy+HtgKUuYvvpiQg7a6qdPy
# DATA qZObKf00Z0rHBbE+c1lQ3tyV7PM6C4SnJb95ytxOW7x0LqxzIU6WNQT55KFpqcJFgcz4EqzscyCO+oKIBa4ob+4lOwe1cSVeSz1f
# DATA lhM7lDs0mYaKJlSSjKG1rRRa/RGLXMExSsYQniaziuwr5p/y2ouItQ5lGs9bu6DDiHk672rK4QFVUIlyI0/oqZDCHr1jDzsRhQq0
# DATA AzYZy0/Sy5mRA10+LYZ+/FyE2ceakRnt2POUTH82llKqWjpjyRlL84ylVFfl3MwvvZt5oZH17DXVdc2n6uyzrPQBPAADuo83IyUa
# DATA 68MRmiZkgDONbGdC82N2NY8CpYE9I+9NzcUogFvK4JGa4nMdyjiWU1bDrIi6uY/GVd2MeUSi0jX6yhg2o27X8/eisMOrn4MojNkl
# DATA PtKa2tIdJODxJGFa0a3g3aEh2utSaCKiHvM6qRwlxuDbk7jEvH8RgRwYLXDqWSatmBr9ZCyGG8vIgfnd0UQ4xLjg3VA6214/bI+i
# DATA 4S47YBQ+LvDb7JbH85QD0K1G9zXfE5+4e3y2NQZKDV5nyp1gLGZEnEg/9yJsZBmD5isb8IY+Qw2tbk8D9AreNjKTgg6HQwXeRhDs
# DATA krvsYWEbVxm97ctddpl7OCOBvniA3NHod0k3p8rbp7fxyviS5N30YdcIt3gnMqrzuMrmFpUEzGIpYI2dp1KXSj6O+tFoFO0rfW+p
# DATA /rxKrouGq74nmTjAvs5o0oYGDGPQxXeVHOJN0iYMdwNNp6LCwKcoy8vS8ybL87NnDAs8M4CcHll0PAUJYC2KBaoU4SMMUmMewnbJ
# DATA ZLANS2qTmDSwqReLaUi3d3FCHU3BjINSHYBDFEwAXvQgYPg8ah5lY18KicnTZFnuoCr3QKKnyEwGGJixphQN42wixZ46ihT0utRz
# DATA XrlCfCRHJRcmWY8wos2DTWojrdXr5rXjGMPcQq/yMidyeqHElMKSzEv8yvzKp3xtSV5Lv0izMo3vdF/DyyXSaBIWljALuBGd7tt4
# DATA weQ2l6yprGN0OlYnjJZyum/lpRPs+17cMNMvvDjpPaUv/qc7+0kQl/S2ThSNYptv+S/THw9/DyDl4R+ZO/k5Ey4/O/xy+t9BlJw+
# DATA mT6eBVz+CxMsgaf8zJt+i38YZvnt9Mnh7z1GX352+Af684UQLlXA9CLGWv5AgT+efq/plQzGpNu+BeXy8eE/0G/fOITl8z9vuyMz
# DATA rVEEI4lNYSwaRZOd3TEzckRmWg2vvXAMdQ05RWwmYpOBtl3IlMKo5zO8VQZ8tmBimbkBgwKz0OczqEv5lXd4xwX1hWHP+4gsRjai
# DATA HMkymcPpXuC8MZZzC+bsgJZcL2Nr/qirqSCP0jejsppbb6mai+HtNGmWZKyykIJaw5S9JtQkho5kuUJpnTrIclttrepR8zjI7/u9
# DATA Bwmpicxq8HaA/1HJgq3b9nHciEbZEeTZFF7H72CEMNCoQRCQkY8FeKqXBzw3UBQknJ8fzpAsj6h5i82Sec3pWREtj0iE41m6Mf5p
# DATA xngNszzp0P5SuGbPbVg/m1F9pUH9OGP6OQzpUi/n5IAZ0J9h+zkLwuWcpHo0D6VPzJ7z1TKpJBexzPE6p49sD9sYZ5FiTu68KPPG
# DATA Z/XwKBJQoPRNLaybc3x9jtsghdpbBW6ZcnQjSioZRvuT3d3Y6uft0xwba8CifBALFdB7L05MKBn5yXLDLu8uxSyEISBownDAa0uG
# DATA dglrJ5QXKM8wCo0XsrYtNKTyrXYCGiP7IZkN+7sBx8L32DThDXbdwNEuHe3S0S7PkHa5yhCz0pRmJZv4vM37k1j3T23cO+SlQ146
# DATA 5KVDXjrkpUNeOuSlQ1465KVDXjrkpUNeOuSlQ1465KVDXjrkpUNeOuSlQ1465KVDXjrkpUNeOuSlQ1465KVDXj43yMtyterX6idF
# DATA XjaDzVb3BUJezll5Pi78slr2qvW6R/nmlSrFXqlY80qN4vVqo+k1mr1ys+xVmhmuJd3bmsVh9kubFa9MGV0r5Zv096a3Wc9Xa/lS
# DATA KV+m8Gt/e6NaorCbtV69ki8VG16z4ZXKjXyNbqnmK/T6zXy5lq80MmVSCxqtziwfsELRbnxcqhXztaJXbpa84rhaaXrFvUbz7Wol
# DATA HUa93ew0yrNhNKterVr8OF8uNvJNilS5mi9RXlCMaohpvtk4gqxpIjfD0Ss15XXtcITZUpuLv86R8NpctCWpuSMBFabi26k1q9Xq
# DATA CWh5XH81LU+agkXLa9VrQaW0Ai2v3glStLyg0altthJaXq1bh21taHmVVrVZTmh5zUa1VArOnJbH1T6/3DBg737GN01FhbOXn1oB
# DATA aNsgxU6TRM/i3FS+zvr/8Ida+OWj1hDmGzuL4G9WLI+m8NmQPXnweJC96ixkLwnmGJA97YBcmEd2TqsMVRg7Vf9sj1GZ7TQ2Bswg
# DATA tmAbgR671QJXcTH7LsnXnJ1VS8yJI3LCEO0cfM7B5xx8zsHnHHzOweccfM7B5xx8zsHnHHzOwedeIvgcpw2nEfLa5qE0vrZsQGME
# DATA keQQyw3N7U89Qx9Db9DburLem+E7qRRv6I7sNQrm4T2Z1nzg4cPGhV66knHN3yh8FIUDCuBD+g98qMvGvPxwTR87T+JSGD9Evn64
# DATA 9sbMiXQVwAV81qSoq2aHgg5Vg580W8kphLuD1UsOVrsD1S/Jgerj6oU/24PW7JdMXGmzOKJeSgtzJ4o6OFvssZ/QHLNlkgQCWaKz
# DATA /azPZ78IZxT571PWap93kPy0Vdvnn8ufq9++wjH5xE9r9MMDEahDaWvZSVU5jMbM3YCiEEf9AEIwfLRWqhqfgFfuNyayiG5g+nx5
# DATA cnI8BxlksjWTxs5zRuiZwgMcdbtwTOsDzaJ7iMClqvErsofPjyMiPlNN5ECun1gnz0as5lmcZjXPO4PKGVRz1OiSCuUEa5xgzUnt
# DATA qIX22tkI2XCfrpsBWVKiXcEaGLvRONoZ+cNdS1T8memmnQLAksblN5QMjTV6HVOzWIwBBHKKgsVq7NeDed8fcuZYY/485dtTUS1+
# DATA n+W9pW+k2giFFPR8ZyBc/CZsdX7RwAseUj568eDU5YNZtPidQTzp+WNRLz9QydtHQofUiXc96u96vbOQLZ6wptJYc2cmrAGeaQ2n
# DATA +96aKE9D4rvjiQi9Hudo+DvddzH98VYwilmKCStVzLcXWRhmG+X9kAz4yZAaZHDKatSNpBPNWNBUnD54sMIAEYP7lCWiM6zJZFom
# DATA QaYdk/SQ1gry+gfG/JDexuAoEwCkrahuloMSRXlMDuz6o5rQQaI+JQOanDiKF0hLtQFY1LpSli4VVIFYXMq7A4HvYOAxeGXQpoLS
# DATA 8lNdRT2gvM8ZhaxI9c5a0hQLTwdaK4lnRKNJqwWRfC4XZhKjmkQ9xhfLOCAaR6MJhLw8nWlGx0u5NwN5gVns9pVu6mqox5/O9MMy
# DATA KNwExE1AZiYgaQvTTUHcFCQ9BVk4sXjWWpqK18FMi11/yLBhHzMMWxw7DpTunpaCzIhFMmpHq0Mq9FEgkxlL53FsC0BirOztg580
# DATA EVxIVuJRWuyEmjL1XVQKe8EcpcdV1TY5tcMrb/LSZhLv1kEyO2LucmsS9jpGi09Fhh2Ns25jdXjUAtBr9Las9jOwCp+UhaUsIP1j
# DATA As82V1hFYJdZMdyzyeKs7F6hodtKShoCrt5rthDAKlWfX5WNEerl1h2mZ7WfejXiHjYx/LAGjzGWmo26j23LSDlys7fTBFUdZniL
# DATA Py2+s90L+y2OKD4svo865gibsujOa/IxufeipO1KBlOubU1ZjbdNTYwoSwzNVOliM7A0e3VGOrGc/VHHTE9584NMVFU+pvMhA+bi
# DATA ndSmO5CdBTKxnfDtVe9B3yQjG2+TqVCOrFy5HTKrqRMwTIhaa0W8BP0oHvcOFPwSP8FKNFLsvFYjvK5wMJYhMBA5TOySjHcjpSfq
# DATA C/Rci8cyUHxgpGap5fK0WLu3lRSmB8tMWYfqoNb5ZmD9GBn4Ps2Je+y7D0dtmi4mWYg5KnUMQHHZHZ2a5cBTQt3CR2qLDvVkV3mV
# DATA gG1j3lsJs70ftfAI9X6B1GkqigexLJopChiXxWlkl9VKjplfm0vzyzQ5ybB3IflJ7WInMFkFbwLfk84jg+CSjCx479OYmfNYJS8k
# DATA I+xA+Z8URIy6c6HEyW4VcYdpzjwNG4xxCzqnkVWm4zlmRjWWZpTqxSSb3oYfR8z5cGDVKn41VYh9imXMjhh/1FOrp9o3AycCtsH5
# DATA 0KqVlS6eZuNneP92DhJ/YYAlQOzJF3IugGPc53E7hKQuoyv4pmfaJmvHaJPXAaJDn0btLk+JzgvkytQ2+zI1N6HWqYy0Vt4CPz7A
# DATA 4p4mwtEjZPOL9DDnp9giMTBe1oz8WVawUnn1GnY9oiKmMbIXHLCbIKljPfolsXCUd1ccfjS7pSbInrjEWEOGUA/PDiu9iKoWRcXa
# DATA gjowTuREqo6StSIuKNAIR2F7br6lB2LZW2cPxOaKZMOVm5HeBaeVp9kEU7vT4BRRJako0Tq/C0cxxH4qDoiEJTYMxkDz2iix/yYg
# DATA MW/69fSRx1gv0L++P/xP00fT76dPZjFi/8/08fTb/PQ7AMAOfwcA2b8BF3b4OV3/y/QH+vsr+vvH6Z+nP3qHX0joCPoJoGOPpt8d
# DATA /mn67eEX9O+XeBNYZPRmCuMRhfBIg8m+nz5yNLEXgAI9kJUf7ONpK5X6hAI9DKIh8xsZsM5DO7U9MRA7EZTP2duIgcZySSsxXL4L
# DATA fXQirM5voB4kFAl5dh4vpYq9BXOJ2e2DA4cTs30oqiM4b5pYukDOFiMWDqw13Gu6lupfZlligzEOAZo+Fl9lpAtGp8kT88eCKNj1
# DATA YxpOYcGSpRt1uw4ntmqpnTpT7Krfa2PVMZAFsIMEUO33eac9L4H0eJ3E62Iq4TEXjuX+zCoHSLr9fsCTX4wlvI4Y/m3A9A2vEwbj
# DATA ORixIyvdYusk1ZaeHUPsyBQ4jpgb3U9jdNc8sWMP6i/Fosh5DeinPJ6vvBhyrNH8nAZzqZF2HiTbrZ590zkLlJidVnEMqx0cuxE9
# DATA h8WHdEKRAhNLXVhYJFqS9HfAYO8NY6EqcdLGfvxA7VVBBMIBTo7hGJ/KktVQYgAYyVC9B16XgjV1ErKTVBsZ1tvaJgB8KsJGO9gE
# DATA WNsKyUCYYxdMoLsQjufZA8oaYPAR7ACsXsUPKDATjxDOca5NVL962KWNPWST8SiUMosG7WA0iB1HzHHEHEfsjDliK400K57AWNE4
# DATA Pjcj/2S+x1Mw8R1NzNHEHE3M0cQcTczRxBxNzNHEHE3M0cQcTczRxBxNzNHEHE3M0cQcTczRxBxNzNHEHE3M0cQcTczRxBxNzNHE
# DATA HE3M0cSeH5pYu1aeJV2tShPrdqtB8wWiidnLzsfFiJVqFa+y2fg4XynmS5Q/jUq+VKv38lVgtUofl0qVfM0rVcteqVj2GuV8w8Nd
# DATA uKPUBAYsnXWd7uZmoztDGAPgq1rc9Mr0jmrDq27mN+lC2WvWEWTNqwHj5ZUQ9iZeV9lMB1urNzvN7hwwV6VogbnKmzUD5ioV0/Wh
# DATA VW1UgzkB1KpWABWL7NWcrRLVeWSwcuO4z1v5Uqk0vArlQ7nmNfP0V6nUL1dLlEceMrfIWbw4IXYp0p3VWm231mhmSGfmgRnSWf0E
# DATA nDJuGYZTxo3M4pRRPWo0/BU4ZX63kuKUdcudRrtucco2691GwinrNNvVVjXhlJWb9Uq9ceacsmEwPpJShvFF37cC5stylFXYTVZo
# DATA 8vIYhrSNWRKYCVljzlIz3Wrtl16N/pRr7HRMobkkRyUEFeHVnGoqVcaxVjbT3czby1X2BbIbL2PbiOdpCcJLpyuXit+SITx1m3aB
# DATA OWSXQ3Y5ZJdDdjlkl0N2OWSXQ3Y5ZJdDdjlkl0N2vWTILmVxWByujn8Qb93wx7uFbi+iiQ3Mvg/XcBiLUv8rmDQX1TU+H4WL8pWm
# DATA WTBUqdWw9fnh2vaQJngP4aIMegeUGxcQ9AXKle5E5ML4eFjX0rlSZ614FQmkLCC19GEuXx3OggYZgpRjNz4f0sYBFXMGS/T+HGXL
# DATA HTs+7rFjd9z4p3rc+CR4refgGDK777S/azllSwSsTLznHlWew9d6Xg4vv1Bn+M4CuJU+bn3KpK1MZTgpYstypCaHyFVOJ1gQyDOK
# DATA gLxSXeHs2q1ceZMn+Kwrp3XouPpAKHSg9ObkIKypPvs+PdGK9nHaOdiZ9CDfp2Xn+pATjbpQw+9MRlxB/VFfS9+rM/H8bh2BbbKt
# DATA QzJ+edusjoKmhFH2dLFI2mItzjH8RB5vThHLBEutPU4b9Oy4LeBEZSvAiztkk01GLSM8+ZIc9bTCcHaVs6uWiLXZlcvpujhdl+Ma
# DATA VEtwW2ej9/LrQbSP7l8UB1r+jmisQXJDDWyl85cTOwW6Fq9AqB0g+lpKG54n+nT1vQH0FgIlw2LcYt76g52NDAlowOtACWhHBWG6
# DATA Kf09hUOiRFOXDD2ZfsjytsUC+mzqWWRLjhhH2MuZ/LhAzl78EAD62IItQ2xxpcF+/cj46ueTflVfSCBczeK8ONsxxnYdO8pLIsye
# DATA EqY0wV2d6Nggo46Iq3rURFV/T+HClsaztCSWGYKSWl9Ca1VOF1Ej56puUZJQqa68KntNVTzVGqOt5Ztckt4l3JMU0PirmK0XJYin
# DATA o0BZzCarfdvCR0qfXiFefDR7ow94Da4nuwFzg2atlOBhKCouPNyhx9EuqI8n1AtBqzye7OwE7IEGMIJXJlQHEY2AsQBUiVWlMQpz
# DATA oAMAKnqaxiUMNPaNq3YHARUy5Sfsj6eigR4MFIL9HcOIhQIVjNNYRvJO2GXplLHoD7Gys6e28gYmPiJHD2kijsYcdaJEkohlleFp
# DATA RGQ8f0h1DgPcqmynn4ixmxrBnLnrzN2F5u6MaeMsXmfxLjZhnxOFw6usvgfN4i4GmXDAMmbz+U6aL5tIAY6CfsiIjtwi1b03hSk4
# DATA M9ywsNnOJOwAZ5gMjBQatdfOBABCHt6yJnAamjAjcGjuo3HdME2174mH+veYE4DxbBTR0OGP9ZjLdnifGvgEJpSyA/ydUaDxlbND
# DATA ptI/pJA6NFSb5MBVNTNwsjQgxGXYcxSwJpznj1GhKcKXbWq7JkMGD3l7FN4RAmpAub5gRiASb9Ee729SDE7Nzx1qhhc2cgoo5GEw
# DATA aofY75iCoEqGc8GwaJ8lVKi8ZAXvLXC2uBtlbxpDu3Zhc/FdDDABsRLuuuvBmPtZTgZMG3+c8bfh4JqJrMeHG8A+WZbGbS1Hafp7
# DATA ncj3MWvT7B3V90NlMieaexpMhEew/kgF3YtzTMeIDbVTG11iJt1EYOgpD2CCqY2WPLKMeEhqwdIOOmHblxJU+Exk5UxNtzBnwUMa
# DATA 83oHy1J5k48UG/OL8SU6ndu801MdEpmMcvAks8J4Xxc/Tx8VKScE/ESZrwMo8SnxT4uRxklKK1UWvDtB8IApIXDLMs8Decm3qmqh
# DATA FStTfBn2nwo3BGqLcBBrR7Ef86TW3xlEcRjPkDnYEDtK5/tuRB0T52fSBXGrOTYpmn3aegw6FU605eZWjQHubXZinwEZ+gaqr94H
# DATA Q83VR9UV/Xc9TTkDSvTVlLMcbZbKW+iyZ0CKvh6OeVY2om4LQpAChVTMGu45RWDyDGDRt3ryTnSQnNqkcfE0q3MGoOht6oB0i0cv
# DATA 1TH6ulyk8BaNOqfMTv6pz98sLg49NY5tLM5/AQRn+sP00eHvpj8c/nH62Dv8DIga+vqYLj85/HKWjPMvjLr5V4bapO+efsOUHI9+
# DATA +nz61fTx4T+oUP4RXBy69uPh7/EEvepL+uV7euE33uHfp0g7FkzHoXFeALIwg9mMdq0wsuD5BdIjJ9tQhQvc5W5rH1DufWVR7QSs
# DATA GPwADmfBCY81K5EhozyIgiG401tOwLke+F1+i8PfpOaY3N7Pm35jFcbZoW8kaUm3yHWny/Ow7K0YOcyNPNUb7R6Md/unibvhTbY0
# DATA 7dlFje/wjADIPd6Kidsd9ubIEjt13g0muVELc0yuZ9pjjZ0iajrM/UvPH/XV0lQy+QxjcUXP7KEW/XS2bWUuQaVFvRimdWS6wME9
# DATA g79ZXv8WGx9JO3pW2JvlMXfEGzdoH2PQ1mCb443VL4cv+HzG6dMcplcapVcfpM9+jJbqZxJtBuTzawtnQaox6RFCcpxNiN5/kWxi
# DATA YHtiN+prGIxVJjLTpQENg53f4YQyBd0QKWLFWG5Hk5GwKZLxVSdcjrLTS5BXHPxq3Bo1xU+Nwb5xruvR24zbMd3YmfQCvSWSl7Dg
# DATA VfTiYdAOgzhn4p+wi5WjtReK6zWgztbvBuODlCtQpYNxuoyJZhRwWxKVTpAD1DhAjQPUnD6g5uiBY6U5xyr26/nY3ycxv5/W+nYw
# DATA GgejcTAaB6NxMBoHo3EwGgejcTAaB6NxMBoHo3EwGgejcTAaB6NxMBoHo3EwGgejcTAaB6NxMBoHo3EwGgejcTAaB6N5fmA0lWpQ
# DATA 6ZwURlPq1l4oGI1Zbj4uiaZSbnqVanGX8TPlqleqVt6u1Mrp7Gh3m8XaLP+kSgmoVBu/KZUrWf5JtdauNufxT7iU0sFUNje9crX8
# DATA 70qbZa9cLtKfhrdZ+rhUa3pNr9Qoe6Vaid5V8cqblY/LpXq+VKEyBDGnmi/V6ZY8faObqnRTiR6o/rvyJj1a9ioUQqX5cQle5KpX
# DATA pXsq9VS6qkFzs16cBcRIhPJkwudLpWa/VKV8wYvqReB5Mmltb3Y2/fa8tCr0DJViSOaHYtdUi7WEXVPdLFoVuCpfDubU5k47qLe7
# DATA J2DHcEU27BhuExY7plpu+LXKkeyYVrfTrafYMRSfZrtlsWMq9U0OSNgx1Els+oHFjqnVWpXqmbNjetQKjoTHwGn0aXKrobxYHBeV
# DATA ulnHHjv3yvRv85e2ud1g8yEJ8mgkjc2b4c12srd4XiyM66owZ/2ULCwPS5VeXf6kQvOURWOAMjyKmt4/Ra6RIs6kmMKEZeTV5I9x
# DATA jUqymzCubH9OyVrjUUE0KMNK9Ef9qy1Mtl55QFxIq1mhLNNZl55jz82IhQE5qI2D2jiojYPaOKiNg9o4qI2D2jiojYPaOKiNg9q8
# DATA ZFAbbRBqaZ+1jdeWjWYMv9G9Pp+6UI/l0AfO7Vo9lTKrUm1dCXXvtcUm8cZltPMP164mal44rGLJuQwoh5WmC6avaWaNOfngzg27
# DATA c8PWyRd3etidHj7q9PBCrckzOVX8OmoulOaSwM3J4meqP3EKeunQmsOb94PgAZ9wlDZ7Qq25ZGw5PbW5IOgpVe6WrJJQhmj1QeXo
# DATA PgPZOX3eWIHbhlSqnRG05zyaIwW9gzPQnHtngEPNY+lhY6WUDXu5mwhUn4H43F12fak0kgmienOqEzR25KF+3TkD3bnbcpQYPkAy
# DATA 5VSSDVzgTMqVtedu4qy1bwTo0PJkhIPJQuYl9kJNRsEpq88pD4yRjk80GVPKAMnhVp0Qc2qWMgxdwDjVg1gS9YkovEjAQ0I1c1if
# DATA e6NCoq7ZGR3ojE5QDX5vH9zCfsAS8rgFC1VkaPR6Be962DXNIQfcQ2+2LSoV1QGiMvJ26cdRgAWr3oE8yd3Lvh9LdDRRSKnVch0U
# DATA lXc0NnhzRbuaJhVYYt9TAVDroGhKfdmFb3CkTsRDJ5Me7dKQskgyQOeKPu5P3eQAJ995mwGNJywFQCN1VuInM1LdDnAcUJ3ilkmr
# DATA 3CHjztGy8S/4yWOHnHT2e2K/O4v9J2exHxcp+Qx1gHgx3yxEL+dIvhmy/LmCo0D0fODxXt4lEMlzlg967uU0zoIPmYgcnTYc0paD
# DATA OikZ0tqkoKdNt3GsylQHmfixcIoSnipnChK7GqQU1e5GEBtfH8nDoAFgC52GNm57vUk/HEQTmiIam2hAlTyCiM0w6PUg7Y4xdFcp
# DATA rpP9NSh477ZEbp8ME2y6hpbSLpmkCnPAPBv9djsab8FA47s4MToWN2EXURAUO6q8VGsss4tNPj4/EvA2hIMYWup+zBLq0kK0xnMf
# DATA EtajZe9nN7SXevdb0oJiMi9jXooueDeieKztPxEXYvaPjvVlZJC0L7CXoHxD/TVsAwjbUzdCVZ1lQ7Ix+amLxFg9g7PVnK1mjwzO
# DATA 2fryOlsXMyefpYTjDV6s1PVZCbDx0WsLSglpPYYj7EG7TdpP4rzJsRuBAZPsRNOOw4J3KxEDxCkcUWkzaB8uQ3Ya+JZ+IPs02XfQ
# DATA DdteTNP9tvGstHgrWaIZKJqLK2pAcorF8ZE0flnrQ0wG/mikeUJ8uATvgddnjpGozjjO0i7VOjcqKX9SfjLlydI/JkBEc4VzHNiR
# DATA gMORp5X7Ker1rBTMJUCaxXOuJvL5VdkSoF5u3WE6SvupVyPuMBP3HVafMWL2enppNIQ/NFLWXPZ2shu4VUX7i+/ZYbOHkVn8afGd
# DATA LbbTWCN7JFaKvvOipCrJBxmPtbdQVqBtPx+GhiWuwqU2o+X59Ecd44TnBX9xx6sctHIgA5LincGm9ctSOleh0YRzYtskIBtjycsh
# DATA G2xXIeIYjiBkinqfmK2w1/JKkzMnEqN5zMy0BikNY/2oE7Affwx7FoaftuAEpWQ7E+GANFKdAQsNaSN77P0tDbgF27+6oi/VM9vk
# DATA 2NJIJ8VkjZYwA+AVy93ciOgZy+matWWPVTxJ5TtmCd1ZXEK6Gksh3RmyDzZdQtSMuSMRjzuwL9DK3CX7R9ygvid1XVn9FjvQrIHg
# DATA eVkFEanVCOqjmHKgdLGDUVkpT182dgqe/4K5tWrB3PJHPRaV9Xt9XTB3oi7DWAc0qrFm6j4meTSC7qTnZgVvey8KMTOmvDdu/Zzt
# DATA +uZSGVL/gslZR80SMT186vKwI35u5ZH0vccsj79eXB66F5fy+GsyWGY6skm7PemxmiwWAdVJQtU49GRVsfSol+KVBJzHpiGj4L1N
# DATA resgR0VIZkgU9kTluM+9WNTvi/wzGRd9YYnRTyFy0KwXP31BJSl6/ovp9qrFdHvSamX7s9dZxFr1ZsHgo+gg6cG0GFfBez+k6W5n
# DATA Qh39jixFGflkvSqUWHhgalNetf2J0PGeuizsaD//ndibq3Zir4ejDu8YGMABRI1jYDWeXVG83p30w04eC4UsMa7Kg0edmA17SAuN
# DATA YZm/72sudbLOb/P2UMKmt6OQyHhS2yaghQz30FOX02yCTlRaaftPtjHa9p+5Inl/5WakNxxqDW4x+cXi5qV/hlr6NGNBduhSVgun
# DATA Z8NEe6E9XgkLLd6NghQK7f+a/uvhF9OvDv8EVhkwZvT58+nj6V+mP9DfXzEe7RuPYWdPpt8d/mkWjPZfGKP2aPodPftnj/7iAKdP
# DATA chTi9Gv6xugz+t+P08fmJTZJjW76fvoYnxRH7S+gouH98t4fp/92+EdHRXsBoNxmmwNveY3G+xq7asjcEC8W8mqOZ0a8zSqAiadZ
# DATA AICGwp3AMjLUAQicAR3oEHQDRXSlejwa854xPNeVJSzjFICnYyk5DcryaApi5zt8mu3r4y7ivOlp2QI5O4QajRZ+L9pJEF+8w5Bf
# DATA nuVwX+yGSTf9Zji28B2nx1CDKa3ObaCGRjKCczY4fNrRpXXq/LQbggH3WmRcYEcXzft3adwx08ucNrLiCIehkJEwZJFMdHdqTyvm
# DATA N4o0/hAqKUHSObHOV45sKlmOHAXsWWTCrD4m0KciErwGBqvxDFtteb1cbMRkWtmzAqwtj74DrLnx/5THfw1hO8Gw/1Is753PkH/q
# DATA I/5KA/4xxvuzH+6lIqaTbkb556v5nAW3LZ1wHiQ5Qwx0zKS6dYCQcnKGcTSRV0lcxwJ0ivs+Fr7M0psn/VIriOHSCkZYmuRE00Cd
# DATA HFtQ0euEXcN2o2QfeIpksiKzbaTMNd5WgyMrZFCwXyJoP8DYpNBkXMeEe8WnhnknkNDmwpj3UMVjoXHx0mwQj8VUQL4klsNlRTED
# DATA PWs8oRD6/mDSxeeRbSQozyv8BGzTjA7y0cAh2xyyzSHbzhDZtsLostJEZxWT+Bzt+pOY9U9r1TtwmwO3OXCbA7c5cJsDtzlwmwO3
# DATA OXCbA7c5cJsDtzlwmwO3OXCbA7c5cJsDtzlwmwO3OXCbA7c5cJsDtzlwmwO3OXCbA7c9N+C2Uq3SrhRPCm6rdetB9wUCt6XXnI9L
# DATA byNb1atUmx/Xa/lK3WtW8qVKuUf/lMtes+aVivRLxSuV6VM9X6706ptere5tFr1y4+NKla56lZpXLb9dKm1+nG/mKw2vXMrXMlka
# DATA bHbLnVYGelZqVOuV6jzo2eZsyZWLXrVY2601ynuV+tv0Nf0CE1aawlamFJTrNa9Rypea/Xy14VWbXqOYLzXoS9Wr1r16k76sHLFS
# DATA ZSZmtRIgcY2P8xUq1Dzyon6DAkBsexW6kKLF8U7O9MuCbqO+AHOnKnA7HPEJu4dS6csJ+q3UYJAcqxrU0y3ABEsBwLDx5OkistaT
# DATA h5vNdLXvdvm77n9ZDpXFXytNqjcUxjGxcdyMNDZOWqSFjQtqzWqtlsbG0U3Vcj2FjcuA5AQbt9nZTLBx1Xa9Vmsk2LhOu93qJti4
# DATA zU5lsxicOTYO7e9obFxFGwViEuhnFvDjkMyMf7H2S69Kfyr0p177pR1Ehhf3Tp+mEuMctgIjvt5NVuygr3bM7WlSrVi8nHXmibsn
# DATA 19zbz/Eq2YIVMRUNwKuGn6y6VFCoWnnhVUbpYDy9nyJlkJj5EnZVaxef9nKmmXYqk8r0p1TTJj/7isIxWVjtFMhO+7CpXy7P4OeK
# DATA i/lyJvdzdg4sMUWOSCBbCY4j5zhyjiPnOHKOI+c4co4j5zhyjiPnOHKOI+c4ci8ZR05ZHOkOIBxQ+Fuw9z5ckzZHCb8g36EIw9nA
# DATA JuaHa3f9EVRo+RFPbkbzusAXqFq8ic1066WNC5Qb7X7hQ/pvsG2dEr/2XvoYHj98wx/vFniGvs7h/KpUqCGE5HjfnEPjifItpLhM
# DATA t69Rc8mxFXeI2h2iXuUQtX20yZ2ldmepl+glP9sz1nI0OKfP+s45aX3bnAuUOpJLK6uZQ71yYFUJsvBZYtjR+0qHWU7yBqyynxye
# DATA HPoHmEzL4UlorQysk5MrayC/KarHLWFEdUCgwqt906GjI3C6x6voHrf9eOIr2TR8WnwnulTKWtz6vnxcfC91sJ0o4ox+Vz6+CArI
# DATA SV4cUwTx6mIRRJ2rIoJIRtnooAMdIn+w58eJAiJOTlLzgoJ4O2K3yWQ4xLlnbDTAYTRvJLKQMfAccpidvWDU1IKCR606xNHhjI4O
# DATA j4ed0UHOC/z4gBvK0+seZtJwbhKVVv07PcVQU5OVTjVsh9EEZmRSNu1JvEs1N2CRXJxBlyPUvshVs5mTGBGwKmGXCIYBBbUL7h26
# DATA iESZWuk58PHwCeoH/KUtzTx5KnXqJAEvQMG8v3LB3Kaqnodb5QAa4JZyKB9szlGJDANuPdxsdANhkAwKjvojNBytG4pzhFCsgmJ4
# DATA MGTbEBluqWmI4ADWtmR8C3u70YSlR59e3zWVlHMrpRN3btdX7dxuhNg5Aw2PychSRqYJCs35sCtwHA110+mGoz7ESSdDTxVMNGIJ
# DATA Nv5V1Ev2KVGjqCXd3SjAV9YNmwx2yaiCuoEt4/E0RZKK+bmViDVIHrNI7i4uEjPcSpncHflhT/RSfDJrTKHQ9zGME9hvkeRwh6Y9
# DATA MPJQNQ0Nc+Sr5qA0qwET1koziZJEIvYmIiy9A1F7e+qCSUf/+W8rd1ZtK+/LnJQmqOGQqrApGNRuWM40dZctQjCseRjn6ShUPYYx
# DATA j/eY5oNHi425CpkVi2a4Egkfs6g1Shee06cuikyMX16t45+CnIh+3Hm3nHdrFe+WXcWcd8t5t1b2Yi10gp2Nd4uFtwwAz/d2okhE
# DATA 8bRv67nVr13m+8KRBs/2gM04tYRuig0jah+yvpbyNqnlGUYzDbD/nieqaqF0vd3fUG4v3TBlUopSlFDN86YrS64Y10+Zd9eO0HOj
# DATA F+uHbCCVeVt13+ctr3ojbzDkrdeF0mIHGa8goZZHqlyHRrUs7SdTN5qY6QdnXFMlReiF3dO55JW8dn+xH6tUqLEDgQILgxHdXail
# DATA 7p/xZSkLyzgKZdMNBXFNyxdmelnLTEL5URT4cJFOley+sk2X5JI08VDMsyGNh2PZkH5RgnhKA0iMFAxGVnuz1SzvjsT9KsRY9AMz
# DATA KtE91mscaC9tTmYMbMOxV8Tf8UPZdYUt8YKRotlDwTOQu6SeFjwutBwPfhaQhcUrkyChVxlr6xivgzU1DAeCsUKYZBEbCUIsKLKC
# DATA Gg6NQdKxdSDNU4T5fChQ2quI8WQH/FreKZCsYapp60BLULJeZSI7OWEL9cAz2wX0nrgh2zAaL4us/skbnslQ40xPZ3quYno6W/On
# DATA a2sutA6fQ7VqPtFhThfMmmE9ywx9C2YnxwoU8lEgy4SxtkKTh1h2iTvf50/d+vmXfOW/5ZzOlVepB802LH0sEOGaI1xNOeFnnVmU
# DATA C36Pv2VFuLPH9aSZtiNMFuRdB4O2mN9G/+rKuzOn/XgHHxXijLi59RR/4bSsICyeHFvR9lgGDr7vH/D0BXrOxjC7ykt2MjkamEVB
# DATA +BN3KKThgSwvytwJNMKhv8dzl4J3m5ezxtqCUvco+wy1Ei5jccaxwZNd6/KxHk5WmqZ1rFQJspXp2sNhD6HG4UNsXZdlSKne5w73
# DATA OHfjKcGUUYXaC3o7E+oubFjZvxx+cfg7xpKBIPaEP38HdBljw/4Mohh+OfxillL2v5kfP59+O30CFNm/8YU/H34x/Q6Xct706+kj
# DATA RpH9Dt9xA7/u8A/0ByCyr+h1AJk9oZ8fMcrsWwrgB/x2+BkF8y1gZYefeRTGI7rwB1wEGs2xy14I6xBp46kX/CEsV65r7yUQSf3R
# DATA A6zy+YMgB7cHzUpHPHcc+jL9wSBDM1QcleY1JOhleJMBB8ba5JOwx2xUatE+7+akiaU/FkhqgK361JktpZYJTDqQgdJBy2xb0eow
# DATA zhtdlimVsyOXdUI5hxmbO99QV7iiztDLMO6ZO6nSSU0cnTK8jOf5YcwbENAceGeYjqojmK1WaqdOMdOdTTfk5/yeOJXi9m7Qmcg2
# DATA kZ6w4yH5wSBn7sU8Vnv1SrV8PxzA1vZ7VLmxj+Sy9vQyOkOssFFAAQtIIRygCxYzUFlG0iZ7Bt+8atVcbOKkm9qzwpctjbyjlzkL
# DATA 4NQsAM0tO/7A/1I4iM5z0D/tMX+lIf+YI/6ZD/hSH1OJt+llz0XzOQtuWSrFXiBz9Fg8Ukzh9qJuet8eZ8N4l2K5w+smaHQh9mka
# DATA y4gRR31/yAmX16KPknMDVDtBXcJSi0YmyX5NHnGl3ntGnC1eEVvGOacqhUfZMcHrZMAHEETcZfvaMKAiiBFLr4MDP3j5g0G0L6cj
# DATA OmpzKbBRw4CLejeajMD+YgZV2Ap7yCpYdwxaofGIcVMwFkQDgfFc5gyBAjkNovnwKccxcxwzxzE7Q47ZiiPNSlOeFezj8zPxT2Lh
# DATA P6WB70BmDmTmQGYOZOZAZg5k5kBmDmTmQGYOZOZAZg5k5kBmDmTmQGYOZOZAZg5k5kBmDmTmQGYOZOZAZg5k5kBmDmTmQGYOZPbc
# DATA gMzKzWqtUT4pyKzb9bvFFwhkllpxPi7HrE55Uqzu1uvNvcpm9e16FkFWDurt7mxOFkuUldXdWrPBnyuAjKnPVcpY/txseiXK4Uq1
# DATA 2C81i3n6V30u6c8ZqBflfKdbngf1KjdnolCuURSK5Y9LjaJXKgHB5pVLxXEJbuPmUfiwRs1vtOe+qVafwaGVGjVwybxKOb9Z9Ur1
# DATA KiBopRplXKnC5Lfq5hGva1fqrfm0Mguilsd0wIdAv9Rob3MOyIzikoDMKFIGZCY4tqQFVCvdRnnl/K3PeVW52EheVSmVzvBVFSGy
# DATA yavK9cYZvqpWtlPVLJ7hq+qMotOpqpxyBh4LKsddmobKSe9oQeWq5Xql2UlD5bIIublQuaAUNDq1BCpX69SDZsVA5dr1dtC2oHIV
# DATA em+zfuZQOdldmJdlBj3MVXgG4enVKWO7NMX8s5/JQuHeCqgzD/3cLP2tOo/+Bv9nY28/Vxf/pwq5768GeSs0lrk19fQsCTS7QGKb
# DATA 97p8ZjybqmRS4bC4xQLX1y9aTerAOmmn1/HsMI/dtViqWgyGs7JqiT03E+f0tOgMrUPHmHOMOceYc4w5x5hzjDnHmHOMOceYc4w5
# DATA x5hzjLmXjDGHuhCOaYY/8qHFThXsssHObV35xMxJhvEW1xPppfj8Mq7es1q+NPytK6bZh931n/GjquFufKK4dFq5CGKocuaLEUdD
# DATA 7qrFuLz8qby6M5G15y07oF8J7g6XEgQec+lkSce+N1/a+FWpdqFUQ3R0aFckgNaE5osoVBMzlptlBdpBEHRi8O70M4DkiQxBbLSX
# DATA usG+dCBDOZUnYl90iU8wppKDjMYpxi1t1o/wYskqWXxa5wndRkEWH9bX/dxeLqRC8C8oQ3tv41frITWN4mv14qXSRq6ITV/c6rH+
# DATA tNXfurLev7JVqlaLr324dpOqJB+x5FCRQcrw4Xzq9iKas/Yv1osbvyxXN2gG1mE9q/Vy7sO1Iu7mx/Qz/V/SjbM3XU5qjmQ5asB6
# DATA zLFWVQfOoy2O3zpSz6jB//HZPyNj48u4cmFrXmGuh6+mC/G1Uu1SUecmh3r5043CR1E4oGcZXCiRVh8vzHllNxyE8a4SRS3VdGHi
# DATA tKw4XASA+N4AKhOCA8DzDD1cz1SYvK4VG3a1oMbD9chkywZF8jIXOJVEXs8q6PnXlpmM3PLQeJJwPsE4SMaQOnSslTO0uIUOWbMV
# DATA daUz8y4KXJ+HLowfop+x4ihh39Fh6odowEVYBtOoD6I5pQinFLFcKcI6puj0IpxexLH1IhbqlJ6JjsStyThpALxrS2t6yshuRCWe
# DATA Rxmj89CxF2NFZNxHYsVklOtxKdGt1/ebzstcMELvxc1LasFcCdcv0KNXAy4r0o9xspx5SEbYe12NvEcp6ZtgTJSSK4mSfrU4T0q/
# DATA YkvpN8pFW0u/VFsspW8ZNIg+R5wmJjSr4mqVltNP3Wzlmx3EjFo+x+xKpajtj8W6+lWOZ7V29J11DrM+J8wZ7X19gJHSzQcRryij
# DATA WJhBaDl0q/yiciZhQmHSwGlKl5t2fGQzIVVON5LxjIdCmYBcsS5nCuR0Xnsb4ya3ePutydWzeakcfPRooB1RN5F6c/qnBO+ZlMtC
# DATA OoL0ZAoT8OIiEa7DvydSN8pY0Za8rZxhNGY6NKGz7P5UJ89mEIQ/UrcoAV6qwqw9A8kZ1tNguAGLOWgGwSINmrTojE0Fm+V/zeeE
# DATA SQam5g8YCfUKBfu29BBkQ8CO5Bu8+OIWaQvDzUvcvOSIeUnK/nRTEzc1OXrG8Uwl7jDGo4LrSCBzeonK3ZtmIiLAA9Z8Mm2NSs+P
# DATA WeQKglOsOWZEqHKinNb3xXFphNC0WEN2cpFBL2CbjY39Fh6tbYAJX/N9EZ4LhDALVynaNyWGKnRspjTM6KLsiT+eIJo7/NskPqAx
# DATA d8BML0qgdBY5BSGS6ZEeaBlIz91F/EAHOtyNxtHOyB/yUD0MYEgred9wxNJjksT0sDf2Gat8IxqJsq4a67JwU0EkW5afpFbMEQuH
# DATA xh0Z+rZ9hUHGNkHVsYnvHqtT+0CRQx9uW/hpgpXY9W28KDzkIAyw1Bp8e8tiH3bYqlsa+azxKCkwSAGBCMeGIAwV/7EBPbdZEE7h
# DATA L7QmcaKsJyzbtPaeKpYWumzhE1i9ti/1d0matrHDfhCB3JpNlpgJaW7sjKqiqchkFt6Ce1+9GflKZtsuCL4K2SBZwD8A2IvIYy25
# DATA zbJtMGpyqEQDSQqYd/DeRpNY5YcKOKR82N6Lwg5LUrNKGwAKkqU0QEVMjO1Dam3IJ914d8r8KT3H+tdCE1EOcJmU6ThjQT0lXB11
# DATA ZRYGHbp+P+pI40bh8WVTVp4+PBd1u/Cp67LTGtZShjlvOGmRhWI9x/pz3Aj9Diwgb8R1WCorjV0ML+ZXeiCx06BDlnZMbXJZEu8A
# DATA Da7gXmMMIlYSQSiTF1LPEELbi7o7SuuQnu9Oer0DxVtRMWU3TswVVdLdT5EKWVlQ+oT93UipI1IHiZ2gVMSjXbRDKTD08VlErRim
# DATA Pz172tHCnC29shq0M51/0qbzcVlhz1gd2t7zvxwWdhcjgYZdslEl9X05Lez5UZN+ISRVjyJIJPv+NcvrNKFiaYXs02aKZRXH5yLF
# DATA lPuN1bxRqLwLjYwgqRGxmDVRz3aHBkPdiV25ydolwhWjqQrrE8ukid5Hv+OeN8PEckbvAcnsAexyoZFRvUnulZkJbFrZnR7Bwgsh
# DATA RXagbroY9RY1T7GXYeei+vLUwp/nYFyKCYEr1pCcZ/THYYGxDPFwhBodB6aZiYKzb6arss2GDPs+7iI7N+VtJZsbosW2Fjpb2jyF
# DATA lJyasCi5NnBn1tlmbL2fmpWXYM32g5YSv7apZv95+nj6r/nD309/ZMrYk+kP0z8zXYw+Hf7d4WfTRzZh7PALXJkFnP1XXJ5+RQ8/
# DATA ZkTZY4++PKKLT+jyDyCTTb/y+J6vmXH2D3Lf4ZcKZPYIJDV6wRf075cKZMbxeYQ4Hf49GGjMO/vz9Ef6ge7/xrHNXhRbVho5Gp4W
# DATA X+clK0PexDoQzeFEXZwnbxEFN0arRxyplb8HlUVmyIv3KNpjL48/SrxKFgkRzWMpyuztbDQczsy2aZOO4rxpZnMK5uyIZuJTiWde
# DATA rq5nb5cdBObu20FMI1BbBmwupFNGm4l7SfT84VqRhT+mFjiw2UqFd+pcs23P0jtPZgamBvCiMYR0Jj2mcLQO8DdOUyj3HKgnEkGx
# DATA c67eeo/uF03znOZU6P0uBmLC9s8e4MUeXezN8MxWrJmLbZzZZves6GYrJsVxzpw1cFJrQGPNTmYEvBROrXM0AM5i/F9p+D/e6H+O
# DATA g7/Uz5mcsFBnz6QFnQXZbCaRTDejrIpnowXGmSwre1Q9UVMvCegp57199+6tOzl1sFStDHPJ8J7REdkPvLLDycAIDadEQlMaqbLU
# DATA ngedp3rMXRVvZqqCR3kNZbC0AYCUhW1gzhIjIA04G46CDnwjaaPANgZy3EzRWXgwMAZtZR6wVQAOlZiHgpzi+Mf0moRuxk6V+CDm
# DATA o5Tqnpbjmzm+meObnSnfbLWxZqWJz7EM5PO1+E9i8J+ave+wZw575rBnDnvmsGcOe+awZw575rBnDnvmsGcOe+awZw575rBnDnvm
# DATA sGcOe+awZw575rBnDnvmsGcOe+awZw575rBnDnv2/GDPNqub9fpJsWeVbqPbeoGwZzPrzyuhzzhzVeYxJUxoW9Vy6rBYqV5O53pF
# DATA WE6S7c1UxnWaQS3oZvBNlWatJqiuLL6pKllsxUPeLfEQ9lUSj0r20Fo5iUY1i62bxwurW7yw0mbTMKhShLRfVDvNUqMyW3OaVao6
# DATA zV2pc1by/Hprs+3P5actS15ZSGlnlLyyRfNaOXn00KklryKMrzNKXkU9fazk0UNPlbxKufxcNJJKpXl2jaRSLz1FI6k0i0/dSOzk
# DATA nXojSSXv2I0EyXvaRmIn79QbSSp5x24kSN7TNpJaqflcNJJapXp2jYRi8RSNpNaoP3UjsZN36o0klbxjNxIk72kbiZ28U28kqeQd
# DATA u5EgeSdrJDawtdj0qrXaXrW+W9ms7uWr9X6+tFn3qvW9ylEA1cWN4CQ0TLZ0DQ2TjWaLhllp1cvN2klomMXA75YsGmalHjSrhobZ
# DATA arc7nbZFwyzV5OezpWGqzbwyu7OcPWrZzfAxecJOJrrtVNvkNfY52yZSoWL+OntPdqvC7JJZk5fMCk1slZFFs1SoasF8ach1Xj1L
# DATA P6ZngfM3GyZ302xyZ+T3U2t0RyVXPTNneX72Br1SP5Pns3cnXsRFOyTlRSUpInEFzASCpYZZ1Keqdunlgs3NTXhgjgfvZI/RnFSx
# DATA 23DG9zy7XWgh99PROh2t09E6Ha3T0TodrdPROh2t09E6Ha3T0TodrdPROk+B1jmL5twJWwqgiNU5mJ4KjqkZVHTlYqlYbdYa9cup
# DATA OYt6jA8P4zGNOCTDfDLElQslPFmuXlZszGvqGDv0Awbj3d6B4VwxIpFiQvXqTezvXy8zFvGt8HVBKl7HOXM5pTzsTWIPgs2eehE/
# DATA q6K06Pltr1z7pXlbIrQj81LKg72AUZ3rFIdfYY1/Y15INsvQOmfqBGGcIExKEGb20LFTh3HqMCdXh1mopHyWqjG6s4YchLQXFBcr
# DATA OWCjDe+8sSRknh8ds/MAGspQyaAPGchYhYOvHgES1E+muvk4hWyDG2EuSLBkcQT5pqK+0+AEF9MEzXAOlqD6jLBZsGSIQVEnwVv/
# DATA dfj6UUBEKziTFPuaSU3t6LSUj5EMsTbQA8ArKibB+o2j46ufM5E1F6yYrpbpK8ZU20HcTiGUCMmRxG6hrmsYBkdVlySQBDyZXDJR
# DATA bxwV8/qSWC+E/JkuQE+ZeDxUhfzCQ//mkf6MhRiY3g89E9UxYXlw8+gYeR3YBlykfp/nALw8w4Iwaq7ZpkkVq0Uz1AR7I2l6k/P2
# DATA d6nykXE42gms0FTudrvU17YmI/g28BxNrkYBFJrCsRb4Uf5qmXnELMvNSkxUpQ7EQGYdTLueFbyrUZ/dYtT15ZRYz6Bj9J8S0SU1
# DATA mevIE/5I6SIltkwCme1TvCYj9q0q8aEVqIE/NaUYxzxxE4EFEwFn878UNv9xSSfPi1KkvVNiOfLkrZBHTFFL5PVoiMQNWLWH2lY/
# DATA WMo+eXbyki+WutpR6tKZPR5nAT6ZFdA8bfjJPB3SuQCUVNnpLTFSkecB/t6EPa9NhLl3sKrn0jteF9PaGBrHlPtW5D/GVYYsOAiQ
# DATA iGh8+mMpc2VuroLDvJNMuzVe8e27N67nvKt37uTUOCzthYcFpeUOiKXMi0RocQiVUF8rqbJSI5WCkf0M42TeoMF23MDDMYbtJUTF
# DATA O9IZyIa35bDIbSsSqhLrFG1DCXSg5FE5dpwgSlgnAM0vGLShCDoIKH5KjzVHtZeq665eZhN51rQq61I0Z7oDOSLqWnBWrGkdbQVT
# DATA ZINbHTAMxJ8hMFKY/aJ9zwb06EBJYqpYFrxbmlODmPPqmO7IfK/rh73JaBnN8rYEg4WrRTzLl8gCt/trZ4M7G3yuDa4qifPEO098
# DATA yrpbaLw/P/rtXKcxUic4Z98TT6HxwIuvJoyxcS/iQTItPq5d6Fn62WQInGDB+w32iB8YRAvd0Zm0ISLTx1hspI2Nv52JxmzvrCzk
# DATA nugWSPPE1yuvasPvDo55c8OGfkWsANgy41B9wasXjZU4lt57PMJHEebGq9rirCd7YxTRGEwNe3fuDe/JmN4FtXnBLe/DZEMqRYub
# DATA xaZx60W886J+vwxG2WgoQ1UZcMbi4Td1rryhNidyDc55GFa61PdHVGaM/aSqNu7wnWqMyHkyGOe01DY4d8AUx7sSbkdFa0E8bvgD
# DATA qlMd2xY0kdlOJPAzv0sUbNPN2F9UoqMA4t28eKAtr6Mj8ptwNJ5AUZ2lxK04qAJmM49rK0vKc58yinomMu8OWVHF3ECVPBizSvqQ
# DATA B0/KoF5PV/XYis9FVVAXVaVbwKVfjv2+o+28JO/F5PM7fRr09SwnYftoJXFFao93o0mvw+1SzNkBLD9sPMfUStTVpYALHtuXZAH3
# DATA ooM+B0H2OXjWPsThLRl6sOg/ilo8cCqJ+cmAWYgqpGVA8EG0r/TKtensj3d19N8fsZw91XuPxU3E2c3rLdpvzE5nssYpGF97m9FL
# DATA UWfH9+AHZqQmNi6QUIAs6tt5YgRS/QAOdhrOg4G+t6NYj8na4LLE3BBXtEqPL+L58Ksb977yrCNiej0j4SrsBr2h6s9kwdPqi1gG
# DATA nwbKKAVVGAb+A5Sw9Jioe1iz7AR9vMCeYSmwAoUi80HGwqMV2FMzZcfY4HOz/on6GfZXZIj/tGz7Tz+99+mHg7VX/uqn/h9lfdC7
# DATA jw4jHEwAVR0enPo7sHZZr1b/Sq0bZ/4tFWu18l8Vk//+qlgqNYr1v/KK55EBE7Q5ev1fvZz//fznP789EUJEmzqQsMPjDCrFWsx7
# DATA kfOM/UgqiHf1+jvUa/AyJ7XvqNfhJXx6oEBhvSJSKWTb7vBhG/39I7IP9ecofoVHL3T6vbDlqcu36Ku+ZWQejCct5Z/RV3AkC8OB
# DATA /j4h0+WVV96/vX3r1rXb2EC9trb2Cp+xeUVtsOzKvmp2Nq3TZLITXOrGaxu8mxEnQ9bA4LtIveJFUH0vtnshzWDWLr8iW627cQH5
# DATA ADffnYNBex0P5bw1mq8316wdqGvsFMoj9HySW2sbG9q/VAgehuP10sblV7L7PtNR43Nk99VD9AbqHfcH/OYkoKCN3Mp5H6jIzH/3
# DATA vdwrnud9MpZTJJdKvN0h1/cfvj7pYu9jqV5pVnMPyMq8E+4M/N6ltTvvvPXrd65fX8vF404YXfpgja7T8LCWWxuGQ/yjvt/7dENl
# DATA j9qYGoxGNPT89rd6o2rMAdoXeLFcNr4uzhLZQ7yVOq2ln+9gLBhH6liFyn8dDX7wNS6oA34JDkbh9T+Tw0OFML7jd4N3yC7awSEF
# DATA 3F5Afl3FSvYG7sxc8171ivMuX+HTNnPToK+ouO7DkFlX8c2+ke5PTm1lg/I+fQWV+JVXaAoNN+V9phuth4N4SKPwfSl0nvxvXEIR
# DATA Iwt4BR2XYAPwhwJbEzGmUOtr+bUN/NALBuvyICWkVirjGp4cBQXsJ+BtxOujtQ+28//Bz/9tMb95v3Dx0v+Uv3dhLf1C/DfyMZX7
# DATA DRJ2DcW/vvbOYA+nfayehJ9Z2+Bn1EC8xS09lZgNnQi5hSvLOtX88X2c1KWYVr1fedjQq/5ZHgcO1wsetsnWjWUiqWIAe3PUQW+A
# DATA /qjAux/W1TtRde5jf/X6xkYqT2OK6dgftFEV+fGch9MDJjvV1Q2qdl5ppdxRU12FMQ1GKnb6+paO5wfFe/KDvhF7vuUmPpS49k6H
# DATA imVNPR4M9sJRNOirveH2fTSd64Y7dO8nn27IlWuDPTkSZCc1Wwn8fJdqwL1P6tVP6WYTiw1daayssV6eyR7rlw3VeJ4mk3AaWg64
# DATA 8FdM1qXTCAd2DiSvmC1Gvj+Ho7ccyTWy8/C0BMMXRtkLD4vFzKWtNbVnRa4l75ufrPcG8WSI4YpmF1Y0VaLwH5/2vE8pk56Cdwyu
# DATA 02tyXmkjm5j5rfX+PavZ3vsVPYlTq0fFTGe4XX3oOStmnOUFGh6DQUcdQDXtddJfRyHjlgJNNqh743N+KHusQ1D28NMo+XKtvkLz
# DATA vWZFY14T/gXWluDY8PqK4/VG1H6A0zX4hyofPTg64OlTTubLba6POMmAgkOnLDA9Mv0LKkjswKK+V9HyYMtgTsv0PrVIdFnoZ3BJ
# DATA 6Zk/fNAsGYrpYrzrY/+VNFfT+21RZAcBXxRHljJdCncD2C7+6OANFhaMRgcsbBc+3FqjFw/89gQHys1Ijs6bpqodfXOSgVRq95UV
# DATA w72quWXDu+it2TXNPKJ95hG6kygugBC2rsPJ4cq799+//e7N63/j/Va+Xb19bfuu/nLt31+9nvOKEZAeJkxOHf3c7XBoySuoe9qX
# DATA yFNzC/x+ujbKNTVQoh0WPqKCW1dV5gI3zeQlYzvhnNGKp7ZlWYkFKrD1D1K34b+1DtcSdJfyFD7lxb2LjybXC0mub+GwF6zLAv6q
# DATA 0oC0GzzMzQadz6sqwaHr/uoSnjbf+G3GnJaX0zQ73xlFw61tWFzzwo31Eg3Zp1uDiN6zn8fMNwRIJpZQqOTyKLk17tFMQW7MDRCx
# DATA pCqCJ7XNq0PRrQbfYaboAR8/44sysNPB3svBWTCejIL7soVy6+5oog5e649ifW5VijlZN+XrG+mCtFqMKlRtRMFPNVxP377acKXD
# DATA zPSAC1voat0kW2JeyD6xsd1Lin2hLPpsfbSqHxtlkun+eOy3d+243psttXn/rZrnpaWZrk7mpQ3s1fP7w84npVxNLAO2oWF3Dsbr
# DATA 6puyky8dI2+tSaZEaiZ7WQ4geYn5tYstH71M90DRNhk7G40lRTTqS/nQMNYO0sXjSTZtWU+/ce03N9+7fv3IkqMnaZY078mkvGq6
# DATA uN6EgMOGmgFgJFpX1ZgnRei59Qy7sD3aYa/+Lf5FFZ3chrN89331O80B8sropjTpvRdWxVj0DJvwc5+g22CLqQf5Hzwaq0ikOmw+
# DATA t7GeTGZwX0HFJ+fJN55gKGv2ITCc3jX+B0KsJqBfqBH/4huvezztjBkNqrpa22Fd8N7FoO17jO7xsHtpAC9l26PxyR+SUZMxRO6w
# DATA c/8aZmFrNyPs405qZNv40Ft8vRuO+kFnDWVEFe3+fZgD98l+2/LW7t9Hid2/vyaRluJ7Tl2JI5xi7wdn4fZbzf9XLtdr5az/r1gs
# DATA VZz/7zz++8XPLk7i0cVWOLhIpoM3PBjvRoPKKz//+c9ZuEN4tVh8kYUxrDFgxRfLFdEw0NBbvYHrtjajPJ5t9XrULSzxCmKZol7V
# DATA 37CnSX/e9WP4BvXXEPpgI8sJeHJ/oqwgmq+7k3HYM994DmG+xb0lXkh/ZDshs07J8e5ICHjmAjWylMeSozwZ9SjG0nPqeNM1nvxR
# DATA x8KLJ57M3ieS1zJkJqOnGhYok7ftDg4mNc15vNYBl4spDbbUsYwyCj4K1PofMkRmnTEXlgw62Au2TjOcOHH6SCc5Jzr6NvUoK/Cg
# DATA NPRzMm5bPheeq/Adlt+F54/Y27nGe6HWNnR4Mj8YssdTTd6xV2dLJiHyjjHOtIz1NIiD1pNU+akQxvfjgz62uqxbJiEnc236f04f
# DATA e9Ovp4+m/zZ9cvj54R+nX9Hnx9PvvcO/ow/fTL/zDv9++vjwM7r2tXf4+fTJ9Hu65cfpd3Q7fvh8+u3hF4f/SD/x09/h6yUPUwAY
# DATA 5RIDNbKp6MiRxUIf9vi6fImV+cZT0fuRbbTxqueWdnV0F7kzArIaJJ87k/4w1r8FAyxR3vfjdhiKaYHdYhgmt8p6niXulE6O57Us
# DATA zKTmqv0HaPlDM0EtJDNUsgoo9lupFM0Z+jExbO9Ska0jfBTdwpkjbqAZI6KcrgxYcd/HxHCLJ4UrzSiRaRvzfu72JtCMSf2EOGBD
# DATA 8bq+h9I+iLQzUN0xChgZpuWlpFht7wzdw/n3MzIDaC6VjpyZnN/vdqy5dyr71AT89hv2BPyNd25fu3r33dt/k47yzIQ4lQ77benn
# DATA 5lrL6lkGus95duYZSSwaWoHra8yZkpls0R2TATc5/lG1Z1kFVq4k48CGH0lpp8FZVFngml5/7VLi5rqX+pa/90kxVy99av2+8dqH
# DATA hY0L6sK9T8q5egUzFvvVVi/w36bfUmv/79Smf4f+4C/UwL+nFv+DN/1XbvjTf6Me4Ef68Ue6EY3/UY6u0ZXP6Nojb/oEd3xBn58Y
# DATA hzP3fOLS60G4ZF1nAg0pZu/iffT5urHCuWVlpZp8ZbyMKuAP1rC3M7508SK6GpWvJgC0bJrihxfpXWv35udzsVacyYb/dfoX9HTU
# DATA qT1CX0f9nySPUkp5wj0kpf8JfkP/9wfOjO+RX/R1+sP0B+oBHxuvNLD1cdavmVtLeZ5L3qtbylvMt2/ge/mo8kFsnqB0nuDFeP9X
# DATA iOajVaOf9OjS9R9+efg79OKm8NRs3vI1s59EfM0cUdsTN2Y1Hf53ZhpN6ZQfVCVIrc2YMsy0nlSQHzQv3bOD07l1IFNt26s6ryhP
# DATA XJDfWJNwrcqTbZIf/MeL9y5srFNjvJi0vcL9/zlPV3+1cfG1NeWWnXFkS4DYcDeA/NIOu30pdz9ZK2AKXiisfSp7dZOf+JEPyvd0
# DATA TaJc2zgi6dn0Xko1bak8fEYjn9Qdj59DYz78p+n3uaQH0K2dW/4juvkRAqLbqGeYfoU+QPUPFLjO6+8O/0Q17EdUT9Rc+v6llasi
# DATA OTivJUtaS/fQknW67SzEk+FAVdTlmXBEW+AM+Y6aFhW5x4n6Wtk2FOPDP5FRY8dYuYzUkgA0CO3eTn6d181Jso7X0x2r6ZtiXZ5c
# DATA lRT0uuKsO6In5rvxjVee6BY0Rq6YqgTwlOlgUZepWuI6L1TQbfzv1tZsD93VP6qb49lB6b9KMg6/mFNqPxx+QXnC1RjD0l+4bv1J
# DATA 2u388YtHp8up36gaU4Y9loxE0DNV9vBPntyBi6YmqOLmaM8rbZpPro+jB8EgXb6Ll5qpu/iwsPw79Qp2kFkLXmL+BXp2Stn2rXfy
# DATA SWNcoUKoFK2vbd+6df/Wu7fvblWKpeKHg9vXbtzcfn/7N9fu39q+ee36/fduX99SwBk2hvf9veBSBQoNg7VUK1xLnqTI3L/77q+v
# DATA 3eRlBU6EWN7v3Lx77fbN7ev3//r9u/fvXLt6+9pdvkXNVAt86/3d4OF6BcZ6OvwPB3dvv3fn7v1bt9/993+zVfpwcGP79n94ffvm
# DATA /evX3tq++jf3r79z89f3r93cfv36tTe2WBWWl1SktDDdzFph80qIverK14vpjBKh1QYaD95w7imrgr7Va7VKbaaI/kX6zqSzkap5
# DATA +EepYVSDKSz8KM+nCyV5gY69bN1lx9sqqVAW4QemMsFYLC+xBqlGYUCkKMNI+JYqzg8U78foc74//FIZg+qXR9orMsfwU/G1FuPW
# DATA k7X0S2lT45NPZ5e1zc3LFvO5ND64l7LPsUg9f4GaF5vbRkhu2ZJzEr0P6Kl7LDvHzy3s8vUG1PtqWWzdWgUbBsEopjnOXjAahTSF
# DATA X1tLHBii98j+Cr3GGmEPcNiWIwCsNGF2t+o+1GsF2Oorrgs2UuC43crmGranzubcTXnPDax3GYNUAsCITM+spWc8Kt7sBzNffjZ7
# DATA 78zI9TV3sjQuUc2hPuexVPl/mv4z96y4hL4WXfFf4HmgpkAGCALN67sP/zHVVaeGYy4EiQNfVfkXz+aDSvGdYIzF7nhOZsRSl1RN
# DATA VI1JBzg7LntsNP7Ads03iBysh8yg8oNKEP6h72rFHmYm2hE1eLIvaIDDQxQcRitk2OOkSObnu9qAsThuq+S8Ggq+pbj8o4wbKhIz
# DATA yZIROFsAyhTXkdhAzSnNTNQGcHCF0Mc1N1I/NjOJN5V6y7gB1+f3Gx+svbF9d/v17TvXMBqt3dso6Gft5ZP1XwcH7KLLeTMuw8z7
# DATA zDqoKnH909yBlsoK1fQ7Ljl03dwZPhYDBDYaLia2tBQoWZbUdX7tpSKe2FYqHvqjmS6biQfPIq0OEn0Jyp/7lFQzxRWzQ4pLJNMK
# DATA +LIKQq7gyExgt4bbsvGD7gtjzhA44zL7D2R1KFk+1svCWBMLFr/rJiXPar5IiziUyJrmNXikat26f/U2u1EIRXNzZimUs3dhi1mY
# DATA JF7m64Us1EO5zx910chRKVzhCOvYS8y25SE9MG1kvJb8mHgtP533MixDwhW3ns023n21tlHoyRQb8z8dn/SgpVYMJN6yNcKKHwv6
# DATA 66Cs5NB1TszaO7e2JQBMRN/qRS2/986tvbq+mIk1Jc7UYXpc55iy7s1lHaXZjFc1HKLi6uitcjICH7Cxwdmhq5ftR+YJDG4pTAZk
# DATA dK//SgckDn3sxsKQptoP+4f5drvvUiGxI2GxMyhpxfMHK+4kPxfHGM0TvmUf+ZO5wwP/IKPAZW1HfcVd7J94emf3EJ74Jx5bXjVr
# DATA QEg1e50j8wYJlQMnH6ERQcqKf4L9umh0WNC7WeOAjpbd06pon7ijTUeW7pMbTLY9xlzQGrgK3vSfZeT9iqP+B/7hG5XWr1WpfsMl
# DATA wfOXq5hhmHTdvHb3/Xdv/zpjL83LYg3WiFR61feYt0Guq9s3sMtVDMe2mND37REvY9grozjm4WrmTYnNMrs+grNTGzNPiIG+8CHe
# DATA yXrplZn9PZ98muq9jVdwjqk9u/+U75aub7YfUGX/nz2eh8v09LFZcrU3aaZcNmYWxZbUZzznfeL9+trfbP1m+/p717SfhC5k9tTw
# DATA TMCQqu1JgfgrcdqdSbiYGMzdFkQhLEnG3Jj/wGtqf2Fj60fxSnzOE3VrcqV8s+LNwcTrm7UVJiW8KVWnRrq71Aav9HwlienSDM5M
# DATA U+nj/6Kmfewtlay1youvZhJAT//eTLz13neKmb1Oqk8/JOunryzdwZzaZ60m3+lN6NZMFkYusvFr7uL+XvuIZvox6Y+Rph8l6ZSo
# DATA L+fMapNmi5Wy+/GuX67V7dR0wh2cO9zSa/kFdctGsh/WWgbmlbC1UWv+0h4aWXt3MniARsZmdM/vtzr+Jb2ix9QE64TARs5rrWX9
# DATA 6RKjgpwmXufwUulSv+8GD+WTWauRM6P3kRAaUpM9tmryHkXj2f23atWsJ1gR6fKGYreyzxbbj5ESLP/yGD3ECjUeoK8YwYbJSuKd
# DATA t7cp5+68d+NO0uvCyzhMLWqvcJZDPGgS8kYSGY7mSg4QrjTJmjivnnBF/0raqFQoaghmsJalWCT3op0OnFuQ3b6p6rNxYc3z1i5I
# DATA DC/w1vxMLHWZ7LFuwH0pmiTfczKKDLC2vSbn2I4uJt7KrQ0pM78YRftsCs7E3d60sCFuE96ybFvdC5dKqBz8fJd3qW543nqmdDaw
# DATA 0S7aX7xQopcB2IxHtOdaNAtLTndSP1o2DA8Xym18+HuMIF9Qr/W91d0yPnGLc/DivHUIXgWeVxX1D6pa09WZzgIVXK9zzE3Lf8nG
# DATA UlloEks4+pfVwkXuFSt1nI1sYOu06V5ByVPReJ/s6y7IiekCdlmo/bzjIHtRb8qOzRVl26RuNNaKqbLsdpJaa1sdEg+O4pp2gPEO
# DATA D73I2ksFwpsP4NLKtuj3Bg8GOFdvBFrVE2uZY0Aq3a9uZauYVb3Y1a4LI10CuKRLQMbyrNOEM02PdNK+ZvNxY372cMrUaXo8wnND
# DATA KymLk3+ThUnwk4qA5MNaurj1+LCmMe55UB5G66F0mCH33tBV4JMvHNAHunhZC27t3sbG/CCt5GZqyEYyX5v7JA8F2lGAGHxgH+5Q
# DATA 2YZ61g0pZiPebKuCvifnNPFW7vb1do3kmJuKkkqDilaqJMwzi2rlkmetLnEQdsUksDJilSezuQEfxweK97EmC3EMkOFJiLzkA8GD
# DATA SOrlfk5D0Fm7l+pd9QNSj1A52BV0OxLSX9aGSCebT9xyFciP1AOZurtag/q/1YCquuS/o57rz2QU01T58D8lvZi4Kqkz57kyWWc0
# DATA HYVpOtOPcx9oekgxndNTrGFqFEwvgajengfK9HEvu0v3W3HUA/nMyiD1pAn3Ii68stIgQRZ51Ntjpk98fxT0/HG4F9wfR/aJJhgC
# DATA qXt5SXX2UFTKpM8ba2WJPf9HZRAn+/3EiP8KK6ycs+zIwOo9T8anf8a4I7OWR5zfX1nLiDqxutFwZzU7HB4dYR66vqSwabbOc/zP
# DATA 0Z0ujnDaTE/n1SuqBgyCyXjkQ/JBaoL2SJBda1RfoPeD/E/WZqD7tzPAYVwhHvX8g2AUe2Cuen53DMXxaMCoV94WelnJqshxcdFF
# DATA MS8yKzXzNtgk/ZseMfVzhQO/37OH0uQHuS4HOPILn1v4O/18b7YSJxo4Fz3jV882hIVFPGer6Vz/qnpbul1aBZFMA62axb5ELqEj
# DATA Qp/ZIahKnw9t/P/svftyW9l1J5y/+RSnu+0cgA2AF6nVMmS4Q1Hsbo4lkkNS7jgUggIJUIQbBGAcQBLDxlTb/jLJlF1OJZX6aipV
# DATA yYzfQO50xx1f2q8gvcL3JN9el7332pdzAFJqJ5mJM9Miztln3/fa6/pbqqNeoLWiT7fdSGscl5VH4cBdphrnKK0nlzOrCdE2h92D
# DATA IpOD2wt0RvVnll/ncrbPkaP9Ek8ncLXGIV3r/JDbgGPyl+wo8ltQM3xmjDxsoPgsh96SpY3E989R50ZqS6TFXziKCNcTxi5WzC7K
# DATA 8EL65AVyJHNlcRFFXJ5UrujmXHIkB77fYlc4djJ5K2H8WUJQYkig3qCKzq5mehmFS8nzTwjuaNjvGHwl3E5L/p06z+c6KqQAU49q
# DATA h/8HFMovf6w7UA1kS4qT1/yEbpU9pu355RnFQnryIuzmUWrmHOxplnLyqKg1pxTwmsAb2sZcrwiLD2D4EfSPuHFj8dlwrp38udCq
# DATA BkFLNU/k9cA2bZzmc8kPcU7wWLJNVknoKNdCTqu+QByh3saG3UZ/EwSccNi8fGXpHEeN3CkzXsoaM9qcLbdlfxC6fJSbkS/jYq8u
# DATA gZIKtURv/Pm6ihAcDnIBydddS9Nz1G5gpiR1NyDidrekYzJEyGXfogKwCcmoj/XageofxCFpbbrEG+yUmblK0gLYA63emeGkQLEc
# DATA ndTfqxH/Ek0fZDR6rt1Uk5B9+izURunUne7mNYd7ASEA4zPJSqu3C4Ta50oC8nTYb6Nbx30d3zy2DM6UPtphl6PKlD07fCEG6w5T
# DATA WKMO7cFPugSJTYDX03OpE5IziaRVdM01xuuC80jn4j1mnx+AImyrmTtTrKatR3Zy3Dtvow91PoMlusfFPQlRV8KWxOL9e41ZBxTC
# DATA 9iCZsnJGX7dIdF0vAU3QZZ8py46/3G44FB1GeiYHlx8gBdvODVTif6zs9YbDI8d1z49EsJA4ISZU/wb637kNkW7atq+14Du797Za
# DATA B4cbh1smHmZ76wBPLBNRBPKBG5Y7Y8eFSvY84jpneSjDkpu0N7Va4oDyaXMo7gfHPm1sVL75UoSFcbjMeS8DWGk3CIxUfVncwMjf
# DATA G4HEoxscqwQT6dljuFcavsUE30k7SDh1pNaPDr6BM/DHyerw3XfftRKxmWUZyr3fJbwHxvjtPukNp1my/WDjg61KMs0ohQH4Az7t
# DATA isTOgwnr/tRhGQFupaiRMOmSH06Hk3byA7Ul4GLHhXyKEdzjrpraaRfjxHuILwR5tjosxWJYxnRkA8M59pBIQMU7eehO2HTPqJbP
# DATA 3JJSO+hOJkrSi0uA+iLFr9Rics/yFgjLVQKZzfjQ9tuDFkFAgl65xdx8iYZWoVmG6PyTsx4mbBeunIwOwgSh04AtrRUH/EOoKFtU
# DATA Jb6QagWSHmxWCO1BZeJU1TGEXSBIzdMeIKrhmj5tjztWnwC233yVMKnVMdiEh1NULmA8/g5dMKTC5zdkHaVIsefayJsgl/aFEj5/
# DATA Qp4xnpYI/USsevznOT6FnsWXJ1tjVjlgbzFMN0WHKS0zEOHsEwCw+uTRNyIgbtJ73nEuIdUi9OvLF78iKzYooRRHjYakn0SmggUW
# DATA ELwxgiQ2tCdwLIYDzMxuloof5o6e37vjj3mpv116r/6oRn+WL9cqFOxHXy8yaO3+Sc5IP0LzRXyoZGYKx6f3VssO1N1uwViDL9jf
# DATA 0L0iwknxv7vm7PjVlBc1KJKZR86U6/Qb4b4ZZQSd1siAzx4ziaK5itstgUeDkuNHJYTvctzSa+pKgjioo9VmspzcLB/Vb3psGlQc
# DATA zAqcCXpTOL5fsFcEiNnPcQvzcnO8kRkZ6I0+J20SDxx8P4oskHdIbw+U4l8MxVBb6i/pMDleyJ+zYv9Lij8nja/eWRa1OXOPj3zD
# DATA hdUV2PI+cLdh5BudD8cvys835BeVoAVrTfL3qSgkfFYwS4DsIVMyp05GEVLvXNfOwYXfCjtLFpwAGxTs2twBKM/6QxhXTacbXvto
# DATA +FNT4xQykqv/qX9w/Zmzk3KFQcq+BkvhV+XjWNKCisVYvC3+1rgdwTToZ2YGRKFwSMIPOdilsZau4JfieDdQrPZ/Rx3ijyg206NP
# DATA gQHnCxNP6FMuyoIA/cVUGs7xgycHxF4BqLB7eJyXZPtmToyc1hRPRAUNg4be3VaT2hvo2fJPi3xnKlXPTS9zZjmYz39S80NTYLxf
# DATA f4OBhb8MIjm+QpL0E/zvj198xjzOVedyNEKviiNKS8K+6Y2G7Tk67gU2b94RTiQ77D+q0G4//m02tthxubuNvwnm5n+rIf0Sgyuf
# DATA v/z5y//BxFvPjw5piGrdfk9xLaoC5hrAdfrHuGN/omr6ImSjfm1iXhiVpZETNcYu9nt7HDAoYGCZUbixrvXPVBWqnW+ufuuWnpWT
# DATA M9o32A7515Hd7RFioD1CrxUEPm2Gs/J3zohzNkVUm/0l3nzojIgPxBjy9PbsYlGgnDe671whir0jnbi6qOtGMwpLQMpI1NyvS8rH
# DATA LmlzdJb/KKJ0fRZbz8vveJ99GugxA9KlVZlGt6Ux/Hns9NwZPnasEkhHWXcLnHz3EPexXDbWf+TPgBUDp+kaIBV93L3ISkfLXA83
# DATA 0ZSf1LrPJqAKXsy+rH35pPrds14YQRpqrwfuZgsb1xe4OELVcTzQzvRU670vyTSCbqhk/QOPMFLm1yO+bkHnjYeyJvmQlB0nwrE/
# DATA pzVFB1I7NzqpEoXd+EI27FD6qxy7W4yrketfa88FlaZPNZ4ooUW7s6r9lYlPx+KktCzwwKcRW7f7hWCar2L5wQU1sLi5Nl7Eaoku
# DATA coELjOksrpK0+koHF+sZQ4N1VtJqc6SnVnznu6ePGi1/vSfBngDFQ0FQi/UBz5svx+Ps6zoXin6wKyagxNU63e4I/mBFlfAUtAwV
# DATA 3OxpRVN5jhYH7fAbjeBhnitOjn/A32gn+d+hWQ0ud0SmSCBWSs3ZP4MzDoaL2hDxlz/RV7vESBDMYMQJJs616cPf0LNyZA94E8du
# DATA QSviR4uLB0ExbgCKZFV+a8wSebe9w27n7ZXu6WkXFYSq8yWtOZxHrhYZkam4aEz5+h748a96PMjnGR/W3NW3ssXzvOEivDSsreke
# DATA DZCeO3HWYQgSFQpikJx6YaylSPS+S9C5uIcI4EwnFaHe9YbWalPjtQCjZpdCaVO5gauQNDCNB5s2Giii5BLvK4gdqCL5LUWkwGaz
# DATA 0U4cqcYhNzFQDwH4G547TbDc/RX1pRp31f7vAQMKm9dbUc5zoSNKeTH+BBfjaLVZGxu0InxSXTP4RXVdRi6HaAvRkNSvyeMxQX7r
# DATA v3/IwOWdHj5Wawqw/YDerXiUZ+go1+508IliyLqnvY/TqHXyxf/KPblw2P9a7X5gTP8KY7XU+vyaokC1hiqhE/QlHBQ8IhiABuUQ
# DATA TOtT9KD8uZSZfiIWhtfhiCcQIrnwL79AbTQcldLjaa8PKS/QiCBsPodnvYxJCOCEgAlhiHB14OKEMP7GxQNej0fDPpm44cbUvIKo
# DATA bwyZS7sD2B8EIcw2KMgAMFA9AtzMPgTvqAoHmKLAxI8BsLC6EGvhCCUYP4zzcnk5FvDoc182VQTcoUJcqrPwZkAJU9Dvp9/4ho5N
# DATA NltU3jIxqivvD6PtgE4Js5TsYlgxSvLNWJ85aYcqSzBXsh52MqXP3LhZVIzTTSHU4cQW6N7FvltyA+oFnxx2OgyV15Qr9+qNEob8
# DATA iSpYy/COcAr/O7shzNrlzrkxOY6ROuqS2zsHhxs7m1utw+/vbcGyAjVTJwQJGSHqDgkW/+Ss25n2u+N05msN6X+l4+GwP2frMRUm
# DATA TtiZT02fG40krwpDg8o5HRAzr+aDdaPQkvolDiGdQmpLb/yyc9nyPIEe4TVeu4bJsbG1z8mA9yvEqftCsaVfcniw4z1VfPkSii0e
# DATA i7eT9E5oGwm1rk7wKJnJjDPtZ/lmVOO/bqzBrotWSA/qIkcN8pQR6uLt4b65sp1NbPVngr+ELxxtGTxYWFU2n/H8KsZ4fhHHpEEz
# DATA 8685Rn8Oc11AuueR/zmEnESxk36bZDGnxULSoGbUfCcJOmZ05RexM/QGAuHE2ZbiOfrMkVg0mKGIoght89a0+8+wNhHgijt6g/+W
# DATA pWI0Dv5Ocz1g+SNgvivueG/XX7rTWE+Q3sQu/5kbSOEKxyjlSixTEz8FhK6hHThC816DtOGVROpGG0cozJPqr9w0L60KsSELiBxR
# DATA Eb5b+CAjvB1AogeGR/nlIRR7qEoxb5BbcI8IPSGdWH1nTl3+kc/5Ys9w957caXs/1/yOUb+3Z1Xz981Z9ab5cUO9uP2t9nHTeaL/
# DATA XiM/OdNYnMwQqkchzGcYGPE8udr98AWS/+fkGPFXgIeiXQEsfPrPggiJo5wFAEbYDkuGTlwaT4l6sgbRO0b9X/f9RpGXIM9N1jjx
# DATA HnRzspiATnCCMn+rj0mzhoopq8qiXE7g4FXXehYd7aue0KigW3xqoRT/WXHv6gPreRU9CjPtizVXi4+acA2layBR8GcQ1JFrCRFA
# DATA vChoxnzxpdsmoT/enh3SH7dmf8YO+o90bDN2C4RcDwDcpM0J9dmRcFYdluUHTPtRX/Fgr5yn8C3FvwbN25jWAFbZdtyDRHKvdAfs
# DATA 6Cu4UYw+Ax3BYoacuroPlOz8S7we9PWB54r1rxaTulqVAT4hlFDuCtvug6+MzIKURRTS7sQHAYSZxfl4wglBYg6D4EhotyT88ryd
# DATA EJgEIzjNu8yHXFvQEy83Uub34LwDVrbcKzeuxQ5NjtDJeeFAJVGShtLM+yTwlXaNDWZGTgKASlZie624yuzclxEA1kUm6CsKoEGn
# DATA LmaWfi012wVma+mkfrRMHbNUV/EMy3awTHXRrhSGXwq/9SD6yORJzTck2PiJEAMITgRXMScAx8UG0v4MnmWEPB3YRZLN/GT7h0nV
# DATA d/A/c96Az+geLlgA9hf7DIpbIuEEISJEvQnoPu9N8o4kmz9aLshQ8Sm+7pFYJNYC6/CiLLTBORK4Fmyg+sJxs/GtQ5bqIFozDPKg
# DATA TglLPz6wln76uThpmmfe/8xQL4Kay90dDqqOdUvHiXId0ufb0HP9x2XCndB13Jawm8sjUSbaXMe80mZz+B9k+3iXSkxvdAunyNOh
# DATA 1r2etweKA+8koPYQGd7YaZ8aAddFSDsO/2o3cukaHuPcF/QYvBIyud41/EsxEJBm/SpObILRpkdXwTD/A55c1rhrwDJmul1brL2g
# DATA 9O7MsbUKIkqu55+hly1hqJGncQHJLJ41OlVGPoEKQmc8wZjEuPcgW7Z0ufPdzLwr2XG2bTqMr67lCt7pAJSMDvaMCwFCnK/Bm79P
# DATA Yp2I2Zhp2RwdEXzW/JoMHBHAfEV38CzNYpRPOwBoTPguVN9tQSBXi8iTDuQqcbALEKsrhd67SGP0jwMzNrDw4dCGORC6PRc/hQ+D
# DATA H7VHPDf1hgLwuRobY5oHkRQeeSozj4PVpSzf3bTgSZpXXzxoM4imMyF0OCuRmE0fgMpHCLJDn4cSJEAHvs4OB0GmC5DOAJFISVQu
# DATA Z+LS0WDQkeEWHk+9rNL1uJnHXIUbcbHQ0f9bw0bz9wyFjbJyu437od8FS/Hw6QDyLA7ao+xsOAmN3xLzOX0y7E/P9XVj3akmFyNQ
# DATA MaXHvUEHzWXU6bpMLwiGflqneuIOjZm2a4WuE721nwJHeC1dXOJ62tZd8mMccLEc7sm6t0WlRo7+mLlkIxoG74mJfpA6DW8RQmNP
# DATA cllQaYMm+qqacr8jMVxB+lUWV5bGJKVfnlCogWYkm250Qf5NaOLkIKSz30U9prlO+QmnpV7gzoxdYSuv/QKDk2a/NScWDrKsUnfR
# DATA llQSwJmDSnQ1EJZc5K+2dm6L7+2obznbKcm5/GvwHU89MftKPvLUuSDiIioNm6iufr/kKWECWXQu+BkoUQJPw5c/B38jnfLLIoHQ
# DATA GxErZ69l3mx5Pu+e+F+/EnKEFHgQgvPr1KZjrDw40xP0kvZnIuhxIurTTN0zxxdJtz3u9zA3Bmf9zSr4d7fdEdUNMSZ/pNjO9oTj
# DATA 7HtjzFOsvjqHCB1FMjvDpy4qSC10hne1+yv/lrr9lTmafdPnf5eK/QX2nBkAq/btInia/ZWYXt8Fj5ABJKzod09DTbtxunXVI+Ao
# DATA rhN6TJlWDxzsrSJOHiS2HA0HSmDu+zh8sa3h6HX1h25/bH35PaLlD+tPiAAj1hK4Z3iBb6RaEIh02nvAEGXwGmC3SZu+ULi+fuUg
# DATA av8NPbvarjDju3Y8DhP0iDjiMgwR+F6hYS5ww9cXomu6CJ7CHRLGe8mi8rEtbCuI1fqHdO/n6x0uQU0A88M8XS0MDcVVFkVj72jr
# DATA fCUil/KDXArc9V0/rS/cAfi8Hx6k0rWAF3KkvCf5X3Kbi8X+hkAE82Yl9TPoxILdjIppGQ+HDna7FhBjAQijZ5rT2tACqnPHy9Kp
# DATA nv6rdkT6itgkD5EAH1nIEQc90Te9DDrdZxXDrHUHShodtw3Uz9z4oxis6HeS28sAJrqcl6Y4iL/zExL/ksaqHrh5QFCXAf5SkXAj
# DATA DUJYd3up3jCuXz0JsQcZ6hsmAUoifl09WR3eWl2d5Q7cC39QfdJSIcIheVMi0ZEqCYmljcCSWY4YZKLghBWN85uP2SddB3DJ9cUL
# DATA NUnpU2/T+TL+KcvwXOGsSCaVzGJLXx02speuDpFSAYGoFEfacDAHc8hSXYJSoibsWdWy21yI1NGp4Yex4yzjCu1nPaYRhdAK44jE
# DATA f83CzH05amnLbm+Z0KeM87glQGsSwEm+0IIjwTq1x2BIwOQTBIuFlYq6YPZryRYiMcN9rj7LED0LVWr9DmMDjSDyARvhSx9NY5Na
# DATA HK8qZInmmQnlWYizigxF9FqEIl8g8tlJDZ1WDkqEmGmLGzoNu/PaFD1x86nw1WQc5S38R+02J/+UgyAsT1i8WvfcCULQ7jHuMnq7
# DATA edFYgrOQ/t6odCB/cHdYnPe1l6GAKvO9moMkNE0MDqYZUtjMEhbMhC7MzXt7PwySYJYP8YWsa71qqkacfU1vT80b+vr0OZ9lDpSH
# DATA oUnUKLM5XCa44v8hTLX0O0rx5pjz2OeG5x9Nmw42kedPwinz5rC0PzeKEZE0mX/wDTAcf0zoP64+zw9TyJ/LGlcBSjgbChdV2nFJ
# DATA R2NnOsA9gMyOcaOoSB9GueopPu3LXLTkXI6pWrXXXA6UBDxomiwk/ICk7dKC80KXQYvuTD9GsOI3DEerpCdjJRmJKfRTNiH1dbSK
# DATA 9Fgg+pAHQNnXxRVnfXKmGDFOHNSOLxKhpZs/xRFtBwUoxLFNFkuKw+PNiTvQR9G8ljAjcbWP1tWEg/WzUdq67gT8ucSIAfHkUzzP
# DATA PxUeCIyk5yksUX3o9JhaaGHGvkjW5WjDX5A2GJKE/FRnXZb1OML7JcZcnbfZv1qyQYJqB3wg70wy9BANrWuy4vlbe/YeBg9x7JL1
# DATA xMSi2xRLZN+hv48gf27Tq9gRkevqyFAdTeT6J+O2cLk+as4K0gjV3TsehO/e3nBM/gsj9YeNZEM74t7uPmLtrKv/pWXHWRYr4JtQ
# DATA dWGQqXN2boA041ciR2CYl1kD5BPHS4pCNUwqu5xID8luvtL9yehWV7oFhQ8Nh5m4mg4vnXgMtuqKkFS5KFRMjFJP6CB22IRYxmIG
# DATA YxB7LBZDDB4mES6dLDaT5fkTV3eJXzkeLYmxZqxB4h0yy49wLYxrLcXIKcVJBtsNHgfscqkgPrV83QhGjxZHosHD3sW+KAoP9xf2
# DATA 2iH/0YDSryng34Tum2B+/KOqCO2zC+9nlbwjxzLSX+AEhJgBFiqA0ANmr47f8FU8l2iYvIhUpr8GRZ2x5P3ti7+vJBysGtVMOnFy
# DATA X0MMNuxRzG8I+jsDN5JgZt94ILMVudR1aPGbY+erhLUvGPhslMGXKR6lp+0n3apT3j4WXwpZVX1v6B2GTLtUsDg22i27lLMjNLdO
# DATA Mcy2xfo1ztxcAIgrnPKCVIHFG9pGFBSwpI6+YTycKH6HckNCAmRdBaUjFonkjyQjh3IEv+APZvl1HwmeA0khyNzAk/Cn+XxJOaam
# DATA CfF/ImciCiYw19PzKJYrGiyUbyOewNtiTDklm9EGZYRbpHbQWpmFQImMrOFOSu54p5tXGKC2pMHC6QGRgwSvc8X6S5j+6EtYrzgz
# DATA PKrimH4KDan85RXn/nJ5WT2qJMvLpoZZmIKq4hxHJ+JQfV1SfR31Eer9TN0UxFnAXy3Yby5HmllmVJcFK+0QTlZJP9F2yCx7Sgma
# DATA KFo5q1Gs51n3WenGetkmvUb2Khbf7H2htvje7sHhB/tbB629jYODj3b376GCnxqqeFNnCz882NoHhb+8FM3Le3fdV34tXjD2qbhO
# DATA 6ysr+kf9Undj9ieWSHeO6+/cvLG+kl/7+/u7O4etrZ17rXu7Dza2wd05PZtMRpmqG7aaXZF0b2Nn674tZt74VR48vNvae3j3/vam
# DATA LewwUtNxPys5q2pXHo7W0e06CFMffrR9T/Vs4+79LdW7rfc3Ht6HpVFcxrQbDuTB1uH+9qad63bnvIfuHvoFrFh0ZSFft1/bR1t3
# DATA P9zd/S5viNaHWxv3sNrovmCFvDqoEE/Mm9lwyu4RpQ0XMsmj9mTSHYP0M07/HCZ+3K0hnE8XTj5Aj4/TRm35G6nLt2mcff68gr0A
# DATA C2btgUdGuXvwyfTYlmcg9FY9CQiMruy0336cNbDKgkQgWP/bDQSkUDWE5OptfCWJA3yi80KCxzzQAprgSjKYnh93tY8c/dBCMb9y
# DATA oyEQSFbDZfjYsvD7zfTR+NEAcDLevJLnHQI8GL3GHXC0YVhd1n3aG5bReCWEFQBbwR9kStSWX8fVq30BjgxqcGBtqMHfYLzKurdu
# DATA 1o5v3WRjmp4WHT9HeVkch+gIijbXjTftx2U33IjfHX3MDAP7SrU3u+PJXvccTs4Pnk72pseKbn+Xob1UT8Rr+KnewC8feQQV/CID
# DATA Y8mxLZTsi0pyeDEKsjTSqsiJlclTEexFY9U/p2SKnA9aR+I+h9AbgNj4Edrlf4zp/L5k9SyGvH0ZTxDBO/P0TcPYNC5pv80eDWyH
# DATA GuklI2CoPf0m7+Gn7d6EQj+QgJY4fQn4tA2nk8b6qg1RFkAP6DSsyMEDDOPACAhYvU67rzjJNBqhEd58rD+Cuu7hE+0s754cUQya
# DATA JF0Tu92ode2dwhXdLUA+Rh9lVTJbAaPayZlqqTZS62+UXLaWaI6x1eTbTpkwA+jajbXVd9ejB/SX6FQAXgTPQfZzEUOjK/08+fDw
# DATA cO+gauORUuNkxLnDZG+sEZh1Wd32KZNMnc2kCv+7u/XB9k6yubV/uP3+9ubG4RY+rS2/h/+quzR4l4okRaq6A4d4QTPBgH8RDicY
# DATA DIusQluu9bnPRlo+8NItZVm/trf1oAXDbk2G6lrdx79L0Al19ZbLNZ11yU4UXhzwJWVLanG4QItflk7aaEUDCUFMZ9mpocZxTHiZ
# DATA JJ9Qfd/b2t9+//utP31n9VvqelZTtnG/tfmh4hicL9U93jufnoucJvDt4f2D79ED+PPJWmudnbnbHbXnYBPDwaudD9UUg3taCe5Q
# DATA PotkcjoDU0pQ6Numinp+IlvID5RkoF2b6ElRvR2AiV1JCKV0bf3d2qr6v7XU3GSWEKjxlNbBn/9ZqbZWMc1V/a5AxpF2pmjp00h+
# DATA JeiAnqCn4/aoRb0pqdKkluuOW5pONAxzBfUpwjUd5zH6akv6O4aKA7Eadbtj3CzHSkofq7Ucjs/5IjK7BgiY3n71XLHKooVRsPqn
# DATA 4MLmhA1+xYnG/0rjPEoEALXgVTrwiAP2o7ScI7VQ17MukNN+6TT9YOtQkTA4RytrtTVgCD5UU1NPLvUMzeDZpllKJVn3wV0AOAf1
# DATA /1Odpqxczpu99dVVIGM91P1Q84p8Pim9s7au9XTlozXIw5rcXF3NnyFB7udkN64k2+AwFMt0DCKB3cSwvbJ+tzsq1Vj6oWVwyUo0
# DATA 2TuA9fwmETACv6PsAi9/dkcr1cgD7mc6YQ2uaSVKljED1b8QOifYSpH5q5KqUVvz8RcDipesDJL1wLdAXVvSZD9XEEQeRr1NU7x7
# DATA dR06Ex4J76cpIblBXFWyiqd3VQlVeG3qL8ozID13Hg1E0aN6vZlbzmF3T9M0pZOZXF4uiSqmg96z+sqT9nhFnbsVo8ReGU8HKzgR
# DATA NTjcUGWCKtcWyNrDk2H/ztIlDW6mhXR16nEq7Ia+Q1aSrN+SV3yktUnfu9WjX7aAsc/5ejTuPVGv3W91X7MEyXRtnf+9QUWAVVpP
# DATA hoM7S2IIKF1lyfD09A7bQNQ1uTLNxiuKKI27NCkrZ5PzPr1vTydD9Jqzn3ThOLQwYv/m6s1kRf2nJj7odJTw1u6opfjT6ibdzFXg
# DATA RKu7JJCqPZkNeqeKq+4/bV9kwVf7gNE67o6re0M1/RfAWfdOJuzJV3161h1UT8bDLOMnTjX9ISlCkj//b8nKM5gA8JZZ0ZsCr75+
# DATA DwD11RXROh52Log7Wr1j3j8ej05axK7QpZLcWF3NvPdA9oreA3XAv5SoX7QFsYu4BakCTrpuhqFG8ehRrfTeG0+7/X4V04iulNVo
# DATA 1M02uABX5DvBJzBYuFXJKyH5xnTcw/+sJA21UFhe/T91XpgcnI672Vkp5s5TMdZfbc80t15qLt9Gqoa/mlbo+DSMfQOZdaIZWNrX
# DATA NOVYQ73HSI9UC2vYAmq1Bt1JCxUQFLPGLdmncGnyQyQa6KmpiEP/FOJk+ql8R9XfvHlDP+0NjodTtbT04ja8sZKFW6dW/JWcuqWA
# DATA EZeFAQzhMzbvM6P9Kfmhv/ht4jKgKBan5aV5KnC3Xw1XzDHJA8SKhMmXEWAOryAKQvuZiXeIcMY2cg1kx99qJIbX0l3bNaM/PMIb
# DATA IBbExvoKf0kjixlGDEG0GzVB4W438rAokYP6abKxt11x1gfAftid5Hnyp+P2hRWlf8dBbhqcEm5z4RPSO/X3MgWzmAkrylaJsUgQ
# DATA Erij5OWNew+UuOQie3/O/MNPAFgIZPofy5Cnz2mlbaBBDDbLuIgFMaABwEie11m+Xqk/fPyY/NEu04661tAtJAUNTZXzkaTDkfYA
# DATA uUwVoa4CjYZCN1ZROwKPsKh69E7KBBBCY1GCAQMbZnuF19OBIoJZNZsMAfcSPubm1Uv+K1BQsgkcGncM38bLmO2yHelQMwuqmfZ7
# DATA 570J1TMYcn8v02x4Cj1bW715+513b6kOqWu3Yx/MZrPF/KTao5FGgaahM5XW6J8a/ZxcWe2S6pwz5WYlxiHDcmWNo1MrZ9W1lqaO
# DATA lD7+GUe3N47YBl0lmYnuPbjprGmafFuz+opa5RU1ihV+kFNzpwsGxqw1HDSk6bRzjLOp2NgO2o5gsdmUAoxEf3J2kc4cqyqZxOd/
# DATA NIt2g15jkLnqx0TtMPBBSjcf3KsefLh1H4GGTwBGuHqaHSDrpa5+uJT7cGnC1K2tUB3oeY5o9WpOoAdrq2i1YHYCN3VGBmHF+aCv
# DATA 0y26WMaT1kiJ+sMOnYVMmodDmhIYbUEFOVLvCJzzKDUEJG3GsGojW8vYR+prt2s302tvMhIhz86R+WqkSoA7P06drMJqjg//DIb5
# DATA 8HAT1tHuL91Dy1IJH4iC5hZZwNHjVi8D3u8iqT5MvvGNS8fMNEuqHefhvbuzYDFvzFvL9dWZDNtQezJnrunE8MGpf6va7o96AyCP
# DATA i561vMmAdtR9I75H0QC6Wa1m6qggaDb+Ius+oHWRVpqeKvp73j1X61wdIYtO77rqGOGhwjLA9VK/4LfXNf4HGV+/uNrhSOTfffdd
# DATA egUUCf5azR1Q/tJap5iq4vuxvmyB/kCih1dcWeE7J8iWKqWm1CFLSMgEwmxIsPBfJ0gpZJ3r+RlRiOXLtwrmf4mSvNZv+y8CD43I
# DATA pw3NBoA3SfAanGFur1YSxWXPcn2RmAErBj+WJowY30Wg4Fp1EkkZ+iWxuWnUhSU7kr45gatbM35+wzUKdy9xGg3C01LfHmneA/de
# DATA rtNdPeZxF7m2Cqiz/F5TauDmTin6xXkfO3cxNiFYYeAY1qLHNn6pX+9yLj79KHfAuQ/t2synnXYhfulNvrLteKDvK0gABu0+391v
# DATA lmuTM8iD2/gO+25BrOCkNK4NP35vtb5WLtdOMByqVPZKqFd59MuhMu/MozJr6xFmYN1lBviGANoDRxyinjzgBoNubQmkpdaGIXMj
# DATA I0HAp0gwlPHrOWeF3uacCnpbX7e3mXvpf7B7b+vuww9gTOfT/qQH6pvJyaixCkwAb7r09mr9NigEQHKvk/Su/1yZdkZFXECcaQ2O
# DATA xyb0ksIawLheX1F7ZAW7vmJe1cdDk4upCvNZX4H/2mekYq2vuOidXuM6+uxSVIRhal41fuia8Re/pEB866qfyHA3/ScsMwNQ1XXT
# DATA M6ECn4zbKGqb1YssOClzjyyzyD7l4gBHwCicQngaFxZhFCsL3oiswoEL6/osJ7O+DYftNVodK4jzGCsFm0PxDXpbRLV6mJvQ+0bJ
# DATA mpnz0fDxSjYdweqg+2esyyHRBqvxCsyDZrxi3WCKl/P1yXDcNX7Fsc9hHd1SzThXg4okWMPYPmq68TwRzRNeA2RTEO/LodCi921T
# DATA +5oGI0Ozef6STPoZnNW8u12YSPKIFr6tr9XWb1u6FducS1ejMmSAgPMtyQxp4OFprbPC9mAshASnmLJdc2quWuv8E3DFCp8+faor
# DATA jJkioI8e+RQkSy7gdenj7HVEUFk12fwYqiCIKtweEUgc4NK8MCtMYO9V7YdRYVRMJIaKJpG5JPZuqcvj6leMKgZT0FgHc5RVRExT
# DATA 9ox/dkFz8ewi7C7FZtUTrc9NEVpR9BRxPAyk7oIqMvaykXzpwzFw1374SaHX5JUELxlQfhlmmqknZJ5w39DYA/a56BDlZF2hfQgZ
# DATA V2rwn5ulcnlWDnvoY9Foyloo58SQppzxSnerhqvlJ428doxqkE7Y0dmXqcg26ey9Uo4mvxxzgpZBerApFP1wgkUI/6FCuOIVsJwN
# DATA n/qmJLbXDPsdoO5PvaABhmisuKnIoLqy9EcF9lrV4IRooWoBOPYMfEtKFLQKp+K/fHTYchyWUwRKvrdNf6GXrvSzhb+1+yxkw7NN
# DATA XgZZzwgTVf8KfJErMWdieGiDGtQvJwbBjZQJY4vUsClK4o0GzB+5RnYv8pN8/0+TXOHLF7/hKCLMWITBtJCvKBI09PJvCKgAaqbI
# DATA RrU1COuH/G1P1CEYQibP0lHpnBwBwfwMIRD884DQU+2De0po7A3wNIin+x+lHJiNsLocI/gAm+PsFmW9Y1rUC9w4LdMj+sNuHf4t
# DATA dg34GSmZHqLQNAQsnGC0ugyzGu817g8gaG8+PDhs7e/u4oqgCt3cvKq3Ao53heJuVeUwpBS1XRaZQ7+qJLT1BcAX9oeNm3ZkbKGi
# DATA txDnacZpl9c+A83F8Em3xB9Q9W/ZlKuTs3G3a2EMq4AHi1i6eAFzi+fti+S4C64B3U4t2UI4FR3HxBViSYBJG7WPe/3e5IKExIp2
# DATA UUZ7IzFqilSgHgzoLII6TIZMKXqZRj+0UAm0Rq8aFRrFT9BTrRvjVLU+oSkMFoc9CUPHFJ9wNdqpLwfn0pQUq6krgGgbsDbi3rNP
# DATA bzQ13jHcV5G4Kj9MTzZ1tN7U+yeO0bxgfQRyrG2QVPWaxwaOu5DwF5FZqbg9ATX9rjUZ0oHSEe4SdwEudf/DXtZa6NswA40JHuBe
# DATA wdqCsVk/wFinDCPy1vHltfCx3drAtZTrch6vNaGZ+Aoc6YVqhmsRnmL8Zfat2EVE6AM6ECPvlD6OjNGYmy5C2CMJDJS4Tsf3Aevx
# DATA gDO4qzYr4CzB7832aKPT4b/ujYcjLDTuPVFsNZhom85N7N37NoIQHTnCurzDpOiMvGh0GGE9uUQH3faorHghJdTj5oOpG427p71n
# DATA quYNdeFz2HcbMTpKXhA/OEsGhMZEq6q7xo0nhEWA3tCFw/2Cf+xlg7/EVROJ+dQjZjqpK2qY6pNPFGdhFSazxSmBbAKnMr+N6pXb
# DATA MCkO5s6d2qGCkucXjDp/hPyJrcBmzwW/yvgpA0kS601zxOQ6itKg7GWJOY2ociBqTKh8ogVDpQ1i4InflSWTjhCyV9g0GjEkCz+L
# DATA xuIOIRq7W793obttNX49RcDdLi5QNFZhLoy375/EWsnSFaE0yovjR0k0jHyc0LnjpZQvAiLDoMB8rpOCfvXyL5Fn/p3J9IYPf4R5
# DATA xv7GIa3o7dlIpJqhlMbvHNjeUpCsnXWfOalQLgtxXeZoR6Aj/Bz+LMvkABrZ5dTkfKgYIp2T9CGI+UO8MmLl6K5zeSZv2SVPbxNg
# DATA YFg5vIkICSIfhZDsckpjDmrQbq2krh+a7mUI06CWCYIYdIEKiDsNvnewlTryFXSNO41BnIkWXyrIvuULYP/gnppg14jd5iSuxjxO
# DATA Mb8y9erHrpjGKSyKQR4Mp0feyLjaAfxjkMv6VbNr0A8nuwb9IVQmbqIKW7GpSG9QW4eoeuZm3VR1KRp80gfn4B2d0OKwPd4enA4B
# DATA hhXRH/m3pryKYLdQ+dFVXFd30gb7UAk8Tis6VXJZplyeILS26kh7orrBJVTvWuaMm1oIVFTNyirsTaiyBu44jrpLPwRQdcB5XV7H
# DATA jY/NQP6zZFk/j12gMEYW6bgniW4coy66nQylwax92k3QW04o6fmLWm7PMcGw6siSnSiwuLZG6tzkTRAOKJxPXdDPxIoWGkX6bMWm
# DATA pNfo48EUcgp9PQ3ryvMazxTDD9lActrmkE8sxDhyBEQ6gXZGqCtBkd4u13nv8ZgpHXMNqCo+mcj8W9wS2GO67fOKOQqwOi1czsa6
# DATA 2SA3OEExv1hbVf+zeQHvwsQkFABAqob+8DHiuuNm4aQjgIKJSKcDJbvDxkHfdQC6fAKdVt3omryAbrIjSYX0ITnBy6CRrC6ZqC99
# DATA BofqlJfgr+HxDxp6eGToGX9CCYp66ow2/EOMQWA8LZ603kU/GBA5/NdE46AvbzeSNS/IaIx6JBKAsQoCSyURL8RIgVq+Iycajmv4
# DATA tWLK2seKbZtOusSZpbVaSlix40mWd108HOBBHYSnGsFkDTYHdiMtR+806kUvI55Qu6abx4xkaCZMPeLNXS7oldnEgxjBgXrC3nD9
# DATA FBubrIommd7ZXawEFNwzeT0QZC6gauYgJejD7HajY69tIGbETvxg2BtgHoBl0hXEplF86CsreKcv0Fc9QwSFoCiA2modyePkTBkv
# DATA XhQxWExhPP5Or5kJo7WsqI7WdykR9zIShign4fxj6BOe0NXhu6urECwCSDoZh4MgoHdr+DGFVC4mxBKdUGdSDCpv+XSuslfoB1y3
# DATA Z9NJr1/r9LKPW9NMiW16NWunoC79trND305u3cy7fu1Mb6vTcXraO4GYJ8Dx/RiJrGKzzpEs+Qda0v2oKk7fynwd4HmlXoWjoW84
# DATA EvAKG1JHkKsvz9X5B19Mt/K3AEK5P82wMIQIwwFilGy1h6dk2tJnXyBl6wuEzFaxsGPocsVZWbwL0mfHKRL34XQymk7qhZvx5Ext
# DATA gBKuvzgTBh1+bW2NNIcIPh9uRtJTk+ySt/VskLUpHT9vx30IbxTK0XanBEHS5rNKcuudd27cyo+6BXqDtcwLOY6s5FM1Y5PxdACr
# DATA 0cmJJKYZrTEQPjQUL2enpUq5qXLKcn2nan+cRSDDh1ntNLsYnJR0OTWJg2HJtSriDWasiaOLGNcj1CV62zi0V/1N7gmkKEC3sFEq
# DATA 1Czo7oCQ23RQQD6soasiuzGw/yAZq7Uz4R7uR6gcLEUdCHqXb7f3tvB5dzz2nzP30zvHsBywwLRBi1o7hCelNfDE1cU/7vX7onit
# DATA 0+5SbA2QLfEcRV8NQAJRoaqI0Yc7kf1BmH8BP6l7QcOrBCKkD6MO5xK24HTsURndJX655IGxmaGWZE4e2XYNQ9TF606v/XgwVEf9
# DATA BBML28KqKTpcmBPaT9RQoa5kin2kBNhptEWoxG/R+LHocgCFUhLAJ9bRjmgl+NptDqf9DsNGKxYLWWUgFsjjyTEgZCDTaeeNlAJp
# DATA GtkehFHdhm+jJmMANZsytxgB1aSb7QEKHerS6V/gwRJ3zx2b+sweEZ0UogPKc0yqADWF0pLZ6Js6OecePeCTot0EwBdFjFIDdKtG
# DATA +3Kz4uY+AZwfuTfIJRKbGQ1h18TvtpydJV8Fa0ikRmcSldpZSqOuaKg8zupnhQgTFmrk0CgZurpQfuK3ko2EQ+X0tjhvf6zkRbow
# DATA IUYPTKt9Yt0QqqLXpV30w6lilyBrSLc3Amsx13cyPOsiAqMeWy3RGTyTj7vdUeYmvbMrTwkzFBkeTgENky7r3iAz6CtqDkqSuPK7
# DATA tGKzkrNysgn5G9A9nJgwxe6qEXdbdAPwQ0D70H96h8t2ygGSMp1hYlEWedY8/eJ2h+CHgp6B2OGVRXlSaqD3p4MB8kCR1EKUee5z
# DATA UM/Rnwgegal1Ytq8rxy1OKcsk6jomE6IdH4/yQsGnZt1npXMojBqe22SdfgZYBjhw2hSYZmw4No5hbF6z9Rztdyg3hw/L9KXCnV7
# DATA RCYwUoDwvVgkgbPLZwCgqpMMuDI3sTOf6ULjvNVsw+SzQjbHikz1NfPSLcZn9feI7/2zBabP6nGCSRQpBWGaOgycLoimc84CHs3V
# DATA wkMNNaKDcG3XPWnjHhGZzIrMgw4l5lQSFQgU0x7kRVJ0MGkfZ0Dt+t3HbYSu0GiFtjK7nfFCI9ZqBaLe4DJVf6KUxixLVkt2II9Q
# DATA kj1F0zVSyz4CDNZ8eavg1jdmKBwocRoYk+XsB+d1rs3gHymzyed0LsioL21QX0YXVycxI5y/3zPkwe90ao9o/hSESqCsCn9r8Lfy
# DATA NXh+3qMjrY9c5j00ftwfHpfS5bTs7VjQ5XGyzFqfcNNi6ZKisGsmIa6xcroZcstFE8lWFQ24B2kmnwMoNsFCQN7J3xsYNrD9fRbO
# DATA 65exQ1OgUjRaDRi0QYcTI2QVHEmoeRpGVN9KU4BQ9OYO+Be5W0LviM9e/vTlX2tUqigmHewx3BToG+gSZG8CcECeLB4slp6FQun8
# DATA hDJeDwCQrRSjsQXUGwGaHTKNXhHzzPdlCYONEz/mRI34l0kjTjlgIwnrnEyesW+cM0M8HchScHAYXVEgKYJypTecZmnZeTymxMUX
# DATA wYkiFDPC1tc1SwM6vY/riOndgp4mDJeGZ77Bv7jLkDgQLa+u0g7B1LyyhMcWKc1d8hNjatbi1s0ZChRQZfFBj2a2ZLqHGF8EuUIZ
# DATA MRR5/S05SWHmYSasGpBFnZ7P4VHYVWcyYJNBLAViEKyoVyvPxu0LzgyhF4WGf074mPDJ8XTQ6QOyxcKOPrLRN+bvbEQ+phnLnbC/
# DATA 80b9hR4zZd9lbvVLnXmAUvXKSwjyEqgJ5IS9DhuHSXu9xFt+fmc/cRdW9YXJaoAotZwg1u9gfP/oA8g7RZBZdShkhki3HHG/hVMV
# DATA uY0laJy8jfXciPzyv6RUuIAW50F+2j22ZPz+MsoFCIsMoTAibeFGguo2xYYhw6HE4p7UO4PjXTIaPgWxbphlkNUYc8q1x2R1GHSf
# DATA ispIBhAuRAki5WZnyNE8PYOkC1qa1JbB9uAiYdUK+NDWhMKGaukRkpDAtgLOVvEGeH87fAMy7ZZXCK4N4cIhP2Ofc9Gg47SBUEPk
# DATA tIF/sicoqCYAfJNRh+u+gQFDMFCJpaYfVX+c/i+r7bb27+3u3P9+8gn90oy5ebCz+/7u/fu7H7lbchKjrUYrapt0vwp0JOJLUlnJ
# DATA Lxm0F1S6LSXIK+FYI/ZyPqN6ICi+krM728NNPvF8lF3vm/M2J/lI93XFyf/36d8jn6GTnsl8JYnMDK8xCHVEKmpqu5p5pGvV5PDJ
# DATA dwGrEQpVyfPv1uyEn9KhxSBJRz4wNKFikVAorsCylyICXlcwypGZPHjgEy3arUuxbJx6cgmPKxdzIKu1OxSqSQfEHiJhefZS20NS
# DATA PJsiF3IbuTniKb7XUs/6Un6rsS8Zf0qJhEgMaPHVzsIEjr/F1UYfupc/1rkwcf+4OWNf/O+CvIQ2h6bMquuFu2F0DoqUOq0VZA5a
# DATA PkoT/DogSLIbOl6w2YzVCqiv5nL6V/J7hJw8n2rENvTLKm6MyJiZ0HLTSUNontu5p/l8G0wdiQxkAHEFGXObSui3iZ8Q+sUXdzzY
# DATA ObyIYL20EOglH+SEQzU2kojWYQbwQzzBP8Jx/xSw28TNVks01h3ekqrUbzHp2Kekz9GYIs9zkh4qAp4l1X47zJFAjpu/VwV/SaD0
# DATA Jk9iDbN4mPTfP3IyCGKoEwKQsEP8Z7idKD+hdrd78WUtbDClvSiTgfM3mAycK4WpxR1qdyardAzKQ5ih4cX/axFklXDmetNiGkRV
# DATA ZVghxbiHtUEnv6Bt6Xvmqs0Z1jPuPlbSDIgH8UHTaYUqlOhYT0460UOnHiakHdbZo5IRRgygKZFpPRytaaZTWWIgafzgNyORCRYk
# DATA ohIBVDE4GlWdPaQ2eTYxGb4o7LuiI7QrFFRd4VmssKwGf0BstBvF4BI3cumJpyzH0yFzNKHRMTJfup6ycS0bEdPF/Abb5OcliS/l
# DATA 6klsLvN4KnDHjRYJs6860fmMfwGJiyk/IDHgeMDf376/dQAzHDC7Iq9xmH/dw4KWaaP1kC3QsZoN91oxjcI6AYY1OO+UcNLLnJSD
# DATA 7zJE0C2+c17+tAJU5y9tguYvZTrWOCFPU7sz7R7G7UnR0BoCxzH4nFDunuDAgTu4rUUNwNcVYGwTfC1EGG0MtC/M4nuGQWymO0Zt
# DATA Leol6BNPZMKpelsn6tU9oVW0VThsXV6ktDrr6OP8KeJGSd7NbgpkZnLqLbuLXM5rB69TfZcnbhopA1Zq2zBBBPY+p3DSps+Hze9d
# DATA Pk8UTihMxz+5uwiutIVngvFVPC0bJqTzByfJ4YMcpyKkII+783r8C7qecc//9wj8V50ZmcfdhfZE8b4QOGPexAQNLLo5/A0SNBHZ
# DATA K9SYx/HZk84n2LJrwd25EsTvq6u5xkItn+ryUf3GunuzzD3DgRaI1z96nHmBaUdMBzrct5POq1RsgGAcV1juRfZ7fFlpp8fqXOio
# DATA 21HnHnIxRAG5tYK8q+Thfk8aLP+u+AnjD3+K2ikcWoIffaEzw7/4MuQZdSvfDmv8zgrZrBhuqrq8wmw07FNgpD3eMpqN/sWXFdBG
# DATA Gd0dfQX5gEQ29y+iWrmws8AI8Xz8ywL8KKGk8e7XQnwR45lWTIS8mfbnnDYBWAwu+RsTVeUgJYds7i+EwPEFSzCfqb5htvEEBo4d
# DATA +hWLECiJ2FligVCb6HUWcWPz8bR3ik3QobQv/1LLQmxaR7Wh4VNEOizmYTStiHMvuDEt90KqHIRp4lOL/thj9AV9jH/XNsaPp9DU
# DATA Hr4xmiB1YhutluLBW62y+BJE9FabPymlw1F3rMOkTs6GoBdpMKYP5npKMZQsQ0MDJ8KlFNwIKwM8TpXZbfxG/m1y6mKcQMpIPu2x
# DATA Rr3DdF/w92PCvSP6lSImc3ZWpdOCZTHBjnjgUCVAjwkeMupm8Jz7BwBTvYnG9qHGswnoycUjDdJXZQgDHHG/PRBuDlg/K0O9x9p3
# DATA SjpFjNn3xtREEwgNVbkDcm5yXnPn4y/1OOitM3bMPWFWx4I2oNiDakLtrxDdKdUqm9DKd/IKsEUuv4D2Eipsxsp9ckt6/HR+G/Yy
# DATA KWxFA0QVdJby9+a+p6XOf89bibDSC/uCCZILahqzDxIEYo4fZw1QjBeOTe2too5Rnlu7GrklhT7JrH5Rw/akcGhgI53TU9ym6rOq
# DATA zmrZRstYI8Vt3MKMmMVNIvzY8NXrACyk6jnhHNhtl5ddoimGaMss2ApjKpsKMNHFncLvGIMp+JSSZBQ1S6TQXZLctvzqEXO+mChE
# DATA aPGCi+98SqdtsV66XGnQ5bXVuUcfLya7yiYtPKpTGH7a1Ehv56/tlWYaIMLz33JGOG6Undm5LP4DpTMb9Q+/auYuNyk/+A63TIif
# DATA yREFB/wYqVlZo4zFq+Rbou4qbLSNya+rkognFJFbXL1/L9W9IGQt6MgafWxM9EsKIpb9rh05KH5C8O8O2sd91JBA0tHFYEUQvMQi
# DATA aKhdtHH/vgs34liRdBoAlEdQQ+e8Hln0FHRxNk7/cqkBdwymjPprs8xw/6PgwE7EttMJA0BnR5GTTR4+6wCeCOYwgNEVjbJDgDAc
# DATA 1r/YbIJ9O5YaweoHxfIbi6YbeGAW0Zk71mBeqB1B2c+pFKEkDoZp8eaUPKmdXnrQgpdd8navWaCFwvp8TvJKm50xIPKwRPhib6mL
# DATA ir7nB+VKEuviglMrimjfPuhA8TBj3LFwk4q43F+RaBTy2UL64mLST18Xc4d9lUX05Ai5hvCixS8E6eH6443xbyb+FXPUizvhiy5S
# DATA 1UwckNONq+zPiIzh731tkM7bWHKrUooUxBDg6sLVdm4NeY9wc8aPjiGISJlW8ZTYdv/bz6ynv/spjT6SI8B2BBn0cuRgMSvdsgfM
# DATA fiSY55azlQNX2aKhVZJ5I/Cc/8gBsjcYTScOZga6I9StJQb4WXK8qztOUPhyFj32FA1jD30BVUD/b4G7nrfNimRdJxkZllpoBy10
# DATA ZAub49O72HYVO3WhY5ormYfnljrgINNiUdENXIyKOILcrznGPlVdac5EuVoXsRaU7pieX4mkGD1SvWj36FKlebeYwIKOklGmemiZ
# DATA mTPWQNVT3EMu3eLSRT0NaQj+4C/ndMsq23zuoALg7IjBoovEtuZVZ5CB//0+G64TfxLDVDI7P8BkLqQNPlPhOEqLo3QnDpUMjLka
# DATA +J24Vw7wpMa0IJqVsJHNKMsjXK7nXItG5Vm4RejkqmKlopNp+DFC+6YfhKAazi3I1nP2SyiL133u1yiaQwTueJNOF8tX6YDWwS7Y
# DATA B50o6XV3Y+5aOW3NXTJDPBeQZec2jcwoNJnvf0mxX4hDSx7yYpss0geGfrdrMI9h651jeqjswkYhq79r5FoyyCBL+qqASW4hfW21
# DATA xBnjOMJyUKfBHHfcaUYrlNGgwO4pXPkXwR+EEMxfo38X5poKI3RMR3RWSfxRGlV0Tgxns5nPbFcpIM7FE7kj3pvAl3fe8cmhKuO4
# DATA IDkJwUNy4OK0G1I8J+uswcads0XINBPeLposU3riha5bk+BBXiWF5I2yEYjxOAXzSEAks1fkhWzGTcxYQUWJbXQwlO8ikxtdCPnQ
# DATA wcf30x+8yg3lVrEF8E57EPhIKRTmVLPALXznenegNuM5DHOA+R8wHwuzJVq5ZVT6VQQhd1AbtDOaceVE/63fm3zB4L1VBHYcIHca
# DATA +jBPUknrgTaOk+vEiEdQVmbjcT6IpuHRX8HWqlMqQEv9w1J0BOtuYmD5qhzTJNaT3kjN8BiwDXojw9Xq1xXOAS/jpfMmCTEYl3yf
# DATA +ED9qqt24DiFlzx+WEFs9RBQPc873mcu1Pl4whmrQcomj3mBY+Kk0rA1CM/6fFEOLdX1uVzsUk5mEq3er3sKn5SsIHVBQ2fhkrE5
# DATA UGKC1GNZRrjcRsBBi0rmc8NLS6rdFm6lVguH32rBJm21eAKckBZyVVgSQDEhFAkgxiCSSL2I6dBn/J9e/rU6vL8kt/Acv5e5TtLY
# DATA nKIvmLoM2BkKsxZALwibcnCRTbrnW5QxUA6i9D3YFdj7SvLd7gX/BZkt+M/dA/4DMSr+y8Huzj0EocGnZRmutY2qGcyv0Buc9Kcd
# DATA jQGGSROyejLAmHMcfzLu/oAgNzgfO0SsTfv9BBqofc3TV0te/C8bzPbyZwRYwQACxqe+4mJY/JSCAQVdJvd6N7PIy58C1tKVVuOP
# DATA /kP9Tx2e4z5ciOp01EYXX0sbEAV+6+ZN/Ff9z/939daNG+ZvfL62trp284+S1T/EBEzBo1w1/0f/d/7vzTffhPOhiB4ZM3WsG8aW
# DATA 6cQrpEvrAUjeuNvvtjOA9aGQyrXaeu1b67WlpcMzcFqVBX84VZx3MjlT5B/h0zgiAkEve48hj8tZtz/CwIszoAoAzKfeDqePz5aw
# DATA kJETksPNvSqhhp5224DKg4ZECAq1feR81clZ+0lX9a4LrtRgt+vUVN+6Y4w37aib8hhuSECWGgyNMfZE0n6EKH3WPZlSpDsgRQGj
# DATA SKh9S4AcO++mCchCejhvPGfqrpGdTv9AhMQJSDn5QfZvcP7fvfXOmn/+11dv/Of5/0P8L51mXeab0ztLS+ogZJPkMtkb97Lz9ma/
# DATA h3I0/Upm6MGPx7qU/skIH66cYJm0fIe//cHTiSwGXMbT7jFZDsqmhYPN3T3MfLGLWZYQufQvuqUjylqR4cmpa/xr3zsyqwPImeI5
# DATA ddJbTnYROIHz+6zOnpv5BYCDV9U0oYen0wFBUYy70wxux9J4+LTMOTp0Qrnh0+SP/xj+qXEKEyc4WDaEbt6pKm3VM/BZ99lITdDG
# DATA BD8dAKv0ySeJ8+I7mF7uHnDi5XLwfXaieP2spujqY8RxaPCc6ieffOKw2gt983aypkfFRZnxy9xQDZzPstsprglYwosSfp00vhOt
# DATA Cn+X1UzPlpbaEE6emBlX0t+THogYJdpdFcwtofN06TUAZdwbK39+tFr9Vrt62ry8Pauav2/OqjfNjxvqxe1vtY+bzhP999r67Bsr
# DATA NcgEjqkQYf4hAYOYOMgLMDzVWcLeIOUVJFpIoTA91nP37eTGehnwMtXOgHVjMMPtAcrj+p6iC0Z911GHpteGlCF3NHqc2je0l4p3
# DATA kiyv3cBAWAKXqYSmrdYe9TDbY1YDjKeHg94Pp0qcS57CPVhXxxvHO0tm3PjKSrLfzaaqbcyCk7Txwq6iqKUxpiraNQGawz16gZcw
# DATA YCr0MARO9bDdB6CC4Qnfo6fJuPf4bJLVzLKZDqtt9oY5X/ppWa8wTr4/lewGlSAtSU7O2oPH3c4dbYREbkDtnwmJITLCmBxbaaiU
# DATA M6SvlhNqb9gZVAuaM4WIHQzTh9m7RQ9pb8KaVRJ9auv20MJ/aoPh0xK4ya+tJsvJjVvvqP/evnUT7zkAycGjUU+OarUaHSCOUHHW
# DATA 5hBYqGG/kzwet9VwSOxSkr0a+WgImQIgSR2gik0h6/wEUY07Bn2sptYWWApd25Cy67Vh97RPDAgZIq06iww8WA/36YSWGsfIbFBs
# DATA QfXfCxEPMY+0Ejmzr3URtHcvYc5nFVyJS549MXmzmbPMTKzVlVQDjrN0yUum7rwxZbwHwgsgH32I0tnY2xYBG722WswHYE047Q+H
# DATA YySgtBU6G5i9BRBxMYPiGi6m+VB1J4fCv5dcAoJbG7TTdYA87s4StaFUwaAl/XHY0KyczCrCnRCIUEWd6Xb/8VAd2LNzNZIPD8Bf
# DATA AvdQAZF9fzjeJrIUJbcAgTnooC5RUt7goT5QJ/127zy7I8F8VbfoKWBiqlUgm7ytwjZ1aboPx4EH0FQDUEfhBACVVFUry8lG0umd
# DATA nhJWKOrLERNSkZyP1Y63ZBVSm2SKjMFZ1Fu4liyvJDPHosN9U1uX/kLDMd3lsBfgBV8B/B7pZkPeA+IGxPP1Om8l0ahzXiz9Lzw5
# DATA kvRryg911eVozImR8+IwPmWTmCa4nEU95o62tc3CkzjnfsfdSh1A9rFG+bcwwVJnqpZGEWkNbtseP35CyQsbgIWt54fmhWoHYDF1
# DATA bhQbculuyshMDomzBGRqTC5dIp73vRpV9T3SfL5XI3b3vVo26oNcV0sBzzV57z1Ij/OdRvIunPFA5au42NEEEgDCfiwZ3hihatqj
# DATA 0Qqq1GmI2YpmrPmj6uhxWq5Rb/Yel0uX0fhRNYgBYXUd4Masm3lSF2FNJv2tQMaoerJemVPPIcHbPuj1FW9cV6SntQqgpL1Ov+u9
# DATA ukGvgvpmQJUoQzqNXLVeyutWuZZ1ATdzrz1uqy1F0cGUXb0M05tiWNoJ0DS3JaCgkC5H7XbFDUSi9rFpKc+UeK3lVtU0xsVA8jmQ
# DATA e+xQoxieHpCZ3l8QowMsErAiRN4SJ8dyeCDKJX5WRIjlPFkj+8HDuweb+9t7h9u7O63D3e9u7bQePty+5xaHtNFkiK8E8OEF1e1v
# DATA PVRdxkqtgrMGHEWJOC51jjzcc9LF01uOBBSf4pTqA4jHTFHXWpemMg8g9MWv4BHCkYGN3IR0/5UAcUCD2a8xzZ8Nkg4CvuNa4b99
# DATA 8fdoc4tDnfnwHDUMfdBz96w32UQjdrKmriUxUoa94rEyIf4GOojhcSqRtEMnHK72ISXsubRboBLbDRUtJ8/uLP0B9D8te/pfqyq4
# DATA WP+z9s6tm77+98b6u/+p//lD6X/3kI+ya6+9WDFnAqhZ1blFiSJQnzhSVrejJDBMrMVWHqCUt27qX6AI0n8PsyVENQZfnX7vWJuF
# DATA wEtAFxl39V9g3jN/G3B7/WTSPR+BfEcVTsfqSjqmyCNdK7hkwGW9ZKqmXKocs0wuU+itih7FpME97SyCpaeh8+zvnbv3dze/W7a5
# DATA wgAyr0OJwjoQ9soJYihbmLArErYwAuwBsjC999KOCIAtKFQ7aG0f7G99UJLotA5crc7JB8kmYtkXrLGwlG7vfG/j/vY9vlUg6NsF
# DATA dPFwHQnHRzcEbDHDQ1+u4lSpC7yrnpbKsyh+7uq775bn9cj2pPUAbqu7W629/e3vbRxuOSDPeDXxhNrkGu/4yTWMQ9yS46hNK4//
# DATA dXK74BPeItHCTtIE4RKAb9EVAZeibz4IF2LOImh0eNqutcD9jzuttzH50xBepZb9jQ9LbndtSd1jCs9i5HIegf4Ng1hfvXkbk8E9
# DATA eoSJQmRZCEYbjjulkzLow27AI/6puPS19XcpCkt+VV5kOvY2drbuEze1RLnH0fNDppHBQCnuCEgE7elkGHF80JNJQCQ+GgpKlD6Y
# DATA kczrwLNZulxeZucDHb2HEQvozeBE7M2Ck2ur47m+RmKH+GwpyrNxX8/Vzsb3Nrbvb9x1jjHPW0bBh7JVTp9+0J1MOGW6aZ9fmeTG
# DATA fm0G8hrJg8Q+M83pRN9MIkqYqRrxTMa9DkbTpgNwByw7eNbYBilE/d62z7vkZApA7HCqIWeuP9O6f7F8EOnRRvXP2tW/AHxm+2er
# DATA Vm0q+qU26iwlxd6VJn1n6/Cj3f3v5ky+3Z5JCkGt9ZUVnRvc5ngCfDveouhEpX9IhzUzGbxAwO/v7e6j2y3FQRtnSuk5JNo3f0I+
# DATA AOyHPMcUaIhxt9xH/QrrUvepqkLfqpY06GOo3tRQcpPrrSpDwAwM8zVkBorCVsA5UM/gt9bN6d8aFk///uG0Szk+4MfpuP0YmQ9T
# DATA WF25plWEg6XW8CVc/oo2rF6H5LgDe6Ohx2IiWnm3FdX94eHh3gHXvL/1Xx9u72/dS51bx+hsx3ZbV3TVitLv7e/e3QIyptgs0lvo
# DATA ZKhKmNiYTs6GY5ZJ60l6VwnUiswgDpIv/n208b2t1sbeNt00SrxAB+doKTMTjL33EWDvmR1MiinuxVH6p1UlvTxtjzvdDvyFblyp
# DATA Ok+1VfV/a+mdeMm98VBR62ZiZhWkJU9rCVsdGTRoj8bePsYVRQl9A/7eJJyePkTtVkwOs4w0qBD6TQIaflfD/0K526BVVRK5Vg2x
# DATA ag2V61nX6NdOu0A45swRY6Uq8skDBeRm8kCupyj6qk0Juuh2v07doB+khUPDlm64NvxY25N4/1BMR/sEOkB6BVC7ApPXWAWUgOng
# DATA 46xx1IQXQIap2yUaDr5Fi4yu/njYuVCTCZ+/3cDXbMq60zstwdPv3FzGXA3wn/KlM2l3Iv3SFauezagvtREk17s7BYVtDfjzEj5X
# DATA wvDMTDO6izXQS4wyuHJx9fZE8cFUUbk2GZJeC7k5xczZ6SLfzU8+0Zpa/P1Go5EO0bKMljoqVDNL6pU2L8Rn0akXQ1wyZ9atQr2Y
# DATA aRjs5PKkr86g3ny4H2Hss6USbu5SufEds5m1sbtBy4aUfaU96q2QMXzFGMPLd9TAS9x//VS7ZsIIWDVdjgzAwDXc0c2yATxsNc9U
# DATA Lr5V1WeNjfG4fVHrZfgvR3Zn5fe0YZ3/rfG/6lvV+Tfcj6Cecqy7skn1GZQ7Wm2+RxrxhXu8kr6NoYXdh/vbmzo4QFfG2nVFcMql
# DATA slFZqXXx9VVCl0Q+igLmywDzPgccLqOdglK/I1dEQlr+nJ5GNVN4OVQSVQaxvSC5AGUsIV2YbQAhiCXYISZG8XRfasp8tVVj7Q5Q
# DATA GfRfQpFBFTjuljgywcoBLMDwpaPoCoUOV7SDFbNE+RJUKGRwG1LCwEdFl+Xexgdbre0H8N+Qn6I03Cz61w67INi3xxf3dKhHicAa
# DATA IJGizvmFOwKHXCUR/HTYVwTaAQfXIUf0qsyhzFolBlFStsPMmJEKFLGb08h90JDsE+lII/cvlnLUqDGWvcQr4aRIuQ7jHmD7oy0s
# DATA Unm+LELiv89l85+C9aeCXLfNchfLG4Kby+bqayLKTfcEU51ChFqVMZTRTXrwpGx25hFU2dSIW1Ac/ouskoe3EXjSY8vguDhANkKM
# DATA RAk0amHHJTMQK62UF+s8AzVXq4RBV62OlPSBok6XMeokDhX1Ih8cNG8O8LlaUNxgqZ0EPnLRudC+4sYVXDqNi/yRB+ZP3zk878jC
# DATA rt/Y3Nw6OGi9r04ssLeUvwzldCI7oCe0CCCYZiCP+HCLimTt012rvlf0uNsBHfsTzKTOc0LaxztJdtYek/dHQrkWFAW6EPkhgfoJ
# DATA R3TKNgMSxJLNIheH5uHsTC4UDzu7K+Y7dvjTuhhZGjn3qgAOeLak0yZAXbZTQHIwZU5W0hFR1A0JRIrf8rgJDkjjNUQrGk7OAFk6
# DATA px43eQzL8pUEP7L5KeTE1KAmAPbWQv4bJuGgnisHRAJ7wRhVBLlxmeJSqcm4nM2WTJJzGFDdS/B3lApBGAWGy+VlTYp1HL2UlTmn
# DATA m86KYT4FTcPyMi3fLCIsi6nTvsFuxQQxcZmiw5Tqut7QKYxd/YZ/ZpUk2DYV3jP2qvTlRvVM9prftyj70vwjqO5LrYd4ACG5D3cO
# DATA Hu6BesDImqEmCFKOSNAl/ZZIv/kI491iyp6KxbTVn8ptEQZMUV4RuBqIe6aRglYHNYX6+CNOpL3AAVjR0fJAh6SeyVxKokX98gjC
# DATA uHTL9rKi504H3mh49GfB6d7c3Xn//vbmYWSa5exipNqlutsmoOjoq71C+WSp+br+Rsx7ezJpA/UCGIVwZyBgcMq1e5k8xTzoSngK
# DATA 3JHpl2E/Z0WBaKJj4EBbgppR0FPfZqWjZdsmTHK5HJxmMwQM9+LSjsMIQrQQfWg6CYOQ4JfwTUX7AHLkX33JpV5mc1LuF96Zgrao
# DATA tYBUb2ivqh3fusmWA/zuKKVIB8gK5FkUCAqbvA9RacYfEE1o5vCK1Cdos6I/wLPdDKrj3IJ/MP9/jup87WFAxfbf9fWb79707L/r
# DATA N//T//8PZv89uBicKNl7AMZCCE4hTxvX85hSb8MZassEDeSCZ1Gkkb9Chg/TYjybCOsuP+EEf9oYe3oymPT1D4CnU1/onyba97Xa
# DATA kEHgv461+Ltb3wcF5cHDu629h3cVoW/d232wsb2TLm0cHGx/sPNga+cQIx+QEYEsC+P0z0vv1cnd4yh5NGm+XX4v+BxfLDdqy9+A
# DATA 9NPd2gOw6J3021mW3MPjSFeNvXUMvraaFyKIg+H4HJyRmGLl2vr48pViOJFGtvLR18l3knfW1smvkp2yIJnlo+zRo2++99ajZ6ur
# DATA 1UfP1k4fPXv3tJkyCQuseLLrKQ20xap1vh49MwLTaGGPoCehMULEPecq5Re0JTDYB5kLQESpJDdv3oiaJ64+QPiSRmgqqZEeqpT2
# DATA OoN2au6Tcq0PWQ/ZNO1I507AO/9ZguqcqF+7OQR+CuyP8NpetPegEoA9gW2B1fcdtOamNZMmGsenHsG/amAdSsoDLpGQYAvzidq/
# DATA 0ODnJdUBFXW/X/KypqoTs/pMe8O+/Qn8pc5NClBF40mZRYmx6YFwxAxqR/yMsIUjtvuplvhPtPrdWpvpN+X3FmrvGrueU+NpW9VR
# DATA vbrW1NuY8iTpiUTLFe5+/U6vS1+7qsCy3FylZamlWriC3yQC2pQ7zvhXeOAb1T9Tg621/lu1+bZ6tOI/Ky/TtEM2pKuPlBk43CVk
# DATA FBEON9qlZkRBIw7fJrMHYuOSmkWyA+pc2gZRBAgBPFmkz0o62ngfRPbDD9PI8XsdbkB8RgFYZWc4eR8QWLyjCt41PBP1mAOrcXIw
# DATA Y/la/YtKV3cwWl2/yZm95dsBQCTBaqyF+UBtqav7Dq2vRwWzxdYXE5e1J23fZ0gM4e1krSwPGxQvu8O83t7i9YT61GH4E48jgsPR
# DATA B/0heaa4x0H7qtRMwDMQ1o/TOd5qH+3rTbm5v7VxOG/HVmQ+89j+ar+ds78ibmm5m81spVdbxUCNjbwkxNCcfMxtVvgZjK219adq
# DATA uOL3zt1AJXoXvu0NHm/vekc0p38P9+5tHG617j48+L6j6dSfXPS6/Q7TPV5tubbaKwmhOMAlKSvhZix0TDJbU2RYt6koCJiadCUI
# DATA 2W0L5aRWyp/2nd3D1oONnY0PjOrI6AsLcudKcm2zMwc0275yCLdtwSkTh1y7yo4B/gtT78bgGmk1EPdJlHEhsZYkeZQKJqiYMYA0
# DATA 17GWfLuBpANfluHX2q089sSrixl0uLwjjAtd0OiotFZZW79tHJVczytsNtagaIzHm9d1fo2dv33N/aLzHV/aZdVps+rECIQvBFuA
# DATA cHWzJQv4hnXNbOJk7CIlOMPOSvYXyaasnsr4l4BhRwoIi0E6FwcVL4XApCItKQ8HvRiwTvEcbu4+2Ns98NS2EcoSSnfR1NHlqLrv
# DATA is1bdgiW8wgmC/R1eI25U2Rf0u8l35RgNmcU+T9qecER4Rb3bZZ441C5mEHRyxYX5uCOZczGc3DUjDXleM1yPVHsL7+lI/PDrRcm
# DATA hVBA0P0uSJks64rs5xJ+e0SA2U1P3YvvnATe+CS08tCa6iaa+kToBw4jRKmeFSd0Y/169EAzQBaSkaknTybvIm0pVH1AaZ8Om1Fr
# DATA 4MntZR6gmM8sI9XE+UfdtFXSYGAkGnfRc8ZT6padC4wryW9FQ8dxwSMlz4FXCUuJDUXN1spHa03H+Vxjwx3VQfgDT8U3Vbk30zfF
# DATA PvrhdIisARVclZk/OvoxDqSEJSuaZSXteq9vPoXyiqGtmy6wqzREK66yeiWVZAXefTtBsbKENWkxEn7I/LvpW2l5YcLiCody5qib
# DATA a3XVbjOisNDFQBmFk6ruQdSlvaWVTxjRiO8aa2WcfDHX0kmLt5VO5lCatw2tpwv2wG5HOjPh1dV01zfco9oQWuE9nGuSEKmTtXCk
# DATA PaqCExz2jwQWnWrSaZ2vMltfjeyRAZJtMcEmmRJSGAun+pgBtoCeC78S1zQbtnSagPYVFdDQZj3qJqHngcocqS+a1lNJJllx7nf9
# DATA la9EXbritc5bUTdG2kTUazDn/LiL+kDWcdc4i0F5Kb4vOGOrsz1Ea1SdBkcwuRK0ghEQJ45T0NWCxrTktYnbo0ZVED3QFFXDNBJd
# DATA OE7Pe1mG/j7OYbpMcbCKheNBK0GFQhfVI+7ZWfeZbkBnCqTyvc5Mn0Nrd+CwFcL0aGAIACNpgSTEsgYKTlZasDJqKDQ7skrO6eaw
# DATA AiOS2XwhhGzWuAKhkPSTBhGefTGB1EKgc5HMHFYizNVZd8IPUUzSS4BOUiOEPNnXazCLaVvo26OwdBOqow4d2XVsLs4xfrix88FW
# DATA jLDbE6Ubpz5TliXvWbj7HHb3fNgBXLmO5f+vTU6LSKlh9B12dinPMaaAOF6TqxWd1V9HN9JcTvdKRNpnhYtocYwea9kxh6XO73r+
# DATA TZk/ltpoOCqp5v1QoYBrjnr7hfXhRaH5kNzyJrOY74BElQTfsU8BCoyd6fkoMy5v3UEGzkTt7KTXI8V3BdM8DyaNdZ1QdwG3RW4A
# DATA iTnM/3GaBg4KsYsUz8AbriRB3Ith9ASrzPY/aCxnGXN3H3dQVjY9xqAcrC1Yezr1XnHYZmpKGsbwx18vFe0kQ0euNSDuN/xjwnDA
# DATA JZeXRv0TdCq2auDGBVWYG/kNkpjDRjVtM7Kz850v8evSi1wsJvOVVijqzN6sH1QyZCwVRhUGBmZydI6/WSrDbe50hOpxNXf07NVU
# DATA ulwvZS0AFXFjdfguwI5QpoaMNEI5jjU2/9R5e9A7BS6EM1NZD8Mjp3vRZFM6kRA+tGmuOZUVpuSTepDoveX58doEVh4nJioqS5Zp
# DATA oUZmAcOOva2Ya647mJ4j2GlJbxo7dU0vc9YEXaCF4iPUrtsGSvbSLccbirCsYvvETIC4srCPxLjjB/QqvIhoNGc+c9qI76xSfE8w
# DATA YDfXHmgUloprt5M5/0teKp0tzdVbaiNGO+tu4Z8QBxisod4dY3BDzxTfzHVedakIlUlQrnoer+DNfPFFj7bc6YBU/UtXv9hjc7vw
# DATA 4ljjqiCqRgxYduSF/2hI3wv4/533HjO+32t1ASz2/7uxtnbjlo//sra++p/+f3+I/731xso0G68c9wYrEDQxupicDQc3IEpsdwSZ
# DATA 15PpSO2JThdCR9sDC5cZ4JI60JGAxel5BbI7XXv8GP3tloxX4OiCvPFAkwEnV3vi6d8UyPsXIA2+shtgAB8DmQg0kgx4+c33C5Re
# DATA hEvXTjgVhaLpdGlK1Y1mY/yJ0vXbx4rshUgImwyAbFVp97GkE/MlrbZUkbEa1yhgSUuFOv1KDbyy1UK21KcEtKABy+DtwtWIT60s
# DATA POdTHSphPw1syVIHzfH9YogNCPp3wEjO2mPEI1k3eCT4REKSqAdwJ9o0Y1qk1UN2Jdx8e4BBb5CZbZykNjwc37Y7H4+C2y7nN64N
# DATA TgsuMkmkZHViOA22W1TcqTc2YTYAqV80mdqETc8LZkXbfU6EMq0h1GrcpYZJzsWDbfC/lVjMnTHON1gdh8FUD9XJbMAplBJMWePk
# DATA 6HCadr+n2KTMHjQ/6CzjiEoMvLw2WAo9NrG0OpzilY6z1sJi4iDUVWv/UUoipKMdrKyzXNKjYcQQGrw2dkIslFfi3s4BgKyIIiEe
# DATA ThEWS2X+yD5kp1jOFmihZK9AH+irppH+tWqZUqmR07rjFO1INa/DBTkX9OTSAz2Z/WFBTxZwJKRnJdv1iuuszJuqYl2lwSR48+YN
# DATA b8AN63eNU3V7tZxvPTGZiHKoBa0f5ambDCmzcAn/K7YUKMyeqBkAQu2e1gqHcRfj5lSi77EV6jmHOzTcjeQekVjAJ25KQzp10ESO
# DATA pdoahzjiopFcOu2pzmF0Gp1rDnbTYbYcfKBafH9/d+ewtbVzTz9jE+8T7CekZZ/5PRpwk0GfjI0MWLqWiBJE+8P1yeCSF3SYdXm+
# DATA r0FRAW1ecWYYlF9y+knNvJXcQ5KhMdEy9v1qn4yHWZZghgIT7G1C2CZDBDw/Qd9KzL3Ilf0AYPjhlf6EY20Jg0A9pyCY4y4wvuTL
# DATA 2SF89Pb5ce/xdDjNOC6Xo2gz9mSGr7SGUk4GBMjjCywvnjV4P1LAe1w4Zkj+kojFL4l6rrxmef/D/uFuOiInBv9i5ThjfamSzcR2
# DATA KrJuMSuLCTy2B17vZTO7BQfrNI5K4Lpem1EwDfVHwtQnHhMaqL/tKVPLZZCvTCNAugA060k+dleUdJuD6YyRPUs1nHoWUMpMkMoG
# DATA 2aQJ778FaQAcv3t1Wqb9iVUCZl0CVlTdtEZqi15HZjRuRSbIA1zQBRibbcwg6HCdf4Jg2qaq4dMBGvywytqYC9XJpWa1SXkcz07G
# DATA td5wpT+cgB/1ig0XDuBgHCcXMQm0laGtOSs77ioGpMdylNupFepUdc14/tTdsaAmzXxuWISwk07Ic/h6Nn/3QeWL35/oNmZ/+Hpm
# DATA u8Rz9/2kew4OajEZ1osgLwXgAxqPQMuN5oEJnKdAcmgjNA7rN7CQ0AJPL2xg380QVKedDl6K3imDza/VqlCb4/HA3hhUCqOZG31F
# DATA fzptbLiuR1TQ/bLxAieoEAg2Vmw35LFEbqQhcDfUT/9Mqkelo2XxUZMMYQ2KHT9pjyCLWGs4nYym+uGEcKcaa7dXDdHkcdKwQBFq
# DATA J0ikDuUYf2J/HZkCmha2NtjDOgdTko5QimSMTPhzivwvA6FkkyH9RDgUDYaCEC8zsLswdIrwNqXEM+j7hb2m7IsY7ySAeLrtjID7
# DATA S27CoxTyu01PzhIhMUDCx5efvvgMcJKSF1+9/PHLH2GWSEgq+dnLn0DOx+TFZzpjZOpBzYML/ccDRSqS034bR8wITj/CTL3MdfDH
# DATA GvoJgZk+x2b/5cWXAN9ErXiJJsO2IFMIuN8MAfZk0Ot2sEEBD5W8+JX6/veYvvJ/AIh5WMdme8AQowBipHkc7min3T1H81jKDxDO
# DATA SuJPfRGrk2lEm12dhKoHv/81pjb+FBNr/hjQrtTMxPN5qheRiS57K2t2I9plYTNShkLa/2TIoB2gtiW9MuJwb6A3kX4EG43huCT4
# DATA lp6AL/O6+vNEbp0Xz1M/B6gWKMIssqXT9MU/UIZnNR2fv3iuWytdmiM3K/N2+RUifEHH/hozQT8HYPwK9erz5DI4vrM6PITxz2qJ
# DATA TDOtM85/pv75DD8GZDBIaPryx64zrj1cilhYKoVOIkBwSoTRgyoW6ZoVxIKEkDKes1YsKAQMvaEGD+uz5dqDkzNXYuTZhtUtwfQ+
# DATA x6ywkDn7n+ejo+VsdEeFduT7y4ycLum4Z5c6kh4Mg9ZwLtwAknJTzoIpqnVoOrQRXpTKjqkuUK+5w/+fTlrbfzUU6JUmgneHgbSq
# DATA JHo4jGZF577KKpyo3tO7FT1SIiqxm4YU6FYPq647yMKN04FAT3o6COJyjK6sR2n1lL+Ed+VmU2OFsPWC4pRaZA1kaCxUFvIjMvC2
# DATA yAvRZLnmXKex+1k11u92Rw1C5oY/LYqVPCTW8BDLsgCRdPbXUi5Qte09HyTitThMSVb+QFvwbLxSGKIFJyw4rMg9cVmzYrakeVR3
# DATA OD5/jxcGT2HqlEZIXMpLeUE2LrdEG4Yh0NJl2pKa+ahWB8MqqgZGmK7APAOIMKRDmM+VHp+CayLeWewhAisMbJdvrPDYuCXPN89x
# DATA zfZCb1DWyT2zf6dO6i/5cNIl6Z7WSEKTRRiWJYmJj1TUbvNyjXIdwG3qouHPg5h3vGLBYlfrqB0Pf7BXW9lXmUcA1PjPplP0iDPJ
# DATA N7VI5bxFV7/0eNrrA/Nj3f3s11eEA3M1eD4g2HyINtswaal1m17FfUdpDzX3hjUj1mkVdhWyjan6I1LgbMlx38KFFDSqHHpuIbwl
# DATA 6Ka12RQzD2rLaW06OcElP4UnpfSb3//m+Tc7h9/88JsPvnnwZ+TbFvX6OqrfZkXTFVyzEPEh0R5h4JBFUah41mge2aWCZo8YDBHE
# DATA Gp2TSuJA69f1IYSoZBnMWU/MVpsthR4h2LmK6UF5qciRjPpNW187ky32pTZXuN/SL6Z3WmvjzJR5KmbLbUMkz5OH72k7a40JnlNV
# DATA aFVgGtdT5EowgnkLQxU8IktSXLXaJgGtWv3htIfpc818a2LpBzXJei3hsx2IEHYHMdNKjrImQZylRsUdr4MwmgtbygEZbJ0YPCEQ
# DATA MetTLpJI2P4bN/ZORaQ8ELiwmskNTimb+yW+JWsNWnXPeVl2RkLOhliZsjseWmaOX2TOhnHdqGy1edaTCD5szAQiWH1dY30pTC9X
# DATA c9CHI4MiZaUBH+aJExqQer4uxd7kZAihqa3P9RsV4/UOrqkkAhIS7OU5rHKgK8phhCNaMsvn2iyczbmMkT7AemqCeYAR9CYt7rQm
# DATA kWLf0BSFrHE5trISn8+bN7QcqFJPonxgxeV6sRvlQIoyFb2VHEyGoxHCkD3WUK8ZPaolG4mmDpipqpepPnP6VjTdKGE3QVRY7a+k
# DATA ZvAZ2ljv3a0Fa0udNiotZCw7XU0q1Q/NpERwfpfVzqh2KEJXUi1UZB7R5+jSAhJSSGWlmlN8Hjp2tlAZAlE1pVur5XhEdITsm6Fd
# DATA k/A7TbxWWu/fKTRjl2F801m33cfw6OJr4EMsJp9AkWkW9xde7EohSx13APShRLdSenLhK+zz6s+zj6BHNNlUAJAtny4HFNlysFgH
# DATA UtX5XrMsnfyjUV2CnMHKS0SvBy3C70B7Ruqlr1iI+RXqzhZK2DhHJ5HGjYHH6uh+HFsmvfYNdTYHetYx4q1w/fTKkw67owQj0kYr
# DATA OtTJWzRvkn4xV16z4P8v/xqUeYlUPb749cufJC/+GYQ6fMRg/9EZQA1DaX0ROPOIbujHqJb9zYuvQB0Imtnfgk72K9RHf84D+Jsr
# DATA rUyO6L8A+Y7fwa1++wJSZJD24/UrLZhyLC9r5t1e0e9zZEhsSDOXYwpZB6lWwr8dx5ccR3xdBWO9mmuXLtnFr1QLe+tGxXj8/L/h
# DATA jUXu9KSJA9mtZDCtxhmm5tHewLWN8eMpkLM9fFPSVkQ19karpa6NVqssvgQbXqvNn5RSo0YnHH3QNzRgm2QnQ0bazxS7ok1SqBDU
# DATA fASpFbv9DqkRKS6K2Ce2e8IvMquREYtVSwQmg/YubchGEpuaCKIqyADwUyddQdMusk1oAMMMJ9NxX6rUosOromSOvSyYhGoV41Ig
# DATA vO5i1G2YjFxosWvob/Af+CqzYhv8qgnrn6KkZu7yeGb6BqelIv0PHAqAhcirSt3mHneHL4V52XVMwB2t5ZR4H3lNBR9OS+/TIfyU
# DATA lsvhpfA5zpmJQGRt/Co4uIrX30bfV67ed88ILk7fAkYX5e/QAqTI/pXobFQbTAOy1MYUzFUFA2dEvT+yw2oWLS1nN5Q0zblttF5d
# DATA FqaqSaDDv1mSw78dDTs+MbIE/jK6dqNFt7unpU4J2M/VorXQsNBq4Q5otYCotFppxLeTyE2uG6JJffHd7sX8xBegp+968Kpj8ONJ
# DATA X/wvvMq/oNt7QYuLY+YDw+2dJGKTZJ1uhSyPnAQI81bDjf7Vy7+BRqAysljCJf+vUDu0X0vUTnzOvYHMQ9j0Z/jtj9BUhjyc4gmQ
# DATA pask6rMfUSYjUEb/lUjKjT37EvYuGouwTYB4BWmzAfEPZJUXW/GCcg6V1v7PiJD6P/t/jsof5ejXDv9eHP+1tnpzfW3Vx39f/8/4
# DATA r3/r+K99C/OOiTq6Y0LgIO1+EP+V3VF3p6Llx70JpOLSTg7MjGaLxYCFqPE6e2KL/RPiSPHXjwjD7Iv/7uPDrmRGxj7G4zotFr9V
# DATA vZnEbhXhvCeZuorjBc/sfA8AK3qTCzLg1h3IZzfGvZQ+Wk1rPxiCAz1ET4Oc9bH2aSePdqn1TIVDkba7lssW2ciJkz+qr99sGlzp
# DATA k+EYEFQtDBAGoVuPVkrrJuAQDL5qYG3KUs0d00eFAKQyIwzjGuxvfbB9cLj//dTFd5LITlTv4/7wuJQua2xXxzNZe4REGr5K48Jj
# DATA wOEj3eBx3R4km0SlU2SBF0mb+wG0v7m7fy9MyAw1FULRmjULHTHJXT6ydAIad8mMAx5ZVxrtZG+eRyY0ymmLiJAQc1fumT3S1emG
# DATA 5oPuBiONZhQnV+Cn7SfdatQeSnAdUBCA9vmIRTv4UJEnyBPURDs3HP/2gPC6QNKaLTJGK0+80kCLJRXODTHo/RAhpATWK+5gCASA
# DATA yoQggkVl3iJ345IZxUGxpE/iMJZyTx/u7gJ85fdxUx+4blFUh47bZWnZxSDDK7TdqaKPuXWxHp4m5ENKZolzNF0w9dZhKEoe7T5r
# DATA n+gdq5PWERn2AMGLDoLZ9C3PuQzJkXweo20cZjgTbeefEhcsVJSO7A7b/FwI67zuOLKepg1sU4CzJKp3TlTQrHQpqIgDl5ZnAf3C
# DATA j6PRGcIm0etkwrji2DxyDCw6/qHsBigM1E7OKPXGLR3OHMlj366eQtDw5dp65dbNWRp3TISaFiXhm7s7hxvbO1v7gNm5tXO4614k
# DATA ZiNfxcazDB0gF341PaRGtPoHNR/Dp4TtZhdgJYfiYTBob7hSWDCmvjexInOauEpIySyMikV+A4mVQ7VEvEWOEcbejlcIlomExYCX
# DATA Pk2o0PDoOAKxUa26TCzFQjE+UXggUWUNctupzRDGJR2Z6poyhtOza0T0NVpNU14A6FnOO/covI/ItcwEjKcxNLnoGNmJMcfjeSkG
# DATA Z4MeJuykAP8wm5/NosCC9tBGLBJxw5RMmeLFJkdwrMMcKsVoPJwaT102JgtNdJQajfSI7CHL2A4PNSdaMepkTTOVM44glWiufTW4
# DATA 2gykA+bZASCTrGjouew18rgecJnX9jCr6Vyo6UDqqEMIQszLwpx3e1IqF2ElLpoypRTLmSJjTWlmyPceHgfl11ZXV8vlYvjE4gna
# DATA /UhdIfFcyTHv3wVyE5cXBHknYnfk8oFNx9WQw3QVQ4AOYTOfy6AqluYmS15IexzjYZaW7m99sLFJvCWlOT/4mu+/Ra9AjaHA5hgM
# DATA 1EU21QFS4KHkZJezmV0XuK3CmdAAwdPRCIXlOZ3I6ykdhdweuoC1c3t61XDTssGieNwVyprWuKvYPpAVtOdGXbsjap+OYg+8csjd
# DATA W7wA4742B6IgP/Dfc20zJmiM9gJrN96ZRW1ZzxMBh1CQqW6BCGejwGpJWyNhRmuOgsObLbyMDMMQjkR5adEWQODxUZkWZKStT6QN
# DATA cjKpit1Qp3KYKCdSwFxpi6ii/OvqVQWUr1k4uY5g8rqFEj8U/tS6EznMvDgo5FInXY62OwLDKg/4KTJFqqoFMAbc7Wx/veH1Ig7P
# DATA Y3mB0H9oXvfMGaCWex2Jx2XflheLVI/S+MVc464RkS4pqKeYxMvCPZ85PD7MsXcoF+nKPIkjkDauIGksLmU4ft5HYT6aK0ofoeQB
# DATA cyp+evSM8gqQNBEH3L6OKGEHZbWM49Jc4cKTOxcQLV5RrLiWSLGoOLGgKPH6xIhC4eA1yBhXly9y3BLt9lhaUBJZXAqJoIRIJAkr
# DATA cmD+C183bf3M1EtFSvMYd3DN63ayTcOOoSpzDl85e70QFhUzvbrLFtWC+LOuz5KZWNswpJYYV9t9ya1ZzdRCfJ+HM8L8iXbXwvyj
# DATA RewF7qYH2x/sbxxu7+60DnYf7m9upU6grXae4vCjEUHcWKKu1taWp0f+eklqP4I0GwQL5Rgt8XaDyq0enUu6ZkF+GOz0NxoLUO2c
# DATA CcDjZNK/Pdg+eLBxuPlhaEEE3Tq3r+gybm66YLRHGK0OIcIuvvr+g4pYemijEUCyQAtaTkRPQLa+6LZRB9qyphkH6yjM6EYfydTo
# DATA OYzQOnJBuEqLMK0k1d5z99OcVSflZWZzGPhjqQc8jmeBKq5z7mmAxG1kRN7a37qX5uOWLiI0+Ug4i8zawdb+97bNKXwLGYosUfc/
# DATA mr2qhAylLV90m2cQB6emIDkeD59mqLweTSdZbSngbI4igVXLsYPTDNJJxjSs8zNTX8OE7zMEOXeV1sKoBzpnHgM0txRPDpuAjkSI
# DATA tJoH4iEETTuSBZFtbca9Iz5P2FNmrPRvgmyRB4BzBSyFnEoeroiY5IaXM9b3/AfQPPrRlNcD9xXTOhftyI0Hd7c/eLj78ICW5HBj
# DATA /4Otw/RqOQLF2G2iwFUdCB/QLi/XFjIOVEWKEYT1SASh8QSwViR+hLLfzPjITIERVqwAtzeYnh8bdQZarJGOJAyMxhhs0PodAyui
# DATA EcFH3THgKGSIKYSIY3goMcgONEbGbA0eR5ht27Dk2ANue2GtxH8QZYRjCXwd2ghxrAK7omiMifxC8WowQxKUraZ4VQ2oPTkZiVKw
# DATA aseQL3Pw2ML27qnlU/I3ni1YXOgRF4JO8Z8ZQwc7hjnVWMUWAO8v2+kCcEpoUUKAcnaRpgb87J2edlE9s71naz+HeFAA60za2M9a
# DATA soM3hGLnYB+3B8JdEXKEdgGuMEokPB7SO99W+xIc77moeEIDkd/APPWBZkgd6YKpCN+RHtMhXqKHZ8OUDFkHW0z2UHyaS8O4gkvj
# DATA 88g6AePw6B0+W2sQiYVJ78K4uDwxfy4gldEBzNd6zF4PA/1WcqjopFkQOGDk5KPpql4+uK+edJH0jrOz3ggQawcEd6QFrQ7jTwaW
# DATA pdhtIWc1emfYArGbY0Gsr9B4EMnwDmEebQg3bk2GuFvEVljQTGAPxTWQRpdycDyN7YeNPTXf+mOSv8dT0ucltG+Qn5Z4Mhx7tkrT
# DATA lzeuaF/yq/L4bIsIng8ymuNZWC4X0booI8oEU+/uMmQXvoZ3He28COT+PGB8fujC7ISZzWRWCdrB9FgGr9KjEv1D2VGpVzJXshsy
# DATA tYg/MUD2IJ2GvFHk7St9E1+B3bOj0GyedoQTrrvyjtKcSLiWRSgAvhzno78w0CS1UnBsF7SCvJKpjRu9BggBgcywBZxEKenU6VuG
# DATA tId5eLmGQk8gpAdpSjU3C8+DIxRGwZNfrXB9FUJXTh/ok1jDlg3TzhEVNMlGfHnnXfnaS1Q4mwXGDYsU4WxWF66X64lizwgON/gI
# DATA VWvCyTMf+AFT69qC/Bg8RHTmY3f0fOdEezT/5pnrT7KQF4kdZcV0KJ0O2k/avX77mDBg0jx99GsRJ/PV1NQvTJ5IHUw5dlw9Oh4O
# DATA +9I/3YgkBfVRcHWdxnlUVwJe0/Nfx1ptN+2romqt/0/utp9FQFKNFN3uXDBijQFZXteQK4AlwTl38Yo4Hyp6Nxz0TjArN5cnyK4z
# DATA ALQMCn3bVBED0YoflysfFdfP35UOPc/+/S4aeO378MCULbcxtqVhI7nAGsH3BScTavPAVKLQ+DlDcuoJ++Ge+4JuuMAiReTYYoFq
# DATA pI5C9erGve8bHyG+VR0Ftol2tzprGwBvmTuEYZDw2l3xSFOz/lCJ04vrq3f3tsga4qqtF9OzWzAKp8e6tzk9onjqIs4EQClc5sTj
# DATA SJpug4gRQO1p4ApsFCtQlz2yN2urqwYQ42TYH44j1Uo7sdhyRX01vWAsDQO+EemjXjCt8ymHrFY4m280eMUlo6Wpkt5VJuhC3tJC
# DATA 1TdREgtp+kCDp1fXgJui0XYCoSiArtibqHKsDgSkLDAhdkeg8cHMpVrZN48/+HeLAetCv1oM0xiqqzSqREQuXXiunYXNHKAtONje
# DATA +UDDt6Lm3uj75FZkddcuxjGC5arT7oORiNlPMA0ioiSuE4e1ZLVEa3UnZ+2J0CvA0nONGDMKu4BUEo9BFYZ6hsnTYVVvCJvRUdta
# DATA 2joZDm6JGuNadjoXCNWcqysAWWlTFyNWRfWqRQhsDQDBVO9Sza/SCjhDolA2I5S7wYWCBaDrpmsy3GdIzy8Dyza36LrKoHuT7mUk
# DATA nNB5Z1UBdGw8tkmK1Oo80UFr+EKoEg2Ty0cDOs2YnZfnJJAn6zdW11YfDWYy6/j5UAmllFyJBnvEw2pSV56o7X/uzB0eSFDcc4Ii
# DATA 6StbwWx97MpLFQCwDN+IoGNNcxMQcXnGyMEvCLOQJ8ytFbc717vSnZysYLkVu0FIRQfbgYZYlilizK6xf4PrCg3LXUILf4zBxIp2
# DATA NXQaYGhcr4slt6ZGveSvZZPZncAnXTPnXMAC84Ado21TymnCoNsjv2XaZl2oIWtRuvNZ2cuSxV86wgzmRmqfa28oSbgi2btzKNiH
# DATA Gwete1t7Wzv3tnYONT3T2pwFIKPzMtRTbnoRNViNox3Hs9RfAavYyKpXgCH24YabNkoVl8suVV1of7f4GoUcYdN2n8G76DoH6EpF
# DATA vYdK5lQC3B32WNK3ZKJmSPqrv+Vm8EiYg0jOIVMZKVcyEAMUIW8PEjGJeA9bpbGhE9DrJkqAp8Zp6kjkIZLrALMO1TRzq9EMDdSS
# DATA Dobp1RGWLepQ8WeLl58Px5z7pQvI7CLC0b2bG5K7mBrwGrG95PDf7reoA35EruhWmSw45rfxUPTyKJkaTaB9ToivDe8tqs7Kq5ew
# DATA K+oyNpfPmQ3KhRKzcuz8zNgfDEBNOw6s9b89Am/uFlkYkdeSY8wl6EGdlAS4UhxzzIPtzTkdBVtZw/pi0tDUZPDutthRywcWNOtg
# DATA YjXI86vTnnSDTRjtTsyfTNJdi8fItQbGuGDRo1rscPpZPl4OrsIr1kPpq1B8wJDxsEK+uRfY8TLdWmT3lxcyPO5vPdhVsjtqFTZ3
# DATA d97f3n+w5YFvuIe77rmO03l372j3C08Jehrng2Le4ZitMkDKaDpH2fCv2rbJaS4LISj8HpmPkf3WhnD9lHNnPu7m9JGM6ws2JTpn
# DATA SUM5H59UlNckp1yYWMWbvsCfOedoRGNlTdZYh2kBTEtPnkoVXzxumwfl3LharjGylcK+Q/Za4CVwY8sdLl6DQShkcpvRWQe9R9Fm
# DATA Di9ye1Wx12kelKu4IyuCKkngCgJLMQCfqOXW94DWF7N6PwL7CkE7REDj1HweHGz0LEsScpWpmHO+ff7iCq048+jV4+MX57AmkSZE
# DATA qemABO0gdoOEGRe9gAOJAoNXNJKqcJQ8Us43gVYHz0ad73MVj8SYq9i6OnJvYUiGRPUtRvSFmfRRfGUogd31xiICusTOgk6n+uoX
# DATA lLIepP0yhLGuv3ahkfLAOCxHvCA37npN+Xy52aKviAAmff5DVr3stsOKJgl3r73edTUiDiCGsGMgr5wyUmlh+XXpGkrZomTUcd5a
# DATA VphSW4XyXjvL2HFUbwgGC0SB50T9hplWv1Gfg3iCJ9o4kKllsNm0jTq5wD85iKkNPHIW8ssoX3VhfddsnW2Lba5OcMdip0LHfyfS
# DATA lVl1G6K/Uz8UhBzHBk/sPnGuGH7jzAM8o4gwiL/Ken/RTb6T3HrnnRu3ruKNvrXzPcELWadU8OTogSK6Xxqnfx4JA2+URGhAtfn2
# DATA o1rx7/I3KOFKkb4OYklqDwLEJOOw2XAcNuUyeQ6a7uVFGdNoX+t8YJsPDw5bBw/vHmzub+9hiND+1sODLR4bqEOoakU4Hg2MRe/V
# DATA wmHI7umFwMh4do5Lcnh2t3jZcsX6UZje+T+smWYB1SItYzwXXdSuUmRjZ4gJC6QpBZjCiXZOJ1oqhIneDxgv6xguEkhsqB17+/o+
# DATA fxT8+mpR1ItJmTkBcjlzEyJycGeOdEeaR9yBpgdB6Z4EJwxqQSSNOSNRMvLO1iYf5P/6cNtGOHE1LT6g4E6xoKNP1BlxOH4MkPUD
# DATA 66NP6Og1kRDAjSQJZhJG7cFUPOq8XXqv/qim/i1frlduoLOc2/Hyot/p8s4enUxH6lY5b49KmLHMq1t7xtZg56hrxCsdK7XQqtzb
# DATA /WhH7bB7W62793c3v2vWJJ6lLXebQHroBY4i0YZ48kn7Pi/95P/f3tc2t3Fdac5n/oqOPN4GJAAEKUpO4GAcioJlJhTJJSk7HhBB
# DATA gUCTRAwCGDQgiZG4FduTnaScSmpS+2mrZqZmd2s/K06cyHbs/AXyH+15u7fv7b7dACHKm8kIiUWgX+7rueeee16ek9KAZDVR3je1
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
# DATA M9dYRokR/gRdpJ/dTjQ3LlR61kvHi8ov/M2rz6vPq8+rz6vPq8+rz6vPq8+rz6vPq8+rz6vPq8+rz6vPq8+8n/8HcMe1awDYDgA=
# END_REMNACUST_HELPERS_V1
REMNACUST_INSTALLER_PAYLOAD_V1
if [[ $EUID == 0 ]]; then
    bash "$directory/installer.sh" "$@"
else
    sudo bash "$directory/installer.sh" "$@"
fi
