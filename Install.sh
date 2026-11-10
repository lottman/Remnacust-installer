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
HELPER_BUNDLE_SHA256='57f3bca5331fd0ae63b70b6e84c459a7d9e9ef141d8ec50eaca7bf12e92ccc1e'
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
# DATA m92mCwPdvjcCLecG7Oh12Kg3G/UCSIZRI+x3Y+i9E0edoNPv9be7263hNgy7HcIfIN9G2O1F28GoBxsojFuNeiOMgFxBAnb6BZBk
# DATA YHWtg6JVvF+HMOnt7QCWDOi/F3Zh1r24Wx92Ws1W3IffW53tIbDQZmMICA23A1i2TqfdaYbtCPZWbw0UgxCY2Ti9XAMNUFq/kFIb
# DATA 3eGoP+p04noQxUPAe297ewh8M2qF9aA7bPfjRqcDPGQY1YFU+/F2t9eud4POcNgIg7iRIxFS+AeSlJksbtft23aniIFE/agBjCFs
# DATA wP+6nXa7G7bbcacdjOJup1fvxCDMIqDkRieGTRpFzcZ23G/XG9utXrMR96McLMo0LgZhG3Z+0ZZp9tvASvt94FYxSJAY73wDvh50
# DATA t+NGvx+NesNu0I4bvag1gpWqA/Pvh60esP3+Nl0J58LA1UsHJM/X4aJRRCWwG9qdTqPVD8NOKwayBdbeqMfbDSCeVr3dDofAqUb9
# DATA ZrczqsfN+vaotR0DX2+FPbyJLs9LbbNrnbBrw+oWMvUmCtkYBg6DbisMmi2g2XYUgGTrdaO434F92wX53u62g34LhF0XOF/cjCJ4
# DATA KWx01gMyMPdYrkENMIUiku3XG0E9Dra3G8Gw3W40t4HbNqJOA37od4ZhAzACJDrcBv7SAL0pHNW7YRdUkGa9vY1UfA9IUYom9jpe
# DATA D1u0aAe1+/UOoCMehkC/3QjEcLMRjFrASELYxF1AW79b7wJ0IKm7DWB8CHXcbvSaddhH9yyVKWC4juc2t/vtIpACkDtNUONHYa8N
# DATA 26Tdge3R7uJdh4A7EIbAg4I+LBhQMahSvWYrGAUgQ2AOQa/RvQ+k2T3CsNVp1Iv29TbQZbvVCoHVB512Hdaj3hmBpGvhXgZdIopR
# DATA CYhboMOCxtBqgZo0rHe2Q9BS4K1mwwVnMV4rjNvb3SK20uj3gChA3oJsHTaaHSCbMAxbgAYQS716ONoGDRIIZNSOmnEAmz+ClrDn
# DATA w2G33mvl6GU5uhlcLoN5tI7TAjkU6SQjkK+ovndC2ERBYwTzi0CT7TbCBihKoxGs1XYEvCRuguYOYgdYUAcw1oB91alv55RGdhJt
# DATA wlqs1wk6oIEXAFLvh8GwFXVgrBDIJGoEHeAYzVGn2Q+AebS6AWClOQTCqYNi0AIKjkFV60UNEJKwUorBeQLMBt/shMRIX6/54l2i
# DATA wlqz1ujAC3fe9/7w74Psf6OA/xvc/90F7Sxv/4Mq8gf7/9+2/u9nWCsimPrq0MVcEt6k/C+WDkomkyVpHFU/HY2oRhrTkx+meI/g
# DATA fXV/+XpO9S2ez6ep+nL5s2SmPuNFN+NkqL4m6e9eHPhquUjGuj5wMEc/hf4aT2b2dy4ZjPkJJ3v7Z3jrRZHDrOQ9Oz4+OzjB5IzS
# DATA N9Pv+ycHL4729l+dng2+OHj+8uDkdPBl4xtodnD0lNp834dPg3Wt9o72vzg+oRvNyVWLJ8Tmw43yp5PKn3PLwWevjp4+PxicfrEH
# DATA bHa3ZN8CUvrBRsV7dvj84BTTUUr5DV7iPE9RVfGb7ZbIO82LfnPUBPvy4pKx2PAdbcjS7ZFj9SknS3RLy/ZWLnzb8nIGyum5KxDO
# DATA rJHX64ArT7U6RmgpcJTg7451TBOyJDTfablilOgJiQHnfLdMKfxd/GT4UXusShXvxd5PBid7X2Fp+a5bRIMe4YLDs2buUe5kWVTG
# DATA xVZ1DbEydxSHAEfZqYghkSF6rq44GfLlJlUicF2mTm4rsTqVd2Xb1uSILzXAjGp1Wa68L9J78DpWty3veGuL0pWo1pT6T/nTnU3r
# DATA 9AN+P69tXtg/VT6ufFpSMdJ7zzjI/QXCvAQqXZwJ8/UHeENCrK7zkERNDPss6OrIcmlTHaKh3ItRwkfEFssZbF6sMY6hFYzwSulF
# DATA rEeUZIAOrOfIlWPKDa5TVPHuqz6gzm4aaFTpzlpJd+2sI8OAd9IkfHRsbr+Ct/4irodpOi6bTuFXaya6VDaQCm06QSdLhF2bwPix
# DATA WkXeoSGmNJWZR1b8H/mN+xbjqb6ZT5ZjlKaLeG7OKAmvxaIjUyfMRl+r0t6X8+QyVRk8X/aQ29biacTZO8CWH8wxPjS3MxVBqBaK
# DATA xGEylYfnO5t4qgf7v2CQ8HlRCWUEq4wP7awiFBlP9872/JJUULQ3Bj7c39v/4sC35QBtEPW91byjvYD9ViqPOVn/ahq/mfG9Ic4s
# DATA fbmqyKwHzotFlq6Uw0RAmYX3rvULuZDR6BgyVjANQYFw+REv5xwvD5+VmQ35nzA/EvpUEDs0Km/nILRIuXJelyUpDzdKG5XzxoVm
# DATA i1QcSrM7ndByzwAgUKCbYjG9QfDWS8Cdu238DMNV7V1l6iQHqnrKJHiTTJaTXcXkDYd8sOBm/mj5Kv6/YGzTaQesGIY5KctxMKea
# DATA DuaMv3XoHKmRB0hnsO4lIL6KH2TYLA4mZiy6Am9XfqZTCGWZCfTZcGiHhANwBXn+CHip1tkiTf0xZtq4VJKXdfq6Ba6TUZ4H1iUL
# DATA ODz+AKO3mr3u9mNwJR2tjC8zts65Yc/6uHMsYhL3xNsSW7F0h7YImypW8TdhuJKu1XFH15XCq+fqrYsH99WrabaczSgbVe0oBXep
# DATA 8q8vYRk6NZOLby9ri6FytFs1moOsDxqShRZdOO5We+GOGetOyR6r9BQ9VZWnZL/h2pLCrU8VckkUdbRTviGN3Q9mXq6wFVWqeG6q
# DATA nFIB+FTOStpYMRJx9cwJ0c0LWGP4aXb7l6DhV/5SlM6/ZI3zG1A5K3J09BHi0MEuAkU1c1ZkrYVFLlahkYgoI7VFNofeAeRc4h3w
# DATA MF1gD6Z6zIfCrXJmXbgxOanMHTMsmJOdybnDhYKr7v/QdxohHSiG/YFwYKE8sxuy5cQd3tEBmQBU3Q6kMLESHsHHmLbWcVHcCpYs
# DATA 4krxklAGbK0qZcmkbKIjB9/i6u+wCKPT87o6E5/W0UXO6Gy5HOB5W2z2yGVjkva4WqXHPgPkcHi9je+UpSH31ZVFSaRJ2JWLhH07
# DATA veiKv2y1kKTAOkWumkH8mVvkFQRqXsSv7ucDrsMF8eQwBD9KuYga7oOSI2KE1Xy0qwWOxsT955lXtT2+WHwN63F6XmVB+vJLWxxT
# DATA az6yUlmpNy/3XyLkLr1byF1pU1wpaj3Jq6sZJ3hfKeDOuuh0DfHr6/ZWyAbYlznPIVO/h8hM8Wj9UkHy7UoHuImsV2ATKF9UlTWW
# DATA StXeoFZTGr2SL44hpRANDGvqn5kj3bKSuEc//lhmrmDYwTHuVpdfn0N0QXeO30nKNKfX02KXLVpRa13Jt1dV4LoIqmj9k2EcRTmt
# DATA 31Kqc3ajnBnP2Y75Cnz3GJFV0F/BRrAtOjGGcdCIHHwlvucSza3z3s5FgUHoGIG0DdabfI5ypIYR5UK+IvPvriuuul7oKNwVSJ+f
# DATA JXISnz21tWG3LVaRDFnV5Grl65J9gA7c2ufwHzy+TPs+Hf50N0lrn+E6Hx6Xue9KoeUAJJUzHJTrK284iOb+CJl34E4zWxF7SgWU
# DATA M8s0C3ENs6FTMAkcnk8X7JbmO2wGSQa2gWWCGCZXkKo4CFQsP5ZX2KA8IF2x9RBXO4M5gLi6zS9ilnNEcKckIrn7QpcDPwOzUSr9
# DATA 6hdrUrpXexnNEyV6GXtYY2SrZMap6coj33yT//lxHgi8ZnyFRAWPpfxJFxQu1ggXFsrjN+Srp5lxkwpTlrqh42agzbpd0apm6ays
# DATA +FxlHXfXrzlsXl3VtPpcq1TTKJ4XyZQwACFlV8N7SKSky8VsSecGDGFWHqBhfkeR7s0ayi2UAXLC8SFRkPdqTUcpHzQiYM6C+SH8
# DATA Ul7V57Ah0VuVPyKE6iNGLPxdR1uo+iAI2m34U3QsB7P7acnx/aqNIFe6WHxbczr+rUyMDK2yeZxlZcYbbmBSubGiAkG1W9cVtUVo
# DATA sKDQVdtwUR+yzx503VEvH2rV0Et+zh4TMD/hSBR7DqkgCjauydSV60u72PJviogzYgpv5GVUnidA32926L/Itev1C9UN2y/0AI9A
# DATA BdPLGL3jtiSr4gtuPUlLmkNHCgoMoik9jeuXc5RL7BRqb++ldd5q7ahWpp25ZUEXrNAeyi39qYYOBC6wwfpLRbMTit2J/eO8XSrQ
# DATA 4BSZ5AwY7U5BfVf39OXByenh8ZEamCt71Ngn+hhXn/QqhcQ4mqF+KzArtFzMGXWWNfdBJpyLCb476DFG3GNYoe0mtp8qEsGbtanS
# DATA hjrP5FQBXbPADuEQGZqyKs6qf9eYIoeTIEbW77FkYtu72hWJCTXGG7mjOs27JXfWmrpuzWNdaFjw8ba00oFm4mLr7Ti8/e5eAeS4
# DATA vip3d9bGK1u3PeAkq/QOhhjVvU7IfqaL3aa+1F3xPCmHvOICUOv/SBe/5S7QPWtvv2WT8KltywCynt3POirOawSnuhGSWqstwv4C
# DATA kR0DZossxZTPxvAq8S2s4U+KvC1jU3Wu0fQI85duZOMyR/Oygcq6443izN+8qdc50mXarKkD9EgRaE6qqYuTdL9sAt9z9ZdoSmAf
# DATA dzpyuk8ZuKYbQJy17t5DhXFWToCbxkUhnbX1Fx+Nhst4GqvLbrzcraurPgd9kPped4MqP+l6GtQZQH3uzz4MWHAGkEtwvQQVK55f
# DATA c6GtKMCMkMgCuuZLpTifEkcy2KW3ctUN1cPM9SZJSrjDnviSw0BXMAC8oOvCUo2oiObC5DAZEqkVlC/Kr3XZ9gneXz9O9L31pBBj
# DATA rlFAHIbKgakkJKRM/Ixh+VHyZrdUEwNvE6MgyXzX2kCV9ZT1OzpzdM1xA6fII4cJKb79mPe0E6fddtvrpqbav9py95ZOSDN99l71
# DATA UFy0Q2hTSBPtnhg/FN7UTE9qlJmmnEZv6Vvt4OAnh6ewJeQbiPCDFy/Pvr67p8TKypPv+3tTumvJCn7j9U2z5XCcZFe0DTKU9WYP
# DATA qPtFr5KsoLvZPA3BSsHD+FQ+ZAFbJl4CU+Ar/XwVXFKJHVj8QdL0imb/uzCj+xkSUIo67l7Am7geCuG+6ILof11WVVgfAyev6XB9
# DATA gQSnWR5N5oncXmHuUfnI5iTW7wq5+k2kZ6eyjNn+j8a5+FCUdw9IA1moZNoVVILh5MjafLKYx9Zmsn0Nruqx1pMhREIb3nnd8eDa
# DATA aUr0gg7Xg2lZ+b0UHkhnitbs0gFoHVA9NYwRlKpa73qgYEC+hsG9jQlLj24twd9HN0ea+jB4eEFWmz9Q2kBVM9CIpGoRhEBDlmRt
# DATA 6boDokaPi19lnFvvOsb8Sid2wQMuWaC0XmoqaUKWgaarHrC+yl8sjZhBYrW48nAhDKbN/5+cMcin3n73+f+NRrPVWMn/r3f/kP//
# DATA Xfzb2Ng4ibFClZ8tZ3RhTRxZlZE5h1tqWQfoFMCE0Agah6hsjJZj+27ae9L9KV3/A5L0l0PRZ/Qvt/oj+lw97+Tg5fHp4dnxySFl
# DATA uvOBJCkBg/6Gy6twXkvSrXG6WIBJv2UusNVlYlZ+yl/btL6P1coyTn8FN69w51ya5n74VPWa3C/Qw53HtyHShK25Xi0Ws2xna+sS
# DATA 9ITlED3WutuT3BzvnEkacB7VBcNx5x2+2PscawPmziiIj2fnvL7ZDzZHnJhT8Z4e7D19fniE+ekUX1VBkFmaJVTpSN9oYDLzSn9c
# DATA cq58W4nUmouoJZf5j0sUmFVFyvOt5tJsRzdTYAD1B+MBlssuM7ljqne6oGyI1VtYdHkd684heg3B5fctV79OocYIDT7kYo6HEd+i
# DATA mI8JKLxakQHTBamIVo98rwDD+cAtNc5tqGULkBNYhLPgMjPVPT9Zef6ULF3TxFTsvUGf4zl0LiXORu4tfVwi0V5lquxmb9xzjd6L
# DATA CxsZ0HW+iPDlJRUzk+4Sdrbmu7fgoANKTEjm/sC7nJ+AeB+qxGhukTWAI9FVuBbofjDOUqYUsqwycfXA70mQxVkt1+vedQp2TpC9
# DATA xp6fUlE99EhwB3imit6DjvyfYuYt/x5hx/F45HZWjOPCuXFiuIsPeVqAvYuColGqMqNFdJgyjic8knBRQ/aNblS8yrhSsT0+Yx3T
# DATA Umu/s+Y2TIu2HnnJRjq/pPCluRykxp3IdaTr7tCEaQuztIis6N7MtTM/N18u3HgUv6QOwdAClz9GNbJKgm7AymQuOw71Rr43oVVH
# DATA ODVbdO711r9ukpyrTVJALHray9Y1MqqrH+769bwr9IyLQyqjm1iT6Hcgq4OI0lBAPQb9NzK3sZDrYNeSu7X5clo+l5KQWOYOp3dR
# DATA 5SQqcYuGwWyBVyjLdPlHjDWojwzK7gQU5la9agCvOHkcasRsEUFrymRpPz6VRfYXLAmsMTxDF08cZXrO42SSLNzsRitHOz82gGSt
# DATA IC+J20ZWfYjcGawLzr5Ud9fxjVV8TacT3JRmHNs007lN4nHEh4mwnj+8ucPvc9RUxsJqfgOWLcooTqgAvJBeSVUqDLg0oS4F7iQZ
# DATA qaVmibFyfdvlPF3SDQRqZjCEfWmeelHfPi1jg/GFmYP5K1jevq0R7d1hau7H1LkLjrMiunf3ysCyVbyQq2RKYdrXcTwT4PD6AGDb
# DATA at/Qb5bGkd9EiNlmfQUXDooVcVpDWtappARmbrI/eW6tF5zI23250Lo/ZrUPRvhfSkV/qy656gI5ScJeNvu+1fzKcfKkKtxtJxRr
# DATA WNZfg+vexGwncmNIuUiBwaNurPVMRE8uVawryLXMQABwXXcehDzKga1JUQ1gaFL37nJmSlgrOrBXIO1Weh8X7zZVK3QBnDPM7T2X
# DATA 4VlD0nE4tHrvY3E600vMMZz7MF1OyVZzfHnSwNFOCza2Gd7SVfm4Lt7YBoLwHpTyZl6LT6XN7EpWzsjRWquOfjj9YPVbeV7zu/pH
# DATA u3rT7xQVtTzRMlNQBIwHN0+0s144si9zFyxPZP3xfO6qGkNo9/regJ6rrBdw8QevEf++r8XbCN5HlG2iT58tjigex2hhPgGe4lMZ
# DATA 26pihzMgQkq+k+rvrla5srrzCVWyNXfZ57RDXtJPdv3G48J8lh5xqj8WBf5keVhNMWsisw7T5ZgvoEM39vhWqdDJYt3icH+j0j4u
# DATA KoD8VmC/s/0b2qAVYnii6+/SveOKweYopVT5Ns7pDy5ja5tHH1ISl2UPRgb5MqNdZV+uaY+s1ipwywqw9bqy9B7wBitJ7RaWFaeq
# DATA uu2MvpDM/g/mXv334f/Nfk+O38fVf2n2Gi3X/1vvdXp/qP/6Xfl/v5Soqs4HFL4nF3mx01V8JKhuLVJhz/f5e3N1W+51/1b9l2BF
# DATA vkyz5M0ab7Dl+5V6LXb9CT7oTEq3nOVi78xuvgyFlRjN966Rnn7/QWZKTLpaTl+Tf28BHH0cTIZRsOMcUbBs1QrWyMhHaBkipcZS
# DATA f+6RI35eUCFDhbw5VLUILoGbZmC5KdVNLm+m+ZgomZXObtko1GBLFWbhy0BWzZQxLG7he5q7b7KLZX0XVjarXK3JSYZcEYBOEDiP
# DATA hfL4OczxPmX43X9790uu7a0Kef8D/Pnt+5+//+t3/yyUufnuN+/+Hq+wf/dPWAhcV/IQ+DProF/uCmq5/NM+U2eeyfnUR5SZv3tw
# DATA BlRrXGZApcexAPlvHpgBJU6Tbv02OC9RWvfFjh8QkQZIoEwaPCf+bC4SCmQp6ApOvkloOcMFBtXGXNVniXDJiZ5aiFtND5ol6KBE
# DATA mjlnfLj3lOMo/DO5UgR3jq+XA7YEmz4NThfKJFM7Czqd2y3xRodkYTWUHx48C/ju/1B45XruhPXfvP8bIims5A6fsPz7+7+hmvDv
# DATA /ws8/kcqP//P8NK/8JHBggL6QiwWiHQMAe0YYG7qTlkmoGASddtIOMF8Ah/uHoT5v2Hh+d8gkb/7e6AahOU3XBYfy9IDpViF6bHe
# DATA /bt/hqn8HL7/7Vp4iWQAwqqJXhDs5zm4L4ozwuS6s5EVpHqrR7nbfAub+G4TrKnlm8232OFdDTh37fJnpVw61kw5YEb3BMSsnnfe
# DATA MpS68N+FGoyHKa3YYMbhTBfn0RKok0nWQzaFnPO9j8mytLkRLAQsw6/e/cv7vyvYxb9Y9VTfc+f6I9HxxxJxK/HV7PkT8WZ6+sJN
# DATA dr986NSY0f7i3T/Cl1++/2sf/+AHIDOY3b086/HHXlyITRUAvC2tuAKAijeu7YQ+qmjbB88attTf+bTXfk0T5dsh+GeY+8/f/Qv8
# DATA 3y8esdbEiulyF+LfBBunZCpZY+xhTPWk/VAQkX3LPP18w8R5YANsifjMtqL0Zoocfev/Y+/dm+PIrjtB/Y1PkaQmnJXsQgHgq6Ui
# DATA ixo0ie6GRQIcAFR3C4RrClUJosRCVamyiiQEIUK27PU4rB17ZveP2Y2YnXXs/rsRcluy25JaithPQH6F+SR7z+Pee+4jswogu+VZ
# DATA S+NpojJv3vc959zz+B08EivBYcDPaWYOJ6OX6kLX1p+0Z5MBk1PqwnvmlIivSDqhcnr2gcDgPJcFZC9GiJEj/oIJ8U9e/6P6+z+9
# DATA /jJRM/xLTD/yC8wCAjvxN6+/SD7qTz+eHfoB3OVaVjEGinFFRK5MIjhgkX16jQgOGkzt2rUblzovvBlgAD+p2CQsAmqBRIerqDXt
# DATA TkOxz0noAyQva/oSX4XMuCTyWxmn1gp+FBnlf0OG+AteJMqpwjlQErVQdEbUmUmwVkUPE6rVDaXQ3d2XoteBsNRZdaYOwg440z78
# DATA 5hS4fMAg4VstkIf2tSx0gGPXkhMIJ7xxkTUcOOtxdu0avnSiYrgjRirBDKwoeJh3WhDx4mFk31VhYr0pHLqm3nnRIwlN4JZsuhtU
# DATA A1ugPY6zQ9XoH6aAvDEGaFSl3IrqpRafqm2vJnRRfOOMgFAYaPKcFwecH9R8NiqYXKA0kFburb8NRRhFX+WZcWgFyWaqOEhxsB8p
# DATA 5c9PBTYZjmqOIdmROnlMjty5UC2gNQyqCaXSyKj/M/b6T9VA/gbEByXfhaKnevS5Iis/RT70hTclIL6qr978pTiK8NC5GiG9MbCL
# DATA /aPTNsfJMtCY3DP9yNVajGoRFJPdj9eXVaEY3ROC9+dqJYm0KyKflgUuUwfTSVPJj+84zB5tL4hBNDupnVCsu8nMKsp9q4wXlO/i
# DATA 159HB6/GDWv1H1Cu+E0CmbaAZKoHv339z0JuABpVOFbaBQP6WTR3dCo1ERkfskpwNO8X7c5hMRrMpuyMnjYa6IKFbwHosiiJ5dc8
# DATA tGYgBDAsQOAEaFCBxQUwdaFBIVLtDjVfLH7+Drf/z5LoxP4yjY5Lj6BYqGngbZ8DE4P8Y+oo/RVkQKPjdKHGsUXQuHsx7mBdJBeQ
# DATA GDRBanQSXp5WFmf016NJuMuDjzVsQ9SLonzmFdFwKpoj3OqyjjG8xh0Nz50uHeqBCgBh9F3SVKF9Jjl0PTs4uMDhQwJj5BSghr8A
# DATA 5vD6H+CgCQpqaO6XcKPBY6lFmNILDTE4pI5lOBNiYDaddrCmsqLoupbUc/nl5fvMn6tR/wMx2Df/k/r7izkrbSGdRJclioZ23BS3
# DATA Ak/9qkPEpJpTcBV9V5u/xv8FlhXuZGpZ/5w0M3RoL8FtcGxShhJ6TxuiTMzRZZ9sEa/xv2Ctljz0m8n9gZLY+l1rwgUNdoGuhtQW
# DATA M9k71pWj55QyMj2rh0nUHQxGL0kH6E9cXU+lue0fGL9Xdo9dOzh3PBF03+2JNI9ww6GvBV8UuOUFnLEwK+M/4Gn7JzhdZUdPC2rg
# DATA x9FyWl4K1uXMF6HJGWTdET6VlDAqzLvtgiV0PDT6qT5D5/FlLTov8l6NlPvuil69evU+9AjXRp3zWWeAlL7H9xT2kh9q28b0uAMa
# DATA C45uIwdPS13BeOLyBAM+xbleLR5RKAvg8dcuFuVQL3oYjFL04wqsFytVBK//IFUY5y+Y9vdaEhqpUurQKF34A71UrMBJBPxbb6lk
# DATA sPlI5an7R8yFChpJdeQWUFCVCSwXAYgqZUWl3i1gJhIrDrYCV4oJ67GnxYobFTBPfuJ4t0WL+52y1JRwrDRtzf3mdVQS1NLDweiQ
# DATA EiHQ1afEf4cY5IKwU95MXJRxtuYxTldWCcCxuNKluIAJm1aLcYY18IMLi2q/FzHNF1jo/u4PgZmBtVuaGHlyyq4cRLkccpGjOEdA
# DATA uYBw8vVm8CbPISeKVmse8aSgApO0ioTY5ngRpshn32V47bTzrNrjyRhEF6vP6tjT30cuclfdVlVSe/EtNixUdS5aWHu2XjYNug74
# DATA pe9J2xzZJELjTIvk+h9QFWTajnpVazWvWDLC/4PQYfMsyMfOvYKjYjrVjIOj+CnUA6V6PBk7uSMKRCJW61dU5+do599yO2h3Yrc9
# DATA rSz3J06rJyPzFnNa9WdGn96QuXhqRPwQdpehSAHv9esmGlBaM4vi5OLZHzYOZ4DaUlJ9kZfWo29q/syYK6yemKDqWD57DWFTl4CG
# DATA 5NtaAijC7BXbxBMV9pQ2CqAi4ffZHN9jYka7p4W60Wy8Uve7tUt6TDrZjH4f/n9KXHz/huf/t7Z68w/53782/7+9SWdY0KFUF1rK
# DATA gaUYGUQvFRyhAdqEfKJusDbYW9EpkJxHsymVRVwRVQQ83juDYvHUb93R+PTtk7r1n6nOm1/TznTxSHKd6m0yAJGbkGfcZ+CEDZZZ
# DATA 7A8/wxElthyqWerw12yIf7sp5OAgU16WoWKUUwgLg8OOt+g26tKUrGXRYBg2RpFqPVRK2SZG5WU7A9KDf5ixDXgC47nbEjP9J4oG
# DATA 6EgLxb1hdZQs2QXlVfLIkAeSeS0dtDqR9aTX7zwbjpRg3SWdh5KdEXZmOkqK49FLs1GQyOFGQWl2xj2h8DfcMWz7Vh+T5Qlf1ZPR
# DATA mHanE1HJAI44hZTjS95ldBIcV/1A37Ss+2eDMg2Zl5Uoc/5sLKJVAG+RP2XvkX8GQ56b6kSPjLIhzE3eE/bg/1aXhX8GDVvQEJoA
# DATA wU3FdWuLpvXR6YQ03BF2pxb2x0wTHDFElGwHeozrb9frSvuYtY+CWwXps7/03S7Udez171znCuizgYpVN7Bpu4MAFtJrmA+Eycsn
# DATA N5lN3teGzVmz7sP1xEZmMM6xmCByzVAfI6R5Z9rYbW8+2n6wUSOk42kb3lmfWSj4R8nqSLHFcmh6cGrjrxVpgZv3CO+2ufq1yI75
# DATA 3/GW+nM1j+pKSvfOX6GPzW9Bh/Q7sC/Dsqhr6K/VzAZ38t+8+SnZ3+H2/U/kh4gG+1+/+Y+pCwTZ5rnmqyrPtuNkkcKjtGn3I8CB
# DATA UiRLMyH45xT1qvwz+TFMz9oaJmh8oe5aoNbl2VAP8IpJkBb6qfrtJwGJ96tpdalqQouuOgJ97hTKdcMpxM17ANkz0KkIV9lcPUFt
# DATA b43Lx6GwOasA7JGjEajVNdEpmMQF8iM25CoQeT/tPtz6rrufjO7UFNnZ+CgsYt4+2NypeLu7fd+rv1TjujiBhG2HVOnnsOl+Jbck
# DATA 2cjFpow7Elb0j6iXfESn6v33ycBRenguMLC/U/udlDt/j0P6ZfLmz4mogUtu9YDUcULv739k/109EfCRonRobwYF0q/Ag1c9Ipe3
# DATA mmjg9qoSILxWvkggf4dx8uiMx4PTtkvt6B+IKsOLvMNO9SUFizRL8oagHDECHdKoIEsDld+nc3xQh+fb7Z0H21sPP1NnFX+p7bVx
# DATA f297xzzY2v5w++HD7U8YTFVeQvl8qGJHeDpsm46VseaceXHUURNpOsUk4qCe6CdEHQ6cHR4SZG3xMhUxSRIVEVGKp5m6KM39grwE
# DATA 0dXn1+xuALsCCDD7OgHppeJChnDcanFF49qLgN7FZhWmnLD57Fs7XD0BhD+BbZFHvz8fS1FcRVV5d6CkS6dljuExVwr2VxSaDxBo
# DATA 2/2eBHEPogtCvZrYTWRYpHTApHrJe9wM1+3MpI1VhzY6Q3Tn8laYEUAYnllbWldQ30dWhLqW1sk8UVU0o5RKNprCBSU3nwSDLAAO
# DATA usZjAADaiM+II9FFR0GOVU5vmQl7vVIdjnVLjGQpqFq9CupWz2TlzmLqM+epTheQaP6zopB/jxIgug7qtuFzLTCGuyST8p29cfhj
# DATA xHm2nbQzzXZYiKaBqQnm0IQQQQnaVLOhxnrtpYYC5V4EEhlTzM9F5DkllCGV+JKsEYliTGBD+DU5UFuzCXIVdN3/B3QwRF9CFL0x
# DATA liQUmevUwzo4w/JfKaA0k9yFT/ZT0Bfs8kPjlsqYy+1jdS3UtzgTDQykwuU6wlObC6u5zwIZGN/hQ3XPBtQOvnfTR2hFa65QDhp6
# DATA QkFH2pMeLj7uTVFV0IAuov1RTTt1saJd/mamZkFbqeH3WF2WX44mPfNb3STmr9zf2niKP5XKE9fUhYzjS1hRJQ78GXnAE4P4CXKE
# DATA 3yS4kEoQ4bglENXf/CWanP65/AJqgMysyqJWg75jrJ5epjoPD/YC/PXDWQ5Ir/Dn0aTz7MSmUXGgkcqWgtGWNBabKsBeKRrpBgMk
# DATA 2/nwRQ1Uspy8W8LrPM9P+ampOhaV1pmqzkNk2iT9k9p3mvkrWJH95On04L3sO7APbKiNqpGjZ+D1tVbj2r9JJRmFdNk5KLlrXCth
# DATA HIEU1Xjk0VV4QaB4kCTAlKeQ0aTdhO4DDWmZragrOxp0nhUtrLLCnsD1wz86E7JOhIzZVd4LG+BXDtSu+pwnfDwZvTol9Tf1wzmk
# DATA 9eR5f9hrpd1Or3eaWr2Lmdvad+5eEWlFG8sHmTu5VB3Nb+07QVm2cIKuETyaUB5lWdPQkJqfwH04Gg5GCF9NHy65WF4gQcyGdhmG
# DATA sXXg4fESmMnflE5hulf6L3Rsh5rviYRDLiIYbxmYNQp9fNYfOj7v+tDxDoFJOcn+pPa0uIbo9xM03z4t3stq+39yR+3V2p0sgKUU
# DATA 3hA0Hk5miP+os4QLQFNHj64jrh/9feOAdlzMgqREMeSGq8JhdSjhZPzc5rgPBc4NQDyATwWhVYSghGSPp0x3RAK+6aA2ilPHfVGd
# DATA wdtcepZSJCpVAo/4b13Tma4pzIbjBlcBOskRBVnJntD3EYeTIfJ3nlCqAs/bGerRsCo31ht7/p7xsGjgpoEGsmTZf3juXW5xHjUa
# DATA HWZrD/eOzC5YONpE3qnzOc/fAVOB2yVwiF+gAPFLkBVQSPgSr5m/oCefgzTxO/RV+FxJFH+jnv4Gmc4khxiJnCjIHXmJwYsMXGIo
# DATA VAMVSubNm79Oy6H0TLpNgAOqJ0ItE8hpxJKMYtgq4YAAtqw+yRxJ9ZglTKjc5BYKUpYH+X1C5SiyMqOPw+7JKvdVWweI0Go0WUFm
# DATA McwFrtPMYxPYfJCACv4qP/8cW3RCGi9PMWv0Hu+//355AwjEfi5XRPVeZ9bs9XUEiFkPph5NOdeRVVuKz4q5JzIT0w0NXyBoGtjH
# DATA UZCs22wcNhHejH0gsQRJzfAhh/UiOGmVTBkCrJk69+kvBzp23+411PbaDsGNAD/QWg8PFI2ZCqGi4SQTByN4Uk920ZKPNomg8NOf
# DATA jIZ4I6YZVfeGKWXjLiISUUmYA88TCHjqczPx+1qAhyVBXzChe9HEji8z2iQke+RPv36RCrcCXErUcgbLSn0BeQ26YrPyHLghLotJ
# DATA eeJoAzgHdZ91n9huJGsDFtIn1Mr13rU58uU3k73jXHHcYproXQenqTObHo8mfXXq+i9yDjwc5i+hU3dYnKVsQmT3GgNw7XQ0CnNu
# DATA HGnzVH9Y1gXUpEz6zxCntuUeL1wQoUU3gX207nVB13wvkMj4gfFiJ/aX1w4IWFYLwWUCNQmeRopWLequRiVlx3kjSmfEXcDWdKaa
# DATA adK6nbuwinb5y7eoJH8eQi19s++UP0CndKhWH1KwCWCvgKAz+qF56OZBF9ipKR8kgghUDPMHatcvYxCq1ZDwYxQAGeiQH6nD4QWT
# DATA 2krsCaqze7s4U9DcUVrnZFu6l5rigK8XHEeedBoM3ul5IDDGpOUYhrFjmXBSd/2N2Jhcg6J6rOxvll5LrSu+hkrsK1loMh4N2BsM
# DATA n6kFWEY7+IzdCx1YUal70V7xEczGfU4QrtUS9eSa0LWAarzfReMz46O479Fxd1eTSSxw4LWJpDMkv9IBnMYq6e2BURkhlp9x76+g
# DATA 4hqYTisxtSsTRCfjggl9DHwq4AR0O/va4/dwNBrUJNId/02D3p3SKhjCwQm39GzDVkGhBol3M9HN42dNdONQ8kw+hj9qtI2kLU+H
# DATA JhtrnvsBvfb3+YS70DSDsQMueMTFuZA1oJNADFmAhp8WaVRTV9obvK0/9MVAT5pB3h+cLJABrJyz8CdMEpa57cbpySAN+1erqADT
# DATA Pjamr+AwkBEax42Osn6JLMg5W+HhEBlHYK2F6TR6gxxcVEKVvdamucr7OrijtE9yxSv1A7Cmo4wqfwNT4d/9IUKcykfkrKY4xSR/
# DATA 2RkM5C3TKPGs9EKeTDX9xubkOx1jeJ6synAGOCPAQ2qUCdUpxLdOrQq+0lpcQ/1/qPvWr8BC/uYv2c7zS+deZe5Mpi24laHeTpUC
# DATA VZ6LrQDGebphQRz8X1ufEjvNjqiPBtFI1zFXlf3EqOBBYwrkVksuSLsHo1nvaNBBkMn0WRfOdbagj8wvCL0IlZkAkGNQr36LtrC/
# DATA T/Ye7pYMSu3/0aRnNNFs0lnAamQ18HqnLTwl9gszIwDNX0zzDhomQNDvdQbqy7ebgZ+QgwWocP8ULt1wK/fHr71HTJdcuwH0eVe9
# DATA e6TdzE0/s7i9jAYJo19wgIuND67/n7O6+suq0X0eqqR//uYv/FGjyh7PvjjR8LNm6IRZWvrhX2wjc/SYEmrdvHmDedqrSec02ogk
# DATA PiRcyt9zmtqkwtzat2xz89YCzZl25vEFBOKcuRNAZpfOuI8tgPBiZ6tux3SOhqQb85fvv5Ep4c1fJ+uPN+vOYgHsBONQ/Dz5VNUc
# DATA uC5Y5Al2XeAFLI47E9KezrHWsrNGzPKKhNiRZyLGMqiVLIZYkyglcr5itJTPUP3yWtwWpa0EbqkJDiywMVuBzA6gib5hJJ+MBjAZ
# DATA NWOxcoxSdvTEtBivypqmFrB6Gw/C6FQueb7y1nQmJkBW+mSCMOf7qRr7/urBxfoStCZnGdbqAQ0zrItXkux2cDy4ZOZ6TarJdJlx
# DATA xZxUDVAQN1ogd1r2wy8OnMmo7pThKfPP4H+xeC9xpWyl5baRvP47pKp/iT4mPwfz4C+xOAXLkVlcWxUBL/BL/JSeM1f6OT/8lQHQ
# DATA oSnx5Cn1EPWV8JKWKdWzYIWwlpkNVyAxnNfhybFAu3CK/h+MrfszOTXkgYVoOdYlkaygghQddrrPZ2Phv0APyIWCT9yyA5M4J6Mv
# DATA fc+Jo3VuaPDIkkmkrQoUb00ooZOfI8K0aq0AUrGmFF9SNXXqifovODnS9m9aubokzfo5JgwDUcn8pMtQU11f1Y/xMQCsNtUfJLkj
# DATA Jh4NhLtFP7JzgeBaIf267CsqYslEDgSp3rb82ufq1dzac6RwhJ4s4Juk2Lb2QnWfd1oWwoX2up1TRf8oNoYrLa9uL/gLr2bw8kOe
# DATA w9QzC4R1iguyWzUtS350pNgRaBpb7HriUNArcSrIqTJC/oqjPDOddliY3plpNNWddPrQwApC2+KqWNQW9EoIdDRP26LKsrkZ1epV
# DATA d+H7UIy0/55tZp9RLlhnEdV0manMGDOaK9chBWGbOmnMKyiDe3CZ7LvVkLc0mnkCINXL0nipxt5uMIMqUU/a4jAdTfLiuKaDTk3v
# DATA 6748U6+wCvhrZUK6yaWqTTSp5V6s9XTHq8TRweY33Y68FqhCCCq8eA/tl2BVJXjn/rBR5FPOZlBLOQ8GafNc4Au06QP6BH7cjGd/
# DATA x5d0guhZmnlmHyzhmH3oG5N4EPxcyDEmNc05LDRIv417ZOVFZ7Iy6B9aBNgVxVTTxV2V/y9zuTIMk6Bbf0aeqH9P4SEmTt34nPoa
# DATA C3VJV5LGf5W3NxIsfomx7VJm+Vw7Ian//kcJGIVzrPVzZykoY4DIHPYx+UTKSd2II9kzqU57N59AEkJVhue/WTo1yAo7vTZkPtdC
# DATA uABWA2XyoP+jvNc222WfN0H1glbbYb3BEGvBDSByeK9oqssb0hlzsF9WD+RwI9vpvLpLke1dNUZAYhF780BkZAb/YTFRTsXhhJqh
# DATA u+elZDcr2uUigsOdl5u04BP8wCA34GRbT22zg3heTRCE/51OG4iXS/tynypEvA9eQH2hQnYgS3IV6h7gBJgt6Av+X30fC4yF+AtU
# DATA BX4JLpv6CvCrSqdxPtJ3yMPit4x9+TOS6MkvsGSundRgr07tKZhHv/cNFT2IVrF/nYBFHEuAmbfM205t7dMRmVkHVj2+RrzOnpNR
# DATA ibkEzVYC2tRyGkyJZTb2frrLPXC3uGMpeYSDtcD6Yqs/yEFdSunlK/c7K33Mh9xsFvhBEW4e9pLOwoVib4wrMCqTf+bsFbj9AQtg
# DATA H9L49vLxj5yV435J7y3VY3FcOBOeEc7UlIZvy+0RLEBj4XWMM0AB2o1pkXX5kkivl/cewwbF74APeCXIeqU2liuEQun9ORbBeiKk
# DATA lv7RhQW4klXbkW5VDA3jOWBpsOX/mVTJ3v0dQSsxdjLUCny5COv+gtF0XVgb0vX9AuP8AAP9t1a/HBl5bMD+Gy0E4OeOKR9KsqXW
# DATA rqC3N6g2bSAUEqb3AusJ7idekF3oaHsRuys27eG4l3bv7Y2wKMXzlsa/7L1EH0wpONXICbUBFtY5NxVxoZp3XanF18g1nghdQGiL
# DATA LKkAtQnWy8+MyskyA4RQ33hwdBofCZUm1bqES6gSvAHMC8YIwDXVYd2CXvpOkj/35OQ7cPI4EIxP55v/ZFz9Qd/uFDcKvc+Ruksd
# DATA nlbs+Z6bnDAHdYlfoLwhcTC193psZq1dd1HtCc5axMuYWxGe53PXu07aMNuHdPGLN3fBdzEyDUl3aHI56oVCDLozxM8EaawFmaM6
# DATA 9h1FN5xVR2fsuB+epR/ubG/ttTe2HrQfbD9a39yCW4Q0EIiRP17f2nhoi+k3Vq4BFTblDBchOOqhN4nkjQhxNJD4tdoIcJA5HB5a
# DATA 8KixHnSoL2elui/XYC+vtBbVzrtzpsS0Jx+0Hz/54OHmfT0VuiH0AA/jS1w0vCo/y/0hOeSYedl3tVl4hx+irg1lupedF/lyBN3L
# DATA uGouGfyjyF6NbBxh9ojuGy6os4lJCtaikHlJ9lrSOOiZJ1vGWJiF3QhFIkdmKhWMLszJdYOjl8O85zQY8+ySYpn7RT2+XFndUdYd
# DATA ZGJB5gR8XvooxQ7CwdIlTsvXuV3PIqeqWXGmzt2l5l0ZHOVHGnKmdOHjpcE/uOQU4NqRtcNCh4pg1ObS27cxf6G+CgrrskrTflkn
# DATA 2fuL7T4H+2hewl8ZbiX6PuakxqWWgruQJivkaat7gA7T7JktonQfGHO1IFoe2CGRcuGozXWem1SFav/12oI2GjNw2QklBm++oHrI
# DATA yNhKpC2JtIFGmqYy0EF0cKoWHzqz6Sj1vaTf3twi6y112JKZLXhYtqAx0HlOW1ixHtsizluoAiv1SOGGW7rHl/YDCvy8Pnfzh/3y
# DATA TgkovYkh8sTm1NpW9W5Fea6F/xVmj5ajRVaMgD0Q6R+UAsEc0vKNIyG4bz6BRN6KpvImb9UceicPQzZn2xryUNnMrthXRSutc8xX
# DATA KZW1hCSzxlvnVJX6ychqHlMWPLZKhD1Uu/C+rrIVNIJunniHbXFHPbcZbLp6DDKKF6lb2aQgNfQnJkaqM69C3Ueyxl67xp96ZAtn
# DATA QnrwSC/tWgpp6LrHYGUa55A8Xe2e/gtF4PBnVupOHDFpqL8c/9SFHX18TyTyPmiXYUjEwBrokxC/wFTE0W/md1UQnClJBs2OVWuU
# DATA iANcDvUrGPs+PeW2S/l1RpEp6ODpaWwo9rFthuRe4RhQr+KTS8oI8yq6nLhQNnuxG1mZICCX8cDGMXMvqz2/7Zf+xW2BsV5pLdD/
# DATA SHgutWod6uiBq2vjVj3QiUjU7nO8x3umf9GE/pEtxQHT4zI3VexK3bpPlxO75wR3WutiTDifvxiVovs3k4cYSE8IkrOCs3wTgEpa
# DATA JOPZoRpR8mTnYUIwZZS8hOPhCRZGzfAkL4rGYtoRinOArHqTfEBJMYZMAnjzkntUabAffzYHpac05UCZXper9UCFh72x4i2SPsod
# DATA oetCs5LW12482lr/ZP17G23S06ipI2fOmP4Dl0U3kjlAJIoyLDiisq3OI0LsFvP3hT17+Mtq556w0IGnDl/oSEWqgUtpbEqbLsCM
# DATA nkOfovrJVYFv0Da7IMhSDGHJsDxTaQnYUpTAmo9C+hOn5faDg5Bfe7UhIwHfJxPtzoFRtmPfhFQGGBBoAxgLxHQ4zvsTG2bKQjHh
# DATA FryaMj6I4tynTAdsJKupB8wc5HMJ5gfzeNkAjzqxWpgUl0K1stg866G+nCiaYOMYPQ8mmamKghC9YE0ZeSyDNufGKRIGPgejOH0x
# DATA g0zxKsLgX/C3EzYVK2ZgkghRnyGK84L3h55+B6FvgVVl3inHir66ejXJ9dso5Sg9pTpzm1MUYuV3mR9JHg979K162rxjYnZJ5C83
# DATA 9hj9jdDRZS7cCJvRUPDGCWHQ1TBDUbyPZgCskfTNg6RZp6mGWzi/PYil9iliZJk3XBAoC064YxPC2s2X1SGd5DLatZePC/PjcNYf
# DATA 9DhIWF0vUK0C5uAKBJhrtf10uce4fDxN5AJJVaLvEepAr1EOIhe+1JuggNuWzVZUeiMm3umdVkWn6uzG7NqqvYtrqIRuhoCQFr+7
# DATA obpR2wcg7fxV3p1NO4cDDDLeTKNY2uBvRcHUuLNMS42x2nkZZtXV64Aa8uUx2QiRQEFngEpA7hX05q4jVvhoNm3dWF1lBTLlBhAd
# DATA 3DV/brhJAC7ioSFt9OShIUMBk9e/Sj7e23u8u6zDdN78NOoCZAMJv9AYLATUy85F/4hqFnBD+rU6iAgUjpc5pktK2gOyJZFx2ZW9
# DATA HOmOaBI5mh/QLRmOxCCneYY6894yVEv3ZfZDz6Jgo1yfTtltfajXQfhwP4vspojrtQWxXJhJLmjBkIxPBOWydz06K789G7wca5uc
# DATA 0BZXbEYSotS1iUiqMOhhjiAch88pPqARUXSSg8fK360YrAPMM1M0aMp1TtIIrrnkqpobchVcaeZoXwQsiIt/EVwYjOuuNS9TBRHQ
# DATA IB4Go7pYsNMiAhVB9TZmQ3RZOukXcG1qj5571YU+Ja7wQNXUBTQQowF5nbAoQXXdvxPCsKUEPBGYX3FwpO9UZoF/bVfnSiBuLIs9
# DATA 3y33REfEI7KukzjEZF/twjYqaRcnLEGrOGJgR3OaFAEAzknT7mol7I3bIxebzCjb5tGBqBDgyFMYVoun0G1C4jXzAITKk0Pfn+en
# DATA EgX3grTYQquK4B8zj4vEr3NAmVbLaz/yf0LnEuA6/8FRzX/1p9Ve5ANsLT6gEsPLhdriAtWqTN3AlZZPFhZ18w3yMTg4zxjH97N5
# DATA SM+NRCal1n497CUESPzGcc8xi1z6wDiy10Voi4s8jF1gaxvqA8mG5BFSP/sUGxgaoLBtjzt9zSID6wuyOfuwTnhRVNjBv5lnQfD0
# DATA PSTR2SQnJfmcypfdJnBimYrSyfg++Ry6NUz2fYuEktO963+DvEhqWSS9I9v7p6xhPtNT3vRWoJ7IOeDoCuTw4nHWEK7s6gs1p7Ik
# DATA wKTKEufBTWLxw65TXtLd3UB8RWbZ2ayiEXPvjzJF3SuUqepGyrPJGRyGkJVcezRU3RV9oY4TgFBsiop/LBZp4Q+7FgHhopqC2NJs
# DATA ztRY+YsMe1LuqrsG/otW9XZ1GGnUrSfQ2riOs464ecB4jlIcLG/ap2ixklS9J2cGI64YBL0COZj+v+KriN/anuSDXBFej1nFBqe1
# DATA LtoI6cjwLjpR02X00e5mPqLReRRhjrWf5oiGZKZZhgvHOs4YtEIpqh+KT/JDB2PB/cyY38uB4qgmf6RG4eVNrF8uWi0lxEIFuuxn
# DATA icWybG5MLeg5wT8uMVXup283WbqudzZd889Zlbhdhii3oDYyIl8YN/iW9vVtRm/LjEYHYTd4A9Z3Ykf9hhl50IiA+l+sTv4hs5ZC
# DATA zletH17Jp90VLLVi3eexTKfXGU8Z/89zrI/fDxfUNpTmqnKUoSZhFaccwB81wZ5kZLORnVi6yt7VPJJ6wVU2QLFp6uAaR26gwXqH
# DATA mqA0mxdvr3VFQfTP4mxjUd1SwNCsVGSkPZ/kRuWimMgj/M8X1FwFNbUHndPRDANYHE4e8poFD2TAb0pZe/RCAsuytNhSsFj+gfp+
# DATA A/9UpFhcWR1VpXuTNSlmDC1fKMfMW0KOmdxmZQAf9ug1o6Cd3oLE8Ao9GBADExIgCWULuRS9G5Ae1At6PVN3k0f6UrKIYyb5GtYZ
# DATA 2eRRZyzvIPMwETOT6Y0S/6Jin8hJcxF9EF8XzbIdeD6RMX2Ro0dthlu6owRNpMa2M/LCl1Uovy2Lu2JYnA5rjnbFydPg1amT+MTH
# DATA SEsqUqs44Scud1APaulKZ9xfAfDjFYLmTMkWDm3QvljRIEJjgHwgv3aRTLWBxq42va1575DvfaxmfKDenWmg317e6TFCNU7tyUhN
# DATA xGjY79ZAYb52neBaXh4DMnNQ4K75vFme/pqS/2GXKLsZemlpy88tzAOo2JWauVi2aRHY5q+MK7wZ/4YSYVusWuBsoCY4/tHhqHfq
# DATA ovHqnqImrAbJOTlHJ8xWOf6zh50O9QqAgMhb2nu6NTi8VaX3bUnetf3i4Ugdn3VwMALDTh2DJCvwokn3YtU0qG0DJRlatn5usuqQ
# DATA 87DODfpTyDf6W0K6gHjW32G03C9BExcR7L01YB4kkwQ3wA5XpSYixHBCR1Ci7yQPs1Cha5VijKpUAjmF0iJ58mTzQcOXCzkVK/pb
# DATA KTpE7Xc59O7m6s2siiwsvvnig65t73LCc5kG3ZkKNQyZFdjahAsbyoJHshjk+bh2nRllXHWK9s2EIxl/68UnUxizVpbyav7k9T+q
# DATA v//T6y/ZFAq4kwRZEkuLG4ZL/tpkptBg/GS2fAvz5xUh58zXr/+vNvz6l2/+CoI+/dwZMLo0oqMNOV253GWssV+b4NUvxoARUOtM
# DATA nhU24xf8AvrK+Z9bWkedeqpn/KxB9ij809H54hPQStqQoEjFupdppOOm+uoqzLQ51h7aIAtWAYafZWLmwmxtrWGiGpo5hNozuU8m
# DATA BXJQnUi9sT55NoPt8xjf1IR822q3e6Nuu52JLxvgGdjhT2qp6VkKDg4j8Pto7WvLkDEMadh6ab3XpnsxGky4ezQy6FixBtVNEcDv
# DATA 6oi83HpMOQcVp1diXE+aF+PfWknF6a6TI7AeE2qru6QksGUjddp6F42dqa4cLofLJ9QzW3cZwu4CdaFvSnanrAzD03KxqtrUXV1f
# DATA ZFPI7ol7JqUL+FQthWe/06Fez/LlPornFp8UdmvqGRbYauAkYot2A4RKG/QAux89crEs/gOli1rmUIzhyAUjrHkHDUiu3sbAD4lk
# DATA VOJ1c5M5kWFnelwEbsTpiSBwc3uJ2KcJNVJB7HQnJUBiH/xhGVQdP6E7pjsG/k2LwD/46sm/bJQYPzBoDPI3BQPjb4lsHCKsY0Zg
# DATA b+6zclJHYWiafEiSIUmJIB8SFoJUWkfd4XTgsDDHJuzR29K0xKgxQhcwytBVSxXHVl3JOEPx/Z2N9T2dj3jnwSc7fm7iOmVGss3o
# DATA xOBHPWxAJslNX6Z4NYAWXAEIR9M4ghc1+E+dnzzcvv/d9sanrtjpcstIOCjtEpTwe7OTcSEJ/9xNo1UUkKy8AE/sTtHt91vsTwnm
# DATA qOG0dT0DBqQWto2uc+027td2G/Zbu51aP9Si/2w4O8EFhz87g8bu5kd7GzuP6on9/fGTx9JLi57TPzWqwKTku9ZW13x07etPa/py
# DATA 4gg6xBGlXFKT4qiRUb+bn5IoGpHKSfzaPVVU+GTjVX8q7LUeLlpOldW0gHSfHdhxn3NLnhiX6bC5139nRVVzGTFya+AyEXXfm+Oy
# DATA hyg9P8G86iD9fq4BQX6Fada/QMi9byzyv5PO5EeH6qiMT7/xlf0PEtbfvnkT/1X/8/69cePm+7f1M37+/vu3b38jWf3G1/C/GXjI
# DATA qia/8a/zf9+8sjIrJiuH/eFKPnyRjE8V6xjeWLp69epO3umpLY7bQ11L1x9vElwR+i/jZbVIpseT0ezZcSxmSJVvqFqWmKxr0VX/
# DATA BlMKHCw4pL2pfqpuq3hl5J/q5nKs7pj6JxA+/feoWEL/Crh7qCKae4BwqYtMTGOKsOg/oU39t7zBes+cvrrKKfN01u9RH5hG6D7g
# DATA XUoRNnVBVLS0O1ADSowJkS585jZlJHw1aL56mjTArPtXjPJkDIlV+j31QuY8IW8L5HkcVWP9s5ekR2N1PmMMJVWkt5j2+sNGv+hM
# DATA p6e10CfMHUH6iPweExHPo6qd9MErm8TH0RDTO3UIr/hEf99MXOGPu8RL3+B/azRsJMs0ciKu/eF4NtUvzfRujXZy0gr7mkTQJeh3
# DATA rFDkoVH4Bb1pc/EaiOh4OVGMegwafpCbTopnavrVcVBbvg7J3VQbc+cHGjb1qz9+gLnn78DBweNyRNE1qNKBiCY7mPVx3/aw3e4P
# DATA +9N2m3tG+sjRc7URUgeoxOpX6YZowsugr44/M+d31j6BZ6ToNbgB50aTZOPRwNzkprx2E15TVmj6U2eFjjrJeXP0RD3r2DlAEWs0
# DATA m8pU2PXE1K1rTuPjabU0qgNq6m3vzUDXrr/fWFX/bw0GixmEoQz8aDbX0vNFeryTn4ymTOsKfYklh3xa2k5CqYl3dz9OprMhjAwO
# DATA A5RIZUTN4KiBa4l/4YLSCpqszisgquIL9yveh+jt9enyh6PJy86kl/eWH09G4GCX2OWUb9Vf8M7OwDnNnU3qsMAEMVz4uduhhfT7
# DATA 4oCChGnPnzx2BpUBNQSgK2bnV0j/pgVV9rd2AqMwYYyYF/BJHGOEo4hUXGHXnWvX5DyeO0ijZjHcvcBl99N1Svb4Iw4MB53aB7m6
# DATA sU2QptnP/Zyyvm8p6upLcxHyRzX/QLN7K3yMdBGmhdZEXAnwbdbgsll8HPcpCfHyHsOpuhP1avnly5eYc2/ZtEp4xrbFcGYd6zQk
# DATA 3FYUGrbVBIIEazcEYAmc1I829tiAuJYt4BWqNkq4w3bE7oH5AUMVbh2YwBb8x5DtliHfDgJIqPbHW57Y13SbRIagzUA359mB3GzX
# DATA rhXmxnVtgxGmmDJLDGC/ckVZci/xv51nIPGJF4hwujeQg1TdvSbP8hKnJmbLTnJH6knMZfZCdhHjM0USRNSgUWUYc4+TrNHbX17N
# DATA QONuXv92Pbm1eh3+cwP+c/Mci+kNeze5Hm9aWi8UDdEfZKWrHwRqz1sY3MzJUac/yHtN5BiJdha1g8hkrFZkIWpRs0w92aPNGzPS
# DATA VEze731W1CfDHJWUPDF3wFIGPgInqmg3eby9uwe7Ar3r/CA26Jy63Z2MKaTG2h/CXM01DB4/Uht96iR00ynXe9OGvrEgFJ1XdR0K
# DATA wLMfqdYbs2k3pr0praxfjCjBKVXW0Lnm0+8D631vdbW5uuo52FNdjemPQPkeD1MyzXFZXSt904p22MnJ3ugUukTNL92wfc5sf7mr
# DATA qtPfF6a04Yt8ouTQAvxlix/OOj2Q6UbTDiV/BHSMTn9IqnbjRgs3P4fFc25HqIWMxlocFegKfJeZqFmdDQYITl2bpPvry9/vLP9o
# DATA dfnb7eWDsxv1G7fPU0qmPVeGf6JF3t4oJ2Z91J+i9N6zON8JzYO3MSe5+hCDa0TO1/ZJZ4wCCt2JQEBZv7+3+b0N1Kyrm5e6O4Gf
# DATA TPpgc3f9g4cbD1AO65+o+yQ+frj5aHOPnuavxmA+gacbnz7e3KGno2H7mLIH2SpMPh87d+yxYcDzbe/mzsjw+XD0cqj1AomuaYmQ
# DATA KE4AkFC108PEybTo7I2kuHEbCxDs2GpW90rAZ+3ppHN01O/qMnJZV5O7LWoC/vj26ur7a9/+9vVbN9+/ufrtb6/pWwuWwh5ECs0b
# DATA 3eYQvTwT7oXauzO4wRZmEcGf9tkpymaRkbVh907buhgNIh2O6HmaNWbjsZKFLSSWrs/cULa22zsbu4r6qrV8sP4Z/PPJxsZ34d9H
# DATA 21t7H8Mfn22s78jLStlCFaq10QR8krH5xHaL3GQ6Ezh0GDB/EPQIuAA2JK2VZvS2n3dMPRrNGz9LDvPuCKLxTUF5DDh3Ee24fZjJ
# DATA fb0lDw7kbrWPsUNmd1udvN/49lb74+2HD6D+0yLRZ+AOGrpe0HEFvtZjRa65wUEepvylpSOWQJER2dAoyskIqy2hNL6fT0aKgXaG
# DATA RQJhoXhgGUtDkopGsvHquDMr0FG826W0Cyfqd0INJHzAG84FFzbzvZbfqDlwajbXfHcRnmfcU5bCaPJxHg8kwoUxhSr8lKnZZTpn
# DATA zv1Jb5Erco94Llb+ku3ouaVJTzA1tv74jkWOSY5m0xku1RDMUEWCfqZWrySv17Gtao1W0O2KPfSkAMccStqiBJrkR2px7yh5eaqu
# DATA 9dTFk85polodEi/oDBD0ICnGIPBr2tF5ht6XSw4rPrNsq8nOwXqL6xTXhravwwXWyhl0HuhVSnknLA3ix9oAcV0Ru+W168s31vau
# DATA 32je+rb6v+8HGBIp9/QhrOYHECap2mMS7rzb1YSjaSYWnASQhW0CfRx2BrvA1xELCMRVzJoHfkw15PdZFqBcpcJyBS7HZiSKFDIw
# DATA ZRrjXKR97rU70zQQ0/b123V0agzmTnwrcnn1ETPEtsDPUpktZCaIaQs8wmtcKkuW1Zq+GEAEJM7a6AdkFC+OO73RS4iQLMQwbDUX
# DATA Id9j0Ox0R4OmOAsscqHWlRF5SPss04nzd0rqwuQidR1jC3GHNdtrMuzjzydq4UDvVBND0Zo+O8DH+gmWlEP1iheFLeqiKui+adbH
# DATA 8+nHb3j3Ba3w5tL7uhZyc6NRZn6egUhkYbVG2/TNqiFdlaPIzWVnzW1B99Q9DXQNkSEg3MdvoWyjbvtUAn7duL5Inx/rvhp9rCOq
# DATA SjGVA1jUnyiqTnJOxeaSTj5KNEQ4RYGpIFiqeM+2Rkm4haVmV+YPEVK/g/xSrtW2sqzw+2mr95p4ZA2EqxTqVA2Dp/7cX1478PdJ
# DATA 5bVh7Xb99k24N6jmskUWRsYZkxpX6/s6SXEMZiLYEaQzHuTPOt3TiHMoT2C4PClWgfsOgyNnh+H1rW44m3Epw2w9fBMD28ywl/d4
# DATA NN9M7pulSZRQpDbLFFWU2lEryV+oMbw8zqn+E9TcIAfuAAgUeAGBBMMXcrw/EiXq54MeSpnOlc0enJCsuJQDqakereWX9RgDK+Nc
# DATA B4YoMgQ19cohSfxGzwtZEfQ2AzdDkGr0W8TD9u/bOPl4aTXgzlH2DfwJa7OvTb2ySGC2s3Wryek/GyI7OivUzNJOcFUbhZOLsCC3
# DATA DYTsMocnysQRnfNcbijgeLaH0Y8OkGjpbtm4G01+2tBorTPuO1dvTSbVc63VraH2CQLrIMAAzcwrh6fLeu9gOIJDE0AkM3FSnaMc
# DATA DGPWTCCBTqzpU/qgGytpmNdd6JLUsqg92CYeQ+MQyTUP4WjpEJMC9cwoL4J9By07kIKXbBkwl5ZHj46OilyoyVfryRp5QbiVaoCt
# DATA uXP1HaqxpTWH9BMBhf4IhTvzhqp3GRvKuHHQG3xFqJn7Kf5ys7Q5L3Bz4xdhDAAUtCocRKWBNA+LUVWcfnY+0DCk6jKHhmhcoTuk
# DATA DdQPOwmi9yXq3t0f9VIvhA68ahl+dJ97cxCGZIYqp4ww03wzUXm/H8zIWJKzKEZNYxRfgThm0AeTN86LP8yH4D5Zi/Uju0Nzoe8u
# DATA 8CPzMyliCQwhxiVx+3yohOLnPit0JgS6Kaq5F6ulTJ2ivf70sGmNLOcX9V4JuhevdAOr4DsoKL1zME6xTgO92B2IbfZvWqaWdfj+
# DATA GQ+uqU8rb9wm9eHcoRhYROOizYaeLzvGpZEb5Gw6nk3L8tmV2ZPJG8Z0GbUBsAaHYEtW9RyOwJsGaktLEhU7jSu6Nhq80IY/U5bx
# DATA JGR+8nqCPs4auKqe+GAT/SPxvRwU+tYOT2vireIFUH+2iEpVjUvd4BOwE5zCRcaZAB00VjS6x6pDNUFkRdd4O7XAV4LGT0/axttB
# DATA Sr6imMORwP4u3G0IaPb+k9299vrjzfbe9nc3toC47ujEjegDRebhxCRk0yrillPVo/Wd73+wvtV+sruxs7X+CNUvWmfa6SnhSdVg
# DATA XHpEMjojxsere7y+u/vJ9s4DWZ3+BPokJsc4FfBPwzJAQjM8A/uygkXNsWD1hP5T3umaprVztsojfwWZAEK321QR8QW8+hcYN2sV
# DATA YFHG1WdRYpk+ASgLy573074nacjLCGxDK/+0Wtqnmb5oY4VW8KH6s/lqYPqcytsbFZ4XqKcns3xapq/G6ooJ+t4tNjH2D1lvu+j/
# DATA SACr1clSWbCwsG9FVs2msI2K4MVx5xQMtXWp2nWtL5HJ4YdW36m9hfWdTN0t4FrmW30pOsJdXZLxxIO67pOQ/Q8CAGVTmZS/NOya
# DATA vrToQqbKbGHeKygBTiXBfpGlv9c/OsoR5otuBHew0ZGaM+AlSuL1uDG6lZvk1dwVPBY896mefPVQ/ynDSZrR4Qqcam3HdYfhht5p
# DATA F+d6Ag4cpd7OWB1uKttl74D7AgVlzsYUSsk832i3h1r3qG0oTKJpWtPzUgYtkZMtW6YTkVLvYdLwD/UENyrmamz6O/dcK/XArnTE
# DATA gkIzObNCxjlIh53eqXqobrAYUznbv6oX5ColOJppVAUornW7lJ6iq8QT+nTOZ6CoU2x7WnDz1P3sPJVdROUNegUy2aB0GKqKpjH8
# DATA 29w1hidTXfNo2ONJrnrw7Hhq7OaSI6r7OgnPjWQHLR+JXQY3cKU3OW0rocePQUgfqNVTz00gHBnmiQyGR8cNbTdBJaeKsMKYyakz
# DATA vS9di9GYPz1WhwS69h3c6Yn6ANgc2hdOQWHtd+s+bNBB+Xghhkp0hqUPUMyzdhhU2AeoFOUF1w9oGvGXTQeDyBC87vKihsQAbKCU
# DATA V4jJxMEdbcaOkMVyum6RDqtprXWpjaAYRi91pe5WngRVIjzQYbUUOaiGaZm7N+OtfTNZt75JYF9R8u9gpNgt65gSg0VCHujoSAw4
# DATA HcNuH2CgESc7OVQCam9wSnfARrQhJyT57ac4Ps362qu5F7+uYl7lR/k+j5e02RDu24f9Pcnh/I3NOZ+O7HxE49lhqxsriE2/HI4J
# DATA 1dIX6Lqu2p6ZyspjLnPzWbe+7Ss21M3tsJHsaH7twCvF9l4Jk9QD4DN+EGWXLAtH2KPg3hEGx8pQZnHUVCk33P14/fqt27tPHu2i
# DATA XwultuIwiEZx3FEva2MP2fQ4f9XrP4PjiWqeBJnHmPIiqt9PhymZg1ACRn28uLk9G4wOa+k1Jv1Z5vJQosg95mI8TVd5C109AFYn
# DATA OaMsZJ5TMe3W5pShh1DAch1/LeYyus4EddZk/rqTiOlGvVKBTc/UY7C+s+jFfEpJfnRMRz08VGk0+vpSgddhGC/KQ+BQm/rRz3ci
# DATA xQXZiX5T0op7lVqoJdIcLNoAXl2W4eqi47nRc05NWkdNe2tN3dBjjaCUFkZES98vrTu0lYnXZd1R4sky4ZHFQpljPTlFM0Fp4HP4
# DATA gb4JLfNNqOprHcgcjWGGnbaGWnL3DgiPbq2uCvlBxyPbyW4ma//9J//LLfADpPumsSlG7nQmVQkHks4N6JwXZ3nBu4gIxkT34T/e
# DATA 3d56gPDLpVcVIjiXu3GYp4bIYNoGkipRvgS9DXnpNYSZSxAAbF5Jw4DsqapocTiUajYrjx1dWzDE8l/0//zUGF9//Of7N1ZXr7vx
# DATA n2trazdu/CH+8/cb/7n9cpiMhkqYniKIUS9Pns06k16C9oo7yfM8H2OUExwwxUMQRQD9Uk6tD9QLdSCheDQSFG94nFZKhHDyE0Ii
# DATA MHGZ6igOR/pHf8xJ594+MvR4kL+yP2bT/sD8mnZMrKfN8WLiSPOTMZCKpaU9cDFMdJo/0BMT3BvOVrq0s729pzX1BBZqyi0jcpyB
# DATA 48iWHmx8uP7k4V57+5OtjZ02f5mujMZT+1G69GRr06uxQKLU43/LGmho5Kds6f721t7O9sP2451tAM9za5sdvVyRGd4aPb9GWKLJ
# DATA CHq8u7m3cdlaChLYH61/2obP2x98trexC96MNsLFvITnSvbFsbf3Nj7FiUnT/SfD/vRg6YEQw6y2Hvcsq6FwMZbW4S7ZGubTl6PJ
# DATA c2DsDXbl6QGU/URP0NIH6FHVOlFCSB8tz1xuaZ8T4x0sAbNrqZse5HRb2niVd3fBX7BlDhMfpKRqxVewV4roagjUJfKFxG4Ci2kp
# DATA YWVpf5MAXA+WPukAk/rgNNIxNRd6LTY+3PwUZmffzsQWzAQGKR48hSyrA8gqoR8pLngIS/F0KKVZwjbo0SSaErD1i1YqjGHXQMRw
# DATA EyVh9JWDpklOBG4iJ/oOeTSHasGp5yq6nTH4erZJNqWHFXkyqXX8r8zTpKV5XnAnCsS4ZBpa0uiP205JTAXV706lfcaGXsANtP9q
# DATA kCOiy2qC0Nr4ol+0cX26nWLqPp5hrkm8afi3Gollt55wsS6Hxm4+hnrU/A3zqXTJSR0zJaV+h7Yyk1xOLSkY/VQlajDFMYK8qFk/
# DATA nPR76sJYTzBWFJ+2Vk0oOsFE6qnA3ywbw9doUcJLJHgymEqz5MfJ2fXr545pl9/cS27f1DZDuDLUxplWfvcpfaYRjcfwn9u3bt24
# DATA Ze+sVEvVjGmdM7AjLO1amHm40JG169/SPan2+Wo0weurvnYLnL4OKTXvIfRGV7ZIfx4gWeFPtGdm56Q/QM/k/vg2BlWmzZS8ECx2
# DATA Zn+cunbOo/SMPjxPCtivyRkWPwc3cgh1ZTGeXMtbSS3t949QAXCG2gC4XpEuQUaKilGJJdUDpCxUiWkCZXJ+qfODGz8nWFW7mWLL
# DATA i4EZtohZ50XmkeiUcB1ggoQTM+2Okx5WeWarN71G/ADbquw3n5sjRTvJB6MP5+sM+fl5cna2BL46qp4Tgm5VT3CcWKzNrOJOcjTo
# DATA qDsfE507yfn5UoJpwfn6AdXQZ0paAE3m8Wikrybq1jGagJvd8tqquqqCof+U+31HfaWX8OpgdJUfq6fdqcGTpsnpTUZj9fyM9gro
# DATA psWMnCVndu1POmO4YtX5RGXnqre2YvvVv7VjNm/PeMrPZRdydF7pF8d5r67T+Xa1MZ/CK0AcNJWc5NNOMriJ3qCK8L64vdzvnqgz
# DATA rv7z4jbNkurxsLc8zPvPjg9Hk+UCJgU80uXDTg9smvhsoiY9109gOOpQqSkek3vI9Vu3Ltq4o3cZTvKOWkzMMzjuQLab5elotHzY
# DATA f0ZsZln7n2AuabVW0BfVgPrgxJlbWiO7N44oML9kd+i3c/bHAjvh0it1xrTkXHZe/R/IGQbasQt6V6MmY+YATGCJvbd16GYAUZIq
# DATA St1WQujWxv29ze0tiuFj/1yHdNtK0IHpJkHQmIfgx6s4a6//DD4U6gToDHpNgVrBLR/DlgI6iMjC4IinhJMU5bgCBDnF4Sgl5x70
# DATA cNpTG446CuXjCaodnoIn6mnvvRQTHUcTZzqdhUJ6JvZNbwMk1vKsk47HINs6NNm2sV7omYFDJdmXco0iy8egQ0bzp22J4YmTvlrt
# DATA FvMyePlDb0LsyvWla620k0lw4tK2OSU3QDWoinQb3sRRVrCCbWy0qbY5q5MM3bB+bjgDWrPPnxuY+wbfALgbDSreYG8/L4OT9z89
# DATA jFVkNmTy20KbHuraeMaY9RxOEPuQSm320oP95tp1vcpakiNmTFTaSGtGqKO818iy1CwOjCwinDJwcodHU4ofJQgP/IDmN4cHyOe0
# DATA 5O6KuLqmBnUIg+cxkUtZtUXqViQ+9Pn7DoEladtWZ0hyAi55ouqm6vQZ7QyLjqYhtaO0l6M3YciunxJMfazjKJ4z3weRBqfMaEj1
# DATA cJa7+N8j/G/KlxjRfhZ+UVGWM/oBG33ZH/ZGL2sAI8F/G4/7dWQiPTNq1UuK6OkORhAEhx73alT3FW87HKEkBboYwGRJ+MQn3UlH
# DATA EfWiYW4nl1v56IJVVbfQil9u1cVJUJO0NUpGL8HTnbRPfXDkwvsw2EDVjZE8tfSVulD8rg/woIBBWTkpBU6FNyWpkXzSxeYHvYXs
# DATA 0sYiAkSY6JPxs0kHz1JCKZx4TOhAAI5iGgCJDjk6CU0L2rGJThvXkODNZbux5qJQQjaZhBzNhYh7YdH2qUB5oXrVWoDgBT106yYJ
# DATA t0KmlHVl4emik46R7nQo5ixWinLutxB84DyNk7XoQslG1SxdrkWeI/hz7dYJ9UFTAQmtzXoF9rQFeFHjR4zRSlWuw/JitJMfzQg7
# DATA JeHy+nbZq6NqcjTpoIOwVlM2Tp6DanAMlt8WNkWuwAi5cNR/1UobuBeXYxDjHvLpUc8inkLdHuIptEZjJn2LeWt8ek0HaSacEgal
# DATA wpax8OKImTY4dU7gqKBAL07mab7z5YVCJ+y1JXRSWkDE5eyW9qqIwHtoDLqEUtMu69d9M1Y9BA0NarIbL4/7SgZN1TMXIUM9KM25
# DATA TYMO/L31c9o2wWsODPSKoEt45GugYzUQ7NozNYYreD1Qkliufs0pjxH5f5SsjlavX6+anydDCAVKnnz4SSLWS9crQw+pIZ0KVphB
# DATA 1XWRgbh0IeqGT/7haWO3vbm7s/FRTX+l+4qjkQ9LBux/F47xLcZJR/yr1gmjlE2hyHbK0FMFFLuUeNefbvJ4dKYXZsBYxdeue7l5
# DATA y+qo6SBo1//KvYupb4puB/SPOCEoDKb7q8vfBk3frfMVxa2egisB1ZVVUmCYce4J5u+YDU94dshRqYgRUkcX5cEiEJegGjVVZidQ
# DATA ST7eS1LuZ+bn+qqpY03o/cCAZmOdrS625uVfQxKWBb5CHzE76XEgO1utSDtvOfuibXGoPq46E/FF8lM4HQw7V3n6v4IRlI4i7hXn
# DATA bQjek+9ozWWODjbmmfzOZC1gS8GleKAxD4JP0cnoRe4gOV2WQzFSeNMSg4uZKljpGXjjCEOF+nX9azFUIAXlafItFv//48BmoA5X
# DATA MrzCrKe6E7X1mlZR/H9pTNp/h+zrHnCvC7Dv+CTNY6rCa0uxOAR7c7SPT32Of5+aeeoyfW7cZfePcSnYBFUDPtlZPlpf/rDRXDl4
# DATA L9OMv2YZaO07zbr9lX0n8zmqvyrYy7lzFE5OJcf1d5KmDtgYaFRdHD2gTyRC2I+utJi2wJ2bKAjYTtDTkaq5fqDRJOrgNYtfeKd/
# DATA 8dEc5oMRhGtNR6ojo+kxhnuhjkOGmCmaCyJcfD1TC6mrruIm8CxCfh3Gca22H2FsB2JmUPzahwyxltmBe01qUWXS6Qh54fA0NaxI
# DATA /TcTKL/o3SAP7lzmi8NgXsSjcFNqz+HuHqdlOAAd7PqVMV4zbmccZmfFZUIaXyCdzJOuwupLpmqu9OFih6Anirxhm3OBrl7BKWku
# DATA XbhH3hwfpftnaubOL0qU2Ahu7iBo6S4xdkYl5wUX0m7GhfKi6e3uiVuRWWYJbJB3hrNxe4zJmQnBWDvoO2cX3mkvKyf1HAXtkwKp
# DATA c1iMBjM1vQSE02iwdwHpfKZFBdM+0gyJe4RfNWGap8fnAlmqqzYCJsNGKKlrE4i9KXJKh8cSAxgu4OdBRcAqYpe2bG2Ngce8eZ4h
# DATA 5e3WaPoheBhGQogCmCgGwEN+/3DruzVox/D6OQQ6mAIWstQsmH6eSzgolLFMQL6dGTwdoDeb2MWUPTS9YmFjNWZlcrpuxA0dG1sL
# DATA W8NoOtklCq9zKjFz8729T7Ms3qxfhSNDPdjccec0XgnhfngV1QJpzKkJpks/QCoFI1uTT1m4cr0Gs+zC64qcVy5ObIX5uMLUemcV
# DATA wbzprBKsitch58AGBzzCB+JZrLABzlG1vfXwMz9Llf299QHklHLoU8W58YG0q5JbTQ5jul4+vPANnlrkLPCf4aiWVcvfpSsujkIS
# DATA 3fmL7o4IVuZiO8IjdgKN30jeNfItcXDb2VsBimYLN39f7kQDx+71gBcKrxY9jKFQt+Xp0fK3LMAyb67ucX/Qm/Cm4f1XyVksS5Yc
# DATA JBTHuAvsOaCbsb4Eeu8UeHwm1D7GeCj+7SDFAe+Ahwi0FbyVbh/cSAbAp8YHuCxs0JnVPTWR6mJw6ixrEVlXMxjNUbFnDTeZaTCJ
# DATA +IWcRfqKr9pHI5CR9cW8YOYdaXOSGxgB/O0sti7hiwdKkPGRzFFLwaCBJZYFwra6iFHBcH9rVnDyBrndQqNkLbbhwIE9vuH4TDnE
# DATA FN3dVwjfLdfhkmu3b3zrpoWjgc8Ccd+nZdC5cac/KTBdfBGDcxfOIQwKV9cYYEP0zQi3JcPDURUL7ESB+URWXnLEQjwEX/tKoH4A
# DATA KecALgaQfgZDOXcTfZP/9OgQcgy1cehtcCRr4Z/OEZfwcFPMoosQcYvsCjEK3/FYPeJNgaZ6Ev1r8PekDRkJ7X5Fe7l5XtUsCfoD
# DATA NQy1E9njuUiWl/FrSijLUEEvKf0MaMqd7YeHWnSiYSXjYFda3KTMmWRvky8J8dIxNtCmRW8ibHEH+4dKJPgZbFbXBVWrKLAWndv2
# DATA IDMoetNO97jNuMdiRKiehTW/zPzuUHVce+UMh3uH20UP+SxubEn3yZP6YN+iaK7Wb18/T/1uV287Hrb+xlv0d7DgpFzpIi4DVbtC
# DATA hv5U/cGt0p5AkQiigaEwRnarrjWK4zSU5ozOziFxVIND1VhUezLsm/jIANRCLxV3QAek9ppSB0bJWUoxN8p0JaIUOjSqLlNR6eQI
# DATA sV6KVRUyMlh3gnRSi3dQd6gGfB6rx2NyI2EXzGK/eR3xA/dTLzbtsFMcPx2y706ynM+eDhGdzqGlsBGpGlDRIYY3yCcAkZ13k9Rs
# DATA VlMGxkUlQDOQRVLy0liiEwugFHCraZn69m81NbassyEQGQstEhBxxspD/txWrV4RLaNC8F9dCBQZRf8VB8iMZ8PudEYwFd3jzqRo
# DATA pXf+6Md379Wy1KsNTCzTvBiDzyC2qqqHOrxS0EqOyQ4wssq5qYLLVA2LMUwfDoXtJP6p524cgMMrlpznPumiTKoPnGX7JuP5/hvU
# DATA YhCmGfz+987vReuHDo8mIHN1IC8hDOgupFVCpYZ+Ziqm+AgG7+VnhX/TLN0m3lbhg25J3AV3GvsAEp8zdEpdGwbFCr/Ek8J/W9JN
# DATA 3cZT1VKnit/XmXw5AAu2OeMysJ/6IW3oZ7aZIu2vaVI4O3rZ1tFsiCJlcr6b7tJTcM3ye+D3FC1yZKJHSkB/X2y+QP6hZHAYwb8M
# DATA vxm0Q/cZ/l2G6y6QcOqdOmLT0qLolYllNTiuTlwQm1Ya1LCXwyyKEdGV6biPDnPw9i6+5c3VdOFYcT6w2AHsQBoUqXTg0/fAFik/
# DATA x3fyMyiC646f7js1+lCnVL6VXK9Qjpsx69uLU2MWr3BNL3AFM4R1JsZT7TDssRoPA5aEGQcNVDcT5yaGkxB7AIcLJL2oQjaDzRhH
# DATA xcGgZOa8jc6pE7db1A/1HCORTUb5lxOYtQmukuaLuDDBZR5PjBbRpcTXGffJE6T51Qm/0wnEuvTatvKYcGtOrVM6aq0ISoVysY9y
# DATA rRbsoxkFwRhhwjQO6M7IcERSD1NxGEQdx9GGhCgEvP4s2hAAlLOgb4RjPxRbI6XxopgbAR5Df16it9ZLd6UzBNQ4jI5CfAu8rOsO
# DATA pWw7eYyuBTrFU+4FyOil3XeLB8j4UvAntxAEbNbAwCbK0/hOOBqLcUYu+J6bhP5auGbA6tkK51lSRbImmOfEGYOjmpPL4wBM1qgp
# DATA SnWnC+mMFKaXqLKOFARNZaB3nrOF9UpZUFEy3EcHUTaGWK43bJZkQyZJtJV4KQB2Ugk38ghBu3dsh0aErpYuReusxSpNK48/co8S
# DATA wczd7qaPDPzDZ1kcIuwmnfgL0p3f27yVbgG5xCYHJvIJungXXSWTaEXLUtjL+NS5lAmBO+6ArZbJBjhMDEfe9vLUi2SNLTTXEV6H
# DATA OmT+ZPQCYHOM5pewusQDDsp1+LyEiKiDU4y++I4J+7LlKjgFs8EeQF+B8WaZo3hxgfptX42Gpj/NSzeFaRu2GPW5lUj4BM66ycWk
# DATA 7TgQh3BKtDTkDbY2z0EwyyplLY4M5LxU7OvNTiNiR5nhaJkCvlvRGWh7fYGkm4YqrHCGtH+Kt5AeaIhYSy3e8XelHgsO19Gxd2JH
# DATA YuYJD9PYdeLxNWQu2iRNQ9v2v5aW+D+VeBqkcy+SR+kFvBHm1hZ6Kzixf1m5vy840BiWZAbcCiYhhtbo7dlgXWuBqw/7csQ8fcoc
# DATA krJsIdxHb4/f91yjxC7XrIBmewW/q9zkRnVO49XYi4VP9wadYSnN00SxLmjdAgRzSUfC+OkVhdo4EAW5oaBJx7BirHwg2LIxZTIa
# DATA 91G3BOg4DdCbINZbDX9qGMhGT6YGA7u0EnKCWrku6WIZdyyEIPLTZccrcBm8AhsAfZyS70fDRf+UTn8Jd8L4qM5z6QDfN+3BV+5R
# DATA wlAuPqwL/1nrj22u2mXERSBUC/UDDT9j4ib9ceCCElPblPme2NpQxtT9AB8ZiM24AmHsYLIew5+oZaASIpFug4L5snnTgqugRsu2
# DATA syNelrP++LwBMW1LYTpyh6Rj8Xpyc/Xbt+WQDWc+Sg3i0dOhQTl6PCoY6Qgj5FVDyfJRNdKR2y9JaEM8FH/CFFW77eGiaKcsIPGT
# DATA iijE2neaGIj4Y4ZUyBIfRsUGhahVP09CBjCRCCM3b97g8MWEFabJ1Ul3udtRVajherUtq+JXHcoNBjlFm190Jv0OrkZtbgil2ibc
# DATA VZ6X88TtTxXPOkoNAgQmr2L7LqW1rRyJWqmw+5j7t233EpwifV/i7a5f+lcth3ykal1SDsUG2pSdrdXRMKRTzPtN2gmLbA4ChQAK
# DATA Me84OT1stbzlcJKByWbdQ+hPgqNM70c9hPB8Se6MHXEqCoMoiwZENyumuE+V4BEKsydU9DTCYMHp5aQzAT4KnshEP5DbI18we6wJ
# DATA O8tXQxTHapK7FLt9mBso6vQCQuyREhegSeKNVYYi6o/ahjqwcdgPyBcwON9HgMoRL0SkOOF+grPKPYH3mcgJC59FBVdfRAHIucQX
# DATA TsoMccf5YOwYKh1XB6sx173n8mUXlxq9dy0kUQTHp8OvAMIRiAEUDnbZ1WoQRNUZVF/T4KIVXAAm0aktix0cXqqSaV7wtkWdXWCN
# DATA o20KLxZHGi0V8paW/q2HfCmF1MGoa0LCGYHyqDucDshwq1622dVQtw/P0tAlxxQ1WZJCp0NThj0P7+9srO9pR8OdB5/szHNCBDX5
# DATA ba0md53dPadB2/7v22PQdd+8qOsgTBlgm+uZk35muE6NI1xB6VdJz2G+2huf2uKn4CAUj3aHAHqwQTnTFlfitMntXrvYF66HiH4a
# DATA Nf1dIj6vHOKDo0j0wRFRs0UTW+pDII8hMt4Vpa6loliPKyMzr8GHUu5SVw0T9kBTpig+BdnUYvaVFmVrjAAkXsjLRvt4VrnXXNpu
# DATA s1Sh3xbaHKldM+ajpeCVf329iAvUBVSubDbbGkmHslDNGooZd6xL/vO+IrahF52DttKuV1/e4dbvr3EWTlrZefJ9dO5okL39YGij
# DATA UK1shgA7lfp2kEXt2Phx3SaqWdxA6G/Wnm9Al6kofG+Dat2IdfuN8ad5m6d6A1XskaqJrNwLbzmJ5RNZPpmRXpSxfn9Xlsy3GzZX
# DATA 2LCMkFIvjMB0OfLMPUH1Uln03rCWEhp1dzpAytwvNArVshLoULk4H6daCGcC9CxNL3NQpd4LnF4boNt8np8WNckhYxyjNHgwMsyO
# DATA an64rO5VkPDJbdwGwqge1Obp6upeh6J5mmwel8kJqtGWIumXGDOwJPeNzCrWQJR1faOv4a/Gxtb2xtZePTG/9jYePd77zDzY+HRz
# DATA d68qoVE5qaQD4FneaAEVuadIWOM8QShYJmWDTujlUlAGXgP0Lx09Kll43aAdkI6eGIA9+RK2ugJdQM0XyNlBDD5K/w4wSaUFgIoH
# DATA ofgozHqvpEw7B5iEJFOaSz+tKtZKqWBttlcvEazx73zRH82KdsTdPHrJkVHpqFSNlzKTgwq9MwMVahcFA91l42WGImFy4i+1+wXW
# DATA 7byyzjK4ziVtWO8WBCRNtFsJfePUDoqmQFbz/GhctG1ILmYwU5e0BhNhOB2c7nKMbndl3hLmEQgcWieCW3I9iYZiAIU6CCwIWI0b
# DATA 110OZLbAjhXYByMMzTmjGFSs1UcTkvFKFigo7J/216N8PdY8GCCK+JHZzh7y9QV+bXEgFacKPwI6Mve4qdptmId22z1VJR87qyTw
# DATA vc/YTNo05ruiOKbz09S7TNjYm4kEP3PPW9Mdhnptj0pTnJHzoJOkojPKuMvwzrBkPtSb/LIiBOGmSsfcSCB3wHK9NRfsNriru9dY
# DATA oxVH4McGRhjF4IZ4y1UmbFxYOqm2vIowfNlFX4KVk6YpDyPykjTKj8oAV311tRr+PlKS8gFWCo/zFjxC6RbdcSWfSqwkJy8cpoC7
# DATA VHI4fO8lGiPoWCc7GooxNGjcdzx+xUEQqkDrL1I+jr1lOu+oBwH/02X2SqXvgMekdeH2bH6gUgnjKvpT0YjBcTqo6PYyN1pZBAnL
# DATA 8pg8ecKkcauVH6u7mP8pJHaLF+4PUYkdfFDVQKCQKRuoE4GkU71R2Vi+N8zMptGLW2YJwms4cn/Kuk2Eev/6dUwBzrm4hQRQFt7j
# DATA QBWBDNksz1uW7rA04+URiXRZbisJK06SsQz2wy+FLORKBAFKCLvwW5E6HJLfF29Py8h5Jz7O64nJZ04hZws0Blcf93TxoXO988Pl
# DATA xULkI+r2wfELpu8qdWTztCfzNSjvRIsS0WHond9wZOkSETr0xM7e0h3MnTvGXNpfPfDSBTpeyggxiS0hT1o1FVoFcHzL6HbCU7jg
# DATA jvXIqMXtqLwZxZFZfZsPoIcf9V9B6IHq8TItqoDaeDECiH9Qy62grXKi2HiRdLqTUWERtCcWNzy4z34Nd0zd7IVvwJfuG8yHsHQ5
# DATA xrJFrV2OdcvDzYCKysCRpR2IYY/iFqDITiJJIO5MuU+B6yBsmhD2WmwDM2/UOMRHurg1GkA0pb0MmUOH2hTJn7zzYO6spUwATexz
# DATA jkecBF5I7eATSJNoXlCrymBtc6v3RyKu9hjk4NAh1pdVkrHmIpRVez1eOh2frKzajidmCQpKHN5yNFTvhus649bjwSQVmGTR8tZh
# DATA 8mK3XXyezdlyKOB6G02gf5fSee1+sSDhfnebuFTzaw+mvwqVg5iPXlY2N+V++QtofkvOP91q3vXBn6d2K9EIkBge7GkPQBZDA7CI
# DATA UaYcZJlQ15XPU8XeRJGz7GLmbSyZVSTgE6aKBbI+c6Lnb/zhf/+K/4deWnDOv6Lcz3PzP6+trr2/dsvL/7x6/f1bf8j//HX8z0/K
# DATA rH8X04vlZ+6CqqWIZms+7hSQiNn8nJ4MLpi3uZ48nk3yx4B/UZLGOe8qcaqIpm4+NY9n6nqhyOL99b31h9sftR+v732sRS2rcLcm
# DATA 2dScjbYSvTqD0TPyIQRXMV2Hzll8nRMWy7zFj9a3Nj/c2N2ziY3BURVfgQn14To9vU2PMHJMpzq+fTNMiwzJEETtaHbd3PrIfKPe
# DATA uy/0h7dvRjpnSj3YeIzT8K2l3T3Vo/bW+iN05GyYdCbEcJf+ePvJztb6w0iBZZH7igvjpSZSFbkl7mzc39h8vGcK2JoOO93nszFX
# DATA sv3wQXt378kHgEmT3r3SG+Emww107y78Nxl0hs9aV/Ph1Xt3Mb0jQqHk09ZVhMhTTzHI6x7HMNxdoZ93x/oJXH6sh+vdlfG9uytY
# DATA PUQobD7Y2Nrb/HBzY4fCX7qjk3EfJAWENtK4RghrdPP986ffV1vj441PI2WPEBP79k0qs7f93Y2t0lI3rlOpjU/3NrZ2N7e3dhHE
# DATA ogG9woiVblFQRk/6p3jxDP+dvpryYxSM08YrLv8yP1RHtX+khK30XO3+7qBTFMmummy6MNu7s9FrFzpEqh3CqPkQanPh06qh01g5
# DATA aXqTPnjy+OHmfdiIf7y7vdX+7sZnjg0nDpTmgqRx32EmCJGxGbXtCX0R4acdnk4DNxAGqovCL3rhWwvgsbUFIJvO6CiRn/hCAyN/
# DATA kIunO3l3huEOtE4RT45gHje3vrf+cPMBzqK62yJlxW/09CCJ89AEvWB/mwU7c3IfQIw+Yw6qX2vfQnVN+vQphj3hi4qOPdnaXf9w
# DATA o72+u7uxhyQ4zRxsY0noZQYpuH7FIY7h0k6Yk1c02qFGJjCgxwBPcMsHCpqbBfpAJoTGg/5tzAcNVUZhjeAFTMIZhZw0Guk5RbpN
# DATA pgJoqhFPKel1o/adpmK1Px5Phj/uzF79eDgb/FjRi/011a0fD8ZT/CNThZ42Gtey73Cv4Lbd2AyvZEfcCxcKOjNheMXs6Kj/Sm3f
# DATA l3BN0hoNS4SyS6xoBDOy3RvhrePC+85ZVt5795Lrt24scAQebD9a39yK5eMxxAxrbEwg3/sY10etFh32fm/YUT/12e8U3X5f/eaJ
# DATA KoNwu8gJ1d2TZ1RipHFOdxpuVfJy3rNqS0jWdHvtXL/BXaJYnbS5lIeOwWRDWUu6dcqDRppl2UUnPkqjQVUb4NI6PljvAPBcb3K4
# DATA A5uaGmqnHTvJcsv2NYX02239PzoAOkzHMyUsTRXZhBdg952S+AvP+odqKgvUWIC6/dXN1dU5LBsnaPezRw83t77reojG8cmrscTn
# DATA NCYXZX3rvhKvt3fcRmujghwpQeWBmHlkeSlvMuqoV4m8XoWovshsfbKziX5ZJUOw89YS8yb8RwuMOnz72cTObG3vtdWHG/dVPz67
# DATA cEfQW+Ly0O4L91DV9+Th+g5ed0rR2dtkdxII2ExBJKWxiujgKJuDzDGX1+SBPsiC1K/25MaVwO2TzvPcIuBbwH5EErt1q/y0IKGy
# DATA 1QfUCmvHQYk67chiU+N2hQYoNgmasto0VovhTb89B79JqYMSzpcw/rn5PUNPJHVW7ZLhseXsqPAfZArto16LWqR6wpXk8fmI/OUb
# DATA QDj4UIrblgexr8njCDzdrOWPiGLw+oPNrXV1cOBlzCbYFkj+2FwmMPWVxJF3TiK4sSZEjkosiKyvoVvFkbOP3Pg3+3weZr5/GlEr
# DATA 8XDz0eZeiJLPvS3Dye8cTfPJ3NHF0PTRvdr2uT8c1b0hyN8nEOrQHhK0bA1bNV+ZX/SR+Wm+qRAJcPz3P17f+mjjQQjQXxLD6Zyp
# DATA preJTR5exyyuWdgVw8KaboCga6UVpsT4hsZfhsb7Fu2lyvwTTHv05g2l6NjdAnLGofC1v9b0cCY15r5tA64tWLk58LG40NIISOe+
# DATA LkeBLcUErsr4U60euCT/L4OGv4gIQEtsO3fhcNCA5kRyTr8Tel+RtUS0m82PZCmhzxezWc7dHqFlUh5hd77FG+c4EJOicxa4hkTZ
# DATA Fq8J6Ia0JrkWU0qNO6dQBrgVAW4JRbUTBxpooKvTvixyGyXKxnU+2tzd3dz6KLyTOt1l2KuW7revILP4G08nhNvtYqGYrMS6WdBV
# DATA we+AxWFDEvRAJ/Bl7QAXcKG8KXkfvkDAE34K/G8Ol9P3V2dOHqh/Jba2Kj7pDDDFKLSxLyB+DQI4o+kAogZaaMGsQq6iNf6ez2Wa
# DATA v+gM0qwCeNNW0zgc9U7rWNX9Eb4mKE5MBeIVa7ipQRS3fQdDB/7GY+FRtKH7fttensXxpAYfEsgnffYO+jLpvMQs96+mRmMj1bNx
# DATA Jevu6XDaeRXVrSo+rKbx4mrWSB8j+hxU53ReZow34BzhRc+mFLxY6CJVN1RcolAjfTRm+sBTkU9ZuLoCtoWie5yfdLT/d0EqS9xN
# DATA UGhfvz/wM8y4b72DtdBMaRFq9LJgJfs+9+GgZCRQVMDPOippeIcaacfCdskuRcwcqn68I6pmXFCWsI/eZKsnPNf9HsZogRmK/PRN
# DATA iACi7UEgKs5/wLXCNvahsgNXTWpNVlI1qMtiMfPL6vVi7Wklo9cmmF68rB/8tEHKU4Prq5/DZj/pvOqfzE7KgPolKr8HyM8TzjUZ
# DATA Y5OuELRvNTOda0q2AfRCd1Zv3F7NDrLsEsRGxu8ylh/OHi1TFUwyB3ibTQCvb+h9SuHGeqNau+9FeogfOPHFgx4itsF2c8OOSV4R
# DATA EUiEVxONQSKrkAvbp0eoHja6Sv6CpiD+bqgb5fGJ4XNjdqOkT1+trqJaVveDdwn/9Il3NgeR5eITpLH5zs5IK31+7nRHC/Y4SmGp
# DATA QbNrtqhMT1W3FeG5v/Hx9sMHGzttANfc+HTP6wnNHESY1Lx5dVWZKWLoUy+0UYa2IkzqzdWb8VdR6nGWdg5Hs6mxJOOvFdHAeaOP
# DATA CUByNOTzNl1IP7ez8e+eqMvlAyWpfrSxa8VHB3+l4N3pheWDJ9wQvBhBB4TysgnbNNvXfaLvI0PPWIjbVivrSAdu64SbdCNdaDQg
# DATA bqt1e/hwE0xfofnZUNADIgil5g1P1td59M4UCWsaqqaJGvkAVvCH7FxyIe82QYKeOs8HVh2G/ozEjNDqFljwYcKa+ghYaV0ckTo6
# DATA W2hMQ6qmnvxwNpqyP29mSENwaGwUdi6w9SroErtaShKrqRRn3OC9YmyA88mG6xbPZiw9V8SfZydVFVZ/fwk5bmdjC+iCFONie4eW
# DATA D72PzLyruVBLNNUKW3oM8h9bVXmZpUzlbRODnc41acLhyjQRo8t3t7Y/2SLKqiUrt/NivxX7uvoDs/WMwe902JWKMKHrakV0XYvp
# DATA KKrVV7TPLqIPi+qdo5oLVCTBkGIKh2hMcJXSRobjksgeKG0uoM3+ZEcO1glr2fj0/sOvXM3Nqh8IhylRdrPyl4aNFxL/1dFgVhwL
# DATA ecbMd6A35imk89tzHAx4h9ZEsAB7GOTDQnGQNhr1WwzYD1SoDbAwnGmryNUu6KhlKlq1tA5EuZlmOiFMFtw6uR/qg5N+l6dDdqZk
# DATA 5eDEjCYdzCGNu1a4IQpHO5yqZYBOBV/GBvznpiL+xznnFeItZGqr+zMSUd9WaN4WP35z1IS8dprFiP6F6Vbj4eqxr/loi1NeTLpt
# DATA 5+yqg1RM2yXH2VKjhnwVnFsmmNRmiaGPg/FNObMT+EVU+e9M+Luzvxmgu0q7m+gYz15cbalOGtz9TBZPjvmkUVC4ZJBJGB6XZxI2
# DATA totJ3lX3PoGRPh1NUadGQZoAqMnptbghdZMT+bP4fdO9BU0gsHyMZJILNMajcS3zNrwu64YlOWzEsbHM4VTBClL9pQemlGfRd18p
# DATA 1+LMy9SoztosOgOZdsUvP9kGjywcejSj82J5n738z7wxTPpnz9kZlE+4xPeS0Je5WerbFBfI9nY2QnOmf6YACx2HnazQSHCB4kMg
# DATA GxOVotTo0azQ8bCpXMlN/Re5ZgP6d3s6qjEeJIR1qb1Xy8omsNrRBRfzbfx/yqw2cfAROzBcUZN0IrWhuXUz6qz8e32U9fcsJeEu
# DATA ABNz/Mty6JMFbE4lBkEBGOu52i8T/WpWOtddchNa6vhey+lKaele/1leAKXm+ItGcdy5fut2rbz+r8IZIgo78xYOErH/XcBpomRt
# DATA 36EjxRV3edBvQT/oD0d4BB0/BvmF+pk15/pmLuKWUH4ObdJKt+eVnxHDNR/P7+Mhh9pLh5ATdUeFJPS367ambL4rKq8P1thcKNPr
# DATA 20yQPTqN2RjcqmrY8PyP7Mwuk553ge9ISWUmaO0rXvzF3G9KOvq1e9+8y9EH7Adx5iznCYfDe0BdreivmgzgjV7tS8WmCzgqsITs
# DATA kWxzidMqMhaPskz2z+hYEC3GVbIYf2kJTul4UceAPzxx3TE3Sn+7MNotc5VDmHdE9Yr7Rnd97m7snel37ZKWzOf9IWlSWROFylRU
# DATA RVk7G7xWd5vQ3nY526d9jI3jQx+uDPEHYinLvSHu244vYuHzPwnCS4yGEAvyRBzgrLmPIsYcKsAKWTv3wRCMfcv5IGLnKm0DV8Mb
# DATA 78cbn4YDxXILhSCQb/qeVVdazTPLR/1h4nQ4NIzFjGIRGztWV9l5LHEhQ6Ts+QKOhsBwFHlQUvFgdAqwZTGtoX2r7jImTtORgDFD
# DATA zATDLiMbePnFmk7g5CqSpP6Sqgj8kjaQ/HgxDGFchOfOm0OCPKwPtyz9fVGLIAw1DUIrHucTBFBk/48SkOQ42/ngye5noZ+Hc6uX
# DATA sq1EFKoSqiM6utgMSW3EcJpGwCQp6vmkeNGdTIO39BgDcpXM4mSm4FcP1c744CGk81hbREMXQFQ5V4tFkmCoeRG/tz4IFqsayfoi
# DATA i3T5TBtt1ReEnq4N8iOIt+s/O566jLY4LRpAiRWtOXFS9SgGO3uVZvEk0ARQ1T9kLTAF1DfuP3j4kPMUzIq8jYH1AkrnaDZk9A+z
# DATA pbgKwnxUG6Qzva62FQZV6U6aryqzUjsNNDqTZ9gjTHZPfeu2EcbR/AKHjfZYPJjzeqbeH7itACYMxHi3nEpC/SjMPd4P4Y+21vXq
# DATA t7Qm8Br/akeUqLrFmlMBCsas0ocXlMGw7lTjlsI3uth1SnVdmmOYwa57Ynxq1WhRrXEOC0AQqUFc3/1s18CtI00zv7Yfb23v7T55
# DATA /Pi8Yg3pYPDhqXXRRRU0f4qPmifWhILw+eTUCAqWYqoOB8yUo73W7+1O1MzFlPfUwuJNTDMc96fYAPXK+t7m9hbpWnZF/tqFD1nk
# DATA jMw9XKWnZ+4Jio5mfW/70eb9tjYAK37bfrK1/r31zYfgAi79eL6W47bokQuOHS07KWbwz+DoyQ0DxcTvdonhyBxFr0p5zNiRl89Z
# DATA WKlbWu41/mTNh0W1wZNVxzFc1bnHyAA8lTJotGWhUBk7Zkshi73cfiLzFs+cNAp4p5HtSVe0K3PDX6e2NnF7nxiSQagdiJQnxEvX
# DATA 8GncTohQiPD+KBQhmRpsZbqXK0lKrRUp/G2EUrjOOfRGt9cSlaD/Iz0Hsd+vvGDDgi5tPT74/YLBwh+s3//uk8cIeFoV/EzZZwJh
# DATA Pa4CGAH4IljqFLkDbzF0mBLfBpboqGpg0nmpr9kldwTndmARYTxXj6qbf4jML3L92nQZBq7fOix1cyVpORuoM+keg12gWaZ/4AKq
# DATA rxJTpkIj8Q50CraDRoVQZ2y6r1uXwHg5gUqBL/W2o1hDuOPKEDGqwRjcay0fYsdRal9e1EN1hJ4QnLKDIFdsLaod4NLz1QNcMMsW
# DATA 1xDQiU2lJGN3lj0FziWZQg/8bSgLlxyOaOksksjCbFiPFoCnvzzdSO46L0PyiWKLVfLwxMyTuph8uUrVsAnBHzwVno1HiGkuKCRy
# DATA Am41uXPYBRepJ9PR81yJkKNBr54M85eMq1hnFiUxIvQ6xEjbks06UNJ1ij4WTTtinmARFom4l7+AORXfuC8XupXSHKM+7LPdvY1H
# DATA QgbU28NpQm2WmsDJAhcgnCLh1uAFeHM1GGm+uupG45StpFDjxLe0CTKJlnRpsNFaGyLaTNY0HW1W0rN6IHxJYtaMUDJNiZu4ZcLP
# DATA ae83k7c5SjK7CclEmj/pfUbOMg4PTV++fElhZ7AJFdmK71QooF5cLPaYGaI3v7gv1N98hFhe4lwtIDbI3Q65IwY9njYlT+Uv1d9w
# DATA 4JwphDK772AGvVr1ovDZTulwwwP841zGTZndhLxZu956GHvXkuvzZtB8Ia3t2l/PWTkJeEcOmVEIIZKJjvrDfnFcRs8cPSjfIISX
# DATA a34Im9+XvnDnyIyKz4IijnMglohRBpExahGKEjQd1T66FBX5Nu1+Hk3mJD2gV7ojqCZRNUTCgDl5H5Wr66nx9Y+LdaAFydteijc4
# DATA QxWNG9UeV1GnWc8i0cp0I3IZjYw45EWu2/0XJBgsimiOmXlbiar5gTohQ/SVK92zUiXJxUPzn35xaQsgV1AvOY5vL3YTOXPpGFMt
# DATA Jlh1QZ+MJG7JybuTyRcw22FnPSEVER9DKxYVzeKyuxjsgUaml7sgJrmHl+iYNL2gQB/HkPMlfFiFg3piftAiRET+6GzB4i0g0GOx
# DATA 0ksELfLCtwgublqNxkp50GqWSkqczlSPW9d5kRvH3s761u76/T0bYaSBz2MGcXupQam09PbkXh24IlJ9LsI33I25dBFhNPKpYDtW
# DATA RLScZS7Xy1+NlSiLUY1iHwT5p51FZ2x2unjCudGVvOW6tBdRj8y7iHRnE9Rhtd5KhmI70QvNnaBNh+/V+bdd/kwbJiHbE5Q3/iSY
# DATA NCE+ncE1VHff3CftebepbQa4Wey84xucmZbuwFy1P82rK+pSMkhBdJaqBJEqXZLcHY4YcAEVAdfVM3NvJBujYC0lTkIPPOk/wwAu
# DATA 92i5ny65RvFwXFRLVr3pL3jbt2fsWe7IcXp5YdYpmRVPRNQOYm5EPFJ5G4r38RL9tGKj20o98Q+AL0rHjwncN7xR8gferi4fu92W
# DATA kes1dtU2GpFxUb6NCKOipz4QXKk4GpjqqX1Tp7txL9BJQYHq4XmooEX16JHBMeO8y+02Z+LFElVoeC4ylMgAJAnEDi7GVdg2c3/7
# DATA exs7n0EY+IcPN+/vpVkV3TLDnX+8wmGFKxkuDtk6S0iWOe2mT5jpiD+eSy0rB/x18kYucMUwHDelbzkXWwjnNMKb5qfj01FgVpao
# DATA PKKsjbClWf2ZlQo/0liH8+u3pHvA1zVpIfSXgi99Z3wHYaWRZp+xvWv1O0n6LB/mE9yS6kN9Tjy9j/FUbBqBzfguzhFGzvUtWV2S
# DATA p/3OgCKk9Wl13HD4YXkcmnHJiEd9XSQ22egcLhKerDv4jmK9HDWNjrG4eHgXmT8Mg+Awf3C5igVuHfUnGGQyhERMXML3l9B2fixa
# DATA nvbXWxT/S4uIKEEx4NoYNl3tfR04yHihW9TcoqFbsfCRtwRcDqFy75FN0IksuULutjpLRrbgQANtnrPgID2J+Q0Co1i/ZchiRVWx
# DATA kLDFeuQYmss65owdlXr6V6CMM72th+B42duOIBYuvEgcQJWPIQCp5ZMXMV9eF4JP6wx8puraFpdKJoOVlFlYoQjRZWYAb2aQCT41
# DATA nQMdG8moYEDg+HkR2EeMI2INeXfswGc4/MxwLskyOOspY2qIG5SPr9FKJ4pojk4wPgRjzjU4gLioSRNkJRIHRI+DwpGrMrTpcDQa
# DATA RFzhdSesWsw8Ii8A6pq5cUcDAgxSyML6KIDw2dg1wHJ2zRyHHcfgZs+GVeVEXMz5MmZLL6q6tuHfgfZazUpMce2EoNN02zgXrg1+
# DATA +5KBKVQlVUjCFD2fWEpe5VvlnlGBbYgwEqHHQpRzbiJLwl7tt0qySJn7vw6AepGz+mcRY5XplP7Ov6yISY5S7wVIBiFsBBTD3L2i
# DATA 4VySXJjeuQEzLk0QhcTzA0kmRBF+dnDux3rIDXXpDbTYJrqQ2jHCB2LXjMgo4irUcrF58c6Tti6yf0nKoimCt6AcPnMaKAt92z9w
# DATA Xdrqi31lIv0qhIe6/7l544T/lXagcqvE7vnwjJGXnMm4zFRXAD0R2vao3yU34n5Pfdg/6ucTNOWIn4wApbtfm79JLN4mSKbwRFTX
# DATA aoV8PLOKzCIfaL1+bUF+79Eb4v+c9K9BQ6zxSAmSzLDMlmCZ+JV+49zcdY+icFgXhsSSgJEOLpZuR+Bi2dj+5zlIED6uT2D/j3DY
# DATA Si8AX4b13YRYSeSlo7gocOS0M1FXHIz3hm6uJAE8BnMuKtjwMUokeBGWMA37fq0WFOvmTbe/DNBhkeTOeGzXJMYPQwgqskopu5/l
# DATA jcmzweiwll5Ls+y8Dlh8rUHn5LDXwWJNP5NYXWcJoUiBmCbWR0gZ5qz2Cp11KpyhnPjVptmkNpK1qSXXeNgzRzQ2NdCfR+TKoDcd
# DATA Zdv8fXBe1jq7Y0nPC4dQOk49ZoZKPHsWUc1FPXscM4TR0lyJeIAsGloudd0XdWNsO/ZJ8SjIJiilJ6Z6vVRIiVHeggQu5XtOVNiK
# DATA +NWVCV9lm8+RrSJjslKVnikpVGl0Q0z9HV7FqGDdKA7btrXS21cULD38utzLIFJ84XvTRxtbGzvrwlz8lV6dLnu7sFZ80SMqlXlx
# DATA E1xURIXIRjXo84L+EboyDMK5UPREuujFBjyLSu+RmXNlrCoX93+qAuwxfgLtxxtbD1y8W2vNKJGBL6K4CQ0XkQ2L41vQJ4JrWmic
# DATA dn9HSCGbo0nMKbe4xxwRaV48vxBnvKawNggC39bPwFuWWtQDeytbN9OjXttbl6inPl+LqfH5Xjg2Hkk24S+S+1qulh6zfznweuy0
# DATA N1eatNFYi7Iw3jTWzlj3+mB8851DX83X6Pu3VAq4CgFvGp2LhTdpJW7JWKfD5eyQpcoAwaAD1ob6PyXCvnDzWCp5cYKOUJRnvbE+
# DATA eTaDyX6Mb2oC6LmVbhIDTw5nw55i44kif51BAkRWs4sCCeNoNk1w3kCvBTkRoM9FwyTUhZoBY7zd4cZq6fKyxF0DvWTrsVETlH1B
# DATA 0mZlGYGzoiaho2bGKFErv6PZW56QU+di/WEJCNhLlyaMhImp2jjVrcEcXeIz3jYLd1CT52WxiTQfRoA1/g7/gS8L3DBZNE01vG5A
# DATA x4PzTwc4vPKjKwV+xh0PnHLwpZPF0Zr71ZsYe/HLaDFU/2YVeKXdjYdN0bJ2XtVYfjhTnSkSsTuRKEansm72vtkK0Atvnwbz5Iic
# DATA 7gTUndmql04Cv4mqSkMr/vx5tnO22Hz5k8Pfd+wU9pLZUN3NYCZhy0DVs0JR1ZI5cSwi0TnRphH8YU0TcgtUzcp40ldHQgAvU9OL
# DATA IC9nAetYnWfGiuCCBB04S7EEMxX8Gy79YX+UXAz33BbgDBRTdZ2fBB1aUyTfHFeTcAZUbTbJioDsNyf1YCluRXWqACB/uLgi+lC7
# DATA jYqsdhtWo91mLwTompJvpzXkOWrCvnHx/wFXwfXXusPG+PQb7/h/q+p/t2/exH/V/5x/r6+t3bh54339jJ6vrb3//q1vJKvf+Br+
# DATA NwPsCNX8N/51/s/PvXZ2ldRTV5tr9asoalxt7p9d7feuNq+iYDdV9EEdlav1q5ilQj1+/bdvfvLmL15/8ebPXv/y9a/e/Nmbn775
# DATA yeufJ6+/SF7/Tv312zd/qp6pJ6+/hL9ef/76t+pjIfBAFf+nev1Pr/9eFf5JyVf1RP37F6qF37z5a1Xk9a/hlWpUFVVV/gpaU//3
# DATA K/X0129+prrxU/Xv36gPqUZV/Ldv/kq9/MXrLxqqeVRhXW2eXdU5VFQn7l7pjRAGApNe3Hv6dHgX/kgGSsJqPX16NR+q/9y7e5x3
# DATA evfunuTTDmYoKvIpvETtGb7HN3Bo4fGLfv4SYJHUn1qDBo9f9nvT41ZPSZXdfBl/1LUlYLlQwl7eWrN1HU+n42Wg7y/g0/tUy/Iu
# DATA 5C3rT0+XH48G/e6p1wALYcvFpJs8TYt8cPQ0vZPQlPsPp6eD3HvWP3nmPEFXueadZHT4A7X8/GqomBYUPuwU+bLqi3gEoCzLJGbZ
# DATA p+HsiE3g9X89edEvZij1TvPD0eh5gulqlJT77BjuJMeKkRyPBr0CWeH0WEnGHcUWk+IEBGe6TEBC5QS03eq5YksnSd4pwDwxHQFT
# DATA bCS701nvFL8dTXr9IcAuMZKsEuhApD4BQEjsNW71e49BtQ3izRF4jyQ/Tv7drJ9PkxejgRL97q5QobvorzPJBzCMfpdGprp7BL9X
# DATA OoXaL8UKPG8UL57BO5QpoeyJqn5FPXzv1ckAW5U14SoVx3k+jdUHS9DoFsUFP0M7n/6MlgIg9IMiP4ASINjnk3t3V6ig+gNPAhwT
# DATA SPeHWwSVQPC5JBVYuzosA1Ul9ul5fyx7801gX1BoV72A1eF9cHelQ6cNWhXfH8LFwhmONe1BNe6qqDqGnRdKRul3lgedQ5qWRyA3
# DATA qcf9Zx3efNBCSX3bL/IJnGOsS5Qq1P7p54UptzvuwAFO+LlfHLagKbsD+/HlaPIc1waLrqj+8KTCgEk07MGnen7ucmomOxVjsPXA
# DATA F0SZ1u7tHXfUEo5BJjYBbWqLq7+VrDZsqOrX7t0dq2J5At+q43GaHHdeqD9GL0C7C5n/jvEAQCpHfA2rgWIm7NRRI1HfqmszusMp
# DATA SVydtikcsdPRDJYOPtaKKn10Vavje3d7/Re230QaCn9nHM6mU+/AuEvxgRIydTOHubr3At4uT7RXC5gHR8OeOtVOfYss2orqK+xz
# DATA mu3ItPMDmvTr97YnybivOjYbq0lSpOVopiZlNBrAdF+H6b7fGXRnaI48GoxQ+s875N+dILVPepPOS6A44NcHM6zWy2yOpDfKaSl7
# DATA +RTQCtUNQsmuMzhbquNg90XgGgQy6o6UiN4HJTjN+kX2nxnvCmy4e3ePlCgPO3Hsnii1u+RUgNaXbglQr80dpepTBe/ptXe6YhOR
# DATA wTfrSNn/qHMyvgPy+otO9xQ6lPy//5RcqP+0arrXK0CU4DwxL1dM3zb7B27/B24/j9vTtrwEk3/HPP5yLH4+h/8fiMG/Y/6+EHu/
# DATA GHf/Wpg77Ug5fMPQ/+WcICT483mnovSjItccdF2zTVLnqRaRu2v+KYcMck3HDnN0xAGQauxqW6FahZeIp6DbnyDzRQWeNxE4PSjS
# DATA aBZcoDptkHcmCOV/opi22lmDOjJgNYj+Sd5LDmf9wRRGAPSxoCGrnj4p4BOUtnT/9AigBcvRu1oeKHyBgMSB0XBw2kg2p1qG60Ke
# DATA b+D4MHGKbaGm2Zq1tSjQ6QGHQfUidhEWZRnFAjjrRYE4Rslunj9Pfqj2CjhraePCcT4Yo64KOpl0jo5glUAg6Rzl01Mzws9Gs4nl
# DATA 0Tw0JekUyWQ2NKLmITg75ZNGssGJhmBKYRyzMUgrIGfqXQh7vEAZRhWAFAojEJIUeSigTGdwOu13UbpRY8snU7DxP1ND6ID/hXZt
# DATA g7q6x3n3Oao80bSDak+nM//9J/9bwWMFLS/6BRXd0VjVg/KkWLNGch/WP0G7PCJeqIGdwsi5LvgCuvri/2PvXZscOc783q9SDq2W
# DATA 3SKAQRXu3ZyRhzeJXpKiOZQYDlEvCkChURoABVYB3dOanQhddld2aOPI4RNxNsIRtsMR57yntKJNUxIVYX+B7q+wn+Q8/+fJzMoq
# DATA XBrd091zS4lkA4WqrLznk09m/n94RTSlkhrpQNnjSm09jKkvmkQVtgNBMYGhLHk7y2NObWLBhU3P0B0mRzw+GKAq1vze28nJTMw8
# DATA ZKTsLBtQjcGOtVLUpJ7KLRmMcIoqtXL0cINIKvo4yaRosacwZRP/YRTN80YdDgaw/ScJGsNgwNePEFAMhUQIL3Fm0uiBcLKa92HC
# DATA 9y251Oj2KOUiQ16aFoVA54jwONKdBFWfD9DbxAtJAgVtNxfKsSVVbq7mqrXqVhk9ImMRSTyhwExWjHjyUijI9yjGZuNSBnEP7MYb
# DATA Sgfj4XgJlVAa63OlwxBRrHlvovORvQcokhTjYkR9i6qu9B6c3+LfpEopa//K05zdBpudZjg7msm3Zuxfxda/BlO/aDSRvf+dx/3k
# DATA EZkvPwO+ps+1tEpXnuChx2TxJJNJtR/RXDhO0oNsSkGPnyDcx9MwpdpwUD/ECsdRCtfPwXGY7lWr83AepfuHg2RCj8glssv2D9F/
# DATA Hfid+aM7fq3d8uQXhLV/iF3m1OWfVE/ScH7Qpxr4sEppGz4JH0sw8YwaSLw4hLZ/dYmto2TrRdVkNKIEHdSCIJo+CQ/GCOcx3zME
# DATA C4QbSZUq/+DhjNruQTB/9EQqSSWezZeLiuzfquAJjDWPOYrqXfrOmvx9PIwzGoZP6Wd+9WgSPTqk0eJoVuUtfweDCJjow59S64xH
# DATA p1XVvvRlmp+S0YJx9aDZnD86nItxcEA5QX2m59d8/D2UEjjw54+8jKY0Q8/Kv5WMRucxWxRzmtKrL6vSTMNhvMzUz/KlQjGQ8qie
# DATA SJzarfohTaUyCmeeMO/6sJSNB5jAqDypmSamcye/8tiKJnVTs0x2TK1UBxXUj9lCxV7uLBrexaLzTx6vJJSTbwcgVUwFcUAlg1Fl
# DATA +DiZhwOaDR7UWi2dGjUHpMoxIgMhq5I9GGMEUo8WL3KlKF2TKlK6qCtM+d7llJrFafHqY2raqDEHjVKh8l1U9+VnXZepaJ5IPKi/
# DATA 3vsxT5F4GKdW+ZN96yKKMvnJ/kod5pn0gV+vf7tQ6dpU6TbULrx+f/d2nFdd1Nxax6q4urI1dCJK8a9YFyX+KroBNc1DFVX+LJW4
# DATA utqJULOrZuOUvhzUnxSCI1v9J4915OpPTIZYueB36xQ2Vbb4Z9EBW040TD3h+ZFp30dpPDw8om6o1uCUFZpJvS531zhJ5plNnQEH
# DATA 00Eo5fZvh9qkUEegLlD5P95aRjp1fi1o6VAlAyle0RGN4o/tgDv1unmk7tWa9MiTsV8ZB5VxozJXXXh1kczp8bEvvZ+8DvMrmMkS
# DATA UAWkZYx30/leUGvi1ZV2rXV8UmnV8GWfevR6U8VU5cn+4YQsIaoScLsiAvIrdQlM1qhUa/VGix49nIaPVBr89mB8qCLVT6h9Timh
# DATA DY50sFvkfOlOKw2KWsAZj6j53QuiRnEJWsjO4rv5zQ15M73EU7lOITbKARaf5JbxBBmsk9buDMZP4ulRJTs+MrWGSWiHVntVFSRc
# DATA LpInMieu8D4DGdFVUwEuzg/qVJErmDDt4Umv6rXRp5uIyCBlh3RhXS0PXOwup7F/cRJFM67Jfq1Vqsp+vWW6FZNt62rukxp7LyQv
# DATA O5KXTcnLYDUvda4FdaoQa8chmksUE8T9AlsP+I80vEANrfz3CbtDLsyFcjvd9HYvlJFLefXvwgT+Sdn0ODCWymGpWT6pwRv0GOIJ
# DATA fOMofhQND39WZR8MpfsQjbLqo5QPQdygnEZGb+iiTbeAdHLIMgQ9Rih48kmNTJpEd45VYQa2UXbFXo/+Y/asoe9dTmfZgT9KPfp3
# DATA U//GDZTD92pkOdBrOK3cxWqzJi/SZosagtw9io+WaWQMyfzqIGRvqBVOrRukeftEqmpdfq2aSlxcF7ql531pozVl8JeyplXPqzXf
# DATA vb5Oq4e5QypGYefGZGcqdd8r3V/LjiW/yKPOsHgXZR1K7vEOZZlGc5oV7jUqVM+pUPbqFSpZ6jbyGD2pDcJ0+NgaWaxRp81DfbkW
# DATA Zst0hCPcF9gX281Rea83P8DsvzoYx5PhajL5lhrc55XadEmT0se2gcBXKCD8bleenuThCbbl29ZAb22bWm8+t6iTbdK/Dfq3DdOq
# DATA VE5cPwsFwD67YnPZYKibAQaBlHpDSfPBbDGWPNkLZvueTsumkghWrbYnNeM3Ldd16gYoWegkzC2esgYkA83Aj6EVoz4+IET4Kq1B
# DATA rtNF2+arnj34deq4TumJF7vUUcpM1ePo7qXQShhq86QG34Kx9oKbrJd4Ey/mrJqIemypifl2iRYYrG2BHJZsBnxc6KzE3LP7eU/V
# DATA uS11QKWMx4/muhml1RYa0h2djPmwJHqrA5qUcS+qY3RASVmcmjTySFiTbesFG7vW0lazan6BdCvaF7nG0m7aqasf4q4qL+Cot+R+
# DATA zEn8eAdzozRHoZ6D5k3xIHpsZ0l5Pqabo24eMu7WpFBoenlkGVEm6vUdhgl51gsx3aD54A6VpFA3PPMtwDfYdKsNwh5Tiv21V9/N
# DATA QCvG0ptbA7P6KaPBfXb0uOQ3oAYSHpW9I2LabqmbpoACmUSmxTrTba9OKjc0zX5Ysm11S1oZW0t2QbkLF4NABenJpBCPHPjWPMtv
# DATA ck8pTSHP6LLzZhhm46iYwT8ex8NhNPtJoQH9K8EDhrPFE2puj40f7BGb7vbcCPOD/H3NC5q+nZXdTQ275HYLZ6cncEM/wdqIlPIo
# DATA nMaT04O3yMRKaFyufPba+3Ff733/IJkln71WmdIfDrfY5ikvhzQOx5PMyqZg9/qofCmPS16pstOqZK/rd3qF2S03YTWJuqi5HhZH
# DATA R45xoCY+eYgNe7hfZ3TuYACWq3w3j6XV+qw60ML4qm4ouDV4prKbf5J67NxbXZqJbqgOtXk8mVTT5ORiK1vZ1Itobkpdd6PN/Cd0
# DATA 4qb9N1UHvYALj8Mrt4In/JMuOOoiJ+E8I6tEfbAn0HYN5IF5Ma4shjIt47w4QGwK4+hOlXGxzdZ6UqMYRI+5J5cO/MC/U/V5bLR8
# DATA RJbRIDZDslzMlws+kVDOLJlT8S79KpZt1lizOJ4WLpL0sR5219myUqN1R2cq9JN/PY2GcbhnmWht6tb2H290OtiehkYbfa/yKhRb
# DATA i7JJVkcnrixyigLTXckmu87w/HTj/LPUKBuYudpZWZxPGqdLi/tqnhtdyhjTxurm+NgvXz+FbGCxoThD3DFbVgyGzdPyYKR9jC3L
# DATA StEP3rPnUnb1DErmszZjV+tFs8H1gvOwoq3cjfFht4y4XnhU7+WFU5hQBOKmU1PN4vCwe+p3Ti53ImvmP9yRU1Uy6Z7zkmZWTaPh
# DATA chANq9OEi0W+UutYtybGgX+n8p0D2fRBH8IR2k04i6e5yygf5w95USRe84uOhpzO0W1RmmFFL0aVHR5iH3NpKvPDcvnKSp3VK7AV
# DATA oOaGfZqfPjSzjfJNT54UVgz1ri3sEKQ/3qPpZMZrn9iXd3DnzsnJSe2kUUvSoztBvV6/ozZ4YQPRm8kj3Fj36l67Sf/wsi9qvCcb
# DATA AOk7X/SkI8u/p/ycH+DziIYg3jPVqDeGzR42Pt57g+VKeLfQB37b83vjRnDc/X7QPPbrY/pv9/t++2eFh0fBqDFqyMOIYnFVNKMR
# DATA Mnr6RHZpIk+TeU5BMlH72/jGfDMWVdz+KX7hfXP57jq1+clctRedD/IdPWYPQDTktfBTswHPypJe3Ws2W16j1/SCVn3SqAee321U
# DATA G/WO5zcbxYwZtof9qL6aq52G1+g2fuR32pMg8Ku9lhf49Hi9e0x/30fQrXpQDCoajXzOY54uPOT0f6vZatVbUX6xaoq+sfJShNr1
# DATA j5uBP61XA7+JV1Z7PY6MiojnS6244huCoO4FTf/YDxoT3/e9VvdHQa/7sw+ajZ7X8Kn6BN2JX+9Um50fBe1uMXndQS8Kw5UgOy3K
# DATA ld7YD+rTartO/xzjY5MuN5rdse/T5VaL/jmmj6WY99v9enO0LubNjTVVbV+kinqAk4WPlSf4QNXwQ57fH6jGcqintgffarfa/QYu
# DATA GO8TPcL/OzQGzeqV4OBbkR+1os6h8rEdfKvVa3c6rUOxMA6+1R8NugM8wW5n+nnYbgTDQ1neP/jstQfRURJ5P3yPpgufhGOyPSv3
# DATA eftYRl1hNYvSGM/qLm2n29E91bDbkkymvEs/EGvSC4pO564YAuZ2Mxqp+c33ImrTcViRoEtLc4dlRxiMs0qn1jw+qXTEEcYBq51y
# DATA u0zvt/q3aKZaDLHsKLfNPFUwqw9oH3pxnCjcNS9YlWJy8g0YfwYxdhI9vsTyQL4WIB7AklkkTqv65YwbDy7a8kaMolegvtGYLaS2
# DATA spK0i4w75dlbqWNsNtykpfJkta3/FE39s9ewe486iXiw4J3kM94A6f0V9MW8u/fMFsja58soPX3A+wKSdC/bt+41N99P0/C0NkqT
# DATA 6d765+5PJvSo9azay/c30SmkF/UzaOE1bAek2PLc0nvd++y1AzuC02iK09mCHfsgnO9xoIYVznLGD6PTijcKJxNU7n3vMQ78038l
# DATA AJHJ5z1lDyQSIFK/R1m9Z0XqdWiU7R8aqjDTVeily8nE+663J7GojcMML9unS+oKBSVXDqwIHHg4+ilaBCy2f+g9wVHlwZhipd5w
# DATA mRDx+BM71XyoXpKtULGP9eOZPK5/OFR5UUh/tiH9FYk3asnsKB6damyVyRZssVmTlhEOd69GMjzdw+R53xRFBIHav9r77LVvief3
# DATA s9coaIgNRRMgWmu4W53OoBvx7bAU5Dg52RimGKOXDnO2nO7Fw/08NR8up/0o3eMwP4PoH/1a07lZeHSoNpHuiZwbAhc9C3rTZ6/h
# DATA 6x1qzvHsUB9zkTMur+WxX6aI/g8/fr8mOy5/wMdD6DvU27w3oaH3Y4Tzk4r3GAE/QWHIo6HdkOTpdyYR62V89lrI2RDWsPsPmjXp
# DATA BN90fNGaKMa4NJjEg4fUprD19JN4GiXLxd7ePto4IpVGx2RU5JGicMB9J/tVZYVEBesbuhQwm8DL7XxKZtjQvDeaIeEoGzzAQnhT
# DATA CH28c0yRfl9prVAY2bI/jakgK150zMV2jx7jjzWoxtDft2Vj1p4qag6IpuM0FfoR6B3x4nRvn8Kf4YYnKqp/hej9WA5chMfRTyiS
# DATA NXrwnXAw3lObP/lFEzKas1DE6Lh3oQjhK+Lz45+oN/4r6QHjjP/u8Q30Rv3cj3+iS4nyH7vjocu5L+HL9VNWsuT7azSqTJbDKFPR
# DATA yDtE+pXeZzbJLe5raXuUsLX1DVF7wI127xRqneaZYuXHO79LFfOBJIc6GPmM80ZPDnVU9/LH15QN1xe8TyfnOrJKf94hOygBchcZ
# DATA 1TS13TtGLMAOvuutvf3A+3Gtxp+HlXV3mIIiCzhDMjke3L1aiZFIF7IIvVv+jMlWsw99OR/qzeSFDfwq399U297X73E/lGckLN7S
# DATA nqnt7DgTSgbFcVTjFv5E/i1Wb7PgVazjyaO8gvMtmS42+slkinl4cxHKw1SGJhQUIgJZsQE+e23dTj47Wvy7RIw/SgS4GCT4vD7I
# DATA 77onlm/rqiifvLHrqDJBco1cy37ZFu0DFZfPIOE5JdtDapuJwqaasyE/dQRU7dFfyb6bHdFkEKaPx2a8Z95LF0u1TLeWDfXq0Byo
# DATA WF+zUG3yeqPqjs4fmKtmhOZvqieXG2jUp7kVG2N8i/5e7u6lab4nWqYm+zmTWZ+YQ/6u5KL3t39LsUaFoP5rukd/kveTkyh9izJv
# DATA z2QxNYSMxdf0KwtPk5WEhHO9xokJuq9+6FkNAplarHR0wa4aLLoI8R66bneaxdjkNZHTsu/99V97ezpqd+/qmCBSHJCpAibf7t5V
# DATA SUH9xS2yrEdv/lccBWlu/HFf0vL661JQytjByqHOfv6Smzv4ti935MFKfqB3rOcjklIqkjLEDSYQ+W1f3VMaPiQsrqUcwyjjgYNK
# DATA XpfomsbI7Qht0aoUSI4px60NuPAQvQhxVNWUMlkHsl+scbhRWRx7+3fvsc342WvvmkNhaCav78Hs++w1aXqU/u/Id54DcnNfJO9i
# DATA W91esP86Evy/f1/7jP43e1vPkpNkwa5WL1x4Ps1YXpcA+LAZBUAPrX8PGU93irfm7/L5Xf/nn6wHdYR2eG4wlcYtM8D8QKY7mO0O
# DATA Zl90MNsdyH6pD2R7he3G6hz0c31Q23jO+OfCCcCJdXz7wZzV8jCyxUPARvTp7fx23lbM5+Ser/PcL8qpxouEW2xHKcdfPM733qCe
# DATA ttwM9SIZomFWKrqy3mWt4MmFcMLfigfVy4tX0qQHCTJX3nQ6G+hoKD/2vR+srH2xmUr2QOngv/UMf+F0cAbM73HRHlC5Qw+Gygv2
# DATA ULo4xaZi8/xcdAOyccgnYnWN8tSGC5oW8nHkZZ/GNQ9eXQ9zEArzc44H71KKk7Tm/WAezfic74jP7tND6jA/V1aPwhqj1lGd9GQb
# DATA AmOYcDe9GYwFCmimdAN2VN7xSj5urSPA54k52mQtkJF9hHNpRobnb3DMGRUOp7uZ6OB9tDTuXm+Gy6x+JO+I6aflHGZDVvNgS/GP
# DATA GZtUyQhOHmoxQ1hqqtmQuZywBMBomZIVsVxVQ3g5D9uaEJz15qy3i6y3Yg1z+jpOX+eyZttGA/GmdHceYAubJQeB18C3CeE8o8Dz
# DATA 7DTetg2X2N3n2XJ1BUuO1z/Y/sCiiNqSo69xYaMTEjuWfQI6k5UXcG+6/4b4RHUDnPF6FApJQjPPme4qv8JeMd7+UWvxJiKtYU3J
# DATA 5w1RuDgNeb9RS20miea8+6gmPfsdjmMpquKFMNUB33aIqH7KxNNcMNFs1NrXGE3xjNDP2kvDF94QR6uKlL7HRMo89EbCHX4euQBv
# DATA vucfBPU37iTKKizf01L3tLbc49fVTfQhv+uORCtPirLVdW6qVTB6MG8GC1vyiMwGfoINiXRK7+U9wSqdajUUo5eumvkl6XniY37R
# DATA nMbpheTAHQkC8yeVW7JOa4eSX9I71MyVe5bBGWJCZnUAtjQVG43S7JeUKgi/GIPyAxoMqX8Wo1F7ra32jzE2mnHLZ0PRDLRxKnZk
# DATA zbs/HHp8JlaZBZkePnMb0nsfayhK1RMTATPSLiGbLo5eNkrFEKceB2/ELgx623w5mfCPSyzD0qAep9r4/2EWifKOiNiI7k/cjymL
# DATA RWJei0jpOo8F24yjQGYJDAs2pdETYV4TZ5gWUpJm0vlplSu21ycQvrd6OYyB/Yj1MjnTuIOXIuHSePmtZnsAdIazM5wvMpxLBpKz
# DATA nJ3lvN0cfg4UKz+ht3HjyEQzLxyq1pCbzSXNRgwuRueNFREfRgsq0NmRSNsVpReFCZaMMG4lSgIyV0oUPcSykVzyz2K7opSC2rL4
# DATA xrjB+nNayFk3dopxQ1xmRqQSFgz2KUFvMZToshh2Mhph+xdk+rgvyLxxckI/e1RCMlxyXtc8ZVxA0pJid4xxF/1MMuKOgfPckq8U
# DATA nxUnpzjoLUL2Zt5PMVxNzEhnUmQn7X12yoUDsnEgpHlCPVaeMoy8VZ4yyIZoRp2Gk4y3i8HSQRKPyBbLdK82pMIbU2/GpcTJlFM+
# DATA FMKMRcXhRiTT6UjmTmLEaH9ZMiWrcaHUBUNYBQ89rRSyJZ1vh6fcE29PKMpQXJUoY53GB8r/OIoiStYwHrG0H83uYKhB4BB7GLEP
# DATA garVQrZgMN2YfkFTxC9sAnqfMIbHY74gAmTLipmycAxSVdQJMRZdf3kqlfp0gfqMTaJbEvlxlK1JoJgVhSq8KqhqqjpZqey3PIEq
# DATA PCrZBE2QR500WmfEokgr2o4E4S0cxjh7JwOd2KlKTJJq78fQfxlSJpJdyLYfkg87b0nGBD/xUDyu2qXMkDLU7qm8U+xJPZXWUqej
# DATA OJ3y4si6uS0n6hPKG5mPg9E7xzFSMpOM2jq1IGM954vfmfiv5X7KD66OZAqo6XmYiS3MvZP3gRb3pN6VYQ9sSisQt/EhU+N5yOYx
# DATA pgZk+FJJh8tFjG4jTFmna6qUJ1n9VDoUcKHEbUwWAq6rKcXG1P7NLDmR+olWQk0EfSQEW3WC3044/AX2VSK3pS1SguZwJXDXyGOb
# DATA 2CWWXwGNn0oZWxriiYFrpTxdSKm4KfvIRqIMkxRSkeOANHZkhCsKsoVumKcIs9OymqyZT9iyspadLzbzS2jtP3lSMQydxRHgvOmp
# DATA TdD5/85/dfaHs2/O/sfZl4qR8+XZn+n/X5z/1jv7ZzBt6Ief07+/XUXn/Ff64Su66Svcz/CbP5//5uxLj778zkB0vqZA5TJ/BWjn
# DATA l+e/qXjnf0fP0TO4DfScb+hNf2SMzz/QD8LU+ePZV+e/1pH5C93yBwH1ALbjWDovwGwGnTKOL1GH06c/i4Jo9lGUUDhpPNAmWM17
# DATA 59F8IuPzhHvESPqGbBzPqbeYWN4I3TliFXEe5T6DfC6UTCZqfKKXapnfrVAdLCeq8FRLcWid4vxG9yC3DdZZVzI3h9fJq465FSZd
# DATA frn8wET0ps3d78t3HtGvmbDD45oa1hO1uRWDqQPs7Fhs14/Ywdp7xNYnCqeSuxjZ+EXuwSGTRVHBMB3TeML5yHL72QIz1dJuZY3U
# DATA RBDmUEq8WOHrXFz9Njs017SsZ4XZuTgZjrPjLIGbsAQ0cOeKBsAr4ty8tcH/Rsb+nYb+y478tzPwS/VczYecwfP8ta6bgPFYOcAo
# DATA nuKr16R3FeRBr5vO1UqiKjzKsxQvVeCbSLImU3lT8ZQEtpeOTxfjKYciB0w4g3ZF8KgiyxciqSOeMF5miZVaqKQvkNsL5Z+VY3Kj
# DATA 8DjBqKBYMzrGeIHATXg4pQe1xaDO1R3m9oIQi+D7gRlxEs4WtltskMwdY8cxdhxj5yYZO7uOKjtNc3a1km/Z5L+KxX8dBr+j7Tja
# DATA jqPtONqOo+042o6j7TjajqPtONqOo+042o6j7TjajqPtONqOo+042o6j7TjajqPtONqOo+042o6j7TjajqPtONrO80TbCVrhVWk7
# DATA nVFrNHiBaDura887MXc4d1XuYVemx+9qtwsKaa1mKdeb7W6RmxNF3ZECG+FwI0VvwIE22iwDMuBQAwmGpTL8ZrsI8WlQhq9BI3Wa
# DATA XjOoe6Db+K3exO/WvaBdova0/Var218l5TQbXtPv/cjvNcfN7nEQtKZ+x/fqP/LrjXGzc9zwi1EYBMNmv78mEa1uPU+EH/RMIhrF
# DATA AIJeMGytEnsoY71mJxirXLToOeaBFXpO+wr0HK6xFj2HKn+BntNqdsOr0HNaw2jk5/ScdtD2O0NDzxl0+6NhL6fntNstv3vz9BxV
# DATA x6tcjc240BCCjh5uCzetc1Q1eByp9I5PKl22pAprTK3B+HBn0k75bcrBbbu2xMRQd+FowfXgduwQV3E7aqLZNcYqyviQd3KMw2Fy
# DATA clD34N2oe7okC4Aebterr9Bud2Oad2T9pJDrpZsKa2UynJdgOIcb9gOsjlaKkrTOUyvrtltCVl2NGtp0Q8lrRtPE72JXquozNlN8
# DATA CqV9gY1YyDy7MFVi9OQFVoij7DjKjqPsOMqOo+w4yo6j7DjKjqPsOMqOo+w4ys6rRdmJR2K/Yd0DNf6x/U3qzl01YqqBS36rcF3c
# DATA P3xiYXoeS74hM+5yMDh1ZIJ5nZ4Afuez115ffYeq1Id6QFEvWb0xv0Ud0KC72M49VJCgD3GMS1o+m/KTUz6do99ajlLN+3fqDLx1
# DATA KI0PnqGsqUKZKFT1DfTDd7eN+NeUFcZmNknlxana4tEiTzP1jp+99r518s4kg7pLlQKZ6JbO+bgj6O4I+s5H0IsHwtxZdHcWffXU
# DATA 4Ea9zefhjHqpjhdaiy1Ow54/FqBFZc5ytRQlfBsPozAroFv4RDSULUEu4pEmo+5MzglrJRXeSlc6LbvrGXROAuszYixncT4lCUqv
# DATA ggt1Lnp8fZZdRPzWHAZVu6xW9euV7YoqyJ+UGrwSDtc/5nrm5gpvt4X8Z8ThmOjFmZXVm1XejUHM0ujyuajxbt1huk/7qRWFdliU
# DATA ONyJDk3uY3HXTYLuqkvlsL6nPm++W47Xs8odf9p8J/e5SmZ2EG2+T/ptTj9/2iIqLwdNtZy72KG2mjuGmC1a7oWaAP+5Leua/wJv
# DATA PXd1eh4gn3Sel/OsJLbJbn3TC4hVzTUvXXJu/Ms//UeTjnLErfyfs0Qp+pxJOM/1V9VSIu9JS5eQSICNlrAUwwxK8KxFDbXSmGoh
# DATA Q5nC+ZzqJOvrUseM1keT2NlCjv9Dj3UB/SOtQ8ta1bz4oUVmT6hyq8Piyudlt8z85LNuGvnBauM4w2WVFJMz+uglXWBfMNcUutcC
# DATA AZRVWy9VRHlFvWwB/f1/31xAutJL8byHYqCKnOkC+uQkoTaaUsfm6VN+mTJBqE9azuCJpCFpXvPeo1EeRs40ORZBCkoDCw5A2OAo
# DATA 4m4VBST7h1U5RVrdQpXW05eKScGtlYvpFi5bLP/4XzcXi+pipFREDnSQpDQZMS1npibCcpmnOX3WdGVdZfnkzUM0rKGYDqLgO6I+
# DATA PDlRRVS0I1manc3iwjhoXY4XMKKfvpTsFN1aQeX98qV7uN9uLindx0tRfRqmU493d+Vd3AmuCRxneAwtbCqZIyoYXr9AXxfJcD8b
# DATA ipRGxOqx0JmOZoDgSAmo2UA/YnJHvBBNDuyOtX9m6sTTl0+ejFsrnacZgf6ff959BHoLg2yUypBg6YBP2a6meKUPlaXNTSqcsHp5
# DATA 6E2XNP5MwhT75OaQT0ZGez8S41ENMGQigWEgzQYl/vQlUYjui9BU/tOuTeVBMlp4fVT7EKWTd2sY4/uURVNo2UAzZkAjDyYHrAgd
# DATA Dn8aYn+OqvEZCitlezyexhOcN0BOQaWCLPXPl7Go1UAFkYVVpAC1IvQ1NJVCMq5UQEUjUDyathForkh23/sw0b5HrSnEsw/lE0xS
# DATA oTJigE64E9cFq4R/noYd9GqIuzg4t3OlXcGV5jxnr4jn7LK87udC3bGw/3I7tlvm3DSQLrBVkyzKI3ZqbSR3P6cqkC+QaNpF2tD2
# DATA vseboHivtpJrZ3mvlRHdRPReTbm6zahji/MFk6Ca5xtJbHYmVcR3JGqQJ4lxXOROJkXtUw7hKaDcRuYvL+iKt8wEXwpZQAoGOyMk
# DATA CVlZC3tNrVH63Fwncz3NK2mBfwhP1+wI0EABjItuj5ECt5QFNfhGaWYdGDlRmNW5qKitJOqxz4Qs1oWUFuY9sL49bMSF3uZxoT7I
# DATA ZjbJLN6uCk3UWd7gRbtQ5xZyuPYqGY92EM58dObjzuajXdfcOqxbh31Kq3GjkXoz67AfCPfTVorOiYfPhlRxG5Rw3vuD6sXHBgvL
# DATA nOqnHK+tbl1ZL8wXkvLlsU1ri/byhr1as+n+kqO9tJSw6amC+7fg0970RNlNWXazbnqu7D0rewU3rpwWSoE3WSGmqE7DeMj1QRaa
# DATA vvuGlq9UxaLuBb9c9pwKS1ydM9Wk8/IiOA6Za/6ebVF5mntPnbptU4nLTL96B4o4byqYnhYa0IuLEMdC04JJqHP09JmyVJOJ/ZZo
# DATA rscTmXGyCR7pmZSBSFL7MatVSzYVKDR6Bs+9rTsS9C328OwpgRCeABiTXT31KSxx6Xtk3XEormXeV04xgXA3FmjUE3eS1YLL543r
# DATA ncZ5Xcv3FoLjqfsoKulSCV/MAH95rGQLDshSSMm0wAb8jwri983Zn+nfP519BQzfVx6+MZbvG7D+/nz2JaB8q3TA/372Fyb+/V7d
# DATA /dXZ1x6DAn939sfz/+vsD2dfnP+Snv2jCvRrhRD8+vxXuEa/fXP+c4++gEgoIECQCREHeQ7AQuYG/sXBAF8Eq7/Qd4+iE7IdeBI9
# DATA DyFdqyAA6NWnI8hH9CHZpTEg1PFhVfa+wuomfWYeqO65rzst3Wcv5/waNCEOj4yMgfhPosVyvhUBeB9SF95wmWGzC7VnBwAs2Pu6
# DATA l7ht/t9qsdwc/Y8tLCas5LcW6luZZ34nOo3mcUTWhr7/HXXBg8oQENpJes0YQFYPYyT0csHjvzqjRU3MkQB3LcLrRwFSX4NFcGrz
# DATA s3iETodh8Axxxna5NHkEDZ2Izy6LKQ+DFbWQOrfBAlsYliz9Lz9mavOJ3nuiK5q4VMkSZ8YNpnHx0WwFC7h7tdxs66w0vGcFB9w9
# DATA MQ4S6CyE67MQNBrwSobBq+EEvDWj4AZsgp1MgktbBLdrEEgVLWeHMQOem1Z1E0hAK9Vq+WtDFDVcjN0XD0+9ozQcLkMF/cvy1QfI
# DATA GBbX2Bg1WFyUOJVNn1iaP2bXE9baWBYxm0cDjPzGFNsJDmjGdVbmpgRnso+OMnAEfBlXwGoyqqJycj9LdajmQcUWx2dDsRzgo2MC
# DATA noqDYqsh+fOULmW8lqpKW5lvskjIkeUbTfbVvA8jAOTkgmzae7CEGZImy6Oxt5xRMS3kDDu/OHMYQYcRdBjBG8QI7jwM7TRJuqxB
# DATA fatzhKtMEa5zhuCogo4q6KiCjiroqIKOKuiogo4q6KiCjiroqIKOKuiogo4q6KiCjiroqIKOKuiogo4q6KiCjiroqIKOKuiogo4q
# DATA 6KiCjir43FAFo040HPlXpAr63SBqhi8QVbC8Ar0TU7AIz+s1LXhep27geZ1ivg4HUXM4WkPfawc2fa+Z0/favY15mxfM1K93vcDv
# DATA eL7f9Lodr9eq+q3A85s+lRddDTpet1vC8nXavW6/uw7LV4gy78NcjS+90EIe+h0T31YRMFmP2oPOmueDIMifb9RzZGJ3t+cb8kqV
# DATA X60gz6/dnm+2rPg3rPze8f2troV8bDY6l32/37bL28/j39gx/nZ9kbLlx5u7Pd7u2Mm3YY87Zr88opLf7l32/cXcq+/w+stAIqWR
# DATA aEik9GUWJHLQCYcdvwiJNI8YSGRQb/RbvQIkMug3O+1WDokc1If14chAIpuDdrfbzCGRI3/Y7o5uHBI5Q39ezR6e5usccoTyOLqG
# DATA dYfAcnVom4vtB/NabREWTB95Gc1mMK1fs4dFZbgdTA3aRUX73grFvlNbObsRKwsR1YseiosoJajvUVnyeNdcq7UtqqFnZ4u6zdO7
# DATA Wop5o2et2CdfcLSWgI5bdiio/QiSjmpGP0yjA4hebqY0mnyolJK7xfQrF3Jla3mxM8UUmdiDK9VEzKdgl5ziEBwF0lEgHQXSUSAd
# DATA BdJRIB0F0lEgHQXSUSAdBdJRIF8xCuQqxHEaHt2FqUe9Os6YUZLvyFd9kgWZoJCLH9iKAmhVr9PTVBfexYbIPX//9c9e+z//VGPi
# DATA 4f21OgP8zJ6EH87lsAHeSMHsm3AChPO/v5Bw3kKL5+NL03C2HIWs0y+nuuQ8IjXnuRx9w6GqUJAL0SO6kQ9/kjmQ0dBWICQWzui4
# DATA 0/fu9P0Fp+/XHOFyZ/HdWfynOYu/UY/zRs/oiyJiwgeR8+PeMqx81+hzPnv5mNvQ6pTRDjKqJgojPiCrrM696XRfURJ1C52xAyQX
# DATA 9NNBmG7NXDCKlp1WUUlyGs9k3auuVCd5FUjpTWK/Df+6madoBmW7qlw23lYgJur2NRP7oLUu8oEV9W4h4vVaa3PUzXhvR11fVPVo
# DATA bxgdpRFN1S9IgRWWSYF9zaSgvTb7G3bu+8GWzN+o0KlbCWq0dBAvqjqnNeIyD5HuTKU16yPuBbMP86bF+iZDr4pxZL1/mjdy+wYW
# DATA 2Rf5fCnuKFtIVyJPCp7RVIk8DL65fyoox0K/pHUHWL9Ch0b9CBmBykDEfG8uZsMwxtyPH4OGMEtqnISnMvBIcfLYn2lhjaNlSCPO
# DATA IopYGlwJW3xOHRyZXzhar0RB1sRoBwHPl+/AemlUdJa1s6wvsKxLRpOzqp1VXbCqN7OVniflq2IrCE1+GfGrH4K/Z9SOsIqdax2x
# DATA ngxc4hWj3yTo4mgaZ3OWoPE+MXQVNt5ZNyeCZ+4kYjJrxdN7NjAqRXMs46f0COpP2aIuEhxXxK7MfTT0vxsr6aNxksY/S4zkjVLw
# DATA D70sHIGvE6VkFLEEkymVbJ7kCuksUcSiUWoWEYXZKY+842QaQZSHZxNk91WEkyFSPLiXRmsaWGOYENxZZZRbWEVQauDYqrBhylCw
# DATA bYaRjvv7EOYpdoDYOqFUe8CDzDtEYxMtZyEbNlSvat6b8SxBHaJnNGZXGwKz6NGCDUleUkEGqX40yeC2Uj2sMoGkCkz5ZRYodJ0x
# DATA sTZtf2ODESbJkU7hxzjRLOUm1aowZ4uxIAv1jzgXKzLcBZHwmpwqtXzu8bOHUtPycUNvihT514z1X0eQaudEaEVShp4yLszjs2DA
# DATA bSN7F9m2RH0kcl7SKqJTJZmFkXo+5S5M0iiqYCI/28/Lgx2AuXEaLoxgWD4eUV5QhaU0yoRT6SlRlmGX6wT7S7gq4whNalfo0wy+
# DATA cY7NIwpgQcZhPAQNtua9nXCTxPBnlMkgAqcMxhE6v9SKzQoBiS2rC3VfTVz6oSrspaWgb9ZTDJPUXJFB4lQuaJF9NTkrPs8/Fqde
# DATA enGqMK2q8xRI9Wd5X8bEAqm5OdReyew/1ft8Q56YhKcKHV40VTLqCa/3nQEPoYzrGcZT6X+u9w3YpnjvQz12IE3zaDaIJ9f7Ft7D
# DATA /Y5uQXoJze5Br/d9LQFYjCKzZ4gaHtuSM2ptxXfdWU5ujEH78s2vHInWTa12lwx2E6mXfiJ1WfTs8yUhbPb03gTDtJzZ104wXaN0
# DATA fDG/dFIgKIgGMLshi7rCW/C6z5eO8osoIbojbsErbCzXRngutyr5YiYbtZXJcT7trXhHUGjO5zSYhXkhJsDYamXmoQOaAtv6saLa
# DATA iklTtijNSnNvQsmToO1vEdAt1FqyXo6ji4WkUSen4VyDHHYqgzUl+lEasUe9oIadRVmmWYWvkOmWE6764cMoLeCt/tvZl6BOnf/8
# DATA 7M+KQfUHxlx9cf7vGVf1v7zzvwdm6ux3q3Cr/wxaFQOpwLH6+fk/eme/P//N2V/Ovjz/NQX6VcU7+590y5/o+y/x3Tv7xoQGatZm
# DATA 4NUvwbWi/zqm1YtAsqU6jOfhbKAKxhLYIeOeZYggayvmkWAI1wTkylXnhDmZuDRm7LTgfmmkwDxDuZSgj5P9tcLIo54jY0/XVoTV
# DATA m9hAi3YSobNwACvbAJVO4LbpVeUSuTl2FSShh6X3rkVWcRUzN77NFe5mYFU06s3Vpl/UUmwSTobhKe8jpPrxMHLAqovK7do5VW+i
# DATA GXAJzKMUZ0VZsR7H8UYM2JbTlx7Z7tAyUasg1hY8vd4PsfyjNBrGEbzRYBRQnxql8HblyymqX4xnZA4tJYe96TKT/kzMsFOheg/i
# DATA ebRCsdqlpm62Z0pN71nRq3ZJhONWOSvgylaAxlRdYfB/JTxPtzTwX/u4v9Owv+uof1uDvlTGYurNIP+sGstN0KeKSfTG0WQO64QM
# DATA DyCYTeTyBKfj08V4ihVZSfqBDLUQescJlwV/AFoa2SKro9Rhgmb0Hhn44TGNk5nOjlSkzXjrAdZk0yVrKVL8p7HhAm1nT6ndEfAw
# DATA RViijvhMlwzEHPsNg7m4OCyDgPFEPBZkYkJU0f6HBfOC9wHqTRQKBcQvYQEFoKboH+ypgJ2n18iXiwTyUAMmdTnAlANMOcDUzQGm
# DATA LhpHdprL7G7q3qLVfhWj/XpsdkeSciQpR5JyJClHknIkKUeSciQpR5JyJClHknIkKUeSciQpR5JyJClHknIkKUeSciQpR5JyJClH
# DATA knIkKUeSciQpR5JyJKnnhiTVbjTbQeeKJKnRaNQaDl4gklRx5XknjpSdKUHba3S6n1ebVb/b9fxWsxrUA/rrez790+x59LWYQ4Oo
# DATA 22+0VnlQvY4XgPrU8Px6d1r1A/qnqb6WQFCUyfVBfx0Iyu9JwJT+mAZujT5qWOilRqttFb3iIAmUqAiuipph1IpWItrs+F7QpWS3
# DATA PL8RTBvdqt9sqW8r8Yz6/dHaeDZW61e95TVbrXG77n/gNwOv2fXHLa0XZzGwWs0gWhfkao1tNymmDf9Hvea07gWtKv3jd6cBvYaK
# DATA pYvP1aBLX1Z/KL202203gsGWl14GdSQtRKOOpLFZqKN+veMHwyLqaMT/s1FH9DUc1Quoo5E/HPX9HHXU6VNWhQZ1NAwHrV4rRx11
# DATA m62637px1BHvMKmy6WGzhFRki7NPHyOhJ/+lZm5PBmymkcwMtkF+eOTK37wDfajghGsbJ5wsva0CiqywVx3yPMLKtjl6KHq4K5xI
# DATA WxpBOQDvEuP1lse2D94bIURWCdq+QE9M6M3pKRVuB6XaUUVbzJ/NyXEkIUcSciQhRxJyJCFHEnIkIUcSciQhRxJyJCFHEnrlSUIj
# DATA xRHio1eU4MrJ3dF35NL4dCirh4D9kHFTycxPWcgWJV89NVdPI+qR1WVNH3oX4TJBaPQ65dAR84E+pRjKxZMiiEj9/oCC55+ztT+/
# DATA N4MoEowFeh/fd7r2vk+SRTiR83181wfhYlxjv8He6PWT17PXT9XNNmcoP8nijkq7o9LFo9LWuSZ3YNodmN4s5fccHKTGmdRRXs3D
# DATA Uy/E7wV58wUrn0h9RgkYiXDUmwp+hmzeZJKcbD/rO40f8fHjeZokI33+GDrjpqHS+IutKMs0yp5C25xGxPQUSVlQliB9+rjlfS9b
# DATA ztGpRkPVouPMkI/IslFgo5QGPNROyOlN4gUWcRKaPGSshC0gk0G6nPYPoQ0Tz/g8dmYOVY/g7D3m87ufwoVbUDBJWdNdFLSzQZLw
# DATA E4PlHDLbcq55m4L2W7Ah0lPZR+fxEJUnbQSRdagAIkgu1VkUDTPdnUl6s0Uq5jKV4ziZDPmsK2JOiaU5MMuBo1RG+O2Iojw5ZaFw
# DATA k22m7ERZh2XScSpdq6JzGjCRmyQLJJ0u9ZOTiRdOsoQPBm+VCH+Xqjc3HTm2TW+NUqvwWLC5z9YmZ5e+Oc70KfoT1EV0zyzuM8H5
# DATA XvTjNY8V1fOefIANKRHk0eMJn8zF2fis5r3Fas1cdz0NqEF1oMgjVKQ2HGIjEIdljiEqVf9wcZGoO+ccx/mEBhKjK4jtqDj/7uEo
# DATA DV5GTSec8utooOPSUZLwg+VCChfbaubqNLDoxJvz3rgyiRWFC9XiZ5CpZzhOZhTNH0p44l/hEMk0nNhZEpvz3GE6vZqu+ZsiRI2s
# DATA o8Z/aWFzNMLrVjb/GJmPwhvBOS290w0ImudsSxE8QlGwIerlegQ3oGlulBnZqJmptoduFmPeDUic3+du39hKSk3i9pTAX56D3Hkg
# DATA bkbhZhTFGUW5SrlphZtW7Dx92Dj9uLlpxQNkRY7DkejoKcVzrw14G4hScaTRZfZ8eXtHF2Ex9QOmwzIXcjpH/SpA0vpmrGfu2qNb
# DATA vq+/eHvfviiy9oMmwoWLOcWzuy7OzZYV5d6uBFX2NzKhZLLYIZbq9hzxqr4XTKqVqNmZ2SgSUrdETZye9HPBK7lDJPWDJpbmQm7X
# DATA 1joXRTTYFtGNIFSZv2K0slrai0tDlaYWZ0WxI6NZ+i71LdQ6vCMzF6947e63PVNvvSmZ1JnXaKp7TuCfplk+TaSjoxQdJT+lkVmY
# DATA fgs3i2/k7oi/Kh02mZkayGnMarXxwHR1eGP0SNZM9JQBy2CY1COskpQZy3NZfZkWsM2EVSZPyyoEJv35tERip04fRFoFbQfK6ctj
# DATA ezv6jrO9t3vznaH9Uhral6XsPGMhVN4BnG+QXTVAbQgNiw6G2oNt9EIlCZspNM9UPvWFkBXk/14z06gk9HrdRKMVqdy1PKMdxGut
# DATA fdS5hC2+RRCuTMJRxRB02MpaZmNlYJXqKXaKS8mq3eJvjBv33k1jrNtglyJ7EekSGPXxI9gw7P2X81xMO4yL5g5NIDELjNYtuyhV
# DATA TREyFX1SdZCBt3Apk6dowNC01PKoGqvFRNeO9wOsWSHmZN+VYi6yu2ZRhWLH6xemTYjGqF6WUQxSHCfD9mxrtYjlU3npCWcRt0QY
# DATA zX7H2PKxtlnC9F+O7wOsBKkFOj19joriqGFxYY+XTCZm1Y/iqOCTWIHAItjmiNLL1uXrK6PdaZGDyHAbgMNjsYP+09mXZ388++b8
# DATA F2dfAfpz9ofz3zDUB/SgXzDD5+f0G+hCv12FB608fPbn898AN/SLs7+c//zsi7Pf04+/ZgbR1xWPPn159nWVnvgKQXt8zzd0D71D
# DATA 0EIbYUIUOt7yBb2BbnRAoeffov4h9Mt4nZh7E0ULO63IgiAuSUerdqem0RH4y1rOWRb+VX01g3vKos0FyjT1xlsZQm+NQ1E1sCTD
# DATA HUfIsq5Vl3DbJKF15XJzNCHeEDBO5ubGT9WF9UyhUZx30+/GC+MJvmaakECN2V4QX5FF9HnVOUK7lNi104TuewJeBwi8ulj2I1Py
# DATA 4sGPsYd26slO8Jr3QUI1YGZAiFSIx9B7h6QH1ghYwwNmWag2u4T4PJFNHynch1PmMYqzjo0vgTVCJLYMD9peJTcbMWva2bNCB21P
# DATA goMGuZH+MiO95gRdcYB/NVxntzW438jYvtPQfrmR/eYHdqmWqzmQb3S9vdZyE6CgPGUQ0aIAstU4L+Bxw2ZNvflPx3dp0s6HnBgn
# DATA ogsQBJiYf2e+CZbAmLaitoTyW6bhjFKXmXRLak3wghmazqkLmy12wgbBvlrgID/ygUIapdTb5YN+LMv9emELwbCYHEOMDAEojSSr
# DATA DBL5VIDKFWukT4D5SUaCLsaLqCJ6DxZIdswej3jkUat6KDSUE+oosGcQbZA3GKTIO+0QdfQgRw9y9KAbpAftNqbsCDW/2Oa9ZeP9
# DATA Krb705rujh3k2EGOHeTYQY4d5NhBjh3k2EGOHeTYQY4d5NhBjh3k2EGOHeTYQY4d5NhBjh3k2EGOHeTYQY4d5NhBjh3k2EGOHeTY
# DATA Qc8NOyiqj+qj4IrsIL/bGLTqLxA7aHXdeSd+0JFJMu8iLLJmhq1oOKpvYs3ce2MQp7D/BewTSEIU2KfDIg0sb+D7ijBUuL1db15w
# DATA u8X5obA9usej36p+j/7W6d9e6/t0feL36nSt7QV+k661q51eNWgG42bvgwDAok533GlO/Uar2myN2+ti0gw2RVwBjO4cFSpQM/AR
# DATA GXrDtOp79WNB9GzJxmjU77XXI5LqK9WT4twK6uN2s/4BUt3stY6b9Wmz3qw26/SpjCDqhZ1+e13QweVpQFLnNQ1Imo9FA6JkDDqN
# DATA Ig3I7zS6zZ5NAwrqzW5rWKABBd1Wox3mNKD+aNgcDg0NqNXo9LtRTgMajQaj7uCmaUDKKFnv+NBpLdlaaiTCxrXqdivEo5sx7OT3
# DATA lsE/ZqK0blKk3WiY61aatSbzfwLm/6yuR7WLkdLGjdVNi+3CCaEcD9PqEabG4FnUh9FRxVp7tz97QW/+qPKtRr3VaffZ7bdf2RxS
# DATA 75JB6Shn82hwWSqRtnnhPVwxqawVuc2L42opXHzC1Yx+mEYHwzB9uJk9lOdwxY76ZpujZPZKHWLbyZGEHEnIkYQcSciRhBxJyJGE
# DATA HEnIkYQcSciRhBxJ6JUlCSnSzyfWsa78PHfxHFcZwyPcIDnlTXmk6ULYEYBmBDrPYFpjmM9byZQF0FcOefPxNiwliVpViIMqyUwd
# DATA X9OCtMWDYtJGZSKnT1q4M87ujHPhqI076uyOOl/xqPNG8cGbOQL9bsxaF3yWll2Q5dOz+ij08ya3cRt63GpwQdWh+qokw5HKvcH0
# DATA Iolm86zpsPIrRqS5u1abu2WLNPt+vSjT3Noidc2DHyRdVO/FF94QW9aoKMs9ucC1fuiNhDtTW0K6zcs9H1Pfp/BCXE/euJMokcA1
# DATA T7Q5u2hs8e54izR6yFqRFz7W4hfZZsAUBg3LJxefvSOp2UGo+h1dP1FlPVTZF1el+oMozJYQjcbB2kGY5gLVDxYiyUc9SZIs5AY5
# DATA 1gxZn/AIYs/wR53QmFXzfsiD2yQ6pkqDDhCd6lSFzc1YwWmS1AgPpQmZkzXvY14AENNIHmC9RSXsR8PJKQqaCiJeFOSrAdMqHNuX
# DATA c6ReusQZbxy5DnHAHhqOZjyHfiBZbFRnufAzmp0ts3kk+oesmB3OliMMxCnmUhIguEjDeDTClWWf9dRjjNMUGGN31tl6SoSAkrDY
# DATA WeD6ZTnn6+Stnflqma/OXn0l7NXLals/Y8keXtfOF2C3a1vfp9GIjUY2INmOzXIpCuYoZFs0rm9b7OeF0Lu4CVnr1Xp97dLWazWd
# DATA ripvnS/6a3NMLApl+0Qgi3Kdy0Wt2fw5JZNGgJq8FESvq3lvim4QzZJErCYKZzBRPoWIkMi9ZBjcGDMqBEeubjCjyOqKtfAz2XAJ
# DATA 2Txk1D2kN2hiyOUqzg+0EItRdTLu8FdL8aSQM84YcsZQqU913jznzSv2nRutqGcsaMg8YICLk8lEdPbLwG7VTsIsl/Cree8Kp5ut
# DATA pHXyfAUtv3maDKIhaNwiRZekny8j8eU8DZ/7fmygzobGu6ARVDMBp/FCUNMyknqs5cIxWHIjPwqXRzRqfkzDsKYFVjgAMUtkuUfh
# DATA HdBhhKMRnGLsKsldnmacfm+G8X4h/NqlokVE0340hAjaMOqnNCILFZmHUBYBxA6lrShrGf1zeUbBAYdUFeAHZU1BZRpk2rqAchz8
# DATA Nak4S5X4NNkAw0nUD9Oa9z7sJ0STKillbqhAYMMQHQyQCP2JCK+NWRhvnZAhf8ws1UJxyWagXn9OBR+PoPM2jbD2Fw+2wsjHrGrN
# DATA lWe2gAeHvcgmyZ8CypGMRt4RDVk6ibJP0pssKVMHIRQbuR4Drx6ehKfimNLxVGWYabcOZx+PAxSMijnlSyYK3PAvsQr3oZI1hBRm
# DATA yicLVMU11bkA1lig/jBvxOtTBKKNXmeVah5pZGyBTDjzwXOhaghOmZZFZkxCiY9BJmH5p3hCP1e0H4oTkMN2BmGanrJy433Ks5D9
# DATA diogIcwLPE5zfI5DluTLM+nDKOZUiZ9YqV/CJXeUJEPL3S5vTaih0Wg4krZWLMKrwb7Rlk9Z9ZH6mO9eGvaNuF037Fvs8lgauNIv
# DATA jGcAx0fDG4B+vwnmvZILVVtHboDx/WlJhfRG3sRw7/fRNKSPoXFNtuVkQsy53rfxKaBPDSURK0TzME69h/AWh6upu0mi+Msx1bHg
# DATA MkmYDo/gW7fxMv9FYWS+YagL6DBfemdfnf3z+c/Pf7PKk/lvdN8fzn4nyBe+i8kvoMJ8c/Yn+vgFs2S+qniGL/PV2R/PvgCu5iv8
# DATA VNVPfeXR1y90UHQbvfCX579ScBmKx/nfe8yY+R3YNKDQOKjMC4BpnGlm14ovbh4lQECrkXshAtNv6fma+D2OeNs2BjkFDWPtXpYX
# DATA zsldZuCj6OmhcDkbbqXM3Odb8jc7xkxhNmd6htumzKyWy80xZjiB5q7vQUic8noyKt83hPazAXphv+8iDU+vEy1DbSAjGzsVAXOa
# DATA acAa45kYCsLBZbYX1bVTZUwnNIzJjOcTe2LqkPmKpyByHz/yuF54H/P2AHHbHmF/5LpN5cI+hEa7VvpGmc2iBWuaY+8HjeHZCkNm
# DATA W83bbKestKFnxY/ZFn1Hj3FD+lMN6Ronc6WR/NXwyd7eKH4Dg/hOY/iOQ/hNj+BSF8vJzrdNPsMWcxNImXJCc7KM0ZzIY065GYUK
# DATA MQP3G8sNwNM1oyLNZLUWyTD8DBlWgZ44jlPGxaCwNFaGUh5muIgj44YojNVQGVgvAZE5hbXFvl0J8Ui2mWGaQB/7E/G4HaURnweQ
# DATA bNdb3ZRvnUZ/SCHw9wt5JIcY/zlLUstmKGJGotTBYhwsxsFibhAWc8GYsRsS/kLL9lbN8ytxqp/KOHd8GMeHcXwYx4dxfBjHh3F8
# DATA GMeHcXwYx4dxfBjHh3F8GMeHcXwYx4dxfBjHh3F8GMeHcXwYx4dxfBjHh3F8GMeHcXwYx4d5bvgw7U6z36xfkQ8zGo2C4egF4sOU
# DATA 15x3osPY2dKoe36rM250GsdBr/l9+l7MkX6n02kOV7OzFXh+t04Z2jkOmu3v0/fic1Q3u33FZeGylLKSgjsVDktQ0JVo9opl3GyW
# DATA ItKPep1ygEHQuGqAw3ov6LRXAuwG1xvDRtO/3hg2pepcXwztQqGyvIY8tArlkgFuKGWrUK4lhnahXEsM7UK5lhjahdKQwK+vpVwy
# DATA wItbyrXE0C6Ua4mhXSjXEsNCobSa19tSLhngxS3lWmJYKJTriGGhUK4jhq3Aasu9Yin7jVKI6kKqcr88+LejRgnF1e41w+ZaWNo6
# DATA 6Fir1bCgYxJ+apBglpGiQ13hpwWtpwug1e1ZAbR6lw+gkIRe+ymTsFsAl+GZiY2meWZi7lk8s7DZbjaiIs9sxP+zeWb0tReNCjyz
# DATA qDsM+8OcZ9bpt9uttuGZDdsDP+zmPLPuoBkGN84zU14PtaHBzITEGU+2JDsoLO+FXqQ287Mur1SuWfQvhlzmmH0vIiM2DisSk9Je
# DATA lDXB2Y5IXuQphq7WfS+Ohpm+rN8lp2+nyfFRtNtSUWuXxWkr1PKqs+0z0XWk6HYOZCK/snroN6xFYnWvHxS9MLq68h7LcThMTngh
# DATA BitudU/XOStve+yw4Fmxmc1t2E+nJ7Eqt+ubGWh2nl7g0bByq1QnebIcOBCaA6E5EJoDoTkQmgOhORCaA6E5EJoDoTkQmgOhvdog
# DATA tMeqdsdUcHcVygyfKdEVTpK6iKN7yAi5XVQ371LHRnVmD1Urvls/jN/gJw7j11/ff4yLfNthPNo7iWdkXZEddjpfJN+FEf8xoBjT
# DATA H3E4+491C5rfZdAag0D2mkGv2Wt3gl77Dkdp/zv8R0Whfxc24A9p9t4IpOP19w+HyWN5R/kVe/39wycsm7nX/3H9J/fu0rv2D0Xy
# DATA DRe+zUG/7h8+ichYV1pwVlyE/8YB7ql47NPdSn10vqRRT3V7TyR6qBx31c8/TeLZHvdWlIPgw6ExvK5+lAXavb2w0qfiCF/vV8h6
# DATA zC15ldpJfHejNTuJUTCT2K6Qd6V5ULnRmyRtNHPEa9nGlxkBDpCj3c+xlWA23JvE+4eSR8XfeVWaJu6qK77n1/eLN2AIVvF5C/fW
# DATA 5PQ0VbYnGllnjn46ZRWnrLKqrGIOAzt1Faeuckl1lY2i2DeguvIx5Li0AsgkYb0P1uwywivPVsjrNuh0bArQVfEEecmIE3MBlk49
# DATA lPdI6ntBTXaFSOdbQLq2jaPzt8Do2HxB1ccHzD9QFCUYnbonh9Hph1YYcW0J6pGYSJtZcjwmvQPv+kV3+qIGTBboRTeywu4nJ9GE
# DATA OtEL7g3q6t4ZmcCle3dH13H1RivnEn1hqXV/oxkNMh5lZD1EQyO1Z+R1yMgysjhivpeldpgkt5tsD4vYeFmyTMHyHQlOBfrbYjVC
# DATA wyHn04nXgozEmZLxoSSeeurQvRGLoXeuqMWMG/ds/R9KU4MKZqILhS0yOzetjbqqBCY70eZeBsWQfCxxRqczOleNzty6cFanszqz
# DATA C+3JZ6b194BRQxxJdnEDOYrqb4xOAySbxoM0sSTwlmyhKv27kFrXbAC6xar2nRkU8xalBkMNKWEpuUEynUbpINZjIFuuaYSVFmxc
# DATA 2Fn7j1M2v/dAvFX9U/jMIuwywTBqAErC/qXBFHsp1uhvqfNuqyaqcs+iJvInZZwqm0P/mBtA5goffAY6LeJwVPxkuUEEB3Xk19qe
# DATA xucLTpD6XLQ8rTtMR2k/tWLYwWmKtgDWlNwXb7MDtXH+Nhtwm+4aJCBuUHM55pvfyr9ufoYrEe7+CB+2WJcyMGsLT1yotkmCQWKL
# DATA eVcoYez5kAatjnbmSAfqlAy7gz3Wsrqj8tLOixIOiHfDmHYuzmCuTemSbw/+5ef/d9ukohxtlbPKFFNSlVRB0sWpGGNk3/HIBCaP
# DATA tiR5EKJpXxV215Dni9794RDSePS0sIAGaGxU+3miyPxksFfwIJt/MjoyEUUTk2Gb0ltq3pvhLKcCzoYyKZWf3gURBi9p1GmQNZQg
# DATA fezkSvlaqj1XyN7m5uwt1EXJZdjLYsNTQhbhROfzfebJ0CAxr0iu6Yk151qITQCLeBrZULb5ZMmzZ5pfLsWiZwKS8uh79+Mp8mpE
# DATA 1lo2BqyKTW9c8gN8nScZm+g17x3AF/GaYZwNlhkKiEOSRcnryGXT3i6bv5vzVrVcnavo8anrXeCDztO3sbcn9Br/558aYCUNKU+w
# DATA eDADz/wE+CCqW0vKOyoLmeJnnk8F2oPTQtZfBhHNQWreR9Rl09T7vlRsqb4gQDEnic8renBvHHpv2nfgDKG4S3gmrTZ51bzv09eI
# DATA KzKV/7VV5Ctn8fYeopDNn9JAS5MMCiLVeWzM2RE1/KroOeUsMGgHUv1CZZpLHsqKTyZ9gdyNSgo/TajQ45gQyoMfQrsUJwMz1i0N
# DATA TSDhTEOpKvIy+g1LKBI3zvSjWCRPwSM7jhNqIerhUHqe56PzaF+q8/i3y5hXPvXgrQtBMpjqL41xqNhcAdkG0oaRTIeQ7V42ieeU
# DATA n9w4uG8B6IynN33WN9UeQSioYlQXJVbumryjaCFFx1mIhcQsmUa4cLSMuOPA0/FMJirULy2upfu4+cHvLR6XwESKTdU23aK4NRYn
# DATA iXTIkrXojTNBaIpQchSnNLqdIBRdj1nGNjYKvzRdR9NPVcsnW5BVnfFO6ppwWpF662M1uaOw8cQ0wUIuzx3QUzB2QroX2KzlzC2a
# DATA K7JsbJsr5opk1j1qYGqBVwsJy/gtpqJlvlJzG3PDk0KpXcR6ehlcLvlsy7lcnMtlDUHBeVlefi/LRgfKc0VUKBwVWB0pJzZrwZvE
# DATA CxxxZiUURmKCYqlGE3bB5A/yeRLO2GeNYHietcov4idZBz9kVZKPvtx7gzrScnvTR98Lx+u6cpbPOpcvF8KJdIdlnMTKkXRpv4ME
# DATA tUPedjob6Kgolcfc72aL2XN5rAFzWM/xF06PWokZB/cesE1uqgggyOHs1KxafT85AQ75VNWd73p8YQnvFFlV3/Xeovsj6kxhDMEI
# DATA yS3h72ISFk+5ws2yE5k9LLDRzuOlY9bfjxXRVbOpAKMNyTYDHxfaZWR49ZNH0Qovqlhb3o0ZmMkOSMqO5WBBiZRifxWWnGzOZcI8
# DATA bpty+Z8ZS/k/gJw8/60HIuXZ78++PvtilXBZuvMvOfAS91e881/Qta/ov9+cfe2d//r8l2df4gnc+xVu/6MgMOn2b85+f/4fAK/0
# DATA 6MPP6bY/ya2OY/kCmGxexn7/VB1ANH09Es2Tc+4Jap7slveypUxYZUM+c2vlQW7AGDN4MGGPwEymUSNMWLnBwU+GpYUxb57fQrF8
# DATA U2TABJXhEJZFE04a/W0DLEtFcnP0StgBx1Z3ryoeU9Dlp/ITqgqaJz5WVRJVcAaP2LUCLXm3xDjM2F8D9I9ylCsLxkEtdy3Ba8db
# DATA 3oddeiS2imFHV7jbHMLBpgFBps8SQ/vteDSKB9iQj23LsuMm0gxwfessojDo51Tc/StEy53q4GazpNi6nhXXcqdEOMClG+ufYqzX
# DATA eMvLD/GviIfmlob36x7ddxrcLz2239rQLtWykA055vKZtZubgFwW0ogpeVhMGLaVSgIQ7HS+kKFwnqLrAaduHPZjXvhbZLrU6Imj
# DATA IyywPKRqkMk8nuqxWubGdFtGZjMCT2KqkFj+EsJfBsW/dFfEJbLRMAExbaD4T6irxxk2rIEotKOOPW97XcFKqppULRgLsiDEsWSJ
# DATA FISCPEQGYOUzq86jtMpWHZXAcsq97KFlJuBGRLlKBttGs8ExMB0D0zEwb4SBufMAs9NM5hL28O2Z9lex7K/JsHdwTAfHdHBMB8d0
# DATA cEwHx3RwTAfHdHBMB8d0cEwHx3RwTAfHdHBMB8d0cEwHx3RwTAfHdHBMB8d0cEwHx3RwTAfHdHBMB8d8buCYQbsRMXPrinDMXtR7
# DATA geCYhZXnnciYFurNb+WUxUaRKtYpZXhDfpccLyLLmt12vbMmw4HdbAfjZnNabTY9vzsW1JkFHivTyHLwWGMF+la34lpCqq3Etd7e
# DATA FNd+v91thStxDQKKa7d9XXHtWXHtdLfGVcHs1sa12e/yr8W4Nvy6F1D9vZ64NrrXUgc6g2479Ffi2qxfZx1odq6lDgw74bC9Wl+b
# DATA veusA632tdSBTrvb7/RX4trqPn0dsIKj0JrtzrjdqB/77e93S3hc6lAHratB7Kgv1RA76ZYtiF2zTd1GdweI3XDUKkLsmlFzWM8h
# DATA dq1Ou9VpGYjdoDuI+oMcYtfotbqd4MYhdthDVZXVDT26Ni1+nUWr67LNmd9/OS5d2enayJda2+J05ZD5nMpuvtT2Nl+qnhPmga6u
# DATA yihfs55mYKKgply91godDj41LDjJfxr8u+HCxTOqU15XyHBSGZpFOp2qNesoe1cjxsmKgVrEXVsExrVX9hdshM1ZJbDFNl2tMY4v
# DATA 5/hyji/n+HKOL+f4co4v5/hyji/n+HKOL+f4co4vZ/hyrN6oUHLs86REf0e+8uE9+npH/yqgOTY2P3vtHXX8b2hOQuKwHpPMmMk2
# DATA iOLJHofOZDXRz8xqn9H/ZvcXuE2CVT8oAJv6xnAYHe6QJtwen+BZE/idcigcjPVoxiOCwZ05HUR30H7zQXt3wP4lPmB/WfXD5+bg
# DATA fe7Y2q6GyCJvfJp1RiMUWRYQWB7T921aiM/2nP4LdmL1IvWd3FF5E9qIJRWCaxZGLOs4XKCKeF8BelgMgXKV2lDGgRlpoY+W8Mbw
# DATA DgbvaAkoWD9iNlhoqX5D94Am6xinvXfpagKRe61+KDJRjGhQ6gpUbxMt4CwnyrmqK/EGZD+fKcc59L5UCDyNOhc9msu0QqlMl1UP
# DATA tyoplZocvNc2/IJVtx8kNNKN1Wl12fyqxbc/DCG3aGT60+gkTHGgXgmKnoQTOZofqgrqTZAQ5iSwAz0OUxGmkMgXz0MvQhZJ/cFy
# DATA gSSZQ9BljfLVOOpcNtSGmZQEU2y4g8AmDA9fhlFopNTDjFUalLBWyHgaPq0eL7ZE7z1Qby4ROfQiJmKWkIauSBDAzKjww1QBDJJJ
# DATA pniMhqbDwaQPvRP0QhxfnLbfEsmP5DVrMvEVOrFuh+JsZGcjl23kUq1yslROluoq1vFGa/zG5Kq+F3MbYCMhVEJPWsGGcuyhpV11
# DATA y5qItwEHFucOQ3BgPaYRcg4qldvxwPox0zuZCznhtlm/CBHcqIshuwMlWLxOQPYaBxNfYpcQXn5BhPXzJsLmQh7h1voISxxVlP1y
# DATA lOub48yuMbvqomrt8YvviGdq/8JsLlKY9fc8zsHaOLeuGmXtMKMbPljvc7sgxnkAJtLWJSuv10bbirWqPjrSrUKcNwKR31zGk6E1
# DATA oqG3eHG5yB/IMCyjezjnoze8gK3nUgaczL0XnxJR6lCS/DE9FIHHdd8bRSfs0mbH8cJ4VKGDtUZI/ihloToz/s+iY828MhJgP1T9
# DATA uu4KAVwLgUXH/lk2yGvevyNLYcjzHuoZrW6WzP4hdgaJ6ppmZIorWzpSbiyUInkzmx6Y0tE0Qzhw8WLTlO0lNsLt0dUZ4c4IX3FU
# DATA r1hbzg53dvg2s/r5kY1Vg51uBuwDQ1uwVeCB26GxyrTC43yoUxKllVzFlIcaI3AKvU7srcKog8DnItmJ4VU5EdHmRgJEyZaxYGbk
# DATA MMgmzdUr05Pzl3LDhgR+H5VCzyJodB46fvIu/OQZ+1DxhHhTN98p7mSZQuDTFnKyditazj9QbJ9/gnKeG5fESH6yGSGp81UgkvcL
# DATA nnu4tKnKAEqbRiimEjA1jY4ox4x/lv2wgsSi/4wwd1bqs1QjM76RbpstYpowywoEz5Vr3lthmp5ClDWZFd3jacjMRrZaF+mp8hKz
# DATA KCv2QKYSMfjMk5n2k6vJg91I89Uf3UTy1SWzB1JG+S3JN/mrVRTpAm/25YYZgnFqZiJPxQrNq/Ili/mdzcWsG4UqZuP0z5dkZK8F
# DATA 9xi6oN9HFwsjJxQma0oWu17lyCxkvWgBiFI0L71I4NkkOZmciiR0ysrG6FwxFpmlHipz3sCHDnJsesWnKsLtSbu1Qiz0Mpcsx4+3
# DATA wIzz/kq3WEGPKInkNAKLlYac2VCJgXNJahJY3k6HcUizwCkbqKNocUrj6RJ5HCvnVahbssKNmck8L7rQ6Jrz0TKzhEOD7yPMSNnn
# DATA xh4wLBDGAlx76ra5LaG3Vq5X7oMf7NwHU4Vd0C1C1428GbO3s4enK/2vZttIscKqEaFpNjLG0TTO5qx97b3PPWbIXoJJmB5BVhrK
# DATA jLNMc+pPklT6V2kr0rmOQiCS4Ra4lna5PlXPf7f6/Z27VTV2kX0FeX0kNVQD1TDUBGvTJGXdG91loo1FsUPhbeHTcRDHQVEqvnV8
# DATA NIOrRyai2sKEY4WlwWF0pvOU9eqp15Vi5nhcR9vbIWEvRNf69qW6Vi3rDsNkmIYnaCC8O2ESj6yFauVc03co6yEKsS2UMgey92Lv
# DATA 2PYMZjRcWNrkGSwXNY9dfmYtW20PGKThHHnOR0L1fgrtIXu6ct2awiuV6O0CvJ/KQ/vy+xRzBOYgotE+HmRFBOaX5z8/++LsT2df
# DATA nf+aPv8CPEtgK/9Ef34BjuX5z/XFdVjMb87+SP//8uzr839g3OX53zEU80+CxOSgf09Xfs38zK+ZnOmd/+r87wHQPP8V0zEp7LM/
# DATA nv8jBfEr+vtbeieFgJt+QT/8gX6me/6ZXvLV2Z/Pf+MwmS+EoxTb0tBdqW5R1TwOOjsQXxQPYX2aHlT4+xE2u8OLOgCyToFajkP2
# DATA XIVmimB8rqEHL9xgXPPeeTSfwHyhzhSFhVgrgyZXB97Kz3xrQuOXtETEzxE0bR+q7jNum6C5Uig3x9DkSmnuwtZCXlNXHsAV4iZV
# DATA 7Tgxtz/grx5Eu5YTiIRdJ0AzziQq8B7KzsYIZ35D8INOo4WjZ+5SdjdAzuRVUl4tj6eY6iI0UwFU97SI+IjaAPWYj/V7H0RhtlTL
# DATA t5RjS0ChmK6AkqO+0vieM+YMeYt4EimXdcr+cjKQhsvJKk5ztyq52dIpt7VnRdTcLR0OqensgpuwCzRr8yrmwCuxnHprpsD1WwI7
# DATA GQKXsgNuzwyQelnKBRu3+by1qZvgcJaSz4mGm5rZhSYyZfimVijOM+cYToyJ4nHaB2k4t3jp2Sj/5QA+/TZkhvhyNL4yexgtBvB7
# DATA 74rjzEd8y2KgyGX58D8VO2GIfXlQjYJCDcXXkxD5ZE3BHuCFb4pbMqwqPz7aeZbxPjKP93CJLaKdijQqIbnij1K0Tt4owW6r0Cyj
# DATA OfSmQ2869OaNoDd3Gmt2mgJdxmi+zSnAVWYA1zUBcOhNh9506E2H3nToTYfedOhNh9506E2H3nToTYfedOhNh9506E2H3nToTYfe
# DATA dOhNh9506E2H3nToTYfedOhNh9506E2H3nxu0JuNVnPYDq6K3myPOqPuC4TeLC0+7wTfpNBjGha9gciM9TgvB6dCN+zlGRs0RYeK
# DATA fwnaRX5hbziKuqu5DCZg0Bj7Qevzatdr+V7ge369x38arWq36ZF9XO01qq1qp1f1g7YX9KqdwPM79KVRLIx2t9vqRfKOYpyDZpDH
# DATA md6Xx7kd5FEWsqhVMVqNdrSKsuz0PL/VGXe7k6pfp+h1Pu9RZNuNakA/tLtV3+9WO9VWq+o3e6Xa4keDyC8xD/vtcBQG65iHzXVJ
# DATA aUrsByrGHQvC2LSSUqzjw+5g0F9DZPS7XiPoft5tV5uUkkbPq1Oaup4f1D+vUlk0mpRC3yuhFcOo02yvjVur28njRgFb2dyzaka9
# DATA SIv0m4Nm+wqkRm56mtQordgiNVJcBr1dSI2FKyA1BlE3GlqkxrA97AxzUmNnGAxDi9Totwbdxo2TGrG3vbrNpKEB1/JxiW1sHtKW
# DATA jA0lRCpHfmlG3Ox+28O/ZGp4bG7kQejx1lpilF/ZnNzR6x9Y8Vs7l+AQIShs+/zruJvnINo0PbQM8IIrVJX75cCK4v7KoZClPGlR
# DATA ntC/Dfm3sFrVbBlsZKf17bWERzEWKc0y58uXS60FrPUIx42oxgsrg7Yn19cCyZTALr6dwykVDc9iS5Mhx4F0HEjHgXQcSMeBdBxI
# DATA x4F0HEjHgXQcSMeBdBxIx4EchWjcd/2q8BRl0zHgj2TNaOTjA33e/SRS/kzGPe4pXCQu4AkJClX1XWz02/MZyTiYCvuxEIiaq1qh
# DATA yJWLgxERWYgnq+P0ctTem8fRINKnEXFGDv7DPsqjyIHMT9640+HudPjOp8PLR7TcQXF3UHy77vZzc4D8QfxImlCFxqfZKZb8Yzlk
# DATA aYNvzJFHSzQVTWYihzrx7MPVU884Cso9rzo7PUIocjIzCyfRJeWzjaqluB65idPNyRSuUfuct1PO3kU5m3eUcFXEh833ob/EbT+i
# DATA v1s0s2lQXAj+8CP5+CLoZZs8uKRI5JubRSJVbopA5Js4xTnCsW4MSrkeJDbLeGS5U1XBeXCczgeXlaY8pxDwnMQjOcGcLJgCkfHQ
# DATA BBcUgvFGEdWjCQwimrAkcvCYU6KJKE+jnXnVLHlrxyx5R2uC0pisM+TNcAJdAdbq5ehSY+IL5sy1LOGwrKg3gneZnkZO8QIJz+vA
# DATA nKOhGX+oCZL1F8vJfAQ2u46M0e3gkvnyo835Ii1K1ZTlkC2TvI7MwpTmpN6M5rQe+hkGg0K6FQsSkBnI4T+waLhKRTMhlEGQIGOO
# DATA CH2eo78/PtXGzTOsI/9mxzryUbJkDYufLo/y/NBq03OtPp1MR9g0AkwDdQJzTK/QIJhmpDBGQzI1aDAbUMZNxskSJ95q3ieYELC2
# DATA AisliF13NAl/ZoQ6nlJ9Nu8KL5k/H23RntWdquQQza+9ub4kOfRRmhyjDlCaaXZzFBl0LG+So0oTLgdQ4bg/85YzJFf3MBAIZiAq
# DATA sEwTKO9DKpoXl59hu/l4x3bDlVopt1jIWlZkmCZLqI8voVQxEeMh5TOy8PeDijUc6p4FSsuxdKVsltlCvKFUF+qvy/lxu1K2r4pC
# DATA Q25mu0m4m4TvPAl3M+6XfMa9cTL9XEu28T4Ws6NFqKy8q+XeG9SgyyWs918iuWZbXVe2UlqbQ+VCOOFvZfmzlX2RUmEGCXYOyctO
# DATA ZwMdE3XS+N4PVrZV6kn+qrqc9Rh/4dQUxvdJgewF+ASzXlhxbEjVkybw2r+QP8RHp3m4eU51614kOacdhW09s6VKqm/BcDAbqLYY
# DATA av/yT/9JmxH8ynEgUnZiQXqLaDLhqYsCTYii1/dgf2bekVhZ4YJpEUOosNGMZbyc9nVxhV46Pl2Mp8qaZYOV5wZHsfwslh+LkWHa
# DATA DFEzS/PL4z2PEOlS0sgVyq00ygXnjBqgXoEWzFCOrjgJ0xVN3WKBMtTIGI5MrHoFZbWsYJzV5qy2na22lfrm1k7c2skVLLaNxuFN
# DATA iu8yoGmkdPRZzB15zQvxBQ3eZy8Iv80QwDk/z15rWVk6EVuRbcth4VphTUOW+unyu9T/8tlvvuLtDaYXge71o6Y7MxfMCoMcECkj
# DATA 4/0i6N5Gxtdr/ub1F7WhwI6sXNoltuZhE938iolv7zqjqzZe0O8faP3fRbIoVIm9b18UbROIiXZ+5YJsrlvxbmyNtjJfzYKZ7Erl
# DATA VS6p8hFv8TBNIbMQUahh996QM8Eqzmp7su1Uyy9J/xMLqmpOY7cyYu9IEE8JfxLbilFaeRdgq1L/MDP7S9D4jHH7gThTjVIzI4dP
# DATA xvEkyvuJGGq1C+zVSVny1qx0UGuOcvFmlgdWK5wwcWXjimx9I1O3VAX0TitvqFB9pjfQ2sHoUq2+h1K1nNL92B6ch8N60oNwBu3g
# DATA OSUgxjnFMJ3zQi97joEih7vyZByJAZ93XEgZhKa5X+OFLTI6ap6C2SGFRmg6W86p61H6wUVx6Tuc76+K9WxBuHiOznMIm8P1T8zg
# DATA +vL8l8K7Ajnrm7N/VmguwLnA4vpilcD13+i2rwDoErTW2f+0wqFPDNj6I92jIVt/Pv/N2f8ylK6zL+jGr/hdvz//D0zowkkH7+x3
# DATA Z1+e/U+qNOHEAbdeCPufjXtr6wZQgWkCvOsU/QTXN2PHMKk1gzw5dUms3kc940xUv09YN1yWLrTsdkVxQ4/Q2MdhH/2UzNZFDZvr
# DATA DMTO+xFmCNtgW5/SXSZCDrVVMP3znuG2aVulUrk51pbQvg3/ibdkW2+17vxpRsWtbyxWsOtEbIUCttJwBbVAKIlxeK0Liuva0Vof
# DATA hWR04meKdateqdfrPGpQBlAXVfM+ogHEWD1MsOBJ1zicYy1Y7/xfhP1DRFJw1JmBUKC4okc0EOBsQZmhdWF122ymFBvPs4JnXZgA
# DATA x81yw/t1D++amXX5Uf3VcObd4oh+3QP6TuP5zsP5rYzmUhsLSbd9dM9TG7oJRlYh4Yz4yRSz3U4mTbrDTC2aDbFo1odlHmIncYUS
# DATA GgPpQ40mpiRMYrCkZkP92lEYT+CvHIRgFTFbqJgsjLahyegpDXB6gTmeZXMkCS5SaiG70rLykFkzIJP3UfyZ0sRb0cdU5+BeoYt8
# DATA ppxPm7N/Y4YVPp7DLpkQNQ/FAZsMGZklZkFmzopTih6ckvH2CJ6yeBiqk+yRGIZRhn2IcTbGOmYIr8ZAuCtIVzzCBsTBOJqGHu98
# DATA ZwrXnMcih9JyKC2H0rpBlNaFY9BOU50dzefbmwVcZRJwDXMAh85y6CyHznLoLIfOcugsh85y6CyHznLoLIfOcugsh85y6CyHznLo
# DATA LIfOcugsh85y6CyHznLoLIfOcugsh85y6CyHznLorOcGnRU0m/XWldFZzVFn1HmB0FmFVeedwFmcsRyXHmecoJnqfkGOou13ixne
# DATA 6PU253i90Wuugpx6ASOpVFAWXKpT7/Z6/XVwqYYEMohTlqBSL2tbbKkGx5MPzHWLNKlhr9Fpr3u+1drp+V6/1+6ve77b3OX5btTv
# DATA hH45E6ZBs+EFQbtKFbvV4+odTBt+q+oHvsfXqnKt6vuNqt/sVDsdz+/6dtC8YbSE5+oOu8PeuhxkXFip5nd6XrPhU4XHq736uFcv
# DATA BWfybiW43hUQWNyENAJLWqOFwGq02/1OcBUEVj3qRaGFwAoooE6OwAqG9WEzR2AF3bbf7t08AotmQlX6fadJexDQWFn0WxVGGhnx
# DATA dIgeH5Az3CdtwynjUydYB5Bq18q6QLzl5HHJZWKNASt3hyWz35jiXWWK5w/oUbs8D1w359Newi57CWV1EH7CNYtt7WIiigsBMkf0
# DATA 7ImPMuTyJ8wwuGbFrozhWuvx0RW16GHYBO0yzmMVHfiNrekXf78gn4ovaiM57FcsbD3Z/LwZpy94zYYp3Gasl6ngO+G4tlXezdP6
# DATA UmVeVyeXkwsnlxwFx/lynC/H+XKcL8f5cpwvx/lynC/H+XKcL8f5cpyvV4zzhbqgTshHw0Ob+rXAkilnBFJ3V+p6skwHESoI16rD
# DATA eMRGpmqY91p1GDyLMWAF76Rpgji+rSwvNC8yeaiPTo+kTzavvVsypq05AZuwFUwuKkL/wrZGLod9YY6ZQOg7dRWfvcZ2jZjn3rv5
# DATA 0X+yo0+zNX3B/uETttEf57HBVstRPKPsUFQzlhFVug/HVvBvofOh5gqXagXnGKehnKHiUsdb+9ijTPNLfpEVPyWoS10NTkJ9mBj7
# DATA 1DvBmUVlfdJvHEGq1pz7OLVT1T/SL9/dZndwGVL55Om6m6ds/3EhMiJGZeKgRRrVm3AaEPEQq//wiTHmP3vNBF5D3Oit5sLr1FeB
# DATA wkbXqLXnxyDvyI06N/jsUTm9Krmmsm1tL5zOdYW3WzA0mcPrKSC2lyXP9sSGHizSCU35/vZv5Ss2A9LX/b/+a/lOj1KefvbaO4x4
# DATA eG3/8QbLWxnd1BVmiwdsse9JoTqJe6emcCU1Baei8HKrKFxW3f6ZqisYB6ykSMT6LCX3RYjqdu9DLcPNKeWDrEtIW8abE/K2Pruf
# DATA Kw9ILPHQtgcfcLvlbV5YFNr4VCE7xFiw2l7+1B3EVOsQ8tHYjQL3hsSkpBCoVW8Xt3/uxCZegMPV/N9rJicURTGum5tQ1hpZS024
# DATA rErWp2msTLd4xqxGst1gzBiVLKMDwsplGSzgEwiZTZei4XDKfuqKEdCXyqgqD1cUjJKZKNpbmh7QOAjZok9GC4YrpRG70ZnApYBb
# DATA bOh7vDDIeuOz6BH7eJWyxoUco5fjnLwJwRl3zrjbybgrKeU4zSynmXUJq26j6XhTWlrviWATVWw1l1dOBK7mOdnnthUbb0PkXnkW
# DATA dObqpL+hd2JoxXF9G1TTxVOGy+wsKwisU0ZOJuzRZgAC1op5dPtruJgO0afJpwN1QVnU8q0if9gtrm77sV8JKo2f0KCoY7RBUl45
# DATA 1ehd7/EnrrJFBLG5xfSt+UMrBOCAkQ0nicdbSbaAh5tieIN7WLpzBRS8UUze+LDyqvPi6shjyiPyUspGWidxtjQCZ3NpNRUlYfZv
# DATA wuPwgXSxSs0MhBXtBkUzUfnAem8ns6IWmqhmhYC02C45pY9FAyZEzwSRNDlVjlDT3KFwJQJc9PQJTnfx0MmaU5b7r+aZ4sKISDby
# DATA crBYKgrTJJ7iIm80gmAVROKYdgHtrkxHpVQR8qmIbSbnUwspraLrFHNLvcJvXIdqzmdqzsWy8y+HhZoPM85EdSbqTiaqbYs4A9UZ
# DATA qFsNz2ct9vphoZHMMNAt4mkOZXogy6QsgFqxKICSOu8dLYMIgUUc3+Hsot/RVIYJj9XQ5WS10PCI4oUtZ7NTowe5o4IrR9fERkhQ
# DATA VAsg6CgGATVWavcR61ui81jjrVMnjtdYqrJHARWMPyk6kLJk9I+5cWWusPQEkPMRh6NiJ3tuTLe0mVVkNj4w9Ec+F+1K6w7TJdpP
# DATA rZiM2DmA0REdo9wXb7Mw0SK1L3nzXZaOrWAczdctIUdZfMRpf5s/bbFdi2xw2UlgGyyKZr7JbCyUMXZXS2O9AoBd58YlAeyPn2wm
# DATA sEvGCoEdk7hIM9KV0/5Uk9g/wZZRSnm6zGS7F9fAGWunKiFdzIFA5tQr0DE2YYTYQOH1l2ToKsXUeFDz3o5ZYHXJQrveNM549ih7
# DATA XbBdiSmivAlErnFr5ZVhITEAQUSvSxWf7anR9qUadMkM/pd/+OPmHC7URslolnRNIxH+hV81HsQLg7znX3L6EmvfklEtWqrJXJ+6
# DATA X1BtS1nHF4dXF7HY5/dHfCic5gbTfny0BPdRuX4rursTVJTQH0My9lnCNx7ybzJhv44cvWJdnWa71dUPw6lUBUhZ51kntQVTHCjY
# DATA yj5fUbWFTvUkWgCJJbubzNMeYzzQezHo4xRoWaF1zaAMiAZB1h9Fh3pPKgq1QcE0kGdf/f7tpSqfsM449pSKz5fRMtL59z5mcJi0
# DATA 0QQ6V2I+CWN25vAFddw8AgD6bWmQvCYhFSfLKyoHjKwf4WgB5ydl4AwuJA5oIU8B0xuBokhDJQrtWqqe6dovmZHvbal7apCQPCyv
# DATA UHqLNDymcfOE0qAz82N1lGCsBLJDqZYp2TDRMFNGAfVyswWD4xAW7BKZn1BDnpmeQfWqU+o1Mp5LxpB4tJZVc7jcIlZy7hHNf7UK
# DATA N2y/Z5qvn+yar58wgc9arsL5xrx1q+WwNDrCfnA5IEIJydSQgdEmV683kucZ+ypyyzAajTiH7X4g7GcsXk0zNHbvyD2qOqM3Fasv
# DATA Rmf7U9nNWsrQopEgexZtI8Fckewhu1bvLtQTO3a2qF1/1BENxgn0s0L4S6kkdUG8EgtvNkaPSiKyCXr/+eyb8787+/Lsf539+fy3
# DATA 4N6d/wJIPPrvN2e/O/+NoPF+f/bF+c/PvsLfsz+ffXX+21Winh0Os/J+wTQ+PPvN+a/x1NnXdJF5e4Leo79/8uiWL8//gZ77y/kv
# DATA gdNDDPppdFI16L2vz39Ff3+Ln5m49yeH1nsRvDVS02zevEw5H8ZopTPZFgxiww+Nb0aU72GOkcUwhNIPWwqyvoHfH+rtJGk0iOfK
# DATA 5sqW6I+4tU8TFuvfStJ7S+JlNSAH07O9NMid2+borZbJzaH0pOrkK4kfS1USyZPyzeiJrDXH6ORGaNm8o3quDl1QVsiEEW+bRrOl
# DATA 4+ntUGbXjtQTs577cu564GUWv1mfDAjdu4k9z93YJ3m3RNU1OVFQH004Z501Qf/yoQMUWjyd4owOYEJU2AZGfKn6twUDXG5Uzwqx
# DATA d3EiHGPPjfNPOc5rpN6VhvdXZAHmVob2GxjZdxrYLzOu386wLlWynAMWWu9ZNp2bIOmVk6oXRcSlGrLcZGlEzOwhEfFfGRMrAsWS
# DATA xVlZYxUli+Nokcz5mSjjA+0JmUuLcTLMdsHkfYw8lGWscowoe+Eh4I27lPxpjA0mCVll2LMlA31eXeidYbZMAQYLWWCUMpn9+RXt
# DATA tk8jtB9O0SmXjOjgCAkQjhUm1enKkIUTwX0N4KzWPDNHw3M0PEfDu0Ea3i6jx05zlV2N3Vu1269itl+H1e6oeI6K56h4jornqHiO
# DATA iueoeI6K56h4jornqHiOiueoeI6K56h4jornqHiOiueoeI6K56h4jornqHiOiueoeI6K56h4jor33FDxWu2g3+hclYo3GvWi4QtE
# DATA xSuvPO8ExitQ3xo9ixrXqDcM9c3vdIrcuNGg21N5QxGMaWQ1QTTyIJrNel42gdD25PBU0CuE12kGg8ZgpaCClu8FQTAOOvVjv9n8
# DATA vNr2en7Vb7S8XkB/6tUuvlR7wZqSW0XztQIKrVUfN9ufdzpex682qR74zQuocyawFUxc0FmbAV2L3EeRtypno5VnQKPw3m81B0G7
# DATA UV+JcqNd9/yW/3mV0tqk2lLt+NNWk+L+eTXo6StXToAfXAF0x61Cg+6kgVmgu06z0Wg2dwDdDUftIuguHPYGzRx012m3eu2WAd0N
# DATA O4N63wLddfyG3+zcAugOTaq63d7weHixbi3z4b4XUS8QhxUJuLSYt4KKa/CCWb5cVgxa2S0rTiqdQyuOyJK/3w5rnQf+UoOqx763
# DATA OhtO6hm1BLY26catuhpJY5YXEXIqbEHXrd8qUCbarWLW1uaMGfj06ld9Gw1uh1pwU6aIQ7s5tJtDuzm0m0O7ObSbQ7s5tJtDuzm0
# DATA m0O7ObTbK4Z2s2Fukmw+sHVXQGpDnHJ7bf878o2XHBnLpZBnySKcyP1oUa9/EC7GNZ5J7vHF/dcpB3Acld6jnGhzaMws53z7XuEd
# DATA d+Qb/ZhxL7JI3sV2vD3fDuVTOUxmBVJ+ZykYfnblyJkmiMkU0BzpcIeo3SHqdYeoS8d83HFqd5z6sseptwjf3tQxa2kFbAdDr11W
# DATA Wc0x62co5HEb1IWhOp6taga+entH+0rSVje7GTswcgF49VTeN6nvObOgyGKYxixA11LYBvb9y6ITtljwWlTN3yx8K+MppJjNsIZi
# DATA wKFqyf8LoqufN/E1F0yE/fa6CHetCAe7x5cHVVDaOB4cTbpyQSTVQ7lur/pe4ECsxNC3Yti1I1iM3kbew1uqRUVGNOjFxT28xVYe
# DATA D2MM8MLkRB9Ifm8ElU30IXwMP+OBDm0vI7NkXmGfJrXSCbz+k1MPSpqoZDF4eWIUibde6FxS6/jcODVDFeKQgqAAYeaMdYCDBEaP
# DATA CkkfB2f+BNfkKFtg3Z2nVCzBNGWL2BIBwGlwVmDkZdQhTpJ5snZzaIsBwGRD75cl00h3RO/T7OUYM6QxAzC4fQ+wO1glCNHO+5qL
# DATA AQ0vz8FiB4l1lux2S9bZrS+53XpZKOwzlwfiBXNrIXjV6JsUJAGZ+pOx6LbiH/T5GClMka0M1WeuKvSCKHDcBDZ1RQHpusmpa9Sk
# DATA 1sNTd1NCLNU/ZLVNU2AR6TdTpFUN66zanitI854ePRFaZgKn0vxUtsUizLOGpwVJl9DDRonlVNlnqGD0IYuUoYTApCYVDRSFTn6X
# DATA bzBGSVmCm+P8MYu9SpQjymId4/fMRC3mOSBFVfSMFnFaYWV2jo1WZS9YaFrx3sYHsEGKoMgKwBGMLdH+CAtz22P9ANAVFWvephQN
# DATA dcTf0RJXQ5rdIjaUBM69Ck/5Kt4pNsuKqhN6jEVyFEHFquZZRnXCyqJTj0EFivqyKbr6hasxfoUEbOw+yVmaztJcZ2kWxinnMXUe
# DATA 04sM1GcvTCkxyJSyYpokU1ap4waRy1NOJtJU1ook1lQ9r4izoiKDEXTn0IywPs1UMPaseLJ6p9oVLyNejgL2LlsJSt1R2qRabuQw
# DATA 0fPNGbsJF3A4wQYGEch2ULBdoGBicdmm1aY7jZ+b6S76y+b7tUon56r6vPluLeNZND+ef4xYnn+X5Lj4B357M8pFF4agXH4wi6gz
# DATA mbNrsYoji9oyxPqG3/KO7JWMoFmnC8qN+GmkCGQ0BcFWuclphex27P3tU70Y4esC4yVCxh6SDGsecqoj4x4CxtZJmI1FS1Vb6HRp
# DATA Msmug4NzK/n3yUnC+TekcWpezL1GvZh7za6Vew94oQbJ5r5WZRIUSwF0XrAcpUhjyl3iF55EwBdhs66nDuGKUOk15FahDV4+w1qb
# DATA M8xq0JJn36M+lWL3bspT2blMYPJ8C0q1rtFpWfm2gCnFy2RsOMWz5QJDDkRLJ8WJFY8YDOuhmkezK0XBM5OwY+xonDwHede+RN69
# DATA hSqQiqxEvj5YyL5StWsE9VL2VXgqzSbqkRRFRvNUUUoFsU9aI/ajD9PwBFt59dIA683mSwNPk2d2H37JLPtgc37lo4FC+CUPQ21d
# DATA 60x6lzkVwo0Auk/ohcdkcxgznSzch9TwJgrtNGTV4WkyZJKfN8Y6sPexCAUz0wpXzPKJWZXJaKCnXGdNXrTo68g2ezC7dE0LNmdc
# DATA PjBKxhnHQNFA03n4AFeV12Xm+V2qYUOdV6HXaPOeIaqo2BbILgSaLilHjNhujJHnupZ4R8tY8b2YG6u8N2w28pbz5xXh9bI4JHKM
# DATA 1yheQGLW5nj9v2dfnf/y7M9nX4Kx9ZV39oez3599dfY/zr5k9NaXq8Cu/0I//e7sGzC2zv89bvEEyXX2l7M/0k9fn//i/DcVhPP/
# DATA s/d2TW4cZ77nXOtTlD3h6G4TAFEACi+kmlqKol5mJJmHpK09a2kVBaDQKBFAQSigm21ZEbI1c2YmxnEcsTsRGzFxdic2zsXe7IXG
# DATA Hh3LsqW52C/Q/RXmk+zzf57MrCy8NfqVTTJlkwQKVVn5nk8+mfn/UZgU1nf02x+947/DT0W64xv6/df8pm+OvqM3f338BePBgOxS
# DATA BLBf09c/UoD0k2N2PQ8ulQzqhy5zaPOApA9JY/hAqUlqXOBk1pmy+r10KJRh0VTgi/uY/sVDcUFKu4ULtYfT5+AAQKGEnwKHkTei
# DATA 8nbPjtLIT8LBWozXfayMd8NDE1PH8bJ9LaqDuGqQ15JSuTySl6qF2ZLRI1UtBzHFc3I4f7/URn3zO7lKepEwL7gMVUxEC1925kc6
# DATA Xg7otVnRXTjT61GUgQ4yFsQEkFTdZRkqB5ecl6K3wV4gkRFmqII5RQzPzyG+lry3466eHVPvJtNrcU6plC6QvU6ujKvtmcVW9qzQ
# DATA XienwqG9nDlw8eaApn2dzQp4KVZbrsoCuAwDYKPx/5TD/9WM/lIxF3LBgn5ds0Z1GRywheQDaoq1oZQ57+tTVuAaCNUrTsJ8Ot+Z
# DATA qq0RvAWCRULicGLepIPilMuCE4pTuQ42IoM9Zl8v/EHYgJPC9RZNwkFBWXI0oMXdGYov6nIxwlibUA3hNeRuhnniCGtTwOwYgXlA
# DATA gYrLA84pauNwzcSjImUxg9g9si6m8SjSjipePkPoWIaG2VIQm4VeLHaIAUE5SpijhDlK2OVRwjYccjaaA21qOl/tNOAss4CLmAQ4
# DATA UpgjhTlSmCOFOVKYI4U5UpgjhTlSmCOFOVKYI4U5UpgjhTlSmCOFOVKYI4U5UpgjhTlSmCOFOVKYI4U5UpgjhTlSmCOFXRtSWK1d
# DATA 7fLPZyKFNXpBr/0ckcIWlp43QoXZ+eIHXtVv9oN6a442VafesRkto01Vm5JDXEZSBjVWpBRSlu/nlHrmy67i24VXz+W/eWcu9KDl
# DATA X2LorXoWeK2VC1xSlQXuV+s2BCwXeKvXbLd784HXg9aFh54DvdWExSaQMr+egd6CZi6AKAjDZnWhWdDjnu8392vBoNL0/MYJBLLV
# DATA daJxBgAZNzYNIJN2mwOQBWGrvgGALHcFALKg2+mVMwBZvRNEzbIBkHV6nUo3sgBkQa3Tal06gEw30LXwqZIfaApZ7n4zOuoFgmAT
# DATA 2lg+CM0by/pxnVMLjkzr0TYWZZY8s+myQKmuLJCK7XiolJasCftsEOXenPMoiGWA53j+YrxJfkB2AkyqJR7JivFISqbML7MsWegL
# DATA Fl5Qua3nWtR7+5ldMhf9Jttzy7horVYrT0PDKvNqSlmu3ApzZbHG2snfOOd7MO5DhyFzGDKHIXMYMochcxgyhyFzGDKHIXMYMoch
# DATA cxiylwxDhrpAoXQHUSHiZaLubrnATnf+NCazO0p3f/5RAQ7V/WiXLdgCOtoH+GkXVfK2qdB8ugzW0WR757O4ty0P7Xymg6YWChMk
# DATA HHWi0ogs1J2ietVtO/jbrOqsD25sS/R2bqMr+HDrcXaMrSs4sc+tOQ72Eer3Syni2Mea9yL99BQllZU8aGI82Va9FfSJJf2UgFH3
# DATA xu5Y7d5PfwzD7jalD4G/Sr/tfMZP745v85kMihP9+AO+RvFYmppcgk3W3zYZfltqHSb03OizGkZ5/qbSd6a8V0g4ffLHKD97j3FI
# DATA Kn/+ckLRZ4IH5UecSPaJLX/789WvY9JbJ4oH29uU1CLSvHOTTVtA3lSWUEwoyaZeUEPi1JfYjbvzWVZhrMsSd/s+yjibi5fVIBVL
# DATA 5KrkkBoLdj7LMgxFh+KMKRvjVxU5jyXdkM74xg19c2k8I9PkMxXzW3InTtnRfQWOCE2sP8Cpu//44p/UmUZg8+Ib/g51MRSJheCL
# DATA /s6asHE80g77IY5L8vLHYuifZ3Xhc1VHeDKp2+RiVVYP3M7V/ttSz3Yxg9VVz7qhUAnK+RY1mY1ESlgIfVwduJXRhdfWGbhZm1dP
# DATA TXCG9KSnuHzt7sKq+VkOzPUz65rEQ6isZu1BJQpR0Ukyc8Al0eIzKPGA5kOmT9U10DwmY8VOLtIU7EE8ouniskCxkkYPRXOZ5Jgx
# DATA TmfijDoTTl/ixdeXOC1J5jroTvDKSs5fvx4n8x4OwYPIAfFVfXA63MOrpskwmdDMbC1T5jqKVjw/R7gvgzSzqLFx0aiZZSImZ2TN
# DATA eLklIqnSvMJ2xy9raWDBbBo5MXqZugUCnlJPMpEPW+j9CVllBXE9iZY9Im8sb1nNS8aYRQKuJ6yH/mwyZamvWL13TCP/SPQTEiX1
# DATA YUTs1wh9nKQ8+gId0c81HGdCORNqQxNqrn91ol1OtMsaflcaX9dBzOv1WQymVl62ykh5vSW6UHZTwsgzjhI0tIN+khuhBCGgB7CS
# DATA dxciNig61tQJZS6s4GPRE2qO4SDuQfEGottwPoiE1CiKuhozdlp+iomoAj4oOW1IqxeWKGk5eMom8JRhIkXHevfq8zogyoTdaCKB
# DATA L59X343dPsLNvsefVt+pzR3FF+LPzwM6xc69U6rkN2E4rtbJz8oix7Jgr54Wx+dZUTayYfyaJLO9ftYYPmHYO0t4aFzSbETGI2tR
# DATA ZRum0Z73k5i1rTpsHnr6BD2sxhmLzY1ZvhfGJsVhL5peBGXgHPkXnC7/3ojSJx472y20ALRxFdzJpJcl48QVnjLP0DYdDsLBE8or
# DATA LR/I4eG22QCYbkY1etGIy4DF23AKwuvOJlpclwapi2FaZM3wtHCGyvp8y1q15NvrNMbLvj9m6sxiU/uUbUV1LopWChli9WgEloXk
# DATA JUvTyWJCquhdUToteX/NQIyo0x/Fn84io6BIlZQmdGAlTPuYdvRDronI16mquBeQm1k3ddq8PKEO6l5PcvIDqjusgqilmg2G1GQS
# DATA pZGrEFuoCjVqkPBk4XaeQApyzpRVuRey7KJC/g0iNcnkbFcackbUu5cfhp9VC66frgW/Hg7YjlBThchm0cA44AxJZ2NMwCiB4aR9
# DATA qOYGHdFZlJ3OJY9XapC7LEc+UWw3yrVeFEFEEVMtsiiidBx1YibCivrl5JD1DM0kfBQdXEQO2mPfaStgeX0WZkOpgq2gck3MRU3B
# DATA pWnXkLs2dPaK1GOmYZ0QVB7KqAMysGGqYweF1yeLEPULWcYqoCx8SJUaOpD72Cqm9thcW6jKC+TayIJwfg3n19jQr5Gvac6t4dwa
# DATA Z1wTWukCuTSNclVlc/RXmOJUzY1345mzMtZ5N5jJuJJjzxu9eZkDu7/VyUV9zUx6eVeDPXKaK3rWy7mUnY/EzhD6lvR6YhqEXbEL
# DATA cg4J3tVCP7ONZHqdbbU9ZUf5RXQLH/GGfrxCIqWeNj2j/m7m+VU5volhYELGPRkvfOYOF4fhU7mjLOfkojEfzVvtO+FNMpwSq0w3
# DATA jqp62kRVfzdRrZwYVb+5cVRl2w8iy59Oipu+PYuduWLiV1sWPd+KXmVN7NSqoPFnybkAnv6Bt3eT9ykOycSWG9n8mAzvvCrSClkW
# DATA 4liIXQezS7k6N6bBfSrHcW9KEFlFNr4Zq32YSyscOGIS0WSwa5naOYX//0y2aUdPUGli3sMoaUA6MmU4CGl4B2xnTI+SgYYZmKIC
# DATA ZbNYDaRUdEI12RJKqtn7ayEtMSQngyLDLHnHFr2lCx5mIjRReFEKXjf+xS9iDCnsXhnNUgjyp4dk+ybDNPOi2jHrR4PxCQvHc6Wa
# DATA LR7bftVsGVjyX/Zs0eMP8CEr8TMFJlu5pFFGU6v6iA3LJfZyWOUW63A2IZuYTDqbdvjfGF74NWiDeQbh8W/w9yLt8J+PvmIe4Z+O
# DATA vj/6vXf8N8dfHn139O3xf6Env6dPilvIjEMQCyVwDtljIOJXwCgef0E3/O74H+ihb3Hb90f/RuHoJ39/9D1wid8wBpGCdMzD52GG
# DATA YapXNrHgCg/iCXKUnikofyV3OBqJwcJJhu4sESaL6AGVotAIYFgZggf1pNroGcdRh2bj6+CGD/U2BhoAGK3m0IbWZEIX2FXDDRdK
# DATA 5fLQhqqO6NvA2dDEHf5l4X5sX7E63EdJT+1puXC0IUcgBzaMU67sDmu4WbFdONbw/tPxAL1MqJ0hw6Q7G4QgrydT1uwpeR+g7+e+
# DATA K9vnxYtf2BhPz5r9TxSH2ZB7ylS2QcGFkkxDvZYVjgQdswA0PLkKrrZa5lvWs8IZnpwGhzN0I/05RnrNLTzLAP9yeAqvbHC/+LF9
# DATA o6H9lCP71QzsUi3n8sBiFj6rlnMZcMK5VGIFACQgxfmLO1Zi9TnH+QSF4tJUUDnQ1vQm6hTFw5uvZVuxluiGlTRir+h8vm1IJDRe
# DATA 1ix26TTp8Iojj8caFcf8OK4lXZprj1IT/Wg2SbxwyPg3HvIjMhviToyl8ZxNkLMAoqc4WIzAuxG8UWpHtVorJOuBivO9KEwRIbbt
# DATA OlO4YsRIZK+OUOpkbV0VdXt2KPXL0QodrdDRCi+LVrjhULPR1GZTy/gqbfyzmPgXYeE7VqFjFTpWoWMVOlahYxU6VqFjFTpWoWMV
# DATA OlahYxU6VqFjFTpWoWMVOlahYxU6VqFjFTpWoWMVOlahYxU6VqFjFTpWoWMVXhtWYeDXakHnjKzCqNvzo8ZzxCqcW3g+Nakw8L2q
# DATA X94vtlqf+o1iteE1Avq7Xw0qn9ZaXsWrV7xqY7/VyuVSx29XO715jB2FVV+KsastkA3lpJ8A/Fp5gF9Q9ecIfrVmVtZybC0j+EXN
# DATA KOwsghMtPmAzyAVfqbbywbeqK0M3ycyFXisHa0IPzhS6XSJN36vVGvu11pC61mKttV9rbZzT/iKMsOF7gd/o14NgLpRO0Gm3O0tR
# DATA lKfHDkq70dhBaYIWdrDeDZqN7onYwbDX7tVz2MEu/d2tWNjBbj1oBAY72O50au2ahR2sBLVm9dKxg2abGoT/9zaar6/h9ol96y3Y
# DATA Rdocn3ubGSjV1OutiLqbOCxI/JYCDAO1EldZoPVhYXHhBXNud9to1AWSn3eTuef5sAO8uvyxw2TrdOMcCrTphEwRIzcf1J1w3lCx
# DATA sIH5yNqbC/SIrpa9ysu8vbKYkk9aBb5P/kv9sWfc64mDc9lamM+TNWbL2iSzPeGAgw446ICDDjjogIMOOOiAgw446ICDDjjogIMO
# DATA OPiSAQdtvpskW7wYQkrjo+KI/s6Pm+UblXKBZpbqpwMuwh2ZsmnM1305JMMH3dDIbvCv4NJ1hgg48v6//8NrlfGtG0Xj0of03wi0
# DATA NQr3zm75tQ+3PmAtdT5Hxws1CIR+lCBKPOWhCEtY5vAN4uK1D3Ev0/HCdooQd8xT+MTvesc+yiap86J0Cj9ydMv7j1//v4jMQtq3
# DATA q5XyDbnK4p7oGhCkRpk5hJg7233S2W53pvtFP9N9WlLYdTjrPediW48JexdNwzxR8t5Dtbe1XZbCwZ7p6fDn52jkZVDA5g+zXzQD
# DATA bFES4KwEsLy/Vp/Vf5epXVIR5DW9yOjavAHXY+h1E/ohPeAz2g/ghETVYimgfhhPSt6jeMruJy34LhVQhMtnYzmerAo3d3w/zKSM
# DATA xhBtTHp8FjkTzZlTuFko5ycRTOXQyO3AJrp6pZtndArWakHOGHLG0LwxtNCjOtEbJ3pzkhl1PcRwHkh9ZaJFNzH4i0+StlHEeWi0
# DATA G6gZxnsjRf5SGmoKHzmhYaEDcYsebhYliTQEfhXuUY3H4Q35LN8hOjRwQw5s7ZYlmikbg78eQ3UG/rFMycbmwbDvQlQ7HO5rM9wX
# DATA JQX6JCrpU241q2Ff7HYUWWj+uPpe3p7LPctj/vQ8wLusvDgld+XRGn6SzlUhrtxDq6DSFdtKgCuPDxIRa0pmEIwJIccikJUhWoqW
# DATA SEQND9kLJbJMYh7SuLYPL/IvIM8yGebVi0SliGy/JBvvQgjCUO0IRaO+x4ayPnMqjUbNDpYLOy8KQJuFN7FJsgSaHNNSDhgbsKDM
# DATA GUMPWILQ5+NfnbnkHm5ccg/lgLlY6bro3oUtgo4wZDYAFceeUv9OmfQVjVkdR7GE8ugwFB9L+ojaNxWBTFLvaj4jPIZqXxT3poNo
# DATA qsACExWXdJxMz19kuZRdXZllvckpy+wn62hlql+SMvsJBIiQj+2EImQDoliaSK+jaEGzPWFkUe5SJ46LSY+sEcPT6kUHojmlB7ep
# DATA SMLjTlnc4ZI+YPobM1dMo+PSb8/Sw/OXVj5Nz0Fxvb9xcb0fAtzOixnU12c8qrQvWvqmMVCvtwd/+JPoUKz9dggFLa+fDKVhYXIw
# DATA 4tBYo27kUUFNQAsDKge8KnbA9+Kngo9jaEJWmPPCb+cvtHzKrqzQslH4lGX2eHWZ6fFc9YqiHIhrWXmJPwL78DEMUBNKhRU4EEcM
# DATA yyN31DjB3jjvLpdvj/Fd1AlBhAzjnlieODbljWd8eI7FE0ZAu1xAv5fF/fqXSGXTEnk/Usp1GD6m6idFuJTzQZEeYKQ5ibUhQn2J
# DATA x8e70AIORZBQwICq1XD/xjNrBACzm4eyONVGCkpX9O8uoM0sJuRMxXS1hLlzYUxeBj+bFYRztDlH27yjza5SzsfmfGxnXGxc6ZO7
# DATA JMFpmZLLTA8jICo3bEzjYnuGUINLIs/lPFl67wnsfd5kjeWnJu+b4Zmw+v0E0FkWiumurEsZNe4k1Fl9Qw7bgfaWGXAXzwvUrr3t
# DATA zvBEwJ0EkAHu1HcLcLcUG+fLZQ2OK28MuZPdPHAX4oMwxoSCDJVizqs5B6J6IPMe6hAWfHaNMmO/sK3dO8BCJu8vapRXe/l8nx95
# DATA HD1FT9S1nqJf1jxW48feprsP7Wdq5TVuwpWIOm2aYjctWWrT5xdSZ7vuDvoUivcJWZ6j6LBkSz4rXWfpBOAQOkg8n1taOFGwOL1h
# DATA bUzTJGW6Y9WZOguKE6ZXPHBT0MYdLw4N7lvEY6/c/Vpdm1+stp15DLikAqtWylzvrBZOfdRMwy/VntxOvqZCb1rJsFMoWoW9QBb+
# DATA U+n6RhTHgUwVWTV7PJsA9C4L20nK+qmWQPYGELkXxHjOEHLUi0SdSdibWgi59/S14vHfHn1//KvjXwMid/T7RXTcvyzFv9GXr+mp
# DATA L4+/OP4VLnv0z9d08Xf891cAx9GVb4++Ov47g4T75uhrpZAOha8xtFNpyHaYuGtv6rNlHnqmznh/Fe6H3v1uLGexRPRe7Svh2W9v
# DATA EkejLnUg/O0gmQy6xvqH53s2Ft8pXAniOhscMl03gUtbKKLsNMgWKFTPg6eip9TQumsRcq9DQIO1Jjz+W3gSjiOXzQhMp3DVHLnl
# DATA RXN5MLk+RYfJBRmcmuurvn4STO5eKJLglwGU481XZDvSvzQmiOsKozkajAPKbVZ0Fw6UkzwL2cwZoXOTeZWZTmnDRk2mhtJBkeWi
# DATA Kwov8NHwhn6Xre29WUiNYhpR3/ZGnD4pwPqhp+89+KmXjiNFysDxd0qbUoWZsQ0E1+J0A9rc8jq62sRZ2gavC3ZueWIces5ZD5dk
# DATA PWgs3ZmNhpfChXh1BsMl2QsbmQuntBauzliQSrosM4yhcD0b2mVQ7KxsAGgOi8TdaAwOFZkyZqA2OcSz+RXZ0kmGwxm6ayzgvYMZ
# DATA RIcdFiwpklK+dCJ7xJ9E7KAQ7x8yLFWb7WmkpyLj6714wqdo03Rjwh1AWqnyzWqYGGXIPlmEE/FzqF97NFeO+YAD7wh6L/mERjSP
# DATA k9ehDEx605L3UMdbDigoWNi8E3jBbpGzAhpBZjQtmGSG/IAuDqSD+5TJcUe8x5z2kbhreC9nNGKODk7Io3UBRKaqBOWqY9455p1j
# DATA 3l0i827D0etMB7vWmeVXPtO4CI/qWecZDoDnAHgOgOcAeA6A5wB4DoDnAHgOgOcAeA6A5wB4DoDnAHgOgOcAeA6A5wB4DoDnAHgO
# DATA gOcAeA6A5wB4DoDnAHgOgOcAeNcGgFfxq91q5ewAvOpzBcBbtgK9EQXP4sVVMhydnEbL8r0xp1AaNHPZVQtajSCaI6tVKlQAtTVk
# DATA NevVrTO/ullpV+rVs7+6Uj/zq6vNRrvWPfurq9Uzv7peaVVrjbO/ulZ+ZmVdazyzsg5qz6ys6/4zK+tcu241rzLDc+36dK8+b4bn
# DATA 2vXpXn3eDM+169O9+tyNq/zMyjrXrq+2rHPt+mrLOteur7as7XZdCepXmeF2uz7lq8+b4Xa7PuWrz5vhdrs+5avP3bjKz6ys7XZ9
# DATA xWVtt+srLmu7XV9xWdvtuurXrtRUaJ351efNcLtdn/LV581wu12f8tXnblzlZ1bWdru+4rK22/UVl7Xdrq+krG3XQ6XsVRuVflAv
# DATA 7zeCt+lr3unQaNeDWmfpY7Vagx+r1hcfq8HR0TiNOaYmIBZc3q/ngvSb1WplMSZBOfAqQdCvlIfVwCv3K+W53GgHUdBuLEWyN89E
# DATA U69mNHXx51g09WY5jIJ6nqbut6p+JcjR1Of46qCpt6NWp5fR1INKvV5rG5p62Gr3wnJGU6/5QadSvnSaOjuDi23epG88nbLYrrHo
# DATA mbe1KQ5r+5l5ILpZilu27KY3ajR4gya2ZzITfXG3Yx1+VnkNHwTbbFtG3dqWsRLoboW6nrUuxaWcloFZdtE1go8l9MNucnCrRT/i
# DATA T9lTpfh5iV41hAtsxRJsZSG49XmYBeipraZ6/5osW5lfx0t2H6i1Xl3DzDKA2guaeboLcycK8svb5dWwdbuk1rjDl9U1dnKzX91B
# DATA 1R1U3UHVHVTdQdUdVN1B1R1U3UHVHVTdQdUdVP0lg6pnFqPSbtjeMfYdpdp7KNofmfDHbSFWcZfNtvLgkHHlIipSHCbdaFfQFXRR
# DATA ttmiUWfXRGSiCBtktxIE9YCvYpYnsmnprmaj89RYIc7Vb2iUGpCOiMEFMYUw225TAo+HCjaS/VKXFyTTLkLmwsQXVHNuG6WUhupo
# DATA u1yo13ZgHOGgyvbNn3+o/ru1+5c/wL8TDuajm3sFKleL085l6y3C6aEqsPvZfjiKB4PwVqUwHsxo2p/eqhYgGXcr+PznHBWexpq4
# DATA fKTx9I9me3tRKuMiC5B5D+++d8tg4ztRPNjGG27MZ8+PS36TafJvxa8LtP51lv/JdHjnQpEARACHJvkIQvPjx7FA5f1SRQeJzlmx
# DATA RDAqiOAFNPVE6JBfqOoMNPGmkOebkrmsa5AoCUGyRQHpORMyDVm6+to6c4ozOO6tsGQ/MxMNSKTNydPS01kl37mNkQWOqzmNHIh9
# DATA qARAycWWvOEYy0Dww0JeoMPp1DmdutPo1M2JuTjFOqdYt0TzZzXL4roo2XnjCdopa2jl42Sk7O7mJd32ZpDGhTDTKu02BbYYgTcb
# DATA d2IVNOZ3rMaqxaqYRjsvSZdHay3I0Zn7+pU7DzA0UdeiIy7ecC039TMZt5ViWka+gg2cMKEeGECgbrCMU2QV/SkL1EtwKbR8PRnz
# DATA 9VT3NsRioTWl1OaA2PKsJxnnCWUrinMEbXxKSgzjWnMI+chf0uPoRE8BURNZL/RU5mEaqVYp9XG631B2EcvtZUq3amjU6X9kDClP
# DATA G1JQrAPeR5SKaT4s1BOVQzHrWJS8n2HkXHik059Bt1jrjylzpeTxpCE30AoeWACo4qkt5KjCmUVBxiUU+qTnRh/LmJUYEWZQMb3K
# DATA nCVI1+XIXdXFS46oXp0bi8mNaTJWbAOuK8mE1eSgfpbOxhihseUYes5U1zpR1+r/p+ETgSvAKmR7BpOv8aEqVD24hAfhYWZRyQAk
# DATA sYev2nscsSNTx43BrqFlijGI2B5yuG7F03XJ5vfjbZ8klGltDIYh1zmaN+iEvwsPimfZ9loVkGlQeb1AoaGyaBdFCQtbYy45lpIL
# DATA u9SFx4ZsowTldAJEhk7Dn/QEIxOU06wbBnSGWSszphpT7bQpp7KB+pxBcshe33nImiiDvfgCZ9mo4wxUZ6CexkB15ujLY46uNDOv
# DATA ubCyvcC/iDAb5OxUaTH097TPAxJsFWWhZo+wXo9CYV1X+eXnS030JKCDtZVDcHO8RebOq9RBz7dUfRwtt8mrWZ7b5KWOmoUD/ras
# DATA vSweE5PW30nglpI3Ho46OjpKfenOTxZOmbEHn2yeFULe1rP8hdM1BwHTG2m0Vvbrymbsa+Vpzh9tjLHBtly8WVllWh6YeR2zsWVL
# DATA GgYnDfawR/V0wWC+8gZm3hy1HHxz+Ir5uvD6LEbNX9TblkqxQOw6kfAxUi8uUEQmEZkuYZusbgX4mGvvOP0qTUETgPvVO4+GAvym
# DATA 3DQ0ZG5urOUbKiLyfn7WwjLgoL6Po2Q8oBb6Aa97IC+y+QermSniosgk53TC84bjNETF1aA3Yy3OI6U5yqr0dHTV5M8Y+5g96PJU
# DATA zDSZYWAnhMw4GUuCWYrqqlRpr4nYgwkZkZ3p+ojd4/UGL4XFf6ijpy7KTJotcC9EVeI8Qk4eTFg1OzkY0ZSNfoqHkEPXlXVpbO7J
# DATA ZG8xNi+hSLHjJjsr/qxW/HyVc35m52c+twG/crpweX5mwxOf53EYrNq1xHxdBX9Zr/zSD/efjmXfDq+CkykTJbNU+1pP4BlnwZh+
# DATA z7pkAL7NkwDM/sZAY2P0f8DdICKWBxjrGzLGspkmzHOF1So7flOO+9UMYrUOL9M8/rj6XpQ6m23st1/DKF5MGa+lm9ThGyMmlGG+
# DATA /Vb8+omIaSuYfB7oiyaetZOKJTgFZ5pX/RX0j6IqF7AnhNorZcL6SJvHLey0vpLxpk+KbnXT2PJGjqwDG1LHQH3HXByxO8dGjU+7
# DATA ec64fDexu+ulZDHpZRo7qhswqe9rVDJ3EJOI1yy0Z/r5BVSbtQLpgAfhbETzISwIpNM8o9qkvws4DZtdvEZgUYbQs09AZgZCWnqZ
# DATA kncXl/djsnfsRTK2hKKnHbWa4cl6hDrq0FPUTGzwCAVgc5hiwxrPOnjGJkYUr1UoQ2kSxoreBJZ0OJaeeq48MweK6h2zTSS5jLXc
# DATA IwbJs8hFzopd8mgOx7SEw8QrbPMgJmZadZNI8FFq5ueBE3WASkaZwcjQzlThfcwodDIn+0WbNVnA7Fkad+DliRMLmX30346/PPrD
# DATA 8T+Can30p+PfHH139NXxbz2ws+mHfzv65vi3i/Tsfzr6/ujPdN/fH313/Fu6++gP9PC/072/Ov5NwaNP39OTvz/6/vjXoGgjaCFp
# DATA /4r+/uboG+Zof0GP/CvdApL2Hz26C7zu31Cw31CwX+Hpo99RtP7IT1IQv6O/vwOW+/gLR9e+/hNC6sSSYVQEWU4QWZo7xX1Vh5op
# DATA QHgDXgbm1fIHaoQItU1bECQYO6fIjBsPIsULU7Qr6v0mGmrPbLDMaF1L0X6Ih6gPihw6Ozffy7qHq4ZnWyVyecRsVatSa6bHF7hi
# DATA pvN3t6Mw665fpy9cGdsRjfUXicqmcJldHeuRTG2tWJjUvaSs7A0K7cJJ2ff6CXTqQ0DMaUwdafuVMpjdToooyb0JldvCHnDx+ZLF
# DATA Qp3UfjS4jbj2eZsU2Xep7aUKU+kN9eaU09S/1RZM1pqeFfv6xMg77LUb1s85rGu89elG85fDc3uFI/lFDuQbjeOnGsavZBSXmmiS
# DATA nu32faZN5TIA1SaNsj10VfK481YeHy7nguykpDTssVRGOO1LGnrYCNmXJVtZfabpeShk2kn/cNofZgVm7YUMdW4oZDGG4k2I1O8n
# DATA nomugHc1c5ljM0o8aTXL4bwl7y7/yALdqZCJWdFZlrBUr4qA0mkyJmurryi407CNDJMDdmI9ZKkygGzKr06cij6FztIOnBGOL+34
# DATA 0o4vfYl86Y2GlI3mKxsavldju5/FdL8Ay92BpB1I2oGkHUjagaQdSNqBpB1I2oGkHUjagaQdSNqBpB1I2oGkHUjagaQdSNqBpB1I
# DATA 2oGkHUjagaQdSNqBpB1I2oGkHUj62oCka5VqGARnBEn3qr1yL3iOQNJmxXkjerSdH3CxBkG/Xq7sV6vlt+n7L+bzMQpaS/BWTc9v
# DATA 1vpBrb7fBN6qmX+s43cbXX/+saFfC7wKPVotF/2GV6nSB6/aLNZqXpX+T781ik2vVvUAz/KL1SZfq+D2wKu2vKqPu3G57LW8WrNY
# DATA 8e238k7IPNuq2g3CenkZ22pJ3QgQn8a+X5kHtLXrbb/dWRZKbQHGZ1PSqnlksIRrAbzqWfWt5knmURg02gsxrFTq549hxa9mMQyq
# DATA FxzDVusCYtisZzFs1C82htVG5fwxrHKTuKRSrlEjOXcMa9XK5ZVy4DfPH8OgHFxeKQct/wJi2GhecCmfBqQng5AG6cl4ZoH0WrXA
# DATA r7byIL15bB5fCedBer1uKwoykF49DKJG04D0Oo12l+boBqTXIuu42rx0kB5v/yyus+5L1Tk+3efWQ4ssupxLyG/mZz06E9jGgsuW
# DATA 8h6bHreLlW60t5MLeY7Q91ZE43ocFiTu887vKru+Zcmb4Xzz6/cqZJ6sbbqmVtLmO/tzq1bSEYynNx7lLHfjWMARA+0Lx8aw4imX
# DATA gGrLHNDsh7PCU16wRTyfqk350kBhWF6JBpZXlm+HWnhFCbEmm9Wa5ZOJqhuDXcJkFQed1mroXlbCBbtM1swiFmubSq5VjZSze33h
# DATA 8FQAtX7lNCorqNPNRx0E0EEAHQTQQQAdBNBBAB0E0EEAHQTQQQAdBNBBAF8yCCDqgpoo7rJ1Wghx6LMACd9JgWXYyrclP/h02K7U
# DATA lrj7v+7ixyJqy20ORMQjdtXwpr5S3H5eLlQKtUKd+si4N99Dqtt2dvTj5u7b/DpTEbdHhRj8t5Hu9nbVE1avt3N7tDaXAJDTI1YW
# DATA P/UeGSWf7t55qt8gPRldUXbuU9Wd0X+g19lzjDGOjm3vfJbLydt8CFjbipyhO3OpGu3eoQTx8UsYozxvR/Pjc3BIQklOfirMHwXN
# DATA vZKC4O2wOZefhn64pc77oaPIauUujbosISunjKk+CgPvoRw6RhLG1MEy5s4kbMoWL5B7P1Bv3xHLf3nZnJCSabK3N8ilpBBTO0ct
# DATA kiRxoD/H949MESigYrLLtVLb/mkHOo9I7k5hL/fTWzSJoIqd0JAVUcaMOodSaPwaelv5Nb9ZvlWtlm/vlfboXhiLP8MNd9mo38ap
# DATA hYIKULah4/KOvjt6Ok5GEGwLBw/D4fhxkn+27C8+e6NUriNClJARFdH2HgLTX+RuKOnFI17ZxJ3sgdqWT8l4e1mIDSomKcAHkpks
# DATA mAi44zY+3PCZ2Zj0vCYXKSde//Kj5m2ui7vWRAYlXaiWsQInAEi4URKua5+rOQkr42sEo64On2V1/7aqGp/rNsBT4Cm2G3ER3r23
# DATA exCPaGJV4lPlXC+fTn/5S3XxIGo/iaf2T9Jb3NuZ9mmc9u5PJly75Ui6NU4jfZxFUg9++UvMB+/eowiFB2FMsz/OPvTTQ4yTSyrz
# DATA KVtRMrYakfSP0lBuf86zfTtPpIwkznnzYvH4uogeiQIPpA/lFHc78iKapum2Sf2Omcou6er4fFw8oGldrtNDkZnHZMjbsWJJgapS
# DATA WBIk1vjpEROU9Rxn7WvS6iUY8amZQ7VOy8Zp2SzTsskftHaiNk7UZlNRm5UC5JcldnMf6y48ukJtYhTZsi1a+ObZCahdhcq4mAJ0
# DATA +TE+eNsojvTmMB7NptFJOtb6WdM5mQtGclmphs9LQsveEKUJXVknYa2P+VK0+bguFOMP0WVxficsnEGlwwtofVlp4uKkAOT+fMaY
# DATA 9SQrJ8yPbJbykrXkDU+BynxnPiO0ByfLCnNrlnR+0J9Tt17/Ln/zd/n5bMaDlVO9q7L5uyq5d/GD1VO9q7r5u6q5d/GDtVO9q7b5
# DATA u2oLUut3glO9K9j8XUHuXfxg/VTvqm/+rnruXfxg41Tvamz+rsaC/vudpnmX1lcxbXiluro9fX0BxNT1UCFIF61EZI021Pc9EbQS
# DATA js7QVE46MBkhMXsANpkn6UNILU1yXZ6E4Be8asELeDhqgKIVjVhI1cMOAg5agMJDQwKzIkYD1XL/qYf+lWEGluyX8bZnqlI0TGHe
# DATA oBXBMAgiTLEaT68HtoGU+fMvJuSgrW7qtH7q5GZKL+ZM6bQg1mcuC8qbu7J9XpeB8LTkNy+Y22mLly6Fda7EybKGIJ88NC1VuCiQ
# DATA GV+Dlb0G4qjPiVjghvLmXrZzUBtX4rXU82U5sUO5Q5NpqGhCJckYWneVQms4YZErOEbJGMLTZFaRfcX8U157EbHWsUzjeWsXdBgx
# DATA T+ddTQU8oAoqU27kCT0VUjygd+xjJ6JQgfbAJmP5SXo5M3Kgy6fF0E+fizD7WDNyTjv2KiXTn42llKuWzlhyxtIyYynXVTk380vv
# DATA Zl5pZD17TXVd86k6hywrfQgPwIju481Imcb6eIKmCRnguUa2N6P5MbuaJ5HSwF6Q96bmYhTALWXwRE3xuQ7NOZZzVsOiiLq5j8ZV
# DATA 3Yx5RKLSNfrKGDaTXs8L95O4y6ufoyRO2SU+0Zra0h1k4PEsYVrRreQ9oiHa61FoIqKe8jqpHCXG4DuQuKS8fxGBHBotcOpZZu2U
# DATA Gv1sKoYby8iB+d3VRDjEuOS9p3S2vWHcmSTjPjtgFD4uCjvslsfzlAPQrUb3tdwTn7l7QrY1RkoNXmfKo2gqZkSaST8PEmxkmYLm
# DATA KxvwxiFDDa1uTwP0St5dZCYFHY/HCryNINgld9vDwjauMno7lLvsMvdwRgJ98Qi5o9Hvkm5OlXdAb+OV8TXJez+EXSPc4r3EqM7j
# DATA KptbVBIwi6WANXaeSl0q+TQZJpNJcqD0vaX68yq5Lhqu+p5k4gj7OpNZBxowjEEX31V2iDdLmzDcDTSdigoDn6Isr0vPmyzPz54x
# DATA LPAsAHIGZNHxFCSCtSgWqFKETzBITXkI65PJYBuW1CYxaWBTLxXTkG7v4YQ6moIZB6U6AIcomAC86EnE8HnUPMrGoRQSk6fJstxD
# DATA VR6ARE+RmY0wMGNNKRmn84kUe+okUtDrUs955QrxkRyVXJjNe4QRbR5schtprV63qB3HGOZWepXXOZHzCyWmFNZkXuZX5lee87W+
# DATA vJZ+kWZlGt/FvoaXS6TRZCwsYRZwI7rYt/GCyUMuWVNZp+h0rE4YLeVi38pLJ9j3vbph5l94czY4py/+xZ39ZIhLels3SSapzbf8
# DATA l6Pvj/8WQMrjf2Tu5K+YcPnF8W+P/geIkkffHH29CLj8FyZYAk/5hXf0Lf5hmOW3R98c/63H6Msvjv+e/nwphEsVML2IsZbfUeBf
# DATA H/1Z0ysZjEm3fQvK5dfH/0C//dEhLK//vO2RzLQmCYwkNoWxaJTM9vpTZuSIzLQaXgfxFOoacorYTMRmI227kCmFUS9keKsM+GzB
# DATA pDJzAwYFZmHIZ1DX8isf8Y4L6gvjgfcJWYxsRDmSZTaH073AVWMslxbM5QEtuV6m1vxRV1NBHuVvRmU1tz5QNRfD20XSLMlYZSEF
# DATA tYYpe02oSYwdyXKD0rpwkOVdtbVqQM3jsHgQDp5kpCYyq8HbAf5HJQu2bifEcSMaZSeQZ1N4nbCLEcJAo0ZRREY+FuCpXh7y3EBR
# DATA kHB+frxAsjyh5q02S5Y1p2dFtDwhEY5n6cb484zxGmZ51qH9pXDNXtmwfjmj+kaD+mnG9CsY0qVeLskBM6A/w/ZzGYTLJUn1aB5K
# DATA n5g9F6plUkkuYlngdc4Q2R53MM4ixZzcZVHmjc/q4UkioEDpm9pYN+f4hhy3UQ61twncMufoRpRUMoz2J7u7sdXPO6A5NtaARfkg
# DATA FSqg99M0M6Fk5CfLDbu8exSzGIaAoAnjEa8tGdolrJ1YXqA8wyg0Xsi6a6EhlW+1G9EYOYzJbDjoRxyL0GPThDfY9SJHu3S0S0e7
# DATA vETa5SZDzEZTmo1s4qs2789i3Z/buHfIS4e8dMhLh7x0yEuHvHTIS4e8dMhLh7x0yEuHvHTIS4e8dMhLh7x0yEuHvHTIS4e8dMhL
# DATA h7x0yEuHvHTIS4e8dMhLh7y8NsjLSq0WBvWzIi+bUavde46Ql0tWnk8Lv6xVvFq97lG+eX61PPDLgec3yu/WGk2v0RxUmhWv2pzj
# DATA WtK97UUc5tBvVb0KZXTgF5v0d8tr1Yu1oOj7xQqFH/zivZpPYTeDQb1a9MsNr9nw/EqjGNAttWKVXt8qVoJitTFXJkHUaHcX+YBV
# DATA inbjUz8oF4OyV2n6Xnlaqza98n6j+Xatmg+j3ml2G5XFMJo1L6iVPy1Wyo1ikyJVqRV9yguKUYCYFpuNE8iaJnILHD2/Ka/rxBPM
# DATA ljpc/HWOhNfhovWl5k4EVJiLbzdo1mq1M9DyuP5qWp40BYuW164HUdXfgJZX70Y5Wl7U6AatdkbLC3p12NaGlldt15qVjJbXbNR8
# DATA P7p0Wh5X++J6w4C9+3O+aSoqnL383ApA2wY5dpokehHnpvJ10f+HP9TCb5+0hrDc2FkFf7NieTKFz4bsyYOng+zVFiF7WTCngOxp
# DATA B+TKPLJzWmWowtip+md7jCpsp7ExYAaxFdsI9NitFrjKq9l3Wb4W7KxaY06ckBOGaOfgcw4+5+BzDj7n4HMOPufgcw4+5+BzDj7n
# DATA 4HMOPvcSwec4bTiNUNQ2D6XxtXUDGiOIJIdYbmhpf+oZ+hh6g8Hune3BAt9JpXhHd2SvUTBPP5Jpzc89fNi5MchXMq75O6VPknhE
# DATA AXxI/4EPdduYlx9u6WPnWVxK06fI1w+33lg4ka4CuIHPmhR1z+xQ0KFq8JNmKzmFcHewes3Baneg+iU5UH1avfBne9Ca/ZKZK20R
# DATA RzTIaWHuJUkXZ4s99hOaY7ZMkkAga3S2n/X57OfhjCL/fcFa7csOkl+0avvyc/lL9ds3OCaf+WmNfngkAnUobS07qSqH0Zh5HFEU
# DATA 0mQYQQiGj9ZKVeMT8Mr9xkQW0Q3Mny/PTo4XIINMtmbW2HnOCD1TeICTXg+OaX2gWXQPEbhUNX7F/OHz04iIL1QTOZAbZtbJsxGr
# DATA eRanWc3zzqByBtUSNbqsQjnBGidYc1Y7aqW9djlCNtyn62ZAlpRoV7AGRj+ZJnuTcNy3RMWfmW7aBQAsaVx+Q8nQWKPXKTWLxRhA
# DATA IBcoWKzGfj2YD8MxZ4415i9Tvr0Q1eIPWN5b+kaqjVBIQc93CcLFb8JW5xeNvOgp5aOXji5cPphFi98ZpbNBOBX18kOVvAMkdEyd
# DATA eM+j/m4wuAzZ4hlrKk01d2bGGuBzreFi3xuI8jQkvrueiNDrcY6Gv4t9F9MfH0STlKWYsFLFfHuRhWG2UTGMyYCfjalBRhesRt3I
# DATA OtE5C5qKMwQPVhggYnBfsET0HGsym5ZJkHnHJD2ktYK84aExP6S3MTjKDABpK6qb5aBMUR6TA7v+qCZ0mKlPyYAmJ47SFdJSHQAW
# DATA ta6UpUsFVSAWl/IeQeA7GnkMXhl1qKC0/FRPUQ8o7wtGIStRvbOWNMXC06HWSuIZ0WTWbkMkn8uFmcSoJsmA8cUyDojG0WQGIS9P
# DATA Z5rR8VLuzUheYBa7Q6Wbuhnq8cWZflgGhZuAuAnIwgQkb2G6KYibguSnICsnFs9aS1PxOphp0Q/HDBsOMcOwxbHTSOnuaSnIObFI
# DATA Ru1odUiFPopkMmPpPE5tAUiMlYMD8JNmgguZl3iUFjujpkx9F5XCfrRE6XFTtU1O7fjOm7y0mcW7fZjNjpi73J7Fg67R4lORYUfj
# DATA ottYHR61APQavS2r/QyswidlYSkLSP+YwbPNFVYR6DMrhns2WZyV3Ss0dFtJyUPA1XvNFgJYperzq7IxQr3cusP0rPZTrybcw2aG
# DATA H9bgMcZSs1H3sW2ZKEfu/O00QVWHGd7iT6vv7AziYZsjig+r76OOOcGmLLrzvnzM7r0pabszhynXtqasxtumJkaUNYZmrnSxGVia
# DATA vTojnVnO4aRrpqe8+UEmqiof8/kwB+bindSmO5CdBTKxnfHtNe/J0CRjPt4mU6EcWb3zMGZWUzdimBC11qp4CYZJOh0cKvglfoKV
# DATA aKTYea1GeF3xaCpDYCRymNglmfYTpScaCvRci8cyUHxkpGap5fK0WLu3lRSmB8tMWYfqoNbVZmD9FBn4Ac2JB+y7jycdmi5mWYg5
# DATA KnUMQHHZHZ2a5cBTQt3CJ2qLDvVk93iVgG1j3lsJs32YtPEI9X6R1GkqiiepLJopChiXxUVkl9VKTplfrbX5ZZqcZNhPIPlJ7WIv
# DATA MlkFbwLfk88jg+CSjCx5H9CYWfBYJS8mI+xQ+Z8URIy6c6HEyW4VcYdpzjwNG4xxi7oXkVWm4zllRjXWZpTqxSSb3oYfR8z5eGTV
# DATA Kn41VYgDimXKjphwMlCrp9o3AycCtsGF0KqVlS6eZuNneP/2DjN/YYQlQOzJF3IugGPc53E7hKQuoyv4pmfaJoNTtMl3AaJDn0bt
# DATA rkiJLgrkytQ2+zI1N6HWqYy0Vt6iMD3E4p4mwtEjZPOL9DDnp9giKTBe1oz8WVYwv7J5DXs3oSKmMXIQHbKbIKtjA/ols3CUd1cc
# DATA fjS7pSbInrjMWEOGUA/PDiu9iKoWRcXagjowTuQkqo6StSIuKNAIJ3Fnab7lB2LZW2cPxOaKZMOd9xO9C04rT7MJpnanwSmiSlJR
# DATA onV+l05iiL0oDoiMJTaOpkDz2iix/y4gMe/oD0dfeYz1Av3rz8f/5eiroz8ffbOIEft/jr4++rZ49CcAwI5/DQDZvwMXdvwruv5v
# DATA R9/R37+jv78/+v3R997xlxI6gv4G0LGvjv50/Jujb4+/pH9/izeBRUZvpjC+ohC+0mCyPx995WhizwEFeiQrP9jH01Eq9RkFehwl
# DATA Y+Y3MmCdh3Zqe2IgdhMon7O3EQON5ZJWYrh8F/roTFid30A9SCwS8uw8XksVewvmErPbR4cOJ2b7UFRHcNU0sXyBXC5GLB5Za7j3
# DATA dS3VvyyyxEZTHAI0fSy+ykgXTS6SJxZOBVHQD1MaTmHBkqWb9HoOJ7ZpqV04U+xeOOhg1TGSBbDDDFAdDnmnPS+BDHidxOthKuEx
# DATA F47l/swqB0i6w2HEk1+MJbyOGP8iYvqG142j6RKM2ImVbrV1kmtLz44hdmIKHEfMje4XMbprntipB/WXYlHkqgb0Cx7PN14MOdVo
# DATA fkWDudRIOw+y7VbPvulcBkrMTqs4htUOjn5Cz2HxIZ9QpMDEUhcWFonWJP0dMNgH41SoSpy0aZg+UXtVEIF4hJNjOMansmQzlBgA
# DATA RjJU74PXpWBN3YzsJNVGhvWOtgkAn0qw0Q42Ada2YjIQltgFM+guxNNl9oCyBhh8BDsAq1fpEwrMxCOGc5xrE9WvAXZpYw/ZbDqJ
# DATA pcySUSeajFLHEXMcMccRu2SO2EYjzYYnMDY0jq/MyD+b7/ECTHxHE3M0MUcTczQxRxNzNDFHE3M0MUcTczQxRxNzNDFHE3M0MUcT
# DATA czQxRxNzNDFHE3M0MUcTczQxRxNzNDFHE3M0MUcTczSx60MT6wSVRdLVpjSxXq8WNZ8jmpi97HxajJgfVL1qq/FpsVou+pQ/jWrR
# DATA D+qDYg1YLf9T368WA8+vVTy/XPEalWLDw124w28CA5bPum6v1Wr0FghjAHzVyi2vQu+oNbxaq9iiCxWvWUeQgRcA4+X5CLuF11Vb
# DATA +WCDerPb7C0Bc1XLFpir0goMmMsv5+tDu9aoRUsCCGpWAFWL7NVcrBK1ZWSwSuO0z1v5Uq02vCrlQyXwmkX6y/eHlZpPeeQhc8uc
# DATA xasTYpci3VkLgn7QaM6RzswDC6Sz+hk4ZdwyDKeMG5nFKaN61GiEG3DKwl41xynrVbqNTt3ilLXqvUbGKes2O7V2LeOUVZr1ar1x
# DATA 6ZyycTQ9kVKG8UXftwHmy3KUVdlNVmry8hiGtJ1FEpgJWWPOcjPdWvAjL6A/lYCdjjk0l+SohKAivJlTTaXKONYqZro79/ZKjX2B
# DATA 7Mabs23E87QG4aXTVcjFb80QnrtNu8AcssshuxyyyyG7HLLLIbscssshuxyyyyG7HLLLIbteMmSXsjgsDlc3PEx33wun/VJvkNDE
# DATA Bmbfh1s4jEWp/zFMmpvqGp+PwkX5StMsGKrUatj6/HDr7pgmeE/hoowGh5QbNxD0DcqV3kzkwvh4WM/SuVJnrXgVCaQsILX0Ya5Q
# DATA Hc6CBhmClGM3IR/SxgEVcwZL9P4cZcsdOz7tsWN33PhFPW58FrzWNTiGzO477e9aT9kSASsT76VHlZfwta7L4eXn6gzfZQC38set
# DATA L5i0NVcZzorYshyp2SFyldMZFgTyjCIgr1RXOLv61Ttv8gSfdeW0Dh1XHwiFjpTenByENdXnIKQn2skBTjtHe7MB5Pu07NwQcqJJ
# DATA D2r43dmEK2g4GWrpe3Umnt+tI3CXbOuYjF/eNqujoClhlD09LJK2WYtzCj+Rx5tTxDLBUuuA0wY9O24LOFHZjvDiLtlks0nbCE++
# DATA JEc9rTCcXeXsqjVibXblcrouTtfltAbVGtzW5ei9/PUoOUD3L4oD7XBPNNYguaEGNv/q5cQugK7FKxBqB4i+ltOG54k+Xf3pCHoL
# DATA kZJhMW4xb/vJ3s4cCWjE60AZaEcFYbop/T2HQ6JEU5cMPZlhzPK25RL6bOpZZEuOGEfYy5n9uELOXvwQAPrYgi1jbHGlwX77xPjq
# DATA 57N+VV/IIFzN8rI42zHGdh07ymsizJ4SpjTBXZ3p2CCjToiretREVX/P4cLWxtNfE8s5gpJaX0JrVU4XUSPnqm5RklCp7rwqe01V
# DATA PNUao63lm12S3iXelxTQ+KuYrTcliPNRoCxmk9W+beEjpU+vEC8hmr3RB7wP15PdgLlBs1ZK9DQWFRce7tDjaBfUpzPqhaBVns72
# DATA 9iL2QAMYwSsTqoNIJsBYAKrEqtIYhTnQEQAVA03jEgYa+8ZVu4OACpnyM/bHU9FADwYKweGeYcRCgQrGaSojeTfusXTKVPSHWNnZ
# DATA U1t5IxMfkaOHNBFHY4k6USZJxLLK8DQiMl44pjqHAW5TttMLYuzmRjBn7jpzd6W5u2DaOIvXWbyrTdhronB4j9X3oFncwyATj1jG
# DATA bDnfSfNlMynASTSMGdFRWKW696YwBReGGxY225vFXeAMs4GRQqP22p0BQMjD27wJnIcmLAgcmvtoXDdMU+174qH+p8wJwHg2SWjo
# DATA CKd6zGU7fEgNfAYTStkB4d4k0vjKxSFT6R9SSF0aqk1y4KpaGDhZGhDiMuw5ilgTzgunqNAU4ds2tV2TIaOnvD0K74gBNaBcXzEj
# DATA EIm3ZJ/3NykGp+bnjjXDCxs5BRTyNJp0Yux3zEFQJcO5YFi0zxIqVF6ykvcWOFvcjbI3jaFdfdhcfBcDTECshLvu3WjK/SwnA6ZN
# DATA OJ3zt+Hgmomsx4cbwD5Zl8a7Wo7S9Pc6kR9g1qbZO6rvh8pkQTT3NJgIj2D9kQp6kBaYjpEaaqc2usRMeh+Boac8hAmmNlryyDLh
# DATA IakNSzvqxp1QSlDhM5GVCzXdwpxFT2nMGxyuS+X7fKTYmF+ML9HpvMs7PdUhkdmkAE8yK4wPdfHz9FGRcmLAT5T5OoISnxL/tBhp
# DATA nKS8UmXJexRFT5gSArcs8zyQl3yrqhZasTLHl2H/qXBDoLYIB7F2FIcpT2rDvVGSxukCmYMNsZN0vh8n1DFxfmZdELeaU5Oi2aet
# DATA x6AL4URbbm7VGODeZif2JZCh30P11ftgqLmGqLqi/66nKZdAib6Xc5ajzVJ5C132EkjR78ZTnpVNqNuCEKRAIRWzhntOEZi8BFj0
# DATA g4G8Ex0kpzZrXDzN6l4CKPoudUC6xaOX6hp9XS5SeIsm3QtmJ7/o8zeLi0NPTVMbi/PPgOAcfXf01fGvj747/sejr73jL4Cooa9f
# DATA 0+Vvjn+7SMb5F0bd/CtDbfJ3H/2RKTke/fSro98dfX38DyqU/wouDl37/vhv8QS96rf0y5/phX/0jv8uR9qxYDoOjfMckIUZzGa0
# DATA a4WRBc8vkB4F2YYqXOAed1sHgHIfKItqL2LF4CdwOAtOeKpZiQwZ5UEUDMG9wXoCzrtR2OO3OPxNbo7J7f2q6TdWYVwe+kaSlnWL
# DATA XHd6PA+bvxUjh7mRp3qT/uG0P7xI3A1vsqVpTx81vsszAiD3eCsmbnfYmxNL7MJ5N5jkJm3MMbmeaY81doqo6TD3L4NwMlRLU9nk
# DATA M07FFb2wh1r009m2lbkElRb1YpjWkekCB/cC/mZ9/VttfGTt6Flhb9bH3BFv3KB9ikFbg21ON1a/HL7gqxmnL3KY3miU3nyQvvwx
# DATA WqqfSbQZkK+uLVwGqcakRwjJ6XxC9P6LbBMD2xP9ZKhhMFaZyEyXBjQMdmGXE8oUdEOkSBVjuZPMJsKmyMZXnXA5yk4vQV5x8Jtx
# DATA a9QUPzcGh8a5rkdvM26ndGN3Noj0lkhewoJX0UvHUSeO0oKJf8YuVo7WQSyu14g627AXTQ9zrkCVDsbpMiaaUcAdSVQ+QQ5Q4wA1
# DATA DlBz8YCakweOjeYcm9ivV2N/n8X8Pq/17WA0DkbjYDQORuNgNA5G42A0DkbjYDQORuNgNA5G42A0DkbjYDQORuNgNA5G42A0Dkbj
# DATA YDQORuNgNA5G42A0DkbjYDQORnN9YDTVWlTtnhVG4/eC5wpGY5abT0uiqVaaXrVW7jN+plLz/Fr17WpQyWdHp9csB4v8kxoloFpr
# DATA /MyvVOf5J7WgU2su459wKeWDqbZaXqVW+U9+q+JVKmX60/Ba/qd+0PSant+oeH7g07uqXqVV/bTi14t+lcoQxJxa0a/TLUX6RjfV
# DATA 6CafHqj9p0qLHq14VQqh2vzUhxe55tXonmo9l65a1GzVy4uAGIlQkUz4ou83h36N8gUvqpeB55lLa6fVbYWdZWlV6BkqxZjMD8Wu
# DATA qZWDjF1Ta5WtClyTL4dLanO3E9U7vTOwY7giG3YMtwmLHVOrNMKgeiI7pt3r9uo5dgzFp9lpW+yYar3FAQk7hjqJVhhZ7JggaFdr
# DATA l86OGVArOBEeA6fR59mthvJicVxU6hYde+zcq9C/zR/Z5naDzYcsyJORNDZvhjfbyd7iZbEwrqvSkvVTsrA8LFV6dfmTC81TFo0B
# DATA yvAoanr/HLlGinguxRQmLCMvkD/GNSrJbsK4sv05vrXGo4JoUIb59Ef9qy1Mtl55QFxJq9mgLPNZl59jL82IlQE5qI2D2jiojYPa
# DATA OKiNg9o4qI2D2jiojYPaOKiNg9q8ZFAbbRBqaZ+tndfWjWYMv9G9Pp+6UI8V0Acu7Vo9lTKrUu3eiXXvtcsm8c5ttPMPt+5lal44
# DATA rGLJuYwoh5WmC6aveWaNOfngzg27c8PWyRd3etidHj7p9PBKrclLOVX8OmoulOaywM3J4meqP3EBeunQmsObD6LoCZ9wlDZ7Rq25
# DATA bGy5OLW5KBooVe62rJJQhmj1QeXovgTZOX3eWIHbxlSq3Qm05zyaI0WDw0vQnHtnhEPNU+lhU6WUDXu5lwlUX4L43GN2fak0kgmi
# DATA enOqEzR2FKF+3b0E3bmHcpQYPkAy5VSSDVzgUsqVtefex1nr0AjQoeXJCAeThcxL7IWaTaILVp9THhgjHZ9pMuaUAbLDrToh5tQs
# DATA ZRi6gGmuB7Ek6jNReJGAh4Tq3GF97o1Kmbpmd3KoMzpDNYSDA3ALhxFLyOMWLFSRoTEYlLx3455pDgXgHgaLbVGpqI4QlYnXpx8n
# DATA ERasBofyJHcvB2Eq0dFEIaVWy3VQVN7R2ODNFe1qmlRgiX1fBUCtg6Ip9aUP3+BEnYiHTiY92qMhZZVkgM4VfdyfuskRTr7zNgMa
# DATA T1gKgEbqeYmfuZHqYYTjgOoUt0xa5Q4Zd06WjX/OTx475KSz3zP73VnsL5zFflqk5DPUAeLFfLMQvZ4j+WbM8ucKjgLR85HHe3nX
# DATA QCSvWD7o2stpXAYfMhM5umg4pC0HdVYypLVJQU+bHuJYlakOMvFj4RQlPFWZK0jsapBSVLsbQWx8fSIPgwaALXQa2njXG8yG8SiZ
# DATA 0RTR2EQjquQJRGzG0WAAaXeMoX2luE7216jk/aQtcvtkmGDTNbSU+mSSKswB82z02+1ovAUDje/ixOhYvA+7iIKg2FHlpVpjmV1s
# DATA 8vH5kYi3IRym0FIPU5ZQlxaiNZ6HkLCerHs/u6G93LvfkhaUknmZ8lJ0yXsvSafa/hNxIWb/6FjfRgZJ+wJ7Cco31F/DNoCwPXUj
# DATA VNVZNmQ+Ji+6SIzVMzhbzdlq9sjgnK0vr7N1NXPyWUo4vseLlbo+KwE2PnptQSkhrcdwhH1ot0n7yZw3BXYjMGCSnWjacVjyHmRi
# DATA gDiFIyptBu3DZchOg9DSD2SfJvsOenHHS2m63zGelTZvJcs0A0VzcUMNSE6xOD6yxi9rfYjJKJxMNE+ID5fgPfD6LDES1RnHRdql
# DATA WudGJeVPyk+mPFn6xwyIaK5wjgM7EnE48rRyPyWDgZWCpQRIs3jO1UQ+vypbAtTLrTtMR2k/9WrCHWbmvsPqM0bMwUAvjcbwhybK
# DATA mpu/newGblXJwep79tjsYWQWf1p9Z5vtNNbInoiVou+8KanK8kHGY+0tlBVo28+HoWGNq3CtzWh5PsNJ1zjhecFf3PEqB60cmANJ
# DATA 8c5g0/plKZ2r0GTGOXHXJGA+xpKXYzbY7kHEMZ5AyBT1PjNbYa8VlSZnQSRGi5iZaQ1SGsaGSTdiP/4U9iwMP23BCUrJdibCAWmk
# DATA OiMWGtJG9tT7BQ24Jdu/uqEv1TPb5NjSyCfFZI2WMAPgFcvd3IjoGcvpOm/Lnqp4ssp3yhJ6tLqEdDWWQno0Zh9svoSoGXNHIh53
# DATA YF+gldkn+0fcoKEndV1Z/RY70KyB4HlZBRGp1QTqo5hyoHSxg1FZKecvGzsF179gHmxaMA/CyYBFZcPBUBfMo6THMNYRjWqsmXqA
# DATA SR6NoHv5uVnJu7ufxJgZU94bt37Bdn1zqYypf8HkrKtmiZgenrs87IhfWXlkfe8py+OvVpeH7sWlPP6KDJaFjmzW6cwGrCaLRUB1
# DATA klA1Dj1ZVSw96qV4JQHnsWnIKHlvU+s6LFARkhmSxANROR5yL5YMhyL/TMbFUFhi9FOMHDTrxecvqCxF17+YHm5aTA9n7fZ8f/Y6
# DATA i1ir3iwafZIcZj2YFuMqeR/ENN3tzqij35OlKCOfrFeFMgsPTG3Kq044EzreucvCjvb178Te3LQTez2edHnHwAgOIGocI6vx9EXx
# DATA uj8bxt0iFgpZYlyVB486KRv2kBaawjL/INRc6myd3+btoYRNb0chkfGktk1ACxnuoXOX02KCzlRaeftPtjHa9p+5Inl/5/1EbzjU
# DATA Gtxi8ovFzUv/DLUMacaC7NClrBZOL4eJ9lx7vDIWWtpPohwK7f86+tfjL49+d/wbsMqAMaPPvzr6+ujfjr6jv3/HeLQ/egw7++bo
# DATA T8e/WQSj/TNj1L46+hM9+3uP/uIAj74pUIhHf6BvjD6j/31/9LV5iU1So5v+fPQ1PimO2r+Biob3y3u/P/r34390VLTnAMpttjnw
# DATA ltdkeqCxq4bMDfFiIa8WeGbE26wimHiaBQBoKNwJLCNDHYDAGdCBjkE3UERXqseTKe8Zw3M9WcIyTgF4OtaS06Asj6Ygdr7Dp9m+
# DATA Pu4irpqeNl8gl4dQo9EiHCR7GeKLdxjyy+c53Dd7cdZNvxlPLXzHxTHUYEqrcxuooYmM4JwNDp92cmldOD/tPcGAe20yLrCji+b9
# DATA fRp3zPSyoI2sNMFhKGQkDFkkE92d2tOK+Y0ijT+FSkqUdU6s81Ugm0qWIycRexaZMKuPCQypiASvgcFqusBWW18vVxsxc63sWQHW
# DATA 1kffAdbc+H/B47+GsJ1h2H8plveuZsi/8BF/owH/FOP95Q/3UhHzSTej/PVqPpfBbcsnnAdJzhADHTOpbh8ipIKcYZzM5FUS16kA
# DATA ndJhiIUvs/TmSb/UjlK4tKIJliY50TRQZ8cWVPS6cc+w3SjZh54imWzIbJsoc4231eDIChkU7JeIOk8wNik0Gdcx4V7xqWHeCSS0
# DATA uTjlPVTpVGhcvDQbpVMxFZAvmeVwW1HMQM+aziiEYTia9fB5YhsJyvMKPwHbNJPDYjJyyDaHbHPItktEtm0wumw00dnEJL5Cu/4s
# DATA Zv15rXoHbnPgNgduc+A2B25z4DYHbnPgNgduc+A2B25z4DYHbnPgNgduc+A2B25z4DYHbnPgNgduc+A2B25z4DYHbnPgNgduc+C2
# DATA awNu84Nqp1o+K7gt6NWj3nMEbsuvOZ+W3ka2qletNT+tB8Vq3WtWi361MqB/KhWvGXh+mX6pen6FPtWLleqg3vKCutcqe5XGp9Ua
# DATA XfWqgVervO37rU+LzWK14VX8YjCXpVGrV+m256BnfqNWr9aWQc9aiyVXKXu1ctAPGpX9av1t+pp/gQkrT2GrUAoq9cBr+EW/OSzW
# DATA Gl6t6TXKRb9BX2pere7Vm/Rl44j51YWYBT4gcY1Pi1Uq1CLyov4eBYDYDqp0IUeL452c+ZdFvUZ9BeZOVeBOPOETdk+l0lcy9Jvf
# DATA YJAcqxrU8y3ABEsBwLDx5OkystaTh5vNfLXv9fi77n9ZDpXFX6tNqjcUximxcdyMNDZOWqSFjYuCZi0I8tg4uqlWqeewcXMgOcHG
# DATA tbqtDBtX69SDoJFh47qdTruXYeNa3WqrHF06Ng7t72RsXFUbBWIS6GdW8OOQzDn/YvAjr0Z/qvSnHvzIDmKOF/fOkKYS0wK2AiO+
# DATA 3vus2EFf7Zjb06SgXL4978wTd0+huX9Q4FWyFStiKhqAV40/23SpoFSz8sKrTvLBeHo/Rc4gMfMl7KrWLj7t5cwz7VQmVeiPH2iT
# DATA n31F8ZQsrE4OZKd92NQvVxbwc+XVfDmT+wU7B9aYIickkK0Ex5FzHDnHkXMcOceRcxw5x5FzHDnHkXMcOceRcxy5l4wjpyyOfAcQ
# DATA jyj8Xdh7H25Jm6OE35DvUIThbGAT88Otx+EEKrT8iCc3o3nd4AtULd7EZrptf+cG5UZnWPqQ/hvdtU6J3/9p/hgeP/xeOO2XeIa+
# DATA zeH82C8FCCE73rfk0HimfAspLtPta9RcdmzFHaJ2h6g3OURtH21yZ6ndWeo1esnP9oy1HA0u6LO+S05aPzTnAqWOFPLKauZQrxxY
# DATA VYIsfJYYdvSB0mGWk7wRq+xnhyfH4SEm03J4ElorI+vk5MYayG+K6nFbGFFdEKjw6tB06OgInO7xJrrHnTCdhUo2DZ9W34kulbIW
# DATA t34gH1ffSx1sN0k4o38iH58HBeQsL04pgnhvtQiizlURQSSjbHLYhQ5RONoP00wBEScnqXlBQbyTsNtkNh7j3DM2GuAwmjcRWcgU
# DATA eA45zM5eMGpqUcmjVh3j6PCcjg6Ph93JYcGLwvSQG8r5dQ/n0nBlEpVW/bs4xVBTk5VONWyHyQxmZFY2nVnap5obsUguzqDLEepQ
# DATA 5KrZzMmMCFiVsEsEw4CC6oN7hy4iU6ZWeg58PHyG+gF/aVszT86lTp0l4DkomA82LpiHVNWLcKscQgPcUg7lg80FKpFxxK2Hm41u
# DATA IAySQcFRf4SGo3VDcY4QilVQDI/GbBsiwy01DREcwNqWjG/xoJ/MWHr0/PquuaRcWSmduXN7d9PO7b0YO2eg4TGbWMrINEGhOR92
# DATA BU6TsW46vXgyhDjpbOypgkkmLMHGv4p6yQElapK0pbubRPjKumGzUZ+MKqgb2DIe5ymSXMyvrESsQfKURfJ4dZGY4VbK5PEkjAei
# DATA lxKSWWMKhb5PYZzAfkskh7s07YGRh6ppaJiTUDUHpVkNmLBWmsmUJDKxNxFhGRyK2tu5CyYf/evfVh5t2lY+kDkpTVDjMVVhUzCo
# DATA 3bCcaeouW4RgWPMwztNRqHqMUx7vMc0HjxYbcxUyKxXNcCUSPmVRa5QuPKfnLoq5GL+8WscvgpyIftx5t5x3axPvll3FnHfLebc2
# DATA 9mKtdIJdjneLhbcMAC/09pJERPG0b+va6teu833hSINne8AWnFpCN8WGEbUPWV/LeZvU8gyjmUbYf88TVbVQut0Z7ii3l26YMilF
# DATA KUqo5nnTlWVXjOunwrtrJ+i50YsNYzaQKrytehjylle9kTca89brkr/aQcYrSKjliSrXsVEty/vJ1I0mZvrBBdeUrwi9sHu6tzzf
# DATA 6wxX+7H8UsAOBAosjiZ0dynI3b/gy1IWlnEUyqYbCuK+li+c62UtMwnlR1Hgw0U6VbL7yjZdskvSxGMxz8Y0Hk5lQ/pNCeKcBpAY
# DATA KRiMrPZmq1k+noj7VYix6AcWVKIHrNc40l7agswY2IZjr0i4F8ay6wpb4gUjRbOHkmcgd1k9LXlcaAUe/CwgC4tXZkFCrzLV1jFe
# DATA B2tqHI8EY4UwySI2EoRYUGQFNRwag6Rj+1CapwjzhVCgtFcR09ke+LW8UyBbw1TT1pGWoGS9ykx2csYW6qFntgvoPXFjtmE0XhZZ
# DATA /cIbntlQ40xPZ3puYno6W/PFtTVXWofXUK2aT3SY0wWLZtjAMkPfgtnJsQKFfBLJMmGqrdDsIZZd4s73+qlbX3/JV/5bzunceZV6
# DATA 0PmGpY8FIlxzhKspJ/ysM4tyIRzwt3kR7vnjetJMOwkmC/Kuw1FHzG+jf3XnJwun/XgHHxXigri59RR/4bRsICyeHVvR9tgcHPwg
# DATA POTpC/ScjWF2j5fsZHI0MouC8CfuUUjjQ1lelLkTaITjcJ/nLiXvIS9nTbUFpe5R9hlqJVzG4oxjg2d+rSvEejhZaZrWsVElmK9M
# DATA 95+OBwg1jZ9i67osQ0r1vnK4x5UbTxmmjCrUfjTYm1F3YcPK/uX4y+NfM5YMBLFv+POfgC5jbNjvQRTDL8dfLlLK/nfz46+Ovj36
# DATA Biiyf+cLvz/+8uhPuFTwjv5w9BWjyH6N77iBX3f89/QHILLf0esAMvuGfv6KUWbfUgDf4bfjLyiYbwErO/7CozC+ogt/j4tAozl2
# DATA 2XNhHSJtPPWCP4TlynXtvQUiaTh5glW+cBQV4PagWemE547jUKY/GGRohoqj0ryGBL0MbzbiwFibfBYPmI1KLTrk3Zw0sQynAkmN
# DATA sFWfOrO11DKBSUcyUDpomW0rWh3GVaPL5krl8shl3VjOYabmzjfUFa6oC/QyjHvmTqp0UhMnFwwv43l+nPIGBDQH3hmmo+oIZpuV
# DATA 2oVTzHRn04v5uXAgTqW004+6M9kmMhB2PCQ/GOTMvZjHaq+eHxSH8Qi2djigyo19JLe1p5fRGWKFTSIKWEAK8QhdsJiByjKSNjkw
# DATA +OZNq+ZqEyff1J4Vvmxt5B29zFkAF2YBaG7Z6Qf+l8JBdJWD/kWP+RsN+acc8S99wJf6mEu8TS+7Fs3nMrhluRR7kczRU/FIMYXb
# DATA S3r5fXucDdM+xXKP103Q6GLs0zSWESOOhuGYEy6vRR8l5waodoK6hKUWjUyS/Zo84kq994w4W7ohtoxzTlUKj7JjhtfJgA8giLjL
# DATA DrRhQEWQIpZeFwd+8PIno+RATkd01eZSYKPGERd1P5lNwP5iBlXcjgfIKlh3DFqh8YhxUzAWRAOB8VzmDIECOY2S5fApxzFzHDPH
# DATA MbtEjtmGI81GU54N7OOrM/HPYuGf08B3IDMHMnMgMwcycyAzBzJzIDMHMnMgMwcycyAzBzJzIDMHMnMgMwcycyAzBzJzIDMHMnMg
# DATA MwcycyAzBzJzIDMHMnMgMwcyuzYgs0qzFjQqZwWZ9Xphr/wcgcxyK86n5ZjVKU/KtX693tyvtmpv1+cRZJWo3ukt5mTZp6ys9YNm
# DATA gz9XARlTn2uUsfy52fR8yuFqrTz0m+Ui/as++/rzHNSLcr7bqyyDelWaC1GoBBSFcuVTv1H2fB8INq/il6c+3MbNk/BhjSBsdJa+
# DATA Kagv4ND8RgAumVetFFs1z6/XAEHzA8o4v8rkt1rrhNd1qvX2clqZBVErYjoQQqBfarTXWgIyo7hkIDOKlAGZCY4tawG1aq9R2Th/
# DATA 60teVSk3sldVff8SX1UVIpu8qlJvXOKrgoqdqmb5El9VZxSdTlX1gjPwVFA57tI0VE56RwsqV6vUq81uHio3j5BbCpWL/KjRDTKo
# DATA XNCtR82qgcp16p2oY0HlqvTeZv3SoXKyu7Aoywx6mKvyDMLTq1PGdmmK+Wc/Mw+FeyuizjwOC4v0t9oy+hv8n439g0Jd/J8q5GG4
# DATA GeSt1Fjn1tTTsyzQ+QUS27zX5bPg2VQlkwuHxS1WuL7+st2kDqybd3qdzg7z2F2LparVYDgrq9bYcwtxzk+LLtE6dIw5x5hzjDnH
# DATA mHOMOceYc4w5x5hzjDnHmHOMOceYe8kYc6gL8ZRm+JMQWuxUwW4b7Nzunc/MnGSc7nI9kV6Kzy/j6kdWy5eGv3vHNPu4t/0DflQ1
# DATA 3J3PFJdOKxdBDFXOfDHiaMxdtRiXtz+XV3dnsva8awf0Y8Hd4VKGwGMunSzp2PcW/Z0f+8ENP0B0dGh3JID2jOaLKFQTM5abZQXa
# DATA URR1U/Du9DOA5IkMQWq0l3rRgXQgYzmVJ2JfdIlPMOaSg4zGKcZdbdZP8GLJKll82uYJ3U5JFh+2t8PCfiGmQghvKEN7f+fH2zE1
# DATA jfJr9fItf6dQxqYvbvVYf9od7t7ZHt7Z9Wu18msfbr1PVZKPWHKoyCBl+HA+9QYJzVmHN+vlnR9Vajs0A+uyntV2pfDhVhl382P6
# DATA meGP6MbFm25nNUeyHDVgO+VYq6oD59Eux28bqWfU4H988U/I2PQ2rtzYXVaY2/Gr+UJ8zQ9ulXVucqi3P98pfZLEI3qWwYUSafXx
# DATA xpJX9uJRnPaVKKof6MLEaVlxuAgA8acjqEwIDgDPM/Rwe67CFHWt2LGrBTUerkcmW3Yokre5wKkkinpWQc+/ts5k5JaHxpOF8xnG
# DATA QTKG1KFjrZyhxS10yJqtqCudmXdR4Po8dGn6FP2MFUcJ+5EOUz9EAy7CMphGfRDNKUU4pYj1ShHWMUWnF+H0Ik6tF7FSp/RSdCQe
# DATA zKZZA+BdW1rTU0Z2IypxHWWMrkLHXowVkXGfiBUzp1yPS5luvb7fdF7mghF6L7duqQVzJVy/Qo9eDbisSD/FyXLmIRlh72018p6k
# DATA pG+CMVHKrmRK+rXyMin9qi2l36iUbS19P1gtpW8ZNIg+R5wmJjSr4mqVl9PP3Wzlmx3Eglo+x+xOtaztj9W6+jWOZy04+c46h1lf
# DATA EuaC9r4+wEjp5oOId5RRLMwgtBy6VX5ROZMxoTBp4DTly007PuYzIVdO72XjGQ+FMgG5Y12eK5CLee1DjJvc4u23Zlcv56Vy8NGj
# DATA gXZC3UTuzfmfMrxnVi4r6QjSkylMwPOLRHgX/j2RulHGirbkbeUMozHTpQmdZffnOnk2gyD8kbtFCfBSFWbtGUjOsJ4Gww1YzEEz
# DATA CFZp0ORFZ2wq2CL/azknTDIwN3/ASKhXKNi3pYcgGwJ2It/g+Re3yFsYbl7i5iUnzEty9qebmripyckzjmcqcYcxHhVcRwKZM8hU
# DATA 7t40ExEBHrDmk2lrVHphyiJXEJxizTEjQlUQ5bRhKI5LI4SmxRrmJxdz6AVss7Gx38KjtQ0w4Wt+IMJzkRBm4SpF+6bEUIVOzZSG
# DATA GV2UPemnM0Rzj3+bpYc05o6Y6UUJlM6ioCBEMj3SAy0D6bm7SJ/oQMf9ZJrsTcIxD9XjCIa0kveNJyw9JknMD3vTkLHK7yUTUdZV
# DATA Y9083FQQyZblJ6kVc8TCoXFHhr7tQGGQsU1QdWziu8fq1AFQ5NCHuyv8NMFK9EMbLwoPOQgDLLUG39662MddturWRn7eeJQUGKSA
# DATA QIRTQxCGiv/UgJ47LAin8BdakzhT1hOWbV57TxVLG1228AmsXjuU+rsmTXexw36UgNw6nywxE/Lc2AVVRVORySx8APe+ejPylcy2
# DATA Pgi+CtkgWcA/ANiLyGMtucOybTBqCqhEI0kKmHfw3iazVOWHCjimfLi7n8RdlqRmlTYAFCRLaYBKmBg7hNTamE+68e6U5VN6jvVf
# DATA C01EOcBlUqbjjAX1nHB10pNZGHTohsOkK40bhceXTVl5+vBc0uvBp67LTmtYSxkWvPGsTRaK9Rzrz3EjDLuwgLwJ12GprDR2MbyY
# DATA X+mBxE6DDlnaKbXJdUl8BDS4gntNMYhYSQShTF5IPUMMbS/q7iitY3q+NxsMDhVvRcWU3TgpV1RJ9zBHKmRlQekTDvqJUkekDhI7
# DATA QamIJ320Qykw9PHziFoxTF88e9rRwpwtvbEatDOdX2jT+bSssGesDm3v+V8PC3uMkUDDLtmokvq+nhZ2fdSknwtJ1ZMIEtm+f83y
# DATA ukioWF4h+6KZYvOK40uRYsr9xmreKFTehUZGkNSIVMyaZGC7Q6Ox7sTuvM/aJcIVo6kK6xPLpIneR7/jnjfjzHJG7wHJ7BHscqGR
# DATA Ub3J7pWZCWxa2Z2ewMKLIUV2qG66mQxWNU+xl2Hnovry1CJc5mBciwmBK9aQnBf0x2GBsQzxeIIanUammYmCc2imq7LNhgz7Ie4i
# DATA OzfnbSWbG6LFthY6W9o8hZScmrEouTZwF9bZFmy9F83Ky7BmB1FbiV/bVLP/7ejro38tHv/t0fdMGfvm6Luj3zNdjD4d/83xF0df
# DATA 2YSx4y9xZRFw9n/j8tHv6OGvGVH2tUdfvqKL39Dl70AmO/qdx/f8gRln/yD3Hf9Wgcy+AkmNXvAl/ftbBTLj+HyFOB3/HRhozDv7
# DATA /dH39APd/0fHNntebFlp5Gh4Wnydl6wMeRPrQDSHE3VxnrwlFNwUrR5xpFb+U6gsMkNevEfJPnt5wknmVbJIiGgea1Fmb89Hw+HM
# DATA bJs26yiumma2pGAuj2gmPpV04eXq+vztsoPA3P0wSmkE6siAzYV0wWgzcS+Jnj9cK7Lwx9QCBzbbqPAunGt217P0zrOZgakBvGgM
# DATA IZ3ZgCkc7UP8jdMUyj0H6olEUOycew9+SveLpnlBcyr0fhcDMWH7Zx/wYo8uDhZ4ZhvWzNU2zmKze1Z0sw2T4jhnzho4qzWgsWZn
# DATA MwJeCqfWFRoAlzH+bzT8n270v8LBX+rnQk5YqLNn0oIug2y2kEimm1FWpYvRAuNMlpU9qp6oqbcE9FTw3n78+MGjgjpYqlaGuWR4
# DATA z+iE7Ade2eFkYISGUyKjKU1UWWrPg85TPeZuijczVcGjvIYyWN4AQMriDjBnmRGQB5yNJ1EXvpG8UWAbAwVupugsPBgYo44yD9gq
# DATA AIdKzENBTnH8U3pNRjdjp0p6mPJRSnVP2/HNHN/M8c0ulW+22Viz0cTnVAby1Vr8ZzH4L8zed9gzhz1z2DOHPXPYM4c9c9gzhz1z
# DATA 2DOHPXPYM4c9c9gzhz1z2DOHPXPYM4c9c9gzhz1z2DOHPXPYM4c9c9gzhz1z2DOHPbs+2LNWrVWvnxV7Vu01eu3nCHu2sP68EfqM
# DATA M1dlHlPChLZVq+QOi/n1Sj7Xq8Jykmxv5jKu24yCqDeHb6o2g0BQXfP4pppksRUPebfEQ9hXWTyq84fWKlk0avPYumW8sLrFC/Nb
# DATA TcOgyhHS/rLWbfqN6mLNadao6jT7Uues5IX1dqsTLuWnrUteRUhpl5S8ikXz2jh59NCFJa8qjK9LSl5VPX2q5NFD50petVK5Fo2k
# DATA Wm1eXiOp1v1zNJJqs3zuRmIn78IbSS55p24kSN55G4mdvAtvJLnknbqRIHnnbSSB37wWjSSo1i6vkVAsztFIgkb93I3ETt6FN5Jc
# DATA 8k7dSJC88zYSO3kX3khyyTt1I0HyztZIbGBruenVgmC/Vu9XW7X9Yq0+LPqtuler71dPAqiubgRnoWGypWtomGw0WzTMarteaQZn
# DATA oWGWo7DnWzTMaj1q1gwNs93pdLsdi4bpB/Lz5dIw1WZemd1Zzh617Gb4mDxhJxPddqq1eI19ybaJXKiYvy7eM79VYXHJrMlLZqUm
# DATA tsrIolkuVLVgvjbkOq+e5R/Ts8Dlmw2zu2k2uTcJh7k1upOSq55Zsjy/eINeqV/I88W7My/iqh2S8iJfikhcAQuBYKlhEfWpql1+
# DATA uaDVasEDczp4J3uMlqSK3YYLvufF7UIruZ+O1ulonY7W6WidjtbpaJ2O1ulonY7W6WidjtbpaJ2O1nkBtM5FNOde3FYARazOwfRU
# DATA cEzNoKIrN/1yrRk06rdzcxb1GB8exmMacUiG+WyMKzd8PFmp3VZszPvqGDv0A0bT/uDQcK4YkUgxoXr1Jvb3b1cYi/hW/LogFd/F
# DATA OXM5pTwezFIPgs2eehE/q6K06vm7XiX4kXlbJrQj81LKg/2IUZ3bFIcfY41/Z1lINsvQOmfqBGGcIExOEGbx0LFTh3HqMGdXh1mp
# DATA pHyZqjG6s4YchLQXFBcrOWCjDe+8sSRkro+O2VUADWWoZNCHDGSswsFXTwAJ6idz3XyaQ7bBjbAUJOhbHEG+qazvNDjB1TRBM5yD
# DATA Jag+I2wWLBljUNRJ8Lb/On79JCCiFZxJin3NpCY4OS2VUyRDrA30APCKikmw/d7J8dXPmciaC1ZMN8v0DWOq7SBupxBKhORIZrdQ
# DATA 1zWOo5OqSxZIBp7MLpmoN06KeX1NrFdC/kwXoKdMPB6qQn7uoX/LSH/GQoxM74eeieqYsDy4eXSNvA5sAy7ScMhzAF6eYUEYNdfs
# DATA 0KSK1aIZaoK9kTS9KXgHfap8ZBxO9iIrNJW7vR71te3ZBL4NPEeTq0kEhaZ4qgV+lL9aZh4py3KzEhNVqUMxkFkH065nJe9eMmS3
# DATA GHV9BSXWM+oa/adMdElN5rryRDhRukiZLZNBZocUr9mEfatKfGgDauCLphTjmCduIrBiIuBs/pfC5j8t6eS6KEXaOyXWI0/einnE
# DATA FLVEXo+GSNyIVXuobQ2jteyTZycv+Xypq52kLj23x+MywCeLApoXDT9ZpkO6FICSKzu9JUYq8jLA35uw57WJsPQOVvVce8frYlob
# DATA Q+OUct+K/Me4ypgFBwESEY3PcCplrszNTXCYj7Jpt8Yrvv34vXcL3r1HjwpqHJb2wsOC0nIHxFLmRSK0OIZKaKiVVFmpkUrByH7G
# DATA aTZv0GA7buDxFMP2GqLiI+kMZMPbeljkXSsSqhLrFN2FEuhIyaNy7DhBlLBuBJpfNOpAEXQUUfyUHmuBai9V175eZhN51rwq61o0
# DATA Z74DOSHqWnBWrGkdbQVTZINbHTCMxJ8hMFKY/aJ9zwb05FBJYqpYlrwHmlODmPPqmO7IQq8XxoPZZB3N8qEEg4WrVTzLl8gCt/tr
# DATA Z4M7G3ypDa4qifPEO098zrpbabxfH/12rtMYqTOcc+iJp9B44MVXE6fYuJfwIJkXH9cu9Hn62WwMnGDJ+xn2iB8aRAvd0Z11ICIz
# DATA xFhspI2Nv52JxmzvbCzknukWSPPE1zuvasPvEY55c8OGfkWqANgy41B9was3jZU4ld57OsFHEebGqzrirCd7Y5LQGEwNu7/0hp/K
# DATA mN4DtXnFLR/AZEMqRYubxaZx602886Z+vwxG89FQhqoy4IzFw2/q3nlDbU7kGlzwMKz0qO9PqMwY+0lVbdrlO9UYUfBkMC5oqW1w
# DATA 7oApTvsSbldFa0U83gtHVKe6ti1oInM3k8Cf+12iYJtuxv6iEp1EEO/mxQNteZ0ckZ/Fk+kMiuosJW7FQRUwm3lcW1lSnvuUSTIw
# DATA kfnJmBVVzA1UyaMpq6SPefCkDBoMdFVPrfjcVAV1U1W6FVz69djvR9rOy/JeTL6wO6RBX89yMraPVhJXpPa0n8wGXW6XYs6OYPlh
# DATA 4zmmVqKuLgVc8ti+JAt4kBwOOQiyz8GzDiEOb8nQg0X/SdLmgVNJzM9GzEJUIa0Dgo+SA6VXrk3ncNrX0f9gwnL2VO89FjcRZzev
# DATA t2i/MTudyRqnYELtbUYvRZ0d34MfmJGa2bhAQgGyqG/niRFI9SM42Gk4j0b63q5iPWZrg+sS8564olV6QhHPh1/duPeVZx0R0+sZ
# DATA GVehHw3Gqj+TBU+rL2IZfBookxxUYRyFT1DC0mOi7mHNshsN8QJ7hqXAChSKzAcZC49WYE/NlB1jg8/N+ifqZzzckCH+Ytn2n3/+
# DATA 0ecfjrZe+YsX/T/K+mjwMTqMeDQDVHV8eOHvwNplvVb7C7VuPPevXw6Cyl+Us//+ouz7jXL9L7zyVWTADG2OXv8XL+d/P/zhDx/O
# DATA hBDRoQ4k7vI4g0qxlfJe5CJjP7IK4t179x3qNXiZk9p3MujyEj49UKKwXhGpFLJt9/iwjf7+CdmH+nOSvsKjFzr9Qdz21OUH9FXf
# DATA MjEPprO28s/oKziSheFAf5+R6fLKKx88vPvgwf2H2EC9tbX1Cp+xeUVtsOzJvmp2Nm3TZLIb3eqlWzu8mxEnQ7bA4LtJveJNUH1v
# DATA dgYxzWC2br8iW617aQn5ADffo8NRZxsPFbwtmq83t6wdqFvsFCoi9GKWW1s7O9q/VIqextNtf+f2K/P7PvNR43NkH6uH6A3UOx6M
# DATA +M1ZQFEHuVXwfq4is/zdHxVe8Tzvs6mcIrnl83aHwjB8+vqsh72Pfr3arBWekJX5KN4bhYNbW4/eeeuv33n33a1COu3Gya2fb9F1
# DATA Gh62ClvjeIx/1PePPt9R2aM2pkaTCQ09v/yl3qiacoD2BV4sl42vq7NE9hDv5k5r6ee7GAumiTpWofJfR4MffI0L6pBfgoNReP0P
# DATA 5PBQKU4fhb3oHbKL9nBIAbeXkF/3sJK9gzvnrnmveuVll+/waZuladBXVFwPYMhsq/jOv5Huz05tzQflff4KKvErr9AUGm7Kj5lu
# DATA tB2P0jGNwh9LofPkf+cWihhZwCvouAQbgD+U2JpIMYXa3ipu7eCHQTTalgcpIYFfwTU8OYlK2E/A24i3J1s/v1v8X8LiL8rF1sel
# DATA m7f+p+JHN7byL8R/kxBTuZ8hYfdR/Ntb74z2cdrH6kn4ma0dfkYNxLvc0nOJ2dGJkFu4smxTzZ9+jJO6FNOa92MPG3rVP+vjwOF6
# DATA 0dMO2bqpTCRVDGBvTrroDdAflXj3w7Z6J6rOx9hfvb2zk8vTlGI6DUcdVEV+vODh9IDJTnV1h6qd52+UO2qqqzCm0UTFTl/f1fH8
# DATA efkj+UHfiD3fchMfStx6p0vFsqUej0b78SQZDdXecPs+ms714j2697PPd+TK/dG+HAmykzpfCcJij2rAR5/Va5/TzSYWO7rSWFlj
# DATA vXwue6xfdlTjOU8m4TS0HHDhr5isS6cRj+wcyF6xWIx8fwFHbzmSW2Tn4WkJhi9M5i88LZfnLu1uqT0rci173/Jk/XSUzsYYrmh2
# DATA YUVTJQr/8WnPjyll0lPwjsFtek3B83fmE7O8tX78kdVsP/oxPYlTqyfFTGe4XX3oOStmnOUlGh6jUVcdQDXtdTbcRiHjlhJNNqh7
# DATA 43N+KHusQ1D28NMo+UpQ36D53reisawJ/yXWluDY8IaK4/VG0nmC0zX4hyofPTg55OlTQebLHa6POMmAgkOnLDA9Mv1LKkjswKK+
# DATA V9HyYMtgTsv0PrVIdFvoZ3BJ6Zk/fNAsGYrpYtoPsf9Kmqvp/XYpsqOIL4ojS5kupccRbJdwcvgGCwsmk0MWtouf7m7Ri0dhZ4YD
# DATA 5WYkR+dNU9WuvjnLQCq1j5UVw72quWXHu+lt2TXNPKJ95gm6kyQtgRC2rcMp4MpPPv7g4U/ef/c/e7+Ub/ce3r/7WH+5/z/fe7fg
# DATA lRMgPUyYnDr6udfl0LJXUPd0IJGn5haFw3xtlGtqoEQ7LH1CBbetqswNbprZS6Z2wjmjFU9t17ISS1Rg2z/P3Yb/trpcS9BdylP4
# DATA VBT3Lj6aXC9lub6Lw16wLkv4q0YDUj96WlgMulhUVYJD1/3VLTxtvvHbjDktL6dpdrE7Sca7d2FxLQs31Us0ZJ/ujhJ6z0ERM98Y
# DATA IJlUQqGSK6LktrhHMwW5szRAxJKqCJ7UNq8ORbcafIeZogd8/IwvysDOB/tRAc6C6WwSfSxbKHcfT2bq4LX+KNbnbrVckHVTvr6T
# DATA L0irxahC1UYU/FTj7fztmw1XOsy5HnBlC92sm2RLzIvZJza1e0mxL5RFP18frerHRplkejidhp2+HdePFktt2X+b5rm/NtPVyby8
# DATA gb15fn/Y/cwvBGIZsA0Nu3M03VbflJ186xR5a00yJVIL2ctyANlLzK89bPkYzHUPFG2TsYvRWFNEk6GUDw1jnShfPJ5k06719Bv3
# DATA f/b+T99998SSoydplrTsyay8Al1cb0LAYUfNADASbatqzJMi9Nx6hl26O9ljr/4D/kUVndyGs3wfh+p3mgMUldFNadJ7L6yKseoZ
# DATA NuGXPkG3wRZTD/I/eDRVkch12HxuYzubzOC+kopPwZNvPMFQ1uxTYDi9+/wPhFhNQH+pRvybb7zu8bQzZTSo6mpth3XJ+wkG7dBj
# DATA dI+H3UsjeCk7Ho1P4ZiMmjlD5BE79+9jFrb1foJ93FmN7Bgfepuv9+LJMOpuoYyoon38McyBj8l+2/W2Pv4YJfbxx1sSaSm+a+pK
# DATA nOAU+zC6DLffZv6/Sq1cC/w5/x+8gs7/dxX//eUPbs7Syc12PLpJpoM3Ppz2k1H1lR/+8Ics3CG8Wiy+yMIY1hiw4ovlimQcaeit
# DATA 3sD1UJtRHs+2BgPqFtZ4BbFMUa/pb9jTpD/3wxS+Qf01hj7YxHICnt2fKCuI5mt/No0H5hvPIcy3dLDGCxlObCfkvFNy2p8IAc9c
# DATA oEaW81hylGeTAcVYek4db7rGkz/qWHjxxJPZ+0zyWobMbPRUwwJl8l27g4NJTXMer33I5WJKgy11LKNMok8itf6HDJFZZ8qFpd/7
# DATA 0/HeJOxGP4PagX7xYlzMuER5I8MVdpFt09wozdxF0r0uSYi+TT3K2j0oR/2cjPiWt4ZnOXyH5bHhmSd2hW7xLqqtHR2ezCzG7CtV
# DATA 037s8tmV6Yu8Y4rTMFM9geKg9fRWfirF6cfp4RCbZLYtY5KTuXX0fx597R394eiro38/+ub4V8f/ePQ7+vz10Z+947+hD388+pN3
# DATA /HdHXx9/Qdf+4B3/6uiboz/TLd8f/Yluxw+/Ovr2+Mvj/0o/8dN/wtdbHiYPMOclBmpMVNGRw46lISz5bfmSKsOPJ7EfJ7a5x+ul
# DATA u9pJ0lvlCInI3pB87s6G41T/Fo2wuPlxmHbiWIwS7DPDALtb0TM0ccR0CzwjZkknNcsdPkGfMTZT21I2tyV7gmK/m0vREqMBU8pO
# DATA n4psG+Gj6FbOOXEDzTUR5XxlwFr9AaaUuzyd3GguikzbWfZzbzCD2kzuJ8QBW5G39T2U9lGi3YjqjknEsDEtTCXFavt16B7Ovx+Q
# DATA AUGzsHzkzLT+417XmrXnsk9N3R++YU/d33jn4f17j3/y8D/no7wwlc6lw35b/rmldrZ6llHwS55deEYSi4ZW4vqacqbMTdPojtmI
# DATA mxz/qNqzrB8rJ5RxfcMDpVTX4GaqrnBqb792K3OQfZT7Vvzos3Kh7n9u/b7z2oelnRvqwkefVQr1KuY69qutXuC/H31Lrf1/UJv+
# DATA NfqDf6MG/uf/n713b27ruvJE+29+imMn6QNQAPgQLSuQYTcl0TbbEsUrUnYSCo0CCZBEBAIIDiCJTaPLj0l3+saV3KRSt6a6qrsn
# DATA de8HUBSrrTi28xWkr3A/yd3rtd8HAOVHT810esYiztlnP9dee+31+C21479Mnv0BN/6zvygO8JV6+ZUqCJv/UUk9U08+UM8eJc+e
# DATA QomP1d9PtaoaOR8pA7sAeVKQSVCHkfZ6bMBpIZsV1GLWVPK1zdNPcsV7KXiFZtWlJWA1PK+6AtjZS81BZ0m1ldbj87z8ynIwDf/X
# DATA s0+B0ymm9gh4neJ/NDw1UjUnyCHV+J/CO+B/v8DJ+ALmS/189uWzLxUHfKL12ZDwPvM1oqXU0VmvJK/VWM+MxYvwe3XW+kBvnsLq
# DATA PIWGof3H0M1H83bfcHRi/c9//fwj4OJ68VgPYGmpUcNCWmrsqK3DGyEOD/4bXMDVOOkFE4Fj1dFr6O0ep8q9y9W6XZ3M1ild0m19
# DATA bGwpX3gh/2Rd3wXPx9+Se3+3VL9QLKjNuGT2XqXxD2X1dLG49EbKCt1ABU4VgqteD4CbjlBhrGb3LK3A5b1SSSfk5Wte4Sd7q3Wh
# DATA JDVrxRlD98dbdbY2EQ9Gd5QN7ST4HWzm57959kXJcADZ7bjzH6nCj6AiVUxxhmePgQcwf1CVy1z/+fknisK+AvIEylW/f23NKoEV
# DATA xnYyjXWlDjtZxm1PIXzZ6TGhTp+EGXsBJ+TPamupJU9wUJ+xbKN6/PwTJdTYPWZlExsTAL3Q5nb0NsbmaFjn43Tn2vp6WacPl4cC
# DATA XJfUfDM4MZaGX2izUkVgMyJh8grAV5rBAi0rsoTnaOJQxfDfWi3k0Ifykgtn4aH0exrG848jq/bl84/VnCAZw7H0KdLWJ7Rv4+cX
# DATA nk5XnHeKjNWEPaGJhKoDkn3+SUIl4KGmBF5u7HZstdVNtDDq32v33PXNN1IrdnG3Mv234gp2lb4ETz3/GDi7Gtn69mbZbMY5CIJH
# DATA VEjXt7cb27du79YuLq8s3+3d3ri5tf7e+rsbje31rY0bjTu3b9Q4VQ0Kww+a99vVi4Dt0EudXZiaL1VnGru33tnYQoMEDoIk782t
# DATA 3Y3bW+s3Gn/73m5jZ+Pa7Y1dLMJ33AoWbRy3HxYugrDu1n+3t3v7zs5uY/v2rR/9uLZyt3dz/fZPrq5vNW5svLV+7ceNG5tb7zQ2
# DATA ttav3ti4XkM8WTTG0GrBRdWXwmIrhPp41hLDdYbha0VAw8Mb1IIsVahfl1555eIrwRL9O/FOw2yINJ//kihMUbCqC17S9+6imAak
# DATA 9+T0iyq7eUbBEuGeJiYQFlenSIOKouBAVF0GIeFzRThfqn4/AZ7zxfNfszDIbx6JPiUi+HF/LTNewVjhq66ocTYJDeK68DQ3AFyN
# DATA vbojn4N5O27aRjP1gYagm2asNt3bU1/VEbAOv8tl+eK62mCDWsGynw3a7WGm7jj328NhR13h09SoPggpEjUdYp3tg/dw54CCBxCj
# DATA QvvFCg9N9tvgJExKDxRSQOVb82cNHFvDmduidm6CpUwLpFQBnMjqm9S98XC/UYOmf7wUlg1Ors+QyapzSVGO4jlPiOR/8+x3yFnh
# DATA EfBaYMWfguZBbQUlgEClZSn9/FcOq3aOY1wE6gM+5fnLwnngEe+0R2AmzyKTkREtMSXyZpIKw3M5QaHxS5Rr/gSdA+nBO1S+5AHB
# DATA P+o32/pBzIR9pDa8ki/UAQcfqergtIIJe2KWJD7v7LqR37d5Zp6Pgs9VX35F5wZ3IhgWncD+ArAoLp0oAuWsBBe1Hii4OoCsqwsq
# DATA PhZc4jVR17QCsRDnG3vp9fXd9avrOxtwGqX1YkW+tQ0vhXfap6iiKyWBstFrT1tQecXlVfSgVWsFZPpnXDlg3cgMn5AAAjIaPDSy
# DATA NC2okiwV6/wscTpuZCvuh/ypr8v64oG3SItBAi+B9Uee4mxTeKJ9q3BFvF2Aj7kKegLBNm17N9wmlxFVrpPhhIAyzvNcILuSMTyL
# DATA QRmsae38trbU8KztC2MhhZKSptF6D6MqWOXn37PFSofQOgMjKk5v7o7JHRIaCLsdhPhRs49/ytJQkBU8wQ5L76ln6/SRHExFT2uJ
# DATA n5HWchJrDAyYoIor+NOGfltpsdKlKzbc/6Q/7qHFtgbqNzlVWP3DVABSlTUc9RwHk25ur1MFcBF9q9vfb3Y3t+9fkoder9XgNA2r
# DATA z2XGWLrXj6VL4cQzhQMcOQftspIREg8UizgdQl62HhkvMFCkMu4pobuwKBWRKQD8uOBI4/2D+mEsbvMurgkVCfnKILOL44cVMskP
# DATA STGm7gmfo478afR4wBd0ClwROeoxsthP8Hpnc4iE9BNPLK2adSA4215mJHZI8Ay8+AkNHVRT8RuQX/NOhxzuZp0D0i2b03K3X5jR
# DATA up1V5aiAnrYncBe0Dq5K8ux3dPI+xq7/Al/8icf6Ga/qn3Al8P5yDW4YelxbG7vv3br9jicvxaZYUnL0ebz8O0MHygIXL4J/LAmO
# DATA ByRCN+wTzxPsWSjO8LgKWjIyS2gfgairYvAFCei5H6EPbHUh8Aw6mzjcW2sFI6J26LmKpYn1hXyA1/63Cd7D6Xr6RBtrbfdOR2Wj
# DATA b1EoSX2Ad96nyTsbP669u37jzoboSdQDzxsHbwI6x7V9KSB9JcTJYw5duBhEHYpUDVOGEe35l2hT+xSFra9IK/EhXtStyxXrZkmb
# DATA AxevP6VzXErQnVVGQ+zOcQ1z7yump1Mn2Lumqj//T772obaUptZaL3zqDUB9/XN98RavedUz204qcRPGfrow1ffZ8dDmy7frvm7d
# DATA ZEHIhWn8DFncP4mOKOBjxI9hTF/R0NWgfh251ZptC5ayRnbcXH3lkj2aVucIIhZr4gVQ4SJF40lrmYHREpYO9+OmPdhkB8fj3j3Y
# DATA ZChGd5sn+61mVSx6mG/Bii0olpL91NenU48qFIdcwPqccfH74/ZD+kvbaijatAEDUUeq8c7ly3u/Pwo9d9lq1qWEJMTyBiS3os4W
# DATA HJdhJGD+xTN6ABZq+ED9hBNsYCyJO2+vq5nbuXNzx3Bd0DIOHKP2HFEgpEGjmoumM9jNuRQgSDTGJo7WEyT0x7RHiaDURtCHNZli
# DATA YbhL9jgg4oH8hB3yKV5IkyS9QD28gE79Xi9lTe4j4kCDlsbMe4lOkR7YtlOKgJu9TOgELoKUvl8M+w9QFAz6bjstFEltgs7OttSd
# DATA aypR69AsH6J/azFJCt7qFMFFr/8g31AiZgAU46HbUYkmd+WESX1lyTB4XLDa+PnP4QT5WHGtLyx2i4kXaziDSzE7BFqBY6QoL5is
# DATA 1dOAWQCBi50jOpZ/8XvJEhr1EhT906gwT71ijQ6nEQVsGZtwBQa2Uue98QivUKx1Bbws2BN41PYfijt3pp+wbOMU1NKKJllUOxHV
# DATA 2lIH9QO7mIoCDD08xMjadSpB5wNQafk7+k7vXg8i8jW0K3+RegFEPO7Xaj6JWeSFqnZZDHcF4JGsAJ3lvtIEJ01OOtpf4TwW49OD
# DATA I+M4fPgE74bWUPKHv4WQJvCKO0DzkLrLLedDKgngy5AfYljoEMPsIPcGRAaMmcGK9mR5EUUurReL8Sqt4XoUUjT3teiXeBSIogB6
# DATA sGeHhfC0AZ0ddlTPhuimy1XXKcITWkW2L+4aJkCOu8Rj4G45K6G/yaPKKd9aLLHXOSSRwJqIeb70ZwN0HHucKSQlQxymnsFLCDWy
# DATA R4lFaPRUHsfQbqV1h7vKB0RHQByoCrrdpxyBvgzhDhtjdZEEykP+wKPd+TbU/8sHKrPk/6Y41x+VUKyuys//0XAxUlUqZo53ZSWd
# DATA qesoiKYBH0ceqDkkic7uFWvgnIKuCYS5PR6UbqCYzdKb+1m/CznTrAniL3W9S/BgYa5DQknk/e59zAaUNYbtbnPUud9ujPp2LBQI
# DATA Ak5ZNKmG4VSOSF/W0soUef6XLBAbfz8S4h+DhRVnFhUZYL3Hy/izP8K5Q7eWRzjfjy0zogxWNg0yq/A4nN1hPLp+repWt3W8438I
# DATA 7DS/w66Y7s7VAlNArz0eDZsAFkGUIBoJJddqvBhACoL5N7YZQAw86kEYL+VK6jZP28MsgWytSfNwBFjl/R4miUW30CsMyEKB5oSo
# DATA ohvSlpqYg43hb3JiyneV0+ZJ1z5KzQt6TqEf5dzvct+r1/WQiA16zlKi9er+Rshd4oiraVS/yq25+9JaCHMNtCgLdYm4QjNqDzwE
# DATA efUx3EN11AvRVvzpshujjeMy91HYcGepICSl1eRsYjQhYnO4tTPN5OD2Ap1R/Znl17mS7SOUaJ/i7gSpVruyi84PpQ3YJj9nR5Ev
# DATA QM3wWBt52EDxOIffkqWNru+fos6N1JbIi584igjXE8YsVswuysBEsvOCeyRLZfErinV4UrlpJ+eCc3Pg8y12hGMnk+8ljFxL2EsM
# DATA JtTpldHZVU8v43ep+/x9Akrqd1samQnJacE/U2f5XEcvKSDUo9rhv4FC+flH0oFycLekCHuRJ6RV9pg2+5dnFAvJ5EXEzb1UzznY
# DATA 0wzn5FFRa04pkDVBNjSNuV4RBllAyyPoH3Hx4vyz4Rw7+XMhqgaLl4pM5PXANK2d5nPZD0lO8NgWm4yS0FGuhZJWdY4IRCFjLW6j
# DATA vwlCVThiXr6ydIajRu6UaS9lQZvWe8tt2R+ElI9KM/bL+LVXSuBNhVqiN/58necSHA5yjpuvu5a656jdwBxL6mxArO52QWIyrGDN
# DATA rsETYBOSVh/L2oHqH65DtrXpDE+wQxbmSkkDABNEvTPBSYFiOTqp36kR/wFNH2Q0eiRuqkkoPj0OtVGS9NMlXr2557gEYGQnWWmF
# DATA XCBIP/cmYO8O822UdNzXceIxZXCmZGuHXY4qU7bN8K1rsHSYAiIltAc/aROYNkFlj09snZA9k8hara65xngpOIt1zt9j9vkBEMOm
# DATA mrljJWqaeuxODjsnTfShzhewrO5xce+GKJWwJXE6/b7ArAN+YbOXjFk5I8ctMl3XS0AYut1nys/jL7cbDkWbkZ7Zg8sPkAKycwOV
# DATA +B9z93rJkZHjuue7VrCQtUN0kP9F9L9zGyLdtGlftOBbt65vNHZ213c3dDzM5sYO7lhmoggBBCcsd8aMC5Xsecx1xvJQbiY33W9q
# DATA tMQB5xNzKNKDY5/WNirffGmFhXG4zEknA0BqNwiMVH1Z3MDI3+sLicc3OFYJJtKzx3CvBPhFB9/ZdpBw6kitHx18DWfgr5Pl/quv
# DATA vmpuxHqW7SDw221CimB04Pb9Tn+cJZs319/aKCXjjJIfgD/gg7aVEro3Yt2f2iwDQLy0aiQ0u+Rn4/6omfxUkQQc7LiQDzD2e9hW
# DATA UztuY4R5B5GJIENXi2+xGJYxHpiQco49JBZQ8nYeuhPW3T0q9zO3pK0ddCcTb9Lz3wDlIMWv1GJyz/IWCMuVgjub9qHtNnsNAo8E
# DATA vXKDpfkCDa1Eswxx/QfHHUz1brlyMq4IM4RWDUhaFAf8w1JRNqhKfGGrFej2YPJJiAeVjnBV2xCowGI1DzqAxYZr+qA5bBl9Ath+
# DATA 81XCpFbHYBMezrRygeDxW3TBsBU+fybrKEWKPRIjb4JS2hN1+fyYPGM8LRH6iRj1+K9yfAo9iy9PtqBdOTBxMTQ4xYcpoTMw4ex9
# DATA gL56/+73I/Bvtve841xCqkXo19Nnn5EVG5RQSqJGQ9LHkangCwtcvDGCJDa0+xSHjDnd9VLxw9zR83t3/DEv9QuFN6p3K/Rn8Wyl
# DATA RMF+9PU8gxb3T3JG+hDNF/GhkpkpHJ/QVsMM1CW3YKzBF+xv6B4R4aT4373g7PjVFOc1KJKZx54p1+k3In0zPgk6rZEBnz1mEsVz
# DATA lbRbAI8GdY8fFBD4y3FLr6gjCeKg9pbryWKyVtyrrnliGlQczArsCXozdXy/Z68IuGY/QhLm5eZ4Iz0y0Bt9StokHjj4fkyzQF4h
# DATA vT1wiv/QHEOR1M9pMzleyJ+yYv8pxZ+Txlcoy+A9Z+72sd9wYXUENrwPXDKMfCOZdPyi/Hzd/qIUtGCsST6dWoUsnxXML2D3kDmZ
# DATA UyfjD6l3rmtn79RvhZ0lp+wAExTs2twBYs/4Q2hXTacbXvto+FNT4xTSN1f/U3/j+jNnJuUcg7T7GiyFX5WPgEkLai3G/G3xt9rt
# DATA CKZBnukZsAqFQ7L8kAMqjbV0Dr8Ux7uBYrX/EXWIH1JspsefAgPOEx1P6HMuyp8A/cUkHM72gyc7JF4BHLG7eZyXZPtmSYyc1pRM
# DATA RAW1gIbe3UaT2unJbPm7xX6nK1XPdS9zZjmYz39T80NToL1f/4yBhX8IIjm+Qpb0Mf73o2ePWcY571wOBuhVsUcJTdg3vVYzPUfH
# DATA vcDmzRThRLID/VGFhvz4tyZsi+JyqY2/Cebmf6gh/QGDKx89/9Xzf2bmLfMjIQ1RrdtfKK5FVcBSA7hOf4QU+7Gq6UkoRn2uY14Y
# DATA z6WWEzXGLvbb2xwwaAHIsqBwcVX0z1QVqp3Xln94SWbl4JjoBtsh/zqyu91F9LS76LWCkKn1cFZ+64w4hyii2uynePKhMyI+sMaQ
# DATA p7dnF4spynmt+869RLF3pBNXF3XdqEdhCUgZiZr7VZvzsUvaDJ3lv1pRur6ILfPyJdPZB4EeM2BdosrUui1B/+ex03Nn+NixUnA7
# DATA ytob4OS7jYiRxaK2/qN8BqIYOE1XAOPoXvs0K+wtcj3cRN3+pNJ+OAJV8Hz2ZfHls9XvnvVCX6Sh9mrgbja3cX2OgyNUHccD7XRP
# DATA Re99RqYRdEMl6x94hJEyvxrxdQs6rz2UheVDOnecCMf+nFYUH0jN3Eg6Jgq78S/ZQKH0VzF2tmhXI9e/1uwLKk2fChIp4Uy7syr+
# DATA yiSnY3FSWk7xwKcRG7f7uQCez2P5wQXVgLq5Nl7Eaoku8hQXGN1ZXCXb6ms7uBjPGBqss5JGm2N7asUp39191Gjx290JZgcoGQqC
# DATA WowPeN58OR5n39a+UPyDXTEBX67SarcH8AcrqixPQSNQwcmeloTLc7Q4aIdfqgUP81xxcvwDfi1O8l+iWQ0Od0SmSCBWSs3ZH8EZ
# DATA B8NFTYj484/laLcxEixhMOIEE5faZPPXZFb2zAav49gNaEV8a3HxICjGDUCxRZUvtFki77R3xO08WmkfHrZRQag6XxDN4Sx2Nc+I
# DATA dMXTxpSv74Eff5LxoJynfVhzV9/cLR7lDReBqWFtdfdogPTcibMOQ5CoUBCD5NQLYy1Eovddhs7FPUQAZzqpCPWu0zdWmwqvBRg1
# DATA 2xRKm9oEXIZ0g2k82LRWwytKLvM+x7UDVSRfUEQKEJuJduJINQ65iYF6WFDB4b4ThuXSV9SXathW9N8BARSI11tRzpAhEaW8GH+D
# DATA i7G3XK8MNVoRPimvaPyiqpSxl8NqC9GQ1K/R0ZDAwuXvnzHkeauDj9WaAuA/4H4rGeUhOso1Wy18ogSy9mHnXhq1Tj7799ydC5v9
# DATA F4r6QTD9J4zVUuvzOUWBioYqoR30FDYKbhEMQINyCKb1AXpQ/sq+M31sLQyvwx5PIERy4V9+gcqgPyik++NOF5JloBHBsvnsHncy
# DATA ZiGAEwImhD7C1YGLEyYA0C4e8Ho46HfJxA0npsgKVn1DyHna7gF9EPgw26Agd0BP9QgQN7sQvKMq7GFyAx0/BpDE6kCshCO0Yfxh
# DATA nGeLi7GAR1/6Mkkm4Ay1rktVvrxpUMIU9Pvp978vscmaRO1TJsZ17fNDazugU5ZZyu5iWDHe5OuxPnO6D1WWYK7setjJlD5z42ZR
# DATA MU4nhaUOJ7FAehf7bsENqLfk5LDTYai8cK7cozfKGPInaspahmeEU/h/shNCr13unGuT4xC5o5Tc3NrZXd+6ttHY/fH2BiwrcDO1
# DATA Q5CRERZvnwD1D47brXG3PUwnvtaQ/lfY7/e7M0iPuTBJws58Cn+u1ZK8KjQPKuZ0wJp5NR+sG4WW1C9rE9IupLaE8IvOYcvzBHqE
# DATA b/DY1UKOia19RAa8zxCn7okSS59yeLDjPTX98CUUW9wWF5L0SmgbCbWuTvAomcm0M+3jfDOq9l/X1mDXRSvkB1Uruw3KlBHu4tFw
# DATA Vx/ZDhEb/ZklX8IXjrYMHsytKpsteH4VEzyfxDFp0Mz8OcfozxCup7DuWex/BiOnq9hBt0l3MafFqaxBzaj+zmbomAuWX8T20EsI
# DATA hBMXW6bP0WPnxiJghlYURWibN6bdP8LaRIArrgiBf8G3YjQOfilSD1j+CJjvnBTvUf2ZO43VBPlN7PCfuIEU7uUYb7k2lqmOnwJG
# DATA VxMHjtC8VyNteCmxdaO1PbzMk+qvWNcvjQqxZhewsktF5G7LBxnh7QBMPTA82l/uQrE7qhTLBrkFt4nRE9KJ0Xfm1OVv+ZwvtrV0
# DATA 7907Te9nmt8x6vfypKz/XpuU1/SPi+rF5R829+vOE/l7hfzkdGNxNkOoHlNhPsPAiEfJ+c6HJ8j+H5FjxD8BHoq4Ahj49E+CCIm9
# DATA nAUAQdgMyw6dONOeEtVkBaJ3tPq/6vuNoixBnpuscWIadLO56IBOcILSf6uPSbOGiimjyqIsUODgVRU9i0T7qic0KugW71ooxX+W
# DATA 3LN6x3heRbfCRHyxZmrxURMuULoaEgV/BkEduZYQC4gXL5oxX3zbbZPQHy9PdumPS5OfsIP+XYltxm7BJdcDANcJd0J9diScVcKy
# DATA /IBpP+orHuyV8xS+pfjXoHkT0xrAKpuOe5BI7pHugB19BSeK1megI1jMkFNV54G6O/8Bjwc5PnBfsf7VYFKXy3aATwgllLvCpvvg
# DATA K2PnT8oiCml34oMAwszgfNznVCIxh0FwJDQkCb88bycEJsEITv0u8yHX5vTEy42U+Qs474CVLffIjWuxQ5MjdHJWOFDBKklDqed9
# DATA EvhKu8YGPSMHAUAlK7G9Vlxldu7LCADrPBP0FQXQoFMXC0uf25rtKWZr20l9b5E6ZriukhkWzWCZ66JdKQy/tPzWg+gjnWE135Bg
# DATA 4idCDCDYEVzFjAAcFxtI/Bk8ywh5OrCLJJv5yfYPkypn8B85b8BjOoenLAD7iz2G4oZJOEGICFGvA7pPOqO8Lcnmj4YLMjR9F7/o
# DATA lpgn1gLr8KIsxOAcCVwLCKg6d9xsnHTIUh1Ea4ZBHtQpy9KPD4yln37Oz5pmmfcfa+5FUHO51OGg6hi3dJwo1yF9tg0913/cTrgT
# DATA uo6bEoa4PBalo80l5pWIzZF/UOxjKrUxvdEtnCJP+6J7PWn2lATeSkDtYeWGY6d9agRcFyFhOfwrbuS2a3hMcp/TY/BcyORCNfxL
# DATA CRCQoP08TmyWoE2PzoNh/h3uXNa4C2AZC92uLdYcUEKdObZWi4mS6/lj9LIlDDXyNJ7CMqfPGu0qfT+BCkJnPEswiUnvQZ5t2+XO
# DATA dzPzjmTH2bbuCL5Syzm80wEoGR3sGRcCLnG+Bm82ncQ6EbMx07I5OiL4rP4tGTgigPmK7+BemsQ4nzgACCZ8G6pvNyCQq0HsSQK5
# DATA ChzsAszqXKH3LtIY/ePAjPUMfDi0oTeEtOfip/Bm8KP2SOam3lAAPldjYkzzIJLCLU9lZkmwUsrI3XUDniSy+vxBm0E0nQ6hw1mJ
# DATA xGz6AFQ+QpAZ+iyUIAt04NvscBBkOgfrDBCJ1I3KlUxcPhoMOjLcqdtTltV2Pa7nCVchIc4XOvq/a9hoPs1Q2Cgrt5tID902WIr7
# DATA D3qQobHXHGTH/VFo/LYxn9P7/e74RI4b4041Oh2Aiind7/RaaC6jTlft9IJg6Kd1qibu0Fhoe6HQdeK35lOQCF9IF5e4nrZVl/1o
# DATA B1wshzRZ9UjU1sjRHxOXbUTD4L1roh+kTsObh9GYnVy0uLRGE/26mnK/IzFcQfpVtI4swSSlX3IMNsaU9FOCoMSXctjutptZm/NS
# DATA VxdmOl564LKvJ2vLgaZR3617inCHnQPtEKr2cP9+m9JGKsImxT13wXcDnZ555ocTE7mGP3X0GrdZzO+VxJtRhJmOLeMPnegyV/cF
# DATA n11ICsulYrKYFNaSMl/81PNiMNFoSynYwZUzYzj9sM1gCCl7upTMYLRjivjJBJ5GC66rkoPtPGoeISIp11EZWuDO1dQTbgVDGTya
# DATA KJmV+rwaAilzZUFXDTXMXseFXMTUtIDWZ67rgqqrqKooF+4Hj4tv4Is3qs2T1qW195vDk0tr6iGeE0ceKJOZHUEe1SD5Rl9UsrBW
# DATA g5f++o8HBERcMJW7yW/Nczv1XyE9Oj4YVjp9k0dqiby69K+Q1vjYaDCAuvHm1OKUbtoMFFEqaj7BxnwkDCQuLobudujCtuD5zJwZ
# DATA jzPtg4Z/lAfD/sNT72eZLvVD20HNcm8LXd2Mhxs5vU0CajRoYnN71YCDBUajzueIEXfAsTzbHUwZrDvquoGGbxexdZp/RzA+ggoB
# DATA S7GRlFhdLnpzISMtRcEr/Nc1i9nFIn2IdawU7W20pNcUnFNKonF66fRtYm8a+0pNI4YMHfAH3UEpswtPIm+TZgYOev4JmPmQBiQp
# DATA mdhp/s3HkwV0kNUKRSfHdMOCow1PWrdeO1NHw6Tvzv9Oty9HtUH/0BK31QFGEjFir9VIgDJynlDu6Q7wWomge6Ln2ShydU8i7+wp
# DATA jEM28JEwvMfgGMav/2HZ0CvPkp+xytqiVEXgFe6gCsNepHKhHcqmMN8P0B+7iOt2XdoAZl2dgomJfahLpVowMdx80On1wB4dJSlm
# DATA 7WZaHcbOB/wcJ1fOIDnOay+G3yA9q88zWv1mvrhYe439WHhVMDceHj4TsGP7TS60ciE/ttd2D5GnRTkCeRjqukKY4UHFTq87s0/0
# DATA zIQ+0NjtI34SavGw5WrEYX0ugslttRihovNT0vQtQ/3zo6zmpJxD8mUjfu1kTLQ0mi3wBO9GMuJxVkDf1dZ40NKHVPhG3C+XpSVb
# DATA ilBjrZA7QkX0OJkTBx73OhLrbdF3D43UZ8pGQpoSoQyJEPeoI57AzFtSnzDPmAqq7qxsEmmos5wlrCp3fRIKpXPEV8xFrrEOOBN7
# DATA Lrr0+oK97+I2ttegPzzCRCWGvip0C3NBXaaTuq67E7moy8ti6Pbub5FzbQ8K+SwZtLJjRUC9ErvJy6UcmJ8zMYVwGKVACgmFqdRB
# DATA R6GMOAyC8gRdKh8puY+UEK6AWAgHVQokm1BYc9tzvRMwZv9zbBFlqbyoV5ohjy60p8EsjQr/G+B0SQ2+z6s8f53HEgZJDZsdtSJ3
# DATA qNl3qVXEUmbXVxdPxvbRlmz2kLXtn8nRuBp3dX2E39EUqA9L7JyExiV5S5TiuRsIhLFtANZeRr6NRSMw6ekqGUNNTCU11RoTM44s
# DATA feOmEVgs863WBQNTtauULpqSSug8dvCuzwfvm4sp35SwybjWNIpawB7wBFvwLaASpJ4Dx7nQF6hzAZZH1M9C4wV1uwXPvSfwcpgJ
# DATA qw/uOUEM6/NfQSSbJJM3GLP0xkJhMgYfJrY8NAXPsaR6LkxS25SOyV2+TT9NRGEEmAYC9ZZIOUpqR+aCcabOq/3TpN0cdjsoYzEv
# DATA zuiMbjdbVnV9RHscqDt8c8QIjh1Veeekrb46Aek4O262+g9cvNlKCLPg+o0u/Wd6jS7N8BnVff6f0mV0DprTA2CnUbMIns/oUsxj
# DATA 1IUltaFJ2IXU3Q0VCRB266pGYHddeIOYm1Y1gG4w1wp7I7FPcr+n7mBdP8NDjDQcbYF86PbH1JffI1r+sP6EGDCieMNB7UEqkdOK
# DATA letA4lI0U4Z4FA7I/Q/tJ2gFVX/l5Gr7NT07H1Xo8b0w0gsz9Iih2xUYIomhLN/FKQAPciC6TrHBUzhDQiQhu6j92BQ2FcRq/S6B
# DATA I/h4h0NQGGA+gJirGaChuG5IUVQnIp2vLEycfPiUKUAQbgTgE3cAvuxXjcJDOOJd1BMCOfTUEh6eiHVhNze4sKlYoje/sWgZr7mC
# DATA 2Wl5SmkLtoJqisnKpq9+4ucYRpP2jFrEnScYTS+UP2RK7hDPo1yc+KawtCsI/kV549T595l6+ieJn/uKZDAPSBMfGaRcJ+mH7zHc
# DATA a7UflrQk2EbTYFMjVM+EzYllw3k9ubwIOXDwP1Mcww1sFLp8P33+C8kB+wcaq3rgpq9FFxww3kRQciR3RtXtZSmRdBTVJEyZwRnq
# DATA YBKg5AlZVJb7l5aXJ7kD91A7VJ9EJYoo3t6U2KDepYS8KWqBA34x4kcczalRkvRU+akm7IgXXHKt31A12U4TQqazXVMO2fWEK5xM
# DATA c6WwJdGGnEsGkI7OJSsTKOKnK3G35qTKmMnzxIErZtZAL0rLElA1TMEyUlRjjnxgL9Xxc/wXkYITLZbjTWlk+Q3NktXtDKT5LAFe
# DATA k0B6r1O5lRIaeXMIykbMmUpo7lipVRfMfiXZwARiICyozzIEfUdPsG6LIa0HANiBjbBEgR7do0ocZj2Ut2Z5t9t7IS6HMoL2N3Lj
# DATA 8m9bvqwqiP/FoEQI9T+/f76Wpb4x/6S4178VYszpvzbwH0VtTtp0J/GVvcPi1br7zmIEoBSTe3hv5IEIWWKLDVOAGg2CMXCHRSqt
# DATA VifD22/Bwra3dJuaoTCmvUi7QMw2mr22F8TNC1ZMV8SGwPLkbBOCVvl7bqDnsjxonkSNsnKFywRH/L+EGcIR4tTzQudQMZ5/9Mh3
# DATA ILW9MCh1Kn5kEtvnycu/0loX7GoD9lKBf/AJ0B/eI9BqV1k4v/mkwlWAhs8gOEU1glzSUQfqDnAP0qU0x5ffynqf4MwRrNLT3CRf
# DATA uRJTuWyOuRwEVHhQ12ZufsBy6ZzzQodBg85MH9qq5DcMW6sgk7GUDKwp9DONI/d1VJb02AKipsCVoq/om56s3JlihOZ1wGafJJYK
# DATA cPYUR1QphKsRh+SdL5czjzcHLkO2on5to+PGdUqiCAoHa1cNKSdMXVcC+dyGNoZL5we4n39pBc5wAghPG4q6SafH1ELjnY0fR7bB
# DATA /xNv+AmpmiG3LTWprpF2PY5m4Ayhgk6aDAtgi0EW1w7kQKZM8k8mHloVtuLBBHhuyox567gCVBPtdGcug+SWTH/vpZstJYS5FTv3
# DATA 76raMlRHHaX+0bBpIQXs1SdTsl9X3TMebvad7f6Qwm4G6g8DwITu79u3biNE9Kr6X+r6uWIFfBKqLvQytc9OtLNU/EhkR1bHRark
# DATA ghsQwkiaak/EKECJLW5+rfOTQdnPdQpa/iaMjpLvb+IhsYfxUnNBGuaCpzMzSr1LB4nD2ocxBnUV84bhazF4H8LPs8LBfDNZnD1x
# DATA VZf5FeMgX+iP4fphTPKB2abCsRVi7JTgvQJyg8eBuFyY4gBafFHgLY8XR0AMw97FvpiGahi4K70oUmUUB+1bwqn8z/L/fVHYUZ2p
# DATA xRVww5zbpI/9HDwMtJnwN89+V0oYYy2q9nTgnb4F6ED2XcaN7jpt5eHvmStXX3tW5uyvAtY+J16f5QKuXdfLTnnz2PrSuquq7zW/
# DATA Q6Q/lwtOh/Rzyy7kUIRI6wS9Z1qsvsCem4lbeo5dHj/jCc17KkEb95QpIqmjbxj2R0reIfdEtZeqUsWe+kFxyeoPsqxaAhjeI/gF
# DATA fzDJr3vPkjmQFcKdG2QS/jRfLinG1DQhbHVkT0QxMGcGKO+hibtiRcHUUuBw4AtTA3WBGVNOyXq0QRuYKVI7aK30QuCNjEzth7hx
# DATA R8RL452un2OAYqaDhZMBkfcFr3PJOGPo/sghLCvOAo+qOKafQistf3nOuT9bXFSPSsnioq5hEmZOLznb0QHKUl8XVF8HXXTnP1Yn
# DATA BUkW8FcD6M2VSDMjjEpZMAH3YWcV5IkYObPsAeUVJ5C9rEIQZcfth4WLq8UFnfsAxasYLJ/3hSLx7Vs7u2/d3thpbK/v7Lx36/Z1
# DATA VPBTQ16QhFX4zs7GbYyVsA5F/fL6VfeVX4uHIXhoHafVpSX5UT2Tbkz+xjDp1n71lbWLq0v5tb95+9bWbmNj63rj+q2b65sQpZ8e
# DATA j0aDTNUNpGZWJN1e39q4YYrpN36VO3euNrbvXL2xec0UdgSp8bCbFZxVNSsPW2vvchUuU2+/t3ld9Wz96o0N1buNN9fv3IClUVLG
# DATA uB0O5ObG7u3Na2aum62TDvqSyAtYsejKrq4Vg9re27j69q1b7zBBNN7eWL+O1UbpghXyaqNCgCITs5aU3S1KBBcKyYPmaNQe9jDO
# DATA 7u9g4oftCqJQt2HnFzE4rlZZ/H7qym2SHpI/L2EvwOhYuemxUe4efDLeN+U5f1+jmgQMRio77DaPshpWOSV/LdZ/oYY4qqqGkF1d
# DATA wFc2c4BPmBkg0APwAppgDOzcb4sDHv2QSzG/cuMcMf+RoLz6KZHg98vp3eHdHsC7vnwutz7EJdV6jSvgxcPZoFj3aU5YTiJlI68D
# DATA Hjv8QaZEltwc082geQqGazU4sDZU4G8wXmXtS2uV/UtrbEyTaRHYJwoochylI8nfuG48ae8VXZQcfrd3jwUGdsRqXmsPR9vtE9g5
# DATA P30w2h7vK779DiPSq55Yr+GnegO/fMBc8np9F9adnF0d20LBvCglu6cD+jNYFXtiPwXNHvs5IkaxpFh8hAkESPNnAOQeAWIMIMN+
# DATA iA7FHz17ijppUs8iUtPTeF5TpszDl7VgUzsjepvc7ZkO1dIzBm5VNP0y0/CDZmdEiCXIQAsSotY5affHo9rqsgkptiIFMNZdsYOb
# DATA iD5CIYRq9VrNrpIk0yiwSHjysf4I6rqOTwTjwd05VjFoknRN7NOj1rVzCEd0e0rCLgytVyWzJTCqHRyrlioDtf5ayWVqCQAlgOiW
# DATA k9ecMp6p/rVasnJxZfnV1egG/QM6FYAXwSO4+7mJbqIr/Sh5e3d3e6dsYHR0wFuPU97bvTFGYNZltZuHzDIlCW8Z/nd1463NreTa
# DATA xu3dzTc3r63vbuDTyuIb+K86S4N3qZVbW1W34zAvaCYY8O/D4QSD4SurpS0Xfe7DgdwPvCzhWdatbG/cbMCwG6O+OlZv498F6IQ6
# DATA eovFiiQLNxOFBwd8SUm+G4xy0eCXhYMmWtHghmBNZ9GpocLwO3iYJO9Tfe9u3N5888eNH72y/EN1PKspW7/RuPa2khicL9U53jkZ
# DATA n1ipeOHb3Rs77E4Pf95faayyp3izpWgOiBg2XuWkr6YYfN8KcIbyXiST0zGYUoJCr+kqLCyVAFmtMzpOMtCujWRSVG97YGJXN4RC
# DATA urL6amVZ/d9Kqk8ywwjUeAqrEJb+sFBZKenmyn5XIFFuM1O89EEkLTh0QCbowbA5aFBvCqo0qeXaw4bwiZoWrqA+xbjGwzxBX5Gk
# DATA TzFUHJjVoN0eIrHsq1v6UK1lf3jCB5GmGmBgQn7V3GuVAbknjMUPwD/OQbsC+yJEg/yTpCexgSvVgpdpwyN8/YdpMefWQl3P2sBO
# DATA u4XD9K2NXcXCYB8trVRWQCB4W01NNTmTGZrAs2t6KdXNugvuAiA5qP8P+dvwOC4W82ZvdXkZ2FgHdT/UvGKf9wuvrKyKnq64t1IH
# DATA OltbXs6fIYvd2yfnrR0+Nu0jdBMchvwzVK5AhoiBvLJuuz0oVPj2Q8vgshU7kTGvwQeIMf3nxEK//JKSYj7/5Ioo1Sh05xPJs4xr
# DATA WoqyZUyc/h+UVAZspSj8lUnVKNZ8/MV58ArmDpJ1wLdAHVu2yX7mRRBlGPU2TfHslTp02DVe3g9TSkAAcEDJMu7eZXWpwmNTvihO
# DATA gPVcuduziu5Vq/Xcco64e5imKe3M5Oxswapi3Os8rC7dbw6X1L5b0krspeG4t4QTUYHNDVUmqHJtwF27f9DvXlk4o8FN5JKudj1O
# DATA hSHoK2QlyboN+4iPtDbqeqd69MsGCPY5Xw+Gnfvqtfut9DVLkE1XVvnfi1QERKXVpN+7smANAW9XWdI/PLzCNhB1TC6Ns+GSYkrD
# DATA Nk3K0vHopEvvm+NRH73mzCdt2A4NBJpcW15LltR/KtYHrZa6vDVbail+VL5GJ3MZJNHyLbqQKprMep1DJVV3HzRPs+Cr2wCYMmwP
# DATA y9t9Nf2nIFl3DkbsyVd+cNzulQ+G/SzjJ0413T4pQpK/+4dk6SFMAHjLLAlR4NHX7UCwnjoiGvv91ilJR8tX9Puj4eCgQeIKHSrJ
# DATA xeXlzHsPbG/ae+AO+Je66k8jQewikiBVMJm4w1CjuHu3UnjjpQftbreMuA5LRTUadbL1TsHP+UrwCQwWTlXySki+Px528D9LSU0t
# DATA FJZX/0/tF2YHh8N2dlyIufOUtPVX7Jn61Ev14VtL1fCX0xJtn5q2b6CwTjwDS/uaphxrqPcY+ZFqYQVbQK1Wrz1qoAKCAuK4JfMU
# DATA Dk1+iEwDPTUVc+geQhBON7XfUfVraxflaae33x+rpaUXl+GNDVZk1ymKv4JTt33BiN+FAcPzMZv3WdD+gJzcn32RuAIoXovT4sIs
# DATA Fbjbr5p7zdE5L60VCTpGeRHwCKIIt090MEVEMjZhcZ9i3CoDiH4j3TVd0/rDPTwBYhFyrK/wlzSymGE4EoTSURMUS3cxL4UKSlC/
# DATA TNa3N0vO+gBGNbuTPEp+NGyemqv0lxxBJzlV4DS3fEI6hz4tR8BucqDdf4uBThBvuKXuy+vXb6rrkpuQ7lOWHz4GPGy4039kx1N9
# DATA SittohhiaO/aRSwIMA1wcfO8zvL1St3+0RH5o52lLXWsoVtIChqaMqfRTfsD8QA5SxWjLgOPhkIXl1E7Ao+wqHr0SsoMEOJu+wL4
# DATA gwBS8HrcU0wwK2ejPqRrgY+5eQjAp78CBaWO0D9zDd/ay5jtsi3boWYSVDPudk46I6qn1+f+nqVZ/xB6trK8dvmVVy+pDqljt2Ue
# DATA TCaT+fykmoOBJC+joTOXlqQ1krSPXFnNkkqq5GK9FJOQYbmy2t6huWdVRUtTRU4f/4xBGWt7bIMu052Jzj046Yxpmnxbs+qSWuUl
# DATA NYolfpBTc6sNBsas0e/VbNNpax9nU4mxLbQdIbgSYzEoQaI7Oj5NJ45VlUzisz+aRLtBrxEbUfVjpCgMfJDSazevl3fe3riB+bEO
# DATA IPtV+TDbQdFLHf1wKHfh0ISpW1miOtDzHJMsqjmBHqwso9WCxQkk6owMwkryQV+nS3SwDEeNgbrq91u0FzLbPBzylMBoCyrIgXpH
# DATA OWX2Us1A0nosxVKEtLR9pLpyubKWvjCR0RXy+ASFr1qqLnAn+1SbWMDUHO/+BIZ5Z/carKOhL+mhEaksH4gpzc2zgIOjRicD2e80
# DATA Kd9Jvv/9M8fMNEnKLefh9auTYDEvzlrL1eWJHbahaDJnrmnH8Map/rDc7A46PWCP8+61vMmAdtR5Y32PVwPoZrmcqa2Cud7wF1n3
# DATA AWSetNL0VPHfk/aJWufyAEV0etdW2wg3FZYBqZf6Bb+9rvE/KPj6xRWFI5N/9dVX6RVwJPhrOXdA+UtrnGLKSu7H+rI5+gP5Sb/m
# DATA ylq+cxbbUqXUlDpsCRmZlRgpZFj4rxOkFIrO1fxEviTy5VsF87/Em7zot/0XgYdG5NOaiAHgTRK8BmeYy8ulREnZk1xfJBbApufs
# DATA sk0YMbmLctmJ6oSsFI7M9JTE3DTqwpLt2b45gatbPb5/wzUKqZckjRrBwKtv90T2QNrLdbqL4ghGjq0p3Nn+Xjg1SHOHFP3ivI/t
# DATA u5iYEKwwSAwr0W0bP9Rf7HCevvsJzlHt+9CuzXLaYRvil17mI9uMB/q+hAyg1+zy2f1ysTI6VpeHYe119t2CWMFRYVjp33tjubpS
# DATA LFYOMByqUPRKqFd5/MvhMq/M4jIrqxFhYNUVBviEEIg1iHryUCF0UjbDIA231gKZGxkJF3yKBMM7fjVnr9DbnF1Bb6ur5jRzD/23
# DATA bl3fuHrnLRjTybg76oD6ZnQwqC2DEMBEl15erl4GhQDc3Kt0e5c/l8atwTQpIC60BtvjGvSSwhrAuF5dUjSyhF1f0q+qw75OIV6G
# DATA +awuwX/NM1KxVpfcpDNe4xJ9dmZVhGFqXjV+6Jr2Fz+jKH/jqp/Y4W7yJywz46ZXpemJpQIfDZt41darF1lwUubuGWGRfcqtDRxB
# DATA unAK4W6c+wqjRFnwRmQVDhxYLy5ysuhbc8RerdUxF3EeY2kKcSi5QcgiqtVLS0nwjbprZs5H/aOlbDyA1UH3z1iXQ6YNVuMlmAcR
# DATA vGLdYI6X8/VBf9jWfsWxzxFT2SlVj0s1qEiCNYzRUd2N54lonvAYIJuC9b4YXlqEbuviaxqMDM3m+Usy6mawV/POdstEkse08G11
# DATA pbJ62fCtGHEunI/LkAEC9rfNZkgDD08rrSW2B2MhZDjTOdsLTs15a529A85Z4YMHD6TCmCkC+uixT4tl2Qv4ovxx8k1EUBk12ewY
# DATA qiCIKiSPCN4OSGlemBX88qv2w6gwKiYSQ0WTyFISe7dU7e3qV4wqBl1QWwdzlFXETFP2jH94SnPx8DTsLsVmVRPR56aYEcTqKeJ4
# DATA 6ExQc6rI2MvGlkvvDEG69sNPpnpNnuviZQeUn4UJkqsJmSfcNzT2QHyetolykgUTHUKi4Ar8Z61QLE6KYQ99oBvhrFPvOTEYK2e8
# DATA trtVzdXyk0ZeHKNqpBN2dPZFKrJJOnuvlKPJL8acoO0gPSAKxT+cYBHBjsF0eCWwnPUf+KYkttf0uy3g7g+8oAHOLOIIrAWsrmj7
# DATA o4J4rWpwQrRQtWCnNAB/aNgVf/vebsNxWE4xv9f1TfoLvXRtP1v4W9xnAVbZNOnlQ1flKJWP/Ap8kUsxZ2J4aIIa1C8nBsGNlAlj
# DATA i9SwKUripRrMH7lGtk+LuXf7/65zgj599meOIsJE2xhMC2m2I0FDz39NQAVQM0U2KtIgrB/ytz1Qm0DRSbtV2CuckCMgmJ8hBIJ/
# DATA 7lDSH/Pguro0dnq4G6ynt99LOTAbs0FxjOBNbI6TshaFYhrUCySchu4R/WFIh39bVAN+RupOD1FokrkIdjBaXfpZhWmN+wOJ367d
# DATA 2dlt3L51C1cEVej65FW9tbJILVHcraocYYdR22WQOeSVgMxa6GHYHzZumpGxhYreQpynHqdZXvOMM9sU+AOq/nvJLclWOToettsG
# DATA I7EMaYwwBRQewNziSfM02W+Da0C7VUk2EE5F4pi4QiwJGGyD5n6n2xmd0iWxJC7KaG8kQU2xCtSDAZ9FUIdRnzlFJxNoRQOVQGv0
# DATA daNCo/gJMtXSGPQxwmimBosDTcLQYSXwaDRTXwz2pS5praZUANE2YG1E2jNPL9YFjxfOq0hclR+mZzcF+WCYfuKpxeasj3JziQ2S
# DATA ql7xxMBhu9tkODQqbnZARd41Rn3aUBLhbuMuwKHuf9jJGnN9GyZO1sED3CtYWzA2y4MKJUcCaWUVX75QWje3NnAt5bqcxyuY/CO+
# DATA AnuyUPVwLcJdjL803VpURIw+4AMx9o7gC5+QMfoLVOKGjD2Sd1Nd12n73mQ9HkgGVxWxAs4S/L7WHKy3WvzX9WF/gIWGnftKrAYT
# DATA bd05ib1z30QQoiNHWJePgt4c2AeNhBFWkzN00G0OikoWUpd6JD47tde1dXXgc9h3EzE6Cl4QPzhLBoxGR6uqs8aNJ4RFgN7QgcP9
# DATA gn/MYYO/rKMmEvMpI2Y+KRXVdPXJ+0qyMAqTyfycwG4CpzK/jfK529CZOWfOnaJQi5PnF4w6f4TyiamgqgHFwa8yvsvgJon1pjnX
# DATA 5CpepUHZyzfmNKLKgagxS+UTLRgqbRADz/pdWphIcCAkXTXZX2NIFn7y1/kdQgQYXN67uOCmGr+eaajgLi5QNFZhJka475/EWsnC
# DATA OaE0ivPjR9loGPkgpDPHS5mKLYgMjQJDnjwQsfP854xHz3yUHsIMfPX81w5rRW/PWmKrGQpp/MwB8rYvkpXj9kMng+/ZVFyXGdoR
# DATA 6Ag/hz+Ldk5LQXY51DmbSppJ5+QqDWL+EK+MRDk661yZyVt2W6Y3WaQwrBzeRC4JVhpV62aXUxrM6ajdWkpdPzTpZQjToJYJghik
# DATA QAmuOzU+d7CVKsoVdIw7jUGciVxfOKFD7gXsX9xdE1CNRW1kc+WYPUw/HvMrU68+cq9pnHl1OsiDlvTIGxlXO4B/tPL3EsrL100K
# DATA Sz+cpLD0h6UycfOrmop1RUKgpg6r6ombMFPVpXjwQRecg7ckD+tuc7jZO+wDDCuiP/Jv4byQ1hCVH20ldbVHTbAPFcDjtJRA3BRk
# DATA L7CCafojxO1WHWmOVDe4hOpdQ+9xXQuBiqpZWQbahCor4I7jqLvkISC2A87r4ioSPjajHl1KFuV57ACFMfKVjnuSSOMYddFuZXgb
# DATA zJqH7QS95SwlPX9Rye05hCFBRxbMRIHFtTFQ+yZvgnBA4XxKQT+bIFpoFOszFeuSXqNHvTGkwv52GpbK8xrPlMAPqUZy2uaQTyzE
# DATA OHIERDqCdgaoK8ErvVmuk87RkDkdSw2oKj4Y2WnjuaUC5Q4ymXNgdRq4nLVVTSAXS4TcwC9WltX/uI8vv/zyVZiYhAIASNXQ7R8h
# DATA aDwSC2c0ARRMRDrtqbs7EA76rgPQ5X3otOpGu6IqWwhzdNtcSDbJAR4GtWR5QUd9yR6EDEYF+Ku//9OaDI8MPcP3Ka92R+3Rmr+J
# DATA MQiMp8W7rbfRDwauHP5r4nHQlwu1ZMULMqLMvHQBxioILJWueCFGyhgT5lgTDds1/FoJZc19JbaNR22SzNJKJSWs2OEoyzsu7vRw
# DATA o/bCXY1gshqbA7uRFqNnGvWik5FMKK7p+jEjGeoJU4+YuItTeqWJuBdjOFBP2Buun2Jjk2WrSeZ3horVBQVpJq8HFpsLuJreSAn6
# DATA MLvdaJljG5gZiRM/7Xd6mGRgkXQFsWm0PvSVFUzpc/RVZoigEBQHUKTWsmWcnCnjxYsiBltTGI+/kzXTYbRGFJVofZcTcS8jYYj2
# DATA JJzcgz7hDl3uv7q8DMEigKSTcTgIAno3+vesZKEzL7HEJ9SetAaVt3wVau7r9AOO2+PxqNOttDrZvcY4gxRuvJqVQ1CXvuZQ6IXk
# DATA 0lre8WtmelPtjsPDzgHEPAGO7z1kskrMOkG25G9om+9HVXFyKvNxgPuVehWOhr4JkqzOJEiJIFdfnqj9D76YbuXfAwjl7jjDwhAi
# DATA DBuIUbIVDY/JtCV730LKlgOEzFaxsGPocslZWTwL0of7KTL3/ng0GEdykdlfHBwrAijg+lt7QqPDr6yskOYQwedDYiQ9Nd1d8kjP
# DATA BFnr0vH9tt+F8EZLOdpsFSBIWn9WSi698srFS/lRt8BvsJZZIceRlXygZmw0HPdgNVo5kcQ0oxUGwoeG4uXMtJQp8VVOWa7vUNHH
# DATA cQQyvJ9VDrPT3kFByqlJ7PULrlURTzBtTRycxqQeS10iZOPwXvU3uSeQogDdwgappWZBdweE3KaNAvfDCroqshsD+w+SsVqcCbeR
# DATA HqFysBS1IOjdfru5vYHP28Oh/5yln84JhuWABaYJWtTKLjwprIAnrhS/1+l2reKVVrNNsTXAtqznePUVABKIClVFtD7ciewPwvyn
# DATA yJPSCxpeKbhC+jDqsC+BBMdDj8tIl/jlggfGpodasBP+2G1XMETdet3qNI96fbXVD2BZrMKqKdpcK5cuXl7zEzWUqCuZEh/b6hZ4
# DATA 4CaecirxW9R+LFIOoFAKFvCJcbQjXgm+dtf6426LYaOViIWiMjALlPHsMSBkIPNp5419C6Rp9PMzotxGTcYAaq7Zics4K+O1Zg8v
# DATA HerQ6Z7ixrLOnismr5rZIpIUogXKc0yqADWFtyVN6IAT220rbrNND3iniJsA+KJYoxSAbtVo1yZWJO4DwPmxaYNcIrGZQR+oJn62
# DATA 5VCW/SpYQ2I1Wa85yI779qYogNJA9X/cs7ez+lkixoSFajk8yg5dHXmqjCj6zfeS9YRD5YQsTpr31H2RDkyI0QPTapdEN4Sq6LSJ
# DATA in42VuISZA1pdwZgLeb6DvrHbURglLFVkttq7sDDOLnXbg8yN6OeWXlKmKHYcH8MaJgVSZiu0VfUHBRs5srvIE6YByrKyTrkb0D3
# DATA cBLClLirRtxu0AnADwHtQ/70NpfplAMkpTvDzKJoJXHz9IubLYIfCnqW2HmZ2eILU21roG+Pez2UgSKphSit3aegnqM/ETwCU+vE
# DATA tHlfOWpxzodmo6JjOiHS+X2cFwxKg5iSHJSVzFZh1PbWtWocfgYYRviQxWjjxfCSraxmpKMXs5lC9Z6p53yJR705fjRNX2qp2yN3
# DATA An0LsHwvMEUTJD3q9HJ3qitnAKAqJgxiXaSicpxyesjqyLrrvkZ7eqpx3mi2YfJZIZtjRab66nm5HOOz+hfE9/5kjukzepxgEu00
# DATA 0mqaWgycbjFNZ58FMpqrhYcaKsQH4diuereN68RkMnNl7rUo66e6UcGFYtyBvEiKDybN/Qy4Xbd91EToCkErNJUZcsYDjUSrJYh6
# DATA g8NU/Ym3NBZZskqyBXmEkuwBmq6RW3YRYLDi37emnPraDIUDJUkDY7IcenBe59oM/pUym3xK+4KM+rYN6ml0cSWJGeH8/YUhD76U
# DATA 1B7R/CkIlUBZFX6j8bfyNXh+3qM90UcuMg0Nj7r9/UK6mBY9igVdHmfirHQJNy2WLikKu6az7Worp5t+tzhtItmqIoB7kMPyEYBi
# DATA EywEJLX8i4ZhA9vf43Ben8Y2zRSVotZqwKA1Opw1QlbB0Q01T8OI6lvbFGApenMH/PtckhCKePz8l89/IahUUUw6oDEkCvQNdBmy
# DATA NwE4IO8uHiyWzMLU2/kBpdPuASBbIcZjp3BvBGh22DR6Rcwy3xdtGGyc+CGJ3QX8S8I5/LSKnmeuziMa+cbZMyTTwV0KNg6jK1pI
# DATA iqBc6fTHWVp0Hg8pK/JpsKMIxYyw9aVm24BO7+M6Yno3p6cJw6Xhnq/xL+4yJA5Ey6urtEMwNa8s4bFFSnOXPIlDixaX1iZ4oYAq
# DATA p2907yTE1BfC9xDjiyBXKCOGYq9fkJOUnWxeAFnU7vkUHoVddSYDiAxiKRCDYEm9Wno4bJ5yZghZFBr+CeFjwif7416rC8gWczv6
# DATA 2I2+NJuyEfmYZix3wn7rjfqJjJlS+7K0+lQyD1AeYPsQgrwEagI5G7AjxmFGYC/xlp882k/chVU90VkNEKWWs8/6HYzTj2xAphSL
# DATA zapNYWeIdMuR9Dt1qiKnsQ0aZ5/GMjdW8vo/UJ5dQIvzID8NjS1ov7+McgHCIkMojJW2cD1BdZsSw1DgUNfijq13Bse7ZNB/ANe6
# DATA fpZBymTMKdccktWh135gVUZ3AMuFKEGk3OwYJZoHx5B0QW6TYhls9k4TVq2AD23FUthQLR1CErKwrUCyVbIBnt+O3IBCu5EVgmPD
# DATA cuGwP2Ofc6tBx2kDoYbIaQP/ZE9QUE0A+CajDld9AwOGYKASS00/qv44/V9WudW4ff3W1o0fJ+/TLxHM9YOtW2/eunHj1nsuSY5i
# DATA vFVrRU2T7leBjsT6klRW9pcM2gsq3Ya6yKvLsSD2cj6janBR/FrO7mwP18nK81F2vW9OmpzkI70tFSf/3we/QzlDkp7Z+UoSO+28
# DATA YBBKRCpqatsiPNKxqnP45LuAVQiFquD5d4s44ad0aDBI0p4PDE2oWHQptI7AopciAl6XMMqRhTx44DMtotaFWDZOmVzC48rFHMgq
# DATA zRaFatIGMZvIsjxj+06SeStFLuQ2chPQU3yv4Z7VhfxWY18y/pS6EiIzoMVXlIUJHL/A1UYfuucfSS5MpB83Z+yz/zElL6HJoWln
# DATA 1fXC3TA6B6+UktYKMgct7qUJfh0wJLsbEi9Yr8dqBdRXfTj9ifweISfPB4LYhn5Z0xsjNqYntFh30hDq52buaT4vgKkjsQMZ4LqC
# DATA grlJJfRF4ieEfvbkigc7hwcRrJdcAr3kg5xwqMJGEqt1mAH8EHfwhzjuXwJ2m3WyVRLBusNTUpX6ApOOfUD6HMEUeZST9FAx8Cwp
# DATA d5thjgRy3PyLKvgHAqXXeRIrmMVDp//+0MkgiKFOCEDCDvGPkZwoP6G42z17WgkbTIkW7WTg/A0mA+dKYWqRQg1lskpHozyEGRqe
# DATA /d8GQVZdzlxvWkyDqKoMK6QY97A26OQTIkvfM1cRZ1jPsH2kbjNwPYgPmnYrVKGujtXkoBXddOphQtphyR6VDDBiAE2JzOtha40z
# DATA SWWJgaTxjV+PRCYYkIhSBFBF42iUJXtIZfRwpDN8Udh3SSK0SxRUXeJZLPFdDf6A2Gg3isFlbuTSE09ZjrvDztGERsfIfEk9Re1a
# DATA NiChi+UNtsnPShJfyNWTmFzm8VTgjhstMmZfdSL5jH8PiYspPyAJ4LjB39y8sbEDMxwIu1Ze4zD/uocFbaeNliEboGM1G+6xohuF
# DATA dQIMa3DeKeCkFzkpB59liKA7/cx5/ssScJ2fmwTNT+10rHFGnqaGMg0NI3lSNLRA4DgGnwPK3RNsOHAHN7WoAfi6Aoxtgq+tK4wY
# DATA A80LvfieYRCbaQ9RW4t6CfrEuzLhVF2QRL3SE1pFU4Uj1uVFSqu9jj7OHyBulC27GaJAYSan3qK7yMW8dvA4lbM8cdNIabBS04YO
# DATA IjDnOYWT1n05bHbv8mWicEJhOv7NpSI40uaeCcZX8bRsmJDOH5zNDm/mOBUhBzlqz+rx7+l4Rpr/xwj8V5UFmaP2XDQxnS4snDFv
# DATA YoIG5iUOn0CCJiK0Qo15Ep/Z6byDjbgWnJ1LQfy+OporfKnlXV3cq15cdU+WmXs40ALx+ke3My8wUcS4J+G+rXRWpRYBBOM4x3LP
# DATA Q+/xZSVKj9U511Y3o87d5NYQLcitJZRdbRnuL6TB8s+Kjxl/+APUTuHQEvzoiWSGf/Y0lBmlldfCGl9fIpsVw02VF5dYjAY6BUHa
# DATA ky2j2eifPS2BNkrr7ugryAdkZXN/EtXKhZ0FQYjn4z/mkEcJJY2pXy7x0wTPtKQj5PW0P+K0CSBicMk/66gqByk5FHN/b104nvAN
# DATA 5rHqG2YbT2Dg2KHP+AqBNxEzS3whFBO9ZBHXNh9Pe6fEBAmlff5zuQuxaR3VhlpOsdJhsQwjvCIuvSBhGumFVDkI08S7Fv2xh+gL
# DATA eoR/V9aHR2NoahvfaE2Q2rG1RkPJ4I1G0foSruiNJn9SSPuD9lDCpA6O+6AXqTGmD+Z6SjGULENDAyfCpRTcCCsDMk6ZxW38xv5b
# DATA 59TFOIGUkXyaQ0G9w3Rf8PcR4d4R/0oRkzk7LtNuwbKYYMd64HAlQI8JHjLqZvCc+4f+KOXxQJ2MFNcMiFOdkYD9UG+yESjOrUeC
# DATA 2ldmTAOcgm6zZ/k9YIOsHfUeizOV7SUxZGccXRPNKDRU5g7Yk5XzmjsffynjoLfOZGAyCr1cBsUB70GoNxQHhijplMtsUyteySvA
# DATA Jrr8AuI2NLUZcxG0adQTsPPbMKfL1FYEMWpKZymhb+57Wur890xKBJ4+tS+YMXlKTUN2SoLIzOFRVgNN+dSxKdqa1jFKfGtWI7ek
# DATA pWDSqz+tYbNTOFawls7oKZKp+qwsaS6baCqrpUjGDUyROb1JxCPrf/06ABypfELAB4bs8tJN1K0hmjJztsIgy7oCzHxxZep3DMoU
# DATA fEpZM6Y1S7zRXZLctvzqEYR+OlOIMOc5F9/5lHbbfL10xdSgyyvLM7c+nlRmlXWeeNSvMB61rpHezl7bc800YIbnv+UUcdwoe7dz
# DATA WfwHSmcGBgB+VfThrnOA8KFupBI/tSPeJPBj5GZFgR2LV8mnRNXV4IjRya+rlFhPKER3evX+uVT1opLl5mPX6INloqNSEMLsd23P
# DATA gfWzNAHtXnO/iyoTyEI6H84IopkYSA1FRes3brj4I45ZSfIC4AUFVXbO64GBU0GfZx0FYC81AJHBlFF/TdoZ7n8ULdgJ4XY6oRHp
# DATA zChy0svDZy0AGMGkBjC6aaNsEUIMx/nPN5tg8I7lSjAKQ2v5tYnTjUTQi+jMHas0TxVFUDp0KkWwib1+Op04bSHVTC89aMDLNrm/
# DATA VwzywtT6fEnyXMTOoBB54CJ8sDfUQUXf84NiKYl1cc6ptYqIsx90YPowY9Kx5TcV8cE/J9OYKmdb1zEuZjvuSzF32OdZRPdiYaWL
# DATA yTLIS8ovJOFnFo7N4ZHMNfEHf1LS2302yrapSZZbswt+QLRemDGj3uXIJkx40eAXVqe5l/EZzBvQ9E749zFboU5indON82y6yMXJ
# DATA 39Bids/bLfb+o0QwiJTA1c23zPiEm9Peggy0RCrDkqeqN5vafGbiGdxPed3DTAimI3jrKEa4Bd8PGoZrmI+sG0HD2Z+BQ/C0oZWS
# DATA WSPwXBzJzbPTG4xHDjIIOl1Ujb0JhHRyL6w6rl74chLlZRTzYzjZFFaHXu4WunwemU27wDsp17DUXBQ015ad2hzv3vnI1aLUubZp
# DATA rroh3LfUAQd/F4ta3cDFKFlbkPs1w6SpqpvF21zdkrUWlNSZnp+LpWhtWXUa9Uipwqyj2UK8jrJR5npof5ox1kB/Nb2HXLrBpaf1
# DATA NOQh+IO/nNEto1L0RZ4SQNAj0owUiZHmeWeQ0xv4fdZnI/6Uk1EoP0CensobfEnJcQe3ttKVOCA03DbUwK/EfY9A0NYGFKtZGxyz
# DATA HpXjLMfyGceiVuxOJRHauapYYdrO1EImYZrTD8KJDecWFAYz6CVUMFR9kV6r00Oc8XiTTheL5+mAaJrn7IOkg/qmuzFzrZy2Zi6Z
# DATA Zp5zXNBnNo0SNjSZ72VKEW6ItktxABaZzNMHBrg3azBLYOucYBKs7NTEWqu/K+RA0wNhvbBsgUE3kL82GtYe42jJYlCnRlZ3nIYG
# DATA S5S3YYp11wpYmAdlEQJNP0cvNsyoFcYh6Y5I7kz8URiUJPOHQ2z6M9NVCvtzUVOuWO91eM8rr/jsUJVxHK2ctOchO3DR6DUrnpFb
# DATA VyMAzyARMkCFp4uwZUrCPNdxq9NY2EfJVPZGORes8TgF81hAJH9Z5IXdjJt+soTaH9Nor2+/i0xudCHsh04WAD/Jw9c5odwqNgDE
# DATA ahvCOylRxIxq5jiFr7zYGSjGSkdgDjIbBMLH3GKJaOy0naKMUOsONoW43GmHVfRS+4vOigw+atMgnQN8Us0fZt1U0mqgYuQUQjHm
# DATA EZS1cw45H0STDclXQFpVSnhouH9YirZg1U1/bL8qxtSj1aQzUDM8BASHzkBLtVqdwpnu7ajwvElCpMkF3/M/0ClL1Q7oqBULgB+W
# DATA EEE+hI3PiwHwhQu1P+5zXm64ZVNcgIXW4iQMMTVY8QP5Vzm0x1dnSrELOflXxGZR9RQ+KZl2qhYPnYRLxjZOG/mkGsulwuXWAwna
# DATA qmS2NLywoNptICk1Gjj8RgOItNHgCXACd8ghY8GCwwkBVwAXB/FSqtOEDtnj//b8F2rz/oGc33O8e2a6gmNzir9ggjYQZyiY3IKz
# DATA QXCYndNs1D7ZoLyI9iAK7wJVYO9LyTvtU/4L8nfwn7d2+A9E4vjbnVtb1xFqB58W7aC0TVTNYBaJTu+gO24J0hmmhsiqSQ8j63H8
# DATA ybD9UwIW4azzEJc37nYTaKDyLU9fJXn27yZk7/knBMvBMAk6cqDkInX8kkIeLb5MQQRu/pTnvwREqXOtxl/9r/k/tcv2u3Byqm1U
# DATA GZx+K21AUPyltTX8V/3P/3f50sWL+m98vrKyvLL2V8nydzEBY3CwV83/1f+e/3v55ZdhIynuSKZcCf3DUDvJQ0NKtw5gBg7b3XYz
# DATA A5QjijBdqaxWfrhaWVjYPQYfXrvgz8ZKRE9Gx+qcQDQ5DhBBDNDOEaS1OW53BxiHcgzsA3AK1dv++Oh4AQvpC0Wye227TCCqh+0m
# DATA gBShGRViZE0fOX13cty831a9a4NnOVgtWxXVt/YQw29b6kjdh6MUgLZ6fW2KPrAPCURsfdg+GFPgPwBngURJIIYLAKQ760gK+Ee6
# DATA O2s8x+pQsjudfkccx4nPOfhp9p+w/1+99MqKv/9Xly/+1/7/Lv6XjrM2C9jplYUFtRGyUXKWbA872UnzWreDF276lUwwoAG3dSH9
# DATA mwE+XDrAMmnxCn/70wcjuxiIIw/a+2RiKOoWdq7d2sZEILcw6RQCuf59u7BHSTwy3DlVgQP3nUWzKmC+KeFUcgBz7o/AJ57fZ1V2
# DATA ZM0vAKK+qqYOPTwc9wiZY9geZ3A6Fob9B0VOWSL59foPkr/+a/inwhldnFhpuyH0ek9VaaPHgc/aDwdqgtZH+GkPZKr330+cF69j
# DATA tr3rILIXi8H32YG6FGQVxVePENaixnMqT95/35HJ5/rmQrIio+KiLCFmbuQKzmfR7RTXBLLjaQG/TmqvR6vC30U105OFhSZE1yd6
# DATA xtU18X4H7iIFoq4SptqQtGWyBqC1e2np7/aWyz9slg/rZ5cnZf332qS8pn9cVC8u/7C5X3eeyN8rq5PvL1UgMTpmhoT5h3wU1sRB
# DATA moT+oSRNe4m0XJB3IoXC9Fjm7rXk4moR4EMVZcC6MbbjZg8v7nJO0QGjvmupTdNpQgaVKwKmp+iGaGk6JdnlxQkOblXgMJbQtFWa
# DATA gw4mv8wqAHl1p9f52Vjd+5IHcA5W1fbG8U6SCTe+tJTcbmdj1TYmBUqaeGCX8U4mkFslccyA5pBGT/EQBoiJDkYEqh42u4Db0D/g
# DATA c/QwGXaOjkdZRS+b7rAis5f0/pKnRVlhnHx/KtkJLEFekhwcN3tH7dYVsVaiNKDoZ0T3FTvgmtx6aaiUQqWrlhNqr5kZVAuaM4UI
# DATA pQzTh8nMrR4SbcKalRLZtVWzaeE/lV7/QQGiBlaWk8Xk4qVX1H8vX1rDcw4wg3BrVJO9SqVCG4gDdpy12QURqt9tJUfDphoO3c8O
# DATA +kM18kEfEidAzj4AWRsrsUmtA8IKazC2ilpbECmktj4lG2wC9TQPNCYbAs86iwwyWAfpdERLjWNkMSi2oPL3XMzDmkdaiZzZF6UF
# DATA 0e4ZzPmkhCtxxrNnTd5k4iwzM2t1JFVA4iyc8ZKpM28Iy1ZFxguYJ10IWlrf3rTiVzpNtZg3wexw2O33h8hAiRRa65jMBgCCMaHk
# DATA Ci6m/lB1J4fDv5GcAaBdE9TYVUCAbk8SRVCqYNCSfBw2NCkmk5LlTAlMqKT2dLN71Fcb9vhEjeTtHXCsQBqawmTf7A83iS1F2S0g
# DATA gvZaqHS0OW/wUDbUQbfZOcmu2NjGqlv0FCBC1SqQ8d5UYZo6092H7cADqKsBqK1wAPhSqqqlxWQ9aXUODwk6FRXrCJGpWM49RfGG
# DATA rUKml0yxMdiLQsKVZHEpmTimH+6bIl36Cy3MdJYDLcALPgL4PfLNmn0OWCcg7q9v8lSyGnX2i+H/U3eOzfqF80NdVXs0esfY8+II
# DATA PkWdpyc4nK169BltapuEO3HG+Y7USh1A8bFC6cgw31RrrJZGMWnB+m0Oj+5TLscaQIPL/NC8UO2As6b2jRJDzlyijMxknyRLAOrG
# DATA XNsFknnfqFBV75KK9I0KibtvVLJBF+51lRTgbZM33oBsQa/Xkldhjwe6YSXFDkaQDxHosaBlY0TuaQ4GS6h7pyFmSyJY80flwVFa
# DATA rFBvto+KhbOod6EaRI+gy3aQMKt6ntRBWLFzIJcggVY1WS3NqGeX0H5vdrpKNq4q1tNYBozWTqvb9l5dpFdBfRPgSpQwnkauWi/k
# DATA datYydoAI7rdHDYVSVGwNCWbL8L0phildwA8zW0JOChkD1LUrqSBCIgBNm3fZwq81japCo9xIaF8CeQ6e94ogacDbKbz9yTogIgE
# DATA ogixt8RJOR1uiGKBn01jxPY8GWv8zp2rO9dub27vbt7aauzeemdjq3HnzuZ1tzhk0SaLfSlAU59S3e2NO6rLWKnRhFZAoiiQxKX2
# DATA kQcDT0p7esuBkdanOKWyAXGbKe5aadNU5uGlPvsMHiE6GxjTdYT7P1mYFmhZ+xyzHpqY8SD+Pa4+/s2z36FxLo785qOVVDDwQ+bu
# DATA YWd0Da3dyYo6lqyRMgoYj5UZ8ffRkwy3U4FuO7TD4WjvU/6iM0MCpRg1lOSePLmy8B3ofxpm93+jquDp+p+VVy6t+frfi6uv/pf+
# DATA 57vS/26jHGXWXtxdMYUEqFnVvsUbRaA+cW5Z7Za6gWGeMTYHAae8tCa/QBEkf/ezBQR5Bqeebmdf7EfgTiBFhm35C+yA+m+N9S9P
# DATA Ru2TAdzvqMLxUB1J+xR3JbWC7wYc1gu6akotyyHc5FuFbq3oekwa3MPWPNCCgiRofm9dvXHr2jtFkzoNEARblDetBUG/nC+HkqdZ
# DATA BkiCWka8QQBapvdeFhYLbwwKVXYamzu3N94q2GC9DnqvpCiE3BuxZBTGqlhIN7feXb+xeZ1PFYiBd/FtPJhLgjWShkAsZrTss2Wc
# DATA KnWAt9XTQnEShRNefvXV4qwemZ40bsJpdXWjsX1789313Q0H8xqPJp5Qk2vkFT/XiPacW3A8umnl8b9Oqht8wiQSLezkkLB8B/At
# DATA +izgUnT1B+FCzFgEAcsncq0EfoLcaSFjcrwh+E65+2tnl9zumpLSYwpOYyB3HoH8hkGsLq9dxtx4d+9i3hS7LITi9YetwkER9GEX
# DATA 4RH/VFL6yuqrFINmf1WcZzq217c2bpA0tUCp2NFFxM6qg2Fi3BG4ETTHo37EQ0Imk3BZfHAYvFH62E52mguezcLZ4iJ7KUjsIoY2
# DATA oNuDE684CXauqY7n+gXyXMRnS3Ge9RsyV1vr765v3li/6mxjnreMQi/tVjmb/E57NOIM8rp9fqVzPfu1aQRwZA82FJxuTvKeM4so
# DATA YOJuhHcZdloYS5z2wG+w6MB7YxukEPV72zxpkzcq4NLDroYUwv5MS/9i6THSvfXyT5rlvwe4avNno1KuK/6lCHWSkmLvXJO+tbH7
# DATA 3q3b7+RMviHPJIWQ3urSkqRKNymvAO6PSRS9reSH7dmmJ4MXCOT97Vu30T+XosC116XtYmS1r/+E9AjYD3sfU5glRh1zH+UV1qXO
# DATA U1WFnKqGNcg2VG8qeHOz11tVhvghGOSs2QwUBVLAOVDP4Lfo5uS3oATK75+N25TyBH4cDptHKHzowurI1a0iOi61hi/h8Fe8YflF
# DATA WI47sJdqMhYdz8vUNq3ut3d3t3e45tsb/8edzdsb11Pn1NE626Eh65JUrTj99u1bVzeAjSkxi/QWkhtWXSbWx6Pj/pDvpNUkvaou
# DATA 1IrNICyUf/17b/3djcb69iadNOp6gZ7Q0VJ6JhiK8D2AItQUTIop7sVe+qOyur08aA5b7Rb8hf5eqdpPlWX1fyvplXjJ7WFfcet6
# DATA omcVbkue1hJIHQU0aI/G3tzHFcUb+jr8fY1gi7oQs1zSKd0y0qBC4Dtd0PC7Cv4Xyl0Graq6kYtqiFVrqFzP2lq/dtgGxjFjjhg6
# DATA VrFPHigAWZOrcjXFq68iStBFN7tV6gb9IC0cGrak4Ur/ntiTmH4o+KN5AB0gvQKoXUHIqy0DRsK4dy+r7dXhBbBh6naBhoNv0SIj
# DATA 1e/3W6dqMuHzCzV8zaasK53DAjx9fW0RU1fAf4pnzqRdifRLKlY9m1BfKgPINXh1DArbCsjnBXyuLsMTPc3oV1ZDdzJKaMvF1dsD
# DATA JQdTRcXKqE96LZTmlDBnpoucPN9/XzS1+PulWi3to2UZLXVUqKKX1CutX1ifRafeGuKC3rNuFerFRFDBk7ODrtqDQnxIjzD2yUIB
# DATA ibtQrL2uiVmM3TVaNuTsS81BZ4mM4UvaGF68ogZe4P7LU/HhhBGwaroYGYAGq7gizbIBPGw1z1Rufauqz2rrw2HztNLJ8F+Oa8+K
# DATA b4hhnf+t8L/qW9X5l9yPoJ5irLt2k+ozKLe3XH+DNOJz93gpvYAxiO07tzevSRSBVMbadcVwioWiVlmpdfH1VZYuiZwZLdQzjVP8
# DATA CGDJtHYKSn1JPosEPP0pPY1qpvBwKCWqDEKdQa4FSuBCujDTACIy29iPmCfG032pKfPVVrWVK8Bl0H8JrwyqwH67wCEM5h7AFxg+
# DATA dBRfoRjjkjhYsUiUf4MKLxnchn3DwEfTDsvt9bc2Gps34b+hPEVZyfnqX9ltw8W+OTy9LjEhBYKqgLySkgINKQKHXKYr+GG/qxi0
# DATA g5UusUn0qsgxz6ISg3Aq02EWzEgFilDWaeQ8qNniE+lII+cvlnLUqDGRvcAr4WSMeRHBPUh1gLawSOX5dxG6/vtSNv9pif5UkOs2
# DATA Sf9iaVSQuEzqwjpi/LQPMPMrhLKVGVIa/al794uaMvegyrrgjUFx+C+KSh7aSOByjy2D42IPxQhrJOpCoxZ2WNADMbeV4nydZ9zq
# DATA cpkg+crlgbp94FWnzZB9NgoX9SIfOiJvDvC5WlAksNRMAm+56FyIU7n2Gbe9y610mjv6T9+LPG/LAtWvX7u2sbPTeFPtWBBvKZ0b
# DATA 3tOJ7YCe0OCfYNaFPObDLSqWdZvOWvW94sftFujY72NieZ4T0j5eSbLj5pC8PxJKPaE40KmVLhO4n+WxTsl34AaxYJLqxYGJOFmV
# DATA C0TEXvFK+I5t/rRqjSyN7HtVAAc8WZAsElCX6RSwHMwglBUkdIq6YeOy4rc8bgJDEmCHaEX90TEAbefU4+bS4bt8KcGPTLoOe2Iq
# DATA UBPgnMsl/yWdf1HmykGbwF4wQhdhc5yluFRqMs4mkwWd8x0GVPXyHe6l1kUYLwxni4vCiiXg3r4rc4o7SRKiPwVNw+IiLd8kclm2
# DATA pk58g92KCYviLEWHKdV1IegUxq5+wz+TUhKQTYlpxhyV/r1RPbN7ze8blIxq9hZU56XoIW5C7O6drZ0726Ae0HfNUBMEGVhsyCl5
# DATA S6xff4SBcTFlT8lA/MqnNlmEkVWUZgWOBpKeaaSg1UFNoWx/RMk0BzjASjpaHuiQrWfSh5LVorzcg3gvadkcVvTc6cBLNY//zDnd
# DATA 125tvXlj89puZJrt2cWQtjN1to1A0dFVtELpdan5qnxjzXtzNGoC9wK8hZAyED855dq9xKbWPEglPAXuyORl2M/JtIg1q2PgQFuA
# DATA mvGip77NCnuLpk2Y5GIx2M16CBgXxqUdhxHEciH+UHfyJyHDL+CbkvgAcohgdcHlXpo4KRUOU6bFW9RaQOY7tFdV9i+tseUAv9tL
# DATA KdIBkiR5FgVCBifvQ1Sa8QfEE+o5siL1CdosyQe4t+tBdZxq8Tvz/+fwz288DGi6/Xd1de3VNc/+u7r2X/7/35n9d+e0d6Du3j0w
# DATA FkJwCnnauJ7HlIkc9lDTzldBLngGVBvlKxT4MEvIw5Fl3eUnnO9QjLGHB71RV34AOJ/6Qn7qsOBv1IYMF/4XsRa/s/FjUFDu3Lna
# DATA 2L5zVTH6xvVbN9c3t9KF9Z2dzbe2bm5s7WLkAwoikHRimP5d4Y0quXvsJXdH9QvFN4LP8cVirbL4fcjG3a7cBIveQbeZZcl13I50
# DATA 1JhTR8ONq3khhtjrD0/AGYk5Vq6tjw9f+xpOrJGtfPR18nryysoq+VWyUxbk9ryb3b37gze+d/fh8nL57sOVw7sPXz2sp8zCAiue
# DATA 3fWUBtpg1Tofj54ZgXm0ZY+gJ6ExwgqQzlXKz2lLYFQQMhfAFaWUrK1djJonzj9A+JJGqCupkB6qkHZavWaqz5NipQtJINk07dzO
# DATA nch4/rMA1TnhwYY4LKAVoI/w2J6396ASAJrAtsDq+wpac9OKzpqN41OP4F81sBblKAKXSMg3hulVzV9o8PNyDIGKutsteElk1Y5Z
# DATA fijesBfeh7/UvkkB02g4KvJVYqh7YDliBrUj0EbYwh7b/VRL/Cda/S6tTORN8Y252nsBqudMgWKr2quWV+pCxpQ2SiYSLVdI/fJO
# DATA 1qUrriqwLGvLtCyVVC5X8JuugCYDkTP+JR74evknarCVxj+U6xfUoyX/WXGRph2SQ51/pCzAIZWQUcRyuBGXmgEFjThym51MERu3
# DATA uVkkWaKkFtfQI8AI4Mk8fVa3o/U34cq++3Ya2X7fhBsQ71FAYNnqj94EqBZvq4J3Dc9ENebAqp0c9Fi+Vf+iwvkdjJZX1zjRuf22
# DATA B1hKsBorYXpUU+r8vkOrq9GL2Xzri3ncmqOm7zNkDeFCslK0NxsUL7rDfDHa4vWE+tRm+BtPIoLN0QX9IXmmuNtBfFUqOuAZGOu9
# DATA dIa32nu3hSiv3d5Y351FsSU7vXuMvpoXcugr4paWS2yalL7eKgZqbJQlIYbm4B63WeJnMLbGxo/UcK3fW1cDlehV+LbTO9q85W3R
# DATA nP7d2b6+vrvRuHpn58eOplM+Oe20uy3me7za9tqKVxJidoBLUlZAYpzqmKRJ00o4bxJxECw36UoQsNwUysk0lT/tW7d2GzfXt9bf
# DATA 0qojrS+ckkrYZtcmWXXAs80rh3GbFpwycWy281AMyF+YiTiG60irgQBRVhkXO2vBZo+2ggkqZrAgkTpWktdqyDrwZRF+rVzKE0+8
# DATA ulhAh8M7IrjQAY2OSiulldXL2lHJ9bzCZmMNWo3xePO6zq+x85dfkF4k/fOZWVbJIlYlQSB8YYkFiGs3WTDIcFjXxOSRxi5Svjfs
# DATA rC3+Itu0q6cy/iGgxZEpjEXjvFsbFQ+FwKRiW1Lu9DoxBJ7pc3jt1s3tWzue2jbCWcLbXTSTdjGq7jtn80YcguXcg8kCfR0eY+4U
# DATA mZf0e8E3JWjijOY9iFpecERI4r7NEk8cKhczKHrJ88KU5LEE4rgP9uqxphyvWa4nChLmt7Snf7j1wqQQCgi63wUZpO26IvRcwG/3
# DATA CFm77ql78Z2TzxyfhFYeWlNpoi47Qh44ghBlvlaS0MXVF+MHIgAZ7EbmnjyZTEViKVR9wNs+bTat1sCd28k85DFfWEauifOPummj
# DATA pMHASDTuoueMp9QtOgcYV5LfimDMccE9dZ8DrxK+JdYUN1sp7q3UHedzAZHbq8LlDzwVX1blXk5ftujoZ+M+igZUcNnOe9KSxziQ
# DATA ApYsichK2vVOV38K5ZVAW9VdYFdpiFZcZvVKarMVePdagtfKAtYk10j4YacjTr+XFudmLO7l0J456uZKVbVbjygspBgoo3BS1TmI
# DATA urTvifIJIxrxXW2liJNvzbXtpMVkJaksCrPI0Hi6YA8MOdKeCY+uuru+IY2KIbTENJxrkrAyScvlSDyqgh0c9o8uLJJ502mdjzJT
# DATA X4XskQHk7XSGTXdKyOhsOdXHDLBT+LnlV+KaZsOWDhPQvqICGtqsRt0kZB6ozJ76om48lewUM875Ll/5StSFcx7rTIrSGGkTUa/B
# DATA kvNRG/WBrOOucLqD4kKcLjiBrUMeVmtUnYAj6KQKomAExIn9FHS1oDEteG0ieVSoCuIHwlEFz5H4wn560sky9PdxNtNZioNVIhwP
# DATA Wl1UKHRRPeKeHbcfSgOSJ5HKd1oT2YfG7sBhK4TpUcMQAEbSgpsQ3zXw4mRuC+aOGl6anbtKzu7msAJ9JTOJRQjZrHYORmHzTxpE
# DATA uPetCaQWAp2LLcxhJZa5OmuP+CFek2QJ0ElqgJAnt2UNJjFtC327F5auQ3XUoT2zjvX5Jca317fe2ogxdrOjpHHqM+WY8p6F1OeI
# DATA uyf9FuDKtYz8/8LsdBor1YK+I84u5DnGTGGOLyjVWp2Vr6OENFPSPReT9kXhabw4xo/l7pgjUud3Pf+kzB9LZdAfFFTzfqhQIDVH
# DATA vf3C+vCgEDkkt7zOq+Y7IFElwXfsU4AXxtb4ZJBpl7d2LwNnomZ20OmQ4ruEWa97o9qq5Beew22RG0BmDvO/n6aBg0LsIMU98JJ7
# DATA kyDpRQt6lqjM9j9oLGcZc6mPO2hXNt7HoBysLVh72vVecSAzNSU1bfjjrxemUZLmIy80IO43/KPDcMAll5dG/RN0KrZq4MYFVegT
# DATA +SW6MYeNCm/Td2fnO//GL6XnOVh0iixRKEqic9YPqjtkLGdGGQYGZnJ0jl8rFOE0dzpC9biaO3r29VS6XC+lNwAVcW25/yrAjlBK
# DATA h4w0QjmONSZR1Umz1zkEKYRTWBkPwz2ne9GsVJJxCB+arN+c8woTEtp6kOi55fnxmkxXniRmVVS0Raa5GpkEAjv2tqSPuXZvfIJg
# DATA pwUhGjN1dS/F1ghdoC3FR6hdNw0UzKFbjDcUEVkt8omZAHFlgY6sccc36HlkEavRnPnMaSNOWYU4TTCyN9ceaBQWptduJnP2l7xU
# DATA klbN1VuKEaOZtTfwT4gDDNZQqGMIbuiZkpu5zvMuFaEyWZyrmicreDM//aBHW+64R6r+hfMf7LG5nXtxjHHVYqr6GrDo3Bf+14AE
# DATA d/z/TjpHjO/3jboATvf/u7iycvGSj/+ysrr8X/5/38X/vvfS0jgbLu13eksQNDE4HR33exchSuzWAPLOJ5wZFUJHmz0DlxngkjrQ
# DATA kYDF6XkFsjtdc3iE/nYL2itwcEreeKDJgJ0rnnjymwJ5/x5ug1/bDTCAj4GUBYIkA15+s/0CbS/ChRfOTBWFomm1aUrViWZi/InT
# DATA dZv7iu2FSAjXGADZqNJuYEkn5su22lJF2mpcoYAluRVKnpYKeGWrhWyoTwloQQDL4O3c1VifmrvwjE8lVMJ8GtiSbR00x/dbQ6xB
# DATA 0L8DRnLcHCIeyarGI8EnNiSJegBnoslHJldaGbJ7w823B2j0BjsFjpP9hofj23Zn41Fw28X8xsXgNOci042UrE4Mp8F2i5I79dom
# DATA zAYg9YsmU0zY9HzKrIjd58BSptUstRp3qaazePFga/xvKRZzp43zNVbHYTDVHbUza7AL7RtMUXByJJym2e0oMSkzG80POss4ohID
# DATA L18YLIUe61haCaf4WttZtLCYYQh11eI/StmGJNrB3HUWCzIaRgyhwYuxE2KhvBLXt3YAZMUqEuLhTMNiKc0e2dvsFMtpBQ2U7Dn4
# DATA A31V17d/US1TzjVyWnecop1bzTfhgpwLenLmgZ5MvlvQkzkcCelZwXS95DorM1GVjKs0mATX1i56A64Zv2ucqsvLxXzriU5ZlMMt
# DATA aP0ood2oTymIC/hfi6RAYXZfzQAwane3ljiMezpuTin6HluhnnO4Q80lJHeLxAI+kSg165SgiRxLtTEOccRFLTlz2lOdw+g02tcc
# DATA 7CZhthx8oFp88/atrd3GxtZ1ecYm3vvYT8jfPvF71OMmgz5pGxmIdA0rShDtDy/OBhe8oMOszfP9AhwV0OaVZIZB+QWnn9TM95Lr
# DATA yDIEEy1j36/mwbCfZQlmKNDB3jqEbdRHwPMD9K3EJI1c2U8Bhh9eyScca0sYBOo5BcHst0HwJV/OFuGjN0/2O0fj/jjjuFyOos3Y
# DATA kxm+Eg2lPRkQII8vsLz1rMb0SAHv8csxQ/IXrFj8glXPudcs73/YP6SmPXJi8A9WjjOWQ5VsJqZTkXWLWVl04LHZ8ELLenanbKzD
# DATA OCqB63qtR8E81B8Jc594TGig/ja7TC2XRr7SjQDrAtCs+/nYXVHWrTemM0b2LBU49SzglJnFKmtkkya8/wakAXD87tVuGXdHRgmY
# DATA tQlYUXXTGKkNeh2Z0bgVO5Me4ILOIdhsYqpBR+r8GwTT1lX1H/TQ4IdVVoZcqEouNct1Svh4fDCsdPpL3f4I/KiXTLhwAAfjOLlY
# DATA k0CkDG3NWNlhWwkgHb5HuZ1aok6VV7TnT9UdC2rS9OdaRAg76YQ8h68ns6kPKp///ES3MfPD1zObJZ5J96P2CTioxe6wXgR5IQAf
# DATA EDwCuTfqBzpwngLJoY3QOCxvYCGhBZ5eIGDfzRBUp60WHoreLgPiF7Uq1OZ4PLA3BpXCaOZaV/GfVhMbrsqIpnS/qL3ACSoEgo2V
# DATA 2A0JL1EaqVm4G+qnvyfVo8LeovVRnQxhNYodP2gOIItYoz8eDcbycES4U7WVy8uaafI4aVigCDUTZOUY5Rh/En+dOwU0bdnagIYl
# DATA B1OSDvAWyRiZ8OcY5V8GQslGffqJcCgChoIQLxOwuzB0iuVtSoln0PcLe01pGjHeyQLiaTczAu4vuAmPUsjvNj44TqwbA2SGfP7B
# DATA s8eAk5Q8++r5R88/xHSSkH3y8fOPITlk8uyxpJZMPah5cKG/11OsIjnsNnHEjOD0Iab0ZamDPxboJwRm+hSb/Y9nTwG+iVrxMlKG
# DATA bUGmEHC/6QPsSa/TbmGDFjxU8uwz9f1fMM/lPwOIeVjHtWaPIUYBxEhkHO5oq9k+QfNYyg8QzsrGn3oSq5N5RJNdnSxVD37/OeZA
# DATA /gAzcH4EaFdqZuKJP9WLyEQXvZXV1Ih2WSBGylBI9E+GDKIARZb0Sl+HOz0hInkEhMZwXDb4lkzA07yu/iqxSefZo9RPFioXijDd
# DATA bOEwffYvlApaTcenzx5Ja4UzveUmRSaXzxDhCzr2C0wZ/QiA8UvUq0+Ts2D7TqrwEMY/qSR2PmpJTf9Y/fMYPwZkMMh8+vwj1xnX
# DATA bC7FLAyXQicRYDgFwuhBFYvtmhXEgoSQMp6zViwoBAy9oQYP6zPlmr2DY/fGyLMNq1uA6X2E6WMhxfYfZ6Oj5RC6o0Lb8/1lBk6X
# DATA JO7Z5Y6kB8OgNZwLN4CkWLdnQRcVHZqENsKLQtEx1QXqNXf4/93Jf/snzYG+1kQwdWhIq1Iiw2E0K9r3ZVbhRPWe3qnosRKrEkM0
# DATA pEA3elh13EG6bpwOBHqS6SCIyyG6su6l5UP+Et4V63XBCmHrBcUpNcgayNBYqCzkR2TgbZAXok6HzblOY+ezaqzbbg9qhMwNfxoU
# DATA K3uTGMNDLMsCRNKZXwu5QNWm97yRSNbiMCW78ptiwTPxSmGIFuywYLOi9MRl9YqZkvpR1ZH4fBqfGjyFqVNqIXMpLuQF2bjSEhEM
# DATA Q6Cli0SSInyUy71+GVUDA0xXoJ8BRBjyIcznSo8PwTURzyz2EIEVBrHLN1Z4YtyC55vnuGZ7oTd418nds79VO/UPvDnpkHR3aySh
# DATA yTwCy4KNiY9c1JB5sUK5DuA0ddHwZ0HMO16xYLGrtBTFwx/s1Vb0VeYRADX+s+4U3eOU83W5Ujlv0dUv3R93uiD8GHc/8/U54cBc
# DATA DZ4PCDYbos00TFpqadOruOso7aHmTr+ir3Wiwi5DtjFVf+QWOFlw3LdwIS0eVQw9txDeEnTTYjbFzINiOa2MRwe45IfwpJD+4Mc/
# DATA OPlBa/cHb//g5g92fkK+bVGvr73qZVY0ncM1CxEfEvEIA4csikLFvUbzyC4VNHskYFhBrNE5KSUOtH5VNiFEJdvBnNVEk9pkIfQI
# DATA wc6VdA+KC9McyajfRPriTDbfl2KucL+lX8zvRGvjzJR+as2W24aVPM/efA+aWWNI8JyqQqMCE1xPK1eCvpg3MFTBY7J0iyuXm3RB
# DATA K5d/Nu5g+lw938Is/aAmu17D+EwHIozdQcw0N0e7Jos52xoVd7wOwmgubCkHZLB1onefQMSMT7mVRML0X7uxt0pWygMLF1aE3GCX
# DATA srnfxrdkrUGj6jkv252xIWdDrEy7Ox5aZo5fZA7BuG5Upto860kEHzZmArFEfamxuhCml6s46MORQZGyUoMP88RZGpBqvi7FnORk
# DATA CKGprc70G7XG621cXUkEJCSg5RmicqAryhGEI1oyI+eaLJz1mYKRbGCZmmAeYASdUYM7LSzSohuaolA0LsZW1sbn8+YNLQeq1P2o
# DATA HFhypV7sRjG4RemKvpfsjPqDAcKQHQnUa0aPKsl6ItwBM1V1MtVnTt+Kpht12U0QFVb8ldQMPkQb6/WrlWBtqdNapYWCZastrFL9
# DATA ECElgvO7qCij3KIIXZtroSJzjz5Hlxa4IYVc1lZzWp+Hjp0NVIZAVE3h0nIxHhEdYft6aC/I+J0mvlFe758pNGNnYXzTcbvZxfDo
# DATA 6cfA21jMfgJFxlncX3i+I4UsddwB0IcS30rpyamvsM+rP88+gh7RZFMBQLZ8vhxwZCPBYh3IVWd7zfLt5F+16hLuGay8RPR60CJ8
# DATA CdozUi99xZeYz1B3NlfCxhk6iTRuDNxXW/debJlk7Wtqb/Zk1jHiber6ycqTDrulLkakjVZ8qJW3aN4k/X7mfc2A/z//BSjzElv1
# DATA +Ozz5x8nz/4Ilzp8xGD/0RlADUNhdR4484hu6CNUy/752VegDgTN7Begk/0K9dGf8gB+fa6Vybn6z8G+42dwo9s8hRQZpP345pUW
# DATA zDkWF0V4N0f0mxwZEhvSxJWYQtHBVivh347jS44jvlTBWK/62KVDdv4j1cDeulExnjz/n3hikTs9aeLg7lbQmFbDDFPziDdwZX14
# DATA NAZ2to1vCmJFVGOvNRrq2Gg0itaXYMNrNPmTQqrV6ISjD/qGGpBJdtBnpP1MiStikkKFoMgRpFZsd1ukRqS4KBKf2O4Jv8isRkYs
# DATA Vi0RmAzau8SQjSw21RFEZbgDwE9JuoKmXRSb0ACGGU7Gw66tUosOr4w3c+zllEkolzEuBcLrTgftms7IhRa7mnyD/8BXmbm2wa+K
# DATA Zf1TnFTPXZ7MTN/gtJRs/wOHA2Ah8qpSp7kn3eFLy7zsOiYgRcs9Jd5HXlNLDqel9/kQfkrL5chS+BznTEcgsjZ+GRxcrdevoe8r
# DATA V++7ZwQHp28Bo4PyS7QAKbZ/Lj4b1QbTgAy30QVzVcEgGVHv98yw6tOWlrMb2jzNOW1Er24XpqrpQod/800O/3Y07PhE3yXwl9a1
# DATA ay26oZ6G2iVgP1eL1kDDQqOBFNBoAFNpNNKIbyexm1w3RJ364p326ezEF6Cnb3vwqkPw40mf/Tse5f9/e9/63NZ13ZvP/CuO5foe
# DATA QALAhyg5gYI6FAnLbCSSJSk7LohgQOCQRAwCKA4oiZF4J3aa23aSSaed++nOtJ3ee+d+Vpw4ke3Y+Reo/6h7Pfbz7HNwQFJukiu2
# DATA sYCDffZz7bXXXo/f+oxO75wWF8vMB4bbO4HHJsk63RJZHjkJEOathhP965f/BI1AZWSxhEP+c6gd2q8EghKfc28g8xA2/Sm++zGa
# DATA ylCGEzIBinSlQLz2MWUyAmX03xtJubFnL4B20ViEbQLEK9w2axD/QFZ5gxRPKedQYfHPI0Lqz/vPUvnjPfrK4d+z478WF5aXlxP4
# DATA 70s3F1/Hf/3Xxn9ta5h3TNQRjQmBg7T7ifiv+I44OwUv3+9NIBWXdHJgYTTOFwOWRI2X2RNb7J/gR4q/eEQYZl/8o48Pm8mMjH30
# DATA x3VqLH6telOJ3UqG854p1JUsL3gW53sAWNGbnJIBt2pBPtsx7oVwbyGs/GgIDvQQPQ33rI+kTzt5tJtaz9BwKJJ212JRIxtZcfKN
# DATA 6tJyU+FKd4ZjQFDVMEAYhK49WimtmwGHoPBVE9amOJTSMb2UCUBqZoRhXIPt+r31nd3tD0Mb38lEdqJ6D/vD/UJ4XWK7Wp7J0iPE
# DATA 0/AsjRseA5YcaQePy/Yg2SQqnTwLnCdt7j1of3Vzey2ZkBlqyoSiVWuWdMQkd3nP0hnQuHNqHPBIu9JIJ3v13DOhXknbiAhJYu6a
# DATA NLNFujrZ0HTQ3cRIvRnFyRX4cftRVPbaQwmuAwoC0D5vMW8HHwr2BHmCmmjnhu3fHhBeF9y0zvKMUd8nLjXQ7JsK54YY9P4WIaQM
# DATA rFekYAgEgMqMiwgWNfMW2YRLZhQLxZJe8cNYmjS9u7kJ8JUfIlHv2G5RVIeM2+Xbso1Bhkdou1tGH3PtYj08CMiHlMwSx2i6YO4t
# DATA w1DEfTR60u5IipVJ64gNO4DgWRtBEX3LcS5DdmQ+9/E2DjM8M9pO3yU2WKhR2kMduvmpENZp3bHuepI3sE0B9pJRvbWjEs2aLgUl
# DATA Y8OFxbME/8KXvdEZhk2i140N44pl80gxsMj4h6IdoDAQlBxT6o3bMpzZk8e+XT6AoOGni0ul28tnod8xEWrKy8JXNzd2V9Y36tuA
# DATA 2Vnf2N20DxJFyLPYeK5DB8iFX0wPqRG1/kHMx/AxYbvpBZhP4XgYDNobzmcW9KnvVazIlCZmCSk5S0bForyBzMriWka8RYoRRp+O
# DATA MwTLeMJiwEufJtTQ8Mg4AoNQtbrMWIpcMT5eeCCjygrkthPEkIxLaqjqmmYMp2PX8OhrpJqmmAPo2Zx37lHyPCLXMhUwHvrQ5Lxj
# DATA ZCfGFI/nOR+cDXqYsJMC/MNifnzmBRbUm9ZjkfAbpsyUKU5ssgfHOplDJRuNh1PjicNGZaHxjlKikTbIHnId2+GhpkQrep2saaZS
# DATA xpFIJZpqX00cbQrSAfPsAJBJnDX0VPEaZVwHuMxpexhXZC7UcGDqqJMQhJiXhSXv9qRQzMJKzJsypeDLmWLGmtLMkO89PE6UX1xY
# DATA WCgWs+ETsydo8wNxhPhzJfu8f3PkJi7mBHknZtew5cCm5WrIYbpCIECHsDNXyqAq5qYmS86lPfbJMHNz9+v3VlZJtqQ05zuv+PzL
# DATA ewRKDAU2x2CgLoqpFpACDyUlu5zO7JrjtErOhAQIPhmN8LI8pRNpPaWtkNpDG7B2ak9nDTctKiyKw8hQ1rTGkRD74K4gPTeq0h1R
# DATA +nRke+AVk9K9xgtQ7mtTIArSA/8d1zZlgsZoL7B245mZ1Zb2PDHgEDIy1eWIcFYKrJZpayTMaClRcHizhpcxwzAMR6K0tGg5EHhc
# DATA VKacgrT2idRBTipVsR3qVEwmyvEUUEdaHlWUe1xd9oLyii8nF7mYXPWlxA2FP9DuRJYwb2wUcqkzXY7WuwaGVRrwk2eKRFU5MAZs
# DATA ctbf3nB64Yfn0bJA0n9oWvfUHqCWe10Tj0v/WswXqe7l8flc4y4QkW5yUEcxiYeFvT9TZHyYY2dT5unKtBtH4rYxw00j/y3D8vNu
# DATA JPPRzHj7SN48YE6Nrw4/o7wCdJvwA25f5CqhB6W1jOPC1MuFc+/McbW45LXiQleKvNeJnFeJq7tGZF4OruCOMfv9IsUtUZPHXM6b
# DATA SP5biAclxESS0FcOzH/h6qa1n5n4UbDSNMEdXPOibryqxDFUZU6RK8+uFsKipKZXdlmjWpB8FrkimYq1TYbUkuCqu29Ka1ozlUvu
# DATA c3BGWD6R7lqYfzRLvEBqerB+b3tld31zo7Wz+XB7tR5agbbSeYrDj0YEcaOZulhbXZ4euetlcvsRpNkgWCjLaImnG1Su9ehc0jYL
# DATA 8sMEpb9Ry8G1UyYAt5NK//ZgfefByu7qe0kLIujWuX3Bl5G46YCRHmG0OoQIm3/13QclY+mhjVoCkgVakPdE9ARk64tsG3WgLW2a
# DATA sbCOkhnd6CUzNXqKILSEUhCuUh6hlW61azY9TVl1Ul7GOoeBO5ZqQsZxLFDZdU7dDZC4jYzI9e36WpiOW5rn0uQi4eSZtZ369vvr
# DATA ahe+iQJFHIjzH81eZUKGkpYvOs1jiIMTUxDsj4ePY1Rej04mcWUuIdk0PIFV130bp5lIJ+nTsE7PTH0BE74rEKScVVILIx7InHkM
# DATA 0NwSMjkQAW2JJNJqGoiHcdHUI8mJbKsz7jV4P2FPWbCS3wmyxdwAnCtgLimppOGKGJNcc3LGup7/AJpHX5rm8cB9xbTOWRS58uDu
# DATA +r2Hmw93aEl2V7bv1XfD2XIEGmPXiQIXZCB8gnc5ubZQcKAqQowgrHoiCJUngLYi8SO8+50pH5kTEISFKMDtDU6O95U6Ay3WyEcC
# DATA BkZjDDZo/Y6CFZGI4KNoDDgKMWIKIeIYbkoMsgONkTJbg8cRZttWIjn2gNvOrZX4E1FGWJbAq9BGGNsqYVc0GmMmnyteDWbIBGWr
# DATA CFlVAmpPOiOjFKzaPuTLHBxq2N4tsXzi/o17CxYXesSFoFP8MWboYMswJxor6QLg/aU7nQFOCS2aEKCcXaQpAT97BwcRqmfWt3Tt
# DATA xxAPCmCdQRv7WQk28IQQ4hzQcXtguCtCjtAI4Aq9TMKRIZ39rbUvie09FRXP0ECkNzBNfSAFUut2wVyEz0hH6DB+RA/PmiqZFB10
# DATA MbOHxqupPIwreKp8HlknoBwenc2na01EYmHSu2RcXNo1fyogldIBTNd6nF2NAP1msCv4pFoQ2GDk5CP5qlw+OK8eRch6x/FRbwSI
# DATA tQOCO5IXrS7jTyYsS77TwpxV75mhC/hOjpxYX0njgSfDO4R5tCHcuDUZIrUYpJDTTKA3xQWQRudScDyV7YeNPRXX+qOSv/tT0qcl
# DATA tK+Rn5bxZDh2bJWqL2/MaF9yq3LkbI0Ing4ymuJZWCxm8TqvIMoMU1J3EbILX8C7jijPA7k/DRifH9owO8nMZmZWCaJgemwGr9Kj
# DATA Av1D2VGpV2auZDtkKo8/MUD2IJ+GvFHk7Wv6Jl5C3NOjkGKedIQzXHfNM0pKIsm1zEIBcO9xLvoLA01SKxnbNqcV5FKmNm70AiAE
# DATA BDLDFnC6SplOna5lSHqYJw/X5KUncUlPpCmV0iw8T2yhZBQ8+dUarq/GpSulD/SKr2EthknniBKaZD2+vNOOfOklajibJYwbGinC
# DATA IlYbrpfr8WLPGBJu4iVUrRlOnunAD5haVxfkx+AhIjMf26PnM8fbo+knz1R/klxeJHqUJdWh8GTQftTu9dv7hAETpumjr+Q6ma6m
# DATA pn5h8kTqYMix4+LR/nDYN/3T1ZUkoz4Krq7SOBtVccFrOv7rWKvupv4pq1rt/5NK9mcekFR1i253TxmxRoEsL0nIFcCS4Jy7eEQc
# DATA DwW/Gw56HczKzeUJsusIAC0Thb6rqvCBaPm3y8xbxfbzt2+Hjmf/doQGXv17csMUtbQx1qWBkGxgjcT7GTsTanPAVLzQ+ClDsupJ
# DATA 9sPe9xndsIFFstixxgKVSB2Z6tWVtQ+VjxCfqpYCW0W7a521DoDXwh3CMJjw2pHxSHKz/lBcp/Prqze36mQNsdXW+fTsGozC6rHs
# DATA bUqPKJ46SzIBUApbOHEkkqbdIGIEUHsSuAIbxQrEYY/izeLCggLE6Az7w7GnWtNObJBcVl9VLxhLQ4FvePooF0zqfIpJUSs5m2/U
# DATA eMVNQUtyJUlVKujCPKUNVd9E3FhI0wcaPLm6CtwUjbYTCEUBdMXeRJRjdSAgZYEJMRqBxgczl0pl3zT54I8WA9aGftUYpj5UV9Oo
# DATA 4rlyycJT7Sxs5gBtwc76xj0J34qae6XvM0mR1V2bGMcIlqtuuw9GIhY/wTSIiJK4ThzWElcCqdWdHLUnhl4Blp5rxJhRoAJSSRyC
# DATA Kgz1DJPHw7IkCJ3RUdpa2jIZDpJEhXEtu91ThGpO1RXAXWlVFiNRRfSqRQhsNQDBFL+FUl6lFbCGRKFs6lJuBxcaIgAdN5HKcB8j
# DATA P3+asGxzi7arDLo3yV56wgmt37QqgLaNIzaZV2qxn2ij1dxLqLgaBk/3BrSbMTsvz0niPlm9ubC4sDc4M7OOHw/FpZSSK9FgGzys
# DATA JnXlkSD/Y2vucEOC4p4TFJm+siXM1seuvFQBAMvwiQg61jA1ARGXZ4wcfIMwC3nC7FqR3Lne+WjSmcdy85pASEUH5EBDLJopYhTV
# DATA 6M/gukLDspdQwx9jMLHgXTWZBhgal+ui2a2qUS75lRCZpgTe6VI45wIamAfsGG2dUk4yBtke+S0TmUVQQ9yidOdnRSdLFr9pXWYw
# DATA N1L7WHpDmYzLk707hYO9t7LTWqtv1TfW6hu7kp9JbU4OyOi0DPWUm96IGiz70Y79WepnwCpWd9UZYIhduOGmjlLF5dJLVTW0v3U+
# DATA RiFH2Em7z+BddJwDdKXg3kNx5xQXuDvssSRPyUDMkOmv/qadwSNgCSI4hkxlpFyJ4RogGHl7EBiTiOewVhorPgG9buIN8EA5TTWM
# DATA PETmOsCsQzXN1GqkQAO1hINhODvCskYdyn4tf/npcMypb9qAzDYiHJ27qSG5+dSAF4jtJYf/dr9FHXAjco1uFcmCo74rD0Unj5Kq
# DATA UQXap4T46vDerOr0ffUpUEXVjM3lfaaDcqHEWdG3f87YHwxATbsWrPV/PQJvKonkRuTV7BhzCTpQJwUDXMmPOebA9qbsjgxSlrC+
# DATA mDQ0VBm8oxY7arnAgmodVKwGeX5125MoQYTe7vj8yUy+q/EYudaEMS6x6F4tdnL6+X58PXEUzlgPpa/C6wOGjCcr5JM7B8Wb6dY8
# DATA 1F/MZXjcrj/YFHd31Cqsbm68u779oO6Ab9ibu+q4jtN+t89o+w1HCXrgl4N83uGYrTKBlNG0trKSX6Vtk9NcZkJQuD1SL6P4LQ3h
# DATA 8innzjyMUvpIxvWcTRmd06yhmI5PapSXLKeYmVjFmb6EP3PK1vDGyqqssZbQApiWzn0qFHLxuK0eFFPjarlGDykl+w7Za0GWQMI2
# DATA Kdz4GQxCSSG36Z110HtkEXPyINdHFXudpkG5GmdkyeBKJnAFgaUogE/UcstzQOqLWb3vgX2FoB1ioH5uPg0O1ruXTRYyy1RM2d+u
# DATA fDFDK9Y8OvW4+MUpoomnCaPUyYAu2onYDbrM2OgFHEiUMHh5I6kyR8kj5XwTaHVwbNTpPlf+SIypiq3ZkXszQzJMVN9sRF+YSRfF
# DATA 1wwl0FSvLCKgS+zmdDqVR7/BKauJtF+KMVbl2zY0UhoYh5aIc0rjtteUK5crEr0kApjp858U1Yt2O6xoMuHupde7rMaIA/Ah7CjI
# DATA K6uMqbTQ8rrpGkrZosyo47S1LDGn1grlrXYcs+OoJAgGC8QLT0d8h5kW31Gfg3iCHWkciMUy6GzaSp2c4Z+ciKlNeOTk8ssozrqw
# DATA rmu2zLbFNlcruCPfrpDx34Hpyiy6DdHfoRsKQo5jg0eaTqwjhn+x5gGeUUQYxF/FvR9HwV8Gt2/dunl7Fm/0+sb7hiyknVLBk6MH
# DATA iuh+YRz+0BMGXisYoQHl5o29Svb34l9QwpUsfR3EklQeJBCTlMNmzXLYNJfJcdC0Dy/KmEZ0LfOBrT7c2W3tPLy7s7q9voUhQtv1
# DATA hzt1HhuoQ6hqwTj2Bsqid7lwGLJ7OiEwZjw7xyVZMrtdvKilYvkomd75T9ZMk0O1SMvoz0Xntatk2dgZYkIDaZoXmMyJtnYnWioM
# DATA E70bMF6UMVx0IdGhduzt6/r8UfDr5aKo890yUwLkUuYmicjBnWnIjjQb3IGmA0Fp7wQrDConksaUkYg78kZ9lTfyXz9c1xFO/oxg
# DATA qV2CVMQ5lj3h+iRZjjguo/GkxZyixWwhTsbVErGXLpEqz7VFpMuJCeW2u1XOki8nGVqDV6RpJLpR9m3XFUrOx0OaiPepNlwyD/B6
# DATA MuWy5z1e6rXNDzYE2a7VW3fvb65+v74mZkvwaRA1sVbw/gbDJ35xrDL+zJT697TclCkUk6QLnRROHk3ue56imQnoiInrwszGiunp
# DATA 12byY0NZggdP3rb0uOQORXXTyN/Gx8NFMt6l1e7Le0j3Mh4UWv/yZXHKY436I7JAZe/uHJv4VdhkLm5jmdmak2WTeUUp/96Ek4Ty
# DATA dcaRWEXxoX96B68sRjCMjOWII4gupl+H/T60F5A5vDL3J2+x8Nljrs4SdvW2rQva1q7GEmYd/1duuUkevdevF56GriFH4jxPO52Q
# DATA ZSaFGn1hANeCafag/KkgL245uoBWPNPO88qTZHld+qZldTRd+mazvsxu1bmMsSG3yj2Zsi5DeZwMCEiqvy1rj/1blvmIK1dmIawn
# DATA /+tppq6ZJjzFQGaAoV/C9HMxI4hMw8etOPmCM5PaXYV146IJ715bRjIsI990NsBURmcmAyS6Ohnb+jFH0NeRaykYlFQqFX2Ggwek
# DATA b4OrYyu4zRV19JzhNO3TfCdvJAhloDR85NBZI5eK4ZPTWihhOcLpuBs5wTYYVcGHqDB3VXfGXFPPAX2WGt4GQckRMwuM2J6HSnvQ
# DATA ORqOp7sgrq1v11cBfwE9IOoPtnY/1FGAPRncPoMm3rIpKKlOAiIYgxEiP8KbFQ1IUWznEn1GTT+4nKoID0U6yoM0XyDH9uYPjEqJ
# DATA JI3gbBlp6w97tftS0z7ZcqRufWkD3Xywsp5QtKHVNT/+KOmBe/0J3ZP6EPlbExVUGA1ZXjx5FVEnL1dURqmiPchYIobNTN7CyEsa
# DATA u9OPr7oXmSsnsQPEyv2VoI5W/QfrO7s7YWIrkuqGWU266oXYn6V36R1Yw09SuemvuqIjQsYR88SgPe4c9R5FfLPlutBpNBgOOtEd
# DATA md3dUKe9GZwMMOw/0i32IOdJe8BRBBGYAijtyf4Ytr12UeX20lQyqmMzOggbVefS0STYQnaIv/ME2J4JfOCp5qK4UC7OAp4TctLm
# DATA 5RX+xHJl0uWzh14iMKnW8CNjJvTLnSPxYgHfK2YgWFuJyEQRPjpEX0f9difyglTXjiaTUXVew5RXby5QoJavMCyz3AaVsQa59emQ
# DATA kvbVktlvC07lqR19asTWVcEvSNB8XAavwlFEoYVCTEX1STVoWM4Mqqmio3gPR4hqI8ofhItLb1cWxP8tVp/C0zMM8HA19cR04I2n
# DATA DtQBiVvl8bCf5hzh1jQ8PKSw3Kdhd9zDXL9kYitLHdBwJPWHT8Pj9pMyGI6h0OLCMekgn5R5vOHN8MxtgCImO0dR5yOsYSLmDoYa
# DATA rj5YQ+lSUB3yVPzvQQQ4ANd43fVkwCzMo6lQyMrzVOe1YkVwn0FhXPtLGSyN+UbHleFH7yxUF4vFSgdhBQpFp4T4ieP+RYVCooGu
# DATA 30Imz2G5+oHgbcClxIPFJQqlHE9ao2jcG4IfWLi0EIshpx2uMOMNuVjiGjcVlgKudvTRtq8+lSHaCRcYWpbkOlNst+4aHwdu3/ix
# DATA dPVnAAGVl9pSm5D11HrjqXpD9OJMvQVdgtwvsFjaW46HwBXorrmyRZqy1tpIOipIitkXi5oqJgZomIdl3JTFBOhhdUlIJ6PeIApz
# DATA 8APJVnBi7m2u1e8+vAeFj8XM9eDKNumMagshTqBkBeG3F6rfRl63vHyzKv5nfJw/6Y6QgGUol4/V6BlCZ6aqL6SqOh4qcbIM8ZvV
# DATA efivfkaTUp1nFbDldk3TJbtAk6RrkhRh1oPPzqaxY5KjylKOEvcEV7P/avzGHMZlO8ZWEQWkkCQSB13AdV9ProtneEULa4E+nF0C
# DATA XybVlc1UpmXqQVNV/jmUp93pygR5L7PVml4dVG5z2JkbkkOQmDYWGsMUY1LwKh/y4xjRcGQ22srK+PAEdusW/lKQmG2gK2i1xOq1
# DATA WkXjzYqg71abXymEKjQbaJbggmuNUKnSyxq/mNBF0C89JAyaCd93WImhTS8n40ix5PLJuM+/8EWgDIjaeHiBRKWObeUIiLcUQS+M
# DATA e4CXyDJHWyLzOomjMvAd/Y1qIrHIDdaXp6APbKCZMTPlMpCvKA3ho7Ut1H5Jzw1DsDS9w23PlxCFeYS8S80Ua02RPR96xHKsvWM7
# DATA fyZV9QTrZIMKDY5sJyZKgX+AIIFqn1lIXI/WfCyL/0DpWEMlYWp7GwXASykuPAK6W3VPjkdxwYuMjfWScgM/GkDc+N3kk9EgFuTV
# DATA asedXo+xkVmM72f1MAotnS/a27Ew6dfECqAPk35OHqUY9XtJ9xwTLtW0X9UCpwclW9EFToSotHL7U1RroV51jHd66iXC+bQp5qsC
# DATA flbGOXop1dvPM6gpa4HbOoM6JHKV6u1FFtzlGRntuajD7iwZqjaab9aLXKBXBtvK6JABdOv2BR5evGHNIU3kDb/rdM5Z4G8GYWb2
# DATA Q3J3d/RSbT1bq8amQf2r2xXDCVdpsYyJBGVHiFdVD/2zfA5FQt04BegbGvHs4cpD0Uj5y7r+xMKit2E370bMblYfwFVH9AWrRXbT
# DATA szOiaV2xTvwE+rvy4k3pVjF9nzz9KDplByIMxrJCxryHbfHsAntHH89JxJ+ESSI5CjWd0jrRWGhmN2iIAGnXSoPcpcP3VayWFr/c
# DATA oWo4nrR1kjWbRnIJDZVNchosSoi6omMttBi1WtilVgv2YavFPYI1jnuHgxNEBCzAx3a/srN+b7e+/aAU6O/vPdwyM6TTc/qnQBWU
# DATA As4hcr0lbmKnWs2SdH0h2Xvuwn6fJC7snEJ++jq0or04QbkyfBSNxtFB70mG66eNMWvll1VofLkyOnq6J67CMabydmGK06Ua0aPz
# DATA fwnO//DyJ+efnf/2/Cvx38+Dlx+//EQ8eC6+vnj5P84/C+D5y09EsfOvz39z/sX5ly9/+fLvRVH4/Z+C8y/gl+f48pfnLyrB+f8R
# DATA ZZ6L6l68/ATefn7+G6j/5cdWuQD+Hxp+cf7p+XNR8quXP4fG/04U+fz8y2Bla70snn4t6oKWnt+Bfv305T9CReL5p+LzL8W356IH
# DATA ToefY4dF/ee/O/89vowVVNxbNqlvV1ZX6zs7rXdX1u/zhPy7qOtr0anPxL9fQG25xs2N/gFf/lyUp0YDs7qXv8AZeW93d2unrOel
# DATA FIjiX+Mofiqq/Io//0I8p9c+Fg3+0j97z2H2AnOinOl4+XM5gD+Irx+LUrBE/yomjopBZ79Q3bfm7OXPE3OGESetd8VctR5AUMpd
# DATA sBWtv7+yW8ep+78pi4cDFP3+LXyVy/4VzIB4CJT3HMZLBhYcHHQCHxmDXLi9sCC6/r9ltXLG8ftz0XEx4kSHpS1Sdxw76pDo1+e/
# DATA evlzsbZEg7OQZYDdw0nDyfw99+pXON7PxMfF28H3e3dTO6bTYnr6lbZ1fiU+/A76+VNR7kUJf8XmvwTCfCG/P+dpRAKsBqDajqvz
# DATA 7G4YPWkfj/roCJjoHFIod81iFv+TWhC9EqT6ayAeu2fY2GdiNn+KDX8sCmNdYt341S95ub58+QugdLcCpNE/4Eh+cf47Uc3nOBPt
# DATA k8nQ7OVZOlOWbBC9pzSHFvLD+b+JmmGZngsu8SLBODw7hRfzd0iBsBP/IWNbi4//HJz/VqzJT5C2v8SV+EKU+kqQz4vzX+Mv1PYv
# DATA gZ2Jur7A5ZVUJrjaz0WVogvwq/hNEOUnFTg0vvVn/DfpC1Hi9NW2sSD+bi8v47/iz/l3aWl58bZ8xs/fXly6/a1g4ZuYgBPQYIkm
# DATA v/X/59+1a9dWo/GEQnGjgN18QJjlvKLafEwquuhxsC1tWdJVigINMGi3d4zXQqlUld+pIlKJyWdwDZGfh/EcRuKAUaTf2w/4Mcjo
# DATA sshYVaYlM/XkVH0UnGgEYvocVchCpqyQrqQlyzTUoodxKcCLAeuKhUQ9iON+4TrI1yUEueSwzIN2rw/XH+Z1tVAc6J8BqxEs4yfI
# DATA ViRL2aoLeRoYmGBdL17+HTMt4HjMclisgTMX+e/XUFAcMCT5WKLQC+RZoolPoCpR6gs8IZ+HLjK5IbeKwRcaIY8EPPlgLJDID1Jj
# DATA 1WBI4s7THk1gNMOTCTwkm51CNb5lOI4gjjSp1zvDblYWMWeGPEjKFcI4ku6AmgJbo3ZvXDgaxhOGc9A/lSh5jLl0cS1UHnXkvyTf
# DATA ZLOFeBu8u3qPKMYG73xGlUXWeoiKDcR0vBZZr9ox1uAG1kG8PHHAjQi4Cr+He4O98d5COFXTSXI/yg9AJHzSSTFNnMwBykQgg4FU
# DATA ylKYOMJR7H7x8mdADCCnfYqvCCpJ5hkeGUgCMKpkCPjiwtJycB3/mdrh/0jSHp+wTMGq83CSy86LsZWl9IYC0QtTQhNH9z+AjBY8
# DATA 6N1Vqd62xcUbfYmCeOiyI1j66G9PwMEE3KvBCfUkZsxSiWILJgSgoYoigBYRulhj/AR+kOIp3fD3T0FvXlQLbT2lcBDmA+GTWwvf
# DATA QZvWYAieAvAJvRuiAVomvn17GV1UkFGoZuWoNkUtOzv3ZbxGHHQxYxFiWvZijEkHb5sJ46bfEdsEtC1iIQc/jsZDiWpP4Rlcnnas
# DATA Sli0H3aHUUzx7ea2CaUr4dSRwN4R3/Tms8eSjS7i+0tySi8ZgeD1G2CLQEWOiPtr2AtAW3Qxep7t/HgV9Ss+APOAu9xzVhQsLqTn
# DATA DE0K1m8y7NU2m1zlWl1+nWZYK/sqCdcJEJTpugY3xk/hlDJmVHAD8eQ53iSeJ0T8HJzyG+kFJxQiWSLuEwmA+AB2NUt+4O90RP5Y
# DATA 2oneDGCdZBh+HOwPJ0fB9s4Kbtj66trOyh1xQHGKlGNwssNfj4fdk34PMVMMdjU62e/3OoBomyAC8ZNgYxY9+PgNMzNPTSP5uvhJ
# DATA 0tOoDakuyIoax1VZp+SX2mXX6NwbNaeRzF3574krvT434DgQy/C1kH0+QWHnE6liQr2XT+h5+VPpyQhWT+9E6d2CBuouGduduap0
# DATA IxBkColUNqKuChaDRW5Nhq1YFBx04wI2KJND1Sg51GITUg9KwqgMho8LkjYqJ5NOsQLfRC+OR4UpvAvlvS8CVF99TrPAN2Wf4AdX
# DATA 3n+ES+9XpCV8/vLv8WYvrv12FhzPGajCMEan0wUuw4CUJnvpY/ViYhwvZwQWIYkh4YRFzIdQR6zwcIzCuRF8zv8XTR2KTL/GTsWO
# DATA 7IUcRclehpClNCZigj8WNPwlKhc+DxNd93jV+vxojRcSnrQwZ0DXhRByJHWOxIlTGUXHZIbpPYKEjfCVBZR+V+cjMr0osBbDCEF5
# DATA CGWr8/CzBb0xU57a8/+HOqPP8HD9zBL0QAC05VlTJHTnVLz+e7zcqFlFOdGQZ8UAJUL2yJLPqNfJuFuP9cHGhwMBUkzQj8Wex0ki
# DATA zuCMuT0ZHvc63JY7caoey6TAVoT8zYqhuYGbWatkINZhXXFK3NlIhoJxFiOb9NKDMRPDHjnjdOO47MLo2iPLy2Q4MvElocpBUhy+
# DATA oIt9AmrDEezxGsavkfM5wtAe9J7UwsqkH5dDz2oiXO4wrhx0gfMXzEbCx/sh2mcES4/ax27WJHjG9r/EwIwSB/2T+MgJpIP24tNB
# DATA pyDLiDEMhgUjHnoYK692WnQME6d9CbF+fWMIyN1QYkxdK+bRCjYtLhxHk6Nht8RIAg4Cm5mimgpY8VkyE7VxI4QnyUvh7ZvfXvb8
# DATA DPws+G/BwnDh7bezeOzaxo7Z56rgBeIo/62yGRhXP+Cm6xvrinEEqGqXJgdkC7fFncrBnDJVSRXCKmGPPQ0pJTG0zFeJdcBJPzgs
# DATA hI3uIG7uDcIbOEzDyUGuV9THjMSQBEF5f4p3lKtbND7uTSh4vfAUfml1+sOT7kG/DZbxUY+MxyGG3NO6kTFfFeKEL/TuYWdIr/Fb
# DATA aulSXpUpAKiflHDA7UR0zEluPJ0DMdBIRGCOxqhWyUNGSyD5qdJGsuVH6NUhZhRYHH8Z8xeVv4EqqVDC9inhUOf/AsSh7J9EReK4
# DATA ePkzEuC/RHspnj+/YjvCV3yhEzRYVuqz52QQhCKhgwxmwr3JsTLATW6R4l+RpD87/51oDAw/H2s71k/xwDM2g9U+s7uLBOFYbJdq
# DATA gyDXyo+GvUHhIHz60RmYoR+Bnzt5dJSs6ZfZHSoIq4e5V5nXgM+2IbUhBZUCyXZyCII+JZxNxWBMsn0IsRUjhNJIDDkODWjAyo29
# DATA cvPG9/STigke2Hy6VILEkVjbdPElTWVLm0bz9CPBGdBNOOQQA+pteAP/vRFiNAFSvRyImSYUV7sfa3RI+8zVlSeKy4/zj9rj+X5v
# DATA X6eCnReP5y25MK2QISvKPDGKi1LTN+RK3cAQivCGeO1GmIyksAOxjLwzrrbDGJuoOSZ1dH7tieNqFdyoIUu5AVyMqBurLebtbnlq
# DATA 4hzDF8i8a5hhJtK7nPYI3ObGMtWL2AhYu07R5iFhnUej3TmOyg0i3mZDIV4C2A5XOJ3XOEQruA56Dvwe7omfILP7vcXsuE8kFlBn
# DATA kxHaWqONJTI12jNsJsUD0Yj7G7yivghWVh/Ulbo3RtuxOMxGUUdcECGRPepMnkSdHUxq8rcnQ3ATDEBn0kWXwc6EdDPxUdTvy99J
# DATA fyIEwfaITjEciI4y3NsDGtoTf6ERe3iNHl4zn70Fz956i3to0AclJ+IO879hcV7Swo1QhuHZCTLDxsNBbyJkjTUjoGA7sg1pu/d3
# DATA zDvy3mDlQMgyNY6ZKg9BRIzYUS3ggGNubW/wQRtOC29Z5E1WZziyRfRnF/zxhZAUHw1FuYcP2vFHtQUh3e0N1OzXrglGR3N6I7y2
# DATA B0oiPqhuLy9fYIJw8+SaHjkxxqSIfSUmrd2HMTV2oSbx1uZgtS3k8G57XLteFv8XLNwsLd6qLixUgU9ZQ98WhCXOzR9H3bWo3z7d
# DATA iTq1m7eh1BYo5WO4DNQm4ozF+tfJstmk2Y26d09r2PlYTawzF54IkwsFl+SKK5FoDBQQMkKVnilnKKgADGMAhBBS702OVLTjWEqy
# DATA hstnw4iIMLXS4ivrDS2XUDrVMR6EMn1Z0RYxg+2p4Cv4iIM2cx2MksEUN5Q1LvmjlGk5/LAmM+smS1qc/2SMk+K+BUqrkT9Cw/Hq
# DATA VBNueAO72q52RVqX2xVL39WuoMarbcdCQ59MV9KE1+/o1PI9lqq66c2YHt+ztWmQkNG0cQNtV6QwKGrmW2i7YorQ/oqdAE8SNM2R
# DATA sKhp1n/hYRB5V63ErDBv6tAWH+kk9PnbMhyjAW1MnsIVAiZM3hVTSIb3nS2Jvhl8P4pGaKmUCECBPIrxxg05nQed/gmgXQfgmbE/
# DATA nIRx0Id4fr6QxJVkluxGOOnLWEzellVjMq3dTDGTPCjTGF7RQkGRt7xVFvalWcZOl0gHAU+TBePoVzaRoGsk4Z30Y08+b5ZfwE+J
# DATA IM+MkaDsYv0KffahJHllFjIvfP3yZ3R9fPnP5JiBF0w0zsMFU5zMTgoY8uYWTTaszjSLd8yfoCfNHN7YU5yk/V7KcHQnHJYtxciF
# DATA nJjB+v4jgvzABJ6sIiORTLz8qAfXFYMf6JRzEsMjCvrDw4rj+R6e/5vh2CJmtCouUIZ7IILa6dyTkZsYnXW7oekSw35/6GKzvrFe
# DATA 0g4V4v/Z3A6BrzCQmpFKK913cfHP29Mvxf3t4HHr8KQ97r5CL8Bs/7/FpVu3l2z/v8WFm4sLr/3/viH/v90IbNvtca8PkAkxGFog
# DATA byQj+Tx89wMhxWI2VT6OSqR/7w0o6ShYIsaUYPg0ywXwoDOY9Gfw94uPTiY99QKFnczmAcjfAf1HKrjQYYcCpab4zZHbn987Thz+
# DATA jqPc8q1sr4to8Kj29Pr1YVzhAEFxvt5fba3cR8/zVUPhO9XPbps8Go1zDHzEfkNWzZcfw21bBxK8kDY3jGoQ//0neCheEct6J/Dw
# DATA 0wMhdD0GpKfzT8FHBt3yf/ryl+FUHz4xZy3jOJT5ICSI31EPzZTGJG+h7cbCp7Kxctl6DW9WHrcFg5aTfWt5IQ8kJb05AWX1AHpU
# DATA TIfk9zSyuJAAqjc6v0ul6k9GNt6bruyjXr/vQjHqVrLMabYhjW6ZWsEk7Tip2ukkfWTrp8EUi9bXT1CHDuTwpYqzEWSiLdyXsOSJ
# DATA Y8ZryQOjGpm/zfpxxPmsfX9exr5xtD8cTlqSnRbEtJVYRdaZiOuR2GRCohlC+vcaq1wSqt8yzLWsASSgk0FvUktV0CReRIRVrcrS
# DATA lEftXgntfWH5YeSkQG4/l3vFcXv8EWrW6SUCTyHMiZA1j7uINyemu4wOXj8a7osNLgYN6Haj4WPxUn8YxzB9/d5HkVRUirvYZNwe
# DATA xD049vBi6WoexSxeXu3InACWrpSmIsOFwk3onN6iG2LWpA4R+qNUhVbOdsj00O1RVs7JUR39KGoyQQbNYJHSGu0NUvWGdo2m5hBg
# DATA 2XhWRCXXAs6ZKs7C9n4/MrSMW8N4Ups/icfz+73B/Pg4KB8EiW5YzaSp6BBYqXwCFyBDTWdoK9Ej3thQIaXQFmQPV32pEkuUoi6H
# DATA tJcqmOfaWifqJSReQKFJtir9efgoo1jZKhPnFFaAQnnUlQdkKaDYX9E1DkOIxPSJezh/e3zU6xzVSGaq4JeSlMrMxFHidcLmw+xD
# DATA JA3xUYq1iR/lJ4AxtM90Qto9eCwKYQuFUHyxzQziQeIE5wrto54dmms018jnJOBMM+mPhz9U0JUvhuOAUnmcxJBXmqbcslBktMv9
# DATA zKjRU5+Pt/2HT6Rix6evOaj3N+wjJXjaHSk9G1Ftf6CQ2vOveA6lLURNLz8oizmyigiidAuJR/ZKyMpYQ6JKTRkWBwo6XFs6Sn+K
# DATA wyLRUj0Ex003PpfmQjl+JAfS7cXt8XEL+C94UDCpItHZZ2DRdwgy6LPYjAFq2jxHnxf9k1n/iuAxsn6ZSgxkC9C5gQpDCsGVYCUA
# DATA OU5wMIkzOgbcUvTjBVVFP+ixA77BMrouaGxn2O8zTlG5jKcx9o14e7ks2A/RXA2RFTWjE7/hCQOJOUaCek5rK53OybjdQdvFImjL
# DATA aOPobNSSUzWL3uQTcqcZL8BCGG9M2z8J2cbQaGJnxb3vWMzX46NowHDtHDzW7vUNzaW/M3bvTZNqBpfIuYvTSF5vW3QLZy/kn4jN
# DATA +wKiSD+1afv8szsB+SehT/Pn0gKbKsIgP+Af5MOvoQowk4JTNHpAWnCuamcUivZ8mUcSQ3DhHgCgN2XTeeVQZzkBvbzvMi2FcIcQ
# DATA F+ya6tF2HYCi1+rbuTC0uBoaUlzhr43FalNBOsln1cUmqF0Bpz5skh7R/N1kmbJWZpkULMbVLDQds/k00Vc7vT0//xU6uAMVJS3j
# DATA XygtfzHhxhfOi2V3BHTwIaj0h52PEvcycIRHJJAB3yDFt83W6nZ9ZTd4Rl+21z7Ylp83Nt/dvH9/8wNLUiH8eyE2jk9GgCgjYT4O
# DATA xnB7cRxbEW3ewRBZ39g1IUSyIUWSsCISSF+/0Vq/t+Eqbb8fne4PhXi0LntaKGYjm8zUKz/QiTErbPiefi2FZTLmDBRg4rYpHhbg
# DATA PyV+AvgkrfoPMjTTCVlQ43pd3sKQmMwMzJVQCTEo4Ij/YTjrnXT+9zWCCrz8GUbcEK/0a6NC2+xhbifD8DGbPSMDM8ZvcjBbVUYH
# DATA 03aBwbz/iGq1n6fq0DwDlBJF+MdmY6BUL+X2IbgiviITQKb+f3Hh1u3lm67+/+2F1/H/38jfm2+oizdkoB6dTo6Gg5tz165du8+p
# DATA uyGXDlGJdFKrwD7hVN+UxhtzBCCqGmQGGA9PDo9QIlRSc27DwFE7BoOA+nrc7pClAPBTUI8BRw79CHpfADjZhpjgePKeYI39q4AX
# DATA ECKk+gyuVhNqNt34ADzDsjZgYyfjvmirMqbeyTa5syX4GQ6OOdUB4j1GK9rhASF+vb8wavgcZadGgzrb61vo6i8kOSPLwNzq/XW4
# DATA MeGaY252UrlICSOcW93c2BWCWH0bIKt2tzfvY3FbDAFl6njYD+d26tvvr6/W7TsYY70hxSg14tzDjfXd1vbm5q6WbXzOYnNbD7ch
# DATA CQak8kyps/xoUbS8u3KvvoMhUqjF4Pwo3eHjASpyMFKK0jQymivljQg5OeYpvwDOHL2BWErGfu0dyF86gpwH4oXi3IOVH7Tub95r
# DATA 3f1wF5s0wuaV2paSMI2Hh2KuY84vM5YrLQgKoAgRD74URI90eIzYFVsQPhkfBftgYhP7SMzDiMrEJc6PIeVSKUbHeE1uPw6YDGUk
# DATA OOwxur8RxdVAqdnqQc5EfMDKKLpy2ykqrEyk6OEC20cBT/OKz7PaxEjIx9oZduEQ7cks1rITUv+gC6UpbIz6DiMZCM0LDVnsYU50
# DATA WhzOQkWrTnDscMWMuknNzUOkm2R+nHvb9Z0dW+x2BkxZRuS6okpBjsvJWjkYgloMI0DhPwXP/VtWY82wthqw5AMA4hvDybtADk40
# DATA mVHB0xBnCf1zKDcF/ovq1Ki7AlDZokdwo0ZKAkByxBpnKJfYQGQX++RRb4i6ONlAg2tvKvQCeEkwC7GlIkzkAjxIEGostSGAv0de
# DATA TYJgwXyofaFg4z0W8mWskApoTStgQH5SwJYggtZ6KjtVTI6+YYyi2ZAFwfXpuP2ksFDCpSi7Y9Ez0ywmqqwQZ6G+1HhG7ddqolZO
# DATA BQ/bGNcQnNIgRGHvycJCee/J4sHek7cPxIfvHDQ56RiWLYo76NJCc84eBC8M9LvgeXojaDwN23odsSZAoycmQgXFd/z3rFlslJeW
# DATA q24bnMcPBi2aERXN+XLfYVZAfsfn00q1uNyN/LuqDsNJ8gLbMR7LJTS1/mSp3v0yfYM6PM/YqPYNQ90pTA8r6U1VTO+jf6cj2Yrn
# DATA DhU7+0lpL0b9iKOt9ISNjhBtnL0/uUjIEwynPKW4Vh2xWW+Sqyas3ADaD77hmSyeD1kxNNFc7OZeRR2B3H5wSHOV1qZ0/fcA8pSY
# DATA uuDc+m28rcvHNG8NnLdq05voUE8BuqMUeLvHJ8cFVWkDK2xm1i2YQ2Eqjygmk3Wic4bqRC1YqHpdPty14lxafTQpguVF+cx1e/Go
# DATA 3z4N2hhR14YUB8G1hYDBBq5VXP+DbJI1vAITyWCFqGqQsj48EgQqD5J1mCvIfIRkfSNYlD+siqkHvtOPBgWaV18iDCTdnQkmprDK
# DATA cuo3Jn+8YGMTbmKkaNwh/ra4sOB5hwiAOncdy8ybrbhdio1j0dgy+jFlsZDMsupnoU6lUb89iiFTCK6WeMmiyoLRzoEgh/iIGiJ5
# DATA 6DEQobcneHwVEyOAiPBj6Mi2pC6jXfnIPO6TR8qZYOedviAFSx4ynCylslgQCzF+ifDRHx4y02dPBz5zIesoJPvx5LSUXAUzRySz
# DATA KuaNrlwfoOO9QvAS1elacqQzmy2BGcuAZtYWFX5/0PWrVz/Y3ty4/6HUqVrK1voPVu9nKlsTCAVKFAM+mcwzWXUZqyoPQbnQebgl
# DATA WNFn7lLpxasQXJEMu1SPrRSd5Perf6HgcQ/ggCxjpaBNQ0UQM9LpQxLgg67rB2VwKa1aPehyXH+SLltI3QW6APHdCuI8JjoIlC9H
# DATA JO0UwgbICJSZbjI+wBM8fOvD8lvH5be6u2+9V33rQfWtnb8JybWvcnhMZzyKEU30SqB7CCSdgm/UFHlJhCqiNjyZHJS/DdGoMPK4
# DATA FrKbh5RBuE/S8yg5LEZjYkqLjP1pE00uqlzZ2qpvrLmkmOpgpaYbNKrU06rrAJ8y/yEjOZNtSMJzK+U0pKNSnh30YzFvzeIGDmGS
# DATA gLgHV6ZsCjOYGGVuk+hWCVYmt0XqFOPkpHJCZoDf7EzxBoGfLD7L/Cp7akxxlmZIKk2M0aG7m7b4XBFnt+7hoFF5uLHyvpiGlbv3
# DATA 62EqC5Z9SS7NNNPX9pq5CyTd6+8bCA2fz9FwLGFFMOjJXuVjwQMYAgn9BgEzg8p5/AYdJ5TKTmt9Z7t+ryArkVgbqVEsOWZR3wBO
# DATA Bp02XTTM+hnqw1Js2UY56n0cRR9JgSbxftl+3xkiqKdqsh64bRTs0h4aTTXgZI+YgoHxRYXhIMdt1gT9Ef8FY/IEnd4K+8izG0t0
# DATA YVElGlUoNhZSW5eLgABMhcD1m+th8LB0Vp/Rm2jQ5ZsMTDLkay2MwzL8AaMGRIOgeZ2x3YPv1z/En0LyPNfzvB8d9gaDlIru1u+t
# DATA b+SuCtALqE9w5COgh64dlG/4I3laCLngu/pX+cyhV56osLFdX1tZ3a2vBUYfmngGixINrhewnYqsvhDXH8GjYo1pZe15/lUCQiXv
# DATA sZZBi26vDUoHIq/fsyoA1PXJzF5cC57KFin3ZUlxRs5sKr96MtaxmEPJ/AyeKh/JSz9olaEpTEEof6wc9of7hfC6VGo0qreXQV+E
# DATA hVQpb8uxkFASb99c0tBh1CSIn9x4hjYBQVxsVQK+k2B1hpkV36ErjyHG47Hu4XfGfIMbCZk1sIqG8XqzWLzyi/KBlZvekMZ7UdaU
# DATA eA8kX8rhCx1Plzmi0k6d1PMq4xhifI5Jb3ASzXkCXYwk0On8Pyf7NG9HhJaKtFkB5gz3IsHtfrgXXy+8U42egHFsL75RfKfAkDCt
# DATA poEe07xeFAVrULhyvfgXdt5nMNZUHhSrfp2P5qzEfZ4BnTwWpP4M+cozlvKe6cDIZ4Cx9M5H0ekzODJBSQYxy8/idn/yrBsjdAAM
# DATA prHYxJbXU2ZZbjEqvNQ0PN4wyfXetb0wLHpfFR0HhQjWUAz+shYsV1MDlByeSu+4eyohSCY2DFWDKCJD0GYUnlL/Ef0JP8FPzN09
# DATA fIHYAB5ATtfPEDOy1of89oz0Qjd6Yy/SeQP/KJ96aqtkHEJNGYPCx7hU4Rfe6R0XC+2TyZHY4j9GVaIglEa11iTi2hcEEI2fiYXs
# DATA dYpAY3s7gEkzDvcWjbrNQ9VtIeQ2RGWNa4JnvbO3bxGneL5TX92u7z7bWtnZ+WBze+0ZZk15xsdm6x1xbj4TBdbqG7vrK/efrWyt
# DATA 07OVh7vvbW6v/80KZBcqupVyY2owxcYP98Z7g+aNMJxtANOFisZevLfTvP6OaHWaKPPsL4phKVU4yOrG3n50+lfGIE0IqLTv+6FN
# DATA A1n1FwCWR7ze5H9FHTcq5eb16vw8TF08/71q80aVPjVvfC8xh9/L7v2Txf29RmOh/E7zeiMoz4v/fq/836W1KPGehPTqHLXH7Q4E
# DATA WCMwj/om9hOWBAWp+RDiIyYhyG2CSem3cTPdXArIx9H64Y1asLj0dpbIqgS6Nb4uBpz6Mqao73Y8IST3SrB7FCmFraW6I00leI4Q
# DATA Vju6VVQAho/lQVtLLW9+4iosP1IC3AnphuENgByRnYVH8vMZX277gNg7aSlHlBb7qRS0BX6bjODB8ckEvI+D+/gKYtCXoJ8DwY4m
# DATA 2GHwniAnAfG1PSHg+WDSPjRM76Nh3OOrso72JJFnu/5gY2UVMjdt17c2d9Z3N7c/pPS6k8lxezCvUG/Kqruu/SwVG03Q+bzzHWhT
# DATA dSefUXy7fr++slNX0Z7SrMdOKwWteAplPiNx0lUOhVRysg8utfPY4vxT3fDZvPQMmqe1eEe5dbTQdaP21PXSPzOc4AmnLK49DVc6
# DATA cA6BWgQcOCAgBfBRHw263PwNlGhLkABd1FteZQNhFQTycgeehZ4Y3fChoMLyyiGnl9ZLYN4jwjN603D8ZO+dgnLyMFJmgBA2juLR
# DATA cBBHiRsoPyeZaOnWbfYkgSumWms4/kRxsIrrEhdaQJx5G80EKjaJyjiGVYpaQL28CMWIrYBjxGoY1aN9iEotTckFp1VRgo9+9hVx
# DATA yPzRXlfwdPkf4JPtQydac2y32R23D8DW0ouxPsxQmSg0Eie6zPBslbzIwDmvA4wFvNCtsC9+xgxJliTxppqyEqZA5J8Va1LEkYv/
# DATA Ft8R02PWPGUQ79e3d4TUoJRvY7x3T04E6y4ct0eAqMr1SdBzSIilUZIGpwV4Ceh0cfnt5W/fvL38Nlky4Kk4ibDKi/SF5466dCMo
# DATA LJSKYh8UloMy7g6qV4fNWu401UyLjf/a5fXpRk34OAVQmDV+HCCM2xmwc29ZuxhxpSWqbq5p2NmFfH5MVSz/G7vXQuT3E03+zWu2
# DATA xROOdfC0sifFTJQKSmnk5w8frq/xqyhe4MecO+uvH9Z3dtP7FYtHI9MNpSUj5o/FqSO/ca5YBQVcneL9xg4QHiewOQN3W3y3TWRi
# DATA zFm6p/wK8YcbOyvv1ltbK7vvhVaP8tk1ZeGEVTPp1afnTFGSniwDmpWeofbYRcPS5dMBsQwiUVWVUE3lWjKNhtTnxkLTUfpRsCia
# DATA 5cws2+qNIvH1la2tFl2lUKz2YXyBp3MtoJEwfJapT1KKGmtsRggF6CFslesPdas1uEIcAMLn09vLZ1LTwBqG5JCkIgBhcikPkAEg
# DATA y2yESoPe9eZSJhE9WN/ZWd+4JyeAT2XQUgDm63G7UxlEj7k6Bf9bCtjrtiTdryvxUVtIHiiNdXuHIPoVPb5j6XRfEuI7KV2r1PyZ
# DATA g+ItKwKaKpgbt5jIY8ArZEh9sYkgyC7GChm8IQEHwT0QQ7X1yoHzCqKOsSO74CSMCVgIHw37J8cROAI3LBdB5R3ZwNdJFYWfIHkT
# DATA 1dg78CpXCsYWwJLMnCmPEzyQMhKCJqLrV8IBG1hM3tqVAiXpxi07Kw/yalgUUslSs9g0ND1qG4rVOx3BxSvc7w1MiEcChGNmU9SA
# DATA j9Vkk+xe3YI4AfE7sKqzOZ/3gullAEdFQ3ak6YvetOidm2o92Hy4sQsNv3t/fXXXkwyNq3cMd7h6Uu8lW/VRun20SERgowE5Jah3
# DATA N72kVX6KtDzkKS/CDmKfvirJpeDTji6CYlV6XYQjYCfLKppzZ837xEvHebdlJUGImlj+epYEfAXA3ajb4oPUyCUv7dHFVFQLDtgu
# DATA TMF8BSWBuOIDYUPK36BA/AX1BtKtU6JbuFi4DiBFEvA27oFiwsS4VQEwHPwSlO+i6d0YGkVX+MaFjiAUEYsvmbMDP6GOI9EpAO+A
# DATA poeDMnsm7A34GcLS2nC8+bEufKSrIy/mAw7YKHHwubu0idSRGlsgCZVRIvwIQwTJfl1haITl8mD4WHzg3sxc05hmKrUGeSlAgBQh
# DATA wYJOfnLKAqMhuRgaIADABcyzPnCsU5X3VPBCPNTuSLqDmM52N5gAdgwdq1FbHNk43UoHlCpiqsQD6QdnRhoCS9SUsumlBEyJrUlt
# DATA eRiVjsvQ0qMJ9popmMlnPOPiHIhMuTFLXOOO3VwKvluzBaBasLzwndsKs/xI2xRYN0o4xntjhNhBfRC454fN4h+R3CRTNiRlJOWj
# DATA iRqpqorJbrV6Yse2WqIL/QOyLZsRy+JhJZ3sVBF9xdFvmPcc1RyKXNhW0hHeuEeYdbrnnlFZ+1HE/U6oJqxpyaqP33XiE3TIOulL
# DATA u8k+o0G75vbatbhzWnbH270nQ7sYehaEAPDSpggnNvwHym5OpQRrlb3xw09YhLexudta3xAX8fvgDaablmoiqrkR8ncPTEeihJ4W
# DATA cOhigpFqSnADMO/D0+PFFO4cONP7Mk7JCyZOLFFOwgcgM0bsCjydpH0gkMsi9bduyJaYkjADlDip3xhxMFCKIi5Ul72lZUg/AsXz
# DATA uW751R3upKbutkIITeH4cGncMBf/5PNUvOoFcDqWvQpMx5Ybotqkhi+ipmv0ZUludQ3k6UTOVvqYOMKotmj5XUNCHHIsgCocRybX
# DATA yQP+ACwu39pA1Q0hrmNIl3+FeJVEnXYcEIY5ijk7ifACJgMe6YJnxB8FZf2uGUiwAIrHt5cWUuJU4B2Oe8MWazJ+kn0xaoJCd+vb
# DATA 2w+3di3OpLqMIxO1EOy4kKCqqh+AFG4mFjAJTwzFTGrAw1X3DrSHHYJqJnQAxqcHSPq7pgKmLOPiiINTaM3PjOMqGV7NTLRz1B4k
# DATA uSfqjJEAENmDTAigMG53CBPHy2Hkj6gzNRhnWjBXlly3tQYOAncf7nyY8P889QVSkfdwcpgVQLw8EuJb78eRuQNp3EXfYvhqWcN/
# DATA 0lw60wdiuDqTTyf5KJubvkXOhrQcxJkVLalDbtaTTYeqquBieb+QKEvGlUPI7IfjdjfKcbanc3hkOF5OJYaGSghz/mmgQqIYPm51
# DATA ezHilllQS4mBQAih7CeyC2iQSOu4PRDVdcnmhcQ6dRxbK/fqrQfr97bRxQSHs75t8YTUPQBfU3YA/fRK6Z+9yXOfnNM3j6EO9MVw
# DATA p8TnJM/eWsbZ631Zs0w8uNXXdK+umUUOh0HI9qcP7AIHll2Bc2p9N+PUmmn9858YypHNlb/ooICAOgqz1+tQNVmPsbhVLWxrfZ2e
# DATA FTMW0ZgTV+9m70lPxLaTXyOVYlNUKYTFmIlUyDq1MsK8ARigAWBoQnMcWlK2Xwsp3lMghlq1RRWqHxh96UH7CSjBgAaggKuew5fu
# DATA gvIHlXKp7TFIHZwqWuwrsXQKmbKiMbcPD3rdUDJa8QhEB3WeWNoly9HDR2yFC2JVWYQ3RTAT18Xt3ZaKIGJ5qZYMdZrzu3uqkyWn
# DATA qO4pOA7LfPMpN5/evH22xwV9UV0zkHDKFrcG7ASayGAoAKi1hQVYZEtWuKCAcOU3wplY84UPMedQLlanXDCTx1ieuyMZ/RMgBqAf
# DATA YaaXJoJaj8E90FFLyZi2Qk4qLboVtjrjiKOfUCKZziwpOg+RUHTAn7FfILcNuyHm2xBJ6rb7BSzFzwIa6hrUZFQn8b3oEUhSIwxx
# DATA 08i9WzOnT59cCu7bWEJD1Cj6r31XLLqq2dfyq5wD3ZemTw65Eon3UpLvld8jLiW++Q4PJYZdhieTY5QnwlWljSfA1sbq/XU9tmT6
# DATA VTpxpaoScW3AJzRsZqwm+kNwxbSWafXinjSVC+pz038SOrLRdUr64pcJTsGhACao2xvUjDfX6u9vPLx/H38BuUDuP8o3pb76RIi3
# DATA FxcW/DJ4xrZe3Xywdb++iye/vbXz0YOGlpHyhM6UPmMc1cUknN6ByQT95MQB8gQTMH2KZLi8+CxFkAsJVrjfN7fqvN+9AgdzJgPU
# DATA o+nBA8qxxyxry0lCn5mpVvdj/3guWikgI6gbvL3gJq7BfAAt0m7yOEldb++fJPB6QufO4pRdiT01bUxqWJti7O3FjI5uX1agC029
# DATA k24VjYxJCM7jVbpBi0mCA3yerhCDAroVaICeftQWPQQ4s/3x8HEMyYlZawHQM0ABk6h/WvFzyzR1SOqFP/3HXFaWdMHNIg+PJUZM
# DATA l7H01Uw3EmsXMWw9e6fk0CKDNl9um5pBqMXsNnHIaEW0T6dkHqeT8ZgjD+EdbRacMUS0mFatV5d8/TrnvAzbj8Tg0c2hql5i13J2
# DATA rlFd0m43XDB5kVW4ZqKQC8JmyFg0KWem2a8j7z2QbMoNlSMD8/0EtZGdGRM5tlqF3mAQ+YJy8TnGiTLcAblKS0dr14bLOKAIWF5K
# DATA gpBbgDkuSA5M6A2P3OIV3V2Ebd1PB2dbtFZATCmYGxIujN837hYztWJegV3mIYOGhai1vpmiZbLnL/N0s6bZojpPp5K3G17LJ+gz
# DATA gHWVgustf4CrbmrmHnP79/F+aR1oSksvfR2Sd2/6pYWu/CXjJq5jKdDRpJR6Nb+41jlF7TKNvfoN2dN0uZaG4lL6zAta2rM6mNq5
# DATA aeiCFxqAcmyiVQd3HrnaLsPO1xS4T2zUP6hvOw29GWwOIoWpi4LGj4ZioO0+8OP45OCg1+mhYxfE9ckYRQjRAq0DzEpbXOCOejGC
# DATA 2iRC0U2gLpPjMbqCwqOUMAvV/DyMid2C6WqAC5SBclmslvEJ195MDQG/PLJXNsJXzjtDSr0ZSnfl+UoXJp8iXbq+am2768/KrMc/
# DATA pgsp4lMlkW9G/Z6m6k6o5P0OMKVUNfxUnf03o5o3tfJ/LCr4XDLuVSrkpzgvQcC5VWgmNXwmAV+V8t3Qu19E4+7qrdNO9Ev7neXC
# DATA Js/QWfcGB0OfZp7DSrPgwnUkEiEA5a4jPppRzw2/myYEn3Z9CskVr0Rxjr1g7fl0Er5ixXnLb6M31JpEZYfVnOo41DRpFTtPWdQl
# DATA 5stqdeyNfSqhGxiQfs2Yaf/5TVFqbtZoA0Rgc3OX43EsLqpLsCD2V5t3rXPSxCHAIObW+sa7m613xQbn+oCyi6nxJJ4K6hu72x+a
# DATA NSBhOw5czjLRmQ6LpHM4zM10/7f3p52DwSA+PXIzV8T5v+vEPZTb59OXP8e8XB/DV8uDIeVeJFMC1jJgJnIpnkm5LQQA6F9ZhqU7
# DATA unJVeRMjCmsQVZgn5GeqxhppmdXV+Nl31n4nTVWtQQa0KRHpJ6U0eqZ3NUxAg3iB2iB+JCTlDk2v+ysH8xwpWg+uvS8T0+hleqo+
# DATA nlU5sc1TWeGZCvEQr/Bv/g18tje4pkIA0vvhyyptHEyJAQXf1Vchb7vFmVx95MaEC9J2fWXtw3CWrsx0LbvA9cxysGcqUIujWeUb
# DATA Nb16F3R0MkEaPK0jm0pE2YBQoH6ZdjO6cPNvBndJqwztUYpdxMU/bp/CdQszLrWDQQS48SPKEqPzLFXmpmpnFT3zhNb8dCVVNLKU
# DATA JAMl7GJ16WzwFXHnf9HM2MqxBlnlqpCrE/LMfXb+5ctfBHSSyl5TOph8fFffYPbbQrIqGUeXYcWUAI9+bmwaB78ptpxKz+52hS3k
# DATA X/aZCJqxOVoP1ncerOyuvhdeZpU5sRIs8r+d/yqZLfV3mCkV0un9A6UQDKcs6tTrWh6T5zRRzzG7Zgt5/qpTdT7UrifbSdLpJzsV
# DATA UXFq9W72HCf/g5FGx3XYnJ5OJ9u/wG8ZsBONQEicmaPI2+uzFHH5AoadTG3UKzWCv4koaXz1IAwZCCIMUMPeDfZPKcZ0NOwNJpVg
# DATA S0wCBBIHW6homR9EE7hke2plZQNEpw5LeL8RbQSd4QjymilFZ7fXPhwM40mvAyrMyZDOl45Mi34hk32KPb5lQtjnV4Ma22Gq6evC
# DATA vChB/uTbzC0TDoc+lHKF16fwtK9SGZtMWjZ3lfScoGVUXNOiYAD+zoc7u/UHra2V1e9DxhTp2SQuglsPd8OskXrzphp7YBVPni17
# DATA Gwy6RACOkf7tW1kt4fxPy9hqHFMyYSvfer0Kqwup93ji3IA3JxH6xfxDcklQcJ2SivfjXiwm4dAG/0molFJLqxwwg96THcRfLJg5
# DATA Liu7R5QS8fBB78n6oGQlwKzgS8ir6FWZHgCBAVoTfDU2lTOgDQRrD+8418VFnAYDigYvBe1ul/d7fDISvcJIEPVi0fMOoLfw7bRw
# DATA K2GT9NSt4KNE3wsYc899oSnh/KEFf1rRopl3gNjhsahTVMOqzoR51dqEhEgw6p/KWDKxBUqIIea8tT/sntq4GlhI3Tg99oho0G1J
# DATA XMEClEorRGCKhXCVIDTLAIghM2JKQEWPktJTgQWxWEKIRURbCPM2fT8aHE6kxA3GLBi362+Kr+u3Y9/oH6NhmkQMrMOa8iNcvDT6
# DATA MwPjs4nKhAPQ4hnhNuRBnveZohFWAETT9jhqMVoA9oZHy/gIJigxQSSI/9xFQGK8+WALxXTLLp57SHnLCzdBwJLmrfDdze2762tr
# DATA 9Y3wLIeKV94uZDZS8NG8V98lb1v8hdTMkC+W5Igw2x6uO7YEmGY0b+wL5w+RzdE+pSOIQfAphPOg5KbQ/vlUP9us3igtNlRNVlin
# DATA zubV9vQwSu2oRGdM6Q+92ZTwTvPZuOCEnwi3w6VXF0GWPqfYPKKf06eFi08jERxH887eGwolv2TrljsyRcFeiPY9kcc5e7a1uXPZ
# DATA rvWRIysKM5hQCxI4Jjl3o5lJYlwfYUurME+Lt+2O24P4IBqX63C4Uawgq9/4bUEZlV4smGNvolVzC8F34dZS0GVQZWmD5F4ZMTPO
# DATA p4GASKuH5w7Cfjp9KWa6YxgiLNQsEeFwfiaMF/oGuEAg3gnGxTMu2Xb0qIfqhbNvesv6CBN7eknixM033+5QPOWfJ1Uu3br9Z0SU
# DATA sGIeDAcdGvYqaFNzao7/hw41ZF+aJEZbsULyke5XMz/ZL13obEglchILX5P3nwJ522rcb4iwTZpO2Gaugo7TZWrrcrBsXQ7AdPfu
# DATA 5sONNfdy8ErVolaHvkMePEoBBNvJ9C0lfc+yOKey1Eh6TBfQJbnraMxFd9gS8iDAw1l3TPN34An+AqRWkY45tExJr3kopRABjVcU
# DATA VB+SsPHcjwXovOyzdrq/49fC9LBlxhTc2Vz9ft2kcrM+y2MUPW5M5dNEKqDIRack1TCEuY6Fqt5qJdD1bdMxgRVV+E/rYIjJgjDB
# DATA ag/84Tm5JtBRqwVSTKsVyqzH4xgdOcT+w8+VlfHhCcAYbuEvKtMWWEhbQgbqtFpF403IT9Zq8ysF7eKIzptbqAFnoGH8Ju5nw9Fk
# DATA XrlsSsuNtzLzpO0cDQHZuEYgxygeaqdJB9kAYdJl0KmYirJEwsSyMrSkmTkMGQeZWYiU58U7ab/32/tRP+N3NLNlNwHeoOkVoNo0
# DATA 43dG780owbiU3AkOZuWy+A+UlvonCFXFwzQ66bGNdcFFl9xBN9/6E7iLb59QvhtyK6G9rWCrIVcI0IpOqiAaqtihsDoOaC7NvIFv
# DATA kXkDP4oJ40+4OvwZV4I/46xLdHR/u0RBJs4kAO+7TXHwE37mmeZvPKvZjSSo04J0syFc3aZzNcA7QleL2Jq6rmIFHVbltGVXZu6x
# DATA jBo1/gQ+xK+9rl4bHyo96aXdqopz33r99/rv9d/rv9d/r/9e/73+e/33+u/13+u/13+v/17/vf67zN9/AvRP/wUAKA8A
# END_REMNACUST_HELPERS_V1
REMNACUST_INSTALLER_PAYLOAD_V1
if [[ $EUID == 0 ]]; then
    bash "$directory/installer.sh" "$@"
else
    sudo bash "$directory/installer.sh" "$@"
fi
