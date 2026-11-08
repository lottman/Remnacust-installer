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
HELPER_BUNDLE_SHA256='c659f815ba8ac897634bb979e91577475608729019d15762888899e3d2234dd7'
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
        NODE_DOMAIN_CONFIRMED=$NODE_DOMAIN
    elif [[ -n $NODE_DOMAIN ]]; then
        NODE_DOMAIN=$(ask_confirmed_domain 'Домен ноды' "$NODE_DOMAIN") || return $?
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
            case "$choice" in
                yes) NODE_DOMAIN=$(ask_confirmed_domain 'Домен ноды') || return $?; NODE_DOMAIN_CONFIRMED=$NODE_DOMAIN;;
                no) ;;
            esac
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
# DATA H4sIAAAAAAAC/+y9a3cjyXUgqM/5K7IpHQPoBkG8AbJEtdksVjetKrJMsrrVZtOYRGaCTBWAhJEAWVSZ59jWzO6e4znrXzD7OPsH
# DATA ZI+11ngs6S9U/aO9r3glEiSrZbWP1ypbTQAZGXHjxo37jhvPD/cPjk4Pvvf7/FeHf912m/7CP/dvo95sNLvqN/m92+u0v+fXv/cd
# DATA /Ftmi2AOQ37vP+a/z49e+XvPnh2cHPufHxwdnOw991+++uz54b7/nCnD+zKeZ0k69VtVf9v/k2C6DOa3frPe7Hjefjq7nSeXVwu/
# DATA vF+h3/yTeDINboLr2P/h1WIxy3a2ti6TxdVyWAvTydZcPf2Rd3Adz2/TaewnmT+L55NksYgjf5H6IXTqB9PIj5JsMU+Gy0XsQ9th
# DATA sEgm+DCJMy8d+YsreHGchPE0i/0oDZeTeLqo+tDcD6+C6WUyvfSTBfY+TRd+MB6nN3FU8zxf/r2cx8FkOI497+wq9gkNo1E8T/3P
# DATA 42k8D8b+y+UQuvefyxDQUeCP5nFcJQjH8Wihhx+lcy9LR4ubYB4T6OniKp77r5NplPkA6006f51V/WwWh8koCQGYWz+Ks+RyylOG
# DATA Tpbz2AvTFDAB8wRs3wDSYI4xDDaZLKfJ4tZPpvxDACNCp9N4gf36WTwH9Phq/BpPSEDLEDZ/kmYLvwDA2TwIFwgPQ+jjUwWXB3At
# DATA gtfQ/Ca49W/T5ZxmH6UThDi7Uj0RsmOCjDqp+f5ntwD1dDEPskXVwxeLUcrjJdNFPI0YD5dAWwF8j/PjeSvjAQ6RKpAyCcUBTCa9
# DATA nAeTzU3oaIKAI06RBIDoggRaYXdmmRAv2EmyyPwl4DADxH11FQPmY1yo4DX2iq9oxFXxEb46j4FQ5khgMJQAWUUy82ZzmBpg4PiB
# DATA SduLb2BdXAULnLl3hfsHMWph3NoNvAlW4PPLgp/5JZMk9DDxkxF2CfSUXVWqegiYQxgn1/jych5ilxEQ1RyIa+pfxgvaOfSidwML
# DATA Al+tV7GNtep6eHgdEOkDbCFDh51MgU5vPIJTFgg2AsKpu3s9TW90v1GKfWbYM+AX1+RpfB2PcV9k/AoOcR9NwSiLOFwwBRFzyjze
# DATA TDdAtosYWJJfblT8IINFX9BeZhaWTp3pMJTlZgVmAsvtIYTEcxRDuLlKwiv/EpCYEfjj+BLAIVaWEcMUXla1ls6DPrdoQ0bJ6NYZ
# DATA D6a6B3sZNk6EDHYI0xsBAgGNEZDbNEJyQ3olWi1pykgYLV4ygYlfx8gEMyCpCDcWtF/E82nADFRvFRxV1qKKqwzfbz1FDzcJ0OYM
# DATA eGOEIwE/BYgmQPbXQTIOgF3SvmHuEVkrk3rJNEznsxTYF26AF8H01m6wQqv4v6s4mMPmh20AaPFi6GA5Dy7h65BRM4+z5XiBE7c4
# DATA I3T+BbBymFA1xxHN3gbII1xPl0VmVV5A7haQdOuPYFa8TjjHYbpc1LQ4WCMHWFYhjl/TkvBaJjCg4JgmM44XBDjhmjsIQtgWGW4K
# DATA bKPYNpImDOvjhACycRxkLLkyz96ai9TqqvYBMktzGkf4wHqxzCHiIURmS6BmxCShKTbTssFgasgMOXgCmJZSsDyHyHL/YpkAnukZ
# DATA Lx2SDbLpnNgCSJBwk0gxE4sdjVxAFH7ny+lUcDtXmPFoW/ArwCS4c4DlDNsAyQIlyzIsWXqurlsV1sULpBngiNcrQZrn7qqy2VfX
# DATA VJDAwHv3AY+7fOqn4wimLiIa9AlYE5QF0P7+9UTKopGzK94l3BwEU5A5MgXgSiczbOdnyQSWau5fpsE4I4wAVSQZzBQgg7eBYRhI
# DATA SFXSiJY5KJhePmf1Sr5fBZnHBIsbGNn8+heFWaq9A6/RiLiKSxD+KKqMNifkDUwoTFASwEsZi37gjcmC2BhyIWSu0IPFX9XuY6yH
# DATA rEmNUtT9sNODkxen/t7RU3//+Ojp4dnh8dGp59Vr/lPgtFPuGJptnFlcfoOFPS2xml1Lze/BDYi9aR15A9hxBuI+DgB+LXY2xwmI
# DATA /3FwI+ItmM1of+ZUSE+pkLhLYbGzeJIgOpYhbqxJkL0W0GNQbIm125AjM9YjEhenLSj4jngNiDl6CnLfPwhgKGnC6m8UwZam1c78
# DATA DRB5G9BqQ16Isw1C/QauGqgAIIY2iMUOURJFCezwJcwflYR0fhlMk58FCuFnqb/BAhG6YMgYScoYGM1B0KG6FgUzUuXxywxkh1oI
# DATA fMdDeQcMPbsiHkEMiEWHEvBGNFcFu4BxliDCzJEvTL34DWjF9B4zEEsOEXCACtmxgQBubfANgckD2TZOkMHjKwg8f9oYBiycNmhg
# DATA uxVpABshSPE5tMBfNgQRcSLggmib6hFloa3OqW9PFBl5LAgGJjsLLkE4r+I4IgIhhYvNDhBRLBZEOHk25m7S5ThipRW1ngjYfLgA
# DATA kgUolPaSwNdxorQFWJgRrgTpJkJqSOWwP7GFWR/YBFU/fhPGsMjxmzhcLsSGw13tIUMDDQrJR9QnFr+gcl8HrBTjer2UeSIRgEoy
# DATA XgJb1JzCczhFmSabGhlssw3QlZWE16qPiBrm/awfouBE3QFUFzB4SCunpUK76hpYCsrKDOyG8VjWATB0HecJHfcn7nSknZk1AeII
# DATA 8RQHl449JHvsVRkO6Vyr8mwWoPIVi11F5p0yJgNSHaHPebq8vAL+rzEqIpnXG2SAD6bbNBvFIrFZiRVDmuEHvLAk06Ncx9w9/TAK
# DATA QIYDrmfj4BZYxd4MJzVPcJmek5Z8lILZCSxDqQ/xmwUSB82XrAZZuIDHmyI/IXxDR5NkCt+AxK4Tks7eKA4W2nxC1V6PDLs7sMY2
# DATA pDal8bWK7y1ggViwC46ChagXNG2Qr3M0TG9J7iiO45eFWIUu7EnIC4nYe6LiRMoCU2w1IxbJOKU+qF/DjpUgYUivwFBCOZSAqOVl
# DATA 8ZUjxLDtwxHafdY6gBzNyCoIYNiMeCZNElW2gKQLrPOMmLGRL4EHu3VZZbOaMQ4Lg+YkMxfqaRLHi4zHD+fwdM4KTqPmn7Iatw+a
# DATA kEjzDUuz22Dj22FDLPDRrgbOBo8nDm8nJwZvR3uT0jZIFiiGjoc/jYlrY/dmV03T6aaoZarTwGK2p4sAGVbkHyp0mZctFPI+ZCac
# DATA 0DOwCZMwCcZepnqIUIlgrSzALZlegoxD9VkaZP4wjWAfpat2ix4oU1o64wCxj9s9XKICJybbBJEwBut7CaYS6qyxGIAZ2W6wL8j6
# DATA CSYptLMsMJw08VNhK6oLtT6ntxmu7/NkOA+QkW2wNBRObJQG2ZtaZIgs9bQspVZIQqD0peNYKL4cVBB18nakUDCFRQF+IGsD3C18
# DATA HVwyY38R/BRQsA9MKp1q1x7rkcKLjAoAA1Bzz2pOe3tYYeUdqHzKehWzU2UGaIDF3waIXBkXtzyQGejTLMICf5VsaLkYONAgdFuR
# DATA Q9mKEFEGBMkPY/IgHoCa97yNHBQbQjS41VIY9A3AJYQKGwObomYGDAeQGaqXvPJrMP/jMTL2aQTMI6M1ZtSAKgpSTuFAWYdirOEK
# DATA cGOvnCAZ3FZQCvMEmWG7VAE2WVZlTQSHT8bxnOmQ7TvQU42LkNvBHjJblvcaMICFeQ/7xM0t9LmfAmvIZil7QpjBOIwkcXskkhIU
# DATA jcde3ricxrFyOpLqvogRw7BZx2MhnRFDaWZKzLlCYJFZaw1GDq3UduvwRJncCZvAIWcL8pSQbzQdQ7MUbTqtKTiejQWoZTGTudpx
# DATA qttS5uU3K6GUJzLenC3nM+x5kaascMsDtGmNGwedocojpyhXuU4sJROwChSByGST2wUZ96RnXnY3JUMLs3qG5PkmwE1R9YvW0dMC
# DATA 31IftFHmj5Ix6VFZGqIcj3izymryQ3F3CtrZvxjntxZ7rSMQXoI2DjPcToMJ+0W8cTJ9jTx7OdSoUbqA1v3XevHF6VH1lBAdos9+
# DATA kUxQ94iCRaC8JGKYkgnLpDACCxUspcVNHE8ZyZ4Ng+WxB+xmDnp5exRhlWjcoSCt5itP6jzz0Os6j9Um8IPlIgWAZXpsea2O7Azn
# DATA 8XD3QeJu0zzH007MLJjoWTVr/mdBBhzppTY+0FjcA+uPvbr+JcUKogJ1iYhRPVYqG/oRUMaseHxfKl8ooplCEjCD65TNE6W5MT0t
# DATA kPw8yw+BzSfxQvlV1PjxG7RvEtRSA9AU0IFB/ujldJxMEuzD9RMrnrJq3YkJCuYJ6Oq8Hsr/hTaRsRXJLJXv5D+1wCHZx55e6Yl9
# DATA WVPyM5JAQUEHH7JFsgCbgDVv03l+fiCmp+kNmMCX7Pyee7Im6OcNEg4EaEcx7ovrYMxSOTMoHd661h8s79dgUqJKjLZNldAiWj8b
# DATA rw5QmYkhgAmL4RdWpLXdajuMQNyNUSMKZCVU6I4gvEE/k4SJ0I8AJENhHAWNKOi5wcVHk2kKy1IkGOa+GKK8Cq7FTzlhY83VXcF6
# DATA GC8zWIYx2xUAF/Fx5Q+l6AtyOuCHyZj5LbYz/k9kxuIYsuhUhWnQA3hLuPAU/Wd5gwG3ozbpyLWC3GqesE4mcoEx7In5RwxLrxtR
# DATA Bkmbq6V2ijtA5hbNk6n6k2WGQg5XxsYEbAhaoGF8FYxHVdnd9BP7GhJ007I3EEGp0jamudHUARFXyZBcGIB22jDKkGcvGIfOPOpR
# DATA TyOOzMSBcjLxRyfkk+f1ukpmLHjgzRrGvhXWxKUBvTO5h8k8XE5Q70eN3glvI4Wghi4+z9ihUGIuMG/0Vvr+KSmI4iR1o9hP0NNC
# DATA IqRR95CwKKoACMfAWxbMbwG8Vg05CEbC8P1XHDRi4/uEt+ozRM0eyKfNfQL4GtVH6PM5bcSj1Fk2FJ1AHEOUy6DZRlrMo4Y0GsXs
# DATA AYDhrqbpOL1E8QEWZEAhBoMfy+0D290fLccgvcdEMTDZS9kX0h4NH1C6Gg0ldL46fHlsMYzFHOx+6DMC45XDPc26/xRQMBnC643t
# DATA 7S7uJk/5v8nFqohDEWmM7iBGUeggAYZEKa7moIPDvLGIG7gcsspR1gDRgFOVaCAsF1kPQPTDBCRHfhAHY74azXfdIhyasV9Fa4/R
# DATA zmwUlNR5mBCpCCMuEIpEvCibUW0FPTS/NVkAslMvC8dBMqGZUIB+IYKKxJdv0hQAwY6z3TapyAZkDRx+jqfIVclgBFaOqrat0JIu
# DATA UuVtTtw0mTONwW4tCTJlZhqbK0vmFWMT1q5d881+/VIlk+yzw8xIHVnZXLaJmpRI5FLmKDAsUHT8NOFoGiIOtkmynBSz5mk2A7M+
# DATA XWZjynXxLDcV/CIxHqTpGL3wkhJzrzPrifc6jme4Wui9xs3KvzNj0UqfqyahwjO99dBLohSSax1xicROx2DSXCndwnh6JlDBZBTd
# DATA A4DgLxiChRpy9A3Qo3xqTwiMS9o4YKiZ+MEaHxe0SpWn2vVz62XkFAgchBIykKKmqXxG8WOQai8Jqg6e2gLYDwX+YffNZikyu7lx
# DATA A0qSAYeXULUdxaj/dmwye6E0OdGBJY+qgN5s7/2KUiq6Rd7tpa3qRLRC5yXxriiXl02vijHEnlYI1KK2i2hVglaxBF5Gkp9hBNeO
# DATA 5wUVUlLZn4diPQRE3Vquw0JSJDQLkrxEPDZAB+z+wdDiNeaeRJhR4HnDbzUGZYCZMGWRqcB7wJbETPncVnDj9ZQKLFYeeYIE+kyy
# DATA FcwDNHIUUnGxNtZsjQ2YWFhhPRPnpLRSYv7A1ubaorX8aavROonxoS8Q2vgco4fRgObTLIszFZQNTFTLevkGZDB7uzFQzhu7au+y
# DATA nOjWPMADRBHKgNkSMVUVPyBIbWEgxpXkW5EtWYVluQzm0Rgj6Kgto3f7CrcDOszJERhHecODI/DTNGc/2XhTVqZRyG6CW/YeWl4V
# DATA UPPBJEmQuFi+Wh1KyhRlYWUxAMtcWVh8xE6pqOIfWsLuKsjuCYYAZojnsM7L4QlvbVjkCeJC/ECO6MmPYnuOidzZDlIj+GtHYEnL
# DATA 0QbtJSAThbRm0srJQ87OPC3bXZ2HqYNxrPAkUbEonmFW33ShAteuk4gTfEC7nnLohhQdJ0HJUUyIK7s9AGBD8reriKVyurB6MMFo
# DATA B0oB7TevomGHJimGia/T8XIieSDZIsWsI3zmhAeV+LbCvVNvI7i8RLLFOGqiIDUooskvMidzSYlpgdxT7k1WpUgwchYJAOAoOulK
# DATA /yVJVfSGMWx2RIn4pkyEXYxTNjkwHDQl06po+ShiDv+vZmQ8jmGw5BQ8s/GQw9gS30QjjXxXHQHldG1JeATqhQjBZ7A0hRLQdWUU
# DATA uHK13GJW4xm5lQGPRcR31oovK8A2gW0IdLOJGW7EzQr9VbnB8ioI09I0NuIQWIwIwn09Vs7BTaIcjBOQGaRXUXDt6jYjXZWl+cIr
# DATA G4+x9bSALitVSfIJponOmPOKnW/JG9YrAj9aztmrpXrmzrwQ+FI64cg90Sd5S1U6HXEZzvhkQfxvNsfAu5mjJT1l3azqEw9nHQyk
# DATA Jwh53A+YaHgbB3N2nFpNMs/yASn1bsbyhggZjHfChKX2sXOHHQsEPgh9DKlg5ECMPSV3RdiqtDcLMxI7pLxTzyi193lLWSbbi8DJ
# DATA BwyFaDdrXX7V4vX2GLH+o9e7quKQpDuD3J2kHGkXLw1soyydSiIHB5fVWGjH2JGDJPOMp0krpUQxmGVrUulEMV9HzajsrqQRBqj/
# DATA ieLPOpXQqMUZXWvOXh7Jj7AWxqUzhMrOUiwCTGlVKueWjMFMuWzYBZuGYZCRvsRmH4anMSaAxjv+RlqSp7y1Vpp2VAwyyzy9GbSt
# DATA 5snToVLVukPWWNZs3KHYOrQleR0EzRzfIK83aBSA/vIlWv60VZgyGOcVVvAYW8bf6yZIFi+o2Crs+w9uVYKK+ZEHphX2Rss5+9h4
# DATA pdlFqzUYUcF9y4Z8kJ5y1qSFFkqm4GAtQUChu1kB28tW6LG6lkw8yYnj7akzMIWMy+xZ4f1MPApRbLwhtxWP81uZOWU2qiXJyfIW
# DATA W/KQTVo0QJKpFwKjtLypIPNB/9KC3ZpZFlCPNyrRdpRwYM1bswFOHIX+xmTigkKbUapI8atVoXWEULkC7ZMxti3nZqIDK1cs3UR0
# DATA M6RQjsNmjl2Gmke8dhcsyX82i+P55iLdxL+cCKVT3xQ26SxAMmXrmoNjMaVYMJ4KYsNF8TLXVzbH5GrmjCNi6LIcErvVCce0C8TB
# DATA IRaqtc0jOUWAujjxfSASyy1ngYUaObrtbddAIjEJnKL2KRRvGiR5JwgNvEtvw6EO6EZufGGFielEHHRQo5WDsm2DALEkJmXNZcsJ
# DATA K/PURBkUOtPHW+CZL5ozLAWZpGj7xLBn7KQRzDaxZZ5qDHIumIA0rHopEis8Bws2UsGczEgpFUHVgV8SnGPuzZyBIB8tGuCwyTH7
# DATA DxPmUBmH91CjTKayrzhZUE2LWUl+slUvSpfDxWg55vx844uHhUnH14zlUXDNKfakEQTEHJ/lcoi09qDFCmUrWUlGaF5U/Q0HUU4m
# DATA sbe4nZG+lnIGGRCXTqUB4gzHAW9+BbvvGvkqirqUM3xxfnCfJ0EbI6AzbybpJNfUAyN4qaDkJYrfoHObpBMR84w95AA4HWaRky8I
# DATA GGbZaJWuEO05yNViWX2QOY7bbxFQ5o1nZDkK42iJGi2jCj2segAGdzmlrkmG4y8wnqTqkWeetACkMXL7sbMpluQ96xQPzcXzNg45
# DATA d4XN0EPiTfRZpcjYG8zKj5vApNIoqyJlhHGE7vIq5gBcpXPJ0PZfx7eMXGZ1ielbsVZCsCTPkKnOOTOrpx+yAh+CykdzAETu4xUc
# DATA raFDZdl6/St2wENvi5ctMVUvzgsTCb6Bjb5EVrCcEgcV1dQ5ucEMy1McEk+0pZy6B8uFwQdmAuyK4XlxegqF+oYxGdNulATpZoip
# DATA HnhQC1bvcOQElqYrTNJ2XCpmL9YWDsaBLjsvZSSH8dgEs3FrsmMsbTwMl2gtZZ4O67HoC9RQ1i6U3ImR7VvELg1des5aYnKH5BNb
# DATA ck2raJJhNIsXSzzkqvRKj61WStooFzoKXQgzUgnhG2ixP5NE2zUaH8/b9QYrpJKDbhjbdqcnp9HW7TA88LpcqKNlxgesvSnkN/ES
# DATA PLHLQg3XeppySNTS7eDtBR1U5WAJKnG39s7KUaQckmLt2cE4pa7phCvbRekR1UmHLDdOjl9UJHXHht6yeNZNfDVDLfByXagdZnen
# DATA DGvUDCkJW0VViJyXM3TJcpaAxEVov5oto7EwtyaiTwwKVVWFkLwV5GhaTh7qFEWENl8CT2n4osBHMTklbq7i6UqABplUPB7plAIV
# DATA 5IuQj8WcFERyyhyPs7Q0NRDAcp2kY0QHT2455pQ1ZNaLNMTsvpGIYZNVFoTzNMvsjihZ4Z59wBxh7SorrZecXnYssHDj8Ckceln7
# DATA KNSROk8d0we80VlliS74uXzZ9cmyXj51TOxOGl1Zf8CeiReiCgjayA0CDGgCOUYUsZxicIEC0egElFQAsZ4AV72av2fiGmcxOyw3
# DATA rN9MqAAPPc1jO/0EqVvyhFfchzriMrxVOSl8goCPtFGu3TTmAy7zWAk7E5iqecVAyMkxid1IlEalEHAUSQUQSHUELsDZE3yUC3Ol
# DATA 2N4GVZmPjthJ2rZTyclL8JQg5ZAN+9lWzvdgXhcZ0kEh7B57lVV2tp09qqOZ7H7DJ7L3SH03kRlPMfJUnc/lvjnoU4AFVRHgEhUR
# DATA Ttr3VlIlMIGMBY+advEM1qSGsCupKEkEJxHIAXU+eAFsc5JK4kjxICrGGyzkOA6yN3LRYJCbkeaRw7+8hkYEdcqvZfJVJRKT3ggY
# DATA 8B4abWA5oTXOFseNmmAuw7lWMUly5CTx1oCPHEKYYVXiq+LhIBvJjfa4mWcUhlOlCcjjWpgFYUaj7KUFLiGdvVCpX6rkRYrnhhS3
# DATA tYmbD5lIEhjmdACcBeDpNaTMeFGVjQgyEF3RMV9KNqOFU31X7mUSbroOPeLAwlNJyiHLUSUiYMwI40h0KCRRSoP2K6kU3qJwf+Y3
# DATA OsQ8G9382E9Qn0RH/4k+RkmmyfxaCypzUMVyAXP4Sqd9gIVG6AFq1679TCv8Jt9urnyAK/FKT+KVKqLJaOYQF+oWARvSyYIhDiu4
# DATA xXWGF9CDtqkcCQsrdplMtdFqKBM6MSdH+VmRCUM2m4Z/iOdH56+JX3oWNm7oCFpmefm0U4UBCHQJEwY/qsACyGLKWTR2UpD4w4VV
# DATA /giq/xJM+AMHv9O5hXFtaysgeYC4gglyY0YaBjCQiHIZY3MwSXA6nKEnZgS56ydAQ/iUR66apmweij5HuMh4vJFNQRgUnkydVDED
# DATA OWUH2KAHC88g+NbNbkAemznT88vqVGhuqYAnVngncUUa8hjgUYLlRMQugWFp2zk1EjUGyuczbUTqcRJMYZ/6UCwoNinlX3ssnAon
# DATA LFntzJ9yqVj5DAuStOhIAI0MOdKGOMQ9ncpISgnOWPYU2voq4qKzRo1rW4lEN40tojw2MVGUTE44RZxtlEC2eVG6jSVW12ZuBWza
# DATA KRURdMbViRhWK/KRUR/TGSnUKFbqP2n4PN2hb3VI+kBREQI+iuHk89oKmyW3i0SCIUN35lao2j71aVWrcuPVlLJVADXaWZR9nS1h
# DATA i11Lwso6+I0/gYBl1TQtcLus0+Vpth6p1CTTdTqZTsmyj95UKYUCEED4FwfACtm6tQ14M8jrZOgJMWG0LiR68laCDo5yK1r53koC
# DATA krV30vxuqiolSFKtJaRqDoZayT5KT9KlMZDDLZTKbNT2Jx5b60iedqRBJisWP4gCgLZfI3MimbLfwGRB0LkpfcbB1AfKrZkcN6bx
# DATA UaxloPpqClpNbUP7FRVKmAcwJuukAxvjejRPRuNqaddpIhYh5YW554EWAn5sl1eyS3ionW7H+ImFLKw6I6tHd2L2g6D7KYBnsyuH
# DATA XTXQQfGFlRJFqjZm9HEZMDKSC1W6heitc0+XauO4puVKzitsPvlxyAvAhmrF00ojB2nFc0tOLzAsxoV6n3MGCGz2UTJ1UegeRDHn
# DATA VZFeAz7iXjU5RtK5J51j4SLa1rhxRhIr5LYGHcCEqDiBpZOQ5xfLlPGh1m7dj0hLGS1kHegEgZDnC7BCU8K5c2TmUSj0LBRaM1qZ
# DATA kHqD5pHEmTUT7+GZSEWnhLWBUTLH/I9kEmvDwQg04TDQ9Vp6UWc+WcOsGJvLy4NrUuXDpYT8TK8auy0bu57kSwA4M23iMlDofjN8
# DATA AZ+t7C7X2aIdb2Y/Ir709kLnrNSJQI2JLCiNCJUGoQegaeJcVvcxy1kbGuqLfGZ67EhSGRb2QlvrX7WOaPl/AboSWZCprluBlYOc
# DATA coUq8m80QCcXF/UXz9uukXduRsdsMK9RVE0J7H3BZ6+cFH+VO2iHLYKQSzjkzkSBYOS0DwUkWgZ4Gs1OErHO6O1NQ+CWASck6/od
# DATA qyl35GkndVjiA4EKPQFMKjv+gUC0Z4El8GARIWLtmjKUcR9oHFnHi1GZoCimUwbHTrNF/sx70U20LZIbnD2dOywYyzlhtvi4AIy1
# DATA 64WJy6mygkVwa3ehw0zXfOEjcozklWOQTGyiR4iYMjhY2fFc/oaSXVEr3lPSThqI4vw0vQFaxoKhQGQqtQReoRJJmt+sORfkRjsc
# DATA eaq4U2apsqs2ojYaqnJUtKr1A/YFy4pw4REaM1tyiIB0LQep7j5Al7AUUcGQgTqiw2cHE8LY8NY9jWPpi6bK1d7U30AfG5pHJiqz
# DATA wZq9HafRkSAehQ8TctkluywUq1smsoobZUw2Vsz5pmAMqjaU38WKxmofk3h+yTRj15wirrZuo3JWNGfwqjyoqb86O0np5tANIRoE
# DATA hT1XZL3WAtuMg3M+MDVVN8BsGdychourXHqOgXD4+7aEh9jiiE76seOEAo9gLQBrjtgQWI4jjzxlRr3CUGWSLin1njUsUJXHS4RL
# DATA TtPlzwqsDZ/ZU9DEugYmVGC8/HNKYl/kqo3K4TQt3uPRCBOcckqy2NPIcQoMpUxFw+Q4nI5H5g6Mo5CnU9nr1GanYIGYfp49vtmt
# DATA WA94nt4GY4lfpVZ6Gp81MrB4Dx5cN3qFnjHWQMDdjSldTK1uAi2Fezb5uB6vPmVv0ncKxuDBxyW6QTCodalMdc9Sy6WxYdSRiVBU
# DATA WRoBS+EslqrJFKSqx8GYNyJiZq49V3ZpMhzHpCHR2YlGo+a/pLEzVfRsyh7CdL6hkmByCiLuJu1tpTz4ooMwrmC2SqM51UvUYxiJ
# DATA Dl2xsPFkpy0zUxnPJP+rhAEBE/ahDbUu/yanJpx2pjSLjXCJHSFfc372QNjEkVUdYmw7l3XHVZM+NMY4FhasFLUG1gVFJyv16teq
# DATA kg9Yvo0CddZak3INqtsUVVt9XNlbTSoe5cmCHH98hleCVXmUVD30uoj6pyLFPNW1IFE4iMpQ5VQjteuLDp0WjM172bPdpjQhU1yk
# DATA KsuYjjdM2TGT5qCcpJ4sUaZOZdMBKyq+g0hjl1xGTXQqqeMOoCCAIzMP+BCigdlSugLyXOhj8Vh1bz6OsL6T5jabXMHFMawthu+S
# DATA 4BoKRIXC41ILlB+FKykbnDPCaXfz1jZFSLhawj1qCI8u015HFuimUqcUMUeaWQfViVYiinxLG+4UmT1Mb5ULxIOmsfieOBSeLNi3
# DATA JmeoMFCfiqHCBU4pE4hKPJAVS6HMsi58NlU9r2i+VCvdvMPjXcfTgA8fUpnypXjsuYVd+bCCTCb1N2iVNyR1O+cY4UQD1ih0eUap
# DATA D86Z3mtmuzIvRRj2UWvqdzXbKKeuYmEPgJnOu41Z356uAMonstamh9oqgipd4Kbtkjvf0xWyqTY05i6qk7vRg0dwdJ544JmSvXqQ
# DATA 3PEALZgp4u8W92VHgrfQIU50fFrpp+ow1Jq5whzQo5iaxGSTLIpBuks2MmKsU8n2CKWGCIqsMt90usMlBzaGk8z2tegKWuWWHqFq
# DATA 8yLvEbxoNaxPIf1I6IS2xNg2kbT9Y1Lrserej/PEosrnaf+LREd0uRipLIoiQZn6OdLypTKHlTTsrbiupeAm61zKs8KA8SG5onOE
# DATA nvsmyx1tnNqpFwkeXQQBw0nUrKmowKUnHZgzZuJfQd2VyWGcxNexSYqgPYcFqOfZMuDEKFaTYZLT2CnRiUJ17Ka2YQCKl5n5mnVa
# DATA 3TaFyVLDLM6lsq2ghdi81RUjmY5aU/SviAeROmDn58aZmKpFJV20WqaL3ah8Ww2bEhWeDlTgXFXNOdsyWrGdpwU0Qgn4DD5KA8dF
# DATA zYQszh0sFmXOgrhDsLpHjm6KJ+vj96Si7uXRAgNtYF2MeULCJJ3f0gnQokJtHH3jknMwNyuThzOzq7oOSZY3V1iXzkyJKVMRgDUC
# DATA Y9jkUoW0zmLSgdyU0PVWh1XpyJR4zRvE4rEhldUYvSiSDHHq0J6V1CgRPk9iSEPUGyWR0xz5I3+YuneBATQJICQAZ8HthHKOUhMu
# DATA kBGcuglSMkX5UKVU3S0nxgtLyVWKs8fL9806WVUV0dZs2jhXmYsof9zK3lDO1Sod97HJJ8/sqULmKk9wT6057EwnskoqTZnz2JJY
# DATA boAQ6zzNVG3gCgsODDIAHHT8jxMtp1HR0HqDSp55JkqHOo6cKX5IMdeC7SuBEoQtJo9AxFUJhEANU/P0IUsXJ1jXXui2avzqzb7/
# DATA IpjDajXr9R5n+1zp0qaWc0+fk6DCZvOljt2J8Wwlz5A5jGmICdUHFGPS3HQx0i4Zp5q1pI8AX9OK8TB28xe1Y92OX6ppUqmlRrPm
# DATA H6X+6RK0C2oIa31MlcVK/jO+5oO1tlzdOXZGRFIxyy8re5DKqi2pYgmHKiyd0QBaUdlkmMIQJaFOiVdDFAXTblWlNUAiClkcV/uA
# DATA 1r+rwwjo8bFZjCvYs1QO8KsDXFkyWY4XwTTmQjmcMbdSKcpxAKhyHupcFvokaOrmNRErK55329EjAAJ3D6hgR94ppLghopYcdSbK
# DATA rc6vURSdNFyw4LHsh7LcSPHRBxm1nmPtVngLWMvEEvVeLiFSzofI1Uzs89NoG6ak9aXO5QkOlrTJTaGE0Ry3L+dIqowx99CWqbHT
# DATA aNXwjq8U5nckOvahqTT+BHOtjda5/hqVb5ujJ3g3aYieRgpRx8qJEU5jsKqGs3Wrb9LxdDkNq/r9nCY4NmdRV4ulU/YfDSkjefpM
# DATA JtlqVvn1Cp3ooId8kZcVv1lXTFMLMDUPVu6Up9u5dqTwmOnDx6SNBUXqni5krQ/BByCjdPkuOVUa6KIW+hS3XF8khVoKgWFGbNex
# DATA XX/uXaKv9sF2ffGGZ128seaKFJVQZF1HFDmaN2d8KI+D9jV8W4LUhk6+IM30tUhLLFOyEiNTmpJzD4fkMRfeM7Luhh8+Y8hmg2eK
# DATA opgyuHb1i9xNFnJkqjhHnbI/7PMbTvkPygnT5ypXC7aoxGszV33ogooW6OItpKHTuV87d0rtqUegAHlSG3kSrBC8/KVz0ZXjcMO5
# DATA ojwFcpNCB8/AkovkrFhgyq7NpS+5rMu62Ub8eI+5e4nZOcYGEWXwl2o6Agrs7jxCAPoPpEohFo6aJfNEH8eW9FVzSRFiFoHlrFJ8
# DATA IcJjQ3iNlSc3tNAQQLOgaUxEZwP5Np/qkKWiMEAPl4El3RTpYgnzR/JQLaZLrKao0wU9fY5A0n+VsaHzxfkF98heMcK8HMI2ZPfj
# DATA gRfjT2etSVSvhdlvBA1nzxN7snyIa64MEpeOSsZTgHoa0LmqTOdA4DsXLi3yNOQZGlpNqtSWIaPr1rpbiYdXBsWD5GQyEMOrVIXA
# DATA VF/k5tRgekVgWqTOuqQN5spiAu28ueX7+OBJpO66Gy2xWJOXv0vu4b2APcmxjaoupvLmtpSJ685NIHTD9QZldhqRFQlSahbjhXpX
# DATA bygPk1FfntPSKgVfzwQReyn+OTvnlmpCSfa2Z5/5sEq1g0C137DU05ySjqfUJSE+LciZIn1U7qZT0p8mpS6aJBIHndkhT2R/nZo+
# DATA HMAk9ZUcD0Cm98XByYF/eOofHftf7Z2c7B2dfe0/Oz7x4YH/8uT485O9F1X/7Ji+H/zk7ODozH95cPLi8Ozs4Kn/2dfe3suXzw/3
# DATA 9z57fuA/3/sK74X6yf7ByzP/qy8Ojvxj7P6rw9MD//RsD184PPK/Ojk8Ozz6nDrcP3759cnh51+ceV8cP396cELXb23B6PSi/3Lv
# DATA 5Ozw4BTh+PLw6YENk7+xdwpgb/hfHZ59cfzqTAPvHT+DTr72f3x49LTqHxxSRwc/eXlycHoKAEDfhy8A4gN4eHi0//zVU4Cl6n8G
# DATA PRwdn/nPD2Fm0OzsuIqoUW1V7wgM9P/i4GT/C/i699nh80PAF94Z9uzw7AiGINztMeT7r57vnXgvX528PD49QGGKKIROAOEnh6c/
# DATA 9mEGgtg/fbWnOwLsQh8v9o72D3Asa84eLBNO1//6+BVKC5j386cOUhBRB/7Tg2cH+2eHXx5UsSUMc/rqxYHg+/QMOvX2nj/3jw72
# DATA Ad69k6/904OTLw/3CQ8nBy/3Dk8QS/vHJyfYy/ERklC3xkcPdEDtucp3R3ZxhNRz8CXSxquj54iFk4M/fQXzRArxXQrBvvc+Pzkg
# DATA JFv04H11CEDhymmi8JkoqvQKPDBE8TWQ17H/4vjp4TNcEiGa/eOjLw++PvVsjACODbnufXaMSPkMADkkeAACxBCu2dO9F3ufH5xa
# DATA VIFjenLpcdU/fXmwf4gf4DnQIiz+c0bT0SnMFZcVfpBO/D1YX+wBCZPX0HsFmwCJ70gRDYyNv9nAls3YqwTpPz8+Rerznu6d7fkE
# DATA Mfz97ABbnxwcAaJof+3t7786gb2GLfANgOb0Fey+wyNeDZwvbe/Dk6ee2mBEs8/2Dp+/OskTHY58DCjELon4rJXgFqeVqoeL7x8+
# DATA g6H2v5Bl851t/LX/BSzFZwfQbO/pl4e0FWUcAPJQcAKzox4Ej0h5vRobkHj5h6a+05UjSkZqRQ6r0yehsNnYIWFzZEMXbuE8bXFC
# DATA DGPRfsYpFrTgw0tcVVly44Xz8gE5TjD3UDmMb9gKWpK5R8YNa8fSU3CjDg9hndJxymd+8XDTG7oNIvPQbzrM0jFWSaCi0ax8oMqd
# DATA XCdjC/YCv5xj9qpkZOdMmDmM4iLCHGvPcoXIdEoEVnUAMe8WtgXyo+UsvEHxC76Wao8wwJl/Z+rUwdcoxY5AHZX+Mx1+lKuJ5ObI
# DATA mX0HA1fSphunJLwmQF7SodUMRHEqwbtlljskXJWwWrbgYlKY4XlF4RidKSwh1WThuVfSspITq3vJ+WIM69pl6/ZpHZzMzFmEM0kl
# DATA rGLGfSC+ZKOXqlNxWq9XqaOHZBJlwQgnhvDqtyf6YtGFHMGhjDPr9AVfOoPxSlWDfXzrkTIlznCr+KNbb5l6oi6yK3IGkVKtiuiR
# DATA jbMRmqsrx2zE4pWHs5R8G+ykUgWPRktd1BZnM0JtE3DyQ0QkvavK5VlzL2V0kky6Hc6TeISBt0DXjpLYSu1HuYvmf4jF/X7k+z+k
# DATA 11N1CvNHaOIlmeqe4LAXeEffMu0sa7LwnVuZvWRRHHx+jKYbZI9XxKvKJFkx+E2+zdwru0eFK6sWSm113mZ6+qatKwxEqUNayuyE
# DATA 7QMrx+a6UrSQ/ytl64l9PzH3o5zkht2MvLy+BLhcpy75Rl06jePHGT9yhz3dm46mrsoKtClXp7e7iZYP9u059d8MFtmYA4rGrJjY
# DATA /+HVYjHLdra2bm5uapfTZS2dX26pTKCtH9ERvowMAacCDdZ6Ye5IQRK+lpwK9qNLeJ5OsaQXXnASzDCpCeam8zOseoxhYC5aZEj5
# DATA tuN73JSevtPx1iCKS3m7180nCyUdWYbo0jF8qzdnZ6qK98Ve8LlNedBHPFShDqZyvGPG3OvErmpVoTjwN9RVXuQy43NycRBlGgaO
# DATA MQITv449HQWLdII4X8HDBeVvM8sbLuU9pcAc3fSkTTmSvKRgqJ0wjBcLyXoy53XVBUxPiAb08YOWMix1gDVfZO7rHNIRjYSpGBCX
# DATA 3mJmiXiyzU0J6n6/eF6hrDq0/WBr8vVrFIHEalBcDU1xQ6MLbZh0Cutqd+tGkGc6t8GlTyR653pJ1mTwB7E49T6iG6ABE96Du+F7
# DATA f/j37+Qf2CCH+we1SfR7HKMO/7rtNv2Ff/m/jXaroT7L771mu/c9v/5dIGCJyhUM+R90/b/v7y2cy9P1USzPO4kn0wBjQXJCm486
# DATA cxFRdoeO08UCeC9mc0/jsZwDi1BOU7Yb+cCplxvSLqeR1LgiXrLZqtU3MYz5xJx1UVoyX5pLJSdYhZErO+RmyxoFLn4yZ3H1WlfO
# DATA QlG1nEmq2gsYolmra2+fnFLD/vl9GBtVU1AGF3QZkOkjvZmCZb5/cISKymegsGEOdjoOT872lfpNKFFl7sNbU5JPAc1BNIDZ5LR8
# DATA dfbs5fMnEgShrEiQ/IC4ram6A/NyLq7kM0xC2eQkFD0Kmm10k4S6moru8kFMq0UD2fNKzZ8B3fEVs74EzWE5rAESt+ZqTbaGQfga
# DATA Oq/e3woWEhN6H2o2pcKiBU1+cvb8dAuXaxPRIbEYPN9Dt2KScxdL8DPZyKGbe0ey392kd8v9Wr1WryhUKwKrgX2VGfqiRd0/sMov
# DATA OCTHNBCj6fIfZP/jvZSYQFULf5r92/D/Zr3T67n8v1FvNjt/4P/fxb+tj/2TJZUEVMXNwarkFApiTWDvUS3ZY76AUtf/uArAxM2w
# DATA 6C/6rkI83kUHDIC1frzlldAvw+eySk8oIXnhjzJ/V+nJ5RKyip1RVqqox+H8dgbaZ74J/2yavfVfzpNsEuyPuT4Lf/Pv7Be3wFTe
# DATA AjWW+NEArHosnLf1xzNquhXSm6bHaAjvlssVf/dH/lvPh3+Y3Muf8B+3khvSoekRRe7KPPCnNe5Vws6f1rj3T2tg3iSLcqlWqpzX
# DATA L/xPP/XrFf9Hu37P/9TqGv8FUTADy2OH3GDlR85BXtqcXZYqNYbk5WWl7PYswIvr8HSBaWs7lCIMNkEtnl7X0MP82d7pweDVyXMs
# DATA jvFmx29W7+njDCyNdLl4gZf2ZTt+oz6A7QqGBojH3KMWP3L6uqvC6oFZE08Cni2MWl4HTqWWxWj1vQzQAKuBAVUu8bulCqKzxO6+
# DATA kn9XMaPc+TvE/ukm9if6Z3FoTskNaYinLGta4ZZ3YGcvQMkwSESz+oZeO5jP03m59FSYpZzKG6sSuViNAa9lpK1z69vzKKnevbtK
# DATA GWmOCiTvX8Xha+pU8pUzHsJ/e+dtbbFyokQWB8Aj//RPn5vKfGDcU4GJgHNJ6SgI5ThzpRxd2wQ6UyFWVlvgpXQO+tMxFdwjByaY
# DATA 81jLOMGLcKi0M+9tEoimvvwT7AtPx0R4f60vV2r5k0RUFs604jRosMvlahtdKKUmu80M80K9iZuKkV5q1pvd+naj0ay3gHwG8TwY
# DATA BGO06wc6p3JApeRLO9Y6CSyE1Gw52fFLje16KwqG/WYwao2ajW6z1ay3W/1Or95rderNfnfU6zUa/bDfDYf9YSvqN+J62NzuBNtR
# DATA ENd7w5KhKXVyVvUOxH3ukHWpHUa95igaxb0o7tTh9aATbcfdMAwazX4z7De7/VEYdIdBb7vX7of1IUDUadXj7V4rjDpRr+Ruk1I4
# DATA CjqdXtgdDrdHcTsahdvbzShoRb1+o9EYNXpBYzvqNqJRCyfTHPVbrU6vCbPpj5pBMwg6Vn8X/PGu6t0pdpfxre27eDRhGSPT+5PT
# DATA 46NaRuwBqLdMv1f98qDqXxNTXNzOYiyb4e/u7vqlIZLlogR87Lq2SJmrAPPcgcZqCKQfewDm4bWQvPdfwEPYyldBs9MF5sX1XssM
# DATA FY9dqdSi5DLOYMdfxW9wA6nyzOrevTh6HoMWmClYZ8ECBzy/qKoAOlDUXUVIJBn53ND/oz/Sk2HYcEJcTbeEDz/am4OOWksy+ivQ
# DATA 0APpgEpaTEPsAXiBPPtsif4ieIs/qEk4BIpAnecQjVBXLgDUK0KJwFExfAs9OmVGKRYvxbRgalPDktx6mEKcnEMTwMZ5rVbDYao+
# DATA f2dANMOLx1n8KOB4LH5NuCm/9sS7s1ZnDKqBwprBvYPyjxDlPEzJ/8u/9D+in2sU4ci+AlW/XHoD276xU4KpyVDUhAdnbAxvsXzO
# DATA ri+YR3OhLP2gIVTughlQQkbdbSt8GjTu5uhxEoSaHquOeNx7+XJwerB/cnCm6ZSA24RucAKb142SplVnnDCZoWM/N9TTmH9Prsul
# DATA IM42YcTNy3BSotWp8qxqYNkERH0gWBvNiuqWXgSZuNgDq+UsuCznWjeaVb/Zr7hrJPjB9K9gUT6XTmQquQ7w5aoah4oVlSsXFbPF
# DATA S8vFqI/YvPOC7HYa6prpfjYNZtlVuigrVqkWn3FBOxtXCyw3jOgMaz/4i2U8vz0Jbl5NMexV3jg9eH6wf8YtBxTUeXZy/ML2VA5Y
# DATA 9teks68oq4Xb85NdpRBsOAvBRRJ3SYifgg7B79cmway8IN5WM4Mq5FnbboZ3mQPtnp+XgmiSTGGpiAIG/A13WEkbpQNYHcyhy3Sr
# DATA gkcXFzZjwO1BINZgm5VxNNAWiavkfm1cVCqWPmL0h3IJIB2N5RJjjGGHt4Jyo3oYfKDDwMhb/EdudpBppSRCuGEh54vBcsnf8CFC
# DATA gp8X8/SnwXSgSirjT9cYetaN4aN+eGFkEKEKByjqVL0wQDaDP8zTcWy/jbNLLgewLalcHCiOSzyjvIpZecIztknAkgj2z8l0iJE4
# DATA 2Eo2faySwHkYTDFOQ3eEJPE4yi4sThzjuWZguoRXh+fz27Igu77uhYUO0w8IUZucQIjy15L/iXnhSa5LJb8NheimoBlbA+1YTRgO
# DATA fC4QMbqeOJT4EXUNk6BvOYiJTkrriJAS47B2Ird6ojOHnwj5GfjN6Zh7WEJJWEKIFzVO7+cJ3KaQKfygQdkKZo/v/qDpH59g9spn
# DATA GKaMkM8NZmlG6XtEkMxFqvxOJY98Ndau1gs/rRkKufhUAwOijakFP+kpE+MJSSeqWVOrAMPFa8P40UewVYhFR4NggTCx9KBvFzVV
# DATA pKAcViru8snQNUznl57MwPRjgD8G9si0ttDTQ+uqlQzBANoXDpWuYCqJcH3d8VdnLrSFnAGJkz/hPoA/+R4zCprG2C/qNWrLnmO9
# DATA Qvgu07+oXORfhIndK3/+kxDbD96qIcw6lTZKn4SfwH8rtZ+moN2UqqXKHZPixg/eEpHcbfynldmLCYVMR7GNz24PI4sL5dgMIh/Y
# DATA CoJayXkICjZjjiuW8q/oHe0qtNB7jV/9tCb8D0ZDLcw80Q9qYPVdghK4hjJkbKrmM00VO81s/bVgmtJMppofsmgaeirSCAT2JYJs
# DATA 8W/icNbjB6kZg7xLjlDHGiR4sQh4Gt8aK4giZ6zVN+689d8sVMhGQu2iSLY60rRibXBK0UpvKvifc/4J9XRWvq3fcpAxRZ6LNoft
# DATA kujCaPirlE9dXVRy3RhaLupKpCIq5AdKMq50fB4W+Jhc+i5QnFApYpCoCUov9KWhyydvAQnkziDORO7ylpnh4LhDhZNUtZOTJ71j
# DATA Tf7OZb2FwqDiqBGk4rOtUKRAqB6s92s8fKWIH8hqolVHJhV3XLR/hNgobw35j14PW+QUbzvxfI6jZyzJjNCzoWSkwMwRGETAxZP1
# DATA m1h3po07PJdb/II0yCHK9MAypXzOBi7ZfxfksDCWpkWtGjr4D75xUbRzC36jjcfYe5gjiozEoIpGeV5SwufSDv8k3Ypg8Uv5zXaX
# DATA o9i7YgM8Z49hiLZsG+DKpg3ml9fnTd4/AG0MZsPl1aK0qrVObNfcgzqabk0SHWxI8ZThvplSJtwAS35wJasBBhzhu4jQATu0B2bE
# DATA jdKqMDWuSXTyFMrPBK8ixPJUuqOibYOtai4gFaOqeqvEzzoK9V5z5/lkpfOPtv78PNj82d7mn9U3twcXn/xgq4bJqmTgsZSlbiyk
# DATA rKMkPLyIGVYLy7+al01mxBEMd/G2275TA9IwahUq6wfhG1uMBzc0DlSgTgK7CCfibTMhCglKGNRvqfeR1s3vtewvxqWiHpU/Z5TV
# DATA 4jew2NkpEDS7oIDHw69YtucZaBvW73kDxrK5RtAVdfnpivsCeqKa5uWtb+bfTLcuYdN9s4JaxTLF4at6A1DO6UMVhsD/WZ1JV3Ps
# DATA 7IJFHZfAeqT/U1rnPJ84y/OLgnXXsBlzIL/o6yQBVuKZGlENguT4ZloucstXmQRg2kVPz/HhReEyaDB5LKT8AoDpYS3nu+d9wo9W
# DATA PO8fMlk3fmPT/XLKYNk3RmgSNaTvf1LYJ3non/iIDzSGnB3jQIWk/0SHSdyGZY2O88YFzrhEqrSopytiYFWNJIVOL0pttgSaKtiv
# DATA dwUaD7Nz7bPL2ZBWp0rYKemRLaJ0uahhYXzg/V8i76DD1RZ3XmUlGU/Y6tYIO8SQu/mKh9JRNy2y6F6vODIviyt7rbBT03VkXeFo
# DATA EojIYykH7EPjcSCwQLLqOqy7HHaZBfMsLuc5XB29ZMSvLOTkQNLO1ofQ91KrJeScqcqFnuRywjRxDCDyVdFkS1JqjNK6dTLAytR5
# DATA b+VEib7Kjv3ErIjUKKxajim+ibomoSIdxzX6SR5YkRUrOPqpb1afSEpCrUxV9GZtghmulzE6Dda0lbCsjqgav37VIlmm0Vt1bFj7
# DATA VMVljCVarDQHrEaDZWlq6OzSQYM3yWIfU7l2/cYT0CZrUvRfsgtQh8KMXY6nl3Fx/+3zf2JMSMbY8WAc3CLZzG6/2/yfdrPT6OTy
# DATA f5qNeusP+T/fSf7nR1vLbL41TKZb8fTan90urtJpy9vY2HjBN9L5XI7W0AmfxM8sg4YUQnVQhIwa3DdP0/A11k6CPVmD7jxVRnR+
# DATA SUxPfcdkdvV5NJ0gr1Bff5rhLdr8Oc24pAmONU6GqijpS/iqmsx1n9ltpj5i5QX1GZ2LngcPKSYK2gTwwwUyW+CCZeypPBggDxwM
# DATA UE+kq7WBfQG0qJlV9DB458dEKqzYeYjGiPH13CaTALMmKXE1iwfInDzPi2KsozubxZGKYINVi7lUN5UdZbUlmWKJqg1AKY8tKxBB
# DATA x/eAHXLgF8R2GX+EHiuVnQvsSgW7ffU7XS1qxV1x7fRLpLOD6CI2T63WgzQGnrkK07nMDfUha2p8RTraaYnEdC/W94wVqVZ7fguy
# DATA a8e/p3vysjhj1PBbVq44tjNPixdCrQ3SRFZmj+TKguggEpJrLYrjGX6Q1hUdM1J3oCXKPJfEJf4ZA4NvQSrQ6ACSmZ40OC/BHiQS
# DATA LKEjSuZZ8NCeNqDPPKECIgIELeD5hWMtX6NrK7ZaMYD8M8J3fmGBVbA61FCWh0Ql/8LdYKQfKIfTRKZRaWdFaeXW5yXORrJnmX9i
# DATA TdGZAenmAH9ZnOAUbc1iEM2LrJSD/fv+qeCCbrDHKl9y5pCTLTIuCIwZRcRYsieSWR3F4TiYW2UchvE4vamtuHJVVoiDTfaCrCDy
# DATA flInXJb0GtKjnUILhLd5KU8lzs955I2ovHS6nD0Gc87ELDKmDtZR8L/G7L7tzAxR25vO0HQxxA8RdimKcUkZYIvII8xRnw/S2UL6
# DATA diei6NhudnGuOisg+DUN8xN1vH7CukDvBtEESquaV0JeWhE7ZeiMZDB2VprRcm9ugj7KH/5imcRgEEmmakWxYsrgi7JVpn5hg4Gi
# DATA uTZOgwg5ZsFogFc8mgAjfQydgfBkgPU2jMrstZV8YrJLOFcQg1q4N3eP0mks0xpJMXxqKSfi5TUD5ziATcrTl4e8XvtE7EIG9Mtz
# DATA alkiMfj2ziYIFwQ+DkON+UWYao0nWROpUZOmzPXc13fyTiXyMhprDRkOOjQfN0INTwqCXjWIkjkuYKmyGkXxP35kXxI/5OAhdaYS
# DATA lqvF/Z5PsOgx98sHNvk1OZq7pGLnecy/wN9FqFxc2HgOppJdp7QS9umtU0v4qeglDnsiJOZ2oJDo2VyQLd+fgdWmZD6a0gMllcuo
# DATA lVX1raacyLzb6Nel3whMczootMt1vCYp7BFUfcsIk7SnljdXdCY/3+iHuguL+zg7lSFYt0dhExFw7l4loqKaoaiXfOiGJPYHMOSV
# DATA BPgZNUjpmKgav/P4fGxmPC6HQglYacDeWSfL6ZQ8WGxFr2n1RRyMF1f2L9hkiTsSxdMRXe5TuqJWt7LiIdGXQFW43vIwT2bfAghK
# DATA SZiq8R8afjiPg9cmZxwXPxuDglhuCuMOsCzsl0ix4i7Z3zs6Pjrc33s+eL739fGrs8HR8dng5GDv6dclxSjlwPNgOcWiWeV5mi6q
# DATA 5vibzTctFkl2GCojYHvIS7XLcTos6xdxD21+XKq4YpDvgqphDQeyv8rwJc7CYBabN5HU56XNb6K3jfYd/PmkxGm3NfYRy+i1JBtk
# DATA txM8yl2u8AWcC/0AGBf/eI8UqDzANAUveNoDZudvYZpn+Ho5y7aACvCak032YpTgkQYv/7aYdLXJawRpkkbxbj3t4UkGfpDtIu9A
# DATA gQTmzSB9TV8rDmFJRxytyOtBBkjVDjkZRY3K6hcVHdlERxYapjX8Txvszav4zflO3wpf0zwALuv1PJmIQid0QgVAbKzashRM8T2B
# DATA j/3gkhCm6kzTzSt0c4wplEw1UcDYu7YUabLpib5xIXg9jNUsiXaK7HYZJi2X+GfSP/MH+UpaEzGv86kCUFzpSBK+hqdi1rxuaS4r
# DATA O+/w6Mu954dPB/vHL14eHx0cnclolndjl3wKZYIXOCjd5AwaVulCw2UaF5K7+5iI/j6QXh2d7j07GDw9ePn8+OsXa0Cy+syhGGuV
# DATA RgGHzyiuXcQJbJBgZQkmlAAF9kXZZQQl0Ry+qc3VYWDkAf27M/hv9+7PkBN8U0Ph4/CDIsNFsQhJ+/JL+0EU3aIKUhvSNX+bdH/n
# DATA 5vVsWirqQF8yucJnuIIG/4r9lSsXtjZrcLSi1OK+8CxhQb3g0sM+hK2fJT+L/R/5ff9jv1FvttUfG8Om83tX+fnB53v7XwPdHT07
# DATA /HxwdnwMrP/k84OS2ihqp2Ks2Sj1vAv0syQjgFlmm99FybnEOz/mnB5H1HuhBQPQMN70bAiirLgnvwbkXanNSVSUPubVzIkI7sFB
# DATA e04IryPsk4PPD0/PTr621tTAWkNTCFQV8amRAlPmsSrcPuDzzZi3ohQf241kunLtV3RakqUgXiIKzbEvxuIYL0xwnW2B3KQcVZO6
# DATA tDhYFj8T9bnQ1GfAKV2MfYv0vstRYAX4tITZ1TzF7/v7PIS5kyqZCip0oGaRpjV/jxl3xLWcsFJMtpCSJsFU+lLeoaqPXhlW16uS
# DATA Wc0XeKEPgKufWlc8ZYsUDVXt2/BMPralutquTeaaFVJdBUxk0h9TEqsyw+DZNN2kgjAzvDI31r8BnJuEiKXKxt3c5Gxf/MxkSUDo
# DATA ald5xdd44yyHj7SJlpNZVtavgnifYhmcQZCFSbJL1gG/yh6ogbLP3tLqyakW2ArWV9wPqoxbWTymFt/estynRTmRxnuUE44Oad2t
# DATA AKWSBpyhiK26DjLNYEliXibTN2T4lSqVApXRdO9sfJevrmfCK56gR7HS1W2zykdOj1+d7B+sY52Gp+j1/mSXQrWgV4nmFESDRfxm
# DATA UYbHKeozuxhc3exLDzO8IH1OqU7ni/R1LGVj6RNxGIziRWj1zEul0vmff5NtlN7ePalefAJfq9bA7Ir9mBxG/Dr0U/o09/3cfGcG
# DATA TduRRr/Pxl7j/ni0/Y2wWf2foae2Km5ay2PrgASIPLc9X1keKMvdrffVvR5vr2gXPMIl/Tt5oS9EnxIEiNWxzuHJc18hZyT6NW7L
# DATA FSPF7Fc8Wb7KECo5Jc4aRr22yzsznetyI+zrENMlK9g4Oa/HiufjEeqi9VjtYA2pUsJZCt2jn91n3elGzkqs6cxoizK02Wr3DI9q
# DATA nMQRa/I3RNFkjoribq+oeeMXQS5xgbVJPwWkUtYQwpaobWmOw79ox1Xlw9VRXmWxqixmPRc7SIzekuUTsOhZvy0ftuhNl6vPi8yX
# DATA svyuzFqL3c9te+axut9ne/s/fvVy8HLv7ItSJQdegfW9xt6W9uEVtC1TU1ENtZmt51kusTW7yapAoXHtvLwChYjGhI8snr8t0Um1
# DATA HXthVfLejgoF1yhozL/ykuddqCUcQPVihCL+6v+RDwP3endrdqK43WUkzulRMwcFHnSwBCuHKhvsraVg7hANGv6Dihm7fHd4hncV
# DATA YffXbDZcqPIXLm/kbRzTpXcA28+SWdnAV+Wu1igAeQpbizH/o10e4Vyh9+IxyoFoBVh98vODp4Onr04Ojz4f7J3sf3H4ZV5FKPCj
# DATA 2F4itzHhRJknhkuxh9//DDjKgSptsIosZlZYnhNYHPVUKRQoNHbBZrtXtyIrvQh+NTeXpxLOmKlgxlK59O7/fv83737x/q/e/+27
# DATA X/rv/vndb9799t2v3v2KP/76/X+GL//9/c/f/xW0+V/4wW/f/RK+/vLdr+HvX+Pf93/LCVhIXsoj5USpVL1GibCP42C6nA2MsZZ3
# DATA aDrBnpW8CvTrZL7O8kDrkPk06c2ZoVxX/XWdRQ5/pATmFRsYGYjyy9Usc2MdQX97C3hFsXa74nkVGscsUezZo5b29uOP2c61nGs7
# DATA Rd6xu5z1TLik1TBK2sW9PgkeOo6nKzY51x1W5oxrRlgWznJKehzm4LPZbbmnKfeQPW9mInjCpVDOFSpfmv35uyavp8Cblze5lXNP
# DATA v04KaTx9nEP6IQ9sxUr1iKfkFdAjKWfuFE3dMdhJ+d1hkoIedIl+K+/neg+uOI7W7BUnrGBvGKaEXb/IreOtUoRZ6oqz1L4iqgLC
# DATA uW+een4UWDk8Oj3be/784KkAR2H1Bd6AdZ+zt6qmrKF5eFfArKBzVN65+51vTyUfEP9ZzQiDXi14xGRAzNKU0Ds2jgpd198mCIR9
# DATA kfgxs/2+f/AGT1cmC6puNJ8G4y2phmiUEc6roctxkjFf6sIy99sjrQgBOIBMV8efeHVWMIDNjG4WxdcKZe6vj3DmmwCfpfomTvoD
# DATA UaGd/SA0qPIJLpg1CqiOjmD1wo8dbNzvhuZ449NDvPrj+ORr2ByDV6cHBsKi8ehucY2yBwMaZvJn6KfhTahHVE4XybAA2RVaAVbL
# DATA 143H7h6XwFF5XHJGHsEs5oa3Kg8AXX2/+5DSGTAo35qYDHpnU6VCAd5CGk/L8pU4IH43gNGYaNaubtHS+d7mnwWbP8MTYObjoLZ5
# DATA 8bZebTR7d6Wq5LvNtdNGKUjWAI8RGi9Pjv8ElhAoBu+BMStJ+fa7foEbmB9TaKc4QUGyHn5vvmInpwl1FRunP2T1heErclo9ELVj
# DATA rQ4vZdGo4Xt21G7iIOpuLr+Ux6vaUoibS8kHK+2TGd26hueuq/iCwz5zYQkoq5kyNxVlAqsriW6X7wLPat++xHsdqJ81I5zXtS2K
# DATA SR44oON0rjKtGySr1FvSXB7KGLkQzYFjDvm+3Y5pTW3HEHciO5p8I6sZAiX2D1B6ADkG3KyI9a4Cfv+BbIFKgZkukFhqk0Q6lbFu
# DATA 7ZN1b6rVc1/kb/e/icUBjVcArSpxCGCSN9bzSeW7EBcW35HF2FEYRWcHrwi1pU/iNFCnabjIhVcc08iT0KoNJsDbm4RlI3tKPRM9
# DATA luHOlV8Njw4G6IscLFLOdkfaLed8/pXqfU4XFW17Go8CuncNbPYxXiOgixniL3NVGhWPEppjD+wQoetQaisBFTWxabxczIPxQE1Q
# DATA 9ZfxLM9J/5yJO3It3uwA4+8TE+toiVw8ORrUcFSsAPT8dqA5vkUVCiuPiDvv/J5Mbkk39Fetad1kCmgaqHYF5zNsLqwki3nlo92i
# DATA AEEOLcVrRvY3LZoJGCqnnOW8lzJAYrUbt4coyrDOyqqxuIAcE9w0xs2qky8nkHGjs0SV5Eb80qpj7qAlQW005NRGFwXy0PW8KWCt
# DATA HQ7qt7TJP1K4cIIbtmjQtLiz4vHzlTUmMdJCN2Ux4NppuJwy9RmFwNkn94rcKisCNpXdDIqUJpG6lZVVUS88qCpJRrfrdyGenXdi
# DATA rHS8nGnNCky0TH8ZLpNxxN9mS85KpYrPugFl6iJlyEjO6CJFHjt6pNW4MAbljun9g+H6WEZ1/bkmU9bN/TVQFL62GnrlflYJRSpF
# DATA lHXrc2VFXBRaEOf3WQ8X3mr2lBxe3bX0ID6DX3TKRPJ81gJzML1mSDC4CpxL2qtR7m1uo+S8dIj1wdlHZ96WH4sPsBR68ekCw5MB
# DATA 3bx4ePa18ugXZIIBnxhIcNjXgJclu+cIozUg6eTr0xhvNZYUH0lWt/nFmji5FSPnODKPVwAMks/vCsxDUfvHQ8MOHw3QR7s2fI9d
# DATA jKfH+z+Glfjy+PmrFwePWRCljBsbGw9+nypSLh7XsjFk9mR62IQVldyza0piVu3TSY50VQZHoRQQ1UP14rnL+GGSX/tzuC/7vIJW
# DATA bVbvqMi2SgUS5oF4R0Inzhe3BaQHMMvcSEqZJGP1TtnMq1IU1CgWZ7rjqoWX4mXXIHzEMBSvdU5xUXEN/XZhuugayUtBONCIdh6Y
# DATA xHr43XYMU9Vfkb5OMzkbr2S0I9PvDwlS2s11XgI72ldeMBZqBR+ulnEcm+oP7NxXb82/V30pWnb98j16kzNI8TLaSlzVL6ORUsWS
# DATA LHHFUemKN/UDmhj3aXW58rKrlaLVVJDgr7TU+xP9das16uvvwrxy1OrysBUr2UkhcHfdzu9B8VWbx/JjPEbvXNU5lRb5gZreB+uc
# DATA 352+WXTCbKWhic0b9TQfVCqOgmhGpM4keY+KGtmNJVoiPXke3jQ4IPkxGJCaMRigHB8M5Bg3VW2Y06EWruBQ25tfLjGU85KelKNY
# DATA i7DdwQB4yWBQsd7EoOcgkFfKgEgEDwvtgmKz+5LYtdx+ElketTXv2mdIwqsUkbx7/pjjIRf3d8uZCpsmvyqgmnq7JSr4NMBihcq9
# DATA O6fC0dIR/cGuVJKjw+GJoVxmNZUIId3naHQ1S4Je4lXk93UgzlsvC3WpAhNPfkQ/doLI//XuF+/+/t1v3v+v73717n9gXsgvMGPk
# DATA 3f9895t3/50TP6Rs5urxGBGGZaNQVv3jU/nw4/iWPq141k9vYcKTgzd4APXd//PutzD2X73/u3f/KDD8Awz+a/j7S//9f4aP/4Mg
# DATA +Qcf81H8d/8Ev/wDJqi8/98oReU3Nf/d//n+r7AF/fpfAXZo9lv4iXqCr79+/7c4r/+Xslx+jTN74r/71fu/xoHf/c/3//XdP73/
# DATA OfT1L5Qho4Z8/7cyIKbO/Bfq61fw6efv//f3f/P+r9//XQ3o4t9h/ZereDwjkT9d4PWypCF+x/c/dlvNfP2fRq9d/0P9n+/iHxYo
# DATA 2yBPtqTjbez4G63WsDuMhp1RuxM0hu1Gd7jdq0dhvd1uBfVG2IqDaHvYCsJWMxx2wl7c72+P2o1mr96oB2HcCzYw/3GDnMYb6qKe
# DATA DblPccPc3LNB1RThh1ar3+urnMkNA0e7t93ojSKghmAYBfUwGnVb0TCub/eC7qjZgLe2w06ntd2JRvVeuzdsxb163OjGw6DVHQVR
# DATA Z0PdfkP96qtOi0DobbcKAOjGcSNoBUEcDqP+sDfsB1G/F0fDbrO5HTa6nWEjitpBo9FtNBpYyiqImoCi9iish91+1I9cAOy79opg
# DATA 6Hd6nQIg4t6w124HTRil3xtux6NO0O2G20EzbrVDmHDUbnZaw9FwFAVhf7tfj4LtsN/a3g7aw1a7sT3MAVFQ8KsImEav124UoSTq
# DATA d+qNuNscjmBRWr32sBt1426r0261R3jJUlQPRvUm4Ky13QBENEeAqzhqNFqtXjwKQxcaZj+DIV2xuQ6SRqeQOrZbQBnb9VY7jrrN
# DATA oNMZ9urtqN9oAZqa3aARNvutUa/Z7Q+73SBqdWLATLvZbUfbvV5jO4xaLiR0z91AhPAaSNq9biFK+sPtRjPCi6XCTjxsRtsA0rAf
# DATA dbc7vdawE9XrzV7QG4b17nYTVrHf6YTbzQAaxS3YPVFYAEi2BoLtbiGJRGFcD4fN7c4oHMG27AedsN7vAi30+sN6vdcdNhrxcBR2
# DATA uk0AJujX+0CqYb3XGw57ve1OmNsooCoDCHRctBiKVh3mWgBGB3A+7DW6oygcDgH5nV4j7AG6u0G30W3BlhjWgxbABLt31GkE3bjT
# DATA HAYN5CxxvF3vBnkw5j8bBtN1VNFutItggHUYtYbDYdDtdMN6fXsUb4+a7V5zFDbqo3Z71O8gh+rVe9vbo9FouB1sN7d7/Xa/1Y3b
# DATA 9Wa36cJAt++NQMu5ATt6DST9VrOQdwR1vKmrtz0EThFvd7cb27As7VEPhgSm1RptN+utUWvU6LTjxnYjAo7VqPdbYdTHlv1uASAZ
# DATA GF3rlqRVvF2HMOd+P2i1m0D+vbALk+7F3fqwA0DH2/B7q9MfAgdtNoaAz7AftIHvd9qdZtiOYGv11kAxCIGXjdPLNdAAoW0XEiqI
# DATA ktH2qNOJ60EUDwHtvX5/CGwzaoX1oDtsb8eNTgdYyDCqA6Vux/0uaALdoDMcNsIgbtRdcEjfH0hOZrK4Xbdt250i/hFtRw3gC2ED
# DATA /tfttNvdsN2OO+1gFHc7vXonbkTAWkfbjU4MezSKmo1+vN2uN/qtXrMRb0c5WJRlXAxCrwU8qQiGOIJd2ACp1g6gTTcMm8CrmsC8
# DATA miEwm163PwK+AiyrGTe3I9i4PXgO0IVh0AJxlyMSLl46IHG+DheNIiqBzdDudBqt7TDstOJwG6R/q1GP+w0gnhaIfRLzQLDdzqge
# DATA N+v9UasfA1tvIYzRKM9Kbatrnaxrw+oW8vQmytgYBg4DYBlBE9jGdjsKQLD1ulG83YFt2wXx3u62g+0WyLouML64GUXwUtjorAdk
# DATA YK6xXLdG9UKS3a43gnoc9PuNYNgGLacPzLYRdRrww3YH9jZgBEh02Af20uiFQTiqd8MuaCDNeruPVHwPSFGKFvY6Vg9btGgHtbfr
# DATA HUBHPAyBfrsRSOFmIxi1ukCksIm7gLbtbr0L0IGg7jaA7yHUcbvRa9ZhH92zVKZ+4TqW2+xvt4tACkDsNFvN7ijstWGbtDuwPdpd
# DATA vOoQcAeyEHhQsA0LFrVGoEn1mq1gFIAohjkEIC3uA2l2jyxsbre7RYwXtdJWv9+GEUegPXabPdAaR0As/S5ojSMYOByGvV6zA4Jq
# DATA 2BgCtjqwfqC81IGeR82cvrQYr5XF7X7hlm5s94AoQNyCaB02mh0gmzAEpTkagVSCrTvqgwIJBDJqR804GG5vR9CyBQJ52K33Wjl6
# DATA WY5uBpfLYB6t47RADkXCZ9QKGi3Ysp0QNlHQGHX6oPEEIIfDBuhJoxGsVT/aBqia7Qboc+E2aNJhv9OAfdWp93M4YB/RJqzFepWg
# DATA Awp4ASD17TAYtqIOjBUCmUSNoAMcoznqNLcDYB6tbgBYacJ6tOt9YK1AwTFoar2oMRr2+1Hc39AXHxAwG3yxExIjfb3me3eJCmvN
# DATA WgMF1p33vT/8+zD73yjg/wb3f3dBO8vb/6CL/MH+/7et//sZ1ooIpr46dDGXhDcp/4ulg5LJZEkqR9VPRyOqkcb05Icp3iN4X91f
# DATA vp5TfYvn82mqvlz+LJmpz3jRzTgZqq9J+rsXB75aLpKxrg8czNFPob/Gk5n9nUsGY37Cyd7+Gd56UeQwK3nPjo/PDk4wOaP0zfT7
# DATA /snBi6O9/VenZ4MvDp6/PDg5HXzZ+AaaHRw9pTbf9+HTYF2rvaP9L45P6EZzctXiCbH5cKP86aTy59xy8Nmro6fPDwanX+wBn90t
# DATA 2beAlH6wUfGeHT4/OMV0lFJ+g5c4z1N0VfxmuyXyTvOi3xw9wb68uGQsNnxHG7J0e+RYfcoJE93Ssr2VC9+2vJyBcoruCoQza+T1
# DATA SuDKU62PEVoKHCX4u2Md04QsEc13Wq5YJXpCYsE53y1bCn8XPxl+1B6rUsV7sfeTwcneV1havusW0aBHuODwrJl7lDtZFpVxsVVd
# DATA Q6zMHcUhwFF2KmJIZIieqytOhny5SZUIXJepk9tKrE7lXdm2NTniSw0wo1pdlivvi/gevI7Vbcs73tqidCWqNaX+U/50Z9M6/YDf
# DATA z2ubF/ZPlY8rn5ZUjPTeMw5yf4EwL4FKF2fCfP0B3pAQq+s8JFETwz4LujqyXNpUh2go92KU8BGxxXIGmxdrjGNoBSO8UnoR6xEl
# DATA GaAD6zly5Zhyg+sUVbz7qg+os5sGGlW6s1bSXTvryDDgnTQJHx2b26/grb+I62GajsumU/jVmokulQ2kQptO0MkSYdcmMH6sVpF3
# DATA aIgpTWXmkRX/R37jvsV4qm/mk+UYpekinpszSsJrsejI1Amz0deqtPflPLlMVQbPlz3ktrV4GnH2DrDlB3OMD83tTEUQqoUicZhM
# DATA 5eH5ziae6sH+LxgkfF5UQhnBKuNDO6sIRcbTvbM9vyQVFO2NgQ/39/a/OPBtOUAbRH1vNe9oL2C/lcpjTta/msZvZnxviDNLX64q
# DATA MuuB82KRpSvlMBFQZuG9a/1CLmQ0OoaMFUxDUCBcfsTLOcfLw2dlZkP+J8yPhD4VxA6Nyts5CC1SrpzXZUnKw43SRuW8caHZIhWH
# DATA 0uxOJ7TcMwAIFOimWExvELz1EnDnbhs/w3BVe1eZOsmBqp4yCd4kk+VkVzF5wyEfLLiZP1q+iv8vGNt02gErhmFOynIczKmmgznj
# DATA bx06R2rkAdIZrHsJiK/iBxk2i4OJGYuuwNuVn+kUQllmAn02HNoh4QBcQZ4/Al6qdbZIU3+MmTYuleRlnb5ugetklOeBdckCDo8/
# DATA wOitZq/bfwyupKOV8WXG1jk37Fkfd45FTOKeeFtiM5bu0BZhU8Uq/iYMV9K1Ou7oulJ49Vy9dfHgvno1zZazGWWjqh2l4C5V/vUl
# DATA LEOnZnLx7WVtMVSOdqtGc5D1QUOy0KILx91qL9wxY90p2WOVnqKnqvKU7DdcW1K49alCLomijnbKN6Sx+8HMyxW2okoVz02VUyoA
# DATA n8pZSRsrRiKunjkhunkBaww/zW7/EjT8yl+K0vmXrHF+AypnRY6OPkIcOthFoKhmzoqstbDIxSo0EhFlpLbI5tA7gLxLvAMepgvs
# DATA wVSP+VC4Vc6sCzcmJ5W5Y4YFc7IzOXe4UHDV/R/6TiOkA8WwPxAOLJRndkO2nLjDOzogE4Cq24EUJlbCI/gY09Y6LopbwZJFXCle
# DATA EsqArVWlLJmUTXTk4Ftc/R0WYXR6Xldn4tM6usgZnS2XAzxvi80euWxM0h5Xq/TYZ4AcDq+38Z2yNOS+urIoiTQJu3KRsG+nF13x
# DATA l60WkhRYp8hVM4g/c4u8gkDNi/jV/XzAdbggnhyG4EcpF1HDfVByRIywmo92tcDRmLj/PPOqtscXi69hPU7PqyxIX35pi2NqzUdW
# DATA Kiv15uX+S4TcpXcLuSttiitFrSd5dTXjBO8rBdxZF52uIX593d4K2QD7Muc5ZOr3EJkpHq1fKki+XekAN5H1CmwC5YuqssZSqdob
# DATA 1GpKo1fyxTGkFKKBYU39M3OkW1YS9+jHH8vMFQw7OMbd6vLrc4gu6M7xO0mZ5vR6WuyyRStqrSv59qoKXBdBFa1/MoyjKKf1W0p1
# DATA zm6UM+M52zFfge8eI7IK+ivYCLZFJ8YwDhqRg6/E91yiuXXe27koMAgdI5C2wXqTz1GO1DCiXMhXZP7ddcVV1wsdhbsC6fOzRE7i
# DATA s6e2Nuy2xSqSIauaXK18XbIP0IFb+xz+g8eXad+nw5/uJmntM1znw+My910ptByApHKGg3J95Q0H0dwfIfMO3GlmK2JPqYByZplm
# DATA Ia5hNnQKJoHD8+mC3dJ8h80gycA2sEwQw+QKUhUHgYrlx/IKG5QHpCu2HuJqZzAHEFe3+UXMco4I7pREJHdf6HLgZ2A2SqVf/WJN
# DATA SvdqL6N5okQvYw9rjGyVzDg1XXnkm2/yPz/OA4HXjK+QqOCxlD/pgsLFGuHCQnn8hnz1NDNuUmHKUjd03Ay0WbcrWtUsnZUVn6us
# DATA 4+76NYfNq6uaVp9rlWoaxfMimRIGIKTsangPiZR0uZgt6dyAIczKAzTM7yjSvVlDuYUyQE44PiQK8l6t6Sjlg0YEzFkwP4Rfyqv6
# DATA HDYkeqvyR4RQfcSIhb/raAtVHwRBuw1/io7lYHY/LTm+X7UR5EoXi29rTse/lYmRoVU2j7OszHjDDUwqN1ZUIKh267qitggNFhS6
# DATA ahsu6kP22YOuO+rlQ60aesnP2WMC5icciWLPIRVEwcY1mbpyfWkXW/5NEXFGTOGNvIzK8wTo+80O/Re5dr1+obph+4Ue4BGoYHoZ
# DATA o3fclmRVfMGtJ2lJc+hIQYFBNKWncf1yjnKJnULt7b20zlutHdXKtDO3LOiCFdpDuaU/1dCBwAU2WH+paHZCsTuxf5y3SwUanCKT
# DATA nAGj3Smo7+qevjw4OT08PlIDc2WPGvtEH+Pqk16lkBhHM9RvBWaFlos5o86y5j7IhHMxwXcHPcaIewwrtN3E9lNFInizNlXaUOeZ
# DATA nCqgaxbYIRwiQ1NWxVn17xpT5HASxMj6PZZMbHtXuyIxo8Z4I3dUp3m35M5aU9eteawLDQs+3pZWOtBMXGy9HYe3390rgBzXV+Xu
# DATA ztp4Zeu2B5xkld7BEKO61wnZz3Sx29SXuiueJ+WQV1wAav0f6eK33AW6Z+3tt2wSPrVtGUDWs/tZR8V5jeBUN0JSa7VF2F8gsmPA
# DATA bJGlmPLZGF4lvoU1/EmRt2Vsqs41mh5h/tKNbFzmaF42UFl3vFGc+Zs39TpHukybNXWAHikCzUk1dXGS7pdN4Huu/hJNCezjTkdO
# DATA 9ykD13QDiLPW3XuoMM7KCXDTuCiks7b+4qPRcBlPY3XZjZe7dXXV56APUt/rblDlJ11PgzoDqM/92YcBC84Acgmul6BixfNrLrQV
# DATA BZgREllA13ypFOdT4kgGu/RWrrqhepi53iRJCXfYE19yGOgKBoAXdF1YqhEV0VyYHCZDIrWC8kX5tS7bPsH768eJvreeFGLMNQqI
# DATA w1A5MJWEhJSJnzEsP0re7JZqYuBtYhQkme9aG6iynrJ+R2eOrjlu4BR55DAhxbcf85524rTbbnvd1FT7V1vu3tIJaabP3qseiot2
# DATA CG0KaaLdE+OHwpua6UmNMtOU0+gtfasdHPzk8BS2hHwDEX7w4uXZ13f3lFhZefJ9f29Kdy1ZwW+8vmm2HI6T7Iq2QYay3uwBdb/o
# DATA VZIVdDebpyFYKXgYn8qHLGDLxEtgCnyln6+CSyqxA4s/SJpe0ex/F2Z0P0MCSlHH3Qt4E9dDIdwXXRD9r8uqCutj4OQ1Ha4vkOA0
# DATA y6PJPJHbK8w9Kh/ZnMT6XSFXv4n07FSWMdv/0TgXH4ry7gFpIAuVTLuCSjCcHFmbTxbz2NpMtq/BVT3WejKESGjDO687Hlw7TYle
# DATA 0OF6MC0rv5fCA+lM0ZpdOgCtA6qnhjGCUlXrXQ8UDMjXMLi3MWHp0a0l+Pvo5khTHwYPL8hq8wdKG6hqBhqRVC2CEGjIkqwtXXdA
# DATA 1Ohx8auMc+tdx5hf6cQueMAlC5TWS00lTcgy0HTVA9ZX+YulETNIrBZXHi6EwbT5/5NDBvnU2+8+/7/RaLYaK/n/9e4f8v+/i38b
# DATA GxsnMVao8rPljC6siSOrMjLncEst6wCdApgQGkHjEJWN0XJs3017T7o/pet/QJL+cij6jP7lVn9En6vnnRy8PD49PDs+OaRMdz6R
# DATA JCVg0N9weRXOa0m6NU4XCzDpt8wFtrpMzMpP+Wub1vexWlnG6a/g5hXunEvT3A+fql6T+wV6uPP4NkSasDXXq8Vilu1sbV2CnrAc
# DATA osdad3uSm+OdM0kDzqO6YDjuvMMXe59jbcDcGQXx8eyc1ze3g80RJ+ZUvKcHe0+fHx5hfjrFV1UQZJZmCVU60jcamMy80h+XnCvf
# DATA ViK15iJqyWX+4xIFZlWR8nyruTTb0c0UGED9wXiA5bLLTO6Y6p0uKBti9RYWXV7HunOIXkNw+X3L1a9TqDFCgw+5mONhxLco5mMC
# DATA Cq9WZMB0QSqi1SPfK8BwPnBLjXMbatkC5AQW4Sy4zEx1z09Wnj8lS9c0MRV7b9DneA6dS4mzkXtLH5dItFeZKrvZG/dco/fiwkYG
# DATA dJ0vInx5ScXMpLuEna357i046IASE5K5P/Au5ycg3ocqMZpbZA3gSHQVrgW6H4yzlCmFLKtMXD3wexJkcVbL9bp3nYKdE2Svseen
# DATA VFQPPRLcAZ6povegI/+nmHnLv0fYcTweuZ0V47hwbpwY7uJDnhZg76KgaJSqzGgRHaaM4wmPJFzUkH2jGxWvMq5UbI/PWMe01Nrv
# DATA rLkN06KtR16ykc4vKXxpLgepcSdyHem6OzRh2sIsLSIrujdz7czPzZcLNx7FL6lDMLTA5Y9RjaySoBuwMpnLjkO9ke9NaNURTs0W
# DATA nXu99a+bJOdqkxQQi572snWNjOrqh7t+Pe8KPePikMroJtYk+h3I6iCiNBRQj0H/jcxtLOQ62LXkbm2+nJbPpSQklrnD6V1UOYlK
# DATA 3KJhMFvgFcoyXf4RYw3qI4OyOwGFuVWvGsArTh6HGjFbRNCaMlnaj09lkf0FSwJrDM/QxRNHmZ7zOJkkCze70crRzo8NIFkryEvi
# DATA tpFVHyJ3BuuCsy/V3XV8YxVf0+kEN6UZxzbNdG6TeBzxYSKs5w9v7vD7HDWVsbCa34BlizKKEyoAL6RXUpUKAy5NqEuBO0lGaqlZ
# DATA Yqxc33Y5T5d0A4GaGQxhX5qnXtS3T8vYYHxh5mD+Cpa3b2tEe3eYmvsxde6C46yI7t29MrBsFS/kKplSmPZ1HM8EOLw+ANi22jf0
# DATA m6Vx5DcRYrZZX8GFg2JFnNaQlnUqKYGZm+xPnlvrBSfydl8utO6PWe2DEf6XUtHfqkuuukBOkrCXzb5vNb9ynDypCnfbCcUalvXX
# DATA 4Lo3MduJ3BhSLlJg8Kgbaz0T0ZNLFesKci0zEABc150HIY9yYGtSVAMYmtS9u5yZEtaKDuwVSLuV3sfFu03VCl0A5wxze89leNaQ
# DATA dBwOrd77WJzO9BJzDOc+TJdTstUcX540cLTTgo1thrd0VT6uize2gSC8B6W8mdfiU2kzu5KVM3K01qqjH04/WP1Wntf8rv7Rrt70
# DATA O0VFLU+0zBQUAePBzRPtrBeO7MvcBcsTWX88n7uqxhDavb43oOcq6wVc/MFrxL/va/E2gvcRZZvo02eLI4rHMVqYT4Cn+FTGtqrY
# DATA 4QyIkJLvpPq7q1WurO58QpVszV32Oe2Ql/STXb/xuDCfpUec6o9FgT9ZHlZTzJrIrMN0OeYL6NCNPb5VKnSyWLc43N+otI+LCiC/
# DATA FdjvbP+GNmiFGJ7o+rt077hisDlKKVW+jXP6g8vY2ubRh5TEZdmDkUG+zGhX2Zdr2iOrtQrcsgJsva4svQe8wUpSu4Vlxamqbjuj
# DATA LySz/4O5V/99+H+z35Pj93H1X5q9Rsv1/9axcuAf/L/fkf/3S4mq6nxA4XtykRc7XcVHgurWIhX2fJ+/N1e35V73b9V/CVbkyzRL
# DATA 3qzxBlu+X6nXYtef4IPOpHTLWS72zuzmy1BYidF87xrp6fcfZKbEpKvl9DX59xbA0cfBZBgFO84RBctWrWCNjHyEliFSaiz15x45
# DATA 4ucFFTJUyJtDVYvgErhpBpabUt3k8maaj4mSWenslo1CDbZUYRa+DGTVTBnD4ha+p7n7JrtY1ndhZbPK1ZqcZMgVAegEgfNYKI+f
# DATA wxzvU4bf/bd3v+Ta3qqQ9z/An9++//n7v373z0KZm+9+8+7v8Qr7d/+EhcB1JQ+BP7MO+uWuoJbLP+0zdeaZnE99RJn5uwdnQLXG
# DATA ZQZUehwLkP/mgRlQ4jTp1m+D8xKldV/s+AERaYAEyqTBc+LP5iKhQJaCruDkm4SWM1xgUG3MVX2WCJec6KmFuNX0oFmCDkqkmXPG
# DATA h3tPOY7CP5MrRXDn+Ho5YEuw6dPgdKFMMrWzoNO53RJvdEgWVkP54cGzgO/+D4VXrudOWP/N+78hksJK7vAJy7+//xuqCf/+v8Dj
# DATA f6Ty8/8ML/0LHxksKKAvxGKBSMcQ0I4B5qbulGUCCiZRt42EE8wn8OHuQZj/Gxae/w0S+bu/B6pBWH7DZfGxLD1QilWYHuvdv/tn
# DATA mMrP4fvfroWXSAYgrJroBcF+noP7ojgjTK47G1lBqrd6lLvNt7CJ7zbBmlq+2XyLHd7VgHPXLn9WyqVjzZQDZnRPQMzqeectQ6kr
# DATA /12owXiY0ooNZhzOdHEeLYE6mWQ9ZFPIOd/7mCxLmxvBQsAy/Ordv7z/u4Jd/ItVT/U9d64/Eh1/LBG3El/Nnj8Rb6anL9xk98uH
# DATA To0Z7S/e/SN8+eX7v/bxD34AMoPZ3cuzHn/sxYXYVAHA29KKKwCoeOPaTuijirZ98KxhS/2dT3vt1zRRvh2Cf4a5//zdv8D//eIR
# DATA a02smC53If5NsHFKppI1xh7GVE/aDwUR2bfM0883TJwHNsCWiM9sK0pvpsjRt2hL/H/svWtzG1l2IOjP/BUplbcTUAEgwYekAgW1
# DATA WRK7itMSpSGp7i5TNCIJJEi0QACNBEixWIxou+31OKZ37JndD7MbMbvr2P26EXa52273M2J/geovzC/Z87rPvAmAkqp6d7bLbRGZ
# DATA eZ/nnnvuuee5nNsMVJ0hczweXsCFrqWqtKbjvpBTHsKHepdYtZg74XIK+khgCM5FDtmLEWI6EX8mhPjHb/4Zfv/HN7+JAMI/p/Qj
# DATA P6MsIIiJv37zi+iT3uTT6bHvwF0sZbXmwD6uFJGrbEdwoCKH/JkiOKhganfurL3VfhFkwAn8eAaSCAuoGBLlrgJr2p7k2T4noQ+S
# DATA vHLD5/hm8IxLVn4rbdQ64zwKzPJ/owPxZ7JInFNFcqBEsFC8R2DPRNQq0MOIW3VdKdRwD23W68jS1BlxpnLCzp1Mh/gsKXBlg2HC
# DATA t1KOHzpUvNARzV1xTsicCOLS0XDkrMfVnTv00fGKkYForoQysBLjob8pRsTzh7HHDoX56I1x0zUU5gW3JHZBKNlwEVQFtiB9nGSH
# DATA KvEfoYCCGH1SqnJuRfio2KfZulftumjVcWbAURgYeM6HI8kPqqsNMyEXxA3EM3Hr7/IsDNBXe884tIJ5MyiOXBziI6f8+YkVm4xm
# DATA NUeR7HCdMieH71yoFZQa5prJc6WBWf8nGvWfw0T+FtkH4O/yrCe8+hLIyk/oHPqFBxJkX6HWV39tbUV86VyNiN7osIu97mVL/GQl
# DATA 0JiNM73A1dqa1SJRTPY/3apCoRDdsxjvL2ElmbQDkY+LHJd5gPG4Afzje3azJ90LxSCanpXO2NddZ2a1yt0vOguKsfjNl8HJw7xx
# DATA rf4d8RW/jjDTFpJMePHbN/9q8Q1IozJHS7ugQ7+w5o5MpWR5xuePSjQ072Wt5Dgb9qcTMUaPazUywaKvGOgyK/DlV2doSYcQILcA
# DATA K06ACiqwOAMGFxpiIgE7AF7Cfv6O0P+nURCwP4+D81IzyBbqGs+2L/EQw/xjsJX+BjOg8Xa6UefUI0rcPR931C6yCUgoNEGsZRJe
# DATA nlZhZ1Tt4TiP5bnKKmxD0IqiGPJANJyG5jC3qqyjDC/JQPP7TpXOy4EyDMLom6RBoUMhOXw9Ozq6weYjAqP5FKSGP8PD4c0/4Uaz
# DATA KKimub/BGw1tS8XCFF5o+IAj6lgUZ8KamEmnnVtTu6Hguha08/bLK/eZv4RZ/xMfsF/99/D7F3NW2oR0soZsR9FQhpvWrcATvyoX
# DATA MVvMaZ0q6q42f43/My4r3slgWf+SJTO8ad/itKG52TyUJfc0Lsp8OLrHp2jES/IXtdX2GfpB9KgPHFuvbVS4KMHOyNSQ+5JDdtOY
# DATA cnScUpqnF/Ews7r9/vCCZYA+4CoKlPq2f6TtXsU8tn507VgiqLGbHalfEcKRrYVcFKTnBYyxKCvjP9Fu+xfcXUVbTzFqaMfRdHpe
# DATA yq3Llc9CszHIlsN8ApcwzPS3Z5lw6LRp1Fu1h67Dy5ol52mnxMJ9d0Vv3779CEdEawP7fJr0idJ35J4iVvIDpduYnCYosRDvNjbw
# DATA NNQVlSfumaCDT0muVxOPKM8L0PZXJhbFoV7UNCRK0RczYr0YriL3+Q9chTb+QrB/2LRDI83kOlSULnogKxXDcDIBv/+OQgaTj9Te
# DATA df9MuVBRIglbbgEBVRHDcpMAUYVHUaF1C6qJrBVHXYHLxeTbMbvFsBszwjz5iePdHk3c71i4pkh8pRk1DxurJCQoxcf94TEnQuCr
# DATA T4H9Dh+QC4ad8iBx04OzOe/gdHmVXHAsaXQpzGAi0io2Th8N8uLGrNrvhU3zGRa+v/tTkMPA6C21jzwbZc+cRDEfcpOtOIdBuQFz
# DATA 8s1m8GbLIceLVkkeaaeQAJOlihyxzbEijOmcfZ/utZPkZLbFk1aILtaekbHHv49c5K64bVZJZcW32LRI1LloYWXZ+rZp0JXDL9dn
# DATA aXMASSyJMy+Sa3/ATbBqO2hVrcS81pJx/D90HdbvcvnYZVS4VfSgGuHgKH4K9ZxQPZyMnc0RrYhEItaf0Zyfo12ebXRQ5sRuf0pY
# DATA 7gNOiScDcAsZrfqQUbs3f7h4YkSqiNilKVLu7PXbZhpQ2LKw4mzi2RvUjqcYtaWg+SwtbEfd1HzI6CusAkyu6VA+exXCpmIHNGTb
# DATA 1oKAInK8Up+0o/IjZUTBqEhUvzzH9pgPo/3LDG4026/hfld/S4tJJ5vR78X+797a+vpdz/97ZX3jD/Z/35T938E4GWS8KeFCyzmw
# DATA 4CBD76VMPDRQmpCO4QZrnL2BTiHnPJxOuCzFFYEiaPGe9LPFU7+1h6PLd0/q1juBweunSTIp8htXid3GfWSwOc6M+w5NrlEPS73L
# DATA Oxp/ZMqRUKWCv6YD+u0mjMNty1lYBnAsTtAJDLc23ZlbJDkDzsrEfpEgMUCY1cQ4QZvlDe/lNkNCQz/03PoCrnCmtkgD+wx2vPKr
# DATA gLMa1wI4xzaKqqKnmhgwh2uonpGAbEWdXnIyGAIb3WYJB3DKFGRmMoyy0+GFRgsiaYQWxLtOZSTs7Eb4IZpuqMx6JvpUiYYjxkXH
# DATA f1LCNRIIOaOXfXNRKW9cYQPXaRpjzxrnFdIfZ8aU86GxiAwBbUP+XGxF/hXVdm5iEzUzzn0wN1VPfgT/J1wN/hXlabmOSOGHRimu
# DATA EVswiY9KHqSCG9FwSvnxaDDhhqL4ka2c1GL13UY9UxtmtKFoRMHS69/4RhZw+XrzO9eUAsesA8PCfWvSSihchW0jLBtCZ+Gzkcyk
# DATA 6mshcpaMsXAlMn4YEtXYAhAbYkBlCmCeTGr7rZ2nzx5vlziu8aSF34yFLBb8VrQyXFmpFweiRxM2qQ2kBe/ZQ7rJpvC0CMb8L3Qn
# DATA /QeAI1xA+Zb5S7Ko+S1KjH6H2mRcFrh0/gogm7uB//qrn7C2He/a/8JWh6Se/9VX/yF2wz62BNZyMRVoOyYVMb6KGwYfMfgn+600
# DATA Ig72HJMUVR6jLxA89TqlYzyHmxUKcQUa8IIulBzAQr2FZz/lR3hcDSM5BYBmbdgCPRkUcXGDCXrJe+GwpyhBsQxjU3hDst2SlA8H
# DATA vpYcAogj3SEK0RXRyYTE5bhF6sgVFwo+7T/Z/a6LT1pSqovsbX+SL6K/Pt7Zm/F1/9kjr/1C+eriBBLRjqjSPyDS/dJGSdaIW0gZ
# DATA NhucMT6mXvYr3lX37rE6o3Dz3GBifw/4zqKcf6Qp/Tz66i+ZqKEB7uwJwXYiW+9/FmtdBQisBJSOtMsoLvol2uvCKzZwK1kd3F0B
# DATA BsLr5RcRZuvQJh3JaNS/bLnUjv+gDxld253jVF1JqEijIEsI8RFDlBgNM9YrcPlD3sdHFXz/rLX3+Nnuk89gr9IToNf2o4Nne/rF
# DATA 7rPvPHvy5Nn3JXSqfeWU/QHFurQ7TJ+OTrHk7Hlrq5PcUQ9KSMRRJVJvmDocORieJ8hKv6UbEpJkNcREKZxU6qY09xdsE0iGPb8S
# DATA 4wLECiTAYtmEpJeLWzyEY0RLKxqWVeToXQiqCHKOxGe+mukqAHC0CeqL7fd9eCwFoyhC4+0+cJdOz+Kxoy8QYp1oyTmQoW31OnbI
# DATA 9pwvQV6KZmETqxE5+S8LWtKOdCNtO5A0nunYRzIg4y1vhSXehwRjVnrVZZLusc6gorh1VkbMKlrmBErGd8INQa6r5CaZYfDnkswB
# DATA w80GLEQcji44CzajckYrh7A3KhhwaFjWTJZyTcOnXNvwzm7cWUy15zxB6QIczX8CCvmPxAGSoaDqG6srhjGPJWWbvzM3Dn+OBGcz
# DATA SANp0bqi7wyCJgdD7TCEJRippgMV2bUTawqUev5GrDrRj4vwc8CUEZX4DeseIjiYUGPwKzaXNkoSOlXIUP+fyJyQLAeJ9SbPkTzL
# DATA XOERVtD0VX7FGJOZ+S56cxijdGBfXmojVImw3DqFa6G6xWnfXyQV7qlj2WVLYYB9OccD0zd6CfdsjNEh926uRDqzxjJnnOE37GKk
# DATA 7Obx4uPeFKGBGg6RtI0Adh7ijH6lzhSgoHTS+DyCy/LFcNzRz3CTmL9yf2e8J/7cFpW4ii06OH6DKwrswF+wvTsfED+mE+HXES0k
# DATA MCLipYSs+ld/TQqmfy2+gOqwZUZkUSrh2MkzTy1TRaaHuIC/fjRNMa4r/uyOk5MzkzTFCYRUtBQSW0lFXoMCYoOi4tqQO2QrHZyX
# DATA UAArqbrtYDqv0kt5q5sO+aAlExg8+qGN4z8rfbuRvsYVOYxeTo4+LH8b8cA41kCL4iuDn+80a3f+OLbJKCbHTlGkXZJWOaIRclG1
# DATA px5dxQ8cAg9TAujy7CAatRo4fKQhTY2KqrFuPznJmtTkDO2BtI9/VN5jlfaYcql8mO9APjmBdaG6AHw0Hr6+ZGE3j8PZpJXoVW/Q
# DATA acbtpNO5jI3cRcO29O0Ht6wkorXqUdkFLjfH8C19O1dW9JkoWUT7JeJHhdfUNKTkp2sfDAf9IQWr5opLbuQu5CCmA7MMg9A6yPRk
# DATA CTTwd2wTMDUq9YvM2LHlh1Z6ITf+l6AMQo0dHU96A8fCXW06wRAEyln5z0ovszsU635MytqX2Yfl0uGfbQKuljbLuSCUlu0Dz0dS
# DATA F9If2Eu0AAw6frVKUfz499oRY1xIXwSsGJ2GK5Z56sAOHuNnMic8tKLaYEAHtKDg2BT5EISsfee8dkwCPnBiNFq7TsYCg6HbXHwV
# DATA s98pN4Kv5Ldq6Uq1lM9947pSYSySLrtU2SPh+gHzkgGd7wJQboL22xXJ0agp17ObRv6htqeQZPdQvhxV/ZfX3uWW4Khiz1Fu9jzu
# DATA 2LkEM0eaKJg6/+T5ezxU8HaJJ8TPiIH4OfIKxCT8hq6ZP+M3XyI38TuyTPgSOIq/hbe/pkNnnKJHRMoUZNO+xNBFBi8x7JhBAiX9
# DATA 5at/HxcHztPJNTH4TyWyxDI5Po2PJC0YNkI4JIBNI0/SWxJeC4eJjetMQrkE5blsPnnhKB1lWh5Hw7ObPIS+jigeq5Zk5fKIUeZv
# DATA lVSeuqDuc+mm8Ffx/hdPojOWeHmCWS33uHfvXnEHFHb92l4RGL3Ko9npKX8PvR5CPRo2rAOrthSGir4nyiGmOhqcU4g01IYTI1kx
# DATA uTdM2rupWDxSCeaasaI48VIo0lk8ZT6cmm7zkH85gWIPDa6RtNcMCG8EVEFJPbwQaHKocAw0AjKfYByM1ONdFOejVCLE/PTGwwHd
# DATA iBmicG+YcO7tLMARFTg1CJyQwYPqGvCHioHHJSHLL0v2ooidXGaUSsgekQ9+9SG2jAhoKUnKmVtWHgvyazgUk4PnyHVoWYzLs7Y2
# DATA huLg4Yvsk/oN5GigQmqHGr7euzYHan4QHZymcOJmk0hhHe6mZDo5HY57sOt656m4GQ7SCxzUprCznDuI9V4jDFM7GQ7zGTa6Sj3V
# DATA GxQNgSQp494JRaVtutuLFsSSoms3Pl73ikXXfJuPwPzx4KVBHFbrRxxGVjHBRQw1M56ai4Ye1VCDnLJjqhGkM9ZdwLR0Bd00eN2u
# DATA 3SCKZvmLUdQmf148Wq5z6JQ/IhN0bFZtUtQJ0KiQoEusQ/3SzXpuRUqNZSNxQEA4MH8IWF8ll1MjIZHXxABKWEN5BZvDcx01jZgd
# DATA pNLdW3sKu+vGFUmtpUapKA5aduF2FKDzZOhOLxPBOUZNRzFMAytbJumudZEok0tYVM1VrMviO7ExvFeBEXvAC41Hw77YftE7WIAq
# DATA 6cGnYkzoBBG1ZS/KBj4QofFQ0oErsUQlumPJWlA03muT8lmiobjfyUx3X5FJKnDk9UmkM09+bXNvnqtNb4+0yIgi92lj/hlUXIWh
# DATA U0JMZbiEvsi0YJY8BqtawQNUP4fKvvd4OOyX7Lh28psnvT/hVdCEQ9JrKWgjqhBTQ8S7EanuqVqDjDaAn0lH+KPEaGTr8pQjstbm
# DATA uRX4s4/nYxlCQ0/GTDiTGWfXFq+Bg0RiKAw0Ppq4ooq6Mm4IWn/HZwM9bobO/tzOQh7A8DkLVxGSUJW+a5dn/Tg/vtKMBijJY23y
# DATA GjcDK6Fp3mQW65co5zLMzrBwCMwjp61FcGq5QYomKnmRvZKmucL7CpqjtM5SOCsdab6WvRmmg82NSuqLSZynG3CYWFL1GfnsLR1d
# DATA CHMumSpauIyyQCQk6kwmqtQfTjvdfkLBEuOTNmJseUHrj59xFB4S02GgFx296bek5fnH6ODJPl6xfsUXInRSNzcg6KmjZayirFhA
# DATA HyJYd5qMWT4xRx8i6tCQbgOhVHIoRkAcja2yTJ5askpZORTJ+8BHWb+8OtCs0uaMMxJzmlhOi2NInplAg6wvmAIM+wiMkpYJO2Jf
# DATA M3vGL4n/YoS/C+iVtI1OEJRLnu2pEU5bALAbfTGmsMGHMcz9cOXoZmPJ9WZDGdfqMU8z35asJEvGcatIybJrlwTAZCHLAjCZNUFr
# DATA G/ECuWA5zNc4coAxe1B6u8/frP/ZxE8Iiz1m6kZq0Zu/J1H6X5MW9x9QAP9zKs7OJ6x4UnJ7jL/1G6rK74U+/IO8/KUOSMEg8Ugf
# DATA vCSJAH7kZYoVFAy9bGpouIQx5KKSB8b/RV4pf2EDga0ZKM6EMe9hjQKqpGXAx0n71XRk6QL5BasjZW9VnQBjc3Jhcn1JuaqyqqJ1
# DATA g51+1YgTiAOh045thijAoeKwiV41bIIZA5DgDfyLBkOM6A1zRhUkKL6mVDtInPUjMxYNYAXhYXSKoQkb8INPQYomxRORYfFDmQlT
# DATA 2u0ChcPrYVP0hc6mvBXeWBLNPE+yCSWu9NAdqqhAEAezEdmaOuX7arHILl8Mc/VKWAFsPBYZyoqOgGQhsxiYR1iMRTaeQO1QHJGF
# DATA 0QxeTzQoJWW1alzZgeb7VHH9X2MZohVVFsrPjkrIswlbHHA5DgyN7QpvUShmMdtRO/5Wopa177tw3zktKb8gPfqKf0RWZohy/LXS
# DATA XnesB28x8jddtkqBO9wkzQ4vDnrYgc9W4AeK+7j4CE1NFIVzBM7eoJalEwk4XYolVDlfwVzfZFLEoIMwVW6EE/TSR95B/C4ue7I6
# DATA KuHI6riOzg2FyknWZsa6O4cq5zKkEo4snyfj5X7v2ATpWwY6HS9uX/Z/aG5RU2aOrvdTNh/6R7bp1a6E2lDol2iICccUmxP9HPlP
# DATA OLz+i60F5rPq5+R+aB+DXyrNMfz7H+yYHgRjdam6itFTDInMcY/ig8eSd4dJn9mTsNvb6RjzREEZgX+jEDREc5NOC5PTKr7Oin2D
# DATA EoB+7/O009LocihIMHtBZwvPvcmwFS4hgJVmdVlRXUFIZ845fFk5sqcbQKfr2UMKoPesOaKzvIWbR1bSTDT6sgDlNJwHqJ66u18K
# DATA sBlolxu0Ff2DpUvjHywvtHMtAduY12kMErhqy1W/nsrsRPcV8/GQGySXbFlAxaPTcWCXlCaAtXS8AhY04PsvvmKMDFj/ivRiv0E7
# DATA G8VV/nKmpZ9s6U1Wi/1WwpP9lJlENuYogLWTveX1pdkF8+j3oaaiR8EmDlfZ99sR32i4lT10ailFXACyTuTb8BrJOnua4QIZF8ka
# DATA rehz5qShrCUasQ/jfRmBi+KOeOspTdbEPrZQ/XGKkgCVbXoGvhNyWRWl23JOec2hjWiUvBduZDCt7bfIMvinDq7ghQKPADH8CaOX
# DATA H6LCWTkZl61yhxFb20WSFWnmDECa/1osRGKBFBfeIuNQkqO7hsh2Wz4n0umkneeIoFQPzwGvBIscAbFcJhRLH84R41Yii2vpdW/M
# DATA wBWs2p6tCxfvfU9rruJh/g8sJ/KuhBRXjBxe8hfN3yxydP9CAh66kQc4EODPyDkDw9T+1jgfBWYemrD/RTEBVN3Rv2BJEa+bFfRw
# DATA g1tTUl2Lw/Q+UDu5+4nnGZG3jrqJsJy69kLtFg7v3SXnxMULStMvcy9RG9NmnEpsOVRDsficm4p1oVoKKtN0H0bXRI2rCBL6SlC8
# DATA ijrrnbIVs+wwdPNO1P8K37mNNDhe/NalwEb6v07+cCLdQvhqJglwDfpyG4eOTAzXwBEvObYAV/F39p7tHrS2dx+3Hj97urWzi9yh
# DATA LUu0JvV8a3f7iSmmvpjzCqVdnK7TsoeFlx582DQAjVox59pseeFR2aHc2IO3y9Sk86I1kb/55xWN8lZzUUGeCzM4fl983Hr+4uMn
# DATA O48UKFRHZI6VN/Z0A9HMMno4HLB2TMPl0JVS0N1sQDIUOqsvkvM0kGv5SNtNmLzzATQMII4lIQ3ijS6YP4yc06rwSDIDmuN98Nao
# DATA FEKEo6W3wJZvcrmuAljVmIFT1+5hxJPKo/JT5f+cO5pCYDCl0VilAAto7VhcaKJWWZ4RjaV372P+Qn0dFMY9YXX/RYMUVaQITo8O
# DATA ST5LT2VCJa4f0phKqaUcj6fy47DZhxoBWe+ImZDlMvJYa3asTevF2WFSZlkNSZvXOktOgnmRLdqgNSZFO5TPLl2D22F5fDOylT8s
# DATA 5dBcApfBAZJOcvbJmEwnw9g32Xl3MbLdbqGO1Q6qLNMyBbXvsqdnpYbV3BbRt9LVvkjQqjpuqhEvppxFm9QvxYfiNwWq2S/d1BU/
# DATA 3yyIh6oNWl1DVxU3DxFZYSvxRE361xLnNh3pGHBIog7nP8SooZi36Qt983Hl0jHmkASaKkjeLDn0zt4M5Tloq8nDzG72LbzKmnFF
# DATA DJALqawhJGXJ/OTvqkKVst3Mc07AItLW/AgBCx+pJpu5TsjmgHjzpgzU0zBT17PnYLuUEHUrAgpRQx8wIVJd9hpUY6QG4KIiVT2y
# DATA RZCwld22yVApxgwo7VOUno9SzNsJ2NM7BwJHj+VC25aAqBZ+OVYXC+vEfaU9q+9aRQ6NIc9BrpJ3ptMNiSm2fp5lka1LsqImMde1
# DATA AnZAytG9kRyxJpfSd+F5XWYzSbLJ8G6ibIjf0lNyrzAS3WVGlbfkEeY19HbsQhH0QjeSIkbAXsYj41Qjo5xthmRq+heXBeZ6q7nA
# DATA +AO+ItyrsT3hF64MQXr1PCADLiSv6B7rqTStLtRDeSkcqzPMc3PDLtetxvR2bPccTwOjNQkx5/MXYybr/kH0hLy6OJzRNJMEk+zN
# DATA G2fRaHoMM4pe7D2JOGYGx80W5yz2UQYIjzHF8GLSATa6w4Qu47TP8ZgHQgIEedm+oNDyXKrNcRkvjHZbJK+SZr14doPOCM4Wmz7a
# DATA GKHaInG5kkNtP93d+v7W97ZbLKcA0LHdU+j+T8uiOik7XrFAGRacURGqy4zIkVj/vrHFgtScbbSQL3TkifkW2lKBZvBSGgJpw/V2
# DATA VjD0Kaqf1wvPDUazG3r8h9z99ZGnGy3w/A8SWF0pT3/CtNxUOMqf115rdJCgTYd2vRIrXTOwDyKdclbbqVMyeNjhvbHxeRCmmJ3o
# DATA Xk9UQtpkcCl0wLhV6HZQfMtGSyhW1a+rOgqWYzhM+djYbrgcgrOa6sW4h2lbVWueZYadJIEt4j3PAdsNxvYgmGs0z+FXxX7UGYue
# DATA ZExXEYlEgb8dG95QMe2zz8FcJTl7mgl+KPA74WIWWFU5O+25klmbWk22ktQCZ86MBHtuZ0JMrF2v7Ls1hW3wfW2FMhzUDiTM8odl
# DATA 3MTJKvmNZShUdn1fRT1AjDcBRCKA5YPjh8eoJyDSdl/twZJlBjXewuXrUSiqfBYiy4JwOa8NtGIbaX+KdlqFTTpObdeLTjrK9MPx
# DATA tNfviMcKXC9IrIJqrhnuyHdKh3G1I0FiBExs2sVNkk1FTN4WHP7ejaXlASh32hZBK8i98SGedC5nuUoI3gM3gdvCDgMmtobFYT0Y
# DATA 59kS8IhvYQjyfsrwxDbTThWb5fuYGAqWg5GVFtlMi2nYbLJn+QeIcSKZ4L07EXw7wjY+Y2wCImOjoZLXqd1m4US/Q8HJaR4+nfiY
# DATA Z8Rm3E5oKKm3rN2uKMB1VuPDQiVDCoRYtGmqooXShDRadu7eloei64qXYxe1QZrRm3EDAf9lmYY4mJq4S1nAa43brU0HpIg/62XI
# DATA NLeGr7zm8ppS9+jgZiqWl7I4JnuDMA7LFTW+Mw6nxZG/AxHH6JAREx7LIqBsYpCZoc49f1xTYLP7mu5+CxyOrP7kw1BczQELWySi
# DATA W3zb53qlGSMxmtOlZdbq7DRlhFFA3KQ/VhyXtahlHh0IHgHOaUp+W7QL3S7s0HEyAUvgJZ48r9JL24XnhpTSRHmybKc1HBeQ6/6v
# DATA YnmvhLLKOvJfyNYCTSD+nSOY/fp3q7nG5dz8ZYPa4QRcr38pMFuQpTq41fTJwqLGa7nQsE7IOXJ4+Om8oHO1yM6Gpzwb/pybwaCg
# DATA 2hzFEYq/9YZx4gLehLa4QdBoCKJrIWkQaxA8QuqHvRfxcg3Fda1R0lNHZE72TseceVlh13Uu7LjizpMfe7d9DjNv4i0XBJIvXnYT
# DATA Ob4cURxojmztW5qKQ8IgOvTl0cCleZe/GuvQS+VAXhnR9k5EvnilQN7wVqAS2TAQm2E64a3X5ZploAk1AKZ2SYzYZJe4zvGRi292
# DATA lWuHb2462kAAyg6yWp3oW1/wUFSjIp6qork8EyfWORDKBUyvippxS12nwgQgzzYF2T9hixTzR0MLxAPglnKuOeU5oDH8F6t1bL6r
# DATA 4qp3b9rUu7WhuVG3ndyd3TUHc9jNIwktY7ODxV37FC1Ukpv3+MzcjGdMgj8hH8z/D+cqhZJqSQ5477AKTU7duZUKyuHhXUfphnvQ
# DATA B4db9p2rr4PBLkT2pbdonsw0ikJUiIQr5INaGGCE2Ce7ouOM6lbTytfimBXckj9TLe7wAOuXCzbLsflJfGqPs0BfVQQb3QrpzeXh
# DATA LUDlVn03YKm23hu45u+zWex2UXCLBWVRAf5CG3c2lRFjI3hblsAYaExON2B1J3aELxQcnETIJP2j5uwfdrokTDalpIPL6aS9TKWW
# DATA jVEolUk6yWgioUg8c9Hw/XBBaUNh2HxHFKZj50v0U3ooWceT7a+neSfhrsrvC44sXnCFDVhsEjsh1gI30HKAvdBsk0+7ggxGiHew
# DATA zFgXFAHlWmr1k8vhlOybnSMxT7QXxOwc4S48I4OcfQ9uc0uLbVHhbz+G+tv0E2iadfdzJHLulVCHjdZEcaG40e8YbEHnKyhyNDY4
# DATA 3AgG4vEWJBSDxHNH1u7KudgF5YUsM95PWAASsHkjAyb/qeLuF7FvY5OtinhYP01GNjM/L85J+drNxkuW2LwvG4sIVlwCfUsTaOVq
# DATA FhK8uAFPPWGtioYtFzqND0cWHK0YxY7puEvb4EUpXk5GvWWMIrbMMW5i1uNhH7wYyypWwAjdcNkm18pKVCNBfYu/lrxvRLU/BYrZ
# DATA h29XKmJWJ006EuqNtujZEAAxHPTaJRT31lclh/AphjjLFXigqzeKs8ZxFg0aEqcJIAsTbAvoVXODEmoAsQXIhZK0idYmtDIu66F1
# DATA swWsorVqOUUpADhc6XjYuXTDWqmRcq5WK6stQqs4kJoXhBDbtZw2A18Z91RvuGNmlT40JQVre9mTIZxrW5yVG+uj48qMwGvBbMIo
# DATA 4uE8wjo8NRs+qiQ7P8HEPb9l72P0MfodeTH9HOVIAbbUWwMh/Ha2rdqnBwfPZwk5OPQee6wC4zZO8+HcySwETiMoFWFw7jiLXrzY
# DATA eVzzuRrJaUS2IsDkcv9tStDTjNZX1suzyMLiyBeedOnZvuQJtLMHOqCAadjptYw+KzNm+LQls36ajkqrcjqFBX8I1/1Igo781vMZ
# DATA U2lmWdQnq4kZd3+G7qzioYr5f9iNPJRf6ktyULQjm/xKh3hVUS1ZJfYOqrVbFnMxXzr8PxmXuJ9/9Tdf/cd8EFqcXRyQMOaPl2Jm
# DATA R2v6vjFup5eN0G+TslSa0PmUPxLoqyRSayoJa+wJTjm5JWtTOJeoLbGkNyhTW3LTcroNq1HGgYHr5mc3ocHm6CoYQRZsAtUWVT7M
# DATA LbNWo8uxmmHIUUSd8teS7liPzE3zy3oNrdZQ8R9tzbBSC1uzocxV3eEN0x+jGu1HU+CdOrZy7BvNSgxcX1WzeqbdRe3+j8oBe2bs
# DATA ttoj3tGE68JVjT3xsciGncj/wVEi82UMmxfMUeyinlpYqy9K0apC4fkZfP18vTwTeZDLhUr2q90pysXoz24VCqVsNLLRy0IpO/4f
# DATA X9K77cGk75A1R8vl7cHCnE+keEEWr8Xhz0sxUHEYSlnSPz3a2946UMme9h5/f89P/FThsNOmG5V1rduhDuwMRPFFTOwi9uAeijSb
# DATA Whc/lPCfirx58uzRd1vbP3BZEZeCBtybcomZ7RvmvLVVd0XMBJehZWGStXu9ptgHoYB9MGmulhdIyU46md7JYHpGC85pTGv7O58c
# DATA bO89rUTm+dMXz23Lfn7Pf0rcgM53cKfVwKynqGXEvMCBw4+p5FJRgmPNt6hMx6G8xrkMxEYD5cUvSbmxkjo0H9npQKUn72gvKzeQ
# DATA N39v2BfNoGpeJqcEDkbaEHaAExdK3I5/Jk8fjPDxK/Km/zElrUOO6EuOh8NuQb978wsKjfPfbv7fs2T8+THs768t+fPc/M9ra+v3
# DATA vPzPK/fu3b37h/zP38R/H9xanmbj5ePeYDkdnEejSziWBmtLt2/f3oPbL+xLQg+4X2093+FYCGRESLeuLJqcjofTk9OQ4T6Un5UD
# DATA GiXaSA2QsnR09mS4dtHdRx6BBcfUz++eHfrGOaCdsXp5oe1MzzQGIWxqDHQpAGoMNx2TWVlpcvjmoq8FmlWFScsdSieGEskxnO5n
# DATA Iwy12+vABzvXCiu96aAW03ZjJLlkG5bNznBF/lycZ743qPWyZDK5DGSWdWcQP2Xzs8gyqodmx73kuC8WsMMBBfxOOBiiTkXNGYnN
# DATA IGVIsvQ1+VviadNZwjPnE6E3GE0n6qMG7+5wL2WZoi8Sw0ux+iaSMZka20Dzl5YUL2Vpv0tcNnAXI5QPY0ras+wEwA/bAVC+guH+
# DATA oY+58MGOdfvw44eUjXATNw5tly6buJNsAt0KzGS2Rj0zwlarN+hNWi0ZGQvWhq8AEWInWoARFPJVR/t44Fgds1LJ+KVMs65YYqmd
# DATA d6+1SMQ4haCywk2C5qZA4zxh/FPlCQvaKnkweoEZJQ0MTEJ5kxytEum2VctxeD7NpnKtJqtvM3o90frqvdoK/F8dJ0s5pbAMPjQa
# DATA 9fh6kRHvpWfDidC6TN3GIpK88NImESer2t//NJpMBzgz3AxYIrbN2vvdGq0l/aIF5RXUeb6Wkb+mD24twUMyuvlB9TvD8UUy7qSd
# DATA 6vPxEO2cIrOc9lf4hd8MBK4ZdiYI8QIAklik1+6AFhJUWxsU2WKz/+xtp12j6aqLQk+xQcSEAIq7FrNXxzuBYotbcEHTsBG5GVnu
# DATA QstiQXHnjg3HayeMmV4MFxek7GG8xek/PhfvTBQOfZzCbXDMWdZ1dT/LkG/iR0LnwuwUUqnkb2ixMsTKRBcRLLwm1j2GvpZrUrYc
# DATA nscjTktVPZBYbS6gXlcvLi4oC0NV98rBEk2Pecg6uk1MwQYUGtFqjJ46pTUragDu1E+2D0T9VC8vYJwHiJLHsD0LexA+qHEh1EEA
# DATA NvEfTbabmnw7bvh5+TVdTS285iswHQhKn7E+T6Hh5j9z1Qlrq0qZYOkUilQKGFhOGipHDyO/7jxJv0+8kIVTo8GsNHBhHJ+kBbYl
# DATA ciw76T54JCHLxRsJ+LXpCnMQQcn8LA2Pu53sFj388lpGGre++lEl2lhZxX/W8J/1ayqmEPZBtBru2hbDAw1RFcqFq5/zlpy3MITM
# DATA UTfp9dNOg06MSNnsmUko884cCNRFPqhfqEQHjLwhbcMM4P3eoQJVBhgCejgQwGyiygc1zGdQtB09f7Z/gFhBRk4GMMxK4+Dgdnc2
# DATA cnJKBrN3lciDswuIPnFSQagkfJ1JTd1YKO2M13QFC+C7z6H32nTSDomcChvrZUNOecON1VT2wfhP8ej9cGWlsbLi2TlLZtXJ55RB
# DATA PegtYiWfpLKqVa7TDA7YydJXSzJVouSXrpkxl814Zagw6D+1dEKD83QMfGiGZovZj6ZJB3m64SShlHVNdFFPegOWGWtrRrz5OUe8
# DATA pA3BViS7srCjlouzTo5ewwgZFPmyNI6tJKTVo6u1ytrd65jTq83l4V8olrczTPmw7vYmxL13TBDRiOHgIeY4hYrk42BlAWqdJSNi
# DATA UPhOhAzK1qODne9tk+gbbl7HmCsa3j7e2d/6+Mn2Y+LDemdwn6TXT3ae7hzw2/T1CPUA+Hb7B8939vjtcNA65Rj4polr7XOiYSem
# DATA BzoyrxndXIgMXg2GFwMlF4hUS0vsDn6GUcGgnw6l0uJFF1sWOI1bVIBj/6xgYnCnBFZrTcZJt9trqzL2sq5ED5rcBf74aGXlXv2j
# DATA j1Y31u+tr3z0UV3dWqgUjSBQaN7sdgZkbBfJKDj/K3ANehHRrPHkknizwMxaiL2TlirGk4gHQ34fl2vT0Qh4YStXuLSnbyi7z1p7
# DATA 2/tAfWEtH299hn++v739Xfz79Nnuwaf447PtrT37slK0UBn0NhyjaSh1H5lhsb1HMsZNZ6V7tUeEpwB1ZKvd9OzNODd1OypUKFWL
# DATA jtP2EF1idUF7G0hiBMa4Q4TkoULJoyMbW81rGpDGbqNI8Dt/ttv69NmTx9j+ZRapPbAZ0Ybj7YrnWkekz/oGN07Pe+mFoSOGQLE2
# DATA VNMoqk6rbfuz/2k6HsIBmgyyCL3zaMOKQ7tNKmrR9uvTZJqRvW67zTGdz+A54g4i2eA154KLyPyw6XeqNxxAs+7bPQicCacMhVHk
# DATA 4zrsz0ELowvNMBflbqu8z5z7k0KRWzaOeLZC/pLtKdgy0CNKlqYqb5rwDVF3OpnSUg3SC0ybTlaKRq5kX69DqGo0bTjsGTj0IkML
# DATA E44IDwxN9Dks7ibwyxO41vMQz5LLCHod8FmQ9MnzOMpGyPAr2pGckO2em3z9yhxbDTEtVSiukp5p2r6FF1jDZ/B+4E8xB7U2NEhe
# DATA K63JKhC7an21ulY/WF1rbHwE//vTnCN3LCN9gqv5MXqrQX9Cwp1v+4pwNDRgUdtNR9gO0sdB0t/Hc50CciC7Srlf0CCnROd9uZwL
# DATA NRNb6jY0WNUzAVIo0eHi0MnF0udOK5nEOTbtUH3d4lyOPuysulaikB457pse5F1shyKfWsQUU9KSABJLYYrnq/i8j45oBLXhD1lr
# DATA nZ0mneEFOqpl1jRMMzch3yOU7LSH/Ya1F4TlIqmrhMVg6bOdYE7qAddFkcsrytUR3b9KZtSseafHF7BwKHcqWVNRkj4zwefqDZW0
# DATA p+oVzzJT1HVuV2PTSZoZnvkc4s59QQm8pfShakXSodIsy34WvICD12yJth6bEUO6Ikcr8YeBmtuDGqm7GyQxsEVaZYz3ibeB2z6X
# DATA wKe11UXG/FyNVctjHVbVZlPFjwB+Eqs6TiXPi0s6ZSvxFN2kuSqroL9U4ZHtDqM8CtuSXTs4ucX1WwzH9LhYqm14WcuApQXfFfEo
# DATA 1zgFrhGnqlhU8BPz3Pp4MvPaUL9bubuO9wborrzIwtjunizGVfK+JMpOUU2EGMEy4356krQvA1aOAsD88sTUBOEd+ahNj/PXt4o+
# DATA 2bRtFKUCkJsY6mYGnbQjs/kgeqSXJgKmCJBlQiJKZXEUpecwh4vTlNs/I8kNncAJRmJBMx3kYORCTvdHpkS9tN8hLtO5spmNkycr
# DATA LuUgaqpma87LSugAKzq5jpasVNNIb3hUDknSeaUZLqxFUGiG9nLI1aivFJTWv28T8OnSqiOsBo/vLUreecs+oXS7dpGc2s60DcDp
# DATA nQzoOLrKALKMCa5oI3MSHWVsa0Jxc/TmCR7iFCLPyRGPJ54ZYbDSEREtNSzjtaHITws7LSWjnnP1VmQS3iupbomkT+jfhJbypGZe
# DATA Pr6sKtwhu3qHJiBLpr1skm6KijGjJrDjTRjVp21MrbWkTqJR45kvOespA3aLzxieh5W56xi3lnJQyEjOTPwi6ndIs4OJ5FiXgbA0
# DATA Z/Sw281SS0y+UonqbAXhNqqi3MyF1be5xaaSHPIjxXX5FjF3+gs37x5sxOOGY4/QJw5ddxjTk5sCxvlAyE018sbsWNCIcCg4CKZ0
# DATA XoyqEvjF+EDFAoTLHCmiaYU2WRqoXiYRhdCK4N7dG3ZizwELzUMlBuChjOYo7xmXFzmVOXCRryYqHvfjKStLUmHFuGvyAQOooMYc
# DATA xqCT0nipytMB2jeWQuMobzIsdAbkzHZTFg0ClSBPTloSd8zHwBS/yicOtgCCw7SaeRhqpUicokwV1bR5jczJb7V7Kze8cKPb1ITc
# DATA QVHonaJySmQaZI7txLkV+6Yq96y8qK9kcg21WwVxGzyGazcPMhZRwaOmA88om7ya2HZzOhlNJ0XJcor0yWwNo4dM0gBcg2PUJUM7
# DATA x0O0psHW4oIsiE7nlEv9XCn+dFlx67ezbFYiMtZV8YOAZHo+/72uVd+eFGJEMrgsWV/hLMD2y4uIVGFecIOPUE9wiRcZBwDK+ymr
# DATA tU9hQCWLyFpDE3Rqoq0Ez5/ftLS1g835WsWcEwn175a5DUd7fPRi/6C19XyndfDsu9u7SFz3VFYosoFi9XCk05YoEXHTaerp1t6f
# DATA fry123qxv723u/WUxC9KZpp0gHmCFrRJj5XpRrPx4eaeb+3vf//Z3mO7OVUFx2QBRxsVyKM+MpBD02cGjWWZiuptIeIJ9dO+0zV0
# DATA b9eilafzFXkC9KBtcUOS+J4YA/K6NAKw4MHVE1aiylUwooA5ng/jnsdp2JcRREPD/zSbbJ+rarSoQcP4cPvl+WJgrs7lzY2K9gu2
# DATA 07FTiJlDH+bqsgnq3m0hMY2Pjt5W1vvcim9VYU1lJszCoWFZ1TFFfczwwhsll6iordiiXVf7EgCOvDTyTmXirO5kcLfAa5mv9WUz
# DATA f3d1mcezXlTUmCze/ygXxVQ35id6xwd1aVGFdJPlhc9eixIQKDn6Emv6O71uN6VoS3wj2OTM0wAzPEuA4/VOY7KF15kxZSi0LQT2
# DATA sQI+vFQ/bb+IRnC6VrBYpcd1p+H6kCm77EqEBhyFJtrUHCGVGbK3wX2GgtNyUh6TaJ5BtztCJXtUOhQh0QzW+LrwgLbDl5pjmXdE
# DATA zKNHoNEPeEOI+pSy9/iYe62EeqhX6gqj0IiuDJNxjdxh0rmEl3CDJefA6eFttSC3OcvIVPnkY3El2+UY8W1gT7jqnGooqINje5JJ
# DATA 9zz88nVsD5GEN2QVKGSDY9JDEw2t+DcJJPSZzG3No2HPxymM4OR0ovXm9okI93VmnmvRHmk+IrMMrlNMZ3zZAqbHd5yIH8PqwXvt
# DATA 0cWKeSaD+a1jOUgqwo2NXwJhxTmzUWf8yDYtJmX+5BQ2CQ7t24TpEVTAY470C5dplnPOiR8hgvaL5xuXN+3BCPeBgnmRDquk33rB
# DATA 1QsGIz2ZnAwUV0DW3b6oETFAHSgn9xAycbSp1NgBslhM103Audm01k307AWTC17qCs2tPA6qgHngzWoocq4ZoWUuboZ7+yDaMrZJ
# DATA qF8B/rc/hONWZEyRjmTBFuhkSIxRHgZtWBe0ygWaHR0Dg9rpX/IdsBbsyPGtfXcQh8Gsrr3q9JLPsw6v4q38SObL0mz0W+0hfo9T
# DATA 3H8jvc8nQwOPoGM2orrWgpjcjvk5kVj6BkNXTZs9M7PxkMnc/KNb3fbhGGqnZtpEdtR57US5CeFewSGpJiB7/Ch4XAovHDgerdM7
# DATA cMCJMFSOOO6q8DTc/3RrdePu/oun+2TXwvllxA2ilp0m8LE08gJMnqavO70T3J4k5ono8BhxcjJ4fjmIWR1EHDDJ462b20l/eFyK
# DATA 7wjpL5fdM5QpckdOMQHTbUGh20d41Nkno11Iv+diyqzNKcMvsYA5dfy1mHvQJWOSWbP6azOywE1ypYy6nsJr1L4L6yXnFHB+vE2H
# DATA HdpUcdCN+K08iHMuqcwPoUFt7LvxbgaKW2QnWKegF/cqtVBPLDlYtAO6ulTx6qIck8lyDoCWANibdbihhzohLq16xk7Hxm3Ytv1S
# DATA skPTmPW5aDjAnlQ5LFRCVoLNmEM6TWAKcXAkl6QmCJUu6ELdhKpyE5pVW3kaB52MEdPqJCV374D4amNlxeIf2HqzFBtgN6L6f/3x
# DATA /7iBdoB839Q6xcCdTucLEO/XuV6o85xDb3gXsTxIyXz43+w/231MUXALrypMcN7uxqHfaiIDB1f7FXOVxF+i3Iat9GqWmssiANQ9
# DATA cMMYYBGaaIo7FHRbLnZ4rf+34BdK4dq6sO0vkn7/a/ICne3/uQr/t+b6f9br9dU/+H/+nv0/n10MouEAmOkJRePppNHJNBl3ItJX
# DATA bEav0nREXk64weAMOR5OKeLmCGsoG6hz2JBYfJYnaG8kaZze3c1zeiyh/LS3Z3o2wg29tHSAhoCRyoiF0twWoT7NKV7ae/bsQMnT
# DATA ObKiLlelCIJqiwD9fbG745XNiCh05G9R1ZoKIVS2lAl3kERXmGKJHJ68V5xYdqyE1bOrKdJeYRonri6YI0eaaCcjtJVr8dnOL2ck
# DATA ++Le6V/j5rK2osY5SCcXw/Erx4pem7Tp5av1Ri2nJEbfG/faE1u+bUzXkYPvve6nFG1jJaIIsfShl7XO4C+wjtnEfT2lhFnEqflc
# DATA oR3UaiuSYm1xLdx5ju0A/AbpxDZpiB01D+evxb70+qDCG5Um0AhMJjttIVIB1I/HvQ4w3Np5lyPEqcnTs3ATWJ5k8MR2o+5XN1OO
# DATA voiuVlevHWWYfHkY3V1XWhZkskqjshIX9jjrl2YmRvjP3Y2NtQ3D5XMrs2CkpHS4gam0q5NTE4SB1Ffvq5HMtpKpNdBOplLfQDOZ
# DATA Y84oeIyjcaE1ezyPMbT7WKooW7bkrNcnW87e6C65ocWNmPW2JmxebxS7mqFufMUVr6MMMTS6ouLXaHiLzoHC+LAxbjMqxb1el65M
# DATA V3R/QoaUb1+2b501K2tJ1QQ5fUqkuyAuRj6qtKY2xnXjOGbtbw8x84po1HV0dbWEVgLQCvBr6M0Jb4jVpmItoSJwpeonwG3Kdt2M
# DATA rq+XIsoKKowPNsPVgAKiDOV0OFRMEfA7wzEa+FTrK8Ako4rxUka9CbUUKG73h7flNbxtT3QcVF6szng4gvdXDHOUik3ao6hDlBeG
# DATA fGVgeJaMkLmrCGaWr2G0pmFT60/MnPPdpqQq72WnaaeiMvi1leqQjbnx8NEVz9JJEvXXyfYMyNT53WqvfQb7A/45v8uQgVEOOtVB
# DATA 2js5PR6O4Y4GgED7V/tl0kENCr0bA6BT9QanAAgJYB2xMnp1Y+OmnTu3vAFcq2EBj1GcNUowxUF1MhxWj3snTJSrSttN6SNhfXAs
# DATA 0AFUOHPgyeti8KHLbsAFGKG+zsGJBVb/rVfqSvbhtT14+B/sDxMRrY1SHn0pF8KKBHRJbEWVo1guIEIMVK716Nnu7vajg51nu+wx
# DATA JNaADtkzjZC5xDoHvNAv0WoQzqFO7wQrWpcXHAzZaOAlxi0fCr+DNIQCcqLZDxzlMbFgGfJgcDpwFq4DHOGkAwjHA8Xy4ZyUDj2m
# DATA XfSy82FMuQ2DubKcwWIhBYlDPdpcAEOL99jXP31fQi1ZVSTPeJaQHpim2iECz+nF6LgkFycJ4cxoSc5Q4x6sdlPOAfz4Iw8gZuV6
# DATA tiGfLZW3Y3oW9i1ZONExHBpSfXiA41QwmUj0GameSSoP21DcWNUQBJQcUarrkMw1HklNhlHj4jWxLfLSdnj/qWms6BT1h/EuaRDo
# DATA Zi8Qk+PmeEyh0LjUTic+OmzUV9UqK76HDzKmzJq30SwQp7qkYwqg2NfnuKUCJuAOuhP2VuOAAVSB4ZviCzrbFJ/rMoSqpRoPiFx1
# DATA KXp/UbNZ7DZkVfR5jD0OzaIk6cmAWSha8gja5ubUHk0GWaJoSKkbd1KyXcof0S85pHJo4MTMylmP7ACBTMtj1HSqbfq3S//GwvJb
# DATA /ZfzNWaUlTROeHRe9Aad4UUJndblt7bv3aJDpKNnDaNk/4F2f4guN2TfC7N6BGfb8ZCYTLz5YQSISHZ81B4nQNRNwt23XPnggs1q
# DATA bqEVf7tVt3YCAGl3GA0v0K6W77o9NBuhKPaocYH7FduFqBtdBuddr9/nqJszgZIRKDyQxJrbiReDD9kmmKUN2R9bTmkvRifjhPZS
# DATA xHk7ZE6krkSzFBVuhTc5mSRMMsbYSOUKqtkxT4uwseQG6sMUAhGbtVps7Y3Z2ZdWTAluF9YCGS8cods2c7Uz+Ei7rXJ+d/FOJ79a
# DATA 3hRzFism3vY+uTpfx2GyFlwou1OA0tv1KDDCn/WNMx6DogJ2RFrP6538IWYZJ9oXsr20yzm5yQjRMj/sdiokVhmOEzJBVCKW2tkr
# DATA FH6MULfUpK5UCnW+6TfjGuFfNRSN1wsI2e2YQJDYthcIEnvjefIM9VdtNagHmAs9OcyMI7wpZELxUlim/qWz7YYZ+5JI2jZdz2cS
# DATA MpWa0ZTwUuyhYGCu0AB6RHFUzuSyRG917jg4Imfmb+fiuIlLyNW0psCz3xJRi/eJ/Fy/BaBaWV0tz0SLFwM0sRdK4httUqt+/ijP
# DATA zNSSi1QsRtHw97I3+/TalcB40hfRVKbnveE0e0c2BNeXGFYSBC5HMc2wNsLgq+qVk6IJhYDGRA+rs0QCmnEd3Yo33QIQtjK3AAnH
# DATA +w621+BWSQuMQj/OLWijqJVZMD++68D+o90UmDsJOVsUL7bVKttdlgsqO1CyZCdXEnu4EclqxnDXeU6ipwav7HWuTQQyXtbiwxeD
# DATA 3uRo6bGlbjVWuSSbFrkPDX1pC21GmrK1UIFXE5c94bvlzFn6mDwnmyRuJA8TKbd0KFnoj5ZQqdUEMGIC9aXt12l7H/2Cm1poLgLz
# DATA aJbMeFkBVGWcWWKfZxomqpKal8AjHu4wp3G09P0ElVEfXwYGFsdudvJSzDLn9oSiOneS9Gw4qMKdG+2NZpVMB2pnzJdWW2YSucuA
# DATA fV8MBDtXyFfRAZF6xI0UZubTxYrslQjN56XALTY0sc/HXEAjd4KKtMiVUDwV+VURx+8cG/3OIZGJgvgs+dXjCCCLLEqAhC2CEUXV
# DATA rNjzX2MEdb6vOAYAJsA17wyZOxwF/AvJfyysUBV5A/1At5Y5wcqZ4twoCLi6/zV1776SWs4kCQRNpOxwdZVMtstFFo9DuvuncASX
# DATA yHhxZUYc5XhvOAypKXJBvfFKB4wVBviAGlW+txhrouR8iHIXDJW9jPQbesI89El7PMzMtWZsLnM5puMbYARUtzdmU956bAgPK7i5
# DATA OrYoovlbBTT3eFcOTR7mXu0Q5l0yWywIYR7ARj/Tg5/twfCPbkR5B6F5j7mNsMjWyYATOswLDv9FuLmC84P3kWSS5a16VLH1Kizk
# DATA /VAlm9X8wlHZyKnKM+bMIfQLKId39NjSkxzodRNzkqy/d3qeh1rsmXbiAbPQcbg4s2CZUz+zZCFMljub0XByCoeCmoLw6tqURhta
# DATA zzc7EkujP/rDf79n+x9K1/j1RYCfaf9TX6nfq2949j8rq/c2/mD/8038V2CUk2QTNrwhHvn1xLK9kTdnlLFBx01vo0RP292k4/Fg
# DATA WBDF/XRy1r+hqQ/cQ6fj9Pkw670usPxJ28Bw6e7xwAjEfqeI7UtLj7YOtp48+6T1fOvgU2XHY664lOgEaVYp1nuj1U6AWRqe4J24
# DATA vPR06wct1cbHnx1s70MjXmRWKvN0a3fnO9v7B7pQ/e7aff50sP30+ZMtfnuXX+3vHGy3KA+ieYePuvZGfdVuffsHO/sHO7uf6Drw
# DATA 3f2gKt5dDwxOl3q8/ZzAcH9p/wBG1EJvVbS1qNFBRZSBw/v+m2cv9na3ngQKVC1thBQmjibQFLFZS3vbj7Z3nh/oAqYlTl0ujTx7
# DATA 8ri1f/DiYyhyHD+4BdcLEhsjAj18gP9GfThrmrfTwe2HD0jhDofPGKMf3J5OutX78HbSm/TTh3Kbf7DMjw9G6g2y2cZI7cHy6OGD
# DATA ZWoe5cU7j7d3D3a+s7O9R5IoygKDeXPG8WFS/fzokO1eqkdXK5X1e9cvMeTlp9s/CJTtQrGjq7vrXIb8igtLra1yqe0fHGzv7u88
# DATA 290n76QajorsKdoctAlARH+yc7KdptyZ/JpuWHHttZS/SI9hq/a6wPvF1zrG/D4Am7llwzjncxG0RklvnFHOzsy3+7q6tmOqVFQI
# DATA jQEpG4ORVbhqSP5lRhM/fvH8yc4jRES0Gm59d/uzfPQbjL3iRCZy4t6osSMkSqieKAeMnF3zYrafI4eKcjAUN/6pdciEuRQTbuW1
# DATA Rxb/zO0NjzHmP8OwhaYWTf7t6thfDHraMjpsL12J9tL2dJwZu+fCbDwGjju739t6svOYoKhC43KiCwEPkThPQ+BF6jBWfGXH5MwN
# DATA VFW/T3e1+OVLMsryE074A3uxu7/1ne3W1v7+9gGR4NhIYJEa24Telu9jNkclTE2Os2F/OklZLo6GeyTAx3sjo6GErFBqCDap2/A1
# DATA 63Nt2o5s8zba6B+RdRs2GdTT4weOulijzVfjdAr4ugbXnQwPlxJ8C1b2hlH6dgOO2i9G48EXyfT1F4Np/wugF4d1GNYX/dGEfpSh
# DATA 0Mta7U752zIq9OKo7eS9v7oyCiUEVlAR8VyNM3vVMJMo3NpUVDZDhMpvsaJOrhHBOs6KdnO8c5ZVcO9htLqxtsAWePzs6dbObkjt
# DATA pImZxF2WWGGwPip+ftzrDBJ4VHufEn3BswDK3sn2Rr7JDlXDs/eoQnh2liKbVJ7uLFNMwVlACftoulu/Vl8IS+CoswUFhf+RkRKW
# DATA NaRbBVCroaPYTQEfpNEopxFhrJbT2KbPiihQ8ng7aShHqQlRA9x0LpYrJMcrqG6pBph26pgvFeE1MWYWWiNg2smgg8H06MA7vDNG
# DATA 59Ms7ZQsvSfa0uDj0YyIDRS8u2laq/VZ2OU7MWLG8N3h5DtoYh/woc3FSZQIsLX91s7+k93vlrAfJUAjIJ0AszQBsokfKKQas7/4
# DATA rnc85UhqK2WUtb1etz2TgnAiAO1/9vTJzu53XQm4AdOtJi+BCuugh/d4Z88d3pzO7EXZ2n0E7PWzPbfT0jBj30fK4ohHCQftLe4y
# DATA qEq1Syihox6+91E3/b2DH5QXgdb393ZIE1kwBQO3pgU3I9oFrhUFPO8OTRrM7rODFlTcfgTj+OzGAyGJFb0uOUPZ2/4kj3fqBcmr
# DATA ECnqC48Q2nvxZGuPrjsuScFxKYKiwhyZ9MNMQWxKY2Rjua2sN/IhF71jb2g7IJ+QILNzleLVnU7rLHmVtjS8Sro8RTPa2CjeLUSo
# DATA TPM5akWt06SsNnPB7hzQuEPhCVpIQnLsFs9V+Ck4xfjZU2kXRxQgeFmSf2p/htAU9qpZshq7WOuKdCi0up0m98jt5FdS5kfpVfg9
# DATA 2WMXI4AlZGWjo6YS9T/bffJZ9IUmj0OMOGLE/kwUc58/3tnd2vuMPoYUAi1Ooko9U3cUZOWY9QPAcaTJmYGJxPKlAXXpMOASNaTP
# DATA g2GpnAtv62w4ru5sOfPKbDr3PfmgPgzFFw/vRpJKUJhwi1jIRUlGS2vBVvFOfhsO5jBvdmKNTXc3NTAygDFj7g3g3HKnYD9Tfo7W
# DATA gMPKlahXXUs/cSX9qOvMYAlo/o8+3dr9ZPuxS4RwsICJf+JJx+QWbfZUw0NibSXl6MTUEXZLH2FmUJcYUcfN/2IpG8MITU+axvvq
# DATA rKXi1L+GU1LIGzZn9+8WMCVmvg7rDS+kYvu0R6Yspo/xRBrXG94MpuyTC9LelIoKOLOgnkIMl0a/omZQPPCW539RbIubsAC8xGZw
# DATA Ycu0IDCEGPo0R0f3Q7Xle6T3hVjj9Fuen+CrgD57jPDHSZYGrEwWRg9j7BCI3OvB2/ribAc+pHif5fTCwWNL1gRlQ0qSXAoJpUzc
# DATA ID7MbEF1zdxyKlFOAu1cRHO3hUVuo0zZpM2nO/v7O7uf5O+kznC1q52M2xeQmbxAL8cvSSj50tagslkoin9VtyirwufcEccRDDkj
# DATA A4lQuK6WDkgBI2HBjkg0xB8o04a8xfNvzimn7q8OTB7DX2v0fQx5SRFxuY9DkjfxsBp2dPH0NQaQyNipIMkmbHpSkvqyL+P03A8y
# DATA 78lETDM1zPBXoaYeDekzyaLIpNovVhNRifiOwmn7HqaO55vMRWbRwuH7fXv5qkbjElakBZBq72Es4+SCbJBfT7TExhbPhoWs+5eD
# DATA SfI6KFudE1HvJmMMyHNInJNcIFOT28KL7k2b8RKmi0Xd2HCBQI3l0RwMHHdFOhHm6hbqFih/akJeCj28+l9rbMJCh+r7ke+C7H71
# DATA NtZCkFIs1PAiEyH7oYzhqGAmWFTiRedE0viNJNKOhu0thxRQc0D7dEeEbpzzsZQfowdseCOwlnj3qIZivwOTBQVjzPX6Av/cqZXv
# DATA A+NtkcGMJSY1KitbNKjKUjH9ZOR6of6UkNHrE1UvbpfqbY2Fp2UlpFXvEdnPkte9s+lZkWcb9jUcd0qovYMFxDyXdDOHRwG4tKSV
# DATA TapBzmSiwInBhzAjiQvVtbsr5aNy+S2IjR0uvCcG6Qg9XqajGdSaSlhIgJ/XFJ7SR42oRu97kxFSBSeceb+jk9O4Uc6ZX7HMb6n/
# DATA sAEua4WCgQTxZa0N/Bd2VaII6NJpPsS7dGYQJX75emWFxLJqHIIl8ugTb0UhjQJ8AbZ6JoBkFvHVFUulr6+d4SjGnmZpaWpI7Vpe
# DATA lKfnpltAeB5tYxqy7T10Oz7Y/sGBNxKGHHnhenB1RZlxb9BJX/MolFKGURGBur6yHv4UpB5XcXKM3rNKk0xPy1YH1xxGKmPnZUHT
# DATA heRze9v/9gWmIARO9ZPtfcM+LtlioUywk9t1TB0xiPNERScva0cFjb7uG3UfGXjKQkJbJayTdGS6TbxJ1+KFZoPsNqzbkyc7qPrK
# DATA q581BT1iglCo3vB4fSlyeAUkrKGpmp2VpDTrfChf26eQd5tgRg/285ERh5F5JR9GpHXLafARYA21BQy3bm2RChlb1GAUCbID1Axn
# DATA 70zZxLCsSUNu07BNvLS+lFcu5eiSWH7aJFZRqbLOoYW4onWA88kG9aRNE0SNpWDF5/P0bFaDs+u/BR+3t72LdMFm40K4w8tH1kca
# DATA 7uhWhsEUZCH5NfJ/olWVZbZ5Kg9NdF4aaUkRDpenCShdvrv77Pu7TFkVZ+UO3sK37FA1f6RRTyv8LgdtWxBmybqaAVnXYjKK2eIr
# DATA xrObyMOCcueg5IIESTilkMAhJ7CZJ7SxfVOYZc8JbW4gzf7+nj1Zx6Z9+wePnnztYm4R/aAtfIGwW4S/EgYVLyT+p25/mp2WHO9N
# DATA hndObiwglGT1XqgqwlA7kI9YGKSDDKNkkVKfTa/Z/rwF9FglychSDLYCy5Q1S3EFiXIj5kA/KE7I3TplHFDhrNcO+OEWrJztUUtY
# DATA a5khWoZ2BCoK6UABIPGf9RJFgBXlCMPS8mz1IBIQ386QvC2+/eaICRfxvJ3ttxWqLVvb2uXZuN1y9i5spGzSKtjOhhrV7E8hF2DT
# DATA Z4Gir8jzV30ICv8dgL8//Zt0OUfvZg1MoBcWW8JOw7vfUCnU8KcmQfjg6S74UjicBCAlO1HrLjBe9bhjBYpRWaZWmNjBkcIRRg6l
# DATA I7jJMaxO0aFJvjfcW9AYA8iOiExKgdpoOCqVPYRXZV1PCecYcXQsc06q3Apy+4UbpvDM4npf66kFX8ec9hQayEh/PLbOI0r8Yz35
# DATA WdFkZvmpS7uNoPUZfiQmt7CULSRjxChj3uOAsTMKn2iJH0Z5W+ZGoW1TmCE72NvOqzP9PYUB5TiIxjLPhBYoPAXWMXEp0jJBzf7w
# DATA QvnVZSEnH7NDgG/qnafqGFDPrcmQ92AtyVqEe6VyEQBnG7rQYr6L/U+R1ibvcuROjFZURUQqxcYvr6JnXS6ur7ayqi9cEmEBqpjD
# DATA NcNnyYI6pwKFoKjLA6b21VBqtPeEhIY6fth0hlJYmmPCAyJ54eOL2/86jCFC/72LgUTovxsYTRSs7Xs0pLjlLg/ZLagXvcGQtqBj
# DATA x2DXgMdyY65t5iJmCcX7UGVbb3ojn1mND1xdef4Yj8XP1jYIOYM7KkYqvVsxLZXnm6LK+lCL8zt+VwCZrVObjtCsqkQdz69kIFtl
# DATA Oe8C9VhIpQFU/5oXfzHzm4KBfuPWN+9z9rnjhyKrmJMnPx3BASu5RnnO1b6QbbqBoYJwyB7J1pc4JSIT9shN/qFlLOgu7QlZtL20
# DATA HT7IsaIOef177LqjbrTt7fLebm6IwZbkHk9lbHzXl+GGvulxl95Sk/mqN2BJqkiiSJhKoiijZ6Nk0Wma17e9ne7TvKbO6aXv942X
# DATA +NjvLjDFQzPwRTR8fpWce4mWEFJBAQTnoHZfBZQ5XEAEsgb2uSlo/ZZTIaDnKuyDVsOb76fbP8hPlMot5ILAtukHRlxpJM/CH/UG
# DATA kTPgvGIspBQL6NipuZmDpxI3UkTaI1/A0BAPHMzuk476w0sMghKSGpqvcJfRfpoOB3yWjF/RQXEcQuDqeV2F03MFSbb8kpvI2SVR
# DATA Bp7M82HI+0V45rwpRpCm9ghl+fdNNYI41Xx+qOfpmMImzEkQFTx2Pn6x/1nezsO51du8rR1OZBZTHZDRhSBkSyMGkzgPDvF6PsvO
# DATA 2+NJ7iu/Jodc4Fmsg6iiPj0BzPj4yaPvVmwL3uJbVS4+jXO1sCKf2F058U8ALtbz7se5xZJ4xO9hkbSV5c1NK2EsFOKi1E+76G+H
# DATA WcjcgxazxyAlxpQzttVaDAfs9HWcP2Fp63F0mt6xSIHZob726PGTJyXOHD/N0hY51lvRPbrTgQpYq1BKmuDwSYAgyWQ15uTzWkSn
# DATA a+VkiLkBqaK1ZHxCI0JpnIyt3aLcT/oJDTZaI+vFnM9T+H7k9oIhatDHu+k0kpePIuzpfog/WkrWq77ymuBn+tUKCFFVjyWnAWKM
# DATA RaSPH2iHlStOM24p+qKKrVLY8JVQXFYSj0ik8o41P1g1XlSjnKMC6ERK72vbu8/2P9uvRPJENE0/PXu+++xg/8Xz59cz1pA3hmye
# DATA UptMVFHyB+eofmNUKBjlxWQuNgHqHem1+m4wUR0uVrZERyxsp5MMSIbD9hTbKF7ZwqDtLGvZN2kqFt9kgT0yd3MV7p65Oyg4m62D
# DATA Z093HrWUAhjO29aL3a3vbe08QRNw247nG9lui2653LbjZWfBDCdc97eejTBYzM6nWaA40lvRa9LeZmLIK/ss36hb2sY1qVL3464Z
# DATA 58lZ2zG/qnO3kQ5FVXhAky6LmMrQNlvKH7Fvh0+s3hLI2UoBbzeKPumWThXvr1NLqbi9KppkcNSOFgqoLfbSVXxqsxMmFJZ7P45H
# DATA TCx8VYNpTI1yOYq5tyzG35opxeucQ29Uf02rEZNOiLO4e41nolhQpY3Fh3xf0Fn4461H333xvIVB1GY5P2PAvnGeWQ+LAFQM4gGQ
# DATA O7QWI4Mpq25OEx0UDYyTC3XNLrgjOLcDExHGM/WYdfPPx6JVQQacgMY6QK0xWGqnwGk5CJSM26eoF2gUyR+kAIzVjikzQyLxHmQK
# DATA ZoBahFCRUHnftCxB4uXkRApyqTcDpRbyGFcUEWN2MAb3Wiub2DGUOrQv6nlxhAIIgezI2fbakTgnHZDS88UDUrBcXlxCwDs2tjkZ
# DATA g1lmFziXZHY98NHQLlywOYKly4HQzRphPVqAlv5O1l8kdzCaHPkktsUIeQQw87guIV+uUDXfhXU+eCI8448QklywS+QYzWpSZ7Nb
# DATA p0glmgxfpcBCDvsdzO19UeEgkBU5opz0eLIOIdK2ZELxFgydvY+trh02zzoiTBjSTnqOMLXquB8XupUyjEke9tn+wfZTiwdU6OF0
# DATA AchSsuJkoQkQgcgya/AcvKUZ8jS3I+DPWklLjBNGae1kEizp0mAttdZEtBHVFR1tzKRn+WSFNjFrBCiZosQNQpl8dcb9RvQuW8kO
# DATA UM48kTqfFJ6xsYxzhsYXFxfsdoZICGQrjKlYAD7czPdYDkQPvoQX8Fu2kPBLGFVYspbb2A7fYVwCNkyMdIGpzmHDOSDEMvvvAYJe
# DATA q2pRZG/HvLnxhc4ppk1CNDbR2axMb70Ye3ei1XkQ1DVsbbuy13NWzg54xwaZwRBCzBN1e4NedlpEzxw5qNwgLCvX9BiR3+e+CHMs
# DATA i8jkJFfEMQ6kEiHKYOVIWISi5LoOSh9dikrnNmO/zKasrsbWJzUQEpNACwE3YJI+qHIVBRpf/rjYAJqYXuPC+kIQmtG5Fu1JExWG
# DATA ejngrcw3IvegCaZO0/hX9i31JFuaH4B9HipxMz+EHTIgW7lCnLVFklI8r/5TH95aAygNVAq247uz3UzOXDomVEsIVsWiT5oTN+Tk
# DATA /fHkC6jtaLAek0oRH/NaLC5aDvPu1mSpe59uhzj3/CU6xE0vyNCHY8j5HD6uwlEl0g+8CAGWPwgtXLwFGHoqVniJ4EVe+BYhxXWv
# DATA QV8pL7SaoZJ2nM5YzVu1eZMbx8He1u7+FuejZFCrOOwhhbi51BBXWnh7cq8O0hCLPhc5N1zEXLoJMxqoah07hkU0J8vcUy99jfna
# DATA yKvRwoMly8oxj+wSKp4vnrhvVCPvuC6tRcQj8y4i7emYZFjNd+KhRE90rk4n7NM59yrybJa/rBSTmE4Cy2t7EhxnOQzO3DVUDV/f
# DATA J81+18dJqU/IYuDOmRwRMk01gLlif4ary+py+iOL6CzNYkRmyZJs7HDYgBuICKStjoa95my0gLWQOFly4HHvhBy43K3lVl1yleL5
# DATA eXEr5dlIf8PbvtljJ6nDx6nlRajjswZEUA+ib0QyU/s2FB7jW4zTsI1uL5XI3wA+Kx3eJnjf8GYpFTysLp67QcvA9ZqGajoN8LjE
# DATA 3waYUWukfiC4QnY0p6rn/nWbLuLeYJAWBark98MMWlQJbhmaM8HdRrc5gLeWaIaE5yZTCUzAJoE0wMVOFdHNPHr2ve29z9AN/DtP
# DATA dh4dxOVZdEtPd/72yk8rv5L5xWFdZwHJ0rtdjwlNLVTludRy5oS/ybNRCtzSB46zMWecYgvFOQ2cTT5HEtj04mxleImZW1SkEaa0
# DATA iD/LhcyPrawj+Po9qRHIdc3WEPpLIZe+K7mDiNBIHZ8h3DXynSg+SQfpmFASKqp94sl9tKViQzNs2nZxDjNyrW7JcEme9JI+e0ir
# DATA 3eqY4cjLYj80bZIR9vq6iW+yljncxD1ZDfA9+XoFM6re3L2L1R/6gBA3fzS5CjludXtjcjIZYF4oKeHbSyg9PxUt9A/1F8WvaSIi
# DATA 2kEx8NqY73q29XXOQMZz3eLuFnXdCrmPvGPA5Xyo3IesE3Q8S26xua3KklFecKI5aZ6z4Mg9WfDNOUaJfEuTxRlNhVzCFhuRo2gu
# DATA GpgzdxLqqaecME6PtpIPjld+1xmE3IUX8QOYZWOIgdTS8XnIltcNwadkBv6h6uoWlwqAIULKcr5By0VXDgP8MsVcrbEeHMrYVLqv
# DATA RiT+85ZjHx8cAW3I+zsO/ANH3umTyz4yJOWhxNSwblB+fI1mPAaiOTwj/xDyOVfBAayLmq2CnBmJA73HUeAoTWnadDwc9gOm8GoQ
# DATA RiymX7EVAA9N37iDDgE6UsjC8igM4bO9rwPLmTVzDHYchZvZG0aUEzAxl8uYKb2o6Nq4f+ek1wCVkODacUFncBs/F2kNn33OQBea
# DATA xVXYhCm4P6mUfZVvFltG5XRDHCMRR2yxcs5NZMnSV/u9Mi9SZP6vHKDOUxH/LKKs0oNS9fzLigXkIPVegGRwhI0cxdB3r6A7l00u
# DATA 9OhchxmXJliFrPdHNpmwisi7o2vf18NGqLdGoMWQ6EZix8A5ELpmBGYRFqEWs82LD56ldQH8ZS6LQYRfUTh85XRQ5PqG2XXte2Bl
# DATA sVra028G81Dxq+svjvtf4QBmokrono/vJPKSA4y3AfWMQE8cbZtSLaMZca8DFXvdHibvRMbEPEoEKDX80nwkMfE2kTPFN1ZzzWb+
# DATA HC8bQWaW9pVcv7Tgee/RGz7/JelfjadYkplySDJ9ZDatI5NqqS/OzV2NKBgO68YhseyAkU5cLNWPFRfL+Pa/SpGD8OP65PT/gRN2
# DATA phWAz8P6ZkIiJPLSUdw0cCSnpyd/bxzmcpQLjyEnFxes+TFK7OBFVEJ37Nu1mqBY6+vueCVAh4kkdyVzu2PH+NEp6akgFqiNT/rD
# DATA 41J8Jy6XrysYi6/ZT86OOwkVa/iZxCoqSwh7CoQksX6ElEEqYq+8sc4MYyjHf7WhkdR4sjYU5xp2exaPxoYK9OcRuaLQm46wbT4e
# DATA XBf1LuZYtuWFQygdox4NoQLLnkVEc0HLHkcNoaU0twIWIIu6ltuy7puaMbYc/aT1KpdN0OaehOp1YotLDJ4tROBildo9xGwF7OqK
# DATA mK8i5HN4q8CcDFelIGUzVSq6IWUiz1/FuGBFCw5bprfC21cwWHq+drGVQaD4wvemT7Z3t/e2LHXx13p1etvbhdHiWyPiUmXPb0KK
# DATA Wl4hdqcq6POC9hGqMXLCuZH3RLzoxQYtiwrvkWXnyjirXNj+aVbAHm0n0Hq+vfvYjXdrtBkFPPBNBDd5xUUAYWl+C9pESEsLzdPg
# DATA d4AUijqa2ZxijXvIEJHh4tmFOPPVhZVCEM9t9Q6tZblHNbF30nULPeq0vHUJWurLtZg7n2+FY/yR7C78RXI/26ul5uxfDrwRO/3N
# DATA 5SaNN9aiR5ggjdEzVrwxaNt8Z9PPPte4/jsKBVyBgAdG52LhAa3ALJnadE45M2VbZEDBoHNHG8n/gIU9d/NYAr84JkMozrNe2xqf
# DATA TBHYz+lLyQr03Ix3+ACPjqeDDhzjEZC/pB8hkVXHRUaEcTidRAQ3lGthTgQcc1bTCXWxZYwx3kqks1Jcrdpx11Au2XyuxQRFNZjb
# DATA nFnGirMCQEgAMlqIOrMeQ686ZqPOxcYjHBAeL20GGDMTE0Cc2b0hjN6imqDNwgNU5LlqIZE6hynAmtSjP1gzI4QpB9NU4+caDjy3
# DATA /3kD56/8ZEpB1WTgOaMc+uhkcTTqfvgSOl78MooNVc8iAp+pd5Nps7esgSvM5UdTGEwWWdhJRDEIyorGfY0KOAoPT3NwclhOFwAV
# DATA B1qVQiDIl6CoNK/Fnw9nA7PF4OUDR+onBoSdaDqAuxlCElEGm55mQFULYOJoRIIwUaoRejCqCRsFZkFlNO7BlrACL3PXi0ReLueO
# DATA jpV5aqxAXJDcAK5iKiGHCv3GS39+PMAX4z23iXEGsglc58e5AdWB5OvtqhPOoKjNJFmxQvbrnXq0FNaiOk1gIH+8uFL0oVaLBFmt
# DATA Fq5GqyVWCDg04G8nJTpzAGB/dPP/8FSh9Veyw9ro8o/e838r8N/d9XX6C/85f1fr9bX1tXvqHb+v1+/d2/ijaOWPvoH/phg7Arr/
# DATA o/9//ufnXru6zeKp24165TaxGrcbh1e3e53bjdvE2E2APsBWuV25TVkq4PWbv/vqx1/91ZtffPUXb37+5pdf/cVXP/nqx2/+IXrz
# DATA i+jN7+DXb7/6c3gHb978Bn+9+fLNb6GyxfBgE/87fP6XN/8IhX9cUKsSwd+/gh5+/dW/hyJvfoWfoFMoCk3+EnuD//0S3v7qq5/C
# DATA MH4Cf/8WKnKLUPy3X/0NfPzZm1/UoHsSYd1uXN1WOVRgEA9udYYUBoKSXjx8+XLwAH9EfeCwmi9f3k4H8M/DB6dp0nn44CydJJSh
# DATA KEsn+JGkZ/SdvuCmxdfnvfQCwyLBTyVBw9cXvc7ktNkBrrKdVumhojQB1QyYvbRZN22dTiajKtL3c6z6iFup7mPest7ksvp82O+1
# DATA L70OhAmrZuN29DLO0n73ZbwZMcj9l5PLfuq9652dOG/IVK6xGQ2PfwjLL58GcGhh4eMkS6swFusVBmWpMptl3uahYyGBN/6t6LyX
# DATA TYnrnaTHw+GriNLVAJd7cop3klM4SE6H/U5GR+HkFDjjBI7FKDtDxpkvE5hQOUJpN7yHY+ksSpMM1ROTIR6KtWh/Mu1cUt3huNMb
# DATA YNgliSQLDB2y1GcYEJJGTaj+8DmKtpG96aL1SPRF9G+nvXQSnQ/7wPo9WOZCD8heZ5z2cRq9Ns8MhtvF5+UkA3zJlvF9LTs/wW/E
# DATA U2LZM2h+GV5++PqsT73aLdEqZadpOgm1h0tQa2fZDauRnk9V46XAEPq5Ij/EEsjYp+OHD5a5IPygnYDbBNP9EYqQEAir26SCWofN
# DATA 0ocmaUyveiN7NB/g8YWF9uEDro7gwYPlhHcb9mrVP8aLhTMdo9rDZtxVgTYGyTnwKL2k2k+OGSxPkW+C172TRJAPeyho79l5OsZ9
# DATA TG1ZpTLAn16a6XL7owQ3cCTv/eKIgrrsHuLjxXD8itaGii7DeASoOGFmDTtYVcHngaRmMqAYoa4HazBlqj88OE1gCUfIE2uHNkBx
# DATA +A282qAGzdcfPhhBsTTCurA9LqPT5Bx+DM9RuouZ/05pA2AqR/qMq0FsJmLqsBZBXbg2kzkccOKw2ya4xS6HU1w6rKwEVWrrQq+j
# DATA hw86vXMzbiYNmY8Zx9PJxNsw7lJ8DEym6uY4hXsvxtsVQHutoHpwOOjArnbaW2TRlmGsiOcM7QDY5QUDffXhs3E06sHApiMAEpCW
# DATA 7hSAMhz2EdyrCO5HSb89JXVktz8k7j9N2L47ImofdcbJBVIctOtDCMN6aeSIOsOUl7KTTjBaIdwggHed4t6CgaPelwLXUCCj9hBY
# DATA 9B4KwRnqN8E/Pd9lRLiHD7rAyiMmjtwdBdhlgwKlvnxLwHZN7ihoDwo+VGvvDMUkIsM6W0TZv5WcjTaRXz9P2pc4oOj//pfoRuPn
# DATA VVOjXkaihPtJznI49E23fzjt/3DazzvtGS3f4pB/z2f82x3x80/4/w8d8O/5fF/oeL/Z6f6NHO6Mkfb09YH+/54dRAR//tkJlH6Y
# DATA peoE3VLHJovzoEc63dX5aU8Z+ZrETHPYFQdImDugFYlVZIkEBO3emA5fEuB5gCDwEEujjuCMxGn9NBlTKP8zOLQBs/oVOoBhEr2z
# DATA tBMdT3v9Cc4A6WPGU4aRvsiwCnFbanxqBtiDOdHbih/IfIaA2YHhoH9Zi3YmiodrY55vPPERcHBskaTZqLUVK5B08IQh8SINERel
# DATA SmwB7vUsozhG0X6avop+BLiCxlpKuXCa9kckq8JBRkm3i6uEDEnSTSeXeoafDadjc0bL1IDTyaLxdKBZzWM0dkrHtWhbEg0hSHEe
# DATA 0xFyK8hnKixEHM+Ih4ECmEJhiEwSkIcMyyT9y0mvTdwNzC0dT1DHfwJTSND+Qpm2YVvt07T9ikSepNohsaczmP/64/85k7milJfs
# DATA grL2cATtED9prVkteoTrH5FeniJewMQucebSFtbAoZ5jF+kZrFRXNUoSV9jrSQ9oUT+tEB+IWUyQUWbYDszIYU9MaLGhDpTQEInI
# DATA MUAQa/Tw8fBiwGweApIty9qAMWix5g2N8ZSLZMiEw1BhlyOFa6eM6KfDjJcWbQrHxOK/StOR2dRJu428f3+Im6Hdpvcn2FAPIyRi
# DATA 4CUCJpwe2E5Wi3aHVG5KqwbF0zEtGcJS7yhsdIQDPk0VkQD0eYrUpjfhKUDT9nYBiE0BuQnNZbeqXZm+BmYRp3gBjWlQdOny4izk
# DATA DoxYGy5lGNwDrfE6TGAidC+BFRr3lF9pJ8Eh1qKPkfiw7QEuyRjPxRRoi6Ar9IP+W/SNUUq4/be+5ix22Cx0w1mQTf7GmP234fXf
# DATA A6vvMk3A79+5Oh6+Bvblc0xfc0xYWoU311jpCjieYb9fPU7hLtwbjhvZGTR9eo3tXp0lY8CGxsomajhOxij6aZwn41K1OkpG6bi8
# DATA 2R72oQq/Ar6svIn0q1G/N3q9XK/d3Yj4C7ZV3kQrcyD5F9WLcTJqHAMGvqrC3DrXyRU30xvABulNNjG2f3WKpqPA66XVYbcLE2rU
# DATA VlfTs+ukcYrtXFGZDuYCoU1SBeRvvxrA3m2sjl5fM5JUeoPRdFJh+60K1sCz5oqGKH2pkjX+e9XpZXAMX8Jn6rrbT19vwmlxMqiS
# DATA yV+jnWKa6M0fwu7sdS+rsr/Ua7ifAtOC52pjfX30enPEzEEDIAE0M6rX6vh3k1egUR+9jjK40nQiC345QCPxGExcSMN81WtZzXHS
# DATA 6U0z+cwPFRgBr0f1gsd0d2NlE65SGbQzGlK+600PjA28wAhManqLKeiYN1fWMIFMDTK2mMqhgzR1SBwq2nJnaaeJSuejq9xEafp2
# DATA A4xi0kQDVgZPlc7VcJS04TbYqG1sqNnIHRCQowsMQlYFfrCHJ5BUdV8SUnjvGEW8lwph/LLTM9gWl+7bK9jaiDGNNW9RqRTgPn9W
# DATA uAxLc83jAHpdOqQrEh3jsCuPytZLXMrhUTmHw3STbtRXVv47B+nuAtIVYBd2X158HxvURcyt3bMQVyHbmpqEN/6K9ZLHL8Ndha25
# DATA KUOl34zE1TwRgW1XzU7H8NBYuXaaA1796EoNbuVaA8SCQv3+CrQNyNb7PG0Q5wTH1DXdj/T+Phn3OpsnQIZqazQzZ5usrHDpGk1J
# DATA 1ykiBtTMPWzF3/92q+vQahezLsD6X81cIzW7em11Q7XKAIRxpSdwil/ZDd9bWdFVVqLaOlS5Pq1XTlcrp2uVkZDw6mQ4guqndaZ+
# DATA 3B3er5BN5oYqmGkZz7uzUWm1to5dV+7WNs4vKhs1fCgDRV9Zl5EKTMqbfeCEACVQ7IoD4K9AEiizRqVaW1nbgKqbZ8lrmUP9bvt0
# DATA UwZ1PIT9eQYTXaNBry42uDqT08oaDG2VAI9Dq9+fMzQYy+oGgtPtm3pe456hk0igDi2u+Q26NWlnXCOA1dTu3mufXvfOTirZ+YnG
# DATA GsqEtmntV0GQZDoZXvOduEJ2Bnyiy1bBdHH11RVA5ApemEpYM6pGd5Gm64HwIWW3NBdX/YOLxOVw9k8u0nRAmFyvbXioXF/Z0GRF
# DATA gy2Eudc1kl4wLO8xLNcZlqt5WCqora4AQgTPIbhLuBMiukDcA/7DG29Vjlb6e03ikLlQ8PdpUe9RwieXSPWbyAIf+axHQ3Mqm962
# DATA vK6hNOgKgydQwW7vddrZ/LxKMhiY9yZuymodV3kTM24ApBHQBSRakwWcJ7XMR9AVtoI1r2vA0gwVcaxyzsC7uHYu1YN/tM0a0t7p
# DATA 2SBr1LvjCP6/iL7RBqX2oxpwDtANzZVIrGJrzJKub8BG4NLd3sl0nGpG0rxtJyQNtdqp3V8dm/2Js6rdp27lKjEfF+579eu8R2vC
# DATA 8Hug2VgxaE2lwzgtlYkguUNYeDPZQAXynSN/G/YoqaMIiKFbCkCHK3e1wFqO0xHcCktrFcBzWJTSSgVWFsiGGdF1rZ2MO1fWyWKd
# DATA OnfpqPexMJuOu+jCPYe/mM2Ocr/RqIG3/2r7tNfv5KdJRWooPq/UzqZwKb2yGQR6Aw3hdxt5PmIYXqBZvs0NfBTcU2H2eQOI7Dr8
# DATA /xr8/11krbx1Ivx0FoBkdu52KWDU9QGDjXjUkOfcGExOGSal1UE5UnMpWonVPNd2XdNyUx/XgQzAtJBI6CKRcAMMQH3w49GKpz7+
# DATA wBZRVmkdcvfu496mt5F9+N1bwfcwn95kERwFYArFUeTF2SWU1Oa6hrIFze2tfp14iT2RMifPIqqzpcbs2w124GpwB1JbbAx45RAr
# DATA ZvdsOh8Jzs3AAZkZnR/roRultRfWmBxdnJKzJFKrBlzKiIqqETVgKpNLPUc6CWtstu7w2LUNxTXL9ltlsqJkkQFOe92e3comlqqS
# DATA Akd6MXLMfu9qAXbDu6MA5YB7U6+dXtkg8e9jajuq7cHnbo0XBa6XJxYTpYe+ssAxwXWjBK8bcB9cAEkc3Ij00yo+IU+X3xD2meLS
# DATA 62hlMQbNHWU0sg5m+ZTB4T44ufLkBrBBkhNfOsKs7Qzc1Au0ypfIsYsz9+/mL5UFW/M48XhbtZNyZ6vHF/gknBkCaTLiSyFWadSt
# DATA e1Z9nSglbwUDaF9400my09QF8OFpr9NJB0fOBrrF6QGTweQattuVloO9Jtbdvhvh/cD0tz5n69ugvF+0sT2xWzK4vEAx9DXqRniV
# DATA u8lZr3/ZeAQs1hDO5crL+EnvWNm+Px0Ohi/jyhn8oXbdPQ+w7MA53OtnFphWF8dHkaVceVIpX2jl8euqz8i53dIWlkvUvO266Z6O
# DATA NOJVufiYFtfs4z7EdC7AAPoof9+M0tp9Fg5s4PkqBRyxBt1UFpNPAsU20mrvJlqADrVRr9+vjocX87ls4akn6UivuiKj6+YTEnG9
# DATA /9eFQE9QhEft+bvgmj6phQMS2U9GGXAl8sO+QNsYSAfz5LQy6fC1jGDRwNE45+hCyDiZxWtd12AE6RVRcibgjfpytU5noyUjspgG
# DATA 5hmG08loOiGPBB9YfKciK/0qqm0C3Cy6pyWT4fhKHbshXpYxWhE6jdDXf3KWdnpJyWLR7gJZK18VCh1sScPaXaS9IlVwd4vwJPnT
# DATA iZCFvSjwustgsnGG7qeF909vU67hzdUGpXuf1EKXDaLVdDe6ETOmmNXi8didh6+Qa6hscG+IC4IlxzAUX8tXu0rGuGFxKariQ/su
# DATA ZaPnqsc+KzY2jxfra4QXBMOK4nILx0NiGRa90Kn+kVkc50KxymI6uWq6x8Pis194ukREAvcfIuSASnreI1JpZtVx2pm20071bEjL
# DATA wo+wO0I6MWr8TuVOg40+4EfSxX2TDHpnRmRkzvlNUor0Al/UMNg7R+1F3oYVpYzyBR7MH9NqCvthiXxZU2dRBeIC5G54DPfTV/q2
# DATA 4Re6vnY0hspqCy0E4U/0+qw/IN0n2uU1lpcvLi5qF2u14fhkeXVlZWVZDLzQgOjj4WssuBKtRHfX4X+k9kWMj9gAEJ7pZcSEzDyP
# DATA qV59FX934Qgim6m1lbXO+kdo+PjwAYUrIWuhp/W7Uf2j07XV8/ufrq6f11dO4d/7n9bvfu5U7q5217prXBmH6GpFMzgh03ef5H24
# DATA yMNlnmYw7It9GxU0xliAuMeX+IXs5ox1nRg/6be20rlhLHq0DUDaIV34pTbAs0Dy0Uq0vr4RrX20Hq1urPTXVlaj+v216trKvai+
# DATA vuYCpnO3c5yu5KF6by1au7/2vfq9u/3V1Xr1o41otQ7VV+6fw98n2PTGyqrbVNrt1gnGdF14RfP/YH1jY2UjNS+reunXcp1iq/fr
# DATA 5+ur9bOV6mp9HbusfvQRDUYGEtUZK96yh9XVlWh1vX5eX13r1+v1aOP+91Y/uv/50/W1j6K1OqDP6v1+feVedf3e91bv3nend7/9
# DATA UZokuSbvbQBUPjqtr66cVe+uwP/O8ec6vF5bv39ar8PrjQ343zn89EZ+fPd4Zb0bGvl6IaaK+SIgagM9C69EEtwQDN+k+31DNsum
# DATA uto2Pri7cfd4DV9o6RNUof82NUOTf7Pa+CCtpxvpvU2RsTU+2Pjo7r17G5vMYTQ+OO6277exBomd4XPn7tpqZ5PV+42X8X56Mkyj
# DATA FztwXThIToH3rGyR+VgGpLCapeMe1lUkbaHiSJ5qaG0JLJMh6Q3mJqNVV+h8nxkBXVyfRnK/+SSFPd1LKty0p5rb9AVhyJxV7tXW
# DATA zy8q91gQRg2Lpdwi1/uZ8i24qbot+oJym82ThclXUDJ095xwSo0crpJZTiqA50+7h5ZEVzdQDxhdAEsAPbaIhVYrN2NuIhTR+oYY
# DATA rlRgpZCZdWZbyU1tHnMnkr0cjhHb8HVyKtf5vf5D3OovY7TeAyLRa0/IknxABpDRH2N8saj5UJtA1n40TceX+2QXMByXsrJVVhfe
# DATA Go+Ty1p3PDwrhett9ftQ1aortnzfTS8x9KKqgzu8huaAMFq6W0YfRi/jhj3As/QMvbM57djTZFSiRnWucApn/Cq9rETdpN9H5C5H
# DATA V+jwD/9yAxwmn2zK9nkQmJF6B0Bdsgb1IcYoK2/qrMKUXQU6nfb70bejEo+idppk2FkZXskbaIrfNKwBNCJ0/eRYBBRsfzO6Rlfl
# DATA 9imMSnq4SYtY/dqeNTnV87QlVeyVqp5xdfVhU2DhzD8rmH+Fx41YMjjpdS9V2ioNFjSxCcyli87d+UEmlyW8PJf1UqQYoPaPSy/j
# DATA D1jy+zKGpjHYUNrHFK01LC3eGVAQnza9Jk+HF4VtMjN64zYH07NSr1M2s9mdnh2n4xK1+RKD/sHXmoKmU7UjRqQlDueGjXM8C+jp
# DATA ZYyPy7Cde4NN5ebCPi6xGf10jMN/sfekxhaXz8g9BJ4xelv0McbQO8R2jirRFTZ8jYvBVRN7I3Ht7X5K8TJexgmBIamh9R/GrBn3
# DATA 8UmNF3cTjBhftfu99ivYU2h6etA7S4fTSalUxj2Ogxqn58BUmEFBO5j3HfhXAQUPBfUbahXwNoGd23AaDtCgudQd4MRxbbACBcI7
# DATA w0Af2+cw6CcSawXayKbHZz1YyEqUntOyPYRq9LOGUWPg72M2zCrJUlNDcB2Hq9D3MHtHb3JZKkP7AyxwLUP9YxzeITtcJOfpEQyy
# DATA BhW3k/ZpSYw/qaM+MM1ZwsHoiLrAgPARx3N4JD3eYgrYy+hviQpAj6re4ZFaJYA/WsdjXM4yt8/vLymSJZWvwanSn3bSTIZhCCJ8
# DATA hf60kdxkS4W2xxW2TN9waPu0aUuXGK1T13GRH/v8NiDmPk8HCAz/Rn+j60011JKpHlgbwhfsT03nfYBK/V4AHDABLgVMNVxtS+c4
# DATA Cswd3IyCxRvRYa1GvzuVUAm9UMABZzhNGgeRV2syPGgHREjdTB0NVm2HPh11lDG5Y8AvcP9YzN7DNu6bXIfbIpP2TMzZ0ScUGIrz
# DATA tEY7/Jr/30VvrfBycXz42iA4FcnUssEnDRRduXgJuTKsoW4FFxEbyfEAL+OQJZ89LPrOA6OfPABaBm7e4AN/V5SYn0IoSp43No4K
# DATA C2Ji5Fr8y6xhN2QsLzGE5xnwHoxteghFmFMATzUAwR71CPzd4AQug8j6RMTGR7pfeOlhmdotBXi1qR0qwpiFaGPwRnBHwQfZVX1C
# DATA 05NQci4Apz7crYgZoyLq2Sf3vDV3OJapBj8BmeITU8vfZihGX3wBo0aEAPp1VoI/wyfDi3T8CIBX0iCGjZBR8DXVpVMbuCScOOE1
# DATA ekxAuZXNyNoQCFQX6eCFjRoUdBGD98B7m2i6ozGYSHMpR9/6VlRSQ2s21UhwUNSQRgENt2ZTpoL4i0VYrQc936Ih8Hajn2Wey4cf
# DATA 8kIJs4OaQwV+ejDsDj6VuYRpluGB1HHFnEgSqYjXEAvoRvhbWcp4xwe3RVhKI0wzOjhg5dWKBjYj7SPcixZS4HT0Os7cwE4l6AjH
# DATA KGgKQFaNlF2Mw4LCcZTKzYfEM76Mv6OdwnCbfFhCtu9lzFsP5n+Hn+kO+P+w97ZNbhxXvudXqY0bHpFmdxOFZ4giHdQDbY0lWZek
# DATA rZgYzYsCqtAoE0BBVUA327qKkOSZ8Z3wxPrG7MY6YmLvnbgRu+/2hSybMxzJoiPufAH0V/An2fM/JzMrq/DQ6Ca62U2mbJJAoSor
# DATA n/Pkycz/j5v7NLmHbXXXqtdvIMH/6+u9j+m/8dt6lpwkU3a1esHU82nGckMC4MNmFAA9tPw9ZDzdLN6av8vnd/3Hb60HdYQ2eK43
# DATA ksYtM8D8QKY7mO0OZp90MNsdyH6pD2R7he3G6hz0pT6obTxn/HPhBODQOr79YMJqeRjZ4hCwEX16O7+dtxXzObnLdZ77qpxqPEm4
# DATA xXaUcvzF43znDeppy81QL5IhGmaloi3rXdYKnlwIhvyteFC9vHglTbqXIHPlTUfjno6G8mPf+cnC2hebqWQPlA7+W8/wF04HZ8Dk
# DATA Dhft61Tu0IOh8oI9lE6PsKnYPD8R3YBsEPCJWF2jPLXhgqaFfBx51qVxzYNX18MchML8hOPBu5TiJN3zfjKJxnzOt89n9+khdZif
# DATA K6tHYQ1Q66hOerINgTFMuJveDMYCBTRWugEbKu94JR+31hHg88QcbbIWyMjex7k0I8PzYxxzRoXD6W4mOngfzoy71xvjMqsfyTti
# DATA +mk2gdmQ7XmwpfjHjE2qpA8nD7WYEJaaajZkLicsAdCfpWRFzBbVEF7Ow7YmBGe9OevtJOutWMOcvo7T1zmt2bbSQDwv3Z0H2MJm
# DATA yUHgNfBtQjjPKPC8OI23dcMldvd5tlxdwZLj9Q+2P7Aoorbk6Gtc2OiExI5ln4DOZOUFvDa6/ob4RHUDHPN6FApJQjPPme4qv8Je
# DATA Md7+sdfgTURaw5qSzxuicHEU8H6jhtpMEk1499Ge9Ow3OY6lqIoXwlQHfNsgovopE09zwUSzttfcYjTFM0I/ay8NX3hDHK0qUvoe
# DATA Eynz0BsJd/h55Kp48x3/9WrljZuJsgrL9zTUPY019/gVdRN9yO+6KdHKk6JsdZ2bahWMHsybwdSWPCKzgZ9gQyId0Xt5T7BKp1oN
# DATA xeilq2Z+SXqe+IBfNKFxeio5cFOCwPxJ5Zas09qh5Jf0DjVz5Y5lcAaYkFkdgC1NxUajNPsZpQrCL8agfJ8GQ+qfxWjUXmur/WOM
# DATA jcbc8tlQNANtnIoduefdDUOPz8QqsyDTw2duQ3rvYQ1FqXpiImBG2hlk08XRy0apGOLU4+CN2IVBb5vMhkP+cYZlWBrU41Qb/z/N
# DATA IlHeEREb0f2JuzFlsUjMaxEpXeexYJtxFMgsgWHBpjR6Isxr4gzTQkrSWDo/rXLF9voQwvdWL4cxsBuxXiZnGnfwUiRcGi+/1WwP
# DATA gM5wdobzSYZzyUBylrOznNebw5dAsfIhvY0bRyaaeUGoWkNuNpc0GzG4GJ03VkR8FE2pQMf7Im1XlF4UJljSx7iVKAnIXClR9BDL
# DATA RnLJP4vtilIKasviG4Ma689pIWfd2CnGNXGZGZFKWDDYpwS9xUCiy2LYSb+P7V+Q6eO+IPMGySH97FEJyXDJeb3nKeMCkpYUuwOM
# DATA u+hnkj53DJznlnyl+Kw4OcVBbxqwN/NuiuFqaEY6kyI7ae+xUy7okY0DIc1D6rHylGHk3eUpg2yIZtRpMMx4uxgsHSRxn2yxTPdq
# DATA IRXegHozLiVOppzyoRDGLCoONyKZTvsydxIjRvvLkhFZjVOlLhjAKnjkaaWQNel8Ozjinnh9QlGG4qpEGes0PlD+x34UUbLCuM/S
# DATA fjS7g6EGgUPsYcQ+BKpWU9mCwXRj+gVNEb+wCeg9ZAyPx3xBBMiWFTNl4RikqqgTYiy67uxIKvXRFPUZm0TXJPJ+lC1JoJgVhSq8
# DATA KKhqqjpZqey3PIQqPCrZEE2QR500WmbEokh3tB0JwlsQxjh7JwOd2KlKTJJq733ov4SUiWQXsu2H5MPOm5ExwU88Eo+rdikzpAy1
# DATA eyTvFHtST6W11Gk/Tke8OLJsbsuJekh5I/NxMHonOEZKZpJRW6cWZKznfPE7E/+13E/5wdWRTAE1PQ8ysYW5d/Le1+Ke1Lsy7IFN
# DATA aQXiNj5kajyP2DzG1IAMXyrpYDaN0W0EKet0jZTyJKufSocCLpS4jclCwHU1pViZ2h+Pk0Opn2gl1ETQR0KwVSf47YTDn2JfJXJb
# DATA 2iIlaAJXAneNPLaJXWL5FdD4qZSxpSEeGrhWytOFlIqbso9sJMowSSEVOQ5IY0dGsKAgW+iGeYowPiqryZr5hC0ra9n5YjO/hNb+
# DATA Z5/tGIbOdB9w3vTIJuj8v8e/nP9h/mz+r/MnipHzZP4d/e+r499489+DaUM/fE5/frOIzvkf9MNTuukp7mf4zXfHv54/8ejL7wxE
# DATA 5xsKVC7zV4B2vjz+9Y53/Lf0HD2D20DPeUZv+pYxPn9PPwhT59v50+Nf6cj8iW75g4B6ANtxLJ0rMJtBp4zjS9ThdOmfaUE0ez9K
# DATA KJw07mkTbM975/FkKOPzkHvESPqGbBBPqLcYWt4I3TliFXES5T6DfC6UDIdqfKKXapnftVAdLCeq8FRLcWid4vxG9yAXDdZZVjLn
# DATA h9fJq465FSZdfrn8wFD0ps3d78l3HtG3TNjhcU0N64na3IrB1AF2Niy27SN2sPYesfWJwtnJXYxs/CL34JDJoqhgmA5oPOF8ZLn9
# DATA bIqZamm3skZqIghzKCWeLvB1Tq5+qx2aS1rWi8LsnJwMx9lxlsB5WAIauHNGA+AVcW5e2OB/LmP/RkP/aUf+ixn4pXou5kPO4Ll8
# DATA res8YDxWDjCKp/jqJeldBHnQ60YTtZKoCo/yLMVLFfgmkqzJVN7seEoC20sHR9PBiEORAyacQZsieFSR5QuR1BEPGS8zw0otVNKn
# DATA yO2p8s/KMbl+cJBgVFCsGR1jvEDgJjyc0oPaYlDn6m7l9oIQi+D7gRlxGIyntlusl0wcY8cxdhxj5zwZO5uOKhtNcza1ki/Y5D+L
# DATA xb8Ng9/Rdhxtx9F2HG3H0XYcbcfRdhxtx9F2HG3H0XYcbcfRdhxtx9F2HG3H0XYcbcfRdhxtx9F2HG3H0XYcbcfRdhxtx9F2HG3n
# DATA MtF2qo3grLSdVr/R710h2s7i2vNGzB3OXZV72JXp8buazYJCWqNeyvV6s13k5kRRu6/ARjjcSNHrcaC1JsuA9DjUqgTDUhl+vVmE
# DATA +NQow5egkVp1r16teKDb+I3O0G9XvGqzRO1p+o1Gu7tIyqnXvLrf+ZnfqQ/q7YNqtTHyW75X+ZlfqQ3qrYOaX4xCrxrWu90liWi0
# DATA K3ki/GrHJKJWDKDaqYaNRWIPZaxXb1UHKhcteo55YIGe0zwDPYdrrEXPocpfoOc06u3gLPScRhj1/Zye06w2/VZo6Dm9drcfdnJ6
# DATA TrPZ8NvnT89RdXyXq7EZF2pC0NHDbeGmZY6qGo8jO52Dw502W1KFNaZGb3BrY9JO+W3KwW27tsTEUHfhaMF2cDt2iIu4HTXRbBtj
# DATA FWV8i3dyDIIwOXy94sG7UfF0SRYAPdyuF1+h3e7GNG/J+kkh10s3FdbKZDgvwXBurdgPsDhaKUrSMk+trNuuCVl1NWpo0w0lrxl1
# DATA E7+TXamqz1hN8SmU9gk2YiHz7MJUidGTF1ghjrLjKDuOsuMoO46y4yg7jrLjKDuOsuMoO46y4yg7rxZlJ+6L/YZ1D9T4T+1vUndu
# DATA qxFTDVzy2w7Xxeu3PrMwPZ9KviEzbnMwOHVkgrlBTwC/8/FrNxbfoSr1LT2gqJcs3pjfog5o0F1s595SkKAPcIxLWj6b8sMjPp2j
# DATA 31qO0p73V+oMvHUojQ+eoaypQpko7Oob6IcfrBvxt5QVxmY2SeXFqb3p42meZuodP37tPevknUkGdZcqBTLRLZ3zcUfQ3RH0jY+g
# DATA Fw+EubPo7iz64qnBlXqbl+GMeqmOF1qLLU7Dnj8WoEVlznK1FCV8G4dRkBXQLXwiGsqWIBfxSJNRdybnhLWSCm+lK52W3fQMOieB
# DATA 9RkxlrM4n5IEpVfBhToRPb4uyy4ifksOg6pdVov69cp2RRXkT0oNXgmH6x9zPXNzhbfbQv4z4nBM9OLMyurVKu/GIGZpdPlc1Hi3
# DATA 7jDdp/3UgkI7LEoc7kSHJvexuOsqQXfVpXJYP1SfV98tx+tZ5Y4/rb6T+1wlM9uLVt8n/Tannz+tEZWXg6Zazl3sUFvNHUPMGi33
# DATA Qk2A/9yWdc1/gbeeuzo9D5BPOs/LeVYS22S3vukFxKrmmpfOODf+/Nv/ZtJRjriV/xOWKEWfMwwmuf6qWkrkPWnpDBIJsNESlmIY
# DATA QwmetaihVhpTLWQoUzCZUJ1kfV3qmNH6aBI7nsrxf+ixTqF/pHVoWauaFz+0yOwhVW51WFz5vOyWmZ981k0jP1htHGe4rJJickYf
# DATA vaQL7AvmmkL3WiCAsmrrqYoor6inLaC/+5+rC0hXeimed1EMVJEzXUAPDxNqoyl1bJ4+5ZcpE4T6pNkYnkgakiZ73rs0ysPIGSUH
# DATA IkhBaWDBAQgb7EfcraKAZP+wKqdIq1uo0nr+UjEpuLByMd3CaYvlH//H6mJRXYyUisiB9pKUJiOm5YzVRFgu8zSny5qurKssn7xJ
# DATA gIYViukgCr596sOTQ1VERTuSpdnZLC6Mg9bleAoj+vlLyU7RhRVU3i+fuof7zeqS0n28FNVHQTryeHdX3sUd4prAccIDaGFTyexT
# DATA wfD6Bfq6SIb7cShSGhGrx0JnOhoDgiMloGYD3YjJHfFUNDmwO9b+makTz18+eTIurHSeZwT6v36/+Qj0FgbZKJUhwdIBH7FdTfFK
# DATA HylLm5tUMGT18sAbzWj8GQYp9slNIJ+MjPZ+JsajGmDIRALDQJoNSvz5S6IQ3avQVP5p06byIOlPvS6qfYDSybs1jPFdyqIRtGyg
# DATA GdOjkQeTA1aEDsKfB9ifo2p8hsJK2R6PR/EQ5w2QU1CpIEv9k1ksajVQQWRhFSlArQi9haZSSMaZCqhoBIpH0zYCzRXJ7jsfJNr3
# DATA qDWFePahfIJJKlRGDNAJd+K6YJXwz/Owg14NcRcH53autDO40pzn7BXxnJ2W130p1B0L+y/XY7tlzk0D6RRbNcmi3Gen1kpy9yVV
# DATA gbxComknaUPb+x7Pg+K92Eq2zvJeKiO6iui9mHJ1m1HHFucLJkF7nm8ksdmZtCO+I1GDPEyM4yJ3Milqn3IIjwDlNjJ/eUHveLNM
# DATA 8KWQBaRgsDNCkpCVtbCX1Bqlz811MtfTPJMW+AfwdI33AQ0UwLjo9hgpcEtZUINvlGbW60ZOFGZ1LipqK4l67DMhi3UqpYV5D6xv
# DATA Dxtxobd5UKgPsplNMou3q0ITdZw3eNEu1LmFHN57lYxHOwhnPjrzcWPz0a5rbh3WrcM+p9W40kg9n3XY94X7aStF58TDF0OquAhK
# DATA OO/9QfXiY4OFZU71U47XVrcurBfmC0n58tiqtUV7ecNerVl1f8nRXlpKWPVUwf1b8GmveqLspiy7WVc9V/aelb2CK1dOC6XAm6wQ
# DATA U1SnMA65PshC0w/e0PKVqljUveCXy55TYYmrc6aadF5eBMchc83fsy0qT3PvqVO3bSpxmelXb0AR500Fo6NCA7q6CHEsNE2ZhDpB
# DATA T58pSzUZ2m+JJno8kRknm+CRnkkZiCS1H7NaNWNTgUKjZ/Dc27ojQd9iD8+eEgjhCYAx2dVTH8ESl75H1h1DcS3zvnKKCYS7sUCj
# DATA nriZLBZcPm9c7jTO61q+txAcT91HUUmXSvhkBvjLYyVbcECWQkpGBTbgf1MQv2fz7+jPH+dPgeF76uEbY/megfX33fwJoHyLdMD/
# DATA Of8TE/++Vnc/nX/jMSjwd/Nvj//3+R/mXx1/Sc9+qwL9RiEEvzn+Ja7Rb8+OP/foC4iEAgIEmRBxkOcALGRu4J8cDPAqWP2Fvrsf
# DATA HZLtwJPoSQDpWgUBQK8+6kM+ogvJLo0BoY4Pq7J3FVY36TLzQHXPXd1p6T57NuHXoAlxeGRk9MR/Ek1nk7UIwLuQuvDCWYbNLtSe
# DATA HQCwYO/rXuKi+X+LxXJ+9D+2sJiwkt9aqG9lnvnN6CiaxBFZG/r+d9QFDypDQGgn6ZYxgKwexkjo2ZTHf3VGi5qYIwFuWoTbRwFS
# DATA X4NFcGrz47iPTodh8Axxxna5NHkMDZ2Izy6LKQ+DFbWQOrfeFFsYZiz9Lz9mavOJ3nuiK5q4VMkSZ8YNpnHx/ngBC7h5tVxt6yw0
# DATA vBcFB9w8MQ4S6CyE7VkIGg14JsPg1XACXphRcA42wUYmwaktgos1CKSKlrPDmAGXplWdBxLQSrVa/loRRQ0XY/fFoyNvPw3CWaCg
# DATA f1m++gAZw+IaG6MGi4sSR7LpE0vzB+x6wlobyyJmk6iHkd+YYhvBAc24zsrclOBM9tFRBvaBL+MKuJv0d1E5uZ+lOrTnQcUWx2cD
# DATA sRzgo2MCnoqDYqsh+ZOULmW8lqpKW5lvskjIkeUbTfbteR9EAMjJBdm092AGMyRNZvsDbzamYprKGXZ+ceYwgg4j6DCC54gR3HgY
# DATA 2miSdFqD+kLnCGeZImxzhuCogo4q6KiCjiroqIKOKuiogo4q6KiCjiroqIKOKuiogo4q6KiCjiroqIKOKuiogo4q6KiCjiroqIKO
# DATA Kuiogo4q6KiCjip4aaiCUSsK+/4ZqYJ+uxrVgytEFSyvQG/EFCzC8zp1C57Xqhh4XquYr2Evqof9JfS9ZtWm79Vz+l6zszJv84IZ
# DATA +ZW2V/Vbnu/XvXbL6zR2/UbV8+s+lRddrba8druE5Ws1O+1uexmWrxBl3oe5GF96oYU89Fsmvo0iYLISNXutJc9Xq9X8+VolRya2
# DATA N3u+Jq9U+dWo5vm12fP1hhX/mpXfG76/0baQj/Va67Tv95t2eft5/Gsbxt+uL1K2/Hh9s8ebLTv5Nuxxw+yXR1Tym53Tvr+Ye5UN
# DATA Xn8aSKQ0Eg2JlL7MgkT2WkHY8ouQSPOIgURWK7Vuo1OARFa79VazkUMie5WwEvYNJLLea7bb9RwS2ffDZrt/7pDIMfrz3ezRUb7O
# DATA IUcoD6ItrDtULVeHtrnYfjCv1RZhwfSRl9FsBtP6JXtYVIbbwexBu6ho31uh2HdqK2czYmUhonrRQ3ERpQT1PSpLPt001/aaFtXQ
# DATA s7NF3ebpXS3FvNGzVuyTLzhaS0DHNTsU1H4EScduRj+Motcherma0mjyYaeU3DWmX7mQd9aWFztTTJGJPbhQTcR8qm6SUxyCo0A6
# DATA CqSjQDoKpKNAOgqko0A6CqSjQDoKpKNAOgrkK0aBXIQ4joL92zD1qFfHGTNK8k35qk+yIBMUcvF9W1EAreoGPU114R42RF7zr9/4
# DATA +LX/+O0eEw/vLtUZ4GeuSfjBRA4b4I0UzHUTThXh/K+vJJy30OL5+NIoGM/6Aev0y6kuOY9IzXkiR99wqCoQ5EL0mG7kw59kDmQ0
# DATA tBUIiYUzOu70vTt9f8Lp+yVHuNxZfHcW/3nO4q/U4zzXM/qiiJjwQeT8uLcMKz8w+pwvXj7mIrQ6ZbSDjKqJQp8PyCqr89podF1R
# DATA EnULHbMDJBf000GYbs1cMIqWrUZRSXIUj2Xdq6JUJ3kVSOlNYr8N/7qap2gGZbuqnDbeViAm6vY1E/tqY1nkq1bU24WIV/Yaq6Nu
# DATA xns76vqiqkfXwmg/jWiqfkIKrLBMCuxrJgXNpdlfs3Pfr67J/JUKnbqVoEZLB3FV1TmtEZd5iHRnKq1ZH3EvmH2YN02XNxl6VYwj
# DATA 692jvJHbN7DIvsjnS3FH2VS6EnlS8IymSuRh8M3dI0E5FvolrTvA+hU6NOpHyAhUBiLmexMxG8IYcz9+DBrCLKlxGBzJwCPFyWN/
# DATA poU19mcBjTjTKGJpcCVs8Ql1cGR+4Wi9EgVZEqMNBDxfvgPrpVHRWdbOsj7Bsi4ZTc6qdlZ1wapezVa6TMpXxVYQmPwy4lc/BX/P
# DATA qB1hFTvXOmI9GbjEd4x+k6CLo1GcTViCxnto6CpsvLNuTgTP3GHEZNYdT+/ZwKgUTbCMn9IjqD9li7pIcFwQuzL30dB/L1bSR4Mk
# DATA jX+RGMkbpeAfeFnQB18nSskoYgkmUyrZJMkV0lmiiEWj1CwiCrIjHnkHySiCKA/PJsju2xFOhkjx4F4arWlgjWFCcGeVUW5hFUGp
# DATA gWOrwoopQ8G2CSMd9/cgzFPsALF1Qqn2gAeZd4jGJpqNAzZsqF7teW/G4wR1iJ7RmF1tCIyjx1M2JHlJBRmk+tEkg9tK9bDKBJIq
# DATA MOKXWaDQZcbE0rT92AYjDJN9ncL7ONEs5SbVqjBni7EgC/WPOBcrMtwFkfAaHim1fO7xs0dS0/JxQ2+KFPnXjPVf+5Bq50RoRVKG
# DATA njIuzOOzYMBtI3un2bpEfShyXtIqoiMlmYWRejLiLkzSKKpgIj/bzcuDHYC5cRpMjWBYPh5RXlCFpTTKhFPpKVGWYZfrEPtLuCrj
# DATA CE1qV+ijDL5xjs1jCmBKxmEcgga7572dcJPE8GeUySACpwzGPjq/1IrNAgGJLasTdV9NXLqBKuyZpaBv1lMMk9RckUHiSC5okX01
# DATA OSs+zz8Wp156caowrarwFEj1Z3lfxsQCqbk51F7J7D/X+3xDnhgGRwodXjRVMuoJt/vOKg+hjOsJ45H0P9t9A7Yp3vlAjx1I0yQa
# DATA 9+Lhdt/Ce7jf0S1IL6HZPeh239cQgEU/MnuGqOGxLTmm1lZ8183Z8NwYtC/f/MqRaN3UanPJYDeReuknUqdFz14uCWGzp/c8GKbl
# DATA zN46wXSJ0vHJ/NJhgaAgGsDshizqCq/B614uHeWrKCG6IW7BK2ws10Z4Lrcq+WImG3sLk+N82rvj7UOhOZ/TYBbmBZgAY6uVmYf2
# DATA aAps68eKaismTdm0NCvNvQklT4K2v0VAt1BryXo5iE4WkkadHAUTDXLYqAyWlOiHacQe9YIadhZlmWYVvkKmW0646gaPorSAt/qX
# DATA +RNQp44/n3+nGFR/YMzVV8f/lXFV/+4d/x0wU/PfLcKt/hm0KgZSgWP1+fE/evOvj389/9P8yfGvKNCnO9783+iWP9L3L/Hdmz8z
# DATA oYGatRp49SW4VvS3Y1pdBZIt1WE8D2cDVTCWwA4Y9yxDBFlbMY8EIVwTkCtXnRPmZOLSGLPTgvulvgLzhHIpQR8n+2uFkUc9R8ae
# DATA rrUIqzexgRbtJEJn4QBWtgEqncBF06vKJXJ+7CpIQoel9y5FVnEVMze+zRXufGBVNOpN1KZf1FJsEk7C4Ij3EVL9eBQ5YNVJ5bZ1
# DATA TtWbaAZcApMoxVlRVqzHcbw+A7bl9KVHtju0TNQqiLUFT6/3Qyx/P43COII3GowC6lOjFN6ufDlF9YvxmMyhmeSwN5pl0p+JGXYk
# DATA VO9ePIkWKFab1NTV9kyp6b0oetUmiXDcKmcFnNkK0JiqMwz+r4Tn6YIG/q2P+xsN+5uO+hc16EtlLKbeDPIvqrGcB32qmERvEA0n
# DATA sE7I8ACC2UQuT3A6OJoORliRlaS/LkMthN5xwmXKH4CWRrbI6ih1mKAZvUsGfnBA42SmsyMVaTPeeoA12XTGWooU/1FsuEDr2VNq
# DATA dwQ8TBGWqCM+0yUDMcd+xWAuLg7LIGA8EY8FmZgQu2j/YcG84H2AehOFQgHxS1hAAagp+j/2VMDO02vks2kCeagek7ocYMoBphxg
# DATA 6vwAUyeNIxvNZTY3dS/Qaj+L0b4dm92RpBxJypGkHEnKkaQcScqRpBxJypGkHEnKkaQcScqRpBxJypGkHEnKkaQcScqRpBxJypGk
# DATA HEnKkaQcScqRpBxJypGkHEnq0pCkmrV6s9o6I0mq3+83wt4VIkkVV5434kjZmVJterVW+5Pd+q7fbnt+o75brVTpX9/z6f/1jkdf
# DATA iznUi9rdWmORB9VpeVVQn2qeX2mPdv0q/b+uvpZAUJTJlV53GQjK70jAlP6YBm6NPqpZ6KVao2kVveIgCZSoCK6K6kHUiBYiWm/5
# DATA XrVNyW54fq06qrV3/XpDfVuIZ9Tt9pfGs7ZYvyoNr95oDJoV/32/XvXqbX/Q0HpxFgOrUa9Gy4JcrLHNOsW05v+sUx9VvGpjl/7v
# DATA t0dVeg0VSxufd6tt+rL4Q+ml7XazVu2teelpUEfSQjTqSBqbhTrqVlp+NSyijvr8n406oq9Bv1JAHfX9sN/1c9RRq0tZFRjUURj0
# DATA Gp1Gjjpq1xsVv3HuqCPeYbLLpofNElKRLc4+fYyEnvxNzdyeDNhMI5kZrIP88MiVv3kD+lDBCdc0TjhZelsEFFlhLzrkeYSVbXP0
# DATA UPRoUziRtjSq5QC8U4zXax5bP3ivhBBZJWj7Aj0xoVenp1S4LZRqSxVtMX9WJ8eRhBxJyJGEHEnIkYQcSciRhBxJyJGEHEnIkYQc
# DATA SeiVJwn1FUeIj15RgncOb/e/L5cGR6GsHgL2Q8bNTmZ+ygK2KPnqkbl6FFGPrC5r+tA9hMsEof4NyqF95gN9RDGUi4dFEJH6/QEF
# DATA zz9nS39+dwxRJBgL9D6+72jpfQ+TaTCU83181/vBdLDHfoNr/RuHN7IbR+pmmzOUn2RxR6XdUeniUWnrXJM7MO0OTK+W8rsEB6lx
# DATA JrWfV/PgyAvwe0HefMrKJ1KfUQJGIhz1Zgc/QzZvOEwO15/1HcWP+fjxJE2Svj5/DJ1x01Bp/MVWlFkaZc+hbU4jYnqEpEwpS5A+
# DATA fdzyrpfNJuhUo1C16Dgz5COybBTYKKUBD7UTcnrDeIpFnIQmDxkrYQvIpJfORt1b0IaJx3weOzOHqvtw9h7w+d2P4MItKJikrOku
# DATA CtpZL0n4id5sApltOde8TkH7LdgQ6ZHso/N4iMqT1ofIOlQAESSX6jiKwkx3Z5LebJqKuUzlOEiGIZ91RcwpsTQHZjlwlEofv+1T
# DATA lIdHLBRuss2UnSjrsEw6TqVrVXROAyZyw2SKpNOlbnI49IJhlvDB4LUS4feoenPTkWPb9NYotQqPBZu7bG1ydumb40yfoj9EXUT3
# DATA zOI+Q5zvRT++57Giet6T97AhJYI8ejzkk7k4G5/teW+xWjPXXU8DalAdKPIIFakNQmwE4rDMMUSl6h9MTxJ155zjOB/SQGJ0BbEd
# DATA FeffPRylwcuo6QQjfh0NdFw6ShK+N5tK4WJbzUSdBhadeHPeG1eGsaJwoVr8AjL1DMfJjKL5IwlP/CscIpmGQztLYnOeO0hHZ9M1
# DATA f1OEqJF11PhPLWyORrhtZfP7yHwUXh/OaemdzkHQPGdbiuARioINUS/XIzgHTXOjzMhGzVi1PXSzGPPOQeL8Lnf7xlZSahIXpwT+
# DATA 8hzkzgNxMwo3oyjOKMpVyk0r3LRi4+nDyunH+U0rHiArchyOREdPKS69NuBFIErFkUaX2fPlXds/CYupHzAdlrmQ0zkqZwGSVlZj
# DATA PXPXHt3yI/3Fu/a9kyJrP2giXLiYUzzby+Jcb1hR7mxKUGV/IxNKhtMNYqluzxGv6nvBpFqImp2ZtSIhdU3UxOlJPxe8khtEUj9o
# DATA Ymku5HbtXuukiFbXRXQlCFXmrxitrJZ2dWmo0tTirCh2ZDRL71HfQq3D2zdz8R2v2f6eZ+qtNyKTOvNqdXXPIfzTNMuniXS0n6Kj
# DATA 5Kc0MgvTb+Fm8Y3cHfFXpcMmM1MDOY1ZrTbuma4Ob4wey5qJnjJgGQyTeoRVkjJjeS6rL9MCtpmwyuRpWYXApD+flkjs1OmDSKug
# DATA bUA5fXlsb0ffcbb3em++M7RfSkP7tJSdFyyEyjuA8w2yiwaoDaFh0cFAe7CNXqgkYTWF5oXKp14JWUH+e8tMo5LQ67aJRgtSuUt5
# DATA RhuI11r7qHMJW3yLIFyZBP0dQ9BhK2uWDZSBVaqn2CkuJat2i78xqN25l8ZYt8EuRfYi0iUw6uPHsGHY+y/nuZh2GBfNHZpAYhYY
# DATA LVt2UaqaImQq+qTqIANv4VImT9GAoWmp5VE1VouJrh3vB1izQszJvivFXGR3zaIKxY7XL0ybEI1RvSyjGKQ4Tobt2dZqEcun8tIT
# DATA ziKuiTCa/Yax5WNt44TpvxzfB1gJUgt0evocFcVRg+LCHi+ZDM2qH8VRwSexAoFFsNURpZcty9dXRrvTIgeR4dYDh8diB/3T/Mn8
# DATA 2/mz4y/mTwH9mf/h+NcM9QE96Atm+HxOv4Eu9JtFeNDCw/Pvjn8N3NAX8z8dfz7/av41/fgrZhB9s+PRpyfzb3bpiacI2uN7ntE9
# DATA 9A5BC62ECVHoeMtX9Aa60QGFLr9F/VPol/E6MfcmihZ2tCMLgrgkHa3anZpG++AvazlnWfhX9dUM7imLNhco09Qbr2UIvTUIRNXA
# DATA kgx3HCHLulZdwkWThJaVy/nRhHhDwCCZmBs/UheWM4X6cd5N34unxhO8ZZqQQI3ZXhBfkUX0edU5QpuU2NZpQnc9Aa8DBL47nXUj
# DATA U/LiwY+xh3bkyU7wPe/9hGrA2IAQqRAPoPcOSQ+sEbCGB8yyQG12CfB5KJs+UrgPR8xjFGcdG18Ca4RIbBketL5KrjZilrSzF4UO
# DATA Wp8EBw1yI/1pRnrNCTrjAP9quM4uanA/l7F9o6H9dCP7+Q/sUi0XcyDf6HpxreU8QEF5yiCiRQFki3GewuOGzZp685+O78yknQ85
# DATA MU5EFyAIMDH/znwTLIExbUVtCeW3jIIxpS4z6ZbUmuAFMzSaUBc2nm6EDYJ9NcVBfuQDhdRPqbfLB/1Ylvv1whaCYTE5hhgZAlAa
# DATA SVYZJPKRAJV3rJE+AeYn6Qu6GC+iiug9mCLZMXs84r5HreqR0FAOqaPAnkG0Qd5gkCLvtEPU0YMcPcjRg86RHrTZmLIh1Pxkm/eC
# DATA jfez2O7Pa7o7dpBjBzl2kGMHOXaQYwc5dpBjBzl2kGMHOXaQYwc5dpBjBzl2kGMHOXaQYwc5dpBjBzl2kGMHOXaQYwc5dpBjBzl2
# DATA kGMHXRp2UFTpV/rVM7KD/Hat16hcIXbQ4rrzRvygfZNk3kVYZM2EjSjsV1axZu680YtT2P8C9qlKQhTYp8UiDSxv4PuKMFS4vVmp
# DATA n3C7xfmhsD26x6Pfdv0O/VuhP53Gj+j60O9U6FrTq/p1utbcbXV2q/XqoN55vwpgUas9aNVHfq2xW28MmstiUq+uirgCGN3cL1Sg
# DATA etVHZOgNo13fqxwIomdNNkb9bqe5HJFUWaieFOdGtTJo1ivvI9X1TuOgXhnVK/XdeoU+lRFEnaDVbS4Lunp6GpDUeU0DkuZj0YAo
# DATA Gb1WrUgD8lu1dr1j04CqlXq7ERZoQNV2o9YMchpQtx/Ww9DQgBq1Vrcd5TSgfr/Xb/fOmwakjJLljg+d1pKtpUYibFzbXW+FeHQz
# DATA hp383jL4x0yUlk2KtBsNc92d+l6d+T9V5v8srkc1i5HSxo3VTYvtwgmhHA/S3X1MjcGzqITR/o619m5/9qqdyeOd/1SrNFrNLrv9
# DATA ru+sDqlzyqB0lLNJ1DstlUjbvPAeLphU1orc6sVxtRQuPuHdjH4YRa+HQfpoNXsoz+EdO+qrbY6S2St1iG0nRxJyJCFHEnIkIUcS
# DATA ciQhRxJyJCFHEnIkIUcSciShV5YkpEg/D61jXfl57uI5rjKGR7hBcsqb8kjThbAjAM0IdJ7eaI9hPm8lIxZAXzjkzcfbsJQkalUB
# DATA DqokY3V8TQvSFg+KSRuViZw+aeHOOLszzoWjNu6oszvqfMajzivFB8/nCPS9mLUu+CwtuyDLp2f1UejLJrdxEXrcanBB1aH6qiTD
# DATA kcprvdFJEs3mWdNh5VeMSHN7qTZ3wxZp9v1KUaa5sUbqmgc/SLqo3osvvCG2rFFRlntygWv90BsJd6a2hHSTl3vuU9+n8EJcT964
# DATA mSiRwCVPNDm7aGzxbnrTNHrEWpEnPtbgF9lmwAgGDcsnF5+9KanZQKj6HV0/UWU9VNmrq1L9fhRkM4hG42BtL0hzgeoHU5Hko54k
# DATA SaZygxxrhqxPsA+xZ/ijDmnM2vN+yoPbMDqgSoMOEJ3qSIXNzVjBaZLUCA+lCZmTe959XgAQ00geYL1FJexHw8kRCpoKIp4W5KsB
# DATA 0yoc25dzpF46wxlvHLkOcMAeGo5mPId+IFlsVGe58DOanc2ySST6h6yYHYxnfQzEKeZSEiC4SGHc7+PKrMt66jHGaQqMsTvLbD0l
# DATA QkBJmG4scP2ynPN18tbOfLXMV2evvhL26mm1rV+wZA+va+cLsOu1re/SaMRGIxuQbMdmuRQFcxSyNRrXFy32cyX0Ls5D1nqxXm9d
# DATA 2nqpptNZ5a3zRX9tjolFoWyfCGRRrnO5qDWbP0dk0ghQk5eC6HV73puiG0SzJBGriYIxTJSPICIkci8ZBjfGjArBkasbzCiyumIt
# DATA /Ew2XEI2Dxl1j+gNmhhyuorzEy3EYlSdjDv81VI8KeSMM4acMVTqU503z3nzin3nSivqBQsaMg8Y4OJkOBSd/TKwW7WTIMsl/Pa8
# DATA e8LpZitpmTxfQctvkia9KASNW6TokvSTWSS+nOfhc9+NDdTZ0HinNIJqJuAongpqWkZSj7VcOAYzbuT7wWyfRs37NAxrWuAOByBm
# DATA iSz3KLwDOoyg34dTjF0lucvTjNPvjjHeT4VfO1O0iGjUjUKIoIVRN6URWajIPISyCCB2KK1FWcvon8szCg44oKoAPyhrCirTINPW
# DATA BZTj4K9JxVmqxKfJBgiHUTdI97z3YD8hmlRJKXMDBQILA3QwQCJ0hyK8NmBhvGVChvwxs1QLxSWbgXr9CRV83IfO2yjC2l/cWwsj
# DATA H7CqNVee8RQeHPYimyR/BChH0u97+zRk6STKPklvOKNM7QVQbOR6DLx6cBgciWNKx1OVYabdOpx9PA5QMCrmlC+ZKHDDv8Qq3LeU
# DATA rCGkMFM+WaAqrqnOBbDGFPWHeSNelyIQrfQ6q1TzSCNjC2TCmQ+eC1VDcMq0LDJjEkp8DDIJyz/FQ/p5R/uhOAE5bKcXpOkRKzfe
# DATA pTwL2G+nAhLCvMDjNMfnIGBJvjyTPohiTpX4iZX6JVxy+0kSWu52eWtCDY1Gw760tWIRng32jbZ8xKqP1Mf84NSwb8Rt27Bvsctj
# DATA aeBKvzAeAxwfhecA/X4TzHslF6q2jpwD4/ujkgrpubyJ4d7voWlIH0PjmmzLyYSYs9238SmgjwwlEStEkyBOvUfwFgeLqTtPovjL
# DATA MdWx4DJJkIb78K3beJn/rjAyzxjqAjrME2/+dP7748+Pf73Ik/kXuu8P898J8oXvYvILqDDP5n+kj18xS+bpjmf4Mk/n386/Aq7m
# DATA KX7a1U899ejrVzoouo1e+OXxLxVchuJx/HceM2Z+BzYNKDQOKnMFMI1jzexa8MVNogQIaDVyT0Vg+i09XxO/xz5v28Ygp6BhrN3L
# DATA 8sI5ucsMfBQ9PRTOxuFaysxdviV/s2PMFGZzpme4aMrMYrmcH2OGE2ju+iGExCmvh/3yfSG0nw3QC/t9p2lwtE20DLWBjGzsVATM
# DATA aaYBa4xnYigIB5dZX1Rbp8qYTiiMyYznE3ti6pD5iqcgch8/9rheePd5e4C4bfexP3LZpnJhH0KjXSt9o8zG0ZQ1zbH3g8bwbIEh
# DATA s67mrbZTFtrQi+LHrIu+o8e4If25hnSNkznTSP5q+GQvbhQ/h0F8ozF8wyH8vEdwqYvlZOfbJl9gizkPpEw5oTlZxmhO5DGn3IwC
# DATA hZiB+43lBuDpGlORZrJai2QYfoYMq0BPHMQp42JQWBorQykPMlzEkXFDFMZqqAysp4DIHMHaYt+uhLgv28wwTaCP3aF43PbTiM8D
# DATA SLbrrW7Kt06jP6QQ+PuJPJJbGP85S1LLZihiRqLUwWIcLMbBYs4RFnPCmLEZEv5Ey/ZCzfMzcaqfyzh3fBjHh3F8GMeHcXwYx4dx
# DATA fBjHh3F8GMeHcXwYx4dxfBjHh3F8GMeHcXwYx4dxfBjHh3F8GMeHcXwYx4dxfBjHh3F8GMeHuTR8mGar3q1XzsiH6ff71bB/hfgw
# DATA 5TXnjegwdrbUKp7faA1qrdpBtVP/EX0v5ki31WrVw8XsbFQ9v12hDG0dVOvNH9H34nNUN9tdxWXhspSykoI7Eg5LtaArUe8Uy7he
# DATA L0WkG3Va5QCr1dpZAwwrnWqruRBgu7rdGNbq/nZjWJeqs70Y2oVCZbmFPLQK5ZQBrihlq1C2EkO7ULYSQ7tQthJDu1BqEvj2Wsop
# DATA Azy5pWwlhnahbCWGdqFsJYaFQmnUt9tSThngyS1lKzEsFMo2YlgolG3EsFG12nKnWMp+rRSiupCq3C8P/s2oVkJxNTv1oL4UlrYM
# DATA OtZo1CzomISfGiSYZaToUBf4adXG8wXQaHesABqd0wdQSEKn+ZxJ2CyA0/DMxEbTPDMx9yyeWVBv1mtRkWfW5/9snhl97UT9As8s
# DATA aodBN8x5Zq1us9loGp5Z2Oz5QTvnmbV79aB67jwz5fVQGxrMTEic8WRLsoPC8l7oRWozP2vzSuWSRf9iyGWO2Q8jMmLjYEdiUtqL
# DATA siQ42xHJizzF0NW678nRMNOX5bvk9O00Od6PNlsqamyyOG2FWl51tn0muo4U3c5VmcgvrB76NWuRWN3rV4teGF1deY/lIAiTQ16I
# DATA wYpbxdN1zsrbDjsseFZsZnMr9tPpSazK7cpqBpqdpyd4NKzcKtVJnixXHQjNgdAcCM2B0BwIzYHQHAjNgdAcCM2B0BwIzYHQXm0Q
# DATA 2qeqdsdUcLcVygyfKdE7nCR1EUf3kBFyu6hu3qaOjerMNVSt+HblVvwGP3ErvnHj+qe4yLfdivvXDuMxWVdkhx1NpskPYMTfBxRj
# DATA 9DMO5/qnugVNbjNojUEg1+rVTr3TbFU7zZscpevf539UFLq3YQP+lGbvtap0vP71W2Hyqbyj/Ipr3eu3PmPZzGvdv678zZ3b9K7r
# DATA t0TyDRe+x0Hf8G99FpGxrrTgrLgI/40DvKbicZ3uVuqjkxmNeqrb+0yih8pxW/388yQeX+PeinIQfDg0hhvqR1mgvXYt2OlScQQ3
# DATA ujtkPeaWvErtML690podxiiYYWxXyNvSPKjc6E2SNpo54rVs48uMAAfI0e4n2EowDq8N4+u3JI+Kv/OqNE3cVVd8x69cL96AIVjF
# DATA 5y3cuyenp6myfaaRdebop1NWccoqi8oq5jCwU1dx6iqnVFdZKYp9Dqor9yHHpRVAhgnrfbBmlxFeebFCXhdBp2NTgK6KJ8hL+pyY
# DATA E7B06qG8R1LfC2qyC0Q63wLSNW0cnb8GRsfmC6o+PmD+gaIowejUPTmMTj+0wIhrSlCPxURazZLjMekdeNdPutMXNWCyQE+6kRV2
# DATA Hx5GQ+pET7i3WlH3jskELt27ObqOqzdaOZfolaXW/VgzGmQ8ysh6iEIjtWfkdcjIMrI4Yr6XpXaYJLeZbA+L2HhZMkvB8u0LTgX6
# DATA 22I1QsMh59OJ14KMxLGS8aEkHnnq0L0Ri6F3LqjFDGp3bP0fSlONCmaoC4UtMjs3rY26qgSGG9HmXgbFkHwscUanMzoXjc7cunBW
# DATA p7M6sxPtyRem9feAUUMcSXZxAzmK6m+MTgMkG8W9NLEk8GZsoSr9u4Ba17gHusWi9p0ZFPMWpQZDDSlhKbleMhpFaS/WYyBbrmmE
# DATA lRZsXNhY+49TNrnzQLxV3SP4zCLsMsEwagBKwv6lwRR7KZbob6nzbosmqnLPoibyJ2WcKptD/5gbQOYKH3wGOi3icFT8ZLlBBAd1
# DATA 5JfansbnC06Q+ly0PK07TEdpP7Vg2MFpirYA1pTcF6+zA7Vx/jYbcKvu6iUgblBzOeCb38q/rn6GKxHu/hAf1liXMjBrC09cqLZJ
# DATA gkFijXlXKGHs+ZAGrY525kgH6pQMu4M91rK6o/LSzosSDoh3w5h2Ls5grk3pjG+v/vnz/6NpUlGOtspZZYopqUqqIOn0SIwxsu94
# DATA ZAKTR1uSPAjRtG8XdlfI80XvbhhCGo+eFhZQD42Naj9PFJmfDPYKHmTzT0ZHJqJoYjJsU3rLnvdmMM6pgONQJqXy0z0QYfCSWoUG
# DATA WUMJ0sdOzpSvpdpzhuytr87eQl2UXIa9LDY8JWQaDHU+32WeDA0Skx3JNT2x5lwLsAlgGo8iG8o2Gc549kzzy5lY9ExAUh597248
# DATA Ql71yVrLBoBVsemNS34VXydJxib6nvcO4It4TRhnvVmGAuKQZFFyG7ls2ttp83d13qqWq3MVPT51vVN80Hn6Nvb2BF7tP35bAysp
# DATA pDzB4sEYPPND4IOobs0o76gsZIqfeT4VaAdOC1l/6UU0B9nzPqQum6bed6ViS/UFAYo5SXxe0YN745b3pn0HzhCKu4Rn0mqT1573
# DATA I/oacUWm8t9aRT5zFq/vIQrZ/BENtDTJoCBSncfGnO1Tw98VPaecBQbtQKpfqEwTyUNZ8cmkL5C7UUnhpwkUehwTQnnwA2iX4mRg
# DATA xrqlgQkkGGso1Y68jH7DEorEjTN9PxbJU/DIDuKEWoh6OJCe53J0Hs1TdR7/eRbzyqcevHUhSAZT/aUxDhWbKyDbQNowkukQst3L
# DATA hvGE8pMbB/ctAJ3x9KbL+qbaIwgFVYzqosTKXZO3H02l6DgLsZCYJaMIF/ZnEXcceDoey0SF+qXpVrqP8x/83uJxCUyk2FRt0y2K
# DATA W2N6mEiHLFmL3jgThKYIJUdxSqPbIULR9ZhlbGOj8EvTdTT9VLV8sgVZ1RnvpK4JpxWptz5QkzsKG0+MEizk8twBPQVjJ6R7gc1a
# DATA ztyiuSLLxra5Yq5IZt2hBqYWeLWQsIzfYipa5is1twE3PCmUvZNYTy+DyyWfbTmXi3O5LCEoOC/Ly+9lWelAuVREhcJRgcWRcmiz
# DATA FrxhPMURZ1ZCYSQmKJZqNGEXTP4gnyfhjH3RCIbLrFV+Ej/JOvghq5J89OXOG9SRltubPvpeOF7XlrN81rl8uRAMpTss4yQWjqRL
# DATA ++0lqB3ytqNxT0dFqTzmfjdbzJ7LYwmYw3qOv3B61ErMoHrnAdvkpooAghyMj8yq1Y+SQ+CQj1Td+YHHF2bwTpFV9QPvLbo/os4U
# DATA xhCMkNwS/gEmYfGIK9w4O5TZwxQb7TxeOmb9/VgRXTWbCjDagGwz8HGhXUaGVzd5HC3wooq15V7MwEx2QFJ2zHpTSqQU+6uw5GRz
# DATA LhPmcduUy39mLOW/Ajl5/BsPRMr51/Nv5l8tEi5Ld/4pB17i/h3v+Au69pT+fjb/xjv+1fGX8yd4Avc+xe3fCgKTbn82//r4HwCv
# DATA 9OjD53TbH+VWx7G8Aiabl7HfP1UHEE1fj0Tz5Jx7gj1Pdst72UwmrLIhn7m18iA3YIwZPJiwR2As06g+Jqzc4OAnw9LCgDfPr6FY
# DATA vikyYILKcAjLogknjf6iAZalIjk/eiXsgAOru1cVjyno8lP5CVUFzRP3VZVEFRzDI7ZVoCXvlhgEGftrgP5RjnJlwTio5aYluHW8
# DATA 5V3Ypftiqxh29A53myEcbBoQZPosMbTfjvv9uIcN+di2LDtuIs0A17eOIwqDfk7F3b9AtNyoDq42S4qt60VxLTdKhANcurH+OcZ6
# DATA jbc8/RD/inhoLmh43/bovtHgfuqx/cKGdqmWhWzIMZcvrN2cB+SykEZMyYNiwrCtVBKAYEeTqQyFkxRdDzh1g6Ab88LfNNOlRk/s
# DATA 72OB5RFVg0zm8VSP1TI3ptsyMpsReBhThcTylxD+Mij+pZsiLpGNhgmIaQPFf0hdPc6wYQ1EoR117Hnb6wJWUtWk3YKxIAtCHEuW
# DATA SEEoyENkAFY+s91JlO6yVUclMBtxL3vLMhNwI6K8SwbbSrPBMTAdA9MxMM+FgbnxALPRTOYU9vDFmfZnsey3ZNg7OKaDYzo4poNj
# DATA Ojimg2M6OKaDYzo4poNjOjimg2M6OKaDYzo4poNjOjimg2M6OKaDYzo4poNjOjimg2M6OKaDYzo4poNjXho4ZrVZi5i5dUY4Zifq
# DATA XCE4ZmHleSMypoV68xs5ZbFWpIq1Shlek98lx4vIsnq7WWktyXBgN5vVQb0+2q3XPb89ENSZBR4r08hy8FhtAfpWseJaQqotxLXS
# DATA XBXXbrfZbgQLca1WKa7t5rbi2rHi2mqvjauC2S2Na73b5l+Lca35Fa9K9Xc7ca21t1IHWr12M/AX4lqvbLMO1FtbqQNhKwibi/W1
# DATA 3tlmHWg0t1IHWs12t9VdiGuj/fx1wAqOQqs3W4NmrXLgN3/ULuFxqUPtNc4GsaO+VEPspFu2IHb1JnUb7Q0gdmG/UYTY1aN6WMkh
# DATA do1Ws9FqGIhdr92Lur0cYlfrNNqt6rlD7LCHaldWN/ToWrf4dRatrs02Z37/6bh0ZadrLV9qbYrTlUPmcyqb+VKb63ypek6YB7q4
# DATA KqN8zXqagYmCmnJ1Ggt0OPjUsOAkf9X4d8OFi8dUp7y2kOGkMtSLdDpVa5ZR9s5GjJMVA7WIu7QIjGuv7C9YCZuzSmCNbbpYYxxf
# DATA zvHlHF/O8eUcX87x5RxfzvHlHF/O8eUcX87x5RxfzvDlWL1RoeTY50mJ/r585cN79PWm/lVAc2xsfvzaO+r4X2hOQuKwHpPMmMnW
# DATA i+LhNQ6dyWqin5ntfUz/je9OcZsEq35QADb1jeEwOtyQJtwen+BZEvjNcigcjPVoxiOCwZ05HUR30H71QXt3wP4lPmB/WvXDS3Pw
# DATA PndsrVdDZJE3Ps06phGKLAsILA/o+zotxBd7Tv+KnVg9SX0nd1SehzZiSYVgy8KIZR2HE1QR7ypAD4shUK5SG8o4MCMt9OEM3hje
# DATA weDtzwAF60bMBgss1W/oHtBkHeO0d4+uJhC51+qHIhPFiAalrkD1NtECznKinKu6Em9A9vOZcpxD70qFwNOoc9HjiUwrlMp0WfVw
# DATA rZJSqcnBe23DL1h1+0FCI91AnVaXza9afPuDAHKLRqY/jQ6DFAfqlaDoYTCUo/mBqqDeEAlhTgI70OMgFWEKiXzxPPQ0YJHUn8ym
# DATA SJI5BF3WKF+Mo85lQ20YS0kwxYY7CGzC8PAljAIjpR5krNKghLUCxtPwafV4uiZ674J6c4rIoRcxEbOENHRFggBmRoUfpApgkAwz
# DATA xWM0NB0OJn3kHaIX4vjitP2aSH4or1mSia/QiXU7FGcjOxu5bCOXapWTpXKyVGexjlda4+cmV/XDmNsAGwmBEnrSCjaUY48s7aoL
# DATA 1kS8CDiwOHcYggPrMY2Qc1CpXI8H1o+Z3slcyAm39cpJiOBaRQzZDSjB4nUCstc4mPgSu4Tw8hMirJ83ETYX8gg3lkdY4qii7Jej
# DATA XFkdZ3aN2VUXVesav/imeKaun5jNRQqz/p7Hubo0zo2zRlk7zOiG95f73E6IcR6AibR1ycrrpdG2Yq2qj450oxDnlUDkN2fxMLRG
# DATA NPQWV5eL/L4MwzK6BxM+esML2HouZcDJ3HvxKRGlDiXJH9BDEXhcd71+dMgubXYcT41HFTpYS4Tk91MWqjPj/zg60MwrIwH2U9Wv
# DATA 664QwLUAWHTsn2WDfM/7K7IUQp73UM9odbNk9ofYGSSqa5qRKa5s6Ui5sVCK5M1semBKR9MM4cDF01VTtpfYCLdHV2eEOyN8wVG9
# DATA YG05O9zZ4evM6ssjG6sGO90M2AeGtmCrwAO3Q2OVaYUH+VCnJEp3chVTHmqMwCn0OrG3CqMOAp+IZCeGV+VERJvrCxAlm8WCmZHD
# DATA IKs0V89MT85fyg0bEvhdVAo9i6DROXT85E34yWP2oeIJ8aauvlPcyTKFwKc15GTtVrScf6DYXn6Ccp4bp8RIPlyNkNT5KhDJuwXP
# DATA PVzaVGUApU0jFFMJmJpG+5Rjxj/LflhBYtFffcydlfos1ciMb6TbxtOYJsyyAsFz5T3vrSBNjyDKmoyL7vE0YGYjW63T9Eh5iVmU
# DATA FXsgU4kYfObJWPvJ1eTBbqT56o9uIvnqktkDKaP8muSb/NUqinSBN/tywwzAODUzkediheZV+ZTF/M7qYtaNQhWzcfrnSzKy14J7
# DATA DF3Q76GLhZETCJM1JYtdr3JkFrJetABEKZqXXiTwbJgcDo9EEjplZWN0rhiLzFIPlTlv4EMHOTC94nMV4fqkXVghFnqZU5bj/TUw
# DATA 47y/0i1W0CNKIjmNwGKlIWccKjFwLklNAsvbaRgHNAscsYHaj6ZHNJ7OkMexcl4FuiUr3JiZzPOiC42uOR8tM0s4NPg+xoyUfW7s
# DATA AcMCYSzAtedum+sSemHleuY++MHGfTBV2CndInTdyBszezt7dLTQ/2q2jRQrrBoRmmYjYxCN4mzC2tfee9xjBuwlGAbpPmSlocw4
# DATA zjSn/jBJpX+VtiKdaz8AIhluga20y+Wpuvzd6o827lbV2EX2FeT1kdRADVRhoAnWpknKuje6y0Qbi2KHwtvCp+MgjoOiVHzreH8M
# DATA V49MRLWFCccKS4PD6EwnKevVU68rxczx2Ebb2yBhV6JrfftUXauWdYdhEqbBIRoI704Yxn1roVo51/QdynqIAmwLpcyB7L3YO7Y9
# DATA gxkNF5Y2eXqz6Z7HLj+zlq22B/TSYII85yOhej+F9pA9X7muTeGZSvRiAd7P5aF9+X2KOQKzF9FoH/eyIgLzyfHn86/mf5w/Pf4V
# DATA ff4CPEtgK/9I/3wBjuXx5/riMizms/m39L8n82+O/55xl8d/y1DMPwoSk4P+mq78ivmZ3zA50zv+5fHfAaB5/EumY1LY82+P/5GC
# DATA +CX9+xt6J4WAm76gH/5AP9M9v6eXPJ1/d/xrh8m8Eo5SbEtDd6W6RVXzOOjsdfFF8RDWpenBDn/fx2Z3eFF7QNYpUMtBwJ6rwEwR
# DATA jM818OCF6w32vHceT4YwX6gzRWEh1sqgydWB1/Iz3xrS+CUtEfFzBE3bh6r7jIsmaC4UyvkxNLlSmruwtZDX1JUHcIG4SVU7Tszt
# DATA D/irB9Gu2RAiYdsEaMaZRAXeQ9nZGOHMbwB+0FE0dfTMTcruHMiZvErKq+XxCFNdhGYqgOqephEfUeuhHvOxfu/9KMhmavmWcmwG
# DATA KBTTFVBy1Fca33PGnCFvGg8j5bJO2V9OBlI4Gy7iNDerkqstnXJbe1FEzc3S4ZCazi44D7tAszbPYg68EsupF2YKbN8S2MgQOJUd
# DATA cHFmgNTLUi7YuM3L1qbOg8NZSj4nGm5qZheayJThm1qhOM+cAzgxhorHaR+k4dzipWej/JcD+PTbkBniy9H4yuxRNO3B770pjjMf
# DATA 8S2LgSKX5cP/SOyEEPvyoBoFhRqKrych8smagj3AC98UtyTcVX58tPMs431kHu/hEltEOxVpVEJyxR+laJ28UYLdVoFZRnPoTYfe
# DATA dOjNc0FvbjTWbDQFOo3RfJFTgLPMALY1AXDoTYfedOhNh9506E2H3nToTYfedOhNh9506E2H3nToTYfedOhNh9506E2H3nToTYfe
# DATA dOhNh9506E2H3nToTYfedOhNh968NOjNWqMeNqtnRW82+61++wqhN0uLzxvBNyn0mIZFrycyYx3Oy96R0A07ecZW66JDxb9Um0V+
# DATA YSfsR+3FXAYTsFob+NXGJ7ttr+F7Vd/zKx3+p9bYbdc9so93O7Xdxm6rs+tXm161s9uqen6LvtSKhdFstxudSN5RjHO1Xs3jTO/L
# DATA 49ys5lEWsqhVMRq1ZrSIsmx1PL/RGrTbw12/QtFrfdKhyDZru1X6odne9f32bmu30dj1651SbfGjXuSXmIfdZtAPqsuYh/VlSalL
# DATA 7Hsqxi0Lwli3klKs42G71+suITL6ba9WbX/Sbu7WKSW1jlehNLU9v1r5ZJfKolanFPpeCa0YRK16c2ncGu1WHjcK2MrmjlUzKkVa
# DATA pF/v1ZtnIDVy09OkRmnFFqmR4tLrbEJqLFwBqbEataPQIjUGzbAV5qTGVlgNA4vU6Dd67dq5kxqxt313nUlDA67l4xLb2DykLRkb
# DATA SohU9v3SjLje/p6HP2RqeGxu5EHo8dZaYpRf2Zzc0OtfteK3dC7BIUJQ2Pb5V3A3z0G0aXrLMsALrlBV7qcDK4r7K4dClvKkQXlC
# DATA f2ryp7BaVW8YbGSr8b2lhEcxFinNMufLl0utBazlCMeVqMYTK4O2J5fXAsmUql18G4dTKhqexZYmQ44D6TiQjgPpOJCOA+k4kI4D
# DATA 6TiQjgPpOJCOA+k4kI4D2Q/QuG/7u8JTlE3HgD+SNaORjw/0effDSPkzGfd4TeEicQFPSFCoqvew0e+az0jG3kjYj4VA1FzVCkWu
# DATA nByMiMhCPFkdp5ej9t4kjnqRPo2IM3LwH3ZRHkUOZH7yxp0Od6fDNz4dXj6i5Q6Ku4Pi63W3L80B8gfxY2lCOzQ+jY+w5B/LIUsb
# DATA fGOOPFqiqWgyQznUiWcfLZ56xlFQ7nnV2ek+QpGTmVkwjE4pn21ULcX1yE2cbk5GcI3a57ydcvYmytm8o4SrIj6svg/9JW77Gf27
# DATA RjObBsWp4A8/lI9XQS/b5MEpRSLfXC0SqXJTBCLfxCnOPo51Y1DK9SCxWcYjy52qCs6D43Q+uKw05TmCgOcw7ssJ5mTKFIiMhya4
# DATA oBCM14+oHg1hENGEJZGDx5wSTUR5Hu3Ms2bJWxtmyTtaE5TGZJ0hbwZD6AqwVi9HlxoTXzBnrmUJh2VFvT68y/Q0cooXSHheB+Yc
# DATA Dc34h5ogWX+xnMxHYONtZIxuB6fMl5+tzhdpUaqmzEK2TPI6Mg5SmpN6Y5rTeuhnGAwK6VYsSEBmIIf/wKLhKhWNhVAGQYKMOSL0
# DATA eYL+/uBIGzcvsI785YZ15MNkxhoWP5/t5/mh1aYnWn06GfWxaQSYBuoEJpheoUEwzUhhjEIyNWgw61HGDQfJDCfe9ryHmBCwtgIr
# DATA JYhdtz8MfmGEOp5TfTbvCk+ZPx+u0Z7VnarkEM2vvYm+JDn0YZocoA5Qmml2sx8ZdCxvkqNKE8x6UOG4O/ZmYyRX9zAQCGYgKrBM
# DATA QyjvQyqaF5dfYLu5v2G74UqtlFssZC0rMoySGdTHZ1CqGIrxkPIZWfj7QcUKQ92zQGk5lq6UzTJbiDeQ6kL9dTk/LlbK9lVRaMjN
# DATA bDcJd5PwjSfhbsb9ks+4V06mL7VkG+9jMTtahMrKu1ruvEENulzCev8lkmu21bVlK6W1OVQuBEP+VpY/W9gXKRWml2DnkLzsaNzT
# DATA MVEnje/8ZGFbpZ7kL6rLWY/xF05NYXwfFshegE8w64UVx0KqnjSB1/6F/CE+Os3DzSXVrbtKck4bCtt6ZkuVVN+C4WA2UK0x1P78
# DATA 23/SZgS/clAVKTuxIL1pNBzy1EWBJkTR64ewPzNvX6ysYMq0iBAqbDRjGcxGXV1cgZcOjqaDkbJm2WDlucF+LD+L5cdiZJg2Q9TM
# DATA 0vzyeM8jRLqUNPIO5VYa5YJzRg1Qr0ALZihHVxwG6YKmbrFAGWpkDEcmVr2CslpWMM5qc1bbxlbbQn1zaydu7eQMFttK4/A8xXcZ
# DATA 0NRXOvos5o685oX4ggbvixeEX2cI4JyfZ6+1LCydiK3ItmVYuFZY05Clfrp8j/pfPvvNV7xrvdFJoHv9qOnOzAWzwiAHRMrIeL8I
# DATA ureR8ZU9f/X6i9pQYEdWLm0SW/OwiW5+xcS3s83oqo0X9Pv7Wv93mkwLVeLa906KtgnERDu/ckI2V6x419ZGW5mvZsFMdqXyKpdU
# DATA +Yi3eJimkFmIKNSwO2/ImWAVZ7U92Xaq5Zek/4kFVTWhsVsZsTcliOeEP4ltxSitvAuwVal/mpn9JWh8xrh9X5ypRqmZkcOHg3gY
# DATA 5f1EDLXaKfbqpCx5a1Y6qDVHuXgzywOrFU6YuLJxRba+kalbqgJ6p5UXKlSf6Q20djC6VKvvoVTNRnQ/tgfn4bCedC8YQzt4QgmI
# DATA cU4xSCe80MueY6DI4a48HERiwOcdF1IGoWnu13hhi4yOPU/B7JBCIzSdzSbU9Sj94KK49E3O91fFerYgXDxH5zmEzeH6LTO4nhx/
# DATA KbwrkLOezX+v0FyAc4HF9dUigetf6LanAHQJWmv+b1Y49IkBW9/SPRqy9d3xr+f/bihd86/oxqf8rq+P/4EJXTjp4M1/N38y/zeq
# DATA NMHQAbeuhP3Pxr21dQOowDQB3nWEfoLrm7FjmNSaQZ6cuiRW76OecSyq34esGy5LF1p2e0dxQ/fR2AdBF/2UzNZFDZvrDMTOuxFm
# DATA COtgWx/RXSZCDrVVMP3znuGiaVulUjk/1pbQvg3/ibdkW2+17vx5RsWtbyxWsG0itgIBW2m4gloglMQ4vNYJxbV1tNaHARmd+Jli
# DATA 3ajsVCoVHjUoA6iL2vM+pAHEWD1MsOBJ1yCYYC1Y7/yfBt1biKTgqDMDoUBxRY9pIMDZgjJD68TqttpMKTaeFwXPOjEBjpvlhvdt
# DATA D++amXX6Uf3VcOZd4Ii+7QF9o/F84+H8QkZzqY2FpNs+usvUhs6DkVVIOCN+MsVst5NJk+4gU4tmIRbNurDMA+wk3qGExkD6UKOJ
# DATA KQnDGCypcahf2w/iIfyVvQCsImYLFZOF0TYwGT2iAU4vMMfjbIIkwUVKLWRTWlYeMmsGZPI+ij9Tmngr+oDqHNwrdJHPlPNpc/Zv
# DATA jLHCx3PYGROiJoE4YJOQkVliFmTmrDil6MERGW+P4SmLw0CdZI/EMIwy7EOMswHWMQN4NXrCXUG64j42IPYG0SjweOc7U7gmPBY5
# DATA lJZDaTmU1jmitE4cgzaa6mxoPl/cLOAsk4AtzAEcOsuhsxw6y6GzHDrLobMcOsuhsxw6y6GzHDrLobMcOsuhsxw6y6GzHDrLobMc
# DATA Osuhsxw6y6GzHDrLobMcOsuhsxw6y6GzLg06q1qvVxpnRmfV+61+6wqhswqrzhuBszhjOS4dzjhBM1X8ghxF028XM7zW6azO8Uqt
# DATA U18EOXWqjKRSQVlwqVal3el0l8GlahJIL05Zgkq9rGmxpWocTz4w1y7SpMJOrdVc9nyjsdHznW6n2V32fLu+yfPtqNsK/HImjKr1
# DATA mletNnepYjc6XL2ro5rf2PWrvsfXduXaru/Xdv16a7fV8vy2bwfNG0ZLeK522A47y3KQcWGlmt/qePWaTxUer/Yqg06lFJzJu4Xg
# DATA OmdAYHET0ggsaY0WAqvWbHZb1bMgsCpRJwosBFaVAmrlCKxqWAnrOQKr2m76zc75I7BoJrRLv280aa9Waaws+q0KI42MeDpEjw/I
# DATA Ge6TtuGU8akTrANItWtlWSDebPhpyWVijQELdwcls9+Y4m1liucP6FG7PA9cNufTXsI2ewlldRB+wiWLbc1iIooLATJH9OyJjzLk
# DATA 8ifMMLhkxa6M4Vrq8dEVtehhWAXtMs5jFR34ja3pF38/IZ+KL2oiOexXLGw9Wf28GadPeM2KKdxqrJep4BvhuNZV3tXT+lJlXlYn
# DATA Z8MTJ5ccBcf5cpwvx/lynC/H+XKcL8f5cpwvx/lynC/H+XKcr1eM84W6oE7IR+Etm/o1xZIpZwRSd1vqejJLexEqCNeqW3GfjUzV
# DATA MO80KjB4pgPACt5J0wRxfFtZXmheZPJQH53uS59sXnu7ZExbcwI2YXcwudgR+he2NXI5XBfmmAmEvlNX8fFrbNeIee7dy4/+kx19
# DATA lC3pC67f+oxt9E/z2GCrZT8eU3YoqhnLiCrdhwMr+LfQ+VBzhUt1B+cYR4GcoeJSx1u72KNM80t+kRU/JahLXQ1OQn2QGPvUO8SZ
# DATA RWV90m8cQarWnPs4tbOrf6RffrDO7uAypPLJ03U7T9n1TwuRETEqEwct0qjehNOAiIdY/bc+M8b8x6+ZwPcQN3qruXCD+ipQ2Oga
# DATA tfb8GORNuVHnBp89KqdXJddUtrXthdO5rPA2C4Ymc3g9BcT2suTZNbGhe9N0SFO+//Jf5Cs2A9LX63/xF/KdHqU8/fi1dxjx8Nr1
# DATA T1dY3sropq4wmz5gi/2aFKqTuHdqCmdSU3AqCi+3isJp1e1fqLqCccBKikSsz1Jynwaobnc+0DLcnFI+yDqDtGW8OiFv67P7ufKA
# DATA xBIPrXvwAbdb3uaFRaGVTxWyQ4wFq+3lT91ETLUOIR+NXSlwb0hMSgqBWvV6cftLJzZxBQ5X899bJicURTG2zU0oa40spSacViXr
# DATA ozRWpls8ZlYj2W4wZoxKltEBYeWyDBbwIYTMRjPRcDhiP/WOEdCXyqgqD1cUjJKZKNpbmh7QOAjYok/6U4YrpRG70ZnApYBbbOh7
# DATA vDDIeuPj6DH7eJWyxokco5fjnLwJwRl3zrjbyLgrKeU4zSynmXUKq26l6XheWlrvimATVWw1l1dOBK7mOdnnohUbL0LkXnkWdObq
# DATA pL+hd2JoxXF9G1TTxVOGy+wsKwisU0YOh+zRZgAC1op5dPsLuJhuoU+TT6+rC8qilm878g+7xdVtf+3vVHdqf0ODoo7RCkl55VSj
# DATA d73Ln7jKFhHE5hbTt+YPLRCAq4xsOEw83kqyBjxcF8Mb3MPSnQug4JVi8saHlVedq6sjjymPyEspG2mZxNnMCJxNpNXsKAmzvwwO
# DATA ggfSxSo1MxBWtBsUzUTlA+u9HY6LWmiimhUA0mK75JQ+Fg2YED0TRNLwSDlCTXOHwpUIcNHThzjdxUMna05Z7r89zxQXRkSykWe9
# DATA 6UxRmIbxCBd5oxEEqyASx7QLaHdlOiqlipBPRWwzOZ9aSGkVXaeYW+oVfuM6VHM+U3NOlp1/OSzUfJhxJqozUTcyUW1bxBmozkBd
# DATA a3i+aLHXDwqNZIyBbhqPcijTA1kmZQHUHYsCKKnz3tEyiBBYxPEdzi76HU0lTHishi4nq4UG+xQvbDkbHxk9yA0VXDm6JjZCgqJa
# DATA AEFHMQiosVK7j1jfEp3HEm+dOnG8xFKVPQqoYPxJ0YGUJaN/zI0rc4WlJ4CcjzgcFTvZc2O6pdWsIrPxgaE/8rloV1p3mC7RfmrB
# DATA ZMTOAYyO6BjlvnidhYkWqX3Jq++ydGwF42i+rgk5yuJ9Tvvb/GmN7Vpkg8tOAttgUTTzVWZjoYyxu1oa6xkA7Do3Tglg//Sz1QR2
# DATA yVghsGMSF2lGunLaH2kS+0NsGaWUp7NMtntxDRyzdqoS0sUcCGROvQIdYxNGgA0UXndGhq5STI17e97bMQuszlho1xvFGc8eZa8L
# DATA tisxRZQ3gcg1bq28MiwkBiCI6HWp4rM9N9q+VINOmcF//vtvV+dwoTZKRrOkaxqJ8C/8qnEvnhrkPf+S05dY+5aMatFSTSb61P2U
# DATA alvKOr44vDqNxT6/2+dD4TQ3GHXj/Rm4j8r1u6O7O0FFCf0xIGOfJXzjkH+TCfs2cvSMdXWUbVZXPwhGUhUgZZ1nndQWTHGgYCv7
# DATA fEXVFjrVw2gKJJbsbjJPe4zxQO/FoI8joGWF1jWGMiAaBFl/FB3qPako1AYF00BefPX7z6eqfMI649hTKj6ZRbNI5997mMFh0kYT
# DATA 6FyJ+TCI2ZnDF9Rx8wgA6LelQfKahFScLK+oHDCyvo+jBZyflIFjuJA4oKk8BUxvBIoiDZUotK1UPdO1nzIj311T99QgIXlYXqH0
# DATA pmlwQOPmIaVBZ+Z9dZRgoASyA6mWKdkwUZgpo4B6ufGUwXEIC3aJzE+oIY9Nz6B61RH1GhnPJWNIPFrLqjlcbhorOfeI5r9ahRu2
# DATA 3wvN14eb5utDJvBZy1U435i3brUclkb72A8uB0QoIZkaMjDa5Or1RvI8Y19FbhlG/T7nsN0PBN2MxatphsbuHblHVWf0pmL1xehs
# DATA fy67WUsZWjQSZM+ibSSYK5I9ZNfq3YV6YsfOFrXrjzqi3iCBflYAfymVpC6IV2LhzcboUUlENkHvn+fPjv92/mT+7/Pvjn8D7t3x
# DATA F0Di0d/P5r87/rWg8b6ef3X8+fwp/p1/N396/JtFop4dDrPyvmAaH559dvwrPDX/hi4yb0/Qe/TvHz265cnx39Nzfzr+Ejg9xKCb
# DATA Roe7Br33zfEv6d/f4Gcm7v3RofWugrdGaprNm5cp56MYrXQs24JBbPip8c2I8j3MMbIYQij9sKUg6xv4/ZHeTpJGvXiibK5shv6I
# DATA W/soYbH+tSS9tyReVgNyMD3bS4PcuWiO3mKZnB9KT6pOvpJ4X6qSSJ6Ub0ZPZK05RofnQsvmHdUTdeiCskImjHjbKBrPHE9vgzLb
# DATA OlJPzHruy7nrgZdZ/GZdMiB07yb2PHdjD/NuiaprcqigPppwzjprgv7lQwcotHg0whkdwISosA2M+FT1bw0GuNyoXhRi7+REOMae
# DATA G+efc5zXSL0zDe+vyALMhQzt5zCybzSwn2Zcv5hhXapkOQcstN6LbDrnQdIrJ1UviohLNWC5ydKImNlDIuK/MCbuCBRLFmdljVWU
# DATA LA6iaTLhZ6KMD7QnZC5NB0mYbYLJu488lGWscowoe+Eh4I27lPxRjA0mCVll2LMlA31eXeidQTZLAQYLWGCUMpn9+TvabZ9GaD+c
# DATA oiMuGdHBERIgHCtMqtOVIQuGgvvqwVmteWaOhudoeI6Gd440vE1Gj43mKpsauxdqt5/FbN+G1e6oeI6K56h4jornqHiOiueoeI6K
# DATA 56h4jornqHiOiueoeI6K56h4jornqHiOiueoeI6K56h4jornqHiOiueoeI6K56h4jop3aah4jWa1W2udlYrX73ei8ApR8corzxuB
# DATA 8QrUt1rHosbVKjVDffNbrSI3rt9rd1TeUARjGllNELU8iHq9kpdNVWh7cniq2imE16pXe7XeQkFVG75XrVYH1VblwK/XP9lteh1/
# DATA 1681vE6V/qnstvFlt1NdUnKLaL5GlUJrVAb15ietltfyd+tUD/z6CdQ5E9gCJq7aWpoBbYvcR5G3KmetkWdArfDe/1TvVZu1ykKU
# DATA a82K5zf8T3YprXWqLbstf9SoU9w/2a129JUzJ8CvngF0x61Cg+6kgVmgu1a9VqvXNwDdhf1mEXQXhJ1ePQfdtZqNTrNhQHdhq1fp
# DATA WqC7ll/z660LAN2hSe2utzc8Hl6sW8t8uB9G1AvEwY4EXFrMW0DF1XjBLF8uKwat7JYFJ5XOoQVHZMnfb4e1zAN/qkHVY99bhQ0n
# DATA 9YxaAluadONWXYykMcuLCDkVtqDrlm8VKBPtFjFrS3PGDHx69auyjga3QS04L1PEod0c2s2h3RzazaHdHNrNod0c2s2h3RzazaHd
# DATA HNrtFUO72TA3STYf2LotILUQp9xeu/59+cZLjozlUsizZBoM5X60qBvvB9PBHs8kr/HF6zcoB3Acld6jnGgTaMzMJnz7tcI7bso3
# DATA +jHjXmSa3MN2vGu+HcpHcpjMCqT8zlIw/OzCkTNNEJMpoDnS4Q5Ru0PUyw5Rl475uOPU7jj1aY9TrxG+Pa9j1tIK2A6GXrussppj
# DATA 1i9QyOMiqAuhOp6taga+etf2rytJW93sxuzAyAXg1VN536S+58yCIothFLMAXUNhG9j3L4tO2GLBa1F7/mrhWxlPIcVshjUUAw5V
# DATA S/6fEF39vImvuWAi7DeXRbhtRbi6eXx5UAWljePB0aQrJ0RSPZTr9qrvBQ7EQgx9K4ZtO4LF6K3kPbylWlRkRIOuLu7hLbbyeBhj
# DATA gBcmJ/pA8rt9qGyiD+Fj+BkPdGh7GZklkx32aVIrHcLrPzzyoKSJShaDlydGkXjrhc4ltY7PjVMzVCGGFAQFCDNnoAPsJTB6VEj6
# DATA ODjzJ7gmR9kU6+48pWIJphFbxJYIAE6DswIjL6OGOEnmydrNLVsMACYber8sGUW6I3qPZi8HmCENGIDB7buH3cEqQYh23tecDGh4
# DATA eQ4WO0iss2TXW7LObn3J7dbTQmFfuDwQL5hbC8GLRt+wIAnI1J+MRbcV/6DLx0hhiqxlqL5wVaErosBxHtjUBQWkbZNTl6hJLYen
# DATA bqaEWKp/yGqbpsAi0m+mSKsa1lm1PVeQ5j09eiI0ywROpfmpbItFmGeFRwVJl8DDRonZSNlnqGD0IYuUoYTApCYVDRSFTr7HNxij
# DATA pCzBzXG+z2KvEuWIsljH+F0zUYt5DkhRFT2jaZzusDI7x0arshcsNK14b+MD2CBFUGQF4AjGmmh/iIW59bF+AOiKijVvU4pCHfF3
# DATA tMRVSLNbxIaSwLm3w1O+He8Im2VF1Qk9xjTZj6BitedZRnXCyqIjj0EFivqyKrr6hYsxfoUEbOw+yVmaztJcZmkWxinnMXUe05MM
# DATA 1BcvTCkxyJSyYpokI1ap4waRy1MOh9JUlook7ql6viPOih0ZjKA7h2aE9WmmgrFnxZPVO9WueBnxdBSwe2wlKHVHaZNquZHDRM83
# DATA YewmXMDBEBsYRCDbQcE2gYKJxWWbVqvuNH5uprvoL6vv1yqdnKvq8+q7tYxn0fy4/BixPP9OyXHxX/ebq1EuujAE5fKTcUSdyYRd
# DATA i7s4sqgtQ6xv+A1v317JqNYrdEG5ET+KFIGMpiDYKjc82iG7HXt/u1Qv+vg6xXiJkLGHJMOah5zqyLiHgLF1GGQD0VLVFjpdGg6z
# DATA bXBwLiT/Hh4mnH8hjVOTYu7VKsXcq7et3HvACzVINve1KpOgWAqg85TlKEUaU+4Sv/AwAr4Im3U9dQhXhEq3kFuFNnj6DGuszjCr
# DATA QUue/ZD6VIrdvZSnshOZwOT5Vi3VulqrYeXbFKYUL5Ox4RSPZ1MMORAtHRYnVjxiMKyHah7NrhQFz0zCDrCjcXgJ8q55irx7C1Ug
# DATA FVmJfH2wkH2lalerVkrZt8NTaTZR96UoMpqnilIqiH3SGrEfPUyDQ2zl1UsDrDebLw08T57Zffgps+z91fmVjwYK4Zc8CrR1rTPp
# DATA HnMqhBsBdJ/QCw/I5jBmOlm4j6jhDRXaKWTV4VESMsnPG2Ad2LsvQsHMtMIVs3xiVmUyGugp11mTFy16G9lmD2anrmnV1RmXD4yS
# DATA ccYxUDTQdB4+wFXldRl7fptqWKjzKvBqTd4zRBUV2wLZhUDTJeWIEduNMfJc1xJvfxYrvhdzY5X3hs1G3nJ+WRFeL4tDIsd49eMp
# DATA JGZtjtf/M396/OX8u/kTMLaeevM/zL+eP53/6/wJo7eeLAK7/jv99Lv5MzC2jv8rbvEEyTX/0/xb+umb4y+Of72DcChMCus7+u3f
# DATA veNf4adduuMp/f4lv+np/Dt685PjzxkPBmSXIoB9SV//nQKknxyz6yq4VHKoH7rMkc0Dkj4ki+EDpSapcYHprDdl9XvpUCjDoqnA
# DATA Fw8w/YtH4oKUdgsXah+nz8EBgEIJPwUOI29E5e2ePaWRnwTDtRivd7AyHgZHJqaO42X7WlQHcdEgryWlcn4kL1UL8yWjB6paDmOK
# DATA Z3pUvl9qo7753UIl3SbMCy5DFRPRwped+ZGOlwN6bVZ0W2d6PYhy0EHOgkgBSdVdlqFycMl5GXob7AUSGWGGKphTxPD8HOHrnvej
# DATA ONSzY+rdZHotzimV0gWy18mVcbU9s9jKXhTa6+RUOLSXMwe2bw5o2tfZrIBXYrXloiyA8zAANhr/Tzn8X8zoLxVzIRcs6Ncla1Tn
# DATA wQFbSD6gplgbypjzvj5lO1wDoXrFSSin892p2hrBWyBYJCQOUvMmHRSnXBacUJzKdbARGewh+3rhD8IGnAyutygNhjvKkqMBLQ5n
# DATA KL4o5GKEsZZSDeE15DDHPHGEtSlgdozAPKBAxeUB5xS1cbhm4vEuZTGD2D2yLqbxONKOKl4+Q+hYhobZsiM2C71Y7BADgnKUMEcJ
# DATA c5Sw86OEbTjkbDQH2tR0vthpwFlmAduYBDhSmCOFOVKYI4U5UpgjhTlSmCOFOVKYI4U5UpgjhTlSmCOFOVKYI4U5UpgjhTlSmCOF
# DATA OVKYI4U5UpgjhTlSmCOFOVKYI4VdGlJYvVsL+eczkcJa/Ua/e4VIYQtLzxuhwux88RtezW8PGs1OiTbVpN6xHS2jTdXakkNcRlIG
# DATA dVakFFKW7xeUesplV/XtwmsW8t+8sxB6o+OfY+idZh54vVMIXFKVB+7XmjYErBB4p9/udvvlwJuNztZDL4De6sJiE0iZ38xBb412
# DATA IYCoEQTt2kKzoMc9328f1BvDatvzWycQyFbXidYZAGTc2DSATNptAUDWCDrNDQBkhSsAkDXCXr+SA8iavUbUrhgAWa/fq4aRBSBr
# DATA 1HudzrkDyHQDXQuf2vMbmkJWuN+MjnqBoLEJbawYhOaN5f24zqkFR6b1aBeLMkue2XRZYK+pLJCq7Xio7i1ZE/bZICq8ueBREMsA
# DATA z/H8xXiT/AbZCTCplngkq8YjKZlSXmZZstDXWHhB9Zaea1Hv7ed2SSn6bbbnlnHROp1OkYaGVebVlLJCue2UymKNtVO8seR7MO5D
# DATA hyFzGDKHIXMYMochcxgyhyFzGDKHIXMYMochcxiyVwxDhrpAoYTDaCfiZaLwdmWHne78aUJmd5Td/uu/2YFD9SC6zRbsDjraD/HT
# DATA bVTJW6ZC8+kyWEfpteufxv1r8tD1T3XQ1EJhggTjXrQ3Jgv1+q561S07+Fus6qwPblyT6F2/ha7g49ce5sfYQsGJfWbNcbCPUL9f
# DATA ShHHPta8F+mnpyiprORBE+P0muqtoE8s6acEjMMbtydq9372fRh2tyh9CPwN+u36p/z07cktPpNBcaIf/ze+RvFYmppCgk3W3zIZ
# DATA fktqHSb03OjzGkZ5fk/pO1PeKyScPvljlJ+9hzgkVTx/mVL0meBB+REnkn1iy9/6bPXrmPTWi+LhtWuU1F2k+fpNNm0BeVNZQjGh
# DATA JJt6QQ2JU7/Hbtzrn+YVxroscbfvo4yzuXh5DVKxRK5KDqmx4PqneYah6FCcMWVj/IYi57GkG9IZ37ihb96bzMg0+VTF/HW5E6fs
# DATA 6L4djghNrD/Cqbs/f/5/qjONwObFN/zr1MVQJBaC3/WvrwkbxyPtsO/juCQvfyyG/lleFz5TdYQnk7pNLlZl9cCtQu2/JfXsNmaw
# DATA uupZN+xUG5Vii0pnY5ESFkIfVwduZXThB+sM3LzNq6dSnCE96SkuX7u7sGp+ngOlfmZdk7gPldW8PahEISo6SWYOuCRafAYlHtJ8
# DATA yPSpugaax2SsuF6INAV7GI9purgsUKyk0UNRKZMcM8bpTJxRZ8LpS7z8+hKnJclcBt0JXlkp+OvX42TexyF4EDkgvqoPTgf7eNU0
# DATA GSUpzczWMmUuo2jF1TnCfR6kmUWNjW2jZpaJmJyRNeMVloikSvMK2x2/oqWBBbNp5MToZeoWCHhKPclFPmyh90dkle2I60m07BF5
# DATA Y3nLal4ywSwScD1hPQxm6ZSlvmL13gmN/GPRT0iU1IcRsV8j9HGS8uhLdES/0HCcCeVMqA1NqFL/6kS7nGiXNfyuNL4ug5jXm7MY
# DATA TK2ibJWR8vqh6ELZTQkjzyRK0NAOB0lhhBKEgB7A9ry7ELFB0bGmTiBzYQUfix5RcwyGcR+KNxDdhvNBJKTGURRqzNhp+Skmogr4
# DATA oOS0Ia2+s0RJy8FTNoGnjBIpOta7V5/XAVFSdqOJBL58Xn03dvsIN/st/rT6Tm3uKL4Qf74K6BQ7906pkt+G4bhaJz8viwLLgr16
# DATA WhyfZ0X5yIbxK01m+4O8MfycYe8s4aFxSbMxGY+sRZVvmEZ7Pkhi1rbqsXno6RP0sBpnLDY3YfleGJsUh/1oug3KwHPkX+N0+fd2
# DATA lD3y2NluoQWgjavgTia9LBknrvCMeYa26XAYDB9RXmn5QA4Pt82GwHQzqtGLxlwGLN6GUxBeOEu1uC4NUtthWuTN8LRwhur6fMtb
# DATA teTbmzTGy74/ZurMYlP7lG1FdS6KVgoZYvVoDJaF5CVL08liQqboXVE23fN+zECMqDcYx5/MIqOgSJWUJnRgJUwHmHYMAq6JyNep
# DATA qrhbyM28mzptXp5QB3WvJzn5EdUdVkHUUs0GQ2oyidLIVYgtVIUaNUh4snB7jyAFWTJlVe4FLLuokH/DSE0yOduVhpwR9e4Xh+EX
# DATA 1YKbp2vBbwZDtiPUVCGyWTQwDjhDstkEEzBKYJB2j9TcoCc6i7LTec/jlRrkLsuRp4rtRrnWjyKIKGKqRRZFlE2iXsxEWFG/TI9Y
# DATA z9BMwsfR4TZy0B77TlsBK+uzMB9KFWwFlSs1FzUFl6ZdI+7a0NkrUo+ZhvUCUHkoow7JwIapjh0U3oAsQtQvZBmrgLLwIVVq6EAe
# DATA YKuY2mNzaaEqL5FrIw/C+TWcX2NDv0axpjm3hnNrnHFNaKUL5Nw0ylWVLdBfYYpTNTfejRfOyljn3WAm40qOPW/05mUO7P5WJxf1
# DATA NTPp5V0N9shpruhZL+dSfj4SO0PoW9Lvi2kQhGIXFBwSvKuFfmYbyfQ619T2lOvKL6Jb+Jg39OMVEin1tOkZ9Xczz6/J8U0MAykZ
# DATA 92S88Jk7XBwFj+WOipyTiyZ8NG+174Q3yXBKrDLdOKrqaRNV/d1EtXpiVP32xlGVbT+ILH86KW769jx25oqJX31Z9HwretU1sVOr
# DATA gsafJecCePoH3t5N3qc4IhNbbmTzIx3deUOkFfIsxLEQuw7mlwp1bkKD+1SO496UIPKKbHwzVvswl1Y4cMQkoslgaJnaBYX/vyLb
# DATA tKcnqDQx72OUNCAdmTIcBjS8A7YzoUfJQMMMTFGB8lmsBlIqOqGabAkl1ez9tZCWGJKT4S7DLHnHFr0lBA8zEZoovCg7Xhj/4hcx
# DATA hhR2r4xnGQT5syOyfZNRlntR7ZgNouHkhIXjUqnmi8e2XzVfBpb8lz1b9PiH+JCX+JkCk61c0iijqVV9xIblEns1rHKLdThLySYm
# DATA k86mHf7fDC98AtpgkUF4/I/4e5F2+M/zr5hH+O382fz33vHfHv9y/t38m+O/pyef0SfFLWTGIYiFEjiH7DEQ8StgFI8/pxu+Pv4H
# DATA eugb3PZs/gcKRz/5+/kz4BKfMgaRgnTMw6swwzDVK59YcIUH8QQ5Ss/sKH8ldzgaicHCSYbuLBEmi+hDKkWhEcCwMgQP6km10TOJ
# DATA ox7NxtfBDe/rbQw0ADBazaENrcmELrCLhhsulMr5oQ1VHdG3gbOhiTv8y8L92L5idbgPkr7a07J1tCFHoAA2jDOu7A5ruFmxbR1r
# DATA +M7jyRC9TKCdIaMknA0DkNeTKWv27Hkfoe/nvivf58WLX9gYT8+a/U8Uh9mIe8pMtkHBhZJMA72WFYwFHbMANDy5Cq62Wsot60Xh
# DATA DE9Og8MZupH+OUZ6zS08ywD/angKL2xw3/7YvtHQfsqR/WIGdqmWpTywmIUvquWcB5ywlEqsAIAEpDh/cc9KrD7nWE5QIC5NBZUD
# DATA bU1vos5QPLz5WrYVa4luWElj9oqW821DIqHxsuaxy6ZJj1cceTzWqDjmx3EtCWmuPc5M9KNZmnjBiPFvPORHZDbEvRhL4wWboGAB
# DATA RI9xsBiBhxG8UWpHtVorJOuBivP9KMgQIbbtelO4YsRIZK+OUOpkbV0VdXd2JPXL0QodrdDRCs+LVrjhULPR1GZTy/gibfyzmPjb
# DATA sPAdq9CxCh2r0LEKHavQsQodq9CxCh2r0LEKHavQsQodq9CxCh2r0LEKHavQsQodq9CxCh2r0LEKHavQsQodq9CxCh2r0LEKLw2r
# DATA sOHX643eGVmFUdj3o9YVYhWWFp5PTSps+F7Nrxzsdjqf+K3dWstrNejvQa1R/aTe8apes+rVWgedTiGXen631uuXMXYUVnMpxq6+
# DATA QDaUk34C8OsUAX6Nml8i+NXbeVnLsbWc4Be1o6C3CE60+IDtRiH4aq1TDL5TWxm6SWYh9HqlsSb0xplCt0uk7Xv1euug3hlR17pb
# DATA 7xzUOxvntL8II2z5XsNvDZqNRimUXqPX7faWoihPjx2UdqOxg9IELexgM2y0W+GJ2MGg3+03C9jBkP4OqxZ2MGw2Wg2DHez2evVu
# DATA 3cIOVhv1du3csYNmmxqE//c3mq+v4faJfest2EXaHC+9zQyUaur1w4i6mzjYkfgtBRg21EpcdYHWh4XFhReU3O620agLpDjvJnPP
# DATA 82EHeE35Y4fJ1unGOdTQphMyRYzcYlB3grKhYmEDi5G1NxfoEV0te1WWeXtlMaWYtCp8n/yX+mPPuNcTB0vZulPOkzVmy9oksz3h
# DATA gIMOOOiAgw446ICDDjjogIMOOOiAgw446ICDDjj4igEHbb6bJFu8GEJK46PiiP7177crN6qVHZpZqp8OuQivy5RNY77ekUMyfNAN
# DATA jewG/wouXW+EgCPvP37rdSr4FkbRZO9j+m8M2hqFe+d25Qcfv/YRa6nzOTpeqEEg9KMEscdTHoqwhGUO3yAuXvcI9zIdL+hmCPG6
# DATA eQqf+F3v2kfZJHVelE3hR45e9/785f+HyCyk/VqtWrkhV1ncE10DgtQoM4cQc2e7Tzrb7c50v+xnuk9LCrsMZ71LLrb1mLD30DTM
# DATA E3ve+6j2trbLUjjYCz0dfnWORp4HBax8mH3bDLBFSYCzEsCK/lp9Vv89pnZJRZDX9COja/M2XI+BFyb0Q3bIZ7Q/hBMSVYulgAZB
# DATA nO55D+Ipu5+04LtUQBEun03keLIq3MLx/SCXMppAtDHp81nkXDSnpHCzUM6PIpjKgZHbgU108Uo3L+gUrNWCnDHkjKGyMbTQozrR
# DATA Gyd6c5IZdTnEcD6U+spEizAx+IufJ12jiHPfaDdQM4z3x4r8pTTUFD4ypWGhB3GLPm4WJYksAH4V7lGNx+EN+SzfITo0cEMObe2W
# DATA JZopG4O/HkJ1Bv6xXMnG5sGw70JUOxzuazPcFyUF+iQq6VNuNathX+x2FFlo/rj6Xt6eyz3LQ/50FeBdVl6ckrvyYA0/SeeqEFfe
# DATA Qqug0hXbSoArDw8TEWtKZhCMCSDHIpCVEVqKlkhEDQ/YCyWyTGIe0rh2AC/yLyDPko6K6kWiUkS2X5KPdwEEYah2BKJR32dDWZ85
# DATA lUajZgfLhZ0XBaDNwpvYJHkCTY5pKQeMDVhQ5oyhByxB6OfjX5255O5vXHL35YC5WOm66N6DLYKOMGA2ABXHvlL/zpj0FU1YHUex
# DATA hIroMBQfS/qI2jcVgUxS72o+IzyGal8U96bDaKrAAqmKSzZJps9fZIWUXVyZ5b3JKcvsJ+toZapfkjL7CQSIkI/dhCJkA6JYmkiv
# DATA o2hBs31hZFHuUieOi0mfrBHD0+pHh6I5pQe3qUjC405Z3OGSPmT6GzNXTKPj0u/OsqPnL61imq5AcX2wcXF9EADczosZ1NfnPKps
# DATA IFr6pjFQr7cPf/ij6Eis/W4ABS1vkIykYWFyMObQWKNu7FFBpaCFAZUDXhU74PvxY8HHMTQhL8yy8NvzF1oxZRdWaPkofMoye7i6
# DATA zPR4rnpFUQ7Etby8xB+BffgYBqgJZcIKHIojhuWRe2qcYG+cd5fLt8/4LuqEIEKGcU8sTxyb8iYzPjzH4gljoF220O/lcb/8JVLd
# DATA tEQ+iJRyHYaPqfpJES7lfFCkBxhpTmJtiFBf4vHxLrSAIxEkFDCgajXcv/HMGgHA7OahLM60kYLSFf27LbSZxYScqZguljD3XBiT
# DATA V8HPZgXhHG3O0VZ2tNlVyvnYnI/tjIuNK31y5yQ4LVNymelhBETlho1pXGwvEGpwTuS5gidL7z2Bvc+brLH81OZ9MzwTVr+fADrL
# DATA QzHdlXUpp8adhDprbshhO9TeMgPu4nmB2rV3rTc6EXAnAeSAO/XdAtwtxcb5clmD4yobQ+5kNw/chfggjDGhIEOlmPOq5EBUD+Te
# DATA Qx3Cgs+uVWHsF7a1e4dYyOT9Ra3Kai+f7/MjD6PH6IlC6yn6Zc1jdX7sR3T3kf1MvbLGTbgSUadNU+ymJUttenUhdbbr7nBAoXg/
# DATA J8tzHB3t2ZLPStdZOgE4hA4Tz+eWFqQKFqc3rE1omqRMd6w6U2dBccL0igduCtq448WhwX2LeOyVu1+ra/OL1bYzjwGXVGC1aoXr
# DATA ndXCqY+aafil2pPbK9ZU6E0rGXYKRauw75CF/1i6vjHFcShTRVbNnsxSgN5lYTvJWD/VEsjeACL3khjPOUKOepGolwb9qYWQe19f
# DATA 2z3+u/mz4y+OvwREbv77RXTcvyzFv9GXJ/TUL48/P/4Clz365wld/Jr//grgOLryzfyr418ZJNzT+ROlkA6Frwm0U2nIdpi4S2/q
# DATA s2UeeKbOeH8ZHATeO2EsZ7FE9F7tK+HZbz+No3FIHQh/O0zSYWisf3i+ZxPxncKVIK6z4RHTdRO4tIUiyk6DfIFC9Tx4KnpMDS1c
# DATA i5B7EwIarDXh8d/Ck3AcuXxGYDqFi+bI/f/svet2HMeVLujfeoq0PR4AUlWx7lUgBepAFHVpUxQPSVmnD8mDlajKAlKsm+pCEJY5
# DATA S7La3e6xlzXd0796zTk9vc6sNX9pWWxRV79C4RXmSWZ/e0dERl6qUAABkBRDNsmqrMzIuO5b7Pi+7KE5PTK5XaoOMxdE5NQ8X/X1
# DATA w8jkLvkCCX4ahHKcfEW2I/1LOkFCV9DmWDCOUG65oTtxQjnpM5/NnD6Em/hVxp3Sho1ypnoioMhy0ROFN/hIvUHusrW9M/VpUUwC
# DATA km1vhOO7OVg/9PSla+9742GgmDJw/J3aplBhpmwDIbQ4WYJtLnuOzjdxMtfgs0I7l90YRz3nrIdTsh40Ld2xjYYXIoR4dgbDKdkL
# DATA S5kLR7QWzs5YkEma1RnGUHg2F9ppsNhZ3QCiOWwSt4MheKjIlDGK2vQQe/NzuqU16PWmENfYwHsHHkSLAxYMKTKmfmkFtsYfBRyg
# DATA kOgfOmysku1J09OQ8fVOOOJTtOPx0gx3INIaq9isJhOjDrlHFuFI4hzq1w75yiEfcOCMoHcHH5JG87h5LerAQWdS8K7ressBBUUW
# DATA lgwCp+wWOSugKcgMpgUzmaE/gIsD6OBd6uSwJdFjbntfwjWcyxn0mUcHJ+SxukBEpqYE9arjvHOcd47z7hQ575bUXsc62LXILD9z
# DATA T+MkIqrH9TMcAZ4jwHMEeI4AzxHgOQI8R4DnCPAcAZ4jwHMEeI4AzxHgOQI8R4DnCPAcAZ4jwHMEeI4AzxHgOQI8R4DnCPAcAZ4j
# DATA wHMEeI4A75khwCuXKu1K+fgEeJXnigAvawd6KRY8iy+uHNHRyWm0qN8bCYTSWjPWXdXaeqMWJJjVymUagOoCZjXr1evHfnWzvF2u
# DATA V47/6nL92K+uNBvb1fbxX12pHPvV9fJ6pdo4/qurxac21tXGUxvrWvWpjXW99NTGOrau15tn2eGxdX20Vz9ph8fW9dFe/aQdHlvX
# DATA R3v1Ey+u4lMb69i6Ptuxjq3rsx3r2Lo+27G213W5Vj/LDrfX9RFf/aQdbq/rI776STvcXtdHfPUTL67iUxtre12f8Vjb6/qMx9pe
# DATA 12c81va6rpSqZ2oqrB/71U/a4fa6PuKrn7TD7XV9xFc/8eIqPrWxttf1GY+1va7PeKztdX0mY22HHspFr9Io79bqxXuN2tv0NR50
# DATA aGzXa9VW5mPVaoMfq9TTj1UR6GgcxRxTDohFLl+qx4osNSuVcromtWLNK9dqu+Vir1LzirvlYqI3tmtBbbuRScnePBabeiViU5d4
# DATA jsWm3iz6Qa0eZ1MvrVdK5VqMTT3Brw429e1gvdWJ2NRr5Xq9um3Y1P317Y5fjNjUq6Vaq1w8dTZ1DgbntzlJ30Q6ZbNd06JH0dam
# DATA BKztZ5KE6GYrLmvbTSdqNDhBE+mZzImeznasI84qr+GDYMulZdSttIy5hO5WqYu51mW4VNCyZrZd9IzgYwm7fnuwd36dfsSfoqdG
# DATA 8UGBXtVDCGzOFmw5VdziPowK9FSqqc5fk20r8+swI/tA7fXqGWa2AVQuaBTpziVOFMS3t4vzydbtkVoQDs+aaxzk5ri6I1V3pOqO
# DATA VN2RqjtSdUeq7kjVHam6I1V3pOqOVN2Rqr9gpOqRxaiwG1bXjH1HrfauC/ZHBPxxQRirWGSzrdzdZ7pyARXJ9wbtYEOoK+iipNli
# DATA UUfXBGQiDxtko1yr1Wt8FV6ewKaNNzQ3OrvGiuJc/YZFqQnSUTGEICYAZttoSuFhT5GNRL/U5QWDSRsl82DiC6Y5r43CmFR1sFrM
# DATA 1atrMI5wUGX13K3b6r/zGz//Kf4dcTF3zu3kaFwtnnYeWy9NTg9UgY2P7/n9sNv1z5dzw+6U3P7x+UoOkHHnaw9ucVXYjTV1uaPp
# DATA 6W9Md3aCsehFBiDzrm++e97QxreCsLuKN7yS7J6XC6Ums8m/Fb4upPWvM/xPhMObKEUKEAAccvJRhOaPH4ZCKl8qlHWREM6KSwRa
# DATA QQAvgKknQIf8QjVngIk3ATzfhMxlPYMESQiQLYqQnjshwpClq68tMqe4g8POHEv2Y+NoACItAU9LT0eTfO0CNAsCVwmMHIB9qAYA
# DATA ycWGvOEaiyL4WS4O0OFw6hxO3VFw6hJgLg6xziHWZWD+zOeyeFaQ7LzhCOuUMbTidTJQdptxSLedKaBxAcw0D7tNEVv0wTcbtkJV
# DATA NPw7RmPVYFXMRpuEpItTa6Xg6Mx9u+WL16CaSLToiks0XMNN/Ur0tkJMi5ivYAMPmKEeNICgusE2Tp5R9CcMUC/FjYHl64nO167u
# DATA BYDFAmtKoc2BYsuznmQ6TyBbUZ0DYONTU0IY15qHkI/8DTpcneA+SNQE1guSyjxMmmoeUh+3+w1lFzHcXoR0q1Sjbv8NY0h52pAC
# DATA Yh3ofQSpmPxhYT1RPRQyjkXB+xU0Z+qR1u4UuMUaf0yZKwWPnYaYohV6YCFAlUhtLsYqHFkUZFwCoU8kN2Qs06yEqDATFdOrzFmC
# DATA 8aIe2VQiXnpESXVeLKY3JoOh4jbguTIYMZoc0M/G0yE0NFKOgedMc60VtC35P/HvCrkCrEK2Z+B8DffVoGrl4u/5+5FFJQpIao9Y
# DATA tXcz4ECmrhsTu/qWKcZExLbK4bkVThY1m9+Pt304oE7bhjL0ec6R36AbfgURFM+y7TUqILNBxfEChQ2VQbuoStjYGvLIMZSc3yYR
# DATA HhpmGwUopxsgMHSa/Ek7GBGgnOa6YYJOP1plxlRjVjttyqluIJnTHexz1DdJsibIYD9+gLNI6zgD1RmoRzFQnTn64pijc83MZxxY
# DATA 2d7gT1OYdWN2qqwY+nuyywoJtoqyUKNHGK9HUWE9q/DLzxea6GGEDlYqh9DNcYrMxVdJQCdXqj6OFkvyahYTSV7qqJnf5W9Z6yV9
# DATA TExWf2uAsJS8cb/f0tVR6EsX30udMuMIPtk8c4C8rWf5C7crQQKmE2k0Vvbrymbc1cjT3D/aGGODLRu8WVllGh6Y+TqmQ8uWNByc
# DATA pOxhj2p3wdB8xQ3MuDlqBfgS9BXJufD6NMTMT+Nty6RIMXYdyvDRVy/OUUVGAZku/jZZ3YrgI7HecfpVloJmAN6tXLzRE8Jv6k3D
# DATA hszLjbF8fcWIfC/utTAMOFjfh8Fg2KUV+gHve6AvIv+D0cwU46LAJMdwwuOG48THxNVEb8ZaTFJKc5XV6OnqKufPGPvwHvR4Ks40
# DATA 8TCQCSEeJ9OSwEtRokqN9oKKXRuREdmaLK7YJd5v8Maw+Pd19dRF8aTZAvd8TCXuI/Tk3ohRswd7fXLZ6KewBzh0PVkza3NJnL10
# DATA bV5AkGLHm+ys+ONa8ckp5+LMLs78xAb8XHfh9OLMhk88ycdhaNWeSZqvs+Bf1ju/9MPl+0PJ2+FdcDJlgsF0rGOth/AZR8UYuWdd
# DATA MgS+zcMImEtLExobo/8DFoOoWJzAWN8QcSwbNyHJK6x22fGbCtzP5yBW+/Di5vHH+fdi1Nls47j9Ao7idMt4L920Dt+YYkIZ5qtv
# DATA ha8fSjFtFRPvA33R1LN62LDUjsAzzbv+ivSPqioXkBNC65U6YXGlzeMW7bS+EvFNH1bdyrK15USOSID1SDCQ7EjUEdk5NtX4pB3n
# DATA GZfvpnab3pgsJr1NY1d1CU7qy5oqmQXEKOA9Cx2Zfn4Jqs1egQjgrj/tkz+EDYHxJM5RbdrfBjkNm128R2CxDEGyj8DMDAppkTIF
# DATA bxOX74Vk79ibZGwJBfdbajfDk/0IddSho1gzkeDhC4HN/hgJa+x1sMcmRhTvVShDaeSHir0JXNL+UCR1YjyjAIqSjlESSaxjrfCI
# DATA oeRJ8yJHwy59lKBjyuBh4h22JBETc1q1B4HQRynPzwNP1B4mGXUGU4a2Jorex2ihw3myf2xek0WYPR2HLUR5woFFmT37vw4+m311
# DATA 8AewWs++Pfjj7PvZw4PPPXBn0w9fzh4ffJ5mz/6X2Q+z7+i+38++P/ic7p59RQ//le799OCPOY8+/UBP/mX2w8FvwaKNooVJ+1P6
# DATA +/HsMfNof0KP/JluAZP21x7dBb7uP1Kxj6nYh3h69gVV62t+kor4gv7+HrTcB584du1n3yEkITboBXkwywlFluadYlnVomUKIrwu
# DATA bwPzbvk1pSF8bdPmhBKMg1Nkxg27geILU2xXJP1GmtSeucEio3Uhi/Z1PEQyKHDU2TF/LxIPZ02ebY3I6TFmq1k1tjw9vsATc5y8
# DATA ezvwI3H9On3hybgdkK4/SapsKpe5q0OtyVRqRcqpe0G5spcYtBNnyr60OwBOvQ8Sc9KpfW2/Ugdz2EkxSrI0oXFL5YBLzJcsFhJS
# DATA 94LuBdR1l9OkyL4b21EqfyzSUCenHGX+zbdgotX0tLivD628o712av0J1bqmtz6aNn8xIrdnqMlPUpEvpcePpMbPRIvLTDRNj7J9
# DATA n+pSOQ2CatNGSQ+d1zwW3iriw+Ock0xKasMOQ2X4k11pQweJkLuyZSu7z+Se+8JMO9rdn+z2ogGzciF93RuKshiqeBlG6qsDz1RX
# DATA iHc15zLXpj/wZNVkk/MWvE3+kQG6x8JMzIjOsoWlpCoKGk8GQ7K2dhUL7sTfRofJATuxHqJWGYJs6q9WOBZ8Ct2lLQQjHL+045d2
# DATA /NKnyC+9lEpZyl9Z0vA9G9v9OKb7CVjujkjaEUk7ImlHJO2IpB2RtCOSdkTSjkjaEUk7ImlHJO2IpB2RtCOSdkTSjkjaEUk7ImlH
# DATA JO2IpB2RtCOSdkTSjkjaEUk7ImlHJP3MEElXyxW/VjsmkXSn0il2as8RkbTZcV6KPdruD4RYa7XderF8r1Ipvk3ff53sx6C2nkFv
# DATA 1fRKzepurVq/1wS9VTP+WKvUbrRLycd6pWrNK9OjlWK+1PDKFfrgVZr5atWr0P/pt0a+6VUrHsizSvlKk6+VcXvNq6x7lRLuxuWi
# DATA t+5Vm/lyyX4rZ0LGua0q7ZpfL2ZxW2XMjRrq07hXKicJ2rbr26XtVlYp1RQZn82SVolTBku5FoFXPZq+lTiTeeDXGtupGpbL9Sev
# DATA YblUiWpYq5xwDdfXT6CGzXpUw0b9ZGtYaZSfvIYVXhKnNMpVWiRPXMNqpXx6o1wrNZ+8hrVi7fRGubZeOoEaNponPMpHIdITJaSJ
# DATA 9ESfWUR669VaqbIeJ9JL0ubxFT9JpNdprwe1iEiv7teCRtMQ6bUa223y0Q2R3jpZx5XmqRPpcfpnfpF1X6gk+OkeWA+luehiIaFS
# DATA M+716E5gGwshW+p7JD2u5svtYGctVnKCoe+tgPR66Oek7sngd4VD37LlzeR8yf17VTI7a8vuqRW0+c7x3IrVdBTj6cSjmOVuAgs4
# DATA YqBj4UgMyx9xC6iaFYDmOJxVnoqCpen51GyKjwYGw4pKNLC9kp0OlXpFAbUmm9Xy8slE1YvBHmGyimut9fmke9EI5+wxWeBFpGeb
# DATA aq41jVSwe/HgsCuAWT/XjYoG6mj+qCMBdCSAjgTQkQA6EkBHAuhIAB0JoCMBdCSAjgTQkQC+YCSAmAvKUdxg6zTn49BnDhC+oxzD
# DATA sBUvSH/w6bANmS1h+79t4Mc8ZssFLkTAIzaUelNfqW63irlyrpqrk4wMO0kJqW5bW9OPm7sv8OvMRFzt50Lwv/W12NtQT1hSb+1C
# DATA f2EvgUBOa6yofuo9oiXvb1y8r98gkoyuKDv3vhJn9B/Y62wfY4ijY6trH8d68gIfAta2InfoWqJV/Y2L1CA+fgljlP12LD8+B4cm
# DATA FOTkp6L5o6JZKikSvDU25+Ju6O0Vdd4PgiKalRukdRlCVk4Z03wUDrzrcugYTRiSgGWaO9OwCVu8oNz7qXr7mlj+2WNzSEsmg52d
# DATA bqwluZDWOWaRNIkLvYXvd8wQKELFwQbPSm37j1vAeURz13I7sZ/eIieCJvaAVFZAHdNv7cug8WvobcXXSs3i+UqleGGnsEP3wlj8
# DATA FW7YZKN+FacWcqpASUPH5TV9d3B/OOgDsM3vXvd7w5uD+LPFUvrZVwrFOipEDenTEK3uoDD9Re4Gkl7Y551N3MkRqFX5NBiuZpXY
# DATA oGGSAbwmncmAiSB3XMWHV0rM2TjoeE0eUm68/uUXzQs8FzcsRwYjnasUsQMnBJAIowx4rj1QPgkj42sKRj0dPo7m/gU1NR7oNcAu
# DATA 8ATpRjyEm5c29sI+OVYFPlXO8/L+5De/URf3gu274cT+SaTFpbXJLulp7/JoxLNbjqRbehrt4y6SefCb38Af3LxEFfL3/JC8P+4+
# DATA yOke9GTGZD7iKhoMrUUk8lEWyoUH7O3bfSJjJHWOmxfp4+sCeiQIPIA+lFPc24EXkJum1ybJHePKZog6Ph8Xdsmtiwk9DJl5TFTe
# DATA mlVLKlSNQkaR2OOnR0xR1nPcta/JqpdiJKZmDtU6LBuHZZOFZRM/aO1AbRyozbKgNnMByE8L7OYy9l1YuwJtoh/YsC0a+ObpAaid
# DATA Bcq4mAJ0+SY+eKsYjvG5XtifToLDcKz1s0Y4mQsGclmhhichoSU3RGFClxdBWOtjvlRtPq4LxPh9iCzu7wEDZ9Do8Abaruw08XBS
# DATA AXJ/vGPMfpLVE+ZHNkt5y1r6hl2gIt8Z7wgdwYm6wtwaNZ0fLCXQrRe/q7T8u0rxbsaD5SO9q7z8u8qxd/GDlSO9q7L8uyqxd/GD
# DATA 1SO9q7r8u6opqPWLtSO9q7b8u2qxd/GD9SO9q778u+qxd/GDjSO9q7H8uxop/PeLTfMuja9i1vBcdHXbff0RgKlrVSGULhqJyNI2
# DATA JPvuCrUSjs6QKycCTDQkvAfQJrOT3gPU0igm8qSEUs6r5Lwaq6MGWLSCPgOpesgg4KKFULhnmMCsipGiyo6fepCvTGZgwX6ZaHuE
# DATA KkVqCn6DRgSDEkSZYjUeHQ9sCSjz5x9MyJG2OtdpsevkPKUfp6d0VCLWpw4LysldUZ7XaVB4WvCbJ8zbaYOXZpJ1zqWTZQxBPnlo
# DATA VqrwogBmfAGt7DMAjvqcgAUuCW/uRZmD2riSqKX2l+XEDvUOOdNA0QRKkjG0NhVCqz9ikCsERskYwtNkVpF9xfynvPciYK1DceM5
# DATA tQs4jPDTOasphwfUQEXIjezQ0yCFXXrHPWQiCivQDrjJGH6SXs4cOcDl02DoR+9FmH2MGZnAjj1LyPSnYynFpqUzlpyxlGUsxUSV
# DATA CzO/8GHmuUbW08dU1zOfprPPsNL7iAD06T5ORoow1ocjLE3AACcW2c6U/GMONY8ChYGdgvem5WIQwC1k8IFy8XkOJQLLMashDaJu
# DATA 7iO9qpcxayQaXYOvDLU56HQ8/94gbPPuZ38QjjkkPtKY2iIOIuLxqGEa0a3g3SAV7XWoNAFRH/M+qRwlhvLtSl3GnL+IQvYNFjhJ
# DATA lun2mBb9dCKGG8PIgfO7rRnhUOOC967C2fZ6YWs0GO5yAEbRxwV+i8PyeJ56ALjVEF/Zkfgo3OOzrdFXaPC6U24EEzEjxhH0c3eA
# DATA RJYJ2HwlAW/oM6mhJfY0gV7B20RnUtHhcKiIt1EEh+QueNjYxlWm3vblLnvMPZyRgCzuo3c09bu0m1vl7dHbeGd8QfOu+rBrhLd4
# DATA Z2BQ53GVzS0aCZjFMsCadp5GXSb5ZNAbjEaDPYXvLdOfd8n10PDU96QT+8jrHExbwIBhGnSJXUWHeKO2CYe7IU2noYLiUyzLi9rz
# DATA JsPzc2QMGzwpgpwuWXTsggSwFsUCVYjwAyipCauwXTIZbMOS1iScBjb1xmIa0u0dnFDHUjB6UKYD6BCFJgAvuhsw+TxmHnVjTwaJ
# DATA mafJstzBVO6CiZ4qM+1DMWNPaTAcJxsp9tRhTEGvyzznnSvUR3pUemGajAij2qxsYom0ltTN68Ax1NzcqPKiIHJ8o8SMwoLOi+LK
# DATA /MonfG1JXku/yLIyi+9kX8PbJbJoIi4s4SzgRXSyb+MNk+s8smayTiB0LCGMlXKyb+WtE+R9z1+Y8Reem3afMBb/4/V+IopLelt7
# DATA MBiNbX7Lf5v9cPA7EFIe/IF5Jz9lhstPDj6f/QcYJWePZ4/SBJf/xgyWoKf8xJt9g3+YzPKb2eOD33lMffnJwe/pz2fCcKkKphcx
# DATA reX3VPij2XeavZKJMem2b8By+ejgH+m3rx2F5bPvt90QT2s0gJHEpjA2jQbTnd0Jc+QIzLRSr91wAnQNOUVsHLFpX9suZEpB6/lM
# DATA 3ioKny2YsXhuoEGBWejzGdSF/JU3OOOCZGHY9T4ki5GNKMdkGflwWgqcNY1l5sCcHqElz8ux5T/qaSqUR/GbMVnNrdfUzIV6O0k2
# DATA SzJWGUhB7WFKrgktiaFjslxitE6cyHJTpVZ1aXns5/f87t2IqYnMavDtgP5HNQu2bsvHcSPSsiPAsyl6Hb8NDWFIo/pBQEY+NuBp
# DATA Xu6zb6BYkHB+fphisjxk5s03S7KW09NitDykEY7P0un4J9HxmszyuKr9hQjNnplaPx2tvpRSP4pOPwOVLvMyoweMQn+K6+c0GC4z
# DATA muqRH0qfmHvOV9uk0lzUMsf7nD66PWxBz6LF3NysKnPis3p4NBCiQJFN29g35/r6XLd+jGpvGXLLWKAbVVLNMNifHO5Gqp+3Rz42
# DATA 9oAF+WAsrIDe++PIhBLNT5Ybsrw7VLMQhoBQE4Z93lsybJewdkJ5gYoMY9B4I2vTooZUsdV2QDqyF5LZsLcbcC18j00TTrDrBI7t
# DATA 0rFdOrbLU2S7XEbFLOXSLGUTn7V5fxzr/omNe0d56SgvHeWlo7x0lJeO8tJRXjrKS0d56SgvHeWlo7x0lJeO8tJRXjrKS0d56Sgv
# DATA HeWlo7x0lJeO8tJRXjrKS0d56SgvHeWlo7x8Zigvy9WqX6sfl/KyGaxvd54jysuMneejkl9Wy161Xveo37xSpdgtFWteqVG8Um00
# DATA vUazW26WvUozwWtJ926n6TB7pfWKV6aOrpXyTfp73Vuv56u1fKmUL1P5tV+/Wy1R2c1at17Jl4oNr9nwSuVGvka3VPMVev16vlzL
# DATA VxqJMakFje12mh+wQtVufFSqFfO1oldulrzipFppesV7jebb1Uq8jHqr2W6U02U0q16tWvwoXy428k2qVLmaL1FfUI1qqGm+2TiE
# DATA WdNULsWjV2rK61rhCN5Si4e/zpXwWjy0JZm5IyEqjNW3XWtWq9VjsOXx/NVsebIULLa87XotqJSWYMurt4MYW17QaNfWtyO2vFqn
# DATA DtvasOVVtqvNcsSW12xUS6Xg1NnyeNrnFxsGHN1PxKZpqHD28oFVgLYNYtxp0ug0nZvq13T8D39ohV84bA8h29iZR/5m1fJwFj6b
# DATA ZE8ePBrJXjVNshcVcwSSPR2AnNtHdk+rDlU0dmr+2RGjMttpbAwYJTYnjUDrbrXBVZzPfRf1a87uqgXmxCE9YRjtHPmcI59z5HOO
# DATA fM6RzznyOUc+58jnHPmcI59z5HOOfO4FIp/jtuE0Ql7bPNTG1xYpNKYgkh5iuKFMeeoZ9jFIg+7GxdVuit9JtXhNC7LXqJj7d8St
# DATA ueXhw9or3fgk45m/VvhwEPapgNv0H/ihLhjz8vaKPnYe1aUwuY9+vb3yRupEuirgFXzWTFGXTIaCLlUTP2luJYcQ7g5WLzhY7Q5U
# DATA vyAHqo+KF/50D1pzXDIKpaXpiLoxLMydwaCNs8UexwnNMVtmkkAhC3C2n/b57OfhjCL/fcJY7VkHyU8atT37XH4mfvsSx+SjOK3B
# DATA Dw8EoA6jrWEn1eQwGDM3A6rCeNALAATDR2tlqvEJeBV+Y0YWwQ2Mny+PTo7nAINMtma02NlnBJ4pIsCDTgeBaX2gWXAPUbhMNX5F
# DATA 8vD5UUDEU9NEDuT6kXXydMBqnsZpVvO8M6icQZWBRhdNKAdY4wBrjmtHzbXXTgfIhmW6XgZkSQl2BWNg7A4mg52RP9y1QMWfGm7a
# DATA CRBYkl5+Q8HQWNrriJjFYgygkBMELFa6Xyvznj/kzrF0fhby7YmgFn/A8N4iG2k2AiEFku8UgIvfhK3OL+p7wX3qR2/cP3H4YAYt
# DATA fqc/nnb9iaCX76vm7aGhQxLiHY/kXbd7GrDFU8ZUmmjemSljgCdWw8m+tybI04D4bnsCQq/1HKm/k30Xsz9eC0ZjhmLCThXz2wss
# DATA DHMb5f2QDPjpkBZkcMJo1I1IiCYsaBpOH3ywwgEiBvcJQ0QnuCYjt0yKjAcm6SGNFeT19o35IdLG0FFGBJA2orrZDooQ5eEc2PNH
# DATA LaH9CH1KFJqcOBrPgZZqgWBR40pZuFRABWJwKe8GAL6DvsfEK/0WDZSGn+oo1gPq+5xByBoo6awhTbHxtK+xktgjGk23twGSz+PC
# DATA nMSYJoMu0xeLHhCMo9EUQF6e7jSD46XCm4G8wGx2+wo3dTmqxx+P+2EZFM4BcQ5IygGJW5jOBXEuSNwFmetYPG0sTcXXwZwWu/6Q
# DATA yYZ9eBg2OPY4ULh7GgoyARbJVDsaHVJRHwXizFg4jxMbABK6srsH/qSp0IUkIR5lxU5pKZPsolG4F2QgPS6LtsmtHV58k7c2o3pv
# DATA 70feEfMub0/Dbttg8anKcKAxHTZWh0ctAnpNvS27/UxYhU/KwlIWkP4xIs82VxhFYJe5YliyyeasZK+Q6raaEicBV+81KQSwStXn
# DATA VyUxQr3cusNIVvupVwcsYSPDD3vw0LG0bNR9bFsOVCA3eTs5qOoww1v8af6drW7Y2+aK4sP8+0gwD5CURXdelo/RveekbRcTNOXa
# DATA 1pTdeNvUhEZZYGjGRhfJwLLs1RnpyHL2R23jnnLygziqqh/j/ZAg5uJMaiMOJLNAHNsp31717vZMM5L1Np0K5MjKxeshczW1AyYT
# DATA otVakShBbzCedPcV+SV+gpVooNh5r0b4usL+RFRgIHCYyJIc7w4UnqgvpOcaPJYJxfsGapZWLrvFOrytoDA9WGbKOlQHtc62A+tH
# DATA 6MAPyCfucuw+HLXIXYy6ED4qCQZQcdmCTnk5iJSQWPhQpeiQJLvEuwRsG3NuJcz23mAbj5D0C2RO01DcHcummWIB47E4ie6yVskR
# DATA +2t9YX+ZJScd9h4gP2ld7ASmqxBN4HvifWQouKQjC94HpDNzHqPkhWSE7av4kyIRI3EuLHGSrSLhMM0zT2qDadyC9kl0lRE8R+yo
# DATA xsKOUlJMuultxHHEnA/71qziV9OE2KNajjkQ44+6avdUx2YQREAanA+sWtnpYjcbPyP6t7MfxQsDbAEiJ1+Yc0E4xjKP1yEgdZm6
# DATA gm96qmuydoQ1eQVEdJBptO7y1Oi8kFyZ2WZfpuUmrHWqI62dt8Af72NzTzPC0SNk8wv0MPen2CJj0HhZHvnTnGCl8vIz7MqAhph0
# DATA ZDfY5zBBNMe69Etk4ajorgT8yLulJciRuMhYQ4eQhOeAld5EVZuiYm0BHRgncgZqjpK1IiEosBGOwlZmv8UVseTW2YrYXJFuuHh1
# DATA oLPgNPI0m2AqOw1BETWSiiVa93fhMA6xH0sAIuISGwYTUPPaVGL/U4jEvNlXs4ce03qB/eu7g7+fPZx9N3ucphH7f2ePZt/kZ9+C
# DATA AOzgtyAg+yvowg4+petfzr6nv7+gv3+Y/WX2g3fwmZSOoh+DdOzh7NuDP86+OfiM/v0cbwIXGb2ZynhIJTzUxGTfzR46NrHngAW6
# DATA Lzs/yONpKZT6iAV6GAyGzN/IBOus2mntiYHYHgD5nKONUDRWSFqB4fJdkNERsDq/gSRIKBDyHDxeyCr2Fswl5m7v7zs6MTuGogTB
# DATA WbOJxQfkdGnEwr61h3tZz1L9S5pLrD/BIUAjY/FVNF0wOkk+MX8iFAW7/pjUKSxYsnQHnY6jE1t21E6cU+yS321h1zGQDbD9iKDa
# DATA 73GmPW+BdHmfxOvAlfCYF47h/swuB5h0e72AnV/oEt5HDH8dMPuG1w6DSQaN2KGTbr51EltLT49D7NAWOB4xp91PQrtrPrEjK/UX
# DATA YlPkrBT6CevzpTdDjqTNz0iZy4y0+yBKt3r6S+c0qMTstkpgWGVw7A7oOWw+xBuKFpha6sHCJtGCpr8DDvbucCysSty0iT++q3JV
# DATA UIGwj5NjOManumQ5KjEQGImqvge+LkXW1I6YnWTaiFpvaZsA5FMDJNrBJsDeVkgGQoZdMAXuQjjJsgeUNcDER7ADsHs1vkuFmXqE
# DATA CI7zbKL51UWWNnLIppNRKGM26LeCUX/seMQcj5jjETtlHrGlNM2SJzCWNI7PzMg/XuzxBEx8xybm2MQcm5hjE3NsYo5NzLGJOTYx
# DATA xybm2MQcm5hjE3NsYo5NzLGJOTYxxybm2MQcm5hjE3NsYo5NzLGJOTYxxybm2MQcm5hjE3t22MRatXKa6WpZNrFOpxo0nyM2MXvb
# DATA +ag0YqVaxausNz7KV4r5EvVPo5Iv1erdfBW0WqWPSqVKvuaVqmWvVCx7jXK+4eEu3FFqggYs3nXtzvp6o5NiGAPBV7W47pXpHdWG
# DATA V13Pr9OFsteso8iaVwONl1dC2et4XWU9Xmyt3mw3OxnEXJWiRcxVXq8ZYq5SMT4ftquNapBRQK1qFVCxmL2a6SlRzWIGKzeO+rzV
# DATA L5VKw6tQP5RrXjNPf5VKvXK1RH3koXOL3MXzG2KPIt1ZrdV2a41mgunMPJBiOqsfg6eMV4bhKeNFZvGU0TxqNPwleMr8TiXGU9Yp
# DATA txutusVTtl7vNCKesnazVd2uRjxl5Wa9Um+cOk/ZMJgcylIG/aLvW4LmywqUVThMVmjy9hhU2lqaCcyUrGnOYp5utfYLr0Z/yjUO
# DATA OsaouaRHpQRV4eWCaqpVJrBWNu5u4u3lKscCOYyXsG0k8rSAwku3Kxer3wIVHrtNh8AcZZej7HKUXY6yy1F2OcouR9nlKLscZZej
# DATA 7HKUXY6y6wWj7FIWh8XD1fb3xxvv+pPdQqc7IMcGZt/tFRzGota/DJPmnLrG56NwUb6SmwVDlVYNW5+3VzaH5ODdR4gy6O5Tb7yC
# DATA ol+hXulMBS6Mj4d1LJwrddaKd5HAlAVKLX2Yy1eHs4BBhiLl2I3Ph7RxQMWcwRK8P8ey5Y4dH/XYsTtu/GM9bnwceq1n4Bgyh+90
# DATA vGsxy5YAWJl6Zx5VzuDXelYOLz9XZ/hOg3Arftz6hJm2EpPhuBRbViA1OkSuejqiBQE8owDIK9QV7q7dysU32cFnXDmNQ8fTB0Ch
# DATA fYU3JwdhzfTZ8+mJ7cEeTjsHO9Mu4Ps07FwPcKKDDtDw29MRT1B/1NPQ9+pMPL9bV2CTbOuQjF9Om9VV0Cxh1D0dbJJuMxbnBHEi
# DATA j5NTxDLBVmuX2wY8O14LOFG5HeDFbbLJpqNtAzz5ghz1tMpwdpWzqxaAtdmTy+G6OFyXoxpUC+i2Tgfv5Zf9wR7EvyAObPs7grEG
# DATA yA2l2EpnDyd2AuxavAOhMkD0tRg2PDv6dPX9PvAWAgXDYsJi3urdnbUEE1Cf94Eioh1VhBFT+nuMDokaTSIZeDK9kOFtiwXIbJIs
# DATA kpIjxhFyOaMf58DZSxwChD42YMsQKa6k7FcPra9+PpKr+kJEwtUsZtXZrjHSdewqL6gwR0qYpQnh6gjHBh11SF3Vo6aq+nuMLmxh
# DATA PUsLaplgUFL7S1itKugiaOQ81S2WJEyqi69Krqmqp9pjtLF8o0siXcJ70gLSv4qz9ZwU8WQsUBZnk7W+beAjhU+vKF58LHuDD3gZ
# DATA oSd7AfOCZqyU4H4oKC6s7iBxdAjqoylJIWCVj6c7OwFHoEEYwTsTSkAMRqCxAKkSo0pDC3OhfRBUdDUbl3CgcWxcrTsAqJApP+V4
# DATA PA0N8GCAEOzvGI5YIFDBOB2LJm+HHYZOmQj+ECM7eyqVNzD1ETh6QBNxNTLQiSJIIoZVRqQRlfH8Ic05KLhluZ1+JMZuTIM5c9eZ
# DATA u3PN3ZRp4yxeZ/HON2GfEYTDS4y+B8ziDpRM2GcYs2x+J80vG0EBjoJeyBQduXmoe28Kp2BK3TCw2c40bIPOMFKMVBqt1/YUBISs
# DATA 3pImcJw0IQVwaO4jvW44TXXsiVX9+8wTAH02GpDq8Cda57Id3qMFPoUJpewAf2cUaPrKtMpU+IdUUptUtWkOQlUpxcnQgACX4chR
# DATA wJhwnj/BhKYKX7BZ2zUzZHCf06PwjhCkBtTrczwCgXgb3OP8JsXBqflzh5rDC4mcQhRyPxi1QuQ7xkhQpcN5YBi0zwIqVFGygvcW
# DATA eLZYjHI0jUm7dmFz8V1MYALGSoTrrgQTlrPcDJg2/iQRb8PBNVNZjw83gPtkURs3NRylkfe6kR/Aa9PcO0r2A2UyJ5h7mpgIj2D/
# DATA kQa6O84xO8bYsHZqo0vMpKsoDJJyHyaYSrRkzTJilbQNSztohy1fRlDRZ6IrUzPdojkL7pPO6+4vauVVPlJszC+mL9Ht3ORMT3VI
# DATA ZDrKIZLMCOM9PfzsPiqmnBDkJ8p87QOJT4F/Whxp3KQ4UmXBuxEEd5klBGFZ5vNAX/KtalpoxMoYvwzHT4U3BGiLCBDrQLE/ZqfW
# DATA 3+kPxuE4xczBhthhON83BySYuD8jEcSr5shM0RzT1jroRHiirTC3WgwIb3MQ+xSYod/F9NV5MLRcfUxdwX/XbsopsERfigXLsWZp
# DATA vIVd9hSYoq+EE/bKRiS2AAQppJCKs4YlpwBMngJZ9LWuvBMCklsbLS52s9qnQBS9SQJIr3hIqbbB1+UhRbRo1D5h7uQfu/9m8eLQ
# DATA U5OxTYvzryDBmX0/e3jw29n3B3+YPfIOPgFFDX19RJcfH3yeZsb5N6a6+TOT2sTvnn3NLDke/fTp7IvZo4N/VKX8Cbw4dO2Hg9/h
# DATA CXrV5/TLd/TCr72Df4gx7VhkOo4a5zlgFmZiNoNdKxxZiPyC0iMnaajCC9xhsbUHUu49ZVHtBIwYfBcBZ6ETnmiuRCYZZSUKDsGd
# DATA 7mIGnCuB3+G3OPqbmI/J6/2s2W+swTg96htpWiQWee502A9L3grNYW5kV2+0uz/Z7Z0k3Q0n2ZLbs4sZ32aPAJR7nIqJ2x3tzaEj
# DATA duJ8N3ByB9vwMXme6Yg1MkWUO8zypeuPemprKnI+w7GEolM51IKfzrat+BI0WiTF4NaR6YIAd4r+ZvH8m298ROvoadHeLK65Y7xx
# DATA SvsISlsT2xxNV78YseCz0dMnqaaX0tLLK+nT19Ey/UyjjUI+u7VwGkw1pj3CkDxONkTnX0RJDGxP7A56mgzGGhPxdEmhQdn5bW4o
# DATA s6AbRoqx4lhuDaYj4aaI9KtuuBxlp5egr7j45XhrlIsf08G+Ca5r7W309phubE+7gU6J5C0sRBW98TBohcE4Z+ofcRerQGs3lNBr
# DATA QMLW7wST/VgoULWD6XSZJpqpgFvSqHiDHEGNI6hxBDUnT1BzuOJYyudYxn49G/v7OOb3k1rfjozGkdE4MhpHRuPIaBwZjSOjcWQ0
# DATA jozGkdE4MhpHRuPIaBwZjSOjcWQ0jozGkdE4MhpHRuPIaBwZjSOjcWQ0jozGkdE4MhpHRvPskNFUqkGlfVwymlKn9lyR0Zjt5qMy
# DATA 0VTKTa9SLe4y/Uy56pWqlbcrtXK8O1qdZrGW5j+pUgMq1cavSuVKkv+kWmtVm1n8JzxK8WIq6+teuVr+z6X1slcuF+lPw1svfVSq
# DATA Nb2mV2qUvVKtRO+qeOX1ykflUj1fqtAYgjGnmi/V6ZY8faObqnRTiR6o/ufyOj1a9ipUQqX5UQlR5KpXpXsq9Vi7qkFzvV5ME8RI
# DATA hfJkwudLpWavVKV+wYvqRdDzJNraWm+v+62stirqGRrFkMwPxV1TLdYi7prqetGawFX5sp8xm9utoN7qHIM7hiey4Y7hNWFxx1TL
# DATA Db9WOZQ7ZrvT7tRj3DFUn2Zr2+KOqdTXuSDhjiEhse4HFndMrbZdqZ46d0yXVsGh5DEIGj2IbjUsLxaPi2pdOrDHwb0y/dv8hW1u
# DATA N9h8iIo8nJLG5pvhZDvJLc6qhQldFTL2T8nC8rBV6dXlT6w0T1k0hlCGtaiR/jHmGhniRIupTFhGXk3+mNCoNLsJ48qO55SsPR5V
# DATA RIM6rER/1L/awmTrlRXiXLaaJcYy3nVxHzuzI+YW5EhtHKmNI7VxpDaO1MaR2jhSG0dq40htHKmNI7VxpDYvGKmNNgg1tM/K2muL
# DATA tBmT32ipz6cu1GM5yMBM0eqpllmTauNiqKXXBpvEaxewzm+vXIrQvHBYxYJz6VMPK0wXuK9xzhpz8sGdG3bnhq2TL+70sDs9fNjp
# DATA 4blYk6dyqvh1zFwgzUWFm5PFTxV/4gTw0oE1hzfvBcFdPuEoa/aYWHORbjk5tLkg6CpU7m3ZJaEO0eiDKtB9CrBz+ryxIm4b0qi2
# DATA R8Ce88hHCrr7p4A5904fh5onImHHCikb9nInAqg+BfC5mxz6Um0kE0RJc5oTpDvyQL9unwLu3HU5SowYIJlyqsmGXOBUxpWx567i
# DATA rLVvAOiw8kTDwWQh8xK5UNNRcMLocyoCY6DjI0zGGDJAdLhVN8ScmqUOgwiYxCSIBVEfgcILBDwgVBOH9VkaFSJ0zfZoX3d0RNXg
# DATA d/fAW9gLGEIet2CjigyNbrfgXQk7ZjnkQPfQTa9FhaLaR1VG3i79OAqwYdXdlydZvOz5Y6mOZhRSaLU8BwXlHYsN0VzBrianAlvs
# DATA 91QBtDqomjJfdhEbHKkT8cDJpEc7pFLmQQboXtHH/UlM9nHyndMMSJ8wFABp6iTET0JTXQ9wHFCd4hanVe4QvXM4bPxzfvLYUU46
# DATA +z2y353F/qOz2I9KKfkUcYB4M99sRC/mkXwzZPhzRY4C0PO+x7m8C0gkzxg+6JmH0zgNfsgI5OikySFtOKjjMkNaSQrabbqOY1Vm
# DATA Oojjx8ApCniqnBhIZDXIKKrsRjA2vj6Sh8EGgBQ6Tdq46XWnvbA/mJKLaGyiPk3yAUBshkG3C2h36NBdhbhO9le/4L23LXD7ZJgg
# DATA 6RpYSrtkkiqaA+az0W+3q/EWDDS+ixuja3EVdhEVQbWjyUuzxjK72OTj8yMBpyHsj4Gl7o8ZQl1WiMZ47gHCerTo/RyG9mLvfktW
# DATA 0JjMyzFvRRe8dwfjibb/BFyIuX90rS+gg2R9gXsJyDckr2EbANiexAhNdYYNSdbkxw4SY0kGZ6s5W83WDC7Y+uIGW+dzTj5NCMd3
# DATA ebNSz2cFwMZHry1SSkDrMTnCPWC3yfqJgjc5DiMwwSQH0XTgsOBdi8AAcQpHUNoMtQ+PIQcNfAs/kGOaHDvohC1vTO5+y0RWtjmV
# DATA LMIMFMzFJTEgucUS+IgWv+z1oSZ9fzTSfEJ8uATvQdQnw0hUZxzTbJdqnxuTlD+pOJmKZOkfI0JEc4V7HLQjAZcjT6vw06DbtVqQ
# DATA yQBpNs95msjnVyUlQL3cusMISvupVwcsMKPwHXafoTG7Xb01GiIeOlDWXPJ2sht4VQ325t+zw2YPU2bxp/l3brOdxhjZI7FS9J3n
# DATA pFVRP4g+1tFC2YG243xQDQtChQttRivy6Y/aJgjPG/4Sjlc9aPVAgkiKM4PN6petdJ5Coyn3xKZpQLLG0pdDNtguAcQxHAHIFPM+
# DATA Mlthr+UVJmdOIEbz8Mw0Bimpsd6gHXAcfwJ7FoaftuCESskOJiIAaaA6AwYa0kb2xPs1KdyCHV9dMpbqmTQ5tjTiTTFdoyHMQPCK
# DATA 7W5eRPSMFXRN2rJHGp5o8h1xhG7MHyE9jWWQbgw5BhsfIVrGLEgk4g7aF2Bl7pL9I2FQ35O5rqx+izvQ7IHgedkFEajVAdBH4XJg
# DATA dJHBqKyUJx8buwXP/sBcW3ZgrvmjLoPK+t2eHpgbgw6TsfZJqzFm6h6cPNKgO3HfrOBt3huE8Iyp701YP2eHvnlUhiRf4Jy1lZcI
# DATA 9/CJx8Ou+JmNRyR7jzgefzN/PLQUl/H4GzJYUoJs2mpNu4wmi01AdZJQLQ7trCouPZJSvJOA89ikMgre27S69nM0hGSGDMKuoBz3
# DATA WIoNej2BfybjoidcYvRTiB40+8VPPlBRi579Ybq+7DBdn25vJ+XZ6wxiraRZ0P9wsB9JMA3GVfA+CMndbU9J0O/IVpSBT9a7QpGF
# DATA B05t6quWPxV2vCceC7vaz74Qe3NZIfZ6OGpzxkAfASBaHH1r8ewK4vXutBe289goZIhxNR6sdcZs2ANaaALL/ANf81JH+/w23x5G
# DATA 2Eg7KomMJ5U2ASxkhIeeeJzSDTrWaMXtP0ljtO0/c0X6/uLVgU441BjcYvKLxc1b/0xq6ZPHgu7Qo6w2Tk+HE+25jnhFXGjj3UEQ
# DATA o0L7H7M/H3w2++Lgj+AqA40Zff509mj25ex7+vsLpkf72mOys8ezbw/+mCZG+1emUXs4+5ae/YtHf3GBs8c5KnH2FX1j6jP63w+z
# DATA R+YlNpMa3fTd7BE+KR61L8GKhvfLe3+Y/fXgD44V7Tkg5TZpDpzyOpjsadpVw8wN8GJhXs2xZ8RpVgFMPM0FANJQhBMYRoYEgJAz
# DATA QIAOwW6gGF1pHo8mnDOG5zqyhWWCAoh0LGROA7I8loLY+Y4+zY71sYg4a/a05ICcHoUaaQu/O9iJKL44w5BfnuThPtcJIzH9Zjix
# DATA 6DtOjkMNprQ6t4EZOhANzt3g6NMOH60T5097V2jAvW0yLpDRRX7/Lukd417mtJE1HuAwFDoShiyaCXGnclrh3yim8ftASQki4cQ4
# DATA XzmyqWQ7chRwZJEZZvUxgR4NkdBrQFlNUtxqi+flfCMmscqeFsHa4uo7gjWn/09Y/2sStmOo/Rdie+9sVP6Ja/ylFP4R9P3pq3uZ
# DATA iPGmGy3/bC2f0+BtizeclSR3iCEdM63e3kdJOTnDOJrKq6SuEyF0Gvd8bHyZrTdP5NJ2MEZIKxhha5IbTYo6OragqtcOO4bbjZq9
# DATA 7ykmkyU520bKXOO0GhxZIYOC4xJB6y50k6Im4zkmvFd8apgzgYRtLhxzDtV4ImxcvDUbjCdiKqBfIsvhgmIxA3vWZEol9Pz+tIPP
# DATA I9tIUJFXxAnYphnt5wd9R9nmKNscZdspUrYtoV2WcnSWMYnP0K4/jln/pFa9I25zxG2OuM0RtzniNkfc5ojbHHGbI25zxG2OuM0R
# DATA tzniNkfc5ojbHHGbI25zxG2OuM0RtzniNkfc5ojbHHGbI25zxG2OuM0Rtz0zxG2lWqVVKR6XuK3WqQed54i4Lb7nfFT2NrJVvUq1
# DATA +VG9lq/UvWYlX6qUu/RPuew1a16pSL9UvFKZPtXz5Uq3vu7V6t560Ss3PqpU6apXqXnV8tul0vpH+Wa+0vDKpXwt0aXBeqfc3k6Q
# DATA npUa1XqlmkV6tp4euXLRqxZru7VG+V6l/jZ9jb/AlBVnYStTC8r1mtco5UvNXr7a8KpNr1HMlxr0pepV6169SV+WrlipkqpZrQSS
# DATA uMZH+QoNah59UX+XCkBtuxW6EGOL40zO+MuCTqM+h+ZOTeBWOOITdvdl0pcj6rdSg4nkGNWgHl8BplgqAIaNJ08X0bWePNxsxqd9
# DATA p8PftfxlOFQGf600ad5QGUekjeNlpGnjZEVatHFBrVmt1eK0cXRTtVyP0cYliOSENm69vR7RxlVb9VqtEdHGtVut7U5EG7ferqwX
# DATA g1OnjcP6O5w2rqKNAjEJ9DNz+OPQzER8sfYLr0p/KvSnXvuFXUSCL+6dHrkSkxxSgVFf7yojdtBXu+a2m1QrFi8kg3kS7sk17+3l
# DATA eJdszo6YqgbIq4YfL7tVUKhafeFVRvFiPJ1PETNIjL+ErGod4tNRzjinneqkMv0p1bTJz7GicEIWVitGZKdj2CSXyyn6ueJ8fjnT
# DATA +zm7BxaYIoc0kK0ExyPneOQcj5zjkXM8co5HzvHIOR45xyPneOQcj5zjkXvBeOSUxREXAGGfyt+AvXd7RdYcNfwV+Q5EGO4GNjFv
# DATA r9z0R0Ch5Uc8uRnL6xW+QNPiTSTTrZbWXqHeaPUKt+m//qZ1Svzy+/FjePzwu/5kt8Ae+iqX83KpUEMJ0fG+jEPjEfItoLiM2NdU
# DATA c9GxFXeI2h2iXuYQtX20yZ2ldmepF+AlP90z1nI0OKfP+mactL5uzgXKHMnFkdXMoV45sKoAWfgsMezoPYXDLCd5A0bZjw5PDv19
# DATA ONNyeBJYK33r5OTSGMhvCurxtnBEtcFAhVf7RqBDEDjc42Vwj1v+eOor2DR8mn8nRCp1LW79QD7Ov5cEbHsw4I5+Tz4+DwjIUV8c
# DATA EQTx0nwQRN2rAoJIRtlovw0cIr9/zx9HCIg4OUnLCwjirQGHTabDIc49I9EAh9G8kcBCjkHPIYfZOQpGSy0oeLSqQxwdTuDosD5s
# DATA j/ZzXuCP93mhPDnuYaINZwZRac2/k0MMNTNZ4VTDdhhNYUZGY9Oajndp5gYMkosz6HKE2he4ajZzIiMCViXsEqFhwEDtgvcOIiJC
# DATA plZ4Dnw8fIr5gXjptuY8eSJ06qgBz8HAfLD0wFynqZ5HWGUfGOAWcigfbM7RiAwDXj28bPQCYSIZDBzJIywcjRuKc4RArAJieDBk
# DATA 2xAdbqFpCOAA9rZEv4Xd3cGUoUefHN811pQzG6VjC7crywq3d0NkzgDDYzqykJHJQSGfD1mBk8FQL51OOOoBnHQ69NTADEYMwca/
# DATA CnrJHjVqNNgWcTcK8JVxw6b9XTKqgG5gw3g8yZDEan5mI2IpySMOyc35Q2LUrYzJzZEfdgUvxSezxgwKfZ/AOIH9NpAebpPbAyMP
# DATA U9OwYY58tRwUZjXIhDXSTIQkEYG9CQhLd1/Q3p54YOLVf/bXyo1l18oH4pOSgxoOaQqbgcHshuVMrrukCMGwZjXO7ihQPYZj1vdw
# DATA 88FHi8RcRZk1FsxwBRI+YVBrjC4ip088FIkav7hYxz8GOBH9uItuuejWMtEte4q56JaLbi0dxZobBDud6BYDbxkCPN/bGQwEFE/H
# DATA tp5Z/NpFsS8cafDsCFgqqCXspkgYUXnI+los2qS2Z5iaqY/8e3ZU1Ubpaqu3psJeemGKU4pRlFLN80aURVdM6KfM2bUjSG5IsV7I
# DATA BlKZ06p7Pqe86kTeYMip14XS/AAZ7yBhlg/UuA4Nalk8TqZuNDXTD6ZCUyXF0Au7p33eK3mt3vw4VqlQ4wACFRYGI7q7UIvdn4pl
# DATA KQvLBAol6YaKuKzhCxNS1jKTMH5UBT5cpFsl2Ve26RJdkiUeink2JH04kYT0c1LEExpAYqRAGVnrzUazvDmS8KswxkIOpFCiu4zX
# DATA 2NdR2px4DGzDcVTE3/FDybpCSrzQSJH3UPAMyV00TwseD1qOlZ9FyMLglVGRwKsca+sYr4M1NQz7QmOFMskiNhCE2FBkBDUcGgOk
# DATA 4/a+LE8B5vOBQGnvIo6nO+Cv5UyBaA9Tua19DUHJeJUR7OSULdR9z6QL6Jy4Idswml4WXf2jNzwjVeNMT2d6LmN6Olvzx2trzrUO
# DATA n0G0aj7RYU4XpM2wrmWGvgWzk2sFFvJRINuEY22FRg8x7BIL32cP3frZh3zlv+WczsVXSYImF5Y+FohyzRGuppzws84sygW/y9+S
# DATA INzJ43qyTFsDOAvyrv1+S8xvg3918b3UaT/O4KNBTIGbW0/xF27LEsDi0bEVbY8lyMH3/H12X4DnbAyzS7xlJ85R32wKIp64QyUN
# DATA 92V7UXwnsBEO/XvsuxS867ydNdEWlLpH2WeYlQgZSzCODZ7kXpeP/XCy0jRbx1KTIDmZLt8fdlHqOLyP1HXZhpTpfebkHmduPEU0
# DATA ZTSh7gXdnSmJC5us7N8OPjv4LdOSgUHsMX/+FtRlTBv2FzCK4ZeDz9IsZf+n+fHT2Tezx6Ai+ytf+MvBZ7NvcSnnzb6aPWQqst/i
# DATA O27g1x38nv6AiOwLeh2IzB7Tzw+ZyuwbKuB7/HbwCRXzDcjKDj7xqIyHdOH3uAhqNMdd9lxYh2gbu16IhzBcuZ6958FI6o/uYpfP
# DATA 7wc5hD3IKx2x7zj0xf2BkiEPFUeleQ8JeBnetM+FMTb5NOwyNyqtaJ+zOcmx9CdCkhogVZ+E2ULWMiGTDkRROtIy21a0BMZZU5cl
# DATA RuX0mMvaoZzDHJs731BXeKKm2Mug98ydNOlkJo5OmLyM/fxwzAkIWA6cGaar6hjMlhu1E2cx08KmE/JzfleCSuPWbtCeSppIV7jj
# DATA AfnBRM4sxTxGe/VKtXwv7MPW9rs0uZFHckFHepk6Q6ywUUAFC5FC2IcIFjNQWUayJruGvnnZqTnfxIkvtadFX7aw8o69zFkAJ2YB
# DATA aN6yoyv+FyJAdJZK/6R1/lIq/4ga/9QVvszHWONt9rJnYvmcBm9ZrMVeID76WCJSzMLtDTrxvD3uhsku1XKH902w6ELkaRrLiCmO
# DATA ev6QGy6vhYyScwM0O8G6hK0WTZkk+ZqscWXeewacbbwkbRn3nJoUHnXHFK8ThQ9CEAmX7WnDgIZgjFp6bRz4wcvv9gd7cjqirZJL
# DATA QRs1DHiodwfTEbi/mIMq3A676CpYd0y0QvqI6aZgLAgGAtNzmTMEisipP8gmn3I8Zo7HzPGYnSKP2ZKaZimXZwn7+OxM/ONY+E9o
# DATA 4DsiM0dk5ojMHJGZIzJzRGaOyMwRmTkiM0dk5ojMHJGZIzJzRGaOyMwRmTkiM0dk5ojMHJGZIzJzRGaOyMwRmTkiM0dk5ojMHJHZ
# DATA M0NkVm5Wa43ycYnMOh2/U3yOiMxiO85H5TGrU58Uq7v1evNeZb36dj1JQVYO6q1OuieLJerK6m6t2eDPFZCMqc9V6lj+3Gx6Jerh
# DATA SrXYKzWLefpXfS7pzwlSL+r5dqecRepVbqaqUK5RFYrlj0qNolcqgYLNK5eKkxLCxs3D6MMaNb/RynxTrZ6iQys1auAl8yrl/HrV
# DATA K9WrIEEr1ajjShVmfquuH/K6VqW+nc1WZpGo5eEO+ADolxntrWcQmVFdIiIzqpQhMhM6tmgFVCudRnnp/q1nvKpcbESvqpRKp/iq
# DATA ijCyyavK9cYpvqpWtlvVLJ7iq+pMRadbVTnhDjwSqRyLNE0qJ9LRIpWrluuVZjtOKpekkMsklQtKQaNdi0jlau160KwYUrlWvRW0
# DATA LFK5Cr23WT91UjnJLszLNoNWcxX2IDy9O2Vsl6aYf/YzSVK4twIS5qGfS7O/VbPY3xD/bNzby9Ul/qlK7vnLkbwVGovCmto9iwpN
# DATA bpDY5r0en1RkU41MrBwGt5gT+vr5dpMEWDse9DqaHeZxuBZbVfOJ4ayuWmDPpeocd4tO0Tp0HHOOY85xzDmOOccx5zjmHMec45hz
# DATA HHOOY85xzDmOuReMYw5zIZyQhz/ygcVOE+yCoZ3buPix8UmG4w2eJyKl+Pwyrt6xVr4s/I2LZtmHndWf8qNq4a59rHjpNHIRwFDl
# DATA zBdTHA1ZVItxeeGBvLo9lb3nDbugl4XuDpciCjzmpZMtHfvefGnt5VLtlVIN1dGlXZQCtqfkL2JQTc0YbpYRaPtB0B6D704/A5I8
# DATA gSEYG+ylTrAnAmQop/IE7Isu8QnGWHPQ0TjFuKHN+hFeLF0lm0+r7NCtFWTzYXXVz93LhTQI/ivK0L639vJqSEuj+Fq9eL60lisi
# DATA 6YtXPfafNnobF1d7FzdK1WrxtdsrV2lK8hFLLhUdpAwf7qdOd0A+a+9cvbj2i3J1jTywNuNZrZZzt1eKuJsf08/0fkE3pm+6EM0c
# DATA 6XLMgNUx11pNHQSPNrh+q2g9Uw3+f5/8Czp2fAFXXtnIGszV8NX4IL5Wqp0v6t7kUi88WCt8OAj79CwTF0ql1cdXMl7ZCfvheFeB
# DATA opZqejBxWlYCLkKA+H4fKBNCB4DnmfRwNTFh8npWrNnTghYPzyPTLWtUyQs84DQSee1V0POvLTIZeeVh8UTlfAw9SMaQOnSskTM0
# DATA uIUuWXMr6kln/C4qXJ+HLkzuQ85YdZSyb+gy9UOkcFGWoWnUB9EcUoRDiliMFGEdU3R4EQ4v4sh4EXNxSk8FR+LadBItAM7a0pie
# DATA otkNqMSzCGN0Fjj2YqwIjPtIrJgEcj0uRbj1+n4jvMwFA/ReXD+vNswVcP0cPHqlcBmRfoKT5cyHZIC9V5XmPQxJ3xRjqhRdiZD0
# DATA q8UsKP2KDaXfKBdtLP1SbT6UvmXQoPpccXJMyKviaRWH04/dbPWbXUQKLZ9rdrFS1PbHfFz9KtezWjv8zjqXWc8oM4W9rw8wUrv5
# DATA IOJFZRQLZxBWDt0qv6ieiTih4DRwm+LjpgMfyU6IjdO7kT5jVSgOyEXrcmJATua116E3ecXbb42uns5L5eCjR4p2RGIi9ub4TxG9
# DATA ZzQuc9kRRJIpmoDnlxLhCuJ7AnWjjBVtydvIGQZjpk0OnWX3x4Q8m0EA/ojdogB4aQoz9gwgZxhPg8kNGMxBcxDMw6CJg87YrGBp
# DATA /q9snjDpwJj/AE2odyg4tqVVkE0Cdii/wfMPbhG3MJxf4vySQ/ySmP3pXBPnmhzucTxViDvoeExwXQl0TjdCuXvTOCJCeMCYT2at
# DATA 0ej5Ywa5AuAUY44ZEKqcIKf1fAlcGiA0DdaQdC4S1AtIs7Fpv4WP1jbAhF/zAwGeC4RhFqFSrG9qDE3osXFpmKOLumf80RTV3OHf
# DATA puN90rl95vSiBoqwyCkSInGPtKJlQnoWF+O7utDh7mAy2Bn5Q1bVwwCGtIL3DUcMPSZNjKu9ic+0yu8ORoKsq3RdktxUKJIty09a
# DATA K+aIRYfGggyybU/RICNNUAk2id1jd2oPVOTAh9sU/jShldj1bXpRRMjBMMBQa4jtLap92GarbmHlk8ajtMBQCgiJ8NgwCAPFf2KI
# DATA nlsMCKfoLzQmcYSsJ1y2cew9NSzbENnCT2BJbV/m74I2bSLDvj8Ac2uyWWImxHljU6iKZiKTWXgN4X31ZvQrmW27YPBVlA3SBfwD
# DATA CHtReewltxi2DUZNDpOoL00B5x2it4PpWPWHKjikfti8NwjbDEnNKG0gUJAuJQU1YMbYHqDWhnzSjbNTsl16rvUvhU1EBcDFKdN1
# DATA xoZ6DLh60BEvDDh0vd6gLYsbg8eXzVh5+vDcoNNBTF2PncawljHMecPpNlko1nOMP8eL0G/DAvJGPIdlspLuYvJifqUHJnZSOmRp
# DATA j2lNLmriDVCDK3KvCZSI1UQwlMkLSTKEwPYicUdtHdLznWm3u6/4VlRNOYwz5okq7e7FmAoZWVBkwt7uQKEjkoBEJigN8WgX61AG
# DATA DDI+SVErhumPz552bGHOll4aDdqZzj9q0/moXGFPGR3azvlfTBZ2E5pAk12yUSXzfTFb2LODJv1cQKoexiAR5f1rLq+TJBWLI2Sf
# DATA NKdYEnE8k1JMhd8YzRuDylloZATJjBiLWTPo2uHQYKiF2MWrjF0ivGLkqjA+sThN9D76Hfe8GUaWM6QHILP7sMuFjYzmTXSveCaw
# DATA aSU7fQALLwQU2b666dygO295ir0MOxfTl10LPyvAuJAmBKFYw+Scwh+HBcYwxMMRZvQ4MMtMEJx9465Kmg0Z9j3cRXZuLNpKNjdA
# DATA i20sdLa02YWUnpoyKLk2cFP7bClb78dm5UW0ZnvBtgK/tlnN/nn2aPbn/MHvZj8wy9jj2fezvzC7GH06+LuDT2YPbYaxg89wJU1w
# DATA 9u+4PPuCHn7EFGWPPPrykC4+psvfg5ls9oXH93zFHGf/KPcdfK6IzB6CSY1e8Bn9+7kiMuP6PESdDv4BHGjMd/aX2Q/0A93/teM2
# DATA e15sWVnkWHgafJ23rAzzJvaByIcTdHF23gZU3ASrHnWkVf4+UBaZQ16iR4N7HOXxR1FUyWJCxPJYSGX2drIajs7MtmkjQXHWbGYZ
# DATA A3N6jGYSUxmnXq6uJ2+XDAJz9/VgTBqoJQqbB+mEqc0kvCR4/gityMYfsxY4YrOlBu/Eec02PQvvPPIMzAzgTWMA6Uy7zMKxvY+/
# DATA cZpChefAeiIVFDvn0rX36X7BNM9pngqd72JITNj+uQfyYo8udlN8ZkvOzPk2TnrZPS12syWb4njOnDVwXGtA05odzwh4IYJaZ2gA
# DATA nIb+X0r9H037n6Hyl/mZ6gmL6uyprKDTYDZLNZLZzairxulqgeNMtpU9mp6YqeeF6CnnvX3z5rUbOXWwVO0M88hwzuiI7Afe2eFm
# DATA QEMjKBGxKY3UWOrIg+5TrXOXpTczU8GjvgYyWNwAQMvCFmjOIiMgTnA2HAVtxEbiRoFtDOR4mUJYeDAw+i1lHrBVAB4qMQ+Fcorr
# DATA P6bXROxmHFQZ74/5KKW6Z9vxmzl+M8dvdqr8ZsvpmqUcnyMZyGdr8R/H4D8xe9/RnjnaM0d75mjPHO2Zoz1ztGeO9szRnjnaM0d7
# DATA 5mjPHO2Zoz1ztGeO9szRnjnaM0d75mjPHO2Zoz1ztGeO9szRnjnaM0d75mjPnh3as/Xqer1+XNqzSqfR2X6OaM9S+89LUZ9x56rO
# DATA Y5YwYduqlmOHxUr1crzXK8LlJN3ejHVcuxnUgk6CvqnSrNWEqitJ31SVLrbqIe+Wegj3VVSPSvLQWjmqRjVJW5fFF1a3+MJK603D
# DATA QRVjSPt5td0sNSrpmdOs0tRp7sqcs5rn17fXW34mf9qi5pWFKe2Umle22LyWbh49dGLNqwjH1yk1r6KePlLz6KEnal6lXH4mFkml
# DATA 0jy9RVKpl55gkVSaxSdeJHbzTnyRxJp35EWC5j3pIrGbd+KLJNa8Iy8SNO9JF0mt1HwmFkmtUj29RUK1eIJFUmvUn3iR2M078UUS
# DATA a96RFwma96SLxG7eiS+SWPOOvEjQvOMtEpuwtdj0qrXavWp9t7JevZev1nv50nrdq9bvVQ4jUJ2/CI7DhsmWrmHDZKPZYsOsbNfL
# DATA zdpx2DCLgd8pWWyYlXrQrBo2zO1Wq91uWWyYpZr8fLpsmCqZV7w7K9ijtt0MPyY77GSi20G1dd5jz0ibiJUK/zV9TzJVIb1l1uQt
# DATA s0ITqTKyaRYrVW2YLyy5zrtn8ce0F5idbBjdTd7kzsjvxfboDmuueiZjez59g96pT/V5+u4oijgvQ1JeVJIhklBAqhBsNaSpPtW0
# DATA i28XrK+vIwJzNPJOjhhltIrDhqnYczpdaC7vp2PrdGydjq3TsXU6tk7H1unYOh1bp2PrdGydjq3TsXU6ts4TYOtMU3PuhNuKQBG7
# DATA czA9FTmm5qCiK+dKxWqz1qhfiPks6jE+PIzHNMUhGebTIa68UsKT5eoFxY15WR1jB35Af7Lb3Tc8V0yRSDWhefUm8vtXy0yL+Fb4
# DATA ulAqXsE5czmlPOxOxx4Amz31In5WVWne85teufYL87YIaEf8UuqDewFTda5SHV7GHv9aVkk2l6F1ztQBwjhAmBggTPrQsUOHcegw
# DATA x0eHmYukfJqoMVpYAw5C1guGi5EckGjDmTcWhMyzg2N2FoSGoiqZ6EMUGaNw8NVDiAT1kzExP45RtiGMkEkkWLJ4BPmmor7T0AnO
# DATA ZxM06hxcguozymbAkiGUom6Ct/rL8PXDCBGt4kxT7GumNbXD21I+QjPE2oAEQFRUTILVdw+vr37OVNZcsGq6XKcvWVNtB/E6BVAi
# DATA IEciu4VE1zAMDpsuUSER8WR0yVS9cVjN6wtqPZfkz4gA7TKxPlSD/NyT/mUx/RkLMTDSD5KJ5phwefDyaBt4HdgGPKR+j30A3p5h
# DATA QBjla7bIqWK0aCY1QW4kuTc5b2+XJh8Zh6OdwCpN9W6nQ7J2ezpCbAPPkXM1CoDQFE40wI+KV4vnMWZYbkZioim1LwYy42Da86zg
# DATA XRr0OCxGoi+nwHr6bYP/FIEuKWeuLU/4I4WLFNkyEclsj+o1HXFsVYEPLcEa+GNDinGcJ84RmOMIOJv/hbD5j8p08qwgRdqZEosp
# DATA T94KWWMKWiLvRwMkrs+oPbS2esFC7pOnBy/5fKGrHYYuncjxOA3ikzSA5kmTn2ThkGYSoMTGTqfEyETOIvh7E/a8NhEy72BUz4V3
# DATA vC6mtTE0jgj3rZj/mK4yZMBBEIkIxqc/kTFX5uYydJg3Irdb0yu+ffPdKznv0o0bOaWHZb2wWlBY7iCxFL9IgBaHQAn1NZIqIzXS
# DATA KBjYz3Ac+Q2a2I4XeDiB2l7AqHhDhIEkvC0mi9y0KqEmsW7RJpBA+woelWvHDaKGtQOw+QX9FhBB+wHVT+Gx5mj20nTd1dtsAs8a
# DATA R2VdSM0ZFyCHVF0Dzoo1rautyBTZ4FYHDAOJZwgZKcx+wb5nA3q0ryAxVS0L3jXNU4Oa8+6YFmS+1/HD7nS0iM3yuhSDjat5fJYv
# DATA kAVuy2tngzsbPNMGV5PEReJdJD5m3c013p8d/Hae09DUEZ2z70mk0ETgJVYTjpG4N2AlGQcf1yH0JPvZdAg6wYL3K+SI7xuKFrqj
# DATA PW0BRKYHXWygjU28nRmN2d5ZGsg9wi2Q5YmvF1/Vht8NHPPmhQ38irEiwBaPQ8mCV88ZK3Ei0nsywkcB5sarWhKsJ3tjNCAdTAt7
# DATA N/OG90Wnd8DaPOeWD2CyoZWCxc1g07j1HN55Tr9flFGyGspQVQacsXj4Te2Lb6jkRJ7BOQ9qpUOyf0BjxrSfNNUmbb5T6YicJ8o4
# DATA p6G2wXMHmuLxrpTbVtWaU493/T7NqbZtC5rKbEYQ+InfpQq26WbsLxrRUQDwbt480JbX4RX5VTiaTIGozlDiVh3UALOZx7OVIeVZ
# DATA powGXVOZ94aMqGJuoEkeTBglfcjKkzqo29VTfWzV55waqHNq0s3hpV9M+31D23lR34vJ57d7pPS1lxNx+2gkccXUPt4dTLttXpdi
# DATA zvZh+SHxHK6VoKvLABc8ti/JAu4O9ntcBNnn4LP2AQ5vwdCDi/7DwTYrTgUxP+0zF6IqaREheH+wp/DKtensT3Z19T8YMZw9zXuP
# DATA wU0k2M37LTpuzEFnssapGF9HmyGlSNjxPfiBOVIjGxeUUCBZ1LezYwSm+j4C7KTOg76+t624HqO9wUWNeVdC0ao9voDnI65uwvsq
# DATA so6K6f2MiFdhN+gOlTyTDU9LFjEMPinKQYxUYRj4dzHCIjEx97Bn2Q56eIHtYSliBSpF/EGmhccqsF0zZcfYxOdm/xPzM+wtySH+
# DATA 47LtHzy48+B2f+Wln/zY/6OuD7pbEBhhfwpS1eH+ib8De5f1avUnat848W+pWKuVf1KM/vtJsVRqFOs/8Ypn0QFTrDl6/U9ezP9+
# DATA 9rOfXZ8KQ0SLBEjYZj2DSbEy5lzkPNN+RBPEu3TlHZIavM1J63vQbfMWPj1QoLJeEqgUsm13+LCN/v4h2Yf682D8EmsvCP1uuO2p
# DATA y9foq75lZB4cT7dVfEZfwZEsqAP9fUqmy0svfXB989q1y9eRQL2ysvISn7F5SSVYdiSvmoNNq+RMtoPznfHKGmcz4mTICjj4zpFU
# DATA PAdW33OtbkgezMqFlyTVujMuoB8Q5rux32+t4qGct0L+enPFykBd4aBQHqXno95aWVvT8aVCcD+crJbWLryUzPuMV43PkW2ph+gN
# DATA JB33+vzmqKCghd7KebdUZbLffSf3kud5H0/kFMn5Eqc75Hr+/denHeQ+luqVZjV3l6zMG+FO3++eX7nxzlu/fOfKlZXceNIOB+dv
# DATA rdB1Ug8ruZVhOMQ/6vudB2uqe1RiajAaker5zW90ouqYC7Qv8Ga5JL7O7xLJId6IndbSz7ehCyYDdaxC9b+uBj/4Gg/UPr8EB6Pw
# DATA +p/K4aFCOL7hd4J3yC7awSEF3F5Af13CTvYa7kxc8171ilmXL/Jpm8w26CuqrnswZFZVfZNvpPujU1vJorwHL2ESv/QSudAIU24x
# DATA u9Fq2B8PSQtvyaCz8792HkOMLuAddFyCDcAfCmxNjOFCra7kV9bwQzfor8qD1JBaqYxreHIUFJBPwGnEq6OVW5v5/+rnf13Mr28V
# DATA zp3/T/k7r6zEX4j/Rj5cuV+hYZcx/Ksr7/Tv4bSPJUn4mZU1fkYp4g1e6bHGrOlGyC08WVZp5k+2cFKXalr1XvaQ0Kv+WVwHLtcL
# DATA 7rfI1h2LI6lqAHtz1IY0gDwqcPbDqnonps4W8qtX19ZifTqmmk78fgtTkR/PeTg9YLpTXV2jaeeVluod5eoqGtNgpGqnr2/oet4q
# DATA 3pEf9I3I+Zab+FDiyjttGpYV9XjQvxeOBv2eyg237yN3rhPu0L0fP1iTK5f79+RIkN3U5CTw8x2aAXc+rlcf0M2mFmt60lhdY708
# DATA 0T3WL2tq8TxJJ+E0tBxw4a9w1kVohH27B6JXpIeR78/h6C1XcoXsPDwtxfCFUfLC/WIxcWljReWsyLXofdnNer8/ng6hrsi7sKqp
# DATA GoX/+LTnFrVMJAVnDK7Sa3JeaS3ZmOzVunXHWrZ3XqYncWr1sJrpDrenDz1n1Yy7vEDqMei31QFUs16nvVUMMm4pkLNB4o3P+WHs
# DATA sQ9B3cNPY+TLtfoSy/eyVY2sJfxz7C0hsOH1FI/XG4PWXZyuwT80+ejB0T67Tznxl1s8H3GSAQMHoSxkemT6F1SRyMAi2avY8mDL
# DATA wKdl9j61SXRB2M8QktKeP2LQDBkKd3G86yP/SparkX4bVNl+wBclkKVMl8LNALaLP9p/g4EFB6N9BrYL72+s0Iv7fmuKA+VGk0N4
# DATA k6va1jdHHUijtqWsGJaq5pY175y3Ys8084iOmQ8gTgbjAhjCVnU5OVx5b+uD6+9dvfK33m/k26Xrlzdv6i+X/8ulKzmvOAClhymT
# DATA W0c/d9pcWvQKEk97UnlaboHfi89GuaYUJdZh4UMauFU1ZV7hpRm9ZGI3nDta8altWFZigQZs9VbsNvy30uZZAnEpT+FTXsK7+Gh6
# DATA vRD1+gYOe8G6LOCvKimk3eB+Ll10Pq+mBJeu5dV5PG2+8duMOS0vJzc73x4NhhubsLiyyh3rLRqyTzf6A3rPXh6ebwgimbGUQiOX
# DATA x8itsEQzA7mWWSBqSVMET2qbV5eiVw2+w0zRCh8/44sysOPF3skhWDCZjoItSaHcuDmaqoPX+qNYnxuVYk72Tfn6WnwgrRWjBlUb
# DATA UYhTDVfjty+nrnSZCQk4d4UuJybZEvNCjolNbCkp9oWy6JPz0Zp+bJRJp/uTid/atet6Jz1qWf8t2+elhZ2uTubFDezl+/t2++NS
# DATA riaWAdvQsDv7k1X1TdnJ54/Qt5aTKZVKdS/DAUQvMb92kPLRTYgHqrbp2HQ1FgzRqCfjQ2qsFcSHx5Nu2rCefuPyr66+f+XKoSNH
# DATA T5KXlPVkNF41PVxvAsBhTXkA0ESrahqzUwTJrT3swuZoh6P61/gXNXRyG87ybfnqd/IB8sropjbp3AtrYsx7hk34zCfoNthi6kH+
# DATA B4+OVSViApvPbaxGzgzuK6j65Dz5xg6Gsmbvg4bTu8z/AIjVFPRzpfHPvfG6x27nmKlBlai1A9YF7z0obd9j6h4P2Ut9RClbHukn
# DATA f0hGTcIQucHB/cvwwlauDpDHHc3Ilomhb/P1TjjqBe0VjBFNtK0tmANbZL9teCtbWxixra0VqbQM3zMaShzhFHsvOI2w33Lxv3K5
# DATA WKom43/0d8XF/87iv5//9Nx0PDq3HfbPkengDfcnu4N+5aWf/exnDNwhfLXYfJGNMewxYMcX2xWDYaBJb3UC13VtRnnsbXW7JBYW
# DATA RAWxTVGv6m/IadKfd/0xYoP6awh8sJEVBDx+PFF2EM3X3ekk7C4INvojO9aYjD1OdkdCdBcLRnJtpqMuVUaEoq4SXWO/jmQG74t4
# DATA 4phPpRtFG0aKUUl86r9NW3bBWiZ3xtve5y43Hc1GOHZIRsGHgdraQ1vFoRzzOIg+QZrXKjkv4yieI/Ivozr6NvUog+ugo/VzopKt
# DATA cAq7IXyHFVJh1xBpmyuc5rSypssT03/IwUzllyMNZ0P8C3nHBMdVJtrD4aK1/yk/FcLx1ni/hyyWVcva42auzP777JE3+2r2cPbX
# DATA 2eODTw/+MPuCPj+afecd/B19+Hr2rXfwD7NHB5/Qta+8g09nj2ff0S0/zL6l2/HDp7NvDj47+BP9xE9/i6/nPVj3sLelBkppqerI
# DATA acRCD6b2qnwZK8uMvcytgW2P8Ybmho5idOZFKgIyCKSf29PecKx/C/rYfdzyx60wFKsBiWDQgBtl7UJJpKSdY5eVMZeUG9q7i0U9
# DATA NL5nIXI+SeFT7TdiLcrQ6vD5Wrs0ZKsoH0M31ynEDeQMosrxyYDN9D34fBvs7y3lLKLT1rJ+7nSngIOJ/YQ6IFd4Vd9Dbe8PdJxP
# DATA 3TEKmA1MI0fJsNqBF7qH+++npOHJTYpXzvjdW5225VbHuk/51tffsH3rN965fvnSzfeu/228yilfN9YO+23x5zINYfUsc7VnPJt6
# DATA RhqLhVbg+TrmTkn4UXTHtM9Ljn9U61k2eFWUyMSmESJSsGiIA1XmRJ1XXzsfRbDuxL7l73xczNVLD6zf1167XVh7RV2483E5V6/A
# DATA GbFfbUmB/zn7hlb7f9Ca/i3kwZe0wL+jFf+9N/szL/zZX0kC/EA//kA3YvE/zNE1uvIJXXvozR7jjs/o82MTS2bJJ9G6LjBJVnUn
# DATA kBoxaYlbkPl6sSJuZXWl8qsSAURV8K0VpG2Oz587B1Gj+tUUgJVN3nt4jt61cie7n4u1Yqob/o/Zl5B0JNQeQtaR/JPmUUupT1hC
# DATA Uvsf4zfIv99zZ3yH/qKvs+9n35MEfGQCzmCkHydDlrmVWFC55L26oQLBfPsavpcPGx/U5jFG5zFejPd/gWo+XLb6kUQX0X/w+cFv
# DATA IcXN4ClH3QojcwhEwshcUTvINmGgHP435SFTO+UHNQli2y5mDBOrJ1bkreb5O3Zxurf2xYu2A6ZZQ3nsgfza8q814E5ySd76b+fu
# DATA vLK2SovxXLT2Clv/W56uvrx27rUVFXFNxailQOTS9YGstMMRXerdj1cK8K4LhZUHkoYb/cSP3Crf0TOJem3tkKYn23s+trRl8vDx
# DATA i3w0dzx+Dov54J9m3+UiCaBXO6/8h3TzQxREt5FkmH0BGaDkAxWu+/rbgz/SDPsB0xMzl75/bvWqoAlmrWRpa+kOVrJut92FeDLs
# DATA q4m6uBMOWQvcId/S0qIh97hRXynbhmp88Ecyauwaq2iQivYDXtCWdvJrlpiTZh1N0h1p6ZthXdxc1RRIXYnDHSKJ+W58400lugWL
# DATA kSemGgE8ZQQs5jJNS1znPQi6jf/d2EhL6I7+Ud08Tiulf5dmHHyWMWrfH3xGfcLTGGrpS55bf5R1m62/WDtdiP1G05g67JF0JIpO
# DATA TdmDP3pyBy6amaCGm6udNdrkKq5OBneDfnx85+8ik7i4XVj8naSCXWTSgpeafwbJTi3bvPZOPlqMS0wI1aLVlc1r17auvXf95kal
# DATA WCre7l+//O7VzQ82f3V569rm1ctXtt6/fmVDccmwMbzn3wvOVwC+0F+JrcKV6EmqzNbN9355+SrvGHAjxPJ+5+rNy9evbl7Z+psP
# DATA bm7duHzp+uWbfItyQgt869ZucH+1AmM9Xv7t/s3r79+4uXXt+nv/5W83Srf7725e/6+vb17dunL5rc1Lf7t15Z2rv9y6fHXz9SuX
# DATA 39hgwFfeLZHRgruZtMKyRogD5iqMC3dG4ctqA42VN+J2yqqgb/VarVJLDdG/ieyMhI1MzYM/yAyjGUxl4Ud5Pj4o0Qt07SUrl2Nq
# DATA y7RCWYS3zGSCsVheYA3SjIJCpCrDSPiGJs73VO9HkDnfHXyujEH1y0Md8Mgw/FR9rX221Wib/Hzc1Pj4QXrH2ty8aJ+eR+PWnZh9
# DATA jv3n7L1n3kduGYy4RbvJUfVu0VN3GFGOn5sr8nVu6Zba8Vq1NriGQTAak49zLxiNQnLhV1aiAIZAOXK8Qm+fDpDeG7Yku59BJEzi
# DATA qpah3naALF4JXbCRgpjsRrLXkHma7rmr8p53sZVlDFIpABqZnlmJezyq3hziMl9+mr43pbm+YiFLeolmDsmcRzLl/2n2LyxZcQmy
# DATA FqL4S0QeaCmQAYJC8/rugz/FRHVMHfMgSB34quq/cbofVItvBBPsY48zOmMsc0nNRLWYdIFpveyx0fg92zVfo3KwHhJK5XvVIPxD
# DATA 39VmPMxMrCNa8GRfkILDQ1QctBU67FE0JNn9rnIr5tdtmZ5XquAbqsufRG+oSqSaJRo4OQDKFNeVWMPMKaUctT4CXCGgb82NJMdS
# DATA TryZ1BsmDLiaLTdurbyxeXPz9c0bl6GNVu6sFfSz9s7I6i+DfQ7R5bxUyDDxPrPFqUZc/5SpaGmsME2/5ZGD6GZh+EgMENhouBjZ
# DATA 0jKgZFmS6PzKi1U8sq1UPfRH4y4bx4O9SEtAQpZg/FmmxJYprpjkJx6RxCrgy6oIuYLTMIG9Gq5LTgfdF465QxCMS6QWyMZPtDOs
# DATA d3yx3RXMf9dVap61fNEWCSiRNc3b62jVqnX/8mt2rRAKnGZql5O7d+6Kmdsk3sHrhozBQ73PH/XQyCkoXOEK69pLzTblIa2Y1hJR
# DATA S35MopYPsl6GHUaE4laT3caJVStrha642PD/dH3iSkttBki9JevBqh9j9euirObQdW7MyjvXNqUAOKJvdQfbfveda/fq+mKi1tQ4
# DATA M4fpcd1jyro3l3WV0h2vZjjwwtWpWhVkBDPA2hp3h55edhyZHRjcUpj2yehefVkXJAF9JFpBpan1w/Fhvt2WXaokDiTMDwZFqzhb
# DATA WbGQ/FQCY+QnfMMx8seZ6oF/EC1wQdtRX7CI/SO7d7aE8CQ+8ciKqlkKIbbsdY9kKQnVA8fX0KggdcU/wX6dpx3mSDdLD+hq2ZJW
# DATA VfvYgjZeWbpPbjDd9gi+oKW4Ct7sX0TzfsFV/z3/8LVq61dqVL/mkWD/5RI8DNOuq5dvfvDe9V8m7KWsLtacGQPVXvV9zBmOq+r2
# DATA NSSwiuHYEhN6y9Z4CcNeGcVjVlepN0U2S3p/BMei1lJPiIE+9yFOUj3/Uip15+MHMeltooIZpnY6tZTvFtGXlgNq7P/ZYz9c3NNH
# DATA ZjfVzr+MhWyMF8WW1Cfs8z72fnn5bzd+tXnl/cs6TkIXEuky7AkYEmrbKZB4JQ6yM8ktHIPMjB8qYUEzMmv+Pe+pfcnG1g8SlfiU
# DATA HXXLuVKxWYnmwPH6emUJp4TzTXVrRNzFcrfi/kpU04UdnHBT6eP/rtw+jpZK11rjxVcTDaCnf2ccb53WTjWz90n1wYZo//SlhcnJ
# DATA sRRq5XzH88stTxZGLrrxKxZx/6BjRCk5JvIYbfpBmk6N+jzDq42WLXbKtsa7frlWt1vTDndwpHBDb9MX1C1rUaqrtQ3MO2Ero+3s
# DATA rT0sstbutH8Xi4zN6K7f22775/WOHhMiWMn/azlveyUZT5caFeSg8CqXF2uX+n03uC+fzF6NHAfdQkNIpUbps8p5Hwwm6dRatWvW
# DATA FcYQEXlDsVs5ZovMYrQE27+so4fYocYD9BUabBjtJN54e5N67sb7796IpC6ijMPYpvYSxzQkgiYlr0WV4WouFQDhSRPtifPuCU/0
# DATA L2SNyoSihWCUtWzFornn7HbgSIIk8samz9orK5638orU8BXOuk/UUo/JPYYE2JKhifo9J1qkj73tFTmidvgwcZa2NqSMfzEa7LEp
# DATA mKq7nbSwJmETzka2re65WyU0Dn6+wwmoa563mhidNeTQDfbmb5TobQA241HtTItm7shpIfWDZcOwulBh44PfQYN8RlLrO0vcMjPi
# DATA Bvfguax9CN4FzpqK+gc1relqSlhggut9jsy2/GuylspCk1oi0L9oFs4Lr1it425kA1u3TUsFhTxF+j5K2S7IYegCsixUqu4kSF7U
# DATA +dZjc0XZNrEbjbVipiyHnWTW2laH1IOruKIDYJzhoTdZu7FCOPkAIa3kin6/f7ePI/MGe1U9sZI44aPa/epGcopZ04tD7Xow4iOA
# DATA S3oERJcngybcaVrTyfpK9+Nadvdwy9RBeTzCvqHVlPnNv8qYI/hJVUD6YSU+3Fo/rGiG9jwIHEaroQjMkKU3IBP4UAsXdEsPL8O8
# DATA rdxZW8su0mpuYoasRf5a5pOsCnSgADW4ZZ/bUN2GedYJqWYjzqNVRd+RI5h4K4t9na4RnWBTVVJtUNWKjYR5Zt6sXPCsJRL7YUdM
# DATA Aqsjlnky2RuIcdxSVB4rshHH3DDshMhLbgnzh7Re7uc2BO2VOzHpqh+QeYTJwaGg6wMh8UvaEPFm82FangL5kXogMXeXW1D/j1Ko
# DATA SiT/HUmuv5BRTK7ywd9HUkxClSTM2Vcm64zcUZimKTnOMtBISDGd4y7WMKYF41sgStqzooyf5LJFur89HnRBamZ1kHrSlHsOF15a
# DATA SkmQRT7o3mO6nvHWKOj6k/BesDUZ2IeVYAjE7uUt1fR5p5hJnzfWygJ7/g/KII7y/cSI/wI7rNyzHMjA7j0747O/QO+I1/KQ+/sL
# DATA axtRN1YvGhZWaXV4eIVZdX1OZZO3zj7+pxCn8yscN9PjffWSmgH9YDoZ+UBzkJmgIxJk1xpAF0D5oP+jvRlA+u30cc5WyIy6/n4w
# DATA GnugU/X8zgRg4oM+s7hyWugFhZgiJ8EF8sS8yOzUZCXYRPJNa0z9XGHf73VtVRr9INflbEZ+7nNzf6ef76QncQRvc84zcfXkQpg7
# DATA xBmpppnxVfW2+Lq0BiJyA62ZxbFEHqFDSk9lCKrR5/MYVNHEGWqST834IWpuV+SPYsF9vKIhjFbOex8/iCIhes/hvRuLthziteBk
# DATA 1GTPqp/nWrYP2aJ9zKsTVq3JNdcxP7Y2sEx+pxJFvkOY4QuzyaM2KL6YI29lp03c9y855iZhS5bFj2KBiHgmTDRYWfuiCjlIr7yU
# DATA H6mssmwXxVKect8izflSzHNQ+i1LhXMlvZ97ClpWwJEU2k/Yz3Oyq+leBbBF/vw9QTIadNsGOomn00tJnXpYznWmkwKjnsMOf4eA
# DATA 8sFvdQXyKd9SjsBre0K/VWVMR+tX9SjfpDsvw9y8tWL6HPtpkeRUrZK3xe6CrQnbMHpZPCsiOvpv7BHOj6hUlu+NmNqZ3xc61GDJ
# DATA Um0TJWoQvdokzc8VP2I54bJtNkVBwlhwLW1pnV/iiKCexsbc5nwTxpKImXnzg6WHJGrM7TKTpazhoM3air852Qh9f6Y1Y/+Y7fbq
# DATA O9hTkTfJL8n+OooTnG7kEp5vfCxNzTm6wSRIpBsYTDtY1WcyrNOU3ejAv9pCMuFjPXYI/cMdsnebPmYN1lHGXM7bAqKBDu884E7B
# DATA bXNiUv9CLf4zb33IptFDnabqpc2nL9LRKM3KGZ+8ZnEv4QTw0UvZpdXTBafo53oC9uqIns2cOvGfsydPdA/3lF7a6SpnBlOuRc23
# DATA 3GBdYTmxqI/28COBoF0LlvW0Z8eE7J5k0WpVLb4Zr288THQuX2OV8wOUQZ96bpdMzagcu5KjsOdzDvV8A8uqnro94SHqQtRO4uL5
# DATA e4xeB8Cg3/emKjij1S0L3XiWgBbodp2FQCc53PHjULIY5ZrduPkHpDDt4geV1D+R7/XTmI2cHXu+bR0WslaIOYVf4fy7+IskNh29
# DATA X0fBr773xuWtGzc3b14252HeuXyDV6wSoozRAw2rKhO1i4Ps84TrIcMj5ElxPt6VKEqcknx6O5TnQ2x/2uxRJbcvrWNh6rhMLxwD
# DATA MTp+CExCfePsDUb1vHFIEnJDnVVCRyb2Y1StNDKLOXxn74Oku07C+pmN3+Ae+F+94qDRaEQesell+5T29UCgHBR8b3AvHEzH3jvv
# DATA br51OedNx8JOgHzAvcDibO5PVOyPFssQkJRWiQI35300HUx870OaElDsPJB7fDh7FFDXTgM+Ah4ydBAotNrKi+VjGdNhdOZbnT0U
# DATA EZBLrDxOJ7wTX6PaP4vfaUcH453JnvTyHqBWpPwUDaaq2bwB4vtyKZ/N5NB2/f6WoDsirrylrPlVaVpOehkH71u7IXOxW6mcCvhD
# DATA CYT2Bqa0DhyoL1aIckuK5B/ssIJ4DxHhg86gMudUaRliFliiZi8EWBqP6Z4/akfxBOz9zg8JS1idD5uo5iy6L2V4/DOnYNgBn29l
# DATA d1ROij3Um7weW2mPyPn8TDJjElEizhOJwuN/mpNTmNjxVZ2t4ahiOG5ZcG0kh4VxGUJ4/BtgU/3m9v+Sgc9mZ8/HkksktIh6PZ59
# DATA JbvYCEKRRc0bSZ9ldIVyWOB48wmSrKbdw7IY9Jl03QyVuji39er3ePuzstRfWX3t/O2CfFz7uJSTw37y9DKN1umfkoz0KW9fZDdV
# DATA tpnS7dNzaytqaHy6pdqaekLlG8ZVRLpTks8ds3eSxawtu6Eo2zx2T8WTfjOsbwUgwklrsoGvMmY8krlk7a4io4H8+OEqI3PF0tIL
# DATA pJJwDupW8Y73slddu3W+mjDTUHCqV7Am5JeF7ft3lRUBN/shT2E13Oq8kWkZ4kZfSjRJNRy5H4t2IC9I3B6S4j+MxKAp9TtZTLEs
# DATA 5C9VYP+xnD+XiK+eWREg8zi+fOxf1M2kArcSD8SnYcYzmuomeau6vmk/kUu9IdpNSs5T6yYrZ4UJAOwaKkkWK1MBBNFv8dTO/n7y
# DATA LSpZcsEKiA4Fx/fcgYEX5UOYVM1YNRLv540/6prYTcZzTT6aXLjJnos65QiNtOuaGopkUUmIShlQazCWf5d61qQdoRv0NdMD1k3p
# DATA Jll5yKlZmvWmI+SlxLIb5Kz233MM8VM5m5mQT6kNnEfmPGFScgnBAerLLBmx5YcrN8S8Al5wfPHEfpS9b2WJSdIa2URyozHQOLs7
# DATA iqSGfd1bydVi/2YKpeumlnN6OdWf/4P6R7rAZL9+ywcL/5w6yfEDi6TP+O/fzr5QNs5R+3I45KyKW8I4onLTNzaimnPiXmrPW82I
# DATA 2El2zD8pMJp+6ruZ2NaMmzvb1DOpvvm/qUl/5sOVDw/+dPCPSnjr/tFHGjKjbn+Vcy1UgLIakDr9W56xn1FJj9Jm1DfmzItCZdmY
# DATA c2pMpdhfu6YODFoIr8pQqJR1/FmK4rBztbhe173S2pV5w++R/DrZd7vN8Ga3OWuFMU3vpHvln2MtnjMpMqPZj1nzcTIiX7DaMC9u
# DATA r1IsFgTnTex7rhOlsiNj5+oyUzfuZMISSDCSI/dlW/KplLRDYpb/3TqlmzSxdb98r+bZJ6k4Zkp06VCmiW1peH7Vdrkeaz5XLJfy
# DATA jsbBZST5XmNIx7U1s/vP9hlMMSRNF4BUdDfYH6/eelmVo15xx36kENyfIBS83P6yzuWzw++J3QvjSKP086l0s6U315dQHOnQcfZB
# DATA O1NTHff+WLZGOA1Vdv+QESbB/PMZuW6pypsMZS3ywbfOHRHbf14pkBxYifpG8yXJsZukk40ZKp/WsnSLSTWK59dG60Lulkc1VKgA
# DATA Qcd7Vecri53Ot0vQckEGvrQ4SrtfCoH5KDs/PKAG8XbuHi9jtWQO8oIUGFNZHiV719dOcIkyY6SxsZGMojl2plb2zI+vPnnp2umu
# DATA hGgFkA2FQy1RDvi8/oplnJ3WuiD5oVIxAQBXaAfBEB9UoMrKFIwMKmj2lZyW8uq0OKLDP91IXZyXijMnP+BznST/PW+rQbkzMoWH
# DATA s1LUZ39BMg4fF42OiB98plW7jZFgGYMZSTDZVpte/Bu6V25FC/wOtz0CrcheWur21KGY+AEU21T5zmxLzNP2MXN73lwJOp2AA4RU
# DATA +VUdOTxMXC3TIlPwojbNj/fgy9e6PWznmRzWuaMf+RYP5zWXkaMxtqZ60kC5HjtnnT6CJDelziDFykVbVzNO78cFuro9gQgQ6065
# DATA RWoXDqJdm4IaC2xqBnKUdsWewHnwAa5kHzbd2GAXZa7wPoLbwSGS7+RECiZbdNpJnVRTR26yQD0sLN/0utMCKz6/MnOpRgHN/xAG
# DATA KCZvYkQVhYU+UaoG4z/xYNwq3imMDFoRX8mXDH7ReX2PPRzWuxgNib79/+y9e3Nbx5Uvev7mp9i2k7MBGgAfkmUFCuyhJNrmxBJ5
# DATA SCqeDMVBgQRIIgIBBBuQxDA4ZTszZzKVVFIzNXXr1FSdyc29t+7fimMnipM4X0H6CveT3F6P7l792BsgJTs5M3FmROxXP1evXr0e
# DATA vzU+HhGat/79PcYkb3fxtppTQOQHYG4lozxGR7lWu413lEDWOeo+SKPWyWc/z125sNh/pKgfBNN/xFgtNT+fUxSo1lAltIKewkLB
# DATA JYIBaPAegml9iB6UP5Vnph+KieF52OMBhEgu/OW/UBsOhqX0YNLtQTYLNCIIm8/uSTdjFgI4IWBCGCBcHbg4IUK/cfGAx6PhoEcm
# DATA btgxtawgyhtBUtJOH+iD0IHZBgXg/n3VIsDN7EHwjiqwj9kHTPwYYAarDbEW9lDi7EM/zxcXYwGPvvRls0DAHiqOS3U+vBlQwhT0
# DATA ++nXvqZjkw2Jyl0mxnXl/mG0HdAoYZaSTQwLxpP8fqzNnI9DvUswV7IcdjKlz9y4WVSM004h1OEkFujWxb5bcAPqhZwcNjoMldec
# DATA K3frjTKG/IEqmMtwj3Be/jPbIczc5Y65MTmOkDvqNzfu7uyu3b213tz9ztY6TCtwM7VCkJERiu6AEO8PTzrtSa8zSqe+1pD+Kx0M
# DATA Br0ZpMdcmCRhZzw1f240krwiDA8q5zRAjLwaD9aNQk3qSixCWoVUlyb8srPZ8jiBHuElbrtGyLGxtU/IgPcbxKn7TImlTzk82PGe
# DATA Kt58CcUWl8XrSXojtI2EWlcneJTMZMaZ9pN8M6rxXzfWYNdFK+QHdZF+BmXKCHfxaLhntmyHiK3+TMiX8IWjLYMbc6vKZgueX8QE
# DATA z8/imDRoZv6cY/RnCNcFrHsW+5/ByOkodthr0VnMqbGQNagRNd9Jho7JWvlBbA29gkA4cbGleIw+cU4sGsxQRFGEtnlr2v0VzE0E
# DATA uOKGJvDf86kYjYN/0FIPWP4ImO+CFO9R/bk7jPUE+U1s85+6gRTu4RhPuRLL1MRPAaNraAeO0LzXIG14JZG60cYeHuZJ9VfeNw+t
# DATA CrEhXxDpnyJyt/BBRng7gEQPDI/yy1147Z56i2WD3Be3iNET0onVd+aU5S/5nC+2jHTvnTtt62ea3zHq9/q0an5fnVavmosr6sH1
# DATA b7QO9p07+vcK+cmZyuJshlA9CmE+w8CIJ8nF9ofPkP0/IceIfwQ8FO0KYOHTfxJESOzlTAAIwrZbMnTi3HhK1JMViN4x6v+67zeK
# DATA sgR5brLGiWnQTbdiAjrBCcr8Vh+TZg0VU1aVRWmawMGrrvUsOtpX3aFeQbN41cJb/LPi7tU71vMquhSm2hdrphYfNeEaStdAouBl
# DATA ENSRawkRQLx40Iz54ku3TUJ/vD7dpR/Xpn/LDvr3dWwzNgsOuR4AuMmIE+qzI+GsOizLD5j2o77iwV45d+Fbin8NqrcxrQGssm24
# DATA B4nkbukO2NEXsKMYfQY6gsUMOXW1H6iz8y9xe9DbB64r1r9aTOpqVQb4hFBCuTNsmw++MjLBURZRSLsDHwQQZhbn4yHn+og5DIIj
# DATA oSVJuPK8nRCYBCM4zbPMh1yb0xMvN1Lmj+C8A1a23C03rsUOTY7QyFnhQCXxJnVlP++TwFfaNTaYETkMACpZie3V4iqzcx9GAFjn
# DATA GaAvKIAGnbpYWPpcarYLzNbSSX1vkRpmua6SGRZtZ5nrol0pDL8UfutB9JFJgZpvSLDxEyEGEKwILmJGAI6LDaT9GTzLCHk6sIsk
# DATA m/nJ9g+DqvfgX3HegE9oHy6YAPYX+wRet0zCCUJEiHoT0H3aHectSTZ/NF2QoeJVfNklMU+sBZbhRVlog3MkcC0goPrccbNx0iFL
# DATA dRCtGQZ5UKOEpR9vWEs/Xc7PmmaZ9z8x3Iug5nKpw0HVsW7pOFCuQ/psG3qu/7hMuBO6jts3LHF5LMpEm+uYVyI2R/5BsY+pVGJ6
# DATA o1s4RZ4OtO71tNVXEng7AbWHSN7GTvtUCbguQkZx+KvdyKVreExyn9Nj8ELI5Jpq+EoJEJBB/SJObELQplsXwTD/Clcua9w1YBkL
# DATA 3a4t1m5QmjpzbK2CiZLr+SfoZUsYauRpXMAyi0eNVpU5n0ABoTOeEExi0nuQCFu63PluZt6W7Djb7juCry7lAt7pAJSMDvaMCwGH
# DATA OF+DN5tOYo2I2Zhp2hwdEXy2/yUZOCKA+Yrv4FqaxjifdgDQmPAdKL7ThECuJrEnHchV4mAXYFYXCr13kcbojwMz1rfw4VCHWRC6
# DATA Phc/hReDH7VHMje1hgLwuRgbY5oHkRQueXpnlgSr37Jy974FT9Ky+vxBm0E0nQmhw1GJxGz6AFQ+QpDt+iyUIAE68GU2OAgynYN1
# DATA BohE6kTlSiYuHw06Helu4fLU0ypdj/fzhKuQEOcLHf3PGjaaTzMUNsrK7RbSQ68DluLBoz7kWey3htnJYBwavyXmc/pw0Juc6u3G
# DATA ulONz4agYkoPuv02msuo0XWZXhAM/TRP9cTtGgttlwpdJ35rPwWJ8FK6uMT1tK277Mc44OJ7SJN1j0SlRo5+TF22EQ2D946JfpA6
# DATA dW8eRmNXcllwaYMm+qKacr8hMVxBuiqLLUtjktKVdyjUQDNSTDe6IH8nNHFyENLZ66Ae02ynfIczTs+xZ8a2sKWXvoHBSrPfmhUL
# DATA C1kWqZto31QngBMHlehiICy5yF8t7dwWp+2obznbKcm5/EvwHU+9Y/aFfOSpcUHERfQ0bKK6er2Sp4QJzqIzwc9AiRJ4Gj7/Kfgb
# DATA 6ZRfFgmEnohYObstM7Hl+bx7x//6hZAj5IEHITi/TG06xsqDMz1BL2l/JoIeJ6Y+ydQ+c3CWdFqjXhdzY3DW36yCvzuttihugDH5
# DATA QyV2tsYcZ98dYZZ59dUpROgoltkePHJRQWqhM7yr3V/6U+r2l2Zo9k2b/ywV+3PQnOkAq/btJHia/aWYXt8Fj5ABJKzod1dDTbtx
# DATA umXVI+AorhN6TJlWDxzsrSJOLiS2HA366sDc83H4YqTh6HX1h257bHn5LaLpD8tPiAEj1hK4Z3iBb6RaEIh02nvAMGXwGmC3SZu+
# DATA ULi+fuEgav+M7l2MKkz/Lh2Pwww9chxxBYYIfK/QMBe44esN0TVdBHdhDwnjveSr8rZ92RYQK/WrdO/n7R02Qc0A88M8XS0MdcVV
# DATA FkVj74h0vhCRS/lBLgXu+q6f1mduB3zZDxdS6VLACzmnvIf5X3Kd88X+hkAEs0Yl9TPoxILdjIppEReHDna7FBBjAQijZ5rT2tAC
# DATA rnPDy9Kp7v5WOyJ9QWKSh0iAtyzkiIOe6Jte+u3O44oR1jp9dRodtQzUz8z4oxis6FvJ9UUAE13MS1McxN/5CYl/SX1VN9w8IKjL
# DATA AH+pSLiRBiGsu61UTxjXr56E2IMM9Q2DAG8ifl09WR5cW16e5nbcC39QbdKnQoRD8oZEoiNVEjqWNgJLZjlikImCE1Y0zm8+Zp90
# DATA HcAp1xsvlCRPn5pMZ5/xj/gMzwVOi86kUlhs6q3DRvbS1iFSKiAQlZJIGw7mYA5bqktQStSEPa5acZtfInV0auRhbDifcYX2sx7T
# DATA iEJohXFE4l/TMHNfjlraitvrJvQp4zxuCfCaBHCSz/TBkWCdWiMwJGDyCYLFwkJFWTD6tWQdkZhhP1efZYiehSq1XpuxgYYQ+YCV
# DATA 8KaPprFxLY5XFYpEs8yEci3ERUWGInophyL/QOSLkxo6rRy8EWKmzW/oNOLOS1P0xM2nwleTcZTX8Y+iNif/lIMgLFdYvFh33QlG
# DATA 0Ooy7jJ6u3nRWEKykP7eqHQgf3C3W5z3tZvhAVXmezULSWiaGBxMC6RAzBIWzIQuzMx7+34YJMEiH+ILWdd6VVWNJPuaJk8tG/r6
# DATA 9BmfZQ6Uh+FJVCmLOfxOsMX/W5hq6Q+U4s0x57HPDY8/mjYdbCLPn4RT5s0QaX9qFCMiaTJf8A4wGD0g9B9Xn+eHKeSPZY2LACWc
# DATA DYWLKu34TUdjZxrALYDMjnGjqEgfRrnqKT7taS5acq7EVK3abS4HSgJu7JssJHyDTtulOceFNoMm7Zl+jGDFrxiWVkkPxlIyFEPo
# DATA p2xC7utoFem2QPQhD4Cyr4srzvrkDDFinDioHZ8lQks3e4gj2g4KUIhjm8yXFIf7mxN3oJeieSxhRuJqH62rCTvrZ6O0Zd0I5HOJ
# DATA EQPHkw9xPf9YeCAwkp6nsET1odNiqqGJGfsiWZejFX9G2mBIEvJjnXVZluMc3s8x5uq0xf7VUgwSXDuQA5kyydBDPLSu2Yrnb+3Z
# DATA exg8xLFL1hMTi25TLJF9h37vQf7cfa9g54hcV0uGythHqX88agmX6739aUEaobq7x8Phu7s1GJH/wlD9sJFsaEfc2txGrJ1V9V9a
# DATA dpxlsQDeCVUT+plaZ6cGSDO+JXIEhnmYNeB84nhJUaiGSWWXE+khxc0X2j8Z3epCu6DwoeEwE1fT4aUTj8FWXRCSKheFiplR6h06
# DATA SBw2IZaxmMEYxB4fiyEGD5MIlw7nG8ny7IGru8yvHI+WxFgz1iAxhUzzI1wL41pLMXZKcZIBucHtQFwuFcSnli8bwejx4kg0eNi6
# DATA 2BdF4eH+xF465D8aUPolBfyb0H0TzI8/qorRPj7zLqvkHTmSkf4CJyDEDLBQAYQeMH1x/IYv4rlEw+RFpDL9HBR1xpL3z8/+tZJw
# DATA sGpUM+nEyX0JMdhAo5jfEPR3Bm4kwcy+8UBme+RS26HFb46trxKWPmfgs1EGn6e4lB61Hnaqzvv2tvhSnFXV94bfYci0ywWLY6Pd
# DATA dxdyKEJL6xTDbGusX2LNzQSAuMAqL0gVWEzQNqKgQCR19A2jwVjJO5QbEhIg6yIoHbFIJL8nBTk8R/AD/mCaX/aekDmQFcKZG2QS
# DATA /jRfLinH1DQh/k9kTUTBBGZ6eu7FckWDhfJ1xBN4XfQp5839aIUywi1SOmitzETgiYys4U5K7nij9y/QQW1Jg4nTHSIHCZ7nivWX
# DATA MO3Rm7CecRZ4VMEx/RQaUvnLC479+eKiulVJFhdNCdMwBVXFWY5OxKH6uqTaOuwh1PuJ2ilIsoBfTaA3VyLNrDCq3wUr7QBWVknf
# DATA 0XbILHtECZooWjmrUaznSedx6cpq2Sa9RvEqFt/sfaFIfGtzZ/fd7fWd5tbazs4Hm9u3UcFPFVW8obMv39tZ3waFv9wUzcPbN91H
# DATA fileMPaR2E7rS0v6on6umzH9K8uk2wf1N65eWV3KL/2d7c27u831u7ebtzfvrG2Au3N6Mh4PM1U2kJqdkXRr7e76+/Y188Qvcufe
# DATA zebWvZvvb9yyLzuC1GTUy0rOrNqZh6W1d70Oh6n3Pti4rVq2dvP9ddW69XfW7r0PU6OkjEkn7Mid9d3tjVt2rFvt0y66e+gHMGPR
# DATA mYV83X5pH6zffG9z81tMEM331tduY7FRumCFvFqoEE/MxGwkZXeJEsGFQvKwNR53RnD6GaV/BwM/6tQQzqcDKx+gx0dpo7b4tdSV
# DATA 2zTOPn9ewVaABbN2x2Oj3Dz4ZHJg32cg9GY9CRiMLuyo1zrOGlhkQSIQLP/1BgJSqBJCdvU6PpLMAT7ReSHBYx54AQ1wJelPTg86
# DATA 2keOLvShmB+50RAIJKvhMnxsWbh+Nb0/ut8HnIxXL+R5hwAPRq9xAxxtGFaXdZ92h2U0XglhBcBW8INMidry67h6tc7AkUF1DqwN
# DATA NfgNxqusc+1q7eDaVTam6WHR8XOUl8VxiI6gaHPZuNM+KLvhRvxs7wELDOwr1brVGY23Oqewcr77aLw1OVB8+1sM7aVaIh7DpXoC
# DATA Vz7yCCr4RQbGkmNbKNkHlWT3bBhkaaRZkQMrk6ci2IvGqn9CyRQ5H7SOxH0CoTcAsfER2uU/xnR+T1k9iyFvT+MJIpgyj141gk3j
# DATA nOhter9vG9RIzxkBQ9H0q5qG4VDEIKh2L5pvs9L1pilqLhSxn58zeBU4eieTfvdxfelha7TU6x4smXPu0mjSX8J6a9kAvMCzXoKn
# DATA siZsx4PDQe+GUZJ0Rqh3T851zVN+lvWah2pWu0ewQXeSSC3jXrYEVrTDE9Xy2rBzGv2yCWs+5+vhqPtQPXa/1W3Mkt33dx6u1Fb5
# DATA 7xV6Bbah1WTQd7qAjDdLBkdHN1g9omh5aZKNlrKT1qhDg7F0Mj7lnrcm4wEa1O0nHaC2JgbzXV2+miypf2rig3Zb8fVWW03B31Rv
# DATA UWahKhBpdZP2KrV6sn73SC243qPWWRZ8tQ3wbaPOqLo1UEvnDBZd93DMRv7qo5NOv3o4GmQZ33GK6Q1IRkr+7r8nS49hAMCQtqSJ
# DATA AU8LvS5g7Z62HjcPBu0z8nFYvmGeH4+Gh00yZ3dPO5DE5srycuY9z5REWfQcZAn8paSAItLDJiLpUQGcj9V0Q/Xi/v1a6e1XHnV6
# DATA vSpmGFsqq94k7U7/DLyUbgSfQGeBQ5LBIvnaZNTFf5aShpoofF/9n1onvOqOlFhzUopZ+ipGMaxVnZrylRCpd5hGqrq/nFZo2TSM
# DATA 6gM3JFqq+LYvhOYoSr3bsF9BDStYAwq8/c64ibIJubNzTfYuMnaLZeB+Q/6E5pRZlDAI3UHBK/uuYllrt+9s3PXAFT8lgHgwABJb
# DATA /Vh6nX6KaC7C1yuGXGCsdIEbfhDjmWf4y9/ae4PjYzIJnqdtxT5QM5/CJlllSOh0MNRK+PNULYgqrAV46coyblBwC19Vt95ImdAg
# DATA OgET44COAxNuweNJXxFbVs3GA4Aego+5evWQfwUyImshoXJH92gcPVg11pY2jWlQzKTXPe2OqZz+gNt7nmaDI2jZyvLV62+8eU01
# DATA SLG3tr0xnU7nM1Wpk5cG4qOu82rQAEwagJK8CeyUatjv8n4ldiSE6coae0fpyuqbtWX1v5W63ijruKLin3GAUWOP1YBV4B2dMfEX
# DATA 4ChWO0juBeocomZ5SfViiW/klNzugI4naw76Dam9ah/gaKpduY3Hd5hsPs0Cw+6NT87SqaPYIq3k7I+m0WbQY4zzUe0YKwoDM1B6
# DATA 687t6s576+8j1tshILlVj7Id3OIUiwXm1wPmBEO3skRloPMPAoaqMYEWrCzjwZHZNhJ1Rjo5tcOguekaYQSN1Mm5M+oO2rQWMqmh
# DATA C3lKoDcDKXConhE+0l5qGIjIRSvgwiKkZY6o9ZXrtavppYmMdA8np7jJNdI3VlZPD1InsZsa492/hW7e270F82jpS7fQbl1CDV1Q
# DATA 3TwTODxudjPYY8+S6r3ka187d07606Tadm7evjkNJvPKrLlcXZ5KzzlFkzljTSuGF079G9VWb9jtA3ucd63lDQbUo/Yb8T2KYNDM
# DATA ajVTSwVxC/GKFKwAmEAHA7qr+O9p51TNc3WIohA966hlhIsK3wHpgtoF117T+A8KGP7risKRyb/55pv0CDgS/FrO7VD+1Fq7RFXJ
# DATA V1heNkd7AGv3BWdWmC8F21JvqSF12BIyMgHyFTIs/Ov4iYYiSj0flJqEnXzFTP6XMPJ6Bw8eBEryyKcNLQaAQj94DPaI68uV5OrV
# DATA K9Ncc9DP8fT+cTH+nDxFSlxGOENaXEaEz/lQHxQdmelp8t7u7tZOGrUiZHvSPBJYG/fj6zeco5B6SdJoEKSB+nZPyx5Ie7l2z3rM
# DATA 6BnZtgq4s/xec2qQ5o7IAdF5Hlt3MTEhmGGQGFaiyza+qV9ucy5e/WisgXUfqhZZTjvqgAvpq7xl2/5A25eQAfRbPd67Xy3XxieQ
# DATA iqzxFpvPwF17XBrVBg/eXq6vlMu1Q/RILZW9N9SjPP7lcJk3ZnGZldWIMLDqCgO8QwDvgSUOjqde7JwBGLQM0nJrI5C5zulwkCJn
# DATA XDxL1XPWCj3NWRX0tL5qdzN303938/b6zXvvQp9OJ71xF47J48NhYxmEACa69Ppy/TocvFLFOerq/8XPpUl7WCQFxIXWYHncglaS
# DATA ZxnoN+tLikaWsOlL5lF9NDBw+FUYz/oS/GvvkcaovhRm9BWVawfgc1EQegp7xfjew8Zl55xioay3VCI9jvVPmGbGAKjrqu3sonsT
# DATA +qaY2YtMOBnD9qywyG49YgFH4gGdl3A1zn2EUaIsGIQxtqGRwoZ1eZGTRd+GI/aSmlke03UfKwXEoeQGTRZR7Qmmh/G+UWfNzPlo
# DATA cLyUTYYwO2iBjzU5ZNrgDLYE46AFr1gzmOPlfH04GHWMa0fsc5hH9639uFSDRm+Ywxgd7bsulUbn4jINVpmK5+Xw0KLpdl+b+4Oe
# DATA ga4yy5+ScS+DtZq3tyNQBTnE5DEtfFpfqa1et3wrRpwLF+MypOCF9S3ZDGk64W6tvcQIHvgSMpxiznbJobloqbNXwAULfPTokS4w
# DATA pvKFNnrsU7AsOYGX5Y/Tl+HEatVks91YAz/WkDwiUckgpXmerphD1Cva92RFx8SIGysNIktJt3EBqrtiOfoFo4rBvGiMHznKKmKm
# DATA KTsnPT6jsXh8FjaX3GPrfFwADSCg24iWYiilQTWbU0XG3rdSLr03Auna9wAsNFxf6OAlY3rOQ7DvegJqYA/KmfseiM9FiygH+Jro
# DATA EECva/DP1VK5PC2HLfTDgTVnLTznlGP+H9I/GSZDrVvHT45C3yoEqVgBy8Dgka8qZ634oNcGrvrI85didJqKm4UBiitLUzynpHW8
# DATA U/FID5Jy9qg7VjI5uoIANf71B7tNx1cjRYy42xv0Cx0UpIsB/NaeA5AIxFZ5HiR8IDgofRW4YVRifhRw0/pzqSvH/cp1EgzdKlW3
# DATA yUHslQaMH1mFO2f5+Q3/p8GVffrsd+xAiWDtGEcAUO0Rf8nnP6MYLSiZnLoHk77MuX6oiG8ASYxKe6VTcgID8xp4f/HlDgFH2Ru3
# DATA 1WGt20cqFHe3P0g5JgURxdg9+g5Wx8C+Nh05tQIJp2laRD8s6fC1oBrwwlNnaXDA1ehXsHLQ2jHIakxr3B4AD7x1b2e3ub25iTOC
# DATA qmuz46nWCiSyJQo5UIVDl1LUMtmgRP2okhDpC2wDbI9Irsy9IcsQPQUXd9NPO732HmgMBg87Jf6Ain/NZpsan4w6HYvgUgUoLIQR
# DATA w42PazxtnSUHHTB9dtq1ZB0jSbULJxeIbwJCxLB10O11x2d0OKto7wx0jiQBSbEK1D8Bf8N4tvGAOUU308AvNkqM5uhFHeKjoWN6
# DATA qHVlnKXLZzSFcTJAk9B1zG4EW5Id+nKwLs2bYjZ1AeBoCFY+pD1798q+hnqDfSLiUup7KMuq9lb3Nf3E4enmLI/w3bTtj4pe8cSv
# DATA UQdynSEoFb1uV0BNP2uOB7SgdHCPDDmDzdT/sJs15/o2BN82flPcKphbTBnPN9DNM0Nn5FV8eCloQLc0NYVlLsu5vbIP1cRnYE9P
# DATA 1H44F+EqxitDt4KKiNEHfCDG3ilzBhmBMS1HhLFHsFvVMZmW7x3Wn4GQclMRK4SYw/Wt1nCt3eZft0eDIb406j5U4iyYRvedndjb
# DATA 963zNKQajpTlLSbFZ+RGoz2o68k5MG31tKxkLnWYRuKDoRuOOkfdx6rkNbXhc8RLC8MTS1780ntKzAsYjXHUV3uN60oNkwCtoQ2H
# DATA 2wV/7GaDV2Kribi76x4zn9QFNUzxyQ+UZGEVFdP5OYGsAocyv47qhesw6K4zx05RqODk+S9GoyZD+cQWYBOHQYB4fJXBCQ7LTXOO
# DATA p3U8woKSlU+qaUSFAg6zQtUSfTFUliD8h7iuLJhMLADcaxGEY0F8PoDw/I4YGrZQP3dRC20xfjlFmIVuSDSAkKl5+QJFxY/mRTA0
# DATA DpYGixe1gaULRhGW5w+dl4GA+RBJM/tLaNciOtAEwH6q8yF98fwfUGb+g0lygTc/whQLP3NYK3qzNRJ5vC+l8T0HyFse4GonnccO
# DATA CvR5YUjrDK0ENITvw8+yxEXVQa1HBu62Yph0Dt5t4O6MUA0kytFe58pM3rRLmd5i/2JEDTyJHBIEFK842eW8jen3QKu0lLqgfbqV
# DATA 9Viy+NPW45J+oQLHnQbvO1hLHeUK2sadyvbLZXN8qSTC2yvC4P7NXTUB1Qhqc3L2IYR9zJ9LPfrYPaYxem9xfJuR9MjbEmc7QL4J
# DATA 0vi9KLAwXTjAwvRDqCpcjF5bsClIE6gtQxQ9dRMOqbIUDz7sgfPjXY3lu9sabfSPBoBAhcA3fK05r2LYzQM1y+oM1DztjFtglyll
# DATA nd5RRWeJK8tsc2NEFVQNaY1VM/gN1bqmWeOmFMJTUqOyDLQJRdbADcZRM+mbgCcJEFeLq0j4WA2kfkgW9f3YBgp95CMdtyTRlaOr
# DATA NqQWhtNg1jrqJOilJpTj/EUtt+WYW001ZMEOFFg6m0O1bvIGCDsUjqd+0U9ChZYRxfpsweZNr9Lj/gTg1L+cinXheZVnSuAHIOSc
# DATA utnbHV9iCA3CYBpDPUPUleCR3k7Xafd4xJyOpQZU0YKHpU09wDWBHaTTOq2YpQCz08TpbKwaArnCudn4wcqy+s+mRLkJA5OQgzOp
# DATA GnqDY4S0RGJhvGUAAEKQp746uwPhoG8uYPw8hEarZnRMShQX511yIb1IDnEzaCTLdPRX/DvRa3CgVnkJfg0OvtvQ3SMDy+gHhM3e
# DATA VWu04S9idQ7L9AR4p/UO+p/AkcN/TDwO2vJ6I1nxcERHqEeiAzAWQThRdMQLw0OhlLfkQMNyDb9WQlnrQIltk3GHJLO0VksJJms0
# DATA zvK2i3t9XKj9cFUjjpYJS8RmpOXonkat6GYkE+KRQN5mEBczYOoWE3e5oFWGiPsxhgPlhK3h8pG5fTNZFlUyv7NUrA4oSDN5LRBs
# DATA LuBqZiEl6DvsNqNtt21gZiROfHfQ7SME6iLpCmLDKD70lRVM6XO0VY8QRYEpDqBIrS1lnJwh48mLgqWJIYwHeuo56zweUmCrFUV1
# DATA oJLLibiVaTniu2MH4fQBtAlX6PLgzeVlcIaHIOKsQXYOxDJsDh6Q9/t8h1jiE2pNik7lTZ9O0/AC7YDt9mQy7vZq7W72oDnJ1LFN
# DATA z2btCNSl33Qo9PXk2tW87deO9IZaHUdH3UOI6QAIswfIZJWYdYpsyV/Qku9HVXF6V+btANcrtSrsDX3Tzbxk1jMJ8pCCYuDLU7X+
# DATA wQfSLfw1QI/rTTJ8WTFnXEAMEKhoeEImJb32BUig3kDIPOZiUAL/pyZXnJnFvSB9fJAicx9MxsPJuF5IjIcnigBKOP9iTRhgzJWV
# DATA FdIcIu5mSIykp6azSx7pYYtPAKrLvB1fbwc9CNsSytFWu3TaBYUkf1ZJrr3xxpVrkaB6wW+wlHquGTB3Jh+pERuPJn2YjXYar4JG
# DATA tMYYoFBR/D07LFWC5c95l8s7UvRxEkFLHGS1o+ysf1jS76lB7A9KLtoR7mDGmjg8i0k9Ql2iycbhveo3uQWQogDdsUA5ab5DNwNE
# DATA G6SFAufDGroIsvsA++2RkVg78W0hPULhYClqq1405NONrXW83xmN/Pss/XRPMRwGLDAt0KLWduFOaQU8YPXrD7q9nni91m51KKYF
# DATA 2Ja4j0dfHXsJUW8yp70ThTr20TUL5EndCupeJThC+giSsC6BBCcjj8voJvHDBQ+HwnS1JOHIZd21wx4AUYos5t3WcX+glvoh5lSz
# DATA L6uqaHFhOjwfo7ZCTcmU+Ei5/9JojVCIX6PxH9HvPWp1xyX2y2ysCv7BvBJ83G4NJr02I+YpEQtFZWAWKOPJPiBaCvNp54k8BdIw
# DATA +nntUW6jKmOxubdkWgWK0U1vtfp46FCbTu8MF5bYe27YrA92iWg8XMiLTniyUFJ4WjKEfkvnJdqiG7xSTELrtCJ7qbEJVaU9SaxI
# DATA 3IcQ4ixpg1wRsZrhAKgmvrflUJZ8FMwhsRqdRElqZymDpOKhcjmrywoxJnypkcOjbJjfnKnZXkvWEg5R02Rx2nqgzou0YUJsHJhW
# DATA eyS6HahxA2dgJIfvTZS4BIDJne4QrMVc3uHgpIPgM7pvtUQnL0oedDrDzM33YWeesIIVGx5MAAiINutuPxtqYBo1BiXJXPlZKtKF
# DATA snJyH6Br0S2bhDAl7qoed5q0A/BNwArQP73FZRvlxNCbxjCzKIsUE55+caOdlp1UkbplcOzw3t3x80ZvT/p9lIEiqOqUdOPThNPn
# DATA fsaZjQFVPKbN+8JRi3O2BgkIiUjqpPP7YV4Q5syEm6xkFi+jttfml4TLILEa3ozmU5NYrZdOp4bFe6aei6VF8sb4SZG+VKjbI2cC
# DATA cwoQvhfz5K5z5Yyk4eVBq8zMacdrutA4bzXbMPiskM2xIlN5+3mZZnLymCO04U/mGD6rxwkGUWRTgWFqM2akYJrOOgtkNFcLDyXU
# DATA iA/Ctl33Thu3iclk9sjcb1NOInWiggPFpAuQ8IoPJq2DDLhdr3PcwtB8DdRiC7PkjBsaiVZLEG0Gm6n6iac0FlmyWnIXINST7BGa
# DATA rpFb9hBbpeaftwp2fWOGwo6SpIGxUA49OI9zbQb/i0CdP6V1QUZ9aYN6Gp1cnb+BIE4o09ev8UEUWY+w8pyUuZImoho8H/J9T+sj
# DATA F5mGRse9wUEpXUzLHsWCLo/zBNV6lMoghhQfsCwYN5MLzFg53eRg5aKBZKuKxhqBDDtPMCEwZ/h9+uyPBowYbH+fhOP6NLZoClSK
# DATA RqsBnTY5LHISyy/naRhRfStNAULRm9vhX+SShKaIT57/+PmPYAggSi5m50UaQ6JA30CXIXsDgB3yzuLBZOlRKDydH1Kyvz6kbyjF
# DATA eGwB90ZsOodNo1fELPN9WSIA4sCPOEcN/jIZFCn9VSRXh5PEKPaNs2ZIpoOzFCwcfI19akkGAeVKdzDJ0rJze0Q5286CFYWiIcOK
# DATA 6pKlAZ2ex3XE9GxOTxN6GdMBACIkXnGTIWcKWl5dpV33mNPbiHcpNUnkbW6SnxNIixbXrk7xQAFFFi/0aFIf5nuIGQqGVA0GrNjr
# DATA 78lJCpOuMWPVubfU6vkUboVNdQYDiAxiGDD2f0k9Wno8ap0xKK6eFOo+5oEhENuDSb/dA0SJuR19ZKWvzKZsBH2jEcsdsH/xev2Z
# DATA 7jMlHmNp9akGXaUsZXIT4rzhnKvMEeMwX5mXc8BPbRdJQf4F7UcYpIsAXZwby29gnH70AmRKEWxWLQonf6vzHkm/hUMV2Y0ZhPYT
# DATA 3SFvg5apNX9JWcDUA2avIlGbprEF4/eXmazDKYSgiIwtawmq25QYhgKHOhZ3pd4ZHO+S4eARHOsGWQYJ3TCdRmtEVod+55EojM4A
# DATA woUoQZCw7AQlmkcngDerT5PaMtjqnyWsWsEMqEJhQ6V0KfuAwO4ByVbJBrh/O3IDCu1WVgi2DeHCIT9jn3NRoeO0gRh15LSBP9kT
# DATA FFQTkHan04h4arQ7FPqASiw1/Kj648wnWW2zuX178+7730l+QFdaMDc37m6+s/n++5sfuCQ5jvFWoxW1VbpfBToS8SWprOSXpM5A
# DATA lW5THeTV4bjEewpDudeDg+ILObvnpNkNU+3535y2GN843dYFJ//fh/+KcobO9yChmhOZFFOjDepIUNTUdrTwSNuqgS/PdwGrEWRj
# DATA yfPv1uKEj2bbZHCiPR8Tj1AQ6VAotsCyh44LjysYXchCHtzwmRZR60IsEZEeXMqnmxvrn9VabQqRpAViF5GwPHtZPSEfiM0O5uY+
# DATA tXG1lnvWF/JrjX3JuE/qSIjMgCZfURbmrvk9zjb60D3/WKcBQvpx02U9+z8LUrLY9EEyoZgXZobROXik1Ij+AJq+uJcm+HXAkGQz
# DATA TLLl/Vipajt4Yjan35LfI8CRf6jTLKNfVnFlxMbMgJb3nQws5r4dexrP18HUkchABjiueKlAfx8ml/3sBiFlUNrnn/BGBPOlD4Fe
# DATA 3hXGWq+xkUTUDiOAH+IK/gj7/WPITyJ2tlry7F8JeQx3SfXW7zHfwoekz9FYHk9y8r0oBp4l1V4rhIclx80/6qzNqnKdIqaGAMYm
# DATA 8+FHTvIUDHVC4A92iP8EyYlSs2h3u2dPa2GFKdGizIPI32AeRC4UhhYp1FImq3QMukIITvvs/8DcSuCFCjlwXG9azACjigwLpNjy
# DATA sDRo5GdElr5nriLOsJxR51idZuB4EO80rVYoQh0d68lhO7ro1M2EtMMaOD8ZYsQAmhKZ18PSmmQ6iw8GcMYX/n4kMsGCM1QiQCYG
# DATA v6KqgZNr48djk9yAwq0rOjK6QsHMFR7FCp/V4AfEJLtRDC5zc5NCu0wbV4eEp0ejY2S8dDll41o2JKGL5Q22yc/Kj1nK1ZPYNI7x
# DATA LIiOGy0yZl91olO5/QJytlFqFBLAcYG/s/H++g6McCDsipRuYepJYfzwM+bpLpMtlkfD3VZMpTBPShxA550SDnqZ8Yh5L0OE0OI9
# DATA 5/mPK8B1/sHmpnuaOPniY4w8TS1lWhpG8qQoZA094xh8Dgm2PFhw4A5uS1Ed8HUFGNsEX4sjjDYG2gdm8j3DIFbTGaG2FvUS9Il3
# DATA ZMKhel3nKNMtoVm0RThiXV6Eslrr6OP8IeI1uQnNNVGgMJNTbtmd5HJePbid6r08cRH0DTK3rcMEEdj9nMJJ9305bHbr8mWicEBh
# DATA OP7dpSLY0uYeCcY18bRsmIvD75xkh3dynIqQgxx3ZrX4F7Q9I83/jwjsVp0FmePOXDRRTBcC38sbmKCCeYnDJ5CgigitUGWexGdX
# DATA Oq9gK64Fe+dSEDevtuYaH2p5VZf36ldW3Z1l5hoOtEA8/9HlzBNMFDHp63DfdjqrUEEAQT8uMN3z0Ht8WonSY2XOtdRtr3MXueii
# DATA gLpaQtlVynB/JA2Wv1f8MCFN1IeoncKuJfjRZyIPeCA+6Vq+GZb41hLZrBjmqbq4xGI00CkI0p5smZN7vALaKKO7o68ACl0ksvws
# DATA qpULGwuCEI/Hr+eQRwmdjKlfH+KLBM+0YiLkzbA/oUqctLAmqspBKA7F3F+IA8dnfIL5RLUNEy0m0HFKW85HCDyJ2FHiA6E20esE
# DATA isbm42nvlJigQ2mf/4M+C7FpHdWGRk4RmQBYhtG8Ii69UHZwI72QKgfhkXjVoj/2CH1Bj/F3bW10PIGqtvCJ0QSpFdtoNpUM3myW
# DATA xZdwRG+2+JNSOhh2RjpM6vBkAHoRQFflbLuc9YvyDSKAC0g1VRaw0dwvf5sEYhgZkDJmTmuk8eUwtwH8PiaEOeJYKaIfZydVzjpO
# DATA SbG7R2fihsOHAKcluMn4lsF9bh9AOXXHGkWHKsd8x/KWhsOrMmgB9rjX6gvHBiyf1Z/ebe0tJd0gRuxtY0qiAYSKqtwAOTY5j7nx
# DATA 8Ye6H/TU6Tui6ZvZsTANeNBBxaD2UIjSRrXKRrPyjbwX2AaX/4L2Cyqsxp70JBF6EnR+HX6a3ZzXTFbm/MZSsrLc5zTV+c8jyWhz
# DATA 3sRscAUljdjrCEIvR8dZA1ThhX1TtFXUMErqZWcj902hQTKzX1SxXSkcDNhIZ7QUyVR9VtUpfFpoC2uklH4c0/8UV4lAX4MXKoO4
# DATA hdvq3DFh6GHzKgKgF6+bCLuac3ycT4kg52ulK6oFTV5Znrk6kHfb9WfSRKKOgbGQTYn0dPZEXWikAa86/ylYauw5hj28+V38A29n
# DATA NhQermpmg0MDK3O9uqty0FYSFKPxK8poX0nEHYopFRmVI8X7fLbuhdFqUV2W6KMqUnJdP+bWb9qeg/8mjq6dfuugh2d8yBg0HzAG
# DATA wm9YDAg15Wvvv+8CZjh2EA0gjxI16picx0OL/4FOusZtXc4LIGfBkFF7U6PH4PZHYWWdmGOnEQa6zPYiJxUkfNYGRAxEv4feFfWy
# DATA TZAmHJg+32iChTYGqm81XGL6jU3OdZ03k+iMHevgzhRFUOpCeovw9fqDtJg4pYxlh5duNOFhh/y1axYqoLA8XzK6ELEzikEeGgZv
# DATA VE0lFdD3fKNcSWJNnHNoxSvaOw0aUNzNmLQnHH0iTuMXZBqFcqM4P/Br0tNcv+Z2+yKT6MnFcg7hQZMfCNbD5ccr42vm1BWz1Isb
# DATA 4YviUllKO7rTjIvQZ0Rm9mlfm1TzCEuSKiXXwCh4Li6cbWfXkPsIV2c8wRhEh9RBFU8Na+nffmZ91d1PqfcRdHnbEBQ4y5GFxaJh
# DATA 0y4w+5EQBpsOKQfOnkVdqySzeuC5r5ELX7c/nIwd1Ac0qNetLQGOYuQ6VnfcePDhNLrsKZ7DLvoCroAezAKxO4/Mis5utl/6rbko
# DATA aK4lW1gdr975yFVQ6lzLNPekGa5baoCDaYqvimbgZFTEEuR2zTBXqeJKMwbK1SKIucD7Tbp/IZZi9CL1IurRb5Vm7WICRTjKRnXK
# DATA cSDuGX0NVBfFLeS3m/x2UUtDHoIX/OWMZlnlkS8dYNJgRBHRr8RI86IjyJDxfpuN1ImXJDCVDOUHaL6FvMEXKhxXX7GUbsRBdkEw
# DATA Vx2/EfcrAZnUKMdFtRL4cD8q8gin4RnbolHhFZKIzd9ctDKNPEY40XRBGKDh2MJBeAa9hAfnui/9GlVpiN0cr9JpYvkiDdA6xTnb
# DATA oFPsvOxmzJwrp66ZU2aY5xxn2ZlVm8y++R6EFL1EqbfRx1uQyTxtYNBwOwezBLbuKSYWys5sHK36XSPniL4SoselZQH020T+2myK
# DATA NcaRcOWgTJK9u2PnPFsaLhEWfoHlTjijz4OgB0GEmOOWshSFMSamITofIV6UhhWdTcEhNvOZbSqFdLmIGDfEcxO68cYbPjtU7zhO
# DATA NE5m3LDevMklI0G4L2iGSqk/59ooDai/3AQKGRMh0PNWJpDuk8LFG8nmFHkgq3GT8VVQxWEr7Q/ss7IPWP8iO4NbxDoAA21ByByB
# DATA 3s8oZo7d78bl9h5tDnIE1QAtPtj05xYHtFLJqIarCF/txPtrNybjBIieP5wUDDx9nhbD5AaYj2ZdzjohpPVAC8bpUGKLNnhX5k9x
# DATA PogmTtFfATHWKXmb5brhW7SA6m4qV/moHNPg1ZPuUI3wCKLiu0MjTerHFc6OLCNt8wYJ0fsWfG/qQO2pi3aAHIV/Nae2B1TuEIo7
# DATA z6/a39TV+nhI2s+HcLolX2uBgOFkNrIlCJ/s/CMUWjzrM6XHhZxcEloHXvcULSmZCuqCA07DKWOzkkSTqMfyQvB7a4HkKgqZLYUu
# DATA LKh6m0hKzSZ2v9kEIm02eQCcYAgycstE8iGIBWCNIAZFvWiz12v835//SC3eX5JDcY7HxEz3WqxO8RdMNgViBAXoCogQBNzYOcvG
# DATA ndN1yvEmO1H6NlAFtr6SfKtzxr8gJwL/3NzhH4hu8Nc7m3dvI3wJ3i3LQJ8NVIkgMn+3f9ibtDV6FMLtZ/Wkj9HK2H91BP8ugTVQ
# DATA gAPGOk16vQQqqH3Jw1dLnv3chkE9/wlBHXDoufHGrrjoBz+mMDLBl8kx281J8fzHgNJzodn4L3/578/4P8UsDnogAChuUBuefSl1
# DATA QLz0tatX8a/6z/+7fO3KFfMb76+sLK9c/S/J8lcxABPwvVbV/yed/1dffRX4gWLyZDTVUWEYhaVTlJDOrgtwcqNOr9PKAACHgg9X
# DATA aqu1b6zWFhZ2T8C9U774vYk6JyTjE7XdIdAYxw4gPGT3GDKenHR6QwxROAEuCBB26ulgcnyygC8pmaLd6gHm0u6trSrhax51WoBf
# DATA gwZLCJ+0beSMyslJ62FHta4DTsdgH2zXVNs6I4zMbCvJ4AAkAsBg6g+M0fdQ7nUI5vm4czihmHDAVALBmPDtFgBjddbOGrDBdHdW
# DATA f07U3iobnX5FjNMJ3Tj8bvYnWP9vXntjxV//q8tX/rL+v4r/0knW4XNCemNhQS2EbJycJ1ujbnbautXr4qmfrpIp+rrjsi6lfzXE
# DATA m0uH+E5avsHffvfRWL4GUtWjzgFZKMqmhp1bm1uYI2IT8xEhxuf3O6U9yu+Q4cqpa6Ro36swqwMcmJKxdVpWTgsRuEvz86zOHo/5
# DATA L8CJRRWzDy08mvQJtGHUmWSwO5ZGg0dlzmahU68NHiX/9b/Cnxon+3DCaGVF6BCdqretGgg+6zweqgFaG+OnfRANf/CDxHnwFiZi
# DATA uw0nj3I5+D47VGebrKb46jEiHjR4TPWdH/zAOVrM9c3ryYruFb/Kgm7mBjXgeJbdRnFJIAKflfDrpPFWtCi8LquRni4stCDwOjEj
# DATA rk67D7twpCoRdVUwC4POaKXnAJR+ryz93d5y9Rut6tH++fVp1fy+Oq1eNRdX1IPr32gd7Dt39O+V1enXlmqQqxqT9cH4Q6oCMXCA
# DATA oD840vm0XkHV8BhSEqTwMt3WY/fN5MpqGZAlFWXAvDHs30Yf9Q96n6INRn3XVoum24LkGjc0zpqiG6KlYkqS72vfMDgcAq5eQsNW
# DATA aw27mI8wqwEa0r1+93sTdXxNHsE+WFfLG/s7TaZc+dJSst3JJqpuzBeTtHDDruLRUqMxVbQLBFSHNHqGmzCgD3QxWEy1sNWDkP7B
# DATA Ie+jR8moe3wyzmpm2kyDFZm9YtaXvlvWM4yD7w8lu1slyEuSw5NW/7jTvqGNnSgNKPoZ07FLxuKSQyh1lbJr9NR0QukNO4JqQnOG
# DATA EFF2Yfgwv7RoIdEmzFkl0au2bhct/FPrDx6VwKF8ZTlZTK5ce0P9e/3aVdznAE4Gl0Y92avVarSAOJbDmZtdEKEGvXZyPGqp7tAx
# DATA 83AwUj0fDgBTH9K5Af7WBPKijxH/t21wumpqbkGk0KUNKA9dC6indWjguhCT1JlkkMG6SKdjmmrsI4tBsQnVv+diHmIcaSZyRl/r
# DATA Xoh2z2HMpxWciXMePTF406kzzcys1ZZUA4mzdM5Tpva8EeVkB8YLcBg9iGdZ29oQoQ3dlprMO2C1OOoNBiNkoEQK7TXMcwLYsZhr
# DATA cAUn03yompPD4d9OzgHrrAW69DqAA3emiSIo9WJQk/44rGhaTqYV4bYITKii1nSrdzxQC/bkVPXkvR3wy0AaKmCy7wxGG8SWouwW
# DATA wCL7bdSdSs4b3NQL6rDX6p5mNyTsrWoW3QX0SDULZPu3Rdiqzk3zYTlwB/ZVB9RSOAToIVXU0mKylrS7R0eEqonafURPVCzngaJ4
# DATA y1YhCUim2BisRU3CtWRxKZk6liNumyJd+oUGatrLgRbgAW8B/Bz5ZkPuA2IHxPX1MnclUamzXiz/L1w5kvVrzg9l1WVvzIqR4+II
# DATA PmWTwiXYnEU5Zo+2pU3DlThjf0dqpQag+FijTFWYiqg9UVOjmLSGgW2Njh9Smr8GoEbr8aFxodIBgkutGyWGnLtEGRnJAUmWgOGM
# DATA 6Y9LJPO+XaOivk2a3rdrJO6+XcuGPTjX1VJAPk3efhsSybzVSN6ENR6ouJUUOxxDqjygx5KRjRHUpTUcLqEJgbqYLWnBmj+qDo/T
# DATA co1as3VcLp1HIy1VJ/qEarWDhFk346Q2wppMj1uB3Er1ZLUyo5xdAoK90+0p2biuWE9zGeA7u+1ex3t0hR4F5U2BK1EOb+q5qr2U
# DATA 16xyLesAwuRWa9RSJEVxtJT/uwzDm2IA1yHwNLcm4KCQWEZRu5IGIvHtWLU8z5R4riWpah7jogX5EshtdtxRAk8X2Ez3+yTogIgE
# DATA ogixt8TJRhwuiHKJ7xUxYjlO1pi/c+/mzq3tja3djc27zd3Nb63fbd67t3HbfR0SLJPBvxIAbRcUt71+TzUZC7UK3RpIFCWSuNQ6
# DATA 8hDCyfZATzlmTnyKQ6oXIC4zxV1rHRrKPCjNZ7+BWwjcBbZ4E/z8jwLuAA2En2NCPBtOHIRGx7Xg//zsX9HGGAcF84EsahgPocfu
# DATA cXd8CxT+jWRFbUuipwwQxX1lRvw1dETD5VSi0w6tcNjaB5Ta5tySQCVGDRV9Tp7eWPgK9D9Nu/pfqiq4WP+z8sa1q77+98rqm3/R
# DATA /3xV+t8tlKPs3GtvWcwuAGpWtW7xRBGoT5xTVqetTmCYgoqtWsApr13VV6AI0r8H2QLi/4JPUK97oM1g4BWhXxl19C8wZ5rfBgZe
# DATA 3xl3TodwvqMCJyO1JR1QOJIuFRxIYLNeMEVT1lGO7iXXLPSKRc9l0uAetedBndMgc/b67s33N299q2yzagG4XJtSarUhXJRTqVBe
# DATA LWFHJRRehKIDDF567iXoEFBU8FJtp7mxs73+bkniuDrArjp7HaRliOUpsMbRUrpx99tr72/c5l0FwqNd6BMPAZEQb3RFIBYzkPL5
# DATA Mg6V2sA76m6pPI0izS6/+WZ5VotsS5p3YLe6ud7c2t749truugOHjFsTD6hNQ/GGn4bCON4tOA7hNPP4r5MFBe8wiURfdtILCBcI
# DATA fIquFzgVPfNBOBEzJkHjqBO51gI3Q260JmPyHyJkR332Nz47uc21b+oWUxgYY3xzD/Q1dGJ1+ep1TJt2/z6m1JDvQtDbYNQuHZZB
# DATA H3YFbvGlktJXVt+kaC/5VXme4dhau7v+PklTC5Slm7Lai4QrGJDFDYETQWsyHkQcPfRgEmSHjxuCJ0of9kdmQODRLJ0vLrKzhY4S
# DATA xMgI9N5wIgOnwcq1xfFYXyIFQny0FOdZe1+P1d21b69tvL9201nGPG4ZBTnKWjnR+E5nPObk4qZ+fmTSAPulGXBoZA8SJcxUp1Ni
# DATA M4soYU5nRP4YddsYYpv21UQq6VEiP2MdpBD1W9s67ZAzK0CWw6qG7LL+SOv2xTInpHtr1b9tVb8PSMb2Z7NW3Vf8SxHqNCXF3oUG
# DATA /e767geb29/KGXxLnkl6Mh4P60tLOou2zYYESHBMoug0pi+kg54ZDJ4gkPe3NrfRvZeCo43rp/SUEvWbn4Ccj+2Q65gCGqGJGbdR
# DATA P8Ky1H6qitC7qmUNehmqJzU8ucn5VoUh0AQUmho2A68CKeAYqHtwrXVz+loDyOnr7006lA0DLo5GrWMUPszLass1tSJwKtWGD2Hz
# DATA V7xh+TIsx+3YKw3dFxM5y9RWVPZ7u7tbO1zy9vp/u7exvX47dXYdo7MdWbKu6KIVp9/a3ry5DmxMiVmkt9BpQ9VhYm0yPhmM+Exa
# DATA T9Kb6kCt2AwiBvnHvw/Wvr3eXNvaoJ1GHS/QkTr6lhkJRqn7AFDqDAWTYopbsZf+TVWdXh61Ru1OG36h21qq1lNtWf1vJb0Rf3Nr
# DATA NFDcej8xowqnJU9rCaSOAhrUR31vHeCM4gl9DX7fIkSbHkQHV0y2r4w0qBBiTgc0/K6G/8J710Grqk7kWjXEqjVUrmcdo1876gDj
# DATA mDFGjCqq2Cd3FDCOyV+6nuLRVxEl6KJbvTo1gy5IC4eGLV1xbfBA25OYfih2pHUIDSC9AqhdQchrLAN0wKT/IGvs7cMDYMPU7BJ1
# DATA B5+iRUYXfzBon6nBhM9fb+BjNmXd6B6V4O5bVxcxqwH8Uz53Bu1GpF26YNWyKbWlNoQ0dDcnoLCtgXxewvvqMDw1w4zucQ30iqNc
# DATA p/y6enqo5GAqqFwbD0ivhdKcEubscJGv6g9+oDW1eP1Ko5EO0LKMljp6qWam1HvbPBCfRYdedHHBrFm3CPVgqgGjk/PDnlqDmviQ
# DATA HqHv04USEnep3HjLELM2djdo2pCzL7WG3SUyhi8ZY3j5hup4iduv72pXVOgBq6bLkQ4YDIcbulo2gIe15pnKxbeq+KyxNhq1zmrd
# DATA DP9yBHlWflsb1vlvjf+qb1XjX3E/gnLKsebKKtVn8N7e8v7bpBGfu8VL6esYwti5t71xS4cy6MJYu64YTrlUNiorNS++vkroksgn
# DATA UwBiGQjbJ4BYZbRT8NYfyPWSMIk/pbtRzRRuDhXIJY8oWADDT7k9SBdmK0CwXgkLaDPUW92XGjJfbdVYuQFcBv2X8MigXjjolDiO
# DATA wp4D+ADDm47iKxSiXNEOViwS5Z+gwkMG1yFPGHiraLPcWnt3vblxB/4N5SlKWM1H/9puBw72rdHZbR2YUiJQCEg5qLNjIUVgl6t0
# DATA BD8a9BSDdmC0dWgTPSpzyLRWiUE0lm0wC2akAkWU4zSyHzSk+EQ60sj+i285atSYyF7imXCSiVxGcA9Q8NEWFik8/yxCx39fyuaf
# DATA QvSnF7lsmw8ulmEDictmtdtH6JvOISYFhUi4KqMNo1t4/2HZUOYeFLmvkargdfgXRSUP1yOIHMCawXGxj2KE6Ik60KiJHZVMR+xp
# DATA pTxf4xnSuFol7LZqdahOH3jU6TC2m8Rvolbkw2jmjQHeVxOKBJbaQeAlFx0L7RtvXN+lk7zItLhjfvrO8HlLFqh+7dat9Z2d5jtq
# DATA xYJ4S5m+8JxObAf0hBZpBAH585gP16hY1jbttep7xY87bZP2Xo8JaR9vJNlJa0TeHwllJVAc6ExkUgTuJxzvKS8LnCAWbL61OAQQ
# DATA 5zFyIX/YuV8J37HFn9ZFz9LIulcvYIenCzrBAJRlGwUsB5PLZCUdAUbNkJCd+C33m2CHNC5EtKDB+AQwmHPKcdOs8Fm+kuBHNpOD
# DATA HJgalAQQ2PqQ/4pJzafHygGrwFYwcBVBe5ynOFVqMM6n0wWTDhw6VPdS4e2l4iCMB4bzxUXNinW8vjwrc/YznT/CfAqahsVFmr5p
# DATA 5LAshk77BrsFE5TFeYoOU6rpmqBT6Lu6hj/TShKQTYVpxm6V/rlR3ZOt5udNylM0ewmq/VLrIe5A6O+9uzv3tkA9YM6aoSYIknNI
# DATA cCf9lFi/+Qjj+2LKnopFf9WfSrIIA8QoAwdsDSQ9U09Bq4OaQr38EV/RbuAASOhoeaBBUs9kNiVRo364B2Fruma7WdF9pwGvNDz+
# DATA M+dw39q8+877G7d2I8MsRxcj887V3jYGRUdP0QplXqXq6/obMe6t8bgF3AvgGkLKQGjdlEv3cl6KcdCF8BC4PdMPw3ZOiwLvRMPA
# DATA gbYEJeNBT32blfYWbZ0wyOVysJpNFzC8jd92HEYQCob4w76TWgcZfgmfVLQPIEc61hdc7mWIk7KkMGUK3qLmApKiob2qdnDtKlsO
# DATA 8Lu9lCIdIH+OZ1Eg0GjyPkSlGX9APGE/R1akNkGdFf0Bru39oDjOwveV+f9zFOtLDwMqtv+url5986pn/129+hf//6/M/rtz1j9U
# DATA Z+8+GAshOIU8bVzPY0pSDWuoJVMZkAuexVtG+QoFPkwg8XgsrLt8h1PhaWPs0WF/3NMXAIOnvtCXJrr5pdqQ4cB/GWvxt9a/AwrK
# DATA nXs3m1v3bipG37y9eWdt4266sLazs/Hu3Tvrd3cx8gEFEchHMEr/rvR2ndw99pL74/3Xy28Hn+ODxUZt8WuQqLlTuwMWvcNeK8uS
# DATA 27gcaauxu45BolbjQgyxPxidgjMSc6xcWx9vvvIYTqyRrXz0dfJW8sbKKvlVslMWpH28n92///W3X7v/eHm5ev/xytH9x28e7afM
# DATA wgIrnmx6Sh1tsmqdt0fPjMA8Wtgj6E5ojBBx3rlK+TltCQwqQuYCOKJUkqtXr0TNExfvIHxJPTSF1EgPVUq77X4rNftJudaD/IBs
# DATA mnZO506AP/8sQXFOlLMlDoHTAvQRbtvzth5UAkATWBdYfd9Aa25aMwmVsX/qFvxVHWtT+hpwiYRUVJh50/5Cg5+XfgZU1L1eycsv
# DATA qlbM8mPtDfv6D+CXWjeQ2b41Gpf5KDEyLRCOmEHpiPYR1rDHdj9VE/9Eq9+1lal+Un57rvouQfWcRE7bqvbq1ZV9TcaUUUgPJFqu
# DATA kPr1Mz0vPe2qAtNydZmmpZbqwxVc0xHQJqdx+r/EHV+r/q3qbK3536v7r6tbS/698iINO+QNunhPWYBDKiGjiHC40S41QwoaceQ2
# DATA mWcPK5fcLJJHT2edNggqwAjgzjxtVqejtXfgyL77XhpZfi/DDYjXKADJ3B2M3xlM+m1vqYJ3DY9EPebAapwcTF++VP+i0sUdjJZX
# DATA r3IObPm0D1BMMBsrYeZM+9bFfYdWV6MHs/nmF1N8tcYt32dIdOH1ZKUsFxu8Xna7eTna4vmE8tRi+CtPIoLF0QP9IXmmuMtB+6rU
# DATA TMAzMNYH6QxvtQ+2NVHe2l5f251FsRWZ+TtGX63Xc+gr4paWS2yGlF5sFgM1NsqSEENz+IDrrPA96Ftz/W9Ud8X13ZuBSvQmfNvt
# DATA H29seks0p333tm6v7a43b97b+Y6j6dSfnHU7vTbzPZ5tObfaKwmhR8AlKSshMRY6JhnSFLnIbQoHAsAmXQlCg9uXcpIQ5Q/73c3d
# DATA 5p21u2vvGtWR0RcWZJmV7NrmMQ54tn3kMG5bg/NOHNrtIhQD8hcmqY3BQtJsIM6VeMeFAFuQ7FEqmKBgxjzSUsdK8s0Gsg58WIar
# DATA lWt54olXFgvosHlHBBfaoNFRaaWysnrdOCq5nldYbaxCURn3N6/p/Bgbf/2S9KIzA5/badUJpuokCIQPhFiAsHjTBQtPh2VNbYph
# DATA bCKlAsPGSvEX2aYsnt7xNwEjjhQwFoOoLhYqbgqBSUVaUu71uzEgoeIxvLV5Z2tzx1PbRjhLeLqLJlkuR9V9F6zeikMwnXswWKCv
# DATA w23MHSL7kK4XfFOCIc5ohoGo5QV7hCQeyy7P78UMil5etTBbdSy3NK6Dvf1YVY7XLJcTxTrza9ozF265MCiEAoLud0FyYVlWhJ5L
# DATA +O0eAXPve+pefOakusY7oZWH5lRXsa9XhL7hCEKUFFlJQldWL8cPtABkASSZe/JgMhVpS6FqA572abEZtQau3G7mAaj5wjJyTRx/
# DATA 1E1bJQ0GRqJxFz1nPKVu2dnAuJD8WjRUHr+4p85z4FXCp8SG4mYr5b2Vfcf5XGPh7dXh8Aeeiq+q915NXxV09L3JAEUDenFZZhhp
# DATA 69vYkRK+WdEiK2nXuz3zKbyvBNq6aQK7SkO04jKrV1LJVuDZNxM8VpawJH2MhAuZqTZ9LS3PzVjcw6EcOWrmSl3Vux9RWOjXQBmF
# DATA g6r2QdSlvaaVTxjRiM8aK2UcfDHW0kmLyUonjSjNIkPr6YItsORIaybcuvbd+Q1pVBtCK0zDuSYJkWRYH460R1WwgsP20YFFJ2V0
# DATA auetzJZXI3tkgJhbzLDpTAnJfoVTfcwAW8DPhV+Ja5oNazpKQPuKCmiosx51k9DjQO/sqS/2raeSTObi7O/6K1+JunDBbZ1JUVdG
# DATA 2kTUa7DkfNxBfSDruGucLaG8EKcLzm3qkIeojYrT4AgmJ4NWMALixEEKulrQmJa8OpE8alQE8QPNUTUsJfGFg/S0m2Xo7+MspvMU
# DATA O6tEOO60OqhQ6KK6xS076TzWFegMe/R+tz3V69DaHThshTA9GhgCwEhacBLiswYenOxpwZ5Rw0Ozc1bJWd0cVmCOZDYvCSGbNS7A
# DATA KCT/pE6Ea18MINUQ6FykMIeFCHN11hnzTTwm6SlAJ6khQp5s6zmYxrQt9O1e+PY+FEcN2rPzuD+/xPje2t1312OM3a4oXTm1mbI5
# DATA efdC6nPE3dNBG3Dl2lb+vzQ7LWKlRtB3xNmFPMeYAuZ4SalWNFZ/HSWkmZLuhZi0LwoX8eIYP9ZnxxyROr/p+Ttlfl9qw8GwpKr3
# DATA Q4UCqTnq7ReWhxuFlkNy3zcZzHwHJCok+I59CvDA2J6cDjPj8tbpZ+BM1MoOu11SfFcwIXJ/3FjVqWfncFvkCpCZw/gfpGngoBDb
# DATA SHENvOKeJEh6MYKeEJXZ/geV5UxjLvVxA2VhkwMMysHSgrmnVe+9DmSmhqRhDH/89UIRJRk+cqkOcbvhjwnDAZdcnhr1J2hUbNbA
# DATA jQuKMDvyK3RiDivVvM2cnZ3v/BO/fnuejcVk2NIKRZ0Dm/WD6gwZS7lRhY6BmRyd46+WyrCbOw2hclzNHd17MZUul0vZEUBF3Fge
# DATA vAmwI5QRIiONUI5jjc1zddrqd49ACuEMWNbDcM9pXjSplU5YhDdtQmhOmYWp/6QeJLpveX68NlGWJ4mJgspSZJqrkmkgsGNrK2ab
# DATA 6/Qnpwh2WtJEY4du38vQNUYXaKH4CLXrtoKS3XTL8YoiIqsgn5gJEGcW6Ej0O75ALyKLiEpzxjOnjjhlleI0wQDlXHqgUVgoLt0O
# DATA 5uwveap0VjZXb6mNGK2ss44/IQ4wmENNHSNwQ8+U3MxlXnSqCJVJcK56nqzgjXzxRo+23EmfVP0LF9/YY2M79+RY46pgquYYsOic
# DATA F/5jIJs7/n+n3WPG93upLoDF/n9XVlauXPPxX1ZWl//i//dV/PfaK0uTbLR00O0vQdDE8Gx8MuhfgSixzSFkLE8mQ0UT7Q6Ejrb6
# DATA Fi4zwCV1oCMBi9PzCmR3utboGP3tFoxX4PCMvPFAkwErV3vi6WsK5P0+nAZf2A0wgI+BzAsaSQa8/Gb7BUovwoVLJ7aKQtG0OzSk
# DATA akezMf7E6XqtA8X2QiSEWwyAbFVp7+ObTsyXtNpSQcZqXKOAJX0q1OlmauCVrSayqT4loAUNWAZP5y5GfGrPwjM+1aES9tPAlix1
# DATA 0BzfL7rYgKB/B4zkpDVCPJJVg0eCdyQkiboBe6JNZ6aPtLrL7gk33x5g0BtkJh8niQ93x7ftzsaj4LrL+ZVrg9Ock0wnUrI6MZwG
# DATA 2y0q7tAbmzAbgNQVDaY2YdP9glHRdp9DoUxrCLUaN6lhUolxZxv8txKLuTPG+Qar4zCY6p5amQ1YhfIEU9Y4OTqcptXrKjEpswvN
# DATA DzrLOKISAy8vDZZCt00srQ6neKHlrLWwmCgJddXaf5SSJuloB3vWWSzp3jBiCHVeGzshFsp74/bdHQBZEa+EeDhFWCyV2T17j51i
# DATA OSuhhZK9AH+gr/bN6V+rlinxGzmtO07RzqnmZbgg54KenHugJ9OvFvRkDkdCuleyTa+4zspMVBXrKg0mwatXr3gdbli/axyq68vl
# DATA fOuJybyUwy1o/g7AS7I5HlAG4xL+K0gKFGYP1QgAo3ZXa4XDuItxcyrR51gLtZzDHRouIblLJBbwiURpWKcOmsixVFvjEEdcNJJz
# DATA pz7VOIxOo3XNwW46zJaDD1SN72xv3t1trt+9re+xifchthPSv0/9FvW5yqBNxkYGIl1TRAmi/eHybHDBCzrMOjzel+CogDavJDMM
# DATA yi857aRqXktuI8vQmGgZ+361DkeDLEswQ4EJ9jYhbOMBAp4fom8lZorkwr4LMPzwSH/CsbaEQaDuUxDMQQcEX/LlbBM+euv0oHs8
# DATA GUwyjsvlKNqMPZnhK62hlIMBAfL4AN8X9xpMjxTwHj8cMyR/ScTil0Q5F56zvP+wfUhNe+TE4G+sHGesN1WymdhGReYtZmUxgcd2
# DATA wWtaNqNbsLCO4qgEruu16QXzUL8nzH3iMaGB+tuuMjVdBvnKVAKsC0CzHuZjd0VZt1mYTh/Zs1TDqWcBp8wEq2yQTZrw/puQBsDx
# DATA u1erZdIbWyVg1iFgRdVMa6S26HVkRuNaZEJAwAWdQ7DZwIyJjtT5VwimbYoaPOqjwQ+LrI34pTq51CzvU97Kk8NRrTtY6g3G4Ee9
# DATA ZMOFAzgYx8lFDAKRMtQ1Y2ZHHSWAdPkc5TZqiRpVXTGeP3W3L6hJM58bESFspBPyHD6ezqY+KHz+/RPdxuyFr2e2UzyT7sedU3BQ
# DATA i51hvQjyUgA+oPEI9LnR3DCB8xRIDnWExmH9BCYSauDhBQL23QxBddpu46borTIgfq1WhdIcjwf2xqC3MJq50VP8p93Ciuu6RwXN
# DATA LxsvcIIKgWBjJXZD3k6URhoCd0Nd+mtS3SrtLYqP9skQ1qDY8cPWELKINQeT8XCib44Jd6qxcn3ZME3uJ3ULFKF2gESqVI7xJ/HX
# DATA OVNA1cLWBjSsczAl6RBPkYyRCT8nKP8yEEo2HtAlwqFoMBSEeJmC3YWhU4S3KSWeQd8vbDVlm8R4JwHE02llBNxfchMepZDfbXJ4
# DATA kogTAyS4fP7hs08AJyl59sXzj59/hFkxIYnmJ89/CDkuk2ef6AyZqQc1Dy70D/qKVSRHvRb2mBGcPsLMxCx18Mca+gmBmT7Fan/9
# DATA 7CnAN1EtXmLNsC7IFALuNwOAPel3O22sUMBDJc9+o77/I6br/CcAMQ/LuNXqM8QogBhpGYcb2m51TtE8lvINhLOS+FOfxcpkHtFi
# DATA Vyeh6sHvP8dUzh9iItGPAe1KjUw8f6l6EBnosjezhhrRLgvESBkKif7JkEEUoMiSHpnjcLeviUjfAkJjOC4JvqUH4GleU3+aSNJ5
# DATA 9iT1c57qA0WYNbd0lD77N8porYbj02dPdG2lc7PkpmUml98gwhc07EeY+foJAONXqFWfJufB8p3W4Sb0f1pLZFptndn+E/XnE/wY
# DATA kMEggevzj11nXLu4FLOwXAqdRIDhlAijB1Us0jUriAUJIWU8Z61YUAgYekMNHpZn32v1D0/cEyOPNsxuCYb3CWbBhUzhv5qNjpZD
# DATA 6I4Kbc/3lxk6TdJxzy53JD0YBq3hWLgBJOV9OQrmVa1D06GN8KBUdkx1gXrN7f7/dNL4/tZwoBcaCKYOA2lVSXR3GM2K1n2VVThR
# DATA vae3K3qsRBRiiYYU6FYPq7Y7yDqOw4FAT3o4COJyhK6se2n1iL+EZ+X9fY0VwtYLilNqkjWQobFQWci3yMDbJC9Ek9Wbc53G9mdV
# DATA Wa/TGTYImRt+WhQruUis4SGWZQEi6ezVQi5QtW09LySStThMSRZ+R1vwbLxSGKIFKyxYrCg98btmxuyb5lbdkfh8Gi8MnsLUKY2Q
# DATA uZQX8oJsXGmJCIYh0NJFIkktfFSr/UEVVQNDTFdg7gFEGPIhzOdKt4/ANRH3LPYQgRkGscs3Vnhi3ILnm+e4ZnuhN3jWyV2z/6JW
# DATA 6i95cdIm6a7WSEKTeQSWBYmJj1zUknm5RrkOYDd10fBnQcw7XrFgsau1FcXDD/ZqK/sq8wiAGv/cd17dS3E1kicd/HKeoqtfejDp
# DATA 9kD4se5+9usLwoG5GjwfEGw2RJutmLTUuk6v4J6jtIeSu4OaOdZpFXYVso2p8iOnwOmC476FEyl4VDn03EJ4S9BNa7MpZh7UltPa
# DATA ZHyIU34Ed0rp17/z9dOvt3e//t7X73x952/Jty3q9bVXv86Kpgu4ZiHiQ6I9wsAhi6JQca3ROLJLBY0eCRgiiDU6JpXEgdav60UI
# DATA UckymLOeGFKbLoQeIdi4imlBeaHIkYzaTaSvncnm+1KbK9xv6Yr5ndbaOCNl7orRcusQyfPk4nvUypojgudUBVoVmMb1FLkSzMG8
# DATA iaEKHpOlU1y12qIDWrX6vUkX0+ea8dbM0g9qkuVaxmcbEGHsDmKmPTnKkgRzlhoVt78OwmgubCkHZLB1ov+QQMSsT7lIImHbb9zY
# DATA 2xWR8kDgwmohN1ilbO6X+JasNWjWPedl2RgJORtiZcrmeGiZOX6ROQTjulHZYvOsJxF82JgJRIj6usT6QpheruagD0c6RcpKAz7M
# DATA Ayc0IPV8XYrdyckQQkNbn+k3KvrrLVxTSAQkJKDlGaJyoCvKEYQjWjIr59osnPszBSO9gPXQBOMAPeiOm9xozSIF3dAQhaJxOTaz
# DATA Ep/PGze0HKi3HkblwIor9WIzysEpyhT0WrIzHgyHCEN2rKFeM7pVS9YSzR0wU1U3U23m9K1oulGH3QRRYbW/khrBx2hjvX2zFswt
# DATA NdqotFCwbHc0q1QXWkiJ4PwuKsqotilCV3ItVGTu0efo0gInpJDLSjWn+Dx07GyiMgSiakrXlsvxiOgI2zdduyTjd6p4qbze31No
# DATA xM7D+KaTTquH4dHF28B7+Jq8A69Msri/8HxbClnquAGgDyW+ldKdM19hn1d+nn0EPaLJpgKAbPl8OeDIVoLFMpCrzvaa5dPJ/zKq
# DATA SzhnsPIS0etBi/AH0J6ReukLPsT8BnVncyVsnKGTSOPGwAO1dB/EpknPfUOtzb4edYx4K5w/PfOkw26rgxFpoxUfaudNmjdIv5h5
# DATA XrPg/89/BMq8RKoen33+/IfJs1/BoQ5vMdh/dARQw1BanQfOPKIb+hjVsr979gWoA0Ez+3vQyX6B+uhPuQM/u9DM5Bz952Df8T24
# DATA 2WudQYoM0n68fKUFc47FRS282y36HY4MiXVp6kpMoegg1Ur423F8yXHE10Uw1qvZdmmTnX9LtbC3blSMJ8//CXcscqcnTRyc3UoG
# DATA 02qUYWoe7Q1cWxsdT4CdbeGTkrYiqr43mk21bTSbZfEl2PCaLf6klBo1OuHog76hAWSSHQ4YaT9T4oo2SaFCUMsRpFbs9NqkRqS4
# DATA KBKf2O4JV2RWIyMWq5YITAbtXdqQjSw2NRFEVTgDwKVOuoKmXRSb0ACGGU4mo55UqUW7V8WTObayYBCqVYxLgfC6s2GnYTJyocWu
# DATA ob/BP/BVZo9tcFUT1j/FSc3Y5cnM9A0OS0X6HzgcAF8iryq1m3vSHT4U5mXXMQEpWp9T4m3kORVyOE29z4fwU5ouR5bC+zhmJgKR
# DATA tfHL4OAqHn8TfV+5eN89I9g4fQsYbZR/QAuQYvsX4rNRbTB1yHIb82KuKhgkI2r9nu3WftHUcnZDydOc3Ubr1eXLVDQd6PA3n+Tw
# DATA t6NhxzvmLIFXRtdutOiWeppqlYD9XE1aEw0LzSZSQLMJTKXZTCO+ncRuct0QTeqLb3XOZie+AD19x4NXHYEfT/rs57iVf0a795wW
# DATA F8fMB4bbG0nEJsk63QpZHjkJEOathh39i+c/g0qgMLJYwib/Wygd6q8lihKfcGsg8xBW/Ql++xGaylCGUzIBinSVRH32EWUyAmX0
# DATA P4qk3Niyp0C7aCzCOgHiFU6bDYh/IKu8IMUzyjlUWvmPESH1H/s/R+WP5+iXDv8+I/7rzZWrq2/6+O+rV974S/zXnzb+a9vCvGOi
# DATA js6IEDhIux/Ef2U31N6pePlBdwypuLSTAwuj2XwxYCFqvM6e2GT/hDhS/OUjwjD74p99fNiFzMjYxnhcp8Xit6o3k9itIpz3pFDH
# DATA AnwXICq64zMy2dYdkGc3qr2U3l9Oa98dgMs8xEvDyeqB9mInH3ap50yFC5G2tJbLFsvIiYzfq69e3TdI0oeDEWCmWuAfDDu3PqyU
# DATA yE0AIBhE1cC+lKVaHqaPCiFHZQ4YRjLYXn93Y2d3+zupi+gksZyo3OPe4KCULmo0V8cXWfuARCq+SOXCR8CRHN1wcV0fpJdENVNk
# DATA gudJlPsu1H9rc/t2mIIZSioEnzVzFrpekoN8ZOoEGO6C6Qfcss4z2q3e3I8MaFS2FjEgIcqupJkt0s7pimbD7AY9jeYQJ+ffR62H
# DATA nWrUAkoAHfAiQOvzEos28J5iSJAZaB8t27DgW31C6IKz1XSePtoTxAt1tPhswtkg+t3vIWiUQHdFCgbXfyhMHD3wVZmpyCVcMpw4
# DATA uJX0SRy4UtL07uYmAFZ+B4l6x3WEojJ0pC6fj13UMdw0W+0qepVbp+rBUUJeo2SIOEVjBfNrHXiiTqCdx61DTbE6TR0dfzwI8KKF
# DATA YIi+6bmTITuS92O8jQMLp6Lu/FXiwoOKtyPUYaufCVqd1xzndKd5A1sRYC2J4p0VFVQrnQgqYsGl5WnAv/DjaDyGsEJ025kwpzhW
# DATA jhyTio54KLshCX1FyRkl27imA5gjmetb1SMIEz5fWa1cuzpN466IUNK8LPzW5t3dtY2769uA0rl+d3fT3UgMIV/EqrMIDSCnfTU8
# DATA pDi0Ggc1HoNHhOZmJ2Aph+Nh+Gd3sFT4Ykxhb6JDZlRxkSCSaRgHi/IGMiuHa4kIixyzi90dLxAeEwmEAb98GlCh09GRA4JQrYJM
# DATA TMVcUT1RQCBRZA2y2SliCCOR9kxx+zJq07NkRDQ0WjFTngPaWY47tyjcj8iZzISIpzH8uGgf2W0xx8d5IQZggz4l7JYAf1iwz6ZR
# DATA KEG7aCM2iLgpSiZJ8aKRI8jVYdaUYvwdToanNhuTdybaS40/ukcWkEWsh7uaE58YdaumkcrpR5A8NNeiGmxtBsQBM+sAdElW1PVc
# DATA 8RplXA+qzKt7kNV09tO0L7XSIeggZmJhybs1LpWL0BHnTZJSimVJkdGlNDLkbQ+3g/dXlpeXy+ViwMTiAdr8QG0h8ezIMX/fObIR
# DATA l+eEdSdmt+fKgfuOcyEH5iqBAF3Apr6UQUUszEyPPJe+OCbDMOYtGi1YbKwwcA4y76aVKZ2wzBB8fhgkU88REFZROoDXCw+wzknO
# DATA JgDj86M8Y+PWhOUtyLg7bT7B2GOvL/UgQNATnYvLnJkhHjDm6fS7vr1+O82HWJkHYcUP2ptn1HbWt7+9cUsnpn8NWXKWKB6I8nqV
# DATA gli1yM7Jf8FlTw1BcjAaPMpw1x1OxlltIdgQ9iI+YIuxXWI/yHwR2xpmJ9G6hO7BZ445y51XAtzQ8P6MJdWkbLC8JEJQmLx4Ixsk
# DATA UrM9mROExyYH2OP1hC3lzUZfU3SZXAAMa7gQcuq8ECgxyA0vvY3vpADx/XSxL0+v3FbMQFVEkWt3bm68e2/z3g5Nye7a9rvru+nF
# DATA 0hmIvtucBsvaZz/gXR4sOGJ8UxE6m3Ho7GhUGFb85Vso7U6Ncm8C4sFgpAmjPzk9MHhYeNRGPpJwDDeHi0PtN0wElAYvG3ZGEPKR
# DATA YfgjBkfjokR/QPCvMOdtUI5iYjBjycYWcN08lrPPe7Fj3pd8xLvM8c45wryMs51YVsGBSFTGTH4u1zoYIRk/LjMkjg+H4i2YtQNI
# DATA 7dE/tghDW2r60jJhZ2C+WYBKppegUfwzY5Qj50SBCbDNC6C2to0uwNGAGiVaCQOh7mtsku7RUQedJDe2bOmn4LoKuCJJC9tZS+7i
# DATA DqFOM0DHrb6wrEA6kw4gK0SZBKTby1/f9qQXLO+ZAfxCp5tfwayT1pDgIVxRjbkI75Ge0CEeojGqYd4MRQf7mmyh+DSXh3EB58Y8
# DATA w8haxjbjLT5bauA0hvj8oQuf4CnO4Wdm7Kxe/eXZh8XpXAnrUVA3qZ7ubOzcWdu9Jc82ryW7ik+aCYEFRtpJzVf19MF+9bCDrHeU
# DATA nXSHAK7Tp8jMhIxOatQJKiMQiWO7hRzV6J5hX4jtHHOGJYf6xEgyOvBIaYFndHM8QGoRpDAr926wKC4BirKQAzlilEGs/an56iCT
# DATA py6ePS8v916DFMzizmDkHbJMW165IPKKX5QnZ1vwsnw8lByTSLlcxOuigigzTE3dZUiEdAmzAFFeBB1wFoYf33QjAkMQdgmASRRM
# DATA t6WfLd0q0R9K5EKtkmmdXO+ueQyhEF2IfBogrslMKY0qLyDu2V5oMU9r8IXNUe5RWhIJ57IoYME/x/mBaoyJQbUULNujZB7ZzMdq
# DATA nVMac81Ll4iXoHg4GsYeHaWkNcrHc9Km8XBzDQ89wSE9yKiipVm4Hyyh0GGfDILCZicOXTltoE9iFVsxTGt1KmjUjBghZ2352rwl
# DATA tORh9kcT1OIQq4ssxOVEw+SEhBt8NDH5RmfFqHjZXPk2qLZ0kia397znRFs0e+eZqQibS/1le1kxDUon/dbDVrfXOqBwtXQhDsL0
# DATA co6TlTyFZkrtwjwP1MCU3dzVrYPBoCcN6+ZIUlAe+YHXqZ97dXXA2/cM71iqbaZ9VFSsVVzmkv00gucikq2fcXCdwYNa1dFhEPbC
# DATA 6YFwizgdKH436HcPMYEYv0/RxSeAvRG89E1TRCzeN75cLrxUXAcF93TouSRsdzAswT4PF0zZShsj+zYQkhsDFHxfsDKhNC/uK4ri
# DATA l9Mlp5ywHe66L2iGGwNVxI4tbIkOKipUr67dBo2B1mDjruoosI1jvtVZW199K9xhxIhEAuuIW5qb9QbqOD2/vnpza317bXdj866r
# DATA tp5Pz27jZpwW69bmtIhcv4skE4ifcYUTTyLZdyvEcAaqT8fYYKVYAKTdhF8ry8smdudw0BuMIsWWy+WFCMkVtdW0gsN+TJxQpI16
# DATA wrTOpxyKWuFovtLgGZeCluZKmqqMt4jcpYWqb6xOLKTpAw2enl2Dw4IWrTH40AAQRHes3mN1IAT1AmBfZwgaH0yyopV9s+SDP1u4
# DATA GhelxsKtxABopFElcuTSL8+0s7CZA7QFOxt339VIM6i5N/o+SYqs7tpEB0ywXLVbPTASsfgJ2SIQ/ALnif1xslqitbrjk9ZY6BVg
# DATA 6rlEdG8FKiCVxDGowlDPMH40qGqCsMkntK2lpXF7kSRqDMHRbp8hqlSurgDOSrf0aySqqFY1KVi8AXgd6lmq5VWaAadL5IPnJo+P
# DATA iQC03XRMMr4M+fm5N6wVXaPrSQDfms5E/CCdZ1YVQMvGE5vkkVpnizRISOYQqo6Gyfn9Pq1mTCTEYxKcJ+tXlleW7/enMkHa6UAd
# DATA SkUS7myPu0V5EdOHivxPnbHDBQmKe8ZSFvbQhzpNJrqpUwEQA8c7IuhY01ysZH6fw/nwC4JX4AFzS0Vy53KXOuPDJXxvyRIIqeiA
# DATA HKiLZYlma6jG/gbTPXXLnUKL1IRe0Ip3NXTGIqhcz4tlt6ZEPeUvhcjqIqc0rnQtnPMLNoYQ7Bgti36vGYOuj/JVE5l1oISsSZnZ
# DATA pmUP0Ju/dA4zOt9mxWo/dQciicZyONh7azvN2+tb63dvr9/d1fxMa3PmQLfKS6ZHafSEu2M1DswUT6h3AVglc1a9AGKSj4y0b91r
# DATA dQJTHvC60P6u8zYKcOaTVo/jjGk7B5QNxb0H6sypDnA3GLpF75KJGiE156IsB2w0YQkiOQVQdVKuZHAMUIy81U/EIOI+bJXGhk9A
# DATA q/fxBHhkws73BGSynAcYdShmP7cYLdBAKWl/kF4cDMoGSBZ/Nv/7s5Gjcr90saPc4HXad3N9iedTA17CKZmQz1u9JjXAdyUWzSqT
# DATA BcdcG48tD/LZlGgiBHJ8k61fclFx9rx6DlRRl07FvM6sNzG8MS3H1g8tLMpq3HYQuP70YEG5JDI3eJBIFglpD7yorJKIA42HR3sI
# DATA Qzmro4CUNQIR5jdJTbKxTpMDh30MBDMPBjifwpbbrXEnIMJoc4JQGo/vWugILjUwxgWTHtVih8PP5+PFYCu8YDmEtI3HB/R1Dwvk
# DATA nXsOipfI8BHqL89leNxev7Opzu6oVbi1efedje07617UkLu43VL1enf3aPeLsp+ENyoH1SNeu5hYIwjx2XeWspFftW2TM3IUxs74
# DATA LTIfo/itDeH6Lqf5OO7ktJGM63NWJRpnWUM5H0pFvK9ZTrkQA9YbvgARJmdpRJ18TYIbR2gB+A3vPJUquXjUMjfKuQ7BXGKElMK2
# DATA Q6IdkCWQsCWFi8dgEAqF3P3oqIPeo4iYY7lK9VZVSTxa9mx4do+sCK4kI24oysvPZswIM1PHgB1BqAF0KmKgcW4+C7kmupaLk+7m
# DATA D8WM9e3LFxeoxRlHrxwfailHNIlUId6KprG1hxk37ILhqgKDl5wU+8EcCYwZGhOtDp6NOt/nqpyT5H2GYuviIEOFjuYSgKgYfAhG
# DATA 0gcckok7LNUbiwjoEttzOp3qrV9wynqAUG4YYz0x+QtlTGdeFJGViOeUxl2vKV8uNyT6gqHLSrR62KWsVRFRvezWw4omiczHQ2+K
# DATA AY7Iv2OhgSZW13lHKi2svC5dQwnYWkLh5c1lhTm1VShvtbKMHUc1QTCuAR54DtU1jLS6Rn0OQh8cauNApqbBJv4y6uQC/2Q9Pfke
# DATA OXP5ZZQvOrG+a7YGBmebq5zoOVeFRs5NpCuzajZAEtpobF0uOo71H1o6cbYYfuKMA9yjqBgITsm63+8kbyXX3njjyrWLeKOv3/22
# DATA kIWsUyp4cnRBEd0rjdK/i2AlNkoiNKC6//r9WvF1+WuEDVukrwOYttqdINTTOGw2HIdNOU2eg6a7eRG4O9G1hi6/dW9nt7lz7+bO
# DATA re2NLTCKqaV9b2ed+wbqECpaMY77fWPR01hO0lTGME5hKgTamS3ahJPs4H9zg8ocSkAa8DjAfdQCUmQNjyNQ+yMchsJQI+LQ+fZ5
# DATA Hni+C+Rloak11fn1R14thMGmWbcvc7/L+SDQF3JRQTbBPSRHOrpd8btimilQpJmeLoO7nVd6WU5zkxcMuDfM2auoc+BgdAxod33r
# DATA M0/AajWBJSh3fSeV9P3266W36/dr6m/5fLVyBX3U3PbRrjvHd/p9h3GPJ0PFzE9bwxKOh1e2dkitAYiL4t7e27G35lIe3N784O67
# DATA 22u315s339+89S2jOHCB4Ena5ZFHm8p8ML7z6Pj/jPT6biaE0H7j6/193jT9MjTdl9dcX1hHXqTp/pIw318DkqSEDVlHzaL60Tu7
# DATA gYKgCDHQHvJZB2I26emg14P6EjIy1hb+t9cDx7TcL8++8PItBpe0WLwc+4Kj/n/p+vBQQltcLJ2nvnpcw/7kCRhu1k+wys5Spc8P
# DATA +H95pfslFIqFKvIvHQo56g01C7tfekNdTHF9cYX4i+hp59ZWhsDkBXq30Jc61Bw6inL3WZHmnQs3GnWRtHqez/OsBBca8BzbggDA
# DATA egGt+eX0xxpsnWvxssIUQpe/DMXwZWHN/6JULlAqf9WY77mMTkK+H3IuVFe14B2kbNCPpoqHLGaRhk/moItpKtjvWpuFffVEya+u
# DATA bAOPhL9pTGkYnvgwCtwoR8gXrkHW6MHjs0aqEQ3S2ZAFc+IUcEB6LBh94WWdyeca+ljuVhc/Yo5ww7lSu+ac/ja2129B6Doaj9fv
# DATA bO1+xwZQdXVc8AWUmI461ohuOpZcdEbJ9QibYzXVXM8LtBmVpOCtZ5zjDekY57v5fOC3N/9GFEokKeJadZBiPGLQbUvDurPqnvrl
# DATA 5R7N76xtgLLxv93bcFBYLgKKR4q5bm9MhyHModhQBdQYAU6fLnkWUZ2pZ1QH+KEqXUwRaQAiRy1yMMXm9LKX3YrCmdNh12rm/lpR
# DATA R3P9bzZ2dnfSYCk6+dHyVVucJk3qtbpHTvdDKpeufmvWmX7UYZ6YtEaHJ92HHT6+clmcsLh/2Lmhc3iJsN7XkkkfI6Y7tsYu4Fy2
# DATA +uyA3QHdLEFdHoxg2VvvPq4vT+9iGnZB30pR9FyKmIAtFEdHe3eA7cmY8Ugxl4XU8UPUcZ/Qg7akz+kTxwvEvl/c9Qrh8DQHD8RI
# DATA 2I8PT9SHJfzOKK21vkTwlZzMsaqtw17rsBNNFdg4GY+H9SWLzli/skwxLrGXYZr1MqiNaKWlS1px58pgoWmqItvtIFGcu4F7Iiyp
# DATA Di4ViuazKieVQ9cTJaaijgTSjEo7sKmqvO+luR4iIIh6/yhdWX2ztqz+t1I/h7tT9I1P/Q84fWwd2nbBvLF+SYPjY4poPE/boy5m
# DATA dCGbR1UregZDrSQ8T09bj6tgc4OXVpZPSdH4uMr9Ta+kU78CCjY7POkcPsASxmrsoKvprTu3UbpUVIc8Ff896oCm+VWedzsYMApL
# DATA aLtRsvISlflquaa4T780aryl40wxq8SoNnjw9nJ9pVyuHaLiulT23lCPOGRaFagkGmj6G8jkOaLR3lC8DbiUurGySlFoo3Fz2Bl1
# DATA B+BCk64uZ6rLeZsrjLhNBLw3O6Ifjnb00zV4nevo1sB7gKYlnGcKi7VN4+3Abxvf1l7SHHttsg85ahMyZzlfnJsvVCum5itoEuB9
# DATA wmRZRyPuAhdgm+bLFnkaWWch2YAKLWZfLuCkHHRQ2Ot0yInDBOhmfVVJJ8Nuv5POwQ9MDmkYmHc3b6/fvPcuvHyqRq4LR7bx4bCx
# DATA nOIAalaQXl+uX0ded/Xqlbr6f/FzadIeIgHrKJgYq7EjhH4g9Vg0Sn00MOJkFULf6kvwr71Hg1JfYj2v47FKw6WbQINkS9IUIcvB
# DATA e9NZ7JjkqKqWo9Q5wVfffzkuNx7jcn0K6wigUAqJxAvM9j1/w3mJdK/shKnTj+kLQHPkegFJZVqhHjRXrz+H8rQ9W5mgz2WuWjOq
# DATA g5rb5jX1oxkITdCFkfoTZZpj6VSml6tYoczL9kZPWMqvAgyryR1n9mTjIIVHEEUMHA+OJ8QqR6EhZ5pknSowFXtFJZHM4wcx6y0u
# DATA FoS9X5hbjnPZYWq5LVRtjTqKctwgauk1W0pROEf0r9xsH86ouENgO6m7Z/LsWXgH3AByUuyV58qqZ90HL5UnD+fGjwxH/5X25HSY
# DATA lTQsC6U4AyQVEEQzRRTNVnbY7TLSa3GiO3/iC+rzITVNvZxlTShDKL0an1wv0SpBewUNEiiOflvg5uUrtmQuw8rjfoFzjoLMWocy
# DATA fnE79BL1e68Vixer1SS6q5CGzG+K8DAzegYxkHAcTfEwEcnDxxIUvJLayin6VOgsi7urOVtODkA5sapmzOUcNCSa8q+4WstF655w
# DATA Anrl4qrFmDo6URhI1G/6gzyzKQ7bDqCNjeNbTrPK+evk/EHnjP04MNLAiYeIss/y9BJrxzLcEM4iUBqHvTDDqfXHe8v7xRUKpp4n
# DATA +Aty196ML2O27B7qd9ViTeTNU8xRTuOeFJOcRUKZna8S5hjyj00Q7qpEqchqOxvv7q5v36kk9vq9e1sybxHdpz8lKqCS9FqnB+1W
# DATA stisywSM5a8+MaY6LWSY4cYHwUxJl7N269b6zk7znbWN99dvg6z37OcyJ7bNo/35s989/ymnEYf81M8+hydPMAvl79zs2s9+S8nJ
# DATA MfHlz4NMmu/t7m7tVNWnn0KqzucfVRL1OqbRfP5DVSQn3n7+k0rCn32kKvypV9tTqgvydj4RCc3hYlbSz3g2Tmz+02e/sak1n/+4
# DATA 5h9T0HO3+Y4aq+YdcO69CYrjjW+v7a7j0P0/qtbfPvtdsra1UXXaBB1U7f415lznFJ5/gBHAlJ+/Vq2BhKJ44sDOYW7aj3W6T+rk
# DATA 8rXlZdX0/8vkbucRx+snmMP0D0GDtWHCNhwb+n/jJ79WIwITgmnjf6zmlpPjUvs+gVbpjPF/n9czSjdPuXQhpy636pfY38/Uz5Vr
# DATA ybe6N3MbZjSKsXYZEvEm/5fqx2+gnT+EBO0VfIrV/w4I86m+fsLDiARYT0DPldWX2MGo87h1Ouyh60/QOKRQbpqxokD7/pVqUK1S
# DATA pPorIB63ZVjZZ2o0f4gVf6RexrLUvPGnv+Pp+t3zn2DS19/6dK1o9I/Yk588+40q5rc4Eq3JeCBbOfUsGjtnkDVuHbiMXvDoSgHn
# DATA YWQIcGJ89u+qZMxH+/x/zJdiPkyPW7Cs1c9/Tp79Ws3Jh0jbv8OZoGy4f6/o6Vf4hOr+6Q1Mo/vsc5xek5X5E/XnE2gCPFXPFFF+
# DATA DB6p/3kS1457X0LC1wvlf11dvbpyzc3/uvzmyuq1v+R//Sr+e/XVV291RmOKb+ok7ACASUXRdCoMS3S+7zxKtrWWWztRkJ9xcYpX
# DATA KIgO1y+etLUwTWvndAji4QIVyLKmLpCOQhU3PSrdzCoJCqSsRQL3+yzrlRZBrqsgcliDjK2Q6h3EbmZ8jfys71vrSo4Dbqb42NPn
# DATA f88cDNgf8x+WcWADRmb8BbyodhsSgxy56CnlAf8QNiBkb5/jdvkk9eFehbimOl/aS7kn4OMDfcE8XMPJuAFdgjyvwzH0ZjAZw03S
# DATA 5huoyDeESRnBOUnxBolZC4zc3ghF4ClrnM6XHYUsBTaHre6odDLIxhwjax9VCJFfTl3WSI2vDXk26C9Zoam+Br+P7kNyscezhiiy
# DATA zKdtVbCAoUVx3PnUjX8AB5FDBCFSu92Q0EDwOr3fvz+6v5zOtPM++xcjTACR8LanZTa1TScoIIFABiIqi2RqP1fU8k9q/v8BiAGE
# DATA tk/wE0UlYe7VoZf9MYyrW1levZos4p+ZDf5FSHu83TIFm8bDtq4br/pW1aIcSkdPpbim9vEfgcCW3OneNPlzIIMmehkk2cBnRzD1
# DATA ne9NwPQMjpfgnjbJGAhOQwOC/hFoqGYIoEmEruYYf4GHlLpLJ8uDM8hVVzYT7dwlb3DmA+njN5a/gdru/gBsiPAL7Z6dPuo4r1+7
# DATA isZrZBSmWt2rTVXKzs772l07S9qYBgKBwroZRuCAHX7MYLQ31DKBU76ayP73O6OBhgqGQTDv04o1WSAO0vagk1HQoFw2qXYymtkT
# DATA WDvqyi4+ty/FIdux/0JOGSUjkMI+BbYIVOTJu7+CtQC0RaekJ8VuUS+jfMMHYBxwlUf2ipLDheyYYUyA80xjZToc5KXO1YvP0wXm
# DATA yj1XwtkCpGY6u8Hx8RPYpcSIKm6g7jzBY8WTQN6fg1N+Ja3gLA0kS2Q9IgEQH8AZ0pEf+Jq2yO/rGI/XEpgnNfFDtPAmB4PxSbK9
# DATA s4YLdv3W7Z21G2qDYtz5U3C/waeng/ak18VAdMGuhpODXvcQYAIDIlCPFBtz6CHGb5iZRUoa6s/VI01Pwxbgh5M9JsvqukzNL60z
# DATA n2jcKw2vksJV+fPgfG/3DdgO1DR8oWSfj1HYgVOs+kUn2qjQ8/yH2scJMo1GB8quFrRutSnszxurWrtDGeb9/ACqrBq+BpPcHA+a
# DATA mXqx385KWKEOXWxQxo2VfYhy1IRR6w8elTRt1Cbjw3INrlQrToelGbwL5b3PE9Rl/ZZGgY/NMcEPzr//BCdg3FAV63r+j3jM/+j5
# DATA z9zUApE90DhoD89mC1zCcJEne9lt9XJiHE9nBywRrML1HaaXUigjMyAD4uW5YRGe/RsNHYpMv8JGZZ7shRzFyF5CyDLqEzXAHyka
# DATA /h1qGn6bBk2P+NvFPOzEB4GPHYwZ0HUphfjcwxO149SGnVNS/3cfQhYsuGQBpde2SR6kCRZLEcpvSu6ka12Cx3JPGl4o+d+z/xcV
# DATA SJ/h5vqZI+iBAOjKs1Ik9MdUff57PNyYUUU5UcizqoMadnToyGfU6jDsLqL1dkF3QIBUA/R9teZxkIgzeH1ujQen3UOuyx84U46j
# DATA SWfl+fzVqq75IV1FsyRggLCsLCciZaiDRDg1hEt6+WFaQbeHXj/9CA/3ZfQL0O/rDAM6mxhB9UCmAT6gq3UCOsQhrPGGyByM2H5H
# DATA 3ceNtDbuZdU0MpuIQTjIakdt4PwlWUn66CBFs4Ri6Z3WqZ+KAu6x3SnomHjjqDfJTrwQG6gvO+sflvQ7qg/9QUlESg4y4+9Kk45R
# DATA orQuIQqoJ7qA3A0lxty5Yh5tsGiy0mlnfDL4/9v79uY2kuve/M1PMauNagARAB+iJBu7iJYiIS28FMmA4K4VEEYNgSEJLwjwYkBJ
# DATA tMRb10m5Kqncuqnk/yR1v0Hsim+c134G7TdKn0c/p2cAQtSW4yvYKwIzPd093adPnz6P3+mXOJDYgbUx835SAStyQ6b3NE6EOgWx
# DATA eSh8eP9HG57bOrHwo0d5PHZ798Dsc1XwArGV/z9lQDCOfsBNG7sNxTgC1LtL+wOyhYfiTOXAg5iqpArhKbAvj0b/UMAkxqPEOmCn
# DATA H50WwnZ/lHSORuEyvqZhXJfzFQ8xzSMgSyu/MPGM8pOJJ+eDKYW1Ft7AnW5vOL7snwwjsMheDMhoGWLELc0bGZFVIUbRp2dPe2N6
# DATA jJ9SU5fxqMRVpn4SirPbificMwd4OgdioIHubL6NUa2Sh4yWQPJTpY0Mli/Rm0CMKLA4/jHhHwoUmyqpUBbcGYES7/4OiANpBkR+
# DATA oiKxXXz/KxLgYfNhFf6v2ajwn3ygEzRYVuqzfyLrIBQJHRAXE0NHvitDi8wtUvw9kvRv3/2LaAysQL/URq2/wA3PWAxW+8zuFnHP
# DATA t9gu1Qbhb5Wfjwejwkn45ttrsL6+BA9Y8iQoWcMvIbMriFWECe2Y14A3pyG1IQWVAsl25hAEfUo4m4rBshTaOFDQihFcZYGSmKma
# DATA l4/KneUv9JWKicjUebNeAsQSrG22+JKlsqVFo3n6meAM6EAYsvMx9TZcxr/LIfoZI9XLFzFzr+FsDxMNuWXvubryVHH5deVlNFkZ
# DATA Do51fr0VcXnFkguzChmyogTfV1yUml6WM7WMztXhsnhsOUz7WNshGgaYv6vtMN5N1JyQOnp+7Ynj4hMs15ClLAMXI+rGaovzdrc8
# DATA MxuB4YNinjVMB3Tpd0prBE5zE4mfLxYC1m7nandIWIOTR73zuNyWScgVjBhgbXCFs3mNQ7SC66AbwX/AOfHPkdn9h8XsuE8kFlBn
# DATA 07GbWqONJXI12jdYTIoHokX3n/GI+rtgc+u5TpeeoCFZbGYXcU8cECE7MOpMXse9A0SK/x+XY3BPw4zqfXRV601JN5OcxcOhvE/6
# DATA EyEIRhe0i+GL6PijoyOgoSPxCY2opDt08Y557S5cu3tXogtp+qCMD9xh/hsWVyQtLIcyQMfOOha2D0eDqZA1tg1X42ZsG9JaOwfm
# DATA GflotHkiZJkaR1OUxyAixuwgFXAoIrd2NPomgt3CWxZ5k9UZ9nkX/WmBM68QkpKzsSh3+DxKvq2tCunuaKRGv3ZHMDoa0+XwzhEo
# DATA iXijerixscAA4eKZa3jkwBiDItaVGLRoCO/UbkFN4qm90VYk5PB+NKndK4v/Bav3S2sPqqurVeBT1qs3BWGJffMXcX87HkZXB3Gv
# DATA dv8hlNoHpTzkVJ7WpmKPxfobZNns0OjG/SdXNex8ogbWGQuP7/lCbudzeZzLOG3yJr9AlZ4pZ6ggYnSIBuwAUu9Nz1Qc1ERKsoar
# DATA YdvwrTa10uIn6w0tV0Ta1dGZnNKnWH7bCWNtqbAM+IovbQJIX6TdspeVNS59U8q0HJhUkyho6ZIW57+c4KC4T4HS6sLv6+14E6oB
# DATA N7xQXW1XVJHW5ahi6buiCmq8IjtKEvpkujCmvE0vriyfV6mqm92M6Wl8szYNEjKaNk6gUUUKg6JmPoVGFVOE9lfshH6RoGm+CYua
# DATA Zv0LvwaRd9XKdgfjpjZt8ZV2Qp+fJ6OxGSiU5KFaIVyy9Fkxg2R43dmS6KfBV3F8gZZKiQ0SyK0YT9yQKHPUG15ignrwzDgeT8Mk
# DATA GEKkLx9Ikko69Wg7nA5llBYvy6oxmNZqpmgqfinTGF7RQkGRl7xVFtalWcbOQUUbAQ+TheLmVzaRoGtkNpwOE0+SVJZfwE+JwJCM
# DATA N0HZxboLffbhp3hlFjIvfPf9r+j4+P3fkmMGHjDROA8HTLEzO7j65EUsmmxbnekUPzNvQU86c3gBL+ScC1t3yk/XUows5LsL1vef
# DATA ExgAZkVjFRmJZJDqfQDHFYMf6Dw+Mro/Dobj04rjcR2++wfDsUWMaFUcoAxfQYS70gm9YjfbLOt2Q9Mlhp0A0cWmsdsoaYcK8X82
# DATA t0NIHLxIzchPku3IuPb/kdufdn87edU9vYwm/Q/oBZjv/7e2/uDhuu3/t7Z6f231o//fD+T/14rBth1NBkMIpk7A0ALJuBjj4/Dp
# DATA N0KKxRR1vB2VSP8+GFEmN7BETChr41WeC+BJbzQd3sDfLzm7nA7UAxTucDMPQP4NuCBSwYUOOxSgM8Nvjtz+/N5xYvN3HOU2HuR7
# DATA XcSjl7U39+6NkwoHpon9dWeru7mDbuhbhsJ3pp9dkzwajX0MfMT+maya3/8STts6quB30uaGIQ7i37+Bi+IRMa2fBR5+eiKErleA
# DATA AfPuN+Ajgz76f/H9/wln+vCJMesa26GE7pbwXmcDNFMag7yPthsLucaGymTrNTxZeRUJBi0H+8HG6jxgdfTkFJTVI+hRMSfFe7qR
# DATA tdVUInSj8y0qVX99YSNB6cq+HQyHLkibbiXPnGYb0uiUqRVM0o6TqZ1O00e+fhpMsWh9/XPUoQM5/LsKuhFkoi3c72HJE9uM15IH
# DATA RjUyf5v14xvPZ+37wzL2TeLj8Xjaley0IIatxCqy3lQcj8QiExLNGHLq1ljlklL9lmGsZQ0gAV2OBtNapoIm9SBiL2pVlqY8avdW
# DATA aO/fLD+MOSmQ25/LveI8mnyLmnV6iGAVKGA9ZM1jC5GoxHCX0cHr5+NjscDFSwPu1cX4lXhoOE4SGL7h4NtYKirFWWw6iUbJALY9
# DATA PFi6mkcxiu+vdmROAFNXylKR4UThInR2b9ENMWpShwj9UapCKxEuoNH3B5TqbHpWRz8KxFkCyZxGsEi5Io5GmXpDu0ZTcwiATTwq
# DATA opI7ASeiE3thdDyMDS3j/jiZ1lYuk8nK8WC0MjkPyidBqhtWM1kqOoRcKV/CAchQ0xnaSvSINxZUSHlJBdnDUV+qxFKlqMshraUK
# DATA Jg+15ol6CbjrKDTJVqU/D29lFKNZZeKcwQpQKI/7coMsBRRzKrrGYQixGD5xDudfr84GvbMayUwV/FGSUpmZokM8TqhdcHJmaYi3
# DATA UqwtqKlvAHBm7+mEwXnyShTCFgqh+GGbGcSF1A7OFdpbPTs012iskc9JtIpO2h8Pb1TQlS+B7YCQ/C8TSNZJQ25ZKHLa5X7m1Oip
# DATA z8fb/q9PpGLHp+9QsPotOvIRJ/vuMyk9GyFusAP/FdzmMZS2EDW8fKEsxsgqIojSLSQu2TMhK2MNiSo147U4atDh2tJR+jf4WiRa
# DATA qovguOkG69JYKMeP9Iv0B0k0Oe8C/wUPCiZVJDp7Dyz6NkGGgxWLMUBNm2fr8+ICMuvfFDxG1i+zvoBsATo3UGFIIbgSbAYgxwkO
# DATA JhEIJ4BoSCnVRz3AH2YHfINl9F04yd54OGTEk3IZd2PsG/H2clmwH6K5GmKuaUYn7uEOA7j8F4J6rmqbvd7lJOqh7WINtGW0cHSK
# DATA T8mpOkUv9rxcacYDMBHGE7PWT0q2MTSa2Flx7jsX4/XqLB5ZeaPBv9zQXPo7Y/feNKnmcIk5V3EWyetli27h7IX8v8Ti/R2ElP7G
# DATA pu13v/0sIP8k9Gn+V2mBzRRhkB/wDXnxO6gCzKTgFI0ekBbQo1oZhaI9XuaWxPg9uAYAAkrZdD44CNKcaEDeZ5mWQjhDiAN2TfWo
# DATA WQcI2e16cy40Hq6GXimp8M/2WrWjgHrktepaB9SugGAddkiPaN43WaaslVkmBYtxNasdx2w+S/TVTm//9O7X6OAOVJS2jP+b0vIX
# DATA U2584YqYdkdABx+CynDc+zZ1LgNHeESgGPEJUvza624165ut4C39aG5/05Tfd/ee7u3s7H1jSSqEjC3ExsnlBSCZSHiJkwmcXhzH
# DATA VsShdrArGrstE7oiH8oiDWchIbb1E93Gs11XaftVfHU8FuJRQ/a0UMxH1LhRr/wAG8aosOF79rEUpskYM1CAidOmuFiAf0p8BbIZ
# DATA des/zdFMp2RBjSf1/haG1GBWszsSKiEGBRzxH4azfpbN/75DhIHvf4URN8Qr/dqo0DZ7mMvJMHzczJ6R6v8sk4PZqjI6mLYLDOb9
# DATA K1Sr/XWmDs3zglKiCH/fbAyUBKIcnYIr4gcyAeTq/9dWHzzcuO/q/x+tfoz//0E+n36iDt6Q1vPiano2Ht1funPnzg7nQ4UsG0Ql
# DATA 0kmtAuuE86dSblRED0c0L8AMn4wvT89QIlRS89yGgbMoAYOA+nke9chSAGAqqMeALYdugt4X0E6aEBOcTL8UrHF4G/ACQoRU38HV
# DATA akrNZhsfgGdY1gZs7HIyFG1VJtQ72SZ3tgS3YeNYUh0g3mO0oh0eEPzTe4fxhJco5Sca1Nle30VXfyHJGfjjS1s7DTgx4ZxjwltS
# DATA uUgJI1za2tttCUGs3uzCt+beDha3xRBQpk7Gw3DpoN78urFVt89gjDGGFKPUiEuHu41Wt7m319Kyjc9ZbGn/sAnw+JDJL6PO8ss1
# DATA 0XJr81n9AEOkUIvBmRP641cjVORgpBRlaWNcSE6EzrnxrvgBcOYYjMRUMork4ETe6QlyHokHikvPN3/a3dl71n3yooVNGmHzSm1L
# DATA 6Vkm41Mx1glnnpjImRYEBRB4iBRdCuKXOjwGUhFD+GRyFhyDiU2sIzEOF1QmKTFyvpRLpRid4DE5ehUwGcpIcJmJWFJcDZSa3QGk
# DATA TMMLrIyiI7cNXm8lIkQPF1g+CpKWZ3yF1SZ20mnDhUO014Cczp/UVCek/kEXylLYGPWdxjIQmicaUgPDmOiEGZyfhmadgJrhiAkp
# DATA pV0B4BDpJp0541mzfnBgi93OC1P+ATmvqFKQ7+UkrRuNQS2GEaDwT8Fz/pbVWCOsrQYs+QC08O54+hTIwYkmMyp4E+IooX8Oodbj
# DATA X1Snxv1NANEVPYITNVISQBUjCjFDuSQGVrORBVo20ObaOwq9AB4SzEIsqRhTPAAPEoSaSG3I+fgl5cQGnQqYD7UvFCy8V0K+TBRS
# DATA Ac1pBQzIrwvYEkTQWldlp4rpt28bb9Fpy4IdzJf8urBawqkou++iR6ZTTFVZIc5CfanxiNqP1USt9CAuY0omLUYBQhSOXq+ulo9e
# DATA r50cvX50Ir78+KTD6YiwbFGcQdc5h7PuFU8M9LvguboctN+EkZ5HrAlwqomJUEHxG/9ed4rt8vpG1W2DM3zBS4tmREVLvqxYmC+M
# DATA n/H5tFItLncj/66qw3DSvMB2jMdyKU2tP1eid73MXqAOzzMWqn3CUGcK08NKelMVs/voX+lItuK6Q8XOelLai4thzNFWesAuzhC3
# DATA mL0/uUjIAwy7PGW4VR2xWW+aq6as3ADnDb7huSyeN1nxaqK5xM3KiDoCufxgk+YqrUXp+u8B1CYxdcG59dN4WpeXadzaOG7VjjcF
# DATA mh4CdEcp8HJPLs8LqtI2VtjJrVswh8JMHlFMp/FD5wzViVqwWvW6fLhzxVl2hmhSBMuL8pnrD5KLYXQVRBhRFwH4eXBnNWCwgTsV
# DATA 1/8gn2QNr8BUmkghqhqkrDePFIHKjaQBYwU5UZCsl4M1eWNLDD3wHUhhT+Pqg8hH0j2YImS9VZaTQjH54wEbm3BTpsSTHvG3tdVV
# DATA zzNEANS5e1hmxWzF7VJibIvGktGXCd9eMsuqn4U6lcbD6CKBHAI4W+IhiyoLRjsnghySM2qI5KFXQITenuD2VUy9AUSEn0NHmpK6
# DATA jHblJXO7T28p14Kd94aCFCx5yHCylMpiQSzE+CXCx3B8ykyfPR14z4V8hJAGxJPtTnIVhJ1P51ubN7qyMULHe4XgJarTtcyR6Ohm
# DATA qY1YBjTzOajw+5O+X736TXNvd+eF1Klaytb6T7d2cpWtKYQCJYoBn0xnoKu6jFWVh6Bc6Hwqq7s7VXryKgRXJMMu1WUreR/5/eo7
# DATA FDzuARyQZazklFmoCGJEekNID3rSd/2gDC6lVasnfY7rT9NlF6m7QAcgPltBnMdUB4Hy4YiknULYBhmBclZNJye4g4d3X5Tvnpfv
# DATA 9lt3v6zefV69e/BnIbn2VU7PaY9HMaKDXgl0DoF0NPCLmiIviVBF1IaX05PyjyAaFd48qYXs5iFlEO6T9DxKvxajMTGlxcb6tIlm
# DATA Lqrc3N+v7267pJjpYKWGGzSq1NOq6wCfMf4hwzqTbYhVrRWlnIZENcqzg24W561ZnMA5izkemfIpzGBilNNJolulWJlcFplDjIOT
# DATA yQmZAf6wI8ULBG5ZfJb5Vf7QmOIsjZBUmhhvh+5u2uJzS5zdOoeDRuVwd/NrMQybT3bqYSYLln1JT80s01dz21wFku71790nYHqZ
# DATA z9FwImFFMOjJnuVzwQMYAgn9BgEzg8p5/AYdJ5TKQbdx0Kw/K8hKJNZGZhTLHKOoTwCXox7nXjfrZ6gPS7FlG+Wo90kcfysFmtTz
# DATA Zft55xVBPVWT9cBpo2CX9tBopgEn/40pGBgfVBgO8r3NmqA/4l8wJk/R6a1wjDy7vU4HFlWiXYViEyG19bkICMBUCFy/uR4GD8tm
# DATA 9Tm9iUd9PsnAIEMmx8IkLMMHGDUgGgSdewz0HnxVf4G3QvI81+N8HJ8ORqOMip7UnzV2564K0AuoT7DlI6CHrh2Ub3iTPC2EXPC5
# DATA viuvOfTKAxW2m/Xtza1WfTsw+tDBPViUaHO9gO1UZPWFOP4IHpVoTCtrzfNdCQiVPsdaBi06vbYpDYU8ft9UAaCOT2Ze01rwRrZI
# DATA WfFKijNyzkP505PLisUcSvNl8FR5SR76QasMTWFyMnmzcjocHxfCe1Kp0a4+3AB9ERZSpbwtJ0JCST19f11Dh8l05yPZeI42AUFc
# DATA bFWCJ8m5bWbFZ+jIY4jxuK17+J0x3uBGQmYNrKJtPN4pFm/9oHxiZa02pPFBnDck3g3Jl4x0oe3pfbaorF0nc7/K2YYYn2M6GF3G
# DATA S55AFyM9bDb/n5N9mqcjQktF2qwAc4ZzkeB2PztK7hUeV+PXYBw7SpaLjwsMCdPtGOgxnXtFUbAGhSv3in9sZ4QFY03lebHq1/lo
# DATA zkrc5y3QyStB6m+Rr7xlKe+tDox8CxhLj7+Nr97ClglKMohZfptEw+nbfoLQAfAy7bUOttzIGGW5xKjwesfweMP0t0d3jsKw6H1U
# DATA dBwUIlhDMfiTWrBRzQxQcngqPeOuqZQgmVowVA2iiIxBm1F4Q/1H9Cf8BreYu3v4ArEB3ICcrl8jZmRtCJmvGemFTvTGWqT9Bv4o
# DATA n3pqq2RsQh0Zg8LbuFThFx4PzouF6HJ6Jpb4L1CVKAilXa11iLiOBQHEk7diIge9ItDY0QFg0kzCozWjbnNTdVsIuQ1RWfuO4FmP
# DATA j44t4hTXD+pbzXrr7f7mwcE3e83tt5hC5S1vm93HYt98Kwps13dbjc2dt5v7Dbq2edj6cq/Z+LPNVmNvt+hWyo2plym2f3Y0ORp1
# DATA lsPwZi8wW6hoHyVHB517j0Wrs0SZt39cDEuZwkFeN46O46ufGC9pQkBl/T4ObRrIq78AsDzi8Q7/FXUsV8qde9WVFRi6ZOWLame5
# DATA St86y1+kxvCL/N6/Xjs+ardXy48799pBeUX8+0X5f0prUeo5CenVO4smUQ8CrBGYR/0S6wlLgoLUvAjxEdMQ5DbBpPTTuJjurwfk
# DATA 42jd+KQWrK0/yhNZlUC3zcdF3AMAzYmivqNkSkjulaB1FiuFraW6I00leI4QVju6VVQAho/lQVtLLU9+4igsv1L2zCnphuEJgByR
# DATA nYVL8vs1H24hI73YypQjSpf9VAraAt8kI3hwfjkF7+NgBx9BDPoS9HMk2NEUOwzeE+QkIH5GUwKeD6bRqWF6vxgnAz4q62hPEnkw
# DATA rfkWpHFq1vf3DhqtveYLys05nZ5HoxWFelNW3XXtZ5nYaILOV5zfQJuqO/MZxZv1nfrmQV1Fe0qzHjutFLTiKZTJjcROVzkVUsnl
# DATA MbjUrmCLK290w9cr0jNohebisXLr6KLrRu2N66V/bTjBE05ZUnsTbvZgHwK1CDhwQEAK4KO+HPW5+WWUaEuQGlnUW95iA2EVBPJy
# DATA D66Fnhjd8FBQYXnzlBPP6ikwzxEyr7rh+MneOwXl5GGkzAAhbBInF+NREqdOoHydZKL1Bw/ZkwSOmGquYfsTxcEqrkssNIE48jaa
# DATA CVRsEpWxDXP5EqJeLkIxYingO2I1jOoRnaJSS1NywWlVlOCtn31FHDJ/edQXPF3+A3wyOnWiNSd2m/1JdAK2lkGC9WFmxFShC7Gj
# DATA y1yxVslFXpzzOsC7gBe6FfbF15ghyZIk3lQzZsIUiPyjYg2K2HLxb/GxGB6z5hkv8XW9eSCkBqV8m+C5e3opWHfhPLoARFWuT4Ke
# DATA Q3YsjZI0uirAQ0CnaxuPNn50/+HGI7JkwFWxE2GVi/SFx466tBwUVktFsQ4KG0EZVwfVq8NmLXeaaq7Fxn/s8vp0oyZ8kgEozBo/
# DATA DhDG5QzYuQ+sVYy40hJVd65hOGhBcj+mKpb/jdVrIfL7iWb+xWu2xQOOdfCwsifFjSgVlNLIzw8PG9v8KIoX+HXOlfWnh/WDVna/
# DATA EnHpwnRD6cqIeUpbTr84R6mCAq7O8H5jBwiPE9iSgbstftsmMvHOebqn+RXih7sHm0/r3f3N1peh1aP57JqycMqqmfbq02OmKEkP
# DATA lgHNStdQe+yiYeny2YBYBpGoqkqopnItmUZD6nt7teMo/ShYFM1yZnZn9USR+Prm/n6XjlIoVvswvsDTuRbQmzB8lqlPUooa692M
# DATA EArQQ9gq15/pVmtwhDgBhM83DzeupaaBNQzpV5KKAITJpTxABoAssxEqDXrX++u5RPS8cXDQ2H0mB4B3ZdBSAObredSrjOJXXJ2C
# DATA /y0F7HVbku7XleQsEpIHSmP9wSmIfkWP71g23ZeE+E5K1yo1f+2geMuKgKYK5sJNp5LnGTKkvsREEGQXY4UM3paAg+AeiKHaeubA
# DATA eQVRx9iRXXASxgQshC/Hw8vzGByB25aLoPKObOPjpIrCb5C8iWocnHiVKwVjCWBJZs6UxwkuSBkJQRPR9SvlgA0sZt7alQIl7cYt
# DATA Oys38mpYFFLJeqfYMTQ9ahmK2bu6gINXeDwYmRCPBAjHzKaoAR+r6SbZvboLcQLiPrCq6yWf94LpZQBbRVt2pOOL3rTonZvqPt87
# DATA 3G1Bw093GlstTzI0rt4x3OHsSb2XbNVH6fbWIhGBjQbkkKDe3fSSVvkpsvJfZzwIK4h9+qokl4JPO7oIilkZ9BGOgJ0sq2jOvWne
# DATA J566r0kglZUEIWpi+ed1GvAVAHfjfpc3UiOHubRHFzNRLThguzAD8xWUBOKID4QN+X+DAvEX1BtIt06JbuFi4TqAFGnA22QAigkT
# DATA 41YFwHDwS1B+gqZ349UousL3XugIQhGx+JA5OnALdRypTgF4BzQ9HpXZM+FoxNcQltaG450f68JHujryYiXggI0SB5+7U5tKHamx
# DATA BdJQGSXCjzBEkPzHFYZGWC6Pxq/EF+7NjWua0Ehl1iAPBQiQIiRY0MlPr1hgNCQXQwMEALiAeTYEjnWl8p4KXoib2meS7iCmM+oH
# DATA U8COoW01jsSWjcOtdECZIqZKPJC9ceakIbBETSmbvpeAKbE1qS0Po9JxGVp6NMFecwUzeY1HXOwDsSk35olr3LH768HnNVsAqgUb
# DATA qz9+qDDLz7RNgXWjhGN8NEGIHdQHgXt+2Cn+HslNMmVDWkZSPpqokaqqmOxudyBWbLcrujA8IduyGbEsLlayyU4V0Ucc/YR5zlHN
# DATA ociFbaUd4Y1zhFmnu+8ZlUUvY+53SjVhDUteffysE5+gQ9ZJX9pP9xkN2jW3167FnXO0O97uAxnaxdCzIASAlzZFOLHhP1B2cyol
# DATA WKvsjR9+wiK83b1Wt7ErDuI74A2mm5ZqIqq5HfJvD0xHqoQeFnDoYoKRakpwAzDPw7PjxRTuHDjT+zJOyQMmDixRTsoHIDdG7BY8
# DATA naR9IJDTIvW3bsiWGJIwB5Q4rd+44GCgDEVcqA576xuQfgSKz+e65Vd3uIOaudoKITSF74dT44a5+Aefh+JDT4DTsfxZYDq23BDV
# DATA IjV8ETVdoy9LeqlrIE8ncrYyxMQRRrVFy+8aEuKQYwFU4TgyuU4e8AGwuPnmBqpuC3EdQ7r8M8SzJOq044AwzFGM2WWMBzAZ8EgH
# DATA PCP+KCjrZ81AglVQPD5aX82IU4FnOO4NW6zJ+En2xagJCm3Vm83D/ZbFmVSX8c1ELQQ7LiSoquoHIIWbiQVMwhOvYiY14NdV5w60
# DATA h52CaiZ0AMZnB0j6u6YCpizj4gUHp9CcXxvbVTq8mplo7ywapbkn6oyRABDZg0wIoDCOeoSJ4+Uw8ibqTA3GmRXMlSfX7W+Dg8CT
# DATA w4MXKf/PK18gFXkPp1+zAoiXZ0J8G/wiNlcgvXfRNxm+WrbxT5ZLZ/aLGK7O5NNJPsrmou+SsyFNB3FmRUtqk7vpzqZDVVVwsTxf
# DATA SJQl48ghZPbTSdSP59jbszk8MhwvpxKvhkoIc/zpRYVEMX7V7Q8SxC2zoJZSLwIhhLKfyC6gQSKt82gkquuTzQuJdeZ77G8+q3ef
# DATA N5410cUEX6fRtHhC5hqAnxkrgG59UPpnb/K5d87Zi8dQB/piuDPic9J7by1n7/U+rFkmbtzqZ7ZX141FDodByPZnv9gCG5ZdgbNr
# DATA fZ6za91o/uffMZQjmyt/0UYBAXUUZq/noWqyHmNyq1rY1vo6PSpmLKIxJq7ezV6TnohtJ79GJsVmqFIIizEXqZB1amWEeQMwQAPA
# DATA 0ITmOLWkbL8WUjynQAy1aosqVDcYfel59BqUYEADUMBVz+FDT0D5g0q5zPYYpA52FS32lVg6hUxZ8YTbhwuDfigZrbgEooPaTyzt
# DATA kuXo4SO2woJYVRbhzRDMxHGx2eqqCCKWl2rpUKclv7un2lnmFNU9BSdhmU8+5c6b+w+vj7igL6rrBiScscStF3YCTWQwFADU2sIC
# DATA TLIlKywoINz6ifBGrHnhTczZlIvVGQfM9DY2z9mRjP4pEAPQjzDTyxJBrcvgHuiopWRMW2FOKi26FXZ7k5ijn1Aimc0sKToPkVB0
# DATA wJ+xXiC3Dbshzrcg0tRt9wtYip8FtNUxqMOoTuJ30SOQZEYY4qKRa7dmDp/euRTctzGFhqhR9B/7bll0VaOv5Vc5BrovHZ8ccisS
# DATA 73tJvrd+jngv8c23eSgx7H14MjlGeSJcVdp4Amxtb+009Lul06/SjitVlYhrAz6hYSdnNtEfgiumucyqF9ekqVxQ3zv+ndCRje5R
# DATA 0he/THAFDgUwQP3BqGY8uV3/evdwZwfvgFwg1x/lm1I/fSLEo7XVVb8MnrOst/ae7+/UW7jz20t7PnrQ0DJSntCZ0m8YR7WYhDM4
# DATA MZmgn5w4QJ5gAmYPkQyXF9+lCLKQYIXrfW+/zuvdK3AwZzJAPToePKA51phlbblM6TNz1ep+7B/PQSsDZAR1gw9X3cQ1mA+gS9pN
# DATA fk9S19vrJw28ntK5szhlV2IPTYRJDWszjL2DhNHR7cMKdKGjV9KDopExCcF5vEo3aDFNcIDP0xdiUECnAg3QM4wj0UOAMzuejF8l
# DATA kJyYtRYAPQMUMI2HVxU/t8xSh2Qe+LNvzmVlyRbcLPLwWGLEcBlTX811I7FWEcPWs3fKHFpk0ObLZVMzCLWY3ya+MloR7d0pncfp
# DATA cjLhyEN4RpsFbxgiWsyq1qtLvnePc16G0Uvx8ujmUFUPsWs5O9eoLmm3Gy6YPsgqXDNRyAVhM2QsGpRr0+zXk+ceSDblhsqRgXkn
# DATA RW1kZ8ZEjt1uYTAaxb6gXLyOcaIMd0Cu0tLR2rXhMg4oApaX0iDkFmCOC5IDA7rskVu8oruLsK376eBsi9YKiCkFY0PChXF/90kx
# DATA VyvmFdhlHjJoWIhajb0MLZM9frm7mzXMFtV5OpU+3fBcvkafAayrFNzr+gNcdVM37jG3v4PnS2tDU1p66euQPnvTnS668peMk7iO
# DATA pUBHk1Lm0XxxrXOG2mUWe/Ubsmfpci0NxXvpMxe0tOd1MLNzs9AFF3oB5dhEsw7uPHK2XYY9X1PgPrFb/6bedBr6NNgbxQpTFwWN
# DATA n4/Fi0ZD4MfJ5cnJoDdAxy6I65MxihCiBVoHGJVIHODOBgmC2qRC0U2gLpPjMbqCwqOUMAvV+XkYE7sF09UGFygD5bJYLeMVrr2T
# DATA GQL+/she+Qhfc54ZMurNUborz1c6MPkU6dL1VWvbXX9WZj3+d1pIEZ8pifww6vcsVXdKJe93gCllquFn6ux/GNW8qZX/fVHBzyXj
# DATA 3qZCfobzEgScW4VupIbPJeDbUr4bevdFNO6u3jprR39vv7O5sMlzdNaD0cnYp5nnsNI8uHAdiUQIQHPXkZzdUM8N900Tgk+7PoPk
# DATA ireiOMdesPZ8NgnfsuK867fRG2pNorLT6pzqONQ0aRU7D1ncJ+bLanXsjb0roRsYkH7NGGn//k1Ram7WaANEYG+vxfE4FhfVJVgQ
# DATA +8neE2ufNHEIMIi529h9utd9KhY41weUXcyMJ/FUUN9tNV+YNSBhOw5czjTRng6TpHM4LN3o/G+vTzsHg0F8+s3NXBHv/lEn7qHc
# DATA Pr/5/q8xL9cv4aflwZBxLpIpAWs5MBNzKZ5JuS0EAOhfWYalO7pyVXkHIwprEFU4T8jPTI010jKrq/G7b6/9cZaqWoMMaFMi0k9G
# DATA afRM72uYgDbxArVA/EhIyh2aHvdXDuY5UrSe3PlaJqbR0/RGfb2ucmKbN7LCaxXiIR7he/4FfH00uqNCALL74csqbWxMqRcKPtdH
# DATA IW+7xRu5+siFCQekZn1z+0V4k67c6Fi2wPHMcrBnKlCTo1nlJzU9ews6OpkgDZ7WkU2lomxAKFB3Zp2MFm7+0+AJaZWhPUqxi7j4
# DATA 59EVHLcw41IUjGLAjb+gLDE6z1JlaaZ2VtEzD2jNT1dSRSNLSTJQwi5Wl80GPxB3/jvNjK0ca5BVrgq5OiHP3G/f/fv3/zugnVT2
# DATA mtLBzMd39QnmOBKSVcnYugwrpgR49HNj0zj4Q7HlTHp2lyssIf+034igGZuj+7xx8HyztfVl+D6zzImVYJL/4d2v09lS/wUzpUI6
# DATA vb+kFILhjEmdeVybx+Q5S9RzzK75Qp6/6kydD7XryXaSdvrJT0VUnFm9mz3Hyf9gpNFxHTZnp9PJ9y/wWwbsRCMQEmfmKPL2+jpD
# DATA XF7AsJOrjfqgRvBPESWNjx6EIQNBhAFq2PvB8RXFmF6MB6NpJdgXgwCBxME+KlpWRvEUDtmeWlnZANGp4xKeb0QbQW98AXnNlKKz
# DATA P4hOR+NkOuiBCnM6pv2lJ9OiL2Syz7DHd00I+/nVoMZymGn6WpgXpciffJu5ZcLh0JvSXOH1GTztPzMZm0xatnSb9JyiZVRc06Rg
# DATA AP7Bi4NW/Xl3f3PrK8iYIj2bxEFw/7AV5r2pN2+qsQa2cOfZt5fBqE8E4BjpHz3IawnHf1bGVmObkglb+dTrVVgtpN7jgXMD3pxE
# DATA 6Iv5h8wlQcFxSirezweJGIRTG/wnpVLKLK1ywIwGrw8Qf7Fg5ristM4oJeLp88HrxqhkJcCs4EPIq+hRmR4AgQG6U3w0MZUzoA0E
# DATA aw+vONfFRewGI4oGLwVRv8/rPbm8EL3CSBD1YNHzDKC38Om08CBlk/TUreCjRN8LGHPPfaEh4fyhBX9a0aKZd4DY4bmoU1TDqs6U
# DATA edVahIRIcDG8krFkYgmUEEPMeep43L+ycTWwkDpxeuwR8ajflbiCBSiVVYjAFAvhFkFolgEQQ2bElICKHiWlpwILYrGEEIuIthDO
# DATA 2/ROPDqdSokbjFnw3q6/KT6un058b/8KDdMkYmAd1pCf4eRl0Z8ZGJ9PVCYcgBbPCLdhHuR5nykaYQVANI0mcZfRArA3/LaMj2CC
# DATA EhNEgvjnCQIS48kHWyhmW3Zx30PK21i9DwKWNG+FT/eaTxrb2/Xd8HoOFa88XchspOCj+azeIm9bvENqZsgXS3JEmG8P1x1bB0wz
# DATA Gjf2hfOHyM7RPqUjSEDwKYQroOSm0P6VTD/bvN4oLTZUTVZYp87O7fb0NM7sqERnzOgPPdmR8E4r+bjghJ8Ip8P1DxdBlj2m2Dyi
# DATA n9O31cWHkQiOo3lv3hsKJX/P1i13ZIqCXYj2PZHHc/Zsf+/gfbs2RI6sKMxgQl1I4Jjm3O1OLolxfYQtrcI8Ld7WmkSj5CSelOuw
# DATA uVGsIKvf+GlBGZVBIpjjYKpVc6vB53BqKegyqLK0QXJvjZgZ59NAQKTZw30HYT+dvhRz3TEMERZqlohwOD5Txgv9BFwgEO8E4+IZ
# DATA l6wZvxygeuH6h16yPsLEnr4nceLiW4l6FE/5h0mV6w8e/gERJcyYB8NBh4Z9CNrUnJrj/6FDbdmXDonRVqyQvKT71Zmf7NcX2hsy
# DATA iZzEwo/k/d+BvG017g9E2CZNp2wzt0HH2TK1dTjYsA4HYLp7une4u+0eDj6oWtTq0I/Jg0cpgGA5mb6lpO/ZEPtUnhpJv9MCuiR3
# DATA Ho2x6I+7Qh4EeDjrjGneB57gL0BqFemYQ9OU9pqHUgoR0HhEQfUhCRvX/ViAzsM+a6d7H38WZoctM6bgwd7WV3WTys36LI9R9Lgx
# DATA lU9TqYAiF52SVMMQ5joWqnqrlUDXD03HBFZU4Z/uyRiTBWGC1QH4w3NyTaCjbhekmG43lFmPJwk6coj1h98rm5PTS4Ax3Mc7KtMW
# DATA WEi7QgbqdbtF40nIT9aN+JGCdnFE58191IAz0DD+Euez8cV0RblsSsuNtzJzp+2djQHZuEYgxygeaqdJB9kAYdJl0KkYirJEwsSy
# DATA MrSkk/saMg4ytxApz4ufZd0fRsfxMOc+mtnymwBv0OwKUG2ac5/Re3NKMC4ld4KDWbks/oHSUv8Eoaq4mcaXA7axrrrokgfo5lt/
# DATA DWfx5iXluyG3ElrbCrYacoUAreikCqKhih0Kq+OAlrLMG/gUmTfwqxgw/oazw99xJvg7jrpER/e3SxRk4kwC8L7bFAc/4Xceaf7F
# DATA o5rfSIo6LUg3G8LVbXquBnhF6GoRW1PXVaygw6octvzKzDWWU6PGn8CL+HPQ13PjQ6UnvbRbVXHpjz5+Pn4+fj5+Pn4+fj5+Pn4+
# DATA fj5+buvzX0YkWuoAiA4A
# END_REMNACUST_HELPERS_V1
REMNACUST_INSTALLER_PAYLOAD_V1
if [[ $EUID == 0 ]]; then
    bash "$directory/installer.sh" "$@"
else
    sudo bash "$directory/installer.sh" "$@"
fi
